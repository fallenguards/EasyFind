-- Tests for Shared/Caps.lua on a Classic Era client: UI entries written
-- for retail's windows must not be offered where Classic has none.

local H = require("Harness")
local env = H.newEnv()
local ns = H.newNs(env)
-- Caps looks frames up through _G.
env._G = env

env.WOW_PROJECT_CLASSIC = 2
env.WOW_PROJECT_BURNING_CRUSADE_CLASSIC = 5
env.WOW_PROJECT_ID = 2
env.GetBuildInfo = function() return "1.15.9", "70003", "Sep 29 2026", 11509 end
env.GetNumBindings = function() return 2 end
env.GetBinding = function(i) return i == 1 and "TOGGLECHARACTER0" or "TOGGLEQUESTLOG" end

-- Blizzard_GroupFinder is in at login on Era; every retail-only panel
-- answers "loadable" and then refuses the load.
local loaded = { Blizzard_GroupFinder = true }
env.C_AddOns = {
    GetAddOnInfo = function(name) return name, name, "", true, nil end,
    IsAddOnLoaded = function(name) return loaded[name] == true end,
    LoadAddOn = function() return false, "WRONG_GAME_TYPE" end,
}

local function frame(shown)
    return { IsShown = function() return shown end }
end
env.CHARACTERFRAME_SUBFRAMES = { "PaperDollFrame", "PetPaperDollFrame", "ReputationFrame", "SkillFrame", "HonorFrame" }
env.CharacterFrame = frame(false)
for i = 1, 5 do env["CharacterFrameTab" .. i] = frame(true) end
env.CharacterMicroButton = frame(true)
env.StoreMicroButton = frame(false)

H.loadModule("Shared/Caps.lua", env, ns)
local Caps = ns.Caps

local tests = {}

function tests.detectsEra()
    H.assertTrue(Caps.classic, "classic")
    H.assertTrue(Caps.era, "era")
    H.assertFalse(Caps.retail, "not retail")
end

function tests.characterTabs_resolveByFrame()
    H.assertEq(Caps.CharacterTab(1), env.CharacterFrameTab1, "Character")
    H.assertEq(Caps.CharacterTab(2), env.CharacterFrameTab3, "Reputation is the third tab")
    H.assertNil(Caps.CharacterTab(3), "no currency tab")
end

-- Skills and Honor are tabs here under Classic's own frame names.
function tests.characterTabs_namedForeversWay_resolve()
    H.assertEq(Caps.CharacterSubframe("SkillsFrame"), "SkillFrame")
    H.assertEq(Caps.CharacterSubframe("PVPRankFrame"), "HonorFrame")
    H.assertEq(Caps.CharacterSubframe("PaperDollFrame"), "PaperDollFrame")
    H.assertNil(Caps.CharacterSubframe("StatisticsFrame"), "no statistics tab")
    H.assertEq(Caps.CharacterTab("SkillsFrame"), env.CharacterFrameTab4, "Skills is the fourth tab")
    H.assertEq(Caps.CharacterTab("PVPRankFrame"), env.CharacterFrameTab5, "Honor is the fifth")
    H.assertNil(Caps.UIEntryBlocked({ steps = { { waitForFrame = "CharacterFrame", tabFrame = "SkillsFrame" } } }), "Skills is offered")
    H.assertNotNil(Caps.UIEntryBlocked({ steps = { { waitForFrame = "CharacterFrame", tabFrame = "StatisticsFrame" } } }))
end

function tests.sidebarEntries_haveNoSlot()
    for n = 1, 3 do H.assertNil(Caps.CharacterSidebarSlot(n), "sidebar " .. n) end
    local titles = { steps = {
        { waitForFrame = "CharacterFrame", tabIndex = 1 },
        { waitForFrame = "CharacterFrame", sidebarButtonFrame = "CharacterFrameTab1", sidebarIndex = 2 },
    } }
    H.assertNotNil(Caps.UIEntryBlocked(titles), "Titles is blocked")
end

function tests.reputationEntry_isOffered()
    H.assertNil(Caps.UIEntryBlocked({ steps = { { waitForFrame = "CharacterFrame", tabIndex = 2 } } }))
end

function tests.missingFrameOfLoadedAddon_isBlocked()
    H.assertNotNil(Caps.UIEntryBlocked({ steps = { { waitForFrame = "PVEFrame", tabIndex = 1 } } }), "PVEFrame")
end

function tests.retailPanels_areOff()
    H.assertFalse(Caps.PanelEnabled("Blizzard_EncounterJournal"), "journal panel")
    H.assertFalse(Caps.pvpUI, "PvP window")
    H.assertFalse(Caps.collectionsUI, "collections")
end

function tests.hiddenMicroButton_isBlocked()
    H.assertNotNil(Caps.UIEntryBlocked({ buttonFrame = "StoreMicroButton" }), "hidden Shop button")
    H.assertNil(Caps.UIEntryBlocked({ buttonFrame = "CharacterMicroButton" }), "shown Character button")
end

function tests.taggedEntries_areOff()
    for _, cap in ipairs({ "selfHighlight", "editMode", "specs", "calendar", "transmog", "titles" }) do
        H.assertFalse(Caps[cap] and true or false, cap)
    end
end

function tests.titles_areOffOnEra()
    H.assertFalse(Caps.Has("titles"), "titles provider, filter and quick filter")
    local rows = Caps.PruneRows({ { key = "titles" }, { key = "bags" } })
    H.assertEq(#rows, 1, "titles row pruned")
    H.assertEq(rows[1].key, "bags")
end

local pass, fail, failures = H.runSuite("CapsClassic", tests)
return { pass = pass, fail = fail, failures = failures }
