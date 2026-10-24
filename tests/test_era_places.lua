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

function tests.theTocLoadsIt()
    local f = assert(io.open(H.ADDON_ROOT .. "/EasyFind.toc", "rb"))
    local toc = f:read("*a")
    f:close()
    H.assertTrue(toc:find("Database/StaticLocations_Era.lua", 1, true) ~= nil)
end

local pass, fail, failures = H.runSuite("EraPlaces", tests)
return { pass = pass, fail = fail, failures = failures }
