-- Discovers and runs all tests/test_*.lua files.
-- Invoke from the EasyFind root: `lua tests/Run.lua`

-- A runaway test (a loop that never ends, a function calling itself) must
-- not take the machine with it: past 2 GB of Lua memory or 240 s of CPU
-- the run stops and says which file was running.
local MEMORY_CAP_KB, CPU_CAP_S = 2 * 1024 * 1024, 240
local runningFile = "(start)"
debug.sethook(function()
    local kb, cpu = collectgarbage("count"), os.clock()
    if kb > MEMORY_CAP_KB or cpu > CPU_CAP_S then
        io.stderr:write(string.format("tests/Run.lua: stopped in %s at %.0f MB, %.0f s of CPU (a runaway test?)\n",
            runningFile, kb / 1024, cpu))
        os.exit(3)
    end
end, "", 200000)

local source = debug.getinfo(1, "S").source:sub(2)
local TEST_DIR = source:gsub("[/\\]Run%.lua$", "")
package.path = TEST_DIR .. "/?.lua;" .. package.path

local function listTestFiles()
    local files = {}
    -- Use shell globbing: works on bash/git-bash; on PowerShell call via /c/...
    local cmd = string.format([[ls "%s"/test_*.lua 2>/dev/null]], TEST_DIR:gsub("\\", "/"))
    local handle = io.popen(cmd)
    if handle then
        for line in handle:lines() do
            files[#files + 1] = line
        end
        handle:close()
    end
    if #files == 0 then
        -- Fallback for PowerShell environments without `ls`
        cmd = string.format([[cmd /c "dir /b "%s\test_*.lua" 2>nul"]], TEST_DIR)
        handle = io.popen(cmd)
        if handle then
            for line in handle:lines() do
                files[#files + 1] = TEST_DIR .. "/" .. line
            end
            handle:close()
        end
    end
    table.sort(files)
    return files
end

local files = listTestFiles()
if #files == 0 then
    print("No test files found in " .. TEST_DIR)
    os.exit(1)
end

local totalPass, totalFail = 0, 0
local allFailures = {}

for i = 1, #files do
    local file = files[i]
    runningFile = file
    local chunk, err = loadfile(file)
    if not chunk then
        print("LOAD ERROR " .. file .. ": " .. tostring(err))
        totalFail = totalFail + 1
        allFailures[#allFailures + 1] = { file = file, err = err }
    else
        local ok, result = xpcall(chunk, debug.traceback)
        if not ok then
            print("RUN ERROR " .. file .. ": " .. tostring(result))
            totalFail = totalFail + 1
            allFailures[#allFailures + 1] = { file = file, err = result }
        elseif type(result) == "table" then
            totalPass = totalPass + (result.pass or 0)
            totalFail = totalFail + (result.fail or 0)
            for j = 1, #(result.failures or {}) do
                allFailures[#allFailures + 1] = result.failures[j]
            end
        end
    end
end

print("")
print(string.format("== Results: %d passed, %d failed ==", totalPass, totalFail))
if totalFail > 0 then
    for i = 1, #allFailures do
        local failure = allFailures[i]
        print("  FAIL " .. tostring(failure.name or failure.file)
            .. (failure.err and (": " .. tostring(failure.err)) or ""))
    end
    os.exit(1)
end
