-- debugprofilestart resets the client's one profiler clock: every addon's
-- debugprofilestop reading across it goes wrong, our slice deadlines and
-- the lag probe too. Shipped files time from a reading of their own.
local H = require("Harness")

local function LuaFiles()
    local files = {}
    local root = H.ADDON_ROOT:gsub("\\", "/")
    local handle = io.popen(string.format([[find "%s" -name "*.lua" -not -path "*/dev/*" -not -path "*/tests/*" -not -path "*/.git/*" 2>/dev/null]], root))
    if handle then
        for line in handle:lines() do files[#files + 1] = line end
        handle:close()
    end
    if #files == 0 then
        handle = io.popen(string.format([[cmd /c "dir /s /b "%s\*.lua" 2>nul"]], root:gsub("/", "\\")))
        if handle then
            for line in handle:lines() do
                local path = line:gsub("\\", "/")
                if not (path:find("/dev/", 1, true) or path:find("/tests/", 1, true)) then files[#files + 1] = path end
            end
            handle:close()
        end
    end
    return files
end

local tests = {}

function tests.noShippedFileResetsTheProfilerClock()
    local files = LuaFiles()
    H.assertTrue(#files > 100, "read the shipped files: " .. #files)
    for _, path in ipairs(files) do
        local f = assert(io.open(path, "rb"))
        local src = f:read("*a")
        f:close()
        local n = 0
        for line in src:gmatch("[^\n]*") do
            n = n + 1
            local code = line:gsub("%-%-.*$", "")
            H.assertFalse(code:find("debugprofilestart", 1, true) ~= nil,
                ("%s:%d calls debugprofilestart"):format(path, n))
        end
    end
end

local pass, fail, failures = H.runSuite("ProfilerClock", tests)
return { pass = pass, fail = fail, failures = failures }
