local _, ns = ...

-- A recipe's mats as a page in the bar, as a boss's loot is: Shift on a
-- recipe row. The game's recipe data hands any recipe's reagents with the
-- profession closed, known or not, enchants too (EasyFindDev /efd
-- reagents, Forever, 2026-11-23). A reagent's row says how many the recipe
-- takes and how many the character has; a click opens its sources page.
-- Typing narrows the rows.
local RecipeMats = {}
ns.RecipeMats = RecipeMats

local L, Utils = ns.L, ns.Utils
local ipairs, type = Utils.ipairs, Utils.type
local slower, sformat, sfind = Utils.slower, Utils.sformat, Utils.sfind

local def = { key = "recipeMats", canonical = "mats", token = "", label = "", nestedParent = true,
              categoryLookup = {}, bucketLookup = {} }
local entries, words, waiting = {}, {}, {}
local loads = CreateFrame("Frame")
local refreshPending = false

local function Schematic(recipeID)
    local TS = C_TradeSkillUI
    if not (TS and TS.GetRecipeSchematic and recipeID) then return nil end
    local ok, schematic = pcall(TS.GetRecipeSchematic, recipeID, false)
    return ok and type(schematic) == "table" and schematic or nil
end

function RecipeMats.Available(data)
    local TS = C_TradeSkillUI
    return data ~= nil and data.professionRecipeID ~= nil and TS ~= nil and TS.GetRecipeSchematic ~= nil
end

-- ownCounted: the note counts the player's own (Owned adds only the alts).
local function ItemRow(id, note, ownCounted)
    local name = C_Item.GetItemNameByID(id)
    if type(name) ~= "string" or name == "" then
        name = nil
        waiting[id] = true
        C_Item.RequestLoadItemDataByID(id)
        loads:RegisterEvent("ITEM_DATA_LOAD_RESULT")
    end
    return { itemID = id, catalogItem = true, lookupRow = true, category = "Item", name = name or "",
             nameLower = name and slower(name) or "", quality = C_Item.GetItemQualityByID(id), noPin = true,
             sourceNote = note, ownCounted = ownCounted }
end

-- How many of the item the character has, bank included.
local function Have(id)
    local count = C_Item.GetItemCount and C_Item.GetItemCount(id, true)
    return tonumber(count) or 0
end

-- What it makes, then each reagent the recipe must have (a slot's other
-- items, a reagent's better grades, count toward what the character has).
local function Build(recipeID)
    local schematic = Schematic(recipeID)
    local page = { made = {}, reagents = {} }
    if not schematic then return page end
    local out = schematic.outputItemID
    if type(out) == "number" and out > 0 then
        local lo, hi = schematic.quantityMin or 1, schematic.quantityMax or 1
        local count = hi > lo and sformat("%d-%d", lo, hi) or tostring(lo)
        page.made[1] = ItemRow(out, sformat(L["MATS_MAKES_FMT"], count))
    end
    for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        local first = type(slot.reagents) == "table" and slot.reagents[1]
        local id = type(first) == "table" and first.itemID
        if id and slot.required ~= false then
            local have = 0
            for _, r in ipairs(slot.reagents) do
                if type(r) == "table" and r.itemID then have = have + Have(r.itemID) end
            end
            page.reagents[#page.reagents + 1] = ItemRow(id, sformat(L["MATS_NEED_HAVE_FMT"], slot.quantityRequired or 1, have), true)
        end
    end
    return page
end

function RecipeMats:Show(data)
    def.recipeMats = { recipeID = data.professionRecipeID, name = data.name }
    def.page = nil
    def.token = "@" .. data.name
    def.label = data.name
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

-- A heading and the rows under it that match, none when none match.
local function Section(n, label, rows)
    local first = true
    for _, row in ipairs(rows) do
        if Matches(row) then
            if first then
                n = n + 1
                SetEntry(n, label, nil, true)
                first = false
            end
            n = n + 1
            SetEntry(n, row.name, row, false)
        end
    end
    return n
end

function RecipeMats:ShowView(view, text)
    local recipe = view.recipeMats
    if not recipe then return end
    if not view.page then view.page = Build(recipe.recipeID) end
    for w = #words, 1, -1 do words[w] = nil end
    for word in slower(text or ""):gmatch("%S+") do words[#words + 1] = word end
    local n = Section(0, L["MATS_MAKES"], view.page.made)
    n = Section(n, L["MATS_REAGENTS"], view.page.reagents)
    for i = n + 1, #entries do entries[i] = nil end
    ns.Results:ShowHierarchicalResults(entries)
end

-- A reagent the page waits on is in: named, and the page drawn again once
-- the burst of answers settles.
loads:SetScript("OnEvent", function(self, _, itemID, ok)
    if not waiting[itemID] then return end
    waiting[itemID] = nil
    if next(waiting) == nil then self:UnregisterEvent("ITEM_DATA_LOAD_RESULT") end
    local page = def.page
    local name = ok and C_Item.GetItemNameByID(itemID)
    if page and type(name) == "string" then
        for _, list in ipairs({ page.made, page.reagents }) do
            for _, row in ipairs(list) do
                if row.itemID == itemID then row.name, row.nameLower = name, slower(name) end
            end
        end
    end
    if refreshPending then return end
    refreshPending = true
    C_Timer.After(0.3, function()
        refreshPending = false
        if ns.Filters:GetQuickFilter() == def and ns.Search then ns.Search:RefreshActiveSearch(true) end
    end)
end)
