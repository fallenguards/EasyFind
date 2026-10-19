-- Tests for Apps/Notes/Context.lua: where a note applies, on each client.

local H = require("Harness")

-- A world: Westfall (1436) under Eastern Kingdoms (1415) under Azeroth (947),
-- and the Deadmines (36) as the instance the player stands in.
local MAPS = {
    [947] = { mapID = 947, name = "Azeroth", mapType = 1, parentMapID = 946 },
    [1415] = { mapID = 1415, name = "Eastern Kingdoms", mapType = 2, parentMapID = 947 },
    [1436] = { mapID = 1436, name = "Westfall", mapType = 3, parentMapID = 1415 },
    [1453] = { mapID = 1453, name = "Stormwind City", mapType = 3, parentMapID = 1415 },
}

local function Load(opts)
    opts = opts or {}
    local env = H.newEnv()
    env._G = env
    env.Enum = { UIMapType = { Cosmic = 0, World = 1, Continent = 2, Zone = 3, Dungeon = 4, Micro = 5 } }
    env.C_Map = {
        GetBestMapForUnit = function() return opts.map or 1436 end,
        GetMapInfo = function(m) return MAPS[m] end,
        GetMapChildrenInfo = function(m)
            if m ~= 946 then return {} end
            return { MAPS[947], MAPS[1415], MAPS[1436], MAPS[1453] }
        end,
    }
    env.IsInInstance = function() return opts.instance ~= nil end
    env.GetInstanceInfo = function() return "The Deadmines", "party", 1, "", 5, 0, false, opts.instance end
    env.UnitClass = function() return "Mage", "MAGE", 8 end
    env.UnitFactionGroup = function() return "Alliance", "Alliance" end
    env.GetNumClasses = function() return 11 end
    local classes = { [1] = { "Warrior", "WARRIOR" }, [8] = { "Mage", "MAGE" }, [11] = { "Druid", "DRUID" } }
    env.GetClassInfo = function(id) local c = classes[id] if c then return c[1], c[2], id end end
    env.IsInRaid = function() return false end
    env.IsInGroup = function() return opts.party ~= nil end
    env.UnitExists = function(u)
        return (u == "target" and (opts.target or opts.npc)) or (u == "party1" and opts.party) or false
    end
    env.UnitIsPlayer = function(u) return not (u == "target" and opts.npc) end
    env.UnitIsUnit = function(a, b) return a == b end
    env.UnitGUID = function(u)
        return u == "target" and opts.npc and ("Creature-0-4234-0-1234-" .. opts.npc .. "-000012345") or nil
    end
    env.UnitName = function(u) return u == "target" and opts.npc and "Defias Pillager" or nil end
    env.GetUnitName = function(u, withRealm)
        local name = (u == "target" and opts.target) or (u == "party1" and opts.party)
        if not withRealm then return (name:gsub("%-.*", "")) end
        return name
    end
    env.GetNormalizedRealmName = function() return "Stormrage" end
    env.GetRealmName = function() return "Stormrage" end
    env.GetRealZoneText = function(id) return id == 36 and "The Deadmines" or "" end
    env.GetSpecialization = function() return 1 end
    env.GetSpecializationInfo = function() return 62, "Arcane", "", 0, "DAMAGER" end
    env.DAMAGER, env.TANK, env.HEALER = "Damage", "Tank", "Healer"
    env.C_ChallengeMode = { IsChallengeModeActive = function() return true end }
    env.InCombatLockdown = function() return opts.combat == true end
    env.IsResting = function() return opts.resting == true end
    env._frames = {}
    env.CreateFrame = function()
        local f = { RegisterEvent = function() end }
        f.SetScript = function(self, _, fn) self.onEvent = fn end
        env._frames[#env._frames + 1] = f
        return f
    end
    local ns = H.newNs(env)
    ns.Caps = { forever = opts.forever, retail = not opts.forever, specs = not opts.forever }
    ns.PlayerName = function() return opts.forever and "Ana Brightwood" or "Ana" end
    ns.CurrentCharacterKey = function() return ns.PlayerName() .. "-Stormrage" end
    ns.FOREVER_INSTANCES = { { id = 36, n = "Deadmines", raid = false }, { id = 409, n = "Molten Core", raid = true } }
    H.loadModule("Shared/MapUtils.lua", env, ns)
    H.loadModule("Search/NoteMenus.lua", env, ns)
    local notesNS = {}
    local chunk = assert(loadfile(H.ADDON_ROOT .. "/Apps/Notes/Context.lua", "t", env))
    env.EasyFind = { _ns = ns }
    chunk("EasyFind_Notes", notesNS)
    -- The game's events, as the watcher hears them.
    local function fire(event, arg)
        for _, f in ipairs(env._frames) do
            if f.onEvent then f.onEvent(f, event, arg) end
        end
    end
    return notesNS.Context, ns, fire
end

local function has(set, key) return set[key] == true end

local tests = {}

function tests.zones_matchFromInsideTheirSubMaps()
    local Ctx = Load()
    local _, set = Ctx.Active()
    H.assertTrue(has(set, "map:1436"), "the zone you stand in")
    H.assertTrue(has(set, "map:1415"), "its continent too")
    H.assertFalse(has(set, "map:947"), "never the world map")
    H.assertFalse(has(set, "map:1453"), "not a zone you are not in")
end

function tests.instances_matchByTheirID_olderTagsToo()
    local Ctx = Load({ instance = 36 })
    local _, set = Ctx.Active()
    H.assertTrue(has(set, "dungeon:36"))
    H.assertTrue(has(set, "instance:36"), "a tag made before dungeons had their own kind")
end

function tests.classAndFaction_areActive()
    local _, set = Load().Active()
    H.assertTrue(has(set, "class:MAGE"))
    H.assertTrue(has(set, "faction:Alliance"))
    H.assertTrue(has(set, "group:solo"))
end

function tests.retailOnlyKinds_stayOffOnForever()
    local _, set = Load({ forever = true }).Active()
    H.assertFalse(has(set, "spec:62"))
    H.assertFalse(has(set, "role:DAMAGER"))
    H.assertFalse(has(set, "mythicplus:mplus"))
    local _, retail = Load().Active()
    H.assertTrue(has(retail, "spec:62"))
    H.assertTrue(has(retail, "mythicplus:mplus"))
end

function tests.options_areWhatThisClientHas()
    local function keys(Ctx)
        local out = {}
        for _, e in ipairs(Ctx.Options()) do out[Ctx.Key(e)] = true end
        return out
    end
    local forever = keys(Load({ forever = true }))
    H.assertTrue(forever["class:WARRIOR"] and forever["class:DRUID"], "every class the client defines")
    H.assertTrue(forever["dungeon:36"] and forever["raid:409"], "Forever's instances")
    H.assertTrue(forever["map:1453"], "zones you are not in")
    H.assertTrue(forever["map:1415"], "continents")
    H.assertFalse(forever["mythicplus:mplus"])
    H.assertFalse(forever["uistate:greatvault"])
    H.assertFalse(forever["role:TANK"])
    local retail = keys(Load())
    H.assertTrue(retail["uistate:greatvault"] and retail["role:TANK"] and retail["warmode:warmode"] ~= nil)
end

function tests.comesUp_byAnyCondition_orAllOfARule()
    local Ctx = Load()
    local _, set = Ctx.Active()
    local westfall, mage, raid = { type = "map", id = 1436 }, { type = "class", id = "MAGE" }, { type = "raid", id = 409 }
    H.assertTrue(Ctx.Applies({ appliesIn = { westfall, raid } }, set), "any one of its own conditions")
    H.assertFalse(Ctx.Applies({ rules = { { conds = { westfall, raid } } } }, set), "a rule needs every condition")
    H.assertTrue(Ctx.Applies({ rules = { { conds = { westfall, mage } } } }, set))
    H.assertFalse(Ctx.Applies({ appliesIn = {} }, set), "nothing set, nothing to come up")
end

function tests.activities_aDuelItsOpponentTargetCombatResting()
    local Ctx, _, fire = Load({ target = "Bren Oakhart-Stormrage", combat = true, resting = true })
    local _, set = Ctx.Active()
    H.assertTrue(has(set, "targetclass:MAGE"), "the target's class, apart from mine")
    H.assertTrue(has(set, "combat:combat"))
    H.assertTrue(has(set, "resting:resting"))
    H.assertFalse(has(set, "duel:duel"), "no duel yet")
    fire("DUEL_REQUESTED", "Bren")
    _, set = Ctx.Active()
    H.assertTrue(has(set, "duel:duel"), "challenged: in a duel")
    H.assertTrue(has(set, "duelclass:MAGE"), "the challenger is the target, a mage")
    local druids = { rules = { { conds = { { type = "duel", id = "duel" }, { type = "duelclass", id = "DRUID" } } } } }
    H.assertFalse(Ctx.Applies(druids, set), "a druid-duel note waits for a druid")
    fire("DUEL_FINISHED")
    _, set = Ctx.Active()
    H.assertFalse(has(set, "duel:duel"), "over")
end

function tests.players_oneKeyFromMenusAndUnits()
    local Ctx, ns = Load({ forever = true, target = "Bren Oakhart-Stormrage", party = "Cass" })
    H.assertEq(ns.NotesPlayerKey("Bren"), "Bren-Stormrage")
    H.assertEq(ns.NotesPlayerKey("Bren Oakhart"), "Bren-Stormrage", "a Forever surname is left out")
    H.assertEq(ns.NotesPlayerKey("Bren-Stormrage"), "Bren-Stormrage")
    H.assertEq(ns.NotesPlayerKey("Dax", "Area 52"), "Dax-Area52")
    H.assertEq((Ctx.UnitPlayer("target")), "Bren-Stormrage", "the tooltip's key for a unit, the menus' key")
    local _, set = Ctx.Active()
    H.assertTrue(has(set, "player:Bren-Stormrage"), "the target")
    H.assertTrue(has(set, "player:Cass-Stormrage"), "a party member")
    local cass = { { type = "player", id = "Cass-Stormrage" } }
    H.assertTrue(Ctx.Applies({ appliesIn = cass }, set), "a party member as a condition")
    H.assertFalse(Ctx.Applies({ appliesIn = {}, showsOn = cass }, set), "a tooltip it rides brings nothing up")
end

function tests.npcs_areUnitsToo_andAPresentUnitAppliesItsNote()
    local Ctx, ns = Load({ npc = 5678 })
    local entry = ns.NotesUnitEntry("target")
    H.assertEq(entry.type, "npc")
    H.assertEq(entry.id, 5678)
    H.assertEq(entry.name, "Defias Pillager")
    local _, set = Ctx.Active()
    H.assertTrue(has(set, "npc:5678"), "the targeted creature by its id")
    local here = { { type = "npc", id = 5678 } }
    H.assertTrue(Ctx.Applies({ appliesIn = here }, set), "the target as a condition")
    H.assertFalse(Ctx.Applies({ appliesIn = { { type = "npc", id = 99 } } }, set), "another creature")
    H.assertFalse(Ctx.Applies({ showsOn = here }, set), "its tooltip alone brings nothing up")
end

function tests.search_ranksWordStartsFirst()
    local Ctx = Load()
    local a = Ctx.MatchScore({ type = "map", name = "Westfall" }, "fall")
    local b = Ctx.MatchScore({ type = "map", name = "Fallen Hill" }, "fall")
    H.assertTrue(b > a, "a word start beats a hit inside a word")
    H.assertNil(Ctx.MatchScore({ type = "map", name = "Duskwood" }, "fall"))
end

local pass, fail, failures = H.runSuite("NotesContext", tests)
return { pass = pass, fail = fail, failures = failures }
