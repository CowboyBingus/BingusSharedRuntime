-- R3 fixture: stores through FFI pointers into (possibly game) memory.
local ffi = require('ffi')
local BYTES, WORDS = ffi.cast('uint8_t *', 0), ffi.cast('uint32_t *', 0)
local scratch = ffi.cast('uint32_t *', ffi.new('uint32_t[4]'))
local M = {}
function M.store(address, value)
    ffi.cast('float *', address)[0] = value -- expect: R3
    ffi.cast('struct SampleThing *', address).count = value -- expect: R3
    BYTES[address] = value -- expect: R3 (pointer cast from a constant address)
    WORDS[address / 4] = value -- expect: R3
    pcall(function() ffi.cast('uint16_t *', address)[1] = value end) -- expect: R3
    scratch[0] = value
    local current = ffi.cast('float *', address)[0]
    if ffi.cast('uint8_t *', address)[0] == 1 then return current end
    return BYTES[address] + WORDS[address / 4]
end
return M
