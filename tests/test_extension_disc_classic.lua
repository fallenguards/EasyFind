-- The extension buttons on the Classic theme (2026-10-27): the disc kept
-- the theme's plain fill whatever background was picked, and the ring took
-- the Classic border color, white for its art. The disc wears the picked
-- background (the tree, else the marble); the ring the bar's stone.
local H = require("Harness")

local function Load(palette, classicArt)
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/ExtensionButtons.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local consts = assert(src:match("(local RING_R.-local CLASSIC_STONE = [^\n]*\n)"))
    local s = assert(src:find("local function PaintDisc(", 1, true))
    local _, e = assert(src:find("\nend\r?\n", s))
    local function region()
        local r = {}
        setmetatable(r, { __index = function(_, k)
            return function(self, ...) self[k .. "Args"] = { ... } end
        end })
        return r
    end
    local frame = { disc = region(), ringLine = region(), ring = region(), icon = region() }
    local env = setmetatable({
        ns = { ACTIVE_UI_PALETTE = palette, SEARCH_WINDOW_FILL_COLOR = { 0.05, 0.05, 0.06 } },
        EasyFind = { db = { classicArt = classicArt } },
        BorderGroup = function() return "free" end,
        BorderStyle = function() return "easyfind" end,
        BASE_SIZE = 40, GLOW_TEX = "glow",
    }, { __index = _G })
    assert(load(consts .. src:sub(s, e) .. "\nreturn PaintDisc", "=ExtensionButtons.lua PaintDisc", "t", env))()(frame, {})
    return frame
end

local CLASSIC = { chrome = "classic", windowFill = { 0.05, 0.05, 0.1 }, backdropBorder = { 1, 1, 1, 1 } }

local tests = {}

function tests.classicTree_theDiscWearsTheTree()
    local f = Load(CLASSIC, "WarlockDestruction")
    H.assertEq(f.disc.SetTextureArgs[1], "Interface\\TalentFrame\\WarlockDestruction-TopLeft")
end

function tests.classicMarble_theDiscWearsTheMarble()
    local f = Load(CLASSIC, "marble")
    H.assertEq(f.disc.SetTextureArgs[1], "Interface\\FrameGeneral\\UI-Background-Marble")
    f = Load(CLASSIC, nil)
    H.assertEq(f.disc.SetTextureArgs[1], "Interface\\FrameGeneral\\UI-Background-Marble", "no pick: the marble")
end

function tests.classic_theRingIsTheStoneNotWhite()
    local f = Load(CLASSIC, "WarlockDestruction")
    local c = f.ringLine.SetVertexColorArgs
    H.assertTrue(c[1] < 0.9, "not the white border color: " .. tostring(c[1]))
end

function tests.otherThemes_theDiscIsTheThemesFill()
    local f = Load({ windowFill = { 0.2, 0.1, 0.05 } }, "WarlockDestruction")
    H.assertTrue(f.disc.SetColorTextureArgs ~= nil, "a plain color disc")
    H.assertEq(f.disc.SetVertexColorArgs[1], 0.2)
end

local pass, fail, failures = H.runSuite("ExtensionDiscClassic", tests)
return { pass = pass, fail = fail, failures = failures }
