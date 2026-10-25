-- Tests for the filter menu at combat start (Search/SearchBar.lua): the
-- menu sits on UIParent, so it closes in every visibility mode, not only
-- when the bar stays up; left open it kept the keyboard through the fight.

local H = require("Harness")

local tests = {}

function tests.theFilterMenuClosesBeforeTheModeBranch()
    local fh = assert(io.open(H.ADDON_ROOT .. "/Search/SearchBar.lua", "rb"))
    local src = fh:read("*a")
    fh:close()
    local body = src:match('if event == "PLAYER_REGEN_DISABLED" then(.-)elseif event ==')
    assert(body, "the bar's combat-start branch")
    local close = body:find("CloseFilterDropdownIfOpen()", 1, true)
    local branch = body:find("if not (ns.GetVisibilityMode()", 1, true)
    H.assertTrue(close ~= nil and branch ~= nil and close < branch, "closed before the visibility branch")
    local _, count = body:gsub("CloseFilterDropdownIfOpen%(%)", "")
    H.assertEq(count, 1, "one close, for every mode")
end

local pass, fail, failures = H.runSuite("Filter menu combat", tests)
return { pass = pass, fail = fail, failures = failures }
