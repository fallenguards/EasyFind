-- An item row says how many of its item are held (2026-11-19): the
-- character played counted live, the others summed from their last bag
-- and bank scans, on the row's subtext and never in the tooltip. Each alt
-- by name ran past the row's width (2026-11-26): "Owned: 40, 28 on alts".
-- A stored-item row, which names its holders already, says nothing more.
local H = require("Harness")

local function World(counts, live)
    local env = H.newEnv()
    env._G = env
    local ns = H.newNs(env)
    ns.Utils.sformat = ns.Utils.sformat or string.format
    ns.L.SUBTEXT_OWNED_FMT = "Owned: %s"
    ns.L.SUBTEXT_ON_ALTS_FMT = "%d on alts"
    ns.CurrentCharacterKey = function() return "Thrall-Realm" end
    ns.PlayerName = function() return "Thrall" end
    local state = { stamp = 1, asked = 0 }
    ns.StoredItemCounts = function(itemID)
        state.asked = state.asked + 1
        return counts[itemID], state.stamp
    end
    env.C_Item = { GetItemCount = function(itemID, withBank)
        local c = live[itemID]
        return c and (withBank and c[1] + c[2] or c[1]) or 0
    end }
    H.loadModule("Search/Results/RowText.lua", env, ns)
    return ns.ResultText, state, counts, live
end

local tests = {}

function tests.anItemRow_saysItsOwnCountLive_andTheAltsTogether()
    local Text = World({
        [2589] = { ["Thrall-Realm"] = { name = "Thrall", bags = 99, bank = 0 },
                   ["Jaina-Realm"] = { name = "Jaina", bags = 4, bank = 8 },
                   ["Bob-Realm"] = { name = "Bob", bags = 0, bank = 3 },
                   ["Old-Realm"] = { name = "Old", bags = 0, bank = 0 } },
    }, { [2589] = { 5, 20 } })
    H.assertEq(Text:GetShownSubtext({ category = "Item", itemID = 2589 }), "Item, Owned: 25, 15 on alts",
        "bags and bank, his own count the game's and not the old scan's")
end

function tests.onlyAlts_orOnlyThePlayedOne_orNobody()
    local Text = World({
        [1] = { ["Jaina-Realm"] = { name = "Jaina", bags = 2, bank = 0 } },
    }, { [2] = { 7, 0 } })
    H.assertEq(Text:GetShownSubtext({ category = "Item", itemID = 1 }), "Item, Owned: 2 on alts")
    H.assertEq(Text:GetShownSubtext({ category = "Loot", itemID = 2 }), "Loot, Owned: 7")
    H.assertEq(Text:GetShownSubtext({ category = "Item", itemID = 3 }), "Item", "held by no one: nothing added")
    H.assertEq(Text:GetShownSubtext({ category = "Ability", spellID = 5 }), "Ability", "not an item row")
end

-- A recipe's reagent row counts the player's own already: the alts alone.
function tests.aRowCountingItsOwn_addsTheAltsAlone()
    local Text = World({ [2592] = { ["Jaina-Realm"] = { name = "Jaina", bags = 28, bank = 0 } } }, { [2592] = { 40, 0 } })
    H.assertEq(Text:GetShownSubtext({ category = "Item", itemID = 2592, ownCounted = true, sourceNote = "Need 1, have 40" }),
        "Need 1, have 40, 28 on alts")
    H.assertEq(Text:GetShownSubtext({ category = "Item", itemID = 4, ownCounted = true, sourceNote = "Need 1, have 0" }),
        "Need 1, have 0", "no alt holds it")
end

function tests.aStoredItemRow_keepsItsOwnHolderLine()
    local Text, state = World({ [1] = { ["Jaina-Realm"] = { name = "Jaina", bags = 2, bank = 0 } } }, {})
    H.assertEq(Text:GetShownSubtext({ category = "Bank", itemID = 1, storedSubtext = "Bank: Jaina (2)" }), "Bank: Jaina (2)")
    H.assertEq(Text:GetShownSubtext({ category = "Bag", itemID = 1 }), "Bag")
    H.assertEq(state.asked, 0, "never asked")
end

function tests.theAltsPart_isBuiltOncePerScan()
    local Text, state, counts = World({ [1] = { ["Jaina-Realm"] = { name = "Jaina", bags = 2, bank = 0 } } }, {})
    local row = { category = "Item", itemID = 1 }
    H.assertEq(Text:GetShownSubtext(row), "Item, Owned: 2 on alts")
    counts[1]["Jaina-Realm"].bags = 9
    H.assertEq(Text:GetShownSubtext(row), "Item, Owned: 2 on alts", "the same scan: the count kept")
    state.stamp = 2
    H.assertEq(Text:GetShownSubtext(row), "Item, Owned: 9 on alts", "a new scan: read again")
end

local pass, fail, failures = H.runSuite("OwnedCounts", tests)
return { pass = pass, fail = fail, failures = failures }
