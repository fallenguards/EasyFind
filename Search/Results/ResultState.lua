local _, ns = ...

local Search = ns.Search
local Results = ns.Results

local collapsedNodes = {}
local flatEntries = {}
local flatCombined = {}

local SCRATCH = {
    visible = {},
    isLastChild = {},
    catSepYPositions = {},
    aliasSeen = {},
    mapBoostSeen = {},
    mapNaturalScore = {},
    catalogBoostSeen = {},
    calculatorResults = {},
    filteredResults = {},
    quickFilterResults = {},
    -- The words typed, for a character's fact rows, and the rows kept.
    factAsked = {},
    factResults = {},
    skipCategories = {},
    currencyInfoCache = {},
    renderState = {},
    launchers = {},
    -- The rendered list's geometry and the frames its rows hold.
    rowTops = {},
    rowHeights = {},
    frameOfRow = {},
    -- The candidates past the head of a search, listed a frame later.
    tail = {},
}

Results._cachedHierarchical = nil
Results._flatEntries = flatEntries
Results._flatCombined = flatCombined
Results._collapsedNodes = collapsedNodes
Results._SCRATCH = SCRATCH
Results._resultButtons = Search:GetResultButtons()
