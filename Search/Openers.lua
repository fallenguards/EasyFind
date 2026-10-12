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

-- The interface replacement's API (ClassicUIForeverAPI) when its version of
-- a window (by its API name) stands in for the client's now, else nil.
local function Replacement(name)
    local api = name and ClassicUIForeverAPI
    if not (api and (api.version or 0) >= 1 and api.IsOn) then return nil end
    local ok, on = pcall(api.IsOn, name)
    return (ok and on) and api or nil
end
Openers.Replacement = Replacement

-- The replacement's window a client frame name stands for, shown or not:
-- PlayerSpellsFrame is its spellbook or its talents, whichever is up.
local REPLACED_FRAMES = { ClassTalentFrame = "talents", QuestLogFrame = "questLog", CommunitiesFrame = "guildRoster" }
function Openers.ReplacementFrame(path)
    if path == "PlayerSpellsFrame" then
        local book, talents = Replacement("spellBook"), Replacement("talents")
        local b = book and book.GetFrame("spellBook")
        local t = talents and talents.GetFrame("talents")
        if t and t:IsShown() then return t end
        return b or t
    end
    local name = REPLACED_FRAMES[path]
    local api = Replacement(name)
    return api and api.GetFrame(name) or nil
end

-- Where a client micro button stands now: the replacement's lookup (its own
-- copy when the client's is hidden), else the client's own while shown.
function Openers.MicroButton(name)
    local api = ClassicUIForeverAPI
    if api and api.GetFrame then
        local ok, frame = pcall(api.GetFrame, "microMenu", name)
        if ok and frame then return frame end
    end
    local own = _G[name]
    return (own and own:IsShown()) and own or nil
end

local function SecureShowUIPanel(frame)
    if not frame or not ShowUIPanel then return false end
    -- Protected panels cannot be shown by insecure code in combat; refuse
    -- only those (capability check, not a category list) so the hard
    -- ADDON_ACTION_BLOCKED path can't fire. Unprotected panels open fine.
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

-- Switching the PlayerSpells tab from addon execution writes the action
-- bars' drag-grid flag tainted (measured: MultiBarBottomLeft.showAllButtons
-- flips the moment the tab is clicked), so NO
-- code path may ClickButton these tabs. Row clicks steer securely on
-- their release edge (Shared/SecureOpeners.lua); when that steer did not
-- land (non-row flows, first-open gaps), highlight the tab so the user's
-- own hardware click does the switch. Returns true when the requested tab
-- is already active (or no specific tab was requested).
local function EnsurePlayerSpellsTab(tabIndex)
    if not tabIndex or IsPlayerSpellsTabSelected(tabIndex) then return true end
    if Replacement(tabIndex == (ns.SecureOpeners and ns.SecureOpeners.TAB_TALENTS) and "talents" or "spellBook") then
        return true
    end
    local tab = ns.SecureOpeners
        and ns.SecureOpeners.GetTabButtonFor("playerSpells", tabIndex)
    local highlight = ns.RequestGuide()
    if tab and highlight and highlight.HighlightFrame then
        highlight:HighlightFrame(tab, nil, nil, true)
    end
    return false
end

local function OpenPlayerSpellsFrame(tabIndex)
    -- The replacement's spellbook or talents open through its API, never the
    -- client's window or its taken micro button.
    local which = tabIndex == (ns.SecureOpeners and ns.SecureOpeners.TAB_TALENTS) and "talents" or "spellBook"
    local api = Replacement(which)
    if api then return api.Open(which) end
    local frame = _G["PlayerSpellsFrame"]
    if frame and frame:IsShown() then
        EnsurePlayerSpellsTab(tabIndex)
        return true
    end

    -- The Blizzard opener path below reaches TrySetTab -> SetShown, which is
    -- protected on this frame in combat even through securecallfunction
    -- (measured ADDON_ACTION_BLOCKED). Refuse by capability, not category.
    if InCombatLockdown() and (not frame
        or (frame.IsProtected and frame:IsProtected())) then
        return false
    end

    -- Opening PlayerSpellsFrame through the microbutton taints Blizzard's
    -- ShowUIPanel/UIParent path. Call Blizzard's opener through
    -- securecallfunction so later protected panel work, including
    -- CharacterFrame status bars, does not inherit EasyFind taint.
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

-- ClassicUI Forever replaces some client windows with its own. When its
-- public API says one is replaced, its version opens through the API (its
-- own taint handling) and the client's button is never pressed; nil means
-- not replaced, so the usual path runs.
local REPLACED_BY = {
    GuildMicroButton = "guildRoster",
    QuestLogMicroButton = "questLog",
    TalentMicroButton = "talents",
}
local function OpenReplacement(buttonFrame)
    local name = REPLACED_BY[buttonFrame]
    local api = Replacement(name)
    if not (api and api.Open) then return nil end
    local okOpen, opened = pcall(api.Open, name)
    return (okOpen and opened) and true or false
end
Openers.OpenReplacement = OpenReplacement

local function OpenButtonFrame(buttonFrame, nextStep)
    local replaced = OpenReplacement(buttonFrame)
    if replaced ~= nil then return replaced end
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

-- Enter the in-game Quick Keybind overlay directly, the same as clicking the
-- button in Settings > Keybindings. Returns false (so the caller can fall back
-- to opening that settings category) when in combat or the frame isn't present.
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
