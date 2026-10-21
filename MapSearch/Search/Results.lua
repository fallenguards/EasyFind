local _, ns = ...

local MapSearch = ns.MapSearch
local Utils = ns.Utils
local Search = ns.MapSearchSearch
local L = ns.L

local pairs, ipairs = Utils.pairs, Utils.ipairs
local tinsert, tsort, tremove = Utils.tinsert, Utils.tsort, Utils.tremove
local slower = Utils.slower
local mmin, mmax = Utils.mmin, Utils.mmax
local wipe = wipe

local GetBestMapForUnit = C_Map.GetBestMapForUnit

local GetCategoryIcon = Search.GetCategoryIcon
local GetMapPinKey = Search.GetMapPinKey
local FlightPathsEnabledAnywhere = Search.FlightPathsEnabledAnywhere
local WipeScratchTables = Search.WipeScratchTables
local GetNameLower = Search.GetNameLower
local PreparePOI = Search.PreparePOI
local POICouldMatch = Search.POICouldMatch
local BuildEntranceLookup = Search.BuildEntranceLookup
local EnrichZoneWithEntrance = Search.EnrichZoneWithEntrance
local AppendLocalSearchSources = Search.AppendLocalSearchSources
local AppendZoneSearchResults = Search.AppendZoneSearchResults
local AppendGlobalInstanceSearchSources = Search.AppendGlobalInstanceSearchSources
local AppendAlwaysFindableLocations = Search.AppendAlwaysFindableLocations
local AppendSubzones = Search.AppendSubzones
local ReleaseGlobalMapCaches = Search.ReleaseGlobalMapCaches
local CollectMapGarbage = Search.CollectMapGarbage

local reuseAllPOIs = Search.reuseAllPOIs
local reuseZoneNames = Search.reuseZoneNames
local reuseExistingNames = Search.reuseExistingNames
local reuseFilteredResults = Search.reuseFilteredResults
local reusePinnedKeys = Search.reusePinnedKeys
local reusePinned = Search.reusePinned
local reuseFiltered = Search.reuseFiltered
local reuseSearchResults = Search.reuseSearchResults
local reuseSearchSeen = Search.reuseSearchSeen
local reuseSearchDuplicates = Search.reuseSearchDuplicates
local reuseUISearchPOIs = Search.reuseUISearchPOIs
local reuseUISearchExistingNames = Search.reuseUISearchExistingNames
local reuseUISearchZoneNames = Search.reuseUISearchZoneNames
local reuseUISearchFiltered = Search.reuseUISearchFiltered
local reuseUISearchResults = Search.reuseUISearchResults
local reuseUISearchResultData = Search.reuseUISearchResultData
local reuseFreshRows = Search.reuseFreshRows
local reuseUIFreshRows = Search.reuseUIFreshRows
local reuseUIScored = Search.reuseUIScored
local reuseUICategoryRows = Search.reuseUICategoryRows
local reuseUICategoryData = Search.reuseUICategoryData
local UI_MAP_RESULT_CAP = Search.UI_MAP_RESULT_CAP

local function RequestUISearchGlobalInstances(self)
    if not self.RequestGlobalInstanceCache then return end
    if Search.uiGlobalInstanceRefreshPending then
        self:RequestGlobalInstanceCache()
        return
    end

    Search.uiGlobalInstanceRefreshPending = true
    self:RequestGlobalInstanceCache(function(ready)
        Search.uiGlobalInstanceRefreshPending = nil
        if ready and ns.MapSearch.ResetSearchPoisCache then ns.MapSearch.ResetSearchPoisCache() end
        if ready and ns.Search and ns.Search.RefreshActiveSearch then
            ns.Search:RefreshActiveSearch()
        end
    end)
end

-- Pure result computation: takes a query and a global-mode flag, returns the
-- ranked + filtered + pin-merged result list. No rendering. Safe to call
-- from MapTab or any other renderer that wants both local and global sets.
-- Temporarily sets the module-level `Search.isGlobalSearch` so transitively-called
-- helpers (SearchZones, GetGlobalInstanceCache, ...) see the requested mode.
function MapSearch:BuildResults(text, isGlobal, skipPins)
    local savedGlobalFlag = Search.isGlobalSearch
    Search.isGlobalSearch = isGlobal and true or false

    -- Search for zones (works for both local and global mode). Local mode
    -- self-scopes to the viewed map's children plus the viewed map itself,
    -- so this runs from any view, not just continents: searching a zone's
    -- own name while viewing it (or one of its subzones) must match.
    local zoneMatches = self:SearchZones(text)

    wipe(reuseAllPOIs)
    wipe(reuseZoneNames)
    wipe(reuseFreshRows)
    local allPOIs = reuseAllPOIs
    local zoneNames = reuseZoneNames
    -- Zone and creature rows: a set of their own per query, so scored
    -- fresh beside the cached rest.
    local fresh = reuseFreshRows

    local groupedZones = self:GroupZonesByParent(zoneMatches)
    AppendZoneSearchResults(fresh, zoneNames, groupedZones)

    -- Global search: zones + dungeon/raid/delve entrances (skip service POIs)
    --
    -- Instances get ONE authoritative source: the global instance cache.
    -- Dungeon-type zone results from SearchZones are suppressed when the
    -- cache covers them. Cache entries are promoted to zone-style display
    -- (with full breadcrumb paths) using a mapID-to-path lookup.
    if isGlobal then
        AppendGlobalInstanceSearchSources(self, allPOIs, zoneNames, fresh)
        AppendAlwaysFindableLocations(self, allPOIs, zoneNames, WorldMapFrame and WorldMapFrame:GetMapID())
        AppendSubzones(self, allPOIs, zoneNames, WorldMapFrame and WorldMapFrame:GetMapID())
        if self.AppendNpcRows then self.AppendNpcRows(fresh, zoneNames, text) end

        if FlightPathsEnabledAnywhere() then
            local allFMs = self:ScanAllFlightMasters()
            for i = 1, #allFMs do
                local fm = allFMs[i]
                fm.score = nil
                fm.duplicateKey = nil
                fm.allInstances = nil
                if not zoneNames[GetNameLower(fm)] then
                    allPOIs[#allPOIs + 1] = fm
                end
            end
        end
    else
        wipe(reuseExistingNames)
        local existingNames = reuseExistingNames
        local dungeonEntrances = AppendLocalSearchSources(self, allPOIs, existingNames, zoneNames, nil, false)
        if self.AppendNpcRows then
            self.AppendNpcRows(fresh, existingNames, text, WorldMapFrame and WorldMapFrame:GetMapID())
        end

        local entranceLookup = BuildEntranceLookup(dungeonEntrances)
        for _, poi in ipairs(fresh) do
            if poi.isZone and poi.zoneMapID then
                local entrance = entranceLookup[GetNameLower(poi)]
                if entrance then
                    EnrichZoneWithEntrance(poi, entrance)
                end
            end
        end

        -- Local mode normally only sees POIs in the current zone, so
        -- abbreviations like "rfc" -> Ragefire Chasm fall flat unless
        -- the player happens to be standing in Orgrimmar. The UI search
        -- bar always pulls the global instance cache; the map search
        -- bar should match that for consistency. Add globally-cached
        -- dungeon / raid / delve entrances as additional candidates so
        -- a name or abbreviation hit surfaces them regardless of
        -- current zone. They still get scored alongside local POIs.
    end

    local results = self:SearchPOIs(allPOIs, text, fresh)

    -- Blacklist rides the existing filter copy-loops in both branches:
    -- same single suppression predicate as main search (ns.Blacklist).
    local blacklistActive = ns.Blacklist and ns.Blacklist:HasAny()

    -- Apply global search filters (zones / dungeons / raids / delves)
    if isGlobal then
        local filters = EasyFind.db.globalSearchFilters
        wipe(reuseFilteredResults)
        local filteredResults = reuseFilteredResults
        for _, r in ipairs(results) do
            local dominated = false
            if blacklistActive and ns.Blacklist:Contains(r) then
                dominated = true
            elseif (r.isZone or r.category == "subzone") and filters.zones == false then
                dominated = true
            elseif r.category == "dungeon" and filters.dungeons == false then
                dominated = true
            elseif r.category == "raid" and filters.raids == false then
                dominated = true
            elseif r.category == "delve" and filters.delves == false then
                dominated = true
            end
            if not dominated then
                tinsert(filteredResults, r)
            end
        end
        results = filteredResults
    else
        -- Drop any POI whose filter bucket is disabled. Bucketing (including
        -- flightmaster -> flightpath, kept separate from travel) lives in
        -- GetFilterBucket so every filter surface agrees on one mapping.
        local filters = EasyFind.db.localSearchFilters
        wipe(reuseFilteredResults)
        local filteredResults = reuseFilteredResults
        for _, r in ipairs(results) do
            if ns.MapSearch.PassesFilter(r, filters)
               and not (blacklistActive and ns.Blacklist:Contains(r)) then
                tinsert(filteredResults, r)
            end
        end
        results = filteredResults
    end

    -- Prepend pinned items with header (always shown at top regardless of query).
    -- Callers that render their own pinned section (e.g. MapTab) pass skipPins.
    local pins = not skipPins and EasyFind.db.pinnedMapItems or nil
    if pins and #pins > 0 then
        wipe(reusePinnedKeys)
        wipe(reusePinned)
        local pinnedKeys = reusePinnedKeys
        local pinned = reusePinned
        -- Header row
        tinsert(pinned, { isPinHeader = true, name = L["HEADER_PINNED"] })
        if not EasyFind.db.mapPinsCollapsed then
            for _, pin in ipairs(pins) do
                local copy = {}
                for k, v in pairs(pin) do copy[k] = v end
                copy.isPinned = true
                tinsert(pinned, copy)
                pinnedKeys[GetMapPinKey(pin)] = true
            end
        else
            for _, pin in ipairs(pins) do
                pinnedKeys[GetMapPinKey(pin)] = true
            end
        end
        wipe(reuseFiltered)
        local filtered = reuseFiltered
        for _, r in ipairs(results) do
            if not pinnedKeys[GetMapPinKey(r)] then
                tinsert(filtered, r)
            end
        end
        for _, r in ipairs(filtered) do
            tinsert(pinned, r)
        end
        results = pinned
    end

    Search.isGlobalSearch = savedGlobalFlag
    return results
end

-- Per-query cache for SearchPOIs, mirrors the SearchZones cache. Keeps
-- recent queries so backspace re-hits cached results instead of doing
-- a fresh scan. Extension of the last query still narrows from its
-- match set.
local SEARCH_CACHE_MAX = 32
local searchPoisCache = {
    local_  = { entries = {}, order = {}, lastQuery = "", lastCategory = nil },
    global_ = { entries = {}, order = {}, lastQuery = "", lastCategory = nil },
    ui_     = { entries = {}, order = {}, lastQuery = "", lastCategory = nil },
}
local function ResetSearchPoisCache()
    for _, c in pairs(searchPoisCache) do
        wipe(c.entries); wipe(c.order); c.lastQuery = ""; c.lastCategory = nil
    end
end
ns.MapSearch.ResetSearchPoisCache = ResetSearchPoisCache

local function ClearMapSearchScratch()
    WipeScratchTables()
end

function MapSearch:TrimSearchMemory()
    if self.ResetSearchZonesCache then self.ResetSearchZonesCache() end
    ResetSearchPoisCache()
    ReleaseGlobalMapCaches()
    Search.ClearLocalCaches()
    ClearMapSearchScratch()
    CollectMapGarbage()
end

function MapSearch:ReleaseIdleSearchMemory()
    ReleaseGlobalMapCaches()
    Search.ClearLocalCaches()
    ClearMapSearchScratch()
    CollectMapGarbage()
end

-- Equal matches nearest first: the player's spot, taken once a search, and
-- each place's world spot, kept beside it.
local GetPlayerMapPosition, GetWorldPosFromMapPos = C_Map.GetPlayerMapPosition, C_Map.GetWorldPosFromMapPos
local FAR = math.huge
local worldSpots = setmetatable({}, { __mode = "k" })
local nearOf = setmetatable({}, { __mode = "k" })

local function WorldSpot(poi)
    local m, x, y = poi.coordMapID or poi.entranceMapID or poi.mapID, poi.x, poi.y
    if not (m and x and y) then return nil end
    local s = worldSpots[poi]
    if not (s and s.m == m and s.x == x and s.y == y) then
        s = { m = m, x = x, y = y }
        local ok, ci, pos = pcall(GetWorldPosFromMapPos, m, CreateVector2D(x, y))
        if ok and ci and pos then s.ci, s.wx, s.wy = ci, pos:GetXY() end
        worldSpots[poi] = s
    end
    return s.ci, s.wx, s.wy
end

local function Nearest(poi, pci, px, py)
    local d = FAR
    local list = poi.allInstances
    for i = 1, list and #list or 1 do
        local ci, wx, wy = WorldSpot(list and list[i] or poi)
        if ci == pci then d = mmin(d, (wx - px) ^ 2 + (wy - py) ^ 2) end
    end
    return d
end

local function TakeDistances(results)
    local m = GetBestMapForUnit("player")
    local pos = m and GetPlayerMapPosition(m, "player")
    local ok, pci, wp
    if pos then ok, pci, wp = pcall(GetWorldPosFromMapPos, m, pos) end
    local px, py
    if ok and pci and wp then px, py = wp:GetXY() else pci = nil end
    for i = 1, #results do
        local r = results[i]
        nearOf[r] = (pci and not r.isZone) and Nearest(r, pci, px, py) or FAR
    end
end

local function POIResultLess(a, b)
    local sa, sb = a.score or 0, b.score or 0
    if sa == sb then
        if a.isZone and not b.isZone then return true end
        if b.isZone and not a.isZone then return false end
        local da, db = nearOf[a] or FAR, nearOf[b] or FAR
        if da ~= db then return da < db end
        local an, bn = a.name or "", b.name or ""
        if #an ~= #bn then return #an < #bn end
        return an < bn
    end
    return sa > sb
end

local function GetPOIDuplicateKey(poi)
    return (poi.name or "") .. (poi.category or "")
        .. (poi.isZone and (poi.pathPrefix or "") or "")
end

-- The cache's entry for the query, or the candidates: the last query's
-- pool when this one extends it (narrowed = true), else every poi.
local function ResolveSearchCache(cache, query, matchedCategory, defaultCandidates)
    local cachedHit = cache.entries[query]
    if cachedHit and cachedHit.matchedCategory == matchedCategory then
        cache.lastQuery = query
        cache.lastCategory = matchedCategory
        return cachedHit, nil, false
    end

    if cache.lastQuery ~= ""
       and #query > #cache.lastQuery
       and query:sub(1, #cache.lastQuery) == cache.lastQuery
       and cache.lastCategory == matchedCategory then
        local previous = cache.entries[cache.lastQuery]
        if previous then
            return nil, previous.pool, true
        end
    end

    return nil, defaultCandidates, false
end

local function ClearCachedCandidateScores(candidates)
    for i = 1, #candidates do
        local poi = candidates[i]
        poi.score, poi.duplicateKey, poi.allInstances = nil, nil, nil
    end
end

local function ScorePOIForQuery(poi, query)
    if poi.isZone and poi.score then return poi.score end

    local score = ns.Database:ScoreName(GetNameLower(poi), query, #query)
    if poi.keywords then
        if not poi.kwLower then PreparePOI(poi) end
        score = mmax(score, ns.Database:ScoreKeywords(poi.kwLower, query, #query))
    end
    return score
end

local function AddScoredPOI(results, seen, duplicates, poi, key, score)
    local first = seen[key]
    if first then
        -- The same place again: its set of spots, made at the second.
        local dup = duplicates[key]
        if not dup then
            dup = { first }
            duplicates[key] = dup
        end
        dup[#dup + 1] = poi
        return
    end
    seen[key] = poi
    poi.score = score
    poi.duplicateKey = key
    tinsert(results, poi)
end

local function AppendNameMatches(results, seen, duplicates, candidates, query)
    for _, poi in ipairs(candidates) do
        -- Letter-mask gate BEFORE any scoring call: the map corpus'
        -- version of the UI index's candidate pruning. For a typical
        -- non-map query ("glad mount") this skips nearly every POI with
        -- one band(), which was the main bar's per-keystroke map cost.
        if (poi.isZone and poi.score) or POICouldMatch(poi, query) then
            local score = ScorePOIForQuery(poi, query)
            if score >= 50 then
                AddScoredPOI(results, seen, duplicates, poi, GetPOIDuplicateKey(poi), score)
            end
        end
    end
end

local function GetCategoryMatchScore(poi, matchedCategory, relatedCategories)
    if poi.category == matchedCategory then return 150 end
    if relatedCategories then
        for _, category in ipairs(relatedCategories) do
            if poi.category == category then return 100 end
        end
    end
    return 0
end

local function AppendCategoryMatches(results, seen, duplicates, pois, matchedCategory, relatedCategories)
    if not matchedCategory then return end

    for _, poi in ipairs(pois) do
        if poi.category then
            local key = GetPOIDuplicateKey(poi)
            if not seen[key] then
                local score = GetCategoryMatchScore(poi, matchedCategory, relatedCategories)
                if score > 0 then
                    AddScoredPOI(results, seen, duplicates, poi, key, score)
                end
            end
        end
    end
end

local function AttachDuplicateSets(results, duplicates)
    for _, result in ipairs(results) do
        if not result.allInstances and result.duplicateKey and duplicates[result.duplicateKey] then
            result.allInstances = duplicates[result.duplicateKey]
        end
    end
end

-- The rows with their scores, keys and spot sets, so the same query comes
-- back as it was; and every scored place, the other spots included, for
-- a longer query to narrow over.
local function StoreSearchResults(cache, query, matchedCategory, results, duplicates)
    if #results == 0 then return end
    local rows, scores, keys, sets, anyDup = {}, {}, {}, {}, false
    for i = 1, #results do
        local r = results[i]
        rows[i], scores[i], keys[i], sets[i] = r, r.score, r.duplicateKey, r.allInstances or false
        if duplicates[r.duplicateKey] then anyDup = true end
    end
    local pool = rows
    if anyDup then
        pool = {}
        for i = 1, #rows do
            local dup = duplicates[keys[i]]
            if dup then
                for j = 1, #dup do pool[#pool + 1] = dup[j] end
            else
                pool[#pool + 1] = rows[i]
            end
        end
    end
    if cache.entries[query] == nil then
        cache.order[#cache.order + 1] = query
        if #cache.order > SEARCH_CACHE_MAX then
            local oldest = tremove(cache.order, 1)
            cache.entries[oldest] = nil
        end
    end
    cache.entries[query] = { matchedCategory = matchedCategory, rows = rows, scores = scores, keys = keys,
                             sets = sets, pool = pool }
end

-- Scores pois against query (name, keywords, the matched category), equal
-- matches nearest first; the list is pooled. fresh: rows scored the same
-- way but kept out of the cache (zones and creatures, a set of their own
-- per query). cacheKey: local_, global_ or ui_ (nil: by the search mode;
-- false: none). Also the matched category.
function MapSearch:SearchPOIs(pois, query, fresh, cacheKey)
    query = slower(query)
    if ns.Database and ns.Database.NormalizeSearchQuery then
        query = ns.Database:NormalizeSearchQuery(query)
    end
    wipe(reuseSearchResults)
    wipe(reuseSearchSeen)
    wipe(reuseSearchDuplicates)
    local results = reuseSearchResults
    local seen = reuseSearchSeen
    local duplicates = reuseSearchDuplicates

    local matchedCategory = self:GetCategoryMatch(query)
    local relatedCategories = matchedCategory and self:GetRelatedCategories(matchedCategory) or nil

    if cacheKey == nil then cacheKey = Search.isGlobalSearch and "global_" or "local_" end
    local cache = cacheKey and searchPoisCache[cacheKey]
    local hit, candidates, narrowed
    if cache then
        hit, candidates, narrowed = ResolveSearchCache(cache, query, matchedCategory, pois)
    else
        candidates = pois
    end
    if hit then
        local rows, scores, keys, sets = hit.rows, hit.scores, hit.keys, hit.sets
        for i = 1, #rows do
            local r = rows[i]
            r.score, r.duplicateKey, r.allInstances = scores[i], keys[i], sets[i] or nil
            results[i], seen[keys[i]] = r, r
        end
    else
        if narrowed then ClearCachedCandidateScores(candidates) end
        AppendNameMatches(results, seen, duplicates, candidates, query)
        AppendCategoryMatches(results, seen, duplicates, pois, matchedCategory, relatedCategories)
        AttachDuplicateSets(results, duplicates)
        if cache then
            StoreSearchResults(cache, query, matchedCategory, results, duplicates)
            cache.lastQuery = query
            cache.lastCategory = matchedCategory
        end
    end
    if fresh and #fresh > 0 then
        AppendNameMatches(results, seen, duplicates, fresh, query)
        AppendCategoryMatches(results, seen, duplicates, fresh, matchedCategory, relatedCategories)
        AttachDuplicateSets(results, duplicates)
    end

    -- The player has moved since a cached hit: equal matches ranked again.
    TakeDistances(results)
    tsort(results, POIResultLess)
    return results, matchedCategory
end

-- Search for the UI search bar, mirroring the real map search pipeline.
-- Gathers the same POI sources (dynamic, static, entrances, flight masters),
-- runs SearchPOIs with the same scoring, and returns results for UI display.
-- The main bar's @map list in the map tab's two parts: the player's zone
-- first under "This Zone (Zone)", the rest under "Across the World", each
-- part in its own order. entries: the bar's { data, score } rows.
-- A query for a kind of place rather than one (inn, repair, mailbox,
-- hunter trainer): a remembered pick stands for the nearest of its kind.
function MapSearch:IsKindQuery(query)
    query = slower(query or "")
    local _, _, exact = self:GetCategoryMatch(query)
    if exact then return true end
    return self.NpcKindQuery ~= nil and self.NpcKindQuery(query)
end

local splitHere, splitThere = {}, {}
function MapSearch:SplitUIRowsByZone(entries)
    local zone = GetBestMapForUnit("player")
    local info = zone and C_Map.GetMapInfo(zone)
    wipe(splitHere)
    wipe(splitThere)
    local here, there = splitHere, splitThere
    for i = 1, #entries do
        local d = entries[i].data
        if d and zone and (d.mapID == zone or d.zoneMapID == zone) then
            here[#here + 1] = entries[i]
        else
            there[#there + 1] = entries[i]
        end
    end
    local hereLabel = info and info.name and string.format(L["MAP_SECTION_THIS_ZONE_NAMED"], info.name)
        or L["MAP_SECTION_THIS_ZONE"]
    local n = 0
    for _, e in ipairs(here) do
        n = n + 1
        entries[n] = e
        if e.data then e.data.sectionLabel = hereLabel end
    end
    for _, e in ipairs(there) do
        n = n + 1
        entries[n] = e
        if e.data then e.data.sectionLabel = L["MAP_SECTION_ACROSS_WORLD"] end
    end
end

-- A bar row's data from a scored map row. showNear: the row says how far
-- it is (a list of a kind of place, nearest first).
local function FillUIRow(d, r, searchMapID, query, showNear)
    local cat = r.category or "location"
    local near = showNear and nearOf[r]
    d.nearYards = near and near < FAR and near ^ 0.5 or nil
    d.name = r.name
    d.nameLower = GetNameLower(r)
    d.category = cat
    d.icon = r.icon or GetCategoryIcon(cat)
    d.displayID = r.displayID
    d.mapSearchResult = true
    d.mapID = r.mapID or r.zoneMapID or r.entranceMapID or searchMapID
    d.zoneName = r.zoneName or r.pathPrefix
    d.matchNote = r.matchNote
    d.soldName = r.soldName
    d.pathPrefix = r.pathPrefix
    d.x = r.x or r.entranceX
    d.y = r.y or r.entranceY
    d.keywords = r.keywords
    d.query = query
    d.isZone = nil
    d.zoneMapType = r.zoneMapType
    d.zoneMapID = nil
    d.entranceMapID = nil
    d.entranceX = nil
    d.entranceY = nil
    d.entranceIcon = nil
    d.entranceCategory = nil
    d.isDungeonEntrance = nil
    if r.isZone then
        d.isZone = true
        d.zoneMapID = r.zoneMapID
        d.entranceMapID = r.entranceMapID
        d.entranceX = r.entranceX
        d.entranceY = r.entranceY
        d.entranceIcon = r.entranceIcon
        d.entranceCategory = r.entranceCategory
    end
    if r.isDungeonEntrance then
        d.isDungeonEntrance = true
        if not d.entranceMapID then
            d.entranceMapID = r.entranceMapID
        end
    end
end

function MapSearch:SearchForUI(query)
    Search.uiSearchCount = (Search.uiSearchCount or 0) + 1
    Search.uiScoredFor = nil
    if not query or query == "" or #query < 2 then return nil end
    if self.HasWorldZoneCache and not self:HasWorldZoneCache() then return nil end

    -- Use the player's current zone as the local anchor so UI-bar map
    -- results reflect what's actually around them rather than wherever
    -- the WorldMapFrame happens to be viewing.
    local searchMapID = GetBestMapForUnit("player") or (WorldMapFrame and WorldMapFrame:GetMapID())

    -- Gather POIs from both local and global sources in a single pass
    -- so the UI bar shows results regardless of zone scope, matching
    -- how the MapTab surfaces both "This Zone" and "Across the World"
    -- content without asking the user to pick.
    wipe(reuseUISearchPOIs)
    wipe(reuseUISearchExistingNames)
    wipe(reuseUIFreshRows)
    local pois = reuseUISearchPOIs
    local existingNames = reuseUISearchExistingNames
    local fresh = reuseUIFreshRows

    do
        AppendLocalSearchSources(self, pois, existingNames, nil, searchMapID, true)
    end

    -- Always also pull in global zone + instance results. Dedup against
    -- existingNames so the local sources take priority for any POI that
    -- exists in both (same ownership rule as MapTab's local-first pass).
    do
        local savedGlobalFlag = Search.isGlobalSearch
        Search.isGlobalSearch = true
        local zoneMatches = self:SearchZones(query)
        Search.isGlobalSearch = savedGlobalFlag
        local groupedZones = self:GroupZonesByParent(zoneMatches)
        wipe(reuseUISearchZoneNames)
        local zoneNames = reuseUISearchZoneNames

        AppendZoneSearchResults(fresh, zoneNames, groupedZones, existingNames)

        -- Dungeons / raids / delves use a global map walk. The cache is
        -- built in background slices; first search should never do that walk.
        if self.HasGlobalInstanceCache and self:HasGlobalInstanceCache() then
            AppendGlobalInstanceSearchSources(self, pois, zoneNames, fresh)
        else
            RequestUISearchGlobalInstances(self)
        end
        AppendAlwaysFindableLocations(self, pois, existingNames, searchMapID)
        AppendSubzones(self, pois, existingNames, searchMapID)
        if self.AppendNpcRows then self.AppendNpcRows(fresh, existingNames, query, nil, searchMapID) end
    end

    if #pois == 0 and #fresh == 0 then return nil end

    -- The map tab's scoring, under the bar's own narrowing cache.
    local scored, matchedCategory = self:SearchPOIs(pois, query, fresh, "ui_")
    if not scored or #scored == 0 then return nil end
    -- Kept for a category boost in the same keystroke (GetCategoryResultsForUI).
    wipe(reuseUIScored)
    for i = 1, #scored do reuseUIScored[i] = scored[i] end
    Search.uiScoredFor, Search.uiScoredCategory, Search.uiScoredMapID = query, matchedCategory, searchMapID

    -- Apply the search bar's OWN map buckets (uiMapFilters), independent
    -- of the map tab's cog filters, so the bar can stay lean while the
    -- tab shows everything. Any POI whose bucket is explicitly disabled
    -- (filters[bucket] == false) drops out. Buckets without a saved
    -- value default to enabled, same convention DB_DEFAULTS uses.
    do
        local mtFilters = EasyFind.db.uiMapFilters
        if mtFilters then
            wipe(reuseUISearchFiltered)
            local filtered = reuseUISearchFiltered
            for _, r in ipairs(scored) do
                if ns.MapSearch.PassesFilter(r, mtFilters) then
                    filtered[#filtered + 1] = r
                end
            end
            scored = filtered
            if #scored == 0 then return nil end
        end
    end

    local results = reuseUISearchResults
    local resultCap = mmin(#scored, UI_MAP_RESULT_CAP)
    local kindQuery = self:IsKindQuery(query)
    for ri = 1, resultCap do
        local r = scored[ri]
        local d = reuseUISearchResultData[ri]
        if not d then
            d = {}
            reuseUISearchResultData[ri] = d
        end
        FillUIRow(d, r, searchMapID, query, kindQuery)
        d.mapRank, d.mapNear = ri, nearOf[r] or FAR
        local out = results[ri]
        if not out then
            out = {}
            results[ri] = out
        end
        out.score = r.score or 50
        out.data = d
    end
    for i = resultCap + 1, #results do
        results[i] = nil
    end

    return results
end

-- The nearest rows of one map category (GitHub #21): runs the normal UI map
-- search with the category's canonical keyword (so live scans, static data,
-- and instance caches all participate with the usual local-first ordering)
-- and keeps only rows of that category. Category ALIASES bypass the map
-- bucket filters (an explicit alias must always reach its category, same
-- rule row aliases follow); the default keyword boost passes respectFilters
-- so the user's map buckets still apply. Returned rows are the pooled
-- search tables; callers must copy before retaining them.
local function CategoryCovered(matched, category)
    if not matched then return false end
    if matched == category then return true end
    local related = MapSearch:GetRelatedCategories(matched)
    for i = 1, #related do
        if related[i] == category then return true end
    end
    return false
end

-- text: the keystroke's query; its own map pass (SearchForUI) already
-- scored the category's rows when its query matched the category, so
-- those are read instead of running a pass of their own.
function MapSearch:GetCategoryResultsForUI(category, maxN, respectFilters, localOnly, text)
    if not category then return nil end
    maxN = maxN or 3
    if text and Search.uiScoredFor == text and CategoryCovered(Search.uiScoredCategory, category) then
        local filters = respectFilters and EasyFind.db.uiMapFilters
        local stash, mapID = reuseUIScored, Search.uiScoredMapID
        local playerMapID = GetBestMapForUnit("player")
        wipe(reuseUICategoryRows)
        local out, n = reuseUICategoryRows, 0
        -- The current zone's rows first, then the rest as the pass ranked them.
        for pass = 1, localOnly and 1 or 2 do
            for i = 1, #stash do
                if n >= maxN then break end
                local r = stash[i]
                if r.category == category and (not filters or MapSearch.PassesFilter(r, filters)) then
                    local here = playerMapID ~= nil
                        and (r.mapID or r.zoneMapID or r.entranceMapID or mapID) == playerMapID
                    if here == (pass == 1) then
                        n = n + 1
                        local d = reuseUICategoryData[n]
                        if not d then
                            d = {}
                            reuseUICategoryData[n] = d
                        end
                        FillUIRow(d, r, mapID, text, true)
                        out[n] = d
                    end
                end
            end
        end
        return n > 0 and out or nil
    end
    local catDef = ns.MapSearchData and ns.MapSearchData.CATEGORIES
        and ns.MapSearchData.CATEGORIES[category]
    local canonical = catDef and catDef.keywords and catDef.keywords[1] or category
    local rows
    if respectFilters then
        rows = self:SearchForUI(canonical)
    else
        local savedFilters = EasyFind.db.uiMapFilters
        EasyFind.db.uiMapFilters = nil
        rows = self:SearchForUI(canonical)
        EasyFind.db.uiMapFilters = savedFilters
    end
    if not rows then return nil end
    -- Categories fed by the global instance cache (delves, dungeons, raids)
    -- match the canonical keyword identically world-wide, so score order
    -- degrades to name length / alphabetical. Partition current-zone rows to
    -- the front (stable within each half) so "your zone's first" holds for
    -- every category, not just the ones whose sources are local-only.
    -- Zone equality is by the row's mapID; parent/child zone nesting is not
    -- walked -- a subzone row and its parent zone count as different maps.
    local playerMapID = GetBestMapForUnit("player")
    local out, away
    for i = 1, #rows do
        local d = rows[i].data
        if d and d.category == category then
            if playerMapID and d.mapID == playerMapID then
                out = out or {}
                out[#out + 1] = d
            elseif not localOnly then
                away = away or {}
                away[#away + 1] = d
            end
        end
    end
    if away then
        out = out or {}
        for i = 1, #away do
            if #out >= (maxN or 3) then break end
            out[#out + 1] = away[i]
        end
    end
    if not out then return nil end
    for i = #out, (maxN or 3) + 1, -1 do out[i] = nil end
    return out
end
