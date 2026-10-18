-- EasyFind GPS: the arrow at the character.
--
-- While a route is followed, an arrow under the character points the way
-- on foot as it runs: at a spot a little ahead along the walk, so it turns
-- with every bend, with the step, the yards left on the walk and the times
-- left in the beacon's plate under it. A walk hardly longer than the line
-- to its spot and close beside it is aimed at the spot, past the grid's
-- wiggles; a way round (out along a pier) is followed. A few yards
-- beside the walk it leads alongside it, not back onto it, where nothing
-- stands between. At a ride's boarding spot it points there; on board, and
-- where the game gives no facing (instances), it rests. Shift-drag moves it.
local ns = EasyFind and EasyFind._ns
if not ns then return end
local Arrow = {}
ns.GPSArrow = Arrow

local mmax, mmin, mabs, matan2, mpi = math.max, math.min, math.abs, math.atan2 or math.atan, math.pi

local TEX_ARROW = "Interface\\AddOns\\EasyFind\\MapSearch\\Images\\arrow-hq"   -- points down as drawn
local SIZE = 44
local HOME_Y = -130            -- under the character, from the screen's center
local AHEAD = 25               -- yards along the walk the arrow aims at
local NEAR_STRAIGHT = 1.1      -- a walk within this of the straight line is aimed at its spot
local WIGGLE = 10              -- yards it may stray from that line: two or three grid cells
local LANE = 10                -- yards beside the walk still walked alongside it
local AT_RIDE = 60             -- yards from a ride's boarding spot: still pointing at it
local THROTTLE = 0.03

local frame, art, plate, driver
local since = 0
local aimCi                    -- the continent the last aim was taken on

local function DB() return EasyFind and EasyFind.db end
local function Route() local g = ns.GPS return g and g.CurrentRoute and g.CurrentRoute() end
local function Enabled() local db = DB() return not (db and db.gpsArrow == false) end

-- The way from (px, py) to (ax, ay) as the game turns: from north toward west.
local function Bearing(ci, px, py, ax, ay)
    local a = ns.GPSFollow.Axes(ci)
    if not a then return nil end
    local dx, dy = ax - px, ay - py
    return matan2(dx * a[3] + dy * a[4], dx * a[1] + dy * a[2])
end
Arrow._Bearing = Bearing   -- tests

local function Clear(ci, px, py, x, y)
    local Nav = ns.GPSNav
    return Nav and Nav.Straight and Nav.Straight(ci, px, py, x, y, IsIndoors and IsIndoors()) == true
end

-- How far the rest of the walk (from stretch s) strays from the line from
-- (px, py) to its spot d yards off, in yards.
local function Spread(path, s, px, py, tx, ty, d)
    if d < 1 then return 0 end
    local pts, far = path.pts, 0
    local ux, uy = (tx - px) / d, (ty - py) / d
    for v = s + 1, #pts / 2 do
        local off = mabs((pts[2 * v - 1] - px) * uy - (pts[2 * v] - py) * ux)
        if off > far then far = off end
    end
    return far
end
Arrow._Spread = Spread   -- the dev probe

-- Where the arrow points from where the player stands, and the yards left,
-- or nothing to point at.
local function Aim()
    local f = ns.GPSFollow.Now()
    if not f then return nil end
    aimCi = f.ci
    local px, py = f.px, f.py
    if f.ride then
        if f.straight > AT_RIDE then return nil end
        return px, py, f.tx, f.ty, f.straight
    end
    local path = f.path
    if not path then return px, py, f.tx, f.ty, f.straight end
    local left = mmax(0, path.len - f.along)
    -- A walk hardly longer than the line to the spot and never far beside
    -- it bends only round the grid's small blocks (a bush, a post):
    -- straight at the spot. Far off it, the walk is a way round.
    if left <= f.straight * NEAR_STRAIGHT and Spread(path, f.seg, px, py, f.tx, f.ty, f.straight) <= WIGGLE then
        return px, py, f.tx, f.ty, left
    end
    local ax, ay = ns.GPSFollow.PointAt(path, f.along + AHEAD, f.seg)
    -- Beside the walk: alongside it, up to LANE out, closing in on the
    -- last stretch so the spot itself is reached.
    local keep = f.off > 0.5 and mmin(1, LANE / f.off) * mmax(0, mmin(1, (left - AHEAD) / AHEAD)) or 0
    if keep > 0 then
        local sx, sy = (px - f.qx) * keep, (py - f.qy) * keep
        for _ = 1, 2 do
            if Clear(f.ci, px, py, ax + sx, ay + sy) then return px, py, ax + sx, ay + sy, left end
            sx, sy = sx / 2, sy / 2
        end
    end
    return px, py, ax, ay, left
end

Arrow._Aim = Aim   -- tests

local function SavePlace()
    local cx, cy = frame:GetCenter()
    if not (cx and cy) then return end
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx, cy)
    local db = DB()
    if db then db.gpsArrowPos = { x = cx, y = cy } end
end

local function Build()
    frame = CreateFrame("Frame", "EasyFindGPSArrow", UIParent)
    frame:SetSize(SIZE, SIZE)
    frame:SetFrameStrata("LOW")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(false)
    frame:RegisterForDrag("LeftButton")
    local db = DB()
    local pos = db and db.gpsArrowPos
    if pos and pos.x and pos.y then
        frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", pos.x, pos.y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, HOME_Y)
    end
    art = frame:CreateTexture(nil, "ARTWORK")
    art:SetAllPoints(frame)
    art:SetTexture(TEX_ARROW)
    ns.GPSWorldPin.Tint(art, "arrow", 1)
    plate = ns.GPSWorldPin.NewPlate(frame)
    plate:SetPoint("TOP", frame, "BOTTOM", 0, -7)
    -- Clicks pass through to the world; Shift held, the arrow and a grip
    -- over the plate take them to move it. The plate's right-click stays.
    local grip = CreateFrame("Frame", nil, plate)
    grip:SetAllPoints(plate)
    grip:EnableMouse(false)
    grip:RegisterForDrag("LeftButton")
    grip:SetScript("OnMouseDown", function(_, button) plate:GetScript("OnMouseDown")(plate, button) end)
    grip:SetScript("OnMouseUp", function(_, button) plate:GetScript("OnMouseUp")(plate, button) end)
    local function DragStart() if IsShiftKeyDown() then frame:StartMoving() end end
    local function DragStop()
        frame:StopMovingOrSizing()
        SavePlace()
    end
    local function TakeMouse()
        local shift = IsShiftKeyDown()
        frame:EnableMouse(shift)
        grip:EnableMouse(shift)
    end
    -- The game refuses the pass-through in a fight: built in one, the plate
    -- takes no clicks until it ends.
    local function PassClicks()
        local ok, why = ns.Utils.SafeCallMethod(plate, "SetPropagateMouseClicks", true)
        if why == "combat" then return frame:RegisterEvent("PLAYER_REGEN_ENABLED") end
        frame:UnregisterEvent("PLAYER_REGEN_ENABLED")
        plate:EnableMouse(ok)
    end
    frame:SetScript("OnDragStart", DragStart)
    frame:SetScript("OnDragStop", DragStop)
    grip:SetScript("OnDragStart", DragStart)
    grip:SetScript("OnDragStop", DragStop)
    frame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_ENABLED" then PassClicks() else TakeMouse() end
    end)
    frame:SetScript("OnShow", function(self)
        self:RegisterEvent("MODIFIER_STATE_CHANGED")
        TakeMouse()
    end)
    frame:SetScript("OnHide", function(self)
        self:UnregisterEvent("MODIFIER_STATE_CHANGED")
        self:EnableMouse(false)
    end)
    plate:EnableMouse(false)
    PassClicks()
    frame:Hide()
end

local function Update()
    local px, py, ax, ay, left = Aim()
    local facing = px and GetPlayerFacing and GetPlayerFacing()
    local bearing = facing and not (issecretvalue and issecretvalue(facing)) and Bearing(aimCi, px, py, ax, ay)
    if not bearing then
        if frame then frame:Hide() end
        return
    end
    if not frame then Build() end
    -- Facing turns from north toward west too; the art points down at rest.
    art:SetRotation(bearing - facing + mpi)
    local Pin = ns.GPSWorldPin
    local text, line, trip = Pin.PlateLines(Route(), left)
    plate:SetShown(text ~= nil)
    if text then Pin.FillPlate(plate, text, line, trip) end
    frame:Show()
end

local function Tick(_, dt)
    since = since + dt
    if since < THROTTLE then return end
    since = 0
    Update()
end

-- Whether the arrow points the way now: the beacon's own edge arrow stays
-- away while it does.
function Arrow:Guiding() return frame ~= nil and frame:IsShown() end

-- A route change or the option flipped: runs only while there is a way to point.
function Arrow:Refresh()
    local route = Route()
    local on = Enabled() and route ~= nil and not route.arrived and not route.untracked
    if on then
        since = 0
        driver:SetScript("OnUpdate", Tick)
        Update()
    else
        driver:SetScript("OnUpdate", nil)
        if frame then frame:Hide() end
    end
end

driver = CreateFrame("Frame")
Arrow._driver = driver   -- dev tools
