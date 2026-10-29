-- Tests for ns.GetDungeonEntrancesForMap (Shared/MapUtils.lua) on WoW
-- Forever: the generated entrance table (Database/Instances_Forever.lua)
-- answers in the encounter journal's shape, by zone and by continent.
local H = require("Harness")

local function fresh(forever)
    local env = H.newEnv()
    local ns = H.newNs(env)
    ns.Caps = { forever = forever, instanceTable = forever }
    env.GetRealZoneText = function(id) return id == 36 and "Die Todesminen" or "" end
    env.C_EncounterJournal = { GetDungeonEntrancesForMap = function(m) return { { name = "journal " .. m } } end }
    H.loadModule("Shared/MapUtils.lua", env, ns)
    H.loadModule("Database/Instances_Forever.lua", env, ns)
    return ns
end

local tests = {}

function tests.zoneMap_listsItsEntrances()
    local ns = fresh(true)
    local list = ns.GetDungeonEntrancesForMap(1436)   -- Westfall
    H.assertEq(#list, 1)
    H.assertEq(list[1].name, "Die Todesminen", "the client's own name for the instance")
    H.assertFalse(list[1].isRaid)
    H.assertTrue(list[1].position.x > 0 and list[1].position.x < 1)
    H.assertEq(list[1].zoneMapID, 1436)
end

function tests.continentMap_listsEachInstanceOnce()
    local ns = fresh(true)
    local list = ns.GetDungeonEntrancesForMap(1415)   -- Eastern Kingdoms
    local seen = {}
    for i = 1, #list do
        local id = list[i].instanceMapID
        H.assertNil(seen[id], "Blackrock Mountain's instances sit in two zones but once on the continent: " .. tostring(id))
        seen[id] = true
        H.assertTrue(list[i].position.x >= 0 and list[i].position.x <= 1)
    end
    H.assertTrue(seen[409] and seen[36] and seen[533], "Molten Core, Deadmines and Naxxramas are on it")
    H.assertNil(seen[43], "Wailing Caverns is in Kalimdor")
end

function tests.raids_areRaids()
    local ns = fresh(true)
    local list = ns.GetDungeonEntrancesForMap(1445)   -- Dustwallow Marsh
    H.assertEq(list[1].instanceMapID, 249)
    H.assertTrue(list[1].isRaid, "Onyxia's Lair")
    H.assertEq(list[1].name, "Onyxia's Lair", "English when the client has no name")
end

function tests.retail_asksTheJournal()
    local ns = fresh(false)
    local list = ns.GetDungeonEntrancesForMap(1436)
    H.assertEq(list[1].name, "journal 1436")
end

-- Classic Era and TBC Anniversary ship their entrances too: the map search
-- and the instance rows answered nothing there (2026-10-28).
function tests.era_andTbc_answerFromTheirOwnTables()
    for file, cap in pairs({ ["Database/Instances_Era.lua"] = "era", ["Database/Instances_TBC.lua"] = "tbc" }) do
        local env = H.newEnv()
        local ns = H.newNs(env)
        ns.Caps = { [cap] = true, classic = true, instanceTable = true }
        env.GetRealZoneText = function() return "" end
        env.C_EncounterJournal = { GetDungeonEntrancesForMap = function() return {} end }
        H.loadModule("Shared/MapUtils.lua", env, ns)
        H.loadModule(file, env, ns)
        local list = ns.GetDungeonEntrancesForMap(1436)   -- Westfall
        H.assertEq(#list, 1, file)
        H.assertEq(list[1].name, "Deadmines", file)
    end
end

local pass, fail, failures = H.runSuite("ForeverInstances", tests)
return { pass = pass, fail = fail, failures = failures }
