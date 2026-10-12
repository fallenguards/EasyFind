-- EasyFind GPS: the arrow at the character.
--
-- While a route is followed, an arrow under the character points the way
-- on foot as it runs: at a spot a little ahead along the walk, so it turns
-- with every bend, with the yards left on the walk under it. Straying off
-- the way finds the walk again from where you stand. At a ride's boarding
-- spot it points there; on board, and where the game gives no facing
-- (instances), it rests. Shift-drag moves it.
local ns = EasyFind and EasyFind._ns
if not ns then return end
local Arrow = {}
ns.GPSArrow = Arrow

local msqrt, matan2, mpi, mfloor, mmax, mmin, mhuge = math.sqrt, math.atan2 or math.atan, math.pi, math.floor, math.max, math.min, math.huge
local sformat = string.format

local TEX_ARROW = "Interface\\AddOns\\EasyFind\\MapSearch\\Images\\arrow-hq"   -- points down as drawn
local SIZE = 44
local HOME_Y = -130            -- under the character, from the screen's center
local AHEAD = 25               -- yards along the walk the arrow aims at
local OFF_WAY = 20             -- yards off the walk before it is found again
local REFIND = 2               -- seconds at least between two findings
local BACK, ON = 2, 12         -- stretches searched behind and ahead of the last one matched
local AT_RIDE = 60             -- yards from a ride's boarding spot: still pointing at it
local THROTTLE = 0.03
local COLOR = { 0.25, 0.6, 1 } -- the map line's blue
local RIDES = { taxi = true, boat = true, ferry = true, zeppelin = true, skyship = true, tram = true }

local frame, art, label, driver
local since = 0
local walk = { seg = 1 }       -- the walk followed: its route, step, end, path, matched stretch
local axes = {}                -- per continent: north and west as world directions
local aimCi                    -- the continent the last aim was taken on

local function DB() return EasyFind and EasyFind.db end
local function Route() local g = ns.GPS return g and g.CurrentRoute and g.CurrentRoute() end
local function Enabled() local db = DB() return not (db and db.gpsArrow == false) end

local function World(p)
    if not p then return nil end
    if p.wx and p.ci then return p.ci, p.wx, p.wy end
    local toWorld = ns.GPSRoute and ns.GPSRoute.WorldPos
    if p.m and toWorld then return toWorld(p.m, p.x, p.y) end
    return nil
end

-- North and west in the client's world coordinates, read off the player's
-- map (up is north, left is west) rather than assumed.
local function Axes(ci)
    local a = axes[ci]
    if a then return a end
    local toWorld = ns.GPSRoute and ns.GPSRoute.WorldPos
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if not (toWorld and mapID) then return nil end
    local c0, x0, y0 = toWorld(mapID, 0.5, 0.5)
    local c1, xn, yn = toWorld(mapID, 0.5, 0.4)
    local c2, xw, yw = toWorld(mapID, 0.4, 0.5)
    if not (c0 == ci and c1 == ci and c2 == ci) then return nil end
    local nx, ny, wx, wy = xn - x0, yn - y0, xw - x0, yw - y0
    local ln, lw = msqrt(nx * nx + ny * ny), msqrt(wx * wx + wy * wy)
    if ln == 0 or lw == 0 then return nil end
    a = { nx / ln, ny / ln, wx / lw, wy / lw }
    axes[ci] = a
    return a
end

-- The way from (px, py) to (ax, ay) as the game turns: from north toward west.
local function Bearing(ci, px, py, ax, ay)
    local a = Axes(ci)
    if not a then return nil end
    local dx, dy = ax - px, ay - py
    return matan2(dx * a[3] + dy * a[4], dx * a[1] + dy * a[2])
end
Arrow._Bearing = Bearing   -- tests

local function Find(route, index, ci, px, py, tx, ty)
    walk.route, walk.index, walk.tx, walk.ty = route, index, tx, ty
    walk.found, walk.seg = GetTime(), 1
    local find = ns.GPSRoute and ns.GPSRoute.WalkPath
    walk.path = find and find(ci, px, py, tx, ty) or false
end

-- The walk's nearest point to (x, y), looked for near the stretch matched
-- last: its stretch, the yards along the walk there, and how far off.
local function Nearest(path, x, y)
    local pts, cum = path.pts, path.cum
    local bestD, bestSeg, bestAlong = mhuge, walk.seg, 0
    for s = mmax(1, walk.seg - BACK), mmin(#pts / 2 - 1, walk.seg + ON) do
        local ax, ay = pts[2 * s - 1], pts[2 * s]
        local dx, dy = pts[2 * s + 1] - ax, pts[2 * s + 2] - ay
        local l2 = dx * dx + dy * dy
        local t = l2 > 0 and mmax(0, mmin(1, ((x - ax) * dx + (y - ay) * dy) / l2)) or 0
        local qx, qy = ax + t * dx, ay + t * dy
        local d = msqrt((x - qx) ^ 2 + (y - qy) ^ 2)
        if d < bestD then bestD, bestSeg, bestAlong = d, s, cum[s] + t * (cum[s + 1] - cum[s]) end
    end
    return bestSeg, bestAlong, bestD
end

local function PointAt(path, along, s)
    local pts, cum = path.pts, path.cum
    local n = #pts / 2
    if along >= path.len then return pts[2 * n - 1], pts[2 * n] end
    while s < n - 1 and cum[s + 1] < along do s = s + 1 end
    local l = cum[s + 1] - cum[s]
    local t = l > 0 and mmax(0, mmin(1, (along - cum[s]) / l)) or 0
    return pts[2 * s - 1] + t * (pts[2 * s + 1] - pts[2 * s - 1]), pts[2 * s] + t * (pts[2 * s + 2] - pts[2 * s])
end

-- Where the arrow points from where the player stands, and the yards left,
-- or nothing to point at.
local function Aim()
    local route = Route()
    if not (route and route.steps and not route.arrived) then return nil end
    local index = route.active or 1
    local step = route.steps[index]
    if not step or step.kind == "teleport" or (UnitOnTaxi and UnitOnTaxi("player")) then return nil end
    local ci, px, py = ns.GPS.PlayerWorldPos()
    aimCi = ci
    local tci, tx, ty = World(step.go or step.arrive)
    if not (ci and tci == ci and tx) then return nil end
    local straight = msqrt((tx - px) ^ 2 + (ty - py) ^ 2)
    if RIDES[step.kind] then
        if straight > AT_RIDE then return nil end
        return px, py, tx, ty, straight
    end
    if walk.route ~= route or walk.index ~= index or walk.tx ~= tx or walk.ty ~= ty then
        Find(route, index, ci, px, py, tx, ty)
    end
    local path = walk.path
    if not path then return px, py, tx, ty, straight end
    local seg, along, off = Nearest(path, px, py)
    if off > OFF_WAY and GetTime() - walk.found > REFIND then
        Find(route, index, ci, px, py, tx, ty)
        path = walk.path
        if not path then return px, py, tx, ty, straight end
        seg, along = Nearest(path, px, py)
    end
    walk.seg = seg
    local ax, ay = PointAt(path, along + AHEAD, seg)
    return px, py, ax, ay, mmax(0, path.len - along)
end

Arrow._Aim = Aim   -- tests

local function SavePlace()
    local cx, cy = frame:GetCenter()
    if not (cx and cy) then return end
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx, cy)
    local db = DB()
    if db then db.gpsArrowPos = { x = cx, y = cy } end
end

local function Build()
    frame = CreateFrame("Frame", "EasyFindGPSArrow", UIParent)
    frame:SetSize(SIZE, SIZE)
    frame:SetFrameStrata("LOW")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(false)
    frame:RegisterForDrag("LeftButton")
    local db = DB()
    local pos = db and db.gpsArrowPos
    if pos and pos.x and pos.y then
        frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", pos.x, pos.y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, HOME_Y)
    end
    art = frame:CreateTexture(nil, "ARTWORK")
    art:SetAllPoints(frame)
    art:SetTexture(TEX_ARROW)
    art:SetVertexColor(COLOR[1], COLOR[2], COLOR[3], 1)
    label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOP", frame, "BOTTOM", 0, -2)
    -- Clicks pass through to the world, unless Shift is held to move it.
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePlace()
    end)
    frame:SetScript("OnEvent", function(self) self:EnableMouse(IsShiftKeyDown()) end)
    frame:SetScript("OnShow", function(self)
        self:RegisterEvent("MODIFIER_STATE_CHANGED")
        self:EnableMouse(IsShiftKeyDown())
    end)
    frame:SetScript("OnHide", function(self)
        self:UnregisterEvent("MODIFIER_STATE_CHANGED")
        self:EnableMouse(false)
    end)
    frame:Hide()
end

local function Update()
    local px, py, ax, ay, left = Aim()
    local facing = px and GetPlayerFacing and GetPlayerFacing()
    local bearing = facing and not (issecretvalue and issecretvalue(facing)) and Bearing(aimCi, px, py, ax, ay)
    if not bearing then
        if frame then frame:Hide() end
        return
    end
    if not frame then Build() end
    -- Facing turns from north toward west too; the art points down at rest.
    art:SetRotation(bearing - facing + mpi)
    label:SetText(IN_GAME_NAVIGATION_RANGE and sformat(IN_GAME_NAVIGATION_RANGE, mfloor(left)) or (mfloor(left) .. " yd"))
    frame:Show()
end

local function Tick(_, dt)
    since = since + dt
    if since < THROTTLE then return end
    since = 0
    Update()
end

-- A route change or the option flipped: runs only while there is a way to point.
function Arrow:Refresh()
    local route = Route()
    local on = Enabled() and route ~= nil and not route.arrived and not route.untracked
    if on then
        since = 0
        driver:SetScript("OnUpdate", Tick)
        Update()
    else
        driver:SetScript("OnUpdate", nil)
        walk.route, walk.path = nil, nil
        if frame then frame:Hide() end
    end
end

driver = CreateFrame("Frame")
