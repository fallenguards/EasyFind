-- Adding to a note from a result's menu (2026-10-26): a checklist note's
-- body only mirrors its lines, so text appended there never became a line
-- and was overwritten on its next change. A checklist takes a line; any
-- other note carries on the list its last line is in.
local H = require("Harness")

local function Source(path)
    local f = assert(io.open(H.ADDON_ROOT .. path, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local function Cut(src, head)
    local s = assert(src:find(head, 1, true), head)
    local e = select(2, assert(src:find("\nend\r?\n", s)))
    return src:sub(s, e)
end

local NOTES = Source("/Apps/Notes/Notes.lua")

-- The prefixes as the file spells them, then the cut functions over them.
local function LoadNotesPart(env, ...)
    local consts = {}
    for _, name in ipairs({ "BULLET_PREFIX", "CHECK_EMPTY_PREFIX", "CHECK_FILLED_PREFIX" }) do
        consts[#consts + 1] = assert(NOTES:match("\n(local " .. name .. " = [^\n]+)"), name)
    end
    local parts = { table.concat(consts, "\n") }
    for _, head in ipairs({ ... }) do parts[#parts + 1] = Cut(NOTES, head) end
    assert(load(table.concat(parts, "\n"), "=Notes.lua parts", "t", env))()
    return env
end

local function Prefix(name)
    return assert(load("return " .. NOTES:match("\nlocal " .. name .. " = ([^\n]+)")))()
end

local function Checklist()
    local env = H.newEnv()
    env._G = env
    env.UnitName = function() return "Tester" end
    env.GetUnitName = function() return "Tester" end
    env.GetRealmName = function() return "Realm" end
    env.C_Item = { GetItemCount = function() return 0 end, GetItemNameByID = function(id) return "Item" .. id end }
    env.date = os.date
    env.time = os.time
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    env.GetBuildInfo = function() return "12.0.5", "1", "", 120005 end
    H.loadModule("Shared/Caps.lua", env, ns)
    local notesNS = { Context = {} }
    assert(loadfile(H.ADDON_ROOT .. "/Apps/Notes/Checklist.lua", "t", env))("EasyFind_Notes", notesNS)
    return notesNS
end

local tests = {}

function tests.aListEndingTheNoteGoesOn()
    local env = LoadNotesPart({ Fmt = {}, tonumber = tonumber }, "function Fmt.ListMarkAfter(")
    local Mark = env.Fmt.ListMarkAfter
    local bullet, empty, filled = Prefix("BULLET_PREFIX"), Prefix("CHECK_EMPTY_PREFIX"), Prefix("CHECK_FILLED_PREFIX")
    H.assertEq(Mark("Bags\n" .. bullet .. "Cloth\n"), bullet)
    H.assertEq(Mark(filled .. "Done\n"), empty, "a ticked box: an empty one next")
    H.assertEq(Mark("Route\n1. Ore\n2. Herbs\n"), "3. ")
    H.assertEq(Mark("1. Ore\n\n"), "", "a blank line ended the list")
    H.assertEq(Mark("Just words\n"), "")
    H.assertEq(Mark(""), "")
end

function tests.aChecklistNoteTakesALine()
    local notesNS = Checklist()
    local CK = notesNS.Checklist
    local note = { id = 7, body = "" }
    CK.Init(note)
    local refreshed = 0
    notesNS.ChecklistView = { Refresh = function() refreshed = refreshed + 1 end }
    -- A linked checklist's extension hears of each line added.
    local told = 0
    notesNS.LinkedChanged = function(n) if n == note then told = told + 1 end end
    local env = setmetatable({
        notesNS = notesNS, Fmt = {}, tonumber = tonumber, tostring = tostring,
        Utils = { HexColorNames = function(s) return s end },
        FindNoteIndex = function(id) return id == 7 and 1 or nil end,
        NotesStore = function() return { note } end,
        UpdateBody = function() error("a checklist's body is its lines") end,
    }, { __index = _G })
    LoadNotesPart(env, "function Fmt.ListMarkAfter(", "function notesNS.AppendToNote(")
    H.assertTrue(notesNS.AppendToNote(7, "|cffffffff|Hitem:2589::|h[Linen Cloth]|h|r"))
    H.assertTrue(notesNS.AppendToNote(7, "|cff71d5ff|Hspell:148396|h[Cloud Serpent]|h|r"))
    local lines = note.list.lines
    H.assertEq(#lines, 2)
    H.assertEq(lines[1].item, 2589, "an item line")
    H.assertEq(lines[2].link, nil, "a spell is ticked by hand, not a cooldown")
    H.assertTrue(lines[2].text:find("Cloud Serpent", 1, true) ~= nil)
    H.assertEq(refreshed, 2)
    H.assertEq(told, 2, "each line added told the note's extension")
end

local pass, fail, failures = H.runSuite("NoteAppendLists", tests)
return { pass = pass, fail = fail, failures = failures }
