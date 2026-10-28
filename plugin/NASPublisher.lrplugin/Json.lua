--[[ Json.lua
Minimal JSON for Lua 5.1 (Lightroom's Lua): enough for talking to the NAS.
  Json.encode(value)  -> string. Tables with keys 1..n are arrays; empty tables
                         encode as {} unless marked with Json.array().
  Json.decode(string) -> value, or nil and an error message. null -> Json.null.
]]

local Json = {}

Json.null = setmetatable({}, { __tostring = function() return "null" end })

local arrayMarker = {}
function Json.array(t)
	return setmetatable(t or {}, { [arrayMarker] = true })
end

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function encodeString(s)
	return '"' .. s:gsub('[%c"\\]', function(c)
		return escapes[c] or string.format('\\u%04x', c:byte())
	end) .. '"'
end

local function isArray(t)
	local mt = getmetatable(t)
	if mt and mt[arrayMarker] then return true end
	local n = 0
	for k in pairs(t) do
		if type(k) ~= 'number' or k <= 0 or k % 1 ~= 0 then return false end
		n = n + 1
	end
	return n > 0 and n == #t
end

local encodeValue

local function encodeTable(t, seen)
	if seen[t] then error('Json.encode: cycle in table') end
	seen[t] = true
	local out = {}
	if isArray(t) then
		for i = 1, #t do out[i] = encodeValue(t[i], seen) end
		seen[t] = nil
		return '[' .. table.concat(out, ',') .. ']'
	end
	local keys = {}
	for k in pairs(t) do
		if type(k) ~= 'string' and type(k) ~= 'number' then error('Json.encode: key of type ' .. type(k)) end
		keys[#keys + 1] = tostring(k)
	end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local v = t[k]
		if v == nil then v = t[tonumber(k)] end
		out[#out + 1] = encodeString(k) .. ':' .. encodeValue(v, seen)
	end
	seen[t] = nil
	return '{' .. table.concat(out, ',') .. '}'
end

function encodeValue(v, seen)
	local tv = type(v)
	if v == nil or v == Json.null then return 'null'
	elseif tv == 'boolean' then return tostring(v)
	elseif tv == 'number' then
		if v ~= v or v == math.huge or v == -math.huge then error('Json.encode: number ' .. tostring(v)) end
		if v % 1 == 0 and v > -1e15 and v < 1e15 then return string.format('%d', v) end
		local short = string.format('%.15g', v)
		if tonumber(short) == v then return short end
		return string.format('%.17g', v)
	elseif tv == 'string' then return encodeString(v)
	elseif tv == 'table' then return encodeTable(v, seen)
	end
	error('Json.encode: value of type ' .. tv)
end

function Json.encode(v)
	return encodeValue(v, {})
end

-- Decoding

local function utf8char(cp)
	if cp < 0x80 then return string.char(cp)
	elseif cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
	elseif cp < 0x10000 then
		return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	end
	return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
		0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local unescapes = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local decodeValue

local function skip(s, i)
	return s:find('[^ \t\r\n]', i) or #s + 1
end

local function decodeString(s, i)
	-- s:sub(i, i) == '"'
	local out, j = {}, i + 1
	while true do
		local k = s:find('["\\]', j)
		if not k then error('unterminated string at ' .. i) end
		out[#out + 1] = s:sub(j, k - 1)
		if s:sub(k, k) == '"' then return table.concat(out), k + 1 end
		local c = s:sub(k + 1, k + 1)
		if c == 'u' then
			local hex = s:sub(k + 2, k + 5)
			if not hex:match('^%x%x%x%x$') then error('bad \\u escape at ' .. k) end
			local cp, nextPos = tonumber(hex, 16), k + 6
			if cp >= 0xD800 and cp <= 0xDBFF and s:sub(nextPos, nextPos + 1) == '\\u' then
				local lo = tonumber(s:sub(nextPos + 2, nextPos + 5), 16)
				if lo and lo >= 0xDC00 and lo <= 0xDFFF then
					cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
					nextPos = nextPos + 6
				end
			end
			out[#out + 1] = utf8char(cp)
			j = nextPos
		elseif unescapes[c] then
			out[#out + 1] = unescapes[c]
			j = k + 2
		else
			error('bad escape at ' .. k)
		end
	end
end

local function decodeArray(s, i)
	local out, n = Json.array(), 0
	i = skip(s, i + 1)
	if s:sub(i, i) == ']' then return out, i + 1 end
	while true do
		local v
		v, i = decodeValue(s, i)
		n = n + 1
		out[n] = v
		i = skip(s, i)
		local c = s:sub(i, i)
		if c == ']' then return out, i + 1 end
		if c ~= ',' then error('expected , or ] at ' .. i) end
		i = skip(s, i + 1)
	end
end

local function decodeObject(s, i)
	local out = {}
	i = skip(s, i + 1)
	if s:sub(i, i) == '}' then return out, i + 1 end
	while true do
		if s:sub(i, i) ~= '"' then error('expected a key at ' .. i) end
		local k
		k, i = decodeString(s, i)
		i = skip(s, i)
		if s:sub(i, i) ~= ':' then error('expected : at ' .. i) end
		local v
		v, i = decodeValue(s, skip(s, i + 1))
		out[k] = v
		i = skip(s, i)
		local c = s:sub(i, i)
		if c == '}' then return out, i + 1 end
		if c ~= ',' then error('expected , or } at ' .. i) end
		i = skip(s, i + 1)
	end
end

function decodeValue(s, i)
	i = skip(s, i)
	local c = s:sub(i, i)
	if c == '{' then return decodeObject(s, i)
	elseif c == '[' then return decodeArray(s, i)
	elseif c == '"' then return decodeString(s, i)
	elseif s:sub(i, i + 3) == 'true' then return true, i + 4
	elseif s:sub(i, i + 4) == 'false' then return false, i + 5
	elseif s:sub(i, i + 3) == 'null' then return Json.null, i + 4
	end
	local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
	if num and num ~= '' and num ~= '-' then
		local v = tonumber(num)
		if v then return v, i + #num end
	end
	error('unexpected ' .. (c == '' and 'end of input' or ("'" .. c .. "'")) .. ' at ' .. i)
end

function Json.decode(s)
	if type(s) ~= 'string' then return nil, 'not a string' end
	local ok, v, i = pcall(decodeValue, s, 1)
	if not ok then return nil, tostring(v) end
	if skip(s, i) <= #s then return nil, 'trailing characters at ' .. i end
	return v
end

return Json
