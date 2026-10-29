-- Blackthornes Tradeskills -- UI/Tab_Gather.lua
-- The materials gathering queue.
--
-- Everything the craft queue needs, in one list, grouped by where you have to
-- go to get it. The vendor-versus-auction choice is made explicit rather than
-- resolved silently inside the cost engine: on a Classic realm people list
-- vendor-sold thread for many times the shop price, and knowing that is worth
-- more than a slightly cheaper total.
--
-- There is no manual "tick off" state. Items leave the list when you actually
-- own them, which is the only definition of gathered that cannot go stale.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local UI = ns.UI

local ROW_HEIGHT = 24

-- Right to left. Money sits to the right, so its coins line up; the rest is
-- centred under its heading. `width` is the least each gets:
-- Widgets.FitColumns widens it to fit the heading and a full amount.
local COLUMNS = {
    { key = "action", label = "",       width = 30 },
    { key = "cost",   label = L["COST"],   width = 74, money = true },
    { key = "unit",   label = L["EACH"],   width = 64, money = true },
    { key = "source", label = L["BUY AT"], width = 76, justify = "CENTER" },
    { key = "have",   label = L["HAVE"],   width = 42, justify = "CENTER" },
    { key = "need",   label = L["NEED"],   width = 42, justify = "CENTER" },
}

-- Any column with a heading can be hidden (UI/Columns.lua).
ns.Columns:Register("gather", L["Gather"], COLUMNS)

local SOURCE_LABELS = {
    vendor  = L["Vendor"],
    auction = L["Auction"],
    unknown = L["no data"],
}

local state = { hideSatisfied = true, sortBy = "source" }
local widgets = {}

--------------------------------------------------------------------------------
-- Data
--------------------------------------------------------------------------------

local SOURCE_ORDER = { vendor = 1, auction = 2, unknown = 3 }

--- The rows to show, sorted, and the whole shopping list they came from.
local function BuildList()
    local lines = {}
    local all = ns.Queue:GetShoppingList()

    for _, line in ipairs(all) do
        if line.shortfall > 0 or not state.hideSatisfied then
            line.label = Util.GetItemLabel(line.itemID)
            lines[#lines + 1] = line
        end
    end

    table.sort(lines, function(a, b)
        -- Outstanding first: satisfied rows are reference, not work.
        local aDone, bDone = a.shortfall <= 0, b.shortfall <= 0
        if aDone ~= bDone then return bDone end

        if state.sortBy == "source" then
            -- Grouped by where you go, so the list reads as a route: clear the
            -- vendor in one trip, then the auction house.
            local aOrder = SOURCE_ORDER[a.source] or 9
            local bOrder = SOURCE_ORDER[b.source] or 9
            if aOrder ~= bOrder then return aOrder < bOrder end

        elseif state.sortBy == "cost" then
            local aCost, bCost = a.estimatedCost or 0, b.estimatedCost or 0
            if aCost ~= bCost then return aCost > bCost end

        elseif state.sortBy == "name" then
            -- By the name inside the link: the link itself opens with a
            -- colour code, which sorted by rarity instead.
            local aName = (a.label or ""):match("%[(.-)%]") or a.label or ""
            local bName = (b.label or ""):match("%[(.-)%]") or b.label or ""
            if aName ~= bName then return aName < bName end
        end

        -- A last tie-break, so equal rows (every "no data" one at 0) keep
        -- their places between refreshes instead of swapping.
        if (a.estimatedCost or 0) ~= (b.estimatedCost or 0) then
            return (a.estimatedCost or 0) > (b.estimatedCost or 0)
        end
        return (a.itemID or 0) < (b.itemID or 0)
    end)

    return lines, all
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

--- The shown columns from the right edge; the name has the rest.
local function PlaceRow(row)
    local offset = ns.Columns:Place("gather", COLUMNS, row.cells)
    row.name:SetPoint("RIGHT", row, "RIGHT", offset - 10, 0)
    row.columnsVersion = ns.Columns.version
end

local function CreateRow(row)
    -- The item's icon beside its name, as the bags draw it.
    row.icon = Theme.CreateItemIcon(row, 16)
    row.icon:SetPoint("LEFT", 10, 0)

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("LEFT", 30, 0)

    row.cells = {}
    for _, column in ipairs(COLUMNS) do
        if column.key ~= "action" then
            row.cells[column.key] = Theme.CreateLabel(row, "small", "muted", column.justify or "RIGHT")
        end
    end

    PlaceRow(row)

    row.search = Widgets.CreateButton(row, L["AH"], function()
        if row.data then UI:SearchOrPlan(row.data.itemID, row.data.shortfall) end
    end, { width = 26, height = 16, tooltip = L["Search the auction house for this"] })
    row.search:SetPoint("RIGHT", -8, 0)

    -- With Blackthornes Farmer loaded: turn the shortfall into a Farmer
    -- gathering goal, shown on Farmer's Goals panel.
    row.goal = Widgets.CreateButton(row, L["Set goal"], function()
        local line = row.data
        if line then ns.FarmerGoals:SetGoal(line.itemID, line.needed) end
    end, { width = 52, height = 16,
        tooltip = L["Make a Blackthornes Farmer goal to gather what you need of this"] })
    row.goal:SetPoint("RIGHT", -38, 0)
    row.goal:Hide()
end

local function UpdateRow(row, line)
    if row.columnsVersion ~= ns.Columns.version then PlaceRow(row) end

    local done = line.shortfall <= 0

    -- The plain name, set on the label so its colour shows: greyed once you
    -- have it all, else its rarity colour (below).
    Theme.SetRowName(row.name, Util.GetItemName(line.itemID, line.label))
    Theme.SetItemIcon(row.icon, line.itemID)

    local cells = row.cells

    cells.need:SetText(tostring(line.needed))
    cells.have:SetText(tostring(line.have))
    cells.have:SetTextColor(Theme.Unpack(done and "profit" or "loss"))

    if done then
        row.name:SetTextColor(Theme.Unpack("muted"))

        cells.source:SetText(line.paid and L["bought"] or L["have it"])
        cells.source:SetTextColor(Theme.Unpack("dim"))
        cells.unit:SetText("")
        -- Bought: what it cost, amber when well over the estimate.
        if line.paid then
            cells.cost:SetText(Util.FormatMoney(line.paid, { short = true }))
            cells.cost:SetTextColor(Theme.Unpack(line.overpaid and "warn" or "muted"))
        else
            cells.cost:SetText("")
        end

        row.search:Hide()
        row.goal:Hide()
        return
    end

    local r, g, b = Util.GetItemQualityColor(line.itemID)
    if r then
        row.name:SetTextColor(r, g, b)
    else
        row.name:SetTextColor(Theme.Unpack("text"))
        if line.itemID then state.waiting = true end
    end

    cells.source:SetText(SOURCE_LABELS[line.source] or "?")
    cells.source:SetTextColor(Theme.Unpack(
        line.source == "vendor" and "accent"
        or line.source == "auction" and "text"
        or "dim"))

    cells.unit:SetText(line.unitCost and Util.FormatMoney(line.unitCost, { short = true }) or "?")
    cells.cost:SetText(line.estimatedCost
        and Util.FormatMoney(line.estimatedCost, { short = true }) or "?")
    cells.cost:SetTextColor(Theme.Unpack(line.overpaid and "warn" or "text"))

    -- The Queue tab's rule: an auction search for anything still short,
    -- unless a vendor that never runs out sells it. A vendor with limited
    -- stock may run dry, and an item never priced may still be listed
    -- (a player found no AH button on Mageroyal, 2026-10-14).
    row.search:SetShown(not line.fromVendor or line.vendorLimited == true)
    row.goal:SetShown(ns.FarmerGoals:Available())
end

local function ShowRowTooltip(row, line)
    ns.Widgets.ShowItemTooltip(row, "ANCHOR_RIGHT", line.itemID, line.label)
    GameTooltip:AddLine(" ")

    GameTooltip:AddDoubleLine(L["Required"], tostring(line.needed), 0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddDoubleLine(L["In bags"], tostring(line.inBags or 0), 0.7, 0.7, 0.7, 1, 1, 1)

    if (line.inBank or 0) > 0 then
        GameTooltip:AddDoubleLine(L["In bank"], tostring(line.inBank),
            0.7, 0.7, 0.7, 0.91, 0.76, 0.35)
    end

    if line.shortfall > 0 then
        GameTooltip:AddDoubleLine(L["Still needed"], tostring(line.shortfall),
            0.7, 0.7, 0.7, 0.9, 0.38, 0.31)
    end

    GameTooltip:AddLine(" ")

    -- The whole point of the tab: show both prices, not just the winner.
    if line.vendorUnit then
        GameTooltip:AddDoubleLine(L["Vendor, each"],
            Util.FormatMoney(line.vendorUnit, { noColor = true }),
            0.7, 0.7, 0.7, 0.78, 0.64, 0.30)
    else
        GameTooltip:AddLine(L["No vendor known to sell this"], 0.5, 0.5, 0.5)
    end

    if line.auctionUnit then
        GameTooltip:AddDoubleLine(L["Auction, each"],
            Util.FormatMoney(line.auctionUnit, { noColor = true }),
            0.7, 0.7, 0.7, 1, 1, 1)
    else
        GameTooltip:AddLine(L["Not seen on the auction house"], 0.5, 0.5, 0.5)
    end

    -- Too few at the cheapest price: the rest cost more, up the listings.
    if line.source == "auction" and line.auctionUnit and line.unitCost
        and line.unitCost > line.auctionUnit and line.shortfall > 0 then
        GameTooltip:AddDoubleLine(L.Format("Buying %d, each on average", line.shortfall),
            Util.FormatMoney(line.unitCost, { noColor = true }),
            0.7, 0.7, 0.7, 1, 1, 1)
    end

    if line.savingTotal and line.savingTotal > 0 then
        GameTooltip:AddDoubleLine(
            line.source == "auction" and L["Saved by buying from the auction house"]
                or line.source == "vendor" and L["Saved by buying from the vendor"]
                or L.Format("Saved by buying from the %s", tostring(line.source)),
            Util.FormatMoney(line.savingTotal, { noColor = true }),
            0.7, 0.7, 0.7, 0.31, 0.82, 0.55)
    end

    if line.vendorLimited then
        GameTooltip:AddLine(L["Vendor stock is limited"], 0.91, 0.76, 0.35)
    end

    if (line.onAlts or 0) > 0 then
        GameTooltip:AddDoubleLine(L["On other characters"], tostring(line.onAlts),
            0.7, 0.7, 0.7, 0.91, 0.76, 0.35)
    end

    if UI.AddPaidLines then UI.AddPaidLines(line) end

    -- How fast you farm it, from Blackthornes Farmer (your own kills and
    -- gathers only, the Your time view's call; 2026-10-16).
    local CraftOrFarm, YourTime = ns.CraftOrFarm, ns.YourTimeView
    if CraftOrFarm and CraftOrFarm:HasFarmer() and YourTime and YourTime.PaceText then
        local pace, samples = CraftOrFarm:PaceOf(line.itemID)
        if pace or (samples or 0) > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine(L["Farming it"], YourTime.PaceText({ pace = pace, samples = samples }),
                0.7, 0.7, 0.7, 1, 1, 1)
            if pace and line.shortfall > 0 then
                GameTooltip:AddDoubleLine(L.Format("The %d you still need", line.shortfall),
                    L.Format("About %s", YourTime.Duration(pace.seconds * line.shortfall)),
                    0.7, 0.7, 0.7, 0.78, 0.64, 0.30)
            end
        end
    end

    GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

local function Refresh()
    if not widgets.list then return end

    local lines, all = BuildList()
    -- A clicked heading's order over the menu's.
    if widgets.sorter then lines = widgets.sorter:Sort(lines) end
    widgets.list:SetData(lines)

    widgets.emptyLabel:SetShown(#lines == 0)
    if #lines == 0 then
        widgets.emptyLabel:SetText(ns.Queue:Count() == 0
            and L["Nothing queued.\nAdd crafts on the Profit tab and their materials appear here."]
            or L["You already have everything the queue needs."])
    end

    -- From the list already built, satisfied lines and all, rather than
    -- building it a second time.
    local summary = ns.Queue:GetGatherSummary(all)

    widgets.progress:SetText(L.Format("%d of %d materials still needed",
        summary.outstanding, summary.outstanding + summary.satisfied))

    -- Split by destination, because that is how you actually do the errand.
    widgets.vendorTotal:SetText(summary.vendor.count > 0
        and L.Format(summary.vendor.count == 1 and L["Vendor  %s   (%d item)"] or L["Vendor  %s   (%d items)"],
            Util.FormatMoney(summary.vendor.cost, { short = true }),
            summary.vendor.count)
        or L["Vendor  --"])

    widgets.auctionTotal:SetText(summary.auction.count > 0
        and L.Format(summary.auction.count == 1 and L["Auction  %s   (%d item)"] or L["Auction  %s   (%d items)"],
            Util.FormatMoney(summary.auction.cost, { short = true }),
            summary.auction.count)
        or L["Auction  --"])

    widgets.grandTotal:SetText(L.Format("Total  %s",
        Util.FormatMoney(summary.total, { short = true })))

    if summary.saving > 0 then
        widgets.savingLabel:SetText(L.Format("Buying from the cheaper source saves %s",
            Util.FormatMoney(summary.saving, { short = true })))
    else
        widgets.savingLabel:SetText("")
    end

    -- Unknown prices make the total an understatement, so say so.
    widgets.unknownLabel:SetText(summary.unknown.count > 0
        and L.Format(summary.unknown.count == 1 and L["%d material with no price data, so the real total is higher"]
            or L["%d materials with no price data, so the real total is higher"],
            summary.unknown.count)
        or "")

    -- Vendor prices ship with the addon now (Data/VendorPrices.lua), so there
    -- is no longer a "visit a vendor first" note to show.
    widgets.vendorNote:SetText("")
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function Build(container)
    -- Room for the Set goal button beside AH, only when Farmer is there to take it.
    COLUMNS[1].width = ns.FarmerGoals:Available() and 88 or 30
    COLUMNS[1].baseWidth = COLUMNS[1].width
    -- Then before any row or heading is laid out: they read these widths.
    if Widgets.FitColumns then Widgets.FitColumns(COLUMNS) end

    local toolbar = CreateFrame("Frame", nil, container)
    toolbar:SetPoint("TOPLEFT", 8, -8)
    toolbar:SetPoint("TOPRIGHT", -8, -8)
    toolbar:SetHeight(24)

    -- The menu first, then the tick box, as on every tab. It stays: it
    -- groups the list by where to buy, which a heading cannot.
    local sort = Widgets.CreateDropdown(toolbar, {
        { text = L["Group: Where to buy"], value = "source" },
        { text = L["Sort: Cost"], value = "cost" },
        { text = L["Sort: Name"], value = "name" },
    }, function(value)
        state.sortBy = value
        Refresh()
    end, { width = 150 })
    sort:SetPoint("LEFT", 0, 0)
    sort:SetValue("source")

    local hideSatisfied = Widgets.CreateCheckbox(toolbar, L["Hide what I have"], function(checked)
        state.hideSatisfied = checked
        Refresh()
    end, true)
    hideSatisfied:SetPoint("LEFT", sort, "RIGHT", 12, 0)

    -- With Blackthornes Farmer loaded: every material still needed becomes a
    -- Farmer goal in one click, in the order the list shows them.
    if ns.FarmerGoals:Available() then
        local setAll = Widgets.CreateButton(toolbar, L["Set all goals"], function()
            local needed = {}
            for _, line in ipairs(BuildList()) do
                if line.shortfall > 0 then needed[#needed + 1] = line end
            end
            ns.FarmerGoals:SetGoals(needed)
        end, { width = 100, height = 22,
            tooltip = L["Make a Blackthornes Farmer goal for every material you still need"] })
        setAll:SetPoint("RIGHT", 0, 0)
    end

    -- Column headings
    local headings = CreateFrame("Frame", nil, container)
    headings:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -8)
    headings:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -8)
    headings:SetHeight(16)

    local nameHeading = Theme.CreateLabel(headings, "tiny", "muted")
    nameHeading:SetPoint("LEFT", 30, 0)
    nameHeading:SetText(L["MATERIAL"])

    local sortLabels, cells = { name = nameHeading }, {}
    for _, column in ipairs(COLUMNS) do
        if column.label ~= "" then
            local heading = Theme.CreateLabel(headings, "tiny", "muted", column.justify or "RIGHT")
            heading:SetText(column.label)
            sortLabels[column.key] = heading
            cells[column.key] = heading
        end
    end
    ns.Columns:Place("gather", COLUMNS, cells)

    -- Click a heading to sort by it.
    widgets.sorter = Widgets.SortableHeadings and Widgets.SortableHeadings(sortLabels, {
        name = function(line)
            local label = line.label or ""
            return label:match("%[(.-)%]") or label
        end,
        cost = function(line) return line.estimatedCost end,
        unit = function(line) return line.unitCost end,
        source = function(line) return SOURCE_LABELS[line.source] or line.source end,
        have = function(line) return line.have end,
        need = function(line) return line.needed end,
    }, function() Refresh() end)
    if widgets.sorter then widgets.sorter:SetText({ "name", "source" }) end

    -- Right-click the headings to choose the columns.
    ns.Columns:Attach(headings, "gather", widgets.sorter)
    ns.Columns:OnChange("gather", function()
        ns.Columns:Place("gather", COLUMNS, cells)
        if widgets.sorter then widgets.sorter:Sync() end
        if widgets.list then widgets.list:Refresh() end
    end)

    local divider = Theme.CreateDivider(container, "borderLit")
    divider:SetPoint("TOPLEFT", headings, "BOTTOMLEFT", 0, -2)
    divider:SetPoint("TOPRIGHT", headings, "BOTTOMRIGHT", 0, -2)

    local list = Widgets.CreateScrollList(container, {
        -- The headings move in with the rows when the scrollbar takes its room.
        onScrollbarShown = function(shown)
            headings:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", -(shown and 10 or 0), -8)
        end,
        rowHeight = ROW_HEIGHT,
        createRow = CreateRow,
        updateRow = UpdateRow,
        onEnter = ShowRowTooltip,
        onLeave = function() GameTooltip:Hide() end,
    })
    list:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -4)
    list:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -8, 86)
    widgets.list = list

    local emptyLabel = Theme.CreateLabel(container, "small", "dim", "CENTER")
    emptyLabel:SetPoint("CENTER", list, "CENTER")
    emptyLabel:SetWidth(360)
    emptyLabel:SetWordWrap(true)
    widgets.emptyLabel = emptyLabel

    -- Footer
    local footerDivider = Theme.CreateDivider(container)
    footerDivider:SetPoint("BOTTOMLEFT", 8, 78)
    footerDivider:SetPoint("BOTTOMRIGHT", -8, 78)

    widgets.progress = Theme.CreateLabel(container, "small", "text")
    widgets.progress:SetPoint("BOTTOMLEFT", 10, 58)

    widgets.vendorTotal = Theme.CreateLabel(container, "small", "accent")
    widgets.vendorTotal:SetPoint("BOTTOMLEFT", 10, 38)

    widgets.auctionTotal = Theme.CreateLabel(container, "small", "text")
    widgets.auctionTotal:SetPoint("BOTTOMLEFT", 220, 38)

    -- In gold, like the other headline figures: it is the answer here.
    widgets.grandTotal = Theme.CreateLabel(container, "small", "accent")
    widgets.grandTotal:SetPoint("BOTTOMLEFT", 430, 38)

    widgets.savingLabel = Theme.CreateLabel(container, "tiny", "profit")
    widgets.savingLabel:SetPoint("BOTTOMLEFT", 10, 22)

    widgets.unknownLabel = Theme.CreateLabel(container, "tiny", "warn")
    widgets.unknownLabel:SetPoint("BOTTOMLEFT", 10, 8)

    widgets.vendorNote = Theme.CreateLabel(container, "tiny", "dim")
    widgets.vendorNote:SetPoint("BOTTOMLEFT", 430, 22)
    widgets.vendorNote:SetPoint("BOTTOMRIGHT", -10, 22)

    -- A name drawn before the client had its item gets its rarity colour when
    -- the item arrives: the rows on screen again, once for a burst, only
    -- while a row waits and the list shows.
    local redrawQueued = false
    ns.RegisterEvent(widgets, "GET_ITEM_INFO_RECEIVED", function()
        if redrawQueued or not state.waiting or not list:IsVisible() then return end
        redrawQueued = true
        C_Timer.After(0.2, function()
            redrawQueued = false
            state.waiting = false
            if list:IsVisible() then list:Refresh() end
        end)
    end)
end

UI:RegisterTab({
    key = "gather",
    text = L["Gather"],
    order = 3,
    build = Build,
    refresh = Refresh,
})
