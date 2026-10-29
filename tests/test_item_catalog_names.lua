-- Guardrail: the catalogs built by dev/tools/forever_items.py and
-- classic_items.py hold no developer item ("72 test green druid shoulder",
-- "[dnt] test mount"): its rules, in Lua. About 5,400 were in the Forever,
-- Era, TBC and Mists catalogs (2026-10-29).
local H = require("Harness")

local PREFIXES = { "monster - ", "deprecated", "[ph]", "test ", "zzold", "zz ", "old ", "unused ", "[deprecated" }
local MARKERS = { "[dnt]", "[ph]", "[test]", "(test", "[unused]", "(old)", "do not localize", "do not test",
                  "deprecated", "derecated", "(delete me)", "qa functionality", "[daon test]" }
local KEEP = { ["high test eternium fishing line"] = true }

local function Unheld(name)
    for _, p in ipairs(PREFIXES) do
        if name:sub(1, #p) == p then return true end
    end
    for _, m in ipairs(MARKERS) do
        if name:find(m, 1, true) then return true end
    end
    return name:find("%f[%w]test%f[%W]") ~= nil and not KEEP[name]
end

local tests = {}

function tests.noDeveloperItemInTheBuiltCatalogs()
    local bad, rows = {}, 0
    for _, file in ipairs({ "Data_Forever", "Data_Era", "Data_TBC", "Data_Mists" }) do
        local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Items/" .. file .. ".lua", "rb"))
        local src = f:read("*a")
        f:close()
        for name in src:gmatch("\n([^\t\n]+)\t") do
            rows = rows + 1
            if Unheld(name) and #bad < 10 then bad[#bad + 1] = file .. ": " .. name end
        end
    end
    H.assertTrue(rows > 100000, "expected the four catalogs' rows, read " .. rows)
    H.assertEq(#bad, 0, "\n  " .. table.concat(bad, "\n  "))
end

function tests.theOneRealTestItemStays()
    H.assertFalse(Unheld("high test eternium fishing line"))
    H.assertTrue(Unheld("72 test green druid shoulder"))
    H.assertFalse(Unheld("testament of the light"), "a word starting with test")
end

local pass, fail, failures = H.runSuite("ItemCatalogNames", tests)
return { pass = pass, fail = fail, failures = failures }
