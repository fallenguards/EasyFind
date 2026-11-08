-- Result rows are secure buttons, protected in a fight like the results
-- frame: hiding them there was refused (ADDON_ACTION_BLOCKED
-- EasyFindResultButton1:Hide(), the chat composer opened in a fight,
-- 2026-11-07). Their Hide degrades quietly in a fight and runs when it
-- ends (Search/Results/Navigation.lua HideResults, SearchBar.lua
-- PLAYER_REGEN_ENABLED).
local H = require("Harness")

local function Source(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local tests = {}

function tests.everyRowHide_degradesQuietlyInAFight()
    local src = Source("Search/Results/Navigation.lua")
    local s = assert(src:find("function Results:HideResults()", 1, true))
    local e = assert(src:find("\nfunction Results:", s + 1, true))
    local body = src:sub(s, e)
    H.assertTrue(body:find("Utils.SafeCallMethod(row, \"Hide\")", 1, true) ~= nil, "the row")
    H.assertTrue(body:find("Utils.SafeCallMethod(row.shortcutGroup, \"Hide\")", 1, true) ~= nil, "its shortcut group")
    H.assertTrue(body:find("Utils.SafeCallMethod(ResultsFrame(), \"Hide\")", 1, true) ~= nil, "the frame")
    H.assertNil(body:find("row:Hide()", 1, true), "no bare row hide")
    H.assertNil(body:find("shortcutGroup:Hide()", 1, true), "no bare group hide")
    H.assertTrue(body:find("self.hideAfterCombat = InCombatLockdown() or nil", 1, true) ~= nil, "remembered for the fight's end")
end

function tests.theHide_runsAgainWhenTheFightEnds()
    local src = Source("Search/SearchBar.lua")
    H.assertTrue(src:find('elseif event == "PLAYER_REGEN_ENABLED" then\n'
        .. "            inCombat = false\n"
        .. "            combatToggledOff = false\n"
        .. "            -- Results hidden in the fight: their secure rows hide now.\n"
        .. "            if Results.hideAfterCombat then Results:HideResults() end", 1, true) ~= nil,
        "the rows hide once the fight ends")
end

-- Utils.SafeCallMethod is the quiet path: nothing is called in a fight.
function tests.safeCallMethod_callsNothingInAFight()
    local src = Source("Shared/Utils.lua")
    local s = assert(src:find("function Utils.SafeCallMethod", 1, true))
    local e = assert(src:find("\nfunction Utils.", s + 1, true))
    local inCombat = true
    local Utils = {}
    local env = { InCombatLockdown = function() return inCombat end, xpcall = xpcall,
                  ErrorHandler = function(err) return err end, Utils = Utils }
    assert(load(src:sub(s, e), "=Utils.lua SafeCallMethod", "t", env))()
    local hidden = 0
    local row = { Hide = function() hidden = hidden + 1 end }
    local ok, why = Utils.SafeCallMethod(row, "Hide")
    H.assertFalse(ok)
    H.assertEq(why, "combat")
    H.assertEq(hidden, 0)
    inCombat = false
    H.assertTrue((Utils.SafeCallMethod(row, "Hide")))
    H.assertEq(hidden, 1)
end

local pass, fail, failures = H.runSuite("HideResultsInCombat", tests)
return { pass = pass, fail = fail, failures = failures }
