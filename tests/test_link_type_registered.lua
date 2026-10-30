-- Our chat links are a link type of their own ("easyfind:..."), registered
-- with the game's LinkUtil so SetItemRef answers them Handled. Unregistered,
-- the Era, TBC and Mists ItemRef tooltip throws "Unknown link type" inside
-- SetItemRef and no post-hook runs (Era, 2026-10-30: the links needed Shift).
local H = require("Harness")

local tests = {}

local function LinkEnv(alreadyRegistered)
    local e = H.newEnv()
    local n = H.newNs(e)
    e._G = e
    local handlers = {}
    e.LinkUtil = {
        RegisterLinkHandler = function(linkType, fn) handlers[linkType] = fn end,
        IsLinkHandlerRegistered = function(linkType) return alreadyRegistered and alreadyRegistered[linkType] or false end,
    }
    e.hooksecurefunc = function() end
    e.ChatFrame_AddMessageEventFilter = function() end
    H.loadModule("Shared/SearchText.lua", e, n)
    H.loadModule("Shared/Aliases.lua", e, n)
    local RL = H.loadModule("Shared/ResultLinks.lua", e, n)
    return RL, handlers
end

function tests.installRegistersTheEasyfindLinkType()
    local RL, handlers = LinkEnv()
    RL:Install()
    local handler = handlers.easyfind
    H.assertEq(type(handler), "function", "easyfind registered with LinkUtil")
    H.assertNil(handler("easyfind:whatsnew:4.0.2", "[What's New]", {}, {}), "nil answers Handled")
end

function tests.aTypeAlreadyRegisteredIsLeftAlone()
    local RL, handlers = LinkEnv({ easyfind = true })
    RL:Install()
    H.assertNil(handlers.easyfind, "the game's duplicate assert never fires")
end

-- Link types the game itself handles or shows in its tooltip.
local GAME_TYPES = {
    item = true, spell = true, quest = true, achievement = true, currency = true,
    enchant = true, trade = true, instancelock = true, talent = true, battlepet = true,
    journal = true, worldmap = true, channel = true, player = true, BNplayer = true,
    unit = true, url = true, urlIndex = true, addon = true,
}

function tests.everyLiteralLinkTypeIsTheGamesOrOurs()
    local bad = {}
    local p = io.popen('git -C "' .. H.ADDON_ROOT .. '" ls-files "*.lua"')
    for rel in p:lines() do
        if not rel:match("^tests/") and not rel:match("^dev/") then
            local f = io.open(H.ADDON_ROOT .. "/" .. rel, "rb")
            if f then
                local n = 0
                for line in f:lines() do
                    n = n + 1
                    for linkType in line:gmatch("|H(%a+)[:|]") do
                        if not GAME_TYPES[linkType] and linkType ~= "easyfind" then
                            bad[#bad + 1] = rel .. ":" .. n .. " " .. linkType
                        end
                    end
                end
                f:close()
            end
        end
    end
    p:close()
    H.assertEq(#bad, 0, "a new link type needs LinkUtil.RegisterLinkHandler (ResultLinks:Install): " .. table.concat(bad, ", "))
end

local pass, fail, failures = H.runSuite("LinkTypeRegistered", tests)
return { pass = pass, fail = fail, failures = failures }
