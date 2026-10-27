-- The settings' looks preview on hover (2026-10-27: a theme, a Classic
-- background or a font had to be clicked to be seen). The hovered choice
-- shows after a short rest; a click keeps it; the flyout closing without
-- one puts the saved look back.
local H = require("Harness")

local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Options/OptionsPanel.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local function HoverPreview(", 1, true))
    local e = select(2, assert(src:find("\nend\n", s)))
    local env = setmetatable({ Utils = { SafeAfter = function(_, fn) fn() end } }, { __index = _G })
    return assert(load(src:sub(s, e) .. "\nreturn HoverPreview", "=OptionsPanel.lua HoverPreview", "t", env))()
end

local function Flyout()
    local f = { scripts = {}, shown = false }
    function f:HookScript(name, fn) self.scripts[name] = fn end
    function f:IsShown() return self.shown end
    function f:Open() self.shown = true self.scripts.OnShow(self) end
    function f:Close() self.shown = false self.scripts.OnHide(self) end
    return f
end

local tests = {}

function tests.hoverShows_andClosingPutsTheSavedLookBack()
    local HoverPreview = Load()
    local saved, applied = "Midnight", {}
    local fl = Flyout()
    local hover = HoverPreview(fl, function() return saved end, function(v) applied[#applied + 1] = v end)
    fl:Open()
    hover("Classic")
    hover("Frost")
    H.assertEq(applied[#applied], "Frost", "the hovered look shows")
    fl:Close()
    H.assertEq(applied[#applied], "Midnight", "closed without a click: the saved look")
end

function tests.aClickKeepsTheLook()
    local HoverPreview = Load()
    local saved, applied = "Midnight", {}
    local fl = Flyout()
    local hover, keep = HoverPreview(fl, function() return saved end, function(v) applied[#applied + 1] = v end)
    fl:Open()
    hover("Classic")
    keep("Classic")
    saved = "Classic"
    local n = #applied
    fl:Close()
    H.assertEq(#applied, n, "nothing put back after a pick")
end

function tests.theSavedLookHoveredDoesNothing()
    local HoverPreview = Load()
    local applied = {}
    local fl = Flyout()
    local hover = HoverPreview(fl, function() return "Midnight" end, function(v) applied[#applied + 1] = v end)
    fl:Open()
    hover("Midnight")
    H.assertEq(#applied, 0)
end

local pass, fail, failures = H.runSuite("HoverPreview", tests)
return { pass = pass, fail = fail, failures = failures }
