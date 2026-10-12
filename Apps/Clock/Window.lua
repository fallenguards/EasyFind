local _, CL = ...
local ns = EasyFind and EasyFind._ns
if not (ns and ns.ClockRuns and ns.ClockGrammar) then return end

-- The window: one card per run, and the start tiles when nothing runs
-- (or when the header's + asks for them).
local Utils = ns.Utils
local L = ns.L
local Runs, Grammar = ns.ClockRuns, ns.ClockGrammar

local CreateFrame, UIParent = CreateFrame, UIParent
local time, tostring = time, tostring
local mmax = Utils.mmax

local Window = {}
CL.Window = Window

local W, PAD, HEADER_H, GAP = 272, 8, 30, 6
local CARD_H, ENDED_H, RING, BTN, BTN_GAP = 56, 84, 40, 24, 5
local CHIP_H, TILE_GAP = 18, 8
local PLUS_SECONDS = 300
local PAUSED_ALPHA = 0.55
local TIMER_CHIPS = { 1, 5, 10, 15, 30 }
local POMODORO_CHIPS = { { 25, 5 }, { 50, 10 } }

local UI = { cards = {} }

local function DragStart()
    UI.win:StartMoving()
end

-- The place is read before the stop, which can leave the frame unanchored.
local function DragStop()
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

-- Cards

local function CardRun(btn)
    return btn:GetParent().run
end

local function PauseClick(self)
    Runs:TogglePause(CardRun(self), time())
    CL.Changed()
end

local function StopClick(self)
    Runs:Cancel(CardRun(self))
    CL.Changed()
end

local function SkipClick(self)
    CL.Skip(CardRun(self))
end

local function PlusClick(self)
    Runs:Extend(CardRun(self), time(), PLUS_SECONDS)
    CL.Changed()
end

local function AgainClick(self)
    CL.Again(CardRun(self))
end

local function CardClick(self, button)
    if button == "RightButton" and self.run then CL.ShowRunMenu(self.run, self) end
end

local function PaintPill(card)
    local run = card.run
    if not (run and run.tool == "pomodoro") then return end
    local c = CL.KindColor(run)
    local _, _, light = CL.Palette()
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
end

-- An ended run wears a gold outline and a gold time.
local function PaintCard(card)
    local r, g, b = CL.Surface(0.07)
    ns.SetRoundedRectFill(card, r, g, b, 1, true)
    local ended = card.run and card.run.done
    ns.SetRoundedRectBorderEdgeShown(card, ended and true or false)
    if ended then ns.SetRoundedRectBorderColor(card, CL.GOLD[1], CL.GOLD[2], CL.GOLD[3], 0.75, true) end
    local body, faint, light = CL.Palette()
    local c = ended and CL.GOLD or body
    card.time:SetTextColor(c[1], c[2], c[3], 1)
    card.label:SetTextColor(faint[1], faint[2], faint[3], 1)
    local shadow = light and 0 or 1
    card.time:SetShadowColor(0, 0, 0, shadow)
    card.label:SetShadowColor(0, 0, 0, shadow)
    ns.SetRoundedRectFill(card.glow, CL.GOLD[1], CL.GOLD[2], CL.GOLD[3], 0.18, true)
    PaintPill(card)
end

local function CreateCard()
    local card = CreateFrame("Button", nil, UI.win)
    card:SetHeight(CARD_H)
    card:RegisterForClicks("RightButtonUp")
    card:RegisterForDrag("LeftButton")
    card:SetScript("OnDragStart", DragStart)
    card:SetScript("OnDragStop", DragStop)
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

    -- A pomodoro's phase and its round in the set.
    card.pill = CreateFrame("Frame", nil, card)
    card.pill:SetHeight(14)
    card.pill:SetPoint("TOPLEFT", card.time, "BOTTOMLEFT", 0, -4)
    ns.CreateRoundedRectBorder(card.pill)
    ns.SetRoundedRectBarHeight(card.pill, 14)
    ns.SetRoundedRectBorderEdgeShown(card.pill, false)
    card.pill.text = CL.Text(card.pill, "GameFontHighlightSmall")
    card.pill.text:SetPoint("CENTER")
    card.dots = {}
    for i = 1, CL.ROUNDS do
        local dot = card:CreateTexture(nil, "ARTWORK")
        dot:SetTexture(CL.TEX.dot)
        dot:SetSize(6, 6)
        dot:SetPoint("LEFT", card.pill, "RIGHT", 6 + (i - 1) * 9, 0)
        card.dots[i] = dot
    end

    -- Controls, right to left.
    card.stop = CL.CreateRoundButton(card, BTN, CL.TEX.stop)
    card.stop:SetPoint("RIGHT", card, "TOPRIGHT", -8, -(8 + RING / 2))
    card.stop:SetScript("OnClick", StopClick)
    card.stop.tip = L["CLOCK_STOP"]
    card.pause = CL.CreateRoundButton(card, BTN)
    card.pause:SetPoint("RIGHT", card.stop, "LEFT", -BTN_GAP, 0)
    card.pause:SetScript("OnClick", PauseClick)
    card.skip = CL.CreateRoundButton(card, BTN, CL.TEX.skip)
    card.skip:SetPoint("RIGHT", card.pause, "LEFT", -BTN_GAP, 0)
    card.skip:SetScript("OnClick", SkipClick)

    -- An ended run's choices, under the time.
    card.dismiss = CL.CreateChip(card, CHIP_H)
    card.dismiss:SetLabel(L["CLOCK_DISMISS"])
    card.dismiss:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -8, 8)
    card.dismiss:SetScript("OnClick", StopClick)
    card.again = CL.CreateChip(card, CHIP_H)
    card.again:SetLabel(L["CLOCK_AGAIN"])
    card.again:SetPoint("RIGHT", card.dismiss, "LEFT", -5, 0)
    card.again:SetScript("OnClick", AgainClick)
    card.more = CL.CreateChip(card, CHIP_H)
    card.more:SetLabel(L["CLOCK_PLUS5"])
    card.more:SetPoint("RIGHT", card.again, "LEFT", -5, 0)
    card.more:SetScript("OnClick", PlusClick)

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

local function FillCard(card, run, now)
    card.run = run
    local tool = run.tool
    local running = not run.done
    card:SetHeight(running and CARD_H or ENDED_H)
    CL.SetRing(card.ring, run, now)
    card.shownTime, card.shownLabel = nil, nil

    local pom = running and tool == "pomodoro"
    card.pill:SetShown(pom)
    for i = 1, #card.dots do card.dots[i]:SetShown(pom) end
    card.label:SetShown(not pom)
    if pom then
        card.pill.text:SetText(run.phase == "break" and L["CLOCK_BREAK"] or L["CLOCK_FOCUS"])
        card.pill:SetWidth(CL.TextWidth(card.pill.text) + 12)
        card.lit = CL.RoundInSet(run)
        card.skip.tip = run.phase == "focus" and L["CLOCK_SKIP_BREAK"] or L["CLOCK_SKIP_FOCUS"]
    end

    local pausable = running and tool ~= "alarm"
    card.stop:SetShown(running)
    card.pause:SetShown(pausable)
    card.skip:SetShown(pom)
    card.more:SetShown(not running)
    card.again:SetShown(not running)
    card.dismiss:SetShown(not running)
    if pausable then
        card.pause.icon:SetTexture(run.pausedAt and CL.TEX.play or CL.TEX.pause)
        card.pause.tip = run.pausedAt and L["CLOCK_RESUME"] or L["CLOCK_PAUSE"]
    end

    -- The label ends where the controls start.
    local n = not running and 0 or (pom and 3 or (pausable and 2 or 1))
    card.label:ClearAllPoints()
    card.label:SetPoint("TOPLEFT", card.time, "BOTTOMLEFT", 0, -4)
    card.label:SetPoint("RIGHT", card, "RIGHT", -(8 + n * BTN + mmax(0, n - 1) * BTN_GAP + 6), 0)
    card.time:SetAlpha(run.pausedAt and PAUSED_ALPHA or 1)
    PaintCard(card)
    TickCard(card, now)
end

-- Tiles

local function PaintHint()
    local hint = UI.hint
    if not hint then return end
    local _, faint, light = CL.Palette()
    local c = UI.badEntry and CL.FOCUS_COLOR or faint
    hint:SetTextColor(c[1], c[2], c[3], 1)
    hint:SetShadowColor(0, 0, 0, light and 0 or 1)
end

local function SetHint(text, bad)
    UI.badEntry = bad
    UI.hint:SetText(text)
    PaintHint()
end

local function PaintTile(tile)
    local r, g, b = CL.Surface(0.07)
    ns.SetRoundedRectFill(tile, r, g, b, 1, true)
    local body, faint, light = CL.Palette()
    tile.title:SetTextColor(body[1], body[2], body[3], 1)
    tile.title:SetShadowColor(0, 0, 0, light and 0 or 1)
    tile.glyph:SetVertexColor(tile.color[1], tile.color[2], tile.color[3], 1)
    if tile.unit then tile.unit.text:SetTextColor(faint[1], faint[2], faint[3], 1) end
end

local function CreateTile(parent, tool, color)
    local tile = CreateFrame("Frame", nil, parent)
    ns.CreateRoundedRectBorder(tile)
    ns.SetRoundedRectBarHeight(tile, 18)
    ns.SetRoundedRectBorderEdgeShown(tile, false)
    tile.glyph = tile:CreateTexture(nil, "ARTWORK")
    tile.glyph:SetSize(14, 14)
    tile.glyph:SetPoint("TOPLEFT", tile, "TOPLEFT", 8, -8)
    tile.glyph:SetTexture(ns.CLOCK_TOOL_ICONS[tool])
    tile.title = CL.Text(tile, "GameFontHighlight")
    tile.title:SetPoint("LEFT", tile.glyph, "RIGHT", 6, 0)
    tile.title:SetText(CL.TOOL_NAMES[tool])
    tile.color = color
    tile.items = {}
    CL.Painted(tile, PaintTile)
    return tile
end

local function AddChip(tile, label, onClick, a, b)
    local chip = CL.CreateChip(tile, CHIP_H)
    chip:SetLabel(label)
    chip.a, chip.b = a, b
    chip:SetScript("OnClick", onClick)
    tile.items[#tile.items + 1] = chip
    return chip
end

-- The plain word after the timer chips.
local function AddUnit(tile, text)
    local unit = CreateFrame("Frame", nil, tile)
    unit:SetHeight(CHIP_H)
    unit.text = CL.Text(unit, "GameFontHighlightSmall")
    unit.text:SetPoint("LEFT", unit, "LEFT", 2, 0)
    unit.text:SetText(text)
    unit:SetWidth(CL.TextWidth(unit.text) + 4)
    tile.unit = unit
    tile.items[#tile.items + 1] = unit
end

-- Chips in rows, wrapping at the tile's edge; returns the tile's height.
local function FlowTile(tile, width)
    local x, y = 8, -28
    for i = 1, #tile.items do
        local item = tile.items[i]
        local w = item:GetWidth()
        if x > 8 and x + w > width - 8 then
            x, y = 8, y - CHIP_H - 4
        end
        item:ClearAllPoints()
        item:SetPoint("TOPLEFT", tile, "TOPLEFT", x, y)
        x = x + w + 4
    end
    return -y + CHIP_H + 8
end

local function StartFromTile(tool, a, b)
    UI.tilesOpen = false
    CL.StartRun(tool, a, b)
end

local function TimerChip(self)
    StartFromTile("timer", self.a * 60)
end

local function PomodoroChip(self)
    StartFromTile("pomodoro", self.a * 60, self.b * 60)
end

local function StopwatchChip()
    StartFromTile("stopwatch")
end

-- The alarm tile's time entry

local function CloseEntry()
    local box = UI.entry
    if not (box and box:IsShown()) then return end
    box:Hide()
    UI.setTime:Show()
    SetHint(L["CLOCK_TILES_HINT"], false)
end

local function EntryEnter(box)
    local cmd = Grammar.Parse("alarm " .. (box:GetText() or ""))
    if cmd and Grammar.Resolve(cmd, time()) then
        box:ClearFocus()
        StartFromTile("alarm", cmd.at)
        return
    end
    SetHint(L["CLOCK_ALARM_BAD"], true)
end

local function EntryChanged(box)
    box.placeholder:SetShown((box:GetText() or "") == "")
    if UI.badEntry then SetHint(L["CLOCK_TILES_HINT"], false) end
end

local function PaintEntry(box)
    local r, g, b = CL.Surface(0.0)
    ns.SetRoundedRectFill(box, r, g, b, 1, true)
    local body, faint = CL.Palette()
    box:SetTextColor(body[1], body[2], body[3], 1)
    box.placeholder:SetTextColor(faint[1], faint[2], faint[3], 1)
end

local function EnsureEntry()
    if UI.entry then return UI.entry end
    local tile = UI.setTime:GetParent()
    local box = CreateFrame("EditBox", nil, tile)
    box:Hide()
    box:SetAutoFocus(false)
    box:SetSize(92, CHIP_H)
    box:SetPoint("TOPLEFT", UI.setTime, "TOPLEFT", 0, 0)
    box:SetFontObject(_G["GameFontHighlightSmall"] or _G["GameFontNormal"])
    box:SetTextInsets(7, 7, 0, 0)
    box:SetMaxLetters(12)
    ns.CreateRoundedRectBorder(box)
    ns.SetRoundedRectBarHeight(box, CHIP_H)
    ns.SetRoundedRectBorderEdgeShown(box, false)
    box.placeholder = CL.Text(box, "GameFontHighlightSmall")
    box.placeholder:SetPoint("LEFT", box, "LEFT", 7, 0)
    box.placeholder:SetText(GameTime_GetFormattedTime and GameTime_GetFormattedTime(19, 30, true) or "19:30")
    box:SetScript("OnEnterPressed", EntryEnter)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    box:SetScript("OnEditFocusLost", CloseEntry)
    box:SetScript("OnTextChanged", EntryChanged)
    UI.entry = box
    CL.Painted(box, PaintEntry)
    return box
end

local function AlarmChip()
    local box = EnsureEntry()
    UI.setTime:Hide()
    box:SetText("")
    box:Show()
    -- A box opened from a press takes focus a frame later.
    Utils.SafeAfter(0, function()
        if box:IsVisible() then box:SetFocus() end
    end)
end

local function CreateTiles(win)
    local tiles = CreateFrame("Frame", nil, win)
    local tw = (W - 2 * PAD - TILE_GAP) / 2
    tiles:SetWidth(W - 2 * PAD)
    local timer = CreateTile(tiles, "timer", CL.GOLD)
    for i = 1, #TIMER_CHIPS do AddChip(timer, tostring(TIMER_CHIPS[i]), TimerChip, TIMER_CHIPS[i]) end
    AddUnit(timer, L["CLOCK_MIN"])
    local pom = CreateTile(tiles, "pomodoro", CL.FOCUS_COLOR)
    for i = 1, #POMODORO_CHIPS do
        local p = POMODORO_CHIPS[i]
        AddChip(pom, p[1] .. " / " .. p[2], PomodoroChip, p[1], p[2])
    end
    local sw = CreateTile(tiles, "stopwatch", CL.GOLD)
    AddChip(sw, _G["START"] or "Start", StopwatchChip)
    local alarm = CreateTile(tiles, "alarm", CL.ALARM_COLOR)
    UI.setTime = AddChip(alarm, L["CLOCK_SET_TIME"], AlarmChip)
    -- Two by two, each row as tall as its taller tile.
    local h1 = mmax(FlowTile(timer, tw), FlowTile(pom, tw))
    local h2 = mmax(FlowTile(sw, tw), FlowTile(alarm, tw))
    local cells = { { timer, 0, 0, h1 }, { pom, tw + TILE_GAP, 0, h1 },
        { sw, 0, -(h1 + TILE_GAP), h2 }, { alarm, tw + TILE_GAP, -(h1 + TILE_GAP), h2 } }
    for i = 1, #cells do
        local c = cells[i]
        c[1]:SetSize(tw, c[4])
        c[1]:SetPoint("TOPLEFT", tiles, "TOPLEFT", c[2], c[3])
    end
    tiles:SetHeight(h1 + TILE_GAP + h2)
    UI.tiles = tiles
end

-- The window

local function PaintWindow(win)
    local _, _, light = CL.Palette()
    local gc = ns.ChromeGlyphColor()
    win.glyph:SetVertexColor(gc[1], gc[2], gc[3], 1)
    win.title:SetTextColor(ns.TooltipTextColor())
    win.title:SetShadowColor(0, 0, 0, light and 0 or 1)
    PaintHint()
end

local function SettingsTip()
    return _G["SETTINGS"] or "Settings"
end

local function TilesClick()
    UI.tilesOpen = not UI.tilesOpen
    Window.Refresh()
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
    win:SetScript("OnDragStart", DragStart)
    win:SetScript("OnDragStop", DragStop)
    win:HookScript("OnHide", function()
        if UI.entry then UI.entry:ClearFocus() end
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

    CreateTiles(win)
    UI.hint = CL.Text(win, "GameFontHighlightSmall")
    UI.hint:SetWidth(W - 2 * PAD - 4)
    UI.hint:SetJustifyH("LEFT")
    UI.hint:SetText(L["CLOCK_TILES_HINT"])
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
    win.plus:SetShown(#runs > 0)
    local tiles = #runs == 0 or UI.tilesOpen
    UI.tiles:SetShown(tiles)
    UI.hint:SetShown(tiles)
    if tiles then
        UI.tiles:ClearAllPoints()
        UI.tiles:SetPoint("TOPLEFT", win, "TOPLEFT", PAD, y)
        y = y - UI.tiles:GetHeight() - 8
        UI.hint:ClearAllPoints()
        UI.hint:SetPoint("TOPLEFT", win, "TOPLEFT", PAD + 2, y)
        y = y - UI.hint:GetStringHeight()
    else
        y = y + GAP
        CloseEntry()
    end
    win:SetHeight(-y + PAD)
end

function Window.UpdateTimes(now)
    if not Window.IsShown() then return end
    local cards = UI.cards
    for i = 1, #cards do
        if cards[i].run and cards[i]:IsShown() then TickCard(cards[i], now) end
    end
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
