-- The "Finding a way" line sits right under the trip's fields, where the
-- window's planning height counts it (Apps/GPS/GPS.lua, GPS.planning); the
-- arrival line sits where the steps were. The planning line was anchored
-- at the steps' place and cut off at the window's bottom (2026-10-27).
local H = require("Harness")

local function Read(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local function Load()
    local src = Read("Apps/GPS/Trip.lua")
    local s = assert(src:find("\nfunction Trip.PlaceEmpty(frame, underFields)", 1, true), "PlaceEmpty not in Trip.lua")
    local _, e = assert(src:find("\nend\r?\n", s))
    local Trip = {}
    assert(load(src:sub(s, e), "=Trip.lua PlaceEmpty", "t", setmetatable({ Trip = Trip }, { __index = _G })))()
    return Trip
end

local function Frame()
    local empty = { points = {} }
    function empty:SetPoint(point, rel, relPoint, x, y) self.points[point] = { rel = rel, relPoint = relPoint, x = x, y = y } end
    local ed = { emptyX = 6, emptyStepsY = -24 }
    return { trip = ed, empty = empty }, ed, empty
end

local tests = {}

function tests.findingAWay_sitsUnderTheFields()
    local Trip = Load()
    local frame, ed, empty = Frame()
    Trip.PlaceEmpty(frame, true)
    local p = empty.points.TOPLEFT
    H.assertEq(p.rel, ed)
    H.assertEq(p.relPoint, "BOTTOMLEFT")
    H.assertEq(p.x, 6)
    H.assertEq(p.y, -10, "the gap the window's planning height allows for")
end

function tests.arrived_sitsWhereTheStepsWere()
    local Trip = Load()
    local frame, _, empty = Frame()
    Trip.PlaceEmpty(frame, false)
    H.assertEq(empty.points.TOPLEFT.y, -24)
    Trip.PlaceEmpty({ empty = empty }, true)
    H.assertEq(empty.points.TOPLEFT.y, -24, "no editor: nothing moves")
end

function tests.theWindowPlacesItForEachState()
    local src = Read("Apps/GPS/GPS.lua")
    H.assertTrue(src:find("if finding then%s+ns%.GPSTrip%.PlaceEmpty%(container, true%)") ~= nil,
        "a first way being found: the line goes under the fields")
    H.assertTrue(src:find("if container%.trip then ns%.GPSTrip%.PlaceEmpty%(container, false%) end") ~= nil,
        "arrived: the line goes where the steps were")
end

local pass, fail, failures = H.runSuite("GPSPlanningPlace", tests)
return { pass = pass, fail = fail, failures = failures }
