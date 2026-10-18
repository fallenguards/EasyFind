-- The client refuses these frame methods to addons in a fight
-- (HasRestrictions in its API docs): a shipped line calls them only through
-- Utils.SafeCallMethod, which skips them in combat.
local H = require("Harness")

local RESTRICTED = {
    "SetPassThroughButtons",
    "SetPropagateKeyboardInput",
    "SetPropagateMouseClicks",
    "SetPropagateMouseMotion",
}

local function scan(text)
    local hits = {}
    local n = 0
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        n = n + 1
        local code = line:gsub("%-%-.*$", "")
        for _, name in ipairs(RESTRICTED) do
            if code:find("[:.]" .. name .. "%s*%(") then hits[#hits + 1] = n .. ": " .. name end
        end
    end
    return hits
end

local tests = {}

function tests.noShippedLineCallsARestrictedMethodBare()
    local bad, checked = {}, 0
    for _, toc in ipairs(H.TOCS) do
        for _, rel in ipairs((H.TocFiles(toc))) do
            local fh = io.open(H.ADDON_ROOT .. "/" .. rel, "r")
            if fh then
                checked = checked + 1
                for _, hit in ipairs(scan(fh:read("a"))) do bad[#bad + 1] = rel .. ":" .. hit end
                fh:close()
            end
        end
    end
    H.assertTrue(checked > 100, "expected the full file set, read " .. checked)
    H.assertEq(#bad, 0, "call these through Utils.SafeCallMethod:\n  " .. table.concat(bad, "\n  "))
end

function tests.scan_flagsTheBareCall()
    H.assertEq(#scan("plate:SetPropagateMouseClicks(not shift)"), 1)
    H.assertEq(#scan("f.SetPropagateKeyboardInput(f, false)"), 1)
end

function tests.scan_acceptsTheGuardedCall()
    H.assertEq(#scan('Utils.SafeCallMethod(self, "SetPropagateKeyboardInput", false)'), 0)
    H.assertEq(#scan("-- plate:SetPropagateMouseClicks(true) is refused in a fight"), 0)
    H.assertEq(#scan("if plate.SetPropagateMouseClicks then"), 0)
end

local pass, fail, failures = H.runSuite("CombatRestricted", tests)
return { pass = pass, fail = fail, failures = failures }
