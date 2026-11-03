-- A note made a shopping list and back (Apps/Notes/Notes.lua SetShopping,
-- 2026-11-02): on, names are items and the extension that keeps lists of
-- items makes one of the note (handlers.adopt), filed under its category;
-- off, that list is deleted there (handlers.drop), asked first. A list an
-- extension keeps for itself with no drop stays one.

local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function Extract(src, header)
    local s = assert(src:find(header, 1, true), header .. " not in Notes.lua")
    local _, e = assert(src:find("\nend\n", s, true))
    return src:sub(s, e)
end

local function Load()
    local env = H.newEnv()
    env._G = env
    env.UnitName = function() return "Tester" end
    env.GetUnitName = function() return "Tester" end
    env.GetRealmName = function() return "Realm" end
    env.C_Item = { GetItemCount = function() return 0 end, GetItemNameByID = function(id) return "Item" .. id end }
    env.time = os.time
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    env.GetBuildInfo = function() return "12.0.5", "1", "", 120005 end
    H.loadModule("Shared/Caps.lua", env, ns)
    local notesNS = { Context = { WindowLabel = function() return "Auction House" end } }
    assert(loadfile(H.ADDON_ROOT .. "/Apps/Notes/Checklist.lua", "t", env))("EasyFind_Notes", notesNS)
    local CK = notesNS.Checklist
    local dialog, refreshed = {}, 0
    ns.ChecklistLinks = {}
    ns.Extensions = { byID = { auctionator = { name = "Auctionator" } } }
    ns.GOLD_COLOR = {}
    ns.ShowThemedDialog = function(opts) dialog.opts = opts end
    notesNS.Refresh = function() refreshed = refreshed + 1 end
    notesNS.Lines = { Reload = function() end }
    local src = Read("Apps/Notes/Notes.lua")
    local chunk = table.concat({
        Extract(src, "function notesNS.TagLinkedWindow(note, window)"),
        Extract(src, "function notesNS.LinkLines(note)"),
        Extract(src, "function notesNS.ListKeeper()"),
        Extract(src, "function notesNS.SetShopping(note, on)"),
    }, "\n")
    local fenv = setmetatable({
        notesNS = notesNS, ns = ns, L = { NOTES_SHOP_OFF_ASK = "%s|%s", NOTES_SHOP_OFF_ACCEPT = "Delete list" },
        Utils = { sformat = string.format }, NoteTitle = function(n) return n.name end, time = os.time,
        tremove = table.remove, geterrorhandler = function() return print end,
        tContains = function(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end,
    }, { __index = _G })
    assert(load(chunk, "=SetShopping", "t", fenv))()
    return notesNS, CK, ns, dialog
end

local function Checklist(CK)
    local note = { id = 9, name = "raid consumes", body = "", decorations = {}, categories = { "Raids" }, category = "Raids" }
    CK.Init(note)
    note.body = CK.EMPTY .. "|cffffffff|Hitem:1181::|h[Scroll of Spirit]|h|r x3\n" .. CK.EMPTY .. "Linen Cloth"
    CK.Reconcile(note)
    return note
end

local function Auctionator(ns, log)
    ns.ChecklistLinks.auctionator = {
        items = true,
        category = { key = "ShoppingLists", label = "Shopping lists", window = "auctionhouse" },
        adopt = function(noteID, title, lines) log.adopt = { noteID, title, lines } return title end,
        drop = function(noteID, key) log.drop = { noteID, key } end,
    }
end

local tests = {}

function tests.on_withoutAKeeper_namesAreItems()
    local notesNS, CK = Load()
    local note = Checklist(CK)
    H.assertFalse(CK.ItemsList(note), "a checklist")
    notesNS.SetShopping(note, true)
    H.assertTrue(note.list.shopping, "the player made it a shopping list")
    H.assertTrue(CK.ItemsList(note), "names typed in it are items")
    H.assertNil(note.list.source, "no extension keeps it")
end

function tests.on_theKeeperMakesAListOfIt_filedUnderItsCategory()
    local notesNS, CK, ns = Load()
    local log = {}
    Auctionator(ns, log)
    local note = Checklist(CK)
    notesNS.SetShopping(note, true)
    H.assertEq(log.adopt[1], 9)
    H.assertEq(log.adopt[2], "raid consumes", "the list takes the note's title")
    H.assertEq(#log.adopt[3], 2, "with its lines")
    H.assertEq(log.adopt[3][1].item, 1181)
    H.assertEq(log.adopt[3][1].target, 3)
    H.assertTrue(log.adopt[3][1].id ~= nil, "each line with its id, for the refs")
    H.assertDeepEq(note.list.source, { ext = "auctionator", key = "raid consumes" }, "the note follows that list")
    H.assertDeepEq(note.categories, { "Raids", "ShoppingLists" }, "its own category kept, the list's added")
    H.assertEq(note.appliesIn[1].id, "auctionhouse", "the Auction House tag")
end

function tests.off_asksThenDeletesTheKeepersList()
    local notesNS, CK, ns, dialog = Load()
    local log = {}
    Auctionator(ns, log)
    local note = Checklist(CK)
    notesNS.SetShopping(note, true)
    note.list.lines[1].ref = "raw1"
    notesNS.SetShopping(note, false)
    H.assertEq(dialog.opts.text, "Auctionator|raid consumes", "asks, naming the extension and its list")
    H.assertNil(log.drop, "nothing deleted before the answer")
    H.assertTrue(CK.ItemsList(note), "still a shopping list while asked")
    dialog.opts.onAccept()
    H.assertDeepEq(log.drop, { 9, "raid consumes" }, "the list deleted there")
    H.assertNil(note.list.source)
    H.assertNil(note.list.shopping)
    H.assertFalse(CK.ItemsList(note), "a checklist again")
    H.assertDeepEq(note.categories, { "Raids" }, "the list's category goes, the player's stays")
    H.assertEq(#note.appliesIn, 0, "the tag the list gave goes")
    H.assertNil(note.list.lines[1].ref, "its lines stand for nothing there now")
end

function tests.off_ownShoppingList_noQuestion()
    local notesNS, CK, _, dialog = Load()
    local note = Checklist(CK)
    notesNS.SetShopping(note, true)
    notesNS.SetShopping(note, false)
    H.assertNil(dialog.opts, "nothing to delete: no question")
    H.assertFalse(CK.ItemsList(note))
end

function tests.off_aListAnExtensionKeepsForItself_staysOne()
    local notesNS, CK, ns, dialog = Load()
    ns.ChecklistLinks.tsm = { items = true }
    local note = Checklist(CK)
    note.list.source = { ext = "tsm", key = "crafting" }
    notesNS.SetShopping(note, false)
    H.assertNil(dialog.opts)
    H.assertTrue(CK.ItemsList(note), "the crafting list stays a list of items")
    H.assertDeepEq(note.list.source, { ext = "tsm", key = "crafting" })
end

-- A plain checklist with an item on it offers to become a shopping list,
-- until the player says no for that note; plain words never do.
function tests.aChecklistOfItemsOffersToBeAShoppingList()
    local notesNS, CK = Load()
    local note = Checklist(CK)
    H.assertTrue(CK.OffersShopping(note), "an item on a checklist")
    note.list.shopDeclined = true
    H.assertFalse(CK.OffersShopping(note), "declined for this note")
    note.list.shopDeclined = nil
    notesNS.SetShopping(note, true)
    H.assertFalse(CK.OffersShopping(note), "already one")
    local words = { id = 3, body = "", decorations = {} }
    CK.Init(words)
    words.body = CK.EMPTY .. "call the guild\n" .. CK.EMPTY .. "repair"
    CK.Reconcile(words)
    H.assertFalse(CK.OffersShopping(words), "no items: no offer")
end

-- The list menu's checklist entry opens the choice (menu A); a pick makes
-- the note that kind with the caret's line a list line, and the kind it
-- already is flips the line's box.
function tests.theChecklistChoice_kindAndLine()
    local src = Read("Apps/Notes/Notes.lua")
    H.assertTrue(src:find('if item.key == "checklist" then return UI:ToggleEasyNotesChecklistMenu(self) end', 1, true) ~= nil,
        "the checklist entry opens the choice")
    local menu = Extract(src, "function UI:ToggleEasyNotesChecklistMenu(opt)")
    H.assertTrue(menu:find('L["NOTES_FMT_CHECKLIST"]', 1, true) and menu:find('L["NOTES_FMT_SHOPPING"]', 1, true), "both kinds by name")
    H.assertTrue(menu:find("self:ShowEasyNotesMenu(", 1, true) ~= nil, "the shared menu, Esc and outside clicks with it")
    local BOX = "\226\150\161 "
    local applied, shopped, text, isShop = {}, {}, "", false
    local editor = { GetText = function() return text end, GetCursorPosition = function() return #text end }
    local UI = { _notes = { frame = { editor = editor } } }
    function UI:ApplyEasyNotesFormat(action) applied[#applied + 1] = action.mode end
    local env = setmetatable({
        UI = UI, CHECK_EMPTY_PREFIX = BOX, CHECK_FILLED_PREFIX = "\226\150\163 ",
        GetSelectedNote = function() return {} end,
        FindLineStartByte = function(t, pos) local nl = t:sub(1, pos):find("\n[^\n]*$") return nl and nl + 1 or 1 end,
        MatchLinePrefix = function(t, at) return t:sub(at, at + #BOX - 1) == BOX and #BOX or 0 end,
        notesNS = { Checklist = { ItemsList = function() return isShop end },
                    SetShopping = function(_, on) shopped[#shopped + 1] = on end },
    }, { __index = _G })
    assert(load(Extract(src, "function UI:PickEasyNotesListKind(shop)"), "=Pick", "t", env))()
    text = "plain words"
    UI:PickEasyNotesListKind(true)
    H.assertEq(#applied, 1, "a line with no box gets one")
    H.assertEq(shopped[1], true, "and the note is a shopping list")
    applied, shopped, isShop, text = {}, {}, true, BOX .. "Linen Cloth"
    UI:PickEasyNotesListKind(true)
    H.assertEq(#applied, 1, "the kind it is: the line's box flips")
    H.assertEq(#shopped, 0, "the kind left alone")
    applied, shopped = {}, {}
    UI:PickEasyNotesListKind(false)
    H.assertEq(#applied, 0, "the line keeps its box")
    H.assertEq(shopped[1], false, "a checklist again (asked there)")
end

local pass, fail, failures = H.runSuite("NotesShopping", tests)
return { pass = pass, fail = fail, failures = failures }
