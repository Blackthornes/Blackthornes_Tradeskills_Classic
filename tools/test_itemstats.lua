-- The Stats tab (asked 2026-10-14): one item at a time, in charts.
--
-- What must hold:
--   1. The ninety days keep one day a line, the cheapest of the day and its
--      newest sales count, only for kept items, and let go past ninety.
--   2. A full scan counts sellers and shares, and keeps no name.
--   3. A sale is timed from your oldest posting of the item, by when the
--      mail says it sold; an expiry or cancellation only takes a posting.
--   4. Prices:Record and CommitScan feed it; Mail's new ledger entry too.
--   5. ItemStats:Build works out the week's change, the heat by day and
--      hour, the listings, sales by week with the best week, and money by
--      method; a module that raises costs only its own part.
--   6. The tab's list holds what you craft, star and sell, sold most first,
--      and a search finds any priced item by its saved name.

time = time or os.time
date = date or os.date

local DAY, HOUR = 86400, 3600
local now = 1790000000
local clock = now
time = function() return clock end

local passed, failed = 0, 0
local function check(label, got, want)
    if got == want then
        passed = passed + 1
        print(("  ok    %-62s %s"):format(label, tostring(got)))
    else
        failed = failed + 1
        print(("  FAIL  %-62s got %s, want %s"):format(label, tostring(got), tostring(want)))
    end
end

local realm = "Forever-Alliance"
local BOLT, WOOL, OTHER, STARRED = 2996, 2589, 9999, 4306

local ns = {}
ns.L = setmetatable({ Format = string.format }, { __index = function(_, key) return key end })
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.Util = {
    Clamp = function(v, l, h) return math.max(l, math.min(h, v)) end,
    Count = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end,
    FormatMoney = function(c) return tostring(c) end,
    FormatAge = function() return "" end,
    HasFunction = function() return false end,
    GetItemLabel = function(i) return "item" .. tostring(i) end,
    Comma = function(n) return tostring(n) end,
}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.commands = {}
ns.RegisterCommand = function(name, _, fn) ns.commands[name] = fn end
ns.RegisterEvent = function() end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end
ns.db = {
    prices = {},
    favouritePrices = { [STARRED] = "Spider Silk" },
    characters = {
        ["Ana-Forever"] = {
            recipes = {
                [2963] = { name = "Bolt of Woolen Cloth", outputItemID = BOLT,
                    reagents = { { itemID = WOOL, quantity = 3 } } },
            },
        },
    },
}
ns.Config = {
    Get = function() return nil end,
    GetRealmKey = function() return realm end,
    GetPriceTable = function()
        ns.db.prices[realm] = ns.db.prices[realm] or {}
        return ns.db.prices[realm]
    end,
}

assert(loadfile(lfs_cwd .. "/Data/Prices.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Data/PriceHistory.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Data/StatsLog.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/ItemStats.lua"))("Blackthornes_TS", ns)

local S = ns.StatsLog

print("ninety days")
S:NoteDay(OTHER, 100, 1, now)
check("an item nobody crafts with is not kept", ns.db.statsDays == nil, true)

S:NoteDay(BOLT, 300, 2, now)
S:NoteDay(BOLT, 250, 5, now + HOUR)
S:NoteDay(BOLT, 280, 4, now + 2 * HOUR)
local days = S:GetDays(BOLT)
check("three scans in a day keep one day", #days, 1)
check("the day keeps its cheapest", days[1].cheapest, 250)
check("and its highest sales count", days[1].sold, 5)

S:NoteDay(BOLT, 260, 1, now + DAY)
check("the next day adds a line", #S:GetDays(BOLT), 2)
S:NoteDay(BOLT, 10, 1, now - DAY)
check("an older day is left out", #S:GetDays(BOLT), 2)
S:NoteDay(BOLT, nil, 3, now + 2 * DAY)
check("a day with nothing listed keeps no price", S:GetDays(BOLT)[3].cheapest, nil)
S:NoteDay(BOLT, 270, 0, now + 95 * DAY)
days = S:GetDays(BOLT)
check("past ninety days the old ones go", #days, 1)
check("leaving the new day", days[1].cheapest, 270)

print("who sells it")
local listings = {
    { unitPrice = 10, quantity = 20, seller = "Goblin" },
    { unitPrice = 11, quantity = 5, seller = "Goblin" },
    { unitPrice = 12, quantity = 5, seller = "Gnome" },
    { unitPrice = 13, quantity = 10, isOwn = true, seller = "Me" },
}
S:NoteSellers(BOLT, listings, now)
local sellers = S:GetSellers(BOLT)
check("one reading", #sellers, 1)
check("three sellers, you among them", sellers[1].sellers, 3)
check("the biggest holds 25 of 40", sellers[1].top, 63)
check("you hold 10 of 40", sellers[1].yours, 25)
local saved = false
for _, value in ipairs(ns.db.statsSellers[realm][BOLT]) do
    if type(value) == "string" then saved = true end
end
check("no name is kept", saved, false)

S:NoteSellers(BOLT, { { unitPrice = 10, quantity = 3 } }, now)
check("a scan with no names notes nothing", #S:GetSellers(BOLT), 1)
for index = 1, 20 do S:NoteSellers(BOLT, listings, now + index) end
check("the last twelve are kept", #S:GetSellers(BOLT), 12)

print("how fast yours sell")
S:NotePosted(BOLT, 2, now)
S:NotePosted(BOLT, 1, now + 10 * HOUR)
-- Sold an hour after the first posting, its mail read a day later.
local mail = { daysLeft = 30 - 23 / 24 }
S:NoteLedger({ t = now + DAY, kind = "sold", itemID = BOLT }, mail)
local times = S:GetSellTimes(BOLT)
check("a sale is timed from the mail's own time", times and times[1], 1)
S:NoteLedger({ t = now + DAY, kind = "expired", itemID = BOLT }, { daysLeft = 30 })
check("an expiry takes a posting", #ns.db.statsPosts[realm][BOLT], 1)
S:NoteLedger({ t = now + 12 * HOUR, kind = "sold", itemID = BOLT }, { daysLeft = 30 })
times = S:GetSellTimes(BOLT)
check("a sale two hours after its posting", times[2], 1)
check("the posting list is let go once empty", ns.db.statsPosts[realm][BOLT], nil)
S:NoteLedger({ t = now + 13 * HOUR, kind = "sold", itemID = BOLT }, {})
check("a sale with no posting is not timed", S:GetSellTimes(BOLT)[1] + S:GetSellTimes(BOLT)[2], 2)
check("buckets: 30 hours is longer", S.Bucket(30 * HOUR), 4)
check("buckets: 9 hours is 8 to 24", S.Bucket(9 * HOUR), 3)

print("fed by the scans")
ns.db.statsDays, ns.db.statsSellers = nil, nil
ns.Prices:CommitScan({ [BOLT] = {
    { unitPrice = 300, quantity = 4, seller = "Goblin" },
    { unitPrice = 320, quantity = 2, seller = "Gnome" },
} }, now)
check("a full scan notes the day", #S:GetDays(BOLT), 1)
check("with its cheapest", S:GetDays(BOLT)[1].cheapest, 300)
check("and counts the sellers", S:GetSellers(BOLT)[1].sellers, 2)

print("the item's numbers")
clock = now
ns.PriceHistory.Retrack(ns.PriceHistory)
-- A week of prices: cheap at 4am, dear at 8pm.
ns.db.priceHistory = nil
for d = 6, 1, -1 do
    local base = now - d * DAY
    ns.PriceHistory:Note(BOLT, 200, base - (base % DAY) + 4 * HOUR)
    ns.PriceHistory:Note(BOLT, 400, base - (base % DAY) + 20 * HOUR)
end
ns.Mail = {
    GetLedger = function()
        return { entries = {
            { t = now - 3 * DAY, kind = "sold", itemID = BOLT, net = 900, quantity = 3 },
            { t = now - 9 * DAY, kind = "sold", itemID = BOLT, net = 400, quantity = 2 },
            { t = now - 1 * DAY, kind = "sold", itemID = BOLT, net = 500, quantity = 1 },
            { t = now - 2 * DAY, kind = "expired", itemID = BOLT, quantity = 1 },
            { t = now - 2 * DAY, kind = "sold", itemID = WOOL, net = 50 },
        } }
    end,
    NameIndex = function() return {} end,
    GetSummary = function() return { sold = 3, soldUnits = 6, expired = 1, cancelled = 0, net = 1800, sellThrough = 0.75 } end,
    GetRecent = function(_, _, itemID)
        local out = {}
        for _, entry in ipairs(ns.Mail.GetLedger().entries) do
            if entry.itemID == itemID then out[#out + 1] = entry end
        end
        return out
    end,
}
ns.MethodProfit = {
    METHODS = { { key = "crafted", text = "Crafted" }, { key = "other", text = "Other sales" } },
    Summary = function()
        return { methods = {
            crafted = { items = { [BOLT] = { n = 4, income = 1400, cost = 600, unknown = 0 } } },
            other = { items = {} },
        } }
    end,
}
-- The profit engine raises: only the craft's part goes.
ns.Cost = { FindAnyRecipeForItem = function() return 2963 end }
ns.Profit = { Analyse = function() error("boom") end }

local stats = ns.ItemStats:Build(BOLT, now)
check("worth now from the price table", stats.worth ~= nil, true)
check("a week ago from the graph's oldest days", stats.worthBefore ~= nil, true)
check("set against the cheapest listed now, not the market value",
    stats.change, (ns.Prices.LowestListed(ns.Prices:Get(BOLT)) - stats.worthBefore) / stats.worthBefore)
do
    -- With market values from a week back, those are what it is set against.
    local record = ns.Prices:Get(BOLT)
    local savedTrend, savedMarket = record.trend, record.market
    local today = math.floor(now / DAY)
    record.market = 500
    record.trend = { today - 6, 400, today - 1, 450 }
    local weekly = ns.ItemStats:Build(BOLT, now)
    check("a week ago from the market values kept day by day", weekly.worthBefore, 400)
    check("set against the market value now", weekly.change, 0.25)
    record.trend, record.market = savedTrend, savedMarket
end
check("a raising profit engine leaves the craft bare", stats.craft and stats.craft.recipeID, 2963)
check("and no profit", stats.craft.profitEach, nil)
check("the heat saw 12 prices", stats.heat.count, 12)
check("cheapest cell is the 4am price", stats.heat.low, 200)
check("dearest cell is the 8pm price", stats.heat.high, 400)
local fourAm = date("*t", (now - DAY) - ((now - DAY) % DAY) + 4 * HOUR)
check("a 4am cell is filled", stats.heat.cells[fourAm.wday][fourAm.hour + 1], 200)
check("listings: best sale each", stats.listings.bestEach, 500)
check("weeks: this week holds two sales", stats.weeks[1].units, 4)
check("weeks: last week one", stats.weeks[2].units, 2)
check("weeks: this week is the best", stats.weeks.best, 1)
check("weeks: the other item is not counted", stats.weeks[1].net, 1400)
check("methods: crafted made 800", stats.methods[1].profit, 800)
check("sources: your scans first", stats.sources[1] and stats.sources[1].key, "scans")
check("ninety days carried", #stats.days, 1)
check("the key moves with the clock's hour",
    ns.ItemStats:Key(BOLT) ~= (function() clock = now + 2 * HOUR; return ns.ItemStats:Key(BOLT) end)(), true)
clock = now

-- Demand as numbers (a player asked, 2026-10-16): what the market does.
do
    local savedShare, savedUnits = ns.Prices.GetSalesPerDay, ns.Prices.GetUnitsSoldPerDay
    ns.Prices.GetSalesPerDay = function() return 0.18 end
    ns.Prices.GetUnitsSoldPerDay = function() return 4.2 end
    ns.Demand = { MarketLevel = function(share) return share >= 0.3 and "high" or share >= 0.1 and "some" or "low" end }
    local record = ns.Prices:Get(BOLT)
    local savedQuantity = record.quantity
    record.quantity = 21
    local market = ns.ItemStats:Build(BOLT, now).market
    check("market: the share of stock gone a day", market and market.share, 0.18)
    check("market: about how many go a day", market and market.perDay, 4.2)
    check("market: how many are up now", market and market.listed, 21)
    check("market: five days to sell what is up", market and market.daysToSell, 5)
    check("market: 18% is some", market and market.level, "some")
    ns.Prices.GetSalesPerDay = function() return nil end
    check("market: nothing without a share", ns.ItemStats:Build(BOLT, now).market, nil)
    ns.Prices.GetSalesPerDay, ns.Prices.GetUnitsSoldPerDay = savedShare, savedUnits
    record.quantity = savedQuantity
    ns.Demand = nil
    stats.market = market
end

local bare = ns.ItemStats:Build(OTHER, now)
check("an item with nothing kept still builds", bare.itemID, OTHER)
check("with no weeks", bare.weeks, nil)
check("and an empty heat", bare.heat.count, 0)

print("the tab's list")
ns.Theme, ns.Widgets = {}, {}
ns.UI = { RegisterTab = function(_, tab) ns.statsTab = tab end }
ns.Prices.GetFavourites = function() return ns.db.favouritePrices end
assert(loadfile(lfs_cwd .. "/UI/Tab_Stats.lua"))("Blackthornes_TS", ns)

check("it hands Prices its Stats view", ns.StatsUI.view and ns.StatsUI.view.key, "stats")
check("the command registers", type(ns.commands.stats), "function")

local rows = ns.UI._StatsList("")
local found = {}
for index, row in ipairs(rows) do found[row.itemID] = index end
check("what you craft is listed", found[BOLT] ~= nil, true)
check("what you starred is listed", found[STARRED] ~= nil, true)
check("what you sold is listed", found[WOOL] ~= nil, true)
check("an item you never touched is not", found[OTHER], nil)
check("sold most in 30 days comes first", rows[1].itemID, BOLT)

ns.Prices:Record(OTHER, 300, 100, 5, now)
check("a search by saved name finds it", #ns.UI._StatsList("woolen"), 1)
check("a search finds a priced item by ID", ns.UI._StatsList(tostring(OTHER))[1].itemID, OTHER)
check("an item link gives its ID", ns.StatsUI.ItemFromText("|Hitem:2996::|h[Bolt]|h"), BOLT)
check("a name gives its item", ns.StatsUI.ItemFromText("Spider Silk"), STARRED)
check("nothing gives nothing", ns.StatsUI.ItemFromText("  "), nil)

do
    local lines = ns.StatsUI.MarketLines(stats)
    local byName = {}
    for _, line in ipairs(lines) do byName[line[1]] = line[2] end
    check("hover: sells about 4 a day", byName["Sells a day"], "about 4")
    check("hover: 21 up now", byName["Up for sale now"], "21")
    check("hover: 18% of the stock", byName["Stock that sells a day"], "18%")
    check("hover: about 5 days to sell", byName["Time to sell what's up"], "about 5 days")
    check("hover: your own listings last", lines[#lines][1], "Your own listings")
    check("hover: nothing for nothing", #ns.StatsUI.MarketLines({}), 0)
end

-- Every card says what it shows on hover.
do
    local missing = 0
    for _, card in ipairs(ns.StatsUI.CARDS or {}) do
        if type(card.hint) ~= "string" or card.hint == "" then missing = missing + 1 end
    end
    check("every card has a hover", #(ns.StatsUI.CARDS or {}) > 0 and missing, 0)
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then error(("%d item stats check(s) failed"):format(failed)) end
