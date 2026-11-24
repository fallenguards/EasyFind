-- Tests for Shared/Caps.lua: what each client has.

local H = require("Harness")

local function Load(numSpecs, skillInfo)
    local env = H.newEnv()
    env.C_SkillInfo = skillInfo
    env.UnitClass = function() return "Warrior", "WARRIOR", 1 end
    env.GetNumSpecializationsForClassID = function() return numSpecs end
    env.GetSpecializationInfoForClassID = function() return 71, "Arms" end
    env.GetBuildInfo = function() return "1.60.1", "70338", "Oct 1 2026", numSpecs > 1 and 120100 or 16001 end
    local ns = H.newNs(env)
    H.loadModule("Shared/Caps.lua", env, ns)
    return ns.Caps
end

local tests = {}

function tests.specs_onRetail()
    H.assertTrue(Load(3).specs)
end

function tests.specs_offOnForever_whereTheAPIAnswersOne()
    H.assertFalse(Load(1).specs)
end

-- Forever's character window has the currency tab (Blizzard_TokenUI's
-- Camelot files): the currency search is on there (2026-10-27).
function tests.currencies_onForever()
    local caps = Load(1)
    H.assertTrue(caps.forever, "loaded as Forever")
    H.assertTrue(caps.currencies, "Forever has the currency tab")
end

-- Forever's character window has the Skills tab, read through C_SkillInfo
-- (a table a line); retail's C_SkillInfo holds only its event. Forever got no
-- skill rows (no Mining with its bar) while the switch asked for a classic
-- client (2026-11-24).
function tests.skills_onForever_offOnRetail()
    local forever = Load(1, { GetNumSkillLines = function() return 0 end, GetSkillLineInfo = function() end })
    H.assertTrue(forever.skills, "Forever lists skills")
    H.assertFalse(Load(3, {}).skills, "retail has no skill list")
end

local pass, fail, failures = H.runSuite("Caps", tests)
return { pass = pass, fail = fail, failures = failures }
