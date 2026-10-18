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

-- Arrival rings: a step's spot; the last step to a creature or other spot
-- (beside it); a crossing's far spot, where it drops you, give or take.
local ARRIVE = { yards = 40, spot = 8, cross = 300 }
local ROUTE_MAX_AGE = 2 * 60 * 60
local ARRIVED_LINGER = 20
local START_YARDS = 60      -- this close to a planned route's start, the player is on it
local ROW_H = 22
-- Beside the map the steps read at the quest log's size and follow the map
-- search's font size choice; the windows keep their small type.
local MAP_STEP_PX = 13
local function MapScale(container)
    return container.mapFont and ((EasyFind.db and EasyFind.db.mapTabFontSize) or 1) or nil
end
local function SizeFont(fs, px)
    local file, _, flags = fs:GetFont()
    if file then fs:SetFont(file, px, flags) end
end
-- The trip editor sizes its text as the page's steps.
GPS.SizeFont = SizeFont
function GPS.MapTextPx(container)
    local scale = MapScale(container)
    return scale and MAP_STEP_PX * scale or nil
end
local HIT_ROWS = 8            -- results shown under the pop-out's search box
-- Pop-out sizes on offer: the cog's radio rows. A nil height fits the steps.
local SIZE_WIDTHS = { { 240, "GPS_SIZE_NARROW" }, { 300, "GPS_SIZE_NORMAL" }, { 380, "GPS_SIZE_WIDE" }, { 460, "GPS_SIZE_WIDER" } }
local SIZE_HEIGHTS = { { nil, "GPS_SIZE_FIT" }, { 160, "GPS_SIZE_SHORT" }, { 240, "GPS_SIZE_MEDIUM" }, { 340, "GPS_SIZE_TALL" } }

local ticker
local surfaces = {}     -- every container that renders the route
GPS.Surfaces = function() return surfaces end   -- dev tools
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

-- A start other than where the player stands ({ name, mapID, x, y }), set
-- from the From line or a result's Route from here; nil: the player's spot.
local function Start()
    local c = CharDB()
    return c and c.start
end
GPS.Start = Start   -- the trip editor's first field

-- The search box's hint: picking a start, where to from a start, or plain.
local function SearchHint(frame)
    local box = frame.search
    if not (box and box.Instructions) then return end
    local s = Start()
    if GPS.picking == frame then
        box.Instructions:SetText(L["GPS_FROM_PLACEHOLDER"])
    elseif GPS.along == frame then
        box.Instructions:SetText(L["GPS_ALONG"])
    elseif s and not Route() then
        box.Instructions:SetText(sformat(L["GPS_SEARCH_FROM_FMT"], s.name or "?"))
    else
        box.Instructions:SetText(L["GPS_SEARCH_PLACEHOLDER"] or SEARCH or "Search")
    end
end

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

-- Whether a left-click on a spot pinned on the world map starts the GPS
-- there (the setting's default) rather than placing the game's waypoint.
function GPS.MapClickNavigates()
    local db = DB()
    return db ~= nil and db.gpsMapClick ~= "pin"
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

-- Instances carry isZone in search, but their entrance is the spot to reach.
local INSTANCE_CATEGORIES = { dungeon = true, raid = true, delve = true }

local function Destination(data)
    local dest = { name = data.name, icon = data.icon, category = data.category, displayID = data.displayID }
    local em, ex, ey
    if data.isDungeonEntrance and not (data.x and data.y) then em, ex, ey = EntranceOf(data) end
    if em then
        dest.mapID, dest.x, dest.y = em, ex, ey
    elseif data.x and data.y and data.mapID then
        dest.mapID, dest.x, dest.y = data.mapID, data.x, data.y
    else
        -- A zone or a continent itself, not a spot on it: reached on entering it.
        dest.mapID, dest.x, dest.y = data.zoneMapID or data.mapID, 0.5, 0.5
        if data.isZone and not INSTANCE_CATEGORIES[data.category] then dest.zone = true end
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

local function SplitWalks(steps, dest, origin)
    local Route = ns.GPSRoute
    local ci, wx, wy
    if origin then ci, wx, wy = origin.ci, origin.wx, origin.wy else ci, wx, wy = PlayerWorldPos() end
    if not (Route and Route.SplitWalks and ci and C_Map.GetMapPosFromWorldPos) then return steps end
    local here = origin and origin.m or C_Map.GetBestMapForUnit("player")
    continentOf[ci] = continentOf[ci] or ContinentAbove(here)
    for i = 1, #steps do
        local p = steps[i].arrive
        if p and p.ci and p.m and not continentOf[p.ci] then continentOf[p.ci] = ContinentAbove(p.m) end
    end
    local start = { ci = ci, wx = wx, wy = wy }
    local hereInfo = here and IsCity(here) and C_Map.GetMapInfo(here)
    local ok, out = pcall(Route.SplitWalks, steps, start, ns.GPSData, {
        zoneAt = ZoneAt, mapPos = MapPos, isCity = IsCity,
        startCity = hereInfo and { map = here, name = hereInfo.name } or nil,
        goalZone = dest.zone and dest.mapID or nil,
    })
    if ok and out and #out > 0 then return out end
    return steps
end

-- The start as a world point { m, x, y, ci, wx, wy }, or nil for the player.
local function StartPoint()
    local s = Start()
    if not s then return nil end
    local ci, wx, wy = WorldPos(s.mapID, s.x, s.y)
    if not ci then return nil end
    return { m = s.mapID, x = s.x, y = s.y, ci = ci, wx = wx, wy = wy }
end

-- avoid: ways to leave out, the settings' by default; quick: no advice;
-- draw: "first" draws the walk set out on (a route to show), nothing
-- otherwise (a route to compare).
-- The flight points the player dropped from the trip dest belongs to.
function GPS.SkipFor(dest)
    local route = Route()
    if not (route and route.skipLearn and dest) then return nil end
    for _, s in ipairs(route.stops or { route.dest }) do
        if s.name == dest.name and s.mapID == dest.mapID then return route.skipLearn end
    end
    return nil
end

function GPS:BuildRoute(dest, via, avoid, quick, draw, startFrom)
    local Route = ns.GPSRoute
    local origin = startFrom or StartPoint()
    if Route and ns.GPSData then
        local h = HearthPoint()
        local db = DB()
        local opts = { hearth = h and { point = h } or nil, via = via, avoid = avoid or (db and db.gpsAvoid) or nil,
                       start = origin, draw = draw,
                       autoLearn = not (db and db.gpsAutoLearn == false), skipLearn = GPS.SkipFor(dest) }
        if quick then opts.advise = false end
        local ok, steps, advice, _
        local co = coroutine.running()
        local Nav = ns.GPSNav
        if co then
            if Nav then Nav.yieldCo = co end
            steps, _, advice = Route.Build(Route, dest, opts)
            if Nav then Nav.yieldCo = nil end
            ok = true
        else
            ok, steps, _, advice = pcall(Route.Build, Route, dest, opts)
        end
        if ok and steps and #steps > 0 then
            for i = 1, #steps do steps[i].name = steps[i].name or dest.name end
            steps = SplitWalks(steps, dest, origin)
            -- A walk to a zone ends at its border: the total follows the split.
            local total = 0
            for i = 1, #steps do total = total + (steps[i].sec or 0) end
            return steps, total, advice
        end
        if via then return nil end   -- no way with that stop: the route stays as it was
    end
    -- No way through the data: a plain leg, priced as the crow flies when
    -- the spot is on this continent, unpriced when it is not.
    local sec
    local Engine = ns.GPSRoute
    local ci, px, py
    if origin then ci, px, py = origin.ci, origin.wx, origin.wy else ci, px, py = PlayerWorldPos() end
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

GPS.WorldPos = WorldPos   -- the trip's legs start at a stop's world spot

-- The route's stops planned leg by leg (Trip.lua); one stop is the route itself.
function GPS:BuildStops(route, via, avoid, quick, draw)
    local Trip = ns.GPSTrip
    if Trip and route.stops and #route.stops > 1 then return Trip.Build(route.stops, via, avoid, quick, draw) end
    return self:BuildRoute(route.dest, via, avoid, quick, draw)
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
    if ns.GPSArrow then ns.GPSArrow:Refresh() end
    if ns.GPSMinimap then ns.GPSMinimap:Refresh() end
end
GPS.RefreshSurfaces = Refresh

-- Plans run a slice a frame, so a long one never stalls the game: a bigger
-- slice for the plan someone waits on (a route to show), a smaller one for
-- the work after it. One at a time: a newer plan replaces one still
-- running. A plan that fails runs once more at once, guarded, so its
-- fallback still comes.
local PLAN_BUDGET_MS, PLAN_BUDGET_BACK_MS = 12, 6
local Planner = { frame = CreateFrame("Frame"), IDLE_RELEASE = 60 }

-- A minute after the last plan the grid's decoded data goes (Nav.Release);
-- what the arrow still reads stays, and the check comes round again
-- while anything is held.
function Planner.ReleaseLater()
    if Planner.releaseWaits then return end
    Planner.releaseWaits = true
    Utils.SafeAfter(Planner.IDLE_RELEASE, function()
        Planner.releaseWaits = false
        local Nav = ns.GPSNav
        if GPS:IsPlanning() or (Nav and Nav.Release(Planner.IDLE_RELEASE)) then Planner.ReleaseLater() end
    end)
end

local function PlanStep()
    local co = Planner.co
    if not co then
        Planner.frame:SetScript("OnUpdate", nil)
        return
    end
    local Nav = ns.GPSNav
    if Nav then Nav.sliceEnd = debugprofilestop() + (GPS.planning and PLAN_BUDGET_MS or PLAN_BUDGET_BACK_MS) end
    local before = collectgarbage("count")
    local ok, a, b, c = coroutine.resume(co)
    if Nav then Nav.sliceEnd = nil end
    -- The collector keeps pace with the slice: what the plan left behind
    -- goes now, not once the heap has doubled.
    local grew = collectgarbage("count") - before
    if grew > 0 then collectgarbage("step", mfloor(grew)) end
    if coroutine.status(co) ~= "dead" or Planner.co ~= co then return end
    Planner.co = nil
    Planner.frame:SetScript("OnUpdate", nil)
    local done, build = Planner.done, Planner.build
    Planner.done, Planner.build = nil, nil
    GPS.planning = nil
    if not ok then
        Utils.ErrorHandler(a)
        a, b, c = build()
    end
    done(a, b, c)
    Refresh()
    Planner.ReleaseLater()
end

-- build() runs in the plan; done gets what it returns. name: the place the
-- surfaces say a way is being found to.
function GPS:Plan(name, build, done)
    Planner.co = coroutine.create(build)
    Planner.done, Planner.build = done, build
    GPS.planning = name and { name = name } or nil
    Refresh()
    Planner.frame:SetScript("OnUpdate", PlanStep)
    PlanStep()
end

function GPS:IsPlanning() return Planner.co ~= nil end

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

-- The game's pin off the map, when it is still ours on this step's end.
local function LiftPin(route)
    local step = route and route.steps and route.steps[route.active or 1]
    local mapID, x, y
    if step then mapID, x, y = WaypointPoint(step) end
    local wp = mapID and C_Map and C_Map.GetUserWaypoint and C_Map.GetUserWaypoint()
    if not (wp and wp.uiMapID == mapID and wp.position) then return end
    if math.abs(wp.position.x - x) > 0.001 or math.abs(wp.position.y - y) > 0.001 then return end
    if ns.MapSearch and ns.MapSearch.SetEasyFindWaypointPlaced then ns.MapSearch:SetEasyFindWaypointPlaced(false) end
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(false) end
    if C_Map.ClearUserWaypoint then C_Map.ClearUserWaypoint() end
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
-- A timed boat's next departure from its stop, as "leaves in 1:20".
local function DepartureText(step)
    local Boats = ns.GPSBoats
    local wait = Boats and step.route and step.stop and Boats.WaitAt(step.route, step.stop, 0)
    if not wait then return nil end
    return sformat(L["GPS_LEAVES_IN_FMT"], sformat("%d:%02d", math.floor(wait / 60), math.floor(wait % 60)))
end

local function StepText(step, active)
    local departs = active and step and step.route and DepartureText(step)
    if departs then return (step.text or "") .. " " .. departs end
    if not (active and step and step.reach and step.go) or step.reached then return step and step.text or "" end
    local ci, px, py = PlayerWorldPos()
    local tci, tx, ty
    if step.go.wx then tci, tx, ty = step.go.ci, step.go.wx, step.go.wy
    else tci, tx, ty = WorldPos(step.go.m, step.go.x, step.go.y) end
    if ci and tci == ci and tx then
        local d = ((px - tx) ^ 2 + (py - ty) ^ 2) ^ 0.5
        if d > REACH_YARDS then return step.reachText or sformat(L["GPS_STEP_REACH_FMT"], step.reach) end
        -- Once there, moving away is the ride itself (the boat under way, the
        -- flight): the step keeps its own words.
        step.reached = true
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
    step.reached = nil
    -- A teleport counts as taken only once cast, or once off this continent.
    route.castAt = nil
    route.stepCi = PlayerWorldPos()
    -- The game's pin, at this step's end only: the beacon stands on it.
    local MapSearch = ns.MapSearch
    local mapID, x, y = WaypointPoint(step)
    if mapID and UiMapPoint and MapSearch and MapSearch.PlaceUserWaypoint then
        MapSearch:PlaceUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
        if not route.untracked and C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            C_SuperTrack.SetSuperTrackedUserWaypoint(true)
        end
        if MapSearch.RefreshAllClearButtons then MapSearch:RefreshAllClearButtons() end
    end
    Refresh()
    if ns.GPSPreview and ns.GPSPreview.Follow then ns.GPSPreview:Follow() end
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
    if route.report and route.report.t then route.tookSec = time() - route.report.t end
    StopTicker()
    LiftPin(route)
    local dest = route.dest
    if dest and EasyFind.db.autoPinClear ~= false and ns.MapSearch and ns.MapSearch.ClearPinAt then
        ns.MapSearch:ClearPinAt(dest.mapID, dest.x, dest.y)
    end
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

-- The step followed: the yards along its way at the last tick and when,
-- the yards and seconds moved since the step began (its speed, once
-- enough), what the last tick answered, and the estimate smoothed.
local closing = {}
local walkOpts = {}
local SPEED_AFTER_YARDS, SPEED_AFTER_SECONDS = 40, 6
local ETA_SMOOTH = 0.3

-- The time still to go, as a car's navigation reckons it: the way left to
-- the current step's spot along its drawn way, at the speed planned until
-- the speed seen on this step tells more (mounted under level 40, a buff),
-- then that step's crossing and every step after it, their walks at the
-- speed seen too. Off a drawn way the straight line stands in. Standing
-- still holds the estimate, and it is smoothed so the minute shown holds.
local function RemainingSeconds(route)
    local i = route.active or 1
    local step = route.steps[i]
    local Engine = ns.GPSRoute
    if not (step and Engine and Engine.TravelSeconds) then return route.eta end
    local now = GetTime and GetTime() or 0
    if closing.step ~= i then
        closing.step, closing.along, closing.at, closing.d = i, nil, nil, nil
        closing.moved, closing.secs, closing.speed, closing.held, closing.eta = 0, 0, nil, nil, nil
    end
    local planned = Engine.GroundSpeed(ns.GPSData)
    local total
    if step.kind == "teleport" then
        total = step.edgeSec or step.sec or 0
    else
        local onTaxi = step.kind == "taxi" and UnitOnTaxi and UnitOnTaxi("player")
        local f = not onTaxi and ns.GPSFollow and ns.GPSFollow.Now()
        local moved = false
        if f and f.path then
            if closing.at and now > closing.at then
                local gain = f.along - closing.along
                if gain > 0.5 then
                    moved = true
                    closing.moved, closing.secs = closing.moved + gain, closing.secs + (now - closing.at)
                    if closing.moved >= SPEED_AFTER_YARDS and closing.secs >= SPEED_AFTER_SECONDS then
                        closing.speed = closing.moved / closing.secs
                    end
                end
            end
            closing.along, closing.at = f.along, now
            local left = mmax(0, f.path.len - f.along)
            total = left * (f.path.time / mmax(1, f.path.len)) / (closing.speed or planned) + (step.edgeSec or 0)
        else
            local ci, px, py = PlayerWorldPos()
            local target = onTaxi and step.arrive or (step.go or step.arrive)
            local tci, tx, ty
            if target and target.wx then tci, tx, ty = target.ci, target.wx, target.wy
            elseif target then tci, tx, ty = WorldPos(target.m, target.x, target.y) end
            if ci and tci == ci and tx then
                local d = ((px - tx) ^ 2 + (py - ty) ^ 2) ^ 0.5
                moved = closing.d ~= nil and (closing.d - d > 0.5 or d - closing.d > 0.5)
                closing.d = d
                if onTaxi then
                    total = Engine:TravelSeconds(d, { taxi = true })
                else
                    walkOpts.wind = step.wind
                    total = Engine:TravelSeconds(d, walkOpts) + (step.edgeSec or 0)
                end
            else
                total = step.sec or 0
            end
        end
        if not moved and closing.held then total = closing.held end
        closing.held = total
    end
    route.stepEta = total
    local k = closing.speed and planned / closing.speed or 1
    for j = i + 1, #route.steps do
        local s = route.steps[j]
        total = total + (s.sec or 0) * (s.kind == "travel" and k or 1)
    end
    closing.eta = closing.eta and (closing.eta + (total - closing.eta) * ETA_SMOOTH) or total
    return closing.eta
end

-- The time still to go in minutes, and hours past one; under a minute
-- reads <1 min. Our own unit words: the game's carry a grammar token that
-- some text does not render.
local function EtaText(sec)
    local H, M = L["GPS_UNIT_HR"] or "%d hr", L["GPS_UNIT_MIN"] or "%d min"
    sec = sec or 0
    if sec < 60 then return "<" .. sformat(M, 1) end
    local m = mfloor(sec / 60 + 0.5)
    local h = mfloor(m / 60)
    m = m % 60
    if h > 0 then return sformat(H, h) .. (m > 0 and (" " .. sformat(M, m)) or "") end
    return sformat(M, m)
end
GPS.EtaText = EtaText

-- The destination line: the name, with the time still to go after it.
local function DestText(route)
    local name = route.dest.name or "?"
    if route.arrived or not (route.eta and route.eta > 0) then return sformat(L["GPS_TO_FMT"], name) end
    return sformat(L["GPS_TO_ETA_FMT"], name, EtaText(route.eta))
end

-- The time on every surface, without a full redraw.
local function UpdateEtaText(route)
    local eta = ""
    if route and not route.arrived and route.eta and route.eta > 0 then eta = EtaText(route.eta) end
    for i = 1, #surfaces do
        local s = surfaces[i]
        if s.SetEta then s:SetEta(route)
        elseif s.eta then s.eta:SetText(eta) end
        if route and s.PlaceSearch then s:PlaceSearch(true) end
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
-- line and off its way on foot, or on another continent.
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
    local way = Engine and Engine.WalkPath and Engine.WalkPath(tci, fx, fy, tx, ty, true, step.near)
    -- Its way not drawn yet: nothing to be off.
    if way == nil then return false end
    local pts = way and way.pts or {}
    for v = 1, #pts - 3, 2 do
        if ToSegment(px, py, pts[v], pts[v + 1], pts[v + 2], pts[v + 3]) <= OFF_ROUTE_YARDS then return false end
    end
    return true
end

-- The route again from where the player stands, to the same place. A stop
-- to learn a flight master stays until that master is learned.
local function Reroute(route)
    if GPS:IsPlanning() then return end
    local known = ns.GPSRoute and ns.GPSRoute.recordedKnown
    local via = route.via and not (known and known[route.via.id]) and route.via or nil
    GPS:Plan(nil, function() return GPS:BuildStops(route, via, route.wayAvoid, true, "first") end,
        function(steps, total, advice)
            if steps and Route() == route then GPS.Rerouted(route, via, steps, total, advice) end
        end)
end

function GPS.Rerouted(route, via, steps, total, advice)
    local ci, wx, wy = PlayerWorldPos()
    -- The report keeps the first plan, and counts the starts over.
    local report = route.report
    if report then report.re = (report.re or 0) + 1 end
    CharDB().route = { dest = route.dest, steps = steps, active = 1, t = time(), eta = total, total = total, advice = advice,
                       via = via, from = ci and { ci = ci, wx = wx, wy = wy } or nil, report = report,
                       wayAvoid = route.wayAvoid }
    closing.step = nil
    if GPS.AfterRoute then GPS.AfterRoute() end
    if ns.GPSPreview and ns.GPSPreview.Reset then ns.GPSPreview:Reset() end
    TrackStep(1)
end

-- Dead on the way: released, the ghost is led to its corpse first, a step
-- of its own before the one it was on; risen, that step goes and the
-- route carries on from there.
local function CorpsePoint()
    local get = C_DeathInfo and C_DeathInfo.GetCorpseMapPosition
    local mapID = get and C_Map.GetBestMapForUnit("player")
    for _ = 1, 4 do
        if not mapID then return nil end
        local pos = get(mapID)
        local x, y
        if pos and pos.GetXY then x, y = pos:GetXY() elseif pos then x, y = pos.x, pos.y end
        if x and (x ~= 0 or y ~= 0) then
            local ci, wx, wy = WorldPos(mapID, x, y)
            if ci then return { m = mapID, x = x, y = y, ci = ci, wx = wx, wy = wy } end
        end
        local info = C_Map.GetMapInfo(mapID)
        mapID = info and info.parentMapID
    end
    return nil
end

-- The steps changed under the route: every surface starts afresh and the
-- walks are drawn again from their new starts.
local function StepsChanged(route, active)
    if ns.GPSFollow then ns.GPSFollow.Reset() end
    if ns.GPSPreview and ns.GPSPreview.Reset then ns.GPSPreview:Reset() end
    TrackStep(active)
    if GPS.AfterRoute then GPS.AfterRoute(true) end
end

local function LeadToCorpse()
    local route = Route()
    if not (route and route.steps and not route.arrived) then return end
    local i = route.active or 1
    if route.steps[i] and route.steps[i].corpse then return end
    local p = CorpsePoint()
    if not p then return end
    local ci, px, py = PlayerWorldPos()
    table.insert(route.steps, i, { kind = "travel", corpse = true, text = L["GPS_STEP_CORPSE"],
                                   mapID = p.m, x = p.x, y = p.y, go = p, arrive = p, sec = 0,
                                   from = ci and { ci = ci, wx = px, wy = py } or nil })
    StepsChanged(route, i)
end

local function Risen()
    local route = Route()
    if not (route and route.steps) then return end
    for i = 1, #route.steps do
        if route.steps[i].corpse then
            table.remove(route.steps, i)
            local active = route.active or 1
            if active > i then active = active - 1 end
            if route.steps[active] then StepsChanged(route, active) else Arrive(route) end
            return
        end
    end
end

local function GhostOrRisen()
    if UnitIsGhost("player") then LeadToCorpse() else Risen() end
end
GPS.LeadToCorpse, GPS.Risen = LeadToCorpse, Risen   -- dev tools

local function Tick()
    local route = Route()
    if not route or route.arrived then StopTicker() return end
    local step = route.steps[route.active or 1]
    if not step then StopTicker() return end
    SampleGroundSpeed()
    -- Planned from elsewhere: no countdown and no starting over until the
    -- player reaches the start.
    local planned = route.origin and not route.joined
    if planned then
        local pci, ppx, ppy = PlayerWorldPos()
        local o = route.origin
        if pci == o.ci and ppx and (ppx - o.wx) ^ 2 + (ppy - o.wy) ^ 2 <= START_YARDS * START_YARDS then
            route.joined, planned = true, false
        end
    end
    -- The estimate follows the player: the way still ahead, every second.
    if not planned then
        route.eta = RemainingSeconds(route)
        UpdateEtaText(route)
    end
    -- A ghost without its corpse leg (the route rewritten under it), or a
    -- risen player still carrying one: put right here, every second. A
    -- ghost on its way to its corpse: nothing else counts until it rises.
    local ghost = UnitIsGhost("player") == true
    if ghost ~= (step.corpse == true) then GhostOrRisen() return end
    if ghost then return end
    -- Reaching a crossing's spot changes what its step says: redraw then.
    local there = StepText(step, true) == (step.text or "")
    if route.there ~= there then
        route.there = there
        Refresh()
    end
    -- A zone is reached when you are in it, wherever its map's middle is.
    if route.dest and route.dest.zone and not INSTANCE_CATEGORIES[route.dest.category] and OnMap(route.dest.mapID) then
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
    if not planned and not (UnitOnTaxi and UnitOnTaxi("player")) and OffRoute(route, ci, px, py) then
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
        local radius = crossing and ARRIVE.cross or ARRIVE.yards
        -- The marks stay on a creature until the player stands beside it
        -- (several stand in a town); an entrance keeps the wider ring.
        local dest = route.dest
        if not crossing and not route.steps[(route.active or 1) + 1] and dest and not dest.zone
           and not INSTANCE_CATEGORIES[dest.category] then
            radius = ARRIVE.spot
        end
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

GPS.Destination = Destination   -- the trip editor's stops

function GPS:NavigateTo(data, opts)
    if not self:CanNavigate(data) then return false end
    local db = DB()
    if not db then return false end
    local dest = Destination(data)
    -- Started from the window: it shows there; the map is not opened.
    -- Started from the main search bar: the window opens, not the map.
    if opts and opts.popout then
        self:TogglePopout(true)
    elseif not (opts and opts.quiet) then
        self:Open()
    end
    self:Plan(dest.name, function() return self:BuildRoute(dest, nil, nil, true, "first") end,
        function(steps, total, advice)
            GPS.Navigated(dest, steps, total, advice)
        end)
    return true
end

function GPS.Navigated(dest, steps, total, advice, stops)
    local db = DB()
    if not db then return end
    -- Planned from elsewhere: the route waits there until the player comes.
    local origin = StartPoint()
    local ci, wx, wy
    if origin then ci, wx, wy = origin.ci, origin.wx, origin.wy else ci, wx, wy = PlayerWorldPos() end
    local from = ci and { ci = ci, wx = wx, wy = wy } or nil
    local okFly, fly = pcall(IsFlyableArea)
    local Engine = ns.GPSRoute
    -- The report's start: the world spot and the map spot it was on.
    local start = from and { ci = ci, wx = wx, wy = wy } or nil
    if start and origin then
        start.m, start.x, start.y = origin.m, origin.x, origin.y
    elseif start then
        local hereMap = C_Map.GetBestMapForUnit("player")
        local okPos, herePos = pcall(C_Map.GetPlayerMapPosition, hereMap, "player")
        if okPos and herePos then start.m, start.x, start.y = hereMap, herePos:GetXY() end
    end
    -- The same trip planned again keeps the flight points dropped from it.
    local old = Route()
    local skip = old and old.dest and old.dest.name == dest.name and old.dest.mapID == dest.mapID and old.skipLearn or nil
    CharDB().route = { dest = dest, steps = steps, active = 1, t = time(), eta = total, total = total, advice = advice,
                       from = from, origin = origin, stops = stops or { dest }, skipLearn = skip,
                       report = { from = start, total = total, t = time(), fly = okFly and fly and true or false,
                                  steps = Engine and Engine.StepsCode and Engine.StepsCode(steps) or nil } }
    if GPS.AfterRoute then GPS.AfterRoute() end
    -- A new route opens up, whatever the last one was folded to.
    db.gpsPopoutCollapsed = nil
    for i = 1, #surfaces do
        if surfaces[i].SyncFold then surfaces[i]:SyncFold() end
    end
    TrackStep(1)
    StartTicker()
end

-- The trip again with a stop to learn a flight master on it.
function GPS:AddStop(tip)
    local route = Route()
    local Engine = ns.GPSRoute
    if not (route and route.dest and Engine and tip and tip.id) then return end
    local via = { id = tip.id, name = tip.name, p = tip.p }
    self:Plan(route.dest.name, function() return self:BuildStops(route, via, nil, nil, "first") end,
        function(steps, total, advice)
            if steps and Route() == route then GPS.StopAdded(route, via, tip, steps, total, advice) end
        end)
end

-- A learning stop dropped: the trip again without it, and it is not
-- taken or offered again on this trip.
function GPS:DropLearn(nodeID)
    local route = Route()
    if not (route and route.dest and nodeID) then return end
    route.skipLearn = route.skipLearn or {}
    route.skipLearn[nodeID] = true
    local keepVia = route.via and route.via.id ~= nodeID and route.via or nil
    self:Plan(route.dest.name, function() return self:BuildStops(route, keepVia, nil, nil, "first") end,
        function(steps, total, advice)
            if steps and Route() == route then GPS.StopAdded(route, keepVia, keepVia or {}, steps, total, advice) end
        end)
end

function GPS.StopAdded(route, via, tip, steps, total, advice)
    route.steps, route.eta, route.total, route.advice, route.t, route.there = steps, total, total, advice, time(), nil
    route.via = via
    if route.report then route.report.via = tip.id end
    local ci, wx, wy = PlayerWorldPos()
    route.from = ci and { ci = ci, wx = wx, wy = wy } or nil
    closing.step = nil
    TrackStep(1)
    if GPS.AfterRoute then GPS.AfterRoute(true) end
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
                ci == sci and tostring(math.floor(((px - sx) ^ 2 + (py - sy) ^ 2) ^ 0.5)) or "other continent", ARRIVE.yards)
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

-- Other ways: the route planned again without its main way of travel,
-- and with no transport at all; up to OTHER_WAYS that differ from it.
local OTHER_WAYS = 2
local WAY_ORDER = { "teleport", "portal", "boat", "zeppelin", "taxi" }
local NO_TRANSPORT = { "taxi", "boat", "zeppelin", "portal", "teleport" }

-- The main way a route travels: its first transport by WAY_ORDER, else "walk".
local function WayOf(steps)
    local kinds = ns.GPSRoute and ns.GPSRoute.AVOID_KIND or {}
    local seen = {}
    for i = 1, #steps do
        local k = kinds[steps[i].kind]
        if k then seen[k] = true end
    end
    for _, k in ipairs(WAY_ORDER) do
        if seen[k] then return k end
    end
    return "walk"
end

local function OtherWays(route)
    local db = DB()
    local base = route.wayAvoid or (db and db.gpsAvoid) or {}
    local best = WayOf(route.steps)
    local found, ways = { [best] = true }, {}
    local function Try(extra)
        local avoid = {}
        for k, v in pairs(base) do avoid[k] = v end
        for i = 1, #extra do avoid[extra[i]] = true end
        local steps, total = GPS:BuildStops(route, nil, avoid, true)
        if not (steps and total and total > 0) then return end
        local way = WayOf(steps)
        if found[way] then return end
        found[way] = true
        ways[#ways + 1] = { way = way, total = total, avoid = avoid }
    end
    if best ~= "walk" then Try({ best }) end
    Try(NO_TRANSPORT)
    table.sort(ways, function(a, b) return a.total < b.total end)
    for i = #ways, OTHER_WAYS + 1, -1 do ways[i] = nil end
    return ways
end

-- A planner job for the next frame; the follower's walks wait behind it.
local jobsPending = 0
local function Soon(fn)
    jobsPending = jobsPending + 1
    Utils.SafeAfter(0, function()
        jobsPending = jobsPending - 1
        fn()
    end)
end

-- Planned once the route is on screen, never in the way of showing it: what
-- to pick up on the way, then the other ways.
local function PlanOtherWays()
    Soon(function()
        local route = Route()
        if not (route and route.dest and not route.arrived) or GPS:IsPlanning() then return end
        GPS:Plan(nil, function()
            local _, _, advice = GPS:BuildStops(route, route.via, route.wayAvoid)
            return advice, OtherWays(route)
        end, function(advice, ways)
            if Route() ~= route then return end
            route.advice, route.others = advice or route.advice, ways
        end)
    end)
end
GPS.PlanOtherWays = PlanOtherWays

-- The route's walks past the one set out on, drawn now that the route is
-- on screen: each timed by its way, split by zone, the total following;
-- then, unless onlyDraw, the advice and the other ways.
local function AfterRoute(onlyDraw)
    Soon(function()
        local route = Route()
        local Engine = ns.GPSRoute
        if not (route and route.dest and route.from and not route.arrived and Engine and Engine.DrawWalks)
            or GPS:IsPlanning() then
            if not onlyDraw then PlanOtherWays() end
            return
        end
        GPS:Plan(nil, function()
            local Nav = ns.GPSNav
            if Nav then Nav.yieldCo = coroutine.running() end
            Engine.DrawWalks(route.steps, route.from)
            if Nav then Nav.yieldCo = nil end
            return true
        end, function()
            if Route() ~= route then return end
            local current = route.steps[route.active or 1]
            local steps = SplitWalks(route.steps, route.dest, route.from)
            for i = 1, #steps do
                if steps[i] == current then route.active = i end
            end
            local total = 0
            for i = 1, #steps do total = total + (steps[i].sec or 0) end
            route.steps, route.total, route.eta = steps, total, total
            if route.report and Engine.StepsCode then route.report.steps = Engine.StepsCode(steps) end
            closing.eta = nil
            if ns.GPSFollow and ns.GPSFollow.Reset then ns.GPSFollow.Reset() end
            if ns.GPSPreview and ns.GPSPreview.Follow then ns.GPSPreview:Follow() end
            Refresh()
            if not onlyDraw then PlanOtherWays() end
        end)
    end)
end
GPS.AfterRoute = AfterRoute

-- A walk the follower needs (from where the player strayed to), drawn in
-- the planner's slices; the follower reads it once it is there. Refused
-- while the planner runs or a job waits for it: asked again.
function GPS.DrawWalk(ci, sx, sy, tx, ty, near)
    local Engine = ns.GPSRoute
    if jobsPending > 0 or GPS:IsPlanning() or not (Engine and Engine.WalkPath) then return false end
    GPS:Plan(nil, function()
        local Nav = ns.GPSNav
        if Nav then Nav.yieldCo = coroutine.running() end
        Engine.WalkPath(ci, sx, sy, tx, ty, nil, near)
        if Nav then Nav.yieldCo = nil end
        return true
    end, function()
        if ns.GPSPreview and ns.GPSPreview.Follow then ns.GPSPreview:Follow() end
    end)
    return true
end

-- Takes one of the other ways: the route keeps to it, starting over too.
function GPS:TakeOtherWay(other)
    local route = Route()
    if not (route and route.dest and other) then return end
    self:Plan(route.dest.name, function() return self:BuildStops(route, nil, other.avoid, true, "first") end,
        function(steps, total, advice)
            if not (steps and Route() == route) then return end
            route.steps, route.eta, route.total, route.advice, route.t, route.there = steps, total, total, advice, time(), nil
            route.wayAvoid, route.others = other.avoid, nil
            closing.step = nil
            TrackStep(1)
            AfterRoute()
        end)
end

-- Picking a start in a surface's search box: its hits set the start.
-- Where the trip's fields show, the start's own field takes it.
function GPS:PickStart(frame)
    if frame and frame.trip then
        if frame.collapsed and frame.collapseBtn then frame.collapseBtn:Click() end
        if frame.trip:FocusStart() then return end
    end
    GPS:EndAlong()
    GPS.picking = frame
    Refresh()
    local box = frame and frame.search
    if box then
        box:Show()
        box._blockAutoFocus = nil
        box:SetFocus()
    end
end

function GPS:EndPick()
    if not GPS.picking then return end
    GPS.picking = nil
    Refresh()
end

-- Places along the route ahead in a surface's search: the trip's field
-- before the destination where the trip's fields show, else the search
-- box, tagged. A pick is a stop before the destination.
function GPS:SearchAlong(frame)
    local route = Route()
    if not (route and not route.arrived and frame) then return end
    GPS:EndPick()
    if frame.collapsed and frame.collapseBtn then frame.collapseBtn:Click() end
    if frame.trip then
        frame.trip:SearchAlong()
        return
    end
    local box = frame.search
    if not box then return end
    GPS.along = frame
    ns.GPSTrip.Tag(box, true)
    box:SetText("")
    frame:ShowHits(nil)
    Refresh()
    box:Show()
    box._blockAutoFocus = nil
    box:SetFocus()
end

function GPS:EndAlong()
    local frame = GPS.along
    if not frame then return end
    GPS.along = nil
    if frame.search then ns.GPSTrip.Tag(frame.search, false) end
    Refresh()
end

-- Starts routes at data's place ({ name, mapID, x, y }), or at the player
-- again with nil. A route on screen is planned again from there; with none,
-- the GPS window asks where to. quiet: the start alone, the caller plans.
function GPS:SetStart(data, quiet)
    local c = CharDB()
    if not c then return end
    c.start = data and { name = data.name, mapID = data.zoneMapID or data.mapID, x = data.x or 0.5, y = data.y or 0.5 } or nil
    GPS.picking = nil
    for i = 1, #surfaces do
        local box = surfaces[i].search
        if box then
            box:SetText("")
            box:ClearFocus()
        end
    end
    if quiet then return end
    local route = Route()
    local dest = route and route.dest
    if dest and not route.arrived then
        -- The trip again from the new start, every stop kept.
        if ns.GPSTrip and route.stops and #route.stops > 1 then
            ns.GPSTrip.Navigate({ quiet = true })
        else
            GPS:NavigateTo({ name = dest.name, icon = dest.icon, category = dest.category, isZone = dest.zone,
                             displayID = dest.displayID,
                             mapID = dest.mapID, x = not dest.zone and dest.x or nil, y = not dest.zone and dest.y or nil },
                           { quiet = true })
        end
    elseif data then
        GPS:TogglePopout(true)
        local box = popoutFrame and popoutFrame.search
        if box then
            box._blockAutoFocus = nil
            box:SetFocus()
        end
    end
    Refresh()
end

-- A route that went wrong: the issue form, filled in with the route.
function GPS:ReportRoute()
    local route = Route()
    local Engine = ns.GPSRoute
    if not (route and Engine and Engine.ReportCode and EasyFind.OpenRouteReport) then return end
    local db = DB()
    local code = Engine.ReportCode(route, { version = ns.version, avoid = db and db.gpsAvoid, hearth = HearthPoint() })
    if code then EasyFind:OpenRouteReport(code) end
end

function GPS:Clear()
    local route = Route()
    if route and not route.arrived then LiftPin(route) end
    local c = CharDB()
    if c then c.route, c.start = nil, nil end
    GPS.picking = nil
    GPS:EndAlong()
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
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(true)
    row.num:ClearAllPoints()
    row.num:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -4)
    -- A teleport's icon near the row's right edge, with a little room.
    row.cast = CastButton(row, -8)
    -- A learning step drops from the trip with the X its row shows on hover.
    row.drop = ns.CreateCloseX(row, 10)
    row.drop:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -4)
    row.drop:Hide()
    row.drop:SetScript("OnClick", function() if row.learnID then GPS:DropLearn(row.learnID) end end)
    Utils.AttachDelayedTooltip(row.drop, "ANCHOR_TOP", function() return L["GPS_SKIP_LEARN"] end)
    row.drop:HookScript("OnLeave", function() if not row:IsMouseOver() then row.drop:Hide() end end)
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
        if self.learnID then self.drop:Show() end
    end)
    row:SetScript("OnLeave", function(self)
        GameTooltip_Hide()
        if self.cast and self.cast.pulse then self.cast.pulse:Stop() end
        if not self.drop:IsMouseOver() then self.drop:Hide() end
    end)
    rows[i] = row
    return row
end

-- A tip's click could be an accident: the stop is added only once
-- confirmed, with what it does to this trip spelled out.
local function TipClick(self)
    local tip = self.tip
    if tip and tip.report then
        GPS:ReportRoute()
        return
    end
    if tip and tip.other then
        GPS:TakeOtherWay(tip.other)
        return
    end
    local route = Route()
    if not (tip and tip.p and tip.viaTotal and route) then return end
    local text = sformat(L["GPS_STOP_CONFIRM_FMT"], tip.name or "?", EtaText(tip.viaTotal), EtaText(route.total or route.eta))
    if tip.after then text = text .. " " .. sformat(L["GPS_STOP_AFTER_FMT"], EtaText(tip.after)) end
    ns.ShowThemedDialog({ text = text, acceptText = L["GPS_STOP_ADD"], cancelText = _G["CANCEL"],
                          onAccept = function() GPS:AddStop(tip) end })
end

local function TipEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(self.text:GetText() or "", nil, nil, nil, nil, true)
    local tip = self.tip
    local key = tip and (tip.report and "GPS_REPORT_TT" or tip.other and "GPS_OTHER_WAY_TT"
        or tip.detour and "GPS_ADVICE_DETOUR_TT") or "GPS_ADVICE_TT"
    GameTooltip:AddLine(L[key], 1, 1, 1, true)
    GameTooltip:Show()
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
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(true)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if button ~= "RightButton" then return TipClick(self) end
        if container.ShowMenu then container.ShowMenu() end
    end)
    row:SetScript("OnEnter", TipEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
    container.tips[i] = row
    return row
end

-- The advice as lines: masters on the way first (with what learning one
-- saves when the engine priced it), then the best one elsewhere.
local function AdviceLines(route)
    if route and route.arrived then return { { text = L["GPS_REPORT"], report = true } } end
    if not route then return nil end
    local a = route.advice or {}
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
    for _, other in ipairs(route.others or {}) do
        local way = sformat(L["GPS_WAY_" .. other.way:upper() .. "_FMT"], EtaText(other.total))
        out[#out + 1] = { text = sformat(L["GPS_OTHER_WAY_FMT"], way), other = other }
    end
    return #out > 0 and out or nil
end

local StyleTrackButton, RouteTracked   -- defined with the tracking toggle below; the surfaces render before it

-- The route's start in the panel: where the player stands or the place
-- picked; a click picks another, Reset goes back to the player's spot.
local function FromRow(container)
    local row = container.fromRow
    if row then return row end
    row = CreateFrame("Button", nil, container.list)
    row:SetHeight(ROW_H)
    Utils.InstallMenuRowHighlight(row)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text._efOwnColor = true
    row.text:SetPoint("LEFT", row, "LEFT", 30, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    local reset = CreateFrame("Button", nil, row)
    reset:SetHeight(14)
    local label = reset:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("RIGHT", reset, "RIGHT", 0, 0)
    label:SetText(_G["RESET"] or "Reset")
    label:SetTextColor(unpack(ns.TEXT_DIM))
    label._efOwnColor = true
    reset:SetWidth((label:GetStringWidth() or 40) + 4)
    reset:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    reset:SetScript("OnEnter", function() label:SetTextColor(1, 1, 1) end)
    reset:SetScript("OnLeave", function() label:SetTextColor(unpack(ns.TEXT_DIM)) end)
    reset:SetScript("OnClick", function() GPS:SetStart(nil) end)
    row.reset = reset
    row.text:SetPoint("RIGHT", reset, "LEFT", -6, 0)
    row:SetScript("OnClick", function() GPS:PickStart(container) end)
    row:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L["GPS_FROM_TT"], 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    container.fromRow = row
    return row
end

local function Render(container)
    local route = Route()
    SearchHint(container)
    -- Picking a start: the search and its hits in the steps' place.
    if GPS.picking == container then route = nil end
    local rows = container.rows
    if container.glyphTex then
        container.glyphTex:SetVertexColor(unpack(ns.GOLD_COLOR))
        container.glyphTex:SetAlpha(1)
    end
    if container.track then StyleTrackButton(container.track, route ~= nil and RouteTracked()) end
    if not route then
        if ns.GPSPreview and ns.GPSPreview.Reset then ns.GPSPreview:Reset() end
        container.title:SetText(GPS.planning and sformat(L["GPS_PLANNING_FMT"], GPS.planning.name or "?") or "")
        for i = 1, #rows do rows[i]:Hide() end
        for i = 1, #(container.tips or {}) do container.tips[i]:Hide() end
        if container.fromRow then container.fromRow:Hide() end
        container.list:SetHeight(1)
        container.contentHeight = 0
        if container.search then
            container.search:Show()
            container.empty:Hide()   -- the search box says what to do
        else
            container.empty:Show()
        end
        if container.trip then container.trip:Refresh(nil) end
        if container.OnRouteChanged then container:OnRouteChanged(false) end
        return
    end
    container.empty:Hide()
    if container.search then
        container.search:Show()
        -- A new route: places typed before it go.
        if container.shownRoute ~= route then
            container.shownRoute = route
            container.search:SetText("")
            container:ShowHits(nil)
        end
    end
    container.title:SetText(GPS.planning and sformat(L["GPS_PLANNING_FMT"], GPS.planning.name or "?")
        or sformat(L["GPS_TO_FMT"], route.dest.name or "?"))
    if route.arrived then
        -- Arrived: the announcement in the body where the time line and
        -- the steps were, nothing left to follow.
        container.eta:SetText("")
        container.empty:SetText(L["GPS_ARRIVED_AT_FMT"] and sformat(L["GPS_ARRIVED_AT_FMT"], route.dest.name or "?") or L["GPS_ARRIVED"])
        container.empty:Show()
    else
        local eta = ""
        if route.eta and route.eta > 0 then eta = EtaText(route.eta) end
        -- The trip editor stands where the title was: a plan under way says so here.
        if container.trip and GPS.planning then eta = sformat(L["GPS_PLANNING_FMT"], GPS.planning.name or "?") end
        container.eta:SetText(eta)
    end
    if container.trip then
        container.trip:Refresh(route)
        -- The time line and the Clear link in the page's size, as the steps.
        local px = GPS.MapTextPx(container)
        local linkText = container.clearBtn and container.clearBtn.text
        if px and linkText then
            SizeFont(container.eta, px)
            SizeFont(linkText, px)
            container.clearBtn:SetWidth((linkText:GetStringWidth() or 60) + 4)
            if container.note then SizeFont(container.note, px) end
        end
    end
    local y = 0
    local offset = container.scrollOffset or 0
    local shown = route.arrived and 0 or #route.steps
    -- The window set to the next step alone: that step, nothing else.
    local dbo = DB()
    local only = container.isPopout and dbo and dbo.gpsPopoutNextOnly and shown > 0 and (route.active or 1) or nil
    local scale = MapScale(container)
    local rowBase = scale and mfloor((ROW_H + 4) * scale + 0.5) or ROW_H
    -- A wrapped line is measured at the width it is given outright: a new
    -- row's anchors may not be placed yet when it is measured.
    local listW = container.list:GetWidth() or 0
    local from = FromRow(container)
    if route.arrived or only or container.trip then
        from:Hide()
    else
        local s = Start()
        from:ClearAllPoints()
        from:SetPoint("TOPLEFT", container.list, "TOPLEFT", 0, -y + offset)
        from:SetPoint("RIGHT", container.list, "RIGHT", 0, 0)
        from.text:SetText(sformat(L["GPS_FROM_FMT"], s and s.name or L["GPS_FROM_HERE"]))
        from.text:SetTextColor(unpack(ns.TEXT_DIM))
        from.reset:SetShown(s ~= nil)
        from:SetHeight(rowBase)
        from:Show()
        y = y + rowBase
    end
    for i = only or 1, only or shown do
        local step = route.steps[i]
        local row = StepRow(container, i)
        row.index = i
        if scale and row.fontScale ~= scale then
            row.fontScale = scale
            SizeFont(row.text, MAP_STEP_PX * scale)
            SizeFont(row.num, MAP_STEP_PX * scale)
            row.num:SetWidth(mfloor(24 * scale + 0.5))
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", container.list, "TOPLEFT", 0, -y + offset)
        row:SetPoint("RIGHT", container.list, "RIGHT", 0, 0)
        row.num:SetText(tostring(i) .. ".")
        local active = (route.active or 1) == i and not route.arrived
        local done = route.arrived or i < (route.active or 1)
        local cast = SetupCast(row.cast, step, active)
        row.learnID = step.kind == "learn" and not route.arrived and step.nodeID or nil
        if not row.learnID then row.drop:Hide() end
        row.text:SetWidth(mmax(40, listW - 12 - row.num:GetWidth() - ((cast or row.learnID) and 32 or 6)))
        row.text:SetText(StepText(step, active))
        local rowH = mmax(rowBase, (row.text:GetStringHeight() or 0) + 8)
        row:SetHeight(rowH)
        -- The window's art is dark whatever the theme: the dark colors,
        -- not the theme's text, which a light theme turns dark.
        if active then
            row.text:SetTextColor(1, 0.97, 0.86)
            row.num:SetTextColor(unpack(ns.GOLD_COLOR))
        elseif done then
            row.text:SetTextColor(unpack(ns.TEXT_DIM))
            row.num:SetTextColor(unpack(ns.TEXT_DIM))
        else
            row.text:SetTextColor(0.78, 0.78, 0.80)
            row.num:SetTextColor(0.78, 0.78, 0.80)
        end
        row:Show()
        y = y + rowH
    end
    for i = 1, (only or 1) - 1 do rows[i]:Hide() end
    for i = (only or shown) + 1, #rows do rows[i]:Hide() end
    local tips = not only and AdviceLines(route)
    local nTips = tips and #tips or 0
    -- Arrived: the report line goes under the announcement.
    if route.arrived and container.empty:IsShown() then
        local eb, lt = container.empty:GetBottom(), container.list:GetTop()
        y = (eb and lt) and mmax(0, lt - eb + 4) or ((container.empty:GetStringHeight() or 12) + 8)
    end
    for t = 1, nTips do
        local row = TipRow(container, t)
        row.tip = tips[t]
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", container.list, "TOPLEFT", 0, -y + offset)
        row:SetPoint("RIGHT", container.list, "RIGHT", 0, 0)
        if scale and row.fontScale ~= scale then
            row.fontScale = scale
            SizeFont(row.text, (MAP_STEP_PX - 1) * scale)
        end
        row.text:SetWidth(mmax(40, listW - 36))
        row.text:SetText(tips[t].text)
        row.text:SetTextColor(unpack(ns.TEXT_DIM))
        local rowH = mmax(rowBase, (row.text:GetStringHeight() or 0) + 8)
        row:SetHeight(rowH)
        row:Show()
        y = y + rowH
    end
    for t = nTips + 1, #(container.tips or {}) do container.tips[t]:Hide() end
    container.contentHeight = y
    container.list:SetHeight(mmax(1, y))
    -- Rows made this render carry the font's shadow until flattened.
    if ns.StripShadows then ns.StripShadows(container.list) end
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
    ns.GPSTrip.Note(row)
    row:SetScript("OnClick", function(self)
        if not self.data then return end
        if GPS.picking == frame then
            GPS:SetStart(self.data)
            return
        end
        if GPS.along == frame then
            frame.search:SetText("")
            frame.search:ClearFocus()
            GPS:EndAlong()
            ns.GPSTrip.Insert(GPS.Destination(self.data))
            return
        end
        frame.search:SetText("")
        frame.search:ClearFocus()
        GPS:NavigateTo(self.data, { quiet = true })
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

-- Places for a typed name, for the trip editor: the map search's, then towns.
function GPS.SearchPlaces(q)
    local MapSearch = ns.MapSearch
    if not (MapSearch and MapSearch.BuildResults) then return WithTowns(q, nil) end
    local ok, results = pcall(MapSearch.BuildResults, MapSearch, q, true, true)
    return WithTowns(q, ok and results or nil)
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
    box:HookScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
        -- Escape leaves a start being picked; with no route, drops a start set.
        if GPS.picking == frame then GPS:EndPick() elseif Start() and not Route() then GPS:SetStart(nil) end
        if GPS.along == frame then GPS:EndAlong() end
    end)
    box:HookScript("OnEditFocusLost", function(self)
        if GPS.picking == frame and (self:GetText() or "") == "" then GPS:EndPick() end
        if GPS.along == frame and (self:GetText() or "") == "" then GPS:EndAlong() end
    end)
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

    -- secs, along the way: by place, the seconds a stop there adds.
    function frame:ShowHits(results, secs)
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
                    row.note:SetText(secs and secs[r] and ns.GPSTrip.AddsText(secs[r]) or "")
                    row:Show()
                end
            end
        end
        for i = n + 1, #self.hits do self.hits[i]:Hide() end
        hitChild:SetHeight(mmax(1, n * ROW_H))
        hitList:SetVerticalScroll(0)
        self.hitCount = n
        self:SetHitView(HIT_ROWS * ROW_H)
        if self.OnRouteChanged then self:OnRouteChanged(Route() ~= nil and GPS.picking ~= self) end
    end

    local pending
    box:HookScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        if text == "" then frame:ShowHits(nil) return end
        if pending then return end
        pending = true
        Utils.SafeAfter(0.15, function()
            pending = nil
            local MapSearch = ns.MapSearch
            local q = box:GetText() or ""
            if q == "" or not (MapSearch and MapSearch.BuildResults) then return end
            if GPS.along == frame then
                frame:ShowHits(ns.GPSTrip.AlongPlaces(q))
                return
            end
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
    local route = Route()
    return route ~= nil and not route.untracked
end

-- The arrow and the beacon follow the route, or let go of it for the
-- tracker's quests.
local function ToggleRouteTracking()
    local route = Route()
    if not route then return end
    if RouteTracked() then
        route.untracked = true
        -- Let go: the map search must stop treating the pin as its own, or
        -- it re-tracks it the moment nothing else is tracked.
        if ns.MapSearch and ns.MapSearch.SetEasyFindWaypointPlaced then ns.MapSearch:SetEasyFindWaypointPlaced(false) end
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(false) end
    else
        route.untracked = nil
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
    frame.padRight = padRight   -- the trip editor keeps its first row clear of the header's buttons
    -- The header's right padding clears its buttons; the body below only
    -- clears the edge.
    local bodyPad = opts.bodyPadRight or padRight

    -- On a child frame above the panel's gloss; its gold is re-applied every
    -- render in case a theme pass touches it.
    local head, glyph
    if opts.trackGlyph then
        -- The window's icon is the tracking toggle the section has, so it
        -- reads the same way: lit while the arrow follows the route.
        head = CreateFrame("Frame", nil, frame)
        head:SetFrameLevel(frame:GetFrameLevel() + 10)
        head:SetSize(20, 20)
        head:SetPoint("TOPLEFT", frame, "TOPLEFT", padX - 2, -(padY - 2))
        local track = BuildTrackButton(frame)
        track:SetFrameLevel(frame:GetFrameLevel() + 10)
        track:SetPoint("TOPLEFT", head, "TOPLEFT", 0, 0)
        track:Show()
        glyph = head
        frame.glyph = head
        frame.track = track
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
    title:SetTextColor(1, 0.97, 0.86)
    title._efOwnColor = true
    frame.title = title
    if not opts.titleOpensMap then
        -- A click on the destination line holds the whole route on the
        -- map, as a click on a step holds that step; right-click is the menu.
        local over = CreateFrame("Button", nil, frame)
        over:SetAllPoints(title)
        over:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        over:SetScript("OnClick", function(_, button)
            if button == "RightButton" then
                if frame.ShowMenu then frame.ShowMenu() end
            elseif frame.previewOnHover and ns.GPSPreview then
                ns.GPSPreview:Toggle(0)
            end
        end)
    end
    if opts.titleOpensMap then
        -- The destination line opens the map's GPS page, as a quest in
        -- the tracker opens its log entry; the steps keep their own click.
        local btn = CreateFrame("Button", nil, frame)
        btn:SetAllPoints(title)
        btn:SetScript("OnEnter", function() title:SetTextColor(unpack(ns.GOLD_COLOR)) end)
        btn:SetScript("OnLeave", function() title:SetTextColor(1, 0.97, 0.86) end)
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
        link.text = text
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
        Utils.AttachDelayedTooltip(btn, "ANCHOR_TOP", function() return L["GPS_POPOUT"], L["GPS_POPOUT_TT"] end)
        frame.popoutBtn = btn
    end

    if opts.search then
        BuildSearch(frame, glyph, padRight, bodyPad)
        -- With a route the box moves to the time line, after the time and
        -- before the Clear link, and the places it finds take the steps' place.
        frame.PlaceSearch = function(self, hasRoute)
            local box, hits = self.search, self.hitList
            box:ClearAllPoints()
            hits:ClearAllPoints()
            if hasRoute then
                box:SetPoint("LEFT", self.eta, "LEFT", (self.eta:GetStringWidth() or 0) + 10, 0)
                box:SetPoint("RIGHT", self.clearBtn, "LEFT", -8, 0)
                hits:SetPoint("TOPLEFT", self.list, "TOPLEFT", 0, 0)
                hits:SetPoint("RIGHT", self.list, "RIGHT", 0, 0)
            else
                box:SetPoint("LEFT", glyph, "RIGHT", 12, 0)
                box:SetPoint("RIGHT", self, "RIGHT", -padRight, 0)
                hits:SetPoint("TOPLEFT", glyph, "BOTTOMLEFT", -6, -8)
                hits:SetPoint("RIGHT", self, "RIGHT", -(bodyPad - 4), 0)
            end
        end
    end

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
    frame.listGap = opts.listGap or 8   -- the room between the time line and the first step
    local list = CreateFrame("Frame", nil, frame)
    list:SetPoint("TOPLEFT", head, "BOTTOMLEFT", -6, -(4 + etaH + frame.listGap))
    list:SetPoint("RIGHT", frame, "RIGHT", -(bodyPad - 4), 0)
    list:SetHeight(1)
    frame.list = list

    frame.OnRouteChanged = function(self, hasRoute)
        self.clearBtn:SetShown(hasRoute)
        self.eta:SetShown(hasRoute)
        if self.titleBtn then self.titleBtn:SetShown(hasRoute) end
        -- With the trip's fields the track toggle sits on the time line.
        if self.track and self.trip then self.track:SetShown(hasRoute) end
        if self.search then
            -- While a way is found the title says so in the box's place.
            -- With the trip editor up, its fields do the searching.
            local searching = not GPS.planning and not self.trip
            self.search:SetShown(searching)
            self.hitList:SetShown(searching and (not hasRoute or (self.hitCount or 0) > 0))
            self:PlaceSearch(hasRoute)
        end
        if opts.onRouteChanged then opts.onRouteChanged(self, hasRoute) end
    end
    frame.Render = Render
    surfaces[#surfaces + 1] = frame
    frame:HookScript("OnShow", function(self) self:Render() end)
end

-- The page under the map search tab

-- The steps stop above the foot rule and scroll under the wheel; the rule
-- under the time line shows with a route.
local function FitPage(self, hasRoute)
    if self.headRule then self.headRule:SetShown(hasRoute and true or false) end
    -- A new route starts at its first step.
    local route = Route()
    if self.fitRoute ~= route then
        self.fitRoute = route
        if (self.scrollOffset or 0) > 0 then
            self.scrollOffset = 0
            self:Render()
            return
        end
    end
    local top, foot = self.list:GetTop(), self.footRule and self.footRule:GetTop()
    if not (top and foot) then return end
    local avail = mmax(1, top - foot - 8)
    local maxOffset = mmax(0, (self.contentHeight or 0) - avail)
    if (self.scrollOffset or 0) > maxOffset then
        self.scrollOffset = maxOffset
        self:Render()
        return
    end
    self.list:SetHeight(mmax(1, math.min(self.contentHeight or 0, avail)))
    self.list:SetClipsChildren(true)
    local bar = self.scrollBar
    if bar then
        bar:SetShown(hasRoute and true or false)
        self.maxOffset = maxOffset
        local total = self.contentHeight or 0
        self.syncingBar = true
        bar:SetVisibleExtentPercentage(total > 0 and math.min(1, avail / total) or 1)
        bar:SetScrollPercentage(maxOffset > 0 and (self.scrollOffset or 0) / maxOffset or 0)
        self.syncingBar = nil
    end
end

local function Rule(frame)
    local rule = frame:CreateTexture(nil, "ARTWORK")
    rule:SetHeight(1)
    local d = ns.TEXT_DIM
    rule:SetColorTexture(d[1], d[2], d[3], 0.35)
    rule:SetPoint("LEFT", frame, "LEFT", 12, 0)
    rule:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
    return rule
end

local function BuildPage(frame)
    BuildSurface(frame, { popoutButton = true, listGap = 14, onRouteChanged = FitPage })
    frame.previewOnHover = true   -- this surface sits beside the map
    frame.mapFont = true          -- its steps follow the map search's font size
    if ns.GPSTrip then ns.GPSTrip.BuildEditor(frame) end
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(self, delta)
        if not Route() then return end
        self.scrollOffset = mmax(0, (self.scrollOffset or 0) - delta * ROW_H)
        self:Render()
    end)
    frame:HookScript("OnSizeChanged", function(self) if self:IsShown() then self:Render() end end)
    -- The steps' scroll bar where the map search keeps its own, in the strip
    -- right of the panel.
    local panel = frame:GetParent()
    local bar = CreateFrame("EventFrame", nil, frame, "MinimalScrollBar")
    bar:SetFrameStrata("HIGH")
    bar:SetPoint("TOPLEFT", panel, "TOPRIGHT", 8, 2)
    bar:SetPoint("BOTTOMLEFT", panel, "BOTTOMRIGHT", 8, -4)
    bar:Hide()
    if bar.RegisterCallback and bar.Event and bar.Event.OnScroll then
        bar:RegisterCallback(bar.Event.OnScroll, function(_, pct)
            if frame.syncingBar then return end
            local offset = mfloor(pct * (frame.maxOffset or 0) + 0.5)
            if offset == (frame.scrollOffset or 0) then return end
            frame.scrollOffset = offset
            frame:Render()
        end, frame)
    end
    frame.scrollBar = bar
    -- A rule under the time line sets the steps apart from it.
    frame.headRule = Rule(frame)
    frame.headRule:SetPoint("TOP", frame.clearBtn, "BOTTOM", 0, -4)
    frame.headRule:Hide()
    -- At its foot, under a rule: GPS is experimental and where to say so.
    local note = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.note = note
    local exp = ns.CreateFeatureTag(frame, "exp", L["TAG_EXP_TITLE"], L["GPS_EXP_TT"])
    note:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12 + exp:GetWidth() + 6, 10)
    note:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 10)
    note:SetJustifyH("LEFT")
    note:SetText(L["GPS_EXP_TT"])
    note:SetTextColor(unpack(ns.TEXT_DIM))
    note._efOwnColor = true
    exp:SetPoint("TOPRIGHT", note, "TOPLEFT", -6, 1)
    frame.footRule = Rule(frame)
    frame.footRule:SetPoint("BOTTOM", exp, "TOP", 0, 7)
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
        clear = function() GPS:Clear() end,
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
local SectionLook           -- defined with it; the placing reads it
local PopoutSize            -- defined with the pop-out below; the floating section uses it
local DOCK_REACH = 24
local DOCK_HEADER_H = 25
local DOCK_INDENT = 20
local DOCK_LINE_GAP = 4

-- The section's other looks: the Era watch's (its lines wrap past W, are
-- LINE tall, its titles in TITLE) and ClassicUI's restyled tracker's.
local Look = { W = 280, LINE = 13, TITLE = { 0.75, 0.61, 0 } }

local function ClientTracker()
    local t = _G.ObjectiveTrackerFrame
    if t and type(t.modules) == "table" then return t end
    return nil
end

-- What the section snaps into: "game" the game's tracker, "classic" that
-- tracker restyled by ClassicUI Forever, "era" its Era quest watch, or nil
-- with none to snap into (its tracker hidden, or a watch without room).
local function Host()
    local Replacement = ns.SearchOpeners and ns.SearchOpeners.Replacement
    if Replacement then
        local api = Replacement("questWatch")
        if api then return api.WatchRoom and "era" or nil, api end
        if Replacement("hideObjectiveTracker") then return nil end
        if Replacement("questTracker") then return ClientTracker() and "classic" or nil end
    end
    return ClientTracker() and "game" or nil
end

-- The game's tracker, while the section snaps into it.
local function Tracker()
    local host = Host()
    if host == "game" or host == "classic" then return ClientTracker() end
    return nil
end

-- The Era watch and its API, while the section snaps into it.
local function Watch()
    local host, api = Host()
    if host ~= "era" then return nil end
    return api.GetFrame("questWatch"), api
end

-- A frame's edges in screen pixels: left, top, right, bottom.
function Look.ScreenRect(r)
    local l, b, w, h = r:GetRect()
    if not l then return nil end
    local s = r:GetEffectiveScale()
    return l * s, (b + h) * s, (l + w) * s, b * s
end

-- The menu row for the beacon in the world (on unless turned off).
function GPS.WorldPinRow()
    return { kind = "check", label = L["GPS_WORLD_PIN"],
        get = function() local db = DB() return not (db and db.gpsWorldPin == false) end,
        set = function(v)
            local db = DB()
            if db then db.gpsWorldPin = (not v) and false or nil end
            Refresh()
        end }
end

-- The menu row for learning cheap flight points on the way (on unless
-- turned off); the trip on screen is planned again either way.
function GPS.AutoLearnRow()
    return { kind = "check", label = L["GPS_AUTO_LEARN"], tooltip = L["GPS_AUTO_LEARN_TT"],
        get = function() local db = DB() return not (db and db.gpsAutoLearn == false) end,
        set = function(v)
            local db = DB()
            if db then db.gpsAutoLearn = (not v) and false or nil end
            local route = Route()
            if route and route.dest and not route.arrived then
                GPS:Plan(route.dest.name, function() return GPS:BuildStops(route, nil, nil, nil, "first") end,
                    function(steps, total, advice)
                        if steps and Route() == route then GPS.StopAdded(route, nil, {}, steps, total, advice) end
                    end)
            end
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
            elseif d.kind == "submenu" then
                local sub = root:CreateButton(d.label)
                for i = 1, #d.rows do
                    local r = d.rows[i]
                    if r.isSeparator then
                        sub:CreateDivider()
                    else
                        local onClick = r.onClick
                        if r.copy and ns.CopyToClipboard then
                            onClick = function() ns.CopyToClipboard(r.copy, r.copyLink) end
                        end
                        local b = sub:CreateButton(r.text, onClick or function() end)
                        if r.disabled and b.SetEnabled then b:SetEnabled(false) end
                    end
                end
            end
        end
    end)
    return ok
end

local function HideMenus()
    if ns.HideTogglePopup then
        ns.HideTogglePopup("EasyFindGPSDockMenu")
        ns.HideTogglePopup("EasyFindGPSWindowMenu")
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
    local watch = Watch()
    if watch and f:GetLeft() then
        -- Over the Era watch's column: its lines run left from its right edge.
        local wl, wt, wr, wb = Look.ScreenRect(watch)
        local fl, ft, fr, fb = Look.ScreenRect(f)
        if not (wl and fl) then return false end
        local s = watch:GetEffectiveScale()
        local cx = (fl + fr) / 2
        return cx > math.min(wl, wr - Look.W * s) and cx < wr
            and ft > wb - DOCK_REACH * s and fb < wt + DOCK_REACH * s
    end
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
    local watch = Watch()
    if watch then
        -- Above the Era watch's middle: over its quests; else under them.
        local _, wt, _, wb = Look.ScreenRect(watch)
        local s = UIParent:GetEffectiveScale()
        return (wt and y * s > (wt + wb) / 2) and { top = true } or { bottom = true }
    end
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
GPS._topPad = topPad   -- dev tools
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
    if ins.api then ins.api.WatchRoom(ins.side, nil) return end
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

-- Room in the Era watch above or under its quests, in its scale; kept
-- until the side or the size changes.
function Look.WatchInsert(api, watch, slot, height, width)
    local side = slot and slot.top and "top" or "bottom"
    local k = dockFrame:GetEffectiveScale() / watch:GetEffectiveScale()
    local h, w = mfloor(height * k + 0.5), mfloor(width * k + 0.5)
    local ins = dockFrame.insert
    if ins and ins.api and ins.side == side and ins.height == h and ins.width == w then return side end
    ClearInsert(ClientTracker())
    api.WatchRoom(side, h, w)
    dockFrame.insert = { api = api, side = side, height = h, width = w }
    return side
end

-- In the room the Era watch keeps: its top left, or its bottom left.
function Look.PlaceInWatch(watch, api)
    local gap = dockFrame.dragGap
    if gap then
        Look.WatchInsert(api, watch, gap.slot, gap.height, gap.width or Look.W)
        return
    end
    if not dockFrame.docked or dockFrame.dragging or dockFrame.ghost then return end
    local db = DB()
    local side = Look.WatchInsert(api, watch, db and db.gpsWatchSlot, dockFrame:GetHeight() or 13, dockFrame:GetWidth() or Look.W)
    local wl, wt, _, wb = Look.ScreenRect(watch)
    -- Kept out of sight until the watch has a spot (it is built after login).
    local alpha = (wl and watch:IsVisible()) and 1 or 0
    if dockFrame:GetAlpha() ~= alpha then dockFrame:SetAlpha(alpha) end
    if not wl then return end
    local s = dockFrame:GetEffectiveScale()
    local lvl = (watch:GetFrameLevel() or 0) + 5
    if dockFrame:GetFrameLevel() ~= lvl then dockFrame:SetFrameLevel(lvl) end
    dockFrame:ClearAllPoints()
    if side == "top" then
        dockFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", wl / s, wt / s)
    else
        dockFrame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", wl / s, wb / s)
    end
end

-- A faded section takes no mouse: nothing of ours to hover or click
-- under a folded tracker. Out of a fight only (the cast buttons are
-- protected); rows made later are walked on the next placing.
local function DockMouse(on)
    if InCombatLockdown() then return end
    local function walk(f)
        for i = 1, select("#", f:GetChildren()) do
            local c = select(i, f:GetChildren())
            if on then
                if c.efMouseOff then
                    c.efMouseOff = nil
                    c:EnableMouse(true)
                end
            elseif c:IsMouseEnabled() then
                c.efMouseOff = true
                c:EnableMouse(false)
            end
            walk(c)
        end
    end
    walk(dockFrame)
end

local function PlaceDock()
    if not dockFrame then return end
    -- ClassicUI's tracker pick changed under it: drawn again in the new look.
    if (dockFrame.docked or dockFrame.floating) and dockFrame.look ~= SectionLook(dockFrame) then
        return RenderDock(dockFrame)
    end
    -- Nothing left to snap into (ClassicUI's tracker hidden): the window.
    if dockFrame.docked and not (dockFrame.dragging or dockFrame.ghost) and Host() == nil then
        GPS:Undock()
        return GPS:TogglePopout(true)
    end
    local watch, api = Watch()
    if watch then return Look.PlaceInWatch(watch, api) end
    local t = Tracker()
    if not t then return end
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
    DockMouse(not collapsed)
    local db = DB()
    local height = dockFrame:GetHeight() or DOCK_HEADER_H
    local above, below, ins = ApplyInsert(t, db and db.gpsDockSlot or { bottom = true }, height)
    if not ins then return end
    local pad = (not above) and (ins.provider and ((t.topModulePadding or 0) - topPad.seen) or ins.pad or 0) or 0
    -- Inset by the left margin on both sides, as the tracker's sections. A neighbor
    -- with content is the reference: at the top slot, the section below.
    local ref = above or below or (VisibleModules(t))[1] or t.modules[1]
    local margin = ref and ref.leftMargin or 0
    local refW = ref and ref.GetWidth and ref:GetWidth() or 0
    -- Anchored again only when the place changed (this runs four times a
    -- second), or when something else anchored it since (a drag's ghost
    -- rides the window): still hung where this left it.
    local placed = dockFrame.placed
    local _, hungOn = dockFrame:GetPoint(1)
    if placed and hungOn == (above or t) and placed.t == t and placed.above == above and placed.pad == pad
       and placed.height == height and placed.margin == margin and placed.refW == refW then
        return
    end
    placed = placed or {}
    placed.t, placed.above, placed.pad, placed.height, placed.margin, placed.refW = t, above, pad, height, margin, refW
    dockFrame.placed = placed
    dockFrame:ClearAllPoints()
    if above then
        -- Inside the room at the bottom of the section above: our bottom
        -- is its extended bottom, and the next section hangs off that.
        dockFrame:SetPoint("TOP", above, "BOTTOM", 0, height)
    else
        dockFrame:SetPoint("TOP", t, "TOP", 0, -pad)
    end
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
    if not (t or Watch()) then return end
    local want
    if frame and NearTracker(frame) then
        want = { slot = SlotAt(frame:GetTop() or 0), height = height, width = dockFrame:GetWidth() }
    end
    local had = dockFrame.dragGap
    if (want == nil) ~= (had == nil) or (want and had and (not SameSlot(want.slot, had.slot) or want.height ~= had.height)) then
        dockFrame.dragGap = want
        if not want then
            ClearInsert(t)
            if t then TrackerRelayout(t) end
        end
        PlaceDock()
    end
end

-- The section look as a ghost under a dragged window: the section frame
-- rides on the window, at the tracker's width, and the window fades.
local function ShowSectionGhost(window)
    local t = Tracker()
    if not (dockFrame and (t or Watch())) then return end
    dockFrame.ghost = true
    dockFrame.docked = true
    RenderDock(dockFrame)
    dockFrame.docked = nil
    dockFrame:ClearAllPoints()
    if t then dockFrame:SetWidth(t:GetWidth() or 260) end
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

-- The window's flight path advice, as tracker lines under the steps.
local function DockTipLine(f, i)
    f.tipLines = f.tipLines or {}
    local row = f.tipLines[i]
    if row then return row end
    row = CreateFrame("Button", nil, f)
    row.dash = row:CreateFontString(nil, "ARTWORK", "ObjectiveTrackerLineFont")
    row.dash:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.dash:SetText(QUEST_DASH or "- ")
    row.text = row:CreateFontString(nil, "ARTWORK", "ObjectiveTrackerLineFont")
    row.text:SetPoint("TOPLEFT", row.dash, "TOPRIGHT", 0, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(true)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if button ~= "RightButton" then return TipClick(self) end
        if f.ShowMenu then f.ShowMenu() end
    end)
    row:SetScript("OnEnter", TipEnter)
    row:SetScript("OnLeave", GameTooltip_Hide)
    f.tipLines[i] = row
    return row
end

-- The section's line for a start picked, with Reset back to the player.
local function DockFromLine(f)
    if f.fromLine then return f.fromLine end
    local row = CreateFrame("Button", nil, f)
    row.dash = row:CreateFontString(nil, "ARTWORK", "ObjectiveTrackerLineFont")
    row.dash:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.dash:SetText(QUEST_DASH or "- ")
    row.text = row:CreateFontString(nil, "ARTWORK", "ObjectiveTrackerLineFont")
    row.text:SetPoint("TOPLEFT", row.dash, "TOPRIGHT", 0, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    local reset = CreateFrame("Button", nil, row)
    reset:SetHeight(12)
    local label = reset:CreateFontString(nil, "ARTWORK", "ObjectiveTrackerLineFont")
    label:SetPoint("RIGHT", reset, "RIGHT", 0, 0)
    label:SetText(_G["RESET"] or "Reset")
    label:SetTextColor(unpack(ns.TEXT_DIM))
    reset:SetWidth((label:GetStringWidth() or 40) + 4)
    reset:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    reset:SetScript("OnEnter", function() label:SetTextColor(1, 1, 1) end)
    reset:SetScript("OnLeave", function() label:SetTextColor(unpack(ns.TEXT_DIM)) end)
    reset:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    reset:SetScript("OnClick", function(_, button)
        if button ~= "RightButton" then return GPS:SetStart(nil) end
        if f.ShowMenu then f.ShowMenu() end
    end)
    row.reset = reset
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(_, button)
        if button ~= "RightButton" then return GPS:PickStart(f) end
        if f.ShowMenu then f.ShowMenu() end
    end)
    row:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L["GPS_FROM_TT"], 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    f.fromLine = row
    return row
end

-- Where a drop leaves the section: its slot in the tracker, or its side of the Era watch.
local function SaveDockSlot(slot)
    local db = DB()
    if not (db and slot) then return end
    if Watch() then db.gpsWatchSlot = slot else db.gpsDockSlot = slot end
end

-- The section's look: the Era watch's, ClassicUI's restyled tracker's or
-- the game's; floating, the window style picked.
SectionLook = function(f)
    local host = Host()
    if f.docked then return host == "era" and "era" or (host == "classic" and "classic" or "game") end
    if PopoutStyle() == "era" then return "era" end
    return host == "classic" and "classic" or "game"
end

-- ClassicUI's tracker sizes: 12 a header, 11 a title, 10 a line, each up by
-- what the game's Text Size adds to its line font past 12.
Look.FONT = _G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
function Look.ClassicSize(base)
    local font = _G.ObjectiveTrackerLineFont
    if not font then return base end
    local _, h = font:GetFont()
    if type(h) ~= "number" or (issecretvalue and issecretvalue(h)) then return base end
    return base + mmax(0, mfloor(h + 0.5) - 12)
end

function Look.Restyle(fs, look, base, object)
    if fs.look == look then return end
    fs.look = look
    if look == "classic" then
        fs:SetFont(Look.FONT, Look.ClassicSize(base), "")
        fs:SetShadowColor(0, 0, 0, 1)
        fs:SetShadowOffset(1, -1)
    else
        fs:SetFontObject(object)
    end
end

-- ClassicUI's fold button: its sheet's module open and shut, each pushed.
Look.FOLD_SHEET = "Interface\\Buttons\\QuestTrackerButtons"
Look.FOLD_OPEN, Look.FOLD_OPEN_DOWN = { 0.273438, 0.390625, 0.265625, 0.484375 }, { 0.273438, 0.390625, 0.015625, 0.234375 }
Look.FOLD_SHUT, Look.FOLD_SHUT_DOWN = { 0.40625, 0.523438, 0.265625, 0.484375 }, { 0.40625, 0.523438, 0.015625, 0.234375 }
function Look.FoldArt(fold, look, open)
    if look == "classic" then
        fold:SetNormalTexture(Look.FOLD_SHEET)
        fold:SetPushedTexture(Look.FOLD_SHEET)
        fold:GetNormalTexture():SetTexCoord(unpack(open and Look.FOLD_OPEN or Look.FOLD_SHUT))
        fold:GetPushedTexture():SetTexCoord(unpack(open and Look.FOLD_OPEN_DOWN or Look.FOLD_SHUT_DOWN))
        fold:SetSize(15, 14)
    else
        if fold.ClearPushedTexture then fold:ClearPushedTexture() end
        fold:SetNormalAtlas(open and "UI-QuestTrackerButton-Secondary-Collapse" or "UI-QuestTrackerButton-Secondary-Expand")
        fold:SetSize(16, 15)
    end
end

-- The widgets of one look shown, the other's hidden.
function Look.Apply(f, look)
    if f.look == look then return end
    f.look = look
    local era = look == "era"
    f.head:SetShown(not era)
    f.plate:SetShown(look == "game")
    f.eraTitle:SetShown(era)
    f.eraGrip:SetShown(era)
    f.searchAnchor:ClearAllPoints()
    f.hitList:ClearAllPoints()
    if era then
        f.title:Hide()
        f.titleBtn:Hide()
        f.track:Hide()
        for i = 1, #f.lines do f.lines[i]:Hide() end
        for i = 1, #(f.tipLines or {}) do f.tipLines[i]:Hide() end
        if f.fromLine then f.fromLine:Hide() end
        f.searchAnchor:SetPoint("LEFT", f.eraTitle, "RIGHT", 4, 0)
        f.hitList:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -(Look.LINE + 4))
        f.hitList:SetPoint("RIGHT", f, "RIGHT", 0, 0)
        return
    end
    for i = 1, #f.eraLines do f.eraLines[i]:Hide() end
    f.searchAnchor:SetPoint("LEFT", f.header, "RIGHT", -2, 0)
    f.hitList:SetPoint("TOPLEFT", f, "TOPLEFT", DOCK_INDENT, -(DOCK_HEADER_H + 4))
    f.hitList:SetPoint("RIGHT", f.head, "RIGHT", 0, 0)
    Look.Restyle(f.header, look, 12, "ObjectiveTrackerHeaderFont")
    f.header:SetTextColor(1, 0.82, 0)
    Look.Restyle(f.title, look, 11, "ObjectiveTrackerLineFont")
    f.title:SetTextColor(1, 0.82, 0)
end

-- A line laid as the Era watch lays one: on one line, or wrapped at its width.
function Look.EraFill(fs, text)
    fs:SetWidth(0)
    fs:SetText(text)
    local w = fs:GetStringWidth() or 0
    if w <= Look.W then
        fs:SetSize(w, Look.LINE)
        return w, Look.LINE
    end
    fs:SetWidth(Look.W)
    local h = mmax(Look.LINE, fs:GetStringHeight() or Look.LINE)
    fs:SetHeight(h)
    return Look.W, h
end

function Look.EraLine(f, i)
    local row = f.eraLines[i]
    if row then return row end
    row = CreateFrame("Button", nil, f)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.text:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetJustifyV("TOP")
    row.text:SetIndentedWordWrap(true)
    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            if f.ShowMenu then f.ShowMenu() end
        elseif self.tip then
            TipClick(self)
        elseif self.from then
            GPS:PickStart(f)
        elseif self.index and IsShiftKeyDown() then
            GPS.GoToStep(self.index)
        end
    end)
    row:SetScript("OnEnter", function(self) if self.tip then TipEnter(self) end end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    -- A teleport's icon just past the line's end.
    row.cast = CastButton(row, 18)
    row.cast:SetSize(16, 16)
    f.eraLines[i] = row
    return row
end

-- Line n of the Era block at depth tall, its text in gray c: the row, its
-- width and the depth under it.
function Look.EraRow(f, n, text, c, tall)
    local row = Look.EraLine(f, n)
    local w, h = Look.EraFill(row.text, " - " .. text)
    row.text:SetTextColor(c, c, c)
    row.index, row.tip, row.from = nil, nil, nil
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -tall)
    row:SetSize(mmax(1, w), h)
    row:Show()
    return row, w, tall + h
end

-- The section in the Era watch's look: the route's title as a quest's,
-- its steps as the quest's lines, the current one white.
function Look.RenderEra(f)
    local route = Route()
    SearchHint(f)
    if GPS.picking == f then route = nil end
    local text = route and DestText(route) or L["APP_GPS"]
    local widest, tall = Look.EraFill(f.eraTitle, text)
    if f.eraGrip:IsMouseOver() then f.eraTitle:SetTextColor(1, 1, 1) else f.eraTitle:SetTextColor(unpack(Look.TITLE)) end
    local n = 0
    local hits = route and f.search and (f.hitCount or 0) > 0
    if route and f.search then
        -- The box after the title; the places it finds take the steps' place.
        f.search:SetPoint("RIGHT", f, "RIGHT", -10, 0)
        f.search:Show()
        f.hitList:SetShown(hits)
    end
    if hits then
        local k = math.min(f.hitCount, HIT_ROWS)
        f:SetHitView(k * ROW_H)
        widest = Look.W
        tall = tall + 4 + k * ROW_H + 4
    elseif route then
        local row, w
        local start = not route.arrived and Start()
        if start then
            n = n + 1
            row, w, tall = Look.EraRow(f, n, sformat(L["GPS_FROM_FMT"], start.name or "?"), 1, tall)
            row.text:SetTextColor(unpack(ns.TEXT_DIM))
            row.from = true
            widest = mmax(widest, w)
        end
        local items = route.steps
        if route.arrived then
            items = { { text = L["GPS_ARRIVED_AT_FMT"] and sformat(L["GPS_ARRIVED_AT_FMT"], route.dest.name or "?") or L["GPS_ARRIVED"] } }
        end
        local at = route.active or 1
        for i = 1, #items do
            local active = at == i and not route.arrived
            n = n + 1
            row, w, tall = Look.EraRow(f, n, StepText(items[i], active), (active or route.arrived) and 1 or (i < at and 0.5 or 0.8), tall)
            row.index = (not route.arrived) and i or nil
            widest = mmax(widest, w + (SetupCast(row.cast, items[i], active) and 20 or 0))
        end
        local tips = AdviceLines(route)
        for t = 1, tips and #tips or 0 do
            n = n + 1
            row, w, tall = Look.EraRow(f, n, tips[t].text, 1, tall)
            row.text:SetTextColor(unpack(ns.TEXT_DIM))
            row.tip = tips[t]
            widest = mmax(widest, w)
        end
    elseif f.search then
        -- The search box right of the name, and the places it finds under it.
        f.search:SetPoint("RIGHT", f, "RIGHT", -10, 0)
        f.search:Show()
        f.hitList:Show()
        local k = math.min(f.hitCount or 0, HIT_ROWS)
        f:SetHitView(k * ROW_H)
        widest = Look.W
        if k > 0 then tall = tall + 4 + k * ROW_H + 4 end
    end
    for i = n + 1, #f.eraLines do f.eraLines[i]:Hide() end
    f:SetSize(mmax(1, widest), mmax(Look.LINE, tall))
    PlaceDock()
end

RenderDock = function(f)
    if not (f.docked or f.floating) then return end
    local look = SectionLook(f)
    Look.Apply(f, look)
    if look == "era" then return Look.RenderEra(f) end
    local route = Route()
    local y = -(DOCK_HEADER_H + 8)
    local nTips = 0
    SearchHint(f)
    if GPS.picking == f then route = nil end
    if f.fromLine then f.fromLine:Hide() end
    local hits = route and f.search and (f.hitCount or 0) > 0
    if route and f.search then
        -- The box after the name in the banner; the places it finds take
        -- the steps' place.
        f.search:SetPoint("RIGHT", f.fold, "LEFT", -4, 0)
        f.search:Show()
        f.hitList:SetShown(hits)
    end
    if hits then
        f.title:Hide()
        f.titleBtn:Hide()
        f.track:Hide()
        for i = 1, #f.lines do f.lines[i]:Hide() end
        local k = math.min(f.hitCount, HIT_ROWS)
        f:SetHitView(k * ROW_H)
        y = -DOCK_HEADER_H - (4 + k * ROW_H + 4)
    elseif route then
        f.title:SetText(DestText(route))
        f.title:Show()
        f.titleBtn:Show()
        local start = not route.arrived and Start()
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
            -- A start picked: its line first; a click picks another.
            if start then
                local line = DockFromLine(f)
                Look.Restyle(line.text, look, 10, "ObjectiveTrackerLineFont")
                Look.Restyle(line.dash, look, 10, "ObjectiveTrackerLineFont")
                line.text:SetText(sformat(L["GPS_FROM_FMT"], start.name or "?"))
                line.text:SetWidth(mmax(40, lineW - (line.dash:GetStringWidth() or 8) - (line.reset:GetWidth() or 40) - 6))
                line.text:SetTextColor(unpack(ns.TEXT_DIM))
                line.dash:SetTextColor(unpack(ns.TEXT_DIM))
                line:ClearAllPoints()
                line:SetPoint("TOPLEFT", f, "TOPLEFT", DOCK_INDENT, y)
                line:SetPoint("RIGHT", f.head, "RIGHT", 0, 0)
                local h = mmax(12, line.text:GetStringHeight() or 12)
                line:SetHeight(h)
                line:Show()
                y = y - h - DOCK_LINE_GAP
            end
            -- Arrived: one line with the announcement in the steps' place.
            local items = route.steps
            if route.arrived then
                items = { { text = L["GPS_ARRIVED_AT_FMT"] and sformat(L["GPS_ARRIVED_AT_FMT"], route.dest.name or "?") or L["GPS_ARRIVED"] } }
            end
            for i = 1, #items do
                n = n + 1
                local row = DockLine(f, n)
                Look.Restyle(row.text, look, 10, "ObjectiveTrackerLineFont")
                Look.Restyle(row.dash, look, 10, "ObjectiveTrackerLineFont")
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
            local tips = AdviceLines(route)
            for t = 1, tips and #tips or 0 do
                nTips = t
                local row = DockTipLine(f, t)
                Look.Restyle(row.text, look, 10, "ObjectiveTrackerLineFont")
                Look.Restyle(row.dash, look, 10, "ObjectiveTrackerLineFont")
                row.tip = tips[t]
                row.text:SetText(tips[t].text)
                row.text:SetWidth(mmax(40, lineW - (row.dash:GetStringWidth() or 8)))
                row.text:SetTextColor(unpack(ns.TEXT_DIM))
                row.dash:SetTextColor(unpack(ns.TEXT_DIM))
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", f, "TOPLEFT", DOCK_INDENT, y)
                row:SetPoint("RIGHT", f.head, "RIGHT", 0, 0)
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
        for i = 1, #f.lines do f.lines[i]:Hide() end
        if f.search then
            -- The search box, and the places it finds, in the steps' place.
            f.search:SetPoint("RIGHT", f, "RIGHT", -10, 0)
            f.search:Show()
            f.hitList:Show()
            local n = math.min(f.hitCount or 0, HIT_ROWS)
            f:SetHitView(n * ROW_H)
            y = -DOCK_HEADER_H - (n > 0 and (4 + n * ROW_H + 4) or 0)
        end
    end
    for t = nTips + 1, #(f.tipLines or {}) do f.tipLines[t]:Hide() end
    -- Nothing to fold without a route.
    f.fold:SetShown(route ~= nil)
    Look.FoldArt(f.fold, look, f.expanded ~= false)
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
    f.plate = bg

    local header = head:CreateFontString(nil, "ARTWORK", "ObjectiveTrackerHeaderFont")
    header:SetPoint("LEFT", head, "LEFT", 7, 0)
    header:SetJustifyV("MIDDLE")
    header:SetText(L["APP_GPS"])
    header:SetTextColor(1, 0.82, 0)
    f.header = header
    -- The tag rides the name's top right corner, above the search box's
    -- magnifier that follows the name.
    local exp = ns.CreateFeatureTag(head, "exp", L["TAG_EXP_TITLE"], L["GPS_EXP_TT"], true)
    exp:SetPoint("BOTTOMLEFT", header, "LEFT", (header:GetStringWidth() or 0) - 7, 7)

    -- The fold button as the tracker's own section headers place theirs.
    local fold = CreateFrame("Button", nil, head)
    fold:SetSize(16, 16)
    fold:SetPoint("RIGHT", head, "RIGHT", 1, 0)
    fold:SetNormalAtlas("UI-QuestTrackerButton-Secondary-Collapse")
    fold:SetPushedAtlas("UI-QuestTrackerButton-Secondary-Collapse-Pressed")
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
    local function DragStart()
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
    end
    local function DragStop()
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
            SaveDockSlot(slot)
            PlaceDock()
            local t = Tracker()
            if t then TrackerRelayout(t) end
            DLog("-> placed: %s", FrameState(f))
        elseif PopoutStyle() ~= "easyfind" then
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
    end
    grip:SetScript("OnDragStart", DragStart)
    grip:SetScript("OnDragStop", DragStop)
    -- The menu anchors at the cursor, not the header: a click anywhere on
    -- the header then closes it, and the header keeps its drag.
    local menuAnchor = CreateFrame("Frame", nil, f)
    menuAnchor:SetSize(1, 1)
    -- The section's options: on the game's own menu, as the tracker's
    -- sections have theirs; the styled popup only if that is missing.
    local function ShowDockMenu()
            local defs = GPS.MenuRows(f)
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

    -- The Era watch's look: the title line, as a quest's, is the handle; a
    -- click opens the map's GPS page.
    local eraTitle = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    eraTitle:SetJustifyH("LEFT")
    eraTitle:SetJustifyV("TOP")
    eraTitle:SetIndentedWordWrap(true)
    eraTitle:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    eraTitle:Hide()
    f.eraTitle = eraTitle
    f.eraLines = {}
    local eraGrip = CreateFrame("Button", nil, f)
    eraGrip:SetAllPoints(eraTitle)
    eraGrip:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    eraGrip:RegisterForDrag("LeftButton")
    eraGrip:SetScript("OnDragStart", DragStart)
    eraGrip:SetScript("OnDragStop", DragStop)
    eraGrip:SetScript("OnClick", function(_, button)
        if button == "RightButton" then ShowDockMenu() elseif Route() then GPS:Open() end
    end)
    eraGrip:SetScript("OnEnter", function() eraTitle:SetTextColor(1, 1, 1) end)
    eraGrip:SetScript("OnLeave", function() eraTitle:SetTextColor(unpack(Look.TITLE)) end)
    eraGrip:Hide()
    f.eraGrip = eraGrip

    local title = f:CreateFontString(nil, "ARTWORK", "ObjectiveTrackerLineFont")
    title:SetJustifyH("LEFT")
    title:SetWordWrap(true)
    title:SetTextColor(1, 0.82, 0)
    f.title = title
    -- The destination line opens the map's GPS page and lights up under the
    -- cursor, as a quest header does; a right-click, the section's options.
    -- Steps keep their own click.
    local titleBtn = CreateFrame("Button", nil, f)
    titleBtn:SetAllPoints(title)
    titleBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    titleBtn:SetScript("OnEnter", function() title:SetTextColor(1, 1, 1) end)
    titleBtn:SetScript("OnLeave", function() title:SetTextColor(1, 0.82, 0) end)
    titleBtn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then ShowDockMenu() else GPS:Open() end
    end)
    titleBtn:Hide()
    f.titleBtn = titleBtn
    -- With no route, a search box in the banner right of the name, from the
    -- same builder as the window's folded row. Its finds list below.
    local searchAnchor = CreateFrame("Frame", nil, f)
    searchAnchor:SetSize(1, 20)
    searchAnchor:SetPoint("LEFT", header, "RIGHT", -2, 0)
    f.searchAnchor = searchAnchor
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
    local t = ClientTracker()
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
                if PopoutStyle() == "easyfind" and GPS.EnsurePopout and not (popoutFrame and popoutFrame.ghosting) then
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

    -- The time on the destination line; the section is laid out again
    -- only when the line grows or shrinks.
    f.SetEta = function(self, route)
        if not (route and self:IsShown()) or GPS.picking == self then return end
        local text = DestText(route)
        if self.look == "era" then
            if self.eraTitle:GetText() ~= text then RenderDock(self) end
        elseif self.title:IsShown() then
            local h = self.title:GetStringHeight()
            self.title:SetText(text)
            if self.title:GetStringHeight() ~= h then RenderDock(self) end
        end
    end
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
    local t = ClientTracker()
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
                    local f = (style ~= "easyfind") and dockFrame or popoutFrame
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
        { kind = "radio", label = L["GPS_STYLE_ERA"], value = "era", get = PopoutStyle, set = pick("era") },
    }
end

function GPS:Dock(slot)
    if not (Tracker() or Watch()) then return false end
    HideMenus()
    dockFrame = dockFrame or BuildDock()
    local db = DB()
    if db then db.gpsDocked = true end
    SaveDockSlot(slot)
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
            ins and (ins.side and ("watch " .. ins.side) or ins.module and (ins.module:GetName() or "?")) or "none",
            tostring(ins and ins.height), tostring(ins and ins.pad))
        local watch = Watch()
        out[#out + 1] = sformat("host %s look %s | watch %s", tostring((Host())), tostring(d.look),
            watch and FrameState(watch) or "none")
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

-- One menu for every surface (the section, snapped in or floating, and
-- the window): the route's actions, the settings, then the window's look.
function GPS.MenuRows(f)
    local defs = {}
    local route = Route()
    if f.docked then
        defs[#defs + 1] = { kind = "action", label = L["GPS_POPOUT"], onClick = function() GPS:Undock() GPS:TogglePopout(true) end }
        -- Closing the section ends the route with it.
        defs[#defs + 1] = { kind = "action", label = L["GPS_CLOSE_SECTION"], onClick = function()
            GPS:Clear()
            GPS:Undock()
            local c = CharDB()
            if c then c.popoutOpen = nil end
        end }
    else
        defs[#defs + 1] = { kind = "action", label = L["GPS_CLOSE"], onClick = function() GPS:TogglePopout(false) end }
    end
    if route then defs[#defs + 1] = { kind = "action", label = L["GPS_CLEAR"], onClick = function() GPS:Clear() end } end
    -- The trip's fields have a start field only with a route.
    if route or not f.trip then
        defs[#defs + 1] = { kind = "action", label = L["GPS_FROM_PICK"], onClick = function() GPS:PickStart(f) end }
    end
    if route and not route.arrived then
        defs[#defs + 1] = { kind = "action", label = L["GPS_ALONG"], onClick = function() GPS:SearchAlong(f) end }
    end
    -- The Era look has no tracking button beside the title.
    if f.look == "era" and route then
        defs[#defs + 1] = { kind = "action", label = RouteTracked() and L["GPS_TRACK_OFF"] or L["GPS_TRACK_ON"],
            onClick = ToggleRouteTracking }
    end
    -- The route as a link another EasyFind user clicks to be routed there too.
    local share = route and ns.ResultLinks and ns.ResultLinks.BuildRouteText
        and ns.ResultLinks:BuildRouteText(route.dest)
    local sendRows = share and ns.BuildSendLinkRows and ns.BuildSendLinkRows(share)
    if sendRows then defs[#defs + 1] = { kind = "submenu", label = L["CTX_SEND_LINK"], rows = sendRows } end
    if route then defs[#defs + 1] = { kind = "action", label = L["GPS_REPORT"], onClick = function() GPS:ReportRoute() end } end
    defs[#defs + 1] = { kind = "separator" }
    defs[#defs + 1] = GPS.WorldPinRow()
    defs[#defs + 1] = GPS.SnapRow()
    defs[#defs + 1] = GPS.AutoLearnRow()
    -- Snapped in, the section has one look.
    if f.docked then return defs end
    if f.isPopout then
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
        defs[#defs + 1] = { kind = "check", label = L["GPS_SIZE_NEXT_ONLY"],
            get = function() local db = DB() return db and db.gpsPopoutNextOnly == true end,
            set = function(v)
                local db = DB()
                if db then db.gpsPopoutNextOnly = v or nil end
                if popoutFrame then
                    popoutFrame.scrollOffset = 0
                    popoutFrame:Render()
                end
            end }
    end
    defs[#defs + 1] = { kind = "separator" }
    for _, d in ipairs(GPS.StyleRows()) do defs[#defs + 1] = d end
    if not f.isPopout then return defs end
    defs[#defs + 1] = { kind = "separator" }
    defs[#defs + 1] = { kind = "title", label = L["GPS_SIZE_WIDTH"] }
    for i = 1, #SIZE_WIDTHS do
        local px, key = SIZE_WIDTHS[i][1], SIZE_WIDTHS[i][2]
        defs[#defs + 1] = { kind = "radio", label = L[key], value = px,
            get = function() return (select(1, PopoutSize())) end,
            set = function() SetPopoutSize(px, (select(2, PopoutSize()))) end }
    end
    defs[#defs + 1] = { kind = "separator" }
    defs[#defs + 1] = { kind = "title", label = L["GPS_SIZE_HEIGHT"] }
    for i = 1, #SIZE_HEIGHTS do
        local px, key = SIZE_HEIGHTS[i][1], SIZE_HEIGHTS[i][2]
        defs[#defs + 1] = { kind = "radio", label = L[key], value = px or 0,
            get = function() return (select(2, PopoutSize())) or 0 end,
            set = function() SetPopoutSize((select(1, PopoutSize())), px) end }
    end
    return defs
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
        if Tracker() or Watch() then dockFrame = dockFrame or BuildDock() end
    end
    local function EndWindowDrag(self)
        self:StopMovingOrSizing()
        self.dragging = nil
        local near = (Tracker() or Watch()) and NearTracker(self)
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
        -- The close centered on the header row: the trip's first field (30
        -- tall and up with the text size), else the icon; the other
        -- buttons center on the close.
        local row = self.trip and self.trip:IsShown() and self.trip.rows[1]
        local h = row and row:GetHeight() or self.glyph:GetHeight()
        close:ClearAllPoints()
        close:SetPoint("RIGHT", self, "TOPRIGHT", -8, -(pad + h / 2))
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
        if ns.ShowTogglePopup then ns.ShowTogglePopup("EasyFindGPSWindowMenu", menuAnchor, GPS.MenuRows(f), {}) end
    end
    f:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then ShowWindowMenu() end
    end)
    f.ShowMenu = ShowWindowMenu
    f.menuAnchor = menuAnchor
    f.isPopout = true

    BuildSurface(f, {
        padX = 12, padY = 9, padRight = 84, bodyPadRight = 12, search = true, compact = true, titleOpensMap = true,
        onRouteChanged = function(self)
            -- The fold button folds a route; with none there is nothing to fold.
            if self.collapseBtn then self.collapseBtn:SetShown(Route() ~= nil) end
            local hits = self.search ~= nil and (self.hitCount or 0) > 0
            local folded = self.collapsed == true and Route() ~= nil
            if self.trip then ns.GPSTrip.Fold(self, folded) end
            -- The header row: the trip's fields while they show, else the icon.
            local headRow = (self.trip and self.trip:IsShown()) and self.trip:GetHeight() or 20
            local tight = (not Route() and not hits) or folded
            if tight then
                -- One tight title row: a folded route, or no route, where the row
                -- holds the search box and typed results unfold below.
                self:SetHeaderPad(8)
                self:SetHeight(8 + headRow + 8)
                self.list:Hide(); self.eta:Hide(); self.clearBtn:Hide(); self.empty:Hide()
                if self.search then
                    self.search:SetShown(not (Route() or GPS.planning or self.trip))
                    self.hitList:Hide()
                end
                return
            end
            self:SetHeaderPad(9)
            local _, fixed = PopoutSize()
            local head = 9 + headRow + 8   -- pad, the header row, gap
            local line = 4 + 14 + 8   -- the time line under the name
            local h
            -- With a route, typed places take the steps' place.
            self.list:SetShown(not (Route() and hits))
            if Route() and hits then
                h = head + line + (math.min(self.hitCount, HIT_ROWS) * ROW_H) + 12
            elseif Route() then
                h = head + line + (self.contentHeight or 0) + 4   -- the last row carries its own padding
            elseif hits then
                h = head + (math.min(self.hitCount, HIT_ROWS) * ROW_H) + 12
            elseif self.search then
                h = head + 4   -- the search box alone, in the header row
            else
                h = head + 2 + (self.empty:GetStringHeight() or 24) + 14
            end
            if fixed then
                -- A fixed height: the step list, or the hits, scroll inside it.
                self:SetHeight(fixed)
                if hits then self:SetHitView(fixed - head - (Route() and line or 0) - 12) end
                local avail = fixed - (head + line + 12)
                self.list:SetHeight(mmax(1, math.min(self.contentHeight or 0, avail)))
                self.list:SetClipsChildren(true)
            else
                self:SetHeight(mmax(60, h))
                if hits then self:SetHitView(HIT_ROWS * ROW_H) end
                self.list:SetClipsChildren(false)
                self.scrollOffset = 0
            end
        end,
    })
    -- The trip's fields in the window too, as on the map page.
    if ns.GPSTrip then ns.GPSTrip.BuildEditor(f) end
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
    if ns.FlatText then ns.FlatText(f) end
    return f
end

function GPS.EnsurePopout()
    popoutFrame = popoutFrame or BuildPopout()
    return popoutFrame
end

function GPS:TogglePopout(show)
    HideMenus()
    if PopoutStyle() ~= "easyfind" then
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
    GPS:Plan(nil, function()
        local steps, total, advice = GPS:BuildStops(route, route.via, nil, nil, "first")
        if not steps then
            route.via = nil
            steps, total, advice = GPS:BuildStops(route, nil, nil, nil, "first")
        end
        return steps, total, advice
    end, function(steps, total, advice)
        if not (steps and Route() == route) then return end
        route.steps, route.eta, route.total, route.advice, route.t, route.there = steps, total, total, advice, time(), nil
        closing.step = nil
        TrackStep(1)
        AfterRoute(true)
    end)
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
    local widths = {
        { label = L["GPS_LINE_THIN"], value = "thin" },
        { label = L["GPS_SIZE_NORMAL"], value = "normal" },
        { label = L["GPS_LINE_THICK"], value = "thick" },
    }
    local lineRow = ctx.CreateFlyoutPresetRow(page, L["GPS_LINE_WIDTH"], widths,
        function() local db = DB() return db and db.gpsLineWidth or "normal" end,
        function(v)
            local db = DB()
            if db then db.gpsLineWidth = (v ~= "normal") and v or nil end
        end,
        "EasyFindGPSLineWidth", "normal", L["GPS_LINE_WIDTH_TT"])
    lineRow:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -4)
    local clicks = {
        { label = L["CTX_GPS"], value = "gps" },
        { label = L["GPS_MAP_CLICK_PIN"], value = "pin" },
    }
    local clickRow = ctx.CreateFlyoutPresetRow(page, L["GPS_MAP_CLICK"], clicks,
        function() local db = DB() return db and db.gpsMapClick or "gps" end,
        function(v)
            local db = DB()
            if db then db.gpsMapClick = (v ~= "gps") and v or nil end
        end,
        "EasyFindGPSMapClick", "gps", L["GPS_MAP_CLICK_TT"])
    clickRow:SetPoint("TOPLEFT", lineRow, "BOTTOMLEFT", 0, -4)
    -- The lines' colors: a swatch per way of travel, the theme's beacon
    -- color until one is picked, and again on a right-click.
    local colorHead = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    colorHead:SetPoint("TOPLEFT", clickRow, "BOTTOMLEFT", 8, -8)
    colorHead:SetText(L["GPS_LINE_COLORS"])
    local prevRow = colorHead
    local ways = { { "walk", L["GPS_LINE_WALK"] }, { "taxi", L["GPS_AVOID_TAXI"] }, { "boat", L["GPS_AVOID_BOAT"] },
                   { "zeppelin", L["GPS_AVOID_ZEPPELIN"] }, { "tram", L["GPS_LINE_TRAM"] } }
    local swatches = {}
    local function PaintSwatches()
        local Preview = ns.GPSPreview
        for i = 1, #swatches do
            local c = Preview and Preview.LineColor(swatches[i].kind) or ns.GOLD_COLOR
            swatches[i].fill:SetColorTexture(c[1], c[2], c[3], 1)
        end
    end
    for _, way in ipairs(ways) do
        local kind, label = way[1], way[2]
        local wrow = CreateFrame("Frame", nil, page)
        wrow:SetSize(ctx.SELECTOR_ROW_W, 22)
        wrow:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT", prevRow == colorHead and -8 or 0, prevRow == colorHead and -4 or 0)
        local text = wrow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("LEFT", wrow, "LEFT", 8, 0)
        text:SetText(label)
        local swatch = CreateFrame("Button", nil, wrow)
        swatch:SetSize(18, 18)
        swatch:SetPoint("LEFT", wrow, "RIGHT", -ctx.SELECTOR_BTN_W - 18, 0)
        swatch:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        if ns.CreateRoundedRectBorder then ns.CreateRoundedRectBorder(swatch) end
        local fill = swatch:CreateTexture(nil, "ARTWORK")
        fill:SetPoint("TOPLEFT", 2, -2)
        fill:SetPoint("BOTTOMRIGHT", -2, 2)
        swatch.fill, swatch.kind = fill, kind
        swatches[#swatches + 1] = swatch
        local function Changed()
            PaintSwatches()
            if ns.GPSPreview and ns.GPSPreview.ColorsChanged then ns.GPSPreview.ColorsChanged() end
        end
        swatch:SetScript("OnClick", function(_, button)
            local db = DB()
            if not db then return end
            if button == "RightButton" then
                if db.gpsLineColors then db.gpsLineColors[kind] = nil end
                Changed()
                return
            end
            local c = ns.GPSPreview and ns.GPSPreview.LineColor(kind) or ns.GOLD_COLOR
            if not ns.PickColor then return end
            ns.PickColor(c[1], c[2], c[3], function(r, g, b)
                db.gpsLineColors = db.gpsLineColors or {}
                db.gpsLineColors[kind] = { r, g, b }
                Changed()
            end)
        end)
        Utils.AttachDelayedTooltip(swatch, "ANCHOR_RIGHT", function() return label, L["GPS_LINE_COLOR_TT"] end)
        prevRow = wrow
    end
    PaintSwatches()
    if not ctx.CreateCheckbox then return end
    local arrow = ctx.CreateCheckbox(page, "GPSArrow", L["GPS_ARROW"], L["GPS_ARROW_TT"], true)
    arrow:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT", 0, -6)
    local d0 = DB()
    arrow:SetChecked(not (d0 and d0.gpsArrow == false))
    if arrow.RefreshVisual then arrow:RefreshVisual() end
    arrow:SetScript("OnClick", function(self)
        local d = DB()
        if d then d.gpsArrow = (not self:GetChecked()) and false or nil end
        if self.RefreshVisual then self:RefreshVisual() end
        Refresh()
    end)
    local texts = {
        { label = L["GPS_ARROW_TEXT_FULL"], value = "full" },
        { label = L["GPS_ARROW_TEXT_RANGE"], value = "range" },
        { label = L["GPS_ARROW_TEXT_STEP"], value = "step" },
        { label = _G["OFF"] or "Off", value = "off" },
    }
    local textRow = ctx.CreateFlyoutPresetRow(page, L["GPS_ARROW_TEXT"], texts,
        function() local db = DB() return db and db.gpsArrowText or "full" end,
        function(v)
            local db = DB()
            if db then db.gpsArrowText = (v ~= "full") and v or nil end
            Refresh()
        end,
        "EasyFindGPSArrowText", "full", L["GPS_ARROW_TEXT_TT"])
    textRow:SetPoint("TOPLEFT", arrow, "BOTTOMLEFT", 0, -4)
    local mini = ctx.CreateCheckbox(page, "GPSMinimap", L["GPS_MINIMAP_LINE"], L["GPS_MINIMAP_LINE_TT"], true)
    mini:SetPoint("TOPLEFT", textRow, "BOTTOMLEFT", 0, -6)
    mini:SetChecked(not (d0 and d0.gpsMinimap == false))
    if mini.RefreshVisual then mini:RefreshVisual() end
    mini:SetScript("OnClick", function(self)
        local d = DB()
        if d then d.gpsMinimap = (not self:GetChecked()) and false or nil end
        if self.RefreshVisual then self:RefreshVisual() end
        Refresh()
    end)
    -- Ways of travel a route leaves out unless nothing else gets there.
    local head = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    head:SetPoint("TOPLEFT", mini, "BOTTOMLEFT", 0, -14)
    head:SetText(L["GPS_AVOID"])
    local prev = head
    local kinds = { "taxi", "boat", "zeppelin", "portal", "teleport" }
    -- Danger needs the creature catalog, roads the walking grid (WoW Forever).
    if ns.NPC_DATA and ns.NPC_DATA.danger then kinds[#kinds + 1] = "danger" end
    if ns.GPSNav and ns.GPSNav.HasRoads and ns.GPSNav.HasRoads(0) then kinds[#kinds + 1] = "offroad" end
    for _, kind in ipairs(kinds) do
        local tip = (kind == "danger" or kind == "offroad") and L["GPS_AVOID_" .. kind:upper() .. "_TT"] or L["GPS_AVOID_TT"]
        local box = ctx.CreateCheckbox(page, "GPSAvoid" .. kind, L["GPS_AVOID_" .. kind:upper()], tip, true)
        box:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, prev == head and -4 or 0)
        local db = DB()
        box:SetChecked(db and db.gpsAvoid and db.gpsAvoid[kind] or false)
        if box.RefreshVisual then box:RefreshVisual() end
        box:SetScript("OnClick", function(self)
            local d = DB()
            if not d then return end
            d.gpsAvoid = d.gpsAvoid or {}
            d.gpsAvoid[kind] = self:GetChecked() or nil
            if self.RefreshVisual then self:RefreshVisual() end
            local route = Route()
            if route and not route.arrived then Reroute(route) end
        end)
        prev = box
    end
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
loginFrame:RegisterEvent("PLAYER_ALIVE")
loginFrame:RegisterEvent("PLAYER_UNGHOST")
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
    -- Released to a graveyard, risen, or back in the world as either.
    if event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        GhostOrRisen()
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        Utils.SafeAfter(1, GhostOrRisen)
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
        -- Nothing to snap into (ClassicUI's tracker hidden): the window.
        if not GPS:Dock() then GPS:TogglePopout(true) end
    elseif c and c.popoutOpen then
        GPS:TogglePopout(true)
    end
    -- What every plan decodes first, done now in the planner's slices
    -- rather than on the session's first click.
    -- The player's continent only; another decodes inside the plan that
    -- needs it. Warm counts as a use, so an idle minute lets it go.
    local Nav = ns.GPSNav
    if Nav and Nav.Warm and ns.GPSNavData then
        Utils.SafeAfter(2, function()
            if GPS:IsPlanning() then return end
            local m = C_Map.GetBestMapForUnit("player")
            if not m then return end
            local ok, pos = pcall(C_Map.GetPlayerMapPosition, m, "player")
            local ci = ok and pos and WorldPos(m, pos:GetXY())
            if not (ci and ns.GPSNavData[ci]) then return end
            GPS:Plan(nil, function()
                Nav.yieldCo = coroutine.running()
                Nav.Warm(ci)
                Nav.yieldCo = nil
            end, function() end)
        end)
        -- The grid's base64 decoded once, at the pre-load moment, never
        -- under a plan (its readers hold the table they started with).
        if Nav.DecodeBlobs then
            local function decode()
                if GPS:IsPlanning() then Utils.SafeAfter(5, decode) return end
                Nav.DecodeBlobs()
            end
            Utils.SafeAfter(12, decode)
        end
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
    -- Its walks are drawn afresh this session.
    AfterRoute()
end)
