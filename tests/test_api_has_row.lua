-- API.HasRow and HasCreature (MINOR 6): an extension asks whether EasyFind
-- lists a thing itself, so a pin EasyFind has marks EasyFind's row and never
-- doubles it. A creature answers from the loaded catalog (its id back), a
-- recorded place or shipped entrance by name on the map or the zone over it.
local H = require("Harness")

local MAPS = {
    [1415] = { mapID = 1415, mapType = 2 },                      -- Eastern Kingdoms
    [1429] = { mapID = 1429, mapType = 3, parentMapID = 1415 },  -- Elwynn Forest
    [1426] = { mapID = 1426, mapType = 3, parentMapID = 1415 },  -- Dun Morogh
    [1500] = { mapID = 1500, mapType = 5, parentMapID = 1429 },  -- a building in Elwynn
    [1501] = { mapID = 1501, mapType = 4, parentMapID = 1500 },  -- a cellar under it
}

local function Env()
    local env = H.newEnv()
    env.C_Map.GetMapInfo = function(id) return MAPS[id] end
    local ns = H.newNs(env)
    local API = env.EasyFind.API
    ns.STATIC_LOCATIONS = {
        [1429] = { { name = "Innkeeper", category = "innkeeper", x = 0.4, y = 0.5 } },
        [1426] = { { name = "Mailbox", category = "mailbox", x = 0.4, y = 0.5 } },
    }
    ns.MapSearch = { GetGlobalInstanceCache = function() return { { name = "The Deadmines", entranceMapID = 1431 } } end }
    local asked = {}
    ns.Npcs = {
        NamedOn = function(name, maps)
            asked[#asked + 1] = name
            if name == "Hogger" and maps[1429] then return 448 end
            return nil
        end,
        HasID = function(id) return id == 448 end,
    }
    return API, asked, ns
end

local tests = {}

function tests.aCreatureAnswersItsId_onTheMapOrItsZone()
    local API, asked = Env()
    H.assertEq(API.HasRow("Hogger", 1429), 448)
    H.assertEq(API.HasRow("Hogger", 1501), 448, "a cellar under a building: the zone's maps are asked too")
    H.assertEq(API.HasRow("Hogger", 1426), false, "another zone")
    H.assertEq(asked[1], "Hogger", "the name passed as given; the catalog lowers it")
end

function tests.aPlaceOrEntranceAnswersTrue_byNameAnyCase()
    local API = Env()
    H.assertEq(API.HasRow("innkeeper", 1429), true)
    H.assertEq(API.HasRow("INNKEEPER", 1500), true, "a building in the zone")
    H.assertEq(API.HasRow("Innkeeper", 1426), false, "not on that map")
    H.assertEq(API.HasRow("Mailbox", 1426), true)
    H.assertEq(API.HasRow("the deadmines", 1431), true, "a shipped entrance on its map")
    H.assertEq(API.HasRow("Nobody", 1429), false)
    H.assertEq(API.HasRow("", 1429), false)
    H.assertEq(API.HasRow("Innkeeper", nil), false)
    H.assertEq(API.HasRow(nil, 1429), false)
end

function tests.hasCreatureAsksTheCatalog_placesAnswerWithoutOne()
    local API, _, ns = Env()
    H.assertTrue(API.HasCreature(448))
    H.assertFalse(API.HasCreature(449))
    H.assertFalse(API.HasCreature("448"))
    ns.Npcs = nil
    H.assertFalse(API.HasCreature(448), "no catalog loaded")
    H.assertEq(API.HasRow("Hogger", 1429), false, "and no creature row")
    H.assertEq(API.HasRow("Innkeeper", 1429), true, "the places still answer")
end

-- The catalog's side (EasyFind_GPS Npcs.lua), read when the repo sits
-- beside this checkout.
function tests.theCatalogCarriesTheLookups()
    local f = io.open((os.getenv("GPS_ROOT") or (H.ADDON_ROOT .. "/../EasyFind_GPS")) .. "/Npcs.lua", "rb")
    if not f then return end
    local src = f:read("*a")
    f:close()
    H.assertTrue(src:find("function N.NamedOn(name, maps)", 1, true) ~= nil)
    H.assertTrue(src:find("function N.HasID(npcID)", 1, true) ~= nil)
    H.assertTrue(src:find("if not byLow then IndexNames() end", 1, true) ~= nil, "an index, not a scan per ask")
end

local pass, fail, failures = H.runSuite("APIHasRow", tests)
return { pass = pass, fail = fail, failures = failures }
