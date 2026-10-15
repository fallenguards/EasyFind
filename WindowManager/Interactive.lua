local _, ns = ...

-- Interactive snapping, modeled on the Windows 11 behaviors:
--  - Edge snap: dragging a window (unlock mode) against the left/right/bottom
--    edge or into a corner shows a translucent preview of the target rect;
--    releasing snaps the window there.
--  - Snap layouts: holding a drag against the top edge shows a centered strip
--    of layout presets; releasing over a zone cell snaps into that zone.
--  - Task view: an overlay listing every open registered window with a row of
--    zone buttons; hovering previews the zone on screen, clicking snaps that
--    window. The searchable "Task View" command toggles it.
-- All zones resolve to SnapMath spec keys, so previews, drops, cycling, and
-- persistence share one geometry owner.

local SnapAssist = {}
ns.WindowSnapAssist = SnapAssist

local Utils = ns.Utils
local L = ns.L
local sformat = string.format
local SnapMath = ns.SnapMath

local UIParent = UIParent
local CreateFrame = CreateFrame
local GetCursorPosition = GetCursorPosition
local IsAltKeyDown = IsAltKeyDown
local InCombatLockdown = InCombatLockdown
local SetOverrideBindingClick = SetOverrideBindingClick
local ClearOverrideBindings = ClearOverrideBindings

local EDGE_PX = 24
local CORNER_PX = 96
local TOP_BAR_TRIGGER = 48
local TOP_BAR_STICKY = 150

local dragFrame
local pendingSpec
-- Tooltip gate for the restore drop-cell: OnEnter never fires while the
-- dragged window captures the mouse, so hover time accrues in the tick.
local restoreTipShown
local restoreHoverTime = 0

local function WorkArea()
    return UIParent:GetWidth(), UIParent:GetHeight()
end

local function CurrentGap()
    local gap = EasyFind and EasyFind.db and EasyFind.db.windowGap
    if type(gap) ~= "number" or gap < 0 then return ns.WINDOW_GAP_DEFAULT end
    return gap
end

local scratchRect = {}

-- Translucent zone preview, accent-tinted so it reads as "where this lands".
local previewFrame

local function EnsurePreview()
    if previewFrame then return previewFrame end
    previewFrame = CreateFrame("Frame", nil, UIParent)
    previewFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    previewFrame:SetFrameLevel(900)
    previewFrame.fill = previewFrame:CreateTexture(nil, "BACKGROUND")
    previewFrame.fill:SetAllPoints()
    previewFrame.edges = {}
    for i = 1, 4 do
        previewFrame.edges[i] = previewFrame:CreateTexture(nil, "BORDER")
    end
    previewFrame.edges[1]:SetPoint("TOPLEFT")
    previewFrame.edges[1]:SetPoint("TOPRIGHT")
    previewFrame.edges[1]:SetHeight(2)
    previewFrame.edges[2]:SetPoint("BOTTOMLEFT")
    previewFrame.edges[2]:SetPoint("BOTTOMRIGHT")
    previewFrame.edges[2]:SetHeight(2)
    previewFrame.edges[3]:SetPoint("TOPLEFT")
    previewFrame.edges[3]:SetPoint("BOTTOMLEFT")
    previewFrame.edges[3]:SetWidth(2)
    previewFrame.edges[4]:SetPoint("TOPRIGHT")
    previewFrame.edges[4]:SetPoint("BOTTOMRIGHT")
    previewFrame.edges[4]:SetWidth(2)
    previewFrame:Hide()
    return previewFrame
end

local function PreviewColors()
    local pal = ns.ACTIVE_UI_PALETTE
    local accent = pal and pal.accent or { 0.35, 0.6, 0.9 }
    return accent[1], accent[2], accent[3]
end

local function ShowPreviewForSpec(specKey)
    local w, h = WorkArea()
    local rect = SnapMath:ComputeRect(specKey, w, h, CurrentGap(), scratchRect)
    if not rect then return end
    local preview = EnsurePreview()
    local r, g, b = PreviewColors()
    preview.fill:SetColorTexture(r, g, b, 0.18)
    for i = 1, 4 do preview.edges[i]:SetColorTexture(r, g, b, 0.8) end
    preview:ClearAllPoints()
    preview:SetPoint("TOPLEFT", UIParent, "TOPLEFT", rect.x, rect.y)
    preview:SetSize(rect.w, rect.h)
    preview:Show()
end

local function ShowPreviewForFrame(frame)
    if not (frame and frame.GetLeft) then return end
    local left, bottom = frame:GetLeft(), frame:GetBottom()
    local fw, fh = frame:GetWidth(), frame:GetHeight()
    if not (left and bottom and fw and fh) then return end
    local scale = (frame:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
    local _, uiH = WorkArea()
    local preview = EnsurePreview()
    local r, g, b = PreviewColors()
    preview.fill:SetColorTexture(r, g, b, 0.18)
    for i = 1, 4 do preview.edges[i]:SetColorTexture(r, g, b, 0.8) end
    preview:ClearAllPoints()
    preview:SetPoint("TOPLEFT", UIParent, "TOPLEFT",
        left * scale, -(uiH - (bottom + fh) * scale))
    preview:SetSize(fw * scale, fh * scale)
    preview:Show()
end

local function HidePreview()
    if previewFrame then previewFrame:Hide() end
end

-- Snap-layouts strip: preset cells whose sub-zones each carry a spec key.
-- Dropped-on zone wins; zones hit-test geometrically because the mouse is
-- captured by the dragged window the whole time.
local BAR_PRESETS = {
    { { "left-half", 0, 0, 0.5, 1 }, { "right-half", 0.5, 0, 0.5, 1 } },
    { { "left-two-thirds", 0, 0, 2 / 3, 1 }, { "right-third", 2 / 3, 0, 1 / 3, 1 } },
    { { "left-third", 0, 0, 1 / 3, 1 }, { "center-third", 1 / 3, 0, 1 / 3, 1 },
      { "right-third", 2 / 3, 0, 1 / 3, 1 } },
    { { "top-left-quarter", 0, 0, 0.5, 0.5 }, { "top-right-quarter", 0.5, 0, 0.5, 0.5 },
      { "bottom-left-quarter", 0, 0.5, 0.5, 0.5 }, { "bottom-right-quarter", 0.5, 0.5, 0.5, 0.5 } },
}

local CELL_W, CELL_H, CELL_GAP, CELL_PAD = 84, 56, 10, 12
-- The restore drop-cell sits apart from the preset cells: a square bearing
-- the red not-ready mark; dropping a window there resets it to default.
local RESTORE_CELL_GAP = 22
local RESTORE_ICON = 30
local RESTORE_ICON_TEX = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local layoutBar

local function EnsureLayoutBar()
    if layoutBar then return layoutBar end
    layoutBar = CreateFrame("Frame", "EasyFindSnapLayoutBar", UIParent, "BackdropTemplate")
    layoutBar:SetFrameStrata("FULLSCREEN_DIALOG")
    layoutBar:SetFrameLevel(920)
    ns.StyleMenuPanel(layoutBar)
    local totalW = #BAR_PRESETS * CELL_W + (#BAR_PRESETS - 1) * CELL_GAP
        + RESTORE_CELL_GAP + CELL_H + CELL_PAD * 2
    layoutBar:SetSize(totalW, CELL_H + CELL_PAD * 2)
    layoutBar:SetPoint("TOP", UIParent, "TOP", 0, -8)
    layoutBar.zones = {}
    local x = CELL_PAD
    for p = 1, #BAR_PRESETS do
        local preset = BAR_PRESETS[p]
        local cell = CreateFrame("Frame", nil, layoutBar)
        cell:SetSize(CELL_W, CELL_H)
        cell:SetPoint("TOPLEFT", x, -CELL_PAD)
        for z = 1, #preset do
            local def = preset[z]
            local zone = CreateFrame("Frame", nil, cell)
            zone:SetPoint("TOPLEFT", cell, "TOPLEFT",
                def[2] * CELL_W + 1, -(def[3] * CELL_H) - 1)
            zone:SetSize(def[4] * CELL_W - 2, def[5] * CELL_H - 2)
            zone.fill = zone:CreateTexture(nil, "ARTWORK")
            zone.fill:SetAllPoints()
            zone.specKey = def[1]
            layoutBar.zones[#layoutBar.zones + 1] = zone
        end
        x = x + CELL_W + CELL_GAP
    end

    local restoreZone = CreateFrame("Frame", nil, layoutBar)
    restoreZone:SetSize(CELL_H, CELL_H)
    restoreZone:SetPoint("TOPLEFT", x - CELL_GAP + RESTORE_CELL_GAP, -CELL_PAD)
    restoreZone.icon = restoreZone:CreateTexture(nil, "ARTWORK")
    restoreZone.icon:SetSize(RESTORE_ICON, RESTORE_ICON)
    restoreZone.icon:SetPoint("CENTER")
    restoreZone.icon:SetTexture(RESTORE_ICON_TEX)
    restoreZone.isRestore = true
    restoreZone.specKey = "restore"
    layoutBar.zones[#layoutBar.zones + 1] = restoreZone
    layoutBar.restoreZone = restoreZone

    layoutBar:Hide()
    return layoutBar
end

local function PaintLayoutZones(hoverZone)
    if not layoutBar then return end
    local r, g, b = PreviewColors()
    for i = 1, #layoutBar.zones do
        local zone = layoutBar.zones[i]
        local hover = zone == hoverZone
        if zone.isRestore then
            zone.icon:SetAlpha(hover and 1 or 0.65)
        elseif hover then
            zone.fill:SetColorTexture(r, g, b, 0.85)
        else
            zone.fill:SetColorTexture(r, g, b, 0.25)
        end
    end
end

local function HideLayoutBar()
    if layoutBar then layoutBar:Hide() end
end

-- Drag watcher: classifies the cursor each frame into a zone (or a layout
-- bar cell) and keeps the preview in sync. Runs only while a drag is live.
local watcher

local function CursorUI()
    local cx, cy = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale() or 1
    return cx / scale, cy / scale
end

local function DragTick(_, elapsed)
    if not dragFrame then return end
    local w, h = WorkArea()
    local cx, cy = CursorUI()
    local spec

    local nearTop = cy > h - TOP_BAR_TRIGGER
    local barShown = layoutBar and layoutBar:IsShown()
    if nearTop or (barShown and cy > h - TOP_BAR_STICKY) then
        local bar = EnsureLayoutBar()
        bar:Show()
        local hoverZone
        for i = 1, #bar.zones do
            local zone = bar.zones[i]
            if zone:IsMouseOver() then hoverZone = zone break end
        end
        PaintLayoutZones(hoverZone)
        if hoverZone then
            spec = hoverZone.specKey
        elseif nearTop and not bar:IsMouseOver() then
            spec = "maximize"
        end
    else
        HideLayoutBar()
        local nearLeft = cx < EDGE_PX
        local nearRight = cx > w - EDGE_PX
        local nearBottom = cy < EDGE_PX
        local inTopBand = cy > h - CORNER_PX
        local inBottomBand = cy < CORNER_PX
        if nearLeft and inTopBand then spec = "top-left-quarter"
        elseif nearRight and inTopBand then spec = "top-right-quarter"
        elseif nearLeft and inBottomBand then spec = "bottom-left-quarter"
        elseif nearRight and inBottomBand then spec = "bottom-right-quarter"
        elseif nearLeft then spec = "left-half"
        elseif nearRight then spec = "right-half"
        elseif nearBottom then spec = "bottom-half"
        end
    end

    pendingSpec = spec
    if spec == "restore" then
        HidePreview()
        restoreHoverTime = restoreHoverTime + (elapsed or 0)
        if not restoreTipShown and restoreHoverTime >= (ns.TOOLTIP_HOVER_DELAY or 0.4) then
            restoreTipShown = true
            if layoutBar then
                ns.ShowHintTooltip(layoutBar.restoreZone, "ANCHOR_BOTTOM", nil,
                    L["WINDOW_RESTORE_DROP_TIP"])
            end
        end
    else
        if restoreTipShown then ns.HideHintTooltip() end
        restoreTipShown = nil
        restoreHoverTime = 0
        if spec then
            ShowPreviewForSpec(spec)
        else
            HidePreview()
        end
    end
end

function SnapAssist:OnDragStart(_, frame)
    dragFrame = frame
    pendingSpec = nil
    if not watcher then
        watcher = CreateFrame("Frame")
    end
    Utils.SafeOnUpdate(watcher, DragTick)
end

-- Returns the spec key to apply ("restore" = reset to default), or nil to
-- keep the free-drag position.
function SnapAssist:OnDragEnd()
    local spec = pendingSpec
    dragFrame, pendingSpec = nil, nil
    if watcher then Utils.SafeOnUpdate(watcher, nil) end
    if restoreTipShown then ns.HideHintTooltip() end
    restoreTipShown = nil
    restoreHoverTime = 0
    HidePreview()
    HideLayoutBar()
    return spec
end

-- Task view: every open registered window as a row with zone buttons.
-- Hovering a button previews the zone; hovering the row's name previews the
-- window's current position; clicking a button snaps that window.
local TASK_ZONES = {
    "left-half", "right-half", "top-left-quarter", "top-right-quarter",
    "bottom-left-quarter", "bottom-right-quarter", "center", "maximize", "restore",
}
local TASK_BTN = 24
local TASK_ROW_H = 34
local TASK_W = 380
-- The panel grows downward from its anchor, so a tall list (nine windows is
-- ~350 units) must start near the screen top or it reads as centered.
local TASK_TOP_INSET = 40
local TASK_PAD = 14
-- The selection pill hugs the panel edges a little wider than the rows.
local TASK_PILL_INSET = 8
local TASK_FOOT_H = 26
local TASK_LAYOUT_ROW_H = 22
local CHECK_TEX = "Interface\\Buttons\\UI-CheckBox-Check"
local TASK_SEL_COLOR = { 0, 0, 0, 0.14 }
-- Checkbox metrics copied from the filter flyout's checkbox rows so the two
-- views of the same setting look identical.
local CHECK_BOX_INSET = 5
local CHECK_BOX_W = 12
local CHECK_LABEL_GAP = 6

local taskView
local taskBindOwner
local TaskViewWatchTick
local SyncTaskMultiCheck

-- Alt+1..9 press the selected row's zone buttons (same convention as the
-- search results' Alt+number row shortcuts). Bindings target named proxy
-- buttons armed only while the task view is shown.
-- The pill spans the panel rather than the row so it clears the row's text
-- and icon lane on both sides, matching the search results' row pill.
local function TaskRowWashLayout(hl, row)
    hl:SetPoint("TOP", row, "TOP", 0, 0)
    hl:SetPoint("BOTTOM", row, "BOTTOM", 0, 0)
    local view = row:GetParent()
    hl:SetPoint("LEFT", view, "LEFT", TASK_PILL_INSET, 0)
    hl:SetPoint("RIGHT", view, "RIGHT", -TASK_PILL_INSET, 0)
end

local function SelectTaskRow(index)
    if not taskView then return end
    taskView.selectedIndex = index
    local r, g, b = PreviewColors()
    TASK_SEL_COLOR[1], TASK_SEL_COLOR[2], TASK_SEL_COLOR[3] = r, g, b
    local altDown = IsAltKeyDown()
    for i = 1, #taskView.rows do
        local row = taskView.rows[i]
        local selected = row:IsShown() and i == taskView.selectedIndex
        Utils.UpdateRoundedRowWash(row, selected, TaskRowWashLayout, TASK_SEL_COLOR)
        for z = 1, #row.zones do
            row.zones[z].num:SetShown(selected and altDown)
        end
    end
end

local function TaskZoneClicked(self)
    local mgr = ns.WindowManager
    if not (mgr and self._entry) then return end
    if self._rowIndex then SelectTaskRow(self._rowIndex) end
    if self._specKey == "restore" then
        mgr:Restore(self._entry)
        HidePreview()
        return
    end
    mgr:ApplyCommand(self._specKey, self._entry)
    -- The cursor has not left the button, so its preview stays up: hiding it
    -- here made the overlay blink out under a stationary mouse. Repeat clicks
    -- cycle the zone, so preview what actually landed, not what was clicked.
    local _, _, _, _, appliedKey = mgr:GetAppliedZone(self._entry.name)
    ShowPreviewForSpec(appliedKey or self._specKey)
end

local function TaskShortcutClicked(self)
    if not (taskView and taskView:IsShown()) then return end
    local row = taskView.rows[taskView.selectedIndex or 1]
    if not (row and row:IsShown()) then return end
    local zone = row.zones[self._zoneIndex]
    if zone then TaskZoneClicked(zone) end
end

local function ArmTaskBindings()
    if InCombatLockdown() or not taskBindOwner then return end
    for i = 1, 9 do
        local name = "EasyFindTaskViewKey" .. i
        SetOverrideBindingClick(taskBindOwner, true, "ALT-" .. i, name, "LeftButton")
        SetOverrideBindingClick(taskBindOwner, true, "ALT-NUMPAD" .. i, name, "LeftButton")
    end
end

local function ClearTaskBindings()
    if InCombatLockdown() or not taskBindOwner then return end
    ClearOverrideBindings(taskBindOwner)
end

local function TaskZoneEnter(self)
    if self._specKey ~= "restore" then ShowPreviewForSpec(self._specKey) end
    self.icon:SetVertexColor(1, 1, 1, 1)
end

local function TaskZoneLeave(self)
    HidePreview()
    self.icon:SetVertexColor(0.84, 0.84, 0.86, 1)
end

local function EnsureTaskView()
    if taskView then return taskView end
    taskView = CreateFrame("Frame", "EasyFindTaskView", UIParent, "BackdropTemplate")
    taskView:SetFrameStrata("FULLSCREEN_DIALOG")
    taskView:SetFrameLevel(940)
    taskView:SetPoint("TOP", UIParent, "TOP", 0, -TASK_TOP_INSET)
    ns.StyleMenuPanel(taskView)
    taskView:EnableMouse(true)
    taskView:SetMovable(true)
    taskView:SetClampedToScreen(true)
    taskView:RegisterForDrag("LeftButton")
    taskView:SetScript("OnDragStart", taskView.StartMoving)
    taskView:SetScript("OnDragStop", taskView.StopMovingOrSizing)
    taskView.title = taskView:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    taskView.title:SetPoint("TOPLEFT", TASK_PAD, -12)
    taskView.title:SetText(L["WINDOW_CMD_TASKVIEW"])
    taskView.hint = taskView:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    taskView.hint:SetPoint("LEFT", taskView.title, "RIGHT", 6, 0)
    taskView.hint:SetText(L["WINDOW_TASKVIEW_HINT"])
    taskView.empty = taskView:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    taskView.empty:SetPoint("TOPLEFT", TASK_PAD, -36)
    taskView.empty:SetText(L["WINDOW_NO_TARGET"])
    taskView.rows = {}
    taskView.selectedIndex = 1
    local closeX = ns.CreateCloseX(taskView, 14)
    closeX:SetPoint("TOPRIGHT", -10, -10)
    closeX:SetScript("OnClick", function() taskView:Hide() end)
    -- Second view of the windows flyout's multi-panel toggle: one db key, so
    -- the two stay in step (this one re-reads the key on the watcher tick).
    local multiCheck = CreateFrame("Button", nil, taskView)
    multiCheck:SetHeight(TASK_FOOT_H - 4)
    multiCheck:SetPoint("BOTTOMLEFT", TASK_PAD - CHECK_BOX_INSET, 8)
    local checkBox = multiCheck:CreateTexture(nil, "ARTWORK")
    checkBox:SetAtlas("common-dropdown-ticksquare")
    checkBox:SetSize(CHECK_BOX_W, CHECK_BOX_W)
    checkBox:SetPoint("LEFT", CHECK_BOX_INSET, 0)
    multiCheck.tick = multiCheck:CreateTexture(nil, "OVERLAY")
    multiCheck.tick:SetAtlas("common-dropdown-icon-checkmark-yellow")
    multiCheck.tick:SetSize(CHECK_BOX_W + 2, CHECK_BOX_W + 2)
    multiCheck.tick:SetPoint("LEFT", CHECK_BOX_INSET - 1, 0)
    multiCheck.tick:Hide()
    local checkLabel = multiCheck:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    checkLabel:SetPoint("LEFT", checkBox, "RIGHT", CHECK_LABEL_GAP, 0)
    checkLabel:SetText(L["WINDOW_MULTI_TOGGLE"])
    multiCheck:SetWidth(CHECK_BOX_INSET + CHECK_BOX_W + CHECK_LABEL_GAP
        + (checkLabel:GetStringWidth() or 0) + CHECK_LABEL_GAP)
    multiCheck:SetScript("OnClick", function(self)
        local db = EasyFind and EasyFind.db
        if not db then return end
        db.windowMultiPanels = not db.windowMultiPanels
        self.tick:SetShown(db.windowMultiPanels)
        if ns.WindowManager then ns.WindowManager:RefreshMultiPanels() end
    end)
    Utils.AttachDelayedTooltip(multiCheck, "ANCHOR_RIGHT", function()
        return L["WINDOW_MULTI_TOGGLE"], L["WINDOW_MULTI_TIP"]
    end)
    taskView.multiCheck = multiCheck
    taskBindOwner = CreateFrame("Frame", nil, taskView)
    for i = 1, 9 do
        local proxy = CreateFrame("Button", "EasyFindTaskViewKey" .. i, taskBindOwner)
        proxy:SetSize(1, 1)
        proxy:SetPoint("TOPLEFT")
        proxy:EnableMouse(false)
        proxy._zoneIndex = i
        proxy:SetScript("OnClick", TaskShortcutClicked)
    end
    Utils.AttachEscClose(taskView)
    Utils.AttachOutsideClickClose(taskView)
    -- Alt held/released toggles the digit hints on the selected row.
    taskView:SetScript("OnEvent", function(_, _, key)
        if key == "LALT" or key == "RALT" then
            SelectTaskRow(taskView.selectedIndex)
        end
    end)
    taskView:HookScript("OnShow", function()
        taskView:RegisterEvent("MODIFIER_STATE_CHANGED")
        ArmTaskBindings()
        Utils.SafeOnUpdate(taskView, TaskViewWatchTick)
    end)
    taskView:HookScript("OnHide", function()
        taskView:UnregisterEvent("MODIFIER_STATE_CHANGED")
        ClearTaskBindings()
        Utils.SafeOnUpdate(taskView, nil)
        HidePreview()
    end)
    taskView:Hide()
    return taskView
end

-- The flyout owns the same db key; re-read it so a change made there while
-- the task view is open shows up here (and vice versa).
function SyncTaskMultiCheck()
    if not (taskView and taskView.multiCheck) then return end
    local db = EasyFind and EasyFind.db
    taskView.multiCheck.tick:SetShown(db and db.windowMultiPanels and true or false)
end

local function EnsureTaskRow(index)
    local view = EnsureTaskView()
    local row = view.rows[index]
    if row then return row end
    row = CreateFrame("Frame", nil, view)
    row:SetSize(TASK_W - TASK_PAD * 2, TASK_ROW_H)
    row._index = index
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", 0, 0)
    row.name:SetPoint("RIGHT", row, "RIGHT", -(#TASK_ZONES * (TASK_BTN + 2) + 6), 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if self._frame then ShowPreviewForFrame(self._frame) end
    end)
    row:SetScript("OnLeave", HidePreview)
    row:SetScript("OnMouseDown", function(self)
        SelectTaskRow(self._index)
    end)
    row.zones = {}
    local icons = ns.WindowCommands and ns.WindowCommands.ICON_DEFS or {}
    for z = 1, #TASK_ZONES do
        local specKey = TASK_ZONES[z]
        local zoneBtn = CreateFrame("Button", nil, row)
        zoneBtn:SetSize(TASK_BTN, TASK_BTN)
        zoneBtn:SetPoint("RIGHT", row, "RIGHT",
            -((#TASK_ZONES - z) * (TASK_BTN + 2)), 0)
        zoneBtn.icon = zoneBtn:CreateTexture(nil, "ARTWORK")
        zoneBtn.icon:SetAllPoints()
        local def = icons[specKey]
        if def then
            zoneBtn.icon:SetTexture(def.tex)
            zoneBtn.icon:SetTexCoord(def.coords[1], def.coords[2], def.coords[3], def.coords[4])
        end
        zoneBtn.icon:SetVertexColor(0.84, 0.84, 0.86, 1)
        zoneBtn.num = zoneBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        zoneBtn.num:SetPoint("BOTTOMRIGHT", 2, -2)
        zoneBtn.num:SetText(tostring(z))
        zoneBtn.num:Hide()
        zoneBtn._specKey = specKey
        zoneBtn._rowIndex = index
        zoneBtn:SetScript("OnClick", TaskZoneClicked)
        zoneBtn:SetScript("OnEnter", TaskZoneEnter)
        zoneBtn:SetScript("OnLeave", TaskZoneLeave)
        row.zones[z] = zoneBtn
    end
    view.rows[index] = row
    return row
end

-- Display name for a task view row: static entries carry a labelKey;
-- dynamically registered panels fall back to their own (already localized)
-- title text, then the frame name.
local function PanelLabel(entry, frame)
    if entry.labelKey then return L[entry.labelKey] end
    local title = frame and (frame.TitleContainer and frame.TitleContainer.TitleText
        or frame.TitleText)
    local text = title and title.GetText and title:GetText()
    if text and text ~= "" then return text end
    return entry.name
end

-- Signature of the currently open registered windows; the watcher below
-- re-renders the task view when it changes (a panel opened or closed while
-- the overlay is up).
local function TaskWindowSignature()
    local registry = ns.WindowRegistry
    local sig = ""
    if registry then
        registry:ForEach(function(entry)
            local frame = registry:GetFrame(entry)
            if frame and frame:IsShown() and not entry.own then
                sig = sig .. entry.name .. ";"
            end
        end)
    end
    return sig
end

local taskWatchElapsed = 0
function TaskViewWatchTick(_, elapsed)
    taskWatchElapsed = taskWatchElapsed + (elapsed or 0)
    if taskWatchElapsed < 0.2 then return end
    taskWatchElapsed = 0
    if not (taskView and taskView:IsShown()) then return end
    if TaskWindowSignature() ~= taskView._windowSig then
        SnapAssist:RefreshTaskView()
        return
    end
    SyncTaskMultiCheck()
end

local function EnsureLayoutRow(view, index)
    view.layoutRows = view.layoutRows or {}
    local row = view.layoutRows[index]
    if row then return row end
    -- A secure button: its click opens the layout's panels through their
    -- micro buttons in the client's own execution, the snaps follow after.
    row = CreateFrame("Button", nil, view, "SecureActionButtonTemplate")
    row:SetSize(TASK_W - TASK_PAD * 2, TASK_LAYOUT_ROW_H)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetAttribute("type", "macro")
    row:SetAttribute("type2", "ignore")
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", TASK_PILL_INSET, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.sub:SetPoint("RIGHT", row, "RIGHT", -TASK_PILL_INSET, 0)
    row.sub:SetJustifyH("RIGHT")
    row.name:SetPoint("RIGHT", row.sub, "LEFT", -8, 0)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)
    -- A layout row opens and places its windows; right-click holds its
    -- standing and its removal. The last row saves the screen as it stands.
    row:SetScript("PostClick", function(self, button)
        local Layouts = ns.WindowLayouts
        if not Layouts then return end
        if not self.layoutID then
            if button == "LeftButton" then Layouts:PromptSave() end
            return
        end
        if button == "RightButton" then
            local layout = Layouts:Get(self.layoutID)
            if not layout then return end
            Utils.ShowCursorMenu("EasyFindTaskLayoutMenu", {
                { text = L["WINDOW_LAYOUT_MAKE_STANDING"], icon = layout.standing and CHECK_TEX or nil,
                  onClick = function()
                      Layouts:SetStanding(layout.id, not layout.standing)
                      SnapAssist:RefreshTaskView()
                  end },
                { isSeparator = true },
                { text = _G["DELETE"] or "Delete", onClick = function()
                    Layouts:Delete(layout.id)
                    SnapAssist:RefreshTaskView()
                end },
            }, {})
            return
        end
        Layouts:Apply(self.layoutID, self.closing)
        SnapAssist:RefreshTaskView()
    end)
    view.layoutRows[index] = row
    return row
end

-- The row's clicks for the layout as the windows stand now; untouched in
-- a fight, where the row refuses anyway.
local function ArmLayoutRow(row, layoutID)
    local Layouts = ns.WindowLayouts
    local text, closing = nil, nil
    if layoutID and Layouts and Layouts.ClickMacro then text, closing = Layouts:ClickMacro(layoutID) end
    row.closing = closing
    if not InCombatLockdown() then row:SetAttribute("macrotext", text or "") end
end

-- The saved layouts under the windows: a header, a row each with its
-- window count and standing, and a Save layout row. Returns the height.
local function LayoutRows(view, top)
    local Layouts = ns.WindowLayouts
    if not view.layoutsHead then
        view.layoutsHead = view:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        view.layoutsHead:SetJustifyH("LEFT")
        view.layoutsHead:SetText(L["WINDOW_LAYOUTS_HEADER"])
    end
    view.layoutsHead:ClearAllPoints()
    view.layoutsHead:SetPoint("TOPLEFT", TASK_PAD + TASK_PILL_INSET, -top)
    local n, y = 0, top + 16
    for _, layout in ipairs(Layouts and Layouts:All() or {}) do
        n = n + 1
        local row = EnsureLayoutRow(view, n)
        row.layoutID = layout.id
        ArmLayoutRow(row, layout.id)
        row.name:SetText(layout.name or "?")
        row.sub:SetText(sformat(L["WINDOW_LAYOUT_SUBTEXT_FMT"], #layout.windows)
            .. (layout.standing and ("  " .. L["WINDOW_LAYOUT_STANDING"]) or ""))
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", TASK_PAD, -y)
        row:Show()
        y = y + TASK_LAYOUT_ROW_H
    end
    n = n + 1
    local save = EnsureLayoutRow(view, n)
    save.layoutID = nil
    ArmLayoutRow(save, nil)
    save.name:SetText(L["WINDOW_LAYOUT_SAVE"])
    save.sub:SetText("")
    save:ClearAllPoints()
    save:SetPoint("TOPLEFT", TASK_PAD, -y)
    save:Show()
    y = y + TASK_LAYOUT_ROW_H
    for i = n + 1, #view.layoutRows do view.layoutRows[i]:Hide() end
    return y - top
end

function SnapAssist:RefreshTaskViewIfShown()
    if taskView and taskView:IsShown() then self:RefreshTaskView() end
end

function SnapAssist:RefreshTaskView()
    local view = EnsureTaskView()
    local registry = ns.WindowRegistry
    local shown = 0
    local sig = ""
    if registry then
        registry:ForEach(function(entry)
            local frame = registry:GetFrame(entry)
            if frame and frame:IsShown() and not entry.own then
                shown = shown + 1
                sig = sig .. entry.name .. ";"
                local row = EnsureTaskRow(shown)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", TASK_PAD, -34 - (shown - 1) * TASK_ROW_H)
                row.name:SetText(PanelLabel(entry, frame))
                row._frame = frame
                row._entry = entry
                for z = 1, #row.zones do row.zones[z]._entry = entry end
                row:Show()
            end
        end)
    end
    view._windowSig = sig
    for i = shown + 1, #view.rows do view.rows[i]:Hide() end
    view.empty:SetShown(shown == 0)
    local windowsH = shown == 0 and 20 or shown * TASK_ROW_H
    local layoutsH = LayoutRows(view, 34 + windowsH + 8)
    view:SetSize(TASK_W, 46 + windowsH + 8 + layoutsH + TASK_FOOT_H)
    SyncTaskMultiCheck()
    -- Preselect the row for the most recently focused window so Alt+1..9
    -- acts on it without an extra click.
    local mgr = ns.WindowManager
    local target = mgr and mgr.ResolveTarget and mgr:ResolveTarget()
    local selected
    if target then
        for i = 1, shown do
            if view.rows[i]._entry == target then
                selected = i
                break
            end
        end
    end
    if not selected then
        selected = view.selectedIndex or 1
        if selected > shown then selected = 1 end
    end
    SelectTaskRow(selected)
end

function SnapAssist:ToggleTaskView()
    local view = EnsureTaskView()
    if view:IsShown() then
        view:Hide()
        return true
    end
    self:RefreshTaskView()
    view:Show()
    return true
end

-- ---------------------------------------------------------------------------
-- Corner resizing ("Make windows resizable"): hovering within RESIZE_HIT of
-- a managed window's corner shows a diagonal double-arrow grip. Dragging it
-- rescales a FREE window about the opposite corner (scaling IS the aspect
-- lock). A SNAPPED window's corner drag moves the shared divider instead:
-- every neighbor zone touching that divider re-fractions and re-fits,
-- Windows-11 style, so the layout stays filled. Corners of a snapped window
-- whose both edges sit on the screen boundary have nothing to drag and get
-- no grip.
-- ---------------------------------------------------------------------------
local RESIZE_HIT = 18
local RESIZE_TICK = 0.05
local msqrt, mabs, mmin = math.sqrt, math.abs, math.min
local resizeWatch
local resizeElapsed = 0
local resizeGrip
local resizeDrag

local function ResizeEnabled()
    return EasyFind and EasyFind.db and EasyFind.db.windowsResizable
end

-- Frame rect in UIParent units, y measured downward from the top.
local function FrameRectUI(frame)
    local uiScale = UIParent:GetEffectiveScale() or 1
    local uiH = UIParent:GetHeight() or 0
    local ratio = (frame:GetEffectiveScale() or 1) / uiScale
    local left, bottom = frame:GetLeft(), frame:GetBottom()
    local w, h = frame:GetWidth(), frame:GetHeight()
    if not (left and bottom and w and h) then return nil end
    return left * ratio, uiH - (bottom + h) * ratio, w * ratio, h * ratio
end

local CORNERS = { "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }
local OPPOSITE_CORNER = {
    TOPLEFT = "BOTTOMRIGHT", TOPRIGHT = "BOTTOMLEFT",
    BOTTOMLEFT = "TOPRIGHT", BOTTOMRIGHT = "TOPLEFT",
}

local function CornerPoint(cornerKey, left, top, w, h)
    if cornerKey == "TOPLEFT" then return left, top end
    if cornerKey == "TOPRIGHT" then return left + w, top end
    if cornerKey == "BOTTOMLEFT" then return left, top + h end
    return left + w, top + h
end

-- Which dividers this corner of a snapped zone can move: its vertical
-- and/or horizontal edge, but only where that edge is interior (a divider),
-- not the screen boundary.
-- Both edges are returned, interior or not: an edge lying on the screen
-- boundary still resizes, it just re-fractions this one zone instead of
-- pushing neighbors (the outer edge of a snapped window, e.g. the top-right
-- corner of a right-half window, which otherwise had no grip at all).
local function SnappedCornerDividers(fx, fy, fw, fh, cornerKey)
    local vDiv, hDiv
    if cornerKey == "TOPLEFT" or cornerKey == "BOTTOMLEFT" then
        vDiv = fx
    else
        vDiv = fx + fw
    end
    if cornerKey == "TOPLEFT" or cornerKey == "TOPRIGHT" then
        hDiv = fy
    else
        hDiv = fy + fh
    end
    return vDiv, hDiv
end

-- The default UI's own diagonal resize cursors, so the grip reads as the
-- stock resize affordance instead of a bespoke glyph.
local GRIP_TEX_NWSE = 1261459   -- UI-Cursor-SizeRight
local GRIP_TEX_NESW = 1094573   -- UI-Cursor-SizeLeft
local GRIP_SIZE = 30
-- The grip tracks the window's scale: a fixed 30 units swallowed the close
-- button once a panel was fitted down. Floored so it stays grabbable.
local GRIP_SIZE_MIN = 14

local function EnsureResizeGrip()
    if resizeGrip then return resizeGrip end
    local grip = CreateFrame("Button", nil, UIParent)
    grip:SetSize(GRIP_SIZE, GRIP_SIZE)
    grip:SetFrameStrata("FULLSCREEN_DIALOG")
    grip:SetFrameLevel(930)
    grip.glyph = grip:CreateTexture(nil, "ARTWORK")
    grip.glyph:SetAllPoints()
    grip:SetScript("OnMouseDown", function(self, mouseButton)
        if mouseButton == "LeftButton" then SnapAssist:BeginCornerResize(self) end
    end)
    grip:SetScript("OnMouseUp", function()
        resizeDrag = nil
    end)
    grip:Hide()
    resizeGrip = grip
    return grip
end

local function ConfigureGripGlyph(cornerKey)
    local grip = EnsureResizeGrip()
    grip.glyph:SetTexture((cornerKey == "TOPLEFT" or cornerKey == "BOTTOMRIGHT")
        and GRIP_TEX_NWSE or GRIP_TEX_NESW)
end

-- Topmost registered window with a hoverable corner under the cursor.
local function FindHoverCorner()
    local registry = ns.WindowRegistry
    local mgr = ns.WindowManager
    local rankTable = ns.WINDOW_STRATA_RANK
    if not (registry and mgr and rankTable) then return nil end
    local cx, cy = CursorUI()
    local cyTop = (UIParent:GetHeight() or 0) - cy
    local best, bestRank, bestLevel, bestCorner, bestX, bestY
    registry:ForEach(function(entry)
        if entry.own then return end
        local frame = registry:GetFrame(entry)
        if not (frame and frame:IsShown()) then return end
        -- The grip must never sit on the panel's close button: the top-right
        -- corner is exactly where the X lives.
        local closeBtn = mgr.GetCloseButton and mgr:GetCloseButton(frame)
        if closeBtn and closeBtn:IsShown() and closeBtn:IsMouseOver() then return end
        local left, top, w, h = FrameRectUI(frame)
        if not left then return end
        if cx < left - RESIZE_HIT or cx > left + w + RESIZE_HIT
            or cyTop < top - RESIZE_HIT or cyTop > top + h + RESIZE_HIT then return end
        local fx, fy, fw, fh = mgr:GetAppliedZone(entry.name)
        for c = 1, 4 do
            local cornerKey = CORNERS[c]
            local px, py = CornerPoint(cornerKey, left, top, w, h)
            if mabs(cx - px) <= RESIZE_HIT and mabs(cyTop - py) <= RESIZE_HIT then
                local eligible = true
                if fx then
                    local vDiv, hDiv = SnappedCornerDividers(fx, fy, fw, fh, cornerKey)
                    eligible = (vDiv or hDiv) and true or false
                end
                if eligible then
                    local rank = rankTable[frame:GetFrameStrata()] or 0
                    local level = frame:GetFrameLevel() or 0
                    if not best or rank > bestRank
                        or (rank == bestRank and level >= bestLevel) then
                        best, bestRank, bestLevel = entry, rank, level
                        bestCorner, bestX, bestY = cornerKey, px, py
                    end
                end
            end
        end
    end)
    return best, bestCorner, bestX, bestY
end

function SnapAssist:BeginCornerResize(grip)
    local entry, frame, cornerKey = grip._entry, grip._frame, grip._corner
    if not (entry and frame and frame:IsShown()) then return end
    local mgr = ns.WindowManager
    local drag = { entry = entry, frame = frame, corner = cornerKey }
    local fx, fy, fw, fh = mgr:GetAppliedZone(entry.name)
    if fx then
        drag.snapped = true
        drag.vDiv, drag.hDiv = SnappedCornerDividers(fx, fy, fw, fh, cornerKey)
        if not (drag.vDiv or drag.hDiv) then return end
        drag.crossMinV, drag.crossMaxV = fy, fy + fh
        drag.crossMinH, drag.crossMaxH = fx, fx + fw
        -- Grab offset: the cursor lands NEAR the divider, not on it (the grip
        -- is 26 units wide and the window sits a gap inside its zone). Without
        -- this the first tick drove the divider to the raw cursor position and
        -- the window jumped the moment it was clicked.
        local grabX, grabY = CursorUI()
        local grabW, grabH = WorkArea()
        drag.grabDX = grabX - drag.vDiv * grabW
        drag.grabDY = (grabH - grabY) - drag.hDiv * grabH
        drag.selfFx, drag.selfFy = fx, fy
        drag.selfFw, drag.selfFh = fw, fh
        -- A fixed-layout panel stops growing at the fit ceiling. Past that,
        -- widening its zone only adds empty space while the neighbor keeps
        -- shrinking, so the divider stops where the window stops.
        local ratio = (frame:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
        local gap = CurrentGap()
        -- Unscaled size, so the fit at any scale is base * scale. The divider
        -- follows the window's own edge, which needs these every tick.
        local dragScale = frame:GetScale() or 1
        if dragScale > 0 then
            drag.baseW = (frame:GetWidth() or 0) * ratio / dragScale
            drag.baseH = (frame:GetHeight() or 0) * ratio / dragScale
        end
        -- Which of this zone's edges the drag moves: its far edge (growing
        -- outward) or its near edge (growing inward).
        drag.movesEnd = (cornerKey == "TOPRIGHT" or cornerKey == "BOTTOMRIGHT")
        drag.movesEndV = (cornerKey == "BOTTOMLEFT" or cornerKey == "BOTTOMRIGHT")
        if entry.resizable then
            -- A resizable window fills its zone outright, so only its own
            -- max bounds (if it declares any) can stop the divider.
            if frame.GetResizeBounds then
                local _, _, maxW, maxH = frame:GetResizeBounds()
                if maxW and maxW > 0 then drag.maxFw = (maxW * ratio + gap) / grabW end
                if maxH and maxH > 0 then drag.maxFh = (maxH * ratio + gap) / grabH end
            end
        else
            -- A fixed-layout panel is ASPECT-FITTED: its scale is
            -- min(zoneW/w, zoneH/h). So the moment the other axis binds, more
            -- room on this one changes nothing -- the window sits still while
            -- the neighbor keeps giving up space, which is the "it moves the
            -- window I'm not dragging" complaint. The divider therefore stops
            -- at whichever comes first: the fit ceiling, or the size the OTHER
            -- axis already allows. The floor does the same for shrinking.
            local scale = frame:GetScale() or 1
            local ceiling = ns.WINDOW_FIT_SCALE_MAX or 2
            local floorScale = ns.WINDOW_FIT_SCALE_MIN or 0.3
            if scale > 0 then
                local baseW = (frame:GetWidth() or 0) * ratio / scale
                local baseH = (frame:GetHeight() or 0) * ratio / scale
                if baseW > 0 and baseH > 0 then
                    local zoneW = fw * grabW - gap
                    local zoneH = fh * grabH - gap
                    -- What each axis permits on its own, right now.
                    local widthAllows = zoneW / baseW
                    local heightAllows = zoneH / baseH
                    local growW = mmin(ceiling, heightAllows)
                    local growH = mmin(ceiling, widthAllows)
                    drag.maxFw = (baseW * growW + gap) / grabW
                    drag.maxFh = (baseH * growH + gap) / grabH
                    drag.minFw = (baseW * floorScale + gap) / grabW
                    drag.minFh = (baseH * floorScale + gap) / grabH
                end
            end
        end
        -- Snapshot every shown snapped zone; divider math works on fresh
        -- copies of this each tick so the drag never compounds.
        drag.zones = {}
        drag.lastKeys = {}
        local registry = ns.WindowRegistry
        registry:ForEach(function(other)
            if other.own then return end
            local otherFrame = registry:GetFrame(other)
            if not (otherFrame and otherFrame:IsShown()) then return end
            local ofx, ofy, ofw, ofh = mgr:GetAppliedZone(other.name)
            if ofx then
                drag.zones[#drag.zones + 1] =
                    { entry = other, fx = ofx, fy = ofy, fw = ofw, fh = ofh }
            end
        end)
    else
        local left, top, w, h = FrameRectUI(frame)
        if not left then return end
        drag.startScale = frame:GetScale() or 1
        drag.fixedPoint = OPPOSITE_CORNER[cornerKey]
        drag.fixedX, drag.fixedY = CornerPoint(drag.fixedPoint, left, top, w, h)
        local cx, cy = CursorUI()
        local cyTop = (UIParent:GetHeight() or 0) - cy
        local dx, dy = cx - drag.fixedX, cyTop - drag.fixedY
        drag.startDist = msqrt(dx * dx + dy * dy)
        if drag.startDist < 1 then drag.startDist = 1 end
    end
    resizeDrag = drag
end

-- Stop a divider where the window it is growing stops. Past its ceiling the
-- dragged window cannot use more room, so pushing further would only shrink
-- the neighbor to buy space nothing occupies.
-- Where the DRAGGED WINDOW's moving edge ends up for a given cursor position,
-- expressed as the divider fraction that sits just past it.
--
-- The window is aspect-locked, so the cursor only proposes a zone size; what
-- the window actually takes is min(proposedAlong, crossAxisAllows, ceiling)
-- and never less than the floor. Feeding THAT back as the divider means a
-- neighbour gives way exactly as far as this window really grew, and stops
-- the instant it stops growing -- which is the whole contract: nearest
-- boundaries stay intact. Falls back to the raw cursor for windows that fill
-- their zone outright (resizable ones), where the two edges coincide anyway.
local function DraggedEdgeFraction(drag, cursorAlong, alongUI, crossUI, vertical)
    local zoneStart = vertical and drag.selfFx or drag.selfFy
    local zoneSize = vertical and drag.selfFw or drag.selfFh
    local grab = vertical and drag.grabDX or drag.grabDY
    local raw = (cursorAlong - grab) / alongUI
    local baseAlong = vertical and drag.baseW or drag.baseH
    local baseCross = vertical and drag.baseH or drag.baseW
    if not (baseAlong and baseAlong > 0 and baseCross and baseCross > 0) then
        return raw
    end
    local gap = CurrentGap()
    local crossZone = (vertical and drag.selfFh or drag.selfFw) * crossUI - gap
    local ceiling = ns.WINDOW_FIT_SCALE_MAX or 2
    local floorScale = ns.WINDOW_FIT_SCALE_MIN or 0.3
    -- How much room along this axis the cursor is asking for.
    local movingEnd = vertical and drag.movesEnd or drag.movesEndV
    local proposed = movingEnd and (raw - zoneStart) * alongUI
        or (zoneStart + zoneSize - raw) * alongUI
    local scale = (proposed - gap) / baseAlong
    local crossAllows = crossZone / baseCross
    if scale > crossAllows then scale = crossAllows end
    if scale > ceiling then scale = ceiling end
    if scale < floorScale then scale = floorScale end
    -- The zone the window genuinely occupies at that scale, plus its gap.
    local occupied = (baseAlong * scale + gap) / alongUI
    if movingEnd then
        return zoneStart + occupied
    end
    return zoneStart + zoneSize - occupied
end

local function DragResizeTick()
    local drag = resizeDrag
    local frame = drag.frame
    if not (frame and frame:IsShown()) then
        resizeDrag = nil
        return
    end
    local mgr = ns.WindowManager
    local cx, cy = CursorUI()
    local uiW, uiH = WorkArea()
    local cyTop = uiH - cy
    if drag.snapped then
        local work = {}
        for i = 1, #drag.zones do
            local zone = drag.zones[i]
            work[i] = { entry = zone.entry, fx = zone.fx, fy = zone.fy,
                fw = zone.fw, fh = zone.fh }
        end
        local eps = SnapMath.EPS
        if drag.vDiv then
            -- Drive the divider from where the dragged WINDOW's edge actually
            -- lands, not from the cursor. These panels are aspect-locked and
            -- cannot fill a zone, so zone edges and window edges are different
            -- things: pushing the zone by the cursor made the neighbour give
            -- way for movement this window never made (and kept giving way
            -- after it had stopped growing entirely).
            local target = DraggedEdgeFraction(drag, cx, uiW, uiH, true)
            SnapMath:MoveDivider(work, drag.vDiv, target, true,
                drag.crossMinV, drag.crossMaxV,
                drag.vDiv <= eps and 0 or nil, drag.vDiv >= 1 - eps and 1 or nil)
        end
        if drag.hDiv then
            local target = DraggedEdgeFraction(drag, cyTop, uiH, uiW, false)
            SnapMath:MoveDivider(work, drag.hDiv, target, false,
                drag.crossMinH, drag.crossMaxH,
                drag.hDiv <= eps and 0 or nil, drag.hDiv >= 1 - eps and 1 or nil)
        end
        for i = 1, #work do
            local zone, orig = work[i], drag.zones[i]
            if zone.fx ~= orig.fx or zone.fy ~= orig.fy
                or zone.fw ~= orig.fw or zone.fh ~= orig.fh then
                local key = SnapMath:EncodeCustom(zone.fx, zone.fy, zone.fw, zone.fh)
                if drag.lastKeys[zone.entry.name] ~= key then
                    drag.lastKeys[zone.entry.name] = key
                    mgr:ApplySpecTo(zone.entry, key)
                end
            end
        end
    else
        local dx, dy = cx - drag.fixedX, cyTop - drag.fixedY
        local dist = msqrt(dx * dx + dy * dy)
        local newScale = drag.startScale * dist / drag.startDist
        if mabs(newScale - (drag.lastScale or drag.startScale)) > 0.01 then
            drag.lastScale = newScale
            mgr:ApplyCornerScale(drag.entry, frame, newScale, drag.fixedPoint)
        end
    end
end

local function ResizeTick(_, elapsed)
    resizeElapsed = resizeElapsed + (elapsed or 0)
    if resizeElapsed < RESIZE_TICK then return end
    resizeElapsed = 0
    if resizeDrag then
        DragResizeTick()
        -- Ride the corner being dragged instead of sitting where the drag
        -- started; the grip is the handle, so it has to stay under the cursor.
        local drag = resizeDrag
        if drag and drag.frame and resizeGrip then
            local left, top, w, h = FrameRectUI(drag.frame)
            if left then
                local px, py = CornerPoint(drag.corner, left, top, w, h)
                resizeGrip:ClearAllPoints()
                resizeGrip:SetPoint("CENTER", UIParent, "TOPLEFT", px, -py)
            end
        end
        return
    end
    if not ResizeEnabled() then
        if resizeGrip then resizeGrip:Hide() end
        if resizeWatch then Utils.SafeOnUpdate(resizeWatch, nil) end
        return
    end
    local entry, cornerKey, px, py = FindHoverCorner()
    local grip = EnsureResizeGrip()
    if not entry then
        grip:Hide()
        return
    end
    ConfigureGripGlyph(cornerKey)
    grip._entry = entry
    grip._frame = ns.WindowRegistry:GetFrame(entry)
    grip._corner = cornerKey
    local gripFrame = grip._frame
    local frameRatio = gripFrame and (gripFrame:GetEffectiveScale() or 1)
        / (UIParent:GetEffectiveScale() or 1) or 1
    local gripSize = GRIP_SIZE * frameRatio
    if gripSize > GRIP_SIZE then gripSize = GRIP_SIZE
    elseif gripSize < GRIP_SIZE_MIN then gripSize = GRIP_SIZE_MIN end
    grip:SetSize(gripSize, gripSize)
    grip:ClearAllPoints()
    grip:SetPoint("CENTER", UIParent, "TOPLEFT", px, -py)
    grip:Show()
end

function SnapAssist:RefreshResizeWatcher()
    if not resizeWatch then resizeWatch = CreateFrame("Frame") end
    if ResizeEnabled() then
        resizeElapsed = 0
        Utils.SafeOnUpdate(resizeWatch, ResizeTick)
    else
        Utils.SafeOnUpdate(resizeWatch, nil)
        if resizeGrip then resizeGrip:Hide() end
        resizeDrag = nil
    end
end

return SnapAssist
