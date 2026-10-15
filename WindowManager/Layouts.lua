local _, ns = ...

-- Window layouts: a named arrangement of the open windows and their zones,
-- saved from the screen as it stands and applied as one. Every window of
-- it is opened and put in its zone for the moment; when all of it is open
-- already, it is closed as one. The standing layout's zones are kept. Each
-- layout is a result row, searched and bound to a key like any; the
-- "layout for here" row applies the one saved nearest to where the player
-- is (the same zone, the same kind of instance, a rest spot, the open world).
local Layouts = {}
ns.WindowLayouts = Layouts

local L = ns.L
local Utils = ns.Utils
local sformat = string.format
local tinsert, tremove = table.insert, table.remove

local NAME_MAX = 24

local function Store()
    local db = EasyFind and EasyFind.db
    if not db then return nil end
    db.windowLayouts = db.windowLayouts or {}
    return db.windowLayouts
end

local function Print(msg)
    if EasyFind and EasyFind.Print then EasyFind:Print(msg) end
end

function Layouts:All() return Store() or {} end

function Layouts:Get(id)
    for _, layout in ipairs(self:All()) do
        if layout.id == id then return layout end
    end
    return nil
end

-- Where the player is, as a layout remembers its saving place: the zone
-- map, the kind of instance, whether at rest (a city or an inn).
local function Here()
    local _, kind = IsInInstance()
    return { map = C_Map.GetBestMapForUnit("player"), kind = kind ~= "none" and kind or nil,
             resting = IsResting() and true or false }
end

-- How well a layout's saving place fits here: the same zone, the same
-- kind of instance, both at rest, both out in the world; 0 for no fit.
function Layouts.Rank(at, here)
    if not at then return 1 end
    if at.map and at.map == here.map then return 4 end
    if at.kind and at.kind == here.kind then return 3 end
    if at.resting and here.resting then return 2 end
    if not (at.kind or here.kind or at.resting or here.resting) then return 1 end
    return 0
end

-- The layout fitting here best; among equals the one used last.
function Layouts:ForHere()
    local here = Here()
    local best, bestRank, bestUsed = nil, 0, -1
    for _, layout in ipairs(self:All()) do
        local rank, used = Layouts.Rank(layout.at, here), layout.used or 0
        if rank > bestRank or (rank == bestRank and rank > 0 and used > bestUsed) then
            best, bestRank, bestUsed = layout, rank, used
        end
    end
    return best
end

-- The open registered windows as they stand, each with its zone where snapped.
local function Snapshot()
    local Registry, Manager = ns.WindowRegistry, ns.WindowManager
    local out = {}
    Registry:ForEach(function(entry)
        local frame = Registry:GetFrame(entry)
        if frame and frame:IsShown() and not entry.own then
            local _, _, _, _, key = Manager:GetAppliedZone(entry.name)
            out[#out + 1] = { name = entry.name, spec = key }
        end
    end)
    return out
end

local function Changed()
    if ns.Database and ns.Database.RefreshDynamicCategory then ns.Database:RefreshDynamicCategory("window") end
    if ns.Options and ns.Options.RefreshWindowLayouts then ns.Options:RefreshWindowLayouts() end
end

-- Saved from the screen as it stands, under the name asked for; a layout
-- of that name is replaced.
function Layouts:PromptSave()
    local windows = Snapshot()
    if #windows == 0 then
        Print(L["WINDOW_LAYOUT_NONE"])
        return false
    end
    ns.ShowThemedDialog({
        text = L["WINDOW_LAYOUT_NAME_PROMPT"],
        hasEditBox = true,
        maxLetters = NAME_MAX,
        acceptText = _G["SAVE"] or "Save",
        onAccept = function(value)
            local name = (value or ""):match("^%s*(.-)%s*$")
            local store = Store()
            if name == "" or not store then return end
            for i = #store, 1, -1 do
                if store[i].name == name then tremove(store, i) end
            end
            tinsert(store, { id = sformat("%d.%d", time(), #store + 1), name = name, windows = windows,
                             at = Here(), used = time() })
            Print(sformat(L["WINDOW_LAYOUT_SAVED_FMT"], name, #windows))
            Changed()
        end,
    })
    return true
end

local function AllShown(windows)
    local Registry = ns.WindowRegistry
    for _, w in ipairs(windows) do
        local frame = Registry:GetFrame(Registry:GetEntryByName(w.name))
        if not (frame and frame:IsShown()) then return false end
    end
    return true
end

local function Close(entry, frame)
    if entry.uiPanel and HideUIPanel then
        Utils.SecureCall(HideUIPanel, frame)
    else
        frame:Hide()
    end
end

local function Open(entry, frame)
    if entry.open then
        xpcall(entry.open, Utils.ErrorHandler)
    elseif frame and ShowUIPanel then
        Utils.SecureCall(ShowUIPanel, frame)
    end
end

-- Applied as one: every window of it opened and put in its zone for the
-- moment (for keeps, from the standing layout); all of it open already:
-- closed as one.
function Layouts:Apply(id)
    local layout = self:Get(id)
    local Registry, Manager = ns.WindowRegistry, ns.WindowManager
    if not (layout and Registry and Manager) then return false end
    if InCombatLockdown() then
        Print(L["WINDOW_LAYOUT_COMBAT"])
        return false
    end
    local closing = AllShown(layout.windows)
    for _, w in ipairs(layout.windows) do
        local entry = Registry:GetEntryByName(w.name)
        local frame = entry and Registry:GetFrame(entry)
        if entry and closing then
            if frame and frame:IsShown() then Close(entry, frame) end
        elseif entry then
            if not (frame and frame:IsShown()) then
                Open(entry, frame)
                frame = Registry:GetFrame(entry)
            end
            if frame and frame:IsShown() and w.spec then Manager:ApplySpecTo(entry, w.spec, not layout.standing) end
        end
    end
    layout.used = time()
    return true
end

-- The one standing layout: its zones kept, so its windows open there on
-- their own. Off again, the zones stay until a window is restored.
function Layouts:SetStanding(id, on)
    local layout = self:Get(id)
    if not layout then return end
    for _, other in ipairs(self:All()) do
        if other ~= layout and on then other.standing = nil end
    end
    layout.standing = on and true or nil
    local Registry, Manager = ns.WindowRegistry, ns.WindowManager
    if on and Registry and Manager and Manager.SetStandingSpec then
        for _, w in ipairs(layout.windows) do
            local entry = Registry:GetEntryByName(w.name)
            if entry and w.spec then Manager:SetStandingSpec(entry, w.spec) end
        end
    end
    Changed()
end

function Layouts:Delete(id)
    local store = Store()
    if not store then return end
    for i = #store, 1, -1 do
        if store[i].id == id then tremove(store, i) end
    end
    Changed()
end

Layouts._Snapshot = Snapshot   -- tests
