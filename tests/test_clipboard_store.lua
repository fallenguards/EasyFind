-- Tests for Apps/Clipboard/Store.lua: classification, repeat merging, the
-- cap and the age limit, remove and clear, and the row text helpers.
local H = require("Harness")

local function fresh()
    local env = H.newEnv()
    local ns = H.newNs(env)
    env.EasyFind._ns = ns
    env.EasyFindDB = {}
    H.loadModule("Apps/Clipboard/Store.lua", env, ns)
    H.assertNotNil(ns.ClipboardStore, "Store.lua must populate ns.ClipboardStore")
    return env, ns.ClipboardStore
end

local tests = {}

function tests.classify_kinds()
    local _, Store = fresh()
    H.assertEq(Store.Classify("[Thunderfury]", "|cffff8000|Hitem:19019::::::::70:::::|h[Thunderfury]|h|r"), "link")
    H.assertEq(Store.Classify("[EasyFind: Dash]", nil), "eflink")
    H.assertEq(Store.Classify("[Map Pin Location]", "|cffffff00|Hworldmap:2248:4521:2100|h[Map Pin Location]|h|r"), "mappin")
    H.assertEq(Store.Classify("https://www.wowhead.com/item=19019", nil), "url")
    H.assertEq(Store.Classify("/cast Dash", nil), "command")
    H.assertEq(Store.Classify("4g / 5", nil), "number")
    H.assertEq(Store.Classify("1234", nil), "number")
    H.assertEq(Store.Classify("meet at the summoning stone", nil), "text")
end

function tests.record_newestFirst_withKindAndCount()
    local _, Store = fresh()
    Store:Record("copied", "first", nil, { now = 100 })
    local e = Store:Record("pasted", "https://example.com", nil, { now = 110 })
    H.assertEq(Store:Count(), 2)
    H.assertEq(Store:Entries()[1].text, "https://example.com")
    H.assertEq(e.kind, "url")
    H.assertEq(e.source, "pasted")
    H.assertEq(e.count, 1)
end

function tests.record_sameTextMovesToTopAndCounts()
    local _, Store = fresh()
    Store:Record("copied", "alpha", nil, { now = 100 })
    Store:Record("copied", "beta", nil, { now = 200 })
    local e = Store:Record("chat", "alpha", nil, { now = 300, sender = "Bob" })
    H.assertEq(Store:Count(), 2)
    H.assertEq(Store:Entries()[1].text, "alpha")
    H.assertEq(e.count, 2)
    H.assertEq(e.source, "chat")
    H.assertEq(e.sender, "Bob")
end

function tests.record_repeatWithinWindowIsOneEvent()
    local _, Store = fresh()
    Store:Record("chat", "[Thing]", "|Hitem:1|h[Thing]|h", { now = 100 })
    local e = Store:Record("chat", "[Thing]", "|Hitem:1|h[Thing]|h", { now = 101 })
    H.assertEq(Store:Count(), 1)
    H.assertEq(e.count, 1)
end

function tests.record_ignoresBlankAndNonString()
    local _, Store = fresh()
    H.assertNil(Store:Record("copied", "   ", nil, { now = 1 }))
    H.assertNil(Store:Record("copied", nil, nil, { now = 1 }))
    H.assertNil(Store:Record("copied", 42, nil, { now = 1 }))
    H.assertEq(Store:Count(), 0)
end

function tests.record_linkDistinguishesEntries()
    local _, Store = fresh()
    Store:Record("chat", "[Thing]", "|Hitem:1|h[Thing]|h", { now = 100 })
    Store:Record("chat", "[Thing]", "|Hitem:2|h[Thing]|h", { now = 200 })
    H.assertEq(Store:Count(), 2)
end

function tests.prune_capKeepsNewest()
    local _, Store = fresh()
    Store.MAX_ENTRIES = 3
    for i = 1, 5 do Store:Record("copied", "t" .. i, nil, { now = i * 10 }) end
    H.assertEq(Store:Count(), 3)
    H.assertEq(Store:Entries()[1].text, "t5")
    H.assertEq(Store:Entries()[3].text, "t3")
end

function tests.prune_ageDropsOld()
    local _, Store = fresh()
    Store.MAX_AGE = 100
    Store:Record("copied", "old", nil, { now = 0 })
    Store:Record("copied", "new", nil, { now = 150 })
    H.assertEq(Store:Count(), 1)
    H.assertEq(Store:Entries()[1].text, "new")
end

function tests.remove_and_clear()
    local _, Store = fresh()
    local a = Store:Record("copied", "a", nil, { now = 1 })
    Store:Record("copied", "b", nil, { now = 2 })
    H.assertTrue(Store:Remove(a.id))
    H.assertFalse(Store:Remove(a.id))
    H.assertEq(Store:Count(), 1)
    H.assertNotNil(Store:Get(Store:Entries()[1].id))
    Store:Clear()
    H.assertEq(Store:Count(), 0)
end

function tests.firstLine_stripsMarkupAndCuts()
    local _, Store = fresh()
    H.assertEq(Store.FirstLine("|cffff0000red|r line\nsecond"), "red line")
    local long = string.rep("x", 100)
    local line = Store.FirstLine(long)
    H.assertEq(#line, Store.FIRST_LINE_MAX)
    H.assertEq(line:sub(-3), "...")
end

function tests.cutBytes_neverSplitsUtf8()
    local _, Store = fresh()
    local s = "ab" .. "\195\169" .. "cd"   -- "abécd"
    H.assertEq(Store.CutBytes(s, 3), "ab")
    H.assertEq(Store.CutBytes(s, 4), "ab\195\169")
    H.assertEq(Store.CutBytes(s, 99), s)
end

function tests.settings_defaults_dbOverrides()
    local env, Store = fresh()
    local s = Store:Settings()
    -- The player's own copies and pastes record; chat is opt-in, since
    -- trade and city chat carry far more junk than links worth keeping.
    H.assertTrue(s.copied); H.assertTrue(s.pasted); H.assertFalse(s.chat); H.assertFalse(s.whispers)
    env.EasyFind.db = { clipboardPasted = false, clipboardChat = true }
    H.assertFalse(Store:Settings().pasted)
    H.assertTrue(Store:Settings().copied)
    H.assertTrue(Store:Settings().chat)
end

function tests.record_keepsCopiedAndPastedTimes()
    local _, Store = fresh()
    local e = Store:Record("copied", "[Thunderfury]", "|Hitem:19019|h[Thunderfury]|h", { now = 100 })
    H.assertEq(e.copiedAt, 100)
    H.assertNil(e.pastedAt)
    local again = Store:Record("pasted", "[Thunderfury]", "|Hitem:19019|h[Thunderfury]|h", { now = 500 })
    H.assertTrue(again == e, "same entry")
    H.assertEq(e.copiedAt, 100, "the copy time survives the paste")
    H.assertEq(e.pastedAt, 500)
    H.assertEq(e.source, "pasted")
    local chat = Store:Record("chat", "[Hi]", "|Hitem:1|h[Hi]|h", { now = 700 })
    H.assertNil(chat.copiedAt)
    H.assertNil(chat.pastedAt)
end

function tests.clear_keepsPinned()
    local _, Store = fresh()
    local keep = Store:Record("copied", "keep me", nil, { now = 1 })
    Store:Record("copied", "drop me", nil, { now = 2 })
    Store:Record("pasted", "drop me too", nil, { now = 3 })
    Store:SetPinned(keep.id, true)
    Store:Clear()
    H.assertEq(Store:Count(), 1, "the pin survives a clear")
    H.assertEq(Store:Entries()[1].text, "keep me")
end

function tests.longText_isCut()
    local _, Store = fresh()
    local e = Store:Record("pasted", string.rep("y", Store.MAX_TEXT + 50), nil, { now = 1 })
    H.assertEq(#e.text, Store.MAX_TEXT)
end

local pass, fail, failures = H.runSuite("ClipboardStore", tests)
return { pass = pass, fail = fail, failures = failures }
