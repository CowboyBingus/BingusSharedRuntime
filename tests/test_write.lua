-- bingus_write.lua on a bingus_memory.lua api: checked writes into this
-- process's real memory, and refusals on read-only, guard, executable, image and
-- unmapped pages. Run by tests/test_runtime.py in a LuaJIT executable and in the
-- game's lua51.dll.
-- arg[1] the runtime folder, arg[2] hostile_vm.lua.
local folder, helper_path = assert(arg[1]), assert(arg[2])
local ffi = require('ffi')
local H = dofile(helper_path)

local passed = 0
local function check(name, condition, detail)
    if not condition then error(name .. (detail ~= nil and (': ' .. tostring(detail)) or ''), 2) end
    passed = passed + 1
end

-- Test-only Windows functions, under private names.
ffi.cdef [[
    void *rtw_VirtualAlloc(void *address, size_t size, uint32_t type, uint32_t protection) __asm__("VirtualAlloc");
    int rtw_VirtualProtect(void *address, size_t size, uint32_t protection, uint32_t *old) __asm__("VirtualProtect");
    int rtw_VirtualFree(void *address, size_t size, uint32_t type) __asm__("VirtualFree");
]]
local kernel = ffi.load('kernel32')
local PAGE = 4096
local blocks = {}
local function allocate(pages, protection)
    local block = kernel.rtw_VirtualAlloc(nil, PAGE * pages, 0x3000, protection or 4)
    check('allocation', block ~= nil)
    blocks[#blocks + 1] = block
    return ffi.cast('uint8_t *', block)
end
local function protect(address, size, protection)
    check('protect', kernel.rtw_VirtualProtect(address, size, protection, ffi.new('uint32_t[1]')) ~= 0)
end

-- 1. Loading: extend adds the write side to a memory api ------------------------------------------

local runtime = dofile(folder .. '/bingus_runtime.lua')
local memory_lib = dofile(folder .. '/bingus_memory.lua')
local write_lib = dofile(folder .. '/bingus_write.lua')
local write_lib2 = dofile(folder .. '/bingus_write.lua')
check('version', write_lib.VERSION == 1)
check('extend needs a memory api', not pcall(write_lib.extend) and not pcall(write_lib.extend, {})
    and select(2, pcall(write_lib.extend, {})):find('bingus_memory.lua', 1, true))
local reader = memory_lib.new(runtime)
local api = memory_lib.new(runtime)
check('extend returns the api it extended', write_lib.extend(api) == api)
check('write and write_batch added', type(api.write) == 'function' and type(api.write_batch) == 'function')
check('the write function is bound under its Windows name', type(api.native.kernel32.WriteProcessMemory) == 'cdata')
check('the sentinel type exists', pcall(ffi.typeof, 'bingus_write1_declared'))
check('no plain declaration of WriteProcessMemory', not pcall(function() return ffi.C.WriteProcessMemory end))
check('an api that was not extended cannot write', reader.write == nil and reader.write_batch == nil)
local other
local growth = H.ctype_growth(function() other = write_lib2.extend(memory_lib.new(runtime)) end)
check('a second copy extends without redeclaring', type(other.write) == 'function' and other.write ~= api.write)
check('a second copy creates no C types', growth == 0, growth)

-- 2. Writes: one VirtualQuery per region, only into private read-write memory ---------------------

local data = allocate(2)
for i = 0, 255 do data[i] = i end
local into = ffi.new('uint8_t[16]')
local before = api.queries
check('write', api.write(data + 100, '\9\9\9'))
check('the bytes landed', data[100] == 9 and data[101] == 9 and data[102] == 9 and data[103] == 103)
check('one query per write in one region', api.queries == before + 1, api.queries - before)
check('refill', api.read_into(data + 16, 16, into) and into[0] == 16)
check('write from a buffer', api.write(data + 200, into, 4) and data[200] == 16 and data[203] == 19
    and data[204] == 204)
check('an empty write refused', not api.write(data, '') and not api.write(data, into, 0))

do -- the check runs right before every write, through api.writable_data
    local seen, check_range = {}, api.writable_data
    api.writable_data = function(address, size)
        seen[#seen + 1] = size
        return check_range(address, size)
    end
    api.write(data + 8, '\1\2\3\4\5')
    api.write_batch(data, 64, {{1, '\1'}, {2, '\2'}})
    api.writable_data = check_range
    check('each write checks its whole range once', #seen == 2 and seen[1] == 5 and seen[2] == 64, #seen)
end

local readonly = allocate(1)
readonly[0] = 7
protect(readonly, PAGE, 2)
check('read-only memory refused', not api.write(readonly, '\1') and readonly[0] == 7)
local guarded = allocate(1, 0x104)
check('a guard page refused', not api.write(guarded, '\1'))
do -- and untouched: touching a guard page clears its guard flag
    local region = ffi.new('bingus_memory1_region')
    check('the guard page keeps its guard', api.native.kernel32.VirtualQuery(api.address(guarded), region,
        ffi.sizeof(region)) ~= 0 and region.protection == 0x104, region.protection)
end
local code = allocate(1, 0x40)
check('executable memory refused', not api.write(code, '\1') and code[0] == 0)
local exe = api.module(nil)
local header = api.read(exe, 2)
check('a module image refused', not api.write(exe, '\0\0') and api.read(exe, 2) == header)
check('unmapped memory refused', not api.write(ffi.cast('uint8_t *', 1), '\0'))
check('a nil address refused', not api.write(nil, '\0'))

-- A write that runs from read-write memory into read-only memory is refused whole.
local split = allocate(2)
protect(split + PAGE, PAGE, 2)
before = api.queries
check('a write across into read-only memory refused', not api.write(split + PAGE - 2, '\1\1\1\1')
    and split[PAGE - 2] == 0 and split[PAGE - 1] == 0)
check('two regions, two queries', api.queries == before + 2, api.queries - before)

-- 3. Batches: one check for several writes ------------------------------------------------------------

before = api.queries
local ok, count = api.write_batch(data, PAGE, {{0, '\5'}, {10, '\6\6'}, {PAGE - 1, '\7'}})
check('batch', ok and count == 3 and data[0] == 5 and data[10] == 6 and data[11] == 6 and data[PAGE - 1] == 7)
check('one query per batch', api.queries == before + 1, api.queries - before)
ok, count = api.write_batch(data, PAGE, {{0, '\8'}, {PAGE, '\8'}})
check('a batch stops at a write outside its range', not ok and count == 1 and data[0] == 8 and data[PAGE] == 0)
ok, count = api.write_batch(data, PAGE, {{0, '\9'}, {-1, '\9'}})
check('a batch stops at a negative offset', not ok and count == 1 and data[0] == 9)
ok, count = api.write_batch(readonly, PAGE, {{0, '\1'}})
check('a batch into read-only memory writes nothing', not ok and count == 0 and readonly[0] == 7)
ok, count = api.write_batch(api.address(data), 16, {{4, '\4'}})
check('a batch at a number address', ok and count == 1 and data[4] == 4)
ok, count = api.write_batch(data, 16, {})
check('an empty batch', ok and count == 0)

-- 4. No C types per call ---------------------------------------------------------------------------------

local changes = {{1, '\2'}}
local growth = H.ctype_growth(function()
    for _ = 1, 500 do api.write(data + 300, '\1'); api.write(data + 300, into, 2); api.write_batch(data, 64, changes) end
end)
check('no C types created per call', growth == 0, growth)

for _, block in ipairs(blocks) do kernel.rtw_VirtualFree(block, 0, 0x8000) end

print('bingus_write: ' .. passed .. ' checks passed (' .. jit.version .. ')')
