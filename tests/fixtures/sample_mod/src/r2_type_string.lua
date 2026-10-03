-- R2 fixture: type strings that create a new C type on every evaluation.
local ffi = require('ffi')
local cast = ffi.cast
local SIGNATURE = 'void (*)(void *)'
local NAMED = 'SampleCallback'
local function call(address)
    ffi.cast('void (*)(void *)', address)(nil) -- expect: R2
    ffi.cast(SIGNATURE, address)(nil) -- expect: R2 (through a string constant)
    local point = ffi.new('struct { int x, y; }') -- expect: R2
    local fast = ffi.cast('void (__fastcall *)(void *, int)', address) -- expect: R2
    local aliased = cast('int (*)(int)', address) -- expect: R2 (through a local alias)
    local bits = ffi.typeof('union { float f; uint32_t u; }') -- expect: R2
    local named = ffi.cast(NAMED, address)
    local typed = ffi.cast('SampleCallback', address)
    local bytes = ffi.new('uint8_t[?]', 16)
    local words = ffi.cast('uint32_t *', bytes)
    return point, fast, aliased, bits, named, typed, words
end
return call
