-- The Quests tab EasyFind draws beside the map on WoW Forever, where the
-- game's quest log has no side tab (CreateBackTab in MapSearch/MapTab.lua):
-- a click on it is the player's way back to the quest log, so the map's
-- next open keeps the quest log instead of restoring EasyFind's panel, as
-- a click on one of the game's own tabs does on retail.
local H = require("Harness")

local function Texture()
    local t = {}
    for _, m in ipairs({ "SetAtlas", "SetPoint", "SetTexture", "SetTexCoord", "SetSize", "SetVertexColor", "Show" }) do
        t[m] = function() end
    end
    return t
end

local function Frame()
    local f = { scripts = {} }
    for _, m in ipairs({ "SetSize", "SetFrameStrata", "SetFrameLevel", "EnableMouse" }) do f[m] = function() end end
    function f:CreateTexture() return Texture() end
    function f:SetScript(name, fn) self.scripts[name] = fn end
    return f
end

local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/MapTab.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local function CreateBackTab(qmf)", 1, true))
    local _, e = assert(src:find("\nend\r?\n", s))
    local hidden = {}
    local env = setmetatable({
        CreateFrame = function() return Frame() end,
        HideOurPanel = function(restore) hidden[#hidden + 1] = restore end,
        RefreshSelectGlows = function() end,
        Utils = { RGB = function() return 1, 1, 1 end },
        TAB_W = 32, TAB_H = 44, TAB_ICON_SIZE = 16, TAB_ICON_GOLD = {},
        lastSelectedWasOurs = true,
    }, { __index = _G })
    local CreateBackTab = assert(load(src:sub(s, e) .. "\nreturn CreateBackTab", "=MapTab.lua back tab", "t", env))()
    local qmf = { QuestsTab = {
        GetSize = function() return 0, 0 end, GetFrameLevel = function() return 1 end,
        GetNumRegions = function() return 0 end, GetRegions = function() end,
    } }
    return CreateBackTab(qmf), env, hidden
end

local tests = {}

function tests.aClickOnTheQuestsTab_isThePlayersChoice()
    local tab, env, hidden = Load()
    tab.scripts.OnMouseUp(tab, "LeftButton")
    H.assertFalse(env.lastSelectedWasOurs, "the map's next open keeps the quest log")
    H.assertEq(#hidden, 1, "the panel hides")
    H.assertTrue(hidden[1], "the quest log's own mode comes back")
end

function tests.anotherButton_changesNothing()
    local tab, env, hidden = Load()
    tab.scripts.OnMouseUp(tab, "RightButton")
    H.assertTrue(env.lastSelectedWasOurs)
    H.assertEq(#hidden, 0)
end

local pass, fail, failures = H.runSuite("MapTabBack", tests)
return { pass = pass, fail = fail, failures = failures }
