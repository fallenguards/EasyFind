-- Locks in current Database/Dynamic.lua async provider behavior before the
-- scheduler migration. These tests must keep passing after migration.

local H = require("Harness")

local function setupDatabase()
    local env = H.newEnv()
    local ns = H.newNs(env)
    -- Scheduler must be loaded before Dynamic.lua so Dynamic's
    -- ensureJobsRegistered can find ns.Scheduler.
    H.loadModule("Shared/Scheduler.lua", env, ns)
    -- Dynamic derives provider categories from the shared category map.
    H.loadModule("Shared/CategoryMap.lua", env, ns)
    ns.Database.uiSearchData = {}
    ns.Database.IsLootStatSearchWord = function() return false end
    ns.Database.ResetSearchCache = function() end
    ns.Database.WarmSearchHotPath = function() end
    ns.Database.CancelDynamicScans = function() end

    -- Dynamic.lua iterates a hardcoded provider list; each provider names a
    -- method on Database (`fn`/`asyncFn`/`pre`). Tests stub the ones they
    -- exercise; unused stubs return false so providers stay marked dirty
    -- and don't pollute side effects.
    local stubLog = {}
    for _, key in ipairs({
        "PopulateDynamicCurrencies", "PopulateDynamicReputations",
        "PopulateDynamicAchievements", "PopulateDynamicStatistics",
        "PopulateDynamicStatisticsAsync",
        "PopulateDynamicMounts", "PopulateDynamicToys", "PopulateDynamicPets",
        "PopulateDynamicOutfits", "PopulateDynamicHeirlooms",
        "PopulateDynamicTitles", "PopulateDynamicGearSets",
        "PopulateDynamicMacros", "PopulateDynamicAbilities",
        "PopulateDynamicTalents", "PopulateDynamicBags", "PopulateDynamicBank",
        "PopulateDynamicTransmogSets", "SyncTransmogSetFiltersFromUI",
        "PopulateDynamicLoot", "PopulateDynamicLootAsync",
        "PopulateDynamicBosses", "PopulateDynamicBossesAsync",
    }) do
        ns.Database[key] = function()
            stubLog[#stubLog + 1] = key
            return true
        end
    end
    ns.Database._stubLog = stubLog

    H.loadModule("Database/Dynamic.lua", env, ns)
    return env, ns, ns.Database
end

local tests = {}

function tests.ensureLoaded_runsProviderAndCallsOnDone()
    local _, _, Database = setupDatabase()
    local ran, changed = false, nil
    Database.PopulateDynamicMounts = function() ran = true; return true end
    Database:EnsureDynamicProviderLoaded("mounts", function(c) changed = c end)
    H.assertTrue(ran, "provider fn should have been called")
    H.assertEq(changed, true, "onDone should be called with changed=true")
    H.assertTrue(Database:IsDynamicProviderLoaded("mounts"))
end

function tests.ensureLoaded_secondCallSkipsRerun()
    local _, _, Database = setupDatabase()
    local runs = 0
    Database.PopulateDynamicMounts = function() runs = runs + 1; return true end
    Database:EnsureDynamicProviderLoaded("mounts", function() end)
    Database:EnsureDynamicProviderLoaded("mounts", function() end)
    H.assertEq(runs, 1, "provider should not be re-run once loaded+clean")
end

function tests.ensureLoaded_unknownKeyReturnsFalse()
    local _, _, Database = setupDatabase()
    H.assertFalse(Database:EnsureDynamicProviderLoaded("nonexistent", function() end))
end

function tests.providerReturningFalse_marksDirtyAndCallsOnDoneFalse()
    local _, _, Database = setupDatabase()
    local changed = "uninit"
    Database.PopulateDynamicMounts = function() return false end
    Database:EnsureDynamicProviderLoaded("mounts", function(c) changed = c end)
    H.assertEq(changed, false, "onDone should be false when provider returns false")
    H.assertFalse(Database:IsDynamicProviderLoaded("mounts"))
end

function tests.providerErrors_marksNotLoadedAndCallsOnDoneFalse()
    local _, _, Database = setupDatabase()
    local changed = "uninit"
    Database.PopulateDynamicMounts = function() error("boom") end
    Database:EnsureDynamicProviderLoaded("mounts", function(c) changed = c end)
    H.assertEq(changed, false, "onDone should be false when provider errors")
    H.assertFalse(Database:IsDynamicProviderLoaded("mounts"))
end

function tests.preFnRunsBeforeMainFn()
    local _, _, Database = setupDatabase()
    local order = {}
    Database.SyncTransmogSetFiltersFromUI = function() order[#order + 1] = "pre" end
    Database.PopulateDynamicTransmogSets = function()
        order[#order + 1] = "main"
        return true
    end
    Database:EnsureDynamicProviderLoaded("transmogSets", function() end)
    H.assertEq(order[1], "pre", "pre fn should run first")
    H.assertEq(order[2], "main", "main fn should run after pre")
end

function tests.refreshDynamicCategory_marksDirtyAndReruns()
    local _, _, Database = setupDatabase()
    local runs = 0
    Database.PopulateDynamicMounts = function() runs = runs + 1; return true end
    Database:EnsureDynamicProviderLoaded("mounts", function() end)
    H.assertEq(runs, 1)
    Database:RefreshDynamicCategory("mounts")
    H.assertEq(runs, 2, "RefreshDynamicCategory should rerun the provider")
end

function tests.markDynamicCategoryDirty_clearsCleanFlag()
    local _, _, Database = setupDatabase()
    Database.PopulateDynamicMounts = function() return true end
    Database:EnsureDynamicProviderLoaded("mounts", function() end)
    H.assertTrue(Database:IsDynamicProviderLoaded("mounts"))
    Database:MarkDynamicCategoryDirty("mounts")
    H.assertFalse(Database:IsDynamicProviderLoaded("mounts"),
        "MarkDynamicCategoryDirty must make the provider report not-loaded")
end

function tests.markDynamicProviderLoaded_forcesLoadedState()
    local _, _, Database = setupDatabase()
    Database:MarkDynamicProviderLoaded("mounts")
    H.assertTrue(Database:IsDynamicProviderLoaded("mounts"),
        "MarkDynamicProviderLoaded should flag the key as loaded+clean")
end

function tests.asyncProvider_callsAllWaitersOnCompletion()
    local _, _, Database = setupDatabase()
    -- Capture the completion callback so we can fire it manually, simulating
    -- async work that completes later.
    local completion
    Database.PopulateDynamicStatisticsAsync = function(_, onDone)
        completion = onDone
        return nil  -- signals async start; runner doesn't auto-finish
    end
    local waiter1, waiter2 = "uninit", "uninit"
    Database:EnsureDynamicProviderLoaded("statistics", function(c) waiter1 = c end)
    -- A second EnsureLoaded while the first is in flight enqueues as a waiter.
    Database:EnsureDynamicProviderLoaded("statistics", function(c) waiter2 = c end)
    H.assertEq(waiter1, "uninit", "first waiter must not fire before async completes")
    H.assertEq(waiter2, "uninit", "second waiter must not fire before async completes")
    -- Fire the async completion. Both waiters get notified with the changed
    -- value the populator passed in.
    H.assertNotNil(completion, "async populator should have received completion callback")
    completion(true, nil)
    H.assertEq(waiter1, true, "first waiter should receive changed=true")
    H.assertEq(waiter2, true, "second waiter should receive changed=true")
    H.assertTrue(Database:IsDynamicProviderLoaded("statistics"))
end

function tests.asyncProvider_errorPathNotifiesAllWaitersWithFalse()
    local _, _, Database = setupDatabase()
    local completion
    Database.PopulateDynamicStatisticsAsync = function(_, onDone)
        completion = onDone
        return nil
    end
    local got = {}
    Database:EnsureDynamicProviderLoaded("statistics", function(c) got[#got + 1] = c end)
    Database:EnsureDynamicProviderLoaded("statistics", function(c) got[#got + 1] = c end)
    completion(false, "fake-error")
    H.assertEq(got[1], false)
    H.assertEq(got[2], false)
    H.assertFalse(Database:IsDynamicProviderLoaded("statistics"))
end

-- Two async populates in flight at once: what RemoveEntriesByCategory does
-- at each start, then interleaved appends.
local function OverlapSetup(rows)
    local _, ns, Database = setupDatabase()
    local attached, appended = {}, {}
    ns.SearchSegments = { Attach = function(key, list) attached[key] = list end }
    Database.NoteAppendedEntries = function(_, list) appended[#appended + 1] = list end
    local data = Database.uiSearchData
    for i, r in ipairs(rows) do data[i] = r end
    local function Start(category)
        local w, before = 0, #data
        for i = 1, before do
            if data[i].category ~= category then
                w = w + 1
                data[w] = data[i]
            end
        end
        for i = before, w + 1, -1 do data[i] = nil end
        Database:NotePopulateStart(category, w < before)
    end
    local finish = {}
    Database.PopulateDynamicStatisticsAsync = function(_, onDone)
        finish.statistics = onDone
        Start("Statistic")
    end
    Database.PopulateDynamicBossesAsync = function(_, onDone)
        finish.bosses = onDone
        Start("Boss")
    end
    local function Add(category, name) data[#data + 1] = { name = name, category = category } end
    return Database, Add, finish, attached, appended, ns
end

local function Names(list)
    local out = {}
    for i, r in ipairs(list or {}) do out[i] = r.name end
    return table.concat(out, ", ")
end

local function RunOverlap(rows)
    local Database, Add, finish, attached, appended = OverlapSetup(rows)
    Database:EnsureDynamicProviderLoaded("statistics", function() end)
    Add("Statistic", "Deaths")
    Database:EnsureDynamicProviderLoaded("bosses", function() end)
    H.assertNotNil(finish.bosses, "both populates in flight")
    Add("Boss", "Ragnaros")
    Add("Statistic", "Kills")
    Add("Boss", "Onyxia")
    finish.statistics(true)
    finish.bosses(true)
    return attached, appended
end

function tests.overlappingPopulates_eachAttachesAllItsOwnRows()
    local attached, appended = RunOverlap({
        { name = "Old Boss", category = "Boss" }, { name = "Kept", category = "Toy" },
    })
    H.assertEq(Names(attached.statistics), "Deaths, Kills", "statistics: its rows, in order")
    H.assertEq(Names(attached.bosses), "Ragnaros, Onyxia", "bosses: its rows, in order")
    H.assertEq(#appended, 1, "only the first load notes appends (bosses replaced rows)")
    H.assertEq(Names(appended[1]), "Deaths, Kills", "and notes exactly its rows")
end

function tests.overlappingPopulates_theRowBeforeTheAppendsRemoved()
    -- Statistics' appends follow the old boss row, which bosses then remove.
    local attached = RunOverlap({
        { name = "Kept", category = "Toy" }, { name = "Old Boss", category = "Boss" },
    })
    H.assertEq(Names(attached.statistics), "Deaths, Kills", "every statistics row still found")
    H.assertEq(Names(attached.bosses), "Ragnaros, Onyxia")
end

-- An attach from an older populate settling while a newer one runs leaves
-- the newer one's hold on its rows.
function tests.olderAttachSettling_keepsANewerPopulatesHold()
    local Database, Add, finish, _, _, ns = OverlapSetup({})
    local holds, settle = {}, nil
    ns.SearchIndex = { Hold = function(_, c) holds[c] = true end, Unhold = function(_, c) holds[c] = nil end }
    ns.SearchSegments = { Attach = function(_, _, settled) settle = settled end }
    Database:EnsureDynamicProviderLoaded("statistics", function() end)
    Add("Statistic", "Deaths")
    finish.statistics(true)
    H.assertNotNil(settle, "its attach is under way")
    Database:RefreshDynamicCategory("statistics")
    H.assertTrue(holds.Statistic, "the new populate holds")
    settle()
    H.assertTrue(holds.Statistic, "the old attach left the new hold alone")
end

function tests.canceledPopulate_leavesNoRecordBehind()
    local Database, Add, finish = OverlapSetup({})
    Database:EnsureDynamicProviderLoaded("statistics", function() end)
    Add("Statistic", "Deaths")
    finish.statistics(false, "cancelled")
    H.assertNil(Database.populateMarks.Statistic, "consumed on the cancel path")
end

function tests.stale_isResidentRowsWhoseSourceChanged_syncOnly()
    local _, _, Database = setupDatabase()
    H.assertFalse(Database:IsDynamicProviderStale("abilities"), "never loaded: nothing to re-read")
    Database:EnsureDynamicProviderLoaded("abilities", function() end)
    H.assertFalse(Database:IsDynamicProviderStale("abilities"), "loaded and current")
    Database:MarkDynamicCategoryDirty("abilities")
    H.assertTrue(Database:IsDynamicProviderStale("abilities"), "rows resident, their source changed")
    Database:MarkDynamicProviderLoaded("loot")
    Database:MarkDynamicCategoryDirty("loot")
    H.assertFalse(Database:IsDynamicProviderStale("loot"), "a heavy walk waits for its own request")
end

-- The stale queue (Database:RefreshStaleProvider): out-of-date providers
-- read again behind the search, one at a time, none while a search run is
-- in flight, and the active search run again once when the queue empties.
local function StaleSetup()
    local env, ns, Database = setupDatabase()
    local reads, reruns, running = {}, 0, 0
    Database.PopulateDynamicMacros = function() reads[#reads + 1] = "macros"; return true end
    Database.PopulateDynamicTitles = function() reads[#reads + 1] = "titles"; return true end
    for _, key in ipairs({ "macros", "titles" }) do
        Database:EnsureDynamicProviderLoaded(key, function() end)
        Database:MarkDynamicCategoryDirty(key)
    end
    for i = #reads, 1, -1 do reads[i] = nil end
    ns.Search.RefreshActiveSearch = function() reruns = reruns + 1 end
    -- A search run in flight for the next `running` asks.
    ns.Search.IsSearchRunning = function()
        if running > 0 then
            running = running - 1
            return true
        end
        return false
    end
    local function Frames(n)
        for _ = 1, n do
            env._clock:advance(0.016)
            ns.Scheduler:Step(0)
        end
    end
    return Database, reads, Frames, function() return reruns end, function(n) running = n end,
        function() return running end
end

function tests.staleQueue_readsEachOnce_thenRerunsOnce()
    local Database, reads, Frames, Reruns = StaleSetup()
    Database:RefreshStaleProvider("macros")
    Database:RefreshStaleProvider("titles")
    Database:RefreshStaleProvider("macros")
    H.assertTrue(Database:IsRefreshingStale(), "the queue is being read")
    H.assertEq(#reads, 0, "nothing read inside the query's own call")
    -- What a landing leaves (Database/Search.lua QueueActiveSearchRefresh).
    Database._staleChanged = true
    Frames(8)
    H.assertEq(table.concat(reads, " "), "macros titles", "each once, in the order asked")
    H.assertFalse(Database:IsRefreshingStale(), "the queue is empty")
    H.assertFalse(Database:IsDynamicProviderStale("macros"), "read again: current")
    H.assertEq(Reruns(), 1, "the active search runs again once, at the end")
end

function tests.staleQueue_waitsWhileASearchRunIsInFlight()
    local Database, reads, Frames, _, SearchRunsFor, AsksLeft = StaleSetup()
    SearchRunsFor(3)
    local leftAtRead
    local read = Database.PopulateDynamicMacros
    Database.PopulateDynamicMacros = function(...)
        leftAtRead = AsksLeft()
        return read(...)
    end
    Database:RefreshStaleProvider("macros")
    Frames(6)
    H.assertEq(table.concat(reads, " "), "macros", "read once the run ended")
    H.assertEq(leftAtRead, 0, "no provider lands while the search run is in flight")
end

function tests.staleQueue_nothingChanged_noRerun()
    local Database, _, Frames, Reruns = StaleSetup()
    Database:RefreshStaleProvider("titles")
    Frames(6)
    H.assertEq(Reruns(), 0, "no landing marked a change: no rerun")
end

-- A provider that never answers (its waiters dropped) does not hold the
-- reruns for good: the queue counts as read two seconds after its last step.
function tests.staleQueue_aProviderThatNeverAnswers_letsGoAfterTwoSeconds()
    local env, _, Database = setupDatabase()
    Database:EnsureDynamicProviderLoaded("macros", function() end)
    Database:MarkDynamicCategoryDirty("macros")
    Database:RefreshStaleProvider("macros")
    env._clock:advance(0.016)
    H.assertTrue(Database:IsRefreshingStale(), "asked for, its job not yet run")
    env._clock:advance(2.5)
    H.assertFalse(Database:IsRefreshingStale(), "no step for two seconds")
    Database:EnsureDynamicProviderLoaded("titles", function() end)
    Database:MarkDynamicCategoryDirty("titles")
    H.assertTrue(Database:RefreshStaleProvider("titles"), "the next ask starts a new run")
    H.assertTrue(Database:IsRefreshingStale())
end

local pass, fail, failures = H.runSuite("Database/Dynamic", tests)
return { pass = pass, fail = fail, failures = failures }
