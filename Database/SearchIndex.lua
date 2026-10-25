local _, ns = ...

-- Candidate-generation index for the full-scan search path.
--
-- Replaces "run the scoring ladder on all N entries" with q-gram
-- inverted-index candidate generation (posting-list count filtering, the
-- method behind pg_trgm / q-gram approximate dictionary search), plus
-- class-complete auxiliary filters. The existing scorers then verify and
-- rank ONLY the candidates, so results are identical to the full scan.
--
-- For a query word w, the union of these sets provably contains every
-- entry the scoring ladder can award points to:
--
--   A  contiguous matches (exact / prefix / substring / word boundary):
--      an occurrence of w inside an indexed text contains every bigram of
--      w, so candidates are entries whose posting count equals w's bigram
--      count. A trailing-s stripped variant is unioned for the plural rule.
--   B  prefix-walk initials ("raba" -> RA(ndom) BA(ttleground)): the
--      walk's first segment is a 2+ char prefix of an indexed word, so
--      w's first bigram must START some word -> the word-prefix posting.
--      (For 2-3 char words the whole walk degenerates to a single word
--      prefix, which is a subset of A, so B only runs at 4+ chars.)
--   B2 pure initials ("rb" -> R(ated) B(attlegrounds)): w must equal the
--      first letters of a text's leading words in order, i.e. a PREFIX of
--      the text's initials string -> posting keyed by the first two
--      initials of every multi-word text.
--   C  fuzzy (Damerau <= k) and in-word subsequences: any such match needs
--      all but k of w's a-z chars present in the entry's combined text ->
--      per-entry char-mask sweep with a popcount allowance (k = 0 under
--      4 chars, 1 under 8, 2 at 8+). Runs at 3+ chars; 2-char words have
--      no fuzzy/subsequence/initials classes, so A alone is complete and
--      the sweep is skipped entirely.
--
-- Loot entries match through fields outside this index (lootSlotKw /
-- lootStatKw / lootSourceKw, some enriched lazily), so they are always
-- emitted as candidates and never filtered here. Multi-word queries
-- intersect the per-word unions, mirroring the scan's "every word of 2+
-- chars must match" contract. Statistic-scoped queries rewrite the query
-- per entry, so the caller bypasses the index for those.
--
-- Maintenance: appends index incrementally (provider loads). Postings are
-- keyed by index-time SERIAL, so removals cost one liveness flag each
-- (NoteRemoved) and never a synchronous rebuild; dead postings purge in a
-- deferred compaction that runs only while the search bar is closed.

local Database = ns.Database
local SearchIndex = {}
ns.SearchIndex = SearchIndex

local sbyte, ssub, sfind = string.byte, string.sub, string.find
local band, bor, bnot, lshift, rshift = bit.band, bit.bor, bit.bnot, bit.lshift, bit.rshift
local wipe = wipe
local pairs = pairs
local tsort = table.sort
local getmetatable, rawget = getmetatable, rawget
local SliceCheckpoint = ns.Utils.SliceCheckpoint

-- Keep in sync with Database/Search.lua's fuzzy thresholds.
local FUZZY_EDIT1_LEN, FUZZY_EDIT2_LEN = 5, 8
local ALL_CHARS_MASK = lshift(1, 26) - 1

local dirty = true
local builtCount = 0
-- Postings are keyed by index-time SERIAL, not uiSearchData position, so
-- a removal's array compaction invalidates nothing: dead entries just
-- stop being alive and filter out of candidates, and the postings purge
-- in ONE idle compaction instead of a full synchronous rebuild on the
-- next keystroke. (Position-keyed postings forced that rebuild -- ~250ms
-- and ~10MB of allocation -- every time a provider repopulated
-- mid-typing; the housing stream did it repeatedly per session.)
-- Serials are dense monotonic integers, so every hot table keeps Lua's
-- array part and the candidate sort needs no comparator (ref keys here
-- measurably LOST to the full scan: pointer hashing on every posting
-- hit). slotEntry maps a serial back to its entry at the very end.
-- Posting lists are COMPRESSED: each serial packs to 3 little-endian
-- bytes in a frozen string (vs ~17 bytes per Lua array slot), with a
-- small pending-tail array per key that freezes into the string in
-- batches. Reads decode a whole bucket into one shared scratch array,
-- so the hot counting loops stay plain array iteration. Standard
-- compressed-posting-list design, sized for the measured reality that
-- the postings were the largest resident structure in the addon.
-- The index is a union of SEGMENTS. "live" indexes rows appended one at a
-- time (Grow) and stores global serials as raw bytes. A saved segment
-- (BuildSegment, RestoreSegment) holds one source's rows under a reserved
-- serial run and stores positions within it in printable bytes (35-126),
-- so its tables go to SavedVariables and come back as they are.
local K_GRAM, K_WORD, K_INIT, K_DICT = 1, 2, 3, 4
local function NewSegment(key, saved)
    return {
        key = key, saved = saved, base = 0, n = 0, cap = 0,
        maps = { {}, {}, {}, {} }, tails = { {}, {}, {}, {} },
        dictId = {}, dictWord = {}, dictMask = {}, dictByFirst = {}, dictOne = {}, dictCount = 0,
        memo = {}, memoMulti = {}, memoCount = -1,
    }
end
local live = NewSegment("live", false)
local segments = { live }   -- what queries read
local segByKey = { live = live }
local savedRanges = {}      -- active and building saved segments
local cur = live            -- the segment IndexEntry writes into
-- "ab" -> packed serials + pending; word-leading bigram; leading-initials pair
local gramStr, gramTail = live.maps[K_GRAM], live.tails[K_GRAM]
local wordStr, wordTail = live.maps[K_WORD], live.tails[K_WORD]
local initStr, initTail = live.maps[K_INIT], live.tails[K_INIT]
local entryMask = {}  -- serial -> a-z char mask over name+keywords
local lootIdx = {}    -- serials of loot entries (always candidates)
local slotEntry = {}  -- serial -> entry ref
local serials = {}    -- entry ref -> serial
local alive = {}      -- serial -> true while still in uiSearchData
-- serial -> true: the scorers reach it through what this index does not read
-- (second names, a score bonus, non-ASCII text), so it is never "rest".
local special = {}
local nextSerial = 0
local deadCount = 0
local compactScheduled = false

local FREEZE_AT = 64
local schar = string.char
local tconcat = table.concat
local postScratch = {}   -- shared decode buffer (one bucket at a time)
local freezeBuf = {}     -- shared encode buffer

-- Printable digits: 92 values from byte 35, three to a position (778,687).
local P0 = 35 + 35 * 92 + 35 * 8464
local function Printable3(v)
    local a = v % 92
    local r = (v - a) / 92
    local b = r % 92
    return schar(35 + a, 35 + b, 35 + (r - b) / 92)
end

-- The tail for key frozen into its bucket's chunk list.
local function FreezeTail(strMap, tailMap, key, saved)
    local tail = tailMap[key]
    local n = #tail
    if n == 0 then return end
    for i = 1, n do
        local v = tail[i]
        if saved then
            freezeBuf[i] = Printable3(v)
        else
            freezeBuf[i] = schar(band(v, 255), band(rshift(v, 8), 255), band(rshift(v, 16), 255))
        end
    end
    -- Chunk LIST during build, one concat on first read: the rolling
    -- string concat this replaces was O(n^2) copying on frequent
    -- grams and produced most of the index build's garbage (a 5000-
    -- posting bucket re-copied its whole string ~78 times).
    local bucket = strMap[key]
    if type(bucket) ~= "table" then
        bucket = { bucket }
        strMap[key] = bucket
    end
    bucket[#bucket + 1] = tconcat(freezeBuf, "", 1, n)
    wipe(tail)
end

-- Append serial to the bucket for key, freezing the tail into the
-- packed string once it grows past FREEZE_AT.
local function PostAppend(strMap, tailMap, key, sid, saved)
    local tail = tailMap[key]
    if not tail then tail = {}; tailMap[key] = tail end
    tail[#tail + 1] = sid
    if #tail >= FREEZE_AT then FreezeTail(strMap, tailMap, key, saved) end
end

-- One segment's bucket for key decoded into postScratch after n entries,
-- as global serials; returns the new count.
local function DecodeSeg(seg, kind, key, n)
    local strMap = seg.maps[kind]
    local str = strMap[key]
    if type(str) == "table" then
        -- Finalize the build-time chunk list into the packed string once.
        if str[1] == nil then table.remove(str, 1) end
        str = tconcat(str)
        strMap[key] = str
    end
    if str then
        local len = #str
        local p = 1
        -- Six serials per string.byte call (18 values, under the 22 the
        -- client's API checks allow), then the remainder one at a time.
        if seg.saved then
            local off = seg.base - P0
            while p + 17 <= len do
                local a1, a2, a3, b1, b2, b3, c1, c2, c3, d1, d2, d3, e1, e2, e3, f1, f2, f3 = sbyte(str, p, p + 17)
                postScratch[n + 1] = a1 + a2 * 92 + a3 * 8464 + off
                postScratch[n + 2] = b1 + b2 * 92 + b3 * 8464 + off
                postScratch[n + 3] = c1 + c2 * 92 + c3 * 8464 + off
                postScratch[n + 4] = d1 + d2 * 92 + d3 * 8464 + off
                postScratch[n + 5] = e1 + e2 * 92 + e3 * 8464 + off
                postScratch[n + 6] = f1 + f2 * 92 + f3 * 8464 + off
                n = n + 6
                p = p + 18
            end
            while p + 2 <= len do
                n = n + 1
                local b1, b2, b3 = sbyte(str, p, p + 2)
                postScratch[n] = b1 + b2 * 92 + b3 * 8464 + off
                p = p + 3
            end
        else
            while p + 17 <= len do
                local a1, a2, a3, b1, b2, b3, c1, c2, c3, d1, d2, d3, e1, e2, e3, f1, f2, f3 = sbyte(str, p, p + 17)
                postScratch[n + 1] = a1 + a2 * 256 + a3 * 65536
                postScratch[n + 2] = b1 + b2 * 256 + b3 * 65536
                postScratch[n + 3] = c1 + c2 * 256 + c3 * 65536
                postScratch[n + 4] = d1 + d2 * 256 + d3 * 65536
                postScratch[n + 5] = e1 + e2 * 256 + e3 * 65536
                postScratch[n + 6] = f1 + f2 * 256 + f3 * 65536
                n = n + 6
                p = p + 18
            end
            while p + 2 <= len do
                n = n + 1
                local b1, b2, b3 = sbyte(str, p, p + 2)
                postScratch[n] = b1 + b2 * 256 + b3 * 65536
                p = p + 3
            end
        end
    end
    local tail = seg.tails[kind][key]
    if tail then
        local base = seg.base
        for i = 1, #tail do
            n = n + 1
            postScratch[n] = base + tail[i]
        end
    end
    return n
end

-- Every segment's bucket for key into postScratch; returns count
-- (0 = no such bucket). Callers loop postScratch 1..count.
local function DecodePostings(kind, key)
    local n = 0
    for s = 1, #segments do n = DecodeSeg(segments[s], kind, key, n) end
    return n
end

local seenGrams = {}
-- All index keys are NUMBERS, never substrings: a gram is b1*256+b2, a
-- word-lead the same for the word's first two bytes, an initials pair the
-- same for the two word-initial bytes. The old per-gram/lead/init ssub was
-- the warm's largest single allocator (measured in the warmledger). The
-- bases keep the three key classes distinct inside the shared per-entry
-- seenGrams dedupe table; the storage maps are separate and unprefixed.
local WORD_SEEN_BASE = 65536
local INIT_SEEN_BASE = 131072
local counts = {}
local wordSet = {}
-- With split: rows that can score above a mid-word substring (a word lead,
-- an initials, walk or dictionary match); the rest of wordSet cannot.
local strongSet = {}
local resultSet = {}
local candBuf = {}

local function maskOf(s, m)
    for i = 1, #s do
        local b = sbyte(s, i)
        if b >= 97 and b <= 122 then m = bor(m, lshift(1, b - 97)) end
    end
    return m
end

-- The word dictionary (class D): every word of 3+ bytes the scorers cut
-- from names and keywords, and each whole keyword, with the serials that
-- hold it. Typo and abbreviation matches are word against word with the
-- first letter fixed, so a query word tests only the words under its
-- first letter instead of masking every entry.
-- Each segment has its own (dictId, dictWord, dictMask, dictByFirst). Most
-- words sit in one entry: the first entry is kept in dictOne and only a
-- second one opens a posting bucket (K_DICT).
local seenWords = {}
local tokenBuf = {}
local gmatch = string.gmatch

local function PostWord(e, w)
    if #w < 3 then return end
    local seg = cur
    local id = seg.dictId[w]
    if not id then
        id = seg.dictCount + 1
        seg.dictCount = id
        seg.dictId[w], seg.dictWord[id] = id, w
        seg.dictMask[id] = maskOf(w, 0)
        local b = sbyte(w, 1)
        local list = seg.dictByFirst[b]
        if not list then list = {}; seg.dictByFirst[b] = list end
        list[#list + 1] = id
    end
    if not seenWords[id] then
        seenWords[id] = true
        if seg.dictOne[id] then
            PostAppend(seg.maps[K_DICT], seg.tails[K_DICT], id, e, seg.saved)
        else
            seg.dictOne[id] = e
        end
    end
end

-- Words as the scorers cut text (Search.lua GetWords).
local function Cut(text)
    if not sfind(text, "[\128-\255]") then
        local n = 0
        for w in gmatch(text, "[%w']+") do
            n = n + 1
            tokenBuf[n] = w
        end
        for i = n + 1, #tokenBuf do tokenBuf[i] = nil end
        return tokenBuf, n
    end
    local words = ns.SearchText.Tokenize(text)
    return words, #words
end

-- Indexes one text of entry e, deduped per entry through seenGrams and
-- seenWords (the caller wipes both per entry). The contiguous class takes
-- the bigrams of space-cut chunks: query words never contain spaces, so
-- that is a superset however the scorers cut. Word leads, initials and
-- the dictionary follow the scorers' own words.
local function IndexText(e, text, isKeyword)
    local seg = cur
    local saved = seg.saved
    local gm, gt = seg.maps[K_GRAM], seg.tails[K_GRAM]
    local wordStart = 1
    local len = #text
    for p = 1, len + 1 do
        local b = p <= len and sbyte(text, p) or 32
        if b == 32 then
            if p - wordStart >= 2 then
                for g = wordStart, p - 2 do
                    local g1, g2 = sbyte(text, g, g + 1)
                    local gram = g1 * 256 + g2
                    if not seenGrams[gram] then
                        seenGrams[gram] = true
                        PostAppend(gm, gt, gram, e, saved)
                    end
                end
            end
            wordStart = p + 1
        end
    end
    local words, n = Cut(text)
    for i = 1, n do
        local w = words[i]
        if #w >= 2 then
            local b1, b2 = sbyte(w, 1, 2)
            local lead = b1 * 256 + b2
            if not seenGrams[WORD_SEEN_BASE + lead] then
                seenGrams[WORD_SEEN_BASE + lead] = true
                PostAppend(seg.maps[K_WORD], seg.tails[K_WORD], lead, e, saved)
            end
        end
        PostWord(e, w)
    end
    -- A whole keyword is compared as one word too (ScoreSingleFieldWord).
    if isKeyword and not (n == 1 and words[1] == text) then PostWord(e, text) end
    -- First letters of the two leading words anchor the pure-initials
    -- class (1-char words count as words there).
    if n >= 2 then
        local key = sbyte(words[1], 1) * 256 + sbyte(words[2], 1)
        if not seenGrams[INIT_SEEN_BASE + key] then
            seenGrams[INIT_SEEN_BASE + key] = true
            PostAppend(seg.maps[K_INIT], seg.tails[K_INIT], key, e, saved)
        end
    end
end

local function IndexEntry(data)
    -- Idempotent: after a removal compacts uiSearchData, already-indexed
    -- entries shift into the "new" position range; re-adding them would
    -- duplicate postings.
    local sid = serials[data]
    if sid then
        alive[sid] = true
        return
    end
    -- e: the position the segment's postings store (live: the serial).
    local seg, e = cur
    if seg.saved then
        e = seg.n + 1
        seg.n = e
        sid = seg.base + e
    else
        nextSerial = nextSerial + 1
        sid = nextSerial
        e = sid
    end
    serials[data] = sid
    slotEntry[sid] = data
    alive[sid] = true
    if data.lootEntry then
        lootIdx[#lootIdx + 1] = sid
        -- Full mask so the sweep classes never reject loot either.
        entryMask[sid] = ALL_CHARS_MASK
        return
    end
    wipe(seenGrams)
    wipe(seenWords)
    local m = 0
    -- Corpus stubs (metatable-tagged) index from transient decodes so the
    -- index build never hydrates them; the values are dropped after this.
    -- KeywordsOf serves per-row keywords (bosses); corpora without them
    -- fall through to the proto's shared keyword list.
    local nameLower, kws
    local mt = getmetatable(data)
    local pc = mt and rawget(mt, "__pcCorpus")
    if pc then
        local ri = rawget(data, "_ri")
        nameLower = pc:NameLowerOf(ri)
        kws = pc:KeywordsOf(ri)
    else
        nameLower = data.nameLower
    end
    if nameLower then
        m = maskOf(nameLower, m)
        IndexText(e, nameLower)
        if sfind(nameLower, "[\128-\255]") then special[sid] = true end
    end
    kws = kws or data.keywordsLower or data.keywords
    if kws then
        for k = 1, #kws do
            local kw = kws[k]
            if kw then
                m = maskOf(kw, m)
                IndexText(e, kw, true)
                if sfind(kw, "[\128-\255]") then special[sid] = true end
            end
        end
    end
    -- Corpus stubs never carry these (PackedCorpus specs hold none).
    if not pc and (rawget(data, "snippetKeywordLower") or rawget(data, "teleportNameLower")
                   or rawget(data, "scoreBonus")) then
        special[sid] = true
    end
    entryMask[sid] = m
end

local function InSaved(sid)
    for i = 1, #savedRanges do
        local seg = savedRanges[i]
        if sid > seg.base and sid <= seg.base + seg.cap then return seg end
    end
    return nil
end

local function WipeSegment(seg)
    for k = 1, 4 do wipe(seg.maps[k]); wipe(seg.tails[k]) end
    wipe(seg.dictId); wipe(seg.dictWord); wipe(seg.dictMask); wipe(seg.dictByFirst); wipe(seg.dictOne)
    wipe(seg.memo); wipe(seg.memoMulti)
    seg.dictCount, seg.memoCount = 0, -1
end

-- A rebuild of "live" starts over empty; its entries index again through
-- Grow. Saved segments keep their rows.
local function Restart()
    WipeSegment(live)
    if #savedRanges == 0 then
        wipe(entryMask)
        wipe(special)
        wipe(lootIdx)
        wipe(slotEntry)
        wipe(serials)
        wipe(alive)
        nextSerial = 0
    else
        for sid, data in pairs(slotEntry) do
            if not InSaved(sid) then
                slotEntry[sid], alive[sid], entryMask[sid], special[sid] = nil, nil, nil, nil
                if serials[data] == sid then serials[data] = nil end
            end
        end
        local n = 0
        for i = 1, #lootIdx do
            if InSaved(lootIdx[i]) then
                n = n + 1
                lootIdx[n] = lootIdx[i]
            end
        end
        for i = #lootIdx, n + 1, -1 do lootIdx[i] = nil end
    end
    deadCount = 0
    builtCount = 0
    dirty = false
end

-- A search never builds the index past this: the rest of the unindexed
-- tail is scored by the sliced scan, and the background build catches up.
local QUERY_BUILD_MS = 2
-- Background slices; while searches run (one in the last second), more.
local lastQueryAt = -10
local function GrowBudget()
    return (GetTime() - lastQueryAt) < 1 and 4 or 2
end
-- Set while a search sits between its index reads: the background build
-- waits, so postings never change under a half-read query.
local reading = false
local growing = false

-- Indexes appended entries until budgetMs is spent (all of them with no
-- clock); true when caught up.
local function Grow(budgetMs)
    if reading then return false end
    if dirty then Restart() end
    local dataArr = Database.uiSearchData
    local n = #dataArr
    -- Removal compactions can shrink the array; ref-keyed postings do not
    -- care (NoteRemoved handled liveness), only the append watermark moves.
    if builtCount >= n then
        builtCount = n
        return true
    end
    local dps = debugprofilestop
    local start = dps and dps() or 0
    local i = builtCount + 1
    while i <= n do
        IndexEntry(dataArr[i])
        i = i + 1
        if dps and (dps() - start) >= budgetMs then break end
    end
    builtCount = i - 1
    return builtCount >= n
end

-- The watermark is read afresh per entry, so a query's own Grow or a
-- compaction between slices never makes this index an entry twice.
local function GrowSliced()
    while true do
        while reading do coroutine.yield() end
        if dirty then Restart() end
        local data = Database.uiSearchData[builtCount + 1]
        if not data then return end
        IndexEntry(data)
        builtCount = builtCount + 1
        if band(builtCount, 31) == 0 then SliceCheckpoint() end
    end
end

-- Next frame, never inline: a sliced run started inside another one
-- would end the outer run's slice deadline.
local function ScheduleGrow()
    if growing then return end
    growing = true
    ns.Utils.SafeAfter(0, function()
        ns.Utils.RunSliced(GrowSliced, function(ok, err)
            growing = false
            if not ok then return ns.Utils.ErrorHandler(err) end
            if dirty or builtCount < #Database.uiSearchData then ScheduleGrow() end
        end, GrowBudget, "indexGrow")
    end)
end

-- Budgeted build for the warm chain, between provider loads; true when
-- caught up.
function SearchIndex:EnsureBudget(budgetMs)
    if Grow(budgetMs) then return true end
    ScheduleGrow()
    return false
end

function SearchIndex:MarkDirty()
    dirty = true
end

-- A search run dropped between its reads: the build may go on.
function SearchIndex:ReadCanceled()
    reading = false
end

-- A removed entry stops being a candidate IMMEDIATELY (liveness check in
-- Candidates); its postings linger until one deferred compaction purges
-- them, instead of a full rebuild on the next keystroke.
local function TryCompact()
    compactScheduled = false
    if deadCount == 0 then return end
    -- Never compact under the user's fingers: the rebuild is the very
    -- hitch this design removed from the keystroke path. With the bar
    -- open, re-arm and wait for it to close.
    local sf = ns.Search and ns.Search.GetSearchFrame and ns.Search:GetSearchFrame()
    if sf and sf:IsShown() then
        compactScheduled = true
        ns.Utils.SafeAfter(5, TryCompact)
        return
    end
    dirty = true
    ScheduleGrow()
end

-- Compactions can remove K entries and later appends can restore the SAME
-- array length before any query runs; a purely positional watermark then
-- sees builtCount == n and never indexes the replacements (the settings
-- live-walk refresh shipped exactly this hole: gated found 0 of 63).
-- Every compaction site reports its post-truncation length here.
--
-- Truncation alone is not enough: a compaction also shifts survivors DOWN,
-- and survivors that were appended but never indexed (no query ran between
-- the append and this compaction) can land below the watermark, where
-- Ensure never looks again -- a permanent candidate hole (109 command
-- entries and 606 settings entries sat exactly there). The watermark's
-- invariant is "every entry at or below it has postings", so re-derive it
-- as the longest fully-indexed prefix. Compactions are per-populate, not
-- per-keystroke, so the O(n) serial-lookup walk is off the hot path.
function SearchIndex:NoteCompacted(n)
    if n < builtCount then builtCount = n end
    local dataArr = Database.uiSearchData
    for i = 1, builtCount do
        if not serials[dataArr[i]] then
            builtCount = i - 1
            return
        end
    end
end

-- In-place replacement (same array slot, new object): retire the old
-- entry's serial and index the replacement immediately.
function SearchIndex:NoteReplaced(oldEntry, newEntry)
    if oldEntry then self:NoteRemoved(oldEntry) end
    if newEntry then IndexEntry(newEntry) end
end

function SearchIndex:NoteRemoved(entry)
    local sid = serials[entry]
    if not sid or not alive[sid] then return end
    alive[sid] = nil
    -- A saved segment's postings go with the segment (DropSegment).
    if InSaved(sid) then return end
    deadCount = deadCount + 1
    if not compactScheduled and ns.Utils and ns.Utils.SafeAfter then
        compactScheduled = true
        ns.Utils.SafeAfter(2, TryCompact)
    end
end

-- A row a segment takes over: its serial elsewhere dies (live's postings
-- purge in the next compaction).
local function Release(data)
    if serials[data] then SearchIndex:NoteRemoved(data) end
    serials[data] = nil
end

-- ==== saved segments ======================================================
-- One source's rows indexed apart from "live" and saved with their rows, so
-- a later session restores them instead of indexing anything. Bump the
-- schema when a segment's shape changes: older snapshots then rebuild.
local SEGMENT_SCHEMA = 1
local tinsert = table.insert

local function Unprintable3(s, p)
    local a, b, c = sbyte(s, p, p + 2)
    return a + b * 92 + c * 8464 - P0
end
local function Printable4(v)
    local low = v % 778688
    return Printable3(low) .. schar(35 + (v - low) / 778688)
end
local function Unprintable4(s, p)
    return Unprintable3(s, p) + (sbyte(s, p + 3) - 35) * 778688
end

-- Every tail into the strings and every chunk list into one string.
local function FreezeSegment(seg)
    for k = 1, 4 do
        local strMap, tailMap = seg.maps[k], seg.tails[k]
        for key in pairs(tailMap) do FreezeTail(strMap, tailMap, key, true) end
        wipe(tailMap)
        for key, v in pairs(strMap) do
            if type(v) == "table" then
                if v[1] == nil then table.remove(v, 1) end
                strMap[key] = tconcat(v)
            end
        end
    end
end

-- A row's indexed name, read from a corpus stub without hydrating it.
local function RowNameLower(data)
    local mt = getmetatable(data)
    local pc = mt and rawget(mt, "__pcCorpus")
    if pc then return pc:NameLowerOf(rawget(data, "_ri")) end
    return data.nameLower
end

-- Every 64th row's name: a restore over rows that shifted or changed is refused.
local CHECK_EVERY = 64

local function Unlist(list, seg)
    for i = #list, 1, -1 do
        if list[i] == seg then table.remove(list, i) end
    end
end

-- The segment's rows forget their serials; its strings go with it.
local function RemoveRows(seg)
    local base = seg.base
    for i = 1, seg.n do
        local sid = base + i
        local data = slotEntry[sid]
        if data and serials[data] == sid then serials[data] = nil end
        slotEntry[sid], alive[sid], entryMask[sid], special[sid] = nil, nil, nil, nil
    end
    local n = 0
    for i = 1, #lootIdx do
        local sid = lootIdx[i]
        if sid <= base or sid > base + seg.cap then
            n = n + 1
            lootIdx[n] = sid
        end
    end
    for i = #lootIdx, n + 1, -1 do lootIdx[i] = nil end
end

local function Deactivate(seg, rewalk)
    Unlist(segments, seg)
    Unlist(savedRanges, seg)
    if segByKey[seg.key] == seg then segByKey[seg.key] = nil end
    RemoveRows(seg)
    -- Its rows still in uiSearchData index into "live" instead.
    if rewalk then builtCount = 0 end
end

local function Activate(seg)
    local old = segByKey[seg.key]
    if old and old ~= seg then Deactivate(old, false) end
    segByKey[seg.key] = seg
    -- Order is free: candidates sort by serial.
    tinsert(segments, 1, seg)
end

-- Indexes rows as segment key in the background, under a serial run of its
-- own; a segment of that key answers until this one replaces it. The caller
-- swaps the rows in uiSearchData in onDone(true), in the same call.
function SearchIndex:BuildSegment(key, rows, onDone)
    local seg = NewSegment(key, true)
    seg.base, seg.cap = nextSerial, #rows
    nextSerial = nextSerial + #rows
    savedRanges[#savedRanges + 1] = seg
    local function run()
        for i = 1, #rows do
            local data = rows[i]
            Release(data)
            cur = seg
            IndexEntry(data)
            cur = live
            if band(i, 31) == 0 then SliceCheckpoint() end
        end
        if seg.n ~= #rows then error("BuildSegment: a row is listed twice in " .. tostring(key)) end
        FreezeSegment(seg)
        while reading do coroutine.yield() end
        Activate(seg)
    end
    ns.Utils.RunSliced(run, function(ok, err)
        cur = live
        if not ok then
            Unlist(savedRanges, seg)
            RemoveRows(seg)
            ns.Utils.ErrorHandler(err)
        end
        if onDone then onDone(ok) end
    end, GrowBudget, "indexSegment")
end

-- What SavedVariables keep for segment key: its own tables and printable
-- strings. nil when it has none or a row of it died (rebuild it instead).
function SearchIndex:SegmentSnapshot(key)
    local seg = segByKey[key]
    if not (seg and seg.saved) then return nil end
    FreezeSegment(seg)
    local base, n = seg.base, seg.n
    local masks, sp, lt = {}, {}, {}
    for i = 1, n do
        local sid = base + i
        if not alive[sid] then return nil end
        masks[i] = Printable4(entryMask[sid] or 0)
        if special[sid] then sp[#sp + 1] = Printable3(i) end
        local data = slotEntry[sid]
        if data and data.lootEntry then lt[#lt + 1] = Printable3(i) end
    end
    local dmask, ones = {}, {}
    for id = 1, seg.dictCount do
        dmask[id] = Printable4(seg.dictMask[id])
        ones[id] = Printable3(seg.dictOne[id])
    end
    local check = {}
    for i = 1, n, CHECK_EVERY do check[#check + 1] = RowNameLower(slotEntry[base + i]) or "" end
    return {
        v = SEGMENT_SCHEMA, n = n, dictCount = seg.dictCount, check = check,
        gram = seg.maps[K_GRAM], word = seg.maps[K_WORD], init = seg.maps[K_INIT], dict = seg.maps[K_DICT],
        words = tconcat(seg.dictWord, "\n", 1, seg.dictCount), dictMask = tconcat(dmask), ones = tconcat(ones),
        masks = tconcat(masks), special = tconcat(sp), loot = tconcat(lt),
    }
end

-- Restores segment key from its snapshot over the same rows in the same
-- order (stubs of its saved blob); false when the snapshot does not fit.
function SearchIndex:RestoreSegment(key, snap, rows)
    if reading or type(snap) ~= "table" or snap.v ~= SEGMENT_SCHEMA or snap.n ~= #rows then return false end
    local words, dmask, ones, em = snap.words, snap.dictMask, snap.ones, snap.masks
    local dc = snap.dictCount
    if type(words) ~= "string" or type(dc) ~= "number" or #dmask ~= dc * 4 or #ones ~= dc * 3
       or #em ~= snap.n * 4 or type(snap.check) ~= "table" then
        return false
    end
    local n = snap.n
    local check = snap.check
    for c = 1, #check do
        local row = rows[(c - 1) * CHECK_EVERY + 1]
        if not row or (RowNameLower(row) or "") ~= check[c] then return false end
    end
    local seg = NewSegment(key, true)
    seg.base, seg.cap, seg.n = nextSerial, n, n
    seg.maps = { snap.gram or {}, snap.word or {}, snap.init or {}, snap.dict or {} }
    local dictId, dictWord, dictMask, dictByFirst, dictOne =
        seg.dictId, seg.dictWord, seg.dictMask, seg.dictByFirst, seg.dictOne
    local id = 0
    for w in gmatch(words, "[^\n]+") do
        id = id + 1
        dictId[w], dictWord[id] = id, w
        dictMask[id] = Unprintable4(dmask, id * 4 - 3)
        dictOne[id] = Unprintable3(ones, id * 3 - 2)
        local b = sbyte(w, 1)
        local list = dictByFirst[b]
        if not list then list = {}; dictByFirst[b] = list end
        list[#list + 1] = id
    end
    if id ~= dc then return false end
    seg.dictCount = id
    nextSerial = nextSerial + n
    local base = seg.base
    for i = 1, n do
        local data = rows[i]
        Release(data)
        local sid = base + i
        serials[data], slotEntry[sid], alive[sid] = sid, data, true
        entryMask[sid] = Unprintable4(em, i * 4 - 3)
    end
    local sp, lt = snap.special or "", snap.loot or ""
    for q = 1, #sp, 3 do special[base + Unprintable3(sp, q)] = true end
    for q = 1, #lt, 3 do lootIdx[#lootIdx + 1] = base + Unprintable3(lt, q) end
    savedRanges[#savedRanges + 1] = seg
    Activate(seg)
    return true
end

-- Segment key leaves the index; rows of it left in uiSearchData index into
-- "live" on the next build step.
function SearchIndex:DropSegment(key)
    local seg = segByKey[key]
    if not (seg and seg.saved) then return false end
    Deactivate(seg, true)
    return true
end

-- Search.lua's IsSubsequence: the first letters equal, the rest in order,
-- the greedy match ending within 2 * qLen - 1 bytes.
local function Subsequence(x, q, qLen, xLen)
    local xi = 1
    for qi = 1, qLen do
        local qc = sbyte(q, qi)
        while xi <= xLen and sbyte(x, xi) ~= qc do xi = xi + 1 end
        if xi > xLen then return false end
        xi = xi + 1
    end
    return xi - 1 <= qLen * 2 - 1
end

-- More than k bits set in m.
local function OverBits(m, k)
    local n = 0
    while m ~= 0 do
        m = band(m, m - 1)
        n = n + 1
        if n > k then return true end
    end
    return false
end

-- Search.lua's DamerauLevenshtein (optimal string alignment) is at most k.
-- Each edit drops or adds at most one distinct letter, so more than k
-- letters missing either way rules a pair out before the table.
local osaPrev2, osaPrev, osaCurr = {}, {}, {}
local function WithinEdits(a, b, la, lb, k, am, bm)
    local d = la - lb
    if d > k or -d > k then return false end
    if OverBits(band(am, bnot(bm)), k) or OverBits(band(bm, bnot(am)), k) then return false end
    local prev2, prev, curr = osaPrev2, osaPrev, osaCurr
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        curr[0] = i
        local rowMin = i
        local ca = sbyte(a, i)
        local caPrev = i > 1 and sbyte(a, i - 1) or nil
        for j = 1, lb do
            local cb = sbyte(b, j)
            local cost = ca == cb and 0 or 1
            local v = prev[j] + 1
            local ins = curr[j - 1] + 1
            if ins < v then v = ins end
            local sub = prev[j - 1] + cost
            if sub < v then v = sub end
            if i > 1 and j > 1 and ca == sbyte(b, j - 1) and caPrev == cb then
                local t = prev2[j - 2] + cost
                if t < v then v = t end
            end
            curr[j] = v
            if v < rowMin then rowMin = v end
        end
        if rowMin > k then return false end
        prev2, prev, curr = prev, curr, prev2
    end
    return prev[lb] <= k
end

-- The dictionary words a query word can reach by typo or abbreviation:
-- the first letters equal (or the first pair swapped, for a typo), as
-- every scorer path requires. Memoized until the dictionary grows.
-- Each segment memoizes its own; a saved one never grows, so the memos are
-- capped by count instead of being dropped when the dictionary grows.
local NO_HITS = {}
local memoEntries, MEMO_CAP = 0, 4096

-- A word the scorers would score as an abbreviation of the query word: twice
-- as long under 5 chars (ScoreName), at most L / 0.6 for any length up to 8
-- (ScoreKeywords takes it under 5 chars too), and ScoreSingleFieldWord's
-- 0.45 window, which only runs for queries of two or more words.
local function AbbrevLength(L, xl, multi)
    if xl <= L or L > 8 then return false end
    if (L <= 4 and xl >= L * 2) or L / xl >= 0.6 then return true end
    return multi and L >= 3 and L / xl >= 0.45 or false
end

local function MatchingWords(seg, qw, L, multi)
    if seg.memoCount ~= seg.dictCount then
        wipe(seg.memo)
        wipe(seg.memoMulti)
        seg.memoCount = seg.dictCount
    end
    local memo = multi and seg.memoMulti or seg.memo
    local hit = memo[qw]
    if hit then return hit end
    if memoEntries >= MEMO_CAP then
        for s = 1, #segments do wipe(segments[s].memo); wipe(segments[s].memoMulti) end
        memoEntries = 0
    end
    memoEntries = memoEntries + 1
    hit = {}
    local dictWord, dictMask, dictByFirst = seg.dictWord, seg.dictMask, seg.dictByFirst
    local q1, q2 = sbyte(qw, 1, 2)
    local qm = maskOf(qw, 0)
    local k = L >= FUZZY_EDIT2_LEN and 2 or (L >= FUZZY_EDIT1_LEN and 1 or 0)
    local list = dictByFirst[q1]
    for i = 1, list and #list or 0 do
        if band(i, 511) == 0 then SliceCheckpoint() end
        local id = list[i]
        local x = dictWord[id]
        local xl = #x
        if (AbbrevLength(L, xl, multi) and Subsequence(x, qw, L, xl))
           or (k > 0 and WithinEdits(qw, x, L, xl, k, qm, dictMask[id])) then
            hit[#hit + 1] = id
        end
    end
    if k > 0 and q2 and q2 ~= q1 then
        list = dictByFirst[q2]
        for i = 1, list and #list or 0 do
            local id = list[i]
            local x = dictWord[id]
            if sbyte(x, 2) == q1 and WithinEdits(qw, x, L, #x, k, qm, dictMask[id]) then hit[#hit + 1] = id end
        end
    end
    if #hit == 0 then hit = NO_HITS end
    memo[qw] = hit
    return hit
end

-- How many serials the segments' buckets hold, without decoding them.
local function PostingCount(kind, key)
    local n, t = 0, 0
    for s = 1, #segments do
        local seg = segments[s]
        local str = seg.maps[kind][key]
        if type(str) == "table" then
            for i = 1, #str do n = n + #str[i] end
        elseif str then
            n = n + #str
        end
        local tail = seg.tails[kind][key]
        if tail then t = t + #tail end
    end
    return n / 3 + t
end

-- The texts IndexEntry reads (corpus stubs through transient decodes)
-- hold w as one run: a plain find per text, far cheaper than scoring.
local function HoldsText(sid, w)
    local data = slotEntry[sid]
    local nameLower, kws
    local mt = getmetatable(data)
    local pc = mt and rawget(mt, "__pcCorpus")
    if pc then
        local ri = rawget(data, "_ri")
        nameLower = pc:NameLowerOf(ri)
        kws = pc:KeywordsOf(ri)
    else
        nameLower = data.nameLower
    end
    if nameLower and sfind(nameLower, w, 1, true) then return true end
    kws = kws or data.keywordsLower or data.keywords
    for k = 1, kws and #kws or 0 do
        local kw = kws[k]
        if kw and sfind(kw, w, 1, true) then return true end
    end
    return false
end

-- Class A: entries holding w's two rarest bigrams, kept only when they hold
-- w itself. Decoding every bigram's bucket was most of a search's cost
-- (common pairs hold thousands of serials).
local function AddContiguous(w)
    local wl = #w
    if wl < 2 then return end
    local rare1, rare2, n1, n2
    for g = 1, wl - 1 do
        local g1, g2 = sbyte(w, g, g + 1)
        local gram = g1 * 256 + g2
        if gram ~= rare1 and gram ~= rare2 then
            local n = PostingCount(K_GRAM, gram)
            if n == 0 then return end
            if not n1 or n < n1 then
                rare2, n2, rare1, n1 = rare1, n1, gram, n
            elseif not n2 or n < n2 then
                rare2, n2 = gram, n
            end
        end
    end
    local pn = DecodePostings(K_GRAM, rare1)
    if not rare2 then
        for pi = 1, pn do wordSet[postScratch[pi]] = true end
        return
    end
    wipe(counts)
    for pi = 1, pn do counts[postScratch[pi]] = true end
    pn = DecodePostings(K_GRAM, rare2)
    -- Holding both bigrams apart is not holding the run.
    for pi = 1, pn do
        local e = postScratch[pi]
        if counts[e] and not wordSet[e] and HoldsText(e, w) then wordSet[e] = true end
    end
end

-- Union of classes A/B/C for one query word into wordSet.
local function CollectWord(qw, multi, split)
    wipe(wordSet)
    if split then wipe(strongSet) end
    local L = #qw
    AddContiguous(qw)
    if L >= 3 and sbyte(qw, L) == 115 then
        AddContiguous(ssub(qw, 1, L - 1))
    end
    -- B2 pure initials: qw must prefix a text's initials string, so its
    -- first two chars equal the text's first two initials; the mask trims
    -- texts that lack qw's remaining letters.
    local qb1, qb2 = sbyte(qw, 1, 2)
    local leadKey = qb1 * 256 + qb2
    do
        local pn = DecodePostings(K_INIT, leadKey)
        if pn > 0 then
            local qm = maskOf(qw, 0)
            for pi = 1, pn do
                local e = postScratch[pi]
                if band(qm, entryMask[e]) == qm then
                    wordSet[e] = true
                    if split then strongSet[e] = true end
                end
            end
        end
    end
    -- A word led by qw's first pair can take the prefix and word-start tiers.
    if split then
        local pn = DecodePostings(K_WORD, leadKey)
        for pi = 1, pn do strongSet[postScratch[pi]] = true end
    end
    -- B prefix walk: the first segment leads a word with qw's first two
    -- chars, the second (2+ chars, from position j >= 3) leads a later word,
    -- so an entry needs a word lead for some pair qw[j..j+1] as well.
    if L >= 4 then
        local pn = DecodePostings(K_WORD, leadKey)
        if pn > 0 then
            local qm = maskOf(qw, 0)
            wipe(counts)
            local leads = 0
            for pi = 1, pn do
                local e = postScratch[pi]
                if not wordSet[e] and band(qm, entryMask[e]) == qm then
                    counts[e] = true
                    leads = leads + 1
                end
            end
            for j = 3, leads > 0 and L - 1 or 0 do
                local s1, s2 = sbyte(qw, j, j + 1)
                local key = s1 * 256 + s2
                local seenKey = false
                for k = 3, j - 1 do
                    local k1, k2 = sbyte(qw, k, k + 1)
                    if k1 * 256 + k2 == key then seenKey = true break end
                end
                if not seenKey then
                    local sn = DecodePostings(K_WORD, key)
                    for pi = 1, sn do
                        local e = postScratch[pi]
                        if counts[e] then
                            wordSet[e] = true
                            counts[e] = nil
                        end
                    end
                end
            end
        end
    end
    -- D: the entries holding a word the query word reaches by typo or
    -- abbreviation (2-char words have neither).
    if L >= 3 then
        for s = 1, #segments do
            local seg = segments[s]
            local ids = MatchingWords(seg, qw, L, multi)
            local base, ones = seg.base, seg.dictOne
            for i = 1, #ids do
                local id = ids[i]
                local one = base + ones[id]
                wordSet[one] = true
                if split then strongSet[one] = true end
                local pn = DecodeSeg(seg, K_DICT, id, 0)
                for pi = 1, pn do
                    local e = postScratch[pi]
                    wordSet[e] = true
                    if split then strongSet[e] = true end
                end
            end
        end
    end
    for li = 1, #lootIdx do
        wordSet[lootIdx[li]] = true
        if split then strongSet[lootIdx[li]] = true end
    end
end

-- Returns (candidateArray, count) for the query's words, or nil when the
-- index cannot serve the query (no usable word). Candidates come out in
-- ascending uiSearchData position -- the same iteration order as the full
-- scan -- so the result cap keeps the exact same tie subset the scan would.
-- Entries past the watermark the index has not seen come last, unfiltered.
-- With split (one query word), the rows that can score no more than a mid-word
-- name substring come after everything else, from the third return on, so the
-- scan can stop before them once its kept rows all score higher.
local restBuf = {}
function SearchIndex:Candidates(queryWords, split)
    -- A synchronous caller that failed between its reads never cleared it.
    reading = false
    lastQueryAt = GetTime()
    local dataArr = Database.uiSearchData
    if not Grow(QUERY_BUILD_MS) then ScheduleGrow() end
    if builtCount == 0 then return nil end
    local tailFrom, readSerial = builtCount, nextSerial
    reading = true
    wipe(resultSet)
    local first = true
    local usable = 0
    -- Two or more words run ScoreEntryFields, which takes looser abbreviations.
    local multi = #queryWords >= 2
    split = split and not multi
    for qi = 1, #queryWords do
        local qw = queryWords[qi]
        if #qw >= 2 then
            usable = usable + 1
            CollectWord(qw, multi, split)
            if first then
                first = false
                for e in pairs(wordSet) do
                    resultSet[e] = true
                end
            else
                for e in pairs(resultSet) do
                    if not wordSet[e] then
                        resultSet[e] = nil
                    end
                end
            end
        end
    end
    reading = false
    if usable == 0 then return nil end
    local n, rn = 0, 0
    for sid in pairs(resultSet) do
        if alive[sid] then
            if split and not strongSet[sid] and not special[sid] then
                rn = rn + 1
                restBuf[rn] = sid
            else
                n = n + 1
                candBuf[n] = sid
            end
        end
    end
    for i = n + 1, #candBuf do
        candBuf[i] = nil
    end
    for i = rn + 1, #restBuf do
        restBuf[i] = nil
    end
    -- Serial order == index-time order == uiSearchData append order, so
    -- ties resolve exactly as the full scan's iteration would.
    tsort(candBuf)
    for i = 1, n do
        candBuf[i] = slotEntry[candBuf[i]]
    end
    -- A compaction while this query yielded can lower the watermark.
    if builtCount < tailFrom then tailFrom = builtCount end
    for i = tailFrom + 1, #dataArr do
        local data = dataArr[i]
        local sid = serials[data]
        if not sid or sid > readSerial then
            n = n + 1
            candBuf[n] = data
        end
    end
    local restFrom
    if rn > 0 then
        restFrom = n + 1
        tsort(restBuf)
        for i = 1, rn do candBuf[n + i] = slotEntry[restBuf[i]] end
        n = n + rn
    end
    return candBuf, n, restFrom
end

-- Debug peek: file-local structures are invisible to table walks from
-- ns; this hands external diagnostics the real internals. Returns
-- shared references; callers must not mutate.
function SearchIndex:_DebugPeek()
    return {
        gramStr = gramStr, gramTail = gramTail, wordStr = wordStr,
        wordTail = wordTail, initStr = initStr, initTail = initTail,
        entryMask = entryMask, lootIdx = lootIdx, slotEntry = slotEntry,
        serials = serials, alive = alive, builtCount = builtCount,
        dictId = live.dictId, dictOne = live.dictOne, dictTail = live.tails[K_DICT], dictStr = live.maps[K_DICT],
        dictCount = live.dictCount, segments = segments,
    }
end
