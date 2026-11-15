-- Blackthornes Tradeskills -- UI/PriceGraph.lua
-- The price graph: the cheapest price hour by hour, over the last 24 hours
-- or 7 days, and when in the day it tends to be cheapest and dearest.
--
-- Asked on Discord 2026-10-06. Shown on the Profit tab's craft pane (for the
-- craft and each of its materials) and on the Prices tab. The prices come
-- from Data/PriceHistory.lua; this only draws them.
--
-- Behind the line (asked 2026-10-09): bars for how many were listed each
-- hour, and a dashed line at the average of the prices shown. The auction
-- house never says what sold, so the bars are what was on offer; a bar
-- that drops from one hour to the next is stock that sold or was taken down.
--
-- The line is the client's own line object where it has one, with a soft
-- wider line under it for the glow. A client without one gets a dot at
-- each price instead, which still shows the shape.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local PriceGraph = {}
ns.PriceGraph = PriceGraph

PriceGraph.all = {}

PriceGraph.WINDOWS = {
    day = { seconds = 24 * 3600, text = L["24 Hours"] },
    week = { seconds = 7 * 24 * 3600, text = L["7 Day"] },
    fortnight = { seconds = 14 * 24 * 3600, text = L["14 Day"] },
}

-- What each toggle's tooltip says, and what the empty graph says.
local TOGGLE_TIPS = {
    day = L["The last 24 hours"],
    week = L["The last seven days"],
    fortnight = L["The last fourteen days"],
}

local HEADER_HEIGHT = 16
local PICKER_HEIGHT = 18
local PICKER_ICON = 16
local TICK_HEIGHT = 11
local BEST_HEIGHT = 13
local TOGGLE_HEIGHT = 16
local TICKS = 4

--------------------------------------------------------------------------------
-- Which view
--------------------------------------------------------------------------------

--- "day", "week" or "fortnight", kept in settings so every graph opens on the last one
--- picked.
function PriceGraph.GetWindow()
    local key = ns.Config and ns.Config.Get and ns.Config:Get("priceGraphWindow")
    return PriceGraph.WINDOWS[key] and key or "day"
end

function PriceGraph.SetWindow(key)
    if not PriceGraph.WINDOWS[key] then return end
    if ns.Config and ns.Config.Set then ns.Config:Set("priceGraphWindow", key) end
end

--------------------------------------------------------------------------------
-- What to draw
--------------------------------------------------------------------------------

--- The points to draw for an item over a window, and what they are.
-- @return points { t, p }, kind ("hourly", "market" or nil when there is
--   nothing to draw), tracked
function PriceGraph.Series(itemID, windowKey, now)
    now = now or time()
    local window = PriceGraph.WINDOWS[windowKey] or PriceGraph.WINDOWS.day
    local history = ns.PriceHistory
    local tracked = history and history:IsTracked(itemID) or false

    local points = history and history:GetPoints(itemID, window.seconds, now) or {}
    if #points >= 2 then return points, "hourly", tracked end

    -- An item with no hourly prices still has the price table's last few
    -- scans of its market value. Better a short line than an empty well.
    if not tracked then
        local record = ns.Prices and ns.Prices:Get(itemID)
        local market = {}
        for _, reading in ipairs(record and type(record.history) == "table" and record.history or {}) do
            if type(reading) == "table" and type(reading.t) == "number" and type(reading.m) == "number"
                and reading.t > now - window.seconds then
                market[#market + 1] = { t = reading.t, p = reading.m }
            end
        end
        if #market >= 2 then return market, "market", tracked end

        -- Then the daily market values kept for the trend, one a day,
        -- each drawn at the end of its day (or now, for today).
        local trend = record and type(record.trend) == "table" and record.trend or {}
        local daily = {}
        for index = 1, #trend - 1, 2 do
            local day, value = trend[index], trend[index + 1]
            if type(day) == "number" and type(value) == "number" and value > 0 then
                local t = math.min(now, (day + 1) * 86400 - 1)
                if t > now - window.seconds then daily[#daily + 1] = { t = t, p = value } end
            end
        end
        if #daily >= 2 then return daily, "market", tracked end
    end

    return points, nil, tracked
end

--- Where each point sits in a plot of this size: x by time across the
--- window, y by price between the lowest and highest shown. A flat line
--- sits in the middle.
-- @return { x, y, t, p } for each point, lowest, highest
function PriceGraph.Layout(points, width, height, seconds, now)
    local low, high = math.huge, 0
    for _, point in ipairs(points) do
        if point.p < low then low = point.p end
        if point.p > high then high = point.p end
    end

    local span = high - low
    local from = now - seconds
    local placed = {}

    for _, point in ipairs(points) do
        local x = Util.Clamp((point.t - from) / seconds, 0, 1) * width
        local y = span > 0 and ((point.p - low) / span) * height or height / 2
        placed[#placed + 1] = { x = x, y = y, t = point.t, p = point.p }
    end

    return placed, low, high
end

--- The time under each of the graph's ticks: the hour for 24 hours, the day
--- for 7 days, and "now" at the right.
function PriceGraph.TickText(windowKey, t, isLast)
    if isLast then return L["now"] end
    if windowKey == "week" then return date("%a", t) end
    if windowKey == "fortnight" then return date("%a ", t) .. tonumber(date("%d", t)) end
    return ns.PriceHistory.HourText(date("*t", t).hour)
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

local function Segment(graph, index)
    local pool = graph.segments
    local segment = pool[index]
    if segment then return segment end

    local plot = graph.plot
    local glow = plot:CreateLine(nil, "ARTWORK", nil, 1)
    local line = plot:CreateLine(nil, "ARTWORK", nil, 2)
    pcall(glow.SetBlendMode, glow, "ADD")
    glow:SetThickness(6)
    line:SetThickness(2)
    glow:SetColorTexture(Theme.Unpack("accent", 0.22))
    line:SetColorTexture(Theme.Unpack("accentHi", 0.95))

    segment = { glow = glow, line = line }
    pool[index] = segment
    return segment
end

local function Dot(graph, index)
    local pool = graph.dots
    local dot = pool[index]
    if dot then return dot end

    dot = graph.plot:CreateTexture(nil, "OVERLAY")
    pool[index] = dot
    return dot
end

local function PlaceDot(dot, plot, x, y, size, key, alpha)
    dot:ClearAllPoints()
    dot:SetSize(size, size)
    dot:SetPoint("CENTER", plot, "BOTTOMLEFT", x, y)
    dot:SetColorTexture(Theme.Unpack(key, alpha))
    dot:Show()
end

local function Pooled(graph, pool, index, layer, sublevel)
    local texture = graph[pool][index]
    if texture then return texture end

    texture = graph.plot:CreateTexture(nil, layer, nil, sublevel)
    graph[pool][index] = texture
    return texture
end

--- Volume bars (asked 2026-10-09): how many were listed each hour, rising
--- from the foot of the plot behind the price line, at most this much of
--- its height.
PriceGraph.BAR_SHARE = 0.4

--- Where each hour's bar sits: x by time as the price points are, height by
--- the most listed in the window. Hours with none listed get no bar.
-- @return { x, width, height, t, q } for each bar, and the most listed
function PriceGraph.LayoutBars(listed, width, height, seconds, now)
    local most = 0
    for _, entry in ipairs(listed) do
        if entry.q > most then most = entry.q end
    end

    local bars = {}
    if most <= 0 then return bars, 0 end

    local from = now - seconds
    local barWidth = math.max(1, width * 3600 / seconds - 1)

    for _, entry in ipairs(listed) do
        if entry.q > 0 then
            bars[#bars + 1] = {
                x = Util.Clamp((entry.t - from) / seconds, 0, 1) * width,
                width = barWidth,
                height = math.max(1, entry.q / most * height * PriceGraph.BAR_SHARE),
                t = entry.t,
                q = entry.q,
            }
        end
    end
    return bars, most
end

local function DrawBars(graph, bars)
    for index, bar in ipairs(bars) do
        local texture = Pooled(graph, "bars", index, "ARTWORK", 0)
        texture:ClearAllPoints()
        texture:SetPoint("BOTTOM", graph.plot, "BOTTOMLEFT", bar.x, 0)
        texture:SetSize(bar.width, bar.height)
        texture:SetColorTexture(Theme.Unpack("metal", 0.55))
        texture:Show()
    end
end

--- The average of the prices shown, as a dashed line across the plot with
--- its amount at the right.
local function DrawAverage(graph, average, low, high, width, height)
    if not average or high <= low then return end

    local y = (average - low) / (high - low) * height
    local dash, gap = 4, 3
    local count = math.max(1, math.floor(width / (dash + gap)))
    for index = 1, count do
        local texture = Pooled(graph, "dashes", index, "ARTWORK", 1)
        texture:ClearAllPoints()
        texture:SetPoint("LEFT", graph.plot, "BOTTOMLEFT", (index - 1) * (dash + gap), y)
        texture:SetSize(dash, 1)
        texture:SetColorTexture(Theme.Unpack("muted", 0.8))
        texture:Show()
    end

    graph.averageLabel:ClearAllPoints()
    -- Above the line, or under it when the line runs along the top, and
    -- never past the plot's edge, where the times sit.
    if y > height - 10 and y >= 12 then
        graph.averageLabel:SetPoint("TOPRIGHT", graph.plot, "BOTTOMRIGHT", 0, y - 2)
    else
        graph.averageLabel:SetPoint("BOTTOMRIGHT", graph.plot, "BOTTOMRIGHT", 0, y + 2)
    end
    graph.averageLabel:SetText(L.Format("avg %s", Util.FormatMoney(average, { short = true })))
    graph.averageLabel:Show()
end

local function HideDrawing(graph)
    for _, segment in ipairs(graph.segments) do
        segment.glow:Hide()
        segment.line:Hide()
    end
    for _, dot in ipairs(graph.dots) do dot:Hide() end
    for _, bar in ipairs(graph.bars) do bar:Hide() end
    for _, dash in ipairs(graph.dashes) do dash:Hide() end
    graph.averageLabel:Hide()
    graph.hover:Hide()
    graph.placed = nil
    graph.listedAt = nil
    graph.average = nil
    graph.points = nil
end

local function Draw(graph, placed, low, high)
    local plot = graph.plot
    local lines = type(plot.CreateLine) == "function" and graph.canLine ~= false

    if lines then
        for index = 2, #placed do
            local a, b = placed[index - 1], placed[index]
            local ok = pcall(function()
                local segment = Segment(graph, index - 1)
                for _, part in ipairs({ segment.glow, segment.line }) do
                    part:SetStartPoint("BOTTOMLEFT", plot, a.x, a.y)
                    part:SetEndPoint("BOTTOMLEFT", plot, b.x, b.y)
                    part:Show()
                end
            end)
            if not ok then
                -- This client's lines do not work: dots from now on.
                graph.canLine = false
                for _, segment in ipairs(graph.segments) do
                    segment.glow:Hide()
                    segment.line:Hide()
                end
                lines = false
                break
            end
        end
    end

    local used = 0
    if not lines then
        for _, point in ipairs(placed) do
            used = used + 1
            PlaceDot(Dot(graph, used), plot, point.x, point.y, 3, "accentHi", 0.9)
        end
    end

    -- The cheapest price in green and the dearest in gold, so the two the
    -- graph is for can be found at a glance.
    local lowPoint, highPoint
    for _, point in ipairs(placed) do
        if point.p == low and not lowPoint then lowPoint = point end
        if point.p == high then highPoint = point end
    end
    if lowPoint and high > low then
        used = used + 1
        PlaceDot(Dot(graph, used), plot, lowPoint.x, lowPoint.y, 5, "profit", 1)
    end
    if highPoint and high > low then
        used = used + 1
        PlaceDot(Dot(graph, used), plot, highPoint.x, highPoint.y, 5, "accentHi", 1)
    end
end

--------------------------------------------------------------------------------
-- Hover
--------------------------------------------------------------------------------

local function Nearest(graph)
    local placed = graph.placed
    if not placed or #placed == 0 then return nil end

    local ok, x = pcall(function()
        local cursor = GetCursorPosition()
        local scale = graph.plot:GetEffectiveScale()
        return cursor / scale - graph.plot:GetLeft()
    end)
    if not ok or type(x) ~= "number" then return nil end

    local best, distance
    for _, point in ipairs(placed) do
        local d = math.abs(point.x - x)
        if not distance or d < distance then best, distance = point, d end
    end
    return best
end

local function ShowHover(graph)
    local point = Nearest(graph)
    if not point then
        graph.hover:Hide()
        GameTooltip:Hide()
        return
    end
    if graph.hoverPoint == point then return end
    graph.hoverPoint = point

    PlaceDot(graph.hover, graph.plot, point.x, point.y, 7, "gilt", 1)

    GameTooltip:SetOwner(graph.plot, "ANCHOR_TOP")
    GameTooltip:SetText(date("%a ", point.t) .. ns.PriceHistory.HourText(date("*t", point.t).hour), 1, 1, 1)
    GameTooltip:AddDoubleLine(graph.kind == "market" and L["Market value"] or L["Cheapest listed"],
        Util.FormatMoney(point.p), 0.8, 0.8, 0.8, 1, 1, 1)
    local listed = graph.listedAt and graph.listedAt[math.floor(point.t / 3600)]
    if listed then
        GameTooltip:AddDoubleLine(L["Listed"], Util.Comma and Util.Comma(listed) or tostring(listed),
            0.8, 0.8, 0.8, 1, 1, 1)
    end
    if graph.average then
        GameTooltip:AddDoubleLine(L["Average shown"], Util.FormatMoney(graph.average),
            0.8, 0.8, 0.8, 0.75, 0.75, 0.75)
    end
    if graph.kind == "market" then
        GameTooltip:AddLine(L["Star this item to save its cheapest price every hour."], 0.6, 0.6, 0.6, true)
    end
    GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- The widget
--------------------------------------------------------------------------------

local function UpdateToggles(graph)
    local current = PriceGraph.GetWindow()
    for key, button in pairs(graph.toggles) do
        local on = key == current
        button.selectedFill:SetShown(on)
        button.selectedLine:SetShown(on)
    end
end

local function CreateToggle(graph, key)
    local window = PriceGraph.WINDOWS[key]
    local button = Widgets.CreateButton(graph, window.text, function()
        PriceGraph.SetWindow(key)
        PriceGraph.RefreshAll()
    end, { width = 50, height = TOGGLE_HEIGHT, fontSize = "tiny",
           tooltip = TOGGLE_TIPS[key] })

    -- Fit the label: a client font wider than the test's must not cut it.
    local width = Theme.TextWidth(button.label)
    if width then button:SetWidth(math.max(44, math.ceil(width) + 12)) end

    -- The view showing wears a gold wash and a gold line under it.
    local fill = button:CreateTexture(nil, "ARTWORK", nil, 1)
    fill:SetPoint("TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMRIGHT", -1, 1)
    fill:SetColorTexture(Theme.Unpack("accent", 0.22))
    button.selectedFill = fill

    local line = button:CreateTexture(nil, "OVERLAY")
    line:SetPoint("BOTTOMLEFT", 2, -3)
    line:SetPoint("BOTTOMRIGHT", -2, -3)
    line:SetHeight(2)
    line:SetColorTexture(Theme.Unpack("accentHi"))
    button.selectedLine = line

    graph.toggles[key] = button
    return button
end

local function CreatePickerIcon(graph, index)
    local button = CreateFrame("Button", nil, graph)
    button:SetSize(PICKER_ICON + 2, PICKER_ICON + 2)

    local ring = button:CreateTexture(nil, "BACKGROUND")
    ring:SetAllPoints()
    button.ring = ring

    local icon = Theme.CreateItemIcon(button, PICKER_ICON)
    icon:SetPoint("CENTER")
    button.icon = icon

    button:SetScript("OnClick", function(self)
        if Widgets.ItemShiftClick and Widgets.ItemShiftClick(self.itemID) then return end
        graph.selected = self.itemID
        graph:Refresh()
    end)
    button:SetScript("OnEnter", function(self)
        if self.itemID then
            Widgets.ShowItemTooltip(self, "ANCHOR_TOP", self.itemID, "item")
            GameTooltip:AddLine(L["Click to see its price history"], 0.6, 0.6, 0.6)
            GameTooltip:Show()
        end
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    graph.pickers[index] = button
    return button
end

--- Make a price graph.
-- @param opts
--   heading  the section heading on the top line, toggles beside it at the
--            right (a graph with no heading puts the toggles on the picker's
--            line instead)
--   picker   true: a row of item icons to choose whose prices are shown
--   ticks    true: times under the graph
function PriceGraph.Create(parent, opts)
    opts = opts or {}
    local graph = CreateFrame("Frame", nil, parent)
    graph.opts = opts
    graph.segments, graph.dots, graph.toggles, graph.pickers = {}, {}, {}, {}

    local top = 0
    if opts.heading then
        graph.heading = Theme.CreateHeading(graph, opts.heading)
        graph.heading:SetPoint("TOPLEFT", 0, -3)
        top = HEADER_HEIGHT + 4
    end

    local fortnight = CreateToggle(graph, "fortnight")
    local week = CreateToggle(graph, "week")
    local day = CreateToggle(graph, "day")
    fortnight:SetPoint("TOPRIGHT", 0, opts.heading and 0 or -1)
    week:SetPoint("RIGHT", fortnight, "LEFT", -4, 0)
    day:SetPoint("RIGHT", week, "LEFT", -4, 0)

    -- The heading's rule stops short of the toggles.
    if graph.heading and graph.heading.rule then
        graph.heading.rule:ClearAllPoints()
        graph.heading.rule:SetPoint("LEFT", graph.heading, "RIGHT", 6, 0)
        graph.heading.rule:SetPoint("RIGHT", day, "LEFT", -8, 0)
    end

    if opts.picker then
        graph.pickerTop = -top
        if not opts.heading then
            top = PICKER_HEIGHT + 4
        else
            top = top + PICKER_HEIGHT + 2
        end
    end

    local bottom = BEST_HEIGHT + 3 + (opts.ticks and TICK_HEIGHT or 0)

    local well = Theme.CreatePanel(graph, "row")
    well:SetPoint("TOPLEFT", 0, -top)
    well:SetPoint("BOTTOMRIGHT", 0, bottom)
    Theme.Recess(well)
    graph.well = well

    local plot = CreateFrame("Frame", nil, well)
    plot:SetPoint("TOPLEFT", 6, -6)
    plot:SetPoint("BOTTOMRIGHT", -6, 5)
    plot:EnableMouse(true)
    graph.plot = plot

    -- Faint lines at the top, middle and foot of the plot to read against.
    for _, fraction in ipairs({ 0, 0.5, 1 }) do
        local guide = plot:CreateTexture(nil, "BACKGROUND", nil, 1)
        guide:SetHeight(1)
        guide:SetPoint("LEFT", plot, "BOTTOMLEFT", 0, 0)
        guide:SetPoint("RIGHT", plot, "BOTTOMRIGHT", 0, 0)
        guide:SetColorTexture(Theme.Unpack("border", 0.35))
        guide.fraction = fraction
        graph.guides = graph.guides or {}
        graph.guides[#graph.guides + 1] = guide
    end

    -- Redrawn at its real size once laid out, and again if it changes. The
    -- drawing is measured on the plot, so its size is the one watched, and a
    -- change while hidden (the Profit tab is laid out before it first shows)
    -- is caught up on show: drawn before that, the line, guides and times
    -- sat bunched at the left until something else redrew it.
    local function Resized()
        if graph:IsVisible() then graph:Refresh() else graph.stale = true end
    end
    graph:SetScript("OnSizeChanged", Resized)
    plot:SetScript("OnSizeChanged", Resized)

    --- Drawn at a size other than the plot's now (or at none)?
    function graph:OutOfSize()
        local width, height = self.plot:GetWidth(), self.plot:GetHeight()
        return self.stale or width ~= self.drawnWidth or height ~= self.drawnHeight
    end

    graph:SetScript("OnShow", function(self)
        if self:OutOfSize() then self:Refresh() end
        -- The size can settle only after the frame it shows on is drawn;
        -- one look on the next frame, and only a redraw if it moved.
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                if self:IsVisible() and self:OutOfSize() then self:Refresh() end
            end)
        end
    end)

    graph.hover = plot:CreateTexture(nil, "OVERLAY", nil, 2)
    graph.hover:Hide()

    graph.bars, graph.dashes = {}, {}
    graph.averageLabel = Theme.CreateLabel(plot, "tiny", "muted", "RIGHT")
    graph.averageLabel:Hide()

    plot:SetScript("OnEnter", function()
        graph.hoverPoint = nil
        plot:SetScript("OnUpdate", function() ShowHover(graph) end)
    end)
    plot:SetScript("OnLeave", function()
        plot:SetScript("OnUpdate", nil)
        graph.hoverPoint = nil
        graph.hover:Hide()
        GameTooltip:Hide()
    end)

    -- Highest and lowest price shown, at the plot's left corners.
    graph.highLabel = Theme.CreateLabel(well, "tiny", "accentHi")
    graph.highLabel:SetPoint("TOPLEFT", 4, -3)
    graph.lowLabel = Theme.CreateLabel(well, "tiny", "profit")
    graph.lowLabel:SetPoint("BOTTOMLEFT", 4, 3)

    graph.empty = Theme.CreateLabel(well, "tiny", "dim", "CENTER")
    graph.empty:SetPoint("LEFT", 10, 0)
    graph.empty:SetPoint("RIGHT", -10, 0)
    graph.empty:SetWordWrap(true)

    graph.ticks = {}
    if opts.ticks then
        for index = 1, TICKS do
            local justify = index == 1 and "LEFT" or (index == TICKS and "RIGHT" or "CENTER")
            local tick = Theme.CreateLabel(graph, "tiny", "dim", justify)
            tick:SetWidth(50)
            graph.ticks[index] = tick
        end
    end

    -- The best times, under it all, with the reasoning on hover.
    local best = CreateFrame("Frame", nil, graph)
    best:SetPoint("BOTTOMLEFT", 0, 0)
    best:SetPoint("BOTTOMRIGHT", 0, 0)
    best:SetHeight(BEST_HEIGHT)
    best:EnableMouse(true)
    best.label = Theme.CreateLabel(best, "tiny", "gilt")
    best.label:SetPoint("LEFT", 0, 0)
    best.label:SetPoint("RIGHT", 0, 0)
    best:SetScript("OnEnter", function(self)
        if not self.why then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["Best time to buy and sell"], 1, 1, 1)
        GameTooltip:AddLine(self.why, 0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    best:SetScript("OnLeave", function() GameTooltip:Hide() end)
    graph.best = best

    --- Show one item's prices.
    function graph:SetItem(itemID)
        self.items = nil
        self.selected = itemID
        self:Refresh()
    end

    --- Show a choice of items (the picker), starting on `selected` or the
    --- first. Keeps the one picked when it is still in the list.
    function graph:SetItems(items, selected)
        self.items = items
        local keep = false
        for _, itemID in ipairs(items or {}) do
            if itemID == self.selected then keep = true end
        end
        if not keep then self.selected = selected or (items and items[1]) end
        self:Refresh()
    end

    function graph:Refresh()
        UpdateToggles(self)
        self:LayoutPicker()

        local itemID = self.selected
        local windowKey = PriceGraph.GetWindow()
        local window = PriceGraph.WINDOWS[windowKey]
        local now = time()

        HideDrawing(self)

        local width = self.plot:GetWidth()
        local height = self.plot:GetHeight()
        if type(width) ~= "number" then width = 0 end
        if type(height) ~= "number" then height = 0 end
        -- Not laid out yet: drawn again once it has a size.
        self.drawnWidth, self.drawnHeight = width, height
        self.stale = width <= 0 or height <= 0

        -- Times under the graph, the same whatever is drawn.
        for index, tick in ipairs(self.ticks) do
            local fraction = (index - 1) / (TICKS - 1)
            tick:ClearAllPoints()
            local x = 6 + fraction * width
            local anchor = index == 1 and "TOPLEFT" or (index == TICKS and "TOPRIGHT" or "TOP")
            if index == TICKS then
                tick:SetPoint("TOPRIGHT", self.well, "BOTTOMRIGHT", -6, -1)
            elseif index == 1 then
                tick:SetPoint("TOPLEFT", self.well, "BOTTOMLEFT", 6, -1)
            else
                tick:SetPoint(anchor, self.well, "BOTTOMLEFT", x, -1)
            end
            tick:SetText(PriceGraph.TickText(windowKey,
                now - window.seconds + fraction * window.seconds, index == TICKS))
        end

        for _, guide in ipairs(self.guides) do
            guide:ClearAllPoints()
            guide:SetPoint("LEFT", self.plot, "BOTTOMLEFT", 0, guide.fraction * height)
            guide:SetPoint("RIGHT", self.plot, "BOTTOMRIGHT", 0, guide.fraction * height)
        end

        if not itemID then
            self.empty:SetText("")
            self.highLabel:SetText("")
            self.lowLabel:SetText("")
            self.best.label:SetText("")
            self.best.why = nil
            local after = self.opts and rawget(self.opts, "onRefresh")
            if type(after) == "function" then pcall(after, self) end
            return
        end

        local points, kind, tracked = PriceGraph.Series(itemID, windowKey, now)
        self.kind = kind
        self.points = kind and points or nil

        if not kind then
            self.highLabel:SetText("")
            self.lowLabel:SetText("")
            if tracked then
                self.empty:SetText(#points == 1
                    and L["One price so far. Scan again later to draw the line."]
                    or (windowKey == "fortnight"
                        and L["No scans in the last 14 days. Scan the auction house to start the line."]
                        or windowKey == "week"
                        and L["No scans in the last 7 days. Scan the auction house to start the line."]
                        or L["No scans in the last 24 hours. Scan the auction house to start the line."]))
            else
                self.empty:SetText(L["Prices are saved every hour for what you craft and its materials. Star this item to save its prices too."])
            end
            self.empty:Show()
        else
            self.empty:Hide()
            local placed, low, high = PriceGraph.Layout(points, width, height, window.seconds, now)
            self.placed = placed

            -- How many were listed, behind the line; hourly prices only,
            -- since the scans' fallback has no hours to put them in.
            if kind == "hourly" then
                local listed = ns.PriceHistory.GetListed
                    and ns.PriceHistory:GetListed(itemID, window.seconds, now) or {}
                self.listedAt = {}
                for _, entry in ipairs(listed) do
                    self.listedAt[math.floor(entry.t / 3600)] = entry.q
                end
                DrawBars(self, (PriceGraph.LayoutBars(listed, width, height, window.seconds, now)))
            end

            self.average = ns.PriceHistory.Average(points)
            DrawAverage(self, self.average, low, high, width, height)
            Draw(self, placed, low, high)
            self.highLabel:SetText(Util.FormatMoney(high, { short = true }))
            self.lowLabel:SetText(high > low and Util.FormatMoney(low, { short = true }) or "")
        end

        -- The best times, from the hourly prices only.
        local texts, why, best
        if tracked or kind == "hourly" then
            texts, why, best = ns.PriceHistory:DescribeBestTimes(itemID, now)
        else
            texts = { L["Best times: star it to start learning"], L["Best times: star it"] }
        end
        self.best.label:SetTextColor(Theme.Unpack(best and best.ready and "gilt" or "dim"))
        Theme.FitText(self.best.label, texts, self.best:GetWidth())
        self.best.why = why

        -- The pane around the graph can show lines from what it drew.
        local after = self.opts and rawget(self.opts, "onRefresh")
        if type(after) == "function" then pcall(after, self) end
    end

    --- Place the item icons, the one showing ringed in gold.
    function graph:LayoutPicker()
        local items = self.opts.picker and self.items or nil
        local shown = 0

        -- As many icons as fit beside the toggles (or under the heading);
        -- the materials list above still names the rest.
        local room = self:GetWidth()
        if type(room) ~= "number" or room <= 0 then room = 276 end
        if not self.opts.heading then
            room = room - self.toggles.day:GetWidth() - self.toggles.week:GetWidth()
                - self.toggles.fortnight:GetWidth() - 16
        end
        local fits = math.max(1, math.floor((room + 6) / (PICKER_ICON + 6)))

        if items then
            for index, itemID in ipairs(items) do
                if index > fits then break end
                local button = self.pickers[index] or CreatePickerIcon(self, index)
                button.itemID = itemID
                Theme.SetItemIcon(button.icon, itemID)
                button.ring:SetColorTexture(Theme.Unpack(itemID == self.selected and "accentHi" or "border",
                    itemID == self.selected and 1 or 0.5))
                button:ClearAllPoints()
                button:SetPoint("TOPLEFT", self, "TOPLEFT", (index - 1) * (PICKER_ICON + 6), self.pickerTop or 0)
                button:Show()
                shown = index
            end
        end

        for index = shown + 1, #self.pickers do
            self.pickers[index]:Hide()
        end
    end

    PriceGraph.all[#PriceGraph.all + 1] = graph
    return graph
end

--- Redraw every graph showing: after a scan, or when the view changes.
--- A "Price graph" button on a heading's line, at the pane's right edge,
--- for panes that swap their materials for the graph. The heading's rule
--- stops short of it.
function PriceGraph.AddButton(pane, heading, onClick)
    local button = Widgets.CreateButton(pane, L["Price graph"], onClick,
        { width = 76, height = 16, fontSize = "tiny" })
    button:SetPoint("TOPRIGHT", pane, "TOPRIGHT", -12, 0)
    button:SetPoint("TOP", heading, "TOP", 0, 4)
    local rule = rawget(heading, "rule")
    if type(rule) == "table" then
        rule:ClearAllPoints()
        rule:SetPoint("LEFT", heading, "RIGHT", 6, 0)
        rule:SetPoint("RIGHT", button, "LEFT", -6, 0)
    end
    return button
end

--- Word the button for what a click shows, growing it to fit.
function PriceGraph.SetButton(button, showsGraph)
    button:SetText(showsGraph and L["Materials"] or L["Price graph"])
    button.tooltipText = not showsGraph
        and L["The cheapest price hour by hour, and the best times to buy and sell"] or nil
    local label = rawget(button, "label")
    if type(label) ~= "table" or not Theme.TextWidth then return end
    local text = Theme.TextWidth(label)
    local ok, width = pcall(button.GetWidth, button)
    if type(text) == "number" and ok and type(width) == "number" and text + 12 > width then
        button:SetWidth(math.ceil(text + 12))
    end
end

--- The average the graph shows, as money, then how the last price stands
--- against it in green or red ("1g 20s +12%"). nil while nothing is drawn.
function PriceGraph.AverageText(graph)
    local average = graph and rawget(graph, "average")
    if type(average) ~= "number" or average <= 0 then return nil end
    local text = Util.FormatMoney(average, { short = true })
    local points = rawget(graph, "points")
    local last = type(points) == "table" and points[#points] or nil
    if type(last) == "table" and type(last.p) == "number" and ns.Prices and ns.Prices.TrendText then
        local trend, color = ns.Prices.TrendText((last.p - average) / average)
        if trend then
            local r, g, b = Theme.Unpack(color or "muted")
            text = ("%s |cff%02x%02x%02x%s|r"):format(text,
                math.floor((r or 1) * 255 + 0.5), math.floor((g or 1) * 255 + 0.5),
                math.floor((b or 1) * 255 + 0.5), trend)
        end
    end
    return text
end

function PriceGraph.RefreshAll()
    for _, graph in ipairs(PriceGraph.all) do
        if graph:IsVisible() and graph.selected then graph:Refresh() end
    end
end
