-- A repaint of the same query (Search/Query.lua: a provider landed, an
-- item's data arrived, a row's state changed) lays the whole list at once
-- and keeps the view where it was. The run painted a head of fifteen with
-- the view reset to the top and the rest a frame later, so a list scrolled
-- past the head jumped back up at every arrival (2026-11-02).
local H = require("Harness")

local function Source(rel)
    local f = assert(io.open(H.ADDON_ROOT .. "/" .. rel, "rb"))
    local src = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    return src
end

local src = Source("Search/Query.lua")
local tests = {}

function tests.aRepaintIsTheSameTextAndScopeOverShownResults()
    H.assertTrue(src:find("local repaint = text == lastPaintText and quickFilter == lastPaintFilter\n"
        .. "        and resultsFrame ~= nil and resultsFrame:IsShown()", 1, true) ~= nil,
        "the same text and scope while the list is up")
    local paint = assert(src:find("self:ShowHierarchicalResults(flatEntries, repaint)", 1, true), "the view kept on a repaint")
    H.assertTrue(src:find("lastPaintText, lastPaintFilter = text, quickFilter", paint, true) ~= nil,
        "the painted text and scope remembered after the paint")
end

function tests.aRepaintLaysTheTailBeforeThePaint()
    local inline = assert(src:find("if repaint and #tail > 0 then n, lastGroup = AppendTailRows(n, lastGroup, mapSplit) end", 1, true))
    local trim = assert(src:find("TrimFlatEntries(n)\n\n    FloatPinnedFirst(flatEntries, n)", 1, true))
    H.assertTrue(inline < trim, "the tail joins the flat list before it is trimmed and painted")
    H.assertTrue(src:find("AppendTailRows(#flatEntries, tailLastGroup, tailMapSplit)", 1, true) ~= nil,
        "the deferred tail goes through the same rows")
    H.assertTrue(src:find("local TOP_N = mapSplit and #combined or 15", 1, true) ~= nil, "a fresh search keeps its head of fifteen")
end

local pass, fail, failures = H.runSuite("RepaintKeepsScroll", tests)
return { pass = pass, fail = fail, failures = failures }
