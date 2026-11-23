-- A recipe's mats as a page in the bar (Search/RecipeMats.lua), as a boss's
-- loot is: Shift on a recipe row (a player asked to see what an enchant or
-- a campfire dish needs, 2026-11-23). The game's recipe data hands any
-- recipe's reagents with the profession closed, known or not, enchants too.
local H = require("Harness")

local NAMES = { [1251] = "Linen Bandage", [2589] = "Linen Cloth", [10940] = "Strange Dust",
                [10938] = "Lesser Magic Essence", [5000] = "Optional Thing" }
local HAVE = { [2589] = 28, [10940] = 3, [10941] = 2 }

local SCHEMATICS = {
    -- Linen Bandage: makes one, one Linen Cloth.
    [3275] = { outputItemID = 1251, quantityMin = 1, quantityMax = 1, reagentSlotSchematics = {
        { reagents = { { itemID = 2589 } }, quantityRequired = 1, reagentType = 1, required = true } } },
    -- An enchant: no item; a reagent whose better grade counts too, and an
    -- optional slot that is not the recipe's need.
    [7420] = { outputItemID = nil, reagentSlotSchematics = {
        { reagents = { { itemID = 10940 }, { itemID = 10941 } }, quantityRequired = 2, reagentType = 1, required = true },
        { reagents = { { itemID = 10938 } }, quantityRequired = 1, reagentType = 1, required = true },
        { reagents = { { itemID = 5000 } }, quantityRequired = 1, reagentType = 0, required = false } } },
}

local function Load(L)
    local env = H.newEnv()
    env.C_TradeSkillUI = { GetRecipeSchematic = function(id) return SCHEMATICS[id] end }
    env.C_Item = {
        GetItemNameByID = function(id) return NAMES[id] end,
        GetItemQualityByID = function() return 1 end,
        GetItemCount = function(id, bank) assert(bank == true, "the bank counts") return HAVE[id] or 0 end,
        RequestLoadItemDataByID = function() end,
    }
    local ns = H.newNs(env)
    if L then ns.L = L end
    local shown = {}
    ns.Filters.ApplyQuickFilter = function(_, def, text) shown.def, shown.text = def, text end
    ns.Filters.GetQuickFilter = function() return shown.def end
    ns.Results.ShowHierarchicalResults = function(_, entries) shown.entries = entries end
    H.loadModule("Search/RecipeMats.lua", env, ns)
    return ns.RecipeMats, shown
end

-- The page's lines as "header" or "name | note".
local function Lines(entries)
    local out = {}
    for i, e in ipairs(entries) do
        out[i] = e.isSectionHeader and ("# " .. e.name) or (e.name .. " | " .. tostring(e.data.sourceNote))
    end
    return table.concat(out, "\n")
end

local tests = {}

function tests.aRecipesPage_showsWhatItMakesThenItsReagents()
    local Mats, shown = Load()
    Mats:Show({ name = "Linen Bandage", professionRecipeID = 3275 })
    H.assertEq(shown.def.token, "@Linen Bandage", "its pill names the recipe")
    Mats:ShowView(shown.def, "")
    H.assertEq(Lines(shown.entries),
        "# MATS_MAKES\nLinen Bandage | MATS_MAKES_FMT\n# MATS_REAGENTS\nLinen Cloth | MATS_NEED_HAVE_FMT")
    local cloth = shown.entries[4].data
    H.assertEq(cloth.itemID, 2589)
    H.assertTrue(cloth.catalogItem == true, "an item row: a click opens its sources page")
end

function tests.anEnchant_listsItsReagents_theCountsTheCharacterHas()
    local L = setmetatable({ MATS_NEED_HAVE_FMT = "%d needed, you have %d" }, { __index = function(_, k) return k end })
    local Mats, shown = Load(L)
    Mats:Show({ name = "Enchant Chest - Minor Health", professionRecipeID = 7420 })
    Mats:ShowView(shown.def, "")
    local notes = {}
    for _, e in ipairs(shown.entries) do
        if not e.isSectionHeader then notes[#notes + 1] = e.name .. ": " .. e.data.sourceNote end
    end
    H.assertEq(table.concat(notes, "; "),
        "Strange Dust: 2 needed, you have 5; Lesser Magic Essence: 1 needed, you have 0",
        "no Makes for an enchant; a reagent's better grade counted; the optional slot left out")
end

function tests.typing_narrowsTheRows()
    local Mats, shown = Load()
    Mats:Show({ name = "Enchant Chest - Minor Health", professionRecipeID = 7420 })
    Mats:ShowView(shown.def, "dust")
    H.assertEq(Lines(shown.entries), "# MATS_REAGENTS\nStrange Dust | MATS_NEED_HAVE_FMT")
end

function tests.onlyARecipeRow_withTheGamesRecipeData()
    local Mats = Load()
    H.assertTrue(Mats.Available({ professionRecipeID = 3275 }))
    H.assertFalse(Mats.Available({ name = "Linen Cloth", itemID = 2589 }), "an item row is no recipe")
end

-- Shift on a recipe row opens it, as on a boss its loot; the row's hint says so.
function tests.shift_onARecipeRow_listsItsMats()
    local function Read(rel)
        local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
        local src = f:read("*a")
        f:close()
        return src
    end
    local sel = Read("Search/Results/Handlers/Selection.lua")
    local at = sel:find('if data.professionRecipeID and ns.ResultGestures.Held() == "shift"', 1, true)
    H.assertTrue(at ~= nil, "the gesture")
    H.assertTrue(sel:find("ns.RecipeMats:Show(data)", at, true) ~= nil, "the page")
    H.assertTrue(at < assert(sel:find("if data.professionSkillLine then", 1, true)), "before the profession opener")
    H.assertTrue(Read("Search/Query.lua"):find("ns.RecipeMats:ShowView(quickFilter, text)", 1, true) ~= nil, "drawn as a page")
    H.assertTrue(Read("Search/Results/ActionHints.lua"):find('"Shift", V.mats', 1, true) ~= nil, "named in the row's hint")
end

local pass, fail, failures = H.runSuite("RecipeMats", tests)
return { pass = pass, fail = fail, failures = failures }
