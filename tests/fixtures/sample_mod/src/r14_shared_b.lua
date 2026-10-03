-- R14 fixture (with r14_shared_a.lua): the second copy of the same block.
local second_copy = setmetatable({limit = 3}, {__index = math})

local function checksum(bytes, offset, count) -- expect: R14
    local total, index = 0, offset
    while index < offset + count do
        local value = bytes:byte(index + 1) or 0
        total = (total * 31 + value) % 4294967296
        if value == 0 then
            total = total + 7
        elseif value > 127 then
            total = total - value
        end
        index = index + 1
        if index - offset > 65536 then
            return nil, 'checksum input too long'
        end
    end
    local folded = (total - total % 65536) / 65536 + total % 65536
    return folded, index - offset
end

function second_copy.first(bytes)
    return checksum(bytes, 0, math.min(second_copy.limit, #bytes))
end

return second_copy
