-- Era has no C_MerchantFrame.GetItemInfo, so Vendor:Scan read nothing and
-- Butler's Buy from a vendor row never got its Buy button (2026-10-25: a
-- trade supplies vendor selling Coarse Thread). The classic call answers
-- instead, laid into the same shape.

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn =
    function() end, function() end, function() end, function() end

local have = { GetMerchantNumItems = true, GetMerchantItemInfo = true, GetMerchantItemLink = true }
ns.Util = {
    HasFunction = function(path) return have[path] == true end,
    GetItemLabel = function(i) return "item" .. tostring(i) end,
}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() end
ns.Cost = { InvalidateIndex = function() end }
ns.db = {}
time = os.time
C_MerchantFrame = nil

-- Coarse Thread one at a time, Vial in fives, a limited pattern, a token item.
local stock = {
    { "Coarse Thread", 10, 1, -1, false, 2320 },
    { "Empty Vial", 20, 5, -1, false, 3371 },
    { "Pattern", 500, 1, 1, false, 4999 },
    { "Token Thing", 0, 1, -1, true, 5000 },
}
GetMerchantNumItems = function() return #stock end
GetMerchantItemInfo = function(i)
    local s = stock[i]
    return s[1], 1, s[2], s[3], s[4], true, true, s[5]
end
GetMerchantItemLink = function(i) return ("|Hitem:%d::|h[x]|h"):format(stock[i][6]) end

assert(loadfile(lfs_cwd .. "/Data/Vendor.lua"))("Blackthornes_TS", ns)
local Vendor = ns.Vendor

local failures = 0
local function check(label, ok)
    print((ok and "  ok  " or "  FAIL  ") .. label)
    if not ok then failures = failures + 1 end
end

Vendor:Scan()
local items = Vendor.merchantItems or {}
local thread, vial, pattern = items[2320], items[3371], items[4999]
check("Era's vendor list is read", thread ~= nil)
check("thread is slot 1 at 10c, unlimited", thread and thread.index == 1 and thread.price == 10
    and thread.stack == 1 and thread.numAvailable == -1)
check("vials keep their bundle of 5", vial and vial.stack == 5 and vial.price == 4 and vial.bundlePrice == 20)
check("a limited item says so", pattern and pattern.numAvailable == 1)
check("a free token item is left out", items[5000] == nil)
check("the price is kept", ns.db.vendorPrices[2320] and ns.db.vendorPrices[2320].price == 10)

-- With neither call the scan reads nothing, as before.
have = {}
Vendor.merchantItems = nil
check("no merchant calls, nothing read", Vendor:Scan() == 0 and Vendor.merchantItems == nil)

if failures > 0 then error(failures .. " check(s) failed") end
print("PASS")
