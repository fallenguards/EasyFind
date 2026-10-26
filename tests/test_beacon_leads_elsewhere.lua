-- Stormwind's Wizard's Sanctum (2026-10-26, /efd navpin): no map of its
-- own, so the portal's waypoint sat on the city map, read as the ground
-- outside, and the game's marker (with the beacon on it) led out through
-- the way out: 57 yards against a straight 30.9. Indoors, a marker that far
-- past the straight way hides, beacon and all.
local H = require("Harness")

local function Load(world)
    local fh = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/WorldPin.lua", "rb"))
    local src = fh:read("*a")
    fh:close()
    local s = assert(src:find("local RISE, OVER, SETTLE", 1, true), "the constants")
    local e = select(2, assert(src:find("WorldPin.MarkerLeadsElsewhere = MarkerLeadsElsewhere", s, true)))
    local env = setmetatable({
        WorldPin = {},
        ns = { GPS = { PlayerWorldPos = function() return 0, world.px, world.py end } },
        IsIndoors = function() return world.indoors end,
        C_Navigation = { GetDistance = function() return world.game end },
        C_Map = {
            GetUserWaypoint = function() return { uiMapID = 84, position = {} } end,
            GetWorldPosFromMapPos = function()
                return 0, { GetXY = function() return world.tx, world.ty end }
            end,
        },
    }, { __index = _G })
    assert(load(src:sub(s, e), "=WorldPin.lua", "t", env))()
    return env.WorldPin.MarkerLeadsElsewhere
end

-- The probe's numbers: the player at world -9043.3, 912.3, the portal's
-- spot at -9062, 888 (30.9 yards), the game's marker 57 yards.
local function Sanctum() return { indoors = true, px = -9043.3, py = 912.3, tx = -9062, ty = 888, game = 57.02 } end

local tests = {}

function tests.theSanctumsWayOutIsHidden()
    local world = Sanctum()
    H.assertTrue(Load(world)({}), "57 against 30.9 indoors")
end

function tests.outdoorsTheMarkerStays()
    local world = Sanctum()
    world.indoors = false
    H.assertFalse(Load(world)({}), "outdoors the game's way is the way")
end

function tests.aFloorUpOrDownStays()
    local world = Sanctum()
    world.game = 40
    H.assertFalse(Load(world)({}), "a spot a floor away reads a little long")
end

function tests.itComesBackOnlyWellUnder()
    local world = Sanctum()
    local Leads = Load(world)
    local step = {}
    H.assertTrue(Leads(step))
    world.game = 45
    H.assertTrue(Leads(step), "just under the limit it stays hidden")
    world.game = 35
    H.assertFalse(Leads(step), "well under, it shows again")
end

local pass, fail, failures = H.runSuite("BeaconLeadsElsewhere", tests)
return { pass = pass, fail = fail, failures = failures }
