local _, ns = ...

local Render = ns.ResultRender

-- The list's geometry and the row window: rows get a top from their
-- heights and the pin gaps, and only the rows near the view hold a frame.
local Window = {}
Render.Window = Window

-- tops[i] for rows 1..n from heights[i] and the pin gaps; returns the
-- content height and the bottom of the last pin (where its separator sits).
function Window.Tops(tops, heights, entries, n, lastPinIndex, hasResultsAfterPins, pinGap, pinSepHeight)
    local y, pinEnd = 0, 0
    for i = 1, n do
        if hasResultsAfterPins and i == lastPinIndex + 1 then
            pinEnd = y
            y = y + pinSepHeight
        end
        local e = entries[i]
        if e.isPinned and i > 1 and not entries[i - 1].isPinHeader then y = y + pinGap end
        tops[i] = y
        y = y + heights[i]
    end
    return y, pinEnd
end

-- The first and last rows touching [scrollTop, scrollTop + viewH], walked
-- from a hint (the last answer): a scroll moves a few rows at a time.
function Window.Range(tops, heights, n, scrollTop, viewH, hint)
    if n < 1 then return 0, -1 end
    local first = hint or 1
    if first < 1 then first = 1 elseif first > n then first = n end
    while first > 1 and tops[first] > scrollTop do first = first - 1 end
    while first < n and tops[first] + heights[first] <= scrollTop do first = first + 1 end
    local last, bottom = first, scrollTop + viewH
    while last < n and tops[last + 1] < bottom do last = last + 1 end
    return first, last
end

-- The rows that keep a frame: the view plus a screen below and half above.
function Window.Bounds(first, last, n, viewRows)
    local a = first - math.ceil(viewRows / 2)
    local b = last + viewRows
    if a < 1 then a = 1 end
    if b > n then b = n end
    return a, b
end
