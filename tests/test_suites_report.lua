-- tests/Run.lua counts a file's results only when the file returns them
-- ({ pass, fail, failures }): one that just calls runSuite runs, prints
-- its failures, and still leaves the total green (three files, 2026-10-28).
local H = require("Harness")

local tests = {}

function tests.everyTestFileReturnsItsResults()
    local dir = H.ADDON_ROOT .. "/tests"
    local handle = io.popen('ls "' .. dir .. '"/test_*.lua 2>/dev/null')
    local list = handle and handle:read("*a") or ""
    if handle then handle:close() end
    if list == "" then
        handle = io.popen('cmd /c "dir /b "' .. dir:gsub("/", "\\") .. '\\test_*.lua" 2>nul"')
        list = handle and handle:read("*a") or ""
        if handle then handle:close() end
    end
    local silent, checked = {}, 0
    for path in list:gmatch("[^\r\n]+") do
        local name = path:match("([^/\\]+)$")
        local f = io.open(dir .. "/" .. name, "rb")
        if f then
            local src = f:read("*a")
            f:close()
            checked = checked + 1
            if src:find("H%.runSuite%(") and not src:find("return%s*{%s*pass%s*=") then
                silent[#silent + 1] = name
            end
        end
    end
    H.assertTrue(checked > 100, "expected the test files, read " .. checked)
    H.assertEq(#silent, 0, "these files run but report nothing to the total:\n  " .. table.concat(silent, "\n  "))
end

local pass, fail, failures = H.runSuite("SuitesReport", tests)
return { pass = pass, fail = fail, failures = failures }
