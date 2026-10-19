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
                      { "notesChatNames", "NOTES_OPT_CHAT_NAMES" }, { "notesPlayerMenu", "NOTES_OPT_PLAYER_MENU" } }
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
    local open = API.CreateButton(page, L["NOTES_OPT_OPEN"], 140, 22)
    open:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 8, -12)
    open:SetScript("OnClick", function() API.OpenExtension("notes") end)
end

API.RegisterExtension({
    id = "notes", addon = "EasyFind_Notes", loadInCombat = true,
    name = L["APP_NOTES"], description = L["APP_DESC_NOTES"],
    icon = ns.NOTES_ICON_TEX, iconCoords = ns.NOTES_ICON_COORDS,
    keywords = { "notes" }, settings = BuildNotesSettings,
})

API.RegisterExtension({
    id = "chat", addon = "EasyFind_Chat", loadInCombat = true,
    name = L["APP_CHAT"], description = L["APP_DESC_CHAT"],
    icon = ns.CHAT_ICON_TEX,
    keywords = { "chat" },
})

-- Their search results, the same way: the rows come with the addon.
API.RegisterSearchProvider({
    key = "notes", category = "Notes", extension = "notes",
    label = L["APP_NOTES"], icon = ns.NOTES_ICON_TEX, iconCoords = ns.NOTES_ICON_COORDS,
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
    label = L["APP_CHAT"], icon = ns.CHAT_ICON_TEX,
    words = { "chat", "message", "messages", "whisper", "whispers", "conversation" },
    loadOnSearch = function() return EasyFind.db and EasyFind.db.chatInUse end,
})
