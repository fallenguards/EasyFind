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

-- The replacement's window a client frame name stands for, only while it is
-- visible (its roots exist hidden); PlayerSpellsFrame is either book.
local REPLACED_FRAMES = {
    ClassTalentFrame = "talents", QuestLogFrame = "questLog", CommunitiesFrame = "guildRoster",
    ProfessionsFrame = "tradeSkill", TradeSkillFrame = "tradeSkill", ProfessionsBookFrame = "professionsBook",
    ClassTrainerFrame = "trainer", CollectionsJournal = "collectionsWindow",
}

-- The Collections tabs by their retail number, as the replacement names
-- its pages.
Openers.COLLECTIONS_PAGES = { "mounts", "pets", "toys", "heirlooms", "appearances", "campsites" }

-- The replacement's Collections window at a page (a key or a retail tab
-- number), and an entry on it ("mount:<id>", "pet:<speciesID>",
-- "toy:<itemID>", "heirloom:<itemID>", "appearance:<sourceID>") picked;
-- true, and the cell drawing the entry when it shows. nil when the game's
-- own window is the one in use.
function Openers.OpenCollectionsPage(page, entry)
    local api = Replacement("collectionsWindow")
    if not (api and api.Open) then return nil end
    if type(page) == "number" then page = Openers.COLLECTIONS_PAGES[page] end
    if page then pcall(api.Open, "collectionsWindow", page) end
    local cell
    if entry then
        local ok, found = pcall(api.Open, "collectionsWindow", entry)
        if ok and found and api.GetFrame then
            local got, frame = pcall(api.GetFrame, "collectionsWindow", "entry:" .. entry)
            cell = got and frame or nil
        end
    end
    return true, cell
end

-- The entry's cell ringed, as a row in the game's journal is.
function Openers.ShowCollectionsEntry(page, entry)
    local replaced, cell = Openers.OpenCollectionsPage(page, entry)
    local Handlers = ns.ResultHandlers
    if cell and Handlers and Handlers.HighlightRevealedFrame then Handlers:HighlightRevealedFrame(cell) end
    return replaced
end
function Openers.ReplacementFrame(path)
    if path == "PlayerSpellsFrame" then
        local book, talents = Replacement("spellBook"), Replacement("talents")
        local b = book and book.GetFrame("spellBook")
        local t = talents and talents.GetFrame("talents")
        if t and t:IsVisible() then return t end
        return (b and b:IsVisible()) and b or nil
    end
    local name = REPLACED_FRAMES[path]
    local api = Replacement(name)
    local frame = api and api.GetFrame(name)
    return (frame and frame:IsVisible()) and frame or nil
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

-- ClassicUI Forever replaces some client windows with its own. When its
-- public API says one is replaced, its version opens through the API (its
-- own taint handling) and the client's button is never pressed; nil means
-- not replaced, so the usual path runs.
local REPLACED_BY = {
    GuildMicroButton = "guildRoster",
    QuestLogMicroButton = "questLog",
    SpellbookMicroButton = "spellBook",
    TalentMicroButton = "talents",
    LegacyMicroButton = "legacyWindow",
    CollectionsMicroButton = "collectionsWindow",
}
-- nextStep: the step after the button; a Collections tab there opens the
-- replacement at that page at once.
local function OpenReplacement(buttonFrame, nextStep)
    local name = REPLACED_BY[buttonFrame]
    local api = Replacement(name)
    if not (api and api.Open) then return nil end
    local page = name == "collectionsWindow" and nextStep and nextStep.waitForFrame == "CollectionsJournal"
        and Openers.COLLECTIONS_PAGES[nextStep.tabIndex or 0] or nil
    local frame = api.GetFrame and api.GetFrame(name)
    if frame and frame:IsVisible() and not page then return true end
    local okOpen, opened = pcall(api.Open, name, page)
    return (okOpen and opened) and true or false
end
Openers.OpenReplacement = OpenReplacement

local function OpenButtonFrame(buttonFrame, nextStep)
    local replaced = OpenReplacement(buttonFrame, nextStep)
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
