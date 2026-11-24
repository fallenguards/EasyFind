local _, ns = ...

-- An extension's rows as a page in the bar, in the order it hands them
-- (API.ShowRows, MINOR 14): a quest chain's parts, numbered, which a
-- ranking would reorder. The rows stay the provider's: its click,
-- tooltip, hint and menu. Typing narrows them by name and subtext.
local RowsPage = {}
ns.RowsPage = RowsPage

local Utils = ns.Utils
local slower, sfind = Utils.slower, Utils.sfind

local def = { key = "rowsPage", canonical = "rows", token = "", label = "", nestedParent = true,
              categoryLookup = {}, bucketLookup = {} }
local entries, words = {}, {}

-- rows: the provider's own row tables, named and given its category here
-- (a row the provider holds back from search has neither yet).
function RowsPage:Show(category, title, rows)
    for i = 1, #rows do
        local row = rows[i]
        row.category = category
        if not row.nameLower and type(row.name) == "string" then row.nameLower = slower(row.name) end
    end
    def.rowsPage = rows
    def.token = "@" .. title
    def.label = title
    ns.Filters:ApplyQuickFilter(def, "")
end

local function Matches(row)
    if #words == 0 then return true end
    local note = type(row.searchCommandDesc) == "string" and slower(row.searchCommandDesc)
    for w = 1, #words do
        if not (sfind(row.nameLower or "", words[w], 1, true) or (note and sfind(note, words[w], 1, true))) then
            return false
        end
    end
    return true
end

function RowsPage:ShowView(view, text)
    local rows = view.rowsPage
    if not rows then return end
    for w = #words, 1, -1 do words[w] = nil end
    for word in slower(text or ""):gmatch("%S+") do words[#words + 1] = word end
    local n = 0
    for i = 1, #rows do
        local row = rows[i]
        if Matches(row) then
            n = n + 1
            local e = entries[n] or {}
            entries[n] = e
            e.name, e.depth, e.isPathNode, e.isMatch, e.isPinned, e.isFlat, e.data = row.name, 0, false, true, false, true, row
            e.isSectionHeader, e.section, e.toggle, e.collapsed = nil, nil, nil, nil
        end
    end
    for i = n + 1, #entries do entries[i] = nil end
    ns.Results:ShowHierarchicalResults(entries)
end
