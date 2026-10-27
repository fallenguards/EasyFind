-- What ships stays small (2026-10-27, the zips at 11 to 16 MiB against a
-- 10 MB wish): the fonts are the subsets dev/tools/subset_fonts.py
-- writes, and the NPC catalogs ship no line-start tables (Apps/GPS/Npcs.lua
-- makes them at load). Each cap sits a little over the subset's size, so
-- a full font put back fails here.
local H = require("Harness")

local FONT_CAPS_KB = {
    ["Inter-Regular.ttf"] = 220, ["Inter-SemiBold.ttf"] = 220, ["Inter-Bold.ttf"] = 220,
    ["Poppins-Regular.ttf"] = 40, ["Poppins-SemiBold.ttf"] = 40, ["Poppins-Bold.ttf"] = 40,
}

local function size(rel)
    local f = io.open(H.ADDON_ROOT .. "/" .. rel, "rb")
    if not f then return nil end
    local n = f:seek("end")
    f:close()
    return n
end

local tests = {}

function tests.fontsAreTheSubsets()
    for name, cap in pairs(FONT_CAPS_KB) do
        local n = size("Fonts/" .. name)
        H.assertTrue(n ~= nil, name .. " ships")
        H.assertTrue(n <= cap * 1024, name .. " is " .. math.floor(n / 1024) .. " KB, over its " .. cap .. " KB cap: run dev/tools/subset_fonts.py")
    end
end

function tests.npcCatalogsShipNoLineStarts()
    local bad = {}
    local p = io.popen('git -C "' .. H.ADDON_ROOT .. '" ls-files "Apps/GPS/Npcs_*.lua"')
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

local pass, fail, failures = H.runSuite("ShippedSize", tests)
return { pass = pass, fail = fail, failures = failures }
