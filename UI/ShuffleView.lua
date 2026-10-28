-- Blackthornes Tradeskills -- UI/ShuffleView.lua
-- The Shuffles view on the Profit tab (a player asked, the owner said build
-- it from a mockup, 2026-10-25): pick something in your bags and how many,
-- and see every way to turn it into gold, best gain first. Picking a way
-- shows it step by step, with what each step is worth if you stop there.
-- Logic/Shuffle.lua works it out.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local ShuffleView = {}
ns.ShuffleView = ShuffleView

local ROW_HEIGHT = 32
local DETAIL_WIDTH = 300
-- Start, up to three crafts and a disenchant.
local STEP_LINES = 5
local MOST = 10000

-- Right to left, measured from the list's right edge.
local COLUMNS = {
    { key = "gain",  label = L["GAIN"],         width = 76, money = true },
    { key = "back",  label = L["YOU GET BACK"], width = 84, money = true },
    { key = "putIn", label = L["YOU PUT IN"],   width = 80, money = true },
    { key = "steps", label = L["STEPS"],        width = 44, justify = "CENTER" },
}

if ns.Columns then ns.Columns:Register("shuffles", L["SHUFFLES"], COLUMNS) end

local HOW = { ah = L["(AH)"], vendor = L["(Vendor)"], de = L["(DE)"] }

local state = { itemID = nil, count = nil, mine = true, selected = nil, waiting = false }
local widgets = {}

ShuffleView._state = state
ShuffleView._widgets = widgets

local function Money(copper)
    return Util.FormatMoney(copper, { short = true })
end

--- "+1g 20s", "-35s", "0".
function ShuffleView.Signed(copper)
    copper = math.floor((copper or 0) + 0.5)
    if copper > 0 then return "+" .. Money(copper) end
    if copper < 0 then return "-" .. Money(-copper) end
    return Money(0)
end

local function Whole(count)
    return math.max(0, math.floor((count or 0) + 0.5))
end

local function Name(itemID)
    local name = ns.Shuffle.ItemName(itemID)
    if not name then state.waiting = true end
    return Util.ColoredItemName(itemID, name or ("#" .. tostring(itemID)))
end

--- The words for one step: "Smelt into 20 Copper Bar".
function ShuffleView.StepText(step)
    local count, name = Whole(step.count), Name(step.itemID)
    if step.kind == "start" then return L.Format("Start with %d %s", count, name) end
    if step.kind == "de" then
        return L.Format("Disenchant into about %d %s", math.max(1, count), name)
    end
    if step.verb == "smelt" then return L.Format("Smelt into %d %s", count, name) end
    return L.Format("Make %d %s", count, name)
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function PlaceRow(row)
    local offset = ns.Columns:Place("shuffles", COLUMNS, row.cells, { gap = 8 })
    row.name:SetPoint("RIGHT", row, "RIGHT", offset - 8, 0)
    row.chain:SetPoint("RIGHT", row, "RIGHT", offset - 8, 0)
    row.columnsVersion = ns.Columns.version
end

local function CreateRow(row)
    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("TOPLEFT", 10, -4)
    row.name:SetWordWrap(false)

    row.chain = Theme.CreateLabel(row, "tiny", "muted")
    row.chain:SetPoint("TOPLEFT", 10, -18)
    row.chain:SetWordWrap(false)

    row.cells = {}
    for _, column in ipairs(COLUMNS) do
        local cell = Theme.CreateLabel(row, "small", "text", column.justify or "RIGHT")
        cell:SetWordWrap(false)
        row.cells[column.key] = cell
    end

    PlaceRow(row)
end

local function UpdateRow(row, way)
    if row.columnsVersion ~= ns.Columns.version then PlaceRow(row) end

    Theme.SetRowName(row.name, way.name)
    row.name:SetTextColor(Theme.Unpack(way.id == 1 and "accentHi" or "text"))
    local chain = ns.Shuffle.ChainText(way.chain)
    for _, itemID in ipairs(way.chain) do
        if not ns.Shuffle.ItemName(itemID) then state.waiting = true end
    end
    row.chain:SetText(chain)

    local cells = row.cells
    cells.steps:SetText(tostring(#way.steps))
    cells.steps:SetTextColor(Theme.Unpack("muted"))
    Theme.SetMoneyText(cells.putIn, way.putIn, { short = true })
    cells.putIn:SetTextColor(Theme.Unpack("text"))
    Theme.SetMoneyText(cells.back, way.back, { short = true })
    cells.back:SetTextColor(Theme.Unpack("text"))
    cells.gain:SetText(ShuffleView.Signed(way.gain))
    cells.gain:SetTextColor(Theme.ProfitColor(way.gain))
end

--------------------------------------------------------------------------------
-- Detail pane
--------------------------------------------------------------------------------

local function StepLine(detail)
    local line = CreateFrame("Frame", nil, detail)
    line:SetHeight(40)

    line.back = line:CreateTexture(nil, "BACKGROUND")
    line.back:SetAllPoints()
    line.back:SetColorTexture(Theme.Unpack("glass"))
    line.edge = line:CreateTexture(nil, "BORDER")
    line.edge:SetPoint("TOPLEFT")
    line.edge:SetPoint("BOTTOMLEFT")
    line.edge:SetWidth(2)
    line.edge:SetColorTexture(Theme.Unpack("accentHi"))
    line.rule = line:CreateTexture(nil, "BORDER")
    line.rule:SetPoint("BOTTOMLEFT")
    line.rule:SetPoint("BOTTOMRIGHT")
    line.rule:SetHeight(1)
    line.rule:SetColorTexture(Theme.Unpack("border"))
    line.rule:SetAlpha(0.6)

    line.num = Theme.CreateLabel(line, "small", "muted")
    line.num:SetPoint("TOPLEFT", 8, -5)
    line.num:SetWidth(14)

    line.how = Theme.CreateLabel(line, "tiny", "muted", "RIGHT")
    line.how:SetPoint("TOPRIGHT", -8, -6)
    line.how:SetWordWrap(false)

    line.text = Theme.CreateLabel(line, "small", "text")
    line.text:SetPoint("TOPLEFT", 24, -5)
    line.text:SetPoint("RIGHT", line.how, "LEFT", -6, 0)
    line.text:SetWordWrap(true)

    line.worth = Theme.CreateLabel(line, "tiny", "muted")
    line.worth:SetPoint("TOPLEFT", line.text, "BOTTOMLEFT", 0, -3)
    line.worth:SetWordWrap(false)

    line.change = Theme.CreateLabel(line, "tiny", "muted", "RIGHT")
    line.change:SetPoint("TOPRIGHT", line, "TOPRIGHT", -8, 0)
    line.change:SetPoint("TOP", line.worth, "TOP", 0, 0)
    line.change:SetWordWrap(false)

    line.best = Theme.CreateLabel(line, "tiny", "profit")
    line.best:SetPoint("TOPLEFT", line.worth, "BOTTOMLEFT", 0, -2)
    line.best:SetText(L["Best place to stop"])

    line.note = Theme.CreateLabel(line, "tiny", "muted")
    line.note:SetPoint("RIGHT", line, "RIGHT", -8, 0)
    line.note:SetWordWrap(true)

    return line
end

local function Height(label, fallback)
    local height = label.GetStringHeight and label:GetStringHeight()
    return (type(height) == "number" and height > 0) and height or fallback
end

local function FillStep(line, index, step)
    line.back:SetColorTexture(Theme.Unpack(step.best and "glassActive" or (index % 2 == 0 and "glassAlt" or "glass")))
    line.edge:SetShown(step.best and true or false)
    line.num:SetText(tostring(index))
    line.text:SetText(ShuffleView.StepText(step))
    line.how:SetText(HOW[step.how] or "")

    local worth = ns.Util.FormatMoney(step.worth or 0, { short = true })
    line.worth:SetText(("%s  %s"):format(L["Worth"], worth))
    line.worth:SetTextColor(Theme.Unpack((step.worth or 0) < 0 and "loss" or "muted"))
    if index > 1 then
        line.change:SetText(ShuffleView.Signed(step.change))
        line.change:SetTextColor(Theme.ProfitColor(step.change))
    else
        line.change:SetText("")
    end

    local anchor = line.worth
    line.best:SetShown(step.best and true or false)
    if step.best then anchor = line.best end

    line.note:ClearAllPoints()
    line.note:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    line.note:SetPoint("RIGHT", line, "RIGHT", -8, 0)
    line.note:SetText(step.note or "")
    line.note:SetTextColor(Theme.Unpack(step.loss and "loss" or "muted"))
    line.note:SetShown(step.note ~= nil)

    local height = 5 + Height(line.text, 13) + 3 + Height(line.worth, 11)
    if step.best then height = height + 2 + Height(line.best, 11) end
    if step.note then height = height + 2 + Height(line.note, 11) end
    line:SetHeight(height + 6)
end

local function BuildDetail(parent)
    local detail = Theme.CreatePanel(parent, "window")
    Theme.AccentStripe(detail, 2, 0.6)
    detail:SetWidth(DETAIL_WIDTH)

    detail.title = Theme.CreateLabel(detail, "normal", "accent")
    detail.title:SetPoint("TOPLEFT", 12, -12)
    detail.title:SetPoint("TOPRIGHT", -12, -12)
    detail.title:SetWordWrap(true)

    detail.heading = Theme.CreateHeading(detail, L["STEP BY STEP"])
    detail.heading:SetPoint("TOPLEFT", detail.title, "BOTTOMLEFT", 0, -10)

    detail.steps = {}
    local anchor = detail.heading
    for index = 1, STEP_LINES do
        local line = StepLine(detail)
        line:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, index == 1 and -6 or 0)
        line:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
        detail.steps[index] = line
        anchor = line
    end

    detail.odds = Theme.CreateLabel(detail, "tiny", "dim")
    detail.odds:SetPoint("BOTTOMLEFT", 12, 10)
    detail.odds:SetPoint("BOTTOMRIGHT", -12, 10)
    detail.odds:SetWordWrap(true)

    detail.prices = Theme.CreateLabel(detail, "tiny", "dim")
    detail.prices:SetPoint("BOTTOMLEFT", detail.odds, "TOPLEFT", 0, 4)
    detail.prices:SetPoint("BOTTOMRIGHT", detail.odds, "TOPRIGHT", 0, 4)
    detail.prices:SetWordWrap(true)
    detail.prices:SetText(L["Prices come from your scans first, then your guild, TSM and Auctionator."])

    detail.list = Widgets.CreateButton(detail, L["Add to List"], function()
        local way = state.selectedWay
        if not way then return end
        local index, name = ns.Shuffle:AddToList(way)
        if index then
            ns.Print(L.Format("Added %s to %s.", Util.ColoredItemName(way.startID), name or ""))
        elseif name then
            ns.Print(name)
        end
    end, { width = 100, height = 22 })
    detail.list:SetPoint("BOTTOMLEFT", detail.prices, "TOPLEFT", 0, 8)

    detail.queue = Widgets.CreateButton(detail, L["Queue It"], function()
        local way = state.selectedWay
        if not way then return end
        local done, why = ns.Shuffle:Queue(way)
        if done then
            for _, craft in ipairs(way.crafts) do
                local recipe = ns.Recipes.GetAll and ns.Recipes:GetAll()[craft.recipeID]
                ns.Print(L.Format("queued %dx %s", craft.crafts, recipe and recipe.name or L["craft"]))
            end
        elseif why then
            ns.Print(why)
        end
    end, { width = 100, height = 22, primary = true })
    detail.queue:SetPoint("LEFT", detail.list, "RIGHT", 8, 0)

    return detail
end

local function ShowNothing(detail)
    detail.title:SetText(L["SHUFFLES"])
    detail.title:SetTextColor(Theme.Unpack("accent"))
    detail.heading:Hide()
    for _, line in ipairs(detail.steps) do line:Hide() end
    detail.list:Hide()
    detail.queue:Hide()
    detail.odds:SetText("")
end

local function ShowWay(detail, way)
    detail.title:SetText(way.name)
    detail.title:SetTextColor(Theme.Unpack("accent"))
    detail.heading:Show()

    local broke = false
    for index, line in ipairs(detail.steps) do
        local step = way.steps[index]
        if step then
            FillStep(line, index, step)
            line:Show()
            if step.kind == "de" then broke = true end
        else
            line:Hide()
        end
    end

    detail.list:Show()
    detail.queue:SetShown(ns.Shuffle.CanQueue(way))
    detail.odds:SetText(broke
        and L.Format("Disenchant odds come from what you've broken. %d so far.", ns.Shuffle.BrokenSoFar())
        or "")
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

local function ScanText()
    local at = ns.Prices and ns.Prices.GetLastScan and ns.Prices:GetLastScan()
    if type(at) ~= "number" or at <= 0 or type(time) ~= "function" then return "" end
    return L.Format("Prices from your scan %s", Util.FormatAgeAgo(math.max(0, time() - at)))
end

local function Draw(ways)
    if not widgets.list then return end
    state.waiting = false

    local list = {}
    for _, way in ipairs(ways or {}) do list[#list + 1] = way end
    if widgets.sorter then list = widgets.sorter:Sort(list) end
    widgets.list:SetData(list)

    widgets.empty:SetShown(#list == 0)
    if #list == 0 then
        widgets.empty:SetText(state.itemID and not ways and L["Working it out..."]
            or L["Pick something to start with. You'll see every way to turn it into gold."])
    end
    widgets.scan:SetText(ScanText())

    local selected
    for _, way in ipairs(list) do
        if way.id == state.selected then selected = way break end
    end
    if not selected and ways and ways[1] then
        selected = ways[1]
        state.selected = selected.id
    end
    state.selectedWay = selected
    if selected then ShowWay(widgets.detail, selected) else ShowNothing(widgets.detail) end
end
ShuffleView.Draw = Draw

--- Fill the Start With box from the bags, keeping the pick while it's there.
local function FillStarts()
    if not widgets.start then return end
    local starts = ns.Shuffle:Starts(state.mine)
    local options, counts, found = {}, {}, false
    for _, entry in ipairs(starts) do
        local name = ns.Shuffle.ItemName(entry.itemID)
        if not name then state.waiting = true end
        options[#options + 1] = { text = name or ("#" .. entry.itemID), value = entry.itemID }
        counts[entry.itemID] = entry.count
        if entry.itemID == state.itemID then found = true end
    end
    table.sort(options, function(a, b) return a.text < b.text end)
    widgets.counts = counts
    if not found then state.itemID, state.count = nil, nil end
    widgets.start:SetOptions(options)
    widgets.start:SetValue(state.itemID)
    if not state.itemID then widgets.start.label:SetText("") end
end
ShuffleView.FillStarts = FillStarts

function ShuffleView.Refresh()
    if not widgets.list then return end
    if not state.itemID then
        Draw(nil)
        return
    end
    local ways, stale = ns.Shuffle:Get(state.itemID, state.count, state.mine)
    Draw(ways)
    if stale then
        ns.Shuffle:Build(state.itemID, state.count, state.mine, function(built)
            if widgets.list and widgets.list:IsVisible() then Draw(built) end
        end)
    end
end

--- Pick a start (and how many; all in the bags when not given).
function ShuffleView.Pick(itemID, count)
    if itemID ~= state.itemID then state.selected = nil end
    state.itemID = itemID
    state.count = math.max(1, math.min(MOST, math.floor(tonumber(count)
        or (widgets.counts and widgets.counts[itemID]) or 1)))
    if widgets.count then widgets.count:SetValue(state.count, true) end
    ShuffleView.Refresh()
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

function ShuffleView.Build(view)
    if Widgets.FitColumns then Widgets.FitColumns(COLUMNS) end

    local right = -DETAIL_WIDTH - 16

    local startLabel = Theme.CreateLabel(view, "small", "muted")
    startLabel:SetPoint("TOPLEFT", 8, -12)
    startLabel:SetText(L["Start With:"])

    local start = Widgets.CreateDropdown(view, {}, function(value)
        if value then ShuffleView.Pick(value) end
    end, { width = 170 })
    start:SetPoint("LEFT", startLabel, "RIGHT", 6, 0)
    widgets.start = start

    local countLabel = Theme.CreateLabel(view, "small", "muted")
    countLabel:SetPoint("LEFT", start, "RIGHT", 12, 0)
    countLabel:SetText(L["How Many:"])

    local minus, plus
    local count = Widgets.CreateNumberBox(view, {
        width = 50, height = 22, min = 1, max = MOST, justify = "CENTER",
        onChange = function(value)
            if state.itemID and value then ShuffleView.Pick(state.itemID, value) end
        end,
    })
    minus = Widgets.CreateButton(view, "-", function()
        count:SetValue((count:GetValue() or 1) - 1)
    end, { width = 20, height = 20 })
    minus:SetPoint("LEFT", countLabel, "RIGHT", 6, 0)
    count:SetPoint("LEFT", minus, "RIGHT", 2, 0)
    plus = Widgets.CreateButton(view, "+", function()
        count:SetValue((count:GetValue() or 0) + 1)
    end, { width = 20, height = 20 })
    plus:SetPoint("LEFT", count, "RIGHT", 2, 0)
    count:SetValue(1, true)
    widgets.count = count

    local mine = Widgets.CreateCheckbox(view, L["Only My Recipes"], function(checked)
        state.mine = checked and true or false
        FillStarts()
        ShuffleView.Refresh()
    end, state.mine)
    mine:SetPoint("LEFT", plus, "RIGHT", 12, 0)

    local scan = Theme.CreateLabel(view, "tiny", "dim", "RIGHT")
    scan:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", right, 8)
    scan:SetWordWrap(false)
    widgets.scan = scan

    local headings = CreateFrame("Frame", nil, view)
    headings:SetHeight(16)
    headings:SetPoint("TOPLEFT", 8, -40)
    headings:SetPoint("TOPRIGHT", view, "TOPRIGHT", right, -40)

    local nameHeading = Theme.CreateLabel(headings, "tiny", "muted")
    nameHeading:SetPoint("LEFT", 10, 0)
    nameHeading:SetText(L["WAY"])

    headings.cells = {}
    for _, column in ipairs(COLUMNS) do
        local cell = Theme.CreateLabel(headings, "tiny", "muted", column.justify or "RIGHT")
        cell:SetText(column.label)
        headings.cells[column.key] = cell
    end
    ns.Columns:Place("shuffles", COLUMNS, headings.cells, { gap = 8 })

    local sortLabels = { name = nameHeading }
    for key, cell in pairs(headings.cells) do sortLabels[key] = cell end
    widgets.sorter = Widgets.SortableHeadings and Widgets.SortableHeadings(sortLabels, {
        name = function(way) return way.name end,
        steps = function(way) return #way.steps end,
        putIn = function(way) return way.putIn end,
        back = function(way) return way.back end,
        gain = function(way) return way.gain end,
    }, function() ShuffleView.Refresh() end)
    if widgets.sorter then widgets.sorter:SetText({ "name" }) end

    ns.Columns:Attach(headings, "shuffles", widgets.sorter)
    ns.Columns:OnChange("shuffles", function()
        ns.Columns:Place("shuffles", COLUMNS, headings.cells, { gap = 8 })
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

        isSelected = function(way)
            return state.selected ~= nil and way.id == state.selected
        end,

        onClick = function(way)
            state.selected = way.id
            ShuffleView.Refresh()
        end,

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

    local detail = BuildDetail(view)
    detail:SetPoint("TOPRIGHT", view, "TOPRIGHT", -8, -8)
    detail:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -8, 8)
    widgets.detail = detail
    ShowNothing(detail)

    -- The bags are read again each time the view shows.
    view:HookScript("OnShow", function()
        FillStarts()
        ShuffleView.Refresh()
    end)
    FillStarts()

    local redrawQueued = false
    ns.RegisterEvent(ShuffleView, "GET_ITEM_INFO_RECEIVED", function(_, _, _, success)
        if success == false then return end
        if redrawQueued or not state.waiting then return end
        if not list:IsVisible() then return end

        redrawQueued = true
        C_Timer.After(0.3, function()
            redrawQueued = false
            FillStarts()
            Draw((ns.Shuffle:Get(state.itemID or 0, state.count or 1, state.mine)))
        end)
    end)
end
