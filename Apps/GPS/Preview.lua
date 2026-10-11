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

local matan2, msqrt = math.atan2, math.sqrt
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

local overlay, pool, solids, marks
local shownMap, shownIndex
local since = 0

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
    solids = {}
    marks = { start = overlay:CreateTexture(nil, "OVERLAY", nil, 2), stop = overlay:CreateTexture(nil, "OVERLAY", nil, 3) }
    marks.start:SetTexture("Interface\\AddOns\\EasyFind_GPS\\textures\\beam_flare")
    marks.start:SetBlendMode("ADD")
    marks.stop:SetTexture(TEX_ARROW)
    -- A portal's, flight master's or dock's spot: the map's own symbol, pulsing.
    local symbol = overlay:CreateTexture(nil, "OVERLAY", nil, 4)
    marks.symbol = symbol
    local pulse = symbol:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local grow = pulse:CreateAnimation("Scale")
    grow:SetScaleFrom(1, 1)
    grow:SetScaleTo(1.3, 1.3)
    grow:SetDuration(0.5)
    grow:SetSmoothing("IN_OUT")
    pulse:Play()
    symbol:Hide()
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

local function Solid(i)
    local s = solids[i]
    if not s then
        s = overlay:CreateLine(nil, "OVERLAY", nil, 1)
        solids[i] = s
    end
    return s
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

-- A walked leg's way over the roads as map points (x, y in pairs), or
-- nothing when no road helps. Kept per step until its start moves.
local roads = {}
local function RoadPoints(route, i, start, target, mapID)
    local find = ns.GPSRoute and ns.GPSRoute.RoadPath
    if not (find and ns.GPSData and start and target) then return nil end
    local ci, sx, sy = World(start)
    local ci2, tx, ty = World(target)
    if not (ci and ci2 and ci == ci2) then return nil end
    local key = mapID * 1e6 + math.floor(sx / 25) * 1e3 + math.floor(sy / 25)
    local c = roads[i]
    if c and c.route == route and c.key == key then return c.pts or nil end
    c = { route = route, key = key, pts = false }
    roads[i] = c
    local path = find(ns.GPSData, ci, sx, sy, tx, ty)
    if not path then return nil end
    local pts, k = {}, 0
    for v = 1, #path.pts / 2 do
        local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, ci, CreateVector2D(path.pts[2 * v - 1], path.pts[2 * v]), mapID)
        if ok and pos then
            local x, y = pos:GetXY()
            if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
                pts[k + 1], pts[k + 2] = x, y
                k = k + 2
            end
        end
    end
    if k < 4 then return nil end
    c.pts = pts
    return pts
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
    local n, nSolid = 0, 0
    local hovered
    local lineW, dash, gap, arrow = px(LINE_W), px(DASH), px(GAP), px(ARROW)
    local cw, ch = canvas:GetWidth(), canvas:GetHeight()
    local poly = {}
    -- Index 0 is the whole route: every leg bright, one arrowhead at its end.
    local all = shownIndex == 0
    for i = 1, #route.steps do
        local step = route.steps[i]
        -- A teleport draws nothing: nothing is walked, and the legs after
        -- it start from where it lands.
        local teleport = step.kind == "teleport"
        local start, target = Ends(route, i)
        local a = (not teleport) and OnCanvas(start, shownMap) or nil
        local b = (not teleport) and OnCanvas(target, shownMap) or nil
        local lastDx, lastDy
        if a and b then
            -- The leg's line: along the roads for a walk, straight otherwise.
            local road = step.kind == "travel" and RoadPoints(route, i, start, target, shownMap)
            local m = 0
            if road then
                -- Points closer together than the line is wide add nothing.
                local last = #road - 1
                for v = 1, last, 2 do
                    local x, y = road[v] * cw, -road[v + 1] * ch
                    if m == 0 or v == last or msqrt((x - poly[m - 1]) ^ 2 + (y - poly[m]) ^ 2) >= lineW then
                        poly[m + 1], poly[m + 2] = x, y
                        m = m + 2
                    end
                end
            else
                poly[1], poly[2], poly[3], poly[4] = a[1], a[2], b[1], b[2]
                m = 4
            end
            local total = 0
            for v = 1, m - 3, 2 do
                total = total + msqrt((poly[v + 2] - poly[v]) ^ 2 + (poly[v + 3] - poly[v + 1]) ^ 2)
            end
            if total > 2 then
                local bright = all or i == shownIndex
                local alpha = bright and 0.95 or 0.4
                -- The line stops short of the arrowhead; a symbol sits on
                -- its spot, so the line runs to it.
                local headed = (all and i == #route.steps) or (i == shownIndex and not SymbolOf(route, i))
                local usable = total - (headed and arrow * 0.9 or 0)
                if step.kind == "travel" then
                    -- A walk: one solid line, stretch by stretch.
                    local walked = 0
                    for v = 1, m - 3, 2 do
                        local x1, y1, x2, y2 = poly[v], poly[v + 1], poly[v + 2], poly[v + 3]
                        local dx, dy = x2 - x1, y2 - y1
                        local len = msqrt(dx * dx + dy * dy)
                        if len > 0 and walked < usable then
                            lastDx, lastDy = dx, dy
                            if walked + len > usable then
                                local f = (usable - walked) / len
                                x2, y2 = x1 + dx * f, y1 + dy * f
                            end
                            nSolid = nSolid + 1
                            local s = Solid(nSolid)
                            s:SetThickness(lineW * 0.8)
                            s:SetStartPoint("TOPLEFT", overlay, x1, y1)
                            s:SetEndPoint("TOPLEFT", overlay, x2, y2)
                            s:SetColorTexture(accent[1], accent[2], accent[3], alpha)
                            s:Show()
                        end
                        walked = walked + len
                    end
                else
                    -- A flight or a crossing: dashes along the straight leg.
                    local x1, y1, dx, dy = poly[1], poly[2], poly[3] - poly[1], poly[4] - poly[2]
                    local ux, uy = dx / total, dy / total
                    local angle = matan2(dy, dx)
                    lastDx, lastDy = dx, dy
                    local pos = 0
                    while pos < usable do
                        local d = dash
                        if pos + d > usable then d = usable - pos end
                        if d > 1 then
                            n = n + 1
                            local t = Line(n)
                            t:ClearAllPoints()
                            t:SetSize(d, lineW)
                            t:SetPoint("CENTER", overlay, "TOPLEFT", x1 + ux * (pos + d / 2), y1 + uy * (pos + d / 2))
                            t:SetRotation(angle)
                            t:SetVertexColor(accent[1], accent[2], accent[3], alpha)
                            t:Show()
                        end
                        pos = pos + dash + gap
                    end
                end
            end
        end
        if all and a and b then
            -- From where the first leg starts to where the last one ends.
            hovered = hovered or { a = a }
            hovered.b, hovered.target, hovered.step, hovered.dx, hovered.dy = b, target, step, lastDx, lastDy
        elseif i == shownIndex then
            hovered = { a = a, b = b, target = target, step = step, dx = lastDx, dy = lastDy, symbol = SymbolOf(route, i) }
        end
    end
    for i = n + 1, #pool do pool[i]:Hide() end
    for i = nSolid + 1, #solids do solids[i]:Hide() end
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
    if hovered and hovered.b and symbol then
        -- A portal, flight master or dock: the map's symbol pulsing on its spot, no arrow.
        marks.stop:Hide()
        local size = px(ARROW) * 1.2
        local atlas = type(symbol) == "string" and symbol:match("^atlas:(.+)$")
        if atlas then marks.symbol:SetAtlas(atlas) else marks.symbol:SetTexture(symbol) end
        marks.symbol:ClearAllPoints()
        marks.symbol:SetSize(size, size)
        marks.symbol:SetPoint("CENTER", overlay, "TOPLEFT", hovered.b[1], hovered.b[2])
        marks.symbol:Show()
    elseif hovered and hovered.b then
        marks.symbol:Hide()
        -- The arrowhead at the end, turned along the leg; pointing down
        -- when there is no leg to turn along.
        marks.stop:ClearAllPoints()
        marks.stop:SetSize(arrow, arrow)
        if hovered.a then
            -- The art's tip is at its edge: set the head back along the
            -- leg by half its size so the tip lands on the spot itself.
            -- Turned along the line's last stretch, which a road bends.
            local dx = hovered.dx or (hovered.b[1] - hovered.a[1])
            local dy = hovered.dy or (hovered.b[2] - hovered.a[2])
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

-- The whole route, on the smallest map that holds its start and its end.
function Preview:ShowAll()
    local route = Route()
    local last = route and route.steps and route.steps[#route.steps]
    if not (last and WorldMapFrame and WorldMapFrame:IsShown()) then return end
    if not overlay and not Build() then return end
    local target = last.go or last.arrive
    local mapID = last.mapID or (target and target.m)
    if not mapID then return end
    local start = StartOf(route, 1)
    local m, depth = mapID, 0
    while start and m and depth < 8 do
        if Falls(start, m) and Falls(target, m) then
            mapID = m
            break
        end
        local info = C_Map.GetMapInfo and C_Map.GetMapInfo(m)
        if not info or not info.parentMapID or info.parentMapID == 0 or (info.mapType and info.mapType <= 1) then break end
        m = info.parentMapID
        depth = depth + 1
    end
    shownMap, shownIndex = mapID, 0
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
    local road = mapID and step.kind == "travel" and RoadPoints(route, index, start, target, mapID)
    out[#out + 1] = string.format("map %s: start on it %s, target on it %s, road points %s", tostring(mapID),
        a and string.format("%.0f,%.0f", a[1], a[2]) or "no", b and string.format("%.0f,%.0f", b[1], b[2]) or "no",
        road and tostring(#road / 2) or "none")
    return out
end
