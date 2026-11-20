-- A flat row's title wears the color its data carries (2026-11-20): a
-- class's on a character, friend or guild row, a recipe's difficulty.
-- Only the branches of the row content that set the title again applied
-- it; a row that took none of them (a character, a classic recipe) showed
-- the theme's color.
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function NameText(ns)
    local src = Read("Search/Results/Render/RowContent.lua")
    local s = assert(src:find("function ns.ResultRender.NameText(entry)", 1, true))
    local e = select(2, assert(src:find("\nend\n", s, true)))
    local fenv = setmetatable({ ns = ns }, { __index = _G })
    assert(load(src:sub(s, e), "=RowContent.lua NameText", "t", fenv))()
    return ns.ResultRender.NameText
end

local tests = {}

function tests.theFlatBranch_setsTheTitleThroughNameText()
    local src = Read("Search/Results/Render/Text.lua")
    local flat = src:sub(assert(src:find("if entry.isFlat then", 1, true)), assert(src:find("resultRow.pathSubtext:Show()", 1, true)))
    H.assertTrue(flat:find("SetClippedText(resultRow.text, Render.NameText(entry))", 1, true) ~= nil,
        "the flat row's title is the colored name")
    H.assertNil(flat:find("SetClippedText(resultRow.text, entry.name)", 1, true), "never the bare name")
end

function tests.theTitle_isTheNameInItsColor()
    local ns = { ResultRender = {} }
    local Name = NameText(ns)
    H.assertEq(Name({ name = "Jaina", data = { nameHex = "|cff3fc6ea" } }), "|cff3fc6eaJaina|r", "a class color")
    H.assertEq(Name({ name = "Linen Bag", data = { professionRecipeID = 5 } }), "Linen Bag", "no skill-ups module: plain")
    ns.SkillUps = { Hex = function(data) return data.professionRecipeID == 5 and "|cffff8040" or nil end }
    H.assertEq(Name({ name = "Linen Bag", data = { professionRecipeID = 5 } }), "|cffff8040Linen Bag|r", "a recipe's difficulty")
    H.assertEq(Name({ name = "Stormwind", data = { category = "zone" } }), "Stormwind", "a row with no color")
    H.assertEq(Name({ name = "Thrall", nameHex = "|cffc79c6e", data = { professionRecipeID = 5 } }), "|cffc79c6eThrall|r",
        "the entry's own color first")
end

local pass, fail, failures = H.runSuite("FlatTitleColor", tests)
return { pass = pass, fail = fail, failures = failures }
