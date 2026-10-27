-- Tests for Apps/Notes/Checklist.lua: checklist notes in Notes.

local H = require("Harness")

local function Load()
    local env = H.newEnv()
    env._G = env
    local w = { bags = {}, bank = {}, stored = {}, resetLeft = 3600, region = 1, money = 0 }
    env.UnitName = function() return "Tester" end
    env.GetUnitName = function() return "Tester" end
    env.GetRealmName = function() return "Realm" end
    env.C_Item = {
        GetItemCount = function(id, withBank)
            return (w.bags[id] or 0) + (withBank and (w.bank[id] or 0) or 0)
        end,
        GetItemNameByID = function(id) return "Item" .. id end,
    }
    env.GetQuestResetTime = function() return w.resetLeft end
    env.GetCurrentRegion = function() return w.region end
    env.GetMoney = function() return w.money end
    env.date = os.date
    env.time = function(t) if t then return os.time(t) end return w.now or os.time() end
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    env.GetBuildInfo = function() return "12.0.5", "1", "", 120005 end
    H.loadModule("Shared/Caps.lua", env, ns)
    ns.StoredItemCounts = function(id) return w.stored[id] end
    local notesNS = { Context = {} }
    assert(loadfile(H.ADDON_ROOT .. "/Apps/Notes/Checklist.lua", "t", env))("EasyFind_Notes", notesNS)
    return notesNS.Checklist, w, env
end

local function NewList(CK, scope)
    local note = { id = 1 }
    CK.Init(note)
    note.list.scope = scope or "account"
    return note
end

local tests = {}

function tests.handTicks_followTheListScope()
    local CK = Load()
    local note = NewList(CK, "character")
    local line = CK.AddLine(note, { text = "Repair" })
    CK.SetTicked(note, line, "A-Realm", true)
    H.assertTrue(CK.Ticked(note, line, "A-Realm"))
    H.assertFalse(CK.Ticked(note, line, "B-Realm"), "per character")
    note.list.scope = "account"
    CK.SetTicked(note, line, "A-Realm", true)
    H.assertTrue(CK.Ticked(note, line, "B-Realm"), "account wide")
end

function tests.itemLine_countsBagsBankAndOtherCharacters()
    local CK, w = Load()
    local note = NewList(CK, "account")
    local line = CK.AddLine(note, { link = "item", item = 13468, target = 10 })
    w.bags[13468], w.bank[13468] = 4, 2
    w.stored[13468] = { ["Alt-Realm"] = { bags = 3, bank = 0 }, ["Tester-Realm"] = { bags = 4, bank = 2 } }
    local done, progress, detail = CK.LineState(note, line)
    H.assertFalse(done)
    H.assertEq(progress, "9/10")
    H.assertTrue(detail:find("Alt 3", 1, true) ~= nil, detail)
    w.bags[13468] = 5
    H.assertTrue((CK.LineState(note, line)))
end

function tests.itemLine_perCharacterListCountsOnlyThisCharacter()
    local CK, w = Load()
    local note = NewList(CK, "character")
    local line = CK.AddLine(note, { link = "item", item = 1, target = 5 })
    w.bags[1] = 2
    w.stored[1] = { ["Alt-Realm"] = { bags = 9, bank = 0 } }
    local _, progress = CK.LineState(note, line)
    H.assertEq(progress, "2/5")
end

function tests.dailyReset_clearsTicksOnceAfterItPasses()
    local CK, w = Load()
    local note = NewList(CK)
    note.list.reset.every = "daily"
    local line = CK.AddLine(note, { text = "Daily quest" })
    local now = 1800000000
    w.resetLeft = 3600
    CK.SetTicked(note, line, "A-Realm", true)
    note.list.resetAt.account = now - 100
    H.assertFalse(CK.ApplyReset(note, now), "ticked after the last reset")
    H.assertTrue(CK.Ticked(note, line, "A-Realm"))
    -- An hour later the reset went by.
    w.resetLeft = 86400
    H.assertTrue(CK.ApplyReset(note, now + 3600))
    H.assertFalse(CK.Ticked(note, line, "A-Realm"))
end

function tests.weeklyReset_landsOnTheRegionWeekday()
    local CK, w = Load()
    local now = os.time({ year = 2026, month = 10, day = 15, hour = 12 })
    w.resetLeft = 3 * 3600
    w.region = 1
    local at = CK.LastReset({ every = "weekly" }, now)
    H.assertEq(os.date("!*t", at).wday, 3, "US: Tuesday")
    w.region = 3
    H.assertEq(os.date("!*t", CK.LastReset({ every = "weekly" }, now)).wday, 4, "EU: Wednesday")
end

function tests.chosenDays_lastPassedDayAndTime()
    local CK = Load()
    local now = os.time({ year = 2026, month = 10, day = 14, hour = 10 })
    local at = CK.LastReset({ every = "days", days = { [2] = true }, hour = 6, min = 0 }, now)
    local t = os.date("*t", at)
    H.assertEq(t.wday, 2)
    H.assertEq(t.hour, 6)
    H.assertTrue(at <= now)
end

function tests.board_listsEveryCharacterThatReadTheList()
    local CK, w = Load()
    local note = NewList(CK, "character")
    local line = CK.AddLine(note, { link = "item", item = 1, target = 1 })
    w.bags[1] = 1
    CK.LineState(note, line)
    note.list.seen["Alt-Realm"] = { [line.id] = { p = "0/1" } }
    local chars = CK.Board(note)
    H.assertEq(#chars, 2)
    local done, progress = CK.BoardCell(note, line, "Alt-Realm")
    H.assertFalse(done)
    H.assertEq(progress, "0/1")
    H.assertTrue((CK.BoardCell(note, line, "Tester-Realm")))
end

function tests.linksBecomeLines()
    local CK = Load()
    local item = CK.LineFromLink("|cff1eff00|Hitem:13468::::|h[Black Lotus]|h|r")
    H.assertEq(item.item, 13468)
    H.assertNil(item.link, "ticked by hand: it came from the bags it would count")
    H.assertEq(CK.LineFromLink("|Hquest:4321:60|h[Quest]|h").quest, 4321)
    H.assertEq(CK.LineFromLink("|Hspell:18560:0|h[Mooncloth]|h").link, "cooldown")
    H.assertNil(CK.LineFromLink("plain words"))
end

function tests.insertLine_goesAfterTheLineNamed()
    local CK = Load()
    local note = NewList(CK)
    local a = CK.AddLine(note, { text = "A" })
    CK.AddLine(note, { text = "C" })
    CK.InsertLine(note, { text = "B" }, a.id)
    H.assertEq(note.body, "A\nB\nC")
end

function tests.body_mirrorsLineNamesForSearch()
    local CK = Load()
    local note = NewList(CK)
    CK.AddLine(note, { text = "Repair" })
    CK.AddLine(note, { link = "item", item = 7, target = 2 })
    H.assertEq(note.body, "Repair\nItem7")
    CK.RemoveLine(note, 1)
    H.assertEq(note.body, "Item7")
end

function tests.goldLine_accountSumsTheLedger()
    local CK, w, env = Load()
    local note = NewList(CK, "account")
    local line = CK.AddLine(note, { link = "gold", target = 100 * 10000 })
    w.money = 40 * 10000
    env.EasyFindDB = { charGold = { ["Alt-Realm"] = 70 * 10000, ["Tester-Realm"] = 40 * 10000 } }
    local done, progress = CK.LineState(note, line)
    H.assertTrue(done)
    H.assertEq(progress, "110g/100g")
end

-- A frame that answers every method: Get* reads 0, the rest do nothing.
local function Stub()
    local special = {
        GetText = function(self) return self._text or "" end,
        SetText = function(self, v) self._text = v end,
        GetChecked = function() return false end,
        IsShown = function(self) return self._shown ~= false end,
        IsVisible = function(self) return self._shown ~= false end,
        Show = function(self) self._shown = true end,
        Hide = function(self) self._shown = false end,
        SetShown = function(self, v) self._shown = v and true or false end,
        CreateFontString = function() return Stub() end,
        CreateTexture = function() return Stub() end,
        GetHighlightTexture = function() return Stub() end,
        SetScript = function(self, name, fn) self._scripts[name] = fn end,
        GetScript = function(self, name) return self._scripts[name] end,
        HasFocus = function() return false end,
        SetPoint = function(self, ...) self._points[#self._points + 1] = { ... } end,
        ClearAllPoints = function(self) self._points = {} end,
    }
    local t = { _scripts = {}, _points = {} }
    return setmetatable(t, { __index = function(_, k)
        if special[k] then return special[k] end
        if k:match("^Get%w*Texture$") then return function() return Stub() end end
        if k:sub(1, 3) == "Get" then return function() return 0 end end
        return function() end
    end })
end

-- The view on stub frames over a list of lines; made: the frames by kind.
local function LoadView(lines)
    local CK, w, env = Load()
    local made = {}
    env.CreateFrame = function(kind)
        local f = Stub()
        made[kind] = made[kind] or {}
        made[kind][#made[kind] + 1] = f
        return f
    end
    local ns = env.EasyFind._ns
    ns.CreateModernButton = function() local b = Stub() b._label = Stub() return b end
    ns.RegisterAddonFont = function() end
    ns.ShowTogglePopup = function() end
    ns.ShowThemedDialog = function() end
    ns.Utils.ShowCursorMenu = function() return Stub() end
    ns.Utils.CreateMinimalScrollBar = function() return Stub() end
    ns.Utils.AttachDelayedTooltip = function() end
    ns.Utils.AddGripDots = function() end
    ns.CreateCloseX = function() return Stub() end
    ns.CreateCogButton = function() return Stub() end
    ns.Utils.HookInsertLink = function(fn) w.insert = fn end
    ns.Utils.HexColorNames = function(s) return s end
    env.C_Spell = { GetSpellName = function() return "Spell" end, GetSpellCooldown = function() return { startTime = 0, duration = 0 } end, GetSpellTexture = function() return 1 end }
    env.C_QuestLog = { GetTitleForQuestID = function() return "Quest" end, IsQuestFlaggedCompleted = function() return false end }
    env.C_Reputation = { GetFactionDataByID = function() return { name = "Faction", reaction = 5 } end }
    env.UnitLevel = function() return 30 end
    env.GetProfessions = function() return nil end
    env.GetNumSavedInstances = function() return 0 end
    env.C_Item.GetItemIconByID = function() return 1 end
    local note = { id = 1, list = nil }
    CK.Init(note)
    for _, line in ipairs(lines) do CK.AddLine(note, line) end
    local notesNS = {
        Checklist = CK, Context = {},
        UI = { _notes = { frame = { editorScroll = Stub(), toolbar = Stub(), charCounter = Stub(), formatButton = Stub(),
            GetFrameLevel = function() return 1 end } } },
        SelectedNote = function() return note end,
        AllNotes = function() return { note } end,
    }
    assert(loadfile(H.ADDON_ROOT .. "/Apps/Notes/ChecklistView.lua", "t", env))("EasyFind_Notes", notesNS)
    return notesNS.ChecklistView, note, w, made, CK, env
end

function tests.view_buildsTheListAndTheBoard()
    local View, note, w, _, CK = LoadView({ { text = "Plain" }, { link = "item", item = 1, target = 2 }, { link = "quest", quest = 9 },
        { link = "rep", faction = 72, standing = 8 }, { link = "gold", target = 10000 }, { link = "level", target = 40 },
        { link = "skill", skill = "Tailoring", target = 300 }, { link = "lockout", instance = "Molten Core" },
        { link = "cooldown", spell = 18560 } })
    View.SetAllowed(true)
    w.insert("|Hitem:5:0|h[Thing]|h")
    H.assertEq(#note.list.lines, 10, "a shift-clicked item joined the list")
    local added = note.list.lines[10]
    H.assertEq(added.item, 5)
    H.assertFalse((CK.LineState(note, added)), "not ticked on arrival")
    View.ShowBoard(true)
    View.ShowBoard(false)
    View.Sweep()
    View.SetAllowed(false)
end

-- The box, grip, icon, name, count and X share the first line's middle,
-- so a line with a detail under it reads as a single line does (2026-10-26).
function tests.view_itemLineDrawsItsIconAndLinkOnTheFirstLine()
    local View, note, _, made, _, env = LoadView({ { link = "item", item = 7, target = 20 } })
    local link = "|cffa335ee|Hitem:7::|h[Item7]|h|r"
    env.C_Item.GetItemInfo = function(id) if id == 7 then return "Item7", link end end
    View.SetAllowed(true)
    local row
    for _, b in ipairs(made.Button) do if b.line == note.list.lines[1] then row = b end end
    H.assertTrue(row ~= nil, "the line has a row")
    H.assertTrue(row.icon._shown, "the item's icon shows")
    H.assertEq(row.name._text, link, "the name is the item's link")
    H.assertEq(row.name._points[1][1], "LEFT")
    H.assertEq(row.name._points[1][2], row.icon, "the name follows the icon, centered on it")
    local mid = row.check._points[1][5]
    for name, part in pairs({ check = row.check, grip = row.grip, count = row.progress, x = row.remove }) do
        local p = part._points[1]
        H.assertTrue(p[2] == row and p[3]:find("^TOP") ~= nil and p[5] == mid,
            name .. " sits on the first line: " .. tostring(p[3]) .. " " .. tostring(p[5]))
    end
end

function tests.lineLabel_drawsItemsAndSpellsAsTheirLinks()
    local CK, _, env = Load()
    env.EasyFind._ns.Utils.HexColorNames = function(s) return (s:gsub("|cnIQ4:", "|cffa335ee")) end
    env.C_Item.GetItemInfo = function(id) if id == 7 then return "Item7", "|cnIQ4:|Hitem:7::|h[Item7]|h|r" end end
    env.C_Spell = { GetSpellLink = function(id) return "|cff71d5ff|Hspell:" .. id .. "|h[Spell]|h|r" end }
    H.assertEq(CK.LineLabel({ item = 7 }), "|cffa335ee|Hitem:7::|h[Item7]|h|r", "an item as its link, quality in hex")
    H.assertEq(CK.LineLabel({ link = "cooldown", spell = 3 }), "|cff71d5ff|Hspell:3|h[Spell]|h|r")
    H.assertEq(CK.LineLabel({ item = 8 }), "Item8", "not in the cache yet: its name")
    H.assertEq(CK.LineLabel({ item = 7, text = "Mine" }), "Mine", "a renamed line keeps its words")
end

-- Every way a count is written after or before the words (2026-10-26).
function tests.splitCount_readsEveryForm()
    local CK = Load()
    for _, typed in ipairs({ "Linen Cloak x20", "Linen Cloak X20", "Linen Cloak x 20", "Linen Cloak*20", "Linen Cloak * 20",
        "Linen Cloak 20", "20x Linen Cloak", "20 x Linen Cloak", "20* Linen Cloak", "20 Linen Cloak", "Linen Cloak \195\15120" }) do
        local words, n = CK.SplitCount(typed)
        H.assertEq(words, "Linen Cloak", typed)
        H.assertEq(n, 20, typed)
    end
    local link = "|cff1eff00|Hitem:5::|h[Thing]|h|r"
    for _, typed in ipairs({ link .. "x20", link .. " x20", link .. " 20", link .. "*20", "20x" .. link, "20 " .. link }) do
        local words, n = CK.SplitCount(typed)
        H.assertEq(words, link, typed)
        H.assertEq(n, 20, typed)
    end
    H.assertEq(select(2, CK.SplitCount("Onyx x3")), 3)
    H.assertEq((CK.SplitCount("Onyx x3")), "Onyx", "a name ending in x keeps it")
    H.assertEq(select(2, CK.SplitCount("Linen Cloak")), nil)
    H.assertEq(select(2, CK.SplitCount("20")), nil, "a number alone is the words")
    H.assertEq(select(2, CK.SplitCount("Bandage 0")), nil, "no count of 0")
end

function tests.typedLine_plainListTakesACountOnlyOnALink()
    local CK = Load()
    H.assertEq(CK.TypedLine("Repair 2", false).text, "Repair 2", "words stay as typed")
    local line = CK.TypedLine("|cff1eff00|Hitem:5::|h[Thing]|h|r x20", false)
    H.assertEq(line.item, 5)
    H.assertEq(line.link, "item", "counted toward its count")
    H.assertEq(line.target, 20)
    H.assertEq(CK.TypedLine("|cff1eff00|Hitem:5::|h[Thing]|h|r", false).link, nil, "no count: ticked by hand")
end

function tests.typedLine_itemListLooksUpNames()
    local CK, _, env = Load()
    local ids = { ["Linen Cloak"] = 2589, ["Net-o-Matic 5000"] = 4 }
    env.C_Item.GetItemInfoInstant = function(name) return ids[name] end
    local line = CK.TypedLine("Linen Cloak x20", true)
    H.assertEq(line.item, 2589)
    H.assertEq(line.target, 20)
    line = CK.TypedLine("Net-o-Matic 5000", true)
    H.assertEq(line.item, 4, "a name ending in a number is the item")
    H.assertEq(line.target, nil)
    line = CK.TypedLine("Mystery 3", true)
    H.assertEq(line.text, "Mystery", "an unknown name keeps its count")
    H.assertEq(line.target, 3)
    H.assertEq(CK.LineState({ list = { ticks = {}, seen = {}, scope = "account" } }, line) == true, false)
end

function tests.retype_keepsTheItemWhenOnlyItsCountChanges()
    local CK = Load()
    local line = { item = 7, link = "item", target = 2 }
    H.assertEq(CK.EditText(line), "Item7 x2", "typed as its name and count")
    CK.Retype(line, "Item7 x5", false)
    H.assertEq(line.item, 7)
    H.assertEq(line.target, 5)
    CK.Retype(line, "Item7", false)
    H.assertEq(line.item, 7)
    H.assertEq(line.link, nil, "no count: ticked by hand")
    CK.Retype(line, "lin x3", true, 9)
    H.assertEq(line.item, 9, "the item picked for the words")
    H.assertEq(line.target, 3)
end

function tests.setCount_givesOrTakesTheCount()
    local CK = Load()
    local line = { item = 1 }
    CK.SetCount(line, 4)
    H.assertEq(line.link, "item")
    H.assertEq(line.target, 4)
    CK.SetCount(line, 0)
    H.assertEq(line.link, nil)
    H.assertEq(line.target, nil)
    H.assertFalse(CK.HasCount({ link = "gold", target = 100 }), "gold keeps its own menu")
end

function tests.view_doubleClickTypesTheCountOverIt()
    local View, note, _, made = LoadView({ { link = "item", item = 1, target = 2 } })
    View.SetAllowed(true)
    local row
    for _, b in ipairs(made.Button) do if b.line == note.list.lines[1] then row = b end end
    H.assertTrue(row.count._shown, "a count to change")
    row.count._scripts.OnDoubleClick(row.count)
    local box
    for _, b in ipairs(made.EditBox or {}) do if b._text == "2" then box = b end end
    H.assertTrue(box ~= nil, "the count in a box")
    box._text = "7"
    box._scripts.OnEditFocusLost(box)
    H.assertEq(note.list.lines[1].target, 7)
end

-- A shopping list's line: the catalog's names under it, the first picked.
function tests.view_itemListSuggestsAndEnterTakesThePick()
    local View, note, _, made, _, env = LoadView({})
    local ns = env.EasyFind._ns
    note.list.source = { ext = "Shop", key = "k" }
    ns.ChecklistLinks = { Shop = { items = true } }
    ns.StyleMenuPanel = function() end
    ns.Utils.InstallMenuRowHighlight = function(row) row.SetMenuHighlightFocused = function(self, on) self._picked = on end end
    ns.Database = { ScoreName = function() return 100 end }
    ns.ItemSearch = { Search = function() return { { data = { itemID = 2589, nameLower = "linen cloak", name = "linen cloak" } } } end }
    View.SetAllowed(true)
    View.AddNew()
    local box = made.EditBox[1]
    box.HasFocus = function() return true end
    box._text = "lin x20"
    box._scripts.OnTextChanged(box, true)
    box._scripts.OnEnterPressed(box)
    local line = note.list.lines[1]
    H.assertEq(line.item, 2589, "the pick")
    H.assertEq(line.target, 20, "with the count typed")
end

function tests.view_escapeKeepsTheWordsAsTyped()
    local View, note, _, made, _, env = LoadView({})
    local ns = env.EasyFind._ns
    note.list.source = { ext = "Shop", key = "k" }
    ns.ChecklistLinks = { Shop = { items = true } }
    ns.StyleMenuPanel = function() end
    ns.Utils.InstallMenuRowHighlight = function(row) row.SetMenuHighlightFocused = function() end end
    ns.Database = { ScoreName = function() return 100 end }
    ns.ItemSearch = { Search = function() return { { data = { itemID = 2589, nameLower = "linen cloak", name = "linen cloak" } } } end }
    View.SetAllowed(true)
    View.AddNew()
    local box = made.EditBox[1]
    box.HasFocus = function() return true end
    box._text = "lin x20"
    box._scripts.OnTextChanged(box, true)
    box._scripts.OnEscapePressed(box)
    box._scripts.OnEnterPressed(box)
    local line = note.list.lines[1]
    H.assertEq(line.text, "lin")
    H.assertEq(line.target, 20)
    H.assertEq(line.item, nil)
end

local function Texts(note)
    local out = {}
    for i, line in ipairs(note.list.lines) do out[i] = line.text or "" end
    return table.concat(out, "|")
end

function tests.view_typesLinesInPlace()
    local View, note, _, made = LoadView({ { text = "Plain" }, { text = "Other" } })
    View.SetAllowed(true)
    View.AddNew()
    local box = made.EditBox and made.EditBox[1]
    H.assertTrue(box ~= nil and box:IsShown(), "a new line opens for typing")
    box:SetText("Bread")
    box._scripts.OnEnterPressed()
    H.assertEq(Texts(note), "Plain|Other|Bread|", "Enter keeps the line and opens one under it")
    box._scripts.OnEnterPressed()
    H.assertEq(Texts(note), "Plain|Other|Bread", "Enter on an empty line stops, the line gone")
    H.assertTrue(not box:IsShown())
    View.Edit(note.list.lines[2].id)
    H.assertEq(box:GetText(), "Other", "a line's words to type over")
    box:SetText("Others")
    box._scripts.OnKeyDown(box, "UP")
    H.assertEq(note.list.lines[2].text, "Others", "moving off keeps the words")
    H.assertEq(box:GetText(), "Plain", "up: the line above")
    box:SetText("")
    box._scripts.OnKeyDown(box, "BACKSPACE")
    H.assertEq(Texts(note), "Others|Bread", "Backspace on an emptied line removes it")
    box._scripts.OnEditFocusLost()
end

-- A checklist linked to an extension's list (an Auctionator shopping list,
-- 2026-10-26): the list's entries in, matched by ref, ticks kept.
function tests.linked_entriesComeInByRef()
    local CK = Load()
    local note = NewList(CK, "account")
    local changed = CK.SyncLinked(note, {
        { ref = "\"Linen Cloth\";;;;;;;;;;;;;;20", line = { link = "item", item = 2589, target = 20 } },
        { ref = "Dust", line = { text = "Dust" } },
    })
    H.assertTrue(changed)
    local lines = note.list.lines
    H.assertEq(#lines, 2)
    H.assertEq(lines[1].target, 20, "the entry's amount is the line's target")
    H.assertEq(lines[2].text, "Dust")
    -- Ticked by hand, then the list again unchanged: nothing moves.
    CK.SetTicked(note, lines[2], "A-Realm", true)
    local dustID = lines[2].id
    H.assertFalse(CK.SyncLinked(note, {
        { ref = "\"Linen Cloth\";;;;;;;;;;;;;;20", line = { link = "item", item = 2589, target = 20 } },
        { ref = "Dust", line = { text = "Dust" } },
    }), "the same list changes nothing")
    H.assertTrue(CK.Ticked(note, note.list.lines[2], "A-Realm"), "the tick stays")
    H.assertEq(note.list.lines[2].id, dustID)
end

function tests.linked_aChangedListMovesAddsAndDrops()
    local CK = Load()
    local note = NewList(CK, "account")
    CK.SyncLinked(note, { { ref = "A", line = { text = "A" } }, { ref = "B", line = { text = "B" } } })
    local b = note.list.lines[2]
    CK.SetTicked(note, note.list.lines[1], "A-Realm", true)
    local aID = note.list.lines[1].id
    -- Made here, not in the list yet: it stays, after the list's lines.
    CK.AddLine(note, { text = "Mine" })
    CK.SyncLinked(note, { { ref = "B", line = { text = "B", target = 5 } }, { ref = "C", line = { text = "C" } } })
    local names = {}
    for i, line in ipairs(note.list.lines) do names[i] = line.text end
    H.assertEq(table.concat(names, " "), "B C Mine", "B first, C new, A gone, the pending line kept")
    H.assertTrue(note.list.lines[1] == b, "B keeps its line")
    H.assertEq(b.target, 5, "and takes the entry's fields")
    H.assertNil((note.list.ticks.account or {})[aID], "a dropped line's tick goes with it")
    H.assertEq(note.body, "B\nC\nMine", "the body mirrors the lines")
end

local pass, fail, failures = H.runSuite("Checklists", tests)
return { pass = pass, fail = fail, failures = failures }
