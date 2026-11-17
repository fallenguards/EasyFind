-- "Show me how" for an item in the bags (Forever, 2026-11-17): the guide
-- lit the bag button and stayed there once the bags were open, as its step
-- moved on only for a window or the game menu (Apps/Guide/Highlight.lua
-- HandleGuideButtonFrame). The bags open where the item lies: on to its slot.
local H = require("Harness")

local function Load(steps)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Guide/Highlight.lua", "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    local s = assert(src:find("local function HandleGuideButtonFrame", 1, true), "the button step")
    local e = assert(src:find("local function HandleGuidePortraitMenu", s, true), "its end")
    local bagButton = { IsShown = function() return true end, IsMouseOver = function() return false end }
    local env = setmetatable({ MainMenuBarBackpackButton = bagButton }, { __index = _G })
    env._G = env
    local chunk = "local ns, Utils, currentGuide, currentStepIndex, canHoverDismiss = ...\n"
        .. src:sub(s, e - 1) .. "\nreturn HandleGuideButtonFrame"
    local ns = { SearchOpeners = {} }
    local Utils = { GetFrameByPath = function() return nil end }
    return assert(load(chunk, "=Highlight.lua bag step", "t", env))(ns, Utils, { steps = steps }, 1,
        function() return false end)
end

local function Guide(open)
    local g = { advanced = false, lit = false }
    function g:FindContainerSlotButton(bag, slot)
        if open and bag == 0 and slot == 5 then return { IsVisible = function() return true end } end
    end
    function g:AdvanceStep() self.advanced = true end
    function g:HighlightFrame() self.lit = true end
    return g
end

local tests = {}

function tests.theBagsOpen_movesOnToTheItemsSlot()
    local steps = {
        { buttonFrame = "MainMenuBarBackpackButton" },
        { containerBag = 0, containerSlot = 5, allLocations = { { bag = 3, slot = 1 }, { bag = 0, slot = 5 } } },
    }
    local step = Load(steps)
    local shut = Guide(false)
    step(shut, steps[1])
    H.assertFalse(shut.advanced, "bags shut: still on the bag button")
    H.assertTrue(shut.lit, "the bag button lit")
    local open = Guide(true)
    step(open, steps[1])
    H.assertTrue(open.advanced, "bags open with the item in view: on to its slot")
end

local pass, fail, failures = H.runSuite("GuideBagItem", tests)
return { pass = pass, fail = fail, failures = failures }
