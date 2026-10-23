-- Tests for reputations on the classic clients: Era and Anniversary have no
-- C_Reputation list; Shared/Caps.lua reads their GetFactionInfo list in
-- retail's fields, and the reader (Database/Main.lua) builds rows from it.
local H = require("Harness")

-- A classic faction list: rows under a collapsed header are not listed.
local function factionTree()
    return {
        { id = "classic", name = "Classic", isHeader = true, factionID = 1118 },
        { id = "alliance", parent = "classic", name = "Alliance", isHeader = true, isChild = true, factionID = 469 },
        { parent = "alliance", name = "Stormwind", factionID = 72, isChild = true,
          standingID = 5, barMin = 3000, barMax = 9000, barValue = 4500 },
        { parent = "alliance", name = "Ironforge", factionID = 47, isChild = true,
          standingID = 4, barMin = 0, barMax = 3000, barValue = 0 },
        { parent = "classic", name = "Bloodsail Buccaneers", factionID = 87,
          standingID = 1, barMin = -42000, barMax = -6000, barValue = -30000 },
        { id = "other", name = "Other", isHeader = true, factionID = 1169, collapsed = true },
        { parent = "other", name = "Wintersaber Trainers", factionID = 589,
          standingID = 4, barMin = 0, barMax = 3000, barValue = 0 },
    }
end

local function classicEnv(tree)
    local env = H.newEnv()
    env._G = env
    env.C_Reputation = nil
    env.WOW_PROJECT_CLASSIC, env.WOW_PROJECT_ID = 2, 2
    env.GetBuildInfo = function() return "1.15.9", "70003", "", 11509 end
    local byID = {}
    for _, row in ipairs(tree) do if row.id then byID[row.id] = row end end
    local function visible()
        local rows = {}
        for _, row in ipairs(tree) do
            local shown, up = true, row.parent
            while up do
                if byID[up].collapsed then shown = false end
                up = byID[up].parent
            end
            if shown then rows[#rows + 1] = row end
        end
        return rows
    end
    env.GetNumFactions = function() return #visible() end
    env.GetFactionInfo = function(i)
        local r = visible()[i]
        if not r then return nil end
        return r.name, "", r.standingID or 4, r.barMin or 0, r.barMax or 0, r.barValue or 0, false, false,
            r.isHeader or false, r.collapsed or false, false, false, r.isChild or false, r.factionID
    end
    env.ExpandFactionHeader = function(i) visible()[i].collapsed = false end
    env.CollapseFactionHeader = function(i) visible()[i].collapsed = true end
    local ns = H.newNs(env)
    H.loadModule("Shared/Caps.lua", env, ns)
    return env, ns
end

-- The reader alone, sliced from the file, over the classic list.
local function loadReader(env, ns)
    local f = assert(io.open(H.ADDON_ROOT .. "/Database/Main.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function Database:PopulateDynamicReputations()", 1, true), "reader not found")
    local _, e = src:find("\nend\r?\n", s)
    assert(e, "end of the reader not found")
    local data, Database = {}, {}
    local readerEnv = setmetatable({
        Database = Database, uiSearchData = data, ns = ns, slower = string.lower,
        RemoveEntriesByCategory = function(cat)
            for i = #data, 1, -1 do if data[i].category == cat then table.remove(data, i) end end
        end,
        Utils = { SliceCheckpoint = function() end, DebugPrint = function() end },
    }, { __index = env })
    assert(load(src:sub(s, e), "=Main.lua PopulateDynamicReputations", "t", readerEnv))()
    return Database, data
end

local tests = {}

function tests.classicListReadsInRetailFields()
    local tree = factionTree()
    local _, ns = classicEnv(tree)
    local Caps = ns.Caps
    H.assertEq(Caps.NumFactions(), 6, "the collapsed header's row is not listed")
    local stormwind = Caps.FactionAt(3)
    H.assertEq(stormwind.name, "Stormwind")
    H.assertEq(stormwind.factionID, 72)
    H.assertEq(stormwind.reaction, 5)
    H.assertEq(stormwind.currentStanding, 4500)
    H.assertEq(stormwind.currentReactionThreshold, 3000)
    H.assertEq(stormwind.nextReactionThreshold, 9000)
    H.assertFalse(Caps.FactionAt(6).isHeaderExpanded, "Other is collapsed")
    H.assertEq(Caps.FactionByID(72).name, "Stormwind", "found by id in the list")
    H.assertEq(Caps.FactionByID(589), nil, "under a collapsed header with no id lookup")
    Caps.SetFactionHeaderExpanded(6, true)
    H.assertFalse(tree[6].collapsed, "expanded through the classic call")
    H.assertEq(Caps.NumFactions(), 7)
end

function tests.retailPassesThrough()
    local env, ns = classicEnv(factionTree())
    local row = { name = "Retail", factionID = 2600 }
    env.C_Reputation = {
        GetNumFactions = function() return 1 end,
        GetFactionDataByIndex = function() return row end,
        GetFactionDataByID = function() return row end,
    }
    H.assertEq(ns.Caps.NumFactions(), 1)
    H.assertEq(ns.Caps.FactionAt(1), row)
    H.assertEq(ns.Caps.FactionByID(2600), row)
end

function tests.readerListsEveryClassicFaction()
    local tree = factionTree()
    local env, ns = classicEnv(tree)
    local Database, data = loadReader(env, ns)
    H.assertTrue(Database:PopulateDynamicReputations(), "read without C_Reputation")
    local byName = {}
    for _, entry in ipairs(data) do byName[entry.name] = entry end
    H.assertTrue(byName.Ironforge ~= nil, "Neutral at 0 is listed")
    H.assertTrue(byName["Bloodsail Buccaneers"] ~= nil, "Hated is listed")
    H.assertTrue(byName["Wintersaber Trainers"] ~= nil, "under a header the reader opened")
    H.assertEq(byName.Stormwind.factionSide, "alliance")
    H.assertEq(byName.Stormwind.category, "Reputation")
    local steps = byName["Wintersaber Trainers"].steps
    H.assertEq(steps[2].tabIndex, 2, "the reputation tab")
    H.assertEq(steps[3].factionHeader, "Other")
    H.assertEq(steps[#steps].factionID, 589)
    H.assertTrue(tree[6].collapsed, "the header it opened is closed again")
    H.assertFalse(tree[1].collapsed == true, "the player's open header stays open")
end

local pass, fail, failures = H.runSuite("ClassicReputations", tests)
return { pass = pass, fail = fail, failures = failures }
