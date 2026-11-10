-- Tab on a result row with a GPS button stops on the button before the
-- row's menu, so a keyboard user can start a route (Search/SearchBar.lua
-- GPSKeyFocusRow / SetGPSKeyFocus): Enter then clicks the button, Tab
-- again opens the menu, Shift+Tab goes back to the row, and moving the
-- selection drops the focus.
local H = require("Harness")

local function Source()
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/SearchBar.lua", "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local function Button()
    local b = { shown = true, over = false, entered = 0, left = 0, clicks = 0, scripts = {} }
    function b:IsShown() return self.shown end
    function b:IsMouseOver() return self.over end
    function b:GetScript(name) return self.scripts[name] end
    function b:Click() self.clicks = self.clicks + 1 end
    function b:CreateTexture()
        local t = { shown = false }
        function t:SetTexture() end
        function t:SetBlendMode() end
        function t:SetAllPoints() end
        function t:Show() self.shown = true end
        function t:Hide() self.shown = false end
        return t
    end
    b.scripts.OnEnter = function(self) self.entered = self.entered + 1 end
    b.scripts.OnLeave = function(self) self.left = self.left + 1 end
    return b
end

local function Load()
    local src = Source()
    local s = assert(src:find("function Search:GPSKeyFocusRow()", 1, true))
    local e0 = assert(src:find("function Search:SetGPSKeyFocus(row)", s, true))
    local _, e = assert(src:find("\nend\r?\n", e0))
    local rowA, rowB = { gpsBtn = Button() }, { gpsBtn = Button() }
    local env = setmetatable({ resultButtons = { rowA, rowB }, selectedIndex = 1, Search = {} }, { __index = _G })
    assert(load(src:sub(s, e), "=SearchBar.lua gps focus", "t", env))()
    return env, rowA, rowB
end

local tests = {}

function tests.focusedButton_isMarkedAsTheMouseMarksIt()
    local env, a = Load()
    env.Search:SetGPSKeyFocus(a)
    H.assertEq(env.Search:GPSKeyFocusRow(), a)
    H.assertEq(a.gpsBtn.entered, 1, "its own hover look and tooltip")
    H.assertTrue(a.gpsBtn._efKeyGlow.shown, "the glow over it")
    env.Search:SetGPSKeyFocus(nil)
    H.assertEq(a.gpsBtn.left, 1)
    H.assertFalse(a.gpsBtn._efKeyGlow.shown)
end

function tests.movingTheSelection_dropsTheFocus()
    local env, a = Load()
    env.Search:SetGPSKeyFocus(a)
    env.selectedIndex = 2
    H.assertNil(env.Search:GPSKeyFocusRow(), "another row selected")
    H.assertFalse(a.gpsBtn._efKeyGlow.shown)
end

function tests.theButtonGone_dropsTheFocus()
    local env, a = Load()
    env.Search:SetGPSKeyFocus(a)
    a.gpsBtn.shown = false
    H.assertNil(env.Search:GPSKeyFocusRow())
end

function tests.theMouseStillOverIt_keepsItsHoverLook()
    local env, a = Load()
    env.Search:SetGPSKeyFocus(a)
    a.gpsBtn.over = true
    env.Search:SetGPSKeyFocus(nil)
    H.assertEq(a.gpsBtn.left, 0)
end

-- The key handler: the GPS stop before the menu, Enter on the button, the
-- secure row's Enter binding not taken while the button is focused.
function tests.theKeyHandler_routesTabAndEnterThroughIt()
    local src = Source()
    local tab = assert(src:find("-- The row's GPS button first, then its menu.", 1, true))
    local menu = assert(src:find("Rows:ShowResultContextMenu(row, true)", tab, true))
    H.assertTrue(src:find("Search:SetGPSKeyFocus(row)", tab, true) < menu, "the button before the menu")
    H.assertTrue(src:find("gpsRow.gpsBtn:Click()", 1, true) ~= nil, "Enter clicks the button")
    H.assertTrue(src:find("IsSecureActionResult(rd) and not Search:GPSKeyFocusRow()", 1, true) ~= nil,
        "a secure row's Enter binding waits while the button is focused")
end

local pass, fail, failures = H.runSuite("GPSKeyFocus", tests)
return { pass = pass, fail = fail, failures = failures }
