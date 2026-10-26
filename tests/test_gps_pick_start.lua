-- Picking a start (or a place along the way) in a GPS search box: a click
-- on a recent search takes the box's focus before it lands, and the pick
-- has to stay on for it, or the place picked next became the destination.
local H = require("Harness")

-- The box's focus-lost handling cut from BuildSearch in GPS.lua.
local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/GPS.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("    -- Left empty for elsewhere", 1, true), "LeftEmpty not in GPS.lua")
    local hook = assert(src:find('box:HookScript("OnEditFocusLost"', s, true))
    local _, e = assert(src:find("\n    end%)\r?\n", hook))
    local ended = {}
    local list = { shown = true, over = false }
    function list:IsShown() return self.shown end
    function list:IsMouseOver() return self.over end
    local frame = { hitList = list }
    local GPS = {}
    function GPS:EndPick() ended[#ended + 1] = "pick" self.picking = nil end
    function GPS:EndAlong() ended[#ended + 1] = "along" self.along = nil end
    local onLost
    local box = { text = "" }
    function box:GetText() return self.text end
    function box:HookScript(_, fn) onLost = fn end
    local env = setmetatable({ frame = frame, box = box, GPS = GPS }, { __index = _G })
    assert(load(src:sub(s, e), "=GPS.lua focus lost", "t", env))()
    return { frame = frame, list = list, box = box, GPS = GPS, ended = ended, lose = function() onLost(box) end }
end

local tests = {}

function tests.aClickOnARecentSearch_keepsThePickOn()
    local t = Load()
    t.GPS.picking = t.frame
    t.list.over = true
    t.lose()
    H.assertEq(t.GPS.picking, t.frame, "the start is still being picked when the recent search lands")
    H.assertEq(#t.ended, 0)
end

function tests.aClickElsewhere_endsIt()
    local t = Load()
    t.GPS.picking = t.frame
    t.lose()
    H.assertNil(t.GPS.picking)
    H.assertEq(t.ended[1], "pick")
end

function tests.typedText_keepsIt()
    local t = Load()
    t.GPS.picking = t.frame
    t.box.text = "orgrimmar"
    t.lose()
    H.assertEq(t.GPS.picking, t.frame)
end

function tests.aSearchAlongTheWay_staysOnForItsListToo()
    local t = Load()
    t.GPS.along = t.frame
    t.list.over = true
    t.lose()
    H.assertEq(t.GPS.along, t.frame)
    t.list.over = false
    t.lose()
    H.assertNil(t.GPS.along)
end

local pass, fail, failures = H.runSuite("GPSPickStart", tests)
return { pass = pass, fail = fail, failures = failures }
