local _, ns = ...

-- Catalog of frames the window manager can move. Each entry is keyed by the
-- frame's global name and declares how the manager should treat it:
--
--   labelKey    L[] key for the display name (localized; English keys/keywords
--               stay stable so search matches in any locale).
--   keywords    English search terms (stable, lowercase).
--   uiPanel     true if the frame is part of the default UI's panel layout
--               system, which auto-positions it. These need SetUserPlaced(true)
--               plus a SetPoint re-assert hook to stay where we put them.
--   protected   true if moving the frame is blocked in combat lockdown. The
--               manager defers and replays the move when combat ends.
--   own         true for EasyFind's own windows (no combat / no UIPanel concern).
--   open        optional function that opens/shows the frame before positioning.
--
-- Frame globals are resolved lazily through _G and always nil-checked: an entry
-- whose frame does not exist on this client (or has not loaded yet) is simply
-- skipped. Names marked "verify in-game" below could not be confirmed to exist
-- in Midnight 12.0 from static inspection.

local Registry = {}
ns.WindowRegistry = Registry

local Utils = ns.Utils
local SecureCall = Utils.SecureCall

local function ShowPanel(frame)
    if frame and not frame:IsShown() and ShowUIPanel then
        SecureCall(ShowUIPanel, frame)
    end
end

-- Openers reuse Blizzard's own toggles through securecallfunction so opening a
-- panel to position it does not taint later protected work.
local function OpenCharacter()
    if CharacterFrame and CharacterFrame:IsShown() then return end
    if not SecureCall(_G.ToggleCharacter, "PaperDollFrame") then
        ShowPanel(CharacterFrame)
    end
end

local function OpenSpells()
    local frame = _G["PlayerSpellsFrame"]
    if frame and frame:IsShown() then return end
    local util = _G.PlayerSpellsUtil
    if util and util.TogglePlayerSpellsFrame then
        SecureCall(util.TogglePlayerSpellsFrame, 3)
    elseif _G.ToggleSpellBook then
        SecureCall(_G.ToggleSpellBook)
    end
end

local function OpenCollections()
    local frame = _G["CollectionsJournal"]
    if frame and frame:IsShown() then return end
    if _G.ToggleCollectionsJournal then
        SecureCall(_G.ToggleCollectionsJournal)
    else
        ShowPanel(frame)
    end
end

local function OpenEncounterJournal()
    local frame = _G["EncounterJournal"]
    if frame and frame:IsShown() then return end
    if _G.ToggleEncounterJournal then
        SecureCall(_G.ToggleEncounterJournal)
    else
        if EncounterJournal_LoadUI then xpcall(EncounterJournal_LoadUI, Utils.ErrorHandler) end
        ShowPanel(_G["EncounterJournal"])
    end
end

local function OpenBags()
    local frame = _G["ContainerFrameCombinedBags"]
    if frame and frame:IsShown() then return end
    if _G.OpenAllBags then SecureCall(_G.OpenAllBags) end
end

local function OpenAchievements()
    local frame = _G["AchievementFrame"]
    if frame and frame:IsShown() then return end
    if _G.ToggleAchievementFrame then SecureCall(_G.ToggleAchievementFrame) end
end

local function OpenGroupFinder()
    local frame = _G["PVEFrame"]
    if frame and frame:IsShown() then return end
    if _G.PVEFrame_ToggleFrame then SecureCall(_G.PVEFrame_ToggleFrame) end
end

local function OpenFriends()
    local frame = _G["FriendsFrame"]
    if frame and frame:IsShown() then return end
    if _G.ToggleFriendsFrame then SecureCall(_G.ToggleFriendsFrame) end
end

-- Bottom tab rows (Character/Reputation/Currency etc.) hang OUTSIDE the
-- frame's own rect; the manager adds this to the frame height when fitting
-- and centering so tabs never bleed past the target rect or the screen.
local TAB_PAD = 30

-- Ordered list. Order controls how commands appear when listed and is also the
-- tiebreak when several registered frames are shown at once and we must pick a
-- default target.
local ENTRIES = {
    {
        name = "EasyFindSearchFrame",
        labelKey = "WINDOW_TARGET_SEARCHBAR",
        keywords = { "easyfind", "search", "bar", "launcher" },
        own = true,
    },
    {
        name = "CharacterFrame",
        labelKey = "WINDOW_TARGET_CHARACTER",
        keywords = { "character", "paperdoll", "gear", "equipment" },
        uiPanel = true,
        protected = true,
        padBottom = TAB_PAD,
        open = OpenCharacter,
    },
    {
        -- Midnight 12.0 merged spellbook + talents into PlayerSpellsFrame; the
        -- legacy SpellBookFrame global no longer exists. Verify in-game.
        name = "PlayerSpellsFrame",
        labelKey = "WINDOW_TARGET_SPELLBOOK",
        keywords = { "spellbook", "spells", "talents", "abilities" },
        uiPanel = true,
        protected = true,
        padBottom = TAB_PAD,
        open = OpenSpells,
    },
    {
        name = "ContainerFrameCombinedBags",
        labelKey = "WINDOW_TARGET_BAGS",
        keywords = { "bags", "inventory", "backpack", "containers" },
        protected = true,
        open = OpenBags,
    },
    {
        name = "CollectionsJournal",
        labelKey = "WINDOW_TARGET_COLLECTIONS",
        keywords = { "collections", "mounts", "pets", "toys", "appearances" },
        uiPanel = true,
        protected = true,
        padBottom = TAB_PAD,
        open = OpenCollections,
    },
    {
        name = "EncounterJournal",
        labelKey = "WINDOW_TARGET_JOURNAL",
        keywords = { "encounter", "journal", "dungeon", "raid", "adventure" },
        uiPanel = true,
        protected = true,
        padBottom = TAB_PAD,
        open = OpenEncounterJournal,
    },
    {
        name = "AchievementFrame",
        labelKey = "WINDOW_TARGET_ACHIEVEMENTS",
        keywords = { "achievements", "achievement", "statistics" },
        uiPanel = true,
        protected = true,
        padBottom = TAB_PAD,
        open = OpenAchievements,
    },
    {
        name = "PVEFrame",
        labelKey = "WINDOW_TARGET_GROUPFINDER",
        keywords = { "group", "finder", "lfg", "dungeon", "raid", "pvp" },
        uiPanel = true,
        protected = true,
        padBottom = TAB_PAD,
        open = OpenGroupFinder,
    },
    {
        name = "FriendsFrame",
        labelKey = "WINDOW_TARGET_FRIENDS",
        keywords = { "friends", "social", "who", "quick", "join" },
        uiPanel = true,
        protected = true,
        padBottom = TAB_PAD,
        open = OpenFriends,
    },
    {
        -- No opener: the toggle global could not be verified from static
        -- inspection, so this entry moves the frame only while it is open.
        name = "CommunitiesFrame",
        labelKey = "WINDOW_TARGET_COMMUNITIES",
        keywords = { "guild", "communities", "community", "club" },
        uiPanel = true,
        protected = true,
        padBottom = TAB_PAD,
    },
    {
        -- No opener: professions open through the spellbook/profession APIs
        -- with context we cannot guess safely; move-only while open.
        name = "ProfessionsFrame",
        labelKey = "WINDOW_TARGET_PROFESSIONS",
        keywords = { "professions", "profession", "crafting", "tradeskill" },
        uiPanel = true,
        protected = true,
        padBottom = TAB_PAD,
    },
}

local byName = {}
for i = 1, #ENTRIES do byName[ENTRIES[i].name] = ENTRIES[i] end

Registry.entries = ENTRIES

function Registry:GetEntryByName(name)
    return name and byName[name] or nil
end

-- Panels discovered at runtime: any named frame shown through ShowUIPanel
-- that is not statically cataloged joins the same entries list, so focus
-- tracking, unlock dragging, edge/layout-bar snapping, and the task view
-- treat it uniformly. No labelKey -- the task view falls back to the
-- panel's own (already localized) title text.
function Registry:RegisterDynamic(frame)
    local name = frame and frame.GetName and frame:GetName()
    if not name or name == "" or byName[name] then return nil end
    if name:sub(1, 8) == "EasyFind" then return nil end
    local entry = { name = name, dynamic = true, uiPanel = true }
    ENTRIES[#ENTRIES + 1] = entry
    byName[name] = entry
    return entry
end

-- Resolve the live frame for an entry, or nil if it does not exist yet.
function Registry:GetFrame(entry)
    if not entry then return nil end
    local frame = _G[entry.name]
    if type(frame) ~= "table" or not frame.GetObjectType then return nil end
    return frame
end

function Registry:ForEach(cb)
    for i = 1, #ENTRIES do cb(ENTRIES[i]) end
end

return Registry
