-- bingus_runtime.lua in a hostile VM: clashing Windows prototypes declared first,
-- two copies of the runtime, C-type growth, allocations, write checks and the
-- update guard against abusive neighbours. Run by tests/test_runtime.py in the
-- workspace LuaJIT and in the game's lua51.dll.
-- arg[1] runtime, arg[2] hostile_vm.lua, arg[3] SHA-256 of this process's executable.
local runtime_path, helper_path, exe_sha256 = assert(arg[1]), assert(arg[2]), assert(arg[3])
local ffi = require('ffi')
local H = dofile(helper_path)

local passed = 0
local function check(name, condition, detail)
    if not condition then error(name .. (detail ~= nil and (': ' .. tostring(detail)) or ''), 2) end
    passed = passed + 1
end

-- Another mod loaded first and declared the same Windows functions with other
-- prototypes. A runtime using the plain names would fail on every call.
local PLAIN = {'GetModuleHandleA', 'GetModuleFileNameW', 'GetCurrentProcess', 'ReadProcessMemory',
               'WriteProcessMemory', 'VirtualQuery', 'CreateFileW', 'ReadFile', 'CloseHandle'}
local clash = H.clash(PLAIN)
for _, name in ipairs(PLAIN) do check('clashed ' .. name, clash[name] == 'clashed', clash[name]) end

ffi.cdef [[
    void *rtt_VirtualAlloc(void *address, size_t size, uint32_t type, uint32_t protection) __asm__("VirtualAlloc");
    int rtt_VirtualProtect(void *address, size_t size, uint32_t protection, uint32_t *old) __asm__("VirtualProtect");
    int rtt_VirtualFree(void *address, size_t size, uint32_t type) __asm__("VirtualFree");
]]
local kernel = ffi.load('kernel32')
local PAGE = 4096
local function allocate(pages, protection)
    local block = kernel.rtt_VirtualAlloc(nil, PAGE * pages, 0x3000, protection or 4)
    check('allocation', block ~= nil)
    return ffi.cast('uint8_t *', block)
end
local function protect(address, size, protection)
    check('protect', kernel.rtt_VirtualProtect(address, size, protection, ffi.new('uint32_t[1]')) ~= 0)
end

-- 1. Two copies, private names ------------------------------------------------------

local runtime = dofile(runtime_path)
local other = dofile(runtime_path)
check('version', runtime.VERSION == 1 and other.VERSION == 1)
local api = runtime.memory()
local api2 = other.memory()
check('a second copy binds without redeclaring', api2 ~= nil)
for _, name in ipairs({'BCryptHashData', 'BCryptOpenAlgorithmProvider'}) do
    check('no plain declaration of ' .. name, not pcall(function() return ffi.C[name] end))
end
check('one shared table', runtime.shared() == other.shared() and rawget(_G, 'BingusRuntime') == runtime.shared())
check('the shared table records the version', runtime.shared().versions[1] == true)

-- 2. Reads ---------------------------------------------------------------------------

local data = allocate(2)
for i = 0, 255 do data[i] = i end
check('read', api.read(data, 4) == '\0\1\2\3')
check('read at an offset', api.read(data + 250, 6) == '\250\251\252\253\254\255')
check('unreadable memory returns nil', api.read(ffi.cast('uint8_t *', 1), 8) == nil)
local into = ffi.new('uint8_t[16]')
check('read_into', api.read_into(data + 16, 16, into) and into[0] == 16 and into[15] == 31)
check('read_into an unreadable address', not api.read_into(ffi.cast('uint8_t *', 1), 16, into))
check('a large read grows the scratch buffer', #api.read(data, PAGE * 2) == PAGE * 2)

local kb = H.heap_peak(function()
    for _ = 1, 20000 do api.read_into(data, 16, into) end
end)
check('read_into allocates nothing (20000 calls)', kb < 16, kb)

-- 3. Pointers --------------------------------------------------------------------------

check('pointer decode', api.address(api.pointer('\0\0\0\0\0\0\0\0' .. '\16\32\48\64\80\96\0\0', 8))
    == 0x605040302010)
check('pointer below 64 KB', api.pointer('\0\0\0\0\0\0\0\0') == nil)
check('pointer outside user space', api.pointer('\0\0\0\0\0\128\0\0') == nil
    and api.pointer('\1\0\0\0\0\0\1\0') == nil)
check('pointer out of range', api.pointer('\1\2\3', 0) == nil and api.pointer(nil) == nil
    and api.pointer(string.rep('\1', 8), 1) == nil)
check('distance', api.distance(data + 40, data) == 40)

-- 4. Writes: one VirtualQuery per region, only into private read-write memory ---------------

local before = api.queries
check('write', api.write(data + 100, '\9\9\9'))
check('the bytes landed', data[100] == 9 and data[102] == 9)
check('one query per write in one region', api.queries == before + 1, api.queries - before)
check('refill', api.read_into(data + 16, 16, into) and into[0] == 16)
check('write from a buffer', api.write(data + 200, into, 4) and data[200] == 16 and data[203] == 19)

local readonly = allocate(1)
readonly[0] = 7
protect(readonly, PAGE, 2)
check('read-only memory refused', not api.write(readonly, '\1') and readonly[0] == 7)
local code = allocate(1, 0x40)
check('executable memory refused', not api.write(code, '\1'))
check('a module image refused', not api.write(api.module(nil), '\0'))
check('unmapped memory refused', not api.write(ffi.cast('uint8_t *', 1), '\0'))
check('an empty write refused', not api.writable_data(data, 0))

-- A write that runs from read-write memory into read-only memory is refused whole.
local split = allocate(2)
protect(split + PAGE, PAGE, 2)
before = api.queries
check('a write across into read-only memory refused', not api.write(split + PAGE - 2, '\1\1\1\1')
    and split[PAGE - 2] == 0)
check('two regions, two queries', api.queries == before + 2, api.queries - before)

before = api.queries
local ok, count = api.write_batch(data, PAGE, {{0, '\5'}, {10, '\6\6'}, {PAGE - 1, '\7'}})
check('batch', ok and count == 3 and data[0] == 5 and data[11] == 6 and data[PAGE - 1] == 7)
check('one query per batch', api.queries == before + 1)
ok, count = api.write_batch(data, PAGE, {{0, '\8'}, {PAGE, '\8'}})
check('a batch stops at a write outside its range', not ok and count == 1 and data[0] == 8)
ok, count = api.write_batch(readonly, PAGE, {{0, '\1'}})
check('a batch into read-only memory writes nothing', not ok and count == 0 and readonly[0] == 7)

local growth = H.ctype_growth(function()
    for _ = 1, 500 do
        api.read(data, 8); api.read_into(data, 8, into); api.write(data + 300, '\1')
        api.writable_data(data, 16); api.pointer('\16\32\48\64\80\96\0\0'); api.distance(data + 1, data)
        api.write_batch(data, 64, {{1, '\2'}})
    end
end)
check('no C types created per call', growth == 0, growth)

-- 5. Module hash: once per session for every copy ---------------------------------------------

local exe = api.module(nil)
check('module handle', exe ~= nil and api.module('no-such-module.dll') == nil)
local reads = runtime.shared().hash_reads
check('module SHA-256', api.module_hash(exe) == exe_sha256, api.module_hash(exe))
check('the executable was read once', runtime.shared().hash_reads == reads + 1)
check('the same session result for another mod', api2.module_hash(exe) == exe_sha256
    and other.memory().module_hash(exe) == exe_sha256 and runtime.shared().hash_reads == reads + 1)
local verified, why = api.verify_build({exe_sha256 = exe_sha256, game_sha256 = 'x'})
check('a test process has no game.dll', not verified and why == 'game modules unavailable', why)

kernel.rtt_VirtualFree(data, 0, 0x8000); kernel.rtt_VirtualFree(readonly, 0, 0x8000)
kernel.rtt_VirtualFree(code, 0, 0x8000); kernel.rtt_VirtualFree(split, 0, 0x8000)

-- 6. Update guard -----------------------------------------------------------------------------

local function environment()
    local env = {calls = 0, shutdowns = 0}
    env.update = function(dt, a, b)
        env.calls = env.calls + 1
        env.seen = {n = select('#', dt, a, b), dt, a, b}
        return 'r1', nil, 'r3'
    end
    env.shutdown = function(...)
        env.shutdowns = env.shutdowns + 1
        return 's1', ...
    end
    return env
end
local function pack(...) return {n = select('#', ...), ...} end

do -- forwarding, step and after, status
    local env, steps, afters = environment(), 0, 0
    local guard = runtime.guard({name = 'forwarding', env = env, step = function(dt) steps = steps + dt end,
        after = function() afters = afters + 1 end}).install()
    local r = pack(env.update(1, nil, 'z'))
    check('returns forwarded', r.n == 3 and r[1] == 'r1' and r[2] == nil and r[3] == 'r3')
    check('arguments forwarded', env.seen.n == 3 and env.seen[1] == 1 and env.seen[2] == nil and env.seen[3] == 'z')
    check('step and after ran', steps == 1 and afters == 1)
    check('status registered in the globals the guard wraps', runtime.shared(env).statuses.forwarding == guard.status
        and guard.status.state == 'running' and guard.running())
    check('installing twice refused', not pcall(guard.install))
    check('a second guard with the name refused', not pcall(runtime.guard, {name = 'forwarding', env = env}))
    local s = pack(env.shutdown('q', nil))
    check('shutdown forwarded', s.n == 3 and s[1] == 's1' and s[2] == 'q' and env.shutdowns == 1)
    check('a clean session', guard.status.state == 'stopped' and not guard.running())
end

do -- P1: the previous update's error passes unchanged; the next frame stops once
    local env, steps, stops = environment(), 0, 0
    H.chain(env, 'throw_below', {raise_on = 2})
    local guard = runtime.guard({name = 'p1', env = env, step = function() steps = steps + 1 end,
        stop = function(reason) stops = stops + 1; error('cleanup also failed') end}).install()
    env.update(1)
    local ok, thrown = pcall(env.update, 1)
    check('the error object passes unchanged', not ok and type(thrown) == 'table' and thrown.hostile_vm == 'throw_below')
    check('not stopped inside the failing frame', guard.running() and stops == 0)
    local r = pack(env.update(1, 'a'))
    check('the next frame stops once and still forwards', r.n == 3 and r[1] == 'r1' and stops == 1 and steps == 2)
    check('status names the failure', guard.status.state == 'stopped: the previous update failed')
    check('a failing stop is kept, not raised', guard.status.stop_error:find('cleanup also failed', 1, true))
    env.update(1); env.update(1)
    check('stopped for good', steps == 2 and stops == 1)
    env.shutdown()
    check('P2: the first failure survives shutdown', guard.status.state == 'stopped after: the previous update failed')
    H.chain_restore(env)
end

do -- the traceback of a raised error starts where it was raised
    local env = environment()
    local function vanilla_update_raises() error('vanilla failure') end
    env.update = function() vanilla_update_raises() end
    runtime.guard({name = 'traceback', env = env}).install()
    local ok, trace = xpcall(env.update, debug.traceback, 1)
    check('traceback from the raising function', not ok and trace:find('vanilla_update_raises', 1, true), trace)
    local _, message = pcall(env.update, 1)
    local _, expected = pcall(vanilla_update_raises)
    check('message unchanged', message == expected, message)
end

do -- P3: a failing step stops after 8 errors with one log line, then never runs
    local env, calls, lines = environment(), 0, {}
    local guard = runtime.guard({name = 'p3', env = env, log = function(line) lines[#lines + 1] = line end,
        step = function() calls = calls + 1; error('step failed ' .. calls) end}).install()
    for _ = 1, 30 do check('forwarding while failing', select('#', env.update(1)) == 3) end
    check('8 step calls, then none', calls == 8 and guard.status.errors == 8, calls)
    check('two lines: first error and stop', #lines == 2 and lines[1]:find('step failed 1', 1, true)
        and lines[2]:find('stopped after 8 errors', 1, true), #lines)
    check('stopped status', guard.status.state:find('^stopped: stopped after 8 errors: .*step failed 1'))
    check('every frame still reached the game', env.calls == 30)
    env.shutdown()
    check('shutdown keeps the step failure', guard.status.state:find('^stopped after: stopped after 8 errors'))
end

do -- errors in after count too; a recovering step keeps running until the 8th error
    local env, n = environment(), 0
    local guard = runtime.guard({name = 'recovering', env = env,
        step = function() n = n + 1; if n <= 3 then error('transient') end end,
        after = function() if n == 20 then error('after failed') end end}).install()
    for _ = 1, 25 do env.update(1) end
    check('3 step errors and 1 after error', guard.status.errors == 4 and guard.running() and n == 25)
end

do -- a refusal is the first failure
    local env, stops = environment(), 0
    local guard = runtime.guard({name = 'refusal', env = env, stop = function() stops = stops + 1 end}).install()
    guard.stop('unsupported game build')
    guard.stop('a second stop')
    env.update(1)
    env.shutdown()
    check('refusal kept; stop work ran once', guard.status.state == 'stopped after: unsupported game build'
        and stops == 1, stops)
end

do -- the game's update is required
    local env = environment()
    env.update = nil
    check('no game update', not pcall(runtime.guard({name = 'no-update', env = env}).install))
end

do -- abusive neighbours above and below
    local env, steps = environment(), 0
    H.chain(env, 'double_call')
    local guard = runtime.guard({name = 'neighbours', env = env, step = function() steps = steps + 1 end}).install()
    H.chain(env, 'drop_args')
    H.chain(env, 'rehook')
    for _ = 1, 10 do env.update(1, 'kept?') end
    check('a neighbour calling below twice is not a failure', guard.running() and steps == 10, steps)
    check('the game update ran twice per frame', env.calls == 20, env.calls)
    H.chain_restore(env)
end

do -- no allocation and no closure per frame
    local env = environment()
    env.update = function() end
    runtime.guard({name = 'garbage', env = env, step = function() end, after = function() end}).install()
    for _ = 1, 100 do env.update(1) end
    local garbage = H.heap_peak(function() for _ = 1, 20000 do env.update(1) end end)
    check('20000 guarded frames allocate nothing', garbage < 16, garbage)
end

print('bingus_runtime: ' .. passed .. ' checks passed (' .. jit.version .. ')')
