-- Named creatures as map rows: the packed catalog (ns.NPC_DATA) unpacked on
-- the first query long enough to reach it, matched on name and title, each
-- row on the creature's spot nearest the player.
local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns then return end

local MapSearch = ns.MapSearch
local Search = ns.MapSearchSearch
if not (MapSearch and Search and Search.PreparePOI) then return end

local sbyte, sfind, slower, sgmatch, ssub = string.byte, string.find, string.lower, string.gmatch, string.sub
local mfloor, mmin = math.floor, math.min
local tsort = table.sort
local band = bit.band
local PreparePOI = Search.PreparePOI

local MIN_QUERY = 3
local MAX_ROWS = 60     -- candidates handed to the map search's scoring
local GRID = 4096       -- a spot's x * GRID + y, each in 1/(GRID - 1) of the map
local DANGER_LEVELS = 3 -- the client's orange: three levels above
-- The catalog's role bits (dev/tools/npc_catalog.py ROLES), in the groups
-- the filter offers; a creature with none is "other".
local ROLE_GROUP = { quest = 1, vendor = 2 + 256, trainer = 4, flight = 8, services = 16 + 32 + 64 + 128 }

-- Everything unpacked, in one table: per creature (index i) its id, levels,
-- flags, title, display and search names, and its spots (index k).
local N = {
    n = nil,
    id = {}, lo = {}, span = {}, flags = {}, kind = {}, title = {}, first = {}, count = {},
    name = {}, low = {}, english = {}, lowEnglish = {},
    titleName = {}, titleLow = {}, titleEnglish = {}, titleLowEnglish = {},
    spotMap = {}, spotXY = {}, spotN = {}, spotCi = {}, spotWx = {}, spotWy = {},
    pois = setmetatable({}, { __mode = "v" }),
    hits = {}, score = {}, words = {}, retailEntrance = {},
    ROLE_GROUPS = { "quest", "vendor", "trainer", "flight", "services", "other" },
}
ns.GPSNpcs = N

local function Unpack(s)
    local E = C_EncodingUtil
    local method = Enum and Enum.CompressionMethod and Enum.CompressionMethod.Deflate or 0
    return E.DecompressString(E.DecodeBase64(s), method)
end

local function Reader(s)
    local pos = 1
    return function()
        local v, mul = 0, 1
        while true do
            local b = sbyte(s, pos)
            pos = pos + 1
            if b < 128 then return v + b * mul end
            v = v + (b - 128) * mul
            mul = mul * 128
        end
    end
end

local function Lines(blob, out)
    if not blob then return out end
    local ok, text = pcall(Unpack, blob)
    if not (ok and text) then return out end
    local i = 0
    for line in sgmatch(text .. "\n", "(.-)\n") do
        i = i + 1
        out[i] = line
    end
    return out
end

-- The name a locale shows: its own, else its base locale's, else English.
local function Pick(own, base, english, i)
    local v = own and own[i]
    if v and v ~= "" then return v end
    v = base and base[i]
    if v and v ~= "" then return v end
    return english[i]
end

local function Load()
    if N.n then return N.n > 0 end
    N.n = 0
    local data = ns.NPC_DATA
    if not (data and C_EncodingUtil and C_EncodingUtil.DecompressString) then return false end
    local ok, raw = pcall(Unpack, data.rows)
    if not (ok and raw) then return false end
    local u = Reader(raw)
    local count, last, k = u(), 0, 0
    for i = 1, count do
        last = last + u()
        N.id[i], N.lo[i], N.span[i], N.flags[i], N.kind[i], N.title[i] = last, u(), u(), u(), u(), u()
        local c = u()
        N.first[i], N.count[i] = k + 1, c
        for _ = 1, c do
            k = k + 1
            N.spotMap[k], N.spotXY[k], N.spotN[k] = u(), u(), u()
        end
    end
    local english, own, base = Lines(data.names, {}), Lines(data.localNames, {}), Lines(data.baseNames, {})
    for i = 1, count do
        local name = Pick(own, base, english, i) or "?"
        N.name[i] = name
        N.low[i] = slower(name)
        if english[i] and english[i] ~= name then
            N.english[i] = english[i]
            N.lowEnglish[i] = slower(english[i])
        end
    end
    local tEnglish, tOwn, tBase = Lines(data.titles, {}), Lines(data.localTitles, {}), Lines(data.baseTitles, {})
    for t = 1, #tEnglish do
        N.titleName[t] = Pick(tOwn, tBase, tEnglish, t)
        N.titleLow[t] = slower(N.titleName[t] or "")
        if tEnglish[t] ~= N.titleName[t] then
            N.titleEnglish[t] = tEnglish[t]
            N.titleLowEnglish[t] = slower(tEnglish[t])
        end
    end
    N.n = count
    return count > 0
end

-- Instance map id -> its entrance, from the instance list.
local entrances
local function Entrance(id)
    if not entrances then
        entrances = {}
        for _, e in ipairs(ns.FOREVER_INSTANCES or {}) do
            if not entrances[e.id] then entrances[e.id] = e end
        end
    end
    return entrances[id]
end

-- Retail: an instance's entrance, from its journal page and the map
-- search's entrance list (once that list is built).
local function RetailEntrance(mapID)
    local kept = N.retailEntrance[mapID]
    if kept ~= nil then return kept or nil end
    local EJ = C_EncounterJournal
    if not (EJ and EJ.GetInstanceForGameMap and EJ_GetInstanceInfo and MapSearch.HasGlobalInstanceCache
            and MapSearch:HasGlobalInstanceCache()) then
        return nil
    end
    N.retailEntrance[mapID] = false
    local jid = EJ.GetInstanceForGameMap(mapID)
    local name = jid and EJ_GetInstanceInfo(jid)
    if not name then return nil end
    for _, e in ipairs(MapSearch:GetGlobalInstanceCache() or {}) do
        if e.name == name and e.entranceMapID and e.x then
            local found = { m = e.entranceMapID, x = e.x, y = e.y, n = name }
            N.retailEntrance[mapID] = found
            return found
        end
    end
    return nil
end

-- A spot's zone map, x and y; an instance spot is its entrance.
local function SpotPoint(k)
    local m = N.spotMap[k]
    if m == 0 then
        local e
        if ns.Caps and ns.Caps.forever then e = Entrance(N.spotXY[k]) else e = RetailEntrance(N.spotXY[k]) end
        if e then return e.m, e.x, e.y, e end
        return nil
    end
    local xy = N.spotXY[k]
    return m, mfloor(xy / GRID) / (GRID - 1), (xy % GRID) / (GRID - 1)
end

local function SpotWorld(k)
    local ci = N.spotCi[k]
    if ci == nil then
        ci = false
        local m, x, y, e = SpotPoint(k)
        if e and e.ci then
            ci, N.spotWx[k], N.spotWy[k] = e.ci, e.wx, e.wy
        elseif m and C_Map.GetWorldPosFromMapPos and CreateVector2D then
            local ok, c, pos = pcall(C_Map.GetWorldPosFromMapPos, m, CreateVector2D(x, y))
            if ok and pos then ci, N.spotWx[k], N.spotWy[k] = c, pos:GetXY() end
        end
        N.spotCi[k] = ci
    end
    return ci, N.spotWx[k], N.spotWy[k]
end

local function StandsOn(i, m)
    for k = N.first[i], N.first[i] + N.count[i] - 1 do
        if N.spotMap[k] == m then return true end
    end
    return false
end

-- The spot to show: on onlyMap when given, else the nearest on the
-- player's continent, else the one with the most spawns.
local function BestSpot(i, onlyMap, pci, px, py)
    local best, bestD, most, mostN
    for k = N.first[i], N.first[i] + N.count[i] - 1 do
        local m = N.spotMap[k]
        if onlyMap then
            if m == onlyMap and (not most or N.spotN[k] > mostN) then most, mostN = k, N.spotN[k] end
        else
            if not most or N.spotN[k] > mostN then most, mostN = k, N.spotN[k] end
            if pci then
                local ci, wx, wy = SpotWorld(k)
                if ci == pci then
                    local d = (wx - px) ^ 2 + (wy - py) ^ 2
                    if not bestD or d < bestD then best, bestD = k, d end
                end
            end
        end
    end
    return best or most
end

local function PlayerWorld()
    local m = C_Map.GetBestMapForUnit("player")
    if not m then return nil end
    local ok, pos = pcall(C_Map.GetPlayerMapPosition, m, "player")
    if not (ok and pos) then return nil end
    local ok2, ci, wp = pcall(C_Map.GetWorldPosFromMapPos, m, pos)
    if not (ok2 and wp) then return nil end
    return ci, wp:GetXY()
end

local function MapName(m)
    local info = C_Map.GetMapInfo(m)
    return info and info.name
end

-- How well creature i matches the query words: 3 the name starts with
-- the first word, 2 a word of the name does, 1 anywhere; 0 no match.
local function Score(i)
    local words, low, alt = N.words, N.low[i], N.lowEnglish[i]
    local tlow, tAlt = N.titleLow[N.title[i]], N.titleLowEnglish[N.title[i]]
    local score = 0
    for w = 1, #words do
        local word = words[w]
        local at = sfind(low, word, 1, true) or (alt and sfind(alt, word, 1, true))
        if not at and not (tlow and sfind(tlow, word, 1, true)) and not (tAlt and sfind(tAlt, word, 1, true)) then
            return 0
        end
        if w == 1 then
            if at == 1 then score = 3
            elseif at and ssub(low, at - 1, at - 1) == " " then score = 2
            else score = 1 end
        end
    end
    return score
end

local function HitLess(a, b)
    local sa, sb = N.score[a], N.score[b]
    if sa ~= sb then return sa > sb end
    return #N.name[a] < #N.name[b]
end

local function Row(i, k)
    local m, x, y, e = SpotPoint(k)
    if not m then return nil end
    local poi = N.pois[i]
    if not poi then
        -- Keywords: the title, and the English name and title on other
        -- clients, which the map search's own scoring reads.
        local keywords = {}
        local t = N.title[i]
        if N.titleName[t] and N.titleName[t] ~= "" then keywords[#keywords + 1] = N.titleName[t] end
        if N.english[i] then keywords[#keywords + 1] = N.english[i] end
        if N.titleEnglish[t] then keywords[#keywords + 1] = N.titleEnglish[t] end
        poi = { name = N.name[i], category = "npc", isStatic = true, npcID = N.id[i],
                keywords = #keywords > 0 and keywords or nil }
        PreparePOI(poi)
        N.pois[i] = poi
    end
    poi.mapID, poi.coordMapID, poi.x, poi.y = m, m, x, y
    poi.zoneName = e and e.n or MapName(m)
    poi.score, poi.duplicateKey, poi.allInstances = nil, nil, nil
    return poi
end

-- Whether creature i passes the NPC filters (EasyFind.db.npcFilters):
-- per facet a table where false leaves that value out, missing keeps it.
-- type[id], expansion[id] (-1: unknown), role[group], reaction[0 friendly,
-- 1 neutral, 2 hostile] to the player's faction.
local function Passes(i, f, horde)
    local kind = N.kind[i]
    if f.type and f.type[kind % 16] == false then return false end
    if f.expansion and f.expansion[mfloor(kind / 16) % 16 - 1] == false then return false end
    local roleF = f.role
    if roleF then
        local roles = mfloor(kind / 256)
        if roles == 0 then
            if roleF.other == false then return false end
        else
            local any = false
            for group, bits in pairs(ROLE_GROUP) do
                if roleF[group] ~= false and band(roles, bits) ~= 0 then
                    any = true
                    break
                end
            end
            if not any then return false end
        end
    end
    if f.reaction and f.reaction[mfloor(N.flags[i] / (horde and 32 or 8)) % 4] == false then return false end
    return true
end

-- Appends the creatures matching query to out (map POIs); onlyMap keeps
-- those standing on that map. True when more matched than were handed over.
function N.Append(out, nameSet, query, onlyMap)
    if not query or #query < MIN_QUERY or not Load() then return false end
    local words = N.words
    for w = #words, 1, -1 do words[w] = nil end
    for word in sgmatch(slower(query), "%S+") do words[#words + 1] = word end
    if #words == 0 then return false end
    local hits, score, n = N.hits, N.score, 0
    local f = EasyFind.db and EasyFind.db.npcFilters
    local horde = f and f.reaction and UnitFactionGroup and UnitFactionGroup("player") == "Horde"
    for i = 1, N.n do
        local s = Score(i)
        if s > 0 and onlyMap and not StandsOn(i, onlyMap) then s = 0 end
        if s > 0 and f and not Passes(i, f, horde) then s = 0 end
        if s > 0 then
            n = n + 1
            hits[n] = i
            score[i] = s
        end
    end
    for j = #hits, n + 1, -1 do hits[j] = nil end
    if n == 0 then return false end
    tsort(hits, HitLess)
    local pci, px, py
    if not onlyMap then pci, px, py = PlayerWorld() end
    for j = 1, mmin(n, MAX_ROWS) do
        local i = hits[j]
        local k = BestSpot(i, onlyMap, pci, px, py)
        local poi = k and Row(i, k)
        if poi and not (nameSet and nameSet[poi.nameLower]) then out[#out + 1] = poi end
    end
    return n > MAX_ROWS
end

-- What the filter menu offers: the creature types by id with the client's
-- names, and the expansions this catalog holds (-1: unknown), in order.
function N.FilterChoices()
    if not Load() then return nil end
    local present, types, expansions = {}, {}, {}
    for i = 1, N.n do
        present[N.kind[i] % 16] = true
        expansions[mfloor(N.kind[i] / 16) % 16 - 1] = true
    end
    local names = ns.NPC_DATA.types or {}
    for id in pairs(present) do
        if names[id] then types[#types + 1] = { id = id, name = names[id] } end
    end
    tsort(types, function(a, b) return a.name < b.name end)
    local list = {}
    for e in pairs(expansions) do list[#list + 1] = e end
    tsort(list, function(a, b) return (a < 0 and 99 or a) < (b < 0 and 99 or b) end)
    return { types = types, expansions = list }
end

-- The walking tiles a character of this level and faction goes around:
-- those whose hostile creatures con orange or red to it (DANGER_LEVELS
-- or more above). { [continent] = { [tile] = true } }, or nil.
function N.DangerTiles(level, faction)
    local data = ns.NPC_DATA
    if not (data and data.danger and level) then return nil end
    local key = level .. (faction or "")
    if N.dangerKey == key then return N.dangerSet end
    local horde = faction == "Horde"
    local set = {}
    for ci, blob in pairs(data.danger) do
        local ok, raw = pcall(Unpack, blob)
        if ok and raw then
            local u = Reader(raw)
            local tiles, last = {}, 0
            for _ = 1, u() do
                last = last + u()
                local alliance, hordeLevel = u(), u()
                if (horde and hordeLevel or alliance) >= level + DANGER_LEVELS then tiles[last] = true end
            end
            set[ci] = tiles
        end
    end
    N.dangerKey, N.dangerSet = key, set
    return set
end

MapSearch.AppendNpcRows = N.Append
MapSearch.WarmNpcRows = Load
