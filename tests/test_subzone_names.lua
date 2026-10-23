-- Tests for the GPS data's subzones as map search places
-- (MapSearch/Search/Scanners.lua GetSubzoneLocations): an area named like a
-- map beside or under its zone is that map, listed once as a zone.
local H = require("Harness")

local function loadSubzones(areaNames, maps, children)
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/Search/Scanners.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local subzoneCache", 1, true), "subzone list not found")
    local e = assert(src:find("\nfunction MapSearch:GetStaticLocations", s, true), "end not found")
    local MapSearch = {}
    local env = setmetatable({
        MapSearch = MapSearch, ipairs = ipairs, pairs = pairs,
        ns = { GPSData = { areas = { [1429] = { 1, 0.3, 0.2, 2, 0.4, 0.6 } } } },
        C_Map = { GetAreaInfo = function(id) return areaNames[id] end },
        GetMapInfo = function(id) return maps[id] end,
        GetMapChildrenInfo = function(id) return children[id] end,
        PreparePOI = function(poi) return poi end,
    }, { __index = _G })
    assert(load(src:sub(s, e), "=Scanners.lua GetSubzoneLocations", "t", env))()
    return MapSearch
end

local tests = {}

function tests.cityAreaInsideItsNeighbourIsNotAPlaceOfItsOwn()
    local MapSearch = loadSubzones(
        { [1] = "Stormwind City", [2] = "Goldshire" },
        { [1429] = { name = "Elwynn Forest", parentMapID = 1415 } },
        { [1415] = { { mapID = 1453, name = "Stormwind City" }, { mapID = 1429, name = "Elwynn Forest" } }, [1429] = {} })
    local list = MapSearch:GetSubzoneLocations()
    H.assertEq(#list, 1, "Stormwind City is a zone, found as one")
    H.assertEq(list[1].name, "Goldshire")
    H.assertEq(list[1].zoneName, "Elwynn Forest")
end

local pass, fail, failures = H.runSuite("SubzoneNames", tests)
return { pass = pass, fail = fail, failures = failures }
