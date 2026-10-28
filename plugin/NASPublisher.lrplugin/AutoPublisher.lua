--[[ AutoPublisher.lua
The background loop that makes publishing continuous. Every 30 seconds, for each NAS Publisher
service with "Publish automatically" on:

  1. If the NAS photo folder isn't mounted or the container doesn't answer, do nothing.
  2. Make sure the service has the "Edited RAWs" smart collection.
  3. For each collection, look for photos waiting to be published or removed. Publish once no
     waiting photo has been edited for "settle" seconds (or after 10 minutes of continuous
     editing), so a photo isn't rendered again for every slider move.
  4. Every 10 minutes, while you aren't editing, ask the container for RAWs with edited XMP
     sidecars and add the ones this catalog doesn't have (Lightroom reads their edits on
     import), so they publish too.
]]

local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'

local NasClient = require 'NasClient'
local PathUtil = require 'PathUtil'
local Settings = require 'Settings'
local State = require 'State'

local AutoPublisher = {}

local prefs = LrPrefs.prefsForPlugin()

-- Preferences are shared by every catalog; keep what belongs to one catalog under its path.
local function catalogKey(catalog, name)
	local ok, path = LrTasks.pcall(catalog.getPath, catalog)
	return name .. '|' .. tostring(ok and path or '')
end

local function ensureSmartCollection(catalog, service)
	local key = catalogKey(catalog, 'smartCollectionCreated_' .. tostring(service.localIdentifier))
	if prefs[key] then return end -- created before; if you deleted it, it stays deleted
	for _, coll in ipairs(service:getChildCollections()) do
		if coll:getName() == Settings.smartCollectionName then
			prefs[key] = true
			return
		end
	end
	local result = catalog:withWriteAccessDo('Create NAS Publisher smart collection', function()
		service:createPublishedSmartCollection(Settings.smartCollectionName, Settings.smartCollectionSearch, nil, true)
	end, { timeout = 10 })
	if result == 'executed' then
		prefs[key] = true
		State.log('created smart collection %q in service %s', Settings.smartCollectionName, tostring(service.localIdentifier))
	end
end

-- RAWs with edited XMP sidecars that the catalog doesn't have yet. A RAW is considered once per
-- version of its sidecar, so one you remove from the catalog is not added back unless its
-- sidecar changes.
local function importSidecarPhotos(catalog, client, root)
	local now = LrDate.currentTime()
	if now - State.lastSidecarCheck < Settings.sidecarCheckSeconds then return end
	State.lastSidecarCheck = now
	local ok, res = client:sidecars()
	if not ok then
		State.log('sidecar list: %s', tostring(res))
		return
	end
	if res.scanning then
		State.lastSidecarCheck = now - Settings.sidecarCheckSeconds + 60 -- ask again in a minute
	end
	local seenKey = catalogKey(catalog, 'sidecarSeen')
	-- A copy: Lightroom saves a preference table only when the key gets a new table.
	local seen, changed = {}, false
	for k, v in pairs(prefs[seenKey] or {}) do seen[k] = v end
	local todo = {}
	for _, item in ipairs(res.items or {}) do
		local token = tostring(item.version or item.modified)
		if type(item.rel) == 'string' and seen[item.rel] ~= token then
			-- The catalog may spell the path either way (macOS can report accented names
			-- decomposed, NFD; the NAS lists them composed, NFC): look for both.
			local candidates = { PathUtil.join(root, item.rel) }
			if type(item.relNFD) == 'string' and item.relNFD ~= item.rel then
				candidates[2] = PathUtil.join(root, item.relNFD)
			end
			local inCatalog, path = false, nil
			for _, c in ipairs(candidates) do
				if catalog:findPhotoByPath(c) then inCatalog = true end
				if not path and LrFileUtils.exists(c) then path = c end
			end
			if inCatalog then
				seen[item.rel], changed = token, true
			elseif path then
				todo[#todo + 1] = { rel = item.rel, path = path, token = token }
			end
		end
	end
	local added = 0
	for i = 1, math.min(#todo, Settings.sidecarImportsPerCycle) do
		local t = todo[i]
		local photo
		-- One short write transaction per photo, so Lightroom stays responsive.
		local okWrite, err = LrTasks.pcall(function()
			catalog:withWriteAccessDo('Add photo with XMP edits (NAS Publisher)', function()
				photo = catalog:addPhoto(t.path)
			end, { timeout = 15 })
		end)
		if okWrite and photo then
			added = added + 1
			seen[t.rel], changed = t.token, true
			LrTasks.pcall(function()
				catalog:withWriteAccessDo('Add photo with XMP edits (NAS Publisher)', function()
					local coll = catalog:createCollection('Added by NAS Publisher', nil, true)
					if coll then coll:addPhotos { photo } end
				end, { timeout = 15 })
			end)
		elseif not okWrite then
			-- e.g. a format Lightroom can't read: don't try again until the sidecar changes. Unless
			-- the file is gone now (the share dropped): then it's tried again later.
			State.log('adding %s: %s', t.path, tostring(err))
			if LrFileUtils.exists(t.path) then seen[t.rel], changed = t.token, true end
		end
	end
	if changed then prefs[seenKey] = seen end
	if added > 0 then
		State.log('added %d photos with XMP edits; %d more waiting', added, math.max(0, #todo - added))
		State.bezel(string.format('NAS Publisher: added %d photos with XMP edits', added))
	end
	if #todo > Settings.sidecarImportsPerCycle then
		State.lastSidecarCheck = 0 -- more next cycle
	end
end

-- Published photos whose id is not where the container would put them now: the RAW moved to
-- another folder, or a virtual copy was renamed. Lightroom doesn't count either as a change. A
-- local mismatch can also be just Unicode spelling (macOS may spell accented names decomposed,
-- the NAS composed), so the NAS confirms before a photo is marked; confirmed matches are cached.
local function findMoved(client, candidates)
	if #candidates == 0 then return {} end
	State.idConfirmed = State.idConfirmed or {}
	local items, unconfirmed = {}, {}
	for _, c in ipairs(candidates) do
		local key = c.remoteId .. '\0' .. c.rel .. '\0' .. c.variant
		if State.idConfirmed[c.photo.localIdentifier] ~= key then
			c.key = key
			unconfirmed[#unconfirmed + 1] = c
			items[#items + 1] = {
				key = tostring(c.photo.localIdentifier), rel = c.rel, variant = c.variant, uuid = c.uuid, fingerprint = '',
			}
		end
	end
	if #items == 0 then return {} end
	local ok, res = client:check(items)
	if not ok or type(res.results) ~= 'table' then return {} end -- not sure: leave them alone
	local moved = {}
	for _, c in ipairs(unconfirmed) do
		local r = res.results[tostring(c.photo.localIdentifier)]
		if type(r) == 'table' and r.id == c.remoteId then
			State.idConfirmed[c.photo.localIdentifier] = c.key
		else
			moved[#moved + 1] = c.pp
		end
	end
	return moved
end

-- What a collection has waiting: photos to publish, removals, when the most recent waiting edit
-- happened, and when any member was last edited. canAsk: the container checks moved-out deletes.
local function collectionWork(catalog, client, coll, root, canAsk)
	local members = coll:getPhotos()
	local isMember = {}
	for _, photo in ipairs(members) do isMember[photo.localIdentifier] = true end
	local byPhoto, removals = {}, 0
	for _, pp in ipairs(coll:getPublishedPhotos()) do
		local photo = pp:getPhoto()
		if not photo then
			-- A record whose photo left the catalog: its removal may still be pending.
			if pp:getRemoteId() then removals = removals + 1 end
		else
			byPhoto[photo.localIdentifier] = pp
			if not isMember[photo.localIdentifier] and pp:getRemoteId() then removals = removals + 1 end
		end
	end
	-- Published photos that left the collection since the last look are queued for removal too, in
	-- case getPublishedPhotos no longer lists them. Photos that were never published don't count.
	local key = coll.localIdentifier
	State.publishedMembers = State.publishedMembers or {}
	local last = State.publishedMembers[key]
	if last then
		for id in pairs(last) do
			if not isMember[id] and not byPhoto[id] then removals = removals + 1 end
		end
	end
	if State.deletesDeferred(key) then removals = 0 end -- the NAS refused them lately

	local meta = catalog:batchGetRawMetadata(members, { 'path', 'lastEditTime', 'isVirtualCopy', 'uuid', 'rating' })
	local work = {
		photos = 0, removals = removals, newestEdit = 0, newestAny = 0, outside = 0, failed = 0,
		kept = 0, unasked = 0, ratings = {},
	}
	local published, candidates, leftFolder = {}, {}, {}
	State.keptUntil = State.keptUntil or {}
	local now = LrDate.currentTime()
	for _, photo in ipairs(members) do
		local m = meta[photo] or {}
		local pp = byPhoto[photo.localIdentifier]
		local remoteId = pp and pp:getRemoteId()
		if remoteId then
			published[photo.localIdentifier] = true
			work.ratings[remoteId] = tonumber(m.rating) or 0
		end
		if (m.lastEditTime or 0) > work.newestAny then work.newestAny = m.lastEditTime end
		local waiting = (not pp) or (not remoteId) or pp:getEditedFlag()
		local rel = PathUtil.relative(m.path, root)
		if not rel then
			if waiting then
				work.outside = work.outside + 1
			elseif type(remoteId) == 'string' then
				-- Published, and now outside the NAS folder in Lightroom. Only the NAS can tell a RAW
				-- that really left (moved to another drive, ejected or not) from a Mac that sees the
				-- share somewhere else (/Volumes/home-1) or a "RAW folder" setting that doesn't match
				-- Lightroom's folders: it removes the JPEG only in the first case. An older container
				-- would remove it without checking, so it isn't asked at all.
				if not canAsk then
					work.unasked = work.unasked + 1
				elseif (State.keptUntil[remoteId] or 0) > now then
					work.kept = work.kept + 1
				else
					leftFolder[#leftFolder + 1] = pp
				end
			end
		elseif State.isFailed(photo, m.lastEditTime) or State.isWaitingToRetry(photo, m.lastEditTime) then
			if waiting then work.failed = work.failed + 1 end
		elseif waiting then
			work.photos = work.photos + 1
			if (m.lastEditTime or 0) > work.newestEdit then work.newestEdit = m.lastEditTime end
		elseif type(remoteId) == 'string' then
			local variant = PathUtil.variantName(m.isVirtualCopy,
				m.isVirtualCopy and photo:getFormattedMetadata('copyName'), photo.localIdentifier)
			if not PathUtil.idMatches(remoteId, rel, variant) then
				candidates[#candidates + 1] = {
					photo = photo, pp = pp, remoteId = remoteId, rel = rel, variant = variant, uuid = m.uuid,
				}
			end
		end
	end
	State.publishedMembers[key] = published

	-- A RAW moved out of the NAS folder in Lightroom: remove its JPEG and mark it changed, so it
	-- is published again if it ever comes back. The NAS keeps any whose RAW it still has; those
	-- are asked about again in 10 minutes.
	local unpublish = {}
	if #leftFolder > 0 then
		local ids = {}
		for _, pp in ipairs(leftFolder) do ids[#ids + 1] = pp:getRemoteId() end
		local ok, res = client:delete(ids, 'moved out of the NAS photo folder in Lightroom', true)
		if ok and type(res.results) == 'table' then
			for _, pp in ipairs(leftFolder) do
				local r = res.results[pp:getRemoteId()]
				if r == 'deleted' or r == 'missing' or r == 'unknown' then
					unpublish[#unpublish + 1] = pp
				elseif r == 'kept' then
					State.keptUntil[pp:getRemoteId()] = now + 600
					work.kept = work.kept + 1
				end
			end
		end
	end
	local moved = findMoved(client, candidates)
	if #moved > 0 or #unpublish > 0 then
		local result = catalog:withPrivateWriteAccessDo(function()
			for _, pp in ipairs(moved) do pp:setEditedFlag(true) end
			for _, pp in ipairs(unpublish) do pp:setEditedFlag(true) end
		end, { timeout = 10 })
		if result == 'executed' or result == nil then
			if #moved > 0 then State.log('%d photos moved or renamed; publishing them again', #moved) end
			if #unpublish > 0 then State.log('%d photos moved out of the NAS folder; their JPEGs were removed', #unpublish) end
			work.photos = work.photos + #moved
		end
	end
	return work
end

-- Starts a publish of one collection and waits for it to end. Lightroom gives no way to ask
-- whether a publish is running, and the done callback might not come for a publish with nothing
-- to do, so stop waiting once nothing has happened for a while.
local function publishCollection(coll, auto)
	State.autoFor = State.autoFor or {}
	State.autoFor[coll.localIdentifier] = auto
	State.activityAt = nil
	local started = LrDate.currentTime()
	local done = false
	local ok, err = LrTasks.pcall(function() coll:publishNow(function() done = true end) end)
	if not ok then
		State.autoFor[coll.localIdentifier] = nil
		State.log('publishNow: %s', tostring(err))
		return
	end
	while not done and not State.stopping do
		LrTasks.sleep(1)
		local now = LrDate.currentTime()
		if not State.publishRunning() then
			local quiet = now - (State.activityAt or started)
			if (State.activityAt == nil and quiet >= 120) or (State.activityAt ~= nil and quiet >= 60) then
				State.log('publish of "%s" ended without a done signal', coll:getName())
				break
			end
		end
		if now - started > 6 * 3600 then break end
	end
	if not State.publishing then State.autoFor[coll.localIdentifier] = nil end
end

-- A container with a new server id (fresh state, or another NAS) has none of the JPEGs Lightroom
-- thinks it published: mark them all for republishing. Ones the NAS already has with the same
-- fingerprint are recognized during the publish and not uploaded again.
local function noteServer(catalog, service, serverId)
	if type(serverId) ~= 'string' or serverId == '' then return end
	local key = catalogKey(catalog, 'serverId_' .. tostring(service.localIdentifier))
	local known = prefs[key]
	if known == serverId then return end
	if known ~= nil then
		local marked = {}
		for _, coll in ipairs(service:getChildCollections()) do
			for _, pp in ipairs(coll:getPublishedPhotos()) do
				if pp:getRemoteId() and not pp:getEditedFlag() then marked[#marked + 1] = pp end
			end
		end
		if #marked > 0 then
			local result = catalog:withPrivateWriteAccessDo(function()
				for _, pp in ipairs(marked) do pp:setEditedFlag(true) end
			end, { timeout = 10 })
			if result ~= 'executed' and result ~= nil then return end -- try again next cycle
		end
		State.log('NAS service changed (%s -> %s): republishing %d photos', tostring(known), serverId, #marked)
	end
	prefs[key] = serverId
end

-- Tells the NAS which of this service's published photos are starred, when that changed (or the
-- NAS's state was reset, or every 10 minutes), so its starred folder follows ratings without
-- re-rendering. After a failure (say, a container from before the starred folder) it waits 10
-- minutes before trying again.
local function syncStarred(client, service, starred, scope, serverId)
	local function sorted(set)
		local list = {}
		for id in pairs(set) do list[#list + 1] = id end
		table.sort(list)
		return list
	end
	local ids, all = sorted(starred), sorted(scope)
	local key = tostring(serverId) .. '\n' .. table.concat(ids, '\n') .. '\n\n' .. table.concat(all, '\n')
	local now = LrDate.currentTime()
	State.starredSync = State.starredSync or {}
	local s = State.starredSync[service.localIdentifier] or {}
	State.starredSync[service.localIdentifier] = s
	if now < (s.retryAt or 0) then return end
	if key == s.key and now - (s.at or 0) < 600 then return end
	local ok, res = client:starred(ids, all)
	if not ok then
		if res ~= s.lastError then State.log('starred folder: %s', tostring(res)) end
		s.lastError, s.retryAt = res, now + 600
		return
	end
	if key ~= s.key then
		State.log('starred folder: %d photos (%d added, %d removed%s)', #ids, tonumber(res.linked) or 0,
			tonumber(res.unlinked) or 0, (tonumber(res.failed) or 0) > 0 and (', ' .. res.failed .. ' failed') or '')
	end
	s.key, s.at, s.lastError, s.retryAt = key, now, nil, nil
end

local function serviceCycle(catalog, service, force)
	local settings = Settings.normalize(service:getPublishSettings())
	if not force and settings.npAutoPublish == false then return end
	local root = PathUtil.cleanRoot(settings.npSourceRoot)
	if root == '' then
		State.setStatus('Set "RAW folder on this Mac" in the NAS Publisher service settings.')
		if force then LrDialogs.message('NAS Publisher can\'t publish now', State.status, 'warning') end
		return
	end
	if LrFileUtils.exists(root) ~= 'directory' then
		State.nasOnline = false
		State.setStatus('Waiting for the NAS photo folder %s (is the share mounted?)', root)
		if force then LrDialogs.message('NAS Publisher can\'t publish now', State.status, 'warning') end
		return
	end
	local client = NasClient.new(settings)
	State.wantSidecars = settings.npImportSidecars ~= false
	local ok, res = client:hello(State.helloInfo(catalog))
	if not ok then
		State.nasOnline = false
		State.setStatus('Waiting for the NAS: %s', tostring(res))
		if force then LrDialogs.message('NAS Publisher can\'t publish now', State.status, 'warning') end
		return
	end
	State.nasOnline = true
	noteServer(catalog, service, res.serverId)
	ensureSmartCollection(catalog, service)

	local canAsk = false
	for _, f in ipairs(type(res.features) == 'table' and res.features or {}) do
		if f == 'deleteIfSourceGone' then canAsk = true end
	end

	local now = LrDate.currentTime()
	local settle = Settings.settleSeconds(settings)
	local waitingTotal, outside, failed, kept, unasked, newestAny = 0, 0, 0, 0, 0, 0
	local starMin = tonumber(settings.npStarredMin) or 0
	local starred, scope, allRead, publishedNow = {}, {}, true, false
	for _, coll in ipairs(service:getChildCollections()) do
		if State.stopping then return end
		if not State.nasOnline then break end -- a publish paused (the share or the NAS went away)
		-- One collection's trouble must not stop the others.
		local okColl, err = LrTasks.pcall(function()
			local work = collectionWork(catalog, client, coll, root, canAsk)
			outside, failed = outside + work.outside, failed + work.failed
			kept, unasked = kept + work.kept, unasked + work.unasked
			for id, rating in pairs(work.ratings) do
				scope[id] = true
				if starMin > 0 and rating >= starMin then starred[id] = true end
			end
			if work.newestAny > newestAny then newestAny = work.newestAny end
			local key = coll.localIdentifier
			if work.photos == 0 and work.removals == 0 then
				State.pendingSince[key] = nil
			else
				State.pendingSince[key] = State.pendingSince[key] or now
				local settled = now - work.newestEdit >= settle
				local overdue = now - State.pendingSince[key] >= Settings.maxWaitSeconds
				if force or settled or overdue or work.photos == 0 then
					State.setStatus('Publishing %d photos and %d removals from "%s"…', work.photos, work.removals, coll:getName())
					publishCollection(coll, not force)
					publishedNow = true
					State.pendingSince[key] = nil
				else
					waitingTotal = waitingTotal + work.photos
				end
			end
		end)
		if not okColl then
			allRead = false
			State.log('collection %s: %s', tostring(coll.localIdentifier), tostring(err))
		end
	end
	State.outside = outside
	if not State.nasOnline then return end -- the publish lost the NAS; keep its status
	-- Only from a complete, current picture: a collection that failed to read must not unstar its
	-- photos, and ids read before a publish may have changed (a moved photo); next cycle has them.
	if allRead and not publishedNow then
		local okStar, err = LrTasks.pcall(syncStarred, client, service, starred, scope, res.serverId)
		if not okStar then State.log('starred folder: %s', tostring(err)) end
	end

	-- Add sidecar-edited RAWs only while you aren't editing, so the imports (which Lightroom
	-- lists under Edit > Undo) don't get mixed up with your own changes. Not while Lightroom's
	-- folders and the "RAW folder" setting disagree: the catalog's copies wouldn't be found under
	-- the setting's path, and the same RAWs would be added a second time.
	if State.wantSidecars and kept + unasked == 0 and now - newestAny >= settle then
		local okImport, err = LrTasks.pcall(importSidecarPhotos, catalog, client, root)
		if not okImport then State.log('sidecar import: %s', tostring(err)) end
	end

	local status = 'Up to date'
	if waitingTotal > 0 then status = string.format('%d edited photos waiting for edits to settle', waitingTotal) end
	if State.lastPublishSummary then status = status .. '. Last publish: ' .. State.lastPublishSummary end
	if outside > 0 then status = status .. string.format('. %d edited photos are outside %s and are not published', outside, root) end
	if kept > 0 then
		status = status .. string.format('. %d published photos are outside %s in Lightroom, but their RAWs are still on '
			.. 'the NAS, so their JPEGs stay: check that "RAW folder on this Mac" is where Lightroom shows them', kept, root)
	end
	if unasked > 0 then
		status = status .. string.format('. %d published photos are outside %s in Lightroom; their JPEGs stay on the NAS '
			.. 'until its container is updated (1.1.1 or later checks whether their RAWs left)', unasked, root)
	end
	if failed > 0 then status = status .. string.format('. %d photos failed and wait for their next edit or a retry (see the log)', failed) end
	State.setStatus('%s.', status)
end

-- One pass over every NAS Publisher service. force: publish now, without waiting for edits to
-- settle, even where auto-publish is off.
function AutoPublisher.cycle(force)
	if State.publishRunning() then
		State.setStatus('Publishing… (the loop waits for it to finish)')
		return
	end
	local catalog = LrApplication.activeCatalog()
	local services = catalog:getPublishServices(_PLUGIN.id)
	if #services == 0 then
		-- Right after a plugin reload the lookup by id can come back empty.
		for _, service in ipairs(catalog:getPublishServices(nil)) do
			local id = service:getPluginId()
			if id == _PLUGIN.id or id:sub(1, #_PLUGIN.id + 1) == _PLUGIN.id .. '.' then
				services[#services + 1] = service
			end
		end
	end
	if #services == 0 then
		State.setStatus('No NAS Publisher service yet: set one up in the Publish Services panel.')
		return
	end
	for _, service in ipairs(services) do
		if State.stopping then return end
		local ok, err = LrTasks.pcall(serviceCycle, catalog, service, force)
		if not ok then State.setStatus('Error: %s', tostring(err)) end
	end
end

-- Runs until Lightroom quits or the plugin is reloaded. A reload starts a new loop with a new
-- token; the old one sees the token change and ends. While the plugin is disabled it idles.
function AutoPublisher.run()
	local token = string.format('%.6f-%d', LrDate.currentTime(), math.random(1, 1000000000))
	prefs.loopToken = token
	State.stopping = false
	State.loopRunning = true
	State.log('NAS Publisher %s: auto-publish loop started', State.version)
	local function alive()
		return not State.stopping and prefs.loopToken == token
	end
	-- Let Lightroom finish starting up first.
	for _ = 1, 20 do
		if not alive() then break end
		LrTasks.sleep(1)
	end
	while alive() do
		if _PLUGIN.enabled ~= false then
			local force = State.forceNext
			State.forceNext = false
			local ok, err = LrTasks.pcall(AutoPublisher.cycle, force)
			if not ok then State.setStatus('Error: %s', tostring(err)) end
		end
		for _ = 1, Settings.pollSeconds do
			if not alive() or State.wakeUp then break end
			LrTasks.sleep(1)
		end
		State.wakeUp = false
	end
	State.loopRunning = false
	State.log('auto-publish loop stopped')
end

function AutoPublisher.stop()
	State.stopping = true
end

-- "Publish Now": the loop runs a forced cycle right away.
function AutoPublisher.publishNow()
	State.forceNext = true
	State.wakeUp = true
end

return AutoPublisher
