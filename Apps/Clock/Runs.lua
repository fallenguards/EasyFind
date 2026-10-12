local ns = EasyFind and EasyFind._ns
if not ns then return end

local Utils = ns.Utils
local mfloor, mmax = Utils.mfloor, Utils.mmax
local tremove, tinsert, tsort = Utils.tremove, Utils.tinsert, Utils.tsort
local type, date, strtrim = type, date, strtrim

-- Runs keep wall-clock times from time(): what is left is always derived,
-- so a reload or a logout costs nothing.
local Runs = {}
ns.ClockRuns = Runs

Runs.MAX = 10
Runs.LAPS_MAX = 50
Runs.RECENT_MAX = 3
Runs.PRESETS_MAX = 8
Runs.NAME_MAX = 24
Runs.DEFAULT_PRESETS = { 60, 300, 600, 900, 1800 }
-- From the settings, set by the clock before each pass.
Runs.autoNext = true
Runs.longEvery, Runs.longLen = 4, 900
local DB_VERSION = 3

local TOOLS = { pomodoro = true, timer = true, stopwatch = true, alarm = true }

local function IsNumber(v)
    return type(v) == "number" and v == v
end

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
    -- Alarms became a kept list; one still waiting moves there.
    [3] = function(sv)
        if type(sv.alarms) ~= "table" then sv.alarms = {} end
        sv.nextAlarmID = IsNumber(sv.nextAlarmID) and sv.nextAlarmID or 1
        if type(sv.runs) ~= "table" then return end
        for i = #sv.runs, 1, -1 do
            local run = sv.runs[i]
            if type(run) == "table" and run.tool == "alarm" and IsNumber(run.at) then
                local t = date("*t", run.at)
                run.hour, run.min = t.hour, t.min
                if not run.done then
                    sv.alarms[#sv.alarms + 1] = {
                        id = sv.nextAlarmID, hour = t.hour, min = t.min, days = 0, enabled = true,
                        next = run.at, armedAt = run.startedAt, name = run.name,
                    }
                    sv.nextAlarmID = sv.nextAlarmID + 1
                    tremove(sv.runs, i)
                end
            end
        end
    end,
}

local function IsValid(run)
    if type(run) ~= "table" or not TOOLS[run.tool] or not IsNumber(run.startedAt) then return false end
    if run.pausedAt ~= nil and not IsNumber(run.pausedAt) then return false end
    if run.done and not IsNumber(run.doneAt) then return false end
    if run.name ~= nil and type(run.name) ~= "string" then return false end
    local tool = run.tool
    if tool == "timer" then
        return IsNumber(run.duration) and run.duration > 0 and (run.base == nil or IsNumber(run.base))
    end
    if tool == "alarm" then return IsNumber(run.at) end
    if tool == "stopwatch" then
        if run.laps ~= nil then
            if type(run.laps) ~= "table" then return false end
            for i = 1, #run.laps do
                if not IsNumber(run.laps[i]) then return false end
            end
        end
        return run.mark == nil or (IsNumber(run.mark) and run.mark > 0)
    end
    if run.longLen ~= nil and not (IsNumber(run.longLen) and run.longLen >= 1) then return false end
    if run.longEvery ~= nil and not IsNumber(run.longEvery) then return false end
    return IsNumber(run.focusLen) and run.focusLen >= 1 and IsNumber(run.breakLen) and run.breakLen >= 1
        and (run.phase == "focus" or run.phase == "break") and IsNumber(run.phaseStartedAt)
end

local function NumberList(list, fallback)
    if type(list) ~= "table" then return fallback end
    for i = #list, 1, -1 do
        if not (IsNumber(list[i]) and list[i] > 0) then tremove(list, i) end
    end
    return list
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
    if type(sv.alarms) ~= "table" then sv.alarms = {} end
    if not IsNumber(sv.nextAlarmID) then sv.nextAlarmID = 1 end
    local presets = {}
    for i = 1, #Runs.DEFAULT_PRESETS do presets[i] = Runs.DEFAULT_PRESETS[i] end
    sv.timerPresets = NumberList(sv.timerPresets, presets)
    sv.recent = NumberList(sv.recent, {})
    if type(sv.pomStats) ~= "table" then sv.pomStats = {} end
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
    if run.phase == "break" then return run.long and run.longLen or run.breakLen end
    return run.focusLen
end
Runs.PhaseLen = PhaseLen

function Runs.PhaseLeft(run, now)
    return mmax(0, PhaseLen(run) - (Now(run, now) - run.phaseStartedAt))
end

-- The seconds a card shows: time left, or a stopwatch's time so far.
function Runs.Shown(run, now)
    if run.done then return 0 end
    local tool = run.tool
    if tool == "timer" then return mmax(0, run.duration - Runs.Elapsed(run, now)) end
    if tool == "alarm" then return mmax(0, run.at - now) end
    if tool == "pomodoro" then return Runs.PhaseLeft(run, now) end
    return Runs.Elapsed(run, now)
end

-- One pomodoro set: its length and how many focus rounds it holds.
local function SetLength(run)
    local n = run.longEvery
    if not (n and n > 0 and run.longLen) then return run.focusLen + run.breakLen, 1 end
    return n * run.focusLen + (n - 1) * run.breakLen + run.longLen, n
end

local function NextPhase(run)
    if run.phase == "focus" then
        run.intervals = (run.intervals or 0) + 1
        run.phase = "break"
        local n = run.longEvery
        run.long = (n and n > 0 and run.longLen and run.intervals % n == 0) or nil
    else
        run.phase, run.long = "focus", nil
    end
end

-- Steps a pomodoro past every phase end the clock has passed, whole sets
-- at a time. Without auto start it stops at the next phase and waits.
local function Advance(run, now)
    local t = Now(run, now)
    local moved = false
    while true do
        if Runs.autoNext and run.phase == "focus" then
            local len, rounds = SetLength(run)
            if (run.intervals or 0) % rounds == 0 then
                local sets = mfloor((t - run.phaseStartedAt) / len)
                if sets > 0 then
                    run.phaseStartedAt = run.phaseStartedAt + sets * len
                    run.intervals = (run.intervals or 0) + sets * rounds
                    moved = true
                end
            end
        end
        if t - run.phaseStartedAt < PhaseLen(run) then break end
        run.phaseStartedAt = run.phaseStartedAt + PhaseLen(run)
        NextPhase(run)
        moved = true
        if not Runs.autoNext then
            run.waiting, run.pausedAt = true, run.phaseStartedAt
            break
        end
    end
    return moved
end

local function Today(now)
    return date("%Y-%m-%d", now)
end

function Runs:RoundsToday(now)
    local stats = self.sv and self.sv.pomStats
    if not (stats and stats.day == Today(now)) then return 0 end
    return stats.count or 0
end

local function CountRound(sv, now)
    local stats, day = sv.pomStats, Today(now)
    if stats.day ~= day then stats.day, stats.count = day, 0 end
    stats.count = (stats.count or 0) + 1
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
                if not away then
                    kind = run.phase
                    if kind == "break" then CountRound(self.sv, now) end
                end
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

local function CleanName(name)
    if type(name) ~= "string" then return nil end
    name = strtrim(name)
    if name == "" then return nil end
    return name:sub(1, Runs.NAME_MAX)
end
Runs.CleanName = CleanName

-- Room for one more run: an ended one gives way.
local function MakeRoom(runs)
    if #runs < Runs.MAX then return true end
    for i = 1, #runs do
        if runs[i].done then
            tremove(runs, i)
            return true
        end
    end
    return false
end

-- A new run, or nil when the list is full. One pomodoro at a time: a new
-- one replaces the old.
function Runs:Start(tool, now, a, b, name)
    local runs = self:List()
    if tool == "pomodoro" then
        for i = #runs, 1, -1 do
            if runs[i].tool == "pomodoro" then tremove(runs, i) end
        end
    end
    if not MakeRoom(runs) then return nil end
    local run = { tool = tool, startedAt = now, name = CleanName(name) }
    if tool == "timer" then
        run.duration = a
        self:NoteRecent(a)
    elseif tool == "stopwatch" then
        run.mark = a
    elseif tool == "alarm" then
        run.at = a
    else
        run.focusLen, run.breakLen = a, b
        run.phase, run.phaseStartedAt, run.intervals = "focus", now, 0
        if Runs.longEvery and Runs.longEvery > 0 then
            run.longEvery, run.longLen = Runs.longEvery, Runs.longLen
        end
    end
    runs[#runs + 1] = run
    return run
end

-- A kept alarm ringing: an ended card that waits for Snooze or Dismiss.
function Runs:Ring(alarm, now)
    local runs = self:List()
    MakeRoom(runs)
    local run = {
        tool = "alarm", startedAt = alarm.armedAt or now, at = alarm.next or now,
        done = true, doneAt = now, name = alarm.name, hour = alarm.hour, min = alarm.min,
        server = alarm.server, alarmID = alarm.id,
    }
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

-- Pause and resume; a pomodoro waiting between phases starts the next one.
function Runs:TogglePause(run, now)
    if run.done or run.tool == "alarm" then return end
    if run.pausedAt then
        local gap = mmax(0, now - run.pausedAt)
        run.startedAt = run.startedAt + gap
        if run.phaseStartedAt then run.phaseStartedAt = run.phaseStartedAt + gap end
        run.pausedAt, run.waiting = nil, nil
    else
        run.pausedAt = now
    end
end

-- Back to the start; a timer that took +5 min gets its own length back.
function Runs:Restart(run, now)
    if run.tool == "alarm" then return end
    run.startedAt, run.pausedAt, run.waiting = now, nil, nil
    run.done, run.doneAt, run.markHit = nil, nil, nil
    if run.base then run.duration, run.base = run.base, nil end
    if run.tool == "stopwatch" then run.laps = nil end
    if run.tool == "pomodoro" then
        run.phase, run.phaseStartedAt, run.intervals, run.long = "focus", now, 0, nil
    end
end

-- An ended timer runs again for `seconds` (+5 min); an alarm snoozes.
function Runs:Extend(run, now, seconds)
    if not run.done then return end
    run.done, run.doneAt, run.pausedAt = nil, nil, nil
    run.startedAt = now
    if run.tool == "alarm" then
        run.at, run.snoozed = now + seconds, true
    else
        run.base = run.base or run.duration
        run.duration = seconds
    end
end

-- An ended run again: a timer for its own length, an alarm at `at`.
function Runs:Again(run, now, at)
    if run.tool == "alarm" then
        run.done, run.doneAt, run.snoozed = nil, nil, nil
        run.startedAt, run.at = now, at
        return
    end
    self:Restart(run, now)
end

-- A running timer's minute up or down; it always keeps a second to go, and
-- a restart gives back its own length.
function Runs:Adjust(run, now, delta)
    if run.tool ~= "timer" or run.done then return end
    run.base = run.base or run.duration
    run.duration = mmax(Runs.Elapsed(run, now) + 1, run.duration + delta)
end

-- A stopwatch lap: the total so far, splits come from the difference.
function Runs:Lap(run, now)
    if run.tool ~= "stopwatch" or run.done then return end
    run.laps = run.laps or {}
    if #run.laps >= Runs.LAPS_MAX then tremove(run.laps, 1) end
    run.laps[#run.laps + 1] = Runs.Elapsed(run, now)
    run.lapsOpen = true
end

function Runs:Rename(run, name)
    run.name = CleanName(name)
end

-- Ends a pomodoro's phase now and starts the next; returns that phase.
function Runs:SkipPhase(run, now)
    if run.tool ~= "pomodoro" or run.done then return nil end
    NextPhase(run)
    run.phaseStartedAt, run.pausedAt, run.waiting = now, nil, nil
    return run.phase
end

-- Timer lengths: the presets on the tile and the ones used lately.

function Runs:Presets()
    return self.sv.timerPresets
end

function Runs:Recent()
    return self.sv.recent
end

local function IndexOf(list, value)
    for i = 1, #list do
        if list[i] == value then return i end
    end
    return nil
end

function Runs:NoteRecent(seconds)
    local sv = self.sv
    if not (sv and IsNumber(seconds)) or IndexOf(sv.timerPresets, seconds) then return end
    local i = IndexOf(sv.recent, seconds)
    if i then tremove(sv.recent, i) end
    tinsert(sv.recent, 1, seconds)
    while #sv.recent > Runs.RECENT_MAX do tremove(sv.recent) end
end

function Runs:AddPreset(seconds)
    local presets = self.sv.timerPresets
    if IndexOf(presets, seconds) or #presets >= Runs.PRESETS_MAX then return false end
    presets[#presets + 1] = seconds
    tsort(presets)
    local i = IndexOf(self.sv.recent, seconds)
    if i then tremove(self.sv.recent, i) end
    return true
end

function Runs:RemovePreset(seconds)
    local i = IndexOf(self.sv.timerPresets, seconds)
    if i then tremove(self.sv.timerPresets, i) end
end
