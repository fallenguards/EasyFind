local addonName, CL = ...
local ns = EasyFind and EasyFind._ns
if not (ns and ns.ClockRuns and ns.ClockAlarms and CL.Window and CL.Strip and CL.UpdateMinimapButton) then return end

local Utils = ns.Utils
local L = ns.L
local Runs, Alarms, Signals = ns.ClockRuns, ns.ClockAlarms, ns.Signals
local Grammar = ns.ClockGrammar
local Format = Grammar.FormatDuration
local Window, Strip = CL.Window, CL.Strip

local CreateFrame, UIParent = CreateFrame, UIParent
local InCombatLockdown, UnitAffectingCombat = InCombatLockdown, UnitAffectingCombat
local time, type, wipe, tonumber, tostring = time, type, wipe, tonumber, tostring
local sformat = Utils.sformat

local TICK_SECONDS, ALARMS_TICK_SECONDS = 0.2, 1
local RING_EVERY = 5
local SNOOZE_DEFAULT = 9

local SOUND_SETTING = {
    timer = "clockSoundTimer", alarm = "clockSoundAlarm", mark = "clockSoundMark",
    focus = "clockSoundPomodoro", ["break"] = "clockSoundPomodoro",
}

-- Frames and state in one table (upvalue budget).
local UI = { events = {}, away = {}, due = {}, spec = {} }
local Clock = {}
local UpdateDim

-- The end of a run

local function PomodoroText(run)
    local len = Format(Runs.PhaseLen(run))
    if run.phase == "focus" then
        return sformat(run.waiting and L["CLOCK_FOCUS_READY"] or L["CLOCK_FOCUS_START"], len)
    end
    if run.long then
        return sformat(run.waiting and L["CLOCK_LONG_BREAK_READY"] or L["CLOCK_LONG_BREAK_START"], len)
    end
    return sformat(run.waiting and L["CLOCK_BREAK_READY"] or L["CLOCK_BREAK_START"], len)
end

local function EventText(event)
    local run, kind = event.run, event.kind
    local text
    if kind == "timer" then
        text = sformat(L["CLOCK_DONE_FMT"], CL.RunLabel(run))
    elseif kind == "alarm" then
        text = CL.RunLabel(run)
    elseif kind == "mark" then
        text = sformat(L["CLOCK_MARK_REACHED"], Format(run.mark))
        if run.name then text = sformat(L["CLOCK_CMD_NAMED"], run.name, text) end
    else
        text = PomodoroText(run)
        if run.name then text = sformat(L["CLOCK_CMD_NAMED"], run.name, text) end
    end
    if event.away then text = sformat(L["CLOCK_AWAY_FMT"], text) end
    return text
end

-- What every end does, from the settings; one table reused (no allocation).
local function SpecFor(kind)
    local db, spec = EasyFind.db, UI.spec
    spec.chat, spec.big, spec.taskbar = db.clockChat ~= false, db.clockBigText ~= false, db.clockFlash ~= false
    spec.sound = db.clockSound ~= false and db[SOUND_SETTING[kind]] or nil
    spec.screen = db.clockScreen or nil
    return spec
end

-- A run that ended while the player was away is told in text only, once
-- the loading screen is gone.
local function Signal(event)
    if event.kind == "break" then UI.dimDismissed = nil end
    Signals.Fire(SpecFor(event.kind), EventText(event), event.away)
    if event.away then return end
    if event.kind == "alarm" then
        event.run.ringing = true
        UI.nextRing = time() + RING_EVERY
    end
    Window.Pulse(event.run)
end

local function Ringing()
    local runs = Runs:List()
    for i = 1, #runs do
        if runs[i].done and runs[i].ringing then return true end
    end
    return false
end

-- An alarm left ringing chimes again until it is dismissed (a setting).
local function RingAgain(now)
    local db = EasyFind.db
    if not db.clockAlarmRepeat or db.clockSound == false or now < (UI.nextRing or 0) then return end
    if not Ringing() then return end
    UI.nextRing = now + RING_EVERY
    Signals.PlaySound(db.clockSoundAlarm)
end

-- Kept alarms whose time has come ring as ended alarm cards.
local function RingDue(now, events, away)
    local due = UI.due
    wipe(due)
    Alarms:Due(now, due)
    for i = 1, #due do
        events[#events + 1] = { run = Runs:Ring(due[i], now), kind = "alarm", away = away or nil }
        Alarms:Rang(due[i], now)
    end
    return #due > 0
end

-- Ticking

local driver = CreateFrame("Frame")

local function Tick()
    local now = time()
    local events = UI.events
    wipe(events)
    local changed = Runs:Update(now, events)
    if RingDue(now, events) then changed = true end
    for i = 1, #events do Signal(events[i]) end
    RingAgain(now)
    if changed then
        CL.Changed()
    else
        Window.UpdateTimes(now)
        Strip.UpdateTimes(now)
        UpdateDim(now)
    end
end

local function OnDriverUpdate(_, elapsed)
    UI.tickWait = (UI.tickWait or 0) - elapsed
    if UI.tickWait > 0 then return end
    UI.tickWait = UI.tickEvery
    Tick()
end

-- Fast while something counts, once a second for alarms waiting or one
-- left ringing, off when nothing is set.
local function TickEvery()
    local runs = Runs:List()
    for i = 1, #runs do
        if not runs[i].done then return TICK_SECONDS end
    end
    if Alarms:AnyOn() or (EasyFind.db.clockAlarmRepeat and Ringing()) then return ALARMS_TICK_SECONDS end
    return nil
end

local function UpdateTicker()
    local every = TickEvery()
    if every == UI.tickEvery then return end
    UI.tickEvery = every
    UI.tickWait = 0
    Utils.SafeOnUpdate(driver, every and OnDriverUpdate or nil)
end

-- The break dim

local function DismissDim()
    UI.dimDismissed = true
    if UI.dim then UI.dim:Hide() end
end

-- Light text on every theme: the dim is always black.
local function PaintDim(dim)
    local c = CL.BREAK_COLOR
    dim.title:SetTextColor(c[1], c[2], c[3], 1)
    dim.time:SetTextColor(Utils.RGB(ns.TEXT_PRIMARY, 1))
    dim.hint:SetTextColor(Utils.RGB(ns.TEXT_BODY, 1))
end

local function EnsureDim()
    if UI.dim then return UI.dim end
    local dim = CreateFrame("Button", "EasyFindClockBreakDim", UIParent)
    dim:Hide()
    dim:SetAllPoints(UIParent)
    dim:SetFrameStrata("FULLSCREEN")
    dim:RegisterForClicks("AnyUp")
    dim:SetScript("OnClick", DismissDim)
    local shade = dim:CreateTexture(nil, "BACKGROUND")
    shade:SetAllPoints()
    shade:SetColorTexture(0, 0, 0, 0.55)
    dim.title = dim:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    dim.title:SetPoint("BOTTOM", dim, "CENTER", 0, 40)
    dim.title:SetText(L["CLOCK_BREAK"])
    dim.time = CL.DigitsText(dim, 56)
    dim.time:SetPoint("TOP", dim.title, "BOTTOM", 0, -10)
    dim.hint = dim:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    dim.hint:SetPoint("TOP", dim.time, "BOTTOM", 0, -16)
    dim.hint:SetText(L["CLOCK_DIM_HINT"])
    -- Never over a fight: a pull takes the dim down at once.
    dim:SetScript("OnShow", function(self) self:RegisterEvent("PLAYER_REGEN_DISABLED") end)
    dim:SetScript("OnHide", function(self) self:UnregisterEvent("PLAYER_REGEN_DISABLED") end)
    dim:SetScript("OnEvent", function(self) self:Hide() end)
    Utils.AttachEscClose(dim, DismissDim)
    UI.dim = dim
    CL.Painted(dim, PaintDim)
    return dim
end

function UpdateDim(now)
    local left
    if EasyFind.db.clockBreakDim and not UI.dimDismissed
       and not InCombatLockdown() and not UnitAffectingCombat("player") then
        local runs = Runs:List()
        for i = 1, #runs do
            local run = runs[i]
            if run.tool == "pomodoro" and run.phase == "break" and not run.pausedAt then
                left = Runs.PhaseLeft(run, now)
            end
        end
    end
    if left and left > 0 then
        local dim = EnsureDim()
        if dim.shownLeft ~= left then
            dim.shownLeft = left
            dim.time:SetText(Format(left))
        end
        if not dim:IsShown() then dim:Show() end
    elseif UI.dim and UI.dim:IsShown() then
        UI.dim:Hide()
    end
end

-- Actions the window, the strip and the menus share

function CL.Skip(run)
    if Runs:SkipPhase(run, time()) == "break" then UI.dimDismissed = nil end
    CL.Changed()
end

-- An ended timer runs its own length again.
function CL.Again(run)
    Runs:Again(run, time())
    CL.Changed()
end

function CL.SnoozeMinutes()
    local minutes = tonumber(EasyFind.db.clockSnoozeMinutes)
    return minutes and minutes > 0 and minutes or SNOOZE_DEFAULT
end

-- A ringing alarm goes quiet and rings again after the snooze.
function CL.Snooze(run)
    run.ringing = nil
    Runs:Extend(run, time(), CL.SnoozeMinutes() * 60)
    CL.Changed()
end

-- The cog toggles: a second press closes the panel open on the clock page.
function CL.OpenSettings()
    local frame = ns.optionsFrame
    if frame and frame:IsShown() and ns.Options.CurrentExtensionPage and ns.Options:CurrentExtensionPage() == "clock" then
        ns.Options:Hide()
        return
    end
    if ns.RequestOptionsPanel() and ns.Options.OpenAtExtension then
        ns.Options:OpenAtExtension("clock")
    end
end

function CL.OpenWindow()
    if not UI.ready then
        UI.openQueued = true
        return
    end
    Runs.sv.hud.shown = true
    Window.Show()
    Strip.Refresh()
end

-- The window closes to the strip; nothing is cancelled.
function CL.Minimize()
    Window.Hide()
    if Runs.sv then Runs.sv.hud.shown = false end
    Strip.Refresh()
end

-- State changes

function CL.Changed()
    local active = #Runs:List() > 0 or Alarms:AnyOn()
    EasyFind.db.clockActive = active
    UpdateTicker()
    CL.UpdateMinimapButton(active)
    Window.Refresh()
    Strip.Refresh()
    UpdateDim(time())
end

-- Something new opens the window, unless the player minimized it while
-- runs were going: then it joins the strip. True when the window shows.
local function Reveal(hadRuns)
    if hadRuns and Runs.sv.hud.shown == false then return false end
    Runs.sv.hud.shown = true
    Window.Show()
    return true
end

function CL.StartRun(tool, a, b, name)
    if not UI.ready then
        UI.queued = { tool, a, b, name }
        return
    end
    local hadRuns = #Runs:List() > 0
    local run = Runs:Start(tool, time(), a, b, name)
    if not run then
        EasyFind:Print(sformat(L["CLOCK_FULL"], Runs.MAX))
        return
    end
    if tool == "pomodoro" then UI.dimDismissed = nil end
    Reveal(hadRuns)
    CL.Changed()
end

-- Kept alarms

-- A resolved alarm command (the search bar, the alarm tile).
function CL.AddAlarm(cmd)
    if not UI.ready then
        UI.queuedAlarm = cmd
        return
    end
    local now = time()
    local alarm = Alarms:Add(now, cmd.hour, cmd.min, cmd.days, cmd.name, cmd.server)
    if not alarm then
        EasyFind:Print(sformat(L["CLOCK_ALARMS_FULL"], Alarms.MAX))
        return
    end
    if not Reveal(#Runs:List() > 0) then
        local label = Grammar.ClockLabel(alarm.hour, alarm.min, alarm.server)
        EasyFind:Print(sformat(L["CLOCK_ALARM_SET"], sformat(L["CLOCK_ALARM_DESC"], label, Format(alarm.next - now))))
    end
    CL.Changed()
end

-- A saved edit switches the alarm on, as a phone's clock does.
function CL.EditAlarm(alarm, hour, minute, days, name, server)
    local now = time()
    Alarms:Edit(alarm, now, hour, minute, days, name, server)
    Alarms:SetEnabled(alarm, true, now)
    CL.Changed()
end

function CL.DeleteAlarm(alarm)
    Alarms:Delete(alarm)
    CL.Changed()
end

function CL.SetAlarmOn(alarm, on)
    Alarms:SetEnabled(alarm, on, time())
    CL.Changed()
end

-- Timer presets

function CL.SavePreset(seconds)
    if type(seconds) ~= "number" then return end
    if #Runs:Presets() >= Runs.PRESETS_MAX then
        EasyFind:Print(sformat(L["CLOCK_PRESETS_FULL"], Runs.PRESETS_MAX))
        return
    end
    Runs:AddPreset(seconds)
    CL.Changed()
end

function CL.RemovePreset(seconds)
    Runs:RemovePreset(seconds)
    CL.Changed()
end

if ns.RegisterThemeCallback then ns.RegisterThemeCallback(CL.RepaintAll) end

-- Settings the model reads; a running pomodoro takes new long breaks too.
local function ApplySettings()
    local db = EasyFind.db
    Runs.autoNext = db.clockAutoNext ~= false
    Runs.longEvery = tonumber(db.clockLongEvery) or 4
    Runs.longLen = tonumber(db.clockLongSeconds) or 900
    local runs = Runs:List()
    for i = 1, #runs do
        local run = runs[i]
        if run.tool == "pomodoro" then run.longEvery, run.longLen = Runs.longEvery, Runs.longLen end
    end
end

-- What the core and the options panel call

-- A parsed search-bar command (Search/ClockCommands.lua).
function Clock.StartFromCommand(cmd)
    if type(cmd) ~= "table" or not Grammar.Resolve(cmd, time()) then return end
    local tool = cmd.tool
    if tool == "alarm" then
        CL.AddAlarm(cmd)
    elseif tool == "pomodoro" then
        CL.StartRun("pomodoro", cmd.seconds, cmd.seconds2, cmd.name)
    else
        CL.StartRun(tool, cmd.seconds, nil, cmd.name)
    end
end

function Clock.Open()
    CL.OpenWindow()
end

function Clock.Minimize()
    if UI.ready then CL.Minimize() end
end

function Clock.IsOpen()
    return Window.IsShown()
end

-- A setting changed (sounds, long breaks, the dim, the minimap icon).
function Clock.SettingsChanged()
    if not UI.ready then return end
    ApplySettings()
    CL.Changed()
end

-- Saved runs arrive with ADDON_LOADED: runs that ended and alarms that
-- rang while the player was away say so once the world is up.
local function Init()
    local now = time()
    EasyClockDB = Runs:Attach(EasyClockDB, now)
    Alarms:Attach(Runs.sv)
    ApplySettings()
    local away = UI.away
    Runs:Update(now, away, true)
    RingDue(now, away, true)
    Alarms:ArmAll(now)
    UI.ready = true
    UI.nextRing = now + RING_EVERY
    if #Runs:List() > 0 and Runs.sv.hud.shown ~= false then Window.Show() end
    CL.Changed()
    local queued, queuedAlarm = UI.queued, UI.queuedAlarm
    UI.queued, UI.queuedAlarm = nil, nil
    if queued then CL.StartRun(queued[1], queued[2], queued[3], queued[4]) end
    if queuedAlarm then CL.AddAlarm(queuedAlarm) end
    if UI.openQueued then
        UI.openQueued = nil
        CL.OpenWindow()
    end
    if #away > 0 then
        Utils.SafeAfter(3, function()
            for i = 1, #away do Signal(away[i]) end
            wipe(away)
        end)
    end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
    if name ~= addonName then return end
    self:UnregisterEvent("ADDON_LOADED")
    local ok, err = Utils.xpcall(Init, Utils.ErrorHandler)
    if not ok then EasyFind:Print(L["ERR_MODULE_INIT_FAILED"]:format(ns.CLOCK_NAME, tostring(err))) end
end)

ns.Clock = Clock
