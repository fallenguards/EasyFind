-- Prices on Notes' shopping lists (2026-11-03): extensions offer prices
-- (API.RegisterPriceSource) and auction searches (API.RegisterAuctionSearch);
-- a line shows the price of what is left to buy, the list its total; the
-- player picks the source and what shows on the total's menu.
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function Core()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    return env.EasyFind.API, ns, env
end

local tests = {}

function tests.choices_oneEachSource_namedForTheExtension()
    local API, ns = Core()
    API.RegisterPriceSource("tsm", { label = "TSM", price = function() end,
        sources = function() return { { key = "dbmarket", label = "Market Value" }, { key = "vendorsell", label = "Vendor Sell" } } end })
    API.RegisterPriceSource("auctionator", { label = "Auctionator", price = function() end, sources = { { key = "auction", label = "Auction" } } })
    local list = ns.PriceChoices()
    H.assertEq(#list, 3)
    H.assertEq(list[1].value, "auctionator:auction", "the extensions in order")
    H.assertEq(list[1].label, "Auctionator", "one kind: the extension's name alone")
    H.assertEq(list[2].label, "TSM: Market Value", "several: the name and the kind")
    H.assertEq(list[3].value, "tsm:vendorsell")
    H.assertFalse(pcall(API.RegisterPriceSource, "bad", { sources = {} }), "a price function is required")
    API.RegisterAuctionSearch("tsm", function() return true end)
    H.assertEq(type(ns.AuctionSearches.tsm), "function")
end

-- The price block of Lines.lua with its state: the picked source, the kept
-- prices, the menu.
local function Prices(choices, priceOf)
    local src = Read("Apps/Notes/Lines.lua")
    local s = assert(src:find("local prices = { cache = {} }", 1, true))
    local e = assert(src:find("local function Tail(layer, i)", s, true))
    local db, now, calls, shown, repaints = {}, 100, {}, nil, 0
    local ns = { PriceSources = {}, PriceChoices = function() return choices end, PRICE_ANY = "any",
                 ShowTogglePopup = function(_, _, defs) shown = defs end }
    for _, c in ipairs(choices) do
        ns.PriceSources[c.id] = { price = function(key, id) calls[#calls + 1] = key .. ":" .. id return priceOf(key, id) end }
    end
    local env = setmetatable({
        ns = ns, notesNS = {}, Lines = {}, L = setmetatable({}, { __index = function(_, k) return k end }),
        EasyFind = { db = db }, GetTime = function() return now end,
        C_Item = { GetItemInfo = function() return nil end },
        C_CurrencyInfo = { GetCoinTextureString = function(c) return c .. "c" end },
        W = { Each = function(fn) fn() end }, NotesUI = { QueueEasyNotesOverlayUpdate = function() repaints = repaints + 1 end },
        Frame = function() return nil end, geterrorhandler = function() return print end,
    }, { __index = _G })
    local fns = assert(load(src:sub(s, e - 1)
        .. "\nreturn { Picked = PickedPrice, Unit = UnitPrice, Switch = PriceSwitch, Source = TotalSource }",
        "=Lines prices", "t", env))()
    local t = { db = db, calls = calls, Lines = env.Lines, env = env }
    function t.Advance(dt) now = now + dt end
    function t.Shown() return shown end
    function t.Repaints() return repaints end
    function t.Asked(k)
        for _, c in ipairs(calls) do if c == k then return true end end
        return false
    end
    return fns, t
end

local CHOICES = {
    { value = "auctionator:auction", id = "auctionator", key = "auction", name = "Auctionator", label = "Auctionator" },
    { value = "tsm:dbmarket", id = "tsm", key = "dbmarket", name = "TSM", label = "TSM: Market Value" },
    { value = "tsm:vendorsell", id = "tsm", key = "vendorsell", name = "TSM", label = "TSM: Vendor Sell" },
}

-- Auctionator has Linen Cloth only, TSM's market both, its vendor price all.
local function Priced(key, id)
    if key == "auction" then return id == 2589 and 10 or nil end
    if key == "dbmarket" then return (id == 2589 and 12) or (id == 2770 and 20) or nil end
    return 1
end

function tests.noPick_eachItemsFirstExtensionWithAPrice()
    local P, t = Prices(CHOICES, Priced)
    H.assertNil(P.Picked(), "nothing picked")
    local copper, _, src = P.Unit(2589)
    H.assertEq(copper, 10)
    H.assertEq(src.label, "Auctionator", "the first extension's")
    copper, _, src = P.Unit(2770)
    H.assertEq(copper, 20, "Auctionator has none: TSM's")
    H.assertEq(src.label, "TSM: Market Value", "at TSM's main kind")
    H.assertNil(P.Unit(9999), "none at either main kind")
    H.assertFalse(t.Asked("vendorsell:9999"), "another kind is no fallback")
    H.assertEq(P.Source({ auctionator = true, tsm = true }), "Auctionator, TSM", "the total names both")
    H.assertEq(P.Source({ tsm = true }), "TSM")
    t.db.notesPriceSource = "gone:auction"
    H.assertNil(P.Picked(), "a pick no longer offered: none")
end

function tests.thePick_alone_pricesKeptAMinute()
    local P, t = Prices(CHOICES, Priced)
    P.Unit(2589)
    local asked = #t.calls
    P.Unit(2589)
    H.assertEq(#t.calls, asked, "kept, not asked again")
    P.Unit(9999)
    asked = #t.calls
    P.Unit(9999)
    H.assertEq(#t.calls, asked, "a missing price is kept too")
    t.Advance(61)
    P.Unit(2589)
    H.assertEq(#t.calls, asked + 1, "asked again after a minute")
    t.db.notesPriceSource = "tsm:dbmarket"
    t.Lines.PricesChanged()
    H.assertEq(P.Picked().value, "tsm:dbmarket", "the player's pick")
    H.assertEq((P.Unit(2589)), 12)
    H.assertNil(P.Unit(4306), "the pick has none: no other source")
    H.assertEq(P.Source({ auctionator = true }), "TSM: Market Value", "the total names the pick")
    t.db.notesPriceSource = "tsm:vendorsell"
    H.assertEq((P.Unit(9999)), 1, "any kind once picked")
    H.assertTrue(t.Repaints() > 0, "every window drawn again")
end

function tests.theTotalsMenu_theSourceAndWhatShows()
    local P, t = Prices(CHOICES, function() return 5 end)
    t.Lines.PriceMenu({})
    local defs = t.Shown()
    H.assertEq(defs[1].kind, "title")
    H.assertEq(defs[2].kind, "radio")
    H.assertEq(defs[2].label, "NOTES_PRICES_ANY", "the first with a price leads")
    H.assertEq(defs[3].label, "Auctionator")
    H.assertEq(defs[4].label, "TSM: Market Value")
    H.assertEq(defs[2].get(), "any", "ticked with nothing picked")
    defs[4].set(defs[4].value)
    H.assertEq(t.db.notesPriceSource, "tsm:dbmarket")
    H.assertEq(defs[2].get(), "tsm:dbmarket", "the pick ticked")
    defs[2].set(defs[2].value)
    H.assertNil(t.db.notesPriceSource, "back to none: nothing saved")
    H.assertEq(defs[6].kind, "separator")
    H.assertEq(defs[7].kind, "title")
    H.assertEq(defs[8].kind, "check")
    H.assertTrue(defs[8].get(), "line prices on by default")
    defs[8].set(false)
    H.assertEq(t.db.notesPriceLines, false)
    H.assertFalse(P.Switch("notesPriceLines"))
    defs[8].set(true)
    H.assertNil(t.db.notesPriceLines, "on is the default: nothing saved")
    H.assertTrue(defs[9].get(), "the total on by default")
end

-- What is left to buy: the count less what is had, one with no count,
-- none once done; nothing for a line with no item.
function tests.itemsLeft()
    local env = H.newEnv()
    env._G = env
    env.UnitName = function() return "Tester" end
    env.GetUnitName = function() return "Tester" end
    env.GetRealmName = function() return "Realm" end
    local bags = { [2589] = 3 }
    env.C_Item = { GetItemCount = function(id) return bags[id] or 0 end, GetItemNameByID = function(id) return "Item" .. id end }
    env.time = os.time
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    env.GetBuildInfo = function() return "12.0.5", "1", "", 120005 end
    H.loadModule("Shared/Caps.lua", env, ns)
    local notesNS = { Context = {} }
    assert(loadfile(H.ADDON_ROOT .. "/Apps/Notes/Checklist.lua", "t", env))("EasyFind_Notes", notesNS)
    local CK = notesNS.Checklist
    local note = { id = 1, body = "", decorations = {} }
    CK.Init(note).shopping = true
    local counted = CK.AppendLine(note, { link = "item", item = 2589, target = 5 })
    local one = CK.AppendLine(note, { item = 2770 })
    local words = CK.AppendLine(note, { text = "repair" })
    H.assertEq(CK.ItemsLeft(note, counted), 2, "5 wanted, 3 had")
    H.assertEq(CK.ItemsLeft(note, one), 1, "no count: one")
    H.assertNil(CK.ItemsLeft(note, words), "no item")
    CK.SetTicked(note, one, ns.CurrentCharacterKey and ns.CurrentCharacterKey() or "Tester-Realm", true)
    CK.SetTicked(note, one, "account", true)
    H.assertEq(CK.ItemsLeft(note, one), 0, "ticked: none")
    bags[2589] = 9
    H.assertEq(CK.ItemsLeft(note, counted), 0, "had them all")
end

-- The tail and the total row read the same pick; the house's own box
-- waits for an extension's search.
function tests.wiring()
    local src = Read("Apps/Notes/Lines.lua")
    H.assertTrue(src:find("local cost = unit and showPrices and MoneyText(unit * left)", 1, true) ~= nil, "a line: what is left")
    H.assertTrue(src:find("sum = sum + unit * left\n", 1, true) ~= nil, "the total: their sum")
    H.assertTrue(src:find('row:SetScript("OnClick", function(self) Lines.PriceMenu(self) end)', 1, true) ~= nil, "the total's menu")
    H.assertTrue(src:find("row.source:SetText(TotalSource(used))", 1, true) ~= nil, "the total names its sources")
    local opts = Read("Core/Extensions.lua")
    H.assertTrue(opts:find('{ { value = any, label = L["NOTES_PRICES_ANY"] } }', 1, true) ~= nil, "settings: the first with a price")
    H.assertTrue(opts:find("if v == any then EasyFind.db.notesPriceSource = nil", 1, true) ~= nil, "settings: none saved as nil")
    local s = assert(src:find("local function SearchAH(note, line)", 1, true))
    local body = src:sub(s, select(2, src:find("\nend\n", s, true)))
    local ext, own = body:find("ns.AuctionSearches", 1, true), body:find('_G["AuctionHouseFrame"]', 1, true)
    H.assertTrue(ext ~= nil and own ~= nil and ext < own, "an extension's search before the house's own box")
end

local pass, fail, failures = H.runSuite("NotesPrices", tests)
return { pass = pass, fail = fail, failures = failures }
