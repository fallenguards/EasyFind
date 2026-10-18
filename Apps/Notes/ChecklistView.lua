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

-- GRIP_W: the margin left of the boxes the drag grip shows in, outside
-- the window's text edge.
local ROW_H, ROW_H2, CELL_W, NAME_W, GRIP_W, CHECK_W = 26, 36, 56, 150, 14, 22
local DONE_COLOR, OPEN_COLOR, FAINT_COLOR = { 0.45, 0.85, 0.45 }, { 1, 1, 1 }, { 0.65, 0.65, 0.65 }
local READY_TEX = "Interface\\RaidFrame\\ReadyCheck-Ready"
local MENU_CHECK_TEX = "Interface\\Buttons\\UI-CheckBox-Check"

-- Frames and state in one table (upvalue budget); open: the rows of the
-- lines not ticked, in order, the ones a drag can move among; editing:
-- the id of the line being typed in.
local UI = { rows = {}, cells = {}, heads = {}, open = {}, allowed = false, board = false }

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
    rows[#rows + 1] = { text = L["CHECK_RENAME"], onClick = function() View.Edit(line.id) end }
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
    -- The grip, six dots at the left, shows under the cursor: a drag
    -- from it carries the line to another place.
    local grip = CreateFrame("Button", nil, row)
    grip:SetSize(GRIP_W, 20)
    grip:SetPoint("LEFT", row, "LEFT", 0, 0)
    for col = -1, 1, 2 do
        for k = -1, 1 do
            local dot = grip:CreateTexture(nil, "ARTWORK")
            dot:SetSize(2, 2)
            dot:SetPoint("CENTER", grip, "CENTER", col * 2, k * 4)
            dot:SetColorTexture(FAINT_COLOR[1], FAINT_COLOR[2], FAINT_COLOR[3], 1)
        end
    end
    grip:RegisterForDrag("LeftButton")
    grip:SetScript("OnDragStart", function() View.DragStart(row) end)
    grip:SetScript("OnDragStop", function() View.DragStop() end)
    Utils.AttachDelayedTooltip(grip, "ANCHOR_LEFT", function() return L["GPS_TRIP_DRAG"] end)
    grip:Hide()
    row.grip = grip
    -- The X at the right, under the cursor too, drops the line.
    local remove = ns.CreateCloseX(row, 12)
    remove:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    remove:SetScript("OnClick", function()
        local note = Note()
        if note and row.line then CK.RemoveLine(note, row.line.id) Changed(note) end
    end)
    remove:Hide()
    row.remove = remove
    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(CHECK_W, CHECK_W)
    row.check:SetPoint("TOPLEFT", row, "TOPLEFT", GRIP_W, -2)
    if Utils.SetCheckboxTextures then Utils.SetCheckboxTextures(row.check, CHECK_W) end
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
    row.progress:SetPoint("TOPRIGHT", row.remove, "TOPLEFT", -4, -6)
    row.detail = Text(row, "GameFontDisableSmall")
    -- A click on the line types in it; the auction search for an item
    -- line is on its menu.
    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            RowMenu(self)
        elseif self.line and not UI.board then
            View.Edit(self.line.id)
        end
    end)
    UI.rows[i] = row
    return row
end

-- The line under the open ones: a click starts a new line there; Track
-- adds one the game ticks.
local function AddRow()
    local add = UI.addRow
    if add then return add end
    add = CreateFrame("Button", nil, UI.list)
    add:SetHeight(ROW_H)
    add:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
    add:GetHighlightTexture():SetAlpha(0.2)
    add.plus = Text(add, "GameFontDisable")
    add.plus:SetPoint("CENTER", add, "LEFT", GRIP_W + CHECK_W / 2, 0)
    add.plus:SetText("+")
    add.track = ns.CreateModernButton(add, L["CHECK_TRACK"], 60, 18)
    add.track:SetWidth(math.ceil(add.track._label:GetStringWidth()) + 20)
    add.track:SetPoint("RIGHT", add, "RIGHT", -2, 0)
    add.track:SetScript("OnClick", function(self)
        local note = Note()
        if note then LinkMenu(self, note) end
    end)
    add.label = Text(add, "GameFontDisable")
    add.label:SetPoint("LEFT", add, "LEFT", GRIP_W + CHECK_W + 4, 0)
    add.label:SetPoint("RIGHT", add.track, "LEFT", -6, 0)
    add.label:SetText(L["CHECK_ADD_ITEM"])
    add:SetScript("OnClick", function() View.AddNew() end)
    UI.addRow = add
    return add
end

local function FillRow(row, note, line, y)
    row.line = line
    row.name:SetAlpha(1)
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
    if UI.doneHead then UI.doneHead:Hide() end
    if UI.addRow then UI.addRow:Hide() end
    UI.empty:Hide()
    local chars = CK.Board(note)
    local lines = note.list.lines
    for i, charKey in ipairs(chars) do
        local head = Head(i)
        head:ClearAllPoints()
        head:SetPoint("TOPLEFT", UI.list, "TOPLEFT", GRIP_W + NAME_W + (i - 1) * CELL_W, 0)
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
        row:SetPoint("TOPLEFT", UI.list, "TOPLEFT", GRIP_W, -y)
        row:SetSize(NAME_W, ROW_H)
        row.check:Hide()
        row.icon:Hide()
        row.progress:SetText("")
        row.detail:Hide()
        row.name:ClearAllPoints()
        row.name:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.name:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.name:SetText(CK.LineName(line))
        row.name:SetTextColor(1, 1, 1, 1)
        row.name:SetAlpha(1)
        row:Show()
        for c, charKey in ipairs(chars) do
            n = n + 1
            local cell = Cell(n)
            local done, progress = CK.BoardCell(note, line, charKey)
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", UI.list, "TOPLEFT", GRIP_W + NAME_W + (c - 1) * CELL_W, -y)
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

-- The open lines first, in their order, then the add line; the ticked
-- ones under a Done heading at the bottom, as a checklist keeps them.
local function FillList(note)
    for _, cell in ipairs(UI.cells) do cell:Hide() end
    for _, head in ipairs(UI.heads) do head:Hide() end
    local y, n = 0, 0
    wipe(UI.open)
    local lines, done = note.list.lines, {}
    for _, line in ipairs(lines) do
        if CK.LineState(note, line) then
            done[#done + 1] = line
        else
            n = n + 1
            local row = UI.rows[n] or CreateRow(n)
            row.check:Show()
            y = y + FillRow(row, note, line, y)
            UI.open[#UI.open + 1] = row
        end
    end
    local add = AddRow()
    add:ClearAllPoints()
    add:SetPoint("TOPLEFT", UI.list, "TOPLEFT", 0, -y)
    add:SetPoint("RIGHT", UI.list, "RIGHT", 0, 0)
    add:Show()
    y = y + ROW_H
    UI.empty:SetShown(#lines == 0)
    if #lines == 0 then y = y + 8 + (UI.empty:GetStringHeight() or 0) end
    if UI.doneHead then UI.doneHead:Hide() end
    if #done > 0 then
        UI.doneHead = UI.doneHead or Text(UI.list, "GameFontNormalSmall")
        local head = UI.doneHead
        head:ClearAllPoints()
        head:SetPoint("TOPLEFT", UI.list, "TOPLEFT", GRIP_W + 4, -y - 6)
        head:SetText(sformat(L["CHECK_DONE_FMT"], #done))
        head:SetTextColor(FAINT_COLOR[1], FAINT_COLOR[2], FAINT_COLOR[3], 1)
        head:Show()
        y = y + 22
        for _, line in ipairs(done) do
            n = n + 1
            local row = UI.rows[n] or CreateRow(n)
            row.check:Show()
            y = y + FillRow(row, note, line, y)
        end
    end
    for i = n + 1, #UI.rows do UI.rows[i]:Hide() end
    return y
end

-- The view

-- Dragging a line's grip: the slot among the open rows the cursor is on,
-- the line drawn there, and on the drop the line moved to it.
function View.DropSlot()
    local _, cy = GetCursorPosition()
    cy = cy / UI.list:GetEffectiveScale()
    for j, r in ipairs(UI.open) do
        local top, bottom = r:GetTop(), r:GetBottom()
        if top and bottom and cy > (top + bottom) / 2 then return j end
    end
    return #UI.open + 1
end

function View.PlaceDropLine()
    local j, open = View.DropSlot(), UI.open
    local last = open[#open]
    if not last then return end
    UI.line:ClearAllPoints()
    if j > #open then
        UI.line:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -1)
        UI.line:SetPoint("RIGHT", last, "RIGHT", 0, 0)
    else
        UI.line:SetPoint("TOPLEFT", open[j], "TOPLEFT", 0, 1)
        UI.line:SetPoint("RIGHT", open[j], "RIGHT", 0, 0)
    end
end

function View.DragStart(row)
    if UI.board or row.done then return end
    if UI.editing then View.EndEdit() end
    UI.drag = row
    UI.line:Show()
end

function View.DragStop()
    local row = UI.drag
    UI.drag = nil
    UI.line:Hide()
    local note = Note()
    if not (row and note and row.line) then return end
    local j = View.DropSlot()
    local target = UI.open[j]
    if target == row or (j > #UI.open and UI.open[#UI.open] == row) then return end
    -- Out of the list, back in before the target's line, or last of the
    -- open lines when dropped under them all.
    local lines = note.list.lines
    local from
    for i = 1, #lines do if lines[i] == row.line then from = i end end
    if not from then return end
    table.remove(lines, from)
    local at = #lines + 1
    local after = target and target.line or (UI.open[#UI.open] and UI.open[#UI.open].line)
    for i = 1, #lines do
        if lines[i] == after then at = target and i or i + 1 break end
    end
    table.insert(lines, at, row.line)
    CK.SyncBody(note)
    Changed(note)
end

local function EnsureView()
    if UI.view then return UI.view end
    local frame = NotesUI._notes and NotesUI._notes.frame
    if not (frame and frame.editorScroll) then return nil end
    local view = CreateFrame("Frame", nil, frame)
    UI.view = view
    view:SetAllPoints(frame.editorScroll)
    view:Hide()

    -- The rows start GRIP_W left of the text edge: the boxes sit on it,
    -- the grip in the margin.
    local scroll = CreateFrame("ScrollFrame", nil, view)
    scroll:SetPoint("TOPLEFT", view, "TOPLEFT", -GRIP_W, 0)
    scroll:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -12, 2)
    UI.scroll = scroll
    UI.list = CreateFrame("Frame", nil, scroll)
    UI.list:SetSize(1, 1)
    scroll:SetScrollChild(UI.list)
    UI.bar = Utils.CreateMinimalScrollBar(scroll, view)
    -- In the gutter right of the rows, never over them.
    UI.bar:ClearAllPoints()
    UI.bar:SetPoint("TOPRIGHT", view, "TOPRIGHT", -2, -2)
    UI.bar:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -2, 4)
    UI.line = UI.list:CreateTexture(nil, "OVERLAY")
    UI.line:SetHeight(2)
    UI.line:SetColorTexture(1, 0.82, 0, 0.9)
    UI.line:Hide()
    -- The grip and the X show on the row under the cursor; while a grip
    -- is dragged, the line marks where its row would land.
    view:SetScript("OnUpdate", function(_, dt)
        UI.since = (UI.since or 0) + dt
        if UI.since < 0.05 and not UI.drag then return end
        UI.since = 0
        for _, row in ipairs(UI.rows) do
            if row:IsShown() then
                local over = not UI.board and (UI.drag == row or row:IsMouseOver())
                row.grip:SetShown(over and not row.done)
                row.remove:SetShown(over)
            end
        end
        if UI.drag then View.PlaceDropLine() end
    end)

    -- An empty list's hint, under its add line.
    UI.empty = Text(UI.list, "GameFontDisable")
    UI.empty:SetPoint("TOPLEFT", AddRow(), "BOTTOMLEFT", GRIP_W, -8)
    UI.empty:SetPoint("TOPRIGHT", AddRow(), "BOTTOMRIGHT", 0, -8)
    UI.empty:SetWordWrap(true)
    UI.empty:SetText(L["CHECK_EMPTY"])

    -- Shift-clicked items, quests and spells join the open list; into the
    -- line being typed, where one is.
    Utils.HookInsertLink(function(link)
        local note = Note()
        if not (view:IsVisible() and note and CK.Is(note)) then return end
        if UI.edit and UI.edit:HasFocus() then
            UI.edit:Insert(link)
            return
        end
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
    -- A line left empty goes, unless it is the one being typed.
    for i = #list.lines, 1, -1 do
        local line = list.lines[i]
        if not line.link and (line.text or "") == "" and line.id ~= UI.editing then CK.RemoveLine(note, line.id) end
    end
    local board = UI.board and #list.lines > 0
    if board and UI.editing then View.EndEdit() return end
    local h = board and FillBoard(note) or FillList(note)
    UI.list:SetWidth(mmax(1, board and (GRIP_W + NAME_W + #CK.Board(note) * CELL_W) or (UI.scroll:GetWidth() or 1)))
    View.PlaceEdit()
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

-- Typing in place --------------------------------------------------------------

local function LineByID(note, id)
    for _, line in ipairs(note.list.lines) do
        if line.id == id then return line end
    end
end

-- The open line before or after line id in the list as shown.
local function Neighbor(id, step)
    for j, row in ipairs(UI.open) do
        if row.line and row.line.id == id then
            local other = UI.open[j + step]
            return other and other.line and other.line.id
        end
    end
end

-- One box, laid over the words of the line being typed.
local function EnsureEdit()
    if UI.edit then return UI.edit end
    local box = CreateFrame("EditBox", nil, UI.list)
    box:SetAutoFocus(false)
    box:SetFontObject("GameFontHighlight")
    ns.RegisterAddonFont(box)
    box:SetMaxLetters(120)
    box:SetHeight(ROW_H - 6)
    box:EnableMouse(true)
    box:SetScript("OnEnterPressed", function() View.EndEdit("next") end)
    box:SetScript("OnEscapePressed", function() View.EndEdit() end)
    box:SetScript("OnEditFocusLost", function() View.EndEdit() end)
    box:SetScript("OnKeyDown", function(self, key)
        if key == "BACKSPACE" and (self:GetText() or "") == "" then View.EndEdit("back")
        elseif key == "UP" then View.EndEdit("up")
        elseif key == "DOWN" then View.EndEdit("down") end
    end)
    box:Hide()
    UI.edit = box
    return box
end

-- The box onto the row of the line being typed, its words under it hidden.
function View.PlaceEdit()
    local id = UI.editing
    if not id then
        if UI.edit then UI.edit:Hide() end
        return
    end
    for _, row in ipairs(UI.rows) do
        if row:IsShown() and row.line and row.line.id == id then
            local box = EnsureEdit()
            box:ClearAllPoints()
            box:SetPoint("LEFT", row.name, "LEFT", 0, 0)
            box:SetPoint("RIGHT", row.progress, "LEFT", -6, 0)
            row.name:SetAlpha(0)
            if not box:IsShown() then
                local text = row.line.text or CK.LineName(row.line)
                box:SetText(text)
                box:Show()
                box:SetFocus()
                box:SetCursorPosition(#text)
            end
            return
        end
    end
    UI.editing = nil
    if UI.edit then UI.edit:Hide() end
end

-- Types in line id where it stands.
function View.Edit(id)
    if UI.board then return end
    if UI.editing and UI.editing ~= id then View.EndEdit() end
    UI.editing = id
    View.Refresh()
end

-- A new line at the end of the open ones, typed in.
function View.AddNew()
    local note = Note()
    if not (note and UI.view and UI.view:IsShown()) or UI.board then return end
    if UI.editing then View.EndEdit() end
    UI.editing = CK.AddLine(note, { text = "" }).id
    Changed(note)
end

-- The typed words kept (a link typed in makes it a line the game ticks;
-- emptied, a plain line goes); then on to the line move names: "next" a
-- new line under it, "back" the one above with this one gone, "up" or
-- "down" the one above or below.
function View.EndEdit(move)
    local id = UI.editing
    if not id then return end
    UI.editing = nil
    local box = UI.edit
    local text = strtrim(box:GetText() or "")
    box:Hide()
    box:ClearFocus()
    local note = Note()
    local line = note and LineByID(note, id)
    if not line then View.Refresh() return end
    local prev, nextID = Neighbor(id, -1), Neighbor(id, 1)
    local from = CK.LineFromLink(text)
    if from then
        line.text = nil
        for k, v in pairs(from) do line[k] = v end
    elseif text == "" and not line.link then
        CK.RemoveLine(note, id)
        line = nil
    elseif text ~= CK.LineName(line) or line.text then
        line.text = text ~= "" and text or nil
    end
    CK.SyncBody(note)
    if move == "next" and line then
        UI.editing = CK.InsertLine(note, { text = "" }, line.id).id
    elseif move == "back" or move == "up" then
        UI.editing = prev
    elseif move == "down" then
        UI.editing = nextID
    end
    Changed(note)
end

-- The list's own settings, for the notes window's menu.
function View.MenuRows(note, anchor)
    local list = CK.Init(note)
    local scopes = {}
    for _, o in ipairs(SCOPES) do
        scopes[#scopes + 1] = { text = o.label, icon = (list.scope or "account") == o.value and MENU_CHECK_TEX or nil,
            onClick = function() list.scope = o.value Changed(note) end }
    end
    return {
        { text = sformat(L["CHECK_SCOPE_FMT"], OptionLabel(SCOPES, list.scope)), submenu = scopes },
        { text = L["CHECK_RESET_ROW"], onClick = function() PickReset(anchor, note) end },
        { text = L["CHECK_BOARD"], icon = UI.board and MENU_CHECK_TEX or nil, iconSide = "right", onClick = function() View.ShowBoard(not UI.board) end },
        { text = L["CHECK_SEARCH_AH"], disabled = not AuctionOpen(), onClick = function() SearchNext(note) end },
    }
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
