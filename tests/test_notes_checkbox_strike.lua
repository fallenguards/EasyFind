-- On a checkbox line the strike is the tick's: the strike button stands down
-- under the caret or a selection that touches one, prose keeps it
-- (Fmt.TouchesCheckbox, Apps/Notes/Notes.lua; 2026-10-26).
local H = require("Harness")

local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Notes/Notes.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local parts = {}
    for _, head in ipairs({ "local CHECK_EMPTY_PREFIX = ", "local CHECK_FILLED_PREFIX = " }) do
        local s = assert(src:find(head, 1, true), head)
        parts[#parts + 1] = src:sub(s, assert(src:find("\n", s, true)))
    end
    for _, head in ipairs({ "local function FindLineStartByte(", "function Fmt.TouchesCheckbox(" }) do
        local s = assert(src:find(head, 1, true), head)
        local _, e = assert(src:find("\nend\r?\n", s))
        parts[#parts + 1] = src:sub(s, e)
    end
    local env = setmetatable({ Fmt = {} }, { __index = _G })
    return assert(load(table.concat(parts, "\n") .. "\nreturn Fmt, CHECK_EMPTY_PREFIX, CHECK_FILLED_PREFIX",
        "=Notes.lua checkbox", "t", env))()
end

local tests = {}

function tests.theStrikeStandsDown_onCheckboxLinesOnly()
    local Fmt, BOX, TICKED = Load()
    local text = "Boss tactics\n" .. BOX .. "Bring flasks\n" .. TICKED .. "Repair\nAfter the boss"
    local boxLine = #"Boss tactics\n" + 3
    H.assertFalse(Fmt.TouchesCheckbox(text, 4), "the caret in prose")
    H.assertTrue(Fmt.TouchesCheckbox(text, boxLine), "the caret on a checkbox line")
    H.assertTrue(Fmt.TouchesCheckbox(text, #text - 18), "on a ticked one too")
    H.assertFalse(Fmt.TouchesCheckbox(text, #text - 2), "the prose after it")
    H.assertTrue(Fmt.TouchesCheckbox(text, nil, 1, #text), "a selection across a checkbox line")
    H.assertFalse(Fmt.TouchesCheckbox(text, nil, 1, 10), "a selection in prose alone")
end

local pass, fail, failures = H.runSuite("NotesCheckboxStrike", tests)
return { pass = pass, fail = fail, failures = failures }
