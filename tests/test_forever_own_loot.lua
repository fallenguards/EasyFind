-- Forever gives the classic dungeons' bosses drops of its own: items no
-- classic world database holds. The loot table was built from those
-- databases alone, so "wc loot" listed Skum without Skum's Bucket
-- (2026-11-23). The generator now also reads the bosses' drop tables.
-- And a drop of Forever's own carried no stat kind for @upgrades: its row
-- holds the stat types as one list, the reader wanted a column each.
local H = require("Harness")

local OWN = 200000   -- item ids above every classic one

local function Read(file)
    local f = assert(io.open(H.ADDON_ROOT .. "/Database/" .. file, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end

local function Bosses()
    local loot = Read("Loot_Forever.lua")
    loot = loot:sub(1, (loot:find("ns.STATIC_LOOT_NAMES", 1, true)))
    local out = {}
    for inst, boss, items in loot:gmatch('{ inst = (%d+), enc = %d+, boss = "([^"]*)", items = {([^}]*)}') do
        local ids = {}
        for id in items:gmatch("%d+") do ids[#ids + 1] = tonumber(id) end
        out[#out + 1] = { inst = tonumber(inst), boss = boss, items = ids }
    end
    return out
end

local tests = {}

function tests.skum_dropsHisBucket()
    local found
    for _, b in ipairs(Bosses()) do
        if b.inst == 43 and b.boss == "Skum" then
            for _, id in ipairs(b.items) do found = found or id == 273137 end
        end
    end
    H.assertTrue(found == true, "Skum's Bucket (273137) is among Skum's drops in Wailing Caverns")
    H.assertTrue(Read("Loot_Forever.lua"):find('[273137] = "Skum\'s Bucket"', 1, true) ~= nil, "and it has its name")
end

-- A table rebuilt without the bosses' own drop tables fails here.
function tests.theClassicDungeonsBosses_carryForeversOwnDrops()
    local bosses, slots = 0, 0
    for _, b in ipairs(Bosses()) do
        if b.inst < 2700 then
            local own = 0
            for _, id in ipairs(b.items) do if id > OWN then own = own + 1 end end
            slots = slots + own
            if own > 0 then bosses = bosses + 1 end
        end
    end
    H.assertTrue(bosses >= 70, "classic dungeon bosses with a drop of Forever's own: " .. bosses .. " (80 on 2026-11-23)")
    H.assertTrue(slots >= 115, "such drops: " .. slots .. " (131 on 2026-11-23)")
end

function tests.foreversOwnDrops_carryTheirStatKinds()
    local own, kinded, bucket = 0, 0, nil
    for id, packed in Read("LootGear_Forever.lua"):gmatch("%[(%d+)%] = (%d+),") do
        id, packed = tonumber(id), tonumber(packed)
        if id > OWN then
            own = own + 1
            local kinds = math.floor(packed / 32768) % 128
            if kinds > 0 then kinded = kinded + 1 end
            if id == 273137 then bucket = kinds end
        end
    end
    H.assertTrue(bucket ~= nil and bucket > 0, "Skum's Bucket has a stat kind (its row holds them as a list)")
    H.assertTrue(own >= 140, "worn drops of Forever's own: " .. own .. " (159 on 2026-11-23)")
    H.assertTrue(kinded * 10 >= own * 7, "most carry a stat kind: " .. kinded .. " of " .. own)
end

local pass, fail, failures = H.runSuite("ForeverOwnLoot", tests)
return { pass = pass, fail = fail, failures = failures }
