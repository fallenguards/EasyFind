-- What ships stays small: the creature catalogs ship no line-start tables
-- (MapSearch/Npcs.lua makes them at load; the GPS zips were 11 to 16 MiB
-- against a 10 MB wish, 2026-10-27).
local H = require("Harness")

local tests = {}

function tests.npcCatalogsShipNoLineStarts()
    local bad = {}
    local p = io.popen('git -C "' .. H.ADDON_ROOT .. '" ls-files "Database/Npcs_*.lua"')
    for rel in p:lines() do
        local f = io.open(H.ADDON_ROOT .. "/" .. rel, "rb")
        if f then
            local s = f:read("*a")
            f:close()
            if s:find("\n    nameAt = ", 1, true) or s:find("\n    goodsNameAt = ", 1, true)
               or s:find("\ndata.localNameAt = ", 1, true) or s:find("\ndata.localGoodsAt = ", 1, true) then
                bad[#bad + 1] = rel
            end
        end
    end
    p:close()
    H.assertEq(#bad, 0, "line-start tables shipped: " .. table.concat(bad, ", "))
end

local pass, fail, failures = H.runSuite("NpcCatalogLean", tests)
return { pass = pass, fail = fail, failures = failures }
