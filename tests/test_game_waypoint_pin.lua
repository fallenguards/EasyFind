-- The game's waypoint pin under EasyFind's (MapSearch/Navigation.lua
-- SyncGameWaypointPin): where EasyFind placed the waypoint and its own pin
-- marks the spot, the game's goes (alpha and mouse off) so the two never
-- stack; anywhere else, or once the waypoint is the player's, it is back.
local H = require("Harness")

local function Pin(x, y, shown)
    return {
        x = x, y = y, shown = shown ~= false, alpha = 1, mouse = true,
        GetCenter = function(self) return self.x, self.y end,
        GetEffectiveScale = function() return 1 end,
        IsVisible = function(self) return self.shown end,
        SetAlpha = function(self, a) self.alpha = a end,
        EnableMouse = function(self, on) self.mouse = on end,
    }
end

local function Load(state)
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/Navigation.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local hiddenGamePins", 1, true), "SyncGameWaypointPin's start")
    local e = select(2, assert(src:find("MapSearch.SyncGameWaypointPin = SyncGameWaypointPin", s, true)))
    local env = setmetatable({
        MapSearch = {},
        WorldMapFrame = { EnumeratePinsByTemplate = function()
            local i = 0
            return function() i = i + 1 return state.gamePins[i] end
        end },
    }, { __index = function(_, k) if state[k] ~= nil then return state[k] end return _G[k] end })
    -- The file's own locals the function reads come from the state, live.
    local chunk = src:sub(s, e) .. "\nreturn SyncGameWaypointPin"
    return assert(load(chunk, "=Navigation.lua SyncGameWaypointPin", "t", env))()
end

local tests = {}

function tests.oursOverTheGamesHidesTheGames()
    local game = Pin(100, 200)
    local state = { efPlacedWaypoint = true, waypointPin = Pin(104, 196), gamePins = { game } }
    Load(state)()
    H.assertEq(game.alpha, 0, "one marker on the spot: ours")
    H.assertFalse(game.mouse, "ours takes the clicks")
end

function tests.aStepEndAwayFromOursKeepsTheGames()
    local game = Pin(100, 200)
    local state = { efPlacedWaypoint = true, waypointPin = Pin(300, 50), gamePins = { game } }
    Load(state)()
    H.assertEq(game.alpha, 1)
    H.assertTrue(game.mouse)
end

function tests.thePlayersOwnWaypointComesBack()
    local game = Pin(100, 200)
    local state = { efPlacedWaypoint = true, waypointPin = Pin(100, 200), gamePins = { game } }
    local sync = Load(state)
    sync()
    H.assertEq(game.alpha, 0)
    state.efPlacedWaypoint = false   -- the player set their own
    sync()
    H.assertEq(game.alpha, 1, "shown again")
    H.assertTrue(game.mouse)
end

-- A slice of Navigation.lua from a marker to another, its file locals read
-- from the state, live.
local function Slice(from, to, name, state)
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/Navigation.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find(from, 1, true), from)
    local _, e = src:find(to, s, true)
    assert(e, to)
    local env = setmetatable({ MapSearch = state.MapSearch or {} },
        { __index = function(_, k) if state[k] ~= nil then return state[k] end return _G[k] end })
    return assert(load(src:sub(s, e) .. "\nreturn " .. name, "=Navigation.lua " .. name, "t", env))()
end

local function Waypoint(state, mapID, x, y)
    state.C_Map = { GetUserWaypoint = function()
        return mapID and { uiMapID = mapID, position = { x = x, y = y } } or nil
    end }
end

-- A CurseForge player had to clear the game's waypoint after EasyFind's
-- pin (2026-11-16): any waypoint update (a super-track) dropped the
-- ownership, so the pin's right-click left the game's behind.
function tests.anUpdateLeavingItInPlace_keepsItOurs()
    local state = { efPoint = { 1453, 0.5, 0.6 } }
    Waypoint(state, 1453, 0.5, 0.6)
    local StillOurs = Slice("local function StillOurs()", "MapSearch._StillOurs = StillOurs", "StillOurs", state)
    H.assertTrue(StillOurs(), "same spot: ours")
    Waypoint(state, 1453, 0.7, 0.6)
    H.assertFalse(StillOurs(), "moved by the player: theirs")
    Waypoint(state, nil)
    H.assertFalse(StillOurs(), "gone")
    state.efPoint = nil
    Waypoint(state, 1453, 0.5, 0.6)
    H.assertFalse(StillOurs(), "never placed by us")
end

function tests.theWaypointCleared_takesOurPinOnlyOnItsSpot()
    local state = { activePinState = { mapID = 1453, x = 0.5, y = 0.6 } }
    local PinMarks = Slice("local function PinMarks(point)", "\nend\n", "PinMarks", state)
    H.assertTrue(PinMarks({ 1453, 0.5004, 0.6 }), "our pin's spot")
    H.assertFalse(PinMarks({ 1453, 0.2, 0.3 }), "a GPS step's waypoint elsewhere leaves the pin")
    H.assertFalse(PinMarks({ 1454, 0.5, 0.6 }), "another map")
    state.activePinState = { mapID = 1453, instances = { { x = 0.1, y = 0.1 }, { x = 0.5, y = 0.6 } } }
    H.assertTrue(PinMarks({ 1453, 0.5, 0.6 }), "one of a cluster")
    local src = assert(io.open(H.ADDON_ROOT .. "/MapSearch/Navigation.lua", "rb")):read("*a")
    H.assertTrue(src:find("if gone and PinMarks(gone) then MapSearch:ClearAll() end", 1, true) ~= nil,
        "the event handler clears our pin with it")
    H.assertTrue(src:find('event == "USER_WAYPOINT_UPDATED" and not efSettingWaypoint and not StillOurs()', 1, true) ~= nil,
        "an update leaving it in place keeps it ours")
end

-- The option's one spot: an entrance, a cluster's nearest, the result's own.
function tests.waypointOnly_picksOneSpot()
    local state = { WorldMapFrame = { GetMapID = function() return 1453 end } }
    state.MapSearch = {
        SpotsOnMap = function(spots) return spots end,
        GetNearestInstance = function(_, spots) return spots[2] end,
    }
    local Spot = Slice("local function WaypointSpot(data)", "MapSearch._WaypointSpot = WaypointSpot", "WaypointSpot", state)
    local m, x, y = Spot({ isDungeonEntrance = true, entranceMapID = 1413, entranceX = 0.2, entranceY = 0.3 })
    H.assertEq(m .. " " .. x .. " " .. y, "1413 0.2 0.3")
    m, x = Spot({ allInstances = { { x = 0.1, y = 0.1 }, { x = 0.4, y = 0.4 } } })
    H.assertEq(m .. " " .. x, "1453 0.4", "the nearest on the viewed map")
    m, x = Spot({ x = 0.6, y = 0.7, coordMapID = 1454 })
    H.assertEq(m .. " " .. x, "1454 0.6", "a spot on another map, on its map")
    H.assertNil(Spot({ isZone = true, zoneMapID = 1440 }), "a zone has no spot")
end

local pass, fail, failures = H.runSuite("GameWaypointPin", tests)
return { pass = pass, fail = fail, failures = failures }
