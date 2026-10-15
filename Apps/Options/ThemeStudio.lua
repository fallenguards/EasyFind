-- EasyFind_Options companion: the core's namespace, not this addon's own.
local EasyFind = EasyFind
local ns = EasyFind and EasyFind._ns
if not ns then return end

-- Theme Studio: a standalone three-pane window. Left: every installed theme
-- (builtin and custom) to start from. Middle: a live mock of the search bar
-- and result rows painted straight from the working draft, so every element
-- being edited is visible at once. Right: the editing controls. The REAL UI
-- also previews live through a reserved palette name that never touches the
-- saved theme. Opened from the palette button beside the theme selector.

local ThemeStudio = {}
ns.ThemeStudio = ThemeStudio

local Utils = ns.Utils
local L = ns.L

local type = type
local xpcall = Utils.xpcall
local ErrorHandler = Utils.ErrorHandler
local mfloor, mceil = Utils.mfloor, Utils.mceil
local tremove = Utils.tremove
local strtrim = strtrim
local CreateFrame = CreateFrame
local UIParent = UIParent

local PREVIEW_NAME = "Studio Preview"
local NAME_MAX = 24
local DEFAULT_DRAFT_COLOR = { 0.5, 0.5, 0.5 }
local CIRCLE_TEX = "Interface\\AddOns\\EasyFind\\textures\\FilterButtonCircle"

local WINDOW_W, WINDOW_H = 780, 508
-- Mock geometry: the card is exactly bar + two result rows tall, like the
-- real bar showing two results; the slot grid lives beneath it.
local MOCK_ROW_H = 38
local MOCK_ROW_COUNT = 2
local LIST_W = 168
local PANEL_PAD = 12
local CONTROLS_W = 216

local SLOT_LABEL_KEYS = {
    windowFill       = "OPT_SLOT_WINDOW_FILL",
    windowFillBottom = "OPT_SLOT_GRADIENT_BOTTOM",
    windowFillTop    = "OPT_SLOT_GRADIENT_TOP",
    pathColor        = "OPT_SLOT_SUBTEXT",
    pathColorHover   = "OPT_SLOT_SUBTEXT_HOVER",
    leafColor        = "OPT_SLOT_MAIN_TEXT",
    chromeGlyph      = "OPT_SLOT_CHROME_GLYPHS",
    mutedGlyph       = "OPT_SLOT_MUTED_HINTS",
    textFaint        = "OPT_SLOT_FAINT_TEXT",
    accent           = "OPT_SLOT_ACCENT",
    controlAccent    = "OPT_SLOT_CONTROL_ACCENT",
    rowHover         = "OPT_SLOT_ROW_HOVER",
    borderColor      = "OPT_SLOT_BORDER",
    selection        = "OPT_SLOT_SELECTION",
    separator        = "OPT_SLOT_SEPARATORS",
    backdropColor    = "OPT_SLOT_BACKDROP",
    backdropBorder   = "OPT_SLOT_BACKDROP_BORDER",
}
local SLOT_HAS_ALPHA = {
    pathColor = true, pathColorHover = true, mutedGlyph = true, accent = true,
    selection = true, separator = true, backdropColor = true, backdropBorder = true,
    rowHover = true, borderColor = true,
}
-- Hardcoded mock icons: general/category icons sit LEFT (line art, chrome
-- tinted); specific per-item icons sit RIGHT (real content art, never
-- tinted). Two different content icons so the rows read as distinct items.
local MOCK_SPECIFIC_ICONS = { 132261, 133877 }

local studio
local draft
local swatchRows = {}
local themeListRows = {}
local lightCheck, borderCheck, nameBox, deleteBtn
local iconModeButtons = {}
local preview
local previewToken = 0

-- Studio chrome text follows the theme like every other surface: one
-- registry, repainted on every preview apply, restore, and theme flip.
local themedTexts = {}
local function RegisterStudioText(fs, alpha)
    fs._efOwnColor = true
    fs._studioAlpha = alpha
    themedTexts[#themedTexts + 1] = fs
end
local function RepaintStudioTexts()
    local r, g, b = ns.TooltipTextColor()
    for i = 1, #themedTexts do
        local fs = themedTexts[i]
        fs:SetTextColor(r, g, b, fs._studioAlpha or 1)
    end
    for i = 1, #swatchRows do
        local label = swatchRows[i].label
        if label then label:SetTextColor(r, g, b, 1) end
    end
    for i = 1, #themeListRows do
        local label = themeListRows[i].label
        if label then label:SetTextColor(r, g, b, 1) end
    end
    if studio and studio._efThemeSeps and ns.RetintMenuSeparators then
        ns.RetintMenuSeparators(studio)
    end
end

local function DraftStore()
    if not (EasyFind and EasyFind.db) then return nil end
    EasyFind.db.themeStudioDraft = type(EasyFind.db.themeStudioDraft) == "table"
        and EasyFind.db.themeStudioDraft or {}
    local store = EasyFind.db.themeStudioDraft
    if type(store.palette) ~= "table" then store.palette = {} end
    return store
end

local function CopyColor(c)
    if type(c) ~= "table" then return nil end
    return { c[1], c[2], c[3], c[4] }
end

-- Field-by-field copy through the shared schema; never a blind pairs() copy
-- of untrusted or live palette tables.
local function CopyPaletteInto(dst, src)
    wipe(dst)
    local slots = ns.ThemeShare and ns.ThemeShare.COLOR_SLOTS or {}
    for i = 1, #slots do
        local key = slots[i].key
        dst[key] = CopyColor(src and src[key])
    end
    if src and src.light then dst.light = true end
    if src and type(src.fillTexture) == "string" then dst.fillTexture = src.fillTexture end
end

local function DraftValid()
    if not (draft and ns.ThemeShare) then return false end
    local slots = ns.ThemeShare.COLOR_SLOTS
    for i = 1, #slots do
        local slot = slots[i]
        if slot.required and type(draft.palette[slot.key]) ~= "table" then return false end
    end
    return true
end

local function DraftColor(key, fallback)
    local c = draft and draft.palette[key]
    if c then return c[1], c[2], c[3], c[4] end
    local f = fallback or DEFAULT_DRAFT_COLOR
    return f[1], f[2], f[3], f[4]
end

-- The middle pane is the REAL search bar in miniature: its panel is fed by
-- StyleMenuPanel (true art/gradient/flat fills, real ring behavior and the
-- borderColor/borderHidden slots), its text wears the real scaled fonts, and
-- every color below reads the APPLIED preview theme -- the same getters the
-- live renderer uses -- never a hand-approximation of the draft. Runs AFTER
-- ApplyUITheme so the mock and the real bar can never disagree.
local function RepaintPreviewCard()
    if not (preview and draft) then return end
    local theme = ns.Results and ns.Results.GetActiveTheme and ns.Results:GetActiveTheme()
    if not theme then return end
    local light = theme.lightTheme

    -- Chrome glyphs: spyglass, filter arrow, apps dots. Same tint + the
    -- ADD-to-BLEND flip light themes need (ADD vanishes on light fills).
    local glyph = theme.chromeGlyph or { 1, 1, 1 }
    local blend = light and "BLEND" or "ADD"
    preview.glyph:SetVertexColor(glyph[1], glyph[2], glyph[3], 1)
    preview.filterArrow:SetBlendMode(blend)
    preview.filterArrow:SetVertexColor(glyph[1], glyph[2], glyph[3], 1)
    for i = 1, #preview.appDots do
        preview.appDots[i]:SetVertexColor(glyph[1], glyph[2], glyph[3], 1)
    end

    local faint = theme.textFaint or { 0.5, 0.5, 0.5 }
    preview.placeholder:SetTextColor(faint[1], faint[2], faint[3], 1)
    preview.placeholder:SetShadowColor(0, 0, 0, light and 0 or 1)
    local sep = theme.separatorColor or { 0.5, 0.45, 0.3, 0.35 }
    preview.barLine:SetColorTexture(sep[1], sep[2], sep[3], sep[4] or 0.35)

    local leaf = theme.leafColor or { 0.9, 0.9, 0.9 }
    local path = theme.pathColor or { 0.65, 0.6, 0.55 }
    local hover = theme.pathColorHover or { 1, 1, 1 }
    local shadow = light and 0 or 1

    -- Real fonts at real sizes, re-applied per repaint (the font setting
    -- and theme font can both change under the studio).
    local SetScaledFont = ns.Results and ns.Results.SetScaledFont

    local iconMode = EasyFind.db.iconVisibility or "all"
    local showGeneral = iconMode == "all" or iconMode == "general"
    local showSpecific = iconMode == "all" or iconMode == "specific"
    for i = 1, #preview.rows do
        local row = preview.rows[i]
        if SetScaledFont then
            ns.Results:SetScaledFont(row.name, theme.pathFont or ns.LEAF_FONT)
            ns.Results:SetScaledFont(row.sub, ns.LEAF_FONT)
        end
        row.name:SetTextColor(leaf[1], leaf[2], leaf[3], 1)
        row.name:SetShadowColor(0, 0, 0, shadow)
        if row.hovered then
            row.sub:SetTextColor(hover[1], hover[2], hover[3], 1)
        else
            row.sub:SetTextColor(path[1], path[2], path[3], path[4] or 1)
        end
        row.sub:SetShadowColor(0, 0, 0, shadow)
        -- THE shared hover pill, not an imitation: same rounded shape, same
        -- wash color/alpha derivation (rowHover slot included), same
        -- refuse-on-Black behavior -- where the additive glow stands in.
        Utils.UpdateRoundedRowWash(row, row.hovered)
        local washShown = row.hoverWash and row.hoverWash:IsShown()
        row.glow:SetShown(row.hovered and not washShown)
        -- General/category icon LEFT (chrome-tinted line art); specific
        -- per-item icon RIGHT (content art, never tinted).
        row.leftIcon:SetVertexColor(glyph[1], glyph[2], glyph[3], 1)
        row.leftIcon:SetShown(showGeneral)
        row.rightIcon:SetShown(showSpecific)
    end
end

-- The real UI previews too: the draft registers under a reserved name and
-- ApplyUITheme repaints everything from it. Never written to db.uiTheme.
local function RunPreview()
    if not (draft and DraftValid() and ns.UI_THEME_PALETTES and ns.ApplyUITheme) then return end
    ns.UI_THEME_PALETTES[PREVIEW_NAME] = draft.palette
    -- ApplyUITheme repaints the real UI AND the mock card's panel (it is a
    -- registered menu panel); the mock's chrome/text repaint reads the
    -- now-active theme afterwards, so both can never disagree.
    ns.ApplyUITheme(PREVIEW_NAME)
    RepaintPreviewCard()
    -- The studio's own buttons follow the draft, as the rest of the UI does.
    if ns.RetintPanelText and studio then ns.RetintPanelText(studio) end
    RepaintStudioTexts()
    local of = ns.optionsFrame
    if of and of.RepaintTheme and of:IsShown() then
        xpcall(of.RepaintTheme, ErrorHandler, of)
    end
end

local function SchedulePreview()
    previewToken = previewToken + 1
    local token = previewToken
    Utils.SafeAfter(0.05, function()
        if token == previewToken then RunPreview() end
    end)
end

local function ClearPreview()
    previewToken = previewToken + 1
    if ns.UI_THEME_PALETTES then ns.UI_THEME_PALETTES[PREVIEW_NAME] = nil end
    if ns.ApplyUITheme and EasyFind and EasyFind.db then
        ns.ApplyUITheme(EasyFind.db.uiTheme)
        if ns.RetintPanelText and studio then ns.RetintPanelText(studio) end
        RepaintStudioTexts()
        local of = ns.optionsFrame
        if of and of.RepaintTheme and of:IsShown() then
            xpcall(of.RepaintTheme, ErrorHandler, of)
        end
    end
end

local function PaintSwatch(row)
    local color = draft and draft.palette[row.slotKey]
    if color then
        row.swatch:SetColorTexture(color[1], color[2], color[3], 1)
    else
        row.swatch:SetColorTexture(DEFAULT_DRAFT_COLOR[1], DEFAULT_DRAFT_COLOR[2],
            DEFAULT_DRAFT_COLOR[3], 0.35)
    end
    if row.label then
        local tr, tg, tb = ns.TooltipTextColor()
        row.label:SetTextColor(tr, tg, tb, 1)
    end
end

local RefreshThemeList

local function RefreshIconModeButtons()
    local mode = EasyFind.db.iconVisibility or "all"
    for i = 1, #iconModeButtons do
        local btn = iconModeButtons[i]
        btn:SetAlpha(btn.iconMode == mode and 1.0 or 0.55)
    end
end

local function RefreshEditor()
    if not draft then return end
    for i = 1, #swatchRows do PaintSwatch(swatchRows[i]) end
    if lightCheck then lightCheck:SetChecked(draft.palette.light and true or false) end
    if borderCheck then borderCheck:SetChecked(not draft.palette.borderHidden) end
    RefreshIconModeButtons()
    if nameBox and not nameBox:HasFocus() then nameBox:SetText(draft.name or "") end
    if deleteBtn then
        deleteBtn:SetShown(draft.sourceCustom ~= nil and ns.ThemeShare
            and ns.ThemeShare:IsCustomTheme(draft.sourceCustom))
    end
    if RefreshThemeList then RefreshThemeList() end
    RepaintPreviewCard()
end

-- Undo/redo: a snapshot stack of the whole draft (palette + name). Color
-- drags coalesce into one entry via a settle delay; toggles/clears/base
-- loads push immediately. Consecutive identical states dedupe through the
-- share-codec serialization, so no-op edits never pollute the stack.
local history, historyIndex = {}, 0
local historyToken = 0
local HISTORY_CAP = 50
local undoBtn, redoBtn

local function HistorySnapshot()
    local snap = { name = draft and draft.name or "", palette = {},
        baseName = draft and draft.baseName, sourceCustom = draft and draft.sourceCustom }
    if draft then CopyPaletteInto(snap.palette, draft.palette) end
    return snap
end

local function SnapshotKey(snap)
    if not (ns.ThemeShare and ns.ThemeShare.ExportPalette) then return tostring(snap) end
    return ns.ThemeShare:ExportPalette(snap.name or "", snap.palette) or ""
end

local function UpdateHistoryButtons()
    if undoBtn then undoBtn:SetAlpha(historyIndex > 1 and 1 or 0.35) end
    if redoBtn then redoBtn:SetAlpha(historyIndex < #history and 1 or 0.35) end
end

local function PushHistoryNow()
    historyToken = historyToken + 1
    if not draft then return end
    local snap = HistorySnapshot()
    if historyIndex >= 1 and history[historyIndex]
       and SnapshotKey(history[historyIndex]) == SnapshotKey(snap) then
        return
    end
    for i = #history, historyIndex + 1, -1 do history[i] = nil end
    history[#history + 1] = snap
    if #history > HISTORY_CAP then
        tremove(history, 1)
    end
    historyIndex = #history
    UpdateHistoryButtons()
end

local function ScheduleHistoryPush()
    historyToken = historyToken + 1
    local token = historyToken
    Utils.SafeAfter(0.6, function()
        if token == historyToken then PushHistoryNow() end
    end)
end

local function RestoreHistorySnapshot(snap)
    if not (draft and snap) then return end
    draft.name = snap.name
    draft.baseName = snap.baseName
    draft.sourceCustom = snap.sourceCustom
    CopyPaletteInto(draft.palette, snap.palette)
    RefreshEditor()
    RefreshThemeList()
    SchedulePreview()
    UpdateHistoryButtons()
end

local function DoUndo()
    PushHistoryNow()
    if historyIndex <= 1 then return end
    historyIndex = historyIndex - 1
    RestoreHistorySnapshot(history[historyIndex])
end

local function DoRedo()
    if historyIndex >= #history then return end
    historyIndex = historyIndex + 1
    RestoreHistorySnapshot(history[historyIndex])
end

local pickerSlotKey, pickerPrior

-- 12.x keeps the picker in ColorPickerFrame.Content.ColorPicker; older
-- clients answer on the frame itself.
local function PickerReader(method)
    local picker = ColorPickerFrame
    if picker[method] then return picker end
    local inner = picker.Content and picker.Content.ColorPicker
    if inner and inner[method] then return inner end
    return nil
end

local function ReadPickerColor()
    local rgb = PickerReader("GetColorRGB")
    if not rgb then return nil end
    local r, g, b = rgb:GetColorRGB()
    if type(r) ~= "number" then return nil end
    local alphaSource = PickerReader("GetColorAlpha")
    local a = alphaSource and alphaSource:GetColorAlpha() or nil
    return r, g, b, a
end

local function ApplyPickerColor()
    if not (draft and pickerSlotKey) then return end
    local r, g, b, a = ReadPickerColor()
    if not r then return end
    local color = draft.palette[pickerSlotKey]
    if not color then
        color = {}
        draft.palette[pickerSlotKey] = color
    end
    color[1], color[2], color[3] = r, g, b
    if SLOT_HAS_ALPHA[pickerSlotKey] and a then
        color[4] = a
    end
    for i = 1, #swatchRows do
        if swatchRows[i].slotKey == pickerSlotKey then PaintSwatch(swatchRows[i]) end
    end
    SchedulePreview()
    ScheduleHistoryPush()
end

local function CancelPickerColor()
    if not (draft and pickerSlotKey) then return end
    draft.palette[pickerSlotKey] = pickerPrior and CopyColor(pickerPrior) or nil
    RefreshEditor()
    SchedulePreview()
end

local function OpenPickerForSlot(slotKey)
    if not (draft and ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow) then return end
    pickerSlotKey = slotKey
    pickerPrior = CopyColor(draft.palette[slotKey])
    local seed = draft.palette[slotKey] or draft.palette.windowFill or DEFAULT_DRAFT_COLOR
    local info = {
        hasOpacity = SLOT_HAS_ALPHA[slotKey] or false,
        opacity = seed[4] or 1,
        r = seed[1], g = seed[2], b = seed[3],
        swatchFunc = ApplyPickerColor,
        opacityFunc = ApplyPickerColor,
        cancelFunc = CancelPickerColor,
    }
    ColorPickerFrame:SetupColorPickerAndShow(info)
    if ColorPickerFrame.SetFrameStrata then ColorPickerFrame:SetFrameStrata("TOOLTIP") end
    if ColorPickerFrame.Raise then ColorPickerFrame:Raise() end
    -- The picker reports a color on release only; while it is up, the
    -- draft follows the wheel and the slider as they are dragged.
    local watch = ThemeStudio.pickerWatch
    if not watch then
        watch = CreateFrame("Frame")
        ThemeStudio.pickerWatch = watch
    end
    local lastR, lastG, lastB, lastA
    watch:SetScript("OnUpdate", function(self)
        if not (ColorPickerFrame:IsShown() and pickerSlotKey) then
            self:SetScript("OnUpdate", nil)
            return
        end
        local r, g, b, a = ReadPickerColor()
        if r and (r ~= lastR or g ~= lastG or b ~= lastB or a ~= lastA) then
            lastR, lastG, lastB, lastA = r, g, b, a
            ApplyPickerColor()
        end
    end)
end

local function LoadBase(name)
    local palette = ns.UI_THEME_PALETTES and ns.UI_THEME_PALETTES[name]
    if not (draft and palette) then return end
    CopyPaletteInto(draft.palette, palette)
    if ns.ThemeShare and ns.ThemeShare:IsCustomTheme(name) then
        draft.name = name
        draft.sourceCustom = name
    else
        draft.sourceCustom = nil
        draft.name = name
    end
    draft.baseName = name
    RefreshEditor()
    SchedulePreview()
    PushHistoryNow()
end

local function DoSave()
    if not (draft and ns.ThemeShare) then return end
    -- Builtin themes are read-only: starting FROM them is the whole point,
    -- but a save wearing their name gets a prompt instead of an overwrite
    -- (or a silently suffixed copy).
    if ns.ThemeShare.IsBuiltinName and ns.ThemeShare:IsBuiltinName(draft.name) then
        if ns.ShowThemedDialog then
            ns.ShowThemedDialog({
                text = (L["THEME_NAME_RESERVED"]):format(strtrim(draft.name or "")),
                acceptText = _G["OKAY"] or "Okay",
                onAccept = function()
                    if nameBox then
                        nameBox:SetFocus()
                        nameBox:HighlightText()
                    end
                end,
            })
        end
        return
    end
    local finalName = ns.ThemeShare:SaveCustomTheme(draft.name or "", draft.palette)
    if not finalName then return end
    draft.name = finalName
    draft.sourceCustom = finalName
    draft.baseName = finalName
    if ns.UI_THEME_PALETTES then ns.UI_THEME_PALETTES[PREVIEW_NAME] = nil end
    EasyFind.db.uiTheme = finalName
    if ns.ApplyUITheme then ns.ApplyUITheme(finalName) end
    local of = ns.optionsFrame
    if of then
        if of.RebuildThemeFlyout then xpcall(of.RebuildThemeFlyout, ErrorHandler) end
        if of.RepaintTheme and of:IsShown() then xpcall(of.RepaintTheme, ErrorHandler, of) end
        if of.themeBtnText then of.themeBtnText:SetText(finalName) end
    end
    RefreshEditor()
end

local function DoExport()
    if not (draft and ns.ThemeShare) then return end
    local code = ns.ThemeShare:ExportPalette(draft.name or "Theme", draft.palette)
    if code then Utils.CopyToClipboard(code) end
end

local function DoDelete()
    if not (draft and draft.sourceCustom and ns.ThemeShare) then return end
    ns.ThemeShare:DeleteCustomTheme(draft.sourceCustom)
    draft.sourceCustom = nil
    draft.baseName = nil
    ClearPreview()
    local of = ns.optionsFrame
    if of then
        if of.RebuildThemeFlyout then xpcall(of.RebuildThemeFlyout, ErrorHandler) end
        if of.themeBtnText then of.themeBtnText:SetText(EasyFind.db.uiTheme or "Black") end
    end
    RefreshEditor()
end

-- The shipped themes a draft can start from: every one but the art
-- themes, whose baked backgrounds no color slot can reproduce.
local function BuiltinBases()
    local out = {}
    for _, name in ipairs(ns.UI_THEME_ORDER or {}) do
        local pal = ns.UI_THEME_PALETTES and ns.UI_THEME_PALETTES[name]
        if pal and not pal.fillTexture and not (ns.ThemeShare and ns.ThemeShare:IsCustomTheme(name)) then
            out[#out + 1] = name
        end
    end
    return out
end

-- Left pane: the themes of your own, one row each, under the button that
-- starts a draft from a shipped theme. Pooled; rebuilt on open and after
-- save/delete so the list always matches reality.
function RefreshThemeList()
    if not studio then return end
    local order = {}
    for _, name in ipairs(ns.UI_THEME_ORDER or {}) do
        if ns.ThemeShare and ns.ThemeShare:IsCustomTheme(name) then order[#order + 1] = name end
    end
    if studio.noThemes then studio.noThemes:SetShown(#order == 0) end
    for i = 1, #order do
        local name = order[i]
        local row = themeListRows[i]
        if not row then
            row = CreateFrame("Button", nil, studio.listPane)
            row:SetHeight(22)
            row:SetPoint("TOPLEFT", studio.listPane, "TOPLEFT", 4, -54 - (i - 1) * 22)
            row:SetPoint("RIGHT", studio.listPane, "RIGHT", -4, 0)
            row.sel = row:CreateTexture(nil, "BACKGROUND")
            row.sel:SetAllPoints()
            row.sel:Hide()
            row.dot = row:CreateTexture(nil, "ARTWORK")
            row.dot:SetSize(12, 12)
            row.dot:SetPoint("LEFT", row, "LEFT", 4, 0)
            row.dot:SetTexture(CIRCLE_TEX)
            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.label:SetPoint("LEFT", row.dot, "RIGHT", 6, 0)
            row.label:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row.label:SetJustifyH("LEFT")
            row.label:SetWordWrap(false)
            row.lock = row:CreateTexture(nil, "OVERLAY")
            row.lock:SetSize(12, 12)
            row.lock:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row.lock:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-LOCK")
            row.lock:SetTexCoord(0, 0.72, 0, 0.72)
            row.lock:Hide()
            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.06)
            row:SetScript("OnClick", function(self)
                if self.themeName and not self.locked then LoadBase(self.themeName) end
            end)
            themeListRows[i] = row
        end
        row.themeName = name
        row.label:SetText(name)
        local palette = ns.UI_THEME_PALETTES and ns.UI_THEME_PALETTES[name]
        if palette and ns.ThemeSwatchColor then
            row.dot:SetVertexColor(ns.ThemeSwatchColor(palette))
        else
            row.dot:SetVertexColor(0.5, 0.5, 0.5)
        end
        -- Only BUILTIN art themes lock; a custom theme carrying shipped art
        -- must stay loadable so it can be edited and deleted.
        row.locked = (palette and palette.fillTexture
            and not (ns.ThemeShare and ns.ThemeShare:IsCustomTheme(name))) and true or nil
        row.lock:SetShown(row.locked or false)
        row.label:SetAlpha(row.locked and 0.75 or 1)
        local isBase = draft and draft.baseName == name
        row.sel:SetShown(isBase)
        if isBase then
            local sr, sg, sb, sa = DraftColor("selection", { 0.25, 0.5, 0.9, 0.35 })
            row.sel:SetColorTexture(sr, sg, sb, (sa or 0.35) * 0.7)
        end
        row:Show()
    end
    for i = #order + 1, #themeListRows do
        themeListRows[i]:Hide()
        themeListRows[i].themeName = nil
    end
end

local function BuildPreviewCard(parent)
    preview = {}
    local card = CreateFrame("Frame", nil, parent)
    preview.card = card
    -- Below the undo/redo/reset row that sits directly above the mock.
    card:SetPoint("TOPLEFT", parent, "TOPLEFT", LIST_W + PANEL_PAD, -72)
    card:SetPoint("RIGHT", parent, "RIGHT", -(CONTROLS_W + PANEL_PAD), 0)
    card:SetHeight((ns.SEARCHBAR_HEIGHT or 30) + 8 + MOCK_ROW_COUNT * MOCK_ROW_H)
    -- The REAL panel pipeline: registered like every menu surface, so each
    -- preview apply refills it with the true theme fill (art viewport,
    -- gradients, flat) and the real ring behavior including the
    -- borderColor/borderHidden slots. Nothing is hand-approximated.
    ns.StyleMenuPanel(card)

    local barH = ns.SEARCHBAR_HEIGHT or 30
    local contentSz = barH * (ns.SEARCHBAR_FILL or 0.62)
    local iconSz = contentSz * (ns.SEARCHBAR_ICON_SCALE or 0.8)

    -- Bar strip, true to the real bar: spyglass flush left, editbox
    -- placeholder, then the apps 3x3 grid and the filter arrow at the right
    -- edge, exactly the real control cluster.
    preview.glyph = card:CreateTexture(nil, "OVERLAY")
    preview.glyph:SetSize(iconSz, iconSz)
    preview.glyph:SetPoint("TOPLEFT", card, "TOPLEFT", (barH - iconSz) / 2, -(barH - iconSz) / 2)
    preview.glyph:SetTexture(ns.SEARCH_ICON_TEX)

    preview.placeholder = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    -- RepaintPreviewCard owns every mock color; the registered panel's
    -- menu-wide text retint must skip them.
    preview.placeholder._efOwnColor = true
    preview.placeholder:SetPoint("LEFT", preview.glyph, "RIGHT", 8, 0)
    preview.placeholder:SetJustifyH("LEFT")
    preview.placeholder:SetText(L["THEME_PREVIEW_PLACEHOLDER"])

    -- Filter arrow at the far right of the strip.
    preview.filterArrow = card:CreateTexture(nil, "OVERLAY")
    preview.filterArrow:SetSize(11, 11)
    preview.filterArrow:SetPoint("TOPRIGHT", card, "TOPRIGHT", -(barH - 11) / 2, -(barH - 11) / 2)
    preview.filterArrow:SetTexture(ns.FILTER_ARROW_TEX)

    -- Apps 3x3 dot grid immediately left of the filter arrow (the real
    -- waffle: drawn dots, circular-masked, chrome tinted).
    preview.appDots = {}
    local gridSize = 14
    local cell = gridSize / 3
    local dotSize = cell * 0.72
    local gridRight = -(barH - 11) / 2 - 11 - 8
    for gy = 0, 2 do
        for gx = 0, 2 do
            local dot = card:CreateTexture(nil, "OVERLAY")
            dot:SetColorTexture(1, 1, 1, 1)
            dot:SetSize(dotSize, dotSize)
            dot:SetPoint("CENTER", card, "TOPRIGHT",
                gridRight - gridSize + (gx + 0.5) * cell,
                -(barH - gridSize) / 2 - (gy + 0.5) * cell)
            local mask = card:CreateMaskTexture()
            mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
                "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetAllPoints(dot)
            dot:AddMaskTexture(mask)
            preview.appDots[#preview.appDots + 1] = dot
        end
    end

    preview.barLine = card:CreateTexture(nil, "ARTWORK")
    preview.barLine:SetHeight(1)
    preview.barLine:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -barH)
    preview.barLine:SetPoint("RIGHT", card, "RIGHT", -8, 0)

    -- Two result rows with the live renderer's anatomy: general/category
    -- icon LEFT, title + subtext, specific per-item icon RIGHT, accent
    -- indent. Row 2 renders permanently hovered (wash + hover subtext).
    preview.rows = {}
    for i = 1, MOCK_ROW_COUNT do
        local row = CreateFrame("Frame", nil, card)
        row:SetHeight(MOCK_ROW_H - 2)
        -- The hover pill hugs the window with the real bar's slim margin.
        row:SetPoint("TOPLEFT", card, "TOPLEFT", 4, -barH - 6 - (i - 1) * MOCK_ROW_H)
        row:SetPoint("RIGHT", card, "RIGHT", -4, 0)
        row.hovered = (i == 2)
        -- Black-theme fallback only: the real Black hover is an additive
        -- glow, which the rounded pill (correctly) refuses to draw.
        row.glow = row:CreateTexture(nil, "BACKGROUND")
        row.glow:SetAllPoints()
        row.glow:SetBlendMode("ADD")
        row.glow:SetColorTexture(1, 1, 1, 0.08)
        row.glow:Hide()
        row.leftIcon = row:CreateTexture(nil, "ARTWORK")
        row.leftIcon:SetSize(ns.RESULT_ICON_SIZE or 18, ns.RESULT_ICON_SIZE or 18)
        row.leftIcon:SetPoint("LEFT", row, "LEFT", 10, 0)
        row.leftIcon:SetTexture(ns.COMMANDS_ICON_TEX)
        row.rightIcon = row:CreateTexture(nil, "ARTWORK")
        row.rightIcon:SetSize(ns.RESULT_ICON_SIZE or 18, ns.RESULT_ICON_SIZE or 18)
        row.rightIcon:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        row.rightIcon:SetTexture(MOCK_SPECIFIC_ICONS[i])
        -- Title above center, subtext below center: the two-line block sits
        -- vertically centered in the row, so the pill wraps it evenly.
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.name._efOwnColor = true
        row.name:SetPoint("BOTTOMLEFT", row, "LEFT", 40, 0)
        row.name:SetText(L["THEME_PREVIEW_PRIMARY"])
        row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.sub._efOwnColor = true
        row.sub:SetPoint("TOPLEFT", row, "LEFT", 40, -1)
        row.sub:SetText(L["THEME_PREVIEW_SECONDARY"])
        preview.rows[i] = row
    end
end

-- Hovering a slot cell outlines the mock element that slot paints: a gold
-- ring around the region, or the group of regions, breathing while the
-- cursor stays. Rings are pooled, one per outlined element.
local rings, ringsUsed = {}, 0
local RING_COLOR = { 1, 0.82, 0 }

local function Ring()
    ringsUsed = ringsUsed + 1
    local ring = rings[ringsUsed]
    if ring then return ring end
    ring = CreateFrame("Frame", nil, preview.card)
    ring:SetFrameLevel(preview.card:GetFrameLevel() + 20)
    local function Edge(p1, p2)
        local e = ring:CreateTexture(nil, "OVERLAY")
        e:SetColorTexture(RING_COLOR[1], RING_COLOR[2], RING_COLOR[3], 1)
        e:SetPoint(p1)
        e:SetPoint(p2)
        return e
    end
    Edge("TOPLEFT", "TOPRIGHT"):SetHeight(1)
    Edge("BOTTOMLEFT", "BOTTOMRIGHT"):SetHeight(1)
    Edge("TOPLEFT", "BOTTOMLEFT"):SetWidth(1)
    Edge("TOPRIGHT", "BOTTOMRIGHT"):SetWidth(1)
    ring.pulse = ring:CreateAnimationGroup()
    ring.pulse:SetLooping("BOUNCE")
    local fade = ring.pulse:CreateAnimation("Alpha")
    fade:SetDuration(0.5)
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.35)
    rings[ringsUsed] = ring
    return ring
end

-- One ring around the box the given regions fill together, pad outward.
local function Outline(pad, ...)
    local left, right, top, bottom
    for i = 1, select("#", ...) do
        local region = select(i, ...)
        if region and region:IsShown() then
            local l, r, t, b = region:GetLeft(), region:GetRight(), region:GetTop(), region:GetBottom()
            if l and r and t and b then
                left = left and math.min(left, l) or l
                right = right and math.max(right, r) or r
                top = top and math.max(top, t) or t
                bottom = bottom and math.min(bottom, b) or b
            end
        end
    end
    local card = preview.card
    local cl, ct = card:GetLeft(), card:GetTop()
    if not (left and cl and ct) then return end
    local ring = Ring()
    ring:ClearAllPoints()
    ring:SetPoint("TOPLEFT", card, "TOPLEFT", left - cl - pad, top - ct + pad)
    ring:SetSize(right - left + 2 * pad, top - bottom + 2 * pad)
    ring:Show()
    ring.pulse:Play()
end

local function HideSlotHighlights()
    for i = 1, ringsUsed do
        rings[i].pulse:Stop()
        rings[i]:Hide()
    end
    ringsUsed = 0
end

-- The mock element each slot owns. Slots with no mock element yet (muted
-- hints, selection, backdrop pair, control accent) outline nothing.
local function ShowSlotHighlight(slotKey)
    HideSlotHighlights()
    if not preview then return end
    if EasyFind and EasyFind.db and EasyFind.db.themeStudioHoverPreview == false then return end
    local card = preview.card
    local rows = preview.rows
    if slotKey == "windowFill" or slotKey == "windowFillBottom"
       or slotKey == "windowFillTop" then
        Outline(-3, card)
    elseif slotKey == "borderColor" then
        Outline(3, card)
    elseif slotKey == "textFaint" then
        Outline(2, preview.placeholder)
    elseif slotKey == "separator" then
        Outline(3, preview.barLine)
    elseif slotKey == "chromeGlyph" then
        Outline(2, preview.glyph)
        Outline(2, preview.filterArrow, unpack(preview.appDots))
        Outline(2, rows[1] and rows[1].leftIcon)
    elseif slotKey == "leafColor" then
        Outline(2, rows[1] and rows[1].name)
        Outline(2, rows[2] and rows[2].name)
    elseif slotKey == "pathColor" then
        Outline(2, rows[1] and rows[1].sub)
    elseif slotKey == "pathColorHover" then
        Outline(2, rows[2] and rows[2].sub)
    elseif slotKey == "rowHover" or slotKey == "accent" then
        Outline(1, rows[2])
    end
end

-- The slot swatches, laid out horizontally in a few rows UNDER the mock
-- card: swatch on top, its name beneath (truncating cells show the full
-- name in a themed tooltip). Left-click opens the picker; right-click
-- clears optional slots.
local function BuildSlotGrid(parent)
    -- Toggle for the hover pulses, between the mock and the color options,
    -- for anyone who finds the flashing distracting.
    local hoverPrevCheck = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    hoverPrevCheck:SetSize(18, 18)
    hoverPrevCheck:SetPoint("TOPLEFT", preview.card, "BOTTOMLEFT", 0, -6)
    if Utils.SetCheckboxTextures then Utils.SetCheckboxTextures(hoverPrevCheck, 15) end
    hoverPrevCheck:SetChecked(EasyFind.db.themeStudioHoverPreview ~= false)
    local hoverPrevLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hoverPrevLabel:SetPoint("LEFT", hoverPrevCheck, "RIGHT", 3, 0)
    hoverPrevLabel:SetText(L["OPT_STUDIO_HOVER_PREVIEW"])
    RegisterStudioText(hoverPrevLabel, 0.9)
    hoverPrevCheck:SetScript("OnClick", function(self)
        EasyFind.db.themeStudioHoverPreview = self:GetChecked() and true or false
        if not self:GetChecked() then HideSlotHighlights() end
    end)

    local grid = CreateFrame("Frame", nil, parent)
    grid:SetPoint("TOPLEFT", hoverPrevCheck, "BOTTOMLEFT", 0, -6)
    grid:SetPoint("RIGHT", preview.card, "RIGHT", 0, 0)
    local slots = ns.ThemeShare and ns.ThemeShare.COLOR_SLOTS or {}
    local COLS = 4
    local CELL_W, CELL_H = 93, 20
    -- Column-major fill: every column before the last carries the same
    -- count; the final column takes the remainder (equal or fewer).
    local perCol = mceil(#slots / COLS)
    for i = 1, #slots do
        local slotKey = slots[i].key
        local cell = CreateFrame("Button", nil, grid)
        cell:SetSize(CELL_W, CELL_H)
        cell._efNoAutoRetint = true   -- a swatch keeps its slot's color through the retint walk
        local col = mfloor((i - 1) / perCol)
        local rowIdx = (i - 1) % perCol
        cell:SetPoint("TOPLEFT", grid, "TOPLEFT", col * (CELL_W + 2), -rowIdx * (CELL_H + 2))
        cell.slotKey = slotKey
        cell.optional = not slots[i].required

        cell.swatch = cell:CreateTexture(nil, "ARTWORK")
        cell.swatch:SetSize(13, 13)
        cell.swatch:SetPoint("LEFT", cell, "LEFT", 2, 0)
        cell.swatchBorder = cell:CreateTexture(nil, "BORDER")
        cell.swatchBorder:SetPoint("TOPLEFT", cell.swatch, "TOPLEFT", -1, 1)
        cell.swatchBorder:SetPoint("BOTTOMRIGHT", cell.swatch, "BOTTOMRIGHT", 1, -1)
        cell.swatchBorder:SetColorTexture(0.5, 0.5, 0.55, 0.6)

        cell.label = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cell.label._efOwnColor = true
        cell.label:SetPoint("LEFT", cell.swatch, "RIGHT", 5, 0)
        cell.label:SetPoint("RIGHT", cell, "RIGHT", -2, 0)
        cell.label:SetJustifyH("LEFT")
        cell.label:SetWordWrap(false)
        cell.label:SetText(L[SLOT_LABEL_KEYS[slotKey] or slotKey])

        cell:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        cell:SetScript("OnClick", function(self, button)
            if button == "RightButton" and self.optional and draft then
                draft.palette[self.slotKey] = nil
                RefreshEditor()
                SchedulePreview()
                PushHistoryNow()
                return
            end
            OpenPickerForSlot(self.slotKey)
        end)
        cell:SetScript("OnEnter", function(self)
            ns.ShowHintTooltip(self, "ANCHOR_TOP", nil, L[SLOT_LABEL_KEYS[self.slotKey] or self.slotKey])
            ShowSlotHighlight(self.slotKey)
        end)
        cell:SetScript("OnLeave", function(self)
            ns.HideHintTooltip(self)
            HideSlotHighlights()
        end)
        local hl = cell:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.06)
        swatchRows[#swatchRows + 1] = cell
    end
    grid:SetHeight(perCol * (CELL_H + 2))
end

local function BuildStudio()
    studio = CreateFrame("Frame", "EasyFindThemeStudio", UIParent)
    studio:SetSize(WINDOW_W, WINDOW_H)
    studio:SetPoint("CENTER")
    studio:SetFrameStrata("DIALOG")
    studio:SetFrameLevel(900)
    studio:EnableMouse(true)
    studio:SetMovable(true)
    studio:SetClampedToScreen(true)
    studio:RegisterForDrag("LeftButton")
    studio:SetScript("OnDragStart", studio.StartMoving)
    studio:SetScript("OnDragStop", studio.StopMovingOrSizing)
    ns.CreateRoundedRectBorder(studio)
    ns.SetRoundedRectBarHeight(studio, 14)
    ns.ApplyThemeFill(studio)
    if ns.RegisterThemeCallback then
        ns.RegisterThemeCallback(function()
            if studio then
                ns.ApplyThemeFill(studio)
                RepaintStudioTexts()
                if studio:IsShown() then RepaintPreviewCard() end
            end
        end)
    end

    studio.title = studio:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    studio.title:SetPoint("TOPLEFT", studio, "TOPLEFT", 16, -14)
    studio.title:SetText(L["OPT_THEME_STUDIO"])
    RegisterStudioText(studio.title)

    local x = ns.CreateCloseX(studio, 14)
    x:SetPoint("TOPRIGHT", -10, -10)
    x:SetScript("OnClick", function() studio:Hide() end)
    ns.AttachEscClose(studio)

    -- Undo / redo arrows and Reset beside the close X. The usual binds
    -- (Ctrl+Z undo, Ctrl+Y or Ctrl+Shift+Z redo) arm as override binds only
    -- while the studio is shown -- taint-free, combat-guarded, cleared on
    -- hide (deferred to combat end if hidden mid-fight).
    -- History row directly above the mock card, right-aligned to it.
    -- Visual order, right to left: [>] [<] [Reset].
    redoBtn = CreateFrame("Button", "EasyFindStudioRedoBtn", studio)
    redoBtn:SetSize(18, 18)
    redoBtn:SetPoint("TOPRIGHT", studio, "TOPRIGHT", -(CONTROLS_W + PANEL_PAD) - 2, -48)
    redoBtn.arrow = redoBtn:CreateTexture(nil, "OVERLAY")
    redoBtn.arrow:SetSize(12, 12)
    redoBtn.arrow:SetPoint("CENTER")
    Utils.SetChevronTexture(redoBtn.arrow)
    redoBtn.arrow:SetRotation(Utils.mpi / 2)
    redoBtn:SetScript("OnClick", DoRedo)
    redoBtn:SetScript("OnEnter", function(self) ns.ShowHintTooltip(self, "ANCHOR_TOP", nil, L["OPT_STUDIO_REDO"]) end)
    redoBtn:SetScript("OnLeave", function(self) ns.HideHintTooltip(self) end)
    local redoHl = redoBtn:CreateTexture(nil, "HIGHLIGHT")
    redoHl:SetAllPoints()
    redoHl:SetColorTexture(1, 1, 1, 0.08)

    undoBtn = CreateFrame("Button", "EasyFindStudioUndoBtn", studio)
    undoBtn:SetSize(18, 18)
    undoBtn:SetPoint("RIGHT", redoBtn, "LEFT", -2, 0)
    undoBtn.arrow = undoBtn:CreateTexture(nil, "OVERLAY")
    undoBtn.arrow:SetSize(12, 12)
    undoBtn.arrow:SetPoint("CENTER")
    Utils.SetChevronTexture(undoBtn.arrow)
    undoBtn.arrow:SetRotation(-Utils.mpi / 2)
    undoBtn:SetScript("OnClick", DoUndo)
    undoBtn:SetScript("OnEnter", function(self) ns.ShowHintTooltip(self, "ANCHOR_TOP", nil, L["OPT_STUDIO_UNDO"]) end)
    undoBtn:SetScript("OnLeave", function(self) ns.HideHintTooltip(self) end)
    local undoHl = undoBtn:CreateTexture(nil, "HIGHLIGHT")
    undoHl:SetAllPoints()
    undoHl:SetColorTexture(1, 1, 1, 0.08)

    local resetBtn = ns.CreateModernButton(studio, _G["RESET"] or "Reset", 56, 20)
    resetBtn:SetPoint("RIGHT", undoBtn, "LEFT", -10, 0)
    resetBtn:SetScript("OnClick", function()
        -- Back to the loaded base; undoable like any other change.
        if draft and draft.baseName then LoadBase(draft.baseName) end
    end)

    local bindsArmed = false
    local bindRegenWatcher
    local function ArmStudioBinds()
        if bindsArmed or InCombatLockdown() then return end
        bindsArmed = true
        SetOverrideBindingClick(studio, false, "CTRL-Z", "EasyFindStudioUndoBtn")
        SetOverrideBindingClick(studio, false, "CTRL-Y", "EasyFindStudioRedoBtn")
        SetOverrideBindingClick(studio, false, "CTRL-SHIFT-Z", "EasyFindStudioRedoBtn")
    end
    local function DisarmStudioBinds()
        if not bindsArmed then return end
        if InCombatLockdown() then
            if not bindRegenWatcher then
                bindRegenWatcher = CreateFrame("Frame")
                bindRegenWatcher:SetScript("OnEvent", function(self)
                    self:UnregisterAllEvents()
                    if not (studio and studio:IsShown()) then
                        bindsArmed = false
                        ClearOverrideBindings(studio)
                    end
                end)
            end
            bindRegenWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
            return
        end
        bindsArmed = false
        ClearOverrideBindings(studio)
    end
    studio:HookScript("OnShow", ArmStudioBinds)
    studio:HookScript("OnHide", DisarmStudioBinds)

    -- Left pane: installed themes.
    studio.listPane = CreateFrame("Frame", nil, studio)
    studio.listPane:SetPoint("TOPLEFT", studio, "TOPLEFT", 10, -40)
    studio.listPane:SetPoint("BOTTOMLEFT", studio, "BOTTOMLEFT", 10, 12)
    studio.listPane:SetWidth(LIST_W - 10)
    local listHeader = studio.listPane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    listHeader:SetPoint("TOPLEFT", studio.listPane, "TOPLEFT", 4, -6)
    listHeader:SetText(L["THEME_STUDIO_YOURS"])
    RegisterStudioText(listHeader, 0.85)
    -- The shipped themes stay as they are: one is copied into the draft
    -- from this button's menu, and saved under a name of its own.
    local baseBtn = ns.CreateModernButton(studio.listPane, L["THEME_STUDIO_START_FROM"], LIST_W - 18, 20)
    baseBtn:SetPoint("TOPLEFT", studio.listPane, "TOPLEFT", 4, -26)
    baseBtn:SetScript("OnClick", function(self)
        local defs = {}
        for _, name in ipairs(BuiltinBases()) do
            defs[#defs + 1] = { kind = "action", label = name, onClick = function() LoadBase(name) end }
        end
        if #defs > 0 then ns.ShowTogglePopup("EasyFindStudioBasePopup", self, defs) end
    end)
    studio.baseBtn = baseBtn
    studio.noThemes = studio.listPane:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    studio.noThemes:SetPoint("TOPLEFT", studio.listPane, "TOPLEFT", 8, -58)
    studio.noThemes:SetPoint("RIGHT", studio.listPane, "RIGHT", -6, 0)
    studio.noThemes:SetJustifyH("LEFT")
    studio.noThemes:SetWordWrap(true)
    studio.noThemes:SetText(L["THEME_STUDIO_NONE_YET"])

    -- Light vertical rules between the three panes, wearing the theme's
    -- separator color (retinted with the rest of the studio chrome).
    studio._efThemeSeps = {}
    local sepOffsets = { LIST_W + 1, WINDOW_W - CONTROLS_W - PANEL_PAD / 2 }
    for i = 1, #sepOffsets do
        local line = studio:CreateTexture(nil, "ARTWORK")
        line:SetWidth(1)
        line:SetPoint("TOPLEFT", studio, "TOPLEFT", sepOffsets[i], -40)
        line:SetPoint("BOTTOMLEFT", studio, "BOTTOMLEFT", sepOffsets[i], 12)
        studio._efThemeSeps[#studio._efThemeSeps + 1] = line
    end
    ns.RetintMenuSeparators(studio)

    BuildPreviewCard(studio)
    BuildSlotGrid(studio)

    -- Right pane: controls.
    local controls = CreateFrame("Frame", nil, studio)
    studio.controls = controls
    controls:SetPoint("TOPRIGHT", studio, "TOPRIGHT", -12, -40)
    controls:SetPoint("BOTTOMRIGHT", studio, "BOTTOMRIGHT", -12, 12)
    controls:SetWidth(CONTROLS_W - 12)

    local nameLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLabel:SetPoint("TOPLEFT", controls, "TOPLEFT", 2, -4)
    nameLabel:SetText(L["OPT_STUDIO_NAME"])
    RegisterStudioText(nameLabel, 0.85)

    local nameShell = CreateFrame("Frame", nil, controls)
    nameShell:SetHeight(22)
    nameShell:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 0, -4)
    nameShell:SetPoint("RIGHT", controls, "RIGHT", -2, 0)
    ns.CreateRoundedRectBorder(nameShell)
    ns.SetRoundedRectBarHeight(nameShell, 8)
    ns.SetRoundedRectBorderShown(nameShell, false)
    local inset = ns.EDITBOX_INSET_FILL or { 0.02, 0.02, 0.03 }
    ns.SetRoundedRectFill(nameShell, inset[1], inset[2], inset[3], 1, true)

    nameBox = CreateFrame("EditBox", nil, nameShell)
    nameBox:SetPoint("TOPLEFT", nameShell, "TOPLEFT", 8, 0)
    nameBox:SetPoint("BOTTOMRIGHT", nameShell, "BOTTOMRIGHT", -8, 0)
    nameBox:SetAutoFocus(false)
    nameBox:SetMaxLetters(NAME_MAX)
    nameBox:SetFontObject(GameFontHighlightSmall)
    RegisterStudioText(nameBox)
    nameBox:SetScript("OnTextChanged", function(self)
        if draft then
            draft.name = self:GetText() or ""
            ScheduleHistoryPush()
        end
    end)
    nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    lightCheck = CreateFrame("CheckButton", nil, controls, "UICheckButtonTemplate")
    lightCheck:SetSize(20, 20)
    lightCheck:SetPoint("TOPLEFT", nameShell, "BOTTOMLEFT", -2, -6)
    if Utils.SetCheckboxTextures then Utils.SetCheckboxTextures(lightCheck, 16) end
    local lightLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lightLabel:SetPoint("LEFT", lightCheck, "RIGHT", 4, 0)
    lightLabel:SetText(L["OPT_STUDIO_LIGHT"])
    RegisterStudioText(lightLabel)
    lightCheck:SetScript("OnClick", function(self)
        if not draft then return end
        draft.palette.light = self:GetChecked() and true or nil
        SchedulePreview()
        PushHistoryNow()
    end)

    -- Theme-level border toggle (the ring): a theme can ship borderless.
    borderCheck = CreateFrame("CheckButton", nil, controls, "UICheckButtonTemplate")
    borderCheck:SetSize(20, 20)
    borderCheck:SetPoint("TOPLEFT", lightCheck, "BOTTOMLEFT", 0, -2)
    if Utils.SetCheckboxTextures then Utils.SetCheckboxTextures(borderCheck, 16) end
    local borderLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    borderLabel:SetPoint("LEFT", borderCheck, "RIGHT", 4, 0)
    borderLabel:SetText(L["OPT_WINDOW_BORDER"])
    RegisterStudioText(borderLabel)
    borderCheck:SetScript("OnClick", function(self)
        if not draft then return end
        draft.palette.borderHidden = (not self:GetChecked()) and true or nil
        SchedulePreview()
        PushHistoryNow()
    end)

    -- Icon visibility, the same setting General carries: which result icons
    -- render. Mirrored here because the mock rows demonstrate it live.
    local iconVisLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    iconVisLabel:SetPoint("TOPLEFT", borderCheck, "BOTTOMLEFT", 2, -6)
    iconVisLabel:SetText(L["OPT_ICON_VISIBILITY"])
    RegisterStudioText(iconVisLabel, 0.85)
    local ICON_MODES = {
        { value = "all",      label = L["OPT_ICONS_ALL"] },
        { value = "general",  label = L["OPT_ICONS_GENERAL"] },
        { value = "specific", label = L["OPT_ICONS_SPECIFIC"] },
    }
    local prevModeBtn
    for i = 1, #ICON_MODES do
        local mode = ICON_MODES[i]
        local btn = ns.CreateModernButton(controls, mode.label, 62, 18)
        if prevModeBtn then
            btn:SetPoint("LEFT", prevModeBtn, "RIGHT", 4, 0)
        else
            btn:SetPoint("TOPLEFT", iconVisLabel, "BOTTOMLEFT", 0, -4)
        end
        btn.iconMode = mode.value
        btn:SetScript("OnClick", function(self)
            EasyFind.db.iconVisibility = self.iconMode
            RefreshIconModeButtons()
            RepaintPreviewCard()
            if ns.Search and ns.Search.RefreshResults then ns.Search:RefreshResults() end
        end)
        iconModeButtons[i] = btn
        prevModeBtn = btn
    end

    local saveBtn = ns.CreateModernButton(controls, _G["SAVE"] or "Save", 64, 22)
    saveBtn:SetPoint("BOTTOMLEFT", controls, "BOTTOMLEFT", 0, 2)
    saveBtn:SetScript("OnClick", function() xpcall(DoSave, ErrorHandler) end)

    local exportBtn = ns.CreateModernButton(controls, L["SHORTKEY_EXPORT"], 64, 22)
    exportBtn:SetPoint("LEFT", saveBtn, "RIGHT", 6, 0)
    exportBtn:SetScript("OnClick", function() xpcall(DoExport, ErrorHandler) end)

    deleteBtn = ns.CreateModernButton(controls, _G["DELETE"] or "Delete", 64, 22)
    deleteBtn:SetPoint("LEFT", exportBtn, "RIGHT", 6, 0)
    deleteBtn:SetScript("OnClick", function() xpcall(DoDelete, ErrorHandler) end)

    -- HookScript, never SetScript: AttachEscClose already hooked OnHide to
    -- disarm the ESC override, and SetScript would wipe that hook -- leaving
    -- ESC captured forever after the window closes.
    studio:HookScript("OnHide", ClearPreview)
    studio:Hide()
end

function ThemeStudio:Open()
    local store = DraftStore()
    if not store then return end
    draft = store
    if not studio then BuildStudio() end
    if not DraftValid() then
        -- Seed from the active theme; an art theme (locked, colors hidden
        -- behind the baked background) seeds from the default flat theme's
        -- palette instead so every edit is visible.
        local active = EasyFind.db.uiTheme
            or (ns.DB_DEFAULTS and ns.DB_DEFAULTS.uiTheme) or "Black"
        local activePal = ns.UI_THEME_PALETTES and ns.UI_THEME_PALETTES[active]
        if activePal and activePal.fillTexture then
            active = "Black"
            activePal = ns.UI_THEME_PALETTES and ns.UI_THEME_PALETTES[active]
        end
        CopyPaletteInto(draft.palette, activePal)
        draft.name = draft.name ~= "" and draft.name or active
        draft.baseName = active
    end
    studio:Show()
    if studio.Raise then studio:Raise() end
    RefreshEditor()
    SchedulePreview()
    -- Fresh undo stack per session, seeded with the opening state.
    wipe(history)
    historyIndex = 0
    PushHistoryNow()
end

function ThemeStudio:Toggle()
    if studio and studio:IsShown() then studio:Hide() else self:Open() end
end

return ThemeStudio
