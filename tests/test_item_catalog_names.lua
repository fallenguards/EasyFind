-- Guardrail: the catalogs built by dev/tools/forever_items.py and
-- classic_items.py hold no developer item ("72 test green druid shoulder",
-- "[dnt] test mount"): its rules, in Lua. About 5,400 were in the Forever,
-- Era, TBC and Mists catalogs (2026-10-29).
local H = require("Harness")

local PREFIXES = { "monster - ", "oldmonster", "deprecated", "depricated", "deptecated", "[ph]", "(ph)", "test ",
                   "zzold", "zzzold", "zz ", "unused", "<unused>", "[unused]", "[dnt]", "(dnt)", "debug ", "qa ",
                   "placeholder", "obsolete", "[deprecated" }
local MARKERS = { "[dnt]", "(dnt)", "[dnd]", "dnd)", "[ph]", "(ph)", "[test]", "(test", "[unused]", "(unused)", "<unused>",
                  " unused", "(old)", "[old]", "do not localize", "do not test", "do not use", "deprecated", "depricated",
                  "derecated", "(delete me)", "qa functionality", "[daon test]", "placeholder", "no longer used",
                  "unknown reward", "zzold", "monster - ", " debug" }
local KEEP = { ["high test eternium fishing line"] = true }

local function Unheld(name)
    local bare = name:gsub("^[\"']+", "")
    for _, p in ipairs(PREFIXES) do
        if bare:sub(1, #p) == p then return true end
    end
    for _, m in ipairs(MARKERS) do
        if name:find(m, 1, true) then return true end
    end
    if name:find("%f[%w]nyi%f[%W]") then return true end
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

-- Forever's tables spell their placeholders their own way (2026-11-08).
function tests.foreverSpellingsAreCaught()
    for _, name in ipairs({ "depricated razor arrow", "oldmonster - chest, plate silver", "(dnt) moonglaive",
                            "hidden belt (dnt)", "charm pouch (dnd)", "heavy quiver (visual dnd)",
                            "gnomish weather machine nyi", "<unused> glyphic rune", "theramore guard medallion unused",
                            "quest reward placeholder", "qa tabard of weighted dice", "debug samophlange manual page",
                            "no longer used", "unknown reward", "\"monster - dagger, broad/flat blade\"",
                            "direbrew's bottle do not use", "flayed demon skin [depricated]" }) do
        H.assertTrue(Unheld(name), name)
    end
    for _, name in ipairs({ "old key", "old blanchy's feed pouch", "unyielding battle signet", "drape of unyielding strength",
                            "advanced target dummy", "contest winner's tabard", "spool of light chartreuse silk thread" }) do
        H.assertFalse(Unheld(name), name .. " is an item")
    end
end

local pass, fail, failures = H.runSuite("ItemCatalogNames", tests)
return { pass = pass, fail = fail, failures = failures }
