-- The bar rows' one deferred re-layout (Search/Results/Render/Core.lua):
-- decided once per render, after its last rows. A long list lays out in two
-- halves; deciding in each half consumed the latch in the first and re-armed
-- it in the second, every frame, and the scroll range jumped with it
-- (Anniversary's talent, skill and reputation bars, 2026-10-23).
local H = require("Harness")

local tests = {}

function tests.relayoutIsDecidedOncePerRender()
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/Results/Render/Core.lua", "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    local s = assert(src:find("    local function finish(preserve)\n", 1, true), "the finish step")
    local e = assert(src:find("\n    end\n", s, true), "end of the finish step")
    local finish = src:sub(s, e)
    H.assertNil(finish:find("repDeferredJustRan", 1, true), "the latch is not decided per half")
    H.assertNil(finish:find("deferredRepRefreshPending", 1, true))
    H.assertTrue(src:find("finish(true)\n            armBarRelayout()", 1, true) ~= nil,
        "a split list decides after its second half")
    H.assertTrue(src:find("    else\n        armBarRelayout()\n    end", 1, true) ~= nil,
        "a whole list decides after its one pass")
end

local pass, fail, failures = H.runSuite("BarRelayout", tests)
return { pass = pass, fail = fail, failures = failures }
