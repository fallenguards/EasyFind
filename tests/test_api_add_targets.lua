-- Where an extension's entries show (Core/API.lua): the filter menu's
-- Extensions flyout names the extension, not its rows, and an extension's
-- Add entry (RegisterAddTarget) joins the right-click Add flyout with the
-- extension's icon, as Note and Quicklist wear theirs (Shared/Utils.lua
-- ShowPinMenu).
local H = require("Harness")

local function fakeWidget()
    local w = {}
    setmetatable(w, { __index = function() return function() return w end end })
    return w
end

local function World()
    local env = H.newEnv()
    local ns = H.newNs(env)
    ns.L.EXT_FILTER_NAMED_FMT = "%s: %s"
    local filterRows = {}
    ns.Filters.AddExtensionFilter = function(row) filterRows[#filterRows + 1] = row end
    return env, ns, env.EasyFind.API, filterRows
end

local function Rows() return {} end

local tests = {}

function tests.theFlyoutNamesTheExtension()
    local _, _, API, filterRows = World()
    API.RegisterExtension({ id = "auctionator", name = "Auctionator", icon = 1 })
    API.RegisterSearchProvider({ key = "lists", label = "Shopping Lists", extension = "auctionator", rows = Rows })
    H.assertEq(filterRows[1].label, "Auctionator")
    API.RegisterSearchProvider({ key = "prices", label = "Prices", extension = "auctionator", rows = Rows })
    H.assertEq(filterRows[1].label, "Auctionator: Shopping Lists", "two providers: each says which")
    H.assertEq(filterRows[2].label, "Auctionator: Prices")
    API.RegisterSearchProvider({ key = "loose", label = "Bookmarks", icon = 2, rows = Rows })
    H.assertEq(filterRows[3].label, "Bookmarks", "no extension: its own label")
end

function tests.anAddTargetNeedsItsExtension()
    local _, ns, API = World()
    H.assertFalse(pcall(API.RegisterAddTarget, { key = "lists", label = "Shopping list", rows = Rows }), "no extension")
    H.assertFalse(pcall(API.RegisterAddTarget, { key = "lists", extension = "nobody", label = "Shopping list", rows = Rows }),
        "not registered")
    API.RegisterExtension({ id = "auctionator", name = "Auctionator", icon = 1 })
    H.assertTrue(API.RegisterAddTarget({ key = "lists", extension = "auctionator", label = "Shopping list", rows = Rows }))
    API.RegisterAddTarget({ key = "lists", extension = "auctionator", label = "Shopping lists", rows = Rows })
    H.assertEq(#ns.Extensions.AddTargets, 1, "a key again replaces it")
    H.assertEq(ns.Extensions.AddTargets[1].label, "Shopping lists")
end

-- The Add flyout: Note, Quicklist and an extension's entry, each with
-- its icon; a core entry (Alias) has none.
function tests.addEntriesWearTheirIcons()
    local env, ns, API = World()
    env.CreateFont, env.CreateFrame = fakeWidget, fakeWidget
    env.CreateColor = function(r, g, b, a) return { GetRGBA = function() return r, g, b, a end } end
    env.UIParent, env.WorldFrame, env.GameTooltip = fakeWidget(), fakeWidget(), fakeWidget()
    env.hooksecurefunc = function() end
    env.GameFontNormal = setmetatable({}, { __index = function(_, k)
        if k == "GetFont" then return function() return "font", 12, "" end end
        return function() end
    end })
    H.loadModule("Shared/Utils.lua", env, ns)
    local Utils = ns.Utils
    local shown
    Utils.ShowCursorMenu = function(_, rows) shown = rows end
    API.RegisterExtension({ id = "notes", name = "Notes", icon = "notes-icon" })
    API.RegisterExtension({ id = "quicklists", name = "Quicklists", icon = "quicklists-icon" })
    API.RegisterExtension({ id = "auctionator", name = "Auctionator", icon = "auctionator-icon" })
    local clicked = false
    local extra = {
        addNoteRows = { { text = "New note" } },
        addQuicklistRows = { { text = "Main" } },
        addTargets = { { text = "Shopping list", fullText = "Add to shopping list", icon = "auctionator-icon",
                         chromeIcon = true, submenu = { { text = "Mats" } }, onClick = function() clicked = true end } },
    }
    Utils.ShowPinMenu("EFTestMenu", false, nil, nil, function() end, nil, extra)
    local add
    for _, r in ipairs(shown) do
        if r.submenu and r.submenu[1] and r.submenu[1].fullText then add = r.submenu end
    end
    H.assertNotNil(add, "an Add flyout")
    local byText = {}
    for _, r in ipairs(add) do byText[r.fullText or r.text] = r end
    H.assertEq(byText[ns.L["CTX_ADD_NOTE"]].icon, "notes-icon")
    H.assertEq(byText[ns.L["CTX_ADD_QUICKLIST"]].icon, "quicklists-icon")
    H.assertEq(byText["Add to shopping list"].icon, "auctionator-icon")
    byText["Add to shopping list"].onClick()
    H.assertTrue(clicked, "the entry's own click (a new list), its lists still a flyout")
    H.assertEq(byText["Add to shopping list"].submenu[1].text, "Mats")
    H.assertNil(byText[ns.L["CTX_ADD_ALIAS"]].icon, "a core entry has none")
end

local pass, fail, failures = H.runSuite("ApiAddTargets", tests)
return { pass = pass, fail = fail, failures = failures }
