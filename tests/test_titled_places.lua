-- A place that is one creature (a weapon master, StaticLocations npcName):
-- its row is "Weapon Master Hanashi", named as the client says when the GPS
-- catalog has the creature, with its face; and it stands in for the
-- catalog's own row (MapSearch/Search/Scanners.lua TitledCreature,
-- Sources.lua AppendSearchCandidate).
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

local ROWS = {
    [1454] = {
        { name = "Weapon Master", category = "trainer", x = 0.8153, y = 0.1963, keywords = { "weapon" },
          teaches = { 196, 197 }, npcName = "Hanashi" },
        { name = "Weapon Master", category = "trainer", x = 0.8170, y = 0.1955, keywords = { "weapon" },
          teaches = { 196, 15590 }, npcName = "Sayoc" },
        { name = "Innkeeper", category = "innkeeper", x = 0.5, y = 0.5, keywords = { "inn" } },
    },
}

local function loadStatics(npcs)
    local env = H.newEnv()
    env.slower = string.lower
    env.tinsert = table.insert
    env.ipairs, env.pairs = ipairs, pairs
    env.L = { POI_TITLED_FMT = "%s %s" }
    env.ns = { GPSNpcs = npcs }
    env.STATIC_LOCATIONS = ROWS
    env.staticLocationCache = {}
    env.emptyStaticLocations = {}
    env.PreparePOI = function(poi) poi.nameLower = string.lower(poi.name) return poi end
    env.GetMapInfo = function(id) return { name = "Map " .. id } end
    local MapSearch = {
        GetSubzones = function() return { n = 0, map = {} } end,
        GetFilterBucket = function() return "services" end,
        GetSubBucket = function() return nil end,
    }
    env.MapSearch = MapSearch
    assert(load(slice(read("MapSearch/Search/Scanners.lua"), "-- A place that is one creature",
        "\nfunction MapSearch:ScanVignettes"), "=Scanners.lua statics", "t", env))()
    return MapSearch
end

local tests = {}

function tests.withoutTheCatalog_theEnglishName()
    local MapSearch = loadStatics(nil)
    local rows = MapSearch:GetStaticLocations(1454)
    H.assertEq(#rows, 3)
    H.assertEq(rows[1].name, "Weapon Master Hanashi")
    H.assertEq(rows[2].name, "Weapon Master Sayoc")
    H.assertEq(rows[1].npcNameLower, "hanashi")
    H.assertNil(rows[1].npcID)
    H.assertEq(rows[3].name, "Innkeeper", "other places as they are")
    H.assertNil(rows[3].npcNameLower)
    H.assertEq(rows[2].teaches[2], 15590, "its own weapons ride along")
end

function tests.withTheCatalog_theClientsNameAndItsFace()
    local asked = {}
    local MapSearch = loadStatics({ ByName = function(name)
        asked[#asked + 1] = name
        if name == "Hanashi" then return { name = "하나시", npcID = 3184, displayID = 4567 } end
        return nil
    end })
    local rows = MapSearch:GetStaticLocations(1454)
    H.assertEq(rows[1].name, "Weapon Master 하나시")
    H.assertEq(rows[1].npcNameLower, "하나시")
    H.assertEq(rows[1].npcID, 3184)
    H.assertEq(rows[1].displayID, 4567)
    H.assertEq(rows[2].name, "Weapon Master Sayoc", "not in the catalog: English")
    H.assertEq(table.concat(asked, ","), "Hanashi,Sayoc", "only the creatures asked for")
    -- The bar's list from every map says the same.
    local world = MapSearch:GetWorldStaticLocations()
    H.assertEq(world[1].name, "Weapon Master 하나시")
    H.assertEq(world[1].zoneName, "Map 1454")
end

-- Listed as a search candidate, the creature's own name is taken too, so
-- the GPS catalog's row of the same creature is not listed twice.
function tests.theRow_standsInForTheCatalogsCreature()
    local env = H.newEnv()
    env.GetNameLower = function(e) return e.nameLower end
    local Append = assert(load(slice(read("MapSearch/Search/Sources.lua"), "local function AppendSearchCandidate",
        "\nlocal function AppendLocalSearchSources") .. "\nreturn AppendSearchCandidate", "=Sources.lua", "t", env))()
    local out, names = {}, {}
    H.assertTrue(Append(out, names, nil, { nameLower = "weapon master hanashi", npcNameLower = "hanashi" }, true))
    H.assertTrue(names["weapon master hanashi"])
    H.assertTrue(names["hanashi"], "the creature's name")
    H.assertTrue(Append(out, names, nil, { nameLower = "innkeeper" }, true))
    H.assertEq(#out, 2)
end

local pass, fail, failures = H.runSuite("Titled places", tests)
return { pass = pass, fail = fail, failures = failures }
