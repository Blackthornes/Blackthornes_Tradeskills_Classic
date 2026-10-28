-- My prices (2026-10-06): a price the player sets on an item, used
-- instead of the auction price ("use") or as the least it can be ("floor").
--
-- What must hold:
--   1. "use" replaces every reading but "rival"; "floor" only lifts a
--      lower one, and gives a price where no scan has.
--   2. GetScanValue keeps answering from the scans alone.
--   3. Cleared by a price of nothing; kept per realm under myPrices.
--   4. A reagent costs its "use" price, over a vendor too, and a floor
--      lifts a cheaper vendor or auction price.
--   5. Posting lists at a "use" price, and undercuts down to a floor only.

time = time or os.time

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.Util = {
    Clamp = function(v, l, h) return math.max(l, math.min(h, v)) end,
    Count = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end,
    FormatMoney = function(c) return tostring(c) end,
    FormatAge = function() return "" end,
    HasFunction = function() return false end,
    GetItemLabel = function(i) return "item" .. tostring(i) end,
    RoundToSilver = function(p) return math.floor(p / 100) * 100 end,
    CeilToSilver = function(p) return math.ceil(p / 100) * 100 end,
}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end

local realm = "Forever-Alliance"
local priceTables = {}
local settings = { undercutCopper = 1, valueOwnedMaterials = true }
ns.db = {}
ns.Config = {
    Get = function(_, k) return settings[k] end,
    GetRealmKey = function() return realm end,
    GetPriceTable = function()
        priceTables[realm] = priceTables[realm] or {}
        return priceTables[realm]
    end,
}

local commodity = true
ns.Scanner = { IsCommodity = function() return commodity end }

local vendorSells = {}
ns.Vendor = { GetUnitPrice = function(_, id) return vendorSells[id] end }
ns.Inventory = {
    GetBagCount = function() return 0 end,
    GetBankCount = function() return 0 end,
}
ns.Recipes = { GetAny = function() return nil end, GetAll = function() return {} end }

assert(loadfile(lfs_cwd .. "/Data/Prices.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Cost.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Profit.lua"))("Blackthornes_TS", ns)

-- No recipes here: post prices come from the auction house alone.
ns.Cost.FindRecipeForItem = function() return nil end
ns.Cost.FindAnyRecipeForItem = function() return nil end

local Prices, Cost, Profit = ns.Prices, ns.Cost, ns.Profit

local failures = 0
local function check(label, got, expected)
    local ok = got == expected
    if not ok then failures = failures + 1 end
    print(("  %-56s %-10s %s"):format(label, tostring(got), ok and "ok" or ("FAILED, expected " .. tostring(expected))))
end

local SILK, BOLT, VIAL, NEVER = 4306, 4305, 3371, 9999

print("my prices")

-- Spider silk: market 120, cheapest 100, a rival at 100.
Prices:Record(SILK, 120, 100, 10, time(), 100, nil)

check("nothing set: GetMine is nil", Prices:GetMine(SILK), nil)
check("nothing set: market is the scan's", Prices:GetValue(SILK, "market"), 120)

-- 1. "use"
check("use: saved", Prices:SetMine(SILK, 80, "use", "Silk"), true)
local price, mode = Prices:GetMine(SILK)
check("use: price", price, 80)
check("use: mode", mode, "use")
check("use: market reads it", Prices:GetValue(SILK), 80)
check("use: min reads it", Prices:GetValue(SILK, "min"), 80)
check("use: lowest reads it", Prices:GetValue(SILK, "lowest"), 80)
check("use: rival stays the auction house's", Prices:GetValue(SILK, "rival"), 100)
check("2. scan value is untouched", Prices:GetScanValue(SILK, "market"), 120)
check("3. kept per realm, by item, with its name", ns.db.myPrices[realm][SILK].name, "Silk")

-- "floor"
Prices:SetMine(SILK, 110, "floor")
check("floor: name kept from before", ns.db.myPrices[realm][SILK].name, "Silk")
check("floor: market above it stays", Prices:GetValue(SILK, "market"), 120)
check("floor: min below it is lifted", Prices:GetValue(SILK, "min"), 110)
check("floor: never-scanned item gets the floor", (function()
    Prices:SetMine(NEVER, 500, "floor")
    return Prices:GetValue(NEVER)
end)(), 500)

-- 3. clearing, and other realms
Prices:SetMine(NEVER, 0)
check("a price of nothing clears it", Prices:GetMine(NEVER), nil)
check("and the scan value is back (none)", Prices:GetValue(NEVER), nil)
check("a price nobody can pay is refused", Prices:SetMine(NEVER, 2 ^ 40, "use"), false)
check("an unknown kind is saved as use", (function()
    Prices:SetMine(NEVER, 5, "sideways")
    local _, m = Prices:GetMine(NEVER)
    Prices:SetMine(NEVER, nil)
    return m
end)(), "use")

realm = "Elsewhere-Horde"
check("another realm does not see it", Prices:GetMine(SILK), nil)
realm = "Forever-Alliance"

ns.db.myPrices[realm][BOLT] = { price = "junk", mode = "use" }
check("a saved entry it cannot read is skipped", Prices:GetMine(BOLT), nil)
check("and left in place", ns.db.myPrices[realm][BOLT].price, "junk")
ns.db.myPrices[realm][BOLT] = nil

-- 4. reagent cost
Prices:SetMine(SILK, 80, "use")
local cost, source = Cost:GetReagentUnitCost(SILK)
check("reagent: use price is the cost", cost, 80)
check("reagent: source says so", source, "mine")

vendorSells[VIAL] = 20
Prices:Record(VIAL, 60, 50, 10, time(), 50, nil)
Prices:SetMine(VIAL, 15, "use")
cost, source = Cost:GetReagentUnitCost(VIAL)
check("reagent: use price wins over a vendor", cost, 15)
Prices:SetMine(VIAL, 30, "floor")
cost, source = Cost:GetReagentUnitCost(VIAL)
check("reagent: floor lifts a cheaper vendor price", cost, 30)
check("reagent: source says so", source, "mine")
Prices:SetMine(VIAL, 10, "floor")
cost, source = Cost:GetReagentUnitCost(VIAL)
check("reagent: floor under the vendor leaves it", source, "vendor")

Prices:SetMine(SILK, 110, "floor")
cost, source = Cost:GetReagentUnitCost(SILK)
check("reagent: floor lifts the auction price", cost, 110)
Prices:SetMine(SILK, 90, "floor")
cost, source = Cost:GetReagentUnitCost(SILK)
check("reagent: floor under the auction price leaves it", source, "buy")

-- 5. posting
Prices:SetMine(SILK, 80, "use")
local basis
price, basis = Profit:ChoosePostPrice(SILK)
check("post: use lists at it", price, 80)
check("post: basis", basis, "mine")

Prices:SetMine(SILK, 90, "floor")
price, basis = Profit:ChoosePostPrice(SILK)
check("post: floor under the rival still undercuts", price, 99)
check("post: basis", basis, "undercut")

Prices:SetMine(SILK, 150, "floor")
price, basis = Profit:ChoosePostPrice(SILK)
check("post: floor over the rival holds", price, 150)
check("post: basis", basis, "floor")

commodity = false
Prices:SetMine(SILK, 150, "floor")
price = Profit:ChoosePostPrice(SILK)
check("post: item auction rounds a floor up to the silver", price, 200)
commodity = true

Prices:SetMine(SILK, nil)
price, basis = Profit:ChoosePostPrice(SILK)
check("cleared: back to undercutting", price, 99)

-- The Prices tab's "My prices only" tick box.
ns.Theme, ns.Widgets = {}, {}
ns.UI = { RegisterTab = function() end }
Prices.GetAge = function() return 60 end
Prices.GetSalesPerDay = function() return nil end
assert(loadfile(lfs_cwd .. "/UI/Columns.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/UI/Tab_Prices.lua"))("Blackthornes_TS", ns)

Prices:SetMine(VIAL, nil)
Prices:SetMine(NEVER, 300, "use", "Never Seen")
local rows = ns.UI._PricesList("", false, true)
check("My prices only: just the one with a price", #rows, 1)
check("an unscanned item with my price still shows", rows[1] and rows[1].itemID, NEVER)
check("found by the name it was saved with", #ns.UI._PricesList("never", false, true), 1)
check("everything shows without the tick", #ns.UI._PricesList("", false, false), 3)

-- 6. Highest and When Cheaper on a "floor" price (2026-10-28)
check("no price: Highest is refused", Prices:SetMyHigh(SILK, 80), false)
check("no price: Wait is refused", Prices:SetMyWait(SILK, true), false)
Prices:SetMine(SILK, 50, "floor")
check("Highest: saved", Prices:SetMyHigh(SILK, 80), true)
check("Highest: read back", (Prices:GetMyLimits(SILK)), 80)
local why
price, basis, why = Profit:ChoosePostPrice(SILK)
check("Highest: the market over it lists at it", price, 80)
check("Highest: basis", basis, "highest")
check("Highest: says so", why, "the most you set on the Prices tab")
check("Highest: the market price itself is untouched", Prices:GetValue(SILK, "market"), 120)

Prices:SetMine(SILK, 60, "floor")
check("Highest: kept when the price changes", (Prices:GetMyLimits(SILK)), 80)
Prices:SetMyHigh(SILK, 40)
price, basis = Profit:ChoosePostPrice(SILK)
check("Highest under the floor means nothing", price, 99)
check("so the usual price", basis, "undercut")
check("Highest: nil takes it off", Prices:SetMyHigh(SILK, nil) and Prices:GetMyLimits(SILK), nil)

Prices:SetMine(SILK, 150, "floor")
local waits
price, basis, _, _, waits = Profit:ChoosePostPrice(SILK)
check("List Anyway: lists at the floor", price, 150)
check("List Anyway: does not wait", waits, nil)
check("Wait: saved", Prices:SetMyWait(SILK, true), true)
check("Wait: read back", select(2, Prices:GetMyLimits(SILK)), true)
price, basis, _, _, waits = Profit:ChoosePostPrice(SILK)
check("Wait: still priced at the floor", price, 150)
check("Wait: says to wait", waits, true)
Prices:SetMine(SILK, 90, "floor")
price, basis, _, _, waits = Profit:ChoosePostPrice(SILK)
check("Wait: the market over the floor lists", price, 99)
check("Wait: and does not wait", waits, nil)

Prices:SetMine(SILK, 80, "use")
check("a use price has no limits", Prices:GetMyLimits(SILK), nil)
price, basis = Profit:ChoosePostPrice(SILK)
check("a use price lists at it, limits or not", price, 80)
check("use: the limits stay in the save", ns.db.myPrices[realm][SILK].under, "wait")
Prices:SetMine(SILK, nil)
check("clearing the price takes the limits too", ns.db.myPrices[realm][SILK], nil)

commodity = false
Prices:Record(BOLT, 1000, 1000, 10, time(), 1000, nil)
Prices:SetMine(BOLT, 100, "floor")
Prices:SetMyHigh(BOLT, 550)
price, basis = Profit:ChoosePostPrice(BOLT)
check("item auction: Highest rounds down to the silver", price, 500)
check("item auction: basis", basis, "highest")
Prices:SetMine(BOLT, nil)
commodity = true

if failures > 0 then error(("%d my-price check(s) failed"):format(failures)) end
