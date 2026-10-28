--[[ PathUtil.lua
Maps a photo's path on this Mac to its path relative to the NAS photo folder
(the container's SOURCE_DIR), and back. Pure Lua, so it can be tested outside
Lightroom.
]]

local PathUtil = {}

-- "/Volumes/photo/RAW/" -> "/Volumes/photo/RAW"
function PathUtil.cleanRoot(root)
	root = (root or ''):gsub('^%s+', ''):gsub('%s+$', '')
	if #root > 1 then root = root:gsub('/+$', '') end
	return root
end

-- Path of `path` below `root`, with "/" separators, or nil if it isn't below
-- root. macOS sees the share case-insensitively, so case is ignored.
function PathUtil.relative(path, root)
	root = PathUtil.cleanRoot(root)
	if type(path) ~= 'string' or root == '' or root == '/' then return nil end
	local prefix = root .. '/'
	local head = path:sub(1, #prefix)
	if head ~= prefix and head:lower() ~= prefix:lower() then return nil end
	local rel = path:sub(#prefix + 1)
	if rel == '' then return nil end
	for part in rel:gmatch('[^/]+') do
		if part == '..' then return nil end
	end
	return rel
end

function PathUtil.join(root, rel)
	return PathUtil.cleanRoot(root) .. '/' .. rel
end

-- A virtual copy's name as the container puts it in a file name (its safeName): / \ : and control
-- characters become _, spaces and dots are trimmed at both ends, at most 80 characters.
function PathUtil.safeName(s)
	s = tostring(s or ''):gsub('[/\\:%c]', '_'):gsub('^[ %.]+', ''):gsub('[ %.]+$', '')
	local out, n = {}, 0
	for ch in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
		n = n + 1
		if n > 80 then break end
		out[n] = ch
	end
	s = table.concat(out)
	if s == '' then s = 'copy' end
	return s
end

-- Whether a published id is where the container would put rel (+ variant) now:
-- <folder>/<name>[-<copy>].jpg, or with the -<ext>[-n] suffix it adds on a name clash. Case is
-- ignored; Unicode spelling (NFC on the NAS, maybe NFD here) is not, so callers confirm a
-- mismatch with the NAS before acting on it.
function PathUtil.idMatches(remoteId, rel, variant)
	if type(remoteId) ~= 'string' or type(rel) ~= 'string' then return false end
	local stem = rel:gsub('%.[^./]*$', '')
	if variant and variant ~= '' then stem = stem .. '-' .. PathUtil.safeName(variant) end
	if remoteId:sub(1, #stem):lower() ~= stem:lower() then return false end
	local rest = remoteId:sub(#stem + 1):lower()
	if rest == '.jpg' then return true end
	local ext = (rel:match('%.([^./]*)$') or ''):lower()
	if ext == '' then ext = 'raw' end
	local suffix = rest:sub(1, #ext + 1)
	if suffix ~= '-' .. ext then return false end
	local tail = rest:sub(#ext + 2)
	return tail == '.jpg' or tail:match('^%-%d+%.jpg$') ~= nil
end

-- The variant name the plugin sends for a photo: '' for a master photo, the copy name for a
-- virtual copy.
function PathUtil.variantName(isVirtualCopy, copyName, localId)
	if not isVirtualCopy then return '' end
	if type(copyName) ~= 'string' or copyName == '' then return 'copy ' .. tostring(localId) end
	return copyName
end

return PathUtil
