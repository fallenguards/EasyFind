-- Lean search rows (Shared/Utils.lua LeanRowMT): constant fields live on a
-- shared proto and steps or a holder line are built on first read. Runs the
-- real row code from Database/Main.lua and Search/Commands.lua; each kind
-- must build the same steps the eager rows carried.
local H = require("Harness")

local function read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local function slice(src, from, to)
    local s = assert(src:find(from, 1, true), from .. " not found")
    local e = assert(src:find(to, s + #from, true), to .. " not found")
    return src:sub(s, e - 1)
end

local MAIN = read("Database/Main.lua")

local function newEnv(extra)
    local env = setmetatable({}, { __index = _G })
    env._G = env
    local utilsEnv = setmetatable({ Utils = {} }, { __index = _G })
    assert(load(slice(read("Shared/Utils.lua"), "function Utils.LeanRowMT", "\n-- Our own functions are post-hooked"),
        "=Utils.lua LeanRowMT", "t", utilsEnv))()
    env.Utils = utilsEnv.Utils
    env.Utils.SliceCheckpoint = function() end
    env.Corpora = {}
    env.slower = string.lower
    env.uiSearchData = {}
    env.RemoveEntriesByCategory = function() end
    for k, v in pairs(extra or {}) do env[k] = v end
    return env
end

local function assertSteps(got, want, label)
    H.assertEq(#got, #want, label .. ": step count")
    for i = 1, #want do
        for k, v in pairs(want[i]) do
            H.assertEq(got[i][k], v, label .. ": step " .. i .. " " .. k)
        end
        for k in pairs(got[i]) do
            H.assertTrue(want[i][k] ~= nil, label .. ": step " .. i .. " has no " .. k)
        end
    end
end

local tests = {}

function tests.lazyFieldIsBuiltOnceAndKept()
    local env = newEnv()
    local builds = 0
    local mt = env.Utils.LeanRowMT({ category = "Kind" }, {
        steps = function(row) builds = builds + 1; return { { id = row.id } } end,
    })
    local row = setmetatable({ id = 7 }, mt)
    H.assertNil(rawget(row, "steps"), "no steps until read")
    H.assertEq(row.category, "Kind", "proto field")
    H.assertNil(row.missing, "absent field")
    local steps = row.steps
    H.assertEq(steps[1].id, 7)
    H.assertTrue(row.steps == steps and rawget(row, "steps") == steps, "kept on the row")
    H.assertEq(builds, 1)
end

function tests.macroRowsBuildTheirListAndSlotSteps()
    local macros = { { "Heal", 11, "/cast Flash Heal" }, [121] = { "Mount", 12, "/cast Swift" } }
    local env = newEnv({
        Database = {}, MAX_ACCOUNT_MACROS = 120, MACROS = "Macros", CHARACTER = "Character", GENERAL = "General",
        GetNumMacros = function() return 1, 1 end,
        GetMacroInfo = function(i) local m = macros[i]; return m[1], m[2], m[3] end,
    })
    assert(load(slice(MAIN, "-- Macro rows: the path per account", "\nCorpora.ABILITY_MT"), "=Main.lua macros", "t", env))()
    H.assertTrue(env.Database:PopulateDynamicMacros())
    local account, char = env.uiSearchData[1], env.uiSearchData[2]
    H.assertEq(account.category, "Macro")
    H.assertEq(account.buttonFrame, "MainMenuMicroButton")
    H.assertEq(account.path[2], "General")
    H.assertEq(char.path[2], "Character")
    H.assertNil(rawget(char, "steps"))
    assertSteps(char.steps, {
        { buttonFrame = "MainMenuMicroButton" }, { gameMenuText = "Macros" },
        { waitForFrame = "MacroFrame", tabIndex = 2 }, { waitForFrame = "MacroFrame", macroIndex = 121 },
    }, "character macro")
    H.assertEq(account.steps[3].tabIndex, 1, "account macro tab")
end

function tests.abilityRowsCastTheirSpell()
    local env = newEnv()
    assert(load(slice(MAIN, "Corpora.ABILITY_MT", "\nfunction Database:PopulateDynamicAbilities"), "=Main.lua ability", "t", env))()
    local row = setmetatable({ spellID = 8936 }, env.Corpora.ABILITY_MT)
    H.assertEq(row.category, "Ability")
    assertSteps(row.steps, { { spellID = 8936 } }, "ability")
end

-- Guild root 10 > child 11 > leaves 12 and 13; personal root 20.
function tests.achievementCategoryStepsWalkTheParentRows()
    local cats = {
        [10] = { "Guild Root", -1, 1 }, [11] = { "Child", 10, 1 }, [12] = { "Leaf", 11, 1 },
        [13] = { "Other Leaf", 11, 1 }, [20] = { "Personal", -1, 0 },
    }
    local env = newEnv({
        Database = { statisticIDs = {}, IsStatisticAchievement = function() return false end },
        L = { UITREE_PERSONAL_ACHIEVEMENTS = "Personal Achievements" },
        ACHIEVEMENTS = "Achievements", GUILD_ACHIEVEMENTS_TITLE = "Guild Achievements",
        SearchText = { Tokenize = function(s) local t = {}; for w in s:gmatch("%S+") do t[#t + 1] = w end; return t end },
        band = function(a, b) return a % 2 == 1 and b == 1 and 1 or 0 end,
        GetCategoryList = function() return { 10, 11, 12, 13, 20 } end,
        GetCategoryInfo = function(id) local c = cats[id]; return c[1], c[2], c[3] end,
    })
    local chunk = slice(MAIN, "local CATEGORY_KEYWORD_OVERLAY = {", "\n-- Title -> source achievement.")
        .. "\nRefreshStatisticsCategoryIDs = function() return {} end"
        .. "\nIsInStatisticsCategoryTree = function() return false end"
        .. "\nHasID = function() return false end\n"
        .. slice(MAIN, "function Database:PopulateDynamicAchievements()", "\n-- statisticIDs:")
    assert(load(chunk, "=Main.lua achievement categories", "t", env))()
    H.assertTrue(env.Database:PopulateDynamicAchievements())
    local byName = {}
    for _, row in ipairs(env.uiSearchData) do byName[row.name] = row end

    local leaf = byName["Guild: Leaf"]
    H.assertEq(leaf.category, "Achievement Category")
    H.assertEq(table.concat(leaf.path, ">"), "Achievements>Guild Achievements>Guild Root>Child")
    H.assertTrue(byName["Guild: Other Leaf"].path == leaf.path, "siblings share one path")
    H.assertTrue(byName["Guild: Child"].path ~= leaf.path)
    H.assertNil(rawget(leaf, "steps"))
    assertSteps(leaf.steps, {
        { buttonFrame = "AchievementMicroButton" },
        { waitForFrame = "AchievementFrame", tabIndex = 2 },
        { waitForFrame = "AchievementFrame", achievementCategory = "Guild Root", achievementCategoryID = 10 },
        { waitForFrame = "AchievementFrame", achievementCategory = "Child", achievementCategoryID = 11 },
        { waitForFrame = "AchievementFrame", achievementCategory = "Leaf", achievementCategoryID = 12 },
    }, "guild leaf")
    H.assertTrue(leaf.isGuildAchievement)

    local personal = byName["Personal"]
    H.assertNil(personal.isGuildAchievement)
    H.assertEq(table.concat(personal.path, ">"), "Achievements>Personal Achievements")
    assertSteps(personal.steps, {
        { buttonFrame = "AchievementMicroButton" },
        { waitForFrame = "AchievementFrame", tabIndex = 1 },
        { waitForFrame = "AchievementFrame", achievementCategory = "Personal", achievementCategoryID = 20 },
    }, "personal root")
    H.assertTrue(personal.keywordsLower == personal.keywords, "one keyword table")
end

function tests.bagRowsOpenTheirSlot()
    local env = newEnv()
    assert(load(slice(MAIN, "Corpora.BAG_MT = ", "\nfunction Database:PopulateDynamicBags"), "=Main.lua bag", "t", env))()
    local locations = { { bag = 2, slot = 5 } }
    local row = setmetatable({ buttonFrame = "CharacterBag1Slot", bagID = 2, bagSlot = 5, bagLocations = locations },
        env.Corpora.BAG_MT)
    H.assertEq(row.category, "Bag")
    assertSteps(row.steps, {
        { buttonFrame = "CharacterBag1Slot" },
        { containerBag = 2, containerSlot = 5, allLocations = locations },
    }, "bag")
end

function tests.storedRowsBuildTheirHolderLine()
    local made = 0
    local env = newEnv({
        Stored = { ItemIcon = function() return 99 end },
        ns = { StoredHoldersText = function(holders, category)
            made = made + 1
            return category .. ":" .. holders[1].name
        end },
    })
    env.Utils.GetItemEquipLoc = function() return "" end
    env.Utils.IsRealEquipLoc = function() return false end
    assert(load(slice(MAIN, "-- One per category and remote flag", "\n-- Which characters a storage scope admits"),
        "=Main.lua stored rows", "t", env))()
    local holders = { { name = "Alt" } }
    local row = env.Stored.EmitStoredRow({ row = { itemID = 5, name = "Ore" }, total = 3, holders = holders },
        "Bank", { "bank" }, true)
    H.assertEq(row.category, "Bank")
    H.assertTrue(row.lookupRow and row.storedRemote, "proto flags")
    H.assertEq(made, 0, "no holder line until read")
    H.assertEq(row.storedSubtext, "Bank:Alt")
    H.assertEq(row.storedSubtext, "Bank:Alt")
    H.assertEq(made, 1, "built once")
    H.assertEq(row.keywords[2], "bank")
end

function tests.commandRowsReadTheirConstantsFromTheProto()
    local env = newEnv({
        EASYFIND_PATH = { "EasyFind" }, SLASH_COMMANDS_PATH = { "Slash Commands" }, COMMANDS_ICON = 42,
        Commands = { searchBarCommands = { { display = "/ef", displayToken = "ef", aliases = { "ef" },
            command = "ef", desc = "Open" } } },
    })
    local defs = { { display = "/dance", lower = "dance", subLabel = "Emote", run = function() end },
                   { display = "/logout", lower = "logout", slashCommand = "/logout" } }
    env.CollectNativeCommandDefs = function() return defs end
    local src = read("Search/Commands.lua")
    local from = assert(src:find("local CUSTOM_ROW_MT", 1, true))
    local _, to = assert(src:find("\n    return out\nend", from, true))
    assert(load(src:sub(from, to), "=Commands.lua rows", "t", env))()
    local rows = env.Commands:BuildCommandSearchData()
    H.assertEq(#rows, 3)
    H.assertEq(rows[1].category, "Command")
    H.assertEq(rows[1].path[1], "EasyFind")
    H.assertFalse(rows[1].isNativeCommand)
    H.assertEq(rows[2].path[1], "Slash Commands")
    H.assertTrue(rows[2].isNativeCommand)
    H.assertEq(rows[2].icon, 42)
    H.assertEq(rows[2].searchCommandDesc, "Emote")
    H.assertEq(rows[3].slashCommand, "/logout")
    H.assertEq(rows[3].searchCommandDesc, "/logout")
    local again = env.Commands:BuildCommandSearchData()
    H.assertTrue(again[2].keywords == rows[2].keywords, "a command's keywords are built once")
end

local pass, fail, failures = H.runSuite("LeanRows", tests)
return { pass = pass, fail = fail, failures = failures }
