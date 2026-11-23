-- A row's release belongs to the row that was pressed (2026-11-22: a
-- Shift-click on a vendor's row lists its wares on the press; the row
-- under the mouse was then one of its items, and the release counted as a
-- Shift-click on that item: its link on the cursor, the bar closed).
-- The two mouse hooks cut from Search/Results/Rows/Interactions.lua.
local H = require("Harness")

local function Hooks()
    local f = assert(io.open(H.ADDON_ROOT .. "/Search/Results/Rows/Interactions.lua", "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    local function Body(script)
        local open = 'resultRow:HookScript("' .. script .. '", function(self, button)\n'
        local s = assert(src:find(open, 1, true), script)
        local e = assert(src:find("\n    end)\n", s, true), script .. " end")
        return "function(self, button)\n" .. src:sub(s + #open, e) .. "\nend"
    end
    local w = { picked = {}, closed = 0, shift = false }
    local env = setmetatable({
        InCombatLockdown = function() return false end,
        IsShiftKeyDown = function() return w.shift end,
        GetCursorPosition = function() return 0, 0 end,
        ns = { ResultGestures = {
            -- An item row sends its link on Shift; a vendor's Shift is its wares.
            Does = function(d, action) return action == "sendLink" and d.lookupRow and w.shift end,
            ShiftChosen = function(d) return d.vendor end,
        } },
        Handlers = { IsLookupRow = function(_, d) return d ~= nil and d.lookupRow == true end,
                     FinishResultSelection = function() w.closed = w.closed + 1 end },
        PickupRowAction = function(d) w.picked[#w.picked + 1] = d.name end,
        CanPickupRowAction = function() return false end,
    }, { __index = _G })
    w.down, w.up = assert(load("return " .. Body("OnMouseDown") .. ", " .. Body("OnMouseUp"), "=row hooks", "t", env))()
    return w
end

local tests = {}

function tests.aPressThatListsWares_itsReleasePicksNothingUp()
    local w = Hooks()
    local row = { data = { name = "Vendor", vendor = true } }
    w.shift = true
    w.down(row, "LeftButton")
    -- The press listed the wares: the same frame now shows one of them.
    row.data = { name = "Simple Wood", lookupRow = true }
    w.up(row, "LeftButton")
    H.assertEq(#w.picked, 0, "no item on the cursor")
    H.assertEq(w.closed, 0, "the wares stay up")
end

function tests.aClickOnAnItemRow_stillSendsItsLink()
    local w = Hooks()
    local row = { data = { name = "Simple Wood", lookupRow = true } }
    w.shift = true
    w.down(row, "LeftButton")
    w.up(row, "LeftButton")
    H.assertEq(table.concat(w.picked, " "), "Simple Wood")
    H.assertEq(w.closed, 1, "dismissed as any activated row")
    -- The next press starts clean.
    w.up(row, "LeftButton")
    H.assertEq(#w.picked, 1, "a release with no press of its own picks nothing up")
end

local pass, fail, failures = H.runSuite("ReleaseIsThePresss", tests)
return { pass = pass, fail = fail, failures = failures }
