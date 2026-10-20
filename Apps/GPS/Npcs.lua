-- Named creatures as map rows: the packed catalog (ns.NPC_DATA) unpacked on
-- the first query long enough to reach it, matched on name, title, service
-- or what a vendor sells, each row on the creature's spot nearest the player.
local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns then return end

local MapSearch = ns.MapSearch
local Search = ns.MapSearchSearch
if not (MapSearch and Search and Search.PreparePOI) then return end

local sbyte, schar, sfind, slower, sgmatch, ssub = string.byte, string.char, string.find, string.lower, string.gmatch, string.sub
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
local WEAPON = 2        -- Enum.ItemClass.Weapon
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
-- Per creature its kind and title as arrays (every query reads them for
-- all creatures), the rest packed in rec; per spot its map, place and
-- spawns packed in spots (Rec, Spot below).
local N = {
    n = nil,
    kind = {}, title = {}, rec = "", spots = "",
    names = "", low = "", at = {}, enNames = nil, enLow = nil, enAt = nil,
    titleName = {}, titleLow = {}, titleEnglish = {}, titleLowEnglish = {},
    spotCi = {}, spotWx = {}, spotWy = {},
    pois = setmetatable({}, { __mode = "v" }),
    hits = {}, score = {}, words = {}, wordBits = {}, spot = {}, near = {}, retailEntrance = {},
    mark = {}, cand = {}, titleHit = {}, gen = 0, hitLow = {}, hitEn = {},
    -- Per query word whether it names a service or title (wordRole) or a
    -- place (wordPlace); the places named and the maps of the chosen ones.
    wordRole = {}, wordPlace = {}, placeHit = {}, placeWordsOf = {}, placeList = {}, placeWords = {}, mapSet = {},
    -- What vendors sell: per item (index j) its id and names, per stock list
    -- (index l) its items, per creature the list it sells (sells[i]).
    goodsN = nil, goodsId = {}, goodsName = {}, goodsLow = {}, goodsLowEnglish = {},
    listsOf = {}, sells = {}, listHit = {}, itemScore = {}, matched = {}, sold = {},
    -- Weapons: per item its type (item subclass), per type the client's
    -- name; soldType[j] when the query named the type, not the item.
    goodsType = {}, typeName = {}, typeLow = {}, typeScore = {}, soldType = {},
    -- The query's best item, and per creature whether only its stock matched.
    bestItem = nil, byItem = {},
    ROLE_GROUPS = { "quest", "vendor", "trainer", "flight", "services", "other" },
}
ns.GPSNpcs = N

-- Unpacked these were ten arrays, 8 MB of the 11 a decoded catalog held.
-- A creature's record: id (3 bytes), flags (1), display id (3), first
-- spot (3), spot count (2). A spot's: map (2), x * GRID + y (3), spawns (2).
local REC, SPOT = 12, 7
local function U16(s, p)
    local a, b = sbyte(s, p, p + 1)
    return a + b * 256
end
local function U24(s, p)
    local a, b, c = sbyte(s, p, p + 2)
    return a + b * 256 + c * 65536
end
local function B3(v)
    return v % 256, mfloor(v / 256) % 256, mfloor(v / 65536)
end
local Rec = {
    id = function(i) return U24(N.rec, (i - 1) * REC + 1) end,
    flags = function(i) return sbyte(N.rec, (i - 1) * REC + 4) end,
    display = function(i) return U24(N.rec, (i - 1) * REC + 5) end,
    first = function(i) return U24(N.rec, (i - 1) * REC + 8) end,
    count = function(i) return U16(N.rec, (i - 1) * REC + 11) end,
}
local Spot = {
    map = function(k) return U16(N.spots, (k - 1) * SPOT + 1) end,
    xy = function(k) return U24(N.spots, (k - 1) * SPOT + 3) end,
    spawns = function(k) return U16(N.spots, (k - 1) * SPOT + 6) end,
}
N.Rec, N.Spot = Rec, Spot

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
    local display = Rec.display(i)
    return { name = Name(i), npcID = Rec.id(i), displayID = display ~= 0 and display or nil }
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

local function Lines(blob, out, sliced)
    if not blob then return out end
    local ok, text = pcall(Unpack, blob)
    if not (ok and text) then return out end
    local i = 0
    for line in sgmatch(text .. "\n", "(.-)\n") do
        i = i + 1
        out[i] = line
        if sliced and i % 1024 == 0 then SliceCheckpoint() end
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
local function Text(text, count, sliced)
    text = (text or ""):gsub("\n$", "")
    local blob = "\n" .. text .. "\n"
    local at, pos = {}, 2
    for i = 1, count do
        if sliced and i % 1024 == 0 then SliceCheckpoint() end
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
local function MergedNames(data, count, key, localKey, baseKey, sliced)
    local english = data[key]
    if not english then return "" end
    local ok, text = pcall(Unpack, english)
    if not (ok and text) then return "" end
    if not (data[localKey] or data[baseKey]) then return text end
    local en = Lines(english, {}, sliced)
    local own, base = Lines(data[localKey], {}, sliced), Lines(data[baseKey], {}, sliced)
    local out = {}
    for i = 1, count do
        if sliced and i % 1024 == 0 then SliceCheckpoint() end
        out[i] = Pick(own, base, en, i) or "?"
    end
    return table.concat(out, "\n")
end

-- Decodes the catalog into N; N.n is set only once it is whole. Rewrites
-- the same slots each run, so a cancelled sliced run can be redone.
-- sliced: the caller's sliced run has no pcall around this.
local function Decode(sliced)
    local data = ns.NPC_DATA
    if not (data and C_EncodingUtil and C_EncodingUtil.DecompressString) then N.n = 0 return end
    local ok, raw = pcall(Unpack, data.rows)
    if not (ok and raw) then N.n = 0 return end
    local u = Reader(raw)
    local count, last, k = u(), 0, 0
    local recs, spots = {}, {}
    for i = 1, count do
        if sliced and i % 256 == 0 then SliceCheckpoint() end
        last = last + u()
        local _, _, flags, kind, display, title = u(), u(), u(), u(), u(), u()
        N.kind[i], N.title[i] = kind, title
        local c = u()
        local i1, i2, i3 = B3(last)
        local d1, d2, d3 = B3(display)
        local f1, f2, f3 = B3(k + 1)
        recs[i] = schar(i1, i2, i3, flags, d1, d2, d3, f1, f2, f3, c % 256, mfloor(c / 256))
        for _ = 1, c do
            k = k + 1
            local m, xy, spawns = u(), u(), u()
            local x1, x2, x3 = B3(xy)
            spots[k] = schar(m % 256, mfloor(m / 256), x1, x2, x3, spawns % 256, mfloor(spawns / 256))
        end
    end
    N.rec, N.spots = tconcat(recs), tconcat(spots)
    N.names, N.at = Text(MergedNames(data, count, "names", "localNames", "baseNames", sliced), count, sliced)
    N.low = slower(N.names)
    if data.localNames or data.baseNames then
        local okEn, en = pcall(Unpack, data.names)
        N.enNames, N.enAt = Text(okEn and en or "", count, sliced)
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
end

local warmHandle, warmQueued
local LoadGoods

-- A caller that needs the catalog now stops a sliced decode under way and
-- decodes at once (the decodes rewrite the same slots, so none interleave).
local function CancelWarm()
    if warmHandle then
        warmHandle:Cancel()
        warmHandle = nil
    end
    warmQueued = nil
end

-- sliced: called from the warm's own run.
local function Load(sliced)
    if N.n then return N.n > 0 end
    if not sliced then CancelWarm() end
    Decode(sliced)
    return N.n > 0
end

-- The decode in slices from first focus, creatures then what vendors
-- sell: the first creature search of a session ran all of it, 23,000
-- creatures and the goods, inside its keystroke.
function N.Warm()
    if (N.n and N.goodsN) or warmQueued then return end
    warmQueued = true
    ns.Utils.SafeAfter(0, function()
        if not warmQueued then return end
        warmHandle = ns.Utils.RunSliced(function()
            Load(true)
            LoadGoods(true)
        end, function(ok, err)
            warmHandle, warmQueued = nil, nil
            if not ok then return ns.Utils.ErrorHandler(err) end
            if not (N.n and N.n > 0) then return end
            if ns.Search and ns.Search.RefreshActiveSearch then ns.Search:RefreshActiveSearch() end
            if ns.MapTab and ns.MapTab.RefreshSearch then ns.MapTab:RefreshSearch() end
        end, 4)
    end)
end

-- The keystroke path never decodes: until the warm lands, searches go on
-- without creatures and repaint when it does.
local function Ready()
    if N.n and N.goodsN then return N.n > 0 end
    N.Warm()
    return false
end

N.Load = Load

-- The goods blob (dev/tools/npc_catalog.py): items, the lists that share
-- them, and which creature (by row index) sells which list.
-- Like Decode, sets N.goodsN only once whole and can be redone.
LoadGoods = function(sliced)
    if N.goodsN then return N.goodsN > 0 end
    if not sliced then CancelWarm() end
    local data = ns.NPC_DATA
    if not (data and data.goods and Load(sliced)) then N.goodsN = 0 return false end
    local ok, raw = pcall(Unpack, data.goods)
    if not (ok and raw) then N.goodsN = 0 return false end
    local u = Reader(raw)
    local count, last = u(), 0
    for j = 1, count do
        if sliced and j % 512 == 0 then SliceCheckpoint() end
        last = last + u()
        N.goodsId[j] = last
        N.listsOf[j] = {}
    end
    for j = 1, count do
        local t = u() - 1
        if t >= 0 then
            N.goodsType[j] = t
            if N.typeLow[t] == nil then
                local name = C_Item.GetItemSubClassInfo(WEAPON, t)
                N.typeName[t], N.typeLow[t] = name, name and name ~= "" and slower(name) or false
            end
        end
    end
    for l = 1, u() do
        if sliced and l % 256 == 0 then SliceCheckpoint() end
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
    local english = Lines(data.goodsNames, {}, sliced)
    local own, base = Lines(data.localGoods, {}, sliced), Lines(data.baseGoods, {}, sliced)
    for j = 1, count do
        if sliced and j % 512 == 0 then SliceCheckpoint() end
        local name = Pick(own, base, english, j) or "?"
        N.goodsName[j] = name
        N.goodsLow[j] = slower(name)
        if english[j] and english[j] ~= name then N.goodsLowEnglish[j] = slower(english[j]) end
    end
    N.goodsN = count
    return count > 0
end
N.LoadGoods = LoadGoods

-- Every word of the query in a name (low, or alt in English): 3 when the
-- name starts with the first, 2 when a word in it does, else 1; 0 when not.
local function WordsScore(low, alt)
    local words, wordPlace = N.words, N.wordPlace
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
    local listHit, itemScore, matched, soldType = N.listHit, N.itemScore, N.matched, N.soldType
    for m = #matched, 1, -1 do
        for _, l in ipairs(N.listsOf[matched[m]]) do listHit[l] = nil end
        itemScore[matched[m]] = nil
        soldType[matched[m]] = nil
        matched[m] = nil
    end
    N.bestItem = nil
    if not LoadGoods() then return false end
    local typeScore = N.typeScore
    for t, low in pairs(N.typeLow) do typeScore[t] = low and WordsScore(low) or 0 end
    for j = 1, N.goodsN do
        local s = WordsScore(N.goodsLow[j], N.goodsLowEnglish[j])
        -- A weapon its type names better than its own name (a Shortbow for
        -- "bow"): it is sold as the type.
        local t = N.goodsType[j]
        if t and typeScore[t] > s then
            s = typeScore[t]
            soldType[j] = t
        end
        if s > 0 then
            itemScore[j] = s
            matched[#matched + 1] = j
            if not N.bestItem or s > itemScore[N.bestItem] then N.bestItem = j end
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
    local m = Spot.map(k)
    if m == 0 then
        local e
        if ns.Caps and ns.Caps.forever then e = Entrance(Spot.xy(k)) else e = RetailEntrance(Spot.xy(k)) end
        if e then return e.m, e.x, e.y, e end
        return nil
    end
    local xy = Spot.xy(k)
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
    local first = Rec.first(i)
    for k = first, first + Rec.count(i) - 1 do
        if not set or set[Spot.map(k)] then
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
    local first = Rec.first(i)
    for k = first, first + Rec.count(i) - 1 do
        if not set or set[Spot.map(k)] then
            local d
            if pci then
                local ci, wx, wy = SpotWorld(k)
                if ci == pci then d = (wx - px) ^ 2 + (wy - py) ^ 2 end
            end
            if not r2 or (d and d <= r2) then
                if d and (not bestD or d < bestD) then best, bestD = k, d end
                local spawns = Spot.spawns(k)
                if not most or spawns > mostN then most, mostN = k, spawns end
            end
        end
    end
    return best or most
end

-- Of creature i's spots on the set's maps, the one a stop at adds the
-- least to the way (along: world spot to seconds, nil off the way), and
-- those seconds; nil when none is along it.
local function AlongSpot(i, set, along)
    local best, bestSec
    local first = Rec.first(i)
    for k = first, first + Rec.count(i) - 1 do
        if not set or set[Spot.map(k)] then
            local ci, wx, wy = SpotWorld(k)
            local sec = ci and along(ci, wx, wy)
            if sec and (not bestSec or sec < bestSec) then best, bestSec = k, sec end
        end
    end
    return best, bestSec
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

-- Per creature line holding word, where its first hit sits: one find per
-- such line. A find per candidate ran on to the next hit anywhere in the
-- text, the whole text for a service word (repair) few names hold.
local function LineHits(blob, at, n, word, into)
    local p = sfind(blob, word, 1, true)
    while p do
        local i = LineAt(at, n, p)
        into[i] = p
        p = sfind(blob, word, at[i + 1], true)
    end
end

-- The query words' line hits in both texts (hitLow[w], hitEn[w]).
local function MarkWordHits()
    local words, wordPlace = N.words, N.wordPlace
    for w = 1, #words do
        local low, en = N.hitLow[w], N.hitEn[w]
        if low then wipe(low) else low = {}; N.hitLow[w] = low end
        if en then wipe(en) else en = {}; N.hitEn[w] = en end
        if not wordPlace[w] then
            LineHits(N.low, N.at, N.n, words[w], low)
            if N.enLow then LineHits(N.enLow, N.enAt, N.n, words[w], en) end
        end
    end
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
            local p, blob, start = N.hitLow[w][i], low, at[i]
            if not p and enLow then p, blob, start = N.hitEn[w][i], enLow, enAt[i] end
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
        local display = Rec.display(i)
        poi = { name = Name(i), category = "npc", isStatic = true, npcID = Rec.id(i), catalog = true,
                displayID = display ~= 0 and display or nil,
                keywords = #keywords > 0 and keywords or nil }
        poi.baseKeywords = poi.keywords
        PreparePOI(poi)
        N.pois[i] = poi
    end
    -- Found by what it sells or where: the item (or weapon type) and the
    -- place words typed ride along as keywords so the map search's own
    -- scoring keeps the row; the item is the row's note too.
    local j = N.sold[i] or nil
    local t = j and N.soldType[j]
    local soldName = j and (t and N.typeName[t] or N.goodsName[j]) or nil
    -- Found by its stock alone: scored as the query's best item, its title
    -- left out, as every such vendor is, so the nearest leads (not a "Staff
    -- & Mace Merchant" across the world for quarter staff).
    local scoredAs = N.byItem[i] and N.bestItem or nil
    local placeKey = N.placeKey
    if poi.soldName ~= soldName or poi.placeKey ~= placeKey or poi.scoredAs ~= scoredAs then
        poi.soldName, poi.placeKey, poi.scoredAs = soldName, placeKey, scoredAs
        local keywords = poi.baseKeywords
        if soldName or placeKey then
            keywords = {}
            local item = scoredAs or j
            if item then
                local it = N.soldType[item]
                keywords[1] = it and N.typeName[it] or N.goodsName[item]
                if not it and N.goodsLowEnglish[item] then keywords[2] = N.goodsLowEnglish[item] end
            end
            if placeKey then
                for w = 1, #N.words do
                    if N.wordPlace[w] then keywords[#keywords + 1] = N.words[w] end
                end
            end
            if not scoredAs then
                for w = 1, #(poi.baseKeywords or {}) do keywords[#keywords + 1] = poi.baseKeywords[w] end
            end
        end
        poi.keywords, poi.kwLower, poi.searchMask = keywords, nil, nil
        poi.matchNote = soldName and sformat(ns.L["NPC_SELLS"] or "Sells %s", soldName) or nil
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
    if f.reaction and f.reaction[mfloor(Rec.flags(i) / (horde and 32 or 8)) % 4] == false then return false end
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

-- Whether every word of query names a service or starts a word of a title
-- (repair, inn, hunter trainer): a kind of creature asked for, not one.
function N.KindQuery(query)
    if not Ready() then return false end
    local any = false
    for word in sgmatch(slower(query), "%S+") do
        if #word < MIN_QUERY then return false end
        local kind = TitleWord(word)
        if not kind then
            for _, s in ipairs(ServiceWords()) do
                if sfind(s.word, word, 1, true) == 1 then
                    kind = true
                    break
                end
            end
        end
        if not kind then return false end
        any = true
    end
    return any
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
        -- What it sells that the query names, when a word of the item starts
        -- with it (not "bow" inside Rainbow Fin Albacore): its match when
        -- nothing else matched, else a note beside its name.
        local j = goods and sells[i] and listHit[sells[i]] or false
        if j and N.itemScore[j] < 2 then j = false end
        local byItem = false
        if s == 0 and j then s, byItem = N.itemScore[N.bestItem], true end
        if s > 0 and (set or r2) and not Within(i, set, pci, px, py, r2) then s = 0 end
        if s > 0 and f and not Passes(i, f, horde) then s = 0 end
        if s > 0 and (service or byItem) and mfloor(Rec.flags(i) / (horde and 32 or 8)) % 4 == 2 then s = 0 end
        if s > 0 then
            n = n + 1
            hits[n] = i
            score[i] = s
            sold[i] = j
            N.byItem[i] = byItem
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
-- auberdine inn). along (world spot to seconds, nil off the way): only
-- those along a route, each at its spot least out of the way. True when
-- more matched than were handed over.
function N.Append(out, nameSet, query, onlyMap, nearMap, along)
    if not query or #query < MIN_QUERY then return false end
    -- A route's along-the-way search waits for the catalog; typing never.
    if along then Load() end
    if not Ready() then return false end
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
    MarkWordHits()
    local n = Keep(set, pci, px, py, r2, goods, f, horde, service)
    if n == 0 and nearOnly then
        wipe(mapSet)
        set = nil
        n = Keep(nil, pci, px, py, nil, goods, f, horde, service)
    end
    if n == 0 then return false end
    local hits, spot, near = N.hits, N.spot, N.near
    if along then
        local kept = 0
        for j = 1, n do
            local i = hits[j]
            local k, sec = AlongSpot(i, set, along)
            if k then
                kept = kept + 1
                hits[kept], spot[i], near[i] = i, k, sec
            end
        end
        for j = n, kept + 1, -1 do hits[j] = nil end
        n = kept
        if n == 0 then return false end
    else
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
MapSearch.NpcKindQuery = N.KindQuery
