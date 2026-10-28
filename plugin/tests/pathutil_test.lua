package.path = arg[1] .. '/?.lua;' .. package.path
local PathUtil = require 'PathUtil'
local function eq(a, b, msg) if a ~= b then error((msg or '') .. ': got ' .. tostring(a) .. ' want ' .. tostring(b), 2) end end
local root = '/Volumes/photo/My Raw Photos/'
eq(PathUtil.relative('/Volumes/photo/My Raw Photos/DCIM/100_FUJI/DSCF0001.RAF', root), 'DCIM/100_FUJI/DSCF0001.RAF', 'rel')
eq(PathUtil.relative('/volumes/PHOTO/my raw photos/x.RAF', root), 'x.RAF', 'case-insensitive root')
eq(PathUtil.relative('/Volumes/photo/My Raw PhotosX/x.RAF', root), nil, 'sibling prefix')
eq(PathUtil.relative('/Volumes/photo/My Raw Photos', root), nil, 'root itself')
eq(PathUtil.relative('/Volumes/photo/My Raw Photos/../x.RAF', root), nil, 'dotdot')
eq(PathUtil.relative(nil, root), nil, 'nil path')
eq(PathUtil.relative('/x/y.RAF', '/'), nil, 'root /')
-- safeName mirrors the container's
eq(PathUtil.safeName('Copy 1'), 'Copy 1'); eq(PathUtil.safeName('a/b:c'), 'a_b_c'); eq(PathUtil.safeName(' .. '), 'copy')
eq(PathUtil.safeName('..x. '), 'x'); eq(PathUtil.safeName(string.rep('é', 100)), string.rep('é', 80), 'rune truncation')
-- idMatches
local rel = 'DCIM/100_FUJI/DSCF0001.RAF'
eq(PathUtil.idMatches('DCIM/100_FUJI/DSCF0001.jpg', rel, ''), true, 'plain')
eq(PathUtil.idMatches('dcim/100_fuji/dscf0001.JPG', rel, ''), true, 'case')
eq(PathUtil.idMatches('DCIM/100_FUJI/DSCF0001-raf.jpg', rel, ''), true, 'clash suffix')
eq(PathUtil.idMatches('DCIM/100_FUJI/DSCF0001-raf-3.jpg', rel, ''), true, 'clash suffix n')
eq(PathUtil.idMatches('DCIM/OTHER/DSCF0001.jpg', rel, ''), false, 'moved')
eq(PathUtil.idMatches('DCIM/100_FUJI/DSCF0001-Copy 1.jpg', rel, ''), false, 'master vs copy id')
eq(PathUtil.idMatches('DCIM/100_FUJI/DSCF0001-Copy 1.jpg', rel, 'Copy 1'), true, 'copy')
eq(PathUtil.idMatches('DCIM/100_FUJI/DSCF0001-Copy 1.jpg', rel, 'Sunset'), false, 'renamed copy')
eq(PathUtil.idMatches('DCIM/100_FUJI/DSCF00011.jpg', rel, ''), false, 'longer name')
eq(PathUtil.idMatches('x/noext-raw.jpg', 'x/noext', ''), true, 'no extension')
eq(PathUtil.variantName(false, 'x', 1), ''); eq(PathUtil.variantName(true, '', 7), 'copy 7'); eq(PathUtil.variantName(true, 'A', 7), 'A')
print('pathutil tests ok')
