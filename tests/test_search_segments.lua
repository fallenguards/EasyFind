-- A source's search index is saved after it is built and restored on a
-- later load only when the rows' indexed text is the same
-- (Database/Segments.lua): same text restores with no build, any change in
-- a name or keyword rebuilds and saves again, per-character sources save
-- under the character, and a restored index finds what a built one does.
local H = require("Harness")

local function Rows(names)
    local rows = {}
    for i, name in ipairs(names) do
        rows[i] = { name = name, nameLower = name:lower(), category = "Toy", keywordsLower = { "toy" } }
    end
    return rows
end

local TOYS = { "Hearthstone", "Boom Bot", "Toy Train Set", "Orb of Deception", "Brewfest Keg" }

-- One load: a fresh index over the rows, the saved variables carried over.
local function Session(db, rows)
    local env = H.newEnv()
    env.EasyFind = { db = db }
    local ns = H.newNs(env)
    ns.Database.uiSearchData = rows
    ns.Database.IsLootStatSearchWord = function() return false end
    ns.Database.IsLootSlotSearchWord = function() return false end
    ns.CurrentCharacterKey = function() return "Alt-Realm" end
    H.loadModule("Shared/SearchText.lua", env, ns)
    local Database = H.loadModule("Database/Search.lua", env, ns)
    H.loadModule("Database/SearchIndex.lua", env, ns)
    local builds = 0
    local build = ns.SearchIndex.BuildSegment
    ns.SearchIndex.BuildSegment = function(self, ...)
        builds = builds + 1
        return build(self, ...)
    end
    H.loadModule("Database/Segments.lua", env, ns)
    return ns, Database, function() return builds end
end

local function Names(Database, query)
    Database:ResetSearchCache()
    local found = {}
    for _, r in ipairs(Database:SearchUI(query) or {}) do found[#found + 1] = r.data.name end
    table.sort(found)
    return table.concat(found, ", ")
end

-- The saved variables as the game writes and reads them back.
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

function tests.sameTextRestoresWithNoBuild()
    local db = {}
    local ns1, _, builds1 = Session(db, Rows(TOYS))
    ns1.SearchSegments.Attach("toys", ns1.Database.uiSearchData)
    H.assertEq(builds1(), 1, "first load builds")
    H.assertNotNil(db.searchIndexCache and db.searchIndexCache.toys, "segment saved")
    local ns2, _, builds2 = Session(RoundTrip(db), Rows(TOYS))
    ns2.SearchSegments.Attach("toys", ns2.Database.uiSearchData)
    H.assertEq(builds2(), 0, "a load with the same rows restores")
end

function tests.aChangedNameRebuilds()
    local db = {}
    local ns1 = Session(db, Rows(TOYS))
    ns1.SearchSegments.Attach("toys", ns1.Database.uiSearchData)
    local changed = { "Hearthstone", "Boom Bot", "Toy Train Set", "Orb of Deceit", "Brewfest Keg" }
    local db2 = RoundTrip(db)
    local ns2, Database2, builds2 = Session(db2, Rows(changed))
    ns2.SearchSegments.Attach("toys", ns2.Database.uiSearchData)
    H.assertEq(builds2(), 1, "same count, one name changed: rebuilt")
    H.assertEq(Names(Database2, "deceit"), "Orb of Deceit", "the rebuilt index finds the new name")
    H.assertEq(Names(Database2, "deception"), "", "and not the old one")
    local ns3, _, builds3 = Session(RoundTrip(db2), Rows(changed))
    ns3.SearchSegments.Attach("toys", ns3.Database.uiSearchData)
    H.assertEq(builds3(), 0, "the rebuilt segment was saved")
end

function tests.aRestoredIndexFindsWhatABuiltOneDoes()
    local db = {}
    local ns1, Database1 = Session(db, Rows(TOYS))
    ns1.SearchSegments.Attach("toys", ns1.Database.uiSearchData)
    local ns2, Database2, builds2 = Session(RoundTrip(db), Rows(TOYS))
    ns2.SearchSegments.Attach("toys", ns2.Database.uiSearchData)
    H.assertEq(builds2(), 0, "restored")
    H.assertEq(Names(Database1, "orb"), "Orb of Deception", "the built index finds rows")
    for _, q in ipairs({ "hearth", "bb", "toy train", "orb", "keg", "toy" }) do
        H.assertEq(Names(Database2, q), Names(Database1, q), "query " .. q)
    end
end

function tests.characterSourcesSaveUnderTheCharacter()
    local db = {}
    local ns1 = Session(db, Rows(TOYS))
    ns1.SearchSegments.Attach("bags", ns1.Database.uiSearchData)
    H.assertNil(db.searchIndexCache and db.searchIndexCache.bags, "not on the account")
    H.assertNotNil(db.searchIndexCharCache and db.searchIndexCharCache["Alt-Realm"]
        and db.searchIndexCharCache["Alt-Realm"].bags, "under the character")
end

local pass, fail, failures = H.runSuite("SearchSegments", tests)
return { pass = pass, fail = fail, failures = failures }
