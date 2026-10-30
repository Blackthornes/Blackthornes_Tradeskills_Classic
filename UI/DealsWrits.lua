-- Blackthornes Tradeskills -- UI/DealsWrits.lua
-- The Deals tab's Craftsman's Writs view: writs by what a point of
-- reputation costs, and what a reputation goal still costs.
--
-- A player's idea (2026-10-09). Each row is a writ: the writ on the auction
-- house, the item it asks for (bought, or made from bought materials), and
-- what that makes one point of reputation cost. The panel on the right reads
-- the character's standing with the trade camp, and says how many writs the
-- goal picked on the option bar still needs and what the cheapest and the
-- quickest ways cost. The sums are Logic/Writs.lua. Tab_Deals.lua shows this
-- in place of its flips when its Show menu says so, and owns the option bar.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local DealsWrits = ns.NewModule("DealsWrits")

local ROW_HEIGHT = 22
local DETAIL_WIDTH = 300
local ICON_GUTTER = 20
-- The Buy box goes from 1 to this many writs.
local BUY_MOST = 99

-- Columns, laid out right to left, as on the flips list.
local COLUMNS = {
    { key = "perRep",    label = L["PER REP"], width = 66, money = true },
    { key = "total",     label = L["TOTAL"], width = 66, money = true },
    { key = "itemCost",  label = L["ITEM"], width = 96, money = true },
    { key = "writPrice", label = L["WRIT"], width = 80, money = true },
    { key = "rep",       label = L["REP"], width = 40, justify = "CENTER" },
    -- How many are on the auction house at the row's price (a player
    -- asked, 2026-10-19; it was what you own before).
    { key = "onAH", label = L["ON AH"], width = 44, justify = "CENTER" },
}

-- Any column but the item's name can be hidden (UI/Columns.lua).
ns.Columns:Register("writs", L["Deals: Craftsman's Writs"], COLUMNS)

local state = {
    search = "",
    goal = nil,         -- read from Settings the first time it is asked
    selected = nil,
    buy = 1,            -- the Buy box, for this session only
}

local widgets = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function Money(value)
    return Util.FormatMoney(value, { short = true })
end

local function Plain(value)
    return Util.FormatMoney(value, { noColor = true })
end

local function Round(value)
    return value and math.floor(value + 0.5) or nil
end

local function TierName(tier)
    return ns.WRIT_TIERS and ns.WRIT_TIERS[tier] or "?"
end

local function SameRow(a, b)
    return a and b and a.key == b.key
end

--- Where the reputation figure came from, in a few words.
local function RewardText(row)
    if row.source == "learned" then
        if row.turnIns == 1 then
            return L.Format("Pays %d reputation, seen on one turn-in.", row.rep)
        end
        return L.Format("Pays %d reputation, seen on %d turn-ins.", row.rep, row.turnIns or 1)
    elseif row.source == "reported" then
        return L.Format("Guides report %d reputation. Not seen on a turn-in here yet.", row.rep)
    end
    return L["Nobody knows what it pays yet."]
end

local function Search(itemID, what)
    local scanner = ns.Scanner
    if not scanner or not scanner.isAuctionHouseOpen then
        ns.Print(L["Open the auction house first, then search again."])
        return
    end
    if scanner.isScanning then
        ns.Print(L["A scan is running. Search again once it finishes."])
        return
    end
    if not itemID then
        if what == "writ" then
            ns.Print(L["The game hasn't shown this writ to the addon yet, so type its name into the auction house search box."])
        else
            ns.Print(L["The game hasn't shown this item to the addon yet, so type its name into the auction house search box."])
        end
        return
    end
    ns.UI:SearchAuctionHouse(itemID)
end

local function SearchWrit(row)
    if row then Search(row.writID, "writ") end
end

local function SearchItem(row)
    if row then Search(row.itemID, "item") end
end

local function ItemName(itemID)
    return ns.MerchantsFavor and ns.MerchantsFavor.NameOf(itemID) or nil
end

--- What Search Both looks for: the writ, then the item it asks for, or
--- the materials to make it when that is cheaper.
-- @return items, reagents (nil unless made)
local function BothItems(row, buy)
    local items = { { itemID = row.writID, count = buy } }
    if row.how == "make" and row.recipeID and ns.MerchantsFavor then
        local _, reagents = ns.MerchantsFavor.CraftPlan(row.recipeID, row.count * buy)
        if reagents and #reagents > 0 then
            for _, reagent in ipairs(reagents) do items[#items + 1] = reagent end
            return items, reagents
        end
    end
    items[#items + 1] = { itemID = row.itemID, count = row.count * buy }
    return items
end

--- The writ and what it asks for, in one search (a player asked, 2026-10-18).
local function SearchBoth(row)
    if not row then return end
    local scanner = ns.Scanner
    if not row.writID or not ns.MerchantsFavor or not scanner or not scanner.isAuctionHouseOpen
            or scanner.isScanning then
        return Search(row.writID, "writ")
    end
    local items, reagents = BothItems(row, state.buy)
    local first = ItemName(row.writID) or L.Format("Craftsman's Writ: %s", row.name)
    local second = reagents and ns.MerchantsFavor.NamesOf(reagents) or row.name
    ns.MerchantsFavor:SearchBoth(items, first, second)
end

local function BothTooltip(row)
    local buy = state.buy
    local _, reagents = BothItems(row, buy)
    if reagents then
        return L.Format("Finds %d of this writ and the materials to make %d %s. You click Buy yourself.",
            buy, row.count * buy, row.name)
    end
    return L.Format("Finds %d of this writ and %d of the item it asks for. You click Buy yourself.",
        buy, row.count * buy)
end

--- Queue the crafts that make the item, times the Buy box.
local function QueueItem(row)
    if not (row and row.how == "make" and row.recipeID and ns.MerchantsFavor) then return end
    ns.MerchantsFavor:QueueCraft(row.recipeID, row.count * state.buy, row.name)
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

--- The shown columns from the right edge; the name has the rest.
local function PlaceRow(row)
    local offset = ns.Columns:Place("writs", COLUMNS, row.cells, { byIndex = true })
    row.name:SetPoint("RIGHT", row, "RIGHT", offset - 4, 0)
    row.columnsVersion = ns.Columns.version
end

local function CreateRow(row)
    row.icon = Theme.CreateItemIcon(row, 16)
    row.icon:SetPoint("LEFT", 8, 0)

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("LEFT", 8 + ICON_GUTTER, 0)

    row.cells = {}
    for index, column in ipairs(COLUMNS) do
        row.cells[index] = Theme.CreateLabel(row, "small", "text", column.justify or "RIGHT")
        -- Cheaper made than bought: a green Make at the left of the
        -- price's column, in one spot down the list whatever the price
        -- (a player's report, 2026-10-22: it rode beside the price before).
        if column.key == "itemCost" then
            row.make = Theme.CreateLabel(row, "small", "profit", "LEFT")
            row.make:SetPoint("LEFT", row.cells[index], "LEFT", 0, 0)
            row.make:SetText(L["Make"])
            row.makeCell = row.cells[index]
        end
    end

    PlaceRow(row)
end

local function FillCell(cell, key, entry)
    if key == "onAH" then
        local count = entry.onAHAtPrice or entry.onAHTotal
        cell:SetText(count and tostring(count) or "")
        cell:SetTextColor(Theme.Unpack((count or 0) > 0 and "text" or "dim"))
        return
    end
    if key == "rep" then
        cell:SetText(entry.rep and tostring(entry.rep) or "?")
        cell:SetTextColor(Theme.Unpack(entry.source == "learned" and "text"
            or entry.source == "reported" and "muted" or "warn"))
        return
    end

    local value = entry[key]
    if key == "perRep" then value = Round(value) end
    local text = value and Money(value) or ""
    cell:SetText(text)
    cell:SetTextColor(Theme.Unpack(key == "perRep" and "accent" or key == "total" and "text" or "muted"))
end

local function NameText(entry)
    return entry.count > 1 and ("%d %s"):format(entry.count, entry.name) or entry.name
end

local function UpdateRow(row, entry)
    if row.columnsVersion ~= ns.Columns.version then PlaceRow(row) end

    Theme.SetRowName(row.name, NameText(entry))
    Theme.SetItemIcon(row.icon, entry.itemID)
    -- In its rarity colour, faded while it has no price.
    local r, g, b = Util.GetItemQualityColor(entry.itemID)
    if r then
        row.name:SetTextColor(r, g, b, entry.perRep and 1 or 0.55)
    else
        row.name:SetTextColor(Theme.Unpack(entry.perRep and "text" or "dim"))
    end

    for index, column in ipairs(COLUMNS) do
        FillCell(row.cells[index], column.key, entry)
    end
    if row.make then
        local shown = row.makeCell and (not row.makeCell.IsShown or row.makeCell:IsShown() ~= false)
        row.make:SetShown((shown and entry.itemCost and entry.how == "make") and true or false)
    end
end

local function ItemLine(entry)
    if not entry.itemCost then return nil end
    local cost = Plain(entry.itemCost)
    local name = Util.ColorItemName(entry.itemID, entry.name)
    if entry.how == "make" then
        if entry.count > 1 then
            return L.Format("%d %s, made from materials: %s", entry.count, name, cost)
        end
        return L.Format("%s, made from materials: %s", name, cost)
    end
    if entry.count > 1 then
        return L.Format("%d %s, bought: %s", entry.count, name, cost)
    end
    return L.Format("%s, bought: %s", name, cost)
end

local function ShowRowTooltip(row, entry)
    GameTooltip:SetOwner(row, "ANCHOR_LEFT")
    GameTooltip:AddLine(L.Format("Craftsman's Writ: %s", Util.ColorItemName(entry.itemID, entry.name)))
    GameTooltip:AddLine(L.Format("%s %s, skill %d", TierName(entry.tier), entry.prof, entry.writ.skill),
        0.7, 0.7, 0.7)

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L.Format("Writ: %s", entry.writPrice and Plain(entry.writPrice)
        or (entry.noneListed and L["none listed"] or L["not priced"])),
        0.85, 0.85, 0.85)
    GameTooltip:AddLine(ItemLine(entry) or L["Item: not priced"], 0.85, 0.85, 0.85, true)
    if entry.perRep then
        GameTooltip:AddLine(L.Format("%s for each reputation.", Plain(Round(entry.perRep))), 0.35, 0.85, 0.45, true)
    end
    GameTooltip:AddLine(RewardText(entry), 0.7, 0.7, 0.7, true)
    if entry.onAHAtPrice then
        GameTooltip:AddLine(L.Format("On the AH at this price: %d", entry.onAHAtPrice), 0.85, 0.85, 0.85)
    end
    if entry.onAHTotal then
        GameTooltip:AddLine(L.Format("On the AH in all: %d", entry.onAHTotal), 0.85, 0.85, 0.85)
    end
    if ns.Writs and ns.Writs.SealedSources then
        for _, source in ipairs(ns.Writs:SealedSources(entry.writ)) do
            GameTooltip:AddLine(L.Format("Came from %s: %d of %d", source.name, source.count, source.opens),
                0.95, 0.82, 0.45, true)
        end
    end
    GameTooltip:AddLine(L.Format("You have %d, counting your bags, bank and mail.", entry.haveWrits or 0),
        0.85, 0.85, 0.85)
    GameTooltip:AddLine(L["Right-click a row to search for both"], 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- Detail panel
--------------------------------------------------------------------------------

-- A line stands at least this tall; one whose name wraps stands taller.
local LINE_HEIGHT = 17
-- The value column is at least this wide, and grows to fit what it says.
local VALUE_WIDTH = 80
local VALUE_MOST = 130
-- The Buy box and the search buttons at the panel's foot stay put; what is
-- above them scrolls when it runs longer than the panel.
local FOOT_HEIGHT = 104

--- Stack the lines by how tall each one stands, so a name that wraps
--- pushes the lines under it down rather than sitting on them.
local function PlaceLines(block)
    local y = 0
    for _, line in ipairs(block.lines) do
        line.label:ClearAllPoints()
        line.label:SetPoint("TOPLEFT", 0, -y)
        line.label:SetPoint("RIGHT", block, "RIGHT", -(line.valueWidth + 4), 0)
        line.value:ClearAllPoints()
        line.value:SetPoint("TOPRIGHT", 0, -y)
        line.value:SetWidth(line.valueWidth)
        if line.shown then
            local need = tonumber(line.label.rowNeed) or 0
            y = y + math.max(LINE_HEIGHT, need + 3)
        end
    end
    block:SetHeight(math.max(1, y))
end

local function Lines(parent, count)
    local block = CreateFrame("Frame", nil, parent)
    block.lines = {}

    for index = 1, count do
        local label = Theme.CreateLabel(block, "small", "muted")
        label:SetWordWrap(false)

        local value = Theme.CreateLabel(block, "small", "text", "RIGHT")

        block.lines[index] = { label = label, value = value, block = block,
            valueWidth = VALUE_WIDTH, shown = true }
    end

    PlaceLines(block)
    return block
end

local function SetLine(line, label, value, labelColor, valueColor)
    line.label:SetShown(label ~= nil)
    line.value:SetShown(label ~= nil)
    line.shown = label ~= nil
    if not label then
        PlaceLines(line.block)
        return
    end

    line.value:SetText(value or "")
    line.value:SetTextColor(Theme.Unpack(valueColor or "text"))
    local width = Theme.MeasureText and Theme.MeasureText("small", value or "")
    line.valueWidth = math.min(VALUE_MOST, math.max(VALUE_WIDTH, math.ceil(tonumber(width) or 0)))

    -- The name gets its room first, then is measured in it.
    PlaceLines(line.block)
    Theme.SetRowName(line.label, label)
    line.label:SetTextColor(Theme.Unpack(labelColor or "muted"))
    PlaceLines(line.block)
end

--- Buy: [-] [3] [+] writs. How many Search Both looks for, 1 to BUY_MOST.
local function CreateBuyBox(parent, onChange)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(DETAIL_WIDTH - 24, 22)

    local label = Theme.CreateLabel(holder, "small", "text")
    label:SetPoint("LEFT", 0, 0)
    label:SetText(L["Buy:"])

    local count, box = 1, nil
    local function Set(value)
        value = math.max(1, math.min(BUY_MOST, math.floor(tonumber(value) or 1)))
        if box then box:SetValue(value, true) end
        if value == count then return end
        count = value
        onChange(value)
    end

    holder.minus = Widgets.CreateButton(holder, "-", function() Set(count - 1) end, { width = 22, height = 20 })
    holder.minus:SetPoint("LEFT", label, "RIGHT", 8, 0)

    box = Widgets.CreateNumberBox(holder, {
        width = 36, height = 20, min = 1, max = BUY_MOST, justify = "CENTER",
        onChange = function(value) Set(value) end,
    })
    box:SetPoint("LEFT", holder.minus, "RIGHT", 4, 0)
    box:SetValue(1, true)
    holder.box = box

    holder.plus = Widgets.CreateButton(holder, "+", function() Set(count + 1) end, { width = 22, height = 20 })
    holder.plus:SetPoint("LEFT", box, "RIGHT", 4, 0)

    holder.word = Theme.CreateLabel(holder, "small", "muted")
    holder.word:SetPoint("LEFT", holder.plus, "RIGHT", 8, 0)

    local function Tip()
        GameTooltip:SetOwner(box, "ANCHOR_TOP")
        GameTooltip:AddLine(L["How many to buy. When you pick one in the auction house, its buy box fills in this many, and the same for what goes with it."],
            1, 1, 1, true)
        GameTooltip:Show()
    end
    for _, part in ipairs({ box, box.editBox }) do
        if part and part.HookScript then
            part:HookScript("OnEnter", Tip)
            part:HookScript("OnLeave", function() GameTooltip:Hide() end)
        end
    end

    function holder:SetWord(text) self.word:SetText(text) end
    return holder
end

local UpdateWrit

--- Size the scrolling part to what it holds now, and again a frame later
--- once the game has laid out text set this frame.
local function FitDetail()
    -- Read raw: the scroll is only there where the client can make one.
    local scroll = widgets.detail and rawget(widgets.detail, "scroll")
    if type(scroll) ~= "table" or type(scroll.FitContent) ~= "function" then return end
    scroll:FitContent(12)
    C_Timer.After(0, function() scroll:FitContent(12) end)
end

local function BuildDetail(parent)
    local detail = Theme.CreatePanel(parent, "window")
    detail:SetWidth(DETAIL_WIDTH)
    Theme.AccentStripe(detail, 2, 0.6)

    -- Everything above the foot scrolls, so a long note or a name that wraps
    -- never runs under the buttons or off the panel.
    local body = detail
    if Widgets.CreateScrollFrame then
        local scroll = Widgets.CreateScrollFrame(detail, { step = 40 })
        scroll:SetPoint("TOPLEFT", 0, -2)
        scroll:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -10, FOOT_HEIGHT)
        scroll.content:SetWidth(DETAIL_WIDTH - 10)
        detail.scroll = scroll
        body = scroll.content
    end
    local inset = body == detail and -12 or -4

    detail.title = Theme.CreateLabel(body, "large", "accent")
    detail.title:SetPoint("TOPLEFT", 12, -10)
    detail.title:SetPoint("TOPRIGHT", inset, -10)
    detail.title:SetWordWrap(true)

    detail.goal = Lines(body, 5)
    detail.goal:SetPoint("TOPLEFT", detail.title, "BOTTOMLEFT", 0, -10)
    detail.goal:SetPoint("RIGHT", body, "RIGHT", inset, 0)

    detail.routeHeading = Theme.CreateHeading(body, L["BUYING WRITS AND ITEMS"])
    detail.routeHeading:SetPoint("TOPLEFT", detail.goal, "BOTTOMLEFT", 0, -12)

    detail.route = Lines(body, 2)
    detail.route:SetPoint("TOPLEFT", detail.routeHeading, "BOTTOMLEFT", 0, -8)
    detail.route:SetPoint("RIGHT", body, "RIGHT", inset, 0)

    detail.writHeading = Theme.CreateHeading(body, L["PICK A WRIT"])
    detail.writHeading:SetPoint("TOPLEFT", detail.route, "BOTTOMLEFT", 0, -12)

    detail.writ = Lines(body, 4)
    detail.writ:SetPoint("TOPLEFT", detail.writHeading, "BOTTOMLEFT", 0, -8)
    detail.writ:SetPoint("RIGHT", body, "RIGHT", inset, 0)

    -- Shown only when the item is cheaper made than bought. As tall as its
    -- words or the button, whichever is taller, so the note sits under both.
    detail.makeRow = CreateFrame("Frame", nil, body)
    detail.makeRow:SetPoint("TOPLEFT", detail.writ, "BOTTOMLEFT", 0, -6)
    detail.makeRow:SetPoint("RIGHT", body, "RIGHT", inset, 0)
    detail.makeRow:SetHeight(22)

    detail.makeLine = Theme.CreateLabel(detail.makeRow, "small", "profit")
    detail.makeLine:SetPoint("TOPLEFT", 0, -2)
    detail.makeLine:SetPoint("RIGHT", detail.makeRow, "RIGHT", -104, 0)
    detail.makeLine:SetWordWrap(true)
    detail.makeLine:SetJustifyV("TOP")

    detail.queueButton = Widgets.CreateButton(detail.makeRow, L["Queue Craft"], function()
        QueueItem(state.selected)
    end, { width = 96, height = 20 })
    detail.queueButton:SetPoint("TOPRIGHT", 0, 0)

    detail.note = Theme.CreateLabel(body, "tiny", "dim")
    detail.note:SetPoint("TOPLEFT", detail.writ, "BOTTOMLEFT", 0, -10)
    detail.note:SetPoint("RIGHT", body, "RIGHT", inset, 0)
    detail.note:SetWordWrap(true)
    detail.note:SetJustifyV("TOP")

    detail.writButton = Widgets.CreateButton(detail, L["Search writ"], function()
        SearchWrit(state.selected)
    end, { width = 134, height = 22 })
    detail.writButton:SetPoint("BOTTOMLEFT", 12, 14)
    detail.writButton.tooltipText = L["Finds this writ on the auction house. You click Buy yourself."]

    detail.itemButton = Widgets.CreateButton(detail, L["Search item"], function()
        SearchItem(state.selected)
    end, { width = 134, height = 22 })
    detail.itemButton:SetPoint("LEFT", detail.writButton, "RIGHT", 8, 0)
    detail.itemButton.tooltipText = L["Finds the item the writ asks for on the auction house."]

    -- The writ and what it asks for in one search, the main thing here.
    detail.bothButton = Widgets.CreateButton(detail, L["Search Both"], function()
        SearchBoth(state.selected)
    end, { width = DETAIL_WIDTH - 24, primary = true, height = 24 })
    detail.bothButton:SetPoint("BOTTOMLEFT", 12, 44)

    detail.buyBox = CreateBuyBox(detail, function(value)
        state.buy = value
        UpdateWrit(state.selected)
    end)
    detail.buyBox:SetPoint("BOTTOMLEFT", 12, 76)

    detail:HookScript("OnShow", FitDetail)
    return detail
end

local function UpdateGoal(plan)
    local detail = widgets.detail
    local faction = plan.faction
    local lines = detail.goal.lines

    if not faction then
        detail.title:SetText(plan.goal.text)
        SetLine(lines[1], L["Writs pay reputation with your side's trade camp."], "")
        for index = 2, 5 do SetLine(lines[index], nil) end
        return
    end

    detail.title:SetText(L.Format("%s with %s", plan.goal.text, faction.name))

    if plan.standing then
        SetLine(lines[1], L.Format("Now (%s)", ns.Writs.StandingText(plan.standing)), tostring(plan.standing))
    else
        SetLine(lines[1], L["Your standing isn't known yet"], "?", "warn", "warn")
    end

    if plan.need == 0 then
        SetLine(lines[2], L["Goal reached"], "", "profit")
        for index = 3, 5 do SetLine(lines[index], nil) end
    else
        SetLine(lines[2], L["Still to go"], tostring(plan.need), "text", "accent")
        for tier = 1, 3 do
            local entry = plan.perTier[tier]
            if entry and entry.writs then
                local marked = entry.source == "reported" and "*" or ""
                SetLine(lines[tier + 2], L.Format("%s writs (%d each%s)", TierName(tier), entry.rep, marked),
                    tostring(entry.writs))
            else
                SetLine(lines[tier + 2], nil)
            end
        end
    end

    local route = detail.route.lines
    if plan.cheapest then
        local cheapest = plan.cheapest
        SetLine(route[1], L.Format("Cheapest: %d %s, one a day", cheapest.writs,
            Util.ColorItemName(cheapest.row.itemID, cheapest.row.name)),
            Plain(Round(cheapest.cost)), "text", "accent")
        local quickest = plan.quickest
        local text = quickest.days == 1 and L.Format("Quickest: %d writs over 1 day", quickest.writs)
            or L.Format("Quickest: %d writs over %d days", quickest.writs, quickest.days)
        SetLine(route[2], text, Plain(Round(quickest.cost)))
    elseif plan.need > 0 then
        SetLine(route[1], L["No writ is fully priced yet"], "")
        SetLine(route[2], nil)
    else
        SetLine(route[1], nil)
        SetLine(route[2], nil)
    end
    detail.routeHeading:SetShown(plan.need > 0)
    FitDetail()
end

function UpdateWrit(entry)
    local detail = widgets.detail
    local lines = detail.writ.lines

    detail.writButton:SetShown(entry ~= nil)
    detail.itemButton:SetShown(entry ~= nil)
    detail.bothButton:SetShown(entry ~= nil)
    detail.buyBox:SetShown(entry ~= nil)

    local made = entry and entry.how == "make" and entry.recipeID and entry.make and entry.buy
    detail.makeRow:SetShown(made and true or false)
    detail.makeLine:SetShown(made and true or false)
    detail.queueButton:SetShown(made and true or false)
    detail.note:ClearAllPoints()
    if made then
        detail.note:SetPoint("TOPLEFT", detail.makeRow, "BOTTOMLEFT", 0, -8)
    else
        detail.note:SetPoint("TOPLEFT", detail.writ, "BOTTOMLEFT", 0, -10)
    end
    detail.note:SetPoint("RIGHT", detail.makeRow, "RIGHT", 0, 0)
    if made then
        detail.makeLine:SetText(L.Format("Cheaper to make: %s made, %s bought.", Plain(entry.make), Plain(entry.buy)))
        detail.queueButton.tooltipText = L.Format("Adds %d %s to your craft queue.", entry.count * state.buy, entry.name)
        local ok, height = pcall(detail.makeLine.GetStringHeight, detail.makeLine)
        height = ok and tonumber(height) or 0
        detail.makeRow:SetHeight(math.max(22, math.ceil(height) + 4))
    end
    if entry then
        detail.buyBox:SetWord(state.buy == 1 and L["writ"] or L["writs"])
        detail.bothButton.tooltipText = BothTooltip(entry)
    end

    if not entry then
        detail.writHeading:SetText(L["PICK A WRIT"])
        SetLine(lines[1], L["Click a row to see how it adds up."], "")
        for index = 2, 4 do SetLine(lines[index], nil) end
    else
        detail.writHeading:SetText(("%s %s"):format(TierName(entry.tier), entry.prof):upper())
        SetLine(lines[1], L["Writ on the AH"], entry.writPrice and Plain(entry.writPrice)
            or (entry.noneListed and L["none listed"] or L["not priced"]))
        local named = Util.ColorItemName(entry.itemID, entry.name)
        local what = entry.count > 1 and ("%d %s"):format(entry.count, named) or named
        SetLine(lines[2], entry.how == "make" and L.Format("%s (made)", what) or what,
            entry.itemCost and Plain(entry.itemCost) or L["not priced"])
        SetLine(lines[3], L["Money back"], entry.money and entry.money > 0 and Plain(entry.money) or L["none known"])
        SetLine(lines[4], entry.rep and L.Format("Each of %d reputation", entry.rep) or L["Each reputation"],
            entry.perRep and Plain(Round(entry.perRep)) or L["not known"], "text", "accent")
    end

    local parts = {}
    if entry then
        parts[#parts + 1] = RewardText(entry)
        if entry.how == "make" and entry.buy and not made then
            parts[#parts + 1] = L.Format("Bought, it would be %s.", Plain(entry.buy))
        end
        if entry.haveWrits > 0 then
            parts[#parts + 1] = L.Format("You have %d of these writs.", entry.haveWrits)
        end
        if not entry.writID then
            parts[#parts + 1] = L["This writ has not been seen in the game yet, so it has no auction house price."]
        end
    else
        parts[#parts + 1] = L["* From guides, until you turn one in."]
    end
    parts[#parts + 1] = L["Each order can be done once a day. The coin pouch a turn-in gives is not counted."]
    detail.note:SetText(table.concat(parts, " "))
    FitDetail()
end

--------------------------------------------------------------------------------
-- List
--------------------------------------------------------------------------------

local function CountText(rows)
    local priced, cheapest = 0, nil
    for _, row in ipairs(rows) do
        if row.perRep then
            priced = priced + 1
            if not cheapest or row.perRep < cheapest.perRep then cheapest = row end
        end
    end

    if not cheapest then
        if (ns.Prices and ns.Prices:Count() or 0) == 0 then
            return { L["Scan the auction house to price the writs and what they ask for."] }
        end
        return { L["No writ is fully priced yet. Scan again once some are listed."] }
    end

    local money = Util.FormatMoney(Round(cheapest.perRep), { noColor = true, short = true })
    if priced == 1 then
        return {
            L.Format("%d writ priced, cheapest reputation %s each (%s)", priced, money, cheapest.name),
            L.Format("%d writ priced, cheapest reputation %s", priced, money),
            L.Format("%d writ priced", priced),
        }
    end
    return {
        L.Format("%d writs priced, cheapest reputation %s each (%s)", priced, money, cheapest.name),
        L.Format("%d writs priced, cheapest reputation %s", priced, money),
        L.Format("%d writs priced", priced),
    }
end

local function Matches(row, needle)
    return row.name:lower():find(needle, 1, true) or row.prof:lower():find(needle, 1, true)
        or TierName(row.tier):lower():find(needle, 1, true)
end

function DealsWrits:Refresh()
    if not widgets.list then return end

    local all = ns.Writs:GetRows()
    local rows = all

    if state.search ~= "" then
        local needle = state.search:lower()
        rows = {}
        for _, row in ipairs(all) do
            if Matches(row, needle) then rows[#rows + 1] = row end
        end
    end

    if widgets.sorter then rows = widgets.sorter:Sort(rows) end
    widgets.list:SetData(rows)

    widgets.emptyLabel:SetShown(#rows == 0)
    if #rows == 0 then widgets.emptyLabel:SetText(L.Format("No writ matching \"%s\".", state.search)) end

    local texts = CountText(rows)
    if Theme.FitText then Theme.FitText(widgets.countLabel, texts) else widgets.countLabel:SetText(texts[1]) end

    -- The goal is worked out over every writ, whatever the search shows.
    UpdateGoal(ns.Writs:GetPlan(DealsWrits:GetGoal(), all))

    local fresh
    for _, row in ipairs(rows) do
        if SameRow(row, state.selected) then fresh = row break end
    end
    state.selected = fresh
    UpdateWrit(fresh)
end

function DealsWrits:SetSearch(text)
    state.search = text or ""
end

function DealsWrits:SetGoal(key)
    state.goal = ns.Writs.GoalFor(key).key
end

function DealsWrits:GetGoal()
    if state.goal == nil then
        state.goal = ns.Writs.GoalFor(ns.Config:Get("writGoal")).key
    end
    return state.goal
end

function DealsWrits:ScrollToTop()
    if widgets.list then widgets.list:ScrollToTop() end
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

--- Lay the view out in `view`, under the tab's option bar `toolbar`.
function DealsWrits:Build(view, toolbar)
    -- A price cheaper made has a green Make before it, so its column is
    -- measured to hold both, not just the price.
    for _, column in ipairs(COLUMNS) do
        if column.key == "itemCost" and Widgets.MONEY_SAMPLE and ns.COLORS then
            column.sample = L.Format("|c%sMake|r  %s", ns.COLORS.profit, Widgets.MONEY_SAMPLE)
        end
    end
    if Widgets.FitColumns then Widgets.FitColumns(COLUMNS) end

    local headings = CreateFrame("Frame", nil, view)
    headings:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -8)
    headings:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", -DETAIL_WIDTH - 8, -8)
    headings:SetHeight(16)

    local nameHeading = Theme.CreateLabel(headings, "tiny", "muted")
    nameHeading:SetPoint("LEFT", 8 + ICON_GUTTER, 0)
    nameHeading:SetText(L["WRIT ASKS FOR"])

    local labels = { name = nameHeading }
    local values = { name = function(row) return row.name end }
    local cells = {}
    for index, column in ipairs(COLUMNS) do
        local heading = Theme.CreateLabel(headings, "tiny", "muted", "RIGHT")
        heading:SetText(column.label)
        heading:SetJustifyH(column.justify or "RIGHT")
        labels[index] = heading
        cells[index] = heading
        values[index] = function(row) return row[column.key] end
    end
    ns.Columns:Place("writs", COLUMNS, cells, { byIndex = true })

    -- Click a heading to sort by it; until then, cheapest reputation first.
    widgets.sorter = Widgets.SortableHeadings and Widgets.SortableHeadings(labels, values,
        function() DealsWrits:Refresh() end)
    if widgets.sorter then widgets.sorter:SetText({ "name" }) end

    -- Right-click the headings to choose the columns.
    ns.Columns:Attach(headings, "writs", widgets.sorter)
    ns.Columns:OnChange("writs", function()
        ns.Columns:Place("writs", COLUMNS, cells, { byIndex = true })
        if widgets.sorter then widgets.sorter:Sync() end
        if widgets.list then widgets.list:Refresh() end
    end)

    local divider = Theme.CreateDivider(view, "borderLit")
    divider:SetPoint("TOPLEFT", headings, "BOTTOMLEFT", 0, -2)
    divider:SetPoint("TOPRIGHT", headings, "BOTTOMRIGHT", 0, -2)

    local list = Widgets.CreateScrollList(view, {
        onScrollbarShown = function(shown)
            headings:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", -DETAIL_WIDTH - 8 - (shown and 10 or 0), -8)
        end,
        rowHeight = ROW_HEIGHT,
        createRow = CreateRow,
        updateRow = UpdateRow,
        onEnter = function(row, entry) ShowRowTooltip(row, entry) end,
        onLeave = function() GameTooltip:Hide() end,
        isSelected = function(entry) return SameRow(entry, state.selected) end,
        onClick = function(entry, _, mouseButton)
            state.selected = entry
            UpdateWrit(entry)
            if mouseButton == "RightButton" then SearchBoth(entry) end
        end,
    })
    list:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -4)
    list:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -DETAIL_WIDTH - 16, 24)
    widgets.list = list

    local emptyLabel = Theme.CreateLabel(view, "small", "dim", "CENTER")
    emptyLabel:SetPoint("CENTER", list, "CENTER", 0, 10)
    emptyLabel:SetWidth(380)
    emptyLabel:SetWordWrap(true)
    widgets.emptyLabel = emptyLabel
    if Widgets.DressEmpty then Widgets.DressEmpty(emptyLabel) end

    local hint = Theme.CreateLabel(view, "tiny", "dim", "RIGHT")
    hint:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -DETAIL_WIDTH - 16, 8)
    hint:SetText(L["Right-click a row to search for both"])

    local countLabel = Theme.CreateLabel(view, "tiny", "dim")
    countLabel:SetPoint("BOTTOMLEFT", 8, 8)
    countLabel:SetPoint("RIGHT", hint, "LEFT", -12, 0)
    countLabel:SetJustifyH("LEFT")
    countLabel:SetWordWrap(false)
    widgets.countLabel = countLabel

    local detail = BuildDetail(view)
    detail:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -8)
    detail:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -8, 8)
    widgets.detail = detail

    -- Writs and items the client had not cached arrive a few at a time,
    -- and a turn-in moves the standing; one redraw for a burst.
    local queued = false
    local function Soon()
        if queued or not list:IsVisible() then return end
        queued = true
        C_Timer.After(1, function()
            queued = false
            if list:IsVisible() then DealsWrits:Refresh() end
        end)
    end
    ns.RegisterEvent(widgets, "GET_ITEM_INFO_RECEIVED", Soon)
    ns.RegisterEvent(widgets, "UPDATE_FACTION", Soon)

    ns.Writs:FindWrits()
end
