-- Result actions (Search/Results/RowActions.lua): a chord over a result row
-- does that row's right-click entry; an entry with a flyout opens it at the
-- cursor. Chords hold Alt or Ctrl, never one the search box answers. The
-- menu shows a bound chord beside its entry (Shared/Utils.lua PinMenuRows).
local H = require("Harness")

local function fakeWidget()
    local w = {}
    setmetatable(w, { __index = function() return function() return w end end })
    return w
end

local function World()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind.db = {}
    local held = { alt = false, ctrl = false, shift = false }
    env.IsAltKeyDown = function() return held.alt end
    env.IsControlKeyDown = function() return held.ctrl end
    env.IsShiftKeyDown = function() return held.shift end
    env.GetBindingAction = function() return "" end
    local Utils = ns.Utils
    Utils.IsModifierKey = function(k) return k == "LALT" or k == "LCTRL" or k == "LSHIFT" end
    Utils.ModifierCombo = function(key)
        return (held.alt and "ALT-" or "") .. (held.ctrl and "CTRL-" or "") .. (held.shift and "SHIFT-" or "") .. key
    end
    Utils.SwallowNextCharInsert = function() end
    local shown
    Utils.ShowCursorMenu = function(name, rows) shown = { name = name, rows = rows } end
    local entries = {}
    Utils.PinMenuRows = function() return entries end
    ns.ResultRows.ResultMenuModel = function() return false, nil, nil, nil, {} end
    local row = { data = { name = "Linen Cloth" }, IsShown = function() return true end,
                  IsMouseOver = function() return true end }
    ns.Results._hoverRow = row
    ns.Search.GetSelectedIndex = function() return 0 end
    ns.Search.GetSearchFrame = function() return nil end
    H.loadModule("Search/Results/RowActions.lua", env, ns)
    return ns.ResultRowActions, held, entries, function() return shown end, ns
end

local tests = {}

function tests.aChordHoldsAltOrCtrlAndIsNotTheBoxs()
    local RA = World()
    H.assertNotNil(RA.Refusal("N"), "a plain key types")
    H.assertNotNil(RA.Refusal("SHIFT-N"), "Shift types a capital")
    H.assertNotNil(RA.Refusal("ALT-J"), "the list's down")
    H.assertNotNil(RA.Refusal("ALT-3"), "a row shortcut")
    H.assertNotNil(RA.Refusal("CTRL-C"), "copy")
    H.assertNotNil(RA.Refusal("CTRL-SHIFT-C"), "the EasyFind link")
    H.assertNil(RA.Refusal("ALT-N"))
    H.assertNil(RA.Refusal("CTRL-SHIFT-N"))
end

function tests.aChordMovesFromTheActionThatHadIt()
    local RA = World()
    H.assertNil(RA.Set("note", "ALT-N"))
    H.assertEq(RA.Set("pin", "ALT-N"), "note", "names the action it left")
    H.assertNil(RA.KeyOf("note"))
    H.assertEq(RA.KeyOf("pin"), "ALT-N")
    H.assertEq(RA.ChordText("ALT-SHIFT-N"), "Alt+Shift+N")
end

function tests.aChordDoesTheEntryOrOpensItsFlyout()
    local RA, held, entries, Shown = World()
    local pinned = false
    entries[1] = { actionId = "pin", text = "Pin", onClick = function() pinned = true end }
    entries[2] = { text = "Add", submenu = {
        { actionId = "note", text = "Note", submenu = { { text = "Raid prep" } } },
    } }
    RA.Set("pin", "ALT-P")
    RA.Set("note", "ALT-N")
    held.alt = true
    H.assertTrue(RA.HandleKey(nil, "P"))
    H.assertTrue(pinned, "the entry's own click")
    H.assertTrue(RA.HandleKey(nil, "N"))
    H.assertEq(Shown().rows[1].text, "Raid prep", "the flyout, at the cursor")
    H.assertFalse(RA.HandleKey(nil, "Q"), "an unbound chord is left alone")
    held.alt = false
    H.assertFalse(RA.HandleKey(nil, "P"), "no modifier: typing")
end

-- A click takes two modifiers: one alone is the row's own Result clicks.
-- An action an extension does wears its icon in the settings list, the
-- core Add to note and Add to quicklist too, not only the extensions' own
-- Add entries (2026-10-26: the Shopping list alone had one).
function tests.anExtensionsActions_wearItsIcon()
    local RowActions, _, _, _, ns = World()
    local Extensions = { byID = {
        notes = { icon = "notes.tga", iconCoords = { 0, 1, 0, 1 } }, quicklists = { icon = "quicklists.tga" },
        shoplist = { icon = "shop.tga" },
    } }
    Extensions.Get = function(id) return Extensions.byID[id] end
    Extensions.AddTargets = { { key = "shop", extension = "shoplist", label = "Shopping list" } }
    ns.Extensions = Extensions
    local icons = {}
    for _, a in ipairs(RowActions.List()) do icons[a.id] = a.icon end
    H.assertEq(icons.note, "notes.tga")
    H.assertEq(icons.quicklist, "quicklists.tga")
    H.assertEq(icons["add:shop"], "shop.tga")
    H.assertNil(icons.pin, "a core action of its own has none")
end

function tests.aClickChordHoldsTwoModifiers()
    local RA, held = World()
    H.assertNotNil(RA.Refusal("ALT-CLICK"), "one modifier: the kind's own gesture")
    H.assertNil(RA.Refusal("ALT-SHIFT-CLICK"))
    H.assertEq(RA.ChordText("ALT-SHIFT-CLICK"), "Alt+Shift+HINT_CLICK")
    RA.Set("note", "ALT-SHIFT-CLICK")
    held.alt, held.shift = true, true
    H.assertEq(RA.ActionForClick(), "note")
    held.shift = false
    H.assertNil(RA.ActionForClick(), "Alt alone is not it")
end

-- The menu: a bound action shows its chord; an unbound one says where to bind.
function tests.theMenuShowsChordsAndWhereToBind()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.CreateFont, env.CreateFrame = fakeWidget, fakeWidget
    env.CreateColor = function(r, g, b, a) return { GetRGBA = function() return r, g, b, a end } end
    env.UIParent, env.WorldFrame, env.GameTooltip = fakeWidget(), fakeWidget(), fakeWidget()
    env.hooksecurefunc = function() end
    env.GameFontNormal = setmetatable({}, { __index = function(_, k)
        if k == "GetFont" then return function() return "font", 12, "" end end
        return function() end
    end })
    H.loadModule("Shared/Utils.lua", env, ns)
    env.EasyFind.db = { rowActionKeys = { note = "ALT-N" } }
    ns.ResultText = { AbbrevBinding = function(_, k) return k end }
    H.loadModule("Search/Results/RowActions.lua", env, ns)
    local rows = ns.Utils.PinMenuRows(false, function() end, nil, function() end, {
        addNoteRows = { { text = "Raid prep" } }, addQuicklistRows = { { text = "Main" } },
    })
    local add
    for _, r in ipairs(rows) do
        if r.submenu and r.submenu[1] and r.submenu[1].fullText then add = r.submenu end
    end
    local byId = {}
    for _, r in ipairs(add) do byId[r.actionId] = r end
    H.assertEq(byId.note.keyHint, "Alt+N")
    H.assertEq(byId.quicklist.tooltip, ns.L["ROWACT_BIND_HINT"], "no tooltip of its own: the hint is it")
    H.assertEq(byId.alias.tooltipNote, ns.L["ROWACT_BIND_HINT"], "its own tooltip first, the hint under it")
end

local pass, fail, failures = H.runSuite("RowActions", tests)
return { pass = pass, fail = fail, failures = failures }
