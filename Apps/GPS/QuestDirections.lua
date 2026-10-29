local ns = EasyFind and EasyFind._ns
if not ns then return end
local GPS = ns.GPS
if not GPS then return end
local L, Utils = ns.L, ns.Utils

-- Directions to log quests at the game's own quest places: its quest
-- menus (Menu.ModifyMenu) and search rows. Era and TBC place no quest.

local QL = C_QuestLog
local GetQuestUiMapID = GetQuestUiMapID
local ICON_TURN_IN, ICON_IN_PROGRESS = 132048, 365195

-- Where the game puts a quest in the log: its mark on its own map, else
-- the next waypoint on the way there; nil where it gives none.
local function QuestSpot(questID)
    local mapID = GetQuestUiMapID and GetQuestUiMapID(questID)
    if mapID and mapID > 0 and QL.GetQuestsOnMap then
        for _, q in ipairs(QL.GetQuestsOnMap(mapID) or {}) do
            if q.questID == questID and q.x and q.y then return mapID, q.x, q.y end
        end
    end
    if QL.GetNextWaypoint then
        local wMap, x, y = QL.GetNextWaypoint(questID)
        if wMap and x and y then return wMap, x, y end
    end
    return nil
end
GPS.QuestSpot = QuestSpot

-- The quests in the log, { questID, title, level, done } each.
local function LogQuests()
    local out = {}
    if QL.GetNumQuestLogEntries and QL.GetInfo then
        for i = 1, QL.GetNumQuestLogEntries() do
            local info = QL.GetInfo(i)
            if info and not info.isHeader and not info.isHidden and info.questID and info.questID > 0 then
                out[#out + 1] = { questID = info.questID, title = info.title, level = info.level,
                                  done = QL.IsComplete and QL.IsComplete(info.questID) or false }
            end
        end
    elseif GetNumQuestLogEntries and GetQuestLogTitle then
        for i = 1, GetNumQuestLogEntries() do
            local title, level, _, isHeader, _, isComplete, _, questID = GetQuestLogTitle(i)
            if title and not isHeader and questID and questID > 0 then
                out[#out + 1] = { questID = questID, title = title, level = level, done = (isComplete or 0) > 0 }
            end
        end
    end
    return out
end

local function QuestTitle(questID)
    local title = QL.GetTitleForQuestID and QL.GetTitleForQuestID(questID)
    if title then return title end
    for _, q in ipairs(LogQuests()) do
        if q.questID == questID then return q.title end
    end
    return nil
end

local function Destination(questID)
    local mapID, x, y = QuestSpot(questID)
    if not mapID then return nil end
    local done = QL.IsComplete and QL.IsComplete(questID)
    local dest = { name = QuestTitle(questID) or L["APP_GPS"], mapID = mapID, x = x, y = y,
                   icon = done and ICON_TURN_IN or ICON_IN_PROGRESS }
    return GPS:CanNavigate(dest) and dest or nil
end

local function Navigate(dest)
    EasyFind.API.CallAction("gps", "navigate", dest, { popout = true })
end

-- ==== the client's quest menus ===============================================

local function AddDirections(root, questID)
    if not (questID and QL.IsOnQuest and QL.IsOnQuest(questID)) then return end
    local dest = Destination(questID)
    if not dest then return end
    root:CreateDivider()
    root:CreateButton(L["GPS_MENU_DIRECTIONS"], function() Navigate(dest) end)
end

-- The quest a frame under the cursor stands for (a tracker block's id, a
-- log title's questID): the tracker's menu belongs to the whole tracker.
local function QuestUnderCursor()
    local foci = GetMouseFoci and GetMouseFoci() or { GetMouseFocus and GetMouseFocus() }
    for i = 1, #foci do
        local f, depth = foci[i], 0
        while f and depth < 6 do
            local id = f.questID or f.id
            if type(id) == "number" and QL.IsOnQuest and QL.IsOnQuest(id) then return id end
            f, depth = f.GetParent and f:GetParent(), depth + 1
        end
    end
    return nil
end

if Menu and Menu.ModifyMenu then
    Menu.ModifyMenu("MENU_QUEST_OBJECTIVE_TRACKER", function(_, root)
        AddDirections(root, QuestUnderCursor())
    end)
    Menu.ModifyMenu("MENU_QUEST_MAP_LOG_TITLE", function(owner, root)
        AddDirections(root, owner and type(owner.questID) == "number" and owner.questID or QuestUnderCursor())
    end)
    -- Mists Classic's watch list: the line knows its watch index.
    Menu.ModifyMenu("MENU_WATCH_FRAME_LINK", function(owner, root)
        if not (owner and owner.type == "QUEST" and owner.index and GetQuestIndexForWatch and GetQuestLogTitle) then return end
        local logIndex = GetQuestIndexForWatch(owner.index)
        AddDirections(root, logIndex and select(8, GetQuestLogTitle(logIndex)))
    end)
end

-- ==== the log's quests as search rows ========================================

-- Only where the client places quests, and not beside the Questie
-- extension's rows, which list these quests already.
local function Questie()
    local loadable = C_AddOns and C_AddOns.IsAddOnLoadable and C_AddOns.IsAddOnLoadable("EasyFind_Questie")
    return loadable and true or false
end
if not (GetQuestUiMapID or QL.GetNextWaypoint) or Questie() then return end

local KEY = "logQuests"

local function Rows()
    local out = {}
    for _, q in ipairs(LogQuests()) do
        out[#out + 1] = {
            name = q.title, questID = q.questID, inLog = true,
            icon = q.done and ICON_TURN_IN or ICON_IN_PROGRESS,
            searchCommandDesc = q.level and q.level > 0 and string.format(L["GPS_QUEST_LEVEL_FMT"], q.level) or nil,
        }
    end
    return out
end

local function OpenLog(questID)
    if QuestMapFrame_OpenToQuestDetails then
        QuestMapFrame_OpenToQuestDetails(questID)
    elseif ToggleQuestLog then
        ToggleQuestLog()
    end
end

EasyFind.API.RegisterSearchProvider({
    key = KEY,
    label = QUESTS_LABEL or "Quests",
    extension = "gps",
    words = { "quest", "quests" },
    rows = Rows,
    place = function(row) return row.questID and Destination(row.questID) or nil end,
    select = function(row)
        if IsAltKeyDown() then return OpenLog(row.questID) end
        local dest = Destination(row.questID)
        if dest then return Navigate(dest) end
        OpenLog(row.questID)
    end,
    hint = function(row)
        return { click = Destination(row.questID) and L["GPS_MENU_DIRECTIONS"] or (QUEST_LOG or "Quest log"),
                 alt = QUEST_LOG or "Quest log" }
    end,
    browse = function() return true end,
})

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function() EasyFind.API.RefreshSearchProvider(KEY) end)
for _, event in ipairs({ "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN" }) do
    Utils.RegisterEventIfValid(events, event)
end
