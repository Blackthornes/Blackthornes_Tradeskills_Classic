-- A price check that another search pushed out of the way.
--
-- Search results are one slot of client state, so a new targeted search
-- replaces the pending one. The replaced search's caller used to hear
-- nothing: its five-second fallback then fired and listed at the last known
-- price, unchecked, while "verify price before posting" was on. Two quick
-- List clicks were enough. Now the replaced caller is told at once, and
-- Posting lists nothing on a check that never happened.

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
C_Timer = {
    NewTimer = function(_, fn) return { Cancel = function() end } end,
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

print("\na price check pushed aside by another")

Prices:Record(2589, 300, 300, 40, time(), 300, nil)
Prices:Record(4306, 900, 900, 3, time(), 900, nil)

-- Click List on the first item, then on the second before the first answers.
check("the first check goes out", Posting:Request(2589, 1))
check("the second check goes out", Posting:Request(4306, 1) and searches == 2)

check("the first item was not listed on an unchecked price", #confirmed == 0)
check("and the player was told to click again",
    printed[#printed] and printed[#printed]:find("interrupted", 1, true) ~= nil)

-- The fallbacks fire. The first was settled by the interruption, so only the
-- second one proceeds, and it says its check never came back.
for _, fn in ipairs(timers) do fn() end
check("the first fallback listed nothing", #confirmed == 1 and confirmed[1].itemID == 4306)
check("the second is honest about its check", confirmed[1].state == "unavailable")

-- A search that is somebody else's (a scan's follow-up for an item already
-- listed) is still out when the player clicks List on that item. The click
-- is answered as "recent" and must still bring up the dialog: waiting for
-- that search to do it left the click doing nothing at all.
print("\na search still out that is not a click's")
confirmed, timers = {}, {}
Scanner:ClearSearchState()
Scanner.recentItemScans = {}
Scanner:ScanItem(2589, nil)
check("the follow-up is out", Scanner.pendingItem and Scanner.pendingItem.itemID == 2589)
Posting:Request(2589, 1)
check("the click still brings up the dialog", #confirmed == 1 and confirmed[1].itemID == 2589)

-- Walking away from the auction house while a check is out. The scanner
-- drops its search on close without calling back, so the five-second
-- fallback used to pop a confirm up out in the world.
print("\nwalking away while a check is out")
confirmed, timers = {}, {}
Scanner:ClearSearchState()
Scanner.recentItemScans = {}
Posting.requesting = {}
Posting:Request(4306, 1)
Scanner.isAuctionHouseOpen = false
Scanner:ClearSearchState()
for _, fn in ipairs(timers) do fn() end
check("no confirm once the auction house has closed", #confirmed == 0)
Scanner.isAuctionHouseOpen = true

-- Listed before your auctions had been read this visit. The count it was
-- measured against was last session's, and two of those have since sold, so
-- a listing that went up read as "did not appear in your auctions".
print("\na listing made before the first read of your auctions")
warned = {}
Posting.pending = { itemID = 2589, postedBefore = 3, idsBefore = nil }
Posting:ResolvePending(2, false)
check("not reported as failed", #warned == 0)

-- With a reading from this visit to compare against, missing is missing.
warned = {}
Posting.pending = { itemID = 2589, postedBefore = 3, idsBefore = { [11] = true } }
Posting:ResolvePending(3, false)
check("a checked listing that is not there still warns", #warned > 0)

-- And nothing there at all is a failure either way.
warned = {}
Posting.pending = { itemID = 2589, postedBefore = 3, idsBefore = nil }
Posting:ResolvePending(0, false)
check("nothing listed at all still warns", #warned > 0)

print(("\n%d check(s) passed\n"):format(checks))
