--[[ PublishServiceProvider.lua
The "NAS Publisher" publish service. Lightroom renders each photo; the JPEG goes to the
lrc-nas-publisher container, which files it under the NAS's export folder in the same folders as
the RAW. The container's answer (the JPEG's path there) is recorded as the photo's remote id.

When the auto-publish loop started a publish, nothing here shows a dialog: problems go to the
status (Library > Plug-in Extras > NAS Publisher: Status…) and the log, and the photos stay
queued for the next try.
]]

local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Fingerprint = require 'Fingerprint'
local JpegSize = require 'JpegSize'
local NasClient = require 'NasClient'
local PathUtil = require 'PathUtil'
local Settings = require 'Settings'
local State = require 'State'

local provider = {}

provider.supportsIncrementalPublish = 'only'
provider.exportPresetFields = Settings.fields
provider.hideSections = { 'exportLocation', 'fileNaming', 'video', 'postProcessing' }
provider.allowFileFormats = { 'JPEG' }
provider.canExportVideo = false
provider.supportsCustomSortOrder = false
provider.hidePrintResolution = true

-- Republish when metadata that is embedded in the JPEG changes; Develop changes always count.
provider.metadataThatTriggersRepublish = function(publishSettings)
	return {
		default = false,
		title = true,
		caption = true,
		keywords = true,
		gps = true,
		dateCreated = true,
		copyright = true,
		creator = true,
		location = true,
	}
end

provider.getCollectionBehaviorInfo = function(publishSettings)
	return {
		-- A plain collection for photos you want on the NAS whether or not they are edited. The
		-- plugin adds the "Edited RAWs" smart collection next to it.
		defaultCollectionName = 'Hand-picked',
		defaultCollectionCanBeDeleted = true,
		canAddCollection = true,
		maxCollectionSetDepth = 0,
	}
end

-- First-time defaults for a new service: full-size sRGB JPEGs at quality 90.
function provider.startDialog(propertyTable)
	if not propertyTable.npDefaultsApplied then
		propertyTable.LR_format = 'JPEG'
		propertyTable.LR_jpeg_quality = 0.9
		propertyTable.LR_export_colorSpace = 'sRGB'
		propertyTable.LR_size_doConstrain = false
		propertyTable.LR_outputSharpeningOn = false
		propertyTable.npDefaultsApplied = true
	end
end

function provider.sectionsForTopOfDialog(f, propertyTable)
	local bind = LrView.bind
	local share = LrView.share
	local function label(title)
		return f:static_text { title = title, alignment = 'right', width = share 'npLabelWidth' }
	end
	return {
		{
			title = 'NAS Publisher',
			synopsis = bind { key = 'npNasUrl', object = propertyTable },
			f:row {
				label 'NAS service:',
				f:edit_field { value = bind 'npNasUrl', width_in_chars = 32, immediate = true },
			},
			f:row {
				label 'Access token:',
				f:password_field { value = bind 'npToken', width_in_chars = 32, immediate = true },
			},
			f:row {
				label '',
				f:static_text {
					title = 'Leave empty to read it from the container\'s config/token on the mounted share.',
					size = 'small',
				},
			},
			f:row {
				label 'RAW folder on this Mac:',
				f:edit_field { value = bind 'npSourceRoot', width_in_chars = 40, immediate = true },
				f:push_button {
					title = 'Choose…',
					action = function()
						local chosen = LrDialogs.runOpenPanel {
							title = 'The NAS folder the container reads RAWs from',
							canChooseFiles = false, canChooseDirectories = true, allowsMultipleSelection = false,
							initialDirectory = propertyTable.npSourceRoot,
						}
						if chosen and chosen[1] then propertyTable.npSourceRoot = chosen[1] end
					end,
				},
			},
			f:row {
				label '',
				f:static_text {
					title = 'The folder mounted as /source in the container. Each JPEG keeps its RAW\'s path below it.',
					size = 'small',
				},
			},
			f:row {
				label '',
				f:checkbox { title = 'Publish automatically while Lightroom is running', value = bind 'npAutoPublish' },
			},
			f:row {
				label '',
				f:static_text { title = 'once edits have settled for' },
				f:edit_field { value = bind 'npSettleSeconds', width_in_digits = 4, precision = 0, min = 5, max = 3600 },
				f:static_text { title = 'seconds' },
			},
			f:row {
				label '',
				f:checkbox {
					title = 'Add RAWs that have edits in XMP sidecars but are not in this catalog',
					value = bind 'npImportSidecars',
				},
			},
			f:row {
				label '',
				f:push_button {
					title = 'Test Connection',
					action = function()
						LrTasks.startAsyncTask(function()
							propertyTable.npTestResult = 'Testing…'
							local ok, res = NasClient.new(propertyTable):hello {
								client = 'NASPublisher', version = State.version, host = 'connection test',
							}
							if ok then
								propertyTable.npTestResult = string.format('Connected: lrc-nas-publisher %s, %d JPEGs published.',
									tostring(res.version), tonumber(res.published) or 0)
							else
								propertyTable.npTestResult = tostring(res)
							end
						end)
					end,
				},
				f:static_text { title = bind 'npTestResult', fill_horizontal = 1, width_in_chars = 40 },
			},
		},
	}
end

local function variantOf(photo)
	local isCopy = photo:getRawMetadata('isVirtualCopy')
	return PathUtil.variantName(isCopy, isCopy and photo:getFormattedMetadata('copyName'), photo.localIdentifier)
end

-- What each photo is, decided before rendering starts. skip is one of
--   'outside'   not under the NAS photo folder: none of this service's business
--   'unmounted' the NAS photo folder isn't there (share not mounted): try again later
--   'offline'   the folder is there but the original isn't
--   'nosource'  the NAS can't find the RAW: the "RAW folder" setting is wrong
local function plan(photos, settings, sourceRoot)
	local root = PathUtil.cleanRoot(sourceRoot)
	local mounted = root ~= '' and LrFileUtils.exists(root) == 'directory'
	local plans, checks = {}, {}
	local raw = LrApplication.activeCatalog():batchGetRawMetadata(photos,
		{ 'path', 'lastEditTime', 'uuid', 'croppedDimensions' })
	for _, photo in ipairs(photos) do
		local m = raw[photo] or {}
		local p = { editTime = m.lastEditTime, uuid = m.uuid, path = m.path, dims = m.croppedDimensions }
		p.rel = PathUtil.relative(p.path, root)
		if not p.rel then
			p.skip = 'outside'
		elseif not mounted then
			p.skip = 'unmounted'
		elseif not LrFileUtils.exists(p.path) then
			p.skip = 'offline'
		else
			p.variant = variantOf(photo)
			p.fingerprint = Fingerprint.forPhoto(photo, p.rel, p.variant, settings)
			checks[#checks + 1] = {
				key = tostring(photo.localIdentifier), rel = p.rel, variant = p.variant,
				uuid = p.uuid, fingerprint = p.fingerprint,
			}
		end
		plans[photo.localIdentifier] = p
	end
	return plans, checks
end

local SKIP_MESSAGES = {
	outside = 'Not in the NAS photo folder.',
	unmounted = 'The NAS photo folder is not mounted on this Mac.',
	offline = 'The original is missing.',
	nosource = 'The NAS can\'t find this RAW: check the "RAW folder on this Mac" setting.',
}

-- After rendering: is this a full render of the original? If the share dropped since plan(),
-- Lightroom quietly renders from the smart preview (about 2560 px) instead.
local function renderedFromOriginal(p, path, settings)
	if not LrFileUtils.exists(p.path) then return false, 'the original went offline while publishing' end
	if settings.LR_size_doConstrain then return true end
	local w, h = JpegSize.read(path)
	if w and not JpegSize.fullSize(w, h, p.dims) then
		return false, string.format('rendered at %dx%d, smaller than the original (a smart preview?)', w, h)
	end
	return true
end

-- The session's photos as a list. exportSession:photosToExport() hands out an iterator
-- (for _, photo in session:photosToExport() do ...), not a table.
local function sessionPhotos(session)
	local first = session:photosToExport()
	if type(first) == 'table' then return first end
	local photos = {}
	for a, b in session:photosToExport() do
		local photo = b
		if photo == nil then photo = a end
		photos[#photos + 1] = photo
	end
	return photos
end

function provider.processRenderedPhotos(functionContext, exportContext)
	local coll = exportContext.publishedCollection
	local collId = coll and coll.localIdentifier
	local auto = (collId and State.autoFor and State.autoFor[collId]) or false
	State.publishing = true
	State.touch()
	functionContext:addCleanupHandler(function()
		if collId and State.autoFor then State.autoFor[collId] = nil end
		State.publishEnded()
	end)

	local settings = exportContext.propertyTable
	local own = Settings.normalize(settings)
	local session = exportContext.exportSession
	local client = NasClient.new(own)
	local counts = { published = 0, unchanged = 0, failed = 0, waiting = 0, skipped = {} }

	-- Decide what happens to each photo before rendering starts. Photos that can't go out now are
	-- taken out of the session: they are neither rendered nor marked published, so they stay
	-- queued, and Lightroom shows no failure dialog for them.
	local photos = sessionPhotos(session)
	local reachable, why = client:hello(State.helloInfo(LrApplication.activeCatalog()))
	local plans = {}
	if not reachable then
		State.nasOnline = false
		State.setStatus('Waiting for the NAS: %s', tostring(why))
		for _, photo in ipairs(photos) do session:removePhoto(photo) end
		counts.waiting = #photos
		if not auto then LrDialogs.message('NAS Publisher can\'t publish now', State.status, 'warning') end
	else
		local checks
		plans, checks = plan(photos, settings, own.npSourceRoot)
		if #checks > 0 then
			local ok, res = client:check(checks)
			if ok and type(res.results) == 'table' then
				for _, c in ipairs(checks) do
					local r, p = res.results[c.key], plans[tonumber(c.key)]
					if type(r) == 'table' then
						if r.found == false then
							p.skip = 'nosource'
						elseif r.current == true and type(r.id) == 'string' then
							p.currentId = r.id
						end
					end
				end
			end
		end
		for _, photo in ipairs(photos) do
			local p = plans[photo.localIdentifier]
			if p.skip then
				counts.skipped[p.skip] = (counts.skipped[p.skip] or 0) + 1
				if p.skip == 'offline' or p.skip == 'nosource' then State.markFailed(photo, p.editTime, SKIP_MESSAGES[p.skip]) end
				session:removePhoto(photo)
			elseif auto and not p.currentId and (State.isFailed(photo, p.editTime) or State.isWaitingToRetry(photo)) then
				session:removePhoto(photo)
			end
		end
		if counts.skipped.nosource then
			State.setStatus('The NAS can\'t find %d RAWs: check that "RAW folder on this Mac" (%s) is the folder the container reads.',
				counts.skipped.nosource, tostring(own.npSourceRoot))
		elseif counts.skipped.unmounted then
			State.setStatus('Waiting for the NAS photo folder %s (is the share mounted?)', tostring(own.npSourceRoot))
		end
	end

	-- Photos the NAS already has in this exact version are recorded without rendering. skipRender
	-- only works before the rendering loop starts, hence this pass over the session first.
	if reachable then
		for _, rendition in session:renditions() do
			local p = plans[rendition.photo.localIdentifier]
			if p and p.currentId then rendition:skipRender() end
		end
	end

	local total = session:countRenditions()
	local progress = exportContext:configureProgress {
		title = total == 1 and 'NAS Publisher: 1 photo' or string.format('NAS Publisher: %d photos', total),
	}

	local function fail(rendition, photo, p, reason, permanent)
		counts.failed = counts.failed + 1
		State.log('%s: %s', tostring(p and p.path or photo.localIdentifier), tostring(reason))
		if permanent then
			State.markFailed(photo, p and p.editTime, reason)
		else
			State.markRetry(photo, reason)
		end
		if not auto then rendition:uploadFailed(tostring(reason)) end
	end

	for _, rendition in exportContext:renditions { stopIfCanceled = true } do
		State.touch()
		local photo = rendition.photo
		local p = plans[photo.localIdentifier]
		if not reachable then
			-- The NAS went away during this publish: nothing is recorded, so the rest stay queued.
			-- (Renders Lightroom already made are temporary files it removes with the session.)
			counts.waiting = counts.waiting + 1
		elseif not p then
			fail(rendition, photo, nil, 'Lightroom asked for a photo it did not list.', false)
		elseif p.currentId then
			-- The NAS already has this exact version (skipped before rendering started).
			rendition:recordPublishedPhotoId(p.currentId)
			State.clearRetry(photo)
			counts.unchanged = counts.unchanged + 1
		else
			local ok, pathOrMessage = rendition:waitForRender()
			if progress:isCanceled() then
				if ok then LrFileUtils.delete(pathOrMessage) end
				break
			end
			if not ok then
				fail(rendition, photo, p, 'Rendering failed: ' .. tostring(pathOrMessage), true)
			else
				local full, whyNot = renderedFromOriginal(p, pathOrMessage, settings)
				if not full then
					LrFileUtils.delete(pathOrMessage)
					-- Most likely the share dropped: nothing more goes out in this publish, and the
					-- loop checks the share and the NAS again before the next one.
					reachable, why = false, whyNot
					State.nasOnline = false
					counts.waiting = counts.waiting + 1
					State.setStatus('Paused publishing: %s', whyNot)
					State.log('%s: %s', tostring(p.path), whyNot)
				else
					local _, previousId = LrTasks.pcall(function() return rendition.publishedPhotoId end)
					local up, res, status = client:upload(pathOrMessage, {
						rel = p.rel, variant = p.variant, previousId = previousId,
						fingerprint = p.fingerprint, uuid = p.uuid,
					})
					LrFileUtils.delete(pathOrMessage)
					if up then
						rendition:recordPublishedPhotoId(res.id)
						State.clearRetry(photo)
						counts.published = counts.published + 1
					elseif status == nil then
						-- The NAS went away: this one and the rest stay queued.
						reachable, why = false, res
						State.nasOnline = false
						counts.waiting = counts.waiting + 1
						State.setStatus('Waiting for the NAS: %s', tostring(res))
					else
						-- 4xx: this photo is the problem (until it's edited again); 5xx: the NAS is.
						fail(rendition, photo, p, res, status < 500)
					end
				end
			end
		end
	end

	local summary = string.format('%d published, %d already current', counts.published, counts.unchanged)
	if counts.failed > 0 then summary = summary .. string.format(', %d failed', counts.failed) end
	if counts.waiting > 0 then summary = summary .. string.format(', %d waiting for the NAS', counts.waiting) end
	for kind, n in pairs(counts.skipped) do
		if kind ~= 'outside' then summary = summary .. string.format(', %d skipped (%s)', n, SKIP_MESSAGES[kind]) end
	end
	State.log('publish (%s): %s', auto and 'automatic' or 'manual', summary)
	State.lastPublishAt = LrDate.currentTime()
	State.lastPublishSummary = summary
	if counts.published > 0 then State.bezel('NAS Publisher: ' .. summary) end
	-- A manual publish whose photos were all taken out above would otherwise end silently.
	if not auto and reachable then
		local notes = {}
		for kind, n in pairs(counts.skipped) do
			if kind ~= 'outside' then notes[#notes + 1] = string.format('%d: %s', n, SKIP_MESSAGES[kind]) end
		end
		if #notes > 0 then
			LrDialogs.message('NAS Publisher skipped some photos', table.concat(notes, '\n'), 'info')
		end
	end
end

-- Remote ids still used by other collections of this service: a photo in both "Hand-picked" and
-- "Edited RAWs" has one JPEG, which must stay while either collection has it.
local function idsUsedElsewhere(localCollectionId)
	local used = {}
	local catalog = LrApplication.activeCatalog()
	local ok, coll = LrTasks.pcall(catalog.getPublishedCollectionByLocalIdentifier, catalog, localCollectionId)
	if not ok or not coll then return used end
	for _, other in ipairs(coll:getService():getChildCollections()) do
		if other.localIdentifier ~= localCollectionId then
			for _, pp in ipairs(other:getPublishedPhotos()) do
				local id = pp:getRemoteId()
				if id then used[id] = true end
			end
		end
	end
	return used
end

function provider.deletePhotosFromPublishedCollection(publishSettings, arrayOfPhotoIds, deletedCallback, localCollectionId)
	State.touch()
	local used = idsUsedElsewhere(localCollectionId)
	local ids = {}
	for _, id in ipairs(arrayOfPhotoIds) do
		if used[id] then deletedCallback(id) else ids[#ids + 1] = id end
	end
	if #ids == 0 then return end
	local ok, res = NasClient.new(Settings.normalize(publishSettings)):delete(ids, 'removed from the collection in Lightroom')
	if not ok then
		-- Not acknowledged, so Lightroom keeps these queued for removal and retries. No error():
		-- that would be a dialog on every automatic publish.
		State.nasOnline = false
		State.deferDeletes(localCollectionId)
		State.log('deleting %d JPEGs: %s', #ids, tostring(res))
		State.setStatus('Waiting for the NAS to delete %d JPEGs: %s', #ids, tostring(res))
		return
	end
	local failed = 0
	for _, id in ipairs(ids) do
		local r = res.results and res.results[id]
		-- 'unknown': not a JPEG the NAS wrote, so it leaves it alone; nothing more to do either way.
		if r == 'deleted' or r == 'missing' or r == 'unknown' then
			deletedCallback(id)
		else
			failed = failed + 1
			State.log('deleting %s: %s', tostring(id), tostring(r))
		end
	end
	if failed > 0 then State.deferDeletes(localCollectionId) end
end

return provider
