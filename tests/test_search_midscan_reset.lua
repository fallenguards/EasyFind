-- Search data that changes while a scan waits at a slice checkpoint (a
-- provider finishing, the close trim) must not leave that scan's set under
-- its query: the coalesced rerun of the same query finds what a fresh
-- search finds, and never reads a missing row.
local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

local corpus = {}
local function Add(name)
    corpus[#corpus + 1] = { name = name, nameLower = name:lower(), category = "Test" }
end
for i = 1, 200 do Add(("Storm Banner %d"):format(i)) end
for i = 1, 200 do Add(("Shadow Lantern %d"):format(i)) end

-- Runs once at the scan's next checkpoint: what another frame did while
-- the coroutine waited there.
local during
ns.Utils.SliceCheckpoint = function()
    local fn = during
    if fn then
        during = nil
        fn()
    end
end

ns.Database.uiSearchData = corpus
ns.Database.IsLootStatSearchWord = function() return false end
ns.Database.IsLootSlotSearchWord = function() return false end
ns.Database.UnloadDynamicSearchData = function() end
ns.Utils.ShedCorpora = function() end
H.loadModule("Shared/SearchText.lua", env, ns)
local Database = H.loadModule("Database/Search.lua", env, ns)
H.loadModule("Database/SearchIndex.lua", env, ns)

local function Names(list)
    local t = {}
    for i, r in ipairs(list) do t[i] = r.data.name .. "=" .. r.score end
    table.sort(t)
    return table.concat(t, "|"), #t
end

-- The query again after the interrupted scan, against a fresh search.
local function AssertRerunFresh(query, label)
    local ok, again, againN = pcall(function() return Names(Database:SearchUI(query)) end)
    H.assertTrue(ok, label .. ": the rerun read every row (" .. tostring(again) .. ")")
    if not ok then return end
    Database:ResetSearchCache()
    local fresh, freshN = Names(Database:SearchUI(query))
    H.assertTrue(again == fresh, ("%s: %d rows, a fresh search %d"):format(label, againN, freshN))
end

-- The same query twice: the second scan reads the set the first left.
local function ScanWith(query, fn)
    Database:ResetSearchCache()
    Database:SearchUI(query)
    Database._disableSearchGate = true
    during = fn
    Database:SearchUI(query)
    during = nil
    Database._disableSearchGate = nil
end

local tests = {}

function tests.resetMidScan_rerunIsFresh()
    ScanWith("storm", function() Database:ResetSearchCache() end)
    AssertRerunFresh("storm", "storm after a reset mid-scan")
end

function tests.resetMidFullScan_rerunIsFresh()
    Database:ResetSearchCache()
    Database._disableSearchGate = true
    during = function() Database:ResetSearchCache() end
    Database:SearchUI("storm")
    during = nil
    Database._disableSearchGate = nil
    AssertRerunFresh("storm", "storm after a reset mid full scan")
end

function tests.trimMidScan_rerunIsFresh()
    ScanWith("storm", function() Database:TrimSearchMemory() end)
    AssertRerunFresh("storm", "storm after the close trim mid-scan")
end

-- Rows appended while the scan waited are past its set: the rerun has them.
function tests.appendMidScan_rerunFindsTheNewRow()
    ScanWith("storm", function()
        Add("Storm Banner 201")
        Database:NoteAppendedEntries({ corpus[#corpus] })
    end)
    AssertRerunFresh("storm", "storm after an append mid-scan")
    local _, n = Names(Database:SearchUI("storm"))
    H.assertTrue(n > 0, "storm finds rows")
end

-- The close trim inside the index's dictionary walk leaves that read its
-- scratch: the run finds what a fresh search finds.
function tests.trimMidIndexRead_runIsFresh()
    local env2 = H.newEnv()
    local ns2 = H.newNs(env2)
    local words = {}
    local letters = "abcdefghijklmnopqrstuvwxyz"
    for i = 0, 599 do
        local a, b = i % 26 + 1, math.floor(i / 26) % 26 + 1
        local w = "z" .. letters:sub(b, b) .. letters:sub(a, a) .. "q"
        words[#words + 1] = { name = w .. " Relic", nameLower = w .. " relic", category = "Test" }
    end
    local trimAt
    ns2.Utils.SliceCheckpoint = function()
        local fn = trimAt
        if fn then
            trimAt = nil
            fn()
        end
    end
    ns2.Database.uiSearchData = words
    ns2.Database.IsLootStatSearchWord = function() return false end
    ns2.Database.IsLootSlotSearchWord = function() return false end
    ns2.Database.UnloadDynamicSearchData = function() end
    ns2.Utils.ShedCorpora = function() end
    H.loadModule("Shared/SearchText.lua", env2, ns2)
    local Db = H.loadModule("Database/Search.lua", env2, ns2)
    H.loadModule("Database/SearchIndex.lua", env2, ns2)
    Db:SearchUI("zaaq")
    local fresh, freshN = Names(Db:SearchUI("zbaq"))
    Db:TrimSearchMemory()
    Db:SearchUI("zaaq")
    trimAt = function() Db:TrimSearchMemory() end
    local got, gotN = Names(Db:SearchUI("zbaq"))
    H.assertTrue(trimAt == nil, "the trim ran inside the read")
    H.assertTrue(got == fresh, ("zbaq with the trim mid-read: %d rows, a fresh search %d"):format(gotN, freshN))
end

local pass, fail, failures = H.runSuite("SearchMidScanReset", tests)
return { pass = pass, fail = fail, failures = failures }
