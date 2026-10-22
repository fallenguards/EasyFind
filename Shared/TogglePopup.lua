local _, ns = ...

-- A small themed popup of toggles beside a frame, in the filter menu's
-- own row conventions: checkbox rows (the shared checkbox textures on a
-- CheckButton), radio rows (the dropdown's radial bullet and tick on a
-- plain button), action rows, submenu rows (cursor menu rows in a flyout
-- beside the row), and separators. State never lives in the
-- popup: every row reads its value through `get` and writes through
-- `set`, so the popup shows the truth each time it opens. One popup
-- frame per `name`; check rows and plain rows are pooled separately so a
-- checkbox's textures can never bleed into a radio row.
--
--   ns.ShowTogglePopup("EasyFindSomePopup", anchorFrame, {
--       { kind = "check", label = "...", get = fn, set = fn(v) },
--       { kind = "radio", label = "...", value = v, get = fn, set = fn(v) },
--       { kind = "separator" },
--       { kind = "title", label = "..." },
--       { kind = "action", label = "...", onClick = fn },
--       { kind = "submenu", label = "...", rows = cursorMenuRows },
--   }, { scale = 1, width = 180 })
local Utils = ns.Utils

local CreateFrame = CreateFrame
local UIParent = UIParent
local ipairs = ipairs
local pairs = pairs

local ROW_H = 22
local PAD = 6
local SEP_H = 9
local TITLE_H = 18
local CHECK_SIZE = 16

local popups = {}

local function EnsurePopup(name)
    local popup = popups[name]
    if popup then return popup end
    popup = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    popup:SetFrameStrata("TOOLTIP")
    popup:SetFrameLevel(9500)
    popup:EnableMouse(true)
    ns.StyleMenuPanel(popup)
    popup.checkRows, popup.plainRows, popup.seps, popup.titles = {}, {}, {}, {}
    popup.live = {}
    -- Unconstrained measuring string: rows size the popup to the widest
    -- label, never to a guess.
    popup.measure = popup:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    popup.measure:Hide()
    -- Rows wear the font the flyouts (cursor menus) wear: the results'
    -- title font at the Font setting, so a popup and its flyout read alike.
    popup.MenuFont = function(fs)
        local Results = ns.Results
        if not (Results and Results.SetScaledFont) then return end
        local theme = Results.GetActiveTheme and Results:GetActiveTheme()
        Results:SetScaledFont(fs, (theme and theme.pathFont) or ns.LEAF_FONT)
    end
    -- The search bar's and results' outside-click closers consult the
    -- shared guard registry; without this, a click on a row here would
    -- close the bar underneath.
    Utils.RegisterClickGuard(popup)
    popup:Hide()
    -- Escape closes the popup ahead of whatever is under it (the search
    -- bar registers earlier, so the popup is on top of the ESC stack).
    Utils.AttachEscClose(popup)
    popup:HookScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
    popup:HookScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        local fly = self.flyout
        if fly and fly._togglePopup == self and fly:IsShown() then fly:Hide() end
    end)
    -- Outside-click close in the menu convention: a press on the popup,
    -- on its anchor, or on a cursor menu is not "outside". The anchor's
    -- own CLICK toggles (ShowTogglePopup hides when already up for it);
    -- hiding on the anchor's press as well made the click reopen what the
    -- press had just closed, a flash. Anything that must close it for
    -- another reason (a drag starting on the anchor) calls HideTogglePopup.
    popup:SetScript("OnEvent", function(self, event)
        if event ~= "GLOBAL_MOUSE_DOWN" then return end
        if Utils.IsFrameVisiblyMouseOver(self) then return end
        if self.anchor and Utils.IsFrameVisiblyMouseOver(self.anchor) then return end
        if Utils.IsCursorMenuMouseOver and Utils.IsCursorMenuMouseOver() then return end
        self:Hide()
    end)
    popups[name] = popup
    return popup
end

-- A submenu row's rows (a table, or a builder for rows that change) for its
-- flyout: a pick closes the popup too; a toggle (keepOpen) leaves it open.
local function FlyoutRows(popup, def)
    local rows = {}
    for i, r in ipairs(type(def.rows) == "function" and def.rows() or def.rows) do
        local onClick = r.onClick
        if onClick and not r.keepOpen then
            local pick = {}
            for k, v in pairs(r) do pick[k] = v end
            pick.onClick = function()
                popup:Hide()
                onClick()
            end
            r = pick
        end
        rows[i] = r
    end
    return rows
end

-- A submenu row's rows in a cursor menu beside it, open until a click
-- elsewhere or a hover on another row.
local function OpenFlyout(popup, row)
    local fly = popup.flyout
    if fly and fly:IsShown() and fly._togglePopup == popup and fly._togglePopupRow == row then return end
    local def = row.def
    fly = Utils.ShowCursorMenu("EasyFindTogglePopupFlyout", FlyoutRows(popup, def), {
        anchorBeside = row, stayOpen = true, scale = popup:GetScale(), iconSide = "left",
        strata = popup:GetFrameStrata(), level = popup:GetFrameLevel() + 20,
        -- A toggle's click lists the rows anew, its tick moved.
        rowsProvider = function() return FlyoutRows(popup, def) end,
    })
    if fly then fly._togglePopup, fly._togglePopupRow = popup, row end
    popup.flyout = fly
end

local function RowEntered(popup, row)
    if row.def and (row.def.kind == "submenu" or row.def.rows) then
        OpenFlyout(popup, row)
        return
    end
    local fly = popup.flyout
    if fly and fly._togglePopup == popup and fly:IsShown() then fly:Hide() end
    -- A row with a tooltip says what it does beside the popup.
    local tip = row.def and row.def.tooltip
    if tip then
        GameTooltip:SetOwner(popup, "ANCHOR_NONE")
        GameTooltip:ClearAllPoints()
        GameTooltip:SetPoint("TOPLEFT", popup, "TOPRIGHT", 4, 0)
        GameTooltip:SetText(row.def.label or "", 1, 1, 1)
        GameTooltip:AddLine(tip, nil, nil, nil, true)
        GameTooltip:Show()
    end
end

local function RowLeft(popup, row)
    if row.def and row.def.tooltip and GameTooltip:GetOwner() == popup then GameTooltip_Hide() end
end

local function MakeCheckRow(popup)
    local row = CreateFrame("CheckButton", nil, popup)
    row:SetHeight(ROW_H)
    Utils.SetCheckboxTextures(row, CHECK_SIZE)
    row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row.label:SetPoint("LEFT", row:GetNormalTexture(), "RIGHT", 4, 0)
    row.label:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row._label = row.label
    Utils.InstallMenuRowHighlight(row)
    row:HookScript("OnEnter", function(self) RowEntered(popup, self) end)
    row:HookScript("OnLeave", function(self) RowLeft(popup, self) end)
    row:SetScript("OnClick", function(self)
        local def = self.def
        if not def then return end
        local v = self:GetChecked() and true or false
        if def.set then def.set(v) end
        self:SetChecked(def.get and def.get() and true or false)
        -- A check row with a flyout: its rows follow the parent's state.
        local fly = popup.flyout
        if def.rows and fly and fly:IsShown() and fly._togglePopupRow == self then
            fly:Hide()
            OpenFlyout(popup, self)
        end
    end)
    return row
end

local function MakePlainRow(popup)
    local row = CreateFrame("Button", nil, popup)
    row:SetHeight(ROW_H)
    row.bullet = row:CreateTexture(nil, "ARTWORK")
    row.bullet:SetAtlas("common-dropdown-tickradial")
    row.bullet:SetSize(14, 14)
    row.bullet:SetPoint("LEFT", 4, 0)
    row.tick = row:CreateTexture(nil, "OVERLAY")
    row.tick:SetAtlas("common-dropdown-icon-radialtick-yellow")
    row.tick:SetSize(14, 14)
    row.tick:SetPoint("LEFT", 4, 0)
    row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row._label = row.label
    row._dimTex = { row.bullet, row.tick }
    Utils.InstallMenuRowHighlight(row)
    row:HookScript("OnEnter", function(self) RowEntered(popup, self) end)
    row:HookScript("OnLeave", function(self) RowLeft(popup, self) end)
    row:SetScript("OnClick", function(self)
        local def = self.def
        if not def then return end
        if def.kind == "submenu" then
            OpenFlyout(popup, self)
        elseif def.kind == "radio" then
            if def.set then def.set(def.value) end
            ns.RefreshTogglePopup(popup)
        elseif def.kind == "action" then
            popup:Hide()
            if def.onClick then def.onClick() end
        end
    end)
    return row
end

-- Every open popup closes; true when one was. The search bar's own
-- Escape path asks this first while its edit box holds the key.
function ns.HideAllTogglePopups()
    local any = false
    for _, popup in pairs(popups) do
        if popup:IsShown() then
            popup:Hide()
            any = true
        end
    end
    return any
end

-- Close a named popup from outside (a drag starting on its anchor).
function ns.HideTogglePopup(name)
    local popup = popups[name]
    if popup and popup:IsShown() then popup:Hide() end
end

-- Repaint every live row from its `get`.
function ns.RefreshTogglePopup(popup)
    for _, row in ipairs(popup.live) do
        local def = row.def
        if def then
            if def.kind == "check" then
                row:SetChecked(def.get and def.get() and true or false)
            elseif def.kind == "radio" then
                row.tick:SetShown(def.get and def.get() == def.value)
            end
        end
    end
end

function ns.ShowTogglePopup(name, anchor, defs, opts)
    opts = opts or {}
    local popup = EnsurePopup(name)
    if popup:IsShown() and popup.anchor == anchor then
        popup:Hide()
        return
    end
    popup.anchor = anchor
    for _, r in ipairs(popup.checkRows) do r:Hide() end
    for _, r in ipairs(popup.plainRows) do r:Hide() end
    for _, s in ipairs(popup.seps) do s:Hide() end
    for _, t in ipairs(popup.titles) do t:Hide() end
    local live = popup.live
    for i = #live, 1, -1 do live[i] = nil end
    -- Width fits the widest label plus its check or bullet column; an
    -- opts.width is only ever a minimum.
    local widest = 0
    popup.MenuFont(popup.measure)
    for _, def in ipairs(defs) do
        if def.kind ~= "separator" then
            popup.measure:SetText(def.label or "")
            local w = popup.measure:GetStringWidth() or 0
            if def.kind == "submenu" or def.rows then w = w + 18 end   -- the chevron's room
            widest = math.max(widest, w)
        end
    end
    local width = math.max(opts.width or 0, math.ceil(PAD * 2 + 4 + CHECK_SIZE + 6 + widest + 10))
    local y = -PAD
    local nCheck, nPlain, nSep, nTitle = 0, 0, 0, 0
    for _, def in ipairs(defs) do
        if def.kind == "separator" then
            nSep = nSep + 1
            local sep = popup.seps[nSep]
            if not sep then
                sep = popup:CreateTexture(nil, "ARTWORK")
                sep:SetHeight(1)
                sep:SetColorTexture(1, 1, 1, 0.12)
                popup.seps[nSep] = sep
            end
            sep:ClearAllPoints()
            sep:SetPoint("TOPLEFT", popup, "TOPLEFT", PAD + 2, y - SEP_H / 2)
            sep:SetPoint("RIGHT", popup, "RIGHT", -PAD - 2, 0)
            sep:Show()
            y = y - SEP_H
        elseif def.kind == "title" then
            -- A heading over the rows below it, in the tooltip title color.
            nTitle = nTitle + 1
            local fs = popup.titles[nTitle]
            if not fs then
                fs = popup:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
                fs:SetJustifyH("LEFT")
                fs:SetShadowColor(0, 0, 0, 0)
                fs._efOwnColor = true
                popup.titles[nTitle] = fs
            end
            fs:SetText(def.label or "")
            if ns.TooltipTextColor then fs:SetTextColor(ns.TooltipTextColor()) end
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", popup, "TOPLEFT", PAD + 8, y - 3)
            fs:Show()
            y = y - TITLE_H
        else
            local row
            if def.kind == "check" then
                nCheck = nCheck + 1
                row = popup.checkRows[nCheck]
                if not row then
                    row = MakeCheckRow(popup)
                    popup.checkRows[nCheck] = row
                end
                row:SetChecked(def.get and def.get() and true or false)
                -- A check row may carry a flyout of its own rows too.
                row.label:SetPoint("RIGHT", row, "RIGHT", def.rows and -20 or -2, 0)
                if def.rows and not row.chevron then
                    row.chevron = row:CreateTexture(nil, "OVERLAY")
                    row.chevron:SetSize(12, 12)
                    row.chevron:SetPoint("RIGHT", row, "RIGHT", -6, 0)
                    Utils.SetChevronTexture(row.chevron)
                end
                if row.chevron then row.chevron:SetShown(def.rows ~= nil) end
            else
                nPlain = nPlain + 1
                row = popup.plainRows[nPlain]
                if not row then
                    row = MakePlainRow(popup)
                    popup.plainRows[nPlain] = row
                end
                row.label:ClearAllPoints()
                row.label:SetPoint("RIGHT", row, "RIGHT", def.kind == "submenu" and -20 or -2, 0)
                if def.kind == "submenu" and not row.chevron then
                    row.chevron = row:CreateTexture(nil, "OVERLAY")
                    row.chevron:SetSize(12, 12)
                    row.chevron:SetPoint("RIGHT", row, "RIGHT", -6, 0)
                    Utils.SetChevronTexture(row.chevron)
                end
                if row.chevron then row.chevron:SetShown(def.kind == "submenu") end
                if def.kind == "radio" then
                    row.bullet:Show()
                    row.tick:SetShown(def.get and def.get() == def.value)
                    row.label:SetPoint("LEFT", row.bullet, "RIGHT", 6, 0)
                else
                    row.bullet:Hide()
                    row.tick:Hide()
                    row.label:SetPoint("LEFT", row, "LEFT", 8, 0)
                end
            end
            row.def = def
            popup.MenuFont(row.label)
            row.label:SetText(def.label or "")
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", popup, "TOPLEFT", PAD, y)
            row:SetPoint("RIGHT", popup, "RIGHT", -PAD, 0)
            row:Show()
            live[#live + 1] = row
            y = y - ROW_H
        end
    end
    popup:SetSize(width, -y + PAD)
    popup:SetScale(opts.scale or 1)
    Utils.RefreshMenuRowHighlights(popup, live)
    Utils.OpenFlyoutBeside(popup, anchor, 4)
    if ns.FlatText then ns.FlatText(popup) end
    popup:Show()
    return popup
end
