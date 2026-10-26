-- Mounts kept as items (2026-10-26, TBC: "mount" never found the mounts in
-- the bags). Before Wrath a mount is an item: TBC files it under the Mount
-- subclass (15/5), Era as Junk (15/0, its own list). A mount item answers
-- "mount", and with no mount journal the word loads the bags.
local H = require("Harness")

local function Engine(mounts)
    local env = H.newEnv()
    local ns = H.newNs(env)
    ns.Caps = { mounts = mounts }
    H.loadModule("Shared/SearchText.lua", env, ns)
    local E = H.loadModule("Search/Engine.lua", env, ns)
    local requested = {}
    ns.Database.IsDynamicProviderLoaded = function() return false end
    ns.Database.RequestDynamicProviderLoaded = function(_, key, onDone)
        requested[#requested + 1] = key
        if onDone then onDone(true) end
        return true
    end
    ns.Database.NormalizeSearchQuery = function(_, query) return query end
    return E, requested
end

local function Kinds(eraList)
    local f = assert(io.open(H.ADDON_ROOT .. "/Database/Main.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("-- A mount kept as an item", 1, true))
    local a = assert(src:find("function Stored.AddItemKindWords(kw, itemID)", s, true))
    local _, e = src:find("\nend\r?\n", a)
    local items = { [5656] = { 15, 5 }, [6948] = { 15, 0 } }
    local env = setmetatable({
        Stored = {}, ns = { ERA_MOUNT_ITEMS = eraList }, slower = string.lower,
        MOUNT = "Mount", MOUNTS = "Mounts",
        C_Item = { GetItemInfoInstant = function(id)
            local c = items[id]
            if c then return id, "", "", "", 0, c[1], c[2] end
        end },
    }, { __index = _G })
    env._G = env
    assert(load(src:sub(s, e), "=Main.lua mount items", "t", env))()
    return env.Stored
end

local tests = {}

function tests.noJournal_mountLoadsTheBags()
    local E, requested = Engine(false)
    E:RequestProviders(E:BuildContext("mount", nil, { bags = true }), function() end, 50)
    local asked = false
    for _, key in ipairs(requested) do asked = asked or key == "bags" end
    H.assertTrue(asked, "the bags, whatever else matched")
end

function tests.withAJournal_theBagsWaitAsBefore()
    local E, requested = Engine(true)
    E:RequestProviders(E:BuildContext("mount", nil, { bags = true }), function() end, 50)
    for _, key in ipairs(requested) do H.assertTrue(key ~= "bags", "the journal answers mount") end
end

function tests.tbc_theMountSubclass()
    local S = Kinds(nil)
    H.assertTrue(S.IsMountItem(5656), "Brown Horse Bridle, 15/5")
    H.assertFalse(S.IsMountItem(6948), "the Hearthstone, 15/0")
    local kw = { "brown horse bridle" }
    S.AddItemKindWords(kw, 5656)
    H.assertEq(kw[2], "mount")
    H.assertEq(kw[3], "mounts")
end

function tests.era_itsOwnList()
    local S = Kinds({ [5656] = true })
    H.assertTrue(S.IsMountItem(5656), "listed")
    H.assertFalse(S.IsMountItem(6948))
end

function tests.eraList_holdsTheMountsAndNoHearthstone()
    local env = H.newEnv()
    local ns = H.newNs(env)
    ns.Caps = { era = true }
    H.loadModule("Database/MountItems_Era.lua", env, ns)
    local list = ns.ERA_MOUNT_ITEMS
    H.assertTrue(list[5656] and list[1132] and list[18766] and list[13317], "bridle, horn, reins, the epics")
    H.assertNil(list[6948], "the Hearthstone")
end

local pass, fail, failures = H.runSuite("MountItems", tests)
return { pass = pass, fail = fail, failures = failures }
