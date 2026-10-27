-- A settings card's ring is a filled shape 1 px past the card, its fill
-- covered by the card's own. Under the Classic stone edge the card has no
-- fill over the tree, and the ring's whole fill showed as a pale wash
-- reaching past the edge (2026-10-27). Off there, on everywhere else.
local H = require("Harness")

local function Load(classic)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Options/OptionsPanel.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local function PaintGroupRing(", 1, true))
    local _, e = assert(src:find("\nend\r?\n", s))
    local shown
    local ns = {
        ThemeSetOf = function() return { palette = { separator = { 0.5, 0.5, 0.4, 0.35 } } } end,
        SetRoundedRectFill = function() end,
        SetRoundedRectBorderShown = function(_, v) shown = v end,
        IsClassicChrome = function() return classic end,
    }
    local env = setmetatable({ ns = ns }, { __index = _G })
    local fn = assert(load(src:sub(s, e) .. "\nreturn PaintGroupRing", "=OptionsPanel.lua ring", "t", env))()
    fn({})
    return shown
end

local tests = {}

function tests.classicStoneEdge_theRingIsOff()
    H.assertFalse(Load(true))
end

function tests.otherwise_theRingShows()
    H.assertTrue(Load(false))
end

local pass, fail, failures = H.runSuite("ClassicCardRing", tests)
return { pass = pass, fail = fail, failures = failures }
