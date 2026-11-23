-- Notes' switches in EasyFind's save (Core/Extensions.lua): one list for
-- the page shown before the extension loads and for the extension's own
-- page, which takes it over when it loads. That page had lost them, the
-- tooltip hint's switch among them (2026-11-23: "why no way to hide the
-- tip for ctrl+right click to set note").
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local tests = {}

function tests.theSharedListHoldsTheTooltipHint()
    local src = Read("Core/Extensions.lua")
    local list = assert(src:match("local NOTES_SAVE_SWITCHES = (%b{})"), "one list of the switches")
    for _, key in ipairs({ "notesClickHint", "notesTooltips", "notesChatNames", "notesPlayerMenu" }) do
        H.assertTrue(list:find('"' .. key .. '"', 1, true) ~= nil, key .. " in it")
    end
    H.assertTrue(src:find("function ns.NotesSaveSwitches(page, kit, anchor)", 1, true) ~= nil, "the page builder, shared")
    H.assertTrue(src:find("function ns.NotesSaveSwitchRows()", 1, true) ~= nil, "the settings search's rows, shared")
    local page = assert(src:match("local function BuildNotesSettings(.-)\nend"), "EasyFind's own page")
    H.assertTrue(page:find("ns.NotesSaveSwitches(", 1, true) ~= nil, "built from the shared list")
end

local pass, fail, failures = H.runSuite("NotesSaveSwitches", tests)
return { pass = pass, fail = fail, failures = failures }
