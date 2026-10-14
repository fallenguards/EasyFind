-- Walking on WoW Forever's baked walking grid (ns.GPSNavData, written by
-- dev/tools/navmesh/pack.py): 4 yd cells, each with its floors, linked
-- where one can really walk. A long walk is searched on the tiles'
-- entrances; only the tiles at its ends, and those a drawn path crosses,
-- are unpacked and searched cell by cell.
local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns then return end

local Nav = {}
ns.GPSNav = Nav

local sbyte, mfloor, msqrt, mhuge, mabs = string.byte, math.floor, math.sqrt, math.huge, math.abs
local mmax, mmin = math.max, math.min
local tinsert, tremove, tsort = table.insert, table.remove, table.sort

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
Nav.epoch = 0            -- bumped whenever walks would come out differently

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

local function Unpack(s)
    local E = C_EncodingUtil
    local method = Enum and Enum.CompressionMethod and Enum.CompressionMethod.Deflate or 0
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

local function DecodeTile(w, key)
    local s = w.data.tiles[key]
    if not s then return nil end
    local raw = Unpack(s)
    local N = w.N
    local NN = N * N
    local cellFirst, cellN, fcell = {}, {}, {}
    local counts = Bytes(raw, 1, NN, {}, 0)
    local f = 0
    for c = 0, NN - 1 do
        local n = counts[c]
        cellFirst[c], cellN[c] = f + 1, n
        for _ = 1, n do
            f = f + 1
            fcell[f] = c
        end
    end
    local pos = NN + 1
    local bytes = Bytes(raw, pos, pos + f - 1, {}, 1)
    pos = pos + f
    -- Road cells: a bit each after the floors, low bit first.
    local roadBytes = Bytes(raw, pos, pos + mfloor((NN + 7) / 8) - 1, {}, 0)
    -- Per floor: its flags, its links west and north (the data's; east
    -- and south are read back from them as asked), and what a yard on it
    -- costs to choose.
    local flag, wc, nc, wt, W, Nn = {}, {}, {}, {}, {}, {}
    for g = 1, f do
        if g % 4096 == 0 then Pause() end
        local b = bytes[g]
        local fl = b % 4
        local k = mfloor(b / 4) % 8
        flag[g], wc[g] = fl, k
        local c = fcell[g]
        if k > 0 and c % N < N - 1 and k <= cellN[c + 1] then W[g] = cellFirst[c + 1] + k - 1 end
        k = mfloor(b / 32)
        nc[g] = k
        if k > 0 and c < NN - N and k <= cellN[c + N] then Nn[g] = cellFirst[c + N] + k - 1 end
        local rb = roadBytes[mfloor(c / 8)]
        local onRoad = rb and mfloor(rb / BIT[c % 8]) % 2 == 1
        wt[g] = (fl % 2 == 1 and SWIM_WEIGHT or 1) * (onRoad and 1 or offRoad)
    end
    local tx, ty = mfloor(key / 64), key % 64
    return { key = key, tx = tx, ty = ty, N = N, nf = f, cellFirst = cellFirst, cellN = cellN,
             fcell = fcell, flag = flag, wc = wc, nc = nc, wt = wt, W = W, N_ = Nn,
             sx = ORIGIN - ty * TILE - TILE, sy = ORIGIN - tx * TILE - TILE }
end

-- The floor east (south) of g inside its tile: the first in the cell
-- before (a row before) that links west (north) to g, or nil.
local function East(t, g)
    local c = t.fcell[g]
    if c % t.N == 0 then return nil end
    local cc, W = c - 1, t.W
    for o = t.cellFirst[cc], t.cellFirst[cc] + t.cellN[cc] - 1 do
        if W[o] == g then return o end
    end
    return nil
end
local function South(t, g)
    local c = t.fcell[g]
    local N = t.N
    if c < N then return nil end
    local cc, Nn = c - N, t.N_
    for o = t.cellFirst[cc], t.cellFirst[cc] + t.cellN[cc] - 1 do
        if Nn[o] == g then return o end
    end
    return nil
end

local function Tile(w, key)
    local t = w.tiles[key]
    if t then return t end
    t = DecodeTile(w, key)
    if not t then return nil end
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
        if col < N - 1 then local o = t.W[g] return o and t, o end
        local k = t.wc[g]
        if k == 0 then return nil end
        local u = Tile(w, t.key - 64)
        if not u then return nil end
        local cc = r * N
        if k > u.cellN[cc] then return nil end
        return u, u.cellFirst[cc] + k - 1
    elseif d == 1 then
        if r < N - 1 then local o = t.N_[g] return o and t, o end
        local k = t.nc[g]
        if k == 0 then return nil end
        local u = Tile(w, t.key - 1)
        if not u then return nil end
        if k > u.cellN[col] then return nil end
        return u, u.cellFirst[col] + k - 1
    elseif d == 0 then
        if col > 0 then local o = East(t, g) return o and t, o end
        local u = Tile(w, t.key + 64)
        if not u then return nil end
        local cc = r * N + N - 1
        local rank = Rank(t, g)
        for o = u.cellFirst[cc], u.cellFirst[cc] + u.cellN[cc] - 1 do
            if u.wc[o] == rank then return u, o end
        end
    else
        if r > 0 then local o = South(t, g) return o and t, o end
        local u = Tile(w, t.key + 1)
        if not u then return nil end
        local cc = (N - 1) * N + col
        local rank = Rank(t, g)
        for o = u.cellFirst[cc], u.cellFirst[cc] + u.cellN[cc] - 1 do
            if u.nc[o] == rank then return u, o end
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
    Nav.epoch = Nav.epoch + 1
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
                    for g = t.cellFirst[cc], t.cellFirst[cc] + t.cellN[cc] - 1 do
                        local inside = mfloor(t.flag[g] / 2) == 1
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
    local W, Nn = t.W, t.N_
    local cellFirst, cellN = t.cellFirst, t.cellN
    local c, N = t.fcell[g], t.N
    local w0, n0 = W[g], Nn[g]
    local n = 0
    if w0 then n = n + 1; nbScratch[n], nbLen[n] = w0, 1 end
    if n0 then n = n + 1; nbScratch[n], nbLen[n] = n0, 1 end
    -- East and south: every floor in the cell before (a row before) that
    -- links west (north) to g; the first of each for the diagonals.
    local e0, s0
    if c % N > 0 then
        local cc = c - 1
        for o = cellFirst[cc], cellFirst[cc] + cellN[cc] - 1 do
            if W[o] == g then n = n + 1; nbScratch[n], nbLen[n] = o, 1; e0 = e0 or o end
        end
    end
    if c >= N then
        local cc = c - N
        for o = cellFirst[cc], cellFirst[cc] + cellN[cc] - 1 do
            if Nn[o] == g then n = n + 1; nbScratch[n], nbLen[n] = o, 1; s0 = s0 or o end
        end
    end
    if n0 and w0 then
        local x = W[n0]
        if x and Nn[w0] == x then n = n + 1; nbScratch[n], nbLen[n] = x, DIAG end
    end
    if n0 and e0 then
        local x = Nn[e0]
        if x and W[x] == n0 then n = n + 1; nbScratch[n], nbLen[n] = x, DIAG end
    end
    if s0 and w0 then
        local x = W[s0]
        if x and Nn[x] == w0 then n = n + 1; nbScratch[n], nbLen[n] = x, DIAG end
    end
    if s0 and e0 then
        local cc = c - 1 - N
        for x = cellFirst[cc], cellFirst[cc] + cellN[cc] - 1 do
            if W[x] == s0 and Nn[x] == e0 then n = n + 1; nbScratch[n], nbLen[n] = x, DIAG break end
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
local function TileSearch(w, t, g0, goal, want, left)
    local cost, prev, closed, time = {}, {}, {}, {}
    local cell = w.cell * Danger(w, t.key) / 2
    local half = w.cell / 2
    local wt, flag = t.wt, t.flag
    local pops = 0
    if goal then
        local heap = NewHeap()
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
                local base, wg, tbase = cost[g], wt[g], time[g]
                local sg = flag[g] % 2 == 1 and SWIM_WEIGHT or 1
                local n = TileNeighbours(t, g)
                for k = 1, n do
                    local o = nbScratch[k]
                    if not closed[o] then
                        local nc = base + nbLen[k] * cell * (wg + wt[o])
                        if not cost[o] or nc < cost[o] then
                            cost[o], prev[o] = nc, g
                            time[o] = tbase + nbLen[k] * half * (sg + (flag[o] % 2 == 1 and SWIM_WEIGHT or 1))
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
    local buckets, lo, hi = {}, mhuge, 0
    local function Put(g, c)
        local b = mfloor(c / width)
        local list = buckets[b]
        if not list then
            list = {}
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
                local base, wg, tbase = cost[g], wt[g], time[g]
                local sg = flag[g] % 2 == 1 and SWIM_WEIGHT or 1
                local n = TileNeighbours(t, g)
                for k = 1, n do
                    local o = nbScratch[k]
                    if not closed[o] then
                        local nc = base + nbLen[k] * cell * (wg + wt[o])
                        if not cost[o] or nc < cost[o] then
                            cost[o], prev[o] = nc, g
                            time[o] = tbase + nbLen[k] * half * (sg + (flag[o] % 2 == 1 and SWIM_WEIGHT or 1))
                            Put(o, nc)
                        end
                    end
                end
            end
        end
        buckets[b] = nil
        b = b + 1
    end
    return cost, prev, time
end

-- Entrances: per entrance two sides (tile, floor, cell); side 1 of entrance
-- e is node 2e - 1, side 2 node 2e.
local function Entrances(w)
    if w.ents then return w.ents end
    local u = Reader(Unpack(w.data.ents))
    local n = u()
    local e = { n = n, key = {}, floor = {}, x = {}, y = {} }
    local N, cell = w.N, w.cell
    for k = 1, 2 * n do
        if k % 4096 == 0 then Pause() end
        local key, f, c = u(), u(), u()
        local tx, ty = mfloor(key / 64), key % 64
        e.key[k], e.floor[k] = key, f
        e.x[k] = ORIGIN - ty * TILE - TILE + (mfloor(c / N) + 0.5) * cell
        e.y[k] = ORIGIN - tx * TILE - TILE + (c % N + 0.5) * cell
    end
    w.ents = e
    return e
end

local function TileCosts(w, key)
    local tc = w.costs[key]
    if tc ~= nil then return tc or nil end
    local s = (roadsOnly and w.data.roads or w.data.costs)[key]
    if not s then w.costs[key] = false return nil end
    local u, i = Reader(Unpack(s))
    local n = u()
    local ents = Entrances(w)
    local side, at, last = {}, {}, 0
    for k = 1, n do
        last = last + i()
        -- The entrance's side in this tile (ids count from 0 in the data).
        local node = (ents.key[2 * last + 1] == key) and (2 * last + 1) or (2 * last + 2)
        side[k], at[node] = node, k
    end
    -- Each pair's cost by its index in the upper triangle: the straight
    -- line plus the way around, false where no way joins them; and that
    -- way's time, the cost less what leaving roads added, as 127ths of
    -- the way around. A table flagged one way (a drop in the tile, data
    -- not shipped yet) lists every ordered pair; the way from the lower
    -- side is taken.
    local oneway = u() == 1
    local cost, time, ex, ey = {}, {}, ents.x, ents.y
    local function Pair(a, b, p)
        local code = u()
        if code == 0 then
            if p then cost[p] = false end
        else
            local off = u()
            if p then
                local na, nb = side[a], side[b]
                local around = (code - 1) / 2
                local c = msqrt((ex[na] - ex[nb]) ^ 2 + (ey[na] - ey[nb]) ^ 2) + around
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
        local f = ents.floor[node]
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
        local f = ents.floor[tc.side[k]]
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
    local spots = w.data.spots
    local s = not indoors and spots and spots[mfloor(x) .. ":" .. mfloor(y)]
    if s then
        local u = Reader(Unpack(s))
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
    local baked = w.data.near and w.data.near[rk]
    if baked and fromKey then
        local touches = false
        for _, cx in ipairs({ x - r, x + r }) do
            for _, cy in ipairs({ y - r, y + r }) do
                if TileOf(cx, cy) == fromKey then touches = true end
            end
        end
        -- Not kept: only the full search below serves every walk.
        if not touches then
            local out, outT = Baked(Reader(Unpack(baked)))
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
                    for g = t and t.cellFirst[cc] or 1, t and t.cellFirst[cc] + t.cellN[cc] - 1 or 0 do
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
                local cost, _, time = TileSearch(w, t, seeds)
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
    local s = w.data.ground
    w.ground = false
    if not s then return false end
    local u = Reader(Unpack(s))
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
    local a = w.data.alt
    if not a then w.alt = false return nil end
    local _, i = Reader(Unpack(a.d))
    local n = Entrances(w).n
    local tabs = {}
    for l = 1, a.n do
        local t, last = {}, 0
        for e = 1, n do
            if e % 4096 == 0 then Pause() end
            last = last + i()
            t[e] = last
        end
        tabs[l] = t
    end
    w.alt = tabs
    return tabs
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
    local ex, ey = ents.x, ents.y
    local alt = not circle and Landmarks(w)
    -- The landmarks used: those whose bound between the nearest sides of
    -- the two ends is largest, as they tell the most along the way.
    local used, K = {}, 0
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
            local d0, ds = alt[l][e0], alt[l][es]
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
        end
    end
    local slack = circle or 0
    local hc = {}   -- each side's bound, once a search
    local function H(node)
        local h = hc[node]
        if h then return h end
        h = msqrt((bx - ex[node]) ^ 2 + (by - ey[node]) ^ 2) - slack
        local e = (node + node % 2) / 2
        for l = 1, K do
            local t = used[l]
            local d0, dv = t[e0], t[e]
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
            local key = ents.key[node]
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
                local tc = TileCosts(w, ents.key[n1])
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
    local alt = Landmarks(w)
    local _, _, reach = End(w, x, y)
    if not (alt and reach) then
        w.marks[key] = false
        return nil
    end
    m = {}
    for l = 1, #alt do
        local t, least = alt[l], mhuge
        for node, fin in pairs(reach) do
            local d = t[(node + node % 2) / 2]
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
    local dry = t.flag[g] % 2 == 0
    local ir, ic = 0, 0
    while ir < nr or ic < ncl do
        local stepRow = (0.5 + ir) * ncl < (0.5 + ic) * nr
        if ic >= ncl then stepRow = true elseif ir >= nr then stepRow = false end
        local d
        if stepRow then d, ir = alongRow, ir + 1 else d, ic = alongCol, ic + 1 end
        t, g = Step(w, t, g, d)
        if not g or (dry and t.flag[g] % 2 == 1) then return false end
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
    local ents = Entrances(w)
    local out = { ax, ay }
    local t, g = Tile(w, keyA), ga
    local k = 1
    while k <= #chain do
        local node = chain[k]
        local key = ents.key[node]
        if key ~= t.key then return nil end
        if not TilePath(w, t, g, ents.floor[node], out) then return nil end
        -- Across: the next node is the other side when the walk crosses here.
        local nxt = chain[k + 1]
        if nxt == Other(node) then
            t = Tile(w, ents.key[nxt])
            g = ents.floor[nxt]
            k = k + 2
        else
            g = ents.floor[node]
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
