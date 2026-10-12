-- Tests for where a GPS route aims (Apps/GPS/GPS.lua Destination): a zone
-- or a continent is "reached on entering it"; a spot on a map is a spot.

local H = require("Harness")

-- Destination and its helpers, cut from GPS.lua (the rest of the file needs
-- the whole client).
local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("-- Instances carry isZone in search", 1, true), "Destination not in GPS.lua")
    local e = assert(src:find("-- The engine plans over", s, true), "end of Destination not found")
    local MAPS = {
        [947] = { mapType = 1 }, [1414] = { mapType = 2 }, [1440] = { mapType = 3 }, [491] = { mapType = 4 },
    }
    local env = setmetatable({
        C_Map = { GetMapInfo = function(m) return MAPS[m] end },
        Enum = { UIMapType = { Zone = 3 } },
        EntranceOf = function() return nil end,
    }, { __index = _G })
    return assert(load(src:sub(s, e - 1) .. "\nreturn Destination", "=GPS.lua Destination", "t", env))()
end

local tests = {}

-- The case that "arrived" at once: an instance pinned on the continent map.
function tests.instanceOnTheContinent_isASpotNotAZone()
    local Destination = Load()
    local dest = Destination({ name = "Razorfen Kraul", category = "dungeon", isZone = true, mapID = 1414, x = 0.5089, y = 0.7035 })
    H.assertNil(dest.zone)
    H.assertEq(dest.mapID, 1414)
end

function tests.zoneRow_isReachedOnEnteringItsMap()
    local Destination = Load()
    local dest = Destination({ name = "Ashenvale", category = "zone", isZone = true, mapID = 1440 })
    H.assertTrue(dest.zone)
    H.assertEq(dest.mapID, 1440)
end

-- The boat to Menethil Harbor already lands in Eastern Kingdoms.
function tests.continentRow_isReachedOnEnteringIt()
    local Destination = Load()
    local dest = Destination({ name = "Eastern Kingdoms", category = "zone", isZone = true, zoneMapID = 1415 })
    H.assertTrue(dest.zone)
    H.assertEq(dest.mapID, 1415)
end

function tests.zoneRowAtASpot_isASpot()
    local Destination = Load()
    H.assertNil(Destination({ name = "Ashenvale", category = "zone", isZone = true, mapID = 1414, x = 0.4, y = 0.3 }).zone)
end

local pass, fail, failures = H.runSuite("GPSDestination", tests)
return { pass = pass, fail = fail, failures = failures }
