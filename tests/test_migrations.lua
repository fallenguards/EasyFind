-- Tests for the core save migrations (Core/Main.lua OnInitialize with
-- Shared/Utils.lua Utils.Migrate): steps run before defaults, in order,
-- stop at an error for a retry, reach profile slots, and a new save runs none.

local H = require("Harness")

local function Read(rel)
    local fh = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local text = fh:read("*a")
    fh:close()
    return text
end

-- Utils.Migrate alone, and Core/Main.lua from DB_DEFAULTS through the
-- migration part of OnInitialize, over a stand-in save.
local function Load(save, opts)
    opts = opts or {}
    local env = setmetatable({ EasyFindDB = save, EasyFind = {} }, { __index = _G })
    local reported = {}
    env.geterrorhandler = function() return function(err) reported[#reported + 1] = err end end
    local utilsSrc = Read("Shared/Utils.lua")
    local m = utilsSrc:find("\nfunction Utils.Migrate(", 1, true)
    local Utils = {}
    if m then
        local _, me = utilsSrc:find("\nend\r?\n", m)
        assert(load("local Utils = ...\nlocal ErrorHandler = function(e) return tostring(e) end\n"
            .. utilsSrc:sub(m, me), "=Utils.Migrate", "t", env))(Utils)
    end
    local main = Read("Core/Main.lua")
    local version = tonumber(main:match("\nlocal DB_VERSION = (%d+)"))
    local s = assert(main:find("\nlocal DB_DEFAULTS = {", 1, true))
    local cut = assert(main:find("\n    EasyFind.db = EasyFindDB", s, true), "OnInitialize's db line")
    local prefix = "local ADDON_NAME, ns = ...\nlocal Utils = ns.Utils\nlocal L = ns.L\n"
        .. "local sformat, pairs, xpcall = string.format, pairs, xpcall\nlocal mmin, mmax = math.min, math.max\n"
        .. "local ErrorHandler = function(e) return tostring(e) end\n"
        .. "local DB_VERSION = " .. version .. "\nlocal REVAMPED_TUTORIAL_VERSION = \"2.0.0\"\n"
    local suffix = "\nend\nreturn OnInitialize, DB_MIGRATIONS"
    local ns = { Utils = setmetatable({ Migrate = Utils.Migrate }, { __index = { DeepCopy = function(v)
        local function deep(x)
            if type(x) ~= "table" then return x end
            local out = {}
            for k, y in pairs(x) do out[k] = deep(y) end
            return out
        end
        return deep(v)
    end } }), L = setmetatable({}, { __index = function(_, k) return k end }) }
    local chunk = assert(load(prefix .. main:sub(s, cut) .. suffix, "=Core/Main.lua init", "t", env))
    local OnInitialize, steps = chunk(nil, ns)
    if opts.steps then opts.steps(steps) end
    OnInitialize()
    return env.EasyFindDB, version, reported, ns
end

local tests = {}

function tests.aNewSaveStartsAtTheSchemaAndRunsNoStep()
    local db, version = Load(nil)
    H.assertEq(db.dbVersion, version)
    H.assertTrue(db.firstInstall)
    H.assertNil(db.showLoginMessage, "step 15 never ran")
    H.assertNil(db.lastSeenVersion, "nothing to announce to a new install")
    H.assertEq(db.tutorialDone, false, "the tutorial waits for a new install")
end

function tests.flightPathsTurnedOnSurviveTheFold()
    local db, version = Load({ dbVersion = 18, mapTabFilters = { flightpath = true } })
    H.assertEq(db.mapTabFilters.flights, true, "step 19 sees the save before defaults")
    H.assertNil(db.mapTabFilters.flightpath)
    H.assertEq(db.dbVersion, version)
end

function tests.profileSlotsGetTheStepsTheyMissed()
    local db = Load({ dbVersion = 21, profiles = { Alt = { settings = { mapPinHighlight = false } } } })
    local settings = db.profiles.Alt.settings
    H.assertEq(settings.mapPinStyle, "off", "step 22 reached the slot")
    H.assertNil(settings.mapPinHighlight)
end

function tests.aFailingStepStopsThereAndIsReported()
    local db, _, reported = Load({ dbVersion = 19 }, { steps = function(steps)
        steps[20] = function() error("broken step") end
    end })
    H.assertEq(db.dbVersion, 19, "the next login retries from 20")
    H.assertEq(#reported, 1)
    H.assertTrue(reported[1]:find("broken step", 1, true) ~= nil)
end

function tests.aWrongTypedValueGetsItsOwnDefault()
    local db, version, _, ns = Load({ dbVersion = 22, uiSearchFilters = "bad" })
    H.assertEq(type(db.uiSearchFilters), "table")
    H.assertTrue(db.uiSearchFilters ~= ns.DB_DEFAULTS.uiSearchFilters, "a copy, never the shared default")
    H.assertEq(db.dbVersion, version)
end

local pass, fail, failures = H.runSuite("Migrations", tests)
return { pass = pass, fail = fail, failures = failures }
