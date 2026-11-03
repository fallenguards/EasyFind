-- Tests for Database/Search.lua's pure-logic scoring helpers.

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

-- Database/Search.lua expects ns.Database to be truthy and exposes
-- IsLootStatSearchWord on it. Stub the dependency before loading.
ns.Database.uiSearchData = {}
ns.Database.IsLootStatSearchWord = function() return false end
ns.Database.IsLootSlotSearchWord = function() return false end

H.loadModule("Shared/SearchText.lua", env, ns)
local Database = H.loadModule("Database/Search.lua", env, ns)
H.assertNotNil(Database, "Database/Search.lua must return Database table")
H.assertEq(Database, ns.Database)

local tests = {}

function tests.keywordTiers_beatTypoNameMatches()
    local kws = { "brackenhide", "bh" }
    local words = { "brackenhide" }
    H.assertEq(Database:ScoreKeywords(kws, "brackenhide", 11, words), 100, "exact long keyword")
    H.assertEq(Database:ScoreKeywords(kws, "brack", 5, { "brack" }), 90, "five-letter prefix")
    H.assertEq(Database:ScoreKeywords(kws, "bra", 3, { "bra" }), 70, "short prefix")
    H.assertEq(Database:ScoreKeywords(kws, "bh", 2, { "bh" }), 600, "short exact abbreviation")
    -- A one-typo name match scores 85: below the exact and long-prefix tiers.
    H.assertEq(Database:ScoreFuzzy("black rat", "brack", 5), 85, "typo name match")
end

-- A tag thousands of rows carry matches only as typed: "potion" is one
-- swapped pair from "option" and listed every setting in the game once the
-- list had no cap (2026-11-01).
function tests.tagKeywords_neverMatchByTypo()
    ns.SearchSteer.Add("Game Settings", "option")
    local tags = { "setting", "option", "config", "auto loot" }
    H.assertEq(Database:ScoreKeywords(tags, "potion", 6, { "potion" }), 0, "no typo match on a tag")
    H.assertEq(Database:ScoreKeywords(tags, "option", 6, { "option" }), 100, "typed, it matches")
    H.assertEq(Database:ScoreKeywords(tags, "opti", 4, { "opti" }), 70, "its prefix matches")
    H.assertEq(Database:ScoreKeywords({ "potoin" }, "potion", 6, { "potion" }), 85, "a row's own word still does")
    H.assertEq(Database:ScoreKeywords(tags, "auto potion", 11, { "auto", "potion" }), 0, "two words: the tag typo counts for nothing")
end

-- A macro's body words answer to the row plainly: a short one typed
-- exactly ("imp", the Era audit's "impact" hunt 2026-11-01) is no
-- abbreviation, so a name starting with it still wins.
function tests.bodyWords_takeNoShortKeywordTier()
    local body = { "macro", "health funnel", "imp" }
    H.assertEq(Database:ScoreKeywords(body, "imp", 3, { "imp" }, true), 100, "a plain keyword")
    H.assertEq(Database:ScoreKeywords(body, "imp", 3, { "imp" }), 600, "a curated one keeps the tier")
end

-- An abbreviation drops letters, so it is short: a six-letter query is a
-- word, not an abbreviation of a longer one ("potion" of "promotion").
function tests.abbreviations_areShort()
    H.assertEq(Database:ScoreKeywords({ "promotion" }, "potion", 6, { "potion" }), 0, "keyword")
    H.assertEq(Database:ScoreName("position", "potion", 6, { "potion" }), 0, "name")
    H.assertTrue(Database:ScoreName("potion", "ption", 5, { "ption" }) > 0, "a five-letter skeleton still does")
    H.assertTrue(Database:ScoreKeywords({ "shadow" }, "shdw", 4, { "shdw" }) > 0, "a four-letter one too")
end

-- "ah" is the Auction House's own abbreviation: above Ahn'Qiraj, which
-- merely starts with it, under a row named "ah" (2026-10-31).
function tests.shortExactKeyword_aboveANamePrefix()
    local kw = Database:ScoreKeywords({ "ah" }, "ah", 2, { "ah" })
    H.assertTrue(kw > Database:ScoreName("ahn'qiraj", "ah", 2), "above a name starting with it")
    H.assertTrue(kw < Database:ScoreName("ah", "ah", 2), "under a whole name")
    H.assertEq(Database:ScoreKeywords({ "repair" }, "rep", 3, { "rep" }), 70, "a keyword's prefix stays a prefix")
    H.assertEq(Database:ScoreKeywords({ "loot" }, "loot", 4, { "loot" }), 100, "four letters is a long keyword")
end

-- The map search passes no word list: keywords and multi-word names still
-- score (they scored 0, which dropped every repairer and titled trainer).
function tests.noWordList_stillScores()
    H.assertEq(Database:ScoreKeywords({ "repair" }, "repair", 6), 100, "a keyword with no word list")
    H.assertTrue(Database:ScoreKeywords({ "hunter trainer" }, "hunter trainer", 14) > 0, "a two-word title")
    H.assertTrue(Database:ScoreName("randal hunter", "randal hunter", 13) > 0, "a two-word name")
end

-- Every query word in the name outranks a row that needs a keyword (a
-- setting's page) for one of them: "spoken stop" puts Stop all Spoken
-- narration above the Spoken settings' Stop All rows (2026-10-31). Rows
-- met by keywords alone score as they did.
function tests.everyWordInTheName_outranksAWordMetByAKeyword()
    local words = { "spoken", "stop" }
    local narration = Database:ScoreEntryFields({ nameLower = "stop all spoken narration", keywordsLower = {} }, words)
    local setting = Database:ScoreEntryFields({ nameLower = "stop all", keywordsLower = { "spoken", "game settings" } }, words)
    H.assertEq(narration, 210, "both words in the name")
    H.assertEq(setting, 185, "one word in the name, one by its page")
    H.assertTrue(narration > setting)
    local prefixes = Database:ScoreEntryFields({ nameLower = "stop spoken", keywordsLower = {} }, { "spo", "sto" })
    H.assertTrue(prefixes > setting, "two name prefixes still outrank a word met by a keyword")
    -- A row met by keywords alone: the same score as before the change
    -- (its first word a prefix of the two-word keyword at 90, the second an
    -- exact word at 100; 0.75 per word and 0.6 for the row is the old 0.45).
    local keywordsOnly = Database:ScoreEntryFields({ nameLower = "a map", keywordsLower = { "eastern kingdoms" } }, { "eastern", "kingdoms" })
    H.assertEq(keywordsOnly, 95, "keywords alone: as before")
end

function tests.queryAsksFor_exactAndPrefixWords()
    local ask = { "teleport", "tp", "portal", "dungeon" }
    H.assertTrue(Database.QueryAsksFor({ "kara", "teleport" }, ask), "exact word")
    H.assertTrue(Database.QueryAsksFor({ "tp", "bran" }, ask), "two-letter exact")
    H.assertTrue(Database.QueryAsksFor({ "tele", "kara" }, ask), "prefix of teleport")
    H.assertFalse(Database.QueryAsksFor({ "kara" }, ask), "bare nickname")
    H.assertFalse(Database.QueryAsksFor({ "te" }, ask), "two letters do not prefix")
    H.assertFalse(Database.QueryAsksFor(nil, ask), "nil words")
end

function tests.normalize_passthroughForSimple()
    H.assertEq(Database:NormalizeSearchQuery("mount"), "mount")
end

function tests.normalize_rewritesTmogToTransmog()
    H.assertEq(Database:NormalizeSearchQuery("tmog"), "transmog")
end

function tests.normalize_rewritesXmogToTransmog()
    H.assertEq(Database:NormalizeSearchQuery("xmog"), "transmog")
end

function tests.normalize_handlesEmptyString()
    H.assertEq(Database:NormalizeSearchQuery(""), "")
end

function tests.normalize_handlesNil()
    H.assertEq(Database:NormalizeSearchQuery(nil), nil)
end

function tests.findAtWordBoundary_atStart()
    H.assertTrue(Database:FindAtWordBoundary("auction house", "auction"))
end

function tests.findAtWordBoundary_afterSpace()
    H.assertTrue(Database:FindAtWordBoundary("auction house", "house"))
end

function tests.findAtWordBoundary_afterHyphen()
    H.assertTrue(Database:FindAtWordBoundary("auction-house", "house"))
end

function tests.findAtWordBoundary_afterColon()
    H.assertTrue(Database:FindAtWordBoundary("group:bosses", "bosses"))
end

function tests.findAtWordBoundary_rejectsMidWord()
    H.assertFalse(Database:FindAtWordBoundary("aaaXbbb", "X"))
end

function tests.findAtWordBoundary_falseForMissing()
    H.assertFalse(Database:FindAtWordBoundary("hello world", "xyz"))
end

function tests.couldMatch_emptyQueryAlwaysMatches()
    H.assertTrue(Database:CouldMatch("anything", ""))
end

function tests.couldMatch_emptyTextRejectsNonEmpty()
    H.assertFalse(Database:CouldMatch("", "x"))
end

function tests.couldMatch_acceptsContainedChars()
    H.assertTrue(Database:CouldMatch("hello world", "lwh"))
end

function tests.couldMatch_rejectsMissingChars()
    H.assertFalse(Database:CouldMatch("hello", "xyz"))
end

function tests.couldMatch_spacesArePermissive()
    -- Space (byte 32) is treated as a wildcard in the prefilter
    H.assertTrue(Database:CouldMatch("hello", " "))
end

function tests.scoreInitials_pureInitialsHit()
    -- "rbg" -> "Rated BattleGround" (3-word, 3-char query). Score >= 130.
    local score = Database:ScoreInitials("rated battleground game", "rbg")
    H.assertTrue(score >= 130, "expected initials score >= 130, got " .. tostring(score))
end

function tests.scoreInitials_unrelatedReturnsZero()
    -- A query that shares no initials must score 0.
    H.assertEq(Database:ScoreInitials("hello world", "zz"), 0)
end

function tests.damerauLevenshtein_identical()
    H.assertEq(Database:DamerauLevenshtein("abc", "abc", 3, 3), 0)
end

function tests.damerauLevenshtein_oneSubstitution()
    H.assertEq(Database:DamerauLevenshtein("abc", "abd", 3, 3), 1)
end

function tests.damerauLevenshtein_oneTransposition()
    -- "ab" <-> "ba" is one transposition in Damerau-Levenshtein.
    H.assertEq(Database:DamerauLevenshtein("ab", "ba", 2, 2), 1)
end

function tests.damerauLevenshtein_capsLargeDifferences()
    -- Function caps at 3 once distance >= 3 to avoid wasted work.
    local d = Database:DamerauLevenshtein("abcdef", "zyxwvu", 6, 6)
    H.assertTrue(d >= 3, "expected capped distance, got " .. tostring(d))
end

function tests.isSubsequence_basicHit()
    -- "tr" in "transmog": consecutive, sparsity check passes.
    H.assertTrue(Database:IsSubsequence("transmog", "tr", 2))
end

function tests.isSubsequence_firstCharMustMatch()
    H.assertFalse(Database:IsSubsequence("transmog", "rm", 2))
end

function tests.isSubsequence_rejectsSparse()
    -- "inn" in "instance" hits positions 1, 2, 6; span 6 > queryLen*2-1 = 5.
    H.assertFalse(Database:IsSubsequence("instance", "inn", 3))
end

function tests.scoreName_exactMatchScoresHighest()
    -- Assert the tier ordering, not the tuned constant: exact beats prefix.
    local exact = Database:ScoreName("mounts", "mounts", 6)
    local prefix = Database:ScoreName("mountains", "mount", 5)
    H.assertTrue(exact > prefix,
        "exact match should outscore a prefix match; got "
        .. tostring(exact) .. " vs " .. tostring(prefix))
end

function tests.scoreName_prefixScoresAbovePartial()
    local prefix = Database:ScoreName("auction house", "auction", 7)
    local partial = Database:ScoreName("auction house", "ction", 5)
    H.assertTrue(prefix > partial,
        "prefix should score higher than mid-string substring; got "
        .. tostring(prefix) .. " vs " .. tostring(partial))
end

function tests.scoreName_emptyText()
    H.assertEq(Database:ScoreName("", "anything", 8), 0)
end

function tests.scoreName_multiWordSettingNameCanSkipMiddleWord()
    local words = { "enemy", "nameplate" }
    local score = Database:ScoreName("enemy unit nameplate", "enemy nameplate", 15, words)
    H.assertTrue(score >= 100,
        "enemy nameplate should match Enemy Unit Nameplate without typing Unit; got "
        .. tostring(score))
end

function tests.warmSearchHotPath_warmsCachedAsyncProvidersThroughGate()
    -- The pre-warm now routes loot/statistics/bosses through the same load
    -- chokepoint (EnsureDynamicProviderLoaded -> RunDynamicProvider) that the
    -- filter gate lives on, instead of calling HydrateCached* directly.
    local warmed = {}
    Database.EnsureDynamicProviderLoaded = function(_, key)
        warmed[key] = (warmed[key] or 0) + 1
        return true
    end

    Database:WarmSearchHotPath()

    H.assertEq(warmed["loot"], 1, "loot cache should warm during warmup")
    H.assertEq(warmed["statistics"], 1, "statistics cache should warm during warmup")
    H.assertEq(warmed["bosses"], 1, "boss cache should warm during warmup")
end

-- SearchUI gating for Statistic / Achievement Category entries: without an
-- "ach"/"stat" query word only strong name matches surface -- exact, prefix,
-- whole-query word boundary, or every query word exact/prefix on a distinct
-- name word. Keyword, fuzzy, and contains matches stay gated.
local statEntry = {
    name = "Average gold earned per day",
    nameLower = "average gold earned per day",
    category = "Statistic",
    keywordsLower = { "economy" },
}

local function withEntries(entries, fn)
    local data = Database.uiSearchData
    for i = 1, #entries do data[i] = entries[i] end
    Database:ResetSearchCache()
    fn()
    for i = #data, 1, -1 do data[i] = nil end
    Database:ResetSearchCache()
end

local function findsEntry(results, entry)
    for i = 1, #results do
        if results[i].data == entry then return true end
    end
    return false
end

function tests.scoreName_multiWordAnyOrderMatchesStatName()
    local score = Database:ScoreName("average gold earned per day",
        "gold per day", #"gold per day", { "gold", "per", "day" })
    H.assertTrue(score >= 90, "all-words name match should score >= 90, got " .. score)
end

function tests.searchUI_gatedStatMatchesMultiWordName()
    withEntries({ statEntry }, function()
        H.assertTrue(findsEntry(Database:SearchUI("gold per day"), statEntry),
            "multi-word all-name match should pass the ach gate")
    end)
end

function tests.searchUI_gatedStatMatchesWordBoundary()
    withEntries({ statEntry }, function()
        H.assertTrue(findsEntry(Database:SearchUI("gold"), statEntry),
            "word-boundary match should pass the ach gate")
    end)
end

function tests.searchUI_gatedStatSurvivesIncrementalTyping()
    withEntries({ statEntry }, function()
        H.assertTrue(findsEntry(Database:SearchUI("gold"), statEntry), "step: gold")
        H.assertTrue(findsEntry(Database:SearchUI("gold p"), statEntry), "step: gold p")
        H.assertTrue(findsEntry(Database:SearchUI("gold per"), statEntry), "step: gold per")
        H.assertTrue(findsEntry(Database:SearchUI("gold per day"), statEntry), "step: gold per day")
    end)
end

function tests.searchUI_gatedKeywordsStayGated()
    withEntries({ statEntry }, function()
        H.assertTrue(not findsEntry(Database:SearchUI("economy"), statEntry),
            "keyword match must not pass the ach gate")
    end)
end

function tests.searchUI_statWordStillUnlocksKeywords()
    withEntries({ statEntry }, function()
        H.assertTrue(findsEntry(Database:SearchUI("stat economy"), statEntry),
            "a typed stat word should unlock keyword scoring")
    end)
end

function tests.searchUI_gatedRejectsTypoWord()
    withEntries({ statEntry }, function()
        H.assertTrue(not findsEntry(Database:SearchUI("golf per day"), statEntry),
            "a typo'd word must not pass the gate even among exact words")
    end)
end

function tests.searchUI_gatedRejectsContainsOnlyWord()
    withEntries({ statEntry }, function()
        H.assertTrue(not findsEntry(Database:SearchUI("old per day"), statEntry),
            "a mid-word substring must not pass the gate")
    end)
end

-- Query words are cut like name words: punctuation in the typed text must
-- not turn a word into one no name has. Loot rows match word by word and
-- were vanishing at the colon of "pattern:"; a typo in one word of a
-- bracketed name found nothing.
local lootPattern = {
    name = "Pattern: Sunfire Sash", nameLower = "pattern: sunfire sash",
    category = "Loot", lootEntry = true,
}
local bracketed = {
    name = "Raids (Journal)", nameLower = "raids (journal)",
    category = "Adventure Guide", keywordsLower = { "journal" },
}

-- A loot row's name scores as any row's name: its own band (115 for a
-- prefix) sat Cruel Barb under every word start of other rows at "cru"
-- (the Era audit, 2026-11-01). The loot scorer's boss knowledge stays.
local lootBarb = {
    name = "Cruel Barb", nameLower = "cruel barb", category = "Loot", lootEntry = true,
    lootSourceKw = { "edwin", "vancleef", "deadmines" },
}
local function scoreOf(results, entry)
    for i = 1, #results do
        if results[i].data == entry then return results[i].score end
    end
    return nil
end

-- Nobody abbreviates a loot item's name: "hs" is Hearthstone, not the
-- initials of Hibernal Sash (eight such rows sat above it, 2026-11-01).
function tests.lootNames_takeNoAbbreviation()
    H.assertEq(Database:ScoreName("hibernal sash", "hs", 2, { "hs" }), 135, "initials, for a row that may be abbreviated")
    H.assertEq(Database:ScoreName("hibernal sash", "hs", 2, { "hs" }, true), 0, "none for a plain name")
    H.assertEq(Database:ScoreName("windrunner", "windrnr", 7, { "windrnr" }, true), 0, "no vowel-stripped form either")
    H.assertEq(Database:ScoreName("cruel barb", "curel barb", 10, { "curel", "barb" }, true),
        Database:ScoreName("cruel barb", "curel barb", 10, { "curel", "barb" }), "a typo is still forgiven")
end

-- The kind of an item ("cloth" as its armor type) ranks under a name that
-- holds the word: the bag's Silk Cloth sat past 250 cloth drops at "cloth"
-- (the Era audit, 2026-11-01).
local silkCloth = { name = "Silk Cloth", nameLower = "silk cloth", category = "Bag", keywordsLower = { "trade goods" } }
local devoutRobe = {
    name = "Devout Robe", nameLower = "devout robe", category = "Loot", lootEntry = true,
    lootSlotKw = { "cloth", "chest" },
}

function tests.searchUI_anItemsKindRanksUnderANameHoldingTheWord()
    local slotWord = Database.IsLootSlotSearchWord
    Database.IsLootSlotSearchWord = function(_, w) return w == "cloth" or w == "chest" end
    withEntries({ devoutRobe, silkCloth }, function()
        Database:ResetSearchCache()
        local r = Database:SearchUI("cloth")
        H.assertEq(scoreOf(r, silkCloth), 120, "the word in the name")
        H.assertEq(scoreOf(r, devoutRobe), 115, "the kind, under it")
        H.assertTrue(r[1].data == silkCloth, "the bag's cloth first")
    end)
    Database.IsLootSlotSearchWord = slotWord
end

function tests.searchUI_lootNameScoresAsAnyRowsName()
    withEntries({ lootBarb }, function()
        Database:ResetSearchCache()
        H.assertEq(scoreOf(Database:SearchUI("cru"), lootBarb), 500, "a prefix of the name")
        Database:ResetSearchCache()
        H.assertEq(scoreOf(Database:SearchUI("cruel barb"), lootBarb), 1000, "the name itself")
        Database:ResetSearchCache()
        H.assertEq(scoreOf(Database:SearchUI("vancleef"), lootBarb), 110, "the boss it drops from, the loot scorer's")
        Database:ResetSearchCache()
        H.assertTrue((scoreOf(Database:SearchUI("curel barb"), lootBarb) or 0) > 0, "a typo in the name, forgiven as any row's")
    end)
end

function tests.searchUI_lootRowSurvivesPunctuationInQuery()
    withEntries({ lootPattern }, function()
        for _, q in ipairs({ "pattern", "pattern:", "pattern: s", "pattern: sunfire" }) do
            Database:ResetSearchCache()
            H.assertTrue(findsEntry(Database:SearchUI(q), lootPattern), "loot row must match: " .. q)
        end
    end)
end

local ampersand = {
    name = "Guild & Communities", nameLower = "guild & communities",
    category = "Menu Bar", keywordsLower = { "guild", "communities" },
}
local outfit2 = {
    name = "Outfit (2)", nameLower = "outfit (2)", category = "Outfit", keywordsLower = { "outfit" },
}
local bareGuild = { name = "Guild", nameLower = "guild", category = "Menu Bar", keywordsLower = { "guild" } }
local hyphenA = { name = "Proto-Drake Rusted", nameLower = "proto-drake rusted", category = "Mount", keywordsLower = {} }
local hyphenB = { name = "Red Proto-Drake", nameLower = "red proto-drake", category = "Mount", keywordsLower = {} }

function tests.searchUI_stray_punctuation_tokens_do_not_hide_rows()
    withEntries({ ampersand, outfit2 }, function()
        for _, q in ipairs({ "& guild", "guild &", "guild  &" }) do
            Database:ResetSearchCache()
            H.assertTrue(findsEntry(Database:SearchUI(q), ampersand), "ampersand query must match: " .. q)
        end
        Database:ResetSearchCache()
        H.assertTrue(findsEntry(Database:SearchUI("outfti ("), outfit2),
            "a typo followed by a stray bracket must still match")
    end)
    -- The second pass sits under the raw tiers: typing the "&" of "Guild &
    -- Communities" must not lift a row named exactly "Guild" over it.
    withEntries({ bareGuild, ampersand }, function()
        for _, q in ipairs({ "guild &", "guild & " }) do
            Database:ResetSearchCache()
            local r = Database:SearchUI(q)
            H.assertEq(r[1] and r[1].data, ampersand, "raw prefix keeps the lead at: " .. q)
        end
        Database:ResetSearchCache()
        local r = Database:SearchUI("& guild")
        H.assertEq(r[1] and r[1].data, bareGuild, "with no raw match at all, the exact cut match leads")
    end)
end

function tests.searchUI_hyphenPrefixKeepsPrefixRank()
    withEntries({ hyphenB, hyphenA }, function()
        Database:ResetSearchCache()
        local r = Database:SearchUI("proto-dra")
        H.assertEq(r[1] and r[1].data, hyphenA, "the hyphenated prefix must rank the prefix match first")
    end)
end

-- The one typo that hits the first letter: the first two swapped.
local moduleControl = { name = "Module Control", nameLower = "module control", category = "AddOn Settings", keywordsLower = {} }
local delverArmor = { name = "Delver's Leather Armor", nameLower = "delver's leather armor", category = "Appearance Set", keywordsLower = {} }

function tests.fuzzy_swappedFirstPairCountsAsOneTypo()
    H.assertEq(Database:ScoreFuzzy("module control", "ocntrol", 7), 85, "swapped first pair")
    H.assertEq(Database:ScoreFuzzy("module control", "xontrol", 7), 0, "a wrong first letter is still not a match")
    withEntries({ moduleControl, delverArmor }, function()
        Database:PrimeSearchGate()
        Database:ResetSearchCache()
        H.assertTrue(findsEntry(Database:SearchUI("module ocntrol"), moduleControl), "module ocntrol")
        Database:ResetSearchCache()
        H.assertTrue(findsEntry(Database:SearchUI("ocntrol"), moduleControl), "ocntrol alone, through the gate")
        Database:ResetSearchCache()
        H.assertTrue(findsEntry(Database:SearchUI("delver's leather ramor"), delverArmor), "ramor")
    end)
end

-- Same name, same score: talents lead, and the order does not depend on
-- which row was added first.
local swipeAbility = { name = "Swipe", nameLower = "swipe", category = "Ability", keywordsLower = {} }
local swipeTalent = { name = "Swipe", nameLower = "swipe", category = "Talent", keywordsLower = {} }

function tests.searchUI_sameNameTieTalentFirstEitherLoadOrder()
    for _, order in ipairs({ { swipeAbility, swipeTalent }, { swipeTalent, swipeAbility } }) do
        withEntries(order, function()
            Database:ResetSearchCache()
            local r = Database:SearchUI("swipe")
            H.assertEq(r[1] and r[1].data, swipeTalent, "talent first")
            H.assertEq(r[2] and r[2].data, swipeAbility, "ability second")
        end)
    end
end

function tests.searchUI_typoInOneWordOfBracketedName()
    withEntries({ bracketed }, function()
        Database:ResetSearchCache()
        H.assertTrue(findsEntry(Database:SearchUI("radis (journal)"), bracketed),
            "one transposition in the first word must still find the bracketed name")
        Database:ResetSearchCache()
        H.assertTrue(findsEntry(Database:SearchUI("raids (jour"), bracketed),
            "a bracketed prefix must match")
    end)
end

-- The catalog's scorer: ScoreName's answer, and no cache entry for the name.
function tests.scoreTransientName_scoresAsScoreNameAndCachesNothing()
    local caches = Database:_DebugPeekSearchCaches()
    local CASES = {
        { "cloak of the black void", "cloak" }, { "black cloak", "cloak" }, { "cloaked hood", "loak" },
        { "the felic", "the" }, { "thelsamar axe", "the" }, { "\"thelsamar\" relic", "the" },
        { "ore-namental sabatons", "ons" }, { "throne of thunder relic", "tot" }, { "shadow bolt rune", "shbo" },
        { "potion of speed", "potoin" }, { "quartermaster's coin", "qtr" }, { "cloak of the void", "cloak of" },
        { "eastern kingdoms map", "estern kingd" }, { "9588bermacht der flamme", "flamme" }, { "x", "zzz" },
    }
    for _, c in ipairs(CASES) do
        local name, q = c[1], c[2]
        local got = Database:ScoreTransientName(name, q, #q)
        H.assertNil(caches.wordCache[name], "no word list cached: " .. name)
        H.assertNil(caches.nameMaskCache[name], "no mask cached: " .. name)
        H.assertNil(caches.wordInitCache[name], "no initials cached: " .. name)
        H.assertEq(got, Database:ScoreName(name, q, #q), name .. " / " .. q)
    end
end

-- Same name and score: what the player holds, then the game's own rows, the
-- catalog, recipes, the addons' settings, an extension's rows last. The Era
-- intent audit had Spoken's Master Volume over the game's, a recipe over the
-- potion, and a fishing catch over the herb.
function tests.sameName_ownThenGameThenCatalogThenAddons()
    ns.Extensions = { ProviderOf = function(d) return d.category == "fishing" and {} or nil end }
    local less = Database.TieCategoryLess
    local function Row(cat) return { category = cat } end
    H.assertTrue(less(Row("Game Settings"), Row("AddOn Settings")), "the game's setting before an addon's")
    H.assertTrue(less(Row("Menu Bar"), Row("AddOn Settings")), "a panel before an addon's setting")
    H.assertTrue(less(Row("Bag"), Row("Item")), "the held item before the catalog's")
    H.assertTrue(less(Row("Bank"), Row("Loot")), "the banked item before a drop")
    H.assertTrue(less(Row("Item"), Row("Profession")), "the item before the recipe that makes it")
    H.assertTrue(less(Row("Item"), Row("fishing")), "the item before an extension's row")
    H.assertTrue(less(Row("AddOn Settings"), Row("fishing")), "every core row before an extension's")
    H.assertTrue(less(Row("Talent"), Row("Bag")), "talents still lead")
    H.assertTrue(not less(Row("Bag"), Row("Bag")), "the same category is no order")
    H.assertTrue(less(Row("Ability"), Row("Macro")) and not less(Row("Macro"), Row("Ability")),
        "other core rows by category name")
    ns.Extensions = nil
end

-- The whole name typed with its words in another order is that name:
-- "depths blackrock" listed 140 Blackrock Depths drops (the loot scorer's
-- 220) over the dungeon (210), the Era audit 2026-11-01.
function tests.scoreName_theWholeNameInAnotherOrder_sitsUnderAPrefixOnly()
    H.assertEq(Database:ScoreName("blackrock depths", "depths blackrock", 16), 495)
    H.assertEq(Database:ScoreName("silk cloth", "cloth silk", 10), 495)
    H.assertTrue(Database:ScoreName("minor healing potion", "potion minor", 11) <= 110, "a longer name holds the words, no more")
    H.assertTrue(Database:ScoreName("blackrock depths", "depth blackrock", 15) <= 110, "a prefix of a word is not the word")
    H.assertEq(Database:ScoreName("blackrock depths", "blackrock dep", 13), 500, "a prefix of the name stays above")
end

function tests.searchUI_aNameInAnotherOrder_beatsTheLootOfWhatItNames()
    local dungeon = { name = "Blackrock Depths", nameLower = "blackrock depths", category = "dungeon", keywordsLower = { "brd" } }
    local ironfoe = { name = "Ironfoe", nameLower = "ironfoe", category = "Loot", lootEntry = true,
        lootSourceKw = { "blackrock", "depths", "brd" } }
    withEntries({ ironfoe, dungeon }, function()
        local res = Database:SearchUI("depths blackrock")
        H.assertEq(scoreOf(res, dungeon), 495)
        H.assertEq(scoreOf(res, ironfoe), 220, "the loot scorer's two source words")
        H.assertEq(res[1].data, dungeon)
    end)
end

-- "brd" tied the dungeon and its bosses at the short keyword's 600 and the
-- shorter names won; "blakcrock depths" scored the bosses' keyword sum
-- (140) over the dungeon's typo-forgiven name: twenty bosses over
-- Blackrock Depths both ways. A boss's instance name is scored as a name.
function tests.searchUI_aBossesInstance_sitsOneUnderTheInstance()
    local dungeon = { name = "Blackrock Depths", nameLower = "blackrock depths", category = "dungeon", keywordsLower = { "brd" } }
    local boss = { name = "Magmus", nameLower = "magmus", category = "Boss",
        instanceNameLower = "blackrock depths", keywordsLower = { "boss", "bosses", "brd" } }
    local ironfoe = { name = "Ironfoe", nameLower = "ironfoe", category = "Loot", lootEntry = true,
        lootSourceKw = { "blackrock", "depths", "brd" } }
    local was = Database.IsInstanceSearchWord
    Database.IsInstanceSearchWord = function(_, w) return w == "brd" or w == "blackrock" or w == "depths" end
    withEntries({ boss, ironfoe, dungeon }, function()
        local res = Database:SearchUI("brd")
        H.assertEq(scoreOf(res, dungeon), 600)
        H.assertEq(scoreOf(res, boss), 599)
        H.assertEq(res[1].data, dungeon)
        Database:ResetSearchCache()
        res = Database:SearchUI("blakcrock depths")
        H.assertEq(scoreOf(res, boss), Database:ScoreName("blackrock depths", "blakcrock depths", 16) - 1)
        H.assertEq(res[1].data, dungeon)
        H.assertEq(res[2].data, boss)
        Database:ResetSearchCache()
        res = Database:SearchUI("blackrock depths")
        H.assertEq(scoreOf(res, boss), 99, "the instance's name typed: a keyword's height, under every name holding it")
        H.assertEq(res[2].data, ironfoe, "its loot before its bosses")
        H.assertEq(res[3].data, boss)
        Database:ResetSearchCache()
        res = Database:SearchUI("magmus")
        H.assertEq(scoreOf(res, boss), 1000, "its own name is its own")
    end)
    Database.IsInstanceSearchWord = was
end

-- A provider row with scopedName answers by name only under its
-- provider's @scope, by keywords everywhere (API MINOR 7: a TSM group's
-- item row doubled EasyFind's own Linen Cloth row, 2026-11-02).
function tests.scopedName_matchesByNameOnlyUnderItsScope()
    local item = { name = "Linen Cloth", nameLower = "linen cloth", category = "TSM", scopedName = true,
        keywordsLower = { "blacksmithing", "bs mats" } }
    local group = { name = "BS Mats", nameLower = "bs mats", category = "TSM" }
    local own = { name = "Linen Cloth", nameLower = "linen cloth", category = "Item" }
    Database.nameScopedCategories.TSM = true
    withEntries({ item, group, own }, function()
        H.assertFalse(findsEntry(Database:SearchUI("linen cloth"), item), "outside its scope: not by name")
        H.assertTrue(findsEntry(Database:SearchUI("linen cloth"), own), "EasyFind's own row stays")
        H.assertTrue(findsEntry(Database:SearchUI("linen cloth", nil, { "TSM" }), item), "under its scope: by name")
        H.assertFalse(findsEntry(Database:SearchUI("linen cloth"), item), "the scoped search's set is not reused")
        H.assertTrue(findsEntry(Database:SearchUI("bs mats"), item), "by its keywords anywhere")
        H.assertTrue(findsEntry(Database:SearchUI("bs mats"), group), "a row without the field keeps its name")
        H.assertFalse(findsEntry(Database:SearchUI("linen blacksmithing"), item), "its name words count for nothing")
        H.assertTrue(findsEntry(Database:SearchUI("linen blacksmithing", nil, { "TSM" }), item), "under its scope they do")
    end)
    Database.nameScopedCategories.TSM = nil
end

-- The scope reaches the scan, and a provider's rows mark their category.
function tests.scopedName_isWiredFromTheScopeAndTheProvider()
    local function Read(path)
        local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
        local src = f:read("*a")
        f:close()
        return src
    end
    local query = Read("Search/Query.lua")
    local _, calls = query:gsub("ns%.Database:SearchUI%(text, skipCategories, quickFilter and quickFilter%.categories%)", "")
    local _, all = query:gsub("ns%.Database:SearchUI%(", "")
    H.assertEq(calls, all, "every search call passes the scope")
    H.assertTrue(Read("Core/API.lua"):find("return database:ReplaceCategoryEntries(p.category, rows, scopedName)", 1, true) ~= nil)
    H.assertTrue(Read("Database/Main.lua"):find("self.nameScopedCategories[category] = scopedName or nil", 1, true) ~= nil)
end

local pass, fail, failures = H.runSuite("Database/Search", tests)
return { pass = pass, fail = fail, failures = failures }
