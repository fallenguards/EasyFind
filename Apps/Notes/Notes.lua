local _, notesNS = ...

local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not (ns and ns.Utils and ns.Results and notesNS.Context) then return end

-- The notes window's methods; the core's search window is ns.Results.
local UI = {}
local L = ns.L
local Utils = ns.Utils

local CreateFrame = CreateFrame
local UIParent = UIParent
local strtrim = strtrim
local time = time
local date = date
local type = type
local tostring = tostring

local sfind, slower = Utils.sfind, Utils.slower
local tinsert, tremove, tsort = Utils.tinsert, Utils.tremove, Utils.tsort
local mmax, mmin = Utils.mmax, math.min
local pcall = pcall
local tonumber = tonumber
local GetCursorInfo = GetCursorInfo

notesNS.UI = UI
ns.Notes = notesNS

local NOTES_DB_VERSION = 11
local FONT_SIZE_MIN = 9
local FONT_SIZE_MAX = 56
local FONT_SIZE_DEFAULT = 12
local UI_SCALE_MIN = 0.65
local UI_SCALE_MAX = 1.50
local UI_SCALE_DEFAULT = 0.90
local UI_SCALE_STEP = 0.05
local OPACITY_MIN = 0.40
local OPACITY_DEFAULT = 1.00
local OPACITY_STEP = 0.05
local NOTES_MAX_BODY = 20000
-- Deleted notes wait in the trash this long, this many at most.
-- The trash keeps this many notes, this many seconds.
local TRASH_KEEP = { max = 50, seconds = 30 * 24 * 3600 }
local NOTE_CODE_PREFIX = "EFN1!"
local NOTE_CODE_PAYLOAD = "EFNOTE1"
local NOTE_CODE_BODY_MAX = 8000
local DEFAULT_WIDTH = 290
local DEFAULT_HEIGHT = 380
local MIN_WIDTH = 220
local MIN_HEIGHT = 180
local HEADER_H = 30
local FOOTER_H = 24
local ATTACH_H = 26
-- editor body sits below the header divider and the tag row
local EDITOR_TOP = 14 + ATTACH_H
local TOOLBAR_H = 28
local PALETTE_ROW_H = 40
local FIND_BAR_H = 58
local HEADER_PANEL_W = 150

-- One standard button size for the whole addon: icon buttons are STD_BTN_W x
-- STD_BTN_H (the T formatting button); text buttons keep their content width but
-- share STD_BTN_H so every button is the same height.
local STD_BTN_W, STD_BTN_H = 22, 20

-- Sideways offsets for faux-bold overlay copies (see the decoration renderer).
local BOLD_FAUX_OFFSETS = { 0.5, 1.0 }

local STRIKE_COMBINER = "\204\182"
local UNDERLINE_COMBINER = "\204\178"
local BULLET_PREFIX = "\226\128\162 "
local CHECK_EMPTY_PREFIX = "\226\150\161 "
local CHECK_FILLED_PREFIX = "\226\150\163 "

local function utf8FromCp(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
    end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
                          0x80 + math.floor(cp / 0x40) % 0x40,
                          0x80 + (cp % 0x40))
    end
    return string.char(0xF0 + math.floor(cp / 0x40000),
                      0x80 + math.floor(cp / 0x1000) % 0x40,
                      0x80 + math.floor(cp / 0x40) % 0x40,
                      0x80 + (cp % 0x40))
end

local BOLD_MAP, ITALIC_MAP, BOLD_ITALIC_MAP = {}, {}, {}
local BOLD_REVERSE_MAP, ITALIC_REVERSE_MAP, BOLD_ITALIC_REVERSE_MAP = {}, {}, {}

-- Two encodings for formatted glyphs. Legacy (1) = Unicode math SMP codepoints,
-- 4-byte UTF-8: the editbox hit-tests those as TWO half-width caret stops, so a
-- click can land mid-character -- the native highlight straddles glyphs and
-- selection byte ranges split characters. PUA (2) = Private Use Area BMP
-- codepoints, 3-byte UTF-8, same class as CJK: one caret stop per glyph. The
-- font carries the glyphs for both; DetectEasyNotesGlyphEncoding switches to
-- PUA (and migrates stored bodies) once the live font has the PUA glyphs.
function UI.FillFormatMaps(enc)
    local maps = { BOLD_MAP, ITALIC_MAP, BOLD_ITALIC_MAP,
        BOLD_REVERSE_MAP, ITALIC_REVERSE_MAP, BOLD_ITALIC_REVERSE_MAP }
    for m = 1, #maps do
        for k in next, maps[m] do maps[m][k] = nil end
    end
    local pua = enc == 2
    for i = 0, 25 do
        BOLD_MAP[string.char(0x41 + i)] = utf8FromCp(pua and 0xE01A + i or 0x1D400 + i)
        BOLD_MAP[string.char(0x61 + i)] = utf8FromCp(pua and 0xE000 + i or 0x1D41A + i)
        if not pua and i == 7 then
            ITALIC_MAP[string.char(0x61 + i)] = utf8FromCp(0x210E)
        else
            ITALIC_MAP[string.char(0x61 + i)] = utf8FromCp(pua and 0xE040 + i or 0x1D44E + i)
        end
        ITALIC_MAP[string.char(0x41 + i)] = utf8FromCp(pua and 0xE05A + i or 0x1D434 + i)
        BOLD_ITALIC_MAP[string.char(0x41 + i)] = utf8FromCp(pua and 0xE09A + i or 0x1D468 + i)
        BOLD_ITALIC_MAP[string.char(0x61 + i)] = utf8FromCp(pua and 0xE080 + i or 0x1D482 + i)
    end
    for i = 0, 9 do
        BOLD_MAP[string.char(0x30 + i)] = utf8FromCp(pua and 0xE034 + i or 0x1D7CE + i)
        BOLD_ITALIC_MAP[string.char(0x30 + i)] = utf8FromCp(pua and 0xE0B4 + i or 0x1D7CE + i)
    end
    for k, v in next, BOLD_MAP do BOLD_REVERSE_MAP[v] = k end
    for k, v in next, ITALIC_MAP do ITALIC_REVERSE_MAP[v] = k end
    for k, v in next, BOLD_ITALIC_MAP do BOLD_ITALIC_REVERSE_MAP[v] = k end
end
UI.FillFormatMaps(1)
-- Live map references for the EasyFindDev test harness (contents are refilled
-- in place on encoding switch, so these stay valid).
UI._fmtMaps = { bold = BOLD_MAP, italic = ITALIC_MAP, boldItalic = BOLD_ITALIC_MAP }

local function iterUtf8(text)
    local pos = 1
    local len = #text
    return function()
        if pos > len then return nil end
        local b = text:byte(pos)
        local size = 1
        if b >= 240 then size = 4
        elseif b >= 224 then size = 3
        elseif b >= 192 then size = 2 end
        local glyph = text:sub(pos, pos + size - 1)
        local start = pos
        pos = pos + size
        return glyph, start
    end
end

local function GlyphPlain(g)
    return BOLD_REVERSE_MAP[g] or ITALIC_REVERSE_MAP[g] or BOLD_ITALIC_REVERSE_MAP[g] or g
end

-- De-formats SMP bold/italic glyphs to plain ASCII. Given a 1-based inclusive
-- byte range [lo,hi] in the original, returns the plain string plus the
-- matching 0-based [start,end) range for HighlightText.
local function BuildPlainCopy(text, lo, hi)
    local out = {}
    local origPos, plainPos = 0, 0
    local plainLo, plainHi
    for g in iterUtf8(text) do
        if plainLo == nil and origPos >= lo - 1 then plainLo = plainPos end
        local p = GlyphPlain(g)
        out[#out + 1] = p
        origPos = origPos + #g
        plainPos = plainPos + #p
        if plainHi == nil and origPos >= hi then plainHi = plainPos end
    end
    return table.concat(out), plainLo or 0, plainHi or plainPos
end

local function GlyphHasBold(g)
    return BOLD_REVERSE_MAP[g] ~= nil or BOLD_ITALIC_REVERSE_MAP[g] ~= nil
end

local function GlyphHasItalic(g)
    return ITALIC_REVERSE_MAP[g] ~= nil or BOLD_ITALIC_REVERSE_MAP[g] ~= nil
end

local function AddBold(g)
    if GlyphHasBold(g) then return g end
    if GlyphHasItalic(g) then
        local p = ITALIC_REVERSE_MAP[g]
        return BOLD_ITALIC_MAP[p] or g
    end
    return BOLD_MAP[g] or g
end

local function RemoveBold(g)
    if not GlyphHasBold(g) then return g end
    if GlyphHasItalic(g) then
        local p = BOLD_ITALIC_REVERSE_MAP[g]
        return p and ITALIC_MAP[p] or p or g
    end
    return BOLD_REVERSE_MAP[g] or g
end

local function AddItalic(g)
    if GlyphHasItalic(g) then return g end
    if GlyphHasBold(g) then
        local p = BOLD_REVERSE_MAP[g]
        return BOLD_ITALIC_MAP[p] or g
    end
    return ITALIC_MAP[g] or g
end

local function RemoveItalic(g)
    if not GlyphHasItalic(g) then return g end
    if GlyphHasBold(g) then
        local p = BOLD_ITALIC_REVERSE_MAP[g]
        return p and BOLD_MAP[p] or p or g
    end
    return ITALIC_REVERSE_MAP[g] or g
end

local function IsLetterLike(g)
    local p = GlyphPlain(g)
    return p:match("^[%w]$") ~= nil
end

local function SelectionAllHave(text, predicate)
    local anyLetter = false
    for g in iterUtf8(text) do
        if IsLetterLike(g) then
            anyLetter = true
            if not predicate(g) then return false, true end
        end
    end
    return anyLetter, anyLetter
end

local function MapSelection(text, mapper)
    local out = {}
    for g in iterUtf8(text) do
        out[#out + 1] = mapper(g)
    end
    return table.concat(out)
end

local function ApplyInlineFormat(text, modes)
    if not (modes.bold or modes.italic) then return text end
    local out = {}
    for g in iterUtf8(text) do
        local r = g
        if modes.bold and modes.italic then
            r = BOLD_ITALIC_MAP[g] or r
        elseif modes.bold then
            r = BOLD_MAP[g] or r
        elseif modes.italic then
            r = ITALIC_MAP[g] or r
        end
        out[#out + 1] = r
    end
    return table.concat(out)
end

-- Render markdown to a display string the editbox shows natively when the note
-- is NOT being edited: **bold**/*italic* become SMP glyphs, __underline__/~~strike~~
-- get combining marks (drawn per glyph by the editbox itself), markers removed.
-- Nothing is overlaid, so nothing can drift. The raw markdown (with markers) is
-- what shows while the editbox is focused.
function UI:MarkdownToDisplay(body)
    -- Rendering markdown to SMP glyphs turns bold into tofu boxes, because the
    -- editbox font (Friz) has no glyphs at those math-alphanumeric codepoints and
    -- WoW 12.0 ships no Friz font file to build a bold-Friz variant. Until the
    -- overlay-on-blur renderer lands, the display IS the raw markdown (clean Friz,
    -- no boxes) -- you just see the markers.
    return body or ""
end

local function IsRangeFullyCovered(decorations, kind, startByte, endByte)
    local relevant = {}
    for _, d in ipairs(decorations) do
        if d.kind == kind and d.endByte > startByte and d.startByte < endByte then
            relevant[#relevant + 1] = d
        end
    end
    if #relevant == 0 then return false end
    tsort(relevant, function(a, b) return a.startByte < b.startByte end)
    local cursor = startByte
    for _, d in ipairs(relevant) do
        if d.startByte > cursor then return false end
        if d.endByte > cursor then cursor = d.endByte end
        if cursor >= endByte then return true end
    end
    return cursor >= endByte
end

local function RemoveDecorationRange(decorations, kind, startByte, endByte)
    local kept = {}
    for _, d in ipairs(decorations) do
        if d.kind ~= kind or d.endByte <= startByte or d.startByte >= endByte then
            kept[#kept + 1] = d
        else
            if d.startByte < startByte then
                kept[#kept + 1] = { kind = kind, startByte = d.startByte, endByte = startByte,
                                    r = d.r, g = d.g, b = d.b }
            end
            if d.endByte > endByte then
                kept[#kept + 1] = { kind = kind, startByte = endByte, endByte = d.endByte,
                                    r = d.r, g = d.g, b = d.b }
            end
        end
    end
    wipe(decorations)
    for _, d in ipairs(kept) do decorations[#decorations + 1] = d end
end

local function StripDecorationMarks(text)
    text = tostring(text or "")
    text = text:gsub(STRIKE_COMBINER, "")
    text = text:gsub(UNDERLINE_COMBINER, "")
    return text
end

local FORMAT_ACTIONS = {
    { key = "bold",      tip = L["NOTES_FMT_BOLD"],          mode = "bold",      buttonLabel = "B", buttonBold = true },
    -- The italic glyph is resolved at button creation through the live italic
    -- map: the font has italic glyphs only at the PUA slots, so a baked SMP
    -- math-italic codepoint renders as nothing.
    { key = "italic",    tip = L["NOTES_FMT_ITALIC"],        mode = "italic",    buttonLabel = "I" },
    { key = "underline", tip = L["NOTES_FMT_UNDERLINE"],     mode = "underline", buttonLabel = "U" },
    { key = "strike",    tip = L["NOTES_FMT_STRIKE"], mode = "strike",    buttonLabel = "S" },
    { key = "color",     tip = L["NOTES_FMT_COLOR"],         mode = "color",     buttonLabel = "A", buttonBold = true, isColor = true },
    -- The three list styles share one toolbar button that opens a small menu,
    -- so they cost one slot instead of three. Each entry is a full action the
    -- menu hands straight to ApplyEasyNotesFormat.
    { key = "lists", tip = L["NOTES_FMT_LISTS"], mode = "lists", isListMenu = true, listMenu = {
        { key = "list",      tip = L["NOTES_FMT_BULLETS"], mode = "list",    linePrefix = BULLET_PREFIX },
        { key = "checklist", tip = L["NOTES_FMT_CHECKLIST"],     mode = "check",   linePrefix = CHECK_EMPTY_PREFIX, toggleCheck = true },
        { key = "numlist",   tip = L["NOTES_FMT_NUMBERED"], mode = "numlist", numbered = true },
    } },
}

local INLINE_MODES = { bold = true, italic = true, strike = true, underline = true }

-- Inline styles are stored as markdown IN the note text, not as decorations.
local MD_MARKERS = { bold = "**", italic = "*", underline = "__", strike = "~~" }

local function NormalizeDB()
    EasyNotesDB = type(EasyNotesDB) == "table" and EasyNotesDB or {}
    local v = type(EasyNotesDB.version) == "number" and EasyNotesDB.version or 0
    if v < 2 then
        EasyNotesDB.window = { w = DEFAULT_WIDTH, h = DEFAULT_HEIGHT }
    end
    if type(EasyNotesDB.notes) ~= "table" then EasyNotesDB.notes = {} end
    if type(EasyNotesDB.itemNotes) ~= "table" then EasyNotesDB.itemNotes = {} end
    if type(EasyNotesDB.shareAcrossCharacters) ~= "boolean" then
        EasyNotesDB.shareAcrossCharacters = false
    end
    -- Bold/italic are char-replace to the custom FrizNotes font's SMP codepoints
    -- (WYSIWYG, native, no overlay). The old range-decoration path (richText2) is
    -- retired -- force it off so the SMP char-replace path is always used.
    EasyNotesDB.richText2 = false
    -- Bodies migrated to PUA glyphs in an earlier session must be read through
    -- PUA maps from the first touch (search runs without the notes window).
    if EasyNotesDB.glyphEnc == 2 and not UI._notes.puaGlyphs then
        UI._notes.puaGlyphs = true
        UI.FillFormatMaps(2)
    end
    if v < 3 then
        for i = 1, #EasyNotesDB.notes do
            local n = EasyNotesDB.notes[i]
            if n and not n.name then
                local body = tostring(n.body or "")
                local first = body:match("^[^\n]+") or ""
                first = strtrim((first:gsub("^#+%s*", "")))
                n.name = (first == "" and "") or (#first > 64 and (first:sub(1, 64) .. "...")) or first
            end
        end
    end
    if v < 4 then
        for i = 1, #EasyNotesDB.notes do
            local n = EasyNotesDB.notes[i]
            if n then
                n.body = StripDecorationMarks(n.body or "")
                n.decorations = n.decorations or {}
            end
        end
    end
    if v < 6 then
        for i = 1, #EasyNotesDB.notes do
            local n = EasyNotesDB.notes[i]
            if n and type(n.decorations) == "table" then
                local bodyLen = #(n.body or "")
                local kept = {}
                for _, d in ipairs(n.decorations) do
                    if type(d) == "table" and d.startByte and d.endByte
                        and d.startByte >= 1 and d.endByte > d.startByte
                        and d.endByte <= bodyLen + 1 then
                        kept[#kept + 1] = d
                    end
                end
                n.decorations = kept
            end
        end
    end
    if v < 7 then
        for i = 1, #EasyNotesDB.notes do
            local n = EasyNotesDB.notes[i]
            if n then n.contexts = type(n.contexts) == "table" and n.contexts or {} end
        end
    end
    if v < 8 then
        for i = 1, #EasyNotesDB.notes do
            local n = EasyNotesDB.notes[i]
            if n then
                n.appliesIn = type(n.appliesIn) == "table" and n.appliesIn or {}
                if type(n.contexts) == "table" then
                    for j = 1, #n.contexts do
                        local c = n.contexts[j]
                        local id = c and c.id
                        if type(id) == "string" then
                            local kind, raw = id:match("^(%a+):(.+)$")
                            local entry
                            if kind == "inst" then
                                entry = { type = "instance", id = tonumber(raw) or raw, name = c.label or raw }
                            elseif kind == "map" then
                                entry = { type = "map", id = tonumber(raw) or raw, name = c.label or raw }
                            else
                                entry = { type = "uistate", id = id, name = c.label or id }
                            end
                            n.appliesIn[#n.appliesIn + 1] = entry
                        end
                    end
                end
                n.contexts = nil
                n.showsOn = type(n.showsOn) == "table" and n.showsOn or {}
                n.tags = type(n.tags) == "table" and n.tags or {}
                if n.matchMode ~= "all" and n.matchMode ~= "manual" then n.matchMode = "any" end
                if n.scope ~= "character" then n.scope = "account" end
            end
        end
    end
    EasyNotesDB.version = NOTES_DB_VERSION
    if type(EasyNotesDB.trash) ~= "table" then EasyNotesDB.trash = {} end
    if type(EasyNotesDB.nextID) ~= "number" then EasyNotesDB.nextID = 1 end
    if type(EasyNotesDB.window) ~= "table" then
        EasyNotesDB.window = { w = DEFAULT_WIDTH, h = DEFAULT_HEIGHT }
    end
    if type(EasyNotesDB.editorWindow) ~= "table" then
        EasyNotesDB.editorWindow = { w = DEFAULT_WIDTH, h = DEFAULT_HEIGHT }
    end
    if type(EasyNotesDB.toolbarShown) ~= "boolean" then EasyNotesDB.toolbarShown = false end
    if type(EasyNotesDB.autoResize) ~= "boolean" then EasyNotesDB.autoResize = true end
    if v < 9 then EasyNotesDB.autoResize = true end
    if v < 10 then
        for i = 1, #EasyNotesDB.notes do
            EasyNotesDB.notes[i].scope = "character"
        end
    end
    -- A unit note carried its player twice; the shows-on tag alone applies.
    if v < 11 then
        for i = 1, #EasyNotesDB.notes do
            local n = EasyNotesDB.notes[i]
            local applies, shows = n and n.appliesIn, n and n.showsOn
            for j = (applies and #applies or 0), 1, -1 do
                local a = applies[j]
                if a and a.type == "player" then
                    for k = 1, (shows and #shows or 0) do
                        if shows[k].type == "player" and shows[k].id == a.id then
                            table.remove(applies, j)
                            break
                        end
                    end
                end
            end
        end
    end
    if type(EasyNotesDB.fontSize) ~= "number" then EasyNotesDB.fontSize = FONT_SIZE_DEFAULT end
    if type(EasyNotesDB.uiScale) ~= "number" then EasyNotesDB.uiScale = UI_SCALE_DEFAULT end
    if EasyNotesDB.uiScale < UI_SCALE_MIN then EasyNotesDB.uiScale = UI_SCALE_MIN end
    if EasyNotesDB.uiScale > UI_SCALE_MAX then EasyNotesDB.uiScale = UI_SCALE_MAX end
    if type(EasyNotesDB.opacity) ~= "number" then EasyNotesDB.opacity = OPACITY_DEFAULT end
    if EasyNotesDB.opacity < OPACITY_MIN then EasyNotesDB.opacity = OPACITY_MIN end
    if EasyNotesDB.opacity > 1 then EasyNotesDB.opacity = 1 end
    return EasyNotesDB
end

local function NotesStore() return NormalizeDB().notes end

local function NextNoteID()
    local db = NormalizeDB()
    local id = db.nextID
    db.nextID = id + 1
    return id
end

local function FindNoteIndex(id)
    local notes = NotesStore()
    for i = 1, #notes do
        if notes[i].id == id then return i end
    end
end

local function NoteTitle(note)
    if not note then return "" end
    local name = note.name and strtrim(note.name) or ""
    if name == "" or name == "Untitled Note" then return L["NOTES_UNTITLED"] end
    if #name > 64 then name = name:sub(1, 64) .. "..." end
    return name
end

local function FormatRelTime(ts)
    if not ts then return "" end
    local diff = time() - ts
    if diff < 60 then return L["NOTES_JUST_NOW"] end
    if diff < 3600 then return Utils.sformat(L["NOTES_MIN_AGO"], math.floor(diff / 60)) end
    if diff < 86400 then return Utils.sformat(L["NOTES_HOURS_AGO"], math.floor(diff / 3600)) end
    if diff < 86400 * 7 then return Utils.sformat(L["NOTES_DAYS_AGO"], math.floor(diff / 86400)) end
    return date("%b %d", ts)
end

local function StripColorEscapes(s)
    return (tostring(s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function CharCount(body)
    local s = StripColorEscapes(body)
    local count = 0
    for i = 1, #s do
        local b = s:byte(i)
        if b < 128 or b >= 192 then count = count + 1 end
    end
    return count
end

UI._notes = {
    selectedID = nil,
    paletteRows = {},
    paletteSelection = {},
    contextChips = {},
    paletteShown = false,
    toolbarShown = false,
    loadingNote = false,
    snippetFocus = false,
}

local function GetSelectedNote()
    local id = UI._notes.selectedID
    if not id then return nil end
    local idx = FindNoteIndex(id)
    return idx and NotesStore()[idx] or nil
end
notesNS.SelectedNote = GetSelectedNote
function notesNS.AllNotes() return NotesStore() end

-- The main chunk sits against Lua's 200-local ceiling: private helper groups
-- live in container tables (Fmt = format host, Builders = one-shot UI
-- builders) so each group costs one local.
local Fmt = {}
local Builders = {}

-- Active format host. The formatting engine (selection tracking, format apply,
-- colour, toolbar state) targets either the notes editor or an attached snippet
-- editor (notesNS.AttachSnippetBodyEditor); snippetFocus tracks which of the two
-- was focused last.
function Fmt.SnippetHostActive()
    local host = UI._notes.snippetHost
    return host ~= nil and UI._notes.snippetFocus and host.editor ~= nil
end

function Fmt.ActiveFormatEditor()
    if Fmt.SnippetHostActive() then return UI._notes.snippetHost.editor end
    return UI._notes.frame and UI._notes.frame.editor
end

function Fmt.ActiveFormatDoc()
    if Fmt.SnippetHostActive() then return UI._notes.snippetHost.doc end
    return GetSelectedNote()
end

function Fmt.SetSnippetFocus(active)
    active = active and true or false
    if UI._notes.snippetFocus == active then return end
    UI._notes.snippetFocus = active
    UI._notes.selAnchor = nil
    UI._notes.curSelection = nil
    UI._notes.lastSelection = nil
    if UI._notes.activeModes then wipe(UI._notes.activeModes) end
    UI:RefreshAllEasyNotesToolbarButtons()
end

-- Sticky bold/italic typing: replace the just-typed character with its styled
-- glyph. Shared by the notes editor's OnChar and the snippet host's. Rich-text
-- v2 keeps text plain and extends bold/italic decoration ranges in
-- OnTextChanged; no SMP glyph substitution there.
function Fmt.ApplyTypingGlyphFormat(editor, c)
    local modes = UI._notes.activeModes or {}
    if not (modes.bold or modes.italic) then return end
    if NormalizeDB().richText2 then return end
    local replacement = ApplyInlineFormat(c, modes)
    if replacement == c then return end
    local pos = editor:GetCursorPosition() or 0
    local txt = editor:GetText() or ""
    UI._notes.inputBusy = true
    local before = txt:sub(1, math.max(0, pos - #c))
    local after = txt:sub(pos + 1)
    editor:SetText(before .. replacement .. after)
    editor:SetCursorPosition(#before + #replacement)
    UI._notes.inputBusy = nil
end

local function CurrentCharKey() return ns.CurrentCharacterKey() end

-- search must see header and styled text, which is stored as SMP glyphs;
-- map it back to plain ASCII (cached per note, keyed on the raw body)
local plainBodyCache = {}
local function PlainSearchText(note)
    local body = note.body or ""
    local cached = plainBodyCache[note]
    if cached and cached.body == body then return cached.plain end
    local plain = slower(StripColorEscapes(MapSelection(body, GlyphPlain)))
    plainBodyCache[note] = { body = body, plain = plain }
    return plain
end

local function SortedNotes(filter)
    local notes = NotesStore()
    local list = {}
    filter = filter and slower(strtrim(filter)) or ""
    local shareAll = EasyNotesDB.shareAcrossCharacters == true
    local charKey = CurrentCharKey()
    -- Search-bar filters: charFilter (nil = this character, "all", or a specific
    -- character key) and categoryFilter (nil = all, or a set of category names).
    local charFilter = UI._notes and UI._notes.charFilter
    local catFilter = UI._notes and UI._notes.categoryFilter
    for i = 1, #notes do
        local n = notes[i]
        local charOK
        if charFilter == "all" then
            charOK = true
        elseif charFilter then
            charOK = n.character == charFilter
        else
            charOK = shareAll or n.scope == "account" or not n.character or n.character == charKey
        end
        local catOK = (not catFilter) or catFilter[n.category or "General"] == true
        if charOK and catOK and (filter == "" or sfind(PlainSearchText(n), filter, 1, true)
                       or sfind(slower(n.alias or ""), filter, 1, true)) then
            list[#list + 1] = n
        end
    end
    tsort(list, function(a, b)
        local ap = a.pinned and 1 or 0
        local bp = b.pinned and 1 or 0
        if ap ~= bp then return ap > bp end
        return (a.updated or 0) > (b.updated or 0)
    end)
    return list
end

local function CreateNote(body)
    local note = {
        id = NextNoteID(),
        name = "",
        body = tostring(body or ""),
        alias = "",
        pinned = false,
        created = time(),
        updated = time(),
        character = CurrentCharKey(),
        appliesIn = {},
        showsOn = {},
        tags = {},
        matchMode = "any",
        scope = "character",
        decorations = {},
    }
    tinsert(NotesStore(), 1, note)
    UI._notes.selectedID = note.id
    if EasyFind.db then EasyFind.db.notesInUse = true end
    return note
end

-- A deleted note goes to the trash, newest first; old and surplus ones
-- fall off there.
local function DeleteNote(id)
    local idx = FindNoteIndex(id)
    if not idx then return end
    local note = tremove(NotesStore(), idx)
    local trash = NormalizeDB().trash
    note.deletedAt = time()
    tinsert(trash, 1, note)
    for i = #trash, 1, -1 do
        if i > TRASH_KEEP.max or time() - (trash[i].deletedAt or 0) > TRASH_KEEP.seconds then
            tremove(trash, i)
        end
    end
    if UI._notes.selectedID == id then
        local rest = SortedNotes()
        UI._notes.selectedID = rest[1] and rest[1].id or nil
    end
end

local function RestoreNote(id)
    local trash = NormalizeDB().trash
    for i = 1, #trash do
        if trash[i].id == id then
            local note = tremove(trash, i)
            note.deletedAt = nil
            note.updated = time()
            tinsert(NotesStore(), 1, note)
            UI._notes.selectedID = note.id
            return note
        end
    end
    return nil
end

function notesNS.TrashList()
    local trash = NormalizeDB().trash
    local out = {}
    for i = 1, #trash do
        out[i] = { id = trash[i].id, title = NoteTitle(trash[i]), deletedAt = trash[i].deletedAt }
    end
    return out
end

function notesNS.RestoreNote(id)
    local note = RestoreNote(id)
    if not note then return nil end
    if EasyFind.db then EasyFind.db.notesInUse = true end
    EasyFind:Print(Utils.sformat(L["NOTES_RESTORED_FMT"], NoteTitle(note)))
    if UI.RefreshEasyNotes then UI:RefreshEasyNotes() end
    return note
end

function notesNS.RestoreLastDeleted()
    local trash = NormalizeDB().trash
    if not trash[1] then
        EasyFind:Print(L["NOTES_NOTHING_TO_UNDO"])
        return nil
    end
    return notesNS.RestoreNote(trash[1].id)
end

function notesNS.EmptyTrash()
    local trash = NormalizeDB().trash
    for i = #trash, 1, -1 do trash[i] = nil end
end

local function UpdateBody(id, body)
    local idx = FindNoteIndex(id)
    if not idx then return end
    local note = NotesStore()[idx]
    body = tostring(body or "")
    if #body > NOTES_MAX_BODY then body = body:sub(1, NOTES_MAX_BODY) end
    if note.body == body then return end
    note.body = body
    note.updated = time()
    if notesNS.RefreshReader then notesNS.RefreshReader(id) end
end

local function TogglePinned(id)
    local idx = FindNoteIndex(id)
    if not idx then return end
    local n = NotesStore()[idx]
    n.pinned = not n.pinned
end

-- Public API for sibling addons (EasyFind's item-catalog "Add to Note"):
-- create a note with initial text, list notes for a picker, append to a note
-- by id, and open the editor to one. Thin wrappers over the file-local
-- primitives above; none needs the editor window open, so a caller can add a
-- link headlessly and the list refreshes only when the window is already up.
local function NotesWindowShown()
    local frame = UI.GetEasyNotesFrame and UI:GetEasyNotesFrame()
    return frame and frame:IsShown()
end

function notesNS.NewChecklist()
    local note = CreateNote("")
    note.scope = "account"
    note.name = L["CHECK_NEW_NAME"]
    if notesNS.Checklist then notesNS.Checklist.Init(note) end
    UI:HideEasyNotesPalette()
    UI:RefreshEasyNotes()
    -- Straight to typing its first line.
    if notesNS.ChecklistView then notesNS.ChecklistView.AddNew() end
    return note
end

function notesNS.CreateNote(opts)
    opts = opts or {}
    local note = CreateNote(opts.body or "")
    local title = opts.title and strtrim(opts.title) or ""
    if title ~= "" then note.name = title end
    if NotesWindowShown() and UI.RefreshEasyNotes then UI:RefreshEasyNotes() end
    return note.id
end

function notesNS.ListNotes(filter)
    local list = SortedNotes(filter)
    local out = {}
    for i = 1, #list do
        local n = list[i]
        out[i] = { id = n.id, title = NoteTitle(n), updated = n.updated, pinned = n.pinned }
    end
    return out
end

function notesNS.AppendToNote(id, text)
    local idx = FindNoteIndex(id)
    if not idx then return false end
    text = tostring(text or "")
    if text == "" then return false end
    local note = NotesStore()[idx]
    local body = note.body or ""
    if body ~= "" and body:sub(-1) ~= "\n" then body = body .. "\n" end
    UpdateBody(id, body .. text)
    if NotesWindowShown() and UI._notes.selectedID == id and UI.RefreshEasyNotes then
        UI:RefreshEasyNotes()
    end
    return true
end

function notesNS.OpenNote(id)
    if UI.SelectEasyNote then UI:SelectEasyNote(id) end
    if UI.OpenEasyNotes then UI:OpenEasyNotes() end
end

-- The notes as rows of the search bar: every note this character sees,
-- found by title, alias and body, opened on Enter. The bar is the one
-- door that needs no window open first.
function notesNS.BuildSearchData()
    local notes = NotesStore()
    local shareAll = EasyNotesDB.shareAcrossCharacters == true
    local charKey = CurrentCharKey()
    local out = {}
    for i = 1, #notes do
        local n = notes[i]
        if shareAll or n.scope == "account" or not n.character or n.character == charKey then
            local title = NoteTitle(n)
            local keywords = { "note", "notes" }
            local alias = n.alias and slower(strtrim(n.alias)) or ""
            if alias ~= "" then keywords[#keywords + 1] = alias end
            local body = PlainSearchText(n)
            if body ~= "" then keywords[#keywords + 1] = body:sub(1, 300) end
            out[#out + 1] = {
                name = title,
                nameLower = slower(title),
                category = "Notes",
                keywordsLower = keywords,
                searchCommandDesc = FormatRelTime(n.updated),
                icon = ns.NOTES_ICON_TEX,
                noteID = n.id,
            }
        end
    end
    return out
end

-- A note made from the bar's "New note: ..." row: titled by the query,
-- open with the body ready to type into.
function notesNS.NewFromSearch(title)
    local note = CreateNote("")
    note.name = strtrim(title or "")
    UI:OpenEasyNotes()
    UI:SelectEasyNote(note.id)
    UI:HideEasyNotesPalette()
    UI:FocusEasyNoteEditor()
end

-- The body as markdown: styled glyphs become ** and * runs, underline and
-- strike decorations __ and ~~; colors stay home. Spaces and punctuation
-- between two words of one style sit inside the markers.
local function DecorationAt(decorations, kind, bytePos)
    for i = 1, #decorations do
        local d = decorations[i]
        if d.kind == kind and d.startByte <= bytePos and bytePos < d.endByte then return true end
    end
    return false
end

local function NoteToMarkdown(note)
    local body = note.body or ""
    local decorations = note.decorations or {}
    local out, pending = {}, {}
    local bold, ital, und, str = false, false, false, false
    local function Close()
        if str then out[#out + 1] = "~~" end
        if und then out[#out + 1] = "__" end
        if ital then out[#out + 1] = "*" end
        if bold then out[#out + 1] = "**" end
    end
    local function Open()
        if bold then out[#out + 1] = "**" end
        if ital then out[#out + 1] = "*" end
        if und then out[#out + 1] = "__" end
        if str then out[#out + 1] = "~~" end
    end
    local function Flush()
        for i = 1, #pending do out[#out + 1] = pending[i] end
        for i = #pending, 1, -1 do pending[i] = nil end
    end
    for g, start in iterUtf8(body) do
        local plain = GlyphPlain(g)
        if not IsLetterLike(g) then
            pending[#pending + 1] = plain
        else
            local b, i = GlyphHasBold(g), GlyphHasItalic(g)
            local u = DecorationAt(decorations, "underline", start)
            local s = DecorationAt(decorations, "strike", start)
            if b ~= bold or i ~= ital or u ~= und or s ~= str then
                Close()
                Flush()
                bold, ital, und, str = b, i, u, s
                Open()
            else
                Flush()
            end
            out[#out + 1] = plain
        end
    end
    Close()
    Flush()
    return StripColorEscapes(table.concat(out))
end
notesNS.NoteToMarkdown = NoteToMarkdown

local function NoteByID(id)
    local idx = FindNoteIndex(id)
    return idx and NotesStore()[idx] or nil
end

function notesNS.CopyAsText(id)
    local note = NoteByID(id)
    if not note then return end
    Utils.CopyToClipboard(StripColorEscapes(MapSelection(note.body or "", GlyphPlain)))
end

function notesNS.CopyAsMarkdown(id)
    local note = NoteByID(id)
    if note then Utils.CopyToClipboard(NoteToMarkdown(note)) end
end

-- Share codes: EFN1! + the shared codec, carrying title, category and the
-- markdown body.
function notesNS.ExportCode(id)
    local note = NoteByID(id)
    local codec = ns.ShareCodec
    if not (note and codec) then return nil end
    local md = NoteToMarkdown(note)
    if #md > NOTE_CODE_BODY_MAX then md = md:sub(1, NOTE_CODE_BODY_MAX) end
    local encS = codec.encS
    local parts = { NOTE_CODE_PAYLOAD, encS(NoteTitle(note)), encS(note.category or "General"), encS(md) }
    return NOTE_CODE_PREFIX .. codec.base64enc(table.concat(parts))
end

function notesNS.DecodeCode(str)
    local codec = ns.ShareCodec
    if not (codec and type(str) == "string") then return nil end
    local b64 = str:match("^%s*EFN1!(%S+)")
    if not b64 then return nil end
    local ok, blob = pcall(codec.base64dec, b64)
    if not ok or type(blob) ~= "string" or blob:sub(1, #NOTE_CODE_PAYLOAD) ~= NOTE_CODE_PAYLOAD then
        return nil
    end
    local decS = codec.decS
    local pos = #NOTE_CODE_PAYLOAD + 1
    local name, category, md
    name, pos = decS(blob, pos)
    category, pos = decS(blob, pos)
    md = decS(blob, pos)
    if not (name and md) then return nil end
    return name, category, md
end

-- An imported note is a new note of this character; its markdown becomes
-- the live styled body. Returns the note, or nil for a bad code.
function notesNS.ImportCode(str)
    local name, category, md = notesNS.DecodeCode(str)
    if not name then return nil end
    if #md > NOTE_CODE_BODY_MAX then md = md:sub(1, NOTE_CODE_BODY_MAX) end
    local doc = notesNS.DocumentFromMarkdown(md)
    local note = CreateNote(doc.body)
    note.decorations = doc.decorations or {}
    note.name = strtrim(name:gsub("|", "")):sub(1, 64)
    local cats = UI:GetEasyNotesCategories()
    for i = 1, #cats do
        if cats[i] == category then note.category = category end
    end
    EasyFind:Print(Utils.sformat(L["NOTES_IMPORTED_FMT"], NoteTitle(note)))
    UI:OpenEasyNotes()
    UI:SelectEasyNote(note.id)
    UI:HideEasyNotesPalette()
    return note
end

function notesNS.PromptImportCode()
    ns.ShowPasteDialog({
        title = L["NOTES_IMPORT_TITLE"],
        onAccept = function(text)
            if not notesNS.ImportCode(text) then EasyFind:Print(L["SHORTKEY_IMPORT_BAD"]) end
        end,
    })
end

-- Notes that apply where the player is, as rows for the empty bar.
function notesNS.HereRows()
    if EasyFind.db and EasyFind.db.notesSurfaceHere == false then return nil end
    local Context = notesNS.Context
    local _, set = Context.Active()
    local list = SortedNotes("")
    local rows
    for i = 1, #list do
        local n = list[i]
        if Context.Applies(n, set) then
            local title = NoteTitle(n)
            rows = rows or {}
            rows[#rows + 1] = {
                name = title, nameLower = slower(title), category = "Notes",
                searchCommandDesc = L["NOTES_HERE"], icon = ns.NOTES_ICON_TEX,
                noteID = n.id, noPin = true, noLearn = true,
            }
            if #rows >= 3 then break end
        end
    end
    return rows
end

-- ==== reader ================================================================

-- A small read-only window of one note, stepping through the pinned
-- notes (every note when none is pinned), in the editor's own font.
local reader
local READER_W, READER_H = 300, 220

local function ReaderNotes()
    local list = SortedNotes("")
    local pinned = {}
    for i = 1, #list do
        if list[i].pinned then pinned[#pinned + 1] = list[i] end
    end
    return #pinned > 0 and pinned or list
end

local function ReaderFit()
    local f = reader
    local w = (f:GetWidth() or READER_W) - 30
    f.child:SetWidth(w)
    f.body:SetWidth(w)
    f.child:SetHeight((f.body:GetStringHeight() or 0) + 8)
    f.scroll:SetVerticalScroll(0)
end

local function ReaderShow(note)
    local f = reader
    f.noteID = note.id
    f.title:SetText(NoteTitle(note))
    UI:ApplyEasyNotesCustomFont(f.body, NormalizeDB().fontSize)
    f.body:SetText(note.body or "")
    local r, g, b = ns.TooltipTextColor()
    f.title:SetTextColor(r, g, b, 1)
    f.body:SetTextColor(r, g, b, 1)
    ReaderFit()
end

local function ReaderSave()
    local f = reader
    local db = NormalizeDB()
    db.reader = { x = f:GetLeft(), y = f:GetTop(), w = f:GetWidth(), h = f:GetHeight() }
end

local function BuildReader()
    local f = CreateFrame("Frame", "EasyNotesReader", UIParent, "BackdropTemplate")
    local saved = NormalizeDB().reader or {}
    f:SetSize(saved.w or READER_W, saved.h or READER_H)
    if saved.x and saved.y then
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", saved.x, saved.y)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    end
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:SetResizable(true)
    if f.SetResizeBounds then f:SetResizeBounds(220, 140) end
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        ReaderSave()
    end)
    ns.StyleMenuPanel(f)
    ns.SetRoundedRectBarHeight(f, 14)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title._efOwnColor = true
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -11)
    f.title:SetPoint("RIGHT", f, "RIGHT", -120, 0)
    f.title:SetJustifyH("LEFT")
    f.title:SetWordWrap(false)

    local close = ns.CreateCloseX(f, 14)
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
    close:SetScript("OnClick", function() f:Hide() end)
    ns.AttachEscClose(f)

    local nextBtn = ns.CreateModernButton(f, ">", 20, 18)
    nextBtn:SetPoint("RIGHT", close, "LEFT", -6, 0)
    nextBtn:SetScript("OnClick", function() notesNS.ReaderStep(1) end)
    local prevBtn = ns.CreateModernButton(f, "<", 20, 18)
    prevBtn:SetPoint("RIGHT", nextBtn, "LEFT", -2, 0)
    prevBtn:SetScript("OnClick", function() notesNS.ReaderStep(-1) end)
    local openBtn = ns.CreateModernButton(f, L["NOTES_OPEN_NOTE"], 64, 18)
    openBtn:SetPoint("RIGHT", prevBtn, "LEFT", -6, 0)
    openBtn:SetScript("OnClick", function()
        if f.noteID then notesNS.OpenNote(f.noteID) end
    end)

    f.scroll = CreateFrame("ScrollFrame", nil, f)
    f.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -34)
    f.scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 12)
    f.child = CreateFrame("Frame", nil, f.scroll)
    f.child:SetSize(READER_W - 30, 1)
    f.scroll:SetScrollChild(f.child)
    f.body = f.child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.body._efOwnColor = true
    f.body:SetPoint("TOPLEFT", f.child, "TOPLEFT", 0, 0)
    f.body:SetJustifyH("LEFT")
    f.body:SetJustifyV("TOP")
    f.body:SetWordWrap(true)
    f.scroll:EnableMouseWheel(true)
    f.scroll:SetScript("OnMouseWheel", function(self, delta)
        local most = math.max(0, (f.child:GetHeight() or 0) - (self:GetHeight() or 0))
        self:SetVerticalScroll(math.min(most, math.max(0, self:GetVerticalScroll() - delta * 30)))
    end)
    Utils.CreateMinimalScrollBar(f.scroll, f)

    -- Corner grip: drag to resize, the text reflows.
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(14, 14)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -3, 3)
    local gripTex = grip:CreateTexture(nil, "OVERLAY")
    gripTex:SetAllPoints()
    gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    gripTex:SetVertexColor(0.7, 0.7, 0.7, 0.8)
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        ReaderSave()
        ReaderFit()
    end)
    f:SetScript("OnSizeChanged", function() if f:IsShown() then ReaderFit() end end)
    if ns.RegisterThemeCallback then
        ns.RegisterThemeCallback(function()
            if f:IsShown() and f.noteID then
                local note = NoteByID(f.noteID)
                if note then ReaderShow(note) end
            end
        end)
    end
    f:Hide()
    return f
end

function notesNS.OpenReader(id)
    if not reader then reader = BuildReader() end
    local note = id and NoteByID(id) or ReaderNotes()[1]
    if not note then
        EasyFind:Print(L["NOTES_READER_EMPTY"])
        return
    end
    ReaderShow(note)
    reader:Show()
end

function notesNS.ReaderStep(delta)
    if not reader then return end
    local list = ReaderNotes()
    if #list == 0 then return end
    local idx = 1
    for i = 1, #list do
        if list[i].id == reader.noteID then idx = i break end
    end
    ReaderShow(list[((idx - 1 + delta) % #list) + 1])
end

function notesNS.ToggleReader()
    if reader and reader:IsShown() then
        reader:Hide()
    else
        notesNS.OpenReader(UI._notes.selectedID)
    end
end

-- The reader follows edits to the note it shows.
function notesNS.RefreshReader(id)
    if reader and reader:IsShown() and reader.noteID == id then
        local note = NoteByID(id)
        if note then ReaderShow(note) end
    end
end

-- ==== capture ===============================================================

local function MoneyText(copper)
    local fn = C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString or GetCoinTextureString
    if fn and copper and copper > 0 then return fn(copper) end
    return nil
end

local function CountLabel(label, count)
    if count and count > 1 then return label .. " x" .. count end
    return label
end

local function OpenCaptured(note)
    UI:OpenEasyNotes()
    UI:SelectEasyNote(note.id)
    UI:HideEasyNotesPalette()
    return note
end

function notesNS.SelectedQuestID()
    local QL = C_QuestLog
    local questID = QL and QL.GetSelectedQuest and QL.GetSelectedQuest()
    if questID and questID > 0 then return questID end
    return nil
end

-- The selected quest as a note: its objectives as checklist lines, then
-- its rewards.
function notesNS.CaptureQuest()
    local QL = C_QuestLog
    local questID = notesNS.SelectedQuestID()
    if not questID then return nil end
    local title = (QL.GetTitleForQuestID and QL.GetTitleForQuestID(questID)) or ("Quest " .. questID)
    local lines = {}
    local objectives = QL.GetQuestObjectives and QL.GetQuestObjectives(questID) or {}
    for i = 1, #objectives do
        local o = objectives[i]
        if o and o.text and o.text ~= "" then
            lines[#lines + 1] = (o.finished and CHECK_FILLED_PREFIX or CHECK_EMPTY_PREFIX) .. o.text
        end
    end
    local rewards = {}
    local n = GetNumQuestLogRewards and GetNumQuestLogRewards(questID) or 0
    for i = 1, n do
        local name, _, count = GetQuestLogRewardInfo(i, questID)
        local link = GetQuestLogItemLink and GetQuestLogItemLink("reward", i)
        if link or name then rewards[#rewards + 1] = CountLabel(link or name, count) end
    end
    local choices = GetNumQuestLogChoices and GetNumQuestLogChoices(questID) or 0
    for i = 1, choices do
        local name, _, count = GetQuestLogChoiceInfo(i, questID)
        local link = GetQuestLogItemLink and GetQuestLogItemLink("choice", i)
        if link or name then rewards[#rewards + 1] = CountLabel(link or name, count) end
    end
    local money = MoneyText(GetQuestLogRewardMoney and GetQuestLogRewardMoney(questID))
    if money then rewards[#rewards + 1] = money end
    local xp = GetQuestLogRewardXP and GetQuestLogRewardXP(questID)
    if xp and xp > 0 then rewards[#rewards + 1] = Utils.sformat(L["NOTES_CAPTURE_XP_FMT"], xp) end
    if #rewards > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = L["NOTES_CAPTURE_REWARDS"]
        for i = 1, #rewards do lines[#lines + 1] = BULLET_PREFIX .. rewards[i] end
    end
    local note = CreateNote(table.concat(lines, "\n"))
    note.name = title
    note.category = "Quests"
    return OpenCaptured(note)
end

function notesNS.OpenMailIndex()
    local index = InboxFrame and InboxFrame.openMailID
    if index and index > 0 and GetInboxHeaderInfo and OpenMailFrame and OpenMailFrame:IsShown() then
        return index
    end
    return nil
end

-- The open mail as a note: sender, text, then its attachments and coin.
function notesNS.CaptureMail()
    local index = notesNS.OpenMailIndex()
    if not index then return nil end
    local _, _, sender, subject, money = GetInboxHeaderInfo(index)
    local body = GetInboxText and GetInboxText(index) or ""
    local lines = {}
    if sender and sender ~= "" then lines[#lines + 1] = Utils.sformat(L["NOTES_CAPTURE_FROM_FMT"], sender) end
    if body and body ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = body
    end
    local items = {}
    for a = 1, (ATTACHMENTS_MAX_RECEIVE or 16) do
        local name, _, _, count = GetInboxItem(index, a)
        if name then
            local link = GetInboxItemLink and GetInboxItemLink(index, a)
            items[#items + 1] = CountLabel(link or name, count)
        end
    end
    local coin = MoneyText(money)
    if coin then items[#items + 1] = coin end
    if #items > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = L["NOTES_CAPTURE_ATTACHMENTS"]
        for i = 1, #items do lines[#lines + 1] = BULLET_PREFIX .. items[i] end
    end
    local note = CreateNote(table.concat(lines, "\n"))
    note.name = (subject and subject ~= "") and subject or L["NOTES_CAPTURE_MAIL_TITLE"]
    return OpenCaptured(note)
end

-- The bar's rows follow every change, a moment after the last one.
local searchRefreshDue
local function RefreshSearchRows()
    if searchRefreshDue then return end
    searchRefreshDue = true
    Utils.SafeAfter(0.3, function()
        searchRefreshDue = nil
        if ns.Database and ns.Database.RefreshDynamicCategory then ns.Database:RefreshDynamicCategory("notes") end
    end)
end

-- Note-context v2. A note carries two independent attachment systems:
--   appliesIn  -- situational filters (zone, instance, class, open UI panel...)
--                 deciding which notes surface on the homepage.
--   showsOn    -- tooltip-linked game objects (item, NPC, spell, quest...)
--                 surfacing the note on that object's tooltip.
-- Each appliesIn / showsOn entry is { type, id, name }. Only reliably
-- detectable situations are auto-detected; bosses and freeform strings are not.

local Ctx = notesNS.Context
local CtxKey = Ctx.Key

local TAG_COLORS = {
    { 0.84, 0.38, 0.40 }, { 0.92, 0.58, 0.30 }, { 0.84, 0.72, 0.34 },
    { 0.52, 0.74, 0.42 }, { 0.36, 0.72, 0.66 }, { 0.42, 0.62, 0.88 },
    { 0.60, 0.52, 0.86 }, { 0.82, 0.52, 0.82 }, { 0.86, 0.52, 0.64 },
    { 0.58, 0.62, 0.68 },
}

-- Deterministic per-tag colour so a tag looks the same everywhere it appears.
local function TagColor(key)
    key = tostring(key or "")
    local h = 5381
    for i = 1, #key do
        h = (h * 33 + key:byte(i)) % 2147483648
    end
    return TAG_COLORS[(h % #TAG_COLORS) + 1]
end


local function NoteHasContext(note, key)
    if not (note and note.appliesIn) then return false end
    for i = 1, #note.appliesIn do
        if CtxKey(note.appliesIn[i]) == key then return true end
    end
    return false
end

local function ToggleNoteContext(note, entry)
    if not (note and entry and entry.type and entry.id ~= nil) then return end
    note.appliesIn = note.appliesIn or {}
    local key = CtxKey(entry)
    for i = 1, #note.appliesIn do
        if CtxKey(note.appliesIn[i]) == key then
            tremove(note.appliesIn, i)
            note.updated = time()
            return
        end
    end
    note.appliesIn[#note.appliesIn + 1] = { type = entry.type, id = entry.id, name = entry.name or tostring(entry.id) }
    note.updated = time()
end

local function NoteHasShowsOn(note, key)
    if not (note and note.showsOn) then return false end
    for i = 1, #note.showsOn do
        if CtxKey(note.showsOn[i]) == key then return true end
    end
    return false
end

local function ToggleNoteShowsOn(note, entry)
    if not (note and entry and entry.type and entry.id ~= nil) then return end
    note.showsOn = note.showsOn or {}
    local key = CtxKey(entry)
    for i = 1, #note.showsOn do
        if CtxKey(note.showsOn[i]) == key then
            tremove(note.showsOn, i)
            note.updated = time()
            return
        end
    end
    note.showsOn[#note.showsOn + 1] = { type = entry.type, id = entry.id, name = entry.name or tostring(entry.id) }
    note.updated = time()
end

-- A unit's note is the one shown on it; opening one makes it when there
-- is none, account-wide (you meet players and NPCs on every character).
function notesNS.FindUnitNote(entry)
    if not entry then return nil end
    local key = CtxKey(entry)
    local notes = NotesStore()
    for i = 1, #notes do
        if NoteHasShowsOn(notes[i], key) then return notes[i] end
    end
    return nil
end

function notesNS.OpenUnitNote(entry)
    if not entry then return end
    local note = notesNS.FindUnitNote(entry)
    if not note then
        note = CreateNote("")
        note.name = entry.name
        note.scope = "account"
        note.category = (entry.type == "player" and "Players") or (entry.type == "item" and "Items")
            or (entry.type == "spell" and "Abilities") or "NPCs"
        note.showsOn[1] = { type = entry.type, id = entry.id, name = entry.name }
    end
    UI:OpenEasyNotes()
    UI:SelectEasyNote(note.id)
    UI:HideEasyNotesPalette()
    UI:FocusEasyNoteEditor()
end

local function CountNotesWithContext(key)
    local notes = NotesStore()
    local n = 0
    for i = 1, #notes do
        if NoteHasContext(notes[i], key) then n = n + 1 end
    end
    return n
end

Ctx.SetOnChange(function(event)
    if event == "PLAYER_ENTERING_WORLD" and UI.CheckEasyNotesReminders then
        pcall(UI.CheckEasyNotesReminders, UI)
    end
    if UI.OnEasyNotesContextChanged then
        pcall(UI.OnEasyNotesContextChanged, UI, event)
    end
end)

-- Reminders: a note may carry an optional reminderAt timestamp. A slow ticker
-- (and the context watcher's PLAYER_ENTERING_WORLD) fire due ones with a chat
-- alert, then clear them so each fires once.
function UI:CheckEasyNotesReminders()
    if type(EasyNotesDB) ~= "table" or type(EasyNotesDB.notes) ~= "table" then return end
    local now = time()
    local notes = EasyNotesDB.notes
    for i = 1, #notes do
        local note = notes[i]
        if note.reminderAt and note.reminderAt <= now then
            note.reminderAt = nil
            EasyFind:Print(Utils.sformat(L["NOTES_REMINDER_FMT"], NoteTitle(note)))
            if PlaySound and SOUNDKIT then pcall(PlaySound, SOUNDKIT.IG_QUEST_LOG_OPEN) end
        end
    end
end
if C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(60, function() UI:CheckEasyNotesReminders() end)
end


local function ConfirmDeleteNote(id)
    local ids = type(id) == "table" and id or { id }
    if #ids == 0 then return end
    local prompt, name
    if #ids == 1 then
        local idx = FindNoteIndex(ids[1])
        local note = idx and NotesStore()[idx]
        if not note then return end
        name = NoteTitle(note)
        if #name > 40 then name = name:sub(1, 40) .. "..." end
        prompt = Utils.sformat(L["NOTES_DELETE_ONE"], name)
    else
        prompt = Utils.sformat(L["NOTES_DELETE_MANY"], #ids)
    end
    if not ns.ShowThemedDialog then return end
    ns.ShowThemedDialog({
        text = prompt,
        messageColor = ns.GOLD_COLOR,
        acceptText = _G.DELETE or "Delete",
        onAccept = function()
            local wasPalette = UI._notes.paletteShown
            for i = 1, #ids do DeleteNote(ids[i]) end
            if #ids == 1 then
                EasyFind:Print(Utils.sformat(L["NOTES_DELETED_ONE_UNDO"], prompt and name or "?"))
            else
                EasyFind:Print(Utils.sformat(L["NOTES_DELETED_MANY_UNDO"], #ids))
            end
            local sel = UI._notes.paletteSelection
            for k in pairs(sel) do sel[k] = nil end
            UI:RefreshEasyNotes()
            if wasPalette then UI:RefreshEasyNotesPalette() else UI:ShowEasyNotesPalette() end
        end,
    })
end

-- Buttons read the live EasyFind theme tables (BTN_FILL_*, NAV_SELECTED_FILL,
-- TEXT_PRIMARY) at paint time, and register here so an open Notes window
-- repaints when the EasyFind theme flips. The tables mutate in place on a flip,
-- but a paint already applied does not, so a repaint sweep is required.
local themedButtons = {}

local function PaintSubtleButton(btn, hovered)
    if not ns.SetRoundedRectFill then return end
    -- Fill only. Text stays GameFontHighlightSmall white and is never recolored,
    -- exactly like EasyFind's theme/font/indicator selector buttons: constant
    -- color and font before and after hover. Control fills stay dark on every
    -- theme, so white text reads on light themes too.
    local fill = (hovered and ns.BTN_FILL_HOVER or ns.BTN_FILL_NORMAL) or { 0.13, 0.13, 0.14 }
    ns.SetRoundedRectFill(btn, fill[1], fill[2], fill[3], 1, true)
end

-- The same fill as the window's other buttons, so the header reads as one.
local function PaintAccentButton(btn)
    if not ns.SetRoundedRectFill then return end
    local ac = ns.BTN_FILL_NORMAL or ns.NAV_SELECTED_FILL or { 0.20, 0.30, 0.45 }
    ns.SetRoundedRectFill(btn, ac[1], ac[2], ac[3], 1, true)
end

local function TrackThemedButton(btn, accent)
    if btn._efThemedTracked then return end
    btn._efThemedTracked = true
    if accent then btn._efAccent = true end
    themedButtons[#themedButtons + 1] = btn
end

if ns.RegisterThemeCallback then
    ns.RegisterThemeCallback(function()
        for i = 1, #themedButtons do
            local btn = themedButtons[i]
            if btn.actionKey then UI:RefreshEasyNotesToolbarButton(btn)
            elseif btn._efAccent then PaintAccentButton(btn)
            else PaintSubtleButton(btn, false) end
        end
    end)
end

local function StyleSubtleButton(btn, label, w, h)
    btn:SetSize(w or 24, h or 24)
    local bar = math.min(h or 22, 10)
    if ns.CreateRoundedRectBorder then
        ns.CreateRoundedRectBorder(btn)
        ns.SetRoundedRectBarHeight(btn, bar)
        ns.SetRoundedRectBorderBgAlpha(btn, 1)
        ns.SetRoundedRectBorderEdgeShown(btn, false)
    end
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.text:SetPoint("CENTER")
    btn.text:SetText(label)
    TrackThemedButton(btn)
    PaintSubtleButton(btn, false)
    btn:SetScript("OnEnter", function(self) PaintSubtleButton(self, true) end)
    btn:SetScript("OnLeave", function(self) PaintSubtleButton(self, false) end)
    return btn
end

local function StyleAccentButton(btn, label, w, h)
    btn:SetSize(w or 56, h or STD_BTN_H)
    btn._efAccent = true
    if ns.CreateRoundedRectBorder then
        ns.CreateRoundedRectBorder(btn)
        ns.SetRoundedRectBarHeight(btn, 10)
        ns.SetRoundedRectBorderEdgeShown(btn, false)
    end
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    btn.text:SetPoint("CENTER")
    btn.text:SetText(label)
    btn.text:SetTextColor(1, 1, 1, 1)
    TrackThemedButton(btn, true)
    PaintAccentButton(btn)
end

-- Custom note font built from the user's Friz screenshot: regular Friz at ASCII,
-- emboldened Friz at the SMP math-bold codepoints. Bold is char-replace (swap
-- letters to those codepoints), so it renders bold Friz natively while typing --
-- no overlay, no drift. MUST be TrueType: WoW dropped .otf/CFF support (it fails
-- silently and renders glyphs malformed/sliced), so this is a real .ttf.
local CUSTOM_FONT_PATH = "Interface\\AddOns\\EasyFind_Notes\\Fonts\\FrizNotes.ttf"

local function GlyphSize(byte)
    if byte >= 240 then return 4 end
    if byte >= 224 then return 3 end
    if byte >= 192 then return 2 end
    return 1
end

local function MatchLinePrefix(text, byteOffset)
    if text:sub(byteOffset, byteOffset + #BULLET_PREFIX - 1) == BULLET_PREFIX then return #BULLET_PREFIX end
    if text:sub(byteOffset, byteOffset + #CHECK_EMPTY_PREFIX - 1) == CHECK_EMPTY_PREFIX then return #CHECK_EMPTY_PREFIX end
    if text:sub(byteOffset, byteOffset + #CHECK_FILLED_PREFIX - 1) == CHECK_FILLED_PREFIX then return #CHECK_FILLED_PREFIX end
    local num = text:sub(byteOffset, byteOffset + 12):match("^(%d+%. )")
    if num then return #num end
    return 0
end

local function FindLineStartByte(text, pos)
    local before = text:sub(1, pos)
    local nlIdx = before:find("\n[^\n]*$")
    return nlIdx and (nlIdx + 1) or 1
end

local function FindLineEndByte(text, pos)
    local nlIdx = text:find("\n", pos + 1)
    return nlIdx and (nlIdx - 1) or #text
end

-- Project the raw note text to a plain, lowercased string for find/replace,
-- with map[plainByte] -> raw byte. SMP bold/italic glyphs collapse to ASCII;
-- color and hyperlink escapes are dropped so they never match or split a hit.
local function BuildPlainIndex(raw)
    local parts, map, plainLen = {}, {}, 0
    local function emit(s, rawStart)
        parts[#parts + 1] = s
        for _ = 1, #s do
            plainLen = plainLen + 1
            map[plainLen] = rawStart
        end
    end
    local i, n = 1, #raw
    while i <= n do
        local b = raw:byte(i)
        if b == 124 then
            local nxt = raw:byte(i + 1)
            if nxt == 99 then
                i = i + 10
            elseif nxt == 114 then
                i = i + 2
            elseif nxt == 72 then
                local c = raw:find("|h", i + 2, true)
                i = c and (c + 2) or (n + 1)
            elseif nxt == 104 then
                i = i + 2
            elseif nxt == 84 then
                local c = raw:find("|t", i + 2, true)
                i = c and (c + 2) or (n + 1)
            elseif nxt == 124 then
                emit("|", i)
                i = i + 2
            elseif nxt == 110 then
                emit("\n", i)
                i = i + 2
            else
                emit("|", i)
                i = i + 1
            end
        else
            local sz = GlyphSize(b)
            emit(GlyphPlain(raw:sub(i, i + sz - 1)), i)
            i = i + sz
        end
    end
    map[plainLen + 1] = n + 1
    return table.concat(parts):lower(), map
end

local function FindNoteMatches(raw, query)
    local out = {}
    if not raw or not query or query == "" then return out end
    local plain, map = BuildPlainIndex(raw)
    local q = query:lower()
    local pos = 1
    while true do
        local ps, pe = plain:find(q, pos, true)
        if not ps then break end
        out[#out + 1] = { lo = map[ps], hi = (map[pe + 1] or (#raw + 1)) - 1 }
        pos = pe + 1
    end
    return out
end

-- A logical line beginning with 1-3 '#' then whitespace is a header.
-- Header lines no longer carry a "#" marker; a header is a line whose text
-- starts bold (the style "## " switches the line into).
local function GetNoteHeaders(text)
    local out = {}
    if not text or text == "" then return out end
    local n = #text
    local pos = 1
    while pos <= n + 1 do
        local nl = text:find("\n", pos, true)
        local lineEnd = nl and (nl - 1) or n
        local line = text:sub(pos, lineEnd)
        if line ~= "" then
            local firstGlyph = iterUtf8(line)()
            if firstGlyph and GlyphHasBold(firstGlyph) then
                local title = strtrim(MapSelection(line, GlyphPlain))
                out[#out + 1] = {
                    level = 1,
                    title = title == "" and L["NOTES_UNTITLED_HEADER"] or title,
                    byteStart = pos,
                }
            end
        end
        if not nl then break end
        pos = nl + 1
    end
    return out
end

local function GetMeasureMeter(editor)
    if not UI._notes._meter then
        local fs = editor:CreateFontString(nil, "ARTWORK")
        fs:Hide()
        if fs.SetWordWrap then fs:SetWordWrap(false) end
        if fs.SetNonSpaceWrap then fs:SetNonSpaceWrap(false) end
        UI._notes._meter = fs
    end
    local meter = UI._notes._meter
    local font, size, flags = editor:GetFont()
    if font and size then meter:SetFont(font, size, flags) end
    return meter
end

local function LayoutCharacters(text, editor, wrapWidth)
    local meter = GetMeasureMeter(editor)
    local positions = {}
    local lineIdx = 1
    local lineCharStart = 1
    local prevCumX = 0
    local lineStartByte = 1
    local prefixCutoff = MatchLinePrefix(text, 1)
    if prefixCutoff > 0 then prefixCutoff = prefixCutoff end
    local i = 1
    local len = #text
    while i <= len do
        local b = text:byte(i)
        if b == 10 then
            positions[#positions + 1] = {
                byteStart = i, byteEnd = i, line = lineIdx,
                x = prevCumX, width = 0, glyph = "\n", isNewline = true,
            }
            lineIdx = lineIdx + 1
            lineCharStart = #positions + 1
            prevCumX = 0
            lineStartByte = i + 1
            local pl = MatchLinePrefix(text, lineStartByte)
            prefixCutoff = lineStartByte + pl - 1
            i = i + 1
        else
            local size = GlyphSize(b)
            local glyph = text:sub(i, i + size - 1)
            local isPrefix = (i + size - 1) <= prefixCutoff
            meter:SetText(text:sub(lineStartByte, i + size - 1))
            local cumX = meter:GetStringWidth() or 0
            local glyphWidth = cumX - prevCumX
            if cumX > wrapWidth and prevCumX > 0 then
                local breakIdx
                for k = #positions, lineCharStart, -1 do
                    if positions[k].glyph == " " then breakIdx = k; break end
                end
                -- Only an INTERIOR break (chars after the space) reflows the tail.
                -- If the space is the last glyph so far, positions[breakIdx+1] is
                -- nil, so the current glyph just starts the new line (else branch).
                if breakIdx and breakIdx < #positions then
                    lineIdx = lineIdx + 1
                    lineStartByte = positions[breakIdx + 1].byteStart
                    local rolling = 0
                    for k = breakIdx + 1, #positions do
                        positions[k].line = lineIdx
                        meter:SetText(text:sub(lineStartByte, positions[k].byteEnd))
                        local cwx = meter:GetStringWidth() or 0
                        positions[k].x = rolling
                        positions[k].width = cwx - rolling
                        rolling = cwx
                    end
                    prevCumX = rolling
                    meter:SetText(text:sub(lineStartByte, i + size - 1))
                    cumX = meter:GetStringWidth() or 0
                    glyphWidth = cumX - prevCumX
                    lineCharStart = breakIdx + 1
                else
                    lineIdx = lineIdx + 1
                    lineStartByte = i
                    lineCharStart = #positions + 1
                    prevCumX = 0
                    meter:SetText(glyph)
                    cumX = meter:GetStringWidth() or 0
                    glyphWidth = cumX
                end
            end
            positions[#positions + 1] = {
                byteStart = i, byteEnd = i + size - 1, line = lineIdx,
                x = prevCumX, width = glyphWidth, glyph = glyph,
                isPrefix = isPrefix,
            }
            prevCumX = cumX
            i = i + size
        end
    end
    return positions
end

local function ComputeDecorationRects(positions, deco)
    local linesUsed = {}
    local order = {}
    for _, p in ipairs(positions) do
        if not p.isNewline and not p.isPrefix and p.byteStart >= deco.startByte and p.byteStart < deco.endByte then
            local r = linesUsed[p.line]
            if not r then
                r = { x1 = p.x, x2 = p.x + p.width }
                linesUsed[p.line] = r
                order[#order + 1] = p.line
            else
                if p.x < r.x1 then r.x1 = p.x end
                if p.x + p.width > r.x2 then r.x2 = p.x + p.width end
            end
        end
    end
    local rects = {}
    for _, lineNum in ipairs(order) do
        local r = linesUsed[lineNum]
        rects[#rects + 1] = { line = lineNum, x1 = r.x1, x2 = r.x2 }
    end
    return rects
end

function UI:ToggleEasyNotesFontFlyout()
    local frame = UI._notes.frame
    if not (frame and frame.fontSizeFlyout) then return end
    frame.fontSizeFlyout:SetShown(not frame.fontSizeFlyout:IsShown())
end

function UI:RefreshEasyNotesFontSizeButton()
    local frame = UI._notes.frame
    if frame and frame.fontSizeButton and frame.fontSizeButton.text then
        frame.fontSizeButton.text:SetText(tostring(EasyNotesDB.fontSize or FONT_SIZE_DEFAULT))
    end
end

-- The note body must look the same regardless of the window's UI scale,
-- so the editbox font is divided by the scale relative to the default.
function UI:ApplyEasyNotesEditorFont()
    local frame = UI._notes.frame
    if not (frame and frame.editor) then return end
    local db = NormalizeDB()
    local scale = db.uiScale or UI_SCALE_DEFAULT
    local size = (db.fontSize or FONT_SIZE_DEFAULT) * UI_SCALE_DEFAULT / scale
    -- Always the custom Friz font: normal text renders as Friz, and the SMP
    -- math-bold codepoints (char-replace) render as bold Friz -- natively, while
    -- typing, with no overlay to drift.
    self:ApplyEasyNotesCustomFont(frame.editor, size)
    -- A little breathing room between lines. WoW draws the selection highlight as
    -- line-height + spacing, so large spacing makes the highlight hang below the
    -- text; keep it small. Overlays measure actual line Y (GetSpacing), so they
    -- stay aligned regardless.
    if frame.editor.SetSpacing then frame.editor:SetSpacing(2) end
end

function UI:AdjustEasyNotesFontSize(delta, reset, absolute)
    NormalizeDB()
    local cur = EasyNotesDB.fontSize or FONT_SIZE_DEFAULT
    local nxt
    if absolute then nxt = absolute
    elseif reset then nxt = FONT_SIZE_DEFAULT
    else nxt = cur + (delta or 0) end
    if nxt < FONT_SIZE_MIN then nxt = FONT_SIZE_MIN end
    if nxt > FONT_SIZE_MAX then nxt = FONT_SIZE_MAX end
    if nxt == cur and not reset then return end
    EasyNotesDB.fontSize = nxt
    self:ApplyEasyNotesEditorFont()
    UI:QueueEasyNotesOverlayUpdate()
    UI:ReSettleEasyNotesOverlay()
    self:RefreshEasyNotesFontSizeButton()
    self:RefreshEasyNotesSettings()
end

function UI:AdjustEasyNotesUIScale(delta, reset, absolute)
    local db = NormalizeDB()
    local cur = db.uiScale or UI_SCALE_DEFAULT
    local nxt
    if absolute then nxt = absolute
    elseif reset then nxt = UI_SCALE_DEFAULT
    else nxt = cur + (delta or 0) end
    nxt = math.floor(nxt * 100 + 0.5) / 100
    if nxt < UI_SCALE_MIN then nxt = UI_SCALE_MIN end
    if nxt > UI_SCALE_MAX then nxt = UI_SCALE_MAX end
    if nxt == cur and not reset then return end
    db.uiScale = nxt
    local frame = UI._notes.frame
    if frame then
        -- SetScale reinterprets the anchor offset at the new scale, which
        -- shifts the window; capture the corner and re-pin it afterwards.
        local left, top = frame:GetLeft(), frame:GetTop()
        frame:SetScale(nxt)
        if left and top and cur > 0 then
            local f = cur / nxt
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * f, top * f)
        end
        self:ApplyEasyNotesEditorFont()
        UI:QueueEasyNotesOverlayUpdate()
        UI:ReSettleEasyNotesOverlay()
    end
    self:RefreshEasyNotesSettings()
end

function UI:ApplyEasyNotesOpacity()
    local frame = UI._notes.frame
    if not frame then return end
    local op = NormalizeDB().opacity or OPACITY_DEFAULT
    if ns.SetRoundedRectBorderBgAlpha then
        ns.SetRoundedRectBorderBgAlpha(frame, op)
    end
end

function UI:AdjustEasyNotesOpacity(delta, reset, absolute)
    local db = NormalizeDB()
    local cur = db.opacity or OPACITY_DEFAULT
    local nxt
    if absolute then nxt = absolute
    elseif reset then nxt = OPACITY_DEFAULT
    else nxt = cur + (delta or 0) end
    nxt = math.floor(nxt * 100 + 0.5) / 100
    if nxt < OPACITY_MIN then nxt = OPACITY_MIN end
    if nxt > OPACITY_DEFAULT then nxt = OPACITY_DEFAULT end
    if nxt == cur and not reset then return end
    db.opacity = nxt
    self:ApplyEasyNotesOpacity()
    self:RefreshEasyNotesSettings()
end

function UI:ApplyEasyNotesCustomFont(region, sizeOverride, flagsOverride)
    if not (region and region.GetFont and region.SetFont) then return end
    local origFont, origSize, origFlags = region:GetFont()
    if not (origFont and origSize) then return end
    local size = sizeOverride or origSize
    local flags = flagsOverride or origFlags
    -- FrizNotes.ttf carries the SMP bold codepoints for char-replace bold. If it
    -- isn't loaded yet (a newly added font file needs a full client relaunch, not
    -- just /reload), keep the base font so text still renders. No .otf fallback --
    -- WoW can't render .otf/CFF, so STIX2Math.otf would slice glyphs the same way.
    if not pcall(region.SetFont, region, CUSTOM_FONT_PATH, size, flags) then
        region:SetFont(origFont, size, flags)
    end
end

-- One-time body migration from legacy SMP glyphs to PUA. Decoration byte
-- offsets (startByte 1-based inclusive, endByte exclusive) shift when 4-byte
-- glyphs become 3-byte, so the body walk records the old->new offset at every
-- byte gap and decorations translate through that map.
function UI:MigrateEasyNotesGlyphEncoding()
    if type(EasyNotesDB) ~= "table" or EasyNotesDB.glyphEnc == 2 then return end
    local m = {}
    for i = 0, 25 do
        m[utf8FromCp(0x1D400 + i)] = utf8FromCp(0xE01A + i)
        m[utf8FromCp(0x1D41A + i)] = utf8FromCp(0xE000 + i)
        m[utf8FromCp(0x1D44E + i)] = utf8FromCp(0xE040 + i)
        m[utf8FromCp(0x1D434 + i)] = utf8FromCp(0xE05A + i)
        m[utf8FromCp(0x1D468 + i)] = utf8FromCp(0xE09A + i)
        m[utf8FromCp(0x1D482 + i)] = utf8FromCp(0xE080 + i)
    end
    m[utf8FromCp(0x210E)] = utf8FromCp(0xE047)
    for i = 0, 9 do m[utf8FromCp(0x1D7CE + i)] = utf8FromCp(0xE034 + i) end
    local notes = EasyNotesDB.notes
    if type(notes) == "table" then
        for n = 1, #notes do
            local note = notes[n]
            local body = note and note.body
            if type(body) == "string" and body ~= "" then
                local out = {}
                local gapMap = { [0] = 0 }
                local oldOff, newOff = 0, 0
                local changed = false
                for g in iterUtf8(body) do
                    local rep = m[g]
                    if rep then changed = true else rep = g end
                    out[#out + 1] = rep
                    for k = 1, #g do
                        gapMap[oldOff + k] = newOff + (k < #g and math.min(k, #rep) or #rep)
                    end
                    oldOff = oldOff + #g
                    newOff = newOff + #rep
                end
                if changed then
                    note.body = table.concat(out)
                    local decos = note.decorations
                    if type(decos) == "table" then
                        for d = 1, #decos do
                            local deco = decos[d]
                            if deco and deco.startByte and deco.endByte then
                                deco.startByte = (gapMap[deco.startByte - 1] or newOff) + 1
                                deco.endByte = (gapMap[deco.endByte - 1] or newOff) + 1
                            end
                        end
                    end
                end
            end
        end
    end
    EasyNotesDB.glyphEnc = 2
end

-- Formatted glyphs must live at 3-byte PUA codepoints (one caret stop per
-- glyph in the editbox); legacy 4-byte SMP stays active only until the live
-- font carries the PUA glyphs. A font file update is only read at client
-- start, so the switch arms itself on the first session where the PUA glyph
-- measures as real instead of the missing-glyph box.
function UI:DetectEasyNotesGlyphEncoding()
    if UI._notes.puaGlyphs then return end
    local fs = UI._notes.encProbe
    if not fs then
        fs = UIParent:CreateFontString(nil, "BACKGROUND")
        fs:SetAlpha(0)
        UI._notes.encProbe = fs
    end
    if not pcall(fs.SetFont, fs, CUSTOM_FONT_PATH, 100, "") then return end
    fs:SetText("\238\128\128")            -- U+E000, PUA bold 'a'
    local puaW = fs:GetStringWidth() or 0
    -- Control must NOT be in U+F8F0-F8FF (WoW zero-widths that sub-block even
    -- when mapped); U+0378 is unassigned so it always measures as the box.
    fs:SetText("\205\184")                -- U+0378: missing-glyph box
    local tofuW = fs:GetStringWidth() or 0
    fs:SetText("")
    if puaW <= 0 or math.abs(puaW - tofuW) < 0.5 then return end
    UI._notes.puaGlyphs = true
    UI.FillFormatMaps(2)
    self:MigrateEasyNotesGlyphEncoding()
end

-- WoW's editbox always blinks its caret, selection or not; there is no API to
-- hide it, and a caret parked on a highlight reads as broken next to any real
-- word processor. The caret is an internal thin vertical Texture region of the
-- editbox: find it once (excluding our own decoration textures) and blank it
-- while a selection is tracked, restore it when the selection collapses.
function UI:UpdateEasyNotesCaretVisibility()
    local ed = UI._notes.frame and UI._notes.frame.editor
    if not ed then return end
    local tex = UI._notes.caretTex
    if not tex then
        local pool = UI._notes.decoTextures
        local regions = { ed:GetRegions() }
        for i = 1, #regions do
            local r = regions[i]
            if r.GetObjectType and r:GetObjectType() == "Texture" then
                local own = false
                if pool then
                    for p = 1, #pool do
                        if pool[p] == r then own = true break end
                    end
                end
                if not own then
                    local w, h = r:GetSize()
                    if w > 0 and w <= 4 and h >= 6 then
                        tex = r
                        UI._notes.caretTex = r
                        break
                    end
                end
            end
        end
        if not tex then return end
    end
    tex:SetAlpha(UI._notes.curSelection and 0 or 1)
end

function UI:GetEasyNotesFrame()
    return UI._notes.frame
end

-- Pool acquisition, parameterized per host: regions are created as children of
-- the passed editor so they scroll with its text.
function Fmt.AcquireDecoTexture(editor, pool, index)
    local tex = pool[index]
    if tex then return tex end
    tex = editor:CreateTexture(nil, "OVERLAY")
    tex:SetColorTexture(0.92, 0.92, 0.94, 1)
    pool[index] = tex
    return tex
end

-- FontString overlays used to draw bold runs over the Friz base text.
function Fmt.AcquireRunOverlay(editor, pool, index)
    local fs = pool[index]
    if fs then return fs end
    fs = editor:CreateFontString(nil, "OVERLAY")
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    pool[index] = fs
    return fs
end

function UI:GetEasyNotesDecorationTexture(index)
    UI._notes.decoTextures = UI._notes.decoTextures or {}
    local frame = UI._notes.frame
    if not (frame and frame.editor) then return nil end
    return Fmt.AcquireDecoTexture(frame.editor, UI._notes.decoTextures, index)
end

function UI:GetEasyNotesRunOverlay(index)
    UI._notes.runOverlays = UI._notes.runOverlays or {}
    local frame = UI._notes.frame
    if not (frame and frame.editor) then return nil end
    return Fmt.AcquireRunOverlay(frame.editor, UI._notes.runOverlays, index)
end

-- Per-line text runs of a bold/italic decoration: the run's text and its left x
-- on each wrapped line, so an overlay FontString can be placed exactly over it.
local function ComputeTextRuns(positions, deco)
    local lineData, order = {}, {}
    for _, p in ipairs(positions) do
        if not p.isNewline and not p.isPrefix
           and p.byteStart >= deco.startByte and p.byteStart < deco.endByte then
            local d = lineData[p.line]
            if not d then
                d = { x = p.x, text = p.glyph }
                lineData[p.line] = d
                order[#order + 1] = p.line
            else
                d.text = d.text .. p.glyph
                if p.x < d.x then d.x = p.x end
            end
        end
    end
    local runs = {}
    for _, ln in ipairs(order) do
        runs[#runs + 1] = { line = ln, x = lineData[ln].x, text = lineData[ln].text }
    end
    return runs
end

-- One-time per note: convert SMP bold/italic glyphs in the body to plain text
-- plus bold/italic decoration ranges, so rich-text v2 can render in Friz.
function UI:MigrateNoteToRichText2(note)
    if not note or note._rt2 then return end
    note._rt2 = true
    local body = note.body or ""
    note.decorations = note.decorations or {}
    local out, outLen = {}, 0
    local bStart, iStart
    for g in iterUtf8(body) do
        local gStart = outLen + 1
        local hasB = GlyphHasBold(g)
        local hasI = GlyphHasItalic(g)
        if hasB and not bStart then bStart = gStart end
        if not hasB and bStart then
            note.decorations[#note.decorations + 1] = { kind = "bold", startByte = bStart, endByte = gStart }
            bStart = nil
        end
        if hasI and not iStart then iStart = gStart end
        if not hasI and iStart then
            note.decorations[#note.decorations + 1] = { kind = "italic", startByte = iStart, endByte = gStart }
            iStart = nil
        end
        local plainG = GlyphPlain(g)
        out[#out + 1] = plainG
        outLen = outLen + #plainG
    end
    local endByte = outLen + 1
    if bStart then note.decorations[#note.decorations + 1] = { kind = "bold", startByte = bStart, endByte = endByte } end
    if iStart then note.decorations[#note.decorations + 1] = { kind = "italic", startByte = iStart, endByte = endByte } end
    note.body = table.concat(out)
    -- No merge needed: runs are already maximal (a run only closes when its style
    -- ends), and MergeAdjacentDecorations is defined later in the file.
end

-- One-time cleanup for notes coloured by the old |c-escape implementation.
-- Editboxes show |c...|r literally, so those notes are full of visible junk.
-- Strip every escape, turn well-formed |cAARRGGBB..|r spans into color
-- decorations, and shift existing decorations left by the bytes removed before
-- them so bold/italic/underline stay aligned to the now-shorter body.
function UI:MigrateColorEscapes(note)
    if not note or note._colorMigrated then return end
    local body = note.body or ""
    if not sfind(body, "|c", 1, true) and not sfind(body, "|r", 1, true) then
        note._colorMigrated = true
        return
    end
    note._colorMigrated = true
    note.decorations = note.decorations or {}
    local out, outLen = {}, 0
    local removed = 0
    local cumRemoved = {}          -- cumRemoved[oldIndex] = bytes removed before it
    local activeColor, colorStart
    local i, n = 1, #body
    while i <= n do
        cumRemoved[i] = removed
        local c = body:sub(i, i)
        if c == "|" then
            local nxt = body:sub(i + 1, i + 1)
            if nxt == "c" then
                local hex = body:sub(i + 2, i + 9)
                local rr = tonumber(hex:sub(3, 4), 16)
                local gg = tonumber(hex:sub(5, 6), 16)
                local bb = tonumber(hex:sub(7, 8), 16)
                if activeColor and outLen + 1 > colorStart then
                    note.decorations[#note.decorations + 1] = { kind = "color",
                        startByte = colorStart, endByte = outLen + 1,
                        r = activeColor.r, g = activeColor.g, b = activeColor.b }
                end
                if rr and gg and bb then
                    activeColor = { r = rr / 255, g = gg / 255, b = bb / 255 }
                    colorStart = outLen + 1
                else
                    activeColor = nil
                end
                removed = removed + 10
                i = i + 10
            elseif nxt == "r" then
                if activeColor and outLen + 1 > colorStart then
                    note.decorations[#note.decorations + 1] = { kind = "color",
                        startByte = colorStart, endByte = outLen + 1,
                        r = activeColor.r, g = activeColor.g, b = activeColor.b }
                end
                activeColor = nil
                removed = removed + 2
                i = i + 2
            else
                out[#out + 1] = c; outLen = outLen + 1; i = i + 1
            end
        else
            out[#out + 1] = c; outLen = outLen + 1; i = i + 1
        end
    end
    if activeColor and outLen + 1 > colorStart then
        note.decorations[#note.decorations + 1] = { kind = "color",
            startByte = colorStart, endByte = outLen + 1,
            r = activeColor.r, g = activeColor.g, b = activeColor.b }
    end
    local newMax = outLen + 1
    local function remap(oldByte)
        local shifted = oldByte - (cumRemoved[oldByte] or removed)
        if shifted < 1 then shifted = 1 end
        if shifted > newMax then shifted = newMax end
        return shifted
    end
    for _, d in ipairs(note.decorations) do
        if d.kind ~= "color" then
            d.startByte = remap(d.startByte)
            d.endByte = remap(d.endByte)
        end
    end
    note.body = table.concat(out)
    for idx = #note.decorations, 1, -1 do
        local d = note.decorations[idx]
        if d.endByte <= d.startByte then tremove(note.decorations, idx) end
    end
end

-- One-time: convert bold/italic/underline/strike DECORATIONS (the old drifting
-- overlay model) into markdown markers in the body text. Colour stays a
-- decoration; its byte positions are shifted for the markers inserted before them.
function UI:MigrateNoteToMarkdown(note)
    if not note or note._md then return end
    note._md = true
    local decos = note.decorations
    if not decos or #decos == 0 then return end
    local inserts, color = {}, {}
    for i = 1, #decos do
        local d = decos[i]
        local m = MD_MARKERS[d.kind]
        if m then
            inserts[#inserts + 1] = { pos = d.startByte, str = m }
            inserts[#inserts + 1] = { pos = d.endByte, str = m }
        elseif d.kind == "color" then
            color[#color + 1] = d
        end
    end
    if #inserts == 0 then return end
    -- Shift colour positions for every marker inserted at or before them (a marker
    -- inserted at position P pushes the char at P, and anything after it, right).
    for _, c in ipairs(color) do
        local addStart, addEnd = 0, 0
        for _, ins in ipairs(inserts) do
            if ins.pos <= c.startByte then addStart = addStart + #ins.str end
            if ins.pos <= c.endByte then addEnd = addEnd + #ins.str end
        end
        c.startByte = c.startByte + addStart
        c.endByte = c.endByte + addEnd
    end
    -- Insert markers from the end backward so earlier byte positions stay valid.
    tsort(inserts, function(a, b) return a.pos > b.pos end)
    local body = note.body or ""
    for _, ins in ipairs(inserts) do
        body = body:sub(1, ins.pos - 1) .. ins.str .. body:sub(ins.pos)
    end
    note.body = body
    note.decorations = color
end

local function MeasureLineYMap(text, editor, positions)
    local meter = GetMeasureMeter(editor)
    meter:SetWidth(4096)
    meter:SetText("M\nM")
    local h2 = meter:GetStringHeight() or 0
    meter:SetText("M")
    local h1 = meter:GetStringHeight() or 0
    -- Keep the advance FRACTIONAL. Fonts report non-integer line heights,
    -- and rounding here multiplies the error by the line index -- overlays
    -- drift further off the text every row down the note. Round only the
    -- final per-line offset.
    local lineH = h2 - h1
    if lineH <= 0 then lineH = h1 end
    if lineH <= 0 then
        local _, fontSize = editor:GetFont()
        lineH = (fontSize or 12) * 1.2
    end
    local maxLine = 1
    for _, p in ipairs(positions) do
        if p.line > maxLine then maxLine = p.line end
    end
    -- The editor's line-to-line advance is the font line height PLUS its line
    -- spacing (SetSpacing); the meter has no spacing, so add it here or every
    -- line after the first drifts up (misaligned bold overlays / underlines).
    local spacing = (editor.GetSpacing and editor:GetSpacing()) or 0
    local advance = lineH + spacing
    local lineYs = {}
    for i = 1, maxLine do lineYs[i] = math.floor((i - 1) * advance + 0.5) end
    return lineYs, lineH
end

-- Renders one host's decorations (underline/strike lines, colour runs, faux-bold
-- copies) over its editor. Pools are per host, so hiding one host's regions never
-- touches the other's.
function Fmt.UpdateDecorationOverlayFor(editor, decos, texPool, runPool)
    if not decos or #decos == 0 then
        for i = 1, #texPool do texPool[i]:Hide() end
        for i = 1, #runPool do runPool[i]:Hide() end
        return
    end
    local used = 0
    local text = editor:GetText() or ""
    local wrapWidth = editor:GetWidth() or 1
    local meter = GetMeasureMeter(editor)
    meter:SetText("M")
    local oneLineH = meter:GetStringHeight() or 0
    if oneLineH <= 0 then
        local _, fontSize = editor:GetFont()
        oneLineH = (fontSize or 12) * 1.20
    end
    local positions = LayoutCharacters(text, editor, wrapWidth)
    local lineYs = MeasureLineYMap(text, editor, positions)
    local strikeY = math.floor(oneLineH * 0.50 + 0.5)
    local underlineY = math.floor(oneLineH * 0.92 + 0.5)
    local usedRuns = 0
    -- Use the editbox's EXACT font -- path, size AND flags. Rendering the overlay
    -- with flags "" while the editbox uses GameFontHighlight's real flags gives the
    -- overlay glyphs slightly different widths, and that error accumulates across
    -- the run, so the faux-bold copies drift right of the base text (the doubling).
    local editorFontPath, editorSize, editorFlags = editor:GetFont()
    editorFontPath = editorFontPath or "Fonts\\FRIZQT__.TTF"
    editorSize = editorSize or 12
    editorFlags = editorFlags or ""
    for _, deco in ipairs(decos) do
        if deco.kind == "bold" then
            -- Bold via faux-bold: draw the run in the SAME font as the base, nudged
            -- a fraction of a pixel sideways a couple of times. The base text (from
            -- the editbox) plus these offset copies thicken the stems into bold.
            local runs = ComputeTextRuns(positions, deco)
            for _, run in ipairs(runs) do
                for _, dx in ipairs(BOLD_FAUX_OFFSETS) do
                    usedRuns = usedRuns + 1
                    local fs = Fmt.AcquireRunOverlay(editor, runPool, usedRuns)
                    if fs then
                        fs:SetFont(editorFontPath, editorSize, editorFlags)
                        fs:SetTextColor(0.74, 0.74, 0.78, 1)
                        fs:SetText(run.text)
                        fs:ClearAllPoints()
                        fs:SetPoint("TOPLEFT", editor, "TOPLEFT", run.x + dx, -(lineYs[run.line] or 0))
                        fs:Show()
                    end
                end
            end
        elseif deco.kind == "strike" or deco.kind == "underline" then
            -- Lines take the text colour of their range (colour decoration
            -- covering the range start), like a word processor.
            local lr, lg, lb = 0.92, 0.92, 0.94
            for c = 1, #decos do
                local cd = decos[c]
                if cd.kind == "color" and cd.startByte <= deco.startByte and cd.endByte > deco.startByte then
                    lr, lg, lb = cd.r or 1, cd.g or 1, cd.b or 1
                    break
                end
            end
            local rects = ComputeDecorationRects(positions, deco)
            for _, r in ipairs(rects) do
                used = used + 1
                local tex = Fmt.AcquireDecoTexture(editor, texPool, used)
                if tex then
                    local lineTop = -(lineYs[r.line] or 0)
                    local yOffset = deco.kind == "strike" and (lineTop - strikeY) or (lineTop - underlineY)
                    tex:ClearAllPoints()
                    tex:SetPoint("TOPLEFT", editor, "TOPLEFT", r.x1, yOffset)
                    tex:SetSize(math.max(1, r.x2 - r.x1), 1)
                    tex:SetColorTexture(lr, lg, lb, 1)
                    tex:Show()
                end
            end
        end
    end
    -- Color is drawn in a second pass so it always sits on TOP of bold's grey
    -- faux copies (editboxes render |c escapes literally, so color has to be an
    -- overlay). When a bold range overlaps the coloured run, draw the colour with
    -- the same faux-bold offsets so colored+bold text is both coloured and bold.
    for _, deco in ipairs(decos) do
        if deco.kind == "color" then
            local dr, dg, db = deco.r or 1, deco.g or 1, deco.b or 1
            local overlapsBold = false
            for _, other in ipairs(decos) do
                if other.kind == "bold" and other.endByte > deco.startByte
                   and other.startByte < deco.endByte then
                    overlapsBold = true
                    break
                end
            end
            local runs = ComputeTextRuns(positions, deco)
            for _, run in ipairs(runs) do
                usedRuns = usedRuns + 1
                local fs = Fmt.AcquireRunOverlay(editor, runPool, usedRuns)
                if fs then
                    fs:SetFont(editorFontPath, editorSize, editorFlags)
                    fs:SetTextColor(dr, dg, db, 1)
                    fs:SetText(run.text)
                    fs:ClearAllPoints()
                    fs:SetPoint("TOPLEFT", editor, "TOPLEFT", run.x, -(lineYs[run.line] or 0))
                    fs:Show()
                    if overlapsBold then
                        for _, dx in ipairs(BOLD_FAUX_OFFSETS) do
                            usedRuns = usedRuns + 1
                            local bfs = Fmt.AcquireRunOverlay(editor, runPool, usedRuns)
                            if bfs then
                                bfs:SetFont(editorFontPath, editorSize, editorFlags)
                                bfs:SetTextColor(dr, dg, db, 1)
                                bfs:SetText(run.text)
                                bfs:ClearAllPoints()
                                bfs:SetPoint("TOPLEFT", editor, "TOPLEFT", run.x + dx, -(lineYs[run.line] or 0))
                                bfs:Show()
                            end
                        end
                    end
                end
            end
        end
    end
    for i = used + 1, #texPool do texPool[i]:Hide() end
    for i = usedRuns + 1, #runPool do runPool[i]:Hide() end
end

function UI:UpdateEasyNotesDecorationOverlay()
    local frame = UI._notes.frame
    if frame and frame.editor then
        UI._notes.decoTextures = UI._notes.decoTextures or {}
        UI._notes.runOverlays = UI._notes.runOverlays or {}
        local note = GetSelectedNote()
        Fmt.UpdateDecorationOverlayFor(frame.editor, note and note.decorations or nil,
            UI._notes.decoTextures, UI._notes.runOverlays)
    end
    local host = UI._notes.snippetHost
    if host and host.editor and host.container and host.container:IsShown() then
        Fmt.UpdateDecorationOverlayFor(host.editor, host.doc and host.doc.decorations or nil,
            host.decoTextures, host.runOverlays)
    end
end

-- Parse note markdown into plain text (markers removed) + per-run styles, byte
-- ranges in the PLAIN text. Nesting handled via toggle state (** *  __ ~~).
function UI:ParseMarkdown(body)
    body = body or ""
    local out, runs = {}, {}
    local plainLen = 0
    local bold, ital, und, str = false, false, false, false
    local cur
    local i, n = 1, #body
    while i <= n do
        local two = body:sub(i, i + 1)
        if two == "**" then bold = not bold; cur = nil; i = i + 2
        elseif two == "__" then und = not und; cur = nil; i = i + 2
        elseif two == "~~" then str = not str; cur = nil; i = i + 2
        elseif body:sub(i, i) == "*" then ital = not ital; cur = nil; i = i + 1
        else
            local sz = GlyphSize(body:byte(i))
            out[#out + 1] = body:sub(i, i + sz - 1)
            local s = plainLen + 1
            plainLen = plainLen + sz
            if cur and cur.bold == bold and cur.italic == ital
               and cur.underline == und and cur.strike == str then
                cur.e = plainLen
            else
                cur = { s = s, e = plainLen, bold = bold, italic = ital,
                        underline = und, strike = str }
                runs[#runs + 1] = cur
            end
            i = i + sz
        end
    end
    return table.concat(out), runs
end

-- Rendered read view. The editbox keeps the raw markdown but its text is hidden;
-- the note is drawn as Friz FontStrings (faux-bold for bold runs = the strokes
-- fattened) plus underline/strike lines, from the PLAIN text. With the editbox
-- text hidden there is no base layer to double against -- clean Friz bold.
function UI:RenderEasyNotesBlurDisplay()
    local frame = UI._notes.frame
    local editor = frame and frame.editor
    if not editor then return end
    local note = GetSelectedNote()
    local plain, runs = UI:ParseMarkdown(note and note.body or "")
    local wrapWidth = editor:GetWidth() or 1
    local positions = LayoutCharacters(plain, editor, wrapWidth)
    local lineYs = MeasureLineYMap(plain, editor, positions)
    local meter = GetMeasureMeter(editor)
    meter:SetText("M")
    local oneLineH = meter:GetStringHeight() or 12
    if oneLineH <= 0 then oneLineH = 12 end
    local strikeY = math.floor(oneLineH * 0.50 + 0.5)
    local underlineY = math.floor(oneLineH * 0.92 + 0.5)
    local fontPath, fontSize, fontFlags = editor:GetFont()
    fontPath = fontPath or "Fonts\\FRIZQT__.TTF"; fontSize = fontSize or 12; fontFlags = fontFlags or ""
    local usedRuns, usedTex = 0, 0
    for _, run in ipairs(runs) do
        local deco = { startByte = run.s, endByte = run.e + 1 }
        for _, tr in ipairs(ComputeTextRuns(positions, deco)) do
            usedRuns = usedRuns + 1
            local fs = UI:GetEasyNotesRunOverlay(usedRuns)
            if fs then
                fs:SetFont(fontPath, fontSize, fontFlags)
                fs:SetTextColor(0.87, 0.87, 0.90, 1)
                fs:SetText(tr.text)
                fs:ClearAllPoints()
                fs:SetPoint("TOPLEFT", editor, "TOPLEFT", tr.x, -(lineYs[tr.line] or 0))
                fs:Show()
            end
            if run.bold then
                for _, dx in ipairs(BOLD_FAUX_OFFSETS) do
                    usedRuns = usedRuns + 1
                    local bfs = UI:GetEasyNotesRunOverlay(usedRuns)
                    if bfs then
                        bfs:SetFont(fontPath, fontSize, fontFlags)
                        bfs:SetTextColor(0.87, 0.87, 0.90, 1)
                        bfs:SetText(tr.text)
                        bfs:ClearAllPoints()
                        bfs:SetPoint("TOPLEFT", editor, "TOPLEFT", tr.x + dx, -(lineYs[tr.line] or 0))
                        bfs:Show()
                    end
                end
            end
        end
        if run.underline or run.strike then
            for _, r in ipairs(ComputeDecorationRects(positions, deco)) do
                usedTex = usedTex + 1
                local tex = UI:GetEasyNotesDecorationTexture(usedTex)
                if tex then
                    local lineTop = -(lineYs[r.line] or 0)
                    local yOff = run.strike and (lineTop - strikeY) or (lineTop - underlineY)
                    tex:ClearAllPoints()
                    tex:SetPoint("TOPLEFT", editor, "TOPLEFT", r.x1, yOff)
                    tex:SetSize(math.max(1, r.x2 - r.x1), 1)
                    tex:Show()
                end
            end
        end
    end
    local runPool = UI._notes.runOverlays
    if runPool then for i = usedRuns + 1, #runPool do runPool[i]:Hide() end end
    local texPool = UI._notes.decoTextures
    if texPool then for i = usedTex + 1, #texPool do texPool[i]:Hide() end end
end

-- Toggle between the editable raw-markdown view (editbox text visible) and the
-- rendered read view (editbox text hidden, styled FontStrings drawn).
function UI:SetEasyNotesRendered(rendered)
    -- Char-replace mode: the editbox always shows the real text (bold = SMP glyphs
    -- drawn as bold Friz by the custom font), so there is no separate rendered view
    -- to swap to. Just keep the text visible and refresh the line/colour overlays.
    local frame = UI._notes.frame
    local editor = frame and frame.editor
    if not editor then return end
    editor:SetTextColor(0.74, 0.74, 0.78, 1)
    local runPool = UI._notes.runOverlays
    if runPool then for i = 1, #runPool do runPool[i]:Hide() end end
    UI:UpdateEasyNotesDecorationOverlay()
end

local function ShiftDecorations(decorations, pos, delta)
    if not decorations or delta == 0 then return end
    if delta < 0 then
        -- Deletion of the byte range [pos, pos - delta). An endpoint AFTER the
        -- removed range shifts left; an endpoint INSIDE it clamps to pos; one
        -- before it is untouched. Without the clamp, endpoints inside the deleted
        -- span went negative and corrupted every range from then on.
        local removeEnd = pos - delta
        for _, d in ipairs(decorations) do
            if d.startByte >= removeEnd then d.startByte = d.startByte + delta
            elseif d.startByte > pos then d.startByte = pos end
            if d.endByte >= removeEnd then d.endByte = d.endByte + delta
            elseif d.endByte > pos then d.endByte = pos end
        end
    else
        for _, d in ipairs(decorations) do
            if d.startByte >= pos then d.startByte = d.startByte + delta end
            if d.endByte > pos then d.endByte = d.endByte + delta end
        end
    end
end

local function PruneDecorations(decorations)
    if not decorations then return end
    for i = #decorations, 1, -1 do
        local d = decorations[i]
        if d.startByte < 1 then d.startByte = 1 end   -- safety clamp
        if d.endByte <= d.startByte then tremove(decorations, i) end
    end
end

local function MergeAdjacentDecorations(decorations)
    if not decorations or #decorations < 2 then return end
    tsort(decorations, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        return a.startByte < b.startByte
    end)
    local i = 1
    while i < #decorations do
        local cur = decorations[i]
        local nxt = decorations[i + 1]
        -- Color ranges only merge when they carry the same rgb; two abutting
        -- ranges of different colours are distinct and must stay separate.
        local sameColor = cur.kind ~= "color"
            or (cur.r == nxt.r and cur.g == nxt.g and cur.b == nxt.b)
        if cur.kind == nxt.kind and sameColor and nxt.startByte <= cur.endByte then
            cur.endByte = math.max(cur.endByte, nxt.endByte)
            tremove(decorations, i + 1)
        else
            i = i + 1
        end
    end
end

local function SplitLogicalLines(text)
    local lines, starts = {}, {}
    local s = 1
    for i = 1, #text do
        if text:byte(i) == 10 then
            lines[#lines + 1] = text:sub(s, i - 1)
            starts[#starts + 1] = s
            s = i + 1
        end
    end
    lines[#lines + 1] = text:sub(s)
    starts[#starts + 1] = s
    return lines, starts
end

-- Move logical line `fromIdx` to sit immediately before original line
-- `beforeIdx` (beforeIdx may be #lines+1 to append). Returns the rebuilt text
-- and the moved line's new index; decoration byte ranges are remapped.
local function MoveLogicalLine(text, decorations, fromIdx, beforeIdx)
    local lines, oldStarts = SplitLogicalLines(text)
    local n = #lines
    if fromIdx < 1 or fromIdx > n then return text, fromIdx end
    if beforeIdx == fromIdx or beforeIdx == fromIdx + 1 then return text, fromIdx end

    local order = {}
    for k = 1, n do
        if k ~= fromIdx then order[#order + 1] = k end
    end
    local insertPos = #order + 1
    for p = 1, #order do
        if order[p] >= beforeIdx then insertPos = p; break end
    end
    tinsert(order, insertPos, fromIdx)

    local newLines, newStartByOrig = {}, {}
    local cursor = 1
    for p = 1, n do
        local orig = order[p]
        newLines[p] = lines[orig]
        newStartByOrig[orig] = cursor
        cursor = cursor + #lines[orig] + 1
    end
    local newText = table.concat(newLines, "\n")

    if decorations and #decorations > 0 then
        local function RemapByte(b)
            for k = 1, n do
                local ls = oldStarts[k]
                if b >= ls and b <= ls + #lines[k] then
                    return newStartByOrig[k] + (b - ls)
                end
            end
            return b
        end
        for _, d in ipairs(decorations) do
            d.startByte = RemapByte(d.startByte)
            d.endByte = RemapByte(d.endByte)
        end
        PruneDecorations(decorations)
        MergeAdjacentDecorations(decorations)
    end
    return newText, insertPos
end

-- After a font-size / UI-scale change the editbox re-lays-out its glyphs over the
-- next frame or two, and the measure meter's first read at the new size can lag a
-- frame -- so the single overlay render right after the change measures the
-- pre-change positions and stays there (bold/underline drift off the text, and it
-- doesn't come back when the size returns). Re-render once things have settled.
function UI:ReSettleEasyNotesOverlay()
    if not Utils.SafeAfter then return end
    Utils.SafeAfter(0.05, function()
        if UI._notes.frame and UI._notes.frame:IsShown() then
            UI:UpdateEasyNotesDecorationOverlay()
        end
    end)
    Utils.SafeAfter(0.15, function()
        if UI._notes.frame and UI._notes.frame:IsShown() then
            UI:UpdateEasyNotesDecorationOverlay()
        end
    end)
end

function UI:QueueEasyNotesOverlayUpdate()
    if UI._notes.overlayQueued then return end
    UI._notes.overlayQueued = true
    if Utils.SafeAfter then
        Utils.SafeAfter(0, function()
            UI._notes.overlayQueued = nil
            UI:UpdateEasyNotesDecorationOverlay()
            UI:UpdateEasyNotesLinkButtons()
            UI:UpdateEasyNotesEditorScrollBar()
        end)
    else
        UI._notes.overlayQueued = nil
        UI:UpdateEasyNotesDecorationOverlay()
        UI:UpdateEasyNotesLinkButtons()
        UI:UpdateEasyNotesEditorScrollBar()
    end
end

local DRAG_HANDLE_W = 12
local DRAG_HANDLE_H = 16
local DRAG_HANDLE_MARGIN = 8
local DRAG_THROTTLE = 0.03

local function BuildDragLineMap(editor)
    local text = editor:GetText() or ""
    local wrapWidth = editor:GetWidth() or 1
    local positions = LayoutCharacters(text, editor, wrapWidth)
    local lineYs, lineH = MeasureLineYMap(text, editor, positions)
    local _, starts = SplitLogicalLines(text)
    local visualLineOf = {}
    for idx = 1, #positions do
        local p = positions[idx]
        if p.byteStart and p.line then
            if not visualLineOf[p.byteStart] then visualLineOf[p.byteStart] = p.line end
        end
    end
    local rows = {}
    for li = 1, #starts do
        local startByte = starts[li]
        if MatchLinePrefix(text, startByte) > 0 then
            local vline = visualLineOf[startByte] or 1
            rows[#rows + 1] = {
                logicalIndex = li,
                y = lineYs[vline] or ((vline - 1) * lineH),
            }
        end
    end
    return rows, lineH
end

function UI:GetEasyNotesDragHandle(index)
    UI._notes.dragHandles = UI._notes.dragHandles or {}
    local pool = UI._notes.dragHandles
    local handle = pool[index]
    if handle then return handle end
    local frame = UI._notes.frame
    if not frame then return nil end
    handle = CreateFrame("Button", nil, frame)
    handle:SetSize(DRAG_HANDLE_W, DRAG_HANDLE_H)
    handle:RegisterForClicks("LeftButtonUp")
    handle:EnableMouse(true)
    handle.dots = {}
    for d = 1, 6 do
        local dot = handle:CreateTexture(nil, "OVERLAY")
        dot:SetColorTexture(0.55, 0.55, 0.60, 0.9)
        dot:SetSize(2, 2)
        local col = (d - 1) % 2
        local row = math.floor((d - 1) / 2)
        dot:SetPoint("TOPLEFT", handle, "TOPLEFT", 3 + col * 4, -(3 + row * 4))
        handle.dots[d] = dot
    end
    handle:SetScript("OnEnter", function(self)
        for _, dot in ipairs(self.dots) do dot:SetColorTexture(0.85, 0.85, 0.90, 1) end
    end)
    handle:SetScript("OnLeave", function(self)
        if UI._notes.dragActive and UI._notes.dragActive.handle == self then return end
        for _, dot in ipairs(self.dots) do dot:SetColorTexture(0.55, 0.55, 0.60, 0.9) end
    end)
    handle:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then UI:BeginEasyNotesLineDrag(self) end
    end)
    pool[index] = handle
    return handle
end

function UI:RefreshEasyNotesDragHandles()
    local frame = UI._notes.frame
    local pool = UI._notes.dragHandles
    if not frame or not frame.editor or not frame.editorScroll then
        if pool then for i = 1, #pool do pool[i]:Hide() end end
        return
    end
    if UI._notes.paletteShown or not frame.editorScroll:IsShown() then
        if pool then for i = 1, #pool do pool[i]:Hide() end end
        return
    end
    local editor = frame.editor
    local scroll = frame.editorScroll
    local rows, lineH = BuildDragLineMap(editor)
    local scrollY = scroll:GetVerticalScroll() or 0
    local viewH = scroll:GetHeight() or 0
    -- Center the handle vertically on the line instead of pinning its top to the
    -- line top (that was the visible offset).
    local centerAdjust = ((lineH or DRAG_HANDLE_H) - DRAG_HANDLE_H) / 2
    local used = 0
    for _, row in ipairs(rows) do
        local localY = row.y - scrollY
        if localY >= -DRAG_HANDLE_H and localY <= viewH then
            used = used + 1
            local handle = UI:GetEasyNotesDragHandle(used)
            if handle then
                handle.logicalIndex = row.logicalIndex
                handle:ClearAllPoints()
                handle:SetPoint("TOPRIGHT", scroll, "TOPLEFT", -DRAG_HANDLE_MARGIN, -(localY + centerAdjust))
                handle:Show()
            end
        end
    end
    if pool then
        for i = used + 1, #pool do pool[i]:Hide() end
    end
end

function UI:QueueEasyNotesDragHandleRefresh()
    if UI._notes.dragHandleQueued then return end
    UI._notes.dragHandleQueued = true
    if Utils.SafeAfter then
        Utils.SafeAfter(0, function()
            UI._notes.dragHandleQueued = nil
            UI:RefreshEasyNotesDragHandles()
        end)
    else
        UI._notes.dragHandleQueued = nil
        UI:RefreshEasyNotesDragHandles()
    end
end

local function EasyNotesDragUpdate(driver)
    if not IsMouseButtonDown("LeftButton") then
        UI:EndEasyNotesLineDrag()
        return
    end
    local state = UI._notes.dragActive
    if not state then
        driver:SetScript("OnUpdate", nil)
        return
    end
    local frame = UI._notes.frame
    local editor = frame and frame.editor
    local scroll = frame and frame.editorScroll
    if not (editor and scroll) then
        UI:EndEasyNotesLineDrag()
        return
    end
    local sc = scroll:GetEffectiveScale()
    local _, cursorY = GetCursorPosition()
    local scrollTop = scroll:GetTop()
    if not scrollTop then return end
    local localY = (scrollTop - cursorY / sc) + (scroll:GetVerticalScroll() or 0)
    local rows = BuildDragLineMap(editor)
    if #rows == 0 then return end
    local lines = SplitLogicalLines(editor:GetText() or "")
    local totalLines = #lines
    local targetBefore = totalLines + 1
    for _, row in ipairs(rows) do
        if localY < row.y + state.lineH * 0.5 then
            targetBefore = row.logicalIndex
            break
        end
    end
    local fromIdx = state.logicalIndex
    if targetBefore == fromIdx or targetBefore == fromIdx + 1 then return end
    local note = GetSelectedNote()
    if not note then return end
    local text = editor:GetText() or ""
    local cursor = editor:GetCursorPosition()
    local newText, newIdx = MoveLogicalLine(text, note.decorations, fromIdx, targetBefore)
    if newText == text then return end
    state.logicalIndex = newIdx
    UI._notes.loadingNote = true
    editor:SetText(newText)
    if cursor then editor:SetCursorPosition(math.min(cursor, #newText)) end
    UI._notes.loadingNote = nil
    UI._notes.lastEditorText = newText
    local id = UI._notes.selectedID
    if id then UpdateBody(id, newText) end
    UI:UpdateEasyNotesDecorationOverlay()
    UI:RefreshEasyNotesDragHandles()
end

function UI:BeginEasyNotesLineDrag(handle)
    local frame = UI._notes.frame
    if not (frame and frame.editor and handle and handle.logicalIndex) then return end
    if UI._notes.paletteShown then return end
    local _, lineH = BuildDragLineMap(frame.editor)
    local driver = UI._notes.dragDriver
    if not driver then
        driver = CreateFrame("Frame", nil, frame)
        driver:Hide()
        UI._notes.dragDriver = driver
    end
    UI._notes.dragActive = {
        handle = handle,
        logicalIndex = handle.logicalIndex,
        lineH = lineH or 14,
    }
    handle:LockHighlight()
    driver:Show()
    if Utils.SafeOnUpdate then
        Utils.SafeOnUpdate(driver, function(self, elapsed)
            self._dragAccum = (self._dragAccum or 0) + (elapsed or 0)
            if self._dragAccum < DRAG_THROTTLE then return end
            self._dragAccum = 0
            EasyNotesDragUpdate(self)
        end)
    else
        driver:SetScript("OnUpdate", function(self, elapsed)
            self._dragAccum = (self._dragAccum or 0) + (elapsed or 0)
            if self._dragAccum < DRAG_THROTTLE then return end
            self._dragAccum = 0
            EasyNotesDragUpdate(self)
        end)
    end
end

function UI:EndEasyNotesLineDrag()
    local state = UI._notes.dragActive
    UI._notes.dragActive = nil
    local driver = UI._notes.dragDriver
    if driver then
        driver:SetScript("OnUpdate", nil)
        driver._dragAccum = 0
        driver:Hide()
    end
    if state and state.handle then
        state.handle:UnlockHighlight()
        for _, dot in ipairs(state.handle.dots or {}) do
            dot:SetColorTexture(0.55, 0.55, 0.60, 0.9)
        end
    end
    UI:RefreshEasyNotesDragHandles()
end

function UI:ExtendActiveDecoration(kind, oldCursor, newCursor)
    local note = GetSelectedNote()
    if not note then return end
    note.decorations = note.decorations or {}
    for _, d in ipairs(note.decorations) do
        if d.kind == kind and d.endByte == oldCursor then
            d.endByte = newCursor
            return
        end
    end
    note.decorations[#note.decorations + 1] = {
        kind = kind,
        startByte = oldCursor,
        endByte = newCursor,
    }
end

function UI:ToggleEasyNotesCheckbox(text, lineStart)
    local note = Fmt.ActiveFormatDoc()
    if not note then return text end
    local prefixLen = MatchLinePrefix(text, lineStart)
    if prefixLen == 0 then return text end
    local prefix = text:sub(lineStart, lineStart + prefixLen - 1)
    note.decorations = note.decorations or {}
    if prefix == CHECK_EMPTY_PREFIX then
        text = text:sub(1, lineStart - 1) .. CHECK_FILLED_PREFIX .. text:sub(lineStart + prefixLen)
        local contentStart = lineStart + #CHECK_FILLED_PREFIX
        local lineEnd = FindLineEndByte(text, contentStart)
        if lineEnd >= contentStart then
            note.decorations[#note.decorations + 1] = {
                kind = "strike", startByte = contentStart, endByte = lineEnd + 1,
            }
            MergeAdjacentDecorations(note.decorations)
        end
    elseif prefix == CHECK_FILLED_PREFIX then
        text = text:sub(1, lineStart - 1) .. CHECK_EMPTY_PREFIX .. text:sub(lineStart + prefixLen)
        local contentStart = lineStart + #CHECK_EMPTY_PREFIX
        local lineEnd = FindLineEndByte(text, contentStart)
        RemoveDecorationRange(note.decorations, "strike", contentStart, lineEnd + 1)
    end
    return text
end

function UI:OpenEasyNotes()
    local frame = self:EnsureEasyNotesFrame()
    if not frame then return end
    NormalizeDB()
    frame:Show()
    self:RefreshEasyNotes()
    self:ShowEasyNotesPalette()
end

function UI:CloseEasyNotes()
    local frame = UI._notes.frame
    if frame then frame:Hide() end
    self:HideEasyNotesPalette()
end

function UI:ToggleEasyNotes()
    local frame = UI._notes.frame
    if frame and frame:IsShown() then
        self:CloseEasyNotes()
    else
        self:OpenEasyNotes()
    end
end

function UI:FocusEasyNoteEditor()
    local frame = UI._notes.frame
    if not (frame and frame.editor) then return end
    frame.editor:SetFocus()
end

-- Tooltip shown only after a hover delay, matching the rest of EasyFind instead
-- of firing the instant it enters. region.tip is the text; call from OnEnter and
-- pair with a hide on OnLeave.
function UI:ShowNotesTipDelayed(region, anchor, text)
    text = text or (region and region.tip)
    if not (region and text and GameTooltip) then return end
    region._tipToken = (region._tipToken or 0) + 1
    local token = region._tipToken
    local delay = (ns and ns.TOOLTIP_HOVER_DELAY) or 0.4
    Utils.SafeAfter(delay, function()
        if region._tipToken ~= token then return end
        if not (region:IsShown() and region:IsMouseOver()) then return end
        if ns.ShowThemedTooltip then
            ns.ShowThemedTooltip(region, text, anchor or "ANCHOR_TOP")
        elseif GameTooltip then
            GameTooltip:SetOwner(region, anchor or "ANCHOR_TOP")
            GameTooltip:SetText(text)
            GameTooltip:Show()
        end
    end)
end

function UI:HideNotesTip(region)
    if region then region._tipToken = (region._tipToken or 0) + 1 end
    if ns.HideThemedTooltip then ns.HideThemedTooltip() end
    if GameTooltip then GameTooltip:Hide() end
end

-- Selection capture. The 12.0 editbox can't report its own highlight, so the
-- selection is derived from an anchor + the moving caret. A left-drag anchors at
-- the click LANDING (the first cursor move after mousedown, i.e. the caret moving
-- onto the click point), NOT the stale pre-click caret -- reading the pre-click
-- caret is what made drags select all the way to the end of the text. These are
-- methods (not inline handlers) so the test harness can drive the exact event
-- order and assert the captured range.
function UI:NotesBeginDrag(shiftDown)
    local ed = Fmt.ActiveFormatEditor()
    if not ed then return end
    ed._notesDragging = true
    if shiftDown then
        ed._notesDragAnchor = UI._notes.selAnchor   -- shift+click extends
        ed._notesAnchorProvisional = nil
    else
        -- Seed the anchor with the current caret: when the click lands exactly
        -- where the caret already is, NO cursor change fires for the landing,
        -- and waiting for one made the first drag step the anchor (a two-char
        -- selection tracked as only its latter char). The seed is provisional:
        -- a cursor change in the SAME frame is the true click landing and
        -- replaces it; later changes are drag extensions and keep it.
        ed._notesDragAnchor = ed:GetCursorPosition()
        ed._notesAnchorProvisional = GetTime and GetTime() or 0
        UI._notes.curSelection = nil
    end
end

function UI:NotesRecomputeSelection(caret)
    local ed = Fmt.ActiveFormatEditor()
    if ed and ed._notesDragging then
        if ed._notesAnchorProvisional then
            local sameFrame = (GetTime and GetTime() or 0) == ed._notesAnchorProvisional
            ed._notesAnchorProvisional = nil
            if sameFrame then
                ed._notesDragAnchor = caret         -- the click landing
                UI._notes.selAnchor = caret
                UI._notes.curSelection = nil
                return
            end
        end
        local a = ed._notesDragAnchor
        if a == nil then
            ed._notesDragAnchor = caret             -- the click landing
            UI._notes.selAnchor = caret
            UI._notes.curSelection = nil
            return
        end
        UI._notes.selAnchor = a
        if caret ~= a then
            UI._notes.curSelection = { lo = math.min(a, caret) + 1, hi = math.max(a, caret) }
        else
            UI._notes.curSelection = nil
        end
        return
    end
    local anchor = UI._notes.selAnchor
    if anchor and anchor ~= caret then
        UI._notes.curSelection = { lo = math.min(anchor, caret) + 1, hi = math.max(anchor, caret) }
    else
        UI._notes.curSelection = nil
    end
end

function UI:NotesEndDrag(caret)
    local ed = Fmt.ActiveFormatEditor()
    if not ed then return end
    local a = ed._notesDragAnchor
    if a == nil then
        UI._notes.selAnchor = caret
        UI._notes.curSelection = nil
        UI._notes.lastSelection = nil
    else
        UI._notes.selAnchor = a
        if caret ~= a then
            local lo = math.min(a, caret) + 1
            local hi = math.max(a, caret)
            UI._notes.curSelection = { lo = lo, hi = hi }
            UI._notes.lastSelection = { lo = lo, hi = hi, ts = GetTime and GetTime() or 0 }
        else
            UI._notes.curSelection = nil
            UI._notes.lastSelection = nil
        end
    end
    ed._notesDragging = false
    ed._notesDragAnchor = nil
    ed._notesAnchorProvisional = nil
    UI:UpdateEasyNotesCaretVisibility()
end

-- Keyboard selection: shift+nav anchors at the pre-move caret; a plain nav key
-- collapses the selection.
function UI:NotesShiftNav(shiftDown, caretBefore)
    if shiftDown then
        if not UI._notes.selAnchor then UI._notes.selAnchor = caretBefore end
    else
        UI._notes.selAnchor = nil
        UI._notes.curSelection = nil
    end
end

-- Double-click: WoW selects the word natively, but that selection is invisible
-- to the manual tracker (no selection getter in 12.0), so formatting acted on a
-- stale range. Recompute the word from the caret and force the native highlight
-- onto the same bytes, so what's shown is exactly what formats. Whitespace is
-- the only delimiter; it's single-byte ASCII, so the byte scan is UTF-8-safe.
function UI:NotesSelectWordAtCaret(editor)
    local text = editor:GetText() or ""
    local caret = editor:GetCursorPosition() or 0
    local n = #text
    if n == 0 then return end
    local function wordByte(b) return b and b ~= 32 and b ~= 10 and b ~= 9 end
    local pivot
    if caret > 0 and wordByte(text:byte(caret)) then
        pivot = caret
    elseif caret < n and wordByte(text:byte(caret + 1)) then
        pivot = caret + 1
    else
        return
    end
    local lo, hi = pivot, pivot
    while lo > 1 and wordByte(text:byte(lo - 1)) do lo = lo - 1 end
    while hi < n and wordByte(text:byte(hi + 1)) do hi = hi + 1 end
    editor._notesWordSelected = true
    editor:SetCursorPosition(hi)
    editor:HighlightText(lo - 1, hi)
    UI._notes.selAnchor = lo - 1
    UI._notes.curSelection = { lo = lo, hi = hi }
    UI._notes.lastSelection = { lo = lo, hi = hi, ts = GetTime and GetTime() or 0 }
    UI:RefreshFormatButtonStates()
    UI:UpdateEasyNotesCaretVisibility()
end

function UI:EnsureEasyNotesFrame()
    self:DetectEasyNotesGlyphEncoding()
    local frame = UI._notes.frame
    if frame then return frame end

    local db = NormalizeDB()
    frame = CreateFrame("Frame", "EasyNotesFrame", UIParent)
    -- Built hidden: a new frame starts shown, so its first open ran no OnShow.
    frame:Hide()
    UI._notes.frame = frame
    frame:SetSize(mmax(MIN_WIDTH, db.window.w or DEFAULT_WIDTH),
                  mmax(MIN_HEIGHT, db.window.h or DEFAULT_HEIGHT))
    frame:SetScale(db.uiScale or UI_SCALE_DEFAULT)
    frame:SetPoint("CENTER")
    -- Same strata as the active search bar (DIALOG): above normal windows,
    -- below menus/flyouts (TOOLTIP) so dropdowns never render under the notes.
    frame:SetFrameStrata("DIALOG")
    frame:SetFrameLevel(880)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:EnableMouseWheel(true)
    -- Consume wheel events over the window so Ctrl+scroll never leaks
    -- through to frames behind it (e.g. the chat font-scale handler).
    frame:SetScript("OnMouseWheel", function(_, delta)
        if IsControlKeyDown and IsControlKeyDown() then
            UI:AdjustEasyNotesUIScale(delta > 0 and UI_SCALE_STEP or -UI_SCALE_STEP)
        end
    end)
    frame:SetMovable(true)
    frame:SetResizable(true)
    if frame.SetMinResize then frame:SetMinResize(MIN_WIDTH, MIN_HEIGHT) end
    if frame.SetResizeBounds then frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT) end
    frame:RegisterForDrag("LeftButton")

    local function PinTopLeftAnchor()
        local left, top = frame:GetLeft(), frame:GetTop()
        if not (left and top) then return end
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    end
    local moveState = {}
    local function MoveUpdate()
        if not IsMouseButtonDown("LeftButton") then
            frame:SetScript("OnUpdate", nil)
            return
        end
        local sc = frame:GetEffectiveScale()
        local mx, my = GetCursorPosition()
        local L = moveState.startL + (mx / sc - moveState.startCX)
        local T = moveState.startT + (my / sc - moveState.startCY)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", L, T)
    end
    local function BeginMove()
        PinTopLeftAnchor()
        local left, top = frame:GetLeft(), frame:GetTop()
        if not (left and top) then return end
        local sc = frame:GetEffectiveScale()
        local mx, my = GetCursorPosition()
        moveState.startCX, moveState.startCY = mx / sc, my / sc
        moveState.startL, moveState.startT = left, top
        frame:SetScript("OnUpdate", MoveUpdate)
    end
    local function EndMove()
        frame:SetScript("OnUpdate", nil)
    end
    UI._notes.PinTopLeftAnchor = PinTopLeftAnchor

    frame:SetScript("OnDragStart", BeginMove)
    frame:SetScript("OnDragStop", EndMove)
    if ns.CreateRoundedRectBorder then
        ns.CreateRoundedRectBorder(frame)
        ns.SetRoundedRectBarHeight(frame, 14)
        ns.SetRoundedRectBorderBgAlpha(frame, db.opacity or OPACITY_DEFAULT)
        ns.SetRoundedRectBorderEdgeShown(frame, false)
        if ns.Results.ApplySearchWindowFill then
            ns.Results:ApplySearchWindowFill(frame)
            -- The body follows a theme change in place, the header too.
            if ns.RegisterThemeCallback then
                ns.RegisterThemeCallback(function()
                    ns.Results:ApplySearchWindowFill(frame)
                    ns.SetRoundedRectBorderBgAlpha(frame, db.opacity or OPACITY_DEFAULT)
                end)
            end
        else
            local c = ns.SEARCH_WINDOW_FILL_COLOR or { 0.052, 0.052, 0.060 }
            ns.SetRoundedRectBorderFillColor(frame, c[1], c[2], c[3], 1)
        end
        ns.SetRoundedRectBorderColor(frame, 0.30, 0.30, 0.33, 0.6, true)
    end

    frame.header = CreateFrame("Frame", nil, frame)
    frame.header:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    frame.header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    frame.header:SetHeight(HEADER_H)
    frame.header:EnableMouse(true)
    frame.header:SetScript("OnMouseDown", BeginMove)
    frame.header:SetScript("OnMouseUp", EndMove)

    local BTN_W, BTN_H = STD_BTN_W, STD_BTN_H

    frame.newButton = CreateFrame("Button", nil, frame.header)
    StyleAccentButton(frame.newButton, "+", BTN_W, BTN_H)
    frame.newButton:SetPoint("LEFT", frame.header, "LEFT", 8, 0)
    frame.newButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    frame.newButton:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            Utils.ShowCursorMenu("EasyNotesNewMenu", {
                { text = L["NOTES_NEW"], onClick = function()
                    CreateNote("")
                    UI:HideEasyNotesPalette()
                    UI:RefreshEasyNotes()
                    UI:FocusEasyNoteEditor()
                end },
                { text = L["CHECK_NEW"], onClick = notesNS.NewChecklist },
            }, { toggleOwner = self })
            return
        end
        CreateNote("")
        UI:HideEasyNotesPalette()
        UI:RefreshEasyNotes()
        UI:FocusEasyNoteEditor()
    end)
    frame.newButton:SetScript("OnEnter", function(self)
        if ns.SetRoundedRectFill then local c = ns.NAV_SELECTED_FILL or {0.20,0.30,0.45}; ns.SetRoundedRectFill(self, c[1]+(1-c[1])*0.18, c[2]+(1-c[2])*0.18, c[3]+(1-c[3])*0.18, 1, true) end
        UI:ShowNotesTipDelayed(self, "ANCHOR_BOTTOM", L["NOTES_NEW_TT"])
    end)
    frame.newButton:SetScript("OnLeave", function(self)
        if ns.SetRoundedRectFill then local c = ns.NAV_SELECTED_FILL or {0.20,0.30,0.45}; ns.SetRoundedRectFill(self, c[1], c[2], c[3], 1, true) end
        UI:HideNotesTip(self)
    end)

    frame.settingsButton = CreateFrame("Button", nil, frame.header)
    frame.settingsButton:SetSize(BTN_W, BTN_H)
    if ns.CreateRoundedRectBorder then
        ns.CreateRoundedRectBorder(frame.settingsButton)
        ns.SetRoundedRectBarHeight(frame.settingsButton, 10)
        ns.SetRoundedRectBorderBgAlpha(frame.settingsButton, 1)
        ns.SetRoundedRectBorderEdgeShown(frame.settingsButton, false)
    end
    TrackThemedButton(frame.settingsButton)
    PaintSubtleButton(frame.settingsButton, false)
    do
        local g = frame.settingsButton
        g.gearIcon = g:CreateTexture(nil, "OVERLAY")
        g.gearIcon:SetTexture("Interface\\Buttons\\UI-OptionsButton")
        g.gearIcon:SetSize(13, 13)
        g.gearIcon:SetPoint("CENTER", g, "CENTER", 0, 0)
        g.gearIcon:SetDesaturated(true)
        g.gearIcon:SetVertexColor(0.84, 0.84, 0.86, 1)
    end
    frame.settingsButton:SetPoint("LEFT", frame.newButton, "RIGHT", 4, 0)
    frame.settingsButton:SetScript("OnEnter", function(self)
        PaintSubtleButton(self, true)
        if self.gearIcon then self.gearIcon:SetVertexColor(1, 1, 1, 1) end
    end)
    frame.settingsButton:SetScript("OnLeave", function(self)
        PaintSubtleButton(self, false)
        if self.gearIcon then self.gearIcon:SetVertexColor(0.84, 0.84, 0.86, 1) end
    end)
    frame.settingsButton:SetScript("OnClick", function() UI:ToggleEasyNotesSettings() end)

    frame.paletteButton = CreateFrame("Button", nil, frame.header)
    frame.paletteButton:SetSize(BTN_W, BTN_H)
    if ns.CreateRoundedRectBorder then
        ns.CreateRoundedRectBorder(frame.paletteButton)
        ns.SetRoundedRectBarHeight(frame.paletteButton, 10)
        ns.SetRoundedRectBorderBgAlpha(frame.paletteButton, 1)
        ns.SetRoundedRectBorderEdgeShown(frame.paletteButton, false)
    end
    TrackThemedButton(frame.paletteButton)
    PaintSubtleButton(frame.paletteButton, false)
    do
        local p = frame.paletteButton
        p.houseIcon = p:CreateTexture(nil, "OVERLAY")
        p.houseIcon:SetAtlas("UI-HUD-MicroMenu-Housing-Up", false)
        p.houseIcon:SetSize(15, 15)
        p.houseIcon:SetPoint("CENTER", p, "CENTER", 0, 0)
        p.houseIcon:SetDesaturated(true)
        p.houseIcon:SetVertexColor(1, 1, 1, 1)
    end
    frame.paletteButton:SetScript("OnEnter", function(self)
        PaintSubtleButton(self, true)
    end)
    frame.paletteButton:SetScript("OnLeave", function(self)
        PaintSubtleButton(self, false)
    end)
    -- Home button: shares the New button's left slot (only one shows per view).
    frame.paletteButton:SetPoint("LEFT", frame.header, "LEFT", 8, 0)
    frame.paletteButton:SetScript("OnClick", function() UI:ToggleEasyNotesPalette() end)

    frame.close = CreateFrame("Button", nil, frame.header)
    StyleSubtleButton(frame.close, "", BTN_W, BTN_H)
    frame.close:SetPoint("RIGHT", frame.header, "RIGHT", -8, 0)
    if frame.close.text then frame.close.text:Hide() end
    do
        local c = frame.close
        local idle = { 0.84, 0.84, 0.86, 1 }
        c.x1 = c:CreateTexture(nil, "OVERLAY")
        c.x1:SetSize(9, 1.4)
        c.x1:SetPoint("CENTER", c, "CENTER", 0, 0)
        c.x1:SetRotation(math.rad(45))
        c.x1:SetColorTexture(unpack(idle))
        c.x2 = c:CreateTexture(nil, "OVERLAY")
        c.x2:SetSize(9, 1.4)
        c.x2:SetPoint("CENTER", c, "CENTER", 0, 0)
        c.x2:SetRotation(math.rad(-45))
        c.x2:SetColorTexture(unpack(idle))
        c:HookScript("OnEnter", function()
            c.x1:SetColorTexture(1, 1, 1, 1)
            c.x2:SetColorTexture(1, 1, 1, 1)
        end)
        c:HookScript("OnLeave", function()
            c.x1:SetColorTexture(unpack(idle))
            c.x2:SetColorTexture(unpack(idle))
        end)
    end
    frame.close:SetScript("OnClick", function() UI:CloseEasyNotes() end)

    frame.deleteButton = CreateFrame("Button", nil, frame.header)
    StyleSubtleButton(frame.deleteButton, "", BTN_W, BTN_H)
    frame.deleteButton:SetPoint("RIGHT", frame.close, "LEFT", -4, 0)
    if frame.deleteButton.text then frame.deleteButton.text:Hide() end
    do
        local t = frame.deleteButton
        t.icon = t:CreateTexture(nil, "OVERLAY")
        t.icon:SetSize(14, 14)
        t.icon:SetPoint("CENTER", t, "CENTER", 0, 0)
        t.icon:SetTexture("Interface\\AddOns\\EasyFind_Notes\\Images\\trash")
        t.icon:SetDesaturated(true)
        t.icon:SetVertexColor(0.95, 0.95, 0.97, 1)
        t:HookScript("OnEnter", function(self)
            if not self:IsEnabled() then return end
            self.icon:SetVertexColor(0.95, 0.45, 0.42, 1)
        end)
        t:HookScript("OnLeave", function(self)
            if not self:IsEnabled() then return end
            self.icon:SetVertexColor(0.95, 0.95, 0.97, 1)
        end)
    end
    frame.deleteButton:SetScript("OnClick", function()
        -- Acts on the list selection when there is one; in the editor view it
        -- deletes the open note.
        local ids = {}
        for k in next, UI._notes.paletteSelection do ids[#ids + 1] = k end
        if #ids > 0 then
            ConfirmDeleteNote(ids)
        elseif not UI._notes.paletteShown and UI._notes.selectedID then
            ConfirmDeleteNote(UI._notes.selectedID)
        end
    end)
    UI:UpdateEasyNotesDeleteButton()

    frame.titleButton = CreateFrame("Button", nil, frame.header)
    frame.titleButton:SetPoint("LEFT", frame.paletteButton, "RIGHT", 8, 0)
    frame.titleButton:SetPoint("RIGHT", frame.deleteButton, "LEFT", -8, 0)
    frame.titleButton:SetHeight(HEADER_H)
    frame.titleButton:RegisterForDrag("LeftButton")
    frame.titleButton:SetScript("OnDragStart", BeginMove)
    frame.titleButton:SetScript("OnDragStop", EndMove)

    frame.title = frame.titleButton:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetAllPoints(frame.titleButton)
    frame.title:SetJustifyH("CENTER")
    frame.title:SetWordWrap(false)
    if frame.title.SetMaxLines then frame.title:SetMaxLines(1) end
    frame.title:SetTextColor(0.96, 0.96, 0.97, 1)
    frame.title:SetText(L["NOTES_UNTITLED"])

    frame.homeTitle = frame.header:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.homeTitle:SetPoint("CENTER", frame.header, "CENTER", 0, 0)
    frame.homeTitle:SetText(L["APP_NOTES"])
    frame.homeTitle:SetTextColor(0.96, 0.96, 0.97, 1)
    frame.homeTitle:Hide()

    frame.titleEdit = CreateFrame("EditBox", nil, frame.header)
    frame.titleEdit:SetAllPoints(frame.titleButton)
    frame.titleEdit:SetAutoFocus(false)
    frame.titleEdit:SetFontObject("GameFontHighlight")
    frame.titleEdit:SetTextColor(1, 1, 1, 1)
    frame.titleEdit:SetJustifyH("CENTER")
    frame.titleEdit:SetMaxLetters(64)
    frame.titleEdit:Hide()
    frame.titleEdit:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    frame.titleEdit:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    frame.titleEdit:SetScript("OnEditFocusLost", function(self)
        local note = GetSelectedNote()
        if note then
            -- Note names carry no formatting: strip SMP styling and color codes.
            local newName = strtrim(StripColorEscapes(MapSelection(self:GetText() or "", GlyphPlain)))
            note.name = newName
            note.updated = time()
        end
        self:Hide()
        frame.titleButton:Show()
        UI:RefreshEasyNotes()
    end)
    frame.titleButton:SetScript("OnClick", function()
        local note = GetSelectedNote()
        if not note then return end
        frame.titleEdit:SetText(NoteTitle(note))
        frame.titleButton:Hide()
        frame.titleEdit:Show()
        frame.titleEdit:SetFocus()
        frame.titleEdit:HighlightText()
    end)

    frame.headerDivider = frame:CreateTexture(nil, "ARTWORK")
    frame.headerDivider:SetColorTexture(0.18, 0.18, 0.20, 0.7)
    frame.headerDivider:SetHeight(1)
    frame.headerDivider:SetPoint("TOPLEFT", frame.header, "BOTTOMLEFT", 12, 0)
    frame.headerDivider:SetPoint("TOPRIGHT", frame.header, "BOTTOMRIGHT", -12, 0)

    frame.editorScroll = CreateFrame("ScrollFrame", nil, frame)
    frame.editorScroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -HEADER_H - EDITOR_TOP)
    frame.editorScroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, FOOTER_H + 4)
    frame.editorScroll:EnableMouseWheel(true)
    -- Without this the OnMouseDown click-to-focus never fires: the editbox child
    -- only catches clicks that land on an actual glyph, so clicking the empty
    -- part of a line (or below short content) fell through and did nothing. The
    -- child still handles direct text clicks; the scroll frame catches the rest.
    frame.editorScroll:EnableMouse(true)

    frame.editor = CreateFrame("EditBox", nil, frame.editorScroll)
    frame.editor:SetMultiLine(true)
    frame.editor:SetAutoFocus(false)
    frame.editor:SetMaxLetters(NOTES_MAX_BODY)
    frame.editor:SetFontObject("GameFontHighlight")
    UI:ApplyEasyNotesEditorFont()
    frame.editor:SetTextColor(0.74, 0.74, 0.78, 1)
    frame.editor:SetJustifyH("LEFT")
    if frame.editor.SetJustifyV then frame.editor:SetJustifyV("TOP") end
    if frame.editor.SetWordWrap then frame.editor:SetWordWrap(true) end
    if frame.editor.SetNonSpaceWrap then frame.editor:SetNonSpaceWrap(true) end
    if frame.editor.SetTextInsets then frame.editor:SetTextInsets(0, 0, 0, 0) end
    frame.editor:SetWidth(frame.editorScroll:GetWidth())
    frame.editor:SetScript("OnEscapePressed", function(self)
        -- Close any open note popup first (list menu, font flyout, settings);
        -- only drop editor focus when nothing was open.
        if UI:CloseEasyNotesOpenMenus() then return end
        self:ClearFocus()
    end)
    frame.editor:SetScript("OnTextChanged", function(self)
        if UI._notes.loadingNote then return end
        -- Hide bold overlays the instant text changes: their positions are now
        -- stale (chars shifted) until the deferred overlay update recomputes them.
        -- This is what prevents the smeared multi-copy flash while typing/editing.
        local runPool = UI._notes.runOverlays
        if runPool then
            for i = 1, #runPool do runPool[i]:Hide() end
        end
        local id = UI._notes.selectedID
        if not id then return end
        local newText = self:GetText() or ""
        local note = GetSelectedNote()
        local modes = UI._notes.activeModes or {}
        -- Format applies remap decoration offsets themselves (glyph byte widths
        -- change in place); the generic diff would collapse interior ranges.
        if note and not UI._notes.applyingFormat then
            note.decorations = note.decorations or {}
            local oldText = UI._notes.lastEditorText or note.body or ""
            local minLen = math.min(#oldText, #newText)
            local diffStart = 1
            while diffStart <= minLen and oldText:byte(diffStart) == newText:byte(diffStart) do
                diffStart = diffStart + 1
            end
            local oldEnd = #oldText
            local newEnd = #newText
            while oldEnd >= diffStart and newEnd >= diffStart
                  and oldText:byte(oldEnd) == newText:byte(newEnd) do
                oldEnd = oldEnd - 1
                newEnd = newEnd - 1
            end
            local removedLen = oldEnd - diffStart + 1
            local addedLen = newEnd - diffStart + 1
            if removedLen > 0 then
                ShiftDecorations(note.decorations, diffStart, -removedLen)
            end
            if addedLen > 0 then
                ShiftDecorations(note.decorations, diffStart, addedLen)
                local insEnd = diffStart + addedLen
                if modes.strike then UI:ExtendActiveDecoration("strike", diffStart, insEnd) end
                if modes.underline then UI:ExtendActiveDecoration("underline", diffStart, insEnd) end
                local tc = UI._notes.typingColor
                if tc then
                    -- Typing colour: paint inserted bytes with the picked colour,
                    -- like the other sticky modes.
                    RemoveDecorationRange(note.decorations, "color", diffStart, insEnd)
                    note.decorations[#note.decorations + 1] = { kind = "color",
                        startByte = diffStart, endByte = insEnd, r = tc.r, g = tc.g, b = tc.b }
                end
                if NormalizeDB().richText2 then
                    if modes.bold then UI:ExtendActiveDecoration("bold", diffStart, insEnd) end
                    if modes.italic then UI:ExtendActiveDecoration("italic", diffStart, insEnd) end
                end
            end
            PruneDecorations(note.decorations)
            MergeAdjacentDecorations(note.decorations)
        end
        UI._notes.lastEditorText = newText
        UpdateBody(id, newText)
        UI:UpdateEasyNotesCharCounter()
        UI:RefreshEasyNotesHeaderOnly()
        -- With a typing colour (or line style) active, the styled copy must
        -- appear in the SAME frame as the typed character; the queued overlay
        -- tick is a frame late, which flashed each new char in the default
        -- text colour first.
        if UI._notes.typingColor or modes.underline or modes.strike then
            UI:UpdateEasyNotesDecorationOverlay()
        end
        UI:QueueEasyNotesOverlayUpdate()
        UI:QueueEasyNotesDragHandleRefresh()
        UI:RefreshEasyNotesHeaderNav()
    end)
    frame.editor:SetScript("OnEditFocusGained", function(self)
        UI:HideEasyNotesPalette()
        -- Editing: show the raw markdown in the editbox, drop the rendered overlay.
        UI:SetEasyNotesRendered(false)
    end)
    frame.editor:SetScript("OnEditFocusLost", function(self)
        -- Blur: hide the editbox text and draw the rendered read view over it.
        UI:SetEasyNotesRendered(true)
    end)
    -- Interacting with the notes editor routes formatting back to it when a
    -- snippet host had it. Registered before the drag hook so the swap lands
    -- before NotesBeginDrag reads the active editor.
    frame.editor:HookScript("OnMouseDown", function() Fmt.SetSnippetFocus(false) end)
    frame.editor:HookScript("OnEditFocusGained", function() Fmt.SetSnippetFocus(false) end)
    -- Undo history capture: appended hooks run even when the main handler
    -- early-returns, so HistoryRecord carries its own loadingNote guard.
    frame.editor:HookScript("OnTextChanged", function()
        Fmt.HistoryRecord(UI._notes.applyingFormat and true or false)
    end)
    frame.editor:SetScript("OnChar", function(self, c)
        if not c or c == "" then return end
        if UI._notes.inputBusy then return end
        -- Typing under any sticky style keeps that intent through the refresh the
        -- keystroke triggers, even for glyph-less chars like space.
        local am = UI._notes.activeModes
        if (am and (am.bold or am.italic or am.underline or am.strike)) or UI._notes.typingColor then
            UI._notes.keepModesOnNextRefresh = true
        end
        local pos = self:GetCursorPosition() or 0
        local txt = self:GetText() or ""
        local ls = FindLineStartByte(txt, pos)
        -- "#+ " typed at line start: drop the marker, turn the line into a
        -- header -- existing line text is bolded and bold mode is switched on
        -- so the rest of the line keeps the header style until Enter.
        if c == " " and (pos - ls) <= 6 and txt:sub(ls, pos):match("^#+ $") then
            local lineEnd = FindLineEndByte(txt, pos)
            local rest = txt:sub(pos + 1, lineEnd)
            local boldRest = (rest ~= "" and ApplyInlineFormat(rest, { bold = true })) or ""
            UI._notes.inputBusy = true
            self:SetText(txt:sub(1, ls - 1) .. boldRest .. txt:sub(lineEnd + 1))
            self:SetCursorPosition(ls - 1)
            UI._notes.inputBusy = nil
            UI._notes.activeModes = UI._notes.activeModes or {}
            UI._notes.activeModes.bold = true
            UI._notes.headerMode = true
            UI._notes.keepModesOnNextRefresh = true
            UI:RefreshAllEasyNotesToolbarButtons()
            return
        end
        -- "[]" or "[ ]" at line start converts to a checkbox
        if c == "]" then
            local linePre = txt:sub(ls, pos)
            if linePre == "[]" or linePre == "[ ]" then
                UI._notes.inputBusy = true
                self:SetText(txt:sub(1, ls - 1) .. CHECK_EMPTY_PREFIX .. txt:sub(pos + 1))
                self:SetCursorPosition(ls - 1 + #CHECK_EMPTY_PREFIX)
                UI._notes.inputBusy = nil
                return
            end
        end
        Fmt.ApplyTypingGlyphFormat(self, c)
    end)
    frame.editor:SetScript("OnKeyDown", function(self, key)
        local kup = tostring(key or ""):upper()
        if kup == "LEFT" or kup == "RIGHT" or kup == "UP" or kup == "DOWN"
            or kup == "HOME" or kup == "END" or kup == "PAGEUP" or kup == "PAGEDOWN" then
            UI:NotesShiftNav(IsShiftKeyDown and IsShiftKeyDown(), self:GetCursorPosition() or 0)
        end
        if IsControlKeyDown and IsControlKeyDown() then
            local k = tostring(key or ""):upper()
            if k == "PLUS" or k == "=" or k == "NUMPADPLUS" then
                UI:AdjustEasyNotesUIScale(UI_SCALE_STEP)
                return
            elseif k == "MINUS" or k == "-" or k == "NUMPADMINUS" then
                UI:AdjustEasyNotesUIScale(-UI_SCALE_STEP)
                return
            elseif k == "0" or k == "NUMPAD0" then
                UI:AdjustEasyNotesUIScale(0, true)
                return
            elseif k == "F" then
                UI:ToggleEasyNotesFindBar()
                return
            elseif k == "S" then
                UI:SaveEasyNoteNow()
                return
            elseif Fmt.HandleEditorFormatKey(self, k) then
                return
            end
        end
        if key ~= "ENTER" then return end
        Fmt.HandleEditorEnterKey(self)
    end)
    frame.editorScroll:SetScrollChild(frame.editor)
    if ns.Utils and ns.Utils.CreateMinimalScrollBar then
        frame.editorScrollBar = ns.Utils.CreateMinimalScrollBar(frame.editorScroll, frame)
        frame.editorScrollBar:ClearAllPoints()
        frame.editorScrollBar:SetPoint("TOPLEFT", frame.editorScroll, "TOPRIGHT", 4, -2)
        frame.editorScrollBar:SetPoint("BOTTOMLEFT", frame.editorScroll, "BOTTOMRIGHT", 4, 2)
        frame.editorScrollBar:Hide()
    end
    frame.editorScroll:SetScript("OnSizeChanged", function(self, w)
        if w and w > 0 then frame.editor:SetWidth(w) end
        UI:QueueEasyNotesOverlayUpdate()
        UI:QueueEasyNotesDragHandleRefresh()
        UI:LayoutEasyNotesToolbar()
    end)
    frame.editorScroll:HookScript("OnVerticalScroll", function()
        UI:QueueEasyNotesOverlayUpdate()
        UI:RefreshEasyNotesDragHandles()
    end)
    frame.editorScroll:SetScript("OnMouseDown", function() UI:FocusEasyNoteEditor() end)
    frame.editorScroll:SetScript("OnMouseWheel", function(self, delta)
        if IsControlKeyDown and IsControlKeyDown() then
            UI:AdjustEasyNotesUIScale(delta > 0 and UI_SCALE_STEP or -UI_SCALE_STEP)
            return
        end
        local cur = self:GetVerticalScroll() or 0
        local maxS = self:GetVerticalScrollRange() or 0
        local nxt = cur - delta * 40
        if nxt < 0 then nxt = 0 elseif nxt > maxS then nxt = maxS end
        self:SetVerticalScroll(nxt)
    end)
    frame.editor:HookScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            UI:NotesBeginDrag(IsShiftKeyDown and IsShiftKeyDown())
        end
    end)
    if frame.editor.HasScript and frame.editor:HasScript("OnDoubleClick") then
        frame.editor:HookScript("OnDoubleClick", function(self)
            UI:NotesSelectWordAtCaret(self)
        end)
    end
    frame.editor:HookScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        -- WoW can deliver the drag's final cursor update AFTER OnMouseUp fires,
        -- so reading the caret synchronously randomly dropped the last selected
        -- character. Keep the drag alive one frame and finalize from the settled
        -- caret. A double-click word-select sets _notesWordSelected; its range
        -- must survive this finalize.
        if Utils.SafeAfter then
            Utils.SafeAfter(0, function()
                if self._notesWordSelected then
                    self._notesWordSelected = nil
                    self._notesDragging = nil
                    self._notesDragAnchor = nil
                    self._notesAnchorProvisional = nil
                else
                    UI:NotesEndDrag(self:GetCursorPosition())
                end
                UI:RefreshFormatButtonStates()
            end)
        else
            UI:NotesEndDrag(self:GetCursorPosition())
            UI:RefreshFormatButtonStates()
        end
        local txt = self:GetText() or ""
        local pos = self:GetCursorPosition() or 0
        local lineStart = FindLineStartByte(txt, pos)
        local relPos = pos - lineStart + 1
        if relPos <= #CHECK_EMPTY_PREFIX then
            local newTxt = UI:ToggleEasyNotesCheckbox(txt, lineStart)
            if newTxt ~= txt then
                UI._notes.inputBusy = true
                self:SetText(newTxt)
                self:SetCursorPosition(pos)
                UI._notes.inputBusy = nil
                UI:QueueEasyNotesOverlayUpdate()
            end
        end
    end)
    frame.editor:HookScript("OnTextChanged", function()
        if UI._notes.applyingFormat then return end
        UI._notes.lastSelection = nil
        UI._notes.curSelection = nil
        UI._notes.selAnchor = nil
        UI:UpdateEasyNotesCaretVisibility()
    end)
    frame.editor:HookScript("OnCursorChanged", function(self)
        local c = self:GetCursorPosition()
        UI._notes.lastCursor = c
        -- The finalize owns the caret/selection while a format applies; a raw<->
        -- rendered swap (loadingNote) must not recompute the selection either.
        if UI._notes.applyingFormat or UI._notes.loadingNote then return end
        UI:NotesRecomputeSelection(c)
        if c ~= UI._notes.lastFmtCursor then
            UI._notes.lastFmtCursor = c
            UI:QueueFormatButtonRefresh()
        end
        UI:UpdateEasyNotesCaretVisibility()
    end)
    frame.editor:HookScript("OnSizeChanged", function()
        UI:UpdateEasyNotesAutoResize()
    end)

    frame.footer = CreateFrame("Frame", nil, frame)
    frame.footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    frame.footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    frame.footer:SetHeight(FOOTER_H)

    frame.charCounter = frame.footer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.charCounter:SetPoint("CENTER", frame.footer, "CENTER", 0, 2)
    frame.charCounter:SetTextColor(0.48, 0.48, 0.52, 1)
    frame.charCounter:SetText(Utils.sformat(L["NOTES_CHARS"], 0))

    frame.formatButton = CreateFrame("Button", nil, frame.footer)
    StyleSubtleButton(frame.formatButton, "T", BTN_W, BTN_H)
    frame.formatButton:SetPoint("LEFT", frame.footer, "LEFT", 8, 2)
    frame.formatButton:SetFrameLevel(frame.footer:GetFrameLevel() + 20)
    frame.formatButton.text:SetTextColor(0.78, 0.78, 0.82, 1)
    frame.formatButton:SetScript("OnClick", function() UI:ToggleEasyNotesToolbar() end)

    frame.autoResizeButton = CreateFrame("Button", nil, frame.footer)
    StyleSubtleButton(frame.autoResizeButton, "", BTN_W, BTN_H)
    frame.autoResizeButton:SetPoint("RIGHT", frame.formatButton, "LEFT", -4, 0)
    if frame.autoResizeButton.text then frame.autoResizeButton.text:Hide() end
    do
        local b = frame.autoResizeButton
        b.upArrow = b:CreateTexture(nil, "OVERLAY")
        b.upArrow:SetSize(8, 8)
        b.upArrow:SetPoint("CENTER", b, "CENTER", 0, 4)
        b.upArrow:SetTexture("Interface\\Buttons\\Arrow-Up-Up")
        b.upArrow:SetDesaturated(true)
        b.upArrow:SetVertexColor(0.96, 0.96, 0.98, 1)
        b.downArrow = b:CreateTexture(nil, "OVERLAY")
        b.downArrow:SetSize(8, 8)
        b.downArrow:SetPoint("CENTER", b, "CENTER", 0, -4)
        b.downArrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
        b.downArrow:SetDesaturated(true)
        b.downArrow:SetVertexColor(0.96, 0.96, 0.98, 1)
        b.tip = L["NOTES_AUTO_RESIZE"]
        b:SetScript("OnClick", function() UI:ToggleEasyNotesAutoResize() end)
        b:SetScript("OnEnter", function(self)
            if ns.SetRoundedRectFill and not NormalizeDB().autoResize then
                ns.SetRoundedRectFill(self, 0.18, 0.18, 0.20, 1, true)
            end
            UI:ShowNotesTipDelayed(self, "ANCHOR_TOP", self.tip)
        end)
        b:SetScript("OnLeave", function()
            UI:RefreshEasyNotesAutoResizeButton()
            if GameTooltip then GameTooltip:Hide() end
        end)
    end

    frame.aliasButton = CreateFrame("Button", nil, frame.footer)
    StyleSubtleButton(frame.aliasButton, "@", BTN_W, BTN_H)
    frame.aliasButton:SetPoint("LEFT", frame.footer, "LEFT", 30, 2)
    frame.aliasButton:SetScript("OnClick", function() UI:PromptEasyNotesAlias() end)

    frame.matchModeButton = CreateFrame("Button", nil, frame.footer)
    StyleSubtleButton(frame.matchModeButton, "#", BTN_W, BTN_H)
    frame.matchModeButton:SetPoint("LEFT", frame.aliasButton, "RIGHT", 4, 0)
    frame.contextButton = frame.matchModeButton
    if frame.matchModeButton.text then
        frame.matchModeButton.text:SetTextColor(0.78, 0.78, 0.82, 1)
    end
    frame.matchModeButton:SetScript("OnClick", function(self) UI:ShowEasyNotesMatchModeMenu(self) end)
    frame.matchModeButton:HookScript("OnEnter", function(self) UI:ShowEasyNotesContextTooltip(self) end)
    frame.matchModeButton:HookScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    frame.findButton = CreateFrame("Button", nil, frame.footer)
    StyleSubtleButton(frame.findButton, "", BTN_W, BTN_H)
    frame.findButton:SetPoint("LEFT", frame.matchModeButton, "RIGHT", 4, 0)
    if frame.findButton.text then frame.findButton.text:Hide() end
    do
        local t = frame.findButton:CreateTexture(nil, "OVERLAY")
        t:SetSize(12, 12)
        t:SetPoint("CENTER")
        t:SetAtlas("common-search-magnifyingglass")
        t:SetVertexColor(0.82, 0.82, 0.86, 1)
    end
    frame.findButton:SetScript("OnClick", function() UI:ToggleEasyNotesFindBar() end)

    frame.overflowButton = CreateFrame("Button", nil, frame.footer)
    StyleSubtleButton(frame.overflowButton, "", BTN_W, BTN_H)
    if frame.overflowButton.text then frame.overflowButton.text:Hide() end
    do
        local b = frame.overflowButton
        b.dots = {}
        for i = 1, 3 do
            local dot = b:CreateTexture(nil, "OVERLAY")
            dot:SetColorTexture(1, 1, 1, 1)
            dot:SetSize(4, 4)
            dot:SetPoint("CENTER", b, "CENTER", 0, 5 - (i - 1) * 5)
            local mask = b:CreateMaskTexture()
            mask:SetTexture(ns.PORTRAIT_ALPHA_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetAllPoints(dot)
            dot:AddMaskTexture(mask)
            dot:SetVertexColor(0.78, 0.78, 0.82, 1)
            b.dots[i] = dot
        end
        b:SetScript("OnClick", function(self) UI:ShowEasyNotesOverflowMenu(self) end)
        b:HookScript("OnEnter", function(self)
            UI:ShowNotesTipDelayed(self, "ANCHOR_TOP", L["NOTES_MORE"])
        end)
        b:HookScript("OnLeave", function()
            if GameTooltip then GameTooltip:Hide() end
        end)
    end

    frame.headerNavButton = CreateFrame("Button", nil, frame.footer)
    StyleSubtleButton(frame.headerNavButton, "\226\137\161", BTN_W, BTN_H)
    frame.headerNavButton:SetPoint("LEFT", frame.footer, "LEFT", 6, 2)
    if frame.headerNavButton.text then
        frame.headerNavButton.text:SetTextColor(0.78, 0.78, 0.82, 1)
    end
    frame.headerNavButton:SetScript("OnClick", function() UI:ToggleEasyNotesHeaderPanel() end)
    frame.headerNavButton:HookScript("OnEnter", function(self)
        UI:ShowNotesTipDelayed(self, "ANCHOR_TOP", L["NOTES_JUMP_HEADER"])
    end)
    frame.headerNavButton:HookScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)
    frame.headerNavButton:Hide()

    -- Top-right: trash (acts on the selection / open note), more-options,
    -- close; find, auto-resize, theme, alias and context fold into the more
    -- menu. Upper-left keeps New and Settings; the title centres between.
    frame.overflowButton:SetParent(frame.header)
    frame.overflowButton:ClearAllPoints()
    frame.overflowButton:SetPoint("RIGHT", frame.deleteButton, "LEFT", -4, 0)
    frame.titleButton:ClearAllPoints()
    frame.titleButton:SetPoint("LEFT", frame.settingsButton, "RIGHT", 8, 0)
    frame.titleButton:SetPoint("RIGHT", frame.overflowButton, "LEFT", -8, 0)
    frame.autoResizeButton:Hide()
    frame.findButton:Hide()
    frame.headerNavButton:Hide()
    frame.matchModeButton:Hide()
    frame.aliasButton:Hide()

    frame.attachBar = CreateFrame("Frame", nil, frame)
    frame.attachBar:SetPoint("TOPLEFT", frame.headerDivider, "BOTTOMLEFT", 0, -6)
    frame.attachBar:SetPoint("TOPRIGHT", frame.headerDivider, "BOTTOMRIGHT", 0, -6)
    frame.attachBar:SetHeight(ATTACH_H)
    frame.attachBar:SetScript("OnSizeChanged", function(self, w)
        if w and w > 0 and math.abs(w - (self._laidW or 0)) >= 1 then
            self._laidW = w
            UI:RefreshEasyNotesAttachBar()
        end
    end)

    frame.appliesInButton = CreateFrame("Button", nil, frame.attachBar)
    StyleSubtleButton(frame.appliesInButton, "+", BTN_W, BTN_H)
    frame.appliesInButton:SetPoint("LEFT", frame.attachBar, "LEFT", 6, 0)
    if frame.appliesInButton.text then
        frame.appliesInButton.text:SetTextColor(0.95, 0.82, 0.52, 1)
    end
    frame.appliesInButton:SetScript("OnClick", function(self) UI:ToggleEasyNotesAppliesInSearch(self) end)
    frame.appliesInButton:HookScript("OnEnter", function(self)
        UI:ShowNotesTipDelayed(self, "ANCHOR_TOP", L["NOTES_ADD_APPLIES_TT"])
    end)
    frame.appliesInButton:HookScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    frame.showsOnButton = CreateFrame("Button", nil, frame.attachBar)
    StyleSubtleButton(frame.showsOnButton, "+", BTN_W, BTN_H)
    frame.showsOnButton:SetPoint("LEFT", frame.appliesInButton, "RIGHT", 4, 0)
    if frame.showsOnButton.text then
        frame.showsOnButton.text:SetTextColor(0.62, 0.78, 0.95, 1)
    end
    frame.showsOnButton:SetScript("OnClick", function(self) UI:ShowAddShowsOnMenu(self) end)
    frame.showsOnButton:HookScript("OnEnter", function(self)
        UI:ShowNotesTipDelayed(self, "ANCHOR_TOP", L["NOTES_ADD_SHOWS_TT"])
    end)
    frame.showsOnButton:HookScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    -- The places' + shows at the end of the Shows line; the tooltip
    -- link's lives in the more menu.
    frame.appliesInButton:Hide()
    frame.showsOnButton:Hide()

    frame.attachPills = {}

    -- The formatting toolbar is an extension of the note window, exactly like the
    -- search results window under the search bar: it overlaps the window bottom
    -- (no gap), shares the themed fill, and a horizontal divider marks the seam.
    frame.toolbar = CreateFrame("Frame", nil, frame)
    frame.toolbar:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, 2)
    frame.toolbar:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", 0, 2)
    frame.toolbar:SetHeight(TOOLBAR_H)
    frame.toolbar:SetFrameLevel(frame:GetFrameLevel() + 10)
    if ns.CreateRoundedRectBorder then
        ns.CreateRoundedRectBorder(frame.toolbar)
        ns.SetRoundedRectBarHeight(frame.toolbar, 12)
        ns.SetRoundedRectBorderEdgeShown(frame.toolbar, false)
    end
    if ns.ApplyThemeFill then ns.ApplyThemeFill(frame.toolbar) end
    -- Square the toolbar's top so it butts flush under the window (no rounded
    -- notches showing the background at the seam).
    if ns.SetRoundedRectSquareTop then ns.SetRoundedRectSquareTop(frame.toolbar) end
    frame.toolbarDivider = frame.toolbar:CreateTexture(nil, "OVERLAY")
    frame.toolbarDivider:SetColorTexture(0.30, 0.30, 0.33, 0.6)
    frame.toolbarDivider:SetHeight(1)
    frame.toolbarDivider:SetPoint("TOPLEFT", frame.toolbar, "TOPLEFT", 8, -2)
    frame.toolbarDivider:SetPoint("TOPRIGHT", frame.toolbar, "TOPRIGHT", -8, -2)
    if ns.RegisterThemeCallback then
        ns.RegisterThemeCallback(function()
            if ns.ApplyThemeFill and frame.toolbar then
                ns.ApplyThemeFill(frame.toolbar)
                if ns.SetRoundedRectSquareTop then ns.SetRoundedRectSquareTop(frame.toolbar) end
            end
        end)
    end
    frame.toolbarButtons = {}
    frame.toolbar:SetScript("OnSizeChanged", function()
        UI:LayoutEasyNotesToolbar()
    end)
    UI._notes.activeModes = UI._notes.activeModes or {}
    for i = 1, #FORMAT_ACTIONS do
        local action = FORMAT_ACTIONS[i]
        local btn = CreateFrame("Button", nil, frame.toolbar)
        local label = action.buttonLabel or action.key
        if action.mode == "italic" and UI._notes.puaGlyphs then
            label = ITALIC_MAP[label] or label
        end
        StyleSubtleButton(btn, label, BTN_W, BTN_H)
        btn.tip = action.tip
        btn.actionKey = action.mode
        btn.actionIndex = i
        if btn.text then
            local font = action.buttonFont
            if font and _G[font] then btn.text:SetFontObject(_G[font]) end
            -- No outline: THICKOUTLINE's halo read as a shadow behind B and A.
            UI:ApplyEasyNotesCustomFont(btn.text, action.fontSize)
        end
        if action.isListMenu then
            btn.text:Hide()
            btn.listIcon = btn:CreateTexture(nil, "OVERLAY")
            btn.listIcon:SetSize(14, 14)
            btn.listIcon:SetPoint("CENTER")
            btn.listIcon:SetTexture("Interface\\AddOns\\EasyFind_Notes\\Images\\list")
            btn.listIcon:SetVertexColor(0.84, 0.84, 0.86, 1)
            UI:BuildEasyNotesListMenu(frame, btn, action.listMenu)
        end
        if action.isColor then
            btn.colorBar = btn:CreateTexture(nil, "OVERLAY")
            btn.colorBar:SetSize(11, 2)
            btn.colorBar:SetPoint("CENTER", btn, "CENTER", 0, -7)
            btn.colorBar:SetColorTexture(0.74, 0.74, 0.78, 1)
            UI._notes.colorButton = btn
        elseif action.mode == "underline" then
            btn.underBar = btn:CreateTexture(nil, "OVERLAY")
            btn.underBar:SetSize(10, 1.6)
            btn.underBar:SetPoint("CENTER", btn, "CENTER", 0, -7)
            btn.underBar:SetColorTexture(0.84, 0.84, 0.86, 1)
        elseif action.mode == "strike" then
            btn.strikeBar = btn:CreateTexture(nil, "OVERLAY")
            btn.strikeBar:SetSize(11, 1.6)
            btn.strikeBar:SetPoint("CENTER", btn, "CENTER", 0, 0)
            btn.strikeBar:SetColorTexture(0.84, 0.84, 0.86, 1)
        end
        btn:SetScript("OnMouseDown", function(self)
            local f = UI._notes.frame
            if f and f.editor then
                local cs = UI._notes.curSelection
                self._capturedLo = cs and cs.lo or nil
                self._capturedHi = cs and cs.hi or nil
                self._capturedCursor = f.editor:GetCursorPosition() or UI._notes.lastCursor
            end
        end)
        btn:SetScript("OnClick", function(self)
            if action.isListMenu then
                UI:ToggleEasyNotesListMenu(self)
                return
            end
            UI:ApplyEasyNotesFormat(action, self._capturedLo, self._capturedHi, self._capturedCursor)
            self._capturedLo, self._capturedHi, self._capturedCursor = nil, nil, nil
        end)
        btn:SetScript("OnEnter", function(self)
            self._hover = true
            UI:RefreshEasyNotesToolbarButton(self)
            UI:ShowNotesTipDelayed(self, "ANCHOR_TOP")
        end)
        btn:SetScript("OnLeave", function(self)
            self._hover = nil
            UI:RefreshEasyNotesToolbarButton(self)
            if GameTooltip then GameTooltip:Hide() end
        end)
        frame.toolbarButtons[i] = btn
        UI:RefreshEasyNotesToolbarButton(btn)
    end
    do
        local fsBtn = CreateFrame("Button", nil, frame.toolbar)
        StyleSubtleButton(fsBtn, tostring(db.fontSize or FONT_SIZE_DEFAULT), BTN_W, BTN_H)
        fsBtn.tip = L["NOTES_FONT_SIZE"]
        if ns.SetRoundedRectFill then ns.SetRoundedRectFill(fsBtn, 0, 0, 0, 0, true) end
        fsBtn:SetScript("OnEnter", function(self)
            if ns.SetRoundedRectFill then ns.SetRoundedRectFill(self, 0.20, 0.20, 0.22, 1, true) end
        end)
        fsBtn:SetScript("OnLeave", function(self)
            if ns.SetRoundedRectFill then ns.SetRoundedRectFill(self, 0, 0, 0, 0, true) end
        end)
        fsBtn:SetScript("OnClick", function() UI:ToggleEasyNotesFontFlyout() end)
        frame.fontSizeButton = fsBtn
        frame.toolbarButtons[#frame.toolbarButtons + 1] = fsBtn

        local SIZES = { 9, 10, 11, 12, 13, 14, 16, 18, 20, 22, 24, 28 }
        local rowH = 16
        local flyout = CreateFrame("Frame", nil, frame)
        flyout:SetFrameStrata("FULLSCREEN_DIALOG")
        flyout:SetFrameLevel(frame:GetFrameLevel() + 30)
        flyout:SetSize(46, #SIZES * rowH + 8)
        if ns.CreateRoundedRectBorder then
            ns.CreateRoundedRectBorder(flyout)
            ns.SetRoundedRectBarHeight(flyout, 10)
            local c = ns.PANEL_CARD_FILL or { 0.08, 0.08, 0.09 }
            ns.SetRoundedRectFill(flyout, c[1], c[2], c[3], 1, true)
            ns.SetRoundedRectBorderEdgeShown(flyout, false)
        end
        flyout:SetPoint("BOTTOM", fsBtn, "TOP", 0, 4)
        flyout:Hide()
        for idx = 1, #SIZES do
            local sz = SIZES[idx]
            local opt = CreateFrame("Button", nil, flyout)
            opt:SetSize(38, rowH)
            opt:SetPoint("TOP", flyout, "TOP", 0, -4 - (idx - 1) * rowH)
            opt.text = opt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            opt.text:SetPoint("CENTER")
            opt.text:SetText(tostring(sz))
            opt:SetScript("OnEnter", function(self) self.text:SetTextColor(1, 0.82, 0.3, 1) end)
            opt:SetScript("OnLeave", function(self) self.text:SetTextColor(0.84, 0.84, 0.86, 1) end)
            opt:SetScript("OnClick", function()
                UI:AdjustEasyNotesFontSize(0, false, sz)
                flyout:Hide()
            end)
        end
        if Utils.AttachOutsideClickClose then
            Utils.AttachOutsideClickClose(flyout)
        end
        frame.fontSizeFlyout = flyout
    end
    UI:LayoutEasyNotesToolbar()
    frame.toolbar:SetShown(db.toolbarShown == true)
    UI:UpdateEasyNotesToolbarSeam()
    UI._notes.toolbarShown = db.toolbarShown == true

    frame.resizeGrip = CreateFrame("Button", nil, frame)
    frame.resizeGrip:SetSize(16, 16)
    frame.resizeGrip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    frame.resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    frame.resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    frame.resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    frame.resizeGrip:SetAlpha(0)
    frame.resizeGrip:SetScript("OnEnter", function(self) self:SetAlpha(1) end)
    frame.resizeGrip:SetScript("OnLeave", function(self)
        if not self._resizing then self:SetAlpha(0) end
    end)
    frame.resizeGrip:SetScript("OnMouseDown", function(self)
        -- Manual resize wins over auto-resize: turn it off so the content-follow
        -- snap does not fight the drag (the source of the snapping).
        local db = NormalizeDB()
        if db.autoResize then
            db.autoResize = false
            UI:RefreshEasyNotesAutoResizeButton()
        end
        PinTopLeftAnchor()
        local sc = frame:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        self._startCX, self._startCY = cx / sc, cy / sc
        self._startW, self._startH = frame:GetWidth(), frame:GetHeight()
        self._resizing = true
        self:SetScript("OnUpdate", function(grip)
            if not IsMouseButtonDown("LeftButton") then
                grip:SetScript("OnUpdate", nil)
                grip._resizing = nil
                local dims = UI._notes.paletteShown and EasyNotesDB.window or EasyNotesDB.editorWindow
                dims.w = math.floor(frame:GetWidth() + 0.5)
                dims.h = math.floor(frame:GetHeight() + 0.5)
                if not grip:IsMouseOver() then grip:SetAlpha(0) end
                return
            end
            local s = frame:GetEffectiveScale()
            local mx, my = GetCursorPosition()
            mx, my = mx / s, my / s
            local nw = mmax(MIN_WIDTH, grip._startW + (mx - grip._startCX))
            local nh = mmax(MIN_HEIGHT, grip._startH + (grip._startCY - my))
            frame:SetSize(nw, nh)
        end)
    end)

    frame.palette = CreateFrame("Frame", nil, frame)
    frame.palette:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -HEADER_H - 4)
    frame.palette:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 8)
    if ns.CreateRoundedRectBorder then
        ns.CreateRoundedRectBorder(frame.palette)
        ns.SetRoundedRectBarHeight(frame.palette, 10)
        ns.SetRoundedRectFill(frame.palette, 0, 0, 0, 0, true)
        ns.SetRoundedRectBorderColor(frame.palette, 0, 0, 0, 0, true)
    end

    frame.paletteSearchShell = CreateFrame("Frame", nil, frame.palette)
    frame.paletteSearchShell:SetPoint("TOPLEFT", frame.palette, "TOPLEFT", 10, -10)
    frame.paletteSearchShell:SetPoint("TOPRIGHT", frame.palette, "TOPRIGHT", -10, -10)
    frame.paletteSearchShell:SetHeight(24)
    if ns.CreateRoundedRectBorder then
        ns.CreateRoundedRectBorder(frame.paletteSearchShell)
        ns.SetRoundedRectBarHeight(frame.paletteSearchShell, 10)
        local c = ns.BTN_FILL_NORMAL or { 0.16, 0.19, 0.25 }
        ns.SetRoundedRectFill(frame.paletteSearchShell, c[1], c[2], c[3], 1, true)
        ns.SetRoundedRectBorderEdgeShown(frame.paletteSearchShell, false)
    end
    -- Filter button (triangle) opens a themed menu to filter the note list by
    -- character and category, mirroring the main search bar's filter.
    frame.paletteFilterBtn = CreateFrame("Button", nil, frame.paletteSearchShell)
    frame.paletteFilterBtn:SetSize(20, 20)
    frame.paletteFilterBtn:SetPoint("RIGHT", frame.paletteSearchShell, "RIGHT", -4, 0)
    do
        local farrow = frame.paletteFilterBtn:CreateTexture(nil, "OVERLAY")
        farrow:SetSize(10, 10)
        farrow:SetPoint("CENTER")
        farrow:SetTexture(ns.FILTER_ARROW_TEX)
        farrow:SetVertexColor(0.7, 0.7, 0.74, 1)
        frame.paletteFilterBtn.arrow = farrow
    end
    frame.paletteFilterBtn:SetScript("OnClick", function(self) UI:ShowEasyNotesFilterMenu(self) end)
    frame.paletteFilterBtn:HookScript("OnEnter", function(self) self.arrow:SetVertexColor(1, 1, 1, 1) end)
    frame.paletteFilterBtn:HookScript("OnLeave", function(self)
        -- Stays engaged (white) the whole time its menu is open; the menu's
        -- onHide restores the rest color.
        if UI._notes._filterMenu and UI._notes._filterMenu:IsShown() then return end
        self.arrow:SetVertexColor(0.7, 0.7, 0.74, 1)
    end)
    frame.paletteSearchIcon = frame.paletteSearchShell:CreateTexture(nil, "OVERLAY")
    frame.paletteSearchIcon:SetSize(12, 12)
    frame.paletteSearchIcon:SetPoint("LEFT", frame.paletteSearchShell, "LEFT", 8, 0)
    frame.paletteSearchIcon:SetAtlas("common-search-magnifyingglass")
    frame.paletteSearchIcon:SetVertexColor(0.62, 0.62, 0.66, 1)
    frame.paletteSearch = CreateFrame("EditBox", nil, frame.paletteSearchShell)
    frame.paletteSearch:SetPoint("LEFT", frame.paletteSearchIcon, "RIGHT", 6, 0)
    frame.paletteSearch:SetPoint("RIGHT", frame.paletteFilterBtn, "LEFT", -4, 0)
    frame.paletteSearch:SetHeight(20)
    frame.paletteSearch:SetAutoFocus(false)
    frame.paletteSearch:SetFontObject("GameFontHighlightSmall")
    frame.paletteSearch:SetTextColor(0.95, 0.95, 0.95, 1)
    frame.paletteSearchPlaceholder = frame.paletteSearchShell:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.paletteSearchPlaceholder:SetPoint("LEFT", frame.paletteSearchIcon, "RIGHT", 6, 0)
    frame.paletteSearchPlaceholder:SetText(L["NOTES_SEARCH"])
    frame.paletteSearchPlaceholder:SetTextColor(0.48, 0.48, 0.52, 1)
    frame.paletteSearch:SetScript("OnTextChanged", function(self)
        frame.paletteSearchPlaceholder:SetShown((self:GetText() or "") == "")
        UI:RefreshEasyNotesPalette()
    end)
    frame.paletteSearch:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    frame.paletteSearch:SetScript("OnEnterPressed", function()
        local rows = UI._notes.paletteRows
        for i = 1, #rows do
            local r = rows[i]
            if r:IsShown() and r.noteID then
                UI:SelectEasyNote(r.noteID)
                UI:HideEasyNotesPalette()
                return
            end
        end
    end)

    frame.paletteContextBar = CreateFrame("Frame", nil, frame.palette)
    frame.paletteContextBar:SetPoint("TOPLEFT", frame.paletteSearchShell, "BOTTOMLEFT", 0, 0)
    frame.paletteContextBar:SetPoint("TOPRIGHT", frame.paletteSearchShell, "BOTTOMRIGHT", 0, 0)
    frame.paletteContextBar:SetHeight(26)
    frame.paletteContextBar:Hide()

    frame.paletteList = CreateFrame("ScrollFrame", nil, frame.palette)
    frame.paletteList:SetPoint("TOPLEFT", frame.paletteSearchShell, "BOTTOMLEFT", 0, -6)
    frame.paletteList:SetPoint("BOTTOMRIGHT", frame.palette, "BOTTOMRIGHT", -10, 10)
    frame.paletteListChild = CreateFrame("Frame", nil, frame.paletteList)
    frame.paletteListChild:SetSize(1, 1)
    frame.paletteList:SetScrollChild(frame.paletteListChild)
    -- A resize fits the rows' tags to the new width.
    frame.paletteList:SetScript("OnSizeChanged", function(_, w)
        if not (w and w > 0) then return end
        frame.paletteListChild:SetWidth(w)
        local rows = UI._notes.paletteRows or {}
        for i = 1, #rows do
            if rows[i]:IsShown() then UI:LayoutEasyNotesRowTags(rows[i], rows[i].tagNote, w) end
        end
    end)
    frame.paletteList:EnableMouseWheel(true)
    -- Selection clearing lives in ONE owner: the GLOBAL_MOUSE_DOWN watcher
    -- installed at the end of frame construction (clicking anywhere that is
    -- not a note row deselects).
    if ns.Utils and ns.Utils.CreateMinimalScrollBar then
        frame.paletteScrollBar = ns.Utils.CreateMinimalScrollBar(frame.paletteList, frame.palette)
        frame.paletteScrollBar:ClearAllPoints()
        frame.paletteScrollBar:SetPoint("TOPLEFT", frame.paletteList, "TOPRIGHT", 4, -4)
        frame.paletteScrollBar:SetPoint("BOTTOMLEFT", frame.paletteList, "BOTTOMRIGHT", 4, 4)
    end

    frame.palette:Hide()
    UI:RefreshEasyNotesAutoResizeButton()

    if hooksecurefunc and not UI._notes._itemClickHooked then
        UI._notes._itemClickHooked = true
        hooksecurefunc("HandleModifiedItemClick", function(link)
            if not link then return end
            if not (IsShiftKeyDown and IsShiftKeyDown()) then return end
            local nf = UI._notes.frame
            if not (nf and nf:IsShown() and not UI._notes.paletteShown) then return end
            local editor = nf.editor
            if not (editor and editor.HasFocus and editor:HasFocus()) then return end
            local pos = editor:GetCursorPosition() or 0
            local txt = editor:GetText() or ""
            UI._notes.inputBusy = true
            editor:SetText(txt:sub(1, pos) .. link .. txt:sub(pos + 1))
            editor:SetCursorPosition(pos + #link)
            UI._notes.inputBusy = nil
        end)
    end

    -- ESC closes the notes window when nothing has keyboard focus, without the
    -- window ever capturing keys itself: a named companion frame rides
    -- UISpecialFrames, so WoW hides IT on ESC and the handler translates that
    -- into closing menus first, then the window.
    local escCatcher = CreateFrame("Frame", "EasyNotesEscCatcher", UIParent)
    escCatcher:Hide()
    escCatcher:SetScript("OnHide", function(self)
        local nf = UI._notes.frame
        if not (nf and nf:IsShown()) then return end
        local consumed = UI:CloseEasyNotesOpenMenus()
        if not consumed and next(UI._notes.paletteSelection) then
            -- ESC clears the row selection before it closes the window.
            for k in next, UI._notes.paletteSelection do UI._notes.paletteSelection[k] = nil end
            UI:RepaintEasyNotesPaletteRows()
            consumed = true
        end
        if consumed then
            -- Something consumed this ESC; re-arm for the next press.
            if Utils.SafeAfter then Utils.SafeAfter(0, function()
                if nf:IsShown() then self:Show() end
            end) end
            return
        end
        UI:CloseEasyNotes()
    end)
    if not tContains(UISpecialFrames, "EasyNotesEscCatcher") then
        tinsert(UISpecialFrames, "EasyNotesEscCatcher")
    end
    frame:HookScript("OnShow", function() escCatcher:Show() end)
    frame:HookScript("OnHide", function() escCatcher:Hide() end)

    -- Left-clicking anywhere that is not a note row clears the list selection.
    -- Single owner for outside-click deselect: rows' own handlers manage row
    -- clicks, the trash button acts on the selection, and cursor menus (row
    -- context menu) must not tear it down mid-use.
    frame.selectionWatcher = CreateFrame("Frame")
    frame.selectionWatcher:SetScript("OnEvent", function(_, _, button)
        if button and button ~= "LeftButton" then return end
        if not next(UI._notes.paletteSelection) then return end
        if frame.deleteButton and frame.deleteButton:IsMouseOver() then return end
        if Utils.IsCursorMenuMouseOver and Utils.IsCursorMenuMouseOver() then return end
        local rows = UI._notes.paletteRows
        for i = 1, #rows do
            local r = rows[i]
            if r and r:IsShown() and r:IsMouseOver() then return end
        end
        for k in next, UI._notes.paletteSelection do UI._notes.paletteSelection[k] = nil end
        UI:RepaintEasyNotesPaletteRows()
    end)
    frame:HookScript("OnShow", function() frame.selectionWatcher:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
    frame:HookScript("OnHide", function() frame.selectionWatcher:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
    if frame:IsShown() then frame.selectionWatcher:RegisterEvent("GLOBAL_MOUSE_DOWN") end

    return frame
end

function UI:RefreshEasyNotesHeaderOnly()
    local frame = UI._notes.frame
    if not frame then return end
    local note = GetSelectedNote()
    frame.title:SetText(note and NoteTitle(note) or L["NOTES_NO_NOTE"])
end

-- Ctrl+S: the open note is stored as typed already; this stores it now and
-- says so (the game writes saved data to disk at a reload or logout).
function UI:SaveEasyNoteNow()
    local frame = UI._notes.frame
    local id = UI._notes.selectedID
    if not (frame and id) then return end
    UpdateBody(id, frame.editor:GetText() or "")
    local flash = frame.savedFlash
    if not flash then
        flash = frame.footer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        flash._efOwnColor = true
        flash:SetPoint("RIGHT", frame.charCounter, "LEFT", -10, 0)
        flash:SetText(L["NOTES_SAVED"])
        flash.fade = flash:CreateAnimationGroup()
        local a = flash.fade:CreateAnimation("Alpha")
        a:SetFromAlpha(1)
        a:SetToAlpha(0)
        a:SetStartDelay(0.9)
        a:SetDuration(0.5)
        flash.fade:SetScript("OnFinished", function() flash:Hide() end)
        frame.savedFlash = flash
    end
    local c = ns.COPIED_COLOR or { 0.48, 1.0, 0.62 }
    flash:SetTextColor(c[1], c[2], c[3], 1)
    flash.fade:Stop()
    flash:SetAlpha(1)
    flash:Show()
    flash.fade:Play()
end

function UI:UpdateEasyNotesCharCounter()
    local frame = UI._notes.frame
    if not frame then return end
    local note = GetSelectedNote()
    frame.charCounter:SetText(Utils.sformat(L["NOTES_CHARS"], CharCount(note and note.body or "")))
end

function UI:RefreshEasyNotes()
    RefreshSearchRows()
    local frame = UI._notes.frame
    if not frame then return end
    NormalizeDB()
    -- Keep the editor font current with the richText2 setting on every load, not
    -- only when the toggle or font size changes.
    self:ApplyEasyNotesEditorFont()
    local note = GetSelectedNote()
    if not note then
        local list = SortedNotes()
        note = list[1]
        UI._notes.selectedID = note and note.id or nil
    end
    if note and NormalizeDB().richText2 then UI:MigrateNoteToRichText2(note) end
    if note then UI:MigrateColorEscapes(note) end
    -- Clean any decoration ranges that an earlier shift bug corrupted (negative
    -- starts, ranges past the end): clamp to the body and drop empties.
    if note and note.decorations then
        local maxByte = #(note.body or "") + 1
        for i = #note.decorations, 1, -1 do
            local d = note.decorations[i]
            if d.startByte < 1 then d.startByte = 1 end
            if d.endByte > maxByte then d.endByte = maxByte end
            if d.endByte <= d.startByte then tremove(note.decorations, i) end
        end
    end
    UI._notes.loadingNote = true
    if note then
        -- Show the rendered display unless the editor is being actively edited
        -- (focused), in which case show the raw markdown so the markers are editable.
        local wantText = frame.editor:HasFocus() and (note.body or "")
            or UI:MarkdownToDisplay(note.body or "")
        if frame.editor:GetText() ~= wantText then
            frame.editor:SetText(wantText)
            frame.editor:SetCursorPosition(0)
        end
        frame.title:SetText(NoteTitle(note))
        -- Only the more-options button shows here; delete/find/auto-resize are
        -- folded into that menu and must stay hidden or they reflow the header.
        -- Only in the note-editing view, never the palette (home) list, so it
        -- doesn't linger after deleting a note from the list.
        if frame.overflowButton then frame.overflowButton:SetShown(not UI._notes.paletteShown) end
    else
        frame.editor:SetText("")
        frame.title:SetText(L["NOTES_NO_NOTE"])
        if frame.overflowButton then frame.overflowButton:Hide() end
    end
    UI._notes.loadingNote = nil
    UI._notes.lastEditorText = frame.editor:GetText() or ""
    UI._notes.lastSelection = nil
    if frame.editor.HighlightText then frame.editor:HighlightText(0, 0) end
    self:UpdateEasyNotesCharCounter()
    self:RefreshEasyNotesHeaderOnly()
    -- Render the read view unless the editbox is being actively edited.
    self:SetEasyNotesRendered(not frame.editor:HasFocus())
    self:RefreshEasyNotesAttachBar()
    self:RefreshEasyNotesHeaderNav()
    self:RefreshEasyNotesDragHandles()
    if UI._notes.paletteShown then self:RefreshEasyNotesPalette() end
    if notesNS.ChecklistView then notesNS.ChecklistView.Refresh() end
end

function UI:SelectEasyNote(id)
    UI._notes.selectedID = id
    self:RefreshEasyNotes()
end

-- While the toolbar is expanded, square the note window's bottom corners so it
-- and the toolbar (whose top is already squared) form one continuous edge;
-- restore the rounded corners when it collapses.
function UI:UpdateEasyNotesToolbarSeam()
    local frame = UI._notes.frame
    if not frame then return end
    if frame.toolbar and frame.toolbar:IsShown() then
        if ns.SetRoundedRectSquareBottom then ns.SetRoundedRectSquareBottom(frame) end
    elseif ns.RestoreRoundedRectCorners then
        ns.RestoreRoundedRectCorners(frame)
    end
end

function UI:ToggleEasyNotesToolbar()
    UI._notes.toolbarShown = not UI._notes.toolbarShown
    local frame = UI._notes.frame
    if frame then
        frame.toolbar:SetShown(UI._notes.toolbarShown)
        self:UpdateEasyNotesToolbarSeam()
        -- the toolbar covers the footer, so swap T <-> x and hide the counter
        if frame.formatButton and frame.formatButton.text then
            frame.formatButton.text:SetText(UI._notes.toolbarShown and "x" or "T")
        end
        if frame.charCounter then
            frame.charCounter:SetShown(not UI._notes.toolbarShown)
        end
    end
    NormalizeDB().toolbarShown = UI._notes.toolbarShown
end

function UI:RefreshEasyNotesAutoResizeButton()
    local frame = UI._notes.frame
    if not (frame and frame.autoResizeButton and ns.SetRoundedRectFill) then return end
    if NormalizeDB().autoResize then
        local c = ns.NAV_SELECTED_FILL or {0.20,0.30,0.45}; ns.SetRoundedRectFill(frame.autoResizeButton, c[1], c[2], c[3], 1, true)
    else
        local c = ns.BTN_FILL_NORMAL or {0.13,0.13,0.14}; ns.SetRoundedRectFill(frame.autoResizeButton, c[1], c[2], c[3], 1, true)
    end
end

function UI:ToggleEasyNotesAutoResize()
    local db = NormalizeDB()
    db.autoResize = not db.autoResize
    self:RefreshEasyNotesAutoResizeButton()
    if db.autoResize then self:UpdateEasyNotesAutoResize() end
end

function UI:UpdateEasyNotesAutoResize()
    local frame = UI._notes.frame
    if not frame then return end
    if not NormalizeDB().autoResize or UI._notes.paletteShown then return end
    if frame.resizeGrip and frame.resizeGrip._resizing then return end
    local contentH = frame.editor:GetHeight() or 0
    -- The formatting toolbar sits below the window, so it no longer adds to the
    -- window's own height.
    local chrome = HEADER_H + 14 + FOOTER_H + 4
    local needed = mmax(MIN_HEIGHT, contentH + chrome)
    if math.abs(needed - (frame:GetHeight() or 0)) > 0.5 then
        frame:SetHeight(needed)
        EasyNotesDB.editorWindow.h = math.floor(needed + 0.5)
        EasyNotesDB.editorWindow.w = math.floor(frame:GetWidth() + 0.5)
    end
end

-- Colour used for a toggled-on toolbar button. Reads EasyFind's live theme
-- selection colour so it tracks the theme instead of the old hardcoded red.
local function ActiveButtonColor()
    local c = ns.NAV_SELECTED_FILL
    if c then return c[1], c[2], c[3], c[4] or 1 end
    return 0.20, 0.30, 0.45, 1
end

-- Small themed menu for the combined list button. Built once per note frame and
-- reused; matches the font-size flyout already in the toolbar.
local LIST_GLYPH_COLOR = { 0.90, 0.90, 0.92 }

-- Each list style keeps the graphic it had as its own toolbar button before the
-- three were folded into one menu: bulleted draws dots + lines, checklist shows
-- the checkbox texture, numbered draws numerals + lines. Drawn into a 16px box
-- anchored at the row's left edge.
local function BuildListMenuGlyph(row, key)
    local g = CreateFrame("Frame", nil, row)
    g:SetSize(16, 16)
    g:SetPoint("LEFT", row, "LEFT", 8, 0)
    local col = LIST_GLYPH_COLOR
    if key == "checklist" then
        local check = g:CreateTexture(nil, "OVERLAY")
        check:SetSize(13, 13)
        check:SetPoint("CENTER")
        check:SetTexture("Interface\\AddOns\\EasyFind_Notes\\Images\\checkbox")
        check:SetVertexColor(col[1], col[2], col[3], 1)
    elseif key == "numlist" then
        for r = 1, 3 do
            local yOff = (2 - r) * 5
            local num = g:CreateFontString(nil, "OVERLAY")
            num:SetFont("Fonts\\FRIZQT__.TTF", 8, "")
            num:SetText(tostring(r))
            num:SetTextColor(col[1], col[2], col[3], 1)
            num:SetPoint("LEFT", g, "LEFT", 0, yOff)
            local line = g:CreateTexture(nil, "OVERLAY")
            line:SetSize(8, 1)
            line:SetColorTexture(col[1], col[2], col[3], 1)
            line:SetPoint("LEFT", g, "LEFT", 6, yOff)
        end
    else
        for r = 1, 3 do
            local yOff = (2 - r) * 5
            local dot = g:CreateTexture(nil, "OVERLAY")
            dot:SetSize(3, 3)
            dot:SetColorTexture(col[1], col[2], col[3], 1)
            dot:SetPoint("LEFT", g, "LEFT", 1, yOff)
            local line = g:CreateTexture(nil, "OVERLAY")
            line:SetSize(8, 1)
            line:SetColorTexture(col[1], col[2], col[3], 1)
            line:SetPoint("LEFT", g, "LEFT", 6, yOff)
        end
    end
    return g
end

function UI:BuildEasyNotesListMenu(frame, btn, items)
    if frame.listMenuFlyout then btn._listFlyout = frame.listMenuFlyout; return end
    local flyout = CreateFrame("Frame", nil, frame)
    flyout:SetFrameStrata("FULLSCREEN_DIALOG")
    flyout:SetFrameLevel(frame:GetFrameLevel() + 30)
    if ns.StyleMenuPanel then
        ns.StyleMenuPanel(flyout)
    elseif ns.CreateRoundedRectBorder then
        ns.CreateRoundedRectBorder(flyout)
        ns.SetRoundedRectBarHeight(flyout, 10)
        local c = ns.PANEL_CARD_FILL or { 0.08, 0.08, 0.09 }
        ns.SetRoundedRectFill(flyout, c[1], c[2], c[3], 1, true)
    end
    flyout:SetPoint("TOP", btn, "BOTTOM", 0, -4)
    flyout:Hide()

    -- A single horizontal row of icon buttons (no labels) that behave like the
    -- formatting toolbar buttons: clickable, hover- and active-highlighted, with
    -- the style name shown as a 0.4s tooltip on hover.
    local PAD, GAP = 6, 4
    flyout.rows = {}
    for idx = 1, #items do
        local item = items[idx]
        local opt = CreateFrame("Button", nil, flyout)
        opt:SetSize(STD_BTN_W, STD_BTN_H)
        opt:SetPoint("LEFT", flyout, "LEFT", PAD + (idx - 1) * (STD_BTN_W + GAP), 0)
        if ns.CreateRoundedRectBorder then
            ns.CreateRoundedRectBorder(opt)
            ns.SetRoundedRectBarHeight(opt, 10)
            ns.SetRoundedRectBorderEdgeShown(opt, false)
        end
        opt.listMode = item.mode
        BuildListMenuGlyph(opt, item.key)
        opt:SetScript("OnEnter", function(self)
            self._hover = true
            UI:PaintEasyNotesListButton(self)
            UI:ShowNotesTipDelayed(self, "ANCHOR_TOP", item.tip)
        end)
        opt:SetScript("OnLeave", function(self)
            self._hover = nil
            UI:PaintEasyNotesListButton(self)
            UI:HideNotesTip(self)
        end)
        opt:SetScript("OnClick", function()
            local cs = UI._notes.curSelection
            local cursor = frame.editor and frame.editor:GetCursorPosition() or UI._notes.lastCursor
            UI:ApplyEasyNotesFormat(item, cs and cs.lo, cs and cs.hi, cursor)
            flyout:Hide()
        end)
        UI:PaintEasyNotesListButton(opt)
        flyout.rows[idx] = opt
    end
    flyout:SetSize(PAD * 2 + #items * STD_BTN_W + (#items - 1) * GAP, STD_BTN_H + 8)
    if Utils.AttachOutsideClickClose then
        Utils.AttachOutsideClickClose(flyout, btn)
    end
    frame.listMenuFlyout = flyout
    btn._listFlyout = flyout
end

-- Paints a list-menu icon button like the toolbar formatting buttons: accent
-- fill when its style is active, a hover fill on hover, transparent otherwise.
function UI:PaintEasyNotesListButton(opt)
    if not (opt and ns.SetRoundedRectFill) then return end
    local active = opt.listMode and UI._notes.activeModes and UI._notes.activeModes[opt.listMode]
    if active then
        ns.SetRoundedRectFill(opt, ActiveButtonColor())
    elseif opt._hover then
        local c = ns.BTN_FILL_HOVER or { 0.22, 0.27, 0.34 }
        ns.SetRoundedRectFill(opt, c[1], c[2], c[3], 1, true)
    else
        ns.SetRoundedRectFill(opt, 0, 0, 0, 0, true)
    end
end

function UI:ToggleEasyNotesListMenu(btn)
    local flyout = btn and btn._listFlyout
    if not flyout then return end
    local show = not flyout:IsShown()
    flyout:SetShown(show)
    if show and flyout.rows then
        for _, opt in ipairs(flyout.rows) do UI:PaintEasyNotesListButton(opt) end
    end
end

-- Central ESC/dismiss for the note's transient popups so every new menu closes
-- on ESC without a per-menu handler. Returns true if it closed something.
function UI:CloseEasyNotesOpenMenus()
    local frame = UI._notes.frame
    local closed = false
    local function hideIfShown(f)
        if f and f:IsShown() then f:Hide(); closed = true end
    end
    if frame then
        hideIfShown(frame.listMenuFlyout)
        hideIfShown(frame.fontSizeFlyout)
        hideIfShown(frame.settingsPanel)
    end
    hideIfShown(UI._notes._moreMenu)
    hideIfShown(UI._notes._filterMenu)
    return closed
end

function UI:LayoutEasyNotesToolbar()
    local frame = UI._notes.frame
    if not (frame and frame.toolbar and frame.toolbarButtons) then return end
    local n = #frame.toolbarButtons
    if n == 0 then return end
    -- The toolbar spans the window width (anchored below it); center the button
    -- row in it, clamped to the left pad when the window is narrow.
    local pad = 8
    local gap = 4
    local totalW = n * STD_BTN_W + (n - 1) * gap
    local barW = frame.toolbar:GetWidth() or 0
    local x = math.max(pad, (barW - totalW) / 2)
    for i = 1, n do
        local btn = frame.toolbarButtons[i]
        btn:ClearAllPoints()
        btn:SetPoint("LEFT", frame.toolbar, "LEFT", x, 0)
        btn:SetWidth(STD_BTN_W)
        x = x + STD_BTN_W + gap
    end
end

function UI:RefreshEasyNotesToolbarButton(btn)
    if not btn or not btn.actionKey then return end
    local active = UI._notes.activeModes[btn.actionKey]
    -- A light theme's toolbar is pale: the engaged fill takes the theme's
    -- control accent and resting ink its dark text, or neither shows.
    local pal = ns.ACTIVE_UI_PALETTE
    local light = pal and pal.light
    if ns.SetRoundedRectFill then
        if active then
            local c = light and ns.CONTROL_ACCENT
            if c then ns.SetRoundedRectFill(btn, c[1], c[2], c[3], 1, true)
            else ns.SetRoundedRectFill(btn, ActiveButtonColor()) end
        elseif btn._hover then
            local c = light and ns.BTN_FILL_HOVER
            if c then ns.SetRoundedRectFill(btn, c[1], c[2], c[3], 1, true)
            else ns.SetRoundedRectFill(btn, 0.20, 0.20, 0.22, 1, true) end
        else
            ns.SetRoundedRectFill(btn, 0, 0, 0, 0, true)
        end
    end
    local ink = light and not active and ns.TEXT_PRIMARY
    local ir, ig, ib = 0.84, 0.84, 0.86
    if active then ir, ig, ib = 1, 1, 1 elseif ink then ir, ig, ib = ink[1], ink[2], ink[3] end
    if btn.text then btn.text:SetTextColor(ir, ig, ib, 1) end
    if btn.underBar then btn.underBar:SetColorTexture(ir, ig, ib, 1) end
    if btn.strikeBar then btn.strikeBar:SetColorTexture(ir, ig, ib, 1) end
    if btn.listIcon then btn.listIcon:SetVertexColor(ir, ig, ib, 1) end
    -- The colour bar shows the colour typing would actually produce here
    -- (typing colour from the caret/selection context), not the last pick.
    if btn.colorBar then
        local tc = UI._notes.typingColor
        if tc then
            btn.colorBar:SetColorTexture(tc.r or 1, tc.g or 1, tc.b or 1, 1)
        else
            btn.colorBar:SetColorTexture(0.74, 0.74, 0.78, 1)
        end
    end
end

function UI:RefreshAllEasyNotesToolbarButtons()
    local frame = UI._notes.frame
    if frame and frame.toolbarButtons then
        for i = 1, #frame.toolbarButtons do
            self:RefreshEasyNotesToolbarButton(frame.toolbarButtons[i])
        end
    end
    local host = UI._notes.snippetHost
    if host and host.toolbarButtons then
        for i = 1, #host.toolbarButtons do
            self:RefreshEasyNotesToolbarButton(host.toolbarButtons[i])
        end
    end
end

-- Recompute bold/italic/underline/strike state from the current selection
-- (state = format shared by ALL selected chars) or, with no selection, from
-- the glyph immediately before the cursor. Drives the toolbar button states.
function UI:RefreshFormatButtonStates()
    local editor = Fmt.ActiveFormatEditor()
    if not editor then return end
    local modes = UI._notes.activeModes
    if not modes then return end
    local note = Fmt.ActiveFormatDoc()
    local decorations = (note and note.decorations) or {}
    local text = editor:GetText() or ""
    local cs = UI._notes.curSelection
    local lo, hi = cs and cs.lo, cs and cs.hi
    -- An explicit toggle or in-progress typing owns activeModes as sticky intent.
    -- Consume the flag once: while it is set, keep that intent instead of
    -- re-deriving from the caret's neighbour (a space or any glyph-less char
    -- would wrongly clear bold/italic mid-type). Genuine caret navigation
    -- arrives without the flag and re-derives normally.
    local keepIntent = UI._notes.keepModesOnNextRefresh
    UI._notes.keepModesOnNextRefresh = nil
    local richText = NormalizeDB().richText2
    if lo and hi and hi >= lo then
        local sel = text:sub(lo, hi)
        if richText then
            modes.bold = IsRangeFullyCovered(decorations, "bold", lo, hi + 1) or nil
            modes.italic = IsRangeFullyCovered(decorations, "italic", lo, hi + 1) or nil
        else
            modes.bold = (SelectionAllHave(sel, GlyphHasBold)) or nil
            modes.italic = (SelectionAllHave(sel, GlyphHasItalic)) or nil
        end
        modes.underline = IsRangeFullyCovered(decorations, "underline", lo, hi + 1) or nil
        modes.strike = IsRangeFullyCovered(decorations, "strike", lo, hi + 1) or nil
        -- A selection wholly inside one colour range reports that colour, so
        -- the colour bar mirrors the highlighted text like the other modes.
        modes.color = nil
        UI._notes.typingColor = nil
        for d = 1, #decorations do
            local deco = decorations[d]
            if deco.kind == "color" and deco.startByte <= lo and deco.endByte >= hi + 1 then
                UI._notes.typingColor = { r = deco.r, g = deco.g, b = deco.b }
                modes.color = true
                break
            end
        end
    elseif not keepIntent then
        local cursor = editor:GetCursorPosition() or 0
        modes.bold, modes.italic, modes.underline, modes.strike = nil, nil, nil, nil
        modes.color = nil
        UI._notes.typingColor = nil
        if cursor > 0 then
            local pos, g, a, b = 0, nil, nil, nil
            for gl in iterUtf8(text) do
                a = pos + 1; pos = pos + #gl; b = pos; g = gl
                if pos >= cursor then break end
            end
            if g then
                if richText then
                    modes.bold = IsRangeFullyCovered(decorations, "bold", a, b + 1) or nil
                    modes.italic = IsRangeFullyCovered(decorations, "italic", a, b + 1) or nil
                else
                    modes.bold = GlyphHasBold(g) or nil
                    modes.italic = GlyphHasItalic(g) or nil
                end
                modes.underline = IsRangeFullyCovered(decorations, "underline", a, b + 1) or nil
                modes.strike = IsRangeFullyCovered(decorations, "strike", a, b + 1) or nil
                -- Typing colour follows the glyph before the caret, like the
                -- other sticky modes: type inside coloured text, stay coloured.
                for d = 1, #decorations do
                    local deco = decorations[d]
                    if deco.kind == "color" and deco.startByte <= a and deco.endByte > b then
                        UI._notes.typingColor = { r = deco.r, g = deco.g, b = deco.b }
                        modes.color = true
                        break
                    end
                end
            end
        end
    end
    self:RefreshAllEasyNotesToolbarButtons()
end

-- Deferred + coalesced: lets the in-progress text/decoration edit settle
-- (OnTextChanged runs) before button state is recomputed.
function UI:QueueFormatButtonRefresh()
    if UI._notes._fmtQueued then return end
    UI._notes._fmtQueued = true
    if Utils.SafeAfter then
        Utils.SafeAfter(0, function()
            UI._notes._fmtQueued = nil
            UI:RefreshFormatButtonStates()
        end)
    else
        UI._notes._fmtQueued = nil
        UI:RefreshFormatButtonStates()
    end
end

function UI:ApplyEasyNotesFormat(action, capturedLo, capturedHi, capturedCursor)
    local editor = Fmt.ActiveFormatEditor()
    if not (editor and action) then return end
    local text = editor:GetText() or ""
    local cursor = capturedCursor or editor:GetCursorPosition() or #text
    local lo, hi = capturedLo, capturedHi
    if not (lo and hi and hi >= lo) then
        local cs = UI._notes.curSelection
        if cs then lo, hi = cs.lo, cs.hi end
    end
    if action.isColor then
        self:PromptEasyNotesColor(lo, hi, cursor)
        return
    end

    if action.numbered then
        local before = text:sub(1, cursor)
        local newlineIdx = before:find("\n[^\n]*$")
        local lineStart = newlineIdx and (newlineIdx + 1) or 1
        local rest = text:sub(lineStart)
        local existing = rest:match("^(%d+%. )")
        if existing then
            text = text:sub(1, lineStart - 1) .. rest:sub(#existing + 1)
            editor:SetText(text)
            editor:SetCursorPosition(math.max(lineStart - 1, cursor - #existing))
            UI._notes.activeModes.numlist = nil
        else
            local num = 1
            if lineStart > 2 then
                local pStart = FindLineStartByte(text, lineStart - 2)
                local pn = text:sub(pStart, pStart + 12):match("^(%d+)%. ")
                if pn then num = tonumber(pn) + 1 end
            end
            local prefix = num .. ". "
            text = text:sub(1, lineStart - 1) .. prefix .. text:sub(lineStart)
            editor:SetText(text)
            editor:SetCursorPosition(cursor + #prefix)
            UI._notes.activeModes.numlist = true
            for k in pairs(UI._notes.activeModes) do
                if k == "list" or k == "check" then
                    UI._notes.activeModes[k] = nil
                end
            end
        end
        UI:RefreshAllEasyNotesToolbarButtons()
        editor:SetFocus()
        return
    end

    if action.linePrefix then
        local before = text:sub(1, cursor)
        local newlineIdx = before:find("\n[^\n]*$")
        local lineStart = newlineIdx and (newlineIdx + 1) or 1
        if action.toggleCheck then
            local rest = text:sub(lineStart)
            local prefix = rest:sub(1, #CHECK_EMPTY_PREFIX)
            if prefix == CHECK_EMPTY_PREFIX or prefix == CHECK_FILLED_PREFIX then
                text = UI:ToggleEasyNotesCheckbox(text, lineStart)
                editor:SetText(text)
                editor:SetCursorPosition(cursor)
                editor:SetFocus()
                UI:QueueEasyNotesOverlayUpdate()
                return
            end
        end
        local active = UI._notes.activeModes[action.mode]
        local rest = text:sub(lineStart)
        if active and rest:sub(1, #action.linePrefix) == action.linePrefix then
            text = text:sub(1, lineStart - 1) .. rest:sub(#action.linePrefix + 1)
            editor:SetText(text)
            editor:SetCursorPosition(math.max(lineStart - 1, cursor - #action.linePrefix))
            UI._notes.activeModes[action.mode] = nil
        else
            text = text:sub(1, lineStart - 1) .. action.linePrefix .. text:sub(lineStart)
            editor:SetText(text)
            editor:SetCursorPosition(cursor + #action.linePrefix)
            UI._notes.activeModes[action.mode] = true
            for k in pairs(UI._notes.activeModes) do
                if (k == "list" or k == "check" or k == "heading") and k ~= action.mode then
                    UI._notes.activeModes[k] = nil
                end
            end
        end
        UI:RefreshAllEasyNotesToolbarButtons()
        editor:SetFocus()
        return
    end

    if INLINE_MODES[action.mode] then
        if lo and hi and hi >= lo then
            local sel = text:sub(lo, hi)
            local newLo, newHi = lo, hi
            if action.mode == "strike" or action.mode == "underline" then
                -- Lines stay decorations (they never drifted).
                local note = Fmt.ActiveFormatDoc()
                if note then
                    note.decorations = note.decorations or {}
                    local sB, eB = lo, hi + 1
                    if IsRangeFullyCovered(note.decorations, action.mode, sB, eB) then
                        RemoveDecorationRange(note.decorations, action.mode, sB, eB)
                        UI._notes.activeModes[action.mode] = nil
                    else
                        note.decorations[#note.decorations + 1] = { kind = action.mode, startByte = sB, endByte = eB }
                        MergeAdjacentDecorations(note.decorations)
                        UI._notes.activeModes[action.mode] = true
                    end
                    note.updated = time()
                end
                UI:QueueEasyNotesOverlayUpdate()
                -- No text change fires for a decoration-only apply, so the
                -- undo snapshot is cut here.
                Fmt.HistoryRecord(true)
            else
                -- Bold/italic = char-replace to the custom font's bold/italic
                -- codepoints, which render natively (WYSIWYG, no overlay).
                local addFn, remFn, hasFn
                if action.mode == "bold" then addFn, remFn, hasFn = AddBold, RemoveBold, GlyphHasBold
                else addFn, remFn, hasFn = AddItalic, RemoveItalic, GlyphHasItalic end
                local anyLetter, allSet = SelectionAllHave(sel, hasFn)
                local off = anyLetter and allSet
                local transformed = MapSelection(sel, off and remFn or addFn)
                UI._notes.activeModes[action.mode] = (not off) or nil
                text = text:sub(1, lo - 1) .. transformed .. text:sub(hi + 1)
                newHi = lo - 1 + #transformed
                -- Styled glyphs change byte width, so decoration offsets inside
                -- and after the range must remap through a per-gap map (same
                -- technique as the encoding migration). Left to the OnTextChanged
                -- diff, ranges wholly inside the transform collapse and get
                -- pruned -- italicizing coloured text silently ate its colour.
                local remapNote = Fmt.ActiveFormatDoc()
                if remapNote and remapNote.decorations and #remapNote.decorations > 0 then
                    local base = lo - 1
                    local gapMap = {}
                    local oldOff, newOff = base, base
                    for g in iterUtf8(sel) do
                        local rep = (off and remFn or addFn)(g)
                        for k = 1, #g do
                            gapMap[oldOff + k] = newOff + (k < #g and math.min(k, #rep) or #rep)
                        end
                        oldOff = oldOff + #g
                        newOff = newOff + #rep
                    end
                    local delta = newOff - oldOff
                    if delta ~= 0 or next(gapMap) then
                        local decos = remapNote.decorations
                        for d = 1, #decos do
                            local deco = decos[d]
                            local sGap, eGap = deco.startByte - 1, deco.endByte - 1
                            if sGap > oldOff then deco.startByte = sGap + delta + 1
                            elseif gapMap[sGap] then deco.startByte = gapMap[sGap] + 1 end
                            if eGap > oldOff then deco.endByte = eGap + delta + 1
                            elseif gapMap[eGap] then deco.endByte = gapMap[eGap] + 1 end
                        end
                    end
                end
                UI._notes.applyingFormat = true
                -- Replace through the editbox's native selection path: Insert
                -- swaps exactly the highlighted bytes, like typing over a
                -- selection. A full SetText drops the internal selection, and a
                -- same-frame HighlightText after SetText does not stick, so one
                -- frame rendered COLLAPSED -- the caret popped at the highlight
                -- end and the last character flashed. Force the internal
                -- selection to the tracked range first so Insert replaces
                -- exactly those bytes, then re-select the transformed range.
                editor:HighlightText(lo - 1, hi)
                editor:Insert(transformed)
                if (editor:GetText() or "") ~= text then
                    -- The internal selection disagreed with the tracked range;
                    -- fall back to the full reset rather than corrupt the note.
                    editor:SetText(text)
                    editor:SetCursorPosition(newHi)
                end
                editor:HighlightText(newLo - 1, newHi)
                local note = Fmt.ActiveFormatDoc()
                if note then note.body = text; note.updated = time() end
                -- lastEditorText feeds the NOTES editor's OnTextChanged diff;
                -- writing snippet text into it would corrupt the next notes diff.
                if not Fmt.SnippetHostActive() then
                    UI._notes.lastEditorText = text
                    UI:UpdateEasyNotesCaretVisibility()
                end
            end
            local a, b = newLo, newHi
            -- Selection state must be correct SYNCHRONOUSLY: a rapid re-apply
            -- (spamming a format button) captures its range before the deferred
            -- finalize runs, and stale pre-transform offsets against the new text
            -- point at garbage (styled glyphs change byte widths), which moved or
            -- killed the highlight.
            UI._notes.selAnchor = a - 1
            UI._notes.curSelection = { lo = a, hi = b }
            UI._notes.lastSelection = { lo = a, hi = b, ts = GetTime and GetTime() or 0 }
            -- Only the newest pending finalize may touch the editor: earlier ones
            -- from the same burst would re-highlight ranges that no longer exist.
            UI._notes.fmtToken = (UI._notes.fmtToken or 0) + 1
            local myToken = UI._notes.fmtToken
            local finalize = function()
                if UI._notes.fmtToken ~= myToken then return end
                editor:SetFocus()
                editor:SetCursorPosition(b)
                editor:HighlightText(a - 1, b)
                UI._notes.selAnchor = a - 1
                UI._notes.curSelection = { lo = a, hi = b }
                UI._notes.applyingFormat = nil
                UI:QueueEasyNotesOverlayUpdate()
                UI:RefreshFormatButtonStates()
                if not Fmt.SnippetHostActive() then UI:UpdateEasyNotesCaretVisibility() end
            end
            if Utils.SafeAfter then Utils.SafeAfter(0, finalize) else finalize() end
        else
            -- No selection: toggle typing intent, word-processor style. Newly
            -- typed characters receive the format -- OnChar consumes bold/italic
            -- via ApplyInlineFormat, the OnTextChanged diff extends underline/
            -- strike decorations over inserted bytes.
            UI._notes.activeModes[action.mode] = not UI._notes.activeModes[action.mode] or nil
            UI._notes.keepModesOnNextRefresh = true
            editor:SetFocus()
        end
        UI:RefreshAllEasyNotesToolbarButtons()
        return
    end
end

-- Bold/italic/underline/strike are stored as markdown IN the note text
-- (**bold**, *italic*, __underline__, ~~strike~~), wrapped around the selection
-- here. No decorations and no overlay while editing -- the editbox shows raw
-- markdown, so there is nothing to measure, drift, or double. The styled preview
-- is rendered on blur. Colour stays a decoration (its overlay is a flat single
-- copy that doesn't drift).
function UI:ToggleEasyNotesMarkdown(mode, lo, hi, cursor)
    local frame = UI._notes.frame
    local editor = frame and frame.editor
    if not editor then return end
    local m = MD_MARKERS[mode]
    if not m then return end
    local mlen = #m
    local note = GetSelectedNote()
    -- Operate on the raw markdown source, not editor:GetText(): clicking the
    -- toolbar button can blur the editbox and swap it to the rendered display, and
    -- lo/hi (from curSelection) index the raw markdown, so use that.
    local text = (note and note.body) or editor:GetText() or ""

    if not (lo and hi and hi >= lo) then
        -- No selection: drop an empty pair at the caret and sit between them.
        cursor = cursor or (editor:GetCursorPosition() or #text)
        local newText = text:sub(1, cursor) .. m .. m .. text:sub(cursor + 1)
        editor:SetText(newText)
        if note then note.body = newText; note.updated = time() end
        UI._notes.lastEditorText = newText
        local caret = cursor + mlen
        local place = function()
            if not editor:IsShown() then return end
            editor:SetFocus()
            editor:SetCursorPosition(caret)
        end
        if Utils.SafeAfter then Utils.SafeAfter(0, place) else place() end
        return
    end

    local before = text:sub(1, lo - 1)
    local sel = text:sub(lo, hi)
    local after = text:sub(hi + 1)
    -- Already wrapped in THIS marker? For a single-char marker (italic *), make
    -- sure the neighbour isn't a second one -- that would be bold ** -- so toggling
    -- italic on bold text nests (***x***) instead of eating a bold asterisk.
    local wrapped = before:sub(-mlen) == m and after:sub(1, mlen) == m
    if wrapped and mlen == 1 and (before:sub(-2, -2) == m or after:sub(2, 2) == m) then
        wrapped = false
    end
    local newText, newLo, newHi
    if wrapped then
        newText = before:sub(1, #before - mlen) .. sel .. after:sub(mlen + 1)
        newLo, newHi = lo - mlen, hi - mlen
    else
        newText = before .. m .. sel .. m .. after
        newLo, newHi = lo + mlen, hi + mlen
    end
    editor:SetText(newText)
    if note then note.body = newText; note.updated = time() end
    UI._notes.lastEditorText = newText
    -- Keep the wrapped content selected so formats can stack (bold then italic).
    -- Deferred a frame: doing it synchronously right after a toolbar-button click
    -- drops the selection (the click's own focus handling clears the highlight).
    local a, b = newLo, newHi
    local reselect = function()
        if not editor:IsShown() then return end
        editor:SetFocus()
        editor:SetCursorPosition(b)
        editor:HighlightText(a - 1, b)
        UI._notes.selAnchor = a - 1
        UI._notes.curSelection = { lo = a, hi = b }
        UI:RefreshFormatButtonStates()
    end
    if Utils.SafeAfter then Utils.SafeAfter(0, reselect) else reselect() end
end

-- Apply a colour decoration over [lo, hi] (1-based inclusive) of the note.
-- Colour is a decoration range rendered as a coloured overlay, never a |c escape
-- (editboxes show |c...|r as literal text, which corrupted notes). Split out from
-- the picker's swatchFunc so it can be driven headlessly by the test harness.
function UI:ApplyEasyNotesColorDecoration(note, lo, hi, r, g, b)
    if not (note and lo and hi and hi >= lo) then return end
    note.decorations = note.decorations or {}
    local startByte, endByte = lo, hi + 1
    RemoveDecorationRange(note.decorations, "color", startByte, endByte)
    note.decorations[#note.decorations + 1] = {
        kind = "color", startByte = startByte, endByte = endByte, r = r, g = g, b = b,
    }
    MergeAdjacentDecorations(note.decorations)
    note.updated = time()
    UI:QueueEasyNotesOverlayUpdate()
    -- Non-structural: the picker's swatch callback fires continuously while
    -- dragging the wheel, and the burst window folds those into one undo step.
    Fmt.HistoryRecord()
end

function UI:PromptEasyNotesColor(lo, hi, cursor)
    local editor = Fmt.ActiveFormatEditor()
    if not editor then return end
    NormalizeDB()
    -- Seed from the note context, not the account-wide last pick: a fresh note
    -- types in the default colour, so the picker must open there; inside (or
    -- selecting) coloured text it opens on that colour.
    local seed = UI._notes.typingColor
    if not seed and lo then
        local note = Fmt.ActiveFormatDoc()
        local decos = note and note.decorations
        if decos then
            for i = 1, #decos do
                local d = decos[i]
                if d.kind == "color" and d.startByte <= lo and d.endByte > lo then
                    seed = d
                    break
                end
            end
        end
    end
    local r0, g0, b0
    if seed then
        r0, g0, b0 = seed.r or 1, seed.g or 1, seed.b or 1
    else
        r0, g0, b0 = 0.74, 0.74, 0.78
    end
    if not ColorPickerFrame then return end
    local function readPickerColor()
        local r, g, b
        if ColorPickerFrame.GetColorRGB then
            local ok, rr, gg, bb = pcall(ColorPickerFrame.GetColorRGB, ColorPickerFrame)
            if ok and type(rr) == "number" then r, g, b = rr, gg, bb end
        end
        if not r and ColorPickerFrame.Content and ColorPickerFrame.Content.ColorPicker
           and ColorPickerFrame.Content.ColorPicker.GetColorRGB then
            local ok, rr, gg, bb = pcall(ColorPickerFrame.Content.ColorPicker.GetColorRGB,
                                          ColorPickerFrame.Content.ColorPicker)
            if ok and type(rr) == "number" then r, g, b = rr, gg, bb end
        end
        return r, g, b
    end
    local function applyColor()
        local r, g, b = readPickerColor()
        r = r or r0; g = g or g0; b = b or b0
        EasyNotesDB.lastColor = { r = r, g = g, b = b }
        local btn = UI._notes.colorButton
        if btn and btn.colorBar then btn.colorBar:SetColorTexture(r, g, b, 1) end
        local host = UI._notes.snippetHost
        if host and host.colorButton and host.colorButton.colorBar then
            host.colorButton.colorBar:SetColorTexture(r, g, b, 1)
        end
        UI:ApplyEasyNotesColorDecoration(Fmt.ActiveFormatDoc(), lo, hi, r, g, b)
        editor:SetFocus()
        if lo and hi and hi >= lo then
            -- Keep the coloured range selected so more formats can stack on it.
            editor:SetCursorPosition(hi)
            editor:HighlightText(lo - 1, hi)
            UI._notes.selAnchor = lo - 1
            UI._notes.curSelection = { lo = lo, hi = hi }
        else
            -- No selection: the picked colour becomes the typing colour; the
            -- OnTextChanged diff paints newly typed bytes with it.
            UI._notes.typingColor = { r = r, g = g, b = b }
            UI._notes.activeModes.color = true
            UI._notes.keepModesOnNextRefresh = true
            UI:RefreshAllEasyNotesToolbarButtons()
        end
    end
    local info = {
        hasOpacity = false,
        r = r0, g = g0, b = b0,
        swatchFunc = applyColor,
        cancelFunc = function() editor:SetFocus() end,
    }
    if ColorPickerFrame.SetupColorPickerAndShow then
        ColorPickerFrame:SetupColorPickerAndShow(info)
        if ColorPickerFrame.SetFrameStrata then
            ColorPickerFrame:SetFrameStrata("TOOLTIP")
        end
        if ColorPickerFrame.Raise then ColorPickerFrame:Raise() end
    end
end

function UI:PromptEasyNotesAlias()
    local note = GetSelectedNote()
    if not note then return end
    local frame = UI._notes.frame
    if not frame then return end
    local popup = frame.aliasPopup
    if not popup then
        popup = CreateFrame("Frame", nil, frame)
        popup:SetSize(280, 90)
        popup:SetPoint("CENTER")
        popup:SetFrameLevel(frame:GetFrameLevel() + 20)
        if ns.CreateRoundedRectBorder then
            ns.CreateRoundedRectBorder(popup)
            ns.SetRoundedRectBarHeight(popup, 10)
            ns.SetRoundedRectFill(popup, 0.08, 0.08, 0.09, 1, true)
            ns.SetRoundedRectBorderEdgeShown(popup, false)
        end
        popup.label = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        popup.label:SetPoint("TOP", popup, "TOP", 0, -10)
        popup.label:SetText(L["NOTES_ALIAS_LABEL"])
        popup.shell = CreateFrame("Frame", nil, popup)
        popup.shell:SetPoint("TOPLEFT", popup, "TOPLEFT", 14, -28)
        popup.shell:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -14, -28)
        popup.shell:SetHeight(22)
        if ns.CreateRoundedRectBorder then
            ns.CreateRoundedRectBorder(popup.shell)
            ns.SetRoundedRectBarHeight(popup.shell, 10)
            ns.SetRoundedRectFill(popup.shell, 0.11, 0.11, 0.12, 1, true)
            ns.SetRoundedRectBorderEdgeShown(popup.shell, false)
        end
        popup.edit = CreateFrame("EditBox", nil, popup.shell)
        popup.edit:SetPoint("TOPLEFT", popup.shell, "TOPLEFT", 8, -2)
        popup.edit:SetPoint("BOTTOMRIGHT", popup.shell, "BOTTOMRIGHT", -8, 2)
        popup.edit:SetAutoFocus(true)
        popup.edit:SetFontObject("GameFontHighlightSmall")
        popup.edit:SetTextColor(0.96, 0.96, 0.96, 1)
        popup.edit:SetMaxLetters(32)
        popup.ok = CreateFrame("Button", nil, popup)
        StyleAccentButton(popup.ok, "OK")
        popup.ok:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -14, 10)
        popup.cancel = CreateFrame("Button", nil, popup)
        StyleSubtleButton(popup.cancel, _G.CANCEL, 60, STD_BTN_H)
        popup.cancel:SetPoint("RIGHT", popup.ok, "LEFT", -6, 0)
        local function close() popup:Hide() end
        popup.cancel:SetScript("OnClick", close)
        popup.edit:SetScript("OnEscapePressed", close)
        popup.edit:SetScript("OnEnterPressed", function() popup.ok:Click() end)
        popup.ok:SetScript("OnClick", function()
            local n = GetSelectedNote()
            if not n then close(); return end
            n.alias = strtrim(popup.edit:GetText() or "")
            n.updated = time()
            close()
        end)
        frame.aliasPopup = popup
    end
    popup.edit:SetText(note.alias or "")
    popup:Show()
    popup.edit:SetFocus()
end

function Builders.BuildSettingsRow(panel, labelText, yOff)
    local row = CreateFrame("Frame", nil, panel)
    row:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, yOff)
    row:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -14, yOff)
    row:SetHeight(22)

    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.label:SetText(labelText)
    row.label:SetTextColor(0.86, 0.86, 0.88, 1)

    row.plus = CreateFrame("Button", nil, row)
    StyleSubtleButton(row.plus, "+", STD_BTN_W, STD_BTN_H)
    row.plus:SetPoint("RIGHT", row, "RIGHT", 0, 0)

    row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.value:SetPoint("RIGHT", row.plus, "LEFT", -6, 0)
    row.value:SetWidth(42)
    row.value:SetJustifyH("CENTER")
    row.value:SetTextColor(0.96, 0.96, 0.96, 1)

    row.minus = CreateFrame("Button", nil, row)
    StyleSubtleButton(row.minus, "-", STD_BTN_W, STD_BTN_H)
    row.minus:SetPoint("RIGHT", row.value, "LEFT", -6, 0)
    return row
end

function Builders.BuildSettingsPanel(frame)
    local panel = CreateFrame("Frame", nil, frame)
    panel:SetSize(250, 172)
    panel:SetPoint("CENTER")
    -- The flyouts' layer, over everything in the window, so its border reads
    -- clear of the window under it.
    panel:SetFrameStrata("FULLSCREEN_DIALOG")
    panel:SetFrameLevel(frame:GetFrameLevel() + 60)
    panel:EnableMouse(true)
    -- EXACTLY the tooltip/menu panel treatment (StyleMenuPanel): themed galaxy
    -- fill with the ring border drawn ON TOP, and automatic restyle on theme
    -- flips via the menu-panel registry.
    if ns.StyleMenuPanel then
        ns.StyleMenuPanel(panel)
        if ns.SetRoundedRectBarHeight then ns.SetRoundedRectBarHeight(panel, 10) end
    elseif ns.CreateRoundedRectBorder then
        ns.CreateRoundedRectBorder(panel)
        ns.SetRoundedRectBarHeight(panel, 10)
        local c = ns.PANEL_CARD_FILL or { 0.08, 0.08, 0.09 }
        ns.SetRoundedRectFill(panel, c[1], c[2], c[3], 1, true)
    end

    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.title:SetPoint("TOP", panel, "TOP", 0, -12)
    panel.title:SetText(_G.SETTINGS)
    panel.title:SetTextColor(0.9, 0.9, 0.92, 1)

    -- Font size lives on the notes toolbar (and Ctrl+scroll); sharing across
    -- characters is the filter menu's job. Neither belongs here.
    panel.scaleRow = Builders.BuildSettingsRow(panel, L["NOTES_WINDOW_SCALE"], -40)
    panel.scaleRow.minus:SetScript("OnClick", function() UI:AdjustEasyNotesUIScale(-UI_SCALE_STEP) end)
    panel.scaleRow.plus:SetScript("OnClick", function() UI:AdjustEasyNotesUIScale(UI_SCALE_STEP) end)

    panel.opacityRow = Builders.BuildSettingsRow(panel, L["NOTES_WINDOW_OPACITY"], -70)
    panel.opacityRow.minus:SetScript("OnClick", function() UI:AdjustEasyNotesOpacity(-OPACITY_STEP) end)
    panel.opacityRow.plus:SetScript("OnClick", function() UI:AdjustEasyNotesOpacity(OPACITY_STEP) end)

    panel.tooltipRow = CreateFrame("Frame", nil, panel)
    panel.tooltipRow:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -100)
    panel.tooltipRow:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -14, -100)
    panel.tooltipRow:SetHeight(22)
    panel.tooltipRow.label = panel.tooltipRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.tooltipRow.label:SetPoint("LEFT", panel.tooltipRow, "LEFT", 2, 0)
    panel.tooltipRow.label:SetText(L["NOTES_TOOLTIP_COLOR"])
    panel.tooltipRow.label:SetTextColor(0.86, 0.86, 0.88, 1)
    local swatch = CreateFrame("Button", nil, panel.tooltipRow)
    StyleSubtleButton(swatch, "", 54, STD_BTN_H)
    swatch:SetPoint("RIGHT", panel.tooltipRow, "RIGHT", 0, 0)
    swatch.color = swatch:CreateTexture(nil, "OVERLAY")
    swatch.color:SetPoint("TOPLEFT", swatch, "TOPLEFT", 5, -5)
    swatch.color:SetPoint("BOTTOMRIGHT", swatch, "BOTTOMRIGHT", -5, 5)
    panel.tooltipRow.swatch = swatch
    swatch:SetScript("OnClick", function()
        if not (ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow) then return end
        local c0 = UI:GetEasyNotesTooltipColor()
        local function apply()
            local r, g, b = ColorPickerFrame:GetColorRGB()
            if type(r) ~= "number" then return end
            NormalizeDB().tooltipColor = { r = r, g = g, b = b }
            UI:RefreshEasyNotesSettings()
        end
        ColorPickerFrame:SetupColorPickerAndShow({
            hasOpacity = false, r = c0.r, g = c0.g, b = c0.b,
            swatchFunc = apply,
            cancelFunc = function()
                NormalizeDB().tooltipColor = { r = c0.r, g = c0.g, b = c0.b }
                UI:RefreshEasyNotesSettings()
            end,
        })
        if ColorPickerFrame.SetFrameStrata then ColorPickerFrame:SetFrameStrata("TOOLTIP") end
        if ColorPickerFrame.Raise then ColorPickerFrame:Raise() end
    end)

    panel.reset = CreateFrame("Button", nil, panel)
    StyleSubtleButton(panel.reset, L["NOTES_RESET_ALL"], 78, STD_BTN_H)
    panel.reset:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 14, 12)
    panel.reset:SetScript("OnClick", function()
        UI:AdjustEasyNotesUIScale(nil, true)
        UI:AdjustEasyNotesFontSize(nil, true)
        UI:AdjustEasyNotesOpacity(nil, true)
        NormalizeDB().tooltipColor = nil
        UI:RefreshEasyNotesSettings()
    end)

    panel.done = CreateFrame("Button", nil, panel)
    StyleAccentButton(panel.done, _G.DONE)
    panel.done:SetSize(60, 22)
    panel.done:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -14, 12)
    panel.done:SetScript("OnClick", function() panel:Hide() end)

    panel:Hide()
    return panel
end

function UI:RefreshEasyNotesSettings()
    local frame = UI._notes.frame
    if not (frame and frame.settingsPanel) then return end
    local panel = frame.settingsPanel
    local db = NormalizeDB()
    local scale = db.uiScale or UI_SCALE_DEFAULT
    local opacity = db.opacity or OPACITY_DEFAULT
    panel.scaleRow.value:SetText(math.floor(scale * 100 + 0.5) .. "%")
    panel.opacityRow.value:SetText(math.floor(opacity * 100 + 0.5) .. "%")
    local c = UI:GetEasyNotesTooltipColor()
    panel.tooltipRow.swatch.color:SetColorTexture(c.r, c.g, c.b, 1)
end

function UI:ToggleEasyNotesSettings()
    local frame = UI._notes.frame
    if not frame then return end
    if not frame.settingsPanel then
        frame.settingsPanel = Builders.BuildSettingsPanel(frame)
    end
    local panel = frame.settingsPanel
    if panel:IsShown() then
        panel:Hide()
    else
        self:RefreshEasyNotesSettings()
        panel:Show()
        panel:Raise()
    end
end

function Builders.MakeFindInput(parent, placeholderText)
    local shell = CreateFrame("Frame", nil, parent)
    shell:SetHeight(22)
    if ns.CreateRoundedRectBorder then
        ns.CreateRoundedRectBorder(shell)
        ns.SetRoundedRectBarHeight(shell, 9)
        ns.SetRoundedRectFill(shell, 0.14, 0.14, 0.16, 1, true)
        ns.SetRoundedRectBorderEdgeShown(shell, false)
    end
    local edit = CreateFrame("EditBox", nil, shell)
    edit:SetPoint("LEFT", shell, "LEFT", 8, 0)
    edit:SetPoint("RIGHT", shell, "RIGHT", -8, 0)
    edit:SetHeight(20)
    edit:SetAutoFocus(false)
    edit:SetFontObject("GameFontHighlightSmall")
    edit:SetTextColor(0.96, 0.96, 0.96, 1)
    edit:SetMaxLetters(200)
    local ph = shell:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ph:SetPoint("LEFT", shell, "LEFT", 8, 0)
    ph:SetText(placeholderText)
    ph:SetTextColor(0.46, 0.46, 0.5, 1)
    edit.placeholder = ph
    edit:SetScript("OnTextChanged", function(self)
        self.placeholder:SetShown((self:GetText() or "") == "")
        if self.onChanged then self.onChanged(self) end
    end)
    shell.edit = edit
    return shell
end

function Builders.BuildEasyNotesFindBar(frame)
    -- the find bar sits just below the note window so it never covers content
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 12, -3)
    bar:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", -12, -3)
    bar:SetHeight(FIND_BAR_H)
    bar:SetFrameLevel(frame:GetFrameLevel() + 12)
    bar:EnableMouse(true)
    if ns.CreateRoundedRectBorder then
        ns.CreateRoundedRectBorder(bar)
        ns.SetRoundedRectBarHeight(bar, 10)
        ns.SetRoundedRectFill(bar, 0.09, 0.09, 0.10, 1, true)
        ns.SetRoundedRectBorderEdgeShown(bar, false)
    end

    local function closeAndFocusEditor()
        UI:CloseEasyNotesFindBar()
        local f = UI._notes.frame
        if f and f.editor then f.editor:SetFocus() end
    end

    bar.close = CreateFrame("Button", nil, bar)
    StyleSubtleButton(bar.close, "x", STD_BTN_W, STD_BTN_H)
    bar.close:SetPoint("TOPRIGHT", bar, "TOPRIGHT", -6, -6)
    bar.close:SetScript("OnClick", closeAndFocusEditor)

    bar.nextBtn = CreateFrame("Button", nil, bar)
    StyleSubtleButton(bar.nextBtn, "", STD_BTN_W, STD_BTN_H)
    if bar.nextBtn.text then bar.nextBtn.text:Hide() end
    bar.nextBtn:SetPoint("RIGHT", bar.close, "LEFT", -3, 0)
    do
        local t = bar.nextBtn:CreateTexture(nil, "OVERLAY")
        t:SetSize(8, 8)
        t:SetPoint("CENTER")
        t:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
        t:SetDesaturated(true)
        t:SetVertexColor(0.95, 0.95, 0.97, 1)
    end
    bar.nextBtn:SetScript("OnClick", function() UI:EasyNotesFindStep(1) end)

    bar.prevBtn = CreateFrame("Button", nil, bar)
    StyleSubtleButton(bar.prevBtn, "", STD_BTN_W, STD_BTN_H)
    if bar.prevBtn.text then bar.prevBtn.text:Hide() end
    bar.prevBtn:SetPoint("RIGHT", bar.nextBtn, "LEFT", -3, 0)
    do
        local t = bar.prevBtn:CreateTexture(nil, "OVERLAY")
        t:SetSize(8, 8)
        t:SetPoint("CENTER")
        t:SetTexture("Interface\\Buttons\\Arrow-Up-Up")
        t:SetDesaturated(true)
        t:SetVertexColor(0.95, 0.95, 0.97, 1)
    end
    bar.prevBtn:SetScript("OnClick", function() UI:EasyNotesFindStep(-1) end)

    bar.countText = bar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    bar.countText:SetPoint("RIGHT", bar.prevBtn, "LEFT", -6, 0)
    bar.countText:SetWidth(46)
    bar.countText:SetJustifyH("RIGHT")
    bar.countText:SetTextColor(0.6, 0.6, 0.64, 1)

    bar.findShell = Builders.MakeFindInput(bar, L["NOTES_FIND"])
    bar.findShell:SetPoint("TOPLEFT", bar, "TOPLEFT", 8, -6)
    bar.findShell:SetPoint("RIGHT", bar.countText, "LEFT", -6, 0)
    bar.findShell.edit.onChanged = function() UI:RefreshEasyNotesFind() end
    bar.findShell.edit:SetScript("OnEscapePressed", closeAndFocusEditor)
    bar.findShell.edit:SetScript("OnEnterPressed", function()
        UI:EasyNotesFindStep((IsShiftKeyDown and IsShiftKeyDown()) and -1 or 1)
    end)

    bar.allBtn = CreateFrame("Button", nil, bar)
    StyleSubtleButton(bar.allBtn, _G.ALL, 36, STD_BTN_H)
    bar.allBtn:SetPoint("TOPRIGHT", bar, "TOPRIGHT", -6, -32)
    bar.allBtn:SetScript("OnClick", function() UI:EasyNotesReplaceAll() end)

    bar.replaceBtn = CreateFrame("Button", nil, bar)
    StyleSubtleButton(bar.replaceBtn, L["NOTES_REPLACE"], 58, STD_BTN_H)
    bar.replaceBtn:SetPoint("RIGHT", bar.allBtn, "LEFT", -4, 0)
    bar.replaceBtn:SetScript("OnClick", function() UI:EasyNotesReplaceCurrent() end)

    bar.replaceShell = Builders.MakeFindInput(bar, L["NOTES_REPLACE_WITH"])
    bar.replaceShell:SetPoint("TOPLEFT", bar, "TOPLEFT", 8, -32)
    bar.replaceShell:SetPoint("RIGHT", bar.replaceBtn, "LEFT", -6, 0)
    bar.replaceShell.edit:SetScript("OnEscapePressed", closeAndFocusEditor)
    bar.replaceShell.edit:SetScript("OnEnterPressed", function()
        UI:EasyNotesReplaceCurrent()
    end)

    bar:Hide()
    return bar
end

function UI:ToggleEasyNotesFindBar()
    local frame = UI._notes.frame
    if not (frame and frame.editorScroll and frame.editorScroll:IsShown()) then return end
    if not frame.findBar then frame.findBar = Builders.BuildEasyNotesFindBar(frame) end
    if frame.findBar:IsShown() then
        frame.findBar.findShell.edit:SetFocus()
        frame.findBar.findShell.edit:HighlightText()
    else
        self:OpenEasyNotesFindBar()
    end
end

-- The editor top reserves space for the attach bar and the find bar only when
-- each is actually present. It always reserved the attach height, which left a
-- dead gap above the text on notes with no tags -- clicking it did nothing
-- because it is the (empty) attach bar, not the editor.
function UI:UpdateEasyNotesEditorTop()
    local frame = UI._notes.frame
    if not (frame and frame.editorScroll) then return end
    local top = HEADER_H + (EDITOR_TOP - ATTACH_H)          -- base gap below the divider
    if UI._notes.attachHasContent then top = top + (UI._notes.attachH or ATTACH_H) end
    if UI._notes.findBarShown then top = top + FIND_BAR_H end
    frame.editorScroll:ClearAllPoints()
    frame.editorScroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -top)
    frame.editorScroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, FOOTER_H + 4)
end

function UI:OpenEasyNotesFindBar()
    local frame = UI._notes.frame
    if not (frame and frame.findBar) then return end
    -- Reserving the find-bar space resizes the editor scroll frame, which snaps
    -- its scroll to the bottom; capture the reader's position and restore it.
    local savedScroll = frame.editorScroll and frame.editorScroll:GetVerticalScroll() or 0
    frame.findBar:Show()
    UI._notes.findBarShown = true
    UI:UpdateEasyNotesEditorTop()
    local fe = frame.findBar.findShell.edit
    fe:SetFocus()
    fe:HighlightText()
    self:RefreshEasyNotesFind()
    if frame.editorScroll and Utils.SafeAfter then
        Utils.SafeAfter(0, function()
            if frame.editorScroll and UI._notes.findBarShown then
                local maxScroll = frame.editorScroll:GetVerticalScrollRange() or savedScroll
                frame.editorScroll:SetVerticalScroll(mmin(savedScroll, maxScroll))
            end
        end)
    end
end

function UI:CloseEasyNotesFindBar()
    local frame = UI._notes.frame
    if not (frame and frame.findBar) then return end
    frame.findBar:Hide()
    UI._notes.findBarShown = nil
    UI:UpdateEasyNotesEditorTop()
    if frame.editor then frame.editor:HighlightText(0, 0) end
    UI._notes.findMatches = nil
    UI._notes.findIndex = 0
end

function UI:UpdateEasyNotesFindCounter()
    local frame = UI._notes.frame
    if not (frame and frame.findBar) then return end
    local matches = UI._notes.findMatches
    local cnt = matches and #matches or 0
    local txt
    if cnt == 0 then
        local q = frame.findBar.findShell.edit:GetText() or ""
        txt = (q == "") and "" or "0/0"
    else
        txt = (UI._notes.findIndex or 1) .. "/" .. cnt
    end
    frame.findBar.countText:SetText(txt)
end

function UI:ScrollEasyNotesEditorToByte(rawByte)
    local frame = UI._notes.frame
    if not (frame and frame.editor and frame.editorScroll) then return end
    local editor = frame.editor
    local text = editor:GetText() or ""
    local positions = LayoutCharacters(text, editor, editor:GetWidth() or 1)
    local lineYs = MeasureLineYMap(text, editor, positions)
    local line = 1
    for idx = 1, #positions do
        local p = positions[idx]
        if p.byteStart and p.byteStart > rawByte then break end
        line = p.line or line
    end
    local y = lineYs[line] or 0
    local scroll = frame.editorScroll
    local viewH = scroll:GetHeight() or 0
    local maxScroll = scroll:GetVerticalScrollRange() or 0
    local target = y - viewH * 0.4
    if target < 0 then target = 0 end
    if target > maxScroll then target = maxScroll end
    scroll:SetVerticalScroll(target)
end

function UI:JumpToEasyNotesMatch(i)
    local matches = UI._notes.findMatches
    local m = matches and matches[i]
    local frame = UI._notes.frame
    if not (m and frame and frame.editor) then return end
    UI._notes.findIndex = i
    frame.editor:HighlightText(m.lo - 1, m.hi)
    self:ScrollEasyNotesEditorToByte(m.lo)
    self:UpdateEasyNotesFindCounter()
end

function UI:RefreshEasyNotesFind(preferByte)
    local frame = UI._notes.frame
    if not (frame and frame.findBar and frame.findBar:IsShown()) then return end
    local query = frame.findBar.findShell.edit:GetText() or ""
    local matches = FindNoteMatches(frame.editor:GetText() or "", query)
    UI._notes.findMatches = matches
    local idx = 0
    if #matches > 0 then
        idx = 1
        if preferByte then
            for j = 1, #matches do
                if matches[j].lo >= preferByte then idx = j break end
            end
        end
    end
    UI._notes.findIndex = idx
    self:UpdateEasyNotesFindCounter()
    if idx > 0 then self:JumpToEasyNotesMatch(idx) end
end

function UI:EasyNotesFindStep(dir)
    local matches = UI._notes.findMatches
    if not matches or #matches == 0 then
        self:RefreshEasyNotesFind()
        return
    end
    local idx = (UI._notes.findIndex or 0) + dir
    if idx < 1 then idx = #matches end
    if idx > #matches then idx = 1 end
    self:JumpToEasyNotesMatch(idx)
end

function UI:EasyNotesReplaceCurrent()
    local frame = UI._notes.frame
    if not (frame and frame.findBar and frame.editor) then return end
    local matches = UI._notes.findMatches
    local m = matches and matches[UI._notes.findIndex or 0]
    if not m then
        self:EasyNotesFindStep(1)
        return
    end
    local raw = frame.editor:GetText() or ""
    if m.hi > #raw then
        self:RefreshEasyNotesFind()
        return
    end
    local repl = frame.findBar.replaceShell.edit:GetText() or ""
    frame.editor:SetText(raw:sub(1, m.lo - 1) .. repl .. raw:sub(m.hi + 1))
    self:RefreshEasyNotesFind(m.lo + #repl)
end

function UI:EasyNotesReplaceAll()
    local frame = UI._notes.frame
    if not (frame and frame.findBar and frame.editor) then return end
    local query = frame.findBar.findShell.edit:GetText() or ""
    if query == "" then return end
    local raw = frame.editor:GetText() or ""
    local matches = FindNoteMatches(raw, query)
    if #matches == 0 then return end
    local repl = frame.findBar.replaceShell.edit:GetText() or ""
    for j = #matches, 1, -1 do
        local m = matches[j]
        raw = raw:sub(1, m.lo - 1) .. repl .. raw:sub(m.hi + 1)
    end
    frame.editor:SetText(raw)
    self:RefreshEasyNotesFind()
end

function Builders.BuildEasyNotesHeaderPanel(frame)
    local panel = CreateFrame("Frame", nil, frame)
    panel:SetPoint("TOPRIGHT", frame, "TOPLEFT", 3, 0)
    panel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", 3, 0)
    panel:SetWidth(HEADER_PANEL_W)
    panel:EnableMouse(true)
    if ns.CreateRoundedRectBorder then
        ns.CreateRoundedRectBorder(panel)
        ns.SetRoundedRectBarHeight(panel, 14)
        ns.SetRoundedRectBorderEdgeShown(panel, false)
        if ns.Results.ApplySearchWindowFill then
            ns.Results:ApplySearchWindowFill(panel)
            if ns.RegisterThemeCallback then
                ns.RegisterThemeCallback(function() ns.Results:ApplySearchWindowFill(panel) end)
            end
        else
            local c = ns.SEARCH_WINDOW_FILL_COLOR or { 0.052, 0.052, 0.060 }
            ns.SetRoundedRectBorderFillColor(panel, c[1], c[2], c[3], 1)
        end
        ns.SetRoundedRectBorderColor(panel, 0.30, 0.30, 0.33, 0.6, true)
    end
    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    panel.title:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -12)
    panel.title:SetText(L["NOTES_HEADERS"])
    panel.sep = panel:CreateTexture(nil, "OVERLAY")
    panel.sep:SetColorTexture(0.30, 0.30, 0.33, 0.7)
    panel.sep:SetWidth(1)
    panel.sep:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -8)
    panel.sep:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 8)
    panel.rows = {}
    panel:Hide()
    return panel
end

function UI:GetEasyNotesHeaderRow(index)
    local frame = UI._notes.frame
    if not (frame and frame.headerPanel) then return nil end
    local pool = frame.headerPanel.rows
    local row = pool[index]
    if row then return row end
    row = CreateFrame("Button", nil, frame.headerPanel)
    row:SetHeight(20)
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.label:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    if row.label.SetMaxLines then row.label:SetMaxLines(1) end
    row:SetScript("OnEnter", function(self) self.label:SetTextColor(1, 1, 1, 1) end)
    row:SetScript("OnLeave", function(self) self.label:SetTextColor(0.78, 0.78, 0.82, 1) end)
    row:SetScript("OnClick", function(self)
        if self.byteStart then UI:JumpToEasyNotesHeader(self.byteStart) end
    end)
    pool[index] = row
    return row
end

function UI:JumpToEasyNotesHeader(byteStart)
    local frame = UI._notes.frame
    if not (frame and frame.editor) then return end
    self:ScrollEasyNotesEditorToByte(byteStart)
    frame.editor:SetCursorPosition(math.max(0, byteStart - 1))
    frame.editor:SetFocus()
end

function UI:RefreshEasyNotesHeaderPanel()
    local frame = UI._notes.frame
    if not (frame and frame.headerPanel and frame.editor) then return end
    local headers = GetNoteHeaders(frame.editor:GetText() or "")
    local pool = frame.headerPanel.rows
    local y = -34
    for i = 1, #headers do
        local h = headers[i]
        local row = self:GetEasyNotesHeaderRow(i)
        if not row then break end
        row.byteStart = h.byteStart
        local indent = 10 + (h.level - 1) * 12
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame.headerPanel, "TOPLEFT", indent, y)
        row:SetPoint("TOPRIGHT", frame.headerPanel, "TOPRIGHT", -10, y)
        row.label:SetText(h.title)
        if h.level == 1 then
            row.label:SetTextColor(0.95, 0.95, 0.97, 1)
        else
            row.label:SetTextColor(0.78, 0.78, 0.82, 1)
        end
        row:Show()
        y = y - 22
    end
    for i = #headers + 1, #pool do pool[i]:Hide() end
end

function UI:ToggleEasyNotesHeaderPanel()
    local frame = UI._notes.frame
    if not frame then return end
    if not frame.headerPanel then
        frame.headerPanel = Builders.BuildEasyNotesHeaderPanel(frame)
    end
    if frame.headerPanel:IsShown() then
        frame.headerPanel:Hide()
    else
        self:RefreshEasyNotesHeaderPanel()
        frame.headerPanel:Show()
    end
end

function UI:RefreshEasyNotesHeaderNav()
    local frame = UI._notes.frame
    if not (frame and frame.headerNavButton) then return end
    local hasHeaders = frame.editor
        and #GetNoteHeaders(frame.editor:GetText() or "") > 0
    -- Folded into the overflow menu; never resurrect it as a header button.
    frame.headerNavButton:Hide()
    if not hasHeaders then
        if frame.headerPanel then frame.headerPanel:Hide() end
    elseif frame.headerPanel and frame.headerPanel:IsShown() then
        self:RefreshEasyNotesHeaderPanel()
    end
end

-- Byte range of each |H...|h<visible>|h hyperlink's visible text.
local function GetNoteLinkSpans(text)
    local spans = {}
    local pos = 1
    while true do
        local hStart = sfind(text, "|H", pos, true)
        if not hStart then break end
        local hMid = sfind(text, "|h", hStart + 2, true)
        if not hMid then break end
        local hEnd = sfind(text, "|h", hMid + 2, true)
        if not hEnd then break end
        spans[#spans + 1] = {
            payload = text:sub(hStart + 2, hMid - 1),
            lo = hMid + 2,
            hi = hEnd - 1,
        }
        pos = hEnd + 2
    end
    return spans
end

local function EasyNotesLinkBtnEnter(self)
    if GameTooltip and self.payload then
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        if pcall(GameTooltip.SetHyperlink, GameTooltip, self.payload) then
            GameTooltip:Show()
        end
    end
end

local function EasyNotesLinkBtnLeave()
    if GameTooltip then GameTooltip:Hide() end
end

-- Invisible hover frames laid over each item/spell link in the note body.
-- They are children of the editbox (like the decoration textures), so they
-- track the rendered text exactly and scroll with it -- no cursor math.
function UI:UpdateEasyNotesLinkButtons()
    local frame = UI._notes.frame
    if not (frame and frame.editor) then return end
    local editor = frame.editor
    UI._notes.linkBtns = UI._notes.linkBtns or {}
    local pool = UI._notes.linkBtns
    local text = editor:GetText() or ""
    local spans = GetNoteLinkSpans(text)
    local used = 0
    if #spans > 0 then
        local positions = LayoutCharacters(text, editor, editor:GetWidth() or 1)
        local lineYs, lineH = MeasureLineYMap(text, editor, positions)
        for s = 1, #spans do
            local span = spans[s]
            local rects = ComputeDecorationRects(positions,
                { startByte = span.lo, endByte = span.hi + 1 })
            for r = 1, #rects do
                used = used + 1
                local btn = pool[used]
                if not btn then
                    btn = CreateFrame("Frame", nil, editor)
                    btn:EnableMouse(true)
                    if btn.SetMouseClickEnabled then btn:SetMouseClickEnabled(false) end
                    btn:SetScript("OnEnter", EasyNotesLinkBtnEnter)
                    btn:SetScript("OnLeave", EasyNotesLinkBtnLeave)
                    pool[used] = btn
                end
                local rc = rects[r]
                btn.payload = span.payload
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", editor, "TOPLEFT", rc.x1, -(lineYs[rc.line] or 0))
                btn:SetSize(math.max(1, rc.x2 - rc.x1), lineH)
                btn:Show()
            end
        end
    end
    for i = used + 1, #pool do pool[i]:Hide() end
end

function UI:UpdateEasyNotesEditorScrollBar()
    local frame = UI._notes.frame
    if not (frame and frame.editorScrollBar and frame.editor and frame.editorScroll) then
        return
    end
    local contentH = frame.editor:GetHeight() or 0
    local viewH = frame.editorScroll:GetHeight() or 0
    local hasScroll = contentH > viewH + 1
    frame.editorScrollBar:SetShown(hasScroll)
    if hasScroll then frame.editorScrollBar:UpdateThumb(contentH, viewH) end
end

function UI:ToggleEasyNotesPalette()
    local frame = UI._notes.frame
    if not frame then return end
    if frame.palette:IsShown() then
        self:HideEasyNotesPalette()
    else
        self:ShowEasyNotesPalette()
    end
end

function UI:SetEasyNotesEditorViewShown(shown)
    local frame = UI._notes.frame
    if not frame then return end
    if frame.editorScroll then frame.editorScroll:SetShown(shown) end
    if frame.toolbar then frame.toolbar:SetShown(shown and UI._notes.toolbarShown == true) end
    UI:UpdateEasyNotesToolbarSeam()
    if frame.attachBar then frame.attachBar:SetShown(shown) end
    if frame.footer then frame.footer:SetShown(shown) end
    if frame.charCounter then
        frame.charCounter:SetShown(shown and not UI._notes.toolbarShown)
    end
    if frame.formatButton and frame.formatButton.text then
        frame.formatButton.text:SetText(UI._notes.toolbarShown and "x" or "T")
    end
    if frame.titleButton then frame.titleButton:SetShown(shown) end
    if frame.overflowButton then frame.overflowButton:SetShown(shown) end
    -- Folded into the overflow menu; never shown as standalone header buttons.
    if frame.findButton then frame.findButton:Hide() end
    if frame.autoResizeButton then frame.autoResizeButton:Hide() end
    if frame.headerNavButton then frame.headerNavButton:Hide() end
    -- The trash button is a standalone header control again (left of X), in
    -- BOTH views: it acts on the list selection, or the open note in the
    -- editor view, and grays out when there is neither.
    if frame.deleteButton then
        frame.deleteButton:Show()
        UI:UpdateEasyNotesDeleteButton()
    end
    -- First left slot is contextual: Home (back to the note list) while a note is
    -- open, New note on the list itself. New note also lives in the more menu.
    if frame.paletteButton then frame.paletteButton:SetShown(shown) end
    if frame.newButton then frame.newButton:SetShown(not shown) end
    if frame.settingsButton then frame.settingsButton:Show() end
    if frame.homeTitle then frame.homeTitle:SetShown(not shown) end
    if shown and frame.settingsPanel then frame.settingsPanel:Hide() end
    if not shown and frame.findBar and frame.findBar:IsShown() then
        self:CloseEasyNotesFindBar()
    end
    if not shown then
        if frame.headerNavButton then frame.headerNavButton:Hide() end
        if frame.headerPanel then frame.headerPanel:Hide() end
        if frame.appliesInSearch then frame.appliesInSearch:Hide() end
    end
    self:RefreshEasyNotesDragHandles()
    if shown then self:RefreshEasyNotesAttachBar() end
    if notesNS.ChecklistView then notesNS.ChecklistView.SetAllowed(shown) end
end

local function ApplyEasyNotesWindowSize(frame, dims)
    if not (frame and dims) then return end
    frame:SetSize(mmax(MIN_WIDTH, dims.w or DEFAULT_WIDTH),
                  mmax(MIN_HEIGHT, dims.h or DEFAULT_HEIGHT))
end

function UI:ShowEasyNotesPalette()
    local frame = UI._notes.frame
    if not frame then return end
    ApplyEasyNotesWindowSize(frame, NormalizeDB().window)
    frame.palette:Show()
    frame.paletteSearch:SetText("")
    UI._notes.paletteShown = true
    UI._notes.contextFilterUserSet = false
    local sel = UI._notes.paletteSelection
    for k in pairs(sel) do sel[k] = nil end
    self:SetEasyNotesEditorViewShown(false)
    if frame.paletteList then frame.paletteList:SetVerticalScroll(0) end
    self:RefreshEasyNotesPalette()
    self:UpdateEasyNotesDeleteButton()
end

function UI:HideEasyNotesPalette()
    if UI._notes.renameRow then self:CommitEasyNotesRowRename() end
    UI._notes.paletteShown = false
    local frame = UI._notes.frame
    if frame and frame.palette then
        frame.palette:Hide()
        frame.paletteSearch:ClearFocus()
        ApplyEasyNotesWindowSize(frame, NormalizeDB().editorWindow)
        self:SetEasyNotesEditorViewShown(true)
        self:UpdateEasyNotesAutoResize()
    end
    self:UpdateEasyNotesDeleteButton()
end

local function PaintPaletteRow(row)
    if not row.noteID then return end
    local over = row:IsMouseOver() and true or false
    local sel = UI._notes.paletteSelection
    local selected = sel and sel[row.noteID] and true or false
    if ns.SetRoundedRectFill then
        -- Rows sit at the same fill as the header buttons (BTN_FILL_NORMAL), a
        -- step lighter on hover, and the theme control accent when selected, so
        -- the list reads as one surface with the buttons instead of black slabs.
        local c
        if selected then
            c = ns.CONTROL_ACCENT or { 0.17, 0.48, 0.72 }
        elseif over then
            c = ns.BTN_FILL_HOVER or { 0.22, 0.27, 0.34 }
        else
            c = ns.BTN_FILL_NORMAL or { 0.16, 0.19, 0.25 }
        end
        ns.SetRoundedRectFill(row, c[1], c[2], c[3], 1, true)
    end
    -- The second line and the time in the theme's text color, a step
    -- down: the dim gray read badly on the row fills.
    local tr, tg, tb = ns.TooltipTextColor()
    row.subtitle:SetTextColor(tr, tg, tb, 0.75)
    row.timeText:SetTextColor(tr, tg, tb, 0.75)
    if row.actionBar then row.actionBar:SetShown(over) end
    -- Pinned notes show a gold pin even when not hovered, so pinned state is
    -- visible at a glance (the action bar only appears on hover).
    local idx = FindNoteIndex(row.noteID)
    local note = idx and NotesStore()[idx]
    if not row.pinnedMark and row.pinButton then
        -- Sits exactly on top of the hover pin button so switching between them on
        -- hover is invisible: same icon, same size, same spot. On hover the trash +
        -- backdrop appear to the LEFT; the pin stays put.
        row.pinnedMark = row:CreateTexture(nil, "OVERLAY")
        row.pinnedMark:SetSize(10, 10)
        row.pinnedMark:SetPoint("CENTER", row.pinButton, "CENTER", 0, 0)
        row.pinnedMark:SetTexture("Interface\\AddOns\\EasyFind_Notes\\Images\\pin.tga")
        row.pinnedMark:SetVertexColor(0.98, 0.82, 0.32, 1)
    end
    if row.pinnedMark then
        row.pinnedMark:SetShown((note and note.pinned) and not over or false)
    end
end

-- The header trash button mirrors the selection: grayed and unclickable with
-- nothing to act on, normal when list rows are selected (or a note is open in
-- the editor view).
function UI:UpdateEasyNotesDeleteButton()
    local frame = UI._notes.frame
    local btn = frame and frame.deleteButton
    if not btn then return end
    local enabled = next(UI._notes.paletteSelection) ~= nil
        or (not UI._notes.paletteShown and UI._notes.selectedID ~= nil)
    btn:SetEnabled(enabled)
    if btn.icon then
        if enabled then
            btn.icon:SetVertexColor(0.95, 0.95, 0.97, 1)
            btn.icon:SetAlpha(1)
        else
            btn.icon:SetVertexColor(0.55, 0.55, 0.58, 1)
            btn.icon:SetAlpha(0.55)
        end
    end
end

function UI:RepaintEasyNotesPaletteRows()
    local rows = UI._notes.paletteRows
    for i = 1, #rows do
        local row = rows[i]
        if row:IsShown() then PaintPaletteRow(row) end
    end
    self:UpdateEasyNotesDeleteButton()
end

function UI:EnsureEasyNotesPaletteRow(index)
    local frame = UI._notes.frame
    if not frame then return nil end
    local rows = UI._notes.paletteRows
    local row = rows[index]
    if row then return row end
    row = CreateFrame("Button", nil, frame.paletteListChild)
    rows[index] = row
    if ns.CreateRoundedRectBorder then
        ns.CreateRoundedRectBorder(row)
        ns.SetRoundedRectBarHeight(row, 10)
        ns.SetRoundedRectBorderBgAlpha(row, 1)
        ns.SetRoundedRectBorderEdgeShown(row, false)
    end

    row.timeText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.timeText:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -10, 7)
    row.timeText:SetJustifyH("RIGHT")
    row.timeText._efOwnColor = true
    -- A theme change repaints the row by its state (hover, selected).
    row.RefreshVisual = PaintPaletteRow

    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 12, -7)
    row.title:SetPoint("RIGHT", row, "RIGHT", -12, 0)
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)
    if row.title.SetMaxLines then row.title:SetMaxLines(1) end

    row.titleEdit = CreateFrame("EditBox", nil, row)
    row.titleEdit:SetPoint("LEFT", row.title, "LEFT", 0, 0)
    row.titleEdit:SetPoint("RIGHT", row.title, "RIGHT", 0, 0)
    row.titleEdit:SetHeight(16)
    row.titleEdit:SetFontObject("GameFontHighlightSmall")
    row.titleEdit:SetTextColor(1, 1, 1, 1)
    row.titleEdit:SetAutoFocus(false)
    row.titleEdit:SetMaxLetters(120)
    if row.titleEdit.SetTextInsets then row.titleEdit:SetTextInsets(0, 0, 0, 0) end
    row.titleEdit:Hide()
    row.titleEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    row.titleEdit:SetScript("OnEscapePressed", function(self)
        self._cancelRename = true
        self:ClearFocus()
    end)
    row.titleEdit:SetScript("OnEditFocusLost", function(self)
        if self._cancelRename then
            self._cancelRename = nil
            UI:CancelEasyNotesRowRename()
        elseif UI._notes.renameRow and UI._notes.renameRow.titleEdit == self then
            UI:CommitEasyNotesRowRename()
            UI:RefreshEasyNotesPalette()
        end
    end)

    row.subtitle = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.subtitle._efOwnColor = true
    row.subtitle:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 12, 7)
    row.subtitle:SetPoint("RIGHT", row.timeText, "LEFT", -8, 0)
    row.subtitle:SetJustifyH("LEFT")
    row.subtitle:SetWordWrap(false)
    if row.subtitle.SetMaxLines then row.subtitle:SetMaxLines(1) end

    -- Discord-style hover action bar (top-right): own elevated backdrop.
    -- Pin only (delete lives in the header trash button).
    row.actionBar = CreateFrame("Frame", nil, row)
    row.actionBar:SetSize(26, 22)
    row.actionBar:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -3)
    row.actionBar:SetFrameLevel(row:GetFrameLevel() + 4)
    row.actionBar:EnableMouse(true)
    if ns.CreateRoundedRectBorder then
        ns.CreateRoundedRectBorder(row.actionBar)
        ns.SetRoundedRectBarHeight(row.actionBar, 10)
        local c = ns.BTN_FILL_NORMAL or { 0.19, 0.19, 0.21 }
        ns.SetRoundedRectFill(row.actionBar, c[1], c[2], c[3], 1, true)
        ns.SetRoundedRectBorderEdgeShown(row.actionBar, false)
    end
    row.actionBar:Hide()
    local function keepShown() PaintPaletteRow(row) end
    row.actionBar:SetScript("OnEnter", keepShown)
    row.actionBar:SetScript("OnLeave", keepShown)

    -- Pin sits on the RIGHT (exactly where the static pinned-mark shows), trash to
    -- its LEFT. This way the pin never moves between unhover and hover, and someone
    -- reaching for the pin to unpin doesn't land on delete.
    row.pinButton = CreateFrame("Button", nil, row.actionBar)
    row.pinButton:SetSize(18, 18)
    row.pinButton:SetPoint("RIGHT", row.actionBar, "RIGHT", -4, 0)
    do
        local p = row.pinButton
        p.icon = p:CreateTexture(nil, "OVERLAY")
        p.icon:SetTexture("Interface\\AddOns\\EasyFind_Notes\\Images\\pin.tga")
        p.icon:SetSize(10, 10)
        p.icon:SetPoint("CENTER", p, "CENTER", 0, 0)
        p.icon:SetVertexColor(0.98, 0.82, 0.32, 1)
        p:SetScript("OnEnter", function()
            p.icon:SetSize(13, 13)
            keepShown()
        end)
        p:SetScript("OnLeave", function()
            p.icon:SetSize(10, 10)
            keepShown()
        end)
        p:SetScript("OnClick", function()
            if row.noteID then
                TogglePinned(row.noteID)
                UI:RefreshEasyNotesPalette()
            end
        end)
    end

    -- Deleting moved to the header trash button (acts on the selection); the
    -- hover pair keeps only the pin.

    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if not self.noteID then return end
        if button == "RightButton" then
            UI:ShowEasyNotesRowMenu(self)
            return
        end
        local sel = UI._notes.paletteSelection
        if IsShiftKeyDown and IsShiftKeyDown() and UI._notes.paletteSelAnchor then
            -- Shift+click: select the range between the last plain-clicked row
            -- and this one (inclusive), ADDED to the existing selection.
            local rows = UI._notes.paletteRows
            local a, b
            for i = 1, #rows do
                local r = rows[i]
                if r and r:IsShown() then
                    if r.noteID == UI._notes.paletteSelAnchor then a = i end
                    if r.noteID == self.noteID then b = i end
                end
            end
            if a and b then
                if a > b then a, b = b, a end
                for i = a, b do
                    local r = rows[i]
                    if r and r:IsShown() and r.noteID then sel[r.noteID] = true end
                end
            else
                sel[self.noteID] = true
            end
        elseif IsControlKeyDown and IsControlKeyDown() then
            sel[self.noteID] = (not sel[self.noteID]) or nil
            UI._notes.paletteSelAnchor = self.noteID
        else
            -- Single click SELECTS (opening is double-click), so a stray click
            -- can't yank you into a note, and multi-select can build on it.
            for k in next, sel do sel[k] = nil end
            sel[self.noteID] = true
            UI._notes.paletteSelAnchor = self.noteID
        end
        UI:RepaintEasyNotesPaletteRows()
    end)
    row:SetScript("OnDoubleClick", function(self, button)
        if not self.noteID or button ~= "LeftButton" then return end
        UI:SelectEasyNote(self.noteID)
        UI:HideEasyNotesPalette()
    end)
    row:SetScript("OnEnter", function(self) PaintPaletteRow(self) end)
    row:SetScript("OnLeave", function(self) PaintPaletteRow(self) end)
    return row
end

function UI:ShowEasyNotesRowMenu(row)
    if not (row and row.noteID) then return end
    if not Utils.ShowCursorMenu then
        self:BeginEasyNotesRowRename(row)
        return
    end
    local rows = {
        { text = L["NOTES_RENAME"], onClick = function() UI:BeginEasyNotesRowRename(row) end },
    }
    -- The note's words into the messenger, plain, when that companion is in.
    if not (ns.IsCompanionLoadable and not ns.IsCompanionLoadable("EasyFind_Chat")) then
        rows[#rows + 1] = { text = L["NOTES_SEND_MESSAGE"], onClick = function()
            local idx = FindNoteIndex(row.noteID)
            local note = idx and NotesStore()[idx] or nil
            if not (note and ns.RequestChat and ns.RequestChat() and ns.Chat.ComposeWith) then return end
            ns.Chat:ComposeWith(nil, strtrim(StripColorEscapes(MapSelection(note.body or "", GlyphPlain))))
        end }
    end
    rows[#rows + 1] = { isSeparator = true }
    -- The row's note, or the whole selection when the row is part of one.
    rows[#rows + 1] = { text = L["NOTES_DELETE"], icon = "Interface\\AddOns\\EasyFind_Notes\\Images\\trash", inlineIcon = true,
      onClick = function()
          local sel = UI._notes.paletteSelection
          local ids = {}
          if sel and sel[row.noteID] then
              for id in pairs(sel) do ids[#ids + 1] = id end
          end
          ConfirmDeleteNote(#ids > 1 and ids or row.noteID)
      end }
    UI:ShowEasyNotesMenu("EasyNotesRowMenu", rows, {})
end

function UI:BeginEasyNotesRowRename(row)
    if not (row and row.noteID and row.titleEdit) then return end
    if UI._notes.renameRow and UI._notes.renameRow ~= row then
        self:CommitEasyNotesRowRename()
    end
    local idx = FindNoteIndex(row.noteID)
    local note = idx and NotesStore()[idx] or nil
    if not note then return end
    UI._notes.renameRow = row
    row.titleEdit._cancelRename = nil
    row.titleEdit:SetText(NoteTitle(note))
    row.title:Hide()
    row.titleEdit:Show()
    row.titleEdit:SetFocus()
    row.titleEdit:HighlightText()
end

function UI:CommitEasyNotesRowRename()
    local row = UI._notes.renameRow
    if not row then return end
    UI._notes.renameRow = nil
    local idx = FindNoteIndex(row.noteID)
    local note = idx and NotesStore()[idx] or nil
    if note and row.titleEdit then
        local newName = strtrim(row.titleEdit:GetText() or "")
        note.name = newName
        note.updated = time()
    end
    if row.titleEdit then
        row.titleEdit:ClearFocus()
        row.titleEdit:Hide()
    end
    if row.title then
        if note then row.title:SetText(NoteTitle(note)) end
        row.title:Show()
    end
end

function UI:CancelEasyNotesRowRename()
    local row = UI._notes.renameRow
    if not row then return end
    UI._notes.renameRow = nil
    if row.titleEdit then
        row.titleEdit:ClearFocus()
        row.titleEdit:Hide()
    end
    if row.title then row.title:Show() end
end

local function ContextMatchSort(a, b)
    local pa = a.here and 99 or Ctx.Priority(a)
    local pb = b.here and 99 or Ctx.Priority(b)
    if pa ~= pb then return pa > pb end
    return a.label < b.label
end

-- Notes set to open by themselves: one whose place comes up opens the
-- window on it, when the window is closed (never over a note in use);
-- when its place ends, the window goes again if it still shows it.
function UI:OpenNotesThatApply()
    local any = false
    local store = NotesStore()
    for i = 1, #store do
        if store[i].opensItself then any = true break end
    end
    local was, now = UI._notes.opensApplied or {}, {}
    UI._notes.opensApplied = now
    if any then
        local _, set = Ctx.Active()
        local visible = SortedNotes("")
        for i = 1, #visible do
            local n = visible[i]
            if n.opensItself and Ctx.Applies(n, set) then now[n.id] = true end
        end
    end
    local frame = UI._notes.frame
    local opened = UI._notes.openedFor
    if opened and not now[opened] then
        UI._notes.openedFor = nil
        if frame and frame:IsShown() and UI._notes.selectedID == opened then self:CloseEasyNotes() end
    end
    if frame and frame:IsShown() then return end
    for i = 1, #store do
        local id = store[i].id
        if now[id] and not was[id] then
            frame = self:EnsureEasyNotesFrame()
            if not frame then return end
            NormalizeDB()
            UI._notes.selectedID = id
            UI._notes.openedFor = id
            frame:Show()
            self:HideEasyNotesPalette()
            self:RefreshEasyNotes()
            return
        end
    end
end

-- A new place starts the filter fresh; a new target or group only refreshes.
local PLACE_EVENTS = { ZONE_CHANGED_NEW_AREA = true, PLAYER_ENTERING_WORLD = true }
function UI:OnEasyNotesContextChanged(event)
    self:OpenNotesThatApply()
    if not event or PLACE_EVENTS[event] then UI._notes.contextFilterUserSet = false end
    if UI._notes.paletteShown then
        self:RefreshEasyNotesPalette()
    end
    self:RefreshEasyNotesAttachBar()
end

local function ItemIDFromLink(link)
    if type(link) ~= "string" then return nil end
    local id = link:match("|Hitem:(%d+)")
    return id and tonumber(id) or nil
end

-- The note line in tooltips: the settings panel's pick, else the blue.
function UI:GetEasyNotesTooltipColor()
    local c = NormalizeDB().tooltipColor
    if type(c) == "table" and type(c.r) == "number" then return c end
    return { r = 0.62, g = 0.78, b = 0.95 }
end

local function GetItemNote(itemID)
    if type(itemID) ~= "number" then return nil end
    local store = NormalizeDB().itemNotes
    return store[itemID]
end

function UI:PromptEasyNotesItemNote(itemID, itemName)
    if type(itemID) ~= "number" then return end
    local frame = UI._notes.frame
    if not frame then return end
    local popup = frame.itemNotePopup
    if not popup then
        popup = CreateFrame("Frame", nil, frame)
        popup:SetSize(300, 110)
        popup:SetPoint("CENTER")
        popup:SetFrameLevel(frame:GetFrameLevel() + 20)
        popup:EnableMouse(true)
        if ns.CreateRoundedRectBorder then
            ns.CreateRoundedRectBorder(popup)
            ns.SetRoundedRectBarHeight(popup, 10)
            ns.SetRoundedRectFill(popup, 0.08, 0.08, 0.09, 1, true)
            ns.SetRoundedRectBorderEdgeShown(popup, false)
        end
        popup.label = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        popup.label:SetPoint("TOPLEFT", popup, "TOPLEFT", 14, -10)
        popup.label:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -14, -10)
        popup.label:SetJustifyH("LEFT")
        popup.shell = CreateFrame("Frame", nil, popup)
        popup.shell:SetPoint("TOPLEFT", popup, "TOPLEFT", 14, -28)
        popup.shell:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -14, -28)
        popup.shell:SetHeight(42)
        if ns.CreateRoundedRectBorder then
            ns.CreateRoundedRectBorder(popup.shell)
            ns.SetRoundedRectBarHeight(popup.shell, 10)
            ns.SetRoundedRectFill(popup.shell, 0.11, 0.11, 0.12, 1, true)
            ns.SetRoundedRectBorderEdgeShown(popup.shell, false)
        end
        popup.edit = CreateFrame("EditBox", nil, popup.shell)
        popup.edit:SetPoint("TOPLEFT", popup.shell, "TOPLEFT", 8, -4)
        popup.edit:SetPoint("BOTTOMRIGHT", popup.shell, "BOTTOMRIGHT", -8, 4)
        popup.edit:SetAutoFocus(true)
        popup.edit:SetMultiLine(true)
        popup.edit:SetFontObject("GameFontHighlightSmall")
        popup.edit:SetTextColor(0.96, 0.96, 0.96, 1)
        popup.edit:SetMaxLetters(200)
        popup.ok = CreateFrame("Button", nil, popup)
        StyleAccentButton(popup.ok, "OK")
        popup.ok:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -14, 10)
        popup.cancel = CreateFrame("Button", nil, popup)
        StyleSubtleButton(popup.cancel, _G.CANCEL, 60, STD_BTN_H)
        popup.cancel:SetPoint("RIGHT", popup.ok, "LEFT", -6, 0)
        local function close() popup:Hide() end
        popup.cancel:SetScript("OnClick", close)
        popup.edit:SetScript("OnEscapePressed", close)
        popup.ok:SetScript("OnClick", function()
            local id = popup.itemID
            if type(id) ~= "number" then close(); return end
            local store = NormalizeDB().itemNotes
            local text = strtrim(popup.edit:GetText() or "")
            if text == "" then
                store[id] = nil
            else
                store[id] = { text = text, name = popup.itemName, updated = time() }
            end
            close()
        end)
        frame.itemNotePopup = popup
    end
    popup.itemID = itemID
    popup.itemName = itemName
    popup.label:SetText(Utils.sformat(L["NOTES_NOTE_FOR"], itemName or Utils.sformat(L["NOTES_ITEM_FMT"], itemID)))
    local existing = GetItemNote(itemID)
    popup.edit:SetText(existing and existing.text or "")
    popup:Show()
    popup.edit:SetFocus()
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        local ok, err = pcall(function()
            if not (tooltip and tooltip.AddLine) then return end
            local itemID = data and data.id
            if type(itemID) ~= "number" and tooltip.GetItem then
                local _, itemLink = tooltip:GetItem()
                itemID = ItemIDFromLink(itemLink)
            end
            if type(itemID) ~= "number" then return end
            local note = GetItemNote(itemID)
            if not (note and type(note.text) == "string" and note.text ~= "") then return end
            local c = UI:GetEasyNotesTooltipColor()
            tooltip:AddLine(Utils.sformat(L["NOTES_TOOLTIP_LINE"], note.text), c.r, c.g, c.b, true)
        end)
        if not ok and Utils.DebugPrint then Utils.DebugPrint(err) end
    end)
end

-- "Shows on" tooltip annotations: surface a brief note line on the linked
-- object's tooltip. Independent of the legacy per-item itemNotes store.
local function ShowsOnNotesFor(objType, objID)
    if objID == nil then return nil end
    local notes = NotesStore()
    local out
    for i = 1, #notes do
        local n = notes[i]
        if n and n.showsOn then
            for j = 1, #n.showsOn do
                local s = n.showsOn[j]
                if s.type == objType and s.id == objID then
                    out = out or {}
                    out[#out + 1] = n
                    break
                end
            end
        end
    end
    return out
end

local function AddShowsOnLines(tooltip, objType, objID)
    if not (tooltip and tooltip.AddLine) or EasyFind.db.notesTooltips == false then return end
    local hits = ShowsOnNotesFor(objType, objID)
    if not hits then return end
    for i = 1, #hits do
        local n = hits[i]
        local body = StripColorEscapes(MapSelection((n.body or ""):gsub("\n+", "  "), GlyphPlain))
        if #body > 120 then body = body:sub(1, 120) .. "..." end
        if body == "" then body = NoteTitle(n) end
        local c = UI:GetEasyNotesTooltipColor()
        tooltip:AddLine(Utils.sformat(L["NOTES_TOOLTIP_LINE"], body), c.r, c.g, c.b, true)
    end
end

-- The same lines for another window (the chat's bubbles): whether a unit
-- has a note to show, and its lines on a tooltip.
function notesNS.HasUnitNote(objType, objID)
    return EasyFind.db.notesTooltips ~= false and ShowsOnNotesFor(objType, objID) ~= nil
end

function notesNS.AddUnitNoteLines(tooltip, objType, objID)
    AddShowsOnLines(tooltip, objType, objID)
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        local ok, err = pcall(function()
            local itemID = data and data.id
            if type(itemID) ~= "number" and tooltip and tooltip.GetItem then
                local _, itemLink = tooltip:GetItem()
                itemID = ItemIDFromLink(itemLink)
            end
            AddShowsOnLines(tooltip, "item", itemID)
        end)
        if not ok and Utils.DebugPrint then Utils.DebugPrint(err) end
    end)
    if Enum.TooltipDataType.Spell then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell, function(tooltip, data)
            local ok, err = pcall(function()
                AddShowsOnLines(tooltip, "spell", data and data.id)
            end)
            if not ok and Utils.DebugPrint then Utils.DebugPrint(err) end
        end)
    end
    if Enum.TooltipDataType.Unit then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
            local ok, err = pcall(function()
                local guid = data and data.guid
                if type(guid) ~= "string" or (_G.issecretvalue and _G.issecretvalue(guid)) then return end
                if guid:find("^Player%-") then
                    local _, unit = tooltip:GetUnit()
                    AddShowsOnLines(tooltip, "player", (Ctx.UnitPlayer(unit)))
                    return
                end
                local npcID = tonumber(guid:match("Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
                    or guid:match("Vehicle%-%d+%-%d+%-%d+%-%d+%-(%d+)%-"))
                AddShowsOnLines(tooltip, "npc", npcID)
            end)
            if not ok and Utils.DebugPrint then Utils.DebugPrint(err) end
        end)
    end
end

local MATCH_MODE_LABELS = {
    any = L["NOTES_MATCH_ANY"],
    all = L["NOTES_MATCH_ALL"],
    manual = L["NOTES_MATCH_MANUAL"],
}

local MENU_CHECK_TEX = "Interface\\Buttons\\UI-CheckBox-Check"

-- One themed context menu for the whole note UI (ShowCursorMenu, the same
-- primitive the search bar's menus use), scaled to the note window. Every note
-- menu routes through this instead of Blizzard's MenuUtil default menus.
function UI:ShowEasyNotesMenu(name, rows, opts)
    if not Utils.ShowCursorMenu then return nil end
    opts = opts or {}
    opts.scale = opts.scale or (NormalizeDB().uiScale or UI_SCALE_DEFAULT)
    -- No forced width: menus fit their content (the shared module measures
    -- labels); pass opts.width only as a deliberate minimum.
    if opts.toggleOwner == nil then opts.toggleOwner = opts.anchorFrame end
    -- Menu text wears the EXACT font the note-list row titles use, so menus
    -- can never drift in size from the text beside them; check marks sit on
    -- the left like the main filter dropdown.
    if opts.labelFontObject == nil then opts.labelFontObject = GameFontHighlightSmall end
    if opts.iconSide == nil then opts.iconSide = "left" end
    return Utils.ShowCursorMenu(name, rows, opts)
end

-- Categories are stored by their English key and shown in the client's language.
local CATEGORY_LABELS = {
    General = "NOTES_CAT_GENERAL", Players = "NOTES_CAT_PLAYERS", NPCs = "NOTES_CAT_NPCS",
    Quests = "NOTES_CAT_QUESTS", Items = "NOTES_CAT_ITEMS", Locations = "NOTES_CAT_LOCATIONS",
    Abilities = "NOTES_CAT_ABILITIES",
}
function UI:GetEasyNotesCategories()
    return { "General", "Players", "NPCs", "Quests", "Items", "Abilities", "Locations" }
end
function UI:EasyNotesCategoryLabel(cat)
    local key = CATEGORY_LABELS[cat]
    return key and L[key] or cat
end

-- Filter menu on the note-list search bar: pick which character's notes to show
-- (default the current one, or All) and which category, mirroring the main
-- search bar's filter dropdown.
function UI:ShowEasyNotesFilterMenu(anchor)
    if not Utils.ShowCursorMenu then return end
    if UI._notes._filterMenu and UI._notes._filterMenu:IsShown() then
        UI._notes._filterMenu:Hide()
        return
    end
    -- Row BUILDERS, not row tables: toggle rows keep the menu open, so the
    -- submenu reshows itself with fresh check marks after every click (the
    -- cursor-menu keepOpen/rowsProvider machinery calls these again).
    local function charFilterRow(label, value)
        return { text = label, keepOpen = true,
            icon = (UI._notes.charFilter == value) and MENU_CHECK_TEX or nil,
            onClick = function() UI._notes.charFilter = value; UI:RefreshEasyNotesPalette() end }
    end
    local function charRows()
        local curKey = CurrentCharKey()
        local t = {
            charFilterRow(L["NOTES_THIS_CHAR"], nil),
            charFilterRow(L["NOTES_ALL_CHARS"], "all"),
        }
        local seen, notes = {}, NotesStore()
        for i = 1, #notes do
            local ch = notes[i].character
            if ch and ch ~= curKey and not seen[ch] then
                seen[ch] = true
                t[#t + 1] = charFilterRow(ch, ch)
            end
        end
        return t
    end
    -- Categories pick several at once; All is none picked. Clearing the
    -- last pick, or picking every one, is All again.
    local function catFilterRow(label, value, cats)
        local picked = UI._notes.categoryFilter
        local on = value == nil and picked == nil or (value ~= nil and picked ~= nil and picked[value] == true)
        return { text = label, keepOpen = true,
            icon = on and MENU_CHECK_TEX or nil,
            onClick = function()
                local set = UI._notes.categoryFilter
                if value == nil then
                    set = nil
                else
                    set = set or {}
                    set[value] = not set[value] or nil
                    local count = 0
                    for _ in pairs(set) do count = count + 1 end
                    if count == 0 or count >= #cats then set = nil end
                end
                UI._notes.categoryFilter = set
                UI:RefreshEasyNotesPalette()
            end }
    end
    local function catRows()
        local cats = UI:GetEasyNotesCategories()
        local t = { catFilterRow(L["NOTES_ALL_CATS"], nil, cats) }
        for i = 1, #cats do
            t[#t + 1] = catFilterRow(UI:EasyNotesCategoryLabel(cats[i]), cats[i], cats)
        end
        return t
    end
    local rows = {
        { text = _G.CHARACTER, submenu = charRows },
        { text = _G.CATEGORY, submenu = catRows },
    }
    UI._notes._filterMenu = self:ShowEasyNotesMenu("EasyNotesFilterMenu", rows, {
        anchorFrame = anchor, point = "TOPRIGHT", relativePoint = "BOTTOMRIGHT",
        offsetX = 0, offsetY = -4,
        -- The owner button stays engaged while its menu is open.
        onHide = function()
            if anchor and anchor.arrow then anchor.arrow:SetVertexColor(0.7, 0.7, 0.74, 1) end
        end,
    })
    if UI._notes._filterMenu and anchor and anchor.arrow then
        anchor.arrow:SetVertexColor(1, 1, 1, 1)
    end
end

function UI:ShowEasyNotesOverflowMenu(anchor)
    if not Utils.ShowCursorMenu then return end
    -- Second click on the button closes the open menu instead of reopening it.
    if UI._notes._moreMenu and UI._notes._moreMenu:IsShown() then
        UI._notes._moreMenu:Hide()
        return
    end
    local note = GetSelectedNote()
    if not note then return end

    local function matchRow(mode, label)
        return { text = label, icon = (note.matchMode or "any") == mode and MENU_CHECK_TEX or nil,
            onClick = function()
                note.matchMode = mode
                note.updated = time()
                UI:RefreshEasyNotesAttachBar()
                if UI._notes.paletteShown then UI:RefreshEasyNotesPalette() end
            end }
    end
    local function scopeRow(scope, label)
        return { text = label, icon = (note.scope or "character") == scope and MENU_CHECK_TEX or nil,
            onClick = function()
                note.scope = scope
                note.updated = time()
                if UI._notes.paletteShown then UI:RefreshEasyNotesPalette() end
            end }
    end
    local contextSub = {
        matchRow("any", L["NOTES_RULE_ANY"]),
        matchRow("all", L["NOTES_RULE_ALL"]),
        matchRow("manual", L["NOTES_RULE_MANUAL"]),
        { isSeparator = true },
        scopeRow("account", L["NOTES_SCOPE_ACCOUNT"]),
        scopeRow("character", L["NOTES_SCOPE_CHAR"]),
    }

    local function remindRow(label, offset)
        return { text = label, onClick = function()
            note.reminderAt = time() + offset
            note.updated = time()
            EasyFind:Print(Utils.sformat(L["NOTES_REMINDER_SET_FMT"], label))
        end }
    end
    local remindSub = {
        remindRow(L["NOTES_REMIND_1H"], 3600),
        remindRow(L["NOTES_REMIND_4H"], 4 * 3600),
        remindRow(L["NOTES_REMIND_TOMORROW"], 24 * 3600),
        remindRow(L["NOTES_REMIND_3D"], 3 * 24 * 3600),
        remindRow(L["NOTES_REMIND_1W"], 7 * 24 * 3600),
        { isSeparator = true },
        { text = note.reminderAt and L["NOTES_REMIND_CLEAR"] or L["NOTES_REMIND_NONE"],
          disabled = not note.reminderAt,
          onClick = function() note.reminderAt = nil; note.updated = time() end },
    }

    local rows = {
        { text = L["NOTES_NEW"], onClick = function()
              CreateNote("")
              UI:HideEasyNotesPalette()
              UI:RefreshEasyNotes()
              UI:FocusEasyNoteEditor()
          end },
        { text = L["CHECK_NEW"], onClick = notesNS.NewChecklist },
        { text = L["NOTES_REMIND_ME"], submenu = remindSub },
        { text = L["NOTES_FIND_IN"], onClick = function() UI:ToggleEasyNotesFindBar() end },
        { text = L["NOTES_AUTO_RESIZE"], icon = NormalizeDB().autoResize and MENU_CHECK_TEX or nil, iconSide = "right",
          onClick = function() UI:ToggleEasyNotesAutoResize() end },
        { isSeparator = true },
        { text = _G.CATEGORY, submenu = (function()
              local cats, out = self:GetEasyNotesCategories(), {}
              for i = 1, #cats do
                  local cat = cats[i]
                  out[i] = { text = UI:EasyNotesCategoryLabel(cat), icon = (note.category or "General") == cat and MENU_CHECK_TEX or nil,
                      onClick = function()
                          note.category = cat
                          note.updated = time()
                          if UI._notes.paletteShown then UI:RefreshEasyNotesPalette() end
                      end }
              end
              return out
          end)() },
        { text = L["NOTES_SET_ALIAS"], onClick = function() UI:PromptEasyNotesAlias() end },
        { text = L["NOTES_ADD_APPLIES"], onClick = function() UI:ToggleEasyNotesAppliesInSearch(anchor) end },
        { text = L["NOTES_OPENS_ITSELF_MENU"], icon = note.opensItself and MENU_CHECK_TEX or nil, iconSide = "right", onClick = function()
              note.opensItself = (not note.opensItself) or nil
              note.updated = time()
          end },
        { text = L["NOTES_ADD_SHOWS"], onClick = function() UI:ShowAddShowsOnMenu(anchor) end },
        { text = L["NOTES_CONTEXT"], submenu = contextSub },
        { isSeparator = true },
        { text = L["NOTES_READER"], onClick = function() notesNS.OpenReader(note.id) end },
        { text = L["NOTES_COPY_TEXT"], onClick = function() notesNS.CopyAsText(note.id) end },
        { text = L["NOTES_COPY_MARKDOWN"], onClick = function() notesNS.CopyAsMarkdown(note.id) end },
        { text = L["NOTES_COPY_CODE"], onClick = function()
              local code = notesNS.ExportCode(note.id)
              if code then Utils.CopyToClipboard(code) end
          end },
        { text = L["NOTES_IMPORT_CODE"], onClick = function() notesNS.PromptImportCode() end },
        { isSeparator = true },
        { text = L["NOTES_TRASH"], submenu = (function()
              local trashed, out = notesNS.TrashList(), {}
              for i = 1, math.min(#trashed, 15) do
                  local entry = trashed[i]
                  out[#out + 1] = { text = entry.title .. "  (" .. FormatRelTime(entry.deletedAt) .. ")",
                      onClick = function()
                          notesNS.RestoreNote(entry.id)
                          if UI._notes.paletteShown then UI:RefreshEasyNotesPalette() end
                      end }
              end
              if #out == 0 then out[1] = { text = L["NOTES_TRASH_NONE"], disabled = true } end
              out[#out + 1] = { isSeparator = true }
              out[#out + 1] = { text = L["NOTES_TRASH_EMPTY"], disabled = #trashed == 0,
                  onClick = function() notesNS.EmptyTrash() end }
              return out
          end)() },
        { text = L["NOTES_DELETE"], icon = "Interface\\AddOns\\EasyFind_Notes\\Images\\trash", inlineIcon = true,
          onClick = function()
              local id = UI._notes.selectedID
              if id then ConfirmDeleteNote(id) end
          end },
    }
    -- A checklist's own settings lead.
    local CKV = notesNS.ChecklistView
    if CKV and notesNS.Checklist and notesNS.Checklist.Is(note) then
        local own = CKV.MenuRows(note, anchor)
        tinsert(rows, 1, { isSeparator = true })
        for i = #own, 1, -1 do tinsert(rows, 1, own[i]) end
    end
    -- Capture rows show only while there is something to capture.
    if notesNS.OpenMailIndex() then
        tinsert(rows, 3, { text = L["NOTES_CAPTURE_MAIL"], onClick = function() notesNS.CaptureMail() end })
    end
    if notesNS.SelectedQuestID() then
        tinsert(rows, 3, { text = L["NOTES_CAPTURE_QUEST"], onClick = function() notesNS.CaptureQuest() end })
    end
    UI._notes._moreMenu = self:ShowEasyNotesMenu("EasyNotesMoreMenu", rows, {
        anchorFrame = anchor, point = "TOPRIGHT", relativePoint = "BOTTOMRIGHT",
        offsetX = 0, offsetY = -4,
    })
end

function UI:ShowEasyNotesMatchModeMenu(anchor)
    local note = GetSelectedNote()
    if not note then return end
    local rows = { { text = L["NOTES_WHEN"], disabled = true } }
    local modes = {
        { "any", L["NOTES_RULE_ANY"] },
        { "all", L["NOTES_RULE_ALL"] },
        { "manual", L["NOTES_RULE_MANUAL"] },
    }
    for _, m in ipairs(modes) do
        rows[#rows + 1] = { text = m[2], icon = (note.matchMode or "any") == m[1] and MENU_CHECK_TEX or nil,
            onClick = function()
                note.matchMode = m[1]
                note.updated = time()
                UI:RefreshEasyNotesAttachBar()
                if UI._notes.paletteShown then UI:RefreshEasyNotesPalette() end
            end }
    end
    rows[#rows + 1] = { isSeparator = true }
    rows[#rows + 1] = { text = L["NOTES_STORAGE"], disabled = true }
    rows[#rows + 1] = { text = L["NOTES_SCOPE_ACCOUNT"], icon = (note.scope or "character") == "account" and MENU_CHECK_TEX or nil,
        onClick = function() note.scope = "account"; note.updated = time() end }
    rows[#rows + 1] = { text = L["NOTES_SCOPE_CHAR"], icon = note.scope == "character" and MENU_CHECK_TEX or nil,
        onClick = function() note.scope = "character"; note.updated = time() end }
    UI:ShowEasyNotesMenu("EasyNotesMatchMode", rows, { anchorFrame = anchor })
end

function UI:ShowEasyNotesContextTooltip(anchor)
    if not GameTooltip then return end
    GameTooltip:SetOwner(anchor, "ANCHOR_TOP")
    GameTooltip:SetText(L["NOTES_MATCHING"])
    local note = GetSelectedNote()
    if note then
        GameTooltip:AddLine(MATCH_MODE_LABELS[note.matchMode or "any"], 0.95, 0.78, 0.36)
        local n = note.appliesIn and #note.appliesIn or 0
        GameTooltip:AddLine(Utils.sformat(L["NOTES_COUNTS"], n, note.showsOn and #note.showsOn or 0),
            0.6, 0.6, 0.62)
    end
    GameTooltip:Show()
end


local function AppliesInResultSort(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.name < b.name
end

function Builders.BuildAppliesInSearch(frame)
    local popup = CreateFrame("Frame", nil, frame)
    popup:SetSize(236, 252)
    popup:SetFrameLevel(frame:GetFrameLevel() + 30)
    popup:EnableMouse(true)
    -- A menu surface: the theme's fill and ring, refilled on each theme.
    ns.StyleMenuPanel(popup)
    popup.shell = Builders.MakeFindInput(popup, L["NOTES_TAG_SEARCH"])
    popup.shell:SetPoint("TOPLEFT", popup, "TOPLEFT", 8, -8)
    popup.shell:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -8, -8)
    popup.shell.edit.onChanged = function() UI:RefreshAppliesInSearchResults() end
    popup.shell.edit:SetScript("OnEscapePressed", function() popup:Hide() end)
    popup.rows = {}
    -- Under the places: whether the note opens by itself in them.
    local auto = CreateFrame("CheckButton", nil, popup, "UICheckButtonTemplate")
    auto:SetSize(18, 18)
    auto:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", 8, 6)
    if Utils.SetCheckboxTextures then Utils.SetCheckboxTextures(auto, 18) end
    auto.label = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    auto.label:SetPoint("LEFT", auto, "RIGHT", 4, 0)
    auto.label:SetPoint("RIGHT", popup, "RIGHT", -8, 0)
    auto.label:SetJustifyH("LEFT")
    auto.label:SetWordWrap(false)
    auto.label:SetText(L["NOTES_OPENS_ITSELF"])
    auto:SetScript("OnClick", function(self)
        local note = GetSelectedNote()
        if not note then return end
        note.opensItself = self:GetChecked() and true or nil
        note.updated = time()
    end)
    popup.auto = auto
    popup.catcher = CreateFrame("Frame", nil, frame)
    popup.catcher:SetAllPoints(UIParent)
    popup.catcher:SetFrameLevel(math.max(1, popup:GetFrameLevel() - 1))
    popup.catcher:EnableMouse(true)
    popup.catcher:Hide()
    popup.catcher:SetScript("OnMouseDown", function() popup:Hide() end)
    popup:SetScript("OnShow", function() popup.catcher:Show() end)
    popup:SetScript("OnHide", function()
        if popup.catcher then popup.catcher:Hide() end
    end)
    popup:Hide()
    return popup
end

function UI:GetAppliesInResultRow(index)
    local frame = UI._notes.frame
    local popup = frame and frame.appliesInSearch
    if not popup then return nil end
    local row = popup.rows[index]
    if row then return row end
    local y = -36 - (index - 1) * 20
    row = CreateFrame("Button", nil, popup)
    row:SetHeight(20)
    row:SetPoint("TOPLEFT", popup, "TOPLEFT", 8, y)
    row:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -8, y)
    -- The hover pill every menu row wears, in the theme's colors.
    Utils.InstallMenuRowHighlight(row)
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.label:SetPoint("RIGHT", row, "RIGHT", -22, 0)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    -- A place already added: a trash on hover, the click takes it off.
    row.trash = row:CreateTexture(nil, "OVERLAY")
    row.trash:SetSize(12, 12)
    row.trash:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.trash:SetTexture("Interface\\AddOns\\EasyFind_Notes\\Images\\trash")
    row.trash:SetDesaturated(true)
    row.trash:SetVertexColor(0.95, 0.45, 0.42, 1)
    row.trash:Hide()
    row:HookScript("OnEnter", function(self) self.trash:SetShown(self.added == true) end)
    row:HookScript("OnLeave", function(self) self.trash:Hide() end)
    row:SetScript("OnClick", function(self)
        local note = GetSelectedNote()
        if note and self.entry then
            ToggleNoteContext(note, self.entry)
            UI:RefreshEasyNotesAttachBar()
            if UI._notes.paletteShown then UI:RefreshEasyNotesPalette() end
            UI:RefreshAppliesInSearchResults()
        end
    end)
    popup.rows[index] = row
    return row
end

function UI:RefreshAppliesInSearchResults()
    local frame = UI._notes.frame
    local popup = frame and frame.appliesInSearch
    if not popup then return end
    local note = GetSelectedNote()
    local query = slower(strtrim(popup.shell.edit:GetText() or ""))
    local opts = Ctx.Options()
    local results = {}
    for i = 1, #opts do
        local e = opts[i]
        local score = Ctx.MatchScore(e, query)
        if score then
            results[#results + 1] = { entry = e, name = e.name or tostring(e.id), score = score }
        end
    end
    tsort(results, AppliesInResultSort)
    for i = 1, 9 do
        local row = self:GetAppliesInResultRow(i)
        if not row then break end
        local r = results[i]
        if r then
            row.entry = r.entry
            local added = note and NoteHasContext(note, CtxKey(r.entry))
            row.added = added
            row.trash:SetShown(added and row:IsMouseOver())
            row.label:SetText((added and "|cff6fcf6f+ |r" or "") .. r.name
                .. "  |cff8a8a90" .. Ctx.KindLabel(r.entry) .. "|r")
            row:Show()
        else
            row:Hide()
        end
    end
    -- Rows made this pass take the theme's hover pill and text color.
    if Utils.RefreshMenuRowHighlights then Utils.RefreshMenuRowHighlights(popup, popup.rows) end
    if ns.RetintPanelText then ns.RetintPanelText(popup) end
end

do
    -- Below the anchor when it fits, else above; its left edge on the
    -- anchor's unless that runs off the screen's right.
    local function PlaceByAnchor(popup, anchor)
        local s, as = popup:GetEffectiveScale(), anchor:GetEffectiveScale()
        local left, bottom, top = (anchor:GetLeft() or 0) * as, (anchor:GetBottom() or 0) * as, (anchor:GetTop() or 0) * as
        local w, h = popup:GetWidth() * s, popup:GetHeight() * s
        local screenW = UIParent:GetWidth() * UIParent:GetEffectiveScale()
        local screenH = UIParent:GetHeight() * UIParent:GetEffectiveScale()
        local below = bottom - h - 4 >= 0 or bottom >= screenH - top
        local side = left + w <= screenW and "LEFT" or "RIGHT"
        popup:ClearAllPoints()
        popup:SetPoint((below and "TOP" or "BOTTOM") .. side, anchor, (below and "BOTTOM" or "TOP") .. side, 0, below and -4 or 4)
        popup:SetClampedToScreen(true)
    end

    function UI:ToggleEasyNotesAppliesInSearch(anchor)
        local frame = UI._notes.frame
        if not (frame and GetSelectedNote()) then return end
        if not frame.appliesInSearch then
            frame.appliesInSearch = Builders.BuildAppliesInSearch(frame)
        end
        local popup = frame.appliesInSearch
        if popup:IsShown() then
            popup:Hide()
            return
        end
        PlaceByAnchor(popup, anchor or frame.appliesInButton)
        popup.auto:SetChecked(GetSelectedNote().opensItself == true)
        popup.shell.edit:SetText("")
        self:RefreshAppliesInSearchResults()
        popup:Show()
        popup.shell.edit:SetFocus()
    end
end

local function CursorObjectEntry()
    if not GetCursorInfo then return nil end
    local kind, id = GetCursorInfo()
    if kind == "item" and id then
        local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id))
        return { type = "item", id = id, name = name or Utils.sformat(L["NOTES_ITEM_FMT"], id) }
    end
    if kind == "spell" and id then
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
        return { type = "spell", id = id, name = (info and info.name) or Utils.sformat(L["NOTES_SPELL_FMT"], id) }
    end
    return nil
end

local function TargetNPCEntry()
    local entry = ns.NotesUnitEntry("target")
    return entry and entry.type == "npc" and entry or nil
end

function UI:ShowAddShowsOnMenu(anchor)
    local note = GetSelectedNote()
    if not note then return end
    local rows = { { text = L["NOTES_SHOW_ON_TT"], disabled = true } }
    local function addEntry(entry)
        rows[#rows + 1] = { text = entry.name, icon = NoteHasShowsOn(note, CtxKey(entry)) and MENU_CHECK_TEX or nil,
            onClick = function()
                ToggleNoteShowsOn(note, entry)
                UI:RefreshEasyNotesAttachBar()
            end }
    end
    local cursorEntry = CursorObjectEntry()
    if cursorEntry then addEntry(cursorEntry) end
    local npcEntry = TargetNPCEntry()
    if npcEntry then addEntry(npcEntry) end
    if not (cursorEntry or npcEntry) then
        rows[#rows + 1] = { text = L["NOTES_PICK_UP"], disabled = true }
    end
    UI:ShowEasyNotesMenu("EasyNotesShowsOn", rows, { anchorFrame = anchor })
end

function UI:RefreshEasyNotesAttachBar()
    local frame = UI._notes.frame
    if not (frame and frame.attachBar) then return end
    local note = GetSelectedNote()
    if frame.appliesInButton then frame.appliesInButton:Hide() end
    if frame.showsOnButton then frame.showsOnButton:Hide() end
    local pills = frame.attachPills
    local entries = {}
    if note then
        for i = 1, #(note.appliesIn or {}) do
            local e = note.appliesIn[i]
            entries[#entries + 1] = { kind = "appliesIn", entry = e, idx = i, name = e.name or tostring(e.id) }
        end
        for i = 1, #(note.showsOn or {}) do
            local e = note.showsOn[i]
            entries[#entries + 1] = { kind = "showsOn", entry = e, idx = i, name = e.name or tostring(e.id) }
        end
    end
    -- The Shows line, a second header while the note has places: the
    -- label, the places as pills with an X, + for the picker, the fold.
    local hasTags = note ~= nil and #entries > 0
    local folded = hasTags and NormalizeDB().showsFolded == true
    local open = hasTags and not folded
    local x = 6
    if not frame.showsLabel then
        frame.showsLabel = frame.attachBar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        frame.showsLabel:SetText(L["NOTES_SHOWS_LABEL"])
        local line = frame.attachBar:CreateTexture(nil, "ARTWORK")
        line:SetColorTexture(0.18, 0.18, 0.20, 0.7)
        line:SetHeight(1)
        line:SetPoint("TOPLEFT", frame.attachBar, "BOTTOMLEFT", 0, -4)
        line:SetPoint("TOPRIGHT", frame.attachBar, "BOTTOMRIGHT", 0, -4)
        frame.showsDivider = line
        -- Folds the line away for the text, and back.
        local fold = CreateFrame("Button", nil, frame.attachBar)
        fold:SetSize(16, 16)
        fold:SetPoint("RIGHT", frame.attachBar, "RIGHT", -2, 0)
        fold.glyph = fold:CreateTexture(nil, "OVERLAY")
        fold.glyph:SetTexture(ns.FILTER_ARROW_TEX)
        fold.glyph:SetSize(10, 10)
        fold.glyph:SetPoint("CENTER")
        fold.glyph:SetVertexColor(0.7, 0.7, 0.74, 1)
        fold:SetScript("OnClick", function()
            local db = NormalizeDB()
            db.showsFolded = not db.showsFolded or nil
            UI:RefreshEasyNotesAttachBar()
        end)
        fold:SetScript("OnEnter", function(self)
            self.glyph:SetVertexColor(1, 1, 1, 1)
            UI:ShowNotesTipDelayed(self, "ANCHOR_TOP",
                NormalizeDB().showsFolded and L["NOTES_SHOWS_UNFOLD"] or L["NOTES_SHOWS_FOLD"])
        end)
        fold:SetScript("OnLeave", function(self)
            self.glyph:SetVertexColor(0.7, 0.7, 0.74, 1)
            if GameTooltip then GameTooltip:Hide() end
        end)
        frame.showsFold = fold
    end
    -- Folded: a thin strip with the arrow.
    UI._notes.attachH = folded and 14 or ATTACH_H
    frame.attachBar:SetHeight(UI._notes.attachH)
    frame.showsDivider:SetShown(hasTags)
    frame.showsFold:SetShown(hasTags)
    frame.showsFold.glyph:SetRotation(folded and 0 or math.pi)
    local showsLabel = frame.showsLabel
    showsLabel:SetShown(open)
    showsLabel:ClearAllPoints()
    showsLabel:SetPoint("LEFT", frame.attachBar, "LEFT", x, 0)
    x = x + (showsLabel:GetStringWidth() or 30) + 6
    local barW = frame.attachBar:GetWidth()
    if not barW or barW < 50 then barW = 280 end
    -- Room kept for the +, a "+N" pill and the fold.
    local maxX = barW - (frame.appliesInButton:GetWidth() or 20) - 58
    local shown, overflowCount = 0, 0
    for i = 1, open and #entries or 0 do
        local data = entries[i]
        local pill = pills[i]
        if not pill then
            pill = CreateFrame("Button", nil, frame.attachBar)
            pill:SetHeight(18)
            if ns.CreateRoundedRectBorder then
                ns.CreateRoundedRectBorder(pill)
                ns.SetRoundedRectBarHeight(pill, 8)
                ns.SetRoundedRectBorderEdgeShown(pill, false)
            end
            pill.text = pill:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            pill.text:SetPoint("LEFT", pill, "LEFT", 8, 0)
            pill.text:SetWordWrap(false)
            pill:RegisterForClicks("RightButtonUp")
            pill.close = ns.CreateCloseX and ns.CreateCloseX(pill, 10)
            if pill.close then
                pill.close:SetPoint("RIGHT", pill, "RIGHT", -4, 0)
                pill.close:SetScript("OnClick", function() pill:GetScript("OnClick")(pill) end)
            end
            pill:SetScript("OnClick", function(self)
                local n = GetSelectedNote()
                if not n then return end
                if self.pillKind == "appliesIn" then
                    ToggleNoteContext(n, self.pillEntry)
                else
                    ToggleNoteShowsOn(n, self.pillEntry)
                end
                UI:RefreshEasyNotesAttachBar()
                if UI._notes.paletteShown then UI:RefreshEasyNotesPalette() end
            end)
            pill:SetScript("OnEnter", function(self)
                if GameTooltip then
                    GameTooltip:SetOwner(self, "ANCHOR_TOP")
                    GameTooltip:SetText(self.pillKind == "appliesIn" and L["NOTES_APPLIES_IN"] or L["NOTES_SHOWS_ON"])
                    GameTooltip:AddLine(self.pillName or "", 0.9, 0.9, 0.9)
                    GameTooltip:AddLine(L["NOTES_RIGHT_REMOVE"], 0.6, 0.6, 0.62)
                    GameTooltip:Show()
                end
            end)
            pill:SetScript("OnLeave", function()
                if GameTooltip then GameTooltip:Hide() end
            end)
            pills[i] = pill
        end
        pill.pillKind = data.kind
        pill.pillEntry = data.entry
        pill.pillName = data.name
        local label = data.name
        if #label > 22 then label = label:sub(1, 22) .. "..." end
        pill.text:SetText(label)
        -- The first pill always shows, cut to the room the line has left.
        local fixed = 16 + (pill.close and 12 or 0)
        local textW = pill.text.GetUnboundedStringWidth and pill.text:GetUnboundedStringWidth() or pill.text:GetStringWidth() or 20
        if shown == 0 then textW = math.min(textW, math.max(20, maxX - x - fixed)) end
        pill.text:SetWidth(textW)
        pill:SetWidth(textW + fixed)
        if ns.SetRoundedRectFill then
            local tc = TagColor(CtxKey(data.entry))
            ns.SetRoundedRectFill(pill, tc[1] * 0.34, tc[2] * 0.34, tc[3] * 0.34, 1, true)
            pill.text:SetTextColor(
                math.min(1, tc[1] + 0.28),
                math.min(1, tc[2] + 0.28),
                math.min(1, tc[3] + 0.28), 1)
        end
        local w = pill:GetWidth() or 20
        if x + w > maxX and shown > 0 then
            pill:Hide()
            overflowCount = #entries - i + 1
            break
        end
        pill:ClearAllPoints()
        pill:SetPoint("LEFT", frame.attachBar, "LEFT", x, 0)
        pill:Show()
        x = x + w + 4
        shown = i
    end
    for i = shown + 1, #pills do
        if pills[i] then pills[i]:Hide() end
    end
    if overflowCount > 0 then
        local ov = frame.attachOverflow
        if not ov then
            ov = CreateFrame("Button", nil, frame.attachBar)
            ov:SetHeight(18)
            if ns.CreateRoundedRectBorder then
                ns.CreateRoundedRectBorder(ov)
                ns.SetRoundedRectBarHeight(ov, 8)
                ns.SetRoundedRectFill(ov, 0.16, 0.16, 0.18, 1, true)
                ns.SetRoundedRectBorderEdgeShown(ov, false)
            end
            ov.text = ov:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            ov.text:SetPoint("CENTER")
            ov.text:SetTextColor(0.82, 0.82, 0.86, 1)
            ov:SetScript("OnClick", function(self) UI:ShowEasyNotesTagOverflow(self) end)
            frame.attachOverflow = ov
        end
        ov.text:SetText("+" .. overflowCount)
        ov:SetWidth((ov.text:GetStringWidth() or 16) + 14)
        ov:ClearAllPoints()
        ov:SetPoint("LEFT", frame.attachBar, "LEFT", x, 0)
        ov:Show()
        x = x + ov:GetWidth() + 4
    elseif frame.attachOverflow then
        frame.attachOverflow:Hide()
    end
    if open then
        frame.appliesInButton:ClearAllPoints()
        frame.appliesInButton:SetPoint("LEFT", frame.attachBar, "LEFT", x, 0)
        frame.appliesInButton:Show()
    end

    UI._notes.attachHasContent = hasTags
    UI:UpdateEasyNotesEditorTop()
end

function UI:ShowEasyNotesTagOverflow(anchor)
    local note = GetSelectedNote()
    if not note then return end
    local rows = { { text = L["NOTES_APPLIED_TAGS"], disabled = true } }
    local function addRow(entry, isShowsOn)
        local nm = (entry.name or tostring(entry.id))
        rows[#rows + 1] = { text = Utils.sformat(isShowsOn and L["NOTES_SHOWS_ON_FMT"] or L["NOTES_APPLIES_IN_FMT"], nm),
            onClick = function()
                local n = GetSelectedNote()
                if not n then return end
                if isShowsOn then ToggleNoteShowsOn(n, entry) else ToggleNoteContext(n, entry) end
                UI:RefreshEasyNotesAttachBar()
                if UI._notes.paletteShown then UI:RefreshEasyNotesPalette() end
            end }
    end
    for i = 1, #(note.appliesIn or {}) do addRow(note.appliesIn[i], false) end
    for i = 1, #(note.showsOn or {}) do addRow(note.showsOn[i], true) end
    UI:ShowEasyNotesMenu("EasyNotesTagOverflow", rows, { anchorFrame = anchor })
end

function UI:GetEasyNotesContextChip(index)
    UI._notes.contextChips = UI._notes.contextChips or {}
    local pool = UI._notes.contextChips
    local chip = pool[index]
    if chip then return chip end
    local frame = UI._notes.frame
    if not (frame and frame.paletteContextBar) then return nil end
    chip = CreateFrame("Button", nil, frame.paletteContextBar)
    chip:SetHeight(20)
    if ns.CreateRoundedRectBorder then
        ns.CreateRoundedRectBorder(chip)
        ns.SetRoundedRectBarHeight(chip, 9)
        ns.SetRoundedRectBorderEdgeShown(chip, false)
    end
    chip.text = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    chip.text:SetPoint("CENTER")
    chip:SetScript("OnClick", function(self)
        local fset = UI._notes.contextFilterSet or {}
        UI._notes.contextFilterSet = fset
        fset[self.ctxKey] = (not fset[self.ctxKey]) or nil
        UI._notes.contextFilterUserSet = true
        UI:RefreshEasyNotesPalette()
    end)
    chip:SetScript("OnEnter", function(self)
        if self.isHere then UI:ShowNotesTipDelayed(self, "ANCHOR_TOP", L["NOTES_HERE_CHIP_TT"]) end
    end)
    chip:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)
    pool[index] = chip
    return chip
end

-- The filter chips: "Applies here" (the notes whose tags match where you
-- are, by each note's match mode), then each active situation a note is
-- tagged with. "Applies here" turns on by itself when it has notes, until
-- the user picks chips; the setting can keep it off.
local HERE_KEY = "@here"
function UI:ResolveEasyNotesContextFilter()
    local active, set = Ctx.Active()
    UI._notes.activeSet = set
    local matches, present = {}, {}
    local visible = SortedNotes("")
    local here = 0
    for i = 1, #visible do
        if Ctx.Applies(visible[i], set) then here = here + 1 end
    end
    if here > 0 then
        matches[1] = { key = HERE_KEY, label = L["NOTES_HERE_CHIP"], here = true, type = "here", count = here }
        present[HERE_KEY] = true
    end
    for i = 1, #active do
        local c = active[i]
        local key = CtxKey(c)
        local count = CountNotesWithContext(key)
        if count > 0 then
            matches[#matches + 1] = { key = key, label = c.name, type = c.type, count = count }
            present[key] = true
        end
    end
    tsort(matches, ContextMatchSort)
    local fset = UI._notes.contextFilterSet or {}
    UI._notes.contextFilterSet = fset
    for k in pairs(fset) do
        if not present[k] then fset[k] = nil end
    end
    if here > 0 and not UI._notes.contextFilterUserSet and EasyFind.db.notesHereFilter ~= false then
        fset[HERE_KEY] = true
    end
    return matches
end

function UI:LayoutEasyNotesContextBar(matches)
    local frame = UI._notes.frame
    if not frame then return end
    local fset = UI._notes.contextFilterSet or {}
    local bar = frame.paletteContextBar
    local chips = UI._notes.contextChips
    if not matches or #matches == 0 then
        if bar then bar:Hide() end
        for i = 1, #chips do chips[i]:Hide() end
        frame.paletteList:SetPoint("TOPLEFT", frame.paletteSearchShell, "BOTTOMLEFT", 0, -6)
        return
    end
    bar:SetHeight(26)
    bar:Show()
    frame.paletteList:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -6)
    UI._notes.contextMatches = matches
    local barW = bar:GetWidth()
    if not barW or barW < 50 then barW = 260 end
    local maxX = barW - 40
    local x = 2
    local shown = 0
    for i = 1, #matches do
        local m = matches[i]
        local chip = self:GetEasyNotesContextChip(i)
        if chip then
            chip.ctxKey = m.key
            chip.isHere = m.here
            chip.text:SetText(m.label)
            chip:SetWidth((chip.text:GetStringWidth() or 24) + 20)
            local w = chip:GetWidth()
            if x + w > maxX and shown > 0 then
                chip:Hide()
                break
            end
            chip:ClearAllPoints()
            chip:SetPoint("LEFT", bar, "LEFT", x, 0)
            local active = fset[m.key] and true or false
            local tc = TagColor(m.key)
            if ns.SetRoundedRectFill then
                if active then
                    ns.SetRoundedRectFill(chip, tc[1] * 0.62, tc[2] * 0.62, tc[3] * 0.62, 1, true)
                else
                    ns.SetRoundedRectFill(chip, tc[1] * 0.26, tc[2] * 0.26, tc[3] * 0.26, 1, true)
                end
            end
            if active then
                chip.text:SetTextColor(1, 1, 1, 1)
            else
                chip.text:SetTextColor(
                    math.min(1, tc[1] + 0.28),
                    math.min(1, tc[2] + 0.28),
                    math.min(1, tc[3] + 0.28), 1)
            end
            chip:Show()
            x = x + w + 6
            shown = i
        end
    end
    for i = shown + 1, #chips do chips[i]:Hide() end
    local overflow = #matches - shown
    local ov = frame.contextOverflowChip
    if overflow > 0 then
        if not ov then
            ov = CreateFrame("Button", nil, bar)
            ov:SetHeight(20)
            if ns.CreateRoundedRectBorder then
                ns.CreateRoundedRectBorder(ov)
                ns.SetRoundedRectBarHeight(ov, 9)
                ns.SetRoundedRectFill(ov, 0.16, 0.16, 0.18, 1, true)
                ns.SetRoundedRectBorderEdgeShown(ov, false)
            end
            ov.text = ov:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            ov.text:SetPoint("CENTER")
            ov.text:SetTextColor(0.82, 0.82, 0.86, 1)
            ov:SetScript("OnClick", function(self)
                UI:ShowEasyNotesContextOverflowMenu(self, UI._notes.contextMatches)
            end)
            frame.contextOverflowChip = ov
        end
        ov.text:SetText("+" .. overflow)
        ov:SetWidth((ov.text:GetStringWidth() or 16) + 16)
        ov:ClearAllPoints()
        ov:SetPoint("LEFT", bar, "LEFT", x, 0)
        ov:Show()
    elseif ov then
        ov:Hide()
    end
end

function UI:ShowEasyNotesContextOverflowMenu(anchor, matches)
    if not matches then return end
    local rows = { { text = L["NOTES_FILTER_BY"], disabled = true } }
    for i = 1, #matches do
        local m = matches[i]
        local fset = UI._notes.contextFilterSet
        rows[#rows + 1] = { text = m.label, icon = (fset and fset[m.key]) and MENU_CHECK_TEX or nil,
            onClick = function()
                local set = UI._notes.contextFilterSet or {}
                UI._notes.contextFilterSet = set
                set[m.key] = (not set[m.key]) or nil
                UI:RefreshEasyNotesPalette()
            end }
    end
    UI:ShowEasyNotesMenu("EasyNotesContextFilter", rows, { anchorFrame = anchor })
end

-- Up to two tag pills after the note name, then a "+N" with a hover list.
-- The tags take at most half the row, so the name always shows.
do
    local function MakeRowTagPill(parent)
        local p = CreateFrame("Button", nil, parent)
        p:SetHeight(15)
        if ns.CreateRoundedRectBorder then
            ns.CreateRoundedRectBorder(p)
            ns.SetRoundedRectBarHeight(p, 7)
            ns.SetRoundedRectBorderEdgeShown(p, false)
        end
        p.text = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        p.text:SetPoint("CENTER")
        p.text:SetWordWrap(false)
        return p
    end

    local function RowTagMoreEnter(self)
        if not (GameTooltip and self.allTags) then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["NOTES_APPLIES_IN"])
        for i = 1, #self.allTags do
            local t = self.allTags[i]
            GameTooltip:AddLine(t.name or tostring(t.id), 0.9, 0.9, 0.92)
        end
        GameTooltip:Show()
    end

    local function RowTagLeave()
        if GameTooltip then GameTooltip:Hide() end
    end

    local ROW_TAG_MAX_W = 110
    local rowTagW = {}
    function UI:LayoutEasyNotesRowTags(row, note, rowW)
        row.tagPills = row.tagPills or {}
        row.tagNote = note
        local pool = row.tagPills
        local tags = (note and note.appliesIn) or {}
        for i = 1, #pool do pool[i]:Hide() end
        if row.tagMore then row.tagMore:Hide() end
        if #tags == 0 then
            row.title:SetPoint("RIGHT", row, "RIGHT", -12, 0)
            return
        end
        local room = math.floor(((rowW or row:GetWidth() or 0) - 22) / 2)
        local more = row.tagMore
        if not more then
            more = MakeRowTagPill(row)
            more:SetScript("OnEnter", RowTagMoreEnter)
            more:SetScript("OnLeave", RowTagLeave)
            row.tagMore = more
        end
        local nShown = mmin(2, #tags)
        for i = 1, nShown do
            local pill = pool[i]
            if not pill then pill = MakeRowTagPill(row); pool[i] = pill end
            local t = tags[i]
            pill.text:SetWidth(0)
            pill.text:SetText(t.name or tostring(t.id))
            local w = pill.text.GetUnboundedStringWidth and pill.text:GetUnboundedStringWidth() or pill.text:GetStringWidth() or 20
            rowTagW[i] = mmin(ROW_TAG_MAX_W, math.ceil(w)) + 12
        end
        -- The pills that fit, the "+N" set to the rest.
        local function Total(k)
            local w = 0
            for i = 1, k do w = w + rowTagW[i] + 3 end
            if #tags > k then
                more.text:SetText("+" .. (#tags - k))
                w = w + (more.text:GetStringWidth() or 14) + 13
            end
            return w - 3
        end
        while nShown > 1 and Total(nShown) > room do nShown = nShown - 1 end
        local over = Total(nShown) - room
        if over > 0 then rowTagW[1] = mmax(28, rowTagW[1] - over) end
        local x = -10
        if #tags > nShown then
            more.allTags = tags
            more.text:SetTextColor(0.82, 0.82, 0.86, 1)
            if ns.SetRoundedRectFill then
                ns.SetRoundedRectFill(more, 0.18, 0.18, 0.20, 1, true)
            end
            more:SetWidth((more.text:GetStringWidth() or 14) + 10)
            more:ClearAllPoints()
            more:SetPoint("TOPRIGHT", row, "TOPRIGHT", x, -6)
            more:Show()
            x = x - more:GetWidth() - 3
        end
        for i = nShown, 1, -1 do
            local pill = pool[i]
            local t = tags[i]
            local tc = TagColor(CtxKey(t))
            if ns.SetRoundedRectFill then
                ns.SetRoundedRectFill(pill, tc[1] * 0.34, tc[2] * 0.34, tc[3] * 0.34, 1, true)
            end
            pill.text:SetTextColor(
                math.min(1, tc[1] + 0.28),
                math.min(1, tc[2] + 0.28),
                math.min(1, tc[3] + 0.28), 1)
            pill.text:SetWidth(rowTagW[i] - 12)
            pill:SetWidth(rowTagW[i])
            pill:ClearAllPoints()
            pill:SetPoint("TOPRIGHT", row, "TOPRIGHT", x, -6)
            pill:Show()
            x = x - pill:GetWidth() - 3
        end
        row.title:SetPoint("RIGHT", row, "RIGHT", x - 4, 0)
    end
end

function UI:RefreshEasyNotesPalette()
    local frame = UI._notes.frame
    if not (frame and UI._notes.paletteShown) then return end
    if UI._notes.renameRow then self:CommitEasyNotesRowRename() end
    local matches = self:ResolveEasyNotesContextFilter()
    self:LayoutEasyNotesContextBar(matches)
    local query = frame.paletteSearch:GetText() or ""
    local list = SortedNotes(query)
    local fset = UI._notes.contextFilterSet
    local set = UI._notes.activeSet or {}
    local hasFilter = fset ~= nil and next(fset) ~= nil
    local filtered, later = {}, {}
    for i = 1, #list do
        local n = list[i]
        local applies = Ctx.Applies(n, set)
        local keep = not hasFilter or (fset[HERE_KEY] and applies)
        if not keep and n.appliesIn then
            for j = 1, #n.appliesIn do
                if fset[CtxKey(n.appliesIn[j])] then keep = true break end
            end
        end
        -- Unfiltered, notes that apply here follow the pinned ones.
        if keep then
            if hasFilter or n.pinned or applies then filtered[#filtered + 1] = n else later[#later + 1] = n end
        end
    end
    for i = 1, #later do filtered[#filtered + 1] = later[i] end
    list = filtered
    local listW = frame.paletteList:GetWidth() or 200
    frame.paletteListChild:SetWidth(listW)
    local rows = UI._notes.paletteRows
    local gap = 4
    local y = 0
    for i = 1, #list do
        local note = list[i]
        local row = self:EnsureEasyNotesPaletteRow(i)
        if not row then break end
        row.noteID = note.id
        row.title:SetText(NoteTitle(note))
        self:LayoutEasyNotesRowTags(row, note, listW)
        if row.pinButton and row.pinButton.icon then
            if note.pinned then
                row.pinButton.icon:SetVertexColor(0.95, 0.78, 0.36, 1)
            else
                row.pinButton.icon:SetVertexColor(0.96, 0.96, 0.98, 1)
            end
        end
        -- strip SMP styling + color codes: the row font can't render them
        local preview = (notesNS.Checklist and notesNS.Checklist.Is(note)) and notesNS.Checklist.Preview(note)
            or StripColorEscapes(MapSelection((note.body or ""):gsub("\n+", " "), GlyphPlain)):sub(1, 80)
        if note.alias and note.alias ~= "" then
            preview = "@" .. note.alias .. "  " .. preview
        end
        row.subtitle:SetText(preview)
        row.timeText:SetText(FormatRelTime(note.updated))
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame.paletteListChild, "TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", frame.paletteListChild, "TOPRIGHT", 0, -y)
        row:SetHeight(PALETTE_ROW_H)
        PaintPaletteRow(row)
        row:Show()
        y = y + PALETTE_ROW_H + gap
    end
    for i = #list + 1, #rows do rows[i]:Hide() end
    local contentH = mmax(1, y)
    frame.paletteListChild:SetHeight(contentH)
    local viewH = frame.paletteList:GetHeight() or 0
    local maxScroll = mmax(0, contentH - viewH)
    if (frame.paletteList:GetVerticalScroll() or 0) > maxScroll then
        frame.paletteList:SetVerticalScroll(maxScroll)
    end
    if frame.paletteScrollBar then
        local hasScroll = contentH > viewH + 1
        frame.paletteScrollBar:SetShown(hasScroll)
        if hasScroll then frame.paletteScrollBar:UpdateThumb(contentH, viewH) end
    end
end

function UI:FindEasyNoteByAlias(raw)
    raw = slower(strtrim(raw or ""))
    if raw == "" then return nil end
    local notes = NotesStore()
    for i = 1, #notes do
        local n = notes[i]
        if n.alias and slower(n.alias) == raw then return n end
    end
end

function UI:OpenEasyNoteByAlias(raw)
    local n = self:FindEasyNoteByAlias(raw)
    if not n then return false end
    self:OpenEasyNotes()
    self:SelectEasyNote(n.id)
    self:HideEasyNotesPalette()
    return true
end

function notesNS.Open() UI:OpenEasyNotes() end
function notesNS.Refresh()
    if UI._notes.paletteShown then UI:RefreshEasyNotesPalette() end
end
function notesNS.Close() UI:CloseEasyNotes() end
function notesNS.Toggle() UI:ToggleEasyNotes() end
function notesNS.IsOpen()
    local frame = UI._notes.frame
    return frame ~= nil and frame:IsShown()
end

-- /notes: toggles the window; /notes <alias> opens that note, and any other
-- word opens the list searching for it.
function notesNS.Slash(msg)
    msg = strtrim(msg or "")
    if msg == "" then return UI:ToggleEasyNotes() end
    if slower(msg) == "undo" then return notesNS.RestoreLastDeleted() end
    if slower(msg) == "import" then return notesNS.PromptImportCode() end
    if slower(msg) == "read" then return notesNS.ToggleReader() end
    if UI:OpenEasyNoteByAlias(msg) then return end
    UI:OpenEasyNotes()
    local frame = UI._notes.frame
    if frame and frame.paletteSearch then frame.paletteSearch:SetText(msg) end
end

-- Hosts the full notes formatting experience inside another window (EasyFind's
-- snippet editor): a notes-treated editor plus formatting toolbar whose actions
-- route through the active format host. The caller positions the container and
-- owns OnEscapePressed/OnTabPressed.
-- Word-processor undo/redo, shared by the notes editor and the snippet host.
-- One history per document; switching documents (note selection, snippet
-- SetDocument) resets it. Typing coalesces into bursts; format applies and
-- decoration edits always cut a snapshot. Ctrl+Z undoes, Ctrl+Y or
-- Ctrl+Shift+Z redoes.
function Fmt.HistorySnapshot(editor, doc)
    local decos = {}
    local src = doc and doc.decorations
    if src then
        for i = 1, #src do
            local d = src[i]
            decos[i] = { kind = d.kind, startByte = d.startByte, endByte = d.endByte,
                r = d.r, g = d.g, b = d.b }
        end
    end
    return { body = editor:GetText() or "", decos = decos,
        cursor = editor:GetCursorPosition() or 0 }
end

function Fmt.HistorySameState(a, b)
    if a.body ~= b.body or #a.decos ~= #b.decos then return false end
    for i = 1, #a.decos do
        local x, y = a.decos[i], b.decos[i]
        if x.kind ~= y.kind or x.startByte ~= y.startByte or x.endByte ~= y.endByte
           or x.r ~= y.r or x.g ~= y.g or x.b ~= y.b then
            return false
        end
    end
    return true
end

function Fmt.HistoryContext()
    local editor = Fmt.ActiveFormatEditor()
    local doc = Fmt.ActiveFormatDoc()
    if not (editor and doc) then return nil end
    local h = UI._notes.editHistory
    if not h or h.ownerDoc ~= doc then
        h = { ownerDoc = doc, undo = {}, redo = {},
            last = Fmt.HistorySnapshot(editor, doc), lastAt = 0 }
        UI._notes.editHistory = h
    end
    return h, editor, doc
end

function Fmt.HistoryRecord(structural)
    if UI._notes.loadingNote then return end
    local h, editor, doc = Fmt.HistoryContext()
    if not h then return end
    local cur = Fmt.HistorySnapshot(editor, doc)
    if Fmt.HistorySameState(cur, h.last) then return end
    local now = GetTime and GetTime() or 0
    -- Typing within the window replaces the tracked state without pushing,
    -- so one undo returns to the burst start, word-processor style.
    if structural or (now - (h.lastAt or 0)) > 0.8 or #h.undo == 0 then
        h.undo[#h.undo + 1] = h.last
        if #h.undo > 100 then table.remove(h.undo, 1) end
    end
    for i = #h.redo, 1, -1 do h.redo[i] = nil end
    h.last = cur
    h.lastAt = now
end

function Fmt.HistoryApply(state)
    local h, editor, doc = Fmt.HistoryContext()
    if not (h and state) then return end
    UI._notes.loadingNote = true
    UI._notes.applyingFormat = true
    editor:SetText(state.body)
    editor:SetCursorPosition(math.min(state.cursor or 0, #state.body))
    UI._notes.applyingFormat = nil
    UI._notes.loadingNote = nil
    doc.decorations = doc.decorations or {}
    local decos = doc.decorations
    for i = #decos, 1, -1 do decos[i] = nil end
    for i = 1, #state.decos do
        local d = state.decos[i]
        decos[i] = { kind = d.kind, startByte = d.startByte, endByte = d.endByte,
            r = d.r, g = d.g, b = d.b }
    end
    doc.body = state.body
    if Fmt.SnippetHostActive() then
        UI._notes.snippetHost._lastText = state.body
    else
        UI._notes.lastEditorText = state.body
        if UI._notes.selectedID then UpdateBody(UI._notes.selectedID, state.body) end
        doc.updated = time()
        UI:UpdateEasyNotesCharCounter()
    end
    UI._notes.selAnchor = nil
    UI._notes.curSelection = nil
    UI._notes.lastSelection = nil
    UI:QueueEasyNotesOverlayUpdate()
    UI:RefreshFormatButtonStates()
end

function Fmt.HistoryUndo()
    local h, editor, doc = Fmt.HistoryContext()
    if not h or #h.undo == 0 then return end
    h.redo[#h.redo + 1] = Fmt.HistorySnapshot(editor, doc)
    local state = table.remove(h.undo)
    Fmt.HistoryApply(state)
    h.last = Fmt.HistorySnapshot(editor, doc)
    h.lastAt = 0
end

function Fmt.HistoryRedo()
    local h, editor, doc = Fmt.HistoryContext()
    if not h or #h.redo == 0 then return end
    h.undo[#h.undo + 1] = Fmt.HistorySnapshot(editor, doc)
    local state = table.remove(h.redo)
    Fmt.HistoryApply(state)
    h.last = Fmt.HistorySnapshot(editor, doc)
    h.lastAt = 0
end

-- Ctrl-key editing actions shared by both editors: undo/redo, select-all,
-- plain copy, and the format shortcuts. Returns true when the key was handled.
function Fmt.HandleEditorFormatKey(editor, k)
    if k == "Z" then
        if IsShiftKeyDown and IsShiftKeyDown() then Fmt.HistoryRedo() else Fmt.HistoryUndo() end
        return true
    elseif k == "Y" then
        Fmt.HistoryRedo()
        return true
    elseif k == "A" then
        local txt = editor:GetText() or ""
        if #txt > 0 then
            UI._notes.selAnchor = 0
            UI._notes.lastSelection = { lo = 1, hi = #txt, ts = GetTime and GetTime() or 0 }
            UI._notes.curSelection = { lo = 1, hi = #txt }
            UI:RefreshFormatButtonStates()
        else
            UI._notes.selAnchor = nil
            UI._notes.curSelection = nil
        end
        if not Fmt.SnippetHostActive() then UI:UpdateEasyNotesCaretVisibility() end
        return true
    elseif k == "C" then
        local cs = UI._notes.curSelection
        local lo = cs and cs.lo
        local hi = cs and cs.hi
        if lo and hi and Utils.SafeAfter then
            local full = editor:GetText() or ""
            local cursor = editor:GetCursorPosition()
            local plain, pLo, pHi = BuildPlainCopy(full, lo, hi)
            if plain ~= full then
                UI._notes.loadingNote = true
                editor:SetText(plain)
                editor:HighlightText(pLo, pHi)
                Utils.SafeAfter(0, function()
                    editor:SetText(full)
                    editor:HighlightText(lo - 1, hi)
                    if cursor then editor:SetCursorPosition(cursor) end
                    UI._notes.loadingNote = nil
                end)
            end
        end
        return true
    end
    local modeKey
    if k == "B" then modeKey = "bold"
    elseif k == "I" then modeKey = "italic"
    elseif k == "U" then modeKey = "underline"
    elseif k == "5" or k == "NUMPAD5" then modeKey = "strike"
    end
    if modeKey then
        local cs = UI._notes.curSelection
        local sLo, sHi = cs and cs.lo, cs and cs.hi
        for i = 1, #FORMAT_ACTIONS do
            if FORMAT_ACTIONS[i].mode == modeKey then
                UI:ApplyEasyNotesFormat(FORMAT_ACTIONS[i], sLo, sHi)
                break
            end
        end
        return true
    end
    return false
end

-- Enter continues an active list line (bullet / checkbox / numbered) and
-- ends a header line, exactly like the notes editor.
function Fmt.HandleEditorEnterKey(editor)
    local modes = UI._notes.activeModes or {}
    if UI._notes.headerMode then
        modes.bold = nil
        UI._notes.headerMode = nil
        UI:RefreshAllEasyNotesToolbarButtons()
    end
    local prefix
    if modes.list then prefix = BULLET_PREFIX
    elseif modes.check then prefix = CHECK_EMPTY_PREFIX
    end
    if not Utils.SafeAfter then return end
    Utils.SafeAfter(0, function()
        if not editor:IsShown() then return end
        local txt = editor:GetText() or ""
        local pos = editor:GetCursorPosition() or 0
        local ins = prefix
        if not ins then
            local lsNow = FindLineStartByte(txt, pos)
            if lsNow > 2 then
                local pStart = FindLineStartByte(txt, lsNow - 2)
                local pn = txt:sub(pStart, pStart + 12):match("^(%d+)%. ")
                if pn then ins = (tonumber(pn) + 1) .. ". " end
            end
        end
        if not ins then return end
        UI._notes.inputBusy = true
        editor:SetText(txt:sub(1, pos) .. ins .. txt:sub(pos + 1))
        editor:SetCursorPosition(pos + #ins)
        UI._notes.inputBusy = nil
    end)
end

-- Single-region byte diff for the snippet host: an editbox change is always
-- one contiguous edit, so common prefix/suffix bounds it. Shifts decoration
-- ranges the way the notes editor's OnTextChanged diff does -- editing text
-- before or inside a decorated range keeps the range on the same characters.
-- startByte is 1-based inclusive, endByte exclusive; collapsed ranges drop.
function Fmt.ShiftDecorationsForEdit(decorations, oldText, newText)
    if not decorations or #decorations == 0 or oldText == newText then return end
    local oldLen, newLen = #oldText, #newText
    local minLen = oldLen < newLen and oldLen or newLen
    local p = 0
    while p < minLen and oldText:byte(p + 1) == newText:byte(p + 1) do p = p + 1 end
    local s = 0
    while s < minLen - p and oldText:byte(oldLen - s) == newText:byte(newLen - s) do s = s + 1 end
    local removed = oldLen - p - s
    local inserted = newLen - p - s
    local delta = inserted - removed
    if removed == 0 and inserted == 0 then return end
    local changeEnd = p + removed
    for i = #decorations, 1, -1 do
        local d = decorations[i]
        local sb, eb = d.startByte, d.endByte
        if sb > p then
            sb = sb > changeEnd and sb + delta or (p + inserted + 1)
        end
        if eb > p + 1 then
            eb = eb > changeEnd + 1 and eb + delta or (p + 1)
        end
        if eb <= sb then
            table.remove(decorations, i)
        else
            d.startByte, d.endByte = sb, eb
        end
    end
end

function notesNS.AttachSnippetBodyEditor(parent, opts)
    if not parent then return nil end
    opts = opts or {}
    local width = opts.width or 260
    local height = opts.height or 120

    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(width, height + TOOLBAR_H)

    local field = CreateFrame("Frame", nil, container)
    field:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    field:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)
    field:SetHeight(height)
    -- Same flat inset the snippet dialog's name/keyword fields wear.
    local fieldBg = field:CreateTexture(nil, "BACKGROUND")
    fieldBg:SetAllPoints()
    fieldBg:SetColorTexture(0, 0, 0, 0.45)

    local scroll = CreateFrame("ScrollFrame", nil, field)
    scroll:SetPoint("TOPLEFT", field, "TOPLEFT", 8, -6)
    scroll:SetPoint("BOTTOMRIGHT", field, "BOTTOMRIGHT", -8, 6)
    scroll:EnableMouseWheel(true)
    scroll:EnableMouse(true)

    local editor = CreateFrame("EditBox", nil, scroll)
    editor:SetMultiLine(true)
    editor:SetAutoFocus(false)
    editor:SetMaxLetters(opts.maxLetters or NOTES_MAX_BODY)
    editor:SetFontObject("GameFontHighlight")
    UI:ApplyEasyNotesCustomFont(editor, type(EasyNotesDB) == "table" and EasyNotesDB.fontSize or nil)
    editor:SetTextColor(0.74, 0.74, 0.78, 1)
    editor:SetJustifyH("LEFT")
    if editor.SetJustifyV then editor:SetJustifyV("TOP") end
    if editor.SetWordWrap then editor:SetWordWrap(true) end
    if editor.SetNonSpaceWrap then editor:SetNonSpaceWrap(true) end
    if editor.SetTextInsets then editor:SetTextInsets(0, 0, 0, 0) end
    if editor.SetSpacing then editor:SetSpacing(2) end
    editor:SetWidth(width - 16)
    scroll:SetScrollChild(editor)

    local toolbar = CreateFrame("Frame", nil, container)
    toolbar:SetPoint("TOPLEFT", field, "BOTTOMLEFT", 0, 0)
    toolbar:SetPoint("TOPRIGHT", field, "BOTTOMRIGHT", 0, 0)
    toolbar:SetHeight(TOOLBAR_H)

    local host = {
        container = container,
        editor = editor,
        toolbar = toolbar,
        toolbarButtons = {},
        doc = { body = "", decorations = {} },
        decoTextures = {},
        runOverlays = {},
    }
    -- BuildEasyNotesListMenu reads frame.editor for its cursor capture; give the
    -- container the same shape so the shared builder targets this editor.
    container.editor = editor

    scroll:SetScript("OnSizeChanged", function(_, w)
        if w and w > 0 then editor:SetWidth(w) end
        UI:QueueEasyNotesOverlayUpdate()
    end)
    scroll:SetScript("OnMouseDown", function() editor:SetFocus() end)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll() or 0
        local maxS = self:GetVerticalScrollRange() or 0
        local nxt = cur - delta * 40
        if nxt < 0 then nxt = 0 elseif nxt > maxS then nxt = maxS end
        self:SetVerticalScroll(nxt)
    end)

    editor:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        Fmt.SetSnippetFocus(true)
        UI:NotesBeginDrag(IsShiftKeyDown and IsShiftKeyDown())
    end)
    if editor.HasScript and editor:HasScript("OnDoubleClick") then
        editor:SetScript("OnDoubleClick", function(self)
            UI:NotesSelectWordAtCaret(self)
        end)
    end
    editor:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        -- Same deferred finalize as the notes editor: the drag's final cursor
        -- update can land after OnMouseUp, and a double-click word-select's
        -- range must survive.
        if Utils.SafeAfter then
            Utils.SafeAfter(0, function()
                if self._notesWordSelected then
                    self._notesWordSelected = nil
                    self._notesDragging = nil
                    self._notesDragAnchor = nil
                    self._notesAnchorProvisional = nil
                else
                    UI:NotesEndDrag(self:GetCursorPosition())
                end
                UI:RefreshFormatButtonStates()
            end)
        else
            UI:NotesEndDrag(self:GetCursorPosition())
            UI:RefreshFormatButtonStates()
        end
    end)
    editor:SetScript("OnEditFocusGained", function() Fmt.SetSnippetFocus(true) end)
    editor:SetScript("OnCursorChanged", function(self, _, y, _, cursorH)
        if not UI._notes.applyingFormat then
            UI:NotesRecomputeSelection(self:GetCursorPosition())
        end
        -- keep the caret line in view
        y = -(y or 0)
        cursorH = cursorH or 0
        local cur = scroll:GetVerticalScroll() or 0
        local viewH = scroll:GetHeight() or 0
        if y < cur then
            scroll:SetVerticalScroll(y)
        elseif y + cursorH > cur + viewH then
            scroll:SetVerticalScroll(y + cursorH - viewH)
        end
    end)
    editor:SetScript("OnTextChanged", function(self)
        -- Hide bold/colour overlays instantly; their positions are stale until
        -- the deferred overlay update recomputes them.
        local runPool = host.runOverlays
        for i = 1, #runPool do runPool[i]:Hide() end
        local newText = self:GetText() or ""
        if not UI._notes.applyingFormat then
            -- Format applies remap decorations themselves (applyingFormat set);
            -- every other change is a plain edit and shifts them here.
            Fmt.ShiftDecorationsForEdit(host.doc.decorations, host._lastText or "", newText)
            UI._notes.selAnchor = nil
            UI._notes.curSelection = nil
            UI._notes.lastSelection = nil
            host.doc.body = newText
        end
        host._lastText = newText
        -- Counter callback runs for programmatic changes too (undo, format
        -- applies): the shown count must always match the text.
        if opts.onTextChanged then opts.onTextChanged(self) end
        Fmt.HistoryRecord(UI._notes.applyingFormat and true or false)
        UI:QueueEasyNotesOverlayUpdate()
    end)
    editor:SetScript("OnKeyDown", function(self, key)
        local kup = tostring(key or ""):upper()
        if kup == "LEFT" or kup == "RIGHT" or kup == "UP" or kup == "DOWN"
            or kup == "HOME" or kup == "END" or kup == "PAGEUP" or kup == "PAGEDOWN" then
            UI:NotesShiftNav(IsShiftKeyDown and IsShiftKeyDown(), self:GetCursorPosition() or 0)
        end
        if IsControlKeyDown and IsControlKeyDown() then
            if Fmt.HandleEditorFormatKey(self, kup) then return end
        end
        if kup == "ENTER" then
            Fmt.HandleEditorEnterKey(self)
        end
    end)
    editor:SetScript("OnChar", function(self, c)
        if not c or c == "" then return end
        if UI._notes.inputBusy then return end
        local am = UI._notes.activeModes
        if am and (am.bold or am.italic) then
            UI._notes.keepModesOnNextRefresh = true
        end
        Fmt.ApplyTypingGlyphFormat(self, c)
    end)

    UI._notes.activeModes = UI._notes.activeModes or {}
    for i = 1, #FORMAT_ACTIONS do
        local action = FORMAT_ACTIONS[i]
        local btn = CreateFrame("Button", nil, toolbar)
        local label = action.buttonLabel or action.key
        if action.mode == "italic" and UI._notes.puaGlyphs then
            label = ITALIC_MAP[label] or label
        end
        StyleSubtleButton(btn, label, STD_BTN_W, STD_BTN_H)
        btn.tip = action.tip
        btn.actionKey = action.mode
        btn.actionIndex = i
        if btn.text then
            UI:ApplyEasyNotesCustomFont(btn.text)
        end
        if action.isListMenu then
            btn.text:Hide()
            btn.listIcon = btn:CreateTexture(nil, "OVERLAY")
            btn.listIcon:SetSize(14, 14)
            btn.listIcon:SetPoint("CENTER")
            btn.listIcon:SetTexture("Interface\\AddOns\\EasyFind_Notes\\Images\\list")
            btn.listIcon:SetVertexColor(0.84, 0.84, 0.86, 1)
            UI:BuildEasyNotesListMenu(container, btn, action.listMenu)
        end
        if action.isColor then
            btn.colorBar = btn:CreateTexture(nil, "OVERLAY")
            btn.colorBar:SetSize(11, 2)
            btn.colorBar:SetPoint("CENTER", btn, "CENTER", 0, -7)
            btn.colorBar:SetColorTexture(0.74, 0.74, 0.78, 1)
            host.colorButton = btn
        elseif action.mode == "underline" then
            btn.underBar = btn:CreateTexture(nil, "OVERLAY")
            btn.underBar:SetSize(10, 1.6)
            btn.underBar:SetPoint("CENTER", btn, "CENTER", 0, -7)
            btn.underBar:SetColorTexture(0.84, 0.84, 0.86, 1)
        elseif action.mode == "strike" then
            btn.strikeBar = btn:CreateTexture(nil, "OVERLAY")
            btn.strikeBar:SetSize(11, 1.6)
            btn.strikeBar:SetPoint("CENTER", btn, "CENTER", 0, 0)
            btn.strikeBar:SetColorTexture(0.84, 0.84, 0.86, 1)
        end
        btn:SetScript("OnMouseDown", function(self)
            -- Clicking this toolbar targets the snippet doc; the swap (a no-op
            -- when already focused) must land before the selection capture.
            Fmt.SetSnippetFocus(true)
            local cs = UI._notes.curSelection
            self._capturedLo = cs and cs.lo or nil
            self._capturedHi = cs and cs.hi or nil
            self._capturedCursor = editor:GetCursorPosition() or 0
        end)
        btn:SetScript("OnClick", function(self)
            if action.isListMenu then
                UI:ToggleEasyNotesListMenu(self)
                return
            end
            UI:ApplyEasyNotesFormat(action, self._capturedLo, self._capturedHi, self._capturedCursor)
            self._capturedLo, self._capturedHi, self._capturedCursor = nil, nil, nil
        end)
        btn:SetScript("OnEnter", function(self)
            self._hover = true
            UI:RefreshEasyNotesToolbarButton(self)
            UI:ShowNotesTipDelayed(self, "ANCHOR_TOP")
        end)
        btn:SetScript("OnLeave", function(self)
            self._hover = nil
            UI:RefreshEasyNotesToolbarButton(self)
            if GameTooltip then GameTooltip:Hide() end
        end)
        host.toolbarButtons[i] = btn
        UI:RefreshEasyNotesToolbarButton(btn)
    end

    local function LayoutToolbar()
        local n = #host.toolbarButtons
        if n == 0 then return end
        local pad, gap = 8, 4
        local totalW = n * STD_BTN_W + (n - 1) * gap
        local barW = toolbar:GetWidth() or 0
        if barW <= 0 then barW = width end
        local x = math.max(pad, (barW - totalW) / 2)
        for i = 1, n do
            local toolbarBtn = host.toolbarButtons[i]
            toolbarBtn:ClearAllPoints()
            toolbarBtn:SetPoint("LEFT", toolbar, "LEFT", x, 0)
            toolbarBtn:SetWidth(STD_BTN_W)
            x = x + STD_BTN_W + gap
        end
    end
    toolbar:SetScript("OnSizeChanged", LayoutToolbar)
    LayoutToolbar()
    container:SetScript("OnShow", function() UI:QueueEasyNotesOverlayUpdate() end)

    function host:SetDocument(doc)
        doc = doc or {}
        local copy = { body = doc.body or "", decorations = {} }
        if type(doc.decorations) == "table" then
            for i = 1, #doc.decorations do
                local d = doc.decorations[i]
                copy.decorations[i] = { kind = d.kind, startByte = d.startByte,
                    endByte = d.endByte, r = d.r, g = d.g, b = d.b }
            end
        end
        self.doc = copy
        self._lastText = copy.body
        UI._notes.applyingFormat = true
        editor:SetText(copy.body)
        UI._notes.applyingFormat = nil
        UI._notes.selAnchor = nil
        UI._notes.curSelection = nil
        UI._notes.lastSelection = nil
        UI:QueueEasyNotesOverlayUpdate()
    end

    function host:GetDocument()
        return { body = editor:GetText() or "", decorations = self.doc.decorations }
    end

    UI._notes.snippetHost = host
    return host
end

-- Plain-text projection of a document: styled glyphs collapse to ASCII,
-- decorations drop, list prefixes stay (they are plain UTF-8).
function notesNS.FlattenDocument(doc)
    if type(doc) ~= "table" then return "" end
    return MapSelection(doc.body or "", GlyphPlain)
end

-- Markdown tokens (**bold**, *italic*, __underline__, ~~strike~~) to the live
-- notes model: bold/italic become char-replace glyphs, underline/strike become
-- decorations with byte ranges measured against the TRANSFORMED body (1-based
-- start, exclusive end).
function notesNS.DocumentFromMarkdown(text)
    local plain, runs = UI:ParseMarkdown(type(text) == "string" and text or "")
    local segments, decorations = {}, {}
    local transformedLen = 0
    for i = 1, #runs do
        local run = runs[i]
        local segment = plain:sub(run.s, run.e)
        if run.bold then segment = MapSelection(segment, AddBold) end
        if run.italic then segment = MapSelection(segment, AddItalic) end
        segments[#segments + 1] = segment
        if run.underline then
            decorations[#decorations + 1] = { kind = "underline",
                startByte = transformedLen + 1, endByte = transformedLen + #segment + 1 }
        end
        if run.strike then
            decorations[#decorations + 1] = { kind = "strike",
                startByte = transformedLen + 1, endByte = transformedLen + #segment + 1 }
        end
        transformedLen = transformedLen + #segment
    end
    MergeAdjacentDecorations(decorations)
    return { body = table.concat(segments), decorations = decorations }
end

-- Inserts a document into the NOTES editor at its caret. Insert first: the
-- OnTextChanged diff shifts EXISTING decorations for the insertion; the
-- document's decorations are appended afterwards, shifted by the pre-insert
-- caret offset.
function notesNS.InsertDocumentAtCursor(doc)
    if type(doc) ~= "table" or type(doc.body) ~= "string" or doc.body == "" then
        return false
    end
    local frame = UI._notes.frame
    if not (frame and frame:IsShown()) then
        UI:OpenEasyNotes()
        frame = UI._notes.frame
    end
    local editor = frame and frame.editor
    if not editor then return false end
    Fmt.SetSnippetFocus(false)
    local caretBefore = editor:GetCursorPosition() or 0
    editor:SetFocus()
    editor:Insert(doc.body)
    local decos = doc.decorations
    if type(decos) == "table" and #decos > 0 then
        local note = GetSelectedNote()
        if note then
            note.decorations = note.decorations or {}
            for i = 1, #decos do
                local d = decos[i]
                note.decorations[#note.decorations + 1] = {
                    kind = d.kind,
                    startByte = caretBefore + d.startByte,
                    endByte = caretBefore + d.endByte,
                    r = d.r, g = d.g, b = d.b,
                }
            end
            MergeAdjacentDecorations(note.decorations)
            note.updated = time()
        end
        UI:QueueEasyNotesOverlayUpdate()
    end
    return true
end

-- Public: EasyFind snippets insert their body here. Snippet bodies carry
-- markdown tokens; the live notes model does not, so they are CONVERTED on the
-- way in -- inserting them raw would show literal asterisks.
function notesNS.InsertAtCursor(text)
    if type(text) ~= "string" or text == "" then return false end
    return notesNS.InsertDocumentAtCursor(notesNS.DocumentFromMarkdown(text))
end
