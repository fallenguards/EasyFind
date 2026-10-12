-- Tests for the interface replacement's windows in Search/Openers.lua and
-- Shared/SecureOpeners.lua: its spellbook and talents open through its API.

local H = require("Harness")

local function Load(on)
    local env = H.newEnv()
    local opened = {}
    if on then
        env.ClassicUIForeverAPI = {
            version = 1,
            IsOn = function(name) return on[name] == true end,
            Open = function(name) opened[#opened + 1] = name return true end,
            GetFrame = function() return nil end,
        }
    end
    local ns = H.newNs(env)
    ns.SearchOpeners = {}
    H.loadModule("Search/Openers.lua", env, ns)
    H.loadModule("Shared/SecureOpeners.lua", env, ns)
    return ns, opened
end

local SPELL = { spellID = 133, category = "Spell", buttonFrame = "PlayerSpellsMicroButton" }
local TALENT = { spellID = 12345, category = "Talent" }

local tests = {}

function tests.noReplacement_rowsKeepTheClientWindow()
    local ns = Load(nil)
    H.assertEq(ns.SecureOpeners.OpenKeyForData(SPELL), "playerSpells")
    H.assertEq(ns.SecureOpeners.OpenKeyForData(TALENT), "playerSpells")
    H.assertEq(ns.SearchOpeners.Replacement("spellBook"), nil)
end

function tests.replacedSpellbook_rowsSkipTheClientWindow()
    local ns = Load({ spellBook = true })
    H.assertEq(ns.SecureOpeners.OpenKeyForData(SPELL), nil)
    H.assertEq(ns.SecureOpeners.OpenKeyForData(TALENT), "playerSpells")
end

function tests.replacedTalents_rowsSkipTheClientWindow()
    local ns = Load({ talents = true })
    H.assertEq(ns.SecureOpeners.OpenKeyForData(TALENT), nil)
end

function tests.replacementOff_whenItsSwitchIsOff()
    local ns = Load({})
    H.assertEq(ns.SearchOpeners.Replacement("talents"), nil)
end

function tests.replacedWindows_standInForTheClientFrames()
    local ns = Load({ tradeSkill = true, professionsBook = true, trainer = true })
    local function Win(visible) return { IsVisible = function() return visible end } end
    local frames = { tradeSkill = Win(true), professionsBook = Win(true), trainer = Win(false) }
    local api = ns.SearchOpeners.Replacement("tradeSkill")
    api.GetFrame = function(name) return frames[name] end
    H.assertEq(ns.SearchOpeners.ReplacementFrame("ProfessionsFrame"), frames.tradeSkill)
    H.assertEq(ns.SearchOpeners.ReplacementFrame("ProfessionsBookFrame"), frames.professionsBook)
    H.assertEq(ns.SearchOpeners.ReplacementFrame("ClassTrainerFrame"), nil, "built but hidden: not open")
end

function tests.legacyButton_opensThroughTheAPI()
    local ns, opened = Load({ legacyWindow = true })
    H.assertTrue(ns.SearchOpeners:OpenButtonFrame("LegacyMicroButton"))
    H.assertEq(opened[1], "legacyWindow")
end

local pass, fail, failures = H.runSuite("CuifOpeners", tests)
return { pass = pass, fail = fail, failures = failures }
