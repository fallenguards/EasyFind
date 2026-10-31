-- Tests for Apps/Notes/Lines.lua: a note's checkbox lines in its editor.
-- A box press ticks the list, a ticked line reads struck and green, a
-- counted line wears its count at the right, a line's X drops it, and a
-- shift-clicked link lands at the caret or as a line.

local H = require("Harness")

local LINK = "|cffffffff|Hitem:2589::|h[Linen Cloth]|h|r"

-- A frame that answers every method: Get* reads 0, the rest do nothing.
local function Stub()
    local special = {
        GetText = function(self) return self._text or "" end,
        SetText = function(self, v) self._text = v end,
        Insert = function(self, v) self._inserted = (self._inserted or "") .. v end,
        IsShown = function(self) return self._shown ~= false end,
        IsVisible = function(self) return self._shown ~= false end,
        Show = function(self) self._shown = true end,
        Hide = function(self) self._shown = false end,
        SetShown = function(self, v) self._shown = v and true or false end,
        CreateFontString = function() return Stub() end,
        CreateTexture = function() return Stub() end,
        SetScript = function(self, name, fn) self._scripts[name] = fn end,
        HookScript = function(self, name, fn) self._scripts[name] = fn end,
        GetScript = function(self, name) return self._scripts[name] end,
        HasFocus = function(self) return self._focus == true end,
        SetPoint = function(self, ...) self._points[#self._points + 1] = { ... } end,
        ClearAllPoints = function(self) self._points = {} end,
        SetSize = function(self, w, h) self._w, self._h = w, h end,
    }
    local t = { _scripts = {}, _points = {} }
    return setmetatable(t, { __index = function(_, k)
        if special[k] then return special[k] end
        if k:sub(1, 1) == "_" then return nil end
        if k:match("^Get%w*Texture$") then return function() return Stub() end end
        if k:sub(1, 3) == "Get" then return function() return 0 end end
        return function() end
    end })
end

local function Load(body)
    local env = H.newEnv()
    env._G = env
    env.UnitName = function() return "Tester" end
    env.GetUnitName = function() return "Tester" end
    env.GetRealmName = function() return "Realm" end
    env.C_Item = {
        GetItemCount = function() return 0 end,
        GetItemNameByID = function(id) return "Item" .. id end,
        GetItemIconByID = function() return 1 end,
    }
    env.date, env.time = os.date, os.time
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    env.GetBuildInfo = function() return "12.0.5", "1", "", 120005 end
    H.loadModule("Shared/Caps.lua", env, ns)
    ns.StoredItemCounts = function() end
    ns.RegisterAddonFont = function() end
    ns.CreateCloseX = function() return Stub() end
    ns.ShowTogglePopup = function() end
    ns.ShowThemedDialog = function() end
    ns.CurrentCharacterKey = function() return "Me-Realm" end
    ns.RegisterThemeCallback = function() end
    local t = { timers = {}, made = {} }
    ns.Utils.SafeAfter = function(delay, fn) t.timers[#t.timers + 1] = { delay = delay, fn = fn } end
    ns.Utils.HookInsertLink = function(fn) t.insertLink = fn end
    ns.Utils.CreateMinimalScrollBar = function() return Stub() end
    ns.Utils.ReleaseFocusOnOutsideClick = function() end
    ns.Utils.HexColorNames = function(s) return s end
    env.CreateFrame = function(kind)
        local f = Stub()
        t.made[kind] = t.made[kind] or {}
        t.made[kind][#t.made[kind] + 1] = f
        return f
    end
    local notesNS = { Context = {} }
    assert(loadfile(H.ADDON_ROOT .. "/Apps/Notes/Checklist.lua", "t", env))("EasyFind_Notes", notesNS)
    local CK = notesNS.Checklist
    local note = { id = 1, body = body or "", decorations = {} }
    CK.Init(note)
    CK.Reconcile(note)
    local frame
    local editor, scroll = Stub(), Stub()
    editor.GetParent = function() return scroll end
    scroll.GetParent = function() return frame end
    frame = { editor = editor, editorScroll = scroll, GetFrameLevel = function() return 1 end, IsShown = function() return true end }
    local main = { frame = frame, selectedID = 1, name = "main" }
    local W = { list = { main }, main = main, active = main, last = main, CreateFrame = env.CreateFrame, followed = 0 }
    function W.Run(w, fn, ...)
        local prev = W.active
        W.active = w
        local a, b = fn(...)
        W.active = prev
        return a, b
    end
    function W.Each(fn) for _, w in ipairs(W.list) do W.Run(w, fn, w) end end
    function W.Bound(fn)
        local w = W.active
        return function(...) return W.Run(w, fn, ...) end
    end
    function W.AnyShown() return true end
    function W.ShowingNote(id) return id == 1 and main or nil end
    function W.Focused() return main end
    function W.ListFollows() W.followed = W.followed + 1 end
    local UI = { _notes = { frame = frame }, overlays = 0, reloads = 0, menus = {} }
    function UI:EnsureEasyNotesFrame() return frame end
    function UI:CloseEasyNotesOpenMenus() return false end
    function UI:QueueEasyNotesOverlayUpdate() self.overlays = self.overlays + 1 end
    function UI:RefreshEasyNotes() self.reloads = self.reloads + 1 end
    function UI:ShowEasyNotesMenu(name, rows) self.menus[#self.menus + 1] = { name = name, rows = rows } end
    function UI:ShowNotesTipDelayed() end
    function UI:HideNotesTip() end
    notesNS.UI, notesNS.Windows = UI, W
    notesNS.SelectedNote = function() return note end
    notesNS.AllNotes = function() return { note } end
    notesNS.Refresh = function() UI.refreshes = (UI.refreshes or 0) + 1 end
    assert(loadfile(H.ADDON_ROOT .. "/Apps/Notes/Lines.lua", "t", env))("EasyFind_Notes", notesNS)
    t.env, t.ns, t.UI, t.W, t.editor, t.frame, t.notesNS = env, ns, UI, W, editor, frame, notesNS
    return notesNS.Lines, note, CK, t
end

local function IDs(note)
    local out = {}
    for i, line in ipairs(note.list.lines) do out[i] = line.id end
    return table.concat(out, " ")
end

-- The box glyph of each line, as the editor's layout hands them over.
local function Positions(CK, body)
    local positions = {}
    for i, f in ipairs(CK.BodyLines(body)) do
        positions[#positions + 1] = { byteStart = f.start, line = i, isPrefix = true, glyph = CK.EMPTY:sub(1, 3) }
    end
    return positions
end

local tests = {}

function tests.aBoxPress_ticksAHandLine_neverAGameLine()
    local Lines, note, CK, t = Load()
    note.body = CK.EMPTY .. "A\n" .. CK.EMPTY .. "B"
    CK.Reconcile(note)
    local b = note.list.lines[2]
    b.link, b.quest = "quest", 9
    H.assertFalse(Lines.ToggleAt(note, CK.LineStart(note, b.id)), "the game ticks that one")
    H.assertTrue(Lines.ToggleAt(note, 1))
    H.assertTrue(CK.Ticked(note, note.list.lines[1], "Me-Realm"))
    H.assertEq(t.UI.overlays, 1, "drawn again")
    H.assertEq(t.UI.refreshes, 1, "the list's preview follows")
    H.assertTrue(Lines.ToggleAt(note, 1))
    H.assertFalse(CK.Ticked(note, note.list.lines[1], "Me-Realm"))
    H.assertEq(Lines.TickedAt(t.editor, 1), false)
    H.assertNil(Lines.TickedAt(Stub(), 1), "another editor: not ours")
end

function tests.aTickedLine_readsStruckAndGreen()
    local Lines, note, CK, t = Load()
    note.body = CK.EMPTY .. "Done\n" .. CK.EMPTY .. "Open"
    CK.Reconcile(note)
    Lines.ToggleAt(note, 1)
    local decos = Lines.WithTicks(t.editor, note.body, note.decorations)
    H.assertEq(#note.decorations, 2, "the note's own untouched")
    H.assertEq(#decos, 4)
    H.assertEq(decos[3].kind, "strike")
    H.assertEq(decos[3].startByte, #CK.EMPTY + 1)
    H.assertEq(decos[3].endByte, #CK.EMPTY + #"Done" + 1)
    H.assertEq(decos[4].kind, "color")
    H.assertTrue(decos[4].g > decos[4].r, "green")
end

function tests.tails_oneALine_theCountOnACountedOne()
    local Lines, note, CK, t = Load()
    CK.AppendLine(note, { text = "Repair" })
    CK.AppendLine(note, { link = "item", item = 7, target = 2 })
    Lines.PlaceTails(t.editor, Positions(CK, note.body), { 0, 14 }, 14)
    local tails = Lines.States[t.W.main].tails
    H.assertEq(#tails, 2)
    H.assertEq(tails[1].text._text, "", "a hand line: the X alone")
    H.assertFalse(tails[1].icon._shown)
    H.assertEq(tails[2].text._text, "0/2", "the count")
    H.assertTrue(tails[2].icon._shown, "and the item's icon")
    H.assertEq(tails[2]._points[1][5], -14, "on its line")
    H.assertEq(tails[2].line, note.list.lines[2])
    Lines.PlaceTails(t.editor, nil)
    H.assertFalse(tails[1]._shown)
end

function tests.theX_dropsTheLine_theMarksAfterItMove()
    local Lines, note, CK, t = Load()
    note.body = CK.EMPTY .. "A\n" .. CK.EMPTY .. "B\n" .. CK.EMPTY .. "C"
    CK.Reconcile(note)
    Lines.Remove(note, note.list.lines[2])
    H.assertEq(note.body, CK.EMPTY .. "A\n" .. CK.EMPTY .. "C")
    H.assertEq(IDs(note), "1 3")
    H.assertEq(CK.LineStart(note, 3), #CK.EMPTY + 3, "C's mark moved up")
    H.assertEq(t.UI.reloads, 1, "the window draws the note again")
    H.assertEq(t.W.followed, 1)
    Lines.Remove(note, note.list.lines[2])
    H.assertEq(note.body, CK.EMPTY .. "A", "the last line goes with its newline")
    H.assertEq(IDs(note), "1")
end

function tests.wordsAdded_fillAnEmptyLastLine_elseANewOne()
    local Lines, note, CK = Load()
    note.body = CK.EMPTY .. "A\n" .. CK.EMPTY
    CK.Reconcile(note)
    Lines.AddWords(note, "Thing")
    H.assertEq(note.body, CK.EMPTY .. "A\n" .. CK.EMPTY .. "Thing")
    H.assertEq(#note.list.lines, 2)
    Lines.AddWords(note, LINK)
    H.assertEq(#note.list.lines, 3)
    H.assertEq(note.list.lines[3].item, 2589, "a link: that item")
end

function tests.aShiftClickedLink_atTheCaret_orAsALine()
    local Lines, note, CK, t = Load()
    note.body = CK.EMPTY .. "A"
    CK.Reconcile(note)
    t.editor._focus = true
    t.insertLink(LINK)
    H.assertEq(t.editor._inserted, LINK, "typing: into the words at the caret")
    H.assertEq(#note.list.lines, 1)
    t.editor._focus = false
    t.insertLink(LINK)
    H.assertEq(#note.list.lines, 2, "not typing: a line under the last")
    H.assertEq(note.list.lines[2].item, 2589)
    H.assertTrue(Lines ~= nil)
end

function tests.theMenu_trackFirst_theTicksSettingsWithLines()
    local Lines, note, CK = Load()
    local rows = Lines.MenuRows(note, Stub())
    H.assertEq(#rows, 1, "no lines yet: what a line can track")
    H.assertEq(rows[1].text, "CHECK_TRACK")
    H.assertEq(#rows[1].submenu, 8, "an item count, a quest, a reputation, gold, a level, a skill, a lockout, a cooldown")
    CK.AppendLine(note, { text = "A" })
    rows = Lines.MenuRows(note, Stub())
    H.assertEq(#rows, 6)
    H.assertEq(rows[3].text, "CHECK_SCOPE_FMT")
    H.assertEq(rows[4].text, "CHECK_RESET_ROW")
    H.assertEq(rows[5].text, "CHECK_BOARD")
    H.assertEq(rows[6].text, "CHECK_SEARCH_AH")
    H.assertTrue(rows[6].disabled, "no house open")
end

function tests.aLinkedListsExtension_hearsOfAChange_onceItSettles()
    local Lines, note, CK, t = Load()
    note.list.source = { ext = "Shop", key = "k" }
    t.ns.ChecklistLinks = { Shop = { items = true } }
    local told = 0
    t.notesNS.LinkedChanged = function(n) if n == note then told = told + 1 end end
    note.body = CK.EMPTY .. "Linen"
    Lines.BodyChanged(note)
    note.body = CK.EMPTY .. "Linen Cloth"
    Lines.BodyChanged(note)
    H.assertEq(told, 0, "not yet")
    for _, timer in ipairs(t.timers) do timer.fn() end
    H.assertEq(told, 1, "once for the two keystrokes")
end

-- A list of items: the catalog's names under the line typed, Tab takes
-- the pick with the count kept, Escape puts the names away before the
-- editor's menus.
function tests.aListOfItems_suggestsNames_tabTakesThePick()
    local Lines, note, CK, t = Load()
    note.list.source = { ext = "Shop", key = "k" }
    t.ns.ChecklistLinks = { Shop = { items = true } }
    t.ns.StyleMenuPanel = function() end
    t.ns.Utils.InstallMenuRowHighlight = function(row) row.SetMenuHighlightFocused = function(self, on) self._picked = on end end
    t.ns.Database = { ScoreName = function() return 100 end }
    t.ns.ItemSearch = { Search = function() return { { data = { itemID = 2589, nameLower = "linen cloak", name = "linen cloak" } } } end }
    note.body = CK.EMPTY .. "lin x20"
    CK.Reconcile(note)
    t.editor._text, t.editor._focus = note.body, true
    t.editor.GetCursorPosition = function() return #note.body end
    t.UI:EnsureEasyNotesFrame()
    H.assertTrue(t.editor._efLinesHooked, "the editor hooked as its window is made")
    Lines.PlaceTails(t.editor, Positions(CK, note.body), { 0 }, 14)
    t.editor._scripts.OnTextChanged(t.editor, true)
    for _, timer in ipairs(t.timers) do timer.fn() end
    local panel = Lines.States[t.W.main].suggest
    H.assertTrue(panel ~= nil and panel._shown, "the names show under the line")
    H.assertEq(panel.rows[1].itemID, 2589)
    H.assertTrue(panel.rows[1]._picked, "the first picked")
    H.assertTrue(t.UI:CloseEasyNotesOpenMenus(), "Escape takes the names first")
    H.assertFalse(panel._shown)
    t.editor._scripts.OnTextChanged(t.editor, true)
    for _, timer in ipairs(t.timers) do timer.fn() end
    H.assertTrue(panel._shown)
    t.editor._scripts.OnTabPressed(t.editor)
    H.assertEq(t.editor._text, CK.EMPTY .. "Item2589 x20", "Tab: the pick's words, the count kept")
    H.assertFalse(panel._shown)
    t.editor._scripts.OnTextChanged(t.editor, false)
    H.assertFalse(panel._shown, "words set by the code show no names")
end

local pass, fail, failures = H.runSuite("NotesLines", tests)
return { pass = pass, fail = fail, failures = failures }
