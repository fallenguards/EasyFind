local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns then return end

-- Clipboard history store: the entries and the rules (repeat merging,
-- the cap, the age limit), free of any frame or event so the tests cover
-- it whole. Entries live in the core saved variables (EasyFindDB.clipboard),
-- account-wide like snippets, newest first.
local Store = {}
ns.ClipboardStore = Store

local Utils = ns.Utils or {}
local smatch = Utils.smatch or string.match
local sfind = Utils.sfind or string.find
local ssub = Utils.ssub or string.sub
local sbyte = string.byte
local tremove = Utils.tremove or table.remove
local tinsert = table.insert
local type = Utils.type or type
local time = time

-- Defaults; the options page sets clipboardMaxEntries and
-- clipboardMaxDays (0 = forever) on the account db.
Store.MAX_ENTRIES = 200
Store.MAX_DAYS = 30
Store.MAX_AGE = Store.MAX_DAYS * 86400
-- Bumped when Classify learns a kind; older entries are reclassified
-- once on load so a filter by kind sees them right.
Store.KIND_VERSION = 2
-- The same text arriving again within this many seconds is one event (a
-- message shown in two chat tabs, a chord pressed twice), not a repeat.
Store.REPEAT_WINDOW = 2
-- Longest text kept: a pasted wall of text is cut, and its first lines are
-- what identify it anyway.
Store.MAX_TEXT = 2000
Store.FIRST_LINE_MAX = 80

Store.KIND = {
    LINK = "link", EFLINK = "eflink", MAPPIN = "mappin", URL = "url", NUMBER = "number",
    COMMAND = "command", TEXT = "text",
}
Store.SOURCE = { COPIED = "copied", PASTED = "pasted", CHAT = "chat", SENT = "sent" }

-- Cut a string at a byte count without splitting a UTF-8 character.
function Store.CutBytes(s, n)
    if not s or #s <= n then return s end
    local cut = n
    while cut > 0 do
        local b = sbyte(s, cut + 1)
        if not b or b < 0x80 or b > 0xBF then break end
        cut = cut - 1
    end
    return ssub(s, 1, cut)
end

local function Root()
    if type(EasyFindDB) ~= "table" then return nil end
    local root = EasyFindDB.clipboard
    if type(root) ~= "table" then
        root = { entries = {}, nextId = 1, settings = {} }
        EasyFindDB.clipboard = root
    end
    if type(root.entries) ~= "table" then root.entries = {} end
    if type(root.settings) ~= "table" then root.settings = {} end
    if type(root.nextId) ~= "number" then root.nextId = 1 end
    if root.kindVersion ~= Store.KIND_VERSION and Store.Classify then
        for i = 1, #root.entries do
            local e = root.entries[i]
            e.kind = Store.Classify(e.text, e.link)
        end
        root.kindVersion = Store.KIND_VERSION
    end
    return root
end

function Store.MaxEntries()
    local db = EasyFind and EasyFind.db
    local v = db and tonumber(db.clipboardMaxEntries)
    return (v and v > 0) and v or Store.MAX_ENTRIES
end

-- Seconds, or nil for forever.
function Store.MaxAge()
    local db = EasyFind and EasyFind.db
    local days = db and tonumber(db.clipboardMaxDays)
    if days == 0 then return nil end
    if days then return days * 86400 end
    return Store.MAX_AGE
end

-- Source toggles live in the core options (EasyFind.db, defaults in
-- Core/Main.lua) so the filter menu's checkboxes drive them; the store's
-- own table only stands in when no options exist (tests).
local DB_KEY = {
    copied = "clipboardCopied", pasted = "clipboardPasted",
    chat = "clipboardChat", whispers = "clipboardWhispers", sent = "clipboardSent",
}
local DEFAULTS = { copied = true, pasted = true, chat = false, whispers = false, sent = false }

function Store:Settings()
    local db = EasyFind and EasyFind.db
    local out = {}
    local root = Root()
    local own = root and root.settings or {}
    for key, default in pairs(DEFAULTS) do
        local value
        if db then value = db[DB_KEY[key]] end
        if value == nil then value = own[key] end
        if value == nil then value = default end
        out[key] = value
    end
    return out
end

function Store.Classify(text, link)
    if link and link ~= "" then
        if sfind(link, "|Heasyfind:", 1, true) then return Store.KIND.EFLINK end
        -- A map pin link is a link, but its own kind: it opens the map at a
        -- spot, and it wears the pin glyph.
        if sfind(link, "|Hworldmap:", 1, true) then return Store.KIND.MAPPIN end
        return Store.KIND.LINK
    end
    if type(text) ~= "string" then return Store.KIND.TEXT end
    -- Pasted text can carry a link's markup, or a map pin's bracketed
    -- name without any link at all.
    if sfind(text, "|Hworldmap:", 1, true) then return Store.KIND.MAPPIN end
    if sfind(text, "|Heasyfind:", 1, true) then return Store.KIND.EFLINK end
    local pinName = _G["MAP_PIN_HYPERLINK"]
    if pinName and smatch(text, "^%s*%[%s*" .. (pinName:gsub("%p", "%%%0")) .. "%s*%]%s*$") then
        return Store.KIND.MAPPIN
    end
    if smatch(text, "^%[EasyFind: ") then return Store.KIND.EFLINK end
    if smatch(text, "^%s*https?://") or smatch(text, "^%s*www%.") then return Store.KIND.URL end
    if smatch(text, "^%s*/%a") then return Store.KIND.COMMAND end
    if smatch(text, "%d") and smatch(text, "^%s*[%d%.,%s%+%-%*/%%%(%)gsc]+%s*$") then
        return Store.KIND.NUMBER
    end
    return Store.KIND.TEXT
end

-- The line a row shows: first line, markup stripped, cut to a row's width.
function Store.FirstLine(text)
    if type(text) ~= "string" then return "" end
    local line = smatch(text, "^[^\r\n]*") or text
    if Utils.StripMarkup then
        line = Utils.StripMarkup(line) or line
    else
        line = smatch(line, "^%s*(.-)%s*$") or line
    end
    if #line > Store.FIRST_LINE_MAX then
        line = Store.CutBytes(line, Store.FIRST_LINE_MAX - 3) .. "..."
    end
    return line
end

function Store:Entries()
    local root = Root()
    return root and root.entries or {}
end

function Store:Count()
    return #self:Entries()
end

function Store:Get(id)
    local entries = self:Entries()
    for i = 1, #entries do
        if entries[i].id == id then return entries[i] end
    end
    return nil
end

local function SameEntry(entry, text, link)
    return entry.text == text and (entry.link or "") == (link or "")
end

-- Record one capture. `meta` may carry sender, channel, char, and `now`
-- (tests). Returns the entry, or nil when there was nothing to keep.
function Store:Record(source, text, link, meta)
    local root = Root()
    if not root then return nil end
    if type(text) ~= "string" or not smatch(text, "%S") then return nil end
    if #text > Store.MAX_TEXT then text = Store.CutBytes(text, Store.MAX_TEXT) end
    if link == "" then link = nil end
    local now = (meta and meta.now) or time()
    local entries = root.entries
    local first = entries[1]
    if first and SameEntry(first, text, link) and (now - (first.at or 0)) < Store.REPEAT_WINDOW then
        return first
    end
    local entry
    for i = 1, #entries do
        if SameEntry(entries[i], text, link) then
            entry = tremove(entries, i)
            break
        end
    end
    if entry then
        entry.count = (entry.count or 1) + 1
    else
        entry = {
            id = root.nextId, text = text, link = link,
            kind = Store.Classify(text, link), count = 1,
        }
        root.nextId = root.nextId + 1
    end
    entry.at = now
    entry.source = source
    -- Each action keeps its own last time: an entry copied here and
    -- pasted later shows both moments, not just the latest.
    if source == Store.SOURCE.COPIED then
        entry.copiedAt = now
    elseif source == Store.SOURCE.PASTED then
        entry.pastedAt = now
    elseif source == Store.SOURCE.SENT then
        entry.sentAt = now
    end
    if meta then
        if meta.sender ~= nil then entry.sender = meta.sender end
        if meta.channel ~= nil then entry.channel = meta.channel end
        if meta.char ~= nil then entry.char = meta.char end
        if meta.icon ~= nil then entry.icon = meta.icon end
    end
    tinsert(entries, 1, entry)
    self:Prune(now)
    return entry
end

-- Drop what is past the cap or the age limit. Pinned entries count
-- toward neither: a pin means keep.
function Store:Prune(now)
    local root = Root()
    if not root then return end
    now = now or time()
    local entries = root.entries
    local maxEntries = Store.MaxEntries()
    local maxAge = Store.MaxAge()
    local kept = 0
    for i = 1, #entries do
        local entry = entries[i]
        if not entry.pinned then
            kept = kept + 1
            if kept > maxEntries or (maxAge and (now - (entry.at or 0)) > maxAge) then
                entry._drop = true
            end
        end
    end
    for i = #entries, 1, -1 do
        if entries[i]._drop then tremove(entries, i) end
    end
end

-- A pin keeps an entry out of pruning and at the top of the list.
function Store:SetPinned(id, on)
    local entry = self:Get(id)
    if not entry then return false end
    entry.pinned = on and time() or nil
    return true
end

function Store:Remove(id)
    local entries = self:Entries()
    for i = 1, #entries do
        if entries[i].id == id then
            tremove(entries, i)
            return true
        end
    end
    return false
end

-- Everything but the pins: a pin means keep, here as in pruning.
function Store:Clear()
    local root = Root()
    if not root then return end
    local kept = {}
    for i = 1, #root.entries do
        if root.entries[i].pinned then kept[#kept + 1] = root.entries[i] end
    end
    root.entries = kept
end
