local _, ns = ...

local Commands = ns.SearchCommands
local Utils = ns.Utils
local L = ns.L

local smatch, slower, sformat = Utils.smatch, Utils.slower, Utils.sformat
local sgsub, sgmatch = string.gsub, string.gmatch
local mfloor, mmax = Utils.mfloor, Utils.mmax
local pairs, tonumber, tostring, type = Utils.pairs, tonumber, tostring, type
local strtrim, strsplit, tconcat = strtrim, strsplit, table.concat
local time, date = time, date

-- The clock's search-bar grammar. Core-owned: the command row must work
-- before the LoadOnDemand companion has ever loaded.
local Grammar = {}
ns.ClockGrammar = Grammar

local VERBS = {
    pom = "pomodoro", pomo = "pomodoro", pomodoro = "pomodoro",
    timer = "timer", time = "timer",
    stopwatch = "stopwatch", stop = "stopwatch", sw = "stopwatch",
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

-- Repeat days as a sum of 2^(wday - 1), wday 1 being Sunday as date() has it.
-- 0 rings once.
Grammar.DAILY, Grammar.WEEKDAYS, Grammar.WEEKENDS = 127, 62, 65

function Grammar.HasDay(days, wday)
    return mfloor(days / 2 ^ (wday - 1)) % 2 == 1
end

function Grammar.JoinDays(a, b)
    local out = 0
    for wday = 1, 7 do
        if Grammar.HasDay(a, wday) or Grammar.HasDay(b, wday) then out = out + 2 ^ (wday - 1) end
    end
    return mfloor(out)
end

-- The next moment after `now` the clock reads hour:minute on an allowed day.
-- offset (seconds) moves the clock to realm time. Without am or pm, "7" is
-- whichever of 7:00 and 19:00 comes first.
function Grammar.NextOccurrence(hour, minute, days, explicit, now, offset)
    offset, days = offset or 0, days or 0
    local s = now + offset
    local t = date("*t", s)
    local best
    for pass = 1, (not explicit and hour >= 1 and hour <= 12) and 2 or 1 do
        local h = pass == 1 and hour or (hour + 12) % 24
        for d = 0, 7 do
            local at = time({ year = t.year, month = t.month, day = t.day + d, hour = h, min = minute, sec = 0 })
            if at > s and (days == 0 or Grammar.HasDay(days, date("*t", at).wday)) then
                if not best or at < best then best = at end
                break
            end
        end
    end
    return best - offset
end

function Grammar.AlarmTarget(hour, minute, explicit, now)
    return Grammar.NextOccurrence(hour, minute, 0, explicit, now, 0)
end

-- Realm time minus local time, from the game clock's minutes.
function Grammar.ServerOffset(now)
    local GetGameTime = _G["GetGameTime"]
    if not GetGameTime then return 0 end
    local h, m = GetGameTime()
    local t = date("*t", now)
    local diff = (h * 60 + m) - (t.hour * 60 + t.min)
    return ((diff + 720) % 1440 - 720) * 60
end

-- "Once", "Daily", "Weekdays", "Weekends" or "Mon, Wed, Fri".
function Grammar.RepeatLabel(days)
    days = days or 0
    if days == 0 then return L["CLOCK_ONCE"] end
    if days == Grammar.DAILY then return L["CLOCK_DAILY"] end
    if days == Grammar.WEEKDAYS then return L["CLOCK_WEEKDAYS"] end
    if days == Grammar.WEEKENDS then return L["CLOCK_WEEKENDS"] end
    local names, out = { strsplit(",", L["CLOCK_DAY_SHORT"]) }, {}
    for wday = 1, 7 do
        if Grammar.HasDay(days, wday) then out[#out + 1] = names[wday] or tostring(wday) end
    end
    return tconcat(out, ", ")
end

function Grammar.FormatDuration(sec)
    sec = mfloor(sec or 0)
    if sec < 0 then sec = 0 end
    local h = mfloor(sec / 3600)
    local m = mfloor((sec % 3600) / 60)
    if h > 0 then return sformat("%d:%02d:%02d", h, m, sec % 60) end
    return sformat("%d:%02d", m, sec % 60)
end

-- hour:minute in the player's 12 or 24 hour setting; realm times say so.
function Grammar.ClockLabel(hour, minute, server)
    local text = GameTime_GetFormattedTime and GameTime_GetFormattedTime(hour, minute, true)
        or sformat("%d:%02d", hour, minute)
    if server then return sformat(L["CLOCK_REALM_FMT"], text) end
    return text
end

function Grammar.TimeLabel(at)
    local t = date("*t", at)
    return Grammar.ClockLabel(t.hour, t.min)
end

-- Words after an alarm's time, before its name.
local REPEAT_WORDS = {
    once = 0, daily = 127, everyday = 127, weekdays = 62, weekends = 65,
    sun = 1, sunday = 1, mon = 2, monday = 2, tue = 4, tues = 4, tuesday = 4,
    wed = 8, wednesday = 8, thu = 16, thur = 16, thurs = 16, thursday = 16,
    fri = 32, friday = 32, sat = 64, saturday = 64,
}
local SERVER_WORDS = { server = true, realm = true }
-- "time" and "stop" are everyday words: a number, and no name after it.
local PLAIN_VERBS = { time = true, stop = true }
Grammar.NAME_MAX = 24

local parsed, words, lowered = {}, {}, {}

-- The words of a command, a number and its unit word ("10 min", "7:30 pm")
-- joined into one.
local function Split(rest)
    for i = #words, 1, -1 do words[i], lowered[i] = nil, nil end
    for word in sgmatch(rest, "%S+") do
        local low = slower(word)
        local n = #words
        if n > 0 and smatch(lowered[n], "^[%d%.:]+$") and (UNIT_WORDS[low] or MERIDIEM[low] ~= nil) then
            words[n], lowered[n] = words[n] .. word, lowered[n] .. low
        else
            words[n + 1], lowered[n + 1] = word, low
        end
    end
end

-- What is left from word i on, as the run's name.
local function NameFrom(i)
    if i > #words then return nil end
    local name = strtrim(tconcat(words, " ", i))
    if name == "" then return nil end
    return name:sub(1, Grammar.NAME_MAX)
end

local function ParseAlarm()
    local hour, minute, explicit = ParseClockTime(lowered[1] or "")
    if not hour then return nil end
    parsed.hour, parsed.min, parsed.explicit = hour, minute, explicit
    local i = 2
    while lowered[i] do
        local low = lowered[i]
        if SERVER_WORDS[low] then
            parsed.server = true
        else
            local days = parsed.days or 0
            for part in sgmatch(low, "[^,]+") do
                local d = REPEAT_WORDS[part]
                if not d then
                    days = nil
                    break
                end
                days = Grammar.JoinDays(days, d)
            end
            if not days then break end
            parsed.days = days
        end
        i = i + 1
    end
    parsed.name = NameFrom(i)
    return parsed
end

-- Durations first, then the name: up to two for a pomodoro, any number
-- for a timer or a stopwatch as long as each names its unit.
local function ParseDurations(limit)
    local i, count, unit = 1, 0, nil
    while lowered[i] and (not limit or count < limit) do
        local n, u = ParseDuration(lowered[i])
        if not n then break end
        count = count + 1
        if limit then
            if count == 1 then parsed.a1, parsed.u1 = n, u else parsed.a2, parsed.u2 = n, u end
        else
            if count > 1 and (u == nil or unit == nil) then return nil end
            parsed.a1, parsed.u1 = (parsed.a1 or 0) + n, u
            unit = u
        end
        i = i + 1
    end
    return i
end

-- A clock command, or nil for anything else. The result is one shared
-- table: copy what must outlive the next call.
function Grammar.Parse(text)
    if type(text) ~= "string" then return nil end
    local trimmed = strtrim(text)
    local verbWord, rest = smatch(trimmed, "^(%a+)%s*(.*)$")
    local verb = verbWord and slower(verbWord)
    local tool = verb and VERBS[verb]
    if not tool then return nil end
    parsed.tool = tool
    parsed.a1, parsed.u1, parsed.a2, parsed.u2 = nil, nil, nil, nil
    parsed.hour, parsed.min, parsed.explicit = nil, nil, nil
    parsed.name, parsed.days, parsed.server = nil, nil, nil
    if tool == "pomodoro" then rest = sgsub(rest, "(%d)%s*/%s*(%d)", "%1 %2") end
    Split(rest)
    if #words == 0 then
        return BARE_VERBS[verb] and parsed or nil
    end
    if tool == "alarm" then return ParseAlarm() end
    local i = ParseDurations(tool == "pomodoro" and 2 or nil)
    if not i then return nil end
    if tool == "timer" and not parsed.a1 then return nil end
    -- A word that looks like a length but is not one is no name.
    if lowered[i] and smatch(lowered[i], "^%d") then return nil end
    parsed.name = NameFrom(i)
    if parsed.name and PLAIN_VERBS[verb] then return nil end
    if not parsed.a1 and not parsed.name and not BARE_VERBS[verb] then return nil end
    return parsed
end

-- cmd.seconds (focus, duration or mark), cmd.seconds2 (break), cmd.at
-- (alarm); false when a value is out of range.
function Grammar.Resolve(cmd, now)
    local tool = cmd.tool
    cmd.seconds, cmd.seconds2, cmd.at = nil, nil, nil
    if tool == "alarm" then
        local offset = cmd.server and Grammar.ServerOffset(now) or 0
        cmd.at = Grammar.NextOccurrence(cmd.hour, cmd.min, cmd.days, cmd.explicit, now, offset)
        -- The hour the clock will read then, for the alarm list.
        local t = date("*t", cmd.at + offset)
        cmd.hour, cmd.min, cmd.explicit = t.hour, t.min, true
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
        local desc = sformat(L["CLOCK_ALARM_DESC"], Grammar.ClockLabel(cmd.hour, cmd.min, cmd.server),
            Format(cmd.at - now))
        entry.searchCommandDesc = cmd.days and sformat(L["CLOCK_DOT_FMT"], desc, Grammar.RepeatLabel(cmd.days))
            or desc
    end
    if cmd.name then entry.name = sformat(L["CLOCK_CMD_NAMED"], entry.name, cmd.name) end
    entry.clockTool = tool
    entry.nameLower = slower(entry.name)
    return entry
end
