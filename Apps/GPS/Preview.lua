-- EasyFind GPS: route previews on the map.
--
-- With the GPS page open beside the map, resting the cursor on a step
-- shows that step's map and draws the route on it: every leg of the route
-- that lies on that map as a faint line, the hovered leg bright, with a
-- mark where it starts and our pin where it ends. Leaving the step takes
-- the drawing away; the map stays where it was put.
local ns = EasyFind and EasyFind._ns
if not ns then return end
local Preview = {}
ns.GPSPreview = Preview

local mabs, matan2, msqrt = math.abs, math.atan2, math.sqrt
local CreateVector2D = CreateVector2D

-- Sizes in screen pixels; the canvas is drawn far larger than the screen
-- and shrinks with the zoom, so each is converted at draw time.
local LINE_W = 5
local DASH, GAP = 18, 10           -- a dashed line: dash length and the gap after it
local ARROW, START = 32, 36

local function px(v)
    return ns.UIToCanvas and ns.UIToCanvas(v) or v
end
local RED = { 1, 0.22, 0.16 }
local WHITE = "Interface\\Buttons\\WHITE8x8"
local TEX_ARROW = "Interface\\AddOns\\EasyFind\\MapSearch\\Images\\arrow-hq"   -- points down as drawn

local overlay, pool, marks
local shownMap, shownIndex
local since = 0

local function DB() return EasyFind and EasyFind.db end
local function Route() local g = ns and ns.GPS return g and g.CurrentRoute and g.CurrentRoute() end

local function Canvas()
    return WorldMapFrame and WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
end

-- Red, as a route is drawn on a map.
local function Accent()
    return RED
end

local function Build()
    local canvas = Canvas()
    if not canvas then return false end
    overlay = CreateFrame("Frame", "EasyFindGPSPreview", canvas)
    overlay:SetAllPoints(canvas)
    overlay:SetFrameStrata("HIGH")
    overlay:SetFrameLevel(300)
    overlay:EnableMouse(false)
    pool = {}
    marks = { start = overlay:CreateTexture(nil, "OVERLAY", nil, 2), stop = overlay:CreateTexture(nil, "OVERLAY", nil, 3) }
    marks.start:SetTexture("Interface\\AddOns\\EasyFind_GPS\\textures\\beam_flare")
    marks.start:SetBlendMode("ADD")
    marks.stop:SetTexture(TEX_ARROW)
    -- A portal's spot: the map's own portal symbol, pulsing.
    local portal = overlay:CreateTexture(nil, "OVERLAY", nil, 4)
    marks.portal = portal
    local pulse = portal:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local grow = pulse:CreateAnimation("Scale")
    grow:SetScaleFrom(1, 1)
    grow:SetScaleTo(1.3, 1.3)
    grow:SetDuration(0.5)
    grow:SetSmoothing("IN_OUT")
    pulse:Play()
    portal:Hide()
    overlay:Hide()
    return true
end

local function PortalAtlas()
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    return faction == "Horde" and "MagePortalHorde" or "MagePortalAlliance"
end


local function Line(i)
    local t = pool[i]
    if not t then
        t = overlay:CreateTexture(nil, "OVERLAY", nil, 1)
        t:SetTexture(WHITE)
        pool[i] = t
    end
    return t
end

-- A step's point on the shown map, in canvas pixels, or nothing when it
-- is not on that map.
local function OnCanvas(p, mapID)
    if not p then return nil end
    local x, y
    if p.wx and p.ci and C_Map.GetMapPosFromWorldPos then
        local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, p.ci, CreateVector2D(p.wx, p.wy), mapID)
        if ok and pos then x, y = pos:GetXY() end
    elseif p.m == mapID then
        x, y = p.x, p.y
    end
    if not (x and y) or x < 0 or x > 1 or y < 0 or y > 1 then return nil end
    local canvas = Canvas()
    return { x * canvas:GetWidth(), -y * canvas:GetHeight() }
end

-- Where a step starts: the previous step's landing, or the player, read
-- through the GPS module's own helper so the axes match the data's.
local function StartOf(route, i)
    if i > 1 then return route.steps[i - 1].arrive end
    local get = ns.GPS and ns.GPS.PlayerWorldPos
    if get then
        local ci, wx, wy = get()
        if ci and wx then return { ci = ci, wx = wx, wy = wy } end
    end
    return nil
end

local function Draw()
    local route = Route()
    if not (route and overlay and shownMap) then return end
    local canvas = Canvas()
    if not canvas or (WorldMapFrame.GetMapID and WorldMapFrame:GetMapID() ~= shownMap) then
        overlay:Hide()
        return
    end
    local accent = Accent()
    local n = 0
    local hovered
    local lineW, dash, gap, arrow = px(LINE_W), px(DASH), px(GAP), px(ARROW)
    for i = 1, #route.steps do
        local step = route.steps[i]
        -- A teleport draws nothing: nothing is walked, and the legs after
        -- it start from where it lands.
        local teleport = step.kind == "teleport"
        local a = (not teleport) and OnCanvas(StartOf(route, i), shownMap) or nil
        local target = step.go or step.arrive
        local b = (not teleport) and OnCanvas(target, shownMap) or nil
        if a and b then
            local dx, dy = b[1] - a[1], b[2] - a[2]
            local len = msqrt(dx * dx + dy * dy)
            if len > 2 then
                -- Dashes laid along the leg, each a short rotated bar; the
                -- last one stops short of the arrowhead.
                local ux, uy = dx / len, dy / len
                local angle = matan2(dy, dx)
                local bright = i == shownIndex
                local alpha = bright and 0.95 or 0.4
                -- The last dash stops short of the arrowhead; a portal's
                -- symbol sits on its spot, so the dashes run to it.
                local usable = len - ((bright and step.kind ~= "portal") and arrow * 0.9 or 0)
                local pos = 0
                while pos < usable do
                    local d = dash
                    if pos + d > usable then d = usable - pos end
                    if d > 1 then
                        n = n + 1
                        local t = Line(n)
                        t:ClearAllPoints()
                        t:SetSize(d, lineW)
                        local cx, cy = a[1] + ux * (pos + d / 2), a[2] + uy * (pos + d / 2)
                        t:SetPoint("CENTER", overlay, "TOPLEFT", cx, cy)
                        t:SetRotation(angle)
                        t:SetVertexColor(accent[1], accent[2], accent[3], alpha)
                        t:Show()
                    end
                    pos = pos + dash + gap
                end
            end
        end
        if i == shownIndex then hovered = { a = a, b = b, target = target, step = step } end
    end
    for i = n + 1, #pool do pool[i]:Hide() end
    -- The hovered leg's ends: a soft mark where it starts, our pin where
    -- it ends; a crossing shows its spot alone when the start is elsewhere.
    if hovered and hovered.a then
        marks.start:ClearAllPoints()
        marks.start:SetSize(px(START), px(START))
        marks.start:SetPoint("CENTER", overlay, "TOPLEFT", hovered.a[1], hovered.a[2])
        marks.start:SetVertexColor(accent[1], accent[2], accent[3], 0.9)
        marks.start:Show()
    else
        marks.start:Hide()
    end
    local portalStep = hovered and hovered.step and hovered.step.kind == "portal"
    if hovered and hovered.b and portalStep then
        -- A portal: the map's portal symbol pulsing on its spot, no arrow.
        marks.stop:Hide()
        local size = px(ARROW) * 1.2
        marks.portal:SetAtlas(PortalAtlas())
        marks.portal:ClearAllPoints()
        marks.portal:SetSize(size, size)
        marks.portal:SetPoint("CENTER", overlay, "TOPLEFT", hovered.b[1], hovered.b[2])
        marks.portal:Show()
    elseif hovered and hovered.b then
        marks.portal:Hide()
        -- The arrowhead at the end, turned along the leg; pointing down
        -- when there is no leg to turn along.
        marks.stop:ClearAllPoints()
        marks.stop:SetSize(arrow, arrow)
        if hovered.a then
            -- The art's tip is at its edge: set the head back along the
            -- leg by half its size so the tip lands on the spot itself.
            local dx, dy = hovered.b[1] - hovered.a[1], hovered.b[2] - hovered.a[2]
            local len = msqrt(dx * dx + dy * dy)
            local ux, uy = (len > 0) and dx / len or 0, (len > 0) and dy / len or 0
            marks.stop:SetPoint("CENTER", overlay, "TOPLEFT", hovered.b[1] - ux * arrow * 0.45, hovered.b[2] - uy * arrow * 0.45)
            marks.stop:SetRotation(matan2(dy, dx) + math.pi / 2)
        else
            marks.stop:SetPoint("CENTER", overlay, "TOPLEFT", hovered.b[1], hovered.b[2] + arrow * 0.45)
            marks.stop:SetRotation(0)
        end
        marks.stop:SetVertexColor(accent[1], accent[2], accent[3], 1)
        marks.stop:Show()
    else
        marks.stop:Hide()
        marks.portal:Hide()
    end
    overlay:Show()
end

-- Whether a world point falls on a map.
local function Falls(p, mapID)
    if not (p and mapID) then return false end
    local x, y
    if p.wx and p.ci and C_Map.GetMapPosFromWorldPos then
        local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, p.ci, CreateVector2D(p.wx, p.wy), mapID)
        if ok and pos then x, y = pos:GetXY() end
    elseif p.m == mapID then
        x, y = p.x, p.y
    end
    return x ~= nil and y ~= nil and x >= 0 and x <= 1 and y >= 0 and y <= 1
end

-- The map a step is about: the smallest one that holds both ends of the
-- leg (the start and its spot), walking up from the spot's own map to
-- the continent, so a leg from Moonglade to Tanaris shows Kalimdor with
-- the line across it. A teleport shows the map it lands on.
local function MapOf(route, index)
    local step = route.steps[index]
    if step.kind == "teleport" then return step.arrive and step.arrive.m end
    local target = step.go or step.arrive
    local mapID = step.mapID or (target and target.m)
    if not mapID then return nil end
    local start = StartOf(route, index)
    if not start then return mapID end
    local m, depth = mapID, 0
    while m and depth < 8 do
        if Falls(start, m) and Falls(target, m) then return m end
        local info = C_Map.GetMapInfo and C_Map.GetMapInfo(m)
        if not info or not info.parentMapID or info.parentMapID == 0 or (info.mapType and info.mapType <= 1) then break end
        m = info.parentMapID
        depth = depth + 1
    end
    return mapID
end

function Preview:Show(index)
    local route = Route()
    local step = route and route.steps and route.steps[index]
    if not (step and WorldMapFrame and WorldMapFrame:IsShown()) then return end
    -- A spell or an item: nothing to show on the map.
    if step.kind == "teleport" then self:Hide() return end
    if not overlay and not Build() then return end
    local mapID = MapOf(route, index)
    if not mapID then return end
    shownMap, shownIndex = mapID, index
    if WorldMapFrame.GetMapID and WorldMapFrame:GetMapID() ~= mapID and WorldMapFrame.SetMapID then
        pcall(WorldMapFrame.SetMapID, WorldMapFrame, mapID)
    end
    Draw()
end

-- A clicked step keeps its preview up; a hovered step shows in its place
-- while the cursor is on it, then the clicked one returns.
local pinned

function Preview:Toggle(index)
    if pinned == index then
        pinned = nil
        shownIndex = nil
        if overlay then overlay:Hide() end
    else
        pinned = index
        self:Show(index)
    end
end

function Preview:Hide()
    shownIndex = nil
    local route = Route()
    if pinned and route and route.steps and route.steps[pinned] then
        self:Show(pinned)
        return
    end
    if overlay then overlay:Hide() end
end

function Preview:Reset()
    pinned = nil
    shownIndex = nil
    if overlay then overlay:Hide() end
end

-- The canvas resizes with the zoom and the map can change under the
-- drawing: redraw while shown, lightly.
local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function(_, dt)
    if not (overlay and overlay:IsShown() and shownIndex) then return end
    since = since + dt
    if since < 0.1 then return end
    since = 0
    Draw()
end)
