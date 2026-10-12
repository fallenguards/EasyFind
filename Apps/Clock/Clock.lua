local addonName, CL = ...
local ns = EasyFind and EasyFind._ns
if not (ns and ns.ClockRuns and ns.ClockGrammar and CL.Window and CL.Strip) then return end

local Utils = ns.Utils
local L = ns.L
local Runs = ns.ClockRuns
local Grammar = ns.ClockGrammar
local Format = Grammar.FormatDuration
local Window, Strip = CL.Window, CL.Strip

local CreateFrame, UIParent, Minimap = CreateFrame, UIParent, Minimap
local GetCursorPosition, InCombatLockdown, UnitAffectingCombat = GetCursorPosition, InCombatLockdown, UnitAffectingCombat
local PlaySound, FlashClientIcon = PlaySound, FlashClientIcon
local time, date, type, wipe = time, date, type, wipe
local sformat = Utils.sformat
local mdeg, matan2 = math.deg, math.atan2

local TICK_SECONDS = 0.2
local PLUS_SECONDS = 300
local RESTART_TEXT = _G["RESTART"] or "Restart"
local ALERT_SOUND = SOUNDKIT and SOUNDKIT.ALARM_CLOCK_WARNING_3

-- Frames and state in one table (upvalue budget).
local UI = { events = {}, away = {} }
local Clock = {}
local UpdateDim

-- A menu names a pomodoro, not its phase.
local function MenuLabel(run)
    if run.tool == "pomodoro" then return CL.TOOL_NAMES.pomodoro end
    return CL.RunLabel(run)
end

-- The end of a run

local function EventText(event)
    local run, kind = event.run, event.kind
    local text
    if kind == "timer" then
        text = sformat(L["CLOCK_DONE_FMT"], CL.RunLabel(run))
    elseif kind == "alarm" then
        text = CL.RunLabel(run)
    elseif kind == "mark" then
        text = sformat(L["CLOCK_MARK_REACHED"], Format(run.mark))
    elseif kind == "break" then
        text = sformat(L["CLOCK_BREAK_START"], Format(run.breakLen))
    else
        text = sformat(L["CLOCK_FOCUS_START"], Format(run.focusLen))
    end
    if event.away then text = sformat(L["CLOCK_AWAY_FMT"], text) end
    return text
end

local function PaintAlert(alert)
    local c = CL.GOLD
    alert.text:SetTextColor(c[1], c[2], c[3], 1)
end

-- Big center-screen text, like a raid warning.
local function ShowAlert(text)
    local alert = UI.alert
    if not alert then
        alert = CreateFrame("Frame", nil, UIParent)
        alert:SetSize(900, 60)
        alert:SetPoint("CENTER", UIParent, "CENTER", 0, 170)
        alert:SetFrameStrata("HIGH")
        alert:EnableMouse(false)
        alert.text = alert:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        local font = alert.text:GetFont()
        if font then alert.text:SetFont(font, 30, "OUTLINE") end
        alert.text:SetAllPoints()
        alert.fade = alert:CreateAnimationGroup()
        local hold = alert.fade:CreateAnimation("Alpha")
        hold:SetFromAlpha(1)
        hold:SetToAlpha(1)
        hold:SetDuration(4)
        hold:SetOrder(1)
        local out = alert.fade:CreateAnimation("Alpha")
        out:SetFromAlpha(1)
        out:SetToAlpha(0)
        out:SetDuration(1.5)
        out:SetOrder(2)
        alert.fade:SetScript("OnFinished", function() alert:Hide() end)
        UI.alert = alert
        CL.Painted(alert, PaintAlert)
    end
    alert.text:SetText(text)
    alert.fade:Stop()
    alert:SetAlpha(1)
    alert:Show()
    alert.fade:Play()
end

-- Every enabled signal. A run that ended while the player was away is
-- told in text only, once the loading screen is gone.
local function Signal(event)
    local db = EasyFind.db
    local text = EventText(event)
    if event.kind == "break" then UI.dimDismissed = nil end
    if db.clockChat ~= false then EasyFind:Print(text) end
    if db.clockBigText ~= false then ShowAlert(text) end
    if event.away then return end
    if db.clockSound ~= false and ALERT_SOUND then PlaySound(ALERT_SOUND, "Master") end
    if db.clockFlash ~= false then FlashClientIcon() end
    Window.Pulse(event.run)
end

-- Ticking

local driver = CreateFrame("Frame")

local function Tick()
    local now = time()
    local events = UI.events
    wipe(events)
    local changed = Runs:Update(now, events)
    for i = 1, #events do Signal(events[i]) end
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
    UI.tickWait = TICK_SECONDS
    Tick()
end

-- Runs only while something counts: an ended card waits without a tick.
local function UpdateTicker()
    local want = false
    local runs = Runs:List()
    for i = 1, #runs do
        if not runs[i].done then want = true end
    end
    if want == (UI.ticking or false) then return end
    UI.ticking = want
    UI.tickWait = 0
    Utils.SafeOnUpdate(driver, want and OnDriverUpdate or nil)
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

-- A timer runs its own length again; an alarm rings at the same time tomorrow.
function CL.Again(run)
    local now = time()
    local at
    if run.tool == "alarm" then
        local t = date("*t", run.at)
        at = Grammar.AlarmTarget(t.hour, t.min, true, now)
    end
    Runs:Again(run, now, at)
    CL.Changed()
end

function CL.OpenSettings()
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

-- Menus

-- The owner's own click toggles its menu.
local function ShowMenu(rows, owner)
    local menu = UI.menu
    if menu and menu:IsShown() and menu.toggleOwner == owner then
        menu:Hide()
        return
    end
    UI.menu = Utils.ShowCursorMenu("EasyFindClockMenu", rows, { toggleOwner = owner })
end

local function Row(text, fn, run)
    return { text = text, onClick = function() fn(run) end }
end

local function TogglePause(run)
    Runs:TogglePause(run, time())
    CL.Changed()
end

local function Restart(run)
    Runs:Restart(run, time())
    CL.Changed()
end

local function Extend(run)
    Runs:Extend(run, time(), PLUS_SECONDS)
    CL.Changed()
end

local function Cancel(run)
    Runs:Cancel(run)
    CL.Changed()
end

-- The card's and the strip segment's right-click: what the card's own
-- buttons do, plus restart.
function CL.ShowRunMenu(run, owner)
    local rows = {}
    if run.done then
        rows[1] = Row(L["CLOCK_PLUS5"], Extend, run)
        rows[2] = Row(L["CLOCK_AGAIN"], CL.Again, run)
        rows[3] = Row(L["CLOCK_DISMISS"], Cancel, run)
    else
        if run.tool ~= "alarm" then
            rows[#rows + 1] = Row(run.pausedAt and L["CLOCK_RESUME"] or L["CLOCK_PAUSE"], TogglePause, run)
        end
        if run.tool == "pomodoro" then
            rows[#rows + 1] = Row(run.phase == "focus" and L["CLOCK_SKIP_BREAK"] or L["CLOCK_SKIP_FOCUS"], CL.Skip, run)
        end
        if run.tool ~= "alarm" then rows[#rows + 1] = Row(RESTART_TEXT, Restart, run) end
        rows[#rows + 1] = Row(L["CLOCK_STOP"], Cancel, run)
    end
    ShowMenu(rows, owner)
end

local function CancelAll()
    Runs:CancelAll()
    CL.Changed()
end

local function ShowCancelMenu(owner)
    local runs = Runs:List()
    if #runs == 0 then return end
    local rows = {}
    for i = 1, #runs do
        local row = Row(sformat(L["CLOCK_CANCEL_RUN"], MenuLabel(runs[i])), Cancel, runs[i])
        row.icon, row.chromeIcon = ns.CLOCK_TOOL_ICONS[runs[i].tool], true
        rows[i] = row
    end
    if #runs > 1 then
        rows[#rows + 1] = { isSeparator = true }
        rows[#rows + 1] = { text = L["CLOCK_CANCEL_ALL"], onClick = CancelAll }
    end
    ShowMenu(rows, owner)
end

-- The minimap icon, a setting (off unless turned on)

local function PlaceMinimapButton()
    local x, y = ns.MinimapEdgeOffset(Runs.sv.minimapAngle)
    UI.mm:ClearAllPoints()
    UI.mm:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function MinimapDrag(self, elapsed)
    self.dragWait = (self.dragWait or 0) - elapsed
    if self.dragWait > 0 then return end
    self.dragWait = 0.03
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    Runs.sv.minimapAngle = mdeg(matan2(cy / scale - my, cx / scale - mx))
    PlaceMinimapButton()
end

local function MinimapOnClick(self, button)
    if button == "RightButton" then
        ShowCancelMenu(self)
    elseif Window.IsShown() then
        CL.Minimize()
    else
        CL.OpenWindow()
    end
end

local function PaintMinimap(btn)
    local gc = ns.ChromeGlyphColor()
    btn.icon:SetVertexColor(gc[1], gc[2], gc[3], 1)
end

local function EnsureMinimapButton()
    if UI.mm then return UI.mm end
    local btn = CreateFrame("Button", "EasyFindClockMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(50, 50)
    border:SetTexture(136430)
    border:SetPoint("TOPLEFT")
    local background = btn:CreateTexture(nil, "BACKGROUND")
    background:SetSize(24, 24)
    background:SetTexture(136467)
    background:SetPoint("CENTER")
    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetSize(17, 17)
    btn.icon:SetPoint("CENTER")
    btn.icon:SetTexture(ns.CLOCK_ICON_TEX)
    btn:SetHighlightTexture(136477)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", MinimapOnClick)
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function(self)
        self.dragWait = 0
        Utils.SafeOnUpdate(self, MinimapDrag)
    end)
    btn:SetScript("OnDragStop", function(self) Utils.SafeOnUpdate(self, nil) end)
    btn:SetScript("OnEnter", function(self)
        ns.ShowHintTooltip(self, "ANCHOR_LEFT", ns.CLOCK_NAME, L["CLOCK_MM_TT"], L["MINIMAP_TT_DRAG"])
    end)
    btn:SetScript("OnLeave", function(self) ns.HideHintTooltip(self) end)
    UI.mm = btn
    CL.Painted(btn, PaintMinimap)
    return btn
end

local function UpdateMinimapButton()
    local want = EasyFind.db.clockMinimapIcon == true and #Runs:List() > 0
    if not (want or UI.mm) then return end
    EnsureMinimapButton():SetShown(want)
    if want then PlaceMinimapButton() end
end

-- State changes

function CL.Changed()
    EasyFind.db.clockActive = #Runs:List() > 0
    UpdateTicker()
    UpdateMinimapButton()
    Window.Refresh()
    Strip.Refresh()
    UpdateDim(time())
end

-- A new run opens the window, unless the player minimized it while other
-- runs were going: then it joins the strip.
function CL.StartRun(tool, a, b)
    if not UI.ready then
        UI.queued = { tool, a, b }
        return
    end
    local hadRuns = #Runs:List() > 0
    local run = Runs:Start(tool, time(), a, b)
    if not run then
        EasyFind:Print(sformat(L["CLOCK_FULL"], Runs.MAX))
        return
    end
    if tool == "pomodoro" then UI.dimDismissed = nil end
    if not (hadRuns and Runs.sv.hud.shown == false) then
        Runs.sv.hud.shown = true
        Window.Show()
    end
    CL.Changed()
end

if ns.RegisterThemeCallback then ns.RegisterThemeCallback(CL.RepaintAll) end

-- What the core and the options panel call

-- A parsed search-bar command (Search/ClockCommands.lua).
function Clock.StartFromCommand(cmd)
    if type(cmd) ~= "table" or not Grammar.Resolve(cmd, time()) then return end
    local tool = cmd.tool
    if tool == "alarm" then
        CL.StartRun("alarm", cmd.at)
    elseif tool == "pomodoro" then
        CL.StartRun("pomodoro", cmd.seconds, cmd.seconds2)
    else
        CL.StartRun(tool, cmd.seconds)
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

-- A setting changed (the break dim, the minimap icon).
function Clock.SettingsChanged()
    if UI.ready then CL.Changed() end
end

-- Saved runs arrive with ADDON_LOADED: runs that ended while the player
-- was away say so once the world is up.
local function Init()
    local now = time()
    EasyClockDB = Runs:Attach(EasyClockDB, now)
    local away = UI.away
    Runs:Update(now, away, true)
    UI.ready = true
    if #Runs:List() > 0 and Runs.sv.hud.shown ~= false then Window.Show() end
    CL.Changed()
    local queued = UI.queued
    UI.queued = nil
    if queued then CL.StartRun(queued[1], queued[2], queued[3]) end
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
