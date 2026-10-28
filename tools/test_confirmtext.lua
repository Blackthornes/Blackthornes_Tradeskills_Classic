-- The posting confirmation says four things and asks one question.
--
-- Asked 2026-09-26: the dialog read oddly. It should say
--   Average Market Value, Lowest Market Posting, Posting at,
--   Do you wish to continue?
-- and nothing else, however the post was started. Every List and Post button
-- goes through Posting:Request, which ends in Posting:Confirm, so this checks
-- the text that dialog is built from.

local ns = {}
ns.COLORS = setmetatable({ accent = "ffc8a44d" }, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() return true end
local printed = {}
ns.Print = function(text) printed[#printed + 1] = text end
ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end

ns.Util = {
    Clamp = function(v, l, h) return math.max(l, math.min(h, v)) end,
    Count = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end,
    Comma = tostring,
    FormatMoney = function(c) return tostring(c) end,
    FormatAge = function() return "" end,
    FormatAgeAgo = function() return "" end,
    GetItemLabel = function(i) return "item" .. tostring(i) end,
    GetMaxStackSize = function() return 20 end,
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


local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

-- Colour codes are left out, so the words can be compared exactly.
local function plain(text)
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function lines(text)
    local out = {}
    for line in (plain(text) .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then out[#out + 1] = line end
    end
    return out
end

print("\nthe posting confirmation")

-- market 500, rival 450 (cheapest), 20 up in all.
Prices:Record(2589, 500, 450, 20, time(), 450, nil)
local l = lines(Posting:BuildConfirmText(2589, 1, 400, { state = "fresh" }))
check("four lines exactly", #l == 4)
check("market value first", l[1] == "Average Market Value: 500")
check("cheapest rival second", l[2] == "Lowest Market Posting: 450")
check("the price being listed third", l[3] == "Posting at: 400, item2589")
check("the question last", l[4] == "List it at this price, or skip it.")

-- The price about to go up is drawn in gold, and only the price.
local raw = Posting:BuildConfirmText(2589, 1, 400, { state = "fresh" })
check("the posting price is in gold",
    raw:find("Posting at: |c" .. ns.COLORS.accent .. "400|r, item2589", 1, true) ~= nil)
check("the other two prices are not", raw:find("Average Market Value: 500\n", 1, true) ~= nil
    and raw:find("Lowest Market Posting: 450\n", 1, true) ~= nil)

local stack = lines(Posting:BuildConfirmText(2589, 5, 400, { state = "fresh" }))
check("a stack says each and how many", stack[3] == "Posting at: 400 each, 5 x item2589")

-- An empty auction house: nobody to undercut.
Prices:RecordEmpty(2589, time())
local empty = lines(Posting:BuildConfirmText(2589, 1, 500, { state = "empty" }))
check("nothing listed reads none", empty[2] == "Lowest Market Posting: none")
check("still four lines", #empty == 4)

-- Only the player's own listing is up.
Prices:Record(4306, 900, 800, 3, time(), nil, 800)
local own = lines(Posting:BuildConfirmText(4306, 1, 800, { state = "fresh" }))
check("only yours says so", own[2] == "Lowest Market Posting: 800 (yours)")

-- A lone low listing was skipped: the line says so.
Prices:Record(2770, 5000, 100, 6, time(), 5000, nil, 100)
local lone = lines(Posting:BuildConfirmText(2770, 1, 4900, { state = "fresh" }))
check("a skipped lone listing is named", lone[2] == "Lowest Market Posting: 5000 (ignored a lone one at 100)" and #lone == 4)

-- A check that never answered.
Prices:Record(3530, 300, 250, 3, time(), 250, nil)
local stale = lines(Posting:BuildConfirmText(3530, 1, 240, { state = "unavailable" }))
check("an unanswered check says so on the same line",
    stale[2] == "Lowest Market Posting: 250 (could not check, last seen)" and #stale == 4)

-- No price ever seen.
local unknown = lines(Posting:BuildConfirmText(9999, 1, 100))
check("no market value reads none", unknown[1] == "Average Market Value: none")

-- Listing below what it cost to make: the one extra line allowed.
ns.Cost.FindRecipeForItem = function() return 1 end
ns.Cost.FindAnyRecipeForItem = ns.Cost.FindRecipeForItem
ns.Profit.Analyse = function() return { costPerUnit = 600 } end
local loss = lines(Posting:BuildConfirmText(3530, 1, 240, { state = "fresh" }))
check("a loss adds one line", #loss == 5 and loss[4]:find("Below the 600 it cost to make", 1, true) ~= nil)
check("and the question stays last", loss[5] == "List it at this price, or skip it.")

print(("\n%d check(s) passed\n"):format(checks))
