-- Apps/GPS/Buildings.lua against the shipped retail data: the Wizard's
-- Sanctum outline holds every portal and landing in its hall and none of
-- the Mage Tower around it (/efd wayin trails, 2026-10-26), so a rebuilt
-- Data.lua that moves a spot out of it fails here, not on the street.
local H = require("Harness")

local function Load()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    ns.Caps = { forever = false }
    env.C_Map = { GetMapInfo = function() return { name = "?" } end }
    H.loadModule("Apps/GPS/Data.lua", env, ns)
    H.loadModule("Apps/GPS/Buildings.lua", env, ns)
    H.loadModule("Apps/GPS/Route.lua", env, ns)
    return ns
end

local SANCTUM = 10523
-- Every crossing spot on Stormwind's map within this of the hall's middle.
local HALL_MIDDLE, HALL_REACH = { -9045, 940 }, 110

local tests = {}

function tests.everyHallCrossingIsInside()
    local ns = Load()
    local out, n = {}, 0
    for _, e in ipairs(ns.GPSData.edges) do
        if e.kind ~= "enter" and e.kind ~= "leave" then
            for _, p in ipairs({ e.from, e.to }) do
                if p and p.m == 84 and p.wx and math.sqrt((p.wx - HALL_MIDDLE[1]) ^ 2 + (p.wy - HALL_MIDDLE[2]) ^ 2) < HALL_REACH then
                    n = n + 1
                    if not ns.GPSRoute.InHall(SANCTUM, 0, p.wx, p.wy) then out[#out + 1] = (e.n or "?") .. " " .. p.wx .. "," .. p.wy end
                end
            end
        end
    end
    H.assertTrue(n >= 15, "the hall's portals were found: " .. n)
    H.assertEq(table.concat(out, "; "), "", "crossing spots outside the outline")
end

function tests.theTowerAndItsStairsAreOutside()
    local ns = Load()
    local InHall = ns.GPSRoute.InHall
    for _, p in ipairs({
        { -9017.4, 864.9 },     -- the stairs' foot
        { -9001.0, 865.4 },     -- the tower's entrance
        { -9008.0, 872.0 },     -- its inner stairs
        { -9016.8, 876.4 },     -- the teleport up
        { -9003.6, 869.0 },     -- where it lands
        { -8999.3, 863.0 },     -- the teleport out
    }) do
        H.assertFalse(InHall(SANCTUM, 0, p[1], p[2]), "outside: " .. p[1] .. "," .. p[2])
    end
    H.assertTrue(InHall(SANCTUM, 0, -9030.1, 903.3), "the hall's mouth, where entering ends")
    H.assertFalse(InHall(SANCTUM, 1, -9030.1, 903.3), "only on its own continent")
end

function tests.enterAndLeaveJoinTheStairsAndTheHall()
    local ns = Load()
    local kinds = {}
    for _, e in ipairs(ns.GPSData.edges) do
        if e.kind == "enter" or e.kind == "leave" then
            kinds[e.kind] = e
            H.assertEq(e.area, SANCTUM)
            H.assertEq(e.faction, "Alliance")
        end
    end
    H.assertTrue(kinds.enter and kinds.leave, "both ways")
    H.assertFalse(ns.GPSRoute.InHall(SANCTUM, 0, kinds.enter.from.wx, kinds.enter.from.wy), "entering starts outside")
    H.assertTrue(ns.GPSRoute.InHall(SANCTUM, 0, kinds.enter.to.wx, kinds.enter.to.wy), "and ends inside")
end

local pass, fail, failures = H.runSuite("GPSBuildings", tests)
return { pass = pass, fail = fail, failures = failures }
