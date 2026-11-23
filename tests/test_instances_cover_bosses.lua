-- Every instance the shipped boss data names has a row in that client's
-- instance list (2026-11-22: on Forever "rfd" found Razorfen Downs' six
-- bosses and no dungeon; the generator's hand table of entrances had left
-- the dungeon out, and a boss with no instance row reads as a raid's).
local H = require("Harness")

local function Read(file)
    local f = assert(io.open(H.ADDON_ROOT .. "/Database/" .. file, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

-- Instances with bosses and no row, each with why. A new one fails here.
local KNOWN = {
    Forever = {
        [2789] = "a Season of Discovery raid in the classic data", [2791] = "a Season of Discovery raid in the classic data",
        [2804] = "a Season of Discovery raid in the classic data", [2832] = "a Season of Discovery raid in the classic data",
    },
    Era = {
        [2789] = "a Season of Discovery raid: no such realm on this client's own list",
        [2791] = "a Season of Discovery raid: no such realm on this client's own list",
        [2804] = "a Season of Discovery raid: no such realm on this client's own list",
        [2832] = "a Season of Discovery raid: no such realm on this client's own list",
    },
    TBC = { [534] = "Hyjal Summit: its entrance is not in the list yet (found 2026-11-22, open)" },
}

local tests = {}

function tests.everyBossesInstance_isInTheClientsList()
    for _, client in ipairs({ "Forever", "Era", "TBC" }) do
        local have = {}
        for id in Read("Instances_" .. client .. ".lua"):gmatch("{ id = (%d+),") do have[tonumber(id)] = true end
        local missing, seen = {}, {}
        for id in Read("Loot_" .. client .. ".lua"):gmatch("%f[%w]inst = (%d+)") do
            id = tonumber(id)
            if not have[id] and not KNOWN[client][id] and not seen[id] then
                seen[id] = true
                missing[#missing + 1] = id
            end
        end
        table.sort(missing)
        H.assertEq(table.concat(missing, ", "), "", client .. ": bosses whose instance has no row")
        for id in pairs(KNOWN[client]) do
            H.assertFalse(have[id] == true, client .. " " .. id .. " has a row now: take it off the known list")
        end
    end
end

-- Open since Forever's launch, in its dungeon list with no ghost point: the
-- doors come from the world files' portals or, where the server spawns the
-- portal, the point the public guides agree on (2026-11-23).
function tests.foreversFiveNewDungeons_haveRowsAndBosses()
    local list, loot = Read("Instances_Forever.lua"), Read("Loot_Forever.lua")
    for id, name in pairs({ [2970] = "The Drowned City", [2974] = "Blackmaw Hold", [2994] = "Alcaz Prison",
                            [3001] = "The Shaper's Terrace", [3039] = "Krol'dok Stronghold" }) do
        H.assertTrue(list:find('{ id = ' .. id .. ', n = "' .. name .. '", raid = false,', 1, true) ~= nil, name .. ": a dungeon row")
        local bosses = 0
        for _ in loot:gmatch("inst = " .. id .. ", enc") do bosses = bosses + 1 end
        H.assertTrue(bosses >= 5, name .. ": its bosses (" .. bosses .. ")")
    end
end

function tests.razorfenDowns_isADungeonOnForever()
    local row = Read("Instances_Forever.lua"):match('{ id = 129, n = "Razorfen Downs", raid = (%a+),')
    H.assertEq(row, "false", "a dungeon: its bosses read Dungeon boss, and rfd finds the dungeon itself")
end

local pass, fail, failures = H.runSuite("InstancesCoverBosses", tests)
return { pass = pass, fail = fail, failures = failures }
