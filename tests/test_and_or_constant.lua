-- An and/or chain whose middle is false or nil always gives the last value:
-- `x and nil or y` is y whatever x is, so a switch written that way never
-- saves its off (or its on) and a fallback never falls back. A shipped
-- line stores off-only settings through Utils.OffOrNil.
local H = require("Harness")

-- Lines found when the check grew past false and nil (2026-10-25), each
-- waiting on its own decision.
local KNOWN = {
    -- The Classic skin keeps the parchment behind results: a look to decide.
    ["Search/Results/Theme.lua"] = 1,
    -- Forever's missing sidebar keeps retail's number: /efd sidebars first.
    ["Shared/Caps.lua"] = 1,
}

local function scan(text)
    local hits, n = {}, 0
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        n = n + 1
        local code = line:gsub("%-%-.*$", ""):gsub('"[^"]*"', '""')
        if code:find("and%s+false%s+or%f[%W]") or code:find("and%s+nil%s+or%f[%W]") then
            hits[#hits + 1] = n
        end
    end
    return hits
end

local tests = {}

function tests.noShippedLineHasAConstantAndOr()
    local bad, checked = {}, 0
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "r")
            if fh then
                checked = checked + 1
                local hits = scan(fh:read("a"))
                if #hits > (KNOWN[rel] or 0) then
                    for _, n in ipairs(hits) do bad[#bad + 1] = rel .. ":" .. n end
                end
                fh:close()
            end
        end
    end
    H.assertTrue(checked > 100, "expected the full file set, read " .. checked)
    H.assertEq(#bad, 0, "an and/or that is always one value; use Utils.OffOrNil:\n  " .. table.concat(bad, "\n  "))
end

function tests.scan_flagsBothForms()
    H.assertEq(#scan("db.x = (not v) and false or nil"), 1)
    H.assertEq(#scan("rec.snap = v and nil or false"), 1)
    H.assertEq(#scan('return GPS:Dock() and nil or "no tracker"'), 1, "any value after or")
    H.assertEq(#scan("x = on and false or default"), 1)
    H.assertEq(#scan("x = on and nil_ok or y"), 0, "a name that starts with nil")
end

function tests.scan_skipsCommentsAndStrings()
    H.assertEq(#scan('-- Not "v and nil or false": that is false for both values.'), 0)
    H.assertEq(#scan('local s = "x and false or nil"'), 0)
    H.assertEq(#scan("db.x = Utils.OffOrNil(v)"), 0)
end

function tests.offOrNil_storesOnlyOff()
    local env = setmetatable({}, { __index = _G })
    local f = assert(io.open(H.ADDON_ROOT .. "/Shared/Utils.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function Utils.OffOrNil", 1, true))
    local e = assert(src:find("\nend", s, true))
    env.Utils = {}
    assert(load(src:sub(s, e + 3), "=Utils.lua OffOrNil", "t", env))()
    H.assertEq(env.Utils.OffOrNil(false), false)
    H.assertNil(env.Utils.OffOrNil(true))
    H.assertEq(env.Utils.OffOrNil(nil), false)
end

local pass, fail, failures = H.runSuite("AndOrConstant", tests)
return { pass = pass, fail = fail, failures = failures }
