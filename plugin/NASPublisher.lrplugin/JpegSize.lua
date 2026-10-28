--[[ JpegSize.lua
Reads a JPEG's pixel size from its frame header, without reading the whole file. Used to catch a
render made from a smart preview (about 2560 px) when the original went offline mid-publish.
Pure Lua, so it can be tested outside Lightroom.
]]

local JpegSize = {}

local function u16(s, i)
	return s:byte(i) * 256 + s:byte(i + 1)
end

-- Returns width, height, or nil and a reason.
function JpegSize.read(path)
	local f = io.open(path, 'rb')
	if not f then return nil, 'cannot open ' .. tostring(path) end
	local function readAt(pos, n)
		f:seek('set', pos)
		return f:read(n) or ''
	end
	if readAt(0, 2) ~= '\255\216' then
		f:close()
		return nil, 'not a JPEG'
	end
	local pos = 2
	for _ = 1, 1000 do
		local head = readAt(pos, 4)
		if #head < 4 then break end
		if head:byte(1) ~= 0xFF then break end
		local marker = head:byte(2)
		if marker == 0xFF then
			pos = pos + 1 -- fill byte
		elseif marker == 0xD8 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7) then
			pos = pos + 2 -- markers without a length
		else
			local len = u16(head, 3)
			-- SOF0..SOF15, except DHT (C4), JPG (C8) and DAC (CC)
			if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
				local sof = readAt(pos + 4, 5)
				f:close()
				if #sof < 5 then return nil, 'truncated frame header' end
				return u16(sof, 4), u16(sof, 2)
			end
			if marker == 0xDA or marker == 0xD9 then break end -- image data or end without a frame header
			pos = pos + 2 + len
		end
	end
	f:close()
	return nil, 'no frame header'
end

-- Whether a render of width x height plausibly comes from the original rather than a smart
-- preview, for an export that isn't resized. expected = { width=, height= } (cropped size).
function JpegSize.fullSize(width, height, expected)
	if type(expected) ~= 'table' or not tonumber(expected.width) or not tonumber(expected.height) then return true end
	local wantLong = math.max(tonumber(expected.width), tonumber(expected.height))
	local gotLong = math.max(width or 0, height or 0)
	if wantLong <= 2600 then return true end -- a smart preview would be just as big
	return gotLong >= 0.9 * wantLong
end

return JpegSize
