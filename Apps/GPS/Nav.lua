-- Walking on WoW Forever's baked walking grid (ns.GPSNavData, written by
-- dev/tools/navmesh/pack.py): 4 yd cells, each with its floors, linked
-- where one can really walk. A long walk is searched on the tiles'
-- entrances; only the tiles at its ends, and those a drawn path crosses,
-- are unpacked and searched cell by cell.
local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns then return end
local Utils = ns.Utils

local Nav = {}
ns.GPSNav = Nav

local sbyte, schar, mfloor, msqrt, mhuge, mabs = string.byte, string.char, math.floor, math.sqrt, math.huge, math.abs
local mmax, mmin = math.max, math.min
local tinsert, tremove, tsort, tconcat = table.insert, table.remove, table.sort, table.concat

local TILE = 1600 / 3
local ORIGIN = 32 * TILE
local TILES_KEPT = 12              -- unpacked tiles held at once
local SNAP_CELLS = 6               -- a point off the grid takes a floor this many cells away
local REACH_KEPT = 256             -- end points whose tile search is kept
local LANDMARKS_USED = 3           -- of the data's landmarks, the most telling for a walk
local WALKS_KEPT = 512             -- walk costs kept
-- Walking weights, the same in dev/tools/navmesh/grid.py: swimming at the
-- game's swim speed against running, and off the road a quarter more, so a
-- walk leaves a road only to save over a fifth.
local SWIM_WEIGHT = 7.0 / 4.72
local OFF_ROAD_WEIGHT = 1.25
-- Staying on roads (Nav.SetRoads): a road up to this many times longer than
-- the way off it is still the way; the data carries tile costs for it.
local OFF_ROAD_STRICT = 3.0
local DIAG = 1.41421356
local offRoad, roadsOnly = OFF_ROAD_WEIGHT, false
-- A tile to go around (Nav.SetDanger) costs this many times as much to
-- choose; the time a walk through it takes stays the same.
local DANGER_WEIGHT = 2
local dangerSet          -- { [continent] = { [tile] = true } }
-- The settings walks come out under, as one number: the danger set's
-- id and the roads switch. The same settings give the same epoch again,
-- so ways kept under it hold good once a trial under others is over.
local dangerIds = setmetatable({}, { __mode = "k" })
local dangerIdNext = 1
local function Epoch()
    local id = 0
    if dangerSet then
        id = dangerIds[dangerSet]
        if not id then
            id, dangerIdNext = dangerIdNext, dangerIdNext + 1
            dangerIds[dangerSet] = id
        end
    end
    return id * 2 + (roadsOnly and 1 or 0)
end
Nav.epoch = 0

-- Inside GPS's planner (yieldCo, the plan's coroutine, while it runs the
-- route engine; sliceEnd, this frame's budget) the searches give the frame
-- back once the budget is spent. Anywhere else they run straight through.
local corunning, coyield = coroutine.running, coroutine.yield
local function Pause()
    local co = Nav.yieldCo
    if co and Nav.sliceEnd and corunning() == co and debugprofilestop() > Nav.sliceEnd then coyield() end
end
Nav.Pause = Pause

-- Unpacking -----------------------------------------------------------------

-- data: the continent's table; raw set once its blobs were decoded from
-- base64 to deflated bytes (DecodeBlobs below).
local function Unpack(s, data)
    local E = C_EncodingUtil
    local method = Enum and Enum.CompressionMethod and Enum.CompressionMethod.Deflate or 0
    if data and data.raw then return E.DecompressString(s, method) end
    return E.DecompressString(E.DecodeBase64(s), method)
end

local function Reader(s)
    local pos = 1
    local function u()
        local v, mul = 0, 1
        while true do
            local b = sbyte(s, pos)
            pos = pos + 1
            if b < 128 then return v + b * mul end
            v = v + (b - 128) * mul
            mul = mul * 128
        end
    end
    local function i()
        local v = u()
        if v % 2 == 1 then return -(v + 1) / 2 end
        return v / 2
    end
    return u, i
end

local worlds = {}
Nav._worlds = worlds   -- dev tools

local function World(ci)
    local w = worlds[ci]
    if w then return w end
    local data = ns.GPSNavData and ns.GPSNavData[ci]
    if not data then return nil end
    w = { ci = ci, data = data, N = data.cells, cell = data.cell, tiles = {}, order = {}, costs = {},
          reach = {}, reachN = 0, walks = {}, walksN = 0, marks = {} }
    worlds[ci] = w
    return w
end

-- Tile key of a world point, and the tile's south-east corner.
local function TileOf(x, y)
    local tx, ty = mfloor((ORIGIN - y) / TILE), mfloor((ORIGIN - x) / TILE)
    return tx * 64 + ty, ORIGIN - ty * TILE - TILE, ORIGIN - tx * TILE - TILE
end
Nav.TileOf = TileOf

-- Bytes from..to of s appended to out from index at: read in runs, not one
-- call a byte.
local RUN = 4000
local function Bytes(s, from, to, out, at)
    local i = from
    while i <= to do
        local j = mmin(to, i + RUN - 1)
        local run = { sbyte(s, i, j) }
        for k = 1, j - i + 1 do out[at + k - 1] = run[k] end
        at = at + (j - i + 1)
        i = j + 1
    end
    return out
end

local BIT = { [0] = 1, 2, 4, 8, 16, 32, 64, 128 }

-- A decoded tile holds, per cell, its first floor's index (one past the
-- last cell closes the list) and, per floor, its cell and its data byte
-- with the cell's road bit above: bits 0-1 the flags (swimming, indoors),
-- 2-4 the west link, 5-7 the north link, 8 the road. Links, weights and
-- the east and south ways are read out of those as asked.
local function DecodeTile(w, key)
    local data = w.data
    local s = data.tiles[key]
    if not s then return nil end
    local raw = Unpack(s, data)
    local N = w.N
    local NN = N * N
    local cellFirst, fcell, b = {}, {}, {}
    local f, c, i = 0, 0, 1
    while c < NN do
        local j = mmin(NN, i + RUN - 1)
        local run = { sbyte(raw, i, j) }
        for k = 1, j - i + 1 do
            cellFirst[c] = f + 1
            for _ = 1, run[k] do
                f = f + 1
                fcell[f] = c
            end
            c = c + 1
        end
        i = j + 1
        Pause()
    end
    cellFirst[NN] = f + 1
    -- Road cells: a bit each after the floors, low bit first.
    local road = Bytes(raw, NN + f + 1, NN + f + mfloor((NN + 7) / 8), {}, 0)
    local g = 0
    i = NN + 1
    while g < f do
        local j = mmin(NN + f, i + RUN - 1)
        local run = { sbyte(raw, i, j) }
        for k = 1, j - i + 1 do
            g = g + 1
            local cg = fcell[g]
            local rb = road[mfloor(cg / 8)]
            b[g] = run[k] + ((rb and mfloor(rb / BIT[cg % 8]) % 2 == 1) and 256 or 0)
        end
        i = j + 1
        Pause()
    end
    local tx, ty = mfloor(key / 64), key % 64
    return { key = key, tx = tx, ty = ty, N = N, NN = NN, nf = f, cellFirst = cellFirst, fcell = fcell, b = b,
             sx = ORIGIN - ty * TILE - TILE, sy = ORIGIN - tx * TILE - TILE }
end

-- By a floor's byte: its west link, its north link, its swimming factor
-- and what a yard on it costs to choose; table reads, no arithmetic, in
-- the searches.
local WC, NC, SW, WT = {}, {}, {}, {}
for v = 0, 511 do
    WC[v], NC[v] = mfloor(v / 4) % 8, mfloor(v / 32) % 8
    SW[v] = v % 2 == 1 and SWIM_WEIGHT or 1
end
local function Reweigh()
    for v = 0, 511 do WT[v] = SW[v] * (v >= 256 and 1 or offRoad) end
end
Reweigh()

-- The floor west (north) of g inside its tile, or nil.
local function WestOf(t, g)
    local k = WC[t.b[g]]
    if k == 0 then return nil end
    local c, N = t.fcell[g], t.N
    if c % N == N - 1 then return nil end
    return t.cellFirst[c + 1] + k - 1
end
local function NorthOf(t, g)
    local k = NC[t.b[g]]
    if k == 0 then return nil end
    local c, N = t.fcell[g], t.N
    if c >= t.NN - N then return nil end
    return t.cellFirst[c + N] + k - 1
end

-- The floor east (south) of g inside its tile: the first in the cell
-- before (a row before) whose west (north) link is g's rank in its cell.
local function East(t, g)
    local c = t.fcell[g]
    if c % t.N == 0 then return nil end
    local cellFirst, b = t.cellFirst, t.b
    local rank = g - cellFirst[c] + 1
    for o = cellFirst[c - 1], cellFirst[c] - 1 do
        if WC[b[o]] == rank then return o end
    end
    return nil
end
local function South(t, g)
    local c, N = t.fcell[g], t.N
    if c < N then return nil end
    local cellFirst, b = t.cellFirst, t.b
    local rank = g - cellFirst[c] + 1
    for o = cellFirst[c - N], cellFirst[c - N + 1] - 1 do
        if NC[b[o]] == rank then return o end
    end
    return nil
end

local function Tile(w, key)
    local t = w.tiles[key]
    if t then
        t.at = GetTime()
        return t
    end
    t = DecodeTile(w, key)
    if not t then return nil end
    t.at = GetTime()
    w.tiles[key] = t
    local order = w.order
    order[#order + 1] = key
    if #order > TILES_KEPT then
        local old = tremove(order, 1)
        w.tiles[old] = nil
    end
    return t
end

-- World point of floor g's cell.
local function FloorXY(w, t, g)
    local c = t.fcell[g]
    local N, cell = w.N, w.cell
    return t.sx + (mfloor(c / N) + 0.5) * cell, t.sy + (c % N + 0.5) * cell
end

local function Rank(t, g) return g - t.cellFirst[t.fcell[g]] + 1 end

-- The floor one step from (t, g) in direction d (0 east, 1 north, 2 west,
-- 3 south), maybe in the next tile: tile, floor, or nil.
local function Step(w, t, g, d)
    local N = w.N
    local c = t.fcell[g]
    local r, col = mfloor(c / N), c % N
    if d == 2 then
        if col < N - 1 then local o = WestOf(t, g) return o and t, o end
        local k = WC[t.b[g]]
        if k == 0 then return nil end
        local u = Tile(w, t.key - 64)
        if not u then return nil end
        local cc = r * N
        if k > u.cellFirst[cc + 1] - u.cellFirst[cc] then return nil end
        return u, u.cellFirst[cc] + k - 1
    elseif d == 1 then
        if r < N - 1 then local o = NorthOf(t, g) return o and t, o end
        local k = NC[t.b[g]]
        if k == 0 then return nil end
        local u = Tile(w, t.key - 1)
        if not u then return nil end
        if k > u.cellFirst[col + 1] - u.cellFirst[col] then return nil end
        return u, u.cellFirst[col] + k - 1
    elseif d == 0 then
        if col > 0 then local o = East(t, g) return o and t, o end
        local u = Tile(w, t.key + 64)
        if not u then return nil end
        local cc = r * N + N - 1
        local rank = Rank(t, g)
        for o = u.cellFirst[cc], u.cellFirst[cc + 1] - 1 do
            if WC[u.b[o]] == rank then return u, o end
        end
    else
        if r > 0 then local o = South(t, g) return o and t, o end
        local u = Tile(w, t.key + 1)
        if not u then return nil end
        local cc = (N - 1) * N + col
        local rank = Rank(t, g)
        for o = u.cellFirst[cc], u.cellFirst[cc + 1] - 1 do
            if NC[u.b[o]] == rank then return u, o end
        end
    end
    return nil
end

-- How much more a yard in tile key costs to choose: DANGER_WEIGHT in a
-- tile to go around, else 1.
local function Danger(w, key)
    local set = dangerSet and dangerSet[w.ci]
    return set and set[key] and DANGER_WEIGHT or 1
end

-- Walks come out differently from now on: the ones kept are dropped, and
-- the tiles, which carry their floors' weights.
local function Reset()
    Nav.epoch = Epoch()
    for _, w in pairs(worlds) do
        w.walks, w.walksN, w.reach, w.reachN, w.costs = {}, 0, {}, 0, {}
        w.tiles, w.order, w.marks = {}, {}, {}
    end
end

-- The tiles walks go around, or nil for none.
function Nav.SetDanger(set)
    if set == dangerSet then return end
    dangerSet = set
    Reset()
end

-- Whether walks keep to roads.
function Nav.SetRoads(on)
    on = on and true or false
    if on == roadsOnly then return end
    roadsOnly = on
    offRoad = on and OFF_ROAD_STRICT or OFF_ROAD_WEIGHT
    Reweigh()
    Reset()
end

-- Whether continent ci's data can keep walks to roads.
function Nav.HasRoads(ci)
    local data = ns.GPSNavData and ns.GPSNavData[ci]
    return data ~= nil and data.roads ~= nil
end

-- The most a walk's cost (the yards it is chosen by) exceeds its time by,
-- as a factor: off the road every yard weighs this much more.
function Nav.CostOverTime() return offRoad end

-- A drawn way is pulled straight along what the player sees and walks;
-- the cells it was found through zigzag about this much longer (measured
-- over twelve trips on both continents).
local PULLED = 0.955

-- The floor under (x, y): indoors an indoor one, else one outdoors, else
-- the highest; off the grid the nearest within SNAP_CELLS (or snap).
local function Locate(w, x, y, indoors, snap)
    local key, sx, sy = TileOf(x, y)
    local t = Tile(w, key)
    if not t then return nil end
    local N, cell = w.N, w.cell
    local r0, c0 = mfloor((x - sx) / cell), mfloor((y - sy) / cell)
    for ring = 0, snap or SNAP_CELLS do
        local best, bestScore
        for r = r0 - ring, r0 + ring do
            for c = c0 - ring, c0 + ring do
                if (mabs(r - r0) == ring or mabs(c - c0) == ring) and r >= 0 and c >= 0 and r < N and c < N then
                    local cc = r * N + c
                    for g = t.cellFirst[cc], t.cellFirst[cc + 1] - 1 do
                        local inside = t.b[g] % 4 >= 2
                        local score = ((indoors and inside) or (not indoors and not inside)) and 100 or 0
                        score = score + (g - t.cellFirst[cc]) - ring * 1000
                        if not bestScore or score > bestScore then best, bestScore = g, score end
                    end
                end
            end
        end
        if best then return t, best end
    end
    return t, nil
end

-- Searching -------------------------------------------------------------------

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

-- Straight and diagonal neighbours of g inside its tile: diagonals only
-- where both ways round the corner are open.
local nbScratch, nbLen = {}, {}
local function TileNeighbours(t, g)
    local cellFirst, b = t.cellFirst, t.b
    local c, N, NN = t.fcell[g], t.N, t.NN
    local bg = b[g]
    local w0, n0
    local k = WC[bg]
    if k > 0 and c % N < N - 1 then w0 = cellFirst[c + 1] + k - 1 end
    k = NC[bg]
    if k > 0 and c < NN - N then n0 = cellFirst[c + N] + k - 1 end
    local n = 0
    if w0 then n = n + 1; nbScratch[n], nbLen[n] = w0, 1 end
    if n0 then n = n + 1; nbScratch[n], nbLen[n] = n0, 1 end
    -- East and south: every floor in the cell before (a row before) whose
    -- west (north) link is g's rank in its cell; the first of each for the
    -- diagonals.
    local rank = g - cellFirst[c] + 1
    local e0, s0
    if c % N > 0 then
        for o = cellFirst[c - 1], cellFirst[c] - 1 do
            if WC[b[o]] == rank then n = n + 1; nbScratch[n], nbLen[n] = o, 1; e0 = e0 or o end
        end
    end
    if c >= N then
        for o = cellFirst[c - N], cellFirst[c - N + 1] - 1 do
            if NC[b[o]] == rank then n = n + 1; nbScratch[n], nbLen[n] = o, 1; s0 = s0 or o end
        end
    end
    -- Diagonals, by the links' ranks: the corner cell's floor is the one
    -- both ways round reach, and the straight ways found above keep the
    -- edge checks already made.
    if n0 and w0 then
        local kd = WC[b[n0]]
        if kd > 0 and NC[b[w0]] == kd then n = n + 1; nbScratch[n], nbLen[n] = cellFirst[c + N + 1] + kd - 1, DIAG end
    end
    if n0 and e0 then
        local kd = NC[b[e0]]
        if kd > 0 then
            local x = cellFirst[c + N - 1] + kd - 1
            if WC[b[x]] == n0 - cellFirst[c + N] + 1 then n = n + 1; nbScratch[n], nbLen[n] = x, DIAG end
        end
    end
    if s0 and w0 then
        local kd = WC[b[s0]]
        if kd > 0 then
            local x = cellFirst[c - N + 1] + kd - 1
            if NC[b[x]] == w0 - cellFirst[c + 1] + 1 then n = n + 1; nbScratch[n], nbLen[n] = x, DIAG end
        end
    end
    if s0 and e0 then
        local rs, re = s0 - cellFirst[c - N] + 1, e0 - cellFirst[c - 1] + 1
        for x = cellFirst[c - 1 - N], cellFirst[c - N] - 1 do
            local bx = b[x]
            if WC[bx] == rs and NC[bx] == re then n = n + 1; nbScratch[n], nbLen[n] = x, DIAG break end
        end
    end
    return n
end

-- Inside one tile from floor g0 (or from each floor of a table, at its
-- starting cost): each floor's cost and the floor before. With a goal the
-- search stops there (A* on the straight line, on a heap); with want (a
-- set of floors, left of them) once all are reached, in buckets a cell
-- wide: no step costs less than a cell, so a bucket's floors are at their
-- final cost when it is opened, in any order.
-- Each floor's time too: yards walked, swimming slower, as its way was
-- chosen by cost (a seed's cost counts as time).
-- A search's tables are wiped and used again, not made anew, so a plan
-- leaves no garbage behind: one set inside the planner, one outside it,
-- as a search the planner left waiting keeps its own. keep: the cost
-- and time tables are fresh, the caller's to hold on to.
local function NewScratch() return { prev = {}, closed = {}, cost = {}, time = {}, buckets = {}, lists = {}, heap = NewHeap() } end
local scratchMain, scratchPlan = NewScratch(), NewScratch()
local function TileSearch(w, t, g0, goal, want, left, keep)
    local s = (Nav.yieldCo and corunning() == Nav.yieldCo) and scratchPlan or scratchMain
    local prev, closed = s.prev, s.closed
    wipe(prev)
    wipe(closed)
    local cost, time
    if keep then
        cost, time = {}, {}
    else
        cost, time = s.cost, s.time
        wipe(cost)
        wipe(time)
    end
    local cell = w.cell * Danger(w, t.key) / 2
    local half = w.cell / 2
    local fb = t.b
    local pops = 0
    if goal then
        local heap = s.heap
        wipe(heap.k)
        wipe(heap.v)
        heap.n = 0
        if type(g0) == "table" then
            for g, c in pairs(g0) do
                cost[g], time[g] = c, c
                heap:Push(c, g)
            end
        else
            cost[g0], time[g0] = 0, 0
            heap:Push(0, g0)
        end
        local gx, gy = FloorXY(w, t, goal)
        while true do
            -- At the loop's top: nbScratch is refilled after, so a search run
            -- while this one waits cannot spoil it.
            pops = pops + 1
            if pops % 256 == 0 then Pause() end
            local g = heap:Pop()
            if not g then break end
            if not closed[g] then
                closed[g] = true
                if g == goal then break end
                local base, bg, tbase = cost[g], fb[g], time[g]
                local sg, wg = SW[bg], WT[bg]
                local n = TileNeighbours(t, g)
                for k = 1, n do
                    local o = nbScratch[k]
                    if not closed[o] then
                        local bo = fb[o]
                        local so = SW[bo]
                        local nc = base + nbLen[k] * cell * (wg + WT[bo])
                        if not cost[o] or nc < cost[o] then
                            cost[o], prev[o] = nc, g
                            time[o] = tbase + nbLen[k] * half * (sg + so)
                            local ox, oy = FloorXY(w, t, o)
                            heap:Push(nc + msqrt((gx - ox) ^ 2 + (gy - oy) ^ 2), o)
                        end
                    end
                end
            end
        end
        return cost, prev, time
    end
    local width = w.cell
    local buckets, lists, lo, hi = s.buckets, s.lists, mhuge, 0
    -- Lists a search ended early left in the buckets go back to the pool.
    for bk, list in pairs(buckets) do
        wipe(list)
        lists[#lists + 1] = list
        buckets[bk] = nil
    end
    local function Put(g, c)
        local b = mfloor(c / width)
        local list = buckets[b]
        if not list then
            list = lists[#lists]
            if list then lists[#lists] = nil else list = {} end
            buckets[b] = list
        end
        list[#list + 1] = g
        if b < lo then lo = b end
        if b > hi then hi = b end
    end
    if type(g0) == "table" then
        for g, c in pairs(g0) do
            cost[g], time[g] = c, c
            Put(g, c)
        end
    else
        cost[g0], time[g0] = 0, 0
        Put(g0, 0)
    end
    local b = lo
    while b <= hi do
        local list = buckets[b]
        local i = 1
        while list and i <= #list do
            local g = list[i]
            i = i + 1
            pops = pops + 1
            if pops % 256 == 0 then Pause() end
            if not closed[g] then
                closed[g] = true
                if want and want[g] then
                    left = left - 1
                    if left == 0 then return cost, prev, time end
                end
                local base, bg, tbase = cost[g], fb[g], time[g]
                local sg, wg = SW[bg], WT[bg]
                local n = TileNeighbours(t, g)
                for k = 1, n do
                    local o = nbScratch[k]
                    if not closed[o] then
                        local bo = fb[o]
                        local so = SW[bo]
                        local nc = base + nbLen[k] * cell * (wg + WT[bo])
                        if not cost[o] or nc < cost[o] then
                            cost[o], prev[o] = nc, g
                            time[o] = tbase + nbLen[k] * half * (sg + so)
                            Put(o, nc)
                        end
                    end
                end
            end
        end
        if list then
            wipe(list)
            lists[#lists + 1] = list
            buckets[b] = nil
        end
        b = b + 1
    end
    return cost, prev, time
end

-- Entrances: per entrance two sides, side 1 of entrance e node 2e - 1,
-- side 2 node 2e; a side is one number, its tile key, cell and floor packed.
local function Entrances(w)
    if w.ents then return w.ents end
    local data = w.data
    local u = Reader(Unpack(data.ents, data))
    local n = u()
    local e = { n = n, v = {} }
    local v = e.v
    for k = 1, 2 * n do
        if k % 4096 == 0 then Pause() end
        local key, f, c = u(), u(), u()
        v[k] = key * 4294967296 + c * 131072 + f
    end
    w.ents = e
    return e
end
local function SideKey(v) return mfloor(v / 4294967296) end
local function SideFloor(v) return v % 131072 end
-- World point of a side's cell.
local function SideXY(w, v)
    local key, c = mfloor(v / 4294967296), mfloor(v / 131072) % 32768
    local tx, ty = mfloor(key / 64), key % 64
    local N, cell = w.N, w.cell
    return ORIGIN - ty * TILE - TILE + (mfloor(c / N) + 0.5) * cell, ORIGIN - tx * TILE - TILE + (c % N + 0.5) * cell
end

local function TileCosts(w, key)
    local tc = w.costs[key]
    if tc ~= nil then return tc or nil end
    local data = w.data
    local s = (roadsOnly and data.roads or data.costs)[key]
    if not s then w.costs[key] = false return nil end
    local u, i = Reader(Unpack(s, data))
    local n = u()
    local ents = Entrances(w)
    local side, at, last = {}, {}, 0
    for k = 1, n do
        last = last + i()
        -- The entrance's side in this tile (ids count from 0 in the data).
        local node = (SideKey(ents.v[2 * last + 1]) == key) and (2 * last + 1) or (2 * last + 2)
        side[k], at[node] = node, k
    end
    local sx, sy = {}, {}
    for k = 1, n do sx[k], sy[k] = SideXY(w, ents.v[side[k]]) end
    -- Each pair's cost by its index in the upper triangle: the straight
    -- line plus the way around, false where no way joins them; and that
    -- way's time, the cost less what leaving roads added, as 127ths of
    -- the way around. A table flagged one way (a drop in the tile, data
    -- not shipped yet) lists every ordered pair; the way from the lower
    -- side is taken.
    local oneway = u() == 1
    local cost, time = {}, {}
    local function Pair(a, b, p)
        local code = u()
        if code == 0 then
            if p then cost[p] = false end
        else
            local off = u()
            if p then
                local around = (code - 1) / 2
                local c = msqrt((sx[a] - sx[b]) ^ 2 + (sy[a] - sy[b]) ^ 2) + around
                cost[p], time[p] = c, c - off / 127 * around
            end
        end
    end
    if oneway then
        for a = 1, n do
            for b = 1, n do
                if a ~= b then Pair(a, b, a < b and ((a - 1) * n - (a - 1) * a / 2 - a + b) or nil) end
            end
        end
    else
        local p = 0
        for a = 1, n - 1 do
            for b = a + 1, n do
                p = p + 1
                Pair(a, b, p)
            end
        end
    end
    tc = { side = side, at = at, n = n, cost = cost, time = time }
    w.costs[key] = tc
    return tc
end

-- Costs and times from floor g of tile t to each entrance side in that
-- tile, out of a tile search's.
local function EntranceCosts(w, t, cost, time)
    local tc = TileCosts(w, t.key)
    local ents = Entrances(w)
    local out, outT = {}, {}
    for k = 1, tc and tc.n or 0 do
        local node = tc.side[k]
        local f = SideFloor(ents.v[node])
        local c = cost[f]
        if c then out[node], outT[node] = c, time[f] end
    end
    return out, outT
end

-- Kept per floor, as every walk from one spot asks the same.
local function ToEntrances(w, t, g)
    local rk = t.key * 131072 + g
    local kept = w.reach[rk]
    if kept then return kept[1], kept[2] end
    if w.reachN >= REACH_KEPT then w.reach, w.reachN = {}, 0 end
    local tc, ents = TileCosts(w, t.key), Entrances(w)
    local want, left = {}, 0
    for k = 1, tc and tc.n or 0 do
        local f = SideFloor(ents.v[tc.side[k]])
        if not want[f] then want[f], left = true, left + 1 end
    end
    local cost, _, time = TileSearch(w, t, g, nil, want, left)
    local out, outT = EntranceCosts(w, t, cost, time)
    w.reach[rk], w.reachN = { out, outT }, w.reachN + 1
    return out, outT
end

-- Costs and times to entrance sides as the data bakes them for fixed
-- spots (dev/tools/navmesh/bake_spots.lua): the sides in order, each a
-- step on from the last, with its cost and its time in sixteenths of a
-- yard.
local function Baked(u)
    local out, outT, node = {}, {}, 0
    for _ = 1, u() do
        node = node + u()
        out[node] = u() / 16
        outT[node] = u() / 16
    end
    return out, outT
end

-- A walk's end at (x, y): its tile key, floor and costs (and times) to
-- that tile's entrance sides, from the baked spots where the point is one
-- (no tile decoded then), else searched once and kept, as every walk from
-- one end asks the same.
local function End(w, x, y, indoors)
    local data = w.data
    local spots = data.spots
    local s = not indoors and spots and spots[mfloor(x) .. ":" .. mfloor(y)]
    if s then
        local u = Reader(Unpack(s, data))
        local key, g = u(), u()
        local rk = key * 131072 + g
        local kept = w.reach[rk]
        if not kept then
            if w.reachN >= REACH_KEPT then w.reach, w.reachN = {}, 0 end
            kept = { Baked(u) }
            w.reach[rk], w.reachN = kept, w.reachN + 1
        end
        return key, g, kept[1], kept[2]
    end
    local t, g = Locate(w, x, y, indoors)
    if not g then return nil end
    local out, outT = ToEntrances(w, t, g)
    return t.key, g, out, outT
end

-- An end that is any floor within r yards of (x, y) (a dock or a landing
-- just off the ground), in every tile that circle touches: the costs from
-- the nearest such floor to each entrance side, and per tile key to every
-- floor of that tile; nil without one. Baked for fixed spots (sides only),
-- taken unless the walk starts in a tile the circle touches (fromKey),
-- where the way inside that tile is needed.
local function NearEnd(w, x, y, r, fromKey)
    local rk = mfloor(x) .. ":" .. mfloor(y) .. ":" .. r
    local kept = w.reach[rk]
    if kept then return kept[1], kept[2], kept[3], kept[4] end
    local N, cell = w.N, w.cell
    local data = w.data
    local baked = data.near and data.near[rk]
    if baked and fromKey then
        local touches = false
        for _, cx in ipairs({ x - r, x + r }) do
            for _, cy in ipairs({ y - r, y + r }) do
                if TileOf(cx, cy) == fromKey then touches = true end
            end
        end
        -- Not kept: only the full search below serves every walk.
        if not touches then
            local out, outT = Baked(Reader(Unpack(baked, data)))
            return out, outT, nil, nil
        end
    end
    local out, outT, floors, floorsT
    for _, cx in ipairs({ x - r, x + r }) do
        for _, cy in ipairs({ y - r, y + r }) do
            local key, sx, sy = TileOf(cx, cy)
            local t = not (floors and floors[key]) and Tile(w, key)
            local seeds
            for row = mmax(0, mfloor((x - r - sx) / cell)), mmin(N - 1, mfloor((x + r - sx) / cell)) do
                for col = mmax(0, mfloor((y - r - sy) / cell)), mmin(N - 1, mfloor((y + r - sy) / cell)) do
                    local cc = row * N + col
                    for g = t and t.cellFirst[cc] or 1, t and t.cellFirst[cc + 1] - 1 or 0 do
                        local gx, gy = FloorXY(w, t, g)
                        local d = msqrt((gx - x) ^ 2 + (gy - y) ^ 2)
                        if d <= r then
                            seeds = seeds or {}
                            seeds[g] = d
                        end
                    end
                end
            end
            if seeds then
                local cost, _, time = TileSearch(w, t, seeds, nil, nil, nil, true)
                floors, floorsT, out, outT = floors or {}, floorsT or {}, out or {}, outT or {}
                floors[key], floorsT[key] = cost, time
                local ec, et = EntranceCosts(w, t, cost, time)
                for node, c in pairs(ec) do
                    if not out[node] or c < out[node] then out[node], outT[node] = c, et[node] end
                end
            end
        end
    end
    if not out then return nil end
    if w.reachN >= REACH_KEPT then w.reach, w.reachN = {}, 0 end
    w.reach[rk], w.reachN = { out, outT, floors, floorsT }, w.reachN + 1
    return out, outT, floors, floorsT
end

local function Other(node) return node % 2 == 1 and node + 1 or node - 1 end

-- The ground each entrance side lies on (dev/tools/navmesh/ground.py): no
-- walk joins two grounds. false: the data does not say.
local function Ground(w)
    if w.ground ~= nil then return w.ground end
    local data = w.data
    local s = data.ground
    w.ground = false
    if not s then return false end
    local u = Reader(Unpack(s, data))
    local out = {}
    for e = 1, u() do
        if e % 8192 == 0 then Pause() end
        local gr = u()
        out[2 * e - 1], out[2 * e] = gr, gr
    end
    w.ground = out
    return out
end

local onGround = {}

-- Landmark distances as refine.py bakes them: per landmark, whole yards
-- to each entrance (its nearer side), 0 unknown. A walk between two sides
-- is at least the difference of their distances from any one landmark.
local function Landmarks(w)
    if w.alt ~= nil then return w.alt or nil end
    local data = w.data
    local a = data.alt
    if not a then w.alt = false return nil end
    local _, i = Reader(Unpack(a.d, data))
    local n = Entrances(w).n
    -- Per landmark a string, three bytes an entrance.
    local tabs, parts = {}, {}
    for l = 1, a.n do
        local last = 0
        for e = 1, n do
            if e % 4096 == 0 then Pause() end
            last = last + i()
            parts[e] = schar(last % 256, mfloor(last / 256) % 256, mfloor(last / 65536))
        end
        tabs[l] = tconcat(parts, "", 1, n)
    end
    w.alt = tabs
    return tabs
end
-- Whole yards from a landmark to entrance e, 0 unknown.
local function Mark(s, e)
    local lo, mid, hi = sbyte(s, 3 * e - 2, 3 * e)
    return lo + mid * 256 + hi * 65536
end

-- The cheapest way over the entrance sides from fromA's sides to toB's,
-- each with its cost on to the walk's end at (bx, by), or any floor within
-- circle yards of it. A* under the straight line and, for a point end,
-- the landmark bound to the end's nearest side, which holds since every
-- pair cost is at least the way inside the tile. best: a way in hand
-- inside one tile; limit: given up past this many yards. The cost, the
-- side it ends at (nil for the way in hand) and the sides before each.
local marksPick = {}
local function Search(w, fromA, toB, bx, by, best, limit, circle)
    local ents = Entrances(w)
    local ev = ents.v
    local alt = not circle and Landmarks(w)
    -- The landmarks used: those whose bound between the nearest sides of
    -- the two ends is largest, as they tell the most along the way.
    local used, used0, K = {}, {}, 0
    local e0, fin0
    if alt then
        local es, cs = nil, mhuge
        for node, c in pairs(fromA) do
            if c < cs then es, cs = (node + node % 2) / 2, c end
        end
        fin0 = mhuge
        for node, fin in pairs(toB) do
            if fin < fin0 then e0, fin0 = (node + node % 2) / 2, fin end
        end
        -- Whole yards in the data, the nearer side's, and pair costs
        -- rounded to the half yard: a cell and a yard and a quarter of play.
        fin0 = fin0 + w.cell + 1.25
        local n = 0
        for l = 1, #alt do
            local d0, ds = Mark(alt[l], e0), Mark(alt[l], es)
            if d0 > 0 and ds > 0 then
                n = n + 1
                marksPick[n] = l
                marksPick[-l] = d0 > ds and d0 - ds or ds - d0
            end
        end
        for k = n + 1, #marksPick do marksPick[k] = nil end
        tsort(marksPick, function(a, b) return marksPick[-a] > marksPick[-b] end)
        for k = 1, mmin(n, LANDMARKS_USED) do
            K = K + 1
            used[K] = alt[marksPick[k]]
            used0[K] = Mark(used[K], e0)
        end
    end
    local slack = circle or 0
    local hc = {}   -- each side's bound, once a search
    local function H(node)
        local h = hc[node]
        if h then return h end
        local x, y = SideXY(w, ev[node])
        h = msqrt((bx - x) ^ 2 + (by - y) ^ 2) - slack
        local e = (node + node % 2) / 2
        for l = 1, K do
            local d0, dv = used0[l], Mark(used[l], e)
            if dv > 0 then
                local diff = (d0 > dv and d0 - dv or dv - d0) - fin0
                if diff > h then h = diff end
            end
        end
        if h < 0 then h = 0 end
        hc[node] = h
        return h
    end
    local g, prev, heap = {}, {}, NewHeap()
    for node, c in pairs(fromA) do
        g[node] = c
        heap:Push(c + H(node), node)
    end
    local reached, cut
    local cell = w.cell
    local pops = 0
    while true do
        pops = pops + 1
        if pops % 64 == 0 then Pause() end
        local node, f = heap:Pop()
        if not node or f >= best then break end
        if limit and f > limit then
            cut = best == mhuge
            break
        end
        local here = g[node]
        -- The landmark bound's rounding makes it uneven from side to side,
        -- so a side may be reached cheaper after it was taken: the cheaper
        -- way is pushed too, and an entry it outdid is passed over here.
        if f <= here + H(node) + 0.001 then
            local fin = toB[node]
            if fin and here + fin < best then best, reached = here + fin, node end
            -- Across the edge to the entrance's other side, then on inside that tile.
            local o = Other(node)
            local c = here + cell
            if not g[o] or c < g[o] then
                g[o], prev[o] = c, node
                heap:Push(c + H(o), o)
            end
            local key = SideKey(ev[node])
            local tc = TileCosts(w, key)
            if tc then
                local df = Danger(w, key)
                local n, side, cost = tc.n, tc.side, tc.cost
                local i = tc.at[node]
                local row = (i - 1) * n - (i - 1) * i / 2 - i
                for j = 1, n do
                    if j ~= i then
                        if j > i then c = cost[row + j] else c = cost[(j - 1) * n - (j - 1) * j / 2 + (i - j)] end
                        if c then
                            o = side[j]
                            c = here + c * df
                            if not g[o] or c < g[o] then
                                g[o], prev[o] = c, node
                                heap:Push(c + H(o), o)
                            end
                        end
                    end
                end
            end
        end
    end
    return best, reached, prev, cut
end

local function NearKey(x, y, r) return mfloor(x) .. ":" .. mfloor(y) .. ":" .. r end

-- The walk from a to b: cost (running yards), the entrance sides it passes
-- (pairs: leave a tile, enter the next), both ends' tile key and floor,
-- and its time (yards walked, swimming slower): the ends' ways, each
-- pair's along the chain, a cell per crossing.
local function Walk(w, ax, ay, bx, by, opts)
    local keyA, ga, fromA, fromAT = End(w, ax, ay, opts and opts.indoorsA)
    if not ga then return nil end
    local near = opts and opts.near
    local keyB, gb, toB, toBT, nearFloors, nearFloorsT
    if near then
        toB, toBT, nearFloors, nearFloorsT = NearEnd(w, bx, by, near, keyA)
    else
        keyB, gb, toB, toBT = End(w, bx, by, opts and opts.indoorsB)
    end
    if not toB then return nil end
    local best, bestTime = mhuge, nil
    if nearFloors then
        local inTile = nearFloors[keyA]
        if inTile and inTile[ga] then best, bestTime = inTile[ga], nearFloorsT[keyA][ga] end
    elseif keyA == keyB then
        local cost, _, time = TileSearch(w, Tile(w, keyA), ga, gb)
        if cost[gb] then best, bestTime = cost[gb], time[gb] end
    end
    -- B is reached only on ground A stands on.
    local ground = Ground(w)
    if ground and best == mhuge then
        wipe(onGround)
        for node in pairs(fromA) do onGround[ground[node]] = true end
        local joined = false
        for node in pairs(toB) do
            if onGround[ground[node]] then joined = true break end
        end
        if not joined then return nil end
    end
    local reached, prev, cut
    best, reached, prev, cut = Search(w, fromA, toB, bx, by, best, opts and opts.limit, near)
    if best == mhuge then return nil, cut end
    local chain = {}
    local node = reached
    while node do
        tinsert(chain, 1, node)
        node = prev[node]
    end
    local time = bestTime
    if reached then
        time = fromAT[chain[1]] + toBT[reached]
        local ents = Entrances(w)
        for k = 1, #chain - 1 do
            local n1, n2 = chain[k], chain[k + 1]
            if n2 == Other(n1) then
                time = time + w.cell
            else
                local tc = TileCosts(w, SideKey(ents.v[n1]))
                local i, j, n = tc.at[n1], tc.at[n2], tc.n
                time = time + tc.time[j > i and ((i - 1) * n - (i - 1) * i / 2 - i + j)
                                      or ((j - 1) * n - (j - 1) * j / 2 + (i - j))]
            end
        end
    end
    return best, chain, keyA, ga, keyB, gb, time * PULLED
end

-- A point's distance from each landmark: the least, over its tile's
-- sides, of the way to the side and the side's own; false where unknown.
-- Kept by the point, so every walk between fixed spots is bounded at once.
local function Marks(w, x, y)
    local key = mfloor(x) .. ":" .. mfloor(y)
    local m = w.marks[key]
    if m ~= nil then return m or nil end
    w.used = GetTime()
    local alt = Landmarks(w)
    local _, _, reach = End(w, x, y)
    if not (alt and reach) then
        w.marks[key] = false
        return nil
    end
    m = {}
    for l = 1, #alt do
        local s, least = alt[l], mhuge
        for node, fin in pairs(reach) do
            local d = Mark(s, (node + node % 2) / 2)
            if d > 0 and fin + d < least then least = fin + d end
        end
        m[l] = least < mhuge and least or false
    end
    w.marks[key] = m
    return m
end

-- What the walk from a to b costs at the least, in running yards, from the
-- landmarks: at least the difference of the ends' distances from any one.
-- Nil without landmarks or an end off the grid.
function Nav.Bound(ci, ax, ay, bx, by)
    local w = World(ci)
    if not w then return nil end
    local ma, mb = Marks(w, ax, ay), Marks(w, bx, by)
    if not (ma and mb) then return nil end
    local best, play = 0, w.cell + 1
    for l = 1, #ma do
        local a, b = ma[l], mb[l]
        if a and b then
            local diff = (a > b and a - b or b - a) - play
            if diff > best then best = diff end
        end
    end
    return best
end

-- For dev/tools/navmesh/bake_spots.lua: a fixed spot's key and costs to
-- its tile's entrance sides, or with near its boarding circle's.
function Nav.SpotReach(ci, x, y, near)
    local w = World(ci)
    if not w then return nil end
    if near then
        local out, outT = NearEnd(w, x, y, near)
        return NearKey(x, y, near), out, outT
    end
    local t, g = Locate(w, x, y)
    if not g then return nil end
    local out, outT = ToEntrances(w, t, g)
    return t.key, g, out, outT
end

-- A walk as Walk finds it, kept with its chain: the drawing of a priced
-- walk reads the chain instead of searching again. false: no way; beyond:
-- not found within the limit asked.
local BEYOND = { beyond = true }
local function Kept(w, ax, ay, bx, by, opts)
    local key = mfloor(ax / 4) .. ":" .. mfloor(ay / 4) .. ":" .. mfloor(bx / 4) .. ":" .. mfloor(by / 4)
        .. ((opts and opts.indoorsA) and "i" or "") .. ((opts and opts.indoorsB) and "i" or "")
        .. ((opts and opts.limit) and ("L" .. mfloor(opts.limit)) or "")
        .. ((opts and opts.near) and ("N" .. opts.near) or "")
    local walk = w.walks[key]
    w.used = GetTime()
    if walk == nil then
        if w.walksN >= WALKS_KEPT then w.walks, w.walksN = {}, 0 end
        local cost, chain, keyA, ga, keyB, gb, time = Walk(w, ax, ay, bx, by, opts)
        walk = cost and { cost, chain, keyA, ga, keyB, gb, time } or (chain and BEYOND) or false
        w.walks[key], w.walksN = walk, w.walksN + 1
    end
    return walk
end

-- Walking cost in running yards from (ax, ay) to (bx, by) on continent ci,
-- or nil (no data there, or no way on foot), then nil and the walk's time
-- (yards walked, swimming slower). opts.indoorsA / indoorsB pick the floor
-- at each end; opts.limit gives up past that many running yards, answering
-- nil, true; opts.near takes any floor within that many yards of b as the
-- end.
function Nav.Walk(ci, ax, ay, bx, by, opts)
    local w = World(ci)
    if not w then return nil end
    local walk = Kept(w, ax, ay, bx, by, opts)
    if not walk then return nil end
    if walk.beyond then return nil, true end
    return walk[1], nil, walk[7]
end

function Nav.Has(ci) return ns.GPSNavData ~= nil and ns.GPSNavData[ci] ~= nil end
Nav.Ensure = Nav.Has

-- What every search on continent ci reads first (the entrance sides, the
-- grounds, the landmarks), decoded now, in the planner's slices, so the
-- first click of a session does not pay for it.
function Nav.Warm(ci)
    local w = World(ci)
    if not w then return end
    Entrances(w)
    Ground(w)
    Landmarks(w)
    -- A use like any walk's: Release lets the decoded tables go after an
    -- idle minute instead of keeping them for the session.
    w.used = GetTime()
end

-- The grid's base64 decoded once to deflated bytes, a continent at a time
-- in slices, and the base64 let go: a quarter less resident. A new table
-- replaces the old whole, so a reader keeps the form it started with.
function Nav.DecodeBlobs(onDone)
    local E = C_EncodingUtil
    if not (E and E.DecodeBase64 and ns.GPSNavData) then return end
    local cis = {}
    for ci, data in pairs(ns.GPSNavData) do
        if not data.raw then cis[#cis + 1] = ci end
    end
    if #cis == 0 then return end
    Utils.RunSliced(function()
        for _, ci in ipairs(cis) do
            local old = ns.GPSNavData[ci]
            local new = {}
            for k, v in pairs(old) do
                if type(v) == "string" then
                    new[k] = E.DecodeBase64(v)
                elseif type(v) == "table" then
                    local t = {}
                    for kk, vv in pairs(v) do
                        t[kk] = type(vv) == "string" and E.DecodeBase64(vv) or vv
                        Utils.SliceCheckpoint()
                    end
                    new[k] = t
                else
                    new[k] = v
                end
            end
            new.raw = true
            ns.GPSNavData[ci] = new
            local w = worlds[ci]
            if w then w.data = new end
        end
    end, onDone, 6)
end

-- Decoded data idle for age seconds goes: a tile by its last read, and a
-- continent's entrance sides, grounds, landmarks and kept searches once
-- no walk has asked for them. True while anything a walk decoded remains.
function Nav.Release(age)
    local now = GetTime()
    local held = false
    for _, w in pairs(worlds) do
        local order = w.order
        for i = #order, 1, -1 do
            local key = order[i]
            if w.tiles[key].at + age <= now then
                w.tiles[key] = nil
                tremove(order, i)
            end
        end
        if #order > 0 then held = true end
        if w.used then
            if w.used + age <= now then
                w.used, w.ents, w.ground, w.alt = nil, nil, nil, nil
                w.walks, w.walksN, w.reach, w.reachN, w.costs, w.marks = {}, 0, {}, 0, {}, {}
            else
                held = true
            end
        end
    end
    return held
end

-- Drawing ---------------------------------------------------------------------

-- Whether one walks straight from floor a to floor b of tile t: the cells
-- along the line, each reached from the one before by a link.
local function Clear(w, t, a, b)
    local N = w.N
    local ca, cb = t.fcell[a], t.fcell[b]
    local r, c, r1, c1 = mfloor(ca / N), ca % N, mfloor(cb / N), cb % N
    local dr, dc = r1 - r, c1 - c
    local sr, sc = dr > 0 and 1 or -1, dc > 0 and 1 or -1
    local nr, ncl = mabs(dr), mabs(dc)
    local g = a
    local ir, ic = 0, 0
    while ir < nr or ic < ncl do
        -- Step along whichever axis the line crosses next.
        local stepRow = (0.5 + ir) * ncl < (0.5 + ic) * nr
        if ic >= ncl then stepRow = true elseif ir >= nr then stepRow = false end
        local d
        if stepRow then d = sr > 0 and 1 or 3; ir = ir + 1 else d = sc > 0 and 2 or 0; ic = ic + 1 end
        local u, o = Step(w, t, g, d)
        if not o or u ~= t then return false end
        g = o
    end
    return g == b
end

-- Whether one walks straight from (ax, ay) to (bx, by): each cell along
-- the line reached from the one before by a link, across tiles, and none
-- of them water unless the start is. nil off the grid.
function Nav.Straight(ci, ax, ay, bx, by, indoors)
    local w = World(ci)
    if not w then return nil end
    local t, g = Locate(w, ax, ay, indoors, 1)
    if not g then return nil end
    local cell = w.cell
    local x0, y0 = FloorXY(w, t, g)
    local _, sx, sy = TileOf(bx, by)
    local x1 = sx + (mfloor((bx - sx) / cell) + 0.5) * cell
    local y1 = sy + (mfloor((by - sy) / cell) + 0.5) * cell
    local nr, ncl = mfloor(mabs(x1 - x0) / cell + 0.5), mfloor(mabs(y1 - y0) / cell + 0.5)
    local alongRow, alongCol = x1 > x0 and 1 or 3, y1 > y0 and 2 or 0
    local dry = t.b[g] % 2 == 0
    local ir, ic = 0, 0
    while ir < nr or ic < ncl do
        local stepRow = (0.5 + ir) * ncl < (0.5 + ic) * nr
        if ic >= ncl then stepRow = true elseif ir >= nr then stepRow = false end
        local d
        if stepRow then d, ir = alongRow, ir + 1 else d, ic = alongCol, ic + 1 end
        t, g = Step(w, t, g, d)
        if not g or (dry and t.b[g] % 2 == 1) then return false end
    end
    return true
end

-- Floor path inside tile t from a to b, pulled straight: world points
-- appended to out.
local function TilePath(w, t, a, b, out)
    local _, prev = TileSearch(w, t, a, b)
    if a ~= b and not prev[b] then return false end
    local cells = {}
    local g = b
    while g do
        tinsert(cells, 1, g)
        if g == a then break end
        g = prev[g]
    end
    local i = 1
    local function emit(f)
        local x, y = FloorXY(w, t, f)
        if not (out[#out - 1] == x and out[#out] == y) then out[#out + 1], out[#out + 2] = x, y end
    end
    emit(cells[1])
    local bends = 0
    while i < #cells do
        local j = i + 1
        while j < #cells and Clear(w, t, cells[i], cells[j + 1]) do j = j + 1 end
        emit(cells[j])
        i = j
        bends = bends + 1
        if bends % 8 == 0 then Pause() end
    end
    return true
end

-- The walk's points { x1, y1, x2, y2, ... } from a to b, its cost (the
-- yards it was chosen by) and its time (yards walked, swimming slower,
-- the same the walk was priced by), or nil.
function Nav.Path(ci, ax, ay, bx, by, opts)
    local w = World(ci)
    if not w then return nil end
    local walk = Kept(w, ax, ay, bx, by, opts)
    if not walk or walk.beyond then return nil end
    local cost, chain, keyA, ga, keyB, gb = walk[1], walk[2], walk[3], walk[4], walk[5], walk[6]
    if not keyB then return nil end
    local ev = Entrances(w).v
    local out = { ax, ay }
    local t, g = Tile(w, keyA), ga
    local k = 1
    while k <= #chain do
        local node = chain[k]
        if SideKey(ev[node]) ~= t.key then return nil end
        if not TilePath(w, t, g, SideFloor(ev[node]), out) then return nil end
        -- Across: the next node is the other side when the walk crosses here.
        local nxt = chain[k + 1]
        if nxt == Other(node) then
            t = Tile(w, SideKey(ev[nxt]))
            g = SideFloor(ev[nxt])
            k = k + 2
        else
            g = SideFloor(ev[node])
            k = k + 1
        end
        if not t then return nil end
    end
    if t.key ~= keyB then return nil end
    t = Tile(w, keyB)
    if not TilePath(w, t, g, gb, out) then return nil end
    out[#out + 1], out[#out + 2] = bx, by
    return out, cost, walk[7]
end

-- Probe (dev tools, tests): the tile and floor under a point (exact: its
-- own cell only), its cell, and how many of its tile's entrance sides it
-- reaches of how many.
function Nav.Probe(ci, x, y, indoors, exact)
    local w = World(ci)
    if not w then return nil end
    local t, g = Locate(w, x, y, indoors, exact and 0 or nil)
    if not g then return t and t.key end
    local reach = ToEntrances(w, t, g)
    local n = 0
    for _ in pairs(reach) do n = n + 1 end
    local tc = TileCosts(w, t.key)
    return t.key, g, t.fcell[g], n, tc and tc.n or 0, t.nf
end
