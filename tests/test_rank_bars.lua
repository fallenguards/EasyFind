-- Tests for the classic clients' rank bars: skill rows (Database/Main.lua
-- PopulateDynamicSkills) and talent rows carry their rank, drawn on the
-- reputation row's bar (Search/Results/Render/Reputation.lua).
local H = require("Harness")

local function loadRender()
    local env = H.newEnv()
    env._G = env
    local ns = H.newNs(env)
    local hidden = {}
    ns.ResultRender = { REP_BAR_WIDTH = 100 }
    ns.ResultIcons = { SetRowIcon = function(_, row, kind) hidden[row] = kind == "hidden" end }
    H.loadModule("Search/Results/Render/Reputation.lua", env, ns)
    return ns.ResultRender, hidden
end

local function stubRow()
    local function region()
        local r = { points = {} }
        function r:ClearAllPoints() self.points = {} end
        function r:SetPoint(...) self.points[#self.points + 1] = { ... } end
        function r:Show() self.shown = true end
        function r:Hide() self.shown = false end
        function r:SetWidth(w) self.width = w end
        function r:SetText(t) self.text = t end
        function r:SetVertexColor() end
        function r:SetBackdropColor() end
        function r:IsTruncated() return false end
        return r
    end
    return { repBar = region(), repBarTex = region(), repFill = region(), repClip = region(),
             repBarText = region(), text = region(), icon = region(), SetHeight = function() end }
end

local STATE = { theme = {}, indPx = 10, rowH = 20, rowIconSize = 16 }

-- The flat view's anchoring alone, over a talent row whose spell icon sits
-- at the right edge.
local function loadFlatAnchoring()
    local env = H.newEnv()
    env._G = env
    local ns = H.newNs(env)
    ns.ResultRender = { INDENT_PX = 10, LINE_X_OFF = 0, MAX_DEPTH = 8, IsBossResultData = function() return false end }
    ns.ResultIcons = { IsMenuBarSpecificIconData = function() return false end,
        IsRightSideIconData = function(d) return d.spellID and d.category == "Talent" end }
    H.loadModule("Search/Results/Render/Layout.lua", env, ns)
    return ns.ResultRender
end

-- The skill list's reader (ns.SkillLines) through the named function,
-- sliced from the file and run in env.
local function loadSkillSlice(upTo, env)
    local f = assert(io.open(H.ADDON_ROOT .. "/Database/Main.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("-- The character window's skill list:", 1, true), "the skill list's reader not found")
    local at = assert(src:find(upTo, s, true), upTo .. " not found")
    local _, e = src:find("\nend\r?\n", at)
    assert(e, "end of " .. upTo .. " not found")
    env.ns = env.ns or {}
    env._G = env
    assert(load(src:sub(s, e), "=Main.lua skills", "t", setmetatable(env, { __index = _G })))()
    return env
end

-- The skill reader over a classic skill list (the globals), or Forever's
-- (C_SkillInfo, a table a line).
local function loadSkillReader(lines, forever)
    local data, Database = {}, {}
    local env = { Database = Database, uiSearchData = data, slower = string.lower,
        RemoveEntriesByCategory = function() end, GetTime = function() return 0 end }
    if forever then
        env.C_SkillInfo = {
            GetNumSkillLines = function() return #lines end,
            GetSkillLineInfo = function(i)
                local l = lines[i]
                return { name = l[1], isHeader = l[2], isCollapsed = not l[3], rank = l[4] or 0,
                         tempPoints = l[5] or 0, modifier = l[6] or 0, maxRank = l[7] or 0 }
            end,
        }
    else
        env.GetNumSkillLines = function() return #lines end
        env.GetSkillLineInfo = function(i) return (rawget(table, "unpack") or unpack)(lines[i]) end
    end
    loadSkillSlice("function Database:PopulateDynamicSkills()", env)
    return Database, data
end

local tests = {}

function tests.skillRowsCarryTheirRank()
    local Database, data = loadSkillReader({
        { "Professions", true, true },
        { "Mining", false, nil, 170, 5, 0, 300 },
        { "Weapon Skills", true, true },
        { "Swords", false, nil, 290, 0, 10, 300 },
    })
    H.assertTrue(Database:PopulateDynamicSkills())
    H.assertEq(data[1].skillRank, 175, "temporary points count, as the Skills tab shows")
    H.assertEq(data[1].skillMaxRank, 300)
    H.assertEq(data[2].skillModifier, 10)
    H.assertEq(data[1].skillHeader, "Professions", "the heading the Skills flyout switches")
    H.assertEq(data[2].skillHeader, "Weapon Skills")
end

-- Forever reads its Skills tab through C_SkillInfo, a table a line: the
-- same rows with their bars (no Mining row with its bar there until
-- 2026-11-24).
function tests.foreverSkillRowsCarryTheirRank()
    local Database, data = loadSkillReader({
        { "Professions", true, true },
        { "Mining", false, nil, 170, 5, 0, 300 },
        { "Weapon Skills", true, true },
        { "Swords", false, nil, 290, 0, 10, 300 },
    }, true)
    H.assertTrue(Database:PopulateDynamicSkills())
    H.assertEq(data[1].name, "Mining")
    H.assertEq(data[1].skillRank, 175, "temporary points count")
    H.assertEq(data[1].skillMaxRank, 300)
    H.assertEq(data[2].skillModifier, 10)
    H.assertEq(data[2].skillHeader, "Weapon Skills")
end

-- Forever's list gives each profession twice in a row, the same rank both
-- times: two identical rows showed (2026-11-26, a hunter's Leatherworking).
-- One row a heading's skill.
function tests.foreverDoubledLines_oneRowEach()
    local Database, data = loadSkillReader({
        { "Professions", true, true },
        { "Leatherworking", false, nil, 150, 0, 0, 225 },
        { "Leatherworking", false, nil, 150, 0, 0, 225 },
        { "Skinning", false, nil, 160, 0, 0, 225 },
        { "Skinning", false, nil, 160, 0, 0, 225 },
        { "Weapon Skills", true, true },
        { "Bows", false, nil, 135, 0, 0, 135 },
    }, true)
    H.assertTrue(Database:PopulateDynamicSkills())
    local names = {}
    for i, row in ipairs(data) do names[i] = row.name end
    H.assertEq(table.concat(names, ", "), "Leatherworking, Skinning, Bows")
end

-- The Skills filter's flyout: the skill list's headings, read as it opens.
function tests.skillHeadingsAreTheFlyoutsSwitches()
    local lines = { { "Class Skills", true }, { "Arcane", false }, { "Professions", true }, { "Mining", false } }
    local Database = {}
    loadSkillSlice("function Database.SkillHeadings()", { Database = Database,
        GetNumSkillLines = function() return #lines end,
        GetSkillLineInfo = function(i) return lines[i][1], lines[i][2] end })
    local list = Database.SkillHeadings()
    H.assertEq(#list, 2)
    H.assertEq(list[1].key, "Class Skills")
    H.assertEq(list[2].label, "Professions")

    local config = assert(io.open(H.ADDON_ROOT .. "/Search/Filters/Config.lua", "rb")):read("*a")
    local row = config:match("{ key = \"skills\",.-flyoutList = [^\n]+")
    H.assertTrue(row ~= nil and row:find("hasFlyout = true", 1, true) ~= nil, "the row draws its arrow")
    H.assertTrue(row:find("flyoutDbTable = \"skillFilters\"", 1, true) ~= nil, "its switches' table")
    local core = assert(io.open(H.ADDON_ROOT .. "/Core/Main.lua", "rb")):read("*a")
    H.assertTrue(core:find("skillFilters = {}", 1, true) ~= nil, "a default for the switches")
end

function tests.rankBarText()
    local Render = loadRender()
    local fill, text = Render.GetRankBarInfo({ skillRank = 150, skillMaxRank = 300 })
    H.assertEq(fill, 0.5)
    H.assertEq(text, "150/300")
    H.assertEq(Render.GetRankBarInfo({ skillRank = 1, skillMaxRank = 1 }), nil, "a proficiency has no count")
    local _, modified = Render.GetRankBarInfo({ skillRank = 290, skillMaxRank = 300, skillModifier = 10 })
    H.assertTrue(modified:find("+10", 1, true) ~= nil, "the bonus shows")
    local _, talent = Render.GetRankBarInfo({ talentRank = 0, talentMaxRank = 1, talentTab = 1 })
    H.assertEq(talent, "0/1", "a one-point talent still counts")
    H.assertEq(Render.GetRankBarInfo({ name = "Stormwind" }), nil)
end

-- The bar once sat over the talent's spell icon, its edge peeking out.
function tests.aFlatTalentsBarSitsBeforeItsIcon()
    local Render = loadFlatAnchoring()
    local row = stubRow()
    row.pathSubtext = row.text
    function row.repBar:IsShown() return true end
    function row.icon:IsShown() return true end
    function row.repBar:GetPoint() return self.points[1] and self.points[1][1] end
    row.repBar:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    Render.ApplyFlatResultAnchoring(row, { isFlat = true, data = { spellID = 31687, category = "Talent" } },
        { stackHalfGap = 0, stackGap = 0, indPx = 10 })
    H.assertEq(row.repBar.points[1][2], row.icon, "the bar hangs before the icon")
    H.assertEq(row.repBar.points[1][3], "LEFT")
end

-- A stack's count (x10) sits between the text and the icon: the name and
-- the subtext stop before it, or the subtext ran under the count.
function tests.aStacksCountBoundsTheTextBeforeTheIcon()
    local Render = loadFlatAnchoring()
    local row = stubRow()
    row.pathSubtext = row.text
    function row.repBar:IsShown() return false end
    function row.icon:IsShown() return true end
    row.amountText = { IsShown = function() return true end }
    local entry = { isFlat = true, data = { spellID = 31687, category = "Talent" } }
    Render.ApplyFlatResultAnchoring(row, entry, { stackHalfGap = 0, stackGap = 0, indPx = 10 })
    H.assertEq(row.text.points[2][2], row.amountText, "the text ends before the count")
    H.assertEq(row.text.points[2][3], "LEFT")
    row.amountText.IsShown = function() return false end
    Render.ApplyFlatResultAnchoring(row, entry, { stackHalfGap = 0, stackGap = 0, indPx = 10 })
    H.assertEq(row.text.points[2][2], row.icon, "no count: the icon bounds it")
end

function tests.skillRowHidesItsIconTalentKeepsIt()
    local Render, hidden = loadRender()
    local skillRow, talentRow = stubRow(), stubRow()
    Render.ReputationBar(skillRow, { data = { skillRank = 50, skillMaxRank = 75 } }, STATE, false, false)
    H.assertTrue(skillRow.repBar.shown, "the skill's bar")
    H.assertEq(skillRow.repBarText.text, "50/75")
    H.assertTrue(hidden[skillRow], "the skill's placeholder icon hides")
    Render.ReputationBar(talentRow, { data = { talentRank = 2, talentMaxRank = 5, talentTab = 1 } }, STATE, false, true)
    H.assertTrue(talentRow.repBar.shown, "the talent's bar")
    H.assertFalse(hidden[talentRow] == true, "the talent keeps its icon")
    H.assertEq(talentRow.text.points[1][2], talentRow.icon, "its name starts after the icon")
    local plain = stubRow()
    Render.ReputationBar(plain, { data = { name = "Bank" } }, STATE, false, false)
    H.assertFalse(plain.repBar.shown, "rows without a rank have no bar")
end

local pass, fail, failures = H.runSuite("RankBars", tests)
return { pass = pass, fail = fail, failures = failures }
