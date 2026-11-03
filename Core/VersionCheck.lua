local _, ns = ...

-- Update notice from peers: an addon has no internet, so a newer EasyFind or
-- extension is heard from a guild or group member who has it. Each one is
-- said once a session in chat; EasyFind's own also shows under the list.
-- Session state only: a spoofed version decorates one session.
--
-- Wire (locale-neutral), prefix EasyFindVer:
--   Hello   "1\tH\t<version>[\t<extensions>]"
--   Version "1\tV\t<version>[\t<extensions>]"
--   extensions "GPS=1.1.0,Chat=1.0.0": addon names without "EasyFind_".
--   Older clients read the first three fields only.

local Utils = ns.Utils
local SafeAfter = Utils.SafeAfter

local EasyFind = EasyFind
local C_ChatInfo = C_ChatInfo
local C_AddOns = C_AddOns
local CreateFrame = CreateFrame
local IsInGroup, IsInRaid, IsInGuild = IsInGroup, IsInRaid, IsInGuild
local IsInInstance = IsInInstance
local smatch, sformat, ssub = string.match, string.format, string.sub
local strsplit = strsplit
local tconcat = table.concat
local random = math.random
local pcall = pcall
local print = print

local VersionCheck = {}
ns.VersionCheck = VersionCheck

local PREFIX = "EasyFindVer"
local PROTOCOL = "1"
local CMD_HELLO = "H"
local CMD_VERSION = "V"
local VERSION_PATTERN = "^%d+%.%d+%.%d+$"
local EXT_PREFIX = "EasyFind_"
-- The extension list's share of a 255-byte message.
local EXT_LIST_MAX = 200
-- Replies spread out: a fixed delay is a burst the size of the guild.
local REPLY_DELAY_MIN, REPLY_DELAY_MAX = 2, 5

-- Channels with a real roster; a whisper is unsolicited and dropped.
local ROSTER_CHANNELS = {
    GUILD = true,
    PARTY = true,
    RAID = true,
    INSTANCE_CHAT = true,
}

local newestSeen = nil
local newestExt = {}        -- short name -> newest version heard
local toldCore, toldExt = false, {}
local tellPending = false
local ownExts, ownExtList   -- short name -> version, and its wire form
local replyScheduled = {}
local guildHelloSent = false
local wasInGroup = false

local function IsValidVersion(value)
    return type(value) == "string" and smatch(value, VERSION_PATTERN) ~= nil
end

local function Meta(addon, field)
    return C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addon, field)
end

-- Released extensions: a loaded EasyFind_ addon with a CurseForge project of
-- its own (core's companions ship inside core and carry none).
local function OwnExtensions()
    if ownExts then return ownExts, ownExtList end
    ownExts = {}
    local parts, len = {}, 0
    if C_AddOns and C_AddOns.GetNumAddOns then
        local core = Meta("EasyFind", "X-Curse-Project-ID")
        for i = 1, C_AddOns.GetNumAddOns() do
            local name = C_AddOns.GetAddOnInfo(i)
            if name and ssub(name, 1, #EXT_PREFIX) == EXT_PREFIX and C_AddOns.IsAddOnLoaded(name) then
                local project, version = Meta(name, "X-Curse-Project-ID"), Meta(name, "Version")
                local short = ssub(name, #EXT_PREFIX + 1)
                local part = short .. "=" .. tostring(version)
                if project and project ~= core and IsValidVersion(version) and len + #part < EXT_LIST_MAX then
                    ownExts[short] = version
                    parts[#parts + 1] = part
                    len = len + #part + 1
                end
            end
        end
    end
    ownExtList = tconcat(parts, ",")
    return ownExts, ownExtList
end

local function ParseExts(list)
    local out = {}
    if type(list) == "string" then
        for short, version in list:gmatch("([%w_]+)=([%d%.]+)") do
            if IsValidVersion(version) then out[short] = version end
        end
    end
    return out
end

local function ExtensionTitle(short)
    local title = Meta(EXT_PREFIX .. short, "Title")
    if type(title) == "string" then title = title:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") end
    return (title and title ~= "") and title or EXT_PREFIX .. short
end

function VersionCheck:GetAvailableVersion()
    if EasyFind.db and EasyFind.db.updateNotify == false then return nil end
    return newestSeen
end

function VersionCheck:IsUpdateAvailable()
    return self:GetAvailableVersion() ~= nil
end

local function Tell()
    tellPending = false
    if EasyFind.db and EasyFind.db.updateNotify == false then return end
    local L, logo = ns.L, ns.CHAT_LOGO or ""
    if newestSeen and not toldCore then
        toldCore = true
        print(logo .. sformat(L["UPDATE_CHAT_CORE"], newestSeen, ns.version))
    end
    for short, version in pairs(newestExt) do
        if not toldExt[short] then
            toldExt[short] = true
            print(logo .. sformat(L["UPDATE_CHAT_EXT"], ExtensionTitle(short), version, ownExts[short]))
        end
    end
end

-- A second's wait: a hello's answers arrive together.
local function ScheduleTell()
    if tellPending then return end
    tellPending = true
    SafeAfter(1, Tell)
end

local function Send(channel, payload)
    if not (channel and C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
    pcall(C_ChatInfo.SendAddonMessage, PREFIX, payload, channel)
end

local function ExtTail()
    local _, list = OwnExtensions()
    return list ~= "" and "\t" .. list or ""
end

-- The hello carries our versions: peers learn them and only newer ones reply.
local function SendHello(channel)
    local tail = IsValidVersion(ns.version) and "\t" .. ns.version .. ExtTail() or ""
    Send(channel, PROTOCOL .. "\t" .. CMD_HELLO .. tail)
end

local function SendVersion(channel)
    if not IsValidVersion(ns.version) then return end
    Send(channel, PROTOCOL .. "\t" .. CMD_VERSION .. "\t" .. ns.version .. ExtTail())
end

local function GroupChannel()
    local inInstance, instanceType = IsInInstance()
    if inInstance and instanceType ~= "none" then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

-- The one place a peer's EasyFind version enters the module.
function VersionCheck:NotePeerVersion(peerVersion, channel)
    if not ROSTER_CHANNELS[channel] then return false end
    if not IsValidVersion(peerVersion) then return false end
    if not IsValidVersion(ns.version) then return false end
    if ns.CompareVersion(peerVersion, ns.version) <= 0 then return false end
    if newestSeen and ns.CompareVersion(peerVersion, newestSeen) <= 0 then return false end
    newestSeen = peerVersion
    self:RefreshSurfaces()
    ScheduleTell()
    return true
end

-- A peer's extensions: one we have in a newer version is noted.
function VersionCheck:NotePeerExtensions(list, channel)
    if not ROSTER_CHANNELS[channel] then return false end
    local mine = OwnExtensions()
    local any = false
    for short, version in pairs(ParseExts(list)) do
        local have = mine[short]
        if have and ns.CompareVersion(version, have) > 0
           and not (newestExt[short] and ns.CompareVersion(version, newestExt[short]) <= 0) then
            newestExt[short] = version
            any = true
        end
    end
    if any then ScheduleTell() end
    return any
end

-- Both surfaces are optional: the bar may not be built, the options
-- companion usually is not loaded.
function VersionCheck:RefreshSurfaces()
    if ns.Search and ns.Search.RefreshUpdateNotice then
        pcall(ns.Search.RefreshUpdateNotice, ns.Search)
    end
    if ns.Options and ns.Options.RefreshVersionLabel then
        pcall(ns.Options.RefreshVersionLabel, ns.Options)
    end
end

-- Whether our reply tells the asker anything: a newer EasyFind, or a newer
-- copy of an extension both have.
local function HaveNewer(askerVersion, askerExts)
    if not IsValidVersion(askerVersion) then return true end
    if ns.CompareVersion(ns.version, askerVersion) > 0 then return true end
    for short, version in pairs(OwnExtensions()) do
        local theirs = askerExts[short]
        if theirs and ns.CompareVersion(version, theirs) > 0 then return true end
    end
    return false
end

-- A reply that says all ours would: at least our versions everywhere.
local function Covers(version, exts)
    if not (IsValidVersion(version) and ns.CompareVersion(version, ns.version) >= 0) then return false end
    for short, mine in pairs(OwnExtensions()) do
        local theirs = exts[short]
        if not theirs or ns.CompareVersion(theirs, mine) < 0 then return false end
    end
    return true
end

local function OnHello(channel, askerVersion, askerList)
    if not ROSTER_CHANNELS[channel] then return end
    VersionCheck:NotePeerVersion(askerVersion, channel)
    VersionCheck:NotePeerExtensions(askerList, channel)
    if replyScheduled[channel] or not HaveNewer(askerVersion, ParseExts(askerList)) then return end
    replyScheduled[channel] = true
    SafeAfter(REPLY_DELAY_MIN + random() * (REPLY_DELAY_MAX - REPLY_DELAY_MIN), function()
        if not replyScheduled[channel] then return end
        replyScheduled[channel] = nil
        SendVersion(channel)
    end)
end

local function OnRosterUpdate()
    local nowInGroup = IsInGroup() or IsInRaid()
    if nowInGroup and not wasInGroup then
        SendHello(GroupChannel())
    end
    wasInGroup = nowInGroup
end

function VersionCheck:Initialize()
    if not (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) then return end

    local frame = CreateFrame("Frame")
    -- Initialize runs inside Core's PLAYER_LOGIN: a frame registered there
    -- never hears that firing, so the hello waits for PLAYER_ENTERING_WORLD.
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("GROUP_ROSTER_UPDATE")
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "PLAYER_ENTERING_WORLD" then
            pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
            -- A reload inside a group does not announce again.
            wasInGroup = IsInGroup() or IsInRaid()
            -- Guild info can read empty on a cold login: later loading
            -- screens retry until the guild answers.
            if not guildHelloSent and IsInGuild() then
                guildHelloSent = true
                SendHello("GUILD")
            end
        elseif event == "GROUP_ROSTER_UPDATE" then
            OnRosterUpdate()
        elseif event == "CHAT_MSG_ADDON" then
            local prefix, message, channel = ...
            if prefix ~= PREFIX or type(message) ~= "string" then return end
            local proto, command, value, list = strsplit("\t", message)
            if proto ~= PROTOCOL then return end
            if command == CMD_HELLO then
                OnHello(channel, value, list)
            elseif command == CMD_VERSION then
                VersionCheck:NotePeerVersion(value, channel)
                VersionCheck:NotePeerExtensions(list, channel)
                if Covers(value, ParseExts(list)) then replyScheduled[channel] = nil end
            end
        end
    end)
end

function VersionCheck:GetDiagnostics()
    local _, list = OwnExtensions()
    return {
        prefix = PREFIX,
        ownVersion = ns.version,
        ownExtensions = list,
        newestSeen = newestSeen,
        newestExtensions = newestExt,
        notifyEnabled = not (EasyFind.db and EasyFind.db.updateNotify == false),
        guildHelloSent = guildHelloSent,
        inGuild = IsInGuild() and true or false,
        groupChannel = GroupChannel(),
    }
end

-- Forgets what was heard and said, and reads the extensions again.
function VersionCheck:ResetSeen()
    newestSeen = nil
    for k in pairs(newestExt) do newestExt[k] = nil end
    for k in pairs(toldExt) do toldExt[k] = nil end
    toldCore, tellPending = false, false
    ownExts, ownExtList = nil, nil
    self:RefreshSurfaces()
end

function VersionCheck:SendHelloTo(channel)
    SendHello(channel)
end

function VersionCheck:BroadcastVersion(channel, spoofVersion)
    if spoofVersion then
        Send(channel, PROTOCOL .. "\t" .. CMD_VERSION .. "\t" .. spoofVersion)
        return
    end
    SendVersion(channel)
end
