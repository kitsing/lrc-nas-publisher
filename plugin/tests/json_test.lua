package.path = arg[1] .. '/?.lua;' .. package.path
local Json = require 'Json'
local function eq(a, b, msg) if a ~= b then error((msg or '') .. ': got ' .. tostring(a) .. ' want ' .. tostring(b), 2) end end
eq(Json.encode({ a = 1, b = 'x"y\n', c = { 1, 2, 3 }, d = true, e = Json.null }), '{"a":1,"b":"x\\"y\\n","c":[1,2,3],"d":true,"e":null}', 'encode')
eq(Json.encode(Json.array()), '[]', 'empty array'); eq(Json.encode({}), '{}', 'empty object')
eq(Json.encode(1.5), '1.5'); eq(Json.encode(814855365.89823), '814855365.89823', 'float')
eq(Json.encode('Photo Booth 圖庫'), '"Photo Booth 圖庫"', 'utf8 passthrough')
local v = assert(Json.decode('{"ok":true,"id":"DCIM/100_FUJI/DSCF0001.jpg","bytes":5004,"items":[{"rel":"a\\/b","m":"\\u5716\\u5eab \\ud83d\\ude00"}],"n":null,"x":-1.5e3,"e":[]}'))
eq(v.ok, true); eq(v.id, 'DCIM/100_FUJI/DSCF0001.jpg'); eq(v.bytes, 5004); eq(v.items[1].rel, 'a/b'); eq(v.items[1].m, '圖庫 😀', 'unicode escapes')
eq(v.n, Json.null); eq(v.x, -1500); eq(#v.e, 0)
local results = assert(Json.decode('{"results":{"d/A.jpg":"deleted","d/gone.jpg":"missing"}}')).results
eq(results['d/A.jpg'], 'deleted')
for _, bad in ipairs({ '', '{', '{"a":}', '[1,]', '"abc', '{"a":1} x', 'nul' }) do
  local r, err = Json.decode(bad); assert(r == nil and err, 'should fail: ' .. bad)
end
-- round trip
local t = { s = 'tab\there \\ "q"', arr = { 'a', 'b' }, nested = { k = { 1, { z = false } } } }
local back = assert(Json.decode(Json.encode(t)))
eq(back.s, t.s); eq(back.arr[2], 'b'); eq(back.nested.k[2].z, false)
print('json tests ok')
