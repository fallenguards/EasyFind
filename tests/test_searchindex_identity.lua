-- The index must never change what a search finds: every query here runs
-- through the index (gated) and the full scan (ungated) and the two result
-- lists must match entry for entry and score for score. Typos, swapped
-- first pairs, abbreviations, initials across punctuation and whole
-- keywords are the classes the index serves without contiguous bigrams.
local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

local corpus = {}
local function Add(name, keywords, category)
    corpus[#corpus + 1] = { name = name, nameLower = name:lower(), category = category or "Test",
        keywordsLower = keywords }
end

local FIRST = { "Shadow", "Storm", "Gladiator's", "Swift", "Ancient", "Crimson", "Frost", "Iron", "Golden",
    "Twilight", "Raging", "Silver", "Ebon", "Thunder", "Blood", "Wind" }
local SECOND = { "Bolt", "Rider", "Drake", "Bulwark", "Lantern", "Banner", "Chair", "Wolf", "Kingdoms",
    "Barrens", "Volume", "Quality", "Ring", "Tabard", "Rug", "Bookshelf" }
for i = 1, #FIRST do
    for j = 1, #SECOND do
        if (i + j) % 3 ~= 0 then Add(FIRST[i] .. " " .. SECOND[j]) end
    end
end
Add("Shadow-Bolt Ring", { "pvp-rated", "ring" })
Add("Raids (Journal)", { "journal" })
Add("Pattern: Sunfire Sash", { "tailoring" })
Add("Kel'Thuzad", { "naxxramas", "lich" })
Add("Master Volume", { "sound", "audio" })
Add("Eastern Kingdoms", { "continent", "azeroth" })
Add("Throne of Thunder", { "raid" })
Add("Quartermaster", { "vendor", "reputation" })
Add("Windrunner Spire", { "dungeon" })
Add("R-2 Boom Bot", { "toy" })
Add("Hearthstone", { "toy", "home" })
-- Stop words: whole, leading a longer word, inside one, in keywords only,
-- on statistics and bosses.
Add("Mountain Inn", { "rest" })
Add("Raining Stone", { "weather" })
Add("Kingdom of the Ancients", { "lore" })
Add("The Infinite Archive", { "dungeon", "dawn of the infinite" })
Add("Dungeons & Raids", { "group finder" })
Add("Brawler's Guild Contender", { "information" })
Add("Deaths in Raids", nil, "Statistic")
Add("Twin Consorts", nil, "Statistic")
Add("Onyxia", { "lair" }, "Boss")
Add("Garrosh Hellscream", { "siege of orgrimmar" }, "Boss")
Add("Fishing Raft", { "toy", "on water" })
Add("Ancient Tome of Teleport: Dalaran", { "portal" })
Add("Ornate Lantern", { "vendor" })
Add("Feathers Collected", nil, "Statistic")
Add("Weathered Relics", nil, "Achievement Category")
Add("Sandfury Executioner", nil, "Boss")
Add("Brandished Banner", { "standard" })

ns.Database.uiSearchData = corpus
ns.Database.IsLootStatSearchWord = function() return false end
ns.Database.IsLootSlotSearchWord = function() return false end
H.loadModule("Shared/SearchText.lua", env, ns)
local Database = H.loadModule("Database/Search.lua", env, ns)
H.loadModule("Database/SearchIndex.lua", env, ns)

local QUERIES = {
    "shadwo", "hsadow", "shdw", "gldtr", "gladiaotr", "sbr", "srb", "sb", "rj", "pvprated", "pvp rated",
    "kelthuzad", "kel'thuzd", "mastr volume", "master vlume", "estern kingdoms", "eastern kingdms",
    "tot", "throne thnder", "qtr", "qrtrmstr", "windrnr", "wndrunner", "r2", "boom bot", "hearthstnoe",
    "hsearthstone", "patern sunfire", "sunfier", "journl", "raid journal", "stb", "frst wolf", "ib",
    "twilgiht drake", "thudner", "crmsn", "gb", "sw", "silvr", "ebn", "blod rug", "winb", "ancent lantern",
    -- Prefix walks: two or more 2+ char segments, each leading a later word.
    "shbo", "shabo", "stdr", "frwo", "sibo", "glbu", "thdr", "twdr", "ebwo", "crdr", "raba",
    -- Bare stop words and the words they lead.
    "in", "inn", "on", "ony", "the", "of", "an", "anc", "and", "at", "for", "with", "to", "or", "orn", "a",
}

local function Run(gated, q)
    Database._disableSearchGate = not gated or nil
    Database:ResetSearchCache()
    local out = {}
    for i, r in ipairs(Database:SearchUI(q)) do out[i] = { data = r.data, score = r.score } end
    return out
end

local tests = {}

function tests.everyQuery_findsTheSameThroughTheIndex()
    local bad, found = {}, 0
    for _, q in ipairs(QUERIES) do
        local g, u = Run(true, q), Run(false, q)
        local same = #g == #u
        for i = 1, same and #g or 0 do
            if g[i].data ~= u[i].data or g[i].score ~= u[i].score then same = false end
        end
        if not same then bad[#bad + 1] = ("'%s' indexed %d, full scan %d"):format(q, #g, #u) end
        if #u > 0 then found = found + 1 end
    end
    Database._disableSearchGate = nil
    H.assertTrue(found > #QUERIES / 2, "most queries find something: " .. found)
    H.assertTrue(#bad == 0, table.concat(bad, "\n"))
end

-- A query typed a letter at a time finds what the same query pasted finds:
-- each keystroke's list equals a fresh search of that text.
function tests.typedQueries_findWhatPastedQueriesFind()
    local bad = {}
    for _, q in ipairs(QUERIES) do
        Database._disableSearchGate = nil
        Database:ResetSearchCache()
        for n = 1, #q - 1 do Database:SearchUI(q:sub(1, n)) end
        local typed = {}
        for i, r in ipairs(Database:SearchUI(q)) do typed[i] = { data = r.data, score = r.score } end
        local pasted = Run(true, q)
        local same = #typed == #pasted
        for i = 1, same and #typed or 0 do
            if typed[i].data ~= pasted[i].data or typed[i].score ~= pasted[i].score then same = false end
        end
        if not same then bad[#bad + 1] = ("'%s' typed %d, pasted %d"):format(q, #typed, #pasted) end
    end
    H.assertTrue(#bad == 0, table.concat(bad, "\n"))
end

-- The early stop skips the index's rest rows once the kept rows outscore
-- them; that is only exact while no rest row can score above 30.
function tests.restRows_neverScoreAboveAMidWordSubstring()
    Database._checkRestBound = true
    Database._restMaxSeen = 0
    for _, q in ipairs(QUERIES) do
        Database:ResetSearchCache()
        Database:SearchUI(q)
        for n = 2, #q - 1 do
            Database:ResetSearchCache()
            Database:SearchUI(q:sub(1, n))
        end
    end
    Database._checkRestBound = nil
    H.assertTrue(Database._restMaxSeen <= 30, ("a rest row scored %s (%s)"):format(
        tostring(Database._restMaxSeen), tostring(Database._restMaxRow)))
end

-- The walk class is only admitted with a second word lead; each of these
-- reaches its row by the walk alone, through the index.
function tests.prefixWalks_reachTheirRowThroughTheIndex()
    local WALKS = { shbo = "Shadow Bolt", frdr = "Frost Drake", sibo = "Silver Bookshelf", twdr = "Twilight Drake" }
    for q, name in pairs(WALKS) do
        local hit = false
        for _, r in ipairs(Run(true, q)) do
            if r.data.name == name then hit = true end
        end
        H.assertTrue(hit, q .. " finds " .. name)
    end
end

local pass, fail, failures = H.runSuite("SearchIndexIdentity", tests)
return { pass = pass, fail = fail, failures = failures }
