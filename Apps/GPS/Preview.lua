-- EasyFind GPS: the route on the world map.
--
-- On whatever map is open, every leg of the route lying on it: the step
-- followed (or the one clicked) bright with a mark where it starts and
-- ends, the rest faint, the part walked faded. The map is never turned on
-- its own; a click on a step's number turns it to that step.
local ns = EasyFind and EasyFind._ns
if not ns then return end
local Preview = {}
ns.GPSPreview = Preview

local msqrt, macos, mceil, mmax, mmin = math.sqrt, math.acos, math.ceil, math.max, math.min
local CreateVector2D = CreateVector2D

-- Sizes in screen pixels; the canvas is drawn far larger than the screen
-- and shrinks with the zoom, so each is converted at draw time.
-- The line's drawn thickness by the GPS setting: its core is a third of it,
-- the rest a soft dark edge and a faint glow.
local LINE_SPANS = { thin = 7, normal = 10, thick = 14 }
local ROUND = 20                   -- how far back a bend is cut to round it
local MIN_TURN, MAX_TURN = math.rad(3), math.rad(12)
local UL, LL, UR, LR = 1, 2, 3, 4  -- the client's vertex order
local START = 36
local SYMBOL, WAY_SYMBOL = 20, 16  -- a step's end symbol; the whole route's, at each change of ride

local function px(v)
    return ns.UIToCanvas and ns.UIToCanvas(v) or v
end
-- Blue, as routing maps draw a route (red reads as traffic or danger); each
-- ride in a hue the parchment does not use. Every line is a colored core on
-- a soft dark edge with a faint glow, so it reads over land and sea alike.
local ROUTE_BLUE = { 0.25, 0.6, 1 }
local MODE_COLOR = { taxi = { 1, 0.55, 0.1 }, boat = { 0.1, 0.8, 0.72 }, ferry = { 0.1, 0.8, 0.72 },
                     zeppelin = { 0.72, 0.42, 1 }, skyship = { 0.72, 0.42, 1 }, tram = { 0.78, 0.78, 0.78 } }
-- The part of the route already walked, faded so it does not read as the way.
local PASSED_COLOR, PASSED_ALPHA = { 0.78, 0.8, 0.84 }, 0.45
local CASING, CASING_COLOR = 1.5, { 0.06, 0.05, 0.08 }
local TEX_DISC = "Interface\\AddOns\\EasyFind\\textures\\FilterButtonCircle"
local TEX_CORE = "Interface\\AddOns\\EasyFind_GPS\\textures\\route_core"
local TEX_EDGE = "Interface\\AddOns\\EasyFind_GPS\\textures\\route_edge"
local DEST = 26                    -- the destination's pin

local overlay, lines, marks, syms
local shownMap, shownIndex
local since = 0

local function Route() local g = ns and ns.GPS return g and g.CurrentRoute and g.CurrentRoute() end

local function Canvas()
    return WorldMapFrame and WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
end

local function Accent()
    return ROUTE_BLUE
end

local function Build()
    local canvas = Canvas()
    if not canvas then return false end
    overlay = CreateFrame("Frame", "EasyFindGPSPreview", canvas)
    overlay:SetAllPoints(canvas)
    overlay:SetFrameStrata("HIGH")
    overlay:SetFrameLevel(300)
    overlay:EnableMouse(false)
    lines = Preview.NewLines(overlay, "TOPLEFT")
    marks = { start = overlay:CreateTexture(nil, "OVERLAY", nil, 2), stop = overlay:CreateTexture(nil, "OVERLAY", nil, 3) }
    marks.start:SetTexture("Interface\\AddOns\\EasyFind_GPS\\textures\\beam_flare")
    marks.start:SetBlendMode("ADD")
    -- A step's end: a round stop on its own casing, the line running into it.
    marks.stop:SetTexture(TEX_DISC)
    marks.stopCasing = overlay:CreateTexture(nil, "OVERLAY", nil, 2)
    marks.stopCasing:SetTexture(TEX_DISC)
    marks.stopCasing:Hide()
    -- A portal's, flight master's or dock's spot: the map's own symbol.
    marks.symbol = overlay:CreateTexture(nil, "OVERLAY", nil, 4)
    marks.symbol:Hide()
    -- The journey's end: the GPS pin standing on it.
    marks.dest = overlay:CreateTexture(nil, "OVERLAY", nil, 5)
    marks.dest:SetTexture(ns.GPS_ICON_TEX)
    marks.dest:Hide()
    syms = {}
    overlay:Hide()
    return true
end

local function PortalAtlas()
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    return faction == "Horde" and "MagePortalHorde" or "MagePortalAlliance"
end


local function Sym(i)
    local t = syms[i]
    if not t then
        t = overlay:CreateTexture(nil, "OVERLAY", nil, 4)
        syms[i] = t
    end
    return t
end

local function SetSymbol(t, symbol, x, y, size)
    local atlas = type(symbol) == "string" and symbol:match("^atlas:(.+)$")
    if atlas then t:SetAtlas(atlas) else t:SetTexture(symbol) end
    t:ClearAllPoints()
    t:SetSize(size, size)
    t:SetPoint("CENTER", overlay, "TOPLEFT", x, y)
    t:Show()
end

local function Span()
    local db = EasyFind and EasyFind.db
    return LINE_SPANS[db and db.gpsLineWidth] or LINE_SPANS.normal
end
Preview.LINE_SPANS = LINE_SPANS

-- One stretch as a four-cornered strip in its box, each corner moved onto
-- its point: strips cut along the bends meet edge to edge, with no overlap
-- to darken and no gap to show.
local function Shape(t, parent, anchor, ulx, uly, llx, lly, urx, ury, lrx, lry)
    local x0, x1 = mmin(ulx, llx, urx, lrx), mmax(ulx, llx, urx, lrx)
    local y0, y1 = mmin(uly, lly, ury, lry), mmax(uly, lly, ury, lry)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", parent, anchor, x0, y1)
    t:SetSize(mmax(x1 - x0, 0.01), mmax(y1 - y0, 0.01))
    t:SetVertexOffset(UL, ulx - x0, uly - y1)
    t:SetVertexOffset(LL, llx - x0, lly - y0)
    t:SetVertexOffset(UR, urx - x1, ury - y1)
    t:SetVertexOffset(LR, lrx - x1, lry - y0)
end

-- Each point's offset to one side of the line, h away: square to the
-- stretch at the ends, along the bend's bisector (the miter) between, so
-- both edges of every strip run parallel to it.
local offX, offY = {}, {}
local function Offsets(line, m, h)
    local np = m / 2
    local pnx, pny
    for k = 1, np do
        local nx, ny = pnx, pny
        if k < np then
            local dx, dy = line[2 * k + 1] - line[2 * k - 1], line[2 * k + 2] - line[2 * k]
            local len = msqrt(dx * dx + dy * dy)
            if len > 0 then nx, ny = -dy / len, dx / len end
        end
        nx, ny = nx or 0, ny or 1
        local ax, ay = pnx or nx, pny or ny
        local mx, my = ax + nx, ay + ny
        local ml = msqrt(mx * mx + my * my)
        if ml < 1e-6 then
            offX[k], offY[k] = nx * h, ny * h
        else
            mx, my = mx / ml, my / ml
            local s = h / mmax(mx * nx + my * ny, 0.5)
            offX[k], offY[k] = mx * s, my * s
        end
        pnx, pny = nx, ny
    end
    return offX, offY
end
Preview._Offsets = Offsets   -- tests

-- A walk's corners rounded: each cut back up to r (half a side at most) and
-- run as a curve through the corner, in turns of MAX_TURN at most.
local bent = {}
local function RoundBends(pts, m, r)
    bent[1], bent[2] = pts[1], pts[2]
    local n = 2
    for v = 3, m - 3, 2 do
        local x, y = pts[v], pts[v + 1]
        local ax, ay, bx, by = x - pts[v - 2], y - pts[v - 1], pts[v + 2] - x, pts[v + 3] - y
        local la, lb = msqrt(ax * ax + ay * ay), msqrt(bx * bx + by * by)
        local turn = (la > 0 and lb > 0) and macos(mmax(-1, mmin(1, (ax * bx + ay * by) / (la * lb)))) or 0
        if turn < MIN_TURN then
            bent[n + 1], bent[n + 2] = x, y
            n = n + 2
        else
            local d = mmin(r, la / 2, lb / 2)
            local sx, sy, ex, ey = x - ax / la * d, y - ay / la * d, x + bx / lb * d, y + by / lb * d
            local steps = mmax(2, mceil(turn / MAX_TURN))
            for k = 0, steps do
                local t = k / steps
                local u = 1 - t
                bent[n + 1] = u * u * sx + 2 * u * t * x + t * t * ex
                bent[n + 2] = u * u * sy + 2 * u * t * y + t * t * ey
                n = n + 2
            end
        end
    end
    bent[n + 1], bent[n + 2] = pts[m - 1], pts[m]
    return bent, n + 2
end
Preview._RoundBends = RoundBends   -- tests

-- Route lines on a frame, in its pixels from anchor (y up): Begin, a Line
-- per piece, then Finish hides the strips left over.
local Lines = {}
Lines.__index = Lines

function Preview.NewLines(parent, anchor)
    return setmetatable({ parent = parent, anchor = anchor, pool = {}, n = 0 }, Lines)
end

function Lines:Begin() self.n = 0 end

-- Every edge under every core: a bend never lays one stretch's dark edge
-- over the next one's core.
function Lines:Strip()
    local n = self.n + 1
    self.n = n
    local s = self.pool[n]
    if not s then
        s = self.parent:CreateTexture(nil, "OVERLAY", nil, 1)
        s:SetTexture(TEX_CORE)
        s.edge = self.parent:CreateTexture(nil, "OVERLAY", nil, 0)
        s.edge:SetTexture(TEX_EDGE)
        s.pair = { s, s.edge }
        self.pool[n] = s
    end
    return s
end

-- A line through points (x, y pairs, m numbers), span wide, its bends cut
-- back up to round: points closer together than the line is wide add nothing.
local poly = {}
function Lines:Line(src, m, span, round, color, alpha)
    local gap, k = span * 0.4, 0
    for v = 1, m - 1, 2 do
        local x, y = src[v], src[v + 1]
        if k == 0 or v == m - 1 or msqrt((x - poly[k - 1]) ^ 2 + (y - poly[k]) ^ 2) >= gap then
            poly[k + 1], poly[k + 2] = x, y
            k = k + 2
        end
    end
    if k < 4 then return end
    local line, n = poly, k
    if n > 4 then line, n = RoundBends(poly, n, round) end
    local total = 0
    for v = 1, n - 3, 2 do total = total + msqrt((line[v + 2] - line[v]) ^ 2 + (line[v + 3] - line[v + 1]) ^ 2) end
    if total <= 2 then return end
    Offsets(line, n, span / 2)
    local parent, anchor = self.parent, self.anchor
    for j = 1, n / 2 - 1 do
        local x1, y1, x2, y2 = line[2 * j - 1], line[2 * j], line[2 * j + 1], line[2 * j + 2]
        if x1 ~= x2 or y1 ~= y2 then
            local ax, ay, bx, by = offX[j], offY[j], offX[j + 1], offY[j + 1]
            for _, t in ipairs(self:Strip().pair) do
                Shape(t, parent, anchor, x1 + ax, y1 + ay, x1 - ax, y1 - ay, x2 + bx, y2 + by, x2 - bx, y2 - by)
                t:SetVertexColor(color[1], color[2], color[3], alpha)
                t:Show()
            end
        end
    end
end

function Lines:Finish()
    local pool = self.pool
    for i = self.n + 1, #pool do
        pool[i]:Hide()
        pool[i].edge:Hide()
    end
end

function Lines:Hide()
    self.n = 0
    self:Finish()
end

Preview.PASSED_COLOR, Preview.PASSED_ALPHA = PASSED_COLOR, PASSED_ALPHA
Preview.MODE_COLOR, Preview.ROUTE_BLUE = MODE_COLOR, ROUTE_BLUE
Preview.Span = Span

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

-- Where a step starts: the previous step's landing, or where the route was
-- planned, or else the player.
local function StartOf(route, i)
    if i > 1 then return route.steps[i - 1].arrive end
    if route.from then return route.from end
    local get = ns.GPS and ns.GPS.PlayerWorldPos
    if get then
        local ci, wx, wy = get()
        if ci and wx then return { ci = ci, wx = wx, wy = wy } end
    end
    return nil
end

-- A flight or a crossing runs from where it is boarded to where it lands;
-- any other leg from the step before to the step's own spot.
local CROSSING = { taxi = true, boat = true, ferry = true, zeppelin = true, skyship = true, tram = true }
local function Ends(route, i)
    local step = route.steps[i]
    if CROSSING[step.kind] then return step.go or StartOf(route, i), step.arrive end
    return StartOf(route, i), step.go or step.arrive
end

-- The map's own symbol for what a leg ends at; a way to a flight master or
-- a dock takes the symbol of the step it leads into.
local SYMBOL_KEY = { taxi = "flightmaster", boat = "boat", ferry = "boat", zeppelin = "zeppelin", skyship = "zeppelin",
                     tram = "tram" }
local function SymbolOf(route, i)
    local step = route.steps[i]
    local nxt = route.steps[i + 1]
    local kind = (step.approach and nxt) and nxt.kind or step.kind
    if kind == "portal" then return "atlas:" .. PortalAtlas() end
    local icons = ns.MapSearchData and ns.MapSearchData.CATEGORY_ICONS
    return icons and SYMBOL_KEY[kind] and icons[SYMBOL_KEY[kind]] or nil
end

local function World(p)
    if p.wx and p.ci then return p.ci, p.wx, p.wy end
    local toWorld = ns.GPSRoute and ns.GPSRoute.WorldPos
    if p.m and toWorld then return toWorld(p.m, p.x, p.y) end
    return nil
end

-- A walked leg's way on foot in world yards and its continent, or nothing
-- without one. Kept per step until its start moves.
local walks = {}
local function WalkWorld(route, i, start, target)
    local find = ns.GPSRoute and ns.GPSRoute.WalkPath
    if not (find and start and target) then return nil end
    local ci, sx, sy = World(start)
    local ci2, tx, ty = World(target)
    if not (ci and ci2 and ci == ci2) then return nil end
    local key = math.floor(sx / 25) * 1e5 + math.floor(sy / 25)
    local c = walks[i]
    if not (c and c.route == route and c.key == key) then
        c = { route = route, key = key, ci = ci, path = find(ci, sx, sy, tx, ty) or false }
        walks[i] = c
    end
    if not c.path then return nil end
    return c.path, c.ci
end

-- World yards to the shown map's fractions, from three of its corners.
local affines = {}
local function Affine(mapID)
    local a = affines[mapID]
    if a ~= nil then return a end
    a = false
    local toWorld = ns.GPSRoute and ns.GPSRoute.WorldPos
    if toWorld then
        local c0, x0, y0 = toWorld(mapID, 0, 0)
        local c1, x1, y1 = toWorld(mapID, 1, 0)
        local c2, x2, y2 = toWorld(mapID, 0, 1)
        if c0 and c0 == c1 and c0 == c2 then
            local ux, uy, vx, vy = x1 - x0, y1 - y0, x2 - x0, y2 - y0
            local det = ux * vy - vx * uy
            if det ~= 0 then a = { ci = c0, x0 = x0, y0 = y0, ux = ux, uy = uy, vx = vx, vy = vy, det = det } end
        end
    end
    affines[mapID] = a
    return a
end

local function Frac(a, wx, wy)
    local dx, dy = wx - a.x0, wy - a.y0
    return (dx * a.vy - a.vx * dy) / a.det, (a.ux * dy - dx * a.uy) / a.det
end

-- The part of segment (x0, y0)-(x1, y1) on the map, as t0, t1; or nil.
local function Edge(p, q, t0, t1)
    if p == 0 then
        if q < 0 then return nil end
        return t0, t1
    end
    local t = q / p
    if p < 0 then t0 = mmax(t0, t) else t1 = mmin(t1, t) end
    if t0 > t1 then return nil end
    return t0, t1
end

local function OnMap(x0, y0, x1, y1)
    local dx, dy = x1 - x0, y1 - y0
    local t0, t1 = Edge(-dx, x0, 0, 1)
    if t0 then t0, t1 = Edge(dx, 1 - x0, t0, t1) end
    if t0 then t0, t1 = Edge(-dy, y0, t0, t1) end
    if t0 then t0, t1 = Edge(dy, 1 - y0, t0, t1) end
    return t0, t1
end
Preview._OnMap = OnMap   -- tests

-- The line being traced, in map fractions: the parts on the map handed to
-- the drawer in canvas pixels, a piece at a time.
local legPts = {}
local pen = { n = 0 }

local function PenUp()
    if pen.n >= 4 then lines:Line(legPts, pen.n, pen.span, pen.round, pen.color, pen.alpha) end
    pen.n = 0
end

local function Pen(color, alpha)
    PenUp()
    pen.color, pen.alpha, pen.x = color, alpha, nil
end

local function PenTo(x, y)
    local x0, y0 = pen.x, pen.y
    pen.x, pen.y = x, y
    if not x0 then return end
    local t0, t1 = OnMap(x0, y0, x, y)
    if not t0 then return PenUp() end
    local cw, ch, n = pen.cw, pen.ch, pen.n
    if t0 > 0 or n == 0 then
        PenUp()
        legPts[1], legPts[2] = (x0 + (x - x0) * t0) * cw, -(y0 + (y - y0) * t0) * ch
        n = 2
    end
    legPts[n + 1], legPts[n + 2] = (x0 + (x - x0) * t1) * cw, -(y0 + (y - y0) * t1) * ch
    pen.n = n + 2
    if t1 < 1 then PenUp() end
end

-- A clicked step stays the one shown; with none clicked it is the step
-- being followed. false: none, until the map opens or the route moves on.
local pinned

local function Following()
    local route = Route()
    return route and route.steps and not route.arrived and (route.active or 1) or nil
end

local function Shown()
    if pinned == false then return nil end
    return pinned or Following()
end

-- What the last drawing was taken from: the same again draws nothing.
local drawn = {}
local dirty = true

local function Draw()
    local route = Route()
    local canvas = Canvas()
    local mapID = WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
    if not (route and canvas and mapID) then
        if overlay then overlay:Hide() end
        drawn.route = nil
        return
    end
    if not overlay and not Build() then return end
    shownMap, shownIndex = mapID, Shown()
    local span, round = px(Span()), px(ROUND)
    local cw, ch = canvas:GetWidth(), canvas:GetHeight()
    local active = route.arrived and #route.steps + 1 or (route.active or 1)
    local affine = Affine(mapID)
    local f = ns.GPSFollow and ns.GPSFollow.Now()
    if f and not (f.route == route and f.path and affine and affine.ci == f.ci) then f = nil end
    local qx, qy
    if f then
        qx, qy = Frac(affine, f.qx, f.qy)
        qx, qy = qx * cw, qy * ch
    end
    if not dirty and drawn.route == route and drawn.map == mapID and drawn.span == span and drawn.cw == cw
        and drawn.ch == ch and drawn.shown == shownIndex and drawn.active == active
        and drawn.seg == (f and f.seg) and (not qx or (qx - drawn.qx) ^ 2 + (qy - drawn.qy) ^ 2 < px(0.5) ^ 2) then
        return
    end
    dirty = false
    drawn.route, drawn.map, drawn.span, drawn.cw, drawn.ch = route, mapID, span, cw, ch
    drawn.shown, drawn.active, drawn.seg, drawn.qx, drawn.qy = shownIndex, active, f and f.seg, qx, qy
    local accent = Accent()
    local nSym = 0
    local hovered
    local lineW = span * 0.4
    pen.span, pen.round, pen.cw, pen.ch, pen.n = span, round, cw, ch, 0
    lines:Begin()
    -- Index 0 is the whole route: every leg bright, one arrowhead at its end.
    local all = shownIndex == 0
    for i = 1, #route.steps do
        local step = route.steps[i]
        -- A teleport draws nothing: nothing is walked, and the legs after
        -- it start from where it lands.
        local teleport = step.kind == "teleport"
        local start, target = Ends(route, i)
        local a = (not teleport) and OnCanvas(start, mapID) or nil
        local b = (not teleport) and OnCanvas(target, mapID) or nil
        if not teleport then
            local bright = all or i == shownIndex
            local color, alpha = MODE_COLOR[step.kind] or accent, bright and 0.95 or 0.4
            -- A leg already behind reads as walked, unless it is the one looked at.
            if i < active and not (i == shownIndex and not all) then color, alpha = PASSED_COLOR, PASSED_ALPHA end
            if f and i == f.index then
                -- Cut where the player stands: the part walked faded.
                local pts, seg = f.path.pts, f.seg
                Pen(PASSED_COLOR, PASSED_ALPHA)
                for v = 1, seg do PenTo(Frac(affine, pts[2 * v - 1], pts[2 * v])) end
                PenTo(Frac(affine, f.qx, f.qy))
                Pen(color, alpha)
                PenTo(Frac(affine, f.qx, f.qy))
                for v = seg + 1, #pts / 2 do PenTo(Frac(affine, pts[2 * v - 1], pts[2 * v])) end
            elseif affine then
                -- Its way on foot for a walk, straight otherwise; drawn where
                -- it lies on this map.
                Pen(color, alpha)
                local path, pci
                if step.kind == "travel" then path, pci = WalkWorld(route, i, start, target) end
                if path and pci == affine.ci then
                    local pts = path.pts
                    for v = 1, #pts / 2 do PenTo(Frac(affine, pts[2 * v - 1], pts[2 * v])) end
                elseif start and target then
                    local sci, sx, sy = World(start)
                    local tci, tx, ty = World(target)
                    if sci == affine.ci and tci == affine.ci then
                        PenTo(Frac(affine, sx, sy))
                        PenTo(Frac(affine, tx, ty))
                    end
                end
            elseif a and b then
                -- A map over more than one continent: its ends joined.
                PenUp()
                legPts[1], legPts[2], legPts[3], legPts[4] = a[1], a[2], b[1], b[2]
                lines:Line(legPts, 4, span, round, color, alpha)
            end
        end
        -- The whole route marks each change of ride with its symbol.
        local wayStop = all and not step.approach and SymbolOf(route, i)
        local at = wayStop and (CROSSING[step.kind] and a or b)
        if at then
            nSym = nSym + 1
            SetSymbol(Sym(nSym), wayStop, at[1], at[2], px(WAY_SYMBOL))
        end
        if all and a and b then
            -- From where the first leg starts to where the last one ends.
            hovered = hovered or { a = a }
            hovered.b, hovered.target, hovered.step = b, target, step
            hovered.final = i == #route.steps
        elseif i == shownIndex then
            hovered = { a = a, b = b, target = target, step = step, symbol = SymbolOf(route, i),
                        final = i == #route.steps, color = MODE_COLOR[step.kind] or accent }
        end
    end
    PenUp()
    lines:Finish()
    for i = nSym + 1, #syms do syms[i]:Hide() end
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
    local symbol = hovered and hovered.symbol
    marks.dest:Hide()
    marks.stopCasing:Hide()
    if hovered and hovered.b and hovered.final then
        -- The journey's end: the GPS pin with its tip on the spot.
        marks.stop:Hide()
        marks.symbol:Hide()
        marks.dest:ClearAllPoints()
        marks.dest:SetSize(px(DEST), px(DEST))
        marks.dest:SetPoint("BOTTOM", overlay, "TOPLEFT", hovered.b[1], hovered.b[2])
        marks.dest:SetVertexColor(unpack(ns.GOLD_COLOR))
        marks.dest:Show()
    elseif hovered and hovered.b and symbol then
        -- A portal, flight master or dock: the map's symbol on its spot, no arrow.
        marks.stop:Hide()
        SetSymbol(marks.symbol, symbol, hovered.b[1], hovered.b[2], px(SYMBOL))
    elseif hovered and hovered.b then
        marks.symbol:Hide()
        local c, d = hovered.color or accent, lineW * 2.2
        marks.stop:ClearAllPoints()
        marks.stop:SetSize(d, d)
        marks.stop:SetPoint("CENTER", overlay, "TOPLEFT", hovered.b[1], hovered.b[2])
        marks.stop:SetVertexColor(c[1], c[2], c[3], 1)
        marks.stop:Show()
        marks.stopCasing:ClearAllPoints()
        marks.stopCasing:SetSize(d + 2 * px(CASING), d + 2 * px(CASING))
        marks.stopCasing:SetPoint("CENTER", overlay, "TOPLEFT", hovered.b[1], hovered.b[2])
        marks.stopCasing:SetVertexColor(CASING_COLOR[1], CASING_COLOR[2], CASING_COLOR[3], 0.9)
        marks.stopCasing:Show()
    else
        marks.stop:Hide()
        marks.symbol:Hide()
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
    local start, target = Ends(route, index)
    local mapID = step.mapID or (target and target.m)
    if not mapID then return nil end
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

-- Index 0 is the whole route: the smallest map holding its start and end.
local function TargetMap(route, index)
    if index ~= 0 then return MapOf(route, index) end
    local last = route.steps[#route.steps]
    local target = last and (last.go or last.arrive)
    local mapID = last and (last.mapID or (target and target.m))
    local start = StartOf(route, 1)
    local m, depth = mapID, 0
    while start and m and depth < 8 do
        if Falls(start, m) and Falls(target, m) then return m end
        local info = C_Map.GetMapInfo and C_Map.GetMapInfo(m)
        if not info or not info.parentMapID or info.parentMapID == 0 or (info.mapType and info.mapType <= 1) then break end
        m = info.parentMapID
        depth = depth + 1
    end
    return mapID
end

-- The route moved on or the map opened: the followed step is shown again
-- unless another is clicked. The map stays where it is.
function Preview:Follow()
    if pinned == false then pinned = nil end
    dirty = true
end

-- A click on a step's number turns the map to that step and shows it; a
-- click on the step shown, its map up, puts it away.
function Preview:Toggle(index)
    local route = Route()
    if not (route and route.steps and (index == 0 or route.steps[index])) then return end
    local mapID = TargetMap(route, index)
    local here = WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
    local followed = Following()
    if Shown() == index and (not mapID or here == mapID) then
        if pinned == index and index ~= followed then pinned = nil else pinned = false end
    else
        if index == followed then pinned = nil else pinned = index end
        if mapID and here ~= mapID and WorldMapFrame.SetMapID then pcall(WorldMapFrame.SetMapID, WorldMapFrame, mapID) end
    end
    dirty = true
    Draw()
end

function Preview:Reset()
    pinned = nil
    shownIndex = nil
    dirty = true
    if overlay then overlay:Hide() end
end

-- The canvas resizes with the zoom, the map changes under the drawing and
-- the walked part grows: looked at while the map is open, drawn on change.
local driver = CreateFrame("Frame")
Preview._driver = driver   -- dev tools
local function Tick(_, dt)
    since = since + dt
    if since < 0.1 then return end
    since = 0
    Draw()
end
if WorldMapFrame then
    WorldMapFrame:HookScript("OnShow", function()
        Preview:Follow()
        since = 0.1
        driver:SetScript("OnUpdate", Tick)
    end)
    WorldMapFrame:HookScript("OnHide", function() driver:SetScript("OnUpdate", nil) end)
end

-- For the dev tools: what a step's preview would draw, and where it stops.
function Preview:Status(index)
    local out = {}
    local function P(p)
        if not p then return "nil" end
        return string.format("m %s %.3f,%.3f ci %s world %s,%s", tostring(p.m), p.x or -1, p.y or -1, tostring(p.ci),
            tostring(p.wx and math.floor(p.wx)), tostring(p.wy and math.floor(p.wy)))
    end
    local route = Route()
    local frameMap = WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
    out[#out + 1] = string.format("route %s, %s steps | shown index %s pinned %s map %s | world map shown %s on map %s | overlay %s",
        tostring(route ~= nil), tostring(route and route.steps and #route.steps), tostring(shownIndex), tostring(pinned),
        tostring(shownMap), tostring(WorldMapFrame and WorldMapFrame:IsShown()), tostring(frameMap),
        tostring(overlay and overlay:IsShown()))
    local step = route and route.steps and index and route.steps[index]
    if not step then
        out[#out + 1] = "no step " .. tostring(index)
        return out
    end
    local start, target = Ends(route, index)
    local mapID = MapOf(route, index)
    out[#out + 1] = string.format("step %d %s: start %s | target %s", index, tostring(step.kind), P(start), P(target))
    local a, b = mapID and OnCanvas(start, mapID), mapID and OnCanvas(target, mapID)
    local way = step.kind == "travel" and WalkWorld(route, index, start, target)
    out[#out + 1] = string.format("map %s: start on it %s, target on it %s, walk points %s", tostring(mapID),
        a and string.format("%.0f,%.0f", a[1], a[2]) or "no", b and string.format("%.0f,%.0f", b[1], b[2]) or "no",
        way and tostring(#way.pts / 2) or "none")
    return out
end
