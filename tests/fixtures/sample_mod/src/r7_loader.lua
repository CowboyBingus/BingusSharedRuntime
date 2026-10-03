-- R7 fixture: comparing the loader's internal version number.
local loader = rawget(_G, 'CowboyBingusModLoader')
local host = rawget(_G, 'CowboyBingusModLoader')
local M = {}
function M.supported(menu)
    if type(loader.version) ~= 'number' then return false end
    if loader.version >= 18 then return true end -- expect: R7
    if (host.version or 0) < 17 then return false end -- expect: R7 (alias, or-default)
    if rawget(_G, 'CowboyBingusModLoader').version == 17 then return true end -- expect: R7
    if 16 <= CowboyBingusModLoader.version then return true end -- expect: R7
    if (tonumber(menu.version) or 1) >= 2 then return true end
    return type(loader.jit) == 'table' and loader.api == 1, 'loader ' .. tostring(loader.version)
end
return M
