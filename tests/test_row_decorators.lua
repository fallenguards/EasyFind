-- Row decorators (Core/API.lua RegisterRowDecorator, MINOR 4): an
-- extension's mark on rows another provider owns. applies(row) picks the
-- rows; one decorator shows per slot; its menu rows land in the row's
-- menu wearing the extension's icon, grayed ones with their reason, folded
-- under one row only when asked or past four; the link is the item's.
local H = require("Harness")

local function Env()
    local env = H.newEnv()
    env.EasyFind = {}
    local ns = H.newNs(env)
    local API = env.EasyFind.API
    API.RegisterExtension({ id = "spoken", name = "Spoken", icon = "voice" })
    API.RegisterExtension({ id = "prices", name = "Prices", icon = "coin" })
    return env, ns, API
end

local function Convert(defs)
    local out = {}
    for _, d in ipairs(defs) do
        if d.kind == "separator" then out[#out + 1] = { isSeparator = true }
        else out[#out + 1] = { text = d.label, tooltip = d.tooltip, disabled = d.disabled == true or nil } end
    end
    return out
end

local tests = {}

function tests.appliesPicksTheRows_itemsByDefault()
    local _, ns, API = Env()
    API.RegisterRowDecorator({ id = "spoken", applies = function(row) return row.questId ~= nil end })
    API.RegisterRowDecorator({ id = "prices", slot = "price", categories = { "Bag" },
        text = function(row, link) return 1234, link == "item:7" and "good" or "warn" end })
    local E = ns.Extensions
    local spoken, prices = E.Decorators.list[1], E.Decorators.list[2]
    H.assertTrue(E.DecoratorTakes(spoken, { questId = 5 }))
    H.assertFalse(E.DecoratorTakes(spoken, { itemID = 5 }), "its applies said no")
    H.assertTrue(E.DecoratorTakes(prices, { itemID = 7, category = "Bag" }))
    H.assertFalse(E.DecoratorTakes(prices, { itemID = 7, category = "Loot" }), "outside its categories")
    H.assertFalse(E.DecoratorTakes(prices, { questId = 5 }), "no item, no price")
    local value, word = E.DecoratorText("price", { itemID = 7, category = "Bag" })
    H.assertEq(value, 1234)
    H.assertEq(word, "good", "the state word rides along")
    H.assertNil(E.DecoratorText("price", { questId = 5 }))
end

function tests.theLinkIsTheItems()
    local _, ns, API = Env()
    local E = ns.Extensions
    H.assertEq(E.DecoratorLink({ itemID = 7 }), "item:7")
    H.assertEq(E.DecoratorLink({ itemID = 7, bagItemLink = "|Hitem:7::|h[x]|h" }), "|Hitem:7::|h[x]|h", "the bag's own")
    H.assertNil(E.DecoratorLink({ questId = 5 }), "none without an item")
    H.assertTrue(API.RegisterRowDecorator ~= nil)
end

function tests.menuRowsLandInTheMenuWithTheIcon_grayedOnesKeepTheirReason()
    local _, ns, API = Env()
    API.RegisterRowDecorator({ id = "spoken", label = "Spoken",
        applies = function(row) return row.questId ~= nil end,
        menu = function(row, link)
            return {
                { kind = "action", label = "Play", disabled = true, tooltip = "No voice yet", onClick = function() end },
                { kind = "action", label = "Open in Compendium", onClick = function() end },
            }
        end })
    local rows = ns.Extensions.DecoratorMenuRows({ questId = 5 }, Convert)
    H.assertEq(#rows, 2, "straight in the menu, no submenu")
    H.assertEq(rows[1].text, "Play")
    H.assertTrue(rows[1].disabled == true, "grayed out")
    H.assertEq(rows[1].tooltip, "No voice yet", "with its reason")
    H.assertEq(rows[1].icon, "voice", "wearing the extension's icon")
    H.assertTrue(rows[1].chromeIcon == true)
    H.assertEq(rows[2].icon, "voice")
    H.assertNil(ns.Extensions.DecoratorMenuRows({ itemID = 9 }, Convert), "a row it does not take")
end

function tests.menuRowsFoldWhenAskedOrPastFour()
    local _, ns, API = Env()
    local many = {}
    for i = 1, 5 do many[i] = { kind = "action", label = "Line " .. i, onClick = function() end } end
    API.RegisterRowDecorator({ id = "spoken", label = "Spoken", applies = function() return true end,
        menu = function() return many end })
    local rows = ns.Extensions.DecoratorMenuRows({ questId = 5 }, Convert)
    H.assertEq(#rows, 1, "five fold under one row")
    H.assertEq(rows[1].text, "Spoken")
    H.assertEq(rows[1].icon, "voice")
    H.assertEq(#rows[1].submenu, 5)
    API.RegisterRowDecorator({ id = "prices", label = "Prices", submenu = true, applies = function() return true end,
        menu = function() return { { kind = "action", label = "One", onClick = function() end } } end })
    rows = ns.Extensions.DecoratorMenuRows({ questId = 5 }, Convert)
    H.assertEq(#rows, 2)
    H.assertEq(rows[2].text, "Prices", "asked for a submenu")
    H.assertEq(rows[2].submenu[1].text, "One")
end

function tests.oneDecoratorShowsPerSlot_unregisterPassesItOn()
    local _, ns, API = Env()
    API.RegisterRowDecorator({ id = "prices", slot = "price", text = function() return "1g" end })
    API.RegisterRowDecorator({ id = "spoken", slot = "price", text = function() return "2g" end })
    local E = ns.Extensions
    H.assertEq((E.DecoratorText("price", { itemID = 1 })), "1g", "the first registered shows")
    API.UnregisterRowDecorator("prices", "price")
    H.assertEq((E.DecoratorText("price", { itemID = 1 })), "2g", "then the next")
    API.UnregisterRowDecorator("spoken", "price")
    H.assertNil(E.DecoratorText("price", { itemID = 1 }))
    H.assertEq(#E.Decorators.list, 0)
end

function tests.subtextAndTooltipJoinTheRows()
    local _, ns, API = Env()
    API.RegisterRowDecorator({ id = "spoken", applies = function(row) return row.mapID ~= nil end,
        subtext = function() return "voiced" end,
        tooltip = function(_, _, tt) tt.lines[#tt.lines + 1] = "Lore by Spoken" end })
    local E = ns.Extensions
    H.assertEq(E.DecoratorSubtext({ mapID = 1 }), "voiced")
    H.assertNil(E.DecoratorSubtext({ itemID = 1 }))
    local tt = { lines = {} }
    H.assertTrue(E.DecorateTooltip({ mapID = 1 }, tt))
    H.assertEq(tt.lines[1], "Lore by Spoken")
    H.assertFalse(E.DecorateTooltip({ itemID = 1 }, tt))
end

-- The gestures where the client has no journal (MINOR 5): the first
-- decorator taking the row answers the gestures it wants and names their
-- words; one it declines is EasyFind's own.
function tests.selectAnswersTheGesturesItWants_hintNamesThem()
    local _, ns, API = Env()
    local got = {}
    API.RegisterRowDecorator({ id = "spoken", applies = function(row) return row.category == "Boss" end,
        select = function(row, _, gesture) got[#got + 1] = gesture return gesture == "click" end,
        hint = function() return "DungeonJournal" end })
    local E = ns.Extensions
    H.assertTrue(E.DecoratorSelect({ category = "Boss", encounterID = 1, name = "Hamhock" }, "click"))
    H.assertFalse(E.DecoratorSelect({ category = "Boss", encounterID = 1 }, "alt"), "declined: EasyFind's own way")
    H.assertEq(table.concat(got, " "), "click alt", "told the gesture each time")
    H.assertFalse(E.DecoratorSelect({ category = "Loot", itemID = 5 }, "click"), "a row it does not take")
    H.assertEq(E.DecoratorHint({ category = "Boss", encounterID = 1 }).click, "DungeonJournal", "a bare word is the click's")
    H.assertNil(E.DecoratorHint({ category = "Boss", encounterID = 1 }).alt, "the rest left to EasyFind's words")
    H.assertNil(E.DecoratorHint({ category = "Loot", itemID = 5 }))
    API.RegisterRowDecorator({ id = "spoken", applies = function(row) return row.category == "Boss" end,
        select = function() return true end, hint = function() return { click = "Journal", alt = "Loot list" } end })
    local words = E.DecoratorHint({ category = "Boss" })
    H.assertEq(words.click, "Journal")
    H.assertEq(words.alt, "Loot list")
    API.RegisterRowDecorator({ id = "spoken", applies = function(row) return row.category == "Boss" end, select = function() return true end })
    H.assertEq(next(E.DecoratorHint({ category = "Boss" })), nil, "select with no hint: an empty set, a decorator all the same")
    H.assertTrue(pcall(API.RegisterRowDecorator, { id = "prices", select = function() return true end }), "select alone is fine")
end

function tests.theJournalPathsAskIt()
    local function Read(path)
        local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
        local src = f:read("*a")
        f:close()
        return src
    end
    local sel = Read("Search/Results/Handlers/Selection.lua")
    local boss = assert(sel:find('if data.category == "Boss" and data.encounterID and not (ns.Caps and ns.Caps.journal) then', 1, true))
    H.assertTrue(sel:find('local gesture = (Handlers:IsSourceModifierHeld(data) and "alt") or (Handlers:IsSourceCtrlHeld(data) and "ctrl") or "click"\n        if not (ns.Extensions and ns.Extensions.DecoratorSelect(data, gesture)) then\n            EasyFind.API.ShowScope("loot", data.name)', boss, true) ~= nil,
        "a boss row's gesture asks the decorators before listing its loot")
    local loot = assert(sel:find("function Handlers:OpenLootSource(data, useFast)", 1, true))
    H.assertTrue(sel:find("if ns.Extensions and ns.Extensions.DecoratorSelect(data, held) then return end", loot, true) < sel:find("ns.FOREVER_INSTANCES", loot, true),
        "a loot row's journal gesture asks them before the directions, the gesture told")
    H.assertTrue(Read("Search/Results/Gestures.lua"):find("return words and words[gesture] or V.gps", 1, true) ~= nil, "the loot hint's word for the gesture")
    local hints = Read("Search/Results/ActionHints.lua")
    H.assertTrue(hints:find('local s = Hint(V.click, words.click or V.loot, "Alt", words.alt or V.loot)', 1, true) ~= nil,
        "the boss hint: the decorator's words, the loot for the gestures left out")
    H.assertTrue(hints:find("if not words then return HINTS.bossLoot end", 1, true) ~= nil, "no decorator: as before")
    H.assertTrue(Read("API/README.md"):find("| `select` |", 1, true) ~= nil, "documented")
end

-- An action that opens another window (closes) steps the bar aside after
-- it, as core's own GPS entry does; one without stays in the bar.
function tests.aClosingActionStepsTheBarAside()
    local function Read(path)
        local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
        local src = f:read("*a"):gsub("\r\n", "\n")
        f:close()
        return src
    end
    local src = Read("Search/Results/Rows/ResultContextMenu.lua")
    local s = assert(src:find('elseif d.kind == "action" and d.label then', 1, true))
    local body = src:sub(s, s + 600)
    H.assertTrue(body:find("ns.Extensions.Run(d.onClick)\n                        if d.closes and Handlers.FinishResultSelection then Handlers:FinishResultSelection() end", 1, true) ~= nil,
        "after the action, the bar steps aside when the row says closes")
    H.assertTrue(Read("API/README.md"):find("`closes = true`", 1, true) ~= nil, "documented")
end

function tests.aDecoratorNeedsItsExtension()
    local _, _, API = Env()
    local ok = pcall(API.RegisterRowDecorator, { id = "nobody", text = function() end })
    H.assertFalse(ok, "an unregistered extension is refused")
    ok = pcall(API.RegisterRowDecorator, { id = "spoken", applies = "yes" })
    H.assertFalse(ok, "a field of the wrong kind is refused")
end

function tests.theRowsPaintAndAskIt()
    local function Read(path)
        local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
        local src = f:read("*a")
        f:close()
        return src
    end
    H.assertTrue(Read("Search/Results/Render/Core.lua"):find("Render.DecorateRow(resultRow, entry, st)", 1, true) ~= nil)
    H.assertTrue(Read("Search/Results/Render/Layout.lua"):find("resultRow.decorText:IsShown()", 1, true) ~= nil, "the name ends at it")
    -- The price had the row's right edge: it sat under the GPS button and
    -- under the Alt hint (Era, 2026-11-01).
    local layout = Read("Search/Results/Render/Layout.lua")
    local gps = assert(layout:find("function Render.ApplyGPSButton", 1, true))
    H.assertTrue(layout:find('decor:SetPoint("RIGHT", edge, edgePoint, x - size - 6, 0)', gps, true) ~= nil, "left of the GPS button")
    H.assertTrue(layout:find("x - size - 4 - decorW", gps, true) ~= nil, "the name short of the price")
    local shortcuts = Read("Search/Results/Shortcuts.lua")
    H.assertTrue(shortcuts:find("ReplaceRightPointToShortcut(row, row.decorText)", 1, true) ~= nil, "shifted left of the Alt hint")
    H.assertTrue(shortcuts:find("RestoreRightPointFromShortcut(row, row.decorText, -8)", 1, true) ~= nil)
    H.assertTrue(Read("Search/Results/Rows/ResultContextMenu.lua"):find("DecoratorMenuRows(pinData", 1, true) ~= nil)
    H.assertTrue(Read("Shared/Utils.lua"):find("extra.decoratorRows", 1, true) ~= nil, "the menu lays them out")
    H.assertTrue(Read("Search/Results/Rows/Tooltips.lua"):find("DecorateTooltip(", 1, true) ~= nil)
    H.assertTrue(Read("API/README.md"):find("### RegisterRowDecorator(def)", 1, true) ~= nil, "documented")
end

-- A row core gives no tooltip (a creature) still shows a decorator's lines:
-- the hover asks first and opens one titled with the row's name.
function tests.tooltipDecorator_opensABareRowsTooltip()
    local _, ns, API = Env()
    API.RegisterRowDecorator({ id = "spoken", applies = function(row) return row.npcID ~= nil end,
        tooltip = function(row, link, tip) tip.lines[#tip.lines + 1] = "casts " .. row.npcID end })
    local E = ns.Extensions
    H.assertTrue(E.HasTooltipDecorator({ npcID = 1548 }))
    H.assertFalse(E.HasTooltipDecorator({ itemID = 7 }), "no decorator takes it")
    local tip = { lines = {} }
    H.assertTrue(E.DecorateTooltip({ npcID = 1548 }, tip))
    H.assertEq(tip.lines[1], "casts 1548")
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/Results/Rows/Tooltips.lua", "rb"))
    local src = f:read("*a")
    f:close()
    H.assertTrue(src:find("if not ns.Extensions.HasTooltipDecorator(self.data) then return end", 1, true) ~= nil,
        "a bare row opens its tooltip only for a decorator with lines")
    H.assertTrue(src:find('GameTooltip:SetText(self.data.name or "", 1, 1, 1)', 1, true) ~= nil, "titled with the row's name")
    f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/Search/Results.lua", "rb"))
    src = f:read("*a")
    f:close()
    H.assertTrue(src:find("d.npcID = r.npcID", 1, true) ~= nil, "a creature row in the bar carries its creature id")
end

-- A decorator's @scope (MINOR 6): its aliases make one quick filter keyed
-- by its id, a later registration of the id takes the scope over, and a
-- token already held leaves it without one.
function tests.aliasesMakeAScope_laterRegistrationTakesItOver()
    local _, ns, API = Env()
    local added = {}
    ns.Filters.AddQuickFilter = function(_, def)
        added[#added + 1] = def
        return def.canonical ~= "items"
    end
    API.RegisterRowDecorator({ id = "spoken", aliases = { "sp", "spoken" }, applies = function(row) return row.questId ~= nil end })
    H.assertEq(#added, 1)
    local scope = added[1]
    H.assertEq(scope.key, "spoken")
    H.assertEq(scope.canonical, "spoken")
    H.assertEq(scope.label, "Spoken", "the extension's name without a label")
    H.assertEq(scope.aliases[1], "sp")
    H.assertEq(scope.decorator, ns.Extensions.Decorators.list[1])
    H.assertEq(ns.Extensions.Decorators.scopes.spoken, scope)
    local again = { id = "spoken", label = "Voices", aliases = { "sp" }, applies = function() return true end }
    API.RegisterRowDecorator(again)
    H.assertEq(#added, 1, "one scope per id")
    H.assertEq(scope.decorator, again, "the scope follows the latest registration")
    H.assertTrue(ns.Extensions.DecoratorTakes(scope.decorator, { itemID = 1 }))
    API.RegisterExtension({ id = "items", name = "Items", icon = "i" })
    API.RegisterRowDecorator({ id = "items", aliases = { "it" }, applies = function() return true end })
    H.assertNil(ns.Extensions.Decorators.scopes.items, "a token a built-in holds: no scope")
end

-- An extension whose surface is its decorator's scope (RegisterExtension
-- scope = the decorator's id, no open): its tile puts the scope's pill in
-- the bar through ShowScope, reads as open while the pill is up, and
-- closes with it.
function tests.aDecoratorScopeLaunchesFromTheExtension()
    local env, ns, API = Env()
    ns.Filters.quickFilterOptions = {}
    ns.Filters.AddQuickFilter = function(_, def)
        local list = ns.Filters.quickFilterOptions
        list[#list + 1] = def
        return true
    end
    local applied, current, shown = nil, nil, false
    ns.Filters.ApplyQuickFilter = function(_, def, text)
        applied, current, shown = def, def, true
        return true
    end
    ns.Filters.GetQuickFilter = function() return current end
    ns.Filters.ClearQuickFilter = function() current = nil end
    ns.Search.Show = function() end
    ns.Search.GetSearchFrame = function() return { IsShown = function() return true end } end
    ns.Search.GetResultsFrame = function() return { IsShown = function() return shown end } end
    ns.Results.HideResults = function() shown = false end
    API.RegisterExtension({ id = "att", name = "All The Things", icon = 1, scope = "att" })
    API.RegisterRowDecorator({ id = "att", aliases = { "att" }, applies = function(row) return row.itemID ~= nil end })
    H.assertFalse(API.IsExtensionOpen("att"))
    H.assertTrue(API.OpenExtension("att"))
    env._clock:advance(0)
    H.assertTrue(applied ~= nil, "the tile applied a quick filter")
    H.assertEq(applied.key, "att")
    H.assertEq(applied.label, "All The Things", "the pill reads the extension's name")
    H.assertEq(applied.decorator, ns.Extensions.Decorators.list[1])
    H.assertTrue(API.IsExtensionOpen("att"), "open while its pill is up")
    H.assertEq(ns.Extensions.ScopeShowing(), "att")
    API.CloseExtension("att")
    H.assertFalse(API.IsExtensionOpen("att"))
end

-- candidates (MINOR 6) name the rows by field before applies is asked: a
-- row outside them is never the decorator's, one inside is, or is asked
-- applies; a refresh asks candidates again.
function tests.candidatesNameTheRows_appliesRefines_refreshAsksAgain()
    local _, ns, API = Env()
    local asked, appliesAsked = 0, {}
    local named = { itemID = { [7] = true }, speciesID = { [40] = true } }
    API.RegisterRowDecorator({ id = "prices", candidates = function() asked = asked + 1 return named end })
    local E = ns.Extensions
    local prices = E.Decorators.list[1]
    H.assertTrue(E.DecoratorTakes(prices, { itemID = 7, category = "Loot" }), "named by its item")
    H.assertTrue(E.DecoratorTakes(prices, { speciesID = 40 }), "or its species")
    H.assertFalse(E.DecoratorTakes(prices, { itemID = 8, category = "Bag" }), "an item not named")
    H.assertFalse(E.DecoratorTakes(prices, { questId = 7 }), "a field not named")
    H.assertEq(asked, 1, "asked once for all the rows")
    named = { itemID = { [9] = true } }
    H.assertFalse(E.DecoratorTakes(prices, { itemID = 9 }), "the first answer stands until a refresh")
    API.RefreshRowDecorations()
    H.assertTrue(E.DecoratorTakes(prices, { itemID = 9 }))
    H.assertEq(asked, 2)
    API.RegisterRowDecorator({ id = "spoken", candidates = function() return named end,
        applies = function(row) appliesAsked[#appliesAsked + 1] = row.itemID return row.itemID == 9 end })
    local spoken = E.Decorators.list[2]
    H.assertTrue(E.DecoratorTakes(spoken, { itemID = 9 }))
    H.assertFalse(E.DecoratorTakes(spoken, { itemID = 7 }), "outside the candidates")
    H.assertEq(#appliesAsked, 1, "applies asked only inside them")
end

-- One extension with a provider and a decorator of one id (MINOR 7): one
-- scope lists both, whichever registers first; another extension's
-- provider keeps its scope to itself.
function tests.aProviderAndItsDecorator_shareOneScope()
    local function Run(providerFirst, providerOwner, decoratorAliases)
        local _, ns, API = Env()
        local held, joined = {}, {}
        ns.Filters.AddQuickFilter = function(_, def)
            if held[def.canonical] then return false end
            held[def.canonical] = def
            return true
        end
        ns.Filters.JoinQuickFilter = function(_, def, cats, aliases)
            joined[#joined + 1] = { def = def, cats = cats, aliases = aliases }
        end
        API.RegisterExtension({ id = "hn", name = "Pins", icon = 1 })
        API.RegisterExtension({ id = "other", name = "Other", icon = 1 })
        local function Provider()
            API.RegisterSearchProvider({ key = "hn", label = "Pins", category = "Pin", extension = providerOwner, aliases = { "pins" } })
        end
        local function Decorator()
            API.RegisterRowDecorator({ id = "hn", aliases = decoratorAliases, applies = function() return true end })
        end
        if providerFirst then Provider() Decorator() else Decorator() Provider() end
        return ns, held.hn, joined
    end
    for _, first in ipairs({ true, false }) do
        for _, aliases in ipairs({ { "hn" }, false }) do
            local ns, scope, joined = Run(first, "hn", aliases or nil)
            local how = (first and "provider first" or "decorator first") .. (aliases and "" or ", no aliases")
            H.assertEq(#joined, 1, "joined once: " .. how)
            H.assertEq(joined[1].def, scope)
            H.assertEq(joined[1].cats[1], "Pin", "the provider's category: " .. how)
            H.assertEq(scope.decorator, ns.Extensions.Decorators.list[1])
            H.assertEq(ns.Extensions.Decorators.scopes.hn, scope)
        end
    end
    local _, _, late = Run(false, "hn", { "hn" })
    H.assertEq(late[1].aliases[1], "pins", "the decorator's scope came first: the provider's aliases join it")
    local ns, scope, joined = Run(true, "other", { "hn" })
    H.assertEq(#joined, 0, "another extension's provider: no join")
    H.assertNil(scope.decorator)
    H.assertNil(ns.Extensions.Decorators.scopes.hn)
end

-- candidates' name key (MINOR 7): a lowercase name to the maps its pins
-- are on; a row so named on one of them, or with one in the same zone.
function tests.candidatesByName_onTheNamesMapsOrTheirZone()
    local env = H.newEnv()
    env.EasyFind = {}
    local maps = { [1] = { mapID = 1, mapType = 3 }, [100] = { mapID = 100, mapType = 6, parentMapID = 1 },
                   [2] = { mapID = 2, mapType = 3 } }
    env.C_Map = { GetMapInfo = function(id) return maps[id] end }
    local ns = H.newNs(env)
    local API = env.EasyFind.API
    API.RegisterExtension({ id = "hn", name = "Pins", icon = 1 })
    API.RegisterRowDecorator({ id = "hn", candidates = function()
        return { npcID = { [5] = true }, name = { ["Faruza"] = { [100] = true } } }
    end })
    local E = ns.Extensions
    local hn = E.Decorators.list[1]
    H.assertTrue(E.DecoratorTakes(hn, { name = "Faruza", nameLower = "faruza", mapID = 100 }), "on the pin's map")
    H.assertTrue(E.DecoratorTakes(hn, { name = "Faruza", mapID = 1 }), "the pin's building walks up to its zone")
    H.assertFalse(E.DecoratorTakes(hn, { name = "Faruza", mapID = 2 }), "another zone")
    H.assertFalse(E.DecoratorTakes(hn, { name = "Someone", mapID = 1 }), "another name")
    H.assertFalse(E.DecoratorTakes(hn, { name = "Faruza" }), "a row on no map")
    H.assertTrue(E.DecoratorTakes(hn, { npcID = 5 }), "the other fields still name rows")
end

-- words (MINOR 7): the words decorators give EasyFind's rows they mark, by
-- creature or by a name on a map (matched in its zone), so a search finds
-- those rows by them ("decor durotar"); asked again after a refresh.
function tests.wordsGiveMarkedRowsWords_byCreatureOrNameInItsZone()
    local env = H.newEnv()
    env.EasyFind = {}
    local maps = { [1] = { mapID = 1, mapType = 3 }, [100] = { mapID = 100, mapType = 6, parentMapID = 1 },
                   [2] = { mapID = 2, mapType = 3 } }
    env.C_Map = { GetMapInfo = function(id) return maps[id] end }
    local ns = H.newNs(env)
    local API = env.EasyFind.API
    local asked, words = 0, { npc = { [5] = { "Decor", "Vendor" } }, name = { ["Faruza@100"] = { "decor" } } }
    API.RegisterExtension({ id = "hn", name = "Pins", icon = 1 })
    API.RegisterRowDecorator({ id = "hn", words = function() asked = asked + 1 return words end })
    local E = ns.Extensions
    H.assertEq(table.concat(E.NpcWords(5), ","), "decor,vendor", "a creature's, lowercased")
    H.assertNil(E.NpcWords(6))
    local set = E.NpcsWithWord("dec", {})
    H.assertTrue(set[5], "a creature by a word holding the typed one")
    H.assertNil(next(E.NpcsWithWord("stable", {})))
    H.assertEq(E.PlaceWords("faruza", 100)[1], "decor", "a name on its map")
    H.assertEq(E.PlaceWords("faruza", 1)[1], "decor", "or on a map in the same zone")
    H.assertNil(E.PlaceWords("faruza", 2), "another zone")
    H.assertNil(E.PlaceWords("someone", 1))
    H.assertEq(asked, 1, "asked once")
    words = { npc = { [6] = { "stable" } } }
    H.assertEq(E.NpcWords(5)[1], "decor", "the first answer stands until a refresh")
    API.RefreshRowDecorations()
    H.assertNil(E.NpcWords(5))
    H.assertEq(E.NpcWords(6)[1], "stable")
    H.assertEq(asked, 2)
end

-- The map search reads them: a POI's row takes its decorators' words among
-- its own, again when the decorators change.
function tests.mapRowsTakeTheWords()
    local function Read(path)
        local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
        local src = f:read("*a")
        f:close()
        return src
    end
    local core = Read("MapSearch/Search/Core.lua")
    H.assertTrue(core:find("local function GetPOIMask(entry)\n    TakeDecoratorWords(entry)", 1, true) ~= nil
        or core:find("local function GetPOIMask(entry)\r\n    TakeDecoratorWords(entry)", 1, true) ~= nil, "the gate takes them first")
    H.assertTrue(core:find("kwLower[#kwLower + 1] = given[i]", 1, true) ~= nil, "among the row's words")
    H.assertTrue(Read("MapSearch/Search/Results.lua"):find("if poi.keywords or poi.decoratorWords then", 1, true) ~= nil,
        "scored with them")
end

-- browse (MINOR 6) says what the scope lists while nothing is typed; every
-- taken row without it.
function tests.browseSaysWhatTheScopeLists()
    local _, ns, API = Env()
    API.RegisterRowDecorator({ id = "spoken", aliases = { "sp" }, applies = function() return true end,
        browse = function(row) return row.itemID == 7 end })
    API.RegisterRowDecorator({ id = "prices", applies = function() return true end })
    local E = ns.Extensions
    H.assertTrue(E.DecoratorBrowses(E.Decorators.list[1], { itemID = 7 }))
    H.assertFalse(E.DecoratorBrowses(E.Decorators.list[1], { itemID = 8 }))
    H.assertTrue(E.DecoratorBrowses(E.Decorators.list[2], { itemID = 8 }), "no browse: every row")
end

-- The scope's paths ask the decorator: the quick filter admits the rows it
-- takes, the empty scope lists what its browse says, a taken token is told.
function tests.theScopePathsAskIt()
    local function Read(path)
        local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
        local src = f:read("*a")
        f:close()
        return src
    end
    local filters = Read("Search/Filters/QuickFilter.lua")
    H.assertTrue(filters:find("return ns.Extensions.DecoratorTakes(def.decorator, data)", 1, true) ~= nil)
    H.assertTrue(filters:find("if Filters.quickFilterByAlias[slower(def.canonical)] then return false end", 1, true) ~= nil)
    local query = Read("Search/Query.lua")
    H.assertTrue(query:find("listed = ns.Extensions.DecoratorBrowses(decorator, d)", 1, true) ~= nil)
    H.assertTrue(query:find('(quickFilter.key == "map" or quickFilter.decorator)', 1, true) ~= nil, "the map pass runs under it")
    H.assertTrue(query:find("or (decorated and not self:QuickFilterAllowsData(r.data, decorated))", 1, true) ~= nil,
        "keeping the map rows it takes")
    local readme = Read("API/README.md")
    H.assertTrue(readme:find("| `aliases` | string list | MINOR 6.", 1, true) ~= nil, "documented")
    H.assertTrue(readme:find("| `browse` | function `(row)` | MINOR 6.", 1, true) ~= nil)
    H.assertTrue(readme:find("| `candidates` | function | MINOR 6.", 1, true) ~= nil)
    H.assertTrue(Read("API/EasyFind_API.lua"):find("---@field candidates? fun(): table<string, table<any, true>>", 1, true) ~= nil, "annotated")
end

local pass, fail, failures = H.runSuite("RowDecorators", tests)
return { pass = pass, fail = fail, failures = failures }
