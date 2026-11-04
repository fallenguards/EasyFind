-- A kind of place's nearest rows (MapSearch/Search/Results.lua
-- GetCategoryResultsForUI, the "ah" boost in the bar and the GPS fields):
-- "ah" from Tirisfal on a Horde character listed Ironforge's auction house
-- above Undercity's (2026-11-03). The folded row took its first listed spot
-- and the other rows stood alphabetical. Now each folded place stands at
-- its nearest spot outside an enemy capital, and the rest go nearest first
-- on the player's continent, then elsewhere, then in enemy capitals.
local H = require("Harness")

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function Cut(src, from, to)
    local s = assert(src:find(from, 1, true), from)
    local e = assert(src:find(to, s, true), to)
    return src:sub(s, e - 1)
end

-- World spots by map: continent and the map's middle.
local WORLD = {
    [1420] = { 0, 2000, 300 },     -- Tirisfal Glades
    [1458] = { 0, 1600, 240 },     -- Undercity
    [1455] = { 0, -4900, -1000 },  -- Ironforge
    [1453] = { 0, -8800, 600 },    -- Stormwind City
    [1434] = { 0, -14400, 450 },   -- Stranglethorn Vale: Booty Bay
    [1454] = { 1, 1600, -4400 },   -- Orgrimmar
}

local function Load(faction, playerMap)
    local src = Read("MapSearch/Search/Results.lua")
    local chunk = table.concat({
        "local ns, MapSearch, Search, EasyFind = ns, MapSearch, Search, EasyFind",
        "local GetBestMapForUnit = C_Map.GetBestMapForUnit",
        "local mmin, tsort, wipe = math.min, table.sort, wipe",
        "local reuseUIScored, reuseUICategoryRows, reuseUICategoryData = {}, {}, {}",
        "local GetNameLower = function(r) return r.name and r.name:lower() end",
        "local GetCategoryIcon = function() return 0 end",
        Cut(src, "-- Equal matches nearest first: the player's spot", "-- Same-named places fold into one row"),
        Cut(src, "-- A bar row's data from a scored map row.", "-- Each part's ms over the bar's map passes"),
        Cut(src, "local function CategoryCovered", "-- A query's place rows as the search bar ranks them"),
        "return MapSearch, TakeDistances, reuseUIScored, Search",
    }, "\n")
    local function vec(x, y) return { x = x, y = y, GetXY = function(v) return v.x, v.y end } end
    local env = setmetatable({
        ns = { Caps = { era = true }, MapSearchData = { CATEGORIES = { auctionhouse = { keywords = { "auction" } } } } },
        MapSearch = {}, Search = {}, EasyFind = { db = {} },
        wipe = function(t) for k in pairs(t) do t[k] = nil end return t end,
        CreateVector2D = vec,
        UnitFactionGroup = function() return faction end,
        C_Map = {
            GetBestMapForUnit = function() return playerMap end,
            GetPlayerMapPosition = function() return vec(0.5, 0.5) end,
            GetWorldPosFromMapPos = function(m, v)
                local w = WORLD[m]
                if not w then return nil end
                return w[1], vec(w[2] + (v.x - 0.5) * 10, w[3] + (v.y - 0.5) * 10)
            end,
        },
    }, { __index = _G })
    local MapSearch, TakeDistances, stash, Search = assert(load(chunk, "=Results.lua category rows", "t", env))()
    return MapSearch, TakeDistances, stash, Search
end

local function Spot(name, mapID, folded)
    return { name = name, category = "auctionhouse", isStatic = folded or nil, mapID = mapID, x = 0.5, y = 0.5 }
end

-- The score pass's rows for "ah": every auction house folded under the
-- first listed (Ironforge's), then the auctioneers alphabetical.
local function Scored(stash, TakeDistances, Search)
    local ironforge = Spot("Auction House", 1455, true)
    ironforge.allInstances = { ironforge, Spot("Auction House", 1453, true), Spot("Auction House", 1458, true),
                               Spot("Auction House", 1434, true), Spot("Auction House", 1454, true) }
    local rows = { ironforge, Spot("Auctioneer Fitch", 1455), Spot("Auctioneer Grizzlin", 1434),
                   Spot("Auctioneer Thathung", 1454) }
    for i = 1, #rows do stash[i] = rows[i] end
    TakeDistances(stash)
    Search.uiScoredFor, Search.uiScoredCategory, Search.uiScoredMapID = "ah", "auctionhouse", 1420
end

local function Names(rows)
    local out = {}
    for i = 1, rows and #rows or 0 do out[i] = rows[i].name .. "@" .. tostring(rows[i].mapID) end
    return table.concat(out, ", ")
end

local tests = {}

function tests.horde_undercityFirst_enemyCapitalsLast()
    local MapSearch, TakeDistances, stash, Search = Load("Horde", 1420)
    Scored(stash, TakeDistances, Search)
    local rows = MapSearch:GetCategoryResultsForUI("auctionhouse", 4, nil, false, "ah")
    H.assertEq(Names(rows), "Auction House@1458, Auctioneer Grizzlin@1434, Auctioneer Thathung@1454, Auctioneer Fitch@1455",
        "Undercity's, Booty Bay on this continent, Orgrimmar across the sea, Ironforge last")
    H.assertTrue(math.abs(rows[1].nearYards - math.sqrt(400 ^ 2 + 60 ^ 2)) < 1, "yards to Undercity's: " .. rows[1].nearYards)
end

function tests.alliance_ironforgeFirst_orgrimmarLast()
    local MapSearch, TakeDistances, stash, Search = Load("Alliance", 1420)
    Scored(stash, TakeDistances, Search)
    local rows = MapSearch:GetCategoryResultsForUI("auctionhouse", 3, nil, false, "ah")
    H.assertEq(Names(rows), "Auction House@1455, Auctioneer Fitch@1455, Auctioneer Grizzlin@1434")
end

function tests.inTheCity_itsOwnFirst()
    local MapSearch, TakeDistances, stash, Search = Load("Horde", 1458)
    Scored(stash, TakeDistances, Search)
    local rows = MapSearch:GetCategoryResultsForUI("auctionhouse", 3, nil, false, "ah")
    H.assertEq(rows[1].name .. "@" .. rows[1].mapID, "Auction House@1458")
end

-- With no pass of its own to read, the bar's rows for the kind's word.
function tests.itsOwnPass_theSameOrder()
    local MapSearch, TakeDistances = Load("Horde", 1420)
    local function D(name, mapID, near) return { name = name, category = "auctionhouse", mapID = mapID, coordMapID = mapID, mapNear = near } end
    local rows = { { data = D("Auctioneer Fitch", 1455, 6900 ^ 2) }, { data = D("Auction House", 1458, 400 ^ 2) },
                   { data = D("Auctioneer Grizzlin", 1434, 16400 ^ 2) }, { data = D("Auctioneer Thathung", 1454, math.huge) } }
    -- The pass reads the player's spot and faction, as SearchPOIs does.
    function MapSearch:SearchForUI() TakeDistances({}) return rows end
    H.assertEq(Names(MapSearch:GetCategoryResultsForUI("auctionhouse", 3, nil, false, "ah")),
        "Auction House@1458, Auctioneer Grizzlin@1434, Auctioneer Thathung@1454")
end

local pass, fail, failures = H.runSuite("CategoryRowsFaction", tests)
return { pass = pass, fail = fail, failures = failures }
