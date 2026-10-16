-- Named creatures as map rows: the packed catalog (ns.NPC_DATA) unpacked on
-- the first query long enough to reach it, matched on name, title, service
-- or what a vendor sells, each row on the creature's spot nearest the player.
local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns then return end

local MapSearch = ns.MapSearch
local Search = ns.MapSearchSearch
if not (MapSearch and Search and Search.PreparePOI) then return end

local sbyte, sfind, slower, sgmatch, ssub = string.byte, string.find, string.lower, string.gmatch, string.sub
local sformat = string.format
local mfloor, mmin = math.floor, math.min
local tsort = table.sort
local band, bor = bit.band, bit.bor
local PreparePOI = Search.PreparePOI

local MIN_QUERY = 3
local MAX_ROWS = 60     -- candidates handed to the map search's scoring
local GRID = 4096       -- a spot's x * GRID + y, each in 1/(GRID - 1) of the map
local DANGER_LEVELS = 3 -- the client's orange: three levels above
-- The catalog's role bits (dev/tools/npc_catalog.py ROLES), in the groups
-- the filter offers; a creature with none is "other".
local ROLE_GROUP = { quest = 1, vendor = 2 + 256, trainer = 4, flight = 8, services = 16 + 32 + 64 + 128 }
-- Words for what a creature offers, matched as if in its title: English on
-- every client, the client's own beside them. Food, ammo and reagents are
-- what a vendor sells.
local SERVICES = {
    { bits = 2, en = "vendor merchant", key = "NPC_WORDS_VENDOR" },
    { bits = 256, en = "repair", key = "NPC_WORDS_REPAIR" },
    { bits = 512, en = "food drink water", key = "NPC_WORDS_FOOD" },
    { bits = 1024, en = "ammo arrows bullets restock", key = "NPC_WORDS_AMMO" },
    { bits = 2048, en = "reagents restock", key = "NPC_WORDS_REAGENTS" },
    { bits = 8, en = "flight", key = "NPC_WORDS_FLIGHT" },
}
local FAR = math.huge

-- Everything unpacked, in one table: per creature (index i) its id, levels,
-- flags, title, display and search names, and its spots (index k).
local N = {
    n = nil,
    id = {}, lo = {}, span = {}, flags = {}, kind = {}, display = {}, title = {}, first = {}, count = {},
    name = {}, low = {}, english = {}, lowEnglish = {},
    titleName = {}, titleLow = {}, titleEnglish = {}, titleLowEnglish = {},
    spotMap = {}, spotXY = {}, spotN = {}, spotCi = {}, spotWx = {}, spotWy = {},
    pois = setmetatable({}, { __mode = "v" }),
    hits = {}, score = {}, words = {}, wordBits = {}, spot = {}, near = {}, retailEntrance = {},
    -- What vendors sell: per item (index j) its id and names, per stock list
    -- (index l) its items, per creature the list it sells (sells[i]).
    goodsN = nil, goodsId = {}, goodsName = {}, goodsLow = {}, goodsLowEnglish = {},
    listsOf = {}, sells = {}, listHit = {}, itemScore = {}, matched = {}, sold = {},
    ROLE_GROUPS = { "quest", "vendor", "trainer", "flight", "services", "other" },
}
ns.GPSNpcs = N

-- A creature by its name in any case, for rows saved before they kept
-- the proper name and portrait: { name, npcID, displayID } or nil.
-- Filled on the first ask from the unpacked catalog.
local byName
function N.ByName(name)
    if not name or name == "" then return nil end
    if not byName then
        if not (N.Load and N.Load()) then return nil end
        byName = {}
        for i = 1, N.n do
            local low = N.low[i]
            if low and not byName[low] then byName[low] = i end
        end
    end
    local i = byName[string.lower(name)]
    if not i then return nil end
    return { name = N.name[i], npcID = N.id[i], displayID = N.display[i] ~= 0 and N.display[i] or nil }
end

-- Every service word with its bits, from SERVICES and the locale.
local serviceWords
local function ServiceWords()
    if serviceWords then return serviceWords end
    serviceWords = {}
    for _, s in ipairs(SERVICES) do
        local seen = {}
        for w in sgmatch(slower(s.en .. " " .. (ns.L[s.key] or "")), "%S+") do
            if not seen[w] then
                seen[w] = true
                serviceWords[#serviceWords + 1] = { word = w, bits = s.bits }
            end
        end
    end
    return serviceWords
end

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
        N.id[i], N.lo[i], N.span[i], N.flags[i], N.kind[i], N.display[i], N.title[i] = last, u(), u(), u(), u(), u(), u()
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

N.Load = Load

-- The goods blob (dev/tools/npc_catalog.py): items, the lists that share
-- them, and which creature (by row index) sells which list.
local function LoadGoods()
    if N.goodsN then return N.goodsN > 0 end
    N.goodsN = 0
    local data = ns.NPC_DATA
    if not (data and data.goods and Load()) then return false end
    local ok, raw = pcall(Unpack, data.goods)
    if not (ok and raw) then return false end
    local u = Reader(raw)
    local count, last = u(), 0
    for j = 1, count do
        last = last + u()
        N.goodsId[j] = last
        N.listsOf[j] = {}
    end
    for l = 1, u() do
        local at = 0
        for _ = 1, u() do
            at = at + u()
            local lists = N.listsOf[at + 1]
            lists[#lists + 1] = l
        end
    end
    local row = 0
    for _ = 1, u() do
        row = row + u()
        N.sells[row + 1] = u() + 1
    end
    local english, own, base = Lines(data.goodsNames, {}), Lines(data.localGoods, {}), Lines(data.baseGoods, {})
    for j = 1, count do
        local name = Pick(own, base, english, j) or "?"
        N.goodsName[j] = name
        N.goodsLow[j] = slower(name)
        if english[j] and english[j] ~= name then N.goodsLowEnglish[j] = slower(english[j]) end
    end
    N.goodsN = count
    return count > 0
end
N.LoadGoods = LoadGoods

-- Every word of the query in the item's name (either language): 3 when the
-- name starts with the first, 2 when a word in it does, else 1; 0 when not.
local function ItemScore(j)
    local words, low, alt = N.words, N.goodsLow[j], N.goodsLowEnglish[j]
    local score = 0
    for w = 1, #words do
        local word = words[w]
        local at = sfind(low, word, 1, true)
        local altAt = alt and sfind(alt, word, 1, true)
        if not (at or altAt) then return 0 end
        if w == 1 then
            local s, pos = at and low or alt, at or altAt
            if pos == 1 then score = 3
            elseif ssub(s, pos - 1, pos - 1) == " " then score = 2
            else score = 1 end
        end
    end
    return score
end

-- Marks each stock list holding an item the query names with its best such
-- item (listHit[l] = j). False when no item matched.
local function MatchGoods()
    local listHit, itemScore, matched = N.listHit, N.itemScore, N.matched
    for m = #matched, 1, -1 do
        for _, l in ipairs(N.listsOf[matched[m]]) do listHit[l] = nil end
        itemScore[matched[m]] = nil
        matched[m] = nil
    end
    if not LoadGoods() then return false end
    for j = 1, N.goodsN do
        local s = ItemScore(j)
        if s > 0 then
            itemScore[j] = s
            matched[#matched + 1] = j
            for _, l in ipairs(N.listsOf[j]) do
                local best = listHit[l]
                if not best or s > itemScore[best] or (s == itemScore[best] and #N.goodsLow[j] < #N.goodsLow[best]) then
                    listHit[l] = j
                end
            end
        end
    end
    return #matched > 0
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
-- the first word, 2 a word of the name does, 1 anywhere or by what it
-- offers; 0 no match.
local function Score(i)
    local words, low, alt = N.words, N.low[i], N.lowEnglish[i]
    local tlow, tAlt = N.titleLow[N.title[i]], N.titleLowEnglish[N.title[i]]
    local score = 0
    for w = 1, #words do
        local word = words[w]
        local at = sfind(low, word, 1, true) or (alt and sfind(alt, word, 1, true))
        if not at and not (tlow and sfind(tlow, word, 1, true)) and not (tAlt and sfind(tAlt, word, 1, true))
            and band(mfloor(N.kind[i] / 256), N.wordBits[w]) == 0 then
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

-- Equal matches nearest first.
local function HitLess(a, b)
    local sa, sb = N.score[a], N.score[b]
    if sa ~= sb then return sa > sb end
    local na, nb = N.near[a], N.near[b]
    if na ~= nb then return na < nb end
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
        local roles = mfloor(N.kind[i] / 256)
        for _, s in ipairs(ServiceWords()) do
            if band(roles, s.bits) ~= 0 then keywords[#keywords + 1] = s.word end
        end
        poi = { name = N.name[i], category = "npc", isStatic = true, npcID = N.id[i],
                displayID = N.display[i] ~= 0 and N.display[i] or nil,
                keywords = #keywords > 0 and keywords or nil }
        poi.baseKeywords = poi.keywords
        PreparePOI(poi)
        N.pois[i] = poi
    end
    -- Found by what it sells: the item rides along as a keyword so the map
    -- search's own scoring keeps the row, and as the row's note.
    local j = N.sold[i] or nil
    if poi.soldItem ~= j then
        poi.soldItem = j
        local keywords = poi.baseKeywords
        if j then
            keywords = { N.goodsName[j] }
            if N.goodsLowEnglish[j] then keywords[2] = N.goodsLowEnglish[j] end
            for w = 1, #(poi.baseKeywords or {}) do keywords[#keywords + 1] = poi.baseKeywords[w] end
        end
        poi.keywords, poi.kwLower, poi.searchMask = keywords, nil, nil
        poi.matchNote = j and sformat(ns.L["NPC_SELLS"] or "Sells %s", N.goodsName[j]) or nil
        PreparePOI(poi)
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
    local words, wordBits = N.words, N.wordBits
    for w = #words, 1, -1 do words[w] = nil end
    for word in sgmatch(slower(query), "%S+") do words[#words + 1] = word end
    if #words == 0 then return false end
    -- A word naming a service: only creatures that will serve the player.
    local service = false
    for w = 1, #words do
        local bits = 0
        if #words[w] >= MIN_QUERY then
            for _, s in ipairs(ServiceWords()) do
                if sfind(s.word, words[w], 1, true) == 1 then bits = bor(bits, s.bits) end
            end
        end
        wordBits[w] = bits
        if bits ~= 0 then service = true end
    end
    local hits, score, n = N.hits, N.score, 0
    local f = EasyFind.db and EasyFind.db.npcFilters
    local horde = UnitFactionGroup and UnitFactionGroup("player") == "Horde"
    local goods = MatchGoods()
    local listHit, sells, sold = N.listHit, N.sells, N.sold
    for i = 1, N.n do
        local s = Score(i)
        local j = false
        if s == 0 and goods and sells[i] then
            j = listHit[sells[i]] or false
            if j then s = N.itemScore[j] end
        end
        if s > 0 and onlyMap and not StandsOn(i, onlyMap) then s = 0 end
        if s > 0 and f and not Passes(i, f, horde) then s = 0 end
        if s > 0 and (service or j) and mfloor(N.flags[i] / (horde and 32 or 8)) % 4 == 2 then s = 0 end
        if s > 0 then
            n = n + 1
            hits[n] = i
            score[i] = s
            sold[i] = j
        end
    end
    for j = #hits, n + 1, -1 do hits[j] = nil end
    if n == 0 then return false end
    -- Past the cap, the nearest of equal matches get in.
    local pci, px, py = PlayerWorld()
    local spot, near = N.spot, N.near
    local capped = n > MAX_ROWS
    for j = 1, n do
        local i = hits[j]
        local k = capped and BestSpot(i, onlyMap, pci, px, py) or nil
        spot[i], near[i] = k, FAR
        if k and pci then
            local ci, wx, wy = SpotWorld(k)
            if ci == pci then near[i] = (wx - px) ^ 2 + (wy - py) ^ 2 end
        end
    end
    tsort(hits, HitLess)
    for j = 1, mmin(n, MAX_ROWS) do
        local i = hits[j]
        local k = spot[i] or BestSpot(i, onlyMap, pci, px, py)
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
