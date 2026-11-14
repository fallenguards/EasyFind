-- Tests for Apps/Icons/IconSearch.lua (the @icons grid data layer) against the
-- real generated blob.

local H = require("Harness")

-- The client's answers for the few spells these tests name: { name, icon }.
-- 132369 ability_whirlwind, 135130 inv_spear_07, 135274 inv_sword_04.
local SPELLS = {
    [1680] = { "Whirlwind", 132369 },
    [19263] = { "Deterrence", 132369 },
    [19434] = { "Aimed Shot", 135130 },
    [20900] = { "Aimed Shot", 135130 },
    [2643] = { "Zzgamma Cut", 135274 },
    [133] = { "Zzalpha One", 135130 },
    [116] = { "Zzbeta Two", 135130 },
    [118] = { "Zzdelta", 1 },
}

-- A companion read in from scratch. deferNames: the name build waits for
-- the returned run function, as it waits for later frames in game.
local function freshIconSearch(deferNames)
    local env = H.newEnv()
    local ns = H.newNs(env)
    -- The whole module ships as the EasyFind_Icons companion, which reads
    -- the parent addon's ns via the EasyFind._ns handshake.
    env.EasyFind._ns = ns
    env.C_Spell = {
        GetSpellName = function(id) return SPELLS[id] and SPELLS[id][1] end,
        GetSpellTexture = function(id) return SPELLS[id] and SPELLS[id][2] end,
    }
    local pending
    if deferNames then
        ns.Utils.RunSliced = function(fn, onDone)
            pending = function() onDone(pcall(fn)) end
        end
    end
    H.loadModule("Apps/Icons/Data.lua", env, ns)
    local spellIDs = ns.ICON_SPELL_IDS
    return H.loadModule("Apps/Icons/IconSearch.lua", env, ns), function() pending() end, spellIDs
end

local IconSearch, _, SPELL_IDS = freshIconSearch()

local tests = {}
local scratch = {}

local function namesOf(n)
    local names = {}
    for i = 1, n do names[i] = IconSearch:GetIcon(scratch[i]) end
    table.sort(names)
    return table.concat(names, " ")
end

function tests.index_buildsFromBlob()
    local total = IconSearch:GetTotal()
    H.assertTrue(total > 30000, "index suspiciously small")
    local name, id = IconSearch:GetIcon(1)
    H.assertEq(type(name), "string")
    H.assertEq(type(id), "number")
end

function tests.filter_emptyQueryIsEverything()
    local n = IconSearch:Filter("", scratch)
    H.assertEq(n, IconSearch:GetTotal())
end

function tests.filter_findsKnownIcon()
    local n = IconSearch:Filter("inv_sword_04", scratch)
    H.assertTrue(n >= 1, "known icon must match")
    local found
    for i = 1, n do
        local name, id = IconSearch:GetIcon(scratch[i])
        if name == "inv_sword_04" then found = id end
    end
    H.assertEq(found, 135274)
end

function tests.filter_pluralSweepsSingular()
    -- GitHub #22 review: "swords" must sweep the _sword_ family even though
    -- icon file names are singular.
    local plural = IconSearch:Filter("swords", scratch)
    H.assertTrue(plural > 50, "plural query must sweep the family, got " .. plural)
    local singular = IconSearch:Filter("sword", scratch)
    H.assertTrue(singular >= plural, "singular is the wider set")
end

function tests.filter_multiWordIsAnd()
    local n = IconSearch:Filter("inv sword", scratch)
    H.assertTrue(n > 0)
    for i = 1, n do
        local name = IconSearch:GetIcon(scratch[i])
        H.assertTrue(name:find("inv", 1, true) and name:find("sword", 1, true),
            "every match carries both words: " .. name)
    end
end

function tests.filter_garbageFindsNothing()
    H.assertEq(IconSearch:Filter("zzqxjv_no_such_icon", scratch), 0)
end

function tests.filter_minusExcludes()
    local all = IconSearch:Filter("sword", scratch)
    local kept = IconSearch:Filter("sword -inv", scratch)
    H.assertTrue(kept > 0 and kept < all, "exclusion must remove the inv_ swords")
    for i = 1, kept do
        local name = IconSearch:GetIcon(scratch[i])
        H.assertTrue(not name:find("inv", 1, true), "excluded term leaked: " .. name)
    end
end

function tests.filter_slashAlternates()
    local swords = IconSearch:Filter("inv_sword_", scratch)
    local axes = IconSearch:Filter("inv_axe_", scratch)
    local both = IconSearch:Filter("inv_sword_/inv_axe_", scratch)
    H.assertEq(both, swords + axes)
end

function tests.filter_commaBranches()
    local swords = IconSearch:Filter("inv_sword_", scratch)
    local axes = IconSearch:Filter("inv_axe_", scratch)
    H.assertEq(IconSearch:Filter("inv_sword_, inv_axe_", scratch), swords + axes)
end

function tests.filter_wildcardWord()
    local n = IconSearch:Filter("inv_sword_*", scratch)
    H.assertTrue(n > 5, "wildcard must sweep the sword files, got " .. n)
    for i = 1, n do
        local name = IconSearch:GetIcon(scratch[i])
        H.assertTrue(name:match("^inv_sword_") ~= nil, "wildcard miss: " .. name)
    end
    -- ? = exactly one character
    local q = IconSearch:Filter("inv_sword_0?", scratch)
    H.assertTrue(q > 0 and q <= n)
end

function tests.filter_bareNumberIsFileDataID()
    local n = IconSearch:Filter("135274", scratch)
    H.assertTrue(n >= 1)
    local name, id = IconSearch:GetIcon(scratch[1])
    H.assertEq(id, 135274)
    H.assertEq(name, "inv_sword_04")
end

function tests.filter_idPrefixNarrows()
    -- Typing digits sweeps every FileDataID starting with them, and each
    -- further digit narrows the sweep (never widens it).
    local n13 = IconSearch:Filter("#13", scratch)
    local n135 = IconSearch:Filter("#135", scratch)
    local n1352 = IconSearch:Filter("#1352", scratch)
    H.assertTrue(n13 > n135 and n135 > n1352 and n1352 >= 1,
        ("expected narrowing, got %d -> %d -> %d"):format(n13, n135, n1352))
    for i = 1, n1352 do
        local _, id = IconSearch:GetIcon(scratch[i])
        H.assertTrue(tostring(id):sub(1, 4) == "1352", "non-prefix id: " .. id)
    end
end

function tests.filter_hashExactListsFirst()
    local n = IconSearch:Filter("#135274", scratch)
    H.assertTrue(n >= 1)
    local _, id = IconSearch:GetIcon(scratch[1])
    H.assertEq(id, 135274)
    -- spell:/item:/achievement: need live APIs; absent here they degrade to 0
    H.assertEq(IconSearch:Filter("spell:133", scratch), 0)
end

function tests.index_idsAscend()
    -- An icon is found by its ID by halving the list.
    local last = 0
    for i = 1, IconSearch:GetTotal() do
        local _, id = IconSearch:GetIcon(i)
        H.assertTrue(id > last, "icon IDs must ascend, broke at " .. id)
        last = id
    end
end

function tests.filter_aNewQueryForgetsTheLast()
    local three = IconSearch:Filter("inv sword 2h", scratch)
    H.assertTrue(three > 0)
    H.assertEq(IconSearch:Filter("zzqxjv", scratch), 0)
    H.assertEq(IconSearch:Filter("inv sword 2h zzqxjv, zzqxjv", scratch), 0)
end

function tests.spellList_namesEveryClassAbility()
    local ids, id = {}, 0
    for gap in SPELL_IDS:gmatch("%d+") do
        H.assertTrue(tonumber(gap) > 0, "IDs must ascend")
        id = id + tonumber(gap)
        ids[id] = true
    end
    -- Deterrence, Fireball, Aimed Shot, Frostbolt, Whirlwind.
    for _, spell in ipairs({ 19263, 133, 19434, 116, 1680 }) do
        H.assertTrue(ids[spell], "spell missing from the list: " .. spell)
    end
end

function tests.spellName_findsItsIcon()
    H.assertEq(IconSearch:Filter("deterr", scratch), 1)
    H.assertEq(namesOf(1), "ability_whirlwind")
    -- One by its file name, one by the spell wearing it.
    H.assertEq(IconSearch:Filter("Aimed Shot", scratch), 2)
    H.assertEq(namesOf(2), "ability_hunter_aimedshot inv_spear_07")
end

function tests.spellName_wordsMeetInOneName()
    H.assertEq(IconSearch:Filter("zzalpha one", scratch), 1)
    H.assertEq(IconSearch:Filter("zzalpha two", scratch), 0)
end

function tests.spellName_joinsTheFileNameMatches()
    local files = IconSearch:Filter("inv_sword_", scratch)
    H.assertEq(IconSearch:Filter("inv_sword_, zzalpha", scratch), files + 1)
    -- Its own icon is among them already: listed once.
    H.assertEq(IconSearch:Filter("inv_sword_, zzgamma", scratch), files)
end

function tests.spellName_aNegatedFileNameKeepsItsIconOut()
    H.assertEq(IconSearch:Filter("zzgamma -axe", scratch), 1)
    H.assertEq(IconSearch:Filter("zzgamma -sword", scratch), 0)
    H.assertEq(IconSearch:Filter("zzgamma -cut", scratch), 0)
end

function tests.spellName_wildcardSpansTheWholeName()
    H.assertEq(IconSearch:Filter("zzgamma*", scratch), 1)
    H.assertEq(IconSearch:Filter("zzgamm?", scratch), 0)
end

function tests.spellName_anIconOutsideTheListIsSkipped()
    H.assertEq(IconSearch:Filter("zzdelta", scratch), 0)
end

function tests.spellName_outlivesTheMemoryRelease()
    IconSearch:ReleaseMemory()
    H.assertEq(IconSearch:Filter("deterr", scratch), 1)
    H.assertEq(namesOf(1), "ability_whirlwind")
end

function tests.spellNames_listTheMatchFirst()
    H.assertEq(IconSearch:Filter("deterr", scratch), 1)
    H.assertEq(IconSearch:GetSpellNames(scratch[1], 3), "Deterrence, Whirlwind")
    H.assertEq(IconSearch:GetSpellNames(scratch[1], 1), "Deterrence, ...")
    H.assertEq(IconSearch:Filter("ability_whirlwind", scratch), 1)
    H.assertEq(IconSearch:GetSpellNames(scratch[1], 3), "Whirlwind, Deterrence")
    -- Ranks sharing a name and an icon are one entry.
    H.assertEq(IconSearch:Filter("inv_spear_07", scratch), 1)
    H.assertEq(IconSearch:GetSpellNames(scratch[1], 1), "Zzbeta Two, ...")
    H.assertEq(IconSearch:Filter("inv_sword_05", scratch), 1)
    H.assertEq(IconSearch:GetSpellNames(scratch[1], 3), nil)
end

function tests.spellNames_arriveLater_andTellTheirListeners()
    local late, runNames = freshIconSearch(true)
    local told = 0
    late:OnNamesReady(function() told = told + 1 end)
    H.assertEq(late:Filter("deterr", scratch), 0)
    H.assertEq(late:NamesReady(), false)
    runNames()
    H.assertEq(told, 1)
    H.assertEq(late:NamesReady(), true)
    H.assertEq(late:Filter("deterr", scratch), 1)
end

function tests.spellNames_builtInsideTheFirstFilter_tellNobody()
    local now = freshIconSearch()
    local told = 0
    now:OnNamesReady(function() told = told + 1 end)
    H.assertEq(now:Filter("deterr", scratch), 1)
    H.assertEq(told, 0)
end

local pass, fail, failures = H.runSuite("IconSearch", tests)
return { pass = pass, fail = fail, failures = failures }
