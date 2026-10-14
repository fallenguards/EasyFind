local _, ns = ...

-- Snap geometry. Pure math: given a position spec and the available screen
-- rectangle (UIParent width/height in UIParent coordinates, minus a gap),
-- compute the target rectangle a frame should occupy. No frame references and
-- no Blizzard API calls live here, so it is unit-testable in isolation.
--
-- A spec is a fractional rectangle over the work area expressed as
-- { fx, fy, fw, fh } where each value is 0..1: fx/fy is the top-left corner
-- (fy measured from the TOP, screen-style), fw/fh the size. The gap is applied
-- as an inset on every screen edge the rectangle touches and as a half-gap on
-- every interior seam, so two adjacent snaps leave one full gap between them.

local SnapMath = {}
ns.SnapMath = SnapMath

local mfloor = math.floor
local mabs = math.abs

-- Position catalog. Keys are stable English identifiers (stored in
-- SavedVariables, never shown). Each has a fractional rect plus an ordered
-- `cycle` list: invoking the same command again advances to the next entry,
-- mirroring the repeat-to-resize interaction. The first cycle element is the
-- command's own key, so a fresh invocation always lands on the base size.
local SPECS = {
    ["left-half"]    = { rect = { 0, 0, 1 / 2, 1 }, cycle = { "left-half", "left-third", "left-two-thirds" } },
    ["right-half"]   = { rect = { 1 / 2, 0, 1 / 2, 1 }, cycle = { "right-half", "right-third", "right-two-thirds" } },
    ["top-half"]     = { rect = { 0, 0, 1, 1 / 2 } },
    ["bottom-half"]  = { rect = { 0, 1 / 2, 1, 1 / 2 } },

    ["left-third"]       = { rect = { 0, 0, 1 / 3, 1 } },
    ["center-third"]     = { rect = { 1 / 3, 0, 1 / 3, 1 } },
    ["right-third"]      = { rect = { 2 / 3, 0, 1 / 3, 1 } },
    ["left-two-thirds"]  = { rect = { 0, 0, 2 / 3, 1 } },
    ["right-two-thirds"] = { rect = { 1 / 3, 0, 2 / 3, 1 } },

    ["top-left-quarter"]     = { rect = { 0, 0, 1 / 2, 1 / 2 },
        cycle = { "top-left-quarter", "top-left-ninth", "top-left-two-thirds" } },
    ["top-right-quarter"]    = { rect = { 1 / 2, 0, 1 / 2, 1 / 2 },
        cycle = { "top-right-quarter", "top-right-ninth", "top-right-two-thirds" } },
    ["bottom-left-quarter"]  = { rect = { 0, 1 / 2, 1 / 2, 1 / 2 },
        cycle = { "bottom-left-quarter", "bottom-left-ninth", "bottom-left-two-thirds" } },
    ["bottom-right-quarter"] = { rect = { 1 / 2, 1 / 2, 1 / 2, 1 / 2 },
        cycle = { "bottom-right-quarter", "bottom-right-ninth", "bottom-right-two-thirds" } },

    -- Corner cycle sizes (cycle-only, never commands). Both dimensions step:
    -- fitted windows aspect-fit inside their zone, so a same-height step only
    -- re-centers and never visibly resizes. Corner gravity keeps the window's
    -- screen corner pinned while the size steps.
    ["top-left-ninth"]          = { rect = { 0, 0, 1 / 3, 1 / 3 } },
    ["top-right-ninth"]         = { rect = { 2 / 3, 0, 1 / 3, 1 / 3 } },
    ["bottom-left-ninth"]       = { rect = { 0, 2 / 3, 1 / 3, 1 / 3 } },
    ["bottom-right-ninth"]      = { rect = { 2 / 3, 2 / 3, 1 / 3, 1 / 3 } },
    ["top-left-two-thirds"]     = { rect = { 0, 0, 2 / 3, 2 / 3 } },
    ["top-right-two-thirds"]    = { rect = { 1 / 3, 0, 2 / 3, 2 / 3 } },
    ["bottom-left-two-thirds"]  = { rect = { 0, 1 / 3, 2 / 3, 2 / 3 } },
    ["bottom-right-two-thirds"] = { rect = { 1 / 3, 1 / 3, 2 / 3, 2 / 3 } },

    -- Sixths: two rows of three.
    ["top-left-sixth"]      = { rect = { 0, 0, 1 / 3, 1 / 2 } },
    ["top-center-sixth"]    = { rect = { 1 / 3, 0, 1 / 3, 1 / 2 } },
    ["top-right-sixth"]     = { rect = { 2 / 3, 0, 1 / 3, 1 / 2 } },
    ["bottom-left-sixth"]   = { rect = { 0, 1 / 2, 1 / 3, 1 / 2 } },
    ["bottom-center-sixth"] = { rect = { 1 / 3, 1 / 2, 1 / 3, 1 / 2 } },
    ["bottom-right-sixth"]  = { rect = { 2 / 3, 1 / 2, 1 / 3, 1 / 2 } },

    ["maximize"] = { rect = { 0, 0, 1, 1 }, cycle = { "maximize", "reasonable-size" } },
    ["center"]   = { center = true, fw = 0.5, fh = 0.6 },

    -- Reasonable size: a centered window at a comfortable fraction of the
    -- screen, the rest-state counterpart to maximize.
    ["reasonable-size"] = { center = true, fw = 0.6, fh = 0.7 },
}

-- Edge-touch tolerance for deciding whether a fractional coordinate sits on a
-- screen edge (and therefore takes the full edge gap) versus an interior seam.
local EPS = 0.001

function SnapMath:HasCommand(id)
    return SPECS[id] ~= nil
end

-- Returns the ordered cycle list for a command (or a single-element list of
-- just the command when it does not cycle). Read-only; never mutate.
function SnapMath:GetCycle(id)
    local spec = SPECS[id]
    if not spec then return nil end
    return spec.cycle
end

-- Given the current command and the previously applied command + target, decide
-- which spec to apply now. Repeating the same command on the same target walks
-- its cycle; anything else restarts at the command's base spec.
function SnapMath:ResolveCyclic(id, sameTargetAsLast, lastAppliedSpec)
    local spec = SPECS[id]
    if not spec then return id end
    local cycle = spec.cycle
    if not cycle or not sameTargetAsLast then return id end
    -- Find where the last applied spec sits in this command's cycle and step
    -- forward, wrapping back to the start.
    for i = 1, #cycle do
        if cycle[i] == lastAppliedSpec then
            return cycle[(i % #cycle) + 1]
        end
    end
    return id
end

-- Custom zones: fractional rects created by linked corner-resizing (the
-- divider between snapped windows moves, both sides get bespoke fractions).
-- Encoded as stable strings so they persist in the same SavedVariables slot
-- spec keys use.
local sformat = string.format

function SnapMath:EncodeCustom(fx, fy, fw, fh)
    return sformat("custom:%.4f,%.4f,%.4f,%.4f", fx, fy, fw, fh)
end

function SnapMath:DecodeCustom(id)
    if type(id) ~= "string" then return nil end
    local fx, fy, fw, fh = id:match("^custom:([%d%.]+),([%d%.]+),([%d%.]+),([%d%.]+)$")
    if not fx then return nil end
    return tonumber(fx), tonumber(fy), tonumber(fw), tonumber(fh)
end

local function ComputeFractionRect(fx, fy, fw, fh, screenW, screenH, gap, out)
    -- Pixel edges before gaps.
    local left = fx * screenW
    local top = fy * screenH
    local right = (fx + fw) * screenW
    local bottom = (fy + fh) * screenH

    -- An edge touching the work-area boundary takes the full gap as an inset;
    -- an interior seam takes a half-gap so the matching neighbour's half-gap
    -- sums to one full gap between the two windows.
    local touchLeft = fx <= EPS
    local touchTop = fy <= EPS
    local touchRight = fx + fw >= 1 - EPS
    local touchBottom = fy + fh >= 1 - EPS
    local leftGap = touchLeft and gap or (gap / 2)
    local topGap = touchTop and gap or (gap / 2)
    local rightGap = touchRight and gap or (gap / 2)
    local bottomGap = touchBottom and gap or (gap / 2)

    -- Gravity: which zone edge a fitted (smaller-than-rect) window should hug.
    -- A rect touching exactly one screen edge per axis pulls the window to
    -- that edge, so corner snaps pin the window's corner to the screen corner
    -- instead of floating it in the middle of the zone.
    out.gx = (touchLeft and not touchRight) and "left"
        or (touchRight and not touchLeft) and "right" or "center"
    out.gy = (touchTop and not touchBottom) and "top"
        or (touchBottom and not touchTop) and "bottom" or "center"

    left = left + leftGap
    top = top + topGap
    right = right - rightGap
    bottom = bottom - bottomGap

    local w = right - left
    local h = bottom - top
    if w < 1 then w = 1 end
    if h < 1 then h = 1 end

    out.point = "TOPLEFT"
    out.x = mfloor(left + 0.5)
    out.y = -mfloor(top + 0.5)
    out.w = mfloor(w + 0.5)
    out.h = mfloor(h + 0.5)
    return out
end

-- Compute the target rectangle for `id` (a catalog key or an encoded custom
-- zone) over a work area of (screenW, screenH) with the given edge/seam gap,
-- all in the same coordinate space (UIParent units). Writes into `out` (a
-- caller-owned table) to avoid per-call allocation and returns it:
-- { point = "TOPLEFT", x, y, w, h, gx, gy } where x/y is the TOPLEFT corner
-- offset from the work area's top-left, y negative (downward).
function SnapMath:ComputeRect(id, screenW, screenH, gap, out)
    if not screenW or not screenH then return nil end
    gap = gap or 0
    out = out or {}

    local spec = SPECS[id]
    if not spec then
        local fx, fy, fw, fh = self:DecodeCustom(id)
        if not fx then return nil end
        return ComputeFractionRect(fx, fy, fw, fh, screenW, screenH, gap, out)
    end

    if spec.center then
        local w = screenW * (spec.fw or 0.5) - gap * 2
        local h = screenH * (spec.fh or 0.5) - gap * 2
        if w < 1 then w = 1 end
        if h < 1 then h = 1 end
        out.point = "TOPLEFT"
        out.w = mfloor(w + 0.5)
        out.h = mfloor(h + 0.5)
        out.x = mfloor((screenW - out.w) / 2 + 0.5)
        out.y = -mfloor((screenH - out.h) / 2 + 0.5)
        out.gx, out.gy = "center", "center"
        return out
    end

    local r = spec.rect
    return ComputeFractionRect(r[1], r[2], r[3], r[4], screenW, screenH, gap, out)
end

-- Fractions for an applied key: catalog rects and custom zones both resolve;
-- center-style specs (no rect) return nil, they have no dividers to move.
function SnapMath:GetZoneFractions(id)
    local spec = SPECS[id]
    if spec and spec.rect then
        local r = spec.rect
        return r[1], r[2], r[3], r[4]
    end
    return self:DecodeCustom(id)
end

-- No zone may shrink below this fraction of the screen during a divider move.
local MIN_ZONE_FRACTION = 0.12

-- Move a shared divider (the Windows-11 linked resize). zones is an array of
-- { fx, fy, fw, fh, ... } tables; oldPos is the divider's current fraction
-- along the moved axis, newPos the requested one, vertical = true for a
-- vertical divider (constant x). Only zones with an edge on oldPos whose
-- cross-axis span overlaps crossMin..crossMax are touched; newPos is clamped
-- so every touched zone keeps MIN_ZONE_FRACTION. Mutates the touched zones
-- in place and returns the clamped position plus the number touched.
-- loBound/hiBound (optional) widen the travel limits. An interior divider
-- keeps a zone on either side, so it stops MIN_ZONE_FRACTION from each screen
-- edge; a zone's OUTER edge has no neighbor to preserve and may travel to the
-- boundary itself, which is how a snapped window resizes against the screen.
function SnapMath:MoveDivider(zones, oldPos, newPos, vertical, crossMin, crossMax,
                              loBound, hiBound)
    local lo = loBound or MIN_ZONE_FRACTION
    local hi = hiBound or (1 - MIN_ZONE_FRACTION)
    local touched = 0
    for i = 1, #zones do
        local zone = zones[i]
        local edgeStart = vertical and zone.fx or zone.fy
        local edgeSize = vertical and zone.fw or zone.fh
        local crossStart = vertical and zone.fy or zone.fx
        local crossSize = vertical and zone.fh or zone.fw
        if crossStart < crossMax - EPS and crossStart + crossSize > crossMin + EPS then
            if mabs(edgeStart + edgeSize - oldPos) <= EPS then
                zone._movesEnd = true
                touched = touched + 1
                if edgeStart + MIN_ZONE_FRACTION > lo then lo = edgeStart + MIN_ZONE_FRACTION end
            elseif mabs(edgeStart - oldPos) <= EPS then
                zone._movesStart = true
                touched = touched + 1
                if edgeStart + edgeSize - MIN_ZONE_FRACTION < hi then
                    hi = edgeStart + edgeSize - MIN_ZONE_FRACTION
                end
            end
        end
    end
    if touched == 0 then return oldPos, 0 end
    if lo > hi then lo = hi end
    if newPos < lo then newPos = lo elseif newPos > hi then newPos = hi end
    for i = 1, #zones do
        local zone = zones[i]
        if zone._movesEnd then
            zone._movesEnd = nil
            if vertical then zone.fw = newPos - zone.fx else zone.fh = newPos - zone.fy end
        elseif zone._movesStart then
            zone._movesStart = nil
            if vertical then
                zone.fw = zone.fx + zone.fw - newPos
                zone.fx = newPos
            else
                zone.fh = zone.fy + zone.fh - newPos
                zone.fy = newPos
            end
        end
    end
    return newPos, touched
end

SnapMath.SPECS = SPECS
SnapMath.EPS = EPS

return SnapMath
