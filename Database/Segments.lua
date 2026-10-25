local _, ns = ...
local Database = ns.Database
local Utils = ns.Utils

-- Saved search index segments (Database/SearchIndex.lua): a source's rows
-- are indexed once and the index is saved; a later load restores it in a
-- few ms when the text the index reads from those rows is the same. The
-- rows themselves always come from their source, so nothing stale is shown.
local Segments = {}
ns.SearchSegments = Segments

local VERSION = 1
local RETRIES = 5
local tconcat = table.concat
local getmetatable, rawget = getmetatable, rawget

-- Per character: rows that differ by character. Everything else is kept
-- for the account; a mismatch only means a rebuild.
local CHAR_SCOPED = {
    bags = true, bank = true, talents = true, abilities = true, macros = true, professions = true,
    titles = true, gearSets = true, outfits = true, statistics = true, reputations = true, currencies = true,
}

-- What the index reads from a row (SearchIndex IndexEntry), joined.
local textBuf = {}
local function RowText(data)
    if data.lootEntry then return "\2L" end
    local nameLower, kws
    local mt = getmetatable(data)
    local pc = mt and rawget(mt, "__pcCorpus")
    if pc then
        local ri = rawget(data, "_ri")
        nameLower, kws = pc:NameLowerOf(ri), pc:KeywordsOf(ri)
    else
        nameLower = data.nameLower
    end
    kws = kws or data.keywordsLower or data.keywords
    local n = 1
    textBuf[1] = nameLower or ""
    if kws then
        for k = 1, #kws do
            n = n + 1
            textBuf[n] = kws[k] or ""
        end
    end
    if not pc and (rawget(data, "snippetKeywordLower") or rawget(data, "teleportNameLower")
                   or rawget(data, "scoreBonus")) then
        n = n + 1
        textBuf[n] = "\2S"
    end
    local s = tconcat(textBuf, "\3", 1, n)
    for i = 1, n do textBuf[i] = nil end
    return s
end
Segments.RowText = RowText

local function Store(key)
    local db = EasyFind and EasyFind.db
    if not db then return nil end
    if not CHAR_SCOPED[key] then
        db.searchIndexCache = db.searchIndexCache or {}
        return db.searchIndexCache
    end
    local char = ns.CurrentCharacterKey and ns.CurrentCharacterKey()
    if not char then return nil end
    db.searchIndexCharCache = db.searchIndexCharCache or {}
    local store = db.searchIndexCharCache[char]
    if not store then
        store = {}
        db.searchIndexCharCache[char] = store
    end
    return store
end

local function StillLive(rows)
    local want = {}
    for i = 1, #rows do want[rows[i]] = true end
    local data, found = Database.uiSearchData, 0
    for i = 1, #data do
        if want[data[i]] then found = found + 1 end
    end
    return found == #rows
end

local attachGen, attachRun = {}, {}

-- rows: a source's rows in order, already in uiSearchData. Restored from
-- the saved segment when their text matches, else indexed and saved. The
-- text is read in background slices: rows gone from uiSearchData by then
-- stay unattached, and a newer attach of the key replaces this one.
function Segments.Attach(key, rows)
    local SearchIndex = ns.SearchIndex
    if not (SearchIndex and SearchIndex.RestoreSegment) or #rows == 0 then return end
    local store = Store(key)
    if not store then return end
    local gen = (attachGen[key] or 0) + 1
    attachGen[key] = gen
    if attachRun[key] then attachRun[key]:Cancel() end
    local function Current() return attachGen[key] == gen and StillLive(rows) end
    attachRun[key] = Utils.RunSliced(function()
        local parts = {}
        for i = 1, #rows do
            if i % 64 == 0 then Utils.SliceCheckpoint() end
            parts[i] = RowText(rows[i])
        end
        return tconcat(parts, "\1")
    end, function(ok, text)
        if attachGen[key] == gen then attachRun[key] = nil end
        if not ok then return Utils.ErrorHandler(text) end
        if not Current() then return end
        local saved = store[key]
        local function Build()
            SearchIndex:BuildSegment(key, rows, function(built)
                if not built then return end
                local snap = SearchIndex:SegmentSnapshot(key)
                store[key] = snap and { v = VERSION, text = text, snap = snap } or nil
            end)
        end
        if not (saved and saved.v == VERSION and saved.text == text) then
            Build()
            return
        end
        -- A restore is refused while a search reads the index: next frame.
        local tries = 0
        local function Restore()
            if tries > 0 and not Current() then return end
            if SearchIndex:RestoreSegment(key, saved.snap, rows) then return end
            tries = tries + 1
            if tries < RETRIES then Utils.SafeAfter(0, Restore) else Build() end
        end
        Restore()
    end, 1.5, "segmentText " .. key)
end

-- The shipped rows, built at file load before saved variables exist.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    local rows = Database.staticRows
    Database.staticRows = nil
    if rows then Segments.Attach("static", rows) end
end)
