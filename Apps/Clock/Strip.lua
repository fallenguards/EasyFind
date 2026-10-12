local _, CL = ...
local ns = EasyFind and EasyFind._ns
if not (ns and ns.ClockRuns and ns.ClockGrammar) then return end

-- The minimized clock: a slim bar with one segment per run, left on
-- screen while the window is closed.
local L = ns.L
local Runs = ns.ClockRuns

local CreateFrame, UIParent = CreateFrame, UIParent
local time, type = time, type

local Strip = {}
CL.Strip = Strip

local STRIP_H, SEG_H, MINI, SEG_GAP = 30, 22, 16, 4

local UI = { segs = {} }

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
    ns.ShowHintTooltip(self, "ANCHOR_TOP", CL.CardLabel(run, time()), nil, L["CLOCK_STRIP_TT"])
end

local function SegLeave(self)
    ns.HideHintTooltip(self)
end

local function SegClick(self, button)
    if button == "RightButton" then
        if self.run then CL.ShowRunMenu(self.run, self) end
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

-- Shown while any run exists and the window is closed.
function Strip.Refresh()
    local runs = Runs:List()
    if #runs == 0 or CL.Window.IsShown() then
        if UI.strip then UI.strip:Hide() end
        return
    end
    EnsureStrip()
    local now = time()
    local segs = UI.segs
    for i = 1, #runs do
        local seg = segs[i] or CreateSeg()
        segs[i] = seg
        seg.run = runs[i]
        seg.shownText = nil
        CL.SetRing(seg.ring, runs[i], now)
        PaintSeg(seg)
        seg:Show()
    end
    for i = #runs + 1, #segs do
        segs[i]:Hide()
        segs[i].run = nil
    end
    UI.strip:Show()
    Strip.UpdateTimes(now, true)
end

function Strip.IsShown()
    return UI.strip ~= nil and UI.strip:IsShown()
end
