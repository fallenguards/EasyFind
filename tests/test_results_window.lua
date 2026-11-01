-- The results list's row window (Search/Results/Render/Window.lua): tops
-- from heights and the pin gaps, the rows touching the view, the rows that
-- keep a frame. The list shows every result; only rows near the view are
-- laid out, so a long list costs what a short one did.
local H = require("Harness")

local function load()
    local env = H.newEnv()
    local ns = H.newNs(env)
    ns.ResultRender = ns.ResultRender or {}
    H.loadModule("Search/Results/Render/Window.lua", env, ns)
    return ns.ResultRender.Window
end

local tests = {}

function tests.tops_stackHeightsWithThePinGaps()
    local W = load()
    local entries = { { isPinHeader = true }, { isPinned = true }, { isPinned = true }, {}, {} }
    local heights = { 20, 30, 30, 36, 36 }
    local tops = {}
    local total, pinEnd = W.Tops(tops, heights, entries, 5, 3, true, 4, 9)
    H.assertEq(tops[1], 0)
    H.assertEq(tops[2], 20, "the first pin follows the header with no gap")
    H.assertEq(tops[3], 54, "a pin after a pin takes the 4 px gap")
    H.assertEq(pinEnd, 84, "the separator sits under the last pin")
    H.assertEq(tops[4], 93, "the first result follows the separator")
    H.assertEq(tops[5], 129)
    H.assertEq(total, 165)
end

function tests.range_findsTheRowsTouchingTheView()
    local W = load()
    local tops, heights, n = {}, {}, 300
    for i = 1, n do heights[i] = 36 end
    local entries = {}
    for i = 1, n do entries[i] = {} end
    W.Tops(tops, heights, entries, n, 0, false, 4, 9)
    local first, last = W.Range(tops, heights, n, 0, 216)
    H.assertEq(first, 1)
    H.assertEq(last, 6, "six rows fill a 216 px view")
    first, last = W.Range(tops, heights, n, 36 * 100 + 10, 216, 1)
    H.assertEq(first, 101, "a row cut at the top still touches the view")
    H.assertEq(last, 107)
    first, last = W.Range(tops, heights, n, 36 * 299, 216, 300)
    H.assertEq(first, 300)
    H.assertEq(last, 300, "the last row alone at the end")
    first = W.Range(tops, heights, n, 36 * 50, 216, 290)
    H.assertEq(first, 51, "a hint far below walks back up")
    H.assertEq(W.Range(tops, heights, 0, 0, 216), 0, "no rows, no range")
end

function tests.bounds_keepAScreenBelowAndHalfAbove()
    local W = load()
    local a, b = W.Bounds(101, 106, 300, 6)
    H.assertEq(a, 98)
    H.assertEq(b, 112)
    a, b = W.Bounds(1, 6, 10, 6)
    H.assertEq(a, 1, "never before the first row")
    H.assertEq(b, 10, "never past the last")
end

local pass, fail, failures = H.runSuite("ResultsWindow", tests)
return { pass = pass, fail = fail, failures = failures }
