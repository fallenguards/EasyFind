-- Guardrail: the Era catalog holds no Season of Discovery item. The season
-- shares Era's client, so its 6,782 items sat in the catalog ("hand of rag"
-- listed 17182 and the season's 227683); classic_items.py keeps only items
-- the client had before the season (1.14.4.51829). 2026-11-03.
local H = require("Harness")

-- Era's own items past id 200000: the insignias of 1.14.4.
local ERA_HIGH_FIRST, ERA_HIGH_LAST = 209611, 209626

local function EraIDs()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Items/Data_Era.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local ids = {}
    for id in src:gmatch("\n[^\t\n]+\t(%d+)\t") do ids[tonumber(id)] = true end
    return ids
end

local tests = {}

function tests.noSeasonOfDiscoveryItem()
    local ids, seasonal = EraIDs(), {}
    for id in pairs(ids) do
        if id >= 200000 and not (id >= ERA_HIGH_FIRST and id <= ERA_HIGH_LAST) and #seasonal < 10 then
            seasonal[#seasonal + 1] = id
        end
    end
    H.assertEq(#seasonal, 0, "seasonal items: " .. table.concat(seasonal, ", "))
    H.assertNil(ids[227683], "the season's Sulfuras")
    H.assertNil(ids[230224], "the season's Thunderfury")
end

function tests.eraItemsStay()
    local ids = EraIDs()
    H.assertTrue(ids[17182], "Sulfuras, Hand of Ragnaros")
    H.assertTrue(ids[19019], "Thunderfury, Blessed Blade of the Windseeker")
    H.assertTrue(ids[ERA_HIGH_FIRST], "Insignia of the Alliance")
end

local pass, fail, failures = H.runSuite("ItemCatalogEra", tests)
return { pass = pass, fail = fail, failures = failures }
