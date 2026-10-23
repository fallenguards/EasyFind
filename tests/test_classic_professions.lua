-- Tests for the classic clients' professions in search (Database/Main.lua
-- CaptureClassicRecipes, PopulateClassicProfessions; Search/Results/
-- Handlers/Selection.lua FindClassicRecipe): a window's recipes kept on the
-- character as it shows, with the spell that opened it.
local H = require("Harness")

local function slice(path, from, to)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find(from, 1, true), from .. " not found")
    local e = assert(src:find(to, s, true), to .. " not found")
    return src:sub(s, e - 1)
end

local SPELLS = { [3100] = "Blacksmithing", [2656] = "Smelting", [2657] = "Smelt Copper", [5149] = "Beast Training" }

local function world()
    local w = { now = 100, windows = {}, data = {} }
    local env = setmetatable({
        ns = { CurrentCharacterKey = function() return "Thrall-Era" end },
        EasyFind = { db = {} },
        uiSearchData = w.data, slower = string.lower, next = next, pairs = pairs, type = type,
        RemoveEntriesByCategory = function() end,
        Utils = { SliceCheckpoint = function() end },
        GetTime = function() return w.now end,
        C_Spell = {
            GetSpellName = function(id) return SPELLS[id] end,
            GetSpellInfo = function(name)
                for id, n in pairs(SPELLS) do if n == name then return { spellID = id } end end
            end,
            GetSpellTexture = function(id) return id * 10 end,
        },
        GetTradeSkillLine = function() return w.windows.trade and w.windows.trade.name end,
        GetNumTradeSkills = function() return #(w.windows.trade and w.windows.trade.rows or {}) end,
        GetTradeSkillInfo = function(i) local r = w.windows.trade.rows[i]; return r[1], r[2] end,
        GetTradeSkillIcon = function(i) return 500 + i end,
        GetCraftDisplaySkillLine = function() return nil end,
        GetCraftName = function() return w.windows.craft and w.windows.craft.name end,
        GetNumCrafts = function() return #(w.windows.craft and w.windows.craft.rows or {}) end,
        GetCraftInfo = function(i) local r = w.windows.craft.rows[i]; return r[1], "", r[2] end,
    }, { __index = _G })
    env._G = env
    local Database = {}
    env.Database = Database
    assert(load(slice("Database/Main.lua", "Database.CLASSIC_OPEN_WINDOW_S", "\nfunction Database:PopulateDynamicProfessions()"),
        "=Main.lua classic professions", "t", env))()
    return Database, w, env
end

local tests = {}

function tests.tradeWindowRecipesAreKept()
    local Database, w, env = world()
    w.windows.trade = { name = "Blacksmithing", rows = { { "Smelting", "header" }, { "Copper Bracers", "easy" },
                                                         { "Rough Sharpening Stone", "trivial" } } }
    H.assertTrue(Database:CaptureClassicRecipes(false, true), "a new list")
    local prof = env.EasyFind.db.classicRecipes["Thrall-Era"].Blacksmithing
    H.assertEq(prof.recipes["Copper Bracers"], 502)
    H.assertNil(prof.recipes.Smelting, "headers are not recipes")
    H.assertEq(prof.spellID, 3100, "opened by the spell of its name")
    H.assertFalse(Database:CaptureClassicRecipes(false, false), "an update with nothing new")
end

-- Mining's window opens on Smelting: the cast names it, in either order.
function tests.theOpeningCastIsKeptEitherOrder()
    local Database, w, env = world()
    w.windows.trade = { name = "Mining", rows = { { "Smelt Copper", "optimal" } } }
    Database:NoteClassicCast(2656)
    w.now = w.now + 0.2
    Database:CaptureClassicRecipes(false, true)
    local book = env.EasyFind.db.classicRecipes["Thrall-Era"]
    H.assertEq(book.Mining.spellID, 2656, "cast, then the window")
    w.now = w.now + 5
    Database:NoteClassicCast(2657)
    H.assertEq(book.Mining.spellID, 2656, "a recipe cast later is not the opener")

    local Database2, w2, env2 = world()
    w2.windows.trade = { name = "Mining", rows = { { "Smelt Copper", "optimal" } } }
    Database2:CaptureClassicRecipes(false, true)
    w2.now = w2.now + 0.3
    Database2:NoteClassicCast(2656)
    H.assertEq(env2.EasyFind.db.classicRecipes["Thrall-Era"].Mining.spellID, 2656, "the window, then the cast")
end

function tests.craftWindowsAreKeptByTheirName()
    local Database, w, env = world()
    w.windows.craft = { name = "Beast Training", rows = { { "Bite", "header" }, { "Bite (Rank 2)", "used" } } }
    Database:CaptureClassicRecipes(true, true)
    local prof = env.EasyFind.db.classicRecipes["Thrall-Era"]["Beast Training"]
    H.assertTrue(prof.recipes["Bite (Rank 2)"] ~= nil)
    H.assertNil(prof.recipes.Bite, "the craft list's kind is its third value")
end

function tests.rowsOpenByTheProfessionSpell()
    local Database, w = world()
    w.windows.trade = { name = "Blacksmithing", rows = { { "Copper Bracers", "easy" } } }
    Database:CaptureClassicRecipes(false, true)
    H.assertTrue(Database:PopulateClassicProfessions())
    local byName = {}
    for _, row in ipairs(w.data) do byName[row.name] = row end
    H.assertEq(byName.Blacksmithing.spellID, 3100)
    H.assertEq(byName["Copper Bracers"].spellID, 3100, "the recipe's click opens its window")
    H.assertTrue(byName["Copper Bracers"].classicRecipe)
    H.assertEq(byName["Copper Bracers"].professionName, "Blacksmithing")
    H.assertTrue(Database:HasClassicProfessions())
end

function tests.aProfessionSwitchedOffHasNoRows()
    local Database, w, env = world()
    w.windows.trade = { name = "Blacksmithing", rows = { { "Copper Bracers", "easy" } } }
    Database:CaptureClassicRecipes(false, true)
    env.EasyFind.db.professionFilters = { Blacksmithing = false }
    Database:PopulateClassicProfessions()
    H.assertEq(#w.data, 0, "unchecked in the filter flyout")
end

-- The filter flyout's list: the skill list's profession headers, and every
-- window the character opened (a hunter's Beast Training has no skill line).
function tests.flyoutListsTheCharactersProfessions()
    local lines = {
        { "Professions", true }, { "Mining" }, { "Weapon Skills", true }, { "Swords" },
        { "Secondary Skills", true }, { "Cooking" },
    }
    local out = {}
    local env = setmetatable({
        ns = { Database = { ClassicRecipeBook = function() return { ["Beast Training"] = { spellID = 5149 } } end } },
        TRADE_SKILLS = "Professions", SECONDARY_SKILLS = "Secondary Skills",
        GetNumSkillLines = function() return #lines end,
        GetSkillLineInfo = function(i) return lines[i][1], lines[i][2] or false end,
        C_Spell = { GetSpellTexture = function(id) return type(id) == "number" and id or nil end },
    }, { __index = _G })
    env._G = env
    local chunk = slice("Search/Filters/ProfessionOptions.lua", "local function ClassicProfessions",
        "\n-- Known professions as") .. "\nreturn ClassicProfessions"
    local ClassicProfessions = assert(load(chunk, "=ProfessionOptions.lua ClassicProfessions", "t", env))()
    ClassicProfessions(out)
    local names = {}
    for i, p in ipairs(out) do names[i] = p.name end
    H.assertEq(table.concat(names, ", "), "Beast Training, Cooking, Mining")
    H.assertEq(out[1].skillLine, "Beast Training", "keyed by name, as the reader keys them")
    H.assertEq(out[1].icon, 5149)
end

function tests.recipeIsFoundInItsWindow()
    local expanded
    local env = setmetatable({
        TradeSkillFrame = { IsShown = function() return true end },
        GetTradeSkillLine = function() return "Blacksmithing" end,
        GetNumTradeSkills = function() return 3 end,
        GetTradeSkillInfo = function(i) return ({ "Armor", "Copper Bracers", "Copper Chain Belt" })[i] end,
        ExpandTradeSkillSubClass = function(i) expanded = i end,
        Handlers = {},
    }, { __index = _G })
    env._G = env
    assert(load(slice("Search/Results/Handlers/Selection.lua", "Handlers.CLASSIC_RECIPE_WINDOWS",
        "\nfunction Handlers:SelectClassicRecipe"), "=Selection.lua FindClassicRecipe", "t", env))()
    local win = env.Handlers.CLASSIC_RECIPE_WINDOWS[1]
    H.assertEq(env.Handlers.FindClassicRecipe(win, "Blacksmithing", "Copper Chain Belt"), 3)
    H.assertEq(expanded, 0, "every header unfolded first")
    H.assertNil(env.Handlers.FindClassicRecipe(win, "Tailoring", "Copper Chain Belt"), "another profession's window")
end

local pass, fail, failures = H.runSuite("ClassicProfessions", tests)
return { pass = pass, fail = fail, failures = failures }
