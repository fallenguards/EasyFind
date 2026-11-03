-- A decorator's subtext part survives a hover: the action hint's restore
-- wrote the flat subtext alone, so a row read "Item, TSM: Blacksmithing"
-- until hovered and "Item" after (Era, 2026-11-02).
local H = require("Harness")
local env = H.newEnv()
env._G = env
local ns = H.newNs(env)
ns.Utils.sformat = ns.Utils.sformat or string.format
H.loadModule("Search/Results/RowText.lua", env, ns)
local Text = ns.ResultText

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function LoadHints()
    local src = Read("Search/Results/ActionHints.lua")
    local s = assert(src:find("\nlocal actionHintRow\n", 1, true))
    local e = select(2, assert(src:find("\nend\n", assert(src:find("function Handlers:ApplyActionHint(row)", s, true)), true)))
    local Handlers = { GetActionHint = function() return "Click: open" end }
    local fenv = setmetatable({ Handlers = Handlers, Text = Text, ns = {} }, { __index = _G })
    assert(load(src:sub(s, e), "=ActionHints.lua hints", "t", fenv))()
    return Handlers
end

local function Row(data)
    local fs = { shown = true }
    function fs:SetText(t) self.text = t end
    function fs:IsShown() return self.shown end
    function fs:SetTextColor() end
    return { data = data, pathSubtext = fs }
end

local tests = {}

function tests.aDecoratedRowKeepsItsPartAfterAHover()
    local was = ns.Extensions
    ns.Extensions = { DecoratorSubtext = function(d) return d.itemID == 2589 and "TSM: Blacksmithing" or nil end }
    local data = { name = "Linen Cloth", category = "Item", itemID = 2589 }
    H.assertEq(Text:GetShownSubtext(data), "Item, TSM: Blacksmithing")
    local Handlers = LoadHints()
    local row = Row(data)
    row.pathSubtext:SetText(Text:GetShownSubtext(data))
    Handlers:ApplyActionHint(row)
    H.assertEq(row.pathSubtext.text, "Click: open", "the hint while hovered")
    Handlers:ClearActionHint()
    H.assertEq(row.pathSubtext.text, "Item, TSM: Blacksmithing", "the part comes back with the subtext")
    H.assertEq(Text:GetShownSubtext({ category = "Item" }), "Item", "a row no decorator takes")
    ns.Extensions = was
end

function tests.everySubtextWriterShowsTheDecoratorPart()
    H.assertTrue(Read("Search/Results/Render/Text.lua"):find("pathSubtext:SetText(Text:GetShownSubtext(data))", 1, true) ~= nil)
    H.assertTrue(Read("Search/Results/ActionHints.lua"):find("pathSubtext:SetText(Text:GetShownSubtext(actionHintRow.data))", 1, true) ~= nil)
    for _, path in ipairs({ "Search/Results/Render/Text.lua", "Search/Results/ActionHints.lua", "Search/SearchBar.lua",
                            "Search/Results/Navigation.lua" }) do
        H.assertNil(Read(path):find("SetText(Text:GetFlatSubtext", 1, true), path .. " writes the flat subtext alone")
    end
end

local pass, fail, failures = H.runSuite("DecoratorSubtextHover", tests)
return { pass = pass, fail = fail, failures = failures }
