local _, ns = ...

local MapTab = {}
ns.MapTab = MapTab

local Utils = ns.Utils
local L = ns.L
local MapUtils = ns.MapUtils
local ResultHandlers = ns.ResultHandlers
local SafeAfter = Utils.SafeAfter
local tinsert = Utils.tinsert
local tremove = Utils.tremove
local tsort = Utils.tsort
local mmin, mmax = Utils.mmin, Utils.mmax

local GOLD_COLOR = ns.GOLD_COLOR

local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local GameTooltip_Hide = GameTooltip_Hide
local IsAltKeyDown = IsAltKeyDown
local GetMapChildrenInfo = C_Map and C_Map.GetMapChildrenInfo
local GetMapInfo = C_Map and C_Map.GetMapInfo

local function NameLess(a, b) return a.name < b.name end
local function ZoneMapIDDesc(a, b) return (a.zoneMapID or 0) > (b.zoneMapID or 0) end

local TAB_W, TAB_H       = 43, 55
-- Side-tab art: retail's quest log draws the shared side tabs, whose
-- edge tucks under the map frame; Forever's draws none, so ours match
-- the quest log's own tab art there (the Quests tab we add is the same).
local FOREVER_TABS = ns.Caps and ns.Caps.forever
local SIDE_TAB = FOREVER_TABS and "QuestLog-tab-side" or "common-sidetab"
local SIDE_TAB_SELECT = FOREVER_TABS and "QuestLog-Tab-side-Glow-Select" or "common-sidetab-selected"
local SIDE_TAB_HOVER = FOREVER_TABS and "QuestLog-Tab-side-Glow-hover" or "common-sidetab-hover"
local SIDE_TAB_ICON_X = FOREVER_TABS and 0 or -2
local TAB_ICON_SIZE      = 20
local TAB_ICON_GOLD      = {1.00, 0.82, 0.00}
local TAB_ICON_DIM       = {0.55, 0.45, 0.10}
local TAB_STACK_GAP      = -3
-- The group headers' font; the classic clients have no Game15Font_Shadow.
local HEADER_FONT = _G.Game15Font_Shadow and "Game15Font_Shadow" or "SystemFont_Shadow_Med3"

local GetTopAncestor = MapUtils.GetTopAncestor
local GetZoneUnderAncestor = MapUtils.GetZoneUnderAncestor
local GetAncestorNames = MapUtils.GetAncestorNames
local ExpandZoneAbbrev = MapUtils.ExpandZoneAbbrev

local ROW_HEIGHT       = 22
local ROW_ICON_SIZE    = 17
local SECTION_HEADER_H = 22
local GROUP_HEADER_H   = 28

-- The list's text size, picked in its settings menu; rows grow with it.
local FONT_SIZES = { { "OPT_FONT_SMALL", 0.85 }, { "OPT_FONT_MED", 1 }, { "OPT_FONT_LARGE", 1.15 }, { "OPT_FONT_XL", 1.3 } }
local SetPortraitTextureFromCreatureDisplayID = _G.SetPortraitTextureFromCreatureDisplayID
local function FontScale() return EasyFind.db and EasyFind.db.mapTabFontSize or 1 end
local function Scaled(h) return math.floor(h * FontScale() + 0.5) end
local function ScaleFont(fs, template, scale)
    local file, size, flags = _G[template]:GetFont()
    if file then fs:SetFont(file, size * scale, flags) end
end
local MAX_ROW_POOL     = 300
local ROW_POOL_RETAIN  = 80
local HEADER_POOL_RETAIN = 40
local SECTION_POOL_RETAIN = 12


local SEARCH_SCRATCH = {
    tokens = {},
    seen = {},
    seenKeys = {},
    candidates = {},
    multiTokenCandidates = {},
    versionByName = {},
    candidateNames = {},
}

local worldChildrenCache = {}
local function GetWorldChildren(mapID)
    if not mapID or mapID == 0 then return nil end
    local cached = worldChildrenCache[mapID]
    if cached then return cached end
    local result = {}
    if not GetMapChildrenInfo then
        worldChildrenCache[mapID] = result
        return result
    end
    -- Blizzard tags instanced cities (Dalaran, etc.) as Dungeon, so an
    -- mt-based dungeon glyph mis-fires on them. Synthesized expansions
    -- of a continent never contain real dungeons anyway. Use the
    -- generic zone icon for every child.
    local children = GetMapChildrenInfo(mapID, nil, false)
    if children then
        for i = 1, #children do
            local child = children[i]
            local mt = child.mapType
            if child.name and mt
               and mt ~= Enum.UIMapType.Micro
               and mt ~= Enum.UIMapType.Orphan then
                result[#result + 1] = {
                    name = child.name,
                    category = "zone",
                    isZone = true,
                    zoneMapID = child.mapID,
                    zoneMapType = mt,
                    icon = ns.ZONE_ICON,
                    synthesized = true,
                }
            end
        end
    end
    tsort(result, NameLess)
    worldChildrenCache[mapID] = result
    return result
end

do
    local inv = CreateFrame("Frame")
    inv:RegisterEvent("PLAYER_ENTERING_WORLD")
    inv:SetScript("OnEvent", function() worldChildrenCache = {} end)
end

local initialized = false
local tabFrame
local backTab            -- our Quests tab, only where Blizzard draws none
-- Forward declared: closures below capture this before RunSearch defines it.
local RefreshCurrentSearch
local ReleaseMapTabMemory

local function MapShownForSweep()
    return WorldMapFrame and WorldMapFrame:IsShown() or false
end

local function TrimAfterMapSearch()
    if ns.MapSearch and ns.MapSearch.TrimSearchMemory then
        ns.MapSearch:TrimSearchMemory()
    end
end
local panel
-- Era, Anniversary and MoP Classic: a map with no quest panel beside it
-- gets a side panel of its own (SidePanel.Build, by the panel's builder).
local SidePanel = {}
-- What the panel and its tabs hang on: retail's quest panel or ours.
local function Host() return SidePanel.frame or _G["QuestMapFrame"] end
local selectedIsOurs = false
local lastSelectedWasOurs = false
-- Extra side pages (an extension's own tab under the search tab): the
-- search widgets hide and the page's frame shows in the same panel.
local activePage
local pages = {}
local pageOrder = {}
local extraTabs = {}
local PlaceTab   -- defined with the tab layout below, used by RegisterPage above it
local restoringBlizzardDisplayMode = false
local function IsMapSearchEnabled()
    return not (EasyFind and EasyFind.db and EasyFind.db.enableMapSearch == false)
end
function MapTab:IsEnabled()
    return IsMapSearchEnabled()
end
-- SetDisplayMode(nil) clears qmf.displayMode, leaving Blizzard with no
-- mode to restore on map close+reopen (renders blank sidebar). Stash the
-- prior mode and put it back on hide.
local prevBlizzardDisplayMode
local rowPool = {}
local headerPool = {}
local rowPoolCursor = 1
local headerPoolCursor = 1
-- Collapse state scoped to the current query text. Reset on text change
-- so fresh matches default to expanded (auto-expand on parent match).
local sessionCollapsed = {}
local sessionCollapsedQuery = nil
local lastQueryGen = 0
local pendingSearchTimer
local pendingSearchFrame
local pendingSearchText
local pendingSearchGrew
local pendingSearchEditBox
local CancelPendingSearch
local function RunPendingSearchNow()
    if not pendingSearchTimer then return false end
    local box = pendingSearchEditBox
    local text = pendingSearchText or ""
    local shouldAutocomplete = pendingSearchGrew
    CancelPendingSearch()
    MapTab:RunSearch(text)
    if shouldAutocomplete and box and box.UpdateAutocomplete then
        box:UpdateAutocomplete()
    end
    return true
end
CancelPendingSearch = function()
    if pendingSearchFrame then pendingSearchFrame:Hide() end
    pendingSearchTimer = nil
    pendingSearchText = nil
    pendingSearchGrew = nil
    pendingSearchEditBox = nil
end
local function SchedulePendingSearch(editBox, typed, grew)
    if not pendingSearchFrame then
        pendingSearchFrame = CreateFrame("Frame")
        pendingSearchFrame:Hide()
        Utils.SafeOnUpdate(pendingSearchFrame, function(self)
            self:Hide()
            local box = pendingSearchEditBox
            local text = pendingSearchText or ""
            local shouldAutocomplete = pendingSearchGrew
            pendingSearchTimer = nil
            pendingSearchText = nil
            pendingSearchGrew = nil
            pendingSearchEditBox = nil
            MapTab:RunSearch(text)
            if shouldAutocomplete and box and box.UpdateAutocomplete then
                box:UpdateAutocomplete()
            end
        end)
    end
    pendingSearchTimer = true
    pendingSearchText = typed
    pendingSearchGrew = grew
    pendingSearchEditBox = editBox
    pendingSearchFrame:Show()
end
-- Search box text can diverge from the active query (clicking a recent
-- row runs a search without populating the box). Result-click and Enter
-- paths read this instead of the editbox.
local currentQuery = ""
local lastRenderedQuery
local navRowIndex = 0
local visibleNavRows = {}
local navFrame
-- SearchBoxTemplate eats OS-level auto-repeat OnKeyDown, so unlike a
-- plain EditBox we can't rely on the OS to walk the list while a key is
-- held. The ticker fires the action at an accelerating cadence.
local navKeyRepeat

local function FindAtlasTexture(frame, atlas)
    if not frame or not frame.GetRegions then return nil end
    for i = 1, frame:GetNumRegions() do
        local region = select(i, frame:GetRegions())
        if region and region.GetAtlas and region.GetObjectType and region:GetObjectType() == "Texture"
           and region:GetAtlas() == atlas then
            return region
        end
    end
    return nil
end

local function RefreshSelectGlows()
    local qmf = Host()
    if not qmf then return end
    local function setGlow(tab, shown)
        if not tab then return end
        local glow = tab._efSelectGlow or tab.SelectedTexture or FindAtlasTexture(tab, SIDE_TAB_SELECT)
        if glow then
            tab._efSelectGlow = glow
            glow:SetShown(shown)
        end
    end
    local searchSelected = selectedIsOurs and activePage == nil
    if selectedIsOurs then
        setGlow(qmf.QuestsTab, false)
        setGlow(qmf.MapLegendTab, false)
        setGlow(qmf.EventsTab, false)
    end
    setGlow(tabFrame, searchSelected)
    if backTab then
        setGlow(backTab, not selectedIsOurs)
        if backTab._efIcon then backTab._efIcon:SetVertexColor(Utils.RGB(selectedIsOurs and TAB_ICON_DIM or TAB_ICON_GOLD)) end
    end
    if tabFrame and tabFrame._efIcon then
        local c = searchSelected and TAB_ICON_GOLD or TAB_ICON_DIM
        tabFrame._efIcon:SetVertexColor(Utils.RGB(c))
    end
    for id, tab in pairs(extraTabs) do
        local on = selectedIsOurs and activePage == id
        setGlow(tab, on)
        if tab._efIcon then tab._efIcon:SetVertexColor(Utils.RGB(on and TAB_ICON_GOLD or TAB_ICON_DIM)) end
    end
end

-- Show one registered page in the panel: an id selects that page, false
-- selects the search page, nil keeps whichever was showing last.
local SEARCH_WIDGETS = { "searchBox", "cog", "scrollFrame", "scrollBar", "emptyMsg", "recentCheck", "expandCheck" }

-- The directions bar: one themed line above the results, shown while a
-- search is up and a keepSearch page has content, leading back to it.
local function UpdatePageBar()
    if not (panel and panel.pageBar) then return end
    local bar = panel.pageBar
    local def, back
    if activePage == nil then
        for i = 1, #pageOrder do
            local d = pages[pageOrder[i]]
            if d and d.keepSearch and d.hasContent and d.hasContent() then def = d break end
        end
    elseif pages[activePage] and pages[activePage].keepSearch then
        -- On the page itself the same bar leads back to the search.
        back = true
    end
    local scrollFrame = panel.scrollFrame
    -- The bar's words in the list's size, as its rows.
    local label = bar._label
    if label then
        local file, _, flags = label:GetFont()
        if file then label:SetFont(file, Scaled(13), flags) end
    end
    if def then
        bar.pageID = def.id
        bar:SetText((def.barText and def.barText()) or def.title or def.id)
        bar:Show()
        if scrollFrame then
            scrollFrame:ClearAllPoints()
            scrollFrame:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -4)
            scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, panel.footH or 28)
        end
    elseif back then
        bar.pageID = false
        bar:SetText(L["MAP_RETURN_SEARCH"])
        bar:Show()
    else
        bar:Hide()
        if scrollFrame then
            scrollFrame:ClearAllPoints()
            scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4)
            scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, panel.footH or 28)
        end
    end
    if panel.emptyMsg then
        panel.emptyMsg:ClearAllPoints()
        panel.emptyMsg:SetPoint("TOPLEFT", scrollFrame or panel, "TOPLEFT", 20, -24)
        panel.emptyMsg:SetPoint("TOPRIGHT", scrollFrame or panel, "TOPRIGHT", -20, -24)
    end
end

local function SelectPage(id)
    if not panel then return end
    if id == false then id = nil elseif id == nil then id = activePage end
    if id and not pages[id] then id = nil end
    activePage = id
    -- A page has its own fields and its return bar: the search bar goes
    -- and the panel takes its strip.
    for i = 1, #SEARCH_WIDGETS do
        local w = panel[SEARCH_WIDGETS[i]]
        if w then w:SetShown(id == nil) end
    end
    if panel.anchor then panel:SetPoint("TOPLEFT", panel.anchor, "TOPLEFT", 0, id and 0 or -29) end
    if id then ns.HideTogglePopup("EasyFindMapTabOptions") end
    UpdatePageBar()
    for pid, def in pairs(pages) do
        if pid == id then
            if not def.frame then
                local f = CreateFrame("Frame", nil, panel)
                f:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4)
                f:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)
                def.frame = f
                if def.build then def.build(f) end
            end
            -- Under the return bar while that shows, else at the panel's top.
            if panel.pageBar and panel.pageBar:IsShown() then
                def.frame:SetPoint("TOPLEFT", panel.pageBar, "BOTTOMLEFT", 0, -4)
            else
                def.frame:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4)
            end
            def.frame:Show()
            if def.onShow then def.onShow(def.frame) end
        elseif def.frame then
            def.frame:Hide()
        end
    end
end

local function ShowOurPanel(pageID)
    if not IsMapSearchEnabled() then return end
    local qmf = Host()
    if not qmf or not panel then return end
    if SidePanel.frame and not SidePanel.Expand() then return end
    selectedIsOurs = true
    lastSelectedWasOurs = true
    -- Must measure before hiding QuestsFrame so GetLeft/GetRight are live.
    if panel.MeasureBlizzardSearch then panel.MeasureBlizzardSearch() end
    -- SetDisplayMode(nil) makes QuestMapFrame formally leave its current
    -- mode. Without this, clicking a Blizzard tab afterwards is a no-op
    -- (same-mode transition) and the panel stays hidden.
    if qmf.SetDisplayMode then
        prevBlizzardDisplayMode = qmf.displayMode
        local ok, err = pcall(qmf.SetDisplayMode, qmf)
        if not ok then
            if qmf.QuestsFrame then qmf.QuestsFrame:Hide() end
            if qmf.EventsFrame then qmf.EventsFrame:Hide() end
            if qmf.MapLegend   then qmf.MapLegend:Hide()   end
            if Utils and Utils.DebugPrint then
                Utils.DebugPrint("MapTab SetDisplayMode failed: " .. tostring(err))
            end
        end
    else
        if qmf.QuestsFrame then qmf.QuestsFrame:Hide() end
        if qmf.EventsFrame then qmf.EventsFrame:Hide() end
        if qmf.MapLegend   then qmf.MapLegend:Hide()   end
    end

    -- Third-party tab frameworks don't react to nil SetDisplayMode, so
    -- their content frames stay visible and tabs stay checked. Tell them
    -- via the public API.
    if LibStub then
        local ok, lwmt = pcall(LibStub, "LibWorldMapTabs", true)
        if ok and lwmt and lwmt.SetDisplayMode then
            pcall(lwmt.SetDisplayMode, lwmt, nil)
        end
    end
    if panel.outer then panel.outer:Show() else panel:Show() end
    if panel.AlignToBlizzardSearch then panel.AlignToBlizzardSearch() end
    SelectPage(pageID)
    RefreshSelectGlows()
    if activePage == nil then
        local sb = panel.searchBox
        MapTab:RunSearch(sb and (sb.GetTypedText and sb:GetTypedText() or sb:GetText()) or "")
    end
end

-- restoreBlizzardMode: true only when our panel is going away with no
-- successor tab (map closed, maximized, or map search disabled) -- then
-- Blizzard's sidebar must get its mode back or it reopens blank. Tab
-- switches pass false: a third-party framework tab also leaves
-- qmf.displayMode nil, and restoring Blizzard's mode over it made the
-- framework clear its fresh selection -- the first click on such a tab
-- showed a blank gray panel until a second click (GitHub #24).
local function HideOurPanel(restoreBlizzardMode)
    if not selectedIsOurs then return end
    selectedIsOurs = false
    if panel then
        if panel.outer then panel.outer:Hide() else panel:Hide() end
        if panel.searchBox then panel.searchBox:ClearFocus() end
    end
    if SidePanel.frame then SidePanel.Collapse() end
    local qmf = Host()
    if restoreBlizzardMode
       and qmf and qmf.SetDisplayMode and qmf.displayMode == nil then
        -- The quest log's mode as its own tab names it: a frame on retail,
        -- a number on WoW Forever.
        local restore = prevBlizzardDisplayMode or (qmf.QuestsTab and qmf.QuestsTab.displayMode) or qmf.QuestsFrame
        if restore then
            restoringBlizzardDisplayMode = true
            pcall(qmf.SetDisplayMode, qmf, restore)
            restoringBlizzardDisplayMode = false
        end
    end
    prevBlizzardDisplayMode = nil
    if ns.MapSearch and ns.MapSearch._previewing then
        if ns.MapSearch.EndHoverPreview then
            ns.MapSearch:EndHoverPreview()
        else
            ns.MapSearch._previewing = nil
            if ns.MapSearch.ClearHighlight then ns.MapSearch:ClearHighlight() end
        end
    end
    if ReleaseMapTabMemory then ReleaseMapTabMemory(true) end
    RefreshSelectGlows()
end

local function PromptAlias(data)
    if ResultHandlers and ResultHandlers.PromptForAlias then
        ResultHandlers:PromptForAlias(data)
    end
end

-- A link to copy, in a box: the game's menus have no copy rows.
local function CopyBox(title, text)
    if not ns.ShowThemedDialog then return end
    ns.ShowThemedDialog({
        text = title,
        messageColor = ns.GOLD_COLOR,
        hasEditBox = true,
        editBoxDefault = text,
        acceptText = _G["OKAY"] or "OK",
        onAccept = function() end,
    })
end

-- The right-click menu as the game draws its own (the tracker's quest
-- menu): the map tab is the game's look throughout. The row stays lit
-- while the menu is up, as the main search rows do, and lets go when the
-- menu closes.
local currentRelease
local function ShowGameMenu(row, isPinned, onPin, onGuide, onAddAlias, data, extra)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return false end
    local name = data and data.name
    if row and row.LockHighlight then row:LockHighlight() end
    local released = false
    local function Release()
        if released then return end
        released = true
        if row and row.UnlockHighlight then row:UnlockHighlight() end
    end
    local ok, menu = pcall(MenuUtil.CreateContextMenu, row or panel or UIParent, function(_, root)
        if name and name ~= "" then root:CreateTitle(name) end
        if extra.onGPS and extra.onGPSFrom then
            local gps = root:CreateButton(L["APP_GPS"])
            gps:CreateButton(L["CTX_GPS_TO"], extra.onGPS)
            gps:CreateButton(L["CTX_GPS_FROM"], extra.onGPSFrom)
        elseif extra.onGPS then
            root:CreateButton(L["CTX_GPS"], extra.onGPS)
        elseif extra.onGPSFrom then
            root:CreateButton(L["CTX_GPS_FROM"], extra.onGPSFrom)
        end
        if onGuide then root:CreateButton(L["CTX_GUIDE"], onGuide) end
        root:CreateButton(isPinned and (_G["RECENT_ALLIES_MENU_BUTTON_LABEL_UNPIN"] or "Unpin")
            or (_G["RECENT_ALLIES_MENU_BUTTON_LABEL_PIN"] or "Pin"), onPin)
        if onAddAlias then root:CreateButton(L["CTX_ADD_ALIAS"], onAddAlias) end
        if extra.sendLink and ns.BuildSendLinkRows then
            local rows = ns.BuildSendLinkRows(extra.sendLink.link)
            if rows then
                local sub = root:CreateButton(L["CTX_SEND_LINK"])
                for i = 1, #rows do
                    local r = rows[i]
                    if r.isSeparator then
                        sub:CreateDivider()
                    elseif r.copy then
                        sub:CreateButton(r.text, function() CopyBox(r.text, r.copy) end)
                    else
                        local b = sub:CreateButton(r.text, r.onClick or function() end)
                        if r.disabled and b.SetEnabled then b:SetEnabled(false) end
                    end
                end
            end
        end
        if extra.wowheadUrl then
            root:CreateButton(L["CTX_WOWHEAD"], function() CopyBox(L["CTX_WOWHEAD"], extra.wowheadUrl) end)
        end
        if root.AddMenuReleasedCallback then root:AddMenuReleasedCallback(Release) end
    end)
    if not ok then
        Release()
        return false
    end
    -- The menu frames are pooled: one hide hook each, releasing whichever
    -- row opened the menu last.
    currentRelease = Release
    if menu and menu.HookScript and not menu._efReleaseHooked then
        menu._efReleaseHooked = true
        menu:HookScript("OnHide", function() if currentRelease then currentRelease() end end)
    end
    return true
end

local function ShowPopup(isPinned, onPin, onGuide, onAddAlias, data, row)
    local extra
    local wowheadUrl = data and ns.GetWowheadLink and ns.GetWowheadLink(data)
    if wowheadUrl then
        extra = { wowheadUrl = wowheadUrl }
    end
    -- Map results have a location but usually no game-object chat link, so the
    -- Send-link menu carries a world map pin the recipient can click to open the
    -- map at this spot.
    local mapPinLink = data and ns.GetMapPinLink and ns.GetMapPinLink(data)
    if mapPinLink then
        extra = extra or {}
        extra.sendLink = { link = mapPinLink }
    end
    if data and EasyFind.API.CallAction("gps", "canNavigate", data) then
        extra = extra or {}
        extra.onGPS = function() EasyFind.API.CallAction("gps", "navigate", data) end
        extra.onGPSFrom = function() EasyFind.API.CallAction("gps", "setStart", data) end
    end
    if ShowGameMenu(row, isPinned, onPin, onGuide, onAddAlias, data, extra or {}) then return end
    Utils.ShowPinMenu("EasyFindPinPopup", isPinned, onPin, onGuide, onAddAlias, {
        strata = "TOOLTIP",
        level = 100,
        width = 96,
        rowHeight = 22,
    }, extra)
end

local function CreateResultRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    -- Click on press, not release: with ButtonUp, WoW's focus-transition
    -- machinery (when the search box is focused) absorbs the mouseUp
    -- before OnClick fires, requiring a second click.
    row:RegisterForClicks("LeftButtonDown", "RightButtonUp")
    row:EnableMouse(true)
    row:HookScript("OnMouseDown", function()
        if panel and panel.searchBox and panel.searchBox.HasFocus and panel.searchBox:HasFocus() then
            panel.searchBox:ClearFocus()
        end
    end)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ROW_ICON_SIZE, ROW_ICON_SIZE)
    icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.icon = icon

    local deleteBtn = Utils.CreateClearButton(row, nil)
    deleteBtn:ClearAllPoints()
    deleteBtn:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    deleteBtn:Hide()
    deleteBtn:SetScript("OnClick", function(self)
        local data = row.data
        if not data or not data.isRecentSearch or not data.query then return end
        local list = EasyFind.db and EasyFind.db.mapTabRecentSearches
        if not list then return end
        local lowerQ = data.query:lower()
        for i = #list, 1, -1 do
            if type(list[i]) == "string" and list[i]:lower() == lowerQ then
                tremove(list, i)
            end
        end
        RefreshCurrentSearch()
    end)
    deleteBtn:SetScript("OnLeave", function(self)
        if not row:IsMouseOver() then self:Hide() end
    end)
    row.deleteBtn = deleteBtn

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    text:SetPoint("RIGHT", deleteBtn, "LEFT", -4, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    row.text = text

    -- One highlight texture covers mouse hover and keyboard selection
    -- (via LockHighlight) so both look identical.
    row:SetHighlightAtlas("QuestLog-quest-glow-yellow")
    local hl = row:GetHighlightTexture()
    if hl then
        hl:SetBlendMode("ADD")
        hl:SetAllPoints(row)
    end

    return row
end

local function SetRowIcon(row, data)
    -- Pooled rows carry their last occupant's size (recent-search rows
    -- shrink to text height). Reset on every placement.
    row.icon:SetSize(Scaled(ROW_ICON_SIZE), Scaled(ROW_ICON_SIZE))
    local icon = data.icon
    -- Dungeon/raid/delve/rare entries leave data.icon nil and rely on
    -- the category icon; resolve it so SetRowIcon matches the MapSearch
    -- dropdown texture.
    if icon == nil and data.category and ns.MapSearch and ns.MapSearch.GetCategoryIcon then
        icon = ns.MapSearch.GetCategoryIcon(data.category)
    end
    Utils.SetIconTexture(row.icon, icon)
    -- A creature wears its own face, drawn by the client from its model.
    if data.displayID and SetPortraitTextureFromCreatureDisplayID then
        SetPortraitTextureFromCreatureDisplayID(row.icon, data.displayID)
    end
    -- A place it can navigate to: the GPS button first, the icon after it.
    local GPS = ns.GPS
    local gps = GPS and GPS.RowButton and GPS.RowButton(row, data, Scaled(ROW_ICON_SIZE))
    row.icon:ClearAllPoints()
    if gps then
        gps:ClearAllPoints()
        gps:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.icon:SetPoint("LEFT", gps, "RIGHT", 4, 0)
    else
        row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    end
end

-- Suppress hover previews briefly after every keystroke: re-renders fire
-- OnEnter for rows that appear under a stationary cursor, which would
-- spuriously preview pins as the user types.
local lastTypeTime = 0
local HOVER_PREVIEW_TYPING_GUARD = 0.3

-- fromKeyboard bypasses the typing guard: keyboard nav is explicit user
-- intent, unlike stray OnEnter when a rendered row lands under a
-- stationary cursor during typing.
local function HoverPreview(data, fromKeyboard)
    if not fromKeyboard and GetTime() - lastTypeTime < HOVER_PREVIEW_TYPING_GUARD then return end
    local MapSearch = ns.MapSearch
    if MapSearch and MapSearch.RunHoverPreview then
        MapSearch:RunHoverPreview(data)
    end
end

local function ClearHoverPreview()
    local MapSearch = ns.MapSearch
    if MapSearch and MapSearch.EndHoverPreview then
        MapSearch:EndHoverPreview()
    end
end

RefreshCurrentSearch = function()
    if not panel or not panel.searchBox then return end
    local sb = panel.searchBox
    MapTab:RunSearch(sb.GetTypedText and sb:GetTypedText() or sb:GetText() or "")
end

-- directOverride is forwarded as `false` by the right-click Guide menu to
-- force breadcrumb/teaching mode regardless of the user's default
-- left-click setting.
local function TriggerResultSelect(data, directOverride)
    local MapSearch = ns.MapSearch
    if MapSearch and MapSearch.SelectResult then MapSearch:SelectResult(data, directOverride) end
    -- Don't re-render: MapTab keeps its list visible after activation so
    -- the user can click/preview adjacent results. OnMapChanged handles
    -- the "This Zone" label refresh.
end

local function RowOnClick(row, button)
    local data = row.data
    if not data then return end
    local MapSearch = ns.MapSearch

    if data.isRecentSearch then
        if data.query and panel and panel.searchBox then
            panel.searchBox:SetText(data.query)
            panel.searchBox:ClearFocus()
        end
        return
    end

    if button == "RightButton" then
        local isPinned = MapSearch and MapSearch:IsMapItemPinned(data)
        ShowPopup(isPinned, function()
            if isPinned then MapSearch:UnpinMapItem(data) else MapSearch:PinMapItem(data) end
            RefreshCurrentSearch()
        end, function() TriggerResultSelect(data, false) end, function() PromptAlias(data) end, data, row)
        return
    end

    MapTab:PushRecentSearch(currentQuery)
    TriggerResultSelect(data)
end

local function RowOnEnter(row)
    local data = row.data
    if not data then return end
    if data.isRecentSearch and row.deleteBtn then
        row.deleteBtn:Show()
        return
    end
    HoverPreview(data)
    -- A vendor found by its goods, not its name, says so.
    if data.soldName then
        GameTooltip:SetOwner(row, "ANCHOR_LEFT")
        GameTooltip:SetText(data.name or "", 1, 1, 1)
        GameTooltip:AddLine(L["MAP_FOUND_BY_SELLS_FMT"]:format(data.soldName), 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end
end
local function RowOnLeave(row)
    if row and row.deleteBtn and not row.deleteBtn:IsMouseOver() then
        row.deleteBtn:Hide()
    end
    ClearHoverPreview()
    GameTooltip:Hide()
end

local function AcquireRow(parent)
    local row = rowPool[rowPoolCursor]
    if row then
        row:SetParent(parent)
    else
        if #rowPool >= MAX_ROW_POOL then return nil end
        row = CreateResultRow(parent)
        row:SetScript("OnClick", RowOnClick)
        row:SetScript("OnEnter", RowOnEnter)
        row:SetScript("OnLeave", RowOnLeave)
        tinsert(rowPool, row)
    end
    rowPoolCursor = rowPoolCursor + 1
    local s = FontScale()
    if row.fontScale ~= s then
        row.fontScale = s
        ScaleFont(row.text, "GameFontNormal", s)
        row:SetHeight(Scaled(ROW_HEIGHT))
    end
    return row
end

local function ReleaseAllRows()
    rowPoolCursor = 1
    for i = 1, #rowPool do rowPool[i]:Hide(); rowPool[i].data = nil end
end

local function CreateSectionLabel(parent)
    local hdr = CreateFrame("Frame", nil, parent)
    hdr:SetHeight(SECTION_HEADER_H)
    local fs = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("CENTER", hdr, "CENTER", 0, 0)
    fs:SetTextColor(Utils.RGB(GOLD_COLOR))
    hdr.label = fs
    local lineLeft = hdr:CreateTexture(nil, "ARTWORK")
    lineLeft:SetHeight(1)
    lineLeft:SetPoint("LEFT", hdr, "LEFT", 6, 0)
    lineLeft:SetPoint("RIGHT", fs, "LEFT", -6, 0)
    lineLeft:SetColorTexture(Utils.RGB(GOLD_COLOR, 0.4))
    local lineRight = hdr:CreateTexture(nil, "ARTWORK")
    lineRight:SetHeight(1)
    lineRight:SetPoint("LEFT", fs, "RIGHT", 6, 0)
    lineRight:SetPoint("RIGHT", hdr, "RIGHT", -6, 0)
    lineRight:SetColorTexture(Utils.RGB(GOLD_COLOR, 0.4))
    return hdr
end

local sectionLabelPool = {}
local sectionLabelPoolCursor = 1

local function AcquireSectionLabel(parent, labelText)
    local hdr = sectionLabelPool[sectionLabelPoolCursor]
    if not hdr then
        hdr = CreateSectionLabel(parent)
        tinsert(sectionLabelPool, hdr)
    else
        hdr:SetParent(parent)
    end
    sectionLabelPoolCursor = sectionLabelPoolCursor + 1
    hdr.label:SetText(labelText or "")
    if hdr.fontScale ~= FontScale() then
        hdr.fontScale = FontScale()
        ScaleFont(hdr.label, "GameFontNormalSmall", hdr.fontScale)
        hdr:SetHeight(Scaled(SECTION_HEADER_H))
    end
    return hdr
end

local function ReleaseAllSectionLabels()
    sectionLabelPoolCursor = 1
    for i = 1, #sectionLabelPool do sectionLabelPool[i]:Hide() end
end

local function CreateGroupHeader(parent)
    local hdr = CreateFrame("Button", nil, parent)
    hdr:SetHeight(GROUP_HEADER_H)
    -- See CreateResultRow: press to bypass focus-transition absorption.
    hdr:RegisterForClicks("LeftButtonDown", "RightButtonUp")
    hdr:HookScript("OnMouseDown", function()
        if panel and panel.searchBox and panel.searchBox.HasFocus and panel.searchBox:HasFocus() then
            panel.searchBox:ClearFocus()
        end
    end)

    local bg = hdr:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    local hoverOverlay = hdr:CreateTexture(nil, "ARTWORK", nil, -1)
    hoverOverlay:SetBlendMode("ADD")
    if not (ns.Caps and ns.Caps.questLogAtlas == false) then
        bg:SetAtlas("QuestLog-tab")
        hoverOverlay:SetAllPoints()
        hoverOverlay:SetAtlas("QuestLog-tab")
        hoverOverlay:SetAlpha(0.40)
    else
        -- No quest log sheet (Era, MoP Classic): its band drawn plain, a dark
        -- fill in a thin rim.
        bg:SetColorTexture(0.42, 0.38, 0.32, 0.9)
        local fill = hdr:CreateTexture(nil, "BACKGROUND", nil, 1)
        fill:SetPoint("TOPLEFT", 1, -1)
        fill:SetPoint("BOTTOMRIGHT", -1, 1)
        fill:SetColorTexture(0.16, 0.13, 0.10, 0.95)
        hoverOverlay:SetPoint("TOPLEFT", 1, -1)
        hoverOverlay:SetPoint("BOTTOMRIGHT", -1, 1)
        hoverOverlay:SetColorTexture(1, 1, 1, 0.08)
    end
    hoverOverlay:Hide()
    hdr.bg = bg
    hdr.hoverOverlay = hoverOverlay

    local toggleBtn = CreateFrame("Button", nil, hdr)
    toggleBtn:SetSize(26, 25)
    toggleBtn:SetPoint("RIGHT", hdr, "RIGHT", -8, 0)
    toggleBtn:SetFrameLevel(hdr:GetFrameLevel() + 2)
    toggleBtn:RegisterForClicks("LeftButtonDown")
    toggleBtn:HookScript("OnMouseDown", function()
        if panel and panel.searchBox and panel.searchBox.HasFocus and panel.searchBox:HasFocus() then
            panel.searchBox:ClearFocus()
        end
    end)
    toggleBtn:SetHitRectInsets(-10, -10, -6, -6)
    local toggleBtnBg = toggleBtn:CreateTexture(nil, "ARTWORK")
    toggleBtnBg:SetAllPoints()
    toggleBtnBg:SetTexture(796424)
    toggleBtnBg:Hide()
    toggleBtn.btnBg = toggleBtnBg
    local toggleIcon = toggleBtn:CreateTexture(nil, "OVERLAY")
    toggleIcon:SetSize(18, 17)
    toggleIcon:SetPoint("CENTER")
    ns.SetQuestLogToggle(toggleIcon, true)
    toggleBtn.icon = toggleIcon
    toggleBtn:SetHighlightTexture(130757)
    toggleBtn:SetScript("OnEnter", function(self)
        self.btnBg:Show()
        hdr.hoverOverlay:Show()
    end)
    toggleBtn:SetScript("OnLeave", function(self)
        self.btnBg:Hide()
        if not hdr:IsMouseOver() then
            hdr.hoverOverlay:Hide()
            ClearHoverPreview()
        end
    end)
    hdr.toggleBtn = toggleBtn

    local fs = hdr:CreateFontString(nil, "OVERLAY", HEADER_FONT)
    fs:SetPoint("LEFT", hdr, "LEFT", 10, 0)
    fs:SetPoint("RIGHT", toggleBtn, "LEFT", -4, 0)
    fs:SetJustifyH("LEFT")
    fs:SetMaxLines(1)
    fs:SetTextColor(0.60, 0.58, 0.55, 1.0)
    hdr.label = fs

    hdr:SetScript("OnEnter", function(self)
        self.hoverOverlay:Show()
        self.label:SetTextColor(0.90, 0.88, 0.85, 1.0)
        if self.navigateData then HoverPreview(self.navigateData) end
    end)
    hdr:SetScript("OnLeave", function(self)
        if not self.toggleBtn:IsMouseOver() then
            self.hoverOverlay:Hide()
            self.label:SetTextColor(self._matchColor and GOLD_COLOR[1] or 0.60,
                                     self._matchColor and GOLD_COLOR[2] or 0.58,
                                     self._matchColor and GOLD_COLOR[3] or 0.55, 1.0)
            ClearHoverPreview()
        end
    end)

    return hdr
end

-- onToggle defaults to mutating sessionCollapsed[groupKey] (query-scoped
-- collapse state); pinned-parent headers override with a callback that
-- mutates the pin's stored `collapsed` flag instead.
local function AcquireGroupHeader(parent, labelText, groupKey, count, collapsed, navigateData, hasChildren, onToggle, onRightClick)
    local hdr = headerPool[headerPoolCursor]
    if not hdr then
        hdr = CreateGroupHeader(parent)
        tinsert(headerPool, hdr)
    else
        hdr:SetParent(parent)
    end
    headerPoolCursor = headerPoolCursor + 1
    hdr.label:SetText(labelText or "")
    if hdr.fontScale ~= FontScale() then
        hdr.fontScale = FontScale()
        ScaleFont(hdr.label, HEADER_FONT, hdr.fontScale)
        hdr:SetHeight(Scaled(GROUP_HEADER_H))
    end
    ns.SetQuestLogToggle(hdr.toggleBtn.icon, collapsed)
    hdr.toggleBtn:SetShown(hasChildren and true or false)
    hdr.groupKey = groupKey
    hdr.navigateData = navigateData
    hdr._matchColor = navigateData ~= nil
    if navigateData then
        hdr.label:SetTextColor(Utils.RGB(GOLD_COLOR, 1.0))
    else
        hdr.label:SetTextColor(0.60, 0.58, 0.55, 1.0)
    end
    hdr.toggleBtn:SetScript("OnClick", function(_)
        if onToggle then
            onToggle()
        elseif hdr.groupKey then
            sessionCollapsed[hdr.groupKey] = not sessionCollapsed[hdr.groupKey]
            RefreshCurrentSearch()
        end
    end)
    hdr:SetScript("OnClick", function(self, button)
        if self.toggleBtn and self.toggleBtn:IsMouseOver() then return end
        if button == "RightButton" then
            if onRightClick then onRightClick() end
            return
        end
        if self.navigateData then
            TriggerResultSelect(self.navigateData)
        end
    end)
    return hdr
end

local function ReleaseAllHeaders()
    headerPoolCursor = 1
    for i = 1, #headerPool do headerPool[i]:Hide() end
    ReleaseAllSectionLabels()
end

local function DetachFrame(frame)
    if frame and frame.SetParent then
        pcall(frame.SetParent, frame, nil)
    end
end

local function TrimRowPool()
    for i = #rowPool, ROW_POOL_RETAIN + 1, -1 do
        local row = rowPool[i]
        if row then
            row:Hide()
            row.data = nil
            DetachFrame(row)
        end
        rowPool[i] = nil
    end
    rowPoolCursor = 1
end

local function TrimHeaderPool()
    for i = #headerPool, HEADER_POOL_RETAIN + 1, -1 do
        local hdr = headerPool[i]
        if hdr then
            hdr:Hide()
            hdr.navigateData = nil
            hdr.groupKey = nil
            DetachFrame(hdr)
        end
        headerPool[i] = nil
    end
    for i = #sectionLabelPool, SECTION_POOL_RETAIN + 1, -1 do
        local hdr = sectionLabelPool[i]
        if hdr then
            hdr:Hide()
            DetachFrame(hdr)
        end
        sectionLabelPool[i] = nil
    end
    headerPoolCursor = 1
    sectionLabelPoolCursor = 1
end

ReleaseMapTabMemory = function(trimFrames)
    if pendingSearchTimer then CancelPendingSearch() end
    ReleaseAllRows()
    ReleaseAllHeaders()
    if panel and panel.scrollChild then panel.scrollChild:SetHeight(1) end
    if panel and panel.emptyMsg then panel.emptyMsg:Hide() end
    if panel then
        panel.topResultName = nil
        panel.topResultCandidates = nil
    end
    navRowIndex = 0
    if visibleNavRows then wipe(visibleNavRows) end
    if navFrame then Utils.SafeCallMethod(navFrame, "EnableKeyboard", false) end
    if navKeyRepeat then navKeyRepeat.Stop() end
    if trimFrames then
        TrimRowPool()
        TrimHeaderPool()
    end
    if ns.MapSearch and ns.MapSearch.ReleaseIdleSearchMemory then
        ns.MapSearch:ReleaseIdleSearchMemory()
    end
end

-- Returns the SavedVariables pin list directly (not a copy) so mutations
-- to fields like `collapsed` on a pinned parent persist.
local function BuildPinnedSection()
    local pins = EasyFind.db.pinnedMapItems
    if not pins or #pins == 0 then return nil end
    return pins
end

local function GroupBySharedParent(results)
    if not results or #results == 0 then return {} end
    local order, groups = {}, {}
    for i = 1, #results do
        local r = results[i]
        local rMapID = r.mapID or r.zoneMapID or r.entranceMapID or r.parentMapID
        local groupName, groupMapID = GetTopAncestor(rMapID)
        if not groupName or groupName == "" then
            order[#order + 1] = { type = "flat", data = r }
        else
            local g = groups[groupName]
            if not g then
                g = {
                    type = "group", name = groupName, items = {},
                    ancestorMapID = groupMapID, navigateData = nil,
                }
                groups[groupName] = g
                order[#order + 1] = g
            end
            if r.name == groupName then
                -- Result is the parent zone: attach as the header's nav
                -- target instead of rendering a duplicate row.
                g.navigateData = r
            else
                g.items[#g.items + 1] = r
            end
        end
    end
    -- Synthesize navigateData for groups whose parent zone wasn't in the
    -- result set. The header still needs something to click-navigate to.
    for _, e in ipairs(order) do
        if e.type == "group" and not e.navigateData and e.ancestorMapID then
            e.navigateData = {
                name = e.name,
                category = "zone",
                isZone = true,
                zoneMapID = e.ancestorMapID,
                synthesized = true,
            }
        end
    end
    -- A group keeps its header whenever it has a parent zone, so a
    -- continent never displays as a solitary flat row. Single-child
    -- groups without a matching parent collapse to flat.
    for i = 1, #order do
        local e = order[i]
        if e.type == "group" and not e.navigateData and #e.items == 1 then
            order[i] = { type = "flat", data = e.items[1] }
        end
    end
    -- Within each continent group, sub-bucket items by the direct-child
    -- zone of the continent containing them. Zone results become subgroup
    -- headers; everything else gets indented under them. Items that don't
    -- map to a direct child stay loose at the continent level.
    for _, e in ipairs(order) do
        if e.type == "group" and e.items and #e.items > 0 and e.ancestorMapID then
            local subgroups, subgroupOrder, looseItems = {}, {}, {}
            for _, item in ipairs(e.items) do
                local itemMapID = item.mapID or item.zoneMapID or item.entranceMapID or item.parentMapID
                local zoneName, zoneMapID = GetZoneUnderAncestor(itemMapID, e.ancestorMapID)
                if zoneName then
                    local sub = subgroups[zoneName]
                    if not sub then
                        sub = { name = zoneName, mapID = zoneMapID, items = {}, headerData = nil }
                        subgroups[zoneName] = sub
                        subgroupOrder[#subgroupOrder + 1] = sub
                    end
                    if itemMapID == zoneMapID and item.isZone and item.category == "zone" then
                        sub.headerData = item
                    else
                        sub.items[#sub.items + 1] = item
                    end
                else
                    looseItems[#looseItems + 1] = item
                end
            end
            local keptOrder = {}
            for _, sub in ipairs(subgroupOrder) do
                if #sub.items == 0 and sub.headerData then
                    looseItems[#looseItems + 1] = sub.headerData
                elseif #sub.items >= 1 then
                    if not sub.headerData then
                        sub.headerData = {
                            name = sub.name,
                            category = "zone",
                            isZone = true,
                            zoneMapID = sub.mapID,
                            synthesized = true,
                        }
                    end
                    keptOrder[#keptOrder + 1] = sub
                end
            end
            if #keptOrder > 0 then
                e.subgroups = keptOrder
                e.looseItems = looseItems
            end
        end
    end
    return order
end

local function RenderRows(scrollChild, pinned, localEntries, globalEntries, recentList)
    ReleaseAllRows()
    ReleaseAllHeaders()
    -- Rows on screen mean the "no matches" line is stale: a later pass can
    -- fill a list that an earlier one found empty.
    if panel and panel.emptyMsg and ((pinned and #pinned > 0) or (localEntries and #localEntries > 0)
        or (globalEntries and #globalEntries > 0) or (recentList and #recentList > 0)) then
        panel.emptyMsg:Hide()
    end
    -- Reset nav selection: row pool is recycled so a stale frame ref in
    -- visibleNavRows would point at a repositioned/released frame.
    navRowIndex = 0
    wipe(visibleNavRows)
    if navFrame then
        Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
    end
    if navKeyRepeat then navKeyRepeat.Stop() end
    local y = 4
    local collapsedDb = sessionCollapsed

    local function placeRow(data, indent, groupName)
        local row = AcquireRow(scrollChild)
        if not row then return end
        local leftInset = 4 + (indent or 0)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", leftInset, -y)
        row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", -4, -y)
        row.data = data
        if row.UnlockHighlight then row:UnlockHighlight() end
        visibleNavRows[#visibleNavRows + 1] = row
        if row.deleteBtn then row.deleteBtn:Hide() end
        SetRowIcon(row, data)
        local name = data.name or ""
        row.icon:Show()
        if data.isZone then
            row.text:SetTextColor(Utils.RGB(GOLD_COLOR))
        else
            row.text:SetTextColor(1, 1, 1)
        end
        do
            local pathText = data.pathPrefix or ""
            if groupName and pathText ~= "" then
                local prefix = groupName .. " > "
                if pathText:sub(1, #prefix) == prefix then
                    pathText = pathText:sub(#prefix + 1)
                elseif pathText == groupName then
                    pathText = ""
                end
            end
            if pathText ~= "" then
                local last = pathText:match("[^>]+$")
                if last then pathText = last:gsub("^%s+", ""):gsub("%s+$", "") end
            end
            -- A vendor found by what it sells says so in the path's place.
            if data.matchNote then pathText = data.matchNote end
            if pathText ~= "" then
                row.text:SetText(name .. "  |cff808080" .. pathText .. "|r")
            else
                row.text:SetText(name)
            end
        end
        row:Show()
        y = y + Scaled(ROW_HEIGHT)
    end

    local function placeSectionLabel(text)
        local hdr = AcquireSectionLabel(scrollChild, text)
        hdr:ClearAllPoints()
        hdr:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, -y)
        hdr:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", -4, -y)
        hdr:Show()
        y = y + Scaled(SECTION_HEADER_H)
    end

    local function placeGroupHeader(name, groupKey, count, collapsed, navigateData, hasChildren, onToggle, onRightClick, indent)
        local hdr = AcquireGroupHeader(scrollChild, name, groupKey, count, collapsed, navigateData, hasChildren, onToggle, onRightClick)
        hdr:ClearAllPoints()
        local leftInset = 4 + (indent or 0)
        hdr:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", leftInset, -y)
        hdr:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", -4, -y)
        if hdr.hoverOverlay then hdr.hoverOverlay:Hide() end
        visibleNavRows[#visibleNavRows + 1] = hdr
        hdr:Show()
        y = y + Scaled(GROUP_HEADER_H)
    end

    -- Pinning a parent here promotes it into the Pinned section,
    -- carrying its current collapsed state so the pinned copy opens
    -- the way the user was viewing it.
    local function headerRightClick(navigateData, capturedCollapsed)
        if not navigateData then return end
        local MapSearch = ns.MapSearch
        if not MapSearch then return end
        local isPinned = MapSearch:IsMapItemPinned(navigateData)
        ShowPopup(isPinned, function()
            if isPinned then
                MapSearch:UnpinMapItem(navigateData)
            else
                navigateData.collapsed = capturedCollapsed or nil
                MapSearch:PinMapItem(navigateData)
                navigateData.collapsed = nil
            end
            RefreshCurrentSearch()
        end, function() TriggerResultSelect(navigateData, false) end, function() PromptAlias(navigateData) end, navigateData)
    end

    local function renderEntries(entries, sectionKey)
        for _, e in ipairs(entries) do
            if e.type == "flat" then
                placeRow(e.data, 0, nil)
            elseif e.type == "version" then
                -- Same name, multiple mapIDs (Dalaran exists in Northrend
                -- and Broken Isles). Default-collapsed; header navigates
                -- to newest mapID.
                local groupKey = sectionKey .. ":version:" .. e.name
                local stored = collapsedDb[groupKey]
                local collapsed = stored ~= false
                local capturedCollapsed = collapsed
                local onToggle = function()
                    collapsedDb[groupKey] = not capturedCollapsed and true or false
                    RefreshCurrentSearch()
                end
                local nav = e.navigateData
                local onRClick = nav and function() headerRightClick(nav, capturedCollapsed) end or nil
                placeGroupHeader(e.name, groupKey, nil, collapsed, nav, true, onToggle, onRClick)
                if not collapsed then
                    for _, item in ipairs(e.items) do
                        placeRow(item, 18, nil)
                    end
                end
            else
                local groupKey = sectionKey .. ":" .. e.name
                local collapsed = collapsedDb[groupKey] == true
                -- If the parent itself matched (real, not synthesized
                -- navigateData), show ALL world-hierarchy children.
                -- Otherwise show just the matched children: surfacing
                -- every sibling under a continent because one child
                -- matched would be wrong.
                local items
                local usingWorldChildren = false
                local parentMatched = e.navigateData and not e.navigateData.synthesized
                local autoExpand = EasyFind.db.mapTabAutoExpand ~= false
                if parentMatched and e.ancestorMapID and autoExpand then
                    local world = GetWorldChildren(e.ancestorMapID)
                    items = world or e.items
                    usingWorldChildren = world and #world > 0
                else
                    items = e.items
                end
                local hasChildren = items and #items > 0
                local nav = e.navigateData
                local capturedCollapsed = collapsed
                local onRClick = nav and function() headerRightClick(nav, capturedCollapsed) end or nil
                placeGroupHeader(e.name, groupKey, nil, collapsed, nav, hasChildren, nil, onRClick)
                if hasChildren and not collapsed then
                    if not usingWorldChildren and e.subgroups then
                        for _, sub in ipairs(e.subgroups) do
                            local subKey = groupKey .. ":" .. sub.name
                            local subCollapsed = collapsedDb[subKey] == true
                            local subHasChildren = #sub.items > 0
                            local subNav = sub.headerData
                            local subCaptured = subCollapsed
                            local subRClick = subNav and function() headerRightClick(subNav, subCaptured) end or nil
                            placeGroupHeader(sub.name, subKey, nil, subCollapsed, subNav,
                                subHasChildren, nil, subRClick, 18)
                            if subHasChildren and not subCollapsed then
                                for _, item in ipairs(sub.items) do
                                    placeRow(item, 36, sub.name)
                                end
                            end
                        end
                        if e.looseItems then
                            for _, item in ipairs(e.looseItems) do
                                placeRow(item, 18, e.name)
                            end
                        end
                    else
                        -- Group duplicate-named children into nested
                        -- version sub-groups (Arathi Highlands warfront
                        -- variants, Dalaran Crater + revisions, etc.).
                        -- One collapsible header per name; default-
                        -- collapsed; header navigates to highest mapID.
                        local byName, order = {}, {}
                        for _, item in ipairs(items) do
                            local n = item.name or ""
                            local list = byName[n]
                            if not list then
                                list = {}
                                byName[n] = list
                                order[#order + 1] = n
                            end
                            list[#list + 1] = item
                        end
                        for _, n in ipairs(order) do
                            local variants = byName[n]
                            if #variants == 1 then
                                placeRow(variants[1], 18, e.name)
                            else
                                tsort(variants, ZoneMapIDDesc)
                                local subKey = groupKey .. ":var:" .. n
                                local stored = collapsedDb[subKey]
                                local subCollapsed = stored ~= false
                                local subCaptured = subCollapsed
                                local subToggle = function()
                                    collapsedDb[subKey] = not subCaptured and true or false
                                    RefreshCurrentSearch()
                                end
                                local subNav = variants[1]
                                local subRClick = function() headerRightClick(subNav, subCaptured) end
                                placeGroupHeader(n, subKey, nil, subCollapsed, subNav,
                                    true, subToggle, subRClick, 18)
                                if not subCollapsed then
                                    for _, variant in ipairs(variants) do
                                        -- Clone: mutating worldChildrenCache
                                        -- entries would poison the cache.
                                        placeRow({
                                            name = variant.name,
                                            category = variant.category,
                                            isZone = variant.isZone,
                                            zoneMapID = variant.zoneMapID,
                                            zoneMapType = variant.zoneMapType,
                                            icon = variant.icon,
                                            synthesized = variant.synthesized,
                                            pathPrefix = "map #" .. tostring(variant.zoneMapID),
                                        }, 36, n)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if recentList and #recentList > 0 then
        placeSectionLabel(L["MAP_SECTION_RECENT_SEARCHES"])
        for _, query in ipairs(recentList) do
            local row = AcquireRow(scrollChild)
            if row then
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, -y)
                row:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", -4, -y)
                if row.UnlockHighlight then row:UnlockHighlight() end
                visibleNavRows[#visibleNavRows + 1] = row
                row.data = {
                    isRecentSearch = true,
                    query = query,
                    name = query,
                    icon = { file = ns.SEARCH_ICON_TEX, coords = ns.SEARCH_ICON_COORDS },
                }
                SetRowIcon(row, row.data)
                row.icon:Show()
                if row.deleteBtn then row.deleteBtn:Hide() end
                row.text:SetTextColor(0.85, 0.85, 0.85)
                row.text:SetText(query)
                local textH = row.text:GetStringHeight() or 0
                if textH < 8 then textH = 12 end
                row.icon:SetSize(textH, textH)
                row:Show()
                y = y + Scaled(ROW_HEIGHT)
            end
        end
    end
    if pinned and #pinned > 0 then
        placeSectionLabel(L["HEADER_PINNED"])
        for _, d in ipairs(pinned) do
            local renderAsParent = d.isZone and d.zoneMapID
            local children = renderAsParent and GetWorldChildren(d.zoneMapID) or nil
            if renderAsParent and children and #children > 0 then
                local pinRef = d
                local collapsed = pinRef.collapsed == true
                local onToggle = function()
                    pinRef.collapsed = not collapsed
                    RefreshCurrentSearch()
                end
                local onRightClick = function()
                    local MapSearch = ns.MapSearch
                    if not MapSearch then return end
                    ShowPopup(true, function()
                        MapSearch:UnpinMapItem(pinRef)
                        RefreshCurrentSearch()
                    end, function() TriggerResultSelect(pinRef, false) end, function() PromptAlias(pinRef) end, pinRef)
                end
                placeGroupHeader(pinRef.name, "pinned:" .. pinRef.zoneMapID,
                    nil, collapsed, pinRef, true, onToggle, onRightClick)
                if not collapsed then
                    for _, child in ipairs(children) do
                        placeRow(child, 18, pinRef.name)
                    end
                end
            else
                placeRow(d, 0, nil)
            end
        end
    end
    if localEntries and #localEntries > 0 then
        local currentMapID = WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
        local currentMapInfo = currentMapID and GetMapInfo and GetMapInfo(currentMapID)
        local sectionLabel = currentMapInfo and L["MAP_SECTION_THIS_ZONE_NAMED"]:format(currentMapInfo.name) or L["MAP_SECTION_THIS_ZONE"]
        placeSectionLabel(sectionLabel)
        renderEntries(localEntries, "local")
    end
    if globalEntries and #globalEntries > 0 then
        placeSectionLabel(L["MAP_SECTION_ACROSS_WORLD"])
        renderEntries(globalEntries, "global")
    end
    scrollChild:SetHeight(mmax(1, y + 4))
end

-- ZONE results with these mapTypes are too coarse to be "local"
-- (continents are direct children of the Azeroth world map but aren't
-- meaningfully "in this zone").
local EXCLUDE_FROM_LOCAL_MAPTYPES = {}
if Enum and Enum.UIMapType then
    EXCLUDE_FROM_LOCAL_MAPTYPES[Enum.UIMapType.Cosmic] = true
    EXCLUDE_FROM_LOCAL_MAPTYPES[Enum.UIMapType.World] = true
    EXCLUDE_FROM_LOCAL_MAPTYPES[Enum.UIMapType.Continent] = true
end

local function ResultDedupeKey(r)
    if not r then return "" end
    local name = r.name or ""
    if r.category == "flightmaster" then
        return "fm:" .. name
    end
    if r.isDungeonEntrance then
        return "instance:" .. tostring(r.entranceMapID or r.mapID or r.coordMapID or 0)
            .. ":" .. name
    end
    if r.isZone and r.zoneMapID then
        return "zone:" .. tostring(r.zoneMapID)
    end
    local mapID = r.mapID or r.coordMapID or r.entranceMapID
        or r.zoneMapID or r.parentMapID or 0
    local x = r.x or r.entranceX or 0
    local y = r.y or r.entranceY or 0
    return tostring(r.category or "location") .. ":" .. tostring(mapID)
        .. ":" .. name .. ":" .. tostring(x) .. ":" .. tostring(y)
end

local function IsMapTabAliasData(data)
    return data and (data.mapSearchResult or data.isZone or data.isDungeonEntrance
        or data.zoneMapID or data.entranceMapID
        or (data.category and (data.x or data.entranceX or data.mapID or data.coordMapID)))
end

local function ResultIsOnViewedMap(data, viewedMapID)
    if not data or not viewedMapID then return false end
    return data.mapID == viewedMapID
        or data.coordMapID == viewedMapID
        or data.entranceMapID == viewedMapID
        or data.zoneMapID == viewedMapID
        or data.parentMapID == viewedMapID
end

-- isLocal=true also excludes continent-level zone results so "This Zone"
-- doesn't list entire continents.
local function FilterAndDedupe(results, seen, isLocal)
    local filters = EasyFind.db.mapTabFilters or {}
    -- The continent exclusion keeps OTHER continents out of "This Zone";
    -- the viewed map itself must stay so searching its own name matches.
    local viewedMapID = isLocal and WorldMapFrame and WorldMapFrame.GetMapID
        and WorldMapFrame:GetMapID() or nil
    local out = {}
    if not results then return out end
    for i = 1, #results do
        local r = results[i]
        if r and not r.isPinHeader then
            -- A zone row from a source that carried no map type is looked
            -- up: a continent nested inside a continent (Quel'Thalas
            -- under the Eastern Kingdoms) must fall out of "This Zone"
            -- here, unmarked, or the global pass drops it as a duplicate
            -- and it shows nowhere.
            local zoneType = r.zoneMapType
            if isLocal and r.isZone and zoneType == nil and r.zoneMapID and GetMapInfo then
                local info = GetMapInfo(r.zoneMapID)
                zoneType = info and info.mapType
            end
            local excludeLocal = isLocal and r.isZone and zoneType
                and EXCLUDE_FROM_LOCAL_MAPTYPES[zoneType]
                and r.zoneMapID ~= viewedMapID
            if not excludeLocal then
                -- FMs are scanned both locally and globally with different
                -- (x,y) per scan. Key by name so the local pass claims
                -- first and the global pass dedupes cleanly.
                local key = ResultDedupeKey(r)
                if not seen[key] then
                    seen[key] = true
                    if ns.MapSearch.PassesFilter(r, filters) then
                        out[#out + 1] = r
                    end
                end
            end
        end
    end
    return out
end

-- Token must be lowercase. Checks name, keywords, category (with plural
-- flex), pathPrefix, ancestor names; falls back to abbrev expansion so
-- "nr" resolves against "northrend".
local function POIMatchesToken(poi, t)
    if poi.name and poi.name:lower():find(t, 1, true) then return true end
    if poi.keywords then
        for i = 1, #poi.keywords do
            if poi.keywords[i]:lower():find(t, 1, true) then return true end
        end
    end
    if poi.category then
        local c = poi.category:lower()
        if c == t or c == t .. "s" then return true end
        if #t > 1 and t:sub(-1) == "s" and c == t:sub(1, -2) then return true end
    end
    if poi.pathPrefix and poi.pathPrefix:lower():find(t, 1, true) then return true end
    local mapID = poi.mapID or poi.zoneMapID or poi.entranceMapID
    local names = GetAncestorNames(mapID)
    for i = 1, #names do
        if names[i]:find(t, 1, true) then return true end
    end
    local expanded = ExpandZoneAbbrev(t)
    if expanded then
        if poi.name and poi.name:lower():find(expanded, 1, true) then return true end
        for i = 1, #names do
            if names[i]:find(expanded, 1, true) then return true end
        end
    end
    return false
end

-- Per token, build a candidate set; union by identity; keep only POIs
-- where every token matches some facet. Enables "northrend raid",
-- "org fp", "dalaran bank".
local function BuildMultiTokenResults(tokens, isGlobal)
    local MapSearch = ns.MapSearch
    if not MapSearch or not MapSearch.BuildResults then return {} end
    local seenKeys = SEARCH_SCRATCH.seenKeys
    local candidates = SEARCH_SCRATCH.multiTokenCandidates
    wipe(seenKeys)
    wipe(candidates)
    for _, tok in ipairs(tokens) do
        local perRef = MapSearch:BuildResults(tok, isGlobal, true)
        for i = 1, #perRef do
            local r = perRef[i]
            local k = (r.mapID or 0) .. ":" .. (r.name or "")
                   .. ":" .. (r.x or 0) .. ":" .. (r.y or 0)
                   .. ":" .. (r.category or "")
            if not seenKeys[k] then
                seenKeys[k] = true
                candidates[#candidates + 1] = r
            end
        end
    end
    local tokensLower = {}
    for i, tok in ipairs(tokens) do tokensLower[i] = tok:lower() end
    local out = {}
    for _, r in ipairs(candidates) do
        local matches = true
        for i = 1, #tokensLower do
            if not POIMatchesToken(r, tokensLower[i]) then
                matches = false
                break
            end
        end
        if matches then out[#out + 1] = r end
    end
    return out
end

function MapTab:RunSearch(text)
    if not panel then return end
    text = text or ""
    if activePage and pages[activePage] and pages[activePage].keepSearch and text ~= currentQuery then
        SelectPage(false)
        RefreshSelectGlows()
    end
    currentQuery = text
    lastQueryGen = lastQueryGen + 1
    local myGen = lastQueryGen
    local scrollChild = panel.scrollChild
    local scrollFrame = panel.scrollFrame
    local MapSearch = ns.MapSearch
    local pinned = BuildPinnedSection()
    local aliasMatches
    if ns.Aliases and text ~= "" then
        aliasMatches = ns.Aliases:GetMatches(text:lower())
    end

    -- Preserve scroll on refresh paths (pin toggle, collapse, filter).
    -- Reset to top on a fresh query.
    local preserveScroll = scrollFrame and text == lastRenderedQuery
    local savedScroll = preserveScroll and scrollFrame:GetVerticalScroll() or 0
    lastRenderedQuery = text
    local function restoreScroll()
        if not scrollFrame then return end
        local maxScroll = mmax(0, (scrollChild:GetHeight() or 0) - (scrollFrame:GetHeight() or 0))
        scrollFrame:SetVerticalScroll(mmin(savedScroll, maxScroll))
    end

    -- Reset collapse state on text change so each new search starts with
    -- every matched parent auto-expanded. Same-text refreshes preserve.
    if text ~= sessionCollapsedQuery then
        wipe(sessionCollapsed)
        sessionCollapsedQuery = text
    end

    if #text < 2 and not aliasMatches then
        local showRecent = EasyFind.db.mapTabShowRecent
        local recentList = showRecent and EasyFind.db.mapTabRecentSearches
        local limit = MapTab.GetRecentLimit and MapTab.GetRecentLimit() or 3
        if recentList and #recentList > limit then
            local trimmed = {}
            for i = 1, limit do trimmed[i] = recentList[i] end
            recentList = trimmed
        end
        local hasRecent = recentList and #recentList > 0
        if pinned or hasRecent then
            RenderRows(scrollChild, pinned, nil, nil, hasRecent and recentList or nil)
        else
            ReleaseAllRows(); ReleaseAllHeaders()
            scrollChild:SetHeight(1)
        end
        panel.emptyMsg:Hide()
        panel.topResultName = nil
        panel.topResultCandidates = nil
        restoreScroll()
        return
    end
    panel.emptyMsg:Hide()
    if not MapSearch or not MapSearch.BuildResults then
        ReleaseAllRows(); ReleaseAllHeaders(); return
    end

    -- Multi-token queries switch to per-token matching with ancestor
    -- awareness so "northrend raid" means "raids under Northrend".
    local tokens = SEARCH_SCRATCH.tokens
    wipe(tokens)
    for tok in text:gmatch("%S+") do tokens[#tokens + 1] = tok end
    local multiToken = #tokens > 1

    -- BuildResults returns a reusable module-level table; the second
    -- call wipes it. Shallow-copy before calling again.
    local seen = SEARCH_SCRATCH.seen
    wipe(seen)
    local localRaw
    if multiToken then
        localRaw = BuildMultiTokenResults(tokens, false)
    else
        local localRawRef = MapSearch:BuildResults(text, false, true)
        localRaw = {}
        for i = 1, #localRawRef do localRaw[i] = localRawRef[i] end
    end
    if myGen ~= lastQueryGen then return end
    -- Local-first dedup so a POI in the current zone wins local ownership.
    local localFiltered = FilterAndDedupe(localRaw, seen, true)
    local localEntries
    local globalRaw
    if multiToken then
        globalRaw = BuildMultiTokenResults(tokens, true)
    else
        globalRaw = MapSearch:BuildResults(text, true, true)
    end
    if myGen ~= lastQueryGen then return end
    local globalFiltered = FilterAndDedupe(globalRaw, seen, false)

    if aliasMatches then
        local viewedMapID = WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
        for i = #aliasMatches, 1, -1 do
            local data = aliasMatches[i] and aliasMatches[i].data
            if IsMapTabAliasData(data) then
                local key = ResultDedupeKey(data)
                if not seen[key] then
                    seen[key] = true
                    if ResultIsOnViewedMap(data, viewedMapID) then
                        tinsert(localFiltered, 1, data)
                    else
                        tinsert(globalFiltered, 1, data)
                    end
                end
            end
        end
    end

    -- When viewing a single zone, every "This Zone" result is in that zone and
    -- the section header already names it, so a continent > zone tree just
    -- restates the header. Group only when the viewed map is broad (continent/
    -- world), where results genuinely span multiple zones.
    local viewedMapID = WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
    local viewedInfo = viewedMapID and GetMapInfo and GetMapInfo(viewedMapID)
    if viewedInfo and EXCLUDE_FROM_LOCAL_MAPTYPES[viewedInfo.mapType] then
        localEntries = GroupBySharedParent(localFiltered)
        -- A continent-type zone match (e.g. EK while viewing EK) gets
        -- dropped from local by EXCLUDE_FROM_LOCAL_MAPTYPES, leaving its
        -- group with synthesized navigateData so auto-expand never fires.
        -- Promote the synthesized header back to the real result.
        for i = 1, #localRaw do
            local r = localRaw[i]
            if r and r.isZone and r.zoneMapID then
                for j = 1, #localEntries do
                    local e = localEntries[j]
                    if e.type == "group" and e.ancestorMapID == r.zoneMapID
                       and e.navigateData and e.navigateData.synthesized then
                        e.navigateData = r
                    end
                end
            end
        end
    else
        -- Single zone (or smaller): list the POIs flat, no redundant headers.
        localEntries = {}
        for i = 1, #localFiltered do
            localEntries[#localEntries + 1] = { type = "flat", data = localFiltered[i] }
        end
    end

    -- Duplicate-named zones collapse into one header that lists every
    -- variant (highest mapID first as "newest"). Header starts collapsed
    -- and navigates to the newest variant.
    local versionGroups
    do
        local byName = {}
        for i = 1, #globalFiltered do
            local r = globalFiltered[i]
            if r and r.isZone and r.zoneMapID and r.name then
                local key = r.name:lower()
                local list = byName[key]
                if not list then list = {}; byName[key] = list end
                list[#list + 1] = r
            end
        end
        local removed = {}
        for _, list in pairs(byName) do
            if #list >= 2 then
                tsort(list, ZoneMapIDDesc)
                for j = 1, #list do removed[list[j]] = true end
                versionGroups = versionGroups or {}
                versionGroups[#versionGroups + 1] = {
                    type = "version",
                    name = list[1].name,
                    items = list,
                    navigateData = list[1],
                }
            end
        end
        if versionGroups then
            local kept = {}
            for i = 1, #globalFiltered do
                if not removed[globalFiltered[i]] then
                    kept[#kept + 1] = globalFiltered[i]
                end
            end
            globalFiltered = kept
        end
    end

    local globalEntries = GroupBySharedParent(globalFiltered)
    if versionGroups then
        for i = #versionGroups, 1, -1 do
            tinsert(globalEntries, 1, versionGroups[i])
        end
    end

    -- 'This zone' already covers the viewed continent, so drop any
    -- global group whose continent matches it.
    if viewedMapID then
        for i = #globalEntries, 1, -1 do
            local e = globalEntries[i]
            if e.type == "group" and e.ancestorMapID == viewedMapID then
                tremove(globalEntries, i)
            end
        end
    end

    -- Ghost/Tab picks the first NAME whose lowercase prefix matches the
    -- typed text, so a fuzzy-winning non-prefix doesn't shadow a slightly
    -- lower-scored prefix match. Stash a window of candidates here.
    local CANDIDATE_CAP = 12
    local candidates = SEARCH_SCRATCH.candidateNames
    wipe(candidates)
    if localFiltered then
        for i = 1, mmin(#localFiltered, CANDIDATE_CAP) do
            if localFiltered[i] and localFiltered[i].name then
                candidates[#candidates + 1] = localFiltered[i].name
            end
        end
    end
    for i = 1, mmin(#globalFiltered, CANDIDATE_CAP) do
        if globalFiltered[i] and globalFiltered[i].name then
            candidates[#candidates + 1] = globalFiltered[i].name
        end
    end
    panel.topResultCandidates = candidates
    panel.topResultName = candidates[1]

    RenderRows(scrollChild, pinned, localEntries, globalEntries)

    -- Behind a page (the GPS) the results are hidden, and so is their empty line.
    if activePage == nil and (not pinned or #pinned == 0)
       and (not localFiltered or #localFiltered == 0) and #globalFiltered == 0 then
        panel.emptyMsg:SetText("|cff999999" .. L["MAP_NO_MATCHES"] .. "|r")
        panel.emptyMsg:Show()
    end
    restoreScroll()
end

-- The open query again, once a source it searched has finished loading.
function MapTab:RefreshSearch()
    if panel and panel:IsShown() and currentQuery ~= "" then MapTab:RunSearch(currentQuery) end
end

-- Search box captures arrow / Alt+J/K / Enter / Esc while focused and
-- falls back to typing. Navigating down hands focus to navFrame, which
-- captures j/k/Enter/Esc so the user can keep moving without reclaiming
-- the editbox. Re-typing or Esc hands focus back.

local HandleNavKey
local RefocusSearchBox
local RefocusSearchBoxAfterAltNav

local function StopNavRepeatAndRefocus(key)
    local navKey = Utils.NormalizeKey(key)
    if not (navKeyRepeat and navKeyRepeat.IsKey(navKey)) then return end
    navKeyRepeat.Stop(navKey)
    if navRowIndex ~= 0 then return end
    if navKey == "J" or navKey == "K" then
        RefocusSearchBoxAfterAltNav(navKey)
    else
        RefocusSearchBox()
    end
end

local function EnsureNavFrame()
    if navFrame then return navFrame end
    if not panel then return nil end
    navFrame = CreateFrame("Frame", nil, panel)
    Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
    Utils.SafeCallMethod(navFrame, "SetPropagateKeyboardInput", true)
    navFrame:SetScript("OnKeyDown", function(self, key)
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", not HandleNavKey(key, false))
    end)
    navFrame:SetScript("OnKeyUp", function(_, key)
        StopNavRepeatAndRefocus(key)
    end)
    navKeyRepeat = Utils.CreateKeyRepeat(navFrame)
    return navFrame
end

local function UpdateNavHighlight()
    for i = 1, #visibleNavRows do
        local f = visibleNavRows[i]
        if f then
            local selected = (i == navRowIndex)
            if f.hoverOverlay then
                f.hoverOverlay:SetShown(selected)
                if f.label then
                    if selected then
                        f.label:SetTextColor(0.90, 0.88, 0.85, 1.0)
                    elseif not f:IsMouseOver()
                       and not (f.toggleBtn and f.toggleBtn:IsMouseOver()) then
                        local g = f._matchColor
                        f.label:SetTextColor(
                            g and GOLD_COLOR[1] or 0.60,
                            g and GOLD_COLOR[2] or 0.58,
                            g and GOLD_COLOR[3] or 0.55, 1.0)
                    end
                end
            elseif f.LockHighlight then
                if selected then f:LockHighlight() else f:UnlockHighlight() end
            end
        end
    end
    if navRowIndex > 0 and panel and panel.scrollFrame then
        local f = visibleNavRows[navRowIndex]
        if f then Utils.ScrollToButton(panel.scrollFrame, f) end
    end
    if navRowIndex > 0 then
        local f = visibleNavRows[navRowIndex]
        local data = f and (f.data or f.navigateData)
        if data then
            HoverPreview(data, true)
        else
            ClearHoverPreview()
        end
    else
        ClearHoverPreview()
    end
end

local function SetNavFrameCapture(on)
    local nf = EnsureNavFrame()
    if not nf then return end
    Utils.SafeCallMethod(nf, "EnableKeyboard", on and true or false)
    -- A missed OnKeyUp (e.g. click on map mid-hold) would leave the
    -- ticker firing the move action next time navFrame became visible.
    if not on and navKeyRepeat then navKeyRepeat.Stop() end
end

RefocusSearchBox = function()
    if navRowIndex ~= 0 then return end
    if not (panel and panel.searchBox) then return end
    panel.searchBox._blockAutoFocus = nil
    panel.searchBox:SetFocus()
end

RefocusSearchBoxAfterAltNav = function(key)
    Utils.ScheduleAfterAltNavRelease(key, RefocusSearchBox)
end

local function SetNavRowIndex(i)
    if i < 0 then i = 0 end
    if i > #visibleNavRows then i = #visibleNavRows end
    navRowIndex = i
    UpdateNavHighlight()
end

local function MoveNavSelection(delta)
    if #visibleNavRows == 0 then return false end
    local newIdx = navRowIndex + delta
    if newIdx < 1 then newIdx = 1 end
    if newIdx > #visibleNavRows then newIdx = #visibleNavRows end
    if newIdx == navRowIndex then return false end
    SetNavRowIndex(newIdx)
    return true
end

local function MoveNavSelectionUpOrExit()
    if #visibleNavRows == 0 then return false end
    if navRowIndex <= 1 then
        SetNavRowIndex(0)
        SetNavFrameCapture(false)
        return false
    end
    return MoveNavSelection(-1)
end

local function FindFirstNavRowIndex()
    local fallback
    for i = 1, #visibleNavRows do
        local row = visibleNavRows[i]
        local data = row and (row.data or row.navigateData)
        if data then
            if not fallback then fallback = i end
            if not data.isRecentSearch and not data.isPinned then return i end
        end
    end
    return fallback
end

local function SelectFirstNavRow()
    local idx = FindFirstNavRowIndex()
    if not idx then return false end
    if panel and panel.searchBox then panel.searchBox:ClearFocus() end
    SetNavFrameCapture(true)
    SetNavRowIndex(idx)
    return true
end

local function ActivateNavSelection()
    if navRowIndex == 0 then return false end
    local f = visibleNavRows[navRowIndex]
    if not f then return false end
    local handler = f:GetScript("OnClick")
    if handler then
        handler(f, "LeftButton")
        return true
    end
    return false
end

-- keepSearchFocus is true from editbox OnKeyDown, false from navFrame.
HandleNavKey = function(key, keepSearchFocus)
    local delta, altNav, navKey = Utils.GetVerticalNavIntent(key)
    if delta == 1 then
        if #visibleNavRows == 0 then return false end
        if keepSearchFocus and panel and panel.searchBox then
            panel.searchBox:ClearFocus()
        end
        SetNavFrameCapture(true)
        if altNav then
            Utils.StartAltNavRepeat(navKeyRepeat, navKey, panel and panel.searchBox,
                function() return MoveNavSelection(1) end)
        else
            Utils.StartKeyRepeatOnce(navKeyRepeat, navKey, function()
                return MoveNavSelection(1)
            end)
        end
        return true
    elseif delta == -1 then
        if #visibleNavRows == 0 then return false end
        -- Up from the first row exits back to the search box.
        if navRowIndex <= 1 then
            SetNavRowIndex(0)
            SetNavFrameCapture(false)
            if keepSearchFocus then
                if altNav then Utils.SuppressNextAltNavChar(panel and panel.searchBox, navKey) end
            elseif altNav then
                RefocusSearchBoxAfterAltNav(navKey)
            else
                RefocusSearchBox()
            end
            return true
        end
        if keepSearchFocus and panel and panel.searchBox then
            panel.searchBox:ClearFocus()
        end
        SetNavFrameCapture(true)
        if altNav then
            Utils.StartAltNavRepeat(navKeyRepeat, navKey, panel and panel.searchBox,
                MoveNavSelectionUpOrExit,
                RefocusSearchBox)
        else
            Utils.StartKeyRepeatOnce(navKeyRepeat, navKey, function()
                local moved = MoveNavSelectionUpOrExit()
                if not moved and navRowIndex == 0 then RefocusSearchBox() end
                return moved
            end)
        end
        return true
    elseif key == "SPACE" then
        -- Space in the editbox is a literal character; in navFrame it
        -- toggles the highlighted group header's collapse.
        if keepSearchFocus then return false end
        if navRowIndex > 0 then
            local f = visibleNavRows[navRowIndex]
            if f and f.toggleBtn and f.toggleBtn:IsShown() then
                -- Toggle triggers a refresh that wipes visibleNavRows.
                -- Snapshot groupKey and reselect after re-render so the
                -- user can spam Space without losing selection.
                local savedGroupKey = f.groupKey
                local handler = f.toggleBtn:GetScript("OnClick")
                if handler then handler(f.toggleBtn) end
                if savedGroupKey then
                    for i = 1, #visibleNavRows do
                        if visibleNavRows[i].groupKey == savedGroupKey then
                            SetNavRowIndex(i)
                            SetNavFrameCapture(true)
                            break
                        end
                    end
                end
            end
            return true
        end
        return false
    elseif key == "ENTER" then
        if navRowIndex > 0 then
            ActivateNavSelection()
            -- Mirror mouse-click flow: unfocus searchBox, drop nav
            -- selection, disable navFrame keyboard. Otherwise the next
            -- Esc would refocus the bar instead of closing the map.
            SetNavRowIndex(0)
            SetNavFrameCapture(false)
            if panel and panel.searchBox then panel.searchBox:ClearFocus() end
            return true
        end
        return SelectFirstNavRow()
    elseif key == "ESCAPE" then
        if not keepSearchFocus then
            -- First Esc clears selection and refocuses search; second
            -- (nothing highlighted) propagates so the map closes.
            if navRowIndex > 0 then
                SetNavRowIndex(0)
                SetNavFrameCapture(false)
                if panel and panel.searchBox then panel.searchBox:SetFocus() end
                return true
            end
            return false
        else
            if panel and panel.searchBox then panel.searchBox:ClearFocus() end
            return true
        end
    end
    return false
end

local function CreateSearchBox(parent)
    local editBox = CreateFrame("EditBox", nil, parent, "SearchBoxTemplate")
    editBox:SetSize(301, 20)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(60)
    if editBox.Instructions then
        -- Some locales render the descriptive placeholder wider than the
        -- box; fall back to Blizzard's plain "Search" when it can't fit.
        -- Re-checked on resize since the box is re-anchored after layout.
        local function FitPlaceholder()
            local instructions = editBox.Instructions
            instructions:SetText(L["MAP_SEARCH_PLACEHOLDER"])
            local avail = instructions:GetWidth() or 0
            local getter = instructions.GetUnboundedStringWidth or instructions.GetStringWidth
            if avail > 0 and getter(instructions) > avail then
                instructions:SetText(_G["SEARCH"] or "Search")
            end
        end
        FitPlaceholder()
        editBox:HookScript("OnSizeChanged", FitPlaceholder)
        Utils.SafeAfter(0, FitPlaceholder)
        editBox.FitPlaceholder = FitPlaceholder
    end

    -- WoW silently focuses visible EditBoxes after creation despite
    -- SetAutoFocus(false). On /reload with WorldMap open, this editbox
    -- auto-focuses; its OnKeyDown sets SetPropagateKeyboardInput(false)
    -- for every key, silently eating SPACE/WASD even though the bar
    -- looks unfocused. Reject focus within the first couple frames.
    editBox._blockAutoFocus = true
    editBox:HookScript("OnEditFocusGained", function(self)
        if self._blockAutoFocus then self:ClearFocus() end
    end)
    editBox:HookScript("OnMouseDown", function(self) self._blockAutoFocus = nil end)
    editBox:ClearFocus()
    SafeAfter(0, function()
        SafeAfter(0, function()
            if editBox then editBox._blockAutoFocus = nil; editBox:ClearFocus() end
        end)
    end)

    local function UpdateClear(self)
        if self.clearButton then
            self.clearButton:SetShown(self:HasFocus() or self:GetText() ~= "")
        end
    end

    -- SearchBoxTemplate's clear button only clears text+focus; without
    -- this hook the list re-renders to its "empty query" state (pinned
    -- + recent), which feels like the clear didn't take.
    if editBox.clearButton then
        editBox.clearButton:HookScript("OnClick", function()
            if ReleaseMapTabMemory then ReleaseMapTabMemory(false) end
        end)
    end

    local function FindPrefixCandidate(q)
        if not panel or q == "" then return nil end
        local qLower = q:lower()
        local list = panel.topResultCandidates
        if not list then return nil end
        for i = 1, #list do
            local name = list[i]
            if name and #name >= #q
               and name:sub(1, #q):lower() == qLower
               and name:lower() ~= qLower then
                return name
            end
        end
        return nil
    end
    editBox.FindPrefixCandidate = FindPrefixCandidate

    Utils.AttachAltNavCharSuppressor(editBox, function(self, restoredText)
        UpdateClear(self)
        if pendingSearchTimer then CancelPendingSearch() end
        if currentQuery ~= restoredText then MapTab:RunSearch(restoredText or "") end
    end)

    Utils.AttachAutocomplete(editBox, {
        enabled = function() return EasyFind.db.mapTabAutocomplete ~= false end,
        findCandidate = FindPrefixCandidate,
        onTypedChanged = function(self, typed, _, grew)
            lastTypeTime = GetTime()
            UpdateClear(self)
            SchedulePendingSearch(self, typed, grew)
        end,
        onAccepted = function(text, source)
            if text and text ~= "" then MapTab:RunSearch(text) end
            if source ~= "right" and source ~= "alt-l" and source ~= "click" then
                MapTab:PushRecentSearch(text)
            end
        end,
    })
    editBox:HookScript("OnEditFocusGained", UpdateClear)
    editBox:HookScript("OnEditFocusLost", function(self)
        UpdateClear(self)
    end)

    -- WoW editboxes default to propagating every keystroke to the
    -- binding system, firing player keybinds while the user types.
    -- Always clamp propagation to false at the end.
    editBox:HookScript("OnKeyDown", function(self, key)
        local navKey = Utils.NormalizeKey(key)
        if IsAltKeyDown() and navKey and navKey:match("^[A-Z]$") then
            Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
        end
        if IsAltKeyDown() and (navKey == "J" or navKey == "K") then
            Utils.SuppressNextAltNavChar(self, navKey)
        end
        if self.HasAutocomplete and self:HasAutocomplete() and self.AcceptAutocomplete then
            if navKey == "RIGHT" or navKey == "ARROWRIGHT" then
                self:AcceptAutocomplete("right")
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
                return
            elseif navKey == "L" and IsAltKeyDown() then
                self:AcceptAutocomplete("alt-l")
                Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
                return
            end
        end
        if pendingSearchTimer
           and (navKey == "DOWN" or navKey == "UP" or navKey == "ENTER"
                or (IsAltKeyDown() and (navKey == "J" or navKey == "K"))) then
            RunPendingSearchNow()
        end
        HandleNavKey(navKey, true)
        Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)
    end)
    -- WoW pairs OnKeyUp to the original frame regardless of focus
    -- changes mid-press, so the navFrame handler isn't always reached.
    editBox:HookScript("OnKeyUp", function(_, key)
        StopNavRepeatAndRefocus(key)
    end)

    -- SearchBoxTemplate doesn't always grab focus cleanly after clicks
    -- around results or map pins; explicit SetFocus makes the caret
    -- reappear every time.
    editBox:HookScript("OnMouseDown", function(self)
        self:SetFocus()
        if navFrame then
            Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
        end
        if navKeyRepeat then navKeyRepeat.Stop() end
        navRowIndex = 0
    end)
    editBox:HookScript("OnEditFocusGained", function()
        if navFrame then
            Utils.SafeCallMethod(navFrame, "EnableKeyboard", false)
        end
        if navKeyRepeat then navKeyRepeat.Stop() end
        if ns.GPSNpcs and ns.GPSNpcs.Warm then ns.GPSNpcs.Warm() end
    end)

    editBox:HookScript("OnEnterPressed", function(self)
        if navRowIndex > 0 then return end
        RunPendingSearchNow()
        local current = self:GetText() or ""
        local typed = self.GetTypedText and self:GetTypedText() or current
        local accepted = false
        if self.HasAutocomplete and self:HasAutocomplete() and self.AcceptAutocomplete then
            accepted = self:AcceptAutocomplete()
            current = self:GetText() or ""
        elseif current ~= "" and current ~= typed and self.AcceptAutocomplete then
            accepted = self:AcceptAutocomplete()
            current = self:GetText() or ""
        end
        if not accepted then MapTab:PushRecentSearch(current) end
        if current ~= currentQuery then MapTab:RunSearch(current) end
        SelectFirstNavRow()
    end)
    return editBox
end

local RECENT_ABSOLUTE_MAX = 20
local function GetRecentLimit()
    local n = EasyFind.db and EasyFind.db.mapTabRecentCount
    if type(n) ~= "number" or n < 1 then n = 3 end
    if n > RECENT_ABSOLUTE_MAX then n = RECENT_ABSOLUTE_MAX end
    return n
end
MapTab.GetRecentLimit = GetRecentLimit

function MapTab:RefreshIfOpen()
    if panel and panel:IsShown() and RefreshCurrentSearch then
        RefreshCurrentSearch()
    end
end

function MapTab:PushRecentSearch(text)
    if type(text) ~= "string" then return end
    text = text:match("^%s*(.-)%s*$") or ""
    if #text < 2 then return end
    local db = EasyFind.db
    if not db then return end
    db.mapTabRecentSearches = db.mapTabRecentSearches or {}
    local list = db.mapTabRecentSearches
    local lowerNew = text:lower()
    for i = #list, 1, -1 do
        if type(list[i]) == "string" and list[i]:lower() == lowerNew then
            tremove(list, i)
        end
    end
    tinsert(list, 1, text)
    local limit = GetRecentLimit()
    while #list > limit do tremove(list) end
end

local FILTER_OPTIONS = {
    { key = "zones",      label = _G["ZONES"] or "Zones" },
    { key = "instances",  label = L["MAP_FILTER_INSTANCES"] },
    { key = "raid",       label = _G["RAIDS"] or "Raids",                   parentKey = "instances" },
    { key = "dungeon",    label = _G["DUNGEONS"] or "Dungeons",             parentKey = "instances" },
    { key = "delve",      label = _G["DELVES_LABEL"] or "Delves",           parentKey = "instances", caps = "delves" },
    { key = "travel",     label = L["MAP_FILTER_TRAVEL"],   tooltip = L["MAP_FILTER_TRAVEL_TT"] },
    { key = "flights",    label = L["MAP_FILTER_FLIGHTS"],                  parentKey = "travel" },
    { key = "boats",      label = L["MAP_FILTER_BOATS"],                    parentKey = "travel" },
    { key = "portals",    label = L["MAP_FILTER_PORTALS"],                  parentKey = "travel" },
    { key = "services",   label = L["MAP_FILTER_SERVICES"], tooltip = L["MAP_FILTER_SERVICES_TT"] },
    { key = "banks",      label = L["MAP_FILTER_BANKS"],           parentKey = "services" },
    { key = "auction",    label = L["MAP_FILTER_AUCTION"],         parentKey = "services" },
    { key = "inns",       label = L["MAP_FILTER_INNS"],            parentKey = "services" },
    { key = "mail",       label = L["MAP_FILTER_MAIL"],            parentKey = "services" },
    { key = "trainers",   label = L["MAP_FILTER_TRAINERS"],        parentKey = "services" },
    { key = "vendors",    label = L["MAP_FILTER_VENDORS"],         parentKey = "services" },
    { key = "appearance", label = L["MAP_FILTER_APPEARANCE"],      parentKey = "services" },
    { key = "otherservices", label = L["MAP_FILTER_OTHER_SERVICES"], parentKey = "services" },
    { key = "rares",      label = L["MAP_FILTER_RARES"] },
    { key = "npcs",       label = L["FILTER_NPCS"],         tooltip = L["MAP_FILTER_NPCS_TT"] },
}

-- Rows for systems this client does not have are dropped once (Shared/Caps.lua).
if ns.Caps then
    for i = #FILTER_OPTIONS, 1, -1 do
        local row = FILTER_OPTIONS[i]
        if row.caps and ns.Caps[row.caps] == false then tremove(FILTER_OPTIONS, i) end
    end
end

-- Sub-row that only shows while the parent Rares filter is checked.
-- Mirrors `alwaysShowRares` in SavedVariables (shared with Options/OptionsPanel.lua).
-- The cog's menu: the "Show" buckets as check rows, each bucket's kinds
-- in a flyout beside it (auto-track under Rares), the text size last.
local MENU_CHECK = "Interface\\Buttons\\UI-CheckBox-Check"

local function Filters()
    EasyFind.db.mapTabFilters = EasyFind.db.mapTabFilters or {}
    return EasyFind.db.mapTabFilters
end

local function SetAutoTrack(on)
    EasyFind.db.alwaysShowRares = on and true or false
    local MapSearch = ns.MapSearch
    -- Deferred: a synchronous rescan during the click leaves the canvas unpainted.
    if MapSearch and MapSearch.UpdateRareTracking then
        SafeAfter(0, function() MapSearch:UpdateRareTracking() end)
    end
    if ns.optionsFrame and ns.optionsFrame.rareTrackCheckbox then
        ns.optionsFrame.rareTrackCheckbox:SetChecked(EasyFind.db.alwaysShowRares)
    end
end

-- A bucket's kinds, ticked while on and dim while the bucket is off.
local function BucketRows(parent, onChanged)
    return function()
        local filters = Filters()
        local off = filters[parent.key] == false
        local rows = {}
        for _, opt in ipairs(FILTER_OPTIONS) do
            if opt.parentKey == parent.key then
                rows[#rows + 1] = { text = opt.label, keepOpen = true, disabled = off,
                    icon = filters[opt.key] ~= false and MENU_CHECK or nil,
                    onClick = function()
                        filters[opt.key] = filters[opt.key] == false
                        onChanged(opt.key, filters[opt.key])
                    end }
            end
        end
        if parent.key == "rares" then
            rows[#rows + 1] = { text = L["MAP_AUTO_TRACK"], tooltip = L["MAP_AUTO_TRACK_RARES_TT"], keepOpen = true,
                disabled = off, icon = EasyFind.db.alwaysShowRares and MENU_CHECK or nil,
                onClick = function() SetAutoTrack(not EasyFind.db.alwaysShowRares) end }
        end
        return rows
    end
end

-- The creature rows' facets (reaction, role, type, expansion), as the
-- bar's NPC options: a flyout per facet of ticks over one table of
-- npcFilters, false leaving a value out. Shared with the bar.
local function NpcFacetRows(onChanged)
    return function()
        local off = Filters().npcs == false
        local rows = {}
        local Flt = ns.Filters
        for _, facet in ipairs(Flt and Flt.NpcFacets and Flt:NpcFacets() or {}) do
            local defs = facet.defs()
            if #defs > 1 then
                rows[#rows + 1] = { text = facet.label, keepOpen = true, disabled = off, submenu = function()
                    local picks = Flt.NpcFacet(facet.name)
                    local out = {}
                    for _, d in ipairs(facet.defs()) do
                        out[#out + 1] = { text = d.label, keepOpen = true, disabled = off,
                            icon = picks[d.key] ~= false and MENU_CHECK or nil,
                            onClick = function()
                                if picks[d.key] == false then picks[d.key] = nil else picks[d.key] = false end
                                onChanged("npcs", Filters().npcs ~= false)
                            end }
                    end
                    return out
                end }
            end
        end
        return rows
    end
end

-- The text size on the panel's chrome too: the search box and its
-- placeholder, the empty hint, the footer's two labels.
function MapTab.ScaleChrome(p)
    local s = FontScale()
    local box = p.searchBox
    if box then
        ScaleFont(box, "ChatFontSmall", s)
        if box.Instructions then ScaleFont(box.Instructions, "GameFontDisableSmall", s) end
        if box.FitPlaceholder then box.FitPlaceholder() end
    end
    if p.emptyMsg then ScaleFont(p.emptyMsg, "GameFontHighlight", s) end
    if p.recentLabel then ScaleFont(p.recentLabel, "GameFontHighlightSmall", s) end
    if p.expandLabel then ScaleFont(p.expandLabel, "GameFontHighlightSmall", s) end
    if p.LayoutChecks then p.LayoutChecks() end
end

-- The text size choices, one ticked.
local function FontRows(onPick)
    return function()
        local cur = FontScale()
        local rows = {}
        for _, choice in ipairs(FONT_SIZES) do
            rows[#rows + 1] = { text = L[choice[1]], keepOpen = true,
                icon = math.abs(choice[2] - cur) < 0.01 and MENU_CHECK or nil,
                onClick = function()
                    EasyFind.db.mapTabFontSize = choice[2]
                    onPick()
                end }
        end
        return rows
    end
end

local function MapOptionsDefs(onChanged, onFontPick)
    local filters = Filters()
    local defs = { { kind = "title", label = (_G["SHOW"] or "Show") .. ":" } }
    for _, opt in ipairs(FILTER_OPTIONS) do
        if not opt.parentKey then
            local kinds = opt.key == "rares"
            for _, o in ipairs(FILTER_OPTIONS) do
                if o.parentKey == opt.key then kinds = true end
            end
            defs[#defs + 1] = { kind = "check", label = opt.label, tooltip = opt.tooltip,
                rows = (kinds and BucketRows(opt, onChanged)) or (opt.key == "npcs" and NpcFacetRows(onChanged)) or nil,
                get = function() return filters[opt.key] ~= false end,
                set = function(v)
                    filters[opt.key] = v and true or false
                    onChanged(opt.key, v)
                end }
        end
    end
    defs[#defs + 1] = { kind = "separator" }
    defs[#defs + 1] = { kind = "submenu", label = L["OPT_FONT_SIZE"], rows = FontRows(onFontPick) }
    return defs
end

-- The same Show buckets as flyout rows for another surface's menu (the
-- GPS window and section): a click flips a bucket, hover opens its kinds.
function MapTab.FilterRows(onChanged)
    return function()
        local filters = Filters()
        local rows = {}
        for _, opt in ipairs(FILTER_OPTIONS) do
            if not opt.parentKey then
                local kinds = opt.key == "rares"
                for _, o in ipairs(FILTER_OPTIONS) do
                    if o.parentKey == opt.key then kinds = true end
                end
                rows[#rows + 1] = { text = opt.label, tooltip = opt.tooltip, keepOpen = true,
                    icon = filters[opt.key] ~= false and MENU_CHECK or nil,
                    submenu = (kinds and BucketRows(opt, onChanged)) or (opt.key == "npcs" and NpcFacetRows(onChanged)) or nil,
                    onClick = function()
                        filters[opt.key] = filters[opt.key] == false
                        onChanged(opt.key, filters[opt.key])
                    end }
            end
        end
        return rows
    end
end

local function CreateFilterCog(parent)
    local cog = CreateFrame("Button", nil, parent)
    cog:SetSize(14, 16)
    local function CogArt(tex)
        if ns.SETTING_ICON.atlas then
            tex:SetAtlas(ns.SETTING_ICON.atlas, false)
        else
            tex:SetTexture(ns.SETTING_ICON.tex)
            tex:SetDesaturated(true)
        end
        tex:SetAllPoints()
    end
    local iconTex = cog:CreateTexture(nil, "ARTWORK")
    CogArt(iconTex)
    local hoverTex = cog:CreateTexture(nil, "HIGHLIGHT")
    CogArt(hoverTex)
    hoverTex:SetAlpha(0.4)
    cog:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(_G["SETTINGS"] or "Settings")
        GameTooltip:AddLine(L["MAP_FILTER_TT"], 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    cog:SetScript("OnLeave", GameTooltip_Hide)
    return cog
end

local function CreateTabFrame(qmf)
    local tab = CreateFrame("Frame", "EasyFindMapSearchTab", qmf)
    -- Match the side tabs it stacks under: their size copied from
    -- MapLegendTab and the same shared tab art, so the two line up; the
    -- template-inheritance path would override our custom icon.
    local refW, refH = qmf.MapLegendTab:GetSize()
    if not refW or refW == 0 then refW, refH = TAB_W, TAB_H end
    tab:SetSize(refW, refH)
    tab:SetFrameStrata("HIGH")
    tab:SetFrameLevel(qmf.MapLegendTab:GetFrameLevel())
    tab.displayMode = "EasyFindMapSearch"
    tab:EnableMouse(true)

    local bg = tab:CreateTexture(nil, "BACKGROUND")
    bg:SetAtlas(SIDE_TAB, true)
    bg:SetPoint("CENTER", tab, "CENTER", 0, 0)

    local icon = tab:CreateTexture(nil, "ARTWORK")
    -- The map pin: this tab is where a place is found and where the
    -- directions to it live.
    icon:SetTexture(ns.GPS_ICON_TEX)
    icon:SetTexCoord(0, 1, 0, 1)
    icon:SetSize(TAB_ICON_SIZE + 2, TAB_ICON_SIZE + 2)
    -- Retail's tab art tucks under the map edge on its left, so there the
    -- icon sits 2px left of center, as on the side tabs it stacks under.
    icon:SetPoint("CENTER", tab, "CENTER", SIDE_TAB_ICON_X, 0)
    icon:SetVertexColor(Utils.RGB(TAB_ICON_DIM))
    tab._efIcon = icon

    local selectGlow = tab:CreateTexture(nil, "OVERLAY")
    selectGlow:SetAtlas(SIDE_TAB_SELECT, true)
    selectGlow:SetPoint("CENTER", bg, "CENTER", 0, 0)
    selectGlow:Hide()
    tab._efSelectGlow = selectGlow

    local hoverGlow = tab:CreateTexture(nil, "HIGHLIGHT")
    hoverGlow:SetAtlas(SIDE_TAB_HOVER, true)
    hoverGlow:SetPoint("CENTER", bg, "CENTER", 0, 0)

    tab:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then ShowOurPanel(false) end
    end)
    tab:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(L["MAP_SEARCH_TITLE"])
        GameTooltip:AddLine(L["MAP_SEARCH_TT"], 1, 1, 1, true)
        GameTooltip:Show()
    end)
    tab:SetScript("OnLeave", GameTooltip_Hide)

    return tab
end

-- Our own Quests tab for a client whose quest log draws no side tabs:
-- the same tab art, the icon Blizzard's hidden Quests tab carries, and a
-- click that leaves our panel and shows the quest log again.
local function CreateBackTab(qmf)
    local tab = CreateFrame("Frame", "EasyFindMapQuestsTab", qmf)
    local refW, refH = qmf.QuestsTab:GetSize()
    if not refW or refW == 0 then refW, refH = TAB_W, TAB_H end
    tab:SetSize(refW, refH)
    tab:SetFrameStrata("HIGH")
    tab:SetFrameLevel(qmf.QuestsTab:GetFrameLevel())
    tab:EnableMouse(true)

    local bg = tab:CreateTexture(nil, "BACKGROUND")
    bg:SetAtlas("QuestLog-tab-side", true)
    bg:SetPoint("CENTER", tab, "CENTER", 0, 0)
    tab.art = bg

    -- The icon: whatever Blizzard's Quests tab draws besides the tab
    -- itself, else the quest log's own book.
    local icon = tab:CreateTexture(nil, "ARTWORK")
    local copied = false
    -- Blizzard's tab keeps its glyph in a region named Icon; failing
    -- that, any texture whose atlas is not tab chrome (compared in lower
    -- case: the chrome atlases mix "tab-side" and "Tab-side").
    local src = qmf.QuestsTab.Icon
    if not src then
        for i = 1, qmf.QuestsTab:GetNumRegions() do
            local r = select(i, qmf.QuestsTab:GetRegions())
            if r and r.GetObjectType and r:GetObjectType() == "Texture" then
                local atlas = r.GetAtlas and r:GetAtlas()
                local low = atlas and atlas:lower() or ""
                if atlas and not low:find("tab") and not low:find("glow") then src = r break end
            end
        end
    end
    if src then
        local atlas = src.GetAtlas and src:GetAtlas()
        if atlas then
            icon:SetAtlas(atlas, false)
            copied = true
        elseif src.GetTexture and src:GetTexture() then
            icon:SetTexture(src:GetTexture())
            if src.GetTexCoord then icon:SetTexCoord(src:GetTexCoord()) end
            copied = true
        end
    end
    if not copied then icon:SetTexture("Interface\\QuestFrame\\UI-QuestLog-BookIcon") end
    icon:SetSize(TAB_ICON_SIZE + 4, TAB_ICON_SIZE + 4)
    icon:SetPoint("CENTER", tab, "CENTER", 0, 0)
    icon:SetVertexColor(Utils.RGB(TAB_ICON_GOLD))
    tab._efIcon = icon

    local selectGlow = tab:CreateTexture(nil, "OVERLAY")
    selectGlow:SetAtlas("QuestLog-Tab-side-Glow-Select", true)
    selectGlow:SetPoint("CENTER", bg, "CENTER", 0, 0)
    selectGlow:Show()
    tab._efSelectGlow = selectGlow

    local hoverGlow = tab:CreateTexture(nil, "HIGHLIGHT")
    hoverGlow:SetAtlas("QuestLog-Tab-side-Glow-hover", true)
    hoverGlow:SetPoint("CENTER", bg, "CENTER", 0, 0)

    tab:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then HideOurPanel(true) RefreshSelectGlows() end
    end)
    tab:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(_G["QUESTLOG_BUTTON"] or _G["QUESTS_LABEL"] or "Quests")
        GameTooltip:Show()
    end)
    tab:SetScript("OnLeave", GameTooltip_Hide)
    return tab
end

-- A registered page's own side tab, stacked under the search tab with
-- the same art; its click shows that page in the shared panel.
local function CreateExtraTab(qmf, def)
    local tab = CreateFrame("Frame", "EasyFindMapTab_" .. def.id, qmf)
    local refW, refH = qmf.MapLegendTab:GetSize()
    if not refW or refW == 0 then refW, refH = TAB_W, TAB_H end
    tab:SetSize(refW, refH)
    tab:SetFrameStrata("HIGH")
    tab:SetFrameLevel(qmf.MapLegendTab:GetFrameLevel())
    tab.displayMode = "EasyFindPage_" .. def.id
    tab._efExtraTab = true
    tab:EnableMouse(true)

    local bg = tab:CreateTexture(nil, "BACKGROUND")
    bg:SetAtlas(SIDE_TAB, true)
    bg:SetPoint("CENTER", tab, "CENTER", 0, 0)

    local icon = tab:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(def.icon)
    if def.coords then icon:SetTexCoord(unpack(def.coords)) end
    local size = def.iconSize or TAB_ICON_SIZE
    icon:SetSize(size, size)
    -- Retail's tab art tucks under the map edge on its left, so there the
    -- icon sits 2px left of center, as on the side tabs it stacks under.
    icon:SetPoint("CENTER", tab, "CENTER", SIDE_TAB_ICON_X, 0)
    icon:SetVertexColor(Utils.RGB(TAB_ICON_DIM))
    tab._efIcon = icon

    local selectGlow = tab:CreateTexture(nil, "OVERLAY")
    selectGlow:SetAtlas(SIDE_TAB_SELECT, true)
    selectGlow:SetPoint("CENTER", bg, "CENTER", 0, 0)
    selectGlow:Hide()
    tab._efSelectGlow = selectGlow

    local hoverGlow = tab:CreateTexture(nil, "HIGHLIGHT")
    hoverGlow:SetAtlas(SIDE_TAB_HOVER, true)
    hoverGlow:SetPoint("CENTER", bg, "CENTER", 0, 0)

    tab:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then ShowOurPanel(def.id) end
    end)
    tab:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(def.title or def.id)
        if def.tooltip then GameTooltip:AddLine(def.tooltip, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    tab:SetScript("OnLeave", GameTooltip_Hide)
    return tab
end

local function EnsureExtraTab(id)
    local def = pages[id]
    if not def or def.noTab or extraTabs[id] then return end
    local qmf = _G["QuestMapFrame"]
    if not qmf or not qmf.MapLegendTab then return end
    extraTabs[id] = CreateExtraTab(qmf, def)
end

-- Classic's windowed map grows a side panel in its own border art, opened
-- from a toggle in its corner, as retail's quest panel.
function SidePanel.Build()
    local wmf = WorldMapFrame
    local right = _G["MiniBorderRight"]
    if not (wmf and wmf.MiniBorderFrame and wmf.ScrollContainer and right) then return nil end
    -- Art pixels, 1:1: grows by W; bars at BARS_U, divider EDGE_U, end CAP_U;
    -- the panel's metal only (the parchment shading is inside TOP, BOTTOM, RIM).
    local W, BARS_U, EDGE_U, CAP_U = 287, 199, 71, 24
    local TOP, BOTTOM, RIM = 24, 407, 73
    local LEFT_ART = "Interface\\WorldMap\\UI-WorldMapSmall-Left"
    local RIGHT_ART = "Interface\\WorldMap\\UI-WorldMapSmall-Right"
    SidePanel.W = W
    local f = CreateFrame("Frame", "EasyFindMapSidePanel", wmf)
    f:SetAllPoints(wmf)
    f:SetFrameLevel(wmf.MiniBorderFrame:GetFrameLevel())
    f:Hide()
    local function Piece(file, u0, u1, v0, v1, x, y)
        local t = f:CreateTexture(nil, "ARTWORK")
        local w = file == LEFT_ART and 512 or 128
        t:SetTexture(file)
        t:SetTexCoord(u0 / w, u1 / w, v0 / 512, v1 / 512)
        t:SetSize(u1 - u0, v1 - v0)
        t:SetPoint("TOPLEFT", right, "TOPLEFT", x, y)
    end
    -- Over the map the bars keep its shading; over the panel, metal only.
    local barsEnd, mapEnd = BARS_U + CAP_U + W, BARS_U + EDGE_U
    Piece(LEFT_ART, BARS_U, mapEnd, 0, 512, 0, 0)
    Piece(LEFT_ART, mapEnd, barsEnd, 0, TOP, EDGE_U, 0)
    Piece(LEFT_ART, mapEnd, barsEnd, BOTTOM, 512, EDGE_U, -BOTTOM)
    Piece(RIGHT_ART, EDGE_U, EDGE_U + 8, TOP, BOTTOM, EDGE_U, -TOP)
    Piece(RIGHT_ART, CAP_U, 128, 0, TOP, CAP_U + W, 0)
    Piece(RIGHT_ART, CAP_U, 128, BOTTOM, 512, CAP_U + W, -BOTTOM)
    Piece(RIGHT_ART, RIM, 128, TOP, BOTTOM, RIM + W, -TOP)
    -- The window's stone, as retail's frames have behind their panels.
    local rock = f:CreateTexture(nil, "BACKGROUND")
    rock:SetTexture("Interface\\FrameGeneral\\UI-Background-Rock", "REPEAT", "REPEAT")
    rock:SetHorizTile(true)
    rock:SetVertTile(true)
    rock:SetPoint("TOPLEFT", right, "TOPLEFT", EDGE_U + 7, 2 - TOP)
    rock:SetPoint("BOTTOMRIGHT", right, "TOPLEFT", RIM + W + 1, -BOTTOM - 1)
    -- Room for the quest border round the panel (3 out, 7 up, 6 down).
    -- Hung from frames: secure cast buttons cannot be placed through art.
    local RIGHT_X = 12 + 512   -- the right piece's left edge in the window
    local contents = CreateFrame("Frame", nil, f)
    contents:SetPoint("TOPLEFT", f, "TOPLEFT", RIGHT_X + EDGE_U + 12, -TOP - 8)
    contents:SetPoint("BOTTOMRIGHT", f, "TOPLEFT", RIGHT_X + RIM + W - 4, 7 - BOTTOM)
    contents:EnableMouse(true)
    f.ContentsAnchor = contents
    SidePanel.frame = f

    -- The toggle: the client's square button, retail's arrow, our pin, in
    -- the map's inner corner.
    local toggle = CreateFrame("Button", "EasyFindMapSidePanelToggle", wmf)
    toggle:SetSize(32, 32)
    -- Over the map's pins, which take the levels from 2000 up.
    local levels = wmf.GetPinFrameLevelsManager and wmf:GetPinFrameLevelsManager()
    toggle:SetFrameLevel(((levels and levels.maxLevel) or 2000) + 1)
    toggle:SetPoint("BOTTOMRIGHT", right, "TOPLEFT", RIM - 1, 1 - BOTTOM)
    toggle:SetNormalTexture("Interface\\Buttons\\UI-SquareButton-Up")
    toggle:SetPushedTexture("Interface\\Buttons\\UI-SquareButton-Down")
    toggle:GetNormalTexture():SetTexCoord(2 / 32, 29 / 32, 3 / 32, 29 / 32)
    toggle:GetPushedTexture():SetTexCoord(2 / 32, 29 / 32, 3 / 32, 29 / 32)
    toggle:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    local arrow = toggle:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\Buttons\\SquareButtonTextures")
    arrow:SetSize(11, 11)
    local pin = toggle:CreateTexture(nil, "OVERLAY")
    pin:SetTexture(ns.GPS_ICON_TEX)
    pin:SetSize(18, 18)
    pin:SetVertexColor(Utils.RGB(TAB_ICON_GOLD))
    local function PlaceGlyphs(dx, dy)
        arrow:SetPoint("LEFT", toggle, "LEFT", 5 + dx, dy)
        pin:SetPoint("CENTER", toggle, "CENTER", 4 + dx, dy)
    end
    PlaceGlyphs(0, 0)
    toggle:SetScript("OnMouseDown", function() PlaceGlyphs(1, -1) end)
    toggle:SetScript("OnMouseUp", function() PlaceGlyphs(0, 0) end)
    toggle:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        if selectedIsOurs then
            lastSelectedWasOurs = false
            EasyFind.db.mapSidePanelOpen = false
            HideOurPanel(true)
        else
            ShowOurPanel()
        end
    end)
    toggle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(L["MAP_SEARCH_TITLE"])
        GameTooltip:AddLine(L["MAP_SEARCH_TT"], 1, 1, 1, true)
        GameTooltip:Show()
    end)
    toggle:SetScript("OnLeave", GameTooltip_Hide)
    toggle:Hide()
    SidePanel.toggle, SidePanel.arrow = toggle, arrow
    SidePanel.RefreshToggle()
    if wmf.SynchronizeDisplayState then hooksecurefunc(wmf, "SynchronizeDisplayState", SidePanel.ClientPlacedClose) end
    return f
end

-- Retail's book page and quest border on the panel, from EasyFind's copies
-- (the classic clients have neither); the border is the client's nine-slice.
function SidePanel.Paper(p)
    local RIM_TEX = "Interface\\AddOns\\EasyFind\\textures\\QuestRim"
    local paper = p:CreateTexture(nil, "BACKGROUND", nil, -1)
    paper:SetTexture("Interface\\AddOns\\EasyFind\\textures\\QuestPaper")
    paper:SetTexCoord(0, 307 / 512, 0, 510 / 512)
    paper:SetAllPoints(p)
    local rim = CreateFrame("Frame", nil, p)
    rim:SetPoint("TOPLEFT", p, "TOPLEFT", -3, 7)
    rim:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", 3, -6)
    rim:SetFrameLevel(p:GetFrameLevel() + 2)
    -- The 2x copy's cuts (of 256): corners to 106, a 2-pixel middle to 108,
    -- the rim to 214; corners draw 53 across, as the client's slices.
    local cuts = { 0, 106 / 256, 108 / 256, 214 / 256 }
    local C = 53
    -- Each cut: its column and row, width and height (0 = from its anchors),
    -- then its anchors on the rim.
    for _, c in ipairs({
        { 1, 1, C, C, { "TOPLEFT", 0, 0 } },
        { 3, 1, C, C, { "TOPRIGHT", 0, 0 } },
        { 1, 3, C, C, { "BOTTOMLEFT", 0, 0 } },
        { 3, 3, C, C, { "BOTTOMRIGHT", 0, 0 } },
        { 2, 1, 0, C, { "TOPLEFT", C, 0 }, { "TOPRIGHT", -C, 0 } },
        { 2, 3, 0, C, { "BOTTOMLEFT", C, 0 }, { "BOTTOMRIGHT", -C, 0 } },
        { 1, 2, C, 0, { "TOPLEFT", 0, -C }, { "BOTTOMLEFT", 0, C } },
        { 3, 2, C, 0, { "TOPRIGHT", 0, -C }, { "BOTTOMRIGHT", 0, C } },
        { 2, 2, 0, 0, { "TOPLEFT", C, -C }, { "BOTTOMRIGHT", -C, C } },
    }) do
        local t = rim:CreateTexture(nil, "BORDER")
        t:SetTexture(RIM_TEX)
        t:SetTexCoord(cuts[c[1]], cuts[c[1] + 1], cuts[c[2]], cuts[c[2] + 1])
        if c[3] > 0 then t:SetWidth(c[3]) end
        if c[4] > 0 then t:SetHeight(c[4]) end
        for i = 5, #c do t:SetPoint(c[i][1], rim, c[i][1], c[i][2], c[i][3]) end
    end
    local filigree = rim:CreateTexture(nil, "ARTWORK")
    filigree:SetTexture(RIM_TEX)
    filigree:SetTexCoord(0, 96 / 256, 216 / 256, 254 / 256)
    filigree:SetSize(48, 19)
    filigree:SetPoint("TOP", rim, "TOP", 0, 1)
end

function SidePanel.RefreshToggle()
    local c = _G.SQUARE_BUTTON_TEXCOORDS and _G.SQUARE_BUTTON_TEXCOORDS[SidePanel.frame:IsShown() and "LEFT" or "RIGHT"]
    if c then SidePanel.arrow:SetTexCoord(c[1], c[2], c[3], c[4]) end
end

-- The client's close button (the maximize button rides on it): its place as
-- the client last set it, and the new end's while the panel is open.
function SidePanel.PlaceClose()
    local close = _G["WorldMapFrameCloseButton"]
    if not close then return end
    if not SidePanel.closeMoved then SidePanel.closeAt = { close:GetPoint(1) } end
    local at = SidePanel.closeAt
    if SidePanel.frame:IsShown() and at[2] == _G["MiniBorderRight"] then
        close:SetPoint(at[1], at[2], at[3], at[4] + SidePanel.W, at[5])
        SidePanel.closeMoved = true
    end
end

function SidePanel.ClientPlacedClose()
    SidePanel.closeMoved = false
    SidePanel.PlaceClose()
end

-- Open beside the windowed map; the full-screen map has no room for it.
function SidePanel.Expand()
    local wmf = WorldMapFrame
    if not wmf:IsShown() or wmf:IsMaximized() then return false end
    local f = SidePanel.frame
    if not f:IsShown() then
        f:Show()
        _G["MiniBorderRight"]:Hide()
        SidePanel.PlaceClose()
    end
    EasyFind.db.mapSidePanelOpen = true
    SidePanel.RefreshToggle()
    return true
end

function SidePanel.Collapse()
    local f = SidePanel.frame
    if f:IsShown() then
        f:Hide()
        _G["MiniBorderRight"]:Show()
        local close = _G["WorldMapFrameCloseButton"]
        if close and SidePanel.closeMoved then close:SetPoint(unpack(SidePanel.closeAt)) end
        SidePanel.closeMoved = false
    end
    SidePanel.RefreshToggle()
end

-- The toggle shows on the windowed map, and the panel opens as it was left.
function SidePanel.Sync()
    local wmf = WorldMapFrame
    local windowed = IsMapSearchEnabled() and not wmf:IsMaximized()
    SidePanel.toggle:SetShown(windowed)
    if not windowed then
        HideOurPanel(true)
        SidePanel.Collapse()
    elseif lastSelectedWasOurs and wmf:IsShown() and not selectedIsOurs then
        ShowOurPanel()
    end
end

-- Sibling content panel: paper backdrop, gold border, search + cog at
-- top, scrollable content below.
local function CreatePanel(qmf)
    local anchor = qmf.ContentsAnchor or qmf.QuestsFrame or qmf

    local outer = CreateFrame("Frame", "EasyFindMapSearchOuter", qmf)
    outer:SetAllPoints(anchor)
    outer:EnableMouse(false)

    local p = CreateFrame("Frame", "EasyFindMapSearchPanel", outer)
    p:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, -29)
    -- The scroll bars' strip right of the panel: retail's matches its quest
    -- log's; the side panel's holds the bar and no more.
    local strip = SidePanel.frame and 16 or 22
    p.barGap = SidePanel.frame and 5 or 8
    p:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -strip, 0)
    p:EnableMouse(true)
    p.outer, p.anchor = outer, anchor
    outer:Hide()

    -- Retail's quest panel paper and rim; the side panel draws the map's.
    if not SidePanel.frame then
        local paper = p:CreateTexture(nil, "BACKGROUND", nil, -1)
        paper:SetAtlas("QuestLog-main-background", true)
        paper:SetAllPoints(p)
        p.paper = paper

        -- Don't SetAllPoints on the border: the template carries its own
        -- anchors that extend the frame a few pixels outside its parent so
        -- the nineslice interior lines up with the parent's rect.
        local border = CreateFrame("Frame", nil, p, "QuestLogBorderFrameTemplate")
        border:SetFrameLevel(p:GetFrameLevel() + 2)
        -- Border is decorative chrome; it never needs mouse input. Leaving
        -- it on ate the first click on every row.
        border:EnableMouse(false)
        p.border = border
    else
        SidePanel.Paper(p)
    end

    local cog = CreateFilterCog(outer)
    cog:SetSize(15, 16)
    cog:SetPoint("TOPRIGHT", p, "TOPRIGHT", 19, 25)
    p.cog = cog

    -- Fallback search-box position; AlignToBlizzardSearch re-anchors it
    -- to mirror the Quests tab box once measurable.
    local searchBox = CreateSearchBox(outer)
    searchBox:ClearAllPoints()
    searchBox:SetHeight(20)
    -- Clear of the quest border's top on the side panel.
    searchBox:SetPoint("TOPLEFT", outer, "TOPLEFT", 4, SidePanel.frame and -2 or -5)
    searchBox:SetPoint("RIGHT", cog, "LEFT", -6, 0)
    p.searchBox = searchBox

    local function OnFilterChanged(key)
        if key == "flights" and ns.MapSearch and ns.MapSearch.ReleaseIdleSearchMemory then
            ns.MapSearch:ReleaseIdleSearchMemory()
        end
        RefreshCurrentSearch()
        -- Rares is the parent of auto-track: toggling it starts or stops
        -- tracking too (deferred, as the auto-track row's own click is).
        if key == "rares" and ns.MapSearch and ns.MapSearch.UpdateRareTracking then
            SafeAfter(0, function() ns.MapSearch:UpdateRareTracking() end)
        end
        local uiMod = ns.Search
        local uiSb = uiMod and uiMod.searchFrame and uiMod.searchFrame.editBox
        if uiMod and uiMod.OnSearchTextChanged and uiSb and uiSb:IsShown() then
            local txt = uiSb:GetText() or ""
            if txt ~= "" then uiMod:OnSearchTextChanged(txt) end
        end
    end
    local function OnFontPicked()
        MapTab.ScaleChrome(p)
        RefreshCurrentSearch()
        -- The GPS page's steps follow the same size.
        if ns.GPS and ns.GPS.RefreshSurfaces then ns.GPS.RefreshSurfaces() end
    end
    cog:SetScript("OnClick", function()
        ns.ShowTogglePopup("EasyFindMapTabOptions", cog, MapOptionsDefs(OnFilterChanged, OnFontPicked), {})
    end)

    p.AlignToBlizzardSearch = function()
        local qsb = not SidePanel.frame and _G["QuestScrollFrame"] and QuestScrollFrame.SearchBox
        if not qsb then return end
        local n = qsb:GetNumPoints() or 0
        if n == 0 then return end
        -- Its left edge and height, then on to the cog: a wider pane than
        -- the client's leaves the client's fixed width short of it.
        searchBox:ClearAllPoints()
        for i = 1, n do
            local point, relTo, relPoint, x, y = qsb:GetPoint(i)
            if point and not point:find("RIGHT") then
                searchBox:SetPoint(point, relTo, relPoint, x, y)
            end
        end
        local w, h = qsb:GetSize()
        if p.cog then
            searchBox:SetPoint("RIGHT", p.cog, "LEFT", -6, 0)
            if h and h > 0 then searchBox:SetHeight(h) end
        elseif w and w > 0 and h and h > 0 then
            searchBox:SetSize(w, h)
        end
    end
    p.MeasureBlizzardSearch = p.AlignToBlizzardSearch

    local scrollFrame = CreateFrame("ScrollFrame", nil, p)
    scrollFrame:SetPoint("TOPLEFT", p, "TOPLEFT", 4, -4)
    -- 28px bottom inset for the "Show recent searches" checkbox.
    scrollFrame:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -4, 28)
    scrollFrame:EnableMouseWheel(true)
    p.scrollFrame = scrollFrame

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(1, 1)
    scrollFrame:SetScrollChild(scrollChild)
    scrollFrame:HookScript("OnSizeChanged", function(_, w) scrollChild:SetWidth(w) end)
    scrollChild:SetWidth(scrollFrame:GetWidth())
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = mmax(0, scrollChild:GetHeight() - self:GetHeight())
        local cur = self:GetVerticalScroll() or 0
        local target = cur - delta * 24
        if target < 0 then target = 0 end
        if target > maxScroll then target = maxScroll end
        self:SetVerticalScroll(target)
    end)
    p.scrollChild = scrollChild

    local scrollBar = CreateFrame("EventFrame", nil, p, "MinimalScrollBar")
    scrollBar:SetFrameStrata("HIGH")
    scrollBar:SetPoint("TOPLEFT", p, "TOPRIGHT", p.barGap, 2)
    scrollBar:SetPoint("BOTTOMLEFT", p, "BOTTOMRIGHT", p.barGap, -4)
    p.scrollBar = scrollBar

    local function SyncScrollBar()
        local contentH = scrollChild:GetHeight() or 0
        local viewH = scrollFrame:GetHeight() or 0
        if scrollBar.SetVisibleExtentPercentage then
            local extent = contentH > 0 and mmin(1, viewH / contentH) or 1
            scrollBar:SetVisibleExtentPercentage(extent)
        end
        if scrollBar.SetScrollPercentage then
            local maxScroll = mmax(1, contentH - viewH)
            scrollBar:SetScrollPercentage((scrollFrame:GetVerticalScroll() or 0) / maxScroll)
        end
    end
    if scrollBar.RegisterCallback and scrollBar.Event and scrollBar.Event.OnScroll then
        scrollBar:RegisterCallback(scrollBar.Event.OnScroll, function(_, pct)
            local maxScroll = mmax(0, (scrollChild:GetHeight() or 0) - (scrollFrame:GetHeight() or 0))
            scrollFrame:SetVerticalScroll(pct * maxScroll)
        end, p)
    end
    scrollFrame:HookScript("OnSizeChanged", SyncScrollBar)
    scrollFrame:HookScript("OnVerticalScroll", SyncScrollBar)
    hooksecurefunc(scrollChild, "SetHeight", SyncScrollBar)
    p.SyncScrollBar = SyncScrollBar

    -- The directions bar above the results (see UpdatePageBar).
    local pageBar = ns.CreateModernButton(p, "", 100, 20)
    pageBar:ClearAllPoints()
    pageBar:SetPoint("TOPLEFT", p, "TOPLEFT", 4, -4)
    pageBar:SetPoint("TOPRIGHT", p, "TOPRIGHT", -4, -4)
    pageBar:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    pageBar:SetScript("OnClick", function(self, button)
        -- On a page the bar leads back to the search.
        if self.pageID == false then
            if button == "LeftButton" then ShowOurPanel(false) end
            return
        end
        local def = self.pageID and pages[self.pageID]
        if not def then return end
        if button == "RightButton" then
            if def.onBarMenu then def.onBarMenu(self) end
            return
        end
        ShowOurPanel(self.pageID)
    end)
    -- An X at the bar's right while the cursor is on it: the page's route
    -- cleared without opening the page.
    local clearX = ns.CreateCloseX(pageBar, 12)
    clearX:SetPoint("RIGHT", pageBar, "RIGHT", -6, 0)
    clearX:Hide()
    clearX:SetScript("OnClick", function()
        local def = pageBar.pageID and pages[pageBar.pageID]
        if def and def.clear then def.clear() end
    end)
    local function HoverX()
        local def = pageBar.pageID and pages[pageBar.pageID]
        clearX:SetShown(def and def.clear and (pageBar:IsMouseOver() or clearX:IsMouseOver()) or false)
    end
    pageBar:HookScript("OnEnter", HoverX)
    pageBar:HookScript("OnLeave", function() Utils.SafeAfter(0.05, HoverX) end)
    clearX:HookScript("OnLeave", function() Utils.SafeAfter(0.05, HoverX) end)
    pageBar:Hide()
    p.pageBar = pageBar

    local emptyMsg = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    emptyMsg:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 20, -24)
    emptyMsg:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", -20, -24)
    emptyMsg:SetJustifyH("CENTER")
    emptyMsg:SetText("|cff999999" .. L["MAP_EMPTY_HINT"] .. "|r")
    p.emptyMsg = emptyMsg

    local recentCheck = CreateFrame("CheckButton", "EasyFindMapTabRecentCheck", p, "UICheckButtonTemplate")
    recentCheck:SetSize(20, 20)
    recentCheck:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 4, 4)
    recentCheck:SetHitRectInsets(0, -120, 0, 0)
    local recentLabel = recentCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    recentLabel:SetPoint("LEFT", recentCheck, "RIGHT", 2, 1)
    recentLabel:SetText(L["MAP_SHOW_RECENT"])
    recentCheck:SetScript("OnShow", function(self)
        self:SetChecked(EasyFind.db.mapTabShowRecent ~= false)
    end)
    recentCheck:SetScript("OnClick", function(self)
        EasyFind.db.mapTabShowRecent = self:GetChecked() and true or false
        RefreshCurrentSearch()
    end)
    p.recentCheck = recentCheck

    local expandCheck = CreateFrame("CheckButton", "EasyFindMapTabAutoExpandCheck", p, "UICheckButtonTemplate")
    expandCheck:SetSize(20, 20)
    expandCheck:SetPoint("LEFT", recentLabel, "RIGHT", 12, -1)
    expandCheck:SetHitRectInsets(0, -120, 0, 0)
    local expandLabel = expandCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    expandLabel:SetPoint("LEFT", expandCheck, "RIGHT", 2, 1)
    expandLabel:SetText(L["MAP_AUTO_EXPAND"])
    expandCheck:SetScript("OnShow", function(self)
        self:SetChecked(EasyFind.db.mapTabAutoExpand ~= false)
    end)
    p.recentLabel, p.expandLabel = recentLabel, expandLabel
    expandCheck:SetScript("OnClick", function(self)
        EasyFind.db.mapTabAutoExpand = self:GetChecked() and true or false
        RefreshCurrentSearch()
    end)
    expandCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:SetText(L["MAP_AUTO_EXPAND"])
        GameTooltip:AddLine(L["MAP_AUTO_EXPAND_TT"], 1, 1, 1, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["MAP_AUTO_EXPAND_EXAMPLE"], 0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    expandCheck:SetScript("OnLeave", GameTooltip_Hide)
    p.expandCheck = expandCheck
    -- The checks share the bottom line where both fit, else stack; the list
    -- ends above them.
    function p.LayoutChecks()
        local need = 64 + recentLabel:GetUnboundedStringWidth() + expandLabel:GetUnboundedStringWidth()
        local stacked = need > p:GetWidth()
        expandCheck:ClearAllPoints()
        if stacked then
            expandCheck:SetPoint("BOTTOMLEFT", recentCheck, "TOPLEFT", 0, 2)
        else
            expandCheck:SetPoint("LEFT", recentLabel, "RIGHT", 12, -1)
        end
        p.footH = stacked and 50 or 28
        if panel == p then UpdatePageBar() end
    end
    p:HookScript("OnSizeChanged", p.LayoutChecks)
    MapTab.ScaleChrome(p)

    return p
end

-- A page under the search tab, registered by an extension:
-- { id, icon, coords, iconSize, title, tooltip, build(frame), onShow(frame) }.
-- build fills the frame once; onShow runs every time the page comes up.
function MapTab:RegisterPage(def)
    if not (def and def.id) then return end
    if not pages[def.id] then pageOrder[#pageOrder + 1] = def.id end
    pages[def.id] = def
    if initialized then
        EnsureExtraTab(def.id)
        PlaceTab()
    end
end

-- Re-derive the directions bar (a page's content changed).
function MapTab:RefreshPageBar()
    UpdatePageBar()
end

-- Back to the results with the current text, if the panel is up.
function MapTab:ShowSearchView()
    if not (panel and selectedIsOurs) then return end
    SelectPage(false)
    RefreshSelectGlows()
    local sb = panel.searchBox
    self:RunSearch(sb and (sb.GetTypedText and sb:GetTypedText() or sb:GetText()) or "")
end

function MapTab:GetPageFrame(id)
    local def = pages[id]
    return def and def.frame
end

function MapTab:IsPageShowing(id)
    return selectedIsOurs and activePage == id and panel ~= nil and (panel.outer or panel):IsShown()
end

-- Open the map if needed and show a registered page.
function MapTab:ShowPage(id)
    if not IsMapSearchEnabled() or not pages[id] then return false end
    if not initialized then self:Initialize() end
    if not WorldMapFrame or not WorldMapFrame:IsShown() then
        if ToggleWorldMap then ToggleWorldMap() end
        if not initialized then self:Initialize() end
    end
    if not panel then return false end
    ShowOurPanel(id)
    if not selectedIsOurs then return false end
    SafeAfter(0, function()
        if panel and not (panel.outer or panel):IsVisible() and WorldMapFrame and WorldMapFrame:IsShown() then
            ShowOurPanel(id)
        end
    end)
    return true
end

function MapTab:Focus()
    if not IsMapSearchEnabled() then return false end
    if not initialized then self:Initialize() end
    -- ToggleWorldMap is a global available before Blizzard_WorldMap
    -- loads; calling it loads the addon and shows the map.
    if not WorldMapFrame or not WorldMapFrame:IsShown() then
        if ToggleWorldMap then ToggleWorldMap() end
        if not initialized then self:Initialize() end
    end
    -- If init hasn't completed (rare race), ADDON_LOADED at the bottom
    -- consumes _pendingFocus to retry once the panel exists.
    if not panel then
        MapTab._pendingFocus = true
        return false
    end
    ShowOurPanel(false)
    if not selectedIsOurs then return false end
    -- Re-apply on next frame against async tab restoration that fires
    -- after this OnShow chain settles.
    SafeAfter(0, function()
        if not panel then return end
        if not panel:IsShown() then ShowOurPanel(false) end
        if panel.searchBox and selectedIsOurs and panel:IsShown() then
            panel.searchBox:SetFocus()
        end
    end)
    return true
end

function MapTab:OpenWithQuery(query)
    if not IsMapSearchEnabled() then return false end
    if not initialized then self:Initialize() end
    if not WorldMapFrame or not WorldMapFrame:IsShown() then
        if ToggleWorldMap then ToggleWorldMap() end
        if not initialized then self:Initialize() end
    end
    -- ADDON_LOADED replays this once the panel exists.
    if not panel then
        MapTab._pendingQuery = query
        return false
    end
    -- Set text BEFORE invoking the tab's OnMouseUp: ShowOurPanel reads
    -- the editbox text and runs a synchronous RunSearch, so seeding
    -- first avoids a flash of empty / recent-searches state.
    if panel.searchBox then
        panel.searchBox:SetText(query or "")
        panel.searchBox:ClearFocus()
    end
    ShowOurPanel(false)
    if not selectedIsOurs then return false end
    SafeAfter(0, function()
        if not panel then return end
        if not panel:IsShown() then ShowOurPanel(false) end
        if panel.searchBox and panel:IsShown() then
            if panel.searchBox:GetText() ~= (query or "") then
                panel.searchBox:SetText(query or "")
            end
            panel.searchBox:ClearFocus()
        end
    end)
    return true
end

-- Anchors our tab below the lowest shown sibling tab on QuestMapFrame.
-- Discovers tabs by the `displayMode` field so it works across Blizzard
-- and third-party tab additions.
-- The tab's left edge to its art's flat side: the atlas is drawn at its own
-- size in the middle of the tab, its art 3 of its 51 columns in.
local function TabArtInset(tab)
    local w = tab.art and tab.art:GetWidth()
    if not (w and w > 0) then return 3 end
    return (tab:GetWidth() - w) / 2 + w * 3 / 51
end

function PlaceTab()
    if not tabFrame then return end
    local qmf = _G["QuestMapFrame"]
    if not qmf then return end
    local lowest, lowestBottom
    for _, child in ipairs({ qmf:GetChildren() }) do
        if child ~= tabFrame and not child._efExtraTab and child.displayMode and child.OnEnter and child:IsShown() then
            local b = child:GetBottom()
            if b and (not lowestBottom or b < lowestBottom) then
                lowest, lowestBottom = child, b
            end
        end
    end
    tabFrame:ClearAllPoints()
    if backTab and lowest then backTab:Hide() end
    if lowest then
        tabFrame:SetPoint("TOPLEFT", lowest, "BOTTOMLEFT", 0, TAB_STACK_GAP)
    elseif qmf.QuestsTab and not qmf.QuestsTab:IsShown() then
        -- No side tab is drawn (WoW Forever's quest log has none): our
        -- Quests tab takes the first slot, where Blizzard's hidden one
        -- still sits, and the search tab goes under it, instead of
        -- floating under two invisible tabs with no way back.
        if not backTab then backTab = CreateBackTab(qmf) end
        backTab:ClearAllPoints()
        -- Against the visible border's outer edge, down from the pane's top.
        -- The game's border art ends 9 inside the window (the tab art has
        -- 3 of padding); a frame drawn round the window with the game's
        -- faded out ends 4 inside (measured with /efd maptabs).
        local wmf = _G["WorldMapFrame"]
        local nine = wmf and wmf.BorderFrame and wmf.BorderFrame.NineSlice
        local inset = (nine and nine:GetAlpha() < 0.01) and -4 or -12
        -- ClassicUI Forever's own map frame: its edge is the border's.
        local openers = ns.SearchOpeners
        local replaced = openers and openers.Replacement and openers.Replacement("worldMap")
        local own = replaced and replaced.GetFrame("worldMap")
        if own and own:IsVisible() then
            -- Its Era art is 768 rows tall; the last column of the rim is
            -- clear, the edge line in the two before it: the art's flat
            -- side over the outer one.
            local row = own:GetHeight() / 768 * own:GetEffectiveScale() / backTab:GetEffectiveScale()
            wmf, inset = own, -(TabArtInset(backTab) + 2 * row)
        end
        local qTop, wTop = qmf:GetTop(), wmf and wmf:GetTop()
        if qTop and wTop then
            backTab:SetPoint("TOPLEFT", wmf, "TOPRIGHT", inset, qTop - wTop - 28)
        else
            backTab:SetPoint("TOPLEFT", qmf, "TOPRIGHT", -9, -28)
        end
        backTab:Show()
        tabFrame:SetPoint("TOPLEFT", backTab, "BOTTOMLEFT", 0, TAB_STACK_GAP)
    elseif qmf.MapLegendTab then
        tabFrame:SetPoint("TOPLEFT", qmf.MapLegendTab, "BOTTOMLEFT", 0, TAB_STACK_GAP)
    else
        tabFrame:SetPoint("LEFT", qmf, "RIGHT", 0, 0)
    end
    -- Page tabs hang under the search tab in registration order.
    local above = tabFrame
    for i = 1, #pageOrder do
        local tab = extraTabs[pageOrder[i]]
        if tab then
            tab:ClearAllPoints()
            tab:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, TAB_STACK_GAP)
            tab:SetShown(tabFrame:IsShown())
            above = tab
        end
    end
end

function MapTab:Initialize()
    if not IsMapSearchEnabled() then
        lastSelectedWasOurs = false
        if initialized and tabFrame then tabFrame:Hide() end
        for _, extraTab in pairs(extraTabs) do extraTab:Hide() end
        if initialized and panel then
            if panel.outer then panel.outer:Hide() else panel:Hide() end
        end
        if SidePanel.frame then
            HideOurPanel(true)
            SidePanel.Collapse()
            SidePanel.toggle:Hide()
        end
        return
    end
    if initialized then return end
    local qmf = _G["QuestMapFrame"]
    if not (qmf and qmf.MapLegendTab) then
        -- No quest panel with side tabs beside this map: the side panel.
        qmf = SidePanel.Build()
        if not qmf then return end
    end
    initialized = true

    if SidePanel.frame then
        panel = CreatePanel(qmf)
        lastSelectedWasOurs = EasyFind.db.mapSidePanelOpen == true
    else
        tabFrame = CreateTabFrame(qmf)
        panel = CreatePanel(qmf)
        for i = 1, #pageOrder do EnsureExtraTab(pageOrder[i]) end
        PlaceTab()
    end

    -- Hook both qmf and the third-party tab framework's SetDisplayMode
    -- so we catch every tab switch.
    if qmf.SetDisplayMode then
        hooksecurefunc(qmf, "SetDisplayMode", function(_, displayMode)
            if displayMode then
                if not restoringBlizzardDisplayMode then
                    lastSelectedWasOurs = false
                end
                if selectedIsOurs then HideOurPanel(false) end
            end
        end)
    end
    if LibStub then
        local ok, lwmt = pcall(LibStub, "LibWorldMapTabs", true)
        if ok and lwmt and type(lwmt.SetDisplayMode) == "function" then
            hooksecurefunc(lwmt, "SetDisplayMode", function(_, displayMode)
                if displayMode then
                    if not restoringBlizzardDisplayMode then
                        lastSelectedWasOurs = false
                    end
                    if selectedIsOurs then HideOurPanel(false) end
                end
            end)
        end
    end

    -- Re-place on next frame to pick up late-registering third-party
    -- tabs. Opportunistically measure Blizzard's SearchBox so the align
    -- cache populates before the user ever clicks our tab.
    if WorldMapFrame then
        WorldMapFrame:HookScript("OnShow", function()
            PlaceTab()
            SafeAfter(0, PlaceTab)
            SafeAfter(0, function()
                if panel and panel.MeasureBlizzardSearch then
                    panel.MeasureBlizzardSearch()
                end
            end)
            local function shouldRestoreEasyFindTab()
                return lastSelectedWasOurs
                    and not MapTab._pendingFocus
                    and MapTab._pendingQuery == nil
                    and IsMapSearchEnabled()
                    and not (WorldMapFrame.IsMaximized and WorldMapFrame:IsMaximized())
            end
            local function restoreEasyFindTab()
                if shouldRestoreEasyFindTab()
                   and panel
                   and WorldMapFrame and WorldMapFrame:IsShown() then
                    ShowOurPanel()
                end
            end
            -- Switch immediately so the native tab doesn't flash first;
            -- next-frame pass defends against late tab restoration.
            if MapTab._pendingFocus then
                MapTab._pendingFocus = nil
                if panel then
                    ShowOurPanel()
                    if panel.searchBox and selectedIsOurs and panel:IsShown() then
                        panel.searchBox:SetFocus()
                    end
                end
                SafeAfter(0, function()
                    if panel then
                        ShowOurPanel()
                        if panel.searchBox and selectedIsOurs and panel:IsShown() then
                            panel.searchBox:SetFocus()
                        end
                    end
                end)
            end
            if MapTab._pendingQuery ~= nil and not MapTab._pendingFocus then
                local q = MapTab._pendingQuery
                MapTab._pendingQuery = nil
                if panel then
                    ShowOurPanel()
                    if panel.searchBox and panel:IsShown() then
                        panel.searchBox:SetText(q or "")
                        panel.searchBox:ClearFocus()
                    end
                end
                SafeAfter(0, function()
                    if panel then
                        ShowOurPanel()
                        if panel.searchBox and panel:IsShown() then
                            panel.searchBox:SetText(q or "")
                            panel.searchBox:ClearFocus()
                        end
                    end
                end)
            end
            if shouldRestoreEasyFindTab() then
                restoreEasyFindTab()
                SafeAfter(0, restoreEasyFindTab)
            else
                SafeAfter(0, function()
                    local q = Host()
                    if q and q.SetDisplayMode and q.displayMode == nil and not selectedIsOurs then
                        local restore = prevBlizzardDisplayMode or (q.QuestsTab and q.QuestsTab.displayMode) or q.QuestsFrame
                        if restore then pcall(q.SetDisplayMode, q, restore) end
                    end
                end)
            end
        end)
        WorldMapFrame:HookScript("OnHide", function()
            if selectedIsOurs then
                lastSelectedWasOurs = true
                HideOurPanel(true)
            elseif ReleaseMapTabMemory then
                ReleaseMapTabMemory(true)
            end
            -- Close boundary: the release above frees the session's caches
            -- but the old two-step nudge (CollectMapGarbage) never claimed
            -- them, so they sat in the memory meter for minutes. The shared
            -- sweep does (mechanics in Utils.NoteSurfaceClosed).
            Utils.NoteSurfaceClosed("mapSearch", MapShownForSweep, TrimAfterMapSearch)
        end)
    end

    if WorldMapFrame and WorldMapFrame.IsMaximized then
        local function UpdateTabVisibility()
            if SidePanel.frame then SidePanel.Sync() return end
            if not tabFrame then return end
            if not IsMapSearchEnabled() then
                HideOurPanel(true)
                tabFrame:Hide()
                return
            end
            if WorldMapFrame:IsMaximized() then
                HideOurPanel(true)
                tabFrame:Hide()
            else
                tabFrame:Show()
                PlaceTab()
            end
        end
        hooksecurefunc(WorldMapFrame, "Maximize", UpdateTabVisibility)
        hooksecurefunc(WorldMapFrame, "Minimize", UpdateTabVisibility)
        WorldMapFrame:HookScript("OnShow", UpdateTabVisibility)
        UpdateTabVisibility()
    end

    -- "This Zone" label and contents are zone-scoped, so refresh when
    -- the displayed map changes (right-click to zoom out, etc.).
    hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
        if selectedIsOurs and panel and panel:IsShown() then
            RefreshCurrentSearch()
        end
    end)

    -- Consume any Focus() that came in before init completed.
    if MapTab._pendingFocus then
        MapTab._pendingFocus = nil
        SafeAfter(0, function() MapTab:Focus() end)
    end
    if MapTab._pendingQuery ~= nil then
        local q = MapTab._pendingQuery
        MapTab._pendingQuery = nil
        SafeAfter(0, function() MapTab:OpenWithQuery(q) end)
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(_, event, addonName)
    if not IsMapSearchEnabled() then return end
    if event == "ADDON_LOADED" and addonName == "Blizzard_WorldMap" then
        SafeAfter(0, function() MapTab:Initialize() end)
    elseif event == "PLAYER_LOGIN" then
        local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_WorldMap")
        if isLoaded then SafeAfter(0, function() MapTab:Initialize() end) end
    end
end)
