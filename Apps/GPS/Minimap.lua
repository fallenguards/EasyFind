-- EasyFind GPS: the route on the minimap.
--
-- The route drawn on the minimap as on the world map: the way ahead in
-- its colors, what was already walked faded, turning with the minimap
-- when it turns. Cut at the rim and around the player's own arrow.
local ns = EasyFind and EasyFind._ns
if not ns then return end
local Mini = {}
ns.GPSMinimap = Mini

local msqrt, mmax, mmin, mabs, mcos, msin = math.sqrt, math.max, math.min, math.abs, math.cos, math.sin

local THROTTLE = 0.05
local MOVE_PX, TURN = 0.5, 0.01 -- moved or turned less than this: drawn as it was
local SCALE = 0.7              -- the line's width against the world map's
local ROUND = 6                -- how far back a bend is cut to round it, in pixels
local HOLE = 7                 -- pixels kept clear around the player's arrow
local ALPHA = 0.9
-- The step's spot: a disc in the step's color on its dark rim, where the
-- game sets no waypoint (Era, TBC) and so shows no blip of its own there.
local TEX_DISC = "Interface\\AddOns\\EasyFind\\textures\\FilterButtonCircle"
local MARK, CASING, CASING_COLOR = 12, 2, { 0.06, 0.05, 0.08 }
local OWN_MARK = not (C_Map and C_Map.SetUserWaypoint)

local frame, lines, driver, mark
local since = 0
local version = 0              -- bumped on every route change
local drawn = {}               -- what the last drawing was taken from
local legs = {}                -- per step: its way on foot
local view = {}                -- this drawing: player, axes, scale, turn, rim, width

local function DB() return EasyFind and EasyFind.db end
local function Route() local g = ns.GPS return g and g.CurrentRoute and g.CurrentRoute() end
local function Enabled() local db = DB() return not (db and db.gpsMinimap == false) end

-- The part of segment a-b within r of the middle, as t0, t1; or nil.
local function InCircle(ax, ay, bx, by, r)
    local dx, dy = bx - ax, by - ay
    local A, B, C = dx * dx + dy * dy, ax * dx + ay * dy, ax * ax + ay * ay - r * r
    if A == 0 then return nil end
    local disc = B * B - A * C
    if disc <= 0 then return nil end
    local s = msqrt(disc)
    local t0, t1 = (-B - s) / A, (-B + s) / A
    if t1 <= 0 or t0 >= 1 then return nil end
    return mmax(0, t0), mmin(1, t1)
end

local function Cut(p, q, t0, t1)
    if not t0 then return nil end
    if p == 0 then
        if q < 0 then return nil end
        return t0, t1
    end
    local t = q / p
    if p < 0 then t0 = mmax(t0, t) else t1 = mmin(t1, t) end
    if t0 > t1 then return nil end
    return t0, t1
end

local function InSquare(ax, ay, bx, by, r)
    local dx, dy = bx - ax, by - ay
    local t0, t1 = Cut(-dx, ax + r, 0, 1)
    t0, t1 = Cut(dx, r - ax, t0, t1)
    t0, t1 = Cut(-dy, ay + r, t0, t1)
    return Cut(dy, r - ay, t0, t1)
end

-- Pieces of the line being traced that show: points in minimap pixels from
-- its middle, handed to the drawer a piece at a time.
local piece, pn = {}, 0
local penColor, penAlpha, lastX, lastY

local function Flush()
    if pn >= 4 then lines:Line(piece, pn, view.span, ROUND, penColor, penAlpha) end
    pn = 0
end

local function Run(ax, ay, bx, by, t0, t1)
    if t0 > 0 or pn == 0 then
        Flush()
        piece[1], piece[2] = ax + (bx - ax) * t0, ay + (by - ay) * t0
        pn = 2
    end
    piece[pn + 1], piece[pn + 2] = ax + (bx - ax) * t1, ay + (by - ay) * t1
    pn = pn + 2
    if t1 < 1 then Flush() end
end

local function Segment(ax, ay, bx, by)
    local t0, t1
    if view.square then t0, t1 = InSquare(ax, ay, bx, by, view.rim) else t0, t1 = InCircle(ax, ay, bx, by, view.rim) end
    if not t0 then Flush() return end
    local h0, h1 = InCircle(ax, ay, bx, by, HOLE)
    if h0 and h0 < t1 and h1 > t0 then
        if h0 > t0 then Run(ax, ay, bx, by, t0, h0) end
        Flush()
        if h1 < t1 then Run(ax, ay, bx, by, h1, t1) end
    else
        Run(ax, ay, bx, by, t0, t1)
    end
end

local function Pen(color, alpha)
    Flush()
    penColor, penAlpha, lastX = color, alpha, nil
end

-- A world point in minimap pixels from its middle, turned with the minimap.
local function Pixel(wx, wy)
    local a, dx, dy = view.axes, wx - view.px, wy - view.py
    local x = -(dx * a[3] + dy * a[4]) * view.k
    local y = (dx * a[1] + dy * a[2]) * view.k
    return x * view.cos - y * view.sin, x * view.sin + y * view.cos
end

-- The next point of the line being traced, in world yards.
local function To(wx, wy)
    local x, y = Pixel(wx, wy)
    if lastX then Segment(lastX, lastY, x, y) end
    lastX, lastY = x, y
end

-- The step's spot marked, within the rim and clear of the player's arrow.
local function PlaceMark(route, ci)
    local Follow = ns.GPSFollow
    local step = route.steps[route.active or 1]
    local target = step and step.kind ~= "teleport" and (Follow.RIDES[step.kind] and step.arrive or (step.go or step.arrive))
    local tci, tx, ty
    if target then tci, tx, ty = Follow.World(target) end
    if tci ~= ci then mark:Hide() return end
    local x, y = Pixel(tx, ty)
    local r = view.rim
    local inside = view.square and (mabs(x) <= r and mabs(y) <= r) or (x * x + y * y <= r * r)
    if not inside or x * x + y * y < HOLE * HOLE then mark:Hide() return end
    local c = ns.GPSPreview.LineColor(step.kind)
    mark.disc:SetVertexColor(c[1], c[2], c[3], 1)
    mark:ClearAllPoints()
    mark:SetPoint("CENTER", frame, "CENTER", x, y)
    mark:Show()
end

-- Trace's pen here: the leg's own color, red where deadly.
local traceColor, traceAlpha
local function TracePen(red)
    Pen(red and ns.GPSPreview.DANGER_COLOR or traceColor, traceAlpha)
end

local function Walk(route, i, ci, sci, sx, sy, tx, ty)
    local c = legs[i]
    if c and c.route == route and c.sx == sx and c.sy == sy and c.tx == tx and c.ty == ty then return c.path end
    local find = ns.GPSRoute and ns.GPSRoute.WalkPath
    local path = sci == ci and find and find(ci, sx, sy, tx, ty, true)
    -- Not drawn yet: asked again next time, straight meanwhile.
    if path == nil and sci == ci then return nil end
    path = path or false
    legs[i] = { route = route, sx = sx, sy = sy, tx = tx, ty = ty, path = path }
    return path
end

local function Hide()
    if lines then lines:Hide() end
    if mark then mark:Hide() end
    drawn.at = nil
end

-- Era, TBC and Mists have no view radius call: the minimap's reach in
-- yards per zoom level instead, as retail reports it (/efd gpsmm,
-- 2026-10-27; its zoom 1 to 5 are these 0 to 4, its zoom 0 reaches
-- farther). The last level carries the step on, unmeasured.
local ZOOM_RADIUS = {
    outdoors = { 233.33, 200, 166.67, 133.33, 100, 66.67 },
    indoors = { 150, 120, 90, 60, 40, 25 },
}
local function ViewRadius()
    if C_Minimap and C_Minimap.GetViewRadius then return C_Minimap.GetViewRadius() end
    local set = ZOOM_RADIUS[(IsIndoors and IsIndoors()) and "indoors" or "outdoors"]
    return set[(Minimap.GetZoom and Minimap:GetZoom() or 0) + 1]
end

local function Draw()
    local route = Route()
    local Follow = ns.GPSFollow
    local ci, px, py = ns.GPS.PlayerWorldPos()
    local radius = ViewRadius()
    local half = Minimap:GetWidth() / 2
    local axes = ci and Follow.Axes(ci)
    if not (route and axes and radius and radius > 0 and half > 0 and Minimap:IsVisible()) then return Hide() end
    local turn = 0
    if GetCVarBool and GetCVarBool("rotateMinimap") then
        turn = GetPlayerFacing and GetPlayerFacing()
        if not turn or (issecretvalue and issecretvalue(turn)) then return Hide() end
    end
    local k = half / radius
    if drawn.at and drawn.version == version and drawn.radius == radius and drawn.half == half
        and ((px - drawn.px) ^ 2 + (py - drawn.py) ^ 2) * k * k < MOVE_PX * MOVE_PX
        and mabs(turn - drawn.turn) < TURN then return end
    drawn.at, drawn.px, drawn.py, drawn.turn, drawn.radius, drawn.half, drawn.version = true, px, py, turn, radius, half, version
    local span = ns.GPSPreview.Span() * SCALE
    view.px, view.py, view.axes, view.k, view.span = px, py, axes, k, span
    view.cos, view.sin = mcos(-turn), msin(-turn)
    view.square = GetMinimapShape and GetMinimapShape() == "SQUARE"
    view.rim = half - span / 2 - 1
    local Preview = ns.GPSPreview
    local passed, passedAlpha = Preview.PASSED_COLOR, Preview.PASSED_ALPHA
    local active = route.arrived and #route.steps + 1 or (route.active or 1)
    local f = Follow.Now()
    if f and not (f.route == route and f.path) then f = nil end
    lines:Begin()
    for i = 1, #route.steps do
        local step = route.steps[i]
        if step.kind ~= "teleport" then
            local color = i < active and passed or Preview.LineColor(step.kind)
            local alpha = i < active and passedAlpha or ALPHA
            if f and i == f.index then
                -- Off the walk with no way back on foot (none from here, a
                -- room the grid has no door to): straight back onto it, as
                -- the arrow points.
                if f.off > Follow.OFF_WAY then
                    Pen(color, alpha)
                    To(f.px, f.py)
                    To(f.qx, f.qy)
                end
                local pts, seg = f.path.pts, f.seg
                Pen(passed, passedAlpha)
                for v = 1, seg do To(pts[2 * v - 1], pts[2 * v]) end
                To(f.qx, f.qy)
                traceColor, traceAlpha = color, alpha
                Preview.Trace(f.path, f.ci, seg, f.qx, f.qy, f.along, TracePen, To)
            else
                local sci, sx, sy, tci, tx, ty
                if Follow.RIDES[step.kind] then
                    sci, sx, sy = Follow.World(step.go)
                    tci, tx, ty = Follow.World(step.arrive)
                else
                    sci, sx, sy = Follow.StartOf(route, i)
                    tci, tx, ty = Follow.World(step.go or step.arrive)
                end
                if sci == ci and tci == ci then
                    Pen(color, alpha)
                    local path = step.kind == "travel" and not step.fly and Walk(route, i, ci, sci, sx, sy, tx, ty)
                    if path then
                        local pts = path.pts
                        traceColor, traceAlpha = color, alpha
                        Preview.Trace(path, i >= active and ci or nil, 1, pts[1], pts[2], 0, TracePen, To)
                    else
                        To(sx, sy)
                        To(tx, ty)
                    end
                end
            end
        end
    end
    Flush()
    lines:Finish()
    if mark then PlaceMark(route, ci) end
end
Mini._Draw = Draw   -- tests

local function Tick(_, dt)
    since = since + dt
    if since < THROTTLE then return end
    since = 0
    Draw()
end

local function Build()
    frame = CreateFrame("Frame", "EasyFindGPSMinimap", Minimap)
    frame:SetAllPoints(Minimap)
    frame:EnableMouse(false)
    lines = ns.GPSPreview.NewLines(frame, "CENTER")
    if not OWN_MARK then return end
    mark = CreateFrame("Frame", nil, frame)
    mark:SetWidth(MARK + 2 * CASING)
    mark:SetHeight(MARK + 2 * CASING)
    local casing = mark:CreateTexture(nil, "OVERLAY", nil, 1)
    casing:SetTexture(TEX_DISC)
    casing:SetAllPoints(mark)
    casing:SetVertexColor(CASING_COLOR[1], CASING_COLOR[2], CASING_COLOR[3], 0.9)
    mark.disc = mark:CreateTexture(nil, "OVERLAY", nil, 2)
    mark.disc:SetTexture(TEX_DISC)
    mark.disc:SetWidth(MARK)
    mark.disc:SetHeight(MARK)
    mark.disc:SetPoint("CENTER", mark, "CENTER", 0, 0)
    mark:Hide()
    Mini._mark = mark   -- tests
end

-- A route change or the option flipped: drawn only while a route is followed.
function Mini:Refresh()
    version = version + 1
    local route = Route()
    local on = Enabled() and Minimap ~= nil and ns.GPSPreview ~= nil and route ~= nil and not route.arrived
        and not route.untracked
    if on then
        if not frame then Build() end
        since = 0
        driver:SetScript("OnUpdate", Tick)
        Draw()
    else
        driver:SetScript("OnUpdate", nil)
        Hide()
    end
end

driver = CreateFrame("Frame")
Mini._driver = driver   -- dev tools
