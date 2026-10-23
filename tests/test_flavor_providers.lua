-- Which providers (and so filter menu rows) each classic client gets: Caps
-- loaded as Era, Anniversary and MoP Classic would load it, with the API
-- each client has. A switch that turns a system off on every classic client
-- hides a reader written for them; this table names what each must keep.
local H = require("Harness")

local FLAVORS = {
    era = { project = 2, build = { "1.15.9", "70003", "", 11509 }, addons = {} },
    tbc = { project = 5, build = { "2.5.6", "69795", "", 20506 }, addons = { Blizzard_AchievementUI = true } },
    mists = { project = 19, build = { "5.5.4", "70531", "", 50504 },
              addons = { Blizzard_AchievementUI = true, Blizzard_Collections = true, Blizzard_EncounterJournal = true,
                         Blizzard_PVPUI = true, Blizzard_Calendar = true } },
}
FLAVORS.era.addons.Blizzard_Calendar = true
FLAVORS.tbc.addons.Blizzard_Calendar = true

-- Provider key -> the flavors that must offer it.
local EXPECTED = {
    reputations = { era = true, tbc = true, mists = true },
    talents = { era = true, tbc = true, mists = true },
    titles = { tbc = true, mists = true },
    skills = { era = true, tbc = true },
    macros = { era = true, tbc = true, mists = true },
    currencies = { mists = true },
    collections = { mists = true },
    mounts = { mists = true },
    pets = { mists = true },
    toys = { mists = true },
    heirlooms = { mists = true },
    gearSets = { mists = true },
    professions = { era = true, tbc = true, mists = true },
    -- MoP's wardrobe: left off until its appearance reads are proven there.
    appearances = {}, transmogSets = {}, outfits = {},
    housing = {}, delves = {}, delve = {}, warband = {}, catalog = {}, icons = {},
}

-- Switches the menu tree reads -> the flavors where they are on.
local SWITCHES = {
    calendar = { mists = true },
    lfgWindow = { era = true, tbc = true },
    mists = { mists = true },
    warbandRep = {},
    -- MoP's journal has Dungeons and Raids only.
    journalTabs = {},
}

local function loadCaps(name)
    local f = FLAVORS[name]
    local env = H.newEnv()
    env._G = env
    env.WOW_PROJECT_CLASSIC, env.WOW_PROJECT_BURNING_CRUSADE_CLASSIC, env.WOW_PROJECT_MISTS_CLASSIC = 2, 5, 19
    env.WOW_PROJECT_ID = f.project
    env.GetBuildInfo = function() return (rawget(table, "unpack") or unpack)(f.build) end
    env.GetNumBindings = function() return 0 end
    env.C_AddOns = {
        GetAddOnInfo = function(addon) return addon, addon, "", true, f.addons[addon] and "DEMAND_LOADED" or "MISSING" end,
        IsAddOnLoaded = function() return false end,
        LoadAddOn = function(addon) return f.addons[addon] == true end,
    }
    -- Every classic client keeps these namespaces; only MoP has the windows.
    env.C_MountJournal = { GetMountIDs = function() return {} end }
    env.C_PetJournal = { GetNumPets = function() return 0 end }
    env.C_ToyBox = { GetToyInfo = function() end }
    env.C_Heirloom = { GetHeirloomInfo = function() end }
    env.C_EquipmentSet = { GetEquipmentSetIDs = function() return {} end }
    env.C_CurrencyInfo = { GetCurrencyInfo = function() end }
    env.GetCurrencyListSize = function() return 0 end
    env.GetNumTradeSkills = function() return 0 end
    if name == "mists" then
        env.CHARACTERFRAME_SUBFRAMES = { "PaperDollFrame", "PetPaperDollFrame", "ReputationFrame", "TokenFrame" }
        env.PAPERDOLL_SIDEBARS = { {}, {}, {} }
    else
        env.CHARACTERFRAME_SUBFRAMES = { "PaperDollFrame", "PetPaperDollFrame", "ReputationFrame", "SkillFrame", "HonorFrame" }
    end
    -- Every classic client: GetFactionInfo's list, part of C_Reputation.
    env.GetNumFactions = function() return 0 end
    env.GetFactionInfo = function() end
    env.C_Reputation = { IsAccountWideReputation = function() return false end }
    env.C_SpecializationInfo = { GetTalentInfo = function() end, GetActiveSpecGroup = function() return 1 end }
    env.C_ClassTalents, env.C_Traits = nil, nil
    if name ~= "mists" then
        env.GetNumTalentTabs = function() return 3 end
        env.GetNumSkillLines = function() return 0 end
        env.GetSkillLineInfo = function() end
    else
        env.GetNumTalentTabs = nil
    end
    local ns = H.newNs(env)
    H.loadModule("Shared/Caps.lua", env, ns)
    return ns.Caps
end

local tests = {}

for _, flavor in ipairs({ "era", "tbc", "mists" }) do
    tests["providers_" .. flavor] = function()
        local Caps = loadCaps(flavor)
        H.assertTrue(Caps.classic, flavor .. " is a classic client")
        local wrong = {}
        for key, want in pairs(EXPECTED) do
            local has = Caps.Has(key)
            if has ~= (want[flavor] == true) then
                wrong[#wrong + 1] = key .. (has and " is offered" or " is missing")
            end
        end
        for key, want in pairs(SWITCHES) do
            if (Caps[key] == true) ~= (want[flavor] == true) then
                wrong[#wrong + 1] = "switch " .. key .. (Caps[key] and " is on" or " is off")
            end
        end
        table.sort(wrong)
        H.assertEq(table.concat(wrong, ", "), "", flavor)
    end
end

local pass, fail, failures = H.runSuite("FlavorProviders", tests)
return { pass = pass, fail = fail, failures = failures }
