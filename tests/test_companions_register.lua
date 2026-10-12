-- Each companion, loaded the way its toc loads it after the core files it
-- needs, registers with the core.
-- A companion that bails out at load (a namespace field the core no longer
-- has) reads as "unavailable" in game with no error at all.

local H = require("Harness")

local COMPANIONS = {
    { toc = "Apps/Notes/EasyFind_Notes.toc", field = "Notes" },
    { toc = "Apps/Clipboard/EasyFind_Clipboard.toc", field = "Clipboard" },
    { toc = "Apps/Clock/EasyFind_Clock.toc", field = "Clock", core = { "Search/ClockCommands.lua" } },
}

local tests = {}

for _, c in ipairs(COMPANIONS) do
    tests["registers_" .. c.field] = function()
        local env = H.newEnv()
        local ns = H.newNs(env)
        env.EasyFind._ns = ns
        ns.Caps = ns.Caps or { forever = true }
        ns.SearchCommands = ns.SearchCommands or {}
        for _, f in ipairs(c.core or {}) do H.loadModule(f, env, ns) end
        local files = H.TocFiles(c.toc)
        H.assertTrue(files and #files > 0, "the toc lists files")
        local own = {}
        for _, f in ipairs(files) do
            local chunk = assert(loadfile(H.ADDON_ROOT .. "/" .. f, "t", env))
            local ok, err = pcall(chunk, "EasyFind_" .. c.field, own)
            H.assertTrue(ok, f .. " loads: " .. tostring(err))
        end
        H.assertNotNil(ns[c.field], "ns." .. c.field .. " is set")
    end
end

local pass, fail, failures = H.runSuite("CompanionsRegister", tests)
return { pass = pass, fail = fail, failures = failures }
