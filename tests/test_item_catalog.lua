-- The item catalog (Apps/Items/ItemSearch.lua): both shipped blobs stay in
-- byte order, and a search returns what scoring every name holding the query
-- would (ScoreName, then the shorter name, then alphabetical).

local H = require("Harness")

local ROOT = H.ADDON_ROOT
local KEEP = 32
-- Mid-word matches past the scan cap are not all scored; rows above this
-- must all be there.
local CAPPED_TIER_MAX = 60

local function BlobOf(path)
    local fh = assert(io.open(ROOT .. "/" .. path, "rb"))
    local src = fh:read("*a")
    fh:close()
    local i = assert(src:find("ns.ITEM_SEARCH_BLOB = [[\n", 1, true), "blob start in " .. path)
    local from = i + #"ns.ITEM_SEARCH_BLOB = [[\n"
    local to = assert(src:find("\n]]", from, true), "blob end in " .. path)
    return src:sub(from, to - 1)
end

-- A fresh catalog over `blob` (nil: the shipped retail one) and its scorer.
local function NewCatalog(blob)
    local env = H.newEnv()
    local ns = H.newNs(env)
    ns.Database.uiSearchData = {}
    ns.Database.IsLootStatSearchWord = function() return false end
    ns.Database.IsLootSlotSearchWord = function() return false end
    H.loadModule("Shared/SearchText.lua", env, ns)
    local Database = H.loadModule("Database/Search.lua", env, ns)
    env.EasyFind._ns = ns
    env.C_Item = { GetItemInfoInstant = function() return 1 end }
    env.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
    if blob then ns.ITEM_SEARCH_BLOB = blob else H.loadModule("Apps/Items/Data.lua", env, ns) end
    local ItemSearch = H.loadModule("Apps/Items/ItemSearch.lua", env, ns)
    -- The catalog scores as the bar does; the oracle below uses ScoreName.
    local function Score(nameLower, ql, qLen) return Database:ScoreTransientName(nameLower, ql, qLen) end
    local function Plain(nameLower, ql, qLen) return Database:ScoreName(nameLower, ql, qLen) end
    return ItemSearch, Score, ns.ITEM_SEARCH_BLOB, Plain
end

local function Oracle(blob, ql, Score)
    local rows, seen, pos = {}, {}, 1
    while true do
        local s = blob:find(ql, pos, true)
        if not s then break end
        local ls = s
        while ls > 1 and blob:byte(ls - 1) ~= 10 do ls = ls - 1 end
        local le = blob:find("\n", s, true) or (#blob + 1)
        if not seen[ls] then
            seen[ls] = true
            local name = blob:sub(ls, le - 1):match("^([^\t]+)")
            local sc = Score(name, ql, #ql)
            if sc > 0 then rows[#rows + 1] = { score = sc, name = name } end
        end
        pos = le + 1
    end
    table.sort(rows, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if #a.name ~= #b.name then return #a.name < #b.name end
        return a.name < b.name
    end)
    for i = #rows, KEEP + 1, -1 do rows[i] = nil end
    return rows
end

local function Above(list, field)
    local t = {}
    for i = 1, #list do
        local r = list[i]
        local sc = r.score
        if sc > CAPPED_TIER_MAX then t[#t + 1] = sc .. " " .. (field and r.data.nameLower or r.name) end
    end
    return table.concat(t, "|")
end

local function AssertMatchesOracle(ItemSearch, Score, blob, q, label, Plain)
    local got = ItemSearch:Search(q, Score) or {}
    H.assertEq(Above(got, true), Above(Oracle(blob, q, Plain or Score)), (label or "") .. q)
end

local tests = {}

function tests.shippedBlobs_areInByteOrder()
    for _, path in ipairs({ "Apps/Items/Data.lua", "Apps/Items/Data_Forever.lua" }) do
        local blob = BlobOf(path)
        local prev, n = nil, 0
        for line in blob:gmatch("[^\n]+") do
            n = n + 1
            if prev and line < prev then
                H.assertTrue(false, ("%s line %d sorts before the one above it: %q"):format(path, n, line:sub(1, 40)))
                return
            end
            -- RecordAt looks back at most 100 bytes for a line start.
            local tab = line:find("\t", 1, true)
            H.assertTrue(tab and tab <= 100, ("%s line %d: name of 100 bytes or more"):format(path, n))
            prev = line
        end
        H.assertTrue(n > 1000, path .. " holds the catalog")
    end
end

-- Lua's < on strings follows the C locale here; the catalog's binary search
-- compares bytes. Names with bytes above 127 must sort the same both ways.
function tests.byteOrder_isLuaStringOrder()
    H.assertTrue("\"x" < "(x" and "(x" < "0x" and "[x" < "ax" and "zz" < "\195\169", "byte order")
end

local SYNTH = {
    "\"thelsamar\" relic", "(lucky) charm", "cloak", "cloak of fire", "cloak of rot", "cloaked hood",
    "dark cloak", "thelsamar axe", "the black book", "torn cloak-of-shadows", "wax ingot",
}
for i = 1, 40 do SYNTH[#SYNTH + 1] = ("cloak%02d"):format(i) end

local function SynthBlob()
    local lines = {}
    for i, name in ipairs(SYNTH) do lines[i] = ("%s\t%d\t2\t0\t10\t4\t0"):format(name, 1000 + i) end
    table.sort(lines)
    return table.concat(lines, "\n")
end

function tests.synthetic_everyQueryMatchesTheOracle()
    local ItemSearch, Score, blob, Plain = NewCatalog(SynthBlob())
    for _, q in ipairs({ "cloak", "clo", "the", "thel", "luck", "lucky", "shadows", "of fire", "cloak of",
        "ingot", "wax", "rot", "ked", "zzz" }) do
        AssertMatchesOracle(ItemSearch, Score, blob, q, "fresh ", Plain)
    end
end

function tests.synthetic_typedMatchesPasted()
    local ItemSearch, Score, blob, Plain = NewCatalog(SynthBlob())
    for _, word in ipairs({ "thelsamar", "cloaked", "shadows", "cloak of rot", "lucky" }) do
        for k = 3, #word do
            AssertMatchesOracle(ItemSearch, Score, blob, word:sub(1, k), "typed ", Plain)
        end
    end
end

-- A name led by punctuation starts at its first word for a stopword query.
function tests.synthetic_quotedNameCountsAsANameStart()
    local ItemSearch, Score = NewCatalog(SynthBlob())
    local found
    for _, r in ipairs(ItemSearch:Search("the", Score) or {}) do
        if r.data.nameLower == "\"thelsamar\" relic" then found = r.score end
    end
    H.assertEq(found, Score("\"thelsamar\" relic", "the", 3), "quoted name scored as the scorer does")
end

function tests.shippedCatalog_matchesTheOracle()
    local ItemSearch, Score, blob, Plain = NewCatalog(nil)
    -- Exact names, prefix runs past the old cap, word starts deep in the
    -- alphabet, two words, a rare word, punctuation-led names.
    for _, q in ipairs({ "boots", "ring", "cloak", "staff", "potion of", "cloak of the", "lad", "and",
        "thunderfury", "lucky", "ancient", "the", "ingot", "eternal fire" }) do
        ItemSearch:Search("zzzq", Score)
        AssertMatchesOracle(ItemSearch, Score, blob, q, "pasted ", Plain)
    end
    for _, word in ipairs({ "boots", "ingot", "thunderfury" }) do
        ItemSearch:Search("zzzq", Score)
        for k = 3, #word do
            AssertMatchesOracle(ItemSearch, Score, blob, word:sub(1, k), "typed ", Plain)
        end
    end
end

local pass, fail, failures = H.runSuite("ItemCatalog", tests)
return { pass = pass, fail = fail, failures = failures }
