-- Tests for Shared/ResultLinks.lua: which rows may be shared as an
-- EasyFind link, and the plain-text form that goes over chat.

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)
H.loadModule("Shared/SearchText.lua", env, ns)
H.loadModule("Shared/Aliases.lua", env, ns)
local ResultLinks = H.loadModule("Shared/ResultLinks.lua", env, ns)
H.assertNotNil(ResultLinks, "Shared/ResultLinks.lua must return its table")

-- Stand-in for Utils.GetResultLink: rows with a spell or item link in chat.
ns.GetResultLink = function(data)
    if data.spellID then return "|Hspell:" .. data.spellID .. "|h[spell]|h" end
    if data.itemID then return "|Hitem:" .. data.itemID .. "|h[item]|h" end
    return nil
end

local menuRow = { name = "Options", category = "Menu Bar", path = { "Game Menu" } }
local settingRow = { name = "Auto Loot", category = "Game Settings", path = { "Gameplay" } }
local ability = { name = "Swipe", category = "Ability", spellID = 213771 }
local catalogItem = { name = "Gladiator's Hacker", category = "Appearance", catalogItem = true, itemID = 1234 }
local bagItem = { name = "Hearthstone", category = "Bag", itemID = 6948 }

local tests = {}

function tests.aProviderLinkCarriesItsOwnKeyAndResolvesThroughIt()
    local provider = { key = "questie", category = "Quest",
        link = { key = function(row) return row.questId .. ":" .. (row.progress or "") end } }
    ns.Extensions = { ProviderOf = function(d) return d.category == "Quest" and provider or nil end }
    local quest = { name = "Cave Mushrooms", category = "Quest", questId = 1234, progress = "2/5,0/1" }
    H.assertEq(ResultLinks:BuildShareText(quest), "[EasyFind: Cave Mushrooms] {ef:questie:1234:2/5,0/1}",
        "the link carries the provider's key")
    local resolved = { name = "Cave Mushrooms", category = "Quest", questId = 1234, shared = "2/5,0/1" }
    ns.Aliases:RegisterKeyResolver("questie", function(full)
        if full == "questie:1234:2/5,0/1" then return resolved end
    end)
    H.assertEq(ns.Aliases:FindEntryByKey("questie:1234:2/5,0/1"), resolved, "resolved by the provider's prefix")
    H.assertEq(ns.Aliases:FindEntryByKey("my-ext:7"), nil, "a dashed prefix reaches the resolvers, none here")
    ns.Extensions = nil
end

function tests.rowsWithoutTheirOwnChatLinkAreShareable()
    H.assertTrue(ResultLinks:CanShare(menuRow), "menu row")
    H.assertTrue(ResultLinks:CanShare(settingRow), "setting row")
    H.assertEq(ResultLinks:BuildShareText(menuRow), "[EasyFind: Options] {ef:ui:Game Menu>Options}",
        "share text carries the marker and the key when the key is not the bare name")
end

function tests.catalogItemsAndBagRowsAreNotShareable()
    H.assertFalse(ResultLinks:CanShare(catalogItem), "a catalog item's EasyFind link adds nothing over its item link")
    H.assertFalse(ResultLinks:CanShare({ name = "Cowl", category = "Appearance", appearanceItemID = 77 }),
        "appearance rows are catalog items")
    H.assertFalse(ResultLinks:CanShare(bagItem), "bag rows are never shared")
    H.assertNil(ResultLinks:BuildSendRows(catalogItem), "no send rows for a catalog item")
end

function tests.rowsWithAnEasyFindActionKeepTheirLinkEvenWithAChatLink()
    H.assertTrue(ResultLinks:CanShare(ability), "a spell opens in the spellbook: worth an EasyFind link")
    H.assertTrue(ResultLinks:CanShare({ name = "Ebon Gryphon", category = "Mount", mountID = 5 }),
        "a mount opens in the journal")
    H.assertNotNil(ResultLinks:BuildShareText(ability), "share text for a spell")
end

-- A fresh env with the link module, its chat filter and SetItemRef hook.
local function LinkEnv()
    local e = H.newEnv()
    local n = H.newNs(e)
    e._G = e
    local hooks, filters = {}, {}
    e.hooksecurefunc = function(name, fn) hooks[name] = fn end
    e.ChatFrame_AddMessageEventFilter = function(_, fn) filters[#filters + 1] = fn end
    e.SetItemRef = function() end
    H.loadModule("Shared/SearchText.lua", e, n)
    H.loadModule("Shared/Aliases.lua", e, n)
    local RL = H.loadModule("Shared/ResultLinks.lua", e, n)
    n.LINK_COLOR = { 0, 1, 1 }
    return n, RL, hooks, filters, e
end

-- A stranger's link to a row that acts only on its owner's side does nothing.
function tests.aCraftedCommandLinkNeverRuns()
    local n, RL, hooks, filters = LinkEnv()
    local ran, macro = false, false
    n.Database.uiSearchData = {
        { name = "/resetchat", category = "Command", path = { n.L["SUBTEXT_SLASH_COMMANDS"] },
          nativeRun = function() ran = true end },
    }
    n.ResultHandlers.SelectResult = function(_, d) if d.nativeRun then d.nativeRun() end end
    n.Shortkeys = { CreateMacro = function() macro = true end }
    RL:Install()
    local key = "ui:" .. n.L["SUBTEXT_SLASH_COMMANDS"] .. ">/resetchat"
    local _, shown = filters[1](nil, nil, "[EasyFind: Free Mount] {ef:" .. key .. "}")
    hooks.SetItemRef(shown:match("|H(.-)|h"), shown, "LeftButton")
    H.assertFalse(ran, "a command row never runs from a link")
    RL:CreateMacro(key, "Free Mount")
    H.assertFalse(macro, "nor becomes a macro")
end

-- A marker arriving in chat only becomes a link: no warm, no provider load.
function tests.aMarkerArrivingStartsNoWork()
    local n, RL, _, filters = LinkEnv()
    local work = 0
    n.Database.LoadDeferredSyncProvidersStaggered = function() work = work + 1 end
    n.Shortkeys = { RequestProviderForRowKey = function() work = work + 1 end }
    RL:Install()
    filters[1](nil, nil, "[EasyFind: Talents] and [EasyFind: Swift Tiger] {ef:mount:999}")
    H.assertEq(work, 0, "arrival starts nothing")
end

-- The same click on a row that may travel still opens it.
function tests.aSharedMenuLinkStillOpens()
    local n, RL, hooks, filters = LinkEnv()
    local opened
    n.Database.uiSearchData = { { name = "Options", category = "Menu Bar", path = { "Game Menu" } } }
    n.ResultHandlers.SelectResult = function(_, d) opened = d end
    RL:Install()
    local _, shown = filters[1](nil, nil, "[EasyFind: Options] {ef:ui:Game Menu>Options}")
    hooks.SetItemRef(shown:match("|H(.-)|h"), shown, "LeftButton")
    H.assertEq(opened and opened.name, "Options")
end

-- A shared GPS route: plain text over chat, a link on arrival, and a click
-- that routes the reader to the same place.
function tests.routeLinkRoutesTheReaderThere()
    local n, RL, hooks, filters, e = LinkEnv()
    n.L.GPS_TO_FMT = "To %s"
    local went
    e.EasyFind.API.RegisterAction("gps", "navigate", function(dest) went = dest end)
    RL:Install()
    local text = RL:BuildRouteText({ name = "Booty Bay", mapID = 210, x = 0.4123, y = 0.7712 })
    H.assertEq(text, "[EasyFind: To Booty Bay] {ef:route:210:0.4123:0.7712:Booty Bay}")
    local _, shown = filters[1](nil, nil, text)
    local link = shown and shown:match("|H(.-)|h")
    H.assertTrue(link ~= nil, "the reader sees a link")
    hooks.SetItemRef(link, shown, "LeftButton")
    H.assertTrue(went ~= nil, "a click starts the GPS")
    H.assertEq(went.name, "Booty Bay")
    H.assertEq(went.mapID, 210)
    H.assertTrue(math.abs(went.x - 0.4123) < 1e-6 and math.abs(went.y - 0.7712) < 1e-6)
end

local pass, fail, failures = H.runSuite("ResultLinks", tests)
return { pass = pass, fail = fail, failures = failures }
