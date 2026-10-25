-- The achievement search's own name list (Search/Providers/Achievements.lua),
-- kept for a session where the client's search answers nothing (Statistics
-- view, then a reload): read from its save only when an empty answer needs
-- it, never once the client has answered, and in a broken session it serves
-- the rows. Runs the real provider and Shared/Utils.lua.
local H = require("Harness")

local function fakeWidget()
    local w = {}
    setmetatable(w, { __index = function() return function() return w end end })
    return w
end

local SPEC = { { "id" }, { "name" }, { "icon" }, { "isGuild" }, { "completed" } }
local ACHIEVEMENTS = { [1] = "Vendor Trash", [2] = "Venture Forth", [3] = "Loremaster" }

local function World(broken)
    local env = H.newEnv()
    env.CreateFont, env.CreateFrame = fakeWidget, fakeWidget
    env.CreateColor = function(r, g, b, a) return { GetRGBA = function() return r, g, b, a end } end
    env.UIParent, env.WorldFrame, env.GameTooltip = fakeWidget(), fakeWidget(), fakeWidget()
    env.hooksecurefunc = function() end
    env.GameFontNormal = setmetatable({}, { __index = function(_, k)
        if k == "GetFont" then return function() return "font", 12, "" end end
        return function() end
    end })
    local ns = H.newNs(env)
    H.loadModule("Shared/Utils.lua", env, ns)
    local Utils = ns.Utils

    local frames = {}
    env.CreateFrame = function()
        local f = H.newFrame()
        frames[#frames + 1] = f
        return f
    end
    env.GetBuildInfo = function() return "12.0.5", "65000" end
    local rows = {}
    for id, name in pairs(ACHIEVEMENTS) do
        rows[#rows + 1] = { id = id, name = name, icon = 100 + id, completed = false }
    end
    table.sort(rows, function(a, b) return a.id < b.id end)
    env.EasyFind.db = { achievementIndex = { version = 2, build = "12.0.5-65000", packed = Utils.PackRows(rows, SPEC) } }

    local client = { matches = {} }
    env.SetAchievementSearchString = function(q)
        client.matches = {}
        if broken then return end
        for id, name in pairs(ACHIEVEMENTS) do
            if name:lower():find(q, 1, true) then client.matches[#client.matches + 1] = id end
        end
        table.sort(client.matches)
    end
    env.GetNumFilteredAchievements = function() return #client.matches end
    env.GetFilteredAchievementID = function(i) return client.matches[i] end
    env.GetAchievementInfo = function(id)
        return id, ACHIEVEMENTS[id], 10, false, nil, nil, nil, "", 0, 100 + id, "", false
    end

    local typed, refreshes = "", 0
    ns.Search.GetSearchFrame = function()
        return { editBox = { GetText = function() return typed end, GetCursorPosition = function() return #typed end } }
    end
    ns.Search.OnSearchTextChanged = function() refreshes = refreshes + 1 end
    env._G = env
    H.loadModule("Search/Providers/Achievements.lua", env, ns)
    local Providers = ns.SearchProviders

    local w = { Utils = Utils, Providers = Providers }
    -- Types a query, lets the client answer, and runs what was queued.
    function w.Search(q)
        typed = q
        local rowsNow = Providers:RequestAchievementSearch(q)
        if rowsNow then return rowsNow end
        for _, f in ipairs(frames) do
            local onEvent = f._handlers.OnEvent
            if onEvent then onEvent(f, "ACHIEVEMENT_SEARCH_UPDATED") end
        end
        env._clock:advance(1)
        return Providers:RequestAchievementSearch(q)
    end
    function w.Armed() return Utils._DebugPeekCorpora().achievementsFallback ~= nil end
    function w.Refreshes() return refreshes end
    return w
end

local tests = {}

function tests.aHealthySessionNeverReadsTheSavedList()
    local w = World(false)
    local rows = w.Search("ve")
    H.assertEq(#rows, 2, "the client's answer")
    H.assertFalse(w.Armed(), "not read for a search the client answered")
    rows = w.Search("zzz")
    H.assertEq(#rows, 0, "an empty answer stands once the client has answered")
    H.assertFalse(w.Armed())
end

function tests.aBrokenSessionServesTheSavedList()
    local w = World(true)
    local rows = w.Search("ve")
    H.assertTrue(w.Armed(), "read when the client answers nothing")
    H.assertTrue(w.Refreshes() >= 1, "the open search is run again once it is ready")
    H.assertEq(#rows, 2, "the rows come from the saved list")
end

local pass, fail, failures = H.runSuite("AchievementFallback", tests)
return { pass = pass, fail = fail, failures = failures }
