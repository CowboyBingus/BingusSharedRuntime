-- R9 fixture: catching another layer's error and rethrowing it from this frame.
local M = {}
function M.install(env)
    local previous_update, original = env.update, env.shutdown
    local function after(ok, ...)
        if not ok then error((...), 0) end -- expect: R9
        return ...
    end
    env.update = function(...)
        return after(pcall(previous_update, ...)) -- expect: R9
    end
    env.shutdown = function(...)
        local ok, problem = xpcall(original, debug.traceback, ...) -- expect: R9
        if not ok then error(problem, 0) end
        return ok
    end
    return pcall(M.helper)
end
return M
