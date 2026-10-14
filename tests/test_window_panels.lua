-- Multi panels in WindowManager/Manager.lua: the world map is never taken out
-- of the game's slots, and a fight seats closed panels so the game's Esc
-- closes what opens in it, then detaches them again.
local H = require("Harness")

local function Frame(name, shown, maximizable)
    local f = { name = name, shown = shown, attrs = {}, points = 0 }
    f.GetName = function(self) return self.name end
    f.IsShown = function(self) return self.shown end
    f.Show = function(self) self.shown = true end
    f.Hide = function(self) self.shown = false end
    f.GetAttribute = function(self, k) return self.attrs[k] end
    f.SetAttribute = function(self, k, v) self.attrs[k] = v end
    f.HookScript = function() end
    f.GetNumPoints = function(self) return self.points end
    f.ClearAllPoints = function(self) self.points = 0 end
    f.SetPoint = function(self) self.points = 1 end
    if maximizable then f.Maximize = function() end end
    return f
end

local function Load()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env._G = env
    env.EasyFind.db = { windowMultiPanels = true }
    env.InCombatLockdown = function() return false end
    env.hooksecurefunc = function() end
    env.UIParent = Frame("UIParent", true)
    env.CreateFrame = function() return Frame(nil, true) end
    env.CharacterFrame = Frame("CharacterFrame", false)
    env.WorldMapFrame = Frame("WorldMapFrame", false, true)
    env.UIPanelWindows = {
        CharacterFrame = { area = "left", pushable = 3 },
        WorldMapFrame = { area = "left", maximizePoint = "TOP", allowOtherPanels = 1 },
    }
    local U = ns.Utils
    U.pairs, U.type, U.xpcall = pairs, type, xpcall
    U.mmin, U.ssub = math.min, string.sub
    U.SafeCallMethod = function(obj, method, ...) return obj[method](obj, ...) end
    U.ErrorHandler = function(e) return e end
    U.RefreshEscArm = function() end
    U.AttachEscClose = function() end
    U.SecureCall = function(f, ...) return f(...) end
    ns.SnapMath = {}
    ns.WindowRegistry = { entries = {}, GetFrame = function() end, GetEntryByName = function() end }
    H.loadModule("WindowManager/Manager.lua", env, ns)
    return ns.WindowManager, env
end

local tests = {}

function tests.worldMap_staysInTheGameSlots()
    local M, env = Load()
    M._SweepDetachablePanels()
    H.assertNil(M._panelState.WorldMapFrame, "map state")
    H.assertNil(env.WorldMapFrame.attrs["UIPanelLayout-defined"], "map keeps its row")
end

function tests.closedPanel_detachedOutsideAFight()
    local M, env = Load()
    M._SweepDetachablePanels()
    H.assertEq(M._panelState.CharacterFrame, "detached", "character state")
    H.assertEq(env.CharacterFrame.attrs["UIPanelLayout-defined"], true, "defined")
end

function tests.fightStart_seatsClosedPanels_fightEnd_detachesAgain()
    local M, env = Load()
    M._SweepDetachablePanels()
    M._StartFight()
    H.assertNil(M._panelState.CharacterFrame, "seated for the fight")
    H.assertNil(env.CharacterFrame.attrs["UIPanelLayout-defined"], "row copies back")
    M._SweepDetachablePanels()
    H.assertNil(M._panelState.CharacterFrame, "no detach during the fight")
    M._EndFight()
    H.assertEq(M._panelState.CharacterFrame, "detached", "detached after the fight")
end

function tests.panelOpenAtFightStart_seatedOnceItCloses()
    local M, env = Load()
    M._SweepDetachablePanels()
    env.CharacterFrame:Show()
    M._StartFight()
    H.assertEq(M._panelState.CharacterFrame, "detached", "open: stays detached")
    env.CharacterFrame:Hide()
    M._EnsurePanelDetached({ name = "CharacterFrame" }, env.CharacterFrame)
    H.assertNil(M._panelState.CharacterFrame, "closed in the fight: seated")
end

function tests.panelOpenedInFight_waitsForItsCloseAfterIt()
    local M, env = Load()
    M._SweepDetachablePanels()
    M._StartFight()
    env.CharacterFrame:Show()
    M._EndFight()
    H.assertEq(M._panelState.CharacterFrame, "pending", "seated and open: pending")
    env.CharacterFrame:Hide()
    M._EnsurePanelDetached({ name = "CharacterFrame" }, env.CharacterFrame)
    H.assertEq(M._panelState.CharacterFrame, "detached", "detached on close")
end

local pass, fail, failures = H.runSuite("WindowPanels", tests)
return { pass = pass, fail = fail, failures = failures }
