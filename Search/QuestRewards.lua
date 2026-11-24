local _, ns = ...

-- A quest's item rewards as a page in the bar, as a boss's loot: the
-- item sources data's quest rewards read the other way (Forever, Era,
-- TBC; 2026-11-25). Each reward is EasyFind's item row (a click opens its
-- sources page) saying its slot and kind. Typing narrows the rows.
local QuestRewards = {}
ns.QuestRewards = QuestRewards

local Utils = ns.Utils
local ipairs, type = Utils.ipairs, Utils.type
local slower, sfind = Utils.slower, Utils.sfind

local def = { key = "questRewards", canonical = "rewards", token = "", label = "", nestedParent = true,
              categoryLookup = {}, bucketLookup = {} }
local entries, words, waiting = {}, {}, {}
local loads = CreateFrame("Frame")
local refreshPending = false

-- "Head, Leather"; a reward that is no gear: its kind ("Consumable").
local function Kind(id)
    local read = C_Item and C_Item.GetItemInfoInstant
    if not read then return nil end
    local _, kind, sub, equipLoc = read(id)
    local slot = type(equipLoc) == "string" and equipLoc ~= "" and _G[equipLoc]
    if slot and type(sub) == "string" and sub ~= "" then return slot .. ", " .. sub end
    return slot or kind
end

local function ItemRow(id)
    local name = C_Item.GetItemNameByID(id)
    if type(name) ~= "string" or name == "" then
        name = nil
        waiting[id] = true
        C_Item.RequestLoadItemDataByID(id)
        loads:RegisterEvent("ITEM_DATA_LOAD_RESULT")
    end
    return { itemID = id, catalogItem = true, lookupRow = true, category = "Item", name = name or "",
             nameLower = name and slower(name) or "", quality = C_Item.GetItemQualityByID(id), noPin = true,
             sourceNote = Kind(id) }
end

-- The data is read in here, on the player's Shift, never at login.
function QuestRewards:Show(questID, title)
    local data = ns.RequestSourceData and ns.RequestSourceData() and ns.SourceData
    local ids = data and data.QuestRewards and data.QuestRewards(questID) or {}
    local rows = {}
    for i, id in ipairs(ids) do rows[i] = ItemRow(id) end
    def.questRewards = { questID = questID, rows = rows }
    def.token = "@" .. title
    def.label = title
    ns.Filters:ApplyQuickFilter(def, "")
end

local function Matches(row)
    if #words == 0 then return true end
    local note = row.sourceNote and slower(row.sourceNote)
    for w = 1, #words do
        if not (sfind(row.nameLower, words[w], 1, true) or (note and sfind(note, words[w], 1, true))) then
            return false
        end
    end
    return true
end

local function SetEntry(n, name, data, header)
    local e = entries[n] or {}
    entries[n] = e
    e.name, e.depth, e.isPathNode, e.isMatch, e.isPinned, e.isFlat, e.data = name, 0, false, not header, false, true, data
    e.isSectionHeader = header
    e.section, e.toggle, e.collapsed = nil, nil, nil
end

-- The heading, then each reward that matches; a quest with none says so.
function QuestRewards:ShowView(view, text)
    local page = view.questRewards
    if not page then return end
    for w = #words, 1, -1 do words[w] = nil end
    for word in slower(text or ""):gmatch("%S+") do words[#words + 1] = word end
    local heading = _G["QUEST_REWARDS"] or "Rewards"
    local n = 1
    SetEntry(1, #page.rows > 0 and heading or (heading .. ": " .. (_G["NONE"] or "None")), nil, true)
    for _, row in ipairs(page.rows) do
        if Matches(row) then
            n = n + 1
            SetEntry(n, row.name, row, false)
        end
    end
    for i = n + 1, #entries do entries[i] = nil end
    ns.Results:ShowHierarchicalResults(entries)
end

-- A reward the page waits on is in: named, and the page drawn again once
-- the burst of answers settles.
loads:SetScript("OnEvent", function(self, _, itemID, ok)
    if not waiting[itemID] then return end
    waiting[itemID] = nil
    if next(waiting) == nil then self:UnregisterEvent("ITEM_DATA_LOAD_RESULT") end
    local page = def.questRewards
    local name = ok and C_Item.GetItemNameByID(itemID)
    if page and type(name) == "string" then
        for _, row in ipairs(page.rows) do
            if row.itemID == itemID then row.name, row.nameLower = name, slower(name) end
        end
    end
    if refreshPending then return end
    refreshPending = true
    C_Timer.After(0.3, function()
        refreshPending = false
        if ns.Filters:GetQuickFilter() == def and ns.Search then ns.Search:RefreshActiveSearch(true) end
    end)
end)
