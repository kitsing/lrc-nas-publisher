--[[ fake_lrsdk.lua
A fake of the parts of the Lightroom Classic SDK that NAS Publisher uses, so the plugin's real Lua
runs outside Lightroom (Lua 5.1) against a real lrc-nas-publisher container. Used by harness.lua.

What it models, and how (see harness.lua for the assumptions list):
  LrHttp        real HTTP through curl. (body, { status = n }) on an HTTP answer;
                (nil, { error = { errorCode, name, nativeCode } }) when the transport fails.
  LrDate/LrTasks  a mock clock in Cocoa seconds. LrTasks.sleep(n) advances it and lets queued tasks
                (publishes started by publishNow) run, like Lightroom's cooperative scheduler.
  LrFileUtils   the real file system (of the harness container). exists() also finds a name spelled
                in decomposed Unicode (NFD) when the disk has it composed (NFC), as macOS does on an
                SMB share.
  Catalog       photos, write gates (withWriteAccessDo / withPrivateWriteAccessDo; nesting is an
                error; catalog writes outside a gate are errors), publish services, published
                (smart) collections with a small searchDesc interpreter, published photo records.
  publishNow    queued; when it runs: removals (deletePhotosFromPublishedCollection) first, then
                processRenderedPhotos with an export session/context/renditions. A run with any
                uploadFailed ends with one failure dialog, as Lightroom does.
Everything a user would see (dialogs, bezels) and every HTTP request is recorded for assertions.
]]

local SDK = {}

SDK.verbose = os.getenv('VERBOSE') == '1'
SDK.tmpDir = os.getenv('HARNESS_TMP') or '/tmp/lrsdk'
os.execute("mkdir -p '" .. SDK.tmpDir .. "'")

SDK.now = 814855365 -- Cocoa seconds (2026-10-27)
SDK.dialogs = {}    -- { kind=, title=, text= }
SDK.bezels = {}
SDK.logLines = {}
SDK.http = {}       -- { method=, url=, path=, status=, rc=, fields=, body= }
SDK.errors = {}     -- Lua errors that escaped plugin code: { where=, err= }
SDK.problems = {}   -- SDK misuse the fake detected but that didn't raise
SDK.renders = {}    -- { photo=, ok=, path=, content= }
SDK.runs = {}       -- publish runs (see runPublish)
SDK.pending = {}    -- queued tasks
SDK.counters = { publishNow = 0, sleeps = 0, smartCreated = 0, imports = 0, writeGates = 0, privateGates = 0 }
SDK.sleepHook = nil -- function(n) called after each LrTasks.sleep
SDK.httpHook = nil  -- function(method, url) called before each request
SDK.renderHook = nil -- function(photo) called as each render starts
SDK.developHook = nil -- function(photo) called by photo:getDevelopSettings()
SDK.unmounted = {}   -- folders that look gone to the plugin, like a dropped share (the NAS still has them)

-------------------------------------------------------------------------------------------------
-- Small helpers

local function q(s) return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'" end
SDK.q = q

function SDK.shell(cmd)
	local p = assert(io.popen(cmd, 'r'))
	local out = p:read('*a')
	p:close()
	return out
end

local seq = 0
local function tmpPath(suffix)
	seq = seq + 1
	return string.format('%s/%d-%s', SDK.tmpDir, seq, suffix or 'tmp')
end
SDK.tmpPath = tmpPath

function SDK.readFile(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local d = f:read('*a')
	f:close()
	return d
end

function SDK.writeFile(path, data)
	local f = assert(io.open(path, 'wb'))
	f:write(data)
	f:close()
end

function SDK.fileKind(path)
	local out = SDK.shell('if [ -d ' .. q(path) .. ' ]; then echo d; elif [ -e ' .. q(path) .. ' ]; then echo f; fi')
	if out:find('d', 1, true) then return 'directory' end
	if out:find('f', 1, true) then return 'file' end
	return false
end

-- A few decomposed sequences and their composed forms; enough for the harness's names.
local NFD_TO_NFC = {
	{ 'e\204\129', '\195\169' }, { 'E\204\129', '\195\137' }, { 'a\204\128', '\195\160' },
	{ 'u\204\136', '\195\188' }, { 'o\204\136', '\195\182' }, { 'n\204\131', '\195\177' },
}
function SDK.toNFC(s)
	for _, pair in ipairs(NFD_TO_NFC) do s = (s:gsub(pair[1], pair[2])) end
	return s
end

function SDK.exists(path)
	if type(path) ~= 'string' or path == '' then return false end
	for _, gone in ipairs(SDK.unmounted) do
		if path == gone or path:sub(1, #gone + 1) == gone .. '/' then return false end
	end
	local kind = SDK.fileKind(path)
	if not kind then
		local alt = SDK.toNFC(path)
		if alt ~= path then kind = SDK.fileKind(alt) end
	end
	return kind
end

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end
local function icopy(t)
	local out = {}
	for i = 1, #(t or {}) do out[i] = t[i] end
	return out
end
local function deepcopy(v)
	if type(v) ~= 'table' then return v end
	local out = {}
	for k, x in pairs(v) do out[k] = deepcopy(x) end
	return out
end
SDK.copy, SDK.deepcopy = copy, deepcopy

local function serialize(v)
	if type(v) ~= 'table' then return tostring(v) end
	local keys = {}
	for k in pairs(v) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local out = {}
	for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. '=' .. serialize(v[k]) end
	return '{' .. table.concat(out, ',') .. '}'
end

function SDK.log(fmt, ...)
	local ok, msg = pcall(string.format, fmt, ...)
	msg = ok and msg or tostring(fmt)
	SDK.logLines[#SDK.logLines + 1] = msg
	if SDK.verbose then print('      [sdk] ' .. msg) end
end

function SDK.luaError(where, err)
	SDK.errors[#SDK.errors + 1] = { where = where, err = tostring(err) }
	print('      [LUA ERROR in ' .. where .. '] ' .. tostring(err))
end

function SDK.problem(msg)
	SDK.problems[#SDK.problems + 1] = msg
	print('      [SDK MISUSE] ' .. msg)
end

function SDK.dialog(kind, title, text)
	SDK.dialogs[#SDK.dialogs + 1] = { kind = kind, title = title, text = text }
	if SDK.verbose then print(string.format('      [dialog:%s] %s: %s', kind, tostring(title), tostring(text))) end
end

function SDK.advance(seconds) SDK.now = SDK.now + seconds end

-------------------------------------------------------------------------------------------------
-- Tasks and function contexts

function SDK.runTask(name, f)
	local ok, err = xpcall(f, debug.traceback)
	if not ok then SDK.luaError('task "' .. tostring(name) .. '"', err) end
	return ok
end

local draining = false
function SDK.runPending()
	if draining then return end
	draining = true
	while #SDK.pending > 0 do
		local t = table.remove(SDK.pending, 1)
		SDK.runTask(t.name, t.fn)
	end
	draining = false
end

local function newFunctionContext()
	local ctx = { cleanup = {}, failure = {} }
	function ctx:addCleanupHandler(f) self.cleanup[#self.cleanup + 1] = f end
	function ctx:addFailureHandler(f) self.failure[#self.failure + 1] = f end
	return ctx
end

function SDK.callWithContext(name, f, ...)
	local args = { n = select('#', ...), ... }
	local ctx = newFunctionContext()
	local res = { xpcall(function() return f(ctx, unpack(args, 1, args.n)) end, debug.traceback) }
	if not res[1] then
		for _, h in ipairs(ctx.failure) do pcall(h, false, res[2]) end
	end
	for i = #ctx.cleanup, 1, -1 do pcall(ctx.cleanup[i], res[1], res[2]) end
	if not res[1] then error(res[2], 0) end
	return unpack(res, 2)
end

-------------------------------------------------------------------------------------------------
-- LrHttp through curl

local CURL_ERR = {
	[6] = 'cannotFindHost', [7] = 'cannotConnectToHost', [28] = 'timedOut',
	[52] = 'networkConnectionLost', [55] = 'networkConnectionLost', [56] = 'networkConnectionLost',
}

local function curl(method, url, extra, headers, timeout, fields)
	if SDK.httpHook then SDK.httpHook(method, url, fields) end
	local bodyFile, errFile = tmpPath('resp'), tmpPath('err')
	local t = math.floor(math.min(math.max(tonumber(timeout) or 30, 1), 120))
	local args = { 'curl', '-sS', '-o', q(bodyFile), '-w', q('%{http_code}'), '-m', tostring(t), '-X', method }
	for _, h in ipairs(headers or {}) do
		if type(h) ~= 'table' or type(h.field) ~= 'string' then error('LrHttp: headers must be an array of { field=, value= }', 3) end
		args[#args + 1] = '-H'
		args[#args + 1] = q(h.field .. ': ' .. tostring(h.value))
	end
	for _, a in ipairs(extra) do args[#args + 1] = a end
	args[#args + 1] = q(url)
	local out = SDK.shell(table.concat(args, ' ') .. ' 2>' .. q(errFile) .. '; echo " rc=$?"')
	local code, rc = out:match('(%d*)%s*rc=(%d+)')
	rc = tonumber(rc)
	local status = tonumber(code)
	local body = SDK.readFile(bodyFile)
	local err = SDK.readFile(errFile) or ''
	os.remove(bodyFile)
	os.remove(errFile)
	local entry = { method = method, url = url, path = url:match('^https?://[^/]+(/[^?]*)'), status = status, rc = rc, fields = fields, t = SDK.now, body = body }
	SDK.http[#SDK.http + 1] = entry
	if SDK.verbose then print(string.format('      [http] %s %s -> %s (rc %s)', method, url, tostring(status), tostring(rc))) end
	if rc ~= 0 or not status or status == 0 then
		entry.status = nil
		local msg = err:gsub('%s+$', '')
		if msg == '' then msg = 'curl exit ' .. tostring(rc) end
		return nil, { error = { errorCode = CURL_ERR[rc] or 'unknown', name = msg, nativeCode = rc } }
	end
	return body or '', { status = status }
end

local LrHttp = {}
function LrHttp.post(url, postBody, headers, method, timeout)
	local f = tmpPath('req')
	SDK.writeFile(f, postBody or '')
	local fields = nil
	local body, hdrs = curl(method or 'POST', url, { '--data-binary', q('@' .. f) }, headers, timeout, { body = postBody })
	os.remove(f)
	return body, hdrs
end
function LrHttp.get(url, headers, timeout)
	return curl('GET', url, {}, headers, timeout)
end
function LrHttp.postMultipart(url, content, headers, timeout)
	local extra, fields = {}, {}
	for _, part in ipairs(content or {}) do
		if type(part.name) ~= 'string' then error('LrHttp.postMultipart: each part needs a name', 2) end
		if part.filePath then
			if not SDK.fileKind(part.filePath) then error('LrHttp.postMultipart: no file at ' .. tostring(part.filePath), 2) end
			local fileName = part.fileName or part.filePath:match('[^/]+$')
			extra[#extra + 1] = '-F'
			extra[#extra + 1] = q(part.name .. '=@' .. part.filePath .. ';type=' .. (part.contentType or 'application/octet-stream') .. ';filename=' .. fileName)
			fields[part.name] = { filePath = part.filePath, bytes = SDK.readFile(part.filePath) }
		else
			if part.value == nil then error('LrHttp.postMultipart: part ' .. part.name .. ' has no value', 2) end
			extra[#extra + 1] = '--form-string'
			extra[#extra + 1] = q(part.name .. '=' .. tostring(part.value))
			fields[part.name] = tostring(part.value)
		end
	end
	return curl('POST', url, extra, headers, timeout, fields)
end

-------------------------------------------------------------------------------------------------
-- Namespaces

local LrDate = {}
function LrDate.currentTime() return SDK.now end
function LrDate.timeToUserFormat(t, fmt) return os.date('!' .. (fmt or '%Y-%m-%d %H:%M:%S'), math.floor(t + 978307200)) end

local LrTasks = {}
LrTasks.pcall = pcall
function LrTasks.sleep(n)
	SDK.now = SDK.now + (tonumber(n) or 0)
	SDK.counters.sleeps = SDK.counters.sleeps + 1
	SDK.runPending()
	if SDK.sleepHook then SDK.sleepHook(n) end
end
function LrTasks.yield() SDK.runPending() end
function LrTasks.canYield() return true end
function LrTasks.startAsyncTask(f, name) SDK.runTask(name or 'startAsyncTask', f) end

local LrFunctionContext = {}
LrFunctionContext.callWithContext = SDK.callWithContext
function LrFunctionContext.postAsyncTaskWithContext(name, f)
	SDK.runTask(name, function() SDK.callWithContext(name, f) end)
end

local LrFileUtils = {}
function LrFileUtils.exists(path) return SDK.exists(path) end
function LrFileUtils.delete(path)
	local ok = os.remove(path)
	return ok and true or false
end
function LrFileUtils.isReadable(path) return SDK.exists(path) == 'file' end

SDK.prefs = {}
local LrPrefs = { prefsForPlugin = function() return SDK.prefs end }

local function newLogger(name)
	local l = { name = name }
	function l:enable() end
	local function emit(_, ...)
		local parts = {}
		for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
		SDK.log('%s: %s', name, table.concat(parts, ' '))
	end
	l.info, l.trace, l.debug, l.warn, l.error = emit, emit, emit, emit, emit
	function l:infof(fmt, ...) emit(self, string.format(fmt, ...)) end
	return l
end
local LrLogger = setmetatable({}, { __call = function(_, name) return newLogger(name) end })

local LrDialogs = {}
function LrDialogs.message(title, text, style) SDK.dialog('message', title, text) end
function LrDialogs.showError(err) SDK.dialog('error', 'Error', tostring(err)) end
function LrDialogs.confirm(title, text) SDK.dialog('confirm', title, text); return 'ok' end
function LrDialogs.showBezel(msg, secs) SDK.bezels[#SDK.bezels + 1] = msg end
function LrDialogs.runOpenPanel(args) SDK.dialog('openPanel', args and args.title, ''); return nil end
function LrDialogs.attachErrorDialogToFunctionContext() end

local LrMD5 = {}
function LrMD5.digest(s)
	local f = tmpPath('md5')
	SDK.writeFile(f, s)
	local out = SDK.shell('md5sum ' .. q(f))
	os.remove(f)
	return (out:match('^(%x+)'))
end

local LrSystemInfo = { computerName = function() return 'TestMac' end }

local LrView = {}
function LrView.bind(x) return { bind = x } end
function LrView.share(x) return { share = x } end
function LrView.osFactory()
	return setmetatable({}, { __index = function(_, kind)
		return function(_, args) local t = copy(args); t._kind = kind; return t end
	end })
end

local LrApplication = { activeCatalog = function() return SDK.catalog end }

SDK.namespaces = {
	LrApplication = LrApplication, LrDate = LrDate, LrDialogs = LrDialogs, LrFileUtils = LrFileUtils,
	LrFunctionContext = LrFunctionContext, LrHttp = LrHttp, LrLogger = LrLogger, LrMD5 = LrMD5,
	LrPrefs = LrPrefs, LrSystemInfo = LrSystemInfo, LrTasks = LrTasks, LrView = LrView,
}

-------------------------------------------------------------------------------------------------
-- Smart collection rules

local CRITERIA = {
	hasAdjustments = { ops = { isTrue = true, isFalse = true }, get = function(p) return p._hasAdjustments == true end },
	cropped = { ops = { isTrue = true, isFalse = true }, get = function(p) return p._cropped == true end },
	fileFormat = {
		ops = { ['=='] = true, ['!='] = true },
		values = { RAW = true, DNG = true, JPG = true, TIFF = true, PSD = true, PNG = true, HEIC = true, VIDEO = true },
		get = function(p) return p._fileFormat end,
	},
}

local function validateSearch(desc, where)
	where = where or 'searchDesc'
	if type(desc) ~= 'table' then error(where .. ' is not a table', 0) end
	if desc.criteria ~= nil then
		local c = CRITERIA[desc.criteria]
		if not c then error(where .. ': criteria ' .. tostring(desc.criteria) .. ' is not supported by the fake', 0) end
		if not c.ops[desc.operation] then error(where .. ': operation ' .. tostring(desc.operation) .. ' is not valid for ' .. desc.criteria, 0) end
		if c.values and not c.values[desc.value] then error(where .. ': value ' .. tostring(desc.value) .. ' is not valid for ' .. desc.criteria, 0) end
		return
	end
	local combine = desc.combine or 'intersect'
	if combine ~= 'union' and combine ~= 'intersect' and combine ~= 'exclude' then error(where .. ': combine ' .. tostring(combine), 0) end
	if #desc == 0 then error(where .. ': empty group', 0) end
	for i = 1, #desc do validateSearch(desc[i], where .. '[' .. i .. ']') end
end

local function matches(p, desc)
	if desc.criteria ~= nil then
		local v = CRITERIA[desc.criteria].get(p)
		local op = desc.operation
		if op == 'isTrue' then return v == true end
		if op == 'isFalse' then return v == false end
		if op == '==' then return v == desc.value end
		if op == '!=' then return v ~= desc.value end
		return false
	end
	local combine = desc.combine or 'intersect'
	if combine == 'union' then
		for i = 1, #desc do if matches(p, desc[i]) then return true end end
		return false
	elseif combine == 'intersect' then
		for i = 1, #desc do if not matches(p, desc[i]) then return false end end
		return true
	end
	-- exclude: the first and none of the others
	if not matches(p, desc[1]) then return false end
	for i = 2, #desc do if matches(p, desc[i]) then return false end end
	return true
end
SDK.matches = matches

-------------------------------------------------------------------------------------------------
-- Photos

local Photo = {}
Photo.__index = Photo

local FORMAT_BY_EXT = {
	raf = 'RAW', nef = 'RAW', cr2 = 'RAW', cr3 = 'RAW', arw = 'RAW', orf = 'RAW', rw2 = 'RAW',
	dng = 'DNG', jpg = 'JPG', jpeg = 'JPG', tif = 'TIFF', tiff = 'TIFF', psd = 'PSD', png = 'PNG', heic = 'HEIC',
}

local RAW_KEYS = {
	path = function(p) return p._path end,
	uuid = function(p) return p._uuid end,
	lastEditTime = function(p) return p._lastEditTime end,
	fileFormat = function(p) return p._fileFormat end,
	isVirtualCopy = function(p) return p._isVirtualCopy end,
	masterPhoto = function(p) return p._master end,
	gps = function(p) return p._gps end,
	croppedDimensions = function(p) return p._croppedDims or { width = 6000, height = 4000 } end,
	dateTimeOriginal = function(p) return p._dateTimeOriginal end,
	rating = function(p) return p._rating end,
	fileName = function(p) return p._path:match('[^/]+$') end,
}
local FORMATTED_KEYS = {
	copyName = true, title = true, caption = true, keywordTagsForExport = true, copyright = true,
	creator = true, headline = true, location = true, city = true, stateProvince = true, country = true,
	fileName = true, folderName = true,
	-- the rest of what the plugin's fingerprint reads; all exist in the real SDK
	copyrightState = true, rightsUsageTerms = true, copyrightInfoUrl = true, creatorJobTitle = true,
	creatorAddress = true, creatorCity = true, creatorStateProvince = true, creatorPostalCode = true,
	creatorCountry = true, creatorPhone = true, creatorEmail = true, creatorUrl = true,
	isoCountryCode = true, dateCreated = true, label = true, rating = true,
}

function Photo:getRawMetadata(key)
	local f = RAW_KEYS[key]
	if not f then error('LrPhoto:getRawMetadata: unknown key ' .. tostring(key), 2) end
	return f(self)
end
function Photo:getFormattedMetadata(key)
	if not FORMATTED_KEYS[key] then error('LrPhoto:getFormattedMetadata: unknown key ' .. tostring(key), 2) end
	if key == 'copyName' then return self._isVirtualCopy and self._copyName or nil end
	if key == 'fileName' then return self._path:match('[^/]+$') end
	if key == 'folderName' then return self._path:match('([^/]+)/[^/]+$') end
	return self._meta[key]
end
function Photo:getDevelopSettings()
	if SDK.developHook then SDK.developHook(self) end
	return deepcopy(self._develop)
end

-------------------------------------------------------------------------------------------------
-- Catalog

local Catalog = {}
Catalog.__index = Catalog
local Collection = {}
Collection.__index = Collection
local Service = {}
Service.__index = Service
local PublishedCollection = {}
PublishedCollection.__index = PublishedCollection
local PublishedPhoto = {}
PublishedPhoto.__index = PublishedPhoto

function SDK.newCatalog(path)
	local c = setmetatable({ _path = path, _photos = {}, _services = {}, _collections = {}, _gate = nil, _nextId = 1000 }, Catalog)
	SDK.catalog = c
	return c
end

function Catalog:_id()
	self._nextId = self._nextId + 1
	return self._nextId
end

function Catalog:_requireGate(what, privateOk)
	if not self._gate then error(what .. ' must be called inside catalog:withWriteAccessDo', 3) end
	if self._gate == 'private' and not privateOk then error(what .. ' cannot be called inside withPrivateWriteAccessDo', 3) end
end

function Catalog:_newPhoto(spec)
	local p = setmetatable({}, Photo)
	p.localIdentifier = self:_id()
	p._catalog = self
	p._path = spec.path
	p._uuid = spec.uuid or string.format('F00D%04X-0000-4000-8000-%012X', p.localIdentifier % 65536, p.localIdentifier)
	p._fileFormat = spec.fileFormat or FORMAT_BY_EXT[(spec.path:match('%.([^./]+)$') or ''):lower()] or 'RAW'
	p._hasAdjustments = spec.hasAdjustments or false
	p._cropped = spec.cropped or false
	p._isVirtualCopy = spec.isVirtualCopy or false
	p._copyName = spec.copyName
	p._master = spec.master
	p._develop = deepcopy(spec.develop or {})
	p._meta = deepcopy(spec.meta or {})
	p._gps = spec.gps
	p._lastEditTime = spec.lastEditTime or SDK.now
	p._renderFail = spec.renderFail
	p._name = spec.name or (p._path:match('[^/]+$') .. (p._isVirtualCopy and (' [' .. tostring(p._copyName) .. ']') or ''))
	self._photos[#self._photos + 1] = p
	return p
end

function Catalog:getPath() return self._path end

function Catalog:withWriteAccessDo(actionName, func, timeoutParams)
	if type(actionName) ~= 'string' then error('withWriteAccessDo: the first argument is the action name', 2) end
	if self._gate then error('withWriteAccessDo: another write access gate is open (nested call)', 2) end
	self._gate = 'write'
	SDK.counters.writeGates = SDK.counters.writeGates + 1
	local ok, err = xpcall(function() func({}) end, debug.traceback)
	self._gate = nil
	if not ok then error(err, 0) end
	return 'executed'
end

function Catalog:withPrivateWriteAccessDo(func, timeoutParams)
	if type(func) ~= 'function' then error('withPrivateWriteAccessDo: the first argument is the function', 2) end
	if self._gate then error('withPrivateWriteAccessDo: another write access gate is open (nested call)', 2) end
	self._gate = 'private'
	SDK.counters.privateGates = SDK.counters.privateGates + 1
	local ok, err = xpcall(function() func({}) end, debug.traceback)
	self._gate = nil
	if not ok then error(err, 0) end
	return 'executed'
end

function Catalog:getPublishServices(pluginId)
	local out = {}
	for _, s in ipairs(self._services) do
		if pluginId == nil or s._pluginId == pluginId then out[#out + 1] = s end
	end
	return out
end

function Catalog:getAllPhotos()
	local out = {}
	for _, p in ipairs(self._photos) do if not p._removed then out[#out + 1] = p end end
	return out
end

function Catalog:batchGetRawMetadata(photos, keys)
	local out = {}
	for _, p in ipairs(photos) do
		local m = {}
		for _, k in ipairs(keys) do m[k] = p:getRawMetadata(k) end
		out[p] = m
	end
	return out
end

function Catalog:batchGetFormattedMetadata(photos, keys)
	local out = {}
	for _, p in ipairs(photos) do
		local m = {}
		for _, k in ipairs(keys) do m[k] = p:getFormattedMetadata(k) end
		out[p] = m
	end
	return out
end

function Catalog:findPhotoByPath(path, caseSensitive)
	for _, p in ipairs(self._photos) do
		if not p._removed and not p._isVirtualCopy then
			if p._path == path or (caseSensitive == false and p._path:lower() == tostring(path):lower()) then return p end
		end
	end
	return nil
end

-- Import: reads <stem>.xmp the way Lightroom does when it adds a RAW with a sidecar.
function Catalog:addPhoto(path)
	self:_requireGate('catalog:addPhoto')
	if SDK.exists(path) ~= 'file' then error('catalog:addPhoto: no file at ' .. tostring(path), 2) end
	if self:findPhotoByPath(path) then error('catalog:addPhoto: the photo is already in the catalog', 2) end
	local stem = path:gsub('%.[^./]*$', '')
	local xmp = SDK.readFile(stem .. '.xmp') or SDK.readFile(stem .. '.XMP')
	local has = xmp and (xmp:find('crs:HasSettings%s*=%s*["\']True["\']') or xmp:find('<crs:HasSettings>%s*True%s*</crs:HasSettings>'))
	local p = self:_newPhoto {
		path = path,
		hasAdjustments = has and true or false,
		develop = has and { Exposure2012 = 0.25, fromXmp = true } or {},
		lastEditTime = SDK.now,
	}
	SDK.counters.imports = SDK.counters.imports + 1
	return p
end

function Catalog:createCollection(name, parent, canReturnPrior)
	self:_requireGate('catalog:createCollection')
	for _, c in ipairs(self._collections) do
		if c._name == name then
			if canReturnPrior then return c end
			return nil
		end
	end
	local c = setmetatable({ localIdentifier = self:_id(), _name = name, _catalog = self, _members = {} }, Collection)
	self._collections[#self._collections + 1] = c
	return c
end

function Catalog:getChildCollections() return icopy(self._collections) end

function Catalog:getPublishedCollectionByLocalIdentifier(id)
	for _, s in ipairs(self._services) do
		for _, c in ipairs(s._children) do
			if c.localIdentifier == id then return c end
		end
	end
	return nil
end

-- Regular (catalog) collections
function Collection:getName() return self._name end
function Collection:getPhotos() return icopy(self._members) end
function Collection:addPhotos(photos)
	self._catalog:_requireGate('LrCollection:addPhotos')
	for _, p in ipairs(photos) do
		local found = false
		for _, m in ipairs(self._members) do if m == p then found = true end end
		if not found then self._members[#self._members + 1] = p end
	end
end
function Collection:removePhotos(photos)
	self._catalog:_requireGate('LrCollection:removePhotos')
	for _, p in ipairs(photos) do
		for i = #self._members, 1, -1 do if self._members[i] == p then table.remove(self._members, i) end end
	end
end

-------------------------------------------------------------------------------------------------
-- Publish services and published collections

-- What Lightroom hands the provider as exportContext.propertyTable / publishSettings: an
-- observable property table. Its raw table holds '< contents >'; reading a key goes through
-- __index.
local function propertyTable(values)
	local contents = copy(values)
	return setmetatable({ ['< contents >'] = contents }, { __index = contents, __newindex = contents })
end
SDK.propertyTable = propertyTable

-- opts: { pluginId=, name=, provider=, settings=, settingsShape = nil | 'contents' | 'prefixed' }
function SDK.newService(catalog, opts)
	local s = setmetatable({
		localIdentifier = catalog:_id(), _catalog = catalog, _pluginId = opts.pluginId, _name = opts.name,
		_provider = opts.provider, _settings = copy(opts.settings), _children = {}, settingsShape = opts.settingsShape,
	}, Service)
	catalog._services[#catalog._services + 1] = s
	local info = opts.provider and opts.provider.getCollectionBehaviorInfo and opts.provider.getCollectionBehaviorInfo(propertyTable(s._settings))
	if info and info.defaultCollectionName then
		s:_newCollection(info.defaultCollectionName, false)
	end
	return s
end

function Service:_newCollection(name, smart, searchDesc)
	local c = setmetatable({
		localIdentifier = self._catalog:_id(), _service = self, _name = name, _smart = smart,
		_search = searchDesc, _members = {}, _records = {},
	}, PublishedCollection)
	self._children[#self._children + 1] = c
	return c
end

function Service:getPluginId() return self._pluginId end
function Service:getName() return self._name end
function Service:getChildCollections() return icopy(self._children) end
function Service:getChildCollectionSets() return {} end
function Service:getPublishedPhotos()
	local out = {}
	for _, c in ipairs(self._children) do
		for _, r in ipairs(c._records) do out[#out + 1] = r end
	end
	return out
end

-- A plain table by default. settingsShape 'contents' returns it the way it has been seen wrapped
-- ({ ['< contents >'] = {...} }), 'prefixed' with the plugin's own keys prefixed '<pluginId>_'.
function Service:getPublishSettings()
	local plain = copy(self._settings)
	if self.settingsShape == 'contents' then
		return { ['< contents >'] = plain }
	elseif self.settingsShape == 'prefixed' then
		local out = {}
		for k, v in pairs(plain) do
			if k:sub(1, 2) == 'np' then out[self._pluginId .. '_' .. k] = v else out[k] = v end
		end
		return out
	end
	return plain
end

function Service:createPublishedCollection(name, parent, canReturnPrior)
	self._catalog:_requireGate('LrPublishService:createPublishedCollection')
	for _, c in ipairs(self._children) do
		if c._name == name then return canReturnPrior and c or nil end
	end
	return self:_newCollection(name, false)
end

function Service:createPublishedSmartCollection(name, searchDesc, parent, canReturnPrior)
	self._catalog:_requireGate('LrPublishService:createPublishedSmartCollection')
	for _, c in ipairs(self._children) do
		if c._name == name then return canReturnPrior and c or nil end
	end
	validateSearch(searchDesc)
	SDK.counters.smartCreated = SDK.counters.smartCreated + 1
	return self:_newCollection(name, true, deepcopy(searchDesc))
end

function PublishedCollection:getName() return self._name end
function PublishedCollection:getService() return self._service end
function PublishedCollection:isSmartCollection() return self._smart and true or false end
function PublishedCollection:getSearchDescription() return deepcopy(self._search) end
function PublishedCollection:getPhotos()
	local out = {}
	if self._smart then
		for _, p in ipairs(self._service._catalog._photos) do
			if not p._removed and matches(p, self._search) then out[#out + 1] = p end
		end
	else
		for _, p in ipairs(self._members) do if not p._removed then out[#out + 1] = p end end
	end
	return out
end
function PublishedCollection:addPhotos(photos)
	if self._smart then error('addPhotos: smart collection', 2) end
	self._service._catalog:_requireGate('LrPublishedCollection:addPhotos')
	for _, p in ipairs(photos) do
		local found = false
		for _, m in ipairs(self._members) do if m == p then found = true end end
		if not found then self._members[#self._members + 1] = p end
	end
end
function PublishedCollection:removePhotos(photos)
	self._service._catalog:_requireGate('LrPublishedCollection:removePhotos')
	for _, p in ipairs(photos) do
		for i = #self._members, 1, -1 do if self._members[i] == p then table.remove(self._members, i) end end
	end
end
function PublishedCollection:getPublishedPhotos() return icopy(self._records) end
function PublishedCollection:_record(photo)
	for _, r in ipairs(self._records) do if r._photo == photo then return r end end
	return nil
end

function PublishedCollection:publishNow(doneCallback)
	SDK.counters.publishNow = SDK.counters.publishNow + 1
	local coll = self
	SDK.pending[#SDK.pending + 1] = { name = 'publish ' .. self._name, fn = function() SDK.runPublish(coll, doneCallback) end }
end

function PublishedPhoto:getPhoto() return self._photo end
function PublishedPhoto:getRemoteId() return self._remoteId end
function PublishedPhoto:getRemoteUrl() return self._remoteUrl end
function PublishedPhoto:getEditedFlag() return self._edited end
function PublishedPhoto:getPublishCount() return self._publishCount end
function PublishedPhoto:getPublishedCollection() return self._coll end
function PublishedPhoto:setEditedFlag(flag)
	self._coll._service._catalog:_requireGate('LrPublishedPhoto:setEditedFlag', true)
	self._edited = flag and true or false
end

local function newRecord(coll, photo)
	return setmetatable({ _coll = coll, _photo = photo, _remoteId = nil, _edited = false, _publishCount = 0 }, PublishedPhoto)
end

-------------------------------------------------------------------------------------------------
-- A publish run, the way Lightroom drives the provider

local function jpegFor(photo)
	return '\255\216\255\224\0\16JFIF\0' .. string.format('harness photo=%d uuid=%s edit=%.3f dev=%s ', photo.localIdentifier,
		photo._uuid, photo._lastEditTime, serialize(photo._develop)) .. string.rep('x', 64) .. '\255\217'
end
SDK.jpegFor = jpegFor

local function newRendition(run, coll, photo)
	local rec = coll:_record(photo)
	local r = { photo = photo, publishedPhotoId = rec and rec._remoteId or nil }
	function r:skipRender()
		if self._rendered then SDK.problem('skipRender() after waitForRender() for ' .. photo._name) end
		-- The SDK: "Must be called before the export session starts its rendering loop."
		if run.renderLoopStarted then SDK.problem('skipRender() after the rendering loop started, for ' .. photo._name) end
		self._skipped = true
		self.wasSkipped = true
	end
	function r:waitForRender()
		if self._skipped then return true, nil end
		if self._rendered then return self._ok, self._result end
		self._rendered = true
		run.rendered[#run.rendered + 1] = photo
		if SDK.renderHook then SDK.renderHook(photo) end
		-- Like Lightroom: no original, no render (smart previews aside, see scenario 18).
		local failure = photo._renderFail or (not SDK.exists(photo._path) and 'File not found.') or nil
		if failure then
			self._ok, self._result = false, failure
			SDK.renders[#SDK.renders + 1] = { photo = photo, ok = false }
			return false, failure
		end
		local content = photo._renderBytes or jpegFor(photo)
		local path = tmpPath('render.jpg')
		SDK.writeFile(path, content)
		SDK.renders[#SDK.renders + 1] = { photo = photo, ok = true, path = path, content = content }
		self._ok, self._result = true, path
		return true, path
	end
	function r:recordPublishedPhotoId(id)
		if type(id) ~= 'string' or id == '' then SDK.problem('recordPublishedPhotoId(' .. tostring(id) .. ') for ' .. photo._name) end
		local existing = coll:_record(photo)
		if not existing then
			existing = newRecord(coll, photo)
			coll._records[#coll._records + 1] = existing
		end
		existing._remoteId = id
		existing._edited = false
		existing._publishCount = existing._publishCount + 1
		run.recorded[#run.recorded + 1] = { photo = photo, id = id }
	end
	function r:recordPublishedPhotoUrl(url) local e = coll:_record(photo); if e then e._remoteUrl = url end end
	function r:uploadFailed(msg) run.uploadFailed[#run.uploadFailed + 1] = { photo = photo, msg = tostring(msg) } end
	return r
end

local function newSession(run, photos)
	local s = { _photos = icopy(photos), _started = false }
	-- Like Lightroom: an iterator over (index, photo), not a table.
	function s:photosToExport()
		local list, i = icopy(self._photos), 0
		return function()
			i = i + 1
			if list[i] then return i, list[i] end
		end
	end
	function s:countRenditions() return #self._photos end
	function s:removePhoto(photo)
		if self._started then error('LrExportSession:removePhoto: rendering has already started', 2) end
		for i, p in ipairs(self._photos) do
			if p == photo then
				table.remove(self._photos, i)
				run.removedFromSession[#run.removedFromSession + 1] = photo
				return
			end
		end
		SDK.problem('removePhoto for a photo that is not in the session: ' .. tostring(photo and photo._name))
	end
	return s
end

-- One set of rendition objects per session: a pre-pass over exportSession:renditions() (to
-- skipRender some) sees the same objects as the rendering loop that follows.
local function renditionsIterator(run, coll, session, startsRendering)
	session._started = true
	if startsRendering then run.renderLoopStarted = true end
	if not session._renditionList then
		session._renditionList = {}
		for _, p in ipairs(session._photos) do session._renditionList[#session._renditionList + 1] = newRendition(run, coll, p) end
	end
	local list = session._renditionList
	run.renditionCount = #list
	local i = 0
	return function()
		i = i + 1
		if list[i] then return i, list[i] end
	end
end

function SDK.runPublish(coll, doneCallback)
	local service = coll._service
	local provider = service._provider
	local run = {
		coll = coll, removalIds = {}, acked = {}, uploadFailed = {}, recorded = {}, removedFromSession = {},
		rendered = {}, toPublish = {}, autoRun = nil, at = SDK.now,
	}
	SDK.runs[#SDK.runs + 1] = run
	local members = coll:getPhotos()
	local isMember = {}
	for _, p in ipairs(members) do isMember[p] = true end

	-- Removals first: photos that left the collection.
	local keep = {}
	for _, r in ipairs(coll._records) do
		if isMember[r._photo] or r._remoteId then keep[#keep + 1] = r end
	end
	coll._records = keep
	for _, r in ipairs(coll._records) do
		if not isMember[r._photo] then run.removalIds[#run.removalIds + 1] = r._remoteId end
	end
	if #run.removalIds > 0 then
		local passed = {}
		for _, id in ipairs(run.removalIds) do passed[id] = true end
		local ok, err = xpcall(function()
			provider.deletePhotosFromPublishedCollection(propertyTable(service._settings), icopy(run.removalIds), function(id)
				if not passed[id] then SDK.problem('deletedCallback(' .. tostring(id) .. '): not an id Lightroom passed') end
				run.acked[id] = true
			end, coll.localIdentifier)
		end, debug.traceback)
		if not ok then
			SDK.luaError('deletePhotosFromPublishedCollection', err)
			SDK.dialog('error', 'Publish failed', err)
		end
		local rest = {}
		for _, r in ipairs(coll._records) do
			if isMember[r._photo] or not run.acked[r._remoteId] then rest[#rest + 1] = r end
		end
		coll._records = rest
	end

	-- Then the photos waiting to be published: new ones and modified ones.
	for _, p in ipairs(members) do
		local r = coll:_record(p)
		if not r or not r._remoteId or r._edited then run.toPublish[#run.toPublish + 1] = p end
	end
	if #run.toPublish > 0 then
		local session = newSession(run, run.toPublish)
		local exportContext = {
			propertyTable = propertyTable(service._settings),
			exportSession = session,
			publishService = service,
			publishedCollection = coll,
			publishedCollectionInfo = { name = coll._name, isDefaultCollection = coll == service._children[1] },
		}
		function exportContext:configureProgress(params)
			session._started = true
			run.renderLoopStarted = true
			run.progressTitle = params and params.title
			return { isCanceled = function() return false end, setPortionComplete = function() end, done = function() end }
		end
		function exportContext:renditions(params) return renditionsIterator(run, coll, session, true) end
		function exportContext:startRendering() session._started = true; run.renderLoopStarted = true end
		function session:renditions(params) return renditionsIterator(run, coll, session, false) end
		local ok, err = pcall(SDK.callWithContext, 'processRenderedPhotos', function(ctx)
			return provider.processRenderedPhotos(ctx, exportContext)
		end)
		if not ok then
			SDK.luaError('processRenderedPhotos', err)
			SDK.dialog('error', 'Publish failed', err)
		end
	end
	if #run.uploadFailed > 0 then
		local lines = {}
		for _, f in ipairs(run.uploadFailed) do lines[#lines + 1] = f.photo._name .. ': ' .. f.msg end
		SDK.dialog('publishFailures', string.format('%d photos failed to publish', #run.uploadFailed), table.concat(lines, '\n'))
	end
	if doneCallback then
		local ok, err = xpcall(doneCallback, debug.traceback)
		if not ok then SDK.luaError('publishNow doneCallback', err) end
	end
end

-------------------------------------------------------------------------------------------------
-- What the user does in Lightroom

-- A Develop or metadata edit: lastEditTime moves, and Lightroom flags the photo as modified
-- wherever it is published.
function SDK.edit(photo, changes)
	changes = changes or {}
	if changes.resetDevelop then photo._develop = {} end
	for k, v in pairs(changes.develop or {}) do photo._develop[k] = v end
	if changes.hasAdjustments ~= nil then photo._hasAdjustments = changes.hasAdjustments end
	if changes.cropped ~= nil then photo._cropped = changes.cropped end
	for k, v in pairs(changes.meta or {}) do photo._meta[k] = v end
	photo._lastEditTime = SDK.now
	SDK.flagModified(photo)
end

-- Lightroom marks the photo "Modified Photos to Re-Publish" (also happens spuriously).
function SDK.flagModified(photo)
	for _, s in ipairs(photo._catalog._services) do
		for _, c in ipairs(s._children) do
			local r = c:_record(photo)
			if r and r._remoteId then r._edited = true end
		end
	end
end

-- The RAW moved to another folder (Folders panel or Synchronize Folder): only the path changes.
function SDK.move(photo, newPath)
	photo._path = newPath
	for _, p in ipairs(photo._catalog._photos) do
		if p._master == photo then p._path = newPath end
	end
end

-- Renaming a virtual copy changes its copy name; Lightroom doesn't flag it (copyName isn't in
-- metadataThatTriggersRepublish).
function SDK.renameCopy(photo, name)
	photo._copyName = name
	photo._lastEditTime = SDK.now
end

-------------------------------------------------------------------------------------------------

function SDK.install(opts)
	_G._PLUGIN = { id = opts.pluginId, enabled = true, path = opts.pluginPath }
	_G.import = function(name)
		local ns = SDK.namespaces[name]
		if not ns then error('import: unknown namespace ' .. tostring(name), 2) end
		return ns
	end
end

return SDK
