-- Part of the EasyFind_Icons LoadOnDemand companion: loaded on first
-- icon-search use via ns.RequestIconSearch(), never at login.
local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns or select(2, ...).stale then return end

-- Icon search data layer (GitHub #22). An icon matches by its file name
-- or by the name of a spell that wears it; both are scanned in place.
--
-- Query syntax:
--   word word          every word must match (AND); "swords" tries "sword"
--   sword/axe          a word with alternatives: either matches
--   axe, mace 2h       comma splits whole alternative queries
--   -word              the word must NOT match
--   inv_sword_*        * and ? make the word a whole-name wildcard match
--   135274 or #135274  FileDataIDs by prefix, the full ID first (# = IDs only)
--   spell:133 item:6948 achievement:12   the icon that thing uses

local IconSearch = {}
ns.IconSearch = IconSearch

local Utils = ns.Utils
local sfind, ssub = Utils.sfind, Utils.ssub
local slower = Utils.slower or string.lower
local mfloor = Utils.mfloor
local tconcat = Utils.tconcat or table.concat
local tonumber = tonumber
local wipe = wipe

-- A corpus: "name\t<number>\n" records in one string, two int arrays
-- (name start, tab) indexing it, and its per-keystroke match stamps.
local function NewCorpus()
    return { offsets = {}, tabs = {}, total = 0, mark = {}, hit = {}, matched = {} }
end

-- icons: file name and FileDataID, ascending. spells: a spell's name;
-- iconOf and spellOf give its icon record and spell ID.
local icons, spells = NewCorpus(), NewCorpus()

local function IndexCorpus(c)
    local blob = c.blob
    if c.total > 0 or not blob then return c.total end
    local len, offsets, tabs = #blob, c.offsets, c.tabs
    local pos, n = 1, 0
    while pos <= len do
        local nl = sfind(blob, "\n", pos, true) or (len + 1)
        local tab = sfind(blob, "\t", pos, true)
        if tab and tab < nl then
            n = n + 1
            offsets[n] = pos
            tabs[n] = tab
        end
        pos = nl + 1
    end
    c.total = n
    return n
end

local function EnsureIndex()
    if not icons.blob then
        local b = ns.ICON_SEARCH_BLOB
        if type(b) ~= "string" then return 0 end
        -- The blob is the database: kept here, the ns field let go.
        icons.blob = b
        ns.ICON_SEARCH_BLOB = nil
    end
    return IndexCorpus(icons)
end

local function IconID(rec)
    local blob = icons.blob
    return tonumber(ssub(blob, icons.tabs[rec] + 1, (icons.offsets[rec + 1] or (#blob + 2)) - 2))
end

function IconSearch:GetIcon(index)
    if not icons.offsets[index] then return nil end
    return ssub(icons.blob, icons.offsets[index], icons.tabs[index] - 1), IconID(index)
end

function IconSearch:GetTotal()
    return EnsureIndex()
end

-- FileDataID -> record index; the blob's IDs ascend.
local function IndexOfFileID(fdid)
    if type(fdid) ~= "number" or EnsureIndex() == 0 then return nil end
    local lo, hi = 1, icons.total
    while lo <= hi do
        local mid = mfloor((lo + hi) / 2)
        local id = IconID(mid)
        if id == fdid then return mid end
        if id < fdid then lo = mid + 1 else hi = mid - 1 end
    end
    return nil
end

-- Ability names: the shipped list is spell IDs only and the client names
-- each, in its own language and with the icon the spell wears there.
local namesStarted, namesReady = false, false
local namesListeners = {}

local function BuildSpellNames()
    local list = ns.ICON_SPELL_IDS
    local getName = C_Spell and C_Spell.GetSpellName
    local getIcon = C_Spell and C_Spell.GetSpellTexture
    if type(list) ~= "string" or not (getName and getIcon) then return end
    ns.ICON_SPELL_IDS = nil
    local lines, iconOf, spellOf, seen = {}, {}, {}, {}
    local n, id, step = 0, 0, 0
    for gap in list:gmatch("%d+") do
        id = id + tonumber(gap)
        step = step + 1
        if step % 64 == 0 then Utils.SliceCheckpoint() end
        local name = getName(id)
        local rec
        if name and name ~= "" then
            -- The spell's own icon, not one a talent or form swaps in.
            local shown, original = getIcon(id)
            rec = IndexOfFileID(original or shown)
        end
        if rec then
            name = slower(name)
            local key = name .. "\t" .. rec
            if not seen[key] then
                seen[key] = true
                n = n + 1
                lines[n] = name
                iconOf[n] = rec
                spellOf[n] = id
            end
        end
    end
    if n == 0 then return end
    lines[n + 1] = ""
    spells.blob = tconcat(lines, "\t\n")
    spells.iconOf, spells.spellOf = iconOf, spellOf
end

-- A build done inside the filter that started it tells nobody: that
-- filter already searches the names.
local function StartSpellNames()
    if namesStarted then return end
    namesStarted = true
    local starting = true
    Utils.RunSliced(BuildSpellNames, function(ok, err)
        if not ok then Utils.ErrorHandler(err) end
        namesReady = true
        if starting then return end
        for i = 1, #namesListeners do namesListeners[i]() end
    end, nil, "iconSpellNames")
    starting = false
end

-- fn runs once the ability names can be searched: results change then.
function IconSearch:OnNamesReady(fn)
    namesListeners[#namesListeners + 1] = fn
end

function IconSearch:NamesReady()
    return namesReady
end

-- spell:/item:/achievement: -> the FileDataID that thing renders with.
-- The kinds are WoW's own hyperlink types (|Hspell:133|...), which is what
-- the grid's shift-click link capture inserts. In-game APIs; every step
-- nil-guarded so the test harness (and any API churn) degrades to "no
-- match", never an error.
local function ResolveRefID(kind, refID)
    if kind == "spell" then
        local GetSpellInfo = C_Spell and C_Spell.GetSpellInfo
        local info = GetSpellInfo and GetSpellInfo(refID)
        return info and info.iconID
    end
    if kind == "item" then
        local GetItemInfoInstant = C_Item and C_Item.GetItemInfoInstant
        if not GetItemInfoInstant then return nil end
        local _, _, _, _, iconID = GetItemInfoInstant(refID)
        return iconID
    end
    if kind == "achievement" then
        local GetAchievementInfo = _G.GetAchievementInfo
        if not GetAchievementInfo then return nil end
        local ok, _, _, _, _, _, _, _, _, _, iconID = pcall(GetAchievementInfo, refID)
        return ok and iconID or nil
    end
    return nil
end

-- A word carrying * or ? becomes an anchored whole-name wildcard. Blob
-- form: the name sits between "\n" (or blob start) and "\t", so the
-- anchors become those delimiters and the wildcards exclude them.
local function GlobToBlobPattern(word)
    local body = word:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")
    body = body:gsub("%*", "[^\t\n]*"):gsub("%?", "[^\t\n]")
    return "\n" .. body .. "\t", "^" .. body .. "\t"
end

-- Indices already emitted by the numeric prefix pass this Filter call, so
-- the name loop doesn't list them twice.
local numericSeen = {}

-- Fill `out` with every icon whose FileDataID STARTS with the typed
-- digits ("12" -> 125..., 129...; each further digit narrows). An exact
-- full-ID match lists first. Deliberately prefix-only: digits have an
-- order, unlike fuzzy text. Works straight off the blob: an ID starts
-- right after its record's tab, so "\t<digits>" enumerates prefixes.
local function CollectIDPrefix(digits, out, seen)
    if EnsureIndex() == 0 then return 0 end
    local blob, offsets, total = icons.blob, icons.offsets, icons.total
    local m = 0
    local exactIdx = IndexOfFileID(tonumber(digits))
    if exactIdx then
        m = 1
        out[1] = exactIdx
        if seen then seen[exactIdx] = true end
    end
    local needle = "\t" .. digits
    local rec = 1
    local p = sfind(blob, needle, 1, true)
    while p do
        while rec < total and offsets[rec + 1] <= p do rec = rec + 1 end
        if rec ~= exactIdx then
            m = m + 1
            out[m] = rec
            if seen then seen[rec] = true end
        end
        p = sfind(blob, needle, p + 1, true)
    end
    return m
end

-- Parsed query scratch, module-level (this runs per keystroke). Three
-- levels flattened into parallel arrays:
--   branches (comma) OR'd -> terms (space) AND'd -> alternates (/) OR'd
-- branch b owns terms branchEnd[b-1]+1 .. branchEnd[b]; term t owns
-- alternates termEnd[t-1]+1 .. termEnd[t].
local altText, altPlural, altPat1 = {}, {}, {}
local altIsPat = {}
local termEnd, termNeg = {}, {}
local branchEnd = {}

local function AddTerm(termN, altN, word)
    local neg = false
    while ssub(word, 1, 1) == "-" do
        neg = not neg
        word = ssub(word, 2)
    end
    local before = altN
    for alt in word:gmatch("[^/]+") do
        altN = altN + 1
        if sfind(alt, "[%*%?]") then
            local pat, pat1 = GlobToBlobPattern(alt)
            altText[altN] = pat
            altPat1[altN] = pat1
            altIsPat[altN] = true
            altPlural[altN] = nil
        else
            altText[altN] = alt
            altPat1[altN] = nil
            altIsPat[altN] = false
            -- "swords" -> "sword"; positive plain alternates only, and only
            -- when the singular is still a word.
            if not neg and #alt > 3
               and ssub(alt, -1) == "s" and ssub(alt, -2) ~= "ss" then
                altPlural[altN] = ssub(alt, 1, -2)
            else
                altPlural[altN] = nil
            end
        end
    end
    if altN == before then return termN, altN end
    termN = termN + 1
    termEnd[termN] = altN
    termNeg[termN] = neg
    return termN, altN
end

local function PrepareQuery(query)
    wipe(termEnd)
    wipe(branchEnd)
    local termN, altN, branchN = 0, 0, 0
    for branch in query:gmatch("[^,]+") do
        local before = termN
        for word in branch:gmatch("[^%s]+") do
            termN, altN = AddTerm(termN, altN, word)
        end
        if termN > before then
            branchN = branchN + 1
            branchEnd[branchN] = termN
        end
    end
    return branchN
end

-- Generation stamps, so nothing wipes per keystroke. In a corpus,
-- mark[rec] == markBase + t: rec passed terms 1..t of the branch under
-- evaluation; hit[rec] == hitGen dedupes within one term; matched[rec] ==
-- matchGen marks a completed branch. A branch's marks start past the last
-- branch's, so a stale mark never reads as progress.
local markBase, markTop, hitGen, matchGen = 0, 0, 0, 0
-- Icon records whose file name hit a negated word, by the branch's base.
local negated = {}

-- Fresh tables drop the capacity wipe() keeps; the blob rebuilds the index.
local function Shed(c)
    c.offsets, c.tabs, c.total = {}, {}, 0
    c.mark, c.hit, c.matched = {}, {}, {}
end

-- Close-boundary release: the indexes and match scratch outweigh the
-- blobs, which stay.
function IconSearch:ReleaseMemory()
    Shed(icons)
    Shed(spells)
    negated = {}
    markBase, markTop, hitGen, matchGen = 0, 0, 0, 0
end

-- Scan the blob for one PLAIN alternate. Ascending occurrences drive a
-- moving record pointer; a settled record skips ahead to the next, so
-- the loop is bounded by the record count, not the occurrence count.
-- An occurrence inside the id digits fails the tab guard and is skipped.
-- presenceOnly (negated terms): just stamp hits, no mark advance.
local function StampWord(c, word, t, firstTerm, presenceOnly)
    local blob, offsets, tabs, total = c.blob, c.offsets, c.tabs, c.total
    local mark, hit = c.mark, c.hit
    local blobLen, wl = #blob, #word
    local rec = 1
    local p = sfind(blob, word, 1, true)
    while p do
        while rec < total and offsets[rec + 1] <= p do rec = rec + 1 end
        local nextInit = p + 1
        if p + wl - 1 < tabs[rec] then
            if presenceOnly then
                hit[rec] = hitGen
            elseif hit[rec] ~= hitGen
               and (firstTerm or mark[rec] == markBase + (t - 1)) then
                hit[rec] = hitGen
                mark[rec] = markBase + t
            end
            nextInit = (offsets[rec + 1] or (blobLen + 1))
        end
        if nextInit > blobLen then break end
        p = sfind(blob, word, nextInit, true)
    end
end

-- Same for a wildcard alternate: anchored blob patterns ("\n<pat>\t",
-- plus a "^" form for record 1).
local function StampPattern(c, pat, pat1, t, firstTerm, presenceOnly)
    local blob, offsets, total = c.blob, c.offsets, c.total
    local mark, hit = c.mark, c.hit
    local blobLen = #blob
    if blob:find(pat1) then
        if presenceOnly then
            hit[1] = hitGen
        elseif hit[1] ~= hitGen and (firstTerm or mark[1] == markBase + (t - 1)) then
            hit[1] = hitGen
            mark[1] = markBase + t
        end
    end
    local rec = 1
    local p = blob:find(pat)
    while p do
        -- p sits on the "\n" BEFORE the record; the record starts at p+1.
        while rec < total and offsets[rec + 1] <= p + 1 do rec = rec + 1 end
        if presenceOnly then
            hit[rec] = hitGen
        elseif hit[rec] ~= hitGen and (firstTerm or mark[rec] == markBase + (t - 1)) then
            hit[rec] = hitGen
            mark[rec] = markBase + t
        end
        local nextInit = (offsets[rec + 1] or (blobLen + 2)) - 1
        if nextInit <= p then nextInit = p + 1 end
        p = blob:find(pat, nextInit)
    end
end

-- One branch's terms over a corpus: a record passing all of them ends
-- with mark == markBase + nTerms.
local function MarkBranch(c, termStart, nTerms, altStart)
    local count, mark, hit = c.total, c.mark, c.hit
    local neg = c == icons and negated
    for t = 1, nTerms do
        local termIdx = termStart + t - 1
        hitGen = hitGen + 1
        if termNeg[termIdx] then
            -- Stamp raw hits, then advance every UN-hit record.
            for a = altStart, termEnd[termIdx] do
                if altIsPat[a] then
                    StampPattern(c, altText[a], altPat1[a], t, false, true)
                else
                    StampWord(c, altText[a], t, false, true)
                end
            end
            for rec = 1, count do
                if hit[rec] == hitGen then
                    if neg then neg[rec] = markBase end
                elseif t == 1 or mark[rec] == markBase + (t - 1) then
                    mark[rec] = markBase + t
                end
            end
        else
            for a = altStart, termEnd[termIdx] do
                if altIsPat[a] then
                    StampPattern(c, altText[a], altPat1[a], t, t == 1, false)
                else
                    StampWord(c, altText[a], t, t == 1, false)
                    if altPlural[a] then
                        StampWord(c, altPlural[a], t, t == 1, false)
                    end
                end
            end
        end
        altStart = termEnd[termIdx] + 1
    end
end

-- Fills `out` (wiped) with master indices of icons matching the query.
-- Empty query = every icon. Returns the match count.
function IconSearch:Filter(query, out)
    wipe(out)
    local count = EnsureIndex()
    if count == 0 then return 0 end
    StartSpellNames()
    query = slower(query or ""):gsub("^%s+", ""):gsub("%s+$", "")

    -- spell:/item:/achievement: reference -> exactly that icon.
    local kind, refID = query:match("^(%a+):(%d+)$")
    if kind then
        local fdid = ResolveRefID(kind, tonumber(refID))
        local idx = fdid and IndexOfFileID(fdid)
        if idx then
            out[1] = idx
            return 1
        end
        return 0
    end

    -- #ID: FileDataIDs only, narrowing by prefix as digits are typed.
    local hashID = query:match("^#(%d+)$")
    if hashID then
        return CollectIDPrefix(hashID, out, nil)
    end

    local branchN = PrepareQuery(query)
    local m = 0

    -- A whole-number query filters FileDataIDs by prefix (exact match
    -- first), then any name-substring matches (icon names carry digit
    -- runs: _04, 2h, ...) follow.
    wipe(numericSeen)
    if query:match("^%d+$") then
        m = CollectIDPrefix(query, out, numericSeen)
    end

    if branchN == 0 then
        if m > 0 then return m end
        for i = 1, count do out[i] = i end
        return count
    end

    -- A branch runs over the file names, then the spell names: a spell
    -- passing it brings its icon, unless the icon's own name is negated.
    matchGen = matchGen + 1
    local spellCount = namesReady and IndexCorpus(spells) or 0
    local iconMark, iconMatched = icons.mark, icons.matched
    local termStart = 1
    for b = 1, branchN do
        local nTerms = branchEnd[b] - termStart + 1
        markBase = markTop
        markTop = markBase + nTerms
        local altStart = termStart > 1 and (termEnd[termStart - 1] + 1) or 1
        MarkBranch(icons, termStart, nTerms, altStart)
        for rec = 1, count do
            if iconMark[rec] == markTop then
                iconMatched[rec] = matchGen
            end
        end
        if spellCount > 0 then
            MarkBranch(spells, termStart, nTerms, altStart)
            local spellMark, spellMatched, iconOf = spells.mark, spells.matched, spells.iconOf
            for line = 1, spellCount do
                if spellMark[line] == markTop and negated[iconOf[line]] ~= markBase then
                    spellMatched[line] = matchGen
                    iconMatched[iconOf[line]] = matchGen
                end
            end
        end
        termStart = branchEnd[b] + 1
    end

    for rec = 1, count do
        if iconMatched[rec] == matchGen and not numericSeen[rec] then
            m = m + 1
            out[m] = rec
        end
    end
    return m
end

-- Names of the spells wearing icon `index`, up to `max`, the last
-- filter's matches first; a longer list ends in "...".
local nameScratch = {}
function IconSearch:GetSpellNames(index, max)
    local iconOf, spellOf = spells.iconOf, spells.spellOf
    local getName = C_Spell and C_Spell.GetSpellName
    if not (iconOf and getName) then return nil end
    wipe(nameScratch)
    local matched = spells.matched
    local n = 0
    for pass = 1, 2 do
        for line = 1, #iconOf do
            if iconOf[line] == index and (matched[line] == matchGen) == (pass == 1) then
                n = n + 1
                if n > max then
                    nameScratch[n] = "..."
                    return tconcat(nameScratch, ", ")
                end
                nameScratch[n] = getName(spellOf[line]) or ""
            end
        end
    end
    return n > 0 and tconcat(nameScratch, ", ") or nil
end

-- Debug peek: file-locals invisible to ns walks, exposed for external
-- diagnostics. Shared references; do not mutate.
function IconSearch:_DebugPeek()
    return { blob = icons.blob, offsets = icons.offsets, tabs = icons.tabs,
        spellBlob = spells.blob, spellOffsets = spells.offsets, iconOf = spells.iconOf }
end

return IconSearch
