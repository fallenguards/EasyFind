-- The settings window's controls (Apps/Options/OptionsPanel.lua, Shared/Utils.lua):
-- its buttons ramp dark at their top against the window's ramp dark at its
-- bottom (flat they blended in; a ring round each looked rough), every
-- search field has the settings search's look (four were button-gray
-- pills), and the export's include list drops
-- down under its button like the other selectors (it opened to the side).
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local s = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return s
end

local function fakeWidget()
    local w = {}
    setmetatable(w, { __index = function() return function() return w end end })
    return w
end

-- A frame whose textures keep their color (Utils caches CreateFrame).
local function Paintable()
    local f = { textures = {} }
    function f:IsMouseOver() return false end
    function f:CreateTexture()
        local t = {}
        function t:SetVertexColor(r, g, b) self.rgb = { r, g, b } end
        self.textures[#self.textures + 1] = t
        return setmetatable(t, { __index = function() return function() end end })
    end
    return setmetatable(f, { __index = function(_, k)
        if type(k) == "string" and k:match("^%u") then return function() end end
    end })
end

-- The real Shared/Utils.lua, its surface and skin answered by the test.
local function LoadRamp(surface, classic)
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.CreateFrame = function() return env.paintable and Paintable() or fakeWidget() end
    env.CreateFont = fakeWidget
    env.CreateColor = function(r, g, b, a) return { r, g, b, a } end
    env.UIParent, env.WorldFrame, env.GameTooltip = fakeWidget(), fakeWidget(), fakeWidget()
    env.hooksecurefunc = function() end
    env.GameFontNormal = setmetatable({}, { __index = function(_, k)
        if k == "GetFont" then return function() return "font", 12, "" end end
        return function() end
    end })
    H.loadModule("Shared/Utils.lua", env, ns)
    ns.ThemeSurfaceOf = function() return surface end
    ns.IsClassicChrome = function() return classic end
    return ns, env
end

-- A button's nine fill pieces, each keeping its flat color or its ramp.
local function Button()
    local cells = {}
    for _, k in ipairs({ "tl", "tm", "tr", "ml", "mm", "mr", "bl", "bm", "br" }) do
        local c = {}
        function c:SetVertexColor(r, g, b, a) self.flat, self.top, self.bottom = { r, g, b, a }, nil, nil end
        function c:GetVertexColor() return (table.unpack or unpack)(self.flat) end
        function c:SetGradient(_, bottom, top) self.bottom, self.top = bottom, top end
        cells[k] = setmetatable(c, { __index = function(_, m)
            if type(m) == "string" and m:match("^%u") then return function() end end
        end })
    end
    local b = { combinedBorder = { fill = cells }, cbBarHeight = 10, hooks = {} }
    function b:GetHeight() return 22 end
    function b:HookScript(k, fn) self.hooks[k] = fn end
    return b
end

local function Near(a, b) return math.abs(a - b) < 1e-6 end

local tests = {}

function tests.settingsButtonsRampDarkAtTheirTop()
    local ns = LoadRamp("options", false)
    local btn = Button()
    ns.SetRoundedRectBorderFillColor(btn, 0.2, 0.3, 0.4, 1)
    ns.RampButton(btn)
    local fill = btn.combinedBorder.fill
    H.assertTrue(btn._efRamp, "a settings button ramps")
    H.assertTrue(Near(fill.tm.top[1], 0.2 * 0.65), "dark at its top")
    H.assertTrue(Near(fill.bm.bottom[1], 0.2 * 1.2), "its own color, a step lighter, at the bottom")
    H.assertTrue(fill.mm.top[1] > fill.tm.top[1] and fill.mm.bottom[1] < fill.bm.bottom[1], "one ramp across the pieces")
    H.assertNotNil(btn.hooks.OnShow, "set again as the button shows (its window known then)")
end

-- Hover and the theme's repaint go through either fill setter.
function tests.everyRepaintKeepsTheRamp()
    local ns = LoadRamp("options", false)
    local btn = Button()
    ns.SetRoundedRectBorderFillColor(btn, 0.2, 0.2, 0.2, 1)
    ns.RampButton(btn)
    ns.SetRoundedRectBorderFillColor(btn, 0.4, 0.4, 0.4, 1)
    H.assertTrue(Near(btn.combinedBorder.fill.tm.top[1], 0.4 * 0.65), "the hover color ramps")
    ns.SetRoundedRectFill(btn, 0.1, 0.1, 0.1, 1, true)
    H.assertTrue(Near(btn.combinedBorder.fill.tm.top[1], 0.1 * 0.65), "the theme's repaint ramps")
end

-- A window's X read the theme only when painted: a theme change left it
-- in the old colors until hovered.
function tests.aThemeChangeRepaintsEveryCloseX()
    local ns, env = LoadRamp("options", false)
    local theme = { textFaint = { 0.5, 0.5, 0.5 } }
    ns.Results = { GetActiveTheme = function() return theme end }
    env.paintable = true
    local x = ns.CreateCloseX(Paintable())
    local stroke = x.textures[1]
    H.assertTrue(Near(stroke.rgb[1], 0.5), "the theme's faint text at rest")
    theme = { textFaint = { 0.9, 0.1, 0.1 } }
    ns.RetintCloseXs()
    H.assertTrue(Near(stroke.rgb[1], 0.9) and Near(stroke.rgb[2], 0.1), "the new theme's, unhovered")
end

function tests.otherWindowsAndTheClassicSkinStayFlat()
    for _, case in ipairs({ { "results", false }, { "options", true } }) do
        local ns = LoadRamp(case[1], case[2])
        local btn = Button()
        ns.SetRoundedRectBorderFillColor(btn, 0.2, 0.3, 0.4, 1)
        ns.RampButton(btn)
        H.assertNil(btn._efRamp, case[1] .. " " .. tostring(case[2]))
        H.assertNil(btn.combinedBorder.fill.tm.top, "no ramp")
        H.assertTrue(Near(btn.combinedBorder.fill.tm.flat[1], 0.2), "its flat fill")
    end
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
