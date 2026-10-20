-- Tests for the note editor's list checkboxes (Apps/Notes/Notes.lua): the
-- font has no box glyph, so the overlay pass hands the line positions to
-- Fmt.PlaceCheckboxes whenever the text holds a box; the caret never rests
-- before a box; Backspace past one drops it; lines sit whole screen pixels
-- apart as the editor draws them (the boxes crept off the text line by line).

local H = require("Harness")

local BOX, TICKED = "\226\150\161 ", "\226\150\163 "

local function Source()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Notes/Notes.lua", "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

-- One function's source, from its header to the end at its own indent.
local function Extract(src, header)
    local s = assert(src:find(header, 1, true), header .. " not in Notes.lua")
    local indent = src:sub(src:sub(1, s):find("[^\n]*$"), s - 1)
    local _, e = src:find("\n" .. indent .. "end\r?\n", s)
    return src:sub(s, e)
end

local function Run(env, ...)
    local chunks = { ... }
    setmetatable(env, { __index = _G })
    for i = 1, #chunks do assert(load(chunks[i], "=Notes.lua", "t", env))() end
    return env
end

local function LoadOverlay()
    local src = Source()
    local placed = {}
    local Fmt = {
        PlaceCheckboxes = function(_, positions) placed[#placed + 1] = positions or false end,
    }
    local meter = { SetText = function() end, GetStringHeight = function() return 12 end }
    Run({
        Fmt = Fmt, CHECK_EMPTY_PREFIX = BOX, CHECK_FILLED_PREFIX = TICKED, BOLD_FAUX_OFFSETS = {},
        GetMeasureMeter = function() return meter end,
        LayoutCharacters = function()
            return { { line = 1, x = 0, width = 7, glyph = BOX:sub(1, 3), isPrefix = true } }
        end,
        MeasureLineYMap = function() return { 0 }, 12, 14 end,
        ComputeTextRuns = function() return {} end,
        ComputeDecorationRects = function() return {} end,
    }, Extract(src, "function Fmt.UpdateDecorationOverlayFor("))
    return Fmt, placed
end

local function Editor(text)
    return {
        GetText = function() return text end,
        GetWidth = function() return 200 end,
        GetFont = function() return "font", 12, "" end,
    }
end

-- A caret-tracking editor for the caret rules.
local function CaretEditor(text, caret)
    local ed = { text = text, caret = caret }
    function ed:GetText() return self.text end
    function ed:SetText(t) self.text = t end
    function ed:GetCursorPosition() return self.caret end
    function ed:SetCursorPosition(c) self.caret = c end
    return ed
end

local function LoadCaretRules()
    local src = Source()
    local UI = { _notes = {} }
    local doc = { decorations = {} }
    local env = Run({
        Fmt = { ActiveFormatDoc = function() return doc end }, UI = UI,
        CHECK_EMPTY_PREFIX = BOX, CHECK_FILLED_PREFIX = TICKED,
        BOX_GLYPH = BOX:sub(1, 3), TICKED_GLYPH = TICKED:sub(1, 3),
        IsShiftKeyDown = function() return false end,
        RemoveDecorationRange = function(_, kind, s, e) doc.removed = { kind, s, e } end,
    }, (Extract(src, "local function FindLineStartByte("):gsub("^local ", "")),
       (Extract(src, "local function FindLineEndByte("):gsub("^local ", "")),
       Extract(src, "function Fmt.KeepCaretPastBox("),
       Extract(src, "function Fmt.KeepTypingPastBox("),
       Extract(src, "function Fmt.DropBrokenBox("))
    return env.Fmt, UI, doc
end

local STRIKE = { { kind = "strike", startByte = 5, endByte = 9 } }

local tests = {}

function tests.box_withNoFormatting_isPlaced()
    local Fmt, placed = LoadOverlay()
    Fmt.UpdateDecorationOverlayFor(Editor(BOX .. "milk"), nil, {}, {})
    H.assertEq(type(placed[#placed]), "table", "the line positions reach the boxes")
end

function tests.tickedBox_withItsStrike_isPlaced()
    local Fmt, placed = LoadOverlay()
    Fmt.UpdateDecorationOverlayFor(Editor(TICKED .. "milk"), STRIKE, {}, {})
    H.assertEq(type(placed[#placed]), "table", "a ticked line keeps its box")
end

function tests.noBox_clearsTheBoxes()
    local Fmt, placed = LoadOverlay()
    Fmt.UpdateDecorationOverlayFor(Editor("milk"), nil, {}, {})
    Fmt.UpdateDecorationOverlayFor(Editor("milk"), STRIKE, {}, {})
    H.assertEq(#placed, 2, "both passes reach the boxes")
    H.assertEq(placed[1], false, "plain text clears them")
    H.assertEq(placed[2], false, "formatting alone clears them")
end

-- "a\n" then a box line: the box line starts at caret 2, its text at 6.
local TWO = "a\n" .. BOX .. "milk"

function tests.caretAtLineStart_landsPastTheBox()
    local Fmt = LoadCaretRules()
    local ed = CaretEditor(TWO, 2)
    H.assertEq(Fmt.KeepCaretPastBox(ed, 2, 8), 6, "moved past the box")
    H.assertEq(ed.caret, 6, "the editor's caret moved")
end

function tests.caretInsideTheBox_landsPastIt()
    local Fmt = LoadCaretRules()
    local ed = CaretEditor(TWO, 5)
    H.assertEq(Fmt.KeepCaretPastBox(ed, 5, 2), 6, "between the glyph and its space")
end

function tests.leftFromPastTheBox_goesToTheLineAbove()
    local Fmt = LoadCaretRules()
    local ed = CaretEditor(TWO, 5)
    H.assertEq(Fmt.KeepCaretPastBox(ed, 5, 6), 1, "the end of the line above")
end

function tests.leftOnTheFirstLine_staysPastTheBox()
    local Fmt = LoadCaretRules()
    local ed = CaretEditor(BOX .. "milk", 3)
    H.assertEq(Fmt.KeepCaretPastBox(ed, 3, 4), 4, "no line above")
end

function tests.homeFromMidLine_staysOnTheLine()
    local Fmt = LoadCaretRules()
    local ed = CaretEditor(TWO, 2)
    H.assertEq(Fmt.KeepCaretPastBox(ed, 2, 6), 6, "Home lands past the box, not a line up")
end

function tests.caretInText_staysPut()
    local Fmt = LoadCaretRules()
    local ed = CaretEditor(TWO, 7)
    H.assertEq(Fmt.KeepCaretPastBox(ed, 7, 6), nil, "already past the box")
    H.assertEq(ed.caret, 7, "not moved")
end

function tests.plainLine_staysPut()
    local Fmt = LoadCaretRules()
    local ed = CaretEditor("a\nmilk", 2)
    H.assertEq(Fmt.KeepCaretPastBox(ed, 2, 4), nil, "no box on the line")
end

function tests.selecting_leavesTheCaret()
    local Fmt, UI = LoadCaretRules()
    UI._notes.curSelection = { lo = 1, hi = 4 }
    local ed = CaretEditor(TWO, 2)
    H.assertEq(Fmt.KeepCaretPastBox(ed, 2, 8), nil, "a selection is left alone")
end

function tests.typedBeforeBox_movesPastIt()
    local Fmt = LoadCaretRules()
    local ed = CaretEditor("a\ndf" .. BOX .. "milk", 4)
    Fmt.KeepTypingPastBox(ed)
    H.assertEq(ed.text, "a\n" .. BOX .. "dfmilk", "the words follow the box")
    H.assertEq(ed.caret, 8, "caret after the words")
end

function tests.typedPastBox_staysPut()
    local Fmt = LoadCaretRules()
    local ed = CaretEditor("a\n" .. BOX .. "dmilk", 7)
    Fmt.KeepTypingPastBox(ed)
    H.assertEq(ed.text, "a\n" .. BOX .. "dmilk", "text after the box is left alone")
    H.assertEq(ed.caret, 7, "caret not moved")
end

function tests.backspacePastBox_dropsTheBox()
    local Fmt = LoadCaretRules()
    local ed = CaretEditor("a\n" .. BOX:sub(1, 3) .. "milk", 5)
    Fmt.DropBrokenBox(ed)
    H.assertEq(ed.text, "a\nmilk", "the glyph left with its space")
    H.assertEq(ed.caret, 2, "caret at the line start")
end

function tests.backspacePastTickedBox_dropsItsStrike()
    local Fmt, _, doc = LoadCaretRules()
    local ed = CaretEditor("a\n" .. TICKED:sub(1, 3) .. "milk\nb", 5)
    Fmt.DropBrokenBox(ed)
    H.assertEq(ed.text, "a\nmilk\nb", "the ticked glyph left")
    H.assertEq(table.concat(doc.removed, ","), "strike,3,7", "the strike over milk")
end

function tests.backspacePastEmptyTickedBox_keepsTheNextLine()
    local Fmt, _, doc = LoadCaretRules()
    local ed = CaretEditor("a\n" .. TICKED:sub(1, 3) .. "\nb", 5)
    Fmt.DropBrokenBox(ed)
    H.assertEq(table.concat(doc.removed, ","), "strike,3,3", "an empty range, not the line below")
end

function tests.wholeBox_isKept()
    local Fmt = LoadCaretRules()
    local ed = CaretEditor(TWO, 6)
    Fmt.DropBrokenBox(ed)
    H.assertEq(ed.text, TWO, "a box with its space stays")
end

local function LoadDrawn(physH, scale)
    local env = Run({
        Fmt = {}, GetPhysicalScreenSize = function() return physH * 16 / 9, physH end,
    }, Extract(Source(), "function Fmt.DrawnAdvance("))
    local ed = { GetEffectiveScale = function() return scale end }
    return function(advance) return env.Fmt.DrawnAdvance(ed, advance) end
end

local function Thousandths(x) return math.floor(x * 1000 + 0.5) end

-- The probe's numbers: 1440 lines tall, 1.08 scale, 13.852 laid out.
function tests.drawnAdvance_roundsUpToWholePixels()
    local Drawn = LoadDrawn(1440, 1.08)
    H.assertEq(Thousandths(Drawn(13.852)), Thousandths(29 / 2.025), "28.05 px drawn as 29")
end

function tests.drawnAdvance_keepsAWholePixelStep()
    local Drawn = LoadDrawn(768, 1)
    H.assertEq(Drawn(14), 14, "14 px stays 14")
    H.assertEq(Drawn(14.004), 14, "float noise does not add a pixel")
end

-- The probe's numbers: a 24 px line and 2 units of spacing laid out 28.05 px
-- apart; just under 28 instead, so the caret's step is the drawn one.
function tests.pixelSpacing_makesAWholePixelStep()
    local meter = { SetText = function() end, GetStringHeight = function() return 24 / 2.025 end }
    local env = Run({
        Fmt = {}, mmax = math.max, GetMeasureMeter = function() return meter end,
        GetPhysicalScreenSize = function() return 2560, 1440 end,
    }, Extract(Source(), "function Fmt.SetPixelSpacing("))
    local ed = { GetEffectiveScale = function() return 1.08 end }
    function ed:SetSpacing(v) self.spacing = v end
    env.Fmt.SetPixelSpacing(ed, 2)
    local step = (24 / 2.025 + ed.spacing) * 2.025
    H.assertEq(Thousandths(step), 27990, "the step lands just under 28 px")
end

-- Enter's key comes before its new line; the fallback runs a frame later.
local function LoadEnter()
    local UI = { _notes = { activeModes = { check = true } } }
    function UI.RefreshAllEasyNotesToolbarButtons() end
    local later = {}
    local env = Run({
        Fmt = {}, UI = UI, CHECK_EMPTY_PREFIX = BOX, BULLET_PREFIX = "\226\128\162 ",
        Utils = { SafeAfter = function(_, fn) later[#later + 1] = fn end },
    }, (Extract(Source(), "local function FindLineStartByte("):gsub("^local ", "")),
       Extract(Source(), "function Fmt.HandleEditorEnterKey("),
       Extract(Source(), "function Fmt.FinishEnter("))
    local function NextFrame()
        for i = 1, #later do later[i]() end
        for i = #later, 1, -1 do later[i] = nil end
    end
    return env.Fmt, NextFrame
end

local function EnterEditor(text, caret)
    local ed = CaretEditor(text, caret)
    function ed:IsShown() return true end
    return ed
end

function tests.enter_boxesTheNewLineAtOnce()
    local Fmt = LoadEnter()
    local ed = EnterEditor(BOX .. "a", 5)
    Fmt.HandleEditorEnterKey(ed)
    ed.text, ed.caret = BOX .. "a\n", 6
    Fmt.FinishEnter(ed)
    H.assertEq(ed.text, BOX .. "a\n" .. BOX, "the new line gets its box with the line")
    H.assertEq(ed.caret, 10, "caret past it")
end

function tests.enter_typedAhead_boxGoesFirst()
    local Fmt, NextFrame = LoadEnter()
    local ed = EnterEditor(BOX .. "a", 5)
    Fmt.HandleEditorEnterKey(ed)
    ed.text, ed.caret = BOX .. "a\nfa", 8
    NextFrame()
    H.assertEq(ed.text, BOX .. "a\n" .. BOX .. "fa", "the box before the letters typed meanwhile")
    H.assertEq(ed.caret, 12, "caret after the letters")
end

function tests.enter_withNoNewLine_addsNoBox()
    local Fmt, NextFrame = LoadEnter()
    local ed = EnterEditor(BOX .. "af", 5)
    Fmt.HandleEditorEnterKey(ed)
    NextFrame()
    H.assertEq(ed.text, BOX .. "af", "no box mid-line")
    ed.text = BOX .. "a\nf"
    Fmt.FinishEnter(ed)
    H.assertEq(ed.text, BOX .. "a\nf", "a later new line is not this Enter's")
end

local function LoadRenumber()
    local src = Source()
    local env = Run({ Fmt = {}, mmin = math.min, mmax = math.max },
        (Extract(src, "local function SplitLogicalLines("):gsub("^local ", "")),
        (Extract(src, "local function ShiftDecorations("):gsub("^local ", "")),
        Extract(src, "function Fmt.RenumberLists("))
    return env.Fmt
end

function tests.renumber_countsAMovedRunAgain()
    local Fmt = LoadRenumber()
    H.assertEq(Fmt.RenumberLists("1. a\n3. b\n2. c", {}), "1. a\n2. b\n3. c", "in order after a move")
end

function tests.renumber_eachRunFromItsLowest()
    local Fmt = LoadRenumber()
    H.assertEq(Fmt.RenumberLists("2. a\n1. b\nx\n5. c\n4. d", {}), "1. a\n2. b\nx\n4. c\n5. d",
        "a plain line splits the runs")
end

function tests.renumber_movesRangesAndCaretWithTheDigits()
    local Fmt = LoadRenumber()
    local decos = { { kind = "bold", startByte = 5, endByte = 6 } }
    local text, caret = Fmt.RenumberLists("10. a\n1. b", decos, 10)
    H.assertEq(text, "1. a\n2. b", "10 and 1 become 1 and 2")
    H.assertEq(decos[1].startByte .. ".." .. decos[1].endByte, "4..5", "the bold stays on a")
    H.assertEq(caret, 9, "caret stays after b")
end

function tests.caretInView_scrollsTheLineIn()
    local env = Run({ Fmt = {} }, Extract(Source(), "function Fmt.KeepCaretInView("))
    local scroll = { at = 0 }
    function scroll:GetVerticalScroll() return self.at end
    function scroll:GetHeight() return 50 end
    function scroll:SetVerticalScroll(v) self.at = v end
    env.Fmt.KeepCaretInView(scroll, -60, 12)
    H.assertEq(scroll.at, 22, "a line below the view scrolls up into it")
    env.Fmt.KeepCaretInView(scroll, -30, 12)
    H.assertEq(scroll.at, 22, "a line in view stays put")
    env.Fmt.KeepCaretInView(scroll, -5, 12)
    H.assertEq(scroll.at, 5, "a line above the view scrolls down to it")
end

local pass, fail, failures = H.runSuite("NotesCheckboxes", tests)
return { pass = pass, fail = fail, failures = failures }
