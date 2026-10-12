local _, CL = ...
local ns = EasyFind and EasyFind._ns
if not (ns and ns.ClockRuns) then return end

-- Right-click menus and the minimap icon. Menus are the shared cursor
-- menu: Esc and a click elsewhere close them.
local Utils = ns.Utils
local L = ns.L
local Runs = ns.ClockRuns

local CreateFrame, Minimap, GetCursorPosition = CreateFrame, Minimap, GetCursorPosition
local time, sformat = time, Utils.sformat
local mdeg, matan2 = math.deg, math.atan2

local NUDGE, PLUS_SECONDS = 60, 300
local RESTART_TEXT = _G["RESTART"] or "Restart"

local UI = {}

-- The owner's own click toggles its menu.
function CL.ShowMenu(rows, owner)
    local menu = UI.menu
    if menu and menu:IsShown() and menu.toggleOwner == owner then
        menu:Hide()
        return
    end
    UI.menu = Utils.ShowCursorMenu("EasyFindClockMenu", rows, { toggleOwner = owner })
end

local function Row(text, fn, run, arg)
    return { text = text, onClick = function() fn(run, arg) end }
end

local function Changed(fn)
    return function(run, arg)
        fn(run, time(), arg)
        CL.Changed()
    end
end

local TogglePause = Changed(function(run, now) Runs:TogglePause(run, now) end)
local Restart = Changed(function(run, now) Runs:Restart(run, now) end)
local Adjust = Changed(function(run, now, delta) Runs:Adjust(run, now, delta) end)
local Extend = Changed(function(run, now) Runs:Extend(run, now, PLUS_SECONDS) end)
local Lap = Changed(function(run, now) Runs:Lap(run, now) end)
local Cancel = Changed(function(run) Runs:Cancel(run) end)

local function SavePreset(run)
    CL.SavePreset(run.base or run.duration)
end

-- A card's or a strip segment's right-click: what the card's own buttons
-- do, and rename.
function CL.ShowRunMenu(run, owner)
    local rows, tool = {}, run.tool
    local function Add(text, fn, arg) rows[#rows + 1] = Row(text, fn, run, arg) end
    if run.done then
        if tool == "alarm" then
            Add(sformat(L["CLOCK_SNOOZE_FMT"], CL.SnoozeMinutes()), CL.Snooze)
        else
            Add(L["CLOCK_PLUS5"], Extend)
            Add(L["CLOCK_AGAIN"], CL.Again)
            Add(L["CLOCK_RENAME"], CL.Rename)
        end
        Add(L["CLOCK_DISMISS"], Cancel)
        CL.ShowMenu(rows, owner)
        return
    end
    if tool ~= "alarm" then
        Add(run.waiting and L["CLOCK_START_NEXT"] or (run.pausedAt and L["CLOCK_RESUME"] or L["CLOCK_PAUSE"]), TogglePause)
    end
    if tool == "timer" then
        Add(L["CLOCK_PLUS1_TT"], Adjust, NUDGE)
        Add(L["CLOCK_MINUS1_TT"], Adjust, -NUDGE)
        Add(L["CLOCK_SAVE_PRESET"], SavePreset)
    elseif tool == "stopwatch" then
        Add(L["CLOCK_LAP"], Lap)
    elseif tool == "pomodoro" then
        Add(run.phase == "focus" and L["CLOCK_SKIP_BREAK"] or L["CLOCK_SKIP_FOCUS"], CL.Skip)
    end
    if tool ~= "alarm" then Add(tool == "stopwatch" and (_G["RESET"] or "Reset") or RESTART_TEXT, Restart) end
    Add(L["CLOCK_RENAME"], CL.Rename)
    Add(L["CLOCK_STOP"], Cancel)
    CL.ShowMenu(rows, owner)
end

-- A typed name, through the themed prompt.
function CL.Rename(run)
    ns.ShowThemedDialog({
        text = L["CLOCK_RENAME_PROMPT"],
        hasEditBox = true, maxLetters = Runs.NAME_MAX, editBoxDefault = run.name or "",
        acceptText = _G["OKAY"] or "Okay",
        cancelText = _G["CANCEL"] or "Cancel",
        onAccept = function(value)
            Runs:Rename(run, value)
            CL.Changed()
        end,
    })
end

local CancelAll = Changed(function() Runs:CancelAll() end)

local function ShowCancelMenu(owner)
    local runs = Runs:List()
    if #runs == 0 then return end
    local rows = {}
    for i = 1, #runs do
        local row = Row(sformat(L["CLOCK_CANCEL_RUN"], CL.MenuLabel(runs[i])), Cancel, runs[i])
        row.icon, row.chromeIcon = ns.CLOCK_TOOL_ICONS[runs[i].tool], true
        rows[i] = row
    end
    if #runs > 1 then
        rows[#rows + 1] = { isSeparator = true }
        rows[#rows + 1] = { text = L["CLOCK_CANCEL_ALL"], onClick = CancelAll }
    end
    CL.ShowMenu(rows, owner)
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
    elseif CL.Window.IsShown() then
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

-- Shown with the setting on while a run or a switched-on alarm exists.
function CL.UpdateMinimapButton(active)
    local want = EasyFind.db.clockMinimapIcon == true and active
    if not (want or UI.mm) then return end
    EnsureMinimapButton():SetShown(want)
    if want then PlaceMinimapButton() end
end
