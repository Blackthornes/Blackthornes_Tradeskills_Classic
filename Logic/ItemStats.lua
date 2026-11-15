-- Blackthornes Tradeskills -- Logic/ItemStats.lua
-- Everything the Stats tab shows about one item, worked out in one place.
--
-- The owner asked (2026-10-14) for a Stats tab like Farmer's, one item at
-- a time. UI/Tab_Stats.lua only draws; this reads what the addon already
-- keeps (prices, the price graph's hours, the mail ledger, the profit
-- engine, the other price sources) and Data/StatsLog.lua's new records,
-- and hands back one plain table. Every read is in a pcall, so one module
-- that is missing or raises costs only its own chart.
--
-- Built only for the item picked, while the tab shows, and kept until
-- something it reads moves (ItemStats:Key).

local _, ns = ...

local ItemStats = ns.NewModule("ItemStats")

local DAY = 24 * 3600
local WEEK = 7 * DAY

ItemStats.WEEKS = 8
ItemStats.METHOD_DAYS = 30

-- Call `fn` on `module` in a pcall; nil when either is missing or it raises.
local function Ask(module, fn, ...)
    if type(module) ~= "table" or type(module[fn]) ~= "function" then return nil end
    local ok, a, b, c = pcall(module[fn], module, ...)
    if not ok then return nil end
    return a, b, c
end

--- This realm's ledger entries, with the other account's shared sales
--- when Share Sales is on (Mail:Entries), else the ledger alone.
local function LedgerEntries()
    local entries = Ask(ns.Mail, "Entries")
    if type(entries) == "table" then return entries end
    local ledger = Ask(ns.Mail, "GetLedger")
    return type(ledger) == "table" and type(ledger.entries) == "table" and ledger.entries or {}
end

local function Number(value)
    return type(value) == "number" and value == value and value or nil
end

--------------------------------------------------------------------------------
-- The parts
--------------------------------------------------------------------------------

--- What it was worth about a week ago, and what it should be set against
--- now, so the two are the same kind of price. First the market value
--- from 5 to 7 days back (the price table's day by day trend), set against
--- the market value now; else the oldest of the price table's readings, when
--- at least five days old, also a market value; else the price graph's
--- cheapest prices from 5 to 7 days back, set against the cheapest listed now.
-- @return before, now (copper), or nil
local function WorthBefore(itemID, record, now)
    local isRecord = type(record) == "table"
    local market = isRecord and Number(record.market) or nil

    if market and type(record.trend) == "table" then
        local today = math.floor(now / DAY)
        local sum, count = 0, 0
        for index = 1, #record.trend - 1, 2 do
            local day, value = record.trend[index], record.trend[index + 1]
            if Number(day) and Number(value) and value > 0 and day >= today - 7 and day <= today - 5 then
                sum, count = sum + value, count + 1
            end
        end
        if count > 0 then return math.floor(sum / count + 0.5), market end
    end

    local oldest = isRecord and type(record.history) == "table" and record.history[1]
    if market and type(oldest) == "table" and Number(oldest.t) and now - oldest.t >= 5 * DAY
        and Number(oldest.m) then
        return oldest.m, market
    end

    local lowest = isRecord and ns.Prices and ns.Prices.LowestListed
        and Number(ns.Prices.LowestListed(record)) or nil
    if not lowest then return nil end
    local points = Ask(ns.PriceHistory, "GetPoints", itemID, 2 * DAY, now - 5 * DAY) or {}
    local sum, count = 0, 0
    for _, point in ipairs(points) do
        if Number(point.p) then sum, count = sum + point.p, count + 1 end
    end
    if count > 0 then return math.floor(sum / count + 0.5), lowest end
    return nil
end

--- The craft: its recipe, what one costs and where the price goes.
local function Craft(itemID)
    local recipeID = Ask(ns.Cost, "FindAnyRecipeForItem", itemID)
    if not recipeID then return nil end

    local analysis = Ask(ns.Profit, "Analyse", recipeID)
    if type(analysis) ~= "table" then return { recipeID = recipeID } end

    local yield = Number(analysis.yield) or 1
    if yield <= 0 then yield = 1 end

    local craft = {
        recipeID = recipeID,
        yield = yield,
        costEach = Number(analysis.costPerUnit),
        profitEach = Number(analysis.profitPerUnit),
        sellEach = Number(analysis.unitRevenue),
        cutEach = Number(analysis.cut) and analysis.cut / yield or nil,
        depositEach = Number(analysis.deposit) and analysis.deposit / yield or nil,
        via = analysis.via,
        reason = analysis.reason,
        materials = {},
    }

    local cost = Ask(ns.Cost, "GetCraftCost", recipeID)
    for _, reagent in ipairs(type(cost) == "table" and cost.reagents or {}) do
        if type(reagent) == "table" and reagent.itemID then
            craft.materials[#craft.materials + 1] = {
                itemID = reagent.itemID,
                quantity = Number(reagent.quantity) or 1,
                each = Number(reagent.lineCost) and reagent.lineCost / yield or nil,
                source = reagent.source,
            }
        end
    end
    table.sort(craft.materials, function(a, b) return (a.each or 0) > (b.each or 0) end)

    return craft
end

--- The cheapest price by day of the week and hour, from the last seven
--- days: cells[wday][hour + 1] = average copper (wday 1 is Sunday, as the
--- game's date() has it), with the lowest and highest cell and the week's
--- average to shade them against.
local function Heat(itemID, now)
    local points = Ask(ns.PriceHistory, "GetPoints", itemID, WEEK, now) or {}
    local sums, counts = {}, {}
    local total, n = 0, 0

    for _, point in ipairs(points) do
        local price, t = Number(point.p), Number(point.t)
        if price and t then
            local stamp = date("*t", t)
            local wday, hour = stamp.wday, stamp.hour
            sums[wday] = sums[wday] or {}
            counts[wday] = counts[wday] or {}
            sums[wday][hour + 1] = (sums[wday][hour + 1] or 0) + price
            counts[wday][hour + 1] = (counts[wday][hour + 1] or 0) + 1
            total, n = total + price, n + 1
        end
    end

    local heat = { cells = {}, count = n }
    if n == 0 then return heat end
    heat.average = total / n

    for wday = 1, 7 do
        heat.cells[wday] = {}
        for slot = 1, 24 do
            local count = counts[wday] and counts[wday][slot]
            if count then
                local value = sums[wday][slot] / count
                heat.cells[wday][slot] = value
                if not heat.low or value < heat.low then heat.low = value end
                if not heat.high or value > heat.high then heat.high = value end
            end
        end
    end

    local best = Ask(ns.PriceHistory, "GetBestTimes", itemID, now)
    if type(best) == "table" and best.ready and not best.steady then
        heat.buyHour, heat.sellHour = best.buyHour, best.sellHour
        heat.buyBelow, heat.sellAbove = best.buyBelow, best.sellAbove
    elseif type(best) == "table" and best.steady then
        heat.steady = true
    end
    return heat
end

--- Your listings: sold, came back, cancelled, and the best sale each.
local function Listings(itemID)
    local summary = Ask(ns.Mail, "GetSummary", itemID)
    if type(summary) ~= "table" then return nil end

    local listings = {
        sold = summary.sold or 0,
        soldUnits = summary.soldUnits or 0,
        expired = summary.expired or 0,
        cancelled = summary.cancelled or 0,
        net = summary.net or 0,
        sellThrough = summary.sellThrough,
    }

    local recent = Ask(ns.Mail, "GetRecent", 400, itemID) or {}
    for _, entry in ipairs(recent) do
        if type(entry) == "table" and entry.kind == "sold" and Number(entry.net) then
            local each = entry.net / math.max(1, Number(entry.quantity) or 1)
            if not listings.bestEach or each > listings.bestEach then
                listings.bestEach, listings.bestAt = each, entry.t
            end
        end
    end
    return listings
end

--- What the auction house wants, from your scans only (a player asked,
--- 2026-10-16, for numbers rather than High, Some or Low): the share of
--- the stock gone each day, about how many go a day, how many are up now
--- and about how many days those would take to go. nil with no share yet.
local function Market(itemID, record, perDay)
    local share = Number(Ask(ns.Prices, "GetSalesPerDay", itemID))
    if not share then return nil end

    local market = { share = share, perDay = Number(perDay) }
    if record and Number(record.quantity) then
        market.listed = Number(record.quantity)
        market.seen = Number(record.seen)
    end
    if market.listed and market.perDay and market.perDay > 0 then
        market.daysToSell = market.listed / market.perDay
    end
    if ns.Demand and ns.Demand.MarketLevel then market.level = ns.Demand.MarketLevel(share) end
    return market
end

--- Sales by week, from the mail ledger: weeks[1] is the week ending now,
--- weeks[2] the one before, back ItemStats.WEEKS. Each { units, net }.
local function Weeks(itemID, now)
    local weeks = {}
    for index = 1, ItemStats.WEEKS do weeks[index] = { units = 0, net = 0 } end

    local entries = LedgerEntries()
    local names = Ask(ns.Mail, "NameIndex") or {}
    local any = false

    for _, entry in ipairs(entries) do
        local t = Number(entry.t)
        if entry.kind == "sold" and t and t <= now and (entry.itemID or names[entry.name]) == itemID then
            local index = math.floor((now - t) / WEEK) + 1
            local week = weeks[index]
            if week then
                week.units = week.units + math.max(1, Number(entry.quantity) or 1)
                week.net = week.net + (Number(entry.net) or 0)
                any = true
            end
        end
    end
    if not any then return nil end

    local best
    for index, week in ipairs(weeks) do
        if week.net > 0 and (not best or week.net > weeks[best].net) then best = index end
    end
    weeks.best = best
    return weeks
end

--- Where its price comes from, each source's own answer.
local function Sources(itemID)
    local sources = {}
    local function Add(key, value)
        value = Number(value)
        if value and value > 0 then sources[#sources + 1] = { key = key, value = value } end
    end

    Add("scans", Ask(ns.Prices, "GetScanValue", itemID, "market"))
    Add("guild", (Ask(ns.GuildPrices, "GetValue", itemID, "market")))
    if Ask(ns.RealmPrices, "IsOn") then Add("realm", (Ask(ns.RealmPrices, "GetValue", itemID, "market"))) end
    if Ask(ns.TSMPrices, "IsOn") then Add("tsm", Ask(ns.TSMPrices, "GetValue", itemID, "market")) end
    if Ask(ns.AuctionatorPrices, "IsOn") then
        Add("auctionator", Ask(ns.AuctionatorPrices, "GetValue", itemID, "market"))
    end
    if ns.Util and ns.Util.GetVendorSellPrice then
        local ok, value = pcall(ns.Util.GetVendorSellPrice, itemID)
        if ok then Add("vendorPays", value) end
    end
    Add("vendorSells", Ask(ns.Vendor, "GetUnitPrice", itemID))
    return sources
end

--- Money it made in the last ItemStats.METHOD_DAYS days, by how it was made.
local function Methods(itemID, now)
    local summary = Ask(ns.MethodProfit, "Summary", now - ItemStats.METHOD_DAYS * DAY, now + 1)
    if type(summary) ~= "table" or type(summary.methods) ~= "table" then return nil end

    local methods, any = {}, false
    for _, method in ipairs(ns.MethodProfit.METHODS or {}) do
        local group = summary.methods[method.key]
        local item = type(group) == "table" and type(group.items) == "table" and group.items[itemID]
        if type(item) == "table" and (item.n or 0) > 0 then
            methods[#methods + 1] = { key = method.key, n = item.n, income = item.income or 0,
                cost = item.cost or 0, profit = (item.income or 0) - (item.cost or 0), unknown = item.unknown or 0 }
            any = true
        end
    end
    return any and methods or nil
end

--------------------------------------------------------------------------------
-- The whole
--------------------------------------------------------------------------------

--- What the tab shows for `itemID`, as of `now`.
function ItemStats:Build(itemID, now)
    now = now or time()
    local stats = { itemID = itemID, now = now }
    if not itemID then return stats end

    local record = Ask(ns.Prices, "Get", itemID)
    stats.record = type(record) == "table" and record or nil

    stats.worth = Ask(ns.Prices, "GetValue", itemID, "market")
    local against
    stats.worthBefore, against = WorthBefore(itemID, stats.record, now)
    if against and stats.worthBefore and stats.worthBefore > 0 then
        stats.change = (against - stats.worthBefore) / stats.worthBefore
    end

    stats.craft = Craft(itemID)
    stats.soldPerDay = Ask(ns.Prices, "GetUnitsSoldPerDay", itemID)
    stats.market = Market(itemID, stats.record, stats.soldPerDay)
    stats.demand = Ask(ns.Demand, "Get", itemID)
    stats.week = Ask(ns.Demand, "Week", itemID)
    stats.heat = Heat(itemID, now)
    stats.listings = Listings(itemID)
    stats.weeks = Weeks(itemID, now)
    stats.sources = Sources(itemID)
    stats.methods = Methods(itemID, now)

    -- The last twelve scans: how many were listed, and the market value.
    stats.stock = {}
    for _, reading in ipairs(stats.record and type(stats.record.history) == "table" and stats.record.history or {}) do
        if type(reading) == "table" and Number(reading.t) then
            stats.stock[#stats.stock + 1] = { t = reading.t, q = Number(reading.q) or 0, m = Number(reading.m) }
        end
    end

    stats.days = Ask(ns.StatsLog, "GetDays", itemID) or {}
    stats.sellers = Ask(ns.StatsLog, "GetSellers", itemID) or {}
    stats.sellTimes = Ask(ns.StatsLog, "GetSellTimes", itemID)

    return stats
end

--- When any character's recipes were last read, added up, so learning one
--- moves the key.
local function RecipesStamp()
    local stamp = 0
    for _, record in pairs(ns.db and type(ns.db.characters) == "table" and ns.db.characters or {}) do
        if type(record) == "table" and type(record.recipesCachedAt) == "number" then
            stamp = stamp + record.recipesCachedAt
        end
    end
    return stamp
end

--- A key that moves whenever anything Build reads may have moved, so the
--- tab builds again only then.
function ItemStats:Key(itemID)
    local record = ns.Prices and Ask(ns.Prices, "Get", itemID)
    local entries = LedgerEntries()
    local last = entries[#entries]
    return table.concat({
        tostring(itemID),
        tostring(type(record) == "table" and record.seen or 0),
        tostring(ns.PriceHistory and ns.PriceHistory.changes or 0),
        tostring(ns.StatsLog and ns.StatsLog.version or 0),
        tostring(#entries), tostring(type(last) == "table" and last.t or 0),
        tostring(RecipesStamp()),
        -- And the hour, so "this week" and "a week ago" move on.
        tostring(math.floor(time() / 3600)),
    }, ":")
end

--- The week number a time falls in, for the best week's cheer.
function ItemStats.WeekOf(t)
    return math.floor((t or time()) / WEEK)
end
