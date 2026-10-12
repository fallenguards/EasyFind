local _, ns = ...

local Commands = ns.SearchCommands
local Utils = ns.Utils
local L = ns.L

local smatch, slower, sformat = Utils.smatch, Utils.slower, Utils.sformat
local sgsub, sgmatch = string.gsub, string.gmatch
local mfloor, mmin, mmax = Utils.mfloor, Utils.mmin, Utils.mmax
local pairs, tonumber, type = Utils.pairs, tonumber, type
local strtrim = strtrim
local time, date = time, date

-- The clock's search-bar grammar. Core-owned: the command row must work
-- before the LoadOnDemand companion has ever loaded.
local Grammar = {}
ns.ClockGrammar = Grammar

local VERBS = {
    pom = "pomodoro", pomo = "pomodoro", pomodoro = "pomodoro",
    timer = "timer", time = "timer",
    stopwatch = "stopwatch", stop = "stopwatch",
    alarm = "alarm",
}
-- "time" and "stop" are everyday words: they need a number.
local BARE_VERBS = { pom = true, pomo = true, pomodoro = true, stopwatch = true }
local UNIT_SECONDS = { s = 1, m = 60, h = 3600 }
local UNIT_WORDS = {
    s = "s", sec = "s", secs = "s", second = "s", seconds = "s",
    m = "m", min = "m", mins = "m", minute = "m", minutes = "m",
    h = "h", hr = "h", hrs = "h", hour = "h", hours = "h",
}
local UNIT_KEYS = {
    pomodoro = { "clockFocusUnit", "clockBreakUnit" },
    timer = { "clockTimerUnit" },
    stopwatch = { "clockStopwatchUnit" },
}
local MERIDIEM = { am = false, a = false, pm = true, p = true }
if _G["TIMEMANAGER_AM"] then MERIDIEM[slower(_G["TIMEMANAGER_AM"])] = false end
if _G["TIMEMANAGER_PM"] then MERIDIEM[slower(_G["TIMEMANAGER_PM"])] = true end

Grammar.UNIT_SECONDS = UNIT_SECONDS
Grammar.MAX_SECONDS = 100 * 3600 - 1
Grammar.MIN_PHASE = 5

-- The unit a bare number means in a slot, from the settings.
function Grammar.DefaultUnit(tool, slot)
    local keys = UNIT_KEYS[tool]
    local key = keys and keys[slot or 1]
    local db = EasyFind and EasyFind.db
    local unit = key and db and db[key]
    return UNIT_SECONDS[unit] and unit or "m"
end

function Grammar.Seconds(n, unit, defaultUnit)
    if type(n) ~= "number" or n <= 0 then return nil end
    local sec = mfloor(n * (UNIT_SECONDS[unit or defaultUnit] or 60) + 0.5)
    if sec < 1 or sec > Grammar.MAX_SECONDS then return nil end
    return sec
end

local function SettingSeconds(value, fallback)
    if type(value) ~= "number" or value < Grammar.MIN_PHASE or value > Grammar.MAX_SECONDS then
        return fallback
    end
    return mfloor(value)
end

function Grammar.PomodoroDefaults()
    local db = EasyFind and EasyFind.db
    return SettingSeconds(db and db.clockFocusSeconds, 1500), SettingSeconds(db and db.clockBreakSeconds, 300)
end

-- "10" is 10 in the slot's unit (unit nil); "10m", "1h30m", "1h30",
-- "1:30" and "1:02:03" are seconds.
local function ParseDuration(token)
    local bare = smatch(token, "^(%d+%.?%d*)$")
    if bare then return tonumber(bare), nil end
    local h, m, s = smatch(token, "^(%d+):(%d%d):(%d%d)$")
    if h then
        if tonumber(m) > 59 or tonumber(s) > 59 then return nil end
        return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s), "s"
    end
    m, s = smatch(token, "^(%d+):(%d%d)$")
    if m then
        if tonumber(s) > 59 then return nil end
        return tonumber(m) * 60 + tonumber(s), "s"
    end
    local total, pos, last = 0, 1, nil
    while pos <= #token do
        local num, word, nextPos = smatch(token, "^(%d+%.?%d*)(%a*)()", pos)
        if not num then return nil end
        local unit = UNIT_WORDS[word]
        -- A trailing bare number is the next unit down: "1h30", "2m15".
        if word == "" and nextPos > #token then
            unit = (last == "h" and "m") or (last == "m" and "s") or nil
        end
        if not unit then return nil end
        total = total + tonumber(num) * UNIT_SECONDS[unit]
        last, pos = unit, nextPos
    end
    return total, "s"
end
Grammar.ParseDuration = ParseDuration

-- "7", "7:30", "19:30", "7pm", "7:30 pm" -> hour (0-23), minute, and
-- whether am or pm was given.
local function ParseClockTime(rest)
    local h, m, suffix = smatch(rest, "^(%d%d?):(%d%d)%s*(.-)$")
    if not h then
        h, suffix = smatch(rest, "^(%d%d?)%s*(.-)$")
        m = "0"
    end
    if not h then return nil end
    local hour, minute = tonumber(h), tonumber(m)
    if minute > 59 then return nil end
    if suffix == "" then
        if hour > 23 then return nil end
        return hour, minute, false
    end
    local pm = MERIDIEM[suffix]
    if pm == nil or hour < 1 or hour > 12 then return nil end
    return hour % 12 + (pm and 12 or 0), minute, true
end
Grammar.ParseClockTime = ParseClockTime

local function NextAt(now, hour, minute)
    local t = date("*t", now)
    t.hour, t.min, t.sec, t.isdst = hour, minute, 0, nil
    local at = time(t)
    if at <= now then
        t.day = t.day + 1
        at = time(t)
    end
    return at
end

-- The next time the clock reads hour:minute. Without am or pm, "7" is
-- whichever of 7:00 and 19:00 comes first.
function Grammar.AlarmTarget(hour, minute, explicit, now)
    local at = NextAt(now, hour, minute)
    if not explicit and hour >= 1 and hour <= 12 then
        at = mmin(at, NextAt(now, (hour + 12) % 24, minute))
    end
    return at
end

function Grammar.FormatDuration(sec)
    sec = mfloor(sec or 0)
    if sec < 0 then sec = 0 end
    local h = mfloor(sec / 3600)
    local m = mfloor((sec % 3600) / 60)
    if h > 0 then return sformat("%d:%02d:%02d", h, m, sec % 60) end
    return sformat("%d:%02d", m, sec % 60)
end

-- Wall-clock label in the player's 12 or 24 hour setting.
function Grammar.TimeLabel(at)
    local t = date("*t", at)
    if GameTime_GetFormattedTime then return GameTime_GetFormattedTime(t.hour, t.min, true) end
    return sformat("%d:%02d", t.hour, t.min)
end

local parsed = {}

-- A clock command, or nil for anything else. The result is one shared
-- table: copy what must outlive the next call.
function Grammar.Parse(text)
    if type(text) ~= "string" then return nil end
    local verb, rest = smatch(slower(strtrim(text)), "^(%a+)%s*(.*)$")
    local tool = verb and VERBS[verb]
    if not tool then return nil end
    parsed.tool = tool
    parsed.a1, parsed.u1, parsed.a2, parsed.u2 = nil, nil, nil, nil
    parsed.hour, parsed.min, parsed.explicit = nil, nil, nil
    if rest == "" then
        return BARE_VERBS[verb] and parsed or nil
    end
    rest = sgsub(rest, "%s+", " ")
    if tool == "alarm" then
        local hour, minute, explicit = ParseClockTime(rest)
        if not hour then return nil end
        parsed.hour, parsed.min, parsed.explicit = hour, minute, explicit
        return parsed
    end
    rest = sgsub(rest, "(%d) (%a)", "%1%2")
    if tool == "pomodoro" then
        local t1, t2, extra = smatch(sgsub(rest, "%s*/%s*", " "), "^(%S+) ?(%S*) ?(.*)$")
        if not t1 or extra ~= "" then return nil end
        parsed.a1, parsed.u1 = ParseDuration(t1)
        if not parsed.a1 then return nil end
        if t2 ~= "" then
            parsed.a2, parsed.u2 = ParseDuration(t2)
            if not parsed.a2 then return nil end
        end
        return parsed
    end
    -- One duration; several tokens add up only when each names its unit.
    local total, count, unit = 0, 0, nil
    for token in sgmatch(rest, "%S+") do
        local n, u = ParseDuration(token)
        if not n then return nil end
        count = count + 1
        if count > 1 and (u == nil or unit == nil) then return nil end
        total, unit = total + n, u
    end
    parsed.a1, parsed.u1 = total, unit
    return parsed
end

-- cmd.seconds (focus, duration or mark), cmd.seconds2 (break), cmd.at
-- (alarm); false when a value is out of range.
function Grammar.Resolve(cmd, now)
    local tool = cmd.tool
    cmd.seconds, cmd.seconds2, cmd.at = nil, nil, nil
    if tool == "alarm" then
        cmd.at = Grammar.AlarmTarget(cmd.hour, cmd.min, cmd.explicit, now)
        return true
    end
    if cmd.a1 then
        cmd.seconds = Grammar.Seconds(cmd.a1, cmd.u1, Grammar.DefaultUnit(tool, 1))
        if not cmd.seconds then return false end
    end
    if tool == "pomodoro" then
        local focus, brk = Grammar.PomodoroDefaults()
        if cmd.a2 then
            brk = Grammar.Seconds(cmd.a2, cmd.u2, Grammar.DefaultUnit(tool, 2))
            if not brk then return false end
        end
        cmd.seconds = mmax(cmd.seconds or focus, Grammar.MIN_PHASE)
        cmd.seconds2 = mmax(brk, Grammar.MIN_PHASE)
    elseif tool == "timer" then
        return cmd.seconds ~= nil
    end
    return true
end

-- The row a clock command shows: Enter on it starts the run.
local pending = {}
local Format = Grammar.FormatDuration

local function RunPendingCommand()
    if ns.RequestClock() and ns.Clock.StartFromCommand then
        ns.Clock.StartFromCommand(pending)
    end
end

local commandEntry = {
    clockCommand = true,
    noPin = true,
    noLearn = true,
    nativeRun = RunPendingCommand,
}

function Commands:GetClockCommandEntry(text)
    local cmd = Grammar.Parse(text)
    if not cmd then return nil end
    if ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Clock") then return nil end
    local now = time()
    if not Grammar.Resolve(cmd, now) then return nil end
    for k in pairs(pending) do pending[k] = nil end
    for k, v in pairs(cmd) do pending[k] = v end
    local entry = commandEntry
    local tool = cmd.tool
    if tool == "pomodoro" then
        entry.name = L["CLOCK_CMD_POMODORO"]
        entry.searchCommandDesc = sformat(L["CLOCK_POM_DESC"], Format(cmd.seconds), Format(cmd.seconds2))
    elseif tool == "timer" then
        entry.name = L["CLOCK_CMD_TIMER"]
        entry.searchCommandDesc = Format(cmd.seconds)
    elseif tool == "stopwatch" then
        entry.name = L["CLOCK_CMD_STOPWATCH"]
        entry.searchCommandDesc = cmd.seconds and sformat(L["CLOCK_MARK_DESC"], Format(cmd.seconds))
            or ns.CLOCK_NAME
    else
        entry.name = L["CLOCK_CMD_ALARM"]
        entry.searchCommandDesc = sformat(L["CLOCK_ALARM_DESC"], Grammar.TimeLabel(cmd.at), Format(cmd.at - now))
    end
    entry.clockTool = tool
    entry.nameLower = slower(entry.name)
    return entry
end
