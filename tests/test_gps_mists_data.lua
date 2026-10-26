-- MoP Classic's GPS data (Apps/GPS/Data_Mists.lua) reaches every continent
-- for both sides: it once had no way onto Pandaria, so a route there from
-- Stormwind found nothing (2026-10-26).
local H = require("Harness")

local function Load()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    ns.Caps = { mists = true }
    H.loadModule("Apps/GPS/Data_Mists.lua", env, ns)
    return assert(ns.GPSData, "Data_Mists.lua sets ns.GPSData")
end

local tests = {}

function tests.eachSide_hasAWayOntoEveryContinent()
    local data = Load()
    for _, side in ipairs({ "Alliance", "Horde" }) do
        local reach = {}
        for _, e in ipairs(data.edges) do
            if (not e.faction or e.faction == side) and e.from.ci ~= e.to.ci then reach[e.to.ci] = true end
        end
        for _, ci in ipairs({ 0, 1, 530, 571, 870 }) do
            H.assertTrue(reach[ci], side .. " has a way onto continent " .. ci)
        end
    end
end

function tests.theJadeForestPortals_openAfterTheIntro()
    local data = Load()
    local gates = {}
    for _, e in ipairs(data.edges) do
        if e.to.ci == 870 and (e.from.ci == 0 or e.from.ci == 1) and e.kind == "portal" then
            gates[e.faction] = e.req and e.req.quest
        end
    end
    H.assertEq(gates.Alliance, 31733, "Stormwind's, after Touching Ground")
    H.assertEq(gates.Horde, 31766, "Orgrimmar's, after Touching Ground")
end

local pass, fail, failures = H.runSuite("GPSMistsData", tests)
return { pass = pass, fail = fail, failures = failures }
