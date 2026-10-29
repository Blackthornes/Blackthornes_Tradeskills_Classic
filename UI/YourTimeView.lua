-- Blackthornes Tradeskills -- UI/YourTimeView.lua
-- The Your time view on the Profit tab (the owner said yes, 2026-10-15,
-- from a mockup): for each craft you know, gold an hour if you farm its
-- materials and craft it, gold an hour if you farm them and sell them as
-- they are, and the profit if you buy them. Logic/CraftOrFarm.lua works it
-- out, with your farming pace from Blackthornes Farmer.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local YourTimeView = {}
ns.YourTimeView = YourTimeView

local ROW_HEIGHT = 22
local DETAIL_WIDTH = 300
local MATERIAL_LINES = 6

-- Right to left, measured from the list's right edge.
local COLUMNS = {
    { key = "best",      label = L["BEST"],             width = 86, justify = "CENTER" },
    { key = "buyCraft",  label = L["BUY + CRAFT"],      width = 80, money = true },
    { key = "farmSell",  label = L["FARM + SELL MATS"], width = 80, money = true },
    { key = "farmCraft", label = L["FARM + CRAFT"],     width = 80, money = true },
}

if ns.Columns then ns.Columns:Register("yourtime", L["Your time"], COLUMNS) end

local BEST_TEXT = { craft = L["Craft it"], raw = L["Sell the mats"] }
local BEST_COLOR = { craft = "profit", raw = "accentHi" }

local state = { search = "", paceOnly = false, selected = nil, waiting = false }
local widgets = {}

YourTimeView._state = state
YourTimeView._widgets = widgets

local function Money(copper)
    return Util.FormatMoney(copper, { short = true })
end

--- "45s", "3m 20s", "1h 05m".
local function Duration(seconds)
    if ns.CraftTime and ns.CraftTime.Format then return ns.CraftTime.Format(seconds) end
    return tostring(math.floor((seconds or 0) + 0.5))
end
YourTimeView.Duration = Duration

--- How you farm one material, in a few words.
function YourTimeView.PaceText(mat)
    local pace = mat.pace
    if not pace then
        if not ns.CraftOrFarm:HasFarmer() then return L["Needs Blackthornes Farmer"] end
        if (mat.samples or 0) > 0 then
            return L.Format("Not enough yet (%d of your 20)", mat.samples)
        end
        return L["You haven't farmed it yet"]
    end
    local each = Duration(pace.seconds)
    if pace.kind == "gather" and pace.zone then
        return L.Format("1 every %s in %s", each, pace.zone)
    end
    return L.Format("1 every %s from %s", each, pace.source or "?")
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function PlaceRow(row)
    local offset = ns.Columns:Place("yourtime", COLUMNS, row.cells, { gap = 8 })
    row.name:SetPoint("RIGHT", row, "RIGHT", offset - 8, 0)
    row.columnsVersion = ns.Columns.version
end

local function CreateRow(row)
    row.icon = Theme.CreateItemIcon(row, 16)
    row.icon:SetPoint("LEFT", 8, 0)

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("LEFT", 30, 0)
    row.name:SetWordWrap(false)

    row.cells = {}
    for _, column in ipairs(COLUMNS) do
        local cell = Theme.CreateLabel(row, "small", "muted", column.justify or "RIGHT")
        cell:SetWordWrap(false)
        row.cells[column.key] = cell
    end

    PlaceRow(row)
end

local function SetHour(cell, copper, lit)
    if copper == nil then
        cell:SetText("--")
        cell:SetTextColor(Theme.Unpack("dim"))
        return
    end
    Theme.SetMoneyText(cell, copper, { short = true })
    cell:SetTextColor(Theme.Unpack(lit and "profit" or (copper < 0 and "loss" or "text")))
end

local function UpdateRow(row, entry)
    if row.columnsVersion ~= ns.Columns.version then PlaceRow(row) end

    Theme.SetItemIcon(row.icon, entry.outputItemID)
    if entry.outputItemID then
        local ok, name = pcall(function() return C_Item.GetItemInfo(entry.outputItemID) end)
        if not ok or not name then state.waiting = true end
    end
    Theme.SetRowName(row.name, entry.name)

    -- The name in the item's rarity colour, as on My crafts; plain until
    -- the client has the item, then the redraw above colours it.
    local ok, r, g, b = pcall(Util.GetItemQualityColor, entry.outputItemID)
    if ok and r then
        row.name:SetTextColor(r, g, b)
    else
        row.name:SetTextColor(Theme.Unpack("text"))
    end

    local cells = row.cells
    SetHour(cells.farmCraft, entry.farmCraft, entry.best == "craft")
    SetHour(cells.farmSell, entry.farmSell, entry.best == "raw")

    Theme.SetMoneyText(cells.buyCraft, entry.buyProfit, { short = true })
    cells.buyCraft:SetTextColor(Theme.ProfitColor(entry.buyProfit))

    if entry.best then
        cells.best:SetText(BEST_TEXT[entry.best])
        cells.best:SetTextColor(Theme.Unpack(BEST_COLOR[entry.best]))
    else
        cells.best:SetText(L["Not enough yet"])
        cells.best:SetTextColor(Theme.Unpack("dim"))
    end
end

local function ShowRowTooltip(row, entry)
    Widgets.ShowItemOnly(row, entry.outputItemID, entry.name)
    GameTooltip:AddLine(" ")
    if entry.farmCraft then
        GameTooltip:AddDoubleLine(L["Farm it, then craft"], Money(entry.farmCraft) .. " " .. L["an hour"],
            1, 1, 1, 1, 1, 1)
    end
    if entry.farmSell then
        GameTooltip:AddDoubleLine(L["Farm it, sell the mats"], Money(entry.farmSell) .. " " .. L["an hour"],
            1, 1, 1, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine(L["Buy the mats, then craft"], Money(entry.buyProfit), 1, 1, 1, 1, 1, 1)
    if not entry.farmSeconds and entry.missing then
        GameTooltip:AddLine(L.Format("Farm some %s and this fills in.",
            Util.ColoredItemName(entry.missing.itemID)), Theme.Unpack("muted"))
    end
    GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- Detail pane
--------------------------------------------------------------------------------

local function Bar(parent)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(6)
    bar.back = bar:CreateTexture(nil, "BACKGROUND")
    bar.back:SetAllPoints()
    bar.back:SetColorTexture(Theme.Unpack("well"))
    bar.farm = bar:CreateTexture(nil, "ARTWORK")
    bar.farm:SetPoint("TOPLEFT")
    bar.farm:SetPoint("BOTTOMLEFT")
    bar.farm:SetColorTexture(Theme.Unpack("profit"))
    bar.craft = bar:CreateTexture(nil, "ARTWORK")
    bar.craft:SetPoint("TOPLEFT", bar.farm, "TOPRIGHT")
    bar.craft:SetPoint("BOTTOMLEFT", bar.farm, "BOTTOMRIGHT")
    bar.craft:SetColorTexture(Theme.Unpack("accent"))
    return bar
end

--- Lay a bar out: farming then crafting, against the longest of the three.
local function SetBar(bar, farm, craft, longest)
    local width = bar:GetWidth()
    if type(width) ~= "number" or width <= 0 then width = DETAIL_WIDTH - 24 end
    longest = (longest and longest > 0) and longest or 1
    local farmWidth = math.max(0.01, width * (farm or 0) / longest)
    local craftWidth = math.max(0.01, width * (craft or 0) / longest)
    bar.farm:SetWidth(farmWidth)
    bar.farm:SetShown((farm or 0) > 0)
    bar.craft:SetWidth(craftWidth)
    bar.craft:SetShown((craft or 0) > 0)
end

local function Way(detail, anchor)
    local way = CreateFrame("Frame", nil, detail)
    way:SetHeight(42)
    way:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)
    way:SetPoint("RIGHT", detail, "RIGHT", -12, 0)

    way.back = way:CreateTexture(nil, "BACKGROUND")
    way.back:SetAllPoints()
    way.back:SetColorTexture(Theme.Unpack("glass"))
    way.edge = way:CreateTexture(nil, "BORDER")
    way.edge:SetPoint("TOPLEFT")
    way.edge:SetPoint("BOTTOMLEFT")
    way.edge:SetWidth(2)
    way.edge:SetColorTexture(Theme.Unpack("accentHi"))

    way.value = Theme.CreateLabel(way, "small", "text", "RIGHT")
    way.value:SetPoint("TOPRIGHT", -8, -5)
    way.value:SetWordWrap(false)

    way.label = Theme.CreateLabel(way, "small", "text")
    way.label:SetPoint("TOPLEFT", 8, -5)
    way.label:SetPoint("RIGHT", way.value, "LEFT", -6, 0)

    way.bar = Bar(way)
    way.bar:SetPoint("TOPLEFT", 8, -21)
    way.bar:SetPoint("TOPRIGHT", -8, -21)

    way.note = Theme.CreateLabel(way, "tiny", "muted")
    way.note:SetPoint("TOPLEFT", 8, -30)
    way.note:SetPoint("RIGHT", way, "RIGHT", -8, 0)

    return way
end

local function MaterialLine(detail, anchor, gap)
    local line = CreateFrame("Frame", nil, detail)
    line:SetHeight(28)
    line:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(gap or 2))
    line:SetPoint("RIGHT", detail, "RIGHT", -12, 0)

    line.label = Theme.CreateLabel(line, "small", "text")
    line.label:SetPoint("TOPLEFT", 0, 0)
    line.label:SetPoint("RIGHT", line, "RIGHT", -70, 0)

    line.value = Theme.CreateLabel(line, "small", "text", "RIGHT")
    line.value:SetPoint("TOPRIGHT", 0, 0)
    line.value:SetWidth(68)
    line.value:SetWordWrap(false)

    line.how = Theme.CreateLabel(line, "tiny", "muted")
    line.how:SetPoint("TOPLEFT", 0, -14)
    line.how:SetPoint("RIGHT", line, "RIGHT", 0, 0)

    return line
end

--- A material's two lines, whole: either wraps and the line grows to hold it.
function YourTimeView.FitMaterial(line, label, how)
    local labelExtra = Theme.FitWhole(line.label, label, { "small", "tiny" })
    local howExtra = Theme.FitWhole(line.how, how or "", { "tiny" })
    line.how:SetPoint("TOPLEFT", 0, -14 - labelExtra)
    line:SetHeight(28 + labelExtra + howExtra)
end

local function BuildDetail(parent)
    local detail = Theme.CreatePanel(parent, "window")
    Theme.AccentStripe(detail, 2, 0.6)
    detail:SetWidth(DETAIL_WIDTH)

    detail.title = Theme.CreateLabel(detail, "normal", "accent")
    detail.title:SetPoint("TOPLEFT", 12, -12)
    detail.title:SetPoint("TOPRIGHT", -12, -12)
    detail.title:SetWordWrap(true)

    detail.subtitle = Theme.CreateLabel(detail, "tiny", "muted")
    detail.subtitle:SetPoint("TOPLEFT", detail.title, "BOTTOMLEFT", 0, -4)
    detail.subtitle:SetPoint("TOPRIGHT", detail.title, "BOTTOMRIGHT", 0, -4)
    detail.subtitle:SetWordWrap(true)

    detail.waysHeading = Theme.CreateHeading(detail, L["FOR ONE CRAFT"])
    detail.waysHeading:SetPoint("TOPLEFT", detail.subtitle, "BOTTOMLEFT", 0, -10)

    detail.ways = {}
    local anchor = detail.waysHeading
    for index = 1, 3 do
        local way = Way(detail, anchor)
        detail.ways[index] = way
        anchor = way
    end

    detail.materialsHeading = Theme.CreateHeading(detail, L["MATERIALS"])
    detail.materialsHeading:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)

    detail.materials = {}
    anchor = detail.materialsHeading
    for index = 1, MATERIAL_LINES do
        local line = MaterialLine(detail, anchor, index == 1 and 6 or 2)
        detail.materials[index] = line
        anchor = line
    end

    detail.queue = Widgets.CreateButton(detail, L["Queue 1"], function()
        local entry = state.selectedEntry
        if not entry then return end
        ns.Queue:Add(entry.recipeID, 1)
        ns.Print(L.Format("queued 1x %s", entry.name or L["craft"]))
    end, { width = 90, height = 22, primary = true })
    detail.queue:SetPoint("BOTTOMLEFT", 12, 40)

    detail.note = Theme.CreateLabel(detail, "tiny", "dim")
    detail.note:SetPoint("BOTTOMLEFT", 12, 10)
    detail.note:SetPoint("BOTTOMRIGHT", -12, 10)
    detail.note:SetWordWrap(true)

    return detail
end

local function ShowNothing(detail)
    detail.title:SetText(L["Your time"])
    detail.title:SetTextColor(Theme.Unpack("accent"))
    detail.subtitle:SetText(L["Pick a craft to see where your time goes."])
    detail.waysHeading:Hide()
    detail.materialsHeading:Hide()
    for _, way in ipairs(detail.ways) do way:Hide() end
    for _, line in ipairs(detail.materials) do line:Hide() end
    detail.queue:Hide()
    detail.note:SetText(L["Farming time is your own, from Blackthornes Farmer. Walking there and selling aren't counted."])
end

local function ShowEntry(detail, entry)
    detail.title:SetText(entry.name)
    -- In the rarity of what it makes, as its row is.
    if not Theme.SetItemNameColor(detail.title, entry.outputItemID, "accent") and entry.outputItemID then
        state.waiting = true
    end
    if entry.yield and entry.yield ~= 1 then
        detail.subtitle:SetText(L.Format("Makes %s a craft", tostring(entry.yield)))
    else
        detail.subtitle:SetText(L["Gold an hour of your time, at today's prices"])
    end

    detail.waysHeading:Show()
    local farm, craft = entry.farmSeconds, entry.craftSeconds
    local longest = math.max((farm or 0) + (craft or 0), craft or 0, 1)

    local ways = {
        { key = "craft", label = L["Farm it, then craft"], value = entry.farmCraft, hour = true,
          farm = farm, craft = craft,
          note = farm and craft and L.Format("%s farming, %s crafting", Duration(farm), Duration(craft)) or nil },
        { key = "raw", label = L["Farm it, sell the mats"], value = entry.farmSell, hour = true,
          farm = farm, craft = 0,
          note = farm and L.Format("%s farming", Duration(farm)) or nil },
        { key = "buy", label = L["Buy the mats, then craft"], value = entry.buyProfit, hour = false,
          farm = 0, craft = craft,
          note = (entry.buyProfit or 0) < 0 and L["The mats cost more than it sells for."]
              or (farm and L.Format("The mats cost about %s of your farming.", Duration(farm)))
              or nil },
    }

    for index, way in ipairs(ways) do
        local frame = detail.ways[index]
        local best = entry.best == way.key
        frame.back:SetColorTexture(Theme.Unpack(best and "glassActive" or (index % 2 == 0 and "glassAlt" or "glass")))
        frame.edge:SetShown(best)
        local labelExtra = Theme.FitWhole(frame.label, way.label, { "small", "tiny" })
        if way.value == nil then
            frame.value:SetText("--")
            frame.value:SetTextColor(Theme.Unpack("dim"))
        else
            frame.value:SetText(way.hour and L.Format("%s an hour", Money(way.value)) or Money(way.value))
            frame.value:SetTextColor(Theme.Unpack(best and "profit" or (way.value < 0 and "loss" or "text")))
        end
        local missing = entry.missing and Util.ColoredItemName(entry.missing.itemID)
        local noteExtra = Theme.FitWhole(frame.note,
            way.note or (missing and L.Format("Farm some %s and this fills in.", missing)) or "", { "tiny" })
        -- A wrapped label or note makes the line taller, never cut.
        frame.bar:SetPoint("TOPLEFT", 8, -21 - labelExtra)
        frame.bar:SetPoint("TOPRIGHT", -8, -21 - labelExtra)
        frame.note:SetPoint("TOPLEFT", 8, -30 - labelExtra)
        frame:SetHeight(42 + labelExtra + noteExtra)
        SetBar(frame.bar, way.farm, way.craft, longest)
        frame.bar:SetShown(way.value ~= nil)
        frame:Show()
    end

    detail.materialsHeading:Show()
    local mats = entry.mats or {}
    for index, line in ipairs(detail.materials) do
        local mat = mats[index]
        if mat and index == MATERIAL_LINES and #mats > MATERIAL_LINES then
            YourTimeView.FitMaterial(line, L.Format("and %d more", #mats - MATERIAL_LINES + 1), "")
            line.value:SetText("")
            line:Show()
        elseif mat then
            local name = Util.ColoredItemName(mat.itemID)
            local count = math.floor(mat.count * 10 + 0.5) / 10
            count = count == math.floor(count) and ("%d"):format(count) or ("%.1f"):format(count)
            local label = ("%sx %s"):format(count, name)
            if mat.bought then
                line.value:SetText(Money(mat.bought))
                line.value:SetTextColor(Theme.Unpack("muted"))
                YourTimeView.FitMaterial(line, label, L["Bought from a vendor"])
                line.how:SetTextColor(Theme.Unpack("muted"))
            else
                line.value:SetText(mat.seconds and Duration(mat.seconds) or "--")
                line.value:SetTextColor(Theme.Unpack(mat.seconds and "text" or "dim"))
                YourTimeView.FitMaterial(line, label, YourTimeView.PaceText(mat))
                line.how:SetTextColor(Theme.Unpack(mat.pace and "muted" or "dim"))
            end
            line:Show()
        else
            line:Hide()
        end
    end

    detail.queue:Show()
    detail.note:SetText(L["Farming time is your own, from Blackthornes Farmer. Walking there and selling aren't counted."])
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

local function Filter(rows)
    local list = {}
    local needle = state.search ~= "" and state.search:lower() or nil
    for _, row in ipairs(rows or {}) do
        local keep = not needle or (row.name or ""):lower():find(needle, 1, true) ~= nil
        if keep and state.paceOnly and not row.farmSeconds then keep = false end
        if keep then list[#list + 1] = row end
    end
    -- Best an hour first; crafts not timed yet after, by buy profit.
    table.sort(list, function(a, b)
        local x, y = a.bestValue, b.bestValue
        if (x ~= nil) ~= (y ~= nil) then return x ~= nil end
        if x and y and x ~= y then return x > y end
        if (a.buyProfit or 0) ~= (b.buyProfit or 0) then return (a.buyProfit or 0) > (b.buyProfit or 0) end
        return (a.name or "") < (b.name or "")
    end)
    return list
end
YourTimeView.Filter = Filter

local function Draw(rows)
    if not widgets.list then return end
    state.waiting = false

    local list = Filter(rows)
    if widgets.sorter then list = widgets.sorter:Sort(list) end
    widgets.list:SetData(list)

    local timed = 0
    for _, row in ipairs(list) do
        if row.farmSeconds then timed = timed + 1 end
    end

    widgets.empty:SetShown(#list == 0)
    if #list == 0 then
        if not rows then
            widgets.empty:SetText(L["Working it out..."])
        elseif state.search ~= "" then
            widgets.empty:SetText(L.Format("Nothing matching \"%s\".", state.search))
        elseif state.paceOnly then
            widgets.empty:SetText(L["None of your crafts has materials you've farmed enough to time yet. Farm a little with Blackthornes Farmer on and they show up here."])
        else
            widgets.empty:SetText(L["None of your crafts uses materials you can farm."])
        end
    end

    if not ns.CraftOrFarm:HasFarmer() then
        widgets.summary:SetText(L["Turn on Blackthornes Farmer to see your farming time."])
    else
        widgets.summary:SetText(#list == 1 and L.Format("%d craft  ·  %d timed from your farming", #list, timed)
            or L.Format("%d crafts  ·  %d timed from your farming", #list, timed))
    end

    local selected
    for _, row in ipairs(list) do
        if row.recipeID == state.selected then selected = row break end
    end
    state.selectedEntry = selected
    if selected then ShowEntry(widgets.detail, selected) else ShowNothing(widgets.detail) end
end

function YourTimeView.Refresh()
    if not widgets.list then return end
    local rows, stale = ns.CraftOrFarm:Rows()
    Draw(rows)
    if stale then
        ns.CraftOrFarm:Build(function(built)
            if widgets.list and widgets.list:IsVisible() then Draw(built) end
        end)
    end
end

--- Draw again from the list already built, without working it out again.
function YourTimeView.Redraw()
    Draw((ns.CraftOrFarm:Rows()))
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

function YourTimeView.Build(view)
    if Widgets.FitColumns then Widgets.FitColumns(COLUMNS) end

    local right = -DETAIL_WIDTH - 16

    local search = Widgets.CreateSearchBox(view, L["Search crafts"], function(text)
        state.search = text or ""
        YourTimeView.Redraw()
    end)
    search:SetPoint("TOPLEFT", 8, -8)
    search:SetWidth(Widgets.SEARCH_WIDTH)

    local paceOnly = Widgets.CreateCheckbox(view, L["Only with your farming pace"], function(checked)
        state.paceOnly = checked and true or false
        YourTimeView.Redraw()
    end, false)
    paceOnly:SetPoint("LEFT", search, "RIGHT", 12, 0)

    local headings = CreateFrame("Frame", nil, view)
    headings:SetHeight(16)
    headings:SetPoint("TOPLEFT", 8, -40)
    headings:SetPoint("TOPRIGHT", view, "TOPRIGHT", right, -40)

    local nameHeading = Theme.CreateLabel(headings, "tiny", "muted")
    nameHeading:SetPoint("LEFT", 30, 0)
    nameHeading:SetText(L["CRAFT"])

    headings.cells = {}
    for _, column in ipairs(COLUMNS) do
        local cell = Theme.CreateLabel(headings, "tiny", "muted", column.justify or "RIGHT")
        cell:SetText(column.label)
        headings.cells[column.key] = cell
    end
    ns.Columns:Place("yourtime", COLUMNS, headings.cells, { gap = 8 })

    local sortLabels = { name = nameHeading }
    for key, cell in pairs(headings.cells) do sortLabels[key] = cell end
    widgets.sorter = Widgets.SortableHeadings and Widgets.SortableHeadings(sortLabels, {
        name = function(entry) return entry.name end,
        farmCraft = function(entry) return entry.farmCraft end,
        farmSell = function(entry) return entry.farmSell end,
        buyCraft = function(entry) return entry.buyProfit end,
        best = function(entry) return entry.bestValue end,
    }, function() YourTimeView.Redraw() end)
    if widgets.sorter then widgets.sorter:SetText({ "name" }) end

    ns.Columns:Attach(headings, "yourtime", widgets.sorter)
    ns.Columns:OnChange("yourtime", function()
        ns.Columns:Place("yourtime", COLUMNS, headings.cells, { gap = 8 })
        if widgets.sorter and widgets.sorter.Sync then widgets.sorter:Sync() end
        if widgets.list then widgets.list:Refresh() end
    end)

    local divider = Theme.CreateDivider(view, "borderLit")
    divider:SetPoint("TOPLEFT", headings, "BOTTOMLEFT", 0, -2)
    divider:SetPoint("TOPRIGHT", headings, "BOTTOMRIGHT", 0, -2)

    local list = Widgets.CreateScrollList(view, {
        rowHeight = ROW_HEIGHT,
        createRow = CreateRow,
        updateRow = UpdateRow,

        isSelected = function(entry)
            return state.selected ~= nil and entry.recipeID == state.selected
        end,

        onClick = function(entry, _, mouseButton)
            if mouseButton == "RightButton" then
                ns.Queue:Add(entry.recipeID, 1)
                ns.Print(L.Format("queued 1x %s", entry.name or L["craft"]))
                return
            end
            state.selected = state.selected ~= entry.recipeID and entry.recipeID or nil
            YourTimeView.Redraw()
        end,

        onEnter = ShowRowTooltip,
        onLeave = function() GameTooltip:Hide() end,

        onScrollbarShown = function(shown)
            headings:SetPoint("TOPRIGHT", view, "TOPRIGHT", right - (shown and 10 or 0), -40)
        end,
    })
    list:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -4)
    list:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", right, 24)
    widgets.list = list

    local empty = Theme.CreateLabel(view, "small", "dim", "CENTER")
    empty:SetPoint("CENTER", list, "CENTER")
    empty:SetWidth(320)
    empty:SetWordWrap(true)
    widgets.empty = empty

    local summary = Theme.CreateLabel(view, "tiny", "dim")
    summary:SetPoint("BOTTOMLEFT", 8, 8)
    widgets.summary = summary

    local detail = BuildDetail(view)
    detail:SetPoint("TOPRIGHT", view, "TOPRIGHT", -8, -8)
    detail:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -8, 8)
    widgets.detail = detail
    ShowNothing(detail)

    local redrawQueued = false
    ns.RegisterEvent(YourTimeView, "GET_ITEM_INFO_RECEIVED", function(_, _, _, success)
        if success == false then return end
        if redrawQueued or not state.waiting then return end
        if not list:IsVisible() then return end

        redrawQueued = true
        C_Timer.After(0.3, function()
            redrawQueued = false
            YourTimeView.Redraw()
        end)
    end)
end
