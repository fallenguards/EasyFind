-- The GPS window's trip fields show the last searches (Apps/GPS/Trip.lua),
-- 2026-10-26: only the map page's own search box showed them; a field
-- opened or emptied cleared the list.
local H = require("Harness")

local function Load()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/Trip.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function Editor:Open(row)", 1, true))
    local fs = assert(src:find("function Editor:ShowRecentOrNone()", s, true))
    local _, e = src:find("\nend\r?\n", fs)
    local Editor = {}
    local env = setmetatable({ Editor = Editor }, { __index = _G })
    assert(load(src:sub(s, e), "=Trip.lua recent", "t", env))()
    local asked
    local ed = setmetatable({
        frame = { ShowRecent = function(_, who) asked = who return true end },
        drop = { ClearAllPoints = function() end, SetPoint = function() end, Hide = function() end },
        Watch = function() end,
        ShowHits = function() error("cleared instead of the last searches") end,
    }, { __index = Editor })
    return ed, function() return asked end
end

local tests = {}

function tests.anOpenedFieldAsksForTheLastSearches()
    local ed, asked = Load()
    ed:Open({ box = {} })
    H.assertTrue(asked() == ed, "for this field")
end

function tests.anEmptiedFieldDoesToo()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/GPS/Trip.lua", "rb"))
    local src = f:read("*a")
    f:close()
    H.assertTrue(src:find('if text == "" then self:ShowRecentOrNone() return end', 1, true) ~= nil)
end

local pass, fail, failures = H.runSuite("GPSTripRecent", tests)
return { pass = pass, fail = fail, failures = failures }
