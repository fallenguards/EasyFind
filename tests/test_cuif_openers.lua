-- Tests for the interface replacement's windows in Search/Openers.lua and
-- Shared/SecureOpeners.lua: its spellbook and talents open through its API.

local H = require("Harness")

local function Load(on, classic)
    local env = H.newEnv()
    env._G = env
    -- Retail and Forever have the combined spells window's button; the
    -- classic clients do not.
    if not classic then env.PlayerSpellsMicroButton = {} end
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
    ns.Utils.IsSpellbookOnlyAbility = ns.Utils.IsSpellbookOnlyAbility or function() return false end
    H.loadModule("Search/Openers.lua", env, ns)
    H.loadModule("Shared/SecureOpeners.lua", env, ns)
    return ns, opened, env
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

-- The classic clients open their spellbook and talents on their own
-- buttons: no secure click on a window they do not have.
function tests.classicClient_noCombinedSpellsWindow()
    local ns = Load(nil, true)
    H.assertNil(ns.SecureOpeners.OpenKeyForData(SPELL))
    H.assertNil(ns.SecureOpeners.OpenKeyForData(TALENT))
    H.assertNil(ns.SecureOpeners.OpenKeyForData({ spellID = 204, category = "Ability", isSpellbookOnly = true }))
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

-- Its keys: armed while the window is closed, never while it is open.
function tests.replacementKey_onlyWhileItsWindowIsClosed()
    local ns, _, env = Load({ talents = true })
    local api = env.ClassicUIForeverAPI
    local shown = false
    api.SecureOpener = function(name) return name == "talents" and "CUIFTalentsKey" or nil end
    api.GetFrame = function() return { IsVisible = function() return shown end } end
    env.CUIFTalentsKey = {}
    H.assertEq(ns.SecureOpeners.ReplacementMacro(TALENT), "/click CUIFTalentsKey")
    shown = true
    H.assertNil(ns.SecureOpeners.ReplacementMacro(TALENT), "open: the key would close it")
    H.assertNil(ns.SecureOpeners.ReplacementMacro(SPELL), "spellbook not replaced")
end

-- Alt+click on a castable spell: the replaced book's key, never the
-- client's spells button (that opened its talents next to ours).
function tests.altClick_opensTheReplacedSpellbookOnly()
    local ns, _, env = Load({ spellBook = true })
    env.ClassicUIForeverAPI.SecureOpener = function(name) return name == "spellBook" and "CUIFBookKey" or nil end
    env.CUIFBookKey, env.PlayerSpellsMicroButton = {}, {}
    ns.ResultIcons, ns.ResultHandlers = {}, {}
    H.loadModule("Search/Results/SecureAttributes.lua", env, ns)
    local attrs = {}
    local row = { SetAttribute = function(_, k, v) attrs[k] = v end }
    ns.ResultSecureAttributes.SwapToPanelOpen(row)
    H.assertEq(attrs.type, "macro")
    H.assertEq(attrs.macrotext, "/click CUIFBookKey")
    H.assertNil(row._efSwappedToOpen, "the client panel's release steer stays off")
end

function tests.followUpOpen_leavesAnOpenWindowAlone()
    local ns, opened, env = Load({ questLog = true })
    env.ClassicUIForeverAPI.GetFrame = function() return { IsVisible = function() return true end } end
    H.assertTrue(ns.SearchOpeners:OpenButtonFrame("QuestLogMicroButton"))
    H.assertEq(#opened, 0)
end

local pass, fail, failures = H.runSuite("CuifOpeners", tests)
return { pass = pass, fail = fail, failures = failures }
