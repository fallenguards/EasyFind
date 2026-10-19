-- Tests for the notes list rows' tag pills (Apps/Notes/Notes.lua
-- UI:LayoutEasyNotesRowTags): the tags take at most half the row, so the
-- note's name always shows; the rest go into "+N".

local H = require("Harness")

local function Text()
    local fs = { text = "", w = 0 }
    function fs:SetText(v) self.text = v end
    function fs:GetText() return self.text end
    function fs:SetWidth(w) self.w = w end
    function fs:GetUnboundedStringWidth() return #self.text * 6 end
    function fs:GetStringWidth() return self.w > 0 and math.min(self.w, #self.text * 6) or #self.text * 6 end
    function fs:SetTextColor() end
    function fs:SetWordWrap() end
    function fs:SetPoint() end
    return fs
end

local function Pill()
    local p = { shown = false, w = 0, x = 0, text = Text() }
    function p:SetWidth(w) self.w = w end
    function p:GetWidth() return self.w end
    function p:ClearAllPoints() end
    function p:SetPoint(_, _, _, x) self.x = x end
    function p:Show() self.shown = true end
    function p:Hide() self.shown = false end
    function p:SetScript() end
    function p:SetHeight() end
    function p:CreateFontString() return Text() end
    return p
end

local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Notes/Notes.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("do\r?\n%s*local function MakeRowTagPill"), "the row tags' block not in Notes.lua")
    local _, e = src:find("\nend\r?\n", s)
    local UI = {}
    local env = setmetatable({
        UI = UI, ns = {}, mmin = math.min, mmax = math.max, slower = string.lower,
        CreateFrame = function() return Pill() end,
        TagColor = function() return { 0.5, 0.5, 0.5 } end,
        CtxKey = function(t) return t.name end,
    }, { __index = _G })
    assert(load(src:sub(s, e), "=Notes.lua LayoutEasyNotesRowTags", "t", env))()
    return UI
end

local function Row()
    local row = { title = { right = 0 } }
    function row.title:SetPoint(_, _, _, x) self.right = x end
    function row:GetWidth() return 0 end
    return row
end

-- The left edge of the leftmost shown pill, from the row's right edge.
local function LeftEdge(row)
    local left = 0
    for _, p in ipairs(row.tagPills) do
        if p.shown then left = math.min(left, p.x - p.w) end
    end
    if row.tagMore and row.tagMore.shown then left = math.min(left, row.tagMore.x - row.tagMore.w) end
    return left
end

local tests = {}

function tests.ownTagsLeadAsWords()
    local UI = Load()
    local row = Row()
    local note = { tags = { "raid" }, appliesIn = { { name = "Orgrimmar" } } }
    UI:LayoutEasyNotesRowTags(row, note, 400)
    H.assertEq(row.tagPills[1].text.text, "#raid", "the note's own tag first, as a word")
    H.assertEq(row.tagPills[2].text.text, "Orgrimmar", "then where it shows")
end

function tests.longTagsOnANarrowRowLeaveTheNameHalf()
    local UI = Load()
    local row = Row()
    local note = { appliesIn = { { name = "Another Hunterz Place" }, { name = "Alterac Mountains" } } }
    UI:LayoutEasyNotesRowTags(row, note, 200)
    H.assertTrue(LeftEdge(row) >= -(10 + 89), "the tags within half the row")
    H.assertTrue(row.title.right >= -(10 + 89 + 4 + 3), "the name keeps the other half")
    H.assertTrue(row.tagMore.shown, "the tag that did not fit is in +N")
    H.assertEq(row.tagMore.text.text, "+1")
end

function tests.shortTagsAllShow()
    local UI = Load()
    local row = Row()
    UI:LayoutEasyNotesRowTags(row, { appliesIn = { { name = "ICC" }, { name = "AH" } } }, 300)
    H.assertTrue(row.tagPills[1].shown and row.tagPills[2].shown)
    H.assertFalse(row.tagMore.shown)
end

function tests.noTagsTheNameRunsToTheEdge()
    local UI = Load()
    local row = Row()
    UI:LayoutEasyNotesRowTags(row, { appliesIn = {} }, 200)
    H.assertEq(row.title.right, -12)
end

local pass, fail, failures = H.runSuite("NotesRowTags", tests)
return { pass = pass, fail = fail, failures = failures }
