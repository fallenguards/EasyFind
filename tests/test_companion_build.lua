-- A load-on-demand companion read in after an update made while the game
-- ran met the session's older core and broke (a player's Options error on
-- 4.3.0, 2026-11-03): each one's first file checks its release against
-- core's stamp and the companion stops, the funnel saying why; the stamps
-- move with the tocs.
local H = require("Harness")

local tests = {}

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local s = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return s
end

local function Version(toc) return Read(toc):match("## Version:%s*([%d%.]+)") end

-- The companions loaded on demand: each toc and its Lua files in order.
local function OnDemand()
    local out = {}
    for _, toc in ipairs(H.TOCS) do
        if toc ~= "EasyFind.toc" and Read(toc):find("\n## LoadOnDemand:%s*1") then
            out[#out + 1] = { toc = toc, files = (H.TocFiles(toc)) }
        end
    end
    return out
end

local function Head(path, n)
    local lines = {}
    for line in (Read(path) .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
        if #lines >= n then break end
    end
    return table.concat(lines, "\n")
end

function tests.theStampsAreTheRelease()
    local release = Version("EasyFind.toc")
    H.assertEq(Read("Core/Main.lua"):match('\nns%.BUILD = "([%d%.]+)"\n'), release, "Core/Main.lua's ns.BUILD")
    local companions = OnDemand()
    H.assertTrue(#companions >= 6, "the companions loaded on demand: " .. #companions)
    for _, c in ipairs(companions) do
        H.assertEq(Version(c.toc), release, c.toc)
        local stamp = Head(c.files[1], 40):match('\nif ns%.BUILD ~= "([%d%.]+)" then select%(2, %.%.%.%)%.stale = true return end')
        H.assertEq(stamp, release, c.files[1] .. "'s stamp")
    end
end

function tests.everyFileStopsOnAStaleCompanion()
    for _, c in ipairs(OnDemand()) do
        for i = 2, #c.files do
            H.assertTrue(Head(c.files[i], 30):find("select(2, ...).stale", 1, true) ~= nil,
                c.files[i] .. " stops when its companion is stale")
        end
    end
end

-- Against another release's core: marked stale, nothing of its own set.
function tests.anotherReleasesCore_theFirstFileStops()
    for _, c in ipairs(OnDemand()) do
        local wrote
        local ns = setmetatable({ BUILD = "0.0.1" }, { __newindex = function(_, k) wrote = wrote or k end })
        local env = setmetatable({ EasyFind = { _ns = ns } }, { __index = _G })
        local own = {}
        local chunk = assert(loadfile(H.ADDON_ROOT .. "/" .. c.files[1], "t", env))
        local ok, err = pcall(chunk, "EasyFind", own)
        H.assertTrue(ok, c.files[1] .. ": " .. tostring(err))
        H.assertTrue(own.stale, c.files[1] .. " marks its companion stale")
        H.assertNil(wrote, c.files[1] .. " set ns." .. tostring(wrote))
    end
end

local pass, fail, failures = H.runSuite("Companion build", tests)
return { pass = pass, fail = fail, failures = failures }
