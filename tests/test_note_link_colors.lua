-- An item link with a named quality color (|cnIQ1:) put in a note's EditBox
-- lost its start ("tem:2589...", 2026-10-26): the box reads |c plus eight
-- characters as a hex color. Utils.HexColorNames gives links the hex form,
-- and saved notes are repaired once.
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

local function LoadHexColorNames(globals)
    local env = setmetatable(globals or {}, { __index = _G })
    env._G = env
    env.Utils = {}
    assert(load(Cut(Source("/Shared/Utils.lua"), "function Utils.HexColorNames("), "=HexColorNames", "t", env))()
    return env.Utils.HexColorNames
end

local tests = {}

function tests.namedQualityColorsBecomeHex()
    local HexColorNames = LoadHexColorNames({
        ITEM_QUALITY_COLORS = { [1] = { hex = "|cffffffff" }, [4] = { hex = "|cffa335ee" } },
        GREEN_FONT_COLOR = { GenerateHexColor = function() return "ff20ff20" end },
    })
    local link = "|cnIQ1:|Hitem:2589::::::::81:103::::::::::|h[Linen Cloth]|h|r"
    H.assertEq(HexColorNames(link), "|cffffffff|Hitem:2589::::::::81:103::::::::::|h[Linen Cloth]|h|r")
    H.assertEq(HexColorNames("|cnIQ4:[Epic]|r and |cnGREEN_FONT_COLOR:ok|r"),
        "|cffa335ee[Epic]|r and |cff20ff20ok|r")
    H.assertEq(HexColorNames("|cffa335ee[Epic]|r"), "|cffa335ee[Epic]|r", "hex left alone")
    H.assertEq(HexColorNames("|cnUNKNOWN_NAME:x|r"), "|cffffffffx|r", "an unknown name reads white")
end

function tests.notesTakeLinksThroughIt()
    local notes = Source("/Apps/Notes/Notes.lua")
    H.assertTrue(notes:find("CreateNote(Utils.HexColorNames(", 1, true) ~= nil, "a new note's body")
    H.assertTrue(notes:find("text = Utils.HexColorNames(", 1, true) ~= nil, "an appended text")
    H.assertTrue(Source("/Apps/Notes/ChecklistView.lua"):find("link = Utils.HexColorNames(link)", 1, true) ~= nil,
        "a link shift-clicked into a checklist")
end

function tests.savedNotesAreRepairedWithTheirDecorations()
    local env = setmetatable({ Utils = {}, UI = {} }, { __index = _G })
    env.Utils.HexColorNames = LoadHexColorNames({ ITEM_QUALITY_COLORS = { [1] = { hex = "|cffffffff" } } })
    assert(load(Cut(Source("/Apps/Notes/Notes.lua"), "function UI.HexBodyColors("), "=HexBodyColors", "t", env))()
    -- "ab" bolded before the link, "cd" after it: the second moves by 3.
    local note = {
        body = "ab |cnIQ1:|Hitem:2589|h[Linen Cloth]|h|r cd",
        decorations = { { startByte = 1, endByte = 3 }, { startByte = 42, endByte = 44 } },
    }
    env.UI.HexBodyColors(note)
    H.assertEq(note.body, "ab |cffffffff|Hitem:2589|h[Linen Cloth]|h|r cd")
    H.assertEq(note.decorations[1].startByte, 1)
    H.assertEq(note.decorations[1].endByte, 3)
    H.assertEq(note.body:sub(note.decorations[2].startByte, note.decorations[2].endByte - 1), "cd")
end

local pass, fail, failures = H.runSuite("NoteLinkColors", tests)
return { pass = pass, fail = fail, failures = failures }
