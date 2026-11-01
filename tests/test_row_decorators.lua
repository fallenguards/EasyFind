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

local pass, fail, failures = H.runSuite("RowDecorators", tests)
return { pass = pass, fail = fail, failures = failures }
