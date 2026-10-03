-- R4 fixture: GC changes that apply to the game and every mod.
local M = {}
function M.run(probe, option)
    collectgarbage('setpause', 400) -- expect: R4
    collectgarbage() -- expect: R4
    collectgarbage('step', 0) -- expect: R4
    pcall(collectgarbage, 'stop') -- expect: R4
    collectgarbage(option) -- expect: R4
    local kb = collectgarbage('count')
    local again = collectgarbage 'count'
    return kb + again + probe(collectgarbage, 'count')
end
return M
