local H = require("Harness")

local env = H.newEnv()
local ns = H.newNs(env)
H.loadModule("Shared/SearchText.lua", env, ns)
local Engine = H.loadModule("Search/Engine.lua", env, ns)

local tests = {}

local function withProviderCapture(loaded, stale)
    local requested = {}
    ns.Database.IsDynamicProviderLoaded = function(_, key)
        return loaded and loaded[key] or false
    end
    ns.Database.IsDynamicProviderStale = function(_, key)
        return stale and stale[key] or false
    end
    ns.Database.RequestDynamicProviderLoaded = function(_, key, onDone)
        requested[#requested + 1] = key
        if onDone then onDone(true) end
        return true
    end
    ns.Database.NormalizeSearchQuery = function(_, query) return query end
    -- Read again behind the paint: no hold, nothing pending.
    local refreshed = {}
    ns.Database.RefreshStaleProvider = function(_, key)
        refreshed[#refreshed + 1] = key
        return true
    end
    return requested, refreshed
end

function tests.lowNonzeroResultsStillRequestAbilities()
    local requested = withProviderCapture()
    local ctx = Engine:BuildContext("dash", nil, { abilities = true })

    Engine:RequestProviders(ctx, function() end, 1)

    H.assertEq(requested[1], "abilities",
        "low-result generic ability names should request abilities first")
end

function tests.richGenericResultsDoNotPreloadLowResultProviders()
    local requested = withProviderCapture()
    local ctx = Engine:BuildContext("dash", nil, { abilities = true })

    Engine:RequestProviders(ctx, function() end, 4)

    H.assertEq(#requested, 0,
        "generic queries with enough results should not fan out provider loads")
end

function tests.staleResidentProviderIsReReadByAnyQuery()
    -- A spell learned after the first search: the ability rows stayed as
    -- read before it until a query carried "spell" or found under four rows.
    local requested, refreshed = withProviderCapture(nil, { abilities = true })
    local ctx = Engine:BuildContext("disenchant", nil, { abilities = true })

    local pending = Engine:RequestProviders(ctx, function() end, 4)

    H.assertEq(refreshed[1], "abilities", "a stale provider is re-read whatever the result count")
    H.assertEq(#refreshed, 1, "only the stale one")
    -- Held for, the first search after any gold or zone change painted
    -- 659 ms late: six such providers landed under it (2026-11-13).
    H.assertEq(#requested, 0, "behind the paint: the query holds for none of it")
    H.assertFalse(pending, "nothing the paint waits on")
end

function tests.staleCharacterFacts_areReadAgainBehindThePaint()
    local facts = { charRows = true, charPlayed = true, charSeen = true, charGold = true, charLevel = true }
    local requested, refreshed = withProviderCapture(nil, facts)
    local ctx = Engine:BuildContext("stormwind", nil, facts)

    Engine:RequestProviders(ctx, function() end, 12)

    H.assertEq(#refreshed, 5, "each fact provider that is on and out of date")
    H.assertEq(#requested, 0, "none holds a query that does not name it")
end

function tests.staleProviderTheQueryAsksFor_holdsThePaint()
    local stale = { abilities = true, charGold = true }
    local function Held(text, filters, resultCount, key)
        local requested, refreshed = withProviderCapture(nil, stale)
        Engine:RequestProviders(Engine:BuildContext(text, nil, filters), function() end, resultCount)
        for _, k in ipairs(refreshed) do
            if k == key then return false end
        end
        for _, k in ipairs(requested) do
            if k == key then return true end
        end
        return false
    end
    H.assertTrue(Held("spell disenchant", { abilities = true }, 12, "abilities"), "its word in the query")
    H.assertTrue(Held("disenchant", { abilities = true }, 1, "abilities"), "under four rows found")
    H.assertTrue(Held("gold", { charGold = true }, 12, "charGold"), "a character fact asked for by its word")
end

function tests.aProviderNeverLoaded_isStillLoadedUnderTheHold()
    local requested, refreshed = withProviderCapture()
    local ctx = Engine:BuildContext("stormwind", nil, { charGold = true })

    Engine:RequestProviders(ctx, function() end, 12)

    H.assertEq(requested[1], "charGold", "on and never read: any query loads it once")
    H.assertEq(#refreshed, 0)
end

function tests.staleProviderWithItsFilterOffStaysOut()
    local requested, refreshed = withProviderCapture(nil, { abilities = true })
    local ctx = Engine:BuildContext("disenchant", nil, { abilities = false })

    Engine:RequestProviders(ctx, function() end, 4)

    H.assertEq(#requested, 0, "its filter off: no re-read")
    H.assertEq(#refreshed, 0, "nor behind the paint")
end

function tests.explicitAbilityWordRequestsAbilitiesRegardlessOfResultCount()
    local requested = withProviderCapture()
    local ctx = Engine:BuildContext("ability dash", nil, { abilities = true })

    Engine:RequestProviders(ctx, function() end, 10)

    H.assertEq(requested[1], "abilities",
        "explicit ability query should request abilities even with existing results")
end

function tests.explicitOptionsQueryRequestsOptionsDespiteExistingResults()
    withProviderCapture()
    local populateRequests = 0
    local liveRequests = 0
    ns.BlizzOptionsSearch = {
        EnsurePopulatedAsync = function(_, onDone)
            populateRequests = populateRequests + 1
            if onDone then onDone(true) end
            return true
        end,
        EnsureLivePopulatedAsync = function(_, onDone)
            liveRequests = liveRequests + 1
            if onDone then onDone(true) end
            return true
        end,
    }
    local ctx = Engine:BuildContext("enemy nameplate", nil, {
        options = true,
        gameOptions = true,
        addonOptions = true,
    })

    Engine:RequestProviders(ctx, function() end, 2)

    H.assertEq(populateRequests, 1,
        "explicit settings queries should request options even when partial results exist")
    H.assertEq(liveRequests, 1,
        "explicit game-settings queries should request live SettingsPanel rows")
    ns.BlizzOptionsSearch = nil
end

function tests.bareQuickFilterRequestsItsProvider()
    local requested = withProviderCapture()
    local ctx = Engine:BuildContext("", { key = "outfits" }, nil)

    Engine:RequestProviders(ctx, function() end, 0)

    H.assertEq(requested[1], "outfits",
        "a bare quick filter (empty query) must load its category's provider")
end

function tests.quickFilterOverridesDisabledFilterMenu()
    -- Regression: `quickFilter and nil or activeFilters` leaked the filter
    -- menu into the engine and FilterAllows blocked the pill's provider.
    -- Even if filters leak again, the pill must win.
    local requested = withProviderCapture()
    local ctx = Engine:BuildContext("", { key = "outfits" },
        { outfits = false, collections = true })

    Engine:RequestProviders(ctx, function() end, 0)

    H.assertEq(requested[1], "outfits",
        "an explicit quick filter must override the filter menu state")
end

-- An extension's results (EasyFind.API), as Snippets registers them.
env.EasyFind.API.RegisterExtension({ id = "snippets", name = "Snippets", icon = 1 })
env.EasyFind.API.RegisterSearchProvider({
    key = "snippets", category = "Snippet", label = "Snippets", extension = "snippets", eager = true, lowResults = true,
    words = { "snippet", "snippets", "snip" }, aliases = { "snip", "snippets" },
})

function tests.typedSnippetsWordDemandLoadsSnippetsProvider()
    -- Regression: the snippets port shipped without a PROVIDERS row, so
    -- typing "snippets" after a reload could not demand-load the provider
    -- and waited ~2s for the eager chain to reach it (second-to-last). An
    -- extension's words reach the engine at registration now.
    local requested = withProviderCapture()
    local ctx = Engine:BuildContext("snippets", nil, { snippets = true })

    Engine:RequestProviders(ctx, function() end, 10)

    H.assertEq(requested[1], "snippets",
        "typing snippets must demand-load the provider, not wait for the eager chain")
end

function tests.snipQuickFilterLoadsSnippetsProvider()
    local requested = withProviderCapture()
    local ctx = Engine:BuildContext("", { key = "snippets" }, nil)

    Engine:RequestProviders(ctx, function() end, 0)

    H.assertEq(requested[1], "snippets",
        "the @snip pill must load the snippets provider on an empty query")
end

local pass, fail, failures = H.runSuite("SearchEngine", tests)
return { pass = pass, fail = fail, failures = failures }
