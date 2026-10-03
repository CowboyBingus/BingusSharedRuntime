-- R14 fixture (with r14_shared_b.lua): a block of 100+ tokens copied into another file.
local first_copy = {}

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

function first_copy.sum(bytes)
    return checksum(bytes, 0, #bytes)
end

return first_copy
