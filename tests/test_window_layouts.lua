-- Tests for WindowManager/Layouts.lua: the layout for here ranks by its
-- saving place, and applying opens and snaps a layout or closes it as one.
local H = require("Harness")

local function Load(opts)
    opts = opts or {}
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind.db = { windowLayouts = opts.layouts or {} }
    env.EasyFind.Print = function() end
    env.IsInInstance = function() return opts.kind ~= nil, opts.kind or "none" end
    env.IsResting = function() return opts.resting or false end
    env.InCombatLockdown = function() return false end
    env.C_Map = { GetBestMapForUnit = function() return opts.map or 1 end }
    env.time = function() return 1000 end
    env.HideUIPanel = function(f) f.shown = false end
    env.ShowUIPanel = function(f) f.shown = true end
    env.xpcall = function(f) return pcall(f) end
    local frames, applied = {}, {}
    local function Frame(name, shown)
        local f = { name = name, shown = shown, GetObjectType = function() return "Frame" end }
        f.IsShown = function(self) return self.shown end
        f.Hide = function(self) self.shown = false end
        frames[name] = f
        return f
    end
    Frame("CharacterFrame", opts.charShown)
    Frame("PlayerSpellsFrame", opts.spellsShown)
    local entries = {
        { name = "CharacterFrame", uiPanel = true, open = function() frames.CharacterFrame.shown = true end },
        { name = "PlayerSpellsFrame", uiPanel = true },
        { name = "EasyFindSearchFrame", own = true },
    }
    local byName = {}
    for _, e in ipairs(entries) do byName[e.name] = e end
    ns.WindowRegistry = {
        ForEach = function(_, cb) for _, e in ipairs(entries) do cb(e) end end,
        GetEntryByName = function(_, name) return byName[name] end,
        GetFrame = function(_, entry) return entry and frames[entry.name] end,
    }
    ns.WindowManager = {
        GetAppliedZone = function(_, name) local k = opts.zones and opts.zones[name] if k then return 0, 0, 1, 1, k end end,
        ApplySpecTo = function(_, entry, spec, momentary) applied[#applied + 1] = { entry.name, spec, momentary } return true end,
    }
    ns.Utils.SecureCall = function(f, ...) return f(...) end
    ns.Utils.ErrorHandler = function(e) return e end
    H.loadModule("WindowManager/Layouts.lua", env, ns)
    return ns.WindowLayouts, frames, applied
end

local tests = {}

function tests.rank_prefersTheSamePlaceThenTheSameKind()
    local Layouts = Load()
    local here = { map = 10, kind = "raid", resting = false }
    H.assertEq(Layouts.Rank({ map = 10, kind = "raid" }, here), 4, "the same zone")
    H.assertEq(Layouts.Rank({ map = 11, kind = "raid" }, here), 3, "another raid")
    H.assertEq(Layouts.Rank({ map = 11, kind = "party" }, here), 0, "a dungeon layout in a raid")
    H.assertEq(Layouts.Rank({ map = 11, resting = true }, { map = 12, resting = true }), 2, "both at rest")
    H.assertEq(Layouts.Rank({ map = 11 }, { map = 12 }), 1, "both out in the world")
    H.assertEq(Layouts.Rank({ map = 11 }, { map = 12, kind = "party" }), 0, "the world's layout in a dungeon")
end

function tests.forHere_takesTheBestFit_thenTheLastUsed()
    local Layouts = Load({ map = 10, kind = "raid", layouts = {
        { id = "a", name = "Town", windows = {}, at = { map = 3, resting = true }, used = 5 },
        { id = "b", name = "Old raid", windows = {}, at = { map = 11, kind = "raid" }, used = 1 },
        { id = "c", name = "Raid", windows = {}, at = { map = 12, kind = "raid" }, used = 9 },
    } })
    H.assertEq(Layouts:ForHere().id, "c", "the raid layout used last")
    local none = Load({ map = 10, kind = "party", layouts = { { id = "a", name = "Town", windows = {}, at = { map = 3, resting = true } } } })
    H.assertNil(none:ForHere(), "nothing fits a dungeon")
end

function tests.snapshot_takesTheOpenWindowsWithTheirZones()
    local Layouts = Load({ charShown = true, spellsShown = false, zones = { CharacterFrame = "left-half" } })
    local windows = Layouts._Snapshot()
    H.assertEq(#windows, 1)
    H.assertEq(windows[1].name, "CharacterFrame")
    H.assertEq(windows[1].spec, "left-half")
end

function tests.apply_opensAndSnapsForTheMoment_thenClosesAsOne()
    local layout = { id = "x", name = "Two", windows = { { name = "CharacterFrame", spec = "left-half" }, { name = "PlayerSpellsFrame", spec = "right-half" } } }
    local Layouts, frames, applied = Load({ charShown = false, spellsShown = true, layouts = { layout } })
    H.assertTrue(Layouts:Apply("x"))
    H.assertTrue(frames.CharacterFrame.shown, "opened through its opener")
    H.assertEq(#applied, 2)
    H.assertEq(applied[1][2], "left-half")
    H.assertTrue(applied[1][3], "for the moment")
    H.assertTrue(Layouts:Apply("x"), "all open: closed as one")
    H.assertFalse(frames.CharacterFrame.shown)
    H.assertFalse(frames.PlayerSpellsFrame.shown)
    H.assertEq(#applied, 2, "closing snaps nothing")
end

function tests.standing_keepsItsZones()
    local layout = { id = "x", name = "Keep", windows = { { name = "CharacterFrame", spec = "center" } }, standing = true }
    local Layouts, _, applied = Load({ charShown = true, layouts = { layout } })
    Layouts:Apply("x")
    H.assertEq(#applied, 0, "all of it open: closed")
    Layouts:Apply("x")
    H.assertEq(applied[1][3], false, "the standing layout snaps for keeps")
end

local pass, fail, failures = H.runSuite("WindowLayouts", tests)
return { pass = pass, fail = fail, failures = failures }
