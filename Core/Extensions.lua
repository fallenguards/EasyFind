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
