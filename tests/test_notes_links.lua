-- Tests for long-note links (Apps/Notes/Notes.lua, NoteLink): who a reader
-- asks, what a throttled whisper does, and one answer chain per asker.

local H = require("Harness")

-- The NoteLink block alone, over a stand-in whisper channel and clock.
local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Notes/Notes.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local NoteLink = {", 1, true), "NoteLink not in Notes.lua")
    local reg = assert(src:find("if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then", s, true))
    local _, e = src:find("\nend\r?\n", reg)
    local w = { sent = {}, printed = {}, imported = {}, timers = {}, now = 0, notes = {}, results = {} }
    -- Timers fire in time order, each at its own moment.
    function w.advance(dt)
        local target = w.now + dt
        while true do
            local first
            for i, t in ipairs(w.timers) do
                if t.at <= target and (not first or t.at < w.timers[first].at) then first = i end
            end
            if not first then break end
            local t = table.remove(w.timers, first)
            w.now = t.at
            t.fn()
        end
        w.now = target
    end
    local listener
    local env = setmetatable({
        NoteByID = function(id) return w.notes[id] end,
        NoteTitle = function(note) return note.title end,
        notesNS = {
            ExportCode = function(id) return w.notes[id] and w.notes[id].code end,
            ImportCode = function(code) w.imported[#w.imported + 1] = code return true end,
            DecodeCode = function() return nil end,
        },
        ns = { NOTES_ICON_TEX = 1, PlayerName = function() return "Valeria Dawnsong" end,
               WhisperName = function() return "Valeria" end },
        Utils = {
            sformat = string.format,
            SafeAfter = function(delay, fn) w.timers[#w.timers + 1] = { at = w.now + delay, fn = fn } end,
        },
        L = setmetatable({}, { __index = function(_, k) return k end }),
        EasyFind = { Print = function(_, msg) w.printed[#w.printed + 1] = msg end },
        C_ChatInfo = {
            RegisterAddonMessagePrefix = function() end,
            SendAddonMessage = function(_, text, _, target)
                w.sent[#w.sent + 1] = { text = text, target = target }
                return table.remove(w.results, 1) or 0
            end,
        },
        Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3 } },
        UnitName = function() return "Valeria", "Dawnsong" end,
        GetNormalizedRealmName = function() return "Stormrage" end,
        GetRealmName = function() return "Stormrage" end,
        strsplit = function(sep, text)
            local out = {}
            for piece in (text .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = piece end
            return out[1], out[2], out[3], out[4], out[5], out[6]
        end,
        CreateFrame = function()
            return { RegisterEvent = function() end, SetScript = function(_, _, fn) listener = fn end }
        end,
        time = function() return 1800000000 end,
    }, { __index = _G })
    local NoteLink = assert(load(src:sub(s, e) .. "\nreturn NoteLink", "=Notes.lua NoteLink", "t", env))()
    function w.hear(text, sender) listener(nil, "CHAT_MSG_ADDON", "EFNote", text, "WHISPER", sender) end
    return NoteLink, w
end

local LONG = string.rep("x", 500)

local tests = {}

function tests.aReaderAsksTheCharacterNameNotTheSurname()
    local NoteLink = Load()
    H.assertEq(NoteLink.Owner(), "Valeria-Stormrage")
end

function tests.aThrottledWhisperGoesAgainASecondLater()
    local NoteLink, w = Load()
    w.results = { 3 }
    NoteLink.Send("Reader-Stormrage", "Q\t7")
    H.assertEq(#w.sent, 1)
    w.advance(1)
    H.assertEq(#w.sent, 2, "sent again after the throttle")
    H.assertEq(w.sent[2].text, "Q\t7")
    w.advance(5)
    H.assertEq(#w.sent, 2, "a delivered whisper is not repeated")
end

function tests.oneAnswerChainPerAskerAndNote()
    local NoteLink, w = Load()
    w.notes[3] = { title = "Raid plan", code = LONG }
    NoteLink.Key(3)
    w.hear("Q\t3\t" .. (w.notes[3].linkToken or ""), "Reader-Stormrage")
    w.hear("Q\t3\t" .. (w.notes[3].linkToken or ""), "Reader-Stormrage")
    w.advance(5)
    H.assertEq(#w.sent, 3, "500 characters in 220-character parts: one chain of 3")
    w.hear("Q\t3\t" .. (w.notes[3].linkToken or ""), "Reader-Stormrage")
    w.advance(5)
    H.assertEq(#w.sent, 6, "the chain ended, so a new ask is answered")
end

-- Only a reader holding the link's token gets the note; a guessed id gets nothing.
function tests.aGuessedIdGetsNothing()
    local NoteLink, w = Load()
    w.notes[3] = { title = "Raid plan", code = LONG }
    w.hear("Q\t3", "Stranger-Stormrage")
    w.advance(5)
    H.assertEq(#w.sent, 0, "no link made yet: nothing to take")
    local key = NoteLink.Key(3)
    H.assertEq(#w.sent, 0, "making the link sends nothing")
    local token = key:match("/3:(%x+)/")
    assert(token, "the link carries the note's token")
    w.hear("Q\t3", "Stranger-Stormrage")
    w.hear("Q\t3\t00000000", "Stranger-Stormrage")
    w.advance(5)
    H.assertEq(#w.sent, 0, "no token or a wrong one: nothing")
    w.hear("Q\t3\t" .. token, "Reader-Stormrage")
    w.advance(5)
    H.assertEq(#w.sent, 3, "the link's token: the whole note")
    H.assertEq(NoteLink.Key(3), key, "the token stays the note's own")
end

-- A reader's click asks with the token its link carries; the row shows the title.
function tests.aClickAsksWithTheLinksToken()
    local NoteLink, w = Load()
    local tail = "pValeria-Stormrage/3:a1b2c3d4/Raid plan"
    H.assertEq(NoteLink.Row(tail).name, "Raid plan")
    NoteLink.Take(tail)
    H.assertEq(w.sent[1].text, "Q\t3\ta1b2c3d4")
    H.assertEq(w.sent[1].target, "Valeria-Stormrage")
end

local pass, fail, failures = H.runSuite("Note links", tests)
return { pass = pass, fail = fail, failures = failures }
