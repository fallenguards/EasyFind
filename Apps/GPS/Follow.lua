-- EasyFind GPS: the walk being followed.
--
-- The active step's way on foot, from where the step starts, and where
-- along it the player stands. Straying off it, a way from where the
-- player is back onto it a little ahead joins the walk's rest, so the
-- walk keeps its shape; a whole way from here takes over only once it
-- stays clearly faster. The arrow, the map line and the minimap line all
-- read it, taken once a frame at most.
local ns = EasyFind and EasyFind._ns
if not ns then return end
local Follow = {}
ns.GPSFollow = Follow

local msqrt, mmax, mmin, mhuge = math.sqrt, math.max, math.min, math.huge

local OFF_WAY = 20             -- yards off the walk before it is found again
local REFIND = 4               -- seconds at least between two findings
-- A way found from off the walk takes over only once faster by this much,
-- and still so after this long and this far: no swing to a way hardly
-- better that the next finding swings back from.
local MARGIN_YD, MARGIN = 25, 0.1
local HOLD_SECONDS, HOLD_YD = 6, 30
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

-- Where step i starts: its own start (a ghost's walk, from where it
-- released), the step before's landing, or where the route was planned.
local function StartOf(route, i)
    local own = route.steps[i] and route.steps[i].from
    if own then return World(own) end
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

-- The walk from where it was found, once drawn: the route's own walks
-- by the planner, one from where the player strayed to by GPS.DrawWalk
-- in the planner's slices, asked here and again while it was busy. nil
-- until then; the arrow points straight meanwhile.
local function Drawn(ci, w, tx, ty, near)
    local find = ns.GPSRoute and ns.GPSRoute.WalkPath
    if not find then w.path = false return false end
    local path = find(ci, w.fx, w.fy, tx, ty, true, near)
    if path == nil then
        local now = GetTime()
        if not (w.asked and now - w.asked < REFIND) then
            local draw = ns.GPS.DrawWalk
            w.asked = draw and draw(ci, w.fx, w.fy, tx, ty, near) and now or nil
        end
        return nil
    end
    w.path = path
    return path
end

local function Find(ci, sx, sy, now)
    walk.found, walk.fx, walk.fy, walk.seg, walk.wide, walk.path, walk.asked = now, sx, sy, 1, true, nil, nil
    walk.cand, walk.join, walk.detour = nil, nil, nil
    Drawn(ci, walk, walk.tx, walk.ty, walk.near)
end

-- A walk's nearest point to (x, y), looked for near the stretch w matched
-- last (all of a walk just found): its stretch, the yards along the walk
-- there, how far off, and the point.
local function Nearest(path, x, y, w)
    local pts, cum = path.pts, path.cum
    local bestD, bestSeg, bestAlong, bestX, bestY = mhuge, w.seg, 0, x, y
    local lo, hi = mmax(1, w.seg - BACK), mmin(#pts / 2 - 1, w.seg + ON)
    if w.wide then lo, hi, w.wide = 1, #pts / 2 - 1, false end
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

-- Yards of walking left by a way from a point off it: back onto it, then
-- on to its end (its time, swimming slower).
local function Left(path, along, off)
    local len = path.len
    return off + (len > 0 and (path.time or len) * (len - along) / len or 0)
end

-- The way from off the walk to a point on it, then the walk from there:
-- one walk, from where the player is.
local function Stitch(way, path, at)
    local pts = {}
    for i = 1, #way.pts do pts[i] = way.pts[i] end
    local s, pc = 1, path.cum
    while s < #pc and pc[s + 1] <= at do s = s + 1 end
    for v = s + 1, #path.pts / 2 do pts[#pts + 1], pts[#pts + 2] = path.pts[2 * v - 1], path.pts[2 * v] end
    local cum, len = { 0 }, 0
    for v = 2, #pts / 2 do
        len = len + msqrt((pts[2 * v - 1] - pts[2 * v - 3]) ^ 2 + (pts[2 * v] - pts[2 * v - 2]) ^ 2)
        cum[v] = len
    end
    local rest = path.len > 0 and (path.time or path.len) * (path.len - at) / path.len or 0
    local jumps
    for k = 1, way.jumps and #way.jumps or 0 do
        jumps = jumps or {}
        jumps[#jumps + 1] = way.jumps[k]
    end
    for k = 1, path.jumps and #path.jumps or 0 do
        local j = path.jumps[k]
        if j.at >= at then
            jumps = jumps or {}
            jumps[#jumps + 1] = { at = j.at - at + way.len, x = j.x, y = j.y, h = j.h }
        end
    end
    return { pts = pts, cum = cum, len = len, time = (way.time or way.len) + rest, jumps = jumps }
end

-- Off the walk: the way from here back onto it, to a point as far ahead
-- as the player is off, drawn in the planner's slices and joined to the
-- walk's rest. No way there: nothing until moved on. True once joined.
local function Rejoin(ci, px, py, now, path, seg, along, off)
    local j = walk.join
    local moved = j and (j.fx - px) ^ 2 + (j.fy - py) ^ 2 > OFF_WAY * OFF_WAY
    if j and j.path == false and not moved then return false end
    if not j or j.path == false or (moved and now - j.at >= REFIND) then
        local at = mmin(path.len, along + mmax(OFF_WAY, off))
        local jx, jy = Follow.PointAt(path, at, seg)
        j = { fx = px, fy = py, tx = jx, ty = jy, along = at, at = now }
        walk.join = j
    end
    local way = j.path
    if way == nil then way = Drawn(ci, j, j.tx, j.ty, nil) end
    if not way then return false end
    walk.path = Stitch(way, path, j.along)
    walk.found, walk.fx, walk.fy, walk.seg, walk.wide, walk.asked, walk.join = now, px, py, 1, true, nil, nil
    -- A way back far round (twice the yards off and more): a whole way
    -- from here may do better.
    walk.detour = way.len > 2 * off + OFF_WAY or nil
    return true
end

-- With no way back onto the walk from here, or one far round, a whole
-- way from here is asked for and weighed against the walk from here. It
-- takes over only once clearly faster, and still so a while and a way
-- on; a way no faster is dropped. True when it took over.
local function Challenge(ci, px, py, now, path, along, off)
    local c = walk.cand
    if not c then
        local j = walk.join
        if not ((j and j.path == false) or walk.detour) or now - walk.found < REFIND then return false end
        c = { fx = px, fy = py, at = now, seg = 1, wide = true }
        walk.cand = c
    end
    local way = c.path
    if way == nil then way = Drawn(ci, c, walk.tx, walk.ty, walk.near) end
    if not way then
        if way == false then walk.cand = nil end
        return false
    end
    local seg, along2, off2 = Nearest(way, px, py, c)
    c.seg = seg
    local stay = Left(path, along, off)
    if Left(way, along2, off2) < stay - mmax(MARGIN_YD, stay * MARGIN) then
        if not c.since then c.since, c.sx, c.sy = now, px, py end
        if now - c.since >= HOLD_SECONDS and (px - c.sx) ^ 2 + (py - c.sy) ^ 2 >= HOLD_YD * HOLD_YD then
            walk.found, walk.fx, walk.fy, walk.seg, walk.wide, walk.path, walk.asked = now, c.fx, c.fy, 1, true, way, nil
            walk.cand, walk.join, walk.detour = nil, nil, nil
            return true
        end
    else
        c.since = nil
        if now - c.at >= REFIND and (c.fx - px) ^ 2 + (c.fy - py) ^ 2 > OFF_WAY * OFF_WAY then
            walk.cand, walk.detour = nil, nil
        end
    end
    return false
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
    if not step or step.kind == "teleport" or step.noWay or (UnitOnTaxi and UnitOnTaxi("player")) then return nil end
    local ci, px, py = ns.GPS.PlayerWorldPos()
    local tci, tx, ty = World(step.go or step.arrive)
    -- On board a crossing: what is left is the ride to where it lands.
    local Boats = ns.GPSBoats
    if RIDES[step.kind] and step.arrive and Boats and Boats.Aboard and Boats.Aboard(ci, px, py, tci, tx, ty) then
        tci, tx, ty = World(step.arrive)
    end
    if not (ci and tci == ci and tx) then return nil end
    cur.route, cur.index, cur.ci, cur.px, cur.py, cur.tx, cur.ty = route, index, ci, px, py, tx, ty
    cur.straight = msqrt((tx - px) ^ 2 + (ty - py) ^ 2)
    cur.ride, cur.path = RIDES[step.kind] or false, false
    cur.ok = true
    if cur.ride then return cur end
    if walk.route ~= route or walk.index ~= index or walk.tx ~= tx or walk.ty ~= ty then
        walk.route, walk.index, walk.tx, walk.ty, walk.near = route, index, tx, ty, step.near
        local sci, sx, sy = StartOf(route, index)
        if sci == ci and sx then Find(ci, sx, sy, -mhuge) else Find(ci, px, py, now) end
    end
    local path = walk.path
    if path == nil then path = Drawn(ci, walk, walk.tx, walk.ty, walk.near) end
    local seg, along, off, qx, qy
    if path then seg, along, off, qx, qy = Nearest(path, px, py, walk) end
    if path == false then
        -- No way from where it was found: found again from here, once moved on.
        if now - walk.found > REFIND and (walk.fx - px) ^ 2 + (walk.fy - py) ^ 2 > OFF_WAY * OFF_WAY then
            Find(ci, px, py, now)
            path = walk.path
            if path then seg, along, off, qx, qy = Nearest(path, px, py, walk) end
        end
    elseif path then
        if off > OFF_WAY and Rejoin(ci, px, py, now, path, seg, along, off) then
            path = walk.path
            seg, along, off, qx, qy = Nearest(path, px, py, walk)
        end
        if Challenge(ci, px, py, now, path, along, off) then
            path = walk.path
            seg, along, off, qx, qy = Nearest(path, px, py, walk)
        end
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
