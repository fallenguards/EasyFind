-- Tests for a theme change reaching every control fill (Shared/Utils.lua):
-- a fill painted from a live theme color records which one, so the theme
-- walk repaints it from that table even when it was first painted under
-- a theme other than the default (the notes list rows and search bar
-- stayed in the old theme until hovered). Loads the REAL Shared/Utils.lua.

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)

local function fakeWidget()
    local w = {}
    setmetatable(w, { __index = function() return function() return w end end })
    return w
end
env.CreateFrame = function() return fakeWidget() end
env.CreateFont = fakeWidget
env.CreateColor = function(r, g, b, a) return { GetRGBA = function() return r, g, b, a end } end
env.UIParent = fakeWidget()
env.WorldFrame = fakeWidget()
env.GameTooltip = fakeWidget()
env.hooksecurefunc = function() end
env.GameFontNormal = setmetatable({}, { __index = function(_, k)
    if k == "GetFont" then return function() return "font", 12, "" end end
    return function() end
end })
H.loadModule("Shared/Utils.lua", env, ns)

-- A control with a rounded fill: one fill texture keeping its color.
local function Control()
    local tex = { color = {} }
    function tex:SetVertexColor(r, g, b, a) self.color = { r, g, b, a } end
    function tex:GetVertexColor() return self.color[1], self.color[2], self.color[3], self.color[4] end
    function tex:SetAlpha() end
    return { combinedBorder = { fill = { mm = tex } } }, tex
end

local function Set(t, r, g, b)
    t[1], t[2], t[3] = r, g, b
end

local tests = {}

function tests.paintedUnderAnotherThemeFollowsTheNext()
    ns.Results = { GetActiveTheme = function() return {} end }
    Set(ns.BTN_FILL_NORMAL, 0.40, 0.30, 0.10)
    local control, tex = Control()
    ns.SetRoundedRectFill(control, ns.BTN_FILL_NORMAL[1], ns.BTN_FILL_NORMAL[2], ns.BTN_FILL_NORMAL[3], 1, true)
    H.assertEq(control._efControlFillKind, "BTN_FILL_NORMAL", "the live table it came from")
    Set(ns.BTN_FILL_NORMAL, 0.30, 0.20, 0.45)
    ns.RetintPanelText(control)
    H.assertEq(tex.color[1], 0.30, "repainted in the new theme's color")
    H.assertEq(tex.color[3], 0.45)
end

function tests.aColorOfItsOwnIsLeftAlone()
    ns.Results = { GetActiveTheme = function() return {} end }
    local control, tex = Control()
    ns.SetRoundedRectFill(control, 0.14, 0.14, 0.16, 1, true)
    H.assertNil(control._efControlFillKind)
    Set(ns.BTN_FILL_NORMAL, 0.50, 0.10, 0.10)
    ns.RetintPanelText(control)
    H.assertEq(tex.color[1], 0.14, "not a theme color: kept")
end

local pass, fail, failures = H.runSuite("ThemeFillRetint", tests)
return { pass = pass, fail = fail, failures = failures }
