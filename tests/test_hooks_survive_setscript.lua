-- A helper that HookScripts a frame's OnShow or OnHide (the Esc close, the
-- outside-click closer, the menu panel's theme refill, text shading) loses
-- that hook when the caller SetScripts the same handler afterwards. The
-- paste dialog did so after AttachEscClose: hidden, it stayed on the Escape
-- stack and every later Escape press was swallowed (2026-10-27).
local H = require("Harness")

-- helper -> the handlers it hooks on its first argument
local HOOKERS = {
    AttachEscClose = { OnShow = true, OnHide = true },
    AttachOutsideClickClose = { OnShow = true, OnHide = true },
    StyleMenuPanel = { OnShow = true },
    KeepTextShaded = { OnShow = true },
}

-- OnShow owners that refill the menu panel themselves (the dropdown's
-- OnShow, the copy prompt through RepaintThemeFills, the cursor menu's
-- fill pass).
local ALLOWED = {
    ['Search/Filters/Dropdown.lua:dropdown:SetScript("OnShow", function(self)'] = true,
    ['Shared/Utils.lua:prompt:SetScript("OnShow", function(self)'] = true,
    ['Shared/Utils.lua:menu:SetScript("OnShow", CursorMenuOnShow)'] = true,
}

local function Indent(line) return #line:match("^%s*") end

-- Every SetScript of a hooked handler on the same frame later in the block
-- that holds the helper call.
local function Scan(path, lines, bad)
    for i = 1, #lines do
        local line = lines[i]
        if not line:match("^%s*local%s+function") and not line:match("^%s*function") then
            for helper, frame in line:gmatch("([%w_]+)%(%s*([%w_%.]+)%s*[,%)]") do
                local hooked = HOOKERS[helper]
                if hooked then
                    local depth = Indent(line)
                    local pat = frame:gsub("%.", "%%.") .. ':SetScript%(%s*"(On%a+)"'
                    for j = i + 1, #lines do
                        local l = lines[j]
                        local trimmed = l:gsub("^%s+", "")
                        if trimmed ~= "" and Indent(l) < depth and trimmed:find("^end") then break end
                        local handler = l:match(pat)
                        if handler and hooked[handler] and not ALLOWED[path .. ":" .. trimmed] then
                            bad[#bad + 1] = path .. ":" .. j .. ": " .. trimmed .. " drops " .. helper .. "'s hook from line " .. i
                        end
                    end
                end
            end
        end
    end
end

local function Lines(text)
    local lines = {}
    for line in text:gmatch("([^\n]*)\n?") do lines[#lines + 1] = (line:gsub("\r$", "")) end
    return lines
end

local tests = {}

function tests.theScanCatchesTheOrder()
    local bad = {}
    Scan("Sample.lua", Lines([[
local function Build()
    local f = CreateFrame("Frame")
    Utils.AttachEscClose(f)
    f:SetScript("OnHide", function(self) self.cb = nil end)
    f:SetScript("OnClick", function() end)
end
local function Fine()
    local g = CreateFrame("Frame")
    ns.StyleMenuPanel(g)
    g:SetScript("OnHide", function() end)
    Utils.AttachEscClose(g, function() return false end)
end
]]), bad)
    H.assertEq(#bad, 1, table.concat(bad, "\n"))
    H.assertTrue(bad[1]:find("Sample.lua:4:", 1, true) ~= nil, bad[1])
end

function tests.noSetScriptAfterAHookingHelper()
    local p = assert(io.popen('git -C "' .. H.ADDON_ROOT .. '" ls-files "*.lua"'))
    local bad = {}
    for path in p:lines() do
        if not (path:find("^tests/") or path:find("^dev/") or path:find("^API/example/")) then
            local f = assert(io.open(H.ADDON_ROOT .. "/" .. path, "rb"))
            Scan(path, Lines(f:read("*a")), bad)
            f:close()
        end
    end
    p:close()
    H.assertEq(#bad, 0, "set the frame's own scripts before the helper that hooks them:\n  " .. table.concat(bad, "\n  "))
end

local pass, fail, failures = H.runSuite("HooksSurviveSetScript", tests)
return { pass = pass, fail = fail, failures = failures }
