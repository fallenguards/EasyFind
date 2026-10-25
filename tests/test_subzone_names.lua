-- Tests for the GPS data's subzones as map search places
-- (MapSearch/Search/Scanners.lua GetSubzones, SubzonePOI; Sources.lua
-- AppendSubzones): an area named like a map beside or under its zone is
-- that map, listed once as a zone; places are kept packed and built only
-- for a query that can reach them.
local H = require("Harness")

local function read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local function slice(src, from, to)
    local s = assert(src:find(from, 1, true), from .. " not found")
    local e = assert(src:find(to, s + #from, true), to .. " not found")
    return src:sub(s, e - 1)
end

local function loadSubzones(areas, areaNames, maps, children, categories)
    local env = H.newEnv()
    env.slower = string.lower
    local Search = {}
    env.Search = Search
    Search.LetterMask = assert(load(slice(read("MapSearch/Search/Core.lua"),
        "local band, bor, lshift = bit.band", "\n-- Combined mask over the POI's searchable text")
        .. "\nreturn LetterMask", "=Core.lua LetterMask", "t", env))()
    local MapSearch = {
        GetCategoryMatch = function(_, q) return categories and categories[q] or nil end,
        GetRelatedCategories = function(_, c) return { c } end,
    }
    env.MapSearch = MapSearch
    env.ns = { GPSData = { areas = areas } }
    env.C_Map = { GetAreaInfo = function(id) return areaNames[id] end }
    env.GetMapInfo = function(id) return maps[id] end
    env.GetMapChildrenInfo = function(id) return children[id] end
    env.PreparePOI = function(poi) return poi end
    assert(load(slice(read("MapSearch/Search/Scanners.lua"), "local subzones", "\nfunction MapSearch:GetStaticLocations"),
        "=Scanners.lua subzones", "t", env))()
    local sources = read("MapSearch/Search/Sources.lua")
    local AppendSubzones = assert(load(slice(sources, "local function ClearPerQueryResultState", "\nlocal function AppendPromotedInstanceResults")
        .. slice(sources, "-- Whether every subzone is a candidate", "\nSearch.AppendAlwaysFindableLocations")
        .. "\nreturn AppendSubzones", "=Sources.lua AppendSubzones", "t", env))()
    return MapSearch, AppendSubzones
end

local ELWYNN = { [1429] = { name = "Elwynn Forest", parentMapID = 1415 } }
local CHILDREN = { [1415] = { { mapID = 1453, name = "Stormwind City" }, { mapID = 1429, name = "Elwynn Forest" } }, [1429] = {} }

local tests = {}

function tests.cityAreaInsideItsNeighbourIsNotAPlaceOfItsOwn()
    local MapSearch = loadSubzones({ [1429] = { 1, 0.3, 0.2, 2, 0.4, 0.6 } },
        { [1] = "Stormwind City", [2] = "Goldshire" }, ELWYNN, CHILDREN)
    local sz = MapSearch:GetSubzones()
    H.assertEq(sz.n, 1, "Stormwind City is a zone, found as one")
    local poi = MapSearch:SubzonePOI(1)
    H.assertEq(poi.name, "Goldshire")
    H.assertEq(poi.nameLower, "goldshire")
    H.assertEq(poi.zoneName, "Elwynn Forest")
    H.assertEq(poi.category, "subzone")
    H.assertEq(poi.x, 0.4)
    H.assertEq(poi.mapID, 1429)
    H.assertTrue(MapSearch:SubzonePOI(1) == poi, "one table while held")
end

function tests.onlyPlacesTheQueryCanReachAreBuilt()
    local MapSearch, AppendSubzones = loadSubzones({ [1429] = { 2, 0.4, 0.6, 3, 0.5, 0.5 } },
        { [2] = "Goldshire", [3] = "Northshire" }, ELWYNN, CHILDREN)
    local out, names = {}, {}
    AppendSubzones(MapSearch, out, names, nil, "Gold")
    H.assertEq(#out, 1)
    H.assertEq(out[1].name, "Goldshire")
    H.assertTrue(names.northshire, "a place out of reach still takes its name")
    out, names = {}, {}
    AppendSubzones(MapSearch, out, names, nil, "xyz")
    H.assertEq(#out, 0)
    out = {}
    AppendSubzones(MapSearch, out, nil, 1429, "gold")
    H.assertEq(#out, 0, "the viewed zone's own stand among its statics")
end

function tests.aQueryForTheirCategoryTakesEveryPlace()
    local MapSearch, AppendSubzones = loadSubzones({ [1429] = { 2, 0.4, 0.6, 3, 0.5, 0.5 } },
        { [2] = "Goldshire", [3] = "Northshire" }, ELWYNN, CHILDREN, { ["district"] = "subzone" })
    local out = {}
    AppendSubzones(MapSearch, out, nil, nil, "district")
    H.assertEq(#out, 2, "listed by category, whatever their letters")
    out = {}
    AppendSubzones(MapSearch, out, nil, nil, nil)
    H.assertEq(#out, 2, "no query: every place")
end

local pass, fail, failures = H.runSuite("SubzoneNames", tests)
return { pass = pass, fail = fail, failures = failures }
