-- Vendor, Make or Buy for a sub-craft a vendor sells.
--
-- On Discord (2026-10-13): Lesser Mana Potion is sold by a vendor a few at
-- a time, so pricing every kit that uses it off the vendor was no help for
-- a run of them. The SUB-CRAFT button on the Level Up tab picks Vendor (the
-- usual), Make (always made) or Buy (never made, priced at the auction
-- house rather than the vendor), in the costs, the queue and the shopping
-- list. Allow in Settings puts it back.
--
-- Drives the real Cost.lua and Queue.lua.

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() end
ns.PrintRaw, ns.Debug, ns.Warn, ns.Print = function() end, function() end, function() end, function() end

time = function() return 1000000 end

local KIT, POTION, HERB = 5000, 3385, 785
local ME = "Player-ME"

ns.Util = { IsBoundOnPickup = function() return false end }

local settings = { valueOwnedMaterials = true }
ns.Config = {
    Get = function(_, key) return settings[key] end,
    GetCharacterKey = function() return ME end,
}

local recipes = {
    [10] = { recipeID = 10, name = "Mystic Kit", outputItemID = KIT, quantityMin = 1,
        reagents = { { itemID = POTION, quantity = 2 } } },
    [20] = { recipeID = 20, name = "Lesser Mana Potion", outputItemID = POTION, quantityMin = 1,
        reagents = { { itemID = HERB, quantity = 2 } } },
}

ns.Recipes = {
    GetAll = function() return recipes end,
    Get = function(_, id) return recipes[id] end,
    GetAny = function(_, id) return recipes[id], ME end,
    GetCharacterName = function() return "Me" end,
}

ns.Inventory = {
    GetBagCount = function() return 0 end,
    GetBankCount = function() return 0 end,
    GetMailCount = function() return 0 end,
    GetOwnedCount = function() return 0 end,
    GetAltTotal = function() return 0 end,
}

-- The potion: 240 at a vendor, 331 listed, 418 to make. The vendor is not
-- marked limited here: a limited shop gives way to any listing by itself
-- (2026-10-18), so Buy is what moves a shop that never runs out.
local auction = { [HERB] = 209, [POTION] = 331, [KIT] = 6000 }
ns.Prices = { GetValue = function(_, id) return auction[id] end }
local vendor = { [POTION] = 240 }
ns.Vendor = {
    GetUnitPrice = function(_, id) return vendor[id] end,
    IsLimited = function() return false end,
}

assert(loadfile(lfs_cwd .. "/Logic/Cost.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Queue.lua"))("Blackthornes_TS", ns)
-- Vendor:KeepsInStock, the real one, over the stubbed prices above.
ns.Vendor.KeepsInStock = function(self, id)
    if ns.Cost:SkipsVendor(id) then return false end
    return vendor[id] ~= nil and not self:IsLimited(id)
end

ns.Profit = { Analyse = function() return { priceable = false } end }

local Queue, Cost = ns.Queue, ns.Cost

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

local function entryFor(recipeID)
    for _, entry in ipairs(Queue:GetAll()) do
        if entry.recipeID == recipeID then return entry end
    end
end

local function row(itemID)
    for _, line in ipairs(Queue:GetShoppingList()) do
        if line.itemID == itemID then return line end
    end
end

ns.db = { queue = {}, characters = { [ME] = { name = "Me", realm = "Forever", recipes = recipes } } }
Cost:InvalidateIndex()
Queue:Add(10, 5)

print("\nVendor, the usual")
check("no choice yet", Cost:SubCraftChoice(20) == nil and Cost:ItemChoice(POTION) == nil)
check("the potion costs the vendor's price", Cost:GetReagentUnitCost(POTION) == 240)
check("so the kit costs 480", Cost:GetCraftCost(10).total == 480)
check("the potion is not queued", entryFor(20) == nil)
check("the shopping list sends you to the vendor", row(POTION) and row(POTION).source == "vendor")

print("\nMake")
Cost:SetSubCraftChoice(20, "make", "Lesser Mana Potion")
check("saved by recipe in its own table", ns.db.alwaysSubCrafts[20] == "Lesser Mana Potion"
    and ns.db.neverSubCrafts[20] == nil)
check("the potion is made though buying is cheaper",
    Cost:GetCraftCost(10).reagents[1].crafted and Cost:GetCraftCost(10).total == 836)
check("the potion is queued", entryFor(20) and entryFor(20).quantity == 10)
check("herbs are on the shopping list, not potions", row(HERB) and row(POTION) == nil)
check("Settings lists it", #Cost:GetAlwaysSubCrafts() == 1
    and Cost:GetAlwaysSubCrafts()[1].outputItemID == POTION)

print("\nBuy")
Cost:SetSubCraftChoice(20, "buy", "Lesser Mana Potion")
check("Buy is the old never-made mark", Cost:IsNeverSubCraft(20)
    and ns.db.alwaysSubCrafts[20] == nil and Cost:SubCraftChoice(20) == "buy")
check("priced at the auction house, not the vendor", Cost:GetReagentUnitCost(POTION) == 331)
check("never made", not Cost:GetCraftCost(10).reagents[1].crafted and entryFor(20) == nil)
check("the shopping list sends you to the auction house",
    row(POTION) and row(POTION).source == "auction" and row(POTION).fromVendor == false)
check("a vendor does not keep it in stock for you", ns.Vendor:KeepsInStock(POTION) == false)
auction[POTION] = nil
check("with nothing listed, the vendor is still a price", Cost:GetReagentUnitCost(POTION) == 240)
auction[POTION] = 331

print("\na shop with limited stock")
Cost:SetSubCraftChoice(20, nil)
local limitedNow = true
ns.Vendor.IsLimited = function() return limitedNow end
check("the shopping list never sends you there",
    row(POTION) and row(POTION).fromVendor == false and row(POTION).vendorLimited == true)
check("it is priced at the auction house", row(POTION).source == "auction")
auction[POTION] = nil
check("with nothing listed, still not the vendor",
    row(POTION) and row(POTION).fromVendor == false and row(POTION).source ~= "vendor")
auction[POTION] = 331
limitedNow = false
ns.Vendor.IsLimited = function() return limitedNow end

print("\nback to Vendor")
Cost:SetSubCraftChoice(20, nil)
check("both marks gone", ns.db.neverSubCrafts[20] == nil and ns.db.alwaysSubCrafts[20] == nil)
check("the vendor's price again", Cost:GetReagentUnitCost(POTION) == 240)

print("\nan old never-made mark")
Cost:SetSubCraftChoice(20, "make")
Cost:SetNeverSubCraft(20, true)
check("never-made clears Make", ns.db.alwaysSubCrafts[20] == nil and Cost:SubCraftChoice(20) == "buy")

print(("\n%d checks passed"):format(checks))
