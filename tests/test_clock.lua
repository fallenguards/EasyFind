-- Clock: the search-bar grammar, the launcher's word rule, the run model
-- (several at once, phases, marks, resume) and the companion on stub frames.
local H = require("Harness")

local function grammar(db)
    local env = H.newEnv()
    env.time, env.date = os.time, os.date
    env.GameTime_GetFormattedTime = function(h, m) return string.format("%02d:%02d", h, m) end
    env.EasyFind.db = db or {}
    local ns = H.newNs(env)
    ns.SearchCommands = {}
    ns.CLOCK_NAME = "Clock"
    H.loadModule("Search/ClockCommands.lua", env, ns)
    return ns.ClockGrammar, ns, env
end

-- focus or duration seconds, break seconds; nil = not a clock command,
-- false = a command whose value is out of range.
local function resolve(G, text, now)
    local cmd = G.Parse(text)
    if not cmd then return nil end
    if not G.Resolve(cmd, now or os.time()) then return false end
    return cmd.seconds, cmd.seconds2, cmd
end

local function launcher()
    local env = H.newEnv()
    local ns = H.newNs(env)
    ns.CLOCK_NAME = "Clock"
    H.loadModule("Search/AppsMenu.lua", env, ns)
    return function(text) return ns.Results:GetClockLauncherMatch(text) end
end

local function runs()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    H.loadModule("Apps/Clock/Runs.lua", env, ns)
    local R = ns.ClockRuns
    R:Attach(nil, 1000)
    return R
end

local function at(hour, min, dayOffset)
    return os.time({ year = 2026, month = 10, day = 11 + (dayOffset or 0), hour = hour, min = min, sec = 0 })
end

local tests = {}

-- ==== grammar ===============================================================

function tests.pomodoro_bareUsesDefaults()
    local G = grammar({ clockFocusSeconds = 1500, clockBreakSeconds = 300 })
    for _, text in ipairs({ "pom", "pomo", "pomodoro", "  POM  " }) do
        local focus, brk, cmd = resolve(G, text)
        H.assertEq(cmd.tool, "pomodoro", text)
        H.assertEq(focus, 1500, text .. " focus")
        H.assertEq(brk, 300, text .. " break")
    end
    local focus, brk = resolve(grammar({ clockFocusSeconds = 3000, clockBreakSeconds = 600 }), "pom")
    H.assertEq(focus, 3000, "the setting's focus length")
    H.assertEq(brk, 600, "the setting's break length")
end

function tests.pomodoro_numbersAndUnits()
    local G = grammar({})
    local cases = {
        { "pom 15 5", 900, 300 },
        { "pom 15m 5m", 900, 300 },
        { "pom 50s 10s", 50, 10 },
        { "pom 25/5", 1500, 300 },
        { "pom 15 min 5 min", 900, 300 },
        { "pom 1h 10m", 3600, 600 },
        { "pom 15", 900, 300 },
    }
    for _, c in ipairs(cases) do
        local focus, brk = resolve(G, c[1])
        H.assertEq(focus, c[2], c[1] .. " focus")
        H.assertEq(brk, c[3], c[1] .. " break")
    end
end

function tests.pomodoro_slotUnitsFromSettings()
    local G = grammar({ clockFocusUnit = "s", clockBreakUnit = "m" })
    local focus, brk = resolve(G, "pom 15 5")
    H.assertEq(focus, 15, "focus slot in seconds")
    H.assertEq(brk, 300, "break slot in minutes")
    focus, brk = resolve(G, "pom 15m 5s")
    H.assertEq(focus, 900, "a unit letter wins over the slot's unit")
    H.assertEq(brk, 5)
    focus, brk = resolve(grammar({ clockFocusUnit = "s", clockBreakUnit = "s" }), "pom 1 1")
    H.assertEq(focus, 5, "a phase is never shorter than five seconds")
    H.assertEq(brk, 5)
end

function tests.timer_forms()
    local G = grammar({})
    local cases = {
        { "timer 10", 600 }, { "timer 50s", 50 }, { "time 20", 1200 },
        { "timer 1h30m", 5400 }, { "timer 1h30", 5400 }, { "timer 2m15", 135 },
        { "timer 1:30", 90 }, { "timer 1:02:03", 3723 }, { "timer 10 min", 600 },
        { "timer 1h 30m", 5400 }, { "timer 1.5h", 5400 }, { "timer 90 seconds", 90 },
        { "timer10", 600 },
    }
    for _, c in ipairs(cases) do
        local sec, _, cmd = resolve(G, c[1])
        H.assertEq(cmd and cmd.tool, "timer", c[1])
        H.assertEq(sec, c[2], c[1])
    end
end

function tests.timer_unitSetting()
    H.assertEq(resolve(grammar({ clockTimerUnit = "s" }), "timer 10"), 10, "seconds")
    H.assertEq(resolve(grammar({ clockTimerUnit = "h" }), "timer 2"), 7200, "hours")
    H.assertEq(resolve(grammar({ clockTimerUnit = "h" }), "timer 2m"), 120, "explicit unit")
    H.assertEq(resolve(grammar({ clockTimerUnit = "bogus" }), "timer 2"), 120, "bad setting reads as minutes")
end

function tests.stopwatch_forms()
    local G = grammar({})
    local sec, _, cmd = resolve(G, "stopwatch")
    H.assertEq(cmd.tool, "stopwatch")
    H.assertNil(sec, "bare stopwatch has no mark")
    H.assertEq(resolve(G, "stop 50"), 3000, "stop 50: minutes by default")
    H.assertEq(resolve(G, "stopwatch 10s"), 10)
    H.assertEq(resolve(G, "stop 10m"), 600)
    H.assertEq(resolve(grammar({ clockStopwatchUnit = "s" }), "stop 50"), 50, "stopwatch unit setting")
end

function tests.notCommands()
    local G = grammar({})
    local texts = {
        "timer", "time", "stop", "alarm", "stormwind", "timeless isle", "stop attack",
        "time 2 tickets", "timer 10 5", "timer abc", "pom 15 5 3", "pom pom", "stopwatches",
        "timer 1:75", "stop watch", "alarm clock", "alarm 25", "alarm 7:61", "alarm 13pm",
        "alarm 7xm", "pomegranate", "times 5", "", "   ",
    }
    for _, text in ipairs(texts) do
        H.assertNil(G.Parse(text), "not a clock command: '" .. text .. "'")
    end
    H.assertEq(resolve(G, "timer 0"), false, "zero is out of range")
    H.assertEq(resolve(G, "timer 200h"), false, "past the cap")
end

function tests.alarm_times()
    local G = grammar({})
    local now = at(18, 0)
    local cases = {
        { "alarm 7", 19, 0, 0 },
        { "alarm 7am", 7, 0, 1 },
        { "alarm 7 pm", 19, 0, 0 },
        { "alarm 7:30pm", 19, 30, 0 },
        { "alarm 19:30", 19, 30, 0 },
        { "alarm 17:00", 17, 0, 1 },
        { "alarm 12", 0, 0, 1 },
        { "alarm 12pm", 12, 0, 1 },
        { "alarm 12am", 0, 0, 1 },
        { "alarm 0:15", 0, 15, 1 },
    }
    for _, c in ipairs(cases) do
        local _, _, cmd = resolve(G, c[1], now)
        H.assertEq(cmd and cmd.tool, "alarm", c[1])
        H.assertEq(cmd.at, at(c[2], c[3], c[4]), c[1])
    end
end

function tests.formatDuration()
    local G = grammar({})
    H.assertEq(G.FormatDuration(0), "0:00")
    H.assertEq(G.FormatDuration(65), "1:05")
    H.assertEq(G.FormatDuration(3723), "1:02:03")
    H.assertEq(G.FormatDuration(-4), "0:00")
end

function tests.commandRow_startsWhatWasTyped()
    local _, ns = grammar({})
    local started
    ns.RequestClock = function() return true end
    ns.Clock = { StartFromCommand = function(cmd) started = cmd end }
    local entry = ns.SearchCommands:GetClockCommandEntry("pom 15 5")
    H.assertTrue(entry and entry.clockCommand, "a pomodoro row")
    H.assertEq(entry.clockTool, "pomodoro")
    H.assertEq(entry.name, "CLOCK_CMD_POMODORO")
    H.assertTrue(entry.noPin and entry.noLearn, "never pinned or learned")
    -- Typing on must not change what the shown row starts.
    H.assertNil(ns.SearchCommands:GetClockCommandEntry("stormwind"))
    ns.ClockGrammar.Parse("timer 3")
    entry.nativeRun()
    H.assertEq(started.tool, "pomodoro")
    H.assertEq(started.seconds, 900)
    H.assertEq(started.seconds2, 300)
end

function tests.commandRow_hiddenWhenCompanionDisabled()
    local _, ns = grammar({})
    ns.IsCompanionLoadable = function(name) return name ~= "EasyFind_Clock" end
    H.assertNil(ns.SearchCommands:GetClockCommandEntry("timer 10"))
end

function tests.launcherRow_wordRule()
    local match = launcher()
    for _, text in ipairs({ "clock", "cloc", "timer", "stopw", "stopwatch", "pomo", "pomodoro", "alarm", "alar", "countdown" }) do
        H.assertTrue(match(text) ~= nil, "opens the clock: " .. text)
    end
    for _, text in ipairs({ "sto", "stop", "stor", "stormwind", "tim", "time", "timeless isle", "ala", "pom", "clo", "al" }) do
        H.assertNil(match(text), "an ordinary search: " .. text)
    end
    H.assertTrue(match("clock").clockLauncher, "the launcher entry")
end

-- ==== runs ==================================================================

function tests.runs_severalAtOnce()
    local R = runs()
    H.assertTrue(R:Start("pomodoro", 1000, 1500, 300) ~= nil)
    H.assertTrue(R:Start("timer", 1000, 600) ~= nil)
    H.assertTrue(R:Start("timer", 1000, 300) ~= nil, "two timers side by side")
    H.assertTrue(R:Start("stopwatch", 1000) ~= nil)
    local alarm = R:Start("alarm", 1000, 5000)
    H.assertEq(#R:List(), 5)
    H.assertEq(R:Start("alarm", 1010, 5000), alarm, "the same alarm twice is one")
    R:Start("pomodoro", 1020, 600, 60)
    H.assertEq(#R:List(), 5, "a new pomodoro replaces the old")
    local pom
    for _, run in ipairs(R:List()) do if run.tool == "pomodoro" then pom = run end end
    H.assertEq(pom.focusLen, 600)
    for i = 1, R.MAX do R:Start("stopwatch", 1030) end
    H.assertEq(#R:List(), R.MAX, "the list stops at the cap")
    H.assertNil(R:Start("timer", 1040, 60), "a full list refuses")
    R:CancelAll()
    H.assertEq(#R:List(), 0)
end

function tests.runs_endedStaysUntilDismissed()
    local R = runs()
    local timer = R:Start("timer", 1000, 600)
    local events = {}
    H.assertFalse(R:Update(1599, events), "not yet")
    H.assertEq(#events, 0)
    H.assertEq(R.Shown(timer, 1599), 1)
    H.assertTrue(R:Update(1600, events))
    H.assertEq(#events, 1)
    H.assertEq(events[1].kind, "timer")
    H.assertNil(events[1].away)
    H.assertTrue(timer.done)
    R:Update(1600 + 86400, events)
    H.assertEq(#R:List(), 1, "an ended card stays")
    H.assertEq(#events, 1, "one signal only")
    R:Cancel(timer)
    H.assertEq(#R:List(), 0, "Dismiss takes it away")
end

function tests.runs_plusFiveAndAgain()
    local R = runs()
    local timer = R:Start("timer", 1000, 600)
    R:Update(1600, {})
    R:Extend(timer, 2000, 300)
    H.assertFalse(timer.done, "+5 min runs it again")
    H.assertEq(R.Shown(timer, 2000), 300)
    R:Update(2300, {})
    H.assertTrue(timer.done)
    R:Again(timer, 3000)
    H.assertFalse(timer.done)
    H.assertEq(R.Shown(timer, 3000), 600, "Again is the timer's own length, not the +5")
    H.assertNil(timer.base)
    local alarm = R:Start("alarm", 1000, 1200)
    R:Update(1200, {})
    H.assertTrue(alarm.done)
    R:Extend(alarm, 1500, 300)
    H.assertEq(alarm.at, 1800, "snoozed five minutes")
    R:Update(1800, {})
    R:Again(alarm, 2000, 87600)
    H.assertFalse(alarm.done)
    H.assertEq(alarm.at, 87600, "Again rings at the time given (tomorrow)")
    R:Extend(alarm, 2100, 300)
    H.assertEq(alarm.at, 87600, "+5 min only applies to an ended run")
end

function tests.runs_pomodoroPhases()
    local R = runs()
    local pom = R:Start("pomodoro", 1000, 1500, 300)
    local events = {}
    R:Update(2499, events)
    H.assertEq(#events, 0)
    H.assertEq(R.Shown(pom, 2499), 1, "focus time left")
    R:Update(2500, events)
    H.assertEq(events[1].kind, "break")
    H.assertEq(pom.phase, "break")
    H.assertEq(pom.intervals, 1)
    H.assertEq(R.Shown(pom, 2500), 300)
    R:Update(2800, events)
    H.assertEq(events[2].kind, "focus")
    H.assertEq(pom.phase, "focus")
    H.assertEq(pom.intervals, 1)
    H.assertFalse(pom.done, "a pomodoro runs until cancelled")
end

function tests.runs_pauseFreezesTime()
    local R = runs()
    local timer = R:Start("timer", 1000, 600)
    R:TogglePause(timer, 1100)
    H.assertEq(R.Shown(timer, 5000), 500, "paused: the time left holds")
    local events = {}
    R:Update(5000, events)
    H.assertEq(#events, 0, "a paused timer never ends")
    R:TogglePause(timer, 5000)
    H.assertEq(R.Shown(timer, 5000), 500, "resumed where it stopped")
    R:Update(5500, events)
    H.assertEq(#events, 1)
    local alarm = R:Start("alarm", 1000, 9000)
    R:TogglePause(alarm, 1100)
    H.assertNil(alarm.pausedAt, "an alarm is wall-clock and never pauses")
end

function tests.runs_stopwatchMarkPingsAndKeepsCounting()
    local R = runs()
    local sw = R:Start("stopwatch", 1000, 600)
    local events = {}
    R:Update(1599, events)
    H.assertEq(#events, 0)
    R:Update(1600, events)
    H.assertEq(#events, 1)
    H.assertEq(events[1].kind, "mark")
    H.assertTrue(sw.markHit)
    H.assertFalse(sw.done, "the stopwatch keeps running")
    R:Update(1900, events)
    H.assertEq(#events, 1, "the mark pings once")
    H.assertEq(R.Shown(sw, 1900), 900, "still counting past the mark")
    H.assertEq(#R:List(), 1)
end

function tests.runs_skipAndRestart()
    local R = runs()
    local pom = R:Start("pomodoro", 1000, 1500, 300)
    H.assertEq(R:SkipPhase(pom, 1200), "break")
    H.assertEq(pom.intervals, 1)
    H.assertEq(R.Shown(pom, 1200), 300)
    H.assertEq(R:SkipPhase(pom, 1300), "focus")
    R:Restart(pom, 2000)
    H.assertEq(pom.phase, "focus")
    H.assertEq(pom.intervals, 0)
    H.assertEq(R.Shown(pom, 2000), 1500)
    local timer = R:Start("timer", 1000, 60)
    R:Update(1060, {})
    H.assertTrue(timer.done)
    R:Restart(timer, 3000)
    H.assertFalse(timer.done, "a finished timer starts over")
    H.assertEq(R.Shown(timer, 3000), 60)
end

-- A reload or a logout: the saved table comes back and the clock has moved on.
function tests.persistence_resumeAfterGap()
    local R = runs()
    local sv = {
        version = 2,
        runs = {
            { tool = "timer", startedAt = 1000, duration = 600 },
            { tool = "timer", startedAt = 1000, duration = 999999 },
            { tool = "alarm", startedAt = 1000, at = 4000 },
            { tool = "stopwatch", startedAt = 1000, mark = 60 },
            { tool = "pomodoro", startedAt = 1000, focusLen = 1500, breakLen = 300,
              phase = "focus", phaseStartedAt = 1000, intervals = 0 },
            { tool = "timer", startedAt = 1000, duration = 600, pausedAt = 1100 },
        },
    }
    local now = 1000 + 10 * 86400 + 100
    R:Attach(sv, now)
    local events = {}
    R:Update(now, events, true)
    local kinds = {}
    for _, e in ipairs(events) do
        H.assertTrue(e.away, "told as away")
        kinds[#kinds + 1] = e.kind
    end
    table.sort(kinds)
    H.assertEq(table.concat(kinds, ","), "alarm,mark,timer", "what ended while away, and no pomodoro phases")
    local list = R:List()
    H.assertEq(#list, 6, "everything survives the gap")
    H.assertTrue(list[1].done, "the short timer ran out while away")
    H.assertFalse(list[2].done, "the long one is still going")
    H.assertEq(R.Shown(list[2], now), 999999 - (now - 1000))
    local pom = list[5]
    local elapsed = now - 1000
    local cycles = math.floor(elapsed / 1800)
    H.assertEq(pom.intervals, cycles + ((elapsed % 1800) >= 1500 and 1 or 0), "a focus counted per cycle")
    H.assertEq(R.Shown(pom, now), (elapsed % 1800) < 1500 and 1500 - elapsed % 1800 or 1800 - elapsed % 1800)
    H.assertFalse(list[6].done, "a paused timer stays paused")
    H.assertEq(R.Shown(list[6], now), 500)
end

function tests.persistence_migrationAndCleanup()
    local R = runs()
    local sv = {
        version = 1,
        runs = {
            { tool = "stopwatch", startedAt = 100, target = 60, targetHit = true },
            { tool = "nonsense", startedAt = 100 },
            { tool = "timer", startedAt = "x", duration = 5 },
            { tool = "timer", startedAt = 100, duration = -5 },
            "junk",
            { tool = "timer", startedAt = 900, duration = 60 },
        },
        hud = { left = 10, top = 20 },
    }
    R:Attach(sv, 500)
    local list = R:List()
    H.assertEq(#list, 2, "broken runs are dropped")
    H.assertEq(list[1].mark, 60, "target is now mark")
    H.assertTrue(list[1].markHit)
    H.assertNil(list[1].target)
    H.assertEq(list[2].startedAt, 500, "a start in the future (clock moved back) restarts now")
    H.assertEq(sv.version, 2)
    H.assertEq(sv.hud.left, 10, "the window place survives")
    H.assertEq(sv.minimapAngle, 245)
    local fresh = R:Attach(nil, 500)
    H.assertEq(#fresh.runs, 0)
    H.assertEq(fresh.version, 2)
end

-- ==== the companion, end to end on stub frames ==============================

-- A frame that takes any call: enough to run every path of Clock.lua.
local frames = {}
local function stubFrame()
    local f = { shown = true, scripts = {}, events = {}, text = nil }
    local methods = {
        Show = function(self) self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end,
        Hide = function(self) self.shown = false; if self.scripts.OnHide then self.scripts.OnHide(self) end end,
        SetShown = function(self, v) if v then self:Show() else self:Hide() end end,
        IsShown = function(self) return self.shown end,
        SetScript = function(self, name, fn) self.scripts[name] = fn end,
        GetScript = function(self, name) return self.scripts[name] end,
        HookScript = function(self, name, fn)
            local prev = self.scripts[name]
            self.scripts[name] = function(...) if prev then prev(...) end fn(...) end
        end,
        RegisterEvent = function(self, e) self.events[e] = true end,
        UnregisterEvent = function(self, e) self.events[e] = nil end,
        CreateTexture = function() return stubFrame() end,
        CreateFontString = function() return stubFrame() end,
        CreateAnimationGroup = function() return stubFrame() end,
        CreateAnimation = function() return stubFrame() end,
        SetText = function(self, t) self.text = t end,
        GetText = function(self) return self.text end,
        GetFont = function() return "Fonts\\FRIZQT__.TTF", 12, "" end,
        GetLeft = function() return 100 end, GetTop = function() return 500 end,
        GetCenter = function() return 0, 0 end, GetEffectiveScale = function() return 1 end,
        GetWidth = function() return 100 end, GetHeight = function() return 100 end,
        GetFrameLevel = function() return 1 end,
        GetStringWidth = function() return 30 end, GetStringHeight = function() return 12 end,
        IsVisible = function(self) return self.shown end,
    }
    frames[#frames + 1] = f
    -- Methods are CamelCase; anything else is a field the code set or nil.
    return setmetatable(f, { __index = function(_, k)
        if methods[k] then return methods[k] end
        if type(k) == "string" and k:find("^%u") then return function() end end
        return nil
    end })
end

local function companion(saved, startAt)
    for i = #frames, 1, -1 do frames[i] = nil end
    local env = H.newEnv()
    local now = startAt or at(18, 0)
    env.time = function(t) if t then return os.time(t) end return now end
    env.date = os.date
    env.CreateFrame = function() return stubFrame() end
    env.UIParent, env.Minimap = stubFrame(), stubFrame()
    env.GetCursorPosition = function() return 0, 0 end
    local log = { chat = {}, sound = 0, flash = 0, menus = {}, combat = false }
    env.InCombatLockdown = function() return log.combat end
    env.UnitAffectingCombat = function() return log.combat end
    env.GameTime_GetFormattedTime = function(h, m) return string.format("%02d:%02d", h, m) end
    env.SOUNDKIT = { ALARM_CLOCK_WARNING_3 = 12889 }
    env.PlaySound = function() log.sound = log.sound + 1 end
    env.FlashClientIcon = function() log.flash = log.flash + 1 end
    env.EasyFind.Print = function(_, msg) log.chat[#log.chat + 1] = msg end
    env.EasyFind.db = {
        clockSound = true, clockBigText = true, clockChat = true, clockFlash = true, clockBreakDim = true,
        clockFocusSeconds = 1500, clockBreakSeconds = 300,
    }
    env.EasyClockDB = saved
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    ns.SearchCommands = {}
    ns.CLOCK_NAME = "Clock"
    ns.CLOCK_ICON_TEX = "clock"
    ns.CLOCK_TOOL_ICONS = { pomodoro = "p", timer = "t", stopwatch = "s", alarm = "a" }
    ns.TEXT_DIM, ns.TEXT_PRIMARY, ns.TEXT_BODY = { 0.5, 0.5, 0.5 }, { 1, 1, 1 }, { 0.8, 0.8, 0.8 }
    ns.ACTIVE_UI_PALETTE = { windowFill = { 0.05, 0.05, 0.06 } }
    ns.ThemeSwatchColor = function(p) return p.windowFill[1], p.windowFill[2], p.windowFill[3] end
    for _, name in ipairs({ "CreateRoundedRectBorder", "SetRoundedRectBarHeight", "SetRoundedRectBorderEdgeShown",
                            "SetRoundedRectFill", "SetRoundedRectBorderColor" }) do
        ns[name] = function() end
    end
    ns.StyleMenuPanel = function() end
    ns.CreateCloseX = function() return stubFrame() end
    ns.CreateCogButton = function() return stubFrame() end
    ns.ChromeGlyphColor = function() return { 1, 0.8, 0 } end
    ns.TooltipTextColor = function() return 1, 1, 1 end
    ns.MinimapEdgeOffset = function() return 0, 80 end
    ns.ShowHintTooltip, ns.HideHintTooltip = function() end, function() end
    ns.RegisterThemeCallback = function(fn) log.themeFn = fn end
    ns.Utils.InstallMenuRowHighlight = function() end
    ns.Utils.RefreshMenuRowHighlights = function() end
    ns.Utils.AttachDelayedTooltip = function() end
    ns.Utils.AttachEscClose = function() end
    ns.Utils.ShowCursorMenu = function(_, rows, opts)
        log.menus[#log.menus + 1] = rows
        local menu = stubFrame()
        menu.toggleOwner = opts and opts.toggleOwner
        return menu
    end
    H.loadModule("Search/ClockCommands.lua", env, ns)
    -- The companion's files share one private table, as the client gives them.
    local CL = {}
    for _, f in ipairs(H.TocFiles("Apps/Clock/EasyFind_Clock.toc")) do
        assert(loadfile(H.ADDON_ROOT .. "/" .. f, "t", env))("EasyFind_Clock", CL)
    end
    ns.RequestClock = function() return ns.Clock ~= nil end
    H.assertTrue(ns.Clock ~= nil, "the companion loads")
    -- The client fires ADDON_LOADED once the saved variables are in.
    for i = #frames, 1, -1 do
        local f = frames[i]
        if f.events.ADDON_LOADED and f.scripts.OnEvent then
            f.scripts.OnEvent(f, "ADDON_LOADED", "EasyFind_Clock")
            break
        end
    end
    local function advance(seconds)
        now = now + seconds
        for i = 1, #frames do
            local f = frames[i]
            if f.scripts.OnUpdate then f.scripts.OnUpdate(f, 1) end
        end
        env._clock:advance(seconds)
    end
    return ns, env, log, advance, CL
end

function tests.companion_typedCommandsRunTogether()
    local ns, env, log, advance, CL = companion(nil)
    ns.Clock.StartFromCommand(ns.ClockGrammar.Parse("pom 15 5"))
    ns.Clock.StartFromCommand(ns.ClockGrammar.Parse("timer 10s"))
    ns.Clock.StartFromCommand(ns.ClockGrammar.Parse("stop 5s"))
    ns.Clock.StartFromCommand(ns.ClockGrammar.Parse("alarm 18:01"))
    H.assertEq(#env.EasyClockDB.runs, 4, "four runs at once")
    H.assertTrue(ns.Clock.IsOpen(), "starting a run shows the window")
    H.assertTrue(env.EasyFind.db.clockActive, "login will load the clock")
    advance(5)
    H.assertEq(#log.chat, 1, "the stopwatch mark")
    advance(5)
    H.assertEq(#log.chat, 2, "the timer")
    H.assertTrue(log.chat[2]:find("CLOCK_DONE_FMT", 1, true) ~= nil)
    H.assertEq(log.sound, 2, "a chime each")
    H.assertEq(log.flash, 2, "a taskbar flash each")
    advance(50)
    H.assertEq(#log.chat, 3, "the alarm at 18:01")
    local before = #env.EasyClockDB.runs
    ns.Clock.Minimize()
    H.assertFalse(ns.Clock.IsOpen(), "minimize closes the window")
    H.assertTrue(CL.Strip.IsShown(), "and the strip takes over")
    H.assertEq(#env.EasyClockDB.runs, before, "minimizing cancels nothing")
    advance(900 - 60)
    H.assertTrue(log.chat[#log.chat]:find("CLOCK_BREAK_START", 1, true) ~= nil, "the pomodoro's break")
    advance(3600)
    H.assertEq(#env.EasyClockDB.runs, 4, "ended cards stay until dismissed")
    log.themeFn()
end

function tests.companion_signalsFollowSettings()
    local ns, env, log, advance = companion(nil)
    env.EasyFind.db.clockSound = false
    env.EasyFind.db.clockChat = false
    env.EasyFind.db.clockFlash = false
    ns.Clock.StartFromCommand(ns.ClockGrammar.Parse("timer 3s"))
    advance(3)
    H.assertEq(#log.chat, 0, "no chat line")
    H.assertEq(log.sound, 0, "no sound")
    H.assertEq(log.flash, 0, "no flash")
    H.assertTrue(env.EasyClockDB.runs[1].done, "it still ended")
end

function tests.companion_resumesSavedRunsAtLogin()
    local start = at(18, 0)
    local saved = {
        version = 2,
        runs = {
            { tool = "timer", startedAt = start - 3600, duration = 600 },
            { tool = "timer", startedAt = start - 60, duration = 600 },
        },
        hud = { shown = true },
    }
    local ns, env, log, advance = companion(saved, start)
    H.assertTrue(ns.Clock.IsOpen(), "the window comes back with its runs")
    H.assertTrue(env.EasyClockDB.runs[1].done, "ran out while away")
    H.assertEq(#log.chat, 0, "the away report waits for the world")
    advance(3)
    H.assertEq(#log.chat, 1)
    H.assertTrue(log.chat[1]:find("CLOCK_AWAY_FMT", 1, true) ~= nil, "told as away")
    H.assertEq(log.sound, 0, "an away report makes no sound")
    advance(540)
    H.assertEq(#log.chat, 2, "the other timer ends on time")
end

function tests.companion_breakDim()
    local ns, env, _, advance = companion(nil)
    ns.Clock.StartFromCommand(ns.ClockGrammar.Parse("pom 10s 20s"))
    advance(10)
    local dim
    for i = 1, #frames do
        if frames[i].events.PLAYER_REGEN_DISABLED then dim = frames[i] end
    end
    H.assertTrue(dim and dim.shown, "the break dims the screen")
    dim.scripts.OnClick(dim)
    H.assertFalse(dim.shown, "a click lifts the dim")
    advance(1)
    H.assertFalse(dim.shown, "and it stays lifted for this break")
    H.assertEq(env.EasyClockDB.runs[1].phase, "break", "the pomodoro goes on")
    advance(19)
    advance(10)
    H.assertTrue(dim.shown, "the next break dims again")
    dim.scripts.OnEvent(dim, "PLAYER_REGEN_DISABLED")
    H.assertFalse(dim.shown, "a pull takes it down")
end

function tests.companion_breakDimNeverInCombat()
    local ns, _, log, advance = companion(nil)
    log.combat = true
    ns.Clock.StartFromCommand(ns.ClockGrammar.Parse("pom 10s 20s"))
    advance(10)
    for i = 1, #frames do
        H.assertFalse(frames[i].events.PLAYER_REGEN_DISABLED, "no dim in combat")
    end
    log.combat = false
    advance(1)
    local shown = false
    for i = 1, #frames do
        if frames[i].events.PLAYER_REGEN_DISABLED then shown = frames[i].shown end
    end
    H.assertTrue(shown, "the dim comes once the fight is over")
end

-- A chip or button found by the word on it.
local function Labeled(word)
    for i = 1, #frames do
        local f = frames[i]
        if f.scripts.OnClick and type(f.text) == "table" and f.text.text == word then return f end
    end
end

local function MinimapIcon()
    for i = 1, #frames do
        local f = frames[i]
        if f.scripts.OnClick and f.scripts.OnDragStart and f.scripts.OnEnter and f.icon then return f end
    end
end

function tests.companion_tilesStartRuns()
    local ns, env = companion(nil)
    ns.Clock.Open()
    H.assertTrue(ns.Clock.IsOpen(), "the launcher opens the window on its tiles")
    Labeled("5").scripts.OnClick(Labeled("5"))
    H.assertEq(env.EasyClockDB.runs[1].duration, 300, "the 5 chip starts a five minute timer")
    Labeled("50 / 10").scripts.OnClick(Labeled("50 / 10"))
    local pom = env.EasyClockDB.runs[2]
    H.assertEq(pom.focusLen, 3000)
    H.assertEq(pom.breakLen, 600)
    local start = Labeled("START") or Labeled("Start")
    start.scripts.OnClick(start)
    H.assertEq(env.EasyClockDB.runs[3].tool, "stopwatch")
end

function tests.companion_endedCardChoices()
    local ns, env, log, advance, CL = companion(nil)
    ns.Clock.StartFromCommand(ns.ClockGrammar.Parse("timer 3s"))
    advance(3)
    local run = env.EasyClockDB.runs[1]
    H.assertTrue(run.done)
    CL.ShowRunMenu(run, {})
    local rows = log.menus[#log.menus]
    H.assertEq(#rows, 3, "+5 min, Again, Dismiss")
    rows[1].onClick()
    H.assertFalse(run.done, "+5 min")
    H.assertEq(run.duration, 300)
    advance(300)
    H.assertTrue(run.done)
    CL.ShowRunMenu(run, {})
    log.menus[#log.menus][2].onClick()
    H.assertEq(run.duration, 3, "Again: its own length")
    advance(3)
    CL.ShowRunMenu(run, {})
    log.menus[#log.menus][3].onClick()
    H.assertEq(#env.EasyClockDB.runs, 0, "Dismiss")
    H.assertTrue(ns.Clock.IsOpen(), "the window stays, on its tiles")
    H.assertFalse(CL.Strip.IsShown())
end

function tests.companion_stripWhileMinimized()
    local ns, env, _, advance, CL = companion(nil)
    ns.Clock.StartFromCommand(ns.ClockGrammar.Parse("timer 10"))
    ns.Clock.Minimize()
    H.assertTrue(CL.Strip.IsShown(), "minimized: the strip")
    ns.Clock.StartFromCommand(ns.ClockGrammar.Parse("stopwatch"))
    H.assertFalse(ns.Clock.IsOpen(), "a new run while minimized joins the strip")
    advance(1)
    CL.OpenWindow()
    H.assertTrue(ns.Clock.IsOpen())
    H.assertFalse(CL.Strip.IsShown(), "the open window hides the strip")
    ns.Clock.Minimize()
    env.EasyClockDB.runs[2] = nil
    env.EasyClockDB.runs[1] = nil
    CL.Changed()
    H.assertFalse(CL.Strip.IsShown(), "nothing running, no strip")
    H.assertNil(MinimapIcon(), "the minimap icon is off by default")
end

function tests.companion_menusAndOpen()
    local ns, env, log = companion(nil)
    env.EasyFind.db.clockMinimapIcon = true
    ns.Clock.Open()
    H.assertTrue(ns.Clock.IsOpen(), "the launcher opens an empty window")
    ns.Clock.StartFromCommand(ns.ClockGrammar.Parse("timer 5"))
    ns.Clock.StartFromCommand(ns.ClockGrammar.Parse("stopwatch"))
    -- The minimap icon's right-click: one cancel row per run, then cancel all.
    local mm = MinimapIcon()
    H.assertTrue(mm ~= nil, "a minimap icon, with the setting on")
    mm.scripts.OnClick(mm, "RightButton")
    local rows = log.menus[#log.menus]
    H.assertEq(#rows, 4, "two cancels, a separator, cancel all")
    rows[4].onClick()
    H.assertEq(#env.EasyClockDB.runs, 0, "cancel all")
    H.assertFalse(env.EasyFind.db.clockActive)
end

local pass, fail, failures = H.runSuite("Clock", tests)
return { pass = pass, fail = fail, failures = failures }
