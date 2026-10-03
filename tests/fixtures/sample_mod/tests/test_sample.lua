-- Test-file fixture: with --tests rules R1-R7 apply here; R8 and R9 never do.
local ffi = require('ffi')
ffi.cdef('int TestOnlyFunction(int value);') -- expect: R1
leaked_test_global = true
local ok = pcall(previous, 1)
collectgarbage('collect') -- expect: R4
return ok
