-- Steering words (Shared/SearchText.lua, ns.SearchSteer): a query word
-- naming a kind of row scopes the rest to that category ("zone
-- stormwind", "spell frostbolt", "rep darnassus": 36 of the Era audit's
-- 69 such queries painted nothing, 2026-10-31). The provider trigger
-- words, the quick-filter aliases and the map categories' keywords
-- register themselves; a steered row scores the cut query as well as
-- the whole one, so a name holding the word keeps its tier.
local H = require("Harness")

local function Fresh()
    local env = H.newEnv()
    local ns = H.newNs(env)
    H.loadModule("Shared/SearchText.lua", env, ns)
    return env, ns
end

local tests = {}

function tests.registry_cutsTheQueryPerCategory()
    local _, ns = Fresh()
    local Steer = ns.SearchSteer
    Steer.Add("Zone", "zone")
    Steer.Add("Ability", "spell")
    Steer.Add("Ability", "a")
    Steer.Add("Ability", "of")
    Steer.Add("Ability", "flight master")
    H.assertNil(Steer.byCategory.Ability.a, "one letter never steers")
    H.assertNil(Steer.byCategory.Ability.of, "a function word never steers")
    H.assertNil(Steer.byCategory.Ability["flight master"], "a phrase never steers")

    H.assertEq(Steer.Strip("zone stormwind", "Zone"), "stormwind")
    H.assertEq(Steer.Strip("spell frostbolt (rank 4)", "Ability"), "frostbolt (rank 4)", "punctuation kept")
    H.assertNil(Steer.Strip("stormwind", "Zone"), "no steering word")
    H.assertNil(Steer.Strip("zone", "Zone"), "nothing left to search for")
    H.assertNil(Steer.Strip("zone stormwind", "Ability"), "another category's word")

    local holder = {}
    H.assertTrue(Steer.Scope(holder, "spell frostbolt", { "spell", "frostbolt" }))
    local rec = holder.byCategory.Ability
    H.assertEq(rec.query, "frostbolt")
    H.assertEq(rec.len, 9)
    H.assertEq(#rec.words, 1)
    H.assertEq(rec.words[1], "frostbolt")
    H.assertNil(holder.byCategory.Zone)
    H.assertEq(#holder.rest, 1, "the words steering nothing")
    H.assertEq(holder.rest[1], "frostbolt")

    H.assertTrue(not Steer.Scope(holder, "frostbolt", { "frostbolt" }))
    H.assertNil(holder.byCategory.Ability, "cleared for the next query")
    H.assertTrue(not Steer.Scope(holder, "spell", { "spell" }), "a bare steering word is a plain query")

    H.assertTrue(Steer.Scope(holder, "zone stormwind"), "no word list: the query's own tokens")
    H.assertEq(holder.byCategory.Zone.query, "stormwind")
end

function tests.bossAndStatWords_steerTheirRows()
    local _, ns = Fresh()
    local by = ns.SearchSteer.byCategory
    H.assertTrue(by.Boss.boss and by.Boss.raid and by.Boss.dungeon)
    H.assertTrue(by.Statistic.stat and by.Statistics.statistics)
end

function tests.providerTriggerWords_steerTheProvidersCategories()
    local env, ns = Fresh()
    H.loadModule("Shared/CategoryMap.lua", env, ns)
    H.loadModule("Search/Engine.lua", env, ns)
    local by = ns.SearchSteer.byCategory
    H.assertTrue(by.Ability.spell and by.Ability.ability)
    H.assertTrue(by.Reputation.rep and by.Reputation.faction)
    H.assertTrue(by.Loot.loot and by.Loot.gear)
    H.assertTrue(by.Bank.vault and by.Warband.vault, "every category the provider fills")
    H.assertTrue(by.Profession.recipe, "a recipe is a profession's")
    ns.CategoryMap.Add({ key = "quests", parent = "extensions", categories = { "Quest" } })
    ns.SearchEngine:AddProvider({ key = "quests", words = { "quest", "quests" } })
    H.assertTrue(by.Quest.quest, "an extension's trigger words")
end

function tests.quickFilterAliases_steerTheirCategories()
    local env, ns = Fresh()
    ns.Filters.GetUIBucket = function() return nil end
    ns.Search.SetQuickFilterPillFill = function() end
    ns.Search.GetSelectedIndex = function() return 0 end
    ns.Search.GetResultButtons = function() return {} end
    ns.Search.GetSearchFrame = function() return nil end
    ns.Filters.HideResults = function() end
    ns.Filters.ShowHierarchicalResults = function() end
    ns.Filters.OnSearchTextChanged = function() end
    ns.Filters.IsGuildAchievementData = function() return false end
    H.loadModule("Search/Filters/QuickFilter.lua", env, ns)
    local by = ns.SearchSteer.byCategory
    H.assertTrue(by.Ability.spells)
    H.assertTrue(by["Game Settings"].setting and by["AddOn Settings"].setting)
    H.assertTrue(by.Item.item and by.Bag.item and by.Bank.items)
    H.assertTrue(by["@map"].zone and by["@map"].location, "@map's aliases steer every map row")
    H.assertNil(by.Mount.m, "one letter never")
    H.assertNil(by.Ability.ab, "a two-letter alias is for the @ only")
end

function tests.mapCategoryKeywords_steerTheirRows()
    local env, ns = Fresh()
    ns.ART = setmetatable({}, { __index = function() return { tex = "art", coords = { 0, 1, 0, 1 } } end })
    H.loadModule("MapSearch/Categories.lua", env, ns)
    local by = ns.SearchSteer.byCategory
    H.assertTrue(by.dungeon.dungeon and by.raid.raids)
    H.assertTrue(by.dungeon.instance, "a parent's words steer its children")
    H.assertTrue(by.innkeeper.inn and by.auctionhouse.ah)
    H.assertNil(by.flightmaster["flight master"], "a phrase never steers")
end

local function WithRows(Database, rows, fn)
    local data = Database.uiSearchData
    for i = 1, #rows do data[i] = rows[i] end
    Database:ResetSearchCache()
    fn()
    for i = #data, 1, -1 do data[i] = nil end
    Database:ResetSearchCache()
end

local function RankOf(results, entry)
    for i = 1, #results do
        if results[i].data == entry then return i, results[i].score end
    end
    return nil
end

function tests.searchUI_aSteeringWordScopesTheRest()
    local env, ns = Fresh()
    ns.Database.uiSearchData = {}
    ns.Database.IsLootStatSearchWord = function() return false end
    ns.Database.IsLootSlotSearchWord = function() return false end
    local Database = H.loadModule("Database/Search.lua", env, ns)
    local Steer = ns.SearchSteer
    Steer.Add("Ability", "spell")
    Steer.Add("Reputation", "rep")
    local frostbolt = { name = "Frostbolt", nameLower = "frostbolt", category = "Ability", keywordsLower = {} }
    local scroll = { name = "Frostbolt Scroll", nameLower = "frostbolt scroll", category = "Item", keywordsLower = {} }
    local reflection = { name = "Spell Reflection (Rank 2)", nameLower = "spell reflection (rank 2)", category = "Ability", keywordsLower = {} }
    local darnassus = { name = "Darnassus", nameLower = "darnassus", category = "Reputation", keywordsLower = {} }
    local macro = { name = "Darnassus", nameLower = "darnassus", category = "Macro", keywordsLower = {} }
    WithRows(Database, { scroll, reflection, frostbolt, macro, darnassus }, function()
        local r = Database:SearchUI("spell frostbolt")
        local rank, score = RankOf(r, frostbolt)
        H.assertEq(rank, 1, "the ability named by the rest of the query leads")
        H.assertEq(score, 1000, "scored as if 'frostbolt' were typed alone")
        H.assertNil(RankOf(r, scroll), "an item needs the word 'spell' itself")

        local _, held = RankOf(Database:SearchUI("spell reflection"), reflection)
        H.assertEq(held, 500, "a name holding the steering word keeps its whole-query tier")

        r = Database:SearchUI("rep darnassus")
        H.assertEq(RankOf(r, darnassus), 1)
        H.assertNil(RankOf(r, macro), "the twin in another category stays out")

        r = Database:SearchUI("spell")
        H.assertNil(RankOf(r, frostbolt), "a bare steering word is a plain query")
        H.assertEq(RankOf(r, reflection), 1)
    end)
end

local pass, fail, failures = H.runSuite("SearchSteering", tests)
return { pass = pass, fail = fail, failures = failures }
