local _, CL = ...
local ns = EasyFind and EasyFind._ns
if not (ns and ns.ClockRuns and ns.ClockGrammar) then return end

-- The pieces the window and the strip are built from: colors, the digits
-- font, the draining ring, round buttons, chips and the run labels.
local Utils = ns.Utils
local L = ns.L
local Runs, Grammar = ns.ClockRuns, ns.ClockGrammar
local Format = Grammar.FormatDuration

local CreateFrame, GetTime = CreateFrame, GetTime
local pairs, setmetatable = Utils.pairs, setmetatable
local sformat, mfloor, mceil = Utils.sformat, Utils.mfloor, Utils.mceil

CL.Runs, CL.Grammar, CL.Format = Runs, Grammar, Format

local TEX = "Interface\\AddOns\\EasyFind\\textures\\"
CL.TEX = {
    ring = TEX .. "clock-ring", ringSmall = TEX .. "clock-ring-small", dot = TEX .. "clock-dot",
    play = TEX .. "clock-play", pause = TEX .. "clock-pause", stop = TEX .. "clock-stop", skip = TEX .. "clock-skip",
    flat = "Interface\\Buttons\\WHITE8x8",
}

-- Kind colors: rings, glyphs and the pomodoro's phase pill.
CL.GOLD = ns.GOLD_COLOR
CL.ALARM_COLOR = { 0.44, 0.66, 1.0 }
CL.FOCUS_COLOR = { 0.89, 0.34, 0.30 }
CL.BREAK_COLOR = { 0.37, 0.75, 0.44 }
CL.ROUNDS = 4

CL.TOOL_NAMES = {
    pomodoro = L["CLOCK_POMODORO"],
    timer = L["CLOCK_TIMER"],
    stopwatch = _G["STOPWATCH_TITLE"] or "Stopwatch",
    alarm = L["CLOCK_ALARM"],
}

-- Frames with a painter, repainted when the theme changes.
local painted = setmetatable({}, { __mode = "k" })

function CL.Painted(frame, paint)
    painted[frame] = paint
    paint(frame)
end

function CL.RepaintAll()
    for frame, paint in pairs(painted) do paint(frame) end
end

function CL.Palette()
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    local light = theme and theme.lightTheme
    local body = light and theme.leafColor or ns.TEXT_PRIMARY
    local faint = light and (theme.textFaint or theme.leafColor) or ns.TEXT_DIM
    return body, faint, light
end

-- A surface stepped from the window fill toward the text; 0 is the window.
function CL.Surface(k)
    local pal = ns.ACTIVE_UI_PALETTE
    local r, g, b
    if pal and pal.windowFill then
        r, g, b = ns.ThemeSwatchColor(pal)
    else
        local c = ns.SEARCH_WINDOW_FILL_COLOR
        r, g, b = c[1], c[2], c[3]
    end
    local body = CL.Palette()
    return r + (body[1] - r) * k, g + (body[2] - g) * k, b + (body[3] - b) * k
end

function CL.KindColor(run)
    if run.tool == "alarm" then return CL.ALARM_COLOR end
    if run.tool == "pomodoro" then return run.phase == "break" and CL.BREAK_COLOR or CL.FOCUS_COLOR end
    return CL.GOLD
end

-- Text the clock colors itself, in the font chosen for EasyFind; the menu
-- panel's text pass leaves its color alone.
function CL.Text(parent, template, size)
    local fs = parent:CreateFontString(nil, "OVERLAY", template)
    fs._efOwnColor = true
    if size then
        local path, _, flags = fs:GetFont()
        if path then fs:SetFont(path, size, flags or "") end
    end
    ns.RegisterAddonFont(fs)
    return fs
end

-- Times in the game's own stopwatch face.
function CL.DigitsText(parent, size)
    local fs = CL.Text(parent, "GameFontHighlightLarge", size)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

function CL.TextWidth(fs)
    return mceil(fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth() or 0)
end

-- Rings

function CL.CreateRing(parent, size, small)
    local tex = small and CL.TEX.ringSmall or CL.TEX.ring
    local ring = CreateFrame("Frame", nil, parent)
    ring:SetSize(size, size)
    ring.track = ring:CreateTexture(nil, "BACKGROUND")
    ring.track:SetAllPoints()
    ring.track:SetTexture(tex)
    ring.cd = CreateFrame("Cooldown", nil, ring)
    ring.cd:SetAllPoints()
    ring.cd:SetSwipeTexture(tex)
    ring.cd:SetDrawEdge(false)
    ring.cd:SetDrawBling(false)
    ring.cd:SetHideCountdownNumbers(true)
    -- Cooldown text addons leave a cooldown flagged like this alone.
    ring.cd.noCooldownCount = true
    ring.top = CreateFrame("Frame", nil, ring)
    ring.top:SetAllPoints()
    ring.top:SetFrameLevel(ring.cd:GetFrameLevel() + 1)
    ring.glyph = ring.top:CreateTexture(nil, "OVERLAY")
    ring.glyph:SetSize(mfloor(size * 0.5), mfloor(size * 0.5))
    ring.glyph:SetPoint("CENTER")
    return ring
end

-- What a ring drains over and how much of it is gone; nil when nothing drains.
local function RingSpan(run, now)
    local tool = run.tool
    if tool == "timer" then return run.duration, Runs.Elapsed(run, now) end
    if tool == "alarm" then return run.at - run.startedAt, now - run.startedAt end
    if tool == "pomodoro" then
        local len = Runs.PhaseLen(run)
        return len, len - Runs.PhaseLeft(run, now)
    end
    if run.mark and not run.markHit then return run.mark, Runs.Elapsed(run, now) end
    return nil
end

-- A stopwatch fills toward its mark; the rest drain. An ended run, or a
-- stopwatch past its mark, wears the whole ring.
function CL.SetRing(ring, run, now)
    local c = CL.KindColor(run)
    ring.glyph:SetTexture(ns.CLOCK_TOOL_ICONS[run.tool])
    ring.glyph:SetVertexColor(c[1], c[2], c[3], 1)
    local duration, gone = RingSpan(run, now)
    local full = run.done or run.markHit
    if full or not duration or duration <= 0 then
        ring.cd:Clear()
        ring.held = nil
        if full then
            ring.track:SetVertexColor(c[1], c[2], c[3], 1)
            return
        end
    else
        ring.cd:SetSwipeColor(c[1], c[2], c[3], 1)
        ring.cd:SetReverse(run.tool == "stopwatch")
        ring.cd:SetCooldown(GetTime() - gone, duration)
        ring.held = run.pausedAt ~= nil
    end
    local r, g, b = CL.Surface(0.16)
    ring.track:SetVertexColor(r, g, b, 1)
end

-- A paused run's ring is set again every tick so it stands still.
function CL.HoldRing(ring, run, now)
    if ring.held then CL.SetRing(ring, run, now) end
end

-- Buttons

local function PaintButton(btn)
    local k = btn.down and 0.10 or (btn.hover and 0.26 or 0.15)
    local r, g, b = CL.Surface(k)
    ns.SetRoundedRectFill(btn, r, g, b, 1, true)
    local body = CL.Palette()
    if btn.icon then btn.icon:SetVertexColor(body[1], body[2], body[3], 1) end
    if btn.text then btn.text:SetTextColor(body[1], body[2], body[3], 1) end
end

local function ButtonEnter(self)
    self.hover = true
    PaintButton(self)
end

local function ButtonLeave(self)
    self.hover, self.down = nil, nil
    PaintButton(self)
end

local function ButtonDown(self)
    self.down = true
    PaintButton(self)
end

local function ButtonUp(self)
    self.down = nil
    PaintButton(self)
end

local function ButtonTip(self)
    return self.tip
end

local function MakeRounded(btn, h)
    ns.CreateRoundedRectBorder(btn)
    ns.SetRoundedRectBarHeight(btn, h)
    ns.SetRoundedRectBorderEdgeShown(btn, false)
    btn:SetScript("OnEnter", ButtonEnter)
    btn:SetScript("OnLeave", ButtonLeave)
    btn:SetScript("OnMouseDown", ButtonDown)
    btn:SetScript("OnMouseUp", ButtonUp)
    Utils.AttachDelayedTooltip(btn, "ANCHOR_TOP", ButtonTip)
    CL.Painted(btn, PaintButton)
end

-- A round button with a glyph; `tip` is its tooltip.
function CL.CreateRoundButton(parent, size, tex)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(size, size)
    btn.icon = btn:CreateTexture(nil, "OVERLAY")
    btn.icon:SetSize(mfloor(size * 0.5), mfloor(size * 0.5))
    btn.icon:SetPoint("CENTER")
    if tex then btn.icon:SetTexture(tex) end
    MakeRounded(btn, size)
    return btn
end

local function SetChipLabel(chip, text)
    chip.text:SetText(text)
    chip:SetWidth(CL.TextWidth(chip.text) + 14)
end

-- A pill with a word on it, as wide as the word.
function CL.CreateChip(parent, height)
    local chip = CreateFrame("Button", nil, parent)
    chip:SetHeight(height)
    chip.text = CL.Text(chip, "GameFontHighlightSmall")
    chip.text:SetPoint("CENTER")
    chip.SetLabel = SetChipLabel
    MakeRounded(chip, height)
    return chip
end

local function PaintGlyphButton(btn)
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    local c = btn.hover and (theme and theme.leafColor or { 1, 1, 1 }) or (theme and theme.textFaint or ns.TEXT_DIM)
    for i = 1, #btn.strokes do btn.strokes[i]:SetVertexColor(c[1], c[2], c[3], 1) end
end

local function GlyphEnter(self)
    self.hover = true
    PaintGlyphButton(self)
end

local function GlyphLeave(self)
    self.hover = nil
    PaintGlyphButton(self)
end

local function Stroke(btn, w, h)
    local t = btn:CreateTexture(nil, "OVERLAY")
    t:SetTexture(CL.TEX.flat)
    t:SetSize(w, h)
    t:SetPoint("CENTER")
    btn.strokes[#btn.strokes + 1] = t
end

-- A flat header glyph like the close X: "plus" or "dash".
function CL.CreateGlyphButton(parent, kind)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(16, 16)
    btn.strokes = {}
    Stroke(btn, 11, 1.5)
    if kind == "plus" then Stroke(btn, 1.5, 11) end
    btn:SetScript("OnEnter", GlyphEnter)
    btn:SetScript("OnLeave", GlyphLeave)
    Utils.AttachDelayedTooltip(btn, "ANCHOR_TOP", ButtonTip)
    CL.Painted(btn, PaintGlyphButton)
    return btn
end

-- Labels

function CL.Words(sec)
    if sec >= 3600 and sec % 3600 == 0 then return sformat(L["CLOCK_HOUR_FMT"], mfloor(sec / 3600)) end
    if sec % 60 == 0 then return sformat(L["CLOCK_MIN_FMT"], mfloor(sec / 60)) end
    return Format(sec)
end

-- A run's name in menus, tooltips and signals.
function CL.RunLabel(run)
    local tool = run.tool
    local name = CL.TOOL_NAMES[tool]
    if tool == "timer" then return name .. " " .. Format(run.duration) end
    if tool == "alarm" then return name .. " " .. Grammar.TimeLabel(run.at) end
    if tool == "stopwatch" then return run.mark and (name .. " " .. Format(run.mark)) or name end
    local n = (run.intervals or 0) + (run.phase == "focus" and 1 or 0)
    return sformat(run.phase == "break" and L["CLOCK_BREAK_N"] or L["CLOCK_FOCUS_N"], n)
end

-- The big time on a card or a strip segment.
function CL.TimeString(run, now)
    if run.tool == "alarm" then return Grammar.TimeLabel(run.at) end
    return Format(Runs.Shown(run, now))
end

-- The line under a card's time.
function CL.CardLabel(run, now)
    local tool = run.tool
    local text
    if tool == "timer" then
        text = sformat(L["CLOCK_CARD_TIMER"], CL.Words(run.duration))
        if run.done then return sformat(L["CLOCK_CARD_ENDED"], text) end
    elseif tool == "alarm" then
        if run.done then return sformat(L["CLOCK_CARD_ENDED"], CL.TOOL_NAMES.alarm) end
        return sformat(L["CLOCK_CARD_ALARM"], Format(run.at - now))
    elseif tool == "stopwatch" then
        if run.mark then
            text = sformat(run.markHit and L["CLOCK_CARD_PASSED"] or L["CLOCK_CARD_MARK"], Format(run.mark))
        else
            text = CL.TOOL_NAMES.stopwatch
        end
    else
        text = sformat(L["CLOCK_CARD_POMODORO"], CL.RunLabel(run))
    end
    if run.pausedAt then return sformat(L["CLOCK_CARD_PAUSED"], text) end
    return text
end

-- The pomodoro round shown as lit dots, 1 to ROUNDS.
function CL.RoundInSet(run)
    local round = (run.intervals or 0) + (run.phase == "focus" and 1 or 0)
    if round < 1 then round = 1 end
    return (round - 1) % CL.ROUNDS + 1
end
