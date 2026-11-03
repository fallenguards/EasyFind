-- The Classic theme's own controls (the red buttons, Era's lists and
-- sliders, gold list names) follow the theme itself (ns.ClassicLook);
-- only the frame art follows the border choice (ns.IsClassicChrome).
-- Picking the line border for the search bar took the red buttons off
-- every window, Notes included (2026-10-27).
-- Under a Classic talent tree with the line border, a window's corners
-- go square: the ring rounded over the art's square corners read as a
-- border drawn behind it.
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
    for _, rel in ipairs({ "Apps/Onboarding/TutorialWizard.lua" }) do
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

local pass, fail, failures = H.runSuite("ClassicLook", tests)
return { pass = pass, fail = fail, failures = failures }
