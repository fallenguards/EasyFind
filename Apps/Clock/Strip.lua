local _, CL = ...
local ns = EasyFind and EasyFind._ns
if not (ns and ns.ClockRuns and ns.ClockAlarms) then return end

-- The minimized clock: a slim bar with one segment per run and one for an
-- alarm due within the hour, left on screen while the window is closed.
local L = ns.L
local Runs, Alarms = ns.ClockRuns, ns.ClockAlarms

local CreateFrame, UIParent = CreateFrame, UIParent
local time, type = time, type
local sformat, mmax = ns.Utils.sformat, ns.Utils.mmax

local Strip = {}
CL.Strip = Strip

local STRIP_H, SEG_H, MINI, SEG_GAP = 30, 22, 16, 4
local SOON_SECONDS = 3600

-- soon: the upcoming alarm drawn as an alarm card would draw it.
local UI = { segs = {}, soon = { tool = "alarm" } }

local function SoonAlarm(now)
    local alarm = Alarms:Soonest()
    if alarm and alarm.next - now <= SOON_SECONDS then return alarm end
    return nil
end

local function DragStart()
    UI.strip:StartMoving()
end

-- The place is read before the stop, which can leave the frame unanchored.
local function DragStop()
    local strip = UI.strip
    local left, top = strip:GetLeft(), strip:GetTop()
    strip:StopMovingOrSizing()
    strip:SetUserPlaced(false)
    if left and top then
        strip:ClearAllPoints()
        strip:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        Runs.sv.strip.left, Runs.sv.strip.top = left, top
    end
end

local function SegEnter(self)
    local run = self.run
    if not run then return end
    local now = time()
    if self.alarm then
        local title = sformat(L["CLOCK_DOT_FMT"], CL.RunLabel(run), sformat(L["CLOCK_IN_FMT"], CL.Format(run.at - now)))
        ns.ShowHintTooltip(self, "ANCHOR_TOP", title, nil, L["CLOCK_STRIP_ALARM_TT"])
        return
    end
    ns.ShowHintTooltip(self, "ANCHOR_TOP", CL.CardLabel(run, now), nil, L["CLOCK_STRIP_TT"])
end

local function SegLeave(self)
    ns.HideHintTooltip(self)
end

local function SegClick(self, button)
    if button == "RightButton" then
        local alarm = self.alarm
        if alarm then
            CL.ShowMenu({ { text = L["CLOCK_TURN_OFF"], onClick = function() CL.SetAlarmOn(alarm, false) end } }, self)
        elseif self.run then
            CL.ShowRunMenu(self.run, self)
        end
    else
        CL.OpenWindow()
    end
end

local function PaintSeg(seg)
    local r, g, b = CL.Surface(0.09)
    ns.SetRoundedRectFill(seg, r, g, b, 1, true)
    local body, _, light = CL.Palette()
    local c = seg.run and seg.run.done and CL.GOLD or body
    seg.time:SetTextColor(c[1], c[2], c[3], 1)
    seg.time:SetShadowColor(0, 0, 0, light and 0 or 1)
end

local function CreateSeg()
    local seg = CreateFrame("Button", nil, UI.strip)
    seg:SetHeight(SEG_H)
    seg:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    seg:RegisterForDrag("LeftButton")
    seg:SetScript("OnDragStart", DragStart)
    seg:SetScript("OnDragStop", DragStop)
    seg:SetScript("OnClick", SegClick)
    seg:SetScript("OnEnter", SegEnter)
    seg:SetScript("OnLeave", SegLeave)
    ns.CreateRoundedRectBorder(seg)
    ns.SetRoundedRectBarHeight(seg, SEG_H)
    ns.SetRoundedRectBorderEdgeShown(seg, false)
    seg.ring = CL.CreateRing(seg, MINI, true)
    seg.ring:SetPoint("LEFT", seg, "LEFT", 3, 0)
    seg.time = CL.DigitsText(seg, 13)
    seg.time:SetPoint("LEFT", seg.ring, "RIGHT", 5, 0)
    CL.Painted(seg, PaintSeg)
    return seg
end

-- Segments sit side by side, each as wide as its time.
local function Layout()
    local x = SEG_GAP
    local segs = UI.segs
    for i = 1, #segs do
        local seg = segs[i]
        if seg:IsShown() then
            local w = 3 + MINI + 5 + CL.TextWidth(seg.time) + 8
            seg:SetWidth(w)
            seg:ClearAllPoints()
            seg:SetPoint("LEFT", UI.strip, "LEFT", x, 0)
            x = x + w + SEG_GAP
        end
    end
    UI.strip:SetWidth(x)
end

local function EnsureStrip()
    if UI.strip then return UI.strip end
    local strip = CreateFrame("Frame", "EasyFindClockStrip", UIParent, "BackdropTemplate")
    UI.strip = strip
    strip:Hide()
    strip:SetSize(120, STRIP_H)
    strip:SetFrameStrata("MEDIUM")
    strip:SetClampedToScreen(true)
    strip:EnableMouse(true)
    strip:SetMovable(true)
    strip:RegisterForDrag("LeftButton")
    strip:SetScript("OnDragStart", DragStart)
    strip:SetScript("OnDragStop", DragStop)
    ns.StyleMenuPanel(strip)
    ns.SetRoundedRectBarHeight(strip, STRIP_H)
    local pos = Runs.sv.strip
    if type(pos.left) == "number" and type(pos.top) == "number" then
        strip:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.left, pos.top)
    else
        strip:SetPoint("TOP", UIParent, "TOP", 0, -140)
    end
    return strip
end

function Strip.UpdateTimes(now, relayout)
    if not relayout and SoonAlarm(now) ~= UI.soonAlarm then
        Strip.Refresh()
        return
    end
    local strip = UI.strip
    if not (strip and strip:IsShown()) and not relayout then return end
    local segs = UI.segs
    for i = 1, #segs do
        local seg = segs[i]
        local run = seg.run
        if run then
            local text = CL.TimeString(run, now)
            if seg.shownText ~= text then
                -- Same-width digits: only a change in length moves anything.
                if #text ~= #(seg.shownText or "") then relayout = true end
                seg.shownText = text
                seg.time:SetText(text)
            end
            CL.HoldRing(seg.ring, run, now)
        end
    end
    if relayout then Layout() end
end

local function ShowSeg(i, run, alarm, now)
    local seg = UI.segs[i] or CreateSeg()
    UI.segs[i] = seg
    seg.run, seg.alarm, seg.shownText = run, alarm, nil
    CL.SetRing(seg.ring, run, now)
    PaintSeg(seg)
    seg:Show()
end

local function FillSoon(alarm)
    local soon = UI.soon
    -- The ring drains over the last hour.
    soon.at, soon.startedAt = alarm.next, mmax(alarm.armedAt or 0, alarm.next - SOON_SECONDS)
    soon.name, soon.hour, soon.min, soon.server = alarm.name, alarm.hour, alarm.min, alarm.server
    return soon
end

-- Shown while the window is closed and a run exists or an alarm is near.
function Strip.Refresh()
    local runs = Runs:List()
    local now = time()
    local alarm = SoonAlarm(now)
    UI.soonAlarm = alarm
    if (#runs == 0 and not alarm) or CL.Window.IsShown() then
        if UI.strip then UI.strip:Hide() end
        return
    end
    EnsureStrip()
    for i = 1, #runs do ShowSeg(i, runs[i], nil, now) end
    local n = #runs
    if alarm then
        n = n + 1
        ShowSeg(n, FillSoon(alarm), alarm, now)
    end
    local segs = UI.segs
    for i = n + 1, #segs do
        segs[i]:Hide()
        segs[i].run, segs[i].alarm = nil, nil
    end
    UI.strip:Show()
    Strip.UpdateTimes(now, true)
end

function Strip.IsShown()
    return UI.strip ~= nil and UI.strip:IsShown()
end
