-- A boss row: one deed a gesture, each named once in its hint (Alt and
-- Shift both said Loot, 2026-11-24): a click its journal, Alt its
-- dungeon's door on the map, Shift its loot. And its creature's own row
-- drops only while the boss row is in the same list (DropStoodInFor):
-- with bosses filtered out, or in the map's search, the creature stays.
local H = require("Harness")

local function Read(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function Slice(src, from, to)
    local a = assert(src:find(from, 1, true), from)
    local b = assert(src:find(to, a, true), to)
    return src:sub(a, b - 1)
end

-- The hint's boss branch, run on its own with the file's Hint and HINTS.
local function BossHint(journal, words)
    local src = Read("Search/Results/ActionHints.lua")
    local hint = Slice(src, "local function Hint(lead, clickTarget, ...)", "-- The rows of no kind")
    local hints = Slice(src, "    encounter        = Hint(", "    settings         = Hint(")
    local branch = Slice(src, '    if data.encounterID and data.category == "Boss" then',
        "    if data.settingVariable or data.bindingAction then")
    local env = setmetatable({
        V = { click = "Click", loot = "Loot", encounter = "Encounter Journal", pinOnMap = "Pin on Map" },
        ns = { Caps = { journal = journal },
               Extensions = { DecoratorHint = function() return words end } },
    }, { __index = _G })
    local chunk = assert(load(hint .. "\nlocal HINTS = {\n" .. hints .. "}\nreturn function(data)\n"
        .. branch .. "\nend", "hint", "t", env))
    return chunk()
end

local DOOR = { gpsDest = { mapID = 1415, x = 0.8, y = 0.3 } }
local function Boss(door)
    return { category = "Boss", encounterID = 448, name = "Herod", gpsDest = door and DOOR.gpsDest or nil }
end

local tests = {}

function tests.withTheJournalExtension_eachGestureItsOwnDeed()
    local hint = BossHint(false, { click = "DungeonJournal" })
    H.assertEq(hint(Boss(true)), "Click: DungeonJournal | Alt: Pin on Map | Shift: Loot")
end

function tests.anOlderJournalExtension_keepingAlt_neverNamesTheLootTwice()
    local hint = BossHint(false, { click = "DungeonJournal", alt = "Loot" })
    H.assertEq(hint(Boss(true)), "Click: DungeonJournal | Alt: Loot")
end

function tests.noJournal_theClickListsTheLoot_andShiftIsNotSaidAgain()
    local hint = BossHint(false, nil)
    H.assertEq(hint(Boss(true)), "Click: Loot | Alt: Pin on Map")
    H.assertEq(hint(Boss(false)), "Click: Loot", "no door known: no Alt")
end

function tests.theAdventureGuide_namesTheDoorWhereThereIsOne()
    local hint = BossHint(true, nil)
    H.assertEq(hint(Boss(true)), "Click: Encounter Journal | Alt: Pin on Map | Shift: Loot")
    H.assertEq(hint(Boss(false)), "Click: Encounter Journal | Shift: Loot")
end

-- The deeds behind the words: Shift the loot, Alt the door (an extension
-- asked first where the client has no journal), the click the journal.
function tests.theGestures_doWhatTheHintSays()
    local sel = Read("Search/Results/Handlers/Selection.lua")
    local at = assert(sel:find('    if data.category == "Boss" and data.encounterID then\n', 1, true))
    local shift = assert(sel:find('if ns.ResultGestures.Held() == "shift" then\n            EasyFind.API.ShowScope("loot", data.name)', at, true))
    local alt = assert(sel:find("if Handlers:IsSourceModifierHeld(data) then", at, true))
    H.assertTrue(shift < alt, "Shift first")
    H.assertTrue(sel:find('if not journal and ns.Extensions and ns.Extensions.DecoratorSelect(data, "alt") then return end', alt, true) ~= nil)
    H.assertTrue(sel:find("ns.MapSearch:HandleUISearchClick({ name = door.name", alt, true) ~= nil, "the door on the map")
    H.assertTrue(sel:find("isDungeonEntrance = true, entranceMapID = door.mapID, entranceX = door.x, entranceY = door.y", alt, true) ~= nil)
    H.assertNil(sel:find('local gesture = (Handlers:IsSourceModifierHeld(data) and "alt")', 1, true), "Alt no longer lists the loot")
end

-- ==== the stand-in pass =====================================================

local function Pass()
    local src = Read("Search/Query.lua")
    local body = Slice(src, "function MapRow.DropStoodInFor(combined)", "local function AppendFlat(")
    local env = setmetatable({ MapRow = {}, SCRATCH = { standIns = {} }, wipe = function(t)
        for k in pairs(t) do t[k] = nil end
        return t
    end }, { __index = _G })
    return assert(load(body .. "\nreturn MapRow.DropStoodInFor", "pass", "t", env))()
end

local function Names(combined)
    local out = {}
    for i, e in ipairs(combined) do out[i] = e.data.name .. "/" .. (e.data.category or "") end
    return table.concat(out, ", ")
end

local function Creature(name, model)
    return { data = { name = name, nameLower = name:lower(), npcID = 3975, displayID = model,
                      mapSearchResult = true, category = "npc" } }
end

local function BossRow(name, folded, model)
    return { data = { name = name, nameLower = folded or name:lower(), category = "Boss", encounterID = 1,
                      displayID = model } }
end

function tests.theCreature_dropsWhileItsBossRowIsListed()
    local drop = Pass()
    local list = { BossRow("Herod", nil, 2041), Creature("Herod", 2041), Creature("Bookie Herod", 1) }
    drop(list)
    H.assertEq(Names(list), "Herod/Boss, Bookie Herod/npc")
end

function tests.noBossRow_theCreatureStays()
    local drop = Pass()
    local list = { Creature("Herod", 2041), Creature("Bookie Herod", 1) }
    drop(list)
    H.assertEq(Names(list), "Herod/npc, Bookie Herod/npc", "bosses filtered out, or the map's search")
end

function tests.anotherCreatureOfTheSameName_stays()
    local drop = Pass()
    local list = { BossRow("Herod", nil, 2041), Creature("Herod", 999) }
    drop(list)
    H.assertEq(Names(list), "Herod/Boss, Herod/npc", "another model: another creature")
end

function tests.aFoldedBossName_stillMeetsItsCreature()
    local drop = Pass()
    local list = { BossRow("Gahz'ranka", "gahzranka", 15288), Creature("Gahz'ranka", 15288) }
    drop(list)
    H.assertEq(Names(list), "Gahz'ranka/Boss")
end

-- The pass runs where every source has joined and before the 15-row
-- head, so a boss lower in the list still stands in; no provider drops
-- a row for another provider's.
function tests.thePass_runsOnTheJoinedList()
    local src = Read("Search/Query.lua")
    local call = assert(src:find("    MapRow.DropStoodInFor(combined)\n\n    Mark(\"joins\")", 1, true))
    H.assertTrue(call < assert(src:find("local TOP_N = mapSplit and #combined or 15", 1, true)))
end

local pass, fail, failures = H.runSuite("BossRowGestures", tests)
return { pass = pass, fail = fail, failures = failures }
