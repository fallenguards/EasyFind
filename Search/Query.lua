local _, ns = ...

local Search = ns.Search
local Results = ns.Results
local Tooltips = ns.ResultTooltips
local Filters = ns.Filters
local Utils = ns.Utils
local UIPins = ns.UIPins
local SearchText = ns.SearchText

local pairs = Utils.pairs
local InCombatLockdown = InCombatLockdown
local GetTime = GetTime
local slower = SearchText.Normalize
local tinsert = Utils.tinsert
local wipe = wipe

local IsUIItemPinned = UIPins.IsPinned
local collapsedNodes = Results._collapsedNodes
local flatEntries = Results._flatEntries
local flatCombined = Results._flatCombined
local SCRATCH = Results._SCRATCH
local SearchEngine = ns.SearchEngine

local function FlatNameLess(ra, rb)
    local sa, sb = ra.score or 0, rb.score or 0
    if sa ~= sb then return sa > sb end
    -- Rows a provider ordered itself (the clipboard list, newest or
    -- oldest first) keep that order among equal scores; a name sort
    -- would shuffle a timeline.
    local oa, ob = ra.data.clipOrder, rb.data.clipOrder
    if oa and ob and oa ~= ob then return oa < ob end
    -- Map rows keep the map search's order among equal scores: nearest first.
    local ma, mb = ra.data.mapRank, rb.data.mapRank
    if ma and mb and ma ~= mb then return ma < mb end
    local na, nb = ra.data.name or "", rb.data.name or ""
    if #na ~= #nb then return #na < #nb end
    if na ~= nb then return na < nb end
    -- Same name: the Database's fixed category order (talents first), so
    -- the pair never flips with load order.
    local tie = ns.Database and ns.Database.TieCategoryLess
    return tie and tie(ra.data, rb.data) or false
end

-- Alias boost band: far above any natural score so alias rows always sort
-- on top. GetMatches returns matches best-first (ranked by the shared name
-- scorer), so each match gets a score descending by its position and the
-- sort preserves that order. A learned pick (Learned:GetBoost) sits one
-- band below: an explicit alias always beats a learned habit.
local ALIAS_SCORE_BASE = 1e9
-- One band below aliases: a learned pick is a habit the addon inferred, so
-- any alias the user set up deliberately must outrank it.
local LEARNED_SCORE = 1e8
-- Category-word injection (typing "dungeon" surfaces a few dungeons): the
-- rows sit below any row whose NAME the word matches exactly or as a
-- prefix (1000 / 500, "Dungeon Finder"), and above the substring, keyword
-- and typo tiers. Injecting them above everything put three arbitrary
-- dungeons over the Dungeon Finder the moment the word completed, and the
-- list reshuffled at the next letter.
local CATEGORY_ROW_SCORE = 450

-- Identity of a map row across the pooled copies the map search hands out:
-- boosted injections record theirs so the same POI is not shown again when
-- the regular map results append below.
local function MapRowKey(d)
    return (d.nameLower or d.name or "") .. "\1" .. tostring(d.mapID or "")
end
-- Re-run the active search after async data changes (provider loads,
-- item-info arrivals, Database cache resets). A quick-filter browse
-- ("@outfits") has empty text but still needs the re-search once its
-- data finishes loading in the background.
function Search:RefreshActiveSearch()
    local frame = Search:GetSearchFrame()
    if not (frame and frame:IsShown()) then return end
    local typed = Search:GetTypedQuery()
    if typed ~= "" or Search:GetQuickFilter() then
        Search:OnSearchTextChanged(typed, true)
    end
end

local searchRefreshQueued = false
-- Paint hold (see the provider request in OnSearchTextChangedNow): the
-- query whose paint is being held, and the query whose hold already timed
-- out (painted anyway, never held again).
local PAINT_HOLD_MAX = 0.25
-- A pending achievement answer holds for about two frames at most: the
-- ACHIEVEMENT_SEARCH_UPDATED event lands in 12-15 ms (measured), so the
-- cap only matters when the client is late.
local ACH_HOLD_MAX = 0.035
local paintHoldText, paintHoldForcedFor, paintHoldTimerFor
-- Repaint only. Providers that changed the dataset already invalidated
-- through Database:ResetSearchCache, whose coalesced deferred re-run is
-- the single ordered repaint path. Routing THIS callback through the
-- reset nuked the incremental-narrowing caches on every async arrival --
-- item-info responses stream in bursts for seconds after a loot query,
-- so each burst forced full rescans and repaints: visible keystroke lag
-- and result lists swapping after they were already shown.
local lastProviderRefreshAt = 0
local function RefreshSearchAfterProviderLoad(anyChanged)
    if not anyChanged then return end
    if searchRefreshQueued then return end
    searchRefreshQueued = true
    -- Leading edge paints next frame; arrivals inside the trailing window
    -- coalesce into one paint. The staggered warm chain lands one provider
    -- per frame, and the old per-frame coalesce still re-rendered per
    -- provider (41 renders, 3.7MB, in the warmledger); a 0.3s window turns
    -- the chain into a handful of paints without delaying the first one.
    local delay = (GetTime() - lastProviderRefreshAt) > 0.5 and 0 or 0.3
    Utils.SafeAfter(delay, function()
        searchRefreshQueued = false
        lastProviderRefreshAt = GetTime()
        Search:RefreshActiveSearch()
        -- A provider finishing may have added the row a shortkey points at;
        -- rebind any shortkeys skipped because their provider had not loaded
        -- yet. No-op once every shortkey resolves.
        if ns.Shortkeys and ns.Shortkeys.ReapplyIfPending then
            ns.Shortkeys:ReapplyIfPending()
        end
    end)
end

-- GET_ITEM_INFO_RECEIVED arrives async after the client requests item
-- data from the server. Loot stat enrichment ("haste ring") queues the
-- item when GetItemStats returns nil for an uncached item; this handler
-- retries enrichment and refreshes the active search so newly-matchable
-- loot surfaces without the user having to retype.
--
-- Throttled with SafeAfter(0.75) so a burst of arrivals coalesces into
-- one search refresh instead of N. Not snappier: each refresh is a full
-- cold re-score plus render, and a fresh loot cache enriches hundreds of
-- items in a stream; a short coalesce window turns that into a sustained
-- frame-rate collapse while a loot search is open.
local itemInfoFrame = CreateFrame("Frame")
local pendingItemRefresh = false
local function RefreshSearchAfterItemInfo()
    pendingItemRefresh = false
    RefreshSearchAfterProviderLoad(true)
end
-- Listening only while an item's stats are awaited: the event fires for
-- every item the client loads, all session.
function ns.OnStatEnrichmentQueued()
    itemInfoFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
end
itemInfoFrame:SetScript("OnEvent", function(self, _, itemID, success)
    if not ns.Database or not ns.Database.ResolvePendingStatEnrichment then return end
    local enriched = ns.Database:ResolvePendingStatEnrichment(itemID, success)
    if enriched and not pendingItemRefresh then
        pendingItemRefresh = true
        Utils.SafeAfter(0.75, RefreshSearchAfterItemInfo)
    end
    local pending = ns.Database._pendingStatEnrichment
    if not (pending and next(pending)) then self:UnregisterEvent("GET_ITEM_INFO_RECEIVED") end
end)

-- The user-typed query, excluding any inline-autocomplete suffix. Every
-- programmatic re-search must use this instead of editBox:GetText(): with
-- a suggestion showing, GetText() returns the completed candidate ("amani
-- battle bear" for typed "amani"), and re-searching the completed text
-- silently narrows the live results to the suggestion.
function Search:GetTypedQuery()
    local sf = self:GetSearchFrame()
    local eb = sf and sf.editBox
    if not eb then return "" end
    if eb.HasAutocomplete and eb.HasAutocomplete() and eb.GetTypedText then
        return eb.GetTypedText() or ""
    end
    return eb:GetText() or ""
end

-- Stable partition: pinned matches float to the top, non-pinned follow.
-- Each group keeps its score-sorted order. ONE implementation for every
-- rendered list (main results and the "/" command palette) so pin
-- behavior cannot drift between them.
local function FloatPinnedFirst(list, n)
    if n <= 1 then return end
    local pinnedBuf = SCRATCH.pinnedFlat or {}
    SCRATCH.pinnedFlat = pinnedBuf
    local otherBuf = SCRATCH.otherFlat or {}
    SCRATCH.otherFlat = otherBuf
    wipe(pinnedBuf)
    wipe(otherBuf)
    for i = 1, n do
        local e = list[i]
        if e.isPinned then
            pinnedBuf[#pinnedBuf + 1] = e
        else
            otherBuf[#otherBuf + 1] = e
        end
    end
    if #pinnedBuf > 0 and #pinnedBuf < n then
        local out = 0
        for i = 1, #pinnedBuf do
            out = out + 1
            list[out] = pinnedBuf[i]
        end
        for i = 1, #otherBuf do
            out = out + 1
            list[out] = otherBuf[i]
        end
    end
end

-- Every dispatch runs sliced; a new one cancels the run in flight.
-- It yields in SearchUI, the index and the item and creature scans.
local sliceHandle
local pendingSliceText, pendingSliceForce
local function RunPendingSearch()
    Search:OnSearchTextChangedNow(pendingSliceText, pendingSliceForce)
end

-- A run that stops early may sit between index reads, which holds the
-- index build until the next search.
local function SearchRunEnded(ok, err)
    if ok then return end
    if ns.SearchIndex then ns.SearchIndex:ReadCanceled() end
    Utils.ErrorHandler(err)
end

function Search:OnSearchTextChanged(text, force)
    if sliceHandle then
        sliceHandle:Cancel()
        if ns.SearchIndex then ns.SearchIndex:ReadCanceled() end
    end
    pendingSliceText, pendingSliceForce = text, force
    sliceHandle = Utils.RunSliced(RunPendingSearch, SearchRunEnded, 6, "search")
end

local topBuf = {}   -- the top-15 selection's scratch

-- Each search's phases in ms, for the lag probe (searchUI spans its yields;
-- the others run whole, so theirs is CPU).
local timings = {}
Search.lastTimings = timings
local markAt = 0
local function Mark(phase)
    local dps = debugprofilestop
    if not dps then return end
    local now = dps()
    timings[phase] = (timings[phase] or 0) + now - markAt
    markAt = now
end

-- Catalog lines are scored and dropped: no per-name cache entries.
local function ScoreCatalogName(nameLower, ql, qLen)
    return ns.Database:ScoreTransientName(nameLower, ql, qLen)
end

function Search:OnSearchTextChangedNow(text, force)
    -- The search UI is dormant in combat (the bar hides at combat start
    -- and cannot reopen), and rendering results would resize/show frames
    -- that ancestor secure row buttons -- protected operations. Any stray
    -- programmatic call in combat is a silent no-op.
    if InCombatLockdown() then return end
    wipe(timings)
    timings.text = text
    markAt = debugprofilestop and debugprofilestop() or 0
    -- Central guard for the whole caller class: if the incoming text is
    -- the autocomplete-COMPLETED editbox text while a suggestion is live,
    -- search what the user actually typed instead. Callers that pass
    -- editBox:GetText() during a suggestion would otherwise narrow the
    -- results to the suggestion. Accepted suggestions are unaffected
    -- (accepting updates the typed text, so HasAutocomplete is false).
    if text and text ~= "" then
        local guardFrame = Search:GetSearchFrame()
        local guardBox = guardFrame and guardFrame.editBox
        if guardBox and guardBox.HasAutocomplete and guardBox.HasAutocomplete()
           and guardBox.GetTypedText and text == (guardBox:GetText() or "") then
            text = guardBox.GetTypedText() or text
        end
    end
    -- Suppress re-renders while SelectResult is clearing text/focus
    if Search:IsSelectingResult() then return end
    -- A pending OnTextChanged timer can fire after focus has shifted
    -- away from the editbox (user clicked outside, OR clicked an
    -- inline child widget like a slider that StripAutocomplete then
    -- triggers a SetText on via the focus-loss hook). Just bail:
    -- don't re-render, but also don't hide. The outside-click paths
    -- (GLOBAL_MOUSE_DOWN, OnEditFocusLost) decide whether to actually
    -- hide based on cursor position. Calling HideResults here also
    -- tore down the panel during slider drags, which is exactly what
    -- we want to avoid.
    -- `force` lets internal callers (pin/unpin from the right-click
    -- menu) re-render after the pin popup briefly stole focus.
    if not force and Search:GetSearchFrame() and Search:GetSearchFrame().editBox
        and not Search:GetSearchFrame().editBox:HasFocus() then
        return
    end
    -- Treat whitespace-only as empty (pins show on focus, not on blank spaces)
    if text then text = strtrim(text) end
    Tooltips:ClearResultTooltips()
    local quickFilter = self:GetQuickFilter()
    -- @icons owns the whole dropdown: the icon grid renders instead of the
    -- row pipeline, filtered live by whatever follows the token. The grid
    -- lives in the LoadOnDemand companion; first use pulls it in here.
    if quickFilter and quickFilter.key == "icons" then
        if ns.RequestIconSearch and ns.RequestIconSearch() then
            Results:ShowIconGrid(text or "")
        end
        return
    end
    -- A quicklist's pill shows that list's own rows; typing narrows them.
    if quickFilter and quickFilter.quicklistID then
        if ns.Quicklists then ns.Quicklists:ShowView(quickFilter.quicklistID, text) end
        return
    end
    if (not text or text == "") and not quickFilter then
        if ns.Database and ns.Database.CancelDynamicWarmup then
            ns.Database:CancelDynamicWarmup()
        end
        -- Pins stay visible whenever there ARE pins, not only while focused:
        -- they show on bar-open before any typing, and clicking a bar control
        -- (filter or apps button) drops editbox focus and re-runs this path --
        -- which must not then hide the pins the user is looking at. A truly
        -- outside click is handled by the results panel's own click closer.
        local hasFocus = Search:GetSearchFrame() and Search:GetSearchFrame().editBox
            and Search:GetSearchFrame().editBox:HasFocus()
        local hasPins = Results.HasPinnedItems and Results:HasPinnedItems()
        if force or hasFocus or hasPins then
            self:ShowPinnedItems()
        else
            self:HideResults()
        end
        return
    end

    local activeFilters = EasyFind.db.uiSearchFilters
    -- NOT `quickFilter and nil or activeFilters`: `x and nil or y` always
    -- yields y in Lua, which silently fed the filter menu into the engine
    -- under a quick filter and blocked its provider from loading.
    local providerFilters = not quickFilter and activeFilters or nil
    local providerContext = SearchEngine and SearchEngine:BuildContext(text, quickFilter, providerFilters)
    local explicitStatistics = providerContext and SearchEngine
        and SearchEngine.LooksLikeStatistics and SearchEngine:LooksLikeStatistics(providerContext)
    local explicitBosses = providerContext and SearchEngine
        and SearchEngine.LooksLikeBosses and SearchEngine:LooksLikeBosses(providerContext)

    local commandsOff = activeFilters and activeFilters.commands == false
    local commandEntries = (not quickFilter) and (not commandsOff)
        and self:GetSearchBarCommandSuggestionEntries(text)
    if commandEntries then
        FloatPinnedFirst(commandEntries, #commandEntries)
        self:ShowHierarchicalResults(commandEntries)
        return
    end

    wipe(collapsedNodes)
    local calculatorData = (not quickFilter) and self:EvaluateCalculatorExpression(text) or nil
    local calculatorLauncher = (not quickFilter and not calculatorData)
        and self:GetCalculatorLauncherMatch(text) or nil
    -- Inline answers ("gold", "ilvl", "durability"): a live value pinned
    -- above the results, which keep flowing beneath it.
    local answerEntry = (not quickFilter and not calculatorData) and ns.Answers
        and ns.Answers.GetAnswerEntry
        and ns.Answers:GetAnswerEntry(text) or nil
    -- Build skip set from filters so SearchUI avoids scoring/copying filtered categories.
    -- Collection items (mounts/toys/pets/outfits/appearance sets) are
    -- skipped when their own filter is off OR the parent Collections
    -- toggle is off. Loot is independent. Same nil-under-quick-filter
    -- value the engine got: a quick filter ignores the filter menu.
    local filters = providerFilters
    local optionsOff = filters and filters.options == false
    local statisticsOff = filters and filters.statistics == false and not explicitStatistics
    local achHits, achPending
    local skipCategories
    if filters then
        -- Category skip set derives from the shared map so the filter menu,
        -- the providers, and this cascade cannot drift apart.
        if ns.CategoryMap.BuildSkipCategories(filters, SCRATCH.skipCategories,
                explicitStatistics, explicitBosses) then
            skipCategories = SCRATCH.skipCategories
        end
    end
    -- Clipboard history rows are a list to browse under @clipboard, never
    -- a search hit: outside that pill the category is always skipped (a
    -- search for "clipboard" finds the launcher row instead).
    if not (quickFilter and quickFilter.key == "clipboard") then
        if not skipCategories then
            wipe(SCRATCH.skipCategories)
            skipCategories = SCRATCH.skipCategories
        end
        skipCategories["Clipboard"] = true
    end
    local results
    if calculatorData or calculatorLauncher then
        results = SCRATCH.calculatorResults
        wipe(results)
    elseif quickFilter and (not text or text == "") then
        -- Quick-filter browse: no query text, so surface the whole category
        -- (e.g. "@outfits" lists every outfit). SearchUI returns nothing for an
        -- empty query, so collect the category's entries directly here.
        SCRATCH.browseResults = SCRATCH.browseResults or {}
        results = SCRATCH.browseResults
        wipe(results)
        local data = ns.Database.uiSearchData
        local ProviderOf = ns.Extensions and ns.Extensions.ProviderOf
        for i = 1, #data do
            local d = data[i]
            if self:QuickFilterAllowsData(d, quickFilter) then
                -- A provider's browse says which of its rows an empty scope
                -- lists (the quest log, not every quest); every row without it.
                local provider = ProviderOf and ProviderOf(d)
                local browse = provider and provider.browse
                if not browse or browse(d) then
                    results[#results + 1] = { data = d, score = 0 }
                end
            end
        end
    else
        results = ns.Database:SearchUI(text, skipCategories)
        -- Achievement rows come from Blizzard's search string API, which
        -- answers through ACHIEVEMENT_SEARCH_UPDATED about a frame later
        -- (12-15 ms measured). Ask before the paint decision so a pending
        -- answer can hold THIS paint: painting without the rows and again
        -- with them merged in re-sorted the list on nearly every keystroke.
        if text ~= "" and ((quickFilter and quickFilter.key == "achievements")
            or (not quickFilter and (not filters or filters.achievements ~= false))) then
            achHits = self:RequestAchievementSearch(text)
            achPending = achHits == nil and self.IsAchievementSearchPending
                and self:IsAchievementSearchPending(text) or false
        end
    end
    Mark("searchUI")
    if providerContext and not calculatorData and not calculatorLauncher then
        -- A provider this query needs (its trigger word, the low-result
        -- fallback) loads through the urgent scheduler budget: what fits
        -- completes inside this call, the rest lands over the next frames
        -- and repaints via RefreshSearchAfterProviderLoad. Painting first
        -- and again on arrival was a visible reshuffle after typing had
        -- stopped ("bran": the toys, then the teleport jumped to the top).
        -- So a load that completed here re-runs the query into THIS paint,
        -- and a load still pending holds the paint back (the previous
        -- results stay up) until the arrival repaints, or the hold times
        -- out and paints what there is.
        local syncPhase, syncChanged = true, false
        SearchEngine:RequestProviders(providerContext, function(changed)
            if syncPhase then
                if changed then syncChanged = true end
            else
                RefreshSearchAfterProviderLoad(changed)
            end
        end, #results)
        syncPhase = false
        if syncChanged then
            results = ns.Database:SearchUI(text, skipCategories)
            timings.searchedAgain = true
        end
        Mark("providers")
        -- Never held for the first-focus warm chain: on a fresh install
        -- with cold caches that chain runs for seconds, and holding every
        -- keystroke behind it made the search feel a second late (zip test,
        -- 2026-09-05). A load the query itself triggered is held for a
        -- quarter second at most; a pending achievement answer for the
        -- two-frame cap (its event repaints well inside one).
        local pendingLoad = SearchEngine.HasPendingProviders and SearchEngine:HasPendingProviders()
        if (pendingLoad or achPending) and paintHoldForcedFor ~= text then
            paintHoldText = text
            if paintHoldTimerFor ~= text then
                paintHoldTimerFor = text
                local held = text
                Utils.SafeAfter(pendingLoad and PAINT_HOLD_MAX or ACH_HOLD_MAX, function()
                    if paintHoldText == held then
                        paintHoldForcedFor = held
                        Search:RefreshActiveSearch()
                    end
                end)
            end
            return
        end
        paintHoldText = nil
    end

    -- Inject user-defined alias hits at the front. Aliases bypass
    -- bucket filters so a saved shortcut is always reachable, even if
    -- the user has the underlying category turned off in the filter
    -- menu. A target that ALSO matched naturally is still injected (the
    -- alias must promote it to the top, not leave it at its natural
    -- rank; skipping here was GitHub #20) and its natural duplicate is
    -- dropped when `combined` is built, keyed by data identity in
    -- SCRATCH.aliasSeen, which must stay populated until then.
    wipe(SCRATCH.aliasSeen)
    SCRATCH.aliasSeenKeys = SCRATCH.aliasSeenKeys or {}
    wipe(SCRATCH.aliasSeenKeys)
    -- A promoted row (alias or learned pick) is remembered by object AND
    -- by row key: a pick resolved through the key index or a snapshot can
    -- be a different table than the natural row for the same thing, and
    -- identity alone then let the natural copy through (the pick at the
    -- top and the row again in its place, zip test 2026-09-05).
    local function MarkPromoted(promoted, data)
        promoted[data] = true
        local key = ns.Aliases and ns.Aliases.GetEntryKey and ns.Aliases:GetEntryKey(data)
        if key then SCRATCH.aliasSeenKeys[key] = true end
    end
    local function IsPromoted(promoted, data)
        if promoted[data] then return true end
        if next(SCRATCH.aliasSeenKeys) == nil then return false end
        local key = ns.Aliases and ns.Aliases.GetEntryKey and ns.Aliases:GetEntryKey(data)
        return key and SCRATCH.aliasSeenKeys[key] or false
    end
    -- The map pass first: a category boost below reads its rows instead
    -- of running a pass of its own.
    local mapResults
    if not calculatorData and not calculatorLauncher and ns.MapSearch and ns.MapSearch.SearchForUI
       and ((quickFilter and quickFilter.key == "map")
            or (not quickFilter and filters and filters.map ~= false)) then
        mapResults = ns.MapSearch:SearchForUI(text)
    end
    Mark("map")
    local mapPass = ns.MapSearchSearch and ns.MapSearchSearch.uiSearchCount
    wipe(SCRATCH.mapBoostSeen)
    wipe(SCRATCH.catalogBoostSeen)
    local seenMapRows = SCRATCH.mapBoostSeen
    -- Catalog rows are rebuilt per query (never shared tables), so identity
    -- dedupe in aliasSeen cannot catch them; promoted catalog picks register
    -- their itemID here and the natural ItemSearch hit is skipped.
    local seenCatalogItems = SCRATCH.catalogBoostSeen
    if ns.Aliases then
        local aliasMatches = ns.Aliases:GetMatches(slower(text))
        if aliasMatches then
            local promoted = SCRATCH.aliasSeen
            for i = #aliasMatches, 1, -1 do
                local hit = aliasMatches[i]
                local data = hit.data
                -- Stride of 10 leaves room for a category alias to expand
                -- into several rows that stay together, in order, inside
                -- this alias's slot of the band.
                local aliasScore = ALIAS_SCORE_BASE - i * 10
                if data and data.mapCategoryAlias then
                    -- Expand to the nearest rows of the category. The rows
                    -- are pooled by the map search, so inject copies.
                    local catRows = ns.MapSearch and ns.MapSearch.GetCategoryResultsForUI
                        and ns.MapSearch:GetCategoryResultsForUI(data.mapCategoryAlias, 3, nil, nil, text)
                    if catRows then
                        for j = #catRows, 1, -1 do
                            local wrapped = {}
                            for k, v in pairs(catRows[j]) do wrapped[k] = v end
                            wrapped.query = (hit.alias and hit.alias.text) or text
                            seenMapRows[MapRowKey(wrapped)] = true
                            tinsert(results, 1, { data = wrapped, score = aliasScore - j, isAlias = true })
                        end
                    end
                elseif data and data.mapSearchResult then
                    local wrapped = {}
                    for k, v in pairs(data) do wrapped[k] = v end
                    wrapped.query = (hit.alias and hit.alias.text) or text
                    seenMapRows[MapRowKey(wrapped)] = true
                    tinsert(results, 1, { data = wrapped, score = aliasScore, isAlias = true })
                elseif data and not IsPromoted(promoted, data) then
                    MarkPromoted(promoted, data)
                    if data.catalogItem and data.itemID then
                        seenCatalogItems[data.itemID] = true
                    end
                    tinsert(results, 1, { data = data, score = aliasScore, isAlias = true })
                end
            end
        end
    end

    -- Default local-category boost (GitHub #21): a query that IS a category
    -- keyword ("flight", "fm", "delve") surfaces that category with your
    -- current zone's results first, no setup. Always on for category words
    -- (the ambiguous-word exclusions in KEYWORD_TO_CATEGORY are the hijack
    -- guard); the flyout scope decides breadth: "all" pins up to 3 rows,
    -- zone-local first, above the normal world list; "local" injects only
    -- the current zone's rows and suppresses the category's other-zone rows
    -- from the list below (a deliberate "just what's around me" mode).
    -- Skipped under a quick filter, when the map bucket is off, or for
    -- calculator queries; rows an alias already injected are not repeated.
    local suppressMapCategory
    if not quickFilter
       and (not filters or filters.map ~= false)
       and not calculatorData and not calculatorLauncher then
        local boostCat = ns.MapSearchData and ns.MapSearchData.KEYWORD_TO_CATEGORY
            and ns.MapSearchData.KEYWORD_TO_CATEGORY[slower(text)]
        local localScope = boostCat and EasyFind.db.mapCategoryScope == "local"
        local catRows = boostCat and ns.MapSearch and ns.MapSearch.GetCategoryResultsForUI
            and ns.MapSearch:GetCategoryResultsForUI(boostCat, localScope and 8 or 3, true, localScope, text)
        if localScope then
            suppressMapCategory = boostCat
        end
        if catRows then
            for j = #catRows, 1, -1 do
                local src = catRows[j]
                local rowKey = MapRowKey(src)
                if not seenMapRows[rowKey] then
                    seenMapRows[rowKey] = true
                    local wrapped = {}
                    for k, v in pairs(src) do wrapped[k] = v end
                    tinsert(results, 1, { data = wrapped, score = CATEGORY_ROW_SCORE - j, isAlias = true })
                end
            end
        end
    end

    -- Learned pick: the result chosen the last time this exact query was
    -- typed boosts to the top, one band below aliases. Rides the same
    -- promotion/dedupe machinery, so an alias to the same row wins and the
    -- natural duplicate drops at the combined build. A learned MAP row
    -- registers in seenMapRows (2.4.2 machinery, newer than this feature's
    -- base) so the pooled natural copy is deduped like any other boost.
    if ns.Learned then
        local learned, olderPicks = ns.Learned:GetBoost(slower(text))
        -- A remembered pick obeys the filter menu like any natural hit: a
        -- category the user has unchecked (or the General Catalog, for a
        -- catalog item) stays hidden however often it was picked, and a
        -- quick filter admits only what it admits.
        local function LearnedAllowed(e)
            if not e then return false end
            if quickFilter and not self:QuickFilterAllowsData(e, quickFilter) then return false end
            if skipCategories and e.category and skipCategories[e.category] then return false end
            if e.catalogItem and filters
               and ns.CategoryMap.IsProviderFilterOff(filters, "catalog") then
                return false
            end
            return true
        end
        if learned then
            local promoted = SCRATCH.aliasSeen
            -- The query's other remembered picks sit right under the
            -- first-ranked one, in frecency order (how often and how
            -- recently each was chosen); inserted first so the lead lands
            -- above them.
            if olderPicks and not learned.mapSearchResult then
                for i = #olderPicks, 1, -1 do
                    local e = olderPicks[i]
                    if not e.mapSearchResult and LearnedAllowed(e) and not IsPromoted(promoted, e) then
                        MarkPromoted(promoted, e)
                        if e.catalogItem and e.itemID then seenCatalogItems[e.itemID] = true end
                        tinsert(results, 1, { data = e, score = LEARNED_SCORE - i, isAlias = true })
                    end
                end
            end
            if learned.mapSearchResult then
                -- Picked for a kind of place (inn, repair): the nearest of
                -- its kind among this search's map rows, not the one picked
                -- somewhere else; none of it here, no boost.
                local src = learned
                if ns.MapSearch.IsKindQuery and ns.MapSearch:IsKindQuery(text) then
                    src = nil
                    local best = math.huge
                    for ri = 1, mapResults and #mapResults or 0 do
                        local d = mapResults[ri].data
                        if d and d.category == learned.category then
                            local near = d.mapNear or math.huge
                            if not src or near < best then src, best = d, near end
                        end
                    end
                end
                if src then
                    local wrapped = {}
                    for k, v in pairs(src) do wrapped[k] = v end
                    wrapped.query = text
                    -- The pick it stands for, for Forget this pick.
                    wrapped.learnedFrom = learned
                    seenMapRows[MapRowKey(wrapped)] = true
                    tinsert(results, 1, { data = wrapped, score = LEARNED_SCORE, isAlias = true })
                end
            elseif LearnedAllowed(learned) and not IsPromoted(promoted, learned) then
                MarkPromoted(promoted, learned)
                if learned.catalogItem and learned.itemID then
                    seenCatalogItems[learned.itemID] = true
                end
                tinsert(results, 1, { data = learned, score = LEARNED_SCORE, isAlias = true })
            end
        end
    end

    -- Feature-owned query: typing toward "Snippets" ITSELF (the query is
    -- a prefix of the feature's name) orders the feature rows first --
    -- the Snippets menu, then Create snippet -- above any learned
    -- individual snippet, which otherwise sits oddly on top of its own
    -- feature's front door. A snippet searched by its OWN name or keyword
    -- takes no part in this: the override only ever touches the two
    -- feature rows, and only for feature-name queries.
    do
        local q = slower(text)
        local featureName = slower(ns.L and ns.L["FILTER_SNIPPETS"] or "snippets")
        if #q >= 3 and (featureName:sub(1, #q) == q or ("snippets"):sub(1, #q) == q) then
            for ri = 1, #results do
                local d = results[ri].data
                if d and d.snippetsLauncher then
                    results[ri].score = LEARNED_SCORE + 2
                elseif d and d.snippetCreate then
                    results[ri].score = LEARNED_SCORE + 1
                end
            end
        end
    end

    if quickFilter then
        wipe(SCRATCH.quickFilterResults)
        local filtered = SCRATCH.quickFilterResults
        local fi = 0
        for ri = 1, #results do
            local r = results[ri]
            if r and self:QuickFilterAllowsData(r.data, quickFilter) then
                fi = fi + 1
                filtered[fi] = r
            end
        end
        for i = fi + 1, #filtered do filtered[i] = nil end
        results = filtered
    end

    -- Bucket-aware Search filter: drop Search entries whose bucket
    -- (abilities / achievements / currencies / reputations / bags /
    -- options) is unchecked. Base Search entries have no bucket and are
    -- always searchable. Options is a parent toggle: when off, both
    -- gameOptions and addonOptions buckets are treated as off.
    -- abilityHidePassives also drops isPassive ability rows here so
    -- the filter applies regardless of which bucket is on.
    local hidePassives = EasyFind.db.abilityHidePassives
    local hideAchievementHeaders = EasyFind.db.hideAchievementHeaders
    local hideGuildAchievements = EasyFind.db.hideGuildAchievements
    local macroGeneralOff = EasyFind.db.macroFilterGeneral == false
    local macroCharOff = EasyFind.db.macroFilterChar == false
    local bossDungeonOff = EasyFind.db.bossFilterDungeon == false
    local bossRaidOff = EasyFind.db.bossFilterRaid == false
    local hideJunk = EasyFind.db.bagHideJunk == true
    -- Statistics carry a live value, so this is filtered HERE rather than at
    -- populate: the populate path also writes the persisted statistic cache,
    -- and filtering there would bake the choice into the cache and force a
    -- re-scan on every change. Query-time also keeps it honest as values
    -- change during play. "all" costs nothing -- the gate below stays off.
    local statMode = EasyFind.db.statisticFilterMode
    if statMode == "all" then statMode = nil end
    local specRowsOff = EasyFind.db.talentShowSpecs == false
    local loadoutRowsOff = EasyFind.db.talentShowLoadouts == false
    local commandNativeOff = EasyFind.db.commandShowNative == false
    local commandCustomOff = EasyFind.db.commandShowCustom == false
    -- The switches under AddOn Options: a settings row carries its addon.
    local addonFilters = EasyFind.db.addonOptionsFilters
    local anyAddonOff = addonFilters ~= nil and next(addonFilters) ~= nil
    -- The Skills flyout's switches: a skill row carries its heading.
    local skillSwitches = EasyFind.db.skillFilters
    local anySkillOff = type(skillSwitches) == "table" and next(skillSwitches) ~= nil
    local bossesFilterOff = filters and filters.bosses == false and not explicitBosses
    local statisticsFilterOff = filters and filters.statistics == false and not explicitStatistics
    if filters and (filters.abilities == false or bossesFilterOff
                    or filters.achievements == false or statisticsFilterOff
                    or filters.currencies == false or filters.reputations == false
                    or filters.bags == false or filters.bank == false
                    or filters.macros == false
                    or filters.options == false
                    or filters.gameOptions == false or filters.addonOptions == false
                    or filters.titles == false or filters.gearSets == false
                    or filters.skills == false
                    or filters.talents == false or filters.commands == false
                    or hidePassives or hideAchievementHeaders or hideGuildAchievements
                    or macroGeneralOff or macroCharOff or bossDungeonOff or bossRaidOff
                    or hideJunk or commandNativeOff or commandCustomOff
                    or statMode or specRowsOff or loadoutRowsOff or anyAddonOff or anySkillOff) then
        wipe(SCRATCH.filteredResults)
        local filtered = SCRATCH.filteredResults
        local fi = 0
        for ri = 1, #results do
            local r = results[ri]
            if r.isAlias then
                fi = fi + 1
                filtered[fi] = r
            else
                local d = r.data
                local bucket = Filters:GetUIBucket(d)
                local bucketOff = bucket and filters[bucket] == false
                if (explicitStatistics and bucket == "statistics")
                   or (explicitBosses and bucket == "bosses") then
                    bucketOff = false
                end
                local parentOff = optionsOff
                    and (bucket == "gameOptions" or bucket == "addonOptions")
                local passiveOff = hidePassives and d and d.category == "Ability" and d.isPassive
                local headerOff = hideAchievementHeaders and d
                    and d.category == "Achievement Category"
                local guildAchievementOff = hideGuildAchievements and self:IsGuildAchievementData(d)
                local macroTypeOff = d and d.category == "Macro"
                    and ((d.macroIsChar and macroCharOff) or (not d.macroIsChar and macroGeneralOff))
                local bossTypeOff = d and d.category == "Boss"
                    and ((d.isRaidBoss and bossRaidOff) or (not d.isRaidBoss and bossDungeonOff))
                local junkOff = hideJunk and d and d.category == "Bag" and d.quality == 0
                local statOff = false
                if statMode and d and d.statisticID then
                    local _, hasValue = ns.GetStatisticValue(d.statisticID)
                    statOff = (statMode == "recorded") ~= hasValue
                end
                local talentSwapOff = d and ((d.specSetIndex and specRowsOff)
                    or (d.loadoutConfigID and loadoutRowsOff))
                local commandTypeOff = d and d.category == "Command"
                    and ((d.isNativeCommand and commandNativeOff) or (not d.isNativeCommand and commandCustomOff))
                local addonOff = anyAddonOff and d and d.addon ~= nil and addonFilters["addon:" .. d.addon] == false
                local skillOff = anySkillOff and d and d.skillHeader ~= nil and skillSwitches[d.skillHeader] == false
                if not passiveOff and not headerOff and not guildAchievementOff
                   and not macroTypeOff and not bossTypeOff and not junkOff
                   and not commandTypeOff and not statOff and not talentSwapOff and not addonOff and not skillOff
                   and (not bucket or (not bucketOff and not parentOff)) then
                    fi = fi + 1
                    filtered[fi] = r
                end
            end
        end
        for i = fi + 1, #filtered do filtered[i] = nil end
        results = filtered
    end

    -- Currency filter mode: kept in DB so it can drive bidirectional
    -- sync with the in-game CurrencyFrame's filter dropdown later, but
    -- we deliberately don't prune our own search results here. The
    -- in-game tab shows every currency the character has discovered
    -- (zero-quantity warband-transferable ones included), and an
    -- earlier per-cache `isAccountTransferable` check was hiding some
    -- of those because the flag's truthiness varied across builds.
    -- Showing everything keeps search at least as inclusive as the
    -- in-game tab regardless of what mode is selected.

    -- A boost that ran a pass of its own rewrote the pooled map rows.
    if mapResults and ns.MapSearchSearch.uiSearchCount ~= mapPass then
        Mark("rows")
        mapResults = ns.MapSearch:SearchForUI(text)
        Mark("mapAgain")
    end

    wipe(flatCombined)
    local combined = flatCombined
    if calculatorData then
        -- Math row at the top; launcher row sits beneath it so the user
        -- can open the popup with the current expression. Two distinct
        -- scores so the math row always sorts above (math.huge - 1 is
        -- still math.huge in IEEE doubles, so use a finite huge instead).
        combined[#combined + 1] = { data = calculatorData, score = math.huge }
        combined[#combined + 1] = { data = ns.Calculator._calculator.LAUNCHER, score = 1e308 }
    elseif calculatorLauncher then
        combined[#combined + 1] = { data = calculatorLauncher, score = math.huge }
    end
    if answerEntry then
        combined[#combined + 1] = { data = answerEntry, score = math.huge }
    end
    -- Skip the natural copy of any alias-promoted row (see the alias
    -- injection above); the isAlias wrapper at the front is the one shown.
    local promoted = SCRATCH.aliasSeen
    for ri = 1, #results do
        local r = results[ri]
        if r.isAlias or not IsPromoted(promoted, r.data) then
            combined[#combined + 1] = r
        end
    end
    if mapResults then
        -- Skip POIs a boost already put on top (alias or local-category);
        -- the same place twice in one list reads as a bug. In "this zone
        -- only" scope, also drop the boosted category's rows from other
        -- zones: the injection above holds the complete local set, so
        -- anything of that category left here is by definition elsewhere.
        local boostedMapRows = SCRATCH.mapBoostSeen
        for ri = 1, #mapResults do
            local r = mapResults[ri]
            if not (r.data and (boostedMapRows[MapRowKey(r.data)]
                    or (suppressMapCategory and r.data.category == suppressMapCategory))) then
                combined[#combined + 1] = r
            end
        end
    end
    -- Catalog items: the full game item DB (Search/ItemSearch.lua scans the
    -- packed blob). Appended BEFORE the sort/cap so they compete for the
    -- TOP_N slots by the same ScoreName relevance rather than flooding past
    -- it. Gated on the General Catalog sub-filter (@gen, or its @items
    -- umbrella parent); IsProviderFilterOff walks the items-parent cascade
    -- so unchecking Items hides all three overlays. English-primary; display
    -- name and icon resolve live at render.
    if not calculatorData and not calculatorLauncher and text ~= "" and ns.ItemSearch
       and ns.Database and ns.Database.ScoreTransientName
       and ((quickFilter and (quickFilter.key == "items" or quickFilter.key == "catalog"))
            or (not quickFilter and (not filters
                 or not ns.CategoryMap.IsProviderFilterOff(filters, "catalog")))) then
        Mark("rows")
        local itemHits = ns.ItemSearch:Search(text, ScoreCatalogName)
        Mark("catalog")
        if itemHits then
            for ii = 1, #itemHits do
                local hitData = itemHits[ii].data
                if not (hitData and hitData.itemID and seenCatalogItems[hitData.itemID]) then
                    combined[#combined + 1] = itemHits[ii]
                end
            end
        end
    end

    -- Extension launcher rows (GitHub #22): typing an extension's name or
    -- one of its words offers the row that opens it. Scored into the band
    -- above natural matches but below aliases and learned picks.
    if not quickFilter and not calculatorData and not calculatorLauncher and ns.Extensions then
        local launchers = ns.Extensions.LauncherMatches(text, wipe(SCRATCH.launchers))
        for li = 1, #launchers do
            combined[#combined + 1] = { data = launchers[li], score = 2e6 }
        end
    end
    -- Under @notes a query that is no note's title offers to make one so
    -- titled, last in the list.
    if quickFilter and quickFilter.key == "notes" and text ~= "" and ns.Notes and ns.Notes.NewFromSearch then
        local lower = slower(text)
        local titled = false
        for ri = 1, #combined do
            local d = combined[ri].data
            if d and d.noteID and d.nameLower == lower then titled = true break end
        end
        if not titled then
            local title = text
            combined[#combined + 1] = { score = 1, data = {
                name = Utils.sformat(ns.L["NOTES_ROW_NEW_FMT"], title), category = "Notes",
                searchCommandDesc = ns.L["NOTES_ROW_NEW_SUB"], icon = ns.NOTES_ICON_TEX,
                noteCreate = true, noPin = true, noLearn = true,
                nativeRun = function() ns.Notes.NewFromSearch(title) end,
            } }
        end
    end
    -- The client's achievement hits, ranked by name with the rest before the cap.
    if achHits then
        if ns.Database and ns.Database.ScoreName then
            local lowerQ = slower(text)
            local qLen = #lowerQ
            -- Name hits only (the index also matches descriptions); the cache
            -- can predate the stats data, so statistics are checked again.
            for ai = 1, #achHits do
                local entry = achHits[ai]
                local score = ns.Database:ScoreName(entry.nameLower, lowerQ, qLen)
                if score and score > 0
                   and not IsPromoted(SCRATCH.aliasSeen, entry)
                   and not (hideGuildAchievements and self:IsGuildAchievementData(entry))
                   and not (statisticsOff and entry.achievementID
                            and ns.Database:IsStatisticAchievement(entry.achievementID)) then
                    combined[#combined + 1] = { data = entry, score = score }
                end
            end
        end
    end

    -- Blacklist gate: every source has joined (map rows, catalog items and
    -- launchers too); before the cap, so a hidden row frees its slot.
    if ns.Blacklist then ns.Blacklist:FilterRows(combined) end
    -- Hard cap on visible results: the scoring step already ranks by
    -- relevance; everything past the cap is noise. Pinned items are not in
    -- this set. The top 15 come from a bounded insertion (a full sort of
    -- hundreds of rows cost up to half a millisecond a keystroke); catalog
    -- rows this client cannot resolve are skipped as they would enter, so
    -- the resolvable check runs on few rows, not on every scored match.
    local TOP_N = 15
    local kept = 0
    for ri = 1, #combined do
        local entry = combined[ri]
        local d = entry.data
        if kept < TOP_N or FlatNameLess(entry, topBuf[kept]) then
            if not (d and d.catalogItem and ns.ItemSearch
                    and not ns.ItemSearch:IsResolvable(d.itemID)) then
                local at = kept < TOP_N and kept + 1 or kept
                while at > 1 and FlatNameLess(entry, topBuf[at - 1]) do
                    topBuf[at] = topBuf[at - 1]
                    at = at - 1
                end
                topBuf[at] = entry
                if kept < TOP_N then kept = kept + 1 end
            end
        end
    end
    for ri = 1, kept do combined[ri] = topBuf[ri] end
    for ri = #combined, kept + 1, -1 do combined[ri] = nil end
    wipe(topBuf)

    -- @map: the map tab's This Zone and Across the World parts.
    local mapSplit = quickFilter and quickFilter.key == "map" and ns.MapSearch and ns.MapSearch.SplitUIRowsByZone
    if mapSplit then ns.MapSearch:SplitUIRowsByZone(combined) end

    local n = 0
    local lastGroup
    for ri = 1, #combined do
        local d = combined[ri] and combined[ri].data
        if d then
            -- Rows that carry a group label (clipboard history's Today,
            -- Yesterday, ...; @map's This Zone) get a section divider where
            -- the label changes: a header row, not a result, drawn by
            -- ResultHeader and skipped by selection like the pin header.
            local group = d.clipGroup or (mapSplit and d.sectionLabel)
            if group and group ~= lastGroup then
                lastGroup = group
                n = n + 1
                local h = flatEntries[n]
                if not h then
                    h = {}
                    flatEntries[n] = h
                end
                h.name = group
                h.depth = 0
                h.isPathNode = false
                h.isSectionHeader = true
                h.isMatch = false
                h.isFlat = true
                h.flatCatKey = nil
                h.isPinned = false
                h.data = nil
            end
            -- A divider-only entry (the clipboard list's empty state) is
            -- its divider and nothing else: no row to select or click.
            if not d.clipDividerOnly then
                n = n + 1
                local e = flatEntries[n]
                if not e then
                    e = {}
                    flatEntries[n] = e
                end
                e.name = d.name
                e.depth = 0
                e.isPathNode = false
                e.isSectionHeader = false
                e.isMatch = true
                e.isFlat = true
                e.flatCatKey = nil
                e.isPinned = (not d.noPin and IsUIItemPinned(d)) and true or false
                e.data = d
            end
        end
    end
    for i = n + 1, #flatEntries do
        flatEntries[i] = nil
    end

    FloatPinnedFirst(flatEntries, n)
    Mark("combine")

    self:ShowHierarchicalResults(flatEntries)
    Mark("render")
end
