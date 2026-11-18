-- A result's Wowhead link opens the client's own section of Wowhead: on
-- WoW Forever an item opened retail's page, where Forever's thread vendors
-- are not (GitHub #30, 2026-11-18). Runs Shared/Utils.lua.
local H = require("Harness")

local function fakeWidget()
    local w = {}
    setmetatable(w, { __index = function() return function() return w end end })
    return w
end

local function Link(caps, data)
    local env = H.newEnv()
    env.CreateFont, env.CreateFrame = fakeWidget, fakeWidget
    env.CreateColor = function(r, g, b, a) return { GetRGBA = function() return r, g, b, a end } end
    env.UIParent, env.WorldFrame, env.GameTooltip = fakeWidget(), fakeWidget(), fakeWidget()
    env.hooksecurefunc = function() end
    env.GetLocale = function() return "enUS" end
    env.GameFontNormal = setmetatable({}, { __index = function(_, k)
        if k == "GetFont" then return function() return "font", 12, "" end end
        return function() end
    end })
    local ns = H.newNs(env)
    H.loadModule("Shared/Utils.lua", env, ns)
    ns.Caps = caps
    return ns.GetWowheadLink(data)
end

local tests = {}

function tests.eachClient_itsOwnSection()
    local thread = { itemID = 2321, name = "Fine Thread" }
    H.assertEq(Link({ forever = true }, thread), "https://www.wowhead.com/forever/item=2321")
    H.assertEq(Link({ era = true, classic = true }, thread), "https://www.wowhead.com/classic/item=2321")
    H.assertEq(Link({ tbc = true, classic = true }, thread), "https://www.wowhead.com/tbc/item=2321")
    H.assertEq(Link({ mists = true, classic = true }, thread), "https://www.wowhead.com/mop-classic/item=2321")
    H.assertEq(Link({ retail = true }, thread), "https://www.wowhead.com/item=2321", "retail keeps the plain site")
end

function tests.aSearch_inThatSectionToo()
    H.assertEq(Link({ forever = true }, { isZone = true, name = "Zephras Isle" }),
        "https://www.wowhead.com/forever/search?q=Zephras%20Isle")
end

local pass, fail, failures = H.runSuite("WowheadLink", tests)
return { pass = pass, fail = fail, failures = failures }
