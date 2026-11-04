-- Tests for Toggle Objective Tracker (Core/Main.lua): the game's tracker
-- (the quest watch on the classic clients) and any tracker an extension
-- registers hidden and kept hidden while their owners show them again,
-- shown back by the next toggle, restored at login, and left alone while
-- edit mode is open.
local H = require("Harness")

local function Read(rel)
    local fh = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local text = fh:read("*a")
    fh:close()
    return text
end

-- A frame whose Show and Hide reach its children's scripts, as the game's do.
local function Frame(parent, shown)
    local f = { shown = shown ~= false, children = {}, scripts = {}, events = {} }
    if parent then parent.children[#parent.children + 1] = f end
    local function fire(frame, name)
        local fn = frame.scripts[name]
        if fn then fn(frame) end
        for _, c in ipairs(frame.children) do fire(c, name) end
    end
    function f:IsShown() return self.shown end
    function f:IsProtected() return self.protected == true end
    function f:SetScript(name, fn) self.scripts[name] = fn end
    function f:RegisterEvent(e) self.events[e] = true end
    function f:UnregisterAllEvents() self.events = {} end
    function f:Show() if self.shown then return end self.shown = true fire(self, "OnShow") end
    function f:Hide() if not self.shown then return end self.shown = false fire(self, "OnHide") end
    return f
end

-- queued: the next frame's timers wait for run(), as in the game.
local function LoadToggle(queued)
    local src = Read("Core/Main.lua")
    local s = assert(src:find("\n-- Hide/show the game's objective tracker", 1, true), "the tracker toggle not in Core/Main.lua")
    local f = assert(src:find("\nfunction EasyFind:ToggleObjectiveTracker()", s, true))
    local _, e = src:find("\nend\r?\n", f)
    local env = H.newEnv()
    env._G = env
    local ns = H.newNs(env)
    local timers = {}
    ns.Utils.SafeAfter = function(_, fn)
        if queued then timers[#timers + 1] = fn else fn() end
    end
    local function run()
        local due = timers
        timers = {}
        for _, fn in ipairs(due) do fn() end
    end
    -- The news an extension docked there (the GPS) hears.
    local placed = { n = 0 }
    env.EasyFind = { db = {}, API = { Fire = function(id, event)
        if id == "easyfind" and event == "trackerChanged" then placed.n = placed.n + 1 end
    end } }
    local made = {}
    env.CreateFrame = function(_, _, parent)
        local frame = Frame(parent, true)
        made[#made + 1] = frame
        return frame
    end
    env.combat = false
    env.InCombatLockdown = function() return env.combat end
    function env.FireEvent(event)
        for _, frame in ipairs(made) do
            if frame.events[event] and frame.scripts.OnEvent then frame.scripts.OnEvent(frame, event) end
        end
    end
    env.ObjectiveTrackerFrame = Frame(nil, true)
    local chunk = assert(load("local _, ns = ...\n" .. src:sub(s, e), "=Core/Main.lua tracker", "t", env))
    chunk(nil, ns)
    return env, env.EasyFind, placed, ns, run
end

local tests = {}

function tests.toggleHidesTheTrackerAndKeepsItHidden()
    local env, EasyFind, placed = LoadToggle()
    EasyFind:ToggleObjectiveTracker()
    H.assertFalse(env.ObjectiveTrackerFrame:IsShown(), "hidden")
    H.assertTrue(EasyFind.db.objectiveTrackerHidden, "kept across sessions")
    H.assertEq(placed.n, 1, "EasyFind tells the GPS its dock moves")
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

-- The row draws its check mark again in the frame of the click: a hide a
-- frame later read "shown" after every hide, so after one round trip the
-- row stuck on enabled (Era, 2026-11-04).
function tests.everyHideLands_inTheFrameOfTheClick()
    local env, EasyFind, _, _, run = LoadToggle(true)
    for round = 1, 3 do
        EasyFind:ToggleObjectiveTracker()
        H.assertFalse(env.ObjectiveTrackerFrame:IsShown(), "hidden before the row redraws, round " .. round)
        EasyFind:ToggleObjectiveTracker()
        H.assertTrue(env.ObjectiveTrackerFrame:IsShown(), "shown before the row redraws, round " .. round)
        run()
        H.assertTrue(env.ObjectiveTrackerFrame:IsShown(), "and stays shown, round " .. round)
    end
end

-- World quest zones show the tracker over and over while moving: hidden a
-- frame later, each show drew once and the hidden tracker flickered
-- (retail, 2026-11-04).
function tests.theGameShowingItAgain_isHiddenInThatSameFrame()
    local env, EasyFind = LoadToggle(true)
    EasyFind:ToggleObjectiveTracker()
    for _ = 1, 3 do
        env.ObjectiveTrackerFrame:Show()
        H.assertFalse(env.ObjectiveTrackerFrame:IsShown(), "never drawn")
    end
end

function tests.theRowReadsTheToggle_notAFrameAnotherTrackerHides()
    local blizz = Read("Apps/Settings/BlizzSearch.lua")
    local s = assert(blizz:find("EASYFIND_TOGGLEOBJECTIVETRACKER = {", 1, true))
    local entry = blizz:sub(s, (blizz:find("\n    },", s, true)))
    H.assertTrue(entry:find("objectiveTrackerHidden", 1, true) ~= nil, "the check mark reads the toggle's setting")
    H.assertNil(entry:find("QuestWatchFrame", 1, true), "never Era's quest watch, which another tracker keeps hidden")
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
end

-- Another addon's tracker hides Era's quest watch for good: shown back,
-- it stood empty beside that tracker.
function tests.aWatchItsOwnerHid_staysHiddenOnShow()
    local env, EasyFind = LoadToggle()
    env.ObjectiveTrackerFrame = nil
    env.QuestWatchFrame = Frame(nil, false)
    EasyFind:ToggleObjectiveTracker()
    EasyFind:ToggleObjectiveTracker()
    H.assertFalse(env.QuestWatchFrame:IsShown(), "only what the toggle hid comes back")
    H.assertNil(EasyFind.db.objectiveTrackerHidden)
end

-- Questie's tracker stood in for Era's quest watch and never hid (2026-11-04).
function tests.anExtensionsTracker_hidesAndShowsWithIt()
    local _, EasyFind, _, ns, run = LoadToggle(true)
    local other = Frame(nil, true)
    local shownTheOwnersWay = 0
    ns.AddTrackerPiece(other, function()
        shownTheOwnersWay = shownTheOwnersWay + 1
        other:Show()
    end)
    EasyFind:ToggleObjectiveTracker()
    H.assertFalse(other:IsShown(), "hidden with the tracker")
    other:Show()
    H.assertFalse(other:IsShown(), "its owner's update showing it: hidden in that same frame, no flash")
    run()
    EasyFind:ToggleObjectiveTracker()
    H.assertTrue(other:IsShown(), "shown back")
    H.assertEq(shownTheOwnersWay, 1, "through its owner, whose own rules (instances, nothing tracked) still hold")
end

function tests.anExtensionsTracker_registeredWhileHidden_hidesAtOnce()
    local _, EasyFind, _, ns = LoadToggle(true)
    EasyFind.db.objectiveTrackerHidden = true
    local other = Frame(nil, true)
    ns.AddTrackerPiece(other)
    H.assertFalse(other:IsShown(), "hidden as it arrives")
    EasyFind:ToggleObjectiveTracker()
    H.assertTrue(other:IsShown(), "shown back without a show of its own")
end

-- A tracker holding quest item buttons (secure) cannot hide in combat.
function tests.aTrackerWithItemButtons_movesOnceCombatEnds()
    local env, EasyFind, _, ns = LoadToggle(true)
    local other = Frame(nil, true)
    other.protected = true
    ns.AddTrackerPiece(other)
    env.combat = true
    EasyFind:ToggleObjectiveTracker()
    H.assertTrue(other:IsShown(), "left alone in combat")
    H.assertFalse(env.ObjectiveTrackerFrame:IsShown(), "the game's own watch hides at once")
    env.combat = false
    env.FireEvent("PLAYER_REGEN_ENABLED")
    H.assertFalse(other:IsShown(), "hidden as combat ends")
    env.combat = true
    EasyFind:ToggleObjectiveTracker()
    H.assertFalse(other:IsShown(), "still hidden in the next fight")
    env.combat = false
    env.FireEvent("PLAYER_REGEN_ENABLED")
    H.assertTrue(other:IsShown(), "shown as that fight ends")
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

function tests.theApiHandsItsFrameToTheToggle()
    local api = Read("Core/API.lua")
    H.assertTrue(api:find("function API.RegisterTrackerPiece(frame, show)", 1, true) ~= nil, "in the API")
    H.assertTrue(api:find("ns.AddTrackerPiece(frame, show)", 1, true) ~= nil, "reaches the toggle")
end

local pass, fail, failures = H.runSuite("ObjectiveTrackerToggle", tests)
return { pass = pass, fail = fail, failures = failures }
