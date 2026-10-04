-- bingus_runtime.lua on its own: no FFI, the shared table and the update guard
-- against abusive neighbours. Run by tests/test_runtime.py in a LuaJIT
-- executable and in the game's lua51.dll.
-- arg[1] the runtime folder, arg[2] hostile_vm.lua.
local folder, helper_path = assert(arg[1]), assert(arg[2])
local H = dofile(helper_path)

local passed = 0
local function check(name, condition, detail)
    if not condition then error(name .. (detail ~= nil and (': ' .. tostring(detail)) or ''), 2) end
    passed = passed + 1
end

-- 1. Loading: the core reads only these globals, never require, ffi or jit -------------------

local READS = {type = true, pcall = true, error = true, tostring = true, rawget = true, rawset = true,
               ipairs = true, _G = true}
local reads = {}
local function core()
    local chunk = assert(loadfile(folder .. '/bingus_runtime.lua'))
    setfenv(chunk, setmetatable({}, {__index = function(_, key)
        reads[key] = true
        return _G[key]
    end}))
    return chunk()
end

local runtime, other = core(), core()
check('version', runtime.VERSION == 1 and other.VERSION == 1)
check('each copy is its own table', runtime ~= other and runtime.guard ~= other.guard)
check('the core has only shared and guard', runtime.memory == nil and runtime.native == nil)
check('one shared table', runtime.shared() == other.shared() and rawget(_G, 'BingusRuntime') == runtime.shared())
check('the shared table records the version', runtime.shared().versions[1] == true)

-- 2. Update guard -----------------------------------------------------------------------------

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
    check('the status names the guard and its version', guard.status.name == 'forwarding' and guard.status.version == 1
        and guard.status.errors == 0 and guard.status.lower_errors == 0 and guard.status.pauses == 0)
    check('installing twice refused', not pcall(guard.install))
    check('a second guard with the name refused', not pcall(runtime.guard, {name = 'forwarding', env = env}))
    local s = pack(env.shutdown('q', nil))
    check('shutdown forwarded', s.n == 3 and s[1] == 's1' and s[2] == 'q' and env.shutdowns == 1)
    check('a clean session', guard.status.state == 'stopped' and not guard.running())
end

do -- a guard needs a name and is 'new' until installed
    check('no name refused', not pcall(runtime.guard, {env = environment()}))
    check('an empty name refused', not pcall(runtime.guard, {name = '', env = environment()}))
    local guard = runtime.guard({name = 'not-installed', env = environment()})
    check('new until installed', guard.status.state == 'new' and not guard.status.installed and not guard.running())
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

do -- a failure in the last frame before shutdown is the first failure
    local env = environment()
    H.chain(env, 'throw_below', {raise_on = 1})
    local guard = runtime.guard({name = 'last-frame', env = env}).install()
    pcall(env.update, 1)
    env.shutdown()
    check('P2: an error below in the last frame', guard.status.state == 'stopped after: the previous update failed')
    H.chain_restore(env)
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
    check('the first error is kept', guard.status.first_error:find('step failed 1', 1, true))
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

do -- a custom error limit
    local env, calls = environment(), 0
    local guard = runtime.guard({name = 'limit-3', env = env, errors = 3,
        step = function() calls = calls + 1; error('always') end}).install()
    for _ = 1, 10 do env.update(1) end
    check('errors = 3 stops after 3', calls == 3 and guard.status.state:find('stopped after 3 errors', 1, true))
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

do -- a neighbour below that skips frames is not a failure
    local env, steps, afters = environment(), 0, 0
    H.chain(env, 'skip_odd_frames')
    local guard = runtime.guard({name = 'skipping', env = env, step = function() steps = steps + 1 end,
        after = function() afters = afters + 1 end}).install()
    for _ = 1, 10 do env.update(1) end
    check('steps and afters every frame; the game update every other', guard.running() and steps == 10
        and afters == 10 and env.calls == 5)
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

-- 3. A broken shared table ----------------------------------------------------------------------

do -- missing or broken fields are filled in; the table itself is kept
    local env = {BingusRuntime = {hashes = 'not a table', hash_reads = 'x'}}
    local shared = runtime.shared(env)
    check('broken shared table repaired', rawget(env, 'BingusRuntime') == shared and type(shared.hashes) == 'table'
        and type(shared.statuses) == 'table' and shared.versions[1] == true and shared.hash_reads == 0)
    local kept = rawget(_G, 'BingusRuntime')
    rawset(_G, 'BingusRuntime', {})
    local repaired = runtime.shared()
    check('BingusRuntime = {} is repaired in place', rawget(_G, 'BingusRuntime') == repaired
        and type(repaired.statuses) == 'table' and repaired.versions[1] == true)
    rawset(_G, 'BingusRuntime', 42)
    check('a non-table BingusRuntime is replaced', type(runtime.shared()) == 'table')
    rawset(_G, 'BingusRuntime', kept)
    local env2 = {BingusRuntime = {}}
    check('a guard repairs the table it registers in', pcall(runtime.guard, {name = 'repairing', env = env2})
        and type(env2.BingusRuntime.statuses.repairing) == 'table')
end

-- 4. Pause and resume after an error below; bursts --------------------------------------------

do -- with pause: the next frame restores and pauses; clean frames resume the mod
    local env, steps, pauses, stops, lines = environment(), 0, {}, 0, {}
    H.chain(env, 'throw_below', {raise_on = 2})
    local guard = runtime.guard({name = 'pausing', env = env, log = function(line) lines[#lines + 1] = line end,
        step = function() steps = steps + 1 end, stop = function() stops = stops + 1 end,
        pause = function(reason) pauses[#pauses + 1] = reason end}).install()
    env.update(1)
    check('the error below passes unchanged', not pcall(env.update, 1))
    env.update(1)
    check('the next frame pauses once and skips the step', #pauses == 1 and pauses[1] == 'the previous update failed'
        and steps == 2 and stops == 0 and guard.status.state == 'paused: the previous update failed')
    for _ = 1, 59 do env.update(1) end
    check('paused until 60 updates below have returned', steps == 2 and guard.status.state:find('^paused'))
    env.update(1)
    check('then resumed, stepping again', steps == 3 and guard.status.state == 'running' and guard.running())
    check('one line each for the pause and the resume', #lines == 2 and lines[1]:find('paused', 1, true)
        and lines[2]:find('resumed', 1, true), #lines)
    env.shutdown()
    check('a resumed mod ends a clean session', guard.status.state == 'stopped' and stops == 1)
    H.chain_restore(env)
end

do -- a custom resume count
    local env, steps = environment(), 0
    H.chain(env, 'throw_below', {raise_on = 1})
    local guard = runtime.guard({name = 'resume-5', env = env, resume = 5, pause = function() end,
        step = function() steps = steps + 1 end}).install()
    pcall(env.update, 1)
    for _ = 1, 5 do env.update(1) end
    check('paused for 5 updates below', steps == 1 and guard.status.state:find('^paused'))
    env.update(1)
    check('resume = 5 resumes on the 6th frame', steps == 2 and guard.status.state == 'running')
    H.chain_restore(env)
end

do -- errors below that keep coming stop the mod after 8; pause work runs once
    local env, pauses, stops = environment(), 0, 0
    H.chain(env, 'throw_below', {raise_on = function(frame) return frame % 2 == 0 end})
    local guard = runtime.guard({name = 'failing-below', env = env, step = function() end,
        stop = function() stops = stops + 1 end, pause = function() pauses = pauses + 1 end}).install()
    for _ = 1, 40 do pcall(env.update, 1) end
    check('8 failed updates below stop the mod', guard.status.state == 'stopped: stopped after 8 failed updates below this mod'
        and guard.status.lower_errors == 8 and pauses == 1 and stops == 1, guard.status.state)
    check('errors below are not the mod\'s own', guard.status.errors == 0, guard.status.errors)
    H.chain_restore(env)
end

do -- the two counts are kept apart: 7 own errors and 7 below keep the mod running
    local env, own, below = environment(), 0, 0
    H.chain(env, 'throw_below', {raise_on = function() return below > 0 end})
    local guard = runtime.guard({name = 'apart', env = env, pause = function() end, resume = 1,
        step = function() if own > 0 then own = own - 1; error('own') end end}).install()
    own = 7
    for _ = 1, 7 do pcall(env.update, 1) end
    below = 1
    for _ = 1, 7 do pcall(env.update, 1) end
    check('7 and 7: still running', guard.running() and guard.status.errors == 7, guard.status.state)
    below = 0
    for _ = 1, 3 do env.update(1) end
    check('the errors below were counted on their own', guard.status.lower_errors == 7 and guard.status.errors == 7,
        guard.status.lower_errors .. ' below, ' .. guard.status.errors .. ' own')
    own = 1
    env.update(1)
    check('the 8th own error stops', guard.status.state:find('^stopped: stopped after 8 errors'), guard.status.state)
    H.chain_restore(env)
end

do -- a pause that raises stops the mod
    local env = environment()
    H.chain(env, 'throw_below', {raise_on = 1})
    local guard = runtime.guard({name = 'bad-pause', env = env, pause = function() error('restore failed') end}).install()
    pcall(env.update, 1)
    env.update(1)
    check('a failed pause stops', guard.status.state:find('^stopped: pause failed: .*restore failed'), guard.status.state)
    H.chain_restore(env)
end

do -- own errors separated by a clean minute never stop the mod; 8 in a burst do
    local env, failing, lines = environment(), true, {}
    local guard = runtime.guard({name = 'bursts', env = env, log = function(line) lines[#lines + 1] = line end,
        step = function() if failing then error('transient') end end}).install()
    for _ = 1, 7 do env.update(1) end
    failing = false
    for _ = 1, 3600 do env.update(1) end
    check('a clean minute clears the burst', guard.status.errors == 0 and guard.running())
    failing = true
    for _ = 1, 7 do env.update(1) end
    check('a second burst of 7 keeps running', guard.running() and guard.status.errors == 7)
    env.update(1)
    check('the 8th error of a burst stops', not guard.running() and guard.status.state:find('stopped after 8 errors'))
    check('one error line per burst plus the stop', #lines == 3, #lines)
end

do -- errors below separated by a clean minute never stop the mod
    local env, frame = environment(), 0
    H.chain(env, 'throw_below', {raise_on = function(n) return n % 3700 == 0 end})
    local guard = runtime.guard({name = 'rare-below', env = env, step = function() end, pause = function() end}).install()
    for _ = 1, 3700 * 10 + 1 do frame = frame + 1; pcall(env.update, 1) end   -- +1: the frame that sees the 10th
    check('ten rare errors below over ten minutes: still running', guard.status.pauses == 10 and guard.running()
        and guard.status.lower_errors <= 1, guard.status.state)
    H.chain_restore(env)
end

do -- a log function that raises never breaks the guard
    local env = environment()
    local guard = runtime.guard({name = 'bad-log', env = env, log = function() error('log failed') end,
        step = function() error('step failed') end}).install()
    for _ = 1, 10 do env.update(1) end
    check('a failing log is ignored', guard.status.state:find('stopped after 8 errors', 1, true) and env.calls == 10)
end

-- 5. What the core read ---------------------------------------------------------------------------

local unexpected = {}
for key in pairs(reads) do
    if not READS[key] then unexpected[#unexpected + 1] = key end
end
table.sort(unexpected)
check('the core reads no global but its own few (no require, ffi or jit)', #unexpected == 0,
    table.concat(unexpected, ', '))

print('bingus_runtime: ' .. passed .. ' checks passed (' .. jit.version .. ')')
