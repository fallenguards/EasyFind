-- Notes on tooltips by both ways a client fills them (Apps/Notes/Notes.lua),
-- 2026-10-26 on TBC: notes never showed. Its GameTooltip has no data
-- handler, so the data post calls never ran; Era has no data processor at
-- all. Classic's own tooltip scripts carry the lines there, once a show.
local H = require("Harness")

local function Section()
    local f = assert(io.open(H.ADDON_ROOT .. "/Apps/Notes/Notes.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("-- Note lines by what a tooltip shows.", 1, true))
    local l = assert(src:find("for _, tip in ipairs({ GameTooltip, ItemRefTooltip }) do", s, true))
    local _, e = src:find("\nend\r?\n", l)
    return src:sub(s, e)
end

-- A tooltip with the old scripts (classic) or without (retail, Forever).
local function Tooltip(classic, guid)
    local t = { scripts = {}, lines = 0 }
    function t:HasScript(name) return classic and name:find("^OnTooltip") ~= nil end
    function t:HookScript(name, fn) self.scripts[name] = fn end
    function t:Fire(name) if self.scripts[name] then self.scripts[name](self) end end
    function t:AddLine() self.lines = self.lines + 1 end
    function t:GetUnit() return "Name", "mouseover" end
    function t:GetItem() return "Item", nil end
    function t:GetSpell() return "Spell", nil end
    t.guid = guid
    return t
end

local function Load(classic)
    local tip = Tooltip(classic, "Creature-0-1-2-3-68-0000")
    local added = {}
    local post = {}
    local env = setmetatable({
        notesNS = {}, GameTooltip = tip, ItemRefTooltip = nil,
        ItemIDFromLink = function() return nil end,
        AddShowsOnLines = function(tooltip, kind, id) added[#added + 1] = kind .. ":" .. tostring(id) tooltip:AddLine() end,
        Ctx = { UnitPlayer = function() return nil end },
        UnitGUID = function() return tip.guid end,
        Utils = {},
        Enum = classic and nil or { TooltipDataType = { Item = 0, Spell = 1, Unit = 2 } },
        TooltipDataProcessor = (not classic) and {
            AddTooltipPostCall = function(kind, fn) post[kind] = fn end,
        } or nil,
    }, { __index = _G })
    assert(load(Section(), "=Notes.lua tooltips", "t", env))()
    return tip, added, post
end

local tests = {}

function tests.classic_aUnitsNotesOnceAShow()
    local tip, added = Load(true)
    tip:Fire("OnTooltipSetUnit")
    tip:Fire("OnTooltipSetUnit")
    H.assertEq(#added, 1, "once, though the script ran twice")
    H.assertEq(added[1], "npc:68", "the creature's id from its GUID")
    tip:Fire("OnTooltipCleared")
    tip:Fire("OnTooltipSetUnit")
    H.assertEq(#added, 2, "again on the next show")
end

function tests.retail_postCallsOnlyAndEveryHover()
    local tip, added, post = Load(false)
    H.assertNil(tip.scripts.OnTooltipSetUnit, "no old scripts hooked")
    post[2](tip, { guid = "Creature-0-1-2-3-68-0000" })
    post[2](tip, { guid = "Creature-0-1-2-3-68-0000" })
    H.assertEq(#added, 2, "each hover of the same unit")
end

local pass, fail, failures = H.runSuite("NotesTooltipPaths", tests)
return { pass = pass, fail = fail, failures = failures }
