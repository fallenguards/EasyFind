local _, ns = ...

-- Window manager core. Resolves a target frame, computes a snap rectangle via
-- SnapMath, applies it (position always; size only for entries that opt in,
-- scale-to-fit for fixed-layout Blizzard panels), persists the result, and
-- keeps it in place against the default UI's re-anchoring. Combat-safe: moving
-- a protected frame while locked down is queued and replayed when combat ends.

local Manager = {}
ns.WindowManager = Manager

local Utils = ns.Utils
local L = ns.L
local SnapMath = ns.SnapMath
local Registry = ns.WindowRegistry

local InCombatLockdown = InCombatLockdown
local hooksecurefunc = hooksecurefunc
local UIParent = UIParent
local CreateFrame = CreateFrame
local HasAction = HasAction
local IsShiftKeyDown = IsShiftKeyDown
local GetCursorPosition = GetCursorPosition
local GetTime = GetTime
local pairs = Utils.pairs
local type = Utils.type
local xpcall = Utils.xpcall
local mmin = Utils.mmin
local ssub = Utils.ssub
local SafeCallMethod = Utils.SafeCallMethod
local ErrorHandler = Utils.ErrorHandler

-- Scale-to-fit bounds for fixed-layout panels: enough head/foot room to fill
-- most rects without blowing nine-slice art past readability.
local FIT_SCALE_MIN, FIT_SCALE_MAX = 0.3, 2.0
-- Exported: the interactive resize stops a divider once the window it is
-- growing has hit this ceiling, so the neighbor is never shrunk to buy space
-- the dragged window cannot use.
ns.WINDOW_FIT_SCALE_MAX = FIT_SCALE_MAX
ns.WINDOW_FIT_SCALE_MIN = FIT_SCALE_MIN

-- Guard so our own SetPoint calls inside the re-assert hook don't recurse.
local ignoreSetPointHook = false
-- Frames we've already installed the SetPoint re-assert hook on.
local hooked = {}
-- Per-frame applied state: which spec key is currently applied, used for
-- cycle-on-repeat. Keyed by frame name.
local appliedSpec = {}
-- Last command + target for the cycling interaction.
local lastCommand, lastTargetName
-- Most-recently-shown registered frame name, our default target.
local frontTargetName
-- Frames whose OnShow we've hooked to track the front target.
local showHooked = {}
-- Defined with the multi-panel block below; frame hooks call it on sight so a
-- load-on-demand panel detaches before its first show.
-- The multi-panel state machine below owns every detach transition; frame
-- hooks and the ShowUIPanel hook route through these three and never touch
-- panel state themselves.
local EnsurePanelDetached   -- ATTACHED/PENDING -> DETACHED, when eligible
local SweepDetachablePanels -- catch panels whose frame just came into being
local ShowIfDetached        -- the show + anchor a detached panel no longer gets
-- Frames carrying the unlock-mode drag hooks.
local dragHooked = {}
-- Pending actions deferred past combat lockdown: name -> specKey, or the
-- RESTORE_SENTINEL for a queued restore.
local pendingMoves = {}
local RESTORE_SENTINEL = "restore"
-- Single event frame: replays queued moves on combat end (PLAYER_REGEN_ENABLED)
-- and installs hooks on load-on-demand panels as they appear (ADDON_LOADED).
local eventFrame

-- Load-on-demand Blizzard modules that own registry frames; ADDON_LOADED
-- rescans only for these and unregisters once every registry frame is hooked.
local LOD_ADDONS = {
    ["Blizzard_Collections"] = true,
    ["Blizzard_EncounterJournal"] = true,
    ["Blizzard_PlayerSpells"] = true,
    ["Blizzard_AchievementUI"] = true,
    ["Blizzard_Communities"] = true,
    ["Blizzard_Professions"] = true,
}

local scratchRect = {}

local function Toast(msg)
    if EasyFind and EasyFind.Print then EasyFind:Print(msg) end
end

local function PositionStore()
    if not (EasyFind and EasyFind.db) then return nil end
    EasyFind.db.windowPositions = EasyFind.db.windowPositions or {}
    return EasyFind.db.windowPositions
end

-- UIParent work area in UIParent coordinates. SetPoint offsets on a frame
-- parented to UIParent are interpreted at UIParent's scale, so we measure the
-- work area there and let the frame's own scale ride on top.
local function WorkArea()
    if not UIParent then return nil, nil end
    return UIParent:GetWidth(), UIParent:GetHeight()
end

local function CurrentGap()
    local gap = EasyFind and EasyFind.db and EasyFind.db.windowGap
    if type(gap) ~= "number" or gap < 0 then return ns.WINDOW_GAP_DEFAULT end
    return gap
end

-- Anchor a frame's TOPLEFT at (x, y) in UIParent units, converting into the
-- frame's own coordinate space by the ratio of effective scales.
local function AnchorTopLeft(frame, x, y)
    local ratio = 1
    local fes = frame.GetEffectiveScale and frame:GetEffectiveScale()
    if fes and fes > 0 and UIParent then
        ratio = UIParent:GetEffectiveScale() / fes
    end
    ignoreSetPointHook = true
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x * ratio, y * ratio)
    ignoreSetPointHook = false
    return ratio
end

-- Scale + anchors (+ size for resizable entries) snapshotted before our
-- first mutation of a frame this session. Restore replays this snapshot
-- exactly, instead of trusting the panel layout system to reseat a frame
-- we insecurely moved (it often does not, leaving "default" wrong).
local origPlacement = {}

local function CaptureDefaultPlacement(entry, frame)
    if origPlacement[entry.name] then return end
    if not (frame.GetNumPoints and frame:GetNumPoints() > 0) then return end
    local snap = { scale = frame.GetScale and frame:GetScale() or 1, points = {} }
    if entry.resizable and frame.GetWidth then
        snap.w, snap.h = frame:GetWidth(), frame:GetHeight()
    end
    for i = 1, frame:GetNumPoints() do
        snap.points[i] = { frame:GetPoint(i) }
    end
    origPlacement[entry.name] = snap
end

-- Reposition a frame into a computed rect (UIParent units, y negative
-- downward). Own windows are anchor-only (content-driven size). Entries with
-- resizable = true fill the rect via SetSize. Everything else keeps its
-- layout intact: scale-to-fit inside the rect, then center there -- resizing
-- a fixed-layout Blizzard panel stretches nine-slice art and misplaces
-- children, so it is never sized. Protected frames are mutated only out of
-- combat.
-- Panels paint outside their own rect: the quest log hangs a tab strip off its
-- right edge, the character panel a tab row off its bottom. Fitting to
-- GetWidth/GetHeight alone lets that art spill into the neighboring zone, so
-- measure how far the shown children reach past each edge. Capped per side so
-- one oversized child (a full-screen backdrop) cannot shrink a panel to
-- nothing, and only direct children count -- deeper art rides inside them.
local OVERHANG_CAP = 0.5

local function AccountOverhang(obj, uiScale, left, top, w, h, out)
    if not (obj and obj.IsShown and obj:IsShown() and obj.GetLeft) then return end
    local l, r, t, b = obj:GetLeft(), obj:GetRight(), obj:GetTop(), obj:GetBottom()
    if not (l and r and t and b) then return end
    local s = (obj.GetEffectiveScale and obj:GetEffectiveScale() or uiScale) / uiScale
    local objTop = (UIParent:GetHeight() or 0) - t * s
    local objBottom = (UIParent:GetHeight() or 0) - b * s
    local overL, overR = left - l * s, r * s - (left + w)
    local overT, overB = top - objTop, objBottom - (top + h)
    if overL > out[1] then out[1] = overL end
    if overR > out[2] then out[2] = overR end
    if overT > out[3] then out[3] = overT end
    if overB > out[4] then out[4] = overB end
end

local overhangOut = {}

local function ContentOverhang(frame, uiScale, left, top, w, h)
    overhangOut[1], overhangOut[2], overhangOut[3], overhangOut[4] = 0, 0, 0, 0
    if frame.GetChildren then
        local function visit(...)
            for i = 1, select("#", ...) do
                AccountOverhang((select(i, ...)), uiScale, left, top, w, h, overhangOut)
            end
        end
        visit(frame:GetChildren())
        if frame.GetRegions then visit(frame:GetRegions()) end
    end
    local capW, capH = w * OVERHANG_CAP, h * OVERHANG_CAP
    if overhangOut[1] > capW then overhangOut[1] = capW end
    if overhangOut[2] > capW then overhangOut[2] = capW end
    if overhangOut[3] > capH then overhangOut[3] = capH end
    if overhangOut[4] > capH then overhangOut[4] = capH end
    return overhangOut[1], overhangOut[2], overhangOut[3], overhangOut[4]
end

local function ApplyRect(frame, entry, rect)
    if not frame or not rect then return false end
    if InCombatLockdown() and frame.IsProtected and frame:IsProtected() then return false end

    if entry.resizable then
        local ratio = AnchorTopLeft(frame, rect.x, rect.y)
        if frame.SetSize then
            frame:SetSize(rect.w * ratio, rect.h * ratio)
        end
    elseif entry.own then
        AnchorTopLeft(frame, rect.x, rect.y)
    else
        local uiScale = UIParent and UIParent:GetEffectiveScale() or 1
        local fes = frame:GetEffectiveScale() or 1
        local w = (frame:GetWidth() or 0) * fes / uiScale
        local h = (frame:GetHeight() or 0) * fes / uiScale
        -- Bottom tab rows hang outside the frame rect; count them as part of
        -- the height for fitting and centering so they never bleed past the
        -- target rect or the screen edge.
        local pad = (entry.padBottom or 0) * fes / uiScale
        local frameLeft = (frame:GetLeft() or 0) * fes / uiScale
        local frameTop = (UIParent:GetHeight() or 0)
            - ((frame:GetBottom() or 0) * fes / uiScale + h)
        -- Same lesson as the drag hooks: a walk over an unknown hierarchy must
        -- never be able to break the snap itself, so fall back to no overhang.
        local measured, overL, overR, overT, overB =
            xpcall(ContentOverhang, ErrorHandler, frame, uiScale, frameLeft, frameTop, w, h)
        if not measured then overL, overR, overT, overB = 0, 0, 0, 0 end
        if overB > pad then pad = overB end
        if w > 0 and h > 0 and frame.SetScale then
            local factor = mmin(rect.w / (w + overL + overR), rect.h / (h + overT + pad))
            local newScale = (frame:GetScale() or 1) * factor
            if newScale > FIT_SCALE_MAX then newScale = FIT_SCALE_MAX
            elseif newScale < FIT_SCALE_MIN then newScale = FIT_SCALE_MIN end
            local prevScale = frame:GetScale() or 1
            frame:SetScale(newScale)
            local grew = prevScale > 0 and newScale / prevScale or 1
            fes = frame:GetEffectiveScale() or 1
            w = (frame:GetWidth() or 0) * fes / uiScale
            h = (frame:GetHeight() or 0) * fes / uiScale
            pad = (entry.padBottom or 0) * fes / uiScale
            -- The overhang scales with the frame; re-measuring here would read
            -- a mid-relayout state, so carry it through the scale change.
            overL, overR, overT, overB = overL * grew, overR * grew, overT * grew, overB * grew
            if overB > pad then pad = overB end
        end
        -- Zone gravity: hug the screen edge(s) the zone touches, so a corner
        -- snap pins the window's corner to the screen corner and repeat-click
        -- size steps grow/shrink from that corner. Centered on free axes.
        -- Placement is by the VISIBLE extent, overhang included, so a side tab
        -- strip lands inside the zone instead of over the neighbor.
        local x
        if rect.gx == "left" then x = rect.x + overL
        elseif rect.gx == "right" then x = rect.x + rect.w - w - overR
        else x = rect.x + (rect.w - (overL + w + overR)) / 2 + overL end
        local y
        if rect.gy == "top" then y = rect.y - overT
        elseif rect.gy == "bottom" then y = rect.y - (rect.h - h - pad)
        else y = rect.y - (rect.h - (overT + h + pad)) / 2 - overT end
        AnchorTopLeft(frame, x, y)
    end

    -- UIPanel frames get shoved by the layout system; flag as user-placed and
    -- re-assert our anchor whenever Blizzard re-anchors them.
    if entry.uiPanel and frame.SetUserPlaced then
        SafeCallMethod(frame, "SetUserPlaced", true)
    end
    return true
end

-- Persist the applied spec key (English/stable) so it can be re-applied on a
-- later session. The search bar additionally mirrors its anchor into the legacy
-- uiSearchPosition store so its drag system stays the source of truth there.
local function Persist(entry, specKey)
    local store = PositionStore()
    if store then store[entry.name] = specKey end
    if entry.own and entry.name == "EasyFindSearchFrame" and EasyFind and EasyFind.db then
        local frame = Registry:GetFrame(entry)
        if frame and frame.GetPoint then
            local point, _, relPoint, x, y = frame:GetPoint()
            if point then EasyFind.db.uiSearchPosition = { point, relPoint, x, y } end
        end
    end
end

local function ReassertHook(frame, entry)
    if hooked[entry.name] then return end
    hooked[entry.name] = true
    hooksecurefunc(frame, "SetPoint", function()
        if ignoreSetPointHook then return end
        local specKey = appliedSpec[entry.name]
        if not specKey then return end
        if InCombatLockdown() and frame.IsProtected and frame:IsProtected() then return end
        local w, h = WorkArea()
        local rect = SnapMath:ComputeRect(specKey, w, h, CurrentGap(), scratchRect)
        if rect then ApplyRect(frame, entry, rect) end
    end)
end

-- Apply a saved/active snap when a frame becomes visible. Deferred one frame so
-- Blizzard's own show-time layout runs first and our position wins over it.
local function ReapplyOnShow(entry, specKey)
    Utils.SafeAfter(0, function()
        local frame = Registry:GetFrame(entry)
        if not frame or not frame:IsShown() then return end
        if InCombatLockdown() and frame.IsProtected and frame:IsProtected() then return end
        local w, h = WorkArea()
        local rect = SnapMath:ComputeRect(specKey, w, h, CurrentGap(), scratchRect)
        if rect then ApplyRect(frame, entry, rect) end
    end)
end

-- Install per-frame hooks once the frame exists (idempotent). The OnShow hook
-- tracks the front target and re-applies any saved snap; the SetPoint re-assert
-- hook (added only when the frame has a snap) holds our position when the panel
-- layout system re-anchors the frame. Load-on-demand panels (collections,
-- journal, spellbook) get hooked the first time their module loads, via the
-- ADDON_LOADED watcher.
-- Unlock mode: registered panels drag freely by their frame body, like a
-- window manager's unlocked state. Off by default (windowsUnlocked). A free
-- drag overrides any snap: the applied spec drops so the re-assert hook
-- stops fighting the dragged position.
-- Press alone must never become a drag: grabbing the frame on mouse-DOWN eats
-- the click from every widget that acts on mouse-UP (the settings panel's
-- category tabs), because StartMoving captures the mouse before they see the
-- release. So a press only ARMS a drag, and the drag begins once the cursor
-- has actually travelled -- press-and-release in place stays a plain click.
local DRAG_THRESHOLD = 4
local pendingDrag
local dragWatcher
-- Declared here (used by EndWindowDrag), assigned by the shift-catcher below.
local catcherDragEntry

local function BeginWindowDrag(entry, frame)
    if not (EasyFind and EasyFind.db and EasyFind.db.windowsUnlocked) then return end
    if InCombatLockdown() and frame.IsProtected and frame:IsProtected() then return end
    CaptureDefaultPlacement(entry, frame)
    SafeCallMethod(frame, "SetMovable", true)
    if SafeCallMethod(frame, "StartMoving") then
        frame._efWinDragging = true
        local assist = ns.WindowSnapAssist
        if assist then assist:OnDragStart(entry, frame) end
    end
end

local function ClearPendingDrag()
    pendingDrag = nil
    if dragWatcher then Utils.SafeOnUpdate(dragWatcher, nil) end
end

local function PendingDragTick()
    local pending = pendingDrag
    if not pending then
        if dragWatcher then Utils.SafeOnUpdate(dragWatcher, nil) end
        return
    end
    local x, y = GetCursorPosition()
    local dx, dy = x - pending.x, y - pending.y
    if (dx * dx + dy * dy) < DRAG_THRESHOLD * DRAG_THRESHOLD then return end
    pendingDrag = nil
    Utils.SafeOnUpdate(dragWatcher, nil)
    BeginWindowDrag(pending.entry, pending.frame)
end

-- Double-click the drag surface to maximize, and again to put it back, the way
-- a title bar behaves everywhere else. Every press path funnels through here,
-- so body, inert-child and shift-catcher drags all get it.
local DOUBLE_CLICK_SECONDS = 0.3
local lastPressName, lastPressTime = nil, 0

function Manager:ToggleMaximize(entry)
    if appliedSpec[entry.name] == "maximize" then
        self:Restore(entry)
    else
        self:ApplySpecTo(entry, "maximize")
    end
end

local function ArmWindowDrag(entry, frame)
    if not (EasyFind and EasyFind.db and EasyFind.db.windowsUnlocked) then return end
    local now = GetTime()
    if lastPressName == entry.name and (now - lastPressTime) <= DOUBLE_CLICK_SECONDS then
        lastPressName, lastPressTime = nil, 0
        ClearPendingDrag()
        Manager:ToggleMaximize(entry)
        return
    end
    lastPressName, lastPressTime = entry.name, now
    local x, y = GetCursorPosition()
    pendingDrag = { entry = entry, frame = frame, x = x, y = y }
    if not dragWatcher then dragWatcher = CreateFrame("Frame") end
    Utils.SafeOnUpdate(dragWatcher, PendingDragTick)
end

local function EndWindowDrag(entry, frame)
    ClearPendingDrag()
    -- Always release the catcher claim: a stuck claim keeps that window's
    -- full-surface catcher shown after Shift is long gone, and it then eats
    -- every click on the panel underneath.
    catcherDragEntry = nil
    if not frame._efWinDragging then return end
    frame._efWinDragging = nil
    -- Edge/layout-bar drop: the assist returns the zone spec the cursor
    -- released on (nil = plain free drag).
    local assist = ns.WindowSnapAssist
    local snapSpec = assist and assist:OnDragEnd() or nil
    SafeCallMethod(frame, "StopMovingOrSizing")
    if entry.uiPanel then SafeCallMethod(frame, "SetUserPlaced", true) end
    if snapSpec == "restore" then
        -- The layout bar's prohibition cell: dropping a window there
        -- resets it to Blizzard's default size and position.
        Manager:Restore(entry)
    elseif snapSpec then
        Manager:ApplySpecTo(entry, snapSpec)
    else
        appliedSpec[entry.name] = nil
        local store = PositionStore()
        if store then store[entry.name] = nil end
    end
end

local function InstallDragHooks(entry, frame)
    if entry.own or not frame.HookScript then return end
    -- Body hook FIRST and unconditionally: moving windows is the feature, so
    -- nothing below may be able to prevent it from being installed.
    if not dragHooked[entry.name] then
        dragHooked[entry.name] = true
        frame:HookScript("OnMouseDown", function(self, mouseButton)
            if mouseButton ~= "LeftButton" then return end
            ArmWindowDrag(entry, self)
        end)
        frame:HookScript("OnMouseUp", function(self)
            EndWindowDrag(entry, self)
        end)
    end
    -- NOTE: hooking inert descendants to widen the drag surface is DISABLED.
    -- It broke clicking on the settings panel's category list (rows stopped
    -- highlighting on hover, so the mouse was not reaching them at all) and
    -- the cause was never established. Do not re-enable without a frame-level
    -- diagnosis of what receives the mouse over those rows.
end

-- Shift+drag. A panel's own body is a thin, unpredictable strip -- every
-- child widget eats the click first -- so finding the spot that moves a given
-- window is guesswork. While Shift is held, a transparent catcher covers each
-- open managed window so the whole surface drags. It sits above the panel's
-- children, which means the panel's own shift+clicks (item links) belong to
-- the catcher for as long as the key is down and unlock mode is on.
local CATCHER_LEVEL_LIFT = 60
local dragCatchers = {}
local shiftDriver

local function EnsureDragCatcher(entry, frame)
    local catcher = dragCatchers[entry.name]
    if catcher then return catcher end
    catcher = CreateFrame("Frame", nil, frame)
    catcher:SetAllPoints(frame)
    catcher:EnableMouse(true)
    catcher:Hide()
    catcher:SetScript("OnMouseDown", function(_, mouseButton)
        if mouseButton ~= "LeftButton" then return end
        catcherDragEntry = entry
        ArmWindowDrag(entry, frame)
    end)
    catcher:SetScript("OnMouseUp", function()
        catcherDragEntry = nil
        EndWindowDrag(entry, frame)
        Manager:RefreshDragCatchers()
    end)
    dragCatchers[entry.name] = catcher
    return catcher
end

function Manager:RefreshDragCatchers()
    local wants = IsShiftKeyDown() and EasyFind and EasyFind.db
        and EasyFind.db.windowsUnlocked and true or false
    Registry:ForEach(function(entry)
        if entry.own then return end
        -- Never pull the catcher out from under an active drag: it would
        -- miss the mouse-up and leave the window stuck to the cursor.
        if catcherDragEntry == entry then return end
        local existing = dragCatchers[entry.name]
        local frame = Registry:GetFrame(entry)
        if not (wants and frame and frame:IsShown()) then
            if existing then existing:Hide() end
            return
        end
        local catcher = EnsureDragCatcher(entry, frame)
        catcher:SetFrameLevel((frame:GetFrameLevel() or 0) + CATCHER_LEVEL_LIFT)
        catcher:Show()
    end)
end

local function EnsureShiftDriver()
    if shiftDriver then return end
    shiftDriver = CreateFrame("Frame")
    shiftDriver:RegisterEvent("MODIFIER_STATE_CHANGED")
    shiftDriver:SetScript("OnEvent", function(_, _, key)
        if key == "LSHIFT" or key == "RSHIFT" then Manager:RefreshDragCatchers() end
    end)
end

local function EnsureFrameHooks(entry)
    local frame = Registry:GetFrame(entry)
    if not frame then return end
    -- A load-on-demand panel reaches here from ADDON_LOADED, which the client
    -- fires before the ShowUIPanel that triggered the load: detaching now
    -- means the panel is never seated in the first place.
    EnsurePanelDetached(entry, frame)
    InstallDragHooks(entry, frame)
    if frame.HookScript and not showHooked[entry.name] then
        showHooked[entry.name] = true
        frame:HookScript("OnShow", function()
            frontTargetName = entry.name
            -- Opened while Shift was already held: give it a catcher now.
            if IsShiftKeyDown() then Manager:RefreshDragCatchers() end
            -- Panels build their contents on first show; pick up the children
            -- that did not exist when the frame was first hooked.
            InstallDragHooks(entry, frame)
            -- Capture the default placement only one frame AFTER a natural
            -- show with no snap active: that is Blizzard's settled seat.
            -- Capturing inside ApplyRect (the old site) could snapshot a
            -- panel mid-show, before the layout delegate seated it, and
            -- Restore then replayed that up-left half-position.
            if not origPlacement[entry.name] and not appliedSpec[entry.name] then
                Utils.SafeAfter(0, function()
                    if not origPlacement[entry.name] and not appliedSpec[entry.name]
                        and frame:IsShown() then
                        CaptureDefaultPlacement(entry, frame)
                    end
                end)
            end
            local specKey = appliedSpec[entry.name]
            if specKey then ReapplyOnShow(entry, specKey) end
        end)
        frame:HookScript("OnHide", function()
            -- Finish a detach that was deferred because the panel was seated:
            -- now that it is closed and the manager has released it,
            -- stripping its layout attributes is safe.
            EnsurePanelDetached(entry, frame)
        end)
    end
    if appliedSpec[entry.name] then
        ReassertHook(frame, entry)
        if frame:IsShown() then ReapplyOnShow(entry, appliedSpec[entry.name]) end
    end
    if frame:IsShown() then frontTargetName = entry.name end
end

local STRATA_RANK = {
    BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5,
    FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8,
}
-- Shared with the interactive layer (corner-resize hover ranking).
ns.WINDOW_STRATA_RANK = STRATA_RANK

-- "Focus" tracking: WoW has no window focus, so the front target follows
-- clicks -- on every mouse-down the topmost registered frame under the
-- cursor becomes the target a bare command acts on. Own frames (the search
-- bar) are excluded: clicking the bar to TYPE a command must not steal the
-- target from the panel the command is meant for. The hit test extends
-- down by padBottom so clicking a panel's bottom tab row counts too.
local function TrackFrontFromClick()
    local best, bestStrata, bestLevel
    local entries = Registry.entries
    for i = 1, #entries do
        local entry = entries[i]
        if not entry.own then
            local frame = Registry:GetFrame(entry)
            if frame and frame:IsShown() and frame.IsMouseOver
               and frame:IsMouseOver(0, -(entry.padBottom or 0), 0, 0) then
                local strataRank = STRATA_RANK[frame:GetFrameStrata()] or 0
                local level = frame:GetFrameLevel() or 0
                if not best or strataRank > bestStrata
                   or (strataRank == bestStrata and level >= bestLevel) then
                    best, bestStrata, bestLevel = entry.name, strataRank, level
                end
            end
        end
    end
    if best then frontTargetName = best end
end

local function EnsureEventFrame()
    if eventFrame then return eventFrame end
    eventFrame = CreateFrame("Frame")
    eventFrame:SetScript("OnEvent", function(self, event, addonName)
        if event == "GLOBAL_MOUSE_DOWN" then
            TrackFrontFromClick()
        elseif event == "PLAYER_REGEN_ENABLED" then
            self:UnregisterEvent("PLAYER_REGEN_ENABLED")
            Manager:FlushPending()
        elseif event == "ADDON_LOADED" and ssub(addonName or "", 1, 9) == "Blizzard_" then
            -- A load-on-demand addon registers its panels the moment it
            -- loads, BEFORE the ShowUIPanel that triggered the load. That is
            -- the only window in which a dynamic panel (the professions book,
            -- the housing dashboard) can be detached ahead of its first show:
            -- miss it and the first open tries to seat, finds the slot taken
            -- by an open settings window, and silently shows nothing.
            SweepDetachablePanels()
            if LOD_ADDONS[addonName] then
                local entries = Registry.entries
                for i = 1, #entries do
                    EnsureFrameHooks(entries[i])
                end
            end
        end
    end)
    return eventFrame
end

-- Pick the frame a bare position command acts on: the most-recently-shown
-- registered frame that is currently visible, else the last one we moved, else
-- the first registered frame that happens to be shown.
function Manager:ResolveTarget()
    if frontTargetName then
        local entry = Registry:GetEntryByName(frontTargetName)
        local frame = entry and Registry:GetFrame(entry)
        if frame and frame:IsShown() then return entry end
    end
    if lastTargetName then
        local entry = Registry:GetEntryByName(lastTargetName)
        local frame = entry and Registry:GetFrame(entry)
        if frame and frame:IsShown() then return entry end
    end
    -- Fallback scan prefers real panels over EasyFind's own windows: the
    -- search bar is nearly always shown, and it must never be the implicit
    -- target while an actual panel is open.
    local entries = Registry.entries
    local ownFallback
    for i = 1, #entries do
        local entry = entries[i]
        local frame = Registry:GetFrame(entry)
        if frame and frame:IsShown() then
            if entry.own then
                ownFallback = ownFallback or entry
            else
                return entry
            end
        end
    end
    return ownFallback
end

local function DoApply(entry, specKey)
    local frame = Registry:GetFrame(entry)
    if not frame then return false end

    if InCombatLockdown() and frame.IsProtected and frame:IsProtected() then
        pendingMoves[entry.name] = specKey
        EnsureEventFrame():RegisterEvent("PLAYER_REGEN_ENABLED")
        Toast(L["WINDOW_QUEUED_COMBAT"])
        return false
    end

    local w, h = WorkArea()
    local rect = SnapMath:ComputeRect(specKey, w, h, CurrentGap(), scratchRect)
    if not rect then return false end
    if not ApplyRect(frame, entry, rect) then return false end

    appliedSpec[entry.name] = specKey
    ReassertHook(frame, entry)
    Persist(entry, specKey)
    return true
end

-- Direct spec application to a known entry: the interactive drop path
-- (edge snap, layout bar) bypasses target resolution and cycling.
function Manager:ApplySpecTo(entry, specKey)
    if not (entry and specKey) then return false end
    return DoApply(entry, specKey)
end

function Manager:FlushPending()
    for name, specKey in pairs(pendingMoves) do
        pendingMoves[name] = nil
        local entry = Registry:GetEntryByName(name)
        if entry then
            if specKey == RESTORE_SENTINEL then
                self:Restore(entry)
            else
                DoApply(entry, specKey)
            end
        end
    end
end

-- Apply a position command. Opens the target's frame first if it has an opener
-- and isn't shown, resolves cycling against the last command, then applies.
function Manager:ApplyCommand(commandID, explicitEntry)
    if not SnapMath:HasCommand(commandID) then return false end

    -- No auto-open fallback: a snap acts on the focused window like a
    -- window manager, and silently opening a panel to have something to
    -- move reads as the addon acting on its own. Rows gray out instead.
    local entry = explicitEntry or self:ResolveTarget()
    if not entry then
        Toast(L["WINDOW_NO_TARGET"])
        return false
    end

    local frame = Registry:GetFrame(entry)
    if (not frame or not frame:IsShown()) and entry.open then
        local ok = xpcall(entry.open, ErrorHandler)
        if ok then frame = Registry:GetFrame(entry) end
    end
    if not frame then
        Toast(L["WINDOW_NO_TARGET"])
        return false
    end

    local sameTarget = (lastCommand == commandID) and (lastTargetName == entry.name)
    local specKey = SnapMath:ResolveCyclic(commandID, sameTarget, appliedSpec[entry.name])

    local applied = DoApply(entry, specKey)
    lastCommand = commandID
    lastTargetName = entry.name
    if applied then frontTargetName = entry.name end
    return applied
end

-- Restore a frame to Blizzard's default position: clear our state, drop the
-- saved entry, and let the default UI re-layout (UIPanel frames re-anchor on
-- next show; we nudge by clearing user-placed). In combat on a protected
-- frame the restore is queued and replayed on PLAYER_REGEN_ENABLED, same as
-- a move.
function Manager:Restore(explicitEntry)
    local entry = explicitEntry or self:ResolveTarget()
    if not entry then return false end
    local frame = Registry:GetFrame(entry)

    appliedSpec[entry.name] = nil
    local store = PositionStore()
    if store then store[entry.name] = nil end

    if entry.own and entry.name == "EasyFindSearchFrame" then
        if EasyFind and EasyFind.db then EasyFind.db.uiSearchPosition = nil end
        if frame and frame.ClearAllPoints and ns.Search and ns.Search.GetDefaultSearchBarPoint then
            local point, relPoint, x, y = ns.Search:GetDefaultSearchBarPoint()
            ignoreSetPointHook = true
            frame:ClearAllPoints()
            frame:SetPoint(point, UIParent, relPoint, x, y)
            ignoreSetPointHook = false
        end
        return true
    end

    if not frame then return false end
    if InCombatLockdown() and frame.IsProtected and frame:IsProtected() then
        pendingMoves[entry.name] = RESTORE_SENTINEL
        EnsureEventFrame():RegisterEvent("PLAYER_REGEN_ENABLED")
        Toast(L["WINDOW_QUEUED_COMBAT"])
        return false
    end
    -- Exact restore: replay the scale/anchors snapshotted before our first
    -- touch this session. No hide/show blink, no dependence on the panel
    -- layout system honoring frames an addon moved.
    local snap = origPlacement[entry.name]
    if snap then
        ignoreSetPointHook = true
        if frame.SetScale then frame:SetScale(snap.scale or 1) end
        if entry.resizable and snap.w and frame.SetSize then
            frame:SetSize(snap.w, snap.h)
        end
        if #snap.points > 0 and frame.ClearAllPoints then
            frame:ClearAllPoints()
            for i = 1, #snap.points do
                local p = snap.points[i]
                frame:SetPoint(p[1], p[2], p[3], p[4], p[5])
            end
        end
        ignoreSetPointHook = false
        if entry.uiPanel and frame.SetUserPlaced then
            SafeCallMethod(frame, "SetUserPlaced", false)
        end
        return true
    end
    -- No snapshot (a saved snap from a prior session, frame untouched since
    -- login): fall back to the panel layout reseat.
    if not entry.resizable and frame.SetScale then
        frame:SetScale(1)
    end
    if entry.uiPanel and frame.SetUserPlaced then
        SafeCallMethod(frame, "SetUserPlaced", false)
    end
    if frame:IsShown() and HideUIPanel and ShowUIPanel then
        Utils.SecureCall(HideUIPanel, frame)
        Utils.SecureCall(ShowUIPanel, frame)
    end
    return true
end

-- Restore every window that carries our state (a saved snap or a live
-- applied spec) back to its default position. Untouched windows are left
-- alone -- no pointless hide/show churn on panels we never moved.
function Manager:RestoreAll()
    local touched = {}
    local store = PositionStore()
    if store then
        for name in pairs(store) do touched[name] = true end
    end
    for name in pairs(appliedSpec) do touched[name] = true end
    local any = false
    for name in pairs(touched) do
        local entry = Registry:GetEntryByName(name)
        if entry and self:Restore(entry) then any = true end
    end
    return any
end

-- Diagnostics handles (EasyFindDev /efd win): internal state, read-only.
Manager._appliedSpec = appliedSpec
Manager._pendingMoves = pendingMoves
Manager._hooked = hooked
Manager._showHooked = showHooked
Manager._origPlacement = origPlacement

function Manager:DebugState()
    return frontTargetName, lastTargetName, lastCommand
end

-- ===========================================================================
-- Multi-panel view: taking a panel out of Blizzard's slot system so panels
-- stop evicting each other.
--
-- Detaching a panel means INHERITING FOUR JOBS the panel manager was doing
-- for it. Each one, skipped, produced its own outage:
--   1. RELEASE the slot. Never strip a seated panel's UIPanelWindows row or
--      its layout attributes: both are how the release path identifies the
--      frame, so stripping mid-seat holds the slot forever. The panel then
--      counts as open and every later Esc closes an invisible window instead
--      of opening the game menu.
--   2. SHOW the frame. With no area, ShowUIPanel returns without Show().
--   3. ANCHOR the frame. The manager SetPoints seated panels; one detached
--      before it was ever seated has no points at all and renders nothing.
--   4. OWN its Esc, via the esc stack, gated on detached AND shown.
--
-- So a panel is in exactly ONE state, and one function performs each
-- transition. A forgotten job is then a visible gap in this block rather than
-- an invisible one spread across four call sites, which is how each of the
-- above got shipped separately.
--
--   ATTACHED  Blizzard's, untouched. The default.
--   PENDING   we want it detached, but it is seated right now, so NOTHING is
--             touched until it closes.
--   DETACHED  ours: no row, no attributes; we show, anchor and close it.
-- ===========================================================================
local PANEL_PENDING, PANEL_DETACHED = "pending", "detached"

local panelState = {}        -- name -> PANEL_PENDING | PANEL_DETACHED (nil = attached)
local panelFrames = {}         -- name -> the frame we detached, for the way back
local panelEscAttached = {}    -- name -> true once its esc entry exists
local panelAnchorHooked = {}   -- name -> true once its OnShow anchor hook exists
-- In a fight the game owns Esc and closes only seated panels, so closed
-- panels are seated for the fight and detached again after it.
local inFight = false

-- Where a detached panel lands when it was never seated and so has no points
-- of its own: the panel system's left slot, where these used to open.
local DETACHED_X, DETACHED_Y = 16, -116

-- The world map maximizes by moving from its slot to the full-screen one and
-- back; with no slot it stays pinned where the maximize put it.
local function IsMaximizablePanel(frame)
    return (frame.HandleUserActionMaximizeSelf or frame.Maximize
        or frame.isMaximized ~= nil) and true or false
end

-- Panels that must keep Blizzard's slot handling.
local NEVER_DETACH = {
    -- Hiding the game menu insecurely reaches ToggleGameMenu ->
    -- SpellStopCasting (ADDON_ACTION_FORBIDDEN).
    GameMenuFrame = true,
    InterfaceOptionsFrame = true,
    VideoOptionsFrame = true,
    -- The communities list paints BNet avatars through the protected
    -- SetAvatarTexture, so ANY insecure touch of this frame taints its
    -- ScrollBox initializer and the client blocks the avatar call.
    CommunitiesFrame = true,
    -- Full-screen experiences: hiding the rest of the UI is the point of
    -- them, so they should keep evicting other panels.
    CinematicFrame = true,
    BarberShopFrame = true,
    HouseEditorFrame = true,
    PerksProgramFrame = true,
    -- Known to break when detached.
    MacroFrame = true,
    TokenFrame = true,
    WarboardQuestChoiceFrame = true,
}

local function MultiPanelEnabled()
    return (EasyFind and EasyFind.db and EasyFind.db.windowMultiPanels) and true or false
end

-- One place decides eligibility, so every caller asks the same question.
-- Every panel qualifies except the few that genuinely cannot survive it, and
-- the detach itself is now light enough (two attributes, row untouched) that
-- a panel keeps its own show/hide behaviour either way: HideUIPanel still
-- hides a detached frame, so event-driven closes (merchant, gossip, mail)
-- still work. What a detached panel opts out of is being seated, evicting
-- others, and being closed by the "close everything" sweeps.
local function PanelDetachable(name, frame)
    if NEVER_DETACH[name] then return false end
    if not frame or not frame.GetAttribute then return false end
    if IsMaximizablePanel(frame) then return false end
    return true
end

-- Seated = the panel system holds a slot for it right now.
local function PanelIsSeated(name, frame)
    if not (frame and frame.IsShown and frame:IsShown()) then return false end
    local panelWindows = _G.UIPanelWindows
    return (panelWindows and panelWindows[name] ~= nil) and true or false
end

-- Job 4: our Esc claim, installed once per frame. Both halves matter -- the
-- close routes through HideUIPanel (laundered) so a seat is released even if
-- the manager still tracks the frame, and the gate requires the frame to be
-- SHOWN so a hidden panel can never arm the override and then close nothing.
local function AttachPanelEsc(name, frame)
    if panelEscAttached[name] then return end
    panelEscAttached[name] = true
    Utils.AttachEscClose(frame, function()
        if HideUIPanel then
            Utils.SecureCall(HideUIPanel, frame)
        else
            frame:Hide()
        end
    end, function()
        return panelState[name] == PANEL_DETACHED and frame:IsShown()
    end)
end

-- Job 3, on its own so EVERY path that shows a detached panel gets it. A
-- panel that was never seated has no points of its own, and a frame shown
-- without points renders nothing at all.
local function EnsurePanelAnchored(frame)
    if not (frame and frame.GetNumPoints) then return end
    if frame:GetNumPoints() > 0 then return end
    ignoreSetPointHook = true
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", DETACHED_X, DETACHED_Y)
    ignoreSetPointHook = false
end

-- The ATTACHED -> DETACHED transition. Only ever called for an unseated,
-- eligible panel; jobs 1 (by not being seated) and 4 happen here.
--
-- Participation in the panel system comes down to ONE test, in both
-- ShowUIPanel and HideUIPanel:
--     if frame.editModeManuallyShown or not GetUIPanelAttribute(frame, "area")
--         then frame:Show() / frame:Hide(); return
-- and GetUIPanelAttribute copies the whole UIPanelWindows row onto the frame
-- unless "UIPanelLayout-defined" is already set. So the entire detach is:
-- mark defined (so the row cannot be copied back over us) and clear area.
-- The row itself stays untouched, which is what makes reattaching a
-- one-attribute operation and keeps the release path able to find the frame.
local function DetachPanel(name, frame)
    SafeCallMethod(frame, "SetAttribute", "UIPanelLayout-defined", true)
    SafeCallMethod(frame, "SetAttribute", "UIPanelLayout-area", nil)
    panelState[name] = PANEL_DETACHED
    panelFrames[name] = frame
    AttachPanelEsc(name, frame)
    -- Anchor on ANY show, not just the ShowUIPanel path: panels are opened
    -- through their own toggles and plain Show() calls too, and those would
    -- otherwise display an unanchored frame (visible per IsShown, nothing on
    -- screen). Hooked once, at the moment the panel becomes ours.
    if not panelAnchorHooked[name] and frame.HookScript then
        panelAnchorHooked[name] = true
        frame:HookScript("OnShow", function(self)
            if panelState[name] == PANEL_DETACHED then EnsurePanelAnchored(self) end
        end)
    end
    EnsurePanelAnchored(frame)
    Utils.RefreshEscArm()
end

-- DETACHED -> ATTACHED: clearing "defined" lets the next GetUIPanelAttribute
-- copy the untouched row back onto the frame, area included.
local function ReattachPanel(name, frame)
    panelState[name] = nil
    panelFrames[name] = nil
    SafeCallMethod(frame, "SetAttribute", "UIPanelLayout-defined", nil)
end

-- The single transition entry point. Every hook and sweep calls THIS; none of
-- them re-derive "is it seated" or strip anything themselves.
function EnsurePanelDetached(entry, frame)
    if not MultiPanelEnabled() then return end
    local name = entry and entry.name or nil
    if not name or (entry and entry.own) then return end
    if inFight then
        -- Closed in the fight: seated for its next open, so Esc closes it.
        if panelState[name] == PANEL_DETACHED and frame and not frame:IsShown() then
            ReattachPanel(name, frame)
        end
        return
    end
    if panelState[name] == PANEL_DETACHED then return end
    if not PanelDetachable(name, frame) then return end
    if PanelIsSeated(name, frame) then
        -- Dynamic panels (professions book, housing dashboard) ALWAYS arrive
        -- here seated: we only meet them through the ShowUIPanel hook, which
        -- runs after the manager has taken the slot. Wait for OnHide.
        panelState[name] = PANEL_PENDING
        return
    end
    DetachPanel(name, frame)
end

-- Jobs 2 and 3, for the show path: a detached panel has no area, so the panel
-- system leaves it hidden, and if it was never seated it has no points either.
function ShowIfDetached(frame, name)
    if not (frame and panelState[name] == PANEL_DETACHED) then return end
    EnsurePanelAnchored(frame)
    if frame.IsShown and not frame:IsShown() then
        frame:Show()
    end
end

-- Every panel in the table, re-swept after each addon load. A panel can only
-- be detached once its FRAME exists (the attributes live there) and its row is
-- present from login, so frame existence is the event worth waiting for.
-- Panels that are seated right now are skipped and picked up when they close.
local sweepEntry = {}

function SweepDetachablePanels()
    if not MultiPanelEnabled() then return end
    local panelWindows = _G.UIPanelWindows
    if not panelWindows then return end
    for name in pairs(panelWindows) do
        if panelState[name] ~= PANEL_DETACHED then
            sweepEntry.name = name
            EnsurePanelDetached(sweepEntry, _G[name])
        end
    end
    local entries = Registry.entries
    for i = 1, #entries do
        local entry = entries[i]
        if panelState[entry.name] ~= PANEL_DETACHED then
            EnsurePanelDetached(entry, Registry:GetFrame(entry))
        end
    end
end

-- The DETACHED -> ATTACHED transition (toggle off). Clearing "defined" is the
-- whole revert: the next GetUIPanelAttribute re-copies the untouched row back
-- onto the frame, area included.
local function ReattachPanels()
    for name, state in pairs(panelState) do
        local frame = panelFrames[name] or _G[name]
        panelState[name] = nil
        panelFrames[name] = nil
        if state == PANEL_DETACHED and frame then
            ReattachPanel(name, frame)
            if frame.IsShown and frame:IsShown() then
                frame:Hide()
                Utils.SecureCall(ShowUIPanel, frame)
            end
        end
    end
end

-- A fight's start runs before the lockdown: every closed detached panel is
-- seated. An open one stays detached and is seated once it closes.
local function StartFight()
    inFight = true
    for name, state in pairs(panelState) do
        local frame = panelFrames[name] or _G[name]
        if state == PANEL_DETACHED and frame and not frame:IsShown() then
            ReattachPanel(name, frame)
        end
    end
end

local function DetachAll()
    local entries = Registry.entries
    for i = 1, #entries do
        EnsurePanelDetached(entries[i], Registry:GetFrame(entries[i]))
    end
    SweepDetachablePanels()
end

-- After the fight a seated panel that is open waits for its close (PENDING).
local function EndFight()
    inFight = false
    DetachAll()
end

local fightFrame
local function WatchFights(on)
    if not fightFrame then
        if not on then return end
        fightFrame = CreateFrame("Frame")
        fightFrame:SetScript("OnEvent", function(_, event)
            if event == "PLAYER_REGEN_DISABLED" then StartFight() else EndFight() end
        end)
    end
    if on then
        fightFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
        fightFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    else
        fightFrame:UnregisterAllEvents()
        inFight = false
    end
end

-- ---------------------------------------------------------------------------
-- Settings-window exclusivity. Separate from the state machine above: this
-- panel is never detached (its close chains through the game menu), so the
-- only thing cleared is its claim on the screen.
-- ---------------------------------------------------------------------------
local exclusiveSaved = {}

-- ONLY allowOtherPanels, and ONLY here. Rewriting a panel's `area` was a step
-- too far: doing it to GameMenuFrame changed where the game menu seats itself
-- and ToggleGameMenu fired with no menu ever appearing, which read as Esc
-- being dead. The game menu is left completely untouched.
local EXCLUSIVITY_OVERRIDE = {
    SettingsPanel = true,
}

local function ApplyExclusiveOverrides()
    if not MultiPanelEnabled() then return end
    for name in pairs(EXCLUSIVITY_OVERRIDE) do
        local panelWindows = _G.UIPanelWindows
        local info = panelWindows and panelWindows[name]
        if info and not exclusiveSaved[name] then
            exclusiveSaved[name] = { allow = info.allowOtherPanels }
            info.allowOtherPanels = 1
        end
        local frame = _G[name]
        if frame and frame.SetAttribute then
            SafeCallMethod(frame, "SetAttribute", "UIPanelLayout-allowOtherPanels", true)
        end
    end
end

-- The settings window closes through TransitionBackOpeningPanel, which calls
-- ToggleGameMenu, which calls protected SpellStopCasting -- so once any addon
-- has touched that frame, closing it trips ADDON_ACTION_FORBIDDEN. Replacing
-- that one method with a plain hide severs the chain at its source, which is
-- what makes the settings panel safe to treat like any other window.
local settingsReworked

local function ReworkSettingsClose()
    if settingsReworked or not _G.SettingsPanel then return end
    settingsReworked = true
    local panel = _G.SettingsPanel
    if panel.TransitionBackOpeningPanel then
        function panel:TransitionBackOpeningPanel()
            if HideUIPanel then HideUIPanel(self) else self:Hide() end
        end
    end
    -- Opening settings from the game menu leaves the menu behind it, which
    -- makes Esc ambiguous; close it as the settings window opens.
    local settingsButton = _G.GameMenuButtonSettings or _G.GameMenuButtonOptions
    if settingsButton and settingsButton.HookScript then
        settingsButton:HookScript("OnClick", function()
            local menu = _G.GameMenuFrame
            if menu and menu:IsShown() and HideUIPanel then
                Utils.SecureCall(HideUIPanel, menu)
            end
        end)
    end
end

local function RestoreExclusivePanels()
    local panelWindows = _G.UIPanelWindows
    for name, saved in pairs(exclusiveSaved) do
        exclusiveSaved[name] = nil
        local info = panelWindows and panelWindows[name]
        if info then info.allowOtherPanels = saved.allow end
    end
end

-- ---------------------------------------------------------------------------
-- Micro buttons. The panel system is only half the block: while the settings
-- window is up the default UI also DISABLES the micro buttons outright (the
-- shop and help buttons staying lit is the tell), so clearing exclusivity
-- alone leaves a dead menu. GuildMicroButton is deliberately absent -- an
-- insecure Enable() taints the click, and the communities list it opens
-- paints avatars through a protected API the client then blocks.
-- ---------------------------------------------------------------------------
local MICRO_BUTTON_NAMES = {
    "CharacterMicroButton", "ProfessionMicroButton", "PlayerSpellsMicroButton",
    "SpellbookMicroButton", "TalentMicroButton", "AchievementMicroButton",
    "QuestLogMicroButton", "LFDMicroButton",
    "CollectionsMicroButton", "EJMicroButton", "MainMenuMicroButton",
    "HousingMicroButton", "SocialsMicroButton",
}
local microHooked
-- The default UI's own verdict, sampled while nothing is blocking, so a
-- button disabled for a real reason (level requirement) stays disabled.
local microEnabledSnapshot = {}

local function MenuBlockingShown()
    local settings = _G.SettingsPanel
    if settings and settings.IsShown and settings:IsShown() then return true end
    local menu = _G.GameMenuFrame
    return (menu and menu.IsShown and menu:IsShown()) and true or false
end

local function RestoreMicroButtons()
    if not MultiPanelEnabled() then return end
    local names = _G.MICRO_BUTTONS or MICRO_BUTTON_NAMES
    if not MenuBlockingShown() then
        for i = 1, #names do
            local button = _G[names[i]]
            if button and button.IsEnabled then
                microEnabledSnapshot[names[i]] = button:IsEnabled()
            end
        end
        return
    end
    for i = 1, #names do
        local button = _G[names[i]]
        if button and button.IsEnabled and button.Enable
           and microEnabledSnapshot[names[i]] ~= false and not button:IsEnabled() then
            SafeCallMethod(button, "Enable")
        end
    end
end

local function InstallMicroButtonHook()
    if microHooked then return end
    microHooked = true
    if type(_G.UpdateMicroButtons) == "function" then
        hooksecurefunc("UpdateMicroButtons", RestoreMicroButtons)
    end
    -- 12.0 dropped the MICRO_BUTTONS global, so the menu was reworked and the
    -- disable may not route through UpdateMicroButtons at all. Drive it from
    -- the blocking frames too, one frame later so our pass runs last.
    for _, name in pairs({ "SettingsPanel", "GameMenuFrame" }) do
        local frame = _G[name]
        if frame and frame.HookScript then
            frame:HookScript("OnShow", function()
                Utils.SafeAfter(0, RestoreMicroButtons)
            end)
            frame:HookScript("OnHide", function()
                Utils.SafeAfter(0, RestoreMicroButtons)
            end)
        end
    end
end

-- Contract surface for the headless tests (and /efd win panels): the state
-- table plus the three transitions, so "detach then show" can be asserted
-- without a client. Read-only from the outside.
Manager._panelState = panelState
Manager._EnsurePanelDetached = EnsurePanelDetached
Manager._ShowIfDetached = ShowIfDetached
Manager._SweepDetachablePanels = SweepDetachablePanels
Manager._StartFight = StartFight
Manager._EndFight = EndFight

function Manager:RefreshMultiPanels()
    WatchFights(MultiPanelEnabled())
    if MultiPanelEnabled() then
        DetachAll()
        ApplyExclusiveOverrides()
        ReworkSettingsClose()
        return
    end
    ReattachPanels()
    RestoreExclusivePanels()
    Utils.RefreshEscArm()
end

-- Dynamic panel discovery: any named UIPanel that shows and is not in the
-- static catalog gets registered on the spot, picking up its saved snap
-- from a previous session. This is what makes "every panel" movable without
-- hand-cataloging each frame name.
local function OnShowUIPanel(frame)
    if type(frame) ~= "table" or not frame.GetName then return end
    local name = frame:GetName()
    if not name then return end
    local entry = Registry:GetEntryByName(name)
    if not entry then
        entry = Registry:RegisterDynamic(frame)
        if not entry then return end
        local store = PositionStore()
        local saved = store and store[name]
        if saved and (SnapMath:HasCommand(saved) or SnapMath:DecodeCustom(saved)) then
            appliedSpec[name] = saved
        end
        EnsureFrameHooks(entry)
    end
    EnsurePanelDetached(entry, frame)
    -- Detached panels carry no area, so the panel system's show path can
    -- return without ever showing the frame. Finish the job it skipped.
    ShowIfDetached(frame, name)
end

-- Empty-slot masking ("Hide empty slots"): purely visual. The hard-won
-- rule (2026-07-18): NEVER call the grid functions from addon code --
-- an insecure MultiActionBar_HideAllGrids call taints grid state, the
-- panels' own secure hide then blocks, slots stick shown for the session
-- and ESC dies. This version only OBSERVES the grid via hooksecurefunc
-- and masks empty buttons with SetAlpha(0); alpha sits outside the
-- secure state machine, so the worst failure is slots reappearing.
-- 12.0 reasons (probe-verified via /efd win grid): SPELLCOLLECTION = a
-- spell-granting panel is open, EVENT = dragging a spell/item (masking
-- yields so drops have visible targets), CVAR = always-show setting.
local GRID_BARS = {
    "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
    "MultiBarRightButton", "MultiBarLeftButton",
    "MultiBar5Button", "MultiBar6Button", "MultiBar7Button",
}
local gridMasked = {}        -- button -> true while we hold its alpha at 0
local gridMousePending = {}  -- button -> true when combat blocked the mouse restore
local gridReasonActive = {}  -- reason -> true, tracked from the hooks
local gridMaskActive = false
local gridEventFrame

local function GridPanelReason()
    return _G.ACTION_BUTTON_SHOW_GRID_REASON_SPELLCOLLECTION
        or _G.ACTION_BUTTON_SHOW_GRID_REASON_SPELLBOOK_SHOWN
end

-- Invisible must also mean click-through: bars can overlap other UI (the
-- micro menu), and an alpha-0 button still hit-tests, eating clicks on
-- whatever sits under it. Mouse writes are combat-guarded; a restore that
-- lockdown blocks is finished on PLAYER_REGEN_ENABLED so no slot ever
-- stays click-dead.
local function GridSetButtonMasked(button, masked)
    if masked then
        gridMasked[button] = true
        button:SetAlpha(0)
        SafeCallMethod(button, "EnableMouse", false)
    else
        gridMasked[button] = nil
        button:SetAlpha(1)
        if SafeCallMethod(button, "EnableMouse", true) then
            gridMousePending[button] = nil
        else
            gridMousePending[button] = true
            if gridEventFrame then gridEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED") end
        end
    end
end

local function GridUnmaskAll()
    for button in pairs(gridMasked) do
        GridSetButtonMasked(button, false)
    end
end

local function GridButtonEmpty(button)
    local slot = button.action
    if type(slot) ~= "number" or slot == 0 then return false end
    return HasAction and not HasAction(slot)
end

local function GridApplyMask()
    for b = 1, #GRID_BARS do
        for i = 1, 12 do
            local button = _G[GRID_BARS[b] .. i]
            if button and button.SetAlpha then
                if GridButtonEmpty(button) then
                    if not gridMasked[button] then
                        GridSetButtonMasked(button, true)
                    end
                elseif gridMasked[button] then
                    GridSetButtonMasked(button, false)
                end
            end
        end
    end
end

local function GridRefreshMask()
    local panelReason = GridPanelReason()
    local dragReason = _G.ACTION_BUTTON_SHOW_GRID_REASON_EVENT
    local wantMask = EasyFind and EasyFind.db and EasyFind.db.windowHideBarGrid
        and panelReason and gridReasonActive[panelReason]
        and not (dragReason and gridReasonActive[dragReason])
    if wantMask then
        gridMaskActive = true
        GridApplyMask()
        -- Slots can empty/fill while the panel is open (dragging a spell
        -- off a bar); track only while masking so the event stays cold
        -- otherwise.
        if gridEventFrame then gridEventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED") end
    else
        gridMaskActive = false
        if gridEventFrame then gridEventFrame:UnregisterEvent("ACTIONBAR_SLOT_CHANGED") end
        GridUnmaskAll()
    end
end

local function InstallGridMask()
    if not (_G.MultiActionBar_ShowAllGrids and _G.MultiActionBar_HideAllGrids) then return end
    if not GridPanelReason() then return end
    gridEventFrame = CreateFrame("Frame")
    gridEventFrame:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_ENABLED" then
            self:UnregisterEvent("PLAYER_REGEN_ENABLED")
            for button in pairs(gridMousePending) do
                if SafeCallMethod(button, "EnableMouse", true) then
                    gridMousePending[button] = nil
                end
            end
            return
        end
        if gridMaskActive then GridApplyMask() end
    end)
    hooksecurefunc("MultiActionBar_ShowAllGrids", function(reason)
        gridReasonActive[reason or 0] = true
        GridRefreshMask()
    end)
    hooksecurefunc("MultiActionBar_HideAllGrids", function(reason)
        gridReasonActive[reason or 0] = nil
        GridRefreshMask()
    end)
end

-- Toggle flip while a panel is already open: reasons have been tracked
-- since login (the hooks install unconditionally), so this masks or
-- unmasks in place.
function Manager:RefreshGridMask()
    GridRefreshMask()
end

-- Re-apply saved positions after login and install hooks. Frames that load on
-- demand are caught later by the ADDON_LOADED watcher.
function Manager:Initialize()
    self:ReapplySaved()
    local entries = Registry.entries
    for i = 1, #entries do
        EnsureFrameHooks(entries[i])
    end
    -- Stays registered for every addon, not just until our own frames are
    -- hooked: new panel rows can appear at any load and must be detached
    -- before that panel's first show.
    SweepDetachablePanels()
    WatchFights(MultiPanelEnabled())
    EnsureEventFrame():RegisterEvent("ADDON_LOADED")
    EnsureEventFrame():RegisterEvent("GLOBAL_MOUSE_DOWN")
    if type(_G.ShowUIPanel) == "function" then
        hooksecurefunc("ShowUIPanel", OnShowUIPanel)
    end
    InstallGridMask()
    EnsureShiftDriver()
    ApplyExclusiveOverrides()
    InstallMicroButtonHook()
    ReworkSettingsClose()
    if ns.WindowSnapAssist and ns.WindowSnapAssist.RefreshResizeWatcher then
        ns.WindowSnapAssist:RefreshResizeWatcher()
    end
end

-- A panel's close button, however that panel names it. Used to keep our own
-- chrome (the corner resize grip) from covering it.
function Manager:GetCloseButton(frame)
    if not frame then return nil end
    local candidate = frame.CloseButton or frame.ClosePanelButton or frame.closeButton
    if candidate and candidate.IsMouseOver then return candidate end
    local name = frame.GetName and frame:GetName()
    if not name then return nil end
    candidate = _G[name .. "CloseButton"]
    if candidate and candidate.IsMouseOver then return candidate end
    return nil
end

-- Fractions of the zone a window currently occupies (nil when unsnapped or
-- on a center-style spec, which has no dividers). Fifth return is the key.
function Manager:GetAppliedZone(name)
    local key = appliedSpec[name]
    if not key then return nil end
    local fx, fy, fw, fh = SnapMath:GetZoneFractions(key)
    if not fx then return nil end
    return fx, fy, fw, fh, key
end

-- Free-window corner resize: rescale about the fixed (opposite) corner.
-- Like a free drag, this unsnaps the window -- the resize IS the position
-- now, and the reassert hook stops fighting for the old zone.
function Manager:ApplyCornerScale(entry, frame, newScale, fixedPoint)
    if not (entry and frame and frame.SetScale) then return false end
    if InCombatLockdown() and frame.IsProtected and frame:IsProtected() then return false end
    if newScale > FIT_SCALE_MAX then newScale = FIT_SCALE_MAX
    elseif newScale < FIT_SCALE_MIN then newScale = FIT_SCALE_MIN end

    local uiScale = UIParent and UIParent:GetEffectiveScale() or 1
    local uiH = UIParent and UIParent:GetHeight() or 0
    local scaleRatio = (frame:GetEffectiveScale() or 1) / uiScale
    local left, bottom = frame:GetLeft(), frame:GetBottom()
    local w, h = frame:GetWidth(), frame:GetHeight()
    if not (left and bottom and w and h and uiH > 0) then return false end
    -- Frame rect in UIParent units, y measured downward from the top.
    local leftU = left * scaleRatio
    local topU = uiH - (bottom + h) * scaleRatio
    local wU, hU = w * scaleRatio, h * scaleRatio

    frame:SetScale(newScale)
    local ratio2 = (frame:GetEffectiveScale() or 1) / uiScale
    local w2, h2 = (frame:GetWidth() or 0) * ratio2, (frame:GetHeight() or 0) * ratio2

    local x, y
    if fixedPoint == "TOPLEFT" then
        x, y = leftU, topU
    elseif fixedPoint == "TOPRIGHT" then
        x, y = leftU + wU - w2, topU
    elseif fixedPoint == "BOTTOMLEFT" then
        x, y = leftU, topU + hU - h2
    else -- BOTTOMRIGHT
        x, y = leftU + wU - w2, topU + hU - h2
    end
    AnchorTopLeft(frame, x, -y)

    appliedSpec[entry.name] = nil
    local store = PositionStore()
    if store then store[entry.name] = nil end
    if entry.uiPanel and frame.SetUserPlaced then
        SafeCallMethod(frame, "SetUserPlaced", true)
    end
    return true
end

-- Re-apply any persisted snaps. Own windows (search bar) apply immediately;
-- Blizzard panels re-apply when they next show, via the OnShow hook plus the
-- SetPoint re-assert hook (both installed by EnsureFrameHooks), so they don't
-- fight the layout system at login.
function Manager:ReapplySaved()
    local store = PositionStore()
    if not store then return end
    local entries = Registry.entries
    for i = 1, #entries do
        local entry = entries[i]
        local specKey = store[entry.name]
        if specKey and (SnapMath:HasCommand(specKey) or SnapMath:DecodeCustom(specKey)) then
            appliedSpec[entry.name] = specKey
            if entry.own then DoApply(entry, specKey) end
        end
    end
end

return Manager
