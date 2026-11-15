-- Blackthornes Tradeskills -- Logic/VendorFlips.lua
-- Items on the auction house listed for less than a vendor pays for them.
--
-- Buy one at the cheapest listing from someone else, sell it to any vendor,
-- and keep the difference. No auction house cut comes into it, since the
-- item goes to a vendor rather than back on the auction house.
--
-- Prices are per item. A stack listed at 40c each is 40c a flip, however
-- many are in it.
--
-- What a vendor pays comes from the item facts the Deals tab uses
-- (Disenchant:GetSellPrice), read once per item and saved, never from the
-- client's item cache on a redraw: reading thousands of scanned items that
-- way pushed his bag items out and broke Ready to sell (2026-09-28).

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Util = ns.Util

local VendorFlips = ns.NewModule("VendorFlips")

--------------------------------------------------------------------------------
-- What is new
--------------------------------------------------------------------------------

-- The Deals tab's "New only" and NEW tag (a player asked, the owner agreeing
-- 2026-10-11): each deal keeps the scan it was first seen in, per realm, in
-- dealsSeen[realm] = { since, items = { [itemID] = { f = first, l = last } } }
-- (never rename it). One not shown for this long starts over as new.
VendorFlips.SEEN_FORGET = 7 * 24 * 3600

local function SeenTable()
    local db = ns.db
    local realm = ns.Config and ns.Config.GetRealmKey and ns.Config:GetRealmKey()
    if not db or not realm then return nil end
    if type(db.dealsSeen) ~= "table" then db.dealsSeen = {} end
    local seen = db.dealsSeen[realm]
    if type(seen) ~= "table" or type(seen.items) ~= "table" then
        seen = { items = {} }
        db.dealsSeen[realm] = seen
    end
    return seen
end

--- A row that clears the deal minimums, by itself or by another way to
--- make money on the same item (row.others). Rows built without the
--- minimums known (clears nil) count as deals.
local function IsDeal(row)
    if row.clears ~= false then return true end
    for _, other in ipairs(row.others or {}) do
        if other.clears ~= false then return true end
    end
    return false
end

--- Mark each row with the scan it was first seen in (row.firstSeen) and
--- whether that is the latest scan (row.isNew). The deals listed the first
--- time this runs on a realm are not new: they were there before it.
--
-- Only deals that clear the minimums are written down. With "Only deals
-- over my minimums" unticked the list also shows items that are no deal;
-- writing those down tagged them NEW the moment the box was unticked,
-- and kept the tag off when one later became a real deal.
-- @param rows the Deals tab's rows, as built
function VendorFlips:NoteSeen(rows)
    local scanAt = ns.Prices and ns.Prices.GetLastScan and ns.Prices:GetLastScan()
    local seen = scanAt and SeenTable()
    if not seen then
        for _, row in ipairs(rows) do row.isNew = false end
        return
    end

    local first = seen.since == nil
    if first then seen.since = scanAt end

    local items = seen.items
    for _, row in ipairs(rows) do
        if IsDeal(row) then
            local entry = items[row.itemID]
            if type(entry) ~= "table" then
                entry = { f = first and 0 or scanAt }
                items[row.itemID] = entry
            end
            entry.l = scanAt
            row.firstSeen = entry.f > 0 and entry.f or nil
            row.isNew = entry.f == scanAt
        else
            row.firstSeen, row.isNew = nil, false
        end
    end

    -- Once a scan: forget what has not been a deal for a while.
    if seen.pruned ~= scanAt then
        seen.pruned = scanAt
        for itemID, entry in pairs(items) do
            if type(entry) ~= "table" or (tonumber(entry.l) or 0) < scanAt - self.SEEN_FORGET then
                items[itemID] = nil
            end
        end
    end
end

--- Every item someone else has on the auction house for less than a vendor
--- pays, with what buying one and selling it to a vendor makes.
--
-- Profit is the vendor price less the buy price. Margin is that profit over
-- the buy price. Your own listings are left out: buying back your own item
-- is not a deal.
--
-- @param opts { profitableOnly, minProfit, minMargin }
--   profitableOnly keeps rows that clear minProfit (at least 1 copper) and
--   minMargin (a percent); both default to Settings.
-- @return rows best profit first, how many flips were held back by the
--   minimums, and how many listed items are still to be read (none are read
--   while the auction house is open)
function VendorFlips:GetAuctionRows(opts)
    opts = opts or {}

    -- Counted for /bts vendordeals, which says how often this ran.
    self.rowBuilds = (self.rowBuilds or 0) + 1

    local rows, hidden, pending = {}, 0, 0
    local prices = ns.Prices and ns.Prices:GetTable() or {}
    local minProfit = opts.minProfit or (ns.Config and ns.Config:Get("minProfit")) or 0
    local minMargin = (opts.minMargin or (ns.Config and ns.Config:Get("minMarginPercent")) or 0) / 100
    local BuyPrice = ns.Disenchant._BuyPrice

    -- Only what the last scan (or a search since) actually saw. A listing
    -- missing from the last scan has sold or expired, but its record keeps
    -- the old price, so without this it stays listed as a deal for days.
    local since = (ns.Prices.GetLastScan and ns.Prices:GetLastScan() or (ns.db and ns.db.lastFullScan))

    for itemID, record in pairs(prices) do
        local buy = type(record) == "table" and BuyPrice(record)
        if buy and since and (record.seen or 0) < since then buy = nil end

        local vendor = buy and ns.Disenchant:GetSellPrice(itemID)
        if buy and vendor == nil and not (ns.Disenchant.GaveUp and ns.Disenchant:GaveUp(itemID)) then
            pending = pending + 1
        end

        -- A charged item nobody has sold on Forever yet: its price in the
        -- game's data can be several times what a vendor pays (Minor Wizard
        -- Oil showed a 1s flip that lost 3s, 2026-10-09). Left out until a
        -- sale says what it is worth.
        if vendor and ns.Disenchant.SellPriceUnsure and ns.Disenchant:SellPriceUnsure(itemID) then
            vendor = nil
        end

        if vendor and vendor > buy then
            local gain = vendor - buy
            local paidFrom
            if ns.Vendor and ns.Vendor.GetPaid then _, paidFrom = ns.Vendor:GetPaid(itemID) end

            local row = {
                kind = "vendor",
                itemID = itemID,
                name = ns.Disenchant:ItemName(itemID),
                buy = buy,
                loneLow = record.ignoredLow ~= nil and buy == record.ignoredLow or nil,
                listed = record.quantity,
                -- How many at the deal's price or less (the Deals tab's QTY).
                qty = ns.Prices.CountAtOrBelow and ns.Prices.CountAtOrBelow(record, buy) or nil,
                vendor = vendor,
                -- "sold" when a sale of yours set the price, "reported" from
                -- the shipped list, nil from the game's item data.
                vendorFrom = paidFrom,
                sell = vendor,
                extra = record.quantity,
                gain = gain,
                margin = gain / buy,
                age = ns.Prices:GetAge(itemID),
                stale = ns.Prices:IsStale(itemID),
            }

            local clears = gain >= minProfit and row.margin >= minMargin

            row.clears = clears
            if not opts.profitableOnly or clears then
                rows[#rows + 1] = row
            else
                hidden = hidden + 1
            end
        end
    end

    table.sort(rows, function(a, b)
        if a.gain ~= b.gain then return a.gain > b.gain end
        return a.itemID < b.itemID
    end)

    return rows, hidden, pending
end

--------------------------------------------------------------------------------
-- Auction house flips: buy under the usual price, list it again
--------------------------------------------------------------------------------

-- Scans of an item, the one that found the deal included, before its usual
-- price is trusted. Fewer, and one seller's cheap stack may simply be where
-- it sells now (a player's idea, 2026-10-06).
local MIN_RESALE_SCANS = 5

VendorFlips.MIN_RESALE_SCANS = MIN_RESALE_SCANS

--- What an item usually sells for: the middle of its market values from the
--- scans before the latest one. The latest is left out on purpose, since a
--- cheap listing found by it pulls that scan's value down too.
--
-- @return copper and how many scans it was taken from, or nil when there
--   are fewer than MIN_RESALE_SCANS
function VendorFlips.UsualPrice(record)
    if type(record) ~= "table" or type(record.history) ~= "table" then return nil end

    local values = {}
    local history = record.history
    for index, entry in ipairs(history) do
        local latest = index == #history and (record.seen == nil or entry.t == record.seen)
        if not latest and type(entry.m) == "number" and entry.m > 0 then
            values[#values + 1] = entry.m
        end
    end

    if #values + 1 < MIN_RESALE_SCANS then return nil end

    table.sort(values)
    local middle = (#values + 1) / 2
    local usual = (values[math.floor(middle)] + values[math.ceil(middle)]) / 2
    return math.floor(usual + 0.5), #values
end

--- Every item someone else has on the auction house well under what it
--- usually sells for, with what buying one and listing it again makes.
--
-- The resale price is the usual price, or the next listing up when that is
-- lower, since that listing is what yours will sit beside. Profit is what
-- that pays after the auction house cut and the deposit (Profit:NetFromListing),
-- less the buy price.
--
-- Held back always, and counted as thin: items with fewer than
-- MIN_RESALE_SCANS scans, items with Low or no Demand (gold tied up in
-- something that does not sell is not a deal), and grey items, which are
-- priced at vendor only.
--
-- @param opts { profitableOnly, minProfit, minMargin } as GetAuctionRows
-- @return rows best profit first, how many were held back by the minimums,
--   and how many cheap listings were held back as thin
function VendorFlips:GetResaleRows(opts)
    opts = opts or {}

    local rows, hidden, thin = {}, 0, 0
    local prices = ns.Prices and ns.Prices:GetTable() or {}
    local minProfit = opts.minProfit or (ns.Config and ns.Config:Get("minProfit")) or 0
    local minMargin = (opts.minMargin or (ns.Config and ns.Config:Get("minMarginPercent")) or 0) / 100
    local BuyPrice = ns.Disenchant._BuyPrice

    local since = (ns.Prices.GetLastScan and ns.Prices:GetLastScan() or (ns.db and ns.db.lastFullScan))

    for itemID, record in pairs(prices) do
        local buy = type(record) == "table" and BuyPrice(record)
        if buy and since and (record.seen or 0) < since then buy = nil end

        local usual, scans
        if buy then usual, scans = VendorFlips.UsualPrice(record) end

        -- Too few scans for a usual price: weighed against the market value
        -- only to say how many were held back.
        local reference = usual or (buy and record.market)

        if buy and reference and buy < reference then
            local resell = reference
            -- The next listing up, when the cheap one is a lone low listing
            -- that pricing left out: yours sits beside it.
            if record.rivalMin and record.rivalMin > buy and record.rivalMin < resell then
                resell = record.rivalMin
            end

            local net = ns.Profit:NetFromListing(itemID, resell)
            local gain = math.floor(net - buy)
            local clears = gain >= minProfit and gain / buy >= minMargin

            local demand, grey
            if usual and gain > 0 then
                demand = ns.Demand and ns.Demand:Get(itemID)
                local facts = ns.Disenchant:GetItemFacts(itemID)
                grey = facts and facts.quality == 0
            end

            if gain <= 0 then
                -- Not a flip once the cut and deposit are paid.
            elseif not usual or grey or not demand or demand.level == "low" then
                if clears or not opts.profitableOnly then thin = thin + 1 end
            else
                local row = {
                    kind = "auction",
                    itemID = itemID,
                    name = ns.Disenchant:ItemName(itemID),
                    buy = buy,
                    loneLow = record.ignoredLow ~= nil and buy == record.ignoredLow or nil,
                    listed = record.quantity,
                    qty = ns.Prices.CountAtOrBelow and ns.Prices.CountAtOrBelow(record, buy) or nil,
                    usual = usual,
                    scans = scans + 1,
                    resell = resell,
                    capped = resell < usual or nil,
                    sell = resell,
                    net = net,
                    depositKnown = ns.Posting:GetCachedUnitDeposit(itemID) ~= nil,
                    -- A sale hands the deposit back, so it only costs a flip
                    -- that is expected to run out first.
                    depositCounts = ns.Profit.LostListings ~= nil and ns.Profit.LostListings(itemID) > 0,
                    gain = gain,
                    margin = gain / buy,
                    demand = demand,
                    extra = ns.Demand:Rank(demand),
                    age = ns.Prices:GetAge(itemID),
                    stale = ns.Prices:IsStale(itemID),
                }

                row.clears = clears
                if not opts.profitableOnly or clears then
                    rows[#rows + 1] = row
                else
                    hidden = hidden + 1
                end
            end
        end
    end

    table.sort(rows, function(a, b)
        if a.gain ~= b.gain then return a.gain > b.gain end
        return a.itemID < b.itemID
    end)

    return rows, hidden, thin
end

--- After a scan: say how many flips it found and the best one, with the
--- sound of coins when there is at least one. Quiet when there are none.
function VendorFlips:AnnounceDeals()
    local ok, rows = pcall(self.GetAuctionRows, self, { profitableOnly = true })
    if not ok or type(rows) ~= "table" or #rows == 0 then return 0 end

    local best = rows[1]
    local total = 0
    for _, row in ipairs(rows) do total = total + row.gain end

    local totalText = Util.FormatMoney(total, { noColor = true })
    local bestName = Util.GetItemLabel(best.itemID)
    local buyText = Util.FormatMoney(best.buy, { noColor = true })
    local vendorText = Util.FormatMoney(best.vendor, { noColor = true })
    if #rows == 1 then
        ns.Print(L.Format("Vendor flips: %d item on the auction house costs less than a vendor pays for it, %s together if you buy one of each. The best is %s for %s, and a vendor pays %s. See the Deals tab.",
            #rows, totalText, bestName, buyText, vendorText))
    else
        ns.Print(L.Format("Vendor flips: %d items on the auction house cost less than a vendor pays for them, %s together if you buy one of each. The best is %s for %s, and a vendor pays %s. See the Deals tab.",
            #rows, totalText, bestName, buyText, vendorText))
    end

    -- Settings: Sound when a scan finishes.
    if (not ns.Config or ns.Config:Get("scanSounds") ~= false) and type(PlaySound) == "function" then
        local kits = type(_G.SOUNDKIT) == "table" and _G.SOUNDKIT or {}
        local sound = kits.LOOT_WINDOW_COIN_SOUND or kits.UI_EPICLOOT_TOAST
        if sound then pcall(ns.PlaySound or PlaySound, sound, "Master") end
    end

    return #rows
end

--------------------------------------------------------------------------------
-- /bts vendordeals: why each vendor flip is on the Deals tab
--------------------------------------------------------------------------------

local function Ago(stamp)
    if not stamp then return "never" end
    return Util.FormatAgeAgo(math.max(0, time() - stamp))
end

ns.RegisterCommand("vendordeals", L["say why each vendor flip on the Deals tab is there"], function()
    local lastScan = (ns.Prices.GetLastScan and ns.Prices:GetLastScan() or (ns.db and ns.db.lastFullScan))
    ns.Print(("vendordeals: last scan %s, price records changed %d time(s) since /reload")
        :format(Ago(lastScan), ns.Prices and ns.Prices.changes or 0))

    local shown = VendorFlips.shownRows
    if shown then
        ns.Print(("vendordeals: the tab's list was built %s, %d row(s)")
            :format(Ago(VendorFlips.shownBuiltAt), #shown))
    else
        ns.Print("vendordeals: the tab has not built its list since /reload (open the Deals tab)")
    end

    local fresh, hidden, pending = VendorFlips:GetAuctionRows({ profitableOnly = true })
    ns.Print(("vendordeals: built fresh now it would have %d flip(s), %d under your minimums, %d item(s) with no vendor price read yet")
        :format(#fresh, hidden or 0, pending or 0))

    local prices = ns.Prices and ns.Prices:GetTable() or {}
    for index, row in ipairs(shown or fresh) do
        if index > 5 then break end
        local record = prices[row.itemID] or {}
        ns.Print(("vendordeals: %s (%d): buy %s, vendor pays %s, last seen %s%s, cheapest other seller %s, lone low %s, yours %s")
            :format(row.name or "?", row.itemID,
                Util.FormatMoney(row.buy, { noColor = true }),
                Util.FormatMoney(row.vendor, { noColor = true }),
                Ago(record.seen),
                (lastScan and record.seen and record.seen < lastScan) and " (NOT in the last scan)" or "",
                record.rivalMin and Util.FormatMoney(record.rivalMin, { noColor = true }) or "none",
                record.ignoredLow and Util.FormatMoney(record.ignoredLow, { noColor = true }) or "none",
                record.ownMin and Util.FormatMoney(record.ownMin, { noColor = true }) or "none"))
    end
end)

--------------------------------------------------------------------------------
-- /bts sellprice: what each source says a vendor pays for one item
--------------------------------------------------------------------------------

ns.RegisterCommand("sellprice", L["say what the item info and the tooltip each say a vendor pays for an item"], function(input)
    input = type(input) == "string" and input or ""
    local itemID = tonumber(input) or tonumber(input:match("item:(%d+)"))
    if not itemID then
        ns.Print("sellprice: give an item ID or shift-click an item, e.g. /bts sellprice 11288")
        return
    end

    local info
    if Util.HasFunction("C_Item.GetItemInfo") then
        local ok, name, _, _, _, _, _, _, _, _, _, sellPrice = pcall(C_Item.GetItemInfo, itemID)
        if ok and name then info = sellPrice end
    end
    local tooltip, read, charges = Util.GetTooltipSellPrice(itemID)
    local saved = ns.Disenchant:GetSellPrice(itemID)
    local paid, paidFrom
    if ns.Vendor and ns.Vendor.GetPaid then paid, paidFrom = ns.Vendor:GetPaid(itemID) end

    local function Money(copper) return copper and Util.FormatMoney(copper, { noColor = true }) or "none" end
    local paidText = paid and (paidFrom == "sold" and "a vendor paid you %s" or "reported on Forever as %s"):format(Money(paid))
        or "never seen sold"
    ns.Print(("sellprice: %s (%d): item info %s, tooltip %s%s%s, %s, used %s")
        :format(Util.GetItemLabel(itemID), itemID, Money(info), Money(tooltip),
            read and "" or " (no tooltip data)",
            charges and (", %d charges"):format(charges) or "",
            paidText, Money(saved)))
end)
