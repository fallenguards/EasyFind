-- Every companion's toc names the same game versions as the core: a
-- companion left behind reads as out of date after a patch.

local H = require("Harness")

local function interfaceLine(tocPath)
    local fh = io.open(H.ADDON_ROOT .. "/" .. tocPath, "r")
    if not fh then return nil end
    for line in fh:lines() do
        local versions = line:gsub("\r$", ""):match("^## Interface:%s*(.-)%s*$")
        if versions then
            fh:close()
            return versions
        end
    end
    fh:close()
end

local function companionTocsOnDisk()
    local found = {}
    local root = H.ADDON_ROOT:gsub("\\", "/")
    local handle = io.popen(string.format([[ls "%s"/Apps/*/*.toc 2>/dev/null]], root))
    if handle then
        for line in handle:lines() do
            found[#found + 1] = line:sub(#root + 2)
        end
        handle:close()
    end
    if #found == 0 then
        handle = io.popen(string.format([[cmd /c "dir /b /s "%s\Apps\*.toc" 2>nul"]], H.ADDON_ROOT))
        if handle then
            for line in handle:lines() do
                local rel = line:gsub("\\", "/"):match("(Apps/[^/]+/[^/]+%.toc)$")
                if rel then found[#found + 1] = rel end
            end
            handle:close()
        end
    end
    return found
end

local tests = {}

function tests.everyToc_sameInterfaceAsCore()
    local core = interfaceLine("EasyFind.toc")
    H.assertNotNil(core, "EasyFind.toc has an Interface line")
    for _, toc in ipairs(H.TOCS) do
        H.assertEq(interfaceLine(toc), core, toc .. " Interface")
    end
end

function tests.everyCompanionToc_isListed()
    local listed = {}
    for _, toc in ipairs(H.TOCS) do listed[toc] = true end
    local found = companionTocsOnDisk()
    H.assertTrue(#found > 0, "companion tocs found on disk")
    for _, toc in ipairs(found) do
        H.assertTrue(listed[toc], toc .. " is in Harness.TOCS")
    end
end

local pass, fail, failures = H.runSuite("TocInterface", tests)
return { pass = pass, fail = fail, failures = failures }
