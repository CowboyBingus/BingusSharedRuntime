-- R12 fixture: more than 7 parameters (SonarSource's default); `self` counts, `...` does not.
local M = {}

function M.seven(a, b, c, d, e, f, g)
    return a or b or c or d or e or f or g
end

function M.eight(a, b, c, d, e, f, g, h) -- expect: R12
    return a or b or c or d or e or f or g or h
end

function M:method_seven(a, b, c, d, e, f)
    return self or a or b or c or d or e or f
end

function M:method_eight(a, b, c, d, e, f, g) -- expect: R12
    return self or a or b or c or d or e or f or g
end

function M.vararg(a, b, c, d, e, f, g, ...)
    return select('#', ...) + (a or b or c or d or e or f or g or 0)
end

return M
