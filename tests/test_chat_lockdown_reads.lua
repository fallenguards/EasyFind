-- The client answers these with secret values in a chat lockdown (a boss
-- fight; SecretInChatMessagingLockdown in its API docs, Forever 1.60.1):
-- any compare on one throws (the holiday read, four errors in chat,
-- 2026-11-23). A shipped file calling one asks InChatMessagingLockdown
-- first or tests the value with issecretvalue.
local H = require("Harness")

local SECRET_IN_LOCKDOWN = {
    "C_Calendar%.EventGetInvite", "C_Calendar%.GetClubCalendarEvents", "C_Calendar%.GetDayEvent",
    "C_ChatInfo%.GetChatLineSenderGUID", "C_ChatInfo%.GetChatLineSenderName", "C_ChatInfo%.GetChatLineText",
    "C_Club%.GetClubInfo", "C_Club%.GetClubMembers", "C_Club%.GetInfoFromLastCommunityChatLine",
    "C_Club%.GetMemberInfo", "C_Club%.GetMessageInfo", "C_Club%.GetMessageRanges", "C_Club%.GetMessagesBefore",
    "C_Club%.GetMessagesInRange", "C_Club%.GetStreamInfo", "C_Club%.GetStreams", "C_Club%.GetSubscribedClubs",
    "C_Club%.IsBeginningOfStream", "C_Club%.RequestMoreMessagesBefore",
    "C_LFGList%.GetActiveEntryInfo", "C_LFGList%.GetApplicantInfo", "C_LFGList%.GetSearchResultInfo",
    "C_LFGList%.GetSearchResultLeaderInfo", "C_LFGList%.GetSearchResultPlayerInfo",
    "GetNextAvailableRaidTargetMarkerIndex", "IsRaidMarkerActive", "UnitIsAFK", "UnitIsDND",
    "C_VoiceChat%.GetChannel", "C_VoiceChat%.GetMember", "C_VoiceChat%.IsMemberMutedForAll",
    "C_VoiceChat%.IsMemberSilenced",
}

-- The calls a file makes that are secret in a lockdown, when it never asks.
local function scan(text)
    if text:find("InChatMessagingLockdown", 1, true) or text:find("issecretvalue", 1, true) then return {} end
    local hits, n = {}, 0
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        n = n + 1
        local code = line:gsub("%-%-.*$", "")
        for _, name in ipairs(SECRET_IN_LOCKDOWN) do
            if code:find("%f[%w_]" .. name .. "[%w_]*%s*[%(,]") then hits[#hits + 1] = n .. ": " .. name:gsub("%%", "") end
        end
    end
    return hits
end

local tests = {}

function tests.noShippedFileReadsALockdownSecretBlind()
    local bad, checked = {}, 0
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "r")
            if fh then
                checked = checked + 1
                for _, hit in ipairs(scan(fh:read("a"))) do bad[#bad + 1] = rel .. ":" .. hit end
                fh:close()
            end
        end
    end
    H.assertTrue(checked > 100, "expected the full file set, read " .. checked)
    H.assertEq(#bad, 0, "ask C_ChatInfo.InChatMessagingLockdown() before these:\n  " .. table.concat(bad, "\n  "))
end

function tests.scan_flagsABlindRead()
    H.assertEq(#scan("local event = C_Calendar.GetDayEvent(0, day, index)"), 1)
    H.assertEq(#scan("local ok, text = pcall(C_ChatInfo.GetChatLineText, lineID)"), 1)
    H.assertEq(#scan("if UnitIsAFK(unit) then"), 1)
end

function tests.scan_acceptsAFileThatAsks()
    H.assertEq(#scan("if C_ChatInfo.InChatMessagingLockdown() then return end\nC_Calendar.GetDayEvent(0, 1, 1)"), 0)
    H.assertEq(#scan("-- C_Calendar.GetDayEvent(0, 1, 1) answers secret in a fight"), 0)
    H.assertEq(#scan("if C_Calendar.GetDayEvent and C_Calendar.SetAbsMonth then"), 0)
end

local pass, fail, failures = H.runSuite("ChatLockdownReads", tests)
return { pass = pass, fail = fail, failures = failures }
