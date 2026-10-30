local _, ns = ...

local L = ns.L
local API = EasyFind.API

-- EasyFind's own extensions that load on demand: their tiles stand before
-- their addon has loaded; each fills in the rest from its own files
-- (EasyFind.API.RegisterExtension with the same id) when it loads.
API.RegisterExtension({
    id = "icons", addon = "EasyFind_Icons",
    name = L["ICON_SEARCH_APP"], description = L["APP_DESC_ICONS"],
    icon = ns.ICON_SEARCH_ICON_TEX,
    keywords = { "icons", "icon search" },
})

-- Notes' settings live in EasyFind's save, so its page needs no load.
local function BuildNotesSettings(page, kit)
    local anchor = kit.Title(page, L["APP_NOTES"], L["NOTES_OPT_HINT"])
    local options = { { "notesHereFilter", "NOTES_OPT_HERE" }, { "notesTooltips", "NOTES_OPT_TOOLTIPS" },
                      { "notesChatNames", "NOTES_OPT_CHAT_NAMES" }, { "notesPlayerMenu", "NOTES_OPT_PLAYER_MENU" },
                      { "notesClickHint", "NOTES_OPT_CLICK_HINT" } }
    for i, o in ipairs(options) do
        local key = o[1]
        local box = kit.Checkbox(page, L[o[2]], function() return EasyFind.db[key] ~= false end,
            function(on)
                EasyFind.db[key] = on
                if API.HasAction("notes", "refresh") then API.CallAction("notes", "refresh") end
            end, L[o[2] .. "_TT"])
        box:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, i == 1 and -8 or -2)
        anchor = box
    end
    local open = kit.Button(page, L["NOTES_OPT_OPEN"], 140, 22)
    open:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 8, -12)
    open:SetScript("OnClick", function() API.OpenExtension("notes") end)
end

API.RegisterExtension({
    id = "notes", addon = "EasyFind_Notes", loadInCombat = true,
    name = L["APP_NOTES"], description = L["APP_DESC_NOTES"],
    icon = ns.NOTES_ICON_TEX, iconCoords = ns.NOTES_ICON_COORDS, experimental = L["NOTES_EXP_TT"],
    keywords = { "notes" }, settings = BuildNotesSettings,
})

-- Their search results, the same way: the rows come with the addon.
API.RegisterSearchProvider({
    key = "notes", category = "Notes", extension = "notes",
    label = L["APP_NOTES"], icon = ns.NOTES_ICON_TEX, iconCoords = ns.NOTES_ICON_COORDS,
    words = { "note", "notes" }, lowResults = true, eager = true, aliases = { "note", "notes" },
    -- A note's link: the addon makes the key and the row the reader sees.
    link = {
        key = function(row) return row.noteID and API.CallAction("notes", "linkKey", row.noteID) or nil end,
        resolve = function(tail) return API.CallAction("notes", "linkRow", tail) end,
    },
    options = {
        ns.Extensions.DbOption("notesHereFilter", L["NOTES_OPT_HERE"], L["NOTES_OPT_HERE_TT"]),
        ns.Extensions.DbOption("notesTooltips", L["NOTES_OPT_TOOLTIPS"], L["NOTES_OPT_TOOLTIPS_TT"]),
        ns.Extensions.DbOption("notesChatNames", L["NOTES_OPT_CHAT_NAMES"], L["NOTES_OPT_CHAT_NAMES_TT"]),
        ns.Extensions.DbOption("notesPlayerMenu", L["NOTES_OPT_PLAYER_MENU"], L["NOTES_OPT_PLAYER_MENU_TT"]),
        ns.Extensions.DbOption("notesClickHint", L["NOTES_OPT_CLICK_HINT"], L["NOTES_OPT_CLICK_HINT_TT"]),
        ns.Extensions.DbOption("notesSurfaceHere", L["NOTES_OPT_SURFACE"], L["NOTES_OPT_SURFACE_TT"]),
    },
})

-- The windows that can wear their own look, as pages of the theme studio.
ns.AddThemeSurface("notes", L["APP_NOTES"], { addon = "EasyFind_Notes" })

-- EasyFind's own extensions on CurseForge: the upgrade notice below names
-- them, a click on one gives its page's address. A page waits for its
-- project's slug; split: came inside EasyFind until SPLIT_VERSION.
local PAGE = "https://www.curseforge.com/wow/addons/"
local PAGE_LINK = "easyfind:page:"
local EXTENSIONS_LINK = "easyfind:extensions"
local MENU_CHECK = "Interface\\Buttons\\UI-CheckBox-Check"
local SPLIT_VERSION = "4.0.2"
local FIRST_PARTY = {
    { addon = "EasyFind_Chat", project = "EasyFind: Chat Extension", slug = nil, split = true },
    { addon = "EasyFind_GPS", project = "EasyFind: GPS Navigation Extension", slug = nil, split = true },
    { addon = "EasyFind_Questie", project = "EasyFind: Questie Extension", slug = "easyfind-questie-extension" },
    { addon = "EasyFind_Auctionator", project = "EasyFind: Auctionator Extension", slug = "easyfind-auctionator-extension" },
}
ns.FirstPartyExtensions = FIRST_PARTY

local function Links(pick)
    local list = {}
    for _, e in ipairs(FIRST_PARTY) do
        if e.slug and pick(e) then list[#list + 1] = ns.BlueChatLink(PAGE_LINK .. e.slug, e.project) end
    end
    return list
end

-- A page link clicked in chat: the address to copy (no browser from here).
function ns.ShowExtensionPage(slug)
    for _, e in ipairs(FIRST_PARTY) do
        if e.slug == slug then
            ns.ShowThemedDialog({ text = e.project .. "\n" .. L["EXT_PAGE_COPY"], hasEditBox = true, readOnly = true,
                editBoxDefault = PAGE .. slug, single = true, acceptText = _G["OKAY"] or "Okay" })
            return
        end
    end
end

-- The [Extensions] link: every page in one menu, a click on one its
-- address; a check marks one already installed.
function ns.ShowExtensionPages()
    local rows = {}
    for _, e in ipairs(FIRST_PARTY) do
        if e.slug then
            local have = C_AddOns.DoesAddOnExist(e.addon)
            rows[#rows + 1] = { text = e.project, icon = have and MENU_CHECK or nil,
                tooltip = have and L["EXT_INSTALLED"] or L["EXT_PAGE_TT"],
                onClick = function() ns.ShowExtensionPage(e.slug) end }
        end
    end
    ns.Utils.ShowCursorMenu("EasyFindExtensionPagesMenu", rows, { iconSide = "left" })
end

-- A player upgrading from before the split is told once, in chat: from
-- 4.0.0 or 4.0.1, where Chat and GPS went, then the [Extensions] link;
-- from earlier, the link alone. Noted at the upgrade, told at the next
-- login out of combat.
function ns.NoteUpgrade(from)
    if ns.CompareVersion(from, SPLIT_VERSION) < 0 then EasyFind.db.extensionsNoticeFrom = from end
end

-- installed(addon): the game's answer; a preview passes its own.
local function TellExtensions(installed)
    local db = EasyFind.db
    local from = db and db.extensionsNoticeFrom
    if not from or InCombatLockdown() then return end
    db.extensionsNoticeFrom = nil
    installed = installed or C_AddOns.DoesAddOnExist
    local pages = ns.BlueChatLink(EXTENSIONS_LINK, L["FILTER_EXTENSIONS"])
    local msg
    if ns.CompareVersion(from, "4.0.0") < 0 then
        msg = L["EXT_NEW_FMT"]:format(ns.version, pages)
    else
        local missing = Links(function(e) return e.split and not installed(e.addon) end)
        msg = L["EXT_SPLIT_FMT"]:format(ns.version)
        if #missing == 2 then
            msg = msg .. " " .. L["EXT_SPLIT_GET_FMT"]:format(L["EXT_AND_FMT"]:format(missing[1], missing[2]))
        elseif #missing == 1 then
            msg = msg .. " " .. L["EXT_SPLIT_GET_FMT"]:format(missing[1])
        end
        msg = msg .. " " .. L["EXT_OTHERS_FMT"]:format(pages)
    end
    print(ns.CHAT_LOGO .. msg)
end
ns.TellExtensions = TellExtensions

local noticeWatch = CreateFrame("Frame")
noticeWatch:Hide()
noticeWatch:RegisterEvent("PLAYER_LOGIN")
noticeWatch:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    C_Timer.After(10, TellExtensions)
end)
