-- An extension's row with places(row) (a fish caught in several zones) is
-- one map row whose spots fold under it: pinned together on the viewed
-- map, listed on a map where one of them is, the GPS keeping place(row).
-- API.ShowPlaces opens the map tab on such a row (MINOR 3, 2026-10-30).
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function Chunk(path, from, to, ret, env)
    local src = Read(path)
    local s = assert(src:find(from, 1, true), from)
    local e = to and assert(src:find(to, s, true), to) or #src + 1
    return assert(load(src:sub(s, e - 1) .. "\nreturn " .. ret, "=" .. path, "t", setmetatable(env, { __index = _G })))()
end

local SPOTS = { { name = "Lake", mapID = 10, x = 0.2, y = 0.3, step = "Fish here" },
                { name = "River", mapID = 20, x = 0.5, y = 0.5 },
                { name = "Pond", mapID = 10, x = 0.7, y = 0.8 } }
local FISH = { key = "fishing", category = "fishing", label = "Fish", place = function() return SPOTS[2] end,
               places = function(row) return row.spots end }
local EXT = { Providers = { byKey = { fishing = FISH }, byCategory = { fishing = FISH } } }
local ROWS = { { name = "Mud Snapper", category = "fishing", spots = SPOTS },
               { name = "Eel", category = "fishing", spots = {} } }

local function Vec(x, y) return { x = x, y = y, GetXY = function(self) return self.x, self.y end } end

local function Env(extra)
    local env = { ns = { Extensions = EXT, Database = { uiSearchData = ROWS } }, MapSearch = {},
                  C_Map = { GetMapInfo = function(id) return { name = "Zone" .. id } end } }
    for k, v in pairs(extra or {}) do env[k] = v end
    return env
end

local function Appender()
    return Chunk("MapSearch/Search/Results.lua", "-- Every spot a provider's row stands for",
        "-- The spot a provider's row stands for", "{ append = AppendProviderRows, spots = ProviderSpots }", Env())
end

local function OnMap(list, m)
    local out = {}
    for _, s in ipairs(list) do if s.coordMapID == m then out[#out + 1] = s end end
    return out
end

local tests = {}

function tests.aRowsSpots_areMapPlacesOfItsNameFoldedUnderIt()
    local fns = Appender()
    local fresh = {}
    fns.append(fresh, "mud", nil)
    H.assertEq(#fresh, 2, "both rows in a global search")
    local head = fresh[1]
    H.assertEq(head.name, "Mud Snapper")
    H.assertEq(#head.spots, 3)
    H.assertEq(head.spots[1].coordMapID, 10, "a spot carries its map for the pins and the ranking")
    H.assertEq(head.spots[1].destName, "Lake")
    H.assertEq(head.spots[1].zoneName, "Zone10")
    H.assertEq(head.spots[1].category, "fishing")
    H.assertEq(head.placeOf, FISH.place, "place(row) stays the GPS's spot")
    H.assertEq(fresh[2].spots, nil, "a row with no spots is the plain place row it was")
    fns.append(fresh, "mud", nil)
    H.assertEq(fresh[3], head, "one map row per search row, kept across queries")
end

function tests.theMapsOwnList_showsARowWhereOneOfItsSpotsIs()
    local fns = Appender()
    local fresh = {}
    fns.append(fresh, "mud", 10)
    H.assertEq(#fresh, 1, "Mud Snapper has spots on map 10; Eel names no map")
    fresh = {}
    fns.append(fresh, "mud", 30)
    H.assertEq(#fresh, 0, "no spot on map 30")
end

function tests.theSpotsFoldUnderTheRow_theViewedMapsInTheLocalList()
    local fns = Appender()
    local fresh = {}
    fns.append(fresh, "mud", nil)
    local head = fresh[1]
    local search = { isGlobalSearch = false }
    local attach = Chunk("MapSearch/Search/Results.lua", "local function AttachDuplicateSets",
        "-- The rows with their scores", "AttachProviderSpots",
        { Search = search, WorldMapFrame = { GetMapID = function() return 10 end }, MapSearch = { SpotsOnMap = OnMap } })
    attach({ head })
    H.assertEq(#head.allInstances, 2, "the two spots on map 10 fold under it")
    head.allInstances = nil
    search.isGlobalSearch = true
    attach({ head })
    H.assertEq(head.allInstances, head.spots, "every spot in a global search")
end

function tests.theGpsSpot_carriesItsMapForThePins()
    local MapSearch = Chunk("MapSearch/Search/Results.lua", "function MapSearch.ResolvePlace",
        "-- Pure result computation", "MapSearch", Env({ GetTime = function() return 100 end }))
    local data = { placeOf = function() return SPOTS[1] end, providerRow = {} }
    MapSearch.ResolvePlace(data)
    H.assertEq(data.coordMapID, 10)
    H.assertEq(data.mapID, 10)
    H.assertEq(data.destName, "Lake")
end

function tests.showPlaces_opensTheMapTabOnTheRowWithItsSpots()
    local opened, selected
    local env = Env({
        WorldMapFrame = { IsShown = function() return true end, GetMapID = function() return 10 end },
        ToggleWorldMap = function() end,
        CreateVector2D = Vec,
    })
    env.ns.MapTab = { OpenWithQuery = function(_, q) opened = q end }
    env.C_Map.GetBestMapForUnit = function() return 10 end
    env.C_Map.GetPlayerMapPosition = function() return Vec(0, 0) end
    env.C_Map.GetWorldPosFromMapPos = function(_, v) return 1, Vec(v.x * 100, v.y * 100) end
    env.MapSearch = { ProviderSpots = function(p, row) return Appender().spots(p, row) end,
                      SelectResult = function(_, data) selected = data end }
    local MapSearch = Chunk("MapSearch/UINavigation.lua", "function MapSearch.NearestSpot", nil, "MapSearch", env)
    H.assertTrue(MapSearch:ShowProviderPlaces(FISH, ROWS[1]))
    H.assertEq(opened, "Mud Snapper", "the map tab searched for the row")
    H.assertEq(#selected.allInstances, 3, "its spots pinned together")
    H.assertEq(selected.coordMapID, 10, "the nearest spot's map, should none be on the viewed one")
    H.assertEq(selected.x, 0.2)
    H.assertEq(selected.placeOf, FISH.place)
    H.assertFalse(MapSearch:ShowProviderPlaces({ places = function() return {} end }, ROWS[2]), "no spots: nothing shown")
end

function tests.theApiOffersIt()
    local src = Read("Core/API.lua")
    H.assertTrue(src:find("places = \"function\"", 1, true) ~= nil, "places passes the provider check")
    H.assertTrue(src:find("function API.ShowPlaces(key, row)", 1, true) ~= nil)
    H.assertTrue(src:find("MINOR = 3", 1, true) ~= nil)
end

local pass, fail, failures = H.runSuite("ProviderPlaces", tests)
return { pass = pass, fail = fail, failures = failures }
