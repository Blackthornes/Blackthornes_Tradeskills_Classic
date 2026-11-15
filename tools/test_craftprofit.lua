-- Craft Cost and Profit: what one craft sells for, what its mats cost and the
-- profit, as the game's recipe rows, their hover and the card show it.
--
-- What matters most here:
--   1. Nothing is ever guessed. A mat or a sale with no price leaves the
--      profit empty and says "No price".
--   2. Mats that bind on pickup can never be bought, so when only they lack a
--      price the rest is shown and they are named.
--   3. A craft that makes two counts both, and says "Makes 2".
--   4. Greys go to a vendor only, and the vendor wins when it pays more.

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.L = setmetatable({ Format = string.format }, { __index = function(_, key) return key end })
ns.COLORS = { profit = "ffPROFIT", loss = "ffLOSS", muted = "ffMUTED" }
ns.Util = {
  FormatMoney = function(copper) return ("<%d>"):format(math.floor(copper + 0.5)) end,
  ColorItemName = function(_, name) return "{" .. name .. "}" end,
}
ns.Theme = {}

local function Load(path)
  local chunk = assert(loadfile(lfs_cwd .. "/" .. path))
  chunk("Blackthornes_TS", ns)
end

--------------------------------------------------------------------------------
-- The world
--------------------------------------------------------------------------------

local NAMES = { [10] = "Bolt of Mageweave", [11] = "Demonic Rune", [12] = "Thread", [20] = "Robe" }
local QUALITY = { [20] = 2, [30] = 0 }
_G.C_Item = {
  GetItemQualityByID = function(id) return QUALITY[id] or 1 end,
  GetItemInfo = function(id)
    if NAMES[id] then return NAMES[id], nil, QUALITY[id] or 1 end
  end,
  GetItemInfoInstant = function() return nil end,
  RequestLoadItemDataByID = function() end,
}
_G.GetTime = function() return 100 end

local RECIPES = {
  [1] = { outputItemID = 20, reagents = { { itemID = 10, quantity = 8 }, { itemID = 12, quantity = 1 } } },
  [2] = { outputItemID = 20, reagents = { { itemID = 10, quantity = 2 }, { itemID = 11, quantity = 4 } } },
  [3] = { outputItemID = 20, reagents = { { itemID = 10, quantity = 1 }, { itemID = 99, quantity = 1 } } },
  [4] = { outputItemID = 20, quantityMin = 2, quantityMax = 2, reagents = { { itemID = 10, quantity = 1 } } },
  [5] = { outputItemID = 30, reagents = { { itemID = 10, quantity = 1 } } },
  [6] = { outputItemID = 77, reagents = { { itemID = 10, quantity = 1 } } },
}
ns.Recipes = { GetAny = function(_, id) return RECIPES[id] end }

local COST = { [10] = { 100, "auction" }, [12] = { 5, "vendor" } }
ns.Cost = {
  GetReagentUnitCost = function(_, id)
    local c = COST[id]
    if c then return c[1], c[2] end
  end,
  CostOfMany = function(_, _, qty, unit) return unit * qty end,
}
ns.Util.IsBoundOnPickup = function(id) return id == 11 end

local POST = { [20] = 2000 }
local VENDOR = { [20] = 50, [30] = 40 }
ns.Util.GetVendorSellPrice = function(id) return VENDOR[id] end
ns.Profit = {
  ChoosePostPrice = function(_, id) return POST[id] end,
  NetFromListing = function(_, _, price) return math.floor(price * 0.95) end,
}
ns.Prices = { changes = 0 }
ns.Config = { changes = 0 }

Load("Logic/CraftProfit.lua")
local CP = ns.CraftProfit
Load("UI/CraftProfitCard.lua")
local Card = ns.CraftProfitCard

local failures = 0
local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(("FAIL %s: got %s, want %s"):format(label, tostring(got), tostring(want)))
  end
end

--------------------------------------------------------------------------------
-- Figures
--------------------------------------------------------------------------------

do
  local f = CP:For(1)
  check("cost adds every mat", f.cost, 8 * 100 + 5)
  check("sells after the cut", f.sells, 1900)
  check("sells at the auction", f.sellsWay, "auction")
  check("profit", f.profit, 1900 - 805)
  check("mat way auction", f.reagents[1].way, "auction")
  check("mat way vendor", f.reagents[2].way, "vendor")
  check("kept until something moves", CP:For(1), f)
  ns.Prices.changes = 1
  check("a price change works it out again", CP:For(1) ~= f, true)
end

do
  local f = CP:For(2)
  check("bound: no full cost", f.cost, nil)
  check("bound: partial", f.partial, 200)
  check("bound: only bound", f.onlyBound, true)
  check("bound: no plain profit", f.profit, nil)
  check("bound: profit without them", f.boundProfit, 1900 - 200)
  check("bound: named with count", CP.BoundNames(f), "4 {Demonic Rune}")
  check("bound: row shows the part and a small +",
    CP.RowText(f), "|cffPROFIT+|r<1700>|cffMUTED+|r")
  local lines = CP.Lines(f)
  check("bound: cost line", lines[2].value, "<200>, plus 4 {Demonic Rune}")
end

do
  local f = CP:For(3)
  check("unpriced mat: no cost", f.cost, nil)
  check("unpriced mat: no partial", f.partial, nil)
  check("unpriced mat: no profit", f.profit, nil)
  check("unpriced mat: row says No price", CP.RowText(f), "|cffMUTEDNo price|r")
  check("unpriced mat: listed", f.unpriced[1], 99)
  check("unpriced mat: profit line", CP.Lines(f)[3].value, "|cffMUTEDNo price|r")
end

do
  local f = CP:For(4)
  check("makes 2: noted", f.makes, 2)
  check("makes 2: sells both", f.sells, 3800)
  check("makes 2: line note", CP.Lines(f)[1].makes, "Makes 2")
end

do
  local f = CP:For(5)
  check("grey: vendor only", f.sellsWay, "vendor")
  check("grey: vendor price", f.sells, 40)
  check("grey: a loss shows red", CP.RowText(f), "|cffLOSS\226\136\146|r<60>")
end

do
  POST[20] = 40
  ns.Prices.changes = 2
  local f = CP:For(1)
  check("vendor wins when it pays more", f.sellsWay, "vendor")
  check("vendor price", f.sells, 50)
  POST[20] = 2000
end

do
  local f = CP:For(6)
  check("no sale price: no sells", f.sells, nil)
  check("no sale price: no profit", f.profit, nil)
  check("no sale price: sells line", CP.Lines(f)[1].value, "|cffMUTEDNo price|r")
  check("unknown recipe", CP:For(999), nil)
  check("no figures row", CP.RowText(nil), "|cffMUTEDNo price|r")
end

--------------------------------------------------------------------------------
-- Names and the card's rows
--------------------------------------------------------------------------------

check("item name in colour, no brackets", CP.ItemName(10), "{Bolt of Mageweave}")
check("item not loaded yet", CP.ItemName(555), "item 555")
check("way AH", CP.WayText("auction"):find("AH", 1, true) ~= nil, true)
check("way Vendor", CP.WayText("vendor"):find("Vendor", 1, true) ~= nil, true)

do
  ns.Prices.changes = 3
  local rows = Card.Rows(CP:For(1))
  check("card: rows", #rows, 5)
  check("card: sells first", rows[1].kind, "sells")
  check("card: mat line", rows[2].label, "8 {Bolt of Mageweave}")
  check("card: mat value", rows[2].value, "<800>")
  check("card: mat tagged", rows[2].way ~= nil, true)
  check("card: cost", rows[4].kind, "cost")
  check("card: profit last", rows[5].kind, "profit")

  local unpriced = Card.Rows(CP:For(3))
  check("card: unpriced mat says No price", unpriced[3].value, "|cffMUTEDNo price|r")
  check("card: unpriced mat has no tag", unpriced[3].way, nil)
  check("card: nothing known", #Card.Rows(nil), 3)
end

if failures > 0 then error(("test_craftprofit: %d failure(s)"):format(failures)) end
print("test_craftprofit: ok")
