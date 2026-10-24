-- A search canceled at a slice checkpoint (the last keystroke wins) must
-- leave nothing a later search reuses: the next run of any query finds what
-- a fresh search finds.
local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

local corpus = {}
local function Add(name)
    corpus[#corpus + 1] = { name = name, nameLower = name:lower(), category = "Test" }
end
for i = 1, 200 do Add(("Storm Banner %d"):format(i)) end
for i = 1, 200 do Add(("Shadow Lantern %d"):format(i)) end

-- The checkpoint throws when armed: the scan stops there, as an abandoned
-- coroutine does.
local armed = false
ns.Utils.SliceCheckpoint = function()
    if armed then
        armed = false
        error("canceled")
    end
end

ns.Database.uiSearchData = corpus
ns.Database.IsLootStatSearchWord = function() return false end
ns.Database.IsLootSlotSearchWord = function() return false end
H.loadModule("Shared/SearchText.lua", env, ns)
local Database = H.loadModule("Database/Search.lua", env, ns)
H.loadModule("Database/SearchIndex.lua", env, ns)

-- The rows as one text, and how many.
local function Names(list)
    local t = {}
    for i, r in ipairs(list) do t[i] = r.data.name .. "=" .. r.score end
    table.sort(t)
    return table.concat(t, "|"), #t
end

local function AssertSame(again, againN, fresh, freshN, label)
    H.assertTrue(again == fresh, ("%s: %d rows, a fresh search %d"):format(label, againN, freshN))
end

local tests = {}

-- An append keeps the last query's set (the cache is cleared); a scan
-- canceled after it must not leave its half-written set under that query.
function tests.canceledScan_isNotReusedByTheLastQuery()
    Database:ResetSearchCache()
    Database:SearchUI("shadow")
    Add("Shadow Lantern 201")
    Database:NoteAppendedEntries(#corpus)
    Database._disableSearchGate = true
    armed = true
    local ok = pcall(Database.SearchUI, Database, "storm")
    armed = false
    Database._disableSearchGate = nil
    H.assertFalse(ok, "the storm scan was canceled at its checkpoint")
    local again, againN = Names(Database:SearchUI("shadow"))
    Database:ResetSearchCache()
    local fresh, freshN = Names(Database:SearchUI("shadow"))
    AssertSame(again, againN, fresh, freshN, "shadow after a canceled scan")
end

function tests.canceledScan_thenSameQuery_findsTheFreshSet()
    Database:ResetSearchCache()
    Database:SearchUI("storm")
    Database._disableSearchGate = true
    armed = true
    pcall(Database.SearchUI, Database, "storm banner")
    armed = false
    Database._disableSearchGate = nil
    local again, againN = Names(Database:SearchUI("storm banner"))
    Database:ResetSearchCache()
    local fresh, freshN = Names(Database:SearchUI("storm banner"))
    AssertSame(again, againN, fresh, freshN, "storm banner after its own canceled scan")
end

-- A run dropped inside the index's dictionary walk holds the index build
-- until the dispatcher tells the index the read is over.
function tests.canceledIndexRead_holdsTheBuildUntilReleased()
    local env2 = H.newEnv()
    local ns2 = H.newNs(env2)
    local words = {}
    local letters = "abcdefghijklmnopqrstuvwxyz"
    for i = 0, 599 do
        local a, b = i % 26 + 1, math.floor(i / 26) % 26 + 1
        words[#words + 1] = { name = "Z" .. letters:sub(b, b) .. letters:sub(a, a) .. "q Relic",
            nameLower = "z" .. letters:sub(b, b) .. letters:sub(a, a) .. "q relic", category = "Test" }
    end
    local stop = false
    ns2.Utils.SliceCheckpoint = function()
        if stop then
            stop = false
            error("canceled")
        end
    end
    ns2.Database.uiSearchData = words
    ns2.Database.IsLootStatSearchWord = function() return false end
    ns2.Database.IsLootSlotSearchWord = function() return false end
    H.loadModule("Shared/SearchText.lua", env2, ns2)
    local Db = H.loadModule("Database/Search.lua", env2, ns2)
    H.loadModule("Database/SearchIndex.lua", env2, ns2)
    local Index = ns2.SearchIndex
    Db:SearchUI("zaaq")
    local built = Index:_DebugPeek().builtCount
    H.assertEq(built, #words, "index built")
    stop = true
    H.assertFalse(pcall(Db.SearchUI, Db, "zxyw"), "the read was canceled in the dictionary walk")
    stop = false
    words[#words + 1] = { name = "Zzzq Relic", nameLower = "zzzq relic", category = "Test" }
    H.assertFalse(Index:EnsureBudget(5), "a canceled read holds the build")
    Index:ReadCanceled()
    H.assertTrue(Index:EnsureBudget(5), "released, the build catches up")
    H.assertEq(Index:_DebugPeek().builtCount, #words, "the appended entry is indexed")
end

local pass, fail, failures = H.runSuite("SearchCancel", tests)
return { pass = pass, fail = fail, failures = failures }
