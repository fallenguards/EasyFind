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
env.GetNumSkillLines = function() return 0 end
env.GetSkillLineInfo = function() end

H.loadModule("Shared/Caps.lua", env, ns)
local Caps = ns.Caps

local tests = {}

function tests.detectsEra()
    H.assertTrue(Caps.classic, "classic")
    H.assertTrue(Caps.era, "era")
    H.assertTrue(Caps.lfgWindow, "the Looking For Group window")
    H.assertFalse(Caps.mists, "not MoP")
    H.assertFalse(Caps.retail, "not retail")
end

-- MoP Classic is of the classic family too, with its own flag.
function tests.detectsMists()
    local env2 = H.newEnv()
    local ns2 = H.newNs(env2)
    env2._G = env2
    env2.WOW_PROJECT_CLASSIC, env2.WOW_PROJECT_BURNING_CRUSADE_CLASSIC, env2.WOW_PROJECT_MISTS_CLASSIC = 2, 5, 19
    env2.WOW_PROJECT_ID = 19
    env2.GetBuildInfo = function() return "5.5.4", "70268", "Oct 1 2026", 50504 end
    env2.GetNumBindings = function() return 0 end
    env2.C_AddOns = env.C_AddOns
    H.loadModule("Shared/Caps.lua", env2, ns2)
    H.assertTrue(ns2.Caps.classic, "classic family")
    H.assertTrue(ns2.Caps.mists, "MoP")
    H.assertFalse(ns2.Caps.era)
    H.assertFalse(ns2.Caps.retail)
    H.assertFalse(ns2.Caps.lfgWindow, "MoP has the Group Finder")
end

-- The Looking For Group rows open on the minimap's eye: offered while the
-- client shows it, not before the character may list.
function tests.lookingForGroup_followsTheEye()
    env.LFGParentFrame = frame(false)
    env.LFGMinimapFrame = frame(true)
    local browse = { caps = "lfgWindow", buttonFrame = "LFGMinimapFrame",
                     steps = { { buttonFrame = "LFGMinimapFrame" }, { waitForFrame = "LFGParentFrame", tabIndex = 2 } } }
    H.assertNil(Caps.UIEntryBlocked(browse), "offered")
    env.LFGMinimapFrame = frame(false)
    H.assertNotNil(Caps.UIEntryBlocked(browse), "the eye is hidden below the level")
    env.LFGMinimapFrame, env.LFGParentFrame = nil, nil
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

-- The Social window's tabs and the Pet tab: classic windows of their own.
function tests.socialAndPetTab_areOffered()
    env.SocialsMicroButton, env.FriendsFrame = frame(true), frame(false)
    local who = { caps = "classic", buttonFrame = "SocialsMicroButton",
                  steps = { { buttonFrame = "SocialsMicroButton" }, { waitForFrame = "FriendsFrame", tabIndex = 2 } } }
    H.assertNil(Caps.UIEntryBlocked(who), "Who")
    H.assertEq(Caps.CharacterTab("PetPaperDollFrame"), env.CharacterFrameTab2, "Pet is the second tab")
    H.assertNil(Caps.UIEntryBlocked({ steps = { { waitForFrame = "CharacterFrame", tabFrame = "PetPaperDollFrame" } } }))
    env.SocialsMicroButton, env.FriendsFrame = nil, nil
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

function tests.gearSets_areOffOnClassic()
    H.assertFalse(Caps.Has("gearSets"), "no Equipment Manager: provider, filter and quick filter")
    H.assertEq(#Caps.PruneRows({ { key = "gearSets" }, { key = "bags" } }), 1, "the filter row is pruned")
end

function tests.skills_areSearchedOnClassic()
    H.assertTrue(Caps.Has("skills"), "skills provider, filter and quick filter")
    H.assertEq(#Caps.PruneRows({ { key = "skills" } }), 1, "the row stays")
end

function tests.titles_areOffOnEra()
    H.assertFalse(Caps.Has("titles"), "titles provider, filter and quick filter")
    local rows = Caps.PruneRows({ { key = "titles" }, { key = "bags" } })
    H.assertEq(#rows, 1, "titles row pruned")
    H.assertEq(rows[1].key, "bags")
end

local pass, fail, failures = H.runSuite("CapsClassic", tests)
return { pass = pass, fail = fail, failures = failures }
