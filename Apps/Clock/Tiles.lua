local _, CL = ...
local ns = EasyFind and EasyFind._ns
if not (ns and ns.ClockRuns and ns.ClockGrammar) then return end

-- The start tiles: timer presets and recent lengths, pomodoro lengths and
-- today's rounds, a stopwatch start and the alarm's time entry.
local Utils = ns.Utils
local L = ns.L
local Runs, Grammar = ns.ClockRuns, ns.ClockGrammar

local CreateFrame, InCombatLockdown = CreateFrame, InCombatLockdown
local time, strtrim = time, strtrim
local mmax, mmin, pairs, sformat = Utils.mmax, Utils.mmin, Utils.pairs, Utils.sformat

local Tiles = {}
CL.Tiles = Tiles

local CHIP_H, TILE_GAP, ENTRY_W = 18, 8, 92
local POMODORO_CHIPS = { { 25, 5 }, { 50, 10 } }

local UI = { entries = {}, pool = {} }

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
    tile.note:SetTextColor(faint[1], faint[2], faint[3], 1)
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
    tile.note = CL.Text(tile, "GameFontHighlightSmall")
    tile.note:SetPoint("TOPRIGHT", tile, "TOPRIGHT", -8, -10)
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
local function CreateUnit(tile, text)
    local unit = CreateFrame("Frame", nil, tile)
    unit:SetHeight(CHIP_H)
    unit.text = CL.Text(unit, "GameFontHighlightSmall")
    unit.text:SetPoint("LEFT", unit, "LEFT", 2, 0)
    unit.text:SetText(text)
    unit:SetWidth(CL.TextWidth(unit.text) + 4)
    tile.unit = unit
    return unit
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
        item:Show()
        x = x + w + 4
    end
    return -y + CHIP_H + 8
end

local function StartFromTile(tool, a, b, name)
    CL.Window.CloseTiles()
    CL.StartRun(tool, a, b, name)
end

local function TimerChip(self, button)
    if button == "RightButton" then
        local seconds = self.a
        if self.recent then
            CL.ShowMenu({ { text = L["CLOCK_SAVE_PRESET"], onClick = function() CL.SavePreset(seconds) end } }, self)
        else
            CL.ShowMenu({ { text = L["CLOCK_REMOVE_PRESET"], onClick = function() CL.RemovePreset(seconds) end } }, self)
        end
        return
    end
    StartFromTile("timer", self.a)
end

local function PomodoroChip(self)
    StartFromTile("pomodoro", self.a * 60, self.b * 60)
end

local function StopwatchChip()
    StartFromTile("stopwatch")
end

-- A tile's typed entry: its chip gives way to a box read as the search bar
-- reads "timer 45 tea", "pom 40 10" or "alarm 7:30pm raid daily".

local ENTRY_VERB = { timer = "timer", pomodoro = "pom", alarm = "alarm" }
local ENTRY_BAD = { timer = "CLOCK_TIMER_BAD", pomodoro = "CLOCK_POMODORO_BAD", alarm = "CLOCK_ALARM_BAD" }

local function CloseEntry(box)
    if not (box and box:IsShown()) then return end
    box:Hide()
    box.chip:Show()
    SetHint(L["CLOCK_TILES_HINT"], false)
end

function Tiles.CloseEntries()
    for _, box in pairs(UI.entries) do CloseEntry(box) end
end

local function EntryEnter(box)
    local text = strtrim(box:GetText() or "")
    local cmd = text ~= "" and Grammar.Parse(ENTRY_VERB[box.tool] .. " " .. text)
    if cmd and cmd.tool == box.tool and Grammar.Resolve(cmd, time()) then
        box:ClearFocus()
        CL.Window.CloseTiles()
        if box.tool == "alarm" then
            CL.AddAlarm(cmd)
        else
            CL.StartRun(box.tool, cmd.seconds, cmd.seconds2, cmd.name)
        end
        return
    end
    SetHint(L[ENTRY_BAD[box.tool]], true)
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

-- A typed box styled like a chip; the alarm editor uses it too.
function CL.CreateEntry(parent, placeholder, maxLetters)
    local box = CreateFrame("EditBox", nil, parent)
    box:Hide()
    box:SetAutoFocus(false)
    box:SetHeight(CHIP_H)
    box:SetFontObject(_G["GameFontHighlightSmall"] or _G["GameFontNormal"])
    ns.RegisterAddonFont(box)
    box:SetTextInsets(7, 7, 0, 0)
    box:SetMaxLetters(maxLetters or 40)
    ns.CreateRoundedRectBorder(box)
    ns.SetRoundedRectBarHeight(box, CHIP_H)
    ns.SetRoundedRectBorderEdgeShown(box, false)
    box.placeholder = CL.Text(box, "GameFontHighlightSmall")
    box.placeholder:SetPoint("LEFT", box, "LEFT", 7, 0)
    box.placeholder:SetText(placeholder or "")
    box:SetScript("OnEscapePressed", box.ClearFocus)
    box:SetScript("OnTextChanged", EntryChanged)
    CL.Painted(box, PaintEntry)
    return box
end

local function EnsureEntry(chip)
    local box = UI.entries[chip.tool]
    if box then return box end
    box = CL.CreateEntry(chip:GetParent(), chip.placeholder)
    box.chip, box.tool = chip, chip.tool
    box:SetPoint("TOPLEFT", chip, "TOPLEFT", 0, 0)
    box:SetScript("OnEnterPressed", EntryEnter)
    box:SetScript("OnEditFocusLost", CloseEntry)
    UI.entries[chip.tool] = box
    return box
end

-- As wide as the room left in the tile row, never narrower than the chip.
local function EntryChip(chip)
    Tiles.CloseEntries()
    local box = EnsureEntry(chip)
    local room = (chip:GetParent():GetRight() or 0) - (chip:GetLeft() or 0) - 8
    box:SetWidth(mmax(chip:GetWidth(), mmin(ENTRY_W * 2, room)))
    chip:Hide()
    box:SetText("")
    box:Show()
    -- A box opened from a press takes focus a frame later, never in a fight.
    Utils.SafeAfter(0, function()
        if box:IsVisible() and not InCombatLockdown() then box:SetFocus() end
    end)
end

local function EntryChipFor(tile, tool, label, placeholder)
    local chip = CL.CreateChip(tile, CHIP_H)
    chip:SetLabel(label)
    chip:SetScript("OnClick", EntryChip)
    chip.tool, chip.placeholder = tool, placeholder
    return chip
end

-- The timer tile follows the presets and the lengths used lately.
local function PoolChip(i)
    local chip = UI.pool[i]
    if chip then return chip end
    chip = CL.CreateChip(UI.timer, CHIP_H)
    chip:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    chip:SetScript("OnClick", TimerChip)
    UI.pool[i] = chip
    return chip
end

local function FillTimerTile()
    local tile = UI.timer
    local items = tile.items
    for i = #items, 1, -1 do items[i] = nil end
    for i = 1, #UI.pool do UI.pool[i]:Hide() end
    local n, whole = 0, false
    local presets = Runs:Presets()
    for i = 1, #presets do
        n = n + 1
        local chip = PoolChip(n)
        chip:SetLabel(CL.ChipLength(presets[i]))
        chip.a, chip.recent = presets[i], nil
        chip.tip = L["CLOCK_PRESET_TT"]
        chip.text:SetAlpha(1)
        items[#items + 1] = chip
        whole = whole or presets[i] % 60 == 0
    end
    tile.unit:SetShown(whole)
    if whole then items[#items + 1] = tile.unit end
    local recent = Runs:Recent()
    for i = 1, #recent do
        n = n + 1
        local chip = PoolChip(n)
        chip:SetLabel(CL.Words(recent[i]))
        chip.a, chip.recent = recent[i], true
        chip.tip = L["CLOCK_RECENT_TT"]
        chip.text:SetAlpha(0.7)
        items[#items + 1] = chip
    end
    items[#items + 1] = UI.timerEntry
end

local function LayoutGrid()
    local tiles = UI.tiles
    local tw = (tiles:GetWidth() - TILE_GAP) / 2
    FillTimerTile()
    local rounds = Runs:RoundsToday(time())
    UI.pom.note:SetText(rounds > 0 and sformat(L["CLOCK_TODAY_FMT"], rounds) or "")
    local h1 = mmax(FlowTile(UI.timer, tw), FlowTile(UI.pom, tw))
    local h2 = mmax(FlowTile(UI.sw, tw), FlowTile(UI.alarm, tw))
    local cells = { { UI.timer, 0, 0, h1 }, { UI.pom, tw + TILE_GAP, 0, h1 },
        { UI.sw, 0, -(h1 + TILE_GAP), h2 }, { UI.alarm, tw + TILE_GAP, -(h1 + TILE_GAP), h2 } }
    for i = 1, #cells do
        local c = cells[i]
        c[1]:SetSize(tw, c[4])
        c[1]:ClearAllPoints()
        c[1]:SetPoint("TOPLEFT", tiles, "TOPLEFT", c[2], c[3])
    end
    tiles:SetHeight(h1 + TILE_GAP + h2)
end

function Tiles.Create(win)
    local W, PAD = CL.Window.W, CL.Window.PAD
    local tiles = CreateFrame("Frame", nil, win)
    tiles:SetWidth(W - 2 * PAD)
    UI.tiles = tiles
    UI.timer = CreateTile(tiles, "timer", CL.GOLD)
    CreateUnit(UI.timer, L["CLOCK_MIN"])
    UI.timerEntry = EntryChipFor(UI.timer, "timer", L["CLOCK_CUSTOM"], L["CLOCK_TIMER_EXAMPLE"])
    UI.pom = CreateTile(tiles, "pomodoro", CL.FOCUS_COLOR)
    for i = 1, #POMODORO_CHIPS do
        local p = POMODORO_CHIPS[i]
        AddChip(UI.pom, p[1] .. " / " .. p[2], PomodoroChip, p[1], p[2])
    end
    UI.pom.items[#UI.pom.items + 1] = EntryChipFor(UI.pom, "pomodoro", L["CLOCK_CUSTOM"], "40 10")
    UI.sw = CreateTile(tiles, "stopwatch", CL.GOLD)
    AddChip(UI.sw, _G["START"] or "Start", StopwatchChip)
    UI.alarm = CreateTile(tiles, "alarm", CL.ALARM_COLOR)
    UI.alarm.items[1] = EntryChipFor(UI.alarm, "alarm", L["CLOCK_SET_TIME"],
        sformat(L["CLOCK_ALARM_EXAMPLE"], Grammar.ClockLabel(19, 30)))
    UI.hint = CL.Text(win, "GameFontHighlightSmall")
    UI.hint:SetWidth(W - 2 * PAD - 4)
    UI.hint:SetJustifyH("LEFT")
    UI.hint:SetText(L["CLOCK_TILES_HINT"])
    PaintHint()
    CL.Painted(UI.hint, PaintHint)
end

-- Places the tiles at y when shown; returns the y under them.
function Tiles.Layout(win, y, show)
    local tiles, hint = UI.tiles, UI.hint
    tiles:SetShown(show)
    hint:SetShown(show)
    if not show then
        Tiles.CloseEntries()
        return y
    end
    LayoutGrid()
    tiles:ClearAllPoints()
    tiles:SetPoint("TOPLEFT", win, "TOPLEFT", CL.Window.PAD, y)
    y = y - tiles:GetHeight() - 8
    hint:ClearAllPoints()
    hint:SetPoint("TOPLEFT", win, "TOPLEFT", CL.Window.PAD + 2, y)
    return y - hint:GetStringHeight() - 6
end
