-- Alt-click for directions: a spot on the world map or a pin on it (the
-- game's own waypoint pin says so in its tooltip), or a map pin linked in
-- chat. Read from the mouse events and after the client's own handling,
-- never inside its click: a hook there would run the rest of the pin's
-- click in our name.
local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns then return end

local GPS = ns.GPS
if not GPS then return end
local L, Utils = ns.L, ns.Utils
local sformat = string.format

local MapClick = {}
ns.GPSMapClick = MapClick

-- A spot's name: the map's, then where on it.
function MapClick.PointName(mapID, x, y)
    local info = C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
    return sformat(L["GPS_MAP_POINT_FMT"], info and info.name or ("#" .. mapID), x * 100, y * 100)
end

-- The map pin under the cursor, if any: a frame the world map placed.
local function PinUnder(map)
    local foci = GetMouseFoci and GetMouseFoci() or { GetMouseFocus and GetMouseFocus() }
    for _, f in ipairs(foci) do
        if type(f) == "table" and f.owningMap == map and f.GetPosition then return f end
    end
end

local function PinName(pin)
    if not pin then return nil end
    local info = pin.poiInfo or pin.areaPoiInfo or pin.taxiNodeData
    local name = pin.name or (info and info.name)
    return type(name) == "string" and name ~= "" and name or nil
end

local function Go(mapID, x, y, name)
    if not (mapID and x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1) then return end
    GPS:NavigateTo({ name = name or MapClick.PointName(mapID, x, y), mapID = mapID, x = x, y = y })
end

-- A press with Alt over the map: the spot (a pin's own, under the cursor)
-- taken on the press, the route started on the release; the client's own
-- zoom into a zone on that click is put back.
local pressed
local watch = CreateFrame("Frame")
watch:SetScript("OnEvent", function(_, event, button)
    local map = WorldMapFrame
    if event == "GLOBAL_MOUSE_DOWN" then
        pressed = nil
        if button ~= "LeftButton" or not IsAltKeyDown() then return end
        if not (map:IsVisible() and map.ScrollContainer and map.ScrollContainer:IsMouseOver()) then return end
        local pin = PinUnder(map)
        local x, y
        if pin then x, y = pin:GetPosition() end
        if not x then x, y = map:GetNormalizedCursorPosition() end
        pressed = { mapID = map:GetMapID(), x = x, y = y, name = PinName(pin) }
    elseif pressed then
        local p = pressed
        pressed = nil
        Utils.SafeAfter(0, function()
            if map:IsShown() and map:GetMapID() ~= p.mapID then map:SetMapID(p.mapID) end
        end)
        Go(p.mapID, p.x, p.y, p.name)
    end
end)

function MapClick.Install()
    local map = WorldMapFrame
    if MapClick.installed or not map then return end
    MapClick.installed = true
    -- The mouse watched only while the map is up.
    map:HookScript("OnShow", function()
        Utils.RegisterEventIfValid(watch, "GLOBAL_MOUSE_DOWN")
        Utils.RegisterEventIfValid(watch, "GLOBAL_MOUSE_UP")
    end)
    map:HookScript("OnHide", function()
        pressed = nil
        watch:UnregisterAllEvents()
    end)
    if map:IsShown() then map:GetScript("OnShow")(map) end

    -- The game's waypoint pin: its tooltip names the Alt-click beside its own.
    GameTooltip:HookScript("OnShow", function(tip)
        local owner = tip:GetOwner()
        if not (owner and owner.owningMap == map and owner.CopySlashCommandToClipboard) then return end
        local c = GREEN_FONT_COLOR
        tip:AddLine(L["GPS_ALT_CLICK_PIN"], c and c.r or 0.1, c and c.g or 1, c and c.b or 0.1)
        tip:Show()
    end)

    -- A map pin linked in chat, Alt-clicked: after the client's own handling.
    hooksecurefunc("SetItemRef", function(link, _, button)
        if button ~= "LeftButton" or not IsAltKeyDown() or type(link) ~= "string" then return end
        local mapID, x, y = link:match("^worldmap:(%d+):(%d+):(%d+)")
        if mapID then Go(tonumber(mapID), tonumber(x) / 10000, tonumber(y) / 10000) end
    end)
end

-- The world map may load after us: at login or when it arrives.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" and name ~= "Blizzard_WorldMap" then return end
    MapClick.Install()
    if MapClick.installed then self:UnregisterAllEvents() end
end)
