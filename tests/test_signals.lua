-- Tests for Shared/Signals.lua: the signals a clock run or an alert fires.

local H = require("Harness")

local function Load()
    local env = H.newEnv()
    local log = { sounds = {}, prints = {}, flashes = 0 }
    env.SOUNDKIT = { ALARM_CLOCK_WARNING_3 = 12889, RAID_WARNING = 8959 }
    env.PlaySound = function(kit, channel) log.sounds[#log.sounds + 1] = { kit, channel } end
    env.FlashClientIcon = function() log.flashes = log.flashes + 1 end
    local ns = H.newNs(env)
    env.EasyFind.Print = function(_, text) log.prints[#log.prints + 1] = text end
    ns.GOLD_COLOR = { 1, 0.82, 0 }
    H.loadModule("Shared/Signals.lua", env, ns)
    return ns.Signals, log
end

local tests = {}

function tests.fire_playsTheChosenSoundOnMaster()
    local S, log = Load()
    S.Fire({ sound = "raidwarning" }, "x")
    H.assertEq(log.sounds[1][1], 8959)
    H.assertEq(log.sounds[1][2], "Master")
end

function tests.fire_quietKeepsToText()
    local S, log = Load()
    S.Fire({ chat = true, sound = "alarm", taskbar = true }, "Flask ends", true)
    H.assertEq(log.prints[1], "Flask ends")
    H.assertEq(#log.sounds, 0)
    H.assertEq(log.flashes, 0)
end

function tests.fire_onlyWhatTheSpecAsks()
    local S, log = Load()
    S.Fire({ taskbar = true }, "x")
    H.assertEq(#log.prints, 0)
    H.assertEq(#log.sounds, 0)
    H.assertEq(log.flashes, 1)
end

function tests.unknownSound_isSilentAndLabeledNone()
    local S, log = Load()
    S.PlaySound("nope")
    H.assertEq(#log.sounds, 0)
    H.assertNotNil(S.SoundLabel("nope"))
end

function tests.everySoundAndColorHasALabel()
    local S = Load()
    for _, s in ipairs(S.SOUNDS) do H.assertNotNil(s.label, s.key) end
    for _, c in ipairs(S.COLORS) do H.assertNotNil(c.label, c.key) end
end

local pass, fail, failures = H.runSuite("Signals", tests)
return { pass = pass, fail = fail, failures = failures }
