-- TradeSkillMaster's prices as a last resort (asked 2026-10-12).
--
-- What must hold:
--   1. Without TSM loaded, nothing changes.
--   2. An item nobody has priced takes TSM's DBRecent (market) or
--      DBMinBuyout (min, lowest); "rival" never asks TSM.
--   3. Your own scan always wins over TSM's.
--   4. Unticked, TSM is never asked.
--   5. A TSM error, a non-number or a silly number counts as no price.
--   6. Answers are kept for a while, so a redraw does not ask TSM again.

local GLOBALS = { "TSM_API", "GetTime" }
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

assert(loadfile(lfs_cwd .. "/Data/Prices.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/TSMPrices.lua"))("Blackthornes_TS", ns)
local Prices, TSM = ns.Prices, ns.TSMPrices

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

print("\nTSM prices")

check("without TSM an unpriced item has no price", Prices:GetValue(2589) == nil)

local asked = {}
local answers = { DBRecent = 1234.4, DBMinBuyout = 999 }
TSM_API = {
    GetCustomPriceValue = function(source, item)
        asked[#asked + 1] = source .. " " .. item
        return answers[source]
    end,
}

check("an unpriced item takes TSM's market value", Prices:GetValue(2589) == 1234)
check("asked for DBRecent by TSM's item string", asked[1] == "DBRecent i:2589")
check("min reads DBMinBuyout", Prices:GetValue(2589, "min") == 999)
check("lowest reads DBMinBuyout", Prices:GetValue(2589, "lowest") == 999)
check("rival never asks TSM", Prices:GetValue(2589, "rival") == nil)

local before = #asked
Prices:GetValue(2589)
check("a second look within the minute is kept", #asked == before)
clock = clock + 61
Prices:GetValue(2589)
check("and asked again after", #asked == before + 1)

priceTable[2589] = { market = 500, scans = 1, history = {}, seen = time() }
check("your own scan wins", Prices:GetValue(2589) == 500)
check("the scans alone never include TSM", Prices:GetScanValue(2590) == nil)

settings.tsmPrices = false
TSM:Forget()
before = #asked
check("unticked, TSM gives nothing", Prices:GetValue(2590) == nil and #asked == before)
settings.tsmPrices = nil

TSM:Forget()
TSM_API.GetCustomPriceValue = function() error("boom") end
check("a TSM error is no price", Prices:GetValue(2591) == nil)
TSM:Forget()
TSM_API.GetCustomPriceValue = function() return "12" end
check("a string is no price", Prices:GetValue(2592) == nil)
TSM:Forget()
TSM_API.GetCustomPriceValue = function() return -5 end
check("a negative number is no price", Prices:GetValue(2593) == nil)
TSM:Forget()
TSM_API.GetCustomPriceValue = function() return 0/0 end
check("NaN is no price", Prices:GetValue(2594) == nil)
TSM_API = { GetCustomPriceValue = "nope" }
check("an API without the call counts as not loaded", not TSM:Loaded())

-- "TSM Price Source:" (2026-11-13): the price "market" reads.
print("\nTSM price source")
priceTable = {}
local reads, valid = {}, { DBMarket = true, ["dbmarket*1.1"] = true }
local noRecent = {}
TSM_API = {
    GetCustomPriceValue = function(source, item)
        reads[#reads + 1] = source
        if source == "DBRecent" then return not noRecent[item] and 1234 or nil end
        if source == "dbmarket*1.1" then return nil end
        if source == "DBMarket" then return 777 end
        if source == "DBMinBuyout" then return 999 end
    end,
    IsCustomPriceValid = function(text) return valid[text] == true end,
}
TSM:Forget()
check("no source typed reads DBRecent", Prices:GetValue(3001) == 1234 and reads[#reads] == "DBRecent")
noRecent["i:3009"] = true
check("no DBRecent price falls back to DBMarket", Prices:GetValue(3009) == 777 and reads[#reads] == "DBMarket")
settings.tsmPriceSource = "  DBMarket  "
TSM:Forget()
check("a typed source is read, trimmed", Prices:GetValue(3002) == 777 and reads[#reads] == "DBMarket")
check("min still reads DBMinBuyout", Prices:GetValue(3002, "min") == 999 and reads[#reads] == "DBMinBuyout")
check("a known source is not refused", not TSM:SourceRefused())
settings.tsmPriceSource = "dbmarket*1.1"
TSM:Forget()
check("a source that gives nothing falls back to DBRecent", Prices:GetValue(3003) == 1234 and reads[#reads] == "DBRecent")
settings.tsmPriceSource = "NotAPrice"
TSM:Forget()
check("a source TSM doesn't know is refused", TSM:SourceRefused())
check("and reads DBRecent", Prices:GetValue(3004) == 1234 and reads[#reads] == "DBRecent")
valid.NotAPrice = true
check("validity is kept until forgotten", TSM:SourceRefused())
TSM:Forget()
check("Forget asks TSM again", not TSM:SourceRefused())
settings.tsmPriceSource = ""
TSM:Forget()
check("an empty box reads DBRecent", TSM:MarketSource() == "DBRecent")
settings.tsmPriceSource = "NotAPrice"
TSM_API.IsCustomPriceValid = nil
TSM:Forget()
check("without the check call the source is tried as typed", TSM:MarketSource() == "NotAPrice")
TSM_API.IsCustomPriceValid = function() error("boom") end
TSM:Forget()
check("a check that raises is tried as typed", TSM:MarketSource() == "NotAPrice")
TSM_API = nil
check("without TSM nothing is refused", not TSM:SourceRefused())
settings.tsmPriceSource = nil

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end
print(("\n%d check(s) passed\n"):format(checks))
