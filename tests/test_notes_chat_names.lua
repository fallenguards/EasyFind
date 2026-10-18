-- Tests for a player's notes on a hover over their name in chat
-- (Apps/Notes/Notes.lua): shown for a player with a note, off by the
-- switch, nothing for other links; whisper windows hooked as they open.

local H = require("Harness")

local function Load(db)
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Notes/Notes.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("do\r?\n%s*local hooked, tipFrame"), "the chat names' block not in Notes.lua")
    local _, e = src:find("\nend\r?\n", s)
    local function Window()
        local w = { scripts = {} }
        function w:HookScript(event, fn) self.scripts[event] = fn end
        return w
    end
    local tip = { lines = {} }
    function tip:SetOwner(owner) self.owner, self.lines, self.shown = owner, {}, false end
    function tip:SetText(text) self.title = text end
    function tip:AddLine(text) self.lines[#self.lines + 1] = text end
    function tip:Show() self.shown = true end
    function tip:Hide() self.shown = false end
    function tip:IsOwned(owner) return self.owner == owner end
    local opened
    local env = setmetatable({
        EasyFind = { db = db },
        GameTooltip = tip,
        CHAT_FRAMES = { "ChatFrame1", "ChatFrame2" },
        ChatFrame1 = Window(), ChatFrame2 = Window(),
        FCF_OpenTemporaryWindow = function() end,
        hooksecurefunc = function(_, fn) opened = fn end,
        ns = { NotesPlayerKey = function(name) return (name:match("^[^%-]+")) .. "-Realm" end },
        notesNS = { HasUnitNote = function(_, key) return key == "Valeria-Realm" end },
        AddShowsOnLines = function(tooltip, _, key) tooltip:AddLine("note on " .. key) end,
    }, { __index = _G })
    env._G = env
    assert(load(src:sub(s, e), "=Notes.lua chat names", "t", env))()
    return env, tip, function() return opened end
end

local tests = {}

function tests.aNameWithANoteShowsIt()
    local env, tip = Load({})
    local cf = env.ChatFrame1
    cf.scripts.OnHyperlinkEnter(cf, "player:Valeria-Realm:12:SAY")
    H.assertTrue(tip.shown)
    H.assertEq(tip.title, "Valeria")
    H.assertEq(tip.lines[1], "note on Valeria-Realm")
    cf.scripts.OnHyperlinkLeave(cf)
    H.assertFalse(tip.shown, "gone when the cursor leaves")
end

function tests.noNoteOrNotAPlayerShowsNothing()
    local env, tip = Load({})
    local cf = env.ChatFrame2
    cf.scripts.OnHyperlinkEnter(cf, "player:Someone-Realm:3:SAY")
    H.assertFalse(tip.shown == true)
    cf.scripts.OnHyperlinkEnter(cf, "item:19019")
    H.assertFalse(tip.shown == true)
end

function tests.theSwitchTurnsItOff()
    local env, tip = Load({ notesChatNames = false })
    local cf = env.ChatFrame1
    cf.scripts.OnHyperlinkEnter(cf, "player:Valeria-Realm:12:SAY")
    H.assertFalse(tip.shown == true)
end

function tests.aWhisperWindowIsHookedAsItOpens()
    local env, tip, opened = Load({})
    local w = { scripts = {} }
    function w:HookScript(event, fn) self.scripts[event] = fn end
    env.ChatFrame11 = w
    env.CHAT_FRAMES[3] = "ChatFrame11"
    opened()()
    H.assertTrue(w.scripts.OnHyperlinkEnter ~= nil)
    w.scripts.OnHyperlinkEnter(w, "player:Valeria:1:WHISPER")
    H.assertTrue(tip.shown)
end

local pass, fail, failures = H.runSuite("NotesChatNames", tests)
return { pass = pass, fail = fail, failures = failures }
