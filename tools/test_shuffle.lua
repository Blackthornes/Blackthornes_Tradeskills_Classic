-- Shuffles: every way to turn one item into gold (Logic/Shuffle.lua).
--
-- What must hold:
--   1. "Sell it as it is" is always a way, and gains nothing.
--   2. A way's gain is what it gets back less the start and the materials
--      bought for its crafts.
--   3. The best place to stop is the step worth the most, and a step worth
--      less than the one before it is marked as losing gold.
--   4. A craft with a material that can't be priced is left out.
--   5. "Only My Recipes" leaves out recipes the character doesn't know, and
--      Queue It is offered only when every craft on a way is known.
--   6. A grey has no auction price, only the vendor's.
--   7. Add to List names the list for the start and never doubles a count.

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.db = {}

local ORE, BAR, BELT, DUST, LINEN, AXE, JUNK, ROPE = 2770, 2840, 6000, 10940, 2996, 7000, 4000, 4100

local names = {
    [ORE] = "Copper Ore", [BAR] = "Copper Bar", [BELT] = "Runed Copper Belt",
    [DUST] = "Strange Dust", [LINEN] = "Bolt of Linen Cloth", [AXE] = "Copper Axe",
    [JUNK] = "Broken Fang", [ROPE] = "Odd Rope",
}
local quality = { [JUNK] = 0 }
_G.GetItemInfo = function(itemID)
    return names[itemID], nil, quality[itemID] or 1
end
_G.C_Item = nil
_G.GetLocale = function() return "enUS" end
_G.GetTime = function() return 1000 end
_G.C_Timer = nil

-- Known: smelt one ore to one bar; a belt from 2 bars and a bolt of linen.
local known = {
    [300] = { outputItemID = BAR, quantityMin = 1, quantityMax = 1, skillLineID = 186,
        reagents = { { itemID = ORE, quantity = 1 } } },
    [400] = { outputItemID = BELT, quantityMin = 1, quantityMax = 1, skillLineID = 164,
        reagents = { { itemID = BAR, quantity = 2 }, { itemID = LINEN, quantity = 1 } } },
}
-- In the book only: an axe from 5 bars; something from a rope no one prices.
local book = {
    [500] = { recipeID = 500, outputItemID = AXE, quantityMin = 1, quantityMax = 1,
        reagents = { { itemID = BAR, quantity = 5 } } },
    [600] = { recipeID = 600, outputItemID = BELT, quantityMin = 1, quantityMax = 1,
        reagents = { { itemID = ORE, quantity = 1 }, { itemID = ROPE, quantity = 1 } } },
}
ns.Recipes = {
    GetAll = function() return known end,
    IsDropped = function() return false end,
    GetLearnedProfessions = function()
        return { { name = "Mining", skillLineID = 186, skillLevel = 75 } }
    end,
}
ns.RecipeBook = { GetAll = function() return book end }

local market = { [ORE] = 20, [BAR] = 50, [BELT] = 300, [DUST] = 100, [AXE] = 1000, [JUNK] = 500 }
ns.Prices = {
    GetValue = function(_, itemID) return market[itemID] end,
    GetLastScan = function() return 900 end,
}
ns.Profit = { NetFromListing = function(_, _, price) return math.floor(price * 0.95) end }
local vendors = { [BELT] = 40, [JUNK] = 7 }
ns.Util = { GetVendorSellPrice = function(itemID) return vendors[itemID] end }
ns.Cost = {
    GetReagentCost = function(_, itemID, count)
        if itemID == LINEN then return 10 * count end
        return nil
    end,
}
ns.Disenchant = {
    IsDisenchantable = function(_, itemID) return itemID == BELT end,
    GetValue = function(_, itemID)
        if itemID ~= BELT then return nil end
        return 150, nil, { outcomes = { { counted = true, itemID = DUST, average = 1.5 } },
            facts = { source = "yours" } }
    end,
}
ns.Inventory = { GetBagCounts = function() return { [ORE] = 10, [LINEN] = 3, [DUST] = 4 } end }
ns.DisenchantLog = { GetTable = function()
    return { items = { [BELT] = { casts = 6 }, [1234] = { casts = 3 } } }
end }

assert(loadfile(lfs_cwd .. "/Logic/Shuffle.lua"))("Blackthornes_TS", ns)
local Shuffle = ns.Shuffle

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

local function Find(ways, name)
    for _, way in ipairs(ways) do
        if way.name == name then return way end
    end
end

print("\nshuffles")

check("way names read in order", Shuffle.WayName({ "smelt", "sell" }) == "Smelt and sell"
    and Shuffle.WayName({ "smelt", "make", "de" }) == "Smelt, make, disenchant"
    and Shuffle.WayName({ "sell" }) == "Sell it as it is")
check("short names for the chain", Shuffle.ChainText({ ORE, BAR, BELT, DUST }) == "Ore, Bar, Belt, Dust")

-- 10 Copper Ore, my recipes only.
local ways
Shuffle:Build(ORE, 10, true, function(found) ways = found end, true)
check("the ways come back", type(ways) == "table" and #ways > 0)

local plain = Find(ways, "Sell it as it is")
check("selling it as it is is a way", plain ~= nil)
check("selling it as it is gains nothing", plain.gain == 0 and plain.putIn == 190 and plain.back == 190)

local bars = Find(ways, "Smelt and sell")
check("smelting and selling the bars", bars and bars.back == 470 and bars.gain == 280)

local belts = Find(ways, "Smelt, make, sell")
-- 5 belts at 285 is 1425; 5 bolts of linen bought for 50; 190 of ore.
check("the belt way counts the linen it buys", belts and belts.putIn == 240 and belts.back == 1425
    and belts.gain == 1185)
check("the belt way is first", ways[1] == belts and belts.id == 1)
check("the linen is on the way's list to buy", belts.buys[LINEN] == 5)

local broken = Find(ways, "Smelt, make, disenchant")
check("disenchanting the belts", broken and broken.back == 750 and broken.gain == 510)
local last = broken.steps[#broken.steps]
check("the disenchant step loses gold", last.loss == true and last.kind == "de")
check("the belt step is the best place to stop", broken.steps[3].best == true and broken.best == 3)
-- Losing gold is the note that matters most; the odds are still yours.
check("the losing disenchant step says to sell before it",
    last.note == "This step loses gold. Sell before it." and last.yours == true
    and last.itemID == DUST and last.count == 7.5)
local vendored = Find(ways, "Smelt, make, vendor")
check("the loss step says to sell before it", vendored and vendored.steps[3].loss == true
    and vendored.steps[3].note == "This step loses gold. Sell before it." and vendored.gain == -40)
check("a smelt names your skill", bars.steps[2].note == "You know this. Mining 75.")
check("a craft you know says so", belts.steps[3].note == "You know this recipe.")

check("only my recipes leaves the axe out", Find(ways, "Smelt, make, sell") == belts)
for _, way in ipairs(ways) do
    for _, craft in ipairs(way.crafts) do
        check("only known crafts with my recipes", craft.recipeID ~= 500 and craft.recipeID ~= 600)
    end
end
check("Queue It for a way you know", Shuffle.CanQueue(belts))
check("no Queue It for selling as it is", not Shuffle.CanQueue(plain))

-- Kept for the same start and scan.
local kept, stale = Shuffle:Get(ORE, 10, true)
check("kept until something moves", kept == ways and stale == false)
local _, again = Shuffle:Get(ORE, 11, true)
check("a new count works it out again", again == true)

-- Every recipe: the axe, which no one here knows, and the rope one, which
-- can't be priced.
local all
Shuffle:Build(ORE, 10, false, function(found) all = found end, true)
local axe
for _, way in ipairs(all) do
    if way.chain[#way.chain] == AXE then axe = way end
    for _, craft in ipairs(way.crafts) do
        check("a craft with a material nobody prices is left out", craft.recipeID ~= 600)
    end
end
-- 2 axes from 10 bars at 950 each.
check("the axe from the book", axe and axe.back == 1900 and axe.gain == 1710)
check("no Queue It for a recipe you don't know", not Shuffle.CanQueue(axe))
check("a way you don't know comes first when it pays most", all[1] == axe)

-- A grey sells only to a vendor.
local ah, vendor = Shuffle:Prices(JUNK)
check("a grey has no auction price", ah == nil and vendor == 7)

-- Starts are what's in the bags that some recipe uses.
local starts = Shuffle:Starts(true)
check("starts are bag items some recipe uses", #starts == 2 and starts[1].itemID == ORE
    and starts[2].itemID == LINEN)

-- Queue It asks for each craft.
local queued = {}
ns.Queue = { Ensure = function(_, recipeID, count) queued[#queued + 1] = { recipeID, count }; return true end }
check("Queue It queues each craft", Shuffle:Queue(belts) == true and #queued == 2
    and queued[1][1] == 300 and queued[1][2] == 10 and queued[2][1] == 400 and queued[2][2] == 5)
check("Queue It does nothing for a way with an unknown craft", Shuffle:Queue(axe) == nil)

-- Add to List, twice.
local lists, made = {}, 0
ns.ShoppingLists = {
    All = function() return lists end,
    Make = function(_, name) made = made + 1; lists[#lists + 1] = { name = name, items = {} }; return #lists end,
    Get = function(_, index) return lists[index] end,
    SetWant = function(_, index, itemID, want)
        for _, item in ipairs(lists[index].items) do
            if item.id == itemID then item.want = want; return true end
        end
        return false
    end,
    Add = function(_, index, itemID, want)
        table.insert(lists[index].items, { id = itemID, want = want })
        return true
    end,
}
local index, name = Shuffle:AddToList(belts)
Shuffle:AddToList(belts)
check("the list is named for the start", index == 1 and name == "Copper Ore" and made == 1)
local wants = {}
for _, item in ipairs(lists[1].items) do wants[item.id] = item.want end
check("a second click never doubles it", #lists[1].items == 2 and wants[ORE] == 10 and wants[LINEN] == 5)

ns.ShoppingLists = nil
local none, why = Shuffle:AddToList(belts)
check("without lists it says why", none == nil and why == "Shopping lists aren't ready yet.")

check("disenchants counted for the odds", Shuffle.BrokenSoFar() == 9)

print(("\n%d checks passed"):format(checks))
