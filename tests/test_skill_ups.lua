-- Skill-up colors (2026-11-19): each learned recipe's difficulty, read
-- from the game while its profession window lists it, colors its row; and
-- @skillups lists the recipes that still give a point, orange first.
local H = require("Harness")

local function World(opts)
    opts = opts or {}
    local env = H.newEnv()
    env._G = env
    local ns = H.newNs(env)
    ns.Caps = opts.caps or { forever = true }
    ns.CurrentCharacterKey = function() return "Thrall-Realm" end
    env.EasyFindDB = {}
    env.EasyFind.db = env.EasyFindDB
    local t = { frames = {}, linked = false, light = false,
                recipes = { [10] = { learned = true, relativeDifficulty = 0 }, [11] = { learned = true, relativeDifficulty = 2 },
                            [12] = { learned = true, relativeDifficulty = 3 }, [13] = { learned = false, relativeDifficulty = 0 },
                            [14] = { learned = true, relativeDifficulty = 1 } } }
    env.CreateFrame = function()
        local f = H.newFrame()
        t.frames[#t.frames + 1] = f
        return f
    end
    env.C_TradeSkillUI = {
        GetAllRecipeIDs = function() return { 10, 11, 12, 13, 14 } end,
        GetRecipeInfo = function(id) return t.recipes[id] end,
        IsTradeSkillLinked = function() return t.linked end,
    }
    ns.Results.GetActiveTheme = function() return { lightTheme = t.light } end
    local shown = {}
    ns.Results.ShowHierarchicalResults = function(_, entries)
        for i = #shown, 1, -1 do shown[i] = nil end
        for i, e in ipairs(entries) do shown[i] = e.data end
    end
    ns.CharacterData = {
        Fold = string.lower,
        Words = function(text, out)
            for i = #out, 1, -1 do out[i] = nil end
            for w in text:lower():gmatch("%S+") do out[#out + 1] = w end
            return out
        end,
        MatchesAll = function(folded, words)
            for _, w in ipairs(words) do if not folded:find(w, 1, true) then return false end end
            return true
        end,
    }
    ns.Database.IsDynamicProviderLoaded = function() return true end
    ns.Database.uiSearchData = {
        { name = "Linen Bag", category = "Profession", professionRecipeID = 11, professionName = "Tailoring" },
        { name = "Bolt of Silk", category = "Profession", professionRecipeID = 14, professionName = "Tailoring" },
        { name = "Runecloth Bag", category = "Profession", professionRecipeID = 10, professionName = "Tailoring" },
        { name = "Brown Linen Shirt", category = "Profession", professionRecipeID = 12, professionName = "Tailoring" },
        { name = "Spice Bread", category = "Profession", professionRecipeID = 20, professionName = "Cooking" },
        { name = "Tailoring", category = "Profession", professionSkillLine = 197 },
    }
    H.loadModule("Database/SkillUps.lua", env, ns)
    return ns.SkillUps, t, shown, ns, env
end

local tests = {}

function tests.theOpenWindowsLearnedRecipes_areRead_neverAnotherPlayers()
    local SkillUps, t, _, _, env = World()
    t.linked = true
    SkillUps.Capture()
    H.assertNil(env.EasyFindDB.recipeLevels, "a linked window is someone else's")
    t.linked = false
    SkillUps.Capture()
    local store = env.EasyFindDB.recipeLevels["Thrall-Realm"]
    H.assertEq(store[10], 0)
    H.assertEq(store[12], 3)
    H.assertNil(store[13], "an unlearned recipe is not kept")
end

function tests.aListUpdate_readsOnce_aMomentLater()
    local SkillUps, t, _, _, env = World()
    local watcher = t.frames[1]
    watcher._handlers.OnEvent(watcher, "TRADE_SKILL_LIST_UPDATE")
    watcher._handlers.OnEvent(watcher, "TRADE_SKILL_LIST_UPDATE")
    H.assertNil(env.EasyFindDB.recipeLevels, "not inside the event")
    env._clock:advance(1)
    H.assertEq(env.EasyFindDB.recipeLevels["Thrall-Realm"][10], 0)
    H.assertTrue(SkillUps ~= nil)
end

function tests.aRecipeRow_wearsItsColor_darkerOnALightTheme()
    local SkillUps, t = World()
    SkillUps.Capture()
    H.assertEq(SkillUps.Hex({ professionRecipeID = 10 }), "|cffff8040", "orange")
    H.assertEq(SkillUps.Hex({ professionRecipeID = 12 }), "|cff808080", "gray")
    H.assertNil(SkillUps.Hex({ professionRecipeID = 99 }), "unread: the theme's own color")
    H.assertNil(SkillUps.Hex({ category = "Item", itemID = 5 }), "not a recipe")
    t.light = true
    H.assertEq(SkillUps.Hex({ professionRecipeID = 14 }), "|cff807000", "yellow would not read on a light fill")
end

function tests.theClassicClients_readItFromTheRecipeBook()
    local SkillUps, _, _, ns = World({ caps = { classic = true, era = true } })
    ns.Database.ClassicRecipeBook = function()
        return { ["First Aid"] = { recipes = { ["Linen Bandage"] = 1 }, levels = { ["Linen Bandage"] = 2 } } }
    end
    H.assertEq(SkillUps.Level({ classicRecipe = true, classicProfession = "First Aid", name = "Linen Bandage" }), 2)
    H.assertNil(SkillUps.Level({ classicRecipe = true, classicProfession = "First Aid", name = "Heavy Linen Bandage" }))
end

function tests.thePage_listsWhatStillGivesAPoint_hardestFirst()
    local SkillUps, _, shown = World()
    SkillUps.Capture()
    SkillUps:ShowView({}, "")
    local names = {}
    for i, d in ipairs(shown) do names[i] = d.name end
    H.assertEq(table.concat(names, ", "), "Runecloth Bag, Bolt of Silk, Linen Bag",
        "orange, yellow, green; the gray one, the unread one and the profession itself left out")
    SkillUps:ShowView({}, "bag")
    H.assertEq(#shown, 2, "typing narrows")
    SkillUps:ShowView({}, "tailoring silk")
    H.assertEq(shown[1].name, "Bolt of Silk", "by profession and name")
end

function tests.nothingReadYet_thePageSaysToOpenAProfession()
    local SkillUps, _, shown = World()
    SkillUps:ShowView({}, "")
    H.assertEq(#shown, 1)
    H.assertEq(shown[1].name, "SKILLUPS_UNREAD")
end

local pass, fail, failures = H.runSuite("SkillUps", tests)
return { pass = pass, fail = fail, failures = failures }
