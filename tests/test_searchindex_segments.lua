-- Saved index segments must never change what a search finds: an index built
-- as segments, one restored from their snapshots (through a SavedVariables
-- style round trip), and one with a segment dropped and rebuilt all return
-- exactly what one index over the same rows returns.
local H = require("Harness")

local FIRST = { "Shadow", "Storm", "Gladiator's", "Swift", "Ancient", "Crimson", "Frost", "Iron", "Golden",
    "Twilight", "Raging", "Silver", "Ebon", "Thunder", "Blood", "Wind" }
local SECOND = { "Bolt", "Rider", "Drake", "Bulwark", "Lantern", "Banner", "Chair", "Wolf", "Kingdoms",
    "Barrens", "Volume", "Quality", "Ring", "Tabard", "Rug", "Bookshelf" }
local CATS = { "Mount", "Toy", "Test" }

-- Fresh row tables each call, the same content in the same order: Mount
-- rows, then Toy rows, then the rest.
local function Corpus()
    local groups = { {}, {}, {} }
    for i = 1, #FIRST do
        for j = 1, #SECOND do
            if (i + j) % 3 ~= 0 then
                local g = (i * 7 + j) % 3 + 1
                local name = FIRST[i] .. " " .. SECOND[j]
                local list = groups[g]
                list[#list + 1] = { name = name, nameLower = name:lower(), category = CATS[g] }
            end
        end
    end
    local function Add(g, name, kws)
        local list = groups[g]
        list[#list + 1] = { name = name, nameLower = name:lower(), category = CATS[g], keywordsLower = kws }
    end
    Add(1, "Shadow-Bolt Ring", { "pvp-rated", "ring" })
    Add(2, "Raids (Journal)", { "journal" })
    Add(3, "Pattern: Sunfire Sash", { "tailoring" })
    Add(1, "Kel'Thuzad", { "naxxramas", "lich" })
    Add(2, "Master Volume", { "sound", "audio" })
    Add(3, "Eastern Kingdoms", { "continent", "azeroth" })
    Add(1, "Throne of Thunder", { "raid" })
    Add(2, "Quartermaster", { "vendor", "reputation" })
    Add(1, "Windrunner Spire", { "dungeon" })
    Add(2, "R-2 Boom Bot", { "toy" })
    Add(3, "Hearthstone", { "toy", "home" })
    Add(1, "\195\156bermacht Rider", { "mount" })
    local all = {}
    for g = 1, 3 do for _, r in ipairs(groups[g]) do all[#all + 1] = r end end
    return all, groups[1], groups[2]
end

-- prep(ns), when given, runs before the modules load.
local function NewEngine(rows, prep)
    local env = H.newEnv()
    local ns = H.newNs(env)
    if prep then prep(ns) end
    ns.Database.uiSearchData = rows
    ns.Database.IsLootStatSearchWord = function() return false end
    ns.Database.IsLootSlotSearchWord = function() return false end
    H.loadModule("Shared/SearchText.lua", env, ns)
    local Database = H.loadModule("Database/Search.lua", env, ns)
    H.loadModule("Database/SearchIndex.lua", env, ns)
    return Database, ns.SearchIndex, env
end

local QUERIES = {
    "shadwo", "hsadow", "shdw", "gldtr", "gladiaotr", "sbr", "srb", "sb", "rj", "pvprated", "pvp rated",
    "kelthuzad", "kel'thuzd", "mastr volume", "master vlume", "estern kingdoms", "eastern kingdms",
    "tot", "throne thnder", "qtr", "qrtrmstr", "windrnr", "wndrunner", "r2", "boom bot", "hearthstnoe",
    "patern sunfire", "sunfier", "journl", "raid journal", "stb", "frst wolf", "ib", "twilgiht drake",
    "thudner", "crmsn", "gb", "sw", "silvr", "ebn", "blod rug", "shbo", "stdr", "frwo", "raba",
    "rider", "ubermacht", "mount", "toy", "wolf", "drake",
}

-- Every query and every prefix of it, as name=score lists.
local function Run(Database, gated)
    Database._disableSearchGate = not gated or nil
    local out = {}
    for _, q in ipairs(QUERIES) do
        for k = 1, #q do
            local sub = q:sub(1, k)
            Database:ResetSearchCache()
            local rows = {}
            for i, r in ipairs(Database:SearchUI(sub)) do rows[i] = r.data.name .. "=" .. r.score end
            out[#out + 1] = sub .. ": " .. table.concat(rows, "|")
        end
    end
    Database._disableSearchGate = nil
    return out
end

local function Same(a, b, label)
    H.assertEq(#a, #b, label .. " query count")
    for i = 1, #a do
        if a[i] ~= b[i] then
            H.assertEq(b[i], a[i], label)
            return
        end
    end
end

-- A SavedVariables-style round trip: strings quoted, tables rebuilt.
local function Serialize(v)
    if type(v) == "string" then return string.format("%q", v) end
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    for k, x in pairs(v) do
        local key = type(k) == "string" and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
        parts[#parts + 1] = key .. "=" .. Serialize(x)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end
local function RoundTrip(v)
    return assert(load("return " .. Serialize(v)))()
end

local tests = {}

local baseRows = Corpus()
local baseDatabase = NewEngine(baseRows)
local BASE = Run(baseDatabase, true)

function tests.builtSegments_findWhatOneIndexFinds()
    local rows, mounts, toys = Corpus()
    local Database, Index = NewEngine(rows)
    Index:BuildSegment("mount", mounts)
    Index:BuildSegment("toy", toys)
    H.assertEq(#Index:_DebugPeek().segments, 3, "two saved segments and live")
    Same(BASE, Run(Database, true), "segments, gated")
    Same(BASE, Run(Database, false), "segments, full scan")
end

-- Rows live already indexed, taken over by a segment, are found once.
function tests.segmentOverLiveRows_findsTheSame()
    local rows, mounts = Corpus()
    local Database, Index = NewEngine(rows)
    Run(Database, true)
    Index:BuildSegment("mount", mounts)
    Same(BASE, Run(Database, true), "after taking over live rows")
end

function tests.restoredSegments_findWhatOneIndexFinds()
    local rows, mounts, toys = Corpus()
    local _, Index = NewEngine(rows)
    Index:BuildSegment("mount", mounts)
    Index:BuildSegment("toy", toys)
    local snapM, snapT = Index:SegmentSnapshot("mount"), Index:SegmentSnapshot("toy")
    H.assertNotNil(snapM, "mount snapshot")
    -- Packed strings hold printable bytes only (words and check are text).
    for _, snap in ipairs({ snapM, snapT }) do
        for k, v in pairs(snap) do
            local strings = type(v) == "table" and v or { v }
            for _, s in pairs(strings) do
                if type(s) == "string" and k ~= "words" and k ~= "check" then
                    H.assertFalse(s:find("[^\35-\126]") ~= nil, "printable " .. k)
                end
            end
        end
    end
    local rows2, mounts2, toys2 = Corpus()
    local Database2, Index2 = NewEngine(rows2)
    H.assertTrue(Index2:RestoreSegment("mount", RoundTrip(snapM), mounts2), "mount restores")
    H.assertTrue(Index2:RestoreSegment("toy", RoundTrip(snapT), toys2), "toy restores")
    Same(BASE, Run(Database2, true), "restored, gated")
    Same(BASE, Run(Database2, false), "restored, full scan")
    -- A snapshot that does not fit its rows is refused.
    local _, mounts3 = Corpus()
    table.remove(mounts3)
    local _, Index3 = NewEngine(rows2)
    H.assertFalse(Index3:RestoreSegment("mount", snapM, mounts3), "a row short is refused")
    -- Rows that shifted (one swapped for another) are refused too.
    local _, mounts4 = Corpus()
    mounts4[1], mounts4[2] = mounts4[2], mounts4[1]
    local _, Index4 = NewEngine(rows2)
    H.assertFalse(Index4:RestoreSegment("mount", snapM, mounts4), "shifted rows are refused")
end

function tests.droppedAndRebuiltSegment_findsTheSame()
    local rows, mounts, toys = Corpus()
    local Database, Index = NewEngine(rows)
    Index:BuildSegment("mount", mounts)
    Index:BuildSegment("toy", toys)
    Run(Database, true)
    -- Dropped while its rows stay: they index into live.
    H.assertTrue(Index:DropSegment("toy"), "toy drops")
    Same(BASE, Run(Database, true), "after a drop")
    -- Rebuilt over fresh row objects swapped into the same places.
    local _, _, toys2 = Corpus()
    local at = {}
    for i, r in ipairs(rows) do if r.category == "Toy" then at[#at + 1] = i end end
    for k, i in ipairs(at) do
        Index:NoteRemoved(rows[i])
        rows[i] = toys2[k]
    end
    Index:BuildSegment("toy", toys2)
    Same(BASE, Run(Database, true), "after a rebuild")
    -- A row of a saved segment dying makes its snapshot unusable.
    Index:NoteRemoved(toys2[1])
    H.assertNil(Index:SegmentSnapshot("toy"), "no snapshot of a segment with a dead row")
end

local function MountSnapshot()
    local rows, mounts = Corpus()
    local _, Index = NewEngine(rows)
    Index:BuildSegment("mount", mounts)
    return RoundTrip(Index:SegmentSnapshot("mount"))
end

local function NoLiveSerials(Index, list, label)
    local peek = Index:_DebugPeek()
    for _, r in ipairs(list) do H.assertNil(peek.serials[r], label .. ": " .. r.name) end
end

-- A held category's rows wait for their segment: searches still find
-- them, and the restore finds live holding none of them to purge.
function tests.heldRows_waitForTheirSegment_andStayFound()
    local rows, mounts, toys = Corpus()
    local Database, Index, env = NewEngine(rows)
    Index:Hold("Mount")
    Same(BASE, Run(Database, true), "found while held")
    NoLiveSerials(Index, mounts, "not indexed while held")
    H.assertTrue(Index:RestoreSegment("mount", MountSnapshot(), mounts), "restores")
    Index:Unhold("Mount")
    env._clock:advance(0)
    H.assertNotNil(Index:_DebugPeek().serials[toys[1]], "growth went on past them")
    Same(BASE, Run(Database, true), "after the restore")
    H.assertEq(Index:_DebugPeek().deadCount, 0, "live had nothing of theirs to purge")
end

function tests.aHoldEndsOnItsOwn()
    local rows, mounts = Corpus()
    local Database, Index, env = NewEngine(rows)
    Index:Hold("Mount")
    Run(Database, true)
    NoLiveSerials(Index, mounts, "held")
    env._clock:advance(16)
    Run(Database, true)
    H.assertNotNil(Index:_DebugPeek().serials[mounts[1]], "indexed once the hold ran out")
    Same(BASE, Run(Database, true), "after the hold")
end

-- A build pauses part way: the rows it moved have no postings anyone reads
-- yet, and searches still find them.
function tests.rowsPartWayThroughABuild_stayFound()
    local held
    local rows, mounts = Corpus()
    local Database, Index = NewEngine(rows, function(ns)
        ns.Utils.SliceCheckpoint = function()
            if coroutine.isyieldable() then coroutine.yield() end
        end
        local run = ns.Utils.RunSliced
        ns.Utils.RunSliced = function(fn, onDone, budget, label)
            if label ~= "indexSegment" then return run(fn, onDone, budget, label) end
            held = { co = coroutine.create(fn), onDone = onDone }
        end
    end)
    Run(Database, true)
    Index:BuildSegment("mount", mounts)
    assert(coroutine.resume(held.co))
    H.assertEq(coroutine.status(held.co), "suspended", "the build paused")
    H.assertTrue(#mounts > 4, "it moved some rows, not all")
    Same(BASE, Run(Database, true), "part way through the build")
    while coroutine.status(held.co) ~= "dead" do assert(coroutine.resume(held.co)) end
    held.onDone(true)
    Same(BASE, Run(Database, true), "once it landed")
end

local pass, fail, failures = H.runSuite("SearchIndexSegments", tests)
return { pass = pass, fail = fail, failures = failures }
