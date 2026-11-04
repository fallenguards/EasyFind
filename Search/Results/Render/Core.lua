local _, ns = ...

local Search = ns.Search
local Results = ns.Results
local Utils = ns.Utils
local Render = ns.ResultRender
local History = ns.SearchHistory
local Icons = ns.ResultIcons
local SecureAttributes = ns.ResultSecureAttributes
local Shortcuts = ns.ResultShortcuts
local Tooltips = ns.ResultTooltips
local Database = ns.Database

local mmin, mmax, mfloor = Utils.mmin, Utils.mmax, Utils.mfloor
local wipe = wipe

local collapsedNodes = Results._collapsedNodes
local SCRATCH = Results._SCRATCH
local ApplySecureResultAttributes = SecureAttributes.Apply
local RestoreResultShortcutGutter = Shortcuts.RestoreResultShortcutGutter
local ApplyResultShortcutGutter = Shortcuts.ApplyResultShortcutGutter
local MAX_BUTTON_POOL = Render.MAX_BUTTON_POOL
local MAX_DEPTH = Render.MAX_DEPTH
local Window = Render.Window
local HideUnusedResultRow = Render.HideUnusedResultRow
local mceil = math.ceil
local InCombatLockdown = InCombatLockdown
local PIN_SEP_HEIGHT = 9  -- 4px gap + 1px line + 4px gap
local PIN_GAP = 4
local deferredRepRefreshPending = false
-- Bumped per render: the rows past the viewport land a frame later.
local renderGen = 0
local repDeferredJustRan = false

-- A grid took the panel: the list's later pass and its scroll window place
-- no more rows over it, and the next list renders in full.
function Render:RetireRows()
    renderGen = renderGen + 1
    self._lastRenderSig = nil
end

-- Each render step's ms over the rows, for the lag probe (it reads and
-- wipes): rows in view, and the rows laid out a frame later.
local parts = { now = {}, later = {} }
Render.parts = parts
local partInto, partAt = parts.now, 0
local function PartStart(later)
    if not debugprofilestop then return end
    partInto, partAt = later and parts.later or parts.now, debugprofilestop()
end
local function Part(name)
    if not debugprofilestop then return end
    local now = debugprofilestop()
    partInto[name] = (partInto[name] or 0) + now - partAt
    partAt = now
end

-- Single owner of the per-row viewport math: one visible row is the themed
-- row height plus the flat-mode extra, both font-scaled. Returns the unit
-- plus its two parts; the Rescaler snaps its height drag to unit multiples.
function Results:GetRowUnitHeight()
    local theme = Results:GetActiveTheme()
    local fontScale = EasyFind.db.fontSize or 1.0
    local rowH = mfloor(theme.rowHeight * fontScale + 0.5)
    if rowH < theme.rowHeight then rowH = theme.rowHeight end
    local flatExtraH = mfloor(16 * fontScale + 0.5)
    if flatExtraH < 16 then flatExtraH = 16 end
    return rowH + flatExtraH, rowH, flatExtraH
end

-- A re-render (settings toggle, or an async heavy-load re-search that fires
-- while the cursor is parked on a row) tears down the row the mouse is over,
-- so its tooltip vanishes and only comes back when the cursor moves. Re-fire
-- OnEnter for the hovered row, but only when its tooltip was actually lost, so
-- ordinary renders don't rebuild a tooltip that's already up.
function Render:RestoreHoveredRow()
    local buttons = Search:GetResultButtons()
    if not buttons then return end
    for i = 1, #buttons do
        local row = buttons[i]
        if row and row:IsShown() and Utils.IsFrameVisiblyMouseOver(row) then
            if not (GameTooltip:IsOwned(row) and GameTooltip:IsShown()) then
                local onEnter = row:GetScript("OnEnter")
                if onEnter then onEnter(row) end
            end
            return
        end
    end
end

-- The update-notice row: returns the extra bottom padding the results window
-- must reserve for it, or 0 when there is nothing to announce. Styling runs
-- here rather than in the theme pass because the notice is almost never up,
-- and a SetFont per render is a typing cost worth skipping.
function Render:LayoutUpdateFooter(resultsFrame)
    local footer = resultsFrame.updateFooter
    if not footer then return 0 end
    local hover = resultsFrame.updateFooterHover
    local newer = ns.VersionCheck and ns.VersionCheck:GetAvailableVersion()
    if not newer then
        footer:Hide()
        if hover then hover:Hide() end
        return 0
    end
    local theme = Results:GetActiveTheme()
    local text = Utils.sformat(ns.L["UPDATE_AVAILABLE_HINT"], newer)
        .. " " .. ns.L["UPDATE_AVAILABLE_SOURCE"]
    if footer.efText ~= text then
        footer.efText = text
        footer:SetText(text)
    end
    Results:ScaleFont(footer, ns.SEARCHBAR_FONT)
    local fontPath, fontSize, fontFlags = footer:GetFont()
    if fontPath then
        footer:SetFont(fontPath, fontSize * ns.UPDATE_NOTICE_FONT_SCALE, fontFlags)
    end
    if theme.textFaint then
        footer:SetTextColor(theme.textFaint[1], theme.textFaint[2], theme.textFaint[3], 1)
    end
    footer:ClearAllPoints()
    -- Both insets clear the window's bottom corner curves; the text is
    -- left-justified from there.
    footer:SetPoint("BOTTOMLEFT", resultsFrame, "BOTTOMLEFT", 14, ns.UPDATE_NOTICE_BOTTOM_PAD)
    footer:SetPoint("BOTTOMRIGHT", resultsFrame, "BOTTOMRIGHT", -14, ns.UPDATE_NOTICE_BOTTOM_PAD)
    footer:Show()
    -- A truncated translation keeps its full text reachable: the hover
    -- tooltip leads with the whole message (see the OnEnter handler).
    local unbounded = footer.GetUnboundedStringWidth or footer.GetStringWidth
    footer.efTruncated = (unbounded(footer) or 0) > (footer:GetWidth() or 0) + 0.5
    local band = (footer:GetStringHeight() or 10) + ns.UPDATE_NOTICE_BOTTOM_PAD + ns.UPDATE_NOTICE_TOP_PAD
    if hover then
        -- Covers the rendered text only, so empty footer space to the
        -- right does not raise the tooltip.
        hover:ClearAllPoints()
        hover:SetPoint("BOTTOMLEFT", resultsFrame, "BOTTOMLEFT", 14, 0)
        hover:SetSize(mmin(footer:GetStringWidth() or 0, footer:GetWidth() or 0), band)
        hover:Show()
    end
    return band
end

-- Open the dropdown to fit `totalContentHeight` of content (viewport capped
-- at maxVisibleHeight), wire the scroll machinery, and wrap the rounded
-- container around bar + dropdown in either orientation. ONE owner for the
-- open-the-dropdown geometry: the row renderer and the icon grid both end
-- their layout here, so the silhouette cannot drift between them.
function Render:ApplyResultsFrameLayout(resultsFrame, totalContentHeight,
        maxVisibleHeight, padT, padB, scrollInset, preserveScroll)
    local hasScroll = totalContentHeight > maxVisibleHeight
    local visibleHeight = hasScroll and maxVisibleHeight or totalContentHeight

    -- The update notice REPLACES the window's bottom padding rather than
    -- stacking under it (padding + band read as a dead strip between the
    -- last row and the text): the viewport keeps its height, and the window
    -- grows only by what the text needs beyond the padding it already had.
    local footerBand = Render:LayoutUpdateFooter(resultsFrame)
    if footerBand > 0 then
        padB = mmax(padB, footerBand)
    end

    resultsFrame:SetHeight(padT + padB + visibleHeight)
    resultsFrame.scrollChild:SetWidth(resultsFrame:GetWidth() - scrollInset)
    resultsFrame.scrollChild:SetHeight(totalContentHeight)

    resultsFrame.scrollFrame:ClearAllPoints()
    resultsFrame.scrollFrame:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 0, -padT)
    resultsFrame.scrollFrame:SetPoint("BOTTOMRIGHT", resultsFrame, "BOTTOMRIGHT", 0, padB)

    if not preserveScroll then
        resultsFrame.scrollFrame:SetVerticalScroll(0)
    end

    if resultsFrame.scrollBar then
        resultsFrame.scrollBar:SetShown(hasScroll)
        if hasScroll then
            resultsFrame.scrollBar:UpdateThumb(totalContentHeight, visibleHeight)
        end
    end

    -- Anchor results above or below based on setting. The rounded
    -- container wraps the bar and dropdown in either orientation.
    local belowMode = not EasyFind.db.uiResultsAbove
    local roundedTheme = Results:GetActiveTheme().searchBarRounded
    resultsFrame:ClearAllPoints()
    if belowMode then
        resultsFrame:SetPoint("TOP", Search:GetSearchFrame(), "BOTTOM", 0, 0)
    else
        resultsFrame:SetPoint("BOTTOM", Search:GetSearchFrame(), "TOP", 0, 0)
    end

    -- In rounded mode the resultsFrame backdrop is owned by the
    -- container; clear its own and hide any bg atlas so the unified
    -- silhouette reads as one shape.
    if roundedTheme then
        resultsFrame:SetBackdrop(nil)
        if resultsFrame.bgAtlasTex then resultsFrame.bgAtlasTex:Hide() end
        if Search:GetContainerFrame() then
            Search:GetContainerFrame():ClearAllPoints()
            if belowMode then
                Search:GetContainerFrame():SetPoint("TOPLEFT",     Search:GetSearchFrame(),  "TOPLEFT",     0, 0)
                Search:GetContainerFrame():SetPoint("TOPRIGHT",    Search:GetSearchFrame(),  "TOPRIGHT",    0, 0)
                Search:GetContainerFrame():SetPoint("BOTTOMLEFT",  resultsFrame, "BOTTOMLEFT",  0, 0)
                Search:GetContainerFrame():SetPoint("BOTTOMRIGHT", resultsFrame, "BOTTOMRIGHT", 0, 0)
                ns.SetRoundedRectDivider(Search:GetContainerFrame(), Search:GetSearchFrame():GetHeight(), true)
            else
                Search:GetContainerFrame():SetPoint("TOPLEFT",     resultsFrame, "TOPLEFT",     0, 0)
                Search:GetContainerFrame():SetPoint("TOPRIGHT",    resultsFrame, "TOPRIGHT",    0, 0)
                Search:GetContainerFrame():SetPoint("BOTTOMLEFT",  Search:GetSearchFrame(),  "BOTTOMLEFT",  0, 0)
                Search:GetContainerFrame():SetPoint("BOTTOMRIGHT", Search:GetSearchFrame(),  "BOTTOMRIGHT", 0, 0)
                ns.SetRoundedRectDivider(Search:GetContainerFrame(), resultsFrame:GetHeight(), true)
            end
        end
    end

    resultsFrame:Show()
end

-- A row's height before it is laid out: flat rows stack a name and a
-- subtext, a divider (a date line in the clipboard history) is one line,
-- a calculator card is sized to itself. The measure after layout agrees
-- except for a setting's Apply extension.
local function EstimateRowHeight(entry, st)
    local h = (entry.isFlat and not entry.isSectionHeader) and st.unit or st.rowH
    local data = entry.data
    if data and data.calculatorResult and not entry.isPathNode then
        local calcRowH = mfloor(56 * st.fontScale + 0.5)
        if calcRowH < 50 then calcRowH = 50 end
        if h < calcRowH then h = calcRowH end
    end
    return h
end

-- One result row laid out at st.tops[i]; st carries the render's settings
-- (ShowHierarchicalResults fills it). Returns the height it took.
local function LayoutRow(owner, resultRow, i, st)
    PartStart(st.belowView)
    local entry = st.visible[i]
    local data = entry.data
    local depth = entry.depth or 0
    st.yOffset = st.tops[i]

    local padL = st.theme.resultsPadLeft or 10
    local entryRowH = EstimateRowHeight(entry, st)
    local rowContentTop = st.yOffset
    resultRow:SetSize(st.resultsFrame:GetWidth() - padL * 2 - st.scrollInset, entryRowH)
    resultRow:ClearAllPoints()
    resultRow:SetPoint("TOPLEFT", st.resultsFrame.scrollChild, "TOPLEFT", padL, -st.yOffset)
    st.rowIndex = i
    st.entryRowH = entryRowH

    -- Selection visual is now carried by the row's built-in
    -- HighlightTexture (atlas set in CreateResultRow), shared
    -- with mouse hover; no separate selectionHighlight texture.
    if resultRow.UnlockHighlight and not resultRow._efContextMenuHeld then
        Results:SetRowHighlightLocked(resultRow, false)
    end

    -- Always hide section-label visuals up front. The section-
    -- header branch below re-shows them when applicable; rows
    -- recycled from a previous section-header role would
    -- otherwise leak the gold rules across normal rows.
    if resultRow.sectionLabelText then
        resultRow.sectionLabelText:Hide()
        resultRow.sectionLabelLeft:Hide()
        resultRow.sectionLabelRight:Hide()
    end
    if resultRow.calcCard then resultRow.calcCard:Hide() end
    if resultRow.calcDivider then resultRow.calcDivider:Hide() end
    if resultRow.calcDividerTop then resultRow.calcDividerTop:Hide() end
    if resultRow.calcDividerBottom then resultRow.calcDividerBottom:Hide() end
    if resultRow.calcArrowText then resultRow.calcArrowText:Hide() end
    if resultRow.calcExpressionHighlight then resultRow.calcExpressionHighlight:Hide() end
    if resultRow.calcResultHighlight then resultRow.calcResultHighlight:Hide() end
    if resultRow.calcExpressionFlash then resultRow.calcExpressionFlash:Hide() end
    if resultRow.calcResultFlash then resultRow.calcResultFlash:Hide() end
    if resultRow.calcExpressionHint then resultRow.calcExpressionHint:Hide() end
    if resultRow.calcResultHint then resultRow.calcResultHint:Hide() end
    if resultRow.calcExpressionButton then resultRow.calcExpressionButton:Hide() end
    if resultRow.calcResultButton then resultRow.calcResultButton:Hide() end
    Part("place")

    resultRow.data = data
    -- Recycled rows can leak icon.mountID etc. into the OnEnter
    -- tooltip; clear before the per-category branch sets fields.
    if resultRow.icon then
        Icons.ClearRowIconLeafIDs(resultRow.icon)
    end
    ApplySecureResultAttributes(resultRow, data)
    Part("attributes")
    resultRow.isPathNode = entry.isPathNode
    resultRow.isSectionHeader = entry.isSectionHeader or false
    resultRow.isPinHeader = entry.isPinHeader or false
    resultRow.isPinned = entry.isPinned or false
    resultRow.pathNodeName = entry.isPathNode and entry.name or nil
    resultRow.pathNodeDepth = entry.isPathNode and depth or nil
    if resultRow.pinIcon then resultRow.pinIcon:Hide() end
    if resultRow.pinToggle then resultRow.pinToggle:Hide() end
    if resultRow.pinHeaderLine then resultRow.pinHeaderLine:Hide() end
    if resultRow.createBadge then
        local showCreate = (data and data.createRow) == true
        resultRow.createBadge:SetShown(showCreate)
        resultRow.createGlow:SetShown(showCreate)
    end
    resultRow._efShortcutIndex = nil
    resultRow._efShortcutBindingReady = nil
    resultRow._efContentTop = rowContentTop
    resultRow._efContentBottom = rowContentTop + entryRowH
    if resultRow.shortcutNumberText then resultRow.shortcutNumberText:SetText("") end
    if resultRow.shortcutGroup then resultRow.shortcutGroup:Hide() end
    RestoreResultShortcutGutter(resultRow)

    for d = 1, MAX_DEPTH do
        resultRow.treeVert[d]:Hide()
        resultRow.treeElbow[d]:Hide()
        resultRow.treeBranch[d]:Hide()
    end
    Part("reset")

    Render.TreeLines(resultRow, st, i, depth)

    Render.ResultHeader(resultRow, entry, st, depth)
    Part("header")

    local isUnearnedCurrency = Render.IsUnearnedCurrencyEntry(entry, st)
    resultRow.isUnearnedCurrency = isUnearnedCurrency
    resultRow.isPathNode = entry.isPathNode  -- Store for tooltip text
    local lockedReason
    if not isUnearnedCurrency and data then
        if data.quicklistMissing then
            lockedReason = ns.L["QUICKLIST_ROW_MISSING"]
        elseif data.quicklistHint then
            lockedReason = data.name
        else
            lockedReason = Database:GetEntryLockedReason(data)
        end
    end
    resultRow.lockedReason = lockedReason
    -- An unearned title dims like any unavailable row, but is NOT
    -- locked: its click still opens the achievement that awards it,
    -- which is the whole point of listing it. lockedReason would have
    -- suppressed that click, so the two are kept separate here.
    local isInertRow = isUnearnedCurrency or lockedReason ~= nil
        or (data and data.titleUnearned) or false
    Part("locked")

    Render.BaseRowText(resultRow, entry, st)
    Part("text")

    local repSideBySide = Render.RowContent(owner, resultRow, entry, st, isInertRow)
    if repSideBySide then st.anyRepSideBySide = true end
    Render.DecorateRow(resultRow, entry, st)
    Part("content")

    if resultRow._efDesat ~= isInertRow then
        resultRow._efDesat = isInertRow
        resultRow.icon:SetDesaturated(isInertRow)
        if resultRow.flatCatIcon then
            resultRow.flatCatIcon:SetDesaturated(isInertRow)
        end
    end
    if isInertRow then
        resultRow.icon:SetVertexColor(0.55, 0.55, 0.55, 1.0)
        if resultRow.flatCatIcon then
            resultRow.flatCatIcon:SetVertexColor(0.55, 0.55, 0.55, 1.0)
        end
    end

    Render.ApplyFlatResultSizing(resultRow, entry, st)
    Render.ApplyIconVisibility(resultRow, entry)
    Part("sizing")

    -- Flat-mode positioning fixup: category-specific blocks above
    -- (currency, mount/toy/pet, loot, map, repBar) re-anchor text using
    -- LEFT (vertical center) which collapses the name+path stack.
    -- Re-apply flat anchoring last so layout is consistent across
    -- all categories and the path subtext is bounded by the rep bar
    -- when one is shown (so it stays out of the bar's horizontal area).
    Render.ApplyFlatResultAnchoring(resultRow, entry, st)
    Part("anchoring")

    Render.ApplyPinnedResultPrefix(resultRow, entry)
    Render.ApplyGPSButton(resultRow, entry, st)
    Part("gps")

    -- Per-row Apply / Reset extension for settings that staged
    -- a pendingValue (CommitFlag.Apply -- graphics, resolution).
    -- The extension sits BELOW the row as a separate visual
    -- element so the row's own contents (icon, name, inline
    -- editors) don't shift; only the y-cursor below advances to
    -- make room.
    local hasPendingApply = Render.GetResultPendingApply(data)
    if resultRow.settingApplyExt then
        resultRow.settingApplyExt:SetShown(hasPendingApply)
    end

    local actualH = Render.MeasureResultRowHeight(resultRow, entry, st)

    Render.ApplyOffSpecResultStyle(resultRow, data)
    Part("measure")

    -- Reserve y-cursor space for the apply extension (sits below
    -- the row at -2 offset). Row's own bounds are unchanged.
    if hasPendingApply and resultRow.settingApplyExtH then
        actualH = actualH + resultRow.settingApplyExtH + 2
    end
    resultRow._efContentBottom = rowContentTop + actualH
    if st.showShortcutHints and resultRow.data and not resultRow.isPinHeader
       and not resultRow.isSectionHeader then
        ApplyResultShortcutGutter(resultRow)
    end
    st.yOffset = st.yOffset + actualH
    resultRow:Show()
    Part("gutter")
    return actualH
end

-- The entries shown, hierarchical[from..to] appended to visible[n+1..]:
-- a collapsed node's children stay out. Returns the new count.
local function CollapseInto(visible, n, hierarchical, from, to)
    local skipBelowDepth, skipPins = nil, false
    for hi = from, to do
        local entry = hierarchical[hi]
        local d = entry.depth or 0
        if skipBelowDepth and d <= skipBelowDepth then skipBelowDepth = nil end
        if not (skipPins and entry.isPinned) and not skipBelowDepth then
            if skipPins and not entry.isPinned then skipPins = false end
            n = n + 1
            visible[n] = entry
            if entry.isPathNode and collapsedNodes[entry.name .. "_" .. d] then
                skipBelowDepth = d
            end
        end
    end
    return n
end

-- A nested row with no later sibling draws an elbow, not a tee.
local function MarkLastChildren(visible, isLastChild, from, to, n)
    for i = from, to do
        local d = visible[i].depth or 0
        if d > 0 then
            local foundSibling = false
            for j = i + 1, n do
                local dj = visible[j].depth or 0
                if dj < d then break end
                if dj == d then foundSibling = true; break end
            end
            isLastChild[i] = not foundSibling
        end
    end
end

-- The frame pool is the rows near the view: a row takes the lowest free
-- frame (made when none is), a row leaving the window gives its back.
local function TakeFrame()
    local buttons = Search:GetResultButtons()
    for k = 1, MAX_BUTTON_POOL do
        local f = buttons[k] or Results:EnsureResultButton(k)
        if not f.rowIndex then return f end
    end
end

local function PlaceRow(owner, i, st)
    local row = st.frameOf[i]
    if not row then
        row = TakeFrame()
        st.frameOf[i] = row
        row.rowIndex = i
    end
    local entry = st.visible[i]
    -- A row past the first paint learns whether it is pinned as it is laid out.
    if entry.isPinned == nil then
        local d = entry.data
        entry.isPinned = (d and not d.noPin and ns.UIPins.IsPinned(d)) and true or false
    end
    local h = LayoutRow(owner, row, i, st)
    if h ~= st.heights[i] then
        st.heights[i] = h
        st.dirty = true
    end
end

local function ReleaseFrame(st, f)
    st.frameOf[f.rowIndex] = nil
    f.rowIndex = nil
    HideUnusedResultRow(f)
end

-- The scroll child's height and the thumb follow the geometry.
local function SetContentHeight(st)
    local resultsFrame = st.resultsFrame
    resultsFrame.scrollChild:SetHeight(st.contentH)
    local bar = resultsFrame.scrollBar
    if bar then
        local hasScroll = st.contentH > st.maxVisibleHeight
        bar:SetShown(hasScroll)
        if hasScroll then bar:UpdateThumb(st.contentH, st.maxVisibleHeight) end
    end
    if resultsFrame.pinSeparator and st.hasResultsAfterPins then
        local y = -st.pinEndYOffset - 4
        resultsFrame.pinSeparator:ClearAllPoints()
        resultsFrame.pinSeparator:SetPoint("TOPLEFT", resultsFrame.scrollChild, "TOPLEFT", 10, y)
        resultsFrame.pinSeparator:SetPoint("TOPRIGHT", resultsFrame.scrollChild, "TOPRIGHT", -10, y)
    end
end

-- A measured height differed from its estimate: the rows below move.
local function Reflow(st)
    st.dirty = false
    st.contentH, st.pinEndYOffset = Window.Tops(st.tops, st.heights, st.visible, st.n,
        st.lastPinIndex, st.hasResultsAfterPins, PIN_GAP, PIN_SEP_HEIGHT)
    local padL = st.theme.resultsPadLeft or 10
    local buttons = Search:GetResultButtons()
    for k = 1, #buttons do
        local f = buttons[k]
        local i = f.rowIndex
        if i and f._efContentTop ~= st.tops[i] then
            local top = st.tops[i]
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", st.resultsFrame.scrollChild, "TOPLEFT", padL, -top)
            f._efContentTop, f._efContentBottom = top, top + st.heights[i]
        end
    end
    SetContentHeight(st)
end

-- The rows near the view hold frames: the view plus a screen below and
-- half above. Runs on every scroll bucket and after a list grows.
function Render:UpdateWindow(force)
    local st = SCRATCH.renderState
    local n = st.n
    if not n or n < 1 or st.gen ~= renderGen or InCombatLockdown() then return end
    local resultsFrame = st.resultsFrame
    if not (resultsFrame and resultsFrame:IsShown()) then return end
    local sf = resultsFrame.scrollFrame
    local viewH = sf:GetHeight() or 0
    if viewH <= 0 then viewH = st.maxVisibleHeight end
    local first, last = Window.Range(st.tops, st.heights, n, sf:GetVerticalScroll() or 0, viewH, st.first)
    local a, b = Window.Bounds(first, last, n, mceil(viewH / st.unit))
    st.first = first
    if not force and a == st.a and b == st.b then return end
    local sel = Search:GetSelectedIndex()
    local buttons = Search:GetResultButtons()
    for k = 1, #buttons do
        local f = buttons[k]
        local i = f.rowIndex
        if i and (i < a or i > b) and i ~= sel and not f._efContextMenuHeld then ReleaseFrame(st, f) end
    end
    for i = a, b do
        if not st.frameOf[i] then PlaceRow(self, i, st) end
    end
    st.a, st.b = a, b
    if st.dirty then Reflow(st) end
end

-- hierarchical[from..] arrived after the first paint (the rows past the
-- head of the list): they join the geometry, the scroll range and, where
-- the view reaches them, the window.
function Render:ExtendResults(hierarchical, from)
    local st = SCRATCH.renderState
    local n = st.n
    if not n or n < 1 or st.gen ~= renderGen or Results._cachedHierarchical ~= hierarchical
       or #hierarchical < from or InCombatLockdown() then return end
    local resultsFrame = st.resultsFrame
    if not (resultsFrame and resultsFrame:IsShown()) then return end
    local visible = st.visible
    local n2 = CollapseInto(visible, n, hierarchical, from, #hierarchical)
    if n2 == n then return end
    for i = n + 1, n2 do st.heights[i] = EstimateRowHeight(visible[i], st) end
    MarkLastChildren(visible, st.isLastChild, n + 1, n2, n2)
    st.n, st.count = n2, n2
    local sig = self._lastRenderSig
    if sig and sig.n == from - 1 then
        for hi = from, #hierarchical do
            local e = hierarchical[hi]
            local stride = (hi - 1) * 3
            sig[stride + 1] = e.data
            sig[stride + 2] = e.depth or 0
            sig[stride + 3] = e.isPinned and 1 or 0
        end
        sig.n = #hierarchical
    end
    st.contentH, st.pinEndYOffset = Window.Tops(st.tops, st.heights, visible, n2,
        st.lastPinIndex, st.hasResultsAfterPins, PIN_GAP, PIN_SEP_HEIGHT)
    st.finish(true)
    self:UpdateWindow(true)
    Render.DrawPendingFaces(resultsFrame.scrollFrame)
end

-- The list by row index: its count, an entry, the frame a row holds (nil
-- past the window), the rows holding frames.
function Results:RowCount()
    return SCRATCH.renderState.n or 0
end

function Results:RowEntry(i)
    local st = SCRATCH.renderState
    return st.n and st.visible[i] or nil
end

function Results:RowFrame(i)
    local st = SCRATCH.renderState
    return st.n and st.frameOf[i] or nil
end

function Results:LaidOutRows()
    local st = SCRATCH.renderState
    if not st.n or st.n < 1 then return 1, 0 end
    return st.a, st.b
end

-- The view moves to row i and the row gets its frame.
function Results:ScrollRowIntoView(i)
    local st = SCRATCH.renderState
    if not st.n or i < 1 or i > st.n or not st.resultsFrame then return end
    local sf = st.resultsFrame.scrollFrame
    local top, bottom = st.tops[i], st.tops[i] + st.heights[i]
    local visH = sf:GetHeight() or 0
    local cur = sf:GetVerticalScroll() or 0
    if top < cur then
        sf:SetVerticalScroll(top)
    elseif bottom > cur + visH then
        sf:SetVerticalScroll(bottom - visH)
    end
    Render:UpdateWindow()
end

-- The list closed: no row holds a frame.
function Results:ResetWindow()
    local st = SCRATCH.renderState
    st.n, st.a, st.b = 0, 0, -1
    if st.frameOf then wipe(st.frameOf) end
    local buttons = Search:GetResultButtons()
    for k = 1, #buttons do buttons[k].rowIndex = nil end
end

function Render:ShowHierarchicalResults(hierarchical, preserveScroll)
    if not hierarchical or #hierarchical == 0 then
        self:HideResults()
        return
    end
    local resultsFrame = Search:GetResultsFrame()
    if not resultsFrame then return end
    PartStart(false)

    -- Leaving a grid: it hid the row pool, so the render-skip signature
    -- must be busted or an "identical" list would early-return with every
    -- row still hidden under a now-hidden grid.
    if Results:IsGridShown() then
        Results:HideGrids()
        self._lastRenderSig = nil
    end

    -- Rows hidden or repurposed by a re-render never fire OnLeave (a
    -- frame hidden under the cursor doesn't), which strands the unearned
    -- tooltip on screen; every render starts it hidden and the next
    -- hover re-shows it.
    local unearned = Tooltips:GetUnearnedTooltip()
    if unearned then unearned:Hide() end

    Render.rendering = nil
    Results._cachedHierarchical = hierarchical

    -- Render-skip: if the input list is identical (same length, same
    -- data refs and same depth at every index) AND the relevant view
    -- state (theme, collapse state, results-above) hasn't
    -- changed since the last render, the visible output would be byte-
    -- for-byte identical. Skip the entire per-row layout pass: this is
    -- the typical case during typing once the top results stabilize.
    do
        -- collapsedNodes is wiped to a fresh empty table on every
        -- search, so identity comparison would always miss during
        -- typing. Snapshot a single key (or nil if empty): a click on
        -- a collapse toggle adds or removes a key, which we'll see.
        local theme = EasyFind.db.resultsTheme
        local above = EasyFind.db.uiResultsAbove
        local collapsedKey = next(collapsedNodes)
        local fontScale = EasyFind.db.fontSize or 1.0
        local searchW = Search:GetSearchFrame() and Search:GetSearchFrame():GetWidth() or 0
        local customResultsW = EasyFind.db.uiResultsWidth or 0
        local maxResultsH = EasyFind.db.uiResultsRows or 6
        -- The screen-fit clamp depends on where the dropdown sits, so a moved
        -- bar must invalidate the signature.
        -- The bar's edge, not the dropdown's own: above the bar the
        -- dropdown's bottom moved with every row-count change and each
        -- keystroke rendered twice.
        local bar = Search:GetSearchFrame()
        local frameEdge = mfloor(((bar and (EasyFind.db.uiResultsAbove and bar:GetTop() or bar:GetBottom())) or 0) + 0.5)
        local quickFilterHelp = self:IsQuickFilterSuggestionsActive() and 1 or 0
        local n = #hierarchical
        local last = self._lastRenderSig
        local same = last and last.n == n
            and last.theme == theme
            and last.above == above
            and last.collapsedKey == collapsedKey
            and last.fontScale == fontScale
            and last.searchW == searchW
            and last.customResultsW == customResultsW
            and last.maxResultsH == maxResultsH
            and last.quickFilterHelp == quickFilterHelp
            and last.frameEdge == frameEdge
            and resultsFrame:IsShown()
        if same then
            for hi = 1, n do
                local e = hierarchical[hi]
                local stride = (hi - 1) * 3
                if last[stride + 1] ~= e.data
                   or last[stride + 2] ~= (e.depth or 0)
                   or last[stride + 3] ~= (e.isPinned and 1 or 0) then
                    same = false
                    break
                end
            end
        end
        if same then
            self:RestoreHoveredRow()
            return
        end
        renderGen = renderGen + 1
        if not last then last = {}; self._lastRenderSig = last end
        last.n = n
        last.theme = theme
        last.above = above
        last.collapsedKey = collapsedKey
        last.fontScale = fontScale
        last.searchW = searchW
        last.customResultsW = customResultsW
        last.maxResultsH = maxResultsH
        last.quickFilterHelp = quickFilterHelp
        last.frameEdge = frameEdge
        for hi = 1, n do
            local e = hierarchical[hi]
            local stride = (hi - 1) * 3
            last[stride + 1] = e.data
            last[stride + 2] = e.depth or 0
            last[stride + 3] = e.isPinned and 1 or 0
        end
        for i = n * 3 + 1, #last do last[i] = nil end
    end

    Tooltips:ClearResultTooltips()

    local theme = Results:GetActiveTheme()
    local fontScale = EasyFind.db.fontSize or 1.0
    local _, rowH, flatExtraH = Results:GetRowUnitHeight()
    local stackGap = mfloor(2 * fontScale + 0.5)
    if stackGap < 2 then stackGap = 2 end
    local stackHalfGap = stackGap * 0.5
    local indPx = theme.indentPx
    local padT  = mfloor((theme.resultsPadTop or 0) * fontScale + 0.5)
    if padT < theme.resultsPadTop then padT = theme.resultsPadTop end
    local padB = mfloor((theme.resultsPadBot or 0) * fontScale + 0.5)
    if padB < theme.resultsPadBot then padB = theme.resultsPadBot end
    local quickFilterHelpH = 0
    if resultsFrame.quickFilterHelp then
        if self:IsQuickFilterSuggestionsActive() then
            quickFilterHelpH = 22
            resultsFrame.quickFilterHelp:SetShown(true)
        else
            resultsFrame.quickFilterHelp:Hide()
        end
    end
    padT = padT + quickFilterHelpH
    -- Scale row icons to match leaf font height so icon top/bottom
    -- align with text top/bottom instead of overflowing the cap line.
    local iconScale = 1.12
    local leafFontObj = _G[theme.leafFont]
    local leafFontPx = 10
    if leafFontObj and leafFontObj.GetFont then
        local _, sz = leafFontObj:GetFont()
        if sz and sz > 0 then leafFontPx = sz end
    end
    local rowIconSize = math.floor(leafFontPx * fontScale * iconScale + 0.5)
    if rowIconSize < 12 then rowIconSize = 12 end
    local maxIconSize = math.floor((theme.iconSize or 16) * fontScale + 0.5)
    if maxIconSize < (theme.iconSize or 16) then maxIconSize = theme.iconSize or 16 end
    if rowIconSize > maxIconSize then rowIconSize = maxIconSize end

    -- Once per theme generation, not per render: the backdrop never
    -- changes between keystrokes (a theme flip bumps the generation).
    local themeGen = ns.uiThemeGeneration or 0
    if resultsFrame._efBackdropGen ~= themeGen or resultsFrame._efBackdropTheme ~= theme then
        resultsFrame._efBackdropGen, resultsFrame._efBackdropTheme = themeGen, theme
        resultsFrame:SetBackdrop(theme.resultsBackdrop)
        if theme.resultsBackdropColor then
            resultsFrame:SetBackdropColor(unpack(theme.resultsBackdropColor))
        end
        if theme.resultsBackdropBorderColor then
            resultsFrame:SetBackdropBorderColor(unpack(theme.resultsBackdropBorderColor))
        end
        if theme.resultsBgAtlas then
            resultsFrame.bgAtlasTex:SetAtlas(theme.resultsBgAtlas, false)
            resultsFrame.bgAtlasTex:Show()
            resultsFrame:SetClipsChildren(true)
        else
            resultsFrame.bgAtlasTex:Hide()
            resultsFrame:SetClipsChildren(false)
        end
    end
    -- Rounded search/results use one shared silhouette whether results
    -- open above or below, so the dropdown must match the bar width.
    -- The dropdown is the bar's width whatever the skin: it reads as one
    -- window continuing below the bar.
    if Search:GetSearchFrame() then
        resultsFrame:SetWidth(Search:GetSearchFrame():GetWidth())
    else
        local customW = EasyFind.db.uiResultsWidth
        resultsFrame:SetWidth((customW and customW > 1) and customW or theme.resultsWidth)
    end

    wipe(SCRATCH.visible)
    wipe(SCRATCH.currencyInfoCache)
    local visible = SCRATCH.visible
    local visibleN = CollapseInto(visible, 0, hierarchical, 1, #hierarchical)

    -- Viewport height from the user's row count (rows scale with the theme
    -- row height and font size).
    local maxVisibleHeight = (EasyFind.db.uiResultsRows or 6) * (rowH + flatExtraH)
    -- Screen fit: if the configured height would push the dropdown off the
    -- screen edge it grows toward, shrink to as many whole rows as fit.
    -- GetTop/GetBottom are in the frame's own units, so no scale conversion
    -- is needed below the bar; above-mode converts the screen top once.
    do
        local SCREEN_MARGIN = 16
        local availableLocal
        if EasyFind.db.uiResultsAbove then
            local frameBottom = resultsFrame:GetBottom()
            local effScale = resultsFrame:GetEffectiveScale()
            if frameBottom and effScale and effScale > 0 then
                local screenTopLocal = UIParent:GetHeight() * UIParent:GetEffectiveScale() / effScale
                availableLocal = screenTopLocal - frameBottom - SCREEN_MARGIN
            end
        else
            local frameTop = resultsFrame:GetTop()
            if frameTop then availableLocal = frameTop - SCREEN_MARGIN end
        end
        if availableLocal and availableLocal > 0
           and (maxVisibleHeight + padT + padB) > availableLocal then
            local fitRows = mfloor((availableLocal - padT - padB) / (rowH + flatExtraH))
            if fitRows < 1 then fitRows = 1 end
            maxVisibleHeight = fitRows * (rowH + flatExtraH)
        end
    end
    local scrollInset = 0

    wipe(SCRATCH.isLastChild)
    local isLastChild = SCRATCH.isLastChild
    MarkLastChildren(visible, isLastChild, 1, visibleN, visibleN)

    local lastPinIndex = 0
    for i = 1, visibleN do
        if visible[i].isPinHeader or visible[i].isPinned then lastPinIndex = i end
    end
    local hasResultsAfterPins = lastPinIndex > 0 and lastPinIndex < visibleN

    local showShortcutHints = Render.ShouldShowShortcutHints()
    local renderState = SCRATCH.renderState
    wipe(renderState)
    renderState.theme = theme
    renderState.fontScale = fontScale
    renderState.rowH = rowH
    renderState.stackGap = stackGap
    renderState.stackHalfGap = stackHalfGap
    renderState.indPx = indPx
    renderState.rowIconSize = rowIconSize
    renderState.visible = visible
    renderState.count = visibleN
    renderState.isLastChild = isLastChild
    renderState.hasSideBySideRepBar = false
    local st = renderState
    st.yOffset, st.pinEndYOffset = 0, 0
    st.hasResultsAfterPins, st.lastPinIndex = hasResultsAfterPins, lastPinIndex
    st.showShortcutHints, st.flatExtraH = showShortcutHints, flatExtraH
    st.scrollInset, st.resultsFrame = scrollInset, resultsFrame
    st.anyRepSideBySide = false
    st.n, st.gen, st.unit = visibleN, renderGen, rowH + flatExtraH
    st.maxVisibleHeight, st.padT, st.padB = maxVisibleHeight, padT, padB
    st.tops, st.heights, st.frameOf = SCRATCH.rowTops, SCRATCH.rowHeights, SCRATCH.frameOfRow
    wipe(st.tops)
    wipe(st.heights)
    wipe(st.frameOf)
    for i = 1, visibleN do st.heights[i] = EstimateRowHeight(visible[i], st) end
    st.contentH, st.pinEndYOffset = Window.Tops(st.tops, st.heights, visible, visibleN,
        lastPinIndex, hasResultsAfterPins, PIN_GAP, PIN_SEP_HEIGHT)
    -- The rows in view take frames in the keystroke's frame; the rest wait
    -- a frame (all fifteen at once were 20-25 ms of item rows), and past
    -- the window hold none. A re-render keeps the view where it was.
    local buttons = Search:GetResultButtons()
    for k = 1, #buttons do buttons[k].rowIndex = nil end
    local scrollTop = preserveScroll and (resultsFrame.scrollFrame:GetVerticalScroll() or 0) or 0
    local first, last = Window.Range(st.tops, st.heights, visibleN, scrollTop, maxVisibleHeight + rowH, 1)
    st.first, st.a, st.b = first, first, last
    Render.rendering = true
    Part("setup")
    for i = first, last do PlaceRow(self, i, st) end
    if st.dirty then Reflow(st) end
    PartStart(false)
    for k = 1, #buttons do
        local resultRow = buttons[k]
        if not resultRow.rowIndex then resultRow:Hide() end
    end

    -- Separators, the frame's height and scroll range, shortcuts: after the
    -- viewport's rows, and again once the rows that waited are in.
    local function finish(preserve)
        if resultsFrame.pinSeparator then
            if st.hasResultsAfterPins then
                local y = -st.pinEndYOffset - 4
                resultsFrame.pinSeparator:ClearAllPoints()
                resultsFrame.pinSeparator:SetPoint("TOPLEFT", resultsFrame.scrollChild, "TOPLEFT", 10, y)
                resultsFrame.pinSeparator:SetPoint("TOPRIGHT", resultsFrame.scrollChild, "TOPRIGHT", -10, y)
                resultsFrame.pinSeparator:Show()
            else
                resultsFrame.pinSeparator:Hide()
            end
        end
        if resultsFrame.categorySeps then
            for si = 1, #resultsFrame.categorySeps do resultsFrame.categorySeps[si]:Hide() end
        end
        Render:ApplyResultsFrameLayout(resultsFrame, st.contentH, st.maxVisibleHeight,
            st.padT, st.padB, st.scrollInset, preserve)
        self:UpdateVisibleResultShortcuts()
    end
    st.finish = finish

    -- If any bar row is in side-by-side mode, schedule one deferred re-render so
    -- IsTruncated() can reflect the layout we just set (it reads the previous frame's state).
    -- CONVERGENCE LATCH: the re-render this schedules still sees the same
    -- side-by-side row, so without the latch it re-scheduled itself every
    -- frame forever. The deferred pass consumes the latch and does not
    -- re-arm; any later USER-driven render arms it fresh. Decided once per
    -- render, after its last rows: a list laid out in two halves consumed
    -- the latch in the first and re-armed it in the second, every frame.
    local function armBarRelayout()
        if st.anyRepSideBySide and not deferredRepRefreshPending then
            if repDeferredJustRan then
                repDeferredJustRan = false
            else
                deferredRepRefreshPending = true
                local selfRef = self
                ns.Utils.SafeAfter(0, function()
                    deferredRepRefreshPending = false
                    repDeferredJustRan = true
                    selfRef:RefreshResults()
                end)
            end
        end
    end
    finish(preserveScroll)
    Render.rendering = nil

    if first > 1 or last < visibleN then
        local gen = renderGen
        ns.Utils.SafeAfter(0, function()
            if gen ~= renderGen or InCombatLockdown() or not resultsFrame:IsShown() then return end
            -- Below the view: a creature's face waits until its row scrolls in.
            st.belowView = true
            Render:UpdateWindow(true)
            st.belowView = nil
            PartStart(true)
            finish(true)
            armBarRelayout()
            Part("finish")
            Render.DrawPendingFaces(resultsFrame.scrollFrame)
            Part("faces")
        end)
    else
        armBarRelayout()
    end
    Part("finish")

    Search:SetSelectedIndex(0)
    Search:SetToggleFocused(false)
    self:UpdateSelectionHighlight(nil, History:IsPreservingNavRepeat())
    self:RestoreHoveredRow()
    Part("select")
end
