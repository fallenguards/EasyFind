-- The bar's map pass memo (Search/Query.lua MapPass): a rerun only search
-- rows asked for (a provider landing) reuses the last pass for the same
-- text moments later; any other request, another pass in between, another
-- zone or a second gone by runs the pass again.
local H = require("Harness")

local function Memo()
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/Query.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("local MAP_REUSE_S", 1, true), "the memo")
    local e = assert(src:find("-- end of the map pass memo", s, true), "its end")
    local passes, zone, now = 0, 1, 100
    local ns = {
        MapSearchSearch = { uiSearchCount = 0 },
        MapSearch = {},
    }
    function ns.MapSearch:SearchForUI(text)
        passes = passes + 1
        ns.MapSearchSearch.uiSearchCount = ns.MapSearchSearch.uiSearchCount + 1
        return { text = text, pass = passes }
    end
    local env = setmetatable({
        ns = ns,
        GetTime = function() return now end,
        C_Map = { GetBestMapForUnit = function() return zone end },
    }, { __index = _G })
    local chunk = "local ns = ns\n" .. src:sub(s, e - 1) .. "\nreturn MapPass, MapPassRedone, MapPassStale"
    local MapPass, MapPassRedone, MapPassStale = assert(load(chunk, "=Query.lua map memo", "t", env))()
    local ctl = {}
    function ctl.passes() return passes end
    function ctl.at(t) now = t end
    function ctl.zone(z) zone = z end
    function ctl.otherPass() ns.MapSearchSearch.uiSearchCount = ns.MapSearchSearch.uiSearchCount + 1 end
    return MapPass, MapPassRedone, MapPassStale, ctl
end

local tests = {}

function tests.aRowsOnlyRerun_reusesThePassMomentsLater()
    local MapPass, _, _, ctl = Memo()
    local first = MapPass("vendor", false)
    ctl.at(100.4)
    H.assertEq(MapPass("vendor", true), first, "the same rows")
    H.assertEq(ctl.passes(), 1, "no second pass")
end

function tests.everythingElse_runsThePass()
    local MapPass, MapPassRedone, MapPassStale, ctl = Memo()
    MapPass("vendor", false)
    MapPass("vendor", false)
    H.assertEq(ctl.passes(), 2, "a rerun that is not rows only")
    MapPass("vendo", true)
    H.assertEq(ctl.passes(), 3, "another text")
    MapPass("vendor", false)
    MapPassStale()
    MapPass("vendor", true)
    H.assertEq(ctl.passes(), 5, "after a request that may have changed the map's inputs")
    ctl.otherPass()
    MapPass("vendor", true)
    H.assertEq(ctl.passes(), 6, "after a pass of someone else's")
    ctl.zone(2)
    MapPass("vendor", true)
    H.assertEq(ctl.passes(), 7, "in another zone")
    ctl.at(101.5)
    MapPass("vendor", true)
    H.assertEq(ctl.passes(), 8, "a second later")
    -- A boost's own pass replaces the rows the memo holds.
    local redone = { redone = true }
    ctl.otherPass()
    MapPassRedone(redone)
    H.assertEq(MapPass("vendor", true), redone, "the boost's rows")
end

local pass, fail, failures = H.runSuite("MapPassReuse", tests)
return { pass = pass, fail = fail, failures = failures }
