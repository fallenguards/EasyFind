-- The keyboard focus and the frames under the mouse can be forbidden
-- (Forever's Communities add dialog box, 2026-11-04): any method our code
-- calls on one errors, so ChatPasteSwap's GetObjectType threw the moment
-- that box took the focus. Every read goes through Utils.KeyboardFocus and
-- Utils.MouseFoci, which leave forbidden frames out. Loads the REAL
-- Shared/Utils.lua and Shared/ChatPasteSwap.lua.
local H = require("Harness")

local CLIENT_READS = { "GetCurrentKeyBoardFocus", "GetMouseFoci", "GetMouseFocus" }
local HELPERS = { "function Utils.KeyboardFocus()", "function Utils.MouseFoci()" }

-- Lines naming a client read, less those inside the two helpers.
local function bareReads(text, rel)
    local hits, inHelper, n = {}, false, 0
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        n = n + 1
        if rel == "Shared/Utils.lua" then
            for _, head in ipairs(HELPERS) do
                if line:find(head, 1, true) == 1 then inHelper = true end
            end
        end
        local code = line:gsub("%-%-.*$", ""):gsub('"[^"]*"', '""')
        if not inHelper then
            for _, name in ipairs(CLIENT_READS) do
                if code:find("%f[%w_]" .. name .. "%f[^%w_]") then
                    hits[#hits + 1] = rel .. ":" .. n
                    break
                end
            end
        end
        if inHelper and line:find("^end") then inHelper = false end
    end
    return hits
end

-- A forbidden frame: fields read nil, every method but IsForbidden errors.
local function forbidden(label)
    return setmetatable({}, { __index = function(_, k)
        if k == "IsForbidden" then return function() return true end end
        if type(k) == "string" and k:sub(1, 1) == "_" then return nil end
        return function() error("calling '" .. k .. "' on bad self (" .. label .. " is forbidden)") end
    end })
end

local function plain(parent)
    return { IsForbidden = function() return false end, GetParent = function() return parent end,
        GetObjectType = function() return "EditBox" end, GetName = function() return nil end }
end

local function loadUtils()
    local env = H.newEnv()
    local ns = H.newNs(env)
    local function fakeWidget()
        local w = {}
        setmetatable(w, { __index = function() return function() return w end end })
        return w
    end
    env.CreateFont = fakeWidget
    env.CreateColor = function(r, g, b, a) return { GetRGBA = function() return r, g, b, a end } end
    env.UIParent = fakeWidget()
    env.WorldFrame = fakeWidget()
    env.GameTooltip = fakeWidget()
    env.hooksecurefunc = function() end
    env.GetCursorPosition = function() return 0, 0 end
    env.IsControlKeyDown = function() return false end
    env.GameFontNormal = setmetatable({}, { __index = function(_, k)
        if k == "GetFont" then return function() return "font", 12, "" end end
        return function() end
    end })
    H.loadModule("Shared/Utils.lua", env, ns)
    return env, ns
end

local tests = {}

function tests.noShippedFileReadsTheFocusBare()
    local bad, checked = {}, 0
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "r")
            if fh then
                checked = checked + 1
                for _, hit in ipairs(bareReads(fh:read("a"), rel)) do bad[#bad + 1] = hit end
                fh:close()
            end
        end
    end
    H.assertTrue(checked > 100, "expected the full file set, read " .. checked)
    H.assertEq(#bad, 0, "a client focus read outside Utils.KeyboardFocus / Utils.MouseFoci; "
        .. "a forbidden frame refuses every method:\n  " .. table.concat(bad, "\n  "))
end

function tests.scan_allowsOnlyTheHelpers()
    local utils = "function Utils.KeyboardFocus()\n    local f = GetCurrentKeyBoardFocus()\nend\n"
        .. "local x = GetMouseFoci()\n"
    H.assertDeepEq(bareReads(utils, "Shared/Utils.lua"), { "Shared/Utils.lua:4" })
    H.assertDeepEq(bareReads("local f = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()", "A.lua"), { "A.lua:1" })
    H.assertDeepEq(bareReads("-- GetMouseFoci() would hand a forbidden frame", "A.lua"), {})
    H.assertDeepEq(bareReads("local f = Utils.KeyboardFocus()", "A.lua"), {})
end

function tests.keyboardFocus_leavesAForbiddenBoxOut()
    local env, ns = loadUtils()
    local focus = forbidden("CommunitiesAddDialog box")
    env.GetCurrentKeyBoardFocus = function() return focus end
    H.assertNil(ns.Utils.KeyboardFocus(), "forbidden: nil")
    focus = plain()
    H.assertEq(ns.Utils.KeyboardFocus(), focus, "a plain box comes through")
    focus = nil
    H.assertNil(ns.Utils.KeyboardFocus())
end

function tests.mouseFoci_leaveForbiddenFramesOut()
    local env, ns = loadUtils()
    local a, b = plain(), plain()
    env.GetMouseFoci = function() return { forbidden("dialog"), a, forbidden("box"), b } end
    H.assertDeepEq(ns.Utils.MouseFoci(), { a, b })
end

function tests.ownedBy_stopsAtAForbiddenParent()
    local env, ns = loadUtils()
    local target = plain()
    local child = plain(target)
    env.GetMouseFoci = function() return { child } end
    H.assertTrue(ns.Utils.MouseFocusOwnedBy(target), "a plain chain reaches the target")
    local orphan = plain(forbidden("dialog"))
    env.GetMouseFoci = function() return { orphan } end
    H.assertFalse(ns.Utils.MouseFocusOwnedBy(target), "the walk stops at the forbidden parent, no error")
end

-- The reported error: the copy watch ticker met the forbidden box.
function tests.copyWatch_skipsAForbiddenFocus()
    local env, ns = loadUtils()
    local ticker, onEvent
    env.CreateFrame = function()
        return { RegisterEvent = function() end, UnregisterEvent = function() end,
            SetScript = function(_, _, fn) onEvent = fn end }
    end
    env.C_Timer = { NewTicker = function(_, fn) ticker = fn end }
    ns.Utils.SafeAfter = function() end
    local watched = {}
    ns.Utils.AttachCopyWatch = function(box) watched[#watched + 1] = box end
    local focus = forbidden("CommunitiesAddDialog box")
    env.GetCurrentKeyBoardFocus = function() return focus end
    H.loadModule("Shared/ChatPasteSwap.lua", env, ns)
    onEvent({ UnregisterEvent = function() end })
    ticker()
    H.assertEq(#watched, 0, "no watch on a forbidden box")
    focus = plain()
    ticker()
    H.assertEq(watched[1], focus, "a plain box still gets the watch")
end

local pass, fail, failures = H.runSuite("ForbiddenFocus", tests)
return { pass = pass, fail = fail, failures = failures }
