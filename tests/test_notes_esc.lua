-- Esc leaves the notes window open unless its "Close with Esc" setting
-- (off by default) says otherwise, as the chat's does (2026-10-30): the
-- dispatch handler lets Esc through, and only arms when there is a menu,
-- a row selection or the setting to act on.
local H = require("Harness")

local function Read(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local tests = {}

function tests.escLeavesTheWindow_unlessTheSettingSays()
    local src = Read("Apps/Notes/Notes.lua")
    local s = assert(src:find("Utils.AttachEscClose(frame, function()", 1, true))
    local e = assert(src:find("\n    end)\n", s, true))
    local block = src:sub(s, e)
    H.assertTrue(block:find("if NormalizeDB().escCloses ~= true then return false end", 1, true) ~= nil,
        "the window stays unless the setting is on")
    H.assertTrue(block:find("UI:CloseEasyNotes()", 1, true) ~= nil, "on, Esc still closes it")
    H.assertTrue(block:find("UI:CloseEasyNotesOpenMenus()", 1, true) < block:find("escCloses ~= true", 1, true),
        "menus close first, setting or not")
    H.assertTrue(block:find("end, function()\n        return NormalizeDB().escCloses == true or next(UI._notes.paletteSelection) ~= nil or UI:HasEasyNotesOpenMenus()", 1, true) ~= nil,
        "Esc is taken only with something to do")
end

function tests.theSettingIsARow_offByDefault()
    local src = Read("Apps/Notes/Notes.lua")
    H.assertTrue(src:find('Row(L["NOTES_OPT_ESC"], "check", L["NOTES_OPT_ESC_TT"],\n            function() return NormalizeDB().escCloses == true end', 1, true) ~= nil,
        "a check row reading off unless set")
    H.assertTrue(src:find("local escClose = Control(8)", 1, true) ~= nil, "placed on the page")
    local enUS = Read("Locales/enUS.lua")
    H.assertTrue(enUS:find('L["NOTES_OPT_ESC"]', 1, true) ~= nil and enUS:find('L["NOTES_OPT_ESC_TT"]', 1, true) ~= nil)
end

local pass, fail, failures = H.runSuite("NotesEsc", tests)
return { pass = pass, fail = fail, failures = failures }
