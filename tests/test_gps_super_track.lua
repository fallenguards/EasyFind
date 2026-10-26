-- One thing lit at a time (Apps/GPS/GPS.lua): a quest super-tracked while
-- the route is tracked (the player's pick; the game picks one itself only
-- with nothing tracked) makes the route let go, and tracking the route
-- clears a quest's super-track, so the tracker never lights both.
local H = require("Harness")

local function Load(state)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function GPS.ReleaseTracking(route)", 1, true), "GPS.ReleaseTracking")
    local e = assert(src:find("-- The toggle's faces", s, true), "the block's end")
    local onEvent
    local ST = {
        IsSuperTrackingQuest = function() return state.quest ~= 0 end,
        SetSuperTrackedQuestID = function(id) state.quest = id end,
        SetSuperTrackedUserWaypoint = function(on) state.waypoint = on end,
    }
    local GPS = {}
    local env = setmetatable({
        GPS = GPS, C_SuperTrack = ST, ns = {},
        Route = function() return state.route end,
        RouteTracked = function() return state.route ~= nil and not state.route.untracked end,
        Refresh = function() state.refreshed = (state.refreshed or 0) + 1 end,
        TrackStep = function() ST.SetSuperTrackedUserWaypoint(true) end,
        Utils = {
            SafeAfter = function(_, fn) fn() end,
            RegisterEventIfValid = function(f, event) f:RegisterEvent(event) return true end,
        },
        CreateFrame = function()
            return { RegisterEvent = function() end, SetScript = function(_, _, fn) onEvent = fn end }
        end,
    }, { __index = _G })
    assert(load(src:sub(s, e - 1), "=GPS.lua tracking", "t", env))()
    return GPS, function() onEvent() end
end

local tests = {}

function tests.aQuestPickedMidRouteMakesTheRouteLetGo()
    local state = { route = {}, quest = 0, waypoint = true }
    local _, fire = Load(state)
    state.quest = 1234   -- the player clicked a quest's POI
    fire()
    H.assertTrue(state.route.untracked, "the route lets go")
    H.assertFalse(state.waypoint, "the game's waypoint no longer super-tracked")
    H.assertEq(state.refreshed, 1, "drawn again")
end

function tests.nothingChangesWithoutAQuest()
    local state = { route = {}, quest = 0, waypoint = true }
    local _, fire = Load(state)
    fire()
    H.assertNil(state.route.untracked)
    H.assertTrue(state.waypoint)
end

function tests.trackingTheRouteClearsTheQuest()
    local state = { route = {}, quest = 1234 }
    local GPS = Load(state)
    GPS.ClearQuestSuperTrack()
    H.assertEq(state.quest, 0, "the quest's super-track cleared")
end

local pass, fail, failures = H.runSuite("GPSSuperTrack", tests)
return { pass = pass, fail = fail, failures = failures }
