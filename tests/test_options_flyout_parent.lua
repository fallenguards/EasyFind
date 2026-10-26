-- A settings dropdown's list belongs to the settings window, not to its
-- button: an extension's page scrolls, and its scroll frame cut a list off
-- at the window's edge (2026-10-26). The list still knows its button, and
-- hides with it (CreateFlyoutPanel, Apps/Options/OptionsPanel.lua).
local H = require("Harness")

local tests = {}

function tests.aDropdownListIsTheWindows_andKnowsItsButton()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Options/OptionsPanel.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local function CreateFlyoutPanel(", 1, true))
    local body = src:sub(s, select(2, assert(src:find("\nend\r?\n", s))))
    H.assertTrue(body:find('CreateFrame("Frame", globalPrefix .. "Flyout", optionsFrame or btnFrame', 1, true) ~= nil,
        "parented to the window")
    H.assertTrue(body:find("flyout._efButton = btnFrame", 1, true) ~= nil, "it knows its button")
    H.assertTrue(body:find('btnFrame:HookScript("OnHide"', 1, true) ~= nil, "and hides with it")
    H.assertTrue(src:find("flyout._efButton or flyout:GetParent()", 1, true) ~= nil,
        "the search bar's settings rows find the button through it")
end

local pass, fail, failures = H.runSuite("OptionsFlyoutParent", tests)
return { pass = pass, fail = fail, failures = failures }
