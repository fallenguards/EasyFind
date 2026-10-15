-- The trip: a route's stops in order, planned leg by leg, and the map
-- page's editor for them: the start first, each stop a field with the
-- map search under it, a grip to drag a stop to another place, the
-- field's own clear button to drop it, and a row to add one.
local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns then return end

local Trip = {}
ns.GPSTrip = Trip

local L = ns.L
local Utils = ns.Utils
local mmax, mmin = math.max, math.min
local tremove, tinsert = table.remove, table.insert

local ROW_H, ADD_H, MARK, GRIP_W, DROP_ROWS, DROP_ROW_H = 30, 26, 16, 14, 6, 20
local TEX_RING = "Interface\\AddOns\\EasyFind\\textures\\clock-ring"   -- a 1.5 px line at 16 px
local PIN = 22
local DIM, RING_GREY = { 0.55, 0.55, 0.58 }, { 0.8, 0.8, 0.82 }

local function Route() local g = ns.GPS return g and g.CurrentRoute and g.CurrentRoute() end

-- A route planned before stops were kept has its one destination.
local function Stops(route)
    route.stops = route.stops or { route.dest }
    return route.stops
end

-- The world spot a stop is reached at, the leg after it starts there.
local function StopPoint(stop)
    local ci, wx, wy = ns.GPS.WorldPos(stop.mapID, stop.x or 0.5, stop.y or 0.5)
    if not ci then return nil end
    return { ci = ci, wx = wx, wy = wy, m = stop.mapID, x = stop.x or 0.5, y = stop.y or 0.5, name = stop.name }
end

-- The stops planned leg by leg, each leg from the stop before: the steps
-- joined, the times added, the first leg's advice. Nil when a leg has no way.
function Trip.Build(stops, via, avoid, quick, draw)
    local g = ns.GPS
    local steps, total, priced, advice = {}, 0, true, nil
    local from
    for k = 1, #stops do
        local legSteps, legTotal, legAdvice = g:BuildRoute(stops[k], k == 1 and via or nil, avoid, quick, draw, from)
        if not legSteps then return nil end
        for i = 1, #legSteps do steps[#steps + 1] = legSteps[i] end
        if legTotal then total = total + legTotal else priced = false end
        advice = advice or legAdvice
        from = StopPoint(stops[k])
        if not from and k < #stops then return nil end
    end
    return steps, priced and total or nil, advice
end

-- The trip planned again from its stops, from the start as set.
function Trip.Navigate(opts)
    local g = ns.GPS
    local route = Route()
    if not route then return false end
    local stops = Stops(route)
    if #stops == 0 then return false end
    local list = {}
    for i = 1, #stops do list[i] = stops[i] end
    local dest = list[#list]
    if not (opts and opts.quiet) then g:Open() end
    g:Plan(dest.name, function() return Trip.Build(list, nil, route.wayAvoid, true, "first") end,
        function(steps, total, advice)
            if steps then g.Navigated(dest, steps, total, advice, list) end
        end)
    return true
end

function Trip.Add(dest)
    local route = Route()
    if not route then return end
    local stops = Stops(route)
    stops[#stops + 1] = dest
    Trip.Navigate({ quiet = true })
end

function Trip.Replace(i, dest)
    local route = Route()
    if not (route and Stops(route)[i]) then return end
    route.stops[i] = dest
    Trip.Navigate({ quiet = true })
end

function Trip.Remove(i)
    local route = Route()
    if not (route and Stops(route)[i]) then return end
    tremove(route.stops, i)
    if #route.stops == 0 then ns.GPS:Clear() else Trip.Navigate({ quiet = true }) end
end

-- Stop i goes to place j.
function Trip.Move(i, j)
    local route = Route()
    local stops = route and Stops(route)
    if not (stops and stops[i] and j >= 1 and j <= #stops) or i == j then return end
    tinsert(stops, j, tremove(stops, i))
    Trip.Navigate({ quiet = true })
end

-- The editor ---------------------------------------------------------------

local Editor = {}

local function DropRow(ed, i)
    local row = ed.dropRows[i]
    if row then return row end
    row = CreateFrame("Button", nil, ed.drop)
    row:SetHeight(DROP_ROW_H)
    row:SetPoint("LEFT", ed.drop, "LEFT", 0, 0)
    row:SetPoint("RIGHT", ed.drop, "RIGHT", 0, 0)
    Utils.InstallMenuRowHighlight(row)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    if ed.px and ns.GPS.SizeFont then ns.GPS.SizeFont(row.text, ed.px) end
    row:SetScript("OnClick", function(self) if self.data then ed:Pick(self.data) end end)
    ed.dropRows[i] = row
    return row
end

-- The places found for what was typed, under the field being edited.
function Editor:ShowHits(results)
    local n = 0
    for i = 1, results and #results or 0 do
        local r = results[i]
        if n < DROP_ROWS and ns.GPS:CanNavigate(r) then
            n = n + 1
            local row = DropRow(self, n)
            row.data = r
            row:SetPoint("TOP", self.drop, "TOP", 0, -(n - 1) * DROP_ROW_H)
            local where = r.zoneName or r.parentName or r.category
            row.text:SetText((r.name or "?") .. (where and where ~= r.name and ("  |cff999999" .. tostring(where) .. "|r") or ""))
            row:Show()
        end
    end
    for i = n + 1, #self.dropRows do self.dropRows[i]:Hide() end
    if ns.StripShadows then ns.StripShadows(self.drop) end
    self.drop:SetHeight(mmax(1, n * DROP_ROW_H))
    self.drop:SetShown(n > 0 and self.editing ~= nil)
end

function Editor:Open(row)
    self.editing = row
    self.closeAt = nil
    self.drop:ClearAllPoints()
    self.drop:SetPoint("TOPLEFT", row.box, "BOTTOMLEFT", 0, -2)
    self.drop:SetPoint("RIGHT", row.box, "RIGHT", 0, 0)
    self:ShowHits(nil)
end

-- Closed: the field reads what it stands for again; an add row with
-- nothing chosen goes.
function Editor:Close()
    local row = self.editing
    self.editing = nil
    self.closeAt = nil
    self.drop:Hide()
    if row and row.adding then self.adding = nil end
    self:Refresh(Route())
end

-- A click on a hit comes after the field loses focus: the close waits.
function Editor:CloseSoon()
    self.closeAt = GetTime() + 0.25
end

function Editor:Typed(row, text)
    if self.editing ~= row then self:Open(row) end
    if text == "" then self:ShowHits(nil) return end
    if self.pending then return end
    self.pending = true
    Utils.SafeAfter(0.15, function()
        self.pending = nil
        local box = self.editing and self.editing.box
        local q = box and box:GetText() or ""
        if q == "" or not ns.GPS.SearchPlaces then return end
        self:ShowHits(ns.GPS.SearchPlaces(q))
    end)
end

function Editor:Pick(data)
    local row = self.editing
    if not row then return end
    local g = ns.GPS
    local index = row.index
    row.box:ClearFocus()
    self.editing, self.closeAt = nil, nil
    self.drop:Hide()
    if index == 0 then
        g:SetStart(data)
    elseif row.adding then
        self.adding = nil
        Trip.Add(g.Destination(data))
    else
        Trip.Replace(index, g.Destination(data))
    end
end

-- The field's own clear button drops the stop, or sets the start back
-- to the player; while a place is being typed it only clears the text.
function Editor:Cleared(row)
    if self.editing == row then return end
    if row.index == 0 then
        ns.GPS:SetStart(nil)
    elseif row.adding then
        self.adding = nil
        self:Refresh(Route())
    else
        Trip.Remove(row.index)
    end
end

-- Dragging a stop's grip: the place the stop would go, by the cursor.
function Editor:Target()
    local _, cy = GetCursorPosition()
    cy = cy / self:GetEffectiveScale()
    local n = #self.stopRows
    for j = 1, n do
        local r = self.stopRows[j]
        local top, bottom = r:GetTop(), r:GetBottom()
        if top and bottom and cy > (top + bottom) / 2 then return j end
    end
    return n + 1
end

function Editor:DragStart(row)
    self.drag = row.index
    self.line:Show()
end

function Editor:DragStop()
    local i = self.drag
    self.drag = nil
    self.line:Hide()
    if not i then return end
    local j = self:Target()
    if j > i then j = j - 1 end
    Trip.Move(i, j)
end

-- Each frame: the drag's line where the stop would land; a pending close
-- once a hit's click had its chance.
function Editor:OnUpdate()
    -- The grip shows on the row under the cursor, while a drag holds it.
    for i = 1, #self.stopRows do
        local r = self.stopRows[i]
        r.grip:SetShown(r.canDrag and (self.drag == r.index or r:IsMouseOver()))
    end
    if self.drag then
        local j = self:Target()
        local n = #self.stopRows
        local r = self.stopRows[mmin(j, n)]
        if r then
            self.line:ClearAllPoints()
            if j > n then
                self.line:SetPoint("TOPLEFT", r, "BOTTOMLEFT", 0, -1)
            else
                self.line:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 1)
            end
            self.line:SetPoint("RIGHT", r, "RIGHT", 0, 0)
        end
    end
    if self.closeAt and GetTime() >= self.closeAt then
        if self.drop:IsShown() and self.drop:IsMouseOver() then
            self.closeAt = GetTime() + 0.25
        else
            self:Close()
        end
    end
end

-- A row's mark, right of the room the drag grip takes: the start's open
-- ring, a stop's pin, the add row's ring with a plus. Three dots above a
-- row join it to the one before.
local function Mark(parent)
    local mark = parent:CreateTexture(nil, "ARTWORK")
    mark:SetSize(MARK, MARK)
    mark:SetPoint("CENTER", parent, "LEFT", GRIP_W + MARK / 2, 0)
    return mark
end

local function Field(ed, i)
    local row = ed.rows[i]
    if row then return row end
    row = CreateFrame("Frame", nil, ed)
    row:SetHeight(ROW_H)
    row.mark = Mark(row)
    row.dots = {}
    for k = 1, 3 do
        local dot = row:CreateTexture(nil, "ARTWORK")
        dot:SetSize(2, 2)
        dot:SetPoint("CENTER", row, "TOPLEFT", GRIP_W + MARK / 2, (2 - k) * 3)
        dot:SetColorTexture(DIM[1], DIM[2], DIM[3], 1)
        row.dots[k] = dot
    end
    -- The drag grip, six dots left of the mark, shown while the cursor
    -- is on a row that can move.
    local grip = CreateFrame("Button", nil, row)
    grip:SetSize(GRIP_W, 20)
    grip:SetPoint("LEFT", row, "LEFT", 0, 0)
    for col = -1, 1, 2 do
        for k = -1, 1 do
            local dot = grip:CreateTexture(nil, "ARTWORK")
            dot:SetSize(2, 2)
            dot:SetPoint("CENTER", grip, "CENTER", col * 2, k * 4)
            dot:SetColorTexture(DIM[1], DIM[2], DIM[3], 1)
        end
    end
    grip:RegisterForDrag("LeftButton")
    grip:SetScript("OnDragStart", function() ed:DragStart(row) end)
    grip:SetScript("OnDragStop", function() ed:DragStop() end)
    if Utils.AttachDelayedTooltip then
        Utils.AttachDelayedTooltip(grip, "ANCHOR_LEFT", function() return L["GPS_TRIP_DRAG"] end)
    end
    grip:Hide()
    row.grip = grip
    local box = CreateFrame("EditBox", nil, row, "SearchBoxTemplate")
    box:SetHeight(20)
    box:SetPoint("LEFT", row, "LEFT", GRIP_W + MARK + 8, 0)
    box:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    box:SetAutoFocus(false)
    box:SetMaxLetters(60)
    if box.Instructions then
        box.Instructions:SetWordWrap(false)
        box.Instructions:SetTextColor(DIM[1], DIM[2], DIM[3], 1)
        box.Instructions._efOwnColor = true
    end
    -- The client focuses a fresh visible EditBox on its own; refuse that.
    box._blockAutoFocus = true
    box:HookScript("OnEditFocusGained", function(self)
        if self._blockAutoFocus then self:ClearFocus() return end
        self:HighlightText()
        ed:Open(row)
    end)
    box:HookScript("OnMouseDown", function(self) self._blockAutoFocus = nil end)
    box:HookScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:HookScript("OnEnterPressed", function()
        local first = ed.dropRows[1]
        if first and first:IsShown() and first.data then ed:Pick(first.data) end
    end)
    box:HookScript("OnEditFocusLost", function() ed:CloseSoon() end)
    box:HookScript("OnTextChanged", function(self, user) if user then ed:Typed(row, self:GetText() or "") end end)
    if box.clearButton then
        box.clearButton:HookScript("OnClick", function() ed:Cleared(row) end)
    end
    row.box = box
    ed.rows[i] = row
    return row
end

-- The rows as the route stands: the start, each stop, the add row. Text
-- in the page's size, the one the steps follow.
function Editor:Refresh(route)
    local g = ns.GPS
    local stops = route and Stops(route) or {}
    local start = g.Start and g.Start()
    local px = g.MapTextPx and g.MapTextPx(self.frame)
    self.px = px
    local boxH = mmax(20, (px or 12) + 8)
    local rowH = boxH + 10
    local y, n = 0, 0
    local function Show(index, text, placeholder, pin, adding)
        n = n + 1
        local row = Field(self, n)
        row.index, row.adding = index, adding or nil
        if self.editing ~= row then
            row.box:SetText(text or "")
            if row.box.Instructions then row.box.Instructions:SetText(placeholder or "") end
        end
        if px and g.SizeFont then
            g.SizeFont(row.box, px)
            if row.box.Instructions then g.SizeFont(row.box.Instructions, px) end
        end
        row.box:SetHeight(boxH)
        if pin then
            local gold = ns.GOLD_COLOR
            row.mark:SetTexture(ns.GPS_ICON_TEX)
            row.mark:SetSize(PIN, PIN)
            row.mark:SetVertexColor(gold[1], gold[2], gold[3], 1)
        else
            row.mark:SetTexture(TEX_RING)
            row.mark:SetSize(MARK, MARK)
            row.mark:SetVertexColor(RING_GREY[1], RING_GREY[2], RING_GREY[3], 1)
        end
        for k = 1, 3 do row.dots[k]:SetShown(n > 1) end
        row.canDrag = index > 0 and not adding and #stops > 1
        if not row.canDrag then row.grip:Hide() end
        row:SetHeight(rowH)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -y)
        -- The first row shares its line with the header's buttons: the
        -- window's fold and close, a pop-out button still in the header.
        if n == 1 and self.frame.popoutBtn and not self.frame.popoutAtFoot then
            row:SetPoint("RIGHT", self.frame.popoutBtn, "LEFT", -6, 0)
        elseif n == 1 then
            row:SetPoint("RIGHT", self, "RIGHT", -mmax(0, (self.frame.padRight or 0) - 14), 0)
        else
            row:SetPoint("RIGHT", self, "RIGHT", 0, 0)
        end
        row:Show()
        y = y + rowH
        return row
    end
    Show(0, start and start.name or "", L["GPS_TRIP_FROM"], false)
    wipe(self.stopRows)
    for i = 1, #stops do
        self.stopRows[i] = Show(i, stops[i].name or "?", L["GPS_TRIP_TO"], true)
    end
    if self.adding then
        local row = Show(#stops + 1, "", L["GPS_TRIP_TO"], true, true)
        if self.adding == "focus" then
            -- Focused after the click that made the row, not inside it.
            self.adding = true
            Utils.SafeAfter(0, function()
                row.box._blockAutoFocus = nil
                row.box:SetFocus()
            end)
        end
    end
    for i = n + 1, #self.rows do self.rows[i]:Hide() end
    if px and g.SizeFont then g.SizeFont(self.addText, px) end
    self.add:ClearAllPoints()
    self.add:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -y)
    self.add:SetPoint("RIGHT", self, "RIGHT", 0, 0)
    for k = 1, 3 do self.addDots[k]:SetShown(not self.adding) end
    self.add:SetShown(not self.adding)
    if not self.adding then y = y + ADD_H end
    self:SetHeight(mmax(1, y))
end

-- The editor at the top of a route page, in the title line's place: the
-- fields say where the trip goes, so the title does not.
function Trip.BuildEditor(frame)
    if frame.trip or not (frame.glyph and frame.eta and frame.list and frame.clearBtn) then return end
    local ed = CreateFrame("Frame", nil, frame)
    for k, v in pairs(Editor) do ed[k] = v end
    ed.frame = frame
    ed.rows, ed.stopRows, ed.dropRows = {}, {}, {}
    ed:SetPoint("TOPLEFT", frame.glyph, "TOPLEFT", 0, 0)
    ed:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
    ed:SetHeight(1)
    frame.title:Hide()
    if frame.glyphTex then frame.glyphTex:Hide() end

    -- The add row: a ring with a plus in it under the marks, the words after.
    local add = CreateFrame("Button", nil, ed)
    add:SetHeight(ADD_H)
    local ring = Mark(add)
    ring:SetTexture(TEX_RING)
    ring:SetVertexColor(RING_GREY[1], RING_GREY[2], RING_GREY[3], 1)
    local plus = add:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    plus:SetPoint("CENTER", ring, "CENTER", 0, 0)
    plus:SetText("+")
    plus:SetTextColor(RING_GREY[1], RING_GREY[2], RING_GREY[3], 1)
    plus._efOwnColor = true
    ed.addDots = {}
    for k = 1, 3 do
        local dot = add:CreateTexture(nil, "ARTWORK")
        dot:SetSize(2, 2)
        dot:SetPoint("CENTER", add, "TOPLEFT", GRIP_W + MARK / 2, (2 - k) * 3)
        dot:SetColorTexture(DIM[1], DIM[2], DIM[3], 1)
        ed.addDots[k] = dot
    end
    local addText = add:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    addText:SetPoint("LEFT", ring, "RIGHT", 8, 0)
    addText:SetText(L["GPS_TRIP_ADD"])
    addText:SetTextColor(DIM[1], DIM[2], DIM[3], 1)
    addText._efOwnColor = true
    add:SetScript("OnEnter", function() addText:SetTextColor(1, 1, 1, 1) end)
    add:SetScript("OnLeave", function() addText:SetTextColor(DIM[1], DIM[2], DIM[3], 1) end)
    add:SetScript("OnClick", function()
        ed.adding = "focus"
        ed:Refresh(Route())
    end)
    ed.add, ed.addText = add, addText

    local line = ed:CreateTexture(nil, "OVERLAY")
    line:SetHeight(2)
    line:SetColorTexture(1, 0.82, 0, 0.9)
    line:Hide()
    ed.line = line

    local drop = CreateFrame("Frame", nil, ed)
    drop:SetFrameLevel(frame:GetFrameLevel() + 30)
    local fill = drop:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints(drop)
    fill:SetColorTexture(0.05, 0.05, 0.06, 0.96)
    drop:Hide()
    ed.drop = drop

    -- The time line and the steps hang from the editor now, the arrival
    -- announcement too.
    local etaH = frame.eta:GetHeight() or 12
    frame.eta:ClearAllPoints()
    frame.eta:SetPoint("TOPLEFT", ed, "BOTTOMLEFT", 22, -4)
    frame.eta:SetPoint("RIGHT", frame.clearBtn, "LEFT", -8, 0)
    -- The link's top hangs from the editor, not the time line, whose right
    -- end is anchored to the link: the client refuses the cycle.
    frame.clearBtn:ClearAllPoints()
    frame.clearBtn:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
    frame.clearBtn:SetPoint("TOP", ed, "BOTTOM", 0, -3)
    frame.list:SetPoint("TOPLEFT", ed, "BOTTOMLEFT", -6, -(4 + etaH + (frame.listGap or 8)))
    if frame.empty then frame.empty:SetPoint("TOPLEFT", ed, "BOTTOMLEFT", 0, -10) end

    ed:SetScript("OnUpdate", ed.OnUpdate)
    frame.trip = ed
    ed:Refresh(Route())
end
