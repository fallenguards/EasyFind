-- The mailbox and the guild bank (2026-11-19): each recorded while open,
-- its items rows in the search and holders in the item counts; the mail
-- says how long it has left, and a guild bank fills tab by tab.
local H = require("Harness")

local function Source(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end
local MAIN = Source("Database/Main.lua")

local function fakeWidget()
    local w = {}
    setmetatable(w, { __index = function() return function() return w end end })
    return w
end

local function World()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env._G = env
    env.CreateFont, env.CreateFrame = fakeWidget, fakeWidget
    env.CreateColor = function(r, g, b, a) return { GetRGBA = function() return r, g, b, a end } end
    env.UIParent, env.WorldFrame, env.GameTooltip = fakeWidget(), fakeWidget(), fakeWidget()
    env.hooksecurefunc = function() end
    env.GameFontNormal = setmetatable({}, { __index = function(_, k)
        if k == "GetFont" then return function() return "font", 12, "" end end
        return function() end
    end })
    H.loadModule("Shared/Utils.lua", env, ns)
    env.time = function() return 1000000 end
    env.D_DAYS = "%d Days"
    env.GetRealmName = function() return "Realm" end
    env.UnitClass = function() return "Warrior", "WARRIOR" end
    ns.PlayerName = function() return "Thrall" end
    ns.CurrentCharacterKey = function() return "Thrall-Realm" end
    env.EasyFindDB = {}
    env.EasyFind.db = env.EasyFindDB
    -- The stored-item helpers and the counts, as Database/Main.lua has them.
    ns.Stored = {}
    ns.BANK_CACHE_VER, ns.BAG_CACHE_VER = 1, 1
    local function Load(from, to)
        local s = assert(MAIN:find(from, 1, true), from)
        local e = assert(MAIN:find(to, s, true), to)
        local chunkEnv = setmetatable({ Stored = ns.Stored, ns = ns, Utils = ns.Utils, slower = string.lower,
                                        GetItemInfo = function() return nil end }, { __index = env })
        assert(load(MAIN:sub(s, e - 1), "=Main.lua " .. from, "t", chunkEnv))()
    end
    Load("function Stored.ItemIcon(itemID)", "Stored.BAG_STORED_KEYWORDS")
    Load("function Stored.AbsorbStoredRows", "-- Which characters a storage scope admits")
    Load("-- What each character held of an item at its last scan", "-- Records what is in the bank while one is open")
    ns.Database.uiSearchData = {}
    ns.Database.RemoveEntriesByCategory = function(category)
        local data = ns.Database.uiSearchData
        for i = #data, 1, -1 do if data[i].category == category then table.remove(data, i) end end
    end
    local t = { frames = {}, dirty = {}, asked = {} }
    ns.Database.MarkDynamicCategoryDirty = function(_, key) t.dirty[#t.dirty + 1] = key end
    env.CreateFrame = function()
        local f = H.newFrame()
        t.frames[#t.frames + 1] = f
        return f
    end
    H.loadModule("Database/Stores.lua", env, ns)
    return env, ns, t
end

-- Three letters: two with Linen Cloth, one cash on delivery.
local function Inbox(env)
    local mails = {
        { money = 500, cod = 0, days = 29.5, items = { { "Linen Cloth", 2589, 1, 20, 1 } } },
        { money = 0, cod = 0, days = 3.2, items = { { "Linen Cloth", 2589, 1, 5, 1 }, { "Copper Bar", 2840, 2, 10, 1 } } },
        { money = 0, cod = 100, days = 1, items = { { "Thunderfury", 19019, 3, 1, 5 } } },
    }
    env.GetInboxNumItems = function() return #mails end
    env.GetInboxHeaderInfo = function(i)
        local m = mails[i]
        return nil, nil, "Sender", "Subject", m.money, m.cod, m.days, #m.items
    end
    env.GetInboxItem = function(i, slot)
        local item = mails[i].items[slot]
        if item then return item[1], item[2], item[3], item[4], item[5] end
    end
    return mails
end

local tests = {}

function tests.theInbox_anItemOnceWithAllOfIt_andItsFirstLettersTime()
    local env, ns = World()
    Inbox(env)
    H.assertTrue(ns.Stores.ScanMail())
    local mail = ns.Stores.Mail("Thrall-Realm")
    H.assertEq(#mail.items, 2, "cash on delivery is not his yet")
    H.assertEq(mail.items[1].name, "Linen Cloth")
    H.assertEq(mail.items[1].count, 25, "both letters' cloth")
    H.assertEq(mail.items[1].expires, 1000000 + math.floor(3.2 * 86400), "the letter that runs out first")
    H.assertEq(mail.money, 500)
    H.assertEq(ns.Stores.DaysLeft(mail.items[1].expires), "4 Days", "a started day counts")
    H.assertNil(ns.Stores.Mail("Jaina-Realm"), "never at a mailbox")
end

function tests.mailThatRanOut_isGone()
    local env, ns = World()
    Inbox(env)
    ns.Stores.ScanMail()
    env.time = function() return 1000000 + 10 * 86400 end
    local mail = ns.Stores.Mail("Thrall-Realm")
    H.assertEq(#mail.items, 1, "the three-day letter's bars are gone")
    H.assertEq(mail.items[1].count, 20, "and its five cloth; the other letter's twenty stay")
    H.assertEq(ns.Stores.DaysLeft(mail.items[1].expires), "20 Days")
end

function tests.mailRows_sayWhoHoldsHowManyForHowLong()
    local env, ns = World()
    Inbox(env)
    ns.Stores.ScanMail()
    ns.Database:PopulateDynamicMail()
    local rows = ns.Database.uiSearchData
    H.assertEq(#rows, 2)
    local cloth = rows[1].name == "Linen Cloth" and rows[1] or rows[2]
    H.assertEq(cloth.category, "Mail")
    H.assertEq(cloth.storedSubtext, "Mail: Thrall (25, 4 Days)")
    H.assertTrue(cloth.storedRemote, "a lookup row: nothing to click open")
end

function tests.theGuildBank_fillsTabByTab()
    local env, ns = World()
    local tabs = {
        [1] = { name = "Herbs", viewable = true, slots = { [1] = { 5, "|Hitem:765::|h[Silverleaf]|h" }, [2] = { 20, "|Hitem:765::|h[Silverleaf]|h" } } },
        [2] = { name = "Ore", viewable = true, slots = {} },
        [3] = { name = "Officers", viewable = false, slots = { [1] = { 1, "|Hitem:19019::|h[Thunderfury]|h" } } },
    }
    local shown = 1
    env.GetGuildInfo = function() return "Horde Heroes" end
    env.GetNumGuildBankTabs = function() return 3 end
    env.GetGuildBankTabInfo = function(tab) return tabs[tab].name, 1, tabs[tab].viewable end
    env.GetCurrentGuildBankTab = function() return shown end
    env.GetGuildBankItemInfo = function(tab, slot) local s = tabs[tab].slots[slot] if s then return 134, s[1] end end
    env.GetGuildBankItemLink = function(tab, slot) local s = tabs[tab].slots[slot] return s and s[2] end
    H.assertTrue(ns.Stores.ScanGuildBank())
    local record = env.EasyFindDB.guildBankCache.chars["guild:Horde Heroes-Realm"]
    H.assertEq(record.name, "Horde Heroes")
    H.assertNil(record.tabRows[2], "a tab not sent yet reads empty and is not recorded so")
    H.assertNil(record.tabRows[3], "a tab he may not view")
    -- The second tab arrives; the first is no longer the one sent.
    tabs[2].slots[1] = { 10, "|Hitem:2770::|h[Copper Ore]|h" }
    shown = 2
    ns.Stores.ScanGuildBank()
    ns.Database:PopulateDynamicGuildBank()
    local names = {}
    for _, row in ipairs(ns.Database.uiSearchData) do names[row.name] = row end
    H.assertEq(names.Silverleaf.storedCount, 25, "both stacks, kept from the first read")
    H.assertEq(names.Silverleaf.category, "Guild Bank")
    H.assertEq(names["Copper Ore"].storedHolders[1].name, "Horde Heroes", "held by the guild")
    H.assertEq(names["Copper Ore"].storedHolders[1].tabName, "Ore")
    -- The tab shown read empty: it is empty.
    tabs[2].slots[1] = nil
    ns.Stores.ScanGuildBank()
    ns.Database:PopulateDynamicGuildBank()
    H.assertEq(#ns.Database.uiSearchData, 1, "the ore was taken out")
end

function tests.mailAndGuildBank_countAmongAnItemsHolders()
    local env, ns = World()
    Inbox(env)
    ns.Stores.ScanMail()
    env.GetGuildInfo = function() return "Horde Heroes" end
    env.GetNumGuildBankTabs = function() return 1 end
    env.GetGuildBankTabInfo = function() return "All", 1, true end
    env.GetCurrentGuildBankTab = function() return 1 end
    env.GetGuildBankItemInfo = function(_, slot) if slot == 1 then return 134, 40 end end
    env.GetGuildBankItemLink = function(_, slot) return slot == 1 and "|Hitem:2589::|h[Linen Cloth]|h" or nil end
    ns.Stores.ScanGuildBank()
    local held = ns.StoredItemCounts(2589)
    H.assertEq(held["Thrall-Realm"].mail, 25)
    H.assertEq(held["guild:Horde Heroes-Realm"].guild, 40)
    H.assertEq(held["guild:Horde Heroes-Realm"].name, "Horde Heroes")
end

function tests.eachIsRead_aMomentAfterItsEvent_andTheGuildBanksTabsAreAskedFor()
    local env, ns, t = World()
    Inbox(env)
    local asked = {}
    env.QueryGuildBankTab = function(tab) asked[#asked + 1] = tab end
    env.GetNumGuildBankTabs = function() return 2 end
    env.GetGuildBankTabInfo = function(tab) return "Tab", 1, tab == 1 end
    local watcher = t.frames[#t.frames]
    watcher._handlers.OnEvent(watcher, "MAIL_INBOX_UPDATE")
    watcher._handlers.OnEvent(watcher, "MAIL_INBOX_UPDATE")
    H.assertNil(ns.Stores.Mail("Thrall-Realm"), "not inside the event")
    env._clock:advance(1)
    H.assertNotNil(ns.Stores.Mail("Thrall-Realm"))
    H.assertEq(t.dirty[1], "mail", "the rows are made again")
    watcher._handlers.OnEvent(watcher, "GUILDBANKFRAME_OPENED")
    H.assertEq(#asked, 1, "the tab he may view, once")
end

local pass, fail, failures = H.runSuite("Stores", tests)
return { pass = pass, fail = fail, failures = failures }
