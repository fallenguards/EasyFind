-- A settings feed pulled again (its addon's rows replaced) must reach the
-- search index: the old rows stop matching and every new row matches, with
-- the real Search.lua and SearchIndex.lua behind the settings search.
local H = require("Harness")

local function Load(db)
    local env = H.newEnv()
    env._G = env
    env.Settings = { GetSetting = function() return nil end }
    local ns = H.newNs(env)
    ns.Database.uiSearchData = {}
    ns.Database.IsLootStatSearchWord = function() return false end
    ns.Database.IsLootSlotSearchWord = function() return false end
    H.loadModule("Shared/SearchText.lua", env, ns)
    local Database = H.loadModule("Database/Search.lua", env, ns)
    H.loadModule("Database/SearchIndex.lua", env, ns)
    env.EasyFind._ns = ns
    if db then
        env.EasyFind.db = db
        H.loadModule("Database/Segments.lua", env, ns)
    end
    H.loadModule("Apps/Settings/BlizzSearch.lua", env, ns)
    return ns, Database
end

local function Feed(names)
    return function()
        local rows = {}
        for i, n in ipairs(names) do rows[i] = { name = n, open = function() end } end
        return rows
    end
end

local function Found(Database, q)
    Database:ResetSearchCache()
    local out = {}
    for _, r in ipairs(Database:SearchUI(q)) do out[r.data.name] = true end
    return out
end

local tests = {}

function tests.feedPulledAgain_reachesTheIndex()
    local ns, Database = Load()
    ns.settingsFeeds = { Feedy = Feed({ "Alpha Toggle", "Beta Toggle", "Gamma Toggle" }) }
    ns.BlizzOptionsSearch:Populate(false)
    H.assertTrue(Found(Database, "alpha")["Alpha Toggle"], "first pull indexed")
    ns.settingsFeeds.Feedy = Feed({ "Delta Toggle", "Epsilon Toggle", "Zeta Toggle", "Eta Toggle", "Theta Toggle" })
    ns.BlizzOptionsSearch:PullSettingsFeed("Feedy")
    H.assertNil(Found(Database, "alpha")["Alpha Toggle"], "a replaced row no longer matches")
    for _, n in ipairs({ "Delta Toggle", "Epsilon Toggle", "Zeta Toggle", "Eta Toggle", "Theta Toggle" }) do
        H.assertTrue(Found(Database, n:lower())[n], n .. " matches after the second pull")
    end
end

-- The light populate's rows are one saved segment: a later session restores
-- their index instead of building it, and finds the same rows.
function tests.settingsRows_restoreTheirSavedIndex()
    local NAMES = { "Alpha Toggle", "Beta Toggle", "Gamma Toggle", "Delta Toggle" }
    local db = {}
    local ns, Database = Load(db)
    ns.settingsFeeds = { Feedy = Feed(NAMES) }
    ns.BlizzOptionsSearch:Populate(false)
    local saved = db.searchIndexCache and db.searchIndexCache.settings
    H.assertNotNil(saved, "the settings segment is saved")
    local before = {}
    for _, n in ipairs(NAMES) do before[n] = Found(Database, n:lower())[n] end

    local ns2, Database2 = Load(db)
    local restored
    local real = ns2.SearchIndex.RestoreSegment
    ns2.SearchIndex.RestoreSegment = function(self, key, ...)
        local ok = real(self, key, ...)
        if key == "settings" then restored = ok end
        return ok
    end
    ns2.settingsFeeds = { Feedy = Feed(NAMES) }
    ns2.BlizzOptionsSearch:Populate(false)
    H.assertTrue(restored, "the second session restores it")
    for _, n in ipairs(NAMES) do
        H.assertEq(Found(Database2, n:lower())[n], before[n], n .. " after the restore")
        H.assertTrue(before[n], n .. " found")
    end
end

local pass, fail, failures = H.runSuite("SettingsFeedIndex", tests)
return { pass = pass, fail = fail, failures = failures }
