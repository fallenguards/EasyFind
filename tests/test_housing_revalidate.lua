-- Housing rows come back from the saved catalog at login and the live
-- catalog search revalidates them. An unchanged catalog leaves the saved
-- rows on show untouched (they stay packed, nothing is re-indexed); a
-- changed one swaps in packed rows built from the new catalog. Runs the
-- real code from Database/Main.lua and Shared/Utils.lua.
local H = require("Harness")

local function fakeWidget()
    local w = {}
    setmetatable(w, { __index = function() return function() return w end end })
    return w
end

local function read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local function cut(src, startText, endText)
    local s = assert(src:find(startText, 1, true), startText)
    local _, e = src:find(endText, s)
    assert(e, "end of " .. startText)
    return src:sub(s, e)
end

local function newRealUtils()
    local env = H.newEnv()
    env.CreateFont, env.CreateFrame = fakeWidget, fakeWidget
    env.CreateColor = function(r, g, b, a) return { GetRGBA = function() return r, g, b, a end } end
    env.UIParent, env.WorldFrame, env.GameTooltip = fakeWidget(), fakeWidget(), fakeWidget()
    env.hooksecurefunc = function() end
    env.GameFontNormal = setmetatable({}, { __index = function(_, k)
        if k == "GetFont" then return function() return "font", 12, "" end end
        return function() end
    end })
    local ns = H.newNs(env)
    H.loadModule("Shared/Utils.lua", env, ns)
    return ns.Utils
end

local RealUtils = newRealUtils()

local CATALOG = {
    [101] = { name = "Oak Chair", iconTexture = 1, recordID = 11, totalNumStored = 2, totalNumPlaced = 1, quality = 1 },
    [102] = { name = "Lamp", iconTexture = 2, recordID = 12, totalNumStored = 0, totalNumPlaced = 3, quality = 2 },
    [103] = { name = "Rug", iconTexture = 3, recordID = 13, totalNumStored = 5, totalNumPlaced = 0, quality = 1 },
}
local IDS = { 101, 102, 103 }

-- One session: a fresh load of the housing code over the saved db.
-- asTables: the client's entry ids, new tables each search (12.x).
local function Session(db, asTables)
    local src = read("Database/Main.lua")
    local chunk = cut(src, "local Corpora = { packedLive = {} }", "\nend\r?\n")
        .. cut(src, "local HOUSING_PROTO = {", "\n}\r?\n")
        .. cut(src, "local HOUSING_ROW_SPEC = {", "\nfunction Database:FinishHousingResults.-\nend\r?\n")
        .. "\nreturn Corpora, HydratePersistedHousingCache, RemoveEntriesByCategory"
    local data, budgets = {}, {}
    local catalog = {}
    for id, info in pairs(CATALOG) do
        catalog[id] = {}
        for k, v in pairs(info) do catalog[id][k] = v end
    end
    local Utils = setmetatable({
        RunSliced = function(fn, onDone, budgetMs, label)
            budgets[#budgets + 1] = budgetMs or "default"
            return RealUtils.RunSliced(fn, onDone, budgetMs, label)
        end,
    }, { __index = RealUtils })
    local env = setmetatable({
        Database = {}, uiSearchData = data, Utils = Utils,
        ns = { HOUSING_CACHE_VER = 1 },
        EasyFind = { db = db },
        UnitGUID = function() return "Player-1" end,
        HOUSING_ROOM_TYPE = 2,
        C_HousingCatalog = { GetCatalogEntryInfo = function(id) return catalog[asTables and id.recordID or id] end },
        housingSearcher = { GetCatalogSearchResults = function()
            if not asTables then return IDS end
            local ids = {}
            for i, id in ipairs(IDS) do ids[i] = { recordID = id, entryType = 1 } end
            return ids
        end },
    }, { __index = _G })
    local Corpora, Hydrate, RemoveCategory = assert(load(chunk, "=Main.lua housing", "t", env))()
    local s = { data = data, budgets = budgets, catalog = catalog, Corpora = Corpora, env = env,
        RemoveCategory = RemoveCategory }
    function s.Hydrate() return Hydrate() end
    function s.Revalidate()
        local changed, err
        env.Database:FinishHousingResults(function(c, e) changed, err = c, e end)
        return changed, err
    end
    return s
end

local function bare(row)
    for key in pairs(row) do
        if key ~= "_ri" then return false end
    end
    return true
end

local function housingRows(data)
    local rows = {}
    for _, row in ipairs(data) do
        if row.category == "Housing" then rows[#rows + 1] = row end
    end
    return rows
end

local tests = {}

function tests.anUnchangedCatalogLeavesTheSavedRowsAlone()
    local db = {}
    local first = Session(db)
    H.assertEq(first.Revalidate(), true, "first session builds the rows")
    H.assertEq(type(db.housingCache.packed), "string", "and saves them")

    local s = Session(db)
    H.assertTrue(s.Hydrate(), "the next login shows the saved rows")
    local shown = housingRows(s.data)
    H.assertEq(#shown, 3)
    local changed, err = s.Revalidate()
    H.assertEq(changed, false, "nothing changed")
    H.assertNil(err)
    local after = housingRows(s.data)
    H.assertEq(#after, 3)
    for i = 1, 3 do
        H.assertTrue(after[i] == shown[i], "row " .. i .. " is the same row")
        H.assertTrue(bare(after[i]), "row " .. i .. " still packed")
    end
    H.assertEq(s.budgets[1], 1.5, "revalidating shown rows runs at the background pace")
end

function tests.aChangedCatalogSwapsInPackedRows()
    local db = {}
    Session(db).Revalidate()
    local s = Session(db)
    s.Hydrate()
    local oldPacked = db.housingCache.packed
    s.catalog[102].totalNumPlaced = 4
    H.assertEq(s.Revalidate(), true, "the change is reported")
    local rows = housingRows(s.data)
    H.assertEq(#rows, 3)
    H.assertTrue(getmetatable(rows[1]).__pcCorpus ~= nil, "new rows are packed")
    H.assertEq(rows[2].housingNumPlaced, 4, "and read the new catalog")
    H.assertEq(rows[2].name, "Lamp")
    H.assertTrue(db.housingCache.packed ~= oldPacked, "the save follows")
    H.assertEq(s.Corpora.packedLive.Housing, db.housingCache.packed, "the new rows are marked as the save")
end

-- The client hands each search new entry id tables: the same catalog
-- still packs the same (packed as addresses, every check swapped all
-- the rows and searched again).
function tests.entryIdTables_packTheSameEachSearch()
    local db = {}
    H.assertEq(Session(db, true).Revalidate(), true, "first session builds the rows")
    H.assertTrue(not db.housingCache.packed:find("table: ", 1, true), "no table address saved")
    local s = Session(db, true)
    H.assertTrue(s.Hydrate(), "the next login shows the saved rows")
    H.assertEq(s.Revalidate(), false, "the same catalog is nothing changed")
    H.assertEq(housingRows(s.data)[2].housingEntryID, "1:102", "the id kept as its fields")
end

function tests.removedRowsAreBuiltAgain()
    local db = {}
    Session(db).Revalidate()
    local s = Session(db)
    s.Hydrate()
    s.RemoveCategory("Housing")
    H.assertEq(#housingRows(s.data), 0)
    H.assertEq(s.Revalidate(), true, "rows gone from search are rebuilt")
    H.assertEq(#housingRows(s.data), 3)
end

local pass, fail, failures = H.runSuite("HousingRevalidate", tests)
return { pass = pass, fail = fail, failures = failures }
