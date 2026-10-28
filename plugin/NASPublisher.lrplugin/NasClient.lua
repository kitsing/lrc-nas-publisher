--[[ NasClient.lua
Talks to the lrc-nas-publisher container. Every call returns
  true, decodedJsonBody        on HTTP 200 with {"ok":true,...}
  false, message, httpStatus   otherwise (status is nil when the NAS is unreachable)
Call from an async task (LrHttp blocks).
]]

local LrFileUtils = import 'LrFileUtils'
local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'

local Json = require 'Json'
local Settings = require 'Settings'
local State = require 'State'

-- The token from the container's config folder on a mounted share, or ''. LrFileUtils calls may
-- yield, so only LrTasks.pcall can guard them; plain io is the fallback.
local function readTokenFile(path)
	local ok, text = LrTasks.pcall(LrFileUtils.readFile, path)
	if not (ok and type(text) == 'string') then
		text = nil
		local f = io.open(path, 'r')
		if f then
			text = f:read('*a')
			f:close()
		end
	end
	return type(text) == 'string' and (text:gsub('%s', '')) or ''
end

-- A share that comes back while its old mount point is still there is mounted at
-- /Volumes/<name>-1 (or -2, ...): look there too.
local function tokenCandidates()
	local out = {}
	for _, path in ipairs(Settings.tokenFiles) do
		out[#out + 1] = path
		local volume, rest = path:match('^/Volumes/([^/]+)(/.+)$')
		if volume then
			for n = 1, 3 do out[#out + 1] = string.format('/Volumes/%s-%d%s', volume, n, rest) end
		end
	end
	return out
end

local function findToken()
	for _, path in ipairs(tokenCandidates()) do
		if LrFileUtils.exists(path) == 'file' then
			local token = readTokenFile(path)
			if token ~= '' then return token end
			State.log('could not read the token in %s', path)
		end
	end
	return ''
end

local NasClient = {}
NasClient.__index = NasClient

function NasClient.new(settings)
	local url = (settings.npNasUrl or ''):gsub('%s', ''):gsub('/+$', '')
	local token = (settings.npToken or ''):gsub('%s', '')
	local fromFile = token == ''
	if fromFile then
		-- Not entered: read it from the container's config folder on a mounted share.
		token = findToken()
	end
	return setmetatable({ url = url, token = token, tokenFromFile = fromFile }, NasClient)
end

function NasClient:headers(extra)
	local h = { { field = 'Authorization', value = 'Bearer ' .. self.token } }
	for _, x in ipairs(extra or {}) do h[#h + 1] = x end
	return h
end

-- Turns an LrHttp result into the convention above.
function NasClient:result(body, hdrs)
	if not hdrs or hdrs.error or not hdrs.status then
		local why = hdrs and hdrs.error and (hdrs.error.name or hdrs.error.errorCode) or 'no answer'
		return false, string.format("Can't reach the NAS at %s (%s).", self.url, tostring(why)), nil
	end
	local data = Json.decode(body or '')
	if hdrs.status == 200 and type(data) == 'table' and data.ok == true then
		return true, data
	end
	local msg = type(data) == 'table' and type(data.error) == 'string' and data.error
		or string.format('HTTP %s from %s', tostring(hdrs.status), self.url)
	return false, msg, hdrs.status
end

function NasClient:configured()
	if not self.url:match('^https?://[^/]+') then return false, 'Enter the NAS address, e.g. http://nas.local:8765.' end
	if self.token == '' and self.tokenFromFile and Settings.tokenFiles[1] then
		return false, string.format("Can't read the access token in %s: is that share mounted? "
			.. '(Or enter the token in the service settings.)', Settings.tokenFiles[1])
	elseif self.token == '' then
		return false, "Enter the NAS's access token (the token file in the container's config folder)."
	end
	return true
end

function NasClient:postJson(path, payload, timeout)
	local ok, why = self:configured()
	if not ok then return false, why end
	local body, hdrs = LrHttp.post(self.url .. path, Json.encode(payload or {}),
		self:headers { { field = 'Content-Type', value = 'application/json' } }, 'POST', timeout or 30)
	return self:result(body, hdrs)
end

function NasClient:hello(info)
	return self:postJson('/api/hello', info, 10)
end

-- ids: list of published ids. Answers results = { [id] = 'deleted' | 'missing' | 'error: ...' }.
-- onlyIfSourceGone: the NAS deletes a JPEG only if its RAW has left the NAS photo folder, and
-- answers 'kept' for the others.
function NasClient:delete(ids, reason, onlyIfSourceGone)
	return self:postJson('/api/delete', { ids = Json.array(ids), reason = reason, onlyIfSourceGone = onlyIfSourceGone or nil }, 60)
end

-- items: list of { key=, rel=, variant=, fingerprint= }. Answers
-- results = { [key] = { id=, current= } }; current means the NAS has this fingerprint already.
function NasClient:check(items)
	return self:postJson('/api/check', { items = Json.array(items) }, 60)
end

-- ids: the published ids that should be in the NAS's starred folder; scope: every id this
-- service publishes, so starred photos of another catalog or service are left alone.
function NasClient:starred(ids, scope)
	return self:postJson('/api/starred', { ids = Json.array(ids), scope = Json.array(scope) }, 120)
end

function NasClient:sidecars()
	local ok, why = self:configured()
	if not ok then return false, why end
	local body, hdrs = LrHttp.get(self.url .. '/api/sidecars', self:headers(), 120)
	return self:result(body, hdrs)
end

-- Uploads the rendered JPEG at filePath; fields are rel, variant, previousId,
-- fingerprint and uuid (see the container's handleUpload). The file is streamed
-- from disk.
function NasClient:upload(filePath, fields)
	local ok, why = self:configured()
	if not ok then return false, why end
	local content = {}
	for _, name in ipairs { 'rel', 'variant', 'previousId', 'fingerprint', 'uuid' } do
		if fields[name] ~= nil then content[#content + 1] = { name = name, value = tostring(fields[name]) } end
	end
	content[#content + 1] = { name = 'file', fileName = 'photo.jpg', filePath = filePath, contentType = 'image/jpeg' }
	local body, hdrs = LrHttp.postMultipart(self.url .. '/api/photos', content, self:headers(), 600)
	return self:result(body, hdrs)
end

return NasClient
