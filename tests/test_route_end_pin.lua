-- A right-click on the route's end pin ends the route (MapSearch/Navigation.lua
-- RouteEndsHere). The GPS pins the end on whatever map is viewed, at that
-- map's spot for it; matched by the destination's own map and x, y alone,
-- the pin on the zone around a city went and the route's line stayed.
local H = require("Harness")

local function Load(pinned, dest, viewed)
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/Navigation.lua", "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    local s = assert(src:find("local function RouteEndsHere", 1, true), "RouteEndsHere")
    local e = assert(src:find("local function PinEnter", s, true), "its end")
    local env = setmetatable({
        EasyFind = { API = { CallAction = function(id, name) if id == "gps" and name == "destination" then return dest end end } },
        WorldMapFrame = { GetMapID = function() return viewed end },
    }, { __index = _G })
    local chunk = "local routeEndPinned = " .. tostring(pinned) .. "\n" .. src:sub(s, e - 1) .. "\nreturn RouteEndsHere"
    return assert(load(chunk, "=Navigation.lua RouteEndsHere", "t", env))()
end

local CITY = { name = "Auction House", mapID = 84, x = 0.61, y = 0.71 }

local tests = {}

function tests.theGPSsEndPinOnAnotherMapEndsTheRoute()
    local ends, dest = Load(true, CITY, 37)({ waypointX = 0.32, waypointY = 0.88 })
    H.assertTrue(ends, "the zone around the city shows the end at its own spot")
    H.assertEq(dest, CITY)
end

function tests.aPinOnTheDestinationsOwnMapStillCounts()
    H.assertTrue(Load(false, CITY, 84)({ waypointX = 0.612, waypointY = 0.709 }))
end

function tests.anotherPinLeavesTheRoute()
    H.assertFalse(Load(false, CITY, 84)({ waypointX = 0.2, waypointY = 0.3 }))
    H.assertFalse(Load(false, CITY, 37)({ waypointX = 0.61, waypointY = 0.71 }), "same numbers, another map")
end

function tests.noRouteNothingToEnd()
    H.assertFalse(Load(true, nil, 84)({ waypointX = 0.61, waypointY = 0.71 }))
end

local pass, fail, failures = H.runSuite("RouteEndPin", tests)
return { pass = pass, fail = fail, failures = failures }
