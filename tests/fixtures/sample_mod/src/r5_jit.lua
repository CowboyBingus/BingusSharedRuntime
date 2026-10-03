-- R5 fixture: JIT controls that apply to every mod's compiled code.
local engine = require('jit')
local M = {}
function M.run(fn, library)
    jit.flush() -- expect: R5
    jit.opt.start('maxtrace=2000') -- expect: R5
    engine.attach(fn, 'trace') -- expect: R5 (through an alias)
    jit.off() -- expect: R5
    jit.on() -- expect: R5
    local start = library.opt.start -- expect: R5
    jit.off(fn, true)
    jit.on(fn)
    if jit and jit.off and jit.status then start = jit.version end
    return start, require('jit.opt') -- expect: R5
end
return M
