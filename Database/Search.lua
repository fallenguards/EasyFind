local _, ns = ...

---@class SearchResult
---@field data table the underlying entry (mount/toy/UI node/etc.)
---@field score number ranking score, higher is better
---@field isAlias boolean? true when this row was resolved from a saved alias

local Database = ns.Database
local Utils = ns.Utils
local SearchText = ns.SearchText

if not Database then return end

local tsort = Utils.tsort
local sfind, ssub = Utils.sfind, Utils.ssub
local sgsub = string.gsub
local sbyte = string.byte
local band, bor, bnot, lshift = bit.band, bit.bor, bit.bnot, bit.lshift
local tconcat = table.concat
local tremove = table.remove

-- All search-side casing flows through SearchText.Normalize so non-ASCII
-- (German umlauts, French accents, etc.) lowercase correctly. WoW's
-- string.lower is ASCII-only and would leave "ÜBERMACHT" partially
-- uppercase. Normalize is ASCII-fast-path internally for the common case.
local slower = SearchText.Normalize
local stokenize = SearchText.Tokenize
local isAscii = SearchText.IsAscii
local mmin, mmax, mabs, mfloor = Utils.mmin, Utils.mmax, Utils.mabs, Utils.mfloor
local wipe = wipe
local rawget = rawget
local SliceCheckpoint = Utils.SliceCheckpoint
local uiSearchData = Database.uiSearchData

local function IsLootStatSearchWord(word)
    return Database:IsLootStatSearchWord(word)
end

local function IsLootSlotSearchWord(word)
    return Database:IsLootSlotSearchWord(word)
end

local BOSS_QUERY_WORDS = ns.BOSS_QUERY_WORDS
local STAT_QUERY_WORDS = ns.STAT_QUERY_WORDS

-- Word lists per string, bounded by the dataset's names and keywords (a
-- FIFO thrashed). Names scored once and dropped (the item catalog) go
-- through ScoreTransientName and are never cached.
local wordCache = {}
Database._wordCache = wordCache
local EMPTY_WORDS = {}
-- The name ScoreTransientName is scoring, and its words, filled on first use.
local transientName
local transientWords, transientFilled = {}, false

-- ASCII path uses gmatch which is fast and well-tested; non-ASCII routes
-- through SearchText.Tokenize so "Übermacht" splits at the right places
-- (the %w pattern only matches ASCII alphanumerics).
local function GetWords(str)
    if not str or str == "" then return EMPTY_WORDS end
    local cached = wordCache[str]
    if cached then return cached end
    if str == transientName then
        if not transientFilled then
            transientFilled = true
            wipe(transientWords)
            if isAscii(str) then
                for w in str:gmatch("[%w']+") do transientWords[#transientWords + 1] = w end
            else
                local t = stokenize(str)
                for i = 1, #t do transientWords[i] = t[i] end
            end
        end
        return transientWords
    end
    local words
    if isAscii(str) then
        words = {}
        for w in str:gmatch("[%w']+") do
            words[#words + 1] = w
        end
    else
        words = stokenize(str)
    end
    wordCache[str] = words
    return words
end

local SEARCH_WORD_SYNONYMS = {
    tmog = "transmog",
    xmog = "transmog",
}

---Rewrites recognized search-word synonyms (tmog/xmog -> transmog) so
---matching is consistent regardless of which form the user typed.
---@param query string?
---@return string?
function Database:NormalizeSearchQuery(query)
    if not query or query == "" then return query end
    return (sgsub(query, "%f[%w](%w+)%f[%W]", SEARCH_WORD_SYNONYMS))
end

local dlPrev2, dlPrev, dlCurr = {}, {}, {}

local scoreNameUsedWords = {}

-- Ties break to the shorter name (standard field-length normalization: for
-- equal match quality, "Eastern Kingdoms" beats "Eastern Kingdoms Map"),
-- then alphabetically so equal-length ties stay stable across re-sorts.
-- Same score, same name (Swipe the ability and Swipe the talent are two
-- rows): a fixed order, or the pair flips between sessions with provider
-- load order. Talents lead, then the category name.
local TIE_CATEGORY_RANK = { Talent = 1, Talents = 1 }
local function TieCategoryLess(a, b)
    local ac, bc = a.category or "", b.category or ""
    if ac == bc then return false end
    local ar, br = TIE_CATEGORY_RANK[ac] or 9, TIE_CATEGORY_RANK[bc] or 9
    if ar ~= br then return ar < br end
    return ac < bc
end
Database.TieCategoryLess = TieCategoryLess

local function scoreDescending(a, b)
    if a.score ~= b.score then return a.score > b.score end
    local an, bn = a.data.nameLower or "", b.data.nameLower or ""
    if #an ~= #bn then return #an < #bn end
    if an ~= bn then return an < bn end
    return TieCategoryLess(a.data, b.data)
end

-- The kept results are a heap whose root is the worst kept row, so the best
-- RESULT_CAP of any number of matches cost one pass and one small sort.
local RESULT_CAP = 250
local heapProbe = {}
-- The best a row can score from a mid-word name substring alone (ScoreName's
-- last tier; ScoreKeywords has no mid-word tier): the index's "rest" rows.
local REST_MAX_SCORE = 30

local function HeapUp(heap, i)
    local item = heap[i]
    while i > 1 do
        local p = (i - i % 2) / 2
        local parent = heap[p]
        if not scoreDescending(parent, item) then break end
        heap[i] = parent
        i = p
    end
    heap[i] = item
end

local function HeapDown(heap, n)
    local i, item = 1, heap[1]
    while true do
        local c = i * 2
        if c > n then break end
        if c < n and scoreDescending(heap[c], heap[c + 1]) then c = c + 1 end
        local child = heap[c]
        if not scoreDescending(item, child) then break end
        heap[i] = child
        i = c
    end
    heap[i] = item
end

-- Suppresses fuzzy/initials matches between word pairs that are close in
-- edit distance but semantically opposite.
local FUZZY_BLOCKLIST = {
    ["pvp"] = { ["pve"] = true },
    ["pve"] = { ["pvp"] = true },
    -- "ability"/"abilities" are keywords on every Ability entry; without
    -- this, typing "agility" drags every ability into results.
    ["agility"]   = { ["ability"] = true, ["abilities"] = true },
    ["ability"]   = { ["agility"] = true },
    ["abilities"] = { ["agility"] = true },
}

-- English function words. Two uses: Initials Strategy 2 may step over them
-- for free ("lfg" = Looking For Group, "tot" = Throne of Thunder) while a
-- non-stopword content word that doesn't match breaks the chain; and a bare
-- stopword QUERY only matches where it extends into a longer word ("the" ->
-- Theramore) -- the standalone word appears in hundreds of names ("The X",
-- "Y of the Z") and carries no signal.
local STOPWORDS = {
    ["of"] = true, ["the"] = true, ["a"] = true, ["an"] = true,
    ["and"] = true, ["or"] = true, ["in"] = true, ["on"] = true,
    ["at"] = true, ["by"] = true, ["for"] = true, ["to"] = true,
    ["with"] = true, ["from"] = true,
}

-- A query that exactly equals an entry's whole name is its own top tier.
-- Every other path caps at 200 EXCEPT the loot scorer, which SUMS per-word
-- scores (up to ~140 each), so a multi-word loot entry containing the query
-- words ("Scouting Map: The Eastern Kingdoms Campaign") could outrank the
-- perfect match ("Eastern Kingdoms") on any 200-scale value.
local EXACT_MATCH_SCORE = 1000
-- A name that starts with everything typed so far is the second tier: the
-- user is mid-word in THAT name ("eastern king" -> "Eastern Kingdoms"), so
-- word-sum paths (ScoreEntryFields reaches 210 on two words, loot sums
-- higher) must not demote it between keystrokes.
local NAME_PREFIX_SCORE = 500

-- Strongest way a bare stopword query extends into a LONGER word of `text`:
-- 3 = prefix of the first word ("the" -> "Theramore Isle"), 2 = prefix of a
-- later word, 1 = inside a word ("the" -> "Aetheril"), 0 = only standalone
-- occurrences (no signal). Callers map tiers onto their own score scale.
local function StopwordExtension(text, query, queryLen)
    local words = GetWords(text)
    local best = 0
    for wi = 1, #words do
        local w = words[wi]
        if #w > queryLen then
            if sfind(w, query, 1, true) == 1 then
                if wi == 1 then return 3 end
                if best < 2 then best = 2 end
            elseif best < 1 and sfind(w, query, 1, true) then
                best = 1
            end
        end
    end
    return best
end

---True if `query` appears in `text` at the start or after a word
---separator (space, hyphen, paren, colon, slash, period).
---@param text string
---@param query string
---@return boolean
function Database:FindAtWordBoundary(text, query)
    local found = sfind(text, query, 1, true)
    if not found then return false end
    if found == 1 then return true end
    -- 32=space 45=- 40=( 58=: 47=/ 46=.
    while found do
        local prev = sbyte(text, found - 1)
        if prev == 32 or prev == 45 or prev == 40
           or prev == 58 or prev == 47 or prev == 46 then
            return true
        end
        found = sfind(text, query, found + 1, true)
    end
    return false
end

function Database:ScoreInitials(text, query)
    local words = GetWords(text)
    if #words < 2 then return 0 end

    local blocked = FUZZY_BLOCKLIST[query]
    if blocked then
        for wi = 1, #words do
            if blocked[words[wi]] then return 0 end
        end
    end

    local queryLen = #query
    local numWords = #words

    -- Strategy 1: pure initials. "rb" -> R(ated) B(attlegrounds).
    if queryLen <= numWords then
        local allMatch = true
        for i = 1, queryLen do
            if sbyte(query, i) ~= sbyte(words[i], 1) then
                allMatch = false
                break
            end
        end
        if allMatch then
            local bonus = (queryLen == numWords) and 135 or 130
            return bonus
        end
    end

    -- Strategy 2: greedy word-prefix walk. "raba" -> ra(ndom) ba(ttleground).
    -- Stopwords may be skipped (so "tot" -> Throne Of Thunder works).
    local qi = 1
    local wordsMatched = 0
    for wi = 1, numWords do
        if qi > queryLen then break end
        local w = words[wi]
        local matchLen = 0
        while qi + matchLen <= queryLen and matchLen < #w do
            if sbyte(query, qi + matchLen) == sbyte(w, matchLen + 1) then
                matchLen = matchLen + 1
            else
                break
            end
        end
        -- A single leading char is not an abbreviation segment here:
        -- 1-char crumbs let ordinary words assemble out of unrelated
        -- names ("rate" -> RA(shok) T(he) E(lder), score 119). True
        -- initials runs ("tot" -> Throne of Thunder) are Strategy 1's
        -- job, so this walk only accepts 2+ char prefixes per word.
        if matchLen >= 2 then
            qi = qi + matchLen
            wordsMatched = wordsMatched + 1
        elseif wordsMatched > 0 and not STOPWORDS[w] then
            break
        end
    end
    if qi > queryLen and wordsMatched >= 2 then
        return 110 + mmin(wordsMatched * 3, 20)
    end

    return 0
end

-- The fuzzy/abbreviation widening envelope. Everything that gates on length
-- -- the scorers' edit budgets, the search gate's allowance, and the
-- incremental-recall boundaries -- must agree on these, or the gate silently
-- prunes results the scorers would match and narrowing misses them.
local FUZZY_EDIT1_LEN, FUZZY_EDIT2_LEN, ABBREV_MIN_LEN = 5, 8, 3

function Database:ScoreFuzzy(text, query, queryLen)
    -- Dev seam (bench FUZZY A/B): no misspelling tolerance when set.
    if Database._disableFuzzy then return 0 end
    -- Length-scaled typo budget (1 edit per ~4 chars). Without this,
    -- "skull" fuzzy-matches "spell" and similar unrelated 40%-diff words.
    local maxEdits
    if queryLen >= FUZZY_EDIT2_LEN then maxEdits = 2
    elseif queryLen >= FUZZY_EDIT1_LEN then maxEdits = 1
    else return 0
    end

    local queryFirst, querySecond = sbyte(query, 1, 2)
    local bestScore = 0
    local blocked = FUZZY_BLOCKLIST[query]
    local textWords = GetWords(text)
    for wi = 1, #textWords do
        local word = textWords[wi]
        -- First letter must match (typos rarely hit it), except the one
        -- typo that always does: the first two letters swapped
        -- ("ocntrol", "ramor"). Two byte reads, no distance work.
        local w1 = sbyte(word, 1)
        if (w1 == queryFirst or (w1 == querySecond and sbyte(word, 2) == queryFirst))
           and not (blocked and blocked[word]) then
            local wordLen = #word
            local lenDiff = wordLen - queryLen
            if lenDiff < 0 then lenDiff = -lenDiff end
            if lenDiff <= maxEdits then
                local dist = Database:DamerauLevenshtein(query, word, queryLen, wordLen)
                if dist == 1 and maxEdits >= 1 then
                    bestScore = mmax(bestScore, 85)
                elseif dist == 2 and maxEdits >= 2 then
                    bestScore = mmax(bestScore, 45)
                end
            end
        end
    end
    return bestScore
end

-- First-char constraint avoids spurious hits like "ahn'" in "magtheridon's".
function Database:IsSubsequence(word, query, queryLen)
    if sbyte(word, 1) ~= sbyte(query, 1) then return false end
    local wi = 1
    local wordLen = #word
    local firstPos
    for qi = 1, queryLen do
        local qc = sbyte(query, qi)
        local found = false
        while wi <= wordLen do
            if sbyte(word, wi) == qc then
                if not firstPos then firstPos = wi end
                wi = wi + 1
                found = true
                break
            end
            wi = wi + 1
        end
        if not found then return false end
    end
    -- Reject sparse matches: "inn" in "instance" hits i(1)n(2)n(6), span 6 > 5.
    return (wi - 1) - firstPos + 1 <= queryLen * 2 - 1
end

local function DistanceCapped2(s1, s2, len1, len2)
    local prev2, prev, curr = dlPrev2, dlPrev, dlCurr

    for j = 0, len2 do prev[j] = j end

    for i = 1, len1 do
        curr[0] = i
        local minInRow = i
        local c1 = sbyte(s1, i)
        local c1Prev = i > 1 and sbyte(s1, i - 1) or nil
        for j = 1, len2 do
            local c2 = sbyte(s2, j)
            local cost = (c1 == c2) and 0 or 1
            curr[j] = mmin(
                prev[j] + 1,
                curr[j - 1] + 1,
                prev[j - 1] + cost
            )
            if i > 1 and j > 1
                and c1 == sbyte(s2, j - 1)
                and c1Prev == c2 then
                curr[j] = mmin(curr[j], prev2[j - 2] + cost)
            end
            if curr[j] < minInRow then minInRow = curr[j] end
        end
        if minInRow > 2 then return 3 end
        prev2, prev, curr = prev, curr, prev2
    end
    return prev[len2]
end

-- Damerau-Levenshtein with transpositions, capped at 2. Pure, and a search
-- asks the same pairs over and over (one keyword on a thousand rows), so
-- results are kept per first string; callers pass the query word first.
local dlMemo, dlMemoRows = {}, 0
function Database:DamerauLevenshtein(s1, s2, len1, len2)
    if Database._disableFuzzy then return 3 end
    if mabs(len1 - len2) > 2 then return 3 end
    local row = dlMemo[s1]
    if row then
        local d = row[s2]
        if d then return d end
    else
        if dlMemoRows >= 64 then
            wipe(dlMemo)
            dlMemoRows = 0
        end
        row = {}
        dlMemo[s1] = row
        dlMemoRows = dlMemoRows + 1
    end
    local d = DistanceCapped2(s1, s2, len1, len2)
    row[s2] = d
    return d
end

-- Character-presence prefilter: every non-space query byte must appear in the
-- text. Each name's a-z letters are cached as a 26-bit mask (one AND per
-- entry); query bytes outside a-z (digits, punctuation, non-Latin locales)
-- cannot live in the mask and are verified with one sfind per distinct byte.
local nameMaskCache = {}
local lastCMQuery, lastCMMask
local lastCMExtra, lastCMExtraN = {}, 0

local function ComputeCharMask(s)
    local m = 0
    for i = 1, #s do
        local b = sbyte(s, i)
        if b >= 97 and b <= 122 then m = bor(m, lshift(1, b - 97)) end
    end
    return m
end

local function ComputeQueryMask(query)
    lastCMExtraN = 0
    local m = 0
    for i = 1, #query do
        local b = sbyte(query, i)
        if b >= 97 and b <= 122 then
            m = bor(m, lshift(1, b - 97))
        elseif b ~= 32 then
            local c = ssub(query, i, i)
            local dup = false
            for e = 1, lastCMExtraN do
                if lastCMExtra[e] == c then dup = true; break end
            end
            if not dup then
                lastCMExtraN = lastCMExtraN + 1
                lastCMExtra[lastCMExtraN] = c
            end
        end
    end
    return m
end

function Database:CouldMatch(text, query)
    if query ~= lastCMQuery then
        lastCMQuery = query
        lastCMMask = ComputeQueryMask(query)
    end
    local tm = nameMaskCache[text]
    if not tm then
        tm = ComputeCharMask(text)
        if text ~= transientName then nameMaskCache[text] = tm end
    end
    if band(lastCMMask, tm) ~= lastCMMask then return false end
    for i = 1, lastCMExtraN do
        if not sfind(text, lastCMExtra[i], 1, true) then return false end
    end
    return true
end

-- Per-entry bitmask of the a-z letters that BEGIN a word in this string, built
-- from the same GetWords() split the word scorers use. ScoreInitials,
-- ScoreFuzzy, and the abbrev subsequence path can only score a word whose first
-- letter equals the query's first letter, so one AND against this mask skips all
-- three (and their GetWords + per-word loops) for entries where the query's
-- initial starts no word here. Cached per string like nameMaskCache.
local wordInitCache = {}
local function WordInitMask(text)
    local m = wordInitCache[text]
    if m then return m end
    m = 0
    local words = GetWords(text)
    for i = 1, #words do
        local b = sbyte(words[i], 1)
        if b and b >= 97 and b <= 122 then m = bor(m, lshift(1, b - 97)) end
    end
    if text ~= transientName then wordInitCache[text] = m end
    return m
end

-- Fuzzy-aware per-keyword pre-reject for ScoreKeywords. A keyword can only
-- reach the scoring ladder's thresholds when at most maxEdits of the query
-- word's a-z chars are absent from it (ScoreFuzzy introduces up to 1 new
-- char at len >= FUZZY_EDIT1_LEN, 2 at >= FUZZY_EDIT2_LEN; every other path
-- needs all chars present). Masks come from the same per-string cache the
-- name gate uses, so the check is one AND plus a popcount of the misses.
local function KeywordCouldMatch(kw, queryWord, queryWordLen)
    if queryWord ~= lastCMQuery then
        lastCMQuery = queryWord
        lastCMMask = ComputeQueryMask(queryWord)
    end
    local tm = nameMaskCache[kw]
    if not tm then tm = ComputeCharMask(kw); nameMaskCache[kw] = tm end
    local present = band(lastCMMask, tm)
    if present == lastCMMask then return true end
    local missing = lastCMMask - present
    local allowed = 0
    if queryWordLen >= FUZZY_EDIT2_LEN then
        allowed = 2
    elseif queryWordLen >= FUZZY_EDIT1_LEN then
        allowed = 1
    end
    if allowed == 0 then return false end
    local n = 0
    while missing ~= 0 do
        missing = band(missing, missing - 1)
        n = n + 1
        if n > allowed then return false end
    end
    return true
end

-- Per-query-word scoring gate. Multi-word full scans ran three engines
-- (ScoreName, ScoreKeywords, ScoreEntryFields) on every entry and dominated
-- keystroke cost. Every path that reaches the result threshold requires each
-- query word of >= 2 chars to match the name or a keyword, and each match
-- needs the word's a-z chars present in that text, except: fuzzy paths may
-- introduce up to maxEdits new chars (1 at len >= 5, 2 at len >= 8), the
-- plural rule one trailing 's' -- and both also require a name/keyword word
-- starting with the query word's first byte (checked at every
-- DamerauLevenshtein call site and the plural line in ScoreSingleFieldWord).
-- An entry missing more than that budget for any word, or the budgeted word's
-- initial, cannot score, so all engines are skipped. 1-char words are never
-- required (ScoreKeywords skips them by design). Loot entries keep their own
-- branch and are never gated. The dev bench GATE section asserts gated ==
-- ungated results; keep it green when touching any scorer above.
local GATE = {
    masks = {}, allows = {}, firstBits = {}, count = 0,
    sawNil = false, gatedN = 0, skipStatistic = false, fillPending = false,
}

-- Shared with PackedCorpus, which walks original-case decoded names; the
-- inputs here are already lowercase, so the fold in the shared version is
-- a no-op for this caller.
local AccumulateGateMasks = Utils.AccumulateGateMasks

local function FillEntryGateMask(e)
    if e.lootEntry then
        e._efGateMask = false
        return
    end
    local cm, im = 0, 0
    if e.nameLower then cm, im = AccumulateGateMasks(e.nameLower, cm, im) end
    local kws = e.keywordsLower or e.keywords
    if kws then
        for k = 1, #kws do
            local kw = kws[k]
            if type(kw) == "string" then cm, im = AccumulateGateMasks(kw, cm, im) end
        end
    end
    e._efGateMask = cm
    e._efGateInit = im
end

local GATE_FILL_STEP = 400
local FillGateMasksStep
local function ScheduleGateMaskFill()
    if GATE.fillPending then return end
    GATE.fillPending = true
    GATE.fillIdx = 1
    Utils.SafeAfter(0, FillGateMasksStep)
end

-- Bounded by time as well: 400 corpus stubs were an 8 ms step.
local GATE_FILL_MS = 1.5
FillGateMasksStep = function()
    local data = Database.uiSearchData
    local i = GATE.fillIdx or 1
    local n = #data
    local filled = 0
    local clock = debugprofilestop
    local stop = clock and clock() + GATE_FILL_MS
    while i <= n and filled < GATE_FILL_STEP and not (stop and band(filled, 15) == 15 and clock() > stop) do
        local e = data[i]
        if e._efGateMask == nil then
            FillEntryGateMask(e)
            filled = filled + 1
        end
        i = i + 1
    end
    if i <= n then
        GATE.fillIdx = i
        Utils.SafeAfter(0, FillGateMasksStep)
    else
        GATE.fillPending = false
        GATE.fillIdx = nil
    end
end

function Database:PrimeSearchGate()
    local data = self.uiSearchData
    for i = 1, #data do
        if data[i]._efGateMask == nil then FillEntryGateMask(data[i]) end
    end
    GATE.fillPending = false
    GATE.fillIdx = nil
end

local function GateSkipsEntry(data)
    local gm = data._efGateMask
    if gm == nil then
        GATE.sawNil = true
        return false
    end
    if not gm then return false end
    local masks, allows, firstBits, count, skipStat =
        GATE.masks, GATE.allows, GATE.firstBits, GATE.count, GATE.skipStatistic
    if skipStat and data.category == "Statistic" then return false end
    for w = 1, count do
        local missing = band(masks[w], bnot(gm))
        if missing ~= 0 then
            local skip = true
            local budget = allows[w]
            if budget > 0 then
                local fb = firstBits[w]
                if fb == 0 or band(data._efGateInit or 0, fb) ~= 0 then
                    local c = 0
                    repeat
                        c = c + 1
                        missing = band(missing, missing - 1)
                    until missing == 0 or c > budget
                    skip = missing ~= 0
                end
            end
            if skip then
                GATE.gatedN = GATE.gatedN + 1
                return true
            end
        end
    end
    return false
end

-- exact -> starts-with -> word-boundary -> substring -> initials -> fuzzy.
-- True when a query word asks for the kind a scoreBonus row represents:
-- one of askWords exactly, or three or more letters that begin one of
-- them ("tele", "port", "dun"). Rows carry askWords as scoreBonusWords.
local function QueryAsksFor(queryWords, askWords)
    if not (queryWords and askWords) then return false end
    for i = 1, #queryWords do
        local w = queryWords[i]
        for j = 1, #askWords do
            local ask = askWords[j]
            if w == ask or (#w >= 3 and #ask > #w and ssub(ask, 1, #w) == w) then
                return true
            end
        end
    end
    return false
end
Database.QueryAsksFor = QueryAsksFor

function Database:ScoreName(nameLower, query, queryLen, optQueryWords)
    if ssub(query, queryLen, queryLen) == " " then
        query = query:match("^(.-)%s+$") or query
        queryLen = #query
        if queryLen == 0 then return 0 end
    end

    -- A name holding the query passes the letter gate by definition.
    local found = sfind(nameLower, query, 1, true)
    if not found and not Database:CouldMatch(nameLower, query) then return 0 end

    if STOPWORDS[query] then
        if nameLower == query then return EXACT_MATCH_SCORE end
        local ext = StopwordExtension(nameLower, query, queryLen)
        if ext == 3 then return NAME_PREFIX_SCORE end
        if ext == 2 then return 120 end
        return ext == 1 and 30 or 0
    end

    local score = 0

    if nameLower == query then
        score = EXACT_MATCH_SCORE
    elseif found == 1 then
        score = NAME_PREFIX_SCORE
    elseif found and Database:FindAtWordBoundary(nameLower, query) then
        score = 120
    elseif found then
        score = 30
    end
    -- Every path below runs only under 130: a name start needs no words.
    if score >= 130 then return score end

    -- ScoreInitials, ScoreFuzzy, and the abbrev subsequence path all require a
    -- name word starting with the query's first letter. One AND against the
    -- word-initial mask skips all three (and their GetWords + per-word loops)
    -- when no word here begins with it -- the bulk of entries for a short
    -- common-letter query. qInitBit == 0 (non a-z first byte) disables the gate.
    local qInitBit = 0
    local qFirst = sbyte(query, 1)
    if qFirst >= 97 and qFirst <= 122 then qInitBit = lshift(1, qFirst - 97) end
    local nameHasQueryInitial = qInitBit == 0
        or band(WordInitMask(nameLower), qInitBit) ~= 0

    if nameHasQueryInitial and score < 130 then
        local initScore = Database:ScoreInitials(nameLower, query)
        if initScore > score then score = initScore end
    end

    -- Fuzzy also accepts a swapped first pair, so the second letter may
    -- be the word initial here; initials and abbreviations stay strict.
    local fuzzyInitialOk = nameHasQueryInitial
    if not fuzzyInitialOk and queryLen >= FUZZY_EDIT1_LEN then
        local qSecond = sbyte(query, 2)
        if qSecond and qSecond >= 97 and qSecond <= 122 then
            fuzzyInitialOk = band(WordInitMask(nameLower), lshift(1, qSecond - 97)) ~= 0
        end
    end
    if fuzzyInitialOk and score < 100 and queryLen >= FUZZY_EDIT1_LEN then
        local fuzzyScore = Database:ScoreFuzzy(nameLower, query, queryLen)
        if fuzzyScore > score then score = fuzzyScore end
    end

    -- Vowel-stripped abbreviations: "qtr" -> quartermaster, "windrnr" -> windrunner.
    if nameHasQueryInitial and score < 50 and queryLen >= ABBREV_MIN_LEN and not sfind(query, " ", 1, true) then
        local nameWords = GetWords(nameLower)
        for wi = 1, #nameWords do
            local word = nameWords[wi]
            local wordLen = #word
            if queryLen <= 4 then
                if wordLen >= queryLen * 2 and Database:IsSubsequence(word, query, queryLen) then
                    score = mmax(score, 55)
                    break
                end
            elseif queryLen <= 8 and wordLen > queryLen and queryLen / wordLen >= 0.6 then
                if Database:IsSubsequence(word, query, queryLen) then
                    score = mmax(score, 60)
                    break
                end
            end
        end
    end

    -- Multi-word query: all words must match. Fires even after an inferior
    -- low-score path so "estern kingd" -> "Eastern Kingdoms" can still surface.
    if score < 100 and sfind(query, " ", 1, true) then
        -- A caller without its own word list (the map search) gets the
        -- query cut as names are.
        local queryWords = optQueryWords or GetWords(query)
        if #queryWords >= 2 then
            local nameWords = GetWords(nameLower)
            local allMatched = true
            local totalWordScore = 0
            wipe(scoreNameUsedWords)
            local usedNameWords = scoreNameUsedWords
            for qwi = 1, #queryWords do
                local qw = queryWords[qwi]
                local qwLen = #qw
                local bestWordScore = 0
                local bestIdx = 0
                for ni = 1, #nameWords do
                    if not usedNameWords[ni] then
                        local nw = nameWords[ni]
                        local ws = 0
                        if nw == qw then
                            ws = 100
                        elseif sfind(nw, qw, 1, true) == 1 then
                            ws = 90
                        elseif sfind(nw, qw, 1, true) then
                            ws = 50
                        elseif qwLen >= FUZZY_EDIT1_LEN
                           and (sbyte(nw, 1) == sbyte(qw, 1)
                                or (sbyte(nw, 1) == sbyte(qw, 2) and sbyte(nw, 2) == sbyte(qw, 1))) then
                            local nwLen = #nw
                            local maxEdits = qwLen >= FUZZY_EDIT2_LEN and 2 or 1
                            if nwLen >= qwLen - maxEdits and nwLen <= qwLen + maxEdits then
                                local dist = Database:DamerauLevenshtein(qw, nw, qwLen, nwLen)
                                if dist == 1 then
                                    ws = 75
                                elseif dist == 2 and maxEdits >= 2 then
                                    ws = 40
                                end
                            end
                            if ws == 0 and qwLen <= 8 and nwLen > qwLen and qwLen / nwLen >= 0.6 then
                                if Database:IsSubsequence(nw, qw, qwLen) then
                                    ws = 45
                                end
                            end
                        elseif qwLen == 3 then
                            local nwLen = #nw
                            if nwLen >= qwLen * 2 and Database:IsSubsequence(nw, qw, qwLen) then
                                ws = 45
                            end
                        end
                        if ws > bestWordScore then
                            bestWordScore = ws
                            bestIdx = ni
                        end
                    end
                end
                if bestWordScore > 0 then
                    usedNameWords[bestIdx] = true
                    totalWordScore = totalWordScore + bestWordScore
                else
                    allMatched = false
                    break
                end
            end
            if allMatched then
                local avgScore = totalWordScore / #queryWords
                local wordScore = mmin(110, avgScore)
                if wordScore > score then score = wordScore end
            end
        end
    end

    return score
end

-- ScoreName for a name nobody keeps (an item catalog line): its words and
-- masks are worked out for this call only, so typing caches no item names.
function Database:ScoreTransientName(nameLower, query, queryLen)
    transientName, transientFilled = nameLower, false
    local score = self:ScoreName(nameLower, query, queryLen)
    transientName = nil
    return score
end

-- The multi-word form of a strong name match, for the gated categories
-- (Statistic / Achievement Category without an "ach"/"stat" query word):
-- EVERY query word must land on a distinct name word at exact or prefix
-- strength ("gold per day" -> "Average gold earned per day"). Deliberately
-- stricter than ScoreName's multi-word path -- no fuzzy/contains/subsequence
-- word tiers -- so the gate keeps meaning strong matches only.
local strongNameUsedWords = {}
local function StrongMultiWordNameScore(nameLower, queryWords)
    local nameWords = GetWords(nameLower)
    local numQueryWords = #queryWords
    if #nameWords < numQueryWords then return 0 end
    wipe(strongNameUsedWords)
    local total = 0
    for qwi = 1, numQueryWords do
        local qw = queryWords[qwi]
        local best = 0
        local bestIdx = 0
        for ni = 1, #nameWords do
            if not strongNameUsedWords[ni] then
                local nw = nameWords[ni]
                if nw == qw then
                    best = 100
                    bestIdx = ni
                    break
                elseif best < 90 and sfind(nw, qw, 1, true) == 1 then
                    best = 90
                    bestIdx = ni
                end
            end
        end
        if bestIdx == 0 then return 0 end
        strongNameUsedWords[bestIdx] = true
        total = total + best
    end
    return total / numQueryWords
end

function Database:ScoreKeywords(keywordsLower, query, queryLen, optQueryWords)
    if not keywordsLower then return 0 end

    if ssub(query, queryLen, queryLen) == " " then
        query = query:match("^(.-)%s+$") or query
        queryLen = #query
        if queryLen == 0 then return 0 end
    end

    -- No word list from the caller: the query cut as names are. Returning
    -- 0 there silently zeroed every map search keyword (repair, a title).
    local queryWords = optQueryWords or GetWords(query)

    -- Single-word: take BEST kw match, not sum. Summing let items with
    -- redundant keywords ("reputation" + "reputation achievements") beat
    -- items with a better name match.
    local numKeywords = #keywordsLower
    if #queryWords == 1 then
        if STOPWORDS[query] then
            local best = 0
            for ki = 1, numKeywords do
                local kw = keywordsLower[ki]
                if kw ~= query
                   and (Database._disableSearchGate or KeywordCouldMatch(kw, query, queryLen)) then
                    local ext = StopwordExtension(kw, query, queryLen)
                    local kwScore = (ext == 3 and 70) or (ext == 2 and 55) or 0
                    if kwScore > best then best = kwScore end
                end
            end
            return best
        end
        local best = 0
        for ki = 1, numKeywords do
            local kw = keywordsLower[ki]
            if Database._disableSearchGate or KeywordCouldMatch(kw, query, queryLen) then
            local kwScore = 0
            if kw == query then
                -- Short abbreviations (2-3 chars) get boosted above initials.
                -- Longer exact keywords sit above any typo-tolerant name
                -- match (85): a word the row literally answers to beats a
                -- name one letter off ("brackenhide" over the "black" rows).
                kwScore = queryLen <= 3 and 140 or 100
            elseif sfind(kw, query, 1, true) == 1 then
                -- A prefix of five or more letters is the same evidence the
                -- typo path needs before it fires at all, so it outranks a
                -- typo too; shorter prefixes stay below.
                kwScore = queryLen >= FUZZY_EDIT1_LEN and 90 or 70
            elseif Database:FindAtWordBoundary(kw, query) then
                kwScore = 55
            end
            if kwScore < 60 and queryLen >= 3 then
                local initScore = Database:ScoreInitials(kw, query)
                if initScore > 0 then
                    local penalty = queryLen == 3 and 70 or 20
                    kwScore = mmax(kwScore, initScore - penalty)
                end
            end
            if kwScore < 40 and queryLen >= FUZZY_EDIT1_LEN then
                local kf = Database:ScoreFuzzy(kw, query, queryLen)
                if kf > 0 then kwScore = mmax(kwScore, kf) end
            end
            if kwScore < 50 and queryLen >= 3 then
                local kwWords = GetWords(kw)
                for kwi = 1, #kwWords do
                    local kwWord = kwWords[kwi]
                    local kwWordLen = #kwWord
                    if queryLen <= 4 and kwWordLen >= queryLen * 2 then
                        if Database:IsSubsequence(kwWord, query, queryLen) then
                            kwScore = mmax(kwScore, 60)
                            break
                        end
                    elseif queryLen <= 8 and kwWordLen > queryLen and queryLen / kwWordLen >= 0.6 then
                        if Database:IsSubsequence(kwWord, query, queryLen) then
                            kwScore = mmax(kwScore, 55)
                            break
                        end
                    end
                end
            end
            if kwScore > best then best = kwScore end
            end
        end
        return best
    end

    -- Multi-word: all words >= 2 chars must match. Single-char words are
    -- SKIPPED (not failed) so mid-type queries like "feral a" don't empty
    -- prevCandidates and silently kill the next "feral abil" extension.
    local total = 0
    for qwi = 1, #queryWords do
        local queryWord = queryWords[qwi]
        local queryWordLen = #queryWord
        local bestScore = 0

        if queryWordLen >= 2 then
            for ki = 1, numKeywords do
                local kw = keywordsLower[ki]
                if Database._disableSearchGate or KeywordCouldMatch(kw, queryWord, queryWordLen) then
                local kwScore = 0
                if kw == queryWord then
                    kwScore = 80
                elseif sfind(kw, queryWord, 1, true) == 1 then
                    kwScore = 70
                elseif Database:FindAtWordBoundary(kw, queryWord) then
                    kwScore = 55
                end
                if kwScore < 60 and queryWordLen >= 3 then
                    local initScore = Database:ScoreInitials(kw, queryWord)
                    if initScore > 0 then
                        local penalty = queryWordLen == 3 and 70 or 20
                        kwScore = mmax(kwScore, initScore - penalty)
                    end
                end
                if kwScore < 40 and queryWordLen >= FUZZY_EDIT1_LEN then
                    local kf = Database:ScoreFuzzy(kw, queryWord, queryWordLen)
                    if kf > 0 then kwScore = mmax(kwScore, kf) end
                end

                if kwScore > bestScore then
                    bestScore = kwScore
                end
                end
            end
            if bestScore == 0 then
                return 0
            end
            total = total + bestScore
        end
    end

    return total
end

-- When the user extends the previous query (e.g. "mou" -> "moun"), only
-- re-score entries that matched before instead of the full dataset.
local function ScoreSingleFieldWord(fieldWord, queryWord, queryWordLen)
    if fieldWord == queryWord then return 100 end
    if sfind(fieldWord, queryWord, 1, true) == 1 then return 90 end
    -- The plural rule without building strings: one is the other plus s.
    local fieldLen = #fieldWord
    if (queryWordLen == fieldLen + 1 and sbyte(queryWord, queryWordLen) == 115
            and sfind(queryWord, fieldWord, 1, true) == 1)
       or (fieldLen == queryWordLen + 1 and sbyte(fieldWord, fieldLen) == 115
            and sfind(fieldWord, queryWord, 1, true) == 1) then
        return 82
    end
    if sfind(fieldWord, queryWord, 1, true) then return 50 end
    if queryWordLen >= 3 then
        if fieldLen > queryWordLen and queryWordLen <= 8
           and queryWordLen / fieldLen >= 0.45
           and Database:IsSubsequence(fieldWord, queryWord, queryWordLen) then
            return 55
        end
    end
    if queryWordLen >= FUZZY_EDIT1_LEN and sbyte(fieldWord, 1) == sbyte(queryWord, 1) then
        local maxEdits = queryWordLen >= FUZZY_EDIT2_LEN and 2 or 1
        if fieldLen >= queryWordLen - maxEdits and fieldLen <= queryWordLen + maxEdits then
            local dist = Database:DamerauLevenshtein(queryWord, fieldWord, queryWordLen, fieldLen)
            if dist <= maxEdits then return mmax(45, 85 - dist * 20) end
        end
    end
    return 0
end

local function ScoreFieldWords(words, queryWord, queryWordLen)
    local best = 0
    for i = 1, #words do
        local score = ScoreSingleFieldWord(words[i], queryWord, queryWordLen)
        if score > best then best = score end
    end
    return best
end

local keywordWordListsScratch = {}
function Database:ScoreEntryFields(data, queryWords)
    if not queryWords or #queryWords < 2 then return 0 end
    local total = 0
    local matched = 0
    local nameMatches = 0
    local nameWords = GetWords(data.nameLower or "")
    -- Fall back to keywords when keywordsLower is omitted (most providers
    -- skip the duplicate field when the keyword list is already lowercase).
    local keywordsLower = data.keywordsLower or data.keywords

    local keywordWordLists = keywordWordListsScratch
    local kwCount = keywordsLower and #keywordsLower or 0
    for ki = 1, kwCount do
        keywordWordLists[ki] = GetWords(keywordsLower[ki])
    end

    for qi = 1, #queryWords do
        local qw = queryWords[qi]
        local qwLen = #qw
        if qwLen >= 2 or (qwLen == 1 and qi == #queryWords and matched > 0) then
            local nameBest = ScoreFieldWords(nameWords, qw, qwLen)
            local kwBest = 0
            for ki = 1, kwCount do
                local kw = keywordsLower[ki]
                local kwScore = ScoreSingleFieldWord(kw, qw, qwLen)
                if kwScore < 90 then
                    kwScore = mmax(kwScore, ScoreFieldWords(keywordWordLists[ki], qw, qwLen))
                end
                if kwScore > kwBest then kwBest = kwScore end
            end
            local best
            if nameBest > 0 then
                best = nameBest
                nameMatches = nameMatches + 1
            else
                best = kwBest
            end
            if best == 0 then return 0 end
            total = total + best
            matched = matched + 1
        end
    end

    if matched < 2 then return 0 end
    -- Discount pure-keyword matches: keyword sums (90/word) beat the
    -- avg-capped name-only score (110 max), so an item whose keyword list
    -- contains "Eastern Kingdoms" would outrank the actual zone.
    if nameMatches == 0 then
        total = mfloor(total * 0.45)
    end
    return total + matched * 5
end

local prevQuery = ""
local prevSkipKey = ""
local prevCandidates = {}
-- Bumped when the rows change: a scan that waited at a checkpoint across a
-- bump keeps nothing under its query.
local searchEpoch = 0
-- A fresh table, not a wiped one: a waiting scan may still read its set.
local function DropCandidates()
    searchEpoch = searchEpoch + 1
    prevQuery = ""
    prevCandidates = {}
end
-- Scratch for building skipKey from CategoryMap.SkipKeyOrder without a
-- per-search table allocation. Reused each search; tconcat reads buf[1..n].
local skipKeyBuf = {}

-- Query result cache. Incremental narrowing only speeds a GROWING query, so a
-- backspace (or retype) of an earlier query otherwise re-scans the whole
-- dataset (~5800 entries). This caches each scored query's candidate set (the
-- entries that matched, at most a few hundred) keyed by query+skipKey, so
-- returning to a previously-scored query re-scores that small set instead of
-- the full data. Bounded LRU; cleared whenever the search data changes.
local RESULT_CACHE_MAX = 16
local resultCache = {}
local resultCacheLRU = {}
Database._resultCache = resultCache

local function ClearResultCache()
    wipe(resultCache)
    wipe(resultCacheLRU)
end

local function StoreResultCache(key, candidates, n)
    local slot = resultCache[key]
    if slot then
        for i = 1, #resultCacheLRU do
            if resultCacheLRU[i] == key then tremove(resultCacheLRU, i); break end
        end
    elseif #resultCacheLRU >= RESULT_CACHE_MAX then
        local evict = tremove(resultCacheLRU, 1)
        slot = resultCache[evict]
        resultCache[evict] = nil
    else
        slot = {}
    end
    resultCache[key] = slot
    resultCacheLRU[#resultCacheLRU + 1] = key
    for i = 1, n do slot[i] = candidates[i] end
    for i = n + 1, #slot do slot[i] = nil end
end

function Database:WarmSearchHotPath()
    -- Pre-warm the cached async providers (loot/statistics/bosses) THROUGH the
    -- one chokepoint every other load uses, so a disabled category is skipped
    -- here by the single gate instead of a special case. Their async populate
    -- hits the SavedVariables cache, so a warm one is near-instant.
    if self.EnsureDynamicProviderLoaded then
        self:EnsureDynamicProviderLoaded("loot")
        self:EnsureDynamicProviderLoaded("statistics")
        self:EnsureDynamicProviderLoaded("bosses")
    end
    -- Load the small name-searched providers (currencies, reputations, etc.)
    -- so they show up without the user typing a category keyword first.
    if self.LoadEagerDynamicProviders then self:LoadEagerDynamicProviders() end
    -- Start the Blizzard-settings passes now, while nobody is waiting: the live
    -- layout walk takes seconds at the idle frame budget, invisible here but a
    -- multi-second stall if the first settings query triggers it cold. Settings
    -- are a separate subsystem (not a dynamic provider), so honor their own
    -- filter keys directly here: skip the walk when both settings buckets are off.
    local filters = EasyFind and EasyFind.db and EasyFind.db.uiSearchFilters
    local map = ns.CategoryMap
    local settingsOff = filters and map and map.IsProviderFilterOff
        and map.IsProviderFilterOff(filters, "gameOptions")
        and map.IsProviderFilterOff(filters, "addonOptions")
    local options = ns.BlizzOptionsSearch
    if not options and not settingsOff and ns.RequestSettingsSearch
       and ns.RequestSettingsSearch() then
        options = ns.BlizzOptionsSearch
    end
    if options and not settingsOff then
        -- Settings' completion never routed through RefreshSearchAfterProviderLoad
        -- -- a shortkey pointing at a setting row stayed unbound until the user
        -- searched settings. Rebind pending shortkeys when the walk finishes.
        local rebindShortkeys = function()
            if ns.Shortkeys and ns.Shortkeys.ReapplyIfPending then ns.Shortkeys:ReapplyIfPending() end
        end
        -- Nobody waits on these: they keep the background pace.
        if options.EnsurePopulatedAsync then options:EnsurePopulatedAsync(rebindShortkeys, true) end
        if options.EnsureLivePopulatedAsync then options:EnsureLivePopulatedAsync(rebindShortkeys, true) end
    end
end

-- Search scans the full dataset for a fresh query, so there is no candidate
-- index to rebuild. This stays the invalidation hook the rest of the codebase
-- calls when search data changes: it clears the incremental-narrowing cache so
-- the next keystroke re-scans from scratch, and re-runs the active search once
-- (coalesced) so a provider that finished loading in the background appears
-- without the user having to retype.
local searchRefreshPending = false
local function RunActiveSearchRefresh()
    searchRefreshPending = false
    -- Only search rows changed (a provider, settings rows, a cache reset).
    local search = ns.Search
    if search and search.RefreshActiveSearch then
        search:RefreshActiveSearch(true)
    end
end

-- A provider appended entries [fromIndex .. #uiSearchData] without removing
-- any (first load of a category -- the common case while typing). Instead
-- of nuking the narrowing state, which forces the next keystroke into a
-- full scan exactly when providers stream in, ADMIT the appended entries
-- into the candidate set. Candidates are a superset by contract (the scan
-- re-scores and writes back only true matches), so admitting everything
-- appended keeps narrowing complete for the live query at O(appended)
-- cost, and one keystroke later the set is tight again. Cached result
-- lists are incomplete now, so those still clear.
-- rows: the appended rows, in order (Database:TakePopulatedRows).
function Database:NoteAppendedEntries(rows)
    if ns.Aliases and ns.Aliases.InvalidateKeyIndex then ns.Aliases:InvalidateKeyIndex() end
    ClearResultCache()
    searchEpoch = searchEpoch + 1
    if prevQuery ~= "" and rows then
        local count = #prevCandidates
        for i = 1, #rows do prevCandidates[count + i] = rows[i] end
    end
    if self._dynamicBatchLoading then
        self._dynamicBatchChanged = true
        return
    end
    if not searchRefreshPending and Utils.SafeAfter then
        searchRefreshPending = true
        Utils.SafeAfter(0, RunActiveSearchRefresh)
    end
end

function Database:ResetSearchCache()
    if ns.Aliases and ns.Aliases.InvalidateKeyIndex then ns.Aliases:InvalidateKeyIndex() end
    -- Invalidate immediately, even mid-batch: the data just changed, so the
    -- narrowing state and cached candidate sets are stale NOW. A search that
    -- runs during the batch window must full-scan current data, or it narrows
    -- inside a candidate set from before the providers pushed their entries
    -- (typing during login made real entries unfindable until a fresh query).
    DropCandidates()
    prevSkipKey = ""
    ClearResultCache()
    -- Only the active-search re-run coalesces to the end of the batch.
    if self._dynamicBatchLoading then
        self._dynamicBatchChanged = true
        return
    end
    if not searchRefreshPending and Utils.SafeAfter then
        searchRefreshPending = true
        Utils.SafeAfter(0, RunActiveSearchRefresh)
    end
end

local resultsBuf = {}
-- Per-query memo keyed by keyword TABLE identity. Prototype-injected
-- categories (housing: 1768 entries) share one keywords table via __index,
-- so scoring it once per query replaces 1768 identical scorings. Entries
-- with unique tables just pay one hash lookup. Wiped per query.
local sharedKwScores = {}
local resultsQueryWords = {}
local statisticScopedQueryWords = {}
local resultEntryPool = {}
Database._resultEntryPool = resultEntryPool

function Database:TrimSearchMemory()
    self:UnloadDynamicSearchData()
    -- Fresh tables, not wiped ones: a wiped table keeps the room its
    -- largest query took.
    resultsBuf, sharedKwScores, resultEntryPool = {}, {}, {}
    Database._resultEntryPool = resultEntryPool
    wipe(resultsQueryWords)
    wipe(statisticScopedQueryWords)
    wordCache, nameMaskCache, wordInitCache = {}, {}, {}
    Database._wordCache = wordCache
    DropCandidates()
    prevSkipKey = ""
    resultCache, resultCacheLRU = {}, {}
    Database._resultCache = resultCache
    if ns.SearchIndex and ns.SearchIndex.TrimScratch then ns.SearchIndex:TrimScratch() end
    Utils.ShedCorpora()
end

-- Per-category minimum query length: entries of a gated category are skipped
-- while the query is shorter than their threshold, and crossing a threshold
-- forces a full scan so the newly eligible category is admitted past the
-- incremental narrowing. A category absent from the map costs a single upvalue
-- nil-check per entry.
local categoryMinLen

-- Shipped default (applied at the bottom of this file): the heavy providers
-- that a 1-2 char query only floods with noise -- Statistics, Bosses,
-- Achievements, and Blizzard/AddOn settings -- load and score only at 3+
-- characters. Measured 2-6x per-keystroke win (bench GATE A/B, results
-- identical once past 3 chars).
local DEFAULT_CATEGORY_MINLEN = {
    ["Statistic"] = 3,
    ["Boss"] = 3,
    ["Achievement"] = 3,
    ["Achievement Category"] = 3,
    ["Game Settings"] = 3,
    ["AddOn Settings"] = 3,
}
Database.DEFAULT_CATEGORY_MINLEN = DEFAULT_CATEGORY_MINLEN
function Database:SetCategoryMinLen(map)
    categoryMinLen = map
    -- Public mirror for the Engine's load-side gate (deferring the
    -- provider REQUEST, so a gated category's cold build also waits for
    -- the threshold, not just its scoring).
    self.categoryMinLenActive = map
    self:ResetSearchCache()
end

function Database:SearchUI(query, skipCategories)
    if not query or query == "" or #query < 2 then
        DropCandidates()
        wipe(resultsBuf)
        return resultsBuf
    end

    query = Database:NormalizeSearchQuery(slower(query))
    local queryLen = #query

    -- Pre-trim trailing whitespace so scoring doesn't match() per entry.
    if ssub(query, queryLen, queryLen) == " " then
        query = query:match("^(.-)%s+$") or query
        query = Database:NormalizeSearchQuery(query)
        queryLen = #query
        if queryLen == 0 then DropCandidates(); wipe(resultsBuf); return resultsBuf end
    end

    wipe(sharedKwScores)
    wipe(resultsQueryWords)
    local queryWords = resultsQueryWords
    -- Query words are cut the way name words are (GetWords: punctuation
    -- dropped, apostrophes kept). Cut on whitespace alone, a typed colon,
    -- hyphen or bracket made "pattern:" or "(journal)" a word no name
    -- has, and every word-level tier (loot rows, multi-word names,
    -- keywords, the index) lost the row while the raw prefix tier still
    -- matched: loot patterns vanished at the colon, and one typo in
    -- "radis (journal)" found nothing. The raw query still drives the
    -- exact and prefix tiers, so "pattern:" itself matches as before.
    local cut = GetWords(query)
    for i = 1, #cut do queryWords[i] = cut[i] end
    if #queryWords == 0 then
        for w in query:gmatch("%S+") do
            queryWords[#queryWords + 1] = w
        end
    end
    -- The raw string still drives the exact, prefix and contains tiers.
    -- When cutting changed it ("& guild" -> "guild", "outfti (" ->
    -- "outfti"), the cut form is a second chance for rows the raw tiers
    -- scored under 100: the single-word tiers compared the raw string,
    -- so a stray ampersand or bracket found nothing at all.
    local queryNorm = tconcat(queryWords, " ")
    local queryNormLen = #queryNorm
    if queryNorm == query or queryNormLen < 2 then queryNorm = nil end

    -- Gates: without "boss" in the query, bosses match name only ("icc"
    -- alone shouldn't flood with bosses). Achievements (~175 entries with
    -- broad keywords) are gated behind "ach"/"stat" or a strong name match.
    local bossQueryWord = false
    local achQueryWord = false
    local statQueryWord = false
    local lootStatWordCount = 0
    local lootGearContext = false
    for qi = 1, #queryWords do
        local qw = queryWords[qi]
        if BOSS_QUERY_WORDS[qw] then
            bossQueryWord = true
        end
        local isStatQueryWord = STAT_QUERY_WORDS[qw]
        if isStatQueryWord then
            statQueryWord = true
        end
        if IsLootStatSearchWord(qw) then
            lootStatWordCount = lootStatWordCount + 1
        end
        if IsLootSlotSearchWord(qw) then
            lootGearContext = true
        end
        if ssub(qw, 1, 3) == "ach" or isStatQueryWord then
            achQueryWord = true
        end
    end

    -- Stat shorthands ("int", "haste") only act on gear queries: without a
    -- slot word ("ring", "shield", ...) they stop matching lootStatKw, so
    -- "arc int" cannot pull in every intellect item whose name starts "arc".
    -- Two stat words together ("haste vers") can only mean gear, so they open
    -- the gate without a slot word; a slot word then narrows via conjunction.
    -- _disableLootStatContext restores legacy behavior for the bench A/B.
    local lootStatActive = lootStatWordCount > 0
        and (lootGearContext or lootStatWordCount >= 2
            or Database._disableLootStatContext == true)

    local statisticScopedQuery
    local statisticScopedQueryLen = 0
    if statQueryWord and #queryWords >= 2 then
        wipe(statisticScopedQueryWords)
        for qi = 1, #queryWords do
            local qw = queryWords[qi]
            if not STAT_QUERY_WORDS[qw] then
                statisticScopedQueryWords[#statisticScopedQueryWords + 1] = qw
            end
        end
        if #statisticScopedQueryWords > 0 then
            statisticScopedQuery = tconcat(statisticScopedQueryWords, " ")
            statisticScopedQueryLen = #statisticScopedQuery
        end
    end

    GATE.count = 0
    GATE.sawNil = false
    GATE.gatedN = 0
    GATE.skipStatistic = statisticScopedQuery ~= nil
    if not Database._disableSearchGate then
        for qi = 1, #queryWords do
            local qw = queryWords[qi]
            local qwLen = #qw
            if qwLen >= 2 then
                local m = ComputeCharMask(qw)
                if m ~= 0 then
                    local gc = GATE.count + 1
                    GATE.count = gc
                    GATE.masks[gc] = m
                    local allow = qwLen >= FUZZY_EDIT2_LEN and 2 or qwLen >= FUZZY_EDIT1_LEN and 1 or 0
                    if allow == 0 and sbyte(qw, qwLen) == 115 then allow = 1 end
                    GATE.allows[gc] = allow
                    -- The initial the scorer will accept: the first letter,
                    -- or the second when a swapped first pair is in budget.
                    local fb, sb2 = sbyte(qw, 1, 2)
                    local bits = fb >= 97 and fb <= 122 and lshift(1, fb - 97) or 0
                    if allow > 0 and sb2 and sb2 >= 97 and sb2 <= 122 then
                        bits = bor(bits, lshift(1, sb2 - 97))
                    end
                    GATE.firstBits[gc] = bits
                end
            end
        end
    end

    -- Distinct 1-2 char code per skippable category. The incremental search
    -- reuses prevCandidates only when skipKey == prevSkipKey, so every
    -- category that Query.lua may put in skipCategories must change the key
    -- when toggled, otherwise re-enabling a filter mid-query leaves the
    -- previously-filtered items missing from the candidate set.
    -- Derive the key from the canonical category list (CategoryMap.SkipKeyOrder)
    -- so it covers EVERY category BuildSkipCategories can emit. A hand-maintained
    -- subset drifted (Currency etc. missing), leaving the key unchanged when
    -- those filters toggled and serving a stale filtered-out cache entry.
    local skipKey = ""
    if skipCategories then
        local order = ns.CategoryMap.SkipKeyOrder
        local n = 0
        for i = 1, #order do
            local cat = order[i]
            if skipCategories[cat] then n = n + 1; skipKeyBuf[n] = cat end
        end
        if n > 0 then skipKey = tconcat(skipKeyBuf, ",", 1, n) end
    end

    -- "\1" separates query from skipKey so ("x", skip "Mount") can never
    -- collide with ("xMount", no skips).
    local cacheKey = query .. "\1" .. skipKey

    local searchSet, restAt, stopwordRest
    local epoch, cands = searchEpoch, prevCandidates
    local cachedSet = resultCache[cacheKey]
    if cachedSet then
        -- Exact prior query (backspace / retype): re-score its cached
        -- candidate set instead of the full dataset.
        searchSet = cachedSet
    elseif query == prevQuery and skipKey == prevSkipKey then
        -- The same query again after an append: NoteAppendedEntries kept the
        -- set complete. A query that grew is never narrowed from the last
        -- set: typo, abbreviation and walk matches widen as a word grows, so
        -- narrowing lost rows that pasting the same text finds.
        searchSet = prevCandidates
    else
        searchSet = uiSearchData
        -- Fresh scans generate candidates from the q-gram index instead of
        -- scoring the whole dataset; the scorers verify only candidates and
        -- results stay identical (statistic-scoped queries rewrite the
        -- query per entry and must bypass; _disableSearchGate bypasses so
        -- the bench A/B proves identity against the true full scan).
        if not statisticScopedQuery and not Database._disableSearchGate
           and ns.SearchIndex then
            -- One plain word: the rows that can only score a mid-word substring
            -- come last, and the scan stops before them once it cannot use them.
            local split = #queryWords == 1 and queryWords[1] == query and not queryNorm
                and not sfind(query, "[^%w]")
                and not lootStatActive and not bossQueryWord and not achQueryWord and not statQueryWord
            local cand, _, restFrom = ns.SearchIndex:Candidates(queryWords, split)
            if cand then
                searchSet = cand
                restAt = restFrom
                stopwordRest = restFrom and STOPWORDS[query]
            end
        end
    end

    -- Dev-only narrowing stats: nil unless the dev profiler armed it, so zero cost
    -- in normal play. Reports whether incremental narrowing engaged and how
    -- big the scored set is.
    local efStats = Database._efSearchStats
    if efStats then
        if cachedSet then
            efStats.cache = efStats.cache + 1
            efStats.lastPath = "cache"
        elseif searchSet == prevCandidates then
            efStats.narrow = efStats.narrow + 1
            efStats.lastPath = "narrow"
        elseif searchSet ~= uiSearchData then
            efStats.indexed = (efStats.indexed or 0) + 1
            efStats.lastPath = "indexed"
        else
            efStats.full = efStats.full + 1
            efStats.lastPath = "full"
            local why
            if prevQuery == "" then why = "noPrev"
            elseif skipKey ~= prevSkipKey then why = "skipKey"
            else why = "newQuery" end
            efStats.whys[why] = (efStats.whys[why] or 0) + 1
        end
        efStats.setSize = #searchSet
        efStats.dataSize = #uiSearchData
    end

    -- Unset until the scan ends: a canceled run leaves prevCandidates half written.
    prevQuery = ""
    wipe(resultsBuf)
    local results = resultsBuf
    local resultsN, matchesN = 0, 0
    local candidateIdx = 0

    local gateActive = GATE.count > 0
    -- Room-shell housing entries can't be opened from the decor catalog; the
    -- housing flyout's Room toggle (default off) hides them. Read once per
    -- search, not per entry. Toggling it resets the search cache so this re-scans.
    local hideRooms = not (EasyFind and EasyFind.db and EasyFind.db.housingShowRooms == true)
    local searchCount = #searchSet
    -- Dev seam: score the rest rows anyway and keep the best they reach.
    local checkRest = Database._checkRestBound and restAt
    local stoppedEarly = false
    for i = 1, searchCount do
        -- Strided slice checkpoint: under the sliced dispatch a wide scan
        -- yields here every 64 candidates; a direct synchronous call
        -- (bench identity) makes this a no-op.
        if band(i, 63) == 0 then SliceCheckpoint() end
        -- Top-k stop (the threshold rule): no rest row can pass the worst kept.
        if i == restAt and not checkRest and resultsN >= RESULT_CAP
           and results[1].score > REST_MAX_SCORE then
            stoppedEarly = true
            break
        end
        local data = searchSet[i]
        -- Read once: on a packed row every field read is a call.
        local cat = data.category
        if not (skipCategories and skipCategories[cat])
           and not (hideRooms and cat == "Housing" and data.isRoom)
           and not (data.available and not data.available())
           and (not categoryMinLen or queryLen >= (categoryMinLen[cat] or 0))
           and (not gateActive or not GateSkipsEntry(data)) then
            local nameLower = data.nameLower
            local score
            if stopwordRest and i >= restAt then
                -- No word of a rest row starts with the stop word, so the
                -- stop word rules give its name 30 for holding it, else 0.
                score = (cat ~= "Achievement Category" and cat ~= "Statistic"
                    and sfind(nameLower, query, 1, true)) and 30 or 0
            elseif data.lootEntry then
                if lootStatActive and not data._statsEnriched then
                    Database:EnrichLootStats(data)
                end
                -- Each query word scores against name + slot + stats + source
                -- kws; best match wins; an unmatched word eliminates the item.
                -- Stopword query words are SKIPPED (no credit, no elimination):
                -- "maw of the greatworm" must not die on "of"/"the", and a bare
                -- "the" must not sum a word-match on every "The X" loot name.
                local totalScore = 0

                local nameWords = GetWords(nameLower)
                for qi = 1, #queryWords do
                    local qw = queryWords[qi]
                    if not STOPWORDS[qw] then
                    local qwLen = #qw
                    local bestWord = 0

                    -- Name match must outrank lootSourceKw (boss name) below,
                    -- else loot named for the query gets buried under same-
                    -- boss loot that only matched via the encounter name.
                    for ni = 1, #nameWords do
                        local nw = nameWords[ni]
                        if nw == qw then
                            bestWord = mmax(bestWord, qi == 1 and 130 or 120)
                        elseif ssub(nw, 1, qwLen) == qw then
                            bestWord = mmax(bestWord, qi == 1 and 115 or 105)
                        end
                    end

                    -- Prefix acceptance here must stay in sync with the
                    -- gear-context prefix rule in IsLootSlotSearchWord (Main.lua).
                    if data.lootSlotKw then
                        for ki = 1, #data.lootSlotKw do
                            local kw = data.lootSlotKw[ki]
                            if kw == qw then
                                -- Exact slot/stat keyword match is a strong signal
                                -- (the user typed the exact slot/stat). It must
                                -- outrank fuzzy noise (~85), or a plain "legs"
                                -- query buries real legs loot under 1-edit matches
                                -- on unrelated entries. Length is irrelevant to an
                                -- exact match, so drop the old 4+char penalty (80).
                                bestWord = mmax(bestWord, 140)
                            elseif sfind(kw, qw, 1, true) == 1 then
                                bestWord = mmax(bestWord, 70)
                            end
                        end
                    end

                    if lootStatActive and data.lootStatKw then
                        for ki = 1, #data.lootStatKw do
                            local kw = data.lootStatKw[ki]
                            if kw == qw then
                                -- Exact slot/stat keyword match is a strong signal
                                -- (the user typed the exact slot/stat). It must
                                -- outrank fuzzy noise (~85), or a plain "legs"
                                -- query buries real legs loot under 1-edit matches
                                -- on unrelated entries. Length is irrelevant to an
                                -- exact match, so drop the old 4+char penalty (80).
                                bestWord = mmax(bestWord, 140)
                            elseif sfind(kw, qw, 1, true) == 1 then
                                bestWord = mmax(bestWord, 70)
                            end
                        end
                    end

                    -- Prefix on boss/dungeon name must beat 1-edit fuzzy (85)
                    -- on unrelated names, so "nexu" -> Nexus-Point Xenas gear
                    -- doesn't rank below misspellings of other entries.
                    if data.lootSourceKw then
                        for ki = 1, #data.lootSourceKw do
                            local kw = data.lootSourceKw[ki]
                            if kw == qw then
                                bestWord = mmax(bestWord, 110)
                            elseif sfind(kw, qw, 1, true) == 1 then
                                bestWord = mmax(bestWord, 100)
                            end
                        end
                    end

                    if bestWord == 0 then
                        totalScore = 0
                        break
                    end
                    totalScore = totalScore + bestWord
                    end
                end

                score = totalScore
            elseif cat == "Boss" and not bossQueryWord then
                score = Database:ScoreName(nameLower, query, queryLen, queryWords)
            else
                local isAchEntry = cat == "Achievement Category" or cat == "Statistic"
                if isAchEntry and not achQueryWord then
                    -- Strong name matches only (skip kw score) so short kw
                    -- aliases don't drag every achievement category in.
                    if nameLower == query then
                        score = EXACT_MATCH_SCORE
                    elseif STOPWORDS[query] then
                        local ext = StopwordExtension(nameLower, query, queryLen)
                        score = (ext == 3 and NAME_PREFIX_SCORE) or (ext == 2 and 120) or 0
                    elseif sfind(nameLower, query, 1, true) == 1 then
                        score = NAME_PREFIX_SCORE
                    elseif Database:FindAtWordBoundary(nameLower, query) then
                        score = 120
                    elseif #queryWords >= 2 then
                        score = StrongMultiWordNameScore(nameLower, queryWords)
                    else
                        score = 0
                    end
                else
                    local entryQuery = query
                    local entryQueryLen = queryLen
                    local entryQueryWords = queryWords
                    if cat == "Statistic" and statisticScopedQuery then
                        entryQuery = statisticScopedQuery
                        entryQueryLen = statisticScopedQueryLen
                        entryQueryWords = statisticScopedQueryWords
                    end
                    -- MAX, not SUM. Many entries duplicate their name into
                    -- keywordsLower; a sum double-counts the same fuzzy hit.
                    local kws = data.keywordsLower or data.keywords
                    local kwScore = 0
                    if kws then
                        -- Keyword tables inherited from an __index prototype
                        -- (rawget nil: housing's 1768 entries share ONE table)
                        -- score once per query via the memo. Entries owning
                        -- their table score directly -- no memo overhead.
                        if entryQuery == query
                            and rawget(data, "keywordsLower") == nil
                            and rawget(data, "keywords") == nil then
                            kwScore = sharedKwScores[kws]
                            if kwScore == nil then
                                kwScore = Database:ScoreKeywords(kws,
                                    entryQuery, entryQueryLen, entryQueryWords)
                                sharedKwScores[kws] = kwScore
                            end
                        else
                            kwScore = Database:ScoreKeywords(kws,
                                entryQuery, entryQueryLen, entryQueryWords)
                        end
                    end
                    score = mmax(
                        Database:ScoreName(nameLower, entryQuery, entryQueryLen, entryQueryWords),
                        kwScore
                    )
                    if queryNorm and score < 100 and entryQuery == query then
                        -- Mapped onto 30..99, under every raw tier: a row named
                        -- exactly "guild" must not jump over "Guild & Communities"
                        -- the moment the "&" is typed, and the weakest cut match
                        -- still clears the 30-point floor below. Among the rows
                        -- only the cut form reaches, their own order holds.
                        local alt = mmax(
                            Database:ScoreName(nameLower, queryNorm, queryNormLen, entryQueryWords),
                            kws and Database:ScoreKeywords(kws, queryNorm, queryNormLen, entryQueryWords) or 0)
                        if alt > 0 then score = mmax(score, 30 + mmin(alt, 1000) * 0.069) end
                    end
                    if #entryQueryWords >= 2 then
                        score = mmax(score, Database:ScoreEntryFields(data, entryQueryWords))
                    end
                    -- A snippet's trigger keyword is its second name: scored
                    -- with the name tiers so typing it exactly ranks the
                    -- snippet like an exact name hit, not a keyword alias.
                    local snippetKw = data.snippetKeywordLower
                    if snippetKw then
                        local kwNameScore = Database:ScoreName(snippetKw,
                            entryQuery, entryQueryLen, entryQueryWords)
                        if kwNameScore > score then score = kwNameScore end
                    end
                    -- A dungeon teleport's dungeon name is its second name
                    -- too; its nicknames ("bran", "kara") are plain keywords.
                    local tpName = data.teleportNameLower
                    if tpName then
                        local tpScore = Database:ScoreName(tpName,
                            entryQuery, entryQueryLen, entryQueryWords)
                        local tpEn = data.teleportNameEnLower
                        if tpEn and tpEn ~= tpName then
                            local enScore = Database:ScoreName(tpEn,
                                entryQuery, entryQueryLen, entryQueryWords)
                            if enScore > tpScore then tpScore = enScore end
                        end
                        if tpScore > score then score = tpScore end
                    end
                end
            end

            if checkRest and i >= restAt and score > (Database._restMaxSeen or 0) then
                Database._restMaxSeen = score
                Database._restMaxRow = data.name
            end
            if score >= 30 then
                matchesN = matchesN + 1
                -- scoreBonus: per-row rank lift, applied per MATCH (not per
                -- candidate, so off the scoring hot path), and only when the
                -- query asks for the row's kind (scoreBonusWords): "teleport
                -- kara" puts the "Path of ..." row above the catalog's name
                -- matches; bare "kara" leaves it at its natural rank.
                local bonus = data.scoreBonus
                if bonus and data.scoreBonusWords
                   and not QueryAsksFor(queryWords, data.scoreBonusWords) then
                    bonus = nil
                end
                local total = score + (bonus or 0)
                if resultsN < RESULT_CAP then
                    resultsN = resultsN + 1
                    local r = resultEntryPool[resultsN]
                    if not r then
                        r = {}
                        resultEntryPool[resultsN] = r
                    end
                    r.data, r.score, r.isAlias = data, total, nil
                    results[resultsN] = r
                    HeapUp(results, resultsN)
                else
                    -- Full: a match that ranks after the worst kept row is dropped.
                    heapProbe.data, heapProbe.score = data, total
                    if scoreDescending(heapProbe, results[1]) then
                        local r = results[1]
                        r.data, r.score, r.isAlias = data, total, nil
                        HeapDown(results, resultsN)
                    end
                end
                candidateIdx = candidateIdx + 1
                cands[candidateIdx] = data
            end
        end
    end
    for i = candidateIdx + 1, #cands do
        cands[i] = nil
    end
    prevSkipKey = skipKey
    -- A stopped scan's set lacks the rest rows: never reused or cached.
    if stoppedEarly or epoch ~= searchEpoch then
        prevQuery = ""
    else
        prevQuery = query
        StoreResultCache(cacheKey, cands, candidateIdx)
    end
    if GATE.sawNil and not GATE.fillPending then ScheduleGateMaskFill() end
    if efStats then efStats.lastResults = matchesN; efStats.gated = GATE.gatedN end
    heapProbe.data = nil

    tsort(results, scoreDescending)
    -- Drop stale data refs so a broad-then-narrow search doesn't keep
    -- the broad refs alive forever.
    for i = resultsN + 1, #resultEntryPool do
        local r = resultEntryPool[i]
        if r and r.data then
            r.data = nil
            r.score = nil
            r.isAlias = nil
        end
    end
    return results
end

-- Apply the shipped category gate. SetCategoryMinLen and ResetSearchCache are
-- both defined above, and the static search data was built in Main.lua's
-- load-time Initialize (which loads before this file). Guarded so a failure
-- here leaves search fully working with the gate off, never aborting load.
if Database.SetCategoryMinLen then
    pcall(Database.SetCategoryMinLen, Database, DEFAULT_CATEGORY_MINLEN)
end

-- Debug peek: file-local caches invisible to ns walks, exposed for
-- external diagnostics. Shared references; do not mutate.
function Database:_DebugPeekSearchCaches()
    return { wordCache = wordCache, nameMaskCache = nameMaskCache, wordInitCache = wordInitCache }
end

return Database
