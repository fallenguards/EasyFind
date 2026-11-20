-- People as rows (2026-11-19): the friends list and the guild roster, each
-- with where they are; a click whispers, Shift invites. Nothing is saved.
local H = require("Harness")

local function World()
    local env = H.newEnv()
    env._G = env
    local ns = H.newNs(env)
    ns.L.CHAR_LEVEL_FMT = "Level %d"
    env.UNIT_LEVEL_TEMPLATE = "Level %d"
    env.LOCALIZED_CLASS_NAMES_MALE = { MAGE = "Magier", ROGUE = "Schurke" }
    env.LOCALIZED_CLASS_NAMES_FEMALE = { MAGE = "Magierin" }
    env.CLASS_ICON_TCOORDS = { MAGE = { 0, 0.25, 0, 0.25 } }
    env.RAID_CLASS_COLORS = { MAGE = { r = 0.25, g = 0.78, b = 0.92 } }
    env.Ambiguate = function(name) return (name:gsub("%-.*$", "")) end
    local t = { frames = {}, dirty = {}, asked = { friends = 0, guild = 0 }, told = {}, invited = {} }
    env.CreateFrame = function()
        local f = H.newFrame()
        t.frames[#t.frames + 1] = f
        return f
    end
    env.C_FriendList = {
        ShowFriends = function() t.asked.friends = t.asked.friends + 1 end,
        GetNumFriends = function() return 2 end,
        GetFriendInfoByIndex = function(i)
            if i == 1 then return { name = "Jaina", connected = true, level = 60, className = "Magierin", area = "Orgrimmar" } end
            return { name = "Bob-Other", connected = false, level = 12, className = "Schurke" }
        end,
    }
    env.BNGetNumFriends = function() return 3 end
    env.BNET_CLIENT_WOW = "WoW"
    env.C_BattleNet = { GetFriendAccountInfo = function(i)
        if i == 1 then
            return { accountName = "|Kq1|k", battleTag = "Thrall#1234",
                     gameAccountInfo = { isOnline = true, clientProgram = "WoW", characterName = "Gorehowl", realmName = "Realm",
                                         className = "Magier", characterLevel = 30, areaName = "Durotar" } }
        elseif i == 2 then
            return { accountName = "|Kq2|k", battleTag = "Sylvanas#99",
                     gameAccountInfo = { isOnline = true, clientProgram = "App", richPresence = "Mobile" } }
        end
        -- The same Jaina, a Battle.net friend too.
        return { accountName = "|Kq3|k", battleTag = "Jaina#5",
                 gameAccountInfo = { isOnline = true, clientProgram = "WoW", characterName = "Jaina", className = "Magierin" } }
    end }
    env.IsInGuild = function() return true end
    env.UnitGUID = function() return "Player-1-ME" end
    env.C_GuildInfo = { GuildRoster = function() t.asked.guild = t.asked.guild + 1 end }
    env.GetNumGuildMembers = function() return 3 end
    env.GetGuildRosterInfo = function(i)
        if i == 1 then return "Me-Realm", "Guild Master", 0, 60, "Magier", "Orgrimmar", "", "", true, 0, "MAGE", 0, 0, false, false, 0, "Player-1-ME" end
        if i == 2 then return "Voljin-Realm", "Officer", 1, 58, "Schurke", "Stranglethorn", "", "", true, 0, "ROGUE", 0, 0, false, false, 0, "Player-1-V" end
        return "Cairne-Realm", "Member", 3, 40, "Magier", "Mulgore", "", "", false, 0, "MAGE", 0, 0, false, false, 0, "Player-1-C"
    end
    env.ChatFrame_SendTell = function(name) t.told[#t.told + 1] = name end
    env.ChatFrame_SendBNetTell = function(account) t.told[#t.told + 1] = "bnet:" .. account end
    env.C_PartyInfo = { InviteUnit = function(name) t.invited[#t.invited + 1] = name end }
    ns.Database.uiSearchData = {}
    ns.Database.RemoveEntriesByCategory = function(category)
        local data = ns.Database.uiSearchData
        for i = #data, 1, -1 do if data[i].category == category then table.remove(data, i) end end
    end
    ns.Database.MarkDynamicCategoryDirty = function(_, key) t.dirty[#t.dirty + 1] = key end
    H.loadModule("Database/Social.lua", env, ns)
    return ns, t, env
end

local function ByName(ns)
    local out = {}
    for _, row in ipairs(ns.Database.uiSearchData) do out[row.name] = row end
    return out
end

local tests = {}

function tests.friends_theCharactersAndBattleNets_eachOnce()
    local ns, t = World()
    ns.Database:PopulateDynamicFriends()
    local rows = ByName(ns)
    H.assertEq(#ns.Database.uiSearchData, 4, "Jaina, Bob, Gorehowl, Sylvanas: Jaina not twice")
    H.assertEq(rows.Jaina.searchCommandDesc, "Level 60 Magierin, Orgrimmar")
    H.assertEq(rows.Jaina.nameHex, "|cff3fc6ea", "her class's color, by the class's name in the client's language")
    H.assertEq(rows.Jaina.category, "Friend")
    H.assertEq(rows.Bob.searchCommandDesc, "Offline")
    H.assertEq(rows.Bob.socialName, "Bob-Other", "whispered with his realm")
    H.assertEq(rows.Gorehowl.socialName, "Gorehowl-Realm", "a Battle.net friend in the game: the character")
    H.assertEq(rows.Gorehowl.searchCommandDesc, "Level 30 Magier, Durotar")
    H.assertEq(rows.Sylvanas.socialBNet, "|Kq2|k", "one not in the game: the account")
    H.assertNil(rows.Sylvanas.socialName)
    H.assertTrue(rows.Jaina.noPin and rows.Jaina.noLearn, "nothing of a person is saved")
    H.assertEq(t.asked.friends, 1, "the list is asked for")
end

function tests.guild_everyMemberButThePlayer()
    local ns, t = World()
    ns.Database:PopulateDynamicGuildMembers()
    local rows = ByName(ns)
    H.assertEq(#ns.Database.uiSearchData, 2)
    H.assertEq(rows.Voljin.searchCommandDesc, "Level 58 Schurke, Stranglethorn, Officer")
    H.assertEq(rows.Voljin.socialName, "Voljin-Realm")
    H.assertEq(rows.Cairne.searchCommandDesc, "Offline, Member")
    H.assertEq(rows.Cairne.category, "Guild Member")
    ns.Database:PopulateDynamicGuildMembers()
    H.assertEq(t.asked.guild, 1, "the roster is not asked for at every populate")
end

function tests.aClickWhispers_shiftInvites()
    local ns, t = World()
    ns.Database:PopulateDynamicFriends()
    local rows = ByName(ns)
    ns.Social.Select(rows.Gorehowl, false)
    H.assertEq(t.told[1], "Gorehowl-Realm")
    ns.Social.Select(rows.Gorehowl, true)
    H.assertEq(t.invited[1], "Gorehowl-Realm")
    ns.Social.Select(rows.Sylvanas, true)
    H.assertEq(#t.invited, 1, "no character to invite")
    H.assertEq(t.told[2], "bnet:|Kq2|k", "a whisper through the account instead")
end

function tests.news_makesTheRowsAgain_aBurstOnce()
    local ns, t, env = World()
    local watcher = t.frames[#t.frames]
    for _ = 1, 5 do watcher._handlers.OnEvent(watcher, "BN_FRIEND_INFO_CHANGED") end
    watcher._handlers.OnEvent(watcher, "GUILD_ROSTER_UPDATE")
    H.assertEq(#t.dirty, 0, "not inside the events")
    env._clock:advance(3)
    table.sort(t.dirty)
    H.assertEq(table.concat(t.dirty, ","), "friends,guildMembers")
    H.assertTrue(ns ~= nil)
end

local pass, fail, failures = H.runSuite("Social", tests)
return { pass = pass, fail = fail, failures = failures }
