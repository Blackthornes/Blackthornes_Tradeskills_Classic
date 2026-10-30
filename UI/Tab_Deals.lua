-- Blackthornes Tradeskills -- UI/Tab_Deals.lua
-- Items on the auction house worth buying, and what to do with them.
--
-- The Vendor Flips tab grown (a player's idea, 2026-10-07). Every item someone
-- else has listed, priced at their cheapest listing from your last scan,
-- against the ways it can be sold on:
--
--   AH      list it again under its usual price (Logic/VendorFlips.lua,
--           A player's idea, 2026-10-06)
--   Vendor  sell it to any vendor for more than it cost (Logic/VendorFlips.lua)
--
-- The Sell to menu ticks which ways count. An item shows once, on the way
-- that pays most, and the VIA column says which. The detail pane says what
-- the other way would make. Buying to disenchant was here for a day and
-- went back to its own Disenchanting tab at the owner's ask (2026-10-08).
--
-- The Show menu swaps the list for the Merchant's Favor view
-- (UI/DealsFavor.lua, a player's idea, 2026-10-08): Waylaid Crates by what a
-- point of favor costs bought on the auction house. And for the Craftsman's
-- Writs view (UI/DealsWrits.lua, a player's idea, 2026-10-09): writs by what a
-- point of reputation costs, and what a reputation goal still costs.
--
-- The addon cannot buy for you: the game wants a real click on its own Buy
-- button for every purchase. What it can do is send the search, so the item
-- is in the auction house list ready to click.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local UI = ns.UI

local ROW_HEIGHT = 22
local DETAIL_WIDTH = 300
local ICON_GUTTER = 20

-- The ways to sell, in the Sell to menu's order, with the VIA column's word
-- for each. The same words as the Profit tab's VIA and the queue's marks.
local ROUTES = {
    { key = "auction",    via = L["AH"],     text = L["Auction house"] },
    { key = "vendor",     via = L["Vendor"], text = L["Vendor"] },
}

local VIA = {}
for _, route in ipairs(ROUTES) do VIA[route.key] = route.via end

-- Columns, laid out right to left, so VIA sits next to the item's name.
-- Money sits to the right, so its coins line up; the rest is centred under
-- its heading. `width` is the least each gets: Widgets.FitColumns widens it
-- to fit the heading and an amount.
local COLUMNS = {
    { key = "gain",   label = L["PROFIT"], width = 66, money = true },
    { key = "margin", label = L["MARGIN"], width = 50, justify = "CENTER" },
    { key = "gets",   label = L["GETS"], width = 70, money = true },
    { key = "buy",    label = L["BUY"], width = 66, money = true },
    -- How many were listed at the buy price or less in the last scan (the
    -- owner said yes, 2026-10-13), so one lonely cheap item reads apart
    -- from a real deal.
    { key = "qty",    label = L["QTY"], width = 36, justify = "CENTER" },
    { key = "age",    label = L["AGE"], width = 44, justify = "CENTER" },
    { key = "via",    label = L["VIA"], width = 44, justify = "CENTER" },
}

-- Any column but the name can be hidden (UI/Columns.lua).
ns.Columns:Register("deals", L["Deals"], COLUMNS)

-- The flips are put away for now (the owner, 2026-10-13: "get rid of Flips
-- under Deals for now"), so the tab is Favors and Writs. Their code, lists
-- and saved settings all stay; setting ns.DEALS_FLIPS before this file
-- loads brings them back as the first view (the tests do).
local SHOW_FLIPS = ns.DEALS_FLIPS == true
UI.DEALS_SHOW_FLIPS = SHOW_FLIPS

local state = {
    view = SHOW_FLIPS and "flips" or "favor",
    routes = { auction = true, vendor = true },
    search = "",
    dealsOnly = true,
    -- Only deals first seen in the latest scan (VendorFlips:NoteSeen).
    newOnly = false,
    selected = nil,
    hidden = 0,
    pending = 0,
    thin = 0,
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

local function MarginText(margin)
    return ("%d%%"):format(math.floor((margin or 0) * 100))
end

--- The row's rarity, from the item facts kept in the saved data, or nil.
local function KnownQuality(entry)
    local facts = entry.breakdown and entry.breakdown.facts
    if facts and facts.quality then return facts.quality end
    local known = ns.Disenchant and ns.Disenchant.GetItemFacts and ns.Disenchant:GetItemFacts(entry.itemID)
    return known and known.quality
end

local function SameRow(a, b)
    return a and b and a.itemID == b.itemID
end

--- The time now, or nil without a clock (a test's).
local function Now()
    return type(time) == "function" and time() or nil
end

--- Any way ticked in the Sell to menu?
local function AnyRoute()
    return next(state.routes) ~= nil
end

--- One way's profit in words, for a line on what the other ways make.
local function OtherWay(row)
    local money = Util.FormatMoney(row.gain, { noColor = true, short = true })
    if row.route == "vendor" then return L.Format("sold to a vendor, %s", money) end
    return L.Format("listed again, %s", money)
end

--- "Other ways: ..." for a row that more than one way pays on, or nil.
local function OthersText(entry)
    if not entry.others or #entry.others == 0 then return nil end

    local parts = {}
    for _, other in ipairs(entry.others) do parts[#parts + 1] = OtherWay(other) end
    return L.Format("Other ways: %s.", table.concat(parts, "; "))
end

--- Send a search for this item, so it shows in the auction house list ready
--- to buy. Your own click on the game's Buy button still does the buying.
local function SearchAuctionHouse(entry)
    if not entry then return end

    local scanner = ns.Scanner
    if not scanner or not scanner.isAuctionHouseOpen then
        ns.Print(L["Open the auction house first, then search again."])
        return
    end

    if scanner.isScanning then
        ns.Print(L["A scan is running. Search again once it finishes."])
        return
    end

    -- The same search as the rest of the addon's item clicks: its own slot
    -- in the queue, at click priority. The scan's slot was shared, so this
    -- could replace a waiting scan (or a scan could drop this search).
    if not ns.UI:SearchAuctionHouse(entry.itemID) then return end

    local label = Util.GetItemLabel(entry.itemID)

    if entry.route == "auction" then
        ns.Print(L.Format("Searching the auction house for %s. Anything under %s each is worth buying to list again at %s. If the list there doesn't change, type the name into its search box.",
            label, Plain(math.floor(entry.net)), Plain(entry.resell)))
    else
        ns.Print(L.Format("Searching the auction house for %s. Anything at %s each or less is a vendor flip. If the list there doesn't change, type the name into its search box.",
            label, Plain(entry.vendor - 1)))
    end
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local NEW_TAG_WIDTH = 30

local function ApplyRowLayout(row)
    local offset = ns.Columns:Place("deals", COLUMNS, row.cells, { byIndex = true })
    row.nameRight = offset - 4
    row.newTag:SetPoint("RIGHT", row, "RIGHT", row.nameRight, 0)
    row.name:SetPoint("RIGHT", row, "RIGHT", row.nameRight - (row.newShown and NEW_TAG_WIDTH or 0), 0)
    row.columnsVersion = ns.Columns.version
end

local function CreateRow(row)
    row.icon = Theme.CreateItemIcon(row, 16)
    row.icon:SetPoint("LEFT", 8, 0)

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("LEFT", 8 + ICON_GUTTER, 0)

    -- First seen in the latest scan.
    row.newTag = Theme.CreateLabel(row, "tiny", "accent", "RIGHT")
    row.newTag:SetText(L["NEW"])
    row.newTag:Hide()

    row.cells = {}
    for index, column in ipairs(COLUMNS) do
        row.cells[index] = Theme.CreateLabel(row, "small", "text", column.justify or "RIGHT")
    end

    ApplyRowLayout(row)
end

local function FillCell(cell, key, entry)
    local color = "muted"
    local text

    if key == "gain" then
        cell:SetText(Money(entry.gain))
        cell:SetTextColor(Theme.ProfitColor(entry.gain))
        return
    elseif key == "margin" then
        cell:SetText(MarginText(entry.margin))
        cell:SetTextColor(Theme.ProfitColor(entry.gain))
        return
    elseif key == "via" then
        text = entry.via or ""
    elseif key == "gets" then
        text = Money(entry.gets)
        color = "text"
    elseif key == "buy" then
        text = Money(entry.buy)
    elseif key == "qty" then
        -- One alone in amber: likely a single cheap listing, not a market.
        text = entry.qty and tostring(entry.qty) or "--"
        color = entry.qty == 1 and "warn" or (entry.qty and "text" or "dim")
    elseif key == "age" then
        -- Read now, as the list itself can be kept for a while. "now"
        -- rather than "just now", which is wider than the column.
        local age = ns.Prices:GetAge(entry.itemID) or entry.age
        text = age and Util.FormatAge(age) or ""
        if text == L["just now"] then text = L["now"] end
        color = ns.Prices:IsStale(entry.itemID) and "warn" or "dim"
    end

    cell:SetText(text or "")
    cell:SetTextColor(Theme.Unpack(color))
end

local function UpdateRow(row, entry)
    local isNew = entry.isNew and true or false
    if row.columnsVersion ~= ns.Columns.version or row.newShown ~= isNew then
        row.newShown = isNew
        row.newTag:SetShown(isNew)
        ApplyRowLayout(row)
    end

    Theme.SetRowName(row.name, entry.name or L.Format("item %s", tostring(entry.itemID)))
    Theme.SetItemIcon(row.icon, entry.itemID)

    -- Coloured by rarity from the facts kept in the saved data: most rows
    -- are items the client's cache no longer holds, which drew white.
    local r, g, b = Util.GetItemQualityColor(entry.itemID, KnownQuality(entry))
    if r then
        row.name:SetTextColor(r, g, b)
    else
        row.name:SetTextColor(Theme.Unpack("text"))
    end

    for index, column in ipairs(COLUMNS) do
        FillCell(row.cells[index], column.key, entry)
    end
end

local function ShowRowTooltip(row, entry)
    Widgets.ShowItemTooltip(row, "ANCHOR_LEFT", entry.itemID, entry.name)

    GameTooltip:AddLine(" ")

    if entry.route == "auction" then
        GameTooltip:AddLine(L.Format("Buy at %s, list it again at %s: %s profit each after the cut.",
            Plain(entry.buy), Plain(entry.resell), Plain(entry.gain)), 0.35, 0.85, 0.45, true)
        GameTooltip:AddLine(L.Format("Usually sells for %s (middle of %d scans).",
            Plain(entry.usual), entry.scans - 1), 0.85, 0.85, 0.85, true)
        local demand = ns.Demand:TooltipText(entry.demand)
        if demand then GameTooltip:AddLine(L.Format("Demand: %s", demand), 0.85, 0.85, 0.85, true) end
    else
        GameTooltip:AddLine(L.Format("Buy at %s, sell to any vendor for %s: %s profit each.",
            Plain(entry.buy), Plain(entry.vendor), Plain(entry.gain)), 0.35, 0.85, 0.45, true)
    end

    if entry.listed then
        GameTooltip:AddLine(L.Format("%d listed.", entry.listed), 0.85, 0.85, 0.85, true)
    end
    if entry.qty then
        GameTooltip:AddLine(entry.qty == 1 and L["Only one listed at this price."]
            or L.Format("%d listed at this price or less.", entry.qty), 0.85, 0.85, 0.85, true)
    end

    local others = OthersText(entry)
    if others then GameTooltip:AddLine(others, 0.7, 0.7, 0.7, true) end

    if entry.isNew then
        GameTooltip:AddLine(L["New: first seen in the latest scan."], 0.91, 0.76, 0.35, true)
    elseif entry.firstSeen and Now() then
        GameTooltip:AddLine(L.Format("First seen %s.", Util.FormatAgeAgo(Now() - entry.firstSeen)),
            0.7, 0.7, 0.7, true)
    end

    -- Read now, as the AGE column is: the list can be kept for hours, and
    -- the warning it was built with never came on as the scan aged.
    if ns.Prices:IsStale(entry.itemID) then
        GameTooltip:AddLine(L["Scanned a while ago, so it may have sold."], 0.91, 0.76, 0.35, true)
    end

    GameTooltip:AddLine(L["Right-click to search the auction house for it."], 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- Detail panel
--------------------------------------------------------------------------------

--- Four label and value lines in a frame.
local function SummaryBlock(detail)
    local summary = CreateFrame("Frame", nil, detail)

    local function SummaryRow(index)
        local label = Theme.CreateLabel(summary, "small", "muted")
        label:SetPoint("TOPLEFT", 0, -(index - 1) * 17)

        local value = Theme.CreateLabel(summary, "small", "text", "RIGHT")
        value:SetPoint("TOPRIGHT", 0, -(index - 1) * 17)

        return { label = label, value = value }
    end

    summary.lines = { SummaryRow(1), SummaryRow(2), SummaryRow(3), SummaryRow(4) }
    return summary
end

local function BuildDetail(parent)
    local detail = Theme.CreatePanel(parent, "window")
    detail:SetWidth(DETAIL_WIDTH)

    Theme.AccentStripe(detail, 2, 0.6)

    local icon = Theme.CreateItemIcon(detail, 30)
    icon:SetPoint("TOPLEFT", 12, -12)
    detail.icon = icon
    if Widgets.ItemHotspot then Widgets.ItemHotspot(icon) end

    local title = Theme.CreateLabel(detail, "large", "accent")
    title:SetPoint("TOPLEFT", 50, -12)
    title:SetPoint("TOPRIGHT", -12, -12)
    title:SetWordWrap(true)
    detail.title = title

    local subtitle = Theme.CreateLabel(detail, "small", "muted")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    subtitle:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
    subtitle:SetWordWrap(true)
    detail.subtitle = subtitle

    local heading = Theme.CreateHeading(detail, L["THE FLIP"])
    heading:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", -38, -12)
    detail.heading = heading

    -- A flip to a vendor or back onto the auction house: the sums under the
    -- heading, a bar for how much of the sale is profit, then the words.
    local flip = SummaryBlock(detail)
    flip:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -8)
    flip:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
    flip:SetHeight(69)

    flip.bar = Theme.CreateBar(detail, DETAIL_WIDTH - 24, 3)
    flip.bar:SetPoint("TOPLEFT", flip, "TOPLEFT", 0, -54)

    flip.verdict = Theme.CreateLabel(detail, "small", "profit")
    flip.verdict:SetPoint("TOPLEFT", flip.bar.track, "BOTTOMLEFT", 0, -10)
    flip.verdict:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
    flip.verdict:SetWordWrap(true)

    -- Under the verdict, as tall as its words. A box of fixed height pinned
    -- to the bottom had room for five lines, and the warning that the scan
    -- is old made six, so the warning itself was the line cut off.
    flip.note = Theme.CreateLabel(detail, "tiny", "dim")
    flip.note:SetPoint("TOPLEFT", flip.verdict, "BOTTOMLEFT", 0, -10)
    flip.note:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
    flip.note:SetWordWrap(true)
    flip.note:SetJustifyV("TOP")
    detail.flip = flip

    -- Always on show, a row picked or not: a flip is never a sure thing.
    -- It wraps, and UpdateDetail hangs it under whatever the panel shows.
    local risk = Theme.CreateLabel(detail, "tiny", "warn")
    risk:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
    risk:SetWordWrap(true)
    risk:SetJustifyV("TOP")
    risk:SetText(L["Flipping is risky: prices can drop before you sell. Only spend what you can afford to lose."])
    detail.risk = risk

    local searchButton = Widgets.CreateButton(detail, L["Search the auction house"], function()
        SearchAuctionHouse(state.selected)
    end, { width = 200, primary = true, height = 24 })
    searchButton:SetPoint("BOTTOMLEFT", 12, 14)
    searchButton.tooltipText = L["Finds this item on the auction house. You click Buy yourself."]
    detail.searchButton = searchButton

    local empty = Theme.CreateLabel(detail, "small", "dim", "CENTER")
    empty:SetPoint("CENTER")
    empty:SetWidth(DETAIL_WIDTH - 40)
    empty:SetWordWrap(true)
    empty:SetText(L["Pick a row to see the deal."])
    detail.empty = empty

    return detail
end

local function SetLine(line, label, value, color)
    line.label:SetShown(label ~= nil)
    line.value:SetShown(label ~= nil)
    if not label then return end

    line.label:SetText(label)
    line.value:SetText(value or "")
    line.value:SetTextColor(Theme.Unpack(color or "text"))
end

--- How many are listed, for the top of a flip's detail.
local function ListedText(entry)
    if entry.listed and entry.listed > 1 then
        return L.Format("%d listed. Only the cheapest is sure to be at this price.", entry.listed)
    end
    return L["One listed."]
end

--- The detail panel for a row bought to list again.
local function UpdateResaleDetail(detail, entry)
    local block = detail.flip

    detail.subtitle:SetText(ListedText(entry))
    detail.subtitle:SetTextColor(Theme.Unpack("muted"))

    local lines = block.lines
    SetLine(lines[1], entry.loneLow and L["Buy for (lone low)"] or L["Buy for"], Util.FormatMoney(entry.buy), "text")
    SetLine(lines[2], L["Usually sells for"], Util.FormatMoney(entry.usual), "text")
    SetLine(lines[3], entry.capped and L["List again at (next listing)"] or L["List again at"],
        Util.FormatMoney(entry.resell), "text")
    SetLine(lines[4], L["Profit each"], ("%s  (%s)"):format(Util.FormatMoney(entry.gain), MarginText(entry.margin)),
        "profit")

    block.bar:SetPoint("TOPLEFT", block, "TOPLEFT", 0, -71)
    block.bar:Set(entry.resell > 0 and entry.gain / entry.resell or 0, "profit")

    local cut = math.floor((ns.Config:Get("auctionCut") or 0.05) * 100 + 0.5)
    if entry.depositKnown and entry.depositCounts then
        block.verdict:SetText(L.Format("Buy it, list it again at %s, and keep about %s each after the %d%% cut and the deposit.",
            Plain(entry.resell), Plain(entry.gain), cut))
    else
        block.verdict:SetText(L.Format("Buy it, list it again at %s, and keep about %s each after the %d%% cut.",
            Plain(entry.resell), Plain(entry.gain), cut))
    end
    block.verdict:SetTextColor(Theme.Unpack("profit"))

    local parts = { OthersText(entry) }
    parts[#parts + 1] = L.Format("The usual price comes from your %d scans before the last one.", entry.scans - 1)
    local demand = ns.Demand:TooltipText(entry.demand)
    if demand then parts[#parts + 1] = L.Format("Demand: %s.", demand) end
    if entry.depositCounts and not entry.depositKnown then
        parts[#parts + 1] = L["The deposit isn't counted until you've listed one."]
    end
    parts[#parts + 1] = L["Your gold is tied up until it sells."]
    local age = ns.Prices:GetAge(entry.itemID) or entry.age
    parts[#parts + 1] = age and L.Format("Scanned %s.", Util.FormatAgeAgo(age)) or L["Never scanned."]
    if ns.Prices:IsStale(entry.itemID) then parts[#parts + 1] = L["That was a while ago, so it may have sold."] end
    block.note:SetText(table.concat(parts, " "))
end

--- The detail panel for a row bought to sell to a vendor.
local function UpdateVendorDetail(detail, entry)
    local block = detail.flip

    detail.subtitle:SetText(ListedText(entry))
    detail.subtitle:SetTextColor(Theme.Unpack("muted"))

    -- Short enough to stay clear of the price on its right; the longer
    -- "(a lone low listing)" ran over it.
    local lines = block.lines
    SetLine(lines[1], entry.loneLow and L["Buy for (lone low)"] or L["Buy for"], Util.FormatMoney(entry.buy), "text")
    SetLine(lines[2], L["A vendor pays"], Util.FormatMoney(entry.vendor), "text")
    SetLine(lines[3], L["Profit each"], ("%s  (%s)"):format(Util.FormatMoney(entry.gain), MarginText(entry.margin)),
        "profit")
    SetLine(lines[4], nil)

    block.bar:SetPoint("TOPLEFT", block, "TOPLEFT", 0, -54)
    block.bar:Set(entry.vendor > 0 and entry.gain / entry.vendor or 0, "profit")

    block.verdict:SetText(L.Format("Buy it, sell it to any vendor, and keep about %s each. No auction house cut.",
        Plain(entry.gain)))
    block.verdict:SetTextColor(Theme.Unpack("profit"))

    -- The scan's age read now, as the AGE column reads it: the list can be
    -- kept for hours, and the age it was built with went on saying "2m ago".
    local age = ns.Prices:GetAge(entry.itemID) or entry.age
    local parts = { OthersText(entry) }
    parts[#parts + 1] = L.Format("The buy price is the cheapest listing at your last scan (%s). Every item in a stack earns the same.",
        age and Util.FormatAgeAgo(age) or L["never"])
    if ns.Prices:IsStale(entry.itemID) then parts[#parts + 1] = L["That was a while ago, so it may have sold."] end
    if entry.vendorFrom == "sold" then
        parts[#parts + 1] = L["The vendor price is what a vendor paid you when you last sold one."]
    elseif entry.vendorFrom ~= "reported" then
        parts[#parts + 1] = L["The vendor price may be off. Sell one to a vendor to get the real price."]
    end
    block.note:SetText(table.concat(parts, " "))
end

local function UpdateDetail(entry)
    local detail = widgets.detail
    local shown = entry ~= nil
    local flip = detail.flip

    detail.empty:SetShown(not shown)

    local risk = detail.risk
    risk:ClearAllPoints()
    risk:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
    if shown then
        risk:SetPoint("TOPLEFT", flip.note, "BOTTOMLEFT", 0, -10)
    else
        risk:SetPoint("TOPLEFT", detail.empty, "BOTTOMLEFT", 0, -12)
    end

    for _, part in ipairs({ detail.icon, detail.title, detail.subtitle, detail.heading,
            detail.searchButton, flip, flip.verdict, flip.note }) do
        part:SetShown(shown)
    end

    if not shown then
        -- Theme.CreateBar's plain table, not a frame: Set(nil) hides it.
        flip.bar:Set(nil)
        return
    end

    detail.title:SetText(entry.name or L.Format("item %s", tostring(entry.itemID)))
    Theme.SetItemNameColor(detail.title, entry.itemID, "accent", KnownQuality(entry))
    Theme.SetItemIcon(detail.icon, entry.itemID)

    if entry.route == "auction" then return UpdateResaleDetail(detail, entry) end
    return UpdateVendorDetail(detail, entry)
end

--------------------------------------------------------------------------------
-- List
--------------------------------------------------------------------------------

-- The last full list and what it was built from. Walking every scanned item
-- is only done again when something it depends on has changed: a redraw for
-- a bag change or an auction event reuses it. At the auction house those
-- redraws come often, and walking thousands of items each time pushed bag
-- items out of the client's memory, so Ready to sell kept losing them.
local built = { key = nil, rows = nil, hidden = 0, pending = 0, thin = 0 }

local function BuildKey()
    return table.concat({
        tostring(ns.Prices and ns.Prices.changes or 0),
        tostring(ns.Prices and ns.Prices:Count() or 0),
        -- Vendor prices are read into the item facts as they arrive.
        tostring(ns.Disenchant.factsVersion or 0),
        tostring(state.dealsOnly),
        tostring(state.routes.auction), tostring(state.routes.vendor),
        tostring(ns.Config:Get("minProfit")),
        tostring(ns.Config:Get("minMarginPercent")),
        tostring(ns.Config:Get("auctionCut")),
        tostring(ns.Scanner and ns.Scanner.isAuctionHouseOpen and true or false),
    }, "|")
end

--- Which of two ways on the same item wins: the bigger profit.
local function Beats(a, b)
    return a.gain > b.gain
end

--- Every ticked way's rows, one per item on its best way.
local function MergeRoutes()
    local byItem, order = {}, {}
    local hidden, pending, thin = 0, 0, 0

    local function Take(rows, route, gets)
        for _, row in ipairs(rows or {}) do
            row.route, row.via, row.gets = route, VIA[route], gets(row)
            row.others = nil

            local best = byItem[row.itemID]
            if not best then
                byItem[row.itemID] = row
                order[#order + 1] = row.itemID
            elseif Beats(row, best) then
                row.others = best.others or {}
                best.others = nil
                table.insert(row.others, best)
                byItem[row.itemID] = row
            else
                best.others = best.others or {}
                best.others[#best.others + 1] = row
            end
        end
    end

    if state.routes.vendor then
        local rows, held, waiting = ns.VendorFlips:GetAuctionRows({ profitableOnly = state.dealsOnly })
        hidden, pending = hidden + (held or 0), math.max(pending, waiting or 0)
        -- For /bts vendordeals.
        ns.VendorFlips.shownRows, ns.VendorFlips.shownBuiltAt = rows, Now()
        Take(rows, "vendor", function(row) return row.vendor end)
    end

    if state.routes.auction then
        local rows, held, few = ns.VendorFlips:GetResaleRows({ profitableOnly = state.dealsOnly })
        hidden, thin = hidden + (held or 0), few or 0
        Take(rows, "auction", function(row) return row.resell end)
    end

    local rows = {}
    for _, itemID in ipairs(order) do rows[#rows + 1] = byItem[itemID] end

    table.sort(rows, function(a, b)
        if a.gain ~= b.gain then return a.gain > b.gain end
        return a.itemID < b.itemID
    end)

    return rows, hidden, pending, thin
end

local function BuildRows()
    local key = BuildKey()

    if key ~= built.key then
        local rows, hidden, pending, thin = MergeRoutes()
        if ns.VendorFlips.NoteSeen then ns.VendorFlips:NoteSeen(rows) end
        built.key, built.rows = key, rows
        built.hidden, built.pending, built.thin = hidden, pending, thin
    end

    local rows = built.rows
    state.hidden = built.hidden
    state.pending = built.pending
    state.thin = built.thin

    if state.search == "" and not state.newOnly then return rows end

    local needle = state.search:lower()
    local filtered = {}

    for _, row in ipairs(rows) do
        if (not state.newOnly or row.isNew)
            and (needle == "" or (row.name or ""):lower():find(needle, 1, true)) then
            filtered[#filtered + 1] = row
        end
    end

    return filtered
end

local function EmptyText()
    if state.search ~= "" then
        return L.Format("Nothing matching \"%s\".", state.search)
    end

    if state.newOnly and #(built.rows or {}) > 0 then
        return L["Nothing new in the latest scan. Untick \"New only\" to see every deal."]
    end

    if not AnyRoute() then
        return L["Tick at least one way to sell in the Sell to menu."]
    end

    if (ns.Prices and ns.Prices:Count() or 0) == 0 then
        return L["Scan the auction house to find items worth buying."]
    end

    local text = L["Nothing on the auction house is worth buying right now."]

    if state.dealsOnly and state.hidden > 0 then
        return text .. " " .. L.Format("%d more would make a profit, but less than your minimums in Settings (%s profit, %d%% margin). Untick \"Only deals over my minimums\" to see them.",
            state.hidden,
            Util.FormatMoney(ns.Config:Get("minProfit") or 0, { noColor = true, short = true }),
            ns.Config:Get("minMarginPercent") or 0)
    end

    if state.routes.auction and (state.thin or 0) > 0 then
        text = text .. " " .. L.Format("%d more are cheap, but have fewer than %d scans, little demand, or are grey. Scan again over the next few days to build up their history.",
            state.thin, ns.VendorFlips.MIN_RESALE_SCANS)
    end

    return text
end

--- The count line for the auction house list, in the first whole wording
--- that fits beside the hint rather than one ending in "...".
local function SetDealsCount(rows)
    local deals, total = 0, 0
    for _, row in ipairs(rows) do
        if row.gain > 0 then
            deals = deals + 1
            total = total + row.gain
        end
    end

    local found
    if deals > 0 then
        local money = Util.FormatMoney(total, { noColor = true, short = true })
        if deals == 1 then
            found = {
                L.Format("%d deal, about %s if you buy one of each", deals, money),
                L.Format("%d deal, about %s for one of each", deals, money),
                L.Format("%d deal", deals),
            }
        else
            found = {
                L.Format("%d deals, about %s if you buy one of each", deals, money),
                L.Format("%d deals, about %s for one of each", deals, money),
                L.Format("%d deals", deals),
            }
        end
    elseif #rows > 0 then
        found = { #rows == 1 and L.Format("%d item", #rows) or L.Format("%d items", #rows) }
    end

    -- Items not read yet wait for the auction house to close, so reading
    -- them cannot upset Ready to sell. Say so, or the list looks short.
    local waiting
    if (state.pending or 0) > 0 then
        local closed = not (ns.Scanner and ns.Scanner.isAuctionHouseOpen)
        waiting = {
            closed and L.Format("%d more listed items not checked yet, reading them now", state.pending)
                or L.Format("%d more listed items not checked yet, checked once the auction house is closed", state.pending),
            L.Format("%d not checked yet", state.pending),
        }
    elseif state.routes.auction and (state.thin or 0) > 0 then
        waiting = {
            L.Format("%d more held back: few scans or little demand", state.thin),
            L.Format("%d held back", state.thin),
        }
    end

    local texts = { "" }
    if found and waiting then
        local sep = "  ·  "
        texts = {}
        for _, first in ipairs(found) do
            texts[#texts + 1] = first .. sep .. waiting[1]
            texts[#texts + 1] = first .. sep .. waiting[2]
        end
    elseif found or waiting then
        texts = found or waiting
    end

    if Theme.FitText then
        Theme.FitText(widgets.countLabel, texts)
    else
        widgets.countLabel:SetText(texts[1])
    end
end

local function Refresh()
    if not widgets.list then return end
    if state.view == "favor" and ns.DealsFavor then return ns.DealsFavor:Refresh() end
    if state.view == "writs" and ns.DealsWrits then return ns.DealsWrits:Refresh() end

    local rows = BuildRows()
    -- A clicked heading's order over the list's own.
    if widgets.sorter then rows = widgets.sorter:Sort(rows) end
    widgets.list:SetData(rows)

    widgets.emptyLabel:SetShown(#rows == 0)
    if #rows == 0 then widgets.emptyLabel:SetText(EmptyText()) end

    SetDealsCount(rows)

    local fresh
    if state.selected then
        for _, row in ipairs(rows) do
            if SameRow(row, state.selected) then
                fresh = row
                break
            end
        end
    end

    state.selected = fresh
    UpdateDetail(fresh)
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

--- The Sell to box's words: "All" with every way ticked, else their short names.
local function SellToSummary(set)
    local names, all = {}, true
    for _, route in ipairs(ROUTES) do
        if set[route.key] then names[#names + 1] = route.via else all = false end
    end
    if all then return L["Sell to: All"] end
    if #names == 0 then return L["Sell to: none"] end
    return L.Format("Sell to: %s", table.concat(names, ", "))
end

local function Build(container)
    -- Before any row or heading is laid out: they read these widths.
    if Widgets.FitColumns then Widgets.FitColumns(COLUMNS) end

    -- What the tab shows is pages along the top (a player asked, the owner
    -- said yes from a mockup, 2026-10-22; a "Show:" menu before), with the
    -- page's own bar under them.
    local pageTabs = {
        { key = "favor", text = L["Merchant's Favor"] },
        { key = "writs", text = L["Craftsman's Writs"] },
    }
    if SHOW_FLIPS then
        table.insert(pageTabs, 1, { key = "flips", text = L["Flips"] })
    end
    local show = Widgets.CreateTabStrip(container, pageTabs, function(value)
        UI.DealsSetView(value)
    end)
    show:SetPoint("TOPLEFT", 8, -8)
    show:Select(state.view)
    widgets.show = show

    local toolbar = CreateFrame("Frame", nil, container)
    toolbar:SetPoint("TOPLEFT", show, "BOTTOMLEFT", 0, -6)
    toolbar:SetPoint("RIGHT", container, "RIGHT", -8, 0)
    toolbar:SetHeight(24)
    widgets.toolbar = toolbar

    -- Everything below the option bar for the flips, so the Merchant's
    -- Favor view can take its place.
    local flipsView = CreateFrame("Frame", nil, container)
    flipsView:SetAllPoints(container)
    widgets.flipsView = flipsView
    widgets.container = container

    -- A new search or filter is a different list, so it starts at the top.
    -- The list keeps its place on the redraws that bag and auction events
    -- cause, which left a new search showing its results part way down.
    local function ShowFromTop()
        Refresh()
        if state.view == "favor" then
            ns.DealsFavor:ScrollToTop()
        elseif state.view == "writs" then
            ns.DealsWrits:ScrollToTop()
        elseif widgets.list then
            widgets.list:ScrollToTop()
        end
    end

    -- Option bar: the menu, then search, then the tick box, as on every
    -- tab (2026-10-06).
    local options = {}
    for _, route in ipairs(ROUTES) do
        options[#options + 1] = { text = route.text, value = route.key }
    end

    local sellTo = Widgets.CreateDropdown(toolbar, options, function(set)
        state.routes = set or {}
        state.selected = nil
        ShowFromTop()
    end, { width = 140, multi = true, summary = SellToSummary })
    sellTo:SetValue(state.routes)
    sellTo.tooltipText = L["Tick the ways you'll sell what you buy. Each item shows under whichever pays most."]
    widgets.sellTo = sellTo

    sellTo:SetPoint("LEFT", 0, 0)

    -- The reputation goal, for the writs; it takes Sell to's place.
    local goals = {}
    for _, goal in ipairs(ns.Writs and ns.Writs.GOALS or {}) do
        goals[#goals + 1] = { text = L.Format("Goal: %s", goal.text), value = goal.key }
    end
    local goal = Widgets.CreateDropdown(toolbar, goals, function(value)
        ns.DealsWrits:SetGoal(value)
        ns.Config:Set("writGoal", value)
        ShowFromTop()
    end, { width = 130 })
    goal:SetPoint("LEFT", 0, 0)
    if ns.DealsWrits then goal:SetValue(ns.DealsWrits:GetGoal()) end
    goal.tooltipText = L["The standing you want with your trade camp. The right side shows the writs it takes and their cost."]
    goal:Hide()
    widgets.goal = goal

    local search = Widgets.CreateSearchBox(toolbar, L["Search items"], function(text)
        state.search = text or ""
        if ns.DealsFavor then ns.DealsFavor:SetSearch(state.search) end
        if ns.DealsWrits then ns.DealsWrits:SetSearch(state.search) end
        ShowFromTop()
    end)
    search:SetPoint("LEFT", sellTo, "RIGHT", 8, 0)
    search:SetWidth(Widgets.SEARCH_WIDTH)
    widgets.search = search

    local dealsOnly = Widgets.CreateCheckbox(toolbar, L["Only deals over my minimums"], function(checked)
        state.dealsOnly = checked
        ShowFromTop()
    end, state.dealsOnly)
    dealsOnly:SetPoint("LEFT", search, "RIGHT", 12, 0)
    widgets.dealsOnly = dealsOnly

    local newOnly = Widgets.CreateCheckbox(toolbar, L["New only"], function(checked)
        state.newOnly = checked
        ShowFromTop()
    end, state.newOnly)
    newOnly:SetPoint("LEFT", dealsOnly, "RIGHT", 12, 0)
    widgets.newOnly = newOnly

    local skipOverStack = Widgets.CreateCheckbox(toolbar, L["Skip bundles over a stack"], function(checked)
        ns.DealsFavor:SetSkipOverStack(checked)
        ns.Config:Set("favorSkipOverStack", checked and true or false)
        ShowFromTop()
    end, not ns.DealsFavor or ns.DealsFavor:GetSkipOverStack())
    skipOverStack:SetPoint("LEFT", search, "RIGHT", 12, 0)
    skipOverStack.tooltipText = L["Leaves out bundles bigger than one stack, like 40 Linen Cloth."]
    skipOverStack:Hide()
    widgets.skipOverStack = skipOverStack

    -- Column headings
    local headings = CreateFrame("Frame", nil, flipsView)
    headings:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -8)
    headings:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", -DETAIL_WIDTH - 8, -8)
    headings:SetHeight(16)

    local nameHeading = Theme.CreateLabel(headings, "tiny", "muted")
    nameHeading:SetPoint("LEFT", 8 + ICON_GUTTER, 0)
    nameHeading:SetText(L["ITEM"])

    widgets.headings = {}
    for index, column in ipairs(COLUMNS) do
        local heading = Theme.CreateLabel(headings, "tiny", "muted", "RIGHT")
        heading:SetText(column.label)
        heading:SetJustifyH(column.justify or "RIGHT")
        widgets.headings[index] = heading
    end
    ns.Columns:Place("deals", COLUMNS, widgets.headings, { byIndex = true })

    -- Click a heading to sort by it.
    local sortLabels, values = { name = nameHeading }, {
        name = function(row) return row.name end,
    }
    for index, column in ipairs(COLUMNS) do
        sortLabels[index] = widgets.headings[index]
        values[index] = function(row) return row[column.key] end
    end
    widgets.sorter = Widgets.SortableHeadings and Widgets.SortableHeadings(sortLabels, values,
        function() Refresh() end)
    if widgets.sorter then widgets.sorter:SetText({ "name" }) end

    -- Right-click the headings to choose the columns.
    ns.Columns:Attach(headings, "deals", widgets.sorter)
    ns.Columns:OnChange("deals", function()
        ns.Columns:Place("deals", COLUMNS, widgets.headings, { byIndex = true })
        if widgets.sorter then widgets.sorter:Sync() end
        if widgets.list then widgets.list:Refresh() end
    end)

    local divider = Theme.CreateDivider(flipsView, "borderLit")
    divider:SetPoint("TOPLEFT", headings, "BOTTOMLEFT", 0, -2)
    divider:SetPoint("TOPRIGHT", headings, "BOTTOMRIGHT", 0, -2)

    local list = Widgets.CreateScrollList(flipsView, {
        -- The headings move in with the rows when the scrollbar takes its room.
        onScrollbarShown = function(shown)
            headings:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", -DETAIL_WIDTH - 8 - (shown and 10 or 0), -8)
        end,
        rowHeight = ROW_HEIGHT,
        createRow = CreateRow,
        updateRow = UpdateRow,

        onEnter = function(row, entry) ShowRowTooltip(row, entry) end,
        onLeave = function() GameTooltip:Hide() end,
        clickHint = L["Right-click for more."],

        -- The row's menu (the house kit, 2026-10-29): search first, as the
        -- right-click did.
        menu = function(entry)
            state.selected = entry
            UpdateDetail(entry)
            if widgets.list then widgets.list:Refresh() end
            return { { text = L["Search the Auction House"], run = function() SearchAuctionHouse(entry) end } }
        end,

        isSelected = function(entry)
            return SameRow(entry, state.selected)
        end,

        onClick = function(entry)
            state.selected = entry
            UpdateDetail(entry)
        end,
    })

    list:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -4)
    list:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -DETAIL_WIDTH - 16, 24)
    widgets.list = list

    local emptyLabel = Theme.CreateLabel(flipsView, "small", "dim", "CENTER")
    emptyLabel:SetPoint("CENTER", list, "CENTER", 0, 10)
    emptyLabel:SetWidth(380)
    emptyLabel:SetWordWrap(true)
    widgets.emptyLabel = emptyLabel
    if Widgets.DressEmpty then Widgets.DressEmpty(emptyLabel) end

    local countLabel = Theme.CreateLabel(flipsView, "tiny", "dim")
    countLabel:SetPoint("BOTTOMLEFT", 8, 8)
    widgets.countLabel = countLabel

    local hint = Theme.CreateLabel(flipsView, "tiny", "dim", "RIGHT")
    hint:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -DETAIL_WIDTH - 16, 8)
    -- What a click does is on each row's hover now; the footer is the count.
    hint:SetText("")
    widgets.hint = hint

    -- The count line grows a long "not checked yet" note while items load,
    -- and ran under this hint. It stops short of it now, and SetDealsCount
    -- picks a wording that fits.
    countLabel:SetPoint("RIGHT", hint, "LEFT", -12, 0)
    countLabel:SetJustifyH("LEFT")
    countLabel:SetWordWrap(false)

    local detail = BuildDetail(flipsView)
    detail:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -8)
    detail:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -8, 8)
    widgets.detail = detail

    UpdateDetail(nil)

    -- Scanned items the client has not cached are left out until it has
    -- them, and are asked for a few dozen a second. Redraw as they arrive,
    -- coalescing a burst into one pass.
    local redrawQueued = false

    ns.RegisterEvent(widgets, "GET_ITEM_INFO_RECEIVED", function(_, _, itemID)
        if redrawQueued or not widgets.list:IsVisible() then return end

        -- Only for items this tab asked for, not every item any window loads.
        if itemID and not ns.Disenchant:WasRequested(itemID) then return end

        redrawQueued = true
        C_Timer.After(1, function()
            redrawQueued = false
            -- Not once the player has moved to another tab: it redraws
            -- when shown.
            if widgets.list:IsVisible() then Refresh() end
        end)
    end)
    -- Items new to the tab wait while the auction house is open. Read them
    -- as soon as it closes rather than whenever something next redraws.
    ns.RegisterEvent(widgets, "AUCTION_HOUSE_CLOSED", function()
        if not widgets.list:IsVisible() then return end
        C_Timer.After(0.5, function()
            if widgets.list:IsVisible() then Refresh() end
        end)
    end)

    -- With the flips put away the tab opens on Merchant's Favor.
    if state.view ~= "flips" then UI.DealsSetView(state.view) end
end

-- The views the Show menu swaps in, each built the first time it is shown.
local VIEWS = {
    favor = "DealsFavor",
    writs = "DealsWrits",
}

--- Show the flips, the Merchant's Favor view or the Craftsman's Writs view.
function UI.DealsSetView(view)
    if not (VIEWS[view] and ns[VIEWS[view]]) then view = "flips" end
    if view == "flips" and not SHOW_FLIPS then view = "favor" end
    state.view = view
    state.selected = nil
    if not widgets.toolbar then return end

    widgets.views = widgets.views or {}
    local module = VIEWS[view] and ns[VIEWS[view]]
    if module and not widgets.views[view] then
        local frame = CreateFrame("Frame", nil, widgets.container)
        frame:SetAllPoints(widgets.container)
        widgets.views[view] = frame
        module:Build(frame, widgets.toolbar)
    end

    widgets.flipsView:SetShown(view == "flips")
    for key, frame in pairs(widgets.views) do frame:SetShown(key == view) end
    widgets.sellTo:SetShown(view == "flips")
    widgets.dealsOnly:SetShown(view == "flips")
    widgets.newOnly:SetShown(view == "flips")
    widgets.skipOverStack:SetShown(view == "favor")
    widgets.goal:SetShown(view == "writs")

    -- Search sits after the menu this view shows, first when it has none.
    if widgets.show and widgets.show.Select then widgets.show:Select(view) end
    local before = view == "flips" and widgets.sellTo or view == "writs" and widgets.goal or nil
    widgets.search:ClearAllPoints()
    if before then
        widgets.search:SetPoint("LEFT", before, "RIGHT", 8, 0)
    else
        widgets.search:SetPoint("LEFT", widgets.toolbar, "LEFT", 0, 0)
    end

    Refresh()
    if module then module:ScrollToTop() elseif widgets.list then widgets.list:ScrollToTop() end
end

-- On Era neither Merchant's Favor nor the writs exist (their files are out
-- of the TOC), so with the flips put away the tab has nothing to show and
-- is left out.
if SHOW_FLIPS or ns.DealsFavor or ns.DealsWrits then
    UI:RegisterTab({
        key = "deals",
        text = SHOW_FLIPS and L["Deals"] or L["Favors and Writs"],
        order = 7,
        build = Build,
        refresh = Refresh,
    })
end
