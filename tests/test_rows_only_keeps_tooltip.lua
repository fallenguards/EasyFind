-- A rows-only rerun of the active search (a provider's rows changed under
-- the same text: a chat line arriving with the bar open) keeps the hovered
-- row's tooltip. The run cleared every row tooltip up front and the render,
-- finding the same rows, drew nothing, so an item tooltip over a result row
-- vanished at every chat line (Era, 2026-10-28, /efd tipwatch).
local H = require("Harness")

local function Source(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local tests = {}

function tests.searchRun_clearsRowTooltips_onlyWhenTheTextRan()
    local src = Source("Search/Query.lua")
    local at = assert(src:find("function Search:OnSearchTextChangedNow", 1, true))
    local body = src:sub(at)
    local call = assert(body:find("Tooltips:ClearResultTooltips()", 1, true))
    local line = body:sub(body:sub(1, call):match(".*()\n") or 1, call + #"Tooltips:ClearResultTooltips()")
    H.assertTrue(line:find("if not rowsOnly then", 1, true) ~= nil,
        "ClearResultTooltips must be skipped on a rows-only rerun, got: " .. line)
end

function tests.unchangedRender_restoresTheHoveredRow()
    local src = Source("Search/Results/Render/Core.lua")
    H.assertTrue(src:find("if same then%s+self:RestoreHoveredRow%(%)%s+return") ~= nil,
        "the same-signature render must refire the hovered row's tooltip before it returns")
end

local pass, fail, failures = H.runSuite("RowsOnlyKeepsTooltip", tests)
return { pass = pass, fail = fail, failures = failures }
