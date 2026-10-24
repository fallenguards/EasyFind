-- MoP Classic's places (Database/StaticLocations_Mists.lua): from
-- TrinityCore's retail database, only the creatures and objects MoP has, on
-- MoP's own maps, class trainers by their titles (MoP has no recorded
-- ones). MoP loaded no places at all before.
local H = require("Harness")

local function Load(caps)
    local env = H.newEnv()
    env._G = env
    local ns = H.newNs(env)
    ns.Caps = caps
    ns.POIName = function(english) return english end
    env.EasyFind = {}
    ns.STATIC_LOCATIONS = {}
    H.loadModule("Database/StaticLocations_Mists.lua", env, ns)
    return ns
end

local function Count(list, category)
    local n = 0
    for _, loc in ipairs(list or {}) do
        if loc.category == category then n = n + 1 end
    end
    return n
end

local tests = {}

function tests.orgrimmarHasItsServicesAndTrainers()
    local ns = Load({ classic = true, mists = true })
    local org = ns.STATIC_LOCATIONS[85]
    H.assertTrue(Count(org, "bank") >= 1, "a bank")
    H.assertTrue(Count(org, "innkeeper") >= 1, "an inn")
    H.assertTrue(Count(org, "classtrainer_monk") >= 1, "MoP's monk trainer")
    for _, loc in ipairs(org) do
        H.assertTrue(loc.name ~= loc.category, "named, not its category id: " .. loc.category)
    end
end

function tests.otherClientsKeepTheirOwn()
    local ns = Load({ classic = true, tbc = true })
    H.assertNil(next(ns.STATIC_LOCATIONS), "Anniversary loads none of MoP's")
end

function tests.theTocLoadsIt()
    local f = assert(io.open(H.ADDON_ROOT .. "/EasyFind.toc", "rb"))
    local toc = f:read("*a")
    f:close()
    H.assertTrue(toc:find("Database/StaticLocations_Mists.lua [AllowLoadGameType mists]", 1, true) ~= nil)
end

local pass, fail, failures = H.runSuite("MistsPlaces", tests)
return { pass = pass, fail = fail, failures = failures }
