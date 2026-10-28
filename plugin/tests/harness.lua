--[[ harness.lua
Integration test: runs NAS Publisher's real Lua (AutoPublisher, PublishServiceProvider, NasClient…)
outside Lightroom on a fake SDK (fake_lrsdk.lua) against a real lrc-nas-publisher container.
Run it with run_harness.sh, which starts the container and this script in Docker:

  lua5.1 harness.lua <plugin dir>
  env: NAS_URL, NAS_TOKEN, NAS_CONTAINER (for stopping/starting it through /var/run/docker.sock),
       NAS_ROOT (default /nas: source/, export/, config/ shared with the container at the same
       paths, so the plugin's "RAW folder on this Mac" is /nas/source, the container's SOURCE_DIR),
       VERBOSE=1 for SDK/HTTP traces, ONLY=<scenario number list> to pick scenarios (e.g. ONLY=1,2,3).

Each check prints ok/FAIL; the script exits 1 if any check failed or any Lua error escaped plugin
code. Scenarios build on each other (one catalog, one container), as a real session would.

Assumptions the fake makes (where the SDK documentation is silent or ambiguous):
  - publishNow() queues the publish; it runs while the caller sleeps (LrTasks.sleep), removals
    first, then processRenderedPhotos; doneCallback runs at the end, also when nothing was pending.
  - A published photo record exists once a photo was published in that collection (recorded id);
    photos added but never published have none. Records stay listed by getPublishedPhotos() while
    their removal is pending.
  - waitForRender() failing does not by itself produce a Lightroom dialog; uploadFailed() does
    (one dialog per run listing the failures).
  - exportContext.propertyTable / publishSettings are observable property tables (raw table holds
    '< contents >', keys read through __index); getPublishSettings() returns a plain table unless a
    scenario asks for the wrapped or prefixed shapes.
  - addPhoto() reads <stem>.xmp synchronously (crs:HasSettings="True" -> hasAdjustments), and the
    photo's lastEditTime is the import time.
  - macOS on an SMB share finds a file whatever Unicode normalization its name is spelled in.
]]

local pluginDir = arg[1] or '/p/NASPublisher.lrplugin'
local testsDir = arg[0]:match('^(.*)/[^/]*$') or '.'
package.path = pluginDir .. '/?.lua;' .. testsDir .. '/?.lua;' .. package.path

local SDK = require 'fake_lrsdk'
local PLUGIN_ID = 'com.kitsing.lrc.naspublisher'
SDK.install { pluginId = PLUGIN_ID, pluginPath = pluginDir }

local NAS_URL = os.getenv('NAS_URL') or 'http://lrcnas:8765'
local NAS_TOKEN = assert(os.getenv('NAS_TOKEN'), 'set NAS_TOKEN')
local NAS_CONTAINER = os.getenv('NAS_CONTAINER')
local ROOT = os.getenv('NAS_ROOT') or '/nas'
local SRC, EXP, CFG = ROOT .. '/source', ROOT .. '/export', ROOT .. '/config'
local q = SDK.q

local ONLY = nil
if os.getenv('ONLY') and os.getenv('ONLY') ~= '' then
	ONLY = {}
	for n in os.getenv('ONLY'):gmatch('[^,%s]+') do ONLY[n] = true end
end

local Json = require 'Json'
local State = require 'State'
local AutoPublisher = require 'AutoPublisher'
local provider = require 'PublishServiceProvider'

-------------------------------------------------------------------------------------------------
-- Checks

local results = { pass = 0, fail = 0, failures = {} }
local scenarioName = '?'

local function check(cond, what, detail)
	if cond then
		results.pass = results.pass + 1
		print('  ok    ' .. what)
	else
		results.fail = results.fail + 1
		results.failures[#results.failures + 1] = { scenario = scenarioName, what = what, detail = detail }
		print('  FAIL  ' .. what .. (detail and ('\n        -> ' .. tostring(detail)) or ''))
	end
	return cond
end

local function note(msg) print('  note  ' .. msg) end

-------------------------------------------------------------------------------------------------
-- Container, files and catalog helpers

local function mkfile(path, content, mtime)
	os.execute('mkdir -p ' .. q(path:match('^(.*)/[^/]*$')))
	SDK.writeFile(path, content or 'RAW')
	if mtime then os.execute('touch -d ' .. q(mtime) .. ' ' .. q(path)) end
end

local function exportFile(rel) return SDK.readFile(EXP .. '/' .. rel) end
local function exportKind(rel) return SDK.fileKind(EXP .. '/' .. rel) end

local function exportJpegs()
	local out = {}
	for line in SDK.shell('cd ' .. q(EXP) .. ' && find . -name "*.jpg" -type f | sort'):gmatch('[^\n]+') do
		out[#out + 1] = line:gsub('^%./', '')
	end
	return out
end

local function nasState()
	local s = SDK.readFile(CFG .. '/state.json')
	return s and Json.decode(s) or { photos = {}, events = {} }
end

local function eventCount(kinds)
	local set = {}
	for _, k in ipairs(kinds) do set[k] = true end
	local n = 0
	for _, e in ipairs(nasState().events or {}) do if set[e.kind] then n = n + 1 end end
	return n
end

local function httpCount(path, sinceIndex)
	local n = 0
	for i = (sinceIndex or 0) + 1, #SDK.http do
		if SDK.http[i].path == path then n = n + 1 end
	end
	return n
end

local function uploadsOf(rel, sinceIndex)
	local out = {}
	for i = (sinceIndex or 0) + 1, #SDK.http do
		local h = SDK.http[i]
		if h.path == '/api/photos' and h.fields and h.fields.rel == rel then out[#out + 1] = h end
	end
	return out
end

local function lastRender(photo)
	for i = #SDK.renders, 1, -1 do
		if SDK.renders[i].photo == photo and SDK.renders[i].ok then return SDK.renders[i] end
	end
	return nil
end

local function renderCount(photo)
	local n = 0
	for _, r in ipairs(SDK.renders) do if r.photo == photo then n = n + 1 end end
	return n
end

local function docker(method, path)
	return SDK.shell('curl -s -o /dev/null -w "%{http_code}" --unix-socket /var/run/docker.sock -X ' .. method .. ' '
		.. q('http://localhost' .. path))
end

local function nasHealthy()
	return SDK.shell('curl -s -o /dev/null -w "%{http_code}" -m 2 ' .. q(NAS_URL .. '/healthz')) == '200'
end

local function stopNas()
	assert(NAS_CONTAINER, 'NAS_CONTAINER not set')
	local code = docker('POST', '/containers/' .. NAS_CONTAINER .. '/stop?t=5')
	note('NAS container stopped (' .. code .. ')')
end

local function startNas()
	local code = docker('POST', '/containers/' .. NAS_CONTAINER .. '/start')
	for _ = 1, 80 do
		if nasHealthy() then
			note('NAS container started (' .. code .. ')')
			return true
		end
		os.execute('sleep 0.25')
	end
	error('the NAS container did not come back')
end

local function withWrite(f) return SDK.catalog:withWriteAccessDo('harness', f) end

local function childNamed(service, name)
	for _, c in ipairs(service:getChildCollections()) do
		if c:getName() == name then return c end
	end
	return nil
end

local function record(coll, photo) return coll and coll:_record(photo) end

local function isMember(coll, photo)
	for _, p in ipairs(coll:getPhotos()) do if p == photo then return true end end
	return false
end

local function lastRun() return SDK.runs[#SDK.runs] end

local function cycle(force)
	local ok, err = xpcall(function() AutoPublisher.cycle(force) end, debug.traceback)
	SDK.runPending()
	if not ok then SDK.luaError('AutoPublisher.cycle', err) end
	return ok
end

local function contains(s, sub) return type(s) == 'string' and s:find(sub, 1, true) ~= nil end

local function runScript(name)
	local f = assert(loadfile(pluginDir .. '/' .. name))
	local ok, err = xpcall(f, debug.traceback)
	if not ok then SDK.luaError(name, err) end
	SDK.runPending()
	return ok
end

-------------------------------------------------------------------------------------------------
-- The world

local XMP_EDITED = [[<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
 <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
  crs:Version="16.0" crs:Exposure2012="+0.25" crs:HasSettings="True"/>
</rdf:RDF></x:xmpmeta>
]]

local catalog = SDK.newCatalog('/Users/test/Pictures/Lightroom/Harness Catalog.lrcat')
local W = {} -- photos, service, collections shared between scenarios

local function serviceSettings()
	return {
		npNasUrl = NAS_URL, npToken = NAS_TOKEN, npSourceRoot = SRC, npAutoPublish = true,
		npSettleSeconds = 60, npImportSidecars = true, npDefaultsApplied = true,
		LR_format = 'JPEG', LR_jpeg_quality = 0.9, LR_export_colorSpace = 'sRGB',
		LR_size_doConstrain = false, LR_outputSharpeningOn = false,
	}
end

local F = 'DCIM/100_FUJI/'

-------------------------------------------------------------------------------------------------
-- Scenarios

local scenarios = {}
local function scenario(id, name, f) scenarios[#scenarios + 1] = { id = id, name = name, f = f } end

scenario('1', 'No publish service', function()
	-- Another plugin's service must not be picked up by the getPublishServices(nil) fallback.
	SDK.newService(catalog, { pluginId = 'com.adobe.lightroom.export.flickr', name = 'Flickr', provider = {}, settings = {} })
	cycle()
	check(contains(State.status, 'No NAS Publisher service yet'), 'status asks the user to set up a service', State.status)
	check(#SDK.dialogs == 0, 'no dialogs')
end)

scenario('2', 'First cycles: smart collection, sidecar import, settle, publish', function()
	mkfile(SRC .. '/' .. F .. 'DSCF0001.RAF', 'RAF1')
	mkfile(SRC .. '/' .. F .. 'DSCF0002.RAF', 'RAF2')
	mkfile(SRC .. '/' .. F .. 'DSCF0003.RAF', 'RAF3')
	mkfile(SRC .. '/' .. F .. 'DSCF0003.xmp', XMP_EDITED, '2020-01-01 00:00:00')
	mkfile('/elsewhere/X.RAF', 'RAFX')
	W.p1 = catalog:_newPhoto { path = SRC .. '/' .. F .. 'DSCF0001.RAF', hasAdjustments = true, develop = { Exposure2012 = 0.3 }, lastEditTime = SDK.now - 10 }
	W.p2 = catalog:_newPhoto { path = SRC .. '/' .. F .. 'DSCF0002.RAF', lastEditTime = SDK.now - 86400 }
	W.px = catalog:_newPhoto { path = '/elsewhere/X.RAF', hasAdjustments = true, develop = { Exposure2012 = 1 }, lastEditTime = SDK.now - 5 }
	W.service = SDK.newService(catalog, { pluginId = PLUGIN_ID, name = 'NAS', provider = provider, settings = serviceSettings() })
	W.hand = childNamed(W.service, 'Hand-picked')
	local dialogs = #SDK.dialogs

	cycle()
	W.smart = childNamed(W.service, 'Edited RAWs')
	check(W.smart and W.smart:isSmartCollection(), '"Edited RAWs" smart collection created')
	check(catalog:findPhotoByPath(SRC .. '/' .. F .. 'DSCF0003.RAF') == nil, 'no sidecar import while the user is editing')
	check(SDK.counters.publishNow == 0 and #exportJpegs() == 0, 'nothing published while edits are younger than the settle time',
		table.concat(exportJpegs(), ', '))
	check(contains(State.status, 'waiting for edits to settle'), 'status says edits are settling', State.status)

	SDK.advance(30)
	cycle()
	check(SDK.counters.smartCreated == 1, 'smart collection created only once')
	check(#exportJpegs() == 0, 'still nothing published 30 s later')

	-- Edits settled: DSCF0001 is published, then (the user being idle) the sidecar RAW is added.
	SDK.advance(61)
	cycle()
	local j1 = exportFile(F .. 'DSCF0001.jpg')
	check(j1 and j1 == (lastRender(W.p1) or {}).content, 'DSCF0001.jpg published with the rendered bytes')
	W.p3 = catalog:findPhotoByPath(SRC .. '/' .. F .. 'DSCF0003.RAF')
	check(W.p3 ~= nil, 'DSCF0003 (edited XMP sidecar, not in the catalog) was added once edits settled')
	check(W.p3 and W.p3._hasAdjustments, 'DSCF0003 came in with its sidecar edits')
	local added = nil
	for _, c in ipairs(catalog:getChildCollections()) do if c:getName() == 'Added by NAS Publisher' then added = c end end
	check(added and W.p3 and #added:getPhotos() == 1 and added:getPhotos()[1] == W.p3, 'it is in the "Added by NAS Publisher" collection')
	if W.smart then
		check(isMember(W.smart, W.p1) and W.p3 and isMember(W.smart, W.p3) and isMember(W.smart, W.px) and not isMember(W.smart, W.p2),
			'smart collection holds the edited RAWs (DSCF0001, DSCF0003, X) and not DSCF0002')
	end

	-- The added photo's own settle time.
	SDK.advance(61)
	cycle()
	local j3 = exportFile(F .. 'DSCF0003.jpg')
	check(j3 and W.p3 and j3 == (lastRender(W.p3) or {}).content, 'DSCF0003.jpg published with the rendered bytes')
	check(#exportJpegs() == 2, 'exactly two JPEGs on the NAS', table.concat(exportJpegs(), ', '))
	check((record(W.smart, W.p1) or {})._remoteId == F .. 'DSCF0001.jpg', 'remote id recorded for DSCF0001')
	check(#uploadsOf('X.RAF') == 0 and renderCount(W.px) == 0, 'photo outside the NAS folder is neither rendered nor uploaded')
	check(#SDK.dialogs == dialogs, 'no dialogs', #SDK.dialogs - dialogs .. ' dialogs')
	check(contains(State.status, 'outside'), 'status mentions the photo outside the NAS folder', State.status)

	local n = SDK.counters.publishNow
	SDK.advance(31)
	cycle()
	check(SDK.counters.publishNow == n, 'no publish when nothing changed')
	check(contains(State.status, 'Up to date'), 'status: up to date', State.status)
end)

scenario('3', 'Re-edit: waits for settle, then republished under the same id', function()
	local before = exportFile(F .. 'DSCF0001.jpg')
	local updated = eventCount { 'updated' }
	local mark = #SDK.http
	SDK.edit(W.p1, { develop = { Exposure2012 = 0.7 } })
	cycle()
	check(exportFile(F .. 'DSCF0001.jpg') == before, 'not republished while the edit settles')
	check(contains(State.status, 'waiting for edits to settle'), 'status says waiting', State.status)
	SDK.advance(61)
	cycle()
	local after = exportFile(F .. 'DSCF0001.jpg')
	check(after and after ~= before and after == lastRender(W.p1).content, 'JPEG replaced with the new rendering')
	check(record(W.smart, W.p1)._remoteId == F .. 'DSCF0001.jpg' and not record(W.smart, W.p1)._edited, 'same remote id, no longer modified')
	check(eventCount { 'updated' } == updated + 1, 'container logged one "updated"')
	local ups = uploadsOf(F .. 'DSCF0001.RAF', mark)
	check(#ups == 1 and ups[1].fields.previousId == F .. 'DSCF0001.jpg', 'upload carried previousId', #ups .. ' uploads')
end)

scenario('4', 'Spurious "modified" flag: recorded through /api/check without re-uploading', function()
	local mark = #SDK.http
	local renders = renderCount(W.p3)
	local events = eventCount { 'published', 'updated' }
	SDK.flagModified(W.p3)
	SDK.advance(31)
	cycle()
	check(httpCount('/api/check', mark) >= 1, 'the publish asked /api/check')
	check(httpCount('/api/photos', mark) == 0, 'no upload')
	check(renderCount(W.p3) == renders, 'not rendered')
	check(not record(W.smart, W.p3)._edited and record(W.smart, W.p3)._remoteId == F .. 'DSCF0003.jpg', 'flag cleared, id kept')
	check(eventCount { 'published', 'updated' } == events, 'container state shows no new upload')
end)

scenario('9', 'Virtual copy', function()
	W.pv = catalog:_newPhoto { path = W.p1._path, isVirtualCopy = true, copyName = 'Copy 1', master = W.p1, hasAdjustments = true,
		develop = { Exposure2012 = 0.7, Contrast2012 = 20 }, lastEditTime = SDK.now }
	local master = exportFile(F .. 'DSCF0001.jpg')
	SDK.advance(61)
	cycle()
	local vc = exportFile(F .. 'DSCF0001-Copy 1.jpg')
	check(vc and vc == lastRender(W.pv).content, 'virtual copy published as DSCF0001-Copy 1.jpg')
	check(exportFile(F .. 'DSCF0001.jpg') == master, 'master JPEG untouched')

	-- Renaming the copy: Lightroom doesn't flag it; the container renames on the next upload.
	SDK.renameCopy(W.pv, 'Sunset')
	for _ = 1, 3 do SDK.advance(31); cycle() end
	check(exportFile(F .. 'DSCF0001-Sunset.jpg') ~= nil, 'renamed virtual copy republished under its new name without another edit',
		'still ' .. table.concat(exportJpegs(), ', '))
	SDK.edit(W.pv, { develop = { Contrast2012 = 25 } })
	SDK.advance(61)
	cycle()
	check(exportFile(F .. 'DSCF0001-Sunset.jpg') ~= nil and exportFile(F .. 'DSCF0001-Copy 1.jpg') == nil,
		'after its next edit it is DSCF0001-Sunset.jpg and the old name is gone', table.concat(exportJpegs(), ', '))
end)

scenario('10', 'Same photo in Hand-picked and Edited RAWs', function()
	local mark = #SDK.http
	withWrite(function() W.hand:addPhotos { W.p1 } end)
	SDK.advance(31)
	cycle()
	check((record(W.hand, W.p1) or {})._remoteId == F .. 'DSCF0001.jpg', 'Hand-picked records the JPEG the NAS already has')
	check(httpCount('/api/photos', mark) == 0, 'without uploading it again')
	-- An edit flags it in both collections: one render and upload, the other run sees it current.
	SDK.edit(W.p1, { develop = { Exposure2012 = 0.75 } })
	SDK.advance(61)
	mark = #SDK.http
	cycle()
	check(#uploadsOf(F .. 'DSCF0001.RAF', mark) == 1, 'edit of a photo in both collections uploads once', #uploadsOf(F .. 'DSCF0001.RAF', mark) .. ' uploads')
	check(not record(W.hand, W.p1)._edited and not record(W.smart, W.p1)._edited, 'both collections up to date')
	mark = #SDK.http
	withWrite(function() W.hand:removePhotos { W.p1 } end)
	SDK.advance(31)
	cycle()
	check(record(W.hand, W.p1) == nil, 'removal from Hand-picked acknowledged')
	check(exportFile(F .. 'DSCF0001.jpg') ~= nil, 'JPEG kept while Edited RAWs still has the photo')
	check(httpCount('/api/delete', mark) == 0, 'no delete sent to the NAS')
	check((record(W.smart, W.p1) or {})._remoteId == F .. 'DSCF0001.jpg', 'Edited RAWs still records it')
end)

scenario('5', 'Reset: JPEG removed; folder pruned only once empty', function()
	SDK.edit(W.p1, { hasAdjustments = false, cropped = false, resetDevelop = true })
	cycle()
	check(exportFile(F .. 'DSCF0001.jpg') == nil, 'DSCF0001.jpg deleted right away (removals do not wait)')
	check(record(W.smart, W.p1) == nil, 'record dropped')
	check(exportKind('DCIM/100_FUJI') == 'directory', 'folder kept: it still has JPEGs', table.concat(exportJpegs(), ', '))
	-- the virtual copy too
	SDK.edit(W.pv, { hasAdjustments = false, cropped = false, resetDevelop = true })
	cycle()
	local vcLeft = exportFile(F .. 'DSCF0001-Sunset.jpg') or exportFile(F .. 'DSCF0001-Copy 1.jpg')
	check(vcLeft == nil, 'virtual copy JPEG deleted')
	check(exportKind('DCIM/100_FUJI') == 'directory' and exportFile(F .. 'DSCF0003.jpg') ~= nil, 'folder still there with DSCF0003.jpg')
end)

scenario('8', 'RAW moved to another folder', function()
	os.execute('mkdir -p ' .. q(SRC .. '/DCIM/200_MOVED') .. ' && mv ' .. q(SRC .. '/' .. F .. 'DSCF0003.RAF') .. ' '
		.. q(SRC .. '/' .. F .. 'DSCF0003.xmp') .. ' ' .. q(SRC .. '/DCIM/200_MOVED/'))
	SDK.move(W.p3, SRC .. '/DCIM/200_MOVED/DSCF0003.RAF')
	cycle()
	check(exportFile('DCIM/200_MOVED/DSCF0003.jpg') ~= nil, 'republished at DCIM/200_MOVED/DSCF0003.jpg')
	check(exportFile(F .. 'DSCF0003.jpg') == nil, 'old JPEG removed')
	check(exportKind('DCIM/100_FUJI') == false, 'emptied folder DCIM/100_FUJI pruned', table.concat(exportJpegs(), ', '))
	check(exportKind('DCIM') == 'directory', 'DCIM kept')
	check(record(W.smart, W.p3)._remoteId == 'DCIM/200_MOVED/DSCF0003.jpg', 'new remote id recorded')
	local n = SDK.counters.publishNow
	SDK.advance(31)
	cycle()
	check(SDK.counters.publishNow == n, 'nothing more to do on the next cycle')
end)

scenario('6', 'NAS down during automatic cycles', function()
	-- 6a: down for the whole cycle
	SDK.edit(W.p2, { hasAdjustments = true, develop = { Exposure2012 = -0.5 } })
	SDK.advance(61)
	stopNas()
	local dialogs, pn = #SDK.dialogs, SDK.counters.publishNow
	cycle()
	check(#SDK.dialogs == dialogs, 'no dialogs')
	check(SDK.counters.publishNow == pn, 'no publish attempted')
	check(contains(State.status, 'Waiting for the NAS'), 'status: waiting for the NAS', State.status)
	check(State.nasOnline == false, 'State.nasOnline false')
	check(record(W.smart, W.p2) == nil, 'DSCF0002 still waiting')
	startNas()
	SDK.advance(31)
	cycle()
	check(exportFile(F .. 'DSCF0002.jpg') == lastRender(W.p2).content, 'published once the NAS is back')

	-- 6b: goes away between two uploads of one publish run
	SDK.edit(W.p2, { develop = { Exposure2012 = -0.6 } })
	SDK.edit(W.p3, { develop = { Exposure2012 = 0.4 } })
	SDK.advance(61)
	local uploads = 0
	SDK.httpHook = function(method, url)
		if url:find('/api/photos', 1, true) then
			uploads = uploads + 1
			if uploads == 2 then stopNas() end
		end
	end
	dialogs = #SDK.dialogs
	cycle()
	SDK.httpHook = nil
	check(#SDK.dialogs == dialogs, 'no dialogs')
	local r2, r3 = record(W.smart, W.p2), record(W.smart, W.p3)
	check(not r2._edited and r3._edited, 'first photo recorded, second still modified (queued)')
	check(contains(State.status, 'Waiting for the NAS') or contains(State.status, 'waiting for the NAS'),
		'status says the run is waiting for the NAS', State.status)
	check(not contains(State.status, 'Up to date'), 'status does not claim "Up to date" while a photo is still queued', State.status)
	startNas()
	SDK.advance(31)
	cycle()
	check(exportFile('DCIM/200_MOVED/DSCF0003.jpg') == lastRender(W.p3).content and not record(W.smart, W.p3)._edited, 'queued photo published once the NAS is back')

	-- 6c: goes away between the cycle's hello and the publish's own hello
	SDK.edit(W.p2, { develop = { Exposure2012 = -0.7 } })
	SDK.advance(61)
	local hellos = 0
	SDK.httpHook = function(method, url)
		if url:find('/api/hello', 1, true) then
			hellos = hellos + 1
			if hellos == 2 then stopNas() end
		end
	end
	dialogs = #SDK.dialogs
	local renders = renderCount(W.p2)
	cycle()
	SDK.httpHook = nil
	check(#SDK.dialogs == dialogs, 'no dialogs')
	check(renderCount(W.p2) == renders and record(W.smart, W.p2)._edited, 'photo taken out of the run, still queued')
	check(not contains(State.status, 'Up to date'), 'status does not claim "Up to date" while a photo is still queued', State.status)
	startNas()
	SDK.advance(31)
	cycle()
	check(not record(W.smart, W.p2)._edited and exportFile(F .. 'DSCF0002.jpg') == lastRender(W.p2).content, 'published once the NAS is back')
end)

scenario('7', 'Manual publish with the NAS down', function()
	SDK.edit(W.p2, { develop = { Exposure2012 = -0.8 } })
	SDK.advance(61)
	stopNas()
	-- 7a: Library > Plug-in Extras > NAS Publisher: Publish Now, loop not running
	local savedLoop = State.loopRunning
	State.loopRunning = false
	local dialogs, pn = #SDK.dialogs, SDK.counters.publishNow
	runScript('MenuPublishNow.lua')
	check(SDK.counters.publishNow == pn, '"Publish Now" with the NAS down does not start a publish',
		'publishNow calls: ' .. (SDK.counters.publishNow - pn) .. '; status: ' .. State.status)
	check(#SDK.dialogs > dialogs, '"Publish Now" tells the user why it can\'t publish (dialog)',
		'dialogs: ' .. (#SDK.dialogs - dialogs) .. '; bezels: ' .. table.concat(SDK.bezels, ' | '))
	State.loopRunning = savedLoop
	-- 7b: the Publish button in the Publish Services panel (Lightroom's own publish, not the loop)
	dialogs = #SDK.dialogs
	State.autoRun = false
	W.smart:publishNow()
	SDK.runPending()
	local run = lastRun()
	check(#run.uploadFailed == 0 and #run.rendered == 0, 'Publish button: nothing rendered or failed one by one',
		#run.uploadFailed .. ' uploadFailed, ' .. #run.rendered .. ' rendered')
	check(#SDK.dialogs == dialogs + 1, 'one dialog saying the NAS is unreachable', (#SDK.dialogs - dialogs) .. ' dialogs')
	check(record(W.smart, W.p2)._edited, 'photo still queued')
	startNas()
	SDK.advance(31)
	cycle()
	check(not record(W.smart, W.p2)._edited, 'published once the NAS is back')
end)

scenario('11', 'Rendering failure in an automatic publish', function()
	W.p2._renderFail = 'simulated render failure'
	SDK.edit(W.p2, { develop = { Exposure2012 = -0.9 } })
	SDK.edit(W.p3, { develop = { Exposure2012 = 0.5 } })
	SDK.advance(61)
	local dialogs = #SDK.dialogs
	cycle()
	check(#SDK.dialogs == dialogs, 'no dialog', #SDK.dialogs - dialogs .. ' dialogs')
	check(not record(W.smart, W.p3)._edited, 'the other photo published')
	check(record(W.smart, W.p2)._edited, 'failed photo not recorded')
	check(State.failed[W.p2.localIdentifier] ~= nil, 'failed photo remembered')
	local renders, pn = renderCount(W.p2), SDK.counters.publishNow
	SDK.advance(31)
	cycle()
	check(SDK.counters.publishNow == pn, 'failed photo alone does not start publishes')
	check(contains(State.status, 'failed'), 'status mentions the failed photo', State.status)
	SDK.edit(W.p3, { develop = { Exposure2012 = 0.55 } })
	SDK.advance(61)
	cycle()
	check(renderCount(W.p2) == renders, 'failed photo not rendered again while unchanged')
	local removed = false
	for _, p in ipairs(lastRun().removedFromSession) do if p == W.p2 then removed = true end end
	check(removed, 'it was taken out of the session')
	W.p2._renderFail = nil
	SDK.edit(W.p2, { develop = { Exposure2012 = -1.0 } })
	SDK.advance(61)
	cycle()
	check(not record(W.smart, W.p2)._edited and exportFile(F .. 'DSCF0002.jpg') == lastRender(W.p2).content, 'published after its next edit')
end)

scenario('11b', 'NAS refuses an upload (4xx) in an automatic publish', function()
	W.p2._renderBytes = '\137PNG\r\n\26\n not a jpeg'
	SDK.edit(W.p2, { develop = { Exposure2012 = -1.1 } })
	SDK.advance(61)
	local dialogs, mark = #SDK.dialogs, #SDK.http
	cycle()
	local ups = uploadsOf(F .. 'DSCF0002.RAF', mark)
	check(#ups == 1 and ups[1].status == 415, 'container answered 415', #ups == 1 and tostring(ups[1].status) or (#ups .. ' uploads'))
	check(#SDK.dialogs == dialogs, 'no dialog')
	check(State.failed[W.p2.localIdentifier] ~= nil and record(W.smart, W.p2)._edited, 'photo skipped until edited again, still queued')
	SDK.advance(31)
	mark = #SDK.http
	cycle()
	check(#uploadsOf(F .. 'DSCF0002.RAF', mark) == 0, 'not retried while unchanged')
	W.p2._renderBytes = nil
	SDK.edit(W.p2, { develop = { Exposure2012 = -1.2 } })
	SDK.advance(61)
	cycle()
	check(not record(W.smart, W.p2)._edited, 'published after its next edit')
end)

scenario('12', 'Accented folder name: macOS spells it NFD, the NAS stores NFC', function()
	local nfc, nfd = 'Caf\195\169', 'Cafe\204\129'
	mkfile(SRC .. '/' .. nfc .. '/IMG_0001.RAF', 'RAFC')
	W.pc = catalog:_newPhoto { path = SRC .. '/' .. nfd .. '/IMG_0001.RAF', hasAdjustments = true, develop = { Exposure2012 = 0.1 }, lastEditTime = SDK.now }
	SDK.advance(61)
	cycle()
	check(exportFile(nfc .. '/IMG_0001.jpg') ~= nil, 'published (container files it under the NFC name)')
	local id = (record(W.smart, W.pc) or {})._remoteId
	note('recorded id: ' .. tostring(id))
	local pn, mark, ev = SDK.counters.publishNow, #SDK.http, eventCount { 'published', 'updated' }
	for _ = 1, 3 do SDK.advance(31); cycle() end
	check(SDK.counters.publishNow == pn, 'no publish runs while nothing changes',
		string.format('%d publish runs, %d /api/check requests in 3 idle cycles', SDK.counters.publishNow - pn, httpCount('/api/check', mark)))
	check(eventCount { 'published', 'updated' } == ev, 'no re-uploads')
	SDK.edit(W.pc, { hasAdjustments = false, resetDevelop = true })
	cycle()
	check(exportFile(nfc .. '/IMG_0001.jpg') == nil, 'removed again after a reset')
end)

scenario('13', "Publish settings returned wrapped in '< contents >' or with prefixed keys", function()
	for _, shape in ipairs { 'contents', 'prefixed' } do
		W.service.settingsShape = shape
		SDK.edit(W.p3, { develop = { Exposure2012 = shape == 'contents' and 0.61 or 0.62 } })
		SDK.advance(61)
		cycle()
		check(not record(W.smart, W.p3)._edited and exportFile('DCIM/200_MOVED/DSCF0003.jpg') == lastRender(W.p3).content,
			shape .. ' shape: published', State.status)
	end
	W.service.settingsShape = nil
	-- An export setting changes: Lightroom marks every published photo modified; the JPEGs must be
	-- rendered again rather than recognized as current.
	W.service._settings.LR_jpeg_quality = 0.8
	local mark = #SDK.http
	for _, r in ipairs(W.service:getPublishedPhotos()) do r._edited = true end
	SDK.advance(31)
	cycle()
	check(httpCount('/api/photos', mark) == #W.smart._records, 'a new JPEG quality re-renders every photo',
		httpCount('/api/photos', mark) .. ' uploads for ' .. #W.smart._records .. ' photos')
end)

scenario('14', 'Container state lost (new serverId): everything published again', function()
	local before = exportJpegs()
	stopNas()
	os.remove(CFG .. '/state.json')
	startNas()
	local mark = #SDK.http
	SDK.advance(31)
	cycle()
	local ids, nIds = {}, 0
	for _, r in ipairs(W.service:getPublishedPhotos()) do
		if r._remoteId and not ids[r._remoteId] then ids[r._remoteId] = true; nIds = nIds + 1 end
	end
	local photos = nasState().photos or {}
	local missing = {}
	for id in pairs(ids) do if not photos[id] then missing[#missing + 1] = id end end
	check(#missing == 0, 'the new container state knows every published JPEG again', 'missing: ' .. table.concat(missing, ', '))
	check(table.concat(exportJpegs(), ',') == table.concat(before, ','), 'same JPEG files, no duplicates', table.concat(exportJpegs(), ', '))
	check(httpCount('/api/photos', mark) == nIds, 'each re-sent once', httpCount('/api/photos', mark) .. ' uploads for ' .. nIds .. ' JPEGs')
end)

scenario('16', 'Continuous editing: published after 10 minutes anyway', function()
	local start = SDK.now
	local publishedAt
	for i = 1, 30 do
		SDK.edit(W.p3, { develop = { Exposure2012 = 1 + i / 100 } })
		SDK.advance(31)
		cycle()
		if not record(W.smart, W.p3)._edited then publishedAt = SDK.now; break end
	end
	check(publishedAt and publishedAt - start >= 600 and publishedAt - start < 700, 'published once edits kept coming for 10 minutes',
		publishedAt and (publishedAt - start) .. ' s' or 'never')
end)

scenario('17', 'Sidecar appearing later; photo removed from the catalog is not added back', function()
	mkfile(SRC .. '/' .. F .. 'DSCF0004.RAF', 'RAF4')
	mkfile(SRC .. '/' .. F .. 'DSCF0004.xmp', XMP_EDITED, '2020-01-02 00:00:00')
	-- The container rescans only when its last scan is older than SCAN_INTERVAL_MINUTES (real time,
	-- 3 s here); the plugin asks every 10 minutes of (mock) time.
	os.execute('sleep 3.5')
	SDK.advance(601)
	cycle()
	local p4 = catalog:findPhotoByPath(SRC .. '/' .. F .. 'DSCF0004.RAF')
	check(p4 and p4._hasAdjustments, 'DSCF0004 added at the next sidecar check')
	if not p4 then return end
	-- The user removes it from the catalog before it is published.
	p4._removed = true
	local pn = SDK.counters.publishNow
	SDK.advance(31)
	cycle()
	check(SDK.counters.publishNow == pn, 'no publish started for a photo that was never published and left the collection',
		(SDK.counters.publishNow - pn) .. ' publishNow calls; run: ' .. (lastRun() and (#lastRun().toPublish .. ' to publish, ' .. #lastRun().removalIds .. ' removals') or '-'))
	SDK.advance(601)
	cycle()
	check(catalog:findPhotoByPath(SRC .. '/' .. F .. 'DSCF0004.RAF') == nil, 'not added back while its sidecar is unchanged')
	-- The outside photo X leaves the smart collection (reset): it was never published either.
	pn = SDK.counters.publishNow
	SDK.edit(W.px, { hasAdjustments = false, resetDevelop = true })
	cycle()
	check(SDK.counters.publishNow == pn, 'no publish started when an unpublished outside photo leaves the collection',
		(SDK.counters.publishNow - pn) .. ' publishNow calls; that run had ' .. #lastRun().toPublish .. ' to publish, '
		.. #lastRun().removalIds .. ' removals')
	-- The common case: edit a photo, then Reset it before the edit settled.
	mkfile(SRC .. '/' .. F .. 'DSCF0005.RAF', 'RAF5')
	local p5 = catalog:_newPhoto { path = SRC .. '/' .. F .. 'DSCF0005.RAF', lastEditTime = SDK.now - 86400 }
	SDK.edit(p5, { hasAdjustments = true, develop = { Exposure2012 = 0.2 } })
	SDK.advance(31)
	cycle()
	pn = SDK.counters.publishNow
	SDK.edit(p5, { hasAdjustments = false, resetDevelop = true })
	SDK.advance(10)
	cycle()
	check(SDK.counters.publishNow == pn, 'no publish started when a photo is edited and reset before it settled',
		(SDK.counters.publishNow - pn) .. ' publishNow calls; that run had ' .. #lastRun().toPublish .. ' to publish, '
		.. #lastRun().removalIds .. ' removals; status during it: "Publishing 0 photos and 1 removals"')
end)

scenario('18', 'Share drops mid-publish: a smart-preview-sized render is not uploaded', function()
	local small = SDK.readFile('/p/tests/fixtures/small.jpg') -- 300 x 225
	W.p2._renderBytes = small
	W.p2._croppedDims = { width = 11648, height = 8736 }
	SDK.edit(W.p2, { develop = { Exposure2012 = -1.3 } })
	SDK.advance(61)
	local mark, dialogs = #SDK.http, #SDK.dialogs
	cycle()
	check(#uploadsOf(F .. 'DSCF0002.RAF', mark) == 0, 'the small render was not uploaded')
	check(record(W.smart, W.p2)._edited, 'photo still queued')
	check(State.failed[W.p2.localIdentifier] == nil, 'not counted as a failure of the photo')
	check(contains(State.status, 'Paused publishing'), 'status says publishing paused', State.status)
	check(#SDK.dialogs == dialogs, 'no dialog')
	W.p2._renderBytes = nil
	W.p2._croppedDims = nil
	SDK.advance(31)
	cycle()
	check(not record(W.smart, W.p2)._edited, 'published from the original once it renders at full size')
end)

scenario('19', 'Wrong "RAW folder" setting: nothing is rendered, the status says why', function()
	W.service._settings.npSourceRoot = ROOT -- the parent of the container's SOURCE_DIR
	SDK.edit(W.p2, { develop = { Exposure2012 = -1.4 } })
	SDK.advance(61)
	local mark, renders, dialogs = #SDK.http, #SDK.renders, #SDK.dialogs
	cycle()
	check(#SDK.renders == renders, 'nothing rendered', (#SDK.renders - renders) .. ' renders')
	check(#uploadsOf('DSCF0002.RAF', mark) == 0, 'nothing uploaded')
	check(contains(State.status, "can't find"), 'status explains the setting', State.status)
	check(#SDK.dialogs == dialogs, 'no dialog')
	SDK.advance(31)
	local pn = SDK.counters.publishNow
	cycle()
	check(SDK.counters.publishNow == pn, 'not retried every cycle')
	W.service._settings.npSourceRoot = SRC
	SDK.edit(W.p2, { develop = { Exposure2012 = -1.5 } })
	SDK.advance(61)
	cycle()
	check(not record(W.smart, W.p2)._edited, 'published once the setting is right')
end)

scenario('15', 'The loop, the menu items, Init/Shutdown, the settings dialog', function()
	-- Init.lua starts the loop; Publish Now during the poll wait forces a cycle; Shutdown.lua stops it.
	SDK.edit(W.p3, { develop = { Exposure2012 = 0.7 } })
	local editAt = SDK.now
	local sleeps, hellos = 0, httpCount('/api/hello')
	local publishedAt
	SDK.sleepHook = function()
		sleeps = sleeps + 1
		if sleeps == 25 then runScript('MenuPublishNow.lua') end
		if not publishedAt and not record(W.smart, W.p3)._edited then publishedAt = SDK.now end
		if sleeps == 20 + 3 * 30 then runScript('Shutdown.lua') end
		if sleeps > 1000 then error('the loop did not stop') end
	end
	runScript('Init.lua')
	SDK.sleepHook = nil
	check(State.loopRunning == false, 'loop ended after Shutdown.lua')
	check(not contains(State.status, 'Error'), 'no error status', State.status)
	check(httpCount('/api/hello') - hellos >= 3, 'loop ran several cycles', (httpCount('/api/hello') - hellos) .. ' hellos')
	check(publishedAt and publishedAt - editAt < 60, 'Publish Now published before the settle time', publishedAt and (publishedAt - editAt) .. ' s after the edit')

	-- Stopped during its 20 s startup wait.
	sleeps = 0
	SDK.sleepHook = function() sleeps = sleeps + 1; if sleeps == 5 then AutoPublisher.stop() end end
	local ok, err = xpcall(AutoPublisher.run, debug.traceback)
	SDK.sleepHook = nil
	check(ok, 'run() returns cleanly', err)
	check(State.loopRunning == false, 'loopRunning cleared when stopped during the startup wait', 'State.loopRunning = ' .. tostring(State.loopRunning))
	if State.loopRunning then
		SDK.edit(W.p3, { develop = { Exposure2012 = 0.75 } })
		local pn = SDK.counters.publishNow
		runScript('MenuPublishNow.lua')
		check(SDK.counters.publishNow > pn, 'consequence: "Publish Now" does nothing (it only signals the dead loop)')
		State.loopRunning = false
		runScript('MenuPublishNow.lua')
	end

	local d = #SDK.dialogs
	runScript('MenuStatus.lua')
	check(#SDK.dialogs == d + 1 and contains(SDK.dialogs[#SDK.dialogs].text, 'NAS: online'), 'Status… dialog', SDK.dialogs[#SDK.dialogs] and SDK.dialogs[#SDK.dialogs].text)

	-- Settings dialog: defaults, layout and Test Connection.
	local props = SDK.propertyTable(serviceSettings())
	props.npDefaultsApplied = false
	provider.startDialog(props)
	check(props.LR_jpeg_quality == 0.9 and props.npDefaultsApplied == true, 'startDialog applies first-time defaults')
	local okUi, sections = pcall(provider.sectionsForTopOfDialog, SDK.namespaces.LrView.osFactory(), props)
	check(okUi and type(sections) == 'table', 'sectionsForTopOfDialog builds', not okUi and sections or nil)
	local button
	local function walk(t)
		if type(t) ~= 'table' then return end
		if t._kind == 'push_button' and t.title == 'Test Connection' then button = t end
		for _, v in pairs(t) do if type(v) == 'table' and v ~= t then walk(v) end end
	end
	if okUi then walk(sections) end
	if button then
		button.action()
		check(contains(props.npTestResult, 'Connected'), 'Test Connection reports connected', props.npTestResult)
	else
		check(false, 'Test Connection button found')
	end
end)

-------------------------------------------------------------------------------------------------

os.execute('rm -rf ' .. q(SRC) .. '/* ' .. q(EXP) .. '/* /elsewhere')
assert(nasHealthy(), 'the NAS container is not answering at ' .. NAS_URL)

for _, s in ipairs(scenarios) do
	if not ONLY or ONLY[s.id] then
		scenarioName = s.id .. '. ' .. s.name
		print('\n== ' .. scenarioName)
		local errors, problems = #SDK.errors, #SDK.problems
		local ok, err = xpcall(s.f, debug.traceback)
		SDK.httpHook, SDK.sleepHook = nil, nil
		if not ok then
			check(false, 'scenario ran to the end', err)
			if not nasHealthy() and NAS_CONTAINER then pcall(startNas) end
		end
		local errs = {}
		for i = errors + 1, #SDK.errors do errs[#errs + 1] = SDK.errors[i].where .. ': ' .. SDK.errors[i].err end
		check(#errs == 0, 'no Lua errors escaped plugin code', table.concat(errs, '\n'))
		local probs = {}
		for i = problems + 1, #SDK.problems do probs[#probs + 1] = SDK.problems[i] end
		check(#probs == 0, 'no SDK misuse', table.concat(probs, '\n'))
	end
end

print(string.format('\n%d checks passed, %d failed', results.pass, results.fail))
for _, f in ipairs(results.failures) do
	print(string.format('  FAIL [%s] %s%s', f.scenario, f.what, f.detail and (': ' .. tostring(f.detail):gsub('\n', ' | ')) or ''))
end
if SDK.verbose then
	print('\nplugin log:')
	for _, l in ipairs(SDK.logLines) do print('  ' .. l) end
end
os.exit(results.fail == 0 and 0 or 1)
