-- Tests for Apps/Notes/Checklist.lua: a note's checkbox lines as its list.
-- The words are the note's text; each box line carries its id in a "line"
-- decoration and its fields (item, link, count) on note.list by that id.

local H = require("Harness")

local LINK5 = "|cff1eff00|Hitem:5::|h[Thing]|h|r"

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

local function NewNote(CK, scope)
    local note = { id = 1, body = "", decorations = {} }
    CK.Init(note)
    note.list.scope = scope or "account"
    return note
end

-- The body's line marks: "id@start" each, in order.
local function Marks(note)
    local out = {}
    for _, d in ipairs(note.decorations) do
        if d.kind == "line" then out[#out + 1] = d.id .. "@" .. d.startByte end
    end
    return table.concat(out, " ")
end

local function IDs(note)
    local out = {}
    for i, line in ipairs(note.list.lines) do out[i] = line.id end
    return table.concat(out, " ")
end

local tests = {}

-- The model's box glyphs are the editor's.
function tests.theBoxGlyphsAreTheEditors()
    local CK = Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Notes/Notes.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local empty = assert(load("return " .. src:match("\nlocal CHECK_EMPTY_PREFIX = ([^\n]+)")))()
    local filled = assert(load("return " .. src:match("\nlocal CHECK_FILLED_PREFIX = ([^\n]+)")))()
    H.assertEq(CK.EMPTY, empty)
    H.assertEq(CK.FILLED, filled)
    H.assertEq(#CK.EMPTY, #CK.FILLED, "the same bytes long: a migration moves nothing")
end

function tests.handTicks_followTheListScope()
    local CK = Load()
    local note = NewNote(CK, "character")
    local line = CK.AppendLine(note, { text = "Repair" })
    CK.SetTicked(note, line, "A-Realm", true)
    H.assertTrue(CK.Ticked(note, line, "A-Realm"))
    H.assertFalse(CK.Ticked(note, line, "B-Realm"), "per character")
    note.list.scope = "account"
    CK.SetTicked(note, line, "A-Realm", true)
    H.assertTrue(CK.Ticked(note, line, "B-Realm"), "account wide")
end

function tests.itemLine_countsBagsBankAndOtherCharacters()
    local CK, w = Load()
    local note = NewNote(CK, "account")
    local line = CK.AppendLine(note, { link = "item", item = 13468, target = 10 })
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
    local note = NewNote(CK, "character")
    local line = CK.AppendLine(note, { link = "item", item = 1, target = 5 })
    w.bags[1] = 2
    w.stored[1] = { ["Alt-Realm"] = { bags = 9, bank = 0 } }
    local _, progress = CK.LineState(note, line)
    H.assertEq(progress, "2/5")
end

function tests.dailyReset_clearsTicksOnceAfterItPasses()
    local CK, w = Load()
    local note = NewNote(CK)
    note.list.reset.every = "daily"
    local line = CK.AppendLine(note, { text = "Daily quest" })
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
    local note = NewNote(CK, "character")
    local line = CK.AppendLine(note, { link = "item", item = 1, target = 1 })
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

function tests.goldLine_accountSumsTheLedger()
    local CK, w, env = Load()
    local note = NewNote(CK, "account")
    local line = CK.AppendLine(note, { link = "gold", target = 100 * 10000 })
    w.money = 40 * 10000
    env.EasyFindDB = { charGold = { ["Alt-Realm"] = 70 * 10000, ["Tester-Realm"] = 40 * 10000 } }
    local done, progress = CK.LineState(note, line)
    H.assertTrue(done)
    H.assertEq(progress, "110g/100g")
end

-- The words are the note: a line appended writes "box words" under the
-- last, marked with its id; the mark finds the line again.
function tests.appendLine_writesTheWordsAndMarksTheLine()
    local CK = Load()
    local note = NewNote(CK)
    local a = CK.AppendLine(note, { text = "Repair" })
    local b = CK.AppendLine(note, { link = "item", item = 7, target = 2 })
    H.assertEq(note.body, CK.EMPTY .. "Repair\n" .. CK.EMPTY .. "Item7 x2")
    H.assertEq(Marks(note), "1@1 2@" .. (#CK.EMPTY + #"Repair" + 2))
    H.assertEq(CK.LineAt(note, 1), a)
    H.assertEq(CK.LineAt(note, CK.LineStart(note, b.id)), b)
    H.assertEq(b.link, "item")
    H.assertEq(b.target, 2, "the count read back from the words")
    H.assertTrue(CK.Is(note))
    H.assertTrue(CK.IsList(note), "every line a box line")
    H.assertEq(CK.Preview(note), "CHECK_PREVIEW_FMT", "the list's own preview (its words, on the harness)")
    note.body = "Shopping\n" .. note.body
    for _, d in ipairs(note.decorations) do d.startByte, d.endByte = d.startByte + 9, d.endByte + 9 end
    CK.Reconcile(note)
    H.assertFalse(CK.IsList(note), "words above the lines: a note with a list in it")
end

-- Typing around the lines keeps their ids: the marks move with the words
-- as the editor shifts them; a line typed in between is new.
function tests.reconcile_keepsIdsThroughEdits()
    local CK = Load()
    local note = NewNote(CK)
    CK.AppendLine(note, { text = "A" })
    CK.AppendLine(note, { text = "B" })
    H.assertEq(IDs(note), "1 2")
    local bStart = CK.LineStart(note, 2)
    -- A new box line typed between A and B: B's mark moved past it.
    local inserted = CK.EMPTY .. "New\n"
    note.body = note.body:sub(1, bStart - 1) .. inserted .. note.body:sub(bStart)
    for _, d in ipairs(note.decorations) do
        if d.startByte >= bStart then d.startByte, d.endByte = d.startByte + #inserted, d.endByte + #inserted end
    end
    H.assertTrue(CK.Reconcile(note))
    H.assertEq(IDs(note), "1 3 2", "A and B keep their ids, the new line takes the next")
    H.assertEq(note.list.lines[2].text, "New")
    H.assertFalse(CK.Reconcile(note), "nothing changed: nothing to tell")
    -- Words added to B.
    note.body = note.body .. " done"
    H.assertTrue(CK.Reconcile(note))
    H.assertEq(note.list.lines[3].text, "B done")
end

function tests.reconcile_aLineGoneTakesItsTicks_aBoxMovedOffALineStartIsNoLine()
    local CK = Load()
    local note = NewNote(CK)
    local a = CK.AppendLine(note, { text = "A" })
    local b = CK.AppendLine(note, { text = "B" })
    CK.SetTicked(note, b, "X-Realm", true)
    -- B's line deleted from the body, its mark with it.
    local bStart = CK.LineStart(note, b.id)
    note.body = note.body:sub(1, bStart - 2)
    for i = #note.decorations, 1, -1 do
        if note.decorations[i].startByte >= bStart then table.remove(note.decorations, i) end
    end
    CK.Reconcile(note)
    H.assertEq(IDs(note), "1")
    H.assertNil(note.list.ticks.account[b.id], "its tick went with it")
    -- The newline before A's box gone: the box sits inside a line now.
    note.body = "Words " .. note.body
    for _, d in ipairs(note.decorations) do d.startByte, d.endByte = d.startByte + 6, d.endByte + 6 end
    CK.Reconcile(note)
    H.assertEq(IDs(note), "", "no box at a line's start: no line")
    H.assertEq(Marks(note), "", "its mark gone too")
    H.assertFalse(CK.Is(note))
    H.assertTrue(a ~= nil)
end

-- What the words say a line is.
function tests.readContent_linksCountsAndNames()
    local CK, _, env = Load()
    local note = NewNote(CK)
    note.body = CK.EMPTY .. LINK5 .. " x20\n" .. CK.EMPTY .. "Repair 2\n" .. CK.EMPTY .. "|Hquest:4321:60|h[Quest]|h\n"
        .. CK.EMPTY .. "|Hspell:18560:0|h[Mooncloth]|h"
    CK.Reconcile(note)
    local lines = note.list.lines
    H.assertEq(lines[1].item, 5)
    H.assertEq(lines[1].link, "item", "a count after a link: counted toward it")
    H.assertEq(lines[1].target, 20)
    H.assertNil(lines[1].text)
    H.assertEq(lines[2].text, "Repair 2", "plain words stay as typed, number and all")
    H.assertNil(lines[2].target)
    H.assertEq(lines[3].link, "quest")
    H.assertEq(lines[3].quest, 4321)
    H.assertNil(lines[4].link, "a spell's link is words; a cooldown is tracked on purpose")
    -- The link's count changed in the words.
    note.body = note.body:gsub("x20", "x7")
    CK.Reconcile(note)
    H.assertEq(lines[1].target, 7)
    -- The link taken out, the item's plain name left: still the item.
    local plain = CK.EMPTY .. "Item5 x3"
    local firstLen = note.body:find("\n", 1, true) - 1
    note.body = plain .. note.body:sub(firstLen + 1)
    local shift = #plain - firstLen
    for _, d in ipairs(note.decorations) do
        if d.startByte > 1 then d.startByte, d.endByte = d.startByte + shift, d.endByte + shift end
    end
    CK.Reconcile(note)
    H.assertEq(lines[1].item, 5, "its own name typed plain keeps the item")
    H.assertEq(lines[1].target, 3)
    H.assertTrue(env ~= nil)
end

function tests.readContent_aListOfItemsLooksNamesUpOnceSettled()
    local CK, _, env = Load()
    local ids = { ["Linen Cloak"] = 2589, ["Net-o-Matic 5000"] = 4 }
    env.C_Item.GetItemInfoInstant = function(name) return ids[name] end
    local note = NewNote(CK)
    note.list.source = { ext = "Shop", key = "k" }
    env.EasyFind._ns.ChecklistLinks = { Shop = { items = true } }
    note.body = CK.EMPTY .. "Linen Cloak x20\n" .. CK.EMPTY .. "Net-o-Matic 5000\n" .. CK.EMPTY .. "Mystery 3"
    CK.Reconcile(note)
    local lines = note.list.lines
    H.assertEq(lines[1].text, "Linen Cloak", "while typing: words and a count")
    H.assertEq(lines[1].target, 20)
    CK.Reconcile(note, true)
    H.assertEq(lines[1].item, 2589, "settled: the item named")
    H.assertEq(lines[1].link, "item")
    H.assertEq(lines[1].target, 20)
    H.assertEq(lines[2].item, 4, "a name ending in a number is the item")
    H.assertNil(lines[2].target)
    H.assertEq(lines[3].text, "Mystery", "an unknown name keeps its count")
    H.assertEq(lines[3].target, 3)
end

function tests.readContent_aTrackedLineKeepsItsLink_theWordsRenameIt()
    local CK = Load()
    local note = NewNote(CK)
    local q = CK.AppendLine(note, { link = "quest", quest = 9, text = "Quest" })
    H.assertEq(note.body, CK.EMPTY .. "Quest")
    note.body = CK.EMPTY .. "Quest, the hard part"
    CK.Reconcile(note)
    H.assertEq(q.link, "quest")
    H.assertEq(q.quest, 9)
    H.assertEq(q.text, "Quest, the hard part")
    H.assertEq(CK.LineName(q), "Quest, the hard part")
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
    for _, typed in ipairs({ LINK5 .. "x20", LINK5 .. " x20", LINK5 .. " 20", LINK5 .. "*20", "20x" .. LINK5, "20 " .. LINK5 }) do
        local words, n = CK.SplitCount(typed)
        H.assertEq(words, LINK5, typed)
        H.assertEq(n, 20, typed)
    end
    H.assertEq(select(2, CK.SplitCount("Onyx x3")), 3)
    H.assertEq((CK.SplitCount("Onyx x3")), "Onyx", "a name ending in x keeps it")
    H.assertEq(select(2, CK.SplitCount("Linen Cloak")), nil)
    H.assertEq(select(2, CK.SplitCount("20")), nil, "a number alone is the words")
    H.assertEq(select(2, CK.SplitCount("Bandage 0")), nil, "no count of 0")
end

function tests.setCount_givesOrTakesTheCount_pickedTextIsTheItemsLink()
    local CK = Load()
    local line = { item = 1 }
    CK.SetCount(line, 4)
    H.assertEq(line.link, "item")
    H.assertEq(line.target, 4)
    H.assertEq(CK.EditText(line), "Item1 x4", "typed as its name and count")
    CK.SetCount(line, 0)
    H.assertEq(line.link, nil)
    H.assertEq(line.target, nil)
    H.assertFalse(CK.HasCount({ link = "gold", target = 100 }), "gold keeps its own menu")
    H.assertEq(CK.PickedText("lin x3", 9), "Item9 x3", "the pick's words, the count kept")
end

-- A note linked to an extension's list (an Auctionator shopping list,
-- 2026-10-26): the list's entries in, matched by ref, ticks kept; the
-- body is then the lines.
function tests.linked_entriesComeInByRef()
    local CK = Load()
    local note = NewNote(CK, "account")
    local changed = CK.SyncLinked(note, {
        { ref = "\"Linen Cloth\";;;;;;;;;;;;;;20", line = { link = "item", item = 2589, target = 20 } },
        { ref = "Dust", line = { text = "Dust" } },
    })
    H.assertTrue(changed)
    local lines = note.list.lines
    H.assertEq(#lines, 2)
    H.assertEq(lines[1].target, 20, "the entry's amount is the line's target")
    H.assertEq(lines[2].text, "Dust")
    H.assertEq(note.body, CK.EMPTY .. "Item2589 x20\n" .. CK.EMPTY .. "Dust", "the body is the lines")
    H.assertEq(Marks(note), "1@1 2@" .. (#CK.EMPTY + #"Item2589 x20" + 2))
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
    local note = NewNote(CK, "account")
    CK.SyncLinked(note, { { ref = "A", line = { text = "A" } }, { ref = "B", line = { text = "B" } } })
    local b = note.list.lines[2]
    CK.SetTicked(note, note.list.lines[1], "A-Realm", true)
    local aID = note.list.lines[1].id
    -- Typed here, not in the list yet: it stays, after the list's lines.
    CK.AppendLine(note, { text = "Mine" })
    CK.SyncLinked(note, { { ref = "B", line = { text = "B", target = 5 } }, { ref = "C", line = { text = "C" } } })
    local names = {}
    for i, line in ipairs(note.list.lines) do names[i] = line.text end
    H.assertEq(table.concat(names, " "), "B C Mine", "B first, C new, A gone, the pending line kept")
    H.assertTrue(note.list.lines[1] == b, "B keeps its line")
    H.assertEq(b.target, 5, "and takes the entry's fields")
    H.assertNil((note.list.ticks.account or {})[aID], "a dropped line's tick goes with it")
    H.assertEq(note.body, CK.EMPTY .. "B x5\n" .. CK.EMPTY .. "C\n" .. CK.EMPTY .. "Mine", "the body is the lines, a count in the words")
end

-- Notes of the old checklist kind become text, their lines as box lines
-- with their ids and ticks; a box ticked in the words opens, its tick on
-- the list.
function tests.migrate_theOldKindAndTickedBoxes()
    local CK = Load()
    local old = { id = 1, kind = "checklist", body = "Item7\nRepair",
        list = { scope = "account", lines = { { id = 4, link = "item", item = 7, target = 2 }, { id = 9, text = "Repair" } },
                 ticks = { account = { [9] = true } }, seen = {}, resetAt = {}, nextLine = 10, reset = { every = "never" } } }
    H.assertTrue(CK.Migrate(old, "Me-Realm"))
    H.assertNil(old.kind)
    H.assertEq(old.body, CK.EMPTY .. "Item7 x2\n" .. CK.EMPTY .. "Repair")
    H.assertEq(IDs(old), "4 9", "the ids stay")
    H.assertTrue(CK.Ticked(old, old.list.lines[2], "Me-Realm"), "the tick stays")
    H.assertFalse(CK.Migrate(old, "Me-Realm"), "done once")
    local ticked = { id = 2, body = CK.FILLED .. "Done\n" .. CK.EMPTY .. "Open\nwords " .. CK.FILLED .. "not a box",
        decorations = { { kind = "strike", startByte = 5, endByte = 9 } } }
    H.assertTrue(CK.Migrate(ticked, "Me-Realm"))
    H.assertEq(ticked.body, CK.EMPTY .. "Done\n" .. CK.EMPTY .. "Open\nwords " .. CK.EMPTY .. "not a box", "every ticked glyph opens")
    H.assertEq(IDs(ticked), "1 2", "two lines; the glyph inside words is none")
    H.assertTrue(CK.Ticked(ticked, ticked.list.lines[1], "Me-Realm"), "the first was ticked")
    H.assertFalse(CK.Ticked(ticked, ticked.list.lines[2], "Me-Realm"))
    H.assertEq(#ticked.decorations, 2, "the tick's strike went; two line marks stand")
end

local pass, fail, failures = H.runSuite("Checklists", tests)
return { pass = pass, fail = fail, failures = failures }
