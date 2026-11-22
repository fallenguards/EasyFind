-- Tests for the per-character key in Shared/Utils.lua: Forever's surnames
-- (UnitName returns "Test", "Addons"), the copy of first-name slots to the
-- full name's key, and a scan that keeps every other file off UnitName.
local H = require("Harness")

local function loadKeyCode(client)
    local ns = {}
    H.loadCharKeyCode({
        pairs = pairs, ipairs = ipairs, type = type, next = next, tonumber = tonumber,
        UnitName = function() return client.first, client.second end,
        GetUnitName = function() return client.full end,
        GetRealmName = function() return client.realm end,
        CopyTable = function(t)
            local out = {}
            for k, v in pairs(t) do out[k] = v end
            return out
        end,
        EasyFindDB = client.sv,
    }, ns)
    return ns
end

local FOREVER = { first = "Test", second = "Addons", full = "Test Addons", realm = "Classic Beta PvE 2" }
local RETAIL = { first = "Bob", second = nil, full = "Bob", realm = "Stormrage" }

local tests = {}

function tests.forever_keyHasTheSurname()
    local ns = loadKeyCode(FOREVER)
    H.assertEq(ns.PlayerName(), "Test Addons")
    H.assertEq(ns.CurrentCharacterKey(), "Test Addons-Classic Beta PvE 2")
end

function tests.retail_keyUnchanged()
    local ns = loadKeyCode(RETAIL)
    H.assertEq(ns.CurrentCharacterKey(), "Bob-Stormrage", "the same key retail always had")
end

function tests.forever_firstNameSlotsCopied()
    local client = {}
    for k, v in pairs(FOREVER) do client[k] = v end
    client.sv = { charGold = { ["Test-Addons"] = 5, ["Test Addons-"] = 0, ["Test Addons-ClassicBetaPvE2"] = 5, ["Other-Realm"] = 9 } }
    local ns = loadKeyCode(client)
    local old, new = "Test-Classic Beta PvE 2", "Test Addons-Classic Beta PvE 2"
    local pins = { a = true }
    local db = {
        profileKeys = { [old] = "Main" },
        shortkeysPerChar = { [old] = { row = "CTRL-1" }, [new] = {} },
        learnedStepLocks = { [old] = { step = true }, [new] = { kept = true } },
        profiles = { Alt = { pinnedUIItemsPerChar = { [old] = pins } } },
        bagCache = { chars = { [old] = {}, ["Other-Realm"] = {} } },
    }
    ns.MigrateCharacterKeys(db)
    H.assertEq(db.profileKeys[new], "Main")
    H.assertEq(db.shortkeysPerChar[new].row, "CTRL-1")
    H.assertTrue(db.shortkeysPerChar[old] ~= nil, "copied, not moved: another Test may still need it")
    H.assertTrue(db.learnedStepLocks[new].kept and not db.learnedStepLocks[new].step, "a slot already under the full name is kept")
    local copied = db.profiles.Alt.pinnedUIItemsPerChar[new]
    H.assertTrue(copied and copied.a and copied ~= pins, "stored profiles are copied too, as their own table")
    H.assertNil(db.bagCache.chars[old], "the old bag record would list a ghost character")
    H.assertTrue(db.bagCache.chars["Other-Realm"] ~= nil)
    local ledger = client.sv.charGold
    H.assertNil(ledger["Test-Addons"], "the surname was read as a realm")
    H.assertNil(ledger["Test Addons-"], "no realm")
    H.assertEq(ledger["Test Addons-ClassicBetaPvE2"], 5)
    H.assertEq(ledger["Other-Realm"], 9)
end

function tests.retail_migrationDoesNothing()
    local client = {}
    for k, v in pairs(RETAIL) do client[k] = v end
    client.sv = { charGold = { ["Bob-Stormrage"] = 1 } }
    local ns = loadKeyCode(client)
    local db = { profileKeys = { ["Bob-Stormrage"] = "Main" }, bagCache = { chars = { ["Bob-Stormrage"] = {} } } }
    ns.MigrateCharacterKeys(db)
    H.assertEq(db.profileKeys["Bob-Stormrage"], "Main")
    H.assertTrue(db.bagCache.chars["Bob-Stormrage"] ~= nil)
    H.assertEq(client.sv.charGold["Bob-Stormrage"], 1)
end

-- Forever's client answers an empty realm name in some sessions
-- (2026-11-22): the character's slots split in two, and a route asked to
-- learn a flight point filed under the other key.
local function Realmless(sv)
    local client = {}
    for k, v in pairs(FOREVER) do client[k] = v end
    client.realm, client.sv = "", sv
    return loadKeyCode(client), client
end

local OWN, BARE = "Test Addons-Classic Beta PvE 2", "Test Addons-"

function tests.emptyRealm_theKeyStaysTheCharactersOwn()
    local sv = { profileKeys = { [OWN] = "Main", [BARE] = "Default", ["Other One-Elsewhere"] = "Main" },
                 bagCache = { chars = { [OWN] = {} } },
                 -- The gold ledger's shape: the same realm without its spaces.
                 charGold = { ["Test Addons-ClassicBetaPvE2"] = 5 } }
    local ns = Realmless(sv)
    H.assertEq(ns.RealmName(), "Classic Beta PvE 2", "the realm its slots are filed under")
    H.assertEq(ns.CurrentCharacterKey(), OWN)
    H.assertEq(sv.charRealms["Test Addons"], "Classic Beta PvE 2", "remembered: no search next time")
    H.assertEq(ns.NormalizedRealmName(), "ClassicBetaPvE2")
end

function tests.emptyRealm_rememberedFromASessionThatHadIt()
    local sv = {}
    local client = {}
    for k, v in pairs(FOREVER) do client[k] = v end
    client.sv = sv
    H.assertEq(loadKeyCode(client).CurrentCharacterKey(), OWN)
    H.assertEq(Realmless(sv).CurrentCharacterKey(), OWN, "no slot carries it yet: the session that had it is remembered")
end

function tests.emptyRealm_nothingKept_theKeyIsBare()
    H.assertEq(Realmless({ profileKeys = { ["Other One-Elsewhere"] = "Main" } }).CurrentCharacterKey(), BARE)
end

function tests.emptyRealm_theNameOnTwoRealms_neitherIsTaken()
    local sv = { profileKeys = { [OWN] = "Main", ["Test Addons-Another Realm"] = "Main" } }
    H.assertEq(Realmless(sv).CurrentCharacterKey(), BARE)
end

function tests.slotsFiledUnderNoRealm_goBackIntoTheCharactersOwn()
    local route = { t = 100, dest = "Blackfathom Deeps" }
    local scan = { scannedAt = 20 }
    local db = {
        profileKeys = { [OWN] = "Main", [BARE] = "Default" },
        gpsChar = { [OWN] = { flights = { [22] = true, [23] = true }, route = { t = 5 } },
                    [BARE] = { flights = { [25] = true }, route = route } },
        gpsHearth = { [BARE] = { m = 1456 } },
        bagCache = { chars = { [OWN] = { scannedAt = 10 }, [BARE] = scan, ["Other One-Elsewhere"] = {} } },
        profiles = { Alt = { shortkeysPerChar = { [OWN] = { a = "CTRL-1" }, [BARE] = { a = "CTRL-9", b = "CTRL-2" } } } },
        rows = { { [BARE] = true } },
    }
    local ns = Realmless(db)
    ns.FoldRealmlessSlots(db)
    local own = db.gpsChar[OWN]
    H.assertTrue(own.flights[22] and own.flights[23] and own.flights[25], "every flight point learned, under either key")
    H.assertEq(own.route, route, "the route in progress: the newer one")
    H.assertNil(db.gpsChar[BARE], "no second slot left")
    H.assertEq(db.profileKeys[OWN], "Main", "its own profile pick stands")
    H.assertNil(db.profileKeys[BARE])
    H.assertEq(db.gpsHearth[OWN].m, 1456, "kept only under no realm: moved")
    H.assertEq(db.bagCache.chars[OWN], scan, "the newer bag scan")
    H.assertNil(db.bagCache.chars[BARE], "no ghost character")
    H.assertTrue(db.bagCache.chars["Other One-Elsewhere"] ~= nil)
    local keys = db.profiles.Alt.shortkeysPerChar
    H.assertEq(keys[OWN].a, "CTRL-1", "its own stands")
    H.assertEq(keys[OWN].b, "CTRL-2", "what it lacked comes over")
    H.assertNil(keys[BARE])
end

function tests.withARealm_andNoBareSlot_nothingIsWalked()
    local client = {}
    for k, v in pairs(RETAIL) do client[k] = v end
    local db = setmetatable({ profileKeys = { ["Bob-Stormrage"] = "Main" } }, { __pairs = function() error("walked") end })
    client.sv = db
    loadKeyCode(client).FoldRealmlessSlots(db)
    H.assertEq(db.profileKeys["Bob-Stormrage"], "Main")
end

-- The realm's name has one owner (ns.RealmName, ns.NormalizedRealmName):
-- a file asking the client itself keys its records under no realm in a
-- session the client has no name for it.
function tests.noOtherFileAsksTheClientForTheRealm()
    local p = assert(io.popen('git -C "' .. H.ADDON_ROOT .. '" ls-files "*.lua"'))
    local offenders, files = {}, 0
    for path in p:lines() do
        if not (path:match("^tests/") or path:match("^dev/") or path == "Shared/Utils.lua") then
            files = files + 1
            local f = io.open(H.ADDON_ROOT .. "/" .. path, "rb")
            if f then
                local n = 0
                for line in f:lines() do
                    n = n + 1
                    if line:find("GetRealmName%s*%(") or line:find("GetNormalizedRealmName%s*%(") then
                        offenders[#offenders + 1] = path .. ":" .. n
                    end
                end
                f:close()
            end
        end
    end
    p:close()
    H.assertTrue(files > 50, "the file list came back")
    H.assertEq(table.concat(offenders, ", "), "", "use ns.RealmName() or ns.NormalizedRealmName()")
end

-- On Forever UnitName and UnitFullName drop the surname: the player's name
-- and key come from ns.PlayerName / ns.CurrentCharacterKey only.
function tests.noOtherFileNamesThePlayerByUnitName()
    local p = assert(io.popen('git -C "' .. H.ADDON_ROOT .. '" ls-files "*.lua"'))
    local offenders, files = {}, 0
    for path in p:lines() do
        if not (path:match("^tests/") or path:match("^dev/") or path == "Shared/Utils.lua") then
            files = files + 1
            local f = io.open(H.ADDON_ROOT .. "/" .. path, "rb")
            if f then
                local n = 0
                for line in f:lines() do
                    n = n + 1
                    if line:find('UnitName%(%s*"player"%s*%)') or line:find("UnitFullName%(") then
                        offenders[#offenders + 1] = path .. ":" .. n
                    end
                end
                f:close()
            end
        end
    end
    p:close()
    H.assertTrue(files > 50, "the file list came back")
    H.assertEq(table.concat(offenders, ", "), "", "use ns.PlayerName() or ns.CurrentCharacterKey()")
end

local pass, fail, failures = H.runSuite("CharKeys", tests)
return { pass = pass, fail = fail, failures = failures }
