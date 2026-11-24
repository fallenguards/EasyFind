-- A quest's item rewards as a page in the bar, as a boss's loot (Search/
-- QuestRewards.lua; asked for 2026-11-25): the item sources data's quest
-- rewards ("q" in an item's line) read the other way.
local H = require("Harness")

local ITEMS = {
    [2575] = "q101,102",                 -- a shirt, rewarded by two quests
    [6070] = "d1001:5;q101",             -- a dagger, dropped too
    [118] = "c1;q102+3",                 -- a potion, made too, "+3" more quests
    [9000] = "d5:1",                     -- rewarded by none
}
local NAMES = { [2575] = "Red Linen Shirt", [6070] = "Wolfrunner Shoes", [118] = "Minor Healing Potion" }
local INSTANT = { [2575] = { "Armor", "Miscellaneous", "INVTYPE_BODY" }, [6070] = { "Armor", "Leather", "INVTYPE_FEET" },
                  [118] = { "Consumable", "Potion", "" } }

local function Sources()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind = { _ns = ns }
    ns.BUILD = "5.7.0"
    ns.SOURCE_DATA = { items = ITEMS, quests = {} }
    H.loadModule("Apps/Sources/Sources.lua", env, ns)
    return ns.SourceData
end

local function Page(data)
    local env = H.newEnv()
    env.C_Item = {
        GetItemNameByID = function(id) return NAMES[id] end,
        GetItemQualityByID = function() return 2 end,
        GetItemInfoInstant = function(id) local i = INSTANT[id] return id, i[1], i[2], i[3] end,
        RequestLoadItemDataByID = function() end,
    }
    env.INVTYPE_BODY, env.INVTYPE_FEET, env.QUEST_REWARDS, env.NONE = "Shirt", "Feet", "Rewards", "None"
    env._G = env
    local ns = H.newNs(env)
    local shown = {}
    ns.RequestSourceData = function() return true end
    ns.SourceData = data
    ns.Filters.ApplyQuickFilter = function(_, def, text) shown.def, shown.text = def, text end
    ns.Filters.GetQuickFilter = function() return shown.def end
    ns.Results.ShowHierarchicalResults = function(_, entries) shown.entries = entries end
    H.loadModule("Search/QuestRewards.lua", env, ns)
    return ns.QuestRewards, shown
end

local function Lines(entries)
    local out = {}
    for i, e in ipairs(entries) do
        out[i] = e.isSectionHeader and ("# " .. e.name) or (e.name .. " | " .. tostring(e.data.sourceNote))
    end
    return table.concat(out, "\n")
end

local tests = {}

function tests.aQuestsRewards_areTheItemLinesReadTheOtherWay()
    local data = Sources()
    H.assertEq(table.concat(data.QuestRewards(101), ","), "2575,6070")
    H.assertEq(table.concat(data.QuestRewards(102), ","), "118,2575", "a line's +n more left out, the rest read")
    H.assertNil(data.QuestRewards(5), "a quest rewarding nothing")
end

function tests.thePage_listsEachReward_withItsSlotAndKind()
    local Rewards, shown = Page(Sources())
    Rewards:Show(101, "Dangerous!")
    H.assertEq(shown.def.token, "@Dangerous!", "its pill names the quest")
    Rewards:ShowView(shown.def, "")
    H.assertEq(Lines(shown.entries), "# Rewards\nRed Linen Shirt | Shirt, Miscellaneous\nWolfrunner Shoes | Feet, Leather")
    H.assertTrue(shown.entries[2].data.catalogItem == true, "an item row: a click opens its sources page")
    Rewards:ShowView(shown.def, "feet")
    H.assertEq(Lines(shown.entries), "# Rewards\nWolfrunner Shoes | Feet, Leather", "typing narrows by name or kind")
end

function tests.aQuestWithNoItemRewards_saysSo()
    local Rewards, shown = Page(Sources())
    Rewards:Show(5, "Errand")
    Rewards:ShowView(shown.def, "")
    H.assertEq(Lines(shown.entries), "# Rewards: None")
end

function tests.thePage_isWired()
    local function Read(rel)
        local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
        local src = f:read("*a"):gsub("\r\n", "\n")
        f:close()
        return src
    end
    H.assertTrue(Read("Search/Query.lua"):find("if ns.QuestRewards then ns.QuestRewards:ShowView(quickFilter, text) end", 1, true) ~= nil)
    H.assertTrue(Read("Core/API.lua"):find("ns.QuestRewards:Show(questID, title)", 1, true) ~= nil)
    H.assertTrue(Read("EasyFind.toc"):find("Search/QuestRewards.lua\n", 1, true) ~= nil)
    H.assertTrue(Read("API/README.md"):find("| `ShowQuestRewards(questID, title)` |", 1, true) ~= nil, "documented")
end

local pass, fail, failures = H.runSuite("QuestRewards", tests)
return { pass = pass, fail = fail, failures = failures }
