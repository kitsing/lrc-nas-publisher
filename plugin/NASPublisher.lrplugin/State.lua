--[[ State.lua
What the auto-publish loop, the publish service and the menu items share while Lightroom runs,
plus the plugin's log (~/Library/Logs/Adobe/Lightroom/LrClassicLogs/NASPublisher.log).
]]

local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrLogger = import 'LrLogger'
local LrTasks = import 'LrTasks'

local logger = LrLogger('NASPublisher')
logger:enable('logfile')

local State = {
	version = '1.0.0',
	status = 'Starting…',
	statusAt = nil,
	nasOnline = false,
	lastPublishAt = nil,
	lastPublishSummary = nil,
	publishing = false, -- processRenderedPhotos is running
	autoRun = false, -- the publish under way was started by the background loop: no dialogs
	stopping = false,
	wakeUp = false, -- "Publish Now" asks the loop to run a cycle at once
	pendingSince = {}, -- [published collection id] = when work was first seen waiting
	failed = {}, -- [photo.localIdentifier] = { editTime=, reason=, at= }: skipped until edited again
	outside = 0, -- edited photos in our collections that aren't under the NAS photo folder
	lastSidecarCheck = 0,
}

-- Last sign of a publish at work (processRenderedPhotos or a delete), for the loop's stall check.
function State.touch()
	State.activityAt = LrDate.currentTime()
end

function State.log(fmt, ...)
	local ok, msg = pcall(string.format, fmt, ...)
	logger:info(ok and msg or tostring(fmt))
end

function State.setStatus(fmt, ...)
	local msg = string.format(fmt, ...)
	if msg ~= State.status then State.log('status: %s', msg) end
	State.status = msg
	State.statusAt = LrDate.currentTime()
end

-- A photo that failed for a reason that won't go away by itself (bad file, outside the photo
-- folder, refused by the NAS) is left alone until it is edited again, or for a few hours.
local FAILED_RETRY_SECONDS = 6 * 3600

function State.markFailed(photo, editTime, reason)
	State.failed[photo.localIdentifier] = { editTime = editTime or 0, reason = tostring(reason), at = LrDate.currentTime() }
	State.log('skipping %s until it is edited again: %s', tostring(photo.localIdentifier), tostring(reason))
end

function State.isFailed(photo, editTime)
	local f = State.failed[photo.localIdentifier]
	if not f then return false end
	if (editTime or 0) ~= f.editTime or LrDate.currentTime() - f.at > FAILED_RETRY_SECONDS then
		State.failed[photo.localIdentifier] = nil
		return false
	end
	return true
end

-- A photo that failed for a reason that may pass (the NAS's disk, a 5xx answer) is retried
-- after 1, 5, 30 and then every 120 minutes, instead of on every cycle.
local RETRY_MINUTES = { 1, 5, 30, 120 }

function State.markRetry(photo, reason)
	State.retry = State.retry or {}
	local r = State.retry[photo.localIdentifier] or { count = 0 }
	r.count = r.count + 1
	r.at = LrDate.currentTime() + 60 * RETRY_MINUTES[math.min(r.count, #RETRY_MINUTES)]
	r.reason = tostring(reason)
	State.retry[photo.localIdentifier] = r
	State.log('retrying %s later: %s', tostring(photo.localIdentifier), r.reason)
end

function State.isWaitingToRetry(photo)
	local r = State.retry and State.retry[photo.localIdentifier]
	return r ~= nil and LrDate.currentTime() < r.at
end

function State.clearRetry(photo)
	if State.retry then State.retry[photo.localIdentifier] = nil end
end

-- Deletes the NAS didn't acknowledge stay queued in Lightroom; don't start a publish for them
-- alone more than every 10 minutes.
function State.deferDeletes(collectionId)
	if collectionId == nil then return end
	State.deleteRetryAt = State.deleteRetryAt or {}
	State.deleteRetryAt[collectionId] = LrDate.currentTime() + 600
end

function State.deletesDeferred(collectionId)
	local t = State.deleteRetryAt and State.deleteRetryAt[collectionId]
	return t ~= nil and LrDate.currentTime() < t
end

function State.failedCount()
	local n = 0
	for _ in pairs(State.failed) do n = n + 1 end
	return n
end

-- What the plugin tells the NAS about itself (shown on the container's status page).
function State.helloInfo(catalog)
	local host = 'Lightroom Classic'
	local ok, name = LrTasks.pcall(function() return import('LrSystemInfo').computerName() end)
	if ok and type(name) == 'string' and name ~= '' then host = name end
	local path
	if catalog then
		local okPath, p = LrTasks.pcall(catalog.getPath, catalog)
		if okPath then path = p end
	end
	return { client = 'NASPublisher', version = State.version, host = host, catalog = path, sidecars = State.wantSidecars == true }
end

function State.bezel(msg)
	pcall(LrDialogs.showBezel, msg, 3)
end

return State
