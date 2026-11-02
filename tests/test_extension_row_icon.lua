-- An extension's row wears its extension's glyph at the left and its own
-- icon at the right (EasyFind.API, a row's icon). BaseRowText clears the
-- icon's anchors and, with a glyph on the row, leaves them to the branch
-- that owns the icon; the generic branches own an extension row's and set
-- none, so the icon was textured and shown with no rectangle (retail,
-- 2026-11-02, /efd iconwatch: quest, HandyNotes and fishing rows).
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local tests = {}

function tests.anExtensionRowsIconIsARightSideIcon()
    local src = Read("Search/Results/Icons.lua")
    local s = assert(src:find("local function IsRightSideIconData(d)", 1, true))
    local body = src:sub(s, assert(src:find("\nend\n", s, true)))
    H.assertTrue(body:find("or ((d.icon or d.iconAtlas) and ns.Extensions and ns.Extensions.ProviderOf(d) ~= nil)", 1, true) ~= nil,
        "a provider's row with an icon counts as a right-side icon row")
    -- The predicate itself, over a stub of the extensions registry.
    local env = { ns = { Extensions = { ProviderOf = function(d) return d.category == "Quests" and {} or nil end } } }
    local fn = assert(load(src:sub(s, assert(src:find("\nend\n", s, true)) + 4) .. "\nreturn IsRightSideIconData",
        "=Icons IsRightSideIconData", "t", setmetatable(env, { __index = { IsMenuBarSpecificIconData = function() return false end } })))()
    H.assertTrue(fn({ category = "Quests", icon = 123, name = "x" }) and true or false, "an extension row with an icon")
    H.assertFalse(fn({ category = "Quests", name = "x" }) and true or false, "none without an icon")
    H.assertFalse(fn({ category = "Game Settings", icon = 123 }) and true or false, "a core row keeps its own rules")
end

function tests.theGenericBranchAnchorsIt()
    local src = Read("Search/Results/Render/RowContent.lua")
    local generic = assert(src:find('Icons:SetRowIcon(resultRow, "file", data.icon, rowIconSize)', 1, true))
    local anchor = assert(src:find("if iconSet and data and resultRow.icon:IsShown() and resultRow.icon:GetNumPoints() == 0\n"
        .. "       and Icons.IsRightSideIconData(data) then\n"
        .. '        resultRow.icon:SetPoint("RIGHT", resultRow, "RIGHT", -5, 0)', 1, true))
    H.assertTrue(anchor > generic, "right after the generic icon branches")
    H.assertTrue(src:find("resultRow.icon:ClearAllPoints()", 1, true) ~= nil)
end

local pass, fail, failures = H.runSuite("ExtensionRowIcon", tests)
return { pass = pass, fail = fail, failures = failures }
