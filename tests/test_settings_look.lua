-- The settings window's controls (Apps/Options/OptionsPanel.lua, Shared/Utils.lua):
-- its buttons carry a ring in the theme's dark tone (on light themes they
-- blended into the panel), every search field has the settings search's
-- look (four were button-gray pills), and the export's include list drops
-- down under its button like the other selectors (it opened to the side).
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local s = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return s
end

local function Frame()
    local f = { shown = true, cbBarHeight = 10 }
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:IsShown() return self.shown end
    function f:GetFrameLevel() return 5 end
    function f:HookScript(_, fn) self.onShow = fn end
    -- Any method answers; fields (underscored) are only what was set.
    return setmetatable(f, { __index = function(_, k)
        if k:sub(1, 1) == "_" then return nil end
        return function() end
    end })
end

local function LoadRing(surface, classic)
    local src = Read("Shared/Utils.lua")
    local s = assert(src:find("ns.RingedButtons = ", 1, true), "the ring")
    local e = assert(src:find("-- A theme flip repaints every button", s, true), "the ring's end")
    local painted
    local ns = {
        ThemeSurfaceOf = function() return surface end,
        IsClassicChrome = function() return classic end,
        ThemeSetOf = function() return { EDITBOX_INSET_FILL = { 0.1, 0.2, 0.3 } } end,
        EDITBOX_INSET_FILL = { 0, 0, 0 },
        CreateRoundedRectBorder = function() end, SetRoundedRectBarHeight = function() end,
        SetRoundedRectRingShown = function() end,
        SetRoundedRectFill = function(_, r, g, b) painted = { r, g, b } end,
    }
    local env = setmetatable({ ns = ns, CreateFrame = function() return Frame() end }, { __index = _G })
    assert(load(src:sub(s, e - 1), "=Utils.lua ring", "t", env))()
    return ns, function() return painted end
end

local tests = {}

function tests.settingsButtonsCarryTheThemesDarkRing()
    local ns, painted = LoadRing("options", false)
    local btn = Frame()
    ns.RingButton(btn)
    H.assertNotNil(btn._efRing, "a ring under the button")
    H.assertTrue(btn._efRing:IsShown())
    H.assertDeepEq(painted(), { 0.1, 0.2, 0.3 }, "the theme's dark inset tone")
    H.assertNotNil(btn.onShow, "set again as the button shows (its window known then)")
end

function tests.otherWindowsAndTheClassicSkinHaveNone()
    local ns = LoadRing("results", false)
    local btn = Frame()
    ns.RingButton(btn)
    H.assertNil(btn._efRing, "only the settings window's buttons")
    local classicNs = LoadRing("options", true)
    local red = Frame()
    classicNs.RingButton(red)
    H.assertNil(red._efRing, "the Classic skin's red buttons keep their own art")
end

function tests.everySearchFieldHasTheSettingsSearchLook()
    local src = Read("Apps/Options/OptionsPanel.lua")
    for _, shell in ipairs({ "aliasSearchShell", "blSearchShell", "snSearchShell", "searchShell", "shell" }) do
        H.assertTrue(src:find("SearchWell(" .. shell .. ")", 1, true) ~= nil, shell .. " is a search well")
    end
    H.assertNil(src:find("PaintControlFill%(%w*[Ss]earchShell"), "no search field on a button's fill")
end

function tests.theIncludeListDropsDownUnderItsButton()
    local src = Read("Apps/Options/OptionsPanel.lua")
    H.assertNil(src:find("EasyFindProfileIncludePopup", 1, true), "not the filter menu's side pop-out")
    H.assertTrue(src:find('AddFlyoutChecks(CreateFlyoutPanel(inclBtn, "EasyFindProfileInclude"', 1, true) ~= nil,
        "a flyout of checks under the button")
end

local pass, fail, failures = H.runSuite("SettingsLook", tests)
return { pass = pass, fail = fail, failures = failures }
