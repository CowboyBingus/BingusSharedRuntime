-- R6 fixture: os.clock aborts trace compilation.
local clock = os.clock -- expect: R6
local M = {}
function M.elapsed(start)
    return os.clock() - start + clock() -- expect: R6
end
function M.now()
    return os.time()
end
return M
