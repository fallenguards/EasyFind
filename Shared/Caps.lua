-- What this client has: each system answered once, from game rules or the API.
-- Providers, filters and options ask this table instead of probing.
local _, ns = ...

local Caps = {}
ns.Caps = Caps

local function rule(name)
    -- True when the game rule of that name is active. Unknown names and
    -- clients without game rules answer nil, never an error.
    if not (C_GameRules and C_GameRules.IsGameRuleActive and Enum and Enum.GameRule) then return nil end
    local id = Enum.GameRule[name]
    if not id then return nil end
    local ok, active = pcall(C_GameRules.IsGameRuleActive, id)
    if ok then return active and true or false end
    return nil
end
Caps.Rule = rule

local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    return nil
end

-- A Blizzard panel is there when its addon loads. The info call says "loadable" for
-- panels Forever then refuses (WRONG_GAME_TYPE): there the load is the test, cached.
local panelKnown = {}
-- Which game this is, by its project: retail, Forever (the 1.x game on the
-- mainline UI), or Classic Era and TBC Anniversary on the classic UI.
local project = WOW_PROJECT_ID
local interface = tonumber((select(4, GetBuildInfo()))) or 0
local forever = (WOW_PROJECT_CAMELOT ~= nil and project == WOW_PROJECT_CAMELOT)
    or (project == nil and interface >= 16000 and interface < 20000)
local classic = project ~= nil and (project == WOW_PROJECT_CLASSIC or project == WOW_PROJECT_BURNING_CRUSADE_CLASSIC
    or (WOW_PROJECT_MISTS_CLASSIC ~= nil and project == WOW_PROJECT_MISTS_CLASSIC))
function Caps.PanelEnabled(addonName)
    if classic then
        -- The classic UI ships different panels: one that is not an addon
        -- there is not there at all.
        local known = panelKnown[addonName]
        if known == nil then
            local ok, _, _, _, _, reason = pcall(C_AddOns.GetAddOnInfo, addonName)
            known = ok and reason ~= "MISSING" and reason ~= "DISABLED" and reason ~= "INCOMPATIBLE"
            -- The info call can answer "loadable" for another game type's
            -- panel; the load itself is the test.
            if known and not C_AddOns.IsAddOnLoaded(addonName) then
                local okL, loaded = pcall(C_AddOns.LoadAddOn, addonName)
                known = okL and loaded
            end
            known = known and true or false
            panelKnown[addonName] = known
        end
        return known
    end
    if not forever then return true end
    local known = panelKnown[addonName]
    if known ~= nil then return known end
    local ok, _, _, _, _, reason = pcall(C_AddOns.GetAddOnInfo, addonName)
    if ok and reason == "MISSING" then panelKnown[addonName] = true return true end  -- baked in, not an addon here
    if ok and (reason == "DISABLED" or reason == "INCOMPATIBLE") then panelKnown[addonName] = false return false end
    local okL, loaded, why = pcall(C_AddOns.LoadAddOn, addonName)
    local enabled = (okL and loaded) and true or (why ~= "WRONG_GAME_TYPE" and why ~= "DISABLED" and why ~= "INCOMPATIBLE")
    panelKnown[addonName] = enabled and true or false
    return panelKnown[addonName]
end

-- A toggle binding exists only for a feature the client has (Forever: no
-- TOGGLEACHIEVEMENT). Read on first use: the list is empty while files load.
local bindingSet
function Caps.HasBinding(name)
    if not bindingSet or next(bindingSet) == nil then
        bindingSet = {}
        local n = GetNumBindings and GetNumBindings() or 0
        for i = 1, n do
            local cmd = GetBinding(i)
            if type(cmd) == "string" then bindingSet[cmd] = true end
        end
        if n == 0 then return true end  -- not readable yet: fail open
    end
    return bindingSet[name] == true
end

-- The client itself.
local version, build, _, toc = GetBuildInfo()
Caps.version = version
Caps.build = tonumber(build)
Caps.interface = tonumber(toc) or 0
-- Forever: the 1.x game on the mainline codebase (interface 16001).
Caps.forever = forever
-- Classic Era and TBC Anniversary: the classic UI codebase, where most of
-- retail's systems and windows do not exist.
Caps.classic = classic
Caps.era = classic and project == WOW_PROJECT_CLASSIC
Caps.tbc = classic and project == WOW_PROJECT_BURNING_CRUSADE_CLASSIC
-- MoP Classic: the classic family too, its own windows for most systems.
Caps.mists = classic and project == WOW_PROJECT_MISTS_CLASSIC
-- Era's and Anniversary's Looking For Group window (LFGParentFrame); MoP
-- Classic has the Group Finder instead.
Caps.lfgWindow = Caps.era or Caps.tbc
Caps.retail = not forever and not classic

-- Systems. Each is a plain boolean, decided once at load.
-- Forever has the API but answers one "specialization" per class.
local classID = UnitClass and select(3, UnitClass("player"))
Caps.specs = type(GetNumSpecializationsForClassID) == "function"
    and type(GetSpecializationInfoForClassID) == "function"
    and (not classID or (call(GetNumSpecializationsForClassID, classID) or 0) > 1)
Caps.journal = rule("EncounterJournalDisabled") ~= true
    and type(EncounterJournal_LoadUI) == "function"
    and Caps.PanelEnabled("Blizzard_EncounterJournal")
-- The journal's top tabs past Dungeons and Raids (Journeys, Traveler's Log,
-- Suggested Content, Item Sets, Tutorials): MoP Classic's has none.
Caps.journalTabs = Caps.journal and not classic
-- Loot from the journal, or on WoW Forever from its shipped table.
Caps.loot = Caps.journal or Caps.forever
Caps.housing = rule("HousingDashboardDisabled") ~= true
    and rule("HousingEnabled") ~= false
    and Caps.PanelEnabled("Blizzard_HousingDashboard")
    and C_Housing ~= nil
    and not Caps.forever
Caps.achievements = rule("AchievementsPanelDisabled") ~= true
    and type(GetCategoryList) == "function"
    and Caps.PanelEnabled("Blizzard_AchievementUI")
    and not Caps.forever   -- the panel loads and is a shell; no toggle binding exists
-- Forever's client asserts on a wardrobe call without the transmog
-- location; Database.TransmogLocation supplies it on every call.
Caps.transmog = rule("TransmogEnabled") ~= false
    and C_TransmogCollection ~= nil
    and not classic
-- The journal's own tab rule shows mounts, pets and toys wherever the
-- journal loads, and heirlooms only where the game has them.
-- Era and Anniversary have no collections window; MoP Classic's has all
-- of retail's journals but the wardrobe (see Caps.transmog).
Caps.collectionsUI = Caps.PanelEnabled("Blizzard_Collections")
Caps.mounts = Caps.collectionsUI and C_MountJournal ~= nil and C_MountJournal.GetMountIDs ~= nil
Caps.pets = Caps.collectionsUI and rule("PetBattlesDisabled") ~= true and C_PetJournal ~= nil
Caps.toys = Caps.collectionsUI and C_ToyBox ~= nil
Caps.heirlooms = Caps.collectionsUI and C_Heirloom ~= nil
    and (C_HeirloomInfo == nil or call(C_HeirloomInfo.HeirloomsAvailable) ~= false)
-- On Classic Era and TBC Anniversary the currency namespace exists only
-- in part, so the API being there says nothing. A classic client counts
-- when its character window has the currency tab (MoP Classic).
local function characterTab(frameName)
    local subs = _G["CHARACTERFRAME_SUBFRAMES"]
    if type(subs) ~= "table" then return false end
    for i = 1, #subs do if subs[i] == frameName then return true end end
    return false
end
Caps.currencies = not Caps.forever and ((not classic and C_CurrencyInfo ~= nil)
    or (classic and characterTab("TokenFrame") and type(_G["GetCurrencyListSize"]) == "function"))
Caps.warbandBank = C_Bank ~= nil and C_Bank.FetchPurchasedBankTabData ~= nil and not Caps.forever
Caps.classTalents = C_ClassTalents ~= nil and C_Traits ~= nil
Caps.oldTalents = type(GetTalentInfo) == "function" and type(GetNumTalentTabs) == "function"
-- The classic clients read talents through one call: Era and Anniversary
-- by tree and index, MoP Classic by tier and column.
local talentQuery = C_SpecializationInfo ~= nil and C_SpecializationInfo.GetTalentInfo ~= nil
Caps.talentTrees = (Caps.era or Caps.tbc) and talentQuery and type(GetNumTalentTabs) == "function"
Caps.talentTiers = Caps.mists and talentQuery
Caps.talents = rule("TalentsPanelDisabled") ~= true
    and ((not classic and (Caps.classTalents or Caps.oldTalents)) or Caps.talentTrees or Caps.talentTiers)
Caps.delves = C_DelvesUI ~= nil and not Caps.forever
Caps.mythicPlus = C_MythicPlus ~= nil and not Caps.forever
Caps.perks = C_PerksProgram ~= nil and not Caps.forever
Caps.editMode = rule("EditModeDisabled") ~= true and C_EditMode ~= nil
Caps.macros = rule("MacrosDisabled") ~= true
-- The classic clients' professions are searched from the recipes each
-- window showed on the character (Database:CaptureClassicRecipes).
Caps.professions = rule("ProfessionsPanelDisabled") ~= true
    and (not classic or type(_G["GetNumTradeSkills"]) == "function")
-- Era and Anniversary keep the API and have no Equipment Manager; MoP
-- Classic has it in the character window's sidebars.
Caps.gearSets = C_EquipmentSet ~= nil and (not classic or type(_G["PAPERDOLL_SIDEBARS"]) == "table")
-- The classic character window lists skills (weapons, languages, class skills).
Caps.skills = classic and type(GetNumSkillLines) == "function" and type(GetSkillLineInfo) == "function"
Caps.outfits = Caps.transmog
Caps.ammo = rule("EnableAmmoSystem") == true
Caps.campsites = C_WarbandScene ~= nil and not Caps.forever
-- Warband-wide reputations and legacy reputation headers: retail's
-- account-wide reputation system, absent on Forever.
Caps.warbandRep = C_Reputation ~= nil and C_Reputation.IsAccountWideReputation ~= nil
    and not Caps.forever and not classic
-- C_Reputation's list, or the classic clients' GetFactionInfo list.
Caps.reputation = (C_Reputation ~= nil and C_Reputation.GetFactionDataByIndex ~= nil)
    or (type(_G["GetNumFactions"]) == "function" and type(_G["GetFactionInfo"]) == "function")
-- Native map waypoints and the arrow that follows them.
Caps.waypoints = C_Map ~= nil and C_Map.SetUserWaypoint ~= nil and C_SuperTrack ~= nil and UiMapPoint ~= nil
Caps.pvpUI = Caps.PanelEnabled("Blizzard_PVPUI")
Caps.groupFinder = Caps.PanelEnabled("Blizzard_GroupFinder")

-- The panel a UI entry's steps open, by the frame they wait for, and the binding
-- behind each micro button: an entry is offered only when both are there.
Caps.FRAME_PANEL = {
    PVEFrame = "Blizzard_GroupFinder", GroupFinderFrame = "Blizzard_GroupFinder", PVPQueueFrame = "Blizzard_PVPUI",
    EncounterJournal = "Blizzard_EncounterJournal", AchievementFrame = "Blizzard_AchievementUI",
    CollectionsJournal = "Blizzard_Collections", PlayerSpellsFrame = "Blizzard_PlayerSpells",
    MacroFrame = "Blizzard_MacroUI", ProfessionsFrame = "Blizzard_Professions", HousingDashboardFrame = "Blizzard_HousingDashboard",
    CommunitiesFrame = "Blizzard_Communities", CalendarFrame = "Blizzard_Calendar",
}
Caps.BUTTON_BINDING = {
    AchievementMicroButton = "TOGGLEACHIEVEMENT", EJMicroButton = "TOGGLEENCOUNTERJOURNAL",
    CollectionsMicroButton = "TOGGLECOLLECTIONS", LFDMicroButton = "TOGGLEGROUPFINDER",
    GuildMicroButton = "TOGGLEGUILDTAB", TalentMicroButton = "TOGGLETALENTS", QuestLogMicroButton = "TOGGLEQUESTLOG",
}

-- Why a UI entry cannot be reached on this client, or nil.
-- Cheap: table lookups and one cached binding scan.
function Caps.UIEntryBlocked(entry)
    -- A node may name the system it needs outright (caps = "pets").
    if entry.caps and Caps[entry.caps] == false then return "no " .. entry.caps end
    -- PvP entries (queues, PvP talents, war mode) need the PvP window.
    if entry.isPvP and not Caps.pvpUI then return "Blizzard_PVPUI disabled" end
    local bf = entry.buttonFrame
    if bf then
        local binding = Caps.BUTTON_BINDING[bf]
        if binding and not Caps.HasBinding(binding) then return "no " .. binding end
        local b = _G[bf]
        if not b then return "no " .. bf end
        -- A hidden micro button counts only off retail: Classic keeps every
        -- flavor's buttons as hidden frames, and retail hides Help.
        if (Caps.forever or Caps.classic) and b.IsShown and not b:IsShown() then return bf .. " hidden" end
    end
    local steps = entry.steps
    if steps then
        for i = 1, #steps do
            local s = steps[i]
            local panel = s.waitForFrame and Caps.FRAME_PANEL[s.waitForFrame]
            if panel and not Caps.PanelEnabled(panel) then return panel .. " disabled" end
            -- Classic: a frame still missing once its addon is in is not
            -- on this client (PVEFrame loads for Wrath and later only).
            if Caps.classic and s.waitForFrame then
                local root = s.waitForFrame:match("^[^.]+")
                if not _G[root] and (not panel or C_AddOns.IsAddOnLoaded(panel)) then return "no " .. root end
            end
            if s.waitForFrame == "CharacterFrame" and CharacterFrame and (s.tabIndex or s.tabFrame)
                and not Caps.CharacterTab(s.tabFrame or s.tabIndex) then
                return "no character tab " .. tostring(s.tabFrame or s.tabIndex)
            end
            if s.sidebarIndex and not Caps.CharacterSidebarSlot(s.sidebarIndex) then
                return "no character sidebar " .. s.sidebarIndex
            end
            if s.buttonFrame then
                local binding = Caps.BUTTON_BINDING[s.buttonFrame]
                if binding and not Caps.HasBinding(binding) then return "no " .. binding end
            end
        end
    end
    return nil
end

-- The character panel, by what each control opens rather than by its
-- number. Entries carry retail's numbers: tab 1 Character, 2 Reputation,
-- 3 Currency; sidebar 1 Stats, 2 Titles, 3 Equipment Manager. Forever
-- draws mode tabs that name their frame (CharacterFrameModeTab<n> with a
-- frameName field) and orders its sidebar Stats, Equipment Manager,
-- Titles, Pet (Titles since build 70170), so the number is looked up
-- here and nil means "not on this client".
local CHARACTER_TAB_FRAME = { [1] = "PaperDollFrame", [2] = "ReputationFrame", [3] = "TokenFrame" }
local SIDEBAR_FRAME = { [1] = "CharacterStatsPane", [2] = "PaperDollTitlesPane", [3] = "PaperDollEquipmentManagerPane" }
-- Forever's sidebar list carries names, not frames: the same global
-- strings on both clients.
local SIDEBAR_NAME = { [1] = "PAPERDOLL_SIDEBAR_STATS", [2] = "PAPERDOLL_SIDEBAR_TITLES", [3] = "PAPERDOLL_EQUIPMENTMANAGER" }

-- Classic's own names for subframes the entries name Forever's way.
local CLASSIC_SUBFRAME = { SkillsFrame = { "SkillFrame" }, PVPRankFrame = { "HonorFrame", "PVPFrame" } }

-- This client's name for a character subframe, or nil when it has none.
function Caps.CharacterSubframe(name)
    local subs = _G["CHARACTERFRAME_SUBFRAMES"]
    if not (Caps.classic and type(subs) == "table") then return name end
    local own = CLASSIC_SUBFRAME[name]
    for i = 1, #subs do
        if subs[i] == name then return name end
        for j = 1, own and #own or 0 do
            if subs[i] == own[j] then return own[j] end
        end
    end
    return nil
end

-- The live tab control for a retail tab number or a subframe name
-- ("SkillsFrame"), or nil.
function Caps.CharacterTab(tabIndex)
    local want = type(tabIndex) == "string" and tabIndex or CHARACTER_TAB_FRAME[tabIndex]
    if type(tabIndex) == "string" then
        -- Retail numbers its tabs; the name maps back to one there.
        for i, f in pairs(CHARACTER_TAB_FRAME) do if f == tabIndex then tabIndex = i end end
    end
    local tabs = _G["CharacterFrameModeTabs"]
    if tabs and want then
        for i = 1, select("#", tabs:GetChildren()) do
            local tab = select(i, tabs:GetChildren())
            if tab and tab.frameName == want then return tab end
        end
        return nil
    end
    -- Classic lists its tabs by the frame each opens, in its own order
    -- (Character, Pet, Reputation, Skills, Honor or PvP).
    local subs = _G["CHARACTERFRAME_SUBFRAMES"]
    if Caps.classic and type(subs) == "table" then
        want = want and Caps.CharacterSubframe(want)
        for i = 1, #subs do
            if subs[i] == want then return _G["CharacterFrameTab" .. i] end
        end
        return nil
    end
    if type(tabIndex) ~= "number" then return nil end
    local tab = _G["CharacterFrameTab" .. tabIndex]
    if not tab and CharacterFrame and CharacterFrame.Tabs then tab = CharacterFrame.Tabs[tabIndex] end
    return tab
end

-- Collections tabs by their label, not retail's number: Forever draws one
-- tab (Appearances) where retail draws six. Both read the same global.
local COLLECTIONS_TAB_LABEL = {
    [1] = "MOUNTS", [2] = "PET_JOURNAL", [3] = "TOY_BOX",
    [4] = "HEIRLOOMS", [5] = "WARDROBE", [6] = "WARBAND_SCENES",
}

-- The live collections tab control for a retail tab number, or nil. The
-- classic-rules journal keeps its tabs unnamed in its TabContainer, each
-- carrying the tooltip text of the tab it stands for.
function Caps.CollectionsTab(tabIndex)
    local direct = _G["CollectionsJournalTab" .. tostring(tabIndex)]
    if direct or not Caps.forever then return direct end
    local container = CollectionsJournal and CollectionsJournal.TabContainer
    local tabs = container and container.Tabs
    if not tabs then return nil end
    local key = COLLECTIONS_TAB_LABEL[tabIndex]
    local want = key and _G[key]
    for i = 1, #tabs do
        if want and tabs[i].tooltipText == want then return tabs[i] end
    end
    return tabs[tabIndex]
end

-- The live sidebar slot for a retail sidebar number, or nil. Blizzard
-- lists the sidebars in PAPERDOLL_SIDEBARS with the pane each opens.
function Caps.CharacterSidebarSlot(sidebarIndex)
    -- Era's and Anniversary's character window has no sidebar.
    if Caps.classic and type(_G["PAPERDOLL_SIDEBARS"]) ~= "table" then return nil end
    local want = SIDEBAR_FRAME[sidebarIndex]
    local wantName = SIDEBAR_NAME[sidebarIndex] and _G[SIDEBAR_NAME[sidebarIndex]]
    local list = _G["PAPERDOLL_SIDEBARS"]
    if type(list) == "table" and want then
        for i = 1, #list do
            local s = list[i]
            if type(s) == "table" and (s.frame == want or (wantName and s.name == wantName)) then return i end
        end
        -- Only the classic-rules client drops a sidebar; retail keeps its
        -- numbers whatever the list looks like.
        return Caps.forever and nil or sidebarIndex
    end
    return sidebarIndex
end

-- Classic's portrait menu has no Self Highlight entry. The calendar came
-- with Wrath: Era's and Anniversary's clock opens none, MoP Classic's does.
Caps.selfHighlight = not classic
Caps.calendar = not (Caps.era or Caps.tbc)
-- Era has no titles to pick: a PvP rank shows by the name on its own.
-- TBC picks one from a dropdown on the character sheet.
Caps.titles = not Caps.era

-- Era lacks the quest log atlas sheet (cog, plus, minus, row glow); MoP
-- Classic keeps its old quest log, so it is not counted on there either.
Caps.questLogAtlas = not (Caps.era or Caps.mists)

-- The item catalog and icon list are built from retail's files.
Caps.itemCatalog = not classic
Caps.iconSearch = not classic

-- Spell ranks: Forever has them; retail's spells carry no rank text.
Caps.spellRanks = Caps.forever and C_Spell ~= nil and C_Spell.GetSpellSubtext ~= nil

-- Providers and filter keys by the system they need: a key whose system is
-- missing is dropped from providers, filters and quick filters at load.
local NEEDS = {
    pets = "pets", toys = "toys", heirlooms = "heirlooms", currencies = "currencies",
    housing = "housing", loot = "loot", bosses = "journal", delves = "delves", delve = "delves",
    warband = "warbandBank", achievements = "achievements", statistics = "achievements",
    talents = "talents", outfits = "outfits", appearances = "transmog",
    transmogSets = "transmog", appearanceItems = "transmog", mounts = "mounts",
    perks = "perks", macros = "macros", professions = "professions", gearSets = "gearSets",
    reputations = "reputation", catalog = "itemCatalog", icons = "iconSearch",
    collections = "collectionsUI", titles = "titles", skills = "skills",
}
Caps.NEEDS = NEEDS

-- True when the feature behind a provider or filter key exists here. Keys
-- with no entry are always available.
function Caps.Has(key)
    local need = NEEDS[key]
    if not need then return true end
    return Caps[need] and true or false
end

-- Prune a list of { key = ... } rows in place, and any flyoutSubFilters
-- under them, to what this client has.
function Caps.PruneRows(rows)
    if type(rows) ~= "table" then return rows end
    for i = #rows, 1, -1 do
        local row = rows[i]
        if type(row) == "table" and row.key and not Caps.Has(row.key) then
            table.remove(rows, i)
        elseif type(row) == "table" then
            -- A group whose every member is gone goes with them.
            if row.flyoutSubFilters and #row.flyoutSubFilters > 0
               and #Caps.PruneRows(row.flyoutSubFilters) == 0 then
                table.remove(rows, i)
            end
            -- Choices inside a flyout may name a system too (caps = "warbandRep").
            local radio = row.flyoutRadio
            if radio then
                local pruned = false
                for _, list in ipairs({ radio.options, radio.checkboxes }) do
                    if type(list) == "table" then
                        for j = #list, 1, -1 do
                            local opt = list[j]
                            if type(opt) == "table" and opt.caps and Caps[opt.caps] == false then
                                table.remove(list, j)
                                pruned = true
                            end
                        end
                    end
                end
                -- One choice left is no choice: the row becomes a plain toggle.
                if pruned and type(radio.options) == "table" and #radio.options < 2
                   and not (radio.checkboxes and #radio.checkboxes > 0) then
                    row.flyoutRadio = nil
                end
            end
        end
    end
    return rows
end

-- One line for /dump or a dev tool.
function Caps.Summary()
    local on, off = {}, {}
    for k, v in pairs(Caps) do
        if type(v) == "boolean" then
            if v then on[#on + 1] = k else off[#off + 1] = k end
        end
    end
    table.sort(on) table.sort(off)
    return string.format("%s (%s) on: %s | off: %s", tostring(version), tostring(toc), table.concat(on, " "), table.concat(off, " "))
end

-- The reputation list on any client, in retail's C_Reputation fields: the
-- classic clients' GetFactionInfo mapped onto them. Either list counts only
-- the rows under expanded headers. listed: a classic row, discovered by
-- standing in the list at all.
function Caps.ClassicFaction(name, _, standingID, barMin, barMax, barValue, _, _, isHeader, isCollapsed, hasRep,
                             isWatched, isChild, factionID)
    if not name then return nil end
    return { name = name, factionID = factionID, isHeader = isHeader, isCollapsed = isCollapsed,
             isHeaderExpanded = not isCollapsed, isHeaderWithRep = hasRep, isWatched = isWatched, isChild = isChild,
             reaction = standingID, currentStanding = barValue, currentReactionThreshold = barMin,
             nextReactionThreshold = barMax, listed = true }
end

function Caps.NumFactions()
    local R = C_Reputation
    if R and R.GetNumFactions then return R.GetNumFactions() or 0 end
    local count = _G["GetNumFactions"]
    return count and count() or 0
end

function Caps.FactionAt(index)
    local R = C_Reputation
    if R and R.GetFactionDataByIndex then return R.GetFactionDataByIndex(index) end
    local get = _G["GetFactionInfo"]
    return get and Caps.ClassicFaction(get(index)) or nil
end

-- By id, under a collapsed header too where the client can; else the list.
function Caps.FactionByID(factionID)
    local R = C_Reputation
    if R and R.GetFactionDataByID then return R.GetFactionDataByID(factionID) end
    local get = _G["GetFactionInfoByID"]
    if get then return Caps.ClassicFaction(get(factionID)) end
    for i = 1, Caps.NumFactions() do
        local data = Caps.FactionAt(i)
        if data and data.factionID == factionID then return data end
    end
    return nil
end

function Caps.SetFactionHeaderExpanded(index, expanded)
    local R = C_Reputation
    local name = expanded and "ExpandFactionHeader" or "CollapseFactionHeader"
    local fn = (R and R[name]) or _G[name]
    if fn then fn(index) end
end

-- The currency list on any client, in retail's C_CurrencyInfo fields: MoP
-- Classic's GetCurrencyListInfo mapped onto them, its id read from the
-- row's link.
function Caps.NumCurrencies()
    local C = C_CurrencyInfo
    if C and C.GetCurrencyListSize then return C.GetCurrencyListSize() or 0 end
    local size = _G["GetCurrencyListSize"]
    return size and size() or 0
end

function Caps.CurrencyAt(index)
    local C = C_CurrencyInfo
    if C and C.GetCurrencyListInfo then return C.GetCurrencyListInfo(index) end
    local get = _G["GetCurrencyListInfo"]
    if not get then return nil end
    local name, isHeader, isExpanded, isUnused, isWatched, count, icon = get(index)
    if not name or name == "" then return nil end
    local link = C and C.GetCurrencyListLink and C.GetCurrencyListLink(index)
    return { name = name, isHeader = isHeader, isHeaderExpanded = isExpanded, isTypeUnused = isUnused,
             isShowInBackpack = isWatched, quantity = count, iconFileID = icon,
             currencyID = type(link) == "string" and tonumber(link:match("currency:(%d+)")) or nil }
end

function Caps.SetCurrencyHeaderExpanded(index, expanded)
    local C = C_CurrencyInfo
    if C and C.ExpandCurrencyList then
        C.ExpandCurrencyList(index, expanded)
    elseif _G["ExpandCurrencyList"] then
        _G["ExpandCurrencyList"](index, expanded and 1 or 0)
    end
end
