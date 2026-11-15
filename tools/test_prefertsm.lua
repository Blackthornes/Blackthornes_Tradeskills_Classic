-- "Prefer TSM Prices:" (the owner, 2026-11-12).
--
-- What must hold:
--   1. Off by default: an own scan of any age keeps its price.
--   2. Ticked, TSM's price takes over once your own scan is more than four
--      hours old, and not before. The stale setting plays no part.
--   3. Ticked, TSM's price stands ahead of the other account, guild and
--      realm prices.
--   4. A price set by hand still wins ("use"), or lifts TSM's ("floor").
--   5. The rival (undercut) price never comes from TSM.
--   6. No TSM price, or TSM Prices unticked: the usual way.

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
local settings = { staleAfterSeconds = 48 * 3600 }
ns.Config = {
    Get = function(_, key) return settings[key] end,
    GetPriceTable = function() return priceTable end,
}
ns.db = {}
time = time or os.time

local clock = 100
GetTime = function() return clock end
TSM_API = {
    GetCustomPriceValue = function(source)
        if source == "DBMarket" then return 900 end
        if source == "DBMinBuyout" then return 800 end
    end,
}

assert(loadfile(lfs_cwd .. "/Data/Prices.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/TSMPrices.lua"))("Blackthornes_TS", ns)
local Prices, TSM = ns.Prices, ns.TSMPrices

local mine = {}
function Prices:GetMine(itemID)
    local entry = mine[itemID]
    if entry then return entry[1], entry[2] end
end

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

local function Scan(itemID, market, hoursOld)
    priceTable[itemID] = { market = market, min = market, rivalMin = market - 1,
        scans = 1, history = {}, seen = time() - hoursOld * 3600 }
end

print("\nPrefer TSM Prices")

Scan(1, 500, 5)
check("off by default, a 5 hour old scan keeps its price", Prices:GetValue(1) == 500)
check("off, PrefersTSM says no", not Prices:PrefersTSM())

settings.preferTsmPrices = true
check("ticked, PrefersTSM says yes", Prices:PrefersTSM())
check("ticked, TSM takes over a scan more than 1 hour old", Prices:GetValue(1) == 900)
check("min reads TSM's min buyout", Prices:GetValue(1, "min") == 800)
check("rival never comes from TSM", Prices:GetValue(1, "rival") == 499)
check("the scans alone are untouched", Prices:GetScanValue(1) == 500)

Scan(2, 500, 0.5)
check("a scan under 1 hour old keeps its price", Prices:GetValue(2) == 500)

settings.staleAfterSeconds = 600
Scan(3, 500, 0.5)
check("the stale setting does not move the hour", Prices:GetValue(3) == 500)
settings.staleAfterSeconds = 48 * 3600

Scan(4, 500, 2)
check("a 2 hour old scan gives way to TSM", Prices:GetValue(4) == 900)

check("an item never scanned takes TSM's price", Prices:GetValue(4) == 900)

-- Other sources TSM stands ahead of.
ns.GuildPrices = { IsOn = function() return true end, GetValue = function() return 222, time() end }
ns.RealmPrices = { IsOn = function() return true end, GetValue = function() return 333, time() end }
check("ahead of guild and realm", Prices:GetValue(1) == 900)
check("a fresh scan never gives way to TSM, the usual rules apply", Prices:GetValue(2) == 500)

mine[1] = { 700, "use" }
check("a price set by hand still wins", Prices:GetValue(1) == 700)
mine[1] = { 1200, "floor" }
check("a floor set by hand lifts TSM's price", Prices:GetValue(1) == 1200)
mine[1] = { 600, "floor" }
check("a lower floor leaves TSM's price", Prices:GetValue(1) == 900)
mine[1] = nil

-- No TSM price: the usual way. (Classic has no other account's prices.)
TSM_API.GetCustomPriceValue = function() return nil end
TSM:Forget()
check("no TSM price, the usual way as before", Prices:GetValue(1) == 500)
ns.GuildPrices, ns.RealmPrices = nil, nil
check("no TSM price and nobody else, your own scan stays", Prices:GetValue(1) == 500)

-- TSM Prices unticked: Prefer does nothing.
TSM_API.GetCustomPriceValue = function() return 900 end
TSM:Forget()
settings.tsmPrices = false
check("TSM Prices off, PrefersTSM says no", not Prices:PrefersTSM())
check("TSM Prices off, your own scan stays", Prices:GetValue(1) == 500)

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end
print(("\n%d check(s) passed\n"):format(checks))
