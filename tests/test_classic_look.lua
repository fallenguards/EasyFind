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
    for _, rel in ipairs({ "Apps/Notes/Notes.lua", "Apps/GPS/GPS.lua", "Apps/Onboarding/TutorialWizard.lua" }) do
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

function tests.notesStepsInFromTheIronFrame()
    local src = Read("Apps/Notes/Notes.lua"):gsub("\r\n", "\n")
    local s = assert(src:find("\nlocal CHROME_PAD = 10\nfunction UI:LayoutEasyNotesChrome(dressed)", 1, true))
    local _, e = assert(src:find("\nend\n", s + 30, true))
    local calls, sized = {}, nil
    local function Piece(name)
        return { ClearAllPoints = function() end,
                 SetPoint = function(_, p, _, _, x, y) calls[#calls + 1] = name .. ":" .. p .. ":" .. x .. "," .. y end }
    end
    local frame = { header = Piece("header"), footer = Piece("footer"), palette = Piece("palette"),
                    findBar = Piece("findBar"), resizeGrip = Piece("grip"), headerPanel = Piece("panel"),
                    GetWidth = function() return 300 end, GetHeight = function() return 200 end,
                    SetSize = function(_, w, h) sized = { w, h } end, SetResizeBounds = function() end }
    local UI = { _notes = { frame = frame }, UpdateEasyNotesEditorTop = function() end }
    local env = setmetatable({ UI = UI, ns = { CLASSIC_WINDOW_OUTSET = 12 }, MIN_WIDTH = 220, MIN_HEIGHT = 140,
                               HEADER_H = 30, FOOTER_H = 20 }, { __index = _G })
    assert(load(src:sub(s, e), "=LayoutEasyNotesChrome", "t", env))()
    UI:LayoutEasyNotesChrome(true)
    H.assertEq(sized[1], 320); H.assertEq(sized[2], 220)
    H.assertEq(UI._notes.chromePad, 10)
    local joined = table.concat(calls, " ")
    H.assertTrue(joined:find("header:TOPLEFT:10,-10", 1, true) ~= nil, "the header steps in")
    H.assertTrue(joined:find("footer:BOTTOMRIGHT:-10,10", 1, true) ~= nil, "the footer too")
    H.assertTrue(joined:find("palette:TOPLEFT:22,-44", 1, true) ~= nil, "the list keeps its own inset plus the pad")
    H.assertTrue(joined:find("grip:BOTTOMRIGHT:-12,12", 1, true) ~= nil)
    H.assertTrue(joined:find("panel:TOPRIGHT:-11,0", 1, true) ~= nil, "the side panel clears the metal hung outside")
    sized, calls = nil, {}
    UI:LayoutEasyNotesChrome(false)
    H.assertEq(sized[1], 280, "shrunk back by the pad"); H.assertEq(sized[2], 180)
    H.assertTrue(table.concat(calls, " "):find("header:TOPLEFT:0,0", 1, true) ~= nil, "flush without the art")
end

local pass, fail, failures = H.runSuite("ClassicLook", tests)
return { pass = pass, fail = fail, failures = failures }
