-- A price check whose answer arrives after its five-second fallback.
--
-- The fallback brings the confirm up at the last known price, but the search
-- itself waits up to eight seconds. That late answer is not the check the
-- player was shown: it must not warn again, bring up a second confirm, or
-- count as a recent check that lets the next click skip searching.

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() return true end
local printed = {}
ns.Print = function(text) printed[#printed + 1] = text end
local warned = {}
ns.PrintRaw, ns.Debug = function() end, function() end
ns.Warn = function(text) warned[#warned + 1] = text end

ns.Util = {
    Clamp = function(v, l, h) return math.max(l, math.min(h, v)) end,
    Count = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end,
    Comma = tostring,
    FormatMoney = function(c) return tostring(c) end,
    FormatAge = function() return "" end,
    FormatAgeAgo = function() return "" end,
    GetItemLabel = function(i) return "item" .. tostring(i) end,
    GetMaxStackSize = function() return 20 end,
    GetVendorSellPrice = function() return nil end,
    UnitPriceFromStack = function(_, buyout, quantity) return math.floor(buyout / (quantity or 1)) end,
    HasFunction = function() return false end,
    RoundToSilver = function(p) if p < 100 then return 100 end return math.floor(p / 100) * 100 end,
    IsWholeSilver = function(p) return p >= 100 and p % 100 == 0 end,
    -- No AHQueue here, so the search goes out at once.
    WhenAuctionReady = function(action) action() end,
}

local priceTable = {}
ns.Config = {
    Get = function(_, key)
        if key == "undercutCopper" then return 1 end
        if key == "verifyPriceBeforePosting" then return true end
        if key == "askBeforeListing" then return true end
        return nil
    end,
    GetPriceTable = function() return priceTable end,
    GetRealmKey = function() return "TestRealm" end,
}
ns.db = {}
ns.Cost = { FindRecipeForItem = function() return nil end }
ns.Cost.FindAnyRecipeForItem = ns.Cost.FindRecipeForItem
ns.Auctions = { GetPostedCount = function() return 0 end }
ns.AHQueue = { PRIORITY = { urgent = 10, normal = 50, scan = 90 } }

time = time or os.time
GetTime = function() return 100 end
Enum = { ItemCommodityStatus = { Commodity = 2 }, BagIndex = {} }
UnitName = function() return "Tester" end
GetRealmName = function() return "TestRealm" end

-- Timers are collected so the five-second fallback can be fired by hand.
local timers = {}
-- The scanner's own eight-second give-up is kept apart, to fire later.
local searchTimers = {}
C_Timer = {
    NewTimer = function(_, fn)
        local t = { fn = fn, cancelled = false }
        t.Cancel = function() t.cancelled = true end
        searchTimers[#searchTimers + 1] = t
        return t
    end,
    After = function(_, fn) timers[#timers + 1] = fn end,
    NewTicker = function() return { Cancel = function() end } end,
}

local searches = 0
C_AuctionHouse = {
    MakeItemKey = function(itemID) return { itemID = itemID } end,
    SendSearchQuery = function() searches = searches + 1 return true end,
    GetNumItemSearchResults = function() return 0 end,
}

assert(loadfile(lfs_cwd .. "/Data/Prices.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Data/Scanner.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Profit.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Posting.lua"))("Blackthornes_TS", ns)

local Scanner, Prices, Posting = ns.Scanner, ns.Prices, ns.Posting
Scanner.isAuctionHouseOpen = true

-- What would have gone up. The confirmation dialog is the step that commits
-- a listing, so recording calls to it is recording what would be listed.
local confirmed = {}
Posting.Confirm = function(_, itemID, quantity, unitPrice, check)
    confirmed[#confirmed + 1] = { itemID = itemID, price = unitPrice, state = check and check.state }
end

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

print("\na price check that answers after its five-second fallback")

Prices:Record(2589, 300, 300, 40, time(), 300, nil)

Posting:Request(2589, 1)
check("the search went out", searches == 1)

-- Five seconds pass with no answer: the confirm comes up at the last price.
for _, fn in ipairs(timers) do fn() end
check("the fallback brought up one confirm", #confirmed == 1 and confirmed[1].state == "unavailable")
check("the search is no longer waited on for this click", Scanner.pendingItem == nil)

-- The scanner's eight-second give-up must not warn a second time about a
-- check the player was already told about.
-- It still settles Blizzard's results panel, though: that timer is the only
-- thing that does when the auction house drops a query without a word.
warned = {}
local settled = {}
local realSettle = Scanner.SettleSearchDisplay
Scanner.SettleSearchDisplay = function(_, reason) settled[#settled + 1] = reason end
for _, t in ipairs(searchTimers) do if not t.cancelled then t.fn() end end
Scanner.SettleSearchDisplay = realSettle
check("no second warning at eight seconds", #warned == 0)
check("the search results panel is still settled", #settled == 1)
check("still only one confirm", #confirmed == 1)

-- Clicking again within twenty seconds must search again. The unanswered
-- search used to count as a recent check, so this click was confirmed as
-- "recent" at a price nobody had checked.
timers = {}
Posting:Request(2589, 1)
check("the next click searches again", searches == 2)
check("and no confirm until it answers or falls back", #confirmed == 1)

-- The price-check button abandons its search the same way.
print("\nthe price-check button")
timers, searchTimers = {}, {}
Scanner:ClearSearchState()
Scanner.recentItemScans = {}
Posting.requesting = {}
local answers = {}
Posting:CheckPrice(2589, function(_, _, status) answers[#answers + 1] = status end)
for _, fn in ipairs(timers) do fn() end
check("the check answers once, unavailable", #answers == 1 and answers[1] == "unavailable")
check("its search is let go", Scanner.pendingItem == nil)

-- Only the caller's own search is let go.
Scanner:ScanItem(4306, nil)
check("someone else's search is not dropped", not Scanner:AbandonItemScan(function() end)
    and Scanner.pendingItem and Scanner.pendingItem.itemID == 4306)

print(("\n%d check(s) passed\n"):format(checks))
