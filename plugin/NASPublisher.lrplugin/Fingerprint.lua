--[[ Fingerprint.lua
A hash of everything that shapes a published JPEG: the Develop settings, the metadata embedded in
it, its place on the NAS and the export settings. Lightroom sometimes marks photos as modified
when nothing changed; the NAS remembers each JPEG's fingerprint, so such photos are not rendered
and uploaded again.
]]

local LrTasks = import 'LrTasks'

local Fingerprint = {}

-- Bump when what goes into the fingerprint changes, so old ones never match.
local VERSION = 'fp2'

local ok, LrMD5 = pcall(import, 'LrMD5')
if not ok then LrMD5 = nil end

-- Export settings that change the JPEG.
local EXPORT_KEYS = {
	'LR_format', 'LR_jpeg_quality', 'LR_jpeg_useLimitSize', 'LR_jpeg_limitSize', 'LR_export_colorSpace',
	'LR_export_bitDepth', 'LR_size_doConstrain', 'LR_size_doNotEnlarge', 'LR_size_maxHeight', 'LR_size_maxWidth',
	'LR_size_resizeType', 'LR_size_units', 'LR_size_resolution', 'LR_size_resolutionUnits', 'LR_size_megapixels',
	'LR_size_percentage', 'LR_outputSharpeningOn', 'LR_outputSharpeningMedia', 'LR_outputSharpeningLevel',
	'LR_minimizeEmbeddedMetadata', 'LR_embeddedMetadataOption', 'LR_removeLocationMetadata',
	'LR_removeFaceMetadata', 'LR_metadata_keywordOptions', 'LR_useWatermark', 'LR_watermarking_id',
	'LR_includeFaceTagsAsKeywords', 'LR_includeFaceTagsInIptc', 'LR_export_postProcessing',
	'LR_size_longEdge', 'LR_size_shortEdge',
}

-- HDR output (File Settings > HDR Output, Maximize Compatibility). Counted only when on, so the
-- fingerprints of SDR exports stay what they were before these keys were added.
local HDR_KEYS = { 'LR_enableHDRDisplay', 'LR_maximumCompatibility' }

-- Metadata embedded in the JPEG (everything metadataThatTriggersRepublish asks for).
local META_KEYS = {
	'title', 'caption', 'keywordTagsForExport', 'copyright', 'copyrightState', 'rightsUsageTerms',
	'copyrightInfoUrl', 'creator', 'creatorJobTitle', 'creatorAddress', 'creatorCity',
	'creatorStateProvince', 'creatorPostalCode', 'creatorCountry', 'creatorPhone', 'creatorEmail',
	'creatorUrl', 'headline', 'location', 'city', 'stateProvince', 'country', 'isoCountryCode',
	'dateCreated', 'label', 'rating',
}

-- Deterministic text form of a value: keys sorted, numbers rounded so float noise (or GPS
-- precision lost in EXIF) doesn't count as a change.
local function serialize(v, out)
	local t = type(v)
	if t == 'table' then
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		out[#out + 1] = '{'
		for _, k in ipairs(keys) do
			out[#out + 1] = tostring(k)
			out[#out + 1] = '='
			serialize(v[k], out)
			out[#out + 1] = ';'
		end
		out[#out + 1] = '}'
	elseif t == 'number' then
		out[#out + 1] = string.format('%.6g', v)
	elseif t == 'string' then
		out[#out + 1] = string.format('%q', v)
	else
		out[#out + 1] = tostring(v)
	end
	return out
end
Fingerprint.serialize = serialize

-- 32-bit FNV-1a, in case LrMD5 is ever missing. Lua 5.1 numbers are doubles, so multiply in
-- 16-bit halves to stay exact.
local function fnv1a(s)
	local h = 2166136261
	for i = 1, #s do
		local x = h
		local b = s:byte(i)
		-- h = h XOR b
		local r, bit = 0, 1
		for _ = 1, 8 do
			local hb, bb = x % 2, b % 2
			if hb ~= bb then r = r + bit end
			x, b, bit = (x - hb) / 2, (b - bb) / 2, bit * 2
		end
		h = (h - h % 256) + r
		-- h = h * 16777619 mod 2^32
		local lo, hi = h % 65536, math.floor(h / 65536)
		h = (lo * 16777619 + (hi * 16777619 % 65536) * 65536) % 4294967296
	end
	return string.format('%08x', h)
end
Fingerprint.fnv1a = fnv1a

function Fingerprint.hash(s)
	if LrMD5 and LrMD5.digest then return LrMD5.digest(s) end
	return fnv1a(s) .. string.format('%08x', #s)
end

-- photo: LrPhoto; rel/variant: where it goes on the NAS; exportSettings: the publish settings.
-- Call from an async task.
function Fingerprint.forPhoto(photo, rel, variant, exportSettings)
	local export = {}
	for _, k in ipairs(EXPORT_KEYS) do export[k] = exportSettings[k] end
	if exportSettings.LR_enableHDRDisplay then
		for _, k in ipairs(HDR_KEYS) do export[k] = exportSettings[k] end
	end
	-- LrTasks.pcall: these getters may yield, which a plain pcall can't survive.
	local meta = {}
	for _, k in ipairs(META_KEYS) do
		local okMeta, v = LrTasks.pcall(photo.getFormattedMetadata, photo, k)
		if okMeta then meta[k] = v end
	end
	local okGps, gps = LrTasks.pcall(photo.getRawMetadata, photo, 'gps')
	local okDims, dims = LrTasks.pcall(photo.getRawMetadata, photo, 'croppedDimensions')
	local okTime, captured = LrTasks.pcall(photo.getRawMetadata, photo, 'dateTimeOriginal')
	local text = VERSION .. table.concat(serialize({
		captured = okTime and captured or nil,
		develop = photo:getDevelopSettings(),
		meta = meta,
		gps = okGps and gps or nil,
		dims = okDims and dims or nil,
		rel = rel,
		variant = variant,
		export = export,
	}, {}))
	return Fingerprint.hash(text)
end

return Fingerprint
