-- The three runtime files together, as mods load them: two copies of each,
-- a copy of another version beside them, and a typical guarded mod loop (a few
-- reads, a page check and the clock per frame) that must allocate nothing,
-- interpreted, compiled and across JIT flushes. Run by tests/test_runtime.py in
-- a LuaJIT executable and in the game's lua51.dll.
-- arg[1] the runtime folder, arg[2] hostile_vm.lua.
local folder, helper_path = assert(arg[1]), assert(arg[2])
local ffi = require('ffi')
local H = dofile(helper_path)

local passed = 0
local function check(name, condition, detail)
    if not condition then error(name .. (detail ~= nil and (': ' .. tostring(detail)) or ''), 2) end
    passed = passed + 1
end

local function source(name)
    local file = assert(io.open(folder .. '/' .. name, 'rb'))
    local text = file:read('*a')
    file:close()
    return text
end

-- One mod's set: core, memory api, write side.
local function load_set(core_text, memory_text, write_text, label)
    local runtime = assert(loadstring(core_text, '=' .. label .. ' bingus_runtime.lua'))()
    local memory = assert(loadstring(memory_text, '=' .. label .. ' bingus_memory.lua'))().new(runtime)
    assert(loadstring(write_text, '=' .. label .. ' bingus_write.lua'))().extend(memory)
    return runtime, memory
end

-- 1. Two mods with copies of version 1, and a mod with a version 2 ----------------------------------

local core, memory_source, write_source = source('bingus_runtime.lua'), source('bingus_memory.lua'), source('bingus_write.lua')
local runtime_a, api_a = load_set(core, memory_source, write_source, 'mod A')
local runtime_b, api_b = load_set(core, memory_source, write_source, 'mod B')
check('separate copies', runtime_a ~= runtime_b and api_a ~= api_b and api_a.write ~= api_b.write)
check('one shared table', runtime_a.shared() == runtime_b.shared())

-- A later version renames its FFI names (bingus_memory2_*, bingus_write2_*) and
-- keeps the shared table's layout: both versions run side by side.
local function version_2(text)
    local renamed = text:gsub('bingus_memory1_', 'bingus_memory2_'):gsub('bingus_write1_', 'bingus_write2_')
        :gsub('VERSION = 1}', 'VERSION = 2}')
    return renamed
end
local runtime_2, api_2 = load_set(version_2(core), version_2(memory_source), version_2(write_source), 'mod C')
check('version 2 loaded', runtime_2.VERSION == 2 and runtime_2.shared() == runtime_a.shared())
check('both versions recorded', runtime_a.shared().versions[1] == true and runtime_a.shared().versions[2] == true)
check('each version has its own declarations', pcall(ffi.typeof, 'bingus_memory1_region')
    and pcall(ffi.typeof, 'bingus_memory2_region') and pcall(ffi.typeof, 'bingus_write2_declared'))

local PAGE = 4096
ffi.cdef [[
    void *rtt_VirtualAlloc(void *address, size_t size, uint32_t type, uint32_t protection) __asm__("VirtualAlloc");
    int rtt_VirtualFree(void *address, size_t size, uint32_t type) __asm__("VirtualFree");
]]
local kernel = ffi.load('kernel32')
local block = kernel.rtt_VirtualAlloc(nil, PAGE, 0x3000, 4)
check('allocation', block ~= nil)
local data = ffi.cast('uint8_t *', block)
for i = 0, 255 do data[i] = i end

for label, api in pairs({['mod A'] = api_a, ['mod B'] = api_b, ['mod C (version 2)'] = api_2}) do
    check(label .. ': read', api.read(data + 1, 2) == '\1\2')
    check(label .. ': write', api.write(data + 64, '\64') and data[64] == 64)
    check(label .. ': page check', api.writable_data(data, PAGE) and not api.writable_data(api.module(nil), 1))
    check(label .. ': time', type(api.time()) == 'number')
end

do -- the module hash is read once for all of them, whatever the version
    local shared = runtime_a.shared()
    local reads, exe = shared.hash_reads, api_a.module(nil)
    local hash = api_a.module_hash(exe)
    check('one hash for every copy and version', api_b.module_hash(exe) == hash and api_2.module_hash(exe) == hash
        and shared.hash_reads <= reads + 1)
end

-- 2. Guards of every copy and version on one update chain -------------------------------------------

local env = {frames = 0}
env.update = function() env.frames = env.frames + 1 end
local steps = {a = 0, b = 0, c = 0}
local guard_a = runtime_a.guard({name = 'mod A', env = env, step = function() steps.a = steps.a + 1 end}).install()
local guard_b = runtime_b.guard({name = 'mod B', env = env, step = function() steps.b = steps.b + 1 end}).install()
local guard_c = runtime_2.guard({name = 'mod C', env = env, step = function() steps.c = steps.c + 1 end}).install()
for _ = 1, 10 do env.update(1) end
check('three guards chained', env.frames == 10 and steps.a == 10 and steps.b == 10 and steps.c == 10)
local statuses = runtime_a.shared(env).statuses
check('one status each, by name and version', statuses['mod A'] == guard_a.status and statuses['mod C'] == guard_c.status
    and guard_b.status.version == 1 and guard_c.status.version == 2)
check('a duplicate name refused across copies', not pcall(runtime_b.guard, {name = 'mod A', env = env}))
env.shutdown = nil
check('all running', guard_a.running() and guard_b.running() and guard_c.running())

-- 3. A typical mod loop allocates nothing -------------------------------------------------------------

-- Per frame: the clock, two reads into kept buffers and a page check before the
-- update below; one more read after it.
local function typical_mod(api, game)
    local header, record = ffi.new('uint8_t[16]'), ffi.new('uint8_t[64]')
    local source_address, record_address = data, data + 64
    local stats = {frames = 0, sum = 0, last = 0}
    local function step()
        local now = api.time()
        if now < stats.last then error('the clock went back') end
        stats.last = now
        if api.read_into(source_address, 16, header) and api.read_into(record_address, 64, record)
            and api.writable_data(record_address, 64) then
            stats.sum = stats.sum + header[1] + record[0] + api.distance(record_address, source_address)
        end
    end
    local function after()
        if api.read_into(record_address, 16, header) then stats.frames = stats.frames + 1 end
    end
    local guard = runtime_a.guard({name = 'typical', env = game, step = step, after = after}).install()
    return guard, stats
end
local game = {update = function() end}
local guard, stats = typical_mod(api_a, game)
local function frames(n) for _ = 1, n do game.update(1 / 60) end end
local flush = H.jit_churn()

jit.off()
flush()
frames(200)
local interpreted = H.heap_peak(frames, 20000) * 1024
jit.on()
check('20000 interpreted frames allocate nothing', interpreted == 0, interpreted .. ' B')

frames(20000)
local compiled = H.heap_peak(frames, 20000) * 1024
check('20000 compiled frames allocate nothing', compiled == 0, compiled .. ' B')

local restore = H.gc_hostile()
for _ = 1, 3 do flush(); frames(5000) end
restore()
check('the loop survives JIT flushes and a hostile GC pause', guard.running() and guard.status.errors == 0
    and stats.frames == 200 + 20000 * 3 + 15000 and stats.sum > 0)
check('the loop compiled again after the flushes', H.heap_peak(frames, 20000) * 1024 == 0)

kernel.rtt_VirtualFree(block, 0, 0x8000)

print('runtime together: ' .. passed .. ' checks passed (' .. jit.version .. ')')
