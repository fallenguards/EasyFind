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

local pass, fail, failures = H.runSuite("GameWaypointPin", tests)
return { pass = pass, fail = fail, failures = failures }
