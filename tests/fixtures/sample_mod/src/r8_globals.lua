-- R8 fixture: global writes into the shared Lua state.
local M = {}
local previous = update
update = function(dt) return previous(dt) end
shutdown = function() end
SampleMod = M
rawset(_G, 'SampleModState', {}) -- expect: R8
_G.SampleLeak = true -- expect: R8
_G['SampleOther'] = 1 -- expect: R8
rawset(_G, 'SampleMod', M)
function M.plan(list)
    _, selected = next(list) -- expect: R8 (two names on one line)
    return selected
end
helper = function() end -- lint-ok: R8 fixture: suppressed on purpose
return M
