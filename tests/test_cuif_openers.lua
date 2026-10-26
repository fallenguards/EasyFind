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
            Open = function(name, arg)
                opened[#opened + 1] = name
                if arg then opened[name .. ":" .. #opened] = arg end
                return true
            end,
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

-- Its Collections window stands in for the game's journal (2026-10-27:
-- EasyFind pressed the Collections button every 0.05 s waiting for the
-- game's journal, toggling this window open and shut). It opens through
-- the API at the page, the entry passed on; the game's button is left be.
function tests.collections_openThroughTheApiAtThePage()
    local ns, opened, env = Load({ collectionsWindow = true })
    local pressed = 0
    ns.Utils.ClickButton = function() pressed = pressed + 1 return true end
    env.CollectionsMicroButton = {}
    ns.SearchOpeners:OpenButtonFrame("CollectionsMicroButton", { waitForFrame = "CollectionsJournal", tabIndex = 4 })
    H.assertEq(opened[1], "collectionsWindow")
    H.assertEq(opened["collectionsWindow:1"], "heirlooms", "at the heirlooms page")
    H.assertEq(pressed, 0, "the game's button is not pressed")
    H.assertTrue(ns.SearchOpeners.OpenCollectionsPage(1, "mount:42"))
    H.assertEq(opened["collectionsWindow:2"], "mounts")
    H.assertEq(opened["collectionsWindow:3"], "mount:42", "the entry handed on")
end

-- The entry's cell, as the replacement draws it, comes back to be ringed.
function tests.collections_theEntrysCellComesBack()
    local ns, _, env = Load({ collectionsWindow = true })
    local cell = {}
    env.ClassicUIForeverAPI.GetFrame = function(_, part) if part == "entry:toy:7" then return cell end end
    local replaced, got = ns.SearchOpeners.OpenCollectionsPage("toys", "toy:7")
    H.assertTrue(replaced)
    H.assertEq(got, cell)
end

function tests.collections_withoutTheReplacementTheGameRuns()
    local ns = Load({})
    H.assertEq(ns.SearchOpeners.OpenCollectionsPage(1, "mount:42"), nil)
end

-- A toggle button is pressed once, then waited on: pressed again each try
-- it shut the window it had just opened.
function tests.collectionOpeners_pressTheToggleOnce()
    local bad = {}
    for _, rel in ipairs({ "Search/Results/Handlers/Mounts.lua", "Search/Results/Handlers/Toys.lua" }) do
        local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
        local lines = {}
        for line in f:lines() do lines[#lines + 1] = line end
        f:close()
        for i, line in ipairs(lines) do
            if line:find("ClickButton(micro)", 1, true) then
                local guarded = false
                for j = math.max(1, i - 3), i do
                    if lines[j]:find("attempt == 1", 1, true) then guarded = true end
                end
                if not guarded then bad[#bad + 1] = rel .. ":" .. i end
            end
        end
    end
    H.assertEq(#bad, 0, table.concat(bad, ", "))
end

local pass, fail, failures = H.runSuite("CuifOpeners", tests)
return { pass = pass, fail = fail, failures = failures }
