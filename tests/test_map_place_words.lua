-- A place named beside other words in the bar's map pass (MapSearch/Search/
-- Results.lua PlaceScope, MINOR 7): "mailbox durotar", "ek decor". The rows
-- on its maps and the maps inside them score the other words too; a place
-- alone, or every word a place, scopes nothing.
local H = require("Harness")

local function Read()
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/Search/Results.lua", "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local ZONES = {
    durotar = { { mapID = 1, nameLower = "durotar" } },
    eastern = { { mapID = 13, nameLower = "eastern kingdoms" } },
    ek = { { mapID = 13, nameLower = "eastern kingdoms" } },
    barrens = { { mapID = 10, nameLower = "the barrens" } },
}
local CHILDREN = { [1] = { { mapID = 1001 } }, [13] = { { mapID = 1429 }, { mapID = 84 } } }

local function Scope()
    local src = Read()
    local s = assert(src:find("local placeFor, placeScope = nil, nil", 1, true), "PlaceScope")
    local e = assert(src:find("-- The bar's search runs sliced", s, true))
    local asked = 0
    local env = setmetatable({
        MapSearch = { ZonesNamed = function(_, word) asked = asked + 1 return ZONES[word] end },
        C_Map = { GetMapChildrenInfo = function(id) return CHILDREN[id] end },
    }, { __index = _G })
    local fns = assert(load(src:sub(s, e - 1) .. "\nreturn PlaceScope, InPlace", "=Results.lua places", "t", env))
    local PlaceScope, InPlace = fns()
    return PlaceScope, InPlace, function() return asked end
end

local tests = {}

function tests.aPlaceBesideOtherWords_scopesTheRest()
    local PlaceScope = Scope()
    local p = PlaceScope("mailbox durotar")
    H.assertEq(p.query, "mailbox")
    H.assertTrue(p.maps[1], "the zone")
    H.assertTrue(p.maps[1001], "and the maps inside it")
    p = PlaceScope("ek decor")
    H.assertEq(p.query, "decor")
    H.assertTrue(p.maps[13] and p.maps[1429] and p.maps[84], "a continent and every map in it")
end

function tests.theRestOfItsNameIsThePlaceToo()
    local PlaceScope = Scope()
    local p = PlaceScope("eastern kingdoms decor")
    H.assertEq(p.query, "decor", "kingdoms is the place's word, not the query's")
end

function tests.nothingScopedWithoutBoth()
    local PlaceScope = Scope()
    H.assertNil(PlaceScope("durotar"), "a place alone")
    H.assertNil(PlaceScope("storm crow"), "no place")
    H.assertNil(PlaceScope("durotar barrens"), "every word a place")
end

function tests.keptForTheLastQuery()
    local PlaceScope, _, Asked = Scope()
    local first = PlaceScope("mailbox durotar")
    local asked = Asked()
    H.assertEq(PlaceScope("mailbox durotar"), first)
    H.assertEq(Asked(), asked, "the zones are not asked again")
end

function tests.inPlace_byEntranceZoneOrSpot_neverAZoneRow()
    local PlaceScope, InPlace = Scope()
    local p = PlaceScope("mailbox durotar")
    H.assertTrue(InPlace({ mapID = 1001 }, p))
    H.assertTrue(InPlace({ entranceMapID = 1, mapID = 999 }, p), "an instance by its entrance")
    H.assertFalse(InPlace({ mapID = 999 }, p))
    H.assertFalse(InPlace({ mapID = 1, isZone = true }, p), "a zone row is the place, not in it")
end

-- The map pass reads it: names one under the full query's match, the
-- place's kind of row one above the same kind elsewhere.
function tests.wiring()
    local src = Read()
    H.assertTrue(src:find("if here then score = mmax(score, ScorePOIForQuery(poi, place.query) - 1) end", 1, true) ~= nil)
    H.assertTrue(src:find("AddScoredPOI(results, seen, duplicates, poi, key, place and score + 1 or score)", 1, true) ~= nil)
    H.assertTrue(src:find("local place = PlaceScope(query)", 1, true) ~= nil)
    H.assertTrue(src:find("if narrowed and (scoped or place) then candidates, narrowed = pois, false end", 1, true) ~= nil,
        "a place's rows are not narrowed from the last query's")
end

local pass, fail, failures = H.runSuite("MapPlaceWords", tests)
return { pass = pass, fail = fail, failures = failures }
