local _, ns = ...

local L = ns.L
local API = EasyFind.API

-- EasyFind's own extensions that load on demand: their tiles stand before
-- their addon has loaded; each fills in the rest from its own files
-- (EasyFind.API.RegisterExtension with the same id) when it loads.
API.RegisterExtension({
    id = "icons", addon = "EasyFind_Icons",
    name = L["ICON_SEARCH_APP"], description = L["APP_DESC_ICONS"],
    icon = ns.ICON_SEARCH_ICON_TEX, tint = true,
    keywords = { "icons", "icon search" },
})

API.RegisterExtension({
    id = "notes", addon = "EasyFind_Notes", loadInCombat = true,
    name = L["APP_NOTES"], description = L["APP_DESC_NOTES"],
    icon = ns.NOTES_ICON_TEX, iconCoords = ns.NOTES_ICON_COORDS, tint = true,
    keywords = { "notes" },
})

API.RegisterExtension({
    id = "chat", addon = "EasyFind_Chat", loadInCombat = true,
    name = L["APP_CHAT"], description = L["APP_DESC_CHAT"],
    icon = ns.CHAT_ICON_TEX, tint = true,
    keywords = { "chat" },
})

-- Their search results, the same way: the rows come with the addon.
API.RegisterSearchProvider({
    key = "notes", category = "Notes", extension = "notes",
    label = L["APP_NOTES"], icon = ns.NOTES_ICON_TEX, iconCoords = ns.NOTES_ICON_COORDS, tint = true,
    words = { "note", "notes" }, lowResults = true, eager = true, aliases = { "note", "notes" },
    options = {
        ns.Extensions.DbOption("notesHereFilter", L["NOTES_OPT_HERE"], L["NOTES_OPT_HERE_TT"]),
        ns.Extensions.DbOption("notesTooltips", L["NOTES_OPT_TOOLTIPS"], L["NOTES_OPT_TOOLTIPS_TT"]),
        ns.Extensions.DbOption("notesChatNames", L["NOTES_OPT_CHAT_NAMES"], L["NOTES_OPT_CHAT_NAMES_TT"]),
        ns.Extensions.DbOption("notesPlayerMenu", L["NOTES_OPT_PLAYER_MENU"], L["NOTES_OPT_PLAYER_MENU_TT"]),
        ns.Extensions.DbOption("notesSurfaceHere", L["NOTES_OPT_SURFACE"], L["NOTES_OPT_SURFACE_TT"]),
    },
})

-- Chat's messages: a messenger never opened has nothing to find, so its
-- addon loads for a search only once it has been used.
API.RegisterSearchProvider({
    key = "chat", category = "Chat", extension = "chat",
    label = L["APP_CHAT"], icon = ns.CHAT_ICON_TEX, tint = true,
    words = { "chat", "message", "messages", "whisper", "whispers", "conversation" },
    loadOnSearch = function() return EasyFind.db and EasyFind.db.chatInUse end,
})
