-- Which maps the map search lists as places (MapUtils.IsPlaceMap, the zone
-- catalog in MapSearch/Zones/Catalog.lua): a continent's dungeon-typed city
-- counts when drawn on it (Dalaran) or on its navigation bar (Oribos, one
-- building with no rect there); an old copy under another world does not.
local H = require("Harness")

local ZONE, CONTINENT, WORLD, DUNGEON, MICRO, ORPHAN = 3, 2, 1, 4, 5, 6
local NAVBAR = 32768

-- A small retail tree: the Shadowlands with Oribos and Bastion, the Broken
-- Isles with Dalaran, the Eastern Kingdoms with an old Dalaran copy.
local MAPS = {
    [946] = { name = "Cosmic", mapType = 0 },
    [947] = { name = "Azeroth", mapType = WORLD, parent = 946 },
    [1550] = { name = "The Shadowlands", mapType = CONTINENT, parent = 946 },
    [1533] = { name = "Bastion", mapType = ZONE, parent = 1550, rect = true },
    [1670] = { name = "Oribos", mapType = DUNGEON, parent = 1550, flags = NAVBAR + 65536 },
    [1671] = { name = "Oribos", mapType = DUNGEON, parent = 1550, flags = 65536 + 4 },
    [619] = { name = "Broken Isles", mapType = CONTINENT, parent = 947 },
    [627] = { name = "Dalaran", mapType = DUNGEON, parent = 619, flags = NAVBAR, rect = true },
    [13] = { name = "Eastern Kingdoms", mapType = CONTINENT, parent = 947 },
    [501] = { name = "Dalaran", mapType = DUNGEON, parent = 13, flags = 0 },
    [1429] = { name = "Elwynn Forest", mapType = ZONE, parent = 13, rect = true },
    [1450] = { name = "Moonglade cave", mapType = MICRO, parent = 1429 },
    -- Arathi Highlands three times under the Eastern Kingdoms: the zone, and
    -- two copies of it in a world of their own (a story's); old Quel'Thalas
    -- in its own world too, but alone of its name.
    [14] = { name = "Arathi Highlands", mapType = ZONE, parent = 13, rect = true },
    [2372] = { name = "Arathi Highlands", mapType = ZONE, parent = 13, rect = true, world = 2796 },
    [2451] = { name = "Arathi Highlands", mapType = ZONE, parent = 13, rect = true, world = 2796 },
    [94] = { name = "Eversong Woods", mapType = ZONE, parent = 13, rect = true, world = 530 },
}

local function fresh()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.Enum = {
        UIMapType = { Cosmic = 0, World = WORLD, Continent = CONTINENT, Zone = ZONE, Dungeon = DUNGEON,
                      Micro = MICRO, Orphan = ORPHAN },
        UIMapFlag = { ForceOnNavbar = NAVBAR },
    }
    local function Details(id)
        local m = MAPS[id]
        return m and { mapID = id, name = m.name, mapType = m.mapType, parentMapID = m.parent or 0, flags = m.flags or 0 }
    end
    env.C_Map = {
        GetMapInfo = Details,
        GetMapChildrenInfo = function(id)
            local out = {}
            for child, m in pairs(MAPS) do
                if m.parent == id then out[#out + 1] = Details(child) end
            end
            table.sort(out, function(a, b) return a.mapID < b.mapID end)
            return out
        end,
        GetMapRectOnMap = function(id) if MAPS[id].rect then return 0.4, 0.5, 0.4, 0.5 end return 0, 0, 0, 0 end,
        GetWorldPosFromMapPos = function(id) return MAPS[id].world or 0, { GetXY = function() return 0, 0 end } end,
    }
    env.CreateVector2D = function(x, y) return { x = x, y = y } end
    H.loadModule("Shared/MapUtils.lua", env, ns)
    H.loadModule("MapSearch/Zones/Catalog.lua", env, ns)
    return ns
end

local function Listed(zones, id)
    for _, z in ipairs(zones) do
        if z.mapID == id then return true end
    end
    return false
end

local tests = {}

function tests.everyWorldZone_takesTheCityOnTheNavbar_notTheOldCopy()
    local ns = fresh()
    local zones = ns.MapSearch:GetAllWorldZones(946)
    H.assertTrue(Listed(zones, 1670), "Oribos: on the Shadowlands' navigation bar, no rect")
    H.assertFalse(Listed(zones, 1671), "its other floors are not places of their own")
    H.assertTrue(Listed(zones, 627), "Dalaran: drawn on the Broken Isles")
    H.assertFalse(Listed(zones, 501), "the old Dalaran under the Eastern Kingdoms")
    H.assertTrue(Listed(zones, 1533) and Listed(zones, 1429), "zones as before")
    H.assertFalse(Listed(zones, 1450), "a micro map")
end

-- A route to "Arathi Highlands" aimed at a copy in another world and found
-- no way there; the copies are not places, the zone is.
function tests.aZoneCopiedIntoAnotherWorld_isNotAPlace()
    local ns = fresh()
    local zones = ns.MapSearch:GetAllWorldZones(946)
    H.assertTrue(Listed(zones, 14), "the Arathi Highlands")
    H.assertFalse(Listed(zones, 2372), "a story's copy of it")
    H.assertFalse(Listed(zones, 2451), "and another")
    H.assertTrue(Listed(zones, 94), "a zone in its own world, alone of its name, stays")
    local direct = ns.MapSearch:GetDirectChildZones(13)
    H.assertTrue(Listed(direct, 14) and not Listed(direct, 2372), "the continent's own list agrees")
end

function tests.aContinentsOwnZones_takeItsCityToo()
    local ns = fresh()
    local zones = ns.MapSearch:GetDirectChildZones(1550)
    H.assertTrue(Listed(zones, 1670), "searching while the Shadowlands are shown finds Oribos")
    H.assertTrue(Listed(zones, 1533))
end

local pass, fail, failures = H.runSuite("MapPlaces", tests)
return { pass = pass, fail = fail, failures = failures }
