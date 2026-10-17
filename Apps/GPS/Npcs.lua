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
local tsort, tconcat = table.sort, table.concat
local band, bor, lshift = bit.band, bit.bor, bit.lshift
local ZONE_ABBREVIATIONS = ns.MapUtils and ns.MapUtils.ZONE_ABBREVIATIONS or {}
local PreparePOI = Search.PreparePOI
local SliceCheckpoint = ns.Utils and ns.Utils.SliceCheckpoint or function() end

local MIN_QUERY = 3
local MAX_ROWS = 60     -- candidates handed to the map search's scoring
local TOWN_RADIUS2 = 300 ^ 2   -- a town's spots: within this of its inn, in yards squared
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
    { bits = 16, en = "inn innkeeper", key = "NPC_WORDS_INN" },
    { bits = 32, en = "bank banker", key = "NPC_WORDS_BANK" },
    { bits = 64, en = "auction auctioneer", key = "NPC_WORDS_AUCTION" },
    { bits = 128, en = "stable", key = "NPC_WORDS_STABLE" },
    { bits = 4096, en = "class trainer", key = "NPC_WORDS_CLASS_TRAINER" },
}
-- A trainer titled with a class's name (Hunter Trainer): no catalog role,
-- worked out from the title as the catalog loads.
local CLASS_TRAINER = 4096
local CLASS_NAMES_EN = { "warrior", "paladin", "hunter", "rogue", "priest", "shaman", "mage", "warlock", "druid",
                         "death knight", "monk", "demon hunter", "evoker" }
local FAR = math.huge

-- Everything unpacked, in one table: per creature (index i) its id, levels,
-- flags, title and display, and its spots (index k). Names stay one text
-- (names) and one lowercase text (low), a line per creature starting at
-- at[i]; the English texts beside them on other clients (enNames, enLow,
-- enAt), nil where the client's names are English.
local N = {
    n = nil,
    id = {}, lo = {}, span = {}, flags = {}, kind = {}, display = {}, title = {}, first = {}, count = {},
    names = "", low = "", at = {}, enNames = nil, enLow = nil, enAt = nil,
    titleName = {}, titleLow = {}, titleEnglish = {}, titleLowEnglish = {},
    spotMap = {}, spotXY = {}, spotN = {}, spotCi = {}, spotWx = {}, spotWy = {},
    pois = setmetatable({}, { __mode = "v" }),
    hits = {}, score = {}, words = {}, wordBits = {}, spot = {}, near = {}, retailEntrance = {},
    mark = {}, cand = {}, titleHit = {}, gen = 0,
    -- Per query word whether it names a service or title (wordRole) or a
    -- place (wordPlace); the places named and the maps of the chosen ones.
    wordRole = {}, wordPlace = {}, placeHit = {}, placeWordsOf = {}, placeList = {}, placeWords = {}, mapSet = {},
    -- What vendors sell: per item (index j) its id and names, per stock list
    -- (index l) its items, per creature the list it sells (sells[i]).
    goodsN = nil, goodsId = {}, goodsName = {}, goodsLow = {}, goodsLowEnglish = {},
    listsOf = {}, sells = {}, listHit = {}, itemScore = {}, matched = {}, sold = {},
    ROLE_GROUPS = { "quest", "vendor", "trainer", "flight", "services", "other" },
}
ns.GPSNpcs = N

-- The creature whose line holds byte position p of a names text.
local function LineAt(at, n, p)
    local lo, hi = 1, n
    while lo < hi do
        local mid = mfloor((lo + hi + 1) / 2)
        if at[mid] <= p then lo = mid else hi = mid - 1 end
    end
    return lo
end

-- Creature i's name, from the text.
local function Name(i)
    return ssub(N.names, N.at[i], N.at[i + 1] - 2)
end

-- Creature i's English name when the client shows another, else nil.
local function EnglishName(i)
    if not N.enNames then return nil end
    local en = ssub(N.enNames, N.enAt[i], N.enAt[i + 1] - 2)
    if en == "" or en == Name(i) then return nil end
    return en
end
N.Name = Name

-- A creature by its name in any case, for rows saved before they kept
-- the proper name and portrait: { name, npcID, displayID } or nil.
function N.ByName(name)
    if not name or name == "" then return nil end
    if not (N.Load and N.Load()) then return nil end
    local p = sfind(N.low, "\n" .. string.lower(name) .. "\n", 1, true)
    if not p then return nil end
    local i = LineAt(N.at, N.n, p + 1)
    return { name = Name(i), npcID = N.id[i], displayID = N.display[i] ~= 0 and N.display[i] or nil }
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

-- A names text as one string, a line per creature between newlines, and
-- the line starts: at[i] for creature i, at[count + 1] past the last.
local function Text(text, count)
    text = (text or ""):gsub("\n$", "")
    local blob = "\n" .. text .. "\n"
    local at, pos = {}, 2
    for i = 1, count do
        at[i] = pos
        local nl = sfind(blob, "\n", pos, true)
        if not nl then
            blob = blob .. "\n"
            nl = #blob
        end
        pos = nl + 1
    end
    at[count + 1] = pos
    return blob, at
end

-- The client's names: its own where it has one, else its base locale's,
-- else English, merged line by line (English clients skip the merge).
local function MergedNames(data, count, key, localKey, baseKey)
    local english = data[key]
    if not english then return "" end
    local ok, text = pcall(Unpack, english)
    if not (ok and text) then return "" end
    if not (data[localKey] or data[baseKey]) then return text end
    local en, own, base = Lines(english, {}), Lines(data[localKey], {}), Lines(data[baseKey], {})
    local out = {}
    for i = 1, count do out[i] = Pick(own, base, en, i) or "?" end
    return table.concat(out, "\n")
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
    N.names, N.at = Text(MergedNames(data, count, "names", "localNames", "baseNames"), count)
    N.low = slower(N.names)
    if data.localNames or data.baseNames then
        local okEn, en = pcall(Unpack, data.names)
        N.enNames, N.enAt = Text(okEn and en or "", count)
        N.enLow = slower(N.enNames)
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
    -- Class trainers: their title names a class, in English or the client's.
    local classNames = {}
    for _, n in ipairs(CLASS_NAMES_EN) do classNames[#classNames + 1] = n end
    for _, names in ipairs({ LOCALIZED_CLASS_NAMES_MALE or {}, LOCALIZED_CLASS_NAMES_FEMALE or {} }) do
        for _, n in pairs(names) do
            if type(n) == "string" then classNames[#classNames + 1] = slower(n) end
        end
    end
    local classTitle = {}
    for t = 1, #tEnglish do
        for _, n in ipairs(classNames) do
            if sfind(N.titleLow[t] or "", n, 1, true) or (N.titleLowEnglish[t] and sfind(N.titleLowEnglish[t], n, 1, true)) then
                classTitle[t] = true
                break
            end
        end
    end
    for i = 1, count do
        local roles = mfloor(N.kind[i] / 256)
        if classTitle[N.title[i]] and band(roles, 4) ~= 0 and band(roles, CLASS_TRAINER) == 0 then
            N.kind[i] = N.kind[i] + CLASS_TRAINER * 256
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
    local words, wordPlace, low, alt = N.words, N.wordPlace, N.goodsLow[j], N.goodsLowEnglish[j]
    local score, first = 0, true
    for w = 1, #words do
        if not wordPlace[w] then
            local word = words[w]
            local at = sfind(low, word, 1, true)
            local altAt = alt and sfind(alt, word, 1, true)
            if not (at or altAt) then return 0 end
            if first then
                first = false
                local s, pos = at and low or alt, at or altAt
                if pos == 1 then score = 3
                elseif ssub(s, pos - 1, pos - 1) == " " then score = 2
                else score = 1 end
            end
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

-- Whether creature i has a spot on the set's maps, within r2 of the
-- point (continent pci, px, py) when given.
local function Within(i, set, pci, px, py, r2)
    for k = N.first[i], N.first[i] + N.count[i] - 1 do
        if not set or set[N.spotMap[k]] then
            if not r2 then return true end
            local ci, wx, wy = SpotWorld(k)
            if ci == pci and (wx - px) ^ 2 + (wy - py) ^ 2 <= r2 then return true end
        end
    end
    return false
end

-- The spot to show: of those on the set's maps (within r2 of the point
-- when given), the nearest to the point, else the one with the most spawns.
local function BestSpot(i, set, pci, px, py, r2)
    local best, bestD, most, mostN
    for k = N.first[i], N.first[i] + N.count[i] - 1 do
        if not set or set[N.spotMap[k]] then
            local d
            if pci then
                local ci, wx, wy = SpotWorld(k)
                if ci == pci then d = (wx - px) ^ 2 + (wy - py) ^ 2 end
            end
            if not r2 or (d and d <= r2) then
                if d and (not bestD or d < bestD) then best, bestD = k, d end
                if not most or N.spotN[k] > mostN then most, mostN = k, N.spotN[k] end
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

-- Where word sits in creature i's line of a names text, or nil.
local function WordIn(blob, at, i, word)
    local p = sfind(blob, word, at[i], true)
    if p and p <= at[i + 1] - 2 then return p end
    return nil
end

-- How well creature i matches the query words: 3 the name starts with
-- the first word, 2 a word of the name does, 1 anywhere or by what it
-- offers; 0 no match.
local function Score(i)
    local words, wordPlace, low, at, enLow, enAt = N.words, N.wordPlace, N.low, N.at, N.enLow, N.enAt
    local tlow, tAlt = N.titleLow[N.title[i]], N.titleLowEnglish[N.title[i]]
    local score, first = 0, true
    for w = 1, #words do
        if not wordPlace[w] then
            local word = words[w]
            local p, blob, start = WordIn(low, at, i, word), low, at[i]
            if not p and enLow then p, blob, start = WordIn(enLow, enAt, i, word), enLow, enAt[i] end
            if not p and not (tlow and sfind(tlow, word, 1, true)) and not (tAlt and sfind(tAlt, word, 1, true))
                and band(mfloor(N.kind[i] / 256), N.wordBits[w]) == 0 then
                return 0
            end
            if first then
                first = false
                if p == start then score = 3
                elseif p and sbyte(blob, p - 1) == 32 then score = 2
                else score = 1 end
            end
        end
    end
    return score
end

-- Equal matches nearest first, then the shorter name.
local function HitLess(a, b)
    local sa, sb = N.score[a], N.score[b]
    if sa ~= sb then return sa > sb end
    local na, nb = N.near[a], N.near[b]
    if na ~= nb then return na < nb end
    local at = N.at
    return (at[a + 1] - at[a]) < (at[b + 1] - at[b])
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
        local english = EnglishName(i)
        if english then keywords[#keywords + 1] = english end
        if N.titleEnglish[t] then keywords[#keywords + 1] = N.titleEnglish[t] end
        local roles = mfloor(N.kind[i] / 256)
        for _, s in ipairs(ServiceWords()) do
            if band(roles, s.bits) ~= 0 then keywords[#keywords + 1] = s.word end
        end
        poi = { name = Name(i), category = "npc", isStatic = true, npcID = N.id[i],
                displayID = N.display[i] ~= 0 and N.display[i] or nil,
                keywords = #keywords > 0 and keywords or nil }
        poi.baseKeywords = poi.keywords
        PreparePOI(poi)
        N.pois[i] = poi
    end
    -- Found by what it sells or where: the item and the place words typed
    -- ride along as keywords so the map search's own scoring keeps the
    -- row; the item is the row's note too.
    local j = N.sold[i] or nil
    local placeKey = N.placeKey
    if poi.soldItem ~= j or poi.placeKey ~= placeKey then
        poi.soldItem, poi.placeKey = j, placeKey
        local keywords = poi.baseKeywords
        if j or placeKey then
            keywords = {}
            if j then
                keywords[1] = N.goodsName[j]
                if N.goodsLowEnglish[j] then keywords[2] = N.goodsLowEnglish[j] end
            end
            if placeKey then
                for w = 1, #N.words do
                    if N.wordPlace[w] then keywords[#keywords + 1] = N.words[w] end
                end
            end
            for w = 1, #(poi.baseKeywords or {}) do keywords[#keywords + 1] = poi.baseKeywords[w] end
        end
        poi.keywords, poi.kwLower, poi.searchMask = keywords, nil, nil
        poi.matchNote = j and sformat(ns.L["NPC_SELLS"] or "Sells %s", N.goodsName[j]) or nil
        poi.soldName = j and N.goodsName[j] or nil
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

-- Marks creature i a candidate once per query.
local function Mark(i)
    if N.mark[i] ~= N.gen then
        N.mark[i] = N.gen
        local cand = N.cand
        cand[#cand + 1] = i
    end
end

-- Every creature whose name holds word, by one find per line that does.
local function MarkLines(blob, at, n, word)
    local p = sfind(blob, word, 1, true)
    while p do
        local i = LineAt(at, n, p)
        Mark(i)
        p = sfind(blob, word, at[i + 1], true)
    end
end

-- Whether a word of low starts with word (hill in razor hill).
local function WordStarts(low, word)
    local p = sfind(low, word, 1, true)
    while p do
        if p == 1 or sbyte(low, p - 1) == 32 then return true end
        p = sfind(low, word, p + 1, true)
    end
    return false
end

-- Whether a title's word starts with word, in either language.
local function TitleWord(word)
    local titleLow, titleLowEnglish = N.titleLow, N.titleLowEnglish
    for t = 1, #titleLow do
        if WordStarts(titleLow[t], word) or (titleLowEnglish[t] and WordStarts(titleLowEnglish[t], word)) then
            return true
        end
    end
    return false
end

-- Forever's towns (ns.GPSData.binds: each inn by area id), as places a
-- word can name; retail has none here.
local towns
local function Towns()
    if towns then return towns end
    towns = {}
    local binds = ns.GPSData and ns.GPSData.binds
    if not (binds and C_Map.GetAreaInfo) then return towns end
    for area, p in pairs(binds) do
        local ok, name = pcall(C_Map.GetAreaInfo, area)
        if ok and name and p.ci then
            towns[#towns + 1] = { town = true, low = slower(name), ci = p.ci, wx = p.wx, wy = p.wy }
        end
    end
    return towns
end

-- Map m and every map inside it (a zone's cities) into set.
local descendants = {}
local function AddMaps(set, m)
    set[m] = true
    local kids = descendants[m]
    if not kids then
        kids = {}
        local ok, list = pcall(C_Map.GetMapChildrenInfo, m, nil, true)
        for _, c in ipairs(ok and list or {}) do kids[#kids + 1] = c.mapID end
        descendants[m] = kids
    end
    for _, c in ipairs(kids) do set[c] = true end
end

local function Named(place, w)
    local hit, wordsOf = N.placeHit, N.placeWordsOf
    if not hit[place] then
        N.placeList[#N.placeList + 1] = place
        hit[place], wordsOf[place] = 0, 0
    end
    hit[place], wordsOf[place] = hit[place] + 1, bor(wordsOf[place], lshift(1, w - 1))
end

-- The place the words beside the service and title words name (org
-- repair, inn barrens, razor hill inn): the one named by the most words,
-- a town over a zone. N.wordPlace marks the words taken; the zones' maps
-- fill N.mapSet, a town comes back. Nothing when every word named one.
local function Places()
    local words, wordRole, wordPlace = N.words, N.wordRole, N.wordPlace
    local hit, wordsOf, list, mapSet = N.placeHit, N.placeWordsOf, N.placeList, N.mapSet
    wipe(hit)
    wipe(wordsOf)
    wipe(mapSet)
    for p = #list, 1, -1 do list[p] = nil end
    local placeWords = 0
    for w = 1, #words do
        local word = words[w]
        if not wordRole[w] then
            local named = false
            local prefix = #word >= 4
            for _, t in ipairs(Towns()) do
                if t.low == word or (prefix and WordStarts(t.low, word)) then
                    Named(t, w)
                    named = true
                end
            end
            local zones = MapSearch.ZonesNamed and MapSearch:ZonesNamed(word)
            for z = 1, zones and #zones or 0 do
                Named(zones[z], w)
                named = true
            end
            if named then placeWords = placeWords + 1 end
        end
    end
    if placeWords == 0 or placeWords == #words then return nil end
    local most = 0
    for p = 1, #list do
        if hit[list[p]] > most then most = hit[list[p]] end
    end
    local town, mask
    for p = 1, #list do
        local place = list[p]
        if hit[place] == most and place.town then
            town = place
            break
        end
    end
    if town then
        mask = wordsOf[town]
    else
        mask = 0
        for p = 1, #list do
            local place = list[p]
            if hit[place] == most then
                AddMaps(mapSet, place.mapID)
                mask = bor(mask, wordsOf[place])
                -- A short first word of the zone's name typed too (the barrens).
                for w = 1, #words do
                    if not wordRole[w] and #words[w] <= 3 and sfind(place.nameLower or "", words[w] .. " ", 1, true) == 1 then
                        mask = bor(mask, lshift(1, w - 1))
                    end
                end
            end
        end
    end
    for w = 1, #words do wordPlace[w] = band(mask, lshift(1, w - 1)) ~= 0 or nil end
    return town, true
end

-- Scores the candidates, keeping those within the set's maps or r2 of the
-- point, passing the filters and serving the player: hits, in no order.
local function Keep(set, pci, px, py, r2, goods, f, horde, service)
    local cand, hits, score = N.cand, N.hits, N.score
    local listHit, sells, sold = N.listHit, N.sells, N.sold
    local n = 0
    for c = 1, #cand do
        local i = cand[c]
        local s = Score(i)
        -- What it sells that the query names: its match when nothing else
        -- matched, else a note beside its name only when a word of the item
        -- starts with the query (Bowen's bows, not an elbow guard).
        local j = goods and sells[i] and listHit[sells[i]] or false
        local byItem = false
        if s == 0 and j then
            s, byItem = N.itemScore[j], true
        elseif j and N.itemScore[j] < 2 then
            j = false
        end
        if s > 0 and (set or r2) and not Within(i, set, pci, px, py, r2) then s = 0 end
        if s > 0 and f and not Passes(i, f, horde) then s = 0 end
        if s > 0 and (service or byItem) and mfloor(N.flags[i] / (horde and 32 or 8)) % 4 == 2 then s = 0 end
        if s > 0 then
            n = n + 1
            hits[n] = i
            score[i] = s
            sold[i] = j
        end
        if c % 256 == 0 then SliceCheckpoint() end
    end
    for j = #hits, n + 1, -1 do hits[j] = nil end
    return n
end

-- Appends the creatures matching query to out (map POIs). onlyMap keeps
-- those standing on that map; nearMap (the player's) does so for a query
-- of services alone (repair, inn), everywhere when that map has none. A
-- zone or town typed beside the services narrows to it (org repair,
-- auberdine inn). True when more matched than were handed over.
function N.Append(out, nameSet, query, onlyMap, nearMap)
    if not query or #query < MIN_QUERY or not Load() then return false end
    local words, wordBits, wordRole, wordPlace = N.words, N.wordBits, N.wordRole, N.wordPlace
    for w = #words, 1, -1 do words[w], wordRole[w], wordPlace[w] = nil, nil, nil end
    for word in sgmatch(slower(query), "%S+") do words[#words + 1] = word end
    if #words == 0 then return false end
    -- A word naming a service: only creatures that will serve the player.
    local service, allService = false, true
    for w = 1, #words do
        local bits = 0
        if #words[w] >= MIN_QUERY then
            for _, s in ipairs(ServiceWords()) do
                if sfind(s.word, words[w], 1, true) == 1 then bits = bor(bits, s.bits) end
            end
        end
        wordBits[w] = bits
        if bits ~= 0 then service = true else allService = false end
        wordRole[w] = bits ~= 0 or (not ZONE_ABBREVIATIONS[words[w]] and TitleWord(words[w]))
    end
    local town, placed = Places()
    local goods = MatchGoods()
    if placed then
        -- A plain name word beside the place (org thrall): no place meant.
        for w = 1, #words do
            if not (wordPlace[w] or wordRole[w] or goods) then
                placed, town = false, nil
                wipe(N.mapSet)
                for v = 1, #words do wordPlace[v] = nil end
                goods = MatchGoods()
                break
            end
        end
    end
    local placeKey
    if placed then
        local list = N.placeWords
        for p = #list, 1, -1 do list[p] = nil end
        for w = 1, #words do
            if wordPlace[w] then list[#list + 1] = words[w] end
        end
        placeKey = tconcat(list, " ")
    end
    N.placeKey = placeKey
    local f = EasyFind.db and EasyFind.db.npcFilters
    local horde = UnitFactionGroup and UnitFactionGroup("player") == "Horde"
    local sells = N.sells
    -- Candidates: the creatures whose name, English name or title holds
    -- the longest word, those offering its service, and the vendors when
    -- an item matched; the rest can match nothing. Scoring runs on these.
    N.gen = N.gen + 1
    local cand = N.cand
    for c = #cand, 1, -1 do cand[c] = nil end
    local lw
    for w = 1, #words do
        if not wordPlace[w] and (not lw or #words[w] > #words[lw]) then lw = w end
    end
    local longest = words[lw]
    MarkLines(N.low, N.at, N.n, longest)
    if N.enLow then MarkLines(N.enLow, N.enAt, N.n, longest) end
    local titleHit, anyTitle = N.titleHit, false
    for t = 1, #N.titleLow do
        local hit = sfind(N.titleLow[t], longest, 1, true)
            or (N.titleLowEnglish[t] and sfind(N.titleLowEnglish[t], longest, 1, true))
        titleHit[t] = hit and true or nil
        if hit then anyTitle = true end
    end
    local bits = wordBits[lw]
    if anyTitle or bits ~= 0 then
        local title, kind = N.title, N.kind
        for i = 1, N.n do
            if titleHit[title[i]] or (bits ~= 0 and band(mfloor(kind[i] / 256), bits) ~= 0) then Mark(i) end
            if i % 512 == 0 then SliceCheckpoint() end
        end
    end
    if goods then
        for i in pairs(sells) do Mark(i) end
    end
    -- Where to look: around the town's inn, on the zones named, on the
    -- caller's map, or on the player's own map (and its cities) for
    -- services alone; the nearest of equal matches first.
    local set, r2, nearOnly
    local pci, px, py
    local mapSet = N.mapSet
    if town then
        pci, px, py, r2 = town.ci, town.wx, town.wy, TOWN_RADIUS2
    else
        pci, px, py = PlayerWorld()
        if next(mapSet) then
            set = mapSet
        elseif onlyMap then
            mapSet[onlyMap] = true
            set = mapSet
        elseif allService and nearMap then
            AddMaps(mapSet, nearMap)
            set, nearOnly = mapSet, true
        end
    end
    local n = Keep(set, pci, px, py, r2, goods, f, horde, service)
    if n == 0 and nearOnly then
        wipe(mapSet)
        set = nil
        n = Keep(nil, pci, px, py, nil, goods, f, horde, service)
    end
    if n == 0 then return false end
    local hits, spot, near = N.hits, N.spot, N.near
    local capped = n > MAX_ROWS
    for j = 1, n do
        local i = hits[j]
        local k = capped and BestSpot(i, set, pci, px, py, r2) or nil
        spot[i], near[i] = k, FAR
        if k and pci then
            local ci, wx, wy = SpotWorld(k)
            if ci == pci then near[i] = (wx - px) ^ 2 + (wy - py) ^ 2 end
        end
    end
    tsort(hits, HitLess)
    for j = 1, mmin(n, MAX_ROWS) do
        local i = hits[j]
        local k = spot[i] or BestSpot(i, set, pci, px, py, r2)
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
