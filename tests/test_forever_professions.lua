-- Professions on WoW Forever (Database/ProfessionData.lua's Forever block,
-- Database/Main.lua PopulateDynamicProfessions): its recipes are its own,
-- First Aid among them, one page each. Only the First Aid row showed, no
-- recipe (2026-11-16): the retail list has no First Aid and no Forever page.
local H = require("Harness")

local function Data(forever)
    local env = H.newEnv()
    local ns = H.newNs(env)
    ns.Caps = { forever = forever }
    H.loadModule("Database/ProfessionData.lua", env, ns)
    return ns.PROFESSION_RECIPES
end

local function Has(list, id)
    for n in list:gmatch("%d+") do if tonumber(n) == id then return true end end
    return false
end

local tests = {}

function tests.foreverShipsItsOwnRecipes_firstAidToo()
    local forever = Data(true)
    H.assertNotNil(forever[129], "First Aid")
    H.assertEq(forever[129].childSkillLine, 2942)
    H.assertTrue(Has(forever[129].recipesByPage[2942], 3275), "Linen Bandage")
    for skillLine, prof in pairs(forever) do
        local pages = 0
        for _ in pairs(prof.recipesByPage) do pages = pages + 1 end
        H.assertEq(pages, 1, "one page: " .. skillLine)
    end
    H.assertTrue(Has(forever[186].recipesByPage[2946], 2657), "Smelt Copper")
    local retail = Data(false)
    H.assertNil(retail[129], "retail has no First Aid")
    H.assertNil(retail[164].recipesByPage[2938], "nor Forever's pages")
end

-- The slice from the learned check to the end of the populate.
local function Populate(opts)
    local f = assert(io.open(H.ADDON_ROOT .. "/Database/Main.lua", "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    local s = assert(src:find("local C_SpellBook = C_SpellBook", 1, true))
    local e = assert(src:find("\n-- Macro rows:", s, true))
    local rows, retries = {}, 0
    local ns = {
        Caps = { forever = true },
        PROFESSION_RECIPES = Data(true),
        KnownExpansionPages = function() return {} end,
        CharacterData = { List = function() return opts.chars or {} end },
    }
    local env = setmetatable({
        ns = ns, uiSearchData = rows, slower = string.lower,
        EasyFind = { db = { professionRecipeFilters = opts.filters, professionScope = opts.scope,
                            professionScopeChars = opts.picked } },
        RemoveEntriesByCategory = function() end,
        Utils = { SliceCheckpoint = function() end, SafeAfter = function() retries = retries + 1 end },
        GetProfessions = function() return nil, nil, nil, nil, 1 end,
        GetProfessionInfo = function() return "First Aid", 135966, 1, 75, 0, 0, 129 end,
        C_SpellBook = { IsSpellKnown = function(id) return id == 3275 end },
        C_Spell = { GetSpellInfo = function(id) return { name = "spell " .. id, iconID = id } end },
        C_Item = { GetItemIconByID = function(id) return "item " .. id end },
        C_TradeSkillUI = opts.names and { GetTradeSkillDisplayName = function(id) return opts.names[id] end } or nil,
    }, { __index = _G })
    env._G = env
    local Database = {}
    env.Database = Database
    assert(load(src:sub(s, e - 1), "=Main.lua professions", "t", env))()
    Database:PopulateDynamicProfessions()
    local byRecipe, profRow = {}, nil
    for _, row in ipairs(rows) do
        if row.professionRecipeID then byRecipe[row.professionRecipeID] = row else profRow = row end
    end
    return byRecipe, retries, profRow, ns
end

-- Each Forever recipe ships the item it makes, in its page's order.
function tests.foreverShipsTheItemEachRecipeMakes()
    for skillLine, prof in pairs(Data(true)) do
        for page, ids in pairs(prof.recipesByPage) do
            local recipes, made = {}, {}
            for n in ids:gmatch("%d+") do recipes[#recipes + 1] = tonumber(n) end
            for n in prof.makesByPage[page]:gmatch("%d+") do made[#made + 1] = tonumber(n) end
            H.assertEq(#made, #recipes, "one per recipe: " .. skillLine)
            for i, id in ipairs(recipes) do
                if id == 3275 then H.assertEq(made[i], 1251, "Linen Bandage makes the bandage") end
                if id == 7418 then H.assertEq(made[i], 0, "an enchant makes no item") end
            end
        end
    end
    H.assertNil(Data(false)[164].makesByPage, "retail ships none")
end

-- A recipe row: the item it makes on the right, its profession's icon on
-- the left. The profession row keeps the profession glyph (2026-11-16).
function tests.aRecipeRowWearsItsItem_andItsProfessionsIcon()
    local byRecipe, _, profRow, ns = Populate({})
    H.assertEq(byRecipe[3275].icon, "item 1251", "the bandage, not the craft's spell icon")
    local env = H.newEnv()
    local iconNs = H.newNs(env)
    iconNs.ResultIcons, iconNs.ProfessionGlyphs = {}, ns.ProfessionGlyphs
    iconNs.PlayerRepCategoryIcon = function() return {} end
    iconNs.ART, iconNs.SETTING_ICON, iconNs.REP_CATEGORY_ICONS = {}, {}, {}
    iconNs.Extensions = { ProviderOf = function() end }
    H.loadModule("Search/Results/Icons.lua", env, iconNs)
    local Icons = iconNs.ResultIcons
    H.assertEq(Icons:GetFlatCategoryIcon(byRecipe[3275]).tex, 135966, "First Aid's own icon")
    H.assertEq(Icons:GetFlatCategoryIcon(profRow).atlas, "UI-HUD-MicroMenu-Professions-Up", "the profession row")
    H.assertEq(Icons:GetFlatCategoryIcon({ name = "Linen Bandage", category = "Profession", classicRecipe = true,
        professionName = "Tailoring" }).atlas, "UI-HUD-MicroMenu-Professions-Up", "no icon known: the glyph")
end

function tests.foreverRecipesFillTheProfession_learnedOrNot()
    local byRecipe, retries = Populate({})
    H.assertNotNil(byRecipe[3275], "Linen Bandage, learned")
    H.assertNotNil(byRecipe[3276], "Heavy Linen Bandage, not learned yet: shown, as on retail")
    H.assertEq(byRecipe[3275].professionOpenID, 2942, "opens on its page")
    H.assertEq(retries, 0, "the page is known: no waiting for the client's list")
    local learnedOnly = Populate({ filters = { unlearned = false } })
    H.assertNotNil(learnedOnly[3275])
    H.assertNil(learnedOnly[3276], "Show Unlearned off")
end

-- Every other profession's recipes too, ranked under the character's own
-- (a player could not look an enchant up, 2026-11-23). They cannot be
-- crafted here, so they open no profession window.
local NAMES = { [129] = "First Aid", [333] = "Enchanting", [164] = "Blacksmithing" }

function tests.otherProfessionsRecipes_showRankedUnderYourOwn()
    local byRecipe = Populate({ names = NAMES })
    local enchant = byRecipe[7418]
    H.assertNotNil(enchant, "an enchant, for a character without Enchanting")
    H.assertTrue(enchant.otherProfession == true, "marked another profession's")
    H.assertEq(enchant.scoreBonus, -60, "ranked under the character's own")
    H.assertNil(enchant.professionSkillLine, "no profession window to open")
    H.assertNil(enchant.professionMakes, "an enchant makes no item")
    H.assertEq(enchant.keywords[2], "enchanting", "found by its profession's name")
    local smith = byRecipe[2660]
    H.assertNotNil(smith and smith.professionMakes, "a smith's recipe names what it makes")
    H.assertNil(byRecipe[3275].otherProfession, "the character's own First Aid stays its own")
    H.assertEq(byRecipe[3275].professionSkillLine, 129)
    -- Show Unlearned is the game's own window filter, about the character's
    -- own professions: off, the other professions' still show (it hid every
    -- enchant, 2026-11-24); the scope alone decides whose show.
    local unlearnedOff = Populate({ names = NAMES, filters = { unlearned = false } })
    H.assertNotNil(unlearnedOff[7418], "Show Unlearned off: an enchant still shows")
    local unnamed = Populate({ names = { [129] = "First Aid" } })
    H.assertNil(unnamed[7418], "a profession the game does not name is left out")
end

-- An enchanter's unlearned enchant, Show Unlearned off as the game's own
-- window had it, the scope on every profession: no row (Forever, 2026-11-26,
-- "crusader ench ... even though i have every profession ticked"). Every
-- profession takes in the character's own recipes its own rows left out.
function tests.everyProfession_takesInTheCharactersOwnUnlearned()
    local every = Populate({ names = NAMES, filters = { unlearned = false } })
    H.assertNotNil(every[3275], "First Aid's learned recipe, its own row")
    H.assertNil(every[3275].otherProfession)
    local unlearned = every[3276]
    H.assertTrue(unlearned and unlearned.otherProfession == true, "the unlearned one: a row as another profession's")
    H.assertEq(unlearned.scoreBonus, -60, "ranked under its own")
    local mine = Populate({ names = NAMES, filters = { unlearned = false }, scope = "mine" })
    H.assertNil(mine[3276], "this character only: Show Unlearned decides")
    local on = Populate({ names = NAMES })
    H.assertNil(on[3276].otherProfession, "Show Unlearned on: its own row, not two")
end

-- Whose professions' recipes show, the Professions filter's scope
-- (2026-11-24): this character's, chosen characters', the account's, or
-- every profession, by the professions the characters' records hold.
function tests.theScope_picksWhoseProfessionsShow()
    local chars = {
        { key = "me", isCurrent = true, profs = { { name = "First Aid" } } },
        { key = "ench", profs = { { name = "Enchanting" } } },
        { key = "smith", profs = { { name = "Blacksmithing" } } },
    }
    local mine = Populate({ names = NAMES, chars = chars, scope = "mine" })
    H.assertNotNil(mine[3275], "this character's own stay")
    H.assertNil(mine[7418], "no other profession's")
    local account = Populate({ names = NAMES, chars = chars, scope = "account" })
    H.assertNotNil(account[7418], "an alt's Enchanting")
    H.assertNotNil(account[2660], "another alt's Blacksmithing")
    local chosen = Populate({ names = NAMES, chars = chars, scope = "chosen", picked = { ench = true } })
    H.assertNotNil(chosen[7418], "the chosen alt's")
    H.assertNil(chosen[2660], "not the one left out")
    local every = Populate({ names = NAMES, chars = { chars[1] } })
    H.assertNotNil(every[7418], "the default: every profession, whoever has it")
end

function tests.otherProfessionsRecipe_clickShowsWhatItMakes()
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/Results/Handlers/Selection.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local other = assert(src:find("if data.otherProfession then", 1, true), "routed apart from the profession opener")
    -- Its page opens in the bar: above the dismiss every other pick ends
    -- in (the click on an enchant closed the bar, 2026-11-26).
    local dismiss = assert(src:find("-- the secure macrotext attribute set when the row was rendered", 1, true))
    H.assertTrue(other < dismiss, "before the bar is closed")
    -- An enchant makes no item: its click lists its mats (2026-11-26).
    H.assertNotNil(src:find("ns.RecipeMats:Show(data)", other, true), "an enchant's click: its mats")
    f = assert(io.open(H.ADDON_ROOT .. "/Search/Results/ActionHints.lua", "rb"))
    local hints = f:read("*a")
    f:close()
    H.assertNotNil(hints:find("if data.otherProfession and not data.professionMakes then return Hint(V.click, V.mats) end",
        1, true), "its hint: the click, no Shift doing the same")
    H.assertNotNil(src:find("ns.ItemSources:Show({ itemID = item,", other, true), "the made item's sources page")
end

-- Another profession's recipe wears its icon at the right, as the
-- character's own do (they had none, 2026-11-26).
function tests.otherProfessionsRecipe_wearsItsIconAtTheRight()
    local env = H.newEnv()
    local iconNs = H.newNs(env)
    iconNs.ResultIcons, iconNs.ProfessionGlyphs = {}, {}
    iconNs.PlayerRepCategoryIcon = function() return {} end
    iconNs.ART, iconNs.SETTING_ICON, iconNs.REP_CATEGORY_ICONS = {}, {}, {}
    iconNs.Extensions = { ProviderOf = function() end }
    H.loadModule("Search/Results/Icons.lua", env, iconNs)
    local byRecipe = Populate({ names = NAMES })
    H.assertTrue(iconNs.ResultIcons.IsRightSideIconData(byRecipe[2660]), "a smith's recipe: its item at the right")
    H.assertTrue(iconNs.ResultIcons.IsRightSideIconData(byRecipe[7418]), "an enchant: its own icon at the right")
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/Results/Render/RowContent.lua", "rb"))
    local src = f:read("*a")
    f:close()
    H.assertNotNil(src:find("data.professionSkillLine or data.otherProfession) then", 1, true), "drawn there too")
end

local pass, fail, failures = H.runSuite("ForeverProfessions", tests)
return { pass = pass, fail = fail, failures = failures }
