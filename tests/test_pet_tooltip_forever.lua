-- A pet row's tooltip on Forever: the battle pet tooltip there is built
-- from a template with no Owned line, and the client's show writes it
-- (BattlePetTooltip.lua:43 errored on every search refresh under a hovered
-- pet row, 2026-11-07). Its own journal shows the companion tooltip.
local H = require("Harness")

local function Source()
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/Results/Rows/Tooltips.lua", "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local tests = {}

function tests.theBattlePetShow_onlyWhereItsTooltipHasTheOwnedLine()
    local src = Source()
    local calls = 0
    for line in src:gmatch("[^\n]+") do
        if line:find("BattlePetToolTip_ShowLink", 1, true) and line:find("^%s*if ") then
            calls = calls + 1
            H.assertTrue(line:find("BattlePetTooltip.Owned", 1, true) ~= nil,
                "the battle pet show is asked only with an Owned line to write")
        end
    end
    H.assertEq(calls, 1, "one place shows a pet row's battle pet tooltip")
end

function tests.elsewhere_theCompanionTooltip()
    H.assertTrue(Source():find("GameTooltip:SetCompanionPet(self.icon.petID)", 1, true) ~= nil,
        "the client journal's own pet tooltip")
end

local pass, fail, failures = H.runSuite("PetTooltipForever", tests)
return { pass = pass, fail = fail, failures = failures }
