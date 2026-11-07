-- Classic Era's places (Database/StaticLocations_Era.lua): generated from the
-- vanilla world databases on Era's own map tables. Era loaded no places at
-- all (StaticLocations.lua holds retail's and steps aside on every classic
-- client; Forever's file loads on Forever only), so "mage trainer" in
-- Ironforge found nothing.
local H = require("Harness")

local function Load(caps)
    local env = H.newEnv()
    env._G = env
    local ns = H.newNs(env)
    ns.Caps = caps
    ns.POIName = function(english) return english end
    env.EasyFind = {}
    H.loadModule("Database/StaticLocations_Era.lua", env, ns)
    return ns
end

local function Find(list, name)
    for _, loc in ipairs(list or {}) do
        if loc.name == name then return loc end
    end
end

local tests = {}

function tests.eraHasIronforgesMageTrainer()
    local ns = Load({ classic = true, era = true })
    local mage = Find(ns.STATIC_LOCATIONS[1455], "Mage Trainer")
    H.assertNotNil(mage, "Ironforge's mage trainer")
    H.assertEq(mage.category, "classtrainer_mage")
    H.assertNotNil(Find(ns.STATIC_LOCATIONS[1455], "Deeprun Tram"), "the tram, as on Era")
end

-- Forever's additions stay on Forever.
function tests.noForeverOnlyPlaces()
    local ns = Load({ classic = true, era = true })
    H.assertNil(Find(ns.STATIC_LOCATIONS[1455], "Barber"))
    H.assertNil(Find(ns.STATIC_LOCATIONS[1455], "Shaman Trainer"), "no dwarf shaman trainer on Era")
end

function tests.otherClientsKeepTheirOwn()
    local ns = Load({ classic = true, tbc = true })
    H.assertNil(ns.STATIC_LOCATIONS, "TBC loads none of Era's")
end

-- A weapon master's row carries the weapons it teaches (trainer spell ids)
-- and the words players type for them: "sword trainer" found nothing
-- while "weapon trainer" did (Trade chat, 2026-10-31).
function tests.weaponMastersTeachTheirWeapons()
    local ns = Load({ classic = true, era = true })
    local function Has(list, word)
        for _, w in ipairs(list or {}) do if w == word then return true end end
        return false
    end
    local masters = 0
    for _, places in pairs(ns.STATIC_LOCATIONS) do
        for _, loc in ipairs(places) do
            if loc.name == "Weapon Master" then
                masters = masters + 1
                H.assertTrue(type(loc.teaches) == "table" and #loc.teaches > 0, "every master teaches something")
                H.assertTrue(Has(loc.keywords, "trainer"), "a trainer")
            end
        end
    end
    H.assertTrue(masters >= 6, "the capitals' weapon masters, got " .. masters)
    local stormwind = Find(ns.STATIC_LOCATIONS[1453], "Weapon Master")
    H.assertNotNil(stormwind, "Stormwind's weapon master")
    H.assertTrue(Has(stormwind.keywords, "sword") and Has(stormwind.keywords, "swords"), "swords in Stormwind")
    H.assertTrue(Has(stormwind.keywords, "dagger"), "daggers in Stormwind")
    local maces = false
    for _, loc in ipairs(ns.STATIC_LOCATIONS[1455]) do
        if loc.name == "Weapon Master" and Has(loc.keywords, "mace") and Has(loc.keywords, "gun") then maces = true end
    end
    H.assertTrue(maces, "maces and guns in Ironforge")
end

-- One row per master, each with its own weapons and its name: Orgrimmar's
-- two stand together, only Sayoc teaches fist weapons (2026-11-07: "fist
-- weapon trainer" listed one "Weapon Master" row for both).
function tests.eachWeaponMaster_isItsOwnRow()
    local ns = Load({ classic = true, era = true })
    local function Has(list, id)
        for _, v in ipairs(list or {}) do if v == id then return true end end
        return false
    end
    local byName = {}
    for _, places in pairs(ns.STATIC_LOCATIONS) do
        for _, loc in ipairs(places) do
            if loc.name == "Weapon Master" then
                H.assertTrue(type(loc.npcName) == "string" and loc.npcName ~= "", "every master named")
                H.assertNil(byName[loc.npcName], loc.npcName .. " listed once")
                byName[loc.npcName] = loc
            end
        end
    end
    H.assertNotNil(byName.Hanashi, "Hanashi")
    H.assertNotNil(byName.Sayoc, "Sayoc")
    H.assertFalse(Has(byName.Hanashi.teaches, 15590), "Hanashi teaches no fist weapons")
    H.assertTrue(Has(byName.Sayoc.teaches, 15590), "Sayoc does")
    H.assertTrue(byName.Hanashi.x ~= byName.Sayoc.x or byName.Hanashi.y ~= byName.Sayoc.y, "each at its own spot")
end

function tests.theTocLoadsIt()
    local f = assert(io.open(H.ADDON_ROOT .. "/EasyFind.toc", "rb"))
    local toc = f:read("*a")
    f:close()
    H.assertTrue(toc:find("Database/StaticLocations_Era.lua", 1, true) ~= nil)
end

local pass, fail, failures = H.runSuite("EraPlaces", tests)
return { pass = pass, fail = fail, failures = failures }
