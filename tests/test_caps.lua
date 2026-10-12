-- Tests for Shared/Caps.lua: what each client has.

local H = require("Harness")

local function Load(numSpecs)
    local env = H.newEnv()
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

local pass, fail, failures = H.runSuite("Caps", tests)
return { pass = pass, fail = fail, failures = failures }
