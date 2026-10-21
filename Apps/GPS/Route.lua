-- Route engine: cheapest path in seconds over walks, flights, crossings and teleports.
-- Walk edges are made on the fly; the data ships places, never pairs.

local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns then return end

local Route = {}
ns.GPSRoute = Route

local msqrt, mmax, mhuge, mfloor = math.sqrt, math.max, math.huge, math.floor

-- Inside the planner's slices the solver gives the frame back where the
-- walking grid's searches do (Nav.lua); anywhere else it runs through.
local function Pause()
    local Nav = ns.GPSNav
    if Nav and Nav.Pause then Nav.Pause() end
end
local tinsert, tsort, tconcat = table.insert, table.sort, table.concat
local sformat = string.format

local MOUNT_UP = 2          -- seconds to get on a mount
local RUN = 7               -- the game's run, yards a second
local BOARD_TAXI = 4        -- seconds at the flight master
local ABILITY_WAIT_MAX = 600 -- a cooldown longer than this is not worth waiting for
local TELEPORT_MIN_YARDS = 1000 -- a teleport landing closer than this to the start is no trip
local HOSTILE_SECONDS = 1800 -- the other faction's boat or zeppelin: a last resort, never banned
local AVOID_SECONDS = 3600  -- a way the player chose to avoid: taken only when nothing else gets there
-- Which avoid setting each way of travel answers to.
local AVOID_KIND = { taxi = "taxi", boat = "boat", ferry = "boat", zeppelin = "zeppelin", skyship = "zeppelin",
                     portal = "portal", tram = "portal", teleport = "teleport" }
Route.AVOID_KIND = AVOID_KIND
local WALK_DETOUR = 1.2     -- without the walking grid: ground yards per straight yard
local PICKUP_YARDS = 150    -- an undiscovered flight master this far off a ride is on the way
-- Learning stops taken without asking: together at most this share of the
-- trip's time and this many seconds, at most this many stops.
local AUTO_LEARN_SHARE, AUTO_LEARN_CAP, AUTO_LEARN_STOPS = 0.05, 90, 3
local SUGGEST_MIN_SECONDS = 60
local SUGGEST_CANDIDATES = 12

-- Enum.FlightPathFaction as the recorder stores it: 1 Horde, 2 Alliance.
local FACTION_OF = { ["1"] = "Horde", ["2"] = "Alliance", [1] = "Horde", [2] = "Alliance" }
local function FactionOK(f, faction)
    if not f or f == "Neutral" or f == "0" or f == 0 then return true end
    return (FACTION_OF[f] or f) == faction
end

-- World coordinates

local function WorldPos(m, x, y)
    if not (m and x and y and C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local ok, ci, pos = pcall(C_Map.GetWorldPosFromMapPos, m, CreateVector2D(x, y))
    if ok and pos then
        local wx, wy = pos:GetXY()
        return ci, wx, wy
    end
    return nil
end
Route.WorldPos = WorldPos

-- A point table with world coordinates, filled from the client when the
-- data did not carry them.
local function Resolve(p)
    if not p then return nil end
    if p.wx and p.wy and p.ci then return p end
    local ci, wx, wy = WorldPos(p.m, p.x, p.y)
    if not ci then return nil end
    return { m = p.m, x = p.x, y = p.y, ci = ci, wx = wx, wy = wy }
end

local function Dist(a, b)
    local dx, dy = a.wx - b.wx, a.wy - b.wy
    return msqrt(dx * dx + dy * dy)
end

local function MapName(m)
    if not m then return "?" end
    local ok, info = pcall(C_Map.GetMapInfo, m)
    return (ok and info and info.name) or ("map " .. tostring(m))
end

-- The client's own name for an area id: localized, where the data only
-- carries English.
local function AreaName(area)
    if not (area and C_Map and C_Map.GetAreaInfo) then return nil end
    local ok, name = pcall(C_Map.GetAreaInfo, area)
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

-- Where a hearth bound in this town lands: the data's town spot whose
-- area the client names the way GetBindLocation does.
local bindCache = {}
local function BindPoint(data, bindName)
    if not (data and data.binds and bindName) then return nil end
    local hit = bindCache[bindName]
    if hit ~= nil then return hit or nil end
    for area, p in pairs(data.binds) do
        if AreaName(area) == bindName then
            bindCache[bindName] = p
            return p
        end
    end
    -- Bound at an inn in a town's district: the town's spot.
    for area, town in pairs(data.bindAreas or {}) do
        if AreaName(area) == bindName and data.binds[town] then
            bindCache[bindName] = data.binds[town]
            return data.binds[town]
        end
    end
    bindCache[bindName] = false
    return nil
end

-- The graph

-- Landmass of a point: walking never crosses between two.
-- A spot (a circle) wins over its zone.
local function Landmass(data, p)
    local lm = data.landmass
    if not (lm and p) then return nil end
    local spots = lm.spots
    for i = 1, spots and #spots or 0 do
        local sp = spots[i]
        if sp.ci == p.ci then
            local dx, dy = p.wx - sp.wx, p.wy - sp.wy
            if dx * dx + dy * dy <= sp.r * sp.r then return sp.name end
        end
    end
    return lm.zones and p.m and lm.zones[p.m] or nil
end

-- ctx: start, goal, faction, canFly, data, cooldown(ability) -> seconds left,
-- known and listed { nodeID = true } (nil: every node learned / exists),
-- avoid { taxi, boat, zeppelin, portal, teleport = true }
local function BuildGraph(ctx)
    local avoid = ctx.avoid or {}
    local function Avoided(kind) return avoid[AVOID_KIND[kind] or kind] and AVOID_SECONDS or 0 end
    local data = ctx.data
    local speeds = data.speeds or { run = 7, mount = 14, fly = 30, taxi = 32 }
    local travelSpeed = ctx.canFly and (ctx.flySpeed or speeds.fly) or (ctx.groundSpeed or speeds.mount or 14)
    local nodes = {}          -- array of { p = point, kind, ... }
    local byCi = {}           -- continent -> array of node indexes

    local function AddNode(p, kind, extra)
        local n = { p = p, kind = kind, land = Landmass(data, p) }
        if extra then for k, v in pairs(extra) do n[k] = v end end
        nodes[#nodes + 1] = n
        local list = byCi[p.ci]
        if not list then
            list = {}
            byCi[p.ci] = list
        end
        list[#list + 1] = #nodes
        return #nodes
    end

    local startIdx = AddNode(ctx.start, "start")
    local goalIdx = AddNode(ctx.goal, "goal")

    -- Flight nodes and legs. An unlearned master can start a flight, never end or relay one.
    local taxiIdx = {}
    for id, n in pairs(data.nodes or {}) do
        if n.wx and n.ci and FactionOK(n.faction, ctx.faction) and (not ctx.listed or ctx.listed[id]) then
            local known = not ctx.known or ctx.known[id] or false
            local name = ctx.nodeName and ctx.nodeName(id) or n.n
            taxiIdx[id] = AddNode({ m = n.m, x = n.x, y = n.y, ci = n.ci, wx = n.wx, wy = n.wy }, "taxi",
                { id = id, name = name, unknown = not known or nil })
        end
    end
    local legs = {}           -- node index -> { { to = idx, sec = s }, ... }
    local taxiByCi = data.taxiByCi or {}
    -- Hops this account has flown, each way, over the estimate.
    local measured = ctx.flown or (ns.GPSFlights and ns.GPSFlights.Seconds)
    for i = 1, #(data.legs or {}) do
        local a, b, yd, flown = data.legs[i][1], data.legs[i][2], data.legs[i][3], data.legs[i][4]
        local ia, ib = taxiIdx[a], taxiIdx[b]
        if ia and ib then
            -- Measured seconds when this leg was flown; else the continent's
            -- taxi speed; else the global one.
            local ci = nodes[ia].p.ci
            local sec = flown or ((yd or 0) / (taxiByCi[ci] or speeds.taxi or 32))
            local pen = Avoided("taxi")
            if not nodes[ib].unknown then
                legs[ia] = legs[ia] or {}
                tinsert(legs[ia], { to = ib, sec = measured and measured(a, b) or sec, pen = pen })
            end
            if not nodes[ia].unknown then
                legs[ib] = legs[ib] or {}
                tinsert(legs[ib], { to = ia, sec = measured and measured(b, a) or sec, pen = pen })
            end
        end
    end

    -- Transport edges. A boat's cost is the ride plus the average wait at
    -- the dock for the next one.
    local hops = {}           -- node index -> { { to = idx, sec, edge }, ... }
    for i = 1, #(data.edges or {}) do
        local e = data.edges[i]
        -- Anyone may ride the other side's transport past its guards: kept,
        -- priced so it is only taken when nothing else gets there.
        local hostile = not FactionOK(e.faction, ctx.faction)
        -- A race-locked route (the Skyborne skyships) is for that race only.
        if (not e.race or e.race == ctx.race) and ctx.meets(e.req) then
            local f, t = Resolve(e.from), Resolve(e.to)
            -- A scanned map marker exists only for a character who can use
            -- the transport (unlocked, right phase): ask the client.
            if f and t and e.poi and ctx.hasMarker and ctx.hasMarker(f.m, e.n) == false then
                f = nil
            end
            if f and t then
                local fi = AddNode(f, "edgeFrom", { edge = e })
                local ti = AddNode(t, "edgeTo", { edge = e })
                local sec = (e.sec or 10) + (e.wait or 0) + (hostile and HOSTILE_SECONDS or 0)
                local pen = Avoided(e.kind)
                -- A timed route waits as long as its next departure; an
                -- untimed one, half its loop.
                local timed = e.route and e.stop and ctx.waitAt and true or nil
                hops[fi] = hops[fi] or {}
                tinsert(hops[fi], { to = ti, sec = sec, pen = pen, edge = e, hostile = hostile or nil, timed = timed })
                if e.bidir then
                    hops[ti] = hops[ti] or {}
                    tinsert(hops[ti], { to = fi, sec = sec, pen = pen, edge = e, reverse = true, hostile = hostile or nil })
                end
            end
        end
    end

    -- Teleports: from the start only, waiting out a short cooldown if needed.
    local teleports = {}
    for i = 1, #(data.abilities or {}) do
        local a = data.abilities[i]
        local dest
        if a.bind then
            -- Hearth landing: learned from the last hearth, else the bound town's
            -- spot, else the data's point when the bind is its inn.
            if ctx.hearth and ctx.hearth.point then
                dest = Resolve(ctx.hearth.point)
            elseif BindPoint(data, ctx.bindName) then
                dest = Resolve(BindPoint(data, ctx.bindName))
            elseif a.to and ctx.bindName and a.bind == ctx.bindName then
                dest = Resolve(a.to)
            end
        else
            dest = a.to and Resolve(a.to)
        end
        -- A landing a short ride from here is never worth a cast: the
        -- step would count as done before it was taken.
        if dest and dest.ci == ctx.start.ci and Dist(dest, ctx.start) < TELEPORT_MIN_YARDS then dest = nil end
        if dest and (not a.class or a.class == ctx.class) and (not a.faction or a.faction == ctx.faction)
            and (not a.race or a.race == ctx.race) and ctx.meets(a.req) and ctx.owns(a) then
            local wait = ctx.cooldown and ctx.cooldown(a) or 0
            if wait <= ABILITY_WAIT_MAX then
                -- The cast as the client prices it for this character now,
                -- with whatever shortens it; the data's figure stands in.
                local cast = a.cast or 0
                if a.id and C_Spell and C_Spell.GetSpellInfo then
                    local ok, info = pcall(C_Spell.GetSpellInfo, a.id)
                    if ok and info and info.castTime and info.castTime > 0 then cast = info.castTime / 1000 end
                end
                local ti = AddNode(dest, "teleportTo", { ability = a })
                tinsert(teleports, { to = ti, sec = wait + cast + 8 + ((a.guess or a.approx) and 20 or 0),
                                     pen = Avoided("teleport"), ability = a })
            end
        end
    end

    local mountUp = (not ctx.canFly and travelSpeed <= RUN + 0.5) and 0 or MOUNT_UP
    return {
        nodes = nodes, byCi = byCi, start = startIdx, goal = goalIdx,
        legs = legs, hops = hops, teleports = teleports, taxiIdx = taxiIdx,
        travelSpeed = travelSpeed, mountUp = mountUp, waitAt = ctx.waitAt,
        detour = (not ctx.canFly and data.classic) and WALK_DETOUR or 1,
        nav = not ctx.canFly and ns.GPSNav and ns.GPSNav.Ensure(ctx.start.ci) or nil,
        walkSec = {}, walkWind = {}, walkNear = {}, least = {}, travel = {}, rides = {},
        data = data,
    }
end

-- Two points within a few yards are the same spot: free, no mounting.
local function TravelCost(g, d, detour)
    if d <= 5 then return 0 end
    return g.mountUp + d * (detour or g.detour) / g.travelSpeed
end

local WALK_KEY = 65536

-- The least a walk not yet priced can take, in running yards: the
-- straight line, or on the walking grid the landmarks' bound on its cost,
-- brought down to time (a yard off the road costs more than it takes), so
-- the solve tries far fewer ways before one holds.
local function LeastYards(g, i, j)
    local key = i * WALK_KEY + j
    local yards = g.least[key]
    if yards then return yards end
    local a, b = g.nodes[i].p, g.nodes[j].p
    yards = Dist(a, b)
    local Nav = ns.GPSNav
    if g.nav and Nav.Bound then
        local lower = Nav.Bound(a.ci, a.wx, a.wy, b.wx, b.wy)
        if lower and Nav.CostOverTime then lower = lower / Nav.CostOverTime() end
        if lower and lower > yards then yards = lower end
    end
    g.least[key] = yards
    return yards
end

-- A binary heap of (cost, id), the least cost first.
local Heap = {}
Heap.__index = Heap
local function NewHeap() return setmetatable({ k = {}, v = {}, n = 0 }, Heap) end
function Heap:Push(cost, id)
    local n = self.n + 1
    self.n = n
    local k, v = self.k, self.v
    while n > 1 do
        local parent = mfloor(n / 2)
        if k[parent] <= cost then break end
        k[n], v[n] = k[parent], v[parent]
        n = parent
    end
    k[n], v[n] = cost, id
end
function Heap:Pop()
    local n = self.n
    if n == 0 then return nil end
    local k, v = self.k, self.v
    local topK, topV = k[1], v[1]
    local lastK, lastV = k[n], v[n]
    k[n], v[n] = nil, nil
    n = n - 1
    self.n = n
    local i = 1
    while true do
        local c = i * 2
        if c > n then break end
        if c < n and k[c + 1] < k[c] then c = c + 1 end
        if k[c] >= lastK then break end
        k[i], v[i] = k[c], v[c]
        i = c
    end
    if n > 0 then k[i], v[i] = lastK, lastV end
    return topV, topK
end

-- A crossing's spot (a boat's stop on the water, the far end of a pier, a
-- portal's landing) can sit just off the ground the walking grid joins up.
-- It is reached from the ground within this many yards of it, by a walk
-- this close (the trouble is the last few yards, not the way there).
local CROSSING = { taxi = true, edgeFrom = true, edgeTo = true, teleportTo = true }
local BOARD, BOARD_NEAR = { near = 40 }, 600
-- The goal reached only a long way round (a trainer just off a bank the
-- grid does not step down from) is walked to within this many yards, the
-- arrival's own reach (GPS.lua ARRIVE.spot), when that is far shorter.
-- Only then: a floor under an upstairs trainer is near too.
local GOAL_NEAR = 8
local goalOpts = { near = GOAL_NEAR }
-- A zone's goal is its map's middle, which can be off the ground the walks
-- know (Winterspring's is): the nearest ground this many cells off stands
-- for it.
local ZONE_GROUND_CELLS = 64

-- A walk's seconds on the walking grid by the cost it is chosen by (the
-- chosen route's walks are timed by their real path afterwards), and its
-- wind (yards per straight yard); no way on foot costs forever. With room
-- (seconds the walk may take and still beat the best route in hand), the
-- search gives up past it: the walk stays unpriced, its least raised past
-- the room, and nil comes back.
local function PriceWalk(g, i, j, room)
    local key = i * WALK_KEY + j
    local sec = g.walkSec[key]
    if sec then return sec, g.walkWind[key], g.walkNear[key] end
    local a, b = g.nodes[i].p, g.nodes[j].p
    local straight = Dist(a, b)
    local wind
    local Nav = ns.GPSNav
    if straight <= 5 then
        sec = TravelCost(g, straight)
    elseif Nav and Nav.Ensure(a.ci) then
        -- Searched from the land toward the crossing, so a walk that finds no
        -- way floods the land's ground, never the sea around a dock. On foot
        -- either way costs the same.
        local ni, nj = g.nodes[i], g.nodes[j]
        local from, to = a, b
        -- A drop goes one way: searched backwards, the walk is still priced
        -- the way it is walked.
        local rev = CROSSING[ni.kind] and not CROSSING[nj.kind] or nil
        if rev then from, to = b, a end
        -- The room in running yards; the search gives up by cost, which a
        -- yard off the road raises, so its limit is that much wider.
        local yards = room and room < mhuge and (room - g.mountUp) * g.travelSpeed or nil
        local limit = yards and yards * (Nav.CostOverTime and Nav.CostOverTime() or 1) or nil
        local cost, beyond, time = Nav.Walk(a.ci, from.wx, from.wy, to.wx, to.wy,
                                            (limit or rev) and { limit = limit, reverse = rev } or nil)
        if not cost and not beyond and (CROSSING[ni.kind] or CROSSING[nj.kind]) and straight <= BOARD_NEAR then
            cost, beyond, time = Nav.Walk(a.ci, from.wx, from.wy, to.wx, to.wy,
                                          (limit or rev) and { near = BOARD.near, limit = limit, reverse = rev } or BOARD)
        end
        if j == g.goal and (not cost or cost > 2 * straight + 50) then
            goalOpts.limit = limit
            local nc, nb, nt = Nav.Walk(a.ci, a.wx, a.wy, b.wx, b.wy, goalOpts)
            if nc and (not cost or (nc * 2 < cost and cost - nc > 100)) then
                cost, beyond, time = nc, nb, nt
                g.walkNear[key] = GOAL_NEAR
            elseif not cost and nb then
                beyond = true
            end
        end
        if cost then
            -- Chosen by its cost, timed by its time (yards walked, swimming slower).
            sec, wind = g.mountUp + time / g.travelSpeed, time / straight
        elseif beyond then
            local least = g.least[key]
            if not least or yards + 0.001 > least then g.least[key] = yards + 0.001 end
            return nil
        else
            sec = mhuge
        end
    else
        sec = TravelCost(g, straight)
    end
    g.walkSec[key], g.walkWind[key] = sec, wind
    return sec, wind, g.walkNear[key]
end

-- A walk step's way drawn and kept, when it has one: the arrow follows
-- it and the split by zone reads it; its time was priced with it.
local function DrawWalk(s, a)
    local b = s.go or s.arrive
    if s.kind == "travel" and a and b and a.wx and b.wx and a.ci == b.ci and Dist(a, b) > 5 then
        Route.WalkPath(a.ci, a.wx, a.wy, b.wx, b.wy, nil, s.near)
    end
end

-- The chosen route's walks drawn: the first (the one set out on) and, for
-- a zone goal, the last (cut at the border on the split), or every one.
-- The rest are drawn once the route is on screen (GPS.lua).
local function DrawWalks(steps, start, all, zoneGoal)
    local first, last
    for i = 1, #steps do
        if steps[i].kind == "travel" then
            first, last = first or i, i
        end
    end
    for i = 1, #steps do
        if all or i == first or (zoneGoal and i == last) then
            DrawWalk(steps[i], steps[i].from or (i > 1 and steps[i - 1].arrive) or start)
        end
    end
end

-- The route's walks not drawn yet, drawn in order: the job after the
-- route shows.
function Route.DrawWalks(steps, start)
    DrawWalks(steps, start, true)
end

-- The travel edge from node i to j, one table per pair for the graph's
-- life, its seconds those of this visit.
local function TravelEdge(g, i, j, sec, wind)
    local key = i * WALK_KEY + j
    local e = g.travel[key]
    if not e then
        e = { to = j, kind = "travel" }
        g.travel[key] = e
    end
    e.sec, e.wind = sec, wind
    return e
end

-- Node i's rides, made once per graph: its flight legs, its crossings
-- and, from the start, the teleports.
local function Rides(g, i)
    local out = g.rides[i]
    if out then return out end
    out = {}
    local legs = g.legs[i]
    for j = 1, legs and #legs or 0 do
        out[#out + 1] = { to = legs[j].to, sec = BOARD_TAXI + legs[j].sec, pen = legs[j].pen, kind = "taxi" }
    end
    local hops = g.hops[i]
    for j = 1, hops and #hops or 0 do
        local h = hops[j]
        out[#out + 1] = { to = h.to, sec = h.sec, pen = h.pen, kind = h.edge.kind, edge = h.edge,
                          reverse = h.reverse, hostile = h.hostile, hop = (h.timed and not h.reverse) and h or nil }
    end
    if i == g.start then
        for j = 1, #g.teleports do
            local tp = g.teleports[j]
            out[#out + 1] = { to = tp.to, sec = tp.sec, pen = tp.pen, kind = "teleport", ability = tp.ability }
        end
    end
    g.rides[i] = out
    return out
end

-- State s is node s reached any way but on foot, s + n node s reached on
-- foot: no walk follows a walk, so stops never chain across a mountain.
-- From a node reached any other way, travel to everything on the same
-- continent (and landmass, without the walking grid); a walk not yet
-- priced on the grid costs the least it can. A timed crossing's wait
-- hangs on when its dock is reached: its edge is made for the visit.
local function Dijkstra(g)
    local n = #g.nodes
    local nodes, walkSec, walkWind, nav = g.nodes, g.walkSec, g.walkWind, g.nav
    local bound = nav and 1
    local dist, prev, prevEdge, done = {}, {}, {}, {}
    dist[g.start] = 0
    local heap = NewHeap()
    heap:Push(0, g.start)
    local reached, pops = nil, 0
    while true do
        pops = pops + 1
        if pops % 32 == 0 then Pause() end
        local best, bestD = heap:Pop()
        if not best then break end
        -- An entry outdone since it was pushed is passed over.
        if not done[best] and bestD <= dist[best] then
            local onFoot = best > n
            local i = onFoot and best - n or best
            if i == g.goal then
                reached = best
                break
            end
            done[best] = true
            if not onFoot then
                local node = nodes[i]
                local same, land = g.byCi[node.p.ci], node.land
                for j = 1, same and #same or 0 do
                    local idx = same[j]
                    if idx ~= i and (nav or nodes[idx].land == land) then
                        local key = i * WALK_KEY + idx
                        local priced = walkSec[key]
                        local sec = priced or TravelCost(g, LeastYards(g, i, idx), bound)
                        local nd = bestD + sec
                        local to = idx + n
                        if nd < (dist[to] or mhuge) then
                            dist[to], prev[to] = nd, best
                            prevEdge[to] = TravelEdge(g, i, idx, sec, priced and walkWind[key] or nil)
                            heap:Push(nd, to)
                        end
                    end
                end
            end
            local rides = Rides(g, i)
            for j = 1, #rides do
                local e = rides[j]
                local h = e.hop
                if h then
                    local wait = g.waitAt(h.edge.route, h.edge.stop, bestD)
                    e = { to = e.to, sec = wait and (h.sec - (h.edge.wait or 0) + wait) or h.sec, pen = e.pen,
                          kind = e.kind, edge = e.edge, hostile = e.hostile, liveWait = wait }
                end
                local to = e.to
                local nd = bestD + e.sec + (e.pen or 0)
                if nd < (dist[to] or mhuge) then
                    dist[to], prev[to], prevEdge[to] = nd, best, e
                    heap:Push(nd, to)
                end
            end
        end
    end
    if not reached then return nil end
    local path = {}
    local s = reached
    while s and s ~= g.start do
        tinsert(path, 1, { node = s > n and s - n or s, edge = prevEdge[s] })
        s = prev[s]
    end
    return path, dist[reached]
end

local SOLVE_ROUNDS = 48

-- The shortest path with its walks priced on the walking grid: only walks a
-- best path takes are looked up, then the path is found again until it
-- holds. Once a path is priced through, its cost is the one to beat: a
-- later path's walk is searched only within the room that leaves it, and
-- the hunt ends when no path can come in under it. A path still holding
-- an unpriced walk is no path: it could be one no foot can take.
local function Solve(g)
    local U, bestPath = mhuge, nil
    for _ = 1, SOLVE_ROUNDS do
        local path, cost = Dijkstra(g)
        if not (path and g.nav) then return path, cost end
        if cost >= U - 1e-6 then return bestPath, U end
        local fresh, beyond = false, false
        for i = 1, #path do
            local from = i > 1 and path[i - 1].node or g.start
            local e = path[i].edge
            if e.kind == "travel" and not g.walkSec[from * WALK_KEY + path[i].node] then
                fresh = true
                if not PriceWalk(g, from, path[i].node, U - (cost - e.sec)) then beyond = true end
            end
        end
        if not fresh then return path, cost end
        if not beyond then
            local real = 0
            for i = 1, #path do
                local from = i > 1 and path[i - 1].node or g.start
                local e = path[i].edge
                real = real + (e.kind == "travel" and g.walkSec[from * WALK_KEY + path[i].node] or (e.sec + (e.pen or 0)))
            end
            if real < U then U, bestPath = real, path end
        end
    end
    return bestPath, bestPath and U or nil
end

-- Path cost in seconds (avoided ways' penalties in), each walk priced on
-- the walking grid where it has one.
local function PathSeconds(g, path)
    local total = 0
    for i = 1, #path do
        local e = path[i].edge
        if g.nav and e.kind == "travel" then
            e.sec, e.wind, e.near = PriceWalk(g, i > 1 and path[i - 1].node or g.start, path[i].node)
        end
        total = total + e.sec + (e.pen or 0)
    end
    return total
end

-- Steps

local KIND_KEY = {
    portal = "GPS_STEP_PORTAL_FMT", boat = "GPS_STEP_BOAT_FMT", zeppelin = "GPS_STEP_ZEPPELIN_FMT",
    tram = "GPS_STEP_TRAM_FMT", ferry = "GPS_STEP_BOAT_FMT", skyship = "GPS_STEP_SKYSHIP_FMT",
    seam = "GPS_STEP_TRAVEL_FMT",
}
-- What a crossing's step says while its spot is still a way off: which
-- dock, tower or portal to head for, named by where it goes.
local REACH_KEY = {
    boat = "GPS_REACH_BOAT_FMT", ferry = "GPS_REACH_BOAT_FMT", zeppelin = "GPS_REACH_ZEPPELIN_FMT",
    skyship = "GPS_REACH_SKYSHIP_FMT", tram = "GPS_REACH_TRAM_FMT", portal = "GPS_REACH_PORTAL_FMT",
}

-- Where a crossing leads: the dock area's own name, else its label;
-- the far map's name when ridden backwards or with neither.
local function EdgeDestName(e, reverse)
    local p = reverse and e.from or e.to
    local named = p and AreaName(p.area)
    if named then return named end
    if not reverse and e.dest then return e.dest end
    if not reverse and e.n then
        local dest = e.n:match("^[Pp]ortal to (.+)$") or e.n:match("^[Bb]oat to (.+)$")
            or e.n:match("^[Zz]eppelin to (.+)$") or e.n:match("^[Tt]ram to (.+)$") or e.n:match("^[Ss]hip to (.+)$")
        if dest then return dest end
    end
    return MapName(p and p.m)
end

-- Floor of a crossing's spot ("upper"/"lower"), recorded by hand:
-- the client zeroes the player's height.
local function FloorHint(_, p)
    local fl = p and p.fl
    if fl == "upper" or fl == "lower" then return fl end
    return nil
end

local function WithFloor(text, floor)
    if not floor then return text end
    local L = ns.L
    local word = floor == "lower" and L["GPS_FLOOR_LOWER"] or L["GPS_FLOOR_UPPER"]
    return text .. " (" .. tostring(word) .. ")"
end

-- Requirement table: quest, anyQuest, notQuest, minLevel, maxLevel, covenant,
-- reputation { id, standing }, art { map, artID }. Unanswerable counts as met.
local function Meets(req)
    if not req then return true end
    if req.quest and C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
        local ok, done = pcall(C_QuestLog.IsQuestFlaggedCompleted, req.quest)
        if ok and not done then return false end
    end
    if req.notQuest and C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
        local ok, done = pcall(C_QuestLog.IsQuestFlaggedCompleted, req.notQuest)
        if ok and done then return false end
    end
    if req.anyQuest and C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
        local any = false
        for i = 1, #req.anyQuest do
            local ok, done = pcall(C_QuestLog.IsQuestFlaggedCompleted, req.anyQuest[i])
            if ok and done then any = true break end
        end
        if not any then return false end
    end
    if (req.minLevel or req.maxLevel) and UnitLevel then
        local lvl = UnitLevel("player") or 0
        if req.minLevel and lvl < req.minLevel then return false end
        if req.maxLevel and lvl > req.maxLevel then return false end
    end
    if req.covenant and C_Covenants and C_Covenants.GetActiveCovenantID then
        local ok, id = pcall(C_Covenants.GetActiveCovenantID)
        if ok and id ~= req.covenant then return false end
    end
    if req.reputation and C_Reputation and C_Reputation.GetFactionDataByID then
        local ok, fd = pcall(C_Reputation.GetFactionDataByID, req.reputation[1])
        if ok and fd and (fd.reaction or 0) < (req.reputation[2] or 0) then return false end
    end
    if req.art and C_Map and C_Map.GetMapArtID then
        local ok, art = pcall(C_Map.GetMapArtID, req.art[1])
        if ok and art and art ~= req.art[2] then return false end
    end
    return true
end

-- Whether map m is goal, or lies under it (Crystalsong Forest under
-- Northrend).
local function WithinMap(m, goal)
    local depth = 0
    while m and depth < 8 do
        if m == goal then return true end
        local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(m)
        m = info and info.parentMapID
        depth = depth + 1
    end
    return false
end

-- A zone goal is reached on entering it: from any stop inside it the goal
-- is no walk further, so the way in is chosen, not the way to its middle.
local function ZoneGoal(g)
    g.zoneGoal = true
    local goal = g.nodes[g.goal].p
    for i = 1, #g.nodes do
        local p = g.nodes[i].p
        if i ~= g.goal and p and p.ci == goal.ci and WithinMap(p.m, goal.m) then
            g.walkSec[i * WALK_KEY + g.goal], g.walkWind[i * WALK_KEY + g.goal] = 0, nil
        end
    end
end

-- One step per path element; consecutive flight legs fold into one flight.
local function Steps(g, path, goalName)
    local L = ns.L
    -- A seam (Khaz Algar's Coreway) joins continent ids with no loading screen:
    -- the travel to it, the crossing and the travel after fold into one step.
    local folded, carry, k = {}, 0, 1
    while k <= #path do
        local el = path[k]
        local nxt, after = path[k + 1], path[k + 2]
        if el.edge.kind == "travel" and nxt and nxt.edge.kind == "seam" and after and after.edge.kind == "travel" then
            carry = carry + el.edge.sec + nxt.edge.sec
            k = k + 2
        else
            if carry > 0 then
                local e2 = {}
                for kk, v in pairs(el.edge) do e2[kk] = v end
                e2.sec = e2.sec + carry
                el = { node = el.node, edge = e2 }
                carry = 0
            end
            folded[#folded + 1] = el
            k = k + 1
        end
    end
    path = folded
    local steps = {}
    local i = 1
    -- The way to a flight master, dock or portal is its own step, named by what
    -- is taken there. approach = that way's seconds while pending.
    local approach, approachWind
    local function leadsInto(el, nxt)
        if not nxt or el.edge.kind ~= "travel" then return false end
        local node = g.nodes[el.node]
        if node.kind == "taxi" then return nxt.edge.kind == "taxi" end
        return node.edge ~= nil and nxt.edge.edge == node.edge
    end
    local function Approach(spot, text)
        if not (approach and spot) then return end
        tinsert(steps, { kind = "travel", approach = true, text = text,
                         mapID = spot.m, x = spot.x, y = spot.y, go = spot, arrive = spot, sec = approach,
                         wind = approachWind })
        approach, approachWind = nil, nil
    end
    while i <= #path do
        local el = path[i]
        local e = el.edge
        local node = g.nodes[el.node]
        if e.kind == "travel" and e.sec == 0 and #steps > 0 and not (node.kind == "goal" and g.zoneGoal) then
            -- Already there: the previous step ends on this spot.
            i = i + 1
        elseif leadsInto(el, path[i + 1]) then
            if e.sec > 0 then approach, approachWind = e.sec, e.wind end
            i = i + 1
        elseif e.kind == "travel" then
            local name
            if node.kind == "taxi" then name = node.name
            elseif node.kind == "edgeFrom" then
                -- A haul to a portal in another zone names the zone; the
                -- portal step that follows says what to take there.
                local from = g.nodes[i > 1 and path[i - 1].node or g.start]
                if from and from.p and node.p and from.p.m ~= node.p.m then name = MapName(node.p.m)
                else name = AreaName(node.p.area) or node.edge.n end
            elseif node.kind == "goal" then name = goalName
            else name = MapName(node.p.m) end
            -- A zone goal is reached on entering it: after a step that already
            -- lands inside it, the route ends where that step lands.
            local from = node.kind == "goal" and g.zoneGoal and #steps > 0 and g.nodes[i > 1 and path[i - 1].node or g.start]
            if from and from.p and WithinMap(from.p.m, node.p.m) then
                tinsert(steps, { kind = "travel", text = (L["GPS_STEP_ARRIVE_IN_FMT"]):format(name or "?"),
                                 mapID = from.p.m, x = from.p.x, y = from.p.y, go = from.p, arrive = from.p, sec = 0 })
            else
                tinsert(steps, { kind = "travel", text = (L["GPS_STEP_TRAVEL_FMT"]):format(name or "?"),
                                 mapID = node.p.m, x = node.p.x, y = node.p.y, go = node.p, arrive = node.p, sec = e.sec,
                                 wind = e.wind, near = e.near })
            end
            i = i + 1
        elseif e.kind == "taxi" then
            local fromNode = g.nodes[i > 1 and path[i - 1].node or g.start]
            local j = i
            local sec = 0
            while j <= #path and path[j].edge.kind == "taxi" do
                sec = sec + path[j].edge.sec
                j = j + 1
            end
            local last = g.nodes[path[j - 1].node]
            local fromName = fromNode and fromNode.name or "?"
            -- A flight from a master this character has not met yet: the
            -- step says to learn it there first.
            local learn = fromNode and fromNode.unknown or nil
            local key = learn and "GPS_STEP_FLY_NEW_FMT" or "GPS_STEP_FLY_FMT"
            local reachText = (L["GPS_REACH_FLIGHT_FMT"]):format(fromName)
            Approach(fromNode and fromNode.p, reachText)
            tinsert(steps, { kind = "taxi", text = (L[key]):format(fromName, last.name or "?"),
                             mapID = fromNode and fromNode.p.m, x = fromNode and fromNode.p.x, y = fromNode and fromNode.p.y,
                             go = fromNode and fromNode.p, arrive = last.p, sec = sec, edgeSec = sec,
                             reach = fromNode and fromNode.name, learn = learn, nodeID = fromNode and fromNode.id, toID = last.id,
                             reachText = reachText })
            i = j
        elseif e.kind == "teleport" then
            tinsert(steps, { kind = "teleport", text = (L["GPS_STEP_USE_FMT"]):format(e.ability.n or "?"),
                             mapID = node.p.m, x = node.p.x, y = node.p.y, go = nil, arrive = node.p, sec = e.sec, edgeSec = e.sec,
                             spellID = e.ability.id, itemID = e.ability.item, toy = e.ability.toy and true or nil,
                             abilityName = e.ability.n })
            i = i + 1
        else
            local key = KIND_KEY[e.kind] or "GPS_STEP_PORTAL_FMT"
            local from = g.nodes[i > 1 and path[i - 1].node or g.start]
            local floor = FloorHint(g, from.p)
            local wait = e.liveWait or e.edge.wait
            local dest = EdgeDestName(e.edge, e.reverse)
            local reachKey = REACH_KEY[e.kind]
            local reachText = reachKey and WithFloor((L[reachKey]):format(dest), floor) or nil
            Approach(from.p, reachText or (L["GPS_STEP_TRAVEL_FMT"]):format(AreaName(from.p.area) or MapName(from.p.m)))
            local text = WithFloor((L[key]):format(dest), floor)
            -- The other faction's transport: said so on the step.
            if e.hostile then text = text .. " (" .. (_G["HOSTILE"] or "Hostile") .. ")" end
            tinsert(steps, { kind = e.kind, text = text, hostile = e.hostile,
                             mapID = from.p.m, x = from.p.x, y = from.p.y, go = from.p, arrive = node.p,
                             sec = e.sec - (e.hostile and HOSTILE_SECONDS or 0),
                             edgeSec = e.sec - (wait or 0) - (e.hostile and HOSTILE_SECONDS or 0), wait = wait,
                             live = e.liveWait and true or nil,
                             route = not e.reverse and e.edge.route or nil, stop = not e.reverse and e.edge.stop or nil,
                             reach = e.edge.n, reachText = reachText,
                             floor = floor })
            i = i + 1
        end
    end
    return steps
end

-- Advice: flight paths worth learning

-- Unlearned flight masters a short detour off a ride the route makes,
-- in route order; never the one a flight already starts from.
local function Pickups(g, path, used)
    local out, seen = {}, {}
    for i = 1, #path do
        local el = path[i]
        if el.edge.kind == "travel" then
            local a = g.nodes[i > 1 and path[i - 1].node or g.start].p
            local b = g.nodes[el.node].p
            local ab = Dist(a, b)
            local same = g.byCi[a.ci]
            for j = 1, same and #same or 0 do
                local n = g.nodes[same[j]]
                if n.kind == "taxi" and n.unknown and not seen[n.id] and not used[n.id] and same[j] ~= el.node then
                    local extra = Dist(a, n.p) + Dist(n.p, b) - ab
                    if extra <= PICKUP_YARDS then
                        seen[n.id] = true
                        out[#out + 1] = { id = n.id, name = n.name, p = n.p, detour = TravelCost(g, extra) }
                    end
                end
            end
        end
    end
    return out
end

local function MostSavedFirst(a, b) return a.most > b.most end

-- The unlearned flight master that would shorten this trip most, among those
-- nearest the start and goal; nil unless it saves a minute and a sixth.
local function BestToLearn(ctx, g, total, usedAsOrigin)
    if not ctx.known then return nil end
    local cands = {}
    for id, idx in pairs(g.taxiIdx) do
        local n = g.nodes[idx]
        if n.unknown and not usedAsOrigin[id] then
            local d = mhuge
            if n.p.ci == ctx.goal.ci then d = Dist(n.p, ctx.goal) end
            if n.p.ci == ctx.start.ci then d = math.min(d, Dist(n.p, ctx.start)) end
            if d < mhuge then cands[#cands + 1] = { id = id, d = d, n = n } end
        end
    end
    tsort(cands, function(a, b) return a.d < b.d end)
    local known = {}
    for k, v in pairs(ctx.known) do known[k] = v end
    local trial = {}
    for k, v in pairs(ctx) do trial[k] = v end
    trial.known = known
    -- Each trip with unpriced walks first: the most it could save.
    local trips = {}
    for i = 1, mmax(0, math.min(#cands, SUGGEST_CANDIDATES)) do
        Pause()
        local c = cands[i]
        known[c.id] = true
        local g2 = BuildGraph(trial)
        if g.zoneGoal then ZoneGoal(g2) end
        local path2, t2 = Dijkstra(g2)
        known[c.id] = nil
        if path2 and total - t2 >= SUGGEST_MIN_SECONDS then
            trips[#trips + 1] = { c = c, g = g2, most = total - t2 }
        end
    end
    tsort(trips, MostSavedFirst)
    -- Then priced on the walking grid, until no trip left could beat the best found.
    local best
    for i = 1, #trips do
        local trip = trips[i]
        if best and trip.most <= best.save then break end
        local path2 = Solve(trip.g)
        local t2 = path2 and PathSeconds(trip.g, path2) or mhuge
        local save = total - t2
        if save >= SUGGEST_MIN_SECONDS and save >= total / 6 and (not best or save > best.save) then
            best = { id = trip.c.id, name = trip.c.n.name, p = trip.c.n.p, save = save, total = t2 }
            -- How that trip goes, its rides and flights: often not the way
            -- shown, so the tip lists them.
            local way = {}
            for _, s in ipairs(Steps(trip.g, path2)) do
                if s.kind ~= "travel" and s.text then way[#way + 1] = s.text end
            end
            best.way = way
        end
    end
    return best
end

-- What this character can use, from the client

local knownCache          -- { at = GetTime(), set, listed, names }
local markerCache = {}    -- mapID -> { at = GetTime(), names = { name = true } }
local CACHE_SECONDS = 120

-- Learned flight points, the points listed at all, and their client names.
-- Nil when the client cannot say: every point counts.
local function KnownFlightNodes(data)
    if not (C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap) then return nil end
    local now = GetTime and GetTime() or 0
    if knownCache and now - knownCache.at < CACHE_SECONDS then return knownCache.set, knownCache.listed, knownCache.names end
    local maps, set, listed, names, seen = {}, {}, {}, {}, 0
    for _, n in pairs(data.nodes or {}) do
        if n.m then maps[n.m] = true end
    end
    for m in pairs(maps) do
        local ok, list = pcall(C_TaxiMap.GetTaxiNodesForMap, m)
        if ok and list then
            for i = 1, #list do
                local info = list[i]
                if info.nodeID then
                    seen = seen + 1
                    listed[info.nodeID] = true
                    if info.name and info.name ~= "" then names[info.nodeID] = info.name end
                    if not info.isUndiscovered then set[info.nodeID] = true end
                end
            end
        end
    end
    if seen == 0 then return nil end
    knownCache = { at = now, set = set, listed = listed, names = names }
    return set, listed, names
end

-- Whether the client shows this character the named marker on the map.
local function MarkerPresent(m, name)
    if not (C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIForMap and m and name) then return nil end
    local now = GetTime and GetTime() or 0
    local c = markerCache[m]
    if not c or now - c.at >= CACHE_SECONDS then
        local names, count = {}, 0
        local ok, ids = pcall(C_AreaPoiInfo.GetAreaPOIForMap, m)
        if ok and ids then
            for i = 1, #ids do
                local ok2, info = pcall(C_AreaPoiInfo.GetAreaPOIInfo, m, ids[i])
                if ok2 and info and info.name then
                    names[info.name:lower()] = true
                    count = count + 1
                end
            end
        end
        c = { at = now, names = names, count = count }
        markerCache[m] = c
    end
    -- No markers listed is no verdict: far maps list theirs only sometimes.
    -- "Absent" needs other markers shown; names match loosely.
    if c.count == 0 then return nil end
    local lname = name:lower()
    if c.names[lname] then return true end
    for n in pairs(c.names) do
        if lname:find(n, 1, true) == 1 or n:find(lname, 1, true) == 1 then return true end
    end
    return false
end
-- For the dev tools' route study: the per-character gates, inspectable.
Route.MarkerPresent = MarkerPresent
Route.KnownFlightNodes = KnownFlightNodes

-- Flight masters seen as known at a flight master (filled from saved
-- variables): known whatever the map listing says.
Route.recordedKnown = nil
-- Riding as the client rules it: the riding skill each riding spell
-- gives, and per mount type what it can do, best first:
-- { riding skill, spell to know (0 none), ground %, flying % or "sky", steady style }.
-- gps_riding.py: begin
local RIDING = {
    forever = {
        skill = { [33388] = 75, [33391] = 150 },
        sets = {
            { { 75, 0, 60 } },
            { { 150, 0, 100 } },
            { { 75, 825, 60 } },
            { { 150, 825, 100 } },
            { { 75, 828, 60 } },
            { { 150, 828, 100 } },
            { { 75, 826, 60 } },
            { { 150, 826, 100 } },
            { { 75, 10861, 60 } },
            { { 150, 10861, 100 } },
            { { 75, 18995, 60 } },
            { { 150, 18995, 100 } },
            { { 75, 10907, 60 } },
            { { 150, 10907, 100 } },
            { { 75, 10906, 60 } },
            { { 150, 10906, 100 } },
            { { 75, 824, 60 } },
            { { 150, 824, 100 } },
            { { 0, 0, 60 } },
            { { 0, 0, 100 } },
            { { 150, 1285849, 100 } },
            { { 75, 1285849, 60 } },
            { { 150, 0, 100 }, { 75, 0, 60 } },
        },
        types = {
            [453] = 1, [454] = 2, [455] = 3, [456] = 4, [457] = 5, [458] = 6, [459] = 7, [460] = 8,
            [461] = 9, [462] = 10, [463] = 11, [464] = 12, [465] = 13, [466] = 14, [467] = 15, [468] = 16,
            [469] = 17, [470] = 18, [471] = 19, [472] = 20, [473] = 21, [474] = 22, [475] = 19, [476] = 2,
            [485] = 23, [487] = 20,
        },
    },
    retail = {
        skill = { [33388] = 75, [33391] = 150, [34090] = 225, [34091] = 300, [90265] = 375 },
        sets = {
            { { 150, 0, 100 }, { 75, 0, 60 } },
            { { 0, 0, 100, 320 } },
            { { 375, 0, 100, 420, true }, { 300, 0, 100, 320, true }, { 225, 0, 100, 220, true }, { 150, 0, 100 }, { 75, 0, 60 } },
            { { 0, 0, 60 } },
            { { 0, 0, 100 } },
            { { 75, 376777, 100, "sky" }, { 375, 0, 100, 420, true }, { 300, 0, 100, 320, true }, { 225, 0, 100, 220, true }, { 150, 0, 100 }, { 75, 0, 60 } },
            { { 375, 0, 100, 310, true }, { 300, 0, 100, 280, true }, { 225, 0, 100, 150, true }, { 150, 0, 100 }, { 75, 0, 60 } },
            { { 0, 0, 0, "sky" } },
            { { 1, 0, 100, "sky" }, { 150, 0, 100 }, { 75, 0, 60 } },
            { { 0, 0, 100, "sky" } },
            { { 0, 0, 100, "sky" }, { 75, 0, 60 } },
            { { 75, 376777, 100, "sky" }, { 0, 0, 0, "sky" } },
            { { 75, 376777, 100, "sky" }, { 375, 0, 100, 310, true }, { 300, 0, 100, 280, true }, { 225, 0, 100, 150, true }, { 150, 0, 100 }, { 75, 0, 60 } },
            { { 375, 0, 100, 420, true }, { 300, 0, 100, 320, true }, { 225, 0, 100, 220, true }, { 0, 0, 0, "sky" } },
        },
        types = {
            [230] = 1, [242] = 2, [247] = 3, [284] = 4, [291] = 5, [402] = 6, [407] = 7, [409] = 8,
            [411] = 9, [412] = 1, [424] = 6, [426] = 10, [430] = 11, [435] = 12, [436] = 13, [437] = 6,
            [442] = 14, [444] = 6, [445] = 6, [446] = 10, [447] = 5,
        },
    },
}
-- gps_riding.py: end

local STEADY_STYLE = 404468   -- the "Flight Style: Steady" aura
-- The capability sets of the mounts this character owns; nil until the
-- journal is walked again (a mount learned or lost).
local ownedSets

function Route.ForgetKnown() knownCache = nil end
function Route.ForgetMounts() ownedSets = nil end

if CreateFrame then
    local f = CreateFrame("Frame")
    f:RegisterEvent("TAXI_NODE_STATUS_CHANGED")
    f:SetScript("OnEvent", function() knownCache = nil end)
    local mounts = CreateFrame("Frame")
    for _, event in ipairs({ "NEW_MOUNT_ADDED", "COMPANION_LEARNED", "COMPANION_UNLEARNED" }) do
        if C_EventUtils and C_EventUtils.IsEventValid and C_EventUtils.IsEventValid(event) then mounts:RegisterEvent(event) end
    end
    mounts:SetScript("OnEvent", Route.ForgetMounts)
end

local function OwnedSets(rules)
    if ownedSets then return ownedSets end
    ownedSets = {}
    local J = C_MountJournal
    local ids = J and J.GetMountIDs and J.GetMountIDs()
    for i = 1, ids and #ids or 0 do
        local _, _, _, _, _, _, _, _, _, hidden, collected = J.GetMountInfoByID(ids[i])
        if collected and not hidden then
            local set = rules.types[select(5, J.GetMountInfoExtraByID(ids[i]))]
            if set then ownedSets[set] = true end
        end
    end
    return ownedSets
end

-- The capability the game picks: the first whose needs are met.
local function Capability(set, riding, flyable, sky, steady)
    for i = 1, #set do
        local c = set[i]
        if riding >= c[1] and (c[2] == 0 or (IsPlayerSpell and IsPlayerSpell(c[2]))) then
            local fly = c[4]
            if not fly or (fly == "sky" and sky and not steady) or (fly ~= "sky" and flyable and (steady or not c[5])) then
                return c[3], fly
            end
        end
    end
end

-- This character's pace on the ground and, where it can fly here, in the
-- air, yards a second (flying nil). Riding skill, mounts owned and the
-- zone, all as the client has them now.
function Route.Riding(data)
    local rules = RIDING[(data and data.classic) and "forever" or "retail"]
    local riding = 0
    for spell, skill in pairs(rules.skill) do
        if skill > riding and IsPlayerSpell and IsPlayerSpell(spell) then riding = skill end
    end
    local okFly, flyable = pcall(IsFlyableArea)
    flyable = okFly and flyable and true or false
    local sky, steady = false, false
    if flyable then
        sky = IsAdvancedFlyableArea and IsAdvancedFlyableArea() and true or false
        local aura = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID and C_UnitAuras.GetPlayerAuraBySpellID(STEADY_STYLE)
        if not (issecretvalue and issecretvalue(aura)) then steady = aura ~= nil end
    end
    local skySpeed = data and data.speeds and data.speeds.fly or 30
    local groundPct, fly = nil, nil
    for set in pairs(OwnedSets(rules)) do
        local pct = Capability(rules.sets[set], riding, false, false, false)
        if pct and (not groundPct or pct > groundPct) then groundPct = pct end
        if flyable then
            local _, flies = Capability(rules.sets[set], riding, flyable, sky, steady)
            local speed = flies == "sky" and skySpeed or flies and RUN * (1 + flies / 100) or nil
            if speed and (not fly or speed > fly) then fly = speed end
        end
    end
    return groundPct and RUN * (1 + groundPct / 100) or RUN, fly
end

function Route.GroundSpeed(data) return (Route.Riding(data)) end
-- For the dev tools' riding probe.
Route.RIDING, Route.RidingCapability = RIDING, Capability

-- Seconds for this many yards from a standstill, as the engine prices travel.
-- opts.taxi: on a flight. opts.wind: a walk's yards walked per straight yard.
function Route:TravelSeconds(yards, opts)
    local data = (opts and opts.data) or ns.GPSData
    local speeds = data and data.speeds or { run = 7, mount = 14, fly = 30, taxi = 32 }
    if not yards or yards <= 5 then return 0 end
    if opts and opts.taxi then return yards / (speeds.taxi or 32) end
    local canFly, flySpeed = opts and opts.canFly, opts and opts.flySpeed
    if canFly == nil then
        local _, fly = Route.Riding(data)
        canFly, flySpeed = fly ~= nil, fly
    end
    if canFly then return MOUNT_UP + yards / (flySpeed or speeds.fly or 30) end
    local speed = (opts and opts.groundSpeed) or Route.GroundSpeed(data)
    local mountUp = speed <= RUN + 0.5 and 0 or MOUNT_UP
    return mountUp + yards * ((opts and opts.wind) or ((data and data.classic) and WALK_DETOUR or 1)) / speed
end

-- Public

local LEARN_SECONDS = 8   -- talking to a flight master to learn its path

local function Copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

-- The trip with stops to learn flight masters, via = { id, name, p } or a
-- list of them in the order the trip meets them: the way to each, a step
-- to learn it, then on with its flight path known.
local function ViaStop(route, dest, opts, start, known, listed)
    local L = ns.L
    local list = opts.via.id and { opts.via } or opts.via
    local via = list[1]
    local rest = {}
    for i = 2, #list do rest[#rest + 1] = list[i] end
    local here = Resolve(via.p)
    if not here then return nil end
    local o = Copy(opts)
    o.via, o.advise, o.start, o.known, o.listed, o.draw = nil, false, start, known or false, listed, nil
    local s1, t1 = route:Build({ name = via.name, mapID = here.m, x = here.x, y = here.y }, o)
    if not s1 then return nil end
    local learned = {}
    for id in pairs(known or {}) do learned[id] = true end
    learned[via.id] = true
    o.start, o.known = here, known and learned or false
    o.via = #rest > 0 and rest or nil
    local s2, t2 = route:Build(dest, o)
    if not s2 then return nil end
    local steps = {}
    for i = 1, #s1 do steps[#steps + 1] = s1[i] end
    steps[#steps + 1] = { kind = "learn", text = (L["GPS_STEP_LEARN_FMT"]):format(via.name or "?"),
                          mapID = here.m, x = here.x, y = here.y, go = here, arrive = here, sec = LEARN_SECONDS,
                          nodeID = via.id, reach = via.name, reachText = (L["GPS_REACH_FLIGHT_FMT"]):format(via.name or "?") }
    for i = 1, #s2 do steps[#steps + 1] = s2[i] end
    return steps, t1 + LEARN_SECONDS + t2
end

local function Cooldown(a)
    if a.item and C_Item and C_Item.GetItemCooldown then
        local ok, s, d = pcall(C_Item.GetItemCooldown, a.item)
        if ok and d and d > 5 then return mmax(0, s + d - GetTime()) end
    elseif a.id and C_Spell and C_Spell.GetSpellCooldown then
        local ok, cd = pcall(C_Spell.GetSpellCooldown, a.id)
        if ok and cd and cd.duration and cd.duration > 5 then return mmax(0, cd.startTime + cd.duration - GetTime()) end
    end
    return 0
end

-- Whether this character can use a teleport now.
local function Owns(a)
    if a.toy and PlayerHasToy then
        -- Engineering toys sit in every toy box: owned is not usable.
        if not PlayerHasToy(a.item) then return false end
        if C_ToyBox and C_ToyBox.IsToyUsable then
            local ok, usable = pcall(C_ToyBox.IsToyUsable, a.item)
            if ok and usable == false then return false end
        end
        return true
    end
    if a.item and C_Item and C_Item.GetItemCount then
        if (C_Item.GetItemCount(a.item) or 0) == 0 then return false end
        if C_Item.IsUsableItem then
            local ok, usable = pcall(C_Item.IsUsableItem, a.item)
            if ok and usable == false then return false end
        end
        return true
    end
    -- A spell this character can cast now: IsPlayerSpell sees
    -- through overrides and talent swaps where IsSpellKnown misses.
    if a.id and IsPlayerSpell then return IsPlayerSpell(a.id) end
    if a.id and IsSpellKnown then return IsSpellKnown(a.id) end
    return true
end
Route.Owns = Owns

-- The flight masters this character knows: known, listed, names.
local function KnownSet(data)
    local known, listed, names = KnownFlightNodes(data)
    local recorded = Route.recordedKnown
    if data.classic then
        -- Forever's map listing marks every point discovered, learned
        -- or not: only what a flight master's own map showed counts.
        known = {}
        for k in pairs(recorded or {}) do known[k] = true end
    elseif known and recorded and next(recorded) then
        local merged = {}
        for k in pairs(known) do merged[k] = true end
        for k in pairs(recorded) do merged[k] = true end
        known = merged
    end
    return known, listed, names
end
Route.KnownSet = KnownSet

local function ByExtra(a, b) return a.extra < b.extra end
local function ByOrder(a, b) return a.order < b.order end

-- Flight points learned on the way without asking: the cheapest offers
-- first, while their extra time together stays within the budget (a share
-- of the trip, capped). A stop that costs nothing is always taken. Never
-- one the player dropped (opts.skipLearn), and on Forever only once this
-- character's learned points were recorded: before that every point looks
-- new. Taken offers leave the advice. Returns the steps and total.
function Route:TakeCheapLearns(dest, priced, advice, steps, total, opts, data)
    local recorded = Route.recordedKnown
    local trusted = not data.classic or (recorded and next(recorded) ~= nil)
    local budget = (opts.autoLearn and trusted) and math.min(AUTO_LEARN_CAP, total * AUTO_LEARN_SHARE) or 0
    local skip = opts.skipLearn
    local cands = {}
    for i = 1, #advice.pickups do
        local p = advice.pickups[i]
        p.order = i
        cands[#cands + 1] = p
    end
    if advice.learn then
        advice.learn.order = #advice.pickups + 1
        cands[#cands + 1] = advice.learn
    end
    local chosen, spent = {}, 0
    local usable = {}
    for i = 1, #cands do
        local c = cands[i]
        if c.extra and not (skip and skip[c.id]) then usable[#usable + 1] = c end
    end
    tsort(usable, ByExtra)
    for i = 1, #usable do
        local c = usable[i]
        local cost = mmax(0, c.extra)
        if #chosen < AUTO_LEARN_STOPS and spent + cost <= budget then
            chosen[#chosen + 1] = c
            spent = spent + cost
        end
    end
    -- Together they may cost more than their sum: the dearest goes until
    -- the whole trip fits.
    while #chosen > 0 do
        local via = {}
        for i = 1, #chosen do via[i] = chosen[i] end
        tsort(via, ByOrder)
        priced.via = via
        local viaSteps, viaTotal = self:Build(dest, priced)
        if viaSteps and viaTotal and viaTotal - total <= budget + 1 then
            local taken = {}
            for i = 1, #via do taken[via[i].id] = true end
            local keep = {}
            for i = 1, #advice.pickups do
                if not taken[advice.pickups[i].id] then keep[#keep + 1] = advice.pickups[i] end
            end
            advice.pickups = keep
            if advice.learn and taken[advice.learn.id] then advice.learn = nil end
            return viaSteps, viaTotal
        end
        chosen[#chosen] = nil
    end
    return steps, total
end

-- Route from the player to dest { name, mapID, x, y }: steps, total seconds,
-- advice { pickups, learn = { id, name, p, save, total } }; nil without data.
-- opts.autoLearn: learn cheap flight points on the way; opts.skipLearn: the
-- flight master ids the player dropped from this trip.
function Route:Build(dest, opts)
    opts = opts or {}
    local data = opts.data or ns.GPSData
    if not data then return nil end
    local goal = Resolve({ m = dest.mapID, x = dest.x, y = dest.y })
    if not goal then return nil end
    local Nav = ns.GPSNav
    if dest.zone and Nav and Nav.Ground then
        local wx, wy = Nav.Ground(goal.ci, goal.wx, goal.wy, ZONE_GROUND_CELLS)
        if wx then goal = { m = goal.m, x = goal.x, y = goal.y, ci = goal.ci, wx = wx, wy = wy } end
    end
    local start = opts.start
    if not start then
        local m = C_Map.GetBestMapForUnit("player")
        local ok, pos
        if m then ok, pos = pcall(C_Map.GetPlayerMapPosition, m, "player") end
        if ok and pos then
            local x, y = pos:GetXY()
            if x and (x ~= 0 or y ~= 0) then start = Resolve({ m = m, x = x, y = y }) end
        end
    end
    if not start then return nil end
    local known, listed, names
    if opts.known ~= nil then
        known, listed = opts.known or nil, opts.listed
    else
        known, listed, names = KnownSet(data)
    end
    -- Walks go around what this character should not walk through
    -- (opts.level: the character's level, the player's by default).
    local Npcs = ns.GPSNpcs
    if Nav and Nav.SetDanger then
        local on = opts.avoid and opts.avoid.danger and Npcs and Npcs.DangerTiles
        Nav.SetDanger(on and Npcs.DangerTiles(opts.level or (UnitLevel and UnitLevel("player")),
            opts.faction or (UnitFactionGroup and UnitFactionGroup("player"))) or nil)
        Nav.SetRoads(opts.avoid and opts.avoid.offroad)
    end
    -- The highest drop walks take (Jumps.lua): the safe one when jumps are avoided.
    if Nav and Nav.SetDropLimit then
        local J = ns.GPSJumps
        local jumps = not (opts.avoid and opts.avoid.jumps)
        Nav.SetDropLimit(jumps and (opts.dropLimit or (J and J.Limit(start.ci))) or nil)
    end
    if opts.via then return ViaStop(self, dest, opts, start, known, listed) end
    local ctx = {
        start = start, goal = goal, data = data,
        faction = opts.faction or (UnitFactionGroup and UnitFactionGroup("player")) or "Neutral",
        class = opts.class or (UnitClass and select(2, UnitClass("player"))) or nil,
        race = opts.race or (UnitRace and select(2, UnitRace("player"))) or nil,
        meets = opts.meets or Meets,
        canFly = opts.canFly,
        flySpeed = opts.flySpeed,
        groundSpeed = opts.groundSpeed,
        hearth = opts.hearth,
        avoid = opts.avoid,
        flown = opts.flown,
        waitAt = opts.waitAt or (ns.GPSBoats and ns.GPSBoats.WaitAt),
        bindName = opts.bindName or (GetBindLocation and GetBindLocation()) or nil,
        known = known,
        listed = listed,
        nodeName = names and function(id) return names[id] end or nil,
        hasMarker = opts.hasMarker or MarkerPresent,
        cooldown = opts.cooldown or Cooldown,
        owns = opts.owns or Owns,
    }
    if ctx.canFly == nil or not ctx.groundSpeed then
        local ground, fly = Route.Riding(data)
        if ctx.canFly == nil then ctx.canFly, ctx.flySpeed = fly ~= nil, fly end
        ctx.groundSpeed = ctx.groundSpeed or ground
    end
    local g = BuildGraph(ctx)
    if dest.zone then ZoneGoal(g) end
    local path = Solve(g)
    if not path then return nil end
    local cost = PathSeconds(g, path)
    local steps = Steps(g, path, dest.name)
    -- opts.draw: "first" draws the walk set out on (and the last, into a
    -- zone goal), "all" every walk; else none, for a route to compare.
    if g.nav and opts.draw then DrawWalks(steps, start, opts.draw == "all", dest.zone) end
    local total = 0
    for i = 1, #steps do total = total + (steps[i].sec or 0) end
    local advice
    if opts.advise ~= false then
        local used = {}
        for i = 1, #steps do
            if steps[i].learn and steps[i].nodeID then used[steps[i].nodeID] = true end
        end
        advice = { pickups = Pickups(g, path, used), learn = BestToLearn(ctx, g, cost, used) }
        -- What each stop really costs: this trip built with it.
        local priced = Copy(opts)
        priced.advise, priced.start, priced.known, priced.listed, priced.draw = false, start, known or false, listed, nil
        local function Price(item)
            priced.via = item
            local _, t = self:Build(dest, priced)
            item.viaTotal = t
            item.extra = t and (t - total) or nil
        end
        for i = 1, #advice.pickups do Price(advice.pickups[i]) end
        local learn = advice.learn
        if learn then Price(learn) end
        steps, total = self:TakeCheapLearns(dest, priced, advice, steps, total, opts, data)
        if #advice.pickups == 0 and not advice.learn then advice = nil end
    end
    return steps, total, advice
end

-- Walks on WoW Forever's walking grid (Nav.lua)

local WALK_PATHS_KEPT = 512
local walkPaths, walkPathCount = {}, 0

-- Keyed under the grid's settings too (Nav.epoch): a way drawn around the
-- dangers of one route stays good once those settings come back, and the
-- other ways' trials in between never throw the shown route's ways out.
local function WalkKey(ci, sx, sy, tx, ty, near)
    local Nav = ns.GPSNav
    return (Nav and Nav.epoch or 0) .. ":" .. ci .. ":" .. mfloor(sx) .. ":" .. mfloor(sy) .. ":" .. mfloor(tx) .. ":" .. mfloor(ty)
        .. (near and (":n" .. near) or "")
end

function Route.ForgetWalkPaths() walkPaths, walkPathCount = {}, 0 end

local function KeepPath(key, path)
    if walkPathCount >= WALK_PATHS_KEPT then walkPaths, walkPathCount = {}, 0 end
    walkPaths[key], walkPathCount = path, walkPathCount + 1
end

-- A walk's way on foot: { pts (world yards, x y pairs), cum[vertex] (yards
-- so far), len (yards walked), time (running yards: swimming takes longer),
-- jumps (each drop that costs health: at, yards along it to its ledge, the
-- ledge x, y and its height h) },
-- false when no way leads there, nil without walking data for ci. lazy:
-- nil too when it is not drawn yet; the planner draws, everything else
-- asks lazily and is told when it is there. near: it ends within that many
-- yards of (tx, ty), as its step was priced (step.near).
function Route.WalkPath(ci, sx, sy, tx, ty, lazy, near)
    local Nav = ns.GPSNav
    if not (Nav and Nav.Ensure(ci)) then return nil end
    local key = WalkKey(ci, sx, sy, tx, ty, near)
    local path = walkPaths[key]
    if path == nil and not lazy then
        local pts, _, time, jumps = Nav.Path(ci, sx, sy, tx, ty, near and { near = near } or nil)
        if pts then
            local cum = { 0 }
            for v = 2, #pts / 2 do
                cum[v] = cum[v - 1] + msqrt((pts[2 * v - 1] - pts[2 * v - 3]) ^ 2 + (pts[2 * v] - pts[2 * v - 2]) ^ 2)
            end
            local list
            for k = 1, jumps and #jumps or 0 do
                local v = mmax(1, jumps[k].v - 1)
                list = list or {}
                list[#list + 1] = { at = cum[v], x = pts[2 * v - 1], y = pts[2 * v], h = jumps[k].h }
            end
            path = { pts = pts, cum = cum, len = cum[#cum], time = time or cum[#cum], jumps = list }
        else
            path = false
        end
        KeepPath(key, path)
    end
    return path
end

-- The stretch of a drawn walk from `from` to `stop` yards along it, between
-- (sx, sy) and (ex, ey), kept as the walk between those: a piece of a split
-- walk is then followed and drawn without a search of its own.
local function KeepStretch(ci, path, from, stop, sx, sy, ex, ey, near)
    local pts, cum = path.pts, path.cum
    local out, ocum = { sx, sy }, { 0 }
    for v = 1, #pts / 2 do
        if cum[v] > from and cum[v] < stop then
            out[#out + 1], out[#out + 2] = pts[2 * v - 1], pts[2 * v]
            ocum[#ocum + 1] = cum[v] - from
        end
    end
    out[#out + 1], out[#out + 2] = ex, ey
    ocum[#ocum + 1] = stop - from
    KeepPath(WalkKey(ci, sx, sy, ex, ey, near), { pts = out, cum = ocum, len = stop - from,
                                             time = path.time * (stop - from) / mmax(1, path.len) })
end

-- Walks, zone by zone

local WALK_SAMPLE = 100    -- yards between zone readings along a walk
local WALK_MIN_RUN = 150   -- a zone crossed for less than this is no step

local function PointWorld(p)
    if not p then return nil end
    if p.wx and p.ci then return p.ci, p.wx, p.wy end
    return WorldPos(p.m, p.x, p.y)
end

-- One walked step as a step per zone its way crosses, or nil when it stays
-- in one zone, no way on foot leads there, or its way is not drawn yet.
local function WalkPieces(step, from, data, env, first)
    local target = step.go or step.arrive
    local ci, fx, fy = PointWorld(from)
    local ci2, tx, ty = PointWorld(target)
    if not (ci and ci == ci2) then return nil end
    local path = Route.WalkPath(ci, fx, fy, tx, ty, true, step.near)
    if not path then return nil end
    step.jumps = path.jumps
    local pts, cum = path.pts, path.cum
    local runs = {}
    local function Read(x, y, at)
        local map, name = env.zoneAt(ci, x, y)
        local run = runs[#runs]
        if map and (not run or run.map ~= map) then
            runs[#runs + 1] = { map = map, name = name or "?", at = at, x = x, y = y }
        end
    end
    for v = 1, #pts / 2 do
        if v > 1 then
            local ax, ay, seg = pts[2 * v - 3], pts[2 * v - 2], cum[v] - cum[v - 1]
            local extra = mfloor(seg / WALK_SAMPLE)
            for s = 1, extra do
                local t = s / (extra + 1)
                Read(ax + t * (pts[2 * v - 1] - ax), ay + t * (pts[2 * v] - ay), cum[v - 1] + t * seg)
            end
        end
        Read(pts[2 * v - 1], pts[2 * v], cum[v])
    end
    -- A zone clipped for a few yards (a border the way runs along) is
    -- no step; its stretch joins the zone before it.
    local r = 1
    while r <= #runs and #runs > 1 do
        local stop = runs[r + 1] and runs[r + 1].at or path.len
        if stop - runs[r].at < WALK_MIN_RUN then
            table.remove(runs, r)
            if r == 1 then
                runs[1].at, runs[1].x, runs[1].y = 0, fx, fy
            elseif runs[r] and runs[r].map == runs[r - 1].map then
                table.remove(runs, r)
            end
        else
            r = r + 1
        end
    end
    -- Setting out from inside a city: getting out of it is the first
    -- step, up to the way's first turn.
    local city = first and env.startCity
    if city and runs[1] and runs[1].map ~= city.map and #pts >= 4
       and cum[2] < (runs[2] and runs[2].at or path.len) then
        runs[1].at, runs[1].x, runs[1].y = cum[2], pts[3], pts[4]
        table.insert(runs, 1, { map = city.map, name = city.name or "?", at = 0, x = fx, y = fy })
    end
    -- A zone goal is reached on entering it: the walk ends at its border,
    -- where the step before's stretch ends.
    local count = #runs
    local intoGoal = env.goalZone and count > 1 and runs[count].map == env.goalZone
    if intoGoal then count = count - 1 end
    if count < 2 and not intoGoal then return nil end
    -- One step per walk (the setting): only a zone goal's border ends it early.
    local firstRun = 1
    if env.wholeWalks then
        if not intoGoal then return nil end
        firstRun = count
        runs[count].at, runs[count].x, runs[count].y = 0, fx, fy
    end
    local L = ns.L
    local out = {}
    for k = firstRun, count do
        local run, nxt = runs[k], runs[k + 1]
        local piece = {}
        for key, value in pairs(step) do piece[key] = value end
        local border = (k < count or intoGoal) and nxt or nil
        local stop = border and border.at or path.len
        piece.jumps = nil
        for _, j in ipairs(path.jumps or {}) do
            if j.at >= run.at and j.at < stop then
                piece.jumps = piece.jumps or {}
                piece.jumps[#piece.jumps + 1] = j
            end
        end
        if step.sec then piece.sec = step.sec * (stop - run.at) / path.len end
        local ex, ey = tx, ty
        if border then ex, ey = border.x, border.y end
        local straight = msqrt((ex - run.x) ^ 2 + (ey - run.y) ^ 2)
        piece.wind = straight > 5 and mmax(1, (stop - run.at) / straight) or nil
        piece.walkZone = run.map
        if border then
            -- Up to the border: done on entering the next zone.
            local mx, my
            if env.mapPos then mx, my = env.mapPos(ci, border.x, border.y, run.map) end
            -- A border the zone's own map cannot place: the walk stays whole.
            if env.mapPos and not mx then return nil end
            local spot = { ci = ci, wx = border.x, wy = border.y, m = run.map, x = mx, y = my }
            piece.mapID, piece.x, piece.y, piece.go, piece.arrive = run.map, mx, my, spot, spot
            piece.enter = border.map
            piece.near = nil   -- a border is reached itself
            if env.wholeWalks then
                piece.text = step.text
            elseif k < count and env.isCity and env.isCity(run.map) then
                piece.text = (L["GPS_STEP_EXIT_FMT"]):format(run.name)
            else
                piece.text = (L["GPS_STEP_WALK_THROUGH_FMT"]):format(run.name, border.name)
            end
        end
        KeepStretch(ci, path, run.at, stop, run.x, run.y, ex, ey, piece.near)
        out[#out + 1] = piece
    end
    return out
end

-- Each long walk as a step per zone crossed. env: zoneAt(ci, wx, wy) -> map, name;
-- mapPos(ci, wx, wy, mapID); isCity(mapID); startCity { map, name }; goalZone;
-- wholeWalks: a walk stays one step.
function Route.SplitWalks(steps, start, data, env)
    local out = {}
    for i = 1, #steps do
        local step = steps[i]
        local pieces
        -- A ghost's walk to its corpse stays one step, from where it released.
        if step.kind == "travel" and not step.corpse then
            pieces = WalkPieces(step, i == 1 and start or steps[i - 1].arrive, data, env, i == 1)
        end
        if pieces then
            for k = 1, #pieces do out[#out + 1] = pieces[k] end
        else
            out[#out + 1] = step
        end
    end
    return out
end

-- Feedback: a route as one line of text, which the dev replay reads back.

-- The steps as kind[:id]>map/seconds; a walk split by zone is one walk.
function Route.StepsCode(steps)
    local out = {}
    for i = 1, #steps do
        local s = steps[i]
        local a = s.arrive
        local sec = s.sec or 0
        sec = (sec == sec and sec < mhuge and sec > -mhuge) and mfloor(sec + 0.5) or -1
        local prev = out[#out]
        if s.kind == "travel" and prev and prev.kind == "travel" then
            prev.sec, prev.m = prev.sec + sec, a and a.m or prev.m
        else
            local id
            if s.kind == "taxi" then id = sformat("%s-%s", tostring(s.nodeID), tostring(s.toID))
            elseif s.kind == "teleport" then id = s.itemID and ("i" .. s.itemID) or tostring(s.spellID)
            elseif s.route then id = s.route .. "." .. (s.stop or 0) end
            out[#out + 1] = { kind = s.kind, id = id, m = a and a.m, sec = sec }
        end
    end
    for i = 1, #out do
        local o = out[i]
        out[i] = sformat("%s%s>%s/%d", o.kind, o.id and (":" .. o.id) or "", tostring(o.m or "?"), o.sec)
    end
    return tconcat(out, ",")
end

-- Sorted ids as 2-6.12 runs.
local function Runs(ids)
    tsort(ids)
    local out, i = {}, 1
    while i <= #ids do
        local j = i
        while ids[j + 1] == ids[j] + 1 do j = j + 1 end
        out[#out + 1] = j > i and (ids[i] .. "-" .. ids[j]) or tostring(ids[i])
        i = j + 1
    end
    return tconcat(out, ".")
end

-- The report line: who planned the route, from where to where, with what,
-- and how it went. extra: { version, avoid, hearth }.
function Route.ReportCode(route, extra)
    local data = ns.GPSData
    local r = route and route.report or {}
    local from, dest = r.from or (route and route.from), route and route.dest
    if not (data and from and dest and dest.mapID) then return nil end
    extra = extra or {}
    local parts = { "efgps1" }
    local function Add(k, v)
        if v ~= nil and v ~= "" then parts[#parts + 1] = k .. "=" .. tostring(v) end
    end
    Add("v", extra.version)
    Add("g", data.classic and "forever" or "retail")
    Add("b", GetBuildInfo and select(2, GetBuildInfo()))
    Add("f", UnitFactionGroup and UnitFactionGroup("player"))
    Add("r", UnitRace and select(2, UnitRace("player")))
    Add("c", UnitClass and select(2, UnitClass("player")))
    Add("lvl", UnitLevel and UnitLevel("player"))
    if r.fly ~= nil then Add("fly", r.fly and 1 or 0) end
    Add("spd", sformat("%.1f", Route.GroundSpeed(data)))
    if from.m and from.x then Add("from", sformat("%d:%.4f:%.4f", from.m, from.x, from.y)) end
    Add("at", sformat("%d:%.1f:%.1f", from.ci, from.wx, from.wy))
    Add("to", sformat("%d:%.4f:%.4f", dest.mapID, dest.x or 0.5, dest.y or 0.5))
    local avoided = {}
    for k, on in pairs(extra.avoid or {}) do
        if on then avoided[#avoided + 1] = k end
    end
    tsort(avoided)
    Add("av", tconcat(avoided, "."))
    local h = extra.hearth
    if h and h.m then Add("hs", sformat("%d:%.4f:%.4f", h.m, h.x or 0.5, h.y or 0.5)) end
    local ids = {}
    for id in pairs(KnownSet(data) or {}) do
        if type(id) == "number" then ids[#ids + 1] = id end
    end
    Add("kn", Runs(ids))
    local own = {}
    for i = 1, #(data.abilities or {}) do
        local a = data.abilities[i]
        if (a.item or a.id) and Owns(a) then own[#own + 1] = a.item and ("i" .. a.item) or tostring(a.id) end
    end
    Add("own", tconcat(own, "."))
    Add("eta", r.total and mfloor(r.total + 0.5))
    Add("took", route.tookSec)
    Add("re", r.re)
    Add("via", r.via)
    Add("st", r.steps or Route.StepsCode(route.steps or {}))
    Add("n", dest.name)   -- last: the name may hold spaces
    return tconcat(parts, " ")
end
