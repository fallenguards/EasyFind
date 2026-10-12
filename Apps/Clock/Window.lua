local _, CL = ...
local ns = EasyFind and EasyFind._ns
if not (ns and ns.ClockRuns and ns.ClockGrammar) then return end

-- The window: one card per run, the kept alarms under them, and the start
-- tiles when nothing runs (or when the header's + asks for them).
local Utils = ns.Utils
local L = ns.L
local Runs = ns.ClockRuns

local CreateFrame, UIParent = CreateFrame, UIParent
local time, type = time, type
local mmin, sformat, pairs = Utils.mmin, Utils.sformat, Utils.pairs

local Window = {}
CL.Window = Window

local W, PAD, HEADER_H, GAP = 272, 8, 30, 6
local CARD_H, RING, BTN, BTN_GAP = 56, 40, 22, 4
-- Buttons sit just above the label line, so the label runs the card's width.
local BTN_Y = 8 + RING / 2 - 3
local CHIP_H, CHIP_ROW = 18, 28
local LAP_HEAD, LAP_ROW, LAPS_SHOWN = 18, 14, 8
local MAX_DOTS = 8
local PLUS_SECONDS, NUDGE = 300, 60
local PAUSED_ALPHA = 0.55
local HALF_PI = math.pi / 2
Window.W, Window.PAD, Window.CHIP_H = W, PAD, CHIP_H

local UI = { cards = {} }

function CL.WindowDragStart()
    UI.win:StartMoving()
end

-- The place is read before the stop, which can leave the frame unanchored.
function CL.WindowDragStop()
    local win = UI.win
    local left, top = win:GetLeft(), win:GetTop()
    win:StopMovingOrSizing()
    win:SetUserPlaced(false)
    if left and top then
        win:ClearAllPoints()
        win:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        Runs.sv.hud.left, Runs.sv.hud.top = left, top
    end
end

-- Card buttons

local function CardRun(btn)
    return btn.card.run
end

local function Act(fn)
    return function(self)
        fn(CardRun(self))
    end
end

local ACTIONS = {
    pause = function(run) Runs:TogglePause(run, time()) CL.Changed() end,
    stop = function(run) Runs:Cancel(run) CL.Changed() end,
    skip = function(run) CL.Skip(run) end,
    plus = function(run) Runs:Adjust(run, time(), NUDGE) CL.Changed() end,
    minus = function(run) Runs:Adjust(run, time(), -NUDGE) CL.Changed() end,
    lap = function(run) Runs:Lap(run, time()) CL.Changed() end,
    reset = function(run) Runs:Restart(run, time()) CL.Changed() end,
    more = function(run) Runs:Extend(run, time(), PLUS_SECONDS) CL.Changed() end,
    again = function(run) CL.Again(run) end,
    snooze = function(run) CL.Snooze(run) end,
    laps = function(run)
        run.lapsOpen = not run.lapsOpen
        Window.Refresh()
    end,
}

local function CardClick(self, button)
    if button == "RightButton" and self.run then CL.ShowRunMenu(self.run, self) end
end

local function PaintPill(card)
    local run = card.run
    if not (run and run.tool == "pomodoro") then return end
    local c = CL.KindColor(run)
    local _, faint, light = CL.Palette()
    ns.SetRoundedRectFill(card.pill, c[1], c[2], c[3], 0.22, true)
    -- The phase color lifted toward white, or toward black on light themes.
    local to, k = light and 0 or 1, light and 0.3 or 0.45
    card.pill.text:SetTextColor(c[1] + (to - c[1]) * k, c[2] + (to - c[2]) * k, c[3] + (to - c[3]) * k, 1)
    card.pill.text:SetShadowColor(0, 0, 0, 0)
    local r, g, b = CL.Surface(0.24)
    for i = 1, #card.dots do
        if i <= (card.lit or 0) then
            card.dots[i]:SetVertexColor(c[1], c[2], c[3], 1)
        else
            card.dots[i]:SetVertexColor(r, g, b, 1)
        end
    end
    card.pomName:SetTextColor(faint[1], faint[2], faint[3], 1)
end

local function PaintCard(card)
    local r, g, b = CL.Surface(0.07)
    ns.SetRoundedRectFill(card, r, g, b, 1, true)
    ns.SetRoundedRectBorderEdgeShown(card, false)
    local body, faint, light = CL.Palette()
    local c = card.run and card.run.done and CL.GOLD or body
    card.time:SetTextColor(c[1], c[2], c[3], 1)
    card.label:SetTextColor(faint[1], faint[2], faint[3], 1)
    local shadow = light and 0 or 1
    card.time:SetShadowColor(0, 0, 0, shadow)
    card.label:SetShadowColor(0, 0, 0, shadow)
    card.lapHead:SetTextColor(faint[1], faint[2], faint[3], 1)
    card.lapArrow:SetVertexColor(faint[1], faint[2], faint[3], 1)
    for i = 1, #card.lapRows do
        local row = card.lapRows[i]
        row.n:SetTextColor(faint[1], faint[2], faint[3], 1)
        row.split:SetTextColor(body[1], body[2], body[3], 1)
        row.total:SetTextColor(faint[1], faint[2], faint[3], 1)
    end
    ns.SetRoundedRectFill(card.glow, CL.GOLD[1], CL.GOLD[2], CL.GOLD[3], 0.18, true)
    PaintPill(card)
end

local function Button(card, key, tex, word)
    local btn = CL.CreateRoundButton(card, BTN, tex, word)
    btn.card = card
    btn:SetScript("OnClick", Act(ACTIONS[key]))
    card.buttons[key] = btn
    return btn
end

local function Chip(card, key, action, label)
    local chip = CL.CreateChip(card, CHIP_H)
    chip.card = card
    if label then chip:SetLabel(label) end
    chip:SetScript("OnClick", Act(ACTIONS[action]))
    card.chips[key] = chip
    return chip
end

local function LapRow(card, i)
    local row = card.lapRows[i]
    if row then return row end
    row = {}
    row.n = CL.Text(card, "GameFontHighlightSmall")
    row.split = CL.Text(card, "GameFontHighlightSmall")
    row.total = CL.Text(card, "GameFontHighlightSmall")
    row.split:SetJustifyH("RIGHT")
    row.total:SetJustifyH("RIGHT")
    card.lapRows[i] = row
    return row
end

local function CreateCard()
    local card = CreateFrame("Button", nil, UI.win)
    card:SetHeight(CARD_H)
    card:RegisterForClicks("RightButtonUp")
    card:RegisterForDrag("LeftButton")
    card:SetScript("OnDragStart", CL.WindowDragStart)
    card:SetScript("OnDragStop", CL.WindowDragStop)
    card:SetScript("OnClick", CardClick)
    ns.CreateRoundedRectBorder(card)
    ns.SetRoundedRectBarHeight(card, 18)

    card.ring = CL.CreateRing(card, RING)
    card.ring:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -8)
    card.time = CL.DigitsText(card, 24)
    card.time:SetPoint("TOPLEFT", card.ring, "TOPRIGHT", 10, -1)
    card.label = CL.Text(card, "GameFontHighlightSmall")
    card.label:SetJustifyH("LEFT")
    card.label:SetWordWrap(false)

    -- A pomodoro's phase, its round in the set, then its name.
    card.pill = CreateFrame("Frame", nil, card)
    card.pill:SetHeight(14)
    card.pill:SetPoint("TOPLEFT", card.time, "BOTTOMLEFT", 0, -4)
    ns.CreateRoundedRectBorder(card.pill)
    ns.SetRoundedRectBarHeight(card.pill, 14)
    ns.SetRoundedRectBorderEdgeShown(card.pill, false)
    card.pill.text = CL.Text(card.pill, "GameFontHighlightSmall")
    card.pill.text:SetPoint("CENTER")
    card.dots = {}
    for i = 1, MAX_DOTS do
        local dot = card:CreateTexture(nil, "ARTWORK")
        dot:SetTexture(CL.TEX.dot)
        dot:SetSize(6, 6)
        dot:SetPoint("LEFT", card.pill, "RIGHT", 6 + (i - 1) * 9, 0)
        card.dots[i] = dot
    end
    card.pomName = CL.Text(card, "GameFontHighlightSmall")
    card.pomName:SetJustifyH("LEFT")
    card.pomName:SetWordWrap(false)

    card.buttons, card.chips = {}, {}
    Button(card, "stop", CL.TEX.stop).tip = L["CLOCK_STOP"]
    Button(card, "pause")
    Button(card, "skip", CL.TEX.skip)
    Button(card, "plus", nil, "+1").tip = L["CLOCK_PLUS1_TT"]
    Button(card, "minus", nil, "-1").tip = L["CLOCK_MINUS1_TT"]
    Button(card, "lap", CL.TEX.lap).tip = L["CLOCK_LAP"]
    Button(card, "reset", CL.TEX.reset).tip = _G["RESET"] or "Reset"

    -- Choices under the time: an ended run's, or the pomodoro's next phase.
    Chip(card, "dismiss", "stop", L["CLOCK_DISMISS"])
    Chip(card, "again", "again", L["CLOCK_AGAIN"])
    Chip(card, "more", "more", L["CLOCK_PLUS5"])
    Chip(card, "snooze", "snooze")
    Chip(card, "next", "pause", L["CLOCK_START_NEXT"])
    Chip(card, "restart", "reset", _G["RESTART"] or "Restart")

    -- A stopwatch's laps, newest first, folded under one line.
    card.lapToggle = CreateFrame("Button", nil, card)
    card.lapToggle:SetHeight(LAP_HEAD)
    card.lapToggle.card = card
    card.lapToggle:SetScript("OnClick", Act(ACTIONS.laps))
    card.lapArrow = card.lapToggle:CreateTexture(nil, "OVERLAY")
    card.lapArrow:SetSize(8, 8)
    card.lapArrow:SetPoint("LEFT", card.lapToggle, "LEFT", 0, 0)
    card.lapArrow:SetTexture(CL.TEX.play)
    card.lapHead = CL.Text(card.lapToggle, "GameFontHighlightSmall")
    card.lapHead:SetPoint("LEFT", card.lapArrow, "RIGHT", 4, 0)
    card.lapRows = {}

    -- Three soft gold pulses when the run signals.
    card.glow = CreateFrame("Frame", nil, card)
    card.glow:SetAllPoints()
    card.glow:EnableMouse(false)
    card.glow:SetAlpha(0)
    ns.CreateRoundedRectBorder(card.glow)
    ns.SetRoundedRectBarHeight(card.glow, 18)
    ns.SetRoundedRectBorderEdgeShown(card.glow, false)
    card.pulse = card.glow:CreateAnimationGroup()
    for n = 0, 2 do
        local rise = card.pulse:CreateAnimation("Alpha")
        rise:SetFromAlpha(0)
        rise:SetToAlpha(1)
        rise:SetDuration(0.25)
        rise:SetOrder(n * 2 + 1)
        local fall = card.pulse:CreateAnimation("Alpha")
        fall:SetFromAlpha(1)
        fall:SetToAlpha(0)
        fall:SetDuration(0.35)
        fall:SetOrder(n * 2 + 2)
    end
    CL.Painted(card, PaintCard)
    return card
end

local function TickCard(card, now)
    local run = card.run
    local text = CL.TimeString(run, now)
    if card.shownTime ~= text then
        card.shownTime = text
        card.time:SetText(text)
    end
    if card.label:IsShown() then
        local label = CL.CardLabel(run, now)
        if card.shownLabel ~= label then
            card.shownLabel = label
            card.label:SetText(label)
        end
    end
    CL.HoldRing(card.ring, run, now)
end

-- The round buttons a running card shows, right to left.
local function ButtonsFor(run)
    local tool = run.tool
    if run.done then return nil end
    if tool == "alarm" then return "stop" end
    if tool == "timer" then return "stop", "pause", "plus", "minus" end
    if tool == "stopwatch" then return "stop", "pause", "lap", "reset" end
    if run.waiting then return "stop", "skip" end
    return "stop", "pause", "skip"
end

-- The chips under the time, right to left.
local function ChipsFor(run)
    if run.done then
        if run.tool == "alarm" then return "dismiss", "snooze" end
        return "dismiss", "again", "more"
    end
    if run.waiting then return "next" end
    if run.pausedAt and run.tool == "timer" then return "restart" end
    return nil
end

local function ShowControls(card, run)
    for _, btn in pairs(card.buttons) do btn:Hide() end
    for _, chip in pairs(card.chips) do chip:Hide() end
    local keys = { ButtonsFor(run) }
    local right = -8
    for i = 1, #keys do
        local btn = card.buttons[keys[i]]
        btn:ClearAllPoints()
        btn:SetPoint("RIGHT", card, "TOPRIGHT", right, -BTN_Y)
        btn:Show()
        right = right - BTN - BTN_GAP
    end
    local chips = { ChipsFor(run) }
    local x = -8
    for i = 1, #chips do
        local chip = card.chips[chips[i]]
        chip:ClearAllPoints()
        chip:SetPoint("TOPRIGHT", card, "TOPRIGHT", x, -(8 + RING + 6))
        chip:Show()
        x = x - chip:GetWidth() - 5
    end
    return #chips > 0
end

-- The laps under a stopwatch; returns the height they take.
local function ShowLaps(card, run, top)
    local laps = run.laps
    local n = laps and #laps or 0
    card.lapToggle:SetShown(n > 0)
    local shown = (n > 0 and run.lapsOpen) and mmin(n, LAPS_SHOWN) or 0
    for i = 1, #card.lapRows do
        local row = card.lapRows[i]
        row.n:Hide()
        row.split:Hide()
        row.total:Hide()
    end
    if n == 0 then return 0 end
    card.lapToggle:ClearAllPoints()
    card.lapToggle:SetPoint("TOPLEFT", card, "TOPLEFT", 10, top)
    card.lapToggle:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, top)
    card.lapHead:SetText(sformat(L["CLOCK_LAPS"], n))
    -- The play glyph points down while the laps are open.
    card.lapArrow:SetRotation(run.lapsOpen and -HALF_PI or 0)
    for i = 1, shown do
        local lap = n - i + 1
        local row = LapRow(card, i)
        local y = top - LAP_HEAD - (i - 1) * LAP_ROW
        row.n:SetPoint("TOPLEFT", card, "TOPLEFT", 10, y)
        row.n:SetText(sformat(L["CLOCK_LAP_N"], lap))
        row.total:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, y)
        row.total:SetText(CL.Format(laps[lap]))
        row.split:SetPoint("TOPRIGHT", card, "TOPRIGHT", -70, y)
        row.split:SetText(CL.Format(laps[lap] - (laps[lap - 1] or 0)))
        row.n:Show()
        row.split:Show()
        row.total:Show()
    end
    PaintCard(card)
    return LAP_HEAD + shown * LAP_ROW + (shown > 0 and 4 or 0)
end

local function FillCard(card, run, now)
    card.run = run
    CL.SetRing(card.ring, run, now)
    card.shownTime, card.shownLabel = nil, nil

    local pom = run.tool == "pomodoro" and not run.done
    card.pill:SetShown(pom)
    card.pomName:SetShown(pom)
    card.label:SetShown(not pom)
    local set = 0
    if pom then
        card.pill.text:SetText(run.phase == "break" and L["CLOCK_BREAK"] or L["CLOCK_FOCUS"])
        card.pill:SetWidth(CL.TextWidth(card.pill.text) + 12)
        card.lit, set = CL.RoundInSet(run)
        set = mmin(set, MAX_DOTS)
        card.buttons.skip.tip = run.phase == "focus" and L["CLOCK_SKIP_BREAK"] or L["CLOCK_SKIP_FOCUS"]
        card.pomName:ClearAllPoints()
        card.pomName:SetPoint("LEFT", card.pill, "RIGHT", 6 + set * 9 + 2, 0)
        card.pomName:SetText(run.name or "")
    end
    for i = 1, #card.dots do card.dots[i]:SetShown(i <= set) end
    card.buttons.pause.icon:SetTexture(run.pausedAt and CL.TEX.play or CL.TEX.pause)
    card.buttons.pause.tip = run.pausedAt and L["CLOCK_RESUME"] or L["CLOCK_PAUSE"]
    card.chips.snooze:SetLabel(sformat(L["CLOCK_SNOOZE_FMT"], CL.SnoozeMinutes()))

    local chipRow = ShowControls(card, run)
    card.label:ClearAllPoints()
    card.label:SetPoint("TOPLEFT", card.time, "BOTTOMLEFT", 0, -4)
    card.label:SetPoint("RIGHT", card, "RIGHT", -10, 0)
    card.pomName:SetPoint("RIGHT", card, "RIGHT", -10, 0)
    card.time:SetAlpha(run.pausedAt and not run.waiting and PAUSED_ALPHA or 1)

    local h = CARD_H + (chipRow and CHIP_ROW or 0)
    h = h + ShowLaps(card, run, -h + 2)
    card:SetHeight(h)
    PaintCard(card)
    TickCard(card, now)
end

-- The window

local function PaintWindow(win)
    local _, _, light = CL.Palette()
    local gc = ns.ChromeGlyphColor()
    win.glyph:SetVertexColor(gc[1], gc[2], gc[3], 1)
    win.title:SetTextColor(ns.TooltipTextColor())
    win.title:SetShadowColor(0, 0, 0, light and 0 or 1)
end

local function SettingsTip()
    return _G["SETTINGS"] or "Settings"
end

local function TilesClick()
    UI.tilesOpen = not UI.tilesOpen
    Window.Refresh()
end

function Window.CloseTiles()
    UI.tilesOpen = false
end

local function EnsureWindow()
    if UI.win then return UI.win end
    local win = CreateFrame("Frame", "EasyFindClockWindow", UIParent, "BackdropTemplate")
    UI.win = win
    win:Hide()
    win:SetSize(W, HEADER_H + 120)
    win:SetFrameStrata("HIGH")
    win:SetClampedToScreen(true)
    win:EnableMouse(true)
    win:SetMovable(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", CL.WindowDragStart)
    win:SetScript("OnDragStop", CL.WindowDragStop)
    win:HookScript("OnHide", function(self)
        self:UnregisterEvent("PLAYER_REGEN_DISABLED")
        CL.Tiles.CloseEntries()
        CL.AlarmList.CloseEditor()
    end)
    -- A pull takes the keyboard back from a typed box.
    win:HookScript("OnShow", function(self) self:RegisterEvent("PLAYER_REGEN_DISABLED") end)
    win:SetScript("OnEvent", function()
        CL.Tiles.CloseEntries()
        CL.AlarmList.DropFocus()
    end)
    ns.StyleMenuPanel(win)
    local pos = Runs.sv.hud
    if type(pos.left) == "number" and type(pos.top) == "number" then
        win:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.left, pos.top)
    else
        win:SetPoint("CENTER", UIParent, "CENTER", 300, 160)
    end

    win.glyph = win:CreateTexture(nil, "ARTWORK")
    win.glyph:SetSize(16, 16)
    win.glyph:SetPoint("TOPLEFT", win, "TOPLEFT", PAD + 2, -8)
    win.glyph:SetTexture(ns.CLOCK_ICON_TEX)
    win.title = CL.Text(win, "GameFontNormal")
    win.title:SetPoint("LEFT", win.glyph, "RIGHT", 6, 0)
    win.title:SetText(ns.CLOCK_NAME)

    -- Header, right to left: minimize, settings, more runs.
    win.minimize = CL.CreateGlyphButton(win, "dash")
    win.minimize:SetPoint("TOPRIGHT", win, "TOPRIGHT", -PAD, -8)
    win.minimize:SetScript("OnClick", function() CL.Minimize() end)
    win.minimize.tip = L["CLOCK_MINIMIZE_TT"]
    win.cog = ns.CreateCogButton(win)
    win.cog:SetPoint("RIGHT", win.minimize, "LEFT", -4, 0)
    win.cog:SetScript("OnClick", function() CL.OpenSettings() end)
    Utils.AttachDelayedTooltip(win.cog, "ANCHOR_TOP", SettingsTip)
    win.plus = CL.CreateGlyphButton(win, "plus")
    win.plus:SetPoint("RIGHT", win.cog, "LEFT", -4, 0)
    win.plus:SetScript("OnClick", TilesClick)
    win.plus.tip = L["CLOCK_TILES_TT"]

    CL.Tiles.Create(win)
    CL.Painted(win, PaintWindow)
    return win
end

function Window.Refresh()
    local win = UI.win
    if not win then return end
    local now = time()
    local runs = Runs:List()
    local cards = UI.cards
    local y = -HEADER_H
    for i = 1, #runs do
        local card = cards[i] or CreateCard()
        cards[i] = card
        FillCard(card, runs[i], now)
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", win, "TOPLEFT", PAD, y)
        card:SetPoint("TOPRIGHT", win, "TOPRIGHT", -PAD, y)
        card:Show()
        y = y - card:GetHeight() - GAP
    end
    for i = #runs + 1, #cards do
        cards[i]:Hide()
        cards[i].run = nil
    end
    y = CL.AlarmList.Layout(win, y, now)
    win.plus:SetShown(#runs > 0)
    y = CL.Tiles.Layout(win, y, #runs == 0 or UI.tilesOpen)
    win:SetHeight(-y + PAD - GAP)
end

function Window.UpdateTimes(now)
    if not Window.IsShown() then return end
    local cards = UI.cards
    for i = 1, #cards do
        if cards[i].run and cards[i]:IsShown() then TickCard(cards[i], now) end
    end
    CL.AlarmList.UpdateTimes(now)
end

function Window.Show()
    EnsureWindow():Show()
    Window.Refresh()
end

function Window.Hide()
    if UI.win then UI.win:Hide() end
end

function Window.IsShown()
    return UI.win ~= nil and UI.win:IsShown()
end

function Window.Pulse(run)
    if not Window.IsShown() then return end
    local cards = UI.cards
    for i = 1, #cards do
        if cards[i].run == run then
            cards[i].pulse:Stop()
            cards[i].pulse:Play()
            return
        end
    end
end
