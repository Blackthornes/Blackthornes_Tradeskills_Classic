-- Blackthornes Tradeskills -- UI/Tab_Sales.lua
-- What actually sold, and what came back.
--
-- Every other tab in this addon is a forecast: the Profit tab says what a craft
-- ought to earn, the Post tab says what to list it at. This one is the only
-- record of what the auction house really paid, which is the number those
-- forecasts are being judged against.
--
-- It reads Data/Mail.lua's ledger and adds nothing to it. The ledger is written
-- when the mailbox is opened, so an empty tab means "you have not been to a
-- mailbox", not "nothing sold" -- and it says so rather than showing a blank
-- list and leaving that to be worked out.
--
-- Two views, because the ledger answers two different questions. "Recent" is
-- the event list: this sold, then that expired. "By item" is the one that tells
-- you whether a craft is worth making again -- how many sold, how many came
-- back, and what the two together say about the price.
--
-- The split matters for a second reason. History from before the client was
-- last closed survives as a per-item rollup rather than as individual sales
-- (see Mail:GetRestoredRollup), so it can appear in the By item view and in the
-- totals but never in a list of events. Rather than let that read as sales
-- going missing, the Recent view says how many are being held back and where
-- to find them.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local UI = ns.UI

local ROW_HEIGHT = 34
local DETAIL_WIDTH = 300

local VIEWS = {
    { text = L["Recent sales"],   value = "sales" },
    { text = L["Recent, all"],    value = "all" },
    { text = L["Still listed"],   value = "listed" },
    { text = L["By item"],        value = "item" },
    { text = L["Profit by method"], value = "methods" },
    { text = L["Mailbox visits"], value = "visits" },
    { text = L["Gold in and out"], value = "gold" },
}

local state = { view = "sales", search = "", selected = nil, period = "week", who = "all" }

-- Whose gold the line over Gold in and out follows (a player asked, the
-- owner said yes from a mockup, 2026-10-22). All characters by default: it
-- reaches back as far as the log does, while the character playing's line
-- starts from the day its gold was first written down.
local WHO = {
    { key = "character", text = L["This character"] },
    { key = "all",       text = L["All characters"] },
}
local widgets = {}

--------------------------------------------------------------------------------
-- Item names
--------------------------------------------------------------------------------

-- Rows whose item the client had not sent yet when they were drawn. Item data
-- arrives on its own schedule, so the first pass over an item the client has
-- never seen gets no rarity colour back; GET_ITEM_INFO_RECEIVED redraws those
-- once it has them. Same hole, and the same fix, as UI/Tab_Profit.lua.
local awaitingItemData = false

--- What to call one ledger row's item.
--
-- An entry always has one of the two: an itemID resolved from the invoice's
-- name, or failing that the name itself. A sale of something the addon has no
-- recipe for is still a sale, so the name is shown rather than the row dropped.
local function ItemLabel(itemID, name)
    if itemID then return Util.GetItemLabel(itemID) end
    return name or L["unknown item"]
end

--- Colour a name by the rarity of the item, where the client knows it.
local function ApplyNameColor(label, itemID)
    local r, g, b = Util.GetItemQualityColor(itemID)

    if r then
        label:SetTextColor(r, g, b)
        return
    end

    label:SetTextColor(Theme.Unpack("text"))
    if itemID then awaitingItemData = true end
end

--- Does this row match what has been typed in the search box?
local function Matches(itemID, name, query)
    if query == "" then return true end

    local haystack = (name or ""):lower()

    -- The item is only looked up when the entry carries no name: reading
    -- every ledger entry through the client on each keystroke pulled items
    -- into its small cache and pushed bag items out.
    if itemID and (name or "") == "" then
        -- GetItemLabel hands back a link once the client has the item, and a
        -- link carries the name inside it, so searching the label works for
        -- both shapes without having to take the link apart.
        -- Only the name inside the link: its colour code and item number
        -- matched "ff" or a digit on every row.
        local label = tostring(Util.GetItemLabel(itemID))
        haystack = haystack .. " " .. (label:match("%[(.-)%]") or label):lower()
    end

    return haystack:find(query, 1, true) ~= nil
end

--------------------------------------------------------------------------------
-- Profit
--------------------------------------------------------------------------------

-- What each sale made over what the item cost (Logic/CraftedCost.lua). Asked
-- by two players on 2026-10-06. Worked out on each draw, never written into
-- the ledger, so a cost learned later still reaches older sales.

-- One lookup per draw: which recipe makes an item and today's cost of it.
local saleCosts

--- "+1g 20s" in green, "-40s" in red, coins left plain so the sign reads.
local function SignedMoney(copper)
    local sign = copper > 0 and "+" or ""
    return ("|c%s%s%s|r"):format(ns.COLORS[copper < 0 and "loss" or "profit"], sign,
        Util.FormatMoney(copper, { short = true, noColor = true }))
end

--- What one ledger sale made, or nil.
-- @return profit, cost, source ("made" | "est")
local function EntryProfit(entry)
    if not ns.CraftedCost or not ns.CraftedCost.SaleProfit then return nil end
    saleCosts = saleCosts or ns.CraftedCost:NewSaleCache()
    local itemID = entry.itemID or (state.names and entry.name and state.names[entry.name])
    return ns.CraftedCost:SaleProfit(entry, itemID, saleCosts)
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

-- One row layout serves both views: a name and a figure on the top line, and a
-- line of context under it. What goes in each is all that changes, so the two
-- views cannot drift apart in how they look.
local function CreateRow(row)
    -- The item's icon beside both lines, as the bags draw it.
    row.icon = Theme.CreateItemIcon(row, 24)
    row.icon:SetPoint("LEFT", 8, 0)

    -- A method's heading folds its items away, in the icon's place.
    row.fold = row:CreateTexture(nil, "ARTWORK")
    row.fold:SetSize(14, 14)
    row.fold:SetPoint("LEFT", 13, 0)
    row.fold:Hide()

    row.name = Theme.CreateLabel(row, "normal", "text")
    row.name:SetPoint("TOPLEFT", 40, -4)
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -130, -4)
    row.name:SetJustifyH("LEFT")

    row.amount = Theme.CreateLabel(row, "normal", "text", "RIGHT")
    row.amount:SetPoint("TOPRIGHT", -12, -4)
    row.amount:SetWidth(115)

    row.detail = Theme.CreateLabel(row, "tiny", "muted")
    row.detail:SetPoint("TOPLEFT", 40, -19)
    row.detail:SetPoint("TOPRIGHT", row, "TOPRIGHT", -130, -19)
    row.detail:SetJustifyH("LEFT")

    row.when = Theme.CreateLabel(row, "tiny", "dim", "RIGHT")
    row.when:SetPoint("TOPRIGHT", -12, -19)
    row.when:SetWidth(115)
end

--- One event: a listing that sold, expired, or that you pulled.
local function UpdateEventRow(row, entry)
    row.name:SetText(ItemLabel(entry.itemID, entry.name))
    ApplyNameColor(row.name, entry.itemID)

    if entry.kind == "heard" then
        -- Announced in chat while you were online. Its price arrives with
        -- its mail, and the row gives way to the ledger's entry then.
        row.amount:SetText(L["sold"])
        row.amount:SetTextColor(Theme.Unpack("profit"))

        local who = Util.CharacterName(entry.who)
        row.detail:SetText(who ~= "" and L.Format("sold  ·  gold waiting in the mail  ·  %s", who)
            or L["sold  ·  gold waiting in the mail"])
        row.detail:SetTextColor(Theme.Unpack("warn"))
    elseif entry.kind == "sold" then
        row.amount:SetText(Util.FormatMoney(entry.net))
        row.amount:SetTextColor(Theme.Unpack("profit"))

        local parts = {}

        -- Only ever shown when the ledger genuinely recorded one. A sale
        -- leaves no attachment behind, so the quantity is usually unknown,
        -- and printing "1" for a stack of twenty would be a number this tab
        -- states with confidence and gets wrong.
        if entry.quantity and entry.quantity > 1 then
            parts[#parts + 1] = L.Format("%d sold", entry.quantity)
        else
            parts[#parts + 1] = L["sold"]
        end

        local profit, cost, source = EntryProfit(entry)

        -- The cut gives way to the profit, which already takes it off: the
        -- line has room for one or the other, not both.
        if not profit and entry.cut and entry.cut > 0 then
            parts[#parts + 1] = L.Format("cut %s",
                Util.FormatMoney(entry.cut, { short = true, noColor = true }))
        end

        if entry.estimated then
            parts[#parts + 1] = L["gold still held"]
        end

        if profit then
            local costText = Util.FormatMoney(cost, { short = true, noColor = true })
            parts[#parts + 1] = source == "est" and L.Format("cost %s est.", costText) or L.Format("cost %s", costText)
            parts[#parts + 1] = L.Format("profit %s", SignedMoney(profit))
        end

        row.detail:SetText(table.concat(parts, "  ·  "))
        row.detail:SetTextColor(Theme.Unpack(entry.estimated and "warn" or "muted"))
    else
        -- Nothing was earned, so the column stays empty rather than saying
        -- zero: a zero here would read as a sale that paid nothing, which is
        -- exactly the bug the ledger already had once.
        row.amount:SetText("")

        local quantity = entry.quantity or 1
        local what = entry.kind == "removed" and L["you cancelled it"] or L["expired, nobody bought it"]
        row.detail:SetText(quantity > 1 and L.Format("%dx %s", quantity, what) or what)
        row.detail:SetTextColor(Theme.Unpack(entry.kind == "removed" and "muted" or "loss"))
    end

    row.when:SetText(Util.FormatAgeAgo(entry.t and (time() - entry.t)))
    row.when:SetTextColor(Theme.Unpack("dim"))
end

--- One item, everything the ledger holds about it rolled together.
local function UpdateItemRow(row, item)
    row.name:SetText(ItemLabel(item.itemID, item.name))
    ApplyNameColor(row.name, item.itemID)

    row.amount:SetText(Util.FormatMoney(item.net, { short = true }))
    row.amount:SetTextColor(Theme.Unpack(item.net > 0 and "profit" or "muted"))

    local parts = {}

    -- Units rather than listings, because a listing is not a useful unit of
    -- anything -- except that a sale's quantity is usually unknown, so the two
    -- are the same number more often than not and saying "sold" twice would
    -- be noise.
    parts[#parts + 1] = L.Format("%d sold", item.sold)

    if item.expired > 0 then
        parts[#parts + 1] = L.Format("%d expired", item.expired)
    end

    if item.cancelled > 0 then
        parts[#parts + 1] = L.Format("%d cancelled", item.cancelled)
    end

    if item.costed + item.guessed > 0 then
        parts[#parts + 1] = item.guessed > 0 and L.Format("profit %s est.", SignedMoney(item.profit))
            or L.Format("profit %s", SignedMoney(item.profit))
    end

    row.detail:SetText(table.concat(parts, "  ·  "))
    row.detail:SetTextColor(Theme.Unpack("muted"))

    if item.sellThrough then
        row.when:SetText(L.Format("%d%% sold through",
            math.floor(item.sellThrough * 100 + 0.5)))
        row.when:SetTextColor(Theme.ProfitColor(item.sellThrough >= 0.5 and 1 or -1))
    else
        row.when:SetText(Util.FormatAgeAgo(item.lastAt and (time() - item.lastAt)))
        row.when:SetTextColor(Theme.Unpack("dim"))
    end
end

--- How long until a listing ends, or that it has.
local function EndsText(listing)
    if listing.ended then return L["ended"], "warn" end
    if not listing.ends then return "", "dim" end

    local left = listing.ends - time()
    local text = Util.FormatAge(left)
    if text == L["just now"] then text = "1m" end
    return listing.roughEnd and L.Format("ends within %s", text) or L.Format("ends in %s", text), "dim"
end

--- One listing from a character's last auction house reading.
local function UpdateListingRow(row, listing)
    row.name:SetText(ItemLabel(listing.itemID, nil))
    ApplyNameColor(row.name, listing.itemID)

    if listing.unit then
        row.amount:SetText(Util.FormatMoney(listing.unit * (listing.quantity or 1), { short = true }))
        row.amount:SetTextColor(Theme.Unpack(listing.ended and "muted" or "text"))
    else
        row.amount:SetText("")
    end

    local parts = { L.Format("%d listed", listing.quantity or 1) }
    if listing.unit and (listing.quantity or 1) > 1 then
        parts[#parts + 1] = L.Format("%s each",
            Util.FormatMoney(listing.unit, { short = true, noColor = true }))
    end
    if listing.ended then
        parts[#parts + 1] = L["sold or back in the mail"]
    end
    local who = Util.CharacterName(listing.who)
    if who ~= "" then parts[#parts + 1] = who end

    row.detail:SetText(table.concat(parts, "  ·  "))
    row.detail:SetTextColor(Theme.Unpack(listing.ended and "warn" or "muted"))

    local text, color = EndsText(listing)
    row.when:SetText(text)
    row.when:SetTextColor(Theme.Unpack(color))
end

--- One mailbox visit: what was collected, and the best sale in it.
local function UpdateVisitRow(row, haul)
    local best = haul.best

    Theme.SetItemIcon(row.icon, best and best.itemID)

    local head = L.Format("Collected %s", Util.FormatMoney(haul.total, { short = true }))
    if haul.recordHaul then head = head .. L.Format("  |c%sbest haul|r", ns.COLORS.accent) end
    row.name:SetText(head)
    row.name:SetTextColor(Theme.Unpack("text"))

    row.amount:SetText(Util.FormatMoney(haul.total, { short = true }))
    row.amount:SetTextColor(Theme.Unpack("accent"))

    local parts = {}
    if (haul.salesCount or 0) > 0 then
        parts[#parts + 1] = haul.salesCount == 1 and L.Format("%d sale", haul.salesCount) or L.Format("%d sales", haul.salesCount)
    end
    if best then
        parts[#parts + 1] = L.Format("best %s %s", best.name or L["item"],
            Util.FormatMoney(best.amount, { short = true, noColor = true }))
    end
    if (haul.itemCount or 0) > 0 then
        parts[#parts + 1] = haul.itemCount == 1 and L.Format("%d item", haul.itemCount) or L.Format("%d items", haul.itemCount)
    end

    local who = Util.CharacterName(haul.who)
    if who ~= "" then parts[#parts + 1] = who end

    row.detail:SetText(table.concat(parts, "  ·  "))
    row.detail:SetTextColor(Theme.Unpack("muted"))

    row.when:SetText(Util.FormatAgeAgo(haul.t and (time() - haul.t)))
    row.when:SetTextColor(Theme.Unpack("dim"))
end

--- What a group of sales made, for the line under a name.
local function MethodDetail(group, unit)
    local parts = {
        L.Format(unit, group.n),
        L.Format("in %s", Util.FormatMoney(group.income, { short = true, noColor = true })),
    }
    if group.cost > 0 then
        parts[#parts + 1] = L.Format("cost %s", Util.FormatMoney(group.cost, { short = true, noColor = true }))
    end
    if group.unknown > 0 then
        parts[#parts + 1] = group.unknown == group.n and L["cost not known"]
            or L.Format("%d with no cost known", group.unknown)
    end
    return table.concat(parts, "  ·  ")
end

-- "%d sold" and the like: how a method's count reads.
local METHOD_UNITS = {
    crafted = L["%d sold"], flipped = L["%d sold"], other = L["%d sold"],
    vendored = L["%d sold to vendors"], disenchanted = L["%d disenchanted"],
}

--- Profit by method's folded headings, from the setting kept as "a,b".
local function FoldedMethods()
    local folded = {}
    local saved = ns.Config and ns.Config.Get and ns.Config:Get("salesMethodsFolded")
    for key in tostring(type(saved) == "string" and saved or ""):gmatch("[^,]+") do folded[key] = true end
    return folded
end

--- Fold a method's heading or open it again, kept for next time.
local function ToggleMethod(key)
    local folded = FoldedMethods()
    folded[key] = not folded[key] or nil
    local keys = {}
    for method in pairs(folded) do keys[#keys + 1] = method end
    table.sort(keys)
    if ns.Config and ns.Config.Set then ns.Config:Set("salesMethodsFolded", table.concat(keys, ",")) end
end

--- A method's heading: its profit, and what it is made of.
local function UpdateMethodRow(row, data)
    Theme.SetItemIcon(row.icon, nil)
    row.fold:Show()
    pcall(row.fold.SetTexture, row.fold, data.folded
        and [[Interface\Buttons\UI-PlusButton-Up]] or [[Interface\Buttons\UI-MinusButton-Up]])

    row.name:SetText(data.method.text)
    row.name:SetTextColor(Theme.Unpack("accent"))

    row.amount:SetText(SignedMoney(data.group.profit))
    row.detail:SetText(MethodDetail(data.group, METHOD_UNITS[data.method.key] or L["%d sold"]))
    row.detail:SetTextColor(Theme.Unpack("muted"))

    row.when:SetText(data.method.hint)
    row.when:SetTextColor(Theme.Unpack("dim"))
end

--- One item under its method.
local function UpdateMethodItemRow(row, data)
    Theme.SetItemIcon(row.icon, data.itemID)

    row.name:SetText(data.itemID and ItemLabel(data.itemID) or L["unknown item"])
    ApplyNameColor(row.name, data.itemID)

    row.amount:SetText(SignedMoney(data.item.profit))
    row.detail:SetText(MethodDetail(data.item, METHOD_UNITS[data.key] or L["%d sold"]))
    row.detail:SetTextColor(Theme.Unpack("muted"))
    row.when:SetText("")
end

local function UpdateRow(row, data)
    row.fold:SetShown(data.methodRow and true or false)
    if data.haul then
        UpdateVisitRow(row, data)
        return
    end

    if data.methodRow then
        UpdateMethodRow(row, data)
        return
    end

    if data.methodItem then
        UpdateMethodItemRow(row, data)
        return
    end

    Theme.SetItemIcon(row.icon, data.itemID)
    if data.listing then
        UpdateListingRow(row, data)
    elseif data.kind then
        UpdateEventRow(row, data)
    else
        UpdateItemRow(row, data)
    end
end

--------------------------------------------------------------------------------
-- Detail
--------------------------------------------------------------------------------

local LINE_COUNT = 13

local function BuildDetail(parent)
    local detail = Theme.CreatePanel(parent, "window")
    -- The gold edge every other detail pane has.
    Theme.AccentStripe(detail, 2, 0.6)
    detail:SetWidth(DETAIL_WIDTH)

    -- The item's charts on the Stats tab (UI/Tab_Stats.lua), as the Prices
    -- tab has it; shown only while one item is picked.
    detail.stats = Widgets.CreateButton(detail, L["Stats"], function()
        if detail.statsItem and ns.StatsUI then ns.StatsUI:ShowItem(detail.statsItem) end
    end, { width = 50, height = 20, tooltip = L["See this item's charts on the Stats tab"] })
    detail.stats:SetPoint("TOPRIGHT", -8, -9)
    detail.stats:Hide()

    local title = Theme.CreateLabel(detail, "large", "accent")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetPoint("TOPRIGHT", -12, -12)
    detail.title = title

    local subtitle = Theme.CreateLabel(detail, "small", "muted")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    subtitle:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -12, 0)
    detail.subtitle = subtitle

    detail.lines = {}
    local anchor = subtitle

    for index = 1, LINE_COUNT do
        local line = CreateFrame("Frame", nil, detail)
        line:SetHeight(16)
        line:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, index == 1 and -12 or 0)
        line:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -12, 0)

        line.label = Theme.CreateLabel(line, "small", "muted")
        line.label:SetPoint("LEFT", 0, 0)
        line.label:SetPoint("RIGHT", -110, 0)

        line.value = Theme.CreateLabel(line, "small", "text", "RIGHT")
        line.value:SetPoint("RIGHT", 0, 0)
        line.value:SetWidth(106)

        detail.lines[index] = line
        anchor = line
    end

    local note = Theme.CreateLabel(detail, "tiny", "dim")
    note:SetPoint("BOTTOMLEFT", 12, 14)
    note:SetPoint("BOTTOMRIGHT", -12, 14)
    note:SetWordWrap(true)
    note:SetJustifyH("LEFT")
    detail.note = note

    return detail
end

--- Fill the panel's fixed set of lines, hiding the ones this subject does not
--- need. Written as a list rather than as named fields so the two subjects --
--- one item, or everything -- can each say what is worth saying about them.
local function SetLines(detail, lines)
    for index, line in ipairs(detail.lines) do
        local content = lines[index]

        if content then
            line.label:SetText(content[1])
            line.value:SetText(content[2])
            line.value:SetTextColor(Theme.Unpack(content[3] or "text"))
            line:Show()
        else
            line:Hide()
        end
    end
end

--- What the Profit tab reckons one of these is worth, for comparison.
--
-- The whole point of keeping a ledger: the forecast said one thing and the
-- auction house paid another. Nil when the addon has no recipe for the item,
-- which is normal for anything bought rather than crafted.
local function EstimatedUnitRevenue(itemID)
    if not itemID or not ns.Recipes or not ns.Profit then return nil end

    for recipeID, recipe in pairs(ns.Recipes:GetAll()) do
        if recipe.outputItemID == itemID then
            local analysis = ns.Profit:Analyse(recipe.recipeID or recipeID)
            if analysis and analysis.priceable then return analysis.unitRevenue end
            return nil
        end
    end

    return nil
end

--- The profit lines for one item or for everything: the total, and how many
--- of the sales it covers when some could not be costed.
local function AddProfitLines(Add, subject)
    local counted = subject.costed + subject.guessed
    if counted == 0 then
        if subject.sold > 0 then Add(L["Profit"], L["cost not known"], "muted") end
        return
    end

    Add(subject.guessed > 0 and L["Profit (some est.)"] or L["Profit"],
        SignedMoney(subject.profit), subject.profit < 0 and "loss" or "profit")

    if counted < subject.sold then
        Add(L["Costed sales"], L.Format("%d of %d", counted, subject.sold), "muted")
    elseif counted > 1 then
        Add(L["Profit per sale"], SignedMoney(subject.profit / counted),
            subject.profit < 0 and "loss" or "profit")
    end
end

--- The Stats button for one item, and room for it beside the title.
local function ShowStatsButton(detail, itemID)
    detail.statsItem = itemID
    detail.stats:SetShown(itemID ~= nil)
    detail.title:ClearAllPoints()
    detail.title:SetPoint("TOPLEFT", 12, -12)
    if itemID then
        detail.title:SetPoint("TOPRIGHT", detail.stats, "TOPLEFT", -6, -3)
    else
        detail.title:SetPoint("TOPRIGHT", -12, -12)
    end
end

local function UpdateDetail(item, totals)
    local detail = widgets.detail
    local lines = {}

    local function Add(label, value, color)
        lines[#lines + 1] = { label, value, color }
    end

    ShowStatsButton(detail, item and item.itemID)

    if item then
        detail.title:SetText(ItemLabel(item.itemID, item.name))
        detail.subtitle:SetText(item.lastAt
            and L.Format("last ended %s", Util.FormatAgeAgo(time() - item.lastAt))
            or L["nothing dated"])

        Add(L["Sold"], (item.sold == 1 and L.Format("%d listing", item.sold) or L.Format("%d listings", item.sold)))

        if item.soldUnits > item.sold then
            Add(L["Units sold"], tostring(item.soldUnits))
        end

        Add(L["Expired"], (item.expired == 1 and L.Format("%d listing", item.expired) or L.Format("%d listings", item.expired)),
            item.expired > 0 and "loss" or "muted")

        if item.cancelled > 0 then
            Add(L["You cancelled"], (item.cancelled == 1 and L.Format("%d listing", item.cancelled) or L.Format("%d listings", item.cancelled)), "muted")
        end

        if item.sellThrough then
            Add(L["Sell-through"], ("%d%%"):format(math.floor(item.sellThrough * 100 + 0.5)),
                item.sellThrough >= 0.5 and "profit" or "loss")
        end

        if item.sold > 0 then
            Add(L["Taken in"], Util.FormatMoney(item.net), "profit")
            Add(L["Average per sale"], Util.FormatMoney(item.net / item.sold))

            if item.cut > 0 then
                Add(L["Auction cut"], Util.FormatMoney(item.cut), "muted")
            end

            AddProfitLines(Add, item)

            local estimate = EstimatedUnitRevenue(item.itemID)
            if estimate then
                Add(L["Profit tab says"], L.Format("%s a unit",
                    Util.FormatMoney(estimate, { short = true })), "muted")
            end

            if item.estimated > 0 then
                Add(L["Still being paid"], item.estimated == 1 and L.Format("%d sale", item.estimated)
                    or L.Format("%d sales", item.estimated), "warn")
            end
        end

        if item.restored then
            detail.note:SetText(L["The auction cut and cancellations here are from this session only."])
        elseif item.guessed > 0 then
            detail.note:SetText(L["A cost marked est. is what the materials cost today."])
        elseif item.soldUnits == item.sold and item.sold > 0 then
            detail.note:SetText(L["Each sale counts as one, even a whole stack."])
        else
            detail.note:SetText("")
        end
    else
        detail.title:SetText(L["Everything"])
        detail.subtitle:SetText(ns.Config:GetRealmKey())

        Add(L["Items sold"], (totals.sold == 1 and L.Format("%d listing", totals.sold) or L.Format("%d listings", totals.sold)))
        Add(L["Expired"], (totals.expired == 1 and L.Format("%d listing", totals.expired) or L.Format("%d listings", totals.expired)),
            totals.expired > 0 and "loss" or "muted")

        if totals.cancelled > 0 then
            Add(L["You cancelled"], (totals.cancelled == 1 and L.Format("%d listing", totals.cancelled) or L.Format("%d listings", totals.cancelled)), "muted")
        end

        if totals.sellThrough then
            Add(L["Sell-through"], ("%d%%"):format(math.floor(totals.sellThrough * 100 + 0.5)),
                totals.sellThrough >= 0.5 and "profit" or "loss")
        end

        if totals.sold > 0 then
            Add(L["Taken in"], Util.FormatMoney(totals.net), "profit")
            Add(L["Average per sale"], Util.FormatMoney(totals.net / totals.sold))

            if totals.cut > 0 then
                Add(L["Auction cut"], Util.FormatMoney(totals.cut), "muted")
            end

            AddProfitLines(Add, totals)
        end

        Add(L["Different items"], tostring(totals.items), "muted")

        local age = ns.Mail:GetAge()
        Add(L["Mailbox read"], Util.FormatAgeAgo(age), "muted")

        if not ns.Mail:HasReadThisSession() then
            detail.note:SetText(L["Open a mailbox to bring in your newest sales."])
        else
            detail.note:SetText(L["Click an item to see how it has done. Sell-through leaves out listings you cancelled."])
        end
    end

    SetLines(detail, lines)
end

--------------------------------------------------------------------------------
-- Gathering what to show
--------------------------------------------------------------------------------

--- Everything the ledger holds, as one set of totals.
local function Totals(items)
    local totals = {
        sold = 0, soldUnits = 0, expired = 0, cancelled = 0,
        net = 0, cut = 0, estimated = 0, items = 0, restored = false,
        profit = 0, costed = 0, guessed = 0, uncosted = 0,
    }

    for _, item in ipairs(items) do
        totals.sold = totals.sold + item.sold
        totals.soldUnits = totals.soldUnits + item.soldUnits
        totals.expired = totals.expired + item.expired
        totals.cancelled = totals.cancelled + item.cancelled
        totals.net = totals.net + item.net
        totals.cut = totals.cut + item.cut
        totals.estimated = totals.estimated + item.estimated
        totals.profit = totals.profit + item.profit
        totals.costed = totals.costed + item.costed
        totals.guessed = totals.guessed + item.guessed
        totals.uncosted = totals.uncosted + item.uncosted
        totals.items = totals.items + 1

        if item.restored then totals.restored = true end
    end

    local judged = totals.sold + totals.expired
    totals.sellThrough = judged > 0 and (totals.sold / judged) or nil

    return totals
end

--- How many sales are in the totals but cannot appear in the event list.
--
-- Carried-over history has no per-event detail, so the Recent view would look
-- emptier than the footer says it is. The rollup is read directly rather than
-- worked out by subtracting this session's sales from the per-item figures:
-- those figures already have this session folded into them, so the subtraction
-- lost a sale for every item that sold this session and had no history behind
-- it. The rollup is the pre-restart half on its own, which is exactly what
-- this is asking for.
local function CarriedOver()
    local rollup = ns.Mail:GetRestoredRollup()
    if not rollup then return 0 end

    local carried = 0
    for _, record in pairs(rollup) do
        carried = carried + (record.sold or 0)
    end

    -- Sales rolled into the history during this session are in the list as
    -- well, so they are not "carried over from before".
    for _, entry in ipairs(ns.Mail:GetLedger().entries) do
        if entry.kind == "sold" and ns.Mail:IsRolledUp(entry) then
            carried = carried - 1
        end
    end

    return math.max(0, carried)
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

--- The key of the item a row is about, the same key By item files it under.
--
-- A sale recorded by name only (the mail gave no item id) is filed under the
-- id another entry gave that name. Keyed by "?name" here instead, clicking
-- one selected nothing, and the item's sales were never lit.
local function SelectionKey(data)
    return data.key or data.itemID
        or (data.name and state.names and state.names[data.name])
        or ("?" .. tostring(data.name or "unknown"))
end

--------------------------------------------------------------------------------
-- Gold in and out
--------------------------------------------------------------------------------

-- Asked by a player on 2026-10-06: income and spending with their sources,
-- over a session, a day, a week or chosen days. Logic/GoldLog.lua keeps it;
-- UI/GoldChart.lua draws it in the list's place, with its legend in the
-- detail pane's.

local PERIOD_TEXT = {
    session = L["this session"], today = L["today"],
    week = L["the last 7 days"], month = L["the last 30 days"],
    quarter = L["the last 3 months"], year = L["the last year"], all = L["all time"],
}

--- A day as the date pickers show it: "Oct 06".
local function DayText(dayKey)
    return date("%b %d", ns.GoldLog.KeyStart(dayKey))
end

--- Every day from the first one logged (or 30 days back) to today, newest first.
local function DayOptions()
    local days = ns.GoldLog:Days()
    local today = ns.GoldLog.DayKey(time())
    local oldest = ns.GoldLog.DayKey(ns.GoldLog.DayStart(time(), -29))
    if days[#days] and days[#days] < oldest then oldest = days[#days] end

    local options = {}
    local day = ns.GoldLog.DayStart(time())
    local key = today
    while key >= oldest and #options < 400 do
        options[#options + 1] = { text = DayText(key), value = key }
        day = ns.GoldLog.DayStart(day, -1)
        key = ns.GoldLog.DayKey(day)
    end
    return options
end

--- The period's name for the legend and footer.
local function PeriodText()
    if state.period == "pick" and state.fromDay and state.toDay then
        local from, to = math.min(state.fromDay, state.toDay), math.max(state.fromDay, state.toDay)
        if from == to then return DayText(from) end
        return L.Format("%s to %s", DayText(from), DayText(to))
    end
    return PERIOD_TEXT[state.period] or ""
end

--- Show the controls and panes the view needs, hide the rest.
local function ApplyLayout()
    local gold = state.view == "gold"
    local methods = state.view == "methods"

    widgets.list:SetShown(not gold)
    widgets.detail:SetShown(not gold)
    widgets.chart:SetShown(gold)
    widgets.legend:SetShown(gold)
    widgets.search:SetShown(not gold and not methods)
    widgets.period:SetShown(gold or methods)
    widgets.who:SetShown(gold)

    local picking = (gold or methods) and state.period == "pick"
    widgets.fromDay:SetShown(picking)
    widgets.toLabel:SetShown(picking)
    widgets.toDay:SetShown(picking)

    if gold or methods then
        widgets.emptyLabel:Hide()
        widgets.carried:Hide()
    end
end

--- The day menus, when dates are being picked.
local function FillPickedDays()
    if state.period ~= "pick" then return end

    local options = DayOptions()
    widgets.fromDay:SetOptions(options)
    widgets.toDay:SetOptions(options)
    state.toDay = state.toDay or options[1].value
    state.fromDay = state.fromDay or (options[7] or options[#options]).value
    widgets.fromDay:SetValue(state.fromDay)
    widgets.toDay:SetValue(state.toDay)
end

local function RefreshGold()
    if not ns.GoldLog then return end

    FillPickedDays()

    local bins = ns.GoldLog:Bins(state.period, state.fromDay, state.toDay)
    for _, bin in ipairs(bins) do
        if state.period == "session" or state.period == "today" then
            bin.title = L.Format("%s to %s", date("%H:%M", bin.from), date("%H:%M", bin.to))
        elseif bin.to - bin.from > 86400 * 1.5 then
            bin.title = L.Format("%s to %s", date("%b %d", bin.from), date("%b %d", bin.to - 1))
        else
            bin.title = date("%A %b %d", bin.from)
        end
    end

    local line = ns.GoldLog.Line and ns.GoldLog:Line(bins, state.who, state.period) or nil
    ns.GoldChart.SetLine(widgets.chart, bins, line)
    ns.GoldChart.SetBins(widgets.chart, bins,
        L["Nothing yet. Gold you make and spend from now on is written down here, with where it came from."])

    local totals = ns.GoldLog:Totals(bins)
    ns.GoldChart.SetTotals(widgets.legend, totals, PeriodText())

    widgets.summary:SetText(L.Format("In %s  ·  out %s  ·  net |c%s%s|r  ·  %s",
        Util.FormatMoney(totals.income, { short = true }),
        Util.FormatMoney(totals.spending, { short = true }),
        ns.COLORS[totals.net < 0 and "loss" or "profit"], ns.GoldChart.Signed(totals.net),
        PeriodText()))
end

--- Profit by method (Logic/MethodProfit.lua): each way of making money, its
--- items beneath it, and the totals in the panel.
local function RefreshMethods()
    awaitingItemData = false
    FillPickedDays()

    if not ns.MethodProfit then return end

    local from, to = ns.MethodProfit.Range(state.period, state.fromDay, state.toDay)
    local summary = ns.MethodProfit:Summary(from, to)
    local total = summary.total

    local data = {}
    local folded = FoldedMethods()
    for _, method in ipairs(ns.MethodProfit.METHODS) do
        local group = summary.methods[method.key]
        if group.n > 0 then
            data[#data + 1] = { methodRow = true, method = method, group = group, folded = folded[method.key] }
            for _, item in ipairs(folded[method.key] and {} or group.list) do
                data[#data + 1] = { methodItem = true, key = method.key,
                    itemID = item.itemID, item = item }
            end
        end
    end
    widgets.list:SetData(data)

    if #data == 0 then
        widgets.emptyLabel:SetText(L["Nothing yet for this period. Sales at auction, to vendors and disenchants are written down as they happen, with what each cost you."])
        widgets.emptyLabel:Show()
    else
        widgets.emptyLabel:Hide()
    end

    local detail = widgets.detail
    local lines = {}
    for _, method in ipairs(ns.MethodProfit.METHODS) do
        local group = summary.methods[method.key]
        if group.n > 0 then
            lines[#lines + 1] = { method.text, SignedMoney(group.profit),
                group.profit < 0 and "loss" or "profit" }
        end
    end
    lines[#lines + 1] = { L["Profit"], SignedMoney(total.profit), total.profit < 0 and "loss" or "profit" }
    lines[#lines + 1] = { L["Taken in"], Util.FormatMoney(total.income), "profit" }
    lines[#lines + 1] = { L["Cost"], Util.FormatMoney(total.cost), total.cost > 0 and "loss" or "muted" }

    ShowStatsButton(detail, nil)
    detail.title:SetText(L["Profit by method"])
    detail.subtitle:SetText(PeriodText())
    SetLines(detail, lines)
    detail.note:SetText(total.unknown > 0
        and L.Format("%d of %d had no known cost (loot, for example), so everything they brought in counts as profit.",
            total.unknown, total.n)
        or L["Costs are what crafting or buying on the auction house cost you."])

    widgets.summary:SetText(L.Format("Profit %s  ·  in %s  ·  %s",
        SignedMoney(total.profit), Util.FormatMoney(total.income, { short = true }), PeriodText()))
end

local function Refresh()
    if not widgets.list then return end

    ApplyLayout()
    if state.view == "gold" then
        RefreshGold()
        return
    end

    if state.view == "methods" then
        RefreshMethods()
        return
    end

    awaitingItemData = false
    saleCosts = nil

    -- Once per redraw: it walks the whole ledger.
    state.names = ns.Mail.NameIndex and ns.Mail:NameIndex() or nil

    local query = (state.search or ""):lower()
    local items = ns.Mail:GetItems()
    local totals = Totals(items)

    local data = {}

    local heard = (state.view ~= "visits" and state.view ~= "item" and ns.Mail.GetHeard)
        and ns.Mail:GetHeard() or {}
    local listedCharacters, endedCount = 0, 0

    if state.view == "listed" then
        local listings, characters = {}, 0
        if ns.Auctions and ns.Auctions.GetListings then
            listings, characters = ns.Auctions:GetListings()
        end
        listedCharacters = characters

        for _, listing in ipairs(listings) do
            if Matches(listing.itemID, nil, query) then
                if listing.ended then endedCount = endedCount + 1 end
                -- Flagged on a copy, so nothing is written into saved data.
                local row = {}
                for k, v in pairs(listing) do row[k] = v end
                row.listing = true
                data[#data + 1] = row
            end
        end

        -- Still up first, soonest to end at the top; ended ones after.
        table.sort(data, function(a, b)
            if a.ended ~= b.ended then return not a.ended end
            return (a.ends or math.huge) < (b.ends or math.huge)
        end)
    elseif state.view == "visits" then
        local history = ns.MailHaul and ns.MailHaul:GetHistory() or {}

        for index = #history, 1, -1 do
            -- Flagged on a view of it, so nothing is written into saved data.
            local haul = setmetatable({ haul = true }, { __index = history[index] })

            local best = haul.best
            if query == "" or (best and Matches(best.itemID, best.name, query)) then
                data[#data + 1] = haul
            end
        end
    elseif state.view == "item" then
        for _, item in ipairs(items) do
            if Matches(item.itemID, item.name, query) then
                data[#data + 1] = item
            end
        end

        -- What came in, most first. An item that only ever came back sorts to
        -- the bottom by that measure and is still shown: a craft that never
        -- sells is exactly the thing worth seeing.
        table.sort(data, function(a, b)
            if a.net ~= b.net then return a.net > b.net end
            return (a.lastAt or 0) > (b.lastAt or 0)
        end)
    else
        local entries = ns.Mail:GetLedger().entries
        local salesOnly = state.view == "sales"

        -- Walked backwards: the ledger is appended to, so the end of it is the
        -- newest, which is the order this list wants.
        for index = #entries, 1, -1 do
            local entry = entries[index]

            if (not salesOnly or entry.kind == "sold")
                and Matches(entry.itemID, entry.name, query) then
                data[#data + 1] = entry
            end
        end

        -- Sales heard in chat whose mail has not been read yet, newest
        -- first, among the rest by time.
        if #heard > 0 then
            for index = #heard, 1, -1 do
                local entry = heard[index]
                if Matches(entry.itemID, entry.name, query) then
                    data[#data + 1] = setmetatable({ kind = "heard" }, { __index = entry })
                end
            end

            -- Kept beside the rows, not on them: ledger rows are saved data.
            local place = {}
            for index, entry in ipairs(data) do place[entry] = index end
            table.sort(data, function(a, b)
                if (a.t or 0) ~= (b.t or 0) then return (a.t or 0) > (b.t or 0) end
                return place[a] < place[b]
            end)
        end
    end

    widgets.list:SetData(data)

    -- Keep the panel on whatever was selected, across a refresh and across a
    -- change of view. An item selected in the By item view still makes sense
    -- as the subject while looking at the event list.
    local selected

    if state.selected then
        for _, item in ipairs(items) do
            if item.key == state.selected then selected = item break end
        end

        if not selected then state.selected = nil end
    end

    UpdateDetail(selected, totals)

    if Widgets.EmptyAction then Widgets.EmptyAction(widgets.emptyLabel, nil) end
    if #data == 0 then
        widgets.emptyLabel:Show()
        if query ~= "" and Widgets.EmptyAction then Widgets.EmptyAction(widgets.emptyLabel, L["Clear Search"], function() widgets.search:SetText("") end) end

        if state.view == "listed" then
            if query ~= "" then
                widgets.emptyLabel:SetText(L.Format("Nothing here matches '%s'.", state.search))
            elseif listedCharacters == 0 then
                widgets.emptyLabel:SetText(L["Open the auction house once and what you have listed shows here, even after you log out."])
            else
                widgets.emptyLabel:SetText(L["Nothing was listed at your last auction house visit."])
            end
        elseif state.view ~= "visits" and totals.sold == 0 and totals.expired == 0 and totals.cancelled == 0 then
            widgets.emptyLabel:SetText(ns.Mail:HasReadThisSession()
                and L["Nothing recorded yet. Sales and expiries are written down when you open the mailbox they arrive in."]
                or L["Nothing recorded yet. Visit a mailbox after a listing has ended and it will appear here."])
        elseif query ~= "" then
            widgets.emptyLabel:SetText(L.Format("Nothing here matches '%s'.", state.search))
        elseif state.view == "visits" then
            widgets.emptyLabel:SetText(L["No mailbox visits yet. Collect mail and each visit shows up here. Click one to see its report again."])
        else
            widgets.emptyLabel:SetText(L["Nothing sold yet. Switch to 'Recent, all' to see what came back."])
        end
    else
        widgets.emptyLabel:Hide()
    end

    if state.view == "visits" then
        local history = ns.MailHaul and ns.MailHaul:GetHistory() or {}
        local collected = 0
        for _, haul in ipairs(history) do collected = collected + (haul.total or 0) end
        local best = ns.MailHaul and ns.MailHaul:Records() or 0

        widgets.summary:SetText(L.Format(#history == 1 and L["%d visit  ·  collected %s  ·  best haul %s"]
                or L["%d visits  ·  collected %s  ·  best haul %s"],
            #history,
            Util.FormatMoney(collected, { short = true }),
            Util.FormatMoney(best, { short = true })))
        widgets.carried:Hide()
        return
    end

    if state.view == "listed" then
        local up = #data - endedCount
        widgets.summary:SetText(endedCount > 0
            and L.Format("%d still listed  ·  %d ended since  ·  as of your last auction house visit", math.max(0, up), endedCount)
            or L.Format("%d still listed  ·  as of your last auction house visit", math.max(0, up)))
        widgets.carried:Hide()
        return
    end

    local counted = totals.costed + totals.guessed

    local profitPart = ""
    if counted > 0 then
        profitPart = counted < totals.sold
            and L.Format("  ·  profit %s on %d", SignedMoney(totals.profit), counted)
            or L.Format("  ·  profit %s", SignedMoney(totals.profit))
    end
    widgets.summary:SetText(L.Format("%d sold  ·  taken in %s%s%s%s",
        totals.sold,
        Util.FormatMoney(totals.net, { short = true }),
        profitPart,
        totals.sellThrough
            and L.Format("  ·  %d%% sell-through",
                math.floor(totals.sellThrough * 100 + 0.5))
            or "",
        #heard > 0 and L.Format("  ·  %d waiting in the mail", #heard) or ""))

    -- Only in the event views, and only when there is something the list
    -- genuinely cannot show. In the By item view the carried-over figures are
    -- already on screen.
    local carried = (state.view ~= "item") and CarriedOver() or 0

    widgets.carried:SetShown(carried > 0)
    if carried > 0 then
        widgets.carried:SetText(carried == 1
            and L.Format("plus %d sale from before you last quit the game. See By item", carried)
            or L.Format("plus %d sales from before you last quit the game. See By item", carried))
    end
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function Build(container)
    -- The views are pages along the top (a player asked, the owner said yes
    -- from a mockup, 2026-10-22: a menu hid which one was showing); under
    -- them each view's own bar, search or the period.
    local viewTabs = {}
    for _, view in ipairs(VIEWS) do viewTabs[#viewTabs + 1] = { key = view.value, text = view.text } end
    local view = Widgets.CreateTabStrip(container, viewTabs, function(value)
        state.view = value
        Refresh()
    end, { width = 1060 })
    view:SetPoint("TOPLEFT", 8, -8)
    view:Select(state.view)
    widgets.view = view

    local toolbar = CreateFrame("Frame", nil, container)
    toolbar:SetPoint("TOPLEFT", view, "BOTTOMLEFT", 0, -6)
    toolbar:SetPoint("RIGHT", container, "RIGHT", -8, 0)
    toolbar:SetHeight(24)

    -- The periods are pages too, Pick dates last with its two days.
    local periodTabs = {}
    for _, period in ipairs(ns.GoldLog and ns.GoldLog.PERIODS or {}) do
        periodTabs[#periodTabs + 1] = { key = period.value, text = period.text }
    end
    local period = Widgets.CreateTabStrip(toolbar, periodTabs, function(value)
        state.period = value
        Refresh()
    end, { width = 560 })
    period:SetPoint("LEFT", 0, 0)
    period:Select(state.period)
    widgets.period = period

    local fromDay = Widgets.CreateDropdown(toolbar, {}, function(value)
        state.fromDay = value
        Refresh()
    end, { width = 90 })
    fromDay:SetPoint("LEFT", period, "RIGHT", 8, 0)
    widgets.fromDay = fromDay

    local toLabel = Theme.CreateLabel(toolbar, "small", "muted")
    toLabel:SetPoint("LEFT", fromDay, "RIGHT", 6, 0)
    toLabel:SetText(L["to"])
    widgets.toLabel = toLabel

    local toDay = Widgets.CreateDropdown(toolbar, {}, function(value)
        state.toDay = value
        Refresh()
    end, { width = 90 })
    toDay:SetPoint("LEFT", toLabel, "RIGHT", 6, 0)
    widgets.toDay = toDay

    local who = Widgets.CreateTabStrip(toolbar, WHO, function(value)
        state.who = value
        Refresh()
    end, { width = DETAIL_WIDTH })
    who:SetPoint("RIGHT", 0, 0)
    who:Select(state.who)
    widgets.who = who

    local search = Widgets.CreateSearchBox(toolbar, L["Search sales"], function(text)
        state.search = text or ""
        Refresh()
    end)
    search:SetPoint("LEFT", 0, 0)
    search:SetWidth(Widgets.SEARCH_WIDTH)
    widgets.search = search

    local divider = Theme.CreateDivider(container)
    divider:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -8)
    divider:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", -DETAIL_WIDTH - 8, -8)

    local carried = Theme.CreateLabel(container, "tiny", "dim")
    carried:SetPoint("BOTTOMLEFT", 8, 26)
    carried:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -DETAIL_WIDTH - 16, 26)
    carried:SetJustifyH("LEFT")
    carried:Hide()
    widgets.carried = carried

    local list = Widgets.CreateScrollList(container, {
        rowHeight = ROW_HEIGHT,
        createRow = CreateRow,
        updateRow = UpdateRow,
        onEnter = function(row, data)
            if data.methodRow then return end
            if data.haul then
                GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
                GameTooltip:SetText(L["Click to see this visit's report again"], 1, 1, 1)
                GameTooltip:Show()
                return
            end
            Widgets.ShowItemOnly(row, data.itemID, data.name)
        end,
        onLeave = function() GameTooltip:Hide() end,
        -- The item the detail pane is showing is lit, as on every other tab.
        isSelected = function(data)
            if data.haul or data.methodRow or data.methodItem or not state.selected then return false end
            return SelectionKey(data) == state.selected
        end,
        onClick = function(data)
            if data.methodRow then
                ToggleMethod(data.method.key)
                Refresh()
                return
            end
            if data.methodItem then return end
            if data.haul then
                if ns.MailReport then ns.MailReport:Show(data, { replay = true }) end
                return
            end

            -- Both views select the same thing: an item. Clicking one sale
            -- asks about that item, not about that one listing.
            local key = SelectionKey(data)

            -- A second click lets it go. Written "== key and nil or key",
            -- the nil fell through to key and the item could not be let go.
            if state.selected == key then
                state.selected = nil
            else
                state.selected = key
            end
            Refresh()
        end,
    })
    list:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -4)
    list:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -DETAIL_WIDTH - 16, 42)
    widgets.list = list

    local emptyLabel = Theme.CreateLabel(container, "small", "dim", "CENTER")
    emptyLabel:SetPoint("CENTER", list, "CENTER")
    emptyLabel:SetWidth(340)
    emptyLabel:SetWordWrap(true)
    widgets.emptyLabel = emptyLabel
    if Widgets.DressEmpty then Widgets.DressEmpty(emptyLabel) end

    local summary = Theme.CreateLabel(container, "small", "text")
    summary:SetPoint("BOTTOMLEFT", 8, 10)
    widgets.summary = summary

    local detail = BuildDetail(container)
    detail:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -8)
    detail:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -8, 8)
    widgets.detail = detail

    local chart = ns.GoldChart.CreateChart(container)
    chart:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -4)
    chart:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -DETAIL_WIDTH - 16, 42)
    chart:Hide()
    widgets.chart = chart

    local legend = ns.GoldChart.CreateLegend(container, DETAIL_WIDTH)
    legend:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -8)
    legend:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -8, 8)
    legend:Hide()
    widgets.legend = legend

    -- Gold changing while the view is up redraws it, a moment later so the
    -- log has written the change down first.
    local goldQueued = false
    ns.RegisterEvent(UI, "PLAYER_MONEY", function()
        if goldQueued or state.view ~= "gold" or not chart:IsVisible() then return end
        goldQueued = true
        C_Timer.After(0.3, function()
            goldQueued = false
            Refresh()
        end)
    end)

    -- An item the client has not cached yet draws with no rarity colour and a
    -- placeholder name, and stays that way until something redraws the tab.
    -- A burst of arrivals is coalesced into one pass, and nothing happens at
    -- all unless a row is actually waiting on one.
    local redrawQueued = false

    ns.RegisterEvent(UI, "GET_ITEM_INFO_RECEIVED", function()
        if redrawQueued or not awaitingItemData then return end
        if not widgets.list:IsVisible() then return end

        redrawQueued = true
        C_Timer.After(0.2, function()
            redrawQueued = false
            Refresh()
        end)
    end)
end

-- The mail report's "See all visits" button opens this view.
ns.SalesTab = {
    ShowVisits = function()
        state.view = "visits"
        if widgets.view then widgets.view:Select("visits") end
    end,
}

UI:RegisterTab({
    key = "sales",
    text = L["Sales"],
    order = 10,
    build = Build,
    refresh = Refresh,
})
