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
    }
    local env = setmetatable({
        ns = ns, uiSearchData = rows, slower = string.lower,
        EasyFind = { db = { professionRecipeFilters = opts.filters } },
        RemoveEntriesByCategory = function() end,
        Utils = { SliceCheckpoint = function() end, SafeAfter = function() retries = retries + 1 end },
        GetProfessions = function() return nil, nil, nil, nil, 1 end,
        GetProfessionInfo = function() return "First Aid", 135966, 1, 75, 0, 0, 129 end,
        C_SpellBook = { IsSpellKnown = function(id) return id == 3275 end },
        C_Spell = { GetSpellInfo = function(id) return { name = "spell " .. id, iconID = id } end },
        C_Item = { GetItemIconByID = function(id) return "item " .. id end },
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

local pass, fail, failures = H.runSuite("ForeverProfessions", tests)
return { pass = pass, fail = fail, failures = failures }
