-- Guardrail: a companion (Apps/<X>, its own addon) shares EasyFind's
-- namespace, EasyFind._ns. Its addon's own `...` namespace holds none of
-- EasyFind (no ns.GPS, ns.L, ns.Utils): a GPS file that took it errored at
-- load (QuestDirections.lua, 2026-10-29).
local H = require("Harness")

local tests = {}

function tests.everyCompanionFile_takesEasyFindsNamespace()
    local root = H.ADDON_ROOT
    local handle = io.popen('ls "' .. root .. '"/Apps/*/*.toc 2>/dev/null')
    local list = handle and handle:read("*a") or ""
    if handle then handle:close() end
    if list == "" then
        handle = io.popen('cmd /c "dir /b /s "' .. root:gsub("/", "\\") .. '\\Apps\\*.toc" 2>nul"')
        list = handle and handle:read("*a") or ""
        if handle then handle:close() end
    end
    local bad, checked = {}, 0
    for toc in list:gmatch("[^\r\n]+") do
        toc = toc:gsub("\\", "/")
        local dir = toc:match("^(.*)/[^/]+$")
        local f = io.open(toc, "rb")
        local text = f and f:read("*a") or ""
        if f then f:close() end
        for file in text:gmatch("\n([%w_/]+%.lua)") do
            local src = io.open(dir .. "/" .. file, "rb")
            if src then
                local body = src:read("*a")
                src:close()
                checked = checked + 1
                if body:find("\nlocal [%w_]+, ns = %.%.%.") or body:find("^local [%w_]+, ns = %.%.%.") then
                    bad[#bad + 1] = dir:match("Apps/.*$") .. "/" .. file
                end
            end
        end
    end
    H.assertTrue(checked > 20, "expected the companion files, read " .. checked)
    H.assertEq(#bad, 0, "take ns from EasyFind._ns, not the addon's own `...`:\n  " .. table.concat(bad, "\n  "))
end

local pass, fail, failures = H.runSuite("CompanionNamespace", tests)
return { pass = pass, fail = fail, failures = failures }
