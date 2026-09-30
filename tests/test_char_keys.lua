-- Tests for the per-character key in Shared/Utils.lua: Forever's surnames
-- (UnitName returns "Test", "Addons"), the copy of first-name slots to the
-- full name's key, and a scan that keeps every other file off UnitName.
local H = require("Harness")

local function loadKeyCode(client)
    local ns = {}
    H.loadCharKeyCode({
        pairs = pairs, ipairs = ipairs, type = type, next = next,
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
