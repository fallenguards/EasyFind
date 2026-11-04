-- The character pages (2026-11-04: a player asked for a simple way to see
-- the bank and an alt's items): what each character holds in slot
-- order, the profile kept per character, @alts and @Name with their tags,
-- the Character info rows, and the classic clients' bank, never read
-- before (C_Bank's tabs are retail's and Forever's).
local H = require("Harness")

local function Source(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local MAIN = Source("Database/Main.lua")
local BANK_VER = tonumber(MAIN:match("ns%.BANK_CACHE_VER = (%d+)"))
local BAG_VER = tonumber(MAIN:match("ns%.BAG_CACHE_VER = (%d+)"))

local function fakeWidget()
    local w = {}
    setmetatable(w, { __index = function() return function() return w end end })
    return w
end

-- The stored-item helpers in Database/Main.lua between two markers, run
-- against env.
local function LoadStored(env, ns, from, to)
    local s = assert(MAIN:find(from, 1, true), from)
    local e = assert(MAIN:find(to, s, true), to)
    local chunkEnv = setmetatable({ Stored = ns.Stored, ns = ns, Utils = ns.Utils }, { __index = env })
    assert(load(MAIN:sub(s, e - 1), "=Main.lua " .. from, "t", chunkEnv))()
end

local function World(opts)
    opts = opts or {}
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.CreateFont = fakeWidget
    env.CreateFrame = fakeWidget
    env.CreateColor = function(r, g, b, a) return { GetRGBA = function() return r, g, b, a end } end
    env.UIParent = fakeWidget()
    env.WorldFrame = fakeWidget()
    env.GameTooltip = fakeWidget()
    env.hooksecurefunc = function() end
    env.GameFontNormal = setmetatable({}, { __index = function(_, k)
        if k == "GetFont" then return function() return "font", 12, "" end end
        return function() end
    end })
    H.loadModule("Shared/Utils.lua", env, ns)
    H.loadModule("Shared/SearchText.lua", env, ns)
    -- Frames that keep their handlers, so the watcher's events can be sent.
    local frames = {}
    env.CreateFrame = function()
        local f = H.newFrame()
        frames[#frames + 1] = f
        return f
    end
    env.GetUnitName = function() return "Thrall" end
    env.UnitName = function() return "Thrall" end
    env.GetRealmName = function() return "Realm" end
    env.UnitClass = function() return "Warrior", "WARRIOR" end
    env.UnitLevel = function() return 60 end
    env.GetMoney = function() return opts.money or 100 end
    env.GetRealZoneText = function() return "Orgrimmar" end
    env.GetSubZoneText = function() return "" end
    env.GetInventoryItemLink = function(_, slot) return (opts.gear or {})[slot] end
    env.EasyFindDB = opts.db or {}
    env.EasyFind.db = env.EasyFindDB
    ns.Stored = {}
    ns.BANK_CACHE_VER, ns.BAG_CACHE_VER = BANK_VER, BAG_VER
    LoadStored(env, ns, "function Stored.ItemIcon(itemID)", "Stored.BAG_STORED_KEYWORDS")
    H.loadModule("Database/Characters.lua", env, ns)
    return env, ns, frames
end

local function Pack(ns, rows, spec)
    return ns.Utils.PackRows(rows, spec or ns.Stored.STORED_ITEM_ROW_SPEC)
end

-- A layout from slots naming their item, in the shape Stored.Layout keeps:
-- each slot points at its item's row in the record.
local function Layout(ns, items, slots, sizes, names)
    local rowOf = {}
    for i, item in ipairs(items) do rowOf[item.itemID] = i end
    local rows = {}
    for i, s in ipairs(slots) do rows[i] = { tab = s.tab, slot = s.slot, row = rowOf[s.itemID], count = s.count } end
    return ns.Stored.Layout(rows, sizes, names)
end

-- An alt's bag record in the shape PersistBagContents writes.
local function BagRecord(ns, name, items, slots, sizes, names)
    return {
        name = name, realm = "Realm", class = "MAGE", scannedAt = 1,
        packed = Pack(ns, items),
        layout = Layout(ns, items, slots, sizes, names),
    }
end

local tests = {}

-- ==== folded text ===========================================================

function tests.fold_accentsAndCaseGo()
    local _, ns = World()
    local Fold = ns.CharacterData.Fold
    H.assertEq(Fold("Thrâll"), "thrall")
    H.assertEq(Fold("ÆLFRÏC"), "aelfric")
    H.assertEq(Fold("Łukasz"), "lukasz")
    H.assertEq(Fold("Ёжик"), Fold("ёжик"), "Cyrillic either case")
    H.assertEq(Fold("어둠"), "어둠", "Hangul as it is")
end

function tests.words_pluralAndSkippedWords()
    local _, ns = World()
    local Data = ns.CharacterData
    local words = Data.Words("Potions bank", {})
    H.assertTrue(Data.MatchesAll(Data.Fold("Major Healing Potion"), words, { [2] = true }), "potions finds a Potion")
    H.assertFalse(Data.MatchesAll(Data.Fold("Major Healing Potion"), words), "bank is a word to find unless skipped")
end

-- ==== items in slot order ===================================================

function tests.sections_eachBagsItemsInTheOrderTheySit_noEmptySlots()
    local db = { bagCacheVer = BAG_VER, bagCache = { chars = {} } }
    local _, ns = World({ db = db })
    db.bagCache.chars["Jaina-Realm"] = BagRecord(ns, "Jaina",
        { { itemID = 10, count = 3, name = "Linen Cloth" }, { itemID = 20, count = 1, name = "Hearthstone" },
          { itemID = 30, count = 1, name = "Silk Cloth" } },
        { { tab = 1, slot = 3, itemID = 10, count = 3 }, { tab = 0, slot = 1, itemID = 20, count = 1 },
          { tab = 1, slot = 1, itemID = 30, count = 1 } },
        { [0] = 2, [1] = 3, [2] = 4 }, { [0] = "Backpack", [1] = "Linen Bag", [2] = "Empty Bag" })
    local sections = ns.CharacterData.Sections("Jaina-Realm", "items")
    H.assertEq(#sections, 2, "a section per bag with something in it")
    H.assertEq(sections[1].header, "Backpack")
    H.assertEq(#sections[1].cells, 1, "no empty slots")
    H.assertEq(sections[1].cells[1].name, "Hearthstone")
    H.assertEq(sections[2].header, "Linen Bag")
    H.assertEq(sections[2].cells[1].name, "Silk Cloth", "slot 1 before slot 3")
    H.assertEq(sections[2].cells[2].count, 3)
    H.assertEq(sections[2].cells[2].place, "bags")
end

function tests.sections_aRecordFromBeforeSlots_listsItsItemsOnce()
    local db = { bankCacheVer = BANK_VER, bankCache = { chars = {} } }
    local _, ns = World({ db = db })
    db.bankCache.chars["Jaina-Realm"] = { name = "Jaina", realm = "Realm", packed = Pack(ns, {
        { itemID = 30, count = 20, tab = -1, slot = 4, name = "Silk Cloth" } }) }
    local sections = ns.CharacterData.Sections("Jaina-Realm", "items")
    H.assertEq(#sections, 1)
    H.assertEq(sections[1].place, "bank")
    H.assertEq(sections[1].cells[1].name, "Silk Cloth")
    H.assertEq(sections[1].cells[1].count, 20)
end

function tests.everyCharacter_aHeaderEach_itemsOnly_thenTheWarband()
    local db = { bagCacheVer = BAG_VER, bagCache = { chars = {} }, bankCacheVer = BANK_VER, bankCache = { chars = {} } }
    local _, ns = World({ db = db })
    db.bagCache.chars["Jaina-Realm"] = BagRecord(ns, "Jaina", { { itemID = 10, count = 1, name = "Linen Cloth" } },
        { { tab = 0, slot = 3, itemID = 10, count = 1 } }, { [0] = 16 }, { [0] = "Backpack" })
    local wool = { { itemID = 40, count = 5, name = "Wool Cloth" } }
    db.bankCache.account = { packed = Pack(ns, wool),
        layout = Layout(ns, wool, { { tab = 12, slot = 1, itemID = 40, count = 5 } }, { [12] = 98 }, { [12] = "Tab 1" }) }
    local sections = ns.CharacterData.Sections(nil, "items")
    local jaina
    for _, s in ipairs(sections) do if s.header == "Jaina" then jaina = s end end
    H.assertNotNil(jaina, "Jaina's section")
    H.assertEq(#jaina.cells, 1, "no empty slots across characters")
    H.assertEq(jaina.charKey, "Jaina-Realm")
    local last = sections[#sections]
    H.assertEq(last.place, "warband")
    H.assertEq(last.cells[1].count, 5)
end

function tests.gear_inSlotOrder_fromTheLinks()
    local gear = { [1] = "|cff0070dd|Hitem:111::|h[Helm]|h|r", [5] = "|cffa335ee|Hitem:555::|h[Chest]|h|r" }
    local _, ns = World({ gear = gear })
    local sections = ns.CharacterData.Sections(ns.CurrentCharacterKey(), "gear")
    H.assertEq(#sections[1].cells, 2)
    H.assertEq(sections[1].cells[1].itemID, 111)
    H.assertEq(sections[1].cells[1].name, "Helm")
    H.assertEq(sections[1].cells[2].link, gear[5])
end

-- ==== the profile ===========================================================

function tests.snapshot_recordsTheCharacter()
    local _, ns = World({ money = 4321 })
    ns.CharacterData.Snapshot()
    local p = ns.CharacterData.Get("Thrall-Realm")
    H.assertEq(p.level, 60)
    H.assertEq(p.zone, "Orgrimmar")
    H.assertEq(p.money, 4321)
    H.assertEq(p.class, "WARRIOR")
    H.assertTrue(p.isCurrent)
end

function tests.playedTime_countsOnWhileOnline_neverOffline()
    local env, ns = World()
    local Data = ns.CharacterData
    Data.Snapshot()
    env._clock.now = 5
    Data.RecordPlayed(1000)
    env._clock.now = 105
    Data.Snapshot()
    local p = env.EasyFindDB.charProfileCache["Thrall-Realm"]
    H.assertEq(p.played, 1100, "100 s online after the reading")
    -- The next session, a day later: the time offline is not played.
    local env2, ns2 = World({ db = env.EasyFindDB })
    env2._clock.now = 86400
    ns2.CharacterData.Snapshot()
    H.assertEq(p.played, 1100, "a login adds nothing")
    env2._clock.now = 86450
    ns2.CharacterData.Snapshot()
    H.assertEq(p.played, 1150)
end

function tests.playedAsked_quietly_onlyTheGameChatWindowsStopHearingIt()
    local env, ns, frames = World()
    local unregistered, registered, asked = {}, {}, 0
    local function ChatWindow(name)
        return { GetName = function() return name end,
                 UnregisterEvent = function(_, e) unregistered[name] = e end,
                 RegisterEvent = function(_, e) registered[name] = e end }
    end
    local windows = { ChatFrame1 = ChatWindow("ChatFrame1"), ChatFrame3 = ChatWindow("ChatFrame3"),
                      Other = ChatWindow("SomeAddonFrame") }
    env.GetFramesRegisteredForEvent = function() return windows.ChatFrame1, windows.Other, windows.ChatFrame3 end
    env.RequestTimePlayed = function() asked = asked + 1 end
    ns.CharacterData.AskPlayedQuietly()
    H.assertEq(asked, 1)
    H.assertEq(unregistered.ChatFrame1, "TIME_PLAYED_MSG")
    H.assertEq(unregistered.ChatFrame3, "TIME_PLAYED_MSG")
    H.assertNil(unregistered.SomeAddonFrame, "another addon's frame keeps hearing it")
    -- The answer arrives: recorded, and the windows hear again a frame on.
    local watcher
    for _, f in ipairs(frames) do if f._handlers.OnEvent then watcher = f end end
    watcher._handlers.OnEvent(watcher, "TIME_PLAYED_MSG", 3600, 60)
    env._clock:advance(0.1)
    H.assertEq(registered.ChatFrame1, "TIME_PLAYED_MSG")
    H.assertEq(registered.ChatFrame3, "TIME_PLAYED_MSG")
    H.assertEq(env.EasyFindDB.charProfileCache["Thrall-Realm"].played, 3600)
end

function tests.list_theLoggedInOneFirst_thenTheLastPlayed()
    local db = { charProfileCache = {
        ["Jaina-Realm"] = { name = "Jaina", realm = "Realm", class = "MAGE", seenAt = 50 },
        ["Bob-Realm"] = { name = "Bob", realm = "Realm", class = "ROGUE", seenAt = 90 },
    }, charProfileCacheVer = 1 }
    local _, ns = World({ db = db })
    local list = ns.CharacterData.List()
    H.assertEq(list[1].name, "Thrall")
    H.assertEq(list[2].name, "Bob")
    H.assertEq(list[3].name, "Jaina")
end

function tests.gold_fromTheLedger_beforeAProfile()
    local db = { charGold = { ["Jaina-ArgentDawn"] = 777 }, bagCacheVer = BAG_VER,
                 bagCache = { chars = { ["Jaina-Argent Dawn"] = { name = "Jaina", realm = "Argent Dawn" } } } }
    local _, ns = World({ db = db })
    H.assertEq(ns.CharacterData.Get("Jaina-Argent Dawn").money, 777)
end

-- ==== the classic bank ======================================================

function tests.classicBank_theMainSlotsThenEachBankBag()
    local env, ns = World()
    env.C_Bank = nil
    env.BANK_CONTAINER, env.NUM_BAG_SLOTS, env.NUM_BANKBAGSLOTS = -1, 4, 2
    env.GetBagName = function(bag) return "Bag " .. bag end
    local contents = { [-1] = { [1] = { itemID = 7, stackCount = 2, hyperlink = "|Hitem:7|h[Rune]|h" } },
                       [5] = { [3] = { itemID = 7, stackCount = 1 } }, [6] = {} }
    env.C_Container = {
        GetContainerNumSlots = function(bag) return bag == -1 and 28 or (bag == 5 and 4 or 0) end,
        GetContainerItemInfo = function(bag, slot) return contents[bag] and contents[bag][slot] end,
    }
    LoadStored(env, ns, "function Stored.CollectBankTabs", "function Stored.BankCacheStore")
    local tabs = ns.Stored.GetCharacterBankTabs()
    H.assertEq(#tabs, 3, "the bank, then bank bags 5 and 6")
    H.assertEq(tabs[1].id, -1)
    H.assertEq(tabs[2].id, 5)
    H.assertEq(tabs[3].name, "Bag 6")
    local rows, names, seen, layout = ns.Stored.WalkBankTabs(tabs)
    H.assertEq(seen, 32)
    H.assertEq(#rows, 1, "one row per item")
    H.assertEq(rows[1].count, 3)
    H.assertEq(names[-1], "Bank")
    H.assertEq(layout.sizes[-1], 28)
    H.assertEq(layout.sizes[5], 4)
    H.assertNil(layout.sizes[6], "an empty bag slot holds no bag")
    H.assertEq(layout.slots[-1], "1*2", "the bank's first slot: row 1, two of it")
    H.assertEq(layout.slots[5], ",,1", "bag 5's third slot: row 1 once")
    H.assertNil(layout.slots[6])
end

function tests.layout_aSlotIsAFewPlainBytes()
    local _, ns = World()
    local slots = {}
    for slot = 1, 98 do slots[slot] = { tab = 6, slot = slot, row = slot, count = 200 } end
    local layout = ns.Stored.Layout(slots, { [6] = 98 }, {})
    H.assertTrue(#layout.slots[6] < 98 * 8, "a full tab of stacks: " .. #layout.slots[6] .. " bytes")
    H.assertNil(layout.slots[6]:find("[%c\\\"]"), "nothing a saved file escapes")
end

function tests.tabbedBank_staysOnTheTabs()
    local env, ns = World()
    env.Enum = { BankType = { Character = 0, Account = 2 } }
    env.BANK_CONTAINER = -1
    env.C_Bank = { FetchPurchasedBankTabData = function() return { { ID = 6, name = "Tab A" } } end }
    LoadStored(env, ns, "function Stored.CollectBankTabs", "function Stored.BankCacheStore")
    local tabs = ns.Stored.GetCharacterBankTabs()
    H.assertEq(#tabs, 1)
    H.assertEq(tabs[1].id, 6)
end

function tests.bagWalk_keepsEachSlotsCount_andEachBagsSize()
    local env, ns = World()
    env.C_Container = {
        GetContainerNumSlots = function(bag) return bag == 0 and 4 or 0 end,
        GetContainerItemInfo = function(_, slot)
            if slot == 1 then return { itemID = 9, stackCount = 5, iconFileID = 1 } end
            if slot == 4 then return { itemID = 9, stackCount = 2, iconFileID = 1 } end
        end,
    }
    LoadStored(env, ns, "function ns.MaxCarriedBagIndex()", "-- Spec switching and saved talent loadouts")
    local map, order, seen, sizes = ns.Stored.WalkPlayerBags()
    H.assertEq(seen, 4)
    H.assertEq(sizes[0], 4)
    H.assertEq(order[1], 9)
    H.assertEq(map[9].totalCount, 7)
    H.assertEq(map[9].locations[2].slot, 4)
    H.assertEq(map[9].locations[2].count, 2)
end

-- ==== tags and pages ========================================================

local function Pages(db)
    local env, ns = World({ db = db })
    ns.Filters.GetUIBucket = function() return nil end
    ns.Search.GetSelectedIndex = function() return 0 end
    ns.Search.GetSearchFrame = function() return nil end
    ns.Filters.ShowHierarchicalResults = function() end
    ns.Filters.HideResults = function() end
    ns.Filters.OnSearchTextChanged = function() end
    ns.Filters.IsGuildAchievementData = function() return false end
    H.loadModule("Search/Filters/QuickFilter.lua", env, ns)
    ns.Answers = { CoinText = function(n) return n .. "c" end, PlainCoinText = function(n) return n .. "c" end }
    ns.Database.uiSearchData = {}
    ns.Database.RemoveEntriesByCategory = function(category)
        local data = ns.Database.uiSearchData
        for i = #data, 1, -1 do if data[i].category == category then table.remove(data, i) end end
    end
    ns.Stored.EmitStoredRow = function(entry, category)
        return { name = entry.row.name, category = category, storedHolders = entry.holders, storedCount = entry.total }
    end
    local shown = {}
    ns.Results.ShowHierarchicalResults = function(_, entries)
        for i = #shown, 1, -1 do shown[i] = nil end
        for i, e in ipairs(entries) do shown[i] = { name = e.name, data = e.data } end
    end
    env.SecondsToTime = function(s) return s .. "s" end
    H.loadModule("Search/Characters.lua", env, ns)
    return env, ns, shown
end

local function TwoJainas()
    return { charProfileCacheVer = 1, charProfileCache = {
        ["Jaina-Realm"] = { name = "Jaina", realm = "Realm", class = "MAGE", seenAt = 50, played = 7200, money = 50,
                            profs = { { name = "Tailoring", rank = 300, max = 300 } } },
        ["Jaina-Other"] = { name = "Jaina", realm = "Other", class = "MAGE", seenAt = 40 },
        ["Bôb-Realm"] = { name = "Bôb", realm = "Realm", class = "ROGUE", seenAt = 90, money = 25,
                          profs = { { name = "Tailoring", rank = 150, max = 300 } } },
    } }
end

function tests.tags_aSharedNameAnswersWithItsRealm()
    local _, ns = Pages(TwoJainas())
    local C = ns.Characters
    H.assertNil(C:ResolveToken("jaina", true), "two Jainas: the name alone is nobody")
    H.assertEq(C:ResolveToken("jaina-other", true).charKey, "Jaina-Other")
    H.assertEq(C:ResolveToken("bob", true).charKey, "Bôb-Realm", "accents fold")
    H.assertEq(C:ResolveToken("bo", false).charKey, "Bôb-Realm", "the one it starts")
    H.assertNil(C:ResolveToken("bo", true))
    local token
    for _, def in ipairs(C:Defs()) do if def.charKey == "Jaina-Other" then token = def.token end end
    H.assertEq(token, "@Jaina-Other")
end

function tests.tags_aFixedWordBeatsACharacter_anExactNameBeatsAPrefix()
    local db = { charProfileCacheVer = 1, charProfileCache = {
        ["Bank-Realm"] = { name = "Bank", realm = "Realm", class = "MAGE" },
        ["Mac-Realm"] = { name = "Mac", realm = "Realm", class = "MAGE" },
    } }
    local _, ns = Pages(db)
    H.assertEq(ns.Filters:ResolveQuickFilterToken("bank").key, "bank", "@bank stays the bank")
    H.assertEq(ns.Filters:ResolveQuickFilterToken("mac").charKey, "Mac-Realm", "Mac over the start of macros")
    H.assertEq(ns.Filters:ResolveQuickFilterToken("ma").key, "macros", "a fixed alias")
    H.assertEq(ns.Filters:ResolveQuickFilterToken("alts").key, "alts")
end

function tests.suggestions_charactersJoinOnceALetterIsTyped()
    local _, ns = Pages(TwoJainas())
    local entries = ns.Filters:GetQuickFilterSuggestionEntries("")
    for _, e in ipairs(entries) do H.assertTrue(e.data.quickFilterDef.key ~= "character", "none on a bare @") end
    entries = ns.Filters:GetQuickFilterSuggestionEntries("jai")
    local n = 0
    for _, e in ipairs(entries) do if e.data.quickFilterDef.key == "character" then n = n + 1 end end
    H.assertEq(n, 2, "both Jainas")
end

function tests.altsPage_itsRows_theCharactersBehindOne()
    local _, ns, shown = Pages(TwoJainas())
    local alts = ns.Filters:ResolveQuickFilterToken("alts")
    ns.Characters:ShowView(alts, "")
    local names = {}
    for i, e in ipairs(shown) do names[i] = e.name end
    H.assertEq(names[1], "Items")
    H.assertEq(names[2], "FILTER_CHARACTERS")
    H.assertEq(names[3], "CHAR_PROFESSIONS")
    H.assertEq(shown[3].data.searchCommandDesc, "Tailoring", "the professions the account has")
    H.assertEq(shown[4].data.searchCommandDesc, "175c", "every character's gold, Thrall's 100 too")
    H.assertEq(names[5], "CHAR_PLAYED")
    H.assertEq(#shown, 5, "no character listed until asked")
    -- A name typed here finds the character.
    ns.Characters:ShowView(alts, "bôb")
    H.assertEq(#shown, 1)
    H.assertEq(shown[1].name, "Bôb")
end

function tests.altsPage_charactersAndProfessions_eachAPageOfTheirOwn()
    local _, ns, shown = Pages(TwoJainas())
    local alts = ns.Filters:ResolveQuickFilterToken("alts")
    ns.Characters:ShowView(alts, "")
    local chars, profs = shown[2].data.quickFilterDef, shown[3].data.quickFilterDef
    H.assertEq(chars.parentDef, alts)
    ns.Characters:ShowView(chars, "")
    H.assertEq(#shown, 4, "every character")
    H.assertEq(shown[1].name, "Thrall", "the logged-in one first")
    ns.Characters:ShowView(profs, "")
    H.assertEq(#shown, 2, "the two who have one")
    local byName = {}
    for _, e in ipairs(shown) do byName[e.name] = e.data.searchCommandDesc end
    H.assertEq(byName["Jaina"], "Tailoring 300")
    H.assertEq(byName["Bôb"], "Tailoring 150")
    H.assertEq(ns.Filters:PillText(profs), "@alts @professions")
end

function tests.anAtWordOnAPage_opensThePageUnderIt()
    local _, ns, shown = Pages(TwoJainas())
    local alts = ns.Filters:ResolveQuickFilterToken("alts")
    ns.Filters:ApplyQuickFilter(alts, "")
    ns.Characters:ShowView(alts, "@")
    H.assertEq(shown[1].name, "Items", "a bare @ lists what is under @alts")
    H.assertEq(#shown, 8, "Items, Characters, Professions, Money, four characters")
    ns.Characters:ShowView(alts, "@ite")
    H.assertEq(#shown, 1)
    H.assertEq(shown[1].data.searchCommandDesc, "@items")
    ns.Characters:ShowView(alts, "@items")
    H.assertEq(ns.Filters:GetQuickFilter().gridKind, "items", "the whole word opens it")
    H.assertEq(ns.Filters:PillText(ns.Filters:GetQuickFilter()), "@alts @items")
    ns.Characters:ShowView(alts, "@bob")
    local bob = ns.Filters:GetQuickFilter()
    H.assertEq(bob.charKey, "Bôb-Realm", "a character's name opens their page")
    ns.Characters:ShowView(bob, "@gear")
    H.assertEq(ns.Filters:PillText(ns.Filters:GetQuickFilter()), "@alts @Bôb @gear")
    ns.Characters:ShowView(alts, "@jaina")
    H.assertEq(#shown, 2, "two Jainas: both listed, neither opened")
end

-- The money row opens every character's gold, the richest first (2026-11-04).
function tests.altsMoney_opensEachCharactersGold()
    local _, ns, shown = Pages(TwoJainas())
    local alts = ns.Filters:ResolveQuickFilterToken("alts")
    ns.Characters:ShowView(alts, "")
    local money = shown[4].data
    H.assertEq(money.copyText, "175c", "Ctrl+C still copies the total")
    local page = money.quickFilterDef
    H.assertNotNil(page, "the row opens a page")
    H.assertEq(page.parentDef, alts)
    ns.Characters:ShowView(page, "")
    local rows = {}
    for i, e in ipairs(shown) do rows[i] = e.name .. " " .. e.data.searchCommandDesc end
    H.assertEq(table.concat(rows, ", "), "Thrall 100c, Jaina 50c, Bôb 25c", "richest first, none without gold on record")
    H.assertEq(shown[1].data.copyText, "100c")
    H.assertEq(ns.Filters:PillText(page), "@alts @money")
    ns.Filters:ApplyQuickFilter(alts, "")
    ns.Characters:ShowView(alts, "@money")
    H.assertEq(ns.Filters:GetQuickFilter(), page, "typed on @alts too")
end

function tests.aPagesTag_opensOnTheWholeWord_unlessALongerOneStartsSo()
    local db = TwoJainas()
    db.charProfileCache["Bôbby-Realm"] = { name = "Bôbby", realm = "Realm", class = "MAGE" }
    local _, ns = Pages(db)
    local text = ""
    local box = { GetText = function() return text end, GetCursorPosition = function() return #text end }
    text = "@alts"
    ns.Filters:HandleQuickFilterTextChanged(box)
    H.assertEq(ns.Filters:GetQuickFilter().key, "alts", "@alts opens at once")
    ns.Filters._quickFilter = nil
    text = "@bob"
    ns.Filters:HandleQuickFilterTextChanged(box)
    H.assertNil(ns.Filters:GetQuickFilter(), "Bôbby starts with it: waits")
    text = "@bobby"
    ns.Filters:HandleQuickFilterTextChanged(box)
    H.assertEq(ns.Filters:GetQuickFilter().charKey, "Bôbby-Realm")
end

function tests.characterPage_itsRows_andItsItemsFound()
    local db = TwoJainas()
    db.bagCacheVer, db.bagCache = BAG_VER, { chars = {} }
    local _, ns, shown = Pages(db)
    db.bagCache.chars["Jaina-Realm"] = BagRecord(ns, "Jaina",
        { { itemID = 10, count = 4, name = "Major Mana Potion" } },
        { { tab = 0, slot = 1, itemID = 10, count = 3 }, { tab = 0, slot = 2, itemID = 10, count = 1 } },
        { [0] = 16 }, { [0] = "Backpack" })
    local jaina = ns.Filters:ResolveQuickFilterToken("jaina-realm")
    ns.Characters:OnApply(jaina)
    ns.Characters:ShowView(jaina, "")
    H.assertEq(shown[1].name, "Items")
    H.assertEq(shown[1].data.quickFilterDef.gridKind, "items")
    H.assertEq(shown[2].data.quickFilterDef.gridKind, "gear")
    H.assertEq(shown[1].data.quickFilterDef.parentDef, jaina, "Backspace steps back to Jaina")
    H.assertEq(ns.Filters:PillText(shown[1].data.quickFilterDef), "@alts @Jaina-Realm @items", "the pill says the way back")
    H.assertEq(shown[3].data.searchCommandDesc, "Tailoring 300/300", "her professions in one row")
    ns.Characters:ShowView(jaina, "potions")
    local item = shown[#shown].data
    H.assertEq(item.name, "Major Mana Potion")
    H.assertEq(item.storedCount, 4, "both stacks, one row")
    H.assertEq(item.storedHolders[1].tabName, "Backpack")
end

function tests.characterInfo_aRowPerCharacterForEachFact()
    local _, ns = Pages(TwoJainas())
    ns.Database:PopulateDynamicCharPlayed()
    local rows = ns.Database.uiSearchData
    H.assertEq(#rows, 1, "only Jaina of Realm has a played time on record")
    H.assertEq(rows[1].category, "Character Played")
    H.assertEq(rows[1].quickFilterDef.charKey, "Jaina-Realm", "a click opens her page")
    H.assertEq(rows[1].factWords[1], "played", "it waits for its word")
    ns.Database:PopulateDynamicCharRows()
    local own
    for _, r in ipairs(rows) do if r.category == "Character" and r.name == "Bôb" then own = r end end
    H.assertNil(own.factWords, "the character's own row answers its name")
    ns.Database:PopulateDynamicCharGold()
    local gold = 0
    for _, r in ipairs(rows) do if r.category == "Character Gold" then gold = gold + 1 end end
    H.assertEq(gold, 3, "Thrall, Jaina, Bôb")
    ns.Database:PopulateDynamicCharPlayed()
    local played = 0
    for _, r in ipairs(rows) do if r.category == "Character Played" then played = played + 1 end end
    H.assertEq(played, 1, "a repopulate replaces its rows")
end

local pass, fail, failures = H.runSuite("Characters", tests)
return { pass = pass, fail = fail, failures = failures }
