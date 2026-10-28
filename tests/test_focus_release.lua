-- An edit box of ours drops its focus on a click anywhere but on it
-- (Utils.ReleaseFocusOnOutsideClick): the client kept the GPS and map
-- tab boxes focused through clicks elsewhere on Era (2026-10-28). The
-- watcher listens only while such a box has the focus, and leaves a box
-- that is not ours alone. Loads the REAL Shared/Utils.lua.
local H = require("Harness")
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

-- The watcher frame the helper makes: its events and its handler.
local watcher = { events = {} }
function watcher:SetScript(_, fn) self.onEvent = fn end
function watcher:RegisterEvent(e) self.events[e] = true end
function watcher:UnregisterEvent(e) self.events[e] = nil end
env.CreateFrame = function() return watcher end

local focused
env.GetCurrentKeyBoardFocus = function() return focused end

H.loadModule("Shared/Utils.lua", env, ns)
local Utils = ns.Utils

local function newBox()
    local box = { hooks = {}, over = false, cleared = 0 }
    function box:HookScript(name, fn) self.hooks[name] = fn end
    function box:IsMouseOver() return self.over end
    function box:ClearFocus() self.cleared = self.cleared + 1 end
    return box
end

local tests = {}

function tests.aClickOffTheBoxDropsItsFocus()
    local box = newBox()
    Utils.ReleaseFocusOnOutsideClick(box)
    box.hooks.OnEditFocusGained()
    H.assertTrue(watcher.events.GLOBAL_MOUSE_DOWN, "watched while the box has the focus")
    focused = box
    box.over = true
    watcher.onEvent(watcher, "GLOBAL_MOUSE_DOWN")
    H.assertEq(box.cleared, 0, "a click on the box keeps it")
    box.over = false
    watcher.onEvent(watcher, "GLOBAL_MOUSE_DOWN")
    H.assertEq(box.cleared, 1, "a click elsewhere drops it")
    focused = nil
    box.hooks.OnEditFocusLost()
    H.assertNil(watcher.events.GLOBAL_MOUSE_DOWN, "unwatched once no box of ours has the focus")
end

function tests.aBoxNotOursIsLeftAlone()
    local box, other = newBox(), newBox()
    Utils.ReleaseFocusOnOutsideClick(box)
    box.hooks.OnEditFocusGained()
    focused = other
    watcher.onEvent(watcher, "GLOBAL_MOUSE_DOWN")
    H.assertEq(other.cleared, 0)
    H.assertEq(box.cleared, 0)
    -- Our box loses the focus to a box of ours: the watch stays.
    focused = box
    other.hooks.OnEditFocusLost = nil
    box.hooks.OnEditFocusLost()
    H.assertTrue(watcher.events.GLOBAL_MOUSE_DOWN, "still watched while a box of ours has the focus")
    focused = nil
    box.hooks.OnEditFocusLost()
end

function tests.everySearchBoxOfTheGpsAndTheMapTabReleases()
    local function Read(rel)
        local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
        local src = f:read("*a")
        f:close()
        return src
    end
    H.assertTrue(Read("Apps/GPS/GPS.lua"):find("box:SetMaxLetters%(60%)%s+Utils%.ReleaseFocusOnOutsideClick%(box%)") ~= nil,
        "the GPS search box")
    H.assertTrue(Read("Apps/GPS/Trip.lua"):find("box:SetMaxLetters%(60%)%s+ns%.Utils%.ReleaseFocusOnOutsideClick%(box%)") ~= nil,
        "a trip's field")
    H.assertTrue(Read("MapSearch/MapTab.lua"):find("editBox:SetMaxLetters%(60%)%s+Utils%.ReleaseFocusOnOutsideClick%(editBox%)") ~= nil,
        "the map tab's search box")
end

local pass, fail, failures = H.runSuite("FocusRelease", tests)
return { pass = pass, fail = fail, failures = failures }
