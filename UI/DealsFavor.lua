-- Blackthornes Tradeskills -- UI/DealsFavor.lua
-- The Deals tab's Merchant's Favor view: Waylaid Crates by what a favor costs.
--
-- A player's idea (2026-10-08), from their spreadsheet. Each row is a crate:
-- what it costs on the auction house, its cheapest bundle, the silver its
-- turn-in pays back, and what that makes one point of Merchant's Favor
-- cost. The sums are Logic/MerchantsFavor.lua. Tab_Deals.lua shows this in
-- place of its flips when its Show menu says so, and owns the option bar.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local DealsFavor = ns.NewModule("DealsFavor")

local ROW_HEIGHT = 22
local DETAIL_WIDTH = 300
local ICON_GUTTER = 20
local BUNDLE_LINES = 5
-- The Buy box goes from 1 to this many crates.
local BUY_MOST = 99

-- Columns, laid out right to left, as on the flips list.
local COLUMNS = {
    { key = "perFavor",   label = L["PER FAVOR"], width = 70, money = true },
    { key = "total",      label = L["TOTAL"], width = 66, money = true },
    { key = "bundleCost", label = L["BUNDLE"], width = 96, money = true },
    { key = "cratePrice", label = L["CRATE"], width = 66, money = true },
    { key = "favor",      label = L["FAVOR"], width = 44, justify = "CENTER" },
    -- How many are on the auction house at the row's price (a player
    -- asked, 2026-10-19; it was what you own before).
    { key = "onAH",       label = L["ON AH"], width = 44, justify = "CENTER" },
}

-- Any column but the crate's name can be hidden (UI/Columns.lua).
ns.Columns:Register("favor", L["Deals: Merchant's Favor"], COLUMNS)

local state = {
    search = "",
    skipOverStack = nil,    -- read from Settings the first time it is asked
    selected = nil,
    buy = 1,                -- the Buy box, for this session only
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

--- A whole copper, for a favor's share of a crate.
local function Round(value)
    return value and math.floor(value + 0.5) or nil
end

--- The item's plain name, or "item N" until the client has it.
local function ItemName(itemID)
    if Util.HasFunction("C_Item.GetItemInfo") then
        local ok, name = pcall(C_Item.GetItemInfo, itemID)
        if ok and type(name) == "string" then return name end
        if Util.HasFunction("C_Item.RequestLoadItemDataByID") then
            pcall(C_Item.RequestLoadItemDataByID, itemID)
        end
    end
    return L.Format("item %s", tostring(itemID))
end

local function BundleText(bundle)
    return ("%d %s"):format(bundle.count, Util.ColorItemName(bundle.itemID, ItemName(bundle.itemID)))
end

--- Where the reward came from, in a few words.
local function RewardText(row)
    if row.source == "learned" then
        if row.turnIns == 1 then
            return L.Format("Pays %d favor and %s, seen on one turn-in.", row.favor, Plain(row.money or 0))
        end
        return L.Format("Pays %d favor and %s, seen on %d turn-ins.", row.favor, Plain(row.money or 0), row.turnIns or 1)
    elseif row.source == "reported" then
        return L.Format("Players report %d favor and %s. Not seen on a turn-in here yet.", row.favor, Plain(row.money or 0))
    end
    return L["Nobody knows what this crate pays yet."]
end

local function SameRow(a, b)
    return a and b and a.key == b.key
end

--- Send a search for one item, so it shows in the auction house list.
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
        if what == "crate" then
            ns.Print(L["The game hasn't shown this crate to the addon yet, so type its name into the auction house search box."])
        else
            ns.Print(L["The game hasn't shown this material to the addon yet, so type its name into the auction house search box."])
        end
        return
    end
    ns.UI:SearchAuctionHouse(itemID)
end

local function SearchCrate(row)
    if not row then return end
    Search(row.itemID, "crate")
end

--- What Search Both looks for: the crate, then the cheapest bundle, or
--- the materials to make it when that is cheaper.
-- @return items, reagents (nil unless made)
local function BothItems(row, buy)
    local items = { { itemID = row.itemID, count = buy } }
    local best = row.best
    if not best then return items end

    if best.made then
        local _, reagents = ns.MerchantsFavor.CraftPlan(best.recipeID, best.count * buy)
        if reagents and #reagents > 0 then
            for _, reagent in ipairs(reagents) do items[#items + 1] = reagent end
            return items, reagents
        end
    end
    items[#items + 1] = { itemID = best.itemID, count = best.count * buy }
    return items
end

--- The crate and what fills it, in one search (a player asked, 2026-10-18).
local function SearchBoth(row)
    if not row then return end
    local scanner = ns.Scanner
    if not row.itemID or not row.best or not scanner or not scanner.isAuctionHouseOpen or scanner.isScanning then
        return Search(row.itemID, "crate")
    end
    local items, reagents = BothItems(row, state.buy)
    local second = reagents and ns.MerchantsFavor.NamesOf(reagents) or ItemName(row.best.itemID)
    ns.MerchantsFavor:SearchBoth(items, row.name, second)
end

local function BothTooltip(row)
    if not row or not row.best then return L["Finds this crate on the auction house. You click Buy yourself."] end
    local buy = state.buy
    local _, reagents = BothItems(row, buy)
    if reagents then
        return L.Format("Finds %d of this crate and the %s to make %d bundles. You click Buy yourself.",
            buy, ns.MerchantsFavor.NamesOf(reagents), buy)
    end
    return L.Format("Finds %d of this crate and %d of its cheapest bundle. You click Buy yourself.", buy, buy)
end

--- Queue the crafts that make the cheapest bundle, times the Buy box.
local function QueueBundle(row)
    local best = row and row.best
    if not (best and best.made and best.recipeID) then return end
    ns.MerchantsFavor:QueueCraft(best.recipeID, best.count * state.buy, ItemName(best.itemID))
end

local function SearchBundle(row)
    if not row or not row.best then return end
    Search(row.best.itemID, "material")
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

--- The shown columns from the right edge; the name has the rest.
local function PlaceRow(row)
    local offset = ns.Columns:Place("favor", COLUMNS, row.cells, { byIndex = true })
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
        if column.key == "bundleCost" then
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
    if key == "favor" then
        cell:SetText(entry.favor and tostring(entry.favor) or "?")
        cell:SetTextColor(Theme.Unpack(entry.source == "learned" and "text"
            or entry.source == "reported" and "muted" or "warn"))
        return
    end

    local value = entry[key]
    if key == "perFavor" then value = Round(value) end
    local text = value and Money(value) or ""
    cell:SetText(text)
    cell:SetTextColor(Theme.Unpack(key == "perFavor" and "accent" or key == "total" and "text" or "muted"))
end

local SlideRow

local function UpdateRow(row, entry)
    if row.columnsVersion ~= ns.Columns.version then PlaceRow(row) end

    Theme.SetRowName(row.name, entry.name)
    Theme.SetItemIcon(row.icon, entry.itemID or (entry.best and entry.best.itemID))
    -- In its rarity colour, faded while it has no price.
    local r, g, b = Util.GetItemQualityColor(entry.itemID)
    if r then
        row.name:SetTextColor(r, g, b, entry.perFavor and 1 or 0.55)
    else
        row.name:SetTextColor(Theme.Unpack(entry.perFavor and "text" or "dim"))
    end

    for index, column in ipairs(COLUMNS) do
        FillCell(row.cells[index], column.key, entry)
    end
    if row.make then
        local shown = row.makeCell and (not row.makeCell.IsShown or row.makeCell:IsShown() ~= false)
        row.make:SetShown((shown and entry.bundleCost and entry.best and entry.best.made) and true or false)
    end

    local moved = state.slides and entry.key and state.slides[entry.key]
    if moved then
        state.slides[entry.key] = nil
        SlideRow(row, moved)
    end
end

local function ShowRowTooltip(row, entry)
    if entry.itemID then
        Widgets.ShowItemTooltip(row, "ANCHOR_LEFT", entry.itemID, entry.name)
    else
        GameTooltip:SetOwner(row, "ANCHOR_LEFT")
        GameTooltip:AddLine(L.Format("Waylaid Crate: %s", entry.name))
    end

    GameTooltip:AddLine(" ")
    if entry.total and entry.best then
        GameTooltip:AddLine(L.Format("Crate %s + %s %s - %s back = %s.",
            Plain(entry.cratePrice), BundleText(entry.best), Plain(entry.best.cost),
            Plain(entry.money or 0), Plain(entry.total)), 0.85, 0.85, 0.85, true)
    end
    if entry.perFavor then
        GameTooltip:AddLine(L.Format("%s for each favor.", Plain(Round(entry.perFavor))), 0.35, 0.85, 0.45, true)
    end
    GameTooltip:AddLine(RewardText(entry), 0.7, 0.7, 0.7, true)
    if entry.onAHAtPrice then
        GameTooltip:AddLine(L.Format("On the AH at this price: %d", entry.onAHAtPrice), 0.85, 0.85, 0.85)
    end
    if entry.onAHTotal then
        GameTooltip:AddLine(L.Format("On the AH in all: %d", entry.onAHTotal), 0.85, 0.85, 0.85)
    end
    GameTooltip:AddLine(L.Format("You have %d, counting your bags, bank and mail.", entry.have or 0), 0.85, 0.85, 0.85)
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

    -- The name gets its room first, then is measured in it. A long material
    -- name ("16 Handful of Copper Bolts") goes smaller rather than ending
    -- in "...".
    PlaceLines(line.block)
    Theme.SetRowName(line.label, label)
    line.label:SetTextColor(Theme.Unpack(labelColor or "muted"))
    PlaceLines(line.block)
end

--- Buy: [-] [3] [+] crates. How many Search Both looks for, 1 to BUY_MOST.
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

local UpdateDetail

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

    detail.icon = Theme.CreateItemIcon(body, 30)
    detail.icon:SetPoint("TOPLEFT", 12, -10)
    if Widgets.ItemHotspot then Widgets.ItemHotspot(detail.icon) end

    detail.title = Theme.CreateLabel(body, "large", "accent")
    detail.title:SetPoint("TOPLEFT", 50, -10)
    detail.title:SetPoint("TOPRIGHT", inset, -10)
    detail.title:SetWordWrap(true)

    detail.subtitle = Theme.CreateLabel(body, "small", "muted")
    detail.subtitle:SetPoint("TOPLEFT", detail.title, "BOTTOMLEFT", 0, -4)
    detail.subtitle:SetPoint("RIGHT", body, "RIGHT", inset, 0)
    detail.subtitle:SetWordWrap(true)

    detail.bundleHeading = Theme.CreateHeading(body, L["FILL IT WITH ONE OF"])
    detail.bundleHeading:SetPoint("TOPLEFT", detail.subtitle, "BOTTOMLEFT", -38, -12)

    detail.bundles = Lines(body, BUNDLE_LINES)
    detail.bundles:SetPoint("TOPLEFT", detail.bundleHeading, "BOTTOMLEFT", 0, -8)
    detail.bundles:SetPoint("RIGHT", body, "RIGHT", inset, 0)

    -- Shown only when the cheapest bundle is cheaper made than bought. As
    -- tall as its words or the button, whichever is taller.
    detail.makeRow = CreateFrame("Frame", nil, body)
    detail.makeRow:SetPoint("TOPLEFT", detail.bundles, "BOTTOMLEFT", 0, -6)
    detail.makeRow:SetPoint("RIGHT", body, "RIGHT", inset, 0)
    detail.makeRow:SetHeight(22)

    detail.makeLine = Theme.CreateLabel(detail.makeRow, "small", "profit")
    detail.makeLine:SetPoint("TOPLEFT", 0, -2)
    detail.makeLine:SetPoint("RIGHT", detail.makeRow, "RIGHT", -104, 0)
    detail.makeLine:SetWordWrap(true)
    detail.makeLine:SetJustifyV("TOP")

    detail.queueButton = Widgets.CreateButton(detail.makeRow, L["Queue Craft"], function()
        QueueBundle(state.selected)
    end, { width = 96, height = 20 })
    detail.queueButton:SetPoint("TOPRIGHT", 0, 0)

    detail.costHeading = Theme.CreateHeading(body, L["ONE FAVOR"])
    detail.costHeading:SetPoint("TOPLEFT", detail.bundles, "BOTTOMLEFT", 0, -12)

    detail.sums = Lines(body, 4)
    detail.sums:SetPoint("TOPLEFT", detail.costHeading, "BOTTOMLEFT", 0, -8)
    detail.sums:SetPoint("RIGHT", body, "RIGHT", inset, 0)

    detail.note = Theme.CreateLabel(body, "tiny", "dim")
    detail.note:SetPoint("TOPLEFT", detail.sums, "BOTTOMLEFT", 0, -10)
    detail.note:SetPoint("RIGHT", body, "RIGHT", inset, 0)
    detail.note:SetWordWrap(true)
    detail.note:SetJustifyV("TOP")

    detail.crateButton = Widgets.CreateButton(detail, L["Search crate"], function()
        SearchCrate(state.selected)
    end, { width = 134, height = 22 })
    detail.crateButton:SetPoint("BOTTOMLEFT", 12, 14)
    detail.crateButton.tooltipText = L["Finds this crate on the auction house. You click Buy yourself."]

    detail.bundleButton = Widgets.CreateButton(detail, L["Search bundle"], function()
        SearchBundle(state.selected)
    end, { width = 134, height = 22 })
    detail.bundleButton:SetPoint("LEFT", detail.crateButton, "RIGHT", 8, 0)
    detail.bundleButton.tooltipText = L["Finds the cheapest bundle's material on the auction house."]

    -- The crate and what fills it in one search, the main thing here.
    detail.bothButton = Widgets.CreateButton(detail, L["Search Both"], function()
        SearchBoth(state.selected)
    end, { width = DETAIL_WIDTH - 24, primary = true, height = 24 })
    detail.bothButton:SetPoint("BOTTOMLEFT", 12, 44)

    detail.buyBox = CreateBuyBox(detail, function(value)
        state.buy = value
        UpdateDetail(state.selected)
    end)
    detail.buyBox:SetPoint("BOTTOMLEFT", 12, 76)

    detail.empty = Theme.CreateLabel(detail, "small", "dim", "CENTER")
    detail.empty:SetPoint("CENTER")
    detail.empty:SetWidth(DETAIL_WIDTH - 40)
    detail.empty:SetWordWrap(true)
    detail.empty:SetText(L["Pick a crate to see what fills it and what a favor costs."])

    detail:HookScript("OnShow", FitDetail)
    return detail
end

function UpdateDetail(entry)
    local detail = widgets.detail
    local shown = entry ~= nil

    detail.empty:SetShown(not shown)
    local made = shown and entry.best and entry.best.made and entry.best.make and entry.best.buy
    detail.makeRow:SetShown(made and true or false)
    detail.makeLine:SetShown(made and true or false)
    detail.queueButton:SetShown(made and true or false)
    for _, part in ipairs({ detail.icon, detail.title, detail.subtitle, detail.bundleHeading, detail.bundles,
            detail.costHeading, detail.sums, detail.note, detail.crateButton, detail.bundleButton,
            detail.bothButton, detail.buyBox }) do
        part:SetShown(shown)
    end
    local scroll = rawget(detail, "scroll")
    if type(scroll) == "table" then
        scroll:SetShown(shown)
        -- The bar hangs off the panel, not the scroll frame, so it goes too.
        if not shown and scroll.scrollbar then scroll.scrollbar:Hide() end
    end
    if not shown then return end

    detail.title:SetText(entry.name)
    Theme.SetItemNameColor(detail.title, entry.itemID, "accent")
    Theme.SetItemIcon(detail.icon, entry.itemID or (entry.best and entry.best.itemID))
    detail.subtitle:SetText(RewardText(entry))
    detail.subtitle:SetTextColor(Theme.Unpack(entry.source == "learned" and "text"
        or entry.source == "reported" and "muted" or "warn"))

    local overStack = false
    for index = 1, BUNDLE_LINES do
        local bundle = entry.bundles[index]
        local line = detail.bundles.lines[index]
        if bundle then
            local label = BundleText(bundle)
            local labelColor, valueColor = "muted", "muted"
            if bundle.best then
                labelColor, valueColor = "text", "profit"
            elseif bundle.overStack then
                labelColor, valueColor = "dim", "dim"
            end
            if bundle.made then
                label = L.Format("%s (make)", label)
            elseif bundle.vendor then
                label = L.Format("%s (vendor)", label)
            end
            if bundle.overStack then
                label = label .. " *"
                overStack = true
            end
            SetLine(line, label, bundle.cost and Plain(bundle.cost) or L["not priced"], labelColor, valueColor)
        else
            SetLine(line, nil)
        end
    end

    -- Room for the make line only when it shows.
    detail.costHeading:ClearAllPoints()
    if made then
        local best = entry.best
        detail.makeLine:SetText(L.Format("Cheaper to make: %s made, %s bought.", Plain(best.make), Plain(best.buy)))
        detail.queueButton.tooltipText = L.Format("Adds %d bundles of %s to your craft queue.", state.buy,
            ItemName(best.itemID))
        local ok, height = pcall(detail.makeLine.GetStringHeight, detail.makeLine)
        height = ok and tonumber(height) or 0
        detail.makeRow:SetHeight(math.max(22, math.ceil(height) + 4))
        detail.costHeading:SetPoint("TOPLEFT", detail.makeRow, "BOTTOMLEFT", 0, -12)
    else
        detail.costHeading:SetPoint("TOPLEFT", detail.bundles, "BOTTOMLEFT", 0, -12)
    end

    detail.buyBox:SetWord(state.buy == 1 and L["crate"] or L["crates"])
    detail.bothButton.tooltipText = BothTooltip(entry)

    local sums = detail.sums.lines
    SetLine(sums[1], L["Crate on the AH"], entry.cratePrice and Plain(entry.cratePrice)
        or (entry.noneListed and L["none listed"] or L["not priced"]))
    SetLine(sums[2], L["Cheapest bundle"], entry.bundleCost and Plain(entry.bundleCost) or L["not priced"])
    SetLine(sums[3], L["Silver back"], entry.money and Plain(entry.money) or L["not known"])
    SetLine(sums[4], entry.favor and L.Format("Each of %d favor", entry.favor) or L["Each favor"],
        entry.perFavor and Plain(Round(entry.perFavor)) or L["not known"], "text", "accent")

    local parts = {}
    if overStack then
        parts[#parts + 1] = DealsFavor:GetSkipOverStack()
            and L["* Needs more than one stack, so it's left out."]
            or L["* Needs more than one stack. That may not work."]
    end
    if entry.have > 0 then
        parts[#parts + 1] = L.Format("You have %d of these crates.", entry.have)
    end
    if not entry.itemID then
        parts[#parts + 1] = L["No auction house price yet."]
    end
    parts[#parts + 1] = L["Prices are the cheapest listings from your last scan, or a vendor's where one sells it."]
    detail.note:SetText(table.concat(parts, " "))
    FitDetail()
end

--------------------------------------------------------------------------------
-- The favor goal (the owner said build it, 2026-10-20, from a mockup)
--------------------------------------------------------------------------------

-- The strip under the list: the heading and box, the bar, two columns of
-- lines.
local GOAL_HEIGHT = 92
local GOAL_LINE = 15
-- How long the gold takes to count to a new total, and a row to slide to
-- its new place, with Window effects on Full.
local COUNT_SECONDS = 0.9
local SLIDE_SECONDS = 0.35

local function MotionFull()
    local motion = ns.Motion
    local ok, level = pcall(function() return motion and motion.Level and motion.Level() end)
    return not ok or level == nil or level == "full"
end

local function FavorText(amount)
    return L.Format("%d favor", amount)
end

local function CratesText(count)
    if count == 1 then return L["1 crate"] end
    return L.Format("%d crates", count)
end

--- Count the gold line from what it showed to `value`, or set it at once.
--- The count runs on the strip's own frame: a font string has no scripts,
--- and calling SetScript on one stopped the whole window being built.
local function CountGold(value)
    local goal = widgets.goal
    if not goal then return end
    local label = goal.gold
    goal.goldTarget = value

    if not value then
        goal.goldShown = nil
        goal:SetScript("OnUpdate", nil)
        label:SetText("--")
        label:SetTextColor(Theme.Unpack("dim"))
        return
    end
    label:SetTextColor(Theme.Unpack("text"))

    local from = goal.goldShown
    if not from or from == value or not MotionFull() or not label:IsVisible() then
        goal.goldShown = value
        goal:SetScript("OnUpdate", nil)
        label:SetText(Money(value))
        return
    end

    local started = GetTime()
    goal:SetScript("OnUpdate", function(self)
        local k = math.min(1, (GetTime() - started) / COUNT_SECONDS)
        local eased = 1 - (1 - k) ^ 3
        goal.goldShown = math.floor(from + (value - from) * eased + 0.5)
        label:SetText(Money(goal.goldShown))
        if k >= 1 then self:SetScript("OnUpdate", nil) end
    end)
end

local function GoalLine(parent, labelText)
    local label = Theme.CreateLabel(parent, "small", "muted")
    label:SetText(labelText)
    local value = Theme.CreateLabel(parent, "small", "text", "RIGHT")
    return { label = label, value = value }
end

local function BuildGoal(view)
    local goal = CreateFrame("Frame", nil, view)
    goal:SetHeight(GOAL_HEIGHT)
    widgets.goal = goal

    local heading = Theme.CreateHeading(goal, L["YOUR FAVOR GOAL"])
    heading:SetPoint("TOPLEFT", 8, -4)

    goal.addList = Widgets.CreateButton(goal, L["Add to List"], function()
        local index, why = ns.MerchantsFavor:AddToList()
        if not index then
            if why then ns.Print(why) end
            return
        end
        local name = L["Merchant's Favor"]
        ns.Print(L.Format("Your %s shopping list has what your goal needs.", name))
    end, { height = 20 })
    goal.addList:SetPoint("TOPRIGHT", goal, "TOPRIGHT", -4, 0)

    goal.box = Widgets.CreateNumberBox(goal, {
        width = 70, height = 20, min = 1, max = 999999, allowEmpty = true, justify = "CENTER",
        onChange = function(value)
            ns.MerchantsFavor:SetGoal(value)
            DealsFavor:Refresh()
            if ns.PostPanel and ns.PostPanel.Refresh then pcall(ns.PostPanel.Refresh, ns.PostPanel) end
        end,
    })
    goal.box:SetPoint("RIGHT", goal.addList, "LEFT", -12, 0)

    local boxLabel = Theme.CreateLabel(goal, "small", "text")
    boxLabel:SetPoint("RIGHT", goal.box, "LEFT", -6, 0)
    boxLabel:SetText(L["Favor Goal:"])
    -- The heading's rule stops short of the box.
    local rule = type(heading) == "table" and rawget(heading, "rule")
    if type(rule) == "table" then
        rule:ClearAllPoints()
        rule:SetPoint("LEFT", heading, "RIGHT", 6, 0)
        rule:SetPoint("RIGHT", boxLabel, "LEFT", -10, 0)
    end

    -- The bar: dark glass, a gold fill and a tick at each tenth.
    local bar = CreateFrame("Frame", nil, goal)
    bar:SetHeight(10)
    bar:SetPoint("TOPLEFT", goal, "TOPLEFT", 8, -30)
    bar:SetPoint("TOPRIGHT", goal, "TOPRIGHT", -4, -30)
    local back = bar:CreateTexture(nil, "BACKGROUND")
    back:SetAllPoints()
    back:SetColorTexture(Theme.Unpack("glassAlt"))
    local edge = bar:CreateTexture(nil, "BORDER")
    edge:SetPoint("BOTTOMLEFT")
    edge:SetPoint("BOTTOMRIGHT")
    edge:SetHeight(1)
    edge:SetColorTexture(Theme.Unpack("border", 0.6))
    local fill = bar:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT")
    fill:SetPoint("BOTTOMLEFT")
    fill:SetWidth(1)
    fill:SetColorTexture(Theme.Unpack("accent"))
    bar.fill = fill
    bar.ticks = {}
    for i = 1, 9 do
        local tick = bar:CreateTexture(nil, "OVERLAY")
        tick:SetSize(1, 10)
        tick:SetColorTexture(Theme.Unpack("ink", 0.7))
        bar.ticks[i] = tick
    end
    bar:SetScript("OnSizeChanged", function(self, width)
        width = tonumber(width) or self:GetWidth() or 0
        for i, tick in ipairs(self.ticks) do
            tick:ClearAllPoints()
            tick:SetPoint("LEFT", self, "LEFT", math.floor(width * i / 10), 0)
        end
        if self.share then self.fill:SetWidth(math.max(1, width * self.share)) end
        self.fill:SetShown((self.share or 0) > 0)
    end)
    goal.bar = bar

    -- Two columns of lines.
    goal.have = GoalLine(goal, L["You have"])
    goal.toGo = GoalLine(goal, L["Still to go"])
    goal.way = GoalLine(goal, L["Cheapest way"])
    goal.goldLine = GoalLine(goal, L["Gold to get there"])
    goal.gold = goal.goldLine.value

    local function Place(line, column, row)
        local y = -48 - (row - 1) * (GOAL_LINE + 4)
        line.label:ClearAllPoints()
        line.value:ClearAllPoints()
        if column == 1 then
            line.label:SetPoint("TOPLEFT", goal, "TOPLEFT", 8, y)
            line.value:SetPoint("TOPRIGHT", goal, "TOP", -10, y)
        else
            line.label:SetPoint("TOPLEFT", goal, "TOP", 10, y)
            line.value:SetPoint("TOPRIGHT", goal, "TOPRIGHT", -4, y)
        end
    end
    Place(goal.have, 1, 1)
    Place(goal.toGo, 1, 2)
    Place(goal.way, 2, 1)
    Place(goal.goldLine, 2, 2)

    return goal
end

local function SetBar(share)
    local bar = widgets.goal and widgets.goal.bar
    if not bar then return end
    bar.share = math.max(0, math.min(1, share or 0))
    local width = bar:GetWidth() or 0
    bar.fill:SetWidth(math.max(1, width * bar.share))
    bar.fill:SetShown(bar.share > 0)
    for i, tick in ipairs(bar.ticks) do
        tick:SetColorTexture(Theme.Unpack(i / 10 <= bar.share and "ink" or "border", 0.7))
    end
end

--- Fill the strip from the goal's plan.
local function UpdateGoal(rows)
    local goal = widgets.goal
    if not goal then return end

    local favor = ns.MerchantsFavor
    local target = favor.Goal()
    if not (goal.box.editBox and goal.box.editBox.HasFocus and goal.box.editBox:HasFocus()) then
        goal.box:SetValue(target, true)
    end

    local plan = target and favor:GetPlan(target, rows)
    local function Set(line, text, color)
        line.value:SetText(text or "--")
        line.value:SetTextColor(Theme.Unpack(text and (color or "text") or "dim"))
    end

    if not plan then
        Set(goal.have, favor:FavorHave() and FavorText(favor:FavorHave()))
        Set(goal.toGo, nil)
        Set(goal.way, nil)
        CountGold(nil)
        SetBar(0)
        goal.addList:Disable()
        return
    end

    Set(goal.have, plan.have and FavorText(plan.have))
    Set(goal.toGo, FavorText(plan.need), plan.need == 0 and "profit" or "accent")
    SetBar(plan.have and plan.have / plan.goal or 0)

    if plan.need == 0 then
        Set(goal.way, nil)
        CountGold(0)
        goal.addList:Disable()
        return
    end
    if plan.best and plan.crates then
        Set(goal.way, CratesText(plan.crates))
        CountGold(plan.gold)
        goal.addList:Enable()
    else
        Set(goal.way, nil)
        CountGold(nil)
        goal.addList:Disable()
    end
end

--------------------------------------------------------------------------------
-- Rows slide to their new place (with Window effects on Full)
--------------------------------------------------------------------------------

--- Slide a row from `rows` rows away to where it is drawn now.
function SlideRow(row, rows)
    if not (row.CreateAnimationGroup and rows and rows ~= 0) then return end
    if not row.slide then
        local group = row:CreateAnimationGroup()
        local jump = group:CreateAnimation("Translation")
        jump:SetOrder(1)
        jump:SetDuration(0.001)
        local back = group:CreateAnimation("Translation")
        back:SetOrder(2)
        back:SetDuration(SLIDE_SECONDS)
        if back.SetSmoothing then back:SetSmoothing("OUT") end
        row.slide = { group = group, jump = jump, back = back }
    end
    local dy = rows * ROW_HEIGHT
    row.slide.group:Stop()
    row.slide.jump:SetOffset(0, dy)
    row.slide.back:SetOffset(0, -dy)
    row.slide.group:Play()
end

--------------------------------------------------------------------------------
-- List
--------------------------------------------------------------------------------

local function CountText(rows)
    local priced, cheapest = 0, nil
    for _, row in ipairs(rows) do
        if row.perFavor then
            priced = priced + 1
            if not cheapest or row.perFavor < cheapest.perFavor then cheapest = row end
        end
    end

    if not cheapest then
        if (ns.Prices and ns.Prices:Count() or 0) == 0 then
            return { L["Scan the auction house to price the crates and their bundles."] }
        end
        return { L["No crate is fully priced yet. Scan again once some are listed."] }
    end

    local money = Util.FormatMoney(Round(cheapest.perFavor), { noColor = true, short = true })
    if priced == 1 then
        return {
            L.Format("%d crate priced, cheapest favor %s each (%s)", priced, money, cheapest.name),
            L.Format("%d crate priced, cheapest favor %s", priced, money),
            L.Format("%d crate priced", priced),
        }
    end
    return {
        L.Format("%d crates priced, cheapest favor %s each (%s)", priced, money, cheapest.name),
        L.Format("%d crates priced, cheapest favor %s", priced, money),
        L.Format("%d crates priced", priced),
    }
end

function DealsFavor:Refresh()
    if not widgets.list then return end

    local rows = ns.MerchantsFavor:GetRows({ skipOverStack = DealsFavor:GetSkipOverStack() })

    if state.search ~= "" then
        local needle = state.search:lower()
        local filtered = {}
        for _, row in ipairs(rows) do
            if row.name:lower():find(needle, 1, true) then filtered[#filtered + 1] = row end
        end
        rows = filtered
    end

    if widgets.sorter then rows = widgets.sorter:Sort(rows) end

    -- When the order moves (new prices, a heading clicked), each row slides
    -- from where it was to its new place. Not while the search changes.
    local places = {}
    for index, row in ipairs(rows) do places[row.key] = index end
    state.slides = nil
    if state.places and state.placesSearch == state.search and MotionFull() then
        for key, index in pairs(places) do
            local was = state.places[key]
            if was and was ~= index then
                state.slides = state.slides or {}
                state.slides[key] = index - was
            end
        end
    end
    state.places, state.placesSearch = places, state.search

    widgets.list:SetData(rows)
    UpdateGoal()

    widgets.emptyLabel:SetShown(#rows == 0)
    if #rows == 0 then widgets.emptyLabel:SetText(L.Format("No crate matching \"%s\".", state.search)) end

    local texts = CountText(rows)
    if Theme.FitText then Theme.FitText(widgets.countLabel, texts) else widgets.countLabel:SetText(texts[1]) end

    local fresh
    for _, row in ipairs(rows) do
        if SameRow(row, state.selected) then fresh = row break end
    end
    state.selected = fresh
    UpdateDetail(fresh)
end

function DealsFavor:SetSearch(text)
    state.search = text or ""
end

function DealsFavor:SetSkipOverStack(on)
    state.skipOverStack = on and true or false
end

function DealsFavor:GetSkipOverStack()
    if state.skipOverStack == nil then
        state.skipOverStack = ns.Config:Get("favorSkipOverStack") ~= false
    end
    return state.skipOverStack
end

function DealsFavor:ScrollToTop()
    if widgets.list then widgets.list:ScrollToTop() end
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

--- Lay the view out in `view`, under the tab's option bar `toolbar`.
function DealsFavor:Build(view, toolbar)
    -- A price cheaper made has a green Make before it, so its column is
    -- measured to hold both, not just the price.
    for _, column in ipairs(COLUMNS) do
        if column.key == "bundleCost" and Widgets.MONEY_SAMPLE and ns.COLORS then
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
    nameHeading:SetText(L["WAYLAID CRATE"])

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
    ns.Columns:Place("favor", COLUMNS, cells, { byIndex = true })

    -- Click a heading to sort by it; until then, cheapest favor first.
    widgets.sorter = Widgets.SortableHeadings and Widgets.SortableHeadings(labels, values,
        function() DealsFavor:Refresh() end)
    if widgets.sorter then widgets.sorter:SetText({ "name" }) end

    -- Right-click the headings to choose the columns.
    ns.Columns:Attach(headings, "favor", widgets.sorter)
    ns.Columns:OnChange("favor", function()
        ns.Columns:Place("favor", COLUMNS, cells, { byIndex = true })
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
            UpdateDetail(entry)
            if mouseButton == "RightButton" then SearchBoth(entry) end
        end,
    })
    list:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -4)
    list:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -DETAIL_WIDTH - 16, 24 + GOAL_HEIGHT + 6)
    widgets.list = list

    local goal = BuildGoal(view)
    goal:SetPoint("BOTTOMLEFT", view, "BOTTOMLEFT", 0, 26)
    goal:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -DETAIL_WIDTH - 16, 26)

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
    UpdateDetail(nil)

    -- Crates and materials the client had not cached arrive by name a few
    -- at a time; one redraw for a burst.
    local queued = false
    ns.RegisterEvent(widgets, "GET_ITEM_INFO_RECEIVED", function()
        if queued or not list:IsVisible() then return end
        queued = true
        C_Timer.After(1, function()
            queued = false
            if list:IsVisible() then DealsFavor:Refresh() end
        end)
    end)

    -- Favor, crates and bundles coming in move the goal; one redraw of the
    -- strip a burst, only while it shows.
    local goalQueued = false
    local function GoalSoon()
        if goalQueued or not goal:IsVisible() then return end
        goalQueued = true
        C_Timer.After(0.5, function()
            goalQueued = false
            if goal:IsVisible() then UpdateGoal() end
        end)
    end
    ns.RegisterEvent(goal, "BAG_UPDATE_DELAYED", GoalSoon)
    ns.RegisterEvent(goal, "CURRENCY_DISPLAY_UPDATE", GoalSoon)

    ns.MerchantsFavor:FindCrates()
end
