-- The Forever welcome (Core/Main.lua): on WoW Forever, a chat line at every
-- login on a new client's bugs, its link opening the bug report form, until
-- the player hides it through its own link or the General switch
-- (2026-11-04).
local H = require("Harness")

local function Load(forever)
    local fh = assert(io.open(H.ADDON_ROOT .. "/Core/Main.lua", "rb"))
    local src = fh:read("*a")
    fh:close()
    local s = assert(src:find("\nlocal GITHUB_ISSUES_URL", 1, true))
    local f = assert(src:find("\nlocal function WelcomeForever()", s, true))
    local _, e = src:find("\nend\r?\n", f)
    local env = H.newEnv()
    local ns = H.newNs(env)
    ns.Caps = { forever = forever }
    ns.Utils.SafeAfter = function(_, fn) fn() end
    ns.CHAT_LOGO = ""
    -- Whole-number channels: Lua 5.4's %02x refuses the fractions WoW's 5.1 takes.
    ns.LINK_COLOR = { 0, 1, 1 }
    ns.L.FOREVER_WELCOME, ns.L.WHATSNEW_CHAT_HERE = "Welcome to EasyFind in Forever! Report any issues %s.", "here"
    ns.L.FOREVER_WELCOME_HIDE = "Hide this message in future?"
    local said, dialog, hook = {}, nil, nil
    env.print = function(msg) said[#said + 1] = msg end
    env.hooksecurefunc = function(_, fn) hook = fn end
    env.EasyFind.db = {}
    ns.ShowThemedDialog = function(opts) dialog = opts end
    local chunk = "local _, ns = ...\nlocal Utils, L = ns.Utils, ns.L\nlocal sformat = string.format\n"
        .. "local ErrorHandler = function(e) error(e) end\n"
        .. src:sub(s, e) .. "\nreturn InstallWhatsNewHyperlinkHook, WelcomeForever"
    local install, welcome = assert(load(chunk, "=Core/Main.lua welcome", "t", env))(nil, ns)
    install()
    local function click(link)
        dialog = nil
        hook(link)
        return dialog
    end
    return welcome, said, click, env
end

local function Links(line)
    local out = {}
    for link, label in line:gmatch("|H(.-)|h%[(.-)%]|h") do out[label] = link end
    return out
end

local tests = {}

function tests.forever_everyLogin_reportLinkOpensTheForm()
    local welcome, said, click = Load(true)
    welcome()
    welcome()
    H.assertEq(#said, 2, "at every login")
    H.assertTrue(said[1]:find("in Forever", 1, true) ~= nil)
    local dialog = click(Links(said[1])["here"])
    H.assertNotNil(dialog, "here opens the bug report form")
    H.assertTrue(dialog.editBoxDefault:find("bug_report", 1, true) ~= nil)
end

function tests.itsHideLink_asksThenStopsIt()
    local welcome, said, click, env = Load(true)
    welcome()
    local dialog = click(Links(said[1])["Hide this message in future?"])
    H.assertNotNil(dialog, "a box asks first")
    H.assertNil(env.EasyFind.db.showForeverWelcome, "nothing changes until confirmed")
    dialog.onAccept()
    H.assertEq(env.EasyFind.db.showForeverWelcome, false, "the General switch, off")
    welcome()
    H.assertEq(#said, 1, "not again")
end

function tests.theGeneralSwitchOff_silencesIt_otherClientsNever()
    local welcome, said, _, env = Load(true)
    env.EasyFind.db.showForeverWelcome = false
    welcome()
    H.assertEq(#said, 0)
    welcome, said = Load(false)
    welcome()
    H.assertEq(#said, 0, "Forever only")
end

local pass, fail, failures = H.runSuite("ForeverWelcome", tests)
return { pass = pass, fail = fail, failures = failures }
