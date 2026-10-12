local _, ns = ...
local L = ns.L

-- Player notes from the core: the key a player's note is filed under, and
-- "Make note" on the right-click menus of players, which opens that note in
-- the Notes companion (made when there is none). The client's menu system
-- runs additions like this one securely (Menu.ModifyMenu).

local issecret = _G.issecretvalue or function() return false end

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

local PLAYER_MENUS = {
    "PLAYER", "PARTY", "RAID_PLAYER", "RAID", "FRIEND", "FRIEND_OFFLINE", "ENEMY_PLAYER",
    "GUILD", "GUILD_OFFLINE", "COMMUNITIES_GUILD_MEMBER", "COMMUNITIES_WOW_MEMBER",
    "CHAT_ROSTER", "TARGET", "FOCUS", "RECENT_ALLY", "RECENT_ALLY_OFFLINE",
}

-- The player a menu is about: key and shown name, or nil (an NPC, yourself,
-- a name the client keeps secret).
local function MenuPlayer(contextData)
    if not contextData then return nil end
    local unit = contextData.unit
    if unit and UnitExists(unit) then
        if not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then return nil end
        local full = GetUnitName(unit, true)
        if type(full) ~= "string" or issecret(full) then return nil end
        return ns.NotesPlayerKey(full), GetUnitName(unit, false) or full
    end
    local name = contextData.name
    if type(name) ~= "string" or name == "" or issecret(name) then return nil end
    local key = ns.NotesPlayerKey(name, contextData.server)
    if key and key == ns.NotesPlayerKey(ns.PlayerName(), GetRealmName()) then return nil end
    return key, (name:match("^([^%-]+)") or name)
end

local function AddMakeNote(_, root, contextData)
    if not (EasyFind.db and EasyFind.db.notesPlayerMenu ~= false) then return end
    if not (ns.IsCompanionLoadable and ns.IsCompanionLoadable("EasyFind_Notes")) then return end
    local key, shown = MenuPlayer(contextData)
    if not key then return end
    local has = ns.Notes and ns.Notes.FindPlayerNote and ns.Notes.FindPlayerNote(key)
    root:CreateDivider()
    root:CreateButton(has and L["NOTES_OPEN_NOTE"] or L["NOTES_MAKE_NOTE"], function()
        if ns.RequestNotes() and ns.Notes.OpenPlayerNote then ns.Notes.OpenPlayerNote(key, shown) end
    end)
end

if Menu and Menu.ModifyMenu then
    for i = 1, #PLAYER_MENUS do
        Menu.ModifyMenu("MENU_UNIT_" .. PLAYER_MENUS[i], AddMakeNote)
    end
end
