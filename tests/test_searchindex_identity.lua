-- The index must never change what a search finds: every query here runs
-- through the index (gated) and the full scan (ungated) and the two result
-- lists must match entry for entry and score for score. Typos, swapped
-- first pairs, abbreviations, initials across punctuation and whole
-- keywords are the classes the index serves without contiguous bigrams.
local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

local corpus = {}
local function Add(name, keywords)
    corpus[#corpus + 1] = { name = name, nameLower = name:lower(), category = "Test", keywordsLower = keywords }
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

local pass, fail, failures = H.runSuite("SearchIndexIdentity", tests)
return { pass = pass, fail = fail, failures = failures }
