--[[ Settings.lua
The publish service's own settings and their defaults.
]]

local Settings = {}

Settings.fields = {
	{ key = 'npNasUrl', default = 'http://nas.local:8765' },
	{ key = 'npToken', default = '' },
	-- The container's SOURCE_DIR as this Mac sees it, e.g. /Volumes/photo/RAW. JPEGs keep their
	-- path below it.
	{ key = 'npSourceRoot', default = '' },
	{ key = 'npAutoPublish', default = true },
	{ key = 'npSettleSeconds', default = 60 },
	{ key = 'npImportSidecars', default = true },
	-- Published photos with at least this many stars also go into the NAS's starred folder; 0: off.
	{ key = 'npStarredMin', default = 1 },
	{ key = 'npDefaultsApplied', default = false },
}

-- Where the container may keep its access token (its config folder), as this Mac sees the NAS's
-- shares; the first one that can be read is used when the token setting is left empty.
Settings.tokenFiles = {
	'/Volumes/docker/projects/lrc-nas-publisher/config/token',
	'/Volumes/docker/lrc-nas-publisher/config/token',
	'/Volumes/home/lrc-nas-publisher/config/token',
}

-- Name of the smart collection the plugin creates in each NAS Publisher service.
Settings.smartCollectionName = 'Edited RAWs'

-- Edited raw photos: Has Adjustments or Cropped, and File Type is Raw or DNG. Which of them
-- are under the NAS photo folder is checked by path, since the Folder rule matches the names
-- shown in the Folders panel rather than full paths.
Settings.smartCollectionSearch = {
	{
		combine = 'union',
		{ criteria = 'hasAdjustments', operation = 'isTrue', value = true },
		{ criteria = 'cropped', operation = 'isTrue', value = true },
	},
	{
		combine = 'union',
		{ criteria = 'fileFormat', operation = '==', value = 'RAW' },
		{ criteria = 'fileFormat', operation = '==', value = 'DNG' },
	},
	combine = 'intersect',
}

Settings.pollSeconds = 30 -- how often the loop looks for work
Settings.maxWaitSeconds = 10 * 60 -- publish anyway when edits haven't settled for this long
Settings.sidecarCheckSeconds = 10 * 60 -- how often to ask the NAS for RAWs with edited XMP sidecars
Settings.sidecarImportsPerCycle = 10

-- service:getPublishSettings() has been seen to return the settings wrapped in '< contents >'
-- and/or with keys prefixed by the plugin id. Read keys by index (which also works on
-- Lightroom's observable property tables) and look in all those places.
function Settings.get(raw, key)
	if raw == nil then return nil end
	local inner = raw['< contents >']
	if type(inner) ~= 'table' then inner = nil end
	local prefixed = _PLUGIN.id .. '_' .. key
	for _, t in ipairs { raw, inner } do
		if t then
			local v = t[key]
			if v == nil then v = t[prefixed] end
			if v ~= nil then return v end
		end
	end
	return nil
end

-- The plugin's own settings, with defaults for missing ones.
function Settings.normalize(raw)
	local out = {}
	for _, f in ipairs(Settings.fields) do
		local v = Settings.get(raw, f.key)
		if v == nil then v = f.default end
		out[f.key] = v
	end
	return out
end

function Settings.settleSeconds(settings)
	local n = tonumber(settings.npSettleSeconds) or 60
	if n < 5 then n = 5 end
	return n
end

return Settings
