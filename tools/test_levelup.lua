-- The Level Up tab's order: skill up colour first, material cost second.
--
-- Orange (a point for certain) before yellow before green, a recipe whose
-- colour was never read after green, grey last and only when asked for.
-- Within a colour, the cheapest craft first, and one whose materials have no
-- price after every priced one.
--
-- Drives the real Cost.lua and SkillUp.lua, so the cost ranked on is the same
-- number the Profit tab shows, bolt-or-wool rule included.

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.Util = { HasFunction = function() return false end }

time = time or os.time

ns.Config = { Get = function(_, key)
    if key == "valueOwnedMaterials" then return true end
    return nil
end }

local LINEN, BOLT, WOOL, THREAD, MYSTERY = 2589, 2996, 2592, 2320, 9999
local TAILORING, TAILORING_OLD, LEATHER = 2941, 197, 2945

-- Wool buys at 3s a cloth, so a bolt made from 3 is 9s; buying a bolt costs 20s.
local auction = { [LINEN] = 100, [BOLT] = 2000, [WOOL] = 300 }
ns.Prices = { GetValue = function(_, id) return auction[id] end }
ns.Vendor = { GetUnitPrice = function(_, id) return id == THREAD and 50 or nil end }

local bags = { [LINEN] = 4, [THREAD] = 2 }
ns.Inventory = {
    GetBagCount = function(_, id) return bags[id] or 0 end,
    GetBankCount = function() return 0 end,
}

local function R(id, name, tier, skillLine, reagents, output)
    return { recipeID = id, name = name, skillLineID = skillLine or TAILORING,
             outputItemID = output or (5000 + id), quantityMin = 1, quantityMax = 1,
             skillUp = tier and { tier = tier } or nil, reagents = reagents }
end

local recipes = {
    -- Orange, 3s: 2 linen at 1s and 2 vendor thread at 50c.
    [1] = R(1, "Linen Belt", "optimal", nil, { { itemID = LINEN, quantity = 2 }, { itemID = THREAD, quantity = 2 } }),
    -- Orange, 9s via the bolt it makes cheaper than it buys.
    [2] = R(2, "Woolen Cape", "optimal", TAILORING_OLD, { { itemID = BOLT, quantity = 1 } }),
    -- The bolt itself: yellow, 9s.
    [3] = R(3, "Bolt of Woolen Cloth", "medium", nil, { { itemID = WOOL, quantity = 3 } }, BOLT),
    -- Yellow and cheap: 1s. Must still sit below every orange.
    [4] = R(4, "Linen Bandana", "medium", nil, { { itemID = LINEN, quantity = 1 } }),
    -- Orange, no price for one material: after the priced orange ones.
    [5] = R(5, "Odd Gloves", "optimal", nil, { { itemID = MYSTERY, quantity = 1 } }),
    -- Green, and never-read, and grey.
    [6] = R(6, "Simple Kilt", "easy", nil, { { itemID = LINEN, quantity = 5 } }),
    [7] = R(7, "Unread Shirt", nil, nil, { { itemID = LINEN, quantity = 1 } }),
    [8] = R(8, "Grey Rag", "trivial", nil, { { itemID = LINEN, quantity = 1 } }),
    -- Same colour, same cost as the belt: the name decides.
    [9] = R(9, "Aaa Belt", "optimal", nil, { { itemID = LINEN, quantity = 2 }, { itemID = THREAD, quantity = 2 } }),
    -- Another profession.
    [10] = R(10, "Leather Strip", "optimal", LEATHER, { { itemID = LINEN, quantity = 1 } }),
}

ns.Recipes = {
    Get = function(_, id) return recipes[id] end,
    GetAny = function(_, id) return recipes[id] end,
    GetAll = function() return recipes end,
}

assert(loadfile(lfs_cwd .. "/Logic/Cost.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/SkillUp.lua"))("Blackthornes_TS", ns)

-- Profit.lua is the Profit tab's; only the craftable count is read here.
ns.Profit = { GetCraftableCount = function(_, recipeID)
    local most = math.huge
    for _, reagent in ipairs(recipes[recipeID].reagents) do
        most = math.min(most, math.floor((bags[reagent.itemID] or 0) / reagent.quantity))
    end
    return most
end }

local chunk = loadfile(lfs_cwd .. "/Logic/LevelUp.lua")
if not chunk then error("FAILED: Logic/LevelUp.lua is missing, so there is no levelling order") end
chunk("Blackthornes_TS", ns)

local LevelUp = ns.LevelUp

local function check(label, condition)
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

local function names(rows)
    local out = {}
    for i, row in ipairs(rows) do out[i] = row.name end
    return table.concat(out, ", ")
end

print("\nlevelling order")

local tailoring = { [TAILORING] = true, [TAILORING_OLD] = true }
local rows = LevelUp:GetRanked({ skillLines = tailoring })

print("  " .. names(rows))

check("orange first, cheapest first, name breaks a tie, unpriced last in its colour",
    names(rows) == "Aaa Belt, Linen Belt, Woolen Cape, Odd Gloves, "
        .. "Linen Bandana, Bolt of Woolen Cloth, Simple Kilt, Unread Shirt")

check("a cheap yellow never jumps an orange", rows[5].name == "Linen Bandana")
check("grey is left out unless asked for", rows[#rows].name ~= "Grey Rag")
check("both of Forever's IDs for one profession are kept", rows[3].skillLineID == TAILORING_OLD)
check("the other profession is left out", not names(rows):find("Leather Strip"))

print("\nthe cost is the Profit tab's cost")

local cape = rows[3]
check("the bolt counts at the cheaper of make (9s) or buy (20s)", cape.cost == 900)
check("it is the same number Cost.lua gives the Profit tab",
    cape.cost == ns.Cost:GetCraftCost(2).total)
check("a material with no price leaves the cost unknown, not free", rows[4].cost == nil)
check("belt: 2 linen at 1s and 2 vendor thread at 50c", rows[2].cost == 300)

print("\nfilters")

local withGrey = LevelUp:GetRanked({ skillLines = tailoring, includeTrivial = true })
check("grey goes last when shown", withGrey[#withGrey].name == "Grey Rag")

local craftable = LevelUp:GetRanked({ skillLines = tailoring, craftableOnly = true })
check("craftable only keeps what the bags make", names(craftable)
    == "Aaa Belt, Linen Belt, Linen Bandana, Unread Shirt")
check("the craftable count is carried on the row", craftable[1].craftableNow == 1 and craftable[3].craftableNow == 4)

local searched = LevelUp:GetRanked({ search = "BELT" })
check("search matches any case, across professions", names(searched) == "Aaa Belt, Linen Belt")

local everything = LevelUp:GetRanked({})
check("no profession given lists every profession", #everything == 9)

print("\nties never reshuffle")

local a = { name = "Same", tier = "optimal", cost = 100, recipeID = 1 }
local b = { name = "Same", tier = "optimal", cost = 100, recipeID = 2 }
check("recipe ID settles a full tie", LevelUp.Compare(a, b) and not LevelUp.Compare(b, a))
check("a row is never before itself", not LevelUp.Compare(a, a))

print("\nthe Craft button")

local busy, ready, reason, windowShows = false, true, nil, true
ns.Crafting = {
    IsBusy = function() return busy end,
    GetReadiness = function() return ready, reason end,
}
ns.ProfessionOpener = {
    WindowShowsRecipe = function() return windowShows end,
    ProfessionFor = function() return { name = "Tailoring", spell = "Tailoring" } end,
}

-- Linen Belt: the bags hold 4 linen and 2 thread, so one craft.
local action = LevelUp:CraftAction(1, "5")
check("crafts, clamped to what the bags make", action.kind == "craft" and action.count == 1)
check("and says so", action.status == "Your bags only have materials for 1.")
check("the button names the number", action.text == "Craft 1")

action = LevelUp:CraftAction(4, "3")
check("a number the bags cover is kept", action.count == 3 and action.status == "Makes 3 now.")

windowShows = false
action = LevelUp:CraftAction(1, "1")
check("the wrong window open means open the right one first",
    action.kind == "open" and action.text == "Open Tailoring" and action.profession.spell == "Tailoring")
windowShows = true

ready, reason = false, "need materials"
action = LevelUp:CraftAction(6, "1")
check("short of materials: no craft, and says why",
    action.kind == "none" and action.status == "You are short of materials for this one.")
ready, reason = true, nil

busy = true
check("while crafting, the button stops it", LevelUp:CraftAction(1, "1").kind == "stop")
busy = false

print("\nwhat a craft gets back")

-- Belt and Aaa Belt both cost 3s. The belt sells to a vendor for 1s, lists
-- for 2s, and disenchants for 2s 50c of materials; the kilt (green, 5s) is
-- grey quality, so only the vendor counts for it.
local KILT_ITEM, BELT_ITEM, AAA_ITEM, CAPE_ITEM = 5006, 5001, 5009, 5002
local quality = { [KILT_ITEM] = 0, [BELT_ITEM] = 2, [AAA_ITEM] = 2, [CAPE_ITEM] = 2 }
local vendorPays = { [KILT_ITEM] = 40, [BELT_ITEM] = 100, [AAA_ITEM] = 100 }
local listsFor = { [KILT_ITEM] = 5000, [BELT_ITEM] = 200, [CAPE_ITEM] = 1200 }
local bound = {}
local priceBasis = {}

ns.Util.GetVendorSellPrice = function(id) return vendorPays[id] end
ns.Util.IsBoundOnPickup = function(id) return bound[id] == true end
ns.Profit.ChoosePostPrice = function(_, id) return listsFor[id], priceBasis[id] or "undercut" end
-- A 5% cut and no deposit.
ns.Profit.NetFromListing = function(_, _, price) return price * 0.95 end
ns.Disenchant = {
    GetItemFacts = function(_, id) return quality[id] and { quality = quality[id] } or nil end,
    IsDisenchantable = function(_, id) return quality[id] == 2 end,
    GetValue = function(_, id) return id == BELT_ITEM and 250 or nil end,
}

local belt = LevelUp:BuildRow(1)
check("the vendor pays in full", belt.returns.vendor == 100)
check("the auction house after its cut", belt.returns.auction == 190)
check("a disenchant's materials lose the cut too", belt.returns.disenchant == 238)
check("the best way back is counted", belt.back == 238 and belt.backWay == "disenchant")
check("real cost is the materials less that", belt.realCost == 300 - 238)

local kilt = LevelUp:BuildRow(6)
check("grey: the vendor only, never the auction house",
    kilt.returns.vendor == 40 and kilt.returns.auction == nil and kilt.back == 40)

bound[BELT_ITEM] = true
belt = LevelUp:BuildRow(1)
check("soulbound: no auction, a disenchant still counts",
    belt.returns.auction == nil and belt.returns.disenchant == 238)
bound[BELT_ITEM] = nil

priceBasis[CAPE_ITEM] = "derived"
local cape2 = LevelUp:BuildRow(2)
check("a price worked out from the materials is not a sale", cape2.back == nil and cape2.realCost == nil)
priceBasis[CAPE_ITEM] = nil
cape2 = LevelUp:BuildRow(2)
check("a craft that sells for more than it costs pays you back", cape2.realCost == 900 - 1140)

rows = LevelUp:GetRanked({ skillLines = tailoring })
print("  " .. names(rows))
check("in a colour, the lowest real cost goes first",
    names(rows) == "Woolen Cape, Linen Belt, Aaa Belt, Odd Gloves, "
        .. "Linen Bandana, Bolt of Woolen Cloth, Simple Kilt, Unread Shirt")

print("\nthe Profit tab's choice of way")

-- The belt: vendor 1s, auction 1s 90c, disenchant 2s 38c, materials 3s.
local method = "auction"
ns.Profit.GetMethod = function() return method end

belt = LevelUp:BuildRow(1)
check("set to AH, only the auction house counts",
    belt.back == 190 and belt.backWay == "auction" and belt.realCost == 300 - 190)
check("every way is still listed", belt.returns.vendor == 100 and belt.returns.disenchant == 238)

method = "vendor"
belt = LevelUp:BuildRow(1)
check("set to Vendor, the vendor counts", belt.back == 100 and belt.backWay == "vendor")

method = "disenchant"
kilt = LevelUp:BuildRow(6)
check("set to DE, a craft that cannot be disenchanted gets nothing back",
    kilt.back == nil and kilt.realCost == nil and kilt.returns.vendor == 40)

method = "best"
belt = LevelUp:BuildRow(1)
check("set to Best, whichever pays most", belt.back == 238 and belt.backWay == "disenchant")

method = "vendordisenchant"
belt = LevelUp:BuildRow(1)
check("set to Vendor and DE, the better of those two", belt.back == 238 and belt.backWay == "disenchant")
kilt = LevelUp:BuildRow(6)
check("Vendor and DE: no disenchant, the vendor counts", kilt.back == 40 and kilt.backWay == "vendor")

method = "something old"
belt = LevelUp:BuildRow(1)
check("an unknown choice counts as Best", belt.back == 238 and belt.returns.method == "best")
ns.Profit.GetMethod = nil

ns.Util.GetVendorSellPrice, ns.Util.IsBoundOnPickup = nil, nil
ns.Profit.ChoosePostPrice, ns.Profit.NetFromListing, ns.Disenchant = nil, nil, nil

print("\nsub-crafts only, and never made as one")

-- Asked 2026-10-07: the crafts whose item another craft uses, grey ones
-- too, each marked Make or Buy.
recipes[3].skillUp = { tier = "trivial" }
local subs = LevelUp:GetRanked({ skillLines = tailoring, subCraftsOnly = true })
check("only the bolt, which the cape uses, grey or not (got " .. names(subs) .. ")",
    names(subs) == "Bolt of Woolen Cloth")
check("it is a material, made as a sub-craft", subs[1].isMaterial and not subs[1].neverSubCraft)
recipes[3].skillUp = { tier = "medium" }

ns.db = {}
local before = LevelUp:BuildRow(2).cost
ns.Cost:SetNeverSubCraft(3, true)
local after = LevelUp:BuildRow(2)
check("the cape's bolt is made while allowed (got " .. tostring(before) .. ")", before == 900)
check("marked, the cape buys its bolt (got " .. tostring(after.cost) .. ")", after.cost == 2000)
check("its material says it is not made", not after.costDetail.reagents[1].crafted
    and ns.Cost:NeverMadeRecipeFor(BOLT) == 3)
check("the bolt's row says Buy", LevelUp:BuildRow(3).neverSubCraft == true)
check("the bolt can still be made and ranked itself",
    names(LevelUp:GetRanked({ skillLines = tailoring })):find("Bolt of Woolen Cloth", 1, true) ~= nil)
ns.Cost:SetNeverSubCraft(3, false)
check("allowed again, the bolt is made", LevelUp:BuildRow(2).cost == 900)

-- Asked 2026-10-09: a Lesser Mana Potion only an alt makes could not be
-- marked. Sub-crafts only lists every character's, saying who knows it.
local POTION, VIAL = 3385, 3371
ns.db = { characters = {
    ALT = { recipes = {
        [20] = R(20, "Lesser Mana Potion", nil, 171, { { itemID = VIAL, quantity = 1 } }, POTION),
        [21] = R(21, "Mana Draught", nil, 171, { { itemID = POTION, quantity = 1 } }),
        [3] = recipes[3],
    } },
} }
local altRecipes = ns.db.characters.ALT.recipes
local savedGetAny, savedCount = ns.Recipes.GetAny, ns.Profit.GetCraftableCount
ns.Recipes.GetAny = function(_, id) return recipes[id] or altRecipes[id] end
ns.Profit.GetCraftableCount = function(self, id)
    if recipes[id] then return savedCount(self, id) end
    return 0
end
local plain = LevelUp:GetRanked({})
check("left out of the usual list, which is this character's", not names(plain):find("Lesser Mana Potion", 1, true))
local all = LevelUp:GetRanked({ subCraftsOnly = true })
local potion
for _, row in ipairs(all) do if row.recipeID == 20 then potion = row end end
check("listed with Sub-crafts only (got " .. names(all) .. ")", potion ~= nil)
check("and says the alt knows it", potion.knownBy == "ALT")
local bolt
for _, row in ipairs(all) do if row.recipeID == 3 then bolt = row end end
check("a craft this character knows too is not named after the alt", bolt and bolt.knownBy == nil)
check("an alt's craft nobody uses is not a sub-craft", not names(all):find("Mana Draught", 1, true))
ns.Recipes.GetAny, ns.Profit.GetCraftableCount = savedGetAny, savedCount
ns.db = nil

print("\n  all level up checks passed\n")
