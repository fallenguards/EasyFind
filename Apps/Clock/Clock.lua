local addonName = ...
local ns = EasyFind and EasyFind._ns
if not (ns and ns.ClockRuns and ns.ClockGrammar) then return end

local Utils = ns.Utils
local L = ns.L
local Runs = ns.ClockRuns
local Grammar = ns.ClockGrammar
local Format = Grammar.FormatDuration

local CreateFrame, UIParent, Minimap = CreateFrame, UIParent, Minimap
local GetCursorPosition, InCombatLockdown, UnitAffectingCombat = GetCursorPosition, InCombatLockdown, UnitAffectingCombat
local PlaySound, FlashClientIcon = PlaySound, FlashClientIcon
local time, type, wipe = time, type, wipe
local sformat = Utils.sformat
local mdeg, matan2 = math.deg, math.atan2

local WIDTH, HEADER_H, ROW_H, PAD = 240, 30, 22, 8
local TICK_SECONDS = 0.2
local PAUSED_ALPHA = 0.55
local TIMER_PRESETS = { 60, 180, 300, 600, 900, 1800, 3600 }
local TOOL_NAMES = {
    pomodoro = L["CLOCK_POMODORO"],
    timer = L["CLOCK_TIMER"],
    stopwatch = _G["STOPWATCH_TITLE"] or "Stopwatch",
    alarm = L["CLOCK_ALARM"],
}
local DONE_TEXT = _G["DONE"] or "Done"
local CANCEL_TEXT = _G["CANCEL"] or "Cancel"
local RESTART_TEXT = _G["RESTART"] or "Restart"
local ALERT_SOUND = SOUNDKIT and SOUNDKIT.ALARM_CLOCK_WARNING_3

-- Frames and view state in one table (upvalue budget).
local UI = { rows = {}, events = {}, away = {} }
local Clock = {}
local OnRunsChanged, ShowHUD, RefreshHUD, UpdateTimes, UpdateDim, StartRun

local function RunLabel(run)
    local tool = run.tool
    if tool == "timer" then return TOOL_NAMES.timer .. " " .. Format(run.duration) end
    if tool == "alarm" then return TOOL_NAMES.alarm .. " " .. Grammar.TimeLabel(run.at) end
    if tool == "stopwatch" then
        return run.mark and (TOOL_NAMES.stopwatch .. " " .. Format(run.mark)) or TOOL_NAMES.stopwatch
    end
    local n = (run.intervals or 0) + (run.phase == "focus" and 1 or 0)
    return sformat(run.phase == "break" and L["CLOCK_BREAK_N"] or L["CLOCK_FOCUS_N"], n)
end

-- A menu names a pomodoro, not its phase.
local function MenuLabel(run)
    if run.tool == "pomodoro" then return TOOL_NAMES.pomodoro end
    return RunLabel(run)
end

local function Palette()
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    local light = theme and theme.lightTheme
    local body = light and theme.leafColor or ns.TEXT_PRIMARY
    local dim = light and (theme.textFaint or theme.leafColor) or ns.TEXT_DIM
    local accent = theme and theme.accent or ns.GOLD_COLOR
    return body, dim, accent, light
end

-- The end of a run

local function EventText(event)
    local run, kind = event.run, event.kind
    local text
    if kind == "timer" then
        text = sformat(L["CLOCK_DONE_FMT"], RunLabel(run))
    elseif kind == "alarm" then
        text = RunLabel(run)
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

local function PaintAlert()
    local alert = UI.alert
    if not alert then return end
    local _, _, accent = Palette()
    alert.text:SetTextColor(accent[1], accent[2], accent[3], 1)
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
        PaintAlert()
    end
    alert.text:SetText(text)
    alert.fade:Stop()
    alert:SetAlpha(1)
    alert:Show()
    alert.fade:Play()
end

local function PulseRow(run)
    if not (UI.hud and UI.hud:IsShown()) then return end
    for i = 1, #UI.rows do
        local row = UI.rows[i]
        if row.run == run then
            row.pulse:Stop()
            row.pulse:Play()
            return
        end
    end
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
    PulseRow(event.run)
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
        OnRunsChanged()
    else
        UpdateTimes(now)
        UpdateDim(now)
    end
end

local function OnDriverUpdate(_, elapsed)
    UI.tickWait = (UI.tickWait or 0) - elapsed
    if UI.tickWait > 0 then return end
    UI.tickWait = TICK_SECONDS
    Tick()
end

-- Runs only while a run exists.
local function UpdateTicker()
    local want = #Runs:List() > 0
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
local function PaintDim()
    local dim = UI.dim
    if not dim then return end
    local _, _, accent = Palette()
    dim.title:SetTextColor(accent[1], accent[2], accent[3], 1)
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
    dim.time = dim:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    local font = dim.time:GetFont()
    if font then dim.time:SetFont(font, 56, "OUTLINE") end
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
    PaintDim()
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

local function ShowRunMenu(run, owner)
    local rows = {}
    if not run.done and run.tool ~= "alarm" then
        rows[#rows + 1] = {
            text = run.pausedAt and L["CLOCK_RESUME"] or L["CLOCK_PAUSE"],
            onClick = function()
                Runs:TogglePause(run, time())
                OnRunsChanged()
            end,
        }
    end
    if run.tool == "pomodoro" and not run.done then
        rows[#rows + 1] = {
            text = run.phase == "focus" and L["CLOCK_SKIP_BREAK"] or L["CLOCK_SKIP_FOCUS"],
            onClick = function()
                if Runs:SkipPhase(run, time()) == "break" then UI.dimDismissed = nil end
                OnRunsChanged()
            end,
        }
    end
    if run.tool ~= "alarm" then
        rows[#rows + 1] = {
            text = RESTART_TEXT,
            onClick = function()
                Runs:Restart(run, time())
                OnRunsChanged()
            end,
        }
    end
    rows[#rows + 1] = {
        text = CANCEL_TEXT,
        onClick = function()
            Runs:Cancel(run)
            OnRunsChanged()
        end,
    }
    ShowMenu(rows, owner)
end

local function ShowStartMenu(owner)
    local timers = {}
    for i = 1, #TIMER_PRESETS do
        local sec = TIMER_PRESETS[i]
        timers[i] = { text = Format(sec), onClick = function() StartRun("timer", sec) end }
    end
    ShowMenu({
        {
            text = L["CLOCK_CMD_POMODORO"],
            icon = ns.CLOCK_TOOL_ICONS.pomodoro, chromeIcon = true,
            onClick = function() StartRun("pomodoro", Grammar.PomodoroDefaults()) end,
        },
        { text = L["CLOCK_CMD_TIMER"], icon = ns.CLOCK_TOOL_ICONS.timer, chromeIcon = true, submenu = timers },
        {
            text = L["CLOCK_CMD_STOPWATCH"],
            icon = ns.CLOCK_TOOL_ICONS.stopwatch, chromeIcon = true,
            onClick = function() StartRun("stopwatch") end,
        },
    }, owner)
end

local function ShowCancelMenu(owner)
    local runs = Runs:List()
    if #runs == 0 then return end
    local rows = {}
    for i = 1, #runs do
        local run = runs[i]
        rows[#rows + 1] = {
            text = sformat(L["CLOCK_CANCEL_RUN"], MenuLabel(run)),
            icon = ns.CLOCK_TOOL_ICONS[run.tool], chromeIcon = true,
            onClick = function()
                Runs:Cancel(run)
                OnRunsChanged()
            end,
        }
    end
    if #runs > 1 then
        rows[#rows + 1] = { isSeparator = true }
        rows[#rows + 1] = {
            text = L["CLOCK_CANCEL_ALL"],
            onClick = function()
                Runs:CancelAll()
                OnRunsChanged()
            end,
        }
    end
    ShowMenu(rows, owner)
end

local function OpenSettings()
    if ns.RequestOptionsPanel() and ns.Options.OpenAtExtension then
        ns.Options:OpenAtExtension("clock")
    end
end

-- The window

local function HUDDragStart()
    UI.hud:StartMoving()
end

-- The place is read before the stop, which can leave the frame unanchored.
local function HUDDragStop()
    local hud = UI.hud
    local left, top = hud:GetLeft(), hud:GetTop()
    hud:StopMovingOrSizing()
    hud:SetUserPlaced(false)
    if left and top then
        hud:ClearAllPoints()
        hud:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        Runs.sv.hud.left, Runs.sv.hud.top = left, top
    end
end

local function PaintPlus(btn, hover)
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    local c = hover and (theme and theme.leafColor or { 1, 1, 1 }) or (theme and theme.textFaint or ns.TEXT_DIM)
    btn.h:SetVertexColor(c[1], c[2], c[3], 1)
    btn.v:SetVertexColor(c[1], c[2], c[3], 1)
end

local function CreatePlusButton(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(16, 16)
    btn.h = btn:CreateTexture(nil, "OVERLAY")
    btn.h:SetTexture("Interface\\Buttons\\WHITE8x8")
    btn.h:SetSize(12, 1.5)
    btn.h:SetPoint("CENTER")
    btn.v = btn:CreateTexture(nil, "OVERLAY")
    btn.v:SetTexture("Interface\\Buttons\\WHITE8x8")
    btn.v:SetSize(1.5, 12)
    btn.v:SetPoint("CENTER")
    btn:SetScript("OnEnter", function(self) PaintPlus(self, true) end)
    btn:SetScript("OnLeave", function(self) PaintPlus(self, false) end)
    PaintPlus(btn, false)
    return btn
end

local function PaintRow(row)
    local body, _, accent, light = Palette()
    local gc = ns.ChromeGlyphColor()
    row.icon:SetVertexColor(gc[1], gc[2], gc[3], 1)
    row.name:SetTextColor(body[1], body[2], body[3], 1)
    local run = row.run
    local c = run and (run.done or run.markHit) and accent or body
    row.time:SetTextColor(c[1], c[2], c[3], 1)
    row.flash:SetVertexColor(accent[1], accent[2], accent[3], 1)
    local shadow = light and 0 or 1
    row.name:SetShadowColor(0, 0, 0, shadow)
    row.time:SetShadowColor(0, 0, 0, shadow)
end

local function RowOnClick(self, button)
    if button == "RightButton" and self.run then ShowRunMenu(self.run, self) end
end

local function RowTooltip(self)
    if not self.run then return nil end
    return RunLabel(self.run), L["CLOCK_ROW_TT"]
end

local function EnsureRow(i)
    local row = UI.rows[i]
    if row then return row end
    local hud = UI.hud
    row = CreateFrame("Button", nil, hud)
    row:SetHeight(ROW_H)
    local top = -(HEADER_H + (i - 1) * ROW_H)
    row:SetPoint("TOPLEFT", hud, "TOPLEFT", PAD - 2, top)
    row:SetPoint("TOPRIGHT", hud, "TOPRIGHT", -(PAD - 2), top)
    row:RegisterForClicks("RightButtonUp")
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnDragStart", HUDDragStart)
    row:SetScript("OnDragStop", HUDDragStop)
    row:SetScript("OnClick", RowOnClick)
    Utils.InstallMenuRowHighlight(row)
    Utils.AttachDelayedTooltip(row, "ANCHOR_RIGHT", RowTooltip)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(14, 14)
    row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.time = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.time:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.time:SetJustifyH("RIGHT")
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetPoint("RIGHT", row.time, "LEFT", -6, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    -- Three soft pulses when the run signals.
    row.flash = row:CreateTexture(nil, "BACKGROUND")
    row.flash:SetAllPoints()
    row.flash:SetColorTexture(1, 1, 1, 1)
    row.flash:SetAlpha(0)
    row.pulse = row.flash:CreateAnimationGroup()
    for n = 0, 2 do
        local rise = row.pulse:CreateAnimation("Alpha")
        rise:SetFromAlpha(0)
        rise:SetToAlpha(0.35)
        rise:SetDuration(0.25)
        rise:SetOrder(n * 2 + 1)
        local fall = row.pulse:CreateAnimation("Alpha")
        fall:SetFromAlpha(0.35)
        fall:SetToAlpha(0)
        fall:SetDuration(0.35)
        fall:SetOrder(n * 2 + 2)
    end
    UI.rows[i] = row
    return row
end

local function PaintHUD()
    local hud = UI.hud
    if not hud then return end
    local _, faint, _, light = Palette()
    local gc = ns.ChromeGlyphColor()
    hud.glyph:SetVertexColor(gc[1], gc[2], gc[3], 1)
    hud.title:SetTextColor(ns.TooltipTextColor())
    hud.hint:SetTextColor(faint[1], faint[2], faint[3], 1)
    local shadow = light and 0 or 1
    hud.title:SetShadowColor(0, 0, 0, shadow)
    hud.hint:SetShadowColor(0, 0, 0, shadow)
    PaintPlus(hud.plus, false)
    for i = 1, #UI.rows do PaintRow(UI.rows[i]) end
    Utils.RefreshMenuRowHighlights(hud, UI.rows)
end

local function EnsureHUD()
    if UI.hud then return UI.hud end
    local hud = CreateFrame("Frame", "EasyFindClockWindow", UIParent, "BackdropTemplate")
    UI.hud = hud
    hud:Hide()
    hud:SetSize(WIDTH, HEADER_H + 2 * ROW_H + PAD)
    hud:SetFrameStrata("HIGH")
    hud:SetClampedToScreen(true)
    hud:EnableMouse(true)
    hud:SetMovable(true)
    hud:RegisterForDrag("LeftButton")
    hud:SetScript("OnDragStart", HUDDragStart)
    hud:SetScript("OnDragStop", HUDDragStop)
    ns.StyleMenuPanel(hud)
    local pos = Runs.sv.hud
    if type(pos.left) == "number" and type(pos.top) == "number" then
        hud:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.left, pos.top)
    else
        hud:SetPoint("CENTER", UIParent, "CENTER", 300, 180)
    end

    hud.glyph = hud:CreateTexture(nil, "ARTWORK")
    hud.glyph:SetSize(16, 16)
    hud.glyph:SetPoint("TOPLEFT", hud, "TOPLEFT", PAD + 2, -8)
    hud.glyph:SetTexture(ns.CLOCK_ICON_TEX)
    hud.title = hud:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hud.title:SetPoint("LEFT", hud.glyph, "RIGHT", 6, 0)
    hud.title:SetText(ns.CLOCK_NAME)

    -- The X minimizes to the minimap; it never cancels a run.
    local close = ns.CreateCloseX(hud, 16)
    close:SetPoint("TOPRIGHT", hud, "TOPRIGHT", -PAD, -8)
    close:SetScript("OnClick", function() Clock.Minimize() end)
    Utils.AttachDelayedTooltip(close, "ANCHOR_TOP", function() return L["CLOCK_MINIMIZE_TT"] end)
    local cog = ns.CreateCogButton(hud)
    cog:SetPoint("RIGHT", close, "LEFT", -4, 0)
    cog:SetScript("OnClick", OpenSettings)
    Utils.AttachDelayedTooltip(cog, "ANCHOR_TOP", function() return _G["SETTINGS"] or "Settings" end)
    hud.plus = CreatePlusButton(hud)
    hud.plus:SetPoint("RIGHT", cog, "LEFT", -4, 0)
    hud.plus:SetScript("OnClick", ShowStartMenu)
    Utils.AttachDelayedTooltip(hud.plus, "ANCHOR_TOP", function() return L["CLOCK_NEW_TT"] end)

    hud.hint = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hud.hint:SetPoint("TOPLEFT", hud, "TOPLEFT", PAD + 2, -HEADER_H)
    hud.hint:SetPoint("RIGHT", hud, "RIGHT", -(PAD + 2), 0)
    hud.hint:SetJustifyH("LEFT")
    hud.hint:SetText(L["CLOCK_EMPTY_HINT"])
    PaintHUD()
    return hud
end

function UpdateTimes(now)
    if not (UI.hud and UI.hud:IsShown()) then return end
    for i = 1, #UI.rows do
        local row = UI.rows[i]
        local run = row.run
        if run then
            local text = run.done and DONE_TEXT or Format(Runs.Shown(run, now))
            if row.shownText ~= text then
                row.shownText = text
                row.time:SetText(text)
            end
        end
    end
end

function RefreshHUD()
    local hud = UI.hud
    if not hud then return end
    local runs = Runs:List()
    local n = #runs
    for i = 1, n do
        local row = EnsureRow(i)
        local run = runs[i]
        row.run = run
        row.icon:SetTexture(ns.CLOCK_TOOL_ICONS[run.tool])
        row.name:SetText(RunLabel(run))
        row:SetAlpha(run.pausedAt and PAUSED_ALPHA or 1)
        row.shownText = nil
        PaintRow(row)
        row:Show()
    end
    for i = n + 1, #UI.rows do
        UI.rows[i]:Hide()
        UI.rows[i].run = nil
    end
    hud.hint:SetShown(n == 0)
    -- The empty hint wraps to two lines.
    hud:SetHeight(HEADER_H + (n > 0 and n or 2) * ROW_H + PAD)
    -- The rows wear the menus' hover pill.
    Utils.RefreshMenuRowHighlights(hud, UI.rows)
    UpdateTimes(time())
end

function ShowHUD()
    EnsureHUD():Show()
    RefreshHUD()
    Runs.sv.hud.shown = true
end

-- The minimap icon

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
    elseif UI.hud and UI.hud:IsShown() then
        Clock.Minimize()
    else
        ShowHUD()
    end
end

local function PaintMinimap()
    if not UI.mm then return end
    local gc = ns.ChromeGlyphColor()
    UI.mm.icon:SetVertexColor(gc[1], gc[2], gc[3], 1)
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
    PaintMinimap()
    return btn
end

-- Shown while any run exists: the window minimizes to it.
local function UpdateMinimapButton()
    local active = #Runs:List() > 0
    if not (active or UI.mm) then return end
    EnsureMinimapButton():SetShown(active)
    if active then PlaceMinimapButton() end
end

-- State changes

function OnRunsChanged()
    local n = #Runs:List()
    EasyFind.db.clockActive = n > 0
    UpdateTicker()
    UpdateMinimapButton()
    if UI.hud then
        if n == 0 and UI.hadRuns and UI.hud:IsShown() then
            UI.hud:Hide()
        else
            RefreshHUD()
        end
    end
    UI.hadRuns = n > 0
    UpdateDim(time())
end

function StartRun(tool, a, b)
    -- Before the saved runs are in, the start waits for them.
    if not UI.ready then
        UI.queued = { tool, a, b }
        return
    end
    local run = Runs:Start(tool, time(), a, b)
    if not run then
        EasyFind:Print(sformat(L["CLOCK_FULL"], Runs.MAX))
        return
    end
    if tool == "pomodoro" then UI.dimDismissed = nil end
    OnRunsChanged()
    ShowHUD()
end

if ns.RegisterThemeCallback then
    ns.RegisterThemeCallback(function()
        PaintHUD()
        PaintMinimap()
        PaintAlert()
        PaintDim()
    end)
end

-- What the core and the options panel call

-- A parsed search-bar command (Search/ClockCommands.lua).
function Clock.StartFromCommand(cmd)
    if type(cmd) ~= "table" or not Grammar.Resolve(cmd, time()) then return end
    local tool = cmd.tool
    if tool == "alarm" then
        StartRun("alarm", cmd.at)
    elseif tool == "pomodoro" then
        StartRun("pomodoro", cmd.seconds, cmd.seconds2)
    else
        StartRun(tool, cmd.seconds)
    end
end

function Clock.Open()
    if UI.ready then ShowHUD() else UI.openQueued = true end
end

function Clock.Minimize()
    if UI.hud then UI.hud:Hide() end
    if Runs.sv then Runs.sv.hud.shown = false end
end

function Clock.IsOpen()
    return UI.hud ~= nil and UI.hud:IsShown()
end

-- A setting changed (the break dim, a unit).
function Clock.SettingsChanged()
    if UI.ready then OnRunsChanged() end
end

-- Saved runs arrive with ADDON_LOADED: runs that ended while the player
-- was away say so once the world is up.
local function Init()
    local now = time()
    EasyClockDB = Runs:Attach(EasyClockDB, now)
    local away = UI.away
    Runs:Update(now, away, true)
    UI.ready = true
    UI.hadRuns = #Runs:List() > 0
    OnRunsChanged()
    if UI.hadRuns and Runs.sv.hud.shown ~= false then ShowHUD() end
    local queued = UI.queued
    UI.queued = nil
    if queued then StartRun(queued[1], queued[2], queued[3]) end
    if UI.openQueued then
        UI.openQueued = nil
        ShowHUD()
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
