-- Same-named creatures are separate map rows (MapSearch/Search/Results.lua
-- GetPOIDuplicateKey): five NPCs named Thrall, each at its own place.
-- Folded into one row, the row's zone was whichever came first, and a
-- hover or click drew every Thrall on the map at once (four across the
-- Caverns of Time). Same-named places (auction houses) still fold.
local H = require("Harness")

local function Key()
    local f = assert(io.open(H.ADDON_ROOT .. "/MapSearch/Search/Results.lua", "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    local s = assert(src:find("local function GetPOIDuplicateKey", 1, true), "GetPOIDuplicateKey")
    local e = select(2, assert(src:find("\nend\n", s, true)))
    return assert(load(src:sub(s, e) .. "\nreturn GetPOIDuplicateKey", "=Results.lua key", "t", {}))()
end

local tests = {}

function tests.twoCreaturesOfOneNameAreTwoRows()
    local key = Key()
    local hyjal = { name = "Thrall", category = "npc", npcID = 17852 }
    local blasted = { name = "Thrall", category = "npc", npcID = 4949 }
    H.assertTrue(key(hyjal) ~= key(blasted))
end

function tests.oneCreatureSeenTwiceIsOneRow()
    local key = Key()
    H.assertEq(key({ name = "Thrall", category = "npc", npcID = 4949 }),
        key({ name = "Thrall", category = "npc", npcID = 4949 }))
end

function tests.placesOfOneKindStillFold()
    local key = Key()
    H.assertEq(key({ name = "Auction House", category = "auctionhouse", x = 0.1 }),
        key({ name = "Auction House", category = "auctionhouse", x = 0.9 }))
end

local pass, fail, failures = H.runSuite("CreatureRowsApart", tests)
return { pass = pass, fail = fail, failures = failures }
