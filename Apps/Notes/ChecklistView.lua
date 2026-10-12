local _, notesNS = ...
local ns = EasyFind and EasyFind._ns
if not (ns and notesNS.Checklist and notesNS.UI) then return end

-- The checklist view: stands where the note editor is while a checklist
-- note is open. Rows tick by hand or from the game; the top bar picks who
-- keeps the ticks, when they clear, and the alts board.
local View = {}
notesNS.ChecklistView = View

local CK = notesNS.Checklist
local NotesUI = notesNS.UI
local Utils = ns.Utils
local L = ns.L
local CreateFrame, time = CreateFrame, time
local sformat, mmax, mfloor, tonumber, tostring = string.format, math.max, math.floor, tonumber, tostring
local ipairs, smatch, strtrim = ipairs, string.match, strtrim

local ROW_H, ROW_H2, BAR_H, ADD_H, CELL_W, NAME_W = 26, 36, 26, 28, 56, 150
local DONE_COLOR, OPEN_COLOR, FAINT_COLOR = { 0.45, 0.85, 0.45 }, { 1, 1, 1 }, { 0.65, 0.65, 0.65 }
local READY_TEX = "Interface\\RaidFrame\\ReadyCheck-Ready"

-- Frames and state in one table (upvalue budget).
local UI = { rows = {}, cells = {}, heads = {}, allowed = false, board = false }

local function Text(parent, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template)
    ns.RegisterAddonFont(fs)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function Note()
    return notesNS.SelectedNote and notesNS.SelectedNote()
end

local function Changed(note)
    note.updated = time()
    View.Refresh()
end

-- The auction house

local function AuctionOpen()
    local ah = _G["AuctionHouseFrame"]
    return ah ~= nil and ah:IsShown()
end

-- The item's name in the auction house's own search bar, then its search.
local function SearchAH(line)
    local ah = _G["AuctionHouseFrame"]
    local bar = ah and ah:IsShown() and ah.SearchBar
    if not (bar and bar.SetSearchText and bar.StartSearch and line.item) then return end
    local name = C_Item.GetItemNameByID and C_Item.GetItemNameByID(line.item)
    if not name then return end
    bar:SetSearchText(name)
    bar:StartSearch()
    UI.lastSearched = line.id
end

-- The next item line still short of its target, after the last searched.
local function SearchNext(note)
    local lines, start = note.list.lines, 1
    for i, line in ipairs(lines) do
        if line.id == UI.lastSearched then start = i + 1 break end
    end
    for n = 0, #lines - 1 do
        local line = lines[(start - 1 + n) % #lines + 1]
        if line.link == "item" and not CK.LineState(note, line) then
            SearchAH(line)
            return
        end
    end
end

-- Pickers

local function Radio(owner, options, get, set)
    local defs = {}
    for _, o in ipairs(options) do
        defs[#defs + 1] = { kind = "radio", label = o.label, value = o.value, get = get,
            set = function(v) set(v) View.Refresh() end }
    end
    ns.ShowTogglePopup("EasyFindChecklistPick", owner, defs, {})
end

local function Menu(owner, rows)
    local menu = UI.menu
    if menu and menu:IsShown() and menu.toggleOwner == owner then
        menu:Hide()
        return
    end
    UI.menu = Utils.ShowCursorMenu("EasyFindChecklistMenu", rows, { toggleOwner = owner })
end

local function Ask(text, default, onAccept, numeric)
    ns.ShowThemedDialog({
        text = text, hasEditBox = true, editBoxDefault = default and tostring(default) or "", maxLetters = 60,
        acceptText = _G["OKAY"] or "Okay", cancelText = _G["CANCEL"] or "Cancel",
        onAccept = function(value)
            value = strtrim(value or "")
            if numeric then
                local n = tonumber(value)
                if n then onAccept(n) end
            elseif value ~= "" then
                onAccept(value)
            end
        end,
    })
end

local SCOPES = {
    { value = "account", label = L["CHECK_SCOPE_ACCOUNT"] },
    { value = "character", label = L["CHECK_SCOPE_CHARACTER"] },
}
local RESETS = {
    { value = "never", label = L["CHECK_RESET_NEVER"] },
    { value = "daily", label = L["CHECK_RESET_DAILY"] },
    { value = "weekly", label = L["CHECK_RESET_WEEKLY"] },
    { value = "days", label = L["CHECK_RESET_DAYS"] },
}

local function OptionLabel(options, value)
    for _, o in ipairs(options) do
        if o.value == value then return o.label end
    end
    return options[1].label
end

local function PickReset(owner, note)
    local reset = note.list.reset
    local defs = {}
    for _, o in ipairs(RESETS) do
        defs[#defs + 1] = { kind = "radio", label = o.label, value = o.value,
            get = function() return reset.every end, set = function(v) reset.every = v Changed(note) end }
    end
    if reset.every == "days" then
        defs[#defs + 1] = { kind = "separator" }
        reset.days = reset.days or {}
        for wday = 1, 7 do
            defs[#defs + 1] = { kind = "check", label = _G["WEEKDAY_" .. ({ "SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY" })[wday]] or tostring(wday),
                get = function() return reset.days[wday] == true end,
                set = function(v) reset.days[wday] = v or nil Changed(note) end }
        end
        defs[#defs + 1] = { kind = "action", label = sformat(L["CHECK_RESET_AT_FMT"], reset.hour or 0, reset.min or 0), onClick = function()
            Ask(L["CHECK_RESET_AT_ASK"], sformat("%02d:%02d", reset.hour or 0, reset.min or 0), function(v)
                local h, m = smatch(v, "^(%d%d?):(%d%d)$")
                h, m = tonumber(h), tonumber(m)
                if h and m and h < 24 and m < 60 then reset.hour, reset.min = h, m Changed(note) end
            end)
        end }
    end
    ns.ShowTogglePopup("EasyFindChecklistReset", owner, defs, {})
end

-- Adding lines

local function AddLine(note, line)
    if not line then return end
    CK.AddLine(note, line)
    Changed(note)
end

local function QuestRows(note)
    local rows = {}
    local QL = C_QuestLog
    for i = 1, (QL and QL.GetNumQuestLogEntries and QL.GetNumQuestLogEntries()) or 0 do
        local info = QL.GetInfo(i)
        if info and not info.isHeader and info.questID then
            rows[#rows + 1] = { text = info.title, onClick = function() AddLine(note, { link = "quest", quest = info.questID }) end }
        end
    end
    return rows
end

local function FactionRows(note)
    local rows = {}
    local R = C_Reputation
    for i = 1, (R and R.GetNumFactions and R.GetNumFactions()) or 0 do
        local data = R.GetFactionDataByIndex and R.GetFactionDataByIndex(i)
        if data and not data.isHeader and data.factionID and data.factionID > 0 then
            rows[#rows + 1] = { text = data.name, onClick = function() AddLine(note, { link = "rep", faction = data.factionID, standing = 8 }) end }
        end
    end
    return rows
end

local function SkillRows(note)
    local rows = {}
    for _, prof in ipairs({ GetProfessions and GetProfessions() }) do
        if prof then
            local name, _, _, maxLevel = GetProfessionInfo(prof)
            if name then
                rows[#rows + 1] = { text = name, onClick = function() AddLine(note, { link = "skill", skill = name, target = maxLevel or 1 }) end }
            end
        end
    end
    return rows
end

local function LockoutRows(note)
    local rows, seen = {}, {}
    for i = 1, (GetNumSavedInstances and GetNumSavedInstances()) or 0 do
        local name = GetSavedInstanceInfo(i)
        if name and not seen[name] then
            seen[name] = true
            rows[#rows + 1] = { text = name, onClick = function() AddLine(note, { link = "lockout", instance = name }) end }
        end
    end
    rows[#rows + 1] = { text = L["CHECK_TYPE_NAME"], onClick = function()
        Ask(L["CHECK_LOCKOUT_ASK"], "", function(v) AddLine(note, { link = "lockout", instance = v }) end)
    end }
    return rows
end

local function BagItemRows(note)
    local rows, seen = {}, {}
    local C_Container = C_Container
    for bag = 0, NUM_BAG_SLOTS or 4 do
        for slot = 1, (C_Container and C_Container.GetContainerNumSlots(bag)) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local id = info and info.itemID
            if id and not seen[id] then
                seen[id] = true
                local name = C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
                if name then rows[#rows + 1] = { text = name, onClick = function() AddLine(note, { link = "item", item = id, target = 1 }) end } end
            end
        end
    end
    table.sort(rows, function(a, b) return a.text < b.text end)
    return rows
end

local function Empty(rows)
    if #rows == 0 then rows[1] = { text = L["CHECK_NOTHING_HERE"], disabled = true } end
    return rows
end

local function LinkMenu(owner, note)
    Menu(owner, {
        { text = L["CHECK_LINK_ITEM"], submenu = Empty(BagItemRows(note)), tooltip = L["CHECK_SHIFT_CLICK_TT"] },
        { text = L["CHECK_LINK_QUEST"], submenu = Empty(QuestRows(note)) },
        { text = L["CHECK_LINK_REP"], submenu = Empty(FactionRows(note)) },
        { text = L["CHECK_LINK_GOLD"], onClick = function()
            Ask(L["CHECK_GOLD_ASK"], 100, function(n) AddLine(note, { link = "gold", target = mfloor(n * 10000) }) end, true)
        end },
        { text = L["CHECK_LINK_LEVEL"], onClick = function()
            Ask(L["CHECK_LEVEL_ASK"], (UnitLevel("player") or 1) + 1, function(n) AddLine(note, { link = "level", target = mfloor(n) }) end, true)
        end },
        { text = L["CHECK_LINK_SKILL"], submenu = Empty(SkillRows(note)) },
        { text = L["CHECK_LINK_LOCKOUT"], submenu = Empty(LockoutRows(note)) },
        { text = L["CHECK_LINK_COOLDOWN"], onClick = function()
            Ask(L["CHECK_COOLDOWN_ASK"], "", function(v)
                local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(tonumber(v) or v)
                if info and info.spellID then AddLine(note, { link = "cooldown", spell = info.spellID }) end
            end)
        end },
    })
end

-- Rows

local TARGET_ASK = { item = "CHECK_TARGET_ITEM_ASK", gold = "CHECK_GOLD_ASK", level = "CHECK_LEVEL_ASK", skill = "CHECK_TARGET_SKILL_ASK" }

local function RowMenu(row)
    local note, line = Note(), row.line
    if not (note and line) then return end
    local rows = {}
    if line.link == "item" and AuctionOpen() then
        rows[#rows + 1] = { text = L["CHECK_SEARCH_AH"], onClick = function() SearchAH(line) end }
    end
    if TARGET_ASK[line.link] then
        rows[#rows + 1] = { text = L["CHECK_SET_TARGET"], onClick = function()
            local cur = line.link == "gold" and mfloor((line.target or 0) / 10000) or line.target
            Ask(L[TARGET_ASK[line.link]], cur, function(n)
                line.target = line.link == "gold" and mfloor(n * 10000) or mmax(1, mfloor(n))
                Changed(note)
            end, true)
        end }
    end
    if line.link == "rep" then
        local sub = {}
        for standing = 4, 8 do
            sub[#sub + 1] = { text = CK.StandingLabel(standing), onClick = function() line.standing = standing Changed(note) end }
        end
        rows[#rows + 1] = { text = L["CHECK_SET_STANDING"], submenu = sub }
    end
    rows[#rows + 1] = { text = L["CHECK_RENAME"], onClick = function()
        Ask(L["CHECK_RENAME_ASK"], CK.LineName(line), function(v) line.text = v CK.SyncBody(note) Changed(note) end)
    end }
    rows[#rows + 1] = { text = L["CHECK_MOVE_UP"], onClick = function() CK.MoveLine(note, line.id, -1) CK.SyncBody(note) Changed(note) end }
    rows[#rows + 1] = { text = L["CHECK_MOVE_DOWN"], onClick = function() CK.MoveLine(note, line.id, 1) CK.SyncBody(note) Changed(note) end }
    rows[#rows + 1] = { isSeparator = true }
    rows[#rows + 1] = { text = _G["REMOVE"] or L["CHECK_REMOVE"], onClick = function() CK.RemoveLine(note, line.id) Changed(note) end }
    Menu(row, rows)
end

local function ItemIcon(line)
    if line.link == "item" then return C_Item.GetItemIconByID and C_Item.GetItemIconByID(line.item) end
    if line.link == "cooldown" then
        if line.item then return C_Item.GetItemIconByID and C_Item.GetItemIconByID(line.item) end
        return C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(line.spell)
    end
end

local function CreateRow(i)
    local row = CreateFrame("Button", nil, UI.list)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
    row:GetHighlightTexture():SetAlpha(0.2)
    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(22, 22)
    row.check:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
    row.check:SetScript("OnClick", function(self)
        local note = Note()
        if not (note and row.line) then return end
        if row.line.link then
            self:SetChecked(row.done)
            return
        end
        CK.SetTicked(note, row.line, ns.CurrentCharacterKey(), self:GetChecked())
        View.Refresh()
    end)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", row.check, "RIGHT", 2, 0)
    row.name = Text(row, "GameFontHighlight")
    row.progress = Text(row, "GameFontHighlight")
    row.progress:SetJustifyH("RIGHT")
    row.progress:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -6)
    row.detail = Text(row, "GameFontDisableSmall")
    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            RowMenu(self)
        elseif self.line and self.line.link == "item" and AuctionOpen() then
            SearchAH(self.line)
        end
    end)
    UI.rows[i] = row
    return row
end

local function FillRow(row, note, line, y)
    row.line = line
    local done, progress, detail = CK.LineState(note, line)
    row.done = done and true or false
    row.check:SetChecked(row.done)
    row.check:SetAlpha(line.link and 0.7 or 1)
    local icon = ItemIcon(line)
    row.icon:SetShown(icon ~= nil)
    if icon then row.icon:SetTexture(icon) end
    row.name:ClearAllPoints()
    row.name:SetPoint("TOPLEFT", icon and row.icon or row.check, "TOPRIGHT", 4, icon and 0 or -4)
    row.name:SetPoint("RIGHT", row.progress, "LEFT", -6, 0)
    row.name:SetText(CK.LineName(line))
    local c = row.done and DONE_COLOR or OPEN_COLOR
    row.name:SetTextColor(c[1], c[2], c[3], 1)
    row.progress:SetText(progress or "")
    row.progress:SetTextColor(c[1], c[2], c[3], 1)
    local hasDetail = detail and detail ~= ""
    row.detail:SetShown(hasDetail)
    if hasDetail then
        row.detail:ClearAllPoints()
        row.detail:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
        row.detail:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.detail:SetText(detail)
    end
    local h = hasDetail and ROW_H2 or ROW_H
    row:SetHeight(h)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", UI.list, "TOPLEFT", 0, -y)
    row:SetPoint("RIGHT", UI.list, "RIGHT", 0, 0)
    row:Show()
    return h
end

-- The alts board: one column per character, one row per line.

local function Cell(i)
    local cell = UI.cells[i]
    if cell then return cell end
    cell = CreateFrame("Frame", nil, UI.list)
    cell:SetSize(CELL_W, ROW_H)
    cell.tex = cell:CreateTexture(nil, "ARTWORK")
    cell.tex:SetSize(16, 16)
    cell.tex:SetPoint("CENTER")
    cell.tex:SetTexture(READY_TEX)
    cell.text = Text(cell, "GameFontHighlightSmall")
    cell.text:SetPoint("CENTER")
    cell.text:SetJustifyH("CENTER")
    UI.cells[i] = cell
    return cell
end

local function Head(i)
    local head = UI.heads[i]
    if head then return head end
    head = Text(UI.list, "GameFontNormalSmall")
    head:SetWidth(CELL_W)
    head:SetJustifyH("CENTER")
    UI.heads[i] = head
    return head
end

local function FillBoard(note)
    for _, row in ipairs(UI.rows) do row:Hide() end
    local chars = CK.Board(note)
    local lines = note.list.lines
    for i, charKey in ipairs(chars) do
        local head = Head(i)
        head:ClearAllPoints()
        head:SetPoint("TOPLEFT", UI.list, "TOPLEFT", NAME_W + (i - 1) * CELL_W, 0)
        head:SetText(CK.CharName(charKey))
        head:Show()
    end
    for i = #chars + 1, #UI.heads do UI.heads[i]:Hide() end
    local n = 0
    for r, line in ipairs(lines) do
        CK.LineState(note, line)
        local y = 18 + (r - 1) * ROW_H
        local row = UI.rows[r] or CreateRow(r)
        row.line = line
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", UI.list, "TOPLEFT", 0, -y)
        row:SetSize(NAME_W, ROW_H)
        row.check:Hide()
        row.icon:Hide()
        row.progress:SetText("")
        row.detail:Hide()
        row.name:ClearAllPoints()
        row.name:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.name:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.name:SetText(CK.LineName(line))
        row.name:SetTextColor(1, 1, 1, 1)
        row:Show()
        for c, charKey in ipairs(chars) do
            n = n + 1
            local cell = Cell(n)
            local done, progress = CK.BoardCell(note, line, charKey)
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", UI.list, "TOPLEFT", NAME_W + (c - 1) * CELL_W, -y)
            cell.tex:SetShown(done == true)
            cell.text:SetShown(done ~= true)
            cell.text:SetText(done == nil and "-" or (progress or ""))
            cell.text:SetTextColor(FAINT_COLOR[1], FAINT_COLOR[2], FAINT_COLOR[3], 1)
            cell:Show()
        end
    end
    for i = n + 1, #UI.cells do UI.cells[i]:Hide() end
    return 18 + #lines * ROW_H
end

local function FillList(note)
    for _, cell in ipairs(UI.cells) do cell:Hide() end
    for _, head in ipairs(UI.heads) do head:Hide() end
    local y = 0
    for i, line in ipairs(note.list.lines) do
        local row = UI.rows[i] or CreateRow(i)
        row.check:Show()
        y = y + FillRow(row, note, line, y)
    end
    for i = #note.list.lines + 1, #UI.rows do UI.rows[i]:Hide() end
    return y
end

-- The view

local function EnsureView()
    if UI.view then return UI.view end
    local frame = NotesUI._notes and NotesUI._notes.frame
    if not (frame and frame.editorScroll) then return nil end
    local view = CreateFrame("Frame", nil, frame)
    UI.view = view
    view:SetAllPoints(frame.editorScroll)
    view:Hide()

    local bar = CreateFrame("Frame", nil, view)
    bar:SetPoint("TOPLEFT")
    bar:SetPoint("TOPRIGHT")
    bar:SetHeight(BAR_H)
    UI.scope = ns.CreateModernButton(bar, "", 112, 20)
    UI.scope:SetPoint("LEFT", bar, "LEFT", 0, 0)
    UI.scope:SetScript("OnClick", function(self)
        local note = Note()
        if note then Radio(self, SCOPES, function() return note.list.scope end, function(v) note.list.scope = v note.updated = time() end) end
    end)
    UI.reset = ns.CreateModernButton(bar, "", 128, 20)
    UI.reset:SetPoint("LEFT", UI.scope, "RIGHT", 6, 0)
    UI.reset:SetScript("OnClick", function(self)
        local note = Note()
        if note then PickReset(self, note) end
    end)
    UI.boardBtn = ns.CreateModernButton(bar, L["CHECK_ALTS"], 56, 20)
    UI.boardBtn:SetPoint("LEFT", UI.reset, "RIGHT", 6, 0)
    UI.boardBtn:SetScript("OnClick", function() View.ShowBoard(not UI.board) end)
    UI.ahBtn = ns.CreateModernButton(bar, L["CHECK_SEARCH_AH"], 96, 20)
    UI.ahBtn:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
    UI.ahBtn:SetScript("OnClick", function()
        local note = Note()
        if note then SearchNext(note) end
    end)

    local scroll = CreateFrame("ScrollFrame", nil, view)
    scroll:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -10, ADD_H + 4)
    UI.scroll = scroll
    UI.list = CreateFrame("Frame", nil, scroll)
    UI.list:SetSize(1, 1)
    scroll:SetScrollChild(UI.list)
    UI.bar = Utils.CreateMinimalScrollBar(scroll, view)

    local add = CreateFrame("EditBox", nil, view, "InputBoxTemplate")
    add:SetAutoFocus(false)
    add:SetHeight(20)
    add:SetPoint("BOTTOMLEFT", view, "BOTTOMLEFT", 6, 4)
    add:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -74, 4)
    ns.RegisterAddonFont(add)
    add.hint = Text(add, "GameFontDisableSmall")
    add.hint:SetPoint("LEFT", add, "LEFT", 2, 0)
    add.hint:SetText(L["CHECK_ADD_HINT"])
    add:SetScript("OnTextChanged", function(self) self.hint:SetShown((self:GetText() or "") == "") end)
    add:SetScript("OnEscapePressed", add.ClearFocus)
    add:SetScript("OnEnterPressed", function(self)
        local note, text = Note(), strtrim(self:GetText() or "")
        if note and text ~= "" then
            AddLine(note, CK.LineFromLink(text) or { text = text })
            self:SetText("")
        end
    end)
    UI.add = add
    UI.linkBtn = ns.CreateModernButton(view, L["CHECK_LINK_BTN"], 66, 22)
    UI.linkBtn:SetPoint("LEFT", add, "RIGHT", 6, 0)
    UI.linkBtn:SetScript("OnClick", function(self)
        local note = Note()
        if note then LinkMenu(self, note) end
    end)

    UI.empty = Text(view, "GameFontDisable")
    UI.empty:SetPoint("TOP", scroll, "TOP", 0, -30)
    UI.empty:SetWidth(260)
    UI.empty:SetJustifyH("CENTER")
    UI.empty:SetWordWrap(true)
    UI.empty:SetText(L["CHECK_EMPTY"])

    -- Shift-clicked items, quests and spells join the open list.
    Utils.HookInsertLink(function(link)
        local note = Note()
        if not (view:IsVisible() and note and CK.Is(note)) then return end
        if UI.add:HasFocus() then return end
        AddLine(note, CK.LineFromLink(link))
    end)

    view:SetScript("OnShow", function() View.Watch(true) end)
    view:SetScript("OnHide", function() View.Watch(false) end)
    return view
end

local EVENTS = { "BAG_UPDATE_DELAYED", "QUEST_LOG_UPDATE", "QUEST_TURNED_IN", "UPDATE_FACTION", "PLAYER_MONEY",
    "PLAYER_LEVEL_UP", "SKILL_LINES_CHANGED", "UPDATE_INSTANCE_INFO", "SPELL_UPDATE_COOLDOWN",
    "BAG_UPDATE_COOLDOWN", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }
local watcher = CreateFrame("Frame")
watcher:SetScript("OnEvent", function()
    if UI.queued then return end
    UI.queued = true
    Utils.SafeAfter(0.3, function()
        UI.queued = nil
        View.Refresh()
    end)
end)

-- The game's events refresh the list only while it shows.
function View.Watch(on)
    for _, e in ipairs(EVENTS) do
        if on then watcher:RegisterEvent(e) else watcher:UnregisterEvent(e) end
    end
end

-- Shown while the editor view is up and the open note is a checklist; the
-- text editor and its format toolbar give way to it.
function View.Refresh()
    local note = Note()
    local frame = NotesUI._notes and NotesUI._notes.frame
    local want = UI.allowed and CK.Is(note) and frame ~= nil
    if not want then
        if UI.view then UI.view:Hide() end
        -- A text note again: the editor comes back as the editor view had it.
        if UI.hidEditor and UI.allowed and frame then
            local toolbarShown = NotesUI._notes.toolbarShown == true
            if frame.editorScroll then frame.editorScroll:Show() end
            if frame.formatButton then frame.formatButton:Show() end
            if frame.toolbar then frame.toolbar:SetShown(toolbarShown) end
            if frame.charCounter then frame.charCounter:SetShown(not toolbarShown) end
        end
        UI.hidEditor = UI.hidEditor and not UI.allowed
        return
    end
    local view = EnsureView()
    if not view then return end
    UI.hidEditor = true
    if frame.editorScroll then frame.editorScroll:Hide() end
    if frame.toolbar then frame.toolbar:Hide() end
    if frame.charCounter then frame.charCounter:Hide() end
    if frame.formatButton then frame.formatButton:Hide() end
    view:Show()
    CK.Init(note)
    if CK.ApplyReset(note, time()) then note.updated = time() end
    local list = note.list
    UI.scope._label:SetText(OptionLabel(SCOPES, list.scope))
    UI.reset._label:SetText(sformat(L["CHECK_RESETS_FMT"], OptionLabel(RESETS, list.reset.every)))
    UI.ahBtn:SetShown(AuctionOpen())
    local board = UI.board and #list.lines > 0
    UI.boardBtn._label:SetText(board and L["CHECK_LIST"] or L["CHECK_ALTS"])
    local h = board and FillBoard(note) or FillList(note)
    UI.empty:SetShown(#list.lines == 0)
    UI.list:SetWidth(mmax(1, board and (NAME_W + #CK.Board(note) * CELL_W) or (UI.scroll:GetWidth() or 1)))
    UI.list:SetHeight(mmax(1, h))
    local viewH = UI.scroll:GetHeight() or 0
    if UI.bar then
        if h > viewH + 1 then
            UI.bar:Show()
            UI.bar:UpdateThumb(h, viewH)
        else
            UI.scroll:SetVerticalScroll(0)
            UI.bar:Hide()
        end
    end
end

function View.ShowBoard(on)
    UI.board = on and true or false
    View.Refresh()
end

-- The editor view showing or not (the note list replaces it).
function View.SetAllowed(on)
    UI.allowed = on and true or false
    View.Refresh()
end

-- Each character leaves what its linked lines read, for the board, and
-- schedules clear hand ticks even while no list is open.
function View.Sweep()
    local now = time()
    for _, note in ipairs(notesNS.AllNotes and notesNS.AllNotes() or {}) do
        if CK.Is(note) then
            CK.ApplyReset(note, now)
            for _, line in ipairs(note.list.lines) do
                if line.link then CK.LineState(note, line) end
            end
        end
    end
end

local sweeper = CreateFrame("Frame")
sweeper:RegisterEvent("PLAYER_LOGOUT")
sweeper:SetScript("OnEvent", View.Sweep)
Utils.SafeAfter(5, View.Sweep)
