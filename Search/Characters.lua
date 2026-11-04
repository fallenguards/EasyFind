local _, ns = ...

-- @alts and @Name: the account's characters as pages in the bar. @alts
-- holds the account's totals and a row per character, @Name the same rows
-- for one character; Items and Gear open the item grid
-- (Search/Results/ItemGrid.lua). Words typed on a page narrow its rows and
-- find the items behind it. The data is ns.CharacterData's.
local Characters = {}
ns.Characters = Characters

local Data = ns.CharacterData
local Utils = ns.Utils
local L = ns.L
local sformat, tconcat = Utils.sformat, Utils.tconcat
local pairs, ipairs = Utils.pairs, Utils.ipairs
local tsort = Utils.tsort
local mmax = Utils.mmax
local wipe = wipe

local CLASS_SHEET = "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES"
local GLYPH = {
    items = { atlas = ns.BAG_ICON_ATLAS, tex = ns.BAG_ICON_TEX or "Interface\\Buttons\\Button-Backpack-Up" },
    gear = { tex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest" },
    gold = { tex = "Interface\\Icons\\INV_Misc_Coin_01" },
    played = { tex = "Interface\\Icons\\INV_Misc_PocketWatch_01" },
    level = { tex = ns.STAT_CATEGORY_ICON_TEX, coords = ns.STAT_CATEGORY_ICON_COORDS },
    profession = { tex = "Interface\\Icons\\INV_Misc_Note_01" },
    portrait = { portrait = "player" },
}
GLYPH.money = GLYPH.gold
-- An item row's category by where it is.
local PLACE_CATEGORY = { bags = "Bag", bank = "Bank", warband = "Warband", gear = "Gear" }
local ITEM_KEYWORDS = {}

local classGlyphs = {}
local function ClassGlyph(class)
    local coords = class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if not coords then return GLYPH.level end
    local glyph = classGlyphs[class]
    if not glyph then
        glyph = { tex = CLASS_SHEET, coords = coords }
        classGlyphs[class] = glyph
    end
    return glyph
end

local function ClassHex(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if not c then return nil end
    return sformat("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
end

local function ClassName(entry)
    return entry.class and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[entry.class]
end

local function Glyph(entry)
    return entry.isCurrent and GLYPH.portrait or ClassGlyph(entry.class)
end

local function Coins(amount)
    return ns.Answers and ns.Answers.CoinText and ns.Answers.CoinText(amount) or tostring(amount)
end

local function PlainCoins(amount)
    return ns.Answers and ns.Answers.PlainCoinText and ns.Answers.PlainCoinText(amount) or tostring(amount)
end

local function Duration(seconds)
    if SecondsToTime then return SecondsToTime(mmax(60, seconds), true, false, 2) end
    return tostring(seconds)
end

local function Ago(seenAt)
    return sformat(L["CHAR_SEEN_AGO_FMT"], SecondsToTime and SecondsToTime(mmax(60, time() - (seenAt or 0)), true, false, 1) or "")
end

local function LevelText(level)
    return sformat(_G["UNIT_LEVEL_TEMPLATE"] or L["CHAR_LEVEL_FMT"], level)
end

-- "Level 60, Orgrimmar, 2 Days ago".
local function CharacterLine(entry)
    local parts = {}
    if entry.level then parts[#parts + 1] = LevelText(entry.level) end
    if entry.zone then parts[#parts + 1] = entry.zone end
    if entry.isCurrent then
        parts[#parts + 1] = L["CHAR_PLAYING_NOW"]
    elseif entry.seenAt then
        parts[#parts + 1] = Ago(entry.seenAt)
    end
    return tconcat(parts, ", ")
end

-- ==== the tags ==============================================================

local altsDef
local function AltsDef()
    if altsDef then return altsDef end
    for _, def in ipairs(ns.Filters.quickFilterOptions) do
        if def.key == "alts" then
            altsDef = def
            def.glyph = GLYPH.portrait
            break
        end
    end
    return altsDef
end

local function NoSpaces(s) return (s:gsub("%s+", "")) end

-- One tag per character: its name folded, name-realm beside it; a name two
-- characters share answers only with its realm.
local charDefs, defList, builtFrom = {}, {}, nil

local function Defs()
    local list = Data.List()
    if list == builtFrom then return defList end
    builtFrom = list
    wipe(defList)
    local counts = {}
    for _, entry in ipairs(list) do
        local canonical = NoSpaces(Data.Fold(entry.name))
        counts[canonical] = (counts[canonical] or 0) + 1
    end
    for i, entry in ipairs(list) do
        local def = charDefs[entry.key]
        if not def then
            def = { key = "character", charView = "char", charKey = entry.key, nestedParent = true,
                    fold = Data.Fold, categoryLookup = {}, bucketLookup = {} }
            charDefs[entry.key] = def
        end
        local canonical = NoSpaces(Data.Fold(entry.name))
        local shown = counts[canonical] > 1 and (entry.name .. "-" .. (entry.realm or "")) or entry.name
        def.canonical = canonical
        def.aliases = { canonical .. "-" .. NoSpaces(Data.Fold(entry.realm or "")) }
        def.unique = counts[canonical] == 1
        def.label = entry.name
        def.token = "@" .. shown
        def.displayToken = def.token
        def.completionTokens = { "@" .. NoSpaces(shown) }
        def.aliasText = CharacterLine(entry)
        def.glyph = Glyph(entry)
        def.order = 1000 + i
        def.parentDef = AltsDef()
        defList[#defList + 1] = def
    end
    return defList
end

function Characters:Defs()
    return Defs()
end

-- A typed tag (lower case, "@" off) to a character's: exactly its name or
-- name-realm, else (exactOnly unset) the one character it starts.
function Characters:ResolveToken(token, exactOnly)
    local folded = Data.Fold(token)
    if folded == "" then return nil end
    local found, count = nil, 0
    for _, def in ipairs(Defs()) do
        if (def.unique and def.canonical == folded) or def.aliases[1] == folded then return def end
        if not exactOnly and (def.canonical:find(folded, 1, true) == 1 or def.aliases[1]:find(folded, 1, true) == 1) then
            found, count = def, count + 1
        end
    end
    if count == 1 then return found end
    return nil
end

local pageDefs = {}

-- A page under another: Items or Gear of one character (charDef) or Items
-- of every one (nil) in the grid, and @alts' Characters, Professions and
-- Money.
-- words: what the page answers to typed as an @ word on the page above.
local PAGE_KIND = {
    items = { view = "grid", token = "@items", words = { "items", "item" } },
    gear = { view = "grid", token = "@gear", words = { "gear", "equipped" } },
    chars = { view = "chars", token = "@characters", words = { "characters", "chars" } },
    profs = { view = "profs", token = "@professions", words = { "professions", "profs" } },
    money = { view = "money", token = "@money", words = { "money", "gold" } },
}
local PAGE_TITLE = {
    items = function() return _G["ITEMS"] or "Items" end,
    gear = function() return L["CHAR_GEAR"] end,
    chars = function() return L["FILTER_CHARACTERS"] end,
    profs = function() return _G["TRADE_SKILLS"] or L["CHAR_PROFESSIONS"] end,
    money = function() return _G["MONEY"] or "Money" end,
}

local function PageDef(charDef, kind)
    local id = (charDef and charDef.charKey or "*") .. "|" .. kind
    local def = pageDefs[id]
    if not def then
        def = { key = "characterPage", charView = PAGE_KIND[kind].view, gridKind = kind,
                categoryLookup = {}, bucketLookup = {} }
        pageDefs[id] = def
    end
    def.charKey = charDef and charDef.charKey or nil
    def.parentDef = charDef or AltsDef()
    def.token = PAGE_KIND[kind].token
    def.displayToken = def.token
    def.pageWords = PAGE_KIND[kind].words
    def.label = PAGE_TITLE[kind]()
    def.glyph = GLYPH[kind]
    return def
end

local function DefOf(key)
    for _, def in ipairs(Defs()) do
        if def.charKey == key then return def end
    end
    return nil
end
Characters.DefOf = DefOf

-- A tag applied: what it shows is read fresh.
function Characters:OnApply()
    Data.Invalidate()
end

-- ==== the pages =============================================================

local function Row(name, subtext, glyph, extra)
    local data = {
        name = name, category = "Character", noPin = true, noLearn = true, noMenu = true,
        searchCommandDesc = subtext, glyph = glyph,
    }
    if extra then
        for k, v in pairs(extra) do data[k] = v end
    end
    data.folded = Data.Fold(name .. " " .. (subtext or ""))
    return data
end

local function CopyRow(name, subtext, glyph, copyText)
    return Row(name, subtext, glyph, { copyText = copyText })
end

local function ProfessionsLine(profs, withMax)
    local parts = {}
    for _, prof in ipairs(profs or {}) do
        if prof.name then
            local rank = prof.rank and (withMax and prof.max and sformat("%d/%d", prof.rank, prof.max) or tostring(prof.rank))
            parts[#parts + 1] = rank and (prof.name .. " " .. rank) or prof.name
        end
    end
    return #parts > 0 and tconcat(parts, ", ") or nil
end

local function CharacterRow(entry, subtext, extra)
    local data = Row(entry.name, subtext or CharacterLine(entry), Glyph(entry),
        { quickFilterDef = DefOf(entry.key), nameHex = ClassHex(entry.class) })
    if extra then
        for k, v in pairs(extra) do data[k] = v end
    end
    return data
end

local function AltsPage(list)
    local out = {}
    out[#out + 1] = Row(_G["ITEMS"] or "Items", L["CHAR_ITEMS_ALL"], GLYPH.items, { quickFilterDef = PageDef(nil, "items") })
    out[#out + 1] = Row(L["FILTER_CHARACTERS"], sformat(L["CHAR_COUNT_FMT"], #list), GLYPH.portrait,
        { quickFilterDef = PageDef(nil, "chars") })
    local profNames, seenProf = {}, {}
    local money, played, known = 0, 0, 0
    for _, entry in ipairs(list) do
        money = money + (entry.money or 0)
        if entry.played then
            played = played + entry.played
            known = known + 1
        end
        for _, prof in ipairs(entry.profs or {}) do
            if prof.name and not seenProf[prof.name] then
                seenProf[prof.name] = true
                profNames[#profNames + 1] = prof.name
            end
        end
    end
    if #profNames > 0 then
        tsort(profNames)
        out[#out + 1] = Row(_G["TRADE_SKILLS"] or L["CHAR_PROFESSIONS"], tconcat(profNames, ", "), GLYPH.profession,
            { quickFilterDef = PageDef(nil, "profs") })
    end
    out[#out + 1] = Row(_G["MONEY"] or "Money", Coins(money), GLYPH.gold,
        { quickFilterDef = PageDef(nil, "money"), copyText = PlainCoins(money) })
    if known > 0 then
        local text = Duration(played)
        if known < #list then text = sformat(L["CHAR_PLAYED_SOME_FMT"], text, known, #list) end
        out[#out + 1] = CopyRow(L["CHAR_PLAYED"], text, GLYPH.played, Duration(played))
    end
    -- The characters themselves answer words typed here.
    for _, entry in ipairs(list) do
        out[#out + 1] = CharacterRow(entry, nil, { typedOnly = true })
    end
    return out
end

local function CharactersPage(list)
    local out = {}
    for _, entry in ipairs(list) do out[#out + 1] = CharacterRow(entry) end
    return out
end

local function ProfessionsPage(list)
    local out = {}
    for _, entry in ipairs(list) do
        local line = ProfessionsLine(entry.profs)
        if line then out[#out + 1] = CharacterRow(entry, line) end
    end
    return out
end

-- Each character's gold, the richest first; one with none on record is left out.
local function MoneyLess(a, b) return a.money > b.money end
local function MoneyPage(list)
    local rich = {}
    for _, entry in ipairs(list) do
        if entry.money then rich[#rich + 1] = entry end
    end
    tsort(rich, MoneyLess)
    local out = {}
    for _, entry in ipairs(rich) do
        out[#out + 1] = CharacterRow(entry, Coins(entry.money), { copyText = PlainCoins(entry.money) })
    end
    return out
end

local function ItemsLine(key)
    local bags, bank = Data.ItemCounts(key)
    if bank then return sformat(L["CHAR_ITEMS_FMT"], bags or 0, bank) end
    return sformat(L["CHAR_ITEMS_NO_BANK_FMT"], bags or 0)
end

local function CharacterPage(def, entry)
    local out = {}
    out[#out + 1] = Row(_G["ITEMS"] or "Items", ItemsLine(entry.key), GLYPH.items, { quickFilterDef = PageDef(def, "items") })
    local gearLine = entry.ilvl and sformat("%s %d", _G["STAT_AVERAGE_ITEM_LEVEL"] or "Item Level", entry.ilvl) or nil
    out[#out + 1] = Row(L["CHAR_GEAR"], gearLine, GLYPH.gear, { quickFilterDef = PageDef(def, "gear") })
    local profs = ProfessionsLine(entry.profs, true)
    if profs then
        out[#out + 1] = CopyRow(_G["TRADE_SKILLS"] or L["CHAR_PROFESSIONS"], profs, GLYPH.profession, profs)
    end
    if entry.money then
        out[#out + 1] = CopyRow(_G["MONEY"] or "Money", Coins(entry.money), GLYPH.gold, PlainCoins(entry.money))
    end
    local played = entry.played and Duration(entry.played)
    out[#out + 1] = CopyRow(L["CHAR_PLAYED"], played or L["CHAR_PLAYED_UNKNOWN"], GLYPH.played, played)
    if entry.level then
        local className = ClassName(entry)
        local line = className and sformat("%d, %s", entry.level, className) or tostring(entry.level)
        out[#out + 1] = CopyRow(_G["LEVEL"] or "Level", line, GLYPH.level, tostring(entry.level))
    end
    -- When and where an alt was left; the character played now says nothing new.
    if not entry.isCurrent and entry.seenAt then
        local seen = Ago(entry.seenAt)
        local line = entry.zone and sformat("%s, %s", seen, entry.zone) or seen
        out[#out + 1] = CopyRow(L["CHAR_LAST_PLAYED"], line, GLYPH.played, line)
    end
    return out
end

-- ==== items found on a page =================================================

-- The items matching the words as stored-item rows, one per item and
-- place, naming who holds it and where.
local function ItemRows(key, words, out)
    local byID, order = {}, {}
    local function Take(section, holderName, holderClass, holderKey)
        for _, cell in pairs(section.cells) do
            if cell and Data.MatchesAll(cell.folded, words) then
                local id = cell.place .. ":" .. cell.itemID
                local entry = byID[id]
                if not entry then
                    entry = { row = { itemID = cell.itemID, name = cell.name, icon = cell.icon, quality = cell.quality },
                              total = 0, holders = {}, place = cell.place, holderAt = {} }
                    byID[id] = entry
                    order[#order + 1] = entry
                end
                entry.total = entry.total + cell.count
                local where = key and section.header or Data.PlaceLabel(cell.place)
                local hid = (holderKey or holderName) .. "|" .. (where or "")
                local holder = entry.holderAt[hid]
                if holder then
                    holder.count = holder.count + cell.count
                else
                    holder = { charKey = holderKey, name = holderName, class = holderClass, count = cell.count, tabName = where }
                    entry.holderAt[hid] = holder
                    entry.holders[#entry.holders + 1] = holder
                end
            end
        end
    end
    if key then
        local entry = Data.Get(key)
        local name, class = entry and entry.name or "?", entry and entry.class
        for _, section in ipairs(Data.Sections(key, "items")) do Take(section, name, class, key) end
        for _, section in ipairs(Data.Sections(key, "gear")) do Take(section, name, class, key) end
    else
        for _, section in ipairs(Data.Sections(nil, "items")) do
            Take(section, section.header, section.class, section.charKey)
        end
        for _, entry in ipairs(Data.List()) do
            for _, section in ipairs(Data.Sections(entry.key, "gear")) do Take(section, entry.name, entry.class, entry.key) end
        end
    end
    for _, entry in ipairs(order) do
        entry.holderAt = nil
        local category = PLACE_CATEGORY[entry.place] or "Bag"
        local data = ns.Stored.EmitStoredRow(entry, category, ITEM_KEYWORDS, true)
        out[#out + 1] = data
    end
end

-- ==== Character info rows ===================================================

-- One row per character for each fact, each fact its own switch under the
-- filter menu's Character info; a click opens that character's page.
-- asks: the words a fact waits for (Search/Query.lua); a name alone finds
-- the character's own row, the first here.
local FACTS = {
    { fn = "PopulateDynamicCharRows", category = "Character", words = {}, line = CharacterLine },
    { fn = "PopulateDynamicCharPlayed", category = "Character Played", words = { "played", "time played", "playtime" },
      asks = { "played", "playtime" }, label = function() return L["CHAR_PLAYED"] end,
      line = function(entry) return entry.played and (L["CHAR_PLAYED"] .. ": " .. Duration(entry.played)) end },
    { fn = "PopulateDynamicCharSeen", category = "Character Seen", words = { "last played", "last", "seen", "online" },
      asks = { "last", "seen", "online" }, label = function() return L["CHAR_LAST_PLAYED"] end,
      line = function(entry)
          local seen = entry.isCurrent and L["CHAR_PLAYING_NOW"] or (entry.seenAt and Ago(entry.seenAt))
          if not seen then return nil end
          if entry.zone then seen = seen .. ", " .. entry.zone end
          return L["CHAR_LAST_PLAYED"] .. ": " .. seen
      end },
    { fn = "PopulateDynamicCharGold", category = "Character Gold", words = { "gold", "money" }, asks = { "gold", "money" },
      label = function() return _G["MONEY"] end,
      line = function(entry) return entry.money and ((_G["MONEY"] or "Money") .. ": " .. Coins(entry.money)) end },
    { fn = "PopulateDynamicCharLevel", category = "Character Level", words = { "level", "lvl" }, asks = { "level", "lvl" },
      label = function() return _G["LEVEL"] end,
      line = function(entry)
          if not entry.level then return nil end
          local className = ClassName(entry)
          return className and (LevelText(entry.level) .. ", " .. className) or LevelText(entry.level)
      end },
}

-- A fact answers its label's words in the client's language too.
local function FactWords(fact)
    local words, asks = {}, nil
    for i = 1, #fact.words do words[i] = fact.words[i] end
    if fact.asks then
        asks = {}
        for i = 1, #fact.asks do asks[i] = fact.asks[i] end
        local label = fact.label and fact.label()
        for _, word in ipairs(label and ns.SearchText.NormalizeAndTokenize(label) or {}) do
            words[#words + 1] = word
            asks[#asks + 1] = word
        end
    end
    return words, asks
end

local function PopulateFact(fact)
    local Database = ns.Database
    local Normalize = ns.SearchText.Normalize
    Database.RemoveEntriesByCategory(fact.category)
    local rows = Database.uiSearchData
    local words, asks = FactWords(fact)
    for _, entry in ipairs(Data.List()) do
        local line = fact.line(entry)
        if line then
            local nameLower = Normalize(entry.name)
            local kw = { nameLower }
            for i = 1, #words do kw[#kw + 1] = words[i] end
            rows[#rows + 1] = {
                name = entry.name, nameLower = nameLower, nameHex = ClassHex(entry.class),
                category = fact.category, keywords = kw, keywordsLower = kw,
                searchCommandDesc = line, glyph = Glyph(entry), quickFilterDef = DefOf(entry.key), noPin = true,
                factWords = asks,
            }
        end
    end
    if Database.ResetSearchCache then Database:ResetSearchCache() end
    return true
end

for _, fact in ipairs(FACTS) do
    ns.Database[fact.fn] = function() return PopulateFact(fact) end
end

-- ==== the view ==============================================================

local entries = {}
local words = {}
local function NameLess(a, b) return (a.name or "") < (b.name or "") end
local page = { def = nil, list = nil, rows = nil }

local function SetEntry(n, data)
    local e = entries[n] or {}
    entries[n] = e
    e.name, e.depth, e.isPathNode, e.isMatch, e.isPinned, e.isFlat, e.data = data.name, 0, false, true, false, true, data
    return e
end

local function PageRows(def)
    local list = Data.List()
    if page.def == def and page.list == list then return page.rows end
    page.def, page.list = def, list
    if def.charView == "list" then
        page.rows = AltsPage(list)
    elseif def.charView == "chars" then
        page.rows = CharactersPage(list)
    elseif def.charView == "profs" then
        page.rows = ProfessionsPage(list)
    elseif def.charView == "money" then
        page.rows = MoneyPage(list)
    else
        local entry = Data.Get(def.charKey)
        page.rows = entry and CharacterPage(def, entry) or {}
    end
    return page.rows
end

-- The pages under a page, each by the words it answers to as an @ word
-- typed there ("@items" on @alts).
local function SubPages(def)
    local out = {}
    if def.charView == "list" then
        out[1], out[2], out[3], out[4] = PageDef(nil, "items"), PageDef(nil, "chars"), PageDef(nil, "profs"),
            PageDef(nil, "money")
        for _, charDef in ipairs(Defs()) do out[#out + 1] = charDef end
    elseif def.charView == "char" then
        out[1], out[2] = PageDef(def, "items"), PageDef(def, "gear")
    else
        for _, charDef in ipairs(Defs()) do out[#out + 1] = charDef end
    end
    return out
end

-- A character answers to its name, or with its realm when two share it.
local function SubWords(sub)
    if sub.pageWords then return sub.pageWords end
    return { sub.unique and sub.canonical or sub.aliases[1] }
end

-- An @ word typed on a page: the pages it starts, to pick; the whole word
-- of one, unless a longer word starts with it, opens that page.
local function ShowSubPages(def, tag)
    local folded = Data.Fold(tag)
    local subs = SubPages(def)
    local exact, longer = nil, false
    local n = 0
    for _, sub in ipairs(subs) do
        local starts = false
        for _, word in ipairs(SubWords(sub)) do
            if word:find(folded, 1, true) == 1 then
                starts = true
                if #word == #folded then exact = exact or sub else longer = true end
            end
        end
        if starts then
            local entry = sub.key == "character" and Data.Get(sub.charKey)
            n = n + 1
            SetEntry(n, Row(sub.label, sub.displayToken or sub.token, sub.glyph,
                { quickFilterDef = sub, nameHex = entry and ClassHex(entry.class) }))
        end
    end
    if exact and not longer then
        ns.Filters:ApplyQuickFilter(exact, "")
        return
    end
    if n == 0 then
        n = 1
        SetEntry(1, { name = _G["BROWSE_NO_RESULTS"] or L["CHAR_NO_MATCH"], category = "Character",
                      noPin = true, noLearn = true, noMenu = true, lookupRow = true })
    end
    for i = n + 1, #entries do entries[i] = nil end
    ns.Results:ShowHierarchicalResults(entries)
end

function Characters:ShowView(def, text)
    local Results = ns.Results
    if def.charView == "grid" then
        if Results.ShowItemGrid then Results:ShowItemGrid(def, text or "") end
        return
    end
    local tag = text and text:match("^%s*@(" .. ns.Filters.TAG_CHARS .. "*)$")
    if tag then
        ShowSubPages(def, tag)
        return
    end
    Data.Words(text or "", words)
    local n = 0
    for _, data in ipairs(PageRows(def)) do
        if (#words == 0 and not data.typedOnly) or (#words > 0 and Data.MatchesAll(data.folded, words)) then
            n = n + 1
            SetEntry(n, data)
        end
    end
    if #words > 0 and (def.charView == "list" or def.charView == "char") then
        local found = {}
        ItemRows(def.charView == "char" and def.charKey or nil, words, found)
        tsort(found, NameLess)
        for _, data in ipairs(found) do
            n = n + 1
            SetEntry(n, data)
        end
    end
    if n == 0 then
        local hint = _G["BROWSE_NO_RESULTS"] or L["CHAR_NO_MATCH"]
        n = 1
        SetEntry(1, { name = hint, category = "Character", noPin = true, noLearn = true, noMenu = true, lookupRow = true })
    end
    for i = n + 1, #entries do entries[i] = nil end
    Results:ShowHierarchicalResults(entries)
end

-- The @alts suggestion row wears the logged-in character's portrait.
AltsDef()
