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
    H.assertEq(CK.LineFromLink("|cff1eff00|Hitem:13468::::|h[Black Lotus]|h|r").item, 13468)
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
    }
    local t = { _scripts = {} }
    return setmetatable(t, { __index = function(_, k)
        if special[k] then return special[k] end
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
        UI = { _notes = { frame = { editorScroll = Stub(), toolbar = Stub(), charCounter = Stub(), formatButton = Stub() } } },
        SelectedNote = function() return note end,
        AllNotes = function() return { note } end,
    }
    assert(loadfile(H.ADDON_ROOT .. "/Apps/Notes/ChecklistView.lua", "t", env))("EasyFind_Notes", notesNS)
    return notesNS.ChecklistView, note, w, made
end

function tests.view_buildsTheListAndTheBoard()
    local View, note, w = LoadView({ { text = "Plain" }, { link = "item", item = 1, target = 2 }, { link = "quest", quest = 9 },
        { link = "rep", faction = 72, standing = 8 }, { link = "gold", target = 10000 }, { link = "level", target = 40 },
        { link = "skill", skill = "Tailoring", target = 300 }, { link = "lockout", instance = "Molten Core" },
        { link = "cooldown", spell = 18560 } })
    View.SetAllowed(true)
    w.insert("|Hitem:5:0|h[Thing]|h")
    H.assertEq(#note.list.lines, 10, "a shift-clicked item joined the list")
    View.ShowBoard(true)
    View.ShowBoard(false)
    View.Sweep()
    View.SetAllowed(false)
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

local pass, fail, failures = H.runSuite("Checklists", tests)
return { pass = pass, fail = fail, failures = failures }
