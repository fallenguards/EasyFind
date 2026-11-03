-- The Classic theme's own controls (the red buttons, Era's lists and
-- sliders, gold list names) follow the theme itself (ns.ClassicLook);
-- only the frame art follows the border choice (ns.IsClassicChrome).
-- Picking the line border for the search bar took the red buttons off
-- every window, Notes included (2026-10-27).
-- Under a Classic talent tree with the line border, a window's corners
-- go square: the ring rounded over the art's square corners read as a
-- border drawn behind it.
-- The Notes window dressed in the iron frame steps its contents in by a
-- pad and grows by it, so the toolbar and buttons clear the metal's lip.
local H = require("Harness")

local function Read(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local tests = {}

function tests.controlsFollowTheThemeNotTheBorder()
    local utils = Read("Shared/Utils.lua")
    H.assertTrue(utils:find('function ns%.ClassicLook%(%)%s+local p = ns%.ACTIVE_UI_PALETTE%s+return p ~= nil and p%.chrome == "classic"%s+end') ~= nil)
    -- The button painters ask the look, never the art.
    H.assertTrue(utils:find("if btn%._efPaintState and %(ns%.ClassicLook%(%) or btn%._efRedOn%) then") ~= nil)
    H.assertTrue(utils:find("local function PaintState%(self, fillTable%)%s+if ns%.ClassicLook%(%) then") ~= nil)
    for _, rel in ipairs({ "Apps/Notes/Notes.lua", "Apps/Onboarding/TutorialWizard.lua" }) do
        local src = Read(rel)
        H.assertNil(src:find("IsClassicChrome() and ns.PaintRedButton", 1, true), rel .. ": red buttons by the look")
    end
    local options = Read("Apps/Options/OptionsPanel.lua")
    H.assertTrue(options:find("local function DressSelector%(btn%)%s+local classic = ns%.ClassicLook%(%)") ~= nil, "Era's selector")
    H.assertTrue(options:find("bgRow:SetGroupEnabled%(ns%.ClassicLook%(%) and true or false%)") ~= nil, "the tree row by the theme")
    -- The frame art keeps asking the art switch.
    H.assertTrue(options:find("local pad = ns%.IsClassicChrome%(%) and CLASSIC_EDGE or 10") ~= nil)
    H.assertTrue(utils:find("function ns%.ApplyClassicHeader%(frame, title%)%s+if not frame then return end%s+local on = ns%.IsClassicChrome%(%)") ~= nil)
end

function tests.squareCornersUnderATree()
    local utils = Read("Shared/Utils.lua")
    H.assertTrue(utils:find("local cornerSize = frame%._efUnderTree and 1 or h / 2") ~= nil, "the corner size squares under the tree")
    H.assertTrue(utils:find("frame%._efUnderTree = true%s+ns%.SetRoundedRectBarHeight%(frame, frame%.cbBarHeight%)") ~= nil, "squared as the tree goes under")
    H.assertTrue(utils:find("frame%._efUnderTree = nil%s+for _, t in pairs%(frame%.combinedBorder%.fill%) do t:SetAlpha%(frame%._efBgAlpha or 1%) end%s+ns%.SetRoundedRectBarHeight%(frame, frame%.cbBarHeight%)") ~= nil, "round again off it")
end

-- The frame art hangs outside the window, so the contents keep their own
-- margins under it: a 10 pad on top of them read as huge margins on the
-- Forever and Classic themes (2026-11-02). The formatting toolbar is the
-- window's bottom row, the footer over it while it shows.
function tests.notesKeepTheirMarginsInsideTheFrameArt()
    local src = Read("Apps/Notes/Notes.lua"):gsub("\r\n", "\n")
    local s = assert(src:find("\nlocal CHROME_PAD = 0\nfunction UI:LayoutEasyNotesChrome(dressed)", 1, true))
    local _, e = assert(src:find("\nend\n", s + 30, true))
    local calls, sized = {}, nil
    local function Piece(name)
        return { ClearAllPoints = function() end,
                 SetPoint = function(_, p, _, _, x, y) calls[#calls + 1] = name .. ":" .. p .. ":" .. x .. "," .. y end }
    end
    local frame = { header = Piece("header"), footer = Piece("footer"), palette = Piece("palette"),
                    findBar = Piece("findBar"), resizeGrip = Piece("grip"), headerPanel = Piece("panel"),
                    toolbar = Piece("toolbar"),
                    GetWidth = function() return 300 end, GetHeight = function() return 200 end,
                    SetSize = function(_, w, h) sized = { w, h } end, SetResizeBounds = function() end }
    local UI = { _notes = { frame = frame }, UpdateEasyNotesEditorTop = function() end }
    local room = 28
    local env = setmetatable({ UI = UI, ns = { CLASSIC_WINDOW_OUTSET = 12 }, MIN_WIDTH = 220, MIN_HEIGHT = 140,
                               HEADER_H = 30, FOOTER_H = 20, Fmt = { ToolbarRoom = function() return room end } },
                             { __index = _G })
    assert(load(src:sub(s, e), "=LayoutEasyNotesChrome", "t", env))()
    UI:LayoutEasyNotesChrome(true)
    H.assertNil(sized, "the window keeps its size under the art")
    H.assertEq(UI._notes.chromePad, 0)
    local joined = table.concat(calls, " ")
    H.assertTrue(joined:find("header:TOPLEFT:0,0", 1, true) ~= nil, "the header at its own place")
    H.assertTrue(joined:find("toolbar:BOTTOMLEFT:0,0", 1, true) ~= nil, "the toolbar the whole bottom row")
    H.assertTrue(joined:find("toolbar:BOTTOMRIGHT:0,0", 1, true) ~= nil)
    H.assertTrue(joined:find("footer:BOTTOMLEFT:0,28", 1, true) ~= nil, "the footer over the toolbar")
    H.assertTrue(joined:find("panel:TOPRIGHT:-11,0", 1, true) ~= nil, "the side panel clears the metal hung outside")
    calls, room = {}, 0
    UI:LayoutEasyNotesChrome(false)
    H.assertTrue(table.concat(calls, " "):find("footer:BOTTOMLEFT:0,0", 1, true) ~= nil, "no toolbar: the footer at the bottom")
end

-- The toolbar's row joins the window: 10 tall plus a 2 row is 12, the top
-- held, the border round the whole; off again it is 10 (2026-11-02).
function tests.notesToolbarGrowsTheWindowByItsRow()
    local src = Read("Apps/Notes/Notes.lua"):gsub("\r\n", "\n")
    local s = assert(src:find("\nfunction UI:ToggleEasyNotesToolbar()", 1, true))
    local _, e = assert(src:find("\nend\n", s + 30, true))
    local log = {}
    local frame = { h = 200, toolbar = { SetShown = function(_, v) log[#log + 1] = "shown:" .. tostring(v) end },
                    IsShown = function() return true end,
                    GetHeight = function(self) return self.h end,
                    SetHeight = function(self, h) log[#log + 1] = "height"; self.h = h end }
    local UI = { _notes = { frame = frame, toolbarShown = false, paletteShown = false,
                            PinTopLeftAnchor = function() log[#log + 1] = "pin" end },
                 LayoutEasyNotesChrome = function() end, UpdateEasyNotesAutoResize = function() end }
    local db = {}
    local env = setmetatable({ UI = UI, TOOLBAR_H = 28, NormalizeDB = function() return db end,
                               notesNS = { Windows = { Each = function(fn) fn() end } } }, { __index = _G })
    assert(load(src:sub(s, e), "=ToggleEasyNotesToolbar", "t", env))()
    UI:ToggleEasyNotesToolbar()
    H.assertEq(frame.h, 228, "the row added under the note")
    H.assertEq(table.concat(log, " "), "shown:true pin height", "pinned by its top before it grows")
    H.assertEq(db.toolbarShown, true)
    UI:ToggleEasyNotesToolbar()
    H.assertEq(frame.h, 200, "back to the note's own height")
    UI._notes.paletteShown, log = true, {}
    UI:ToggleEasyNotesToolbar()
    H.assertEq(frame.h, 200, "the notes list has no toolbar row")
    H.assertEq(table.concat(log, " "), "shown:false")
end

-- Note cards under the Classic frame: Era's thin edge on the window's own
-- ground, light gray inside it under the mouse or picked (mock A,
-- 2026-11-02); the gray card read modern on the marble. Under the Forever
-- frame the same edge in its bronze, the theme's fill only under the mouse
-- or picked (the filled card read heavy, 2026-11-03).
function tests.notesCardsWearTheThinEdgeUnderClassicAndForever()
    local src = Read("Apps/Notes/Notes.lua"):gsub("\r\n", "\n")
    local s = assert(src:find("\nUI.CLASSIC_CARD = {", 1, true))
    local _, e = assert(src:find("\nend\n", assert(src:find("function UI.PaintNotesCardEdge", s, true)), true))
    local made
    local function NewEdge()
        local edge = { shown = false }
        function edge:SetAllPoints() end
        function edge:SetBackdrop(b) self.backdrop = b end
        function edge:SetBackdropBorderColor(r, g, b, a) self.border = { r, g, b, a } end
        function edge:SetBackdropColor(r, g, b, a) self.fill = { r, g, b, a } end
        function edge:SetFrameLevel(l) self.level = l end
        function edge:Show() self.shown = true end
        function edge:Hide() self.shown = false end
        made = edge
        return edge
    end
    local tree = false
    local ns = { CLASSIC_THIN = { edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16, insets = { left = 4 } },
                 FOREVER_BRONZE = { 0.78, 0.55, 0.30, 0.95 },
                 ACTIVE_UI_PALETTE = { separator = { 0.5, 0.4, 0.3, 0.35 } }, ClassicTreeShown = function() return tree end }
    local UI = {}
    local env = setmetatable({ UI = UI, ns = ns, CreateFrame = function() return NewEdge() end }, { __index = _G })
    assert(load(src:sub(s, e), "=PaintNotesCardEdge", "t", env))()
    local row = { GetFrameLevel = function() return 7 end }
    UI.PaintNotesCardEdge(row, "classic", false, false)
    H.assertEq(made.backdrop.edgeFile, ns.CLASSIC_THIN.edgeFile, "the thin Era edge")
    H.assertEq(made.backdrop.insets, ns.CLASSIC_THIN.insets, "its fill inside the line")
    H.assertTrue(math.abs(made.border[1] - 0.55) < 1e-9 and math.abs(made.border[3] - 0.33) < 1e-9, "the search ring's tan")
    H.assertEq(made.fill[4], 0, "no fill: the window's ground shows")
    H.assertEq(made.level, 6, "under the card's words")
    UI.PaintNotesCardEdge(row, "classic", true, false)
    H.assertTrue(made.fill[1] > 0.3 and made.fill[4] > 0.9, "light gray under the mouse")
    UI.PaintNotesCardEdge(row, "classic", false, true)
    H.assertTrue(made.fill[1] > 0.4, "lighter when picked")
    tree = true
    UI.PaintNotesCardEdge(row, "classic", false, false)
    H.assertEq(made.fill[1], 0, "over a tree the dark card keeps the words readable")
    H.assertTrue(made.fill[4] > 0.5)
    tree = false
    local hover = { 0.6, 0.45, 0.25, 1 }
    UI.PaintNotesCardEdge(row, "forever", false, false, hover)
    H.assertEq(made.border[1], 0.78, "Forever's bronze")
    H.assertEq(made.fill[4], 0, "at rest no fill under Forever either")
    UI.PaintNotesCardEdge(row, "forever", true, false, hover)
    H.assertEq(made.fill[1], 0.6, "the theme's own fill under the mouse")
    UI.PaintNotesCardEdge(row, "forever", false, true, hover)
    H.assertEq(made.fill[1], 0.6, "and picked")
    UI.PaintNotesCardEdge(row, nil)
    H.assertFalse(made.shown, "off those frames: no edge")
    local paint = src:sub((assert(src:find("local function PaintPaletteRow(row)", 1, true))))
    H.assertTrue(paint:find("local skin = row._efWindow ~= nil and row._efWindow._efSkin or nil", 1, true) ~= nil,
        "by the card's own window's frame")
    H.assertTrue(paint:find("UI.PaintNotesCardEdge(row, skin, over, selected, c)", 1, true) ~= nil,
        "Forever keeps its fills for hover and picked")
    H.assertTrue(Read("Apps/Notes/Lines.lua"):find('local edged = skin == "classic" or skin == "forever"', 1, true) ~= nil,
        "the shopping offer card too")
end

local pass, fail, failures = H.runSuite("ClassicLook", tests)
return { pass = pass, fail = fail, failures = failures }
