-- Names and repeats in the grammar, kept alarms, snooze, timer nudges and
-- presets, stopwatch laps, pomodoro long breaks and the wait between phases.
local H = require("Harness")

local function load(db, gameTime)
    local env = H.newEnv()
    env.time, env.date = os.time, os.date
    env.GameTime_GetFormattedTime = function(h, m) return string.format("%02d:%02d", h, m) end
    env.GetGameTime = gameTime
    env._G = env
    env.EasyFind.db = db or {}
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    ns.SearchCommands = {}
    H.loadModule("Search/ClockCommands.lua", env, ns)
    H.loadModule("Apps/Clock/Runs.lua", env, ns)
    H.loadModule("Apps/Clock/Alarms.lua", env, ns)
    local sv = ns.ClockRuns:Attach(nil, 1000)
    ns.ClockAlarms:Attach(sv)
    return ns.ClockGrammar, ns.ClockRuns, ns.ClockAlarms, sv
end

-- Sunday 2026-10-11 at the given local time.
local function at(hour, min, dayOffset)
    return os.time({ year = 2026, month = 10, day = 11 + (dayOffset or 0), hour = hour, min = min, sec = 0 })
end

local function parse(G, text, now)
    local cmd = G.Parse(text)
    if cmd then G.Resolve(cmd, now or at(18, 0)) end
    return cmd
end

local tests = {}

-- Grammar

function tests.names_onEveryKind()
    local G = load()
    local cmd = parse(G, "timer 10 pizza")
    H.assertEq(cmd.seconds, 600)
    H.assertEq(cmd.name, "pizza")
    cmd = parse(G, "timer 10 min Pizza Oven")
    H.assertEq(cmd.seconds, 600, "a unit word stays with its number")
    H.assertEq(cmd.name, "Pizza Oven", "the name keeps its case")
    cmd = parse(G, "pom 25 5 study")
    H.assertEq(cmd.seconds, 1500)
    H.assertEq(cmd.seconds2, 300)
    H.assertEq(cmd.name, "study")
    cmd = parse(G, "pom 25/5 study")
    H.assertEq(cmd.seconds2, 300)
    H.assertEq(cmd.name, "study")
    cmd = parse(G, "pom study")
    H.assertEq(cmd.seconds, 1500, "the default lengths")
    H.assertEq(cmd.name, "study")
    cmd = parse(G, "sw boss")
    H.assertEq(cmd.tool, "stopwatch")
    H.assertEq(cmd.name, "boss")
    cmd = parse(G, "stopwatch 10m pull")
    H.assertEq(cmd.seconds, 600)
    H.assertEq(cmd.name, "pull")
    cmd = parse(G, "alarm 7:30pm raid")
    H.assertEq(cmd.hour, 19)
    H.assertEq(cmd.min, 30)
    H.assertEq(cmd.name, "raid")
    H.assertNil(cmd.days, "no repeat given")
    cmd = parse(G, "alarm 7 pm raid night")
    H.assertEq(cmd.hour, 19)
    H.assertEq(cmd.name, "raid night")
    cmd = parse(G, "timer 1 " .. string.rep("x", 40))
    H.assertEq(#cmd.name, G.NAME_MAX, "names are cut to fit")
end

function tests.names_neverHijackSearches()
    local G = load()
    for _, text in ipairs({ "time 2 tickets", "stop attack", "stop 5 more", "sw", "timer pizza",
                            "timer 10 5", "pom 25 5 3" }) do
        H.assertNil(G.Parse(text), "not a clock command: " .. text)
    end
end

function tests.alarm_repeatWords()
    local G = load()
    local cases = {
        { "alarm 7pm daily", 127 }, { "alarm 7pm weekdays", 62 }, { "alarm 7pm weekends", 65 },
        { "alarm 7pm mon,wed,fri", 2 + 8 + 32 }, { "alarm 7pm mon wed", 2 + 8 }, { "alarm 7pm once", 0 },
        { "alarm 7pm tue thursday raid", 4 + 16 },
    }
    for _, c in ipairs(cases) do
        local cmd = parse(G, c[1])
        H.assertEq(cmd.days, c[2], c[1])
    end
    H.assertEq(parse(G, "alarm 7pm tue thursday raid").name, "raid")
    H.assertEq(G.RepeatLabel(0), "CLOCK_ONCE")
    H.assertEq(G.RepeatLabel(127), "CLOCK_DAILY")
end

function tests.alarm_nextOccurrenceHonorsDays()
    local G = load()
    -- Sunday 18:00: the next weekday 7:00 is Monday.
    H.assertEq(G.NextOccurrence(7, 0, 62, true, at(18, 0), 0), at(7, 0, 1))
    -- Friday only, from Sunday: five days on.
    H.assertEq(G.NextOccurrence(7, 0, 32, true, at(18, 0), 0), at(7, 0, 5))
    -- Sunday only, already past today: next week.
    H.assertEq(G.NextOccurrence(7, 0, 1, true, at(18, 0), 0), at(7, 0, 7))
    H.assertEq(G.NextOccurrence(20, 0, 1, true, at(18, 0), 0), at(20, 0), "later today still counts")
end

function tests.alarm_realmTime()
    -- The realm is three hours ahead of this machine.
    local G = load(nil, function() return 21, 0 end)
    local now = at(18, 0)
    H.assertEq(G.ServerOffset(now), 3 * 3600)
    local cmd = parse(G, "alarm 21:30 server raid", now)
    H.assertTrue(cmd.server)
    H.assertEq(cmd.at, at(18, 30), "21:30 realm time is 18:30 here")
    H.assertEq(cmd.hour, 21, "the list shows the realm's hour")
end

-- Kept alarms

function tests.alarms_oneOffSwitchesOffAfterRinging()
    local _, R, A = load()
    local now = at(18, 0)
    local alarm = A:Add(now, 19, 30, 0, "raid")
    H.assertEq(alarm.next, at(19, 30))
    H.assertEq(A:Add(now, 19, 30, 0, "raid"), alarm, "the same alarm twice is one")
    local due = A:Due(at(19, 30), {})
    H.assertEq(due[1], alarm)
    local run = R:Ring(alarm, at(19, 30))
    A:Rang(alarm, at(19, 30))
    H.assertTrue(run.done, "a ringing card")
    H.assertEq(run.name, "raid")
    H.assertFalse(alarm.enabled, "a one-off switches itself off")
    H.assertNil(alarm.next)
    H.assertEq(#A:Due(at(23, 0), {}), 0)
end

function tests.alarms_repeatingReArms()
    local _, R, A = load()
    local alarm = A:Add(at(6, 0), 7, 0, 62, "work")
    H.assertEq(alarm.next, at(7, 0, 1), "Sunday morning: Monday is next")
    R:Ring(alarm, at(7, 0, 1))
    A:Rang(alarm, at(7, 0, 1))
    H.assertTrue(alarm.enabled, "a repeating alarm stays on")
    H.assertEq(alarm.next, at(7, 0, 2), "and arms for Tuesday")
    A:SetEnabled(alarm, false, at(8, 0, 2))
    H.assertNil(alarm.next)
    A:SetEnabled(alarm, true, at(8, 0, 2))
    H.assertEq(alarm.next, at(7, 0, 3))
    A:Edit(alarm, at(8, 0, 2), 9, 15, 127, "late")
    H.assertEq(alarm.next, at(9, 15, 2), "an edit arms for the new time")
    H.assertEq(alarm.name, "late")
    A:Delete(alarm)
    H.assertEq(#A:List(), 0)
end

function tests.alarms_snoozeAndDismiss()
    local _, R, A = load()
    local alarm = A:Add(at(18, 0), 19, 0, 0)
    local run = R:Ring(alarm, at(19, 0))
    R:Extend(run, at(19, 0), 9 * 60)
    H.assertFalse(run.done, "snoozed")
    H.assertTrue(run.snoozed)
    H.assertEq(R.Shown(run, at(19, 0)), 540)
    local events = {}
    R:Update(at(19, 9), events)
    H.assertEq(events[1].kind, "alarm", "rings again after the snooze")
    H.assertTrue(run.done)
    R:Cancel(run)
    H.assertEq(#R:List(), 0, "Dismiss")
end

-- Timers

function tests.timer_nudgesAndRestart()
    local _, R = load()
    local timer = R:Start("timer", 1000, 600, nil, "tea")
    H.assertEq(timer.name, "tea")
    R:Adjust(timer, 1100, 60)
    H.assertEq(R.Shown(timer, 1100), 560, "+1 min")
    R:Adjust(timer, 1100, -60)
    R:Adjust(timer, 1100, -60)
    H.assertEq(R.Shown(timer, 1100), 440, "-1 min twice")
    R:Adjust(timer, 1590, -600)
    H.assertEq(R.Shown(timer, 1590), 1, "never past the end")
    R:Restart(timer, 2000)
    H.assertEq(R.Shown(timer, 2000), 600, "restart: its own length again")
end

function tests.timer_presetsAndRecent()
    local _, R = load()
    H.assertEq(#R:Presets(), 5, "the default presets")
    R:Start("timer", 1000, 2700)
    R:Start("timer", 1000, 300)
    H.assertEq(R:Recent()[1], 2700, "a length not a preset is remembered")
    H.assertEq(#R:Recent(), 1, "a preset length is not")
    R:Start("timer", 1000, 90)
    R:Start("timer", 1000, 120)
    R:Start("timer", 1000, 150)
    H.assertEq(#R:Recent(), R.RECENT_MAX)
    H.assertEq(R:Recent()[1], 150, "newest first")
    H.assertTrue(R:AddPreset(150))
    H.assertFalse(R:AddPreset(150), "once only")
    H.assertEq(R:Recent()[1], 120, "a saved length leaves the recent list")
    R:RemovePreset(60)
    H.assertEq(#R:Presets(), 5)
    H.assertEq(R:Presets()[1], 150, "kept in order")
end

-- Stopwatch

function tests.stopwatch_laps()
    local _, R = load()
    local sw = R:Start("stopwatch", 1000, nil, nil, "boss")
    R:Lap(sw, 1030)
    R:Lap(sw, 1075)
    H.assertEq(#sw.laps, 2)
    H.assertEq(sw.laps[2] - sw.laps[1], 45, "split")
    H.assertEq(sw.laps[2], 75, "total")
    H.assertTrue(sw.lapsOpen)
    R:TogglePause(sw, 1080)
    R:Lap(sw, 1200)
    H.assertEq(sw.laps[3], 80, "a paused stopwatch laps at the paused time")
    R:Restart(sw, 1300)
    H.assertNil(sw.laps, "reset clears the laps")
    for i = 1, R.LAPS_MAX + 5 do R:Lap(sw, 1300 + i) end
    H.assertEq(#sw.laps, R.LAPS_MAX, "the oldest laps give way")
end

-- Pomodoro

function tests.pomodoro_longBreak()
    local _, R = load()
    R.autoNext, R.longEvery, R.longLen = true, 2, 900
    local pom = R:Start("pomodoro", 0, 100, 10, "study")
    local events = {}
    R:Update(100, events)
    H.assertEq(pom.phase, "break")
    H.assertNil(pom.long, "round 1: a short break")
    H.assertEq(R.Shown(pom, 100), 10)
    R:Update(110, events)
    R:Update(210, events)
    H.assertTrue(pom.long, "round 2: the long break")
    H.assertEq(R.Shown(pom, 210), 900)
    R:Update(1110, events)
    H.assertEq(pom.phase, "focus")
    H.assertNil(pom.long)
    -- A long logout steps whole sets: 100 + 10 + 100 + 900 = 1110 each.
    R:Update(1110 + 1110 * 3, events, true)
    H.assertEq(pom.intervals, 2 + 2 * 3)
    H.assertEq(pom.phase, "focus")
end

function tests.pomodoro_waitsWithoutAutoStart()
    local _, R = load()
    R.autoNext, R.longEvery = false, 0
    local pom = R:Start("pomodoro", 0, 100, 10)
    local events = {}
    R:Update(150, events)
    H.assertEq(pom.phase, "break", "the next phase is up")
    H.assertTrue(pom.waiting, "and waits")
    H.assertEq(R.Shown(pom, 150), 10, "its full length")
    R:Update(500, events)
    H.assertEq(#events, 1, "nothing more while waiting")
    H.assertEq(R.Shown(pom, 500), 10)
    R:TogglePause(pom, 500)
    H.assertNil(pom.waiting, "Start next")
    H.assertEq(R.Shown(pom, 505), 5)
end

function tests.pomodoro_roundsToday()
    local _, R = load()
    R.autoNext, R.longEvery = true, 0
    R:Start("pomodoro", at(9, 0), 1500, 300)
    R:Update(at(9, 25), {})
    R:Update(at(9, 30), {})
    R:Update(at(9, 55), {})
    H.assertEq(R:RoundsToday(at(10, 0)), 2)
    H.assertEq(R:RoundsToday(at(10, 0, 1)), 0, "a new day starts at zero")
end

-- Saved data

function tests.migration_toVersion3()
    local G, R, A = load()
    local sv = {
        version = 2,
        runs = {
            { tool = "alarm", startedAt = at(17, 0), at = at(19, 30), name = "raid" },
            { tool = "alarm", startedAt = at(16, 0), at = at(17, 0), done = true, doneAt = at(17, 0) },
            { tool = "stopwatch", startedAt = 100, laps = { 10, "x" } },
            { tool = "timer", startedAt = 100, duration = 60, name = 5 },
        },
    }
    R:Attach(sv, at(18, 0))
    A:Attach(sv)
    H.assertEq(sv.version, 3)
    H.assertEq(#sv.alarms, 1, "the waiting alarm is kept")
    local kept = sv.alarms[1]
    H.assertEq(kept.hour, 19)
    H.assertEq(kept.name, "raid")
    H.assertTrue(kept.enabled)
    H.assertEq(kept.next, at(19, 30))
    H.assertEq(#R:List(), 1, "the rung alarm stays a card; broken laps and names drop their run")
    H.assertEq(R:List()[1].hour, 17)
    H.assertNotNil(G)
end

local pass, fail, failures = H.runSuite("ClockModel", tests)
return { pass = pass, fail = fail, failures = failures }
