-- bingus_memory.lua with the core and without bingus_write.lua: reads, page
-- checks, addresses, time() and module hashes against this process's real
-- memory, plus allocation and C-type growth per call. Run by tests/test_runtime.py
-- in a LuaJIT executable and in the game's lua51.dll.
-- arg[1] the runtime folder, arg[2] hostile_vm.lua, arg[3] SHA-256 of this process's executable.
local folder, helper_path, exe_sha256 = assert(arg[1]), assert(arg[2]), assert(arg[3])
local ffi = require('ffi')
local H = dofile(helper_path)

local passed = 0
local function check(name, condition, detail)
    if not condition then error(name .. (detail ~= nil and (': ' .. tostring(detail)) or ''), 2) end
    passed = passed + 1
end

-- Test-only Windows functions, under private names.
ffi.cdef [[
    void *rtm_VirtualAlloc(void *address, size_t size, uint32_t type, uint32_t protection) __asm__("VirtualAlloc");
    int rtm_VirtualProtect(void *address, size_t size, uint32_t protection, uint32_t *old) __asm__("VirtualProtect");
    int rtm_VirtualFree(void *address, size_t size, uint32_t type) __asm__("VirtualFree");
    uint32_t rtm_GetTickCount(void) __asm__("GetTickCount");
]]
local kernel = ffi.load('kernel32')
local PAGE = 4096
local blocks = {}
local function allocate(pages, protection)
    local block = kernel.rtm_VirtualAlloc(nil, PAGE * pages, 0x3000, protection or 4)
    check('allocation', block ~= nil)
    blocks[#blocks + 1] = block
    return ffi.cast('uint8_t *', block)
end
local function protect(address, size, protection)
    check('protect', kernel.rtm_VirtualProtect(address, size, protection, ffi.new('uint32_t[1]')) ~= 0)
end

-- Bytes allocated by n calls of fn, after a warm-up: the median of three
-- windows, with the JIT on (compiled) or off and flushed (interpreted).
local flush = H.jit_churn()
local function allocated(fn, n, compiled)
    flush()
    if not compiled then jit.off() end
    local function loop() for _ = 1, n do fn() end end
    loop(); loop()
    local windows = {}
    for i = 1, 3 do windows[i] = H.heap_peak(loop) * 1024 end
    jit.on()
    table.sort(windows)
    return windows[2]
end

-- 1. Loading: two copies, private names, no write side ------------------------------------------

local runtime = dofile(folder .. '/bingus_runtime.lua')
local memory_lib = dofile(folder .. '/bingus_memory.lua')
local memory_lib2 = dofile(folder .. '/bingus_memory.lua')
check('version', memory_lib.VERSION == 1 and memory_lib2.VERSION == 1)
check('new needs the core', not pcall(memory_lib.new) and not pcall(memory_lib.new, {})
    and select(2, pcall(memory_lib.new)):find('bingus_runtime.lua', 1, true))
local api = memory_lib.new(runtime)
local api2 = memory_lib2.new(runtime)
local api3 = memory_lib.new(runtime)
check('a second copy binds without redeclaring', api2 ~= nil and api2.read ~= api.read)
check('the sentinel type exists', pcall(ffi.typeof, 'bingus_memory1_region'))
local NAMES = {'GetModuleHandleA', 'GetModuleFileNameW', 'GetCurrentProcess', 'ReadProcessMemory', 'VirtualQuery',
               'QueryPerformanceCounter', 'QueryPerformanceFrequency', 'CreateFileW', 'ReadFile', 'CloseHandle',
               'BCryptOpenAlgorithmProvider', 'BCryptCloseAlgorithmProvider', 'BCryptCreateHash', 'BCryptHashData',
               'BCryptFinishHash', 'BCryptDestroyHash'}
for _, name in ipairs(NAMES) do
    check('no plain declaration of ' .. name, not pcall(function() return ffi.C[name] end))
    local library = name:find('^BCrypt') and api.windows.bcrypt or api.windows.kernel32
    check('bound: ' .. name, type(library[name]) == 'cdata')
end
check('the windows table', api.windows.ffi == ffi and api3.windows == api.windows and api2.windows ~= api.windows)
check('the read side binds no write function', api.windows.kernel32.WriteProcessMemory == nil
    and api.write == nil and api.write_batch == nil)
check('the shared table records the core version', runtime.shared().versions[1] == true)

-- 2. Reads ------------------------------------------------------------------------------------------

local data = allocate(2)
for i = 0, 255 do data[i] = i end
check('read', api.read(data, 4) == '\0\1\2\3')
check('read at an offset', api.read(data + 250, 6) == '\250\251\252\253\254\255')
check('unreadable memory returns nil', api.read(ffi.cast('uint8_t *', 1), 8) == nil)
check('a read running into unmapped memory returns nil', api.read(data + 2 * PAGE - 4, 8) == nil)
check('a nil address reads nothing', api.read(nil, 8) == nil)
local into = ffi.new('uint8_t[16]')
check('read_into', api.read_into(data + 16, 16, into) and into[0] == 16 and into[15] == 31)
check('read_into an unreadable address', not api.read_into(ffi.cast('uint8_t *', 1), 16, into))
check('a large read grows the scratch buffer', #api.read(data, PAGE * 2) == PAGE * 2)
check('then smaller reads still work', api.read(data + 1, 2) == '\1\2')
check('separate apis keep separate buffers', api2.read(data, 2) == '\0\1' and api.read(data + 3, 1) == '\3')

-- 3. Pointers and addresses ---------------------------------------------------------------------------

check('pointer decode', api.address(api.pointer('\0\0\0\0\0\0\0\0' .. '\16\32\48\64\80\96\0\0', 8))
    == 0x605040302010)
check('pointer below 64 KB', api.pointer('\0\0\0\0\0\0\0\0') == nil)
check('pointer outside user space', api.pointer('\0\0\0\0\0\128\0\0') == nil
    and api.pointer('\1\0\0\0\0\0\1\0') == nil)
check('pointer out of range', api.pointer('\1\2\3', 0) == nil and api.pointer(nil) == nil
    and api.pointer(string.rep('\1', 8), 1) == nil)
local base = tonumber(ffi.cast('uintptr_t', data))
check('address of a pointer', api.address(data) == base and api.address(data + 7) == base + 7)
check('address of a number', api.address(base + 3) == base + 3)
check('address of integer cdata', api.address(ffi.new('uint64_t', base)) == base
    and api.address(ffi.cast('uintptr_t', data + 1)) == base + 1)
check('address of nil is 0', api.address(nil) == 0)
check('address of an array', api.address(into) == tonumber(ffi.cast('uintptr_t', into)))
check('an address above 2^32', api.address(ffi.cast('uint8_t *', 0x123456789ab)) == 0x123456789ab)
check('distance', api.distance(data + 40, data) == 40 and api.distance(data, data + 40) == -40
    and api.distance(base + 8, data) == 8)

-- 4. Page checks: one VirtualQuery per region, private read-write memory only ----------------------

local before = api.queries
check('private read-write memory is writable data', api.writable_data(data, 16))
check('one query per region', api.queries == before + 1, api.queries - before)
check('a number address', api.writable_data(base + PAGE, 8))
check('to the end of the region in one query', (function()
    local start = api.queries
    return api.writable_data(data, 2 * PAGE) and api.queries == start + 1
end)())
check('separate apis count separately', api2.queries == 0)

local readonly = allocate(1)
readonly[0] = 7
protect(readonly, PAGE, 2)
check('read-only memory refused', not api.writable_data(readonly, 1))
local guarded = allocate(1, 0x104)
check('guard pages refused', not api.writable_data(guarded, 1))
local code = allocate(1, 0x40)
check('executable memory refused', not api.writable_data(code, 1))
local exe = api.module(nil)
check('a module image refused', not api.writable_data(exe, 1))
check('unmapped memory refused', not api.writable_data(ffi.cast('uint8_t *', 1), 1))
check('nil refused', not api.writable_data(nil, 1))
check('an empty range refused', not api.writable_data(data, 0) and not api.writable_data(data, -1)
    and not api.writable_data(data, nil) and not api.writable_data(data, '8'))

-- A writable page of the executable's own image (its data section) is image
-- memory, not private: refused although its protection allows writing.
local region, image_data = ffi.new('bingus_memory1_region'), nil
do
    local cursor, image = api.address(exe), api.address(exe)
    for _ = 1, 64 do
        if api.windows.kernel32.VirtualQuery(cursor, region, ffi.sizeof(region)) == 0 then break end
        local allocation = region.allocation_base_low + region.allocation_base_high * 4294967296
        if allocation ~= image then break end
        if region.protection == 4 or region.protection == 8 then image_data = cursor; break end
        cursor = region.base_low + region.base_high * 4294967296 + region.size_low + region.size_high * 4294967296
    end
end
check('the executable has a writable image page', image_data ~= nil)
check('a writable image page refused', not api.writable_data(image_data, 8))

-- A range that runs from read-write memory into read-only memory is refused whole.
local split = allocate(2)
protect(split + PAGE, PAGE, 2)
before = api.queries
check('a range across into read-only memory refused', not api.writable_data(split + PAGE - 2, 4))
check('two regions, two queries', api.queries == before + 2, api.queries - before)
before = api.queries
check('a range past the end of an allocation refused', not api.writable_data(data + 2 * PAGE - 2, 4))
check('two queries there too', api.queries == before + 2, api.queries - before)

-- 5. time(): seconds from the performance counter ----------------------------------------------------

check('time is a number', type(api.time()) == 'number' and api.time() > 0)
local function monotonic(n)
    local first = api.time()
    local last = first
    for _ = 1, n do
        local now = api.time()
        if now < last then return false end
        last = now
    end
    return last > first
end
jit.off()
check('time never goes back (interpreted)', monotonic(20000))
jit.on()
check('time never goes back (compiled)', monotonic(200000))
check('copies and apis share the clock', math.abs(api2.time() - api.time()) < 0.01)
do -- seconds, not ticks or milliseconds: against GetTickCount over about 300 ms
    local start_time, start_ticks = api.time(), kernel.rtm_GetTickCount()
    while kernel.rtm_GetTickCount() - start_ticks < 300 do end
    local elapsed, ticks = api.time() - start_time, (kernel.rtm_GetTickCount() - start_ticks) / 1000
    check('time counts seconds', math.abs(elapsed - ticks) < 0.05, elapsed .. ' s against ' .. ticks .. ' s')
end

-- 6. No allocation and no C types per call -------------------------------------------------------------

local cases = {
    {'time', function() return api.time() end},
    {'read_into', function() return api.read_into(data, 16, into) end},
    {'writable_data', function() return api.writable_data(data, 16) end},
    {'writable_data of a number', function() return api.writable_data(base, 16) end},
    {'address', function() return api.address(data) end},
    {'distance', function() return api.distance(data, exe) end},
}
for _, case in ipairs(cases) do
    local interpreted, compiled = allocated(case[2], 2000, false), allocated(case[2], 20000, true)
    check(case[1] .. ' allocates nothing (interpreted)', interpreted == 0, interpreted .. ' B')
    check(case[1] .. ' allocates nothing (compiled)', compiled == 0, compiled .. ' B')
end
do -- read allocates only the string it returns: as much as making that string directly
    local at, n, kept = data + 512, 0, nil
    local words = ffi.cast('uint32_t *', at)
    local function read() n = n + 1; words[0] = n; kept = api.read(at, 8) end
    local function direct() n = n + 1; words[0] = n; kept = ffi.string(at, 8) end
    for _, compiled in ipairs({false, true}) do
        local per_read, per_string = allocated(read, 2000, compiled) / 2000, allocated(direct, 2000, compiled) / 2000
        check('read allocates only its string' .. (compiled and ' (compiled)' or ' (interpreted)'),
            per_read <= per_string + 1, per_read .. ' B per read, ' .. per_string .. ' B per string')
    end
    check('the reads were real', kept ~= nil and #kept == 8)
end

do -- Windows calls per call: counting wrappers in the windows table, in place
   -- before the api is created and while it is called
    local kernel32, calls, real = api.windows.kernel32, {}, {}
    for _, name in ipairs({'ReadProcessMemory', 'VirtualQuery', 'QueryPerformanceCounter', 'QueryPerformanceFrequency'}) do
        real[name], calls[name] = kernel32[name], 0
        kernel32[name] = function(...) calls[name] = calls[name] + 1; return real[name](...) end
    end
    local counted = memory_lib.new(runtime)
    for _ = 1, 10 do counted.time() end
    check('time: one counter read per call, the frequency never again', calls.QueryPerformanceCounter == 10
        and calls.QueryPerformanceFrequency == 0, calls.QueryPerformanceCounter .. ', ' .. calls.QueryPerformanceFrequency)
    for _ = 1, 10 do counted.read_into(data, 4, into); counted.read(data, 4) end
    check('read and read_into: one read per call', calls.ReadProcessMemory == 20, calls.ReadProcessMemory)
    counted.writable_data(data, 16); counted.writable_data(split + PAGE - 2, 4)
    check('writable_data: one query per region, as counted', calls.VirtualQuery == 3 and counted.queries == 3,
        calls.VirtualQuery)
    counted.address(data); counted.distance(data, exe); counted.pointer('\0\0\1\0\0\0\0\0')
    check('address, distance and pointer call nothing', calls.ReadProcessMemory == 20 and calls.VirtualQuery == 3
        and calls.QueryPerformanceCounter == 10 and calls.QueryPerformanceFrequency == 0)
    for name, fn in pairs(real) do kernel32[name] = fn end
end

do -- another copy finds the declarations and makes none: no new C types
    local growth = H.ctype_growth(function() return dofile(folder .. '/bingus_memory.lua').new(runtime) end)
    check('a third copy creates no C types', growth == 0, growth)
end

local growth = H.ctype_growth(function()
    for _ = 1, 500 do
        api.read(data, 8); api.read_into(data, 8, into); api.writable_data(data, 16); api.writable_data(base, 16)
        api.pointer('\16\32\48\64\80\96\0\0'); api.address(data); api.distance(data + 1, data); api.time()
    end
end)
check('no C types created per call', growth == 0, growth)

-- 7. Module hash: once per session for every copy, in the shared table -----------------------------

check('module handle', exe ~= nil and api.module('no-such-module.dll') == nil)
local shared = runtime.shared()
local reads = shared.hash_reads
check('module SHA-256', api.module_hash(exe) == exe_sha256, api.module_hash(exe))
check('the executable was read once', shared.hash_reads == reads + 1)
check('the same session result for another copy', api2.module_hash(exe) == exe_sha256
    and memory_lib2.new(runtime).module_hash(exe) == exe_sha256 and shared.hash_reads == reads + 1)
do -- the key: 'sha256:' and the module's UTF-16 file path
    local path = ffi.new('uint16_t[32768]')
    local length = api.windows.kernel32.GetModuleFileNameW(exe, path, 32768)
    check('the cache key format', shared.hashes['sha256:' .. ffi.string(path, length * 2)] == exe_sha256)
end
local verified, why = api.verify_build({exe_sha256 = exe_sha256, game_sha256 = 'x'})
check('a test process has no game.dll', not verified and why == 'game modules unavailable', why)

do -- the shared table broken by someone else: hashes still work
    local kept = rawget(_G, 'BingusRuntime')
    rawset(_G, 'BingusRuntime', {})
    local ok, hash = pcall(function() return api.module_hash(exe) end)
    check('module hashes still work after BingusRuntime = {}', ok and hash == exe_sha256, hash)
    check('and the table was repaired', type(rawget(_G, 'BingusRuntime').hashes) == 'table')
    rawset(_G, 'BingusRuntime', kept)
end

for _, block in ipairs(blocks) do kernel.rtm_VirtualFree(block, 0, 0x8000) end

print('bingus_memory: ' .. passed .. ' checks passed (' .. jit.version .. ')')
