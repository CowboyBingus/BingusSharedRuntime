-- R10 fixture: cognitive complexity above 15 (SonarSource's default); exactly 15 stays silent.
local M = {}

function M.fifteen(a, b, c, d)
    if a then                    -- +1
        for _ = 1, 2 do          -- +2 (nesting 1)
            if b then            -- +3 (nesting 2)
                d = 1
            end
        end
    elseif b then                -- +1
        d = 2
    else                         -- +1
        d = 3
    end
    while c and d do             -- +1, and +1
        if a or b then           -- +2 (nesting 1), or +1
            c = false
        end
    end
    repeat d = nil until a and b -- +1, and +1
    return d
end

function M.sixteen(a, b, c, d) -- expect: R10
    if a then
        for _ = 1, 2 do
            if b then
                d = 1
            end
        end
    elseif b then
        d = 2
    else
        d = 3
    end
    while c and d do
        if a or b then
            c = false
        end
    end
    repeat d = nil until a and b or c -- one more: the run changes from and to or
    return d
end

-- A factory is not charged with the functions it defines; the closure is measured on its own.
function M.factory()
    local function inner(a, b, c, d) -- expect: R10
        if a then
            for _ = 1, 2 do
                if b then
                    d = 1
                end
            end
        elseif b then
            d = 2
        else
            d = 3
        end
        while c and d do
            if a or b then
                c = false
            end
        end
        repeat d = nil until a or b and c
        return d
    end
    return inner
end

return M
