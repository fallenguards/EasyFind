-- Our text is flat on either polarity, but over a Classic talent tree it
-- wears the game's drop shadow: the art is bright and white text was lost
-- on it (2026-10-27: the shadow was picked from a mock of styles).
local H = require("Harness")

local function Load(classicArt, classic)
    local f = assert(io.open(H.ADDON_ROOT .. "/Shared/Utils.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function ns.TextShadowed()", 1, true))
    local e = select(2, assert(src:find("\n%-%- A root's text shaded now", s)))
    local ns = { IsClassicChrome = function() return classic end,
        TEXT_DIM = { 0.55, 0.55, 0.58 }, TEXT_NEXT = { 0.78, 0.78, 0.80 }, TEXT_ASIDE = { 0.56, 0.74, 0.82 } }
    local env = setmetatable({ ns = ns, EasyFind = { db = { classicArt = classicArt } } }, { __index = _G })
    assert(load(src:sub(s, e), "=Utils.lua shadows", "t", env))()
    return ns
end

local function Text()
    local t = { color = { 0, 0, 0, 0 }, offset = { 0, 0 } }
    function t:SetShadowColor(r, g, b, a) self.color = { r, g, b, a } end
    function t:SetShadowOffset(x, y) self.offset = { x, y } end
    return t
end

local function Frame(texts)
    local f = Text()
    function f:GetRegions() return table.unpack(texts) end
    function f:GetChildren() end
    return f
end

local tests = {}

function tests.overATree_textWearsTheShadow()
    local ns = Load("HunterSurvival", true)
    local a, b = Text(), Text()
    ns.ShadeText(Frame({ a, b }))
    H.assertEq(a.color[4], 1)
    H.assertEq(b.offset[1], 1, "the game's offset")
    H.assertEq(b.offset[2], -1)
end

function tests.onTheMarbleOrOtherThemes_textStaysFlat()
    for _, case in ipairs({ { "marble", true }, { nil, true }, { "HunterSurvival", false } }) do
        local ns = Load(case[1], case[2])
        local a = Text()
        a.color = { 0, 0, 0, 1 }
        ns.ShadeText(Frame({ a }))
        H.assertEq(a.color[4], 0, tostring(case[1]) .. " " .. tostring(case[2]))
    end
end

-- The grays and the aside blue lift over a tree, in their live tables and
-- for text painted once from either look (2026-10-27).
function tests.overATree_theGraysLift()
    local ns = Load("HunterSurvival", true)
    ns.LiftTreeText()
    H.assertEq(ns.TEXT_DIM[1], 0.82)
    H.assertEq(ns.TEXT_NEXT[1], 0.93)
    H.assertEq(ns.TEXT_ASIDE[3], 1.00)
    local r = ns.TreeTextColor(0.55, 0.55, 0.58)
    H.assertEq(r, 0.82, "a gray painted flat shows lifted")
    H.assertEq((ns.TreeTextColor(1, 0.82, 0)), 1, "gold stays")
end

function tests.onTheMarble_theGraysStayAsTheyWere()
    local ns = Load("marble", true)
    ns.LiftTreeText()
    H.assertEq(ns.TEXT_DIM[1], 0.55)
    H.assertEq((ns.TreeTextColor(0.82, 0.82, 0.84)), 0.55, "a gray painted over a tree goes back")
end

local pass, fail, failures = H.runSuite("TextShadow", tests)
return { pass = pass, fail = fail, failures = failures }
