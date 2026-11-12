-- The settings walks on the shared sliced scheduler (Shared/Utils.lua
-- RunSliced, under a fake clock): in the background they stay inside the
-- frame's background pool and span frames, and called from another run (a
-- search's) they never yield there, so no second populate can start inside.
local H = require("Harness")

local function Scheduler()
    local f = assert(io.open(H.ADDON_ROOT .. "/Shared/Utils.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("-- ONE per-frame pool shared by every sliced run", 1, true), "pool block")
    local e = assert(src:find("\nfunction Utils._DebugPeekCorpora", s, true), "end of RunSliced")
    local clock = { ms = 0, frame = 1 }
    local queue = {}
    local Utils = {}
    Utils.SafeAfter = function(_, fn) queue[#queue + 1] = fn end
    Utils.ErrorHandler = function(err) error(err) end
    local spent = {}
    Utils.sliceObserver = function(label, ms)
        local row = spent[clock.frame] or {}
        spent[clock.frame] = row
        row[label] = (row[label] or 0) + ms
    end
    local chunk = "local Utils, dpstop, GetTime = ...\nlocal sliceDeadline\n" .. src:sub(s, e)
    assert(load(chunk, "=Utils.lua RunSliced", "t", _G))(Utils,
        function() return clock.ms end, function() return clock.frame end)
    local function NextFrame()
        clock.frame = clock.frame + 1
        local due = queue
        queue = {}
        for _, fn in ipairs(due) do fn() end
    end
    return Utils, NextFrame, spent, clock
end

-- BlizzSearch over 40 categories, each layout read costing 1 ms of the fake
-- clock (the crawl is the walk's real cost; a name read is not).
local layoutReads = 0
local function Load(sched, clock, setup)
    layoutReads = 0
    local env = H.newEnv()
    env._G = env
    local cats = {}
    for i = 1, 40 do
        cats[i] = {
            GetName = function() return "Category " .. i end,
            GetID = function() return i end,
        }
    end
    env.SettingsPanel = {
        GetAllCategories = function() return cats end,
        GetLayout = function()
            clock.ms = clock.ms + 1
            layoutReads = layoutReads + 1
            return { GetInitializers = function() return {} end }
        end,
    }
    env.Settings = { GetSetting = function() return nil end }
    local ns = H.newNs(env)
    ns.Database.uiSearchData = {}
    ns.Database.ResetSearchCache = function() end
    ns.Utils.RunSliced = sched.RunSliced
    ns.Utils.SliceCheckpoint = sched.SliceCheckpoint
    ns.Utils.SliceYield = sched.SliceYield
    ns.ResultRows.RegisterCustomSetting = function() end
    if setup then setup(env, ns) end
    env.EasyFind._ns = ns
    H.loadModule("Apps/Settings/BlizzSearch.lua", env, ns)
    return ns, env
end

local tests = {}

function tests.backgroundPopulate_spansFramesInsideThePool()
    local sched, NextFrame, spent, clock = Scheduler()
    local ns, env = Load(sched, clock)
    -- No waiter: background work.
    ns.BlizzOptionsSearch:EnsurePopulatedAsync(nil)
    env._clock:advance(0)
    local frames = 0
    while #ns.Database.uiSearchData == 0 and frames < 200 do
        NextFrame()
        frames = frames + 1
    end
    H.assertTrue(#ns.Database.uiSearchData > 0, "the populate finished")
    -- Each category's layout crawled about once, not once per lookup that misses.
    H.assertTrue(layoutReads <= 80, "layout reads for 40 categories: " .. layoutReads)
    H.assertTrue(frames > 1, "it spanned frames: " .. frames)
    -- A slice ends at its first checkpoint past the pool: one category over.
    for frame, row in pairs(spent) do
        H.assertTrue((row.settingsPopulate or 0) <= 2.5 + 1, "frame " .. frame .. " inside the background pool: "
            .. tostring(row.settingsPopulate))
    end
end

-- The login warm-up hears the end but nobody waits on it: still the pool.
function tests.idleWaiter_keepsTheBackgroundPool()
    local sched, NextFrame, spent, clock = Scheduler()
    local ns, env = Load(sched, clock)
    local heard = false
    ns.BlizzOptionsSearch:EnsurePopulatedAsync(function() heard = true end, true)
    env._clock:advance(0)
    local frames = 0
    while not heard and frames < 200 do
        NextFrame()
        frames = frames + 1
    end
    H.assertTrue(heard, "the warm-up heard the end")
    for frame, row in pairs(spent) do
        H.assertTrue((row.settingsPopulate or 0) <= 2.5 + 1, "frame " .. frame .. " inside the background pool: "
            .. tostring(row.settingsPopulate))
    end
end

-- Three AceConfig apps of 100 options, each name read costing 0.2 ms.
local function AceApps(clock, onName)
    return function(env, ns)
        local tables = {}
        for i = 1, 3 do
            local args = {}
            for j = 1, 100 do
                args["opt" .. j] = { type = "toggle", get = function() return true end, set = function() end,
                    name = function()
                        clock.ms = clock.ms + 0.2
                        if onName then onName(ns, i, j) end
                        return "App " .. i .. " option " .. j
                    end }
            end
            local options = { type = "group", name = "App " .. i, args = args }
            tables["app" .. i] = function() return options end
        end
        local registry = {
            IterateOptionsTables = function() return pairs(tables) end,
            GetOptionsTable = function(_, appName) return tables[appName]() end,
        }
        env.LibStub = { NewLibrary = function() end, libs = {
            ["AceConfigRegistry-3.0"] = registry, ["AceConfigDialog-3.0"] = { BlizOptions = {} } } }
    end
end

local function FeedNames(ns)
    local names = {}
    for _, e in ipairs(ns.Database.uiSearchData) do
        if e.addon then names[#names + 1] = e.addon .. "|" .. e.name end
    end
    table.sort(names)
    return names
end

-- Heard at the end, waited on by nobody: the background pool.
local function RunToEnd(ns, env, NextFrame)
    local heard = false
    ns.BlizzOptionsSearch:EnsurePopulatedAsync(function() heard = true end, true)
    env._clock:advance(0)
    local frames = 0
    while not heard and frames < 2000 do
        NextFrame()
        frames = frames + 1
    end
    return frames
end

-- The feeds were one 60 ms slice: now they pause inside the Ace walk.
function tests.aceFeeds_spanFramesInsideThePool()
    local sched, NextFrame, spent, clock = Scheduler()
    local ns, env = Load(sched, clock, AceApps(clock))
    RunToEnd(ns, env, NextFrame)
    local names = FeedNames(ns)
    H.assertEq(#names, 300, "every option is a row")
    for frame, row in pairs(spent) do
        H.assertTrue((row.settingsPopulate or 0) <= 2.5 + 1, "frame " .. frame .. " inside the background pool: "
            .. tostring(row.settingsPopulate))
    end
    -- The same rows as a pull that never pauses.
    local sched2, _, _, clock2 = Scheduler()
    local ns2 = Load(sched2, clock2, AceApps(clock2))
    ns2.BlizzOptionsSearch:Populate(false)
    local direct = FeedNames(ns2)
    H.assertEq(#direct, #names, "the direct pull's row count")
    for i = 1, #names do H.assertEq(names[i], direct[i], "row " .. i) end
end

-- A feed that fails after a pause ends alone; the rest still come in.
function tests.feedError_endsThatFeedAlone()
    local sched, NextFrame, _, clock = Scheduler()
    local reported = {}
    local ns, env = Load(sched, clock, function(env, ns)
        AceApps(clock)(env, ns)
        ns.Utils.ErrorHandler = function(err)
            if tostring(err):find("broken feed", 1, true) then reported[#reported + 1] = err end
        end
        ns.settingsFeeds = { Broken = function()
            clock.ms = clock.ms + 5
            ns.Utils.SliceCheckpoint()
            error("broken feed")
        end }
    end)
    RunToEnd(ns, env, NextFrame)
    H.assertEq(#FeedNames(ns), 300, "the Ace rows came in")
    H.assertEq(#reported, 1, "the error was reported once")
end

-- A feed registered while the populate pauses is read in the same pass.
function tests.feedRegisteredDuringAPause_isRead()
    local sched, NextFrame, _, clock = Scheduler()
    local ns, env = Load(sched, clock, AceApps(clock, function(ns, i, j)
        if i == 2 and j == 50 then
            ns.settingsFeeds.Late = function() return { { name = "Late row", open = function() end } } end
        end
    end))
    RunToEnd(ns, env, NextFrame)
    local found = false
    for _, name in ipairs(FeedNames(ns)) do
        if name == "Late|Late row" then found = true end
    end
    H.assertTrue(found, "the late feed's row is in")
end

function tests.populateInsideASearchRun_neverYieldsThere()
    local sched, _, _, clock = Scheduler()
    local ns = Load(sched, clock)
    local finished = false
    sched.RunSliced(function()
        ns.BlizzOptionsSearch:Populate(false)
        finished = true
    end, nil, 6, "search")
    H.assertTrue(finished, "finished in its first slice, though it ran past the budget")
    H.assertTrue(#ns.Database.uiSearchData > 0, "its rows are in")
end

local pass, fail, failures = H.runSuite("SettingsSlicing", tests)
return { pass = pass, fail = fail, failures = failures }
