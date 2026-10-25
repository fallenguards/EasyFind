-- hooksecurefunc puts the hooked function behind a C call: a sliced run
-- that yields under it fails ("attempt to yield across metamethod/C-call
-- boundary"). The addon's own functions are hooked with Utils.PostHook;
-- client and library functions keep hooksecurefunc.
local H = require("Harness")

local env = H.newEnv()
local ns = H.newNs(env)
local function fakeWidget()
    local w = {}
    setmetatable(w, { __index = function() return function() return w end end })
    return w
end
env.CreateFont, env.CreateFrame = fakeWidget, fakeWidget
env.CreateColor = function(r, g, b, a) return { GetRGBA = function() return r, g, b, a end } end
env.UIParent, env.WorldFrame, env.GameTooltip = fakeWidget(), fakeWidget(), fakeWidget()
env.hooksecurefunc = function() end
env.GameFontNormal = setmetatable({}, { __index = function(_, k)
    if k == "GetFont" then return function() return "font", 12, "" end end
    return function() end
end })
H.loadModule("Shared/Utils.lua", env, ns)
local Utils = ns.Utils

-- Names in a file that hold the namespace or a part of it.
local function OwnNames(text)
    local names = { ns = true }
    local grew = true
    while grew do
        grew = false
        for lhs, root in text:gmatch("local%s+([%a_][%w_]*)%s*=%s*%(?%s*([%a_][%w_]*)") do
            if not names[lhs] and names[root] then
                names[lhs] = true
                grew = true
            end
        end
    end
    return names
end

-- Lines hooking one of the addon's own functions: { line, ... }.
local function Scan(text)
    local names, hits, n, prev = OwnNames(text), {}, 0, ""
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        n = n + 1
        if not (line:find("-- secure hook:", 1, true) or prev:find("-- secure hook:", 1, true)) then
            local code = line:gsub("%-%-.*$", "")
            local root = code:match("hooksecurefunc%(%s*([%a_][%w_]*)[%w_%.]*%s*,%s*[\"']?[%w_%.]+[\"']?%s*,")
            if root and names[root] then hits[#hits + 1] = n end
        end
        prev = line
    end
    return hits
end

local tests = {}

function tests.ownFunctionsAreHookedInLua()
    local bad, checked = {}, 0
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "r")
            if fh then
                checked = checked + 1
                for _, line in ipairs(Scan(fh:read("a"))) do bad[#bad + 1] = rel .. ":" .. line end
                fh:close()
            end
        end
    end
    H.assertTrue(checked > 100, "expected the full file set, read " .. checked)
    H.assertEq(#bad, 0, "hooksecurefunc on our own function; use Utils.PostHook:\n  " .. table.concat(bad, "\n  "))
end

function tests.scan_flagsAnOwnModuleHook()
    H.assertEq(#Scan('local Results = ns.Results\nhooksecurefunc(Results, "HideResults", f)\n'), 1)
    H.assertEq(#Scan('hooksecurefunc(ns.Search, "Hide", f)\n'), 1)
end

function tests.scan_passesClientHooksAndMarkedOnes()
    H.assertEq(#Scan('hooksecurefunc(WorldMapFrame, "OnMapChanged", f)\n'), 0)
    H.assertEq(#Scan('local wmf = WorldMapFrame\nhooksecurefunc(wmf, "SetMapID", f)\n'), 0)
    H.assertEq(#Scan('hooksecurefunc("ChatEdit_OnTabPressed", f)\n'), 0)
    H.assertEq(#Scan('-- secure hook: a taint study\nhooksecurefunc(ns.Results, "HideResults", f)\n'), 0)
end

function tests.postHook_runsTheHookAfterAndKeepsTheReturns()
    local order = {}
    local t = { F = function(_, a) order[#order + 1] = "orig " .. a return a, nil, "c" end }
    Utils.PostHook(t, "F", function(_, a) order[#order + 1] = "hook " .. a end)
    local r1, r2, r3 = t:F("x")
    H.assertEq(table.concat(order, ","), "orig x,hook x")
    H.assertTrue(r1 == "x" and r2 == nil and r3 == "c", "returns kept")
end

function tests.postHook_letsTheHookedFunctionYield()
    local t = { F = function() coroutine.yield() return "done" end }
    Utils.PostHook(t, "F", function() end)
    local co = coroutine.create(function() return t.F() end)
    H.assertTrue(coroutine.resume(co), "yields under the hook")
    local ok, v = coroutine.resume(co)
    H.assertTrue(ok and v == "done", "resumes to the end")
end

local pass, fail, failures = H.runSuite("OwnHooks", tests)
return { pass = pass, fail = fail, failures = failures }
