-- Every error EasyFind catches reaches the client's error handler
-- (BugGrabber, the error frame). The shared handler once only formatted
-- the error, so every timer, OnUpdate and sliced run that dropped its
-- result lost the error: a broken chat window went silent with no trace.
local H = require("Harness")

local function source(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local tests = {}

function tests.theSharedHandlerReportsEveryError()
    local src = source("Shared/Utils.lua")
    local s = assert(src:find("local function ErrorHandler(err)", 1, true), "ErrorHandler not found")
    local e = assert(src:find("\nend", s, true), "ErrorHandler end")
    local reported = {}
    local env = setmetatable({
        geterrorhandler = function() return function(err) reported[#reported + 1] = err end end,
        debugstack = function() return "stack" end,
    }, { __index = _G })
    local handler = assert(load(src:sub(s, e + 3) .. "\nreturn ErrorHandler", "=Utils.lua ErrorHandler", "t", env))()
    local ok, msg = xpcall(function() error("boom", 0) end, handler)
    H.assertFalse(ok, "the call failed")
    H.assertEq(#reported, 1, "reported once")
    H.assertEq(reported[1], "boom", "the error itself reaches the client's handler")
    H.assertTrue(msg:find("boom", 1, true) ~= nil, "and comes back to the caller")
end

-- The wrappers every timer and OnUpdate go through catch with it.
function tests.timersAndOnUpdatesCatchWithIt()
    local src = source("Shared/Utils.lua")
    for _, name in ipairs({ "Utils.SafeAfter", "Utils.SafeOnUpdate" }) do
        local s = assert(src:find("function " .. name .. "(", 1, true), name)
        local body = src:sub(s, assert(src:find("\nend", s, true)))
        H.assertTrue(body:find("xpcall%([^,]+, ErrorHandler") ~= nil, name .. " catches with the reporting handler")
    end
end

local pass, fail, failures = H.runSuite("ErrorHandler", tests)
return { pass = pass, fail = fail, failures = failures }
