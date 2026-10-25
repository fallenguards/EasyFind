-- The real sliced scheduler (Shared/Utils.lua RunSliced) under a fake
-- clock: background runs share a small slice of each frame, a run someone
-- waits on still gets the rest, and a budget function is read per slice.
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
    -- n units of 0.25 ms, a checkpoint after each
    local function Work(n)
        return function()
            for _ = 1, n do
                clock.ms = clock.ms + 0.25
                Utils.SliceCheckpoint()
            end
        end
    end
    return Utils, Work, NextFrame, spent, clock
end

local function FrameTotal(row, labels)
    local total = 0
    for _, label in ipairs(labels) do total = total + ((row or {})[label] or 0) end
    return total
end

local tests = {}

function tests.backgroundRunsShareTwoAndAHalfMsAFrame()
    local Utils, Work, NextFrame, spent = Scheduler()
    local done = 0
    Utils.RunSliced(Work(40), function() done = done + 1 end, 1.5, "a")
    Utils.RunSliced(Work(40), function() done = done + 1 end, 2, "b")
    for _ = 1, 20 do NextFrame() end
    H.assertEq(done, 2, "both finish")
    for frame, row in pairs(spent) do
        H.assertTrue(FrameTotal(row, { "a", "b" }) <= 2.5, "frame " .. frame .. " under the background pool")
    end
    H.assertEq(FrameTotal(spent[1], { "a", "b" }), 2.5, "the pool is used, not idle")
end

function tests.aWaitedRunGetsTheRestOfTheFrame()
    local Utils, Work, _, spent = Scheduler()
    Utils.RunSliced(Work(40), nil, 1.5, "bg1")
    Utils.RunSliced(Work(40), nil, 1.5, "bg2")
    Utils.RunSliced(Work(40), nil, 6, "search")
    H.assertEq(FrameTotal(spent[1], { "bg1", "bg2" }), 2.5, "background stopped at its pool")
    H.assertEq(spent[1].search, 5.5, "the search took the rest of the 8 ms frame")
end

function tests.aBudgetFunctionIsReadEachSlice()
    local Utils, Work, NextFrame, spent = Scheduler()
    local pace = 1.5
    Utils.RunSliced(Work(80), nil, function() return pace end, "provider")
    H.assertEq(spent[1].provider, 1.5, "background pace")
    pace = 4
    NextFrame()
    H.assertEq(spent[2].provider, 4, "urgent pace once a query waits")
end

-- A timer inside a run leaves out the frames it sat paused (16 ms of other
-- work between each), so it reads the run's own 10 ms.
function tests.aRunsPausedFramesAreLeftOutOfItsOwnTime()
    local Utils, _, NextFrame, _, clock = Scheduler()
    local own
    Utils.RunSliced(function()
        local start = clock.ms - Utils.SlicePausedMs()
        for _ = 1, 40 do
            clock.ms = clock.ms + 0.25
            Utils.SliceCheckpoint()
        end
        own = clock.ms - Utils.SlicePausedMs() - start
    end, nil, 2, "a")
    for _ = 1, 20 do
        clock.ms = clock.ms + 16
        NextFrame()
    end
    H.assertEq(own, 10)
    H.assertEq(Utils.SlicePausedMs(), 0, "outside a run")
end

local pass, fail, failures = H.runSuite("SlicedPool", tests)
return { pass = pass, fail = fail, failures = failures }
