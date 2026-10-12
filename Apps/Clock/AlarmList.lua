local _, CL = ...
local ns = EasyFind and EasyFind._ns
if not (ns and ns.ClockAlarms and ns.ClockGrammar) then return end

-- The kept alarms in the window: one row each with its time, name, repeat
-- and a switch; a click opens the row's editor underneath.
local Utils = ns.Utils
local L = ns.L
local Alarms, Grammar = ns.ClockAlarms, ns.ClockGrammar

local CreateFrame = CreateFrame
local time, strtrim, strsplit = time, strtrim, strsplit
local sformat, mfloor = Utils.sformat, Utils.mfloor

local AlarmList = {}
CL.AlarmList = AlarmList

local ROW_H, HEAD_H, EDIT_H, CHIP_H = 36, 18, 104, 18
local PRESET_DAYS = { { "CLOCK_ONCE", 0 }, { "CLOCK_DAILY", 127 }, { "CLOCK_WEEKDAYS", 62 } }

local UI = { rows = {}, sorted = {} }

-- Rows

local function SubLine(alarm, now)
    local text = Grammar.RepeatLabel(alarm.days)
    if alarm.name then text = sformat(L["CLOCK_DOT_FMT"], alarm.name, text) end
    local status = alarm.enabled and alarm.next and sformat(L["CLOCK_IN_FMT"], CL.Format(alarm.next - now))
        or L["CLOCK_OFF"]
    return sformat(L["CLOCK_DOT_FMT"], text, status)
end

local function PaintRow(row)
    local r, g, b = CL.Surface(0.07)
    ns.SetRoundedRectFill(row, r, g, b, 1, true)
    local body, faint, light = CL.Palette()
    local on = row.alarm and row.alarm.enabled
    local c = on and body or faint
    row.time:SetTextColor(c[1], c[2], c[3], 1)
    row.sub:SetTextColor(faint[1], faint[2], faint[3], 1)
    local shadow = light and 0 or 1
    row.time:SetShadowColor(0, 0, 0, shadow)
    row.sub:SetShadowColor(0, 0, 0, shadow)
end

local function OpenEditor(alarm)
    if UI.edit and UI.edit.alarm == alarm then
        AlarmList.CloseEditor()
    else
        UI.edit = { alarm = alarm, days = alarm.days, server = alarm.server }
        UI.editFresh = true
    end
    CL.Window.Refresh()
end

local function RowClick(self, button)
    local alarm = self.alarm
    if not alarm then return end
    if button == "RightButton" then
        CL.ShowMenu({
            { text = _G["EDIT"] or "Edit", onClick = function() OpenEditor(alarm) end },
            { text = _G["DELETE"] or "Delete", onClick = function() CL.DeleteAlarm(alarm) end },
        }, self)
        return
    end
    OpenEditor(alarm)
end

local function SwitchClick(self)
    local alarm = self:GetParent().alarm
    if alarm then CL.SetAlarmOn(alarm, not alarm.enabled) end
end

local function CreateRow(win)
    local row = CreateFrame("Button", nil, win)
    row:SetHeight(ROW_H)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnDragStart", CL.WindowDragStart)
    row:SetScript("OnDragStop", CL.WindowDragStop)
    row:SetScript("OnClick", RowClick)
    ns.CreateRoundedRectBorder(row)
    ns.SetRoundedRectBarHeight(row, 18)
    ns.SetRoundedRectBorderEdgeShown(row, false)
    row.time = CL.DigitsText(row, 17)
    row.time:SetPoint("TOPLEFT", row, "TOPLEFT", 10, -4)
    row.sub = CL.Text(row, "GameFontHighlightSmall")
    row.sub:SetPoint("TOPLEFT", row.time, "BOTTOMLEFT", 0, -2)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)
    row.switch = CL.CreateSwitch(row)
    row.switch:SetPoint("RIGHT", row, "RIGHT", -10, 0)
    row.switch:SetScript("OnClick", SwitchClick)
    row.sub:SetPoint("RIGHT", row.switch, "LEFT", -8, 0)
    CL.Painted(row, PaintRow)
    return row
end

-- The editor

local function SetDays(days)
    UI.edit.days = days
    local editor = UI.editor
    for i = 1, #editor.presets do
        CL.SetActive(editor.presets[i], editor.presets[i].days == days)
    end
    for wday = 1, 7 do
        CL.SetActive(editor.dayChips[wday], Grammar.HasDay(days, wday))
    end
end

local function PresetClick(self)
    SetDays(self.days)
end

local function DayClick(self)
    local days, bit = UI.edit.days, 2 ^ (self.wday - 1)
    days = Grammar.HasDay(days, self.wday) and days - bit or days + bit
    SetDays(mfloor(days))
end

local function RealmClick(self)
    UI.edit.server = not UI.edit.server or nil
    CL.SetActive(self, UI.edit.server)
end

-- An untouched time keeps its hour; a typed one reads as the search bar's.
local function SaveClick()
    local edit, editor = UI.edit, UI.editor
    local alarm = edit.alarm
    local text = strtrim(editor.timeBox:GetText() or "")
    local hour, minute = alarm.hour, alarm.min
    if text ~= editor.filledTime then
        local cmd = Grammar.Parse("alarm " .. text)
        if not (cmd and cmd.hour) then
            editor.error:SetText(L["CLOCK_ALARM_BAD"])
            editor.error:Show()
            return
        end
        cmd.days, cmd.server = edit.days, edit.server
        Grammar.Resolve(cmd, time())
        hour, minute = cmd.hour, cmd.min
    end
    AlarmList.CloseEditor()
    CL.EditAlarm(alarm, hour, minute, edit.days, editor.nameBox:GetText(), edit.server)
end

local function DeleteClick()
    local alarm = UI.edit.alarm
    AlarmList.CloseEditor()
    CL.DeleteAlarm(alarm)
end

local function EditorChip(editor, label, onClick)
    local chip = CL.CreateChip(editor, CHIP_H)
    chip:SetLabel(label)
    chip:SetScript("OnClick", onClick)
    return chip
end

local function PaintEditor(editor)
    local r, g, b = CL.Surface(0.04)
    ns.SetRoundedRectFill(editor, r, g, b, 1, true)
    editor.error:SetTextColor(CL.FOCUS_COLOR[1], CL.FOCUS_COLOR[2], CL.FOCUS_COLOR[3], 1)
end

local function EnsureEditor(win)
    if UI.editor then return UI.editor end
    local editor = CreateFrame("Frame", nil, win)
    editor:SetHeight(EDIT_H)
    ns.CreateRoundedRectBorder(editor)
    ns.SetRoundedRectBarHeight(editor, 18)
    ns.SetRoundedRectBorderEdgeShown(editor, false)

    editor.timeBox = CL.CreateEntry(editor, Grammar.ClockLabel(7, 30), 12)
    editor.timeBox:SetWidth(78)
    editor.timeBox:SetPoint("TOPLEFT", editor, "TOPLEFT", 8, -8)
    editor.timeBox:SetScript("OnEnterPressed", SaveClick)
    editor.nameBox = CL.CreateEntry(editor, L["CLOCK_NAME_PLACEHOLDER"], 24)
    editor.nameBox:SetPoint("LEFT", editor.timeBox, "RIGHT", 6, 0)
    editor.nameBox:SetPoint("RIGHT", editor, "RIGHT", -8, 0)
    editor.nameBox:SetScript("OnEnterPressed", SaveClick)

    editor.presets = {}
    local x = 8
    for i = 1, #PRESET_DAYS do
        local chip = EditorChip(editor, L[PRESET_DAYS[i][1]], PresetClick)
        chip.days = PRESET_DAYS[i][2]
        chip:SetPoint("TOPLEFT", editor, "TOPLEFT", x, -30)
        x = x + chip:GetWidth() + 4
        editor.presets[i] = chip
    end
    editor.dayChips = {}
    local letters = { strsplit(",", L["CLOCK_DAY_LETTERS"]) }
    for wday = 1, 7 do
        local chip = EditorChip(editor, letters[wday] or tostring(wday), DayClick)
        chip.wday = wday
        chip:SetWidth(24)
        chip:SetPoint("TOPLEFT", editor, "TOPLEFT", 8 + (wday - 1) * 28, -52)
        editor.dayChips[wday] = chip
    end

    editor.realm = EditorChip(editor, L["CLOCK_REALM_TIME"], RealmClick)
    editor.realm.tip = L["CLOCK_REALM_TT"]
    editor.realm:SetPoint("TOPLEFT", editor, "TOPLEFT", 8, -76)
    editor.save = EditorChip(editor, _G["SAVE"] or "Save", SaveClick)
    editor.save:SetPoint("TOPRIGHT", editor, "TOPRIGHT", -8, -76)
    editor.delete = EditorChip(editor, _G["DELETE"] or "Delete", DeleteClick)
    editor.delete:SetPoint("RIGHT", editor.save, "LEFT", -5, 0)
    editor.error = CL.Text(editor, "GameFontHighlightSmall")
    editor.error:SetPoint("LEFT", editor.realm, "RIGHT", 8, 0)
    editor.error:SetPoint("RIGHT", editor.delete, "LEFT", -6, 0)
    editor.error:SetJustifyH("LEFT")
    editor.error:SetWordWrap(false)
    UI.editor = editor
    CL.Painted(editor, PaintEditor)
    return editor
end

-- Fills the editor the first time it shows for an alarm.
local function FillEditor(editor)
    local edit = UI.edit
    local alarm = edit.alarm
    editor.filledTime = Grammar.ClockLabel(alarm.hour, alarm.min)
    editor.timeBox:SetText(editor.filledTime)
    editor.timeBox:Show()
    editor.nameBox:SetText(alarm.name or "")
    editor.nameBox:Show()
    editor.error:Hide()
    SetDays(edit.days)
    CL.SetActive(editor.realm, edit.server)
end

function AlarmList.DropFocus()
    local editor = UI.editor
    if editor then
        editor.timeBox:ClearFocus()
        editor.nameBox:ClearFocus()
    end
end

function AlarmList.CloseEditor()
    if not UI.edit then return end
    UI.edit = nil
    AlarmList.DropFocus()
    if UI.editor then UI.editor:Hide() end
end

-- Places the list at y; returns the y under it.
function AlarmList.Layout(win, y, now)
    local list = Alarms:Sorted(UI.sorted)
    local PAD = CL.Window.PAD
    local edit = UI.edit
    if edit and not Alarms:Find(edit.alarm.id) then AlarmList.CloseEditor() end
    if not UI.head then
        UI.head = CL.Text(win, "GameFontHighlightSmall")
        UI.head:SetText(L["CLOCK_ALARMS"])
    end
    UI.head:SetShown(#list > 0)
    if UI.editor then UI.editor:Hide() end
    for i = #list + 1, #UI.rows do
        UI.rows[i]:Hide()
        UI.rows[i].alarm = nil
    end
    if #list == 0 then return y end
    local _, faint = CL.Palette()
    UI.head:SetTextColor(faint[1], faint[2], faint[3], 1)
    UI.head:ClearAllPoints()
    UI.head:SetPoint("TOPLEFT", win, "TOPLEFT", PAD + 4, y - 2)
    y = y - HEAD_H
    for i = 1, #list do
        local alarm = list[i]
        local row = UI.rows[i] or CreateRow(win)
        UI.rows[i] = row
        row.alarm, row.shownSub = alarm, nil
        row.time:SetText(Grammar.ClockLabel(alarm.hour, alarm.min, alarm.server))
        row.switch:SetOn(alarm.enabled)
        row.switch.tip = alarm.enabled and L["CLOCK_TURN_OFF"] or L["CLOCK_TURN_ON"]
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", win, "TOPLEFT", PAD, y)
        row:SetPoint("TOPRIGHT", win, "TOPRIGHT", -PAD, y)
        row:Show()
        PaintRow(row)
        y = y - ROW_H - 4
        if UI.edit and UI.edit.alarm == alarm then
            local editor = EnsureEditor(win)
            if UI.editFresh then
                UI.editFresh = nil
                FillEditor(editor)
            end
            editor:ClearAllPoints()
            editor:SetPoint("TOPLEFT", win, "TOPLEFT", PAD, y)
            editor:SetPoint("TOPRIGHT", win, "TOPRIGHT", -PAD, y)
            editor:Show()
            y = y - EDIT_H - 4
        end
    end
    AlarmList.UpdateTimes(now)
    return y - 2
end

function AlarmList.UpdateTimes(now)
    for i = 1, #UI.rows do
        local row = UI.rows[i]
        if row.alarm and row:IsShown() then
            local sub = SubLine(row.alarm, now)
            if row.shownSub ~= sub then
                row.shownSub = sub
                row.sub:SetText(sub)
            end
        end
    end
end
