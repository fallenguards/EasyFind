local H = require("Harness")

local env = H.newEnv()
local ns = H.newNs(env)
H.loadModule("Shared/CategoryMap.lua", env, ns)
local CategoryMap = ns.CategoryMap

local tests = {}

function tests.everyCategoryBelongsToExactlyOneFilter()
    local ownerByCategory = {}
    for _, e in ipairs(CategoryMap.entries) do
        for _, cat in ipairs(e.categories) do
            H.assertEq(ownerByCategory[cat], nil,
                "category '" .. cat .. "' claimed by two filters")
            ownerByCategory[cat] = e.key
        end
    end
end

function tests.providerCategoriesResolve()
    H.assertEq(CategoryMap.ProviderCategory.mounts, "Mount")
    H.assertEq(CategoryMap.ProviderCategory.transmogSets, "Appearance Set",
        "the appearanceSets filter maps to the transmogSets provider")
    H.assertEq(CategoryMap.ProviderCategory.achievements, "Achievement Category",
        "the provider category must come first in the entry's list")
    H.assertEq(CategoryMap.ProviderCategory.gameOptions, nil,
        "options entries have no dynamic provider")
end

function tests.bucketsExcludeDedicatedFilterEntries()
    H.assertEq(CategoryMap.BucketByCategory["Ability"], "abilities")
    H.assertEq(CategoryMap.BucketByCategory["Game Settings"], "gameOptions")
    H.assertEq(CategoryMap.BucketByCategory["Mount"], nil,
        "collection entries are handled by their dedicated filters")
    H.assertEq(CategoryMap.BucketByCategory["Appearance Set"], nil)
    H.assertEq(CategoryMap.BucketByCategory["Loot"], nil)
end

function tests.parentCascadeSkipsDescendants()
    local out = {}
    local any = CategoryMap.BuildSkipCategories({ collections = false }, out)
    H.assertEq(any, true)
    H.assertEq(out["Mount"], true)
    H.assertEq(out["Appearance Set"], true,
        "appearances chains to collections, so its children skip too")
    H.assertEq(out["Bag"], nil, "unrelated filters stay visible")
end

function tests.midChainParentSkipsOnlyItsSubtree()
    local out = {}
    CategoryMap.BuildSkipCategories({ appearances = false }, out)
    H.assertEq(out["Appearance"], true)
    H.assertEq(out["Appearance Set"], true)
    H.assertEq(out["Mount"], nil)
end

function tests.explicitIntentSuppressesSkip()
    local out = {}
    local any = CategoryMap.BuildSkipCategories({ statistics = false }, out, true, false)
    H.assertEq(out["Statistic"], nil,
        "an explicit statistics query overrides the unchecked filter")
    H.assertEq(any, false)
    CategoryMap.BuildSkipCategories({ statistics = false }, out, false, false)
    H.assertEq(out["Statistic"], true)
    H.assertEq(out["Statistics"], true)
end

-- An extension's row over its providers (EasyFind.API): off, it skips them
-- all; one provider off skips only its own.
function tests.anExtensionRowSkipsItsProviders()
    CategoryMap.AddGroup("ext.fish", "extensions")
    CategoryMap.Add({ key = "fishPools", parent = "ext.fish", categories = { "fishPools" } })
    CategoryMap.Add({ key = "fishZones", parent = "ext.fish", categories = { "fishZones" } })
    H.assertTrue(CategoryMap.IsProviderFilterOff({ ["ext.fish"] = false }, "fishZones"))
    H.assertTrue(CategoryMap.IsProviderFilterOff({ extensions = false }, "fishPools"), "under Extensions")
    local out = {}
    CategoryMap.BuildSkipCategories({ fishZones = false }, out)
    H.assertTrue(out.fishZones)
    H.assertNil(out.fishPools, "its sibling stays")
end

function tests.noFiltersOffMeansNothingSkipped()
    local out = { Stale = true }
    local any = CategoryMap.BuildSkipCategories({}, out)
    H.assertEq(any, false)
    H.assertEq(next(out), nil, "the out table is wiped even when nothing skips")
end

-- A provider's saved index takes every row of its category (Database/
-- Dynamic.lua TakePopulatedRows): a shipped row carrying one would sit in
-- two segments.
function tests.shippedRowsCarryNoProviderCategory()
    local f = assert(io.open(H.ADDON_ROOT .. "/Database/Main.lua", "rb"))
    local src = f:read("*a")
    f:close()
    local s = assert(src:find("function Database:BuildUIDatabase()", 1, true), "the shipped tree")
    local tree = src:sub(s):gsub("%-%-[^\r\n]*", "")
    local providerOf = {}
    for key, cat in pairs(CategoryMap.ProviderCategory) do providerOf[cat] = key end
    local seen = 0
    for value in tree:gmatch("%f[%w]category%s*=([^=][^,}\r\n]*)") do
        local cat = value:match('^%s*"([^"]+)"%s*$')
        H.assertNotNil(cat, "a shipped category is a plain string: " .. value)
        H.assertNil(providerOf[cat], ("shipped category '%s' is provider %s's"):format(cat, tostring(providerOf[cat])))
        seen = seen + 1
    end
    H.assertTrue(seen > 80, "read the shipped tree's categories: " .. seen)
end

local pass, fail, failures = H.runSuite("CategoryMap", tests)
return { pass = pass, fail = fail, failures = failures }
