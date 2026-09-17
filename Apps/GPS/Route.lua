-- EasyFind GPS: the route engine.
--
-- A route is the cheapest path in seconds from where you stand to a point,
-- over: travel inside a continent in a straight line at your speed, flight
-- paths between adjacent flight nodes, portals, boats, zeppelins and trams
-- from their exact spots, and teleports you own, with their cooldowns.
-- Dijkstra over a small graph whose nodes are every place a mode change
-- can happen; the straight-line travel edges are generated on the fly, so
-- the data ships only the places, never the pairs.

local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns then return end

local Route = {}
ns.GPSRoute = Route

local msqrt, mmax, mhuge = math.sqrt, math.max, math.huge
local tinsert = table.insert

local MOUNT_UP = 2          -- seconds to get on a mount
local BOARD_TAXI = 4        -- seconds at the flight master
local ABILITY_WAIT_MAX = 600 -- a cooldown longer than this is not worth waiting for

-- ---------------------------------------------------------------------------
-- World coordinates
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- The graph
-- ---------------------------------------------------------------------------

-- ctx: { start = point, goal = point, faction = "Alliance"|"Horde", canFly = bool,
--        data = ns.GPSData, cooldown = function(ability) -> seconds remaining }
local function BuildGraph(ctx)
    local data = ctx.data
    local speeds = data.speeds or { run = 7, mount = 14, fly = 30, taxi = 32 }
    local travelSpeed = ctx.canFly and speeds.fly or speeds.mount
    local nodes = {}          -- array of { p = point, kind, ... }
    local byCi = {}           -- continent -> array of node indexes

    local function AddNode(p, kind, extra)
        local n = { p = p, kind = kind }
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

    -- Flight nodes and legs.
    local taxiIdx = {}
    -- Only flight points this character has discovered (ctx.known, from the
    -- client; nil when it cannot say, then every point counts).
    for id, n in pairs(data.nodes or {}) do
        if n.wx and n.ci and (not n.faction or n.faction == "Neutral" or n.faction == ctx.faction)
            and (not ctx.known or ctx.known[id]) then
            taxiIdx[id] = AddNode({ m = n.m, x = n.x, y = n.y, ci = n.ci, wx = n.wx, wy = n.wy }, "taxi", { id = id, name = n.n })
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
            legs[ia] = legs[ia] or {}
            legs[ib] = legs[ib] or {}
            tinsert(legs[ia], { to = ib, sec = sec })
            tinsert(legs[ib], { to = ia, sec = sec })
        end
    end

    -- Transport edges.
    local hops = {}           -- node index -> { { to = idx, sec, edge }, ... }
    for i = 1, #(data.edges or {}) do
        local e = data.edges[i]
        if (not e.faction or e.faction == ctx.faction) and ctx.meets(e.req) then
            local f, t = Resolve(e.from), Resolve(e.to)
            -- A scanned map marker exists only for a character who can use
            -- the transport (unlocked, right phase): ask the client.
            if f and t and e.poi and ctx.hasMarker and ctx.hasMarker(f.m, e.n) == false then
                f = nil
            end
            if f and t then
                local fi = AddNode(f, "edgeFrom", { edge = e })
                local ti = AddNode(t, "edgeTo", { edge = e })
                hops[fi] = hops[fi] or {}
                tinsert(hops[fi], { to = ti, sec = e.sec or 10, edge = e })
                if e.bidir then
                    hops[ti] = hops[ti] or {}
                    tinsert(hops[ti], { to = fi, sec = e.sec or 10, edge = e, reverse = true })
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
            -- A hearth lands where this character is bound: the landing
            -- learned from its last hearth, or the data's point when the
            -- bind is the same inn the data was recorded at.
            if ctx.hearth and ctx.hearth.point then
                dest = Resolve(ctx.hearth.point)
            elseif a.to and ctx.bindName and a.bind == ctx.bindName then
                dest = Resolve(a.to)
            end
        else
            dest = a.to and Resolve(a.to)
        end
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
                tinsert(teleports, { to = ti, sec = wait + cast + 8 + (a.guess and 20 or 0), ability = a })
            end
        end
    end

    return {
        nodes = nodes, byCi = byCi, start = startIdx, goal = goalIdx,
        legs = legs, hops = hops, teleports = teleports,
        travelSpeed = travelSpeed, data = data,
    }
end

local function Neighbors(g, i, out)
    local n = g.nodes[i]
    local k = 0
    -- Straight-line travel to everything on the same continent.
    local same = g.byCi[n.p.ci]
    if same then
        for j = 1, #same do
            local idx = same[j]
            if idx ~= i then
                local d = Dist(n.p, g.nodes[idx].p)
                k = k + 1
                -- Two points within a few yards are the same spot: free,
                -- no mounting (a portal's arrival that is the goal).
                out[k] = { to = idx, sec = d > 5 and (MOUNT_UP + d / g.travelSpeed) or 0, kind = "travel" }
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
            out[k] = { to = hops[j].to, sec = hops[j].sec, kind = hops[j].edge.kind, edge = hops[j].edge, reverse = hops[j].reverse }
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

local function Dijkstra(g)
    local n = #g.nodes
    local dist, prev, prevEdge, done = {}, {}, {}, {}
    for i = 1, n do dist[i] = mhuge end
    dist[g.start] = 0
    local scratch = {}
    for _ = 1, n do
        local best, bestD = nil, mhuge
        for i = 1, n do
            if not done[i] and dist[i] < bestD then best, bestD = i, dist[i] end
        end
        if not best or best == g.goal then break end
        done[best] = true
        local count = Neighbors(g, best, scratch)
        for j = 1, count do
            local e = scratch[j]
            local nd = bestD + e.sec
            if nd < dist[e.to] then
                dist[e.to] = nd
                prev[e.to] = best
                prevEdge[e.to] = e
            end
        end
    end
    if dist[g.goal] == mhuge then return nil end
    local path = {}
    local i = g.goal
    while i and i ~= g.start do
        tinsert(path, 1, { node = i, edge = prevEdge[i] })
        i = prev[i]
    end
    return path, dist[g.goal]
end

-- ---------------------------------------------------------------------------
-- Steps
-- ---------------------------------------------------------------------------

local KIND_KEY = {
    portal = "GPS_STEP_PORTAL_FMT", boat = "GPS_STEP_BOAT_FMT", zeppelin = "GPS_STEP_ZEPPELIN_FMT",
    tram = "GPS_STEP_TRAM_FMT", ferry = "GPS_STEP_BOAT_FMT",
    seam = "GPS_STEP_TRAVEL_FMT",
}

-- Where a crossing leads, as its own label says ("Portal to Shattrath",
-- "Boat to Booty Bay, Stranglethorn Vale"); the far map's name only for
-- a crossing ridden backwards or one without a label.
local function EdgeDestName(e, reverse)
    if not reverse and e.n then
        local dest = e.n:match("^[Pp]ortal to (.+)$") or e.n:match("^[Bb]oat to (.+)$")
            or e.n:match("^[Zz]eppelin to (.+)$") or e.n:match("^[Tt]ram to (.+)$") or e.n:match("^[Ss]hip to (.+)$")
        if dest then return dest end
    end
    local p = reverse and e.from or e.to
    return MapName(p and p.m)
end

-- Which floor a crossing's spot is on: "upper" or "lower" when the spot
-- was recorded with one (the den's two levels), else nil. The client
-- zeroes the player's height, so the floor is recorded by hand.
local function FloorHint(g, p)
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

-- The approach to a portal, dock or flight master folds into taking it
-- when it is this short, whatever zone it starts in.
local FOLD_SECONDS = 60

-- Whether map m is goal, or lies under it (Crystalsong Forest under
-- Northrend).
-- A requirement table on an edge or an ability, as the data writes it:
-- quest = id, anyQuest = { ids }, notQuest = id, minLevel, maxLevel,
-- covenant = id, reputation = { id, standing }, art = { map, artID }.
-- Anything the client cannot answer counts as met.
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
    -- A seam is free passage between continent ids with no loading screen
    -- (Khaz Algar's Coreway): the travel to it, the crossing and the travel
    -- after it are one travel step to wherever that leads.
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
    local carry = 0   -- travel seconds folded into the crossing that follows
    -- Reaching a portal, dock or flight master is part of taking it when
    -- it is in this zone or a minute away. A long haul from another zone
    -- is its own step, so the route says where the portal is before it
    -- says to take it.
    local function leadsInto(i, el, nxt)
        if not nxt or el.edge.kind ~= "travel" then return false end
        local node = g.nodes[el.node]
        local into
        if node.kind == "taxi" then into = nxt.edge.kind == "taxi"
        else into = node.edge ~= nil and nxt.edge.edge == node.edge end
        if not into then return false end
        if el.edge.sec <= FOLD_SECONDS then return true end
        local from = g.nodes[i > 1 and path[i - 1].node or g.start]
        return from ~= nil and from.p ~= nil and node.p ~= nil and from.p.m == node.p.m
    end
    while i <= #path do
        local el = path[i]
        local e = el.edge
        local node = g.nodes[el.node]
        if e.kind == "travel" and e.sec == 0 and #steps > 0 then
            -- Already there: the previous step ends on this spot.
            i = i + 1
        elseif leadsInto(i, el, path[i + 1]) then
            carry = carry + e.sec
            i = i + 1
        elseif e.kind == "travel" then
            local name
            if node.kind == "taxi" then name = node.name
            elseif node.kind == "edgeFrom" then
                -- A haul to a portal in another zone names the zone; the
                -- portal step that follows says what to take there.
                local from = g.nodes[i > 1 and path[i - 1].node or g.start]
                if from and from.p and node.p and from.p.m ~= node.p.m then name = MapName(node.p.m)
                else name = node.edge.n end
            elseif node.kind == "goal" then name = goalName
            else name = MapName(node.p.m) end
            -- A zone is reached on entering it: when the step before this
            -- one already lands inside the destination's map (a portal to
            -- Dalaran for a route to Northrend), there is no last leg at
            -- all; that crossing ends the route.
            local skip = false
            if node.kind == "goal" and g.zoneGoal and #steps > 0 then
                local from = g.nodes[i > 1 and path[i - 1].node or g.start]
                if from and from.p and WithinMap(from.p.m, node.p.m) then skip = true end
            end
            if not skip then
                tinsert(steps, { kind = "travel", text = (L["GPS_STEP_TRAVEL_FMT"]):format(name or "?"),
                                 mapID = node.p.m, x = node.p.x, y = node.p.y, go = node.p, arrive = node.p, sec = e.sec })
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
            tinsert(steps, { kind = "taxi", text = (L["GPS_STEP_FLY_FMT"]):format(fromName, last.name or "?"),
                             mapID = fromNode and fromNode.p.m, x = fromNode and fromNode.p.x, y = fromNode and fromNode.p.y,
                             go = fromNode and fromNode.p, arrive = last.p, sec = sec + carry, edgeSec = sec,
                             reach = fromNode and fromNode.name })
            carry = 0
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
            tinsert(steps, { kind = e.kind, text = WithFloor((L[key]):format(EdgeDestName(e.edge, e.reverse)), floor),
                             mapID = from.p.m, x = from.p.x, y = from.p.y, go = from.p, arrive = node.p, sec = e.sec + carry, edgeSec = e.sec,
                             reach = e.edge.n,
                             floor = floor })
            carry = 0
            i = i + 1
        end
    end
    return steps
end

-- ---------------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------------

-- Build a route from the player's position to dest { name, mapID, x, y }.
-- Returns steps (array) and total seconds, or nil when no data covers it.
-- ---------------------------------------------------------------------------
-- What this character can use, from the client
-- ---------------------------------------------------------------------------

local knownCache          -- { at = GetTime(), set = { nodeID = true } }
local markerCache = {}    -- mapID -> { at = GetTime(), names = { name = true } }
local CACHE_SECONDS = 120

-- Flight points discovered by this character: the client lists a map's
-- points with an undiscovered flag, and leaves out points the character
-- cannot see at all (not unlocked, wrong phase). Nil when the client
-- cannot say, so every point counts.
local function KnownFlightNodes(data)
    if not (C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap) then return nil end
    local now = GetTime and GetTime() or 0
    if knownCache and now - knownCache.at < CACHE_SECONDS then return knownCache.set end
    local maps, set, seen = {}, {}, 0
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
                    if not info.isUndiscovered then set[info.nodeID] = true end
                end
            end
        end
    end
    if seen == 0 then return nil end
    knownCache = { at = now, set = set }
    return set
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
    -- No markers at all for the map from here is no verdict: the client
    -- lists a distant map's markers only sometimes. A verdict of "absent"
    -- needs the map to have shown its markers and not this one, matched
    -- loosely (the label may carry a zone qualifier the marker lacks).
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

if CreateFrame then
    local f = CreateFrame("Frame")
    f:RegisterEvent("TAXI_NODE_STATUS_CHANGED")
    f:SetScript("OnEvent", function() knownCache = nil end)
end

-- Seconds to cover this many yards from a standstill, priced as the
-- engine prices travel: on a mount, or flying where this character can;
-- at taxi speed when opts.taxi (the player is on a flight).
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
    return MOUNT_UP + yards / ((canFly and speeds.fly) or speeds.mount or 14)
end

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
    local ctx = {
        start = start, goal = goal, data = data,
        faction = opts.faction or (UnitFactionGroup and UnitFactionGroup("player")) or "Neutral",
        class = opts.class or (UnitClass and select(2, UnitClass("player"))) or nil,
        race = opts.race or (UnitRace and select(2, UnitRace("player"))) or nil,
        meets = opts.meets or Meets,
        canFly = opts.canFly,
        hearth = opts.hearth,
        bindName = opts.bindName or (GetBindLocation and GetBindLocation()) or nil,
        known = (opts.known ~= nil) and opts.known or KnownFlightNodes(data),
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
                -- Owned, and usable by this character: the engineering
                -- rippers and wormholes sit in every toy box but only
                -- an engineer can pull the lever.
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
    local g = BuildGraph(ctx)
    g.zoneGoal = dest.zone and true or nil
    local path = Dijkstra(g)
    if not path then return nil end
    local steps = Steps(g, path, dest.name)
    local total = 0
    for i = 1, #steps do total = total + (steps[i].sec or 0) end
    return steps, total
end
