-- Guardrail: the search runs only through the bar's sliced dispatch. The
-- search writes one shared results list and pauses between slices; a direct
-- call while a sliced run is paused refills that list, and the paused run
-- leaves holes in it when it resumes ("attempt to index local 'a'" in the
-- score sort, from the bench's direct calls, 2026-10-29).
local H = require("Harness")

-- file -> how many calls of each kind it may hold.
local ALLOWED = {
    ["Search/Query.lua"] = { now = 1, searchUI = 2 },
}

local tests = {}

function tests.onlyTheSlicedDispatchRunsTheSearch()
    local seen, bad, checked = {}, {}, 0
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            if not seen[rel] then
                seen[rel] = true
                local f = io.open(H.ADDON_ROOT .. "/" .. rel, "rb")
                if f then
                    local src = f:read("*a")
                    f:close()
                    checked = checked + 1
                    local now, searchUI = 0, 0
                    for line in src:gmatch("[^\n]+") do
                        if not line:find("^%s*%-%-") then
                            if line:find("[:.]OnSearchTextChangedNow%(") and not line:find("^%s*function ") then
                                now = now + 1
                            end
                            if line:find("[:.]SearchUI%(") and not line:find("^%s*function ") then
                                searchUI = searchUI + 1
                            end
                        end
                    end
                    local allow = ALLOWED[rel] or { now = 0, searchUI = 0 }
                    if now > allow.now or searchUI > allow.searchUI then
                        bad[#bad + 1] = string.format("%s: %d direct search pass calls, %d SearchUI calls", rel, now, searchUI)
                    end
                end
            end
        end
    end
    H.assertTrue(checked > 100, "expected the shipped files, read " .. checked)
    H.assertEq(#bad, 0, "a search run outside the sliced dispatch:\n  " .. table.concat(bad, "\n  "))
end

local pass, fail, failures = H.runSuite("SearchEntryPoints", tests)
return { pass = pass, fail = fail, failures = failures }
