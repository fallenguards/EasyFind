local _, ns = ...
local L = ns.L

-- Unit notes from the core: the key a player's note is filed under, the
-- tag a unit becomes, and "Make note" on the right-click menus of players
-- and NPCs, which opens that note in the Notes companion (made when there
-- is none). The client's menu system runs additions like this one
-- securely (Menu.ModifyMenu).

local issecret = _G.issecretvalue or function() return false end
local sformat = string.format

local function Realm(realm)
    if type(realm) == "string" and realm ~= "" and not issecret(realm) then return (realm:gsub("%s", "")) end
    local own = GetNormalizedRealmName and GetNormalizedRealmName()
    if not own or own == "" then own = ((GetRealmName and GetRealmName()) or ""):gsub("%s", "") end
    return own
end

-- First name and realm, no spaces: a Forever surname ("First Surname") is
-- left out, so one player keeps one key however a client shows the name.
function ns.NotesPlayerKey(name, realm)
    if type(name) ~= "string" or name == "" or issecret(name) then return nil end
    local base, inName = name:match("^([^%-]+)%-(.+)$")
    base = (base or name):match("^(%S+)")
    if not base then return nil end
    return base .. "-" .. Realm(inName or realm)
end

-- A unit as a note tag: a player by key, a creature by its NPC id; nil
-- for yourself, pets and names the client keeps secret.
function ns.NotesUnitEntry(unit)
    if not (unit and UnitExists(unit)) or UnitIsUnit(unit, "player") then return nil end
    if UnitIsPlayer(unit) then
        local full = GetUnitName(unit, true)
        if type(full) ~= "string" or issecret(full) then return nil end
        local key = ns.NotesPlayerKey(full)
        return key and { type = "player", id = key, name = GetUnitName(unit, false) or full } or nil
    end
    local guid = UnitGUID(unit)
    if type(guid) ~= "string" or issecret(guid) then return nil end
    local npcID = tonumber(guid:match("Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-"))
    if not npcID then return nil end
    local name = UnitName(unit)
    if type(name) ~= "string" or issecret(name) then name = nil end
    return { type = "npc", id = npcID, name = name or sformat(L["NOTES_NPC_FMT"], npcID) }
end

local UNIT_MENUS = {
    "PLAYER", "PARTY", "RAID_PLAYER", "RAID", "FRIEND", "FRIEND_OFFLINE", "ENEMY_PLAYER",
    "GUILD", "GUILD_OFFLINE", "COMMUNITIES_GUILD_MEMBER", "COMMUNITIES_WOW_MEMBER",
    "CHAT_ROSTER", "TARGET", "FOCUS", "BOSS", "RECENT_ALLY", "RECENT_ALLY_OFFLINE",
}

-- The unit a menu is about as a tag, or nil (yourself, a name the client
-- keeps secret).
local function MenuUnit(contextData)
    if not contextData then return nil end
    local unit = contextData.unit
    if unit and UnitExists(unit) then return ns.NotesUnitEntry(unit) end
    local name = contextData.name
    if type(name) ~= "string" or name == "" or issecret(name) then return nil end
    local key = ns.NotesPlayerKey(name, contextData.server)
    if not key or key == ns.NotesPlayerKey(ns.PlayerName(), GetRealmName()) then return nil end
    return { type = "player", id = key, name = name:match("^([^%-]+)") or name }
end

local function AddMakeNote(_, root, contextData)
    if not (EasyFind.db and EasyFind.db.notesPlayerMenu ~= false) then return end
    if not (ns.IsCompanionLoadable and ns.IsCompanionLoadable("EasyFind_Notes")) then return end
    local entry = MenuUnit(contextData)
    if not entry then return end
    local has = ns.Notes and ns.Notes.FindUnitNote and ns.Notes.FindUnitNote(entry)
    root:CreateDivider()
    root:CreateButton(has and L["NOTES_OPEN_NOTE"] or L["NOTES_MAKE_NOTE"], function()
        if ns.RequestNotes() and ns.Notes.OpenUnitNote then ns.Notes.OpenUnitNote(entry) end
    end)
end

if Menu and Menu.ModifyMenu then
    for i = 1, #UNIT_MENUS do
        Menu.ModifyMenu("MENU_UNIT_" .. UNIT_MENUS[i], AddMakeNote)
    end
end

-- Ctrl+right-click on an item (bags, bank, character, loot) or a spell in
-- the spellbook opens its note, made when there is none, shown on its
-- tooltip as a portrait's is. The game does nothing else with that click:
-- its modified-click handlers have no action for it.
local function CtrlRightClick()
    return IsControlKeyDown() and not IsShiftKeyDown() and not IsAltKeyDown()
        and GetMouseButtonClicked and GetMouseButtonClicked() == "RightButton"
end

local function OpenObjectNote(entry)
    if not (EasyFind.db and EasyFind.db.notesPlayerMenu ~= false) then return end
    if not (ns.IsCompanionLoadable and ns.IsCompanionLoadable("EasyFind_Notes")) then return end
    if ns.RequestNotes() and ns.Notes.OpenUnitNote then ns.Notes.OpenUnitNote(entry) end
end

if hooksecurefunc then
    hooksecurefunc("HandleModifiedItemClick", function(link)
        if type(link) ~= "string" or issecret(link) or not CtrlRightClick() then return end
        local id = tonumber(link:match("|Hitem:(%d+)"))
        if id then OpenObjectNote({ type = "item", id = id, name = link:match("%[(.-)%]") or tostring(id) }) end
    end)
end

-- The spellbook's entries take their methods from its item mixin when they
-- are made, which is when the book first shows: hooked as it loads.
local spellBookHooked = false
local function HookSpellBook()
    local mixin = _G.SpellBookItemMixin
    if spellBookHooked or not (mixin and mixin.OnModifiedIconClick and hooksecurefunc) then return end
    spellBookHooked = true
    hooksecurefunc(mixin, "OnModifiedIconClick", function(self, button)
        if button ~= "RightButton" or not CtrlRightClick() then return end
        local info = self.spellBookItemInfo
        local id = info and info.spellID
        if type(id) == "number" then
            OpenObjectNote({ type = "spell", id = id, name = info.name or tostring(id) })
        end
    end)
end
do
    local watch = CreateFrame("Frame")
    watch:RegisterEvent("ADDON_LOADED")
    watch:SetScript("OnEvent", function(self, _, name)
        if name ~= "Blizzard_PlayerSpells" then return end
        HookSpellBook()
        self:UnregisterAllEvents()
    end)
    if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_PlayerSpells") then
        HookSpellBook()
        watch:UnregisterAllEvents()
    end
end
