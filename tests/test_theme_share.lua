-- Theme share codes (Search/Results/ThemeShare.lua): the EFT1! round trip,
-- what an import refuses or drops, and how custom themes register beside
-- the built-in list.
local H = require("Harness")

local SHIPPED = "Interface\\AddOns\\EasyFind\\textures\\CombinedFillGalaxy"

local function palette(overrides)
    local p = {
        windowFill = { 0.1, 0.2, 0.3 },
        pathColor = { 0.4, 0.5, 0.6, 0.9 },
        pathColorHover = { 1, 1, 1, 1 },
        leafColor = { 0.9, 0.9, 0.9 },
        chromeGlyph = { 1, 1, 1 },
        mutedGlyph = { 0.6, 0.6, 0.6, 0.8 },
        textFaint = { 0.5, 0.5, 0.5 },
        accent = { 0.2, 0.4, 1, 0.8 },
        selection = { 0.3, 0.5, 1, 0.35 },
        separator = { 0.4, 0.4, 0.7, 0.35 },
        backdropColor = { 0.05, 0.05, 0.2, 0.95 },
        backdropBorder = { 0.4, 0.4, 0.7, 1 },
    }
    for k, v in pairs(overrides or {}) do p[k] = v end
    return p
end

local function fresh()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    env.EasyFindDB = {}
    env.EasyFind.db = env.EasyFindDB
    env.UnitName = function() return "Toon" end
    env.GetRealmName = function() return "Realm" end
    ns.Utils.Base64Encode = function(s) return s end
    ns.Utils.Base64Decode = function(s) return s end
    ns.SYSTEM_COMMANDS = { "/reload", "/logout", "/camp", "/quit", "/exit" }
    H.loadModule("Shared/Shortkeys.lua", env, ns)
    ns.UI_THEME_ORDER = { "Black", "Midnight" }
    ns.UI_THEME_PALETTES = { Black = palette(), Midnight = palette() }
    ns.DB_DEFAULTS = { uiTheme = "Black" }
    ns.applied = {}
    ns.ApplyUITheme = function(name) ns.applied[#ns.applied + 1] = name end
    H.loadModule("Search/Results/ThemeShare.lua", env, ns)
    return env, ns, ns.ThemeShare
end

local tests = {}

function tests.roundTrip_keepsSlotsFlagsAndShippedArt()
    local _, _, Share = fresh()
    local src = palette({ light = true, borderHidden = true, fillTexture = SHIPPED,
        rowHover = { 0.2, 0.2, 0.25 }, borderColor = { 0.5, 0.6, 0.7, 0.4 } })
    local code = Share:ExportPalette("Dusk", src)
    H.assertEq(code:sub(1, 5), "EFT1!", "code prefix")
    local name, out = Share:Decode(code)
    H.assertEq(name, "Dusk")
    H.assertEq(out.light, true)
    H.assertEq(out.borderHidden, true)
    H.assertEq(out.fillTexture, SHIPPED)
    H.assertEq(out.rowHover[3], 0.25)
    H.assertEq(out.borderColor[4], 0.4)
    H.assertEq(out.pathColor[4], 0.9)
    H.assertEq(out.windowFill[1], 0.1)
end

function tests.decode_refusesForeignCodes()
    local _, _, Share = fresh()
    H.assertNil(Share:Decode("EF1!aliases"), "shortkey code")
    H.assertNil(Share:Decode("EFT1!EFTHEME1garbage"), "broken fields")
    H.assertNil(Share:Decode(42), "not a string")
end

function tests.import_refusesMissingRequiredSlot()
    local _, _, Share = fresh()
    local src = palette()
    src.leafColor = nil
    H.assertNil(Share:Import(Share:ExportPalette("NoLeaf", src)))
end

function tests.import_dropsUnshippedArtAndSavesTheRest()
    local env, ns, Share = fresh()
    local src = palette({ fillTexture = "Interface\\AddOns\\Other\\art" })
    local name = Share:Import(Share:ExportPalette("Ember", src))
    H.assertEq(name, "Ember")
    local stored = env.EasyFindDB.customThemes.Ember
    H.assertNil(stored.fillTexture, "foreign art dropped")
    H.assertEq(ns.UI_THEME_PALETTES.Ember, stored, "registered palette")
    H.assertEq(ns.UI_THEME_ORDER[3], "Ember", "appended after the built-ins")
end

function tests.save_suffixesBuiltinNameAndKeepsOrderSorted()
    local _, ns, Share = fresh()
    H.assertEq(Share:SaveCustomTheme("Black", palette()), "Black 2")
    Share:SaveCustomTheme("Amber", palette())
    H.assertEq(ns.UI_THEME_ORDER[1], "Black")
    H.assertEq(ns.UI_THEME_ORDER[2], "Midnight")
    H.assertEq(ns.UI_THEME_ORDER[3], "Amber")
    H.assertEq(ns.UI_THEME_ORDER[4], "Black 2")
    H.assertTrue(Share:IsBuiltinName(" black "), "case and spaces")
    H.assertTrue(not Share:IsBuiltinName("Amber"), "custom is not builtin")
    H.assertTrue(Share:IsCustomTheme("Amber"))
end

function tests.register_dropsBadStoredEntries()
    local env, ns, Share = fresh()
    env.EasyFindDB.customThemes = {
        Good = palette(),
        Bad = palette({ accent = { 9, 9, 9 } }),
        ["  Rust\n"] = palette(),
        Midnight = palette(),
    }
    Share:RegisterCustomThemes()
    local store = env.EasyFindDB.customThemes
    H.assertNotNil(store.Good)
    H.assertNil(store.Bad, "out of range color")
    H.assertNil(store["  Rust\n"], "whitespace and control chars stripped")
    H.assertNotNil(store.Rust, "cleaned name kept")
    H.assertNil(store.Midnight, "built-in name refused")
    H.assertEq(#ns.UI_THEME_ORDER, 4)
end

function tests.delete_fallsBackTheActiveTheme()
    local env, ns, Share = fresh()
    Share:SaveCustomTheme("Amber", palette())
    env.EasyFind.db.uiTheme = "Amber"
    H.assertTrue(Share:DeleteCustomTheme("Amber"))
    H.assertEq(env.EasyFind.db.uiTheme, "Black")
    H.assertEq(ns.applied[#ns.applied], "Black")
    H.assertNil(ns.UI_THEME_PALETTES.Amber)
    H.assertEq(#ns.UI_THEME_ORDER, 2)
    H.assertTrue(not Share:DeleteCustomTheme("Amber"), "second delete finds nothing")
end

-- A theme with the Notes window in a light look of its own.
local function withNotes()
    return palette({ surfaces = { notes = palette({ light = true, windowFill = { 0.8, 0.8, 0.7 } }) } })
end

function tests.roundTrip_keepsEachWindowsOwnLook()
    local _, _, Share = fresh()
    local name, out = Share:Decode(Share:ExportPalette("Split", withNotes()))
    H.assertEq(name, "Split")
    local notes = out.surfaces and out.surfaces.notes
    H.assertNotNil(notes, "the Notes window's look came through")
    H.assertEq(notes.light, true)
    H.assertEq(notes.windowFill[1], 0.8)
    H.assertEq(out.light, nil, "the shared look stays dark")
end

function tests.save_keepsEachWindowsOwnLook()
    local env, _, Share = fresh()
    local saved = Share:Import(Share:ExportPalette("Split", withNotes()))
    local stored = env.EasyFindDB.customThemes[saved]
    H.assertNotNil(stored.surfaces and stored.surfaces.notes, "saved with the Notes look")
end

function tests.validate_dropsABadWindowLookNotTheTheme()
    local _, _, Share = fresh()
    local raw = withNotes()
    raw.surfaces["bad id!"] = palette()
    raw.surfaces.gps = { windowFill = { 0.1, 0.1, 0.1 } }
    raw.surfaces.notes.surfaces = { deeper = palette() }
    local clean = Share.ValidatePalette(raw)
    H.assertNotNil(clean, "the theme stands")
    H.assertNotNil(clean.surfaces.notes, "the good look stays")
    H.assertNil(clean.surfaces["bad id!"], "a bad window id goes")
    H.assertNil(clean.surfaces.gps, "a look missing its slots goes")
    H.assertNil(clean.surfaces.notes.surfaces, "looks never nest")
end

local pass, fail, failures = H.runSuite("ThemeShare", tests)
return { pass = pass, fail = fail, failures = failures }
