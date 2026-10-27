-- Tests for Toggle Objective Tracker (Core/Main.lua): the game's tracker
-- (the quest watch on the classic clients) hidden and kept hidden while the
-- game shows it again, shown back by the next toggle, restored at login,
-- and left alone while edit mode is open.
local H = require("Harness")

local function Read(rel)
    local fh = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local text = fh:read("*a")
    fh:close()
    return text
end

-- A frame whose Show and Hide reach its children's scripts, as the game's do.
local function Frame(parent, shown)
    local f = { shown = shown ~= false, children = {}, scripts = {} }
    if parent then parent.children[#parent.children + 1] = f end
    local function fire(frame, name)
        local fn = frame.scripts[name]
        if fn then fn(frame) end
        for _, c in ipairs(frame.children) do fire(c, name) end
    end
    function f:IsShown() return self.shown end
    function f:SetScript(name, fn) self.scripts[name] = fn end
    function f:Show() if self.shown then return end self.shown = true fire(self, "OnShow") end
    function f:Hide() if not self.shown then return end self.shown = false fire(self, "OnHide") end
    return f
end

local function LoadToggle()
    local src = Read("Core/Main.lua")
    local s = assert(src:find("\n-- Hide/show the game's objective tracker", 1, true), "the tracker toggle not in Core/Main.lua")
    local f = assert(src:find("\nfunction EasyFind:ToggleObjectiveTracker()", s, true))
    local _, e = src:find("\nend\r?\n", f)
    local env = H.newEnv()
    env._G = env
    local ns = H.newNs(env)
    ns.Utils.SafeAfter = function(_, fn) fn() end
    local placed = { n = 0 }
    ns.GPS = { PlaceDock = function() placed.n = placed.n + 1 end }
    env.EasyFind = { db = {} }
    env.CreateFrame = function(_, _, parent) return Frame(parent, true) end
    env.ObjectiveTrackerFrame = Frame(nil, true)
    local chunk = assert(load("local _, ns = ...\n" .. src:sub(s, e), "=Core/Main.lua tracker", "t", env))
    chunk(nil, ns)
    return env, env.EasyFind, placed
end

local tests = {}

function tests.toggleHidesTheTrackerAndKeepsItHidden()
    local env, EasyFind, placed = LoadToggle()
    EasyFind:ToggleObjectiveTracker()
    H.assertFalse(env.ObjectiveTrackerFrame:IsShown(), "hidden")
    H.assertTrue(EasyFind.db.objectiveTrackerHidden, "kept across sessions")
    H.assertEq(placed.n, 1, "GPS places its dock again")
    env.ObjectiveTrackerFrame:Show()
    H.assertFalse(env.ObjectiveTrackerFrame:IsShown(), "a quest update showing it: hidden again")
end

function tests.secondToggleShowsItAndStopsRehiding()
    local env, EasyFind = LoadToggle()
    EasyFind:ToggleObjectiveTracker()
    EasyFind:ToggleObjectiveTracker()
    H.assertTrue(env.ObjectiveTrackerFrame:IsShown(), "shown back")
    H.assertNil(EasyFind.db.objectiveTrackerHidden)
    env.ObjectiveTrackerFrame:Hide()
    env.ObjectiveTrackerFrame:Show()
    H.assertTrue(env.ObjectiveTrackerFrame:IsShown(), "the game's own show stands")
end

function tests.hiddenLastSessionHiddenAtLogin()
    local env, EasyFind = LoadToggle()
    EasyFind.db.objectiveTrackerHidden = true
    EasyFind:RestoreObjectiveTrackerHidden()
    H.assertFalse(env.ObjectiveTrackerFrame:IsShown())
    env.ObjectiveTrackerFrame:Show()
    H.assertFalse(env.ObjectiveTrackerFrame:IsShown(), "hidden again after the game shows it")
end

function tests.classicClientsHideTheQuestWatch()
    local env, EasyFind = LoadToggle()
    env.ObjectiveTrackerFrame = nil
    env.WatchFrame = Frame(nil, true)
    EasyFind:ToggleObjectiveTracker()
    H.assertFalse(env.WatchFrame:IsShown(), "the quest watch is the tracker there")
end

-- Era's quest watch is QuestWatchFrame (Vanilla/QuestLogFrame.xml; the
-- Wrath WatchFrame loads from Wrath on): nothing happened there (2026-10-28).
function tests.eraHidesItsQuestWatch()
    local env, EasyFind = LoadToggle()
    env.ObjectiveTrackerFrame = nil
    env.QuestWatchFrame = Frame(nil, true)
    EasyFind:ToggleObjectiveTracker()
    H.assertFalse(env.QuestWatchFrame:IsShown(), "hidden")
    H.assertTrue(EasyFind.db.objectiveTrackerHidden)
    EasyFind:ToggleObjectiveTracker()
    H.assertTrue(env.QuestWatchFrame:IsShown(), "shown back")
    local blizz = Read("Apps/Settings/BlizzSearch.lua")
    H.assertTrue(blizz:find('_G%["ObjectiveTrackerFrame"%] or _G%["WatchFrame"%] or _G%["QuestWatchFrame"%]') ~= nil,
        "the entry's check mark reads the same frames")
end

function tests.editModeKeepsItUntilItCloses()
    local env, EasyFind = LoadToggle()
    env.EditModeManagerFrame = Frame(nil, false)
    EasyFind:ToggleObjectiveTracker()
    H.assertFalse(env.ObjectiveTrackerFrame:IsShown())
    env.EditModeManagerFrame:Show()
    env.ObjectiveTrackerFrame:Show()
    H.assertTrue(env.ObjectiveTrackerFrame:IsShown(), "edit mode shows every system: left shown")
    env.EditModeManagerFrame:Hide()
    H.assertFalse(env.ObjectiveTrackerFrame:IsShown(), "hidden again once edit mode closes")
end

local pass, fail, failures = H.runSuite("ObjectiveTrackerToggle", tests)
return { pass = pass, fail = fail, failures = failures }
