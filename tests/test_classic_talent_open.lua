-- A talent row on the classic clients (Search/Results/Handlers/Talents.lua):
-- Era and Anniversary open the window on the talent's tree, scrolled to it,
-- the talent lit until hovered; the player was guided through the tree's tab
-- and the lit talent stayed lit under the cursor. MoP Classic's tab stays the
-- player's click: its tab click writes a CVar.
local H = require("Harness")

local function Load(data, selected)
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/Results/Handlers/Talents.lua", "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    local s = assert(src:find("local function ScrollToTalent", 1, true), "ScrollToTalent")
    local e = assert(src:find("function Handlers:OpenTalentInTalentsTab", s, true), "the opener's end")
    local lit, clicked, scrolled = {}, {}, nil
    local function Button(name, top)
        return { name = name, IsShown = function() return true end, IsVisible = function() return true end,
            IsEnabled = function() return true end, GetTop = function() return top end,
            GetHeight = function() return 37 end }
    end
    local env = setmetatable({
        ns = { RequestGuide = function()
            return { HighlightFrame = function(_, target, _, _, noHoverDismiss)
                lit[#lit + 1] = { target.name, noHoverDismiss }
            end }
        end },
        Openers = { OpenButtonFrame = function() end },
        Utils = { SafeAfter = function() end },
        PlayerTalentFrame = { IsShown = function() return true end },
        PanelTemplates_GetSelectedTab = function() return selected end,
        PlayerTalentFrameScrollFrame = {
            GetScrollChild = function() return { GetTop = function() return 500 end } end,
            GetHeight = function() return 300 end,
            GetVerticalScrollRange = function() return 200 end,
            SetVerticalScroll = function(_, v) scrolled = v end,
        },
        PlayerTalentFrameTalent5 = Button("talent 5", 120),
        PlayerTalentFrameTalentsTalentRow3Talent2 = Button("tier 3 col 2", 300),
    }, { __index = _G })
    for i = 1, 3 do
        local tab = Button("tab " .. i, 0)
        tab.Click = function() clicked[#clicked + 1] = i; selected = i end
        env["PlayerTalentFrameTab" .. i] = tab
    end
    env._G = env
    local chunk = src:sub(s, e - 1) .. "\nreturn OpenClassicTalent"
    local open = assert(load(chunk, "=Talents.lua OpenClassicTalent", "t", env))()
    open(data)
    return lit, clicked, scrolled
end

local tests = {}

function tests.anniversaryOpensOnTheTreeScrolledToTheTalent()
    local lit, clicked, scrolled = Load({ talentTab = 2, talentIndex = 5 }, 1)
    H.assertEq(table.concat(clicked, ","), "2", "the tree's tab clicked for the player")
    H.assertEq(#lit, 1, "no tab to click through: the talent alone")
    H.assertEq(lit[1][1], "talent 5")
    H.assertNil(lit[1][2], "hovering the talent clears it")
    -- 500 - 120 = 380 down the tree; centered in a 300 view, within the range.
    H.assertEq(scrolled, 200)
end

function tests.aTreeRowOpensOnItsTree()
    local lit, clicked = Load({ talentTab = 3 }, 1)
    H.assertEq(table.concat(clicked, ","), "3", "the tree's tab clicked")
    H.assertEq(#lit, 0, "its tree is up: nothing to light")
end

function tests.mistsLeavesItsTabToThePlayer()
    local lit, clicked = Load({ talentTab = 2, talentTier = 3, talentColumn = 2 }, 1)
    H.assertEq(#clicked, 0, "MoP's tab click writes a CVar: never from EasyFind")
    H.assertEq(lit[1][1], "tab 2")
    H.assertTrue(lit[1][2], "the tab stays lit until clicked")
end

function tests.mistsTalentClearsOnHover()
    local lit = Load({ talentTab = 2, talentTier = 3, talentColumn = 2 }, 2)
    H.assertEq(lit[1][1], "tier 3 col 2")
    H.assertNil(lit[1][2])
end

local pass, fail, failures = H.runSuite("ClassicTalentOpen", tests)
return { pass = pass, fail = fail, failures = failures }
