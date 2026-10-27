local _, ns = ...

local Utils = {}
ns.Utils = Utils
local L = ns.L

local pairs, ipairs, type, select, unpack, next = pairs, ipairs, type, select, unpack, next
local tinsert, tsort, tconcat, tremove = table.insert, table.sort, table.concat, table.remove
local sfind, slower, ssub, sformat, smatch = string.find, string.lower, string.sub, string.format, string.match
local InCombatLockdown = InCombatLockdown
local mmin, mmax, mabs, mpi, mceil, mfloor = math.min, math.max, math.abs, math.pi, math.ceil, math.floor
local pcall, xpcall, tostring, tonumber = pcall, xpcall, tostring, tonumber
local debugstack = debugstack
local CreateFrame = CreateFrame
local CreateColor = CreateColor

-- Every caught error reaches the client's error handler (BugGrabber, the
-- error frame); a caught error that only came back to its caller was
-- lost wherever the result went unread (timers, OnUpdates, sliced runs).
local function ErrorHandler(err)
    local report = geterrorhandler and geterrorhandler()
    if report then report(err) end
    return tostring(err) .. "\n" .. debugstack(2)
end

-- Ordered schema steps keyed by the version each upgrades to. Each runs
-- under xpcall and stamps its version, so an error stops there for a retry.
function Utils.Migrate(db, field, steps, target)
    for version = (tonumber(db[field]) or 0) + 1, target do
        local step = steps[version]
        if step then
            if not xpcall(step, ErrorHandler, db) then return false end
        end
        db[field] = version
    end
    return true
end

-- Theme-change broadcast. A window registers once; every registered callback
-- fires after the active palette changes, so an open window restyles live
-- instead of only picking up the theme the next time it opens.
local themeCallbacks = {}
function ns.RegisterThemeCallback(fn)
    if type(fn) == "function" then themeCallbacks[#themeCallbacks + 1] = fn end
end
function ns.FireThemeCallbacks()
    for i = 1, #themeCallbacks do
        pcall(themeCallbacks[i])
    end
end

-- Bar controls the user configured hidden reveal on hover, like the search
-- bar's own hover-show mode: the button keeps its footprint but sits at
-- alpha 0 until the cursor crosses it, it holds keyboard focus, or its menu
-- is open. One owner for the alpha decision; callers re-run btn.RefreshReveal
-- when any input changes (setting toggled, menu opened or closed, focus moved).
function Utils.InstallBarControlReveal(btn, isConfiguredShown, isEngaged)
    local function Refresh()
        local reveal = isConfiguredShown() or btn:IsMouseOver() or btn.keyboardFocused
            or (isEngaged and isEngaged())
        btn:SetAlpha(reveal and 1 or 0)
    end
    btn.RefreshReveal = Refresh
    btn:HookScript("OnEnter", Refresh)
    btn:HookScript("OnLeave", Refresh)
    Refresh()
end

Utils.pairs   = pairs
Utils.ipairs  = ipairs
Utils.type    = type
Utils.select  = select
Utils.unpack  = unpack
Utils.next    = next

Utils.tinsert  = tinsert
Utils.tsort    = tsort
Utils.tconcat  = tconcat
Utils.tremove  = tremove

Utils.sfind    = sfind
Utils.slower   = slower
Utils.ssub     = ssub
Utils.sformat  = sformat
Utils.smatch   = smatch

Utils.mmin     = mmin
Utils.mmax     = mmax
Utils.mabs     = mabs
Utils.mpi      = mpi
Utils.mceil    = mceil
Utils.mfloor   = mfloor

Utils.pcall    = pcall
Utils.xpcall   = xpcall
Utils.tostring = tostring
Utils.tonumber = tonumber
Utils.ErrorHandler = ErrorHandler

-- Combat vetoes are not queued: callers owning combat-sensitive state must
-- arrange their own regen replay. Did-not-run paths return false plus a
-- reason ("combat", "no-object", "no-method").
-- A setting stored only when off: false off, nil (the default) on. An
-- and/or chain cannot say it: `x and false or nil` is always nil and
-- `x and nil or false` always false (tests/test_and_or_constant.lua).
function Utils.OffOrNil(on)
    if on then return nil end
    return false
end

function Utils.SafeCallMethod(obj, method, ...)
    if InCombatLockdown() then return false, "combat" end
    if not obj then return false, "no-object" end
    local fn = obj[method]
    if not fn then return false, "no-method" end
    local ok, result = xpcall(fn, ErrorHandler, obj, ...)
    if not ok then
        Utils.DebugPrint("SafeCallMethod failed: " .. tostring(result))
    end
    return ok, result
end
function Utils.FindFactionByPredicate(predicate)
    local Caps = ns.Caps
    for i = 1, Caps.NumFactions() do
        local factionData = Caps.FactionAt(i)
        if factionData and predicate(factionData) then
            return i, factionData
        end
    end
end

function Utils.LoadBlizzardAddOn(name)
    if C_AddOns and C_AddOns.LoadAddOn then
        pcall(C_AddOns.LoadAddOn, name)
    elseif LoadAddOn then
        pcall(LoadAddOn, name)
    end
end

function Utils.DeepCopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do copy[k] = Utils.DeepCopy(v) end
    return copy
end

-- Row caches persisted as tables are the single largest thing we hold at
-- login: a 5-field record rounds up to 8 hash nodes (320 B) plus a 56 B
-- header, so 5000 rows cost ~2 MB of live Lua tables that the client parses
-- before our code runs -- even for a category the player disabled and will
-- never search. The same rows as one delimited string cost ~35 B each and are
-- decoded only if something actually asks for them.
--
-- Values are self-describing (a 1-byte type tag), so decode restores the exact
-- original type. Declaring types per field would mean guessing whether e.g.
-- settingCategoryID is a number or a string, and a wrong guess corrupts the
-- cache silently.
--
-- Spec is an array of field descriptors, in order:
--   { key }                    scalar (number, string, or boolean)
--   { key, "list" }            array of scalars
--   { key, "map" }             map of scalar key -> scalar value
--   { key, "records", subSpec} array of records; subSpec is an array of keys
-- A nil field round-trips as nil; an empty list/map round-trips as nil, so
-- callers that need a table should keep their existing `or {}`.
local SEP_ROW = "\31"
local SEP_FIELD = "\30"
local SEP_ITEM = "\29"
local SEP_SUB = "\28"

local PACK_ESCAPE = {
    ["\\"] = "\\\\",
    ["\28"] = "\\a", ["\29"] = "\\b", ["\30"] = "\\c", ["\31"] = "\\d",
}
local PACK_UNESCAPE = {
    ["\\"] = "\\",
    a = "\28", b = "\29", c = "\30", d = "\31",
}

local function EncodeScalar(value)
    local valueType = type(value)
    if value == nil then return "" end
    if valueType == "number" then return "n" .. tostring(value) end
    if valueType == "boolean" then return value and "b1" or "b0" end
    if valueType ~= "string" then
        -- A table or function would pack as its address, different every
        -- session (the housing ids did: a rebuild each time). Dropped, and
        -- reported once a kind so the caller is found.
        local dropped = Utils.packDropped
        if not dropped[valueType] then
            dropped[valueType] = true
            ErrorHandler("PackRows: a " .. valueType .. " in a plain field packs as nothing")
        end
        return ""
    end
    return "s" .. value:gsub("[\\\28\29\30\31]", PACK_ESCAPE)
end
Utils.packDropped = {}

local function DecodeScalar(chunk)
    if chunk == "" then return nil end
    local tag = ssub(chunk, 1, 1)
    local body = ssub(chunk, 2)
    if tag == "n" then return tonumber(body) end
    if tag == "b" then return body == "1" end
    return (body:gsub("\\(.)", PACK_UNESCAPE))
end

-- Splits on sep, preserving empty fields (a bare "[^sep]*" gmatch emits
-- spurious empty matches at the separators and shifts every later field).
local function SplitPacked(str, sep)
    local out, n = {}, 0
    if str == "" then return out end
    for chunk in (str .. sep):gmatch("([^" .. sep .. "]*)" .. sep) do
        n = n + 1
        out[n] = chunk
    end
    return out
end

local function EncodeField(value, kind, subSpec)
    if kind == nil then return EncodeScalar(value) end
    if type(value) ~= "table" then return "" end
    local parts, n = {}, 0
    if kind == "list" then
        for i = 1, #value do parts[i] = EncodeScalar(value[i]) end
        n = #value
    elseif kind == "map" then
        for key, item in pairs(value) do
            n = n + 1
            parts[n] = EncodeScalar(key) .. SEP_SUB .. EncodeScalar(item)
        end
    elseif kind == "records" then
        for i = 1, #value do
            local record, sub = value[i], {}
            for f = 1, #subSpec do sub[f] = EncodeScalar(record[subSpec[f]]) end
            parts[i] = tconcat(sub, SEP_SUB, 1, #subSpec)
        end
        n = #value
    end
    return tconcat(parts, SEP_ITEM, 1, n)
end

local function DecodeField(chunk, kind, subSpec)
    if kind == nil then return DecodeScalar(chunk) end
    if chunk == "" then return nil end
    local items = SplitPacked(chunk, SEP_ITEM)
    local out = {}
    if kind == "list" then
        for i = 1, #items do out[i] = DecodeScalar(items[i]) end
    elseif kind == "map" then
        for i = 1, #items do
            local pair = SplitPacked(items[i], SEP_SUB)
            local key = DecodeScalar(pair[1] or "")
            if key ~= nil then out[key] = DecodeScalar(pair[2] or "") end
        end
    elseif kind == "records" then
        for i = 1, #items do
            local fields = SplitPacked(items[i], SEP_SUB)
            local record = {}
            for f = 1, #subSpec do record[subSpec[f]] = DecodeScalar(fields[f] or "") end
            out[i] = record
        end
    end
    return out
end

-- Emits every field into one flat buffer and concatenates once, rather than
-- building a throwaway string per row: on a 5000-row cache that is 5000 fewer
-- allocations, and this garbage lands on the shared heap every addon pays to
-- collect. sliced: the caller's sliced run has no pcall around this call,
-- so the row loop may yield (the corpus builders take the same flag).
function Utils.PackRows(rows, spec, sliced)
    if type(rows) ~= "table" or type(spec) ~= "table" then return "" end
    local specLen = #spec
    local parts, n = {}, 0
    for i = 1, #rows do
        if sliced and i % 64 == 0 then Utils.SliceCheckpoint() end
        local row = rows[i]
        if type(row) == "table" then
            if n > 0 then
                n = n + 1
                parts[n] = SEP_ROW
            end
            for f = 1, specLen do
                if f > 1 then
                    n = n + 1
                    parts[n] = SEP_FIELD
                end
                local field = spec[f]
                n = n + 1
                parts[n] = EncodeField(row[field[1]], field[2], field[3])
            end
        end
    end
    return tconcat(parts, "", 1, n)
end

-- Walks the blob by offset, slicing only the field values. The obvious
-- implementation (split into rows, split each row into fields) copies every row
-- string and every field string and allocates a scratch array per row -- on the
-- ~10k rows we hydrate at login that is megabytes of garbage for data we
-- already have in hand.
function Utils.UnpackRows(blob, spec)
    local rows = {}
    if type(blob) ~= "string" or blob == "" or type(spec) ~= "table" then return rows end
    local specLen = #spec
    local blobLen = #blob
    local pos, rowCount = 1, 0

    while pos <= blobLen + 1 do
        local rowSep = sfind(blob, SEP_ROW, pos, true)
        local rowEnd = (rowSep or (blobLen + 1)) - 1
        local row = {}
        local fieldPos = pos

        for f = 1, specLen do
            if fieldPos > rowEnd + 1 then break end
            local fieldSep = sfind(blob, SEP_FIELD, fieldPos, true)
            local fieldEnd
            if fieldSep and fieldSep <= rowEnd then
                fieldEnd = fieldSep - 1
            else
                fieldEnd = rowEnd
                fieldSep = nil
            end
            local field = spec[f]
            row[field[1]] = DecodeField(ssub(blob, fieldPos, fieldEnd), field[2], field[3])
            fieldPos = fieldSep and (fieldSep + 1) or (rowEnd + 2)
        end

        rowCount = rowCount + 1
        rows[rowCount] = row
        if not rowSep then break end
        pos = rowSep + 1
    end
    return rows
end

-- The mask accumulator, PackedCorpus, corpus registry, sliced-run, and
-- GC-sweep sections live in one do-block so their locals scope out of the
-- main chunk (Lua's 200-local cap; the compile gate caught the overflow).
do
local sbyte = string.byte
local bor, lshift = bit.bor, bit.lshift
local rawget, rawset, setmetatable = rawget, rawset, setmetatable
local wipe = wipe
local collectgarbage = collectgarbage

-- Scoring-gate mask accumulator, shared with the scorer's per-entry fill
-- (Database/Search.lua): cm gains a bit per a-z letter present in s, im per
-- letter that starts an alphabetic run. Folds A-Z so it can also walk
-- original-case names decoded from packed blobs.
function Utils.AccumulateGateMasks(s, cm, im)
    local prevAlpha = false
    for i = 1, #s do
        local b = sbyte(s, i)
        if b >= 65 and b <= 90 then b = b + 32 end
        if b >= 97 and b <= 122 then
            local bitv = lshift(1, b - 97)
            cm = bor(cm, bitv)
            if not prevAlpha then im = bor(im, bitv) end
            prevAlpha = true
        else
            prevAlpha = false
        end
    end
    return cm, im
end

-- PackedCorpus: the packed blob stays the store instead of being unpacked
-- into thousands of row tables at load. Each included row is represented by
-- a bare stub table ({ _ri = rowIndex }, ~100 B) whose metatable decodes
-- fields from the blob on first read and memoizes them onto the stub; shared
-- per-category fields come from the proto without hydrating. Scoring-gate
-- masks are precomputed per row into corpus arrays and served through
-- __index, so the gate and its background fill never touch the blob. The
-- search index recognizes corpus stubs by the metatable's __pcCorpus tag and
-- indexes from a transient name decode (see Database/SearchIndex.lua).
-- Shed() strips memoized fields back off the stubs (spec-known keys only,
-- foreign runtime writes survive) while stub identity stays stable for
-- serials, aliases, and pins.

local function CorpusRowEnd(corpus, ri)
    local nextOff = corpus.offsets[ri + 1]
    return nextOff and (nextOff - 2) or #corpus.packed
end

local function CorpusFieldChunk(corpus, ri, fieldIdx)
    local packed = corpus.packed
    local pos = corpus.offsets[ri]
    if not pos then return nil end
    local rowEnd = CorpusRowEnd(corpus, ri)
    for _ = 2, fieldIdx do
        local sep = sfind(packed, SEP_FIELD, pos, true)
        if not sep or sep > rowEnd then return nil end
        pos = sep + 1
    end
    local sep = sfind(packed, SEP_FIELD, pos, true)
    local fieldEnd = (sep and sep <= rowEnd) and (sep - 1) or rowEnd
    if fieldEnd < pos then return "" end
    return ssub(packed, pos, fieldEnd)
end

-- wanted (optional): set of field names to decode; every other field is
-- walked past without slicing or decoding. Include passes that read a few
-- fields of heavy rows (loot: 4 of 16, three of them lists) skip most of
-- the allocation this way.
local function CorpusDecodeRow(corpus, ri, into, wanted)
    local packed, spec = corpus.packed, corpus.spec
    local fieldPos = corpus.offsets[ri]
    if not fieldPos then return into end
    local rowEnd = CorpusRowEnd(corpus, ri)
    for f = 1, #spec do
        if fieldPos > rowEnd + 1 then break end
        local fieldSep = sfind(packed, SEP_FIELD, fieldPos, true)
        local fieldEnd
        if fieldSep and fieldSep <= rowEnd then
            fieldEnd = fieldSep - 1
        else
            fieldEnd = rowEnd
            fieldSep = nil
        end
        local field = spec[f]
        if not wanted or wanted[field[1]] then
            local value = DecodeField(ssub(packed, fieldPos, fieldEnd), field[2], field[3])
            if value ~= nil then into[field[1]] = value end
        end
        fieldPos = fieldSep and (fieldSep + 1) or (rowEnd + 2)
    end
    return into
end

-- Index-side casing must match the scorer's contract: SearchText.Normalize
-- (string.lower skips bytes >= 0x80, so localized names would half-lowercase
-- and never match the normalized query). Resolved at call time: SearchText
-- loads before any corpus is built, but not necessarily before this file.
local function NormalizeLower(s)
    local st = ns.SearchText
    if st and st.Normalize then return st.Normalize(s) end
    return slower(s)
end

local function CorpusHydrateName(corpus, stub)
    local chunk = CorpusFieldChunk(corpus, rawget(stub, "_ri"), corpus.nameIdx)
    local decodedName = chunk and DecodeScalar(chunk)
    if type(decodedName) ~= "string" then return end
    rawset(stub, "name", decodedName)
    rawset(stub, "nameLower", NormalizeLower(decodedName))
    corpus.shedSet[stub] = true
end

-- Per-field hydration: decode ONLY the requested field and memoize it.
-- Full-row hydration on any spec read meant a broad query (whose letters
-- survive the gate almost everywhere) decoded every candidate's whole
-- row -- for settings stubs that is the entire step-record payload; the
-- warmledger showed the cost simply moved from the providers bucket to
-- scoring. Scoring now touches two strings per candidate; heavy fields
-- decode only when a row actually renders or acts.
local function CorpusHydrateField(corpus, stub, fieldIdx)
    local chunk = CorpusFieldChunk(corpus, rawget(stub, "_ri"), fieldIdx)
    if chunk == nil then return nil end
    local field = corpus.spec[fieldIdx]
    local value = DecodeField(chunk, field[2], field[3])
    if value ~= nil then
        rawset(stub, field[1], value)
        corpus.shedSet[stub] = true
    end
    return value
end

local Corpus = {}
Corpus.__index = Corpus

function Corpus:StubAt(ri)
    local stub = self.stubs[ri]
    if not stub then
        stub = setmetatable({ _ri = ri }, self.stubMT)
        self.stubs[ri] = stub
    end
    return stub
end

-- Transient decode for index build: no memoization, the string is the
-- caller's to drop.
function Corpus:NameLowerOf(ri)
    local chunk = CorpusFieldChunk(self, ri, self.nameIdx)
    local decodedName = chunk and DecodeScalar(chunk)
    if type(decodedName) ~= "string" then return nil end
    return NormalizeLower(decodedName)
end

-- A stub's field without memoizing it: keying every row must not leave
-- each one's name and path decoded on it.
function Corpus:Peek(stub, key)
    local value = rawget(stub, key)
    if value ~= nil then return value end
    value = self.proto[key]
    if value ~= nil then return value end
    local ri = rawget(stub, "_ri")
    local lite = self.liteValues and self.liteValues[key]
    if lite and lite[ri] ~= nil then return lite[ri] end
    local fieldIdx = self.fieldIdxOf[key]
    local chunk = fieldIdx and CorpusFieldChunk(self, ri, fieldIdx)
    if chunk then
        local field = self.spec[fieldIdx]
        value = DecodeField(chunk, field[2], field[3])
        if value ~= nil then return value end
    end
    local computeFn = self.computed and self.computed[key]
    if computeFn then return computeFn(stub) end
    return nil
end

-- Per-row keywords for the index build (corpora with opts.keywordsFor):
-- decodes the row into a reused scratch and returns keywordsFor's array,
-- which is itself a reused buffer -- valid only until the next call.
local kwScratchRow = {}
function Corpus:KeywordsOf(ri)
    local keywordsFor = self.keywordsFor
    if not keywordsFor then return nil end
    wipe(kwScratchRow)
    return keywordsFor(CorpusDecodeRow(self, ri, kwScratchRow, self.keywordFields))
end

-- Decodes every row into one reused scratch table for inclusion filters.
-- The scratch is only valid inside the callback. wanted (optional) limits
-- decoding to those field names.
function Corpus:EachRow(fn, wanted, sliced)
    local scratch = {}
    for ri = 1, self.count do
        if sliced and ri % 64 == 0 then Utils.SliceCheckpoint() end
        wipe(scratch)
        fn(ri, CorpusDecodeRow(self, ri, scratch, wanted))
    end
end

function Corpus:Shed()
    -- Mutable corpora (loot: stat enrichment, link accrual persisted back
    -- to the blob) opt out; shedding would drop spec-field mutations.
    if self.noShed then return end
    local shedKeys = self.shedKeys
    for stub in pairs(self.shedSet) do
        for key in pairs(shedKeys) do
            rawset(stub, key, nil)
        end
    end
    wipe(self.shedSet)
end

local function CorpusStubIndex(corpus, stub, key)
    local protoValue = corpus.proto[key]
    if protoValue ~= nil then return protoValue end
    -- Gate masks memoize onto the stub on first serve: the scoring gate
    -- reads both for EVERY corpus stub EVERY keystroke, and the flamegraph
    -- put ~12% of all typing CPU in this dispatcher. false memoizes fine
    -- (rawget returns non-nil, so __index stops firing). shedKeys covers
    -- both, so Shed still strips them.
    if key == "_efGateMask" then
        local value
        if corpus.ungated then value = false else value = corpus.gateMasks[rawget(stub, "_ri")] end
        if value ~= nil then
            rawset(stub, key, value)
            corpus.shedSet[stub] = true
        end
        return value
    end
    if key == "_efGateInit" then
        local value
        if corpus.ungated then value = false else value = corpus.gateInits[rawget(stub, "_ri")] end
        if value ~= nil then
            rawset(stub, key, value)
            corpus.shedSet[stub] = true
        end
        return value
    end
    local lite = corpus.liteValues
    if lite then
        local arr = lite[key]
        if arr then
            local value = arr[rawget(stub, "_ri")]
            if value ~= nil then return value end
        end
    end
    if key == "nameLower" or key == "name" then
        CorpusHydrateName(corpus, stub)
        return rawget(stub, key)
    end
    local fieldIdx = corpus.fieldIdxOf[key]
    if fieldIdx then
        local value = CorpusHydrateField(corpus, stub, fieldIdx)
        if value ~= nil then return value end
    end
    local computed = corpus.computed
    local computeFn = computed and computed[key]
    if computeFn then
        local value = computeFn(stub)
        if value ~= nil then
            rawset(stub, key, value)
            corpus.shedSet[stub] = true
        end
        return value
    end
    return nil
end

-- opts.computed: map of field -> fn(stub) for values derived outside the
-- blob (e.g. mountTypeID); computed lazily on read, shed with the rest.
function Utils.NewPackedCorpus(packed, spec, proto, opts)
    local corpus = setmetatable({
        packed = type(packed) == "string" and packed or "",
        spec = spec, proto = proto or {},
        stubs = {}, shedSet = {},
    }, Corpus)

    local nameIdx = 1
    for i = 1, #spec do
        if spec[i][1] == "name" then
            nameIdx = i
            break
        end
    end
    corpus.nameIdx = nameIdx

    local sliced = opts and opts.sliced
    local offsets, rowN = {}, 0
    local blob = corpus.packed
    if blob ~= "" then
        local blobLen = #blob
        local pos = 1
        while pos <= blobLen do
            rowN = rowN + 1
            offsets[rowN] = pos
            local rowSep = sfind(blob, SEP_ROW, pos, true)
            pos = (rowSep or blobLen) + 1
            if sliced and rowN % 256 == 0 then Utils.SliceCheckpoint() end
        end
    end
    corpus.offsets = offsets
    corpus.count = rowN

    -- Proto keywords contribute a constant mask; each row adds its name's
    -- letters. The decode is escape-aware (DecodeScalar), so no escape
    -- bytes leak into the masks. Ungated corpora (loot: the scoring gate
    -- must never skip them) serve false instead and skip the build pass.
    corpus.ungated = opts and opts.ungated or nil
    corpus.noShed = opts and opts.noShed or nil
    -- opts.keywordsFor(scratchRow) -> reused array of lowercase strings:
    -- corpora whose entries carry PER-ROW keywords (bosses: instance name
    -- and abbreviations) must contribute them to the gate masks and the
    -- index, or the gate wrongly skips keyword matches.
    corpus.keywordsFor = opts and opts.keywordsFor or nil
    -- opts.keywordFields: the field-name set keywordsFor actually reads
    -- (plus name for the mask pass); limits the per-row decode.
    corpus.keywordFields = opts and opts.keywordFields or nil
    if not corpus.ungated then
        local protoCm, protoIm = 0, 0
        local kws = corpus.proto.keywordsLower or corpus.proto.keywords
        if kws then
            for k = 1, #kws do
                if type(kws[k]) == "string" then
                    protoCm, protoIm = Utils.AccumulateGateMasks(kws[k], protoCm, protoIm)
                end
            end
        end
        local gateMasks, gateInits = {}, {}
        local maskScratch = corpus.keywordsFor and {} or nil
        local maskWanted
        if maskScratch and corpus.keywordFields then
            maskWanted = { name = true }
            for k in pairs(corpus.keywordFields) do maskWanted[k] = true end
        end
        for ri = 1, rowN do
            if sliced and ri % 64 == 0 then Utils.SliceCheckpoint() end
            local cm, im = protoCm, protoIm
            if maskScratch then
                wipe(maskScratch)
                CorpusDecodeRow(corpus, ri, maskScratch, maskWanted)
                if type(maskScratch.name) == "string" then
                    cm, im = Utils.AccumulateGateMasks(maskScratch.name, cm, im)
                end
                local rowKws = corpus.keywordsFor(maskScratch)
                if rowKws then
                    for k = 1, #rowKws do
                        if type(rowKws[k]) == "string" then
                            cm, im = Utils.AccumulateGateMasks(rowKws[k], cm, im)
                        end
                    end
                end
            else
                local chunk = CorpusFieldChunk(corpus, ri, nameIdx)
                local decodedName = chunk and DecodeScalar(chunk)
                if type(decodedName) == "string" then
                    cm, im = Utils.AccumulateGateMasks(decodedName, cm, im)
                end
            end
            gateMasks[ri] = cm
            gateInits[ri] = im
        end
        corpus.gateMasks = gateMasks
        corpus.gateInits = gateInits
    end

    local fieldIdxOf = {}
    local shedKeys = { nameLower = true, _efGateMask = true, _efGateInit = true }
    for i = 1, #spec do
        fieldIdxOf[spec[i][1]] = i
        shedKeys[spec[i][1]] = true
    end
    corpus.fieldIdxOf = fieldIdxOf
    -- opts.liteFields: spec fields served per row from corpus arrays WITHOUT
    -- hydrating. The scoring loop reads some fields (category) for every
    -- entry on every search; hydrating thousands of stubs for a shared
    -- interned string would defeat the laziness.
    local liteList = opts and opts.liteFields
    if liteList then
        local lite = {}
        for i = 1, #liteList do
            local fieldName = liteList[i]
            local fieldIdx
            for f = 1, #spec do
                if spec[f][1] == fieldName then
                    fieldIdx = f
                    break
                end
            end
            if fieldIdx then
                local arr = {}
                for ri = 1, rowN do
                    if sliced and ri % 64 == 0 then Utils.SliceCheckpoint() end
                    local chunk = CorpusFieldChunk(corpus, ri, fieldIdx)
                    if chunk then arr[ri] = DecodeScalar(chunk) end
                end
                lite[fieldName] = arr
            end
        end
        corpus.liteValues = lite
    end
    local computed = opts and opts.computed
    corpus.computed = computed
    if computed then
        for key in pairs(computed) do shedKeys[key] = true end
    end
    corpus.shedKeys = shedKeys

    corpus.stubMT = {
        __pcCorpus = corpus,
        __index = function(stub, key)
            return CorpusStubIndex(corpus, stub, key)
        end,
    }
    return corpus
end

local corpusRegistry = {}

function Utils.RegisterCorpus(name, corpus)
    corpusRegistry[name] = corpus
end

function Utils.GetCorpus(name)
    return corpusRegistry[name]
end

function Utils.ShedCorpora()
    for _, corpus in pairs(corpusRegistry) do
        corpus:Shed()
    end
end

-- Sliced synchronous work: fn runs inside a coroutine under a per-frame
-- time budget; Utils.SliceCheckpoint() calls sprinkled through fn's loops
-- yield when the budget is spent and the pump resumes next frame. This is
-- the generic form of the boss scanner's budget pattern: a provider walk
-- that took one 300-400ms frame becomes ~4ms slices with a ONE-LINE
-- checkpoint per loop. Checkpoints must sit OUTSIDE any pcall inside fn
-- (this Lua cannot yield across a C boundary); a checkpoint reached on
-- the main thread (direct sync calls, dev probes) is a no-op.
local sliceDeadline
local dpstop = debugprofilestop
local coroutine = coroutine
local GetTime = GetTime

-- ONE per-frame pool shared by every sliced run: individually budgeted
-- systems (search slice, provider walk, index build) each kept their own
-- budget but STACKED in the same frame during cold moments. GetTime is
-- frame-constant, so it doubles as the frame marker with no OnUpdate.
local FRAME_CAP_MS = 8
local frameSpent = 0
local frameStamp

-- Ms each sliced run spent paused, so a timer inside it counts its own work.
Utils.slicePaused = setmetatable({}, { __mode = "k" })
function Utils.SliceCheckpoint()
    if not sliceDeadline then return end
    local now = dpstop()
    if now < sliceDeadline then return end
    local co = coroutine.running()
    if not co then return end
    coroutine.yield()
    local paused = Utils.slicePaused
    paused[co] = (paused[co] or 0) + dpstop() - now
end

function Utils.SlicePausedMs()
    local co = coroutine.running()
    return co and Utils.slicePaused[co] or 0
end

-- Returns a handle whose :Cancel() stops the run at its next slice
-- boundary WITHOUT firing onDone (last-keystroke-wins search dispatch).
-- onDone is optional. Errors reach onDone(false, err) when given, else
-- the shared error handler.
local function slicedDone(onDone, ok, ...)
    if onDone then
        onDone(ok, ...)
    elseif not ok then
        Utils.ErrorHandler(...)
    end
end

-- budgetMs: ms a slice, or a function read at each slice. label: names
-- the run for a dev observer (Utils.sliceObserver, nil in play).
function Utils.RunSliced(fn, onDone, budgetMs, label)
    if not dpstop then
        -- No profiler clock (offline harness): run synchronously.
        local function relay(ok, ...) slicedDone(onDone, ok, ...) end
        relay(pcall(fn))
        return { Cancel = function() end }
    end
    budgetMs = budgetMs or 4
    local co = coroutine.create(fn)
    local handle = {}
    function handle:Cancel() handle.cancelled = true end
    local pump
    local pumpStart
    -- outer: the deadline of a sliced run this one started inside, which
    -- keeps slicing after this returns and counts this one's time itself.
    local function step(outer, ok, ...)
        if not outer then frameSpent = frameSpent + (dpstop() - pumpStart) end
        local observe = Utils.sliceObserver
        if observe then observe(label, dpstop() - pumpStart) end
        sliceDeadline = outer
        if not ok then
            slicedDone(onDone, false, ...)
            return
        end
        if coroutine.status(co) == "dead" then
            slicedDone(onDone, true, ...)
            return
        end
        Utils.SafeAfter(0, pump)
    end
    pump = function()
        if handle.cancelled then return end
        local allowance = type(budgetMs) == "function" and budgetMs() or budgetMs
        -- Background runs (slices of 2 ms or less) share 2.5 ms of a frame;
        -- a run someone waits on, the whole pool.
        local cap = allowance <= 2 and 2.5 or FRAME_CAP_MS
        local now = GetTime()
        if now ~= frameStamp then
            frameStamp = now
            frameSpent = 0
        elseif frameSpent >= cap then
            -- The frame's shared pool is spent; wait for the next one.
            Utils.SafeAfter(0, pump)
            return
        end
        local remaining = cap - frameSpent
        if remaining < allowance then allowance = remaining end
        local outer = sliceDeadline
        pumpStart = dpstop()
        sliceDeadline = pumpStart + allowance
        if outer and outer < sliceDeadline then sliceDeadline = outer end
        step(outer, coroutine.resume(co))
    end
    pump()
    return handle
end

-- Debug peek: the registry is file-local and invisible to ns walks,
-- exposed for external diagnostics. Shared reference; do not mutate.
function Utils._DebugPeekCorpora()
    return corpusRegistry
end

-- Close-boundary GC sweep, ONE owner for every search surface (main bar,
-- map search): the client's incremental GC is allocation-paced, so when a
-- surface closes and allocation stops, the session's garbage sits in every
-- memory meter for minutes. Two stages per boundary: staggered debt-sized
-- steps shortly after close (sub-ms each, never a full collect's frame
-- spike), then the surface's trim plus one full settle at the idle mark,
-- combat-guarded. A new session on the same surface cancels both stages;
-- isOpenFn re-checks at every fire.
local gcSweepSerials = {}
local GC_SWEEP_TICKS = 40

-- A collector step bounded by time, not size: a sized step (step 400)
-- that lands in the sweep frees tens of thousands of objects, a 32 ms
-- frame on the shared heap (Perfy, 2026-10-20). The smallest steps stop
-- at the budget; only the atomic pass stays whole. True when a cycle ends.
function Utils.GCStep(ms)
    local clock = debugprofilestop
    if not clock then return collectgarbage("step", 0) end
    local start = clock()
    repeat
        if collectgarbage("step", 0) then return true end
    until clock() - start >= ms
    return false
end

-- A full collect at a quiet moment, a millisecond a tick across frames:
-- one collect over a large shared heap was a 100 ms frame.
function Utils.SettleGC()
    local ticks = 600
    local function tick()
        ticks = ticks - 1
        if ticks <= 0 or InCombatLockdown() then return end
        if Utils.GCStep(1) then return end
        Utils.SafeAfter(0.02, tick)
    end
    tick()
end

function Utils.NoteSurfaceClosed(key, isOpenFn, trimFn)
    local serial = (gcSweepSerials[key] or 0) + 1
    gcSweepSerials[key] = serial
    local sweepsLeft = GC_SWEEP_TICKS
    local function sweepTick()
        if gcSweepSerials[key] ~= serial then return end
        if isOpenFn and isOpenFn() then return end
        Utils.GCStep(1)
        sweepsLeft = sweepsLeft - 1
        if sweepsLeft > 0 then
            Utils.SafeAfter(0.05, sweepTick)
        end
    end
    Utils.SafeAfter(0.5, sweepTick)
    Utils.SafeAfter(60, function()
        if gcSweepSerials[key] ~= serial then return end
        if isOpenFn and isOpenFn() then return end
        if trimFn then trimFn() end
        Utils.SettleGC()
    end)
end

end

function Utils.SecureCall(fn, ...)
    if not fn then return false end
    if securecallfunction then
        securecallfunction(fn, ...)
    else
        local ok, err = xpcall(fn, ErrorHandler, ...)
        if not ok then
            Utils.DebugPrint("SecureCall fallback failed: " .. tostring(err))
            return false
        end
    end
    return true
end

-- Rows of one kind: what every row has stays in proto, and each lazy
-- field (steps, a subtext) is built from the row on first read and kept.
-- A row holds only its own fields (a macro row 1309 to 534 bytes).
function Utils.LeanRowMT(proto, lazy)
    return {
        __index = function(row, key)
            local build = lazy[key]
            if build then
                local value = build(row)
                rawset(row, key, value)
                return value
            end
            return proto[key]
        end,
        __index_proto = proto,
    }
end

-- Our own functions are post-hooked in Lua: hooksecurefunc puts the
-- function behind a C call, and a sliced run cannot yield under it.
function Utils.PostHook(tbl, key, hook)
    local orig = tbl[key]
    local function pack(...) return { n = select("#", ...), ... } end
    tbl[key] = function(...)
        local r = pack(orig(...))
        hook(...)
        return unpack(r, 1, r.n)
    end
end

function Utils.RGB(c, alpha)
    if alpha == nil then return c[1], c[2], c[3] end
    return c[1], c[2], c[3], alpha
end

function Utils.SafeOnUpdate(frame, handler)
    if not handler then
        frame:SetScript("OnUpdate", nil)
        return
    end
    frame:SetScript("OnUpdate", function(self, elapsed)
        local ok, err = xpcall(handler, ErrorHandler, self, elapsed)
        if not ok then
            self:SetScript("OnUpdate", nil)
            Utils.DebugPrint("OnUpdate stopped: " .. tostring(err))
        end
    end)
end

function Utils.SafeAfter(delay, fn)
    C_Timer.After(delay, function()
        local ok, err = xpcall(fn, ErrorHandler)
        if not ok then
            Utils.DebugPrint("Timer error: " .. tostring(err))
        end
    end)
end

-- A classic client errors on an event it lacks (TBC: SUPER_TRACKING_CHANGED).
function Utils.RegisterEventIfValid(frame, event)
    if C_EventUtils and C_EventUtils.IsEventValid and C_EventUtils.IsEventValid(event) then
        frame:RegisterEvent(event)
        return true
    end
    return false
end

function Utils.CreateKeyRepeat(frame, initialDelay, fastDelay, accelDuration)
    initialDelay = initialDelay or 0.30
    fastDelay = fastDelay or 0.05
    accelDuration = accelDuration or 1.5
    local repeatKey, repeatAction, repeatNext, repeatHeld
    local repeatActive = false
    -- The per-frame driver is a child shown only while a key repeats.
    local driver = CreateFrame("Frame", nil, frame)
    driver:Hide()

    local function Start(key, action)
        repeatKey = key
        repeatAction = action
        repeatHeld = 0
        repeatNext = initialDelay
        repeatActive = true
        driver:Show()
        action()
    end
    local function Stop(key)
        if not key or repeatKey == key then
            repeatActive = false
            repeatKey = nil
            repeatAction = nil
            driver:Hide()
        end
    end
    local function IsKey(key) return repeatKey == key end

    driver:SetScript("OnUpdate", function(_, elapsed)
        if not repeatActive then return end
        -- Stop when the key is released. Arrow-key OnKeyUp is not reliably
        -- delivered to keyboard-enabled frames, so the OnKeyUp handlers
        -- alone let a single tap cascade. Polling the physical key state
        -- here is what Alt+J already does via its own ticker check.
        if repeatKey and not Utils.IsPhysicalKeyDown(repeatKey) then
            Stop(repeatKey)
            return
        end
        repeatHeld = repeatHeld + elapsed
        repeatNext = repeatNext - elapsed
        if repeatNext <= 0 then
            repeatAction()
            local t = repeatHeld / accelDuration
            if t > 1 then t = 1 end
            repeatNext = initialDelay + (fastDelay - initialDelay) * t
        end
    end)

    return { Start = Start, Stop = Stop, IsKey = IsKey }
end

function Utils.NormalizeKey(key)
    return type(key) == "string" and key:upper() or key
end

-- IsKeyDown uses the same names OnKeyDown reports ("UP"/"DOWN"/etc.).
-- An earlier "...ARROW" alias table was wrong: IsKeyDown("DOWNARROW")
-- returns nil, so the guard always read released and arrow repeats never
-- stopped. Verified in-game: IsKeyDown("DOWN") is true while held.
function Utils.IsPhysicalKeyDown(key)
    if not IsKeyDown or not key then return false end
    return IsKeyDown(key) and true or false
end

local MODIFIER_KEYS = {
    LSHIFT = true, RSHIFT = true,
    LCTRL = true, RCTRL = true,
    LALT = true, RALT = true,
}
function Utils.IsModifierKey(key)
    return MODIFIER_KEYS[key] == true
end

local RESERVED_BARE_KEYS = {
    SPACE = true, ENTER = true, RETURN = true,
    W = true, A = true, S = true, D = true,
}
function Utils.IsReservedBareKey(key)
    return RESERVED_BARE_KEYS[key] == true
end

function Utils.ModifierCombo(key)
    local combo = ""
    if IsAltKeyDown and IsAltKeyDown() then combo = combo .. "ALT-" end
    if IsControlKeyDown and IsControlKeyDown() then combo = combo .. "CTRL-" end
    if IsShiftKeyDown and IsShiftKeyDown() then combo = combo .. "SHIFT-" end
    return combo .. (key or "")
end

-- Shared key validation for keybind-capture OnKeyDown handlers. Returns nil
-- (ignore the keypress), "stop" (ESCAPE ends the capture), or the modifier
-- combo string to bind.
function Utils.CaptureKeybindCombo(key)
    if Utils.IsModifierKey(key) then return nil end
    if key == "ESCAPE" then return "stop" end
    -- Bare SPACE / ENTER / WASD silently overwriting jump, accept, or
    -- movement on a stray capture-keypress has bricked spacebar after
    -- /reload before. Only bind these when modified.
    local hasMod = (IsAltKeyDown and IsAltKeyDown())
        or (IsControlKeyDown and IsControlKeyDown())
        or (IsShiftKeyDown and IsShiftKeyDown())
    if not hasMod and Utils.IsReservedBareKey(key) then return nil end
    return Utils.ModifierCombo(key)
end

-- An armed capture ends as a fight starts: PLAYER_REGEN_DISABLED comes
-- before lockdown, so the disarm's EnableKeyboard(false) still runs.
do
local armedCaptures = {}
local captureFightWatch
local function StopCapturesForFight()
    for frame, onCombo in pairs(armedCaptures) do onCombo(frame, "stop") end
end

-- Arms a frame for a binding capture: keys, the mouse buttons past the
-- first two (MB3 and up) and the wheel, each through CaptureKeybindCombo;
-- onCombo(frame, combo) gets "stop" for Escape. Disarm puts back what the
-- frame had.
function Utils.ArmBindingCapture(frame, onCombo)
    local function take(self, key)
        local combo = Utils.CaptureKeybindCombo(key)
        if combo then onCombo(self, combo) end
    end
    frame._efCaptureHad = { down = frame:GetScript("OnMouseDown"), wheel = frame:GetScript("OnMouseWheel"),
                            wheelOn = frame:IsMouseWheelEnabled() }
    Utils.SafeCallMethod(frame, "EnableKeyboard", true)
    frame:EnableMouseWheel(true)
    frame:SetScript("OnKeyDown", take)
    frame:SetScript("OnMouseDown", function(self, button)
        local n = button:match("^Button(%d+)$")
        local key = (button == "MiddleButton" and "BUTTON3") or (n and "BUTTON" .. n)
        if key then take(self, key) end
    end)
    frame:SetScript("OnMouseWheel", function(self, delta)
        take(self, delta > 0 and "MOUSEWHEELUP" or "MOUSEWHEELDOWN")
    end)
    armedCaptures[frame] = onCombo
    if not captureFightWatch then
        captureFightWatch = CreateFrame("Frame")
        captureFightWatch:Hide()
        captureFightWatch:SetScript("OnEvent", StopCapturesForFight)
    end
    captureFightWatch:RegisterEvent("PLAYER_REGEN_DISABLED")
end
function Utils.DisarmBindingCapture(frame)
    armedCaptures[frame] = nil
    if captureFightWatch and not next(armedCaptures) then
        captureFightWatch:UnregisterEvent("PLAYER_REGEN_DISABLED")
    end
    local had = frame._efCaptureHad or {}
    frame._efCaptureHad = nil
    Utils.SafeCallMethod(frame, "EnableKeyboard", false)
    frame:EnableMouseWheel(had.wheelOn and true or false)
    frame:SetScript("OnKeyDown", nil)
    frame:SetScript("OnMouseDown", had.down)
    frame:SetScript("OnMouseWheel", had.wheel)
end
end

function Utils.GetVerticalNavIntent(key)
    local navKey = Utils.NormalizeKey(key)
    if navKey == "DOWN" then return 1, false, navKey end
    if navKey == "UP" then return -1, false, navKey end
    if IsAltKeyDown and IsAltKeyDown() then
        if navKey == "J" then return 1, true, navKey end
        if navKey == "K" then return -1, true, navKey end
    end
    return nil, false, navKey
end

function Utils.IsSuppressedAltNavLeak(currentText, suppress)
    if not suppress then return false end
    local key = suppress.key
    if not key or key == "" then return true end
    local restoreText = suppress.text or ""
    currentText = currentText or ""
    if currentText == restoreText then return true end

    local lowerCurrent = currentText:lower()
    local cursor = suppress.cursor or #restoreText
    if cursor < 0 then cursor = 0 end
    if cursor > #restoreText then cursor = #restoreText end
    if (restoreText:sub(1, cursor) .. key .. restoreText:sub(cursor + 1)):lower() == lowerCurrent then
        return true
    end
    if #currentText ~= #restoreText + #key then return false end
    for pos = 0, #restoreText do
        if (restoreText:sub(1, pos) .. key .. restoreText:sub(pos + 1)):lower() == lowerCurrent then
            return true
        end
    end
    return false
end

function Utils.SuppressNextAltNavChar(box, key, ttl)
    if not box then return end
    local token = (box._easyFindSuppressAltNavToken or 0) + 1
    box._easyFindSuppressAltNavToken = token
    box._easyFindSuppressAltNavChar = {
        key = key and tostring(key):lower(),
        text = box.GetText and (box:GetText() or "") or "",
        cursor = box.GetCursorPosition and (box:GetCursorPosition() or #(box:GetText() or "")) or 0,
    }
    -- TTL is a safety backstop in case the consumer never fires. It needs
    -- to outlive the ticker's initialDelay (0.30s) plus the worst-case
    -- OnTextChanged deferral, otherwise the snapshot can expire exactly
    -- when an OS auto-repeated character lands. 1.0s is conservative
    -- without being so long that stale snapshots interfere with normal
    -- typing.
    Utils.SafeAfter(ttl or 1.0, function()
        if box._easyFindSuppressAltNavToken == token then
            box._easyFindSuppressAltNavChar = nil
        end
    end)
end

function Utils.ConsumeSuppressedAltNavChar(box)
    if not box then return false end
    local suppress = box._easyFindSuppressAltNavChar
    if not suppress then return false end
    box._easyFindSuppressAltNavChar = nil
    local currentText = box.GetText and (box:GetText() or "") or ""
    if not Utils.IsSuppressedAltNavLeak(currentText, suppress) then return false end

    local restoreText = suppress.text or ""
    if box.SetText then box:SetText(restoreText) end
    if box.SetCursorPosition then box:SetCursorPosition(suppress.cursor or #restoreText) end
    if box.HighlightText then box:HighlightText(0, 0) end
    -- Re-arm the snapshot so OS-level key auto-repeat (which keeps firing
    -- char-insert events at ~20Hz while the user holds Alt+J/K) keeps
    -- getting caught. Without this, only the first leaked character is
    -- restored; subsequent auto-repeats leak through until the next ticker
    -- tick re-arms (~300ms away).
    Utils.SuppressNextAltNavChar(box, suppress.key)
    return true, restoreText
end

-- One-shot character swallow at the OnChar boundary. Unlike the snapshot
-- repair above, this works even when the keypress's handler REWRITES the
-- editbox text before the char event lands (a result shortcut applying a
-- quick filter and clearing the box): OnChar fires right after the client
-- inserts the character, so stripping the byte at the cursor removes the
-- leaked char no matter what the text has become in between.
-- held: every insert of the char for a second, as a key held down repeats,
-- or for that many seconds; box._efSwallowChar = nil ends it sooner.
function Utils.SwallowNextCharInsert(box, char, held)
    if not (box and char and char ~= "") then return end
    local span = held and (type(held) == "number" and held or 1) or 0.6
    box._efSwallowChar = { char = char:lower(), expires = GetTime() + span, held = held }
    if box._efSwallowCharHooked then return end
    box._efSwallowCharHooked = true
    box:HookScript("OnChar", function(self, typedChar)
        local armed = self._efSwallowChar
        if not armed then return end
        if GetTime() > armed.expires then
            self._efSwallowChar = nil
            return
        end
        if not typedChar or typedChar:lower() ~= armed.char then return end
        if not armed.held then self._efSwallowChar = nil end
        local cursor = self:GetCursorPosition() or 0
        if cursor < 1 then return end
        local text = self:GetText() or ""
        self:SetText(text:sub(1, cursor - 1) .. text:sub(cursor + 1))
        self:SetCursorPosition(cursor - 1)
    end)
end

function Utils.AttachAltNavCharSuppressor(editBox, onRestored)
    if not editBox or editBox._easyFindAltNavSuppressHooked then return end
    editBox._easyFindAltNavSuppressHooked = true
    editBox:HookScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        local restored, restoreText = Utils.ConsumeSuppressedAltNavChar(self)
        if restored and onRestored then onRestored(self, restoreText) end
    end)
end

function Utils.AfterAltNavReleased(key, callback)
    local navKey = Utils.NormalizeKey(key)
    if (IsAltKeyDown and IsAltKeyDown())
       or (navKey and Utils.IsPhysicalKeyDown(navKey)) then
        Utils.SafeAfter(0.03, function()
            Utils.AfterAltNavReleased(navKey, callback)
        end)
        return false
    end
    if callback then callback() end
    return true
end

function Utils.ScheduleAfterAltNavRelease(key, callback, delay)
    Utils.SafeAfter(delay or 0.05, function()
        Utils.AfterAltNavReleased(key, callback)
    end)
end

function Utils.StartKeyRepeatOnce(repeater, key, step)
    key = Utils.NormalizeKey(key)
    if not (repeater and repeater.Start) then
        return not step or step() ~= false
    end
    if repeater.IsKey and repeater.IsKey(key) then return true end
    repeater.Start(key, function()
        if step and step() == false then
            if repeater.Stop then repeater.Stop(key) end
        end
    end)
    return true
end

function Utils.StartAltNavRepeat(repeater, key, editBox, step, onReleased)
    key = Utils.NormalizeKey(key)
    Utils.SuppressNextAltNavChar(editBox, key)
    local function RunStep()
        local moved = not step or step() ~= false
        -- History navigation can change the editbox text during the keydown.
        -- Refresh the snapshot so a late leaked J/K restores the new text,
        -- not the text that existed before the history step.
        Utils.SuppressNextAltNavChar(editBox, key)
        return moved
    end
    if not (repeater and repeater.Start) then
        local moved = RunStep()
        if not moved and onReleased then Utils.ScheduleAfterAltNavRelease(key, onReleased) end
        return moved
    end
    if repeater.IsKey and repeater.IsKey(key) then return true end
    repeater.Start(key, function()
        local altHeld = IsAltKeyDown and IsAltKeyDown()
        local keyHeld = Utils.IsPhysicalKeyDown(key)
        if not altHeld or not keyHeld then
            if repeater.Stop then repeater.Stop(key) end
            if onReleased then Utils.ScheduleAfterAltNavRelease(key, onReleased) end
            return
        end
        if not RunStep() then
            if repeater.Stop then repeater.Stop(key) end
            if onReleased then Utils.ScheduleAfterAltNavRelease(key, onReleased) end
        end
    end)
    return true
end

-- IME composition support: while a system IME composes (Chinese pinyin and
-- friends), the IME owns the editbox -- ANY programmatic write corrupts the
-- composition. SetText mid-composition leaves pinyin behind on commit, and
-- even HighlightText(0, 0) is destructive: the IME marks its composition
-- region WITH the selection, so clearing it makes the next update insert
-- instead of replace (the accumulated-pinyin garbage). While the composing
-- flag is set every autocomplete write is held. A composition does NOT end
-- by going quiet -- the user can sit in the candidate window indefinitely --
-- it ends only on commit (OnChar delivers the committed characters) or
-- cancel (a composition event with empty text). One frame after either,
-- typed text resyncs from the box and candidates evaluate again. Committed
-- CJK completes like any other prefix (offset math is byte-based and
-- committed boundaries are character boundaries), so the feature stays on
-- for every locale.

local function AutocompleteHas(state)
    return state.currentCandidate ~= nil and (state.editBox:GetText() or "") ~= state.typedText
end

local function AutocompleteNormalize(state, candidate)
    if not candidate or candidate == "" or state.typedText == "" then return nil end
    candidate = slower(candidate)
    local typedLen = #state.typedText
    if typedLen >= #candidate then return nil end
    if slower(ssub(candidate, 1, typedLen)) ~= slower(state.typedText) then
        return nil
    end
    return candidate
end

local function AutocompleteStrip(state)
    if state.imeComposing then
        -- No writes while the IME owns the box; state-only reset.
        state.currentCandidate = nil
        state.smoothExtendDone = false
        return false
    end
    local editBox = state.editBox
    local hadAutocomplete = AutocompleteHas(state)
    if hadAutocomplete then
        state.programmatic = true
        editBox:SetText(state.typedText)
        editBox:SetCursorPosition(#state.typedText)
        editBox:HighlightText(0, 0)
        state.programmatic = false
    elseif not state.endOfTextOnly then
        -- Search bar only: drop a stray selection so Enter is not swallowed
        -- as a deselect. A shared chat box keeps whatever selection it
        -- holds: the client's own /w name completion keeps the rest of the
        -- name selected for Tab, and clearing it here committed the name
        -- unasked on every keystroke.
        editBox:HighlightText(0, 0)
    end
    state.currentCandidate = nil
    state.smoothExtendDone = false
    return hadAutocomplete
end

local function AutocompleteRender(state, candidate)
    candidate = AutocompleteNormalize(state, candidate)
    if not candidate then
        AutocompleteStrip(state)
        return false
    end

    local editBox = state.editBox
    -- WoW defers OnTextChanged by one frame, so the in-flight char
    -- isn't in typedText yet. SetText here would overwrite it and the
    -- deferred OnTextChanged would silently drop the keystroke.
    local liveText = editBox:GetText() or ""
    local liveCursor = editBox:GetCursorPosition() or #liveText
    local hasLiveSuggestion = state.currentCandidate ~= nil
                              and liveText == state.currentCandidate
                              and liveCursor == #state.typedText
    local liveTyped = ssub(liveText, 1, liveCursor)
    if not hasLiveSuggestion and liveTyped ~= state.typedText then
        return false
    end

    local typedLen = #state.typedText
    state.typedText = ssub(candidate, 1, typedLen)
    state.currentCandidate = candidate

    state.programmatic = true
    if editBox:GetText() ~= candidate then
        editBox:SetText(candidate)
    end
    editBox:SetCursorPosition(typedLen)
    editBox:HighlightText(typedLen, #candidate)
    state.programmatic = false
    return true
end

local function AutocompleteApply(state)
    if state.imeComposing or state.candidatesDisabled then return end
    if state.enabled and not state.enabled() then return end
    local editBox = state.editBox
    if state.programmatic or state.typedText == "" or not editBox:HasFocus() then
        AutocompleteStrip(state)
        return
    end
    -- Rendering rebuilds the WHOLE box text from the candidate, which
    -- drops anything after the cursor. On shared surfaces (chat boxes)
    -- ghosting is therefore end-of-text only; mid-text edits never ghost.
    if state.endOfTextOnly then
        local liveText = editBox:GetText() or ""
        if (editBox:GetCursorPosition() or #liveText) < #liveText then
            AutocompleteStrip(state)
            return
        end
    end
    if state.smoothExtendDone then
        state.smoothExtendDone = false
        return
    end
    AutocompleteRender(state, state.findCandidate(state.typedText))
end

local function AutocompleteRestoreBackspace(state, box)
    if state.restoreBackspaceText and state.restoreBackspaceNotify then
        local restoreText = state.restoreBackspaceText
        local restoreCursor = state.restoreBackspaceCursor or #restoreText
        state.restoreBackspaceText, state.restoreBackspaceCursor = nil, nil
        state.restoreBackspaceNotify = false
        state.backspaceStripActive = false
        state.programmatic = true
        box:SetText(restoreText)
        box:SetCursorPosition(restoreCursor)
        box:HighlightText(0, 0)
        state.programmatic = false
        state.typedText = ssub(restoreText, 1, restoreCursor)
        state.currentCandidate = nil
        state.smoothExtendDone = false
        if state.onBackspaceAutocompleteRestored then
            state.onBackspaceAutocompleteRestored(box, state.typedText)
        end
        return
    end
    state.restoreBackspaceText, state.restoreBackspaceCursor = nil, nil
    state.restoreBackspaceNotify = false
    state.backspaceStripActive = false
end

local function AutocompleteOnTextChanged(state, box, userInput)
    if state.programmatic then return end
    if state.imeComposing then
        -- Track only: the box may hold transient composition text, and the
        -- IME must not see it move underneath. The change still forwards
        -- so search-on-type keeps running.
        state.restoreBackspaceText, state.restoreBackspaceCursor = nil, nil
        state.restoreBackspaceNotify = false
        state.backspaceStripActive = false
        state.currentCandidate = nil
        state.smoothExtendDone = false
        local liveText = box:GetText() or ""
        local liveCursor = box:GetCursorPosition() or #liveText
        local prevText = state.typedText
        state.typedText = ssub(liveText, 1, liveCursor)
        if state.typedText ~= prevText and state.onTypedChanged then
            state.onTypedChanged(box, state.typedText, prevText, #state.typedText > #prevText)
        end
        return
    end
    local current = box:GetText() or ""
    if state.restoreBackspaceText then
        local restoreText = state.restoreBackspaceText
        local restoreCursor = state.restoreBackspaceCursor or #restoreText
        local notify = state.restoreBackspaceNotify
        state.restoreBackspaceText, state.restoreBackspaceCursor = nil, nil
        state.restoreBackspaceNotify = false
        state.backspaceStripActive = false
        if current ~= restoreText then
            state.programmatic = true
            box:SetText(restoreText)
            box:SetCursorPosition(restoreCursor)
            box:HighlightText(0, 0)
            state.programmatic = false
        end
        state.typedText = ssub(restoreText, 1, restoreCursor)
        state.currentCandidate = nil
        state.smoothExtendDone = false
        if notify and state.onBackspaceAutocompleteRestored then
            state.onBackspaceAutocompleteRestored(box, state.typedText)
        end
        return
    end
    local cursorPos = box:GetCursorPosition() or #current
    if not userInput and cursorPos == 0 and current ~= "" then
        cursorPos = #current
    end
    local typed = ssub(current, 1, cursorPos)
    if state.charDispatchedTyped and typed == state.charDispatchedTyped then
        state.charDispatchedTyped = nil
        return
    end
    if typed == state.typedText then return end
    local prevText = state.typedText
    local prevLen = #state.typedText
    state.typedText = typed
    local grew = #state.typedText > prevLen
    -- Smooth-extend the candidate in-place: safe here because we run
    -- synchronously inside OnTextChanged (post-keystroke), not from
    -- the throttle's OnUpdate, so there's no in-flight char to clobber.
    local extended = false
    if grew and state.currentCandidate
       and #typed < #state.currentCandidate
       and slower(ssub(state.currentCandidate, 1, #typed)) == slower(typed) then
        local typedLen = #typed
        state.programmatic = true
        if box:GetText() ~= state.currentCandidate then
            box:SetText(state.currentCandidate)
        end
        box:SetCursorPosition(typedLen)
        box:HighlightText(typedLen, #state.currentCandidate)
        state.programmatic = false
        extended = true
    end
    if not extended then
        -- Only a selection this helper painted (its own ghost) is its to
        -- clear; a selection it never made belongs to someone else (the
        -- client's chat name completion).
        local hadGhost = state.currentCandidate ~= nil
        state.currentCandidate = nil
        if hadGhost then box:HighlightText(0, 0) end
    end
    if state.onTypedChanged then state.onTypedChanged(box, state.typedText, prevText, grew) end
    -- Self-driving surfaces (chat boxes): nothing external calls
    -- UpdateAutocomplete for them, so apply here on growth. Synchronous
    -- post-keystroke, the same safety window the smooth-extend above
    -- relies on; grew-only so deletions never fight the ghost.
    if state.applyOnType and userInput and grew and not extended then
        AutocompleteApply(state)
    end
end

local function AutocompleteAccept(state, box, source, cursorPos)
    local candidate = state.currentCandidate
    if not candidate or candidate == "" then return false end
    if cursorPos then
        if cursorPos < 0 then cursorPos = 0 end
        if cursorPos > #candidate then cursorPos = #candidate end
    end
    if not box:HasFocus() then box:SetFocus() end
    state.programmatic = true
    box:SetText(candidate)
    box:SetCursorPosition(cursorPos or #candidate)
    box:HighlightText(0, 0)
    state.programmatic = false
    state.typedText = candidate
    state.currentCandidate = nil
    state.smoothExtendDone = false
    if state.onAccepted then state.onAccepted(candidate, source) end
    return true
end

-- A press whose release moved farther than this (UI units) is a
-- drag-select, not a click, so the caret's final index must not drive the
-- accept/strip decision below.
local AUTOCOMPLETE_CLICK_SLOP = 4

local function AutocompleteOnMouseDown(state, button)
    if button ~= "LeftButton" then return end
    state.mouseAcceptCandidate = AutocompleteHas(state) and state.currentCandidate or nil
    state.mouseAcceptTypedLen = state.mouseAcceptCandidate and #state.typedText or nil
    if state.mouseAcceptCandidate then
        state.mouseDownX, state.mouseDownY = GetCursorPosition()
    end
end

local function AutocompleteOnMouseUp(state, box, button)
    if button ~= "LeftButton" or not state.mouseAcceptCandidate then return end
    local candidate = state.mouseAcceptCandidate
    local typedLen = state.mouseAcceptTypedLen or #state.typedText
    local downX, downY = state.mouseDownX, state.mouseDownY
    state.mouseAcceptCandidate = nil
    state.mouseAcceptTypedLen = nil
    state.mouseDownX, state.mouseDownY = nil, nil
    -- Drag-select (the mouse moved between down and up): leave the user's
    -- selection intact instead of stripping or accepting the suggestion.
    if downX and downY then
        local upX, upY = GetCursorPosition()
        local scale = (box.GetEffectiveScale and box:GetEffectiveScale()) or 1
        if scale <= 0 then scale = 1 end
        if (mabs(upX - downX) + mabs(upY - downY)) / scale > AUTOCOMPLETE_CLICK_SLOP then
            return
        end
    end
    if (box:GetText() or "") ~= candidate then return end
    local cursorPos = box:GetCursorPosition() or #candidate
    if cursorPos < typedLen then
        local prefix = ssub(candidate, 1, typedLen)
        state.programmatic = true
        box:SetText(prefix)
        box:SetCursorPosition(cursorPos)
        box:HighlightText(0, 0)
        state.programmatic = false
        state.typedText = prefix
        state.currentCandidate = nil
        state.smoothExtendDone = false
        return
    end
    state.typedText = candidate
    state.currentCandidate = nil
    state.smoothExtendDone = false
    box:HighlightText(0, 0)
    if state.onAccepted then state.onAccepted(candidate, "click") end
end

local function AutocompleteOnBackspace(state, box)
    local targetText, targetCursor
    if state.backspaceAutocompleteTarget then
        targetText, targetCursor = state.backspaceAutocompleteTarget(box, state.typedText, state.currentCandidate)
    end
    if targetText == nil then
        targetText = state.typedText
        targetCursor = #state.typedText
        state.restoreBackspaceNotify = false
    else
        targetText = tostring(targetText)
        if targetCursor == nil then targetCursor = #targetText end
        state.restoreBackspaceNotify = true
    end
    state.backspaceStripActive = true
    state.restoreBackspaceText = targetText
    state.restoreBackspaceCursor = targetCursor
    AutocompleteStrip(state)
    if Utils.SafeAfter then
        Utils.SafeAfter(0, function()
            AutocompleteRestoreBackspace(state, box)
        end)
    end
    if Utils.SafeCallMethod then
        Utils.SafeCallMethod(box, "SetPropagateKeyboardInput", false)
    end
end

local function AutocompleteOnKeyDown(state, box, key)
    if key == "BACKSPACE" and AutocompleteHas(state) then
        AutocompleteOnBackspace(state, box)
        return
    end
    local source
    if key == "RIGHT" or key == "ARROWRIGHT" then
        source = "right"
    elseif key == "L" and IsControlKeyDown() then
        source = "ctrl-l"
    end
    if source and AutocompleteAccept(state, box, source) and Utils.SafeCallMethod then
        Utils.SafeCallMethod(box, "SetPropagateKeyboardInput", false)
    end
end

function Utils.AttachAutocomplete(editBox, opts)
    if not editBox or not opts or type(opts.findCandidate) ~= "function" then return end

    local state = {
        editBox = editBox,
        findCandidate = opts.findCandidate,
        -- Optional live gate: candidates only render while it returns true
        -- (per-surface user toggles); tracking and accept plumbing stay
        -- armed so re-enabling needs no reattach.
        enabled = opts.enabled,
        onTypedChanged = opts.onTypedChanged,
        onAccepted = opts.onAccepted,
        backspaceAutocompleteTarget = opts.backspaceAutocompleteTarget,
        onBackspaceAutocompleteRestored = opts.onBackspaceAutocompleteRestored,
        typedText = "",
        programmatic = false,
        currentCandidate = nil,
        smoothExtendDone = false,
        restoreBackspaceNotify = false,
        backspaceStripActive = false,
        endOfTextOnly = opts.endOfTextOnly or nil,
        applyOnType = opts.applyOnType or nil,
    }

    editBox:HookScript("OnTextChanged", function(self, userInput)
        AutocompleteOnTextChanged(state, self, userInput)
    end)
    editBox:HookScript("OnEditFocusLost", function(self)
        -- The clipboard box borrowing focus for a Ctrl+C hands it back on
        -- Ctrl-up; the suffix stays rendered through the round trip.
        if self._efClipboardHold then return end
        AutocompleteStrip(state)
    end)
    editBox:HookScript("OnMouseDown", function(_, button)
        AutocompleteOnMouseDown(state, button)
    end)
    editBox:HookScript("OnMouseUp", function(self, button)
        AutocompleteOnMouseUp(state, self, button)
    end)
    editBox:HookScript("OnTabPressed", function(self)
        AutocompleteAccept(state, self, "tab")
    end)
    editBox:HookScript("OnKeyDown", function(self, key)
        AutocompleteOnKeyDown(state, self, key)
    end)

    -- Composition tracking: event-driven, never time-driven. Clients
    -- without the composition script fall back to disabling inline
    -- candidates on IME locales outright (zh composition text is
    -- plain-ASCII pinyin, undetectable by content) -- protected either
    -- way, and the feature stays on wherever the signal exists.
    state.imeComposing = false
    state.imeEndToken = 0
    local function ImeCompositionEnd()
        state.imeEndToken = state.imeEndToken + 1
        local token = state.imeEndToken
        -- One frame late: a multi-character commit delivers each character
        -- through OnChar in a burst, and the box must settle before the
        -- resync; a new composition starting first cancels this via the
        -- token bump in the composition hook.
        Utils.SafeAfter(0, function()
            if state.imeEndToken ~= token then return end
            state.imeComposing = false
            local liveText = editBox:GetText() or ""
            local liveCursor = editBox:GetCursorPosition() or #liveText
            state.typedText = ssub(liveText, 1, liveCursor)
            state.currentCandidate = nil
            if editBox:HasFocus() then
                AutocompleteApply(state)
            end
        end)
    end
    local imeHookOk = pcall(editBox.HookScript, editBox, "OnCharComposition", function(_, compText)
        if compText and compText ~= "" then
            state.imeComposing = true
            state.imeEndToken = state.imeEndToken + 1
        else
            -- Empty composition text = cancelled or resolved.
            ImeCompositionEnd()
        end
    end)
    if imeHookOk then
        editBox:HookScript("OnChar", function()
            -- Commit: the IME resolved the composition into real characters.
            if state.imeComposing then ImeCompositionEnd() end
        end)
    else
        local locale = GetLocale and GetLocale()
        if locale == "zhCN" or locale == "zhTW" then
            state.candidatesDisabled = true
        end
    end

    editBox.UpdateAutocomplete = function()
        return AutocompleteApply(state)
    end
    editBox.StripAutocomplete = function()
        return AutocompleteStrip(state)
    end
    editBox.AcceptAutocomplete = function(self, source, cursorPos)
        return AutocompleteAccept(state, self, source, cursorPos)
    end
    editBox.GetTypedText = function() return state.typedText end
    editBox.HasAutocomplete = function() return AutocompleteHas(state) end
    editBox.IsAutocompleteBackspaceStrip = function() return state.backspaceStripActive end
    editBox.IsAutocompleteProgrammatic = function() return state.programmatic end
end

function Utils.ScrollToButton(scrollFrame, button)
    if not scrollFrame or not button then return end
    local _, _, _, _, btnOffsetY = button:GetPoint(1)
    if not btnOffsetY then return end
    local btnTop = -btnOffsetY
    local btnBot = btnTop + button:GetHeight()
    local visH = scrollFrame:GetHeight()
    local cur = scrollFrame:GetVerticalScroll()
    if btnTop < cur then
        scrollFrame:SetVerticalScroll(btnTop)
    elseif btnBot > cur + visH then
        scrollFrame:SetVerticalScroll(btnBot - visH)
    end
end

ns.GOLD_COLOR = {1.0, 0.82, 0.0}
ns.YELLOW_HIGHLIGHT = {1, 1, 0}
-- Filter flyouts and selector popups size to their widest row, never
-- narrower than this.
ns.FLYOUT_MIN_WIDTH = 110
ns.SEARCH_WINDOW_ALPHA = 0.95
-- Initial hover delay before supplementary tooltips appear.
ns.TOOLTIP_HOVER_DELAY = 0.4

-- Standard delayed hover tooltip on the themed hint panel (never
-- GameTooltip, which is for real item and spell tooltips). resolve(frame)
-- returns title, body and an optional dim third line; returning nothing
-- shows nothing. Hooks (never sets) OnEnter/OnLeave so it composes with a
-- control's own hover visuals.
-- A tooltip must not open by repeating the label the cursor is already
-- on. When the resolved title is text the owner itself shows (its label
-- font string, a child region, a parent row's label), the title is
-- dropped and the description stands alone. A title that says something
-- the control does not (a keybind's action, a code's purpose) stays.
local LABEL_FIELDS = { "_label", "label", "text", "Text" }
local function ShowsText(frame, text)
    for i = 1, #LABEL_FIELDS do
        local fs = frame[LABEL_FIELDS[i]]
        if type(fs) == "table" and fs.GetText and fs:GetText() == text then return true end
    end
    if frame.GetFontString then
        local fs = frame:GetFontString()
        if fs and fs:GetText() == text then return true end
    end
    if frame.GetRegions then
        for _, region in ipairs({ frame:GetRegions() }) do
            if region.GetText and region:IsShown() and region:GetText() == text then return true end
        end
    end
    return false
end

local function OwnerShowsText(owner, text)
    if type(text) ~= "string" or text == "" then return false end
    if ShowsText(owner, text) then return true end
    local parent = owner:GetParent()
    return parent ~= nil and parent ~= UIParent and ShowsText(parent, text)
end
Utils.OwnerShowsText = OwnerShowsText

function Utils.AttachDelayedTooltip(frame, anchor, resolve)
    frame:HookScript("OnEnter", function(self)
        local token = (self._efTipToken or 0) + 1
        self._efTipToken = token
        Utils.SafeAfter(ns.TOOLTIP_HOVER_DELAY, function()
            if self._efTipToken ~= token or not self:IsMouseOver() then return end
            local title, body, dimLine = resolve(self)
            if not title and not body then return end
            if body and OwnerShowsText(self, title) then
                title, body, dimLine = body, dimLine, nil
            end
            ns.ShowHintTooltip(self, anchor, title, body, dimLine)
        end)
    end)
    frame:HookScript("OnLeave", function(self)
        self._efTipToken = (self._efTipToken or 0) + 1
        ns.HideHintTooltip(self)
    end)
end
function ns.GetSearchWindowAlpha()
    local db = EasyFind and EasyFind.db
    if db and type(db.searchWindowOpacity) == "number" then
        return db.searchWindowOpacity
    end
    return ns.SEARCH_WINDOW_ALPHA
end
-- The classic skin: the game's own tooltip frame on any rounded-chrome
-- surface while the window border option is on. Border art in its own tan,
-- the theme's navy underneath, the rounded pieces hidden; ns.ApplySkin
-- owns the switch and hands the rounded look back.
-- The 1.x frame art: the black marble behind the client's own lists, the
-- ornate dialog border on windows and at half its weight on the bar,
-- results and menus, and the header plate with a gold title on top of a
-- window.
local CLASSIC_DIALOG_BG = "Interface\\FrameGeneral\\UI-Background-Marble"
ns.CLASSIC_BACKDROP = {            -- bar, results, menus
    bgFile = CLASSIC_DIALOG_BG,
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 256, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}
-- Its metal ends 6 in at that edge size (12 of the art's 32 columns): drawn
-- that far outside the frame, rows and scroll bars run to the frame's edge
-- clear of it.
ns.CLASSIC_OUTSET = 6
-- Panes inside a window: the thin tooltip edge, so no metal nests in metal.
ns.CLASSIC_THIN = {
    bgFile = CLASSIC_DIALOG_BG,
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 256, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}
ns.CLASSIC_DIALOG = {              -- windows
    bgFile = CLASSIC_DIALOG_BG,
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 256, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
}
ns.CLASSIC_HEADER = "Interface\\DialogFrame\\UI-DialogBox-Header"
-- The window border option: on, the Classic and Forever themes wear their
-- frame art everywhere; off, every surface takes the rounded shape.
function ns.WindowBorderOn()
    local db = EasyFind and EasyFind.db
    if db and db.windowBorder == false then return false end
    -- A studio theme can ship borderless.
    local pal = ns.ACTIVE_UI_PALETTE
    return not (pal and pal.borderHidden)
end

-- The Classic and Forever themes' own frame art; off, they wear the line
-- border the other themes do. Only while the window border option is on.
function ns.FrameArtOn()
    local db = EasyFind and EasyFind.db
    return ns.WindowBorderOn() and not (db and db.themeFrameArt == false)
end

function ns.IsClassicChrome()
    local p = ns.ACTIVE_UI_PALETTE
    return p ~= nil and p.chrome == "classic" and ns.FrameArtOn()
end
-- style: "dialog" for a window, anything else the thin tooltip frame.
function ns.ApplyClassicChrome(frame, alpha, style)
    if not (frame and frame.combinedBorder and ns.ApplySkin) then return false end
    frame._efClassicSurface = true
    frame._efClassicStyle = style
    frame._efClassicAlpha = alpha
    return ns.ApplySkin(frame)
end

-- The filter dropdown and row context menus reuse the results window's
-- rounded-rect panel object so they match it exactly (fill + border) and track
-- the opacity setting, going fully solid at 100%.
function ns.StyleMenuPanel(frame)
    if not frame.combinedBorder then
        ns.CreateRoundedRectBorder(frame)
        ns.SetRoundedRectBorderShown(frame, true)
    end
    frame._efForeverSurface = true
    frame._efClassicSurface = true
    -- Registry (weak keys) so a theme flip can restyle menus that are
    -- OPEN at that moment; their OnShow refill never refires for them.
    ns._menuPanels = ns._menuPanels or setmetatable({}, { __mode = "k" })
    ns._menuPanels[frame] = true
    -- Repainted on every style pass, not just creation, so menus follow
    -- the live theme fill (including gradients) after a theme switch.
    ns.ApplyThemeFill(frame)
    if not frame._efMenuHighlightRefreshHooked then
        frame._efMenuHighlightRefreshHooked = true
        frame:HookScript("OnShow", function(self)
            -- Re-fill on open, but ONLY when the theme generation or the
            -- window alpha changed since this panel's last refill:
            -- hover-cascade flyouts open dozens of times a minute, and
            -- running the full restyle pipeline on every open was the
            -- filter menu's entire hover-spam CPU cost. A theme flip
            -- while the panel is OPEN restyles through the registry
            -- (RestyleShownMenuPanels); the stale stamp after one costs
            -- a single redundant refill on the next open, nothing more.
            local alpha = ns.GetSearchWindowAlpha()
            if self._efMenuStyleGen == ns.uiThemeGeneration
               and self._efMenuStyleAlpha == alpha then
                return
            end
            self._efMenuStyleGen = ns.uiThemeGeneration
            self._efMenuStyleAlpha = alpha
            -- Steps are pcall-isolated: one failure must
            -- not strand the menu wearing the previous theme.
            pcall(ns.ApplyThemeFill, self)
            pcall(ns.SetRoundedRectBorderBgAlpha, self, ns.GetSearchWindowAlpha())
            if Utils.RefreshMenuRowHighlights then
                pcall(Utils.RefreshMenuRowHighlights, self)
            end
            pcall(ns.RetintMenuSeparators, self)
            pcall(ns.RetintMenuText, self)
            -- Per-panel extras (header tints and similar) ride the same
            -- refill on open as they do on live theme flips, AFTER the
            -- generic text pass so they can override it.
            if self._efOnThemeRestyle then
                pcall(self._efOnThemeRestyle, self)
            end
        end)
    end
    ns.SetRoundedRectBarHeight(frame, ns.SEARCHBAR_HEIGHT)
    ns.SetRoundedRectBorderBgAlpha(frame, ns.GetSearchWindowAlpha())
end

-- ONE owner for menu text color: every FontString inside a menu surface
-- wears the theme's main text color (shadow off), re-derived on every
-- open and live flip by the shared refill. Exceptions opt out with
-- fs._efOwnColor = true (gold context-menu labels, dialog prompts,
-- button labels on dark pills); disabled rows keep their dim subtree.
local function RetintMenuTextWalk(frame, leaf)
    if frame._efRowEnabled == false then return end
    if frame.GetRegions then
        for i = 1, select("#", frame:GetRegions()) do
            local region = select(i, frame:GetRegions())
            if region and region.GetObjectType and region:GetObjectType() == "FontString"
               and not region._efOwnColor then
                region:SetShadowColor(0, 0, 0, 0)
                region:SetTextColor(leaf[1], leaf[2], leaf[3], 1)
            end
        end
    end
    for i = 1, select("#", frame:GetChildren()) do
        RetintMenuTextWalk((select(i, frame:GetChildren())), leaf)
    end
end

function ns.RetintMenuText(frame)
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    local leaf = theme and theme.leafColor
    if not leaf then return end
    RetintMenuTextWalk(frame, leaf)
end

-- Thin separator lines inside menu panels follow the theme's separator
-- color. Panels register their lines in frame._efThemeSeps; retinted on
-- every refill (open and live theme flip).
function ns.RetintMenuSeparators(frame)
    local seps = frame._efThemeSeps
    if not seps then return end
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    local sep = theme and theme.separatorColor
    if not sep then return end
    for i = 1, #seps do
        seps[i]:SetColorTexture(sep[1], sep[2], sep[3], sep[4] or 0.35)
    end
end

-- Re-derive every currently-shown menu surface from the live theme.
-- Menus normally restyle in their OnShow refill; a menu that is open
-- while the theme flips never gets that event and stays stale (the
-- recurring "menu lags one theme behind" bug). ApplyUITheme calls this.
function ns.RestyleShownMenuPanels()
    if not ns._menuPanels then return end
    for frame in pairs(ns._menuPanels) do
        if frame:IsShown() then
            pcall(ns.ApplyThemeFill, frame)
            pcall(ns.SetRoundedRectBorderBgAlpha, frame, ns.GetSearchWindowAlpha())
            if Utils.RefreshMenuRowHighlights then
                pcall(Utils.RefreshMenuRowHighlights, frame)
            end
            pcall(ns.RetintMenuSeparators, frame)
            pcall(ns.RetintMenuText, frame)
            if frame._efOnThemeRestyle then
                pcall(frame._efOnThemeRestyle, frame)
            end
        end
    end
end

function ns.ApplyMenuOpacity(frame)
    if not frame then return end
    if frame.combinedBorder then
        ns.ApplyThemeFill(frame)
        ns.SetRoundedRectBorderBgAlpha(frame, ns.GetSearchWindowAlpha())
    elseif frame.SetBackdropColor then
        local r, g, b = unpack(ns.SEARCH_WINDOW_FILL_COLOR)
        frame:SetBackdropColor(r, g, b, ns.GetSearchWindowAlpha())
    end
end
ns.TOOLTIP_BORDER = "Interface\\Tooltips\\UI-Tooltip-Border"

ns.NON_EQUIP_LOCS = {
    INVTYPE_NON_EQUIP = true,
    INVTYPE_NON_EQUIP_IGNORE = true,
    INVTYPE_AMMO = true,
    INVTYPE_QUIVER = true,
}

ns.EQUIP_LOCS = {
    INVTYPE_HEAD = true,
    INVTYPE_NECK = true,
    INVTYPE_SHOULDER = true,
    INVTYPE_BODY = true,
    INVTYPE_CHEST = true,
    INVTYPE_ROBE = true,
    INVTYPE_WAIST = true,
    INVTYPE_LEGS = true,
    INVTYPE_FEET = true,
    INVTYPE_WRIST = true,
    INVTYPE_HAND = true,
    INVTYPE_FINGER = true,
    INVTYPE_TRINKET = true,
    INVTYPE_CLOAK = true,
    INVTYPE_WEAPON = true,
    INVTYPE_SHIELD = true,
    INVTYPE_2HWEAPON = true,
    INVTYPE_WEAPONMAINHAND = true,
    INVTYPE_WEAPONOFFHAND = true,
    INVTYPE_HOLDABLE = true,
    INVTYPE_RANGED = true,
    INVTYPE_RANGEDRIGHT = true,
    INVTYPE_THROWN = true,
    INVTYPE_RELIC = true,
    INVTYPE_TABARD = true,
    INVTYPE_BAG = true,
    INVTYPE_PROFESSION_TOOL = true,
    INVTYPE_PROFESSION_GEAR = true,
}

function Utils.IsRealEquipLoc(slot)
    return type(slot) == "string"
        and ns.EQUIP_LOCS[slot] == true
        and not ns.NON_EQUIP_LOCS[slot]
end

function Utils.GetItemEquipLoc(itemID)
    local getItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not getItemInfoInstant then return nil end
    local info, _, _, equipLoc = getItemInfoInstant(itemID)
    if type(info) == "table" then
        return info.itemEquipLoc or info.equipLoc or info.inventoryType
    end
    return equipLoc
end
ns.EYE_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\eye"
ns.LINK_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\link"
ns.SEARCH_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\search-icon"
-- The glyph fills only the inner ~27/32 of search-icon; crop the transparent
-- padding so it fills the icon bounds where sized directly (the search bar
-- compensates with its own icon scale instead).
ns.SEARCH_ICON_COORDS = { 0.094, 0.938, 0.094, 0.938 }
ns.COMMANDS_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\commands-icon"
ns.RADIO_OFF_TEX = "Interface\\AddOns\\EasyFind\\Search\\Images\\radio-off"
ns.RADIO_ON_TEX = "Interface\\AddOns\\EasyFind\\Search\\Images\\radio-on"
ns.FILTER_ARROW_TEX = "Interface\\AddOns\\EasyFind\\textures\\filter-arrow"
-- Glyphs cut from the game's sheets into files of our own: their coords
-- never move with a patch or a client. Each file is square, art top left.
ns.ART_DIR = "Interface\\AddOns\\EasyFind\\textures\\art\\"
ns.ART = {
    delve = { tex = ns.ART_DIR .. "delve", coords = { 0, 0.98438, 0, 0.96875 } },
    great_vault = { tex = ns.ART_DIR .. "great-vault", coords = { 0, 0.57812, 0, 0.57812 } },
    crest_horde = { tex = ns.ART_DIR .. "crest-horde", coords = { 0, 0.84375, 0, 0.84375 } },
    crest_alliance = { tex = ns.ART_DIR .. "crest-alliance", coords = { 0, 0.78125, 0, 0.8125 } },
    map = { tex = ns.ART_DIR .. "map", coords = { 0, 0.64062, 0, 0.65625 } },
    statistic = { tex = ns.ART_DIR .. "statistic", coords = { 0, 0.59375, 0, 0.875 } },
    ability = { tex = ns.ART_DIR .. "ability", coords = { 0, 0.73438, 0, 0.65625 } },
    boss = { tex = ns.ART_DIR .. "boss", coords = { 0, 0.75, 0, 0.67188 } },
    loot = { tex = ns.ART_DIR .. "loot", coords = { 0, 0.75, 0, 0.67188 } },
    title = { tex = ns.ART_DIR .. "title", coords = { 0, 0.51562, 0, 0.54688 } },
    gear_set = { tex = ns.ART_DIR .. "gear-set", coords = { 0, 0.51562, 0, 0.54688 } },
    transmog = { tex = ns.ART_DIR .. "transmog", coords = { 0, 0.98438, 0, 0.50391 } },
    items = { tex = ns.ART_DIR .. "items", coords = { 0, 0.86719, 0, 0.83594 } },
    gauntlet = { tex = ns.ART_DIR .. "gauntlet", coords = { 0, 0.92969, 0, 0.82031 } },
    quartermaster = { tex = ns.ART_DIR .. "quartermaster", coords = { 0, 0.96875, 0, 0.9375 } },
    rare = { tex = ns.ART_DIR .. "rare", coords = { 0, 0.9375, 0, 0.95312 } },
    catalyst = { tex = ns.ART_DIR .. "catalyst", coords = { 0, 0.9375, 0, 0.90625 } },
    decor = { tex = ns.ART_DIR .. "decor", coords = { 0, 0.96875, 0, 0.53125 } },
    lorewalker = { tex = ns.ART_DIR .. "lorewalker", coords = { 0, 0.59375, 0, 0.9375 } },
    crafting_orders = { tex = ns.ART_DIR .. "crafting-orders", coords = { 0, 0.90625, 0, 0.84375 } },
    rostrum = { tex = ns.ART_DIR .. "rostrum", coords = { 0, 0.96875, 0, 0.53125 } },
}

-- Reputation glyph: the player's faction crest; neutral gets the Alliance one.
ns.REP_CATEGORY_ICONS = { Horde = ns.ART.crest_horde, Alliance = ns.ART.crest_alliance }
function ns.PlayerRepCategoryIcon()
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    return ns.REP_CATEGORY_ICONS[faction] or ns.REP_CATEGORY_ICONS.Alliance
end

-- Items glyph, shared by the filter rows and the catalog result row.
ns.ITEMS_CATEGORY_ICON_TEX = ns.ART.items.tex
ns.ITEMS_CATEGORY_ICON_COORDS = ns.ART.items.coords
ns.ITEMS_CATEGORY_ICON_ASPECT = ns.ART.items.coords[2] / ns.ART.items.coords[4]

-- Bank glyph (the Buy crosshair cursor file, used whole -- not a sheet crop),
-- shared by the filter-menu row and the result-row category icon so the two
-- cannot drift apart.
ns.BANK_CATEGORY_ICON_TEX = 4675621
ns.BANK_CATEGORY_ICON_COORDS = { 0, 1, 0, 1 }

-- Classic lacks retail's cursor sheets: its own sack and purse glyphs.
if (ns.Caps and ns.Caps.classic) then
    ns.ITEMS_CATEGORY_ICON_TEX = "Interface\\Minimap\\Tracking\\Banker"
    ns.ITEMS_CATEGORY_ICON_COORDS = { 0, 1, 0, 1 }
    ns.ITEMS_CATEGORY_ICON_ASPECT = 1
    ns.BANK_CATEGORY_ICON_TEX = "Interface\\GossipFrame\\BankerGossipIcon"
end

-- The settings cog. Era has no quest log sheet: its options cog, greyed
-- like retail's silver one.
ns.SETTING_ICON = (not (ns.Caps and ns.Caps.questLogAtlas == false)) and { atlas = "QuestLog-icon-setting" }
    or { tex = "Interface\\Buttons\\UI-OptionsButton", desaturate = true }
-- Classic's gold options cog stands in for retail's interact cursor.
ns.OPTIONS_CATEGORY_ICON_TEX = (ns.Caps and ns.Caps.classic) and "Interface\\Buttons\\UI-OptionsButton" or 4675635
-- The quest log's expand/collapse glyph; Era's own buttons lacking its sheet.
function ns.SetQuestLogToggle(tex, collapsed, theme)
    if (not (ns.Caps and ns.Caps.questLogAtlas == false)) then
        tex:SetAtlas(collapsed and (theme and theme.expandAtlas or "QuestLog-icon-expand")
            or (theme and theme.collapseAtlas or "QuestLog-icon-shrink"))
    else
        tex:SetTexture(collapsed and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
    end
end

-- The backpack button: classic draws its own, retail's is an atlas.
ns.BAG_ICON_ATLAS = not (ns.Caps and ns.Caps.classic) and "bag-main" or nil
ns.BAG_ICON_TEX = (ns.Caps and ns.Caps.classic) and "Interface\\Buttons\\Button-Backpack-Up" or nil

-- Map-search and Statistics category glyphs (12.1 moved both on the shared
-- sheet), shared by the filter-menu rows and the result-row category icons.
ns.MAP_CATEGORY_ICON_TEX = ns.ART.map.tex
ns.MAP_CATEGORY_ICON_COORDS = ns.ART.map.coords
-- Classic's copy of the sheet is an older layout with no map glyph.
if (ns.Caps and ns.Caps.classic) then
    ns.MAP_CATEGORY_ICON_TEX = "Interface\\Icons\\INV_Misc_Map_01"
    ns.MAP_CATEGORY_ICON_COORDS = { 0.08, 0.92, 0.08, 0.92 }
end
ns.STAT_CATEGORY_ICON_TEX = ns.ART.statistic.tex
ns.STAT_CATEGORY_ICON_COORDS = ns.ART.statistic.coords

-- The key the per-character stored-item caches are filed under. ONE owner:
-- the provider writes db.bagCache.chars[key] with it and the scope picker
-- compares against it, so any divergence silently matches zero characters.
-- Deliberately not memoized -- a call before the unit exists would pin a
-- placeholder for the session.
function ns.CurrentCharacterKey()
    return (ns.PlayerName() or "?") .. "-" .. (GetRealmName() or "?")
end

-- The player's name as the game shows it. On Forever, UnitName and
-- UnitFullName return the surname as a second value ("Test", "Addons");
-- GetUnitName joins them. On retail it is UnitName's name.
function ns.PlayerName()
    return GetUnitName and GetUnitName("player", false) or UnitName("player")
end

-- The name a whisper reaches: the character's own, never Forever's surname.
function ns.WhisperName()
    return (UnitName("player"))
end

-- Forever surnames: per-character slots once keyed by the first name
-- alone are copied to the full name's key, not moved, since every
-- character sharing that first name used the old slot.
function ns.MigrateCharacterKeys(db)
    local first, surname = UnitName("player")
    local full = ns.PlayerName()
    if not (db and first and full and full ~= first) then return end
    local realm = GetRealmName() or "?"
    local old, new = first .. "-" .. realm, full .. "-" .. realm
    local holders = { db }
    for _, slot in pairs(type(db.profiles) == "table" and db.profiles or {}) do
        if type(slot) == "table" then holders[#holders + 1] = slot end
    end
    for _, holder in ipairs(holders) do
        for _, field in ipairs({ "profileKeys", "profileSpecs", "shortkeysPerChar", "pinnedUIItemsPerChar", "learnedStepLocks", "gpsChar", "gpsHearth" }) do
            local t = holder[field]
            if type(t) == "table" and t[old] ~= nil then
                local cur = t[new]
                -- A slot already under the full name wins, unless empty.
                if cur == nil or (type(cur) == "table" and next(cur) == nil) then
                    t[new] = type(t[old]) == "table" and CopyTable(t[old]) or t[old]
                end
            end
        end
    end
    -- Bags are rescanned at each login: the old slot is only a ghost now.
    local bags = type(db.bagCache) == "table" and db.bagCache.chars
    if type(bags) == "table" then bags[old] = nil end
    -- The gold ledger read the surname as the realm ("Test-Addons").
    local ledger = type(EasyFindDB) == "table" and EasyFindDB.charGold
    if type(ledger) == "table" and surname then
        ledger[first .. "-" .. surname] = nil
        ledger[full .. "-"] = nil
    end
end

-- A statistic's live value, plus whether anything is recorded. Shared so the
-- row that dims a "--" and the filter that hides one cannot disagree.
function ns.GetStatisticValue(statisticID)
    if not (statisticID and GetStatistic) then return nil, false end
    local ok, value = pcall(GetStatistic, statisticID)
    if not ok then return nil, false end
    return value, (value ~= nil and value ~= "" and value ~= "--")
end

-- Account bank holdings belong to the warband, not to any character. Resolved
-- lazily: these globals exist on a live client but not at file load in tests.
local warbandBankLabel
function ns.WarbandBankLabel()
    if warbandBankLabel then return warbandBankLabel end
    warbandBankLabel = _G["ACCOUNT_BANK_PANEL_TITLE"] or ns.L["BANK_WARBAND"]
    return warbandBankLabel
end

-- The player-facing name of a storage location, from its category.
function ns.StoredCategoryLabel(category)
    if category == "Warband" then return ns.WarbandBankLabel() end
    if category == "Bank" then return _G["BANK"] or "Bank" end
    return _G["BAGSLOT"] or "Bags"
end

-- "Bank: Alt (5), Otheralt" for a stored-item row. Built once per populate,
-- never in the render loop: the result is a pure function of the holder list,
-- which does not change between populates, and the loop runs for every visible
-- row on every keystroke.
function ns.StoredHoldersText(holders, category)
    if not holders or #holders == 0 then return nil end
    local parts = {}
    for i = 1, #holders do
        local holder = holders[i]
        local who = holder.name or "?"
        if (holder.count or 1) > 1 then
            parts[i] = sformat("%s (%d)", who, holder.count)
        else
            parts[i] = who
        end
    end
    return ns.StoredCategoryLabel(category) .. ": " .. tconcat(parts, ", ")
end

-- Size an icon texture to fit within `sz` while preserving `aspect` (width/height):
-- a tall icon (aspect < 1) keeps full height and narrows; a wide one keeps full
-- width and shortens. nil/0 aspect = square (the default for every other icon).
-- Point/LEFT anchoring is preserved -- only width/height change.
function ns.SizeIconAspect(tex, sz, aspect)
    if aspect and aspect > 0 and aspect < 1 then
        tex:SetSize(sz * aspect, sz)
    elseif aspect and aspect > 1 then
        tex:SetSize(sz, sz / aspect)
    else
        tex:SetSize(sz, sz)
    end
end

-- Achievement status labels. Strings only: ACHIEVEMENT_FILTER_EARNED
-- is the number 3 and printed as "3".
local function StringGlobal(key, fallback)
    local v = _G[key]
    return (type(v) == "string" and v ~= "") and v or fallback
end
ns.ACH_LABEL_EARNED = StringGlobal("EARNED",
    StringGlobal("ACHIEVEMENTFRAME_FILTER_COMPLETED", StringGlobal("COMPLETE", "Earned")))
ns.ACH_LABEL_INCOMPLETE = StringGlobal("INCOMPLETE",
    StringGlobal("ACHIEVEMENTFRAME_FILTER_INCOMPLETE", "Incomplete"))
-- Minimal scrollbar geometry, shared so surfaces that must clear the
-- scrollbar lane (row hover wash) derive from the same numbers.
ns.SCROLLBAR_THUMB_W = 3
ns.SCROLLBAR_EDGE_INSET = 4
ns.SEARCH_WINDOW_FILL_COLOR = {0.052, 0.052, 0.060}
ns.TEXT_PRIMARY = {1.00, 0.97, 0.86}
ns.TEXT_BODY = {0.78, 0.78, 0.80}
ns.TEXT_DIM = {0.55, 0.55, 0.58}
ns.TEXT_ASIDE = {0.56, 0.74, 0.82}   -- an aside among steps (advice), apart from the done gray
-- One look for a search box's hint: the lens and the placeholder in the
-- same gray, no shadow to smear the text on a dark inset.
ns.SEARCH_HINT_COLOR = { 0.66, 0.66, 0.70 }
function Utils.StyleSearchHint(placeholder, icon)
    local c = ns.SEARCH_HINT_COLOR
    if placeholder then
        placeholder:SetTextColor(c[1], c[2], c[3], 1)
        placeholder:SetShadowColor(0, 0, 0, 0)
    end
    if icon then
        icon:SetVertexColor(c[1], c[2], c[3], 1)
        icon:SetAlpha(1)
    end
end
-- "Copied" confirmation green, shared by the calculator card and the
-- copy-row hints.
ns.COPIED_COLOR = {0.48, 1.0, 0.62}
-- Snippet category glyph: shipped white line-art in the app-icon style
-- (chat/notes), tintable, immune to Blizzard sprite-sheet reshuffles.
-- Filter row and result rows share it.
ns.SNIPPET_ICON_TEX    = "Interface\\AddOns\\EasyFind\\textures\\snippet-icon"
ns.CLIPBOARD_ICON_TEX  = "Interface\\AddOns\\EasyFind\\textures\\clipboard-icon"
ns.CLIPBOARD_ICON_COORDS = { 0, 1, 0, 1 }
-- GPS extension glyph: a map pin in the same white line-art family.
ns.GPS_ICON_TEX        = "Interface\\AddOns\\EasyFind\\textures\\gps-icon"
ns.NOTES_ICON_TEX      = "Interface\\AddOns\\EasyFind\\textures\\notes-icon"
ns.CHAT_ICON_TEX       = "Interface\\AddOns\\EasyFind\\textures\\chat-icon"
ns.QUICKLIST_ICON_TEX  = "Interface\\AddOns\\EasyFind\\textures\\quicklists-icon"
ns.NOTES_ICON_COORDS   = { 0, 1, 0, 1 }
ns.EXTENSIONS_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\apps-icon"
ns.CALCULATOR_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\calculator-icon"
ns.ICON_SEARCH_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\icon-search-icon"
-- Sort glyph (bars shrinking downward plus a down arrow = descending);
-- flip the tex coords vertically for ascending.
ns.SORT_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\sort-icon"
ns.COG_ICON_TEX = "Interface\\AddOns\\EasyFind\\textures\\cog-icon"
ns.SNIPPET_ICON_COORDS = { 0, 1, 0, 1 }
-- One chat line's character budget; snippet bodies cap here so an
-- expansion can never overflow a single message.
ns.CHAT_MESSAGE_MAX_CHARS = 255
-- Cool blue-gray fills so interactive buttons read as such against the
-- neutral near-black panels (color as affordance, not brightness).
ns.BTN_FILL_NORMAL = {0.160, 0.190, 0.250}
ns.BTN_FILL_HOVER = {0.220, 0.270, 0.340}
ns.BTN_FILL_PRESSED = {0.120, 0.140, 0.190}
ns.SECTION_TABLE_FILL = {0.075, 0.075, 0.085, 0.92}
ns.BTN_FILL_DISABLED = {0.080, 0.090, 0.110}
-- Live control-accent and sidebar-nav fills, mutated in place by
-- ApplyUITheme like the BTN fills above (paint-time reads follow themes).
ns.CONTROL_ACCENT = {0.17, 0.48, 0.72}
ns.NAV_SELECTED_FILL = {0.16, 0.19, 0.25, 0.95}
ns.NAV_HOVER_FILL = {0.12, 0.14, 0.19, 0.85}
ns.PANEL_CARD_FILL = {0.05, 0.05, 0.06}
ns.EDITBOX_INSET_FILL = {0.02, 0.02, 0.03}
-- Hover wash color for rows and menu rows on every theme except Black
-- (which keeps the classic additive gold glow): the window fill nudged
-- toward the main text color, which darkens light fills and lightens
-- dark ones. Returns nil when the glow should be used instead.
-- One color rule for chrome-tinted glyphs (the calculator icon in results
-- rows, the apps menu, and the popup; the apps 3x3 dots follow the same
-- source): the theme's chrome-glyph color, gold when the theme has none.
function ns.ChromeGlyphColor()
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    return (theme and theme.chromeGlyph) or ns.GOLD_COLOR or { 1.0, 0.82, 0.0 }
end

-- ADD brightens a glyph on dark fills; light themes, and themes whose glyph
-- color must read exactly (flatGlyphs), blend normally.
function ns.ChromeGlyphBlend(theme)
    theme = theme or (ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme())
    return (theme and (theme.lightTheme or theme.flatGlyphs)) and "BLEND" or "ADD"
end

function ns.RowWashColor()
    local pal = ns.ACTIVE_UI_PALETTE
    if not pal or (ns.UI_THEME_PALETTES and pal == ns.UI_THEME_PALETTES.Black) then return nil end
    -- A studio theme can pin the hover wash outright.
    if pal.rowHover then
        return pal.rowHover[1], pal.rowHover[2], pal.rowHover[3]
    end
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    local leaf = theme and theme.leafColor
    if not leaf then return nil end
    local windowFill = ns.SEARCH_WINDOW_FILL_COLOR
    local f = 0.24
    return windowFill[1] + (leaf[1] - windowFill[1]) * f,
        windowFill[2] + (leaf[2] - windowFill[2]) * f,
        windowFill[3] + (leaf[3] - windowFill[3]) * f
end

-- Row washes sit a step below the window itself so the hover/selection
-- highlight never reads as fully solid: even at 100% window opacity the
-- wash paints at this fraction of it, then scales down with the setting.
ns.ROW_WASH_ALPHA_SCALE = 0.80
function ns.RowWashAlpha()
    return ns.GetSearchWindowAlpha() * ns.ROW_WASH_ALPHA_SCALE
end

-- Identity map for paint-time tagging: painters that fill a control from
-- one of the live tables record WHICH table, so the theme retint walker
-- repaints from the same table instead of guessing by color (color
-- snapshots break when a control is first seen under a non-default theme).
ns.LIVE_FILL_NAMES = {
    [ns.BTN_FILL_NORMAL] = "BTN_FILL_NORMAL",
    [ns.BTN_FILL_HOVER] = "BTN_FILL_HOVER",
    [ns.BTN_FILL_PRESSED] = "BTN_FILL_PRESSED",
    [ns.BTN_FILL_DISABLED] = "BTN_FILL_DISABLED",
    [ns.SECTION_TABLE_FILL] = "SECTION_TABLE_FILL",
    [ns.CONTROL_ACCENT] = "CONTROL_ACCENT",
    [ns.NAV_SELECTED_FILL] = "NAV_SELECTED_FILL",
    [ns.NAV_HOVER_FILL] = "NAV_HOVER_FILL",
    [ns.PANEL_CARD_FILL] = "PANEL_CARD_FILL",
    [ns.EDITBOX_INSET_FILL] = "EDITBOX_INSET_FILL",
    [ns.SEARCH_WINDOW_FILL_COLOR] = "SEARCH_WINDOW_FILL_COLOR",
}
ns.LINK_COLOR = {0.44, 0.84, 1.0}
ns.LINK_HOVER = {0.72, 0.94, 1.0}
ns.LINK_GLOW_COLOR = {0.3, 0.85, 1.0, 0.7}
ns.SEARCHBAR_HEIGHT = 30
ns.RESULT_ROWS_MIN = 1
ns.RESULT_ROWS_MAX = 8
ns.SEARCHBAR_FILL = 0.55
ns.SEARCHBAR_ICON_SCALE = 0.9
-- How much smaller the corner update notice runs than the bar's own font,
-- and how far its lower line clears the bar's bottom edge.
ns.UPDATE_NOTICE_FONT_SCALE = 0.85
ns.UPDATE_NOTICE_BOTTOM_PAD = 6
-- Gap between the last result row and the notice; deliberately slim.
ns.UPDATE_NOTICE_TOP_PAD = 1
-- The options window: its height grows by one 28px settings row each time
-- its tabs run out of room.
ns.OPTIONS_WINDOW_W = 634
-- Room for the tabs at the window's text, 2 pt over the game's (Classic chrome's too).
ns.OPTIONS_WINDOW_H = 520
ns.DEFAULT_FONT_SIZE = 0.9
ns.CLEAR_BTN_SIZE = 12
-- Blizzard's standard round-crop mask, used wherever a square icon has to
-- render as a circle (fade masks, the gear-set spec badge).
ns.PORTRAIT_ALPHA_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local EasyFindSearchFont = CreateFont("EasyFindSearchFont")
local baseFont = Game15Font_Shadow or GameFontNormal
EasyFindSearchFont:CopyFontObject(baseFont)
EasyFindSearchFont:SetFont((baseFont:GetFont()), 12, select(3, baseFont:GetFont()))
ns.SEARCHBAR_FONT = "EasyFindSearchFont"

local SEARCH_TEX_FILL = "Interface\\AddOns\\EasyFind\\textures\\SearchBarFill"
local SEARCH_TEX_BORDER = "Interface\\AddOns\\EasyFind\\textures\\SearchBarBorder"
local CLEAR_BTN_TEX = "Interface\\AddOns\\EasyFind\\textures\\clear-button"
-- 9-slice cap = outer 37.5% of texture: curve lives in outer 64 px,
-- followed by 32 px flat that buffers the cap/mid join. Cutting in the
-- flat region lets cap and mid (rendered at different scales) join
-- without a visible kink at the curve's tangent point.
local CAP_TEX_RATIO = 0.375
local CAP_DISPLAY_RATIO = 0.75
local TC_LEFT  = {0, CAP_TEX_RATIO, 0, 1}
local TC_MID   = {CAP_TEX_RATIO, 1 - CAP_TEX_RATIO, 0, 1}
local TC_RIGHT = {1 - CAP_TEX_RATIO, 1, 0, 1}
local BORDER_R, BORDER_G, BORDER_B = 0.42, 0.42, 0.42

local function CreateTexPart(frame, layer, texPath, tc, vertR, vertG, vertB, vertA)
    local tex = frame:CreateTexture(nil, layer)
    tex:SetTexture(texPath)
    tex:SetTexCoord(unpack(tc))
    tex:SetVertexColor(vertR, vertG, vertB, vertA)
    return tex
end

local function ApplyCapWidths(frame)
    if not frame.searchBorder then return end
    local h = frame:GetHeight() or 0
    if h <= 0 then return end
    local capW = h * CAP_DISPLAY_RATIO
    local sb = frame.searchBorder
    sb.fillLeft:SetWidth(capW)
    sb.fillRight:SetWidth(capW)
end

function ns.CreateSearchBorder(frame)
    local fillLeft = CreateTexPart(frame, "BACKGROUND", SEARCH_TEX_FILL, TC_LEFT, 0, 0, 0, 1)
    fillLeft:SetPoint("TOPLEFT")
    fillLeft:SetPoint("BOTTOMLEFT")

    local fillRight = CreateTexPart(frame, "BACKGROUND", SEARCH_TEX_FILL, TC_RIGHT, 0, 0, 0, 1)
    fillRight:SetPoint("TOPRIGHT")
    fillRight:SetPoint("BOTTOMRIGHT")

    local fillMid = CreateTexPart(frame, "BACKGROUND", SEARCH_TEX_FILL, TC_MID, 0, 0, 0, 1)
    fillMid:SetPoint("TOPLEFT", fillLeft, "TOPRIGHT")
    fillMid:SetPoint("BOTTOMRIGHT", fillRight, "BOTTOMLEFT")

    local borderLeft = CreateTexPart(frame, "ARTWORK", SEARCH_TEX_BORDER, TC_LEFT, BORDER_R, BORDER_G, BORDER_B, 1)
    borderLeft:SetAllPoints(fillLeft)

    local borderRight = CreateTexPart(frame, "ARTWORK", SEARCH_TEX_BORDER, TC_RIGHT, BORDER_R, BORDER_G, BORDER_B, 1)
    borderRight:SetAllPoints(fillRight)

    local borderMid = CreateTexPart(frame, "ARTWORK", SEARCH_TEX_BORDER, TC_MID, BORDER_R, BORDER_G, BORDER_B, 1)
    borderMid:SetAllPoints(fillMid)

    frame.searchBorder = {
        fillLeft = fillLeft, fillMid = fillMid, fillRight = fillRight,
        borderLeft = borderLeft, borderMid = borderMid, borderRight = borderRight,
    }
    frame:HookScript("OnSizeChanged", ApplyCapWidths)
    ApplyCapWidths(frame)
end

-- 9-slice rounded-rect: corners stay fixed size (= bar height / 2 so they
-- match the bar's pill caps); edges stretch. When container height equals
-- 2 * cornerSize, the silhouette collapses to a horizontal pill.
local COMBINED_TEX_FILL   = "Interface\\AddOns\\EasyFind\\textures\\CombinedFill"
local COMBINED_TEX_BORDER = "Interface\\AddOns\\EasyFind\\textures\\CombinedBorder"
local CR = 0.25

local TC9 = {
    tl = {0,        CR,     0,        CR    },
    tm = {CR,       1 - CR, 0,        CR    },
    tr = {1 - CR,   1,      0,        CR    },
    ml = {0,        CR,     CR,       1 - CR},
    mm = {CR,       1 - CR, CR,       1 - CR},
    mr = {1 - CR,   1,      CR,       1 - CR},
    bl = {0,        CR,     1 - CR,   1     },
    bm = {CR,       1 - CR, 1 - CR,   1     },
    br = {1 - CR,   1,      1 - CR,   1     },
}

local function CreateNineSlice(frame, layer, texPath, vertR, vertG, vertB, vertA)
    local nine = {}
    local function P(name)
        local t = frame:CreateTexture(nil, layer)
        t:SetTexture(texPath)
        t:SetTexCoord(unpack(TC9[name]))
        t:SetVertexColor(vertR, vertG, vertB, vertA)
        return t
    end
    nine.tl, nine.tm, nine.tr = P("tl"), P("tm"), P("tr")
    nine.ml, nine.mm, nine.mr = P("ml"), P("mm"), P("mr")
    nine.bl, nine.bm, nine.br = P("bl"), P("bm"), P("br")
    return nine
end

local function AnchorNineSlice(frame, n, cornerSize)
    n.tl:ClearAllPoints(); n.tl:SetPoint("TOPLEFT");     n.tl:SetSize(cornerSize, cornerSize)
    n.tr:ClearAllPoints(); n.tr:SetPoint("TOPRIGHT");    n.tr:SetSize(cornerSize, cornerSize)
    n.bl:ClearAllPoints(); n.bl:SetPoint("BOTTOMLEFT");  n.bl:SetSize(cornerSize, cornerSize)
    n.br:ClearAllPoints(); n.br:SetPoint("BOTTOMRIGHT"); n.br:SetSize(cornerSize, cornerSize)
    n.tm:ClearAllPoints()
    n.tm:SetPoint("TOPLEFT",  n.tl, "TOPRIGHT")
    n.tm:SetPoint("BOTTOMRIGHT", n.tr, "BOTTOMLEFT")
    n.bm:ClearAllPoints()
    n.bm:SetPoint("TOPLEFT",  n.bl, "TOPRIGHT")
    n.bm:SetPoint("BOTTOMRIGHT", n.br, "BOTTOMLEFT")
    n.ml:ClearAllPoints()
    n.ml:SetPoint("TOPLEFT",  n.tl, "BOTTOMLEFT")
    n.ml:SetPoint("BOTTOMRIGHT", n.bl, "TOPRIGHT")
    n.mr:ClearAllPoints()
    n.mr:SetPoint("TOPLEFT",  n.tr, "BOTTOMLEFT")
    n.mr:SetPoint("BOTTOMRIGHT", n.br, "TOPRIGHT")
    n.mm:ClearAllPoints()
    n.mm:SetPoint("TOPLEFT",  n.tl, "BOTTOMRIGHT")
    n.mm:SetPoint("BOTTOMRIGHT", n.br, "TOPLEFT")
end

-- An atlas shown as window art: at its own size (pageW x pageH units) when
-- given, cropped from the top left and larger only when the window outgrows
-- it; else fitted to the window's width, cropped from the top, stretched
-- only when the window is taller than the fitted image. Returns the
-- texcoord steps per UI unit across and down, as fractions.
local function AtlasSteps(info, w, h, pageW, pageH)
    if pageW and pageH and pageW > 0 and pageH > 0 then
        local k = mmax(1, w / pageW, h / pageH)
        return 1 / (pageW * k), 1 / (pageH * k)
    end
    local shownH = w * info.height / info.width
    if shownH < h then shownH = h end
    return 1 / w, 1 / shownH
end
local function AtlasU(info, f) return info.leftTexCoord + (info.rightTexCoord - info.leftTexCoord) * f end
local function AtlasV(info, f) return info.topTexCoord + (info.bottomTexCoord - info.topTexCoord) * f end

-- The WoW Forever skin: the spellbook frame's own bronze border (its
-- UI-Frame-Metal atlases, which the client serves as Forever art) around a
-- square window filled with the quest log background. Each piece is a crop
-- of that atlas at the spellbook's size: the chamfered corner, and the band
-- without the title strip or the soft inner shadow. Surfaces opt in with
-- frame._efForeverSurface.
local FOREVER = {
    fillAtlas = "QuestLog-main-background",
    -- name, then the crop as fractions of the piece: left, right, top, bottom.
    pieces = {
        tl = { "UI-Frame-Metal-CornerTopLeft",     20 / 190, 50 / 190, 21 / 190, 38 / 190 },
        tr = { "UI-Frame-Metal-CornerTopRight",   160 / 190, 1,        21 / 190, 38 / 190 },
        bl = { "UI-Frame-Metal-CornerBottomLeft",  20 / 190, 50 / 190, 173 / 200, 197 / 200 },
        br = { "UI-Frame-Metal-CornerBottomRight", 160 / 190, 1,       173 / 200, 197 / 200 },
        top = { "_UI-Frame-Metal-EdgeTop",         0, 1, 21 / 190, 38 / 190 },
        bottom = { "_UI-Frame-Metal-EdgeBottom",   0, 1, 173 / 200, 197 / 200 },
        left = { "!UI-Frame-Metal-EdgeLeft",       20 / 190, 37 / 190, 0, 1 },
        right = { "!UI-Frame-Metal-EdgeRight",    173 / 190, 1,        0, 1 },
    },
    -- Art pixels (the pieces are 2x art): crop sizes, and how far each crop
    -- runs past the window, whose edge is the band's inner edge (rows and
    -- scroll bars run to it clear of the metal); the fill reaches 4 under it.
    px = { cornerW = 30, topH = 17, bottomH = 24, sideW = 17, edgeLen = 256,
           outLeft = 17, outRight = 17, outTop = 17, outBottom = 24, fillIn = -4 },
    unit = 0.5,        -- UI units per art pixel: the spellbook's own size
    level = 12,        -- the border sits over rows and bar content
    dividerInset = -1.5,  -- the divider runs under the band's inner edge
}
ns.FOREVER_BRONZE = { 0.78, 0.55, 0.30, 0.95 }

-- The quest log page as the client serves it: its 2x art where there is one
-- (sharp on any screen), and how many 2x art pixels one of its pixels is.
-- Without the client's page (the classic clients): our 1x copy of it.
FOREVER.SHIPPED_PAGE = { file = "Interface\\AddOns\\EasyFind\\textures\\QuestPaper", width = 307, height = 510,
    leftTexCoord = 0, rightTexCoord = 307 / 512, topTexCoord = 0, bottomTexCoord = 510 / 512 }
function FOREVER.Page()
    if C_Texture and C_Texture.GetAtlasInfo then
        for _, try in ipairs({ { "-2x", 1 }, { "", 2 } }) do
            local info = C_Texture.GetAtlasInfo(FOREVER.fillAtlas .. try[1])
            if info and info.file and (info.width or 0) > 0 and (info.height or 0) > 0 then return info, try[2] end
        end
    end
    return FOREVER.SHIPPED_PAGE, 2
end

function ns.IsForeverChrome()
    local p = ns.ACTIVE_UI_PALETTE
    return p ~= nil and p.chrome == "forever" and ns.FrameArtOn()
end
-- A theme with frame art of its own (Classic, Forever), drawn or not.
function ns.ThemeHasChrome()
    local p = ns.ACTIVE_UI_PALETTE
    return p ~= nil and (p.chrome == "classic" or p.chrome == "forever")
end

local LayoutForever, EnsureForever
do
    -- UI units per art pixel on this frame, so every surface wears the band
    -- at the spellbook's own size on screen (the filter menu is zoomed 1.5x).
    local function ForeverUnit(frame)
        local own = frame.GetEffectiveScale and frame:GetEffectiveScale()
        local ref = UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()
        if type(own) ~= "number" or type(ref) ~= "number" or own <= 0 or ref <= 0 then return FOREVER.unit end
        return FOREVER.unit * ref / own
    end
    FOREVER.UnitOf = ForeverUnit

    local function PlaceForever(frame, f, u)
        local px, p = FOREVER.px, f.pieces
        p.tl:SetSize(px.cornerW * u, px.topH * u)
        p.tl:SetPoint("TOPLEFT", frame, "TOPLEFT", -px.outLeft * u, px.outTop * u)
        p.tr:SetSize(px.cornerW * u, px.topH * u)
        p.tr:SetPoint("TOPRIGHT", frame, "TOPRIGHT", px.outRight * u, px.outTop * u)
        p.bl:SetSize(px.cornerW * u, px.bottomH * u)
        p.bl:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", -px.outLeft * u, -px.outBottom * u)
        p.br:SetSize(px.cornerW * u, px.bottomH * u)
        p.br:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", px.outRight * u, -px.outBottom * u)
        p.left:SetWidth(px.sideW * u)
        p.right:SetWidth(px.sideW * u)
        -- The fill runs under the metal, short of the chamfer's cut.
        local inset = px.fillIn * u
        f.fill:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
        f.fill:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
        f.u = u
    end

    LayoutForever = function(frame)
        local f = frame._efForever
        if not (f and frame._efForeverOn) then return end
        local u, px = ForeverUnit(frame), FOREVER.px
        if f.u ~= u then PlaceForever(frame, f, u) end
        local fw, fh = frame:GetWidth() or 0, frame:GetHeight() or 0
        local inset = px.fillIn * u
        local w, h = fw - 2 * inset, fh - 2 * inset
        if w <= 0 or h <= 0 then return end
        f.border:SetFrameLevel(frame:GetFrameLevel() + FOREVER.level)
        -- Edges tile at the art's own length.
        local tile = px.edgeLen * u
        local across = mmax(fw + (px.outLeft + px.outRight - 2 * px.cornerW) * u, 1) / tile
        local down = mmax(fh + (px.outTop + px.outBottom - px.topH - px.bottomH) * u, 1) / tile
        local p = f.pieces
        p.top:SetTexCoord(0, across, p.top._efV0, p.top._efV1)
        p.bottom:SetTexCoord(0, across, p.bottom._efV0, p.bottom._efV1)
        p.left:SetTexCoord(p.left._efU0, p.left._efU1, 0, down)
        p.right:SetTexCoord(p.right._efU0, p.right._efU1, 0, down)
        -- The page at its own size, at the band's scale, cropped.
        local info = f.info
        local sx, sy = AtlasSteps(info, w, h, info.width * f.pageScale * u, info.height * f.pageScale * u)
        f.fill:SetTexCoord(AtlasU(info, 0), AtlasU(info, w * sx), AtlasV(info, 0), AtlasV(info, h * sy))
    end

    -- The spellbook's pieces as the Forever client serves them; any other
    -- client (whose art under those names is not Forever's) wears our copy
    -- of that art, textures/ForeverBand*, so the frame is the same everywhere.
    local SHIPPED = "Interface\\AddOns\\EasyFind\\textures\\ForeverBand"
    local function Shipped(name, w, h, u1, v1, u0, v0)
        return { file = SHIPPED .. name, width = w, height = h, shipped = true,
                 leftTexCoord = u0 or 0, rightTexCoord = u1, topTexCoord = v0 or 0, bottomTexCoord = v1 }
    end
    local function PieceInfo()
        if C_Texture and C_Texture.GetAtlasInfo then
            local out = {}
            for key, def in pairs(FOREVER.pieces) do
                local info = C_Texture.GetAtlasInfo(def[1])
                if not (info and info.file and (info.width or 0) > 0 and (info.height or 0) > 0) then
                    out = nil
                    break
                end
                out[key] = info
            end
            -- Forever's band art is wider than tall; the other clients' is not.
            if out and out.bottom.width > out.bottom.height then return out end
        end
        return {
            top = Shipped("Top", 256, 17, 1, 17 / 32), bottom = Shipped("Bottom", 256, 24, 1, 24 / 32),
            left = Shipped("Left", 17, 256, 17 / 32, 1), right = Shipped("Right", 17, 256, 17 / 32, 1),
            tl = Shipped("Corners", 30, 17, 30 / 64, 17 / 64), tr = Shipped("Corners", 30, 17, 62 / 64, 17 / 64, 32 / 64, 0),
            bl = Shipped("Corners", 30, 24, 30 / 64, 56 / 64, 0, 32 / 64),
            br = Shipped("Corners", 30, 24, 62 / 64, 56 / 64, 32 / 64, 32 / 64),
        }
    end

    -- A shipped piece is the crop already; the client's atlas needs it cut.
    local FULL_CROP = { false, 0, 1, 0, 1 }
    local function Piece(holder, key, info, tiled)
        local def = info.shipped and FULL_CROP or FOREVER.pieces[key]
        local t = holder:CreateTexture(nil, "OVERLAY")
        local u0, u1 = AtlasU(info, def[2]), AtlasU(info, def[3])
        local v0, v1 = AtlasV(info, def[4]), AtlasV(info, def[5])
        if tiled == "h" then
            if not t:SetTexture(info.file, "REPEAT", "CLAMP") then return nil end
        elseif tiled == "v" then
            if not t:SetTexture(info.file, "CLAMP", "REPEAT") then return nil end
        else
            if not t:SetTexture(info.file) then return nil end
            t:SetTexCoord(u0, u1, v0, v1)
        end
        t._efU0, t._efU1, t._efV0, t._efV1 = u0, u1, v0, v1
        return t
    end

    -- Nil when the client lacks the art: the rounded look stays.
    EnsureForever = function(frame)
        if frame._efForever or frame._efForeverFailed then return frame._efForever end
        frame._efForeverFailed = true
        local fillInfo, pageScale = FOREVER.Page()
        if not fillInfo then return nil end
        local infos = PieceInfo()
        if not infos then return nil end
        local border = CreateFrame("Frame", nil, frame)
        border:SetAllPoints(frame)
        border:Hide()
        local p = {}
        for key in pairs(FOREVER.pieces) do
            local tiled = (key == "top" or key == "bottom") and "h" or (key == "left" or key == "right") and "v" or nil
            p[key] = Piece(border, key, infos[key], tiled)
            if not p[key] then return nil end
        end
        p.top:SetPoint("TOPLEFT", p.tl, "TOPRIGHT")
        p.top:SetPoint("BOTTOMRIGHT", p.tr, "BOTTOMLEFT")
        p.bottom:SetPoint("TOPLEFT", p.bl, "TOPRIGHT")
        p.bottom:SetPoint("BOTTOMRIGHT", p.br, "BOTTOMLEFT")
        p.left:SetPoint("TOPLEFT", p.tl, "BOTTOMLEFT")
        p.left:SetPoint("BOTTOMLEFT", p.bl, "TOPLEFT")
        p.right:SetPoint("TOPRIGHT", p.tr, "BOTTOMRIGHT")
        p.right:SetPoint("BOTTOMRIGHT", p.br, "TOPRIGHT")
        local fill = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
        if not fill:SetTexture(fillInfo.file) then return nil end
        fill:Hide()
        local f = { border = border, pieces = p, fill = fill, info = fillInfo, pageScale = pageScale }
        PlaceForever(frame, f, ForeverUnit(frame))
        frame._efForever = f
        frame._efForeverFailed = nil
        frame:HookScript("OnSizeChanged", LayoutForever)
        return f
    end
end

-- Shows the Forever pieces with the panel; the art is the border here.
local function ShowForeverPieces(frame)
    local f = frame._efForever
    if not f then return end
    local panel = frame._efPanelWanted ~= false
    f.fill:SetShown(panel)
    f.border:SetShown(panel)
end

-- The 1.x talent trees a Classic window may wear over its marble, as their
-- tabs list them; drawn at their own size from the top right, cropped.
ns.CLASSIC_TREES = { "DruidBalance", "DruidFeralCombat", "DruidRestoration", "HunterBeastMastery", "HunterMarksmanship",
    "HunterSurvival", "MageArcane", "MageFire", "MageFrost", "PaladinHoly", "PaladinProtection", "PaladinCombat",
    "PriestDiscipline", "PriestHoly", "PriestShadow", "RogueAssassination", "RogueCombat", "RogueSubtlety",
    "ShamanElementalCombat", "ShamanEnhancement", "ShamanRestoration", "WarlockCurses", "WarlockSummoning",
    "WarlockDestruction", "WarriorArms", "WarriorFury", "WarriorProtection" }
local TREE_ART = "Interface\\TalentFrame\\"
-- The painted part is 300 x 331 of the four files; their right 20 columns are blank.
local TREE_W, TREE_H, TREE_BLANK_RIGHT = 300, 331, 20
local TREE_PIECES = {
    { key = "TopRight", w = 64, h = 256 }, { key = "TopLeft", w = 256, h = 256 },
    { key = "BottomRight", w = 64, h = 75, v1 = 75 / 128 }, { key = "BottomLeft", w = 256, h = 75, v1 = 75 / 128 },
}

local function PlaceTree(art)
    local w, h = art.clip:GetWidth() or 0, art.clip:GetHeight() or 0
    local k = mmax(1, w / TREE_W, h / TREE_H)
    for i, piece in ipairs(TREE_PIECES) do art.tex[i]:SetSize(piece.w * k, piece.h * k) end
    art.tex[1]:ClearAllPoints()
    art.tex[1]:SetPoint("TOPRIGHT", art.clip, "TOPRIGHT", TREE_BLANK_RIGHT * k, 0)
end

-- The tree's own strength, picked in settings.
function ns.ClassicArtAlpha()
    local db = EasyFind and EasyFind.db
    return db and db.classicArtAlpha or 1
end

-- A pane inside a window that wears a tree: its marble would hide the art.
function ns.OverTree(frame)
    local db = EasyFind and EasyFind.db
    local name = db and db.classicArt
    if not name or name == "marble" or frame._efClassicStyle ~= "thin" then return false end
    local anc = frame:GetParent()
    while anc do
        local host = anc._efTreeHost or anc
        if host._efClassicStyle == "dialog" or host._efWearsTree then return true end
        anc = anc:GetParent()
    end
    return false
end

-- A window or the search bar wearing a picked tree: the tree is its whole
-- background, none of the marble.
function ns.ShowsTree(frame)
    local db = EasyFind and EasyFind.db
    local name = db and db.classicArt
    return name ~= nil and name ~= "marble" and (frame._efClassicStyle == "dialog" or frame._efWearsTree == true)
end

-- The picked tree inside the frame's border, or none for the marble alone.
local function DressTree(frame, inset, alpha)
    local db = EasyFind and EasyFind.db
    local name = db and db.classicArt
    if name == "marble" then name = nil end
    local art = frame._efTree
    if not name then
        if art then art.clip:Hide() end
        return
    end
    if not art then
        local clip = CreateFrame("Frame", nil, frame)
        clip:SetFrameLevel(frame:GetFrameLevel())
        clip:SetClipsChildren(true)
        local tex = {}
        for i, piece in ipairs(TREE_PIECES) do
            tex[i] = clip:CreateTexture(nil, "BACKGROUND")
            tex[i]:SetTexCoord(0, 1, 0, piece.v1 or 1)
        end
        tex[2]:SetPoint("TOPRIGHT", tex[1], "TOPLEFT")
        tex[3]:SetPoint("TOPRIGHT", tex[1], "BOTTOMRIGHT")
        tex[4]:SetPoint("TOPRIGHT", tex[3], "TOPLEFT")
        art = { clip = clip, tex = tex }
        frame._efTree = art
        clip:SetScript("OnSizeChanged", function() PlaceTree(art) end)
    end
    art.clip:ClearAllPoints()
    art.clip:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
    art.clip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
    if art.name ~= name then
        art.name = name
        for i, piece in ipairs(TREE_PIECES) do art.tex[i]:SetTexture(TREE_ART .. name .. "-" .. piece.key) end
    end
    art.clip:SetAlpha(alpha * ns.ClassicArtAlpha())
    PlaceTree(art)
    art.clip:Show()
end

do
    -- The bar, results and menus wear the art on a frame CLASSIC_OUTSET
    -- outside their own, under them; a band inside a window's border
    -- (_efClassicInside) and the windows keep it on themselves.
    local function ClassicHost(frame, want)
        local back = frame._efClassicBack
        if want ~= "tooltip" or frame._efClassicInside then
            if back then back:Hide() end
            return frame
        end
        if not back then
            back = CreateFrame("Frame", nil, frame, "BackdropTemplate")
            back:SetPoint("TOPLEFT", frame, "TOPLEFT", -ns.CLASSIC_OUTSET, ns.CLASSIC_OUTSET)
            back:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", ns.CLASSIC_OUTSET, -ns.CLASSIC_OUTSET)
            frame._efClassicBack = back
        end
        back:SetFrameLevel(math.max(0, frame:GetFrameLevel() - 1))
        back:Show()
        return back
    end
    ns.ClassicHost = function(frame) return frame._efClassicBack and frame._efClassicBack:IsShown() and frame._efClassicBack or frame end

    local function DressClassic(frame)
        local style = frame._efClassicStyle
        local want = (style == "dialog" or style == "thin") and style or "tooltip"
        local host = ClassicHost(frame, want)
        if not host.SetBackdrop and BackdropTemplateMixin then
            Mixin(host, BackdropTemplateMixin)
            if host.OnBackdropLoaded then host:OnBackdropLoaded() end
            -- The template's own resize script retiles the marble; mixed in
            -- by hand, a frame sized by its anchors later wore it stretched.
            if host.OnBackdropSizeChanged then host:HookScript("OnSizeChanged", host.OnBackdropSizeChanged) end
        end
        if not host.SetBackdrop then return false end
        local backdrop = (want == "dialog" and ns.CLASSIC_DIALOG) or (want == "thin" and ns.CLASSIC_THIN) or ns.CLASSIC_BACKDROP
        if frame._efClassicChrome ~= want or frame._efClassicHost ~= host then
            if host ~= frame and frame.SetBackdrop then frame:SetBackdrop(nil) end
            host:SetBackdrop(backdrop)
            frame._efClassicChrome, frame._efClassicHost = want, host
        end
        -- The stone is its own color; only the window opacity applies.
        local alpha = frame._efClassicAlpha or frame._efBgAlpha or ns.GetSearchWindowAlpha()
        host:SetBackdropColor(1, 1, 1, (ns.OverTree(frame) or ns.ShowsTree(frame)) and 0 or alpha)
        host:SetBackdropBorderColor(1, 1, 1, 1)
        -- Windows and the search window may wear a talent tree; menus never.
        if want == "dialog" or frame._efWearsTree then
            DressTree(frame, backdrop.insets.left - (host ~= frame and ns.CLASSIC_OUTSET or 0), alpha)
        end
        return true
    end

    -- One owner for a surface's frame art: the Forever border or the Classic
    -- frames while the window border option is on, else the rounded pieces
    -- as they were last asked to show. True while a skin dresses the frame.
    -- Art drawn outside the frame takes the mouse as the frame does (or
    -- as _efBandDragOwner, the one that drags for it): a press there drags.
    local function ReachBand(frame, l, r, t, b)
        local owner = frame._efBandDragOwner or frame
        if not frame._efBandInsets then
            local il, ir, it, ib = owner:GetHitRectInsets()
            frame._efBandInsets = { il or 0, ir or 0, it or 0, ib or 0 }
        end
        owner:SetHitRectInsets(-l, -r, -t, -b)
    end
    local function DropBand(frame)
        if not frame._efBandInsets then return end
        (frame._efBandDragOwner or frame):SetHitRectInsets(unpack(frame._efBandInsets))
        frame._efBandInsets = nil
    end

    function ns.ApplySkin(frame)
        if not (frame and frame.combinedBorder) then return false end
        local want
        -- _efSkinOff: the frame wears another rim for now (the GPS pop-out's
        -- quest border). _efSkinForced: the theme's art whatever the frame
        -- art switch says (the pop-out's own iron border choice).
        if not frame._efSkinOff then
            local p = ns.ACTIVE_UI_PALETTE
            local chrome = p and p.chrome
            local art = ns.FrameArtOn() or frame._efSkinForced
            if frame._efForeverSurface and chrome == "forever" and art and EnsureForever(frame) then
                want = "forever"
            elseif frame._efClassicSurface and chrome == "classic" and art then
                want = "classic"
            end
        end
        local was = frame._efSkin
        if was == "forever" and want ~= "forever" then
            frame._efForeverOn = nil
            frame._efForever.fill:Hide()
            frame._efForever.border:Hide()
            DropBand(frame)
        elseif was == "classic" and want ~= "classic" then
            DropBand(frame)
            frame._efClassicChrome, frame._efClassicHost = nil, nil
            if frame.SetBackdrop then frame:SetBackdrop(nil) end
            if frame._efClassicBack then frame._efClassicBack:Hide() end
            if frame._efTree then frame._efTree.clip:Hide() end
        end
        if want == "classic" and not DressClassic(frame) then want = nil end
        frame._efSkin = want
        if want then
            for _, t in pairs(frame.combinedBorder.fill) do t:Hide() end
            for _, t in pairs(frame.combinedBorder.border) do t:Hide() end
            if frame._efArtCells then
                for _, cell in pairs(frame._efArtCells) do cell:Hide() end
            end
            if want == "forever" then
                local f = frame._efForever
                frame._efForeverOn = true
                f.fill:SetVertexColor(1, 1, 1, 1)
                f.fill:SetAlpha(frame._efBgAlpha or 1)
                LayoutForever(frame)
                ShowForeverPieces(frame)
                local u, px = f.u or FOREVER.unit, FOREVER.px
                ReachBand(frame, px.outLeft * u, px.outRight * u, px.outTop * u, px.outBottom * u)
            elseif frame._efClassicBack and frame._efClassicBack:IsShown() then
                local o = ns.CLASSIC_OUTSET
                ReachBand(frame, o, o, o, o)
            else
                DropBand(frame)
            end
            return true
        end
        if was then
            local panel = frame._efPanelWanted ~= false
            for _, t in pairs(frame.combinedBorder.fill) do t:SetShown(panel) end
            for _, t in pairs(frame.combinedBorder.border) do t:SetShown(panel and frame._efRingWanted ~= false) end
        end
        -- The Forever theme without its band: the line border in its bronze.
        if frame._efForeverSurface then
            local c = ns.ForeverLineColor()
            for _, t in pairs(frame.combinedBorder.border) do t:SetVertexColor(c[1], c[2], c[3], c[4]) end
        end
        return false
    end
end

-- A 1 px square outline in the border gray: small swatches, where the
-- rounded ring's corners read as a circle.
function ns.SquareOutline(frame)
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local edge = frame:CreateTexture(nil, "ARTWORK")
        edge:SetColorTexture(BORDER_R, BORDER_G, BORDER_B, 1)
        if side == "TOP" or side == "BOTTOM" then
            edge:SetHeight(1)
            edge:SetPoint(side .. "LEFT")
            edge:SetPoint(side .. "RIGHT")
        else
            edge:SetWidth(1)
            edge:SetPoint("TOP" .. side)
            edge:SetPoint("BOTTOM" .. side)
        end
    end
end

-- Whether the cursor is on a skinned frame or its art outside it: the hit
-- rect reaches the art, IsMouseOver reads the rect alone.
function ns.IsMouseOverWithBand(frame)
    if not (frame and frame.IsShown and frame:IsShown()) then return false end
    if frame:IsMouseOver() then return true end
    local back = frame._efClassicBack
    if back and back:IsShown() and back:IsMouseOver() then return true end
    if not frame._efForeverOn then return false end
    local f, px = frame._efForever, FOREVER.px
    local u = f and f.u or FOREVER.unit
    local l, r, t, b = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()
    local scale = frame:GetEffectiveScale()
    if not (l and r and t and b and scale and scale > 0) then return false end
    local x, y = GetCursorPosition()
    x, y = x / scale, y / scale
    return x >= l - px.outLeft * u and x <= r + px.outRight * u and y <= t + px.outTop * u and y >= b - px.outBottom * u
end

-- The line border's and divider's color on a surface made for the Forever
-- band: the theme's bronze under the Forever theme, else the usual gray.
do
    local LINE_GRAY = { BORDER_R, BORDER_G, BORDER_B, 1 }
    function ns.ForeverLineColor()
        local p = ns.ACTIVE_UI_PALETTE
        return (p and p.chrome == "forever") and ns.FOREVER_BRONZE or LINE_GRAY
    end
end

local function ApplyContainerCornerSize(frame)
    if not frame.combinedBorder then return end
    LayoutForever(frame)
    local h = frame.cbBarHeight or frame:GetHeight() or 0
    if h <= 0 then return end
    local cornerSize = h / 2
    AnchorNineSlice(frame, frame.combinedBorder.fill,   cornerSize)
    AnchorNineSlice(frame, frame.combinedBorder.border, cornerSize)
    if frame._efArtCells then
        AnchorNineSlice(frame, frame._efArtCells, cornerSize)
        if frame._efArtMasks then
            local d = cornerSize * 2
            for _, mask in pairs(frame._efArtMasks) do
                mask:SetSize(d, d)
            end
        end
        ns.UpdateThemeArtCrop(frame)
    end
    if ns.UpdateThemeFillGradient then
        ns.UpdateThemeFillGradient(frame)
    end
end

function ns.CreateRoundedRectBorder(frame)
    local fill   = CreateNineSlice(frame, "BACKGROUND", COMBINED_TEX_FILL,   0, 0, 0, 1)
    local border = CreateNineSlice(frame, "ARTWORK",    COMBINED_TEX_BORDER, BORDER_R, BORDER_G, BORDER_B, 1)
    frame.combinedBorder = { fill = fill, border = border }
    ApplyContainerCornerSize(frame)
    frame:HookScript("OnSizeChanged", ApplyContainerCornerSize)
end

-- A small rounded well with a crisp 1 px ring: a filled shape in the
-- ring's color, the fill drawn 1 px inside it. The ring art's line is 2 px
-- of a 256 px texture: scaled to corners under 16 px it draws under a
-- pixel, gone on the edges and broken on the corners (test_thin_rings).
-- radius: the outer corner. Paint it with ns.PaintRingedWell.
function ns.CreateRingedWell(frame, radius)
    local inset = CreateFrame("Frame", nil, frame)
    inset:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    inset:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    inset:SetFrameLevel(frame:GetFrameLevel() + 1)
    for _, shape in ipairs({ frame, inset }) do
        ns.CreateRoundedRectBorder(shape)
        ns.SetRoundedRectBorderEdgeShown(shape, false)
        ns.SetRoundedRectBorderBgAlpha(shape, 1)
    end
    ns.SetRoundedRectBarHeight(frame, radius * 2)
    ns.SetRoundedRectBarHeight(inset, (radius - 1) * 2)
    frame.ringInset = inset
    return inset
end

function ns.PaintRingedWell(frame, ring, fill)
    ns.SetRoundedRectFill(frame, ring[1], ring[2], ring[3], ring[4] or 1, true)
    ns.SetRoundedRectFill(frame.ringInset, fill[1], fill[2], fill[3], fill[4] or 1, true)
end

-- Corner radius tracks BAR height, not container height (which grows
-- when results open). Callers must pin it via this setter on creation
-- and again whenever fontSize / theme changes the bar's pixel height.
function ns.SetRoundedRectBarHeight(frame, h)
    frame.cbBarHeight = h
    ApplyContainerCornerSize(frame)
end

function ns.SetRoundedRectBorderShown(frame, shown)
    if not frame.combinedBorder then return end
    frame._efPanelWanted = shown and true or false
    frame._efRingWanted = frame._efPanelWanted
    if frame._efSkin then
        if frame._efSkin == "forever" then ShowForeverPieces(frame) end
        return
    end
    for _, t in pairs(frame.combinedBorder.fill)   do t:SetShown(shown) end
    for _, t in pairs(frame.combinedBorder.border) do t:SetShown(shown) end
end

-- Border RING only. SetRoundedRectBorderShown toggles fill AND ring, which
-- is panel on/off -- using it for "borderless" removed the background too.
function ns.SetRoundedRectRingShown(frame, shown)
    if not (frame.combinedBorder and frame.combinedBorder.border) then return end
    frame._efRingWanted = shown and true or false
    if frame._efSkin then return end
    for _, t in pairs(frame.combinedBorder.border) do t:SetShown(shown) end
end

function ns.SetRoundedRectBorderBgAlpha(frame, alpha)
    if not frame.combinedBorder then return end
    frame._efBgAlpha = alpha
    if frame._efForever then frame._efForever.fill:SetAlpha(alpha) end
    if frame._efSkin == "classic" then
        local marble = not (ns.OverTree(frame) or ns.ShowsTree(frame))
        ns.ClassicHost(frame):SetBackdropColor(1, 1, 1, marble and (frame._efClassicAlpha or alpha) or 0)
    end
    for _, t in pairs(frame.combinedBorder.fill) do t:SetAlpha(alpha) end
    if frame._efArtCells then
        for _, t in pairs(frame._efArtCells) do t:SetAlpha(alpha) end
    end
    -- Gradient fills carry their alpha inside the gradient colors
    -- (texture-level SetAlpha does not reach SetGradient vertex colors),
    -- so a gradient surface must re-derive its ramp with the new alpha.
    if frame._efThemeFillTarget and ns.UpdateThemeFillGradient then
        ns.UpdateThemeFillGradient(frame)
    end
end

function ns.SetRoundedRectBorderFillColor(frame, r, g, b, a)
    if not frame.combinedBorder then return end
    if ns.OwnFill then r, g, b = ns.OwnFill(frame, r, g, b) end
    for _, t in pairs(frame.combinedBorder.fill) do
        t:SetVertexColor(r, g, b, a or 1)
    end
    if frame._efRamp then ns.RampButtonFill(frame, r, g, b, a) end
end

-- Search bar visibility mode, ONE owner for the autoHide/smartShow pair.
-- Exactly one of the pair is true for the two legacy modes; both false is
-- Always Show (the legacy pre-mode encoding, so no migration is needed
-- and old consumers already fall through to a plain persistent Show).
-- Consumers must never write the pair directly.
ns.VISIBILITY_AUTO   = 0
ns.VISIBILITY_SMART  = 1
ns.VISIBILITY_ALWAYS = 2

function ns.GetVisibilityMode()
    local db = EasyFind and EasyFind.db
    if not db or db.autoHide then return ns.VISIBILITY_AUTO end
    if db.smartShow then return ns.VISIBILITY_SMART end
    return ns.VISIBILITY_ALWAYS
end

function ns.SetVisibilityMode(mode)
    local db = EasyFind and EasyFind.db
    if not db then return end
    db.autoHide  = mode == ns.VISIBILITY_AUTO
    db.smartShow = mode == ns.VISIBILITY_SMART
end

local function DisablePixelSnap(t)
    if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
    if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
end

-- A round dot: a flat color under the round mask, off the pixel grid so
-- every dot draws the same size at any scale (a snapped square drew one,
-- two or three pixels wide).
function Utils.CreateDot(parent, size, color, layer)
    local dot = parent:CreateTexture(nil, layer or "ARTWORK")
    dot:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    dot:SetSize(size, size)
    DisablePixelSnap(dot)
    local mask = parent:CreateMaskTexture()
    mask:SetTexture(ns.PORTRAIT_ALPHA_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(dot)
    dot:AddMaskTexture(mask)
    return dot
end

-- A drag grip's six dots: two columns of three, centered on the grip.
function Utils.AddGripDots(grip, color)
    for col = -1, 1, 2 do
        for k = -1, 1 do
            Utils.CreateDot(grip, 3, color):SetPoint("CENTER", grip, "CENTER", col * 2.5, k * 5)
        end
    end
end

-- Paint fill color AND alpha, plus optionally disable pixel snapping so
-- the texture renders at sub-pixel positions cleanly (used by buttons
-- and cards that get color-animated, where snap can cause shimmering).
do
    -- The live tables a fill can be painted from, the plain button first
    -- (the nav pills lift to the same color).
    local TAGGED_FILLS = { "BTN_FILL_NORMAL", "BTN_FILL_HOVER", "BTN_FILL_PRESSED", "BTN_FILL_DISABLED",
        "SECTION_TABLE_FILL", "PANEL_CARD_FILL", "EDITBOX_INSET_FILL", "CONTROL_ACCENT",
        "NAV_SELECTED_FILL", "NAV_HOVER_FILL" }

    -- A control in a window with its own look: a fill given as one of the
    -- shared roles (button, card, window...) is that role in its colors.
    function ns.OwnFill(frame, r, g, b)
        local set = ns.ThemeSetOf and ns.ThemeSetOf(frame)
        if not set or set.shared then return r, g, b end
        for i = 0, #TAGGED_FILLS do
            local role = i == 0 and "SEARCH_WINDOW_FILL_COLOR" or TAGGED_FILLS[i]
            local live, own = ns[role], set[role]
            if own and live and live[1] == r and live[2] == g and live[3] == b then
                return own[1], own[2], own[3]
            end
        end
        return r, g, b
    end

    function ns.SetRoundedRectFill(frame, r, g, b, a, snapOff)
        if not (frame and frame.combinedBorder and frame.combinedBorder.fill) then return end
        a = a or 1
        -- Painted from a live theme color: the theme change repaints it from
        -- that table (RetintControlFill); else it is classified there by color.
        local kind
        for i = 1, #TAGGED_FILLS do
            local live = ns[TAGGED_FILLS[i]]
            if live and live[1] == r and live[2] == g and live[3] == b then kind = TAGGED_FILLS[i] break end
        end
        frame._efControlFillKind = kind
        if kind then frame._efControlFillAlpha = a end
        r, g, b = ns.OwnFill(frame, r, g, b)
        for _, t in pairs(frame.combinedBorder.fill) do
            t:SetVertexColor(r, g, b, a)
            t:SetAlpha(a)
            if snapOff then DisablePixelSnap(t) end
        end
        if frame._efRamp then ns.RampButtonFill(frame, r, g, b, a) end
    end
end

-- The small settings cogwheel tucked into a button or a dialog corner
-- (export scope, snippet trigger). The caller anchors it and sets OnClick.
-- Cog buttons wear the theme's glyph color: dark on a light theme, white
-- otherwise; repainted at each theme change (RetintCogs).
do
    local cogs = setmetatable({}, { __mode = "k" })
    local function PaintCog(cog)
        local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
        local c = theme and theme.lightTheme and (theme.leafColor or theme.textFaint)
        if c then cog.tex:SetVertexColor(c[1], c[2], c[3], 1) else cog.tex:SetVertexColor(1, 1, 1, 1) end
    end
    function ns.RetintCogs()
        for cog in pairs(cogs) do PaintCog(cog) end
    end
    function ns.CreateCogButton(parent)
        local cog = CreateFrame("Button", nil, parent)
        cog:SetSize(18, 18)
        local tex = cog:CreateTexture(nil, "ARTWORK")
        tex:SetPoint("CENTER")
        tex:SetSize(15, 15)
        if ns.SETTING_ICON.atlas then
            tex:SetAtlas(ns.SETTING_ICON.atlas)
        else
            tex:SetTexture(ns.SETTING_ICON.tex)
            tex:SetDesaturated(true)
        end
        cog.tex = tex
        cog:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        cogs[cog] = true
        PaintCog(cog)
        return cog
    end
end

-- Panel text retint for light themes: fontstrings sitting DIRECTLY on
-- a wizard-glossed panel (titles, labels, hints) go dark; fontstrings
-- inside rounded-fill controls (button pills, table cards) keep their
-- authored light colors, since those fills stay dark on light themes.
-- Originals are snapshotted on first touch and restored on dark themes.
local function HasRoundedAncestor(region)
    local parent = region:GetParent()
    for _ = 1, 5 do
        if not parent then return false end
        if parent.combinedBorder then return true end
        parent = parent:GetParent()
    end
    return false
end

local function RetintFontString(fs, theme, shadowOnly)
    if not fs._efOrigTextColor then
        local r, g, b, a = fs:GetTextColor()
        fs._efOrigTextColor = { r, g, b, a }
        local sr, sg, sb, sa = fs:GetShadowColor()
        fs._efOrigShadow = { sr, sg, sb, sa }
    end
    -- Text inside rounded controls keeps its owned colors (the control
    -- painters manage them), but the font-object drop shadow still smears
    -- on light fills, so shadow treatment applies everywhere.
    -- _efOwnColor text likewise has a dedicated painter (row RefreshVisual,
    -- ApplyRowLabelColor): classification here would freeze whatever theme
    -- was active when the color snapshot was taken.
    -- No font shadow on either polarity: our text is flat everywhere.
    fs:SetShadowColor(0, 0, 0, 0)
    if shadowOnly or fs._efOwnColor then return end
    local orig = fs._efOrigTextColor
    -- Tagged link text follows the live link table on BOTH polarities;
    -- its build-time color is whatever theme was active then, so neither
    -- restore-to-original nor color classification can handle it.
    if fs._efLinkText then
        -- The link color of the window the retint walk is in.
        local link = Utils.retintLinkColor or ns.LINK_COLOR
        fs:SetTextColor(link[1], link[2], link[3], orig[4])
        return
    end
    if not theme.lightTheme then
        fs:SetTextColor(orig[1], orig[2], orig[3], orig[4])
        return
    end
    local r, g, b = orig[1], orig[2], orig[3]
    local lum = 0.3 * r + 0.5 * g + 0.2 * b
    if r >= 0.85 and b <= 0.45 then
        -- gold headings
        local c = theme.pathColorHover
        fs:SetTextColor(c[1], c[2], c[3], orig[4])
    elseif lum >= 0.7 then
        local c = theme.leafColor
        fs:SetTextColor(c[1], c[2], c[3], orig[4])
    elseif lum >= 0.35 then
        local c = theme.textFaint
        fs:SetTextColor(c[1], c[2], c[3], orig[4])
    else
        fs:SetTextColor(r, g, b, orig[4])
    end
end

-- Control fills painted once at creation (button pills, table cards,
-- search shells). The live ns.BTN_FILL_* / ns.SECTION_TABLE_FILL tables
-- are mutated per theme, which keeps every hover closure in sync, but
-- resting fills need this repaint. Frames whose snapshot matches one of
-- the canonical control colors follow that table; everything else
-- (gloss panels, custom fills) is left alone.
local CONTROL_FILL_CANON = {
    { canon = {0.160, 0.190, 0.250}, live = "BTN_FILL_NORMAL" },
    { canon = {0.120, 0.140, 0.190}, live = "BTN_FILL_PRESSED" },
    { canon = {0.075, 0.075, 0.085}, live = "SECTION_TABLE_FILL" },
}

local function RetintControlFill(frame)
    -- State-driven fills (sidebar nav pills) opt out: their resting colors
    -- collide with the canonical button fills, so classification would
    -- stamp button colors onto whatever state they held at first walk.
    if frame._efNoAutoRetint then return end
    if not (frame.combinedBorder and frame.combinedBorder.fill and frame.combinedBorder.fill.mm) then return end
    if frame._efControlFillKind == nil then
        local r, g, b = frame.combinedBorder.fill.mm:GetVertexColor()
        frame._efControlFillKind = false
        for i = 1, #CONTROL_FILL_CANON do
            local c = CONTROL_FILL_CANON[i].canon
            if math.abs(r - c[1]) < 0.03 and math.abs(g - c[2]) < 0.03 and math.abs(b - c[3]) < 0.03 then
                frame._efControlFillKind = CONTROL_FILL_CANON[i].live
                break
            end
        end
    end
    local kind = frame._efControlFillKind
    if not kind then return end
    local live = ns[kind]
    ns.SetRoundedRectFill(frame, live[1], live[2], live[3],
        frame._efControlFillAlpha or live[4] or 1, true)
end

-- Every per-frame step is pcall-isolated: one frame throwing must never
-- abort the sweep and leave everything after it in the walk order stale
-- (which shows up as an arbitrary-looking subset of controls not
-- retheming).
local function RetintWalk(frame, theme)
    pcall(RetintControlFill, frame)
    -- Controls that own a state painter repaint themselves from the live
    -- tables; classification heuristics can't know their current state.
    if frame.RefreshVisual then
        pcall(frame.RefreshVisual, frame)
    end
    if frame.GetRegions then
        for i = 1, select("#", frame:GetRegions()) do
            local region = select(i, frame:GetRegions())
            if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                pcall(RetintFontString, region, theme, HasRoundedAncestor(region))
            end
        end
    end
    if frame.GetChildren then
        for i = 1, select("#", frame:GetChildren()) do
            RetintWalk((select(i, frame:GetChildren())), theme)
        end
    end
end

function ns.RetintPanelText(root)
    if not root then return end
    local set = ns.ThemeSetOf and ns.ThemeSetOf(root)
    local theme = set and set.theme or (ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme())
    if not theme then return end
    Utils.retintLinkColor = set and set.LINK_COLOR
    RetintWalk(root, theme)
    Utils.retintLinkColor = nil
end

-- Our text carries no font shadow, on either polarity: the game's font
-- objects bring one, so every font string and edit box under a root is
-- flattened, now and again each time the root shows (rows made since).
function ns.StripShadows(f)
    if not f then return end
    if f.SetShadowColor then f:SetShadowColor(0, 0, 0, 0) end
    if f.GetRegions then
        for i = 1, select("#", f:GetRegions()) do
            local region = select(i, f:GetRegions())
            if region and region.SetShadowColor then region:SetShadowColor(0, 0, 0, 0) end
        end
    end
    if f.GetChildren then
        for i = 1, select("#", f:GetChildren()) do
            ns.StripShadows((select(i, f:GetChildren())))
        end
    end
end
function ns.FlatText(root)
    if not root then return end
    ns.StripShadows(root)
    if not root._efFlatHooked and root.HookScript then
        root._efFlatHooked = true
        root:HookScript("OnShow", ns.StripShadows)
    end
end
-- A glossed panel's text in the theme's colors, now and on each show.
function ns.ThemePanelText(root)
    if not (root and ns.RetintPanelText) then return end
    ns.RetintPanelText(root)
    if not root._efPanelTextHooked and root.HookScript then
        root._efPanelTextHooked = true
        root:HookScript("OnShow", ns.RetintPanelText)
    end
end
-- Every window of ours by its name, at a theme change and after login.
function ns.FlatTextEverywhere()
    if not EnumerateFrames then return end
    local f = EnumerateFrames()
    while f do
        -- Some frames answer GetName with a region of theirs: strings only.
        -- Ours are named EasyFind..., the notes companion's EasyNotes...
        local name = f.GetName and f:GetName()
        if type(name) == "string" and (name:sub(1, 8) == "EasyFind" or name:sub(1, 9) == "EasyNotes") then
            ns.FlatText(f)
            -- Glossed panels: their text goes dark on a light theme too.
            if name:sub(1, 9) == "EasyNotes" then ns.ThemePanelText(f) end
        end
        f = EnumerateFrames(f)
    end
end

-- Theme art overlay: the window is a VIEWPORT onto a big square image.
-- Nine art cells share the fill nine-slice geometry, but their texcoords
-- are computed from each cell's real pixel rect, so the image is cropped
-- to the frame (1:1, never stretched): the bar alone shows the top slice
-- and opening results reveals more of the same picture. Only the four
-- corner cells carry a mask (one each, under the per-texture mask cap)
-- to round the silhouette; edge and center cells are plain crops. An atlas
-- art (palette.fillAtlas) is fitted to the window width instead.
local ART_TEXTURE_SIZE = 1024

function ns.UpdateThemeArtCrop(frame)
    local cells = frame._efArtCells
    if not cells then return end
    local w = frame:GetWidth() or 0
    local fh = frame:GetHeight() or 0
    local barH = frame.cbBarHeight or fh
    if w <= 0 or fh <= 0 then return end
    local c = barH / 2
    local atlas = frame._efArtAtlas
    local tile = frame._efArtTile
    local sx, sy = 1 / (tile or ART_TEXTURE_SIZE), 1 / (tile or ART_TEXTURE_SIZE)
    if atlas then
        local scale = frame._efArtPageScale
        local u = scale and FOREVER.UnitOf and FOREVER.UnitOf(frame)
        sx, sy = AtlasSteps(atlas, w, fh, u and atlas.width * scale * u, u and atlas.height * scale * u)
    end
    local x1, x2 = c * sx, (w - c) * sx
    local y1, y2 = c * sy, (fh - c) * sy
    local xe, ye = w * sx, fh * sy
    if not tile then
        if xe > 1 then xe = 1 end
        if ye > 1 then ye = 1 end
    end
    if x1 > xe then x1 = xe end
    if x2 > xe then x2 = xe end
    if y1 > ye then y1 = ye end
    if y2 > ye then y2 = ye end
    local x0, y0 = 0, 0
    if atlas then
        x0, x1, x2, xe = AtlasU(atlas, 0), AtlasU(atlas, x1), AtlasU(atlas, x2), AtlasU(atlas, xe)
        y0, y1, y2, ye = AtlasV(atlas, 0), AtlasV(atlas, y1), AtlasV(atlas, y2), AtlasV(atlas, ye)
    end
    cells.tl:SetTexCoord(x0, x1, y0, y1)
    cells.tm:SetTexCoord(x1, x2, y0, y1)
    cells.tr:SetTexCoord(x2, xe, y0, y1)
    cells.ml:SetTexCoord(x0, x1, y1, y2)
    cells.mm:SetTexCoord(x1, x2, y1, y2)
    cells.mr:SetTexCoord(x2, xe, y1, y2)
    cells.bl:SetTexCoord(x0, x1, y2, ye)
    cells.bm:SetTexCoord(x1, x2, y2, ye)
    cells.br:SetTexCoord(x2, xe, y2, ye)
end

-- Corner rounding for the art cells: masks cannot subset their texture
-- via texcoords, so each corner cell gets a QUADRANT of a full circle
-- mask (the proven FilterButtonCircle disc) sized 2x the corner cell and
-- anchored so the right quarter covers the cell. The quarter radius then
-- equals the corner size exactly, matching the fill's silhouette.
local ART_MASK_ANCHORS = {
    tl = "TOPLEFT", tr = "TOPRIGHT", bl = "BOTTOMLEFT", br = "BOTTOMRIGHT",
}
local ART_CORNER_MASK_TEX = "Interface\\AddOns\\EasyFind\\textures\\FilterButtonCircle"

local function EnsureThemeArtOverlay(frame)
    if frame._efArtCells then return frame._efArtCells end
    local cells = {}
    local masks = {}
    for name in pairs(TC9) do
        local cell = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
        local anchor = ART_MASK_ANCHORS[name]
        if anchor then
            local mask = frame:CreateMaskTexture()
            mask:SetTexture(ART_CORNER_MASK_TEX, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetPoint(anchor, cell, anchor)
            cell:AddMaskTexture(mask)
            masks[name] = mask
        end
        cells[name] = cell
    end
    frame._efArtCells = cells
    frame._efArtMasks = masks
    ApplyContainerCornerSize(frame)
    return cells
end

-- Position-aware theme gradient: each nine-slice cell gets the segment
-- of the bottom->top ramp matching its own y-range in the frame, so a
-- bar-only pill (all corner rows) still shows a smooth ramp instead of
-- two flat halves with a seam. Re-run on size changes (corner-size pass)
-- because the ranges move. Applies to the art cells when a grain/art
-- texture is showing (the ramp rides the texture as vertex gradient),
-- else to the plain fill cells.
local function ThemeRampColor(bottom, top, yFromTop, height)
    local t = 1 - (yFromTop / height)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return bottom[1] + (top[1] - bottom[1]) * t,
           bottom[2] + (top[2] - bottom[2]) * t,
           bottom[3] + (top[3] - bottom[3]) * t
end

-- Each fill cell its segment of the bottom->top ramp, by its y-range.
function ns.RampFillCells(frame, cells, bottom, top, alpha)
    local h = frame:GetHeight() or 0
    if h <= 0 then return end
    local corner = (frame.cbBarHeight or h) / 2
    if corner > h / 2 then corner = h / 2 end
    local function rampCell(cell, y0, y1)
        if not cell then return end
        local r1, g1, b1 = ThemeRampColor(bottom, top, y0, h)
        local r2, g2, b2 = ThemeRampColor(bottom, top, y1, h)
        cell:SetVertexColor(1, 1, 1, 1)
        cell:SetGradient("VERTICAL", CreateColor(r2, g2, b2, alpha), CreateColor(r1, g1, b1, alpha))
    end
    rampCell(cells.tl, 0, corner)
    rampCell(cells.tm, 0, corner)
    rampCell(cells.tr, 0, corner)
    rampCell(cells.ml, corner, h - corner)
    rampCell(cells.mm, corner, h - corner)
    rampCell(cells.mr, corner, h - corner)
    rampCell(cells.bl, h - corner, h)
    rampCell(cells.bm, h - corner, h)
    rampCell(cells.br, h - corner, h)
end

function ns.UpdateThemeFillGradient(frame)
    if not (frame and frame.combinedBorder) then return end
    -- A ramped settings button follows its own new height.
    if frame._efRamp and frame._efFillR then
        ns.RampButtonFill(frame, frame._efFillR, frame._efFillG, frame._efFillB, frame._efFillA)
        return
    end
    -- Only ApplyThemeFill's windows: this runs for every rounded frame, and
    -- the window ramp on a control left it the wrong color until hovered.
    if not frame._efThemeFillTarget then return end
    local palette = ns.ThemePaletteOf and ns.ThemePaletteOf(frame) or ns.ACTIVE_UI_PALETTE
    local bottom = palette and palette.windowFillBottom
    local top = palette and palette.windowFillTop
    if not (bottom and top and CreateColor) then return end
    -- Art draws as authored; only tintArt palettes (grain) take the ramp.
    local artShown = frame._efArtCells and frame._efArtCells.mm:IsShown()
    local cells
    if artShown then
        if not (palette and palette.tintArt) then return end
        cells = frame._efArtCells
    else
        cells = frame.combinedBorder.fill
    end
    ns.RampFillCells(frame, cells, bottom, top, frame._efBgAlpha or 1)
end

-- Theme-aware window fill shared by the search container, results panel,
-- and every StyleMenuPanel surface. Flat themes paint the live window
-- fill color; a palette with fillTexture shows the cropped art overlay;
-- windowFillBottom/Top give a vertical two-stop gradient (also the
-- pre-relaunch fallback while a new art file is not yet in the client's
-- addon manifest).
function ns.ApplyThemeFill(frame)
    if not (frame and frame.combinedBorder and frame.combinedBorder.fill) then return end
    -- Marks this frame as a window-fill surface: UpdateThemeFillGradient
    -- refuses to ramp anything without this flag.
    frame._efThemeFillTarget = true
    if ns.ApplySkin(frame) then return end
    local fill = frame.combinedBorder.fill
    local set = ns.ThemeSetOf and ns.ThemeSetOf(frame)
    local palette = set and set.palette or ns.ACTIVE_UI_PALETTE
    local windowFill = set and set.SEARCH_WINDOW_FILL_COLOR or ns.SEARCH_WINDOW_FILL_COLOR
    local cWhite = CreateColor and CreateColor(1, 1, 1, 1)
    -- A studio theme tints the ring; the stock tint returns when the
    -- next theme has no borderColor slot.
    local ring = palette and palette.borderColor
    if ring then
        frame._efPaletteRing = true
        ns.SetRoundedRectBorderColor(frame, ring[1], ring[2], ring[3], ring[4] or 1)
    elseif frame._efPaletteRing then
        frame._efPaletteRing = nil
        ns.SetRoundedRectBorderColor(frame, BORDER_R, BORDER_G, BORDER_B, 1)
    end

    local artPath = palette and palette.fillTexture
    -- Forever's page at its own size, cropped; another atlas fitted across.
    local atlasInfo, pageScale
    if palette and palette.fillAtlas == FOREVER.fillAtlas then
        atlasInfo, pageScale = FOREVER.Page()
    else
        atlasInfo = palette and palette.fillAtlas and C_Texture and C_Texture.GetAtlasInfo
            and C_Texture.GetAtlasInfo(palette.fillAtlas)
    end
    if atlasInfo and not (atlasInfo.file and (atlasInfo.width or 0) > 0 and (atlasInfo.height or 0) > 0) then
        atlasInfo = nil
    end
    if atlasInfo then artPath = atlasInfo.file end
    if artPath then
        local cells = EnsureThemeArtOverlay(frame)
        frame._efArtAtlas, frame._efArtPageScale = atlasInfo, pageScale
        -- A tiling texture repeats at its own size instead of one stretched crop.
        local tile = not atlasInfo and palette.fillTile or nil
        frame._efArtTile = tile
        local wrap = tile and "REPEAT" or nil
        if cells.mm:SetTexture(artPath, wrap, wrap) then
            for name, cell in pairs(cells) do
                cell:SetTexture(artPath, wrap, wrap)
                cell:SetVertexColor(1, 1, 1, 1)
                cell:Show()
            end
            ns.UpdateThemeArtCrop(frame)
            if palette.tintArt then
                ns.UpdateThemeFillGradient(frame)
            end
            -- Base fill goes flat under the (opaque) art so nothing of a
            -- previous theme shows through the corners' antialiased rim.
            local flatBase = palette.windowFill or windowFill
            for _, cell in pairs(fill) do
                if cWhite and cell.SetGradient then
                    cell:SetGradient("VERTICAL", cWhite, cWhite)
                end
                cell:SetVertexColor(flatBase[1], flatBase[2], flatBase[3], 1)
            end
            return
        end
    end
    if frame._efArtCells then
        for _, cell in pairs(frame._efArtCells) do cell:Hide() end
    end

    local bottom = palette and palette.windowFillBottom
    local top = palette and palette.windowFillTop
    if bottom and top and CreateColor then
        ns.UpdateThemeFillGradient(frame)
        return
    end
    local flat = windowFill
    for _, cell in pairs(fill) do
        if cWhite and cell.SetGradient then
            cell:SetGradient("VERTICAL", cWhite, cWhite)
        end
        cell:SetVertexColor(flat[1], flat[2], flat[3], 1)
    end
end

function ns.SetRoundedRectBorderColor(frame, r, g, b, a, snapOff)
    if not (frame and frame.combinedBorder and frame.combinedBorder.border) then return end
    for _, t in pairs(frame.combinedBorder.border) do
        t:SetVertexColor(r, g, b, a or 1)
        if snapOff then DisablePixelSnap(t) end
    end
end

-- The ring as SetRoundedRectRingShown sets it: recorded, so a skin taken
-- off brings it back only where it was wanted.
function ns.SetRoundedRectBorderEdgeShown(frame, shown)
    ns.SetRoundedRectRingShown(frame, shown)
end

-- Wizard-style panel gloss shared by the tutorial wizard, options panel, and
-- What's New popup. A single vertical gradient is mapped across the 9-slice
-- fill; each cell's gradient stops are sampled from its vertical position in
-- the frame. The brightness ramp is packed into the bottom 10% so 8-bit
-- banding collapses into a couple-pixel transition, with smoothstep so the
-- slope varies and bands cannot space evenly.
local GLOSS_DARK_FRAC = 0.90

local function GlossSmoothstep(t)
    if t <= 0 then return 0 end
    if t >= 1 then return 1 end
    return t * t * (3 - 2 * t)
end

local function GlossLerp(a, b, t) return a + (b - a) * t end

local function GlossColorAt(y, height, base)
    local t = y / height
    if t < GLOSS_DARK_FRAC then
        t = 0
    else
        t = GlossSmoothstep((t - GLOSS_DARK_FRAC) / (1 - GLOSS_DARK_FRAC))
    end
    -- Ramp endpoints derive from the live theme fill so wizard-style
    -- panels (options, tutorial, What's New) match the selected theme.
    -- Factors are tuned so the Black default reproduces the original
    -- fixed ramp (0.022 -> ~0.21). Light fills get a subtle inverse
    -- gloss (slightly darker body, slightly brighter lip). base: the
    -- panel's window fill.
    local br, bg, bb = base[1], base[2], base[3]
    local lum = 0.3 * br + 0.5 * bg + 0.2 * bb
    local mmin = math.min
    if lum > 0.5 then
        return GlossLerp(br * 0.92, mmin(1, br * 1.06 + 0.02), t),
               GlossLerp(bg * 0.92, mmin(1, bg * 1.06 + 0.02), t),
               GlossLerp(bb * 0.92, mmin(1, bb * 1.06 + 0.02), t)
    end
    return GlossLerp(br * 0.45, mmin(1, br * 2.8 + 0.06), t),
           GlossLerp(bg * 0.45, mmin(1, bg * 2.8 + 0.06), t),
           GlossLerp(bb * 0.45, mmin(1, bb * 2.8 + 0.06), t)
end

local function GlossRamp(cell, yTop, yBot, height, base)
    if not cell then return end
    local r1, g1, b1 = GlossColorAt(yTop, height, base)
    local r2, g2, b2 = GlossColorAt(yBot, height, base)
    -- VERTICAL: first color is bottom, second is top.
    cell:SetGradient("VERTICAL", CreateColor(r2, g2, b2, 1), CreateColor(r1, g1, b1, 1))
end

function ns.ApplyWizardPanelGloss(frame)
    local fill = frame.combinedBorder and frame.combinedBorder.fill
    if not fill then return end
    local height = frame:GetHeight()
    if not height or height <= 0 then return end
    local corner = (frame.cbBarHeight or 32) / 2
    local set = ns.ThemeSetOf and ns.ThemeSetOf(frame)
    local base = set and set.SEARCH_WINDOW_FILL_COLOR or ns.SEARCH_WINDOW_FILL_COLOR
    GlossRamp(fill.tl, 0, corner, height, base)
    GlossRamp(fill.tm, 0, corner, height, base)
    GlossRamp(fill.tr, 0, corner, height, base)
    GlossRamp(fill.ml, corner, height - corner, height, base)
    GlossRamp(fill.mm, corner, height - corner, height, base)
    GlossRamp(fill.mr, corner, height - corner, height, base)
    GlossRamp(fill.bl, height - corner, height, height, base)
    GlossRamp(fill.bm, height - corner, height, height, base)
    GlossRamp(fill.br, height - corner, height, height, base)
end

-- One-call background for wizard-style panels: near-black rounded fill with
-- relaxed pixel snapping, gloss gradient, border ring hidden (its corner
-- cells band against the gradient fill). The alpha lands on the fill cells;
-- callers that dim the whole frame instead pass 1.
-- The header plate with a gold title on a classic window, or nothing.
function ns.ApplyClassicHeader(frame, title)
    if not frame then return end
    local on = ns.IsClassicChrome()
    if on and not frame._efClassicHeader then
        local header = frame:CreateTexture(nil, "ARTWORK")
        header:SetTexture(ns.CLASSIC_HEADER)
        header:SetSize(256, 64)
        header:SetPoint("TOP", frame, "TOP", 0, 12)
        local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        text:SetPoint("TOP", header, "TOP", 0, -14)
        frame._efClassicHeader = { plate = header, text = text }
    end
    local h = frame._efClassicHeader
    if h then
        h.plate:SetShown(on)
        h.text:SetShown(on)
        if on then h.text:SetText(title or "") end
    end
end

function ns.StyleWizardPanel(frame, alpha)
    if not frame.combinedBorder then
        ns.CreateRoundedRectBorder(frame)
    end
    frame._efWizardAlpha = alpha or 1
    if ns.ApplyClassicChrome(frame, frame._efWizardAlpha, "dialog") then return end
    ns.SetRoundedRectBarHeight(frame, 16)
    ns.SetRoundedRectBorderEdgeShown(frame, false)
    -- A theme with background art (Forever's quest log page, Classic's
    -- marble) wears it here as the search window does; the rest the gloss.
    local set = ns.ThemeSetOf and ns.ThemeSetOf(frame)
    local pal = set and set.palette or ns.ACTIVE_UI_PALETTE
    if pal and (pal.fillAtlas or pal.fillTexture) then
        ns.ApplyThemeFill(frame)
        ns.SetRoundedRectBorderBgAlpha(frame, frame._efWizardAlpha)
    else
        if frame._efArtCells then
            for _, cell in pairs(frame._efArtCells) do cell:Hide() end
        end
        local base = set and set.SEARCH_WINDOW_FILL_COLOR or ns.SEARCH_WINDOW_FILL_COLOR
        ns.SetRoundedRectFill(frame, base[1] * 0.8, base[2] * 0.8, base[3] * 0.8, 1, true)
        ns.SetRoundedRectBorderBgAlpha(frame, frame._efWizardAlpha)
        ns.ApplyWizardPanelGloss(frame)
    end
    if not frame._efWizardGlossHooked then
        frame._efWizardGlossHooked = true
        frame:HookScript("OnSizeChanged", ns.ApplyWizardPanelGloss)
        -- Re-style on every open so a theme switched while the panel was
        -- closed lands on the next show.
        frame:HookScript("OnShow", function(self)
            ns.StyleWizardPanel(self, self._efWizardAlpha)
        end)
    end
end

local MENU_ROW_HIGHLIGHT_TEX = "Interface\\QuestFrame\\UI-QuestTitleHighlight"

-- ONE rounded hover pill for every row surface: search result rows and menu
-- rows share this (menus used to cut positional corner masks; now every row
-- wears the same rounded fill the result rows do). wants toggles it; layout
-- (optional) anchors the pill at creation, defaulting to the row's own rect.
-- washColor (optional {r, g, b, a}) overrides the theme's row wash. Callers
-- whose selection carries its own meaning -- the task view's rows tint with
-- the zone-preview accent so row and on-screen preview read as one -- pass it
-- and stay visible on themes that have no wash color of their own.
function Utils.UpdateRoundedRowWash(row, wants, layout, washColor)
    local washR, washG, washB, washA
    if washColor then
        washR, washG, washB, washA = washColor[1], washColor[2], washColor[3], washColor[4]
    else
        washR, washG, washB = ns.RowWashColor()
        washA = ns.RowWashAlpha()
    end
    if not (wants and washR) then
        if row.hoverWash then row.hoverWash:Hide() end
        return
    end
    local hl = row.hoverWash
    if not hl then
        -- The pill must sit BETWEEN its container's fill and the row's text:
        -- strictly ABOVE the container's level and strictly BELOW the row's.
        -- Rows within one level of their container leave no band for it (a
        -- pill at the container's own level z-fights the fill and vanishes --
        -- HARDFOUGHT_BATTLES: equal level = the parent wins), so lift such
        -- rows to container+2 first; their regions ride along.
        local container = row:GetParent()
        if container and container.GetFrameLevel
           and row:GetFrameLevel() <= container:GetFrameLevel() + 1 then
            row:SetFrameLevel(container:GetFrameLevel() + 2)
        end
        hl = CreateFrame("Frame", nil, row)
        if layout then
            layout(hl, row)
        else
            hl:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
            hl:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
        end
        hl:SetFrameLevel(row:GetFrameLevel() > 0 and row:GetFrameLevel() - 1 or 0)
        ns.CreateRoundedRectBorder(hl)
        -- Panel ON first (fill cells are born hidden), then ring off: the
        -- documented ordering for fill-only rounded frames.
        ns.SetRoundedRectBorderShown(hl, true)
        ns.SetRoundedRectRingShown(hl, false)
        row.hoverWash = hl
    end
    -- Corner curvature between the window's full curve and a subtle card
    -- round, clamped to the row height so short rows don't overlap corners.
    local rowH = row:GetHeight() or 0
    local barH = 22
    if rowH > 0 and rowH < barH then barH = rowH end
    if hl._efBarH ~= barH then
        hl._efBarH = barH
        ns.SetRoundedRectBarHeight(hl, barH)
    end
    ns.SetRoundedRectFill(hl, washR, washG, washB, washA, true)
    hl:Show()
end

-- Hover/focus wash for menu rows on non-Black themes. This CANNOT be the
-- Button highlight texture: a highlight texture auto-shows on hover only
-- while it lives in the HIGHLIGHT layer, and that layer draws above the
-- row text (fine for the additive glow, opaque paint hides the label).
-- So the wash is a plain BACKGROUND texture whose visibility mirrors the
-- highlight state through the hooks below.
local function UpdateMenuRowWash(row)
    Utils.UpdateRoundedRowWash(row,
        row._efWashActive and (row._efWashHover or row._efWashFocused))
end

local function EnsureMenuRowWash(row)
    -- Legacy flat wash band: superseded by the shared rounded pill.
    if row._efWashTex then
        row._efWashTex:Hide()
        row._efWashTex = nil
        row._efWashHooked = true   -- the old path installed the hover hooks
    end
    if not row._efWashHooked then
        row._efWashHooked = true
        row:HookScript("OnEnter", function(self)
            self._efWashHover = true
            UpdateMenuRowWash(self)
        end)
        row:HookScript("OnLeave", function(self)
            self._efWashHover = nil
            UpdateMenuRowWash(self)
        end)
    end
end

-- Widest natural width across regions: FontStrings measure unwrapped, other
-- regions by their frame width. The panel-shaped companion to
-- MaxRowLabelWidth below; both exist so popups size to their content
-- instead of hardcoding widths that drift from what they hold.
function Utils.MaxContentWidth(regions)
    local maxW = 0
    for i = 1, #regions do
        local region = regions[i]
        if region then
            local w
            if region.GetUnboundedStringWidth then
                w = region:GetUnboundedStringWidth()
            elseif region.GetStringWidth then
                w = region:GetStringWidth()
            elseif region.GetWidth then
                w = region:GetWidth()
            end
            if w and w > maxW then maxW = w end
        end
    end
    return maxW
end

-- Natural width of one flyout row: leading inset (checkbox + gap, or a
-- plain text inset) + optional ._icon texture + label + optional ._chev
-- reserve. Labels measure unwrapped so anchor-clipped rows don't feed
-- their own clipped width back in.
function Utils.FlyoutRowContentWidth(row, leading, iconSize, chevSize)
    local label = row and row._label
    if not label then return 0 end
    local getter = label.GetUnboundedStringWidth or label.GetStringWidth
    local w = leading + getter(label)
    if row._icon and iconSize then w = w + iconSize + 4 end
    if row._chev and chevSize then w = w + 4 + chevSize + 4 end
    return w
end

-- Popup width for a flyout whose widest content line is contentW: side
-- padding both sides plus a small right margin so text never touches the
-- border, floored at FLYOUT_MIN_WIDTH. Every flyout builder sizes through
-- this so widths track content instead of hardcoded constants.
function Utils.FlyoutWidthFor(contentW, pad)
    return mmax(ns.FLYOUT_MIN_WIDTH, mceil(contentW) + pad * 2 + 8)
end

-- The class/spec selector BUTTON is 130 wide everywhere it appears
-- (gear, heirlooms, the appearances chooser); host panels content-fit
-- around it, treating it as fixed-width content.
ns.CLASS_SELECTOR_BTN_W = 130

-- Widest label across popup rows (rows carry ._label or .text). Callers add
-- their own row insets and margins, then clamp to ns.FLYOUT_MIN_WIDTH so
-- flyouts hug their contents.
function Utils.MaxRowLabelWidth(rows, count)
    local maxW = 0
    for i = 1, count or #rows do
        local row = rows[i]
        local label = row and (row._label or row.text)
        if label and label.GetStringWidth then
            local w = label:GetStringWidth() or 0
            if w > maxW then maxW = w end
        end
    end
    return maxW
end

function Utils.RefreshMenuRowHighlights(parent, orderedRows)
    if not parent then return end
    local rows = {}
    if orderedRows then
        for i = 1, #orderedRows do
            local row = orderedRows[i]
            if row and row._efMenuRowHighlightInstalled and row:IsShown() and not row.isSeparator then
                rows[#rows + 1] = row
            end
        end
    else
        for _, row in ipairs({ parent:GetChildren() }) do
            if row and row._efMenuRowHighlightInstalled and row:IsShown() and not row.isSeparator then
                rows[#rows + 1] = row
            end
        end
    end

    -- Hover tint follows the main-row behavior: the theme wash on every
    -- theme except Black, which keeps the classic additive glow. In wash
    -- mode the real highlight texture stays in its HIGHLIGHT layer but
    -- goes transparent (it still drives hover/lock state); the visible
    -- hover is the SAME rounded pill the search result rows wear
    -- (Utils.UpdateRoundedRowWash) -- uniform on every row, no positional
    -- corner masks.
    local washR = ns.RowWashColor()
    for i = 1, #rows do
        local row = rows[i]
        row._efWashActive = washR and true or nil
        local hlTex = row:GetHighlightTexture()
        if washR then
            if hlTex then hlTex:SetAlpha(0) end
            EnsureMenuRowWash(row)
        elseif hlTex then
            hlTex:SetAlpha(1)
            hlTex:SetBlendMode("ADD")
            hlTex:SetVertexColor(1, 1, 1, 1)
        end
        UpdateMenuRowWash(row)
    end
end

-- Rows whose highlight is locked because their flyout is open. A hold lives
-- for the popup's whole shown lifetime; `held` tracks whether the lock is
-- currently applied. Hovering a SIBLING row releases the lock immediately
-- (the highlight transfers while the flyout lingers through its hide grace),
-- and re-entering the owner, its popup, or any row inside the popup restores
-- it. The popup's OnHide remains the final release.
local flyoutHighlightHolds = {}
-- Dev-tool peek: the holds are otherwise invisible
-- to external diagnosis.
Utils._flyoutHighlightHolds = flyoutHighlightHolds

local function FindFlyoutHighlightHold(owner, popup)
    for i = 1, #flyoutHighlightHolds do
        local hold = flyoutHighlightHolds[i]
        if hold.owner == owner and hold.popup == popup then return i, hold end
    end
    return nil
end

-- A hold's visual goes through the single-owner highlight API when the row
-- has it: SetMenuHighlightFocused drives BOTH the Black-theme texture lock
-- AND the wash-theme pill. Raw LockHighlight only locks the built-in texture,
-- which wash themes run at alpha 0 -- the hold engaged and nothing showed.
local function SetHoldVisual(owner, held)
    if owner.SetMenuHighlightFocused then
        owner:SetMenuHighlightFocused(held)
    elseif held then
        if owner.LockHighlight then owner:LockHighlight() end
    elseif owner.UnlockHighlight then
        owner:UnlockHighlight()
    end
end

local function MenuRowEnterAdjustsHolds(row)
    if #flyoutHighlightHolds == 0 then return end
    local rowParent = row:GetParent()
    for i = #flyoutHighlightHolds, 1, -1 do
        local hold = flyoutHighlightHolds[i]
        if not hold.popup:IsShown() then
            tremove(flyoutHighlightHolds, i)
        elseif hold.owner == row or rowParent == hold.popup then
            if not hold.held then
                hold.held = true
                SetHoldVisual(hold.owner, true)
            end
        elseif hold.held and hold.owner:GetParent() == rowParent then
            hold.held = false
            SetHoldVisual(hold.owner, false)
        end
    end
end

-- Gray out and disable a flyout/popup option row when the filter above it
-- is unchecked, mirroring the default UI (effectiveEnabled = parent and own).
-- Rows opt into extra dimming via _label/_icon/_chev/_dimTex fields.
-- Theme preview color: gradient themes sample the midpoint of their two
-- stops (the base windowFill is the darkest end and reads near-black);
-- flat themes use their single fill. Shared by the tutorial swatches
-- and the options theme dropdown.
function ns.ThemeSwatchColor(palette)
    local top, bottom = palette.windowFillTop, palette.windowFillBottom
    if top and bottom then
        return (top[1] + bottom[1]) / 2, (top[2] + bottom[2]) / 2, (top[3] + bottom[3]) / 2
    end
    return palette.windowFill[1], palette.windowFill[2], palette.windowFill[3]
end

-- Settings-group cards (the big rounded panels on the options tabs, the
-- alias/blacklist tables). Dark themes carry the theme's window fill
-- (gradient/art) at the section alpha, which is what gives the panels
-- their color ramp; light themes keep the flat dark section fill so the
-- fixed light text on them stays readable. Registered weakly so a theme
-- flip restyles every card.
local themeCards = setmetatable({}, { __mode = "k" })

function ns.ApplyCardFill(frame)
    if not (frame and frame.combinedBorder) then return end
    themeCards[frame] = true
    -- Under the Classic skin a card is a pane: marble in the thin edge.
    frame._efClassicSurface = true
    frame._efClassicStyle = frame._efClassicStyle or "thin"
    frame._efNoAutoRetint = true
    local set = ns.ThemeSetOf and ns.ThemeSetOf(frame)
    local section = set and set.SECTION_TABLE_FILL or ns.SECTION_TABLE_FILL
    local sectionAlpha = section[4] or 0.92
    local pal = set and set.palette or ns.ACTIVE_UI_PALETTE
    if pal and pal.light then
        frame._efThemeFillTarget = nil
        if frame._efArtCells then
            for _, cell in pairs(frame._efArtCells) do cell:Hide() end
        end
        ns.SetRoundedRectFill(frame, section[1], section[2], section[3], 1, true)
    else
        ns.ApplyThemeFill(frame)
    end
    ns.SetRoundedRectBorderBgAlpha(frame, sectionAlpha)
end

function ns.RestyleCardFills()
    for frame in pairs(themeCards) do
        ns.ApplyCardFill(frame)
    end
end

-- Flyout/submenu chevrons. The Blizzard forward-arrow atlas is gold as
-- authored, so theme tints multiply into mud (blue over gold reads
-- green). Every chevron instead renders the flat white filter arrow
-- rotated to point right; the vertex color is then the color on screen.
-- Chevrons register weakly so a theme flip repaints all of them, shown
-- or not. Two tint schemes on purpose: right-pointing chevrons stay
-- gold on dark themes, dropdown-selector down arrows stay gray.
local themeChevrons = setmetatable({}, { __mode = "k" })
local CHEVRON_POINT_RIGHT = math.pi / 2

function Utils.ChevronRestColor()
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    if theme and theme.lightTheme and theme.chromeGlyph then
        return theme.chromeGlyph[1], theme.chromeGlyph[2], theme.chromeGlyph[3]
    end
    return ns.GOLD_COLOR[1] * 0.9, ns.GOLD_COLOR[2] * 0.9, ns.GOLD_COLOR[3] * 0.9
end

function Utils.ChevronHoverColor()
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    if theme and theme.lightTheme and theme.pathColorHover then
        return theme.pathColorHover[1], theme.pathColorHover[2], theme.pathColorHover[3]
    end
    return ns.GOLD_COLOR[1], ns.GOLD_COLOR[2], ns.GOLD_COLOR[3]
end

function Utils.SetChevronTexture(tex)
    tex:SetTexture(ns.FILTER_ARROW_TEX)
    tex:SetRotation(CHEVRON_POINT_RIGHT)
    tex:SetVertexColor(Utils.ChevronRestColor())
    themeChevrons[tex] = true
end

function Utils.RetintChevrons()
    for tex in pairs(themeChevrons) do
        tex:SetVertexColor(Utils.ChevronRestColor())
    end
end

function Utils.SetFlyoutRowEnabled(row, enabled)
    if row._efRowEnabled == enabled then return end
    row._efRowEnabled = enabled
    row:SetEnabled(enabled)
    local a = enabled and 1 or 0.35
    if row._label then
        row._label:SetShadowColor(0, 0, 0, 0)
        if not enabled then
            row._label:SetTextColor(0.4, 0.4, 0.4)
        elseif row._label._efOwnColor then
            -- Labels on the always-dark dropdown pills (Blizzard
            -- textholder art) stay white on every theme; leaf text
            -- would sit dark-on-dark there.
            row._label:SetTextColor(1, 1, 1)
        else
            local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
            local leaf = theme and theme.leafColor
            if leaf then
                row._label:SetTextColor(leaf[1], leaf[2], leaf[3], 1)
            else
                row._label:SetTextColor(1, 1, 1)
            end
        end
    end
    local nt = row.GetNormalTexture and row:GetNormalTexture()
    if nt then nt:SetDesaturated(not enabled); nt:SetAlpha(a) end
    local ct = row.GetCheckedTexture and row:GetCheckedTexture()
    if ct then ct:SetDesaturated(not enabled); ct:SetAlpha(a) end
    if row._dimTex then
        for i = 1, #row._dimTex do
            row._dimTex[i]:SetDesaturated(not enabled)
            row._dimTex[i]:SetAlpha(a)
        end
    end
    if row._icon then row._icon:SetDesaturated(not enabled); row._icon:SetAlpha(a) end
    if row._chev then row._chev:SetAlpha(a) end
end

function Utils.InstallMenuRowHighlight(row)
    if not row then return nil end
    if not row._efMenuRowHighlightInstalled then
        row._efMenuRowHighlightInstalled = true
        row:SetHighlightTexture(MENU_ROW_HIGHLIGHT_TEX, "ADD")
        local hl = row:GetHighlightTexture()
        if hl then
            hl:ClearAllPoints()
            hl:SetAllPoints(row)
            hl:SetBlendMode("ADD")
        end
        row:HookScript("OnEnter", MenuRowEnterAdjustsHolds)
    end
    row.SetMenuHighlightFocused = function(self, focused)
        self._efWashFocused = focused and true or nil
        if focused then
            if self.LockHighlight then self:LockHighlight() end
        else
            if self.UnlockHighlight then self:UnlockHighlight() end
        end
        UpdateMenuRowWash(self)
    end
    row.ClearMenuHighlightState = function(self)
        self._efWashFocused = nil
        self._efWashHover = nil
        if self.UnlockHighlight then self:UnlockHighlight() end
        UpdateMenuRowWash(self)
    end
    return row.SetMenuHighlightFocused
end

-- Background-fill button style (keybind captures): rests on the window
-- color with the theme's main text color, hovers with the row wash.
-- RefreshVisual keeps both current across theme flips (the retint walker
-- calls it; the fill is also tagged for the fill sweep).
function ns.StyleBgFillButton(btn)
    btn._efBgFill = true
    btn._efLeafLabel = true
    btn.RefreshVisual = function(self)
        if self:IsEnabled() then
            if self._efPaintState then self._efPaintState(self, ns.BTN_FILL_NORMAL) end
            local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
            -- Under the Classic skin the paint just set the label (gold at rest).
            if self._label and not self._efRedOn then
                if theme and theme.leafColor then
                    self._label:SetTextColor(theme.leafColor[1], theme.leafColor[2], theme.leafColor[3], 1)
                else
                    self._label:SetTextColor(1, 1, 1, 1)
                end
            end
        end
    end
    btn:RefreshVisual()
end

-- Nav-pill styled buttons (alias/shortkey table cells): rest on the
-- selected-tab fill (a window-fill pill on light themes, slate on dark)
-- with the tab's inverted label, so they read as a selected tab instead of
-- vanishing into the table card. RefreshVisual keeps fill and label current
-- across theme flips (the retint walker calls it; the fill is also tagged
-- for the fill sweep).
function ns.StyleNavPillButton(btn)
    btn._efNavFill = true
    btn.RefreshVisual = function(self)
        if not self:IsEnabled() then return end
        if self._efPaintState then self._efPaintState(self, ns.BTN_FILL_NORMAL) end
        -- Under the Classic skin the paint just set the label (gold at rest).
        if not self._label or self._efRedOn then return end
        -- The window-fill pill wants the card color as its label (the same
        -- inversion the selected tab uses); dark themes keep light text on
        -- the slate pill.
        local pal = ns.ACTIVE_UI_PALETTE
        if pal and pal.light then
            local card = ns.SECTION_TABLE_FILL
            self._label:SetTextColor(card[1], card[2], card[3], 1)
        else
            local prim = ns.TEXT_PRIMARY
            self._label:SetTextColor(prim[1], prim[2], prim[3], 1)
        end
    end
    btn:RefreshVisual()
end

function Utils.SetCheckboxTextures(check, size)
    check:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    check:GetNormalTexture():SetSize(size, size)
    check:GetNormalTexture():ClearAllPoints()
    check:GetNormalTexture():SetPoint("LEFT", 4, 0)
    check:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    check:GetCheckedTexture():SetSize(size, size)
    check:GetCheckedTexture():ClearAllPoints()
    check:GetCheckedTexture():SetPoint("LEFT", 4, 0)
end

-- ==== base64 ================================================================
-- Share codes (shortkey lists, profiles) travel as "<PREFIX>!<base64>".
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64char, b64byte = string.char, string.byte

function Utils.Base64Encode(data)
    return ((data:gsub(".", function(x)
        local r, b = "", b64byte(x)
        for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
        return B64:sub(c + 1, c + 1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1])
end

function Utils.Base64Decode(data)
    data = data:gsub("[^" .. B64 .. "=]", "")
    return (data:gsub(".", function(x)
        if x == "=" then return "" end
        local r, f = "", (B64:find(x, 1, true) - 1)
        for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then return "" end
        local c = 0
        for i = 1, 8 do c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0) end
        return b64char(c)
    end))
end

do
-- Under the Classic skin every button is the 1.x red panel button: caps and
-- middle cut from the old art, its highlight on hover, gold text.
local RED_ART = "Interface\\Buttons\\UI-Panel-Button-"
local modernButtons = setmetatable({}, { __mode = "k" })

local function RedButton(btn)
    local red = btn._efRed
    if red then return red end
    red = { l = btn:CreateTexture(nil, "BACKGROUND", nil, 1), m = btn:CreateTexture(nil, "BACKGROUND", nil, 1),
            r = btn:CreateTexture(nil, "BACKGROUND", nil, 1), hl = btn:CreateTexture(nil, "ARTWORK") }
    red.l:SetPoint("TOPLEFT")
    red.l:SetPoint("BOTTOMLEFT")
    red.r:SetPoint("TOPRIGHT")
    red.r:SetPoint("BOTTOMRIGHT")
    red.m:SetPoint("TOPLEFT", red.l, "TOPRIGHT")
    red.m:SetPoint("BOTTOMRIGHT", red.r, "BOTTOMLEFT")
    red.hl:SetTexture(RED_ART .. "Highlight")
    red.hl:SetTexCoord(0, 0.625, 0, 0.6875)
    red.hl:SetBlendMode("ADD")
    red.hl:SetAllPoints(btn)
    btn._efRed = red
    return red
end

local function PaintRed(btn, fillTable)
    local red = RedButton(btn)
    local state = (fillTable == ns.BTN_FILL_PRESSED and "Down") or (fillTable == ns.BTN_FILL_DISABLED and "Disabled") or "Up"
    -- The caps keep the art's 12 to 22 proportion, never past half the width.
    local cap = mmin((btn:GetHeight() or 22) * 12 / 22, (btn:GetWidth() or 24) / 2)
    red.l:SetWidth(cap)
    red.r:SetWidth(cap)
    red.l:SetTexture(RED_ART .. state)
    red.l:SetTexCoord(0, 0.09375, 0, 0.6875)
    red.m:SetTexture(RED_ART .. state)
    red.m:SetTexCoord(0.09375, 0.53125, 0, 0.6875)
    red.r:SetTexture(RED_ART .. state)
    red.r:SetTexCoord(0.53125, 0.625, 0, 0.6875)
    red.l:Show()
    red.m:Show()
    red.r:Show()
    red.hl:SetShown(fillTable == ns.BTN_FILL_HOVER)
    btn._efRedOn = true
    if btn._label then
        if state == "Disabled" then
            btn._label:SetTextColor(0.5, 0.5, 0.5, 1)
        elseif state == "Down" or fillTable == ns.BTN_FILL_HOVER then
            btn._label:SetTextColor(1, 1, 1, 1)
        else
            btn._label:SetTextColor(1, 0.82, 0, 1)
        end
    end
end

-- Back to the rounded pill after the Classic skin.
local function DropRed(btn)
    for _, t in pairs(btn._efRed) do t:Hide() end
    btn._efRedOn = nil
    ns.SetRoundedRectBorderShown(btn, true)
    ns.SetRoundedRectBorderEdgeShown(btn, false)
    if btn._label then
        local theme = btn._efLeafLabel and ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
        local c = theme and theme.leafColor
        if c then btn._label:SetTextColor(c[1], c[2], c[3], 1) else btn._label:SetTextColor(1, 1, 1, 1) end
    end
end
-- Buttons of other makes wear the same red under the Classic skin.
ns.PaintRedButton, ns.DropRedButton = PaintRed, DropRed

-- On the settings window a button's fill ramps dark at its top: the window
-- darkens downward, so the two part at every height where a flat fill can
-- match it.
ns.RampedButtons = setmetatable({}, { __mode = "k" })
function ns.RampButtonFill(frame, r, g, b, a)
    frame._efFillR, frame._efFillG, frame._efFillB, frame._efFillA = r, g, b, a or 1
    if not CreateColor then return end
    local top, bottom = frame._efRampTop or {}, frame._efRampBottom or {}
    frame._efRampTop, frame._efRampBottom = top, bottom
    top[1], top[2], top[3] = r * 0.65, g * 0.65, b * 0.65
    bottom[1], bottom[2], bottom[3] = math.min(1, r * 1.2), math.min(1, g * 1.2), math.min(1, b * 1.2)
    ns.RampFillCells(frame, frame.combinedBorder.fill, bottom, top, a or 1)
end

function ns.PaintButtonRamp(btn)
    local fill = btn.combinedBorder and btn.combinedBorder.fill
    if not fill then return end
    -- Under the Classic skin the red, from the first show (nothing else
    -- paints a button's state before it is hovered).
    if btn._efPaintState and (ns.IsClassicChrome() or btn._efRedOn) then
        btn._efPaintState(btn, not btn:IsEnabled() and ns.BTN_FILL_DISABLED
            or (btn:IsMouseOver() and ns.BTN_FILL_HOVER) or ns.BTN_FILL_NORMAL)
        if btn._efRedOn then return end
    end
    btn._efRamp = ns.ThemeSurfaceOf and ns.ThemeSurfaceOf(btn) == "options" and not ns.IsClassicChrome() or nil
    local r, g, b, a = btn._efFillR, btn._efFillG, btn._efFillB, btn._efFillA
    if not r then r, g, b, a = fill.mm:GetVertexColor() end
    if btn._efRamp then
        ns.RampButtonFill(btn, r, g, b, a)
    else
        for _, t in pairs(fill) do t:SetVertexColor(r, g, b, a or 1) end
    end
end

function ns.RampButton(btn)
    ns.RampedButtons[btn] = true
    btn:HookScript("OnShow", ns.PaintButtonRamp)
    ns.PaintButtonRamp(btn)
end

-- A theme flip repaints every button that enters or leaves the Classic skin.
function ns.RestyleModernButtons()
    for btn in pairs(ns.RampedButtons) do ns.PaintButtonRamp(btn) end
    local classic = ns.IsClassicChrome()
    for btn in pairs(modernButtons) do
        if btn._efPaintState and (classic or btn._efRedOn) then
            local fill = not btn:IsEnabled() and ns.BTN_FILL_DISABLED
                or (btn:IsMouseOver() and ns.BTN_FILL_HOVER) or ns.BTN_FILL_NORMAL
            btn._efPaintState(btn, fill)
        end
    end
end

-- Buttons in a row as wide as their labels (minW at least), cut evenly
-- only when the row has less room than that.
function ns.FitButtonRow(buttons, room, gap, minW)
    local widths, total = {}, gap * (#buttons - 1)
    for i, btn in ipairs(buttons) do
        btn._label:SetText(btn:GetText())
        widths[i] = math.max(minW, math.ceil(btn._label:GetStringWidth() or 0) + 20)
        total = total + widths[i]
    end
    local gaps = gap * (#buttons - 1)
    local scale = total > room and (room - gaps) / (total - gaps) or 1
    for i, btn in ipairs(buttons) do btn:SetSize(math.floor(widths[i] * scale), btn:GetHeight()) end
end

function ns.CreateModernButton(parent, text, width, height)
    local btn = CreateFrame("Button", nil, parent)
    modernButtons[btn] = true
    local rawSetSize = btn.SetSize
    rawSetSize(btn, width or 120, height or 22)

    ns.CreateRoundedRectBorder(btn)
    ns.SetRoundedRectBarHeight(btn, mmin(height or 22, 10))
    ns.SetRoundedRectBorderBgAlpha(btn, 1)
    ns.SetRoundedRectBorderEdgeShown(btn, false)
    ns.SetRoundedRectBorderFillColor(btn, unpack(ns.BTN_FILL_NORMAL))
    btn._efControlFillKind = "BTN_FILL_NORMAL"
    ns.RampButton(btn)

    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText(text or "")
    label:SetTextColor(1, 1, 1, 1)
    -- Flat button design: the font object's baked drop shadow reads as
    -- smear on the pill fills. The label owns its color (light text on
    -- the dark pill on every theme); the menu text pass must not touch it.
    label:SetShadowColor(0, 0, 0, 0)
    label._efOwnColor = true
    btn._label = label

    -- Inset reserved for the text inside the button. Leaves a small margin
    -- around the rounded corners without eating the entire available width
    -- on narrow buttons (preset rows, +/- spinners, etc).
    local TEXT_INSET = 4

    local function fitLabelEllipsis(self)
        local label = self._label
        if not label then return end
        local full = self._fullText or ""
        if full == "" then
            label:SetText("")
            self._isTruncated = false
            return
        end
        local avail = (self:GetWidth() or 0) - TEXT_INSET * 2
        if avail <= 0 then
            label:SetText(full)
            self._isTruncated = false
            return
        end
        label:SetText(full)
        if label:GetStringWidth() <= avail then
            self._isTruncated = false
            return
        end
        -- Binary search for the longest prefix that fits with an ellipsis.
        local ELLIPSIS = "..."
        local lo, hi = 1, #full
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            label:SetText(full:sub(1, mid) .. ELLIPSIS)
            if label:GetStringWidth() <= avail then
                lo = mid
            else
                hi = mid - 1
            end
        end
        label:SetText(full:sub(1, lo) .. ELLIPSIS)
        self._isTruncated = true
    end
    btn._fitLabel = fitLabelEllipsis

    btn.SetText = function(self, value)
        self._fullText = value or ""
        fitLabelEllipsis(self)
    end
    btn.GetText = function(self)
        return self._fullText or (self._label and self._label:GetText()) or ""
    end
    btn.SetSize = function(self, w, h)
        rawSetSize(self, w, h)
        ns.SetRoundedRectBarHeight(self, mmin(h or self:GetHeight() or 22, 10))
        fitLabelEllipsis(self)
    end
    -- Sized by its anchors too: the text fits the width it ends up with.
    btn:HookScript("OnSizeChanged", fitLabelEllipsis)

    -- Tooltip-on-truncate. If the button's text was clipped to ellipsis,
    -- hovering for 0.5s pops the full label. Skipped silently when another
    -- handler has already claimed GameTooltip for this button (e.g. a real
    -- explanatory tooltip) so this never fights an intentional one.
    btn:HookScript("OnEnter", function(self)
        if not self._isTruncated then return end
        if self._ellipsisTimer then self._ellipsisTimer:Cancel(); self._ellipsisTimer = nil end
        self._ellipsisTimer = C_Timer.NewTimer(0.5, function()
            self._ellipsisTimer = nil
            if not self:IsMouseOver() then return end
            if GameTooltip:GetOwner() == self and GameTooltip:IsShown() then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self._fullText or "", 1, 1, 1)
            GameTooltip:Show()
            self._showedEllipsisTooltip = true
        end)
    end)
    btn:HookScript("OnLeave", function(self)
        if self._ellipsisTimer then self._ellipsisTimer:Cancel(); self._ellipsisTimer = nil end
        if self._showedEllipsisTooltip then
            self._showedEllipsisTooltip = nil
            GameTooltip:Hide()
        end
    end)

    local rawSetNormalFont = btn.SetNormalFontObject
    btn.SetNormalFontObject = function(self, fontObject)
        if rawSetNormalFont then rawSetNormalFont(self, fontObject) end
        if self._label then self._label:SetFontObject(fontObject) end
    end
    local rawSetHighlightFont = btn.SetHighlightFontObject
    btn.SetHighlightFontObject = function(self, fontObject)
        if rawSetHighlightFont then rawSetHighlightFont(self, fontObject) end
    end

    local function PaintState(self, fillTable)
        if ns.IsClassicChrome() then
            ns.SetRoundedRectBorderShown(self, false)
            PaintRed(self, fillTable)
            self._efControlFillKind = false
            return
        elseif self._efRedOn then
            DropRed(self)
        end
        -- Window-fill styled buttons (stepper +/-) rest on the row-wash
        -- tint (a step off the window color; the plain fill blended into
        -- the panel on flat themes); hover/pressed keep the shared states.
        if self._efWindowFill and fillTable == ns.BTN_FILL_NORMAL then
            local washR, washG, washB = ns.RowWashColor()
            if washR then
                ns.SetRoundedRectBorderFillColor(self, washR, washG, washB, 1)
                self._efControlFillKind = false
                return
            end
        end
        -- Background-fill buttons (keybind captures) rest on the window
        -- color itself and hover with the wash.
        if self._efBgFill then
            if fillTable == ns.BTN_FILL_NORMAL then
                fillTable = ns.SEARCH_WINDOW_FILL_COLOR
            elseif fillTable == ns.BTN_FILL_HOVER then
                local washR, washG, washB = ns.RowWashColor()
                if washR then
                    ns.SetRoundedRectBorderFillColor(self, washR, washG, washB, 1)
                    self._efControlFillKind = false
                    return
                end
            end
        end
        -- Nav-pill buttons (alias/shortkey cells) rest on the selected-tab
        -- fill and hover a step lighter, so they read as a selected tab
        -- instead of blending into the table card (on light themes the plain
        -- button fill and the card fill are the same dark mix).
        if self._efNavFill then
            if fillTable == ns.BTN_FILL_NORMAL then
                fillTable = ns.NAV_SELECTED_FILL
            elseif fillTable == ns.BTN_FILL_HOVER then
                fillTable = ns.NAV_HOVER_FILL
            end
        end
        ns.SetRoundedRectBorderFillColor(self, unpack(fillTable))
        self._efControlFillKind = ns.LIVE_FILL_NAMES[fillTable]
    end
    btn._efPaintState = PaintState
    btn:SetScript("OnEnter", function(self)
        if self:IsEnabled() then PaintState(self, ns.BTN_FILL_HOVER) end
    end)
    btn:SetScript("OnLeave", function(self)
        if self:IsEnabled() then PaintState(self, ns.BTN_FILL_NORMAL) end
    end)
    btn:SetScript("OnMouseDown", function(self)
        if self:IsEnabled() then PaintState(self, ns.BTN_FILL_PRESSED) end
    end)
    btn:SetScript("OnMouseUp", function(self)
        if not self:IsEnabled() then return end
        PaintState(self, self:IsMouseOver() and ns.BTN_FILL_HOVER or ns.BTN_FILL_NORMAL)
    end)
    btn:SetScript("OnDisable", function(self)
        PaintState(self, ns.BTN_FILL_DISABLED)
        -- A touch lighter than TEXT_DIM: disabled labels on the dark
        -- disabled pill were near-unreadable.
        if self._label and not self._efRedOn then self._label:SetTextColor(0.72, 0.72, 0.72, 1) end
    end)
    btn:SetScript("OnEnable", function(self)
        PaintState(self, ns.BTN_FILL_NORMAL)
        if self._label and not self._efRedOn then
            local theme = self._efLeafLabel and ns.Results and ns.Results.GetActiveTheme
                and ns.Results:GetActiveTheme()
            if theme and theme.leafColor then
                self._label:SetTextColor(theme.leafColor[1], theme.leafColor[2], theme.leafColor[3], 1)
            else
                self._label:SetTextColor(1, 1, 1, 1)
            end
        end
    end)

    if text then btn:SetText(text) end
    -- Its first paint again, now that it has its paint state: a button
    -- built inside a shown page hears no OnShow, so the Classic red waited
    -- for a hover or the page's next show.
    ns.PaintButtonRamp(btn)
    return btn
end
end

-- Thin two-stroke "X" close button (dim by default, white on hover), matching
-- the tutorial / what's-new windows. Two rotated 1px lines stay sharp at any
-- UI scale. Caller sets the OnClick handler.
local X_DEFAULT_HOVER = {1, 1, 1}
-- Resolve a close-X stroke color: an explicit SetXColors value wins,
-- otherwise the active theme's faint text at rest and readable text on
-- hover, so the stroke always dims-to-brightens. leaf/pathColorHover both
-- read near-white on the gradient dark themes (rest looked identical to
-- hover) and a plain white hover vanished on the light ones; faint->leaf
-- keeps a real contrast step on every theme. Neutral fallbacks pre-theme.
local function ResolveXColor(explicit, field, fallback)
    if explicit then return explicit end
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    return (theme and theme[field]) or fallback
end
-- A small revert-to-default arrow (the client's undo glyph); its owner
-- shows it only while the value differs from the default.
function ns.CreateRevertButton(parent, size, onClick, tip)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(size, size)
    local icon = btn:CreateTexture(nil, "OVERLAY")
    icon:SetAllPoints()
    icon:SetAtlas("common-icon-undo")
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetAtlas("common-icon-undo")
    hl:SetBlendMode("ADD")
    hl:SetAlpha(0.5)
    btn:SetScript("OnClick", onClick)
    Utils.AttachDelayedTooltip(btn, "ANCHOR_TOP", function() return tip or _G["RESET_TO_DEFAULT"] or "Reset to default" end)
    return btn
end

-- The 1.x dialog's iron divider (the Calendar's, the Reputation frame's),
-- at half its art's 16 px: end caps fixed, the middle stretched; vertical
-- runs it down a side.
function ns.CreateIronLine(parent, vertical)
    local ART, CAP, LEN, BAND, SIZE, CAP_PX = "Interface\\DialogFrame\\UI-DialogBox-Divider", 6 / 256, 193 / 256, 0.5, 8, 3
    local line = CreateFrame("Frame", nil, parent)
    local parts = {}
    for i, u in ipairs({ { 0, CAP }, { CAP, LEN - CAP }, { LEN - CAP, LEN } }) do
        local t = line:CreateTexture(nil, "ARTWORK")
        t:SetTexture(ART)
        if vertical then
            -- Its length down the side: u runs top to bottom, v across.
            t:SetTexCoord(u[1], 0, u[2], 0, u[1], BAND, u[2], BAND)
        else
            t:SetTexCoord(u[1], u[2], 0, BAND)
        end
        parts[i] = t
    end
    local a, b = vertical and "TOP" or "LEFT", vertical and "BOTTOM" or "RIGHT"
    for i, edge in ipairs({ a, b }) do
        local cap = parts[i == 1 and 1 or 3]
        cap:SetPoint(vertical and (edge .. "LEFT") or ("TOP" .. edge), line, vertical and (edge .. "LEFT") or ("TOP" .. edge))
        cap:SetPoint(vertical and (edge .. "RIGHT") or ("BOTTOM" .. edge), line, vertical and (edge .. "RIGHT") or ("BOTTOM" .. edge))
        if vertical then cap:SetHeight(CAP_PX) else cap:SetWidth(CAP_PX) end
    end
    parts[2]:SetPoint(vertical and "TOPLEFT" or "TOPLEFT", parts[1], vertical and "BOTTOMLEFT" or "TOPRIGHT")
    parts[2]:SetPoint(vertical and "BOTTOMRIGHT" or "BOTTOMRIGHT", parts[3], vertical and "TOPRIGHT" or "BOTTOMLEFT")
    if vertical then line:SetWidth(SIZE) else line:SetHeight(SIZE) end
    return line
end

ns.CloseXs = setmetatable({}, { __mode = "k" })
function ns.CreateCloseX(parent, size)
    size = size or 18
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(size, size)
    local function MakeStroke()
        local t = btn:CreateTexture(nil, "OVERLAY")
        t:SetTexture("Interface\\Buttons\\WHITE8x8")
        t:SetSize(size - 2, 1.5)
        t:SetPoint("CENTER")
        return t
    end
    local stroke1 = MakeStroke(); stroke1:SetRotation(math.pi / 4)
    local stroke2 = MakeStroke(); stroke2:SetRotation(-math.pi / 4)
    local function setX(r, g, b)
        stroke1:SetVertexColor(r, g, b, 1)
        stroke2:SetVertexColor(r, g, b, 1)
    end
    -- _xRest/_xHover stay nil by default so the stroke follows the active
    -- theme (faint at rest, readable on hover); SetXColors lets a panel pin
    -- explicit colors. Read live at paint time, so a flip repaints on the
    -- next hover, and a themed panel's own repaint can force it sooner.
    local function paintRest() setX(Utils.RGB(ResolveXColor(btn._xRest, "textFaint", ns.TEXT_DIM))) end
    local function paintHover() setX(Utils.RGB(ResolveXColor(btn._xHover, "leafColor", X_DEFAULT_HOVER))) end
    paintRest()
    btn:SetScript("OnEnter", paintHover)
    btn:SetScript("OnLeave", paintRest)
    btn.SetXColors = function(_, rest, hover)
        btn._xRest = rest
        btn._xHover = hover
        if btn:IsMouseOver() then paintHover() else paintRest() end
    end
    ns.CloseXs[btn] = true
    return btn
end

-- A theme change repaints every X in its new colors.
function ns.RetintCloseXs()
    for btn in pairs(ns.CloseXs) do btn:SetXColors(btn._xRest, btn._xHover) end
end

-- Read-only feel for the export code box: user keystrokes revert to the
-- canonical text and reselect it, so the Ctrl-C content can't be mangled
-- by an accidental keypress. Pass nil to make the box editable again
-- (the import flow reuses the box).
function Utils.SetEditBoxReadOnlyText(editBox, text)
    if not editBox._efReadOnlyHooked then
        editBox._efReadOnlyHooked = true
        editBox:HookScript("OnTextChanged", function(self, userInput)
            local canonical = self._efReadOnlyText
            if userInput and canonical and self:GetText() ~= canonical then
                self:SetText(canonical)
                self:HighlightText()
            end
        end)
        -- A read-only box always copies its full text, so the selection
        -- must always SHOW that: clicking inside would normally drop the
        -- highlight to place a cursor; restore it immediately.
        editBox:HookScript("OnMouseUp", function(self)
            if self._efReadOnlyText then self:HighlightText() end
        end)
    end
    editBox._efReadOnlyText = text
    if text then editBox:SetText(text) end
end

-- ESC-close WITHOUT UISpecialFrames. Inserting an addon frame's name into
-- UISpecialFrames poisons Blizzard's CloseWindows for the whole session:
-- the secure walker reads the addon-created global by name and its
-- execution turns tainted from that point (taint.log: "Execution tainted
-- by EasyFind while reading global EasyFindEscCatcher"), which then
-- spreads through panel and action-bar bookkeeping and detonates in
-- combat as ADDON_ACTION_BLOCKED and secret-value errors. Instead, while
-- any registered EasyFind frame is shown, hold a transient ESCAPE
-- override bind onto a hidden dispatch button that closes the top-most
-- (most recently shown) one. LIFO matches how stacked popups should eat
-- ESC. A focused EditBox still consumes ESC first (focus outranks
-- bindings), so focused-ESC behavior is untouched. Override bindings can
-- only change out of combat: PLAYER_REGEN_DISABLED's grace window drops
-- the bind for the fight and REGEN_ENABLED re-arms it.
local escStack = {}
local escOwner, escDispatch
-- Whether the ESCAPE override is currently bound. Binding writes are
-- dedup'd against it: redundant writes near the combat boundary put
-- Blizzard's key re-attach pass on EasyFind's execution and detonate
-- protected bar updates (PetActionBar:SetShownBase autopsy).
local escArmed = false
local SetOverrideBindingClick = SetOverrideBindingClick
local ClearOverrideBindings = ClearOverrideBindings

local function EscArm()
    if not escOwner or InCombatLockdown() then return end
    -- An entry only wants ESC while its shouldEat predicate (if any)
    -- passes. Always Show registers the search bar with a predicate that
    -- is false when nothing is dismissable, so the override is not bound
    -- at all and a bare ESC reaches the game (zero keyboard capture
    -- outside explicit UI state).
    local wantArmed = false
    for i = #escStack, 1, -1 do
        local entry = escStack[i]
        -- pcall fail-open: a broken predicate must never leave ESC bound
        -- (captured input is worse than a missed close).
        local wants = true
        if entry.shouldEat then
            local ok, eat = pcall(entry.shouldEat)
            wants = ok and eat and true or false
        end
        if wants then
            wantArmed = true
            break
        end
    end
    if wantArmed == escArmed then return end
    if wantArmed then
        -- escOwner only ever holds this one binding, so the rebind
        -- overwrites in place; no clear-first needed.
        SetOverrideBindingClick(escOwner, true, "ESCAPE", "EasyFindEscDispatch")
    else
        ClearOverrideBindings(escOwner)
    end
    escArmed = wantArmed
end

-- Release the ESCAPE override immediately. Used when a dispatch turns out to
-- have nothing to close: holding a binding that does nothing swallows the key
-- forever (measured: six presses in a row reported "our
-- override owned the key" with zero state change, and ESC stayed ours even
-- with a Blizzard panel open). A missed close is recoverable; a dead ESC is
-- not, so we always hand the key back and let EscArm re-take it when real
-- dismissable state reappears.
local function EscDisarm()
    if not escOwner or not escArmed or InCombatLockdown() then return end
    ClearOverrideBindings(escOwner)
    escArmed = false
end

-- Re-evaluate the ESC override after a shouldEat input changes while the
-- owning frame stays shown (menus or results opening and closing).
function Utils.RefreshEscArm()
    EscArm()
end

-- Dev probe surface: who owns ESCAPE right now.
-- Read-only; returns the armed flag plus one record per stack entry.
function ns.GetEscOverrideState()
    local entries = {}
    for i = 1, #escStack do
        local e = escStack[i]
        local wants, err = true, nil
        if e.shouldEat then
            local ok, eat = pcall(e.shouldEat)
            wants = ok and eat and true or false
            if not ok then err = tostring(eat) end
        end
        entries[i] = {
            name = (e.frame and e.frame.GetName and e.frame:GetName())
                or tostring(e.frame),
            shown = e.frame and e.frame:IsShown() or false,
            wants = wants,
            err = err,
        }
    end
    return escArmed, entries
end

local function EscRemove(frame)
    for i = #escStack, 1, -1 do
        if escStack[i].frame == frame then tremove(escStack, i) end
    end
end

local function EnsureEscDispatch()
    if escOwner then return end
    escOwner = CreateFrame("Frame", nil, UIParent)
    -- Kept shown (1px offscreen corner) like the shortkey pool: the
    -- binding must always have a clickable target.
    escDispatch = CreateFrame("Button", "EasyFindEscDispatch", UIParent)
    escDispatch:SetSize(1, 1)
    escDispatch:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
    escDispatch:SetScript("OnClick", function()
        -- Top-most entry that currently wants ESC; entries whose
        -- predicate is false (or errors, pcall fail-open) never block a
        -- lower one.
        for i = #escStack, 1, -1 do
            local entry = escStack[i]
            local wants = true
            if entry.shouldEat then
                local ok, eat = pcall(entry.shouldEat)
                wants = ok and eat and true or false
            end
            if wants then
                -- close() reports whether it actually dismissed anything. A
                -- predicate that keeps claiming ESC while its close is a
                -- no-op would eat every press forever, so a false (or an
                -- erroring) close hands the key straight back.
                local ok, handled = pcall(entry.close)
                if not ok or handled == false then EscDisarm() end
                return
            end
        end
        -- Nothing wanted it: we should not have held the binding at all.
        EscDisarm()
    end)
    escOwner:RegisterEvent("PLAYER_REGEN_DISABLED")
    escOwner:RegisterEvent("PLAYER_REGEN_ENABLED")
    escOwner:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then
            if escArmed then
                ClearOverrideBindings(escOwner)
                escArmed = false
            end
        else
            EscArm()
        end
    end)
end

-- Other keys held the same way, one owner apart from ESCAPE's: DELETE
-- while the Notes list has a selection. wants() says when; press() acts,
-- false handing the key straight back. Out of combat only, dedup'd per
-- key, dropped for a fight and re-armed after it.
do
local heldKeys, heldOwner = {}, nil
local function HeldArm()
    if not heldOwner or InCombatLockdown() then return end
    local changed = false
    for _, h in pairs(heldKeys) do
        local ok, want = pcall(h.wants)
        h.want = ok and want and true or false
        if h.want ~= h.armed then changed = true end
    end
    if not changed then return end
    -- The owner's bindings are rewritten as one: cleared, then each key
    -- still wanted bound again.
    ClearOverrideBindings(heldOwner)
    for key, h in pairs(heldKeys) do
        if h.want then SetOverrideBindingClick(heldOwner, true, key, h.button:GetName()) end
        h.armed = h.want
    end
end
function Utils.HoldKey(key, wants, press)
    if not heldOwner then
        heldOwner = CreateFrame("Frame", nil, UIParent)
        heldOwner:RegisterEvent("PLAYER_REGEN_DISABLED")
        heldOwner:RegisterEvent("PLAYER_REGEN_ENABLED")
        heldOwner:SetScript("OnEvent", function(_, event)
            if event == "PLAYER_REGEN_DISABLED" then
                ClearOverrideBindings(heldOwner)
                for _, h in pairs(heldKeys) do h.armed = false end
            else
                HeldArm()
            end
        end)
    end
    local h = heldKeys[key]
    if not h then
        h = { button = CreateFrame("Button", "EasyFindHeldKey" .. key, UIParent), armed = false }
        h.button:SetSize(1, 1)
        h.button:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
        h.button:SetScript("OnClick", function()
            local ok, handled = pcall(h.press)
            -- A press that did nothing hands the key back until wanted anew.
            if (not ok or handled == false) and not InCombatLockdown() then
                ClearOverrideBindings(heldOwner)
                for _, other in pairs(heldKeys) do other.armed = false end
                h.wants = function() return false end
            end
        end)
        heldKeys[key] = h
    end
    h.wants, h.press = wants, press
    HeldArm()
end
function Utils.RefreshHeldKeys()
    HeldArm()
end
end

-- Register frame so ESC closes it (via close()) while it is shown.
-- close defaults to hiding the frame. shouldEat (optional) is consulted
-- at arm time and at dispatch: false means this entry neither binds nor
-- consumes ESC right now. Callers whose predicate inputs change while
-- the frame stays shown must call Utils.RefreshEscArm() on those changes.
-- Strip WoW display markup for plain-text surfaces (autocomplete
-- suggestions, snippet previews): atlas / texture / color / hyperlink codes
-- go, a link keeps its bracketed display text. Covers both the legacy
-- |cffRRGGBB color form and the modern |cnColorName: form; without this a
-- byte-length truncation can cut inside an escape and render as nothing.
-- Text bound for the OS clipboard: the client escapes every "|" on paste
-- (anti-injection), so live escapes -- item links above all -- can never
-- survive a Ctrl+C/Ctrl+V round trip; they paste as literal |H garbage.
-- Flatten links to their display text and drop the paint, KEEPING line
-- structure (StripMarkup below is the one-line normalizer built on this;
-- the markup grammar lives here once).
function Utils.ClipboardSafeText(s)
    if not s then return s end
    s = s:gsub("|A:[^|]*|a", "")
    s = s:gsub("|T[^|]*|t", "")
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:|]*:", ""):gsub("|r", "")
    s = s:gsub("|H[^|]+|h(.-)|h", "%1")
    return s
end

-- Named colors (|cnIQ1:, |cnGREEN_FONT_COLOR:) as |cffRRGGBB, for an
-- EditBox: it reads |c and the next eight characters as a hex color, so a
-- named one ate the start of the link behind it (a note read "tem:2589...").
function Utils.HexColorNames(s)
    if type(s) ~= "string" or not s:find("|cn", 1, true) then return s end
    return (s:gsub("|cn([^:|]+):", function(name)
        local q = tonumber(name:match("^IQ(%d+)$"))
        local quality = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
        local hex = quality and quality.hex and quality.hex:match("^|c(%x%x%x%x%x%x%x%x)")
        if not hex then
            local color = _G[name]
            hex = type(color) == "table" and color.GenerateHexColor and color:GenerateHexColor() or nil
        end
        return "|c" .. (hex or "ffffffff")
    end))
end

function Utils.StripMarkup(s)
    s = Utils.ClipboardSafeText(s)
    if not s then return s end
    s = s:gsub("%s+", " ")
    s = s:match("^%s*(.-)%s*$") or s
    return s
end

-- The link the flattened clipboard text stands for rides alongside in
-- memory: every Ctrl+C site that copies ClipboardSafeText(link) stashes the
-- pair, and a chat editbox that receives EXACTLY that text as one inserted
-- chunk (a paste, never typing) swaps the real link back in place. Chat
-- gets a live link, anything outside the game keeps the readable name.
do
local sbyte = string.byte
local pastePlain, pasteLink

function Utils.StashClipboardLink(plain, link)
    if not link or plain == link then
        pastePlain, pasteLink = nil, nil
        return
    end
    pastePlain, pasteLink = plain, link
end

-- Tracks every text state (addon SetText included) so "previous text" is
-- always the box's real prior content; only user changes can be a paste.
-- A chunk arriving in one change with the caret at its end is a paste (or
-- an input method committing a phrase). Reported to whoever listens (the
-- clipboard history companion); the change itself is untouched.
local function ReportPastedChunk(editBox, prev, text)
    if not Utils.OnPasteChunk or not prev or #text <= #prev + 1 then return end
    local caret = editBox:GetCursorPosition() or 0
    local added = #text - #prev
    if caret < added then return end
    local prefix, suffix = ssub(text, 1, caret - added), ssub(text, caret + 1)
    if prev ~= prefix .. suffix then return end
    Utils.OnPasteChunk(editBox, ssub(text, caret - added + 1, caret))
end

local function SwapPastedLink(editBox, userInput)
    local prev = editBox._efPrevText
    local text = editBox:GetText()
    editBox._efPrevText = text
    if not userInput or not prev then return end
    ReportPastedChunk(editBox, prev, text)
    if not pastePlain then return end
    local caret = editBox:GetCursorPosition() or 0
    local plainLen = #pastePlain
    if caret < plainLen or sbyte(text, caret) ~= sbyte(pastePlain, plainLen) then return end
    if ssub(text, caret - plainLen + 1, caret) ~= pastePlain then return end
    local prefix, suffix = ssub(text, 1, caret - plainLen), ssub(text, caret + 1)
    if prev ~= prefix .. suffix then return end
    local newText = prefix .. pasteLink .. suffix
    local maxLetters = editBox:GetMaxLetters()
    if maxLetters and maxLetters > 0 and #newText > maxLetters then return end
    editBox._efPrevText = newText
    editBox:SetText(newText)
    editBox:SetCursorPosition(#prefix + #pasteLink)
end

-- Ctrl+C in an edit box copies its highlighted text; the game exposes no
-- clipboard and no selection getter, so the selection is found the one
-- way there is: a frame after the chord (the native copy has landed by
-- then), the highlight is replaced with nothing, what vanished is the
-- selection, and the text and highlight are put back as they were. The
-- macro body is never touched (an addon-written body is a tainted
-- pending value for the protected macro save), so there the whole body
-- is reported instead. Reported to whoever listens (the clipboard
-- history companion).
local function ReportCopiedSelection(editBox)
    if not Utils.OnClipboardCopied or not editBox:IsShown() then return end
    local full = editBox:GetText()
    if not full or full == "" then return end
    if editBox._efSnippetMacroBox or editBox == _G["MacroFrameText"] then
        Utils.OnClipboardCopied(full, nil, nil)
        return
    end
    local cursor = editBox:GetCursorPosition() or 0
    editBox:Insert("")
    local after = editBox:GetText()
    if after == full then return end   -- nothing highlighted: nothing was copied
    local removed = #full - #after
    local selStart = editBox:GetCursorPosition() or 0
    local selected = ssub(full, selStart + 1, selStart + removed)
    editBox:SetText(full)
    editBox:SetCursorPosition(cursor)
    editBox:HighlightText(selStart, selStart + removed)
    if selected ~= "" then Utils.OnClipboardCopied(selected, nil, nil) end
end

-- The copy report alone, for boxes that only ever hand text out (the
-- game's own copy dialogs: Copy Character Name and the like live in the
-- static popups' edit boxes).
function Utils.AttachCopyWatch(editBox)
    if not editBox or editBox._efCopyWatch then return end
    editBox._efCopyWatch = true
    editBox:HookScript("OnKeyDown", function(self, key)
        if key ~= "C" or not IsControlKeyDown() then return end
        Utils.SafeAfter(0, function() ReportCopiedSelection(self) end)
    end)
end

-- One attach per chat or macro box: the paste swap (and paste report) on
-- text changes, and the copy report on Ctrl+C.
function Utils.AttachPasteLinkSwap(editBox)
    if not editBox or editBox._efPasteSwap then return end
    editBox._efPasteSwap = true
    editBox._efPrevText = editBox:GetText()
    editBox:HookScript("OnTextChanged", SwapPastedLink)
    Utils.AttachCopyWatch(editBox)
end
end

-- One owner for "hook Blizzard's insert-link routing" (shift-clicked items,
-- achievements, spells). 12.1 routes these through ChatFrameUtil.InsertLink;
-- the legacy ChatEdit_InsertLink global still exists but no longer sees the
-- call (probe-verified), so hooking it catches nothing on live clients.
function Utils.HookInsertLink(fn)
    if not hooksecurefunc then return end
    if ChatFrameUtil and type(ChatFrameUtil.InsertLink) == "function" then
        hooksecurefunc(ChatFrameUtil, "InsertLink", fn)
    else
        hooksecurefunc("ChatEdit_InsertLink", fn)
    end
end

-- ONE rule for text color on themed dialog chrome (labels, hints): theme
-- leaf on dark fills, the darker hover accent on light fills. Gold is
-- never correct on themed fills.
function ns.TooltipTextColor(frame)
    local theme = ns.ThemeSetOf and ns.ThemeSetOf(frame).theme
        or (ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme())
    if theme and theme.lightTheme then
        local c = theme.pathColorHover or theme.leafColor
        return c[1], c[2], c[3]
    end
    local c = (theme and theme.leafColor) or { 1, 1, 1 }
    return c[1], c[2], c[3]
end

-- The addon's own messaging tooltip: one pooled panel for hints,
-- explanations and hover help, so they never ride Blizzard's GameTooltip
-- (that stays for real item, spell and achievement tooltips). It is
-- deliberately NOT a menu panel: menus are clickable, this is a label,
-- and its own grammar keeps the two apart at a glance: a notch pointing
-- at the owner, a solid surface pushed away from the window fill with a
-- hairline ring and tighter corners, a small gap from the owner, a short
-- fade-in, and no mouse. Title in the shared tooltip text color with a
-- rule under it, body in the theme's reading tone, an optional dim note;
-- the panel matches the owner's scale and hides only for the owner that
-- showed it. Anchors use GameTooltip's vocabulary (ANCHOR_RIGHT,
-- ANCHOR_TOP, ...): a side name places the panel beside or above/below
-- the owner, centered on it; a corner name aligns that edge instead.
do
local tip
local MAX_W = 280
local PAD_X, PAD_Y = 12, 10
local GAP = 7            -- owner edge to panel edge; the notch spans it
local NOTCH = 9          -- square side; turned 45 degrees, ~6px shows
local NOTCH_INSET = 12   -- how close to a corner the notch may sit
local CORNER = 6         -- tighter than the menus' 10
-- anchor -> panel point, owner point, x, y, notch edge
local ANCHORS = {
    ANCHOR_RIGHT       = { "LEFT",        "RIGHT",       GAP,  0,   "LEFT" },
    ANCHOR_LEFT        = { "RIGHT",       "LEFT",       -GAP,  0,   "RIGHT" },
    ANCHOR_TOP         = { "BOTTOM",      "TOP",         0,    GAP, "BOTTOM" },
    ANCHOR_TOPRIGHT    = { "BOTTOMRIGHT", "TOPRIGHT",    0,    GAP, "BOTTOM" },
    ANCHOR_TOPLEFT     = { "BOTTOMLEFT",  "TOPLEFT",     0,    GAP, "BOTTOM" },
    ANCHOR_BOTTOM      = { "TOP",         "BOTTOM",      0,   -GAP, "TOP" },
    ANCHOR_BOTTOMRIGHT = { "TOPRIGHT",    "BOTTOMRIGHT", 0,   -GAP, "TOP" },
    ANCHOR_BOTTOMLEFT  = { "TOPLEFT",     "BOTTOMLEFT",  0,   -GAP, "TOP" },
}

-- Surface colors: the window fill pushed away from the text (darker on
-- dark themes, deeper on light ones) at full opacity, so the panel reads
-- as a floating label above the UI and never as a sibling of the menus.
-- The ring is the theme's border color.
local function SurfaceColors(theme)
    local pal = ns.ACTIVE_UI_PALETTE
    local base = (pal and pal.windowFill) or ns.SEARCH_WINDOW_FILL_COLOR
    local k = (theme and theme.lightTheme) and 0.86 or 0.55
    local ring = theme and theme.resultsBackdropBorderColor
    local rr, rg, rb = 0.42, 0.42, 0.42
    if ring then rr, rg, rb = ring[1], ring[2], ring[3] end
    return base[1] * k, base[2] * k, base[3] * k, rr, rg, rb
end

local function PaintHintTooltip(self)
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    local light = theme and theme.lightTheme
    local r, g, b, rr, rg, rb = SurfaceColors(theme)
    ns.SetRoundedRectFill(self, r, g, b, 1)
    ns.SetRoundedRectFill(self.ring, rr, rg, rb, 1, true)
    self.notch:SetColorTexture(r, g, b, 1)
    self.ringNotch:SetColorTexture(rr, rg, rb, 1)
    self.title:SetTextColor(ns.TooltipTextColor())
    local body = light and theme.leafColor or ns.TEXT_PRIMARY
    self.body:SetTextColor(body[1], body[2], body[3], 1)
    local note = light and (theme.textFaint or theme.leafColor) or ns.TEXT_DIM
    self.note:SetTextColor(note[1], note[2], note[3], 1)
    local shadow = 0   -- flat text on either polarity
    self.title:SetShadowColor(0, 0, 0, shadow)
    self.body:SetShadowColor(0, 0, 0, shadow)
    self.note:SetShadowColor(0, 0, 0, shadow)
    -- The rule under the title wears the menu separator color.
    local sep = theme and theme.separatorColor
    if sep then
        self.sep:SetColorTexture(sep[1], sep[2], sep[3], sep[4] or 0.35)
    else
        self.sep:SetColorTexture(1, 1, 1, 0.18)
    end
end

-- The hint tooltip's level: a raised menu stays under it, or its rows'
-- hints draw behind it (the GPS window's settings flyout).
Utils.HINT_LEVEL = 9999

function Utils.RaiseMenu(frame)
    frame:Raise()
    if frame:GetFrameLevel() > Utils.HINT_LEVEL - 50 then frame:SetFrameLevel(Utils.HINT_LEVEL - 50) end
end

local function EnsureHintTooltip()
    if tip then return tip end
    tip = CreateFrame("Frame", "EasyFindHintTooltip", UIParent, "BackdropTemplate")
    tip:SetFrameStrata("TOOLTIP")
    tip:SetFrameLevel(Utils.HINT_LEVEL)
    tip:SetClampedToScreen(true)
    tip:EnableMouse(false)   -- a label: the mouse passes straight through
    ns.CreateRoundedRectBorder(tip)
    ns.SetRoundedRectBarHeight(tip, CORNER)
    ns.SetRoundedRectBorderEdgeShown(tip, false)
    -- The notch: a square in the fill color turned 45 degrees, drawn
    -- under the (opaque) fill so only the half outside the panel shows.
    tip.notch = tip:CreateTexture(nil, "BACKGROUND", nil, -1)
    tip.notch:SetSize(NOTCH, NOTCH)
    tip.notch:SetRotation(math.pi / 4)
    -- The edge: the same shape 1 px wider in the ring color, under it (the
    -- art's ring is gone at this corner size).
    tip.ring = CreateFrame("Frame", nil, tip)
    tip.ring:SetPoint("TOPLEFT", tip, "TOPLEFT", -1, 1)
    tip.ring:SetPoint("BOTTOMRIGHT", tip, "BOTTOMRIGHT", 1, -1)
    tip.ring:SetFrameLevel(Utils.HINT_LEVEL - 1)
    ns.CreateRoundedRectBorder(tip.ring)
    ns.SetRoundedRectBorderEdgeShown(tip.ring, false)
    ns.SetRoundedRectBorderBgAlpha(tip.ring, 1)
    ns.SetRoundedRectBarHeight(tip.ring, CORNER + 2)
    tip.ringNotch = tip.ring:CreateTexture(nil, "BACKGROUND")
    tip.ringNotch:SetSize(NOTCH + 2, NOTCH + 2)
    tip.ringNotch:SetRotation(math.pi / 4)
    tip.ringNotch:SetPoint("CENTER", tip.notch, "CENTER")
    tip.title = tip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tip.body = tip:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    tip.note = tip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    -- A 1px rule between the title and the text below it, so the
    -- header reads as a header when the body runs long.
    tip.sep = tip:CreateTexture(nil, "ARTWORK")
    tip.sep:SetHeight(1)
    for _, fs in ipairs({ tip.title, tip.body, tip.note }) do
        fs._efOwnColor = true
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        fs:SetWordWrap(true)
        fs:SetNonSpaceWrap(false)
    end
    -- The fade-in: menus pop, labels arrive.
    tip.fade = tip:CreateAnimationGroup()
    local alpha = tip.fade:CreateAnimation("Alpha")
    alpha:SetFromAlpha(0)
    alpha:SetToAlpha(1)
    alpha:SetDuration(0.1)
    tip:Hide()
    return tip
end

-- Natural (unwrapped) width of a wrapping FontString, with a pixel to
-- spare: a box at exactly the measured width wraps its last word.
local function NaturalWidth(fs)
    fs:SetWidth(0)
    local w = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth() or 0
    return w + 1
end

-- Puts the notch on `edge`, at the owner's center projected onto that
-- edge (kept away from the corners), half hidden behind the panel.
-- Reads the resolved rectangles, so it runs after the panel is shown.
local function PlaceNotch(t, owner, edge)
    local n = t.notch
    n:ClearAllPoints()
    if not edge then n:Hide(); return end
    local w, h = t:GetWidth(), t:GetHeight()
    local ocx, ocy = owner:GetCenter()
    local left, bottom = t:GetLeft(), t:GetBottom()
    if not (ocx and ocy and left and bottom) then n:Hide(); return end
    if edge == "LEFT" or edge == "RIGHT" then
        local y = mmax(NOTCH_INSET, mmin(h - NOTCH_INSET, ocy - bottom))
        n:SetPoint("CENTER", t, "BOTTOM" .. edge, 0, y)
    else
        local x = mmax(NOTCH_INSET, mmin(w - NOTCH_INSET, ocx - left))
        n:SetPoint("CENTER", t, edge .. "LEFT", x, 0)
    end
    n:Show()
end

-- The first anchor in `order` whose panel (pw by ph) fits on the screen
-- (sw by sh) beside the owner's rect (left, bottom, width, height), all in
-- one unit; the first when none does. A side with no room was clamped back
-- over the owner: the very row being read about.
function Utils.HintSide(order, l, b, w, h, pw, ph, gap, sw, sh)
    for i = 1, #order do
        local a = order[i]
        local fits
        if a == "ANCHOR_LEFT" then
            fits = l - gap - pw >= 0
        elseif a == "ANCHOR_RIGHT" then
            fits = l + w + gap + pw <= sw
        elseif a:find("^ANCHOR_TOP") then
            fits = b + h + gap + ph <= sh
        else
            fits = b - gap - ph >= 0
        end
        if fits then return a end
    end
    return order[1]
end

-- An anchor's fallbacks: its mirror, then above, then below (or for one
-- above or below, the other, then right, then left).
local HINT_ORDER = {
    ANCHOR_RIGHT = { "ANCHOR_RIGHT", "ANCHOR_LEFT", "ANCHOR_TOP", "ANCHOR_BOTTOM" },
    ANCHOR_LEFT = { "ANCHOR_LEFT", "ANCHOR_RIGHT", "ANCHOR_TOP", "ANCHOR_BOTTOM" },
    ANCHOR_TOP = { "ANCHOR_TOP", "ANCHOR_BOTTOM", "ANCHOR_RIGHT", "ANCHOR_LEFT" },
    ANCHOR_BOTTOM = { "ANCHOR_BOTTOM", "ANCHOR_TOP", "ANCHOR_RIGHT", "ANCHOR_LEFT" },
}

-- anchor: an ANCHOR_ name, or a list of them in order of preference; the
-- first whose side has room is used (HintSide).
function ns.ShowHintTooltip(owner, anchor, title, body, note)
    if not owner or (not title and not body) then return end
    local t = EnsureHintTooltip()
    local wasShown = t:IsShown()
    t._owner = owner
    t.title:SetText(title or "")
    t.body:SetText(body or "")
    t.note:SetText(note or "")
    local w = 0
    if title then w = mmax(w, NaturalWidth(t.title)) end
    if body then w = mmax(w, NaturalWidth(t.body)) end
    if note then w = mmax(w, NaturalWidth(t.note)) end
    w = mmin(MAX_W, mceil(w))
    t._w = w
    t.title:SetWidth(w)
    t.body:SetWidth(w)
    t.note:SetWidth(w)
    local y = -PAD_Y
    local blocks = {}
    if title then blocks[#blocks + 1] = t.title end
    if body then blocks[#blocks + 1] = t.body end
    if note then blocks[#blocks + 1] = t.note end
    for _, fs in ipairs({ t.title, t.body, t.note }) do
        fs:ClearAllPoints()
        fs:Hide()
    end
    t.sep:ClearAllPoints()
    t.sep:Hide()
    local rule = title and (body or note)
    for i = 1, #blocks do
        local fs = blocks[i]
        fs:SetPoint("TOPLEFT", t, "TOPLEFT", PAD_X, y)
        fs:Show()
        y = y - mceil(fs:GetStringHeight())
        if fs == t.title and rule then
            y = y - 5
            t.sep:SetPoint("TOPLEFT", t, "TOPLEFT", PAD_X, y)
            t.sep:SetWidth(w)
            t.sep:Show()
            y = y - 1 - 6
        else
            y = y - (fs == t.title and 4 or 6)
        end
    end
    t:SetSize(w + PAD_X * 2, -y - 6 + PAD_Y)
    -- Read at the owner's size: menus and the search panel scale with the
    -- user's UI scale setting, the tooltip beside them must too.
    local ownerScale = owner.GetEffectiveScale and owner:GetEffectiveScale()
    if ownerScale and ownerScale > 0 then
        t:SetScale(ownerScale / UIParent:GetEffectiveScale())
    else
        t:SetScale(1)
    end
    t:ClearAllPoints()
    local edge
    if anchor == "ANCHOR_CURSOR" then
        local scale = t:GetEffectiveScale()
        local x, cy = GetCursorPosition()
        t:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / scale + 12, cy / scale + 12)
    else
        local side = type(anchor) == "table" and anchor[1] or anchor
        local order = type(anchor) == "table" and anchor or HINT_ORDER[anchor]
        local ol, ob, ow, oh = owner:GetRect()
        if order and ol then
            -- The owner's rect and the panel's size in UIParent units.
            local k = (ownerScale and ownerScale > 0 and ownerScale or 1) / UIParent:GetEffectiveScale()
            side = Utils.HintSide(order, ol * k, ob * k, ow * k, oh * k, t:GetWidth() * k, t:GetHeight() * k,
                GAP * k, UIParent:GetWidth(), UIParent:GetHeight())
        end
        local a = ANCHORS[side] or ANCHORS.ANCHOR_RIGHT
        t:SetPoint(a[1], owner, a[2], a[3], a[4])
        edge = a[5]
    end
    PaintHintTooltip(t)
    t:Show()
    PlaceNotch(t, owner, edge)
    -- Fade in on arrival only; moving between owners keeps it steady.
    if not wasShown then
        t.fade:Stop()
        t.fade:Play()
    end
    -- A font's first use after a reload measures short until it has drawn
    -- once (the box came out a word too narrow): measure again next frame
    -- and lay out anew when the width moved.
    if not t._remeasuring then
        local token = (t._layoutToken or 0) + 1
        t._layoutToken = token
        Utils.SafeAfter(0, function()
            if t._layoutToken ~= token or t._owner ~= owner or not t:IsShown() then return end
            local w2 = 0
            if title then w2 = mmax(w2, NaturalWidth(t.title)) end
            if body then w2 = mmax(w2, NaturalWidth(t.body)) end
            if note then w2 = mmax(w2, NaturalWidth(t.note)) end
            if mmin(MAX_W, mceil(w2)) == t._w then
                t.title:SetWidth(t._w)
                t.body:SetWidth(t._w)
                t.note:SetWidth(t._w)
                return
            end
            t._remeasuring = true
            ns.ShowHintTooltip(owner, anchor, title, body, note)
            t._remeasuring = nil
        end)
    end
end

-- Hides only when `owner` (or nothing) is the frame that showed it, so a
-- late OnLeave from one control never kills another's tooltip.
function ns.HideHintTooltip(owner)
    if not tip then return end
    if owner and tip._owner ~= owner then return end
    tip._owner = nil
    tip.fade:Stop()
    tip:Hide()
end

function ns.IsHintTooltipOwned(owner)
    return tip ~= nil and tip:IsShown() and tip._owner == owner
end
end

-- Ctrl-C confirmation shared by the copy dialogs. Addons cannot read the
-- clipboard, but a focused editbox fires OnKeyDown for the copy chord, so a
-- detected Ctrl+C flashes "Copied" (title color) and fades it out. The flash
-- holder is created on `parent` and hangs centered under `anchorTo`; returns
-- the holder so callers can include its height in dialog sizing.
function Utils.AttachCopiedFlash(editBox, parent, anchorTo, yOffset)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetPoint("TOP", anchorTo, "BOTTOM", 0, yOffset or -4)
    holder:SetSize(140, 16)
    holder:Hide()
    local copied = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    copied._efOwnColor = true
    copied:SetPoint("CENTER")
    copied:SetText(L["COPIED"])
    local copiedFade = holder:CreateAnimationGroup()
    local fadeAnim = copiedFade:CreateAnimation("Alpha")
    fadeAnim:SetFromAlpha(1)
    fadeAnim:SetToAlpha(0)
    fadeAnim:SetStartDelay(0.8)
    fadeAnim:SetDuration(0.8)
    copiedFade:SetScript("OnFinished", function() holder:Hide() end)
    editBox:SetScript("OnKeyDown", function(_, key)
        if key ~= "C" or not IsControlKeyDown() then return end
        copiedFade:Stop()
        holder:SetAlpha(1)
        holder:Show()
        copiedFade:Play()
    end)
    return holder
end

function Utils.AttachEscClose(frame, close, shouldEat)
    EnsureEscDispatch()
    close = close or function() frame:Hide() end
    frame:HookScript("OnShow", function()
        EscRemove(frame)
        escStack[#escStack + 1] = { frame = frame, close = close, shouldEat = shouldEat }
        EscArm()
    end)
    frame:HookScript("OnHide", function()
        EscRemove(frame)
        EscArm()
    end)
    if frame:IsShown() then
        escStack[#escStack + 1] = { frame = frame, close = close, shouldEat = shouldEat }
        EscArm()
    end
end
ns.AttachEscClose = function(frame, close, shouldEat) return Utils.AttachEscClose(frame, close, shouldEat) end

-- Hidden clipboard box. WoW has no set-clipboard API: a copy is a focused
-- editbox with the payload selected receiving the user's HARDWARE Ctrl+C.
-- One hidden box serves every copy site. Arm fills, selects, and focuses
-- it; the chord that lands is the native copy, paired with its live link
-- for the chat paste swap. The client decides how a copy is confirmed and
-- whether a focus steal mid-arm is fought (a row hover holding Ctrl) or
-- ends the arm (a one-shot prompt): { OnCopied = fn, HoldsFocus = fn ->
-- bool, OnDisarm = fn, OnKey = fn(key), OnCtrlUp = fn }. OnKey receives
-- every other non-modifier key the focused box would otherwise swallow;
-- OnCtrlUp fires when Ctrl is released over the box (see its OnKeyUp).
-- The frame focus is borrowed from carries _efClipboardHold until the
-- borrow ends, so its own focus handlers can treat the round trip as a
-- no-op (the search bar keeps its text, suffix and selection).
do
local box, client, clientLink, prevFocus

function Utils.DisarmClipboardBox(restoreFocus, who)
    if not client or (who and client ~= who) then return end
    local outgoing = client
    client, clientLink = nil, nil
    if box then box:ClearFocus() end
    local owner = prevFocus
    prevFocus = nil
    if owner then
        if restoreFocus and owner.SetFocus and owner:IsVisible() then
            -- The owner's focus-gained handler still sees the hold, so it
            -- keeps its text and selection exactly as they were.
            owner:SetFocus()
        elseif owner.StripAutocomplete then
            -- Focus is not coming back: drop the suffix the hold kept.
            owner:StripAutocomplete()
        end
        owner._efClipboardHold = nil
    end
    if outgoing.OnDisarm then outgoing.OnDisarm() end
end

local function EnsureClipboardBox()
    if box then return box end
    box = CreateFrame("EditBox", "EasyFindClipboardBox", UIParent)
    box:SetAutoFocus(false)
    -- Multi-line, so a copied transcript keeps its line breaks.
    box:SetMultiLine(true)
    box:SetSize(1, 1)
    box:SetPoint("TOP", UIParent, "TOP", 0, 30)
    box:SetAlpha(0)
    box:EnableMouse(false)
    box:SetScript("OnKeyDown", function(self, key)
        if not client then return end
        if (key == "C" or key == "c") and IsControlKeyDown() then
            Utils.StashClipboardLink(self:GetText(), clientLink)
            -- The one moment a copy is known to have landed: the clipboard
            -- history companion records it from here.
            if Utils.OnClipboardCopied then
                Utils.OnClipboardCopied(self:GetText(), clientLink, self._efCopyIcon)
            end
            if client.OnCopied then client.OnCopied() end
        elseif (key == "LSHIFT" or key == "RSHIFT") and client.OnShift then
            -- Focus sits here while armed, so Shift edges arrive here and
            -- not as MODIFIER_STATE_CHANGED; the client swaps its text.
            client.OnShift(true)
        elseif client.OnKey and not Utils.IsModifierKey(key) then
            -- The focused box takes every key ahead of the client's own
            -- keyboard (a menu, the nav frame); hand navigation keys back
            -- and restore the selection the caret move just dropped.
            local holder = client
            holder.OnKey(key)
            Utils.SafeAfter(0, function()
                if client == holder then self:HighlightText(0, -1) end
            end)
        end
    end)
    -- Stray typing means the user wanted their previous editbox: hand
    -- focus straight back rather than eating input.
    -- MODIFIER_STATE_CHANGED is not delivered while an EditBox has
    -- keyboard focus (copytrace: both watchers silent the moment the
    -- search box or this box held focus), and the armed box IS the
    -- focused EditBox. Ctrl's release therefore reaches the client only
    -- through this key-up.
    box:SetScript("OnKeyUp", function(_, key)
        if (key == "LCTRL" or key == "RCTRL") and client and client.OnCtrlUp then
            client.OnCtrlUp()
        elseif (key == "LSHIFT" or key == "RSHIFT") and client and client.OnShift then
            client.OnShift(false)
        end
    end)
    box:SetScript("OnChar", function() Utils.DisarmClipboardBox(true) end)
    box:SetScript("OnEscapePressed", function()
        local holder = client
        if holder and holder.OnKey then holder.OnKey("ESCAPE") end
        Utils.DisarmClipboardBox(true)
    end)
    box:SetScript("OnEditFocusLost", function()
        -- Deliberate teardowns cleared the client before moving focus.
        -- Anything ELSE stealing focus loses to a client that holds
        -- (re-asserted once, next frame) and ends any other arm.
        local holder = client
        if holder and holder.HoldsFocus and holder.HoldsFocus() then
            Utils.SafeAfter(0, function()
                if client == holder and holder.HoldsFocus() then
                    box:SetFocus()
                    box:HighlightText(0, -1)
                end
            end)
        else
            Utils.DisarmClipboardBox(false)
        end
    end)
    return box
end

function Utils.ClipboardBoxClient()
    return client
end

-- `icon` is the texture the armed target showed; the clipboard history
-- companion keeps it on the recorded entry.
function Utils.ArmClipboardBox(text, link, newClient, icon)
    local eb = EnsureClipboardBox()
    eb._efCopyIcon = icon
    local outgoing = client
    if not outgoing then
        local current = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
        prevFocus = (current and current ~= eb) and current or nil
        -- Tell the frame we borrow from that focus comes straight back:
        -- the search bar reads this to keep its text, autocomplete
        -- suffix and selection untouched through the borrow.
        if prevFocus then prevFocus._efClipboardHold = true end
    end
    client, clientLink = newClient, link
    if outgoing and outgoing ~= newClient and outgoing.OnDisarm then outgoing.OnDisarm() end
    eb:SetText(text)
    eb:SetCursorPosition(0)
    eb:HighlightText(0, -1)
    eb:SetFocus()
    -- Focus changes settle one frame late and can drop the selection.
    Utils.SafeAfter(0, function()
        if client ~= newClient or eb:GetText() ~= text then return end
        eb:SetFocus()
        eb:HighlightText(0, -1)
    end)
end

-- One-shot copy: a small themed prompt at the cursor asks for the chord,
-- turns into "Copied" when it lands, and goes away on Escape, a click
-- anywhere, stray typing, or any other focus move. Replaces the old copy
-- window for links, URLs, icon paths, and quick answers.
local prompt, promptFade, promptCopied, promptClient

local function SizePrompt(msg)
    prompt.text:SetText(msg)
    prompt:SetSize(mfloor(prompt.text:GetStringWidth() + 0.5) + 24,
        mfloor(prompt.text:GetStringHeight() + 0.5) + 14)
end

local function EnsurePrompt()
    if prompt then return prompt end
    prompt = CreateFrame("Frame", "EasyFindCopyPrompt", UIParent, "BackdropTemplate")
    prompt:SetFrameStrata("TOOLTIP")
    prompt:SetClampedToScreen(true)
    ns.StyleMenuPanel(prompt)
    prompt.text = prompt:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    prompt.text:SetPoint("CENTER")
    promptFade = prompt:CreateAnimationGroup()
    local alpha = promptFade:CreateAnimation("Alpha")
    alpha:SetFromAlpha(1)
    alpha:SetToAlpha(0)
    alpha:SetStartDelay(0.7)
    alpha:SetDuration(0.6)
    promptFade:SetScript("OnFinished", function() prompt:Hide() end)
    -- Menu rows act on mouse-down, so the press that chose "Clipboard"
    -- can still arrive here as GLOBAL_MOUSE_DOWN; the same grace the
    -- cursor menus use keeps the opening click from dismissing the prompt.
    prompt:SetScript("OnEvent", function(self)
        if GetTime() - (self._showedAt or 0) < 0.05 then return end
        Utils.DisarmClipboardBox(false, promptClient)
    end)
    prompt:SetScript("OnShow", function(self)
        self._showedAt = GetTime()
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
    end)
    prompt:SetScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
    prompt:Hide()
    return prompt
end

-- "Copied" over anchor, fading as the prompt does after a copy.
function Utils.FlashCopied(anchor)
    local p = EnsurePrompt()
    promptFade:Stop()
    promptCopied = true
    p.text:SetTextColor(ns.TooltipTextColor())
    SizePrompt(L["COPIED"])
    p:ClearAllPoints()
    p:SetPoint("CENTER", anchor, "CENTER")
    p:SetAlpha(1)
    p:Show()
    promptFade:Play()
end

promptClient = {
    OnCopied = function()
        promptCopied = true
        SizePrompt(L["COPIED"])
        promptFade:Play()
        -- The native copy completes on this same key event; the box lets
        -- go one frame later so the chord is never cut short.
        Utils.SafeAfter(0, function() Utils.DisarmClipboardBox(true, promptClient) end)
    end,
    OnDisarm = function()
        if prompt and not promptCopied then prompt:Hide() end
    end,
}

-- link: the live hyperlink the (flattened) text stands for, restored when
-- the copied text is pasted into chat (StashClipboardLink).
function Utils.CopyToClipboard(text, link)
    if not text or text == "" then return end
    local p = EnsurePrompt()
    promptFade:Stop()
    promptCopied = false
    p.text:SetTextColor(ns.TooltipTextColor())
    SizePrompt(L["COPY_HINT"])
    local scale = UIParent:GetEffectiveScale()
    local x, y = GetCursorPosition()
    p:ClearAllPoints()
    p:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / scale + 12, y / scale + 12)
    p:SetAlpha(1)
    p:Show()
    Utils.ArmClipboardBox(text, link, promptClient)
end
ns.CopyToClipboard = Utils.CopyToClipboard
end

-- Paste-a-code dialog shared by every import (themes, notes): a title, a
-- multi-line box, Import. opts: { title, hint, acceptText, onAccept(text) }.
do
local pasteDialog

local function BuildPasteDialog()
    local f = CreateFrame("Frame", "EasyFindPasteDialog", UIParent)
    f:SetSize(420, 196)
    f:SetPoint("CENTER")
    f:SetFrameStrata("TOOLTIP")
    f:SetFrameLevel(9600)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    ns.StyleMenuPanel(f)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title._efOwnColor = true
    f.title:SetPoint("TOP", 0, -12)

    local boxFrame = CreateFrame("Frame", nil, f)
    boxFrame:SetPoint("TOPLEFT", 14, -34)
    boxFrame:SetPoint("TOPRIGHT", -14, -34)
    boxFrame:SetHeight(112)
    ns.CreateRoundedRectBorder(boxFrame)
    ns.SetRoundedRectBarHeight(boxFrame, 8)
    ns.SetRoundedRectBorderShown(boxFrame, false)
    ns.SetRoundedRectFill(boxFrame, 0.02, 0.02, 0.03, 1)

    local scroll = CreateFrame("ScrollFrame", "EasyFindPasteDialogScroll", boxFrame)
    scroll:SetPoint("TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", -14, 8)
    local editBox = CreateFrame("EditBox", nil, scroll)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject("GameFontHighlightSmall")
    editBox:SetWidth(384)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() f:Hide() end)
    scroll:SetScrollChild(editBox)
    f.editBox = editBox
    Utils.CreateMinimalScrollBar(scroll, boxFrame)

    f.acceptBtn = ns.CreateModernButton(f, L["SHORTKEY_IMPORT"], 90, 22)
    f.acceptBtn:SetPoint("BOTTOMRIGHT", -14, 12)
    f.acceptBtn:SetScript("OnClick", function()
        local text = f.editBox:GetText()
        local onAccept = f._onAccept
        f:Hide()
        if onAccept then onAccept(text) end
    end)

    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.hint:SetPoint("BOTTOMLEFT", 14, 16)

    local x = ns.CreateCloseX(f, 14)
    x:SetPoint("TOPRIGHT", -8, -8)
    x:SetScript("OnClick", function() f:Hide() end)
    ns.AttachEscClose(f)
    f:SetScript("OnHide", function(self) self._onAccept = nil end)
    f:Hide()
    return f
end

function ns.ShowPasteDialog(opts)
    if not pasteDialog then pasteDialog = BuildPasteDialog() end
    local f = pasteDialog
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    if theme and theme.lightTheme and theme.leafColor then
        f.title:SetTextColor(theme.leafColor[1], theme.leafColor[2], theme.leafColor[3])
    else
        f.title:SetTextColor(1.0, 0.82, 0)
    end
    f.title:SetText(opts.title or "")
    f.hint:SetText(opts.hint or L["SHORTKEY_IMPORT_HINT"])
    f.acceptBtn:SetText(opts.acceptText or L["SHORTKEY_IMPORT"])
    f._onAccept = opts.onAccept
    f.editBox:SetText("")
    ns.FlatText(f)
    f:Show()
    Utils.SafeAfter(0, function() if f:IsShown() then f.editBox:SetFocus() end end)
end
end

-- Themed replacement for Blizzard StaticPopup confirm/input dialogs, styled
-- like the rest of EasyFind (StyleMenuPanel + CreateModernButton). One pooled
-- frame. opts: { text, acceptText, cancelText, hasEditBox, editBoxDefault,
-- maxLetters, onAccept(value), single (one button), readOnly (a text to
-- copy: the box keeps it, Ctrl+C flashes Copied), extraButton (a labeled
-- button under the box: { label, text, onClick(button) or setup(button) }), checkText,
-- checkDefault, checkTooltip (said on hovering the check) }.
local themedDialog

function ns.ShowThemedDialog(opts)
    opts = opts or {}
    local f = themedDialog
    if not f then
        f = CreateFrame("Frame", "EasyFindThemedDialog", UIParent, "BackdropTemplate")
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetToplevel(true)
        f:SetFrameLevel(800)
        f:EnableMouse(true)
        f:SetClampedToScreen(true)
        f:SetPoint("CENTER", 0, 120)
        ns.StyleMenuPanel(f)

        f.message = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        f.message:SetJustifyH("CENTER")
        f.message:SetSpacing(2)
        f.message:SetTextColor(unpack(ns.TEXT_PRIMARY))
        -- ShowThemedDialog owns this color per prompt type; flat text, no
        -- font-object shadow, on either polarity.
        f.message._efOwnColor = true
        f.message:SetShadowColor(0, 0, 0, 0)

        -- The field as the theme draws its search shells: rounded, in the
        -- buttons' fill, painted at each show.
        local field = CreateFrame("Frame", nil, f)
        field:SetHeight(26)
        ns.CreateRoundedRectBorder(field)
        ns.SetRoundedRectBarHeight(field, 10)
        ns.SetRoundedRectBorderEdgeShown(field, false)
        field._efControlFillKind = "BTN_FILL_NORMAL"
        local eb = CreateFrame("EditBox", nil, field)
        eb:SetPoint("LEFT", 8, 0)
        eb:SetPoint("RIGHT", -8, 0)
        eb:SetHeight(20)
        eb:SetFontObject("GameFontHighlight")
        eb:SetAutoFocus(false)
        eb:SetJustifyH("LEFT")
        eb:SetShadowColor(0, 0, 0, 0)
        f.field = field
        f.editBox = eb

        f.accept = ns.CreateModernButton(f, "", 120, 22)
        f.third = ns.CreateModernButton(f, "", 120, 22)
        f.cancel = ns.CreateModernButton(f, "", 120, 22)

        -- Optional "apply to all" checkbox for Windows-style batch confirms.
        -- Its state is passed to onAccept/onThird so a single prompt can decide
        -- the whole remaining set.
        -- The template's own box, as the map tab's checks: its hover is
        -- the box, and the label sits centered on the art.
        f.check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        f.check:SetSize(22, 22)
        f.check.text = f.check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.check.text:SetPoint("LEFT", f.check, "RIGHT", 2, 1)
        f.check:SetScript("OnEnter", function(self)
            local o = f._opts
            if o and o.checkTooltip then ns.ShowHintTooltip(self, "ANCHOR_RIGHT", o.checkText, o.checkTooltip) end
        end)
        f.check:SetScript("OnLeave", function(self) ns.HideHintTooltip(self) end)
        f.check.text:SetTextColor(unpack(ns.TEXT_PRIMARY))
        f.check.text:SetShadowColor(0, 0, 0, 0)

        local function checkedState()
            return f.check:IsShown() and f.check:GetChecked() and true or false
        end
        local function accept()
            local val = f._hasEditBox and f.editBox:GetText() or nil
            local all = checkedState()
            f:Hide()
            if f._onAccept then f._onAccept(val, all) end
        end
        local function third()
            local all = checkedState()
            f:Hide()
            if f._onThird then f._onThird(all) end
        end
        local function cancel()
            f:Hide()
        end
        f.accept:SetScript("OnClick", accept)
        f.third:SetScript("OnClick", third)
        f.cancel:SetScript("OnClick", cancel)
        -- When the prompt has an alternate message for the checked state
        -- (opts.textChecked), toggling the checkbox re-shows the dialog with
        -- the matching text. Re-showing (rather than SetText in place) reruns
        -- the layout, since the two messages can wrap to different heights;
        -- typed input and the checkbox state survive the round trip.
        f.check:SetScript("OnClick", function(self)
            local o = f._opts
            if not (o and o.textChecked) then return end
            o.editBoxDefault = f._hasEditBox and f.editBox:GetText() or o.editBoxDefault
            o.checkDefault = self:GetChecked() and true or false
            ns.ShowThemedDialog(o)
        end)
        eb:SetScript("OnEnterPressed", accept)
        eb:SetScript("OnEscapePressed", cancel)
        -- A text to copy: typing puts it back, Ctrl+C says it landed.
        eb:SetScript("OnTextChanged", function(self, user)
            local o = f._opts
            if user and o and o.readOnly then
                self:SetText(o.editBoxDefault or "")
                self:HighlightText()
            end
        end)
        eb:SetScript("OnKeyDown", function(_, key)
            local o = f._opts
            if key == "C" and IsControlKeyDown() and o and o.readOnly then Utils.FlashCopied(field) end
        end)
        -- ESC closes via the taint-free override-bind path (never
        -- UISpecialFrames); cancel is a bare hide, so this is the
        -- complete cancel path.
        Utils.AttachEscClose(f, cancel)

        themedDialog = f
    end

    f._onAccept = opts.onAccept
    f._onThird = opts.onThird
    f._hasEditBox = opts.hasEditBox and true or false
    f._opts = opts

    local shownText = (opts.checkDefault and opts.textChecked) or opts.text
    f.message:SetJustifyH(opts.justify or "CENTER")
    f.message:SetText(shownText or "")
    -- Title-style prompts (alias/shortkey/Wowhead family) go gold;
    -- plain confirmations keep the primary text color. On light themes
    -- gold is unreadable, so it wears the theme's hue-dark accent.
    local msgColor = opts.messageColor or ns.TEXT_PRIMARY
    if msgColor == ns.GOLD_COLOR then
        local dlgTheme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
        if dlgTheme and dlgTheme.lightTheme then
            msgColor = dlgTheme.pathColorHover or dlgTheme.leafColor
        end
    end
    f.message:SetTextColor(msgColor[1], msgColor[2], msgColor[3], 1)

    local width = 380
    f:SetWidth(width)
    f.message:SetWidth(width - 32)

    local used = 14
    f.message:ClearAllPoints()
    f.message:SetPoint("TOPLEFT", 16, -used)
    f.message:SetPoint("TOPRIGHT", -16, -used)
    used = used + f.message:GetStringHeight() + 14

    if f._hasEditBox then
        f.field:ClearAllPoints()
        f.field:SetPoint("TOPLEFT", 16, -used)
        f.field:SetPoint("TOPRIGHT", -16, -used)
        local c = ns.BTN_FILL_NORMAL
        ns.SetRoundedRectFill(f.field, c[1], c[2], c[3], 1, true)
        f.field:Show()
        f.editBox:SetMaxLetters(opts.maxLetters or 128)
        f.editBox:SetText(opts.editBoxDefault or "")
        used = used + 26 + 14
    else
        f.field:Hide()
    end

    local extra = opts.extraButton
    if extra then
        if not f.extraBtn then
            f.extraLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            f.extraLabel:SetTextColor(unpack(ns.TEXT_PRIMARY))
            f.extraLabel:SetShadowColor(0, 0, 0, 0)
            f.extraBtn = ns.CreateModernButton(f, "", 100, 22)
        end
        f.extraLabel:SetText(extra.label or "")
        f.extraLabel:ClearAllPoints()
        f.extraLabel:SetPoint("TOPLEFT", 16, -(used + 5))
        f.extraBtn:ClearAllPoints()
        f.extraBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 24 + f.extraLabel:GetStringWidth(), -used)
        f.extraBtn:SetPoint("RIGHT", f, "RIGHT", -16, 0)
        f.extraBtn:SetText(extra.text or "")
        if extra.onClick then
            f.extraBtn:SetScript("OnClick", function(self) extra.onClick(self) end)
        else
            f.extraBtn:SetScript("OnClick", nil)
        end
        if extra.setup then extra.setup(f.extraBtn) end
        f.extraLabel:Show()
        f.extraBtn:Show()
        used = used + 22 + 10
    elseif f.extraBtn then
        f.extraLabel:Hide()
        f.extraBtn:Hide()
    end

    if opts.checkText then
        f.check.text:SetText(opts.checkText)
        -- Its label clicks it too.
        f.check:SetHitRectInsets(0, -(f.check.text:GetStringWidth() + 4), 0, 0)
        f.check:SetChecked(opts.checkDefault and true or false)
        f.check:ClearAllPoints()
        f.check:SetPoint("TOPLEFT", 16, -used)
        f.check:Show()
        used = used + 22 + 10
    else
        f.check:Hide()
    end

    f.accept:SetText(opts.acceptText or _G["OKAY"] or _G["ACCEPT"] or "OK")
    f.cancel:SetText(opts.cancelText or _G["CANCEL"] or "Cancel")
    f.accept:ClearAllPoints()
    f.third:ClearAllPoints()
    f.cancel:ClearAllPoints()
    f.cancel:SetShown(not opts.single)
    if opts.single then
        f.third:Hide()
        f.accept:SetWidth(120)
        f.accept:SetPoint("TOP", f, "TOP", 0, -used)
    elseif opts.thirdText then
        -- Three across (e.g. Replace / Skip / Cancel), narrower to fit.
        f.third:SetText(opts.thirdText)
        f.third:Show()
        f.accept:SetWidth(108)
        f.third:SetWidth(108)
        f.cancel:SetWidth(108)
        f.accept:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -used)
        f.third:SetPoint("TOP", f, "TOP", 0, -used)
        f.cancel:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -used)
    else
        -- Accept on the left, Cancel on the right (standard button order).
        f.third:Hide()
        f.accept:SetWidth(120)
        f.cancel:SetWidth(120)
        f.accept:SetPoint("TOPRIGHT", f, "TOP", -6, -used)
        f.cancel:SetPoint("TOPLEFT", f, "TOP", 6, -used)
    end
    used = used + 22 + 14
    f:SetHeight(used)

    ns.FlatText(f)
    f:Show()
    if f._hasEditBox then
        f.editBox:SetFocus()
        f.editBox:HighlightText()
    end
    return f
end

local WOWHEAD_LOCALE_SUB = {
    deDE = "de", esES = "es", esMX = "es", frFR = "fr", itIT = "it",
    ptBR = "pt", ruRU = "ru", koKR = "ko", zhCN = "cn", zhTW = "cn",
}

-- Percent-encode a string for use in a Wowhead search query.
local function WowheadSearchEncode(s)
    return (s:gsub("[^%w]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Build a wowhead.com URL for a search result from the id fields it carries.
-- Returns nil for results with no meaningful Wowhead page (settings, macros,
-- gear sets, ...), so the menu option only appears where it's useful.
function ns.GetWowheadLink(data)
    if not data then return nil end
    local kind, id, query, listing

    if data.appearanceItemID and C_TransmogCollection and C_TransmogCollection.GetSourceInfo then
        local info = C_TransmogCollection.GetSourceInfo(data.appearanceItemID)
        if info and info.itemID then kind, id = "item", info.itemID end
    elseif data.heirloomItemID then
        kind, id = "item", data.heirloomItemID
    elseif data.toyItemID then
        kind, id = "item", data.toyItemID
    elseif data.mountID and C_MountJournal and C_MountJournal.GetMountInfoByID then
        local spellID = select(2, C_MountJournal.GetMountInfoByID(data.mountID))
        if spellID then kind, id = "spell", spellID end
    elseif (data.speciesID or data.petID) and C_PetJournal then
        local species = data.speciesID
        if not species and type(data.petID) == "number" then species = data.petID end
        local npcID
        if species and C_PetJournal.GetPetInfoBySpeciesID then
            npcID = select(4, C_PetJournal.GetPetInfoBySpeciesID(species))
        elseif type(data.petID) == "string" and C_PetJournal.GetPetInfoByPetID then
            npcID = select(11, C_PetJournal.GetPetInfoByPetID(data.petID))
        end
        if npcID then kind, id = "npc", npcID end
    elseif data.npcID then
        -- Creature rows: the world database's creature id is Wowhead's npc id.
        kind, id = "npc", data.npcID
    elseif data.transmogSetID then
        -- Wowhead's transmog-set IDs are internal and do not match WoW's setID
        -- (that number 404s). The item that teaches a set is named
        -- "Ensemble: <set>", so search that -- it lands on the set's gear.
        if data.name then query = L["WOWHEAD_SET_PREFIX"] .. " " .. data.name end
    elseif data.encounterID and data.category == "Boss" then
        -- EJ_GetCreatureInfo returns a journal-internal creature id that does
        -- not match Wowhead's world NPC entries (e.g. LK's journal id 3927 is
        -- an unrelated NPC on Wowhead), so search the boss name -- it lands on
        -- the boss's page.
        if data.name then query = data.name end
    elseif data.achievementID and data.category == "Achievement" then
        kind, id = "achievement", data.achievementID
    elseif data.currencyID then
        kind, id = "currency", data.currencyID
    elseif data.factionID then
        kind, id = "faction", data.factionID
    elseif data.titleID then
        -- WoW's titleID is an index into the client's own title list and bears
        -- no relation to Wowhead's title ids, so linking it landed on an
        -- unrelated page. Link the achievement that awards the title instead:
        -- it is exact, and it is the page that actually explains how to earn
        -- it. Titles from quests, PvP ranks and events have no achievement, so
        -- those fall back to a name search rather than a wrong id.
        -- Verified: Wowhead's title ids are a different space from the
        -- client's (Wowhead title=47 is "Conqueror"; GetTitleName(47) is "the
        -- Explorer"), and its title pages need that numeric id -- the slug
        -- alone 404s. So there is no way to build the exact page from client
        -- data. Prefer the achievement that awards it, which IS exact and
        -- explains how to earn it; otherwise fall back to Wowhead's TITLES
        -- listing filtered by name, which beats a site-wide search.
        local achID = ns.Database and ns.Database.GetTitleSourceAchievement
            and ns.Database:GetTitleSourceAchievement(data.titleID)
        if achID then
            kind, id = "achievement", achID
        elseif data.name then
            query, listing = data.name, "titles"
        end
    elseif data.spellID and (data.category == "Ability" or data.category == "Talent") then
        kind, id = "spell", data.spellID
    elseif data.housingRecordID or data.housingEntryID then
        -- No verified mapping from the client's decor record ids to
        -- Wowhead's decor page ids, so search the name -- it lands on the
        -- decor entry.
        if data.name then query = data.name end
    elseif data.itemID then
        -- Loot, bag items, and anything else carrying a real item id.
        kind, id = "item", data.itemID
    elseif data.isZone or data.isDungeonEntrance then
        -- Wowhead's zone pages key on AreaTable ids, which have no client
        -- mapping from uiMapID, so search the localized name -- it lands on
        -- the zone or instance page. Generic POIs (flight masters, banks)
        -- carry neither flag and stay linkless.
        if data.name then query = data.name end
    end

    if not query and (not kind or not id) then return nil end
    -- Subdomain: an explicit player choice wins; "auto" (default) follows the
    -- client locale. ns.WOWHEAD_LOCALES drives the options dropdown.
    local pref = EasyFind and EasyFind.db and EasyFind.db.wowheadLocale
    local sub
    if pref and pref ~= "auto" then
        sub = pref
    else
        sub = WOWHEAD_LOCALE_SUB[GetLocale and GetLocale()] or "www"
    end
    if listing then
        -- A type-filtered listing (titles): far closer than a site-wide search,
        -- which buries the title among items and quests.
        return "https://" .. sub .. ".wowhead.com/" .. listing
            .. "/name:" .. WowheadSearchEncode(query)
    end
    if query then
        return "https://" .. sub .. ".wowhead.com/search?q=" .. WowheadSearchEncode(query)
    end
    return "https://" .. sub .. ".wowhead.com/" .. kind .. "=" .. id
end

local function ResultItemLink(itemID)
    if not itemID then return nil end
    local link = select(2, C_Item.GetItemInfo(itemID))
    if link then return link end
    -- Not in the client cache yet; ask for it so a re-open resolves.
    if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
    return nil
end

local function ResultSpellLink(spellID)
    if not spellID then return nil end
    if C_Spell and C_Spell.GetSpellLink then return C_Spell.GetSpellLink(spellID) end
    if GetSpellLink then return GetSpellLink(spellID) end
    return nil
end

-- Battle pet chat link. Prefers an owned pet's real stats (petID GUID); falls
-- back to a species reference (null pet GUID) for search results that aren't
-- collected. Quality index = rarity - 1 (0 poor .. 3 rare), matching the item
-- quality colors WoW tints battlepet links with.
local function ResultBattlePetLink(data)
    if not C_PetJournal then return nil end
    local speciesID = data.speciesID
    local petID = type(data.petID) == "string" and data.petID or nil
    -- Owned pet: the client builds the canonical link itself; a hand-built
    -- one risks drifting from the current format and being rejected.
    if petID and C_PetJournal.GetBattlePetLink then
        local ok, apiLink = pcall(C_PetJournal.GetBattlePetLink, petID)
        if ok and type(apiLink) == "string" and apiLink:find("|H", 1, true) then
            return apiLink
        end
    end
    local level, quality, maxHealth, power, speed, name = 1, 0, 0, 0, 0, nil
    if petID and C_PetJournal.GetPetInfoByPetID then
        local sID, _, lvl, _, _, _, _, petName = C_PetJournal.GetPetInfoByPetID(petID)
        speciesID = speciesID or sID
        level, name = lvl or 1, petName
        if C_PetJournal.GetPetStats then
            local _, mh, pw, sp, rarity = C_PetJournal.GetPetStats(petID)
            maxHealth, power, speed = mh or 0, pw or 0, sp or 0
            quality = (rarity or 1) - 1
        end
    end
    if not speciesID then return nil end
    if not name and C_PetJournal.GetPetInfoBySpeciesID then
        name = C_PetJournal.GetPetInfoBySpeciesID(speciesID)
    end
    if not name then return nil end
    -- Quality color markup: .hex carried the full "|cff..." historically;
    -- newer builds expose only the color object. A missing prefix makes
    -- the whole link parse as plain text, so verify and rebuild.
    local qc = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    local hex = qc and qc.hex
    if (not hex or hex:sub(1, 2) ~= "|c") and qc and qc.color
        and qc.color.GenerateHexColorMarkup then
        hex = qc.color:GenerateHexColorMarkup()
    end
    if not hex or hex:sub(1, 2) ~= "|c" then hex = "|cffffffff" end
    return format("%s|Hbattlepet:%d:%d:%d:%d:%d:%d:0000000000000000|h[%s]|h|r",
        hex, speciesID, level, quality, maxHealth, power, speed, name)
end

-- Build a chat hyperlink (|H...|h) for a search result, or nil for results
-- with no linkable game object (settings, zones, POIs, titles, reputations,
-- gear sets, bosses). Mirrors the type dispatch of ns.GetWowheadLink; only the
-- kinds WoW exposes as chat links produce a string, so the Send-link menu
-- option appears only where there is something real to send.
function ns.GetResultLink(data)
    if not data then return nil end
    if data.appearanceItemID and C_TransmogCollection and C_TransmogCollection.GetSourceInfo then
        local info = C_TransmogCollection.GetSourceInfo(data.appearanceItemID)
        return info and ResultItemLink(info.itemID) or nil
    elseif data.heirloomItemID then
        return ResultItemLink(data.heirloomItemID)
    elseif data.toyItemID then
        return ResultItemLink(data.toyItemID)
    elseif data.mountID and C_MountJournal and C_MountJournal.GetMountInfoByID then
        return ResultSpellLink(select(2, C_MountJournal.GetMountInfoByID(data.mountID)))
    elseif data.speciesID or type(data.petID) == "string" then
        return ResultBattlePetLink(data)
    elseif data.achievementID and data.category == "Achievement" and GetAchievementLink then
        return GetAchievementLink(data.achievementID)
    elseif data.statisticID and data.category == "Statistic" and GetStatistic then
        -- Statistics have no chat hyperlink, so synthesize shareable plain text
        -- "Name: Value" from the already-localized stat value. Not clickable,
        -- but WoW otherwise gives players no way to link a statistic at all.
        local value = GetStatistic(data.statisticID)
        if value and value ~= "" and value ~= "--" then
            return format("%s: %s", data.name or "", value)
        end
        return nil
    elseif data.currencyID and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyLink then
        return C_CurrencyInfo.GetCurrencyLink(data.currencyID, 0)
    elseif data.encounterID and data.category == "Boss" then
        -- Adventure Guide (journal) link: type 1 = encounter. Difficulty is
        -- cosmetic for sharing; recipients land on the encounter regardless.
        return format("|cff66bbff|Hjournal:1:%d:%d|h[%s]|h|r",
            data.encounterID, data.difficultyID or 14, data.name or "")
    elseif data.spellID and (data.category == "Ability" or data.category == "Talent") then
        return ResultSpellLink(data.spellID)
    elseif data.category == "Snippet" and data.snippetIndex then
        -- The shareable payload of a snippet IS its chat text (placeholders
        -- resolved at send time), like statistics share synthesized text.
        local snippets = ns.Snippets
        if snippets and snippets.GetChatTextByName then
            return snippets:GetChatTextByName(data.name)
        end
        return nil
    elseif data.housingRecordID and C_HousingDecor and C_HousingDecor.GetDecorHyperlink then
        local ok, link = pcall(C_HousingDecor.GetDecorHyperlink, data.housingRecordID)
        if ok and link and link ~= "" then return link end
        return nil
    elseif data.itemID and data.category == "Loot" then
        -- The journal carries a link per difficulty; prefer the one matching
        -- the selected difficulty over the generic item link, so the shared
        -- link says the same item level the row does.
        local lootLink = ns.Database and ns.Database.GetLootItemLink
            and ns.Database:GetLootItemLink(data)
        return lootLink or ResultItemLink(data.itemID)
    elseif data.itemID then
        return ResultItemLink(data.itemID)
    end
    return nil
end

-- Game-native shift-click linking: with a chat editbox active and Shift
-- held, clicking a result inserts its real hyperlink into the editbox,
-- exactly like shift-clicking an item anywhere else in the game. One owner
-- for every linkable result kind (rides ns.GetResultLink); callers skip
-- their own click action when this returns true.
function ns.TryInsertResultChatLink(data)
    if not data or not (IsShiftKeyDown and IsShiftKeyDown()) then return false end
    if not (ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()) then return false end
    local link = ns.GetResultLink(data)
    if not link or link == "" then return false end
    return (ChatEdit_InsertLink and ChatEdit_InsertLink(link)) and true or false
end

-- Map pin chat icon: the atlas WoW shows in shared waypoint links.
local MAP_PIN_CHAT_ICON = "|A:Waypoint-MapPin-ChatIcon:13:13:0:0|a"

-- Chat-linkable world map pin at a result's location. WoW encodes worldmap
-- hyperlink coords as the normalized position times 10000, and the recipient
-- clicks the link to open the map there. Built by hand from the result's own
-- coordinates so no real user waypoint is placed on the sender's map. Coords are
-- paired with the map they belong to (POI vs dungeon-entrance fields).
function ns.GetMapPinLink(data)
    if not data then return nil end
    local mapID, x, y
    if data.x and data.y and (data.mapID or data.coordMapID) then
        mapID, x, y = data.mapID or data.coordMapID, data.x, data.y
    elseif data.entranceX and data.entranceY and data.entranceMapID then
        mapID, x, y = data.entranceMapID, data.entranceX, data.entranceY
    end
    if not mapID or not x or not y then return nil end
    local label = data.name or _G["MAP_PIN_HYPERLINK"] or "Map Pin Location"
    return format("|cffffff00|Hworldmap:%d:%d:%d|h[%s %s]|h|r",
        mapID, mfloor(x * 10000 + 0.5), mfloor(y * 10000 + 0.5), MAP_PIN_CHAT_ICON, label)
end

-- Wowhead-supported subdomains for the options dropdown. "auto" follows the
-- client locale; the rest force a specific site. Native labels are universal.
-- Language entries use native endonyms (shown the same on every client); the
-- "auto" entry's display label is localized via L["WOWHEAD_LOCALE_AUTO"].
ns.WOWHEAD_LOCALES = {
    { value = "auto", label = "Auto" },
    { value = "www",  label = "English" },
    { value = "de",   label = "Deutsch" },
    { value = "es",   label = "Español" },
    { value = "fr",   label = "Français" },
    { value = "it",   label = "Italiano" },
    { value = "pt",   label = "Português" },
    { value = "ru",   label = "Русский" },
    { value = "ko",   label = "한국어" },
    { value = "cn",   label = "中文" },
}

-- Resolve a "parent.leaf" dotted db key into its container table (created on
-- demand) and the leaf name; a plain key returns EasyFind.db and the key.
function ns.ResolveDbKey(dbKey)
    local parent, leaf = dbKey:match("^(.-)%.([^%.]+)$")
    if parent then
        EasyFind.db[parent] = EasyFind.db[parent] or {}
        return EasyFind.db[parent], leaf
    end
    return EasyFind.db, dbKey
end

-- Markup parser shared by OptionsPanel home and TutorialWizard slide body.
-- Recognises {L:id}text{/L} for click-link chips and {C:rrggbb}text{/C} for
-- colored spans. Everything outside markers is plain text.
local function HexRGB(hex)
    if not hex or #hex < 6 then return 1, 1, 1 end
    return tonumber(hex:sub(1, 2), 16) / 255,
           tonumber(hex:sub(3, 4), 16) / 255,
           tonumber(hex:sub(5, 6), 16) / 255
end

function ns.ParseFlowSegments(str)
    -- Pre-pass: convert WoW's native color codes (|cAARRGGBB...|r) into our
    -- {C:RRGGBB}...{/C} markup so the parser handles both formats. Older
    -- locale translations still use |c|r and are common enough that
    -- supporting both forms saves a translator pass per language.
    str = str:gsub("|c%x%x(%x%x%x%x%x%x)(.-)|r", "{C:%1}%2{/C}")

    local segs, i, n = {}, 1, #str
    while i <= n do
        local s, e, body = str:find("{(.-)}", i)
        if not s then
            segs[#segs + 1] = { kind = "text", text = str:sub(i) }
            break
        end
        if s > i then
            segs[#segs + 1] = { kind = "text", text = str:sub(i, s - 1) }
        end
        local tag, arg = body:match("^(%a+):?(.*)$")
        if tag == "L" then
            local cs, ce = str:find("{/L}", e + 1, true)
            segs[#segs + 1] = { kind = "link", text = str:sub(e + 1, (cs or e + 1) - 1), id = arg }
            i = (ce or e) + 1
        elseif tag == "C" then
            local cs, ce = str:find("{/C}", e + 1, true)
            local r, g, b = HexRGB(arg)
            segs[#segs + 1] = { kind = "text", text = str:sub(e + 1, (cs or e + 1) - 1), color = { r, g, b } }
            i = (ce or e) + 1
        else
            segs[#segs + 1] = { kind = "text", text = str:sub(s, e) }
            i = e + 1
        end
    end
    return segs
end

-- Lay out a marked-up string into a width-bound flow of word atoms + link
-- chips. The container's height is computed from the final line count.
-- opts = { width, font, linkDispatch = {[id] = onClickFn}, textColor }
function ns.BuildFlowText(parent, str, opts)
    opts = opts or {}
    local width = opts.width or 400
    local font = opts.font or "GameFontHighlightSmall"
    local linkDispatch = opts.linkDispatch or {}

    local interWeight = opts.interWeight
    local interSize = opts.interSize
    local interFlags = opts.interFlags
    local function styleFS(fs)
        if interWeight and ns.RegisterAddonFont then
            ns.RegisterAddonFont(fs, interWeight, interSize, interFlags)
        end
        -- Flow text is flat body copy; never carry the font object's shadow.
        fs:SetShadowColor(0, 0, 0, 0)
    end

    local container = CreateFrame("Frame", nil, parent)
    container:SetWidth(width)

    local measure = container:CreateFontString(nil, "OVERLAY", font)
    styleFS(measure)
    measure:Hide()
    local _, fontH = measure:GetFont()
    fontH = fontH or 12
    local function widthOf(text)
        measure:SetText(text)
        return measure:GetStringWidth()
    end
    local spaceW = widthOf(" ")
    if spaceW <= 0 then spaceW = 3 end

    local lineH = math.floor(fontH + 5)

    local atoms = {}
    local pendingSpace = false
    local function addText(text, color)
        if text:sub(1, 1) == " " then pendingSpace = true end
        for word in text:gmatch("%S+") do
            atoms[#atoms + 1] = { kind = "word", text = word, w = widthOf(word), spaceBefore = pendingSpace, color = color }
            pendingSpace = true
        end
        pendingSpace = (text:sub(-1) == " ")
    end
    for _, seg in ipairs(ns.ParseFlowSegments(str)) do
        if seg.kind == "text" then
            addText(seg.text, seg.color)
        else
            atoms[#atoms + 1] = { kind = "link", text = seg.text, id = seg.id,
                w = widthOf(seg.text), spaceBefore = pendingSpace }
            pendingSpace = false
        end
    end

    local defaultColor = opts.textColor or ns.TEXT_BODY

    local x, lineTop = 0, 0
    for _, atom in ipairs(atoms) do
        local gap = (atom.spaceBefore and x > 0) and spaceW or 0
        if x > 0 and (x + gap + atom.w) > width then
            lineTop = lineTop - lineH
            x, gap = 0, 0
        end
        local cx = x + gap
        local cy = lineTop - lineH / 2
        if atom.kind == "word" then
            local fs = container:CreateFontString(nil, "OVERLAY", font)
            styleFS(fs)
            fs:SetPoint("LEFT", container, "TOPLEFT", cx, cy)
            fs:SetText(atom.text)
            if atom.color then
                fs:SetTextColor(atom.color[1], atom.color[2], atom.color[3])
            elseif defaultColor then
                fs:SetTextColor(defaultColor[1], defaultColor[2], defaultColor[3])
            end
        elseif atom.kind == "link" then
            local slot = CreateFrame("Frame", nil, container)
            slot:SetSize(atom.w, lineH)
            slot:SetPoint("LEFT", container, "TOPLEFT", cx, cy)
            local chip = CreateFrame("Button", nil, slot)
            chip:SetSize(atom.w, fontH + 4)
            chip:SetPoint("CENTER", slot, "CENTER", 0, 0)
            local glow = chip:CreateTexture(nil, "BACKGROUND")
            glow:SetPoint("CENTER", chip, "CENTER", 0, 0)
            glow:SetSize(atom.w + 20, fontH + 16)
            glow:SetAtlas("collections-newglow")
            if ns.LINK_GLOW_COLOR then
                glow:SetVertexColor(ns.LINK_GLOW_COLOR[1], ns.LINK_GLOW_COLOR[2],
                                    ns.LINK_GLOW_COLOR[3], ns.LINK_GLOW_COLOR[4] or 1)
            end
            glow:SetBlendMode("ADD")
            glow:Hide()
            local glowPulse = ns.CreateBouncePulse(glow, 1.0, 0.5, 0.9)
            local fs = chip:CreateFontString(nil, "OVERLAY", font)
            styleFS(fs)
            fs:SetAllPoints(chip)
            fs:SetJustifyH("CENTER")
            fs:SetText(atom.text)
            -- Marker for the retint walker: link text repaints from the
            -- live link table on every theme flip (the resting color set
            -- here is only the build-time value).
            fs._efLinkText = true
            local LC = ns.LINK_COLOR or { 0.44, 0.84, 1.0 }
            local LH = ns.LINK_HOVER or { 1, 1, 1 }
            fs:SetTextColor(LC[1], LC[2], LC[3])
            chip:SetScript("OnEnter", function()
                glow:Show()
                glowPulse:Play()
                fs:SetTextColor(LH[1], LH[2], LH[3])
            end)
            chip:SetScript("OnLeave", function()
                glowPulse:Stop()
                glow:Hide()
                fs:SetTextColor(LC[1], LC[2], LC[3])
            end)
            local action = linkDispatch[atom.id]
            if type(action) == "table" then
                -- Hover span: styled like a link but not clickable; fires
                -- enter/leave callbacks (e.g. spotlight a spot on an image).
                if action.onEnter then chip:HookScript("OnEnter", action.onEnter) end
                if action.onLeave then chip:HookScript("OnLeave", action.onLeave) end
            elseif action then
                chip:SetScript("OnClick", action)
            end
        end
        x = cx + atom.w
    end

    container:SetHeight(-lineTop + lineH)
    return container
end

-- Single source of truth for "label that auto-fits with ellipsis + tooltip".
--
--   ns.MakeEllipsisLabel(fs, text, opts?)
--   ns.MakeEllipsisLabel:setText(fs, newText)   via fs:SetEllipsisText(...)
--
-- Configures a FontString so it:
--   1. Stays on one line (SetWordWrap/SetNonSpaceWrap/SetMaxLines).
--   2. Auto-truncates with "..." when its text exceeds the available width.
--   3. Re-fits whenever the parent frame is resized.
--   4. Shows a delayed (0.5s) tooltip with the FULL text on hover, only
--      when the label was actually truncated.
--
-- Width is derived from the FontString's anchors (GetLeft/GetRight) so no
-- caller needs to hand-code a maxWidth: set L/R anchors and forget. Pass
-- opts.maxWidth to override explicitly when anchors aren't bounded.
--
-- opts (all optional):
--   maxWidth       number   Override the anchor-derived width.
--   tooltip        bool     Set false to skip the hover tooltip. Default true.
--   tooltipAnchor  string   GameTooltip anchor (default "ANCHOR_TOP").
--   hoverParent    Frame    Parent for the mouse-host overlay (default fs's parent).
--
-- After setup:
--   fs:SetEllipsisText(t)   set the full text and re-fit.
--   fs._fullText            the original (un-truncated) text.
--   fs._isTruncated         true when the label is currently clipped.
local function SetTruncated(fs, truncated)
    fs._isTruncated = truncated
    if fs._hoverHost then fs._hoverHost:EnableMouse(truncated) end
end

function ns.MakeEllipsisLabel(fs, text, opts)
    if not fs then return fs end
    opts = opts or {}
    fs:SetWordWrap(false)
    fs:SetNonSpaceWrap(false)
    fs:SetMaxLines(1)
    fs._fullText = text or ""

    local ANCHOR_X = {
        LEFT = 0, TOPLEFT = 0, BOTTOMLEFT = 0,
        CENTER = 0.5, TOP = 0.5, BOTTOM = 0.5,
        RIGHT = 1, TOPRIGHT = 1, BOTTOMRIGHT = 1,
    }
    local function utf8CharCount(s)
        local count, i, n = 0, 1, #s
        while i <= n do
            count = count + 1
            local b = s:byte(i) or 0
            if b < 0x80 then i = i + 1
            elseif b < 0xE0 then i = i + 2
            elseif b < 0xF0 then i = i + 3
            elseif b < 0xF8 then i = i + 4
            else i = i + 1 end
        end
        return count
    end
    local function utf8SubChars(s, chars)
        if chars <= 0 then return "" end
        local count, i, n = 0, 1, #s
        while i <= n do
            count = count + 1
            local b = s:byte(i) or 0
            local step
            if b < 0x80 then step = 1
            elseif b < 0xE0 then step = 2
            elseif b < 0xF0 then step = 3
            elseif b < 0xF8 then step = 4
            else step = 1 end
            local nextI = i + step
            if count == chars then return s:sub(1, mmin(nextI - 1, n)) end
            i = nextI
        end
        return s
    end
    local function pointUses(point, side)
        return point == side or (point and point:find(side, 1, true) ~= nil)
    end
    local function pointX(relativeTo, relativePoint, x)
        local w = relativeTo and relativeTo.GetWidth and relativeTo:GetWidth()
        local anchor = ANCHOR_X[relativePoint or ""]
        if not w or w <= 0 or not anchor then return nil end
        return w * anchor + (x or 0)
    end
    local function measureFromPoints()
        if not fs.GetNumPoints or not fs.GetPoint then return nil end
        local leftX, rightX, relFrame
        for i = 1, fs:GetNumPoints() do
            local point, relativeTo, relativePoint, x = fs:GetPoint(i)
            relativeTo = relativeTo or fs:GetParent()
            if relativeTo then
                if relFrame and relFrame ~= relativeTo then return nil end
                relFrame = relativeTo
            end
            local xPos = pointX(relativeTo, relativePoint or point, x)
            if xPos then
                if pointUses(point, "LEFT") then
                    leftX = xPos
                elseif pointUses(point, "RIGHT") then
                    rightX = xPos
                end
            end
        end
        if leftX and rightX and rightX > leftX then return rightX - leftX end
        return nil
    end
    local function measureMax()
        if opts.maxWidth then return opts.maxWidth end
        local pointW = measureFromPoints()
        if pointW and pointW > 0 then return pointW end
        local left, right = fs:GetLeft(), fs:GetRight()
        if left and right and right > left then return right - left end
        return fs:GetWidth() or 0
    end
    local function widthOf()
        return (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth())
            or (fs.GetStringWidth and fs:GetStringWidth())
            or 0
    end

    local fit, scheduleFit
    scheduleFit = function()
        if fs._ellipsisFitPending then return end
        if not (C_Timer and C_Timer.After) then return end
        fs._ellipsisFitPending = true
        C_Timer.After(0, function()
            fs._ellipsisFitPending = nil
            if fit then fit(true) end
        end)
    end
    fit = function(fromDeferred)
        local full = fs._fullText or ""
        if full == "" then fs:SetText(""); SetTruncated(fs, false); return end
        local maxW = measureMax()
        if maxW <= 0 then
            -- Layout hasn't computed L/R yet (FontString just created, parent
            -- not shown). Show full text now and try once after layout settles;
            -- OnShow/OnSizeChanged hooks below handle later hidden-tab reveals.
            fs:SetText(full)
            SetTruncated(fs, false)
            if not fromDeferred then scheduleFit() end
            return
        end
        fs:SetText(full)
        if widthOf() <= maxW then SetTruncated(fs, false); return end
        local ELLIPSIS = "..."
        local lo, hi = 0, utf8CharCount(full)
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            fs:SetText(utf8SubChars(full, mid) .. ELLIPSIS)
            if widthOf() <= maxW then lo = mid else hi = mid - 1 end
        end
        fs:SetText(utf8SubChars(full, lo) .. ELLIPSIS)
        SetTruncated(fs, true)
    end
    fit()
    fs._fit = fit
    fs.SetEllipsisText = function(self, newText)
        self._fullText = newText or ""
        fit()
    end

    -- Re-fit when the parent's size changes (covers first-layout-after-show
    -- and any later panel resize). FontStrings don't fire OnSizeChanged
    -- themselves, so the parent is where we listen.
    local parent = opts.hoverParent or fs:GetParent()
    if parent and not fs._sizeHook then
        parent:HookScript("OnSizeChanged", fit)
        parent:HookScript("OnShow", fit)
        fs._sizeHook = true
    end

    if opts.tooltip ~= false and parent and not fs._hoverHost then
        local host = CreateFrame("Frame", nil, parent)
        host:SetAllPoints(fs)
        -- Mouse-enabled only while the text is actually truncated: an
        -- always-on host swallows clicks meant for the control under it.
        host:EnableMouse(fs._isTruncated or false)
        fs._hoverHost = host
        local anchor = opts.tooltipAnchor or "ANCHOR_TOP"
        host:SetScript("OnEnter", function(self)
            if not fs._isTruncated then return end
            if self._timer then self._timer:Cancel() end
            self._timer = C_Timer.NewTimer(0.5, function()
                self._timer = nil
                if not self:IsMouseOver() then return end
                GameTooltip:SetOwner(self, anchor)
                GameTooltip:SetText(fs._fullText or "", 1, 1, 1)
                GameTooltip:Show()
                self._shown = true
            end)
        end)
        host:SetScript("OnLeave", function(self)
            if self._timer then self._timer:Cancel(); self._timer = nil end
            if self._shown then GameTooltip:Hide(); self._shown = nil end
        end)
    end
    return fs
end

-- Back-compat shim: existing callers used the explicit-maxWidth signature.
-- Routes to the unified helper so there's a single implementation to fix.
function ns.AttachEllipsisToFontString(fs, fullText, maxWidth)
    return ns.MakeEllipsisLabel(fs, fullText, { maxWidth = maxWidth })
end

function ns.CreateBouncePulse(region, fromAlpha, toAlpha, duration, smoothing)
    local animGroup = region:CreateAnimationGroup()
    animGroup:SetLooping("BOUNCE")
    local alpha = animGroup:CreateAnimation("Alpha")
    alpha:SetFromAlpha(fromAlpha or 1)
    alpha:SetToAlpha(toAlpha or 0.4)
    alpha:SetDuration(duration or 0.5)
    if smoothing then alpha:SetSmoothing(smoothing) end
    return animGroup, alpha
end

-- A small badge beside a feature's name: NEW in cyan, EXP (experimental) in
-- amber; its glow pulses, a tooltip says why. Parent it to a container, never
-- to the row the name sits on, or the row takes the mouse. superscript makes
-- it the smaller kind that rides a word (ns.SuperscriptTag places it).
ns.TAG_COLORS = { new = { 0.3, 0.85, 1.0 }, exp = { 1.0, 0.55, 0.12 } }
function ns.CreateFeatureTag(parent, kind, tipTitle, tipBody, superscript)
    local c = ns.TAG_COLORS[kind] or ns.TAG_COLORS.new
    local tag = CreateFrame("Frame", nil, parent)
    tag:EnableMouse(true)
    -- Over its window's rows, never over other windows.
    tag:SetFrameLevel(parent:GetFrameLevel() + 10)
    local text = tag:CreateFontString(nil, "OVERLAY", superscript and "GameFontNormalTiny" or "GameFontNormalSmall")
    text:SetPoint("CENTER")
    text:SetText(kind == "exp" and ns.L["TAG_EXP"] or ((_G["NEW"] or "New"):upper()))
    text._efNoIndex = true   -- a badge, not a setting's name
    text:SetTextColor(1, 1, 1)
    text:SetShadowColor(c[1], c[2], c[3], 1)
    text:SetShadowOffset(1, -1)
    text._efOwnColor = true
    local w = text:GetStringWidth() + 4
    tag:SetSize(w, superscript and 10 or 14)
    local glow = tag:CreateTexture(nil, "BACKGROUND")
    glow:SetPoint("CENTER")
    glow:SetSize(w + (superscript and 16 or 24), superscript and 16 or 24)
    glow:SetAtlas("collections-newglow")
    glow:SetVertexColor(c[1], c[2], c[3], 0.5)
    glow:SetBlendMode("ADD")
    ns.CreateBouncePulse(glow, 0.8, 0.1, 1.5):Play()
    if tipTitle then
        Utils.AttachDelayedTooltip(tag, "ANCHOR_TOPLEFT", function() return tipTitle, tipBody end)
    end
    return tag
end

-- The game's color picker on a color: onPick(r, g, b) with every change
-- and on OK, onCancel() when it is put away unchanged.
function ns.PickColor(r, g, b, onPick, onCancel)
    local picker = ColorPickerFrame
    if not (picker and picker.SetupColorPickerAndShow) then return false end
    local function Read()
        if picker.GetColorRGB then
            local ok, rr, gg, bb = pcall(picker.GetColorRGB, picker)
            if ok and type(rr) == "number" then return rr, gg, bb end
        end
        local inner = picker.Content and picker.Content.ColorPicker
        if inner and inner.GetColorRGB then
            local ok, rr, gg, bb = pcall(inner.GetColorRGB, inner)
            if ok and type(rr) == "number" then return rr, gg, bb end
        end
        return r, g, b
    end
    picker:SetupColorPickerAndShow({
        r = r, g = g, b = b, hasOpacity = false,
        swatchFunc = function() onPick(Read()) end,
        cancelFunc = function()
            onPick(r, g, b)
            if onCancel then onCancel() end
        end,
    })
    if picker.SetFrameStrata then picker:SetFrameStrata("TOOLTIP") end
    if picker.Raise then picker:Raise() end
    return true
end

-- A superscript tag on a word: its foot on the middle of the text, just past
-- the last letter, so it sits raised like an exponent.
-- A word sized by its text carries the badge along through a later font or
-- text change (the chat's brand, restyled after this ran); one pinned at
-- both sides is measured.
function ns.SuperscriptTag(tag, fontString)
    tag:ClearAllPoints()
    if fontString:GetNumPoints() == 1 then
        tag:SetPoint("BOTTOMLEFT", fontString, "RIGHT", 1, 1)
    else
        tag:SetPoint("BOTTOMLEFT", fontString, "LEFT", (fontString:GetStringWidth() or 0) + 1, 1)
    end
end

function ns.CreateBounceFloat(region, offsetX, offsetY, duration)
    local animGroup = region:CreateAnimationGroup()
    animGroup:SetLooping("BOUNCE")
    local trans = animGroup:CreateAnimation("Translation")
    trans:SetOffset(offsetX or 0, offsetY or 0)
    trans:SetDuration(duration or 0.4)
    return animGroup, trans
end

function ns.CreateRoundedRectDivider(frame)
    if frame.combinedDivider then return frame.combinedDivider end
    local d = frame:CreateTexture(nil, "ARTWORK")
    d:SetColorTexture(BORDER_R, BORDER_G, BORDER_B, 1)
    d:SetHeight(1)
    d:Hide()
    frame.combinedDivider = d
    return d
end

function ns.SetRoundedRectDivider(frame, yOffset, shown)
    local d = frame.combinedDivider
    if not d then return end
    local inset = (frame.cbBarHeight or frame:GetHeight() or 0) / 4
    -- The Forever skin: a bronze line one screen pixel tall, band to band.
    if frame._efForeverOn then
        local b = ns.FOREVER_BRONZE
        d:SetColorTexture(b[1], b[2], b[3], b[4])
        inset = FOREVER.dividerInset
        local physH = GetPhysicalScreenSize and select(2, GetPhysicalScreenSize())
        local scale = d.GetEffectiveScale and d:GetEffectiveScale()
        d:SetHeight((physH and physH > 0 and scale and scale > 0) and 768 / physH / scale or 1)
    elseif frame._efSkin == "classic" then
        -- The Classic skin: a line in the metal border's gray, edge to
        -- edge (the metal's inner edge is the frame's own when it sits out).
        d:SetColorTexture(0.62, 0.62, 0.62, 0.9)
        d:SetHeight(1)
        inset = ns.ClassicHost(frame) ~= frame and 0 or ns.CLASSIC_BACKDROP.insets.left
    else
        local c = frame._efForeverSurface and ns.ForeverLineColor() or nil
        if c then d:SetColorTexture(c[1], c[2], c[3], c[4]) else d:SetColorTexture(BORDER_R, BORDER_G, BORDER_B, 1) end
        d:SetHeight(1)
    end
    d:ClearAllPoints()
    d:SetPoint("TOPLEFT",  frame, "TOPLEFT",  inset, -yOffset)
    d:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -inset, -yOffset)
    d:SetShown(shown and true or false)
end

function ns.SetSearchBorderShown(frame, shown)
    if not frame.searchBorder then return end
    local sb = frame.searchBorder
    sb.fillLeft:SetShown(shown)
    sb.fillMid:SetShown(shown)
    sb.fillRight:SetShown(shown)
    sb.borderLeft:SetShown(shown)
    sb.borderMid:SetShown(shown)
    sb.borderRight:SetShown(shown)
end

local EasyFindLeafFont = CreateFont("EasyFindLeafFont")
EasyFindLeafFont:CopyFontObject(baseFont)
EasyFindLeafFont:SetFont((baseFont:GetFont()), 10, select(3, baseFont:GetFont()))
ns.LEAF_FONT = "EasyFindLeafFont"

function Utils.DebugPrint(...)
    if EasyFind and EasyFind.db and EasyFind.db.devMode then
        print("|cff33ff99[EasyFind]|r", ...)
    end
end

local BUTTON_TEXT_KEYS = {"label", "Label", "text", "Text", "Name", "name"}
local FRAME_TEXT_KEYS = {"Label", "label", "Text", "text", "Name", "name"}
local frameTextScratch = {}

function Utils.GetButtonText(btn)
    if not btn then return nil end

    for i = 1, #BUTTON_TEXT_KEYS do
        local child = btn[BUTTON_TEXT_KEYS[i]]
        if child and child.GetText then
            local t = child:GetText()
            if t then return t end
        end
    end

    if btn.GetText then
        local t = btn:GetText()
        if t then return t end
    end

    local n = select("#", btn:GetRegions())
    local regions = { btn:GetRegions() }
    for i = 1, n do
        local region = regions[i]
        if region and region.GetObjectType and region:GetObjectType() == "FontString" then
            local t = region.GetText and region:GetText()
            if t then return t end
        end
    end

    return nil
end

function Utils.IsFrameOrChildMouseOver(frame)
    if not frame or not frame:IsShown() then return false end
    if frame:IsMouseOver() then return true end
    if frame.GetChildren then
        for i = 1, select("#", frame:GetChildren()) do
            local child = select(i, frame:GetChildren())
            if child and Utils.IsFrameOrChildMouseOver(child) then
                return true
            end
        end
    end
    return false
end

-- True when the mouse is on the minimap button or one of the broker
-- launchers (see brokerLauncherButtons in Core/Main.lua). Those toggle
-- on mouse-UP, so an outside-click closer must leave them alone or the
-- surface blinks shut and open again instead of toggling.
function Utils.IsMouseOnLauncherButton()
    local mmBtn = _G["EasyFindMinimapButton"]
    local launchers = ns.brokerLauncherButtons
    local function Hit(f)
        return f ~= nil and (f == mmBtn or (launchers ~= nil and launchers[f] == true))
    end
    if GetMouseFoci then
        local foci = GetMouseFoci()
        for i = 1, (foci and #foci or 0) do
            if Hit(foci[i]) then return true end
        end
        return false
    end
    return (GetMouseFocus ~= nil and Hit(GetMouseFocus())) or false
end

function Utils.IsFrameVisiblyMouseOver(frame)
    if type(frame) ~= "table" or not frame.IsMouseOver then return false end
    if frame.IsShown and not frame:IsShown() then return false end
    return ns.IsMouseOverWithBand(frame)
end

-- Click-guard registry: the ONE list of floating EasyFind windows whose
-- clicks must never read as "outside" to the persistent-surface closers
-- (results panel outside-click, search bar auto-hide). Register a frame,
-- or a global name for frames created lazily or owned by a companion
-- addon; names resolve per check so a frame that does not exist yet
-- leaves no nil hole. Registration only stops clicks from dismissing the
-- surfaces BENEATH a window; a transient menu registered here still
-- closes itself through its own closer.
local clickGuards = {}

function Utils.RegisterClickGuard(target)
    clickGuards[#clickGuards + 1] = target
end

function Utils.IsClickGuardMouseOver()
    for i = 1, #clickGuards do
        local guard = clickGuards[i]
        if type(guard) == "string" then guard = _G[guard] end
        if guard and Utils.IsFrameOrChildMouseOver(guard) then return true end
    end
    return false
end

-- A click outside the popup (and its owner or extra guards) hides it.
function Utils.AttachOutsideClickClose(popup, owner, extraGuards)
    if not popup or popup._efOutsideClose then return end
    popup._efOutsideClose = true
    popup:HookScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
    popup:HookScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
    popup:HookScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if ns.IsMouseOverWithBand(self) then return end
        if owner and owner.IsMouseOver and Utils.IsFrameVisiblyMouseOver(owner) then return end
        if extraGuards then
            for i = 1, #extraGuards do
                if Utils.IsFrameVisiblyMouseOver(extraGuards[i]) then return end
            end
        end
        self:Hide()
    end)
end

-- Windows that predate the registry, plus the Blizzard StaticPopup slots
-- our confirm flows use (their Apply/Exit/Cancel buttons must not dismiss
-- the panel that spawned them).
local PREREGISTERED_GUARDS = {
    "EasyFindUIFilterDropdown",
    "EasyFindUIAppsDropdown",
    "EasyFindUIAppsButton",
    "EasyFindUIWizard",
    "EasyFindPinPopup",
    "EasyFindThemedDialog",
    "EasyFindAsOptionsPopup",
    "EasyFindAsClassPopup",
    "EasyFindLootOptionsPopup",
    "EasyFindDiffPopup",
    "EasyFindSpecPopup",
    "EasyFindSpecFlyout",
    "EasyFindCalculatorFrame",
    "StaticPopup1", "StaticPopup2", "StaticPopup3", "StaticPopup4",
}
for i = 1, #PREREGISTERED_GUARDS do
    Utils.RegisterClickGuard(PREREGISTERED_GUARDS[i])
end

-- Position a cascading flyout to the right of its anchor, flipping to the left
-- when it would run off the right screen edge (standard menu behaviour), and
-- clamping so a deep/tall chain can't end up partly off-screen. Width and scale
-- must already be set on the popup before this is called.
-- Position a cascading flyout beside its anchor and keep it fully on-screen on
-- all four edges. Prefers the right side, flips to the left when the right would
-- overflow, then clamps horizontally and vertically. Works for deeply nested
-- chains by positioning each flyout absolutely against the screen rather than
-- letting a cascade run off the edge. Width/height/scale must be set first.
-- Menus keep this far inside the screen's edge: their border art draws
-- outside the frame, and a frame flush with the edge lost it.
Utils.MENU_EDGE = 8

function Utils.ClampMenu(popup, s)
    if not popup.SetClampedToScreen then return end
    popup:SetClampedToScreen(true)
    local m = Utils.MENU_EDGE / (s or popup:GetEffectiveScale() or 1)
    popup:SetClampRectInsets(-m, m, m, -m)
end

function Utils.OpenFlyoutBeside(popup, anchorFrame, gap)
    gap = gap or 4
    popup:ClearAllPoints()
    local ui = UIParent
    local s = popup:GetEffectiveScale()
    if not s or s == 0 then s = 1 end
    local screenW = (ui:GetWidth() or 0) * (ui:GetEffectiveScale() or 1)
    local screenH = (ui:GetHeight() or 0) * (ui:GetEffectiveScale() or 1)
    local aScale = anchorFrame:GetEffectiveScale() or 1
    local aLeft = (anchorFrame:GetLeft() or 0) * aScale
    local aRight = (anchorFrame:GetRight() or 0) * aScale
    local aTop = (anchorFrame:GetTop() or 0) * aScale
    local pW = (popup:GetWidth() or 0) * s
    local pH = (popup:GetHeight() or 0) * s
    local gapPx = gap * s
    local edge = Utils.MENU_EDGE

    -- Horizontal: right if it fits, else left if it fits, else the roomier side.
    local x
    if (screenW - aRight - edge) >= (pW + gapPx) then
        x = aRight + gapPx
    elseif (aLeft - gapPx - pW - edge) >= 0 then
        x = aLeft - gapPx - pW
    elseif (screenW - aRight) >= aLeft then
        x = aRight + gapPx
    else
        x = aLeft - gapPx - pW
    end
    if x + pW > screenW - edge then x = screenW - edge - pW end
    if x < edge then x = edge end

    -- Vertical: top-align with the anchor, then keep both edges on-screen.
    local top = aTop
    if top - pH < edge then top = pH + edge end
    if top > screenH - edge then top = screenH - edge end

    popup:SetPoint("TOPLEFT", ui, "BOTTOMLEFT", x / s, top / s)
    Utils.ClampMenu(popup, s)
end

-- Position a dropdown list directly below its button, kept fully on-screen:
-- left-aligned with the button (clamped horizontally), dropping down, and
-- flipping above the button if it would run off the bottom. Size/scale first.
function Utils.OpenDropdownBelow(popup, button, gap)
    gap = gap or 2
    popup:ClearAllPoints()
    local ui = UIParent
    local s = popup:GetEffectiveScale()
    if not s or s == 0 then s = 1 end
    local screenW = (ui:GetWidth() or 0) * (ui:GetEffectiveScale() or 1)
    local screenH = (ui:GetHeight() or 0) * (ui:GetEffectiveScale() or 1)
    local bScale = button:GetEffectiveScale() or 1
    local bLeft = (button:GetLeft() or 0) * bScale
    local bTop = (button:GetTop() or 0) * bScale
    local bBottom = (button:GetBottom() or 0) * bScale
    local pW = (popup:GetWidth() or 0) * s
    local pH = (popup:GetHeight() or 0) * s
    local gapPx = gap * s

    local edge = Utils.MENU_EDGE
    local x = bLeft
    if x + pW > screenW - edge then x = screenW - edge - pW end
    if x < edge then x = edge end

    -- Drop below; flip above when it would overflow the bottom.
    local top = bBottom - gapPx
    if top - pH < edge then top = bTop + gapPx + pH end
    if top > screenH - edge then top = screenH - edge end
    if top - pH < edge then top = pH + edge end

    popup:SetPoint("TOPLEFT", ui, "BOTTOMLEFT", x / s, top / s)
    Utils.ClampMenu(popup, s)
end

-- Shared "dropdown button" used by every filter selector: a styled button
-- (background + right arrow + left-aligned label) that toggles a popup list
-- below it (clamped on-screen) and dismisses on outside-click. Eliminates the
-- per-selector duplication of this exact widget.
--   opts: parent, x, y, width, height(27), popup, layout(fn before show),
--         getScale(fn), guardFrames(list), extraGuards(frames kept open)
-- returns button, SetLabelText(text)
function Utils.CreateDropdownButton(opts)
    local btn = CreateFrame("Button", nil, opts.parent)
    btn:SetSize(opts.width, opts.height or 27)
    if opts.x then btn:SetPoint("TOPLEFT", opts.parent, "TOPLEFT", opts.x, opts.y or 0) end
    local bg = btn:CreateTexture(nil, "BACKGROUND")
    Utils.StyleDropdownBg(bg)
    local arrow = btn:CreateTexture(nil, "OVERLAY")
    arrow:SetAtlas("common-dropdown-a-button-hover")
    arrow:SetSize(22, 22)
    arrow:SetPoint("RIGHT", -10, -1)
    -- The textholder pill art stays dark on every theme, so the arrow
    -- and label keep the light-on-dark scheme; theme tints here read
    -- as dark-on-dark. _efOwnColor opts the label out of the menu text
    -- walk and flips SetFlyoutRowEnabled's enabled color to white.
    arrow:SetVertexColor(0.7, 0.7, 0.7)
    local label = btn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", 14, 0)
    label:SetPoint("RIGHT", arrow, "LEFT", -2, 0)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label._efOwnColor = true
    btn:SetScript("OnEnter", function() arrow:SetVertexColor(1, 1, 1) end)
    btn:SetScript("OnLeave", function() arrow:SetVertexColor(0.7, 0.7, 0.7) end)
    btn._label = label
    btn._chev = arrow

    local popup = opts.popup
    if popup then
        local getScale = opts.getScale or function() return 1.0 end
        btn:SetScript("OnClick", function()
            if popup:IsShown() then popup:Hide(); return end
            if opts.layout then opts.layout() end
            popup:SetScale(getScale())
            Utils.OpenDropdownBelow(popup, btn, 2)
            popup:Show()
        end)
        popup:HookScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
        popup:HookScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
        popup:HookScript("OnEvent", function(self, event)
            if event ~= "GLOBAL_MOUSE_DOWN" then return end
            if self:IsMouseOver() or btn:IsMouseOver() then return end
            local guards = opts.extraGuards
            if guards then
                for i = 1, #guards do
                    if Utils.IsFrameVisiblyMouseOver(guards[i]) then return end
                end
            end
            self:Hide()
        end)
        if opts.guardFrames then opts.guardFrames[#opts.guardFrames + 1] = popup end
    end

    return btn, function(text) label:SetText(text) end
end

function Utils.AttachHoverPopup(owner, popup, opts)
    if not owner or not popup then return nil end
    opts = opts or {}

    local delay = opts.delay or 0.3
    local extraGuards = opts.extraGuards or {}
    local chainGuards = opts.chainGuards
    local hideTimer

    local function CancelHide()
        if hideTimer then
            hideTimer:Cancel()
            hideTimer = nil
        end
    end

    local function GuardIsMouseOver(guard)
        if type(guard) == "function" then
            return Utils.IsFrameVisiblyMouseOver(guard())
        end
        return Utils.IsFrameVisiblyMouseOver(guard)
    end

    local function ShouldStayOpen()
        if owner.IsMouseOver and owner:IsMouseOver() then return true end
        if popup.IsMouseOver and popup:IsMouseOver() then return true end
        for i = 1, #extraGuards do
            if GuardIsMouseOver(extraGuards[i]) then return true end
        end
        -- Keep the whole open menu chain alive: don't close while the mouse is
        -- over any currently-shown popup in the same menu. This lets the user
        -- move diagonally to a flyout that opened on the opposite side (crossing
        -- the parent menu in between) without it auto-closing.
        if chainGuards then
            local frames = type(chainGuards) == "function" and chainGuards() or chainGuards
            if frames then
                for i = 1, #frames do
                    if Utils.IsFrameVisiblyMouseOver(frames[i]) then return true end
                end
            end
        end
        return opts.keepOpen and opts.keepOpen(owner, popup) or false
    end

    local function HideNow()
        if ShouldStayOpen() then return end
        popup:Hide()
    end

    local function ScheduleHide()
        CancelHide()
        hideTimer = C_Timer.NewTimer(delay, function()
            hideTimer = nil
            HideNow()
        end)
    end

    local function Show()
        CancelHide()
        if opts.onShow then
            opts.onShow(owner, popup)
        else
            popup:Show()
        end
    end

    owner:HookScript("OnEnter", Show)
    owner:HookScript("OnLeave", ScheduleHide)
    popup:HookScript("OnEnter", CancelHide)
    popup:HookScript("OnLeave", ScheduleHide)

    -- Keep the owning menu row highlighted while its flyout is open, so it
    -- stays clear which row opened the submenu even while the cursor is on
    -- the flyout. Registered as a hold so hovering a sibling row transfers
    -- the highlight immediately instead of waiting out the hide grace.
    if owner.LockHighlight then
        local function HoldHighlight()
            -- SetHoldVisual, not raw LockHighlight: wash themes run the
            -- built-in highlight texture at alpha 0, so the raw lock showed
            -- nothing once the cursor left the owner for the popup.
            SetHoldVisual(owner, true)
            local _, hold = FindFlyoutHighlightHold(owner, popup)
            if hold then
                hold.held = true
            else
                tinsert(flyoutHighlightHolds, { owner = owner, popup = popup, held = true })
            end
        end
        popup:HookScript("OnShow", HoldHighlight)
        popup:HookScript("OnEnter", HoldHighlight)
        owner:HookScript("OnEnter", function()
            if popup:IsShown() then HoldHighlight() end
        end)
        popup:HookScript("OnHide", function()
            SetHoldVisual(owner, false)
            local i = FindFlyoutHighlightHold(owner, popup)
            if i then tremove(flyoutHighlightHolds, i) end
        end)
    end

    return {
        CancelHide = CancelHide,
        HideNow = HideNow,
        ScheduleHide = ScheduleHide,
        Show = Show,
    }
end

function Utils.GetAllFrameText(frame)
    if not frame then return nil end
    wipe(frameTextScratch)
    local texts = frameTextScratch

    for i = 1, #FRAME_TEXT_KEYS do
        local child = frame[FRAME_TEXT_KEYS[i]]
        if child and child.GetText then
            local t = child:GetText()
            if t then texts[#texts + 1] = t end
        end
    end

    if frame.GetText then
        local t = frame:GetText()
        if t then texts[#texts + 1] = t end
    end

    local n = select("#", frame:GetRegions())
    local regions = { frame:GetRegions() }
    for i = 1, n do
        local region = regions[i]
        if region and region.GetObjectType and region:GetObjectType() == "FontString" then
            local t = region.GetText and region:GetText()
            if t then texts[#texts + 1] = t end
        end
    end

    if #texts > 0 then
        return tconcat(texts, " ")
    end
    return nil
end

function Utils.SearchFrameTreeFuzzy(frame, searchTextLower, maxDepth)
    maxDepth = maxDepth or 6
    local function search(f, depth)
        if not f or depth > maxDepth then return nil end
        if f:IsShown() then
            local w, h = f:GetSize()
            if w and h and w > 80 and h > 20 and w < 500 then
                local text = Utils.GetAllFrameText(f)
                if text and sfind(slower(text), searchTextLower, 1, true) then
                    if f.Click or (f.IsMouseEnabled and f:IsMouseEnabled()) then
                        return f
                    end
                end
            end
        end
        for i = 1, select("#", f:GetChildren()) do
            local child = select(i, f:GetChildren())
            local result = search(child, depth + 1)
            if result then return result end
        end
        return nil
    end
    return search(frame, 0)
end

function Utils.GetFrameByPath(path)
    if not path then return nil end
    local parts = { strsplit(".", path) }
    local current = _G[parts[1]]
    for i = 2, #parts do
        if current then
            current = current[parts[i]]
        else
            return nil
        end
    end
    return current
end

-- opts.moreBelow: a chevron at the view's foot while content lies past it (settings pages).
function Utils.CreateMinimalScrollBar(scrollFrame, parent, opts)
    local THUMB_W = ns.SCROLLBAR_THUMB_W
    local EDGE_INSET = ns.SCROLLBAR_EDGE_INSET
    local VERT_PAD = 4
    local MIN_THUMB_H = 14
    local FADE_HOLD = 0.6
    local FADE_OUT = 0.25
    local WHEEL_STEP = 90
    local SCROLL_LERP = 0.30
    local SCROLL_EPS = 0.5

    local bar = CreateFrame("Frame", nil, parent)
    bar:SetWidth(THUMB_W)
    bar:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", -EDGE_INSET, -VERT_PAD)
    bar:SetPoint("BOTTOMRIGHT", scrollFrame, "BOTTOMRIGHT", -EDGE_INSET, VERT_PAD)
    bar:SetFrameStrata(parent:GetFrameStrata())
    bar:SetFrameLevel(parent:GetFrameLevel() + 5)
    bar:EnableMouse(true)

    bar.UpdateBarHeight = function() end

    local track = CreateFrame("Frame", nil, bar)
    track:SetAllPoints(bar)

    local thumb = CreateFrame("Button", nil, track)
    thumb:SetWidth(THUMB_W)
    thumb:EnableMouse(true)
    -- The thumb is a hairline: it takes the mouse a few pixels to either
    -- side (the track does not, so the list's own edge stays clickable).
    thumb:SetHitRectInsets(-5, -4, -3, -3)

    local capH = THUMB_W * 0.5

    local thumbBody = thumb:CreateTexture(nil, "ARTWORK")
    thumbBody:SetColorTexture(1, 1, 1, 1)
    thumbBody:SetPoint("TOPLEFT", thumb, "TOPLEFT", 0, -capH)
    thumbBody:SetPoint("BOTTOMRIGHT", thumb, "BOTTOMRIGHT", 0, capH)

    local thumbTop = thumb:CreateTexture(nil, "ARTWORK")
    thumbTop:SetColorTexture(1, 1, 1, 1)
    thumbTop:SetSize(THUMB_W, capH)
    thumbTop:SetPoint("TOP", thumb, "TOP", 0, 0)

    local topMask = thumb:CreateMaskTexture()
    topMask:SetTexture(ns.PORTRAIT_ALPHA_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    topMask:SetSize(THUMB_W, THUMB_W)
    topMask:SetPoint("TOP", thumb, "TOP", 0, 0)
    thumbTop:AddMaskTexture(topMask)

    local thumbBot = thumb:CreateTexture(nil, "ARTWORK")
    thumbBot:SetColorTexture(1, 1, 1, 1)
    thumbBot:SetSize(THUMB_W, capH)
    thumbBot:SetPoint("BOTTOM", thumb, "BOTTOM", 0, 0)

    local botMask = thumb:CreateMaskTexture()
    botMask:SetTexture(ns.PORTRAIT_ALPHA_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    botMask:SetSize(THUMB_W, THUMB_W)
    botMask:SetPoint("BOTTOM", thumb, "BOTTOM", 0, 0)
    thumbBot:AddMaskTexture(botMask)

    local function SetThumbAlpha(a)
        thumbBody:SetAlpha(a)
        thumbTop:SetAlpha(a)
        thumbBot:SetAlpha(a)
    end
    local function SetThumbNormal() SetThumbAlpha(0.55) end
    local function SetThumbOver()  SetThumbAlpha(0.85) end
    SetThumbNormal()

    thumb:SetScript("OnEnter", SetThumbOver)
    thumb:SetScript("OnLeave", function()
        if not bar.isDragging then SetThumbNormal() end
    end)

    bar:SetAlpha(0)
    bar._lastActivity = 0
    bar._fadingOut = false
    bar._scrollTarget = nil
    bar.isDragging = false
    bar.dragOffset = 0

    function bar:NudgeVisible()
        self._lastActivity = GetTime()
        self._fadingOut = false
        if self:IsShown() then self:SetAlpha(1) end
        -- Self-disarming driver: every activity path lands here, so this
        -- is the ONE arm point. The driver removes itself once there is
        -- nothing left to do (no drag, no ease, fade complete), so an
        -- idle results list runs no per-frame scrollbar code at all --
        -- profiled as a constant per-frame cost whenever results were
        -- open before this.
        if not self._driverArmed and self.ArmDriver then self:ArmDriver() end
    end

    local function ScrollByDelta(delta)
        local range = scrollFrame:GetVerticalScrollRange()
        if range <= 0 then return end
        local current = bar._scrollTarget or scrollFrame:GetVerticalScroll()
        bar._scrollTarget = mmax(0, mmin(range, current - delta * WHEEL_STEP))
        bar:NudgeVisible()
    end
    bar.ScrollByDelta = function(_, delta) ScrollByDelta(delta) end

    thumb:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        bar.isDragging = true
        bar._scrollTarget = nil
        local _, cursorY = GetCursorPosition()
        local scale = self:GetEffectiveScale()
        bar.dragOffset = cursorY / scale - self:GetTop()
        SetThumbOver()
        bar:NudgeVisible()
    end)

    thumb:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        bar.isDragging = false
        if not self:IsMouseOver() then SetThumbNormal() end
        bar:NudgeVisible()
    end)

    local function ScrollBarDriver(self)
        if self.isDragging then
            if not IsMouseButtonDown("LeftButton") then
                self.isDragging = false
                if not thumb:IsMouseOver() then SetThumbNormal() end
            else
                local range = scrollFrame:GetVerticalScrollRange()
                if range > 0 then
                    local _, cursorY = GetCursorPosition()
                    local scale = track:GetEffectiveScale()
                    cursorY = cursorY / scale
                    local trackT = track:GetTop()
                    local thumbH = thumb:GetHeight()
                    local travel = track:GetHeight() - thumbH
                    if travel > 0 then
                        local pos = trackT - (cursorY - self.dragOffset)
                        local ratio = mmax(0, mmin(1, pos / travel))
                        scrollFrame:SetVerticalScroll(ratio * range)
                    end
                end
            end
            self:NudgeVisible()
            return
        end

        if self._scrollTarget then
            local cur = scrollFrame:GetVerticalScroll()
            local diff = self._scrollTarget - cur
            if mabs(diff) < SCROLL_EPS then
                scrollFrame:SetVerticalScroll(self._scrollTarget)
                self._scrollTarget = nil
            else
                scrollFrame:SetVerticalScroll(cur + diff * SCROLL_LERP)
            end
            self:NudgeVisible()
        end

        if self:GetAlpha() <= 0 then
            -- Nothing left to animate: fade finished (or never started)
            -- with no drag and no ease in flight. Disarm entirely.
            self._driverArmed = false
            self:SetScript("OnUpdate", nil)
            return
        end
        local idle = GetTime() - self._lastActivity
        if idle < FADE_HOLD then return end
        if not self._fadingOut then
            self._fadingOut = true
            self._fadeStart = GetTime()
        end
        local t = (GetTime() - self._fadeStart) / FADE_OUT
        if t >= 1 then
            self:SetAlpha(0)
            self._fadingOut = false
            self._driverArmed = false
            self:SetScript("OnUpdate", nil)
        else
            self:SetAlpha(1 - t)
        end
    end

    function bar:ArmDriver()
        self._driverArmed = true
        Utils.SafeOnUpdate(self, ScrollBarDriver)
    end

    track:EnableMouse(true)
    track:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        local range = scrollFrame:GetVerticalScrollRange()
        if range <= 0 then return end

        local _, cursorY = GetCursorPosition()
        local scale = self:GetEffectiveScale()
        cursorY = cursorY / scale

        local trackT = self:GetTop()
        local trackH = self:GetHeight()
        if trackH <= 0 then return end

        local ratio = (trackT - cursorY) / trackH
        bar._scrollTarget = mmax(0, mmin(range, ratio * range))
        bar:NudgeVisible()
    end)

    bar._contentH = nil
    bar._viewH = nil

    function bar:UpdateThumb(contentH, viewH)
        if contentH then self._contentH = contentH end
        if viewH then self._viewH = viewH end
        contentH = contentH or self._contentH
        viewH = viewH or self._viewH or scrollFrame:GetHeight()
        local range = contentH and (contentH - viewH) or scrollFrame:GetVerticalScrollRange()
        if not range or range <= 0 then
            thumb:Hide()
            return
        end

        local trackH = track:GetHeight()
        if trackH <= 0 then
            thumb:Hide()
            return
        end

        contentH = contentH or (viewH + range)
        local thumbH = mmax(MIN_THUMB_H, trackH * (viewH / contentH))
        thumb:SetHeight(thumbH)

        local travel = trackH - thumbH
        local scrollPos = scrollFrame:GetVerticalScroll()
        local ratio = mmax(0, mmin(1, (range > 0) and (scrollPos / range) or 0))

        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", track, "TOP", 0, -(ratio * travel))
        thumb:Show()
    end

    scrollFrame:SetScript("OnVerticalScroll", function()
        bar:UpdateThumb()
        bar:NudgeVisible()
    end)

    bar:EnableMouseWheel(true)
    bar:SetScript("OnMouseWheel", function(_, delta) ScrollByDelta(delta) end)

    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(_, delta) ScrollByDelta(delta) end)

    bar:SetScript("OnShow", function(self)
        self:SetAlpha(0)
        self._lastActivity = 0
        self._fadingOut = false
        self._scrollTarget = nil
        Utils.SafeAfter(0, function()
            if self:IsShown() then self:UpdateThumb() end
        end)
    end)

    -- More below: a faint chevron at the view's bottom while content lies
    -- past it, gone once scrolled to the end, so a page never reads as
    -- all there is. Only where asked for: a chat or a list says enough.
    if not (opts and opts.moreBelow) then
        bar:Hide()
        return bar
    end
    local moreFrame = CreateFrame("Frame", nil, parent)
    -- A new frame starts shown; a page that fits never updates it.
    moreFrame:Hide()
    moreFrame:SetSize(14, 10)
    -- Under the view, in the page's margin: never over its last row.
    moreFrame:SetPoint("TOP", scrollFrame, "BOTTOM", 0, -2)
    moreFrame:SetFrameLevel(parent:GetFrameLevel() + 6)
    local more = moreFrame:CreateTexture(nil, "OVERLAY")
    more:SetAllPoints()
    Utils.SetChevronTexture(more)
    more:SetRotation(0)   -- the art as drawn points down
    more:SetAlpha(0.55)
    local function UpdateMore()
        local range = scrollFrame:GetVerticalScrollRange() or 0
        moreFrame:SetShown(bar:IsShown() and range > 1 and scrollFrame:GetVerticalScroll() < range - 1)
    end
    bar.UpdateMore = UpdateMore
    local updateThumb = bar.UpdateThumb
    bar.UpdateThumb = function(self, ...)
        updateThumb(self, ...)
        UpdateMore()
    end
    bar:HookScript("OnShow", function() Utils.SafeAfter(0, UpdateMore) end)
    bar:HookScript("OnHide", function() moreFrame:Hide() end)
    scrollFrame:HookScript("OnVerticalScroll", UpdateMore)

    bar:Hide()
    return bar
end

function Utils.ScrollBoxScrollTo(scrollBox, matchFn, fallbackFraction)
    if not scrollBox then return end

    local dataProvider = scrollBox.GetDataProvider and scrollBox:GetDataProvider()
    if dataProvider then
        local finder = dataProvider.FindElementDataByPredicate or dataProvider.FindByPredicate
        if finder then
            local scrollData = finder(dataProvider, matchFn)
            if scrollData then
                local alignCenter = ScrollBoxConstants and ScrollBoxConstants.AlignCenter
                scrollBox:ScrollToElementData(scrollData, alignCenter)
                return
            end
        end
    end

    if fallbackFraction and scrollBox.SetScrollPercentage then
        scrollBox:SetScrollPercentage(fallbackFraction)
    end
end

function Utils.ScrollBoxFindButton(scrollBox, matchFn)
    if not scrollBox or not scrollBox.EnumerateFrames then return nil end
    for _, btn in scrollBox:EnumerateFrames() do
        if btn and btn:IsShown() and matchFn(btn) then
            return btn
        end
    end
    return nil
end

-- Pure data predicate for abilities that live only in the spellbook
-- (passives, unlearned ranks): they never cast, their activation opens
-- the spellbook. Owned here so Shared-layer classification (SecureOpeners)
-- does not reach into Search-layer modules; Icons:IsSpellbookOnlyAbility
-- delegates to this.
function Utils.IsSpellbookOnlyAbility(data)
    return data and data.category == "Ability" and data.spellID and data.isSpellbookOnly
end

-- True when a guide cannot start in combat: its first clickable step
-- targets a PROTECTED frame. Capability check via IsProtected, never a
-- category list; guides whose targets are unprotected run in combat like
-- anything else. Deliberately SILENT: blocked-in-combat actions do
-- nothing, no chat notice.
function Utils.GuideBlockedInCombat(guideData)
    if not InCombatLockdown() then return false end
    local steps = guideData and guideData.steps
    local first = steps and steps[1]
    local target = first and first.buttonFrame
    if not target then return false end
    local frame = (Utils.GetFrameByPath and Utils.GetFrameByPath(target)) or _G[target]
    if frame and frame.IsProtected and frame:IsProtected() then
        return true
    end
    return false
end

function Utils.ClickButton(btn, mouseButton)
    if not btn then return false end
    -- Combat capability check, not category guesses: clicking a PROTECTED
    -- button from insecure code in combat is an ADDON_ACTION_BLOCKED error,
    -- so refuse only those; everything unprotected proceeds normally.
    if InCombatLockdown() and btn.IsProtected and btn:IsProtected() then
        Utils.DebugPrint("ClickButton refused: protected button in combat")
        return false
    end
    mouseButton = mouseButton or "LeftButton"
    if btn.Click then
        local ok, err = xpcall(btn.Click, ErrorHandler, btn, mouseButton)
        if ok then return true end
        Utils.DebugPrint("Button click failed: " .. tostring(err))
        return false
    end
    local hasScript, onClick = pcall(btn.GetScript, btn, "OnClick")
    if hasScript and onClick then
        -- Fallback skips PreClick/PostClick and the secure click path.
        local ok, err = xpcall(onClick, ErrorHandler, btn, mouseButton, false)
        if ok then return true end
        Utils.DebugPrint("Button OnClick failed: " .. tostring(err))
    end
    -- A plain frame that answers the mouse (Forever's character mode
    -- tabs): its down and up scripts, in order. Forever only; retail's
    -- behavior for a frame without a click stays as it was.
    local okD, onDown = false, nil
    local okU, onUp = false, nil
    if ns.Caps and ns.Caps.forever then
        okD, onDown = pcall(btn.GetScript, btn, "OnMouseDown")
        okU, onUp = pcall(btn.GetScript, btn, "OnMouseUp")
    end
    if (okD and onDown) or (okU and onUp) then
        local ok = true
        if okD and onDown then ok = xpcall(onDown, ErrorHandler, btn, mouseButton) end
        if ok and okU and onUp then ok = xpcall(onUp, ErrorHandler, btn, mouseButton, true) end
        if ok then return true end
    end
    return false
end

function Utils.CreateClearButton(parent, globalName)
    local btn = CreateFrame("Button", globalName, parent)
    btn:SetSize(ns.CLEAR_BTN_SIZE, ns.CLEAR_BTN_SIZE)
    btn:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    btn:EnableMouse(true)
    btn:Hide()

    local normal = btn:CreateTexture(nil, "ARTWORK")
    normal:SetAllPoints()
    normal:SetTexture(CLEAR_BTN_TEX)
    btn:SetNormalTexture(normal)

    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetTexture(CLEAR_BTN_TEX)
    highlight:SetVertexColor(1.3, 1.3, 1.3, 1)
    highlight:SetBlendMode("ADD")
    btn:SetHighlightTexture(highlight)

    return btn
end

-- Pool cycles through members so each open uses a freshly-laid-out menu.
-- Avoids state-leak bugs where the second open of a cached menu inherits
-- stale flags from the first close (backdrop tile, alpha after click, etc).
local cursorMenuPool = {}
local cursorMenuCounter = 0

local function FindFreeMenu(globalName)
    local pool = cursorMenuPool[globalName]
    if not pool then return nil end
    for i = 1, #pool do
        local menu = pool[i]
        if menu and not menu:IsShown() then return menu end
    end
    return nil
end

local function HideOtherMenus(globalName, except)
    local pool = cursorMenuPool[globalName]
    if not pool then return end
    for i = 1, #pool do
        local menu = pool[i]
        if menu and menu ~= except and menu:IsShown() then menu:Hide() end
    end
end

function Utils.HideCursorMenus(globalName)
    local closedAny = false
    local function hidePool(pool)
        if not pool then return end
        for i = 1, #pool do
            local menu = pool[i]
            if menu and menu:IsShown() then
                menu:Hide()
                closedAny = true
            end
        end
    end
    if globalName then
        hidePool(cursorMenuPool[globalName])
    else
        for _, pool in pairs(cursorMenuPool) do
            hidePool(pool)
        end
    end
    return closedAny
end

-- The click handler of a button that owns a menu: closes the named menu
-- when it is open, otherwise shows it. Same arguments as ShowCursorMenu;
-- the caller passes itself as opts.toggleOwner so the menu's outside-click
-- closer leaves the owner's mouse-down alone (that down-edge would
-- otherwise close the menu and this call would reopen it on the up-edge).
-- Returns the menu, or nil when the click closed one.
function Utils.ToggleCursorMenu(globalName, rows, opts)
    if Utils.HideCursorMenus(globalName) then return nil end
    return Utils.ShowCursorMenu(globalName, rows, opts)
end

-- Ground truth for "is the cursor on this menu": the focus stack that actually
-- receives clicks, walked up so a row (a descendant) counts as the menu. More
-- reliable than IsMouseOver rectangle math for a just-shown flyout.
local function MouseFocusOwnedBy(target)
    local foci = GetMouseFoci and GetMouseFoci()
    if foci then
        for i = 1, #foci do
            local f = foci[i]
            while f do
                if f == target then return true end
                f = f.GetParent and f:GetParent()
            end
        end
    elseif GetMouseFocus then
        local f = GetMouseFocus()
        while f do
            if f == target then return true end
            f = f.GetParent and f:GetParent()
        end
    end
    return false
end

local function CursorMenuHasMouse(self)
    if ns.IsMouseOverWithBand(self) then return true end
    if self.rows then
        for i = 1, #self.rows do
            if Utils.IsFrameVisiblyMouseOver(self.rows[i]) then
                return true
            end
        end
    end
    if MouseFocusOwnedBy(self) then return true end
    return false
end

-- True if the cursor is over any active cursor menu or its open flyout chain.
-- The results window's outside-click closer consults this: a context-menu
-- submenu is a separate pooled frame (parented to UIParent, not a child of the
-- pin popup), so a click on it must not be misread as a click outside the panel.
function Utils.IsCursorMenuMouseOver()
    for _, pool in pairs(cursorMenuPool) do
        for i = 1, #pool do
            local menu = pool[i]
            if menu and menu:IsShown() and CursorMenuHasMouse(menu) then
                return true
            end
        end
    end
    return false
end

local SUBMENU_GLOBAL = "EasyFindCursorSubmenu"

-- True if the mouse is over any menu in this cascade: the root plus every open
-- descendant flyout. Walked from the root so a parent never closes while its
-- submenu is hovered, and a submenu never closes while its owning row (up in the
-- parent) is hovered. Both directions resolve to the same chain.
local function CursorMenuChainHasMouse(menu)
    local root = menu
    while root._parentMenu do root = root._parentMenu end
    local node = root
    while node do
        if node:IsShown() and CursorMenuHasMouse(node) then return true end
        node = node._openSubmenu
    end
    return false
end

local function CursorMenuCloseSubmenu(menu)
    local child = menu._openSubmenu
    -- Result-row pattern: the owning row was explicitly LOCKED when its child
    -- opened; unlock it here, the one place submenus close from.
    if menu._openSubmenuRow and menu._openSubmenuRow.SetMenuHighlightFocused then
        menu._openSubmenuRow:SetMenuHighlightFocused(false)
    end
    menu._openSubmenu = nil
    menu._openSubmenuRow = nil
    -- A pending sibling-brush close dies with this flyout: the pooled frame
    -- comes back as the next row's flyout, which it would close.
    menu._subCloseToken = (menu._subCloseToken or 0) + 1
    if child then child:Hide() end
end

-- Reaching a row (by hover or keyboard): a row carrying its own submenu opens it
-- beside itself; reaching any other row closes whatever submenu was open. This
-- is the same hover-cascade every other flyout in the addon uses, via
-- OpenFlyoutBeside for placement.
local function CursorMenuRowEntered(menu, row)
    -- In a flyout: its row in the menu above lights again, the way back.
    local parent = menu._parentMenu
    local parentRow = parent and parent._openSubmenu == menu and parent._openSubmenuRow
    if parentRow and parentRow.SetMenuHighlightFocused then parentRow:SetMenuHighlightFocused(true) end
    local owner = menu._openSubmenuRow
    if owner == row then
        menu._subCloseToken = (menu._subCloseToken or 0) + 1
        if row.SetMenuHighlightFocused then row:SetMenuHighlightFocused(true) end
    end
    if owner and owner ~= row then
        if row._submenuRows and not row.disabled then
            CursorMenuCloseSubmenu(menu)
        else
            -- The highlight follows the cursor at once; the flyout stays a
            -- moment for a brush over a sibling on the way to it, and closes
            -- if the cursor has not reached it by then.
            if owner.SetMenuHighlightFocused then owner:SetMenuHighlightFocused(false) end
            local open = menu._openSubmenu
            menu._subCloseToken = (menu._subCloseToken or 0) + 1
            local token = menu._subCloseToken
            Utils.SafeAfter(0.4, function()
                if menu._subCloseToken ~= token or not open or menu._openSubmenu ~= open then return end
                local node = open
                while node do
                    if node:IsShown() and CursorMenuHasMouse(node) then return end
                    node = node._openSubmenu
                end
                CursorMenuCloseSubmenu(menu)
            end)
            return
        end
    end
    if not row._submenuRows or row.disabled then return end
    if menu._openSubmenu and menu._openSubmenu:IsShown() and menu._openSubmenuRow == row then return end
    -- A function-typed submenu spec is a live rows provider: called on every
    -- open AND stored so keepOpen toggles can reshow with fresh check marks.
    local spec = row._submenuRows
    local provider
    if type(spec) == "function" then
        provider = spec
        spec = spec()
    end
    -- Pool per DEPTH: ShowCursorMenu opens by hiding other menus of the
    -- same name, so one shared submenu name meant a third-level flyout hid
    -- its own parent and got the parent's freed frame back as itself
    -- (circular anchor). A depth suffix displaces only same-level siblings.
    local depth = (menu._submenuDepth or 0) + 1
    local child = Utils.ShowCursorMenu(SUBMENU_GLOBAL .. depth, spec, {
        scale = menu:GetScale(),
        strata = menu:GetFrameStrata(),
        level = menu:GetFrameLevel() + 20,
        anchorBeside = row,
        parentMenu = menu,
        labelFontObject = menu._labelFontObject,
        iconSide = menu._iconSide,
        rowsProvider = provider,
        search = row._efSubmenuSearch,
        maxRows = row._efSubmenuMaxRows,
        liveSearch = row._efSubmenuLive,
    })
    child._submenuDepth = depth
    menu._openSubmenu = child
    menu._openSubmenuRow = row
    -- Result-row pattern: LOCK the owning row for the child's whole lifetime
    -- (explicit lock at open, explicit unlock at close -- never derived
    -- per-frame from mutable cascade links).
    if row.SetMenuHighlightFocused then row:SetMenuHighlightFocused(true) end
    -- Sit above any sibling at this strata so the flyout's rows, not an
    -- overlapping frame, receive the click.
    if child and child.Raise then Utils.RaiseMenu(child) end
end

-- Copy rows (def.copy): a menu row whose action is the OS clipboard.
-- Addons cannot write the clipboard, so the gesture IS Ctrl+C: the row
-- wears a dim "Ctrl+C" hint that lights while the row is engaged (hovered
-- or keyboard-selected), Ctrl held over it fills the hidden clipboard box
-- with the row's text, and the C of the chord is the native copy. A click
-- or Enter on the row arms the box too and leaves the menu open, so the
-- chord that follows lands; nothing ever dead-ends in a second prompt.
-- Engagement is read off the same per-frame highlight drive the pills
-- use, so it survives everything the pills survive.
local MenuCopy = { row = nil, menu = nil, armedRow = nil }

function MenuCopy.PaintHint(row, lit)
    if not row.hint then return end
    if row._efCopyDone then
        row.hint:SetText(L["COPIED"])
        row.hint:SetTextColor(Utils.RGB(ns.COPIED_COLOR, 1))
        row.hint:SetAlpha(1)
    else
        -- The label reads like a shortcut column, so it names the chord
        -- that does this from the RESULT ROW when there is one (Send's
        -- clipboard: Ctrl+C; EasyFind link: Ctrl+Shift+C). A copy row with
        -- no row-level chord (Wowhead) shows its Ctrl+C only while
        -- engaged: a prompt for this menu row, not a claim about the
        -- result row, which copies something else on Ctrl+C.
        row.hint:SetText(row._copyKey or "Ctrl+C")
        row.hint:SetTextColor(Utils.RGB(lit and row._efLabelColor or ns.TEXT_DIM, 1))
        row.hint:SetAlpha((row._copyKey or lit) and 1 or 0)
    end
end

-- Any engaged menu row that carries a tooltip explains itself after the
-- standard hover delay: the row's own text as the title, def.tooltip as
-- the body, and def.tooltipNote as a dim afterthought. Copy rows and
-- flyout rows alike (the EasyFind link row is a flyout); a flyout row
-- anchors left so the cascade opening to its right is never covered.
local MenuTip = { row = nil, token = 0 }
-- Its right side is the submenu's: left, else above, else below.
MenuTip.SUBMENU_SIDES = { "ANCHOR_LEFT", "ANCHOR_TOP", "ANCHOR_BOTTOM" }

function MenuTip.Sync(row)
    if row == MenuTip.row then return end
    local prev = MenuTip.row
    MenuTip.row = row
    MenuTip.token = MenuTip.token + 1
    if prev then ns.HideHintTooltip(prev) end
    if not row or not row._tooltip then return end
    local token = MenuTip.token
    Utils.SafeAfter(ns.TOOLTIP_HOVER_DELAY, function()
        if MenuTip.token ~= token or MenuTip.row ~= row or not row:IsShown() then return end
        -- A row with a submenu keeps its right side for the submenu.
        ns.ShowHintTooltip(row, row._submenuRows and MenuTip.SUBMENU_SIDES or "ANCHOR_RIGHT",
            row.label:GetText(), row._tooltip, row._tooltipNote)
    end)
end

function MenuTip.Release(menu)
    if MenuTip.row and MenuTip.row:GetParent() == menu then MenuTip.Sync(nil) end
end

function MenuCopy.ShowTip(row)
    MenuTip.Sync(row)
end

function MenuCopy.HideTip(row)
    if row and MenuTip.row == row then MenuTip.Sync(nil) end
end

function MenuCopy.Disarm(restoreFocus)
    if not MenuCopy.armedRow then return end
    Utils.DisarmClipboardBox(restoreFocus, MenuCopy.client)
end

function MenuCopy.Arm(row)
    if not (row and row._copyText) then return false end
    MenuCopy.armedRow = row
    local icon = row.icon and row.icon.IsShown and row.icon:IsShown() and row.icon:GetTexture() or nil
    Utils.ArmClipboardBox(row._copyText, row._copyLink, MenuCopy.client, icon)
    return true
end

function MenuCopy.OnModifier(_, _, key, state)
    if key ~= "LCTRL" and key ~= "RCTRL" then return end
    if state == 1 then
        MenuCopy.Arm(MenuCopy.row)
    else
        MenuCopy.Disarm(true)
        -- The watcher outlives a Ctrl-held leave only for this release.
        if not MenuCopy.row then
            MenuCopy.watcher:UnregisterEvent("MODIFIER_STATE_CHANGED")
        end
    end
end

-- Called every frame by the root's OnUpdate with the engaged copy row (or
-- nil) and on hide by the menu that owned it. The arm follows engagement:
-- Ctrl held over a newly engaged row re-arms for it, leaving without Ctrl
-- releases. Leaving WITH Ctrl held keeps the arm, exactly like result
-- rows: the payload is already in the box and focus returns on Ctrl-up.
function MenuCopy.Sync(row, menu)
    if row == MenuCopy.row then return end
    local prev = MenuCopy.row
    MenuCopy.row, MenuCopy.menu = row, menu
    if prev then
        MenuCopy.PaintHint(prev, false)
        MenuCopy.HideTip(prev)
    end
    if not row then
        if not IsControlKeyDown() then
            MenuCopy.Disarm(true)
            MenuCopy.watcher:UnregisterEvent("MODIFIER_STATE_CHANGED")
        end
        return
    end
    MenuCopy.PaintHint(row, true)
    MenuCopy.ShowTip(row)
    if not MenuCopy.watcher then
        MenuCopy.watcher = CreateFrame("Frame")
        MenuCopy.watcher:SetScript("OnEvent", MenuCopy.OnModifier)
    end
    MenuCopy.watcher:RegisterEvent("MODIFIER_STATE_CHANGED")
    if IsControlKeyDown() then
        MenuCopy.Arm(row)
    elseif MenuCopy.armedRow and MenuCopy.armedRow ~= row then
        MenuCopy.Disarm(true)
    end
end

function MenuCopy.Release(menu)
    if MenuCopy.armedRow and MenuCopy.armedRow:GetParent() == menu then
        MenuCopy.Disarm(true)
    end
    if MenuCopy.menu == menu then MenuCopy.Sync(nil) end
end

MenuCopy.client = {
    OnCopied = function()
        local row = MenuCopy.armedRow
        if not row then return end
        row._efCopyDone = true
        MenuCopy.PaintHint(row, true)
        -- The native copy completes on this same key event; the box lets
        -- go one frame later so the chord is never cut short.
        Utils.SafeAfter(0, function() MenuCopy.Disarm(true) end)
        local menu = row:GetParent()
        Utils.SafeAfter(0.5, function()
            if row._efCopyDone and menu:IsShown() then
                while menu._parentMenu do menu = menu._parentMenu end
                menu:Hide()
            end
        end)
    end,
    HoldsFocus = function() return MenuCopy.armedRow ~= nil and IsControlKeyDown() end,
    OnDisarm = function() MenuCopy.armedRow = nil end,
    -- The focused box swallows MODIFIER_STATE_CHANGED; the release comes
    -- through the box's own key-up and takes the same path.
    OnCtrlUp = function() MenuCopy.OnModifier(nil, nil, "LCTRL", 0) end,
    -- OnKey is attached below CursorMenuOnKeyDown.
}

-- Listed: a row the menu's search keeps, shown or scrolled out of view.
local function CursorMenuIsSelectableRow(row)
    return row and (row:IsShown() or row._efListed) and not row.isSeparator and not row.disabled
end

-- The locked highlight IS the keyboard-focus visual: the same themed pill
-- (or additive glow on Black) hover shows, uniform with result rows, grid
-- cells and the apps menu. No extra overlay: the old gold QuestTitle slab
-- painted ON TOP of the pill read as an off-theme double highlight.
-- Must go through SetMenuHighlightFocused where installed: wash themes run
-- the built-in highlight texture at alpha 0 (the pill is the visible
-- hover), so a raw LockHighlight engages an invisible texture and keyboard
-- focus shows NOTHING on every theme but Black -- the same trap the flyout
-- holds hit (see SetHoldVisual).
local function CursorMenuPaintKeyboardSelection(self)
    if not self.rows then return end
    local focusRow = self.rows[self.keyboardIndex or 0]
    for i = 1, #self.rows do
        local row = self.rows[i]
        if row and row ~= focusRow then
            if row.SetMenuHighlightFocused then
                row:SetMenuHighlightFocused(false)
            elseif row.UnlockHighlight then
                row:UnlockHighlight()
            end
        end
    end
    if focusRow then
        if focusRow.SetMenuHighlightFocused then
            focusRow:SetMenuHighlightFocused(true)
        elseif focusRow.LockHighlight then
            focusRow:LockHighlight()
        end
    end
end

local function CursorMenuSetKeyboardIndex(self, index)
    if not self.rows then return false end
    if not index then
        self.keyboardIndex = nil
        CursorMenuPaintKeyboardSelection(self)
        return false
    end
    if index < 1 then index = #self.rows end
    if index > #self.rows then index = 1 end
    local start = index
    repeat
        local row = self.rows[index]
        if CursorMenuIsSelectableRow(row) then
            self.keyboardIndex = index
            -- Scrolled out of view: the rows move until it shows.
            local o, listed = self._lastOpts, self._listed
            if not row:IsShown() and o and o.maxRows and listed then
                for k = 1, #listed do
                    if listed[k] == row then
                        o._scrollOffset = k <= (o._scrollOffset or 0) and k - 1 or k - o.maxRows
                        Utils.LayoutCursorMenuRows(self)
                        break
                    end
                end
            end
            CursorMenuPaintKeyboardSelection(self)
            return true
        end
        index = index + 1
        if index > #self.rows then index = 1 end
    until index == start
    self.keyboardIndex = nil
    CursorMenuPaintKeyboardSelection(self)
    return false
end

-- Mouse precedence: hovering a selectable row moves the keyboard
-- selection there, so exactly one row is ever highlighted -- the pill
-- under the cursor IS the selection, and arrows/Enter continue from it.
-- Menus with no keyboard selection (mouse-opened, un-arrowed) are
-- untouched; their hover pill is already the only highlight.
local function CursorMenuRoot(menu)
    while menu._parentMenu do menu = menu._parentMenu end
    return menu
end

local function CursorMenuHoverSyncsKeyboard(menu, row)
    -- While the keyboard was the last input device (_mouseYields), a parked
    -- cursor must not steal the selection -- OnEnter also fires when a menu
    -- SPAWNS under the resting mouse, which would knock a Tab-opened menu's
    -- focus off row 1. Real cursor movement clears the flag (OnUpdate).
    if CursorMenuRoot(menu)._mouseYields then return end
    if not menu.keyboardIndex then return end
    local idx = row._efMenuRowIndex
    if idx and idx ~= menu.keyboardIndex and CursorMenuIsSelectableRow(row) then
        CursorMenuSetKeyboardIndex(menu, idx)
    end
end

local function CursorMenuMoveKeyboardIndex(self, delta)
    if not self.rows then return false end
    CursorMenuRoot(self)._mouseYields = true
    local index = (self.keyboardIndex or (delta > 0 and 0 or #self.rows + 1)) + delta
    if index < 1 then index = #self.rows end
    if index > #self.rows then index = 1 end
    return CursorMenuSetKeyboardIndex(self, index)
end

local function CursorMenuActivateKeyboardIndex(self)
    local row = self.rows and self.rows[self.keyboardIndex or 0]
    if not CursorMenuIsSelectableRow(row) then return false end
    if row._submenuRows then
        CursorMenuRowEntered(self, row)
        if self._openSubmenu and self._openSubmenu.FocusKeyboard then
            self._openSubmenu:FocusKeyboard(1)
        end
        return true
    end
    -- Enter on a copy row arms the clipboard box and keeps the menu open
    -- for the chord; closing here would leave nothing to copy from.
    if row._copyText then return MenuCopy.Arm(row) end
    local onClick = row.onClick
    local root = self
    while root._parentMenu do root = root._parentMenu end
    if self._parentMenu then
        if onClick then onClick() end
        root:Hide()
    else
        root:Hide()
        if onClick then onClick() end
    end
    return true
end

local function CursorMenuFocusKeyboard(self, index)
    self.keyboardMode = true
    CursorMenuRoot(self)._mouseYields = true
    Utils.SafeCallMethod(self, "EnableKeyboard", true)
    Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
    if self.Raise then Utils.RaiseMenu(self) end
    CursorMenuSetKeyboardIndex(self, index or 1)
end

local function CursorMenuOnShow(self)
    ns.ApplyMenuOpacity(self)
    self._showedAt = GetTime()
    self._outsideSince = nil
    self._hasEntered = false
    Utils.SafeCallMethod(self, "EnableKeyboard", true)
    Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
    -- Only the root of a cascade watches for click-outside. If a submenu also
    -- registered GLOBAL_MOUSE_DOWN, the two menus raced to close on the same
    -- mouse-down and hid the clicked submenu row before its handler could run,
    -- so the action never fired. One owner, like the single-menu case.
    if not self._parentMenu then
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
        self:RegisterEvent("GLOBAL_MOUSE_UP")
        self:RegisterEvent("PLAYER_REGEN_DISABLED")
    end
    if self.keyboardMode then
        CursorMenuFocusKeyboard(self, self.keyboardIndex or 1)
    else
        CursorMenuSetKeyboardIndex(self, nil)
    end
end

local function CursorMenuOnHide(self)
    self._outsideSince = nil
    self._hasEntered = false
    self._mouseYields = nil
    self._lastCursorX, self._lastCursorY = nil, nil
    CursorMenuSetKeyboardIndex(self, nil)
    MenuCopy.Release(self)
    MenuTip.Release(self)
    Utils.SafeCallMethod(self, "EnableKeyboard", false)
    self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    self:UnregisterEvent("GLOBAL_MOUSE_UP")
    self:UnregisterEvent("PLAYER_REGEN_DISABLED")
    if self.rows then
        for i = 1, #self.rows do
            local row = self.rows[i]
            if row then row:Hide() end
        end
    end
    if self._openSubmenu then
        local child = self._openSubmenu
        self._openSubmenu = nil
        self._openSubmenuRow = nil
        child:Hide()
    end
    -- A flyout whose toggles changed things: the menu it hangs from, still
    -- open, lists them anew next frame.
    local parent = self._efEdited and self._parentMenu
    self._efEdited = nil
    if parent and parent._rowsProvider then
        Utils.SafeAfter(0, function()
            local o = parent._lastOpts
            if not (parent:IsShown() and o) or parent._openSubmenu then return end
            o._reuseMenu = parent
            Utils.ShowCursorMenu(parent._lastName, parent._rowsProvider(o._searchText), o)
        end)
    end
    if self._parentMenu then
        if self._parentMenu._openSubmenu == self then
            local ownerRow = self._parentMenu._openSubmenuRow
            if ownerRow and ownerRow.SetMenuHighlightFocused then
                ownerRow:SetMenuHighlightFocused(false)
            end
            self._parentMenu._openSubmenu = nil
            self._parentMenu._openSubmenuRow = nil
        end
        self._parentMenu = nil
    end
    local onHide = self.onHide
    self.onHide = nil
    if onHide then onHide(self) end
end

-- Row highlights are driven each frame from the root down its cascade: a
-- row is lit while it has the mouse or holds its lock (its flyout's way
-- back), which survives anything that stomps per-row script hooks.
local function CursorMenuDriveRowHighlights(menu, mouseYields)
    local rows = menu.rows
    if not rows then return nil end
    local copyRow, tipRow
    for i = 1, #rows do
        local row = rows[i]
        if row and row:IsShown() and row._efMenuRowHighlightInstalled and not row.isSeparator then
            -- The lock (_efWashFocused: set as the row's flyout opens or the
            -- cursor reaches it, let go when another row is entered) and the
            -- cursor; an open flyout alone lights nothing, or its row stays
            -- lit beside the hovered one while the flyout waits to close.
            -- While the keyboard holds the floor (mouseYields), a parked
            -- cursor's IsMouseOver is ignored.
            local engaged = row._efWashFocused or (not mouseYields and row:IsMouseOver())
            if engaged and row._copyText and not copyRow then copyRow = row end
            -- The tip follows the pointer (or the keyboard cursor), not the
            -- cascade link: a row keeps its open flyout attached while the
            -- mouse browses the children, and its tooltip must not.
            local hot = (not mouseYields and row:IsMouseOver())
                or (mouseYields and menu.keyboardIndex == i)
            if hot and row._tooltip and not tipRow then tipRow = row end
            -- A row with a click of its own shows its X only under the cursor.
            if row._efRemoveOnHover then row.removeX:SetShown(hot) end
            if row._efWashActive then
                Utils.UpdateRoundedRowWash(row, engaged)
            else
                -- Black theme keeps the ADD glow: hover shows it natively, the
                -- cascade-owner state needs an explicit lock.
                local holds = row._efWashFocused
                if holds and not row._efCascadeLocked then
                    if row.LockHighlight then row:LockHighlight() end
                elseif not holds and row._efCascadeLocked then
                    if row.UnlockHighlight then row:UnlockHighlight() end
                end
                row._efCascadeLocked = holds or nil
            end
        end
    end
    return copyRow, tipRow
end

local function CursorMenuOnUpdate(self)
    -- Submenus never drive anything; the root owns the whole cascade, so
    -- there is exactly one owner of the hover/close decisions.
    if self._parentMenu then return end
    local cx, cy = GetCursorPosition()
    if self._lastCursorX ~= nil and (cx ~= self._lastCursorX or cy ~= self._lastCursorY) then
        self._mouseYields = nil
    end
    self._lastCursorX, self._lastCursorY = cx, cy
    local node = self
    local copyRow, copyMenu, tipRow
    while node do
        if node:IsShown() then
            local engagedCopy, engagedTip = CursorMenuDriveRowHighlights(node, self._mouseYields)
            if engagedCopy and not copyRow then copyRow, copyMenu = engagedCopy, node end
            if engagedTip and not tipRow then tipRow = engagedTip end
        end
        node = node._openSubmenu
    end
    if copyRow then
        MenuCopy.Sync(copyRow, copyMenu)
    elseif MenuCopy.menu and CursorMenuRoot(MenuCopy.menu) == self then
        MenuCopy.Sync(nil)
    end
    if tipRow then
        MenuTip.Sync(tipRow)
    elseif MenuTip.row and CursorMenuRoot(MenuTip.row:GetParent()) == self then
        MenuTip.Sync(nil)
    end
    -- stayOpen menus close only on click-outside (handled in OnEvent), never on
    -- mouse-leave, matching the search bar's filter menu.
    if self.stayOpen then return end
    if CursorMenuChainHasMouse(self) then
        self._outsideSince = nil
        self._hasEntered = true
        return
    end
    if not self._hasEntered then return end
    local now = GetTime()
    if not self._outsideSince then
        self._outsideSince = now
        return
    end
    if now - self._outsideSince > (self.outsideDelay or 0.3) then
        self:Hide()
    end
end

local function CursorMenuOnEvent(self, event)
    if event == "PLAYER_REGEN_DISABLED" then
        -- Before lockdown: the cascade stays open, mouse-only for the fight,
        -- since propagation cannot change in one.
        local node = self
        while node do
            Utils.SafeCallMethod(node, "SetPropagateKeyboardInput", true)
            Utils.SafeCallMethod(node, "EnableKeyboard", false)
            node = node._openSubmenu
        end
        return
    end
    if event ~= "GLOBAL_MOUSE_DOWN" and event ~= "GLOBAL_MOUSE_UP" then return end
    if self._showedAt and (GetTime() - self._showedAt) < (self.clickGrace or 0.05) then return end
    -- Clicks on the owning toggle button are its OnClick's to handle:
    -- hiding here on mouse-down would make the mouse-up click instantly
    -- reopen the menu it just closed.
    if self.toggleOwner and Utils.IsFrameVisiblyMouseOver(self.toggleOwner) then return end
    -- A press answering a row's question (removeAsk) is not one outside.
    local dialog = _G.EasyFindThemedDialog
    if dialog and dialog:IsShown() and dialog:IsMouseOver() then return end
    if not CursorMenuChainHasMouse(self) then self:Hide() end
end

local function CursorMenuOnKeyDown(self, key)
    local navKey = key and key:upper() or key
    if navKey == "ESCAPE" then
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
        self:Hide()
    elseif navKey == "DOWN" or (IsAltKeyDown and IsAltKeyDown() and navKey == "J") then
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
        CursorMenuMoveKeyboardIndex(self, 1)
    elseif navKey == "UP" or (IsAltKeyDown and IsAltKeyDown() and navKey == "K") then
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
        CursorMenuMoveKeyboardIndex(self, -1)
    elseif navKey == "ENTER" then
        -- SPACE is never an activation key in EasyFind; it always
        -- propagates (jumping must work with a menu open). ENTER
        -- activates the keyboard-selected row and otherwise propagates
        -- (mouse-opened menus have no selection).
        if CursorMenuIsSelectableRow(self.rows and self.rows[self.keyboardIndex or 0]) then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            CursorMenuActivateKeyboardIndex(self)
        else
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
        end
    elseif navKey == "TAB" then
        -- Tab descends into the focused row's submenu (Send link etc.);
        -- on rows without one it steps the selection like DOWN, so the
        -- whole menu is walkable from the keyboard. Shift+Tab mirrors the
        -- Tab that opened the menu: back out one level -- a submenu
        -- returns to its parent, the root closes and its opener (result
        -- row or grid cell) takes the keyboard back through onHide.
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
        if IsShiftKeyDown and IsShiftKeyDown() then
            self:Hide()
        else
            local row = self.rows and self.rows[self.keyboardIndex or 0]
            if CursorMenuIsSelectableRow(row) and row._submenuRows then
                CursorMenuActivateKeyboardIndex(self)
            else
                CursorMenuMoveKeyboardIndex(self, 1)
            end
        end
    elseif navKey == "RIGHT" then
        -- RIGHT descends like Tab but only on submenu rows; anywhere else
        -- it propagates so movement keys keep working with a menu open.
        local row = self.rows and self.rows[self.keyboardIndex or 0]
        if CursorMenuIsSelectableRow(row) and row._submenuRows then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            CursorMenuActivateKeyboardIndex(self)
        else
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
        end
    elseif navKey == "LEFT" then
        -- LEFT backs out of a submenu to its parent. On a keyboard-opened
        -- root it closes back to the opener, mirroring RIGHT/Tab opening
        -- it (the grid cell or row regains the keyboard through onHide).
        -- A mouse-opened root lets the key through: no nav context is
        -- waiting behind it, so LEFT stays a movement key.
        if self._parentMenu or self.keyboardMode then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
            self:Hide()
        else
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
        end
    else
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", true)
    end
end

-- While the clipboard box holds focus for an armed copy row, the menu's
-- own keyboard is behind it; the box hands navigation keys back here.
function MenuCopy.client.OnKey(key)
    local row = MenuCopy.armedRow
    local menu = row and row:GetParent()
    if menu and menu:IsShown() then CursorMenuOnKeyDown(menu, key) end
end

local function CreateCursorMenu(globalName)
    cursorMenuCounter = cursorMenuCounter + 1
    local frameName = globalName .. "_" .. cursorMenuCounter
    local menu = CreateFrame("Frame", frameName, UIParent, "BackdropTemplate")
    -- Made hidden: a frame starts shown, so its first Show ran no OnShow and
    -- the first menu of each kind never heard a click outside it.
    menu:Hide()
    menu:EnableMouse(true)
    Utils.ClampMenu(menu)
    menu.rows = {}
    ns.StyleMenuPanel(menu)

    menu.SetKeyboardIndex = CursorMenuSetKeyboardIndex
    menu.MoveKeyboardIndex = CursorMenuMoveKeyboardIndex
    menu.ActivateKeyboardIndex = CursorMenuActivateKeyboardIndex
    menu.FocusKeyboard = CursorMenuFocusKeyboard
    menu.RefreshMenuRowHighlights = function(self)
        Utils.RefreshMenuRowHighlights(self, self.rows)
    end
    menu:SetScript("OnShow", CursorMenuOnShow)
    menu:SetScript("OnHide", CursorMenuOnHide)
    Utils.SafeOnUpdate(menu, CursorMenuOnUpdate)
    menu:SetScript("OnEvent", CursorMenuOnEvent)
    menu:SetScript("OnKeyDown", CursorMenuOnKeyDown)
    -- A long menu (opts.maxRows) scrolls its rows under the wheel.
    menu:SetScript("OnMouseWheel", function(self, delta)
        local o = self._lastOpts
        if not (o and o.maxRows) then return end
        o._scrollOffset = (o._scrollOffset or 0) - delta
        Utils.LayoutCursorMenuRows(self)
    end)

    cursorMenuPool[globalName] = cursorMenuPool[globalName] or {}
    local pool = cursorMenuPool[globalName]
    pool[#pool + 1] = menu
    if not _G[globalName] then _G[globalName] = menu end
    return menu
end

-- Cursor-menu rows sit this far in from the menu on each side. The
-- fit-to-content width measures labels in ROW space, so it has to add this
-- back to reach menu space -- they must stay in step.
local MENU_ROW_INSET = 4

-- The rows a menu's search keeps, maxRows of them at a time from its
-- scroll offset (opts.search, opts.maxRows), the rest hidden; the menu
-- takes the height of what shows, a thumb marking the place in a long list.
function Utils.LayoutCursorMenuRows(menu)
    local opts = menu._lastOpts or {}
    local typed = opts._searchText or ""
    local query = slower(typed)
    local listed = menu._listed or {}
    wipe(listed)
    menu._listed = listed
    -- A searchAdd row offers what is typed, unless a row already is it.
    local exact = false
    for i = 1, menu._shownRows or 0 do
        local row = menu.rows[i]
        if not row._efSearchAdd and slower(row.label:GetText() or "") == query then exact = true end
    end
    for i = 1, menu._shownRows or 0 do
        local row = menu.rows[i]
        local keep
        if row._efSearchAdd then
            keep = strtrim(typed) ~= "" and not exact
            if keep then row.label:SetText(sformat(row._efSearchAdd, strtrim(typed))) end
        else
            -- A live search's rows are already what the words find.
            keep = query == "" or opts.liveSearch
                or (not row.isSeparator and sfind(slower(row.label:GetText() or ""), query, 1, true))
        end
        row._efListed = keep and true or nil
        if keep then listed[#listed + 1] = row end
        row:Hide()
    end
    local cap = opts.maxRows
    local first, last = 1, #listed
    if cap and #listed > cap then
        opts._scrollOffset = mmax(0, mmin(opts._scrollOffset or 0, #listed - cap))
        first, last = opts._scrollOffset + 1, opts._scrollOffset + cap
    else
        opts._scrollOffset = 0
    end
    local search = menu.searchShell
    local top = (search and search:IsShown()) and 32 or 4
    local prev, h = nil, 0
    for k = first, last do
        local row = listed[k]
        row:ClearAllPoints()
        if prev then
            row:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, 0)
            row:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, 0)
        else
            row:SetPoint("TOPLEFT", menu, "TOPLEFT", MENU_ROW_INSET, -top)
            row:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -MENU_ROW_INSET, -top)
        end
        row:Show()
        prev = row
        h = h + (row:GetHeight() or 22)
    end
    local thumb = menu.scrollThumb
    if cap and #listed > cap then
        if not thumb then
            thumb = menu:CreateTexture(nil, "OVERLAY")
            thumb:SetWidth(3)
            thumb:SetColorTexture(1, 1, 1, 0.25)
            menu.scrollThumb = thumb
        end
        local thumbH = mmax(12, h * cap / #listed)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -2, -(top + (h - thumbH) * opts._scrollOffset / (#listed - cap)))
        thumb:SetHeight(thumbH)
        thumb:Show()
    elseif thumb then
        thumb:Hide()
    end
    menu:SetHeight(top + h + 4)
end

-- A search box over a menu's rows: typing keeps the rows that hold it.
function Utils.CursorMenuSearch(menu, placeholder)
    local shell = menu.searchShell
    if not shell then
        shell = CreateFrame("Frame", nil, menu)
        shell:SetHeight(22)
        shell:SetPoint("TOPLEFT", menu, "TOPLEFT", 8, -6)
        shell:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -8, -6)
        ns.CreateRingedWell(shell, 6)
        local edit = CreateFrame("EditBox", nil, shell)
        edit:SetPoint("LEFT", shell, "LEFT", 8, 0)
        edit:SetPoint("RIGHT", shell, "RIGHT", -8, 0)
        edit:SetHeight(20)
        edit:SetFrameLevel(shell.ringInset:GetFrameLevel() + 2)
        edit:SetAutoFocus(false)
        edit:SetFontObject("GameFontHighlightSmall")
        edit:SetTextColor(0.96, 0.96, 0.96, 1)
        local hint = edit:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("LEFT", edit, "LEFT", 0, 0)
        hint:SetPoint("RIGHT", edit, "RIGHT", 0, 0)
        hint:SetJustifyH("LEFT")
        hint:SetWordWrap(false)
        edit.hint = hint
        edit:SetScript("OnTextChanged", function(self, userInput)
            local text = self:GetText() or ""
            self.hint:SetShown(text == "")
            -- Typing only: a menu opening clears a pooled box's old words,
            -- and taking that as typing focused the box.
            if not userInput then return end
            local o = menu._lastOpts
            if o and o._searchText ~= text then
                o._searchText, o._scrollOffset = text, 0
                if o.liveSearch and menu._rowsProvider then
                    -- Its rows come from the words, rebuilt in this same
                    -- frame so the box keeps its focus and composition.
                    CursorMenuCloseSubmenu(menu)
                    o._reuseMenu, o._searchTyping = menu, true
                    Utils.ShowCursorMenu(menu._lastName, menu._rowsProvider(text), o)
                else
                    Utils.LayoutCursorMenuRows(menu)
                end
            end
        end)
        -- Enter takes the add row when it shows; in a live search, the
        -- first thing found.
        edit:SetScript("OnEnterPressed", function(self)
            local live = menu._lastOpts and menu._lastOpts.liveSearch
            for _, row in ipairs(menu._listed or {}) do
                if row._efSearchAdd or (live and row.onClick and not row.disabled) then
                    local press = row:GetScript("OnMouseDown")
                    if press then press(row, "LeftButton") end
                    return
                end
            end
            self:ClearFocus()
        end)
        edit:SetScript("OnEscapePressed", function(self)
            self:ClearFocus()
            CursorMenuRoot(menu):Hide()
        end)
        shell.edit = edit
        menu.searchShell = shell
    end
    local palette = ns.ACTIVE_UI_PALETTE
    local line = palette and palette.separator or { 0.42, 0.42, 0.42 }
    local ring = palette and palette.borderColor or { line[1], line[2], line[3], 0.7 }
    ns.PaintRingedWell(shell, ring, ns.EDITBOX_INSET_FILL or { 0.02, 0.02, 0.03 })
    shell.edit.hint:SetText(placeholder)
    return shell
end

-- No menu runs off the screen: past this many rows it scrolls.
Utils.MENU_MAX_ROWS = 16

function Utils.ShowCursorMenu(globalName, rows, opts)
    opts = opts or {}
    if not opts.maxRows and type(rows) == "table" and #rows > Utils.MENU_MAX_ROWS then
        opts.maxRows = Utils.MENU_MAX_ROWS
    end

    -- A keepOpen reshow replaces the pooled child frame: HideOtherMenus fires
    -- the old child's OnHide, which wipes the parent's _openSubmenuRow -- and
    -- with it the parent row's stays-lit-while-child-open state. Capture the
    -- row link BEFORE the teardown so it can be restored onto the new frame.
    local priorSubmenuRow = opts.parentMenu and opts.parentMenu._openSubmenuRow

    -- Every menu hung from a button toggles from it, no caller has to ask:
    -- the anchor is the toggle owner unless one is named, and a click on it
    -- while its menu is open closes the menu. A click only: a menu reshown
    -- as its anchor's text changes (no clicked button) stays.
    local owner = opts.toggleOwner or opts.anchorFrame
    if owner and not opts.parentMenu and GetMouseButtonClicked and GetMouseButtonClicked()
       and Utils.IsFrameVisiblyMouseOver(owner) then
        local pool = cursorMenuPool[globalName]
        for i = 1, #(pool or {}) do
            if pool[i]:IsShown() and pool[i].toggleOwner == owner then
                pool[i]:Hide()
                return nil
            end
        end
    end

    -- A live search fills its own frame again.
    local reuse = opts._reuseMenu
    opts._reuseMenu = nil
    HideOtherMenus(globalName, reuse)

    local menu = reuse or FindFreeMenu(globalName) or CreateCursorMenu(globalName)

    local menuScale = opts.scale or 1
    menu:SetScale(menuScale)
    menu:SetFrameStrata(opts.strata or "TOOLTIP")
    -- NEVER the 10000 ceiling: children spawn at parent+1 and the engine CLAMPS
    -- levels to 10000, so a ceiling menu's rows collapse onto the menu's own
    -- level -- and at equal level the parent wins hover focus, deadening every
    -- row (hover-driven submenu rows worst of all). Keep headroom for rows (+1)
    -- and cascade flyouts (+20).
    local menuLevel = math.min(opts.level or 9000, 9900)
    menu:SetFrameLevel(menuLevel)
    -- Grazing the menu edge shouldn't dismiss it; shares the tooltip
    -- hover delay so all hover timing feels like one system.
    menu.outsideDelay = opts.outsideDelay or ns.TOOLTIP_HOVER_DELAY
    menu.clickGrace = opts.clickGrace or 0.05
    menu.stayOpen = opts.stayOpen and true or false
    menu.keyboardMode = opts.keyboardMode and true or false
    menu.keyboardIndex = nil
    menu.onHide = opts.onHide
    menu.toggleOwner = owner
    menu._parentMenu = opts.parentMenu
    -- Menus wear their CONTEXT's font: search menus track the results leaf
    -- font (default), other hosts (notes) pass their chrome font object so
    -- menu text matches the text around it instead of the search setting.
    menu._labelFontObject = opts.labelFontObject
    -- Filter-style menus put their check marks on the LEFT like the main
    -- filter dropdown; context menus keep glyphs on the right.
    menu._iconSide = opts.iconSide or "right"
    menu._rowsProvider = opts.rowsProvider
    menu._lastName, menu._lastOpts = globalName, opts
    -- A reshow (keepOpen refresh) can hand this cascade slot to a different
    -- pooled frame; the parent's links must follow it or the chain-hover test
    -- loses the child (auto-close) and the parent row loses its engaged state.
    if opts.parentMenu then
        opts.parentMenu._openSubmenu = menu
        if priorSubmenuRow and not opts.parentMenu._openSubmenuRow then
            opts.parentMenu._openSubmenuRow = priorSubmenuRow
            -- The old child's OnHide unlocked this row; re-lock it -- its
            -- child is still open, just on a replacement frame.
            if priorSubmenuRow.SetMenuHighlightFocused then
                priorSubmenuRow:SetMenuHighlightFocused(true)
            end
        end
    end

    local rowH = opts.rowHeight or 22
    local width = opts.width or 96
    local shown = 0
    -- The left check column only when a row has a mark for it. A row's own
    -- glyph (inlineIcon) sits before its text alone; iconSide "right" keeps
    -- a toggle's check on the right.
    local leftIcons = false
    if menu._iconSide == "left" then
        for i = 1, #rows do
            local d = rows[i]
            if d and d.icon and not d.inlineIcon and d.iconSide ~= "right" then leftIcons = true break end
        end
    end
    for i = 1, #rows do
        local def = rows[i]
        if def then
            shown = shown + 1
            local row = menu.rows[shown]
            if not row then
                row = CreateFrame("Button", nil, menu)
                row:EnableMouse(true)
                row:SetHeight(rowH)
                Utils.InstallMenuRowHighlight(row)
                -- Hovering a row opens its submenu beside it (or closes a
                -- sibling's); the current row's spec lives in row._submenuRows.
                row:HookScript("OnEnter", function(self)
                    CursorMenuHoverSyncsKeyboard(menu, self)
                    CursorMenuRowEntered(menu, self)
                end)
                row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                -- Populate owns this color (gold family per theme).
                row.label._efOwnColor = true
                row.label:SetPoint("LEFT", row, "LEFT", 8, 0)
                row.icon = row:CreateTexture(nil, "OVERLAY")
                row.icon:SetSize(14, 14)
                row.icon:SetPoint("RIGHT", row, "RIGHT", -8, 0)
                row.sep = row:CreateTexture(nil, "ARTWORK")
                local sepTheme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
                local sepColor = sepTheme and sepTheme.separatorColor
                if sepColor then
                    row.sep:SetColorTexture(sepColor[1], sepColor[2], sepColor[3], sepColor[4] or 0.35)
                else
                    row.sep:SetColorTexture(1, 1, 1, 0.18)
                end
                row.sep:SetHeight(1)
                row.sep:SetPoint("LEFT", row, "LEFT", 6, 0)
                row.sep:SetPoint("RIGHT", row, "RIGHT", -6, 0)
                row.sep:Hide()
                menu.rows[shown] = row
            end
            row._efMenuRowIndex = shown
            local isSep = def.isSeparator
            local sepH = 7
            -- Pooled rows shed any stale cascade lock on repopulate; a fresh
            -- open has no child yet (RowEntered re-locks when one opens).
            if row._efWashFocused and row.SetMenuHighlightFocused then
                row:SetMenuHighlightFocused(false)
            end
            -- Rows sit TWO above the menu body (re-asserted every open; pooled
            -- rows keep stale levels otherwise): the hover pill lives at row-1
            -- and needs its own level BETWEEN menu fill and row content --
            -- at the menu's own level it z-fights the fill and vanishes
            -- (HARDFOUGHT_BATTLES: equal level = the parent wins).
            row:SetFrameLevel(menuLevel + 2)
            row:SetHeight(isSep and sepH or rowH)
            if isSep then
                if row.ClearMenuHighlightState then row:ClearMenuHighlightState() end
                row.isSeparator = true
                row.disabled = nil
                row.onClick = nil
                row._submenuRows = nil
                row.label:SetText("")
                row.icon:Hide()
                if row.iconOverlay then row.iconOverlay:Hide() end
                if row.chevron then row.chevron:Hide() end
                row.sep:Show()
                row:EnableMouse(false)
                local hl = row:GetHighlightTexture()
                if hl then hl:SetAlpha(0) end
                row:SetScript("OnMouseDown", nil)
                row:SetScript("OnClick", nil)
            else
                row.isSeparator = nil
                row.disabled = def.disabled and true or nil
                -- Menus wear the same scaled leaf font as result rows
                -- (honors the Font setting; plain GameFontNormal read as
                -- a different typeface next to the results) -- unless the
                -- host passed its own font object for context consistency.
                if menu._labelFontObject then
                    -- Apply the host font ABSOLUTELY (object + raw path/size):
                    -- parent and submenu share one object, so their text can
                    -- never differ in size from each other or the host UI.
                    row.label:SetFontObject(menu._labelFontObject)
                    local ff, fs, ffl = menu._labelFontObject:GetFont()
                    if ff then row.label:SetFont(ff, fs, ffl or "") end
                    row.label._efSFBase = nil
                elseif ns.Results and ns.Results.SetScaledFont then
                    -- Menus wear the same font as result-row TITLES (pathFont),
                    -- not the smaller leaf style -- menu text must never read
                    -- smaller than the rows it acts on.
                    local pathTheme = ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
                    ns.Results:SetScaledFont(row.label,
                        (pathTheme and pathTheme.pathFont) or ns.LEAF_FONT)
                end
                row.label:SetText(def.text or "")
                -- Menu rows repopulate on every open, so the gold label
                -- can resolve per theme here (hue-dark accent on light
                -- fills); submenus share this same builder.
                local menuTheme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
                -- Menu labels match the theme's body/leaf text (the same family as
                -- the row icons), not the old gold; light themes take the darker
                -- path-hover so text stays legible on the light fill.
                local labelColor
                if row.disabled then
                    labelColor = ns.TEXT_DIM
                elseif menuTheme and menuTheme.lightTheme then
                    labelColor = menuTheme.pathColorHover or menuTheme.leafColor
                else
                    labelColor = (menuTheme and menuTheme.leafColor) or ns.GOLD_COLOR
                end
                row.label:SetTextColor(Utils.RGB(labelColor, 1))
                -- Own the shadow here too: these _efOwnColor labels are
                -- skipped by RetintMenuText, and pooled rows skip
                -- SetScaledFont's shadow re-apply when font/size are
                -- unchanged, so a row first built on a dark theme keeps its
                -- shadow after a switch to light unless it's set per open.
                row.label:SetShadowColor(0, 0, 0, 0)
                -- Anchoring follows the menu's icon side; pooled rows serve
                -- menus of either style, so re-anchor per open. The label is
                -- ALWAYS right-constrained: an unconstrained label renders
                -- over the icon slot when the menu is narrow.
                -- Submenu rows wear the shared flyout chevron on the right,
                -- exactly like the filter dropdown's cascade rows -- one
                -- arrow style across every menu surface.
                if def.submenu and not row.chevron then
                    row.chevron = row:CreateTexture(nil, "OVERLAY")
                    row.chevron:SetSize(12, 12)
                    row.chevron:SetPoint("RIGHT", row, "RIGHT", -8, 0)
                end
                if row.chevron then
                    if def.submenu then
                        Utils.SetChevronTexture(row.chevron)
                        row.chevron:Show()
                    else
                        row.chevron:Hide()
                    end
                end
                row.label:ClearAllPoints()
                row.icon:ClearAllPoints()
                local iconRight = def.icon and not def.inlineIcon and (def.iconSide == "right" or not leftIcons)
                row._efIconRight = iconRight
                row._efLabelLeft = (leftIcons or (def.icon and def.inlineIcon)) and 28 or 8
                row.label:SetPoint("LEFT", row, "LEFT", row._efLabelLeft, 0)
                -- A remove row keeps an X at its right edge: a click on it
                -- drops what the row names (after a yes, with removeAsk) and
                -- lists the menu anew.
                if def.remove and not row.removeX then
                    row.removeX = ns.CreateCloseX(row, 10)
                    row.removeX:SetPoint("RIGHT", row, "RIGHT", -8, 0)
                    local function Relist()
                        if not menu:IsShown() then return end
                        local o = menu._lastOpts
                        local fresh = menu._rowsProvider and menu._rowsProvider(o and o._searchText)
                        if fresh and #fresh > 0 then
                            menu._efEdited = true
                            if o and o.liveSearch then o._reuseMenu = menu end
                            Utils.ShowCursorMenu(menu._lastName, fresh, o)
                        else
                            menu:Hide()
                        end
                    end
                    row.removeX:SetScript("OnClick", function()
                        local remove, ask = row._efRemove, row._efRemoveAsk
                        if not ask then
                            if remove then remove() end
                            return Relist()
                        end
                        ns.ShowThemedDialog({ text = ask, acceptText = _G.REMOVE or "Remove", cancelText = _G.CANCEL or "Cancel",
                            onAccept = function()
                                if remove then remove() end
                                Relist()
                            end })
                    end)
                end
                row._efRemove, row._efRemoveAsk = def.remove, def.removeAsk
                row._efRemoveOnHover = def.remove ~= nil and def.onClick ~= nil or nil
                if row.removeX then
                    row.removeX:SetShown(def.remove ~= nil and not row._efRemoveOnHover)
                    -- Above its row however the pooled row was leveled, or the
                    -- row takes the press and closes the menu.
                    row.removeX:SetFrameLevel(row:GetFrameLevel() + 2)
                end
                -- The chevron or the X owns the right edge; a right-side
                -- icon steps inward beside it.
                local trailing = def.submenu or def.remove
                if iconRight then
                    row.icon:SetPoint("RIGHT", row, "RIGHT", trailing and -26 or -8, 0)
                    row.label:SetPoint("RIGHT", row, "RIGHT", trailing and -44 or -26, 0)
                else
                    row.icon:SetPoint("LEFT", row, "LEFT", 8, 0)
                    row.label:SetPoint("RIGHT", row, "RIGHT", trailing and -22 or -8, 0)
                end
                -- Copy rows carry their gesture in the icon lane: a dim
                -- "Ctrl+C" the drive lights while the row is engaged and
                -- that turns into "Copied" when the chord lands. The label
                -- hangs off the hint so a wider confirmation never overlaps.
                row._copyText, row._copyLink = def.copy, def.copyLink
                row._copyKey = def.copyKey
                row._tooltip, row._tooltipNote = def.tooltip, def.tooltipNote
                row._efLabelColor = labelColor
                row._efCopyDone = nil
                -- A result action's chord sits in the same lane, always shown.
                row._efKeyHint = not def.copy and def.keyHint or nil
                if def.copy or row._efKeyHint then
                    if not row.hint then
                        row.hint = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                        row.hint._efOwnColor = true
                        row.hint:SetShadowColor(0, 0, 0, 0)
                    end
                    local ff, fs, ffl = row.label:GetFont()
                    if ff then row.hint:SetFont(ff, fs, ffl or "") end
                    row.hint:ClearAllPoints()
                    if def.submenu and row.chevron then
                        -- A flyout row's shortcut sits just left of its chevron.
                        row.hint:SetPoint("RIGHT", row.chevron, "LEFT", -6, 0)
                    else
                        row.hint:SetPoint("RIGHT", row, "RIGHT", iconRight and -26 or -8, 0)
                    end
                    row.hint:Show()
                    if row._efKeyHint then
                        row.hint:SetText(row._efKeyHint)
                        row.hint:SetTextColor(Utils.RGB(ns.TEXT_DIM, 1))
                        row.hint:SetAlpha(1)
                    else
                        MenuCopy.PaintHint(row, false)
                    end
                    row.label:SetPoint("RIGHT", row.hint, "LEFT", -8, 0)
                elseif row.hint then
                    row.hint:Hide()
                end
                row.label:SetJustifyH("LEFT")
                row.label:SetWordWrap(false)
                if def.icon then
                    -- SetIconTexture handles plain paths, atlas: strings,
                    -- and {file, coords} tables (cropped square icons).
                    Utils.SetIconTexture(row.icon, def.icon)
                    row.icon:SetRotation(def.iconRotation or 0)
                    -- Monochrome chrome glyphs (Guide eye, Wowhead link)
                    -- flip polarity with the theme; content icons never
                    -- tint. Rows are pooled, so the reset matters.
                    local glyph = def.chromeIcon and menuTheme and menuTheme.lightTheme
                        and menuTheme.chromeGlyph
                    if glyph then
                        row.icon:SetVertexColor(glyph[1], glyph[2], glyph[3], 1)
                    else
                        row.icon:SetVertexColor(1, 1, 1, 1)
                    end
                    row.icon:SetDesaturated(row.disabled and true or false)
                    row.icon:SetAlpha(row.disabled and 0.5 or 1)
                    row.icon:Show()
                else
                    row.icon:Hide()
                end
                -- The pin rows show the same composite glyph the pinned
                -- result rows wear (Utils.CreatePinGlyph), in the icon slot.
                if def.pinGlyph then
                    if not row.pinGlyph then
                        row.pinGlyph = Utils.CreatePinGlyph(row, 12)
                        row.pinGlyph:SetPoint("RIGHT", row, "RIGHT", -8, 0)
                    end
                    row.pinGlyph:SetAlpha(row.disabled and 0.5 or 1)
                    row.pinGlyph:Show()
                elseif row.pinGlyph then
                    row.pinGlyph:Hide()
                end
                if def.iconOverlay then
                    if not row.iconOverlay then
                        -- Corner badge, not a full cover: the base glyph
                        -- must stay identifiable underneath.
                        row.iconOverlay = row:CreateTexture(nil, "OVERLAY", nil, 3)
                        row.iconOverlay:SetSize(9, 9)
                    end
                    row.iconOverlay:ClearAllPoints()
                    row.iconOverlay:SetPoint("BOTTOMRIGHT",
                        def.pinGlyph and row.pinGlyph or row.icon, "BOTTOMRIGHT", 3, -3)
                    row.iconOverlay:SetTexture(def.iconOverlay)
                    row.iconOverlay:SetAlpha(row.disabled and 0.5 or 1)
                    row.iconOverlay:Show()
                elseif row.iconOverlay then
                    row.iconOverlay:Hide()
                end
                row.sep:Hide()
                row._submenuRows = def.submenu
                if row.disabled then
                    if row.ClearMenuHighlightState then row:ClearMenuHighlightState() end
                    row:EnableMouse(false)
                    local hl = row:GetHighlightTexture()
                    if hl then hl:SetAlpha(0) end
                    row.onClick = nil
                    row:SetScript("OnMouseDown", nil)
                elseif def.submenu and not def.onClick then
                    -- A submenu row opens its flyout (it also opens on hover);
                    -- it never closes the menu or fires a leaf action. One
                    -- with an onClick opens its flyout on hover only and
                    -- takes the click below: a toggle with keepOpen, else
                    -- an action (a list's flyout whose click makes a new one).
                    row:EnableMouse(true)
                    local hl = row:GetHighlightTexture()
                    if hl then hl:SetAlpha(1) end
                    row.onClick = nil
                    row:SetScript("OnMouseDown", function(self, button)
                        if button ~= "LeftButton" then return end
                        CursorMenuRowEntered(menu, self)
                    end)
                elseif def.copy then
                    -- A click cannot copy (no clipboard API); it arms the
                    -- chord and keeps the menu open, hint already lit.
                    row:EnableMouse(true)
                    local hl = row:GetHighlightTexture()
                    if hl then hl:SetAlpha(1) end
                    row.onClick = nil
                    row:SetScript("OnMouseDown", function(self, button)
                        if button ~= "LeftButton" then return end
                        MenuCopy.Arm(self)
                    end)
                elseif def.remove and not def.onClick then
                    -- A row whose one action is its X: a press on the row does
                    -- nothing, so several can be removed in a row.
                    row:EnableMouse(true)
                    row.onClick = nil
                    row:SetScript("OnMouseDown", nil)
                else
                    row:EnableMouse(true)
                    local hl = row:GetHighlightTexture()
                    if hl then hl:SetAlpha(1) end
                    local onClick = def.onClick
                    local keepOpen = def.keepOpen
                    row.onClick = onClick
                    row:SetScript("OnMouseDown", function(_, button)
                        if button ~= "LeftButton" then return end
                        -- Toggle rows (keepOpen) NEVER close the menu -- the
                        -- user is mid-multi-select; instead the menu reshows
                        -- with fresh rows so its check marks track the state.
                        if keepOpen then
                            -- A row gets what the menu's search holds; the add
                            -- row's word, once added, is a row of its own.
                            local o = menu._lastOpts
                            if onClick then onClick(o and o._searchText) end
                            menu._efEdited = true
                            if row._efSearchAdd and o then o._searchText = "" end
                            local fresh = menu._rowsProvider and menu._rowsProvider(o and o._searchText)
                            local search = menu.searchShell
                            if search and search:IsShown() and search.edit:HasFocus() then
                                o._searchTyping = true
                            end
                            if fresh then
                                if o.liveSearch then o._reuseMenu = menu end
                                local shownMenu = Utils.ShowCursorMenu(menu._lastName, fresh, menu._lastOpts)
                                if shownMenu then shownMenu._efEdited = true end
                            end
                            return
                        end
                        local root = menu
                        while root._parentMenu do root = root._parentMenu end
                        -- In a submenu, fire the action BEFORE tearing down: the
                        -- root's hide-cascade hides this row's own menu, and
                        -- hiding the frame whose handler is mid-run swallowed the
                        -- click so the action never ran. Top-level menus keep the
                        -- long-standing hide-then-act order (no cascade hides the
                        -- running row there).
                        if menu._parentMenu then
                            if onClick then onClick() end
                            root:Hide()
                        else
                            root:Hide()
                            if onClick then onClick() end
                        end
                    end)
                end
                row:SetScript("OnClick", nil)
            end
            -- Placed and shown by LayoutCursorMenuRows, after the width.
            row._efSubmenuSearch, row._efSubmenuMaxRows = def.submenuSearch, def.submenuMaxRows
            row._efSubmenuLive = def.submenuLiveSearch
            row._efSearchAdd = def.searchAdd and def.text or nil
        end
    end
    menu._shownRows = shown
    for i = shown + 1, #menu.rows do
        local row = menu.rows[i]
        if row then
            row:Hide()
            row._efListed = nil
            row.isSeparator = nil
            row.disabled = nil
            row.onClick = nil
            row._submenuRows = nil
            row._copyText, row._copyLink = nil, nil
            row._copyKey = nil
            row._tooltip, row._tooltipNote = nil, nil
            row._efRemove = nil
            if row.removeX then row.removeX:Hide() end
            row:SetScript("OnClick", nil)
            row:SetScript("OnMouseDown", nil)
        end
    end

    -- Fit-to-content width. Labels are measured through a hidden, never-
    -- constrained FontString: a pooled row's own label is already right-
    -- anchored into the menu's PREVIOUS width, so on clients where
    -- GetUnboundedStringWidth is unavailable its width reads back clipped
    -- and a long row stays ellipsized forever.
    if not menu.measure then
        menu.measure = menu:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        menu.measure:Hide()
    end
    -- Room to type in, with a search box, and its whole placeholder: the
    -- box sits 8 in from each side and its text 8 more.
    local needed = width
    if opts.search then
        menu.measure:SetFontObject(GameFontDisableSmall)
        menu.measure:SetText(opts.search)
        needed = mmax(width, 180, math.ceil(menu.measure:GetStringWidth() or 0) + 34)
    end
    for i = 1, shown do
        local row = menu.rows[i]
        if row then
            if row.label and not row.isSeparator then
                local lblW
                if row.label.GetUnboundedStringWidth then
                    lblW = row.label:GetUnboundedStringWidth() or 0
                else
                    local ff, fs, ffl = row.label:GetFont()
                    if ff then menu.measure:SetFont(ff, fs, ffl or "") end
                    menu.measure:SetText(row.label:GetText() or "")
                    lblW = menu.measure:GetStringWidth() or 0
                end
                local leftPad = row._efLabelLeft or 8
                local rightPad = 8
                if row.chevron and row.chevron:IsShown() then
                    rightPad = row._efIconRight and 44 or 22
                elseif row.removeX and row.removeX:IsShown() then
                    rightPad = row._efIconRight and 44 or 26
                elseif row._efIconRight then
                    rightPad = 26
                end
                if row._copyText and row.hint then
                    -- Reserve the wider of the hint and its "Copied" swap,
                    -- so the label never ellipsizes when the chord lands.
                    local hintW = row.hint:GetStringWidth()
                    row.hint:SetText(L["COPIED"])
                    hintW = mmax(hintW, row.hint:GetStringWidth())
                    MenuCopy.PaintHint(row, false)
                    rightPad = rightPad + mfloor(hintW + 0.5) + 8
                    -- Beside a chevron the hint sits 6px left of it, 4px
                    -- more than the chevron pad alone accounts for.
                    if row.chevron and row.chevron:IsShown() then rightPad = rightPad + 4 end
                elseif row._efKeyHint and row.hint then
                    rightPad = rightPad + mfloor(row.hint:GetStringWidth() + 0.5) + 8
                    if row.chevron and row.chevron:IsShown() then rightPad = rightPad + 4 end
                end
                -- Rows are inset MENU_ROW_INSET on BOTH sides of the menu, so
                -- a width measured in row space is that much short in menu
                -- space. Without it the widest row -- the one that sets the
                -- width -- always ellipsized by exactly the inset.
                local rowW = leftPad + lblW + rightPad + MENU_ROW_INSET * 2
                if rowW > needed then needed = rowW end
            end
        end
    end
    -- A live search's width only grows while it is open: no jump per word.
    if opts.liveSearch then
        needed = mmax(needed, opts._liveW or 0)
        opts._liveW = needed
    end
    menu:SetWidth(needed)
    if opts.search then
        local search = Utils.CursorMenuSearch(menu, opts.search)
        search:Show()
        -- Set only when it differs, or the caret jumps to the end.
        local want = opts._searchText or ""
        if search.edit:GetText() ~= want then search.edit:SetText(want) end
        -- A toggle's reshow keeps the box typing on.
        if opts._searchTyping then search.edit:SetFocus() end
        opts._searchTyping = nil
    elseif menu.searchShell then
        menu.searchShell:Hide()
    end
    menu:EnableMouseWheel(opts.maxRows ~= nil)
    Utils.LayoutCursorMenuRows(menu)
    menu:ClearAllPoints()
    if opts.anchorBeside then
        -- Cascade flyout: sit beside the owning row, flipping/clamping on-screen,
        -- exactly like the filter sub-flyouts.
        Utils.OpenFlyoutBeside(menu, opts.anchorBeside, 4)
    elseif opts.anchorFrame then
        menu:SetPoint(opts.point or "TOPLEFT", opts.anchorFrame, opts.relativePoint or "TOPRIGHT",
            opts.offsetX or 4, opts.offsetY or 0)
    else
        local scale = UIParent:GetEffectiveScale() * menuScale
        local x, y = GetCursorPosition()
        menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT",
            x / scale + (opts.offsetX or 0), y / scale + (opts.offsetY or 0))
    end
    ns.FlatText(menu)
    menu:Show()
    -- Uniform per-row pills carry no geometry dependency, so this can run
    -- synchronously again (the old positional corner masks needed resolved
    -- rects and got a deferred pass; that whole system is gone).
    if menu.RefreshMenuRowHighlights then menu:RefreshMenuRowHighlights() end
    if menu.keyboardMode and menu.FocusKeyboard then
        menu:FocusKeyboard(1)
        local focusMenu = menu
        Utils.SafeAfter(0, function()
            if focusMenu and focusMenu:IsShown() and focusMenu.keyboardMode and focusMenu.FocusKeyboard then
                focusMenu:FocusKeyboard(1)
            end
        end)
    end
    return menu
end

-- Rows sort by label; a row may carry a sortKey instead to sit somewhere
-- specific (EasyFind link pairs with Send).
local function MenuRowLess(a, b)
    return slower(a.sortKey or a.text or "") < slower(b.sortKey or b.text or "")
end

function Utils.ShowPinMenu(globalName, isPinned, onPin, onGuide, onAddAlias, opts, extra)
    return Utils.ShowCursorMenu(globalName, Utils.PinMenuRows(isPinned, onPin, onGuide, onAddAlias, extra), opts)
end

-- A result's right-click rows. An action a key can do carries actionId
-- (Search/Results/RowActions.lua runs it by that id, and shows its key).
function Utils.PinMenuRows(isPinned, onPin, onGuide, onAddAlias, extra)
    local rows = {}
    local addRows, removeRows = {}, {}
    -- Two or more related rows fold into one flyout row; a lone one stays a
    -- plain row under its own full label.
    local function AddGroup(label, members)
        if #members == 0 then return end
        if #members == 1 then
            members[1].text = members[1].fullText or members[1].text
            rows[#rows + 1] = members[1]
            return
        end
        tsort(members, MenuRowLess)
        rows[#rows + 1] = { text = label, submenu = members }
    end
    if onAddAlias then
        addRows[#addRows + 1] = {
            actionId = "alias", text = L["OPT_COL_ALIAS"], fullText = L["CTX_ADD_ALIAS"], tooltip = L["CTX_ADD_ALIAS_TT"],
            onClick = onAddAlias,
        }
    end
    if extra and extra.onAddShortkey then
        addRows[#addRows + 1] = {
            actionId = "shortkey", text = extra.hasShortkey and L["CTX_EDIT_SHORTKEY"] or L["OPT_COL_SHORTKEY"],
            fullText = extra.hasShortkey and L["CTX_EDIT_SHORTKEY"] or L["CTX_ADD_SHORTKEY"],
            tooltip = L["CTX_ADD_SHORTKEY_TT"],
            onClick = extra.onAddShortkey,
        }
    end
    if extra and extra.onCreateMacro then
        addRows[#addRows + 1] = {
            actionId = "macro", text = L["CTX_EASYFIND_MACRO"], fullText = L["CTX_CREATE_MACRO"],
            tooltip = L["CTX_CREATE_MACRO_TT"], onClick = extra.onCreateMacro,
        }
    end
    -- The exact glyph the pinned result rows wear (Utils.CreatePinGlyph),
    -- so the menu action and the row marker read as one concept; Unpin
    -- adds the red X corner badge. A clipboard history entry pins to the
    -- top of the history only (a general pin would die with the entry
    -- when the history is cleared), so its pin takes this place.
    if extra and extra.onClipPin then
        rows[#rows + 1] = {
            text = extra.clipPinned and L["CTX_CLIP_UNPIN"] or L["CTX_CLIP_PIN"],
            pinGlyph = true,
            iconOverlay = extra.clipPinned and "Interface\\RaidFrame\\ReadyCheck-NotReady" or nil,
            onClick = extra.onClipPin,
        }
    else
        rows[#rows + 1] = {
            text = isPinned and (_G["RECENT_ALLIES_MENU_BUTTON_LABEL_UNPIN"] or "Unpin") or (_G["RECENT_ALLIES_MENU_BUTTON_LABEL_PIN"] or "Pin"),
            pinGlyph = true,
            iconOverlay = isPinned and "Interface\\RaidFrame\\ReadyCheck-NotReady" or nil,
            actionId = "pin", onClick = onPin,
        }
    end
    if onGuide then
        rows[#rows + 1] = { actionId = "guide", text = L["CTX_GUIDE"], icon = ns.EYE_ICON_TEX, chromeIcon = true, onClick = onGuide }
    end
    -- GPS: directions to the row, or a route starting there; the custom
    -- line-art glyph, as Guide's eye.
    if extra and extra.onGPS and extra.onGPSFrom then
        rows[#rows + 1] = {
            text = L["APP_GPS"], icon = ns.GPS_ICON_TEX, chromeIcon = true,
            submenu = {
                { text = L["CTX_GPS_TO"], onClick = extra.onGPS },
                { text = L["CTX_GPS_FROM"], onClick = extra.onGPSFrom },
            },
        }
    elseif extra and (extra.onGPS or extra.onGPSFrom) then
        rows[#rows + 1] = {
            text = extra.onGPS and L["CTX_GPS"] or L["CTX_GPS_FROM"], icon = ns.GPS_ICON_TEX, chromeIcon = true,
            onClick = extra.onGPS or extra.onGPSFrom,
        }
    end
    -- An extension's own rows for the result, under its name with its glyph.
    if extra and extra.extensionMenu then
        local m = extra.extensionMenu
        rows[#rows + 1] = { text = m.label, icon = m.icon, iconCoords = m.iconCoords, chromeIcon = true, submenu = m.rows }
    end
    if extra and extra.wowheadUrl then
        -- Our own chain-link glyph (textures/link.tga), the same custom
        -- treatment as Guide's eye and Pin's diamond. A copy row: the URL
        -- reaches the clipboard through the row's Ctrl+C.
        rows[#rows + 1] = {
            text = L["CTX_WOWHEAD"], icon = ns.LINK_ICON_TEX, chromeIcon = true,
            copy = extra.wowheadUrl, tooltip = L["COPY_ROW_TT"],
        }
    end
    if extra and extra.sendLink then
        -- Hover-cascade flyout of chat channels, opened beside the row like
        -- every other flyout; the arrow glyph marks it as a submenu.
        local sendRows = ns.BuildSendLinkRows(extra.sendLink.link)
        if sendRows then
            -- No bespoke arrow: rows with a submenu get the shared chevron
            -- from the menu module; adding one here doubled the arrows.
            -- Also a copy row: the chord the label names works right here,
            -- on the flyout's parent, as well as on the result row.
            rows[#rows + 1] = {
                actionId = "send", text = L["CTX_SEND_LINK"],
                copy = Utils.ClipboardSafeText(extra.sendLink.link),
                copyLink = extra.sendLink.link,
                copyKey = "Ctrl+C",
                tooltip = L["COPY_ROW_TT"],
                tooltipNote = L["COPY_ROW_TT_RESULT"],
                submenu = sendRows,
            }
        end
    end
    if extra and extra.easyFindLinkRows then
        -- Plain text another EasyFind user's chat turns into a clickable
        -- link to this very row (Shared/ResultLinks.lua).
        -- Sorted directly after Send, in every locale: the two rows are
        -- the same idea (share this row), so they sit together.
        rows[#rows + 1] = {
            text = L["CTX_EASYFIND_LINK"],
            sortKey = L["CTX_SEND_LINK"] .. "\1",
            -- A copy row too: Ctrl+Shift+C (the chord the label names,
            -- the result row's own) copies the link from this very row.
            copy = extra.easyFindLinkText and Utils.ClipboardSafeText(extra.easyFindLinkText),
            copyLink = extra.easyFindLinkText,
            copyKey = "Ctrl+Shift+C",
            tooltip = L["EFLINK_ROW_TT"],
            tooltipNote = L["EFLINK_ROW_TT_NOTE"],
            submenu = extra.easyFindLinkRows,
        }
    end
    -- An entry an app or extension adds wears its icon: where it comes from.
    local function AppEntry(id, entry)
        local app = ns.Extensions and ns.Extensions.Get(id)
        if app and app.icon then
            entry.icon, entry.iconCoords, entry.chromeIcon = app.icon, app.iconCoords, true
        end
        return entry
    end
    if extra and extra.addNoteRows then
        addRows[#addRows + 1] = AppEntry("notes",
            { actionId = "note", text = L["CTX_NOTE"], fullText = L["CTX_ADD_NOTE"], submenu = extra.addNoteRows })
    end
    if extra and extra.addQuicklistRows then
        addRows[#addRows + 1] = AppEntry("quicklists", {
            actionId = "quicklist", text = L["CTX_QUICKLIST"], fullText = L["CTX_ADD_QUICKLIST"],
            submenu = extra.addQuicklistRows,
        })
    end
    for _, target in ipairs(extra and extra.addTargets or {}) do
        addRows[#addRows + 1] = target
    end
    AddGroup(_G["ADD"] or "Add", addRows)
    if extra and extra.onBlacklist then
        removeRows[#removeRows + 1] = {
            actionId = "blacklist", text = L["CTX_BLACKLIST"], tooltip = L["CTX_BLACKLIST_TT"], onClick = extra.onBlacklist,
        }
    end
    if extra and extra.onForgetPick then
        -- Only on a row search put on top from a past pick for this text.
        removeRows[#removeRows + 1] = {
            text = L["CTX_FORGET_PICK"], tooltip = L["CTX_FORGET_PICK_TT"],
            onClick = extra.onForgetPick,
        }
    end
    AddGroup(_G["REMOVE"] or "Remove", removeRows)

    local extras = {}
    if extra and extra.onTrack then
        extras[#extras + 1] = {
            text = extra.isTracked and L["CTX_UNTRACK"] or L["CTX_TRACK"],
            onClick = extra.onTrack,
        }
    end
    if extra and extra.onToggleBackpack then
        extras[#extras + 1] = {
            text = extra.isOnBackpack and L["CTX_REMOVE_FROM_BACKPACK"] or L["CTX_SHOW_ON_BACKPACK"],
            onClick = extra.onToggleBackpack,
        }
    end
    if extra and extra.onTransfer then
        extras[#extras + 1] = { text = _G["TRANSFER"] or "Transfer", onClick = extra.onTransfer }
    end
    if extra and extra.onToggleWatchedFaction then
        extras[#extras + 1] = {
            text = extra.isWatchedFaction and L["CTX_HIDE_XP_BAR"] or L["CTX_SHOW_XP_BAR"],
            onClick = extra.onToggleWatchedFaction,
        }
    end
    if extra and extra.onSummon then
        extras[#extras + 1] = { text = _G["SUMMON"] or "Summon", onClick = extra.onSummon }
    end
    if extra and extra.onRename then
        extras[#extras + 1] = { text = _G["PET_RENAME"] or "Rename", onClick = extra.onRename }
    end
    if extra and extra.onToggleFavorite then
        extras[#extras + 1] = {
            text = extra.isFavorite and (_G["BATTLE_PET_UNFAVORITE"] or "Remove Favorite") or (_G["BATTLE_PET_FAVORITE"] or "Set Favorite"),
            onClick = extra.onToggleFavorite,
        }
    end
    if extra and extra.onCageOrRelease then
        extras[#extras + 1] = {
            text = extra.isCageable and (_G["BATTLE_PET_PUT_IN_CAGE"] or "Put In Cage") or (_G["BATTLE_PET_RELEASE"] or "Release"),
            onClick = extra.onCageOrRelease,
        }
    end
    if extra and extra.onDestroyItem then
        extras[#extras + 1] = { text = L["CTX_DESTROY_ITEM"], onClick = extra.onDestroyItem }
    end
    if extra and extra.onSnippetEdit then
        extras[#extras + 1] = { text = _G["EDIT"] or "Edit", onClick = extra.onSnippetEdit }
    end
    if extra and extra.onSnippetInsertNote then
        extras[#extras + 1] = { text = L["SNIPPET_INSERT_NOTE"], onClick = extra.onSnippetInsertNote }
    end
    if extra and extra.onSnippetDelete then
        extras[#extras + 1] = { text = _G["DELETE"] or "Delete", onClick = extra.onSnippetDelete }
    end
    if extra and extra.onClipSaveSnippet then
        extras[#extras + 1] = { text = L["CTX_CLIP_SAVE_SNIPPET"], onClick = extra.onClipSaveSnippet }
    end
    if extra and extra.onClipDelete then
        extras[#extras + 1] = { text = _G["DELETE"] or "Delete", onClick = extra.onClipDelete }
    end
    if extra and extra.onClipClear then
        extras[#extras + 1] = { text = L["CTX_CLIP_CLEAR"], onClick = extra.onClipClear }
    end
    -- Alphabetical within each section (per-locale, since labels are
    -- localized); the separator keeps standard and extra actions apart.
    tsort(rows, MenuRowLess)
    tsort(extras, MenuRowLess)
    if #extras > 0 then
        rows[#rows + 1] = { isSeparator = true }
        for i = 1, #extras do rows[#rows + 1] = extras[i] end
    end

    -- A result action's chord beside its entry; unbound, where to bind one.
    local RowActions = ns.ResultRowActions
    local function KeyHints(list)
        for _, r in ipairs(list) do
            if r.actionId and not r.copy then
                local chord = RowActions.ChordText(RowActions.KeyOf(r.actionId))
                if chord then
                    r.keyHint = chord
                elseif r.tooltip then
                    r.tooltipNote = r.tooltipNote or L["ROWACT_BIND_HINT"]
                else
                    r.tooltip = L["ROWACT_BIND_HINT"]
                end
            elseif type(r.submenu) == "table" and not r.actionId then
                KeyHints(r.submenu)
            end
        end
    end
    if RowActions then KeyHints(rows) end

    if extra and extra.disabled then
        for i = 1, #rows do
            if not rows[i].isSeparator then rows[i].disabled = true end
        end
    end

    return rows
end

-- Chat channels the "Send link" flyout offers, in display order. `enabled`
-- gates a channel to when it can actually be used (in a party/instance group,
-- raid, or guild); ungated channels are always available. The label is the
-- localized Blizzard global for the channel name.
local SEND_LINK_CHANNELS = {
    { chan = "SAY" },
    { chan = "YELL" },
    { chan = "PARTY",         enabled = function() return IsInGroup() end },
    { chan = "INSTANCE_CHAT", enabled = function() return IsInGroup(LE_PARTY_CATEGORY_INSTANCE or 2) end },
    { chan = "RAID",          enabled = function() return IsInRaid() end },
    { chan = "GUILD",         enabled = function() return IsInGuild() end },
}

-- Whisper target for the current unit target, realm-qualified when cross-realm;
-- nil unless a player is targeted.
local function SendLinkTargetName()
    if not UnitExists("target") or not UnitIsPlayer("target") then return nil end
    local name, realm = UnitName("target")
    if not name then return nil end
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

-- Build the "Send link" flyout rows for a result's chat link: public/group
-- channels, a whisper to the current target, a whisper by typed name, and
-- the clipboard copy row (WoW has no silent set-clipboard API, so a
-- hardware Ctrl+C on the row is the copy). Returned as a submenu spec for
-- the context menu.
-- `copyKey` names the chord that copies the same text from the result row
-- (default Ctrl+C); `copyNote` is the clipboard row's tooltip afterthought.
function ns.BuildSendLinkRows(link, copyKey, copyNote)
    if not link then return nil end
    local rows = {}
    for i = 1, #SEND_LINK_CHANNELS do
        local c = SEND_LINK_CHANNELS[i]
        local on = (not c.enabled) or c.enabled()
        local chan = c.chan
        rows[#rows + 1] = {
            text = _G[chan] or chan,
            disabled = (not on) or nil,
            onClick = on and function() SendChatMessage(link, chan) end or nil,
        }
    end
    local targetName = SendLinkTargetName()
    rows[#rows + 1] = {
        text = _G["TARGET"] or "Target",
        disabled = (not targetName) or nil,
        onClick = targetName and function() SendChatMessage(link, "WHISPER", nil, targetName) end or nil,
    }
    rows[#rows + 1] = {
        text = L["CTX_SEND_LINK_NAME"],
        onClick = function()
            ns.ShowThemedDialog({
                text = L["CTX_SEND_LINK_NAME_PROMPT"],
                messageColor = ns.GOLD_COLOR,
                hasEditBox = true,
                maxLetters = 48,
                acceptText = _G["SEND_LABEL"] or _G["OKAY"],
                onAccept = function(val)
                    val = val and strtrim(val) or ""
                    if val ~= "" then SendChatMessage(link, "WHISPER", nil, val) end
                end,
            })
        end,
    }
    local chatRows = ns.BuildChatSendRows(link)
    if chatRows then
        rows[#rows + 1] = { text = L["CTX_SEND_LINK_MESSENGER"], submenu = chatRows }
    end
    rows[#rows + 1] = { isSeparator = true }
    -- The clipboard carries the text with links flattened to their
    -- display names; the live link rides along for a chat paste. The
    -- tooltip also points at the shortcut: Ctrl+C on the result row
    -- itself copies the same text without the menu.
    rows[#rows + 1] = {
        text = L["CTX_SEND_LINK_CLIPBOARD"],
        copy = Utils.ClipboardSafeText(link),
        copyLink = link,
        copyKey = copyKey or "Ctrl+C",
        tooltip = L["COPY_ROW_TT"],
        tooltipNote = copyNote or L["COPY_ROW_TT_RESULT"],
    }
    return rows
end

-- The messenger's threads for a result's link: a new conversation, then
-- each thread it has, most recent first. Unloaded, the messenger offers
-- the new conversation alone and loads on that click; absent, nothing.
function ns.BuildChatSendRows(link)
    if not link then return nil end
    if ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Chat") then return nil end
    local rows = {
        { text = L["CHAT_NEW_CONVERSATION"], onClick = function()
            EasyFind.API.CallAction("chat", "compose", link)
        end },
    }
    local Chat = ns.Chat
    local list = Chat and Chat.ListConversations and Chat:ListConversations() or {}
    if #list > 0 then rows[#rows + 1] = { isSeparator = true } end
    for i = 1, math.min(#list, 12) do
        local c = list[i]
        rows[#rows + 1] = { text = c.label, onClick = function() Chat:ComposeWith(c.key, link) end }
    end
    return rows
end

-- Build the "Add to Note" flyout rows: a New Note action plus each existing
-- note (most-recent first) the link appends to. Needs the optional EasyNotes
-- plugin (loaded on demand); returns nil when it is absent so the menu row is
-- hidden. Both actions open the editor to the note as confirmation.
function ns.BuildAddNoteRows(link, name)
    if not link then return nil end
    local Notes = ns.Notes
    if not (Notes and Notes.CreateNote) and C_AddOns and C_AddOns.LoadAddOn then
        pcall(C_AddOns.LoadAddOn, "EasyFind_Notes")
        Notes = ns.Notes
    end
    if not (Notes and Notes.CreateNote and Notes.ListNotes and Notes.AppendToNote) then
        return nil
    end
    local rows = {}
    rows[#rows + 1] = {
        text = L["CTX_NEW_NOTE"],
        onClick = function()
            local id = Notes.CreateNote({ title = name, body = link })
            if id and Notes.OpenNote then Notes.OpenNote(id) end
        end,
    }
    local notes = Notes.ListNotes()
    if notes and #notes > 0 then
        rows[#rows + 1] = { isSeparator = true }
        for i = 1, math.min(#notes, 20) do
            local noteID = notes[i].id
            rows[#rows + 1] = {
                text = notes[i].title,
                onClick = function()
                    Notes.AppendToNote(noteID, link)
                    if Notes.OpenNote then Notes.OpenNote(noteID) end
                end,
            }
        end
    end
    return rows
end

-- The pin marker: bronze diamond with an additive gold core, composited
-- from a high-res (64px) diamond source so it stays crisp at any scale.
-- ONE construction, used by the pinned result rows and the context menu
-- pin row, so the glyph reads identically everywhere.
function Utils.CreatePinGlyph(parent, size)
    local DIAMOND_TEX = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3"
    local glyph = CreateFrame("Frame", nil, parent)
    glyph:SetSize(size, size)
    local outer = glyph:CreateTexture(nil, "OVERLAY", nil, 1)
    outer:SetTexture(DIAMOND_TEX)
    outer:SetDesaturated(true)
    outer:SetVertexColor(0.78, 0.50, 0.22)  -- bronze
    outer:SetAllPoints(glyph)
    local core = glyph:CreateTexture(nil, "OVERLAY", nil, 2)
    core:SetTexture(DIAMOND_TEX)
    core:SetDesaturated(true)
    core:SetVertexColor(ns.GOLD_COLOR[1], ns.GOLD_COLOR[2], ns.GOLD_COLOR[3], 0.9)
    core:SetBlendMode("ADD")
    core:SetPoint("CENTER")
    core:SetSize(size * 0.5, size * 0.5)
    return glyph
end

function Utils.SetIconTexture(textureObj, icon, fallback)
    if not textureObj then return end
    textureObj:SetTexture(nil)
    if textureObj.SetAtlas then textureObj:SetAtlas(nil) end
    textureObj:SetTexCoord(0, 1, 0, 1)
    if type(icon) == "table" and icon.file then
        textureObj:SetTexture(icon.file)
        if icon.coords then textureObj:SetTexCoord(unpack(icon.coords)) end
    elseif type(icon) == "string" and ssub(icon, 1, 6) == "atlas:" then
        textureObj:SetAtlas(ssub(icon, 7), false)
    elseif icon then
        textureObj:SetTexture(icon)
    else
        textureObj:SetTexture(fallback or "Interface\\Icons\\INV_Misc_QuestionMark")
    end
end

-- Apply the Blizzard dropdown-button background to a texture. The atlas has a
-- fixed vertical structure (top bevel + center + bottom bevel); stretching it
-- to an arbitrary button height squashes the bevels and reads as "too short".
-- Pin it to its native height and stretch only horizontally, matching the
-- in-game dropdown buttons (e.g. the Encounter Journal loot filter).
function Utils.StyleDropdownBg(bg)
    if not bg then return end
    bg:SetAtlas("common-dropdown-textholder")
    local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("common-dropdown-textholder")
    local height = (info and info.height) or 41
    bg:ClearAllPoints()
    bg:SetPoint("LEFT", 0, 0)
    bg:SetPoint("RIGHT", 0, 0)
    bg:SetHeight(height)
end

local INTER_REGULAR  = "Interface\\AddOns\\EasyFind\\Fonts\\Inter-Regular.ttf"
local INTER_SEMIBOLD = "Interface\\AddOns\\EasyFind\\Fonts\\Inter-SemiBold.ttf"
local INTER_BOLD     = "Interface\\AddOns\\EasyFind\\Fonts\\Inter-Bold.ttf"

-- "Default" = the client's own UI font (varies by locale); the rest map to
-- font files below. Arial Narrow ships inside the WoW client, so it costs
-- nothing to offer.
ns.FONT_CHOICES = { "Default", "Inter", "Lato", "Poppins", "Arial Narrow" }

local ADDON_FONTS_DIR = "Interface\\AddOns\\EasyFind\\Fonts\\"
local ADDON_FONT_FILES = {
    ["Inter"] = {
        regular  = INTER_REGULAR,
        semibold = INTER_SEMIBOLD,
        bold     = INTER_BOLD,
    },
    ["Lato"] = {
        regular  = ADDON_FONTS_DIR .. "Lato-Regular.ttf",
        semibold = ADDON_FONTS_DIR .. "Lato-Bold.ttf",
        bold     = ADDON_FONTS_DIR .. "Lato-Bold.ttf",
    },
    ["Poppins"] = {
        regular  = ADDON_FONTS_DIR .. "Poppins-Regular.ttf",
        semibold = ADDON_FONTS_DIR .. "Poppins-SemiBold.ttf",
        bold     = ADDON_FONTS_DIR .. "Poppins-Bold.ttf",
    },
    ["Arial Narrow"] = {
        regular = "Fonts\\ARIALN.TTF",
    },
}

local fontRegistry = {}

local function GetFontChoice()
    return (EasyFind and EasyFind.db and EasyFind.db.font) or "Default"
end

local function ApplyFontTo(fs)
    if not fs or not fs.SetFont then return end
    local baseline = fs._addonFontBaseline
    if not baseline then return end
    local size  = fs._addonFontSizeOverride or baseline.size or 12
    local flags = fs._addonFontFlags or baseline.flags or ""
    local files = ADDON_FONT_FILES[GetFontChoice()]
    if files then
        local w = fs._addonFontWeight
        if fs:SetFont(files[w] or files.regular, size, flags) then return end
        -- Font file not loadable (e.g. added after the client launched, which
        -- only scans addon files at startup): keep the baseline font rather
        -- than leaving the text blank.
    end
    fs:SetFont(baseline.path, baseline.size, baseline.flags or "")
end

-- Pre-rasterize every bundled font once at login. A FontString whose
-- font file has not been rasterized this session renders NOTHING until
-- something re-sets its text; the multi-MB families are slow enough to
-- rasterize that the font dropdown's self-previewing rows intermittently
-- came up blank. The warm frame sits offscreen at alpha 0 (hidden
-- FontStrings do not rasterize).
local fontWarmFrame
function ns.WarmAddonFonts()
    if fontWarmFrame then return end
    fontWarmFrame = CreateFrame("Frame", nil, UIParent)
    fontWarmFrame:SetSize(1, 1)
    fontWarmFrame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -80, -80)
    fontWarmFrame:SetAlpha(0)
    local warmed = {}
    for _, files in pairs(ADDON_FONT_FILES) do
        for _, path in pairs(files) do
            if not warmed[path] then
                warmed[path] = true
                local fs = fontWarmFrame:CreateFontString(nil, "ARTWORK")
                fs:SetPoint("BOTTOMLEFT")
                fs:SetFont(path, 12, "")
                fs:SetText("Ag")
            end
        end
    end
end

-- Resolve the font path a piece of UI text should use: the chosen font's
-- file for the weight, else the caller's own (Blizzard) path. Lets
-- per-render font sizing (ScaleFont) honor the font choice without joining
-- the FontString registry.
function ns.GetAddonFontPath(weight, fallback)
    local files = ADDON_FONT_FILES[GetFontChoice()]
    if not files then return fallback end
    return files[weight] or files.regular
end

-- The file a named choice would use (regardless of the current choice),
-- for previewing dropdown rows in their own font. nil for "Default".
function ns.GetFontChoicePath(name)
    local files = ADDON_FONT_FILES[name]
    return files and files.regular or nil
end

-- Recursively register every FontString under a frame with the addon font
-- system, so the Inter choice applies to whole surfaces (options panel,
-- search chrome, menus). Idempotent per FontString.
function ns.RegisterAddonFontsIn(frame)
    if not frame then return end
    if frame.GetRegions then
        for i = 1, select("#", frame:GetRegions()) do
            local region = select(i, frame:GetRegions())
            if region and region.GetObjectType and region:GetObjectType() == "FontString" then
                ns.RegisterAddonFont(region)
            end
        end
    end
    if frame.GetChildren then
        for i = 1, select("#", frame:GetChildren()) do
            ns.RegisterAddonFontsIn((select(i, frame:GetChildren())))
        end
    end
end

function ns.RegisterAddonFont(fs, weight, sizeOverride, flags)
    if not fs or not fs.GetFont or not fs.SetFont then return end
    -- Font-preview rows each render in their OWN font on purpose; they must
    -- never be driven by the current global choice, or selecting a font would
    -- overwrite (and blank) the other choices' preview text.
    if fs._efFontPreview then return end
    if not fs._addonFontBaseline then
        local p, sz, fl = fs:GetFont()
        fs._addonFontBaseline = { path = p, size = sz, flags = fl }
        fontRegistry[#fontRegistry + 1] = fs
    end
    fs._addonFontWeight       = weight
    fs._addonFontSizeOverride = sizeOverride
    fs._addonFontFlags        = flags
    ApplyFontTo(fs)
end

function ns.RefreshAddonFont()
    for i = 1, #fontRegistry do
        ApplyFontTo(fontRegistry[i])
    end
end
