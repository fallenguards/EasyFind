-- The bands the search bar's list is built from (Search/Query.lua), read
-- from the source the way the file's other guards are: the local-category
-- boost never lowers a row's natural score, an extension's launcher hit on
-- one of its words sits under an exact name, and a row that is the item
-- keeps the catalog's copy out. The Era intent audit found "bank voucher"
-- over the Bank, Auctionator over the Auction House, and every held or
-- dropped item twice.
local H = require("Harness")

local function Source(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local src = Source("Search/Query.lua")
local tests = {}

local function Constant(name)
    return tonumber(src:match("local " .. name .. " = ([%d%.e]+)"))
end

function tests.categoryBoost_keepsAHigherNaturalScore()
    local boost = assert(src:find("local natural = wipe(SCRATCH.mapNaturalScore)", 1, true), "the natural scores are gathered")
    local lift = assert(src:find("if own and own > score then score = own end", boost, true), "the band only lifts")
    H.assertTrue(lift - boost < 1200, "the lift sits inside the boost loop")
    H.assertTrue(src:find("natural[MapRowKey(r.data)] = r.score or 0", 1, true) ~= nil, "keyed like the dedupe")
end

function tests.launcherWord_sitsBetweenPrefixAndExactName()
    local word, name = Constant("LAUNCHER_WORD_SCORE"), Constant("LAUNCHER_NAME_SCORE")
    H.assertTrue(word > 500 and word < 1000, "a word hit between a name prefix and an exact name, got " .. tostring(word))
    H.assertTrue(name > 1e6, "the name typed stays on top, got " .. tostring(name))
    H.assertTrue(src:find("score = byName and LAUNCHER_NAME_SCORE or LAUNCHER_WORD_SCORE", 1, true) ~= nil,
        "the launcher row takes one of the two bands")
    H.assertTrue(src:find("score = 2e6", 1, true) == nil, "no bare launcher band left")
    H.assertTrue(src:find("ns.Extensions.StartsWord(launcher.nameLower, lowerText)", 1, true) ~= nil,
        "the name band needs the name's or a word's start, never a substring")
end

-- Every result is listed: the head of fifteen paints in the keystroke's
-- frame as before, the rest sort and join a frame later, below the fold.
function tests.theRowsPastTheHead_joinAFrameLater()
    H.assertTrue(src:find("local TOP_N = mapSplit and #combined or 15", 1, true) ~= nil,
        "the head is fifteen rows, or the whole @map list")
    H.assertTrue(src:find("if displaced then tail[#tail + 1] = displaced end", 1, true) ~= nil,
        "a row pushed out of the head joins the tail")
    H.assertTrue(src:find("pcall(tsort, tail, FlatNameLess)", 1, true) ~= nil, "the tail sorts by the same order")
    H.assertTrue(src:find("if Utils.SliceYield() then AppendTail() else tailFrame:Show() end", 1, true) ~= nil,
        "the tail waits for the next slice or the next frame")
    H.assertTrue(src:find("ns.ResultRender:ExtendResults(flatEntries, from)", 1, true) ~= nil,
        "the list grows in place")
end

function tests.catalogScan_takesTheCutQueryUnderAnItemSteer()
    H.assertTrue(src:find('local cut = Steer and Steer.Strip(text, "Item")', 1, true) ~= nil
        and src:find("ns.ItemSearch:Search(cut or text, ScoreCatalogName)", 1, true) ~= nil,
        '"item linen cloth" scans the catalog for "linen cloth"')
    -- A cut match is weaker evidence than the whole query's: one under it.
    H.assertTrue(src:find("if cut then hit.score = hit.score - 1 end", 1, true) ~= nil)
end

function tests.itemRows_keepTheCatalogCopyOut()
    H.assertTrue(src:find("ITEM_ROW_CATEGORY[d.category] then seenCatalogItems[itemID] = r", 1, true) ~= nil,
        "a held, banked or dropped item marks its catalog twin with its own row")
    -- The row standing for the item ranks as the catalog would: a Loot row's
    -- band (115) sank Cruel Barb from 2 to 55 at "cru" (the Era audit, 2026-11-01).
    H.assertTrue(src:find("elseif twin ~= true and (twin.score or 0) < hit.score then", 1, true) ~= nil)
    H.assertTrue(src:find("twin.score = hit.score", 1, true) ~= nil)
    for _, cat in ipairs({ "Bag", "Bank", "Warband", "Loot" }) do
        H.assertTrue(src:find("ITEM_ROW_CATEGORY = {[^}]*" .. cat .. " = true") ~= nil, cat .. " is an item row")
    end
    H.assertTrue(src:find("ITEM_ROW_CATEGORY = {[^}]*Profession") == nil, "a recipe is not the item it makes")
end

-- Equal scores sort by kind before the shorter name: items the player
-- does not have (loot, the catalog) after everything else ("scar" put
-- fourteen Scarlet Monastery drops above the dungeon, the Era audit
-- 2026-11-01). Places rank with own rows: behind them, 250 fishing spots
-- sat over the Fishing Trainer at "fishing".
function tests.equalScores_sortByKindBeforeTheShorterName()
    local kind = assert(src:find("local function KindRank(d)", 1, true), "the kind rank")
    H.assertTrue(src:find('if d.catalogItem or d.category == "Loot" or d.category == "npc" then return 1 end', kind, true) ~= nil,
        "creatures, loot and the catalog last")
    H.assertTrue(src:find("d.mapRank or d.mapSearchResult then return", kind, true) == nil, "places are no kind of their own")
    local cmp = assert(src:find("local function FlatNameLess(ra, rb)", 1, true))
    local byKind = assert(src:find("local ka, kb = KindRank(ra.data), KindRank(rb.data)", cmp, true), "kinds compared")
    local byName = assert(src:find('local na, nb = ra.data.name or "", rb.data.name or ""', cmp, true))
    local byMap = assert(src:find("local ma, mb = ra.data.mapRank, rb.data.mapRank", cmp, true))
    H.assertTrue(byMap < byKind and byKind < byName, "after the map order, before the name's length")
end

local pass, fail, failures = H.runSuite("QueryBands", tests)
return { pass = pass, fail = fail, failures = failures }
