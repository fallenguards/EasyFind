-- Route engine: cheapest path in seconds over walks, flights, crossings and teleports.
-- Walk edges are made on the fly; the data ships places, never pairs.

local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns then return end

local Route = {}
ns.GPSRoute = Route

local msqrt, mmax, mmin, mhuge, mfloor = math.sqrt, math.max, math.min, math.huge, math.floor
local tinsert, tsort = table.insert, table.sort

local MOUNT_UP = 2          -- seconds to get on a mount
local BOARD_TAXI = 4        -- seconds at the flight master
local ABILITY_WAIT_MAX = 600 -- a cooldown longer than this is not worth waiting for
local TELEPORT_MIN_YARDS = 1000 -- a teleport landing closer than this to the start is no trip
local HOSTILE_SECONDS = 1800 -- the other faction's boat or zeppelin: a last resort, never banned
local WALK_DETOUR = 1.2     -- roads wind where nobody flies: ground yards per straight yard
local PICKUP_YARDS = 150    -- an undiscovered flight master this far off a ride is on the way
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
-- known and listed { nodeID = true } (nil: every node learned / exists)
local function BuildGraph(ctx)
    local data = ctx.data
    local speeds = data.speeds or { run = 7, mount = 14, fly = 30, taxi = 32 }
    local travelSpeed = ctx.canFly and speeds.fly or (ctx.groundSpeed or speeds.mount or 14)
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
    for i = 1, #(data.legs or {}) do
        local a, b, yd, flown = data.legs[i][1], data.legs[i][2], data.legs[i][3], data.legs[i][4]
        local ia, ib = taxiIdx[a], taxiIdx[b]
        if ia and ib then
            -- Measured seconds when this leg was flown; else the continent's
            -- taxi speed; else the global one.
            local ci = nodes[ia].p.ci
            local sec = flown or ((yd or 0) / (taxiByCi[ci] or speeds.taxi or 32))
            if not nodes[ib].unknown then
                legs[ia] = legs[ia] or {}
                tinsert(legs[ia], { to = ib, sec = sec })
            end
            if not nodes[ia].unknown then
                legs[ib] = legs[ib] or {}
                tinsert(legs[ib], { to = ia, sec = sec })
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
                hops[fi] = hops[fi] or {}
                tinsert(hops[fi], { to = ti, sec = sec, edge = e, hostile = hostile or nil })
                if e.bidir then
                    hops[ti] = hops[ti] or {}
                    tinsert(hops[ti], { to = fi, sec = sec, edge = e, reverse = true, hostile = hostile or nil })
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
                tinsert(teleports, { to = ti, sec = wait + cast + 8 + ((a.guess or a.approx) and 20 or 0), ability = a })
            end
        end
    end

    local mountUp = (not ctx.canFly and travelSpeed <= (speeds.run or 7) + 0.5) and 0 or MOUNT_UP
    return {
        nodes = nodes, byCi = byCi, start = startIdx, goal = goalIdx,
        legs = legs, hops = hops, teleports = teleports, taxiIdx = taxiIdx,
        travelSpeed = travelSpeed, mountUp = mountUp,
        detour = (not ctx.canFly and data.classic) and WALK_DETOUR or 1,
        roads = data.roads and not ctx.canFly or nil,
        walkSec = {}, walkWind = {},
        data = data,
    }
end

-- Two points within a few yards are the same spot: free, no mounting.
local function TravelCost(g, d, detour)
    if d <= 5 then return 0 end
    return g.mountUp + d * (detour or g.detour) / g.travelSpeed
end

local WALK_KEY = 65536

-- A walk's seconds by its road, and its wind (road yards per straight yard).
local function PriceWalk(g, i, j)
    local key = i * WALK_KEY + j
    local sec = g.walkSec[key]
    if sec then return sec, g.walkWind[key] end
    local a, b = g.nodes[i].p, g.nodes[j].p
    local straight = Dist(a, b)
    local road = straight > 5 and Route.RoadPath(g.data, a.ci, a.wx, a.wy, b.wx, b.wy)
    local wind = road and road.len / straight or nil
    sec = road and g.mountUp + road.len / g.travelSpeed or TravelCost(g, straight)
    g.walkSec[key], g.walkWind[key] = sec, wind
    return sec, wind
end

-- noWalk: arrived on foot, so no walk on from here.
local function Neighbors(g, i, out, noWalk)
    local n = g.nodes[i]
    local k = 0
    -- Travel to everything on the same continent and landmass; a walk not
    -- yet priced by its road costs its straight line, its least.
    local same = not noWalk and g.byCi[n.p.ci]
    if same then
        local walkSec, bound = g.walkSec, g.roads and 1
        for j = 1, #same do
            local idx = same[j]
            if idx ~= i and g.nodes[idx].land == n.land then
                k = k + 1
                local key = i * WALK_KEY + idx
                local sec = walkSec[key]
                out[k] = { to = idx, sec = sec or TravelCost(g, Dist(n.p, g.nodes[idx].p), bound), kind = "travel",
                           wind = sec and g.walkWind[key] or nil }
            end
        end
    end
    local legs = g.legs[i]
    if legs then
        for j = 1, #legs do
            k = k + 1
            out[k] = { to = legs[j].to, sec = BOARD_TAXI + legs[j].sec, kind = "taxi" }
        end
    end
    local hops = g.hops[i]
    if hops then
        for j = 1, #hops do
            k = k + 1
            out[k] = { to = hops[j].to, sec = hops[j].sec, kind = hops[j].edge.kind, edge = hops[j].edge, reverse = hops[j].reverse,
                       hostile = hops[j].hostile }
        end
    end
    if i == g.start then
        for j = 1, #g.teleports do
            k = k + 1
            out[k] = { to = g.teleports[j].to, sec = g.teleports[j].sec, kind = "teleport", ability = g.teleports[j].ability }
        end
    end
    return k
end

-- State s is node s reached any way but on foot, s + n node s reached on
-- foot: no walk follows a walk, so stops never chain across a mountain.
local function Dijkstra(g)
    local n = #g.nodes
    local dist, prev, prevEdge, done = {}, {}, {}, {}
    for s = 1, 2 * n do dist[s] = mhuge end
    dist[g.start] = 0
    local scratch = {}
    local reached
    while true do
        local best, bestD = nil, mhuge
        for s = 1, 2 * n do
            if not done[s] and dist[s] < bestD then best, bestD = s, dist[s] end
        end
        if not best then break end
        local onFoot = best > n
        local i = onFoot and best - n or best
        if i == g.goal then
            reached = best
            break
        end
        done[best] = true
        local count = Neighbors(g, i, scratch, onFoot)
        for j = 1, count do
            local e = scratch[j]
            local to = e.kind == "travel" and e.to + n or e.to
            local nd = bestD + e.sec
            if nd < dist[to] then
                dist[to], prev[to], prevEdge[to] = nd, best, e
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

local SOLVE_ROUNDS = 8

-- The shortest path with its walks priced by road: only walks a best path
-- takes are looked up, then the path is found again until it holds.
local function Solve(g)
    for _ = 1, SOLVE_ROUNDS do
        local path, cost = Dijkstra(g)
        if not (path and g.roads) then return path, cost end
        local fresh = false
        for i = 1, #path do
            local from = i > 1 and path[i - 1].node or g.start
            if path[i].edge.kind == "travel" and not g.walkSec[from * WALK_KEY + path[i].node] then
                PriceWalk(g, from, path[i].node)
                fresh = true
            end
        end
        if not fresh then return path, cost end
    end
    return Dijkstra(g)
end

-- Path seconds, each walk priced by its road where one leads there.
local function RoadSeconds(g, path)
    local total = 0
    for i = 1, #path do
        local e = path[i].edge
        if g.roads and e.kind == "travel" then
            e.sec, e.wind = PriceWalk(g, i > 1 and path[i - 1].node or g.start, path[i].node)
        end
        total = total + e.sec
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
        if e.kind == "travel" and e.sec == 0 and #steps > 0 then
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
            -- A zone goal is reached on entering it: a step that already lands
            -- inside the destination's map ends the route.
            local skip = false
            if node.kind == "goal" and g.zoneGoal and #steps > 0 then
                local from = g.nodes[i > 1 and path[i - 1].node or g.start]
                if from and from.p and WithinMap(from.p.m, node.p.m) then skip = true end
            end
            if not skip then
                tinsert(steps, { kind = "travel", text = (L["GPS_STEP_TRAVEL_FMT"]):format(name or "?"),
                                 mapID = node.p.m, x = node.p.x, y = node.p.y, go = node.p, arrive = node.p, sec = e.sec,
                                 wind = e.wind })
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
            local wait = e.edge.wait
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
        local c = cands[i]
        known[c.id] = true
        local g2 = BuildGraph(trial)
        g2.zoneGoal = g.zoneGoal
        local path2, t2 = Dijkstra(g2)
        known[c.id] = nil
        if path2 and total - t2 >= SUGGEST_MIN_SECONDS then
            trips[#trips + 1] = { c = c, g = g2, most = total - t2 }
        end
    end
    tsort(trips, MostSavedFirst)
    -- Then by road, until no trip left could beat the best found.
    local best
    for i = 1, #trips do
        local trip = trips[i]
        if best and trip.most <= best.save then break end
        local path2 = Solve(trip.g)
        local t2 = path2 and RoadSeconds(trip.g, path2) or mhuge
        local save = total - t2
        if save >= SUGGEST_MIN_SECONDS and save >= total / 6 and (not best or save > best.save) then
            best = { id = trip.c.id, name = trip.c.n.name, p = trip.c.n.p, save = save, total = t2 }
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
-- This character's mounted ground speed as last seen (the GPS surface
-- fills it); nil until seen.
Route.seenGroundSpeed = nil

function Route.ForgetKnown() knownCache = nil end

if CreateFrame then
    local f = CreateFrame("Frame")
    f:RegisterEvent("TAXI_NODE_STATUS_CHANGED")
    f:SetScript("OnEvent", function() knownCache = nil end)
end

-- This character's pace where it cannot fly: its mounted speed as last
-- seen, else on the 1.x game a mount from level 40 and a run before it.
function Route.GroundSpeed(data)
    local speeds = data and data.speeds or {}
    if Route.seenGroundSpeed and Route.seenGroundSpeed > 0 then return Route.seenGroundSpeed end
    if data and data.classic then
        local lvl = UnitLevel and UnitLevel("player") or 0
        return lvl >= 40 and (speeds.mount or 11.2) or (speeds.run or 7)
    end
    return speeds.mount or 14
end

-- Seconds for this many yards from a standstill, as the engine prices travel.
-- opts.taxi: on a flight. opts.wind: a walk's road yards per straight yard.
function Route:TravelSeconds(yards, opts)
    local data = (opts and opts.data) or ns.GPSData
    local speeds = data and data.speeds or { run = 7, mount = 14, fly = 30, taxi = 32 }
    if not yards or yards <= 5 then return 0 end
    if opts and opts.taxi then return yards / (speeds.taxi or 32) end
    local canFly = opts and opts.canFly
    if canFly == nil then
        local ok, fly = pcall(IsFlyableArea)
        canFly = ok and fly and true or false
    end
    if canFly then return MOUNT_UP + yards / (speeds.fly or 30) end
    local speed = (opts and opts.groundSpeed) or Route.GroundSpeed(data)
    local mountUp = speed <= (speeds.run or 7) + 0.5 and 0 or MOUNT_UP
    return mountUp + yards * ((opts and opts.wind) or ((data and data.classic) and WALK_DETOUR or 1)) / speed
end

-- Public

local LEARN_SECONDS = 8   -- talking to a flight master to learn its path

local function Copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

-- The trip with a stop to learn the flight master via = { id, name, p }:
-- the way there, a step to learn it, then on with its flight path known.
local function ViaStop(route, dest, opts, start, known, listed)
    local L = ns.L
    local via = opts.via
    local here = Resolve(via.p)
    if not here then return nil end
    local o = Copy(opts)
    o.via, o.advise, o.start, o.known, o.listed = nil, false, start, known or false, listed
    local s1, t1 = route:Build({ name = via.name, mapID = here.m, x = here.x, y = here.y }, o)
    if not s1 then return nil end
    local learned = {}
    for id in pairs(known or {}) do learned[id] = true end
    learned[via.id] = true
    o.start, o.known = here, known and learned or false
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

-- Route from the player to dest { name, mapID, x, y }: steps, total seconds,
-- advice { pickups, learn = { id, name, p, save, total } }; nil without data.
function Route:Build(dest, opts)
    opts = opts or {}
    local data = opts.data or ns.GPSData
    if not data then return nil end
    local goal = Resolve({ m = dest.mapID, x = dest.x, y = dest.y })
    if not goal then return nil end
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
        known, listed, names = KnownFlightNodes(data)
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
    end
    if opts.via then return ViaStop(self, dest, opts, start, known, listed) end
    local ctx = {
        start = start, goal = goal, data = data,
        faction = opts.faction or (UnitFactionGroup and UnitFactionGroup("player")) or "Neutral",
        class = opts.class or (UnitClass and select(2, UnitClass("player"))) or nil,
        race = opts.race or (UnitRace and select(2, UnitRace("player"))) or nil,
        meets = opts.meets or Meets,
        canFly = opts.canFly,
        groundSpeed = opts.groundSpeed,
        hearth = opts.hearth,
        bindName = opts.bindName or (GetBindLocation and GetBindLocation()) or nil,
        known = known,
        listed = listed,
        nodeName = names and function(id) return names[id] end or nil,
        hasMarker = opts.hasMarker or MarkerPresent,
        cooldown = opts.cooldown or function(a)
            if a.item and C_Item and C_Item.GetItemCooldown then
                local ok, s, d = pcall(C_Item.GetItemCooldown, a.item)
                if ok and d and d > 5 then return mmax(0, s + d - GetTime()) end
            elseif a.id and C_Spell and C_Spell.GetSpellCooldown then
                local ok, cd = pcall(C_Spell.GetSpellCooldown, a.id)
                if ok and cd and cd.duration and cd.duration > 5 then return mmax(0, cd.startTime + cd.duration - GetTime()) end
            end
            return 0
        end,
        owns = opts.owns or function(a)
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
        end,
    }
    if ctx.canFly == nil then
        local ok, fly = pcall(IsFlyableArea)
        ctx.canFly = ok and fly and true or false
    end
    if not ctx.groundSpeed and not ctx.canFly then ctx.groundSpeed = Route.GroundSpeed(data) end
    local g = BuildGraph(ctx)
    g.zoneGoal = dest.zone and true or nil
    local path = Solve(g)
    if not path then return nil end
    local cost = RoadSeconds(g, path)
    local steps = Steps(g, path, dest.name)
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
        priced.advise, priced.start, priced.known, priced.listed = false, start, known or false, listed
        local function Price(item)
            priced.via = item
            local _, t = self:Build(dest, priced)
            item.viaTotal = t
            item.extra = t and (t - total) or nil
        end
        for i = 1, #advice.pickups do Price(advice.pickups[i]) end
        local learn = advice.learn
        if learn then Price(learn) end
        -- A stop that costs nothing is simply taken.
        if learn and learn.extra and learn.extra <= 0 then
            priced.via = learn
            local viaSteps, viaTotal = self:Build(dest, priced)
            if viaSteps then
                steps, total, advice.learn = viaSteps, viaTotal, nil
                local keep = {}
                for i = 1, #advice.pickups do
                    if advice.pickups[i].id ~= learn.id then keep[#keep + 1] = advice.pickups[i] end
                end
                advice.pickups = keep
            end
        end
        if #advice.pickups == 0 and not advice.learn then advice = nil end
    end
    return steps, total, advice
end

-- Roads: the walking network (data.roads)

local ROAD_CELL = 300     -- yards per lookup cell
local ROAD_HOP = 1000     -- off the road between two pieces of road, at most
local ROAD_REACH = 1000   -- the start and the end join a road this close
local OFF_ROAD = 4        -- an off-road yard weighs this many road yards
local END_TRIM = 50       -- road this close to either end is left for the straight line
local roadNets = {}

local function RoadNet(data, ci)
    local net = roadNets[ci]
    if net ~= nil then return net or nil end
    local g = data and data.roads and data.roads[ci]
    if not g then
        roadNets[ci] = false
        return nil
    end
    local xy, edges = g.nodes, g.edges
    local n = #xy / 2
    local adj, cells = {}, {}
    for i = 1, n do adj[i] = {} end
    for e = 1, #edges / 3 do
        local a, b, len = edges[3 * e - 2], edges[3 * e - 1], edges[3 * e]
        local la, lb = adj[a], adj[b]
        local ka, kb = #la, #lb
        la[ka + 1], la[ka + 2], la[ka + 3] = b, len, e
        lb[kb + 1], lb[kb + 2], lb[kb + 3] = a, len, -e
    end
    for i = 1, n do
        local key = (mfloor(xy[2 * i - 1] / ROAD_CELL) + 500) * 1000 + mfloor(xy[2 * i] / ROAD_CELL) + 500
        local c = cells[key]
        if not c then
            c = {}
            cells[key] = c
        end
        c[#c + 1] = i
    end
    net = { xy = xy, n = n, adj = adj, cells = cells, shapes = g.shapes or {} }
    roadNets[ci] = net
    return net
end

-- Road nodes within r yards of (x, y): each id and its distance, in pairs.
local function NodesNear(net, x, y, r, out)
    local k = 0
    local cx, cy, span = mfloor(x / ROAD_CELL), mfloor(y / ROAD_CELL), math.ceil(r / ROAD_CELL)
    local xy = net.xy
    for i = cx - span, cx + span do
        for j = cy - span, cy + span do
            local c = net.cells[(i + 500) * 1000 + j + 500]
            for m = 1, c and #c or 0 do
                local id = c[m]
                local dx, dy = xy[2 * id - 1] - x, xy[2 * id] - y
                local d = msqrt(dx * dx + dy * dy)
                if d <= r then
                    out[k + 1], out[k + 2] = id, d
                    k = k + 2
                end
            end
        end
    end
    return k
end

-- Way over the roads: { pts (world yards), node[vertex], off[vertex] (leg leaves
-- the road), cum[vertex] (yards so far), len, net }; nil when no road helps.
local function RoadSearch(net, sx, sy, tx, ty)
    local n, xy, adj = net.n, net.xy, net.adj
    local S, T = n + 1, n + 2
    local function Pos(u)
        if u == S then return sx, sy elseif u == T then return tx, ty end
        return xy[2 * u - 1], xy[2 * u]
    end
    local function H(u)
        local x, y = Pos(u)
        return msqrt((x - tx) ^ 2 + (y - ty) ^ 2)
    end
    local g, prev, via, done = { [S] = 0 }, {}, {}, {}
    local hk, hv, hn = {}, {}, 0
    local function Push(v, f)
        hn = hn + 1
        local i = hn
        while i > 1 do
            local p = mfloor(i / 2)
            if hk[p] <= f then break end
            hk[i], hv[i] = hk[p], hv[p]
            i = p
        end
        hk[i], hv[i] = f, v
    end
    local function Pop()
        local v, lastK, lastV = hv[1], hk[hn], hv[hn]
        hk[hn], hv[hn] = nil, nil
        hn = hn - 1
        local i = 1
        while true do
            local c = i * 2
            if c > hn then break end
            if c < hn and hk[c + 1] < hk[c] then c = c + 1 end
            if hk[c] >= lastK then break end
            hk[i], hv[i] = hk[c], hv[c]
            i = c
        end
        if hn > 0 then hk[i], hv[i] = lastK, lastV end
        return v
    end
    local function Relax(u, v, cost, e)
        local ng = g[u] + cost
        if not done[v] and (g[v] == nil or ng < g[v]) then
            g[v], prev[v], via[v] = ng, u, e
            Push(v, ng + H(v))
        end
    end
    local near = {}
    Push(S, H(S))
    while hn > 0 do
        local u = Pop()
        if not done[u] then
            done[u] = true
            if u == T then break end
            local ux, uy = Pos(u)
            local dT = msqrt((ux - tx) ^ 2 + (uy - ty) ^ 2)
            if u == S then
                -- Straight there only when it is close: a long line crosses
                -- what cannot be walked.
                if dT <= ROAD_REACH then Relax(u, T, dT * OFF_ROAD, 0) end
                local k = NodesNear(net, ux, uy, ROAD_REACH, near)
                for m = 1, k, 2 do Relax(u, near[m], near[m + 1] * OFF_ROAD, 0) end
            else
                local a = adj[u]
                for m = 1, #a, 3 do Relax(u, a[m], a[m + 1], a[m + 2]) end
                local k = NodesNear(net, ux, uy, ROAD_HOP, near)
                for m = 1, k, 2 do
                    if near[m] ~= u then Relax(u, near[m], near[m + 1] * OFF_ROAD, 0) end
                end
                if dT <= ROAD_REACH then Relax(u, T, dT * OFF_ROAD, 0) end
            end
        end
    end
    if not done[T] or prev[T] == S then return nil end
    local chain = {}
    local v = T
    while v do
        chain[#chain + 1] = v
        v = prev[v]
    end
    local pts, node, off, cum = {}, {}, {}, {}
    local function Add(x, y)
        local k = #pts
        local d = 0
        if k > 0 then d = cum[k / 2] + msqrt((x - pts[k - 1]) ^ 2 + (y - pts[k]) ^ 2) end
        pts[k + 1], pts[k + 2] = x, y
        cum[k / 2 + 1] = d
        return k / 2 + 1
    end
    Add(sx, sy)
    for c = #chain - 1, 1, -1 do
        local w = chain[c]
        local e = via[w]
        local from = #pts / 2
        if e == 0 then
            off[from] = true
        else
            local shape = net.shapes[e < 0 and -e or e]
            if shape then
                local m = #shape / 2
                for s = 1, m do
                    local j = e > 0 and s or (m - s + 1)
                    Add(shape[2 * j - 1], shape[2 * j])
                end
            end
        end
        local wx, wy = Pos(w)
        local idx = Add(wx, wy)
        if w <= n then node[idx] = w end
    end
    -- Near either end the way cuts straight across, never round a bend
    -- or past the spot and back.
    local last = #pts / 2
    local function Near(k, x, y) return (pts[2 * k - 1] - x) ^ 2 + (pts[2 * k] - y) ^ 2 <= END_TRIM * END_TRIM end
    local a, b = 1, last
    for k = last - 1, 2, -1 do
        if Near(k, sx, sy) then a = k break end
    end
    for k = a + 1, last - 1 do
        if Near(k, tx, ty) then b = k break end
    end
    if a > 2 or b < last - 1 then
        local kept = { 1 }
        for k = mmax(a, 2), mmin(b, last - 1) do kept[#kept + 1] = k end
        kept[#kept + 1] = last
        local was, wasNode, wasOff = pts, node, off
        pts, node, off, cum = {}, {}, {}, {}
        for i = 1, #kept do
            local k, after = kept[i], kept[i + 1]
            local idx = Add(was[2 * k - 1], was[2 * k])
            node[idx] = wasNode[k]
            if after and (after ~= k + 1 or wasOff[k]) then off[idx] = true end
        end
    end
    return { pts = pts, node = node, off = off, cum = cum, len = cum[#pts / 2], net = net }
end

-- The last ways searched are kept: pricing a walk, splitting it by zone
-- and pricing each stop tried all ask for the same one.
local ROAD_PATHS_KEPT = 128
local roadPaths, roadPathCount = {}, 0

function Route.RoadPath(data, ci, sx, sy, tx, ty)
    local net = RoadNet(data, ci)
    if not net then return nil end
    local key = ci .. ":" .. mfloor(sx) .. ":" .. mfloor(sy) .. ":" .. mfloor(tx) .. ":" .. mfloor(ty)
    local path = roadPaths[key]
    if path == nil then
        if roadPathCount >= ROAD_PATHS_KEPT then roadPaths, roadPathCount = {}, 0 end
        path = RoadSearch(net, sx, sy, tx, ty) or false
        roadPaths[key], roadPathCount = path, roadPathCount + 1
    end
    return path or nil
end

-- Walks, zone by zone

local WALK_SAMPLE = 100    -- yards between zone readings along a walk
local WALK_MIN_RUN = 150   -- a zone crossed for less than this is no step

local function PointWorld(p)
    if not p then return nil end
    if p.wx and p.ci then return p.ci, p.wx, p.wy end
    return WorldPos(p.m, p.x, p.y)
end

-- One walked step as a step per zone its road way crosses, or nil when it
-- stays in one zone or no road leads there.
local function WalkPieces(step, from, data, env, first)
    local target = step.go or step.arrive
    local ci, fx, fy = PointWorld(from)
    local ci2, tx, ty = PointWorld(target)
    if not (ci and ci == ci2) then return nil end
    local path = Route.RoadPath(data, ci, fx, fy, tx, ty)
    if not path then return nil end
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
    -- A zone clipped for a few yards (a border the road runs along) is
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
    -- step, up to where the way meets its first road.
    local city = first and env.startCity
    if city and runs[1] and runs[1].map ~= city.map and #pts >= 4
       and cum[2] < (runs[2] and runs[2].at or path.len) then
        runs[1].at, runs[1].x, runs[1].y = cum[2], pts[3], pts[4]
        table.insert(runs, 1, { map = city.map, name = city.name or "?", at = 0, x = fx, y = fy })
    end
    -- A zone goal is reached on entering it: the stretch inside it is
    -- the end of the step before.
    local count = #runs
    local intoGoal = env.goalZone and count > 1 and runs[count].map == env.goalZone
    if intoGoal then count = count - 1 end
    if count < 2 and not intoGoal then return nil end
    local L = ns.L
    local out = {}
    for k = 1, count do
        local run, nxt = runs[k], runs[k + 1]
        local piece = {}
        for key, value in pairs(step) do piece[key] = value end
        local stop = (k < count or intoGoal) and nxt and nxt.at or path.len
        if step.sec then piece.sec = step.sec * (stop - run.at) / path.len end
        local ex, ey = tx, ty
        if (k < count or intoGoal) and nxt then ex, ey = nxt.x, nxt.y end
        local straight = msqrt((ex - run.x) ^ 2 + (ey - run.y) ^ 2)
        piece.wind = straight > 5 and mmax(1, (stop - run.at) / straight) or nil
        piece.walkZone = run.map
        if k < count then
            -- Up to the border: done on entering the next zone.
            local mx, my
            if env.mapPos then mx, my = env.mapPos(ci, nxt.x, nxt.y, run.map) end
            -- A border the zone's own map cannot place: the walk stays whole.
            if env.mapPos and not mx then return nil end
            local spot = { ci = ci, wx = nxt.x, wy = nxt.y, m = run.map, x = mx, y = my }
            piece.mapID, piece.x, piece.y, piece.go, piece.arrive = run.map, mx, my, spot, spot
            piece.enter = nxt.map
            if env.isCity and env.isCity(run.map) then
                piece.text = (L["GPS_STEP_EXIT_FMT"]):format(run.name)
            else
                piece.text = (L["GPS_STEP_WALK_THROUGH_FMT"]):format(run.name, nxt.name)
            end
        elseif intoGoal then
            piece.enter = nxt.map
            piece.text = (L["GPS_STEP_WALK_THROUGH_FMT"]):format(run.name, nxt.name)
        end
        out[k] = piece
    end
    return out
end

-- Each long walk as a step per zone crossed. env: zoneAt(ci, wx, wy) -> map, name;
-- mapPos(ci, wx, wy, mapID); isCity(mapID); startCity { map, name }; goalZone.
function Route.SplitWalks(steps, start, data, env)
    local out = {}
    for i = 1, #steps do
        local step = steps[i]
        local pieces
        if step.kind == "travel" then
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
