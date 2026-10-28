-- A price check replaced in the throttle queue before it was sent.
--
-- Core/AHQueue.lua replaces a queued request that shares a key, and only then
-- tells the replaced one to give up. Scanner:ScanItem's give-up used to read
-- the shared pendingItem slot, which by then held the NEW request: it cleared
-- it, told the new caller "unavailable", and the new search never went out.
-- Posting then confirmed at the unverified price, the case "verify price
-- before posting" exists to prevent. Two List clicks a second apart during a
-- scan were enough.

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

-- The queue's keyed replacement, exactly as Core/AHQueue.lua does it (and as
-- tools/test_throttle.lua pins down): the new request takes the slot first,
-- then the replaced request's give-up runs.
local queued = {}
local function WhenAuctionReady(action, onGiveUp, opts)
    local request = { action = action, onGiveUp = onGiveUp, key = opts and opts.key }
    for i = 1, #queued do
        if queued[i].key == request.key then
            local replaced = queued[i]
            queued[i] = request
            if replaced.onGiveUp then pcall(replaced.onGiveUp) end
            return
        end
    end
    queued[#queued + 1] = request
end
local function Drain()
    local pending = queued
    queued = {}
    for _, request in ipairs(pending) do request.action() end
end

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
    WhenAuctionReady = WhenAuctionReady,
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

local timers = {}
C_Timer = {
    NewTimer = function(_, fn) return { Cancel = function() end } end,
    After = function(_, fn) timers[#timers + 1] = fn end,
    NewTicker = function() return { Cancel = function() end } end,
}

local searched = {}
C_AuctionHouse = {
    MakeItemKey = function(itemID) return { itemID = itemID } end,
    SendSearchQuery = function(itemKey) searched[#searched + 1] = itemKey.itemID return true end,
    GetNumItemSearchResults = function() return 0 end,
}

assert(loadfile(lfs_cwd .. "/Data/Prices.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Data/Scanner.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Profit.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Posting.lua"))("Blackthornes_TS", ns)

local Scanner, Prices, Posting = ns.Scanner, ns.Prices, ns.Posting
Scanner.isAuctionHouseOpen = true

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

print("\na price check replaced in the queue before it was sent")

Prices:Record(2589, 300, 300, 40, time(), 300, nil)
Prices:Record(4306, 900, 900, 3, time(), 900, nil)

-- Click List on one item, then on another while the first is still queued.
check("the first check is queued", Posting:Request(2589, 1) and #queued == 1)
check("the second replaces it in the queue", Posting:Request(4306, 1) and #queued == 1)

check("the second check is still waiting for its turn",
    Scanner.pendingItem ~= nil and Scanner.pendingItem.itemID == 4306)
check("nobody was told the auction house was busy", #warned == 0)
check("the first item was not listed on an unchecked price", #confirmed == 0)

-- The queue gets to it.
Drain()
check("the second search went out", #searched == 1 and searched[1] == 4306)

-- The fallbacks fire. The first was settled by the interruption; the second is
-- still waiting on the search it sent, so its fallback is honest about that.
for _, fn in ipairs(timers) do fn() end
check("the first fallback listed nothing", #confirmed == 1 and confirmed[1].itemID == 4306)

print(("\n%d check(s) passed\n"):format(checks))
