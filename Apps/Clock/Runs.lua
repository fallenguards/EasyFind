local ns = EasyFind and EasyFind._ns
if not ns then return end

local Utils = ns.Utils
local mfloor, mmax = Utils.mfloor, Utils.mmax
local tremove = Utils.tremove
local type = type

-- Runs keep wall-clock times from time(): what is left is always derived,
-- so a reload or a logout costs nothing.
local Runs = {}
ns.ClockRuns = Runs

Runs.MAX = 10
local DB_VERSION = 2

local TOOLS = { pomodoro = true, timer = true, stopwatch = true, alarm = true }

local MIGRATIONS = {
    -- The stopwatch mark was saved as target.
    [2] = function(sv)
        if type(sv.runs) ~= "table" then return end
        for i = 1, #sv.runs do
            local run = sv.runs[i]
            if type(run) == "table" and run.target ~= nil then
                run.mark, run.markHit = run.target, run.targetHit
                run.target, run.targetHit = nil, nil
            end
        end
    end,
}

local function IsNumber(v)
    return type(v) == "number" and v == v
end

local function IsValid(run)
    if type(run) ~= "table" or not TOOLS[run.tool] or not IsNumber(run.startedAt) then return false end
    if run.pausedAt ~= nil and not IsNumber(run.pausedAt) then return false end
    if run.done and not IsNumber(run.doneAt) then return false end
    local tool = run.tool
    if tool == "timer" then
        return IsNumber(run.duration) and run.duration > 0 and (run.base == nil or IsNumber(run.base))
    end
    if tool == "alarm" then return IsNumber(run.at) end
    if tool == "stopwatch" then return run.mark == nil or (IsNumber(run.mark) and run.mark > 0) end
    return IsNumber(run.focusLen) and run.focusLen >= 1 and IsNumber(run.breakLen) and run.breakLen >= 1
        and (run.phase == "focus" or run.phase == "break") and IsNumber(run.phaseStartedAt)
end

-- Takes the saved table (or nil) and returns it migrated and cleaned.
function Runs:Attach(sv, now)
    if type(sv) ~= "table" then sv = {} end
    local from = IsNumber(sv.version) and sv.version or (sv.runs and 1 or 0)
    for v = from + 1, DB_VERSION do
        if MIGRATIONS[v] then MIGRATIONS[v](sv) end
    end
    sv.version = DB_VERSION
    if type(sv.runs) ~= "table" then sv.runs = {} end
    local runs = sv.runs
    for i = #runs, 1, -1 do
        local run = runs[i]
        if not IsValid(run) then
            tremove(runs, i)
        elseif run.startedAt > now then
            -- The computer's clock went back: restart from now.
            local shift = run.startedAt - now
            run.startedAt = now
            if run.phaseStartedAt then run.phaseStartedAt = run.phaseStartedAt - shift end
            if run.pausedAt then run.pausedAt = mmax(now, run.pausedAt - shift) end
        end
    end
    if type(sv.hud) ~= "table" then sv.hud = {} end
    if type(sv.strip) ~= "table" then sv.strip = {} end
    -- Clear of the main minimap button (200).
    if not IsNumber(sv.minimapAngle) then sv.minimapAngle = 245 end
    self.sv = sv
    return sv
end

function Runs:List()
    return self.sv and self.sv.runs or {}
end

local function Now(run, now)
    return run.pausedAt or now
end

function Runs.Elapsed(run, now)
    return mmax(0, Now(run, now) - run.startedAt)
end

local function PhaseLen(run)
    return run.phase == "break" and run.breakLen or run.focusLen
end
Runs.PhaseLen = PhaseLen

function Runs.PhaseLeft(run, now)
    return mmax(0, PhaseLen(run) - (Now(run, now) - run.phaseStartedAt))
end

-- The seconds a row shows: time left, or a stopwatch's time so far.
function Runs.Shown(run, now)
    if run.done then return 0 end
    local tool = run.tool
    if tool == "timer" then return mmax(0, run.duration - Runs.Elapsed(run, now)) end
    if tool == "alarm" then return mmax(0, run.at - now) end
    if tool == "pomodoro" then return Runs.PhaseLeft(run, now) end
    return Runs.Elapsed(run, now)
end

-- Steps a pomodoro past every phase end the clock has passed. Whole
-- cycles go in one step, so a long logout costs nothing.
local function Advance(run, now)
    local t = Now(run, now)
    local moved = false
    local cycle = run.focusLen + run.breakLen
    local cycles = mfloor((t - run.phaseStartedAt) / cycle)
    if cycles > 0 then
        run.phaseStartedAt = run.phaseStartedAt + cycles * cycle
        run.intervals = (run.intervals or 0) + cycles
        moved = true
    end
    while t - run.phaseStartedAt >= PhaseLen(run) do
        run.phaseStartedAt = run.phaseStartedAt + PhaseLen(run)
        if run.phase == "focus" then
            run.intervals = (run.intervals or 0) + 1
            run.phase = "break"
        else
            run.phase = "focus"
        end
        moved = true
    end
    return moved
end

-- Each end goes into events as { run, kind, away }; away (the login catch-up)
-- passes pomodoro phases silently. Ended runs stay until dismissed.
function Runs:Update(now, events, away)
    local runs = self:List()
    local changed = false
    for i = #runs, 1, -1 do
        local run = runs[i]
        local kind
        if not (run.done or run.pausedAt) then
            local tool = run.tool
            if tool == "timer" then
                if Runs.Elapsed(run, now) >= run.duration then kind = "timer" end
            elseif tool == "alarm" then
                if now >= run.at then kind = "alarm" end
            elseif tool == "stopwatch" then
                if run.mark and not run.markHit and Runs.Elapsed(run, now) >= run.mark then
                    run.markHit = true
                    kind = "mark"
                end
            elseif Advance(run, now) then
                changed = true
                if not away then kind = run.phase end
            end
            if kind then
                changed = true
                if kind == "timer" or kind == "alarm" then run.done, run.doneAt = true, now end
                if events then events[#events + 1] = { run = run, kind = kind, away = away or nil } end
            end
        end
    end
    return changed
end

-- A new run, or nil when the list is full. One pomodoro at a time: a new
-- one replaces the old. The same alarm twice is one alarm.
function Runs:Start(tool, now, a, b)
    local runs = self:List()
    for i = #runs, 1, -1 do
        local old = runs[i]
        if tool == "pomodoro" and old.tool == "pomodoro" then
            tremove(runs, i)
        elseif tool == "alarm" and old.tool == "alarm" and old.at == a and not old.done then
            return old
        end
    end
    if #runs >= Runs.MAX then
        for i = 1, #runs do
            if runs[i].done then
                tremove(runs, i)
                break
            end
        end
        if #runs >= Runs.MAX then return nil end
    end
    local run = { tool = tool, startedAt = now }
    if tool == "timer" then
        run.duration = a
    elseif tool == "stopwatch" then
        run.mark = a
    elseif tool == "alarm" then
        run.at = a
    else
        run.focusLen, run.breakLen = a, b
        run.phase, run.phaseStartedAt, run.intervals = "focus", now, 0
    end
    runs[#runs + 1] = run
    return run
end

function Runs:Cancel(run)
    local runs = self:List()
    for i = #runs, 1, -1 do
        if runs[i] == run then tremove(runs, i) end
    end
end

function Runs:CancelAll()
    local runs = self:List()
    for i = #runs, 1, -1 do runs[i] = nil end
end

function Runs:TogglePause(run, now)
    if run.done or run.tool == "alarm" then return end
    if run.pausedAt then
        local gap = mmax(0, now - run.pausedAt)
        run.startedAt = run.startedAt + gap
        if run.phaseStartedAt then run.phaseStartedAt = run.phaseStartedAt + gap end
        run.pausedAt = nil
    else
        run.pausedAt = now
    end
end

-- Back to the start; a timer that took +5 min gets its own length back.
function Runs:Restart(run, now)
    if run.tool == "alarm" then return end
    run.startedAt, run.pausedAt = now, nil
    run.done, run.doneAt, run.markHit = nil, nil, nil
    if run.base then run.duration, run.base = run.base, nil end
    if run.tool == "pomodoro" then
        run.phase, run.phaseStartedAt, run.intervals = "focus", now, 0
    end
end

-- An ended timer or alarm runs again for `seconds` (+5 min).
function Runs:Extend(run, now, seconds)
    if not run.done then return end
    run.done, run.doneAt, run.pausedAt = nil, nil, nil
    run.startedAt = now
    if run.tool == "alarm" then
        run.at = now + seconds
    else
        run.base = run.base or run.duration
        run.duration = seconds
    end
end

-- An ended run again: a timer for its own length, an alarm at `at`.
function Runs:Again(run, now, at)
    if run.tool == "alarm" then
        run.done, run.doneAt = nil, nil
        run.startedAt, run.at = now, at
        return
    end
    self:Restart(run, now)
end

-- Ends a pomodoro's phase now; returns the phase it moves to.
function Runs:SkipPhase(run, now)
    if run.tool ~= "pomodoro" or run.done then return nil end
    if run.phase == "focus" then
        run.intervals = (run.intervals or 0) + 1
        run.phase = "break"
    else
        run.phase = "focus"
    end
    run.phaseStartedAt = Now(run, now)
    return run.phase
end
