-- GPS: step by step directions to a zone or point of interest.
-- The route is per character (EasyFind.db.gpsChar); the map page and the pop-out both render it.

-- A companion: it lives in EasyFind's namespace, never its own.
local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns then return end
local L = ns.L
local Utils = ns.Utils

local GPS = {}
ns.GPS = GPS

local CreateFrame = CreateFrame
local UIParent = UIParent
local GameTooltip = GameTooltip
local GameTooltip_Hide = GameTooltip_Hide
local sformat = string.format
local mmax = math.max
local mfloor = math.floor
local unpack = unpack
local mpi = math.pi

local ARRIVE_YARDS = 40
local CROSS_ARRIVE_YARDS = 300   -- a crossing's far spot is where it drops you, give or take
local ROUTE_MAX_AGE = 2 * 60 * 60
local ARRIVED_LINGER = 20
local ROW_H = 22
local HIT_ROWS = 8            -- results shown under the pop-out's search box
-- Pop-out sizes on offer: the cog's radio rows. A nil height fits the steps.
local SIZE_WIDTHS = { { 240, "GPS_SIZE_NARROW" }, { 300, "GPS_SIZE_NORMAL" }, { 380, "GPS_SIZE_WIDE" }, { 460, "GPS_SIZE_WIDER" } }
local SIZE_HEIGHTS = { { nil, "GPS_SIZE_FIT" }, { 160, "GPS_SIZE_SHORT" }, { 240, "GPS_SIZE_MEDIUM" }, { 340, "GPS_SIZE_TALL" } }

local ticker
local surfaces = {}     -- every container that renders the route
local SampleGroundSpeed -- defined with the recorders at the end
local popoutFrame       -- built on first use by the pop-out below

local function DB()
    return EasyFind and EasyFind.db
end

-- This character's slot: the route in progress and whether its pop-out was open.
-- Style, dock slot and size are shared settings.
local function CharKey()
    return ns.CurrentCharacterKey()
end

local function CharDB()
    local db = DB()
    if not db then return nil end
    db.gpsChar = db.gpsChar or {}
    local key = CharKey()
    db.gpsChar[key] = db.gpsChar[key] or {}
    return db.gpsChar[key]
end

local function Route()
    local c = CharDB()
    return c and c.route
end
GPS.CurrentRoute = Route

-- Route model

local WorldPos   -- defined below with the position helpers

-- Not places: battlegrounds and arenas (orphan maps, and newer zones sharing
-- an orphan's name), dungeon insides, the world and the cosmos.
local orphanNames
local function IsOrphanName(name)
    if not orphanNames then
        orphanNames = {}
        local ok, kids = pcall(C_Map.GetMapChildrenInfo, 946, nil, true)
        if ok and kids then
            for i = 1, #kids do
                local k = kids[i]
                if k.mapType == Enum.UIMapType.Orphan and k.name then orphanNames[k.name:lower()] = true end
            end
        end
    end
    return name ~= nil and orphanNames[name:lower()] == true
end

function GPS:CanNavigate(data)
    if not data then return false end
    local mapID = data.zoneMapID or data.mapID
    if not mapID then return false end
    if not (data.isZone or (data.x ~= nil and data.y ~= nil)) then return false end
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
    if not (info and info.mapType and Enum and Enum.UIMapType) then return false end
    local mt = info.mapType
    if mt == Enum.UIMapType.Cosmic or mt == Enum.UIMapType.World or mt == Enum.UIMapType.Orphan then return false end
    if mt == Enum.UIMapType.Dungeon and not data.isDungeonEntrance then return false end
    -- A zone under another zone that shares a battleground's name is its newer
    -- edition (Warsong Gulch under the Barrens); Nazjatar, under the world map, stays.
    if data.isZone and IsOrphanName(info.name) then
        local parent = info.parentMapID and C_Map.GetMapInfo(info.parentMapID)
        if parent and parent.mapType == Enum.UIMapType.Zone then return false end
    end
    return WorldPos(mapID, data.x or 0.5, data.y or 0.5) ~= nil
end

-- Where a row points: a POI's coordinates, a zone's marker on the parent map, else
-- the zone's middle. A dungeon row names its continent: the door is in the entrance list.
local function EntranceOf(data)
    local list = ns.GetDungeonEntrancesForMap and ns.GetDungeonEntrancesForMap(data.entranceMapID or data.mapID)
    for i = 1, list and #list or 0 do
        local e = list[i]
        if e.name == data.name then
            if e.zoneMapID and e.zoneX then return e.zoneMapID, e.zoneX, e.zoneY end
            if e.position then return data.entranceMapID or data.mapID, e.position.x, e.position.y end
        end
    end
    return nil
end

local function Destination(data)
    local dest = { name = data.name, icon = data.icon, category = data.category, zone = data.isZone and true or nil }
    local em, ex, ey
    if data.isDungeonEntrance and not (data.x and data.y) then em, ex, ey = EntranceOf(data) end
    if em then
        dest.mapID, dest.x, dest.y, dest.zone = em, ex, ey, nil
    elseif data.x and data.y and data.mapID then
        dest.mapID, dest.x, dest.y = data.mapID, data.x, data.y
    else
        dest.mapID, dest.x, dest.y = data.zoneMapID or data.mapID, 0.5, 0.5
    end
    return dest
end

-- The engine plans over the recorded travel graph; with no data or no cover,
-- the route is one step of traveling there.
local PlayerWorldPos   -- defined below with the position helpers

-- Where this character's hearth lands, learned from its last hearth and
-- kept while the bind is the same inn; nothing until then.

local function HearthPoint()
    local db = DB()
    local h = db and db.gpsHearth and db.gpsHearth[CharKey()]
    if not h then return nil end
    local bind = GetBindLocation and GetBindLocation()
    if bind and h.bind and h.bind ~= bind then return nil end
    return h
end

local function LearnHearth()
    local db = DB()
    if not db then return end
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local ci, wx, wy = PlayerWorldPos()
    if not (mapID and ci) then return end
    local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")
    local x, y = 0.5, 0.5
    if pos then x, y = pos:GetXY() end
    db.gpsHearth = db.gpsHearth or {}
    db.gpsHearth[CharKey()] = { bind = GetBindLocation and GetBindLocation() or nil, m = mapID, x = x, y = y, ci = ci, wx = wx, wy = wy }
end
GPS.LearnHearth = LearnHearth

-- A long walk reads as one step per zone it crosses ("Walk through Dun
-- Morogh to Loch Modan"), each previewed on its own map.
local CONTINENT = Enum and Enum.UIMapType and Enum.UIMapType.Continent or 2
local ZONE = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
local continentOf = {}

local function ContinentAbove(mapID)
    local depth = 0
    while mapID and depth < 8 do
        local info = C_Map.GetMapInfo(mapID)
        if not info then return nil end
        if info.mapType == CONTINENT then return mapID end
        mapID = info.parentMapID
        depth = depth + 1
    end
    return nil
end

local function ZoneAt(ci, wx, wy)
    local cont = continentOf[ci]
    if not (cont and C_Map.GetMapInfoAtPosition) then return nil end
    local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, ci, CreateVector2D(wx, wy), cont)
    if not (ok and pos) then return nil end
    local x, y = pos:GetXY()
    local info = x and C_Map.GetMapInfoAtPosition(cont, x, y)
    if info and info.mapID and info.mapID ~= cont then return info.mapID, info.name end
    return nil
end

local function MapPos(ci, wx, wy, mapID)
    local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, ci, CreateVector2D(wx, wy), mapID)
    if ok and pos then return pos:GetXY() end
    return nil
end

-- A city is a zone map without exploration to uncover.
local function IsCity(mapID)
    local info = C_Map.GetMapInfo(mapID)
    return info ~= nil and info.mapType == ZONE and info.flags ~= nil and bit.band(info.flags, 2) == 0
end

local function SplitWalks(steps, dest)
    local Route = ns.GPSRoute
    local ci, wx, wy = PlayerWorldPos()
    if not (Route and Route.SplitWalks and ci and C_Map.GetMapPosFromWorldPos) then return steps end
    continentOf[ci] = continentOf[ci] or ContinentAbove(C_Map.GetBestMapForUnit("player"))
    for i = 1, #steps do
        local p = steps[i].arrive
        if p and p.ci and p.m and not continentOf[p.ci] then continentOf[p.ci] = ContinentAbove(p.m) end
    end
    local start = { ci = ci, wx = wx, wy = wy }
    local here = C_Map.GetBestMapForUnit("player")
    local hereInfo = here and IsCity(here) and C_Map.GetMapInfo(here)
    local ok, out = pcall(Route.SplitWalks, steps, start, ns.GPSData, {
        zoneAt = ZoneAt, mapPos = MapPos, isCity = IsCity,
        startCity = hereInfo and { map = here, name = hereInfo.name } or nil,
        goalZone = dest.zone and dest.mapID or nil,
    })
    if ok and out and #out > 0 then return out end
    return steps
end

function GPS:BuildRoute(dest, via)
    local Route = ns.GPSRoute
    if Route and ns.GPSData then
        local h = HearthPoint()
        local ok, steps, total, advice = pcall(Route.Build, Route, dest, { hearth = h and { point = h } or nil, via = via })
        if ok and steps and #steps > 0 then
            for i = 1, #steps do steps[i].name = steps[i].name or dest.name end
            return SplitWalks(steps, dest), total, advice
        end
        if via then return nil end   -- no way with that stop: the route stays as it was
    end
    -- No way through the data: a plain leg, priced as the crow flies when
    -- the spot is on this continent, unpriced when it is not.
    local sec
    local Engine = ns.GPSRoute
    local ci, px, py = PlayerWorldPos()
    local tci, tx, ty = WorldPos(dest.mapID, dest.x or 0.5, dest.y or 0.5)
    if ci and tci == ci and tx and Engine and Engine.TravelSeconds then
        sec = Engine:TravelSeconds(((px - tx) ^ 2 + (py - ty) ^ 2) ^ 0.5)
    end
    return {
        { kind = "travel", name = dest.name, mapID = dest.mapID, x = dest.x, y = dest.y, sec = sec,
          arrive = tci and { m = dest.mapID, x = dest.x, y = dest.y, ci = tci, wx = tx, wy = ty } or nil,
          text = sformat(L["GPS_STEP_TRAVEL_FMT"], dest.name or "?") },
    }, sec
end

WorldPos = function(mapID, x, y)
    if not (mapID and x and y and C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local ok, ci, pos = pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(x, y))
    if ok and pos then
        local wx, wy = pos:GetXY()
        return ci, wx, wy
    end
    return nil
end

PlayerWorldPos = function()
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if not mapID then return nil end
    local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not ok or not pos then return nil end
    local x, y = pos:GetXY()
    if not x or (x == 0 and y == 0) then return nil end
    return WorldPos(mapID, x, y)
end

local function Refresh()
    for i = 1, #surfaces do
        local s = surfaces[i]
        if s:IsShown() and s.Render then s:Render() end
    end
    if ns.MapTab and ns.MapTab.RefreshPageBar then ns.MapTab:RefreshPageBar() end
    if ns.GPSWorldPin then ns.GPSWorldPin:Refresh() end
end

-- The map point for a step's waypoint. A map that refuses user waypoints
-- (dungeon-type cities, underground continents) hands it to the nearest ancestor that takes one.
local function WaypointPoint(step)
    local mapID, x, y = step.mapID, step.x, step.y
    if not (mapID and x and y) then return nil end
    local can = C_Map and C_Map.CanSetUserWaypointOnMap
    if not can or can(mapID) then return mapID, x, y end
    local p = step.go or step.arrive
    local ci, wx, wy
    if p and p.wx then ci, wx, wy = p.ci, p.wx, p.wy else ci, wx, wy = WorldPos(mapID, x, y) end
    if not (ci and C_Map.GetMapInfo and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return nil end
    local cur, depth = mapID, 0
    while cur and depth < 6 do
        local info = C_Map.GetMapInfo(cur)
        cur = info and info.parentMapID
        depth = depth + 1
        if cur and can(cur) then
            local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, ci, CreateVector2D(wx, wy), cur)
            if ok and pos then
                local px, py = pos:GetXY()
                if px and px >= 0 and px <= 1 and py >= 0 and py <= 1 then return cur, px, py end
            end
        end
    end
    return nil
end

local REACH_YARDS = 40
local ShowGameMenu   -- defined with the menus below; the rows are built before it
local TrackStep      -- defined below; the jump above needs it

-- A deliberate jump to a step, announced: a plain click never does this.
function GPS.GoToStep(index)
    local route = Route()
    if not (route and route.steps[index]) then return end
    TrackStep(index)
end


-- A crossing still a way off reads as reaching it (portal, dock, flight master),
-- then as taking it once there.
local function StepText(step, active)
    if not (active and step and step.reach and step.go) then return step and step.text or "" end
    local ci, px, py = PlayerWorldPos()
    local tci, tx, ty
    if step.go.wx then tci, tx, ty = step.go.ci, step.go.wx, step.go.wy
    else tci, tx, ty = WorldPos(step.go.m, step.go.x, step.go.y) end
    if ci and tci == ci and tx then
        local d = ((px - tx) ^ 2 + (py - ty) ^ 2) ^ 0.5
        if d > REACH_YARDS then return step.reachText or sformat(L["GPS_STEP_REACH_FMT"], step.reach) end
    end
    return step.text or ""
end
GPS.StepText = StepText
GPS.PlayerWorldPos = function() return PlayerWorldPos() end

TrackStep = function(index)
    local route = Route()
    local step = route and route.steps[index]
    if not step then return end
    route.active = index
    route.arrived = nil
    -- A teleport counts as taken only once cast, or once off this continent.
    route.castAt = nil
    route.stepCi = PlayerWorldPos()
    local MapSearch = ns.MapSearch
    local mapID, x, y = WaypointPoint(step)
    if mapID and UiMapPoint and MapSearch and MapSearch.PlaceUserWaypoint then
        MapSearch:PlaceUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
        -- Navigation is explicit tracking: the arrow is on whatever the
        -- general auto-track option says.
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            C_SuperTrack.SetSuperTrackedUserWaypoint(true)
        end
        if MapSearch.RefreshAllClearButtons then MapSearch:RefreshAllClearButtons() end
    end
    Refresh()
end

local function StopTicker()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
end

-- Whether the player stands on this map or one nested in it.
local function OnMap(mapID)
    if not (mapID and C_Map and C_Map.GetBestMapForUnit) then return false end
    local cur = C_Map.GetBestMapForUnit("player")
    local depth = 0
    while cur and depth < 8 do
        if cur == mapID then return true end
        local info = C_Map.GetMapInfo and C_Map.GetMapInfo(cur)
        cur = info and info.parentMapID
        depth = depth + 1
    end
    return false
end

local function Arrive(route)
    route.arrived = true
    StopTicker()
    -- The arrow lets go and the pin comes off the map: there is nowhere
    -- left to point.
    if ns.MapSearch and ns.MapSearch.SetEasyFindWaypointPlaced then ns.MapSearch:SetEasyFindWaypointPlaced(false) end
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(false) end
    if C_Map and C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
    Refresh()
    if L["GPS_ARRIVED_AT_FMT"] and EasyFind.Print then
        EasyFind:Print(sformat(L["GPS_ARRIVED_AT_FMT"], route.dest and route.dest.name or "?"))
    end
    if PlaySound and SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_COMPLETE then
        pcall(PlaySound, SOUNDKIT.IG_QUEST_LIST_COMPLETE)
    end
    Utils.SafeAfter(ARRIVED_LINGER, function()
        local r = Route()
        if r and r.arrived then GPS:Clear() end
    end)
end

-- The pace toward the current step's spot, from the last ticks.
local closing = {}
local walkOpts = {}

-- The time still to go: the way from where the player stands to the
-- current step's spot, that step's crossing, and every step after it.
local function RemainingSeconds(route)
    local i = route.active or 1
    local step = route.steps[i]
    local Engine = ns.GPSRoute
    if not (step and Engine and Engine.TravelSeconds) then return route.eta end
    local total
    if step.kind == "teleport" then
        total = step.edgeSec or step.sec or 0
    else
        local ci, px, py = PlayerWorldPos()
        local onTaxi = step.kind == "taxi" and UnitOnTaxi and UnitOnTaxi("player")
        local target = onTaxi and step.arrive or (step.go or step.arrive)
        local tci, tx, ty
        if target and target.wx then tci, tx, ty = target.ci, target.wx, target.wy
        elseif target then tci, tx, ty = WorldPos(target.m, target.x, target.y) end
        if ci and tci == ci and tx then
            local d = ((px - tx) ^ 2 + (py - ty) ^ 2) ^ 0.5
            -- Pace learned over the whole step (ground closed over time moving) beats the
            -- model; the last second swings with every turn. Standing still holds the estimate.
            local now = GetTime and GetTime() or 0
            if closing.step ~= i or not closing.at then
                closing.step, closing.d0, closing.moving, closing.pace = i, d, 0, nil
            elseif now > closing.at then
                if closing.d - d > 0.5 then closing.moving = closing.moving + (now - closing.at) end
                local progress = closing.d0 - d
                if progress >= 40 and closing.moving >= 6 then closing.pace = progress / closing.moving end
            end
            local moved = closing.at and (closing.d - d) > 0.5
            closing.d, closing.at = d, now
            if closing.pace and closing.pace > 1 then
                total = d / closing.pace + (step.edgeSec or 0)
            elseif onTaxi then total = Engine:TravelSeconds(d, { taxi = true })
            else
                walkOpts.wind = step.wind
                total = Engine:TravelSeconds(d, walkOpts) + (step.edgeSec or 0)
            end
            if not moved and closing.held then total = closing.held end
            closing.held = total
        else
            total = step.sec or 0
        end
    end
    for j = i + 1, #route.steps do total = total + (route.steps[j].sec or 0) end
    return total
end

-- The time still to go, always with its units: hours and minutes, or
-- minutes and seconds, or seconds alone, in the game's own short forms.
local function EtaText(sec)
    sec = mfloor((sec or 0) + 0.5)
    if sec < 1 then sec = 1 end
    local h = mfloor(sec / 3600)
    local m = mfloor((sec % 3600) / 60)
    local s = sec % 60
    -- Our own unit words: the game's carry a grammar token that some text
    -- does not render, leaving the number alone.
    local H, M, S = L["GPS_UNIT_HR"] or "%d hr", L["GPS_UNIT_MIN"] or "%d min", L["GPS_UNIT_SEC"] or "%d sec"
    if h > 0 then
        return sformat(H, h) .. (m > 0 and (" " .. sformat(M, m)) or "")
    elseif m > 0 then
        return sformat(M, m) .. (s > 0 and (" " .. sformat(S, s)) or "")
    end
    return sformat(S, s)
end
GPS.EtaText = EtaText

-- The time line on every surface, without a full redraw.
local function UpdateEtaText(route)
    local eta = ""
    if route and not route.arrived and route.eta and route.eta > 0 then eta = EtaText(route.eta) end
    for i = 1, #surfaces do
        local fs = surfaces[i].time or surfaces[i].eta
        if fs and fs.SetText then fs:SetText(eta) end
    end
end

local OFF_ROUTE_YARDS = 250   -- this far from a walk's way, the route starts over from here
local OFF_ROUTE_TICKS = 3     -- seconds off it first: a loading screen or a jump is no detour
local REROUTE_EVERY = 10
local offRoute = { ticks = 0, at = 0 }

local function PointWorld(p)
    if not p then return nil end
    if p.wx then return p.ci, p.wx, p.wy end
    return WorldPos(p.m, p.x, p.y)
end

local function ToSegment(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local t = len2 > 0 and mmax(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / len2)) or 0
    return ((px - ax - t * dx) ^ 2 + (py - ay - t * dy) ^ 2) ^ 0.5
end

-- Whether the player has left the current walk's way: off its straight
-- line and off its road, or on another continent.
local function OffRoute(route, ci, px, py)
    local i = route.active or 1
    local step = route.steps[i]
    if step.kind ~= "travel" then return false end
    local fci, fx, fy = PointWorld(i > 1 and route.steps[i - 1].arrive or route.from)
    local tci, tx, ty = PointWorld(step.go or step.arrive)
    if not (fci and tci and fci == tci) then return false end
    if ci ~= tci then return true end
    if ToSegment(px, py, fx, fy, tx, ty) <= OFF_ROUTE_YARDS then return false end
    local Engine = ns.GPSRoute
    local road = Engine and Engine.RoadPath and ns.GPSData and Engine.RoadPath(ns.GPSData, tci, fx, fy, tx, ty)
    local pts = road and road.pts or {}
    for v = 1, #pts - 3, 2 do
        if ToSegment(px, py, pts[v], pts[v + 1], pts[v + 2], pts[v + 3]) <= OFF_ROUTE_YARDS then return false end
    end
    return true
end

-- The route again from where the player stands, to the same place. A stop
-- to learn a flight master stays until that master is learned.
local function Reroute(route)
    local known = ns.GPSRoute and ns.GPSRoute.recordedKnown
    local via = route.via and not (known and known[route.via.id]) and route.via or nil
    local steps, total, advice = GPS:BuildRoute(route.dest, via)
    if not steps then return end
    local ci, wx, wy = PlayerWorldPos()
    CharDB().route = { dest = route.dest, steps = steps, active = 1, t = time(), eta = total, total = total, advice = advice,
                       via = via, from = ci and { ci = ci, wx = wx, wy = wy } or nil }
    closing.step = nil
    if ns.GPSPreview and ns.GPSPreview.Reset then ns.GPSPreview:Reset() end
    TrackStep(1)
end

local function Tick()
    local route = Route()
    if not route or route.arrived then StopTicker() return end
    local step = route.steps[route.active or 1]
    if not step then StopTicker() return end
    SampleGroundSpeed()
    -- The estimate follows the player: the way still ahead, every second.
    route.eta = RemainingSeconds(route)
    UpdateEtaText(route)
    -- Reaching a crossing's spot changes what its step says: redraw then.
    local there = StepText(step, true) == (step.text or "")
    if route.there ~= there then
        route.there = there
        Refresh()
    end
    -- A zone is reached when you are in it, wherever its map's middle is.
    if route.dest and route.dest.zone and route.dest.mapID and OnMap(route.dest.mapID) then
        Arrive(route)
        return
    end
    -- A walk through a zone ends on entering the next one, wherever the
    -- border is crossed; leaving a city ends its step the same way.
    if step.enter and OnMap(step.enter) then
        if route.steps[(route.active or 1) + 1] then
            TrackStep((route.active or 1) + 1)
        else
            Arrive(route)
        end
        return
    end
    local ci, px, py = PlayerWorldPos()
    if not ci then return end
    -- Backtracked or wandered off: the route starts over from here.
    if not (UnitOnTaxi and UnitOnTaxi("player")) and OffRoute(route, ci, px, py) then
        offRoute.ticks = offRoute.ticks + 1
        local now = GetTime()
        if offRoute.ticks >= OFF_ROUTE_TICKS and now - offRoute.at >= REROUTE_EVERY then
            offRoute.ticks, offRoute.at = 0, now
            Reroute(route)
            return
        end
    else
        offRoute.ticks = 0
    end
    -- A step is done where it lands you (the far side of a portal or a
    -- flight), which is not always where it starts.
    local arrive = step.arrive
    local sci, sx, sy
    if arrive and arrive.wx then sci, sx, sy = arrive.ci, arrive.wx, arrive.wy
    elseif arrive then sci, sx, sy = WorldPos(arrive.m, arrive.x, arrive.y)
    else sci, sx, sy = WorldPos(step.mapID, step.x, step.y) end
    if not sci or sci ~= ci then return end
    if step.kind == "teleport" and ci == route.stepCi
        and not (route.castAt and GetTime() - route.castAt < 300) then return end
    -- A stop to learn a flight path is done when the flight master's map
    -- shows it learned, not on arriving.
    if step.kind == "learn" then return end
    local crossing = step.kind ~= "travel"
    -- A crossing to another continent is done the moment you are on it;
    -- one that stays on this continent is done near its far spot.
    if not (crossing and step.go and step.go.ci ~= sci) then
        local radius = crossing and CROSS_ARRIVE_YARDS or ARRIVE_YARDS
        local dx, dy = px - sx, py - sy
        if (dx * dx + dy * dy) > radius * radius then return end
    end
    if route.steps[(route.active or 1) + 1] then
        TrackStep((route.active or 1) + 1)
    else
        Arrive(route)
    end
end

local function StartTicker()
    if ticker or not C_Timer then return end
    ticker = C_Timer.NewTicker(1, Tick)
end

function GPS:NavigateTo(data, opts)
    if not self:CanNavigate(data) then return false end
    local db = DB()
    if not db then return false end
    local dest = Destination(data)
    local steps, total, advice = self:BuildRoute(dest)
    local ci, wx, wy = PlayerWorldPos()
    CharDB().route = { dest = dest, steps = steps, active = 1, t = time(), eta = total, total = total, advice = advice,
                       from = ci and { ci = ci, wx = wx, wy = wy } or nil }
    -- A new route opens up, whatever the last one was folded to.
    db.gpsPopoutCollapsed = nil
    for i = 1, #surfaces do
        if surfaces[i].SyncFold then surfaces[i]:SyncFold() end
    end
    TrackStep(1)
    StartTicker()
    -- Started from the window: it shows there; the map is not opened.
    -- Started from the main search bar: the window opens, not the map.
    if opts and opts.popout then
        self:TogglePopout(true)
    elseif not (opts and opts.quiet) then
        self:Open()
    end
    return true
end

-- The trip again with a stop to learn a flight master on it.
function GPS:AddStop(tip)
    local route = Route()
    local Engine = ns.GPSRoute
    if not (route and route.dest and Engine and tip and tip.id) then return end
    local via = { id = tip.id, name = tip.name, p = tip.p }
    local steps, total, advice = self:BuildRoute(route.dest, via)
    if not steps then return end
    route.steps, route.eta, route.total, route.advice, route.t, route.there = steps, total, total, advice, time(), nil
    route.via = via
    local ci, wx, wy = PlayerWorldPos()
    route.from = ci and { ci = ci, wx = wx, wy = wy } or nil
    closing.step = nil
    TrackStep(1)
end

-- What the navigation is doing right now, for the dev command.
function GPS:Status()
    local out = {}
    out[#out + 1] = ns.GPSWorldPin and ns.GPSWorldPin:Status() or "world pin: file not loaded (the companion's file list changed: restart the client)"
    if popoutFrame then
        local f = popoutFrame
        local b = f.border
        out[#out + 1] = sformat("pop-out: shown %s, folded %s, size %.0fx%.0f, scale %.2f | border shown %s, extends top %s bottom %s | glyph top %s",
            tostring(f:IsShown()), tostring(f.collapsed == true), f:GetWidth() or 0, f:GetHeight() or 0, f:GetEffectiveScale() or 1,
            tostring(b and b:IsShown()), b and b:GetTop() and f:GetTop() and sformat("%.0f", b:GetTop() - f:GetTop()) or "?",
            b and b:GetBottom() and f:GetBottom() and sformat("%.0f", f:GetBottom() - b:GetBottom()) or "?",
            f.glyph and f.glyph:GetTop() and f:GetTop() and sformat("%.0f", f:GetTop() - f.glyph:GetTop()) or "?")
    end
    local route = Route()
    if not route then out[#out + 1] = "no route" return out end
    local step = route.steps[route.active or 1]
    out[#out + 1] = sformat("route to %s: step %d of %d%s, ticker %s", tostring(route.dest and route.dest.name),
        route.active or 1, #route.steps, route.arrived and " (arrived)" or "", ticker and "running" or "stopped")
    if step then
        local mapID, x, y = WaypointPoint(step)
        out[#out + 1] = sformat("step: %s | pin map %s at %.3f,%.3f (step map %s%s)", tostring(step.text), tostring(mapID),
            x or -1, y or -1, tostring(step.mapID), (C_Map and C_Map.CanSetUserWaypointOnMap and step.mapID and not C_Map.CanSetUserWaypointOnMap(step.mapID)) and ", refuses waypoints" or "")
        local ci, px, py = PlayerWorldPos()
        local arrive = step.arrive
        local sci, sx, sy
        if arrive and arrive.wx then sci, sx, sy = arrive.ci, arrive.wx, arrive.wy
        elseif arrive then sci, sx, sy = WorldPos(arrive.m, arrive.x, arrive.y)
        else sci, sx, sy = WorldPos(step.mapID, step.x, step.y) end
        if ci and sci then
            out[#out + 1] = sformat("player continent %s, arrival continent %s, distance %s yd (advances within %d)", tostring(ci), tostring(sci),
                ci == sci and tostring(math.floor(((px - sx) ^ 2 + (py - sy) ^ 2) ^ 0.5)) or "other continent", ARRIVE_YARDS)
        else
            out[#out + 1] = "player or arrival position unknown"
        end
    end
    if GPS.DockStatus then
        for _, line in ipairs(GPS.DockStatus()) do out[#out + 1] = line end
    end
    local wp = C_Map and C_Map.GetUserWaypoint and C_Map.GetUserWaypoint()
    out[#out + 1] = sformat("native waypoint: %s | super-tracked: %s", wp and sformat("map %s %.3f,%.3f", tostring(wp.uiMapID), wp.position.x, wp.position.y) or "none",
        tostring(C_SuperTrack and C_SuperTrack.IsSuperTrackingUserWaypoint and C_SuperTrack.IsSuperTrackingUserWaypoint()))
    return out
end

function GPS:Clear()
    local c = CharDB()
    if c then c.route = nil end
    StopTicker()
    Refresh()
    if ns.MapTab and ns.MapTab.ShowSearchView then ns.MapTab:ShowSearchView() end
end

function GPS:Open()
    if ns.MapTab and ns.MapTab.ShowPage then
        return ns.MapTab:ShowPage("gps")
    end
    return false
end

-- Rendering, shared by the page and the pop-out

-- Teleport step icon: a secure button for the spell, toy or item.
-- Attributes change only out of combat; in combat it hides.
local CAST_MASK_SCALE = 64 / 45

-- Where an item sits in the bags, for its own tooltip.
local function BagSlotOf(itemID)
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemID) then return nil end
    for bag = 0, (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            if C_Container.GetContainerItemID(bag, slot) == itemID then return bag, slot end
        end
    end
    return nil
end

-- The swipe follows the spell's or item's cooldown.
local function UpdateCooldown(btn)
    if not (btn and btn.cd) then return end
    local start, duration = 0, 0
    if btn.itemID and C_Container and C_Container.GetItemCooldown then
        local ok, s, d = pcall(C_Container.GetItemCooldown, btn.itemID)
        if ok then start, duration = s or 0, d or 0 end
    elseif btn.spellID and C_Spell and C_Spell.GetSpellCooldown then
        local ok, info = pcall(C_Spell.GetSpellCooldown, btn.spellID)
        if ok and info then start, duration = info.startTime or 0, info.duration or 0 end
    end
    if duration and duration > 1.5 then btn.cd:SetCooldown(start, duration) else btn.cd:Clear() end
end

local castButtons = {}   -- every cast button, hidden as a fight begins

-- A secure button protects every frame it hangs from in a fight, so it belongs to
-- UIParent: pinned to its row out of combat, hidden and unpinned as a fight begins.
local function CastButton(row, inset)
    local btn = CreateFrame("Button", nil, UIParent, "SecureActionButtonTemplate")
    btn.row, btn.inset = row, inset
    castButtons[#castButtons + 1] = btn
    row:HookScript("OnHide", function()
        if not (InCombatLockdown and InCombatLockdown()) then btn:Hide() end
    end)
    btn:SetSize(20, 20)
    -- The game acts on the down-click by default now; take both and act
    -- on the up-click only, so one press is one cast.
    btn:RegisterForClicks("AnyUp", "AnyDown")
    btn:SetAttribute("useOnKeyDown", false)
    -- The action bar's button, scaled down: the icon uncropped under the
    -- rounded mask, the frame sitting on the icon's edge, not outside it.
    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetAllPoints()
    -- The mask's rounded square fills the middle 45/64 of its texture:
    -- drawn larger than the icon so the square covers it.
    local mask = btn:CreateMaskTexture()
    mask:SetPoint("CENTER", btn.icon, "CENTER", 0, 0)
    mask:SetTexture("Interface\\HUD\\UIActionBarIconFrameMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    btn.icon:AddMaskTexture(mask)
    local function FitMask(self, w, h)
        mask:SetSize((w or self:GetWidth()) * CAST_MASK_SCALE, (h or self:GetHeight()) * CAST_MASK_SCALE)
    end
    btn:SetScript("OnSizeChanged", FitMask)
    FitMask(btn, 20, 20)
    local frame = btn:CreateTexture(nil, "OVERLAY")
    frame:SetAtlas("UI-HUD-ActionBar-IconFrame")
    frame:SetAllPoints(btn.icon)
    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    -- The cooldown swipe over the icon, as the action bar shows it.
    btn.cd = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
    btn.cd:SetAllPoints(btn.icon)
    btn.cd:SetDrawEdge(false)
    btn.cd:SetHideCountdownNumbers(true)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        -- Toy box or bag tooltip: they carry the cooldown line, the plain item tooltip does not.
        if self.spellID and not self.itemID then GameTooltip:SetSpellByID(self.spellID)
        elseif self.itemID and self.toy and GameTooltip.SetToyByItemID then GameTooltip:SetToyByItemID(self.itemID)
        elseif self.itemID then
            local bag, slot = BagSlotOf(self.itemID)
            if bag then GameTooltip:SetBagItem(bag, slot) else GameTooltip:SetItemByID(self.itemID) end
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", GameTooltip_Hide)
    -- Pulsed while its step is hovered: the thing to press.
    local pulse = btn:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local grow = pulse:CreateAnimation("Scale")
    grow:SetScaleFrom(1, 1)
    grow:SetScaleTo(1.25, 1.25)
    grow:SetDuration(0.4)
    grow:SetSmoothing("IN_OUT")
    btn.pulse = pulse
    btn:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    btn:RegisterEvent("BAG_UPDATE_COOLDOWN")
    btn:SetScript("OnEvent", UpdateCooldown)
    btn:Hide()
    return btn
end

-- Only the step that is up offers its button: a later or taken teleport
-- shows no icon, or it reads as a thing to press.
local function SetupCast(btn, step, active)
    if not btn then return false end
    -- In a fight a secure button can be neither hidden nor changed: it was
    -- hidden as the fight began and comes back after it.
    if InCombatLockdown and InCombatLockdown() then return false end
    local row = btn.row
    -- Not our child, so a list that clips does not clip it: a row scrolled
    -- out of sight takes its button along.
    local clip, outside = row:GetParent(), false
    if clip and clip.DoesClipChildren and clip:DoesClipChildren() then
        local top, bottom, rt, rb = clip:GetTop(), clip:GetBottom(), row:GetTop(), row:GetBottom()
        outside = top and rt and (rt > top + 1 or rb < bottom - 1) or false
    end
    if not active or not (step and step.kind == "teleport" and (step.spellID or step.itemID))
        or outside or not row:IsVisible() or row:GetEffectiveAlpha() < 0.05 then
        btn:Hide()
        return false
    end
    btn:ClearAllPoints()
    btn:SetPoint("RIGHT", row, "RIGHT", btn.inset, 0)
    btn:SetFrameStrata(row:GetFrameStrata())
    btn:SetFrameLevel(row:GetFrameLevel() + 3)
    btn.spellID, btn.itemID = step.spellID, step.itemID
    local tex
    if step.itemID then
        if step.toy then
            btn:SetAttribute("type", "toy")
            btn:SetAttribute("toy", step.itemID)
        else
            btn:SetAttribute("type", "item")
            btn:SetAttribute("item", "item:" .. step.itemID)
        end
        tex = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(step.itemID)
    else
        btn:SetAttribute("type", "spell")
        btn:SetAttribute("spell", step.spellID)
        tex = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(step.spellID)
    end
    btn.icon:SetTexture(tex or 134400)
    UpdateCooldown(btn)
    btn:Show()
    return true
end

local function StepRow(container, i)
    local rows = container.rows
    local row = rows[i]
    if row then return row end
    row = CreateFrame("Button", nil, container.list)
    row:SetHeight(ROW_H)
    row:SetPoint("LEFT", container.list, "LEFT", 0, 0)
    row:SetPoint("RIGHT", container.list, "RIGHT", 0, 0)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- The menus' own rounded hover wash, not a flat square.
    Utils.InstallMenuRowHighlight(row)
    row.num = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.num:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.num:SetWidth(18)
    row.num:SetJustifyH("RIGHT")
    row.num._efOwnColor = true
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text._efOwnColor = true
    -- Anchored from the top so a wrapped step grows the row downward;
    -- a single line sits at the same place either way.
    row.text:SetPoint("TOPLEFT", row.num, "TOPRIGHT", 6, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    row.num:ClearAllPoints()
    row.num:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -4)
    -- A teleport's icon near the row's right edge, with a little room.
    row.cast = CastButton(row, -8)
    -- A plain click never moves the route: beside the map it pins the
    -- step's preview; Shift-click jumps; right-click offers the jump.
    row:SetScript("OnClick", function(self, button)
        if not self.index then return end
        if button == "RightButton" then
            -- The same menu the surface itself gives on a right-click.
            if container.ShowMenu then container.ShowMenu() end
        elseif IsShiftKeyDown() then
            GPS.GoToStep(self.index)
        elseif container.previewOnHover and ns.GPSPreview then
            ns.GPSPreview:Toggle(self.index)
        end
    end)
    row:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.text:GetText() or "")
        GameTooltip:AddLine(L["GPS_STEP_TT"], 1, 1, 1, true)
        GameTooltip:Show()
        -- A spell or an item pulses its own icon.
        if self.cast and self.cast:IsShown() and self.cast.pulse then self.cast.pulse:Play() end
    end)
    row:SetScript("OnLeave", function(self)
        GameTooltip_Hide()
        if self.cast and self.cast.pulse then self.cast.pulse:Stop() end
    end)
    rows[i] = row
    return row
end

-- Advice under the steps: flight paths worth learning. A click routes
-- to that flight master.
local function TipRow(container, i)
    container.tips = container.tips or {}
    local row = container.tips[i]
    if row then return row end
    row = CreateFrame("Button", nil, container.list)
    row:SetHeight(ROW_H)
    Utils.InstallMenuRowHighlight(row)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text._efOwnColor = true
    row.text:SetPoint("TOPLEFT", row, "TOPLEFT", 30, -4)
    row.text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(true)
    -- A click could be an accident: the stop is added only once confirmed,
    -- with what it does to this trip spelled out.
    row:SetScript("OnClick", function(self)
        local tip = self.tip
        local route = Route()
        if not (tip and tip.p and tip.viaTotal and route) then return end
        local text = sformat(L["GPS_STOP_CONFIRM_FMT"], tip.name or "?", EtaText(tip.viaTotal), EtaText(route.total or route.eta))
        if tip.after then text = text .. " " .. sformat(L["GPS_STOP_AFTER_FMT"], EtaText(tip.after)) end
        ns.ShowThemedDialog({ text = text, acceptText = L["GPS_STOP_ADD"], cancelText = _G["CANCEL"],
                              onAccept = function() GPS:AddStop(tip) end })
    end)
    row:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.text:GetText() or "", nil, nil, nil, nil, true)
        GameTooltip:AddLine(L[self.tip and self.tip.detour and "GPS_ADVICE_DETOUR_TT" or "GPS_ADVICE_TT"], 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    container.tips[i] = row
    return row
end

-- The advice as lines: masters on the way first (with what learning one
-- saves when the engine priced it), then the best one elsewhere.
local function AdviceLines(route)
    local a = route and route.advice
    if not a then return nil end
    local out = {}
    local learn = a.learn
    for i = 1, #(a.pickups or {}) do
        local p = a.pickups[i]
        local text
        local after
        if learn and learn.id == p.id then
            text = sformat(L["GPS_ADVICE_PICKUP_SAVE_FMT"], p.name or "?", EtaText(learn.save))
            after = learn.total
            learn = nil
        else
            text = sformat(L["GPS_ADVICE_PICKUP_FMT"], p.name or "?")
        end
        out[#out + 1] = { text = text, id = p.id, name = p.name, p = p.p, viaTotal = p.viaTotal, after = after }
    end
    if learn and learn.extra then
        -- Out of the way: what it costs now, what it saves every time after.
        out[#out + 1] = { text = sformat(L["GPS_ADVICE_DETOUR_FMT"], learn.name or "?", EtaText(learn.extra), EtaText(learn.save)),
                          id = learn.id, name = learn.name, p = learn.p, viaTotal = learn.viaTotal, after = learn.total, detour = true }
    end
    return #out > 0 and out or nil
end

local StyleTrackButton, RouteTracked   -- defined with the tracking toggle below; the surfaces render before it

local function Render(container)
    local route = Route()
    local rows = container.rows
    if container.glyphTex then
        container.glyphTex:SetVertexColor(unpack(ns.GOLD_COLOR))
        container.glyphTex:SetAlpha(1)
    end
    if container.track then StyleTrackButton(container.track, route ~= nil and RouteTracked()) end
    if not route then
        if ns.GPSPreview and ns.GPSPreview.Reset then ns.GPSPreview:Reset() end
        container.title:SetText("")
        for i = 1, #rows do rows[i]:Hide() end
        for i = 1, #(container.tips or {}) do container.tips[i]:Hide() end
        container.list:SetHeight(1)
        container.contentHeight = 0
        if container.search then
            container.search:Show()
            container.empty:Hide()   -- the search box says what to do
        else
            container.empty:Show()
        end
        if container.OnRouteChanged then container:OnRouteChanged(false) end
        return
    end
    container.empty:Hide()
    if container.search then
        container.search:Show()
        container:ShowHits(nil)
    end
    container.title:SetText(sformat(L["GPS_TO_FMT"], route.dest.name or "?"))
    if route.arrived then
        -- Arrived: the announcement in the body where the time line and
        -- the steps were, nothing left to follow.
        container.eta:SetText("")
        container.empty:SetText(L["GPS_ARRIVED_AT_FMT"] and sformat(L["GPS_ARRIVED_AT_FMT"], route.dest.name or "?") or L["GPS_ARRIVED"])
        container.empty:Show()
    else
        local eta = ""
        if route.eta and route.eta > 0 then eta = EtaText(route.eta) end
        container.eta:SetText(eta)
    end
    local y = 0
    local offset = container.scrollOffset or 0
    local shown = route.arrived and 0 or #route.steps
    for i = 1, shown do
        local step = route.steps[i]
        local row = StepRow(container, i)
        row.index = i
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", container.list, "TOPLEFT", 0, -y + offset)
        row:SetPoint("RIGHT", container.list, "RIGHT", 0, 0)
        row.num:SetText(tostring(i) .. ".")
        local active = (route.active or 1) == i and not route.arrived
        local done = route.arrived or i < (route.active or 1)
        -- Long steps: cut with an ellipsis, or wrapped onto more lines.
        local wrap = EasyFind.db and EasyFind.db.gpsWrapSteps and true or false
        row.text:SetWordWrap(wrap)
        row.text:SetText(StepText(step, active))
        local cast = SetupCast(row.cast, step, active)
        row.text:SetPoint("RIGHT", row, "RIGHT", cast and -32 or -6, 0)
        local rowH = ROW_H
        if wrap then rowH = mmax(ROW_H, (row.text:GetStringHeight() or 0) + 8) end
        row:SetHeight(rowH)
        if active then
            row.text:SetTextColor(unpack(ns.TEXT_PRIMARY))
            row.num:SetTextColor(unpack(ns.GOLD_COLOR))
        elseif done then
            row.text:SetTextColor(unpack(ns.TEXT_DIM))
            row.num:SetTextColor(unpack(ns.TEXT_DIM))
        else
            row.text:SetTextColor(unpack(ns.TEXT_BODY))
            row.num:SetTextColor(unpack(ns.TEXT_BODY))
        end
        row:Show()
        y = y + rowH
    end
    for i = shown + 1, #rows do rows[i]:Hide() end
    local tips = not route.arrived and AdviceLines(route) or nil
    local nTips = tips and #tips or 0
    for t = 1, nTips do
        local row = TipRow(container, t)
        row.tip = tips[t]
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", container.list, "TOPLEFT", 0, -y + offset)
        row:SetPoint("RIGHT", container.list, "RIGHT", 0, 0)
        row.text:SetText(tips[t].text)
        row.text:SetTextColor(unpack(ns.TEXT_DIM))
        local rowH = mmax(ROW_H, (row.text:GetStringHeight() or 0) + 8)
        row:SetHeight(rowH)
        row:Show()
        y = y + rowH
    end
    for t = nTips + 1, #(container.tips or {}) do container.tips[t]:Hide() end
    container.contentHeight = y
    container.list:SetHeight(mmax(1, y))
    if container.OnRouteChanged then container:OnRouteChanged(true) end
end

-- With no route, a search box beside the glyph lists the map search's routable
-- results underneath; a click starts navigation. Nothing is focused on open.
local function HitRow(frame, i)
    local rows = frame.hits
    if rows[i] then return rows[i] end
    local row = CreateFrame("Button", nil, frame.hitChild)
    row:SetHeight(ROW_H)
    Utils.InstallMenuRowHighlight(row)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    row:SetScript("OnClick", function(self)
        if self.data then
            frame.search:SetText("")
            frame.search:ClearFocus()
            GPS:NavigateTo(self.data, { quiet = true })
        end
    end)
    rows[i] = row
    return row
end

-- Forever towns the map search lacks (Menethil Harbor, Auberdine): labeled places in the
-- GPS data. A name starting with the query goes above the map rows, one containing it below.
local towns
local mergedHits = {}

local function Listed(results, name)
    for i = 1, results and #results or 0 do
        if results[i].name == name then return true end
    end
    return false
end

local function WithTowns(q, results)
    if not towns then
        towns = {}
        local data = ns.GPSData
        for area, p in pairs(data and data.binds or {}) do
            local name = C_Map.GetAreaInfo and C_Map.GetAreaInfo(area)
            local info = name and C_Map.GetMapInfo(p.m)
            if info then
                towns[#towns + 1] = { lower = name:lower(), row = { name = name, mapID = p.m, x = p.x, y = p.y, zoneName = info.name } }
            end
        end
    end
    wipe(mergedHits)
    local lq = q:lower()
    for i = 1, #towns do
        local t = towns[i]
        if t.lower:sub(1, #lq) == lq and not Listed(results, t.row.name) then mergedHits[#mergedHits + 1] = t.row end
    end
    for i = 1, results and #results or 0 do mergedHits[#mergedHits + 1] = results[i] end
    for i = 1, #towns do
        local t = towns[i]
        if t.lower:sub(1, #lq) ~= lq and t.lower:find(lq, 1, true) and not Listed(results, t.row.name) then
            mergedHits[#mergedHits + 1] = t.row
        end
    end
    return mergedHits
end

local function BuildSearch(frame, glyph, padRight, bodyPad)
    frame.hits = {}
    local box = CreateFrame("EditBox", nil, frame, "SearchBoxTemplate")
    box:SetHeight(20)
    box:SetPoint("LEFT", glyph, "RIGHT", 12, 0)
    box:SetPoint("RIGHT", frame, "RIGHT", -padRight, 0)
    box:SetAutoFocus(false)
    box:SetMaxLetters(60)
    if box.Instructions then
        box.Instructions:SetText(L["GPS_SEARCH_PLACEHOLDER"] or SEARCH or "Search")
        box.Instructions:SetWordWrap(false)   -- cut with an ellipsis when the box is narrow
        -- Faint, as the main search bar's placeholder is: the theme's faint
        -- text where a theme is active, the dim text otherwise.
        local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
        local c = (theme and theme.textFaint) or ns.TEXT_DIM
        box.Instructions:SetTextColor(c[1], c[2], c[3], 1)
        box.Instructions._efOwnColor = true
    end
    -- The client focuses a fresh visible EditBox on its own; refuse that.
    box._blockAutoFocus = true
    box:HookScript("OnEditFocusGained", function(self) if self._blockAutoFocus then self:ClearFocus() end end)
    box:HookScript("OnMouseDown", function(self) self._blockAutoFocus = nil end)
    Utils.SafeAfter(0, function() Utils.SafeAfter(0, function() box._blockAutoFocus = nil; box:ClearFocus() end) end)
    box:HookScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    -- The box covers most of a folded window: dragging it moves the window.
    box:RegisterForDrag("LeftButton")
    box:SetScript("OnDragStart", function() if frame.BeginWindowDrag then frame:BeginWindowDrag() end end)
    box:SetScript("OnDragStop", function() if frame.EndWindowDrag then frame:EndWindowDrag() end end)
    frame.search = box

    -- The hits scroll inside whatever height the window gives them, as the
    -- search results do: a scroll frame, the rows on its child, the thin bar.
    local hitList = CreateFrame("ScrollFrame", nil, frame)
    hitList:SetPoint("TOPLEFT", glyph, "BOTTOMLEFT", -6, -8)
    hitList:SetPoint("RIGHT", frame, "RIGHT", -(bodyPad - 4), 0)
    hitList:SetHeight(1)
    local hitChild = CreateFrame("Frame", nil, hitList)
    hitChild:SetSize(1, 1)
    hitList:SetScrollChild(hitChild)
    hitList:SetScript("OnSizeChanged", function(_, w) hitChild:SetWidth(w) end)
    frame.hitList, frame.hitChild = hitList, hitChild
    frame.hitBar = Utils.CreateMinimalScrollBar(hitList, hitList)

    -- The hits' visible height: at most what they need, the rest scrolls.
    function frame:SetHitView(h)
        local content = (self.hitCount or 0) * ROW_H
        h = math.min(h, content)
        hitList:SetHeight(mmax(1, h))
        local scrolls = content > h + 0.5
        self.hitBar:SetShown(scrolls)
        if scrolls then self.hitBar:UpdateThumb(content, h) end
    end

    function frame:ShowHits(results)
        local n = 0
        if results then
            for i = 1, #results do
                local r = results[i]
                if GPS:CanNavigate(r) then
                    n = n + 1
                    local row = HitRow(self, n)
                    row.data = r
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", hitChild, "TOPLEFT", 0, -(n - 1) * ROW_H)
                    row:SetPoint("RIGHT", hitChild, "RIGHT", 0, 0)
                    local where = r.zoneName or r.parentName or r.category
                    row.text:SetText((r.name or "?") .. (where and where ~= r.name and ("  |cff999999" .. tostring(where) .. "|r") or ""))
                    row:Show()
                end
            end
        end
        for i = n + 1, #self.hits do self.hits[i]:Hide() end
        hitChild:SetHeight(mmax(1, n * ROW_H))
        hitList:SetVerticalScroll(0)
        self.hitCount = n
        self:SetHitView(HIT_ROWS * ROW_H)
        if self.OnRouteChanged then self:OnRouteChanged(Route() ~= nil) end
    end

    local pending
    box:HookScript("OnTextChanged", function(self, userInput)
        if Route() then return end
        local text = self:GetText() or ""
        if text == "" then frame:ShowHits(nil) return end
        if pending then return end
        pending = true
        Utils.SafeAfter(0.15, function()
            pending = nil
            local MapSearch = ns.MapSearch
            local q = box:GetText() or ""
            if q == "" or Route() or not (MapSearch and MapSearch.BuildResults) then return end
            local ok, results = pcall(MapSearch.BuildResults, MapSearch, q, true, true)
            frame:ShowHits(WithTowns(q, ok and results or nil))
        end)
    end)
end

-- Title, buttons, empty hint and step list laid into any frame; it gains Render().
-- opts: padX, padY, padRight, popoutButton, search, onRouteChanged.
local POI_NORMAL, POI_NORMAL_ON = "UI-QuestPoi-QuestNumber", "UI-QuestPoi-QuestNumber-SuperTracked"
local POI_PUSHED, POI_PUSHED_ON = "UI-QuestPoi-QuestNumber-Pressed", "UI-QuestPoi-QuestNumber-Pressed-SuperTracked"
local POI_HIGHLIGHT, POI_GLOW = "UI-QuestPoi-InnerGlow", "UI-QuestPoi-OuterGlow"
local PIN_ON_FACE_OFF = { 1, 0.82, 0 }        -- gold pin on the dark face
local PIN_ON_FACE_ON  = { 0.25, 0.13, 0.03 }  -- dark pin on the gold face

RouteTracked = function()
    return C_SuperTrack and C_SuperTrack.IsSuperTrackingUserWaypoint and C_SuperTrack.IsSuperTrackingUserWaypoint() or false
end

-- The arrow follows the route, or lets go of it for the tracker's quests.
local function ToggleRouteTracking()
    local route = Route()
    if not route then return end
    if RouteTracked() then
        -- Let go: the map search must stop treating the pin as its own, or
        -- it re-tracks it the moment nothing else is tracked.
        if ns.MapSearch and ns.MapSearch.SetEasyFindWaypointPlaced then ns.MapSearch:SetEasyFindWaypointPlaced(false) end
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(false) end
    else
        if C_SuperTrack then
            if C_SuperTrack.IsSuperTrackingQuest and C_SuperTrack.IsSuperTrackingQuest() and C_SuperTrack.SetSuperTrackedQuestID then
                C_SuperTrack.SetSuperTrackedQuestID(0)
            end
            if C_SuperTrack.GetSuperTrackedVignette and C_SuperTrack.GetSuperTrackedVignette() and C_SuperTrack.ClearAllSuperTrackedVignettes then
                C_SuperTrack.ClearAllSuperTrackedVignettes()
            end
        end
        TrackStep(route.active or 1)
    end
    Refresh()
end

-- The toggle as the game's POI button: 32-pixel faces on a 20-pixel button, hover and
-- on glows at the atlas's own size (smaller reads dimmer), our pin in the middle. Hidden until placed.
local function BuildTrackButton(parent)
    local track = CreateFrame("Button", nil, parent)
    track:SetSize(20, 20)
    track:SetNormalAtlas(POI_NORMAL)
    track:SetPushedAtlas(POI_PUSHED)
    track:SetHighlightAtlas(POI_HIGHLIGHT, "ADD")
    for _, tex in ipairs({ track:GetNormalTexture(), track:GetPushedTexture(), track:GetHighlightTexture() }) do
        if tex then
            tex:ClearAllPoints()
            tex:SetSize(32, 32)
            tex:SetPoint("CENTER")
        end
    end
    local glow = track:CreateTexture(nil, "BACKGROUND")
    glow:SetPoint("CENTER")
    glow:SetAtlas(POI_GLOW, true)
    glow:SetBlendMode("ADD")
    glow:Hide()
    track.glow = glow
    local pin = track:CreateTexture(nil, "ARTWORK", nil, 1)
    pin:SetSize(11, 15)
    pin:SetPoint("CENTER", track, "CENTER", 0, 0)
    pin:SetTexture(ns.GPS_ICON_TEX)
    pin:SetVertexColor(PIN_ON_FACE_OFF[1], PIN_ON_FACE_OFF[2], PIN_ON_FACE_OFF[3], 1)
    track.pin = pin
    track:SetScript("OnClick", ToggleRouteTracking)
    Utils.AttachDelayedTooltip(track, "ANCHOR_RIGHT", function()
        return RouteTracked() and L["GPS_TRACK_OFF"] or L["GPS_TRACK_ON"]
    end)
    track:Hide()
    return track
end

-- The faces for on (the arrow follows the route) or off.
StyleTrackButton = function(track, on)
    track:SetNormalAtlas(on and POI_NORMAL_ON or POI_NORMAL)
    track:SetPushedAtlas(on and POI_PUSHED_ON or POI_PUSHED)
    local col = on and PIN_ON_FACE_ON or PIN_ON_FACE_OFF
    track.pin:SetVertexColor(col[1], col[2], col[3], 1)
    track.glow:SetShown(on)
end

local function BuildSurface(frame, opts)
    frame.rows = {}
    local padX, padY, padRight = opts.padX or 8, opts.padY or 8, opts.padRight or 8
    -- The header's right padding clears its buttons; the body below only
    -- clears the edge.
    local bodyPad = opts.bodyPadRight or padRight

    -- On a child frame above the panel's gloss; its gold is re-applied every
    -- render in case a theme pass touches it.
    local head, glyph
    if opts.trackGlyph then
        -- The window's icon is the tracking toggle the section has, so it
        -- reads the same way: lit while the arrow follows the route.
        head = BuildTrackButton(frame)
        head:SetFrameLevel(frame:GetFrameLevel() + 10)
        head:SetPoint("TOPLEFT", frame, "TOPLEFT", padX - 2, -(padY - 2))
        head:Show()
        glyph = head
        frame.glyph = head
        frame.track = head
        frame:RegisterEvent("SUPER_TRACKING_CHANGED")
        frame:HookScript("OnEvent", function(self, event) if event == "SUPER_TRACKING_CHANGED" and self:IsShown() then self:Render() end end)
    else
        head = CreateFrame("Frame", nil, frame)
        head:SetFrameLevel(frame:GetFrameLevel() + 10)
        head:SetSize(16, 16)
        head:SetPoint("TOPLEFT", frame, "TOPLEFT", padX, -padY)
        glyph = head:CreateTexture(nil, "OVERLAY", nil, 7)
        glyph:SetTexture(ns.GPS_ICON_TEX)
        glyph:SetAllPoints(head)
        glyph:SetVertexColor(unpack(ns.GOLD_COLOR))
        glyph._efOwnColor = true
        frame.glyph = head
        frame.glyphTex = glyph
    end

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", glyph, "RIGHT", 6, 0)
    title:SetPoint("RIGHT", frame, "RIGHT", -padRight, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    title:SetTextColor(unpack(ns.TEXT_PRIMARY))
    title._efOwnColor = true
    frame.title = title
    if not opts.titleOpensMap then
        -- Resting on the destination line shows the whole route on the map.
        local over = CreateFrame("Frame", nil, frame)
        over:SetAllPoints(title)
        over:EnableMouse(true)
        if over.SetMouseClickEnabled then over:SetMouseClickEnabled(false) end
        over:SetScript("OnEnter", function()
            if frame.previewOnHover and ns.GPSPreview then ns.GPSPreview:ShowAll() end
        end)
        over:SetScript("OnLeave", function()
            if frame.previewOnHover and ns.GPSPreview then ns.GPSPreview:Hide() end
        end)
    end
    if opts.titleOpensMap then
        -- The destination line opens the map's GPS page, as a quest in
        -- the tracker opens its log entry; the steps keep their own click.
        local btn = CreateFrame("Button", nil, frame)
        btn:SetAllPoints(title)
        btn:SetScript("OnEnter", function() title:SetTextColor(unpack(ns.GOLD_COLOR)) end)
        btn:SetScript("OnLeave", function() title:SetTextColor(unpack(ns.TEXT_PRIMARY)) end)
        btn:SetScript("OnClick", function() GPS:Open() end)
        btn:Hide()
        frame.titleBtn = btn
    end

    -- The time estimate on its own line under the name.
    local eta = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    eta:SetPoint("TOPLEFT", glyph, "BOTTOMLEFT", 16 + 6, -4)   -- under the name, not the glyph
    eta:SetJustifyH("LEFT")
    eta:SetWordWrap(false)
    eta:SetTextColor(unpack(ns.TEXT_DIM))
    eta._efOwnColor = true
    frame.eta = eta

    -- Clear route as a small text link at the right end of the time line:
    -- always in view, never a button competing with the steps.
    do
        local link = CreateFrame("Button", nil, frame)
        link:SetHeight(14)
        local text = link:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("RIGHT", link, "RIGHT", 0, 0)
        text:SetText(L["GPS_CLEAR"])
        text:SetTextColor(unpack(ns.TEXT_DIM))
        text._efOwnColor = true
        link:SetWidth((text:GetStringWidth() or 60) + 4)
        -- On the time line's row, anchored to the frame (the line then
        -- ends at the link; anchoring the two to each other would loop).
        link:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -(padY + 16 + 4))
        link:SetScript("OnEnter", function() text:SetTextColor(1, 1, 1) end)
        link:SetScript("OnLeave", function() text:SetTextColor(unpack(ns.TEXT_DIM)) end)
        link:SetScript("OnClick", function() GPS:Clear() end)
        eta:SetPoint("RIGHT", link, "LEFT", -8, 0)
        frame.clearBtn = link
    end

    if opts.popoutButton then
        -- The pop-out icon, a box with an arrow leaving its corner, at the
        -- header's right in the close button's stroke style.
        local btn = CreateFrame("Button", nil, frame)
        btn:SetSize(18, 18)
        btn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -padRight, -(padY - 1))
        local strokes = {}
        local function stroke(w, h, x, y, rot)
            local tex = btn:CreateTexture(nil, "OVERLAY")
            tex:SetTexture("Interface\\Buttons\\WHITE8x8")
            tex:SetSize(w, h)
            tex:SetPoint("CENTER", btn, "CENTER", x, y)
            if rot then tex:SetRotation(rot) end
            strokes[#strokes + 1] = tex
        end
        -- Pixel-aligned: even stroke widths on whole-pixel centers, the
        -- shaft overlapping the head so the corner reads as one line.
        stroke(2, 11, -6, -1.5)          -- box: left
        stroke(11, 2, -1.5, -6)          -- box: bottom
        stroke(6, 2, -4, 3)              -- box: top, left part
        stroke(2, 6, 3, -4)              -- box: right, bottom part
        stroke(2, 12, 3, 3, -mpi / 4)    -- arrow shaft, from the box out to the tip
        stroke(7, 2, 3.5, 7)             -- arrowhead: the tip's corner
        stroke(2, 7, 7, 3.5)
        local function tint(r, g, b)
            for i = 1, #strokes do strokes[i]:SetVertexColor(r, g, b, 1) end
        end
        tint(unpack(ns.TEXT_DIM))
        btn:SetScript("OnEnter", function() tint(1, 1, 1) end)
        btn:SetScript("OnLeave", function() tint(unpack(ns.TEXT_DIM)) end)
        btn:SetScript("OnClick", function()
            GPS:TogglePopout(true)
            -- Popping out is leaving the map for the small window.
            if WorldMapFrame and WorldMapFrame:IsShown() and HideUIPanel then HideUIPanel(WorldMapFrame) end
        end)
        title:SetPoint("RIGHT", btn, "LEFT", -6, 0)
        frame.popoutBtn = btn
    end

    if opts.search then BuildSearch(frame, glyph, padRight, bodyPad) end

    local empty = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    empty:SetPoint("TOPLEFT", glyph, "BOTTOMLEFT", 0, -10)
    empty:SetPoint("RIGHT", frame, "RIGHT", -bodyPad, 0)
    empty:SetJustifyH("LEFT")
    empty:SetWordWrap(true)
    empty:SetText(L["GPS_EMPTY"])
    empty:SetTextColor(unpack(ns.TEXT_DIM))
    empty._efOwnColor = true
    frame.empty = empty
    -- With a search box the hint has no text at all: the box says what to do.
    if opts.search then
        empty:SetText("")
        empty:Hide()
    end

    -- The list hangs from the glyph's frame: rows carry secure buttons, and a secure frame
    -- cannot be positioned through a FontString or Texture. The time line gets a fixed height.
    local etaH = math.ceil((eta.GetLineHeight and eta:GetLineHeight()) or 12)
    eta:SetHeight(etaH)
    local list = CreateFrame("Frame", nil, frame)
    list:SetPoint("TOPLEFT", head, "BOTTOMLEFT", -6, -(4 + etaH + 8))
    list:SetPoint("RIGHT", frame, "RIGHT", -(bodyPad - 4), 0)
    list:SetHeight(1)
    frame.list = list

    frame.OnRouteChanged = function(self, hasRoute)
        self.clearBtn:SetShown(hasRoute)
        self.eta:SetShown(hasRoute)
        if self.titleBtn then self.titleBtn:SetShown(hasRoute) end
        if self.search then
            self.search:SetShown(not hasRoute)
            if hasRoute then self.search:SetText("") end
            self.hitList:SetShown(not hasRoute)
        end
        if opts.onRouteChanged then opts.onRouteChanged(self, hasRoute) end
    end
    frame.Render = Render
    surfaces[#surfaces + 1] = frame
    frame:HookScript("OnShow", function(self) self:Render() end)
end

-- The page under the map search tab

local function BuildPage(frame)
    BuildSurface(frame, { popoutButton = true })
    frame.previewOnHover = true   -- this surface sits beside the map
end

if ns.MapTab and ns.MapTab.RegisterPage then
    -- The route view lives inside the Map search tab, under its search bar;
    -- the directions bar above the results leads back to it.
    ns.MapTab:RegisterPage({
        id = "gps",
        noTab = true,
        keepSearch = true,
        title = L["APP_GPS"],
        hasContent = function() return Route() ~= nil end,
        barText = function()
            local route = Route()
            return route and sformat(L["GPS_RESUME_FMT"], route.dest.name or "?") or L["APP_GPS"]
        end,
        -- Right-click on the bar: the route's own actions without opening it.
        onBarMenu = function(anchor)
            if not ns.ShowTogglePopup then return end
            ns.ShowTogglePopup("EasyFindGPSBarPopup", anchor, {
                { kind = "action", label = L["GPS_POPOUT"], onClick = function() GPS:TogglePopout(true) end },
                { kind = "action", label = L["GPS_CLEAR"], onClick = function() GPS:Clear() end },
            }, {})
        end,
        build = BuildPage,
        onShow = function(frame) frame:Render() end,
    })
end

-- The objective tracker dock: a section in the tracker's own look at a slot picked by
-- dragging. Drop the window on the tracker to dock, drag the section clear to float.

local dockFrame
local RenderDock            -- defined below; the ghost helpers above it call it
local PopoutSize            -- defined with the pop-out below; the floating section uses it
local DOCK_REACH = 24
local DOCK_HEADER_H = 25
local DOCK_INDENT = 20
local DOCK_LINE_GAP = 4

local function Tracker()
    local t = _G.ObjectiveTrackerFrame
    if t and type(t.modules) == "table" then return t end
    return nil
end

-- Any of our menus that is up: gone before its anchor is.
-- The menu row for the pin in the world (on unless turned off).
function GPS.WorldPinRow()
    return { kind = "check", label = L["GPS_WORLD_PIN"],
        get = function() local db = DB() return not (db and db.gpsWorldPin == false) end,
        set = function(v)
            local db = DB()
            if db then db.gpsWorldPin = (not v) and false or nil end
            Refresh()
        end }
end

-- The menu row for snapping into the tracker (on unless turned off); off
-- while snapped in, the section leaves for the window.
function GPS.SnapRow()
    return { kind = "check", label = L["GPS_SNAP_TRACKER"],
        get = function() local db = DB() return not (db and db.gpsNeverDock) end,
        set = function(v)
            local db = DB()
            if db then db.gpsNeverDock = (not v) or nil end
            if not v and GPS:IsDocked() then GPS:TogglePopout(true) end
        end }
end

-- Our menu rows on the game's own context menu, for surfaces in the game's look.
-- False when the game's menu API is missing.
ShowGameMenu = function(owner, defs)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return false end
    local ok = pcall(MenuUtil.CreateContextMenu, owner, function(_, root)
        for _, d in ipairs(defs) do
            if d.kind == "separator" then
                root:CreateDivider()
            elseif d.kind == "title" then
                root:CreateTitle(d.label)
            elseif d.kind == "check" then
                -- The menu stays up and redraws the box after a click; an
                -- error in the flip is reported, not swallowed.
                root:CreateCheckbox(d.label, function() return d.get() and true or false end, function()
                    local ok2, err = pcall(d.set, not d.get())
                    if not ok2 and EasyFind.Print then EasyFind:Print("GPS menu: " .. tostring(err)) end
                    return MenuResponse and MenuResponse.Refresh or nil
                end)
            elseif d.kind == "radio" then
                root:CreateRadio(d.label, function() return d.get() == d.value end, function()
                    local ok2, err = pcall(d.set)
                    if not ok2 and EasyFind.Print then EasyFind:Print("GPS menu: " .. tostring(err)) end
                end)
            elseif d.kind == "action" and d.onClick then
                root:CreateButton(d.label, d.onClick)
            end
        end
    end)
    return ok
end

local function HideMenus()
    if ns.HideTogglePopup then
        ns.HideTogglePopup("EasyFindGPSDockMenu")
        ns.HideTogglePopup("EasyFindGPSSizePopup")
        ns.HideTogglePopup("EasyFindGPSBeaconMenu")
    end
end

-- The window's look: the themed window, or the tracker section look
-- floating on its own.
local function PopoutStyle()
    local db = DB()
    return (db and db.gpsPopoutStyle) or "easyfind"
end

local VisibleModules   -- defined below; the drop zone reads the sections

-- A drop docks over the tracker, from its top to the end of what it shows (its frame
-- runs far lower; on Forever most of the screen), or a header's height when empty.
local function NearTracker(f)
    local t = Tracker()
    local db = DB()
    if db and db.gpsNeverDock then return false end
    if not (t and f:GetLeft() and t:GetLeft() and t:GetTop()) then return false end
    local top = t:GetTop()
    local bottom = top - DOCK_HEADER_H * 2
    local mods = VisibleModules(t)
    for i = 1, #mods do
        local b = mods[i]:GetBottom()
        if b and b < bottom then bottom = b end
    end
    if dockFrame and dockFrame.docked and dockFrame:GetBottom() and dockFrame:GetBottom() < bottom then
        bottom = dockFrame:GetBottom()
    end
    -- Onto it, not beside it: the frame's middle over the tracker's columns,
    -- so a window can sit right next to the tracker without docking.
    local cx = (f:GetLeft() + f:GetRight()) / 2
    return cx > t:GetLeft() and cx < t:GetRight()
        and f:GetTop() > bottom - DOCK_REACH and f:GetBottom() < top + DOCK_REACH
end

-- The tracker's shown sections, top to bottom.
VisibleModules = function(t)
    local out = {}
    for i = 1, #t.modules do
        local m = t.modules[i]
        local h = m.GetContentsHeight and m:GetContentsHeight() or m:GetHeight()
        if m:IsShown() and h and h > 0 then out[#out + 1] = m end
    end
    return out
end

local function ModuleKey(m, i)
    return (m.GetName and m:GetName()) or ("#" .. tostring(i))
end

-- The slot a frame whose top edge is at screen height y lands in: above
-- the first section, or after the last section whose middle is above y.
local function SlotAt(y)
    local t = Tracker()
    if not t then return { bottom = true } end
    local mods = VisibleModules(t)
    local slot = { top = true }
    for i = 1, #mods do
        local m = mods[i]
        local top, bottom = m:GetTop(), m:GetBottom()
        if top and bottom and y < (top + bottom) / 2 then slot = { after = ModuleKey(m, i) } end
    end
    return slot
end

local function SameSlot(a, b)
    if not a or not b then return false end
    return a.top == b.top and a.after == b.after and a.bottom == b.bottom
end

local function TrackerRelayout(t)
    if t.MarkDirty then t:MarkDirty() elseif t.Update then t:Update() end
end

-- The sections around a slot: the one above it and the one below it.
local function SlotNeighbors(t, slot)
    local mods = VisibleModules(t)
    if slot.top then return nil, mods[1] end
    if slot.after then
        for i = 1, #mods do
            if ModuleKey(mods[i], i) == slot.after then return mods[i], mods[i + 1] end
        end
    end
    return mods[#mods], nil
end

-- Room for a height at a slot by the tracker's own means: a height modifier on the
-- section above, or top padding for the top slot. A drag toward a slot opens it there.
local INSERT_KEY = "EasyFindGPS"

-- Forever recomputes top padding from providers on every update, asking twice a frame:
-- room above the first section, then the header's place. 0 the second time keeps the header put.
local topPad = { height = 0, seen = 0 }
function topPad:GetTopPadding()
    local now = GetTime()
    if self.headerAsk == now then
        self.headerAsk = nil
        return 0
    end
    self.headerAsk = now
    self.seen = self.height
    return self.height
end
local topPadAdded
local function TopPadProvider(t)
    if topPadAdded then return true end
    if not (t and type(t.topPaddingProviders) == "table" and EventRegistry and EventRegistry.TriggerEvent) then return false end
    EventRegistry:TriggerEvent("ObjectiveTrackerContainerMixin.AddTopPaddingProvider", topPad)
    topPadAdded = t.topPaddingProviders[topPad] == true
    return topPadAdded
end

local function ClearInsert(t)
    if not dockFrame then return end
    local ins = dockFrame.insert
    dockFrame.insert = nil
    if not ins then return end
    if ins.module and ins.module.ClearHeightModifier then ins.module:ClearHeightModifier(INSERT_KEY) end
    if ins.provider then
        topPad.height = 0
    elseif ins.pad ~= nil and t then
        t.topModulePadding = ins.pad
    end
end

local function ApplyInsert(t, slot, height)
    local spacing = t.moduleSpacing or 10
    local above, below = SlotNeighbors(t, slot)
    local ins = dockFrame.insert
    local changes = not ins or ins.module ~= above or ins.height ~= height
    -- The tracker's sections hold secure quest item buttons, so they are
    -- not resized in a fight: the change waits for its end.
    if changes and InCombatLockdown and InCombatLockdown() then return nil end
    if ins and changes then ClearInsert(t) ins = nil end
    if not ins then
        ins = { module = above, height = height }
        if above then
            if above.SetHeightModifier then above:SetHeightModifier(INSERT_KEY, height + spacing) end
        else
            ins.pad = (t.topModulePadding or 0) - topPad.seen
            if TopPadProvider(t) then
                ins.provider = true
                topPad.height = height + spacing
            else
                t.topModulePadding = ins.pad + height + spacing
            end
        end
        dockFrame.insert = ins
        TrackerRelayout(t)
    end
    return above, below, ins
end

local function PlaceDock()
    local t = Tracker()
    if not (dockFrame and t) then return end
    local gap = dockFrame.dragGap
    if gap then
        ApplyInsert(t, gap.slot, gap.height)
        return
    end
    if not dockFrame.docked or dockFrame.dragging or dockFrame.ghost then return end
    -- Above the tracker's own blocks: they take the mouse, and where the
    -- two overlap they would swallow the header's clicks and drags.
    local lvl = (t:GetFrameLevel() or 0) + 40
    if dockFrame:GetFrameLevel() ~= lvl then dockFrame:SetFrameLevel(lvl) end
    local collapsed = t.IsCollapsed and t:IsCollapsed()
    -- Faded with a folded tracker; its cast button, not ours to fade, hides.
    local alpha = collapsed and 0 or 1
    if dockFrame:GetAlpha() ~= alpha then
        dockFrame:SetAlpha(alpha)
        Refresh()
    end
    local db = DB()
    local height = dockFrame:GetHeight() or DOCK_HEADER_H
    local above, below, ins = ApplyInsert(t, db and db.gpsDockSlot or { bottom = true }, height)
    if not ins then return end
    dockFrame:ClearAllPoints()
    if above then
        -- Inside the room at the bottom of the section above: our bottom
        -- is its extended bottom, and the next section hangs off that.
        dockFrame:SetPoint("TOP", above, "BOTTOM", 0, height)
    else
        local pad = ins.provider and ((t.topModulePadding or 0) - topPad.seen) or ins.pad or 0
        dockFrame:SetPoint("TOP", t, "TOP", 0, -pad)
    end
    -- Inset by the left margin on both sides, as the tracker's sections. A neighbor
    -- with content is the reference: at the top slot, the section below.
    local ref = above or below or (VisibleModules(t))[1] or t.modules[1]
    local margin = ref and ref.leftMargin or 0
    local refW = ref and ref.GetWidth and ref:GetWidth() or 0
    dockFrame:SetPoint("LEFT", t, "LEFT", margin, 0)
    if refW and refW > 0 then
        dockFrame:SetWidth(refW)   -- exactly a section's width
    else
        dockFrame:SetPoint("RIGHT", t, "RIGHT", -margin, 0)
    end
end

-- A drag in progress over the tracker: open (or move) the room at the
-- slot under the dragged frame; nil ends it.
local function DragGap(frame, height)
    if not dockFrame then return end
    local t = Tracker()
    if not t then return end
    local want
    if frame and NearTracker(frame) then
        want = { slot = SlotAt(frame:GetTop() or 0), height = height }
    end
    local had = dockFrame.dragGap
    if (want == nil) ~= (had == nil) or (want and had and (not SameSlot(want.slot, had.slot) or want.height ~= had.height)) then
        dockFrame.dragGap = want
        if not want then ClearInsert(t) TrackerRelayout(t) end
        PlaceDock()
    end
end

-- The section look as a ghost under a dragged window: the section frame
-- rides on the window, at the tracker's width, and the window fades.
local function ShowSectionGhost(window)
    local t = Tracker()
    if not (dockFrame and t) then return end
    dockFrame.ghost = true
    dockFrame.docked = true
    RenderDock(dockFrame)
    dockFrame.docked = nil
    dockFrame:ClearAllPoints()
    dockFrame:SetWidth(t:GetWidth() or 260)
    dockFrame:SetPoint("TOPLEFT", window, "TOPLEFT", 0, 0)
    dockFrame:SetFrameStrata("HIGH")
    dockFrame:SetAlpha(1)
    dockFrame:Show()
    window:SetAlpha(0)
end

local function HideSectionGhost(window)
    if dockFrame and dockFrame.ghost then
        dockFrame.ghost = nil
        dockFrame:Hide()
        dockFrame:SetFrameStrata("LOW")
    end
    window:SetAlpha(1)
end

-- The window look as a ghost under a dragged section: the window rides
-- on the section and the section fades.
local function ShowWindowGhost(section)
    if not popoutFrame then return end
    popoutFrame:ClearAllPoints()
    popoutFrame:SetPoint("TOPLEFT", section, "TOPLEFT", 0, 0)
    popoutFrame:SetAlpha(1)
    popoutFrame:Show()
    popoutFrame:Render()
    section:SetAlpha(0)
end

local function HideWindowGhost(section)
    if popoutFrame and popoutFrame.ghosting then
        popoutFrame.ghosting = nil
        popoutFrame:Hide()
    end
    section:SetAlpha(1)
end

local function DockLine(f, i)
    local rows = f.lines
    if rows[i] then return rows[i] end
    local row = CreateFrame("Button", nil, f)
    row:SetPoint("LEFT", f, "LEFT", DOCK_INDENT, 0)
    row:SetPoint("RIGHT", f, "RIGHT", -4, 0)
    row.dash = row:CreateFontString(nil, "ARTWORK", "ObjectiveTrackerLineFont")
    row.dash:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.dash:SetText(QUEST_DASH or "- ")
    row.text = row:CreateFontString(nil, "ARTWORK", "ObjectiveTrackerLineFont")
    row.text:SetPoint("TOPLEFT", row.dash, "TOPRIGHT", 0, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(true)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if not self.index then return end
        if button == "RightButton" then
            if f.ShowMenu then f.ShowMenu() end
        elseif IsShiftKeyDown() then GPS.GoToStep(self.index) end
    end)
    -- A teleport's icon at the line's right edge, flush with the section's.
    row.cast = CastButton(row, -4)
    row.cast:SetSize(16, 16)
    rows[i] = row
    return row
end

RenderDock = function(f)
    if not (f.docked or f.floating) then return end
    local route = Route()
    local y = -(DOCK_HEADER_H + 8)
    if route then
        if f.search then
            if f.search:GetText() ~= "" then f.search:SetText("") end
            f.search:Hide()
            f.hitList:Hide()
        end
        f.title:SetText(sformat(L["GPS_TO_FMT"], route.dest.name or "?"))
        f.title:Show()
        f.titleBtn:Show()
        local eta = ""
        if not route.arrived and route.eta and route.eta > 0 then eta = EtaText(route.eta) end
        f.time:SetText(eta)
        -- Widths are set, not anchored: a fresh line's anchors are not
        -- resolved yet when its height is read, and it would read as one line.
        local lineW = (f.head:GetWidth() or 260) - DOCK_INDENT
        f.title:ClearAllPoints()
        f.title:SetPoint("TOPLEFT", f, "TOPLEFT", DOCK_INDENT, y)
        f.title:SetWidth(lineW)
        -- The tracking toggle in the quest POI button's spot, lit while the
        -- arrow follows the route.
        local on = RouteTracked()
        StyleTrackButton(f.track, on)
        f.track:Show()
        y = y - (f.title:GetStringHeight() or 14) - DOCK_LINE_GAP
        local n = 0
        -- One fold state for the section and the window, so it survives
        -- a trip through the tracker either way.
        local dbf = DB()
        f.expanded = not (dbf and dbf.gpsPopoutCollapsed)
        if f.expanded == false then
            -- Folded: the header alone, as the tracker's own sections fold.
            f.title:Hide()
            f.titleBtn:Hide()
            f.track:Hide()
            y = -DOCK_HEADER_H
        else
            -- Arrived: one line with the announcement in the steps' place.
            local items = route.steps
            if route.arrived then
                items = { { text = L["GPS_ARRIVED_AT_FMT"] and sformat(L["GPS_ARRIVED_AT_FMT"], route.dest.name or "?") or L["GPS_ARRIVED"] } }
            end
            for i = 1, #items do
                n = n + 1
                local row = DockLine(f, n)
                row.index = (not route.arrived) and i or nil
                row.text:SetText(StepText(items[i], (route.active or 1) == i and not route.arrived))
                local cast = SetupCast(row.cast, items[i], (route.active or 1) == i and not route.arrived)
                row.text:SetWidth(mmax(40, lineW - (row.dash:GetStringWidth() or 8) - (cast and 24 or 0)))
                local active = (route.active or 1) == i and not route.arrived
                local done = i < (route.active or 1)
                local c = (active or route.arrived) and 1 or (done and 0.5 or 0.8)
                row.text:SetTextColor(c, c, c)
                row.dash:SetTextColor(c, c, c)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", f, "TOPLEFT", DOCK_INDENT, y)
                row:SetPoint("RIGHT", f.head, "RIGHT", 0, 0)   -- the section's visual width
                local h = mmax(12, row.text:GetStringHeight() or 12)
                row:SetHeight(h)
                row:Show()
                y = y - h - DOCK_LINE_GAP
            end
        end
        for i = n + 1, #f.lines do f.lines[i]:Hide() end
        y = y + DOCK_LINE_GAP   -- no gap after the last line
    else
        f.title:Hide()
        f.titleBtn:Hide()
        f.track:Hide()
        f.time:SetText("")
        for i = 1, #f.lines do f.lines[i]:Hide() end
        if f.search then
            -- The search box, and the places it finds, in the steps' place.
            f.search:Show()
            f.hitList:Show()
            local n = math.min(f.hitCount or 0, HIT_ROWS)
            f:SetHitView(n * ROW_H)
            y = -DOCK_HEADER_H - (n > 0 and (4 + n * ROW_H + 4) or 0)
        end
    end
    -- Nothing to fold without a route.
    f.fold:SetShown(route ~= nil)
    f.fold:SetNormalAtlas(f.expanded ~= false and "UI-QuestTrackerButton-Secondary-Collapse" or "UI-QuestTrackerButton-Secondary-Expand")
    f:SetHeight(mmax(DOCK_HEADER_H, -y))
    PlaceDock()   -- the room in the tracker follows the height
end

-- A short log of the section's drag, dock and float steps, read back by
-- the dev probe when a drag goes wrong.
local dragLog = {}
local function DLog(fmt, ...)
    local ok, line = pcall(sformat, fmt, ...)
    dragLog[#dragLog + 1] = sformat("%.1f %s", GetTime and GetTime() or 0, ok and line or tostring(fmt))
    if #dragLog > 40 then table.remove(dragLog, 1) end
end

local function RectOf(r)
    if not (r and r.GetLeft and r:GetLeft()) then return "no rect" end
    return sformat("l %.0f t %.0f r %.0f b %.0f", r:GetLeft(), r:GetTop(), r:GetRight(), r:GetBottom())
end

local function FrameState(r)
    if not r then return "nil" end
    return sformat("shown %s visible %s alpha %.1f %s/%d mouse %s movable %s %s",
        tostring(r:IsShown()), tostring(r:IsVisible()), r:GetAlpha() or 1, tostring(r:GetFrameStrata()), r:GetFrameLevel() or 0,
        tostring(r.IsMouseEnabled and r:IsMouseEnabled()), tostring(r.IsMovable and r:IsMovable()), RectOf(r))
end

-- Everything about the section a drag depends on, plus the log.
function GPS.DragProbe()
    local out = {}
    local d = dockFrame
    if not d then out[1] = "no section built" return out end
    out[#out + 1] = "section: " .. FrameState(d)
    out[#out + 1] = sformat("flags: docked %s floating %s dragging %s ghost %s expanded %s parent %s",
        tostring(d.docked == true), tostring(d.floating == true), tostring(d.dragging == true), tostring(d.ghost == true),
        tostring(d.expanded), d:GetParent() and d:GetParent():GetName() or "?")
    out[#out + 1] = "head: " .. FrameState(d.head)
    out[#out + 1] = "grip: " .. FrameState(d.grip)
    out[#out + 1] = "fold: " .. FrameState(d.fold)
    if popoutFrame then
        out[#out + 1] = sformat("window: %s ghosting %s", FrameState(popoutFrame), tostring(popoutFrame.ghosting == true))
    end
    local t = Tracker()
    if t then out[#out + 1] = "tracker: " .. FrameState(t) end
    for i = 1, #dragLog do out[#out + 1] = "log " .. dragLog[i] end
    return out
end

local function BuildDock()
    local f = CreateFrame("Frame", "EasyFindGPSDock", UIParent)
    f:SetSize(260, DOCK_HEADER_H)
    f:SetFrameStrata("LOW")
    f:SetFrameLevel(5)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f.lines = {}

    -- Header as the tracker's sections: 260-pixel strip, secondary header art centered
    -- at native size, text 7 from the left, fold button at its right.
    local head = CreateFrame("Frame", nil, f)
    head:SetSize(260, DOCK_HEADER_H)
    head:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    f.head = head
    local bg = head:CreateTexture(nil, "BACKGROUND")
    bg:SetAtlas("UI-QuestTracker-Secondary-Objective-Header", true)
    bg:SetPoint("CENTER", head, "CENTER", 0, 0)

    local header = head:CreateFontString(nil, "ARTWORK", "ObjectiveTrackerHeaderFont")
    header:SetPoint("LEFT", head, "LEFT", 7, 0)
    header:SetJustifyV("MIDDLE")
    header:SetText(L["APP_GPS"])
    header:SetTextColor(1, 0.82, 0)
    f.header = header

    local time = head:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    time:SetPoint("LEFT", header, "RIGHT", 8, 0)
    time:SetTextColor(1, 1, 1)
    f.time = time

    local fold = CreateFrame("Button", nil, head)
    fold:SetSize(16, 15)
    fold:SetPoint("RIGHT", head, "RIGHT", -1, 0)
    fold:SetNormalAtlas("UI-QuestTrackerButton-Secondary-Collapse")
    fold:SetHighlightAtlas("UI-QuestTrackerButton-Yellow-Highlight")
    if fold:GetHighlightTexture() then fold:GetHighlightTexture():SetBlendMode("ADD") end
    fold:SetScript("OnClick", function()
        local db = DB()
        if db then db.gpsPopoutCollapsed = (f.expanded ~= false) or nil end
        if popoutFrame and popoutFrame.SyncFold then popoutFrame:SyncFold() end
        RenderDock(f)
    end)
    f.fold = fold

    -- The header is the handle: drag to move among the sections or out
    -- of the tracker; right-click for the route's actions.
    local grip = CreateFrame("Button", nil, head)
    grip:SetPoint("TOPLEFT", head, "TOPLEFT", 0, 0)
    grip:SetPoint("RIGHT", fold, "LEFT", -4, 0)
    grip:SetHeight(DOCK_HEADER_H)
    grip:RegisterForClicks("RightButtonUp")
    grip:RegisterForDrag("LeftButton")
    local function Report(ok, err)
        if not ok and EasyFind.Print then EasyFind:Print("GPS drag: " .. tostring(err)) end
    end
    f.grip = grip
    grip:SetScript("OnDragStart", function()
        Report(pcall(function()
        DLog("drag start: docked %s floating %s %s", tostring(f.docked == true), tostring(f.floating == true), RectOf(f))
        HideMenus()
        if not f:IsMovable() then f:SetMovable(true) end
        -- Its width came from the tracker's edges; keep a size of its own
        -- for the ride, and ride above the tracker.
        local w, h = f:GetWidth() or 260, f:GetHeight() or DOCK_HEADER_H
        local left, top = f:GetLeft(), f:GetTop()
        f.dragging = true
        f:ClearAllPoints()
        f:SetSize(w, h)
        if left and top then f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top) end
        f:SetFrameStrata("HIGH")
        f:StartMoving()
        DragGap(f, h)
        end))
    end)
    grip:SetScript("OnDragStop", function()
        -- Once per drop: the handler must not run again from inside itself.
        if f.stopping then return end
        f.stopping = true
        Report(pcall(function()
        f:StopMovingOrSizing()
        f.dragging = nil
        f:SetFrameStrata("LOW")
        local near = NearTracker(f)
        local slot = near and SlotAt(f:GetTop() or 0) or nil
        local left, top = f:GetLeft(), f:GetTop()
        DLog("drag stop: near %s style %s docked %s floating %s at %s,%s", tostring(near), tostring(PopoutStyle()),
             tostring(f.docked == true), tostring(f.floating == true), tostring(left), tostring(top))
        DragGap(nil)
        HideWindowGhost(f)
        if near and f.floating then
            -- A floating section dropped on the tracker docks there.
            GPS:Dock(slot)
            DLog("-> docked: %s", FrameState(f))
        elseif near then
            local db = DB()
            if db then db.gpsDockSlot = slot end
            PlaceDock()
            local t = Tracker()
            if t then TrackerRelayout(t) end
            DLog("-> placed: %s", FrameState(f))
        elseif PopoutStyle() == "tracker" then
            -- Stays a section, floating where it was dropped, never hidden
            -- on the way (see Undock).
            GPS:Undock(true)
            GPS.FloatDockAt(left, top)
            DLog("-> floating: %s", FrameState(f))
        else
            GPS:Undock(true)
            f.floating = nil
            GPS:TogglePopout(true)
            -- The section leaves on the next frame, never inside its own
            -- drag-stop handler.
            f:SetAlpha(0)
            Utils.SafeAfter(0, function()
                if not (f.docked or f.floating or f.dragging) then f:Hide() end
                f:SetAlpha(1)
            end)
            DLog("-> window: %s", FrameState(popoutFrame))
            if popoutFrame and left and top then
                popoutFrame:ClearAllPoints()
                popoutFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
                local db = DB()
                if db then db.gpsPopout = { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = left, y = top } end
            end
        end
        end))
        f.stopping = nil
    end)
    -- The menu anchors at the cursor, not the header: a click anywhere on
    -- the header then closes it, and the header keeps its drag.
    local menuAnchor = CreateFrame("Frame", nil, f)
    menuAnchor:SetSize(1, 1)
    -- The section's options: on the game's own menu, as the tracker's
    -- sections have theirs; the styled popup only if that is missing.
    local function ShowDockMenu()
            local defs = {}
            if f.floating then
                defs[#defs + 1] = { kind = "action", label = L["GPS_CLOSE"], onClick = function() GPS:TogglePopout(false) end }
            else
                defs[#defs + 1] = { kind = "action", label = L["GPS_POPOUT"], onClick = function() GPS:Undock() GPS:TogglePopout(true) end }
                -- The section leaves the tracker; the route stays, and the window
                -- or section returns through the map page or the app.
                defs[#defs + 1] = { kind = "action", label = L["GPS_CLOSE_SECTION"], onClick = function()
                    -- Closing the section ends the route with it.
                    GPS:Clear()
                    GPS:Undock()
                    local c = CharDB()
                    if c then c.popoutOpen = nil end
                end }
            end
            defs[#defs + 1] = { kind = "action", label = L["GPS_CLEAR"], onClick = function() GPS:Clear() end }
            defs[#defs + 1] = GPS.WorldPinRow()
            defs[#defs + 1] = GPS.SnapRow()
            -- The style is for the window outside the tracker; snapped in,
            -- the section has one look.
            if not f.docked then
                defs[#defs + 1] = { kind = "separator" }
                for _, d in ipairs(GPS.StyleRows()) do defs[#defs + 1] = d end
            end
            if ShowGameMenu(f, defs) then return end
            if not ns.ShowTogglePopup then return end
            local cx, cy = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale()
            menuAnchor:ClearAllPoints()
            menuAnchor:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", cx / scale, cy / scale)
            ns.ShowTogglePopup("EasyFindGPSDockMenu", menuAnchor, defs, {})
    end
    f.ShowMenu = ShowDockMenu
    grip:SetScript("OnClick", function(self, button)
        if button == "RightButton" then ShowDockMenu() end
    end)

    local title = f:CreateFontString(nil, "ARTWORK", "ObjectiveTrackerLineFont")
    title:SetJustifyH("LEFT")
    title:SetWordWrap(true)
    title:SetTextColor(1, 0.82, 0)
    f.title = title
    -- The destination line opens the map's GPS page and lights up under the
    -- cursor, as a quest header does. Steps keep their own click.
    local titleBtn = CreateFrame("Button", nil, f)
    titleBtn:SetAllPoints(title)
    titleBtn:SetScript("OnEnter", function() title:SetTextColor(1, 1, 1) end)
    titleBtn:SetScript("OnLeave", function() title:SetTextColor(1, 0.82, 0) end)
    titleBtn:SetScript("OnClick", function() GPS:Open() end)
    titleBtn:Hide()
    f.titleBtn = titleBtn
    -- With no route, a search box in the banner right of the name, from the
    -- same builder as the window's folded row. Its finds list below.
    local searchAnchor = CreateFrame("Frame", nil, f)
    searchAnchor:SetSize(1, 20)
    searchAnchor:SetPoint("LEFT", header, "RIGHT", -2, 0)
    BuildSearch(f, searchAnchor, 10, 8)
    f.search:SetFrameLevel(head:GetFrameLevel() + 5)   -- above the header's grip
    -- Dressed for the banner: shorter, no inset chrome or field, just the
    -- magnifier, a gray hint and the typed text in gold.
    do
        local box = f.search
        box:SetHeight(16)
        for _, key in ipairs({ "Left", "Middle", "Right" }) do
            if box[key] then box[key]:SetAlpha(0) end
        end
        box:SetTextColor(1, 1, 1, 1)
        box:SetFontObject("ObjectiveTrackerLineFont")
        if box.Instructions then
            box.Instructions:SetFontObject("ObjectiveTrackerLineFont")
            box.Instructions:SetTextColor(0.6, 0.6, 0.6, 1)
        end
        if box.searchIcon then
            -- The template hangs its magnifier low for a taller box; center
            -- it on this one.
            box.searchIcon:SetVertexColor(0.7, 0.7, 0.7, 0.9)
            box.searchIcon:ClearAllPoints()
            box.searchIcon:SetPoint("LEFT", box, "LEFT", 2, 0)
        end
        -- A right-click on the box opens the section's options, as on the
        -- header beside it.
        box:HookScript("OnMouseUp", function(_, button)
            if button == "RightButton" and f.ShowMenu then f.ShowMenu() end
        end)
    end
    f.hitList:ClearAllPoints()
    f.hitList:SetPoint("TOPLEFT", f, "TOPLEFT", DOCK_INDENT, -(DOCK_HEADER_H + 4))
    f.hitList:SetPoint("RIGHT", head, "RIGHT", 0, 0)
    f.OnRouteChanged = function(self) RenderDock(self) end

    -- Tracking toggle where a quest's POI button sits: in the 20-pixel indent
    -- left of the title, a little outside the section's left edge.
    local track = BuildTrackButton(f)
    track:SetPoint("TOPRIGHT", title, "TOPLEFT", -7, 4)
    f.track = track
    -- The arrow can move to a quest from the tracker's own buttons.
    f:RegisterEvent("SUPER_TRACKING_CHANGED")
    f:SetScript("OnEvent", function(self) if self.docked or self.floating then RenderDock(self) end end)

    -- Follow the tracker's own relayouts, and check on a light throttle
    -- for anything that moves without one.
    local t = Tracker()
    if t and not t._efGPSHooked then
        t._efGPSHooked = true
        pcall(hooksecurefunc, t, "Update", function() PlaceDock() end)
    end
    local since = 0
    f:SetScript("OnUpdate", function(self, dt)
        since = since + dt
        if self.dragging then
            if since < 0.05 then return end
            since = 0
            if NearTracker(self) then
                if popoutFrame and popoutFrame.ghosting then HideWindowGhost(self) end
                DragGap(self, self:GetHeight() or DOCK_HEADER_H)
            else
                DragGap(nil)
                if PopoutStyle() ~= "tracker" and GPS.EnsurePopout and not (popoutFrame and popoutFrame.ghosting) then
                    GPS.EnsurePopout()
                    popoutFrame.ghosting = true
                    ShowWindowGhost(self)
                end
            end
            return
        end
        if since < 0.25 then return end
        since = 0
        PlaceDock()
    end)

    f.Render = RenderDock
    surfaces[#surfaces + 1] = f
    f:Hide()
    return f
end

function GPS:IsDocked()
    local db = DB()
    return db and db.gpsDocked == true
end

-- Whether the route shows anywhere on screen already: the window, the
-- floating section, or the section in the tracker.
function GPS:IsWindowOpen()
    if popoutFrame and popoutFrame:IsShown() then return true end
    if dockFrame and dockFrame:IsShown() and (dockFrame.docked or dockFrame.floating) then return true end
    return false
end

-- The section as a window of its own, at a spot or at the saved one.
function GPS.FloatDockAt(left, top)
    dockFrame = dockFrame or BuildDock()
    if not dockFrame then return end
    dockFrame.docked = nil
    dockFrame.floating = true
    dockFrame:SetFrameStrata("MEDIUM")
    -- A section's width, floating or not.
    local t = Tracker()
    local ref = t and t.modules and t.modules[1]
    local w = ref and ref.GetWidth and ref:GetWidth() or 0
    dockFrame:SetWidth(w > 0 and w or 260)
    dockFrame:ClearAllPoints()
    local db = DB()
    if not (left and top) then
        local pos = db and db.gpsPopout
        if pos and pos.point == "TOPLEFT" then left, top = pos.x, pos.y end
    end
    if left and top then
        dockFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        if db then db.gpsPopout = { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = left, y = top } end
    else
        dockFrame:SetPoint("TOPRIGHT", UIParent, "RIGHT", -40, 200)
    end
    dockFrame:SetAlpha(1)
    dockFrame:Show()
    -- A grip the game stopped drawing (shown, yet not visible under a
    -- visible header) comes back with a hide and show.
    if dockFrame.grip and dockFrame.head and dockFrame.head:IsVisible() and not dockFrame.grip:IsVisible() then
        dockFrame.grip:Hide()
        dockFrame.grip:Show()
    end
    RenderDock(dockFrame)
    local c = CharDB()
    if c then c.popoutOpen = true end
end

-- Style rows for the cog popup and the section's menu.
function GPS.StyleRows()
    local function pick(style)
        return function()
            local db = DB()
            if not db or PopoutStyle() == style then return end
            HideMenus()
            -- Swap the open window for the other look at the same spot.
            local open, left, top = false, nil, nil
            if popoutFrame and popoutFrame:IsShown() then open, left, top = true, popoutFrame:GetLeft(), popoutFrame:GetTop() end
            if dockFrame and dockFrame.floating and dockFrame:IsShown() then open, left, top = true, dockFrame:GetLeft(), dockFrame:GetTop() end
            db.gpsPopoutStyle = style
            if open then
                if popoutFrame then popoutFrame:Hide() end
                if dockFrame and dockFrame.floating then dockFrame.floating = nil dockFrame:Hide() end
                GPS:TogglePopout(true)
                if left and top then
                    local f = (style == "tracker") and dockFrame or popoutFrame
                    if f then
                        f:ClearAllPoints()
                        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
                        db.gpsPopout = { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = left, y = top }
                    end
                end
            end
        end
    end
    return {
        { kind = "title", label = L["GPS_STYLE"] },
        { kind = "radio", label = L["GPS_STYLE_EASYFIND"], value = "easyfind", get = PopoutStyle, set = pick("easyfind") },
        { kind = "radio", label = L["GPS_STYLE_TRACKER"], value = "tracker", get = PopoutStyle, set = pick("tracker") },
    }
end

function GPS:Dock(slot)
    if not Tracker() then return false end
    HideMenus()
    dockFrame = dockFrame or BuildDock()
    local db = DB()
    if db then
        db.gpsDocked = true
        if slot then db.gpsDockSlot = slot end
    end
    if popoutFrame then popoutFrame:Hide() end
    dockFrame.docked = true
    dockFrame.floating = nil
    dockFrame:Show()
    RenderDock(dockFrame)
    local t = Tracker()
    if t and t.MarkDirty then t:MarkDirty() end
    return true
end

-- keepShown: the section stays on screen (about to float, or being dragged).
-- Hiding a frame in its own drag-stop re-fires the handler and kills its grip until reload.
function GPS:Undock(keepShown)
    HideMenus()
    local db = DB()
    if db then db.gpsDocked = nil end
    if dockFrame then
        dockFrame.docked = nil
        dockFrame.ghost = nil
        if not keepShown then dockFrame:Hide() end
        dockFrame:SetFrameStrata("LOW")
        local t = Tracker()
        ClearInsert(t)   -- the sections close ranks, now
        if t then TrackerRelayout(t) end
    end
end

-- Section and tracker geometry for the dev readout.
function GPS.DockStatus()
    local out = {}
    if dockFrame then
        local d = dockFrame
        local ins = d.insert
        out[#out + 1] = sformat("section: shown %s alpha %.1f strata %s | docked %s floating %s ghost %s dragging %s | size %.0fx%.0f | room on %s height %s pad %s",
            tostring(d:IsShown()), d:GetAlpha() or 1, tostring(d:GetFrameStrata()), tostring(d.docked == true), tostring(d.floating == true),
            tostring(d.ghost == true), tostring(d.dragging == true), d:GetWidth() or 0, d:GetHeight() or 0,
            ins and ins.module and (ins.module:GetName() or "?") or "none", tostring(ins and ins.height), tostring(ins and ins.pad))
        local t = Tracker()
        if t then
            local mods = VisibleModules(t)
            local parts = {}
            for i = 1, #mods do
                local m = mods[i]
                parts[#parts + 1] = sformat("%s top %.0f bottom %.0f w %.0f", m:GetName() or "?", m:GetTop() or 0, m:GetBottom() or 0, m:GetWidth() or 0)
            end
            out[#out + 1] = sformat("tracker: %s | section top %s bottom %s", table.concat(parts, "; "), tostring(d:GetTop() and math.floor(d:GetTop())), tostring(d:GetBottom() and math.floor(d:GetBottom())))
        end
    end
    return out
end

-- The pop-out

PopoutSize = function()
    local db = DB()
    local size = db and db.gpsPopoutSize or {}
    return size.w or 300, size.h
end

local function SetPopoutSize(w, h)
    local db = DB()
    if not db then return end
    db.gpsPopoutSize = { w = w, h = h }
    if popoutFrame then
        popoutFrame:SetWidth(w)
        popoutFrame.scrollOffset = 0
        popoutFrame:Render()
    end
end

-- The cog's popup: width and height as radio rows, the menu convention.
local function ShowSizePopup(anchor)
    if not ns.ShowTogglePopup then return end
    local defs = {}
    for _, d in ipairs(GPS.StyleRows()) do defs[#defs + 1] = d end
    defs[#defs + 1] = { kind = "separator" }
    defs[#defs + 1] = { kind = "title", label = L["GPS_SIZE_WIDTH"] }
    for i = 1, #SIZE_WIDTHS do
        local px, key = SIZE_WIDTHS[i][1], SIZE_WIDTHS[i][2]
        defs[#defs + 1] = { kind = "radio", label = L[key], value = px,
            get = function() return (select(1, PopoutSize())) end,
            set = function() SetPopoutSize(px, (select(2, PopoutSize()))) end }
    end
    defs[#defs + 1] = { kind = "separator" }
    defs[#defs + 1] = { kind = "check", label = L["GPS_SIZE_BORDER"],
        get = function() local db = DB() return db and db.gpsPopoutBorder ~= false end,
        set = function(v)
            local db = DB()
            -- Not "v and nil or false": that is false for both values.
            if db then
                if v then db.gpsPopoutBorder = nil else db.gpsPopoutBorder = false end
            end
            if popoutFrame then
                popoutFrame:ApplyBorderShape(v)
                popoutFrame:Render()
            end
        end }
    defs[#defs + 1] = { kind = "check", label = L["GPS_SIZE_WRAP"],
        get = function() local db = DB() return db and db.gpsWrapSteps == true end,
        set = function(v)
            local db = DB()
            if db then db.gpsWrapSteps = v or nil end
            Refresh()
        end }
    defs[#defs + 1] = GPS.WorldPinRow()
    defs[#defs + 1] = GPS.SnapRow()
    defs[#defs + 1] = { kind = "separator" }
    defs[#defs + 1] = { kind = "title", label = L["GPS_SIZE_HEIGHT"] }
    for i = 1, #SIZE_HEIGHTS do
        local px, key = SIZE_HEIGHTS[i][1], SIZE_HEIGHTS[i][2]
        defs[#defs + 1] = { kind = "radio", label = L[key], value = px or 0,
            get = function() return (select(2, PopoutSize())) or 0 end,
            set = function() SetPopoutSize((select(1, PopoutSize())), px) end }
    end
    ns.ShowTogglePopup("EasyFindGPSSizePopup", anchor, defs, {})
end

local function BuildPopout()
    local f = CreateFrame("Frame", "EasyFindGPSPopout", UIParent, "BackdropTemplate")
    f:SetSize((PopoutSize()), 120)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    local function BeginWindowDrag(self)
        self.dragging = true
        self:StartMoving()
        if Tracker() then dockFrame = dockFrame or BuildDock() end
    end
    local function EndWindowDrag(self)
        self:StopMovingOrSizing()
        self.dragging = nil
        local near = Tracker() and NearTracker(self)
        local slot = near and SlotAt(self:GetTop() or 0) or nil
        DragGap(nil)
        HideSectionGhost(self)
        -- Dropped on the objective tracker: it docks at the spot it was dropped.
        if near and GPS:Dock(slot) then return end
        -- Kept by its top-left corner, so a height change grows or
        -- shrinks the bottom edge and the header stays put.
        local left, top = self:GetLeft(), self:GetTop()
        if left and top then
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
            local db = DB()
            if db then db.gpsPopout = { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = left, y = top } end
        end
    end
    f:SetScript("OnDragStart", BeginWindowDrag)
    f:SetScript("OnDragStop", EndWindowDrag)
    f.BeginWindowDrag, f.EndWindowDrag = BeginWindowDrag, EndWindowDrag
    -- The results window's own panel object: rounded rect, theme fill,
    -- opacity setting, live restyle on a theme flip.
    ns.StyleMenuPanel(f)
    ns.SetRoundedRectBarHeight(f, 14)
    -- The quest log's border, as around the map search panel. The template
    -- anchors itself a few pixels outside its parent; decorative only.
    local border = CreateFrame("Frame", nil, f, "QuestLogBorderFrameTemplate")
    border:SetFrameLevel(f:GetFrameLevel() + 2)
    border:EnableMouse(false)
    -- The template hangs 7 pixels above and 6 below its parent, made for
    -- the quest log's paper. Here it hugs the panel: 3 pixels all round.
    border:ClearAllPoints()
    border:SetPoint("TOPLEFT", f, "TOPLEFT", -4, 4)
    border:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 4, -4)
    -- Nine-slice instead of the template's one stretched atlas (squashed on a short
    -- window). A thin band: the rim only, the atlas's inner shadow read as a dark strip.
    local BAND = 8
    local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("questlog-frame")
    if info and info.file and info.width and info.height and border.Border then
        border.Border:Hide()
        local l, r, t, b = info.leftTexCoord, info.rightTexCoord, info.topTexCoord, info.bottomTexCoord
        local du, dv = (r - l) * BAND / info.width, (b - t) * BAND / info.height
        local function piece(u0, u1, v0, v1)
            local tex = border:CreateTexture(nil, "BORDER")
            tex:SetTexture(info.file)
            tex:SetTexCoord(l + u0 * (r - l), l + u1 * (r - l), t + v0 * (b - t), t + v1 * (b - t))
            return tex
        end
        local cu, cv = du / (r - l), dv / (b - t)   -- the band as a fraction of the atlas
        local tl, tr, bl, br = piece(0, cu, 0, cv), piece(1 - cu, 1, 0, cv), piece(0, cu, 1 - cv, 1), piece(1 - cu, 1, 1 - cv, 1)
        local top, bottom = piece(cu, 1 - cu, 0, cv), piece(cu, 1 - cu, 1 - cv, 1)
        local left, right = piece(0, cu, cv, 1 - cv), piece(1 - cu, 1, cv, 1 - cv)
        for _, c in ipairs({ tl, tr, bl, br }) do c:SetSize(BAND, BAND) end
        tl:SetPoint("TOPLEFT"); tr:SetPoint("TOPRIGHT"); bl:SetPoint("BOTTOMLEFT"); br:SetPoint("BOTTOMRIGHT")
        top:SetPoint("TOPLEFT", tl, "TOPRIGHT"); top:SetPoint("BOTTOMRIGHT", tr, "BOTTOMLEFT")
        bottom:SetPoint("TOPLEFT", bl, "TOPRIGHT"); bottom:SetPoint("BOTTOMRIGHT", br, "BOTTOMLEFT")
        left:SetPoint("TOPLEFT", tl, "BOTTOMLEFT"); left:SetPoint("BOTTOMRIGHT", bl, "TOPRIGHT")
        right:SetPoint("TOPLEFT", tr, "BOTTOMLEFT"); right:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT")
    end
    f.border = border
    -- With the square quest-log border the fill is square too (1-pixel corner):
    -- rounded corners curve away from its straight edges.
    function f:ApplyBorderShape(on)
        if self.border then self.border:SetShown(on) end
        if ns.SetRoundedRectRingShown then ns.SetRoundedRectRingShown(self, on) end
        ns.SetRoundedRectBarHeight(self, on and 2 or 14)
    end
    local db0 = DB()
    f:ApplyBorderShape(not (db0 and db0.gpsPopoutBorder == false))

    -- The calculator's stroke close, not a stock round button.
    local close = CreateFrame("Button", nil, f)
    close:SetSize(18, 18)
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -10)
    local function stroke()
        local tex = close:CreateTexture(nil, "OVERLAY")
        tex:SetTexture("Interface\\Buttons\\WHITE8x8")
        tex:SetSize(14, 1.5)
        tex:SetPoint("CENTER")
        return tex
    end
    local s1, s2 = stroke(), stroke()
    s1:SetRotation(mpi / 4)
    s2:SetRotation(-mpi / 4)
    local function tint(r, g, b)
        s1:SetVertexColor(r, g, b, 1)
        s2:SetVertexColor(r, g, b, 1)
    end
    tint(unpack(ns.TEXT_DIM))
    close:SetScript("OnEnter", function() tint(1, 1, 1) end)
    close:SetScript("OnLeave", function() tint(unpack(ns.TEXT_DIM)) end)
    close:SetScript("OnClick", function() GPS:TogglePopout(false) end)
    f.closeBtn = close

    -- Header top padding: 9 open, 5 folded (one tight title row).
    -- The rest of the header hangs off the glyph and the close.
    function f:SetHeaderPad(pad)
        self.glyph:ClearAllPoints()
        self.glyph:SetPoint("TOPLEFT", self, "TOPLEFT", 12, -pad)
        -- The close (18 tall) centered on the icon (20 tall); the other
        -- buttons and the search box center on those two.
        close:ClearAllPoints()
        close:SetPoint("TOPRIGHT", self, "TOPRIGHT", -8, -(pad + 1))
    end

    -- Left of the close: maximize, back to the GPS page on the map. A
    -- square outline in the close's stroke style.
    local maximize = CreateFrame("Button", nil, f)
    maximize:SetSize(18, 18)
    maximize:SetPoint("CENTER", close, "CENTER", -24, 0)
    local edges = {}
    local function edge(w, h, point, x, y)
        local tex = maximize:CreateTexture(nil, "OVERLAY")
        tex:SetTexture("Interface\\Buttons\\WHITE8x8")
        tex:SetSize(w, h)
        tex:SetPoint(point, maximize, "CENTER", x, y)
        edges[#edges + 1] = tex
    end
    edge(11, 1.5, "TOP", 0, 5.5)
    edge(11, 1.5, "BOTTOM", 0, -5.5)
    edge(1.5, 11, "LEFT", -5.5, 0)
    edge(1.5, 11, "RIGHT", 5.5, 0)
    local function tintMax(r, g, b)
        for i = 1, #edges do edges[i]:SetVertexColor(r, g, b, 1) end
    end
    tintMax(unpack(ns.TEXT_DIM))
    maximize:SetScript("OnEnter", function() tintMax(1, 1, 1) end)
    maximize:SetScript("OnLeave", function() tintMax(unpack(ns.TEXT_DIM)) end)
    maximize:SetScript("OnClick", function()
        if ns.MapTab and ns.MapTab.ShowPage then ns.MapTab:ShowPage("gps") end
    end)
    f.maximize = maximize

    -- Then minimize: the window folds to its title line and back. One
    -- stroke when open, a plus when folded.
    local collapse = CreateFrame("Button", nil, f)
    collapse:SetSize(18, 18)
    collapse:SetPoint("CENTER", maximize, "CENTER", -24, 0)
    local bar = collapse:CreateTexture(nil, "OVERLAY")
    bar:SetTexture("Interface\\Buttons\\WHITE8x8")
    bar:SetSize(11, 1.5)
    bar:SetPoint("CENTER")
    local post = collapse:CreateTexture(nil, "OVERLAY")
    post:SetTexture("Interface\\Buttons\\WHITE8x8")
    post:SetSize(1.5, 11)
    post:SetPoint("CENTER")
    local function tintFold(r, g, b)
        bar:SetVertexColor(r, g, b, 1)
        post:SetVertexColor(r, g, b, 1)
    end
    tintFold(unpack(ns.TEXT_DIM))
    collapse:SetScript("OnEnter", function() tintFold(1, 1, 1) end)
    collapse:SetScript("OnLeave", function() tintFold(unpack(ns.TEXT_DIM)) end)
    collapse:SetScript("OnClick", function()
        f.collapsed = not f.collapsed or nil
        local db = DB()
        if db then db.gpsPopoutCollapsed = f.collapsed end
        post:SetShown(f.collapsed == true)
        f:Render()
    end)
    local db1 = DB()
    f.collapsed = db1 and db1.gpsPopoutCollapsed or nil
    post:SetShown(f.collapsed == true)
    f.collapseBtn = collapse
    -- The saved fold state, shared with the tracker section.
    f.SyncFold = function(self)
        local db = DB()
        self.collapsed = db and db.gpsPopoutCollapsed or nil
        post:SetShown(self.collapsed == true)
    end

    -- Settings on a right-click anywhere on the window, the menu at the cursor;
    -- no cog in the header.
    local menuAnchor = CreateFrame("Frame", nil, f)
    menuAnchor:SetSize(1, 1)
    local function ShowWindowMenu()
        local cx, cy = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        menuAnchor:ClearAllPoints()
        menuAnchor:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", cx / scale, cy / scale)
        ShowSizePopup(menuAnchor)
    end
    f:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then ShowWindowMenu() end
    end)
    f.ShowMenu = ShowWindowMenu
    f.menuAnchor = menuAnchor

    BuildSurface(f, {
        padX = 12, padY = 9, padRight = 84, bodyPadRight = 12, search = true, compact = true, titleOpensMap = true, trackGlyph = true,
        onRouteChanged = function(self)
            -- The fold button folds a route; with none there is nothing to fold.
            if self.collapseBtn then self.collapseBtn:SetShown(Route() ~= nil) end
            local tight = (not Route() and (self.hitCount or 0) == 0) or (self.collapsed and Route())
            if tight then
                -- One tight title row: a folded route, or no route, where the row
                -- holds the search box and typed results unfold below.
                self:SetHeaderPad(8)
                self:SetHeight(8 + 20 + 8)   -- the icon's 20 pixels, padded
                self.list:Hide(); self.eta:Hide(); self.clearBtn:Hide(); self.empty:Hide()
                if self.search then
                    self.search:SetShown(not Route())
                    self.hitList:Hide()
                end
                return
            end
            self.list:Show()
            self:SetHeaderPad(9)
            local _, fixed = PopoutSize()
            local head = 9 + 20 + 8   -- pad, the icon, gap
            local line = 4 + 14 + 8   -- the time line under the name
            local h
            if Route() then
                h = head + line + (self.contentHeight or 0) + 4   -- the last row carries its own padding
            elseif (self.hitCount or 0) > 0 then
                h = head + (math.min(self.hitCount, HIT_ROWS) * ROW_H) + 12
            elseif self.search then
                h = head + 4   -- the search box alone, in the header row
            else
                h = head + 2 + (self.empty:GetStringHeight() or 24) + 14
            end
            if fixed then
                -- A fixed height: the step list, or the hits, scroll inside it.
                self:SetHeight(fixed)
                if not Route() and (self.hitCount or 0) > 0 then self:SetHitView(fixed - head - 12) end
                local avail = fixed - (head + line + 12)
                self.list:SetHeight(mmax(1, math.min(self.contentHeight or 0, avail)))
                self.list:SetClipsChildren(true)
            else
                self:SetHeight(mmax(60, h))
                if not Route() and (self.hitCount or 0) > 0 then self:SetHitView(HIT_ROWS * ROW_H) end
                self.list:SetClipsChildren(false)
                self.scrollOffset = 0
            end
        end,
    })
    -- While the window is dragged over the tracker, the tracker opens the
    -- gap the section would take.
    local dragSince = 0
    f:SetScript("OnUpdate", function(self, dt)
        if not self.dragging then return end
        dragSince = dragSince + dt
        if dragSince < 0.05 then return end
        dragSince = 0
        if NearTracker(self) then
            if dockFrame then
                ShowSectionGhost(self)
                DragGap(self, dockFrame:GetHeight() or DOCK_HEADER_H)
            end
        else
            DragGap(nil)
            HideSectionGhost(self)
        end
    end)
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(self, delta)
        local _, fixed = PopoutSize()
        if not fixed or not Route() then return end
        local avail = self.list:GetHeight() or 0
        local maxOffset = mmax(0, (self.contentHeight or 0) - avail)
        self.scrollOffset = math.max(0, math.min(maxOffset, (self.scrollOffset or 0) - delta * ROW_H))
        self:Render()
    end)

    -- No Escape close: the window is a companion that stays put; only its
    -- own close button hides it.

    local db = DB()
    local pos = db and db.gpsPopout
    if pos and pos.point == "TOPLEFT" then
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.x or 0, pos.y or 0)
    else
        f:SetPoint("TOPRIGHT", UIParent, "RIGHT", -40, 200)
    end
    f:Hide()
    return f
end

function GPS.EnsurePopout()
    popoutFrame = popoutFrame or BuildPopout()
    return popoutFrame
end

function GPS:TogglePopout(show)
    HideMenus()
    if PopoutStyle() == "tracker" and Tracker() then
        -- The window is the section, floating.
        local open = dockFrame and dockFrame.floating and dockFrame:IsShown()
        if show == nil then show = not open end
        if show then
            if GPS:IsDocked() then GPS:Undock() end
            if popoutFrame then popoutFrame:Hide() end
            GPS.FloatDockAt()
        elseif dockFrame and dockFrame.floating then
            dockFrame.floating = nil
            dockFrame:Hide()
        end
        local c = CharDB()
        if c then c.popoutOpen = show or nil end
        return
    end
    popoutFrame = popoutFrame or BuildPopout()
    if show == nil then show = not popoutFrame:IsShown() end
    if show and GPS:IsDocked() then GPS:Undock() end
    if show and dockFrame and dockFrame.floating then dockFrame.floating = nil dockFrame:Hide() end
    popoutFrame:SetShown(show)
    if show and popoutFrame.SyncFold then popoutFrame:SyncFold() end
    if show then popoutFrame:Render() end
    -- Open or closed survives a reload, like the route does.
    local c = CharDB()
    if c then c.popoutOpen = show or nil end
end

-- Login: a route saved before a reload picks up where it was

-- A hearth is learned as it happens: the cast of any bind-based ability
-- in the data, then the loading screen, then where the character stands.
local hearthSpells
local function IsHearthSpell(spellID)
    if not hearthSpells then
        hearthSpells = {}
        for _, a in ipairs(ns.GPSData and ns.GPSData.abilities or {}) do
            if a.bind and a.id then hearthSpells[a.id] = true end
        end
        hearthSpells[556] = true   -- Astral Recall lands at the bind too
    end
    return hearthSpells[spellID] == true
end
local hearthCastAt

-- Flight masters seen as known at a flight master: covers a client whose
-- world map listing cannot say.
local function RecordKnownFlights()
    local c = CharDB()
    local mapID = GetTaxiMapID and GetTaxiMapID()
    if not (c and mapID and C_TaxiMap and C_TaxiMap.GetAllTaxiNodes and Enum and Enum.FlightPathState) then return end
    local ok, list = pcall(C_TaxiMap.GetAllTaxiNodes, mapID)
    if not (ok and list) then return end
    local state = Enum.FlightPathState
    c.flights = c.flights or {}
    local here, open, learned = nil, {}, false
    for i = 1, #list do
        local n = list[i]
        if n.nodeID and (n.state == state.Current or n.state == state.Reachable) then
            if not c.flights[n.nodeID] then learned = true end
            c.flights[n.nodeID] = true
            open[n.nodeID] = true
            if n.state == state.Current then here = n.nodeID end
        end
    end
    local Engine = ns.GPSRoute
    if Engine then
        Engine.recordedKnown = c.flights
        Engine.ForgetKnown()
    end
    -- Replan from here when this master's answer differs from the plan:
    -- newly learned, or a planned flight it does not offer.
    local route = c.route
    if not (route and route.dest and not route.arrived) then return end
    local stale = learned
    for i = route.active or 1, #route.steps do
        local s = route.steps[i]
        if s.kind == "taxi" and s.nodeID == here and not (s.toID and open[s.toID]) then stale = true end
    end
    if not stale then return end
    if route.via and c.flights[route.via.id] then route.via = nil end
    local steps, total, advice = GPS:BuildRoute(route.dest, route.via)
    if not steps then
        route.via = nil
        steps, total, advice = GPS:BuildRoute(route.dest)
    end
    route.steps, route.eta, route.total, route.advice, route.t, route.there = steps, total, total, advice, time(), nil
    closing.step = nil
    TrackStep(1)
end

-- This character's mounted pace on the ground, the fastest seen.
SampleGroundSpeed = function()
    if not (IsMounted and IsMounted()) or (UnitOnTaxi and UnitOnTaxi("player")) then return end
    if (IsFlying and IsFlying()) or (IsSwimming and IsSwimming()) then return end
    local ok, speed = pcall(GetUnitSpeed, "player")
    if not (ok and speed) or speed <= 7.5 or speed > 40 then return end
    local c = CharDB()
    if c and (not c.groundSpeed or speed > c.groundSpeed + 0.05) then
        c.groundSpeed = speed
        if ns.GPSRoute then ns.GPSRoute.seenGroundSpeed = speed end
    end
end

-- The GPS page in the options' Extensions tab: how the beacon looks, or
-- no beacon (the same switch as the beacon row in the GPS menu).
local function BuildOptionsPage(ctx, page)
    local WorldPin = ns.GPSWorldPin
    local choices = {
        { label = L["GPS_BEACON_CALM"], value = "calm" },
        { label = L["GPS_BEACON_FLAME"], value = "flame" },
        { label = _G["OFF"] or "Off", value = "off" },
    }
    local row = ctx.CreateFlyoutPresetRow(page, L["GPS_BEACON_STYLE"], choices,
        function()
            local db = DB()
            if db and db.gpsWorldPin == false then return "off" end
            return WorldPin and WorldPin.Style() or "calm"
        end,
        function(v)
            local db = DB()
            if not db then return end
            db.gpsWorldPin = (v == "off") and false or nil
            if v ~= "off" then db.gpsBeaconStyle = v end
            Refresh()
        end,
        "EasyFindGPSBeaconStyle", WorldPin and WorldPin.DefaultStyle() or "calm", L["GPS_BEACON_STYLE_TT"])
    row:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -8)
end

if ns.RegisterExtensionPage then
    ns.RegisterExtensionPage({ id = "gps", name = L["APP_GPS"], icon = ns.GPS_ICON_TEX, companion = "EasyFind_GPS", build = BuildOptionsPage })
end

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("TAXIMAP_OPENED")
loginFrame:RegisterEvent("HEARTHSTONE_BOUND")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
loginFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
loginFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
loginFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
loginFrame:SetScript("OnEvent", function(self, event, unit, _, spellID)
    if event == "PLAYER_REGEN_ENABLED" then
        Refresh()   -- the cast icons hidden for combat come back
        return
    end
    -- The last moment before the lockdown a secure button may still hide.
    if event == "PLAYER_REGEN_DISABLED" then
        for i = 1, #castButtons do
            castButtons[i]:Hide()
            castButtons[i]:ClearAllPoints()
        end
        return
    end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if IsHearthSpell(spellID) then hearthCastAt = GetTime() end
        local route = Route()
        local step = route and not route.arrived and route.steps[route.active or 1]
        if step and step.kind == "teleport" and step.spellID == spellID then route.castAt = GetTime() end
        return
    end
    if event == "TAXIMAP_OPENED" then
        Utils.SafeAfter(0, RecordKnownFlights)
        return
    end
    -- Bound at an innkeeper: where the character stands is where a hearth lands.
    if event == "HEARTHSTONE_BOUND" then
        Utils.SafeAfter(0.5, LearnHearth)
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        if hearthCastAt and GetTime() - hearthCastAt < 90 then
            hearthCastAt = nil
            Utils.SafeAfter(1.5, LearnHearth)
        end
        return
    end
    self:UnregisterEvent("PLAYER_LOGIN")
    local db = DB()
    local cc = CharDB()
    if cc and ns.GPSRoute then
        ns.GPSRoute.recordedKnown = cc.flights
        ns.GPSRoute.seenGroundSpeed = cc.groundSpeed
    end
    -- Routes once lived on the account; one left there is dropped, not
    -- handed to whichever character logs in next.
    if db then db.gpsRoute, db.gpsPopoutOpen = nil, nil end
    local c = CharDB()
    if db and db.gpsDocked then
        GPS:Dock()
    elseif c and c.popoutOpen then
        GPS:TogglePopout(true)
    end
    local route = Route()
    if not route then return end
    -- A route is for the trip in progress; one left from another day is
    -- noise, not directions.
    if route.arrived or (time() - (route.t or 0)) > ROUTE_MAX_AGE then
        if c then c.route = nil end
        return
    end
    StartTicker()
end)
