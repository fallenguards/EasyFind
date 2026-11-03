-- A place as the words it answers to (Shared/MapUtils.lua ZoneWords, MINOR
-- 7): the map and the maps over it up to the continent, the short names
-- typed for them, the continent's initials; and an extension's row on a
-- map carries them among its words, once however often it is handed over
-- (Core/API.lua Populate): "decor durotar", "ek decor".
local H = require("Harness")

local ZONE, CONTINENT, WORLD, MICRO = 3, 2, 1, 5
local MAPS = {
    [947] = { name = "Azeroth", mapType = WORLD },
    [12] = { name = "Kalimdor", mapType = CONTINENT, parent = 947 },
    [1] = { name = "Durotar", mapType = ZONE, parent = 12 },
    [85] = { name = "Orgrimmar", mapType = ZONE, parent = 1 },
    [86] = { name = "Cleft of Shadow", mapType = MICRO, parent = 85 },
    [13] = { name = "Eastern Kingdoms", mapType = CONTINENT, parent = 947 },
    [37] = { name = "Elwynn Forest", mapType = ZONE, parent = 13 },
}

local function MapUtils()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.Enum = { UIMapType = { Cosmic = 0, World = WORLD, Continent = CONTINENT, Zone = ZONE, Dungeon = 4, Micro = MICRO, Orphan = 6 } }
    env.C_Map = { GetMapInfo = function(id)
        local m = MAPS[id]
        return m and { mapID = id, name = m.name, mapType = m.mapType, parentMapID = m.parent or 0 }
    end }
    H.loadModule("Shared/MapUtils.lua", env, ns)
    return ns.MapUtils
end

local function Has(list, word)
    for _, w in ipairs(list) do
        if w == word then return true end
    end
    return false
end

local tests = {}

function tests.theMapAndEveryMapOverIt_toTheContinent()
    local words = MapUtils().ZoneWords(86)
    for _, w in ipairs({ "cleft of shadow", "orgrimmar", "durotar", "kalimdor" }) do
        H.assertTrue(Has(words, w), w)
    end
    H.assertFalse(Has(words, "azeroth"), "not the world over the continent")
end

function tests.shortNamesAndTheContinentsInitials()
    local MU = MapUtils()
    local org = MU.ZoneWords(85)
    H.assertTrue(Has(org, "org") and Has(org, "og"), "the short names for Orgrimmar")
    H.assertTrue(Has(org, "kali"), "and for Kalimdor")
    local elwynn = MU.ZoneWords(37)
    H.assertTrue(Has(elwynn, "ek"), "the continent's initials")
    H.assertTrue(Has(elwynn, "eastern kingdoms"))
    H.assertFalse(Has(elwynn, "ef"), "a zone's initials are not added")
    H.assertEq(MU.ZoneWords(37), elwynn, "kept per map")
end

-- An extension's row on a map: its own words, then its place's, once.
function tests.aRowOnAMap_answersToItsPlace_once()
    local env = H.newEnv()
    env.geterrorhandler = function() return print end
    env.InCombatLockdown = function() return false end
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    ns.MapUtils = { ZoneWords = function(id) return id == 1 and { "durotar", "kalimdor", "kali" } or {} end }
    local replaced, providers = {}, {}
    ns.Database.AddDynamicProvider = function(_, p) providers[p.key] = p end
    ns.Database.ReplaceCategoryEntries = function(_, cat, rows) replaced[cat] = rows return rows ~= nil end
    local API = env.EasyFind.API
    API.RegisterExtension({ id = "pins", name = "Pins", icon = 1 })
    local pinned = { name = "Decor Vendor", mapID = 1, keywords = { "Decor" } }
    local away = { name = "Nowhere" }
    API.RegisterSearchProvider({ key = "pins", label = "Pins", extension = "pins",
        rows = function() return { pinned, away } end })
    providers.pins.fn(ns.Database)
    providers.pins.fn(ns.Database)
    local kw = replaced.pins[1].keywordsLower
    H.assertEq(table.concat(kw, ","), "decor,durotar,kalimdor,kali", "its own words, then its place's, once")
    H.assertNil(replaced.pins[2].keywordsLower, "a row on no map: no words added")
end

local pass, fail, failures = H.runSuite("ZoneWords", tests)
return { pass = pass, fail = fail, failures = failures }
