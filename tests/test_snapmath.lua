local H = require("Harness")

local env = H.newEnv()
local ns = H.newNs(env)
H.loadModule("WindowManager/SnapMath.lua", env, ns)
local SnapMath = ns.SnapMath

local tests = {}

-- 1000x500 work area, gap 8: screen edges take the full gap, interior seams
-- take a half-gap so two adjacent snaps leave exactly one gap between them.
function tests.edgeTakesFullGapSeamTakesHalf()
    local r = SnapMath:ComputeRect("left-half", 1000, 500, 8, {})
    H.assertEq(r.point, "TOPLEFT")
    H.assertEq(r.x, 8)
    H.assertEq(r.y, -8)
    H.assertEq(r.w, 488, "500 minus full left gap minus half seam gap")
    H.assertEq(r.h, 484, "full gap top and bottom")
end

function tests.adjacentHalvesLeaveOneFullGap()
    local left = SnapMath:ComputeRect("left-half", 1000, 500, 8, {})
    local right = SnapMath:ComputeRect("right-half", 1000, 500, 8, {})
    local leftEdge = left.x + left.w
    H.assertEq(right.x - leftEdge, 8)
    H.assertEq(right.x + right.w, 1000 - 8, "right edge takes the full gap")
end

function tests.maximizeInsetsEveryEdge()
    local r = SnapMath:ComputeRect("maximize", 1000, 500, 10, {})
    H.assertEq(r.x, 10)
    H.assertEq(r.y, -10)
    H.assertEq(r.w, 980)
    H.assertEq(r.h, 480)
end

function tests.centerSpecCentersItsRect()
    local r = SnapMath:ComputeRect("center", 1000, 500, 0, {})
    H.assertEq(r.w, 500, "fw 0.5 of 1000")
    H.assertEq(r.h, 300, "fh 0.6 of 500")
    H.assertEq(r.x, 250)
    H.assertEq(r.y, -100)
end

function tests.sixthsTileWithoutOverlap()
    local tl = SnapMath:ComputeRect("top-left-sixth", 1200, 600, 6, {})
    local tc = SnapMath:ComputeRect("top-center-sixth", 1200, 600, 6, {})
    local bl = SnapMath:ComputeRect("bottom-left-sixth", 1200, 600, 6, {})
    H.assertEq(tc.x - (tl.x + tl.w), 6, "one gap between horizontal neighbours")
    H.assertEq(bl.y - (tl.y - tl.h), -6, "one gap between vertical neighbours")
end

function tests.zeroGapTilesExactly()
    local left = SnapMath:ComputeRect("left-half", 1000, 500, 0, {})
    local right = SnapMath:ComputeRect("right-half", 1000, 500, 0, {})
    H.assertEq(left.x, 0)
    H.assertEq(left.w, 500)
    H.assertEq(right.x, 500)
    H.assertEq(right.w, 500)
end

function tests.cycleAdvancesOnRepeatSameTarget()
    H.assertEq(SnapMath:ResolveCyclic("left-half", true, "left-half"), "left-third")
    H.assertEq(SnapMath:ResolveCyclic("left-half", true, "left-third"), "left-two-thirds")
    H.assertEq(SnapMath:ResolveCyclic("left-half", true, "left-two-thirds"), "left-half",
        "cycle wraps to the base size")
end

function tests.cycleRestartsOnNewTargetOrUnknownState()
    H.assertEq(SnapMath:ResolveCyclic("left-half", false, "left-third"), "left-half",
        "different target restarts at the base spec")
    H.assertEq(SnapMath:ResolveCyclic("left-half", true, "maximize"), "left-half",
        "a spec outside this cycle restarts at the base spec")
    H.assertEq(SnapMath:ResolveCyclic("top-half", true, "top-half"), "top-half",
        "non-cycling commands return themselves")
end

function tests.cornerCyclesWalkQuarterNinthTwoThirds()
    H.assertEq(SnapMath:ResolveCyclic("top-left-quarter", true, "top-left-quarter"), "top-left-ninth")
    H.assertEq(SnapMath:ResolveCyclic("top-left-quarter", true, "top-left-ninth"), "top-left-two-thirds")
    H.assertEq(SnapMath:ResolveCyclic("top-left-quarter", true, "top-left-two-thirds"), "top-left-quarter",
        "corner cycle wraps to the base quarter")
    H.assertEq(SnapMath:ResolveCyclic("bottom-right-quarter", true, "bottom-right-quarter"), "bottom-right-ninth")
end

function tests.cornerCycleSizesScaleBothDimensions()
    local tl = SnapMath:ComputeRect("top-left-two-thirds", 1200, 600, 0, {})
    H.assertEq(tl.x, 0)
    H.assertEq(tl.y, 0)
    H.assertEq(tl.w, 800)
    H.assertEq(tl.h, 400)
    local br = SnapMath:ComputeRect("bottom-right-two-thirds", 1200, 600, 0, {})
    H.assertEq(br.x, 400)
    H.assertEq(br.y, -200)
    H.assertEq(br.w, 800)
    H.assertEq(br.h, 400)
    local ninth = SnapMath:ComputeRect("bottom-right-ninth", 1200, 600, 0, {})
    H.assertEq(ninth.x, 800)
    H.assertEq(ninth.y, -400)
    H.assertEq(ninth.w, 400)
    H.assertEq(ninth.h, 200)
end

function tests.gravityHugsTouchedScreenEdges()
    local r = SnapMath:ComputeRect("top-left-quarter", 1000, 500, 0, {})
    H.assertEq(r.gx, "left")
    H.assertEq(r.gy, "top")
    r = SnapMath:ComputeRect("bottom-right-quarter", 1000, 500, 0, r)
    H.assertEq(r.gx, "right")
    H.assertEq(r.gy, "bottom")
    r = SnapMath:ComputeRect("left-half", 1000, 500, 0, r)
    H.assertEq(r.gx, "left")
    H.assertEq(r.gy, "center", "full-height zones touch both vertical edges")
    r = SnapMath:ComputeRect("top-half", 1000, 500, 0, r)
    H.assertEq(r.gx, "center")
    H.assertEq(r.gy, "top")
    r = SnapMath:ComputeRect("maximize", 1000, 500, 0, r)
    H.assertEq(r.gx, "center")
    H.assertEq(r.gy, "center")
    r = SnapMath:ComputeRect("center", 1000, 500, 0, r)
    H.assertEq(r.gx, "center")
    H.assertEq(r.gy, "center")
end

function tests.everyCycleMemberIsARealSpec()
    for id in pairs(SnapMath.SPECS) do
        local cycle = SnapMath:GetCycle(id)
        if cycle then
            for i = 1, #cycle do
                H.assertEq(SnapMath:HasCommand(cycle[i]), true,
                    id .. " cycle references unknown spec " .. tostring(cycle[i]))
            end
        end
    end
end

function tests.customZoneCodecRoundTrips()
    local key = SnapMath:EncodeCustom(0.25, 0, 0.75, 0.5)
    local fx, fy, fw, fh = SnapMath:DecodeCustom(key)
    H.assertEq(fx, 0.25)
    H.assertEq(fy, 0)
    H.assertEq(fw, 0.75)
    H.assertEq(fh, 0.5)
    H.assertEq(SnapMath:DecodeCustom("left-half"), nil)
    H.assertEq(SnapMath:DecodeCustom(nil), nil)
end

function tests.customZoneComputesLikeItsSpecTwin()
    local spec = SnapMath:ComputeRect("left-half", 1000, 500, 8, {})
    local custom = SnapMath:ComputeRect(SnapMath:EncodeCustom(0, 0, 0.5, 1), 1000, 500, 8, {})
    H.assertEq(custom.x, spec.x)
    H.assertEq(custom.y, spec.y)
    H.assertEq(custom.w, spec.w)
    H.assertEq(custom.h, spec.h)
    H.assertEq(custom.gx, spec.gx)
    H.assertEq(custom.gy, spec.gy)
end

function tests.moveDividerResizesBothSides()
    local zones = {
        { fx = 0, fy = 0, fw = 0.5, fh = 1 },
        { fx = 0.5, fy = 0, fw = 0.5, fh = 1 },
    }
    local pos, touched = SnapMath:MoveDivider(zones, 0.5, 0.6, true, 0, 1)
    H.assertEq(pos, 0.6)
    H.assertEq(touched, 2)
    H.assertEq(zones[1].fw, 0.6)
    H.assertEq(zones[2].fx, 0.6)
    H.assertEq(zones[2].fw, 0.5 - 0.1, "right zone shrinks by the divider delta")
end

function tests.moveDividerClampsAtMinFractionAndSkipsNonTouching()
    local zones = {
        { fx = 0, fy = 0, fw = 0.5, fh = 0.5 },
        { fx = 0.5, fy = 0, fw = 0.5, fh = 0.5 },
        { fx = 0, fy = 0.5, fw = 1, fh = 0.5 },  -- bottom row: does not touch
    }
    local pos, touched = SnapMath:MoveDivider(zones, 0.5, 0.95, true, 0, 0.5)
    H.assertEq(touched, 2, "full-width bottom zone has no edge on the divider")
    H.assertEq(pos, 0.88, "clamped so the right zone keeps the minimum fraction")
    H.assertEq(zones[3].fx, 0)
    H.assertEq(zones[3].fw, 1)
end

function tests.scratchTableIsReusedNotReplaced()
    local scratch = {}
    local r = SnapMath:ComputeRect("left-half", 1000, 500, 8, scratch)
    H.assertEq(r, scratch)
    local r2 = SnapMath:ComputeRect("maximize", 1000, 500, 8, scratch)
    H.assertEq(r2, scratch)
end

function tests.unknownCommandReturnsNil()
    H.assertEq(SnapMath:ComputeRect("no-such-spec", 1000, 500, 8, {}), nil)
    H.assertEq(SnapMath:HasCommand("no-such-spec"), false)
end

local pass, fail, failures = H.runSuite("SnapMath", tests)
return { pass = pass, fail = fail, failures = failures }
