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

API.RegisterExtension({
    id = "chat", addon = "EasyFind_Chat", loadInCombat = true, loadAtLogin = true,
    name = L["APP_CHAT"], description = L["APP_DESC_CHAT"],
    icon = ns.CHAT_ICON_TEX, experimental = L["CHAT_EXP_TT"],
    keywords = { "chat" },
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

-- Chat's conversations, and its messages only when asked: a row for every
-- message crowded other searches out. A messenger never opened has nothing
-- to find, so its addon loads for a search only once it has been used.
local function RefreshChatRows() API.RefreshSearchProvider("chat") end
API.RegisterSearchProvider({
    key = "chat", category = "Chat", extension = "chat",
    label = L["APP_CHAT"], icon = ns.CHAT_ICON_TEX,
    words = { "chat", "message", "messages", "whisper", "whispers", "conversation" },
    loadOnSearch = function() return EasyFind.db and EasyFind.db.chatInUse end,
    options = {
        ns.Extensions.DbOption("chatFindChats", L["CHAT_OPT_CHATS"], L["CHAT_OPT_CHATS_TT"], RefreshChatRows),
        { label = L["CHAT_OPT_MESSAGES"], tooltip = L["CHAT_OPT_MESSAGES_TT"],
          get = function() return EasyFind.db.chatFindMessages == true end,
          set = function(on)
              EasyFind.db.chatFindMessages = on
              RefreshChatRows()
          end },
    },
})

-- Chat and GPS came inside EasyFind until each became an addon of its own:
-- a player who used one and lacks it now is told once, with its page to
-- copy. A page waits for its project's slug.
local MOVED_PAGE = "https://www.curseforge.com/wow/addons/"
local MOVED = {
    { addon = "EasyFind_Chat", name = L["APP_CHAT"], project = "EasyFind: Chat Extension", slug = nil,
      used = function(db) return db.chatInUse == true end },
    { addon = "EasyFind_GPS", name = L["APP_GPS"], project = "EasyFind: GPS Navigation Extension", slug = nil,
      used = function(db)
          for key in pairs(db) do
              if type(key) == "string" and key:sub(1, 3) == "gps" then return true end
          end
          return false
      end },
}

local function TellMoved()
    local db = EasyFind.db
    if not db or InCombatLockdown() then return end
    db.movedTold = type(db.movedTold) == "table" and db.movedTold or {}
    for _, m in ipairs(MOVED) do
        if m.slug and not db.movedTold[m.addon] and m.used(db) and not C_AddOns.DoesAddOnExist(m.addon) then
            db.movedTold[m.addon] = true
            ns.ShowThemedDialog({
                text = L["EXT_MOVED_FMT"]:format(m.name, m.project),
                hasEditBox = true, readOnly = true, editBoxDefault = MOVED_PAGE .. m.slug,
                single = true, acceptText = _G["OKAY"] or "Okay",
                onAccept = function() C_Timer.After(0.5, TellMoved) end,
            })
            return
        end
    end
end

local movedWatch = CreateFrame("Frame")
movedWatch:Hide()
movedWatch:RegisterEvent("PLAYER_LOGIN")
movedWatch:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    C_Timer.After(10, TellMoved)
end)
