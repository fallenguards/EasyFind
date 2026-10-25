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
local function Load(sched, clock)
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
