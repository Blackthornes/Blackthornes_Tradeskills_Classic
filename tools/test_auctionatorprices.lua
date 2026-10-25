-- Auctionator's prices, after TradeSkillMaster's (asked 2026-10-12).
--
-- What must hold:
--   1. Without Auctionator loaded, nothing changes.
--   2. An item nobody has priced takes Auctionator's price, asked with our
--      caller ID; "rival" never asks.
--   3. Your own scan wins, and TSM's comes before Auctionator's.
--   4. Unticked, Auctionator is never asked.
--   5. An Auctionator error, a non-number or a silly number is no price.
--   6. Answers are kept for a while, so a redraw does not ask again.
--   7. A stale price of your own gives way to Auctionator's only when
--      Auctionator saw the item a whole day later; a fresh one never asks.

local GLOBALS = { "TSM_API", "Auctionator", "GetTime" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.Util = {
    Clamp = function(v, l, h) return math.max(l, math.min(h, v)) end,
    Count = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end,
    FormatMoney = function(c) return tostring(c) end,
    FormatAge = function() return "" end,
    HasFunction = function() return false end,
    GetItemLabel = function(i) return "item" .. tostring(i) end,
}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end
local priceTable = {}
local settings = {}
ns.Config = {
    Get = function(_, key) return settings[key] end,
    GetPriceTable = function() return priceTable end,
}
ns.db = {}
time = time or os.time

local clock = 100
GetTime = function() return clock end
TSM_API = nil
Auctionator = nil

assert(loadfile(lfs_cwd .. "/Data/Prices.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/TSMPrices.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/AuctionatorPrices.lua"))("Blackthornes_TS", ns)
local Prices, Auc = ns.Prices, ns.AuctionatorPrices

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

print("\nAuctionator prices")

check("without Auctionator an unpriced item has no price", Prices:GetValue(2589) == nil)

local asked = {}
local price = 777.6
Auctionator = { API = { v1 = {
    GetAuctionPriceByItemID = function(caller, itemID)
        if type(caller) ~= "string" then error("bad caller") end
        asked[#asked + 1] = caller .. " " .. itemID
        return price
    end,
} } }

check("an unpriced item takes Auctionator's price", Prices:GetValue(2589) == 778)
check("asked with our caller ID", asked[1] == "Blackthornes_TS 2589")
check("min gets the same price", Prices:GetValue(2589, "min") == 778)
check("rival never asks Auctionator", Prices:GetValue(2589, "rival") == nil)

local before = #asked
Prices:GetValue(2589, "lowest")
check("a second look within the minute is kept", #asked == before)
clock = clock + 61
Prices:GetValue(2589)
check("and asked again after", #asked == before + 1)

TSM_API = { GetCustomPriceValue = function() return 500 end }
Auc:Forget()
check("TSM's price comes before Auctionator's", Prices:GetValue(2590) == 500)
-- Price Order set to Auctionator first (the owner, 2026-10-25).
settings.priceOrder = "auctionator"
Auc:Forget()
check("Auctionator first takes Auctionator's price", Prices:GetValue(2590) == 778)
price = nil
Auc:Forget()
check("Auctionator first still falls back to TSM", Prices:GetValue(2590) == 500)
price = 777.6
settings.priceOrder = nil
Auc:Forget()
TSM_API = nil

priceTable[2589] = { market = 300, scans = 1, history = {}, seen = time() }
check("your own scan wins", Prices:GetValue(2589) == 300)

-- 7. Stale own prices and Auctionator's age.
local ageAsked = 0
local ageDays = 0
Auctionator.API.v1.GetAuctionAgeByItemID = function(caller, itemID)
    if type(caller) ~= "string" then error("bad caller") end
    ageAsked = ageAsked + 1
    return ageDays
end
Auc:Forget()
check("a fresh own price never asks Auctionator's age",
    Prices:GetValue(2589) == 300 and ageAsked == 0)
priceTable[2589].seen = time() - 3 * 86400
check("a stale own price gives way to a newer Auctionator price", Prices:GetValue(2589) == 778)
Auc:Forget()
ageDays = 3
check("not when Auctionator saw it no later", Prices:GetValue(2589) == 300)
Auc:Forget()
ageDays = 2
check("a whole day younger is newer", Prices:GetValue(2589) == 778)
Auc:Forget()
ageDays = nil
check("no age from Auctionator keeps your price", Prices:GetValue(2589) == 300)
Auc:Forget()
ageDays = 0
check("rival is still your own", Prices:GetValue(2589, "rival") == nil)
Auctionator.API.v1.GetAuctionAgeByItemID = function() error("boom") end
Auc:Forget()
check("an age error keeps your price", Prices:GetValue(2589) == 300)
Auctionator.API.v1.GetAuctionAgeByItemID = nil
Auc:Forget()
check("an Auctionator with no age call keeps your price", Prices:GetValue(2589) == 300)
priceTable[2589].seen = time()

settings.auctionatorPrices = false
Auc:Forget()
before = #asked
check("unticked, Auctionator gives nothing", Prices:GetValue(2591) == nil and #asked == before)
settings.auctionatorPrices = nil

Auc:Forget()
Auctionator.API.v1.GetAuctionPriceByItemID = function() error("boom") end
check("an Auctionator error is no price", Prices:GetValue(2592) == nil)
Auc:Forget()
Auctionator.API.v1.GetAuctionPriceByItemID = function() return "12" end
check("a string is no price", Prices:GetValue(2593) == nil)
Auc:Forget()
Auctionator.API.v1.GetAuctionPriceByItemID = function() return 0 end
check("zero is no price", Prices:GetValue(2594) == nil)
Auctionator = { API = {} }
check("an Auctionator without the v1 API counts as not loaded", not Auc:Loaded())

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end
print(("\n%d check(s) passed\n"):format(checks))
