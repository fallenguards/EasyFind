-- A map result hovered in the search bar or a GPS box pins on the world
-- map only where it is (MapSearch/Preview.lua GetPreviewCoords). The bar's
-- rows (MapSearch/Search/Results.lua FillUIRow) kept x and y but not the
-- map they are on, and a row with no map counted as the viewed one: Thrall,
-- Thrawn Boltar and a basilisk all pinned on Silvermoon City.
local H = require("Harness")

local SILVERMOON, BLASTED_LANDS = 2393, 17

local function Read(path)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local function FillUIRow()
    local src = Read("MapSearch/Search/Results.lua")
    local s = assert(src:find("local function FillUIRow", 1, true), "FillUIRow")
    local e = assert(src:find("\nend\n", s, true), "its end")
    local env = setmetatable({
        nearOf = {}, FAR = math.huge,
        GetNameLower = function(r) return r.name:lower() end,
        GetCategoryIcon = function() return 1 end,
    }, { __index = _G })
    return assert(load(src:sub(s, e + 4) .. "return FillUIRow", "=Results.lua FillUIRow", "t", env))()
end

local function Preview(viewed)
    local MapSearch = {}
    local ns = {
        MapSearch = MapSearch, Utils = { pcall = pcall },
        MapUtils = { GetMapRectViaContinent = function() end, ResolveZoneForMap = function(m) return m end },
    }
    local env = setmetatable({
        C_Map = { GetMapInfo = function() return nil end, GetMapRectOnMap = function() end },
        WorldMapFrame = { GetMapID = function() return viewed end },
    }, { __index = _G })
    local src = Read("MapSearch/Preview.lua")
    local s = assert(src:find("function MapSearch:GetPreviewCoords", 1, true))
    local e = assert(src:find("\n\n\n", s, true), "its end")
    local head = assert(src:find("-- Resolve preview-able coordinates", 1, true))
    assert(load(src:sub(1, head - 1) .. src:sub(s, e), "=Preview.lua", "t", env))("EasyFind", ns)
    function MapSearch:FindEntranceOnMap() return nil end
    function MapSearch:FindNativePinByName() return nil end
    return MapSearch
end

local THRALL = { name = "Thrall", category = "npc", mapID = BLASTED_LANDS, coordMapID = BLASTED_LANDS, x = 0.66, y = 0.28 }

local tests = {}

function tests.aBarRowKnowsTheMapItsSpotIsOn()
    local d = {}
    FillUIRow()(d, THRALL, SILVERMOON, "thra")
    H.assertEq(d.coordMapID, BLASTED_LANDS)
    H.assertEq(d.mapID, BLASTED_LANDS)
end

function tests.hoveredOnAnotherMapItPinsNothing()
    local d = {}
    FillUIRow()(d, THRALL, SILVERMOON, "thra")
    H.assertNil(Preview(SILVERMOON):GetPreviewCoords(d), "Thrall lives in the Blasted Lands")
end

function tests.aRowNamingOnlyItsMapStaysThere()
    local row = { name = "Thrawn Boltar", category = "npc", mapID = BLASTED_LANDS, x = 0.5, y = 0.5 }
    H.assertNil(Preview(SILVERMOON):GetPreviewCoords(row))
end

function tests.onItsOwnMapItPins()
    local d = {}
    FillUIRow()(d, THRALL, SILVERMOON, "thra")
    local coords = Preview(BLASTED_LANDS):GetPreviewCoords(d)
    H.assertEq(coords and coords.x, 0.66)
end

local pass, fail, failures = H.runSuite("MapRowPreview", tests)
return { pass = pass, fail = fail, failures = failures }
