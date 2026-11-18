-- Search/Results/Handlers/Character.lua ToggleCurrencyBackpack: a currency
-- put on the backpack refreshes the backpack's currency row as the game's
-- own Show on Backpack does, never the bag frames (an Update on a bag not
-- in use ran another addon's slot pass over slots it lacks, 2026-11-17).
local H = require("Harness")

local function Load(opts)
    local env = H.newEnv()
    env._G = env
    local ns = H.newNs(env)
    local seen = { set = {}, bagUpdates = 0, tokenUpdates = 0, globalUpdates = 0 }
    ns.ResultHandlers = {}
    ns.Search, ns.SearchOpeners = {}, {}
    ns.Utils.ClickButton = function() end
    env.C_CurrencyInfo = {
        SetCurrencyBackpackByID = function(id, on) seen.set[#seen.set + 1] = { id, on } end,
        GetBackpackCurrencyInfo = function() return nil end,
        GetCurrencyInfo = function() return { isShowInBackpack = false } end,
    }
    for i = 1, 13 do
        env["ContainerFrame" .. i] = { Update = function() seen.bagUpdates = seen.bagUpdates + 1 end,
                                      tokenFrame = { Update = function() seen.bagUpdates = seen.bagUpdates + 1 end } }
    end
    if opts.classic then
        env.BackpackTokenFrame_Update = function() seen.globalUpdates = seen.globalUpdates + 1 end
    else
        env.BackpackTokenFrame = { Update = function() seen.tokenUpdates = seen.tokenUpdates + 1 end }
    end
    H.loadModule("Search/Results/Handlers/Character.lua", env, ns)
    ns.ResultHandlers.IsCurrencyOnBackpack = function() return false end
    return ns.ResultHandlers, seen
end

local tests = {}

function tests.onTheBackpack_itsRowIsRefreshed_neverTheBags()
    local Handlers, seen = Load({})
    Handlers:ToggleCurrencyBackpack(1792)
    H.assertEq(seen.set[1][1], 1792)
    H.assertTrue(seen.set[1][2], "put on")
    H.assertEq(seen.tokenUpdates, 1, "the backpack's currency row")
    H.assertEq(seen.bagUpdates, 0, "no bag frame updated from here")
end

function tests.onClassic_theGlobalRefreshStands()
    local Handlers, seen = Load({ classic = true })
    Handlers:ToggleCurrencyBackpack(1792)
    H.assertEq(seen.globalUpdates, 1)
    H.assertEq(seen.bagUpdates, 0)
end

local pass, fail, failures = H.runSuite("CurrencyBackpack", tests)
return { pass = pass, fail = fail, failures = failures }
