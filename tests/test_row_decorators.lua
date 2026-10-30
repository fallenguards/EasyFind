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
    H.assertTrue(Read("Search/Results/Rows/ResultContextMenu.lua"):find("DecoratorMenuRows(pinData", 1, true) ~= nil)
    H.assertTrue(Read("Shared/Utils.lua"):find("extra.decoratorRows", 1, true) ~= nil, "the menu lays them out")
    H.assertTrue(Read("Search/Results/Rows/Tooltips.lua"):find("DecorateTooltip(", 1, true) ~= nil)
    H.assertTrue(Read("API/README.md"):find("### RegisterRowDecorator(def)", 1, true) ~= nil, "documented")
end

local pass, fail, failures = H.runSuite("RowDecorators", tests)
return { pass = pass, fail = fail, failures = failures }
