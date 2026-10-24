-- TBC Anniversary's places (Database/StaticLocations_TBC.lua): from the
-- cMaNGOS TBC world database on Anniversary's own map tables, Outland's
-- cities included. TBC renumbered the NPC flags: read with 1.x's bits every
-- vendor came out an innkeeper (fifteen inns in the Exodar).
local H = require("Harness")

local function Load(caps)
    local env = H.newEnv()
    env._G = env
    local ns = H.newNs(env)
    ns.Caps = caps
    ns.POIName = function(english) return english end
    env.EasyFind = {}
    H.loadModule("Database/StaticLocations_TBC.lua", env, ns)
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

function tests.theExodarHasOneInnAndItsServices()
    local ns = Load({ classic = true, tbc = true })
    local exodar = ns.STATIC_LOCATIONS[1947]
    H.assertEq(Count(exodar, "innkeeper"), 1, "one inn, not every vendor")
    H.assertEq(Count(exodar, "bank"), 1)
    H.assertEq(Count(exodar, "auctionhouse"), 1)
end

function tests.shattrathIsThere()
    local ns = Load({ classic = true, tbc = true })
    H.assertTrue(Count(ns.STATIC_LOCATIONS[1955], "bank") >= 1, "Shattrath's banks")
end

function tests.otherClientsKeepTheirOwn()
    local ns = Load({ classic = true, era = true })
    H.assertNil(ns.STATIC_LOCATIONS, "Era loads none of Anniversary's")
end

function tests.theTocLoadsIt()
    local f = assert(io.open(H.ADDON_ROOT .. "/EasyFind.toc", "rb"))
    local toc = f:read("*a")
    f:close()
    H.assertTrue(toc:find("Database/StaticLocations_TBC.lua [AllowLoadGameType tbc]", 1, true) ~= nil)
end

local pass, fail, failures = H.runSuite("TBCPlaces", tests)
return { pass = pass, fail = fail, failures = failures }
