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
        -- The client names no item yet: the names come from the words.
        C_Item = { GetItemNameByID = function() return nil end },
        tremove = table.remove, geterrorhandler = function() return print end,
        tContains = function(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end,
    }, { __index = _G })
    assert(load(chunk, "=SetShopping", "t", fenv))()
    return notesNS, CK, ns, dialog, env
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
    H.assertEq(log.adopt[3][1].name, "Scroll of Spirit", "named as typed while the client has no name")
    H.assertNil(log.adopt[3][2].name, "a line of words has no item name")
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
    local applied, shopped, text, isShop, order = {}, {}, "", false, {}
    local editor = { GetText = function() return text end, GetCursorPosition = function() return #text end }
    local UI = { _notes = { frame = { editor = editor } } }
    function UI:ApplyEasyNotesFormat(action)
        applied[#applied + 1] = action.mode
        text = BOX .. text
    end
    local env = setmetatable({
        UI = UI, CHECK_EMPTY_PREFIX = BOX, CHECK_FILLED_PREFIX = "\226\150\163 ",
        GetSelectedNote = function() return {} end,
        FindLineStartByte = function(t, pos) local nl = t:sub(1, pos):find("\n[^\n]*$") return nl and nl + 1 or 1 end,
        MatchLinePrefix = function(t, at) return t:sub(at, at + #BOX - 1) == BOX and #BOX or 0 end,
        UpdateBody = function(_, body) order[#order + 1] = "saved:" .. body end,
        notesNS = { Checklist = { ItemsList = function() return isShop end },
                    SetShopping = function(_, on) shopped[#shopped + 1] = on order[#order + 1] = "kind" end },
    }, { __index = _G })
    assert(load(Extract(src, "function UI:PickEasyNotesListKind(shop)"), "=Pick", "t", env))()
    text = "plain words"
    UI:PickEasyNotesListKind(true)
    H.assertEq(#applied, 1, "a line with no box gets one")
    H.assertEq(shopped[1], true, "and the note is a shopping list")
    -- The kind change reloads the editor from the note: an empty note
    -- lost the box just typed (2026-11-03).
    text, order = "", {}
    UI:PickEasyNotesListKind(true)
    H.assertEq(table.concat(order, " "), "saved:" .. BOX .. " kind", "the box stored before the kind changes")
    applied, shopped, isShop, text = {}, {}, true, BOX .. "Linen Cloth"
    UI:PickEasyNotesListKind(true)
    H.assertEq(#applied, 1, "the kind it is: the line's box flips")
    H.assertEq(#shopped, 0, "the kind left alone")
    applied, shopped = {}, {}
    UI:PickEasyNotesListKind(false)
    H.assertEq(#applied, 0, "the line keeps its box")
    H.assertEq(shopped[1], false, "a checklist again (asked there)")
end

-- Names typed in a checklist stay words there, so the offer looks them up
-- ("linen cloth", "copper ore" brought none, 2026-11-03); "Never show
-- again" (notesShopOffer false) ends it for every note.
function tests.typedItemNamesBringTheOffer_untilNeverAgain()
    local _, CK, _, _, env = Load()
    local ids = { ["linen cloth"] = 2589, ["copper ore"] = 2770 }
    local lookups = 0
    local note = { id = 4, body = "", decorations = {} }
    CK.Init(note)
    note.body = CK.EMPTY .. "call the guild\n" .. CK.EMPTY .. "linen cloth x20"
    CK.Reconcile(note)
    H.assertNil(note.list.lines[2].item, "a typed name stays words in a checklist")
    CK.ItemByName = function(name) lookups = lookups + 1 return ids[name:lower()] end
    H.assertTrue(CK.OffersShopping(note), "a typed item name brings the offer")
    local before = lookups
    CK.OffersShopping(note)
    H.assertEq(lookups, before, "each name looked up once, not at every repaint")
    env.EasyFind.db = env.EasyFind.db or {}
    env.EasyFind.db.notesShopOffer = false
    H.assertFalse(CK.OffersShopping(note), "never again, on any note")
end

-- The offer's box and its X in the corner; Notes' settings turn it back on.
function tests.theOffer_neverBox_andTheSettingBack()
    local lines = Read("Apps/Notes/Lines.lua")
    H.assertTrue(lines:find('row.never = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")', 1, true) ~= nil, "the box")
    H.assertTrue(lines:find('row.never.text:SetText(L["NOTES_SHOP_NEVER"])', 1, true) ~= nil)
    H.assertTrue(lines:find('row.x:SetPoint("TOPRIGHT", row, "TOPRIGHT", -5, -5)', 1, true) ~= nil, "the X in the top right")
    H.assertTrue(lines:find("if row.never:GetChecked() and EasyFind and EasyFind.db then EasyFind.db.notesShopOffer = false end", 1, true) ~= nil,
        "the box ticked, the X or Convert ends the offer everywhere")
    local ext = Read("Core/Extensions.lua")
    H.assertTrue(ext:find('{ "notesShopOffer", "NOTES_OPT_SHOP_OFFER" }', 1, true) ~= nil, "in Notes' settings page")
    H.assertTrue(ext:find('DbOption("notesShopOffer", L["NOTES_OPT_SHOP_OFFER"], L["NOTES_OPT_SHOP_OFFER_TT"])', 1, true) ~= nil,
        "and the search bar's options")
end

-- Notes' tooltips wrap: the offer's two sentences ran across the screen
-- on one line (2026-11-03).
function tests.notesTooltipsWrap()
    local src = Read("Apps/Notes/Notes.lua")
    local s = assert(src:find("function UI:ShowNotesTipDelayed(region, anchor, text)", 1, true))
    local body = src:sub(s, (src:find("\nend\n", s, true)))
    H.assertTrue(body:find("GameTooltip:SetText(text, c and c.r or 1, c and c.g or 0.82, c and c.b or 0, 1, true)", 1, true) ~= nil,
        "wrapped")
    H.assertNil(body:find("ShowThemedTooltip", 1, true), "no call to a helper that does not exist")
end

-- The + button: a click a new note, a right-click any kind of list at
-- once; the extension that keeps shopping lists is that row, not a second.
-- The footer's T sits in the corner and the character count stays with
-- the toolbar on (2026-11-03).
function tests.theNewMenu_everyKind_andTheFooter()
    local src = Read("Apps/Notes/Notes.lua")
    local s = assert(src:find('frame.newButton:SetScript("OnClick", function(self, button)', 1, true))
    local body = src:sub(s, s + 2200)
    for _, key in ipairs({ "NOTES_NEW", "NOTES_FMT_CHECKLIST", "NOTES_FMT_SHOPPING", "NOTES_FMT_BULLETS", "NOTES_FMT_NUMBERED" }) do
        H.assertTrue(body:find(("L[%q]"):format(key), 1, true) ~= nil, key)
    end
    H.assertTrue(body:find("Start(CHECK_EMPTY_PREFIX, L[\"NOTES_FMT_SHOPPING\"], true)", 1, true) ~= nil, "a shopping list at once")
    H.assertTrue(body:find("target.extension ~= keeper", 1, true) ~= nil, "no second shopping list row")
    H.assertTrue(src:find('frame.formatButton:SetPoint("BOTTOMLEFT", frame.footer, "BOTTOMLEFT", 5, 5)', 1, true) ~= nil, "T in the corner")
    H.assertTrue(src:find("frame.charCounter:SetShown(shown)\n", 1, true) ~= nil, "the count stays with the toolbar on")
    H.assertNil(src:find("charCounter:SetShown(not on)", 1, true))
end

local pass, fail, failures = H.runSuite("NotesShopping", tests)
return { pass = pass, fail = fail, failures = failures }
