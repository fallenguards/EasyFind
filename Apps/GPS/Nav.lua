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
local tinsert, tremove = table.insert, table.remove

local TILE = 1600 / 3
local ORIGIN = 32 * TILE
local TILES_KEPT = 12              -- unpacked tiles held at once
local SNAP_CELLS = 6               -- a point off the grid takes a floor this many cells away
local REACH_KEPT = 64              -- end points whose tile search is kept
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
          reach = {}, reachN = 0, walks = {}, walksN = 0 }
    worlds[ci] = w
    return w
end

-- Tile key of a world point, and the tile's south-east corner.
local function TileOf(x, y)
    local tx, ty = mfloor((ORIGIN - y) / TILE), mfloor((ORIGIN - x) / TILE)
    return tx * 64 + ty, ORIGIN - ty * TILE - TILE, ORIGIN - tx * TILE - TILE
end
Nav.TileOf = TileOf

local function DecodeTile(w, key)
    local s = w.data.tiles[key]
    if not s then return nil end
    local raw = Unpack(s)
    local N = w.N
    local cellFirst, cellN = {}, {}
    local fcell, flag, wc, nc = {}, {}, {}, {}
    local f = 0
    local pos = N * N + 1
    for c = 0, N * N - 1 do
        local n = sbyte(raw, c + 1)
        cellFirst[c], cellN[c] = f + 1, n
        for _ = 1, n do
            f = f + 1
            local b = sbyte(raw, pos)
            pos = pos + 1
            fcell[f] = c
            flag[f] = b % 4
            wc[f] = mfloor(b / 4) % 8
            nc[f] = mfloor(b / 32)
        end
    end
    -- Road cells: a bit each after the floors, low bit first.
    local road = {}
    for c = 0, N * N - 1 do
        local b = sbyte(raw, pos + mfloor(c / 8))
        if b and mfloor(b / 2 ^ (c % 8)) % 2 == 1 then road[c] = true end
    end
    local tx, ty = mfloor(key / 64), key % 64
    local t = { key = key, tx = tx, ty = ty, N = N, nf = f, cellFirst = cellFirst, cellN = cellN,
                fcell = fcell, flag = flag, wc = wc, nc = nc, road = road,
                sx = ORIGIN - ty * TILE - TILE, sy = ORIGIN - tx * TILE - TILE }
    -- Links inside the tile, all four ways: west and north from the data,
    -- east and south their reverse (the lowest floor first; when several
    -- floors link to one, the others in extra). grid.py builds the same.
    local W, Nn, E, S, extra = {}, {}, {}, {}, {}
    for g = 1, f do
        local c = fcell[g]
        local r, col = mfloor(c / N), c % N
        local k = wc[g]
        if k > 0 and col < N - 1 and k <= cellN[c + 1] then
            local o = cellFirst[c + 1] + k - 1
            W[g] = o
            if not E[o] then E[o] = g else extra[o] = extra[o] or {}; tinsert(extra[o], g) end
        end
        k = nc[g]
        if k > 0 and r < N - 1 and k <= cellN[c + N] then
            local o = cellFirst[c + N] + k - 1
            Nn[g] = o
            if not S[o] then S[o] = g else extra[o] = extra[o] or {}; tinsert(extra[o], g) end
        end
    end
    t.W, t.N_, t.E, t.S, t.extra = W, Nn, E, S, extra
    return t
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
        if col > 0 then local o = t.E[g] return o and t, o end
        local u = Tile(w, t.key + 64)
        if not u then return nil end
        local cc = r * N + N - 1
        local rank = Rank(t, g)
        for o = u.cellFirst[cc], u.cellFirst[cc] + u.cellN[cc] - 1 do
            if u.wc[o] == rank then return u, o end
        end
    else
        if r > 0 then local o = t.S[g] return o and t, o end
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

-- Walks come out differently from now on: the ones kept are dropped.
local function Reset()
    Nav.epoch = Nav.epoch + 1
    for _, w in pairs(worlds) do
        w.walks, w.walksN, w.reach, w.reachN, w.costs = {}, 0, {}, 0, {}
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

-- What a yard on floor g costs to choose; Swim what it costs in time.
local function Swim(t, g) return t.flag[g] % 2 == 1 and SWIM_WEIGHT or 1 end
local function Weight(t, g) return Swim(t, g) * (t.road[t.fcell[g]] and 1 or offRoad) end

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
    local W, Nn, E, S = t.W, t.N_, t.E, t.S
    local w0, n0, e0, s0 = W[g], Nn[g], E[g], S[g]
    local n = 0
    if w0 then n = n + 1; nbScratch[n], nbLen[n] = w0, 1 end
    if n0 then n = n + 1; nbScratch[n], nbLen[n] = n0, 1 end
    if e0 then n = n + 1; nbScratch[n], nbLen[n] = e0, 1 end
    if s0 then n = n + 1; nbScratch[n], nbLen[n] = s0, 1 end
    if n0 and w0 and Nn[w0] and Nn[w0] == W[n0] then n = n + 1; nbScratch[n], nbLen[n] = W[n0], DIAG end
    if n0 and e0 and Nn[e0] and Nn[e0] == E[n0] then n = n + 1; nbScratch[n], nbLen[n] = E[n0], DIAG end
    if s0 and w0 and S[w0] and S[w0] == W[s0] then n = n + 1; nbScratch[n], nbLen[n] = W[s0], DIAG end
    if s0 and e0 and S[e0] and S[e0] == E[s0] then n = n + 1; nbScratch[n], nbLen[n] = E[s0], DIAG end
    local more = t.extra[g]
    for k = 1, more and #more or 0 do n = n + 1; nbScratch[n], nbLen[n] = more[k], 1 end
    return n
end

-- Inside one tile from floor g0: each floor's cost and the floor before.
-- With a goal the search stops there (A* on the straight line).
local function TileSearch(w, t, g0, goal)
    local cost, prev, closed = { [g0] = 0 }, {}, {}
    local heap = NewHeap()
    heap:Push(0, g0)
    local gx, gy
    if goal then gx, gy = FloorXY(w, t, goal) end
    local cell = w.cell * Danger(w, t.key)
    while true do
        local g = heap:Pop()
        if not g then break end
        if not closed[g] then
            closed[g] = true
            if g == goal then break end
            local base, wg = cost[g], Weight(t, g)
            local n = TileNeighbours(t, g)
            for k = 1, n do
                local o = nbScratch[k]
                if not closed[o] then
                    local nc = base + nbLen[k] * cell * (wg + Weight(t, o)) / 2
                    if not cost[o] or nc < cost[o] then
                        cost[o], prev[o] = nc, g
                        local h = 0
                        if goal then
                            local ox, oy = FloorXY(w, t, o)
                            h = msqrt((gx - ox) ^ 2 + (gy - oy) ^ 2)
                        end
                        heap:Push(nc + h, o)
                    end
                end
            end
        end
    end
    return cost, prev
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
    local codes = {}
    for k = 1, n * (n - 1) / 2 do codes[k] = u() end
    tc = { side = side, at = at, n = n, codes = codes }
    w.costs[key] = tc
    return tc
end

local function PairCost(tc, ents, a, b)
    local i, j = tc.at[a], tc.at[b]
    if i > j then i, j = j, i end
    local code = tc.codes[(i - 1) * tc.n - (i - 1) * i / 2 + (j - i)]
    if not code or code == 0 then return nil end
    return msqrt((ents.x[a] - ents.x[b]) ^ 2 + (ents.y[a] - ents.y[b]) ^ 2) + (code - 1) / 2
end

-- Costs from floor g of tile t to each entrance side in that tile; kept
-- per floor, as every walk from one spot asks the same.
local function ToEntrances(w, t, g)
    local rk = t.key * 131072 + g
    local kept = w.reach[rk]
    if kept then return kept end
    if w.reachN >= REACH_KEPT then w.reach, w.reachN = {}, 0 end
    local cost = TileSearch(w, t, g)
    local tc = TileCosts(w, t.key)
    local ents = Entrances(w)
    local out = {}
    for k = 1, tc and tc.n or 0 do
        local node = tc.side[k]
        local c = cost[ents.floor[node]]
        if c then out[node] = c end
    end
    w.reach[rk], w.reachN = out, w.reachN + 1
    return out
end

local function Other(node) return node % 2 == 1 and node + 1 or node - 1 end

-- The walk from a to b: cost (running yards), the entrance sides it passes
-- (pairs: leave a tile, enter the next), and both ends' tile and floor.
local function Walk(w, ax, ay, bx, by, opts)
    local ta, ga = Locate(w, ax, ay, opts and opts.indoorsA)
    local tb, gb = Locate(w, bx, by, opts and opts.indoorsB)
    if not (ga and gb) then return nil end
    local ents = Entrances(w)
    local best = mhuge
    if ta.key == tb.key then
        local cost = TileSearch(w, ta, ga, gb)
        if cost[gb] then best = cost[gb] end
    end
    local fromA = ToEntrances(w, ta, ga)
    local toB = ToEntrances(w, tb, gb)
    local g, prev, closed, heap = {}, {}, {}, NewHeap()
    for node, c in pairs(fromA) do
        g[node] = c
        heap:Push(c + msqrt((bx - ents.x[node]) ^ 2 + (by - ents.y[node]) ^ 2), node)
    end
    local reached
    local cell = w.cell
    while true do
        local node, f = heap:Pop()
        if not node or f >= best then break end
        if not closed[node] then
            closed[node] = true
            local fin = toB[node]
            if fin and g[node] + fin < best then best, reached = g[node] + fin, node end
            -- Across the edge to the entrance's other side, then on inside that tile.
            local here = g[node]
            local o = Other(node)
            if not closed[o] and (not g[o] or here + cell < g[o]) then
                g[o], prev[o] = here + cell, node
                heap:Push(here + cell + msqrt((bx - ents.x[o]) ^ 2 + (by - ents.y[o]) ^ 2), o)
            end
            local tc = TileCosts(w, ents.key[node])
            local df = Danger(w, ents.key[node])
            for k = 1, tc and tc.n or 0 do
                o = tc.side[k]
                if o ~= node and not closed[o] then
                    local c = PairCost(tc, ents, node, o)
                    c = c and c * df
                    if c and (not g[o] or here + c < g[o]) then
                        g[o], prev[o] = here + c, node
                        heap:Push(here + c + msqrt((bx - ents.x[o]) ^ 2 + (by - ents.y[o]) ^ 2), o)
                    end
                end
            end
        end
    end
    if best == mhuge then return nil end
    local chain = {}
    local node = reached
    while node do
        tinsert(chain, 1, node)
        node = prev[node]
    end
    return best, chain, ta, ga, tb, gb
end

-- Walking cost in running yards from (ax, ay) to (bx, by) on continent ci,
-- or nil (no data there, or no way on foot). opts.indoorsA / indoorsB pick
-- the floor at each end.
function Nav.Walk(ci, ax, ay, bx, by, opts)
    local w = World(ci)
    if not w then return nil end
    local key = mfloor(ax / 4) .. ":" .. mfloor(ay / 4) .. ":" .. mfloor(bx / 4) .. ":" .. mfloor(by / 4)
        .. ((opts and opts.indoorsA) and "i" or "") .. ((opts and opts.indoorsB) and "i" or "")
    local cost = w.walks[key]
    if cost == nil then
        if w.walksN >= WALKS_KEPT then w.walks, w.walksN = {}, 0 end
        cost = Walk(w, ax, ay, bx, by, opts) or false
        w.walks[key], w.walksN = cost, w.walksN + 1
    end
    return cost or nil
end

function Nav.Has(ci) return ns.GPSNavData ~= nil and ns.GPSNavData[ci] ~= nil end
Nav.Ensure = Nav.Has

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

-- Floor path inside tile t from a to b, pulled straight: world points
-- appended to out; acc gains the cell walk's yards (len) and time (time).
local function TilePath(w, t, a, b, out, acc)
    local _, prev = TileSearch(w, t, a, b)
    if a ~= b and not prev[b] then return false end
    local cells = {}
    local g = b
    while g do
        tinsert(cells, 1, g)
        if g == a then break end
        g = prev[g]
    end
    local N, cell = w.N, w.cell
    for k = 2, #cells do
        local c1, c2 = t.fcell[cells[k - 1]], t.fcell[cells[k]]
        local step = (mfloor(c1 / N) ~= mfloor(c2 / N) and c1 % N ~= c2 % N) and DIAG * cell or cell
        acc.len = acc.len + step
        acc.time = acc.time + step * (Swim(t, cells[k - 1]) + Swim(t, cells[k])) / 2
    end
    local i = 1
    local function emit(f)
        local x, y = FloorXY(w, t, f)
        if not (out[#out - 1] == x and out[#out] == y) then out[#out + 1], out[#out + 2] = x, y end
    end
    emit(cells[1])
    while i < #cells do
        local j = i + 1
        while j < #cells and Clear(w, t, cells[i], cells[j + 1]) do j = j + 1 end
        emit(cells[j])
        i = j
    end
    return true
end

-- The walk's points { x1, y1, x2, y2, ... } from a to b, its cost (the
-- yards it was chosen by) and its time in running yards, or nil.
function Nav.Path(ci, ax, ay, bx, by, opts)
    local w = World(ci)
    if not w then return nil end
    local cost, chain, ta, ga, tb, gb = Walk(w, ax, ay, bx, by, opts)
    if not cost then return nil end
    local ents = Entrances(w)
    local out = { ax, ay }
    local acc = { len = 0, time = 0 }
    local t, g = ta, ga
    local k = 1
    while chain and k <= #chain do
        local node = chain[k]
        local key = ents.key[node]
        if key ~= t.key then return nil end
        if not TilePath(w, t, g, ents.floor[node], out, acc) then return nil end
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
    if t.key ~= tb.key then return nil end
    t = Tile(w, tb.key)
    if not TilePath(w, t, g, gb, out, acc) then return nil end
    out[#out + 1], out[#out + 2] = bx, by
    local len = 0
    for v = 3, #out, 2 do len = len + msqrt((out[v] - out[v - 2]) ^ 2 + (out[v + 1] - out[v - 1]) ^ 2) end
    return out, cost, acc.len > 0 and len * acc.time / acc.len or len
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
