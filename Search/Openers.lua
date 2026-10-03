local _, ns = ...

local Openers = ns.SearchOpeners
local Utils = ns.Utils

local ClickButton = Utils.ClickButton


local CHARACTER_TAB_SUBFRAME = {
    [1] = "PaperDollFrame",
    [2] = "ReputationFrame",
    [3] = "TokenFrame",
}

local SecureCall = Utils.SecureCall

local InCombatLockdown = InCombatLockdown

local function SecureShowUIPanel(frame)
    if not frame or not ShowUIPanel then return false end
    -- Protected panels cannot be shown by insecure code in combat: refuse
    -- those by capability, so ADDON_ACTION_BLOCKED never fires.
    if InCombatLockdown() and frame.IsProtected and frame:IsProtected() then
        return false
    end
    return SecureCall(ShowUIPanel, frame)
end

local function IsPlayerSpellsTabSelected(tabIndex)
    local frame = _G["PlayerSpellsFrame"]
    if not frame then return false end
    if frame.GetTab then
        local currentTab = frame:GetTab()
        if currentTab == tabIndex then return true end
    end
    if tabIndex == 1 and frame.SpecFrame and frame.SpecFrame:IsShown() then
        return true
    elseif tabIndex == 2 and frame.TalentsFrame and frame.TalentsFrame:IsShown() then
        return true
    elseif tabIndex == 2 and ClassTalentFrame and ClassTalentFrame:IsShown() then
        return true
    elseif tabIndex == 3 and frame.SpellBookFrame and frame.SpellBookFrame:IsShown() then
        return true
    end
    return false
end

-- Never ClickButton a PlayerSpells tab: it taints the action bars' drag-grid flag.
-- Rows steer securely on release; otherwise the tab is highlighted. True when already there.
local function EnsurePlayerSpellsTab(tabIndex)
    if not tabIndex or IsPlayerSpellsTabSelected(tabIndex) then return true end
    local tab = ns.SecureOpeners
        and ns.SecureOpeners.GetTabButtonFor("playerSpells", tabIndex)
    local highlight = ns.RequestGuide()
    if tab and highlight and highlight.HighlightFrame then
        highlight:HighlightFrame(tab, nil, nil, true)
    end
    return false
end

local function OpenPlayerSpellsFrame(tabIndex)
    local frame = _G["PlayerSpellsFrame"]
    if frame and frame:IsShown() then
        EnsurePlayerSpellsTab(tabIndex)
        return true
    end

    -- The Blizzard opener reaches TrySetTab -> SetShown, protected here in combat
    -- even through securecallfunction. Refuse by capability.
    if InCombatLockdown() and (not frame
        or (frame.IsProtected and frame:IsProtected())) then
        return false
    end

    -- The microbutton path taints ShowUIPanel: call Blizzard's opener through
    -- securecallfunction so later protected panel work stays clean.
    local util = _G.PlayerSpellsUtil
    if util and SecureCall(util.TogglePlayerSpellsFrame, tabIndex) then
        return true
    end

    return ClickButton(_G["PlayerSpellsMicroButton"])
end

local function IsCharacterTabSelected(tabIndex)
    if not tabIndex then return CharacterFrame and CharacterFrame:IsShown() end
    if not (CharacterFrame and CharacterFrame:IsShown()) then return false end
    if PanelTemplates_GetSelectedTab
       and PanelTemplates_GetSelectedTab(CharacterFrame) == tabIndex then
        return true
    end
    if tabIndex == 1 then
        return (PaperDollFrame and PaperDollFrame:IsShown())
            or (CharacterStatsPane and CharacterStatsPane:IsShown())
    elseif tabIndex == 2 then
        return ReputationFrame and ReputationFrame:IsShown()
    elseif tabIndex == 3 then
        return (TokenFrame and TokenFrame:IsShown())
            or (CurrencyFrame and CurrencyFrame:IsShown())
    end
    return false
end

local function OpenCharacterFrame(tabIndex)
    -- A subframe name ("SkillsFrame") opens as itself on either client.
    if type(tabIndex) == "string" then
        tabIndex = ns.Caps.CharacterSubframe(tabIndex) or tabIndex
        local sub = _G[tabIndex]
        if sub and sub:IsShown() and CharacterFrame and CharacterFrame:IsShown() then return true end
        if SecureCall(_G.ToggleCharacter, tabIndex) then return true end
        return ClickButton(_G["CharacterMicroButton"])
    end
    if IsCharacterTabSelected(tabIndex) then return true end

    local subFrame = CHARACTER_TAB_SUBFRAME[tabIndex] or "PaperDollFrame"
    if SecureCall(_G.ToggleCharacter, subFrame) then
        return true
    end

    return ClickButton(_G["CharacterMicroButton"])
end

local function OpenButtonFrame(buttonFrame, nextStep)
    if buttonFrame == "PlayerSpellsMicroButton" then
        local tabIndex = nextStep and nextStep.waitForFrame == "PlayerSpellsFrame"
            and nextStep.tabIndex or nil
        return OpenPlayerSpellsFrame(tabIndex)
    elseif buttonFrame == "CharacterMicroButton" then
        local tabIndex = nextStep and nextStep.waitForFrame == "CharacterFrame"
            and (nextStep.tabFrame or nextStep.tabIndex) or nil
        return OpenCharacterFrame(tabIndex)
    end

    local stepFrame = Utils.GetFrameByPath(buttonFrame) or _G[buttonFrame]
    if stepFrame then return ClickButton(stepFrame) end
    return false
end


function Openers:SecureShowUIPanel(frame)
    return SecureShowUIPanel(frame)
end

-- Enters the Quick Keybind overlay as the Settings button does.
-- False in combat or without the frame, so the caller can open the settings page.
function Openers:ActivateQuickKeybindMode()
    if InCombatLockdown() then return false end
    local frame = _G["QuickKeybindFrame"]
    if not frame then return false end
    SecureShowUIPanel(frame)
    if not frame:IsShown() then
        pcall(frame.Show, frame)
    end
    return frame:IsShown() and true or false
end

function Openers:OpenButtonFrame(buttonFrame, nextStep)
    return OpenButtonFrame(buttonFrame, nextStep)
end

function Openers:EnsurePlayerSpellsTab(tabIndex)
    return EnsurePlayerSpellsTab(tabIndex)
end

function Openers:OpenPlayerSpellsFrame(tabIndex)
    return OpenPlayerSpellsFrame(tabIndex)
end

function Openers:OpenCharacterFrame(tabIndex)
    return OpenCharacterFrame(tabIndex)
end
