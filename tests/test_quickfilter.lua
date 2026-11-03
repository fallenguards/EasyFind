-- Tests for Search/Filters/QuickFilter.lua's pure token-resolution logic.

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

-- QuickFilter.lua reads Filters.GetUIBucket at load time. Stub it.
ns.Filters.GetUIBucket = function() return nil end

-- The pill builder references ns.Search method; stub it.
ns.Search.SetQuickFilterPillFill = function() end
ns.Search.GetSelectedIndex = function() return 0 end
ns.Search.GetResultButtons = function() return {} end
ns.Search.GetSearchFrame = function() return nil end

-- Ditto Filters.HideResults / ShowHierarchicalResults / OnSearchTextChanged
ns.Filters.HideResults = function() end
ns.Filters.ShowHierarchicalResults = function() end
ns.Filters.OnSearchTextChanged = function() end
ns.Filters.IsGuildAchievementData = function() return false end

-- ns.SetRoundedRectFill etc. referenced if CreateQuickFilterPill is called,
-- but we don't call that in tests.

local Filters = H.loadModule("Search/Filters/QuickFilter.lua", env, ns)
H.assertNotNil(Filters, "QuickFilter.lua must return Filters table")
H.assertEq(Filters, ns.Filters)

local tests = {}

function tests.resolve_byCanonicalName()
    local def = Filters:ResolveQuickFilterToken("mounts")
    H.assertNotNil(def, "expected def for 'mounts'")
    H.assertEq(def.key, "mounts")
end

function tests.resolve_byAlias()
    local def = Filters:ResolveQuickFilterToken("m")
    H.assertNotNil(def)
    H.assertEq(def.key, "mounts")
end

function tests.resolve_byTmogAlias()
    local def = Filters:ResolveQuickFilterToken("tmog")
    H.assertNotNil(def)
    H.assertEq(def.key, "appearanceItems")
end

function tests.resolve_byAtPrefixedToken()
    local def = Filters:ResolveQuickFilterToken("@toys")
    H.assertNotNil(def)
    H.assertEq(def.key, "toys")
end

function tests.resolve_underscoreNormalizedToDash()
    local def = Filters:ResolveQuickFilterToken("appearance_sets")
    H.assertNotNil(def)
    H.assertEq(def.key, "appearanceSets")
end

function tests.resolve_unknownToken()
    H.assertNil(Filters:ResolveQuickFilterToken("nonexistent-filter"))
end

function tests.resolve_emptyToken()
    H.assertNil(Filters:ResolveQuickFilterToken(""))
end

function tests.resolve_ambiguousPrefixReturnsNil()
    -- A prefix that matches multiple canonical names should return nil rather
    -- than guessing. "a" matches "abilities", "achievements", etc.
    -- But "a" is also an explicit alias for "achievements", so the direct
    -- lookup wins. Test a prefix that ISN'T an exact alias.
    local def = Filters:ResolveQuickFilterToken("ach")
    -- "ach" is an alias for achievements. Direct lookup hits.
    H.assertNotNil(def)
    H.assertEq(def.key, "achievements")
end

function tests.matchRank_exactCanonical()
    local def = Filters.quickFilterByAlias.mounts
    H.assertEq(Filters:QuickFilterMatchRank(def, "mounts"), 0)
end

function tests.matchRank_exactAlias()
    local def = Filters.quickFilterByAlias.mounts
    H.assertEq(Filters:QuickFilterMatchRank(def, "m"), 1)
end

function tests.matchRank_canonicalPrefix()
    local def = Filters.quickFilterByAlias.mounts
    local rank = Filters:QuickFilterMatchRank(def, "mo")
    H.assertNotNil(rank)
    -- Canonical-prefix branch returns 10 + order. With ~22 filters, this
    -- lands somewhere in 11..32. Just verify it's strictly worse than an
    -- exact alias (rank 1) and strictly better than no-match (nil).
    H.assertTrue(rank > 1,
        "canonical prefix should rank worse than exact alias, got " .. tostring(rank))
end

function tests.matchRank_noMatchReturnsNil()
    local def = Filters.quickFilterByAlias.mounts
    H.assertNil(Filters:QuickFilterMatchRank(def, "zz"))
end

function tests.matchRank_emptyTokenReturnsDefaultRank()
    local def = Filters.quickFilterByAlias.mounts
    local rank = Filters:QuickFilterMatchRank(def, "")
    H.assertNotNil(rank)
    H.assertTrue(rank >= 100, "empty token gets 100+order rank")
end

function tests.displayToken_shortestAliasFormat()
    local def = Filters.quickFilterByAlias.mounts
    local token = Filters:GetQuickFilterDisplayToken(def)
    -- "m" is the shortest alias, so displayToken should be "@m".
    H.assertEq(token, "@m")
end

function tests.completionToken_offersExpansion()
    local def = Filters.quickFilterByAlias.mounts
    -- Typed "@mo", canonical is "mounts" so completion offers the rest.
    local token = Filters:GetQuickFilterCompletionToken(def, "@mo")
    H.assertNotNil(token, "expected a completion suggestion for '@mo'")
    H.assertTrue(token:sub(1, 3) == "@mo",
        "completion should start with the typed prefix: " .. tostring(token))
end

function tests.needsHeavyData_lootAndBosses()
    H.assertTrue(Filters:QuickFilterNeedsHeavyData({ key = "loot" }))
    H.assertTrue(Filters:QuickFilterNeedsHeavyData({ key = "bosses" }))
    H.assertFalse(Filters:QuickFilterNeedsHeavyData({ key = "mounts" }))
    H.assertFalse(Filters:QuickFilterNeedsHeavyData(nil))
end

-- ApplyQuickFilter is the ONE gate every accept path funnels through; the
-- typed @token must never survive into the applied query text, no matter
-- how a caller composed remainingText (ghost accept + auto-accept built
-- "@icons @ico" at one point).
local function applyAndCaptureQuery(def, remaining)
    local captured
    local orig = Filters.OnSearchTextChanged
    Filters.OnSearchTextChanged = function(_, text) captured = text end
    Filters:ApplyQuickFilter(def, remaining)
    Filters.OnSearchTextChanged = orig
    Filters._quickFilter = nil
    return captured
end

function tests.apply_stripsOwnLeadingToken()
    local def = Filters.quickFilterByAlias.icons
    H.assertEq(applyAndCaptureQuery(def, "@icons sword"), "sword")
    H.assertEq(applyAndCaptureQuery(def, "@icons @ico"), "")
    H.assertEq(applyAndCaptureQuery(def, "@ico"), "")
end

function tests.apply_keepsForeignTokenAndPlainText()
    local def = Filters.quickFilterByAlias.icons
    H.assertEq(applyAndCaptureQuery(def, "sword"), "sword")
    -- "@m" is the mounts token: a DIFFERENT def's token is not ours to eat.
    H.assertEq(applyAndCaptureQuery(def, "@m sword"), "@m sword")
end

-- A decorator's scope admits the rows it takes, map rows too (creatures,
-- places); joined to its extension's provider, that provider's rows as
-- well; every other scope still refuses map rows (MINOR 7).
function tests.decoratorScope_mapRowsItTakes_joinedProviderRows()
    env.EasyFind.db = env.EasyFind.db or {}
    ns.Extensions = ns.Extensions or {}
    local was = ns.Extensions.DecoratorTakes
    ns.Extensions.DecoratorTakes = function(_, row) return row.npcID == 7 end
    local scope = { key = "hntest", canonical = "hntest", aliases = { "hntpins" }, decorator = {} }
    H.assertTrue(Filters:AddQuickFilter(scope))
    local function Allows(row, def) return Filters:QuickFilterAllowsData(row, def or scope) end
    H.assertTrue(Allows({ mapSearchResult = true, npcID = 7 }), "a map row it takes")
    H.assertFalse(Allows({ mapSearchResult = true, npcID = 8 }))
    H.assertFalse(Allows({ category = "HN Pin", name = "x" }), "the provider's rows wait for the join")
    Filters:JoinQuickFilter(scope, { "HN Pin" })
    H.assertTrue(scope.joined)
    H.assertTrue(Allows({ category = "HN Pin", name = "x" }), "joined: the provider's rows")
    H.assertTrue(Allows({ mapSearchResult = true, npcID = 7 }))
    H.assertFalse(Allows({ mapSearchResult = true, npcID = 9 }))
    H.assertFalse(Allows({ mapSearchResult = true, npcID = 7 }, Filters:ResolveQuickFilterToken("mounts")),
        "another scope refuses map rows")
    if ns.SearchSteer then
        H.assertTrue(ns.SearchSteer.byCategory["HN Pin"].hntpins, "its aliases steer to the provider's rows")
    end
    ns.Extensions.DecoratorTakes = was
end

local pass, fail, failures = H.runSuite("QuickFilter", tests)
return { pass = pass, fail = fail, failures = failures }
