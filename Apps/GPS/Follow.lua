-- EasyFind GPS: the walk being followed.
--
-- The active step's way on foot, from where the step starts, and where
-- along it the player stands. Straying off it finds the way again from
-- where the player is. The arrow, the map line and the minimap line all
-- read it, taken once a frame at most.
local ns = EasyFind and EasyFind._ns
if not ns then return end
local Follow = {}
ns.GPSFollow = Follow

local msqrt, mmax, mmin, mhuge = math.sqrt, math.max, math.min, math.huge

local OFF_WAY = 20             -- yards off the walk before it is found again
local REFIND = 4               -- seconds at least between two findings
local BACK, ON = 2, 12         -- stretches searched behind and ahead of the last one matched
local RIDES = { taxi = true, boat = true, ferry = true, zeppelin = true, skyship = true, tram = true }
Follow.RIDES = RIDES

local walk = { seg = 1 }       -- the walk followed: its route, step, end, path, matched stretch
local cur = {}                 -- the last reading
local stamp                    -- the GetTime() it was taken at
local axes = {}                -- per continent: north and west as world directions

local function Route() local g = ns.GPS return g and g.CurrentRoute and g.CurrentRoute() end

local function World(p)
    if not p then return nil end
    if p.wx and p.ci then return p.ci, p.wx, p.wy end
    local toWorld = ns.GPSRoute and ns.GPSRoute.WorldPos
    if p.m and toWorld then return toWorld(p.m, p.x, p.y) end
    return nil
end
Follow.World = World

-- Where step i starts: the step before's landing, or where the route was planned.
local function StartOf(route, i)
    if i > 1 then return World(route.steps[i - 1].arrive) end
    return World(route.from)
end
Follow.StartOf = StartOf

-- North and west in the client's world coordinates, read off the player's
-- map (up is north, left is west) rather than assumed.
function Follow.Axes(ci)
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

local function Find(ci, sx, sy, now)
    walk.found, walk.fx, walk.fy, walk.seg, walk.wide = now, sx, sy, 1, true
    local find = ns.GPSRoute and ns.GPSRoute.WalkPath
    walk.path = find and find(ci, sx, sy, walk.tx, walk.ty) or false
end

-- The walk's nearest point to (x, y), looked for near the stretch matched
-- last (all of a walk just found): its stretch, the yards along the walk
-- there, how far off, and the point.
local function Nearest(path, x, y)
    local pts, cum = path.pts, path.cum
    local bestD, bestSeg, bestAlong, bestX, bestY = mhuge, walk.seg, 0, x, y
    local lo, hi = mmax(1, walk.seg - BACK), mmin(#pts / 2 - 1, walk.seg + ON)
    if walk.wide then lo, hi, walk.wide = 1, #pts / 2 - 1, false end
    for s = lo, hi do
        local ax, ay = pts[2 * s - 1], pts[2 * s]
        local dx, dy = pts[2 * s + 1] - ax, pts[2 * s + 2] - ay
        local l2 = dx * dx + dy * dy
        local t = l2 > 0 and mmax(0, mmin(1, ((x - ax) * dx + (y - ay) * dy) / l2)) or 0
        local qx, qy = ax + t * dx, ay + t * dy
        local d = msqrt((x - qx) ^ 2 + (y - qy) ^ 2)
        if d < bestD then
            bestD, bestSeg, bestX, bestY = d, s, qx, qy
            bestAlong = cum[s] + t * (cum[s + 1] - cum[s])
        end
    end
    return bestSeg, bestAlong, bestD, bestX, bestY
end

-- The point `along` yards into the walk, searched from stretch s on.
function Follow.PointAt(path, along, s)
    local pts, cum = path.pts, path.cum
    local n = #pts / 2
    if along >= path.len then return pts[2 * n - 1], pts[2 * n] end
    while s < n - 1 and cum[s + 1] < along do s = s + 1 end
    local l = cum[s + 1] - cum[s]
    local t = l > 0 and mmax(0, mmin(1, (along - cum[s]) / l)) or 0
    return pts[2 * s - 1] + t * (pts[2 * s + 1] - pts[2 * s - 1]), pts[2 * s] + t * (pts[2 * s + 2] - pts[2 * s])
end

-- The active step as it stands, or nil with nothing to follow (no route,
-- arrived, a spell, on a flight, another continent): the route, index,
-- ci and px, py (the player), tx, ty (the step's spot), straight (yards
-- there), ride (a crossing: tx, ty is where it is boarded), and on a walk
-- its path with seg, along, off and qx, qy (the nearest point on it).
function Follow.Now()
    local now = GetTime()
    if stamp == now then return cur.ok and cur or nil end
    stamp, cur.ok = now, false
    local route = Route()
    if not (route and route.steps and not route.arrived) then return nil end
    local index = route.active or 1
    local step = route.steps[index]
    if not step or step.kind == "teleport" or (UnitOnTaxi and UnitOnTaxi("player")) then return nil end
    local ci, px, py = ns.GPS.PlayerWorldPos()
    local tci, tx, ty = World(step.go or step.arrive)
    if not (ci and tci == ci and tx) then return nil end
    cur.route, cur.index, cur.ci, cur.px, cur.py, cur.tx, cur.ty = route, index, ci, px, py, tx, ty
    cur.straight = msqrt((tx - px) ^ 2 + (ty - py) ^ 2)
    cur.ride, cur.path = RIDES[step.kind] or false, false
    cur.ok = true
    if cur.ride then return cur end
    if walk.route ~= route or walk.index ~= index or walk.tx ~= tx or walk.ty ~= ty then
        walk.route, walk.index, walk.tx, walk.ty = route, index, tx, ty
        local sci, sx, sy = StartOf(route, index)
        if sci == ci and sx then Find(ci, sx, sy, -mhuge) else Find(ci, px, py, now) end
    end
    -- Off the way, or with none found: found again from here, once moved on.
    local path = walk.path
    local seg, along, off, qx, qy
    if path then seg, along, off, qx, qy = Nearest(path, px, py) end
    if (not path or off > OFF_WAY) and now - walk.found > REFIND
        and (walk.fx - px) ^ 2 + (walk.fy - py) ^ 2 > OFF_WAY * OFF_WAY then
        Find(ci, px, py, now)
        path = walk.path
        if path then seg, along, off, qx, qy = Nearest(path, px, py) end
    end
    if not path then return cur end
    walk.seg = seg
    cur.path, cur.seg, cur.along, cur.off, cur.qx, cur.qy = path, seg, along, off, qx, qy
    return cur
end

-- The route was put away: the next reading starts afresh.
function Follow.Reset()
    walk.route, walk.path, stamp = nil, nil, nil
end
