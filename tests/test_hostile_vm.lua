-- Tests for hostile_vm.lua; must pass in the workspace LuaJIT and in the game's lua51.dll:
--   luajit tests/test_hostile_vm.lua [path/to/hostile_vm.lua]
--   python -B ../PerformanceBaseline/game_lua.py tests/test_hostile_vm.lua [path/to/hostile_vm.lua]
-- A failure raises an error (game_lua.py then prints "ERROR:" and exits 1).
local here = (arg and arg[0] or ''):match('^(.*)[/\\][^/\\]*$') or '.'
local H = dofile(arg and arg[1] or (here .. '/../hostile_vm.lua'))
local ffi = require('ffi')

local passed = 0
local function check(name, condition, detail)
    if not condition then
        error('FAIL ' .. name .. (detail ~= nil and (': ' .. tostring(detail)) or ''), 2)
    end
    passed = passed + 1
end

local function raises(fn, ...)
    local ok, problem = pcall(fn, ...)
    return not ok, problem
end

-- H.clash: the first prototype for a name wins process-wide -------------------
do
    local status = H.clash({'GetTickCount', 'BCryptHashData', 'HostileVmUnknownFunction'})
    check('clash declares an unclaimed Windows name', status.GetTickCount == 'clashed', status.GetTickCount)
    check('clash declares names outside the default libraries', status.BCryptHashData == 'clashed', status.BCryptHashData)
    check('clash declares any name', status.HostileVmUnknownFunction == 'clashed', status.HostileVmUnknownFunction)

    -- A mod declaring the real prototype afterwards gets the hostile one, silently.
    ffi.cdef('uint32_t GetTickCount(void);')
    local kernel = ffi.load('kernel32')
    local failed, problem = raises(function() return ffi.C.GetTickCount() end)
    check('a later real prototype is ignored: the call fails instead of working by luck',
          failed and tostring(problem):find('wrong number of arguments', 1, true), problem)
    failed, problem = raises(function() return kernel.GetTickCount('kernel32.dll') end)
    check('every namespace gets the first prototype', failed and tostring(problem):find('cannot convert', 1, true), problem)

    -- The safe pattern: a private name with an __asm__ label is unaffected.
    ffi.cdef('uint32_t hostile_vm_test_ticks(void) __asm__("GetTickCount");')
    local ok, ticks = pcall(function() return kernel.hostile_vm_test_ticks() end)
    check('a private __asm__ name still calls the real function', ok and type(ticks) == 'number', ticks)

    ffi.cdef('void *GetModuleHandleA(const char *name);')
    local again = H.clash({'GetModuleHandleA', 'GetTickCount'})
    check('a name declared earlier is reported, not treated as hostile', again.GetModuleHandleA == 'already declared',
          again.GetModuleHandleA)
    check('clashing twice is reported too', again.GetTickCount == 'already declared', again.GetTickCount)
    local bad = H.clash({'not a C name'})
    check('a declaration error is reported', tostring(bad['not a C name']):find('^error: ') ~= nil, bad['not a C name'])
end

-- H.next_ctype / H.ctype_growth ---------------------------------------------------
do
    local id = H.next_ctype()
    check('next_ctype returns a number', type(id) == 'number', id)
    check('each probe takes two ids', H.next_ctype() == id + 2)
    local function named()
        return ffi.new('uint8_t[16]'), ffi.cast('uint32_t *', 0), ffi.new('uint8_t[?]', 3), ffi.sizeof('double')
    end
    local first = H.ctype_growth(named)
    check('arrays and pointers of named types are interned on first use', first == 3, first)
    check('and add nothing afterwards', H.ctype_growth(named) == 0)
    local growth, a, b = H.ctype_growth(function(x) return x, x + 1 end, 41)
    check('fn results pass through', growth == 0 and a == 41 and b == 42)
    local pointer_growth = H.ctype_growth(function() return ffi.cast('void (*)(void *)', 0) end)
    check('a function-pointer type string adds three types', pointer_growth == 3, pointer_growth)
    check('and adds them again on every evaluation',
          H.ctype_growth(function() return ffi.cast('void (*)(void *)', 0) end) == pointer_growth)
    local callback = ffi.typeof('void (*)(void *)')
    check('a ctype made once and reused adds nothing', H.ctype_growth(function() return ffi.cast(callback, 0) end) == 0)
    check('an anonymous struct string adds two types', H.ctype_growth(function() return ffi.new('struct { int a; }') end) == 2)
    local failed, problem = raises(H.ctype_growth, function() error('inside', 0) end)
    check('errors from fn propagate', failed and problem == 'inside', problem)
end

-- H.chain ---------------------------------------------------------------------------
local function game_env()
    local env = {log = {}}
    env.update = function(dt, extra)
        env.log[#env.log + 1] = {dt = dt, extra = extra}
        return 'game', dt
    end
    return env
end

do -- throw_below under a mod that follows P1: no pcall, everything forwarded
    local env = game_env()
    local neighbour = H.chain(env, 'throw_below')
    local previous, mod_frames = env.update, 0
    env.update = function(...)
        mod_frames = mod_frames + 1
        return previous(...)
    end
    local failed, problem = raises(env.update, 0.016, 'x')
    check('throw_below raises a table error object', failed and type(problem) == 'table'
          and problem.hostile_vm == 'throw_below' and problem.frame == 1, problem)
    check('the same object reaches the top', problem == neighbour.last_error)
    check('the wrapped update ran first, with every argument', #env.log == 1 and env.log[1].extra == 'x')
    check('counts', neighbour.frames == 1 and neighbour.calls == 1 and neighbour.raised == 1 and mod_frames == 1)
end

do -- a wrapper that catches and converts the error is visible
    local env = game_env()
    H.chain(env, 'throw_below')
    local previous = env.update
    env.update = function(...)
        local ok, problem = pcall(previous, ...)
        if not ok then error('mod: ' .. tostring(problem), 0) end
    end
    local failed, problem = raises(env.update, 0.016)
    check('a converted error is a string, not the neighbour\'s table', failed and type(problem) == 'string', problem)
end

do -- raise_on as a frame number and as a function
    local env = game_env()
    local neighbour = H.chain(env, 'throw_below', {raise_on = 2})
    check('frame 1 passes', pcall(env.update, 1))
    local failed, problem = raises(env.update, 2)
    check('frame 2 raises', failed and problem.frame == 2, problem)
    check('frame 3 passes', pcall(env.update, 3))
    check('raise_on number counts', neighbour.frames == 3 and neighbour.raised == 1)
    local env2 = game_env()
    local odd = H.chain(env2, 'throw_below', {raise_on = function(frame) return frame % 2 == 1 end})
    check('raise_on function: frame 1 raises', not pcall(env2.update, 1))
    check('raise_on function: frame 2 passes', pcall(env2.update, 2))
    check('raise_on function counts', odd.raised == 1 and #env2.log == 2)
end

do -- drop_args below and above a mod
    local env = game_env()
    local neighbour = H.chain(env, 'drop_args')
    local tag, dt = env.update(0.5, 'extra')
    check('drop_args forwards dt only', env.log[1].dt == 0.5 and env.log[1].extra == nil)
    check('drop_args keeps the return values', tag == 'game' and dt == 0.5)
    check('drop_args counts', neighbour.frames == 1 and neighbour.calls == 1)
    local env2 = game_env()
    local previous, extras = env2.update, nil
    env2.update = function(step, ...)
        extras = select('#', ...)
        return previous(step, ...)
    end
    H.chain(env2, 'drop_args')
    env2.update(1, 'a', 'b')
    check('a neighbour above passes the mod dt only', extras == 0, extras)
end

do -- double_call
    local env = game_env()
    local neighbour = H.chain(env, 'double_call')
    local tag = env.update(1, 'x')
    check('double_call calls the wrapped update twice per frame', #env.log == 2 and neighbour.calls == 2
          and neighbour.frames == 1 and tag == 'game')
end

do -- skip_odd_frames
    local env = game_env()
    local neighbour = H.chain(env, 'skip_odd_frames')
    for frame = 1, 4 do env.update(frame) end
    check('skip_odd_frames runs even frames only', #env.log == 2 and env.log[1].dt == 2 and env.log[2].dt == 4)
    check('skip_odd_frames counts', neighbour.frames == 4 and neighbour.calls == 2)
end

do -- rehook
    local env = game_env()
    local neighbour = H.chain(env, 'rehook')
    local seen, distinct = {}, 0
    for frame = 1, 3 do
        if not seen[env.update] then
            seen[env.update], distinct = true, distinct + 1
        end
        check('rehook keeps forwarding returns', select(2, env.update(frame)) == frame)
    end
    check('rehook changes env.update every frame', distinct == 3 and neighbour.layers == 3, distinct)
    check('rehook still runs the wrapped update once per frame', #env.log == 3 and neighbour.calls == 3)
end

do -- chain_restore and argument checks
    local env = game_env()
    local original = env.update
    H.chain(env, 'drop_args')
    H.chain(env, 'double_call')
    check('restore returns true', H.chain_restore(env) == true)
    check('restore puts back the update from before the first chain', env.update == original)
    check('a second restore has nothing to do', H.chain_restore(env) == false)
    check('unknown kinds are refused', raises(H.chain, env, 'nonsense'))
    check('a missing update is refused', raises(H.chain, {}, 'drop_args'))
    check('a refused chain changes nothing', env.update == original)
end

-- H.gc_hostile ------------------------------------------------------------------------
do
    local before = collectgarbage('setpause', 200)
    local restore = H.gc_hostile()
    check('gc_hostile sets pause 400', collectgarbage('setpause', 400) == 400)
    restore()
    check('restore puts back the previous pause', collectgarbage('setpause', before) == 200)
    local restore_custom = H.gc_hostile(300)
    check('a custom pause', collectgarbage('setpause', 300) == 300)
    restore_custom()
end

-- H.jit_churn -------------------------------------------------------------------------
do
    local flush = H.jit_churn()
    local function work(n)
        local sum = 0
        for i = 1, n do sum = sum + i end
        return sum
    end
    check('work before a flush', work(10000) == 50005000)
    local util = require('jit.util')
    if jit.status() then
        check('the hot loop compiled a trace', util.traceinfo(1) ~= nil)
    end
    check('flush counts', flush() == 1 and flush() == 2)
    check('every trace is gone after a flush', util.traceinfo(1) == nil)
    check('work after a flush', work(10000) == 50005000)
end

-- H.aligned16 -------------------------------------------------------------------------
do
    local buffer = ffi.new('uint8_t[64]')
    local skew = tonumber(ffi.cast('uintptr_t', buffer) % 16)
    local aligned = ffi.cast('uint8_t *', buffer) + ((16 - skew) % 16)
    check('an aligned pointer passes and is returned', H.aligned16(aligned) == aligned)
    local failed, problem = raises(H.aligned16, aligned + 8, 'fake movaps')
    check('8 bytes off faults like movaps', failed and tostring(problem):find('fake movaps: buffer is 8 bytes past', 1, true),
          problem)
    check('numbers work', H.aligned16(0x1000) == 0x1000 and raises(H.aligned16, 0x1004))
    check('NULL is refused', raises(H.aligned16, ffi.cast('void *', 0)))
    check('other values are refused', raises(H.aligned16, 'text'))
    check('the check creates no C types', H.ctype_growth(H.aligned16, aligned) == 0)
end

-- H.heap_peak -------------------------------------------------------------------------
do
    local kb, rows = H.heap_peak(function(n)
        local t = {}
        for i = 1, n do t[i] = {i} end
        return t
    end, 1000)
    check('allocation is measured', kb > 30 and #rows == 1000, kb)
    local small, value = H.heap_peak(function(x) return x * 2 end, 21)
    check('no allocation measures under 1 KB and results pass through', small < 1 and value == 42, small)
    local failed, problem = raises(H.heap_peak, function() error('boom', 0) end)
    check('errors propagate', failed and problem == 'boom', problem)
    local ring, start = {}, collectgarbage('count')
    for i = 1, 200000 do ring[i % 64] = {i} end
    local grown = collectgarbage('count') - start
    check('the GC runs again afterwards (also after an error)', grown < 4096, grown)
end

print(string.format('hostile_vm: %d checks passed (%s)', passed, jit.version))
