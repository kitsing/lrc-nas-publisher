package.path = arg[1] .. '/?.lua;' .. package.path
local JpegSize = require 'JpegSize'
local function eq(a, b, msg) if a ~= b then error((msg or '') .. ': got ' .. tostring(a) .. ' want ' .. tostring(b), 2) end end
local w, h = JpegSize.read(arg[2] .. '/fixtures/small.jpg')
eq(math.max(w, h), 300, 'long edge'); assert(math.min(w, h) > 100 and math.min(w, h) < 300, 'short edge')
local tmp = os.tmpname(); local f = io.open(tmp, 'wb'); f:write('not a jpeg'); f:close()
local a, err = JpegSize.read(tmp); assert(a == nil and err == 'not a JPEG')
f = io.open(tmp, 'wb'); f:write('\255\216\255\224\0\16JFIF'); f:close()
a, err = JpegSize.read(tmp); assert(a == nil, 'truncated file has no size')
os.remove(tmp)
eq(JpegSize.fullSize(11648, 8736, { width = 11648, height = 8736 }), true, 'full')
eq(JpegSize.fullSize(2560, 1920, { width = 11648, height = 8736 }), false, 'smart preview')
eq(JpegSize.fullSize(8736, 11648, { width = 11648, height = 8736 }), true, 'rotated')
eq(JpegSize.fullSize(2000, 1500, { width = 2000, height = 1500 }), true, 'small original')
eq(JpegSize.fullSize(2560, 1920, nil), true, 'unknown size')
print('jpegsize tests ok')
