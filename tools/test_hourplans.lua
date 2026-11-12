-- Gold an hour, buy the parts or make them (a Discord player, 2026-11-12;
-- the owner said build it, casting time only).
--
-- What must hold:
--   * nothing is worked out while "Gold an Hour:" is unticked;
--   * buying every part counts only the final cast; making a part adds its
--     casts, as often as the materials need;
--   * a plan's profit is the craft's profit with only the parts' cost moved;
--   * the best plan is the one earning most an hour, a mix included;
--   * a part nobody sells can only be made, and one no character makes can
--     only be bought;
--   * a cast never timed gives no plan.

local GLOBALS = { "CreateFrame", "GetTime", "time", "C_Item", "C_Spell", "GetSpellInfo",
    "UnitCastingInfo" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local function noop() end

CreateFrame = function()
    return setmetatable({}, { __index = function(_, k)
        if type(k) == "string" and k:match("^%u") then return noop end
    end })
end
GetTime = function() return 1000 end
time = function() return 100000 end
C_Spell, GetSpellInfo = nil, nil

local DYN, POWDER, STONE, FUSE, STRING, WRAP = 4365, 4364, 2836, 7000, 7001, 7002
local DYN_RECIPE, POWDER_RECIPE, FUSE_RECIPE, DE = 3931, 3929, 3999, 13262

-- Nothing is sold to a vendor here.
C_Item = { GetItemInfo = function(itemID)
    return "item " .. itemID, "link", 2, 1, 1, "", "", 1, "", "", 0
end }

local recipes = {
    [DYN_RECIPE] = { recipeID = DYN_RECIPE, name = "Coarse Dynamite", outputItemID = DYN,
        quantityMin = 1, quantityMax = 1,
        reagents = { { itemID = POWDER, quantity = 3 }, { itemID = WRAP, quantity = 1 } } },
    [POWDER_RECIPE] = { recipeID = POWDER_RECIPE, name = "Coarse Blasting Powder", outputItemID = POWDER,
        quantityMin = 1, quantityMax = 1, reagents = { { itemID = STONE, quantity = 1 } } },
}

local settings = { undercutCopper = 1, auctionCut = 0.05, expectedRelists = 1, minProfit = 0,
    staleAfterSeconds = 48 * 3600, valueOwnedMaterials = true, unscannedMarkupPercent = 50,
    priceUnscannedCrafts = true, profitGoldAnHour = false }

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
local events = {}
ns.RegisterEvent = function(owner, event, fn) events[event] = function(...) return fn(owner, event, ...) end end
ns.RegisterCommand = noop
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = noop, noop, noop, noop
ns.db = {}

local priceTable = {}
ns.Config = {
    Get = function(_, key) return settings[key] end,
    GetCharacterKey = function() return "Me" end,
    GetPriceTable = function() return priceTable end,
}
ns.Recipes = {
    GetAll = function() return recipes end,
    Get = function(_, id) return recipes[id] end,
    GetAny = function(_, id) return recipes[id], recipes[id] and "Me" or nil end,
    GetAccountWide = function() return recipes end,
    GetCharacterName = function() return "Me" end,
    IsDropped = function() return false end,
    GetDisplayLink = function() return "[Linen Belt]" end,
}
ns.Inventory = {
    GetBagCount = function() return 0 end, GetCharacterBagCount = function() return 0 end,
    GetBankCount = function() return 0 end, GetOwnedCount = function() return 0 end,
    GetAltTotal = function() return 0 end,
}
ns.Vendor = { GetUnitPrice = function(_, id) return id == WRAP and 10 or nil end }
ns.Scanner = { GetCommodityStatus = function() return true end }
ns.Auctions = { GetRoom = function() return nil, 0, 0, 0, 0, 0 end }
ns.Posting = { GetCachedUnitDeposit = function() return 0 end }

assert(loadfile(lfs_cwd .. "/Core/Util.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Data/Prices.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Cost.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/CraftTime.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/HourPlans.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Profit.lua"))("Blackthornes_TS", ns)

local HourPlans, Profit = ns.HourPlans, ns.Profit

local passed, failed = 0, 0
local function check(label, got, want)
    local ok = got == want
    if ok then passed = passed + 1 else failed = failed + 1 end
    print(string.format("  %-58s %-10s %s", label, tostring(got), ok and "ok" or
        ("WRONG, wanted " .. tostring(want))))
end
local function near(a, b) return a ~= nil and b ~= nil and math.abs(a - b) < 0.01 end

-- Stone 5c, powder 30c listed, dynamite 200c. Making a powder (5c) beats
-- buying one, so the costing makes them. Each cast takes 5s.
ns.db.castTimes = { [DYN_RECIPE] = 5, [POWDER_RECIPE] = 5, [FUSE_RECIPE] = 1 }
ns.Prices:Record(STONE, 5, 5, 500, time(), 5, nil)
ns.Prices:Record(POWDER, 30, 30, 500, time(), 30, nil)
ns.Prices:Record(DYN, 200, 200, 50, time(), 200, nil)

print("")
print("off unless ticked")
local a = Profit:Analyse(DYN_RECIPE, nil, "auction")
check("unticked: no plans", a.hourPlans, nil)

settings.profitGoldAnHour = true
a = Profit:Analyse(DYN_RECIPE, nil, "auction")
local plans = a.hourPlans
check("ticked: plans are worked out", type(plans), "table")

print("")
print("buy the parts or make them")
check("make the parts takes 5s and 3 powders at 5s", plans.make.seconds, 20)
check("buy the parts takes the final cast only", plans.buy.seconds, 5)
check("making is the costing's profit", near(plans.make.profit, a.profit), true)
-- Three powders bought at 30c instead of made at 5c: 75c less each time.
check("buying costs 75c more each time", near(plans.make.profit - plans.buy.profit, 75), true)
check("an hour is the profit over the time", near(plans.buy.perHour, plans.buy.profit * 720), true)
check("buying earns more an hour here", plans.best.kind, "buy")
check("the powder is made in the make plan", plans.make.made[POWDER], true)

-- Powder at 6c: buying saves little, making takes 15s longer... still buy?
-- Powder listed at 200c: making wins.
ns.Prices:Record(POWDER, 200, 200, 500, time(), 200, nil)
plans = Profit:Analyse(DYN_RECIPE, nil, "auction").hourPlans
check("with dear powder, making earns more an hour", plans.best.kind, "make")
ns.Prices:Record(POWDER, 30, 30, 500, time(), 30, nil)

print("")
print("a part with one way only")
local realValue = ns.Prices.GetValue
ns.Prices.GetValue = function(self, id, ...) if id == POWDER then return nil end return realValue(self, id, ...) end
plans = Profit:Analyse(DYN_RECIPE, nil, "auction").hourPlans
check("nobody sells the powder: no buy plan", plans.buy, nil)
check("so making is best", plans.best.kind, "make")
ns.Prices.GetValue = realValue

local realFind = ns.Cost.FindRecipeForItem
ns.Cost.FindRecipeForItem = function() return nil end
plans = Profit:Analyse(DYN_RECIPE, nil, "auction").hourPlans
check("nobody makes the powder: no make plan", plans.make, nil)
check("so buying is best", plans.best.kind, "buy")
ns.Cost.FindRecipeForItem = realFind

print("")
print("a mix of the two")
-- A fuse: string 2c makes it in 1s, 40c listed. Worth making; the powder
-- (30c, 5s each) is not.
recipes[FUSE_RECIPE] = { recipeID = FUSE_RECIPE, name = "Fuse", outputItemID = FUSE,
    quantityMin = 1, quantityMax = 1, reagents = { { itemID = STRING, quantity = 1 } } }
ns.Prices:Record(STRING, 2, 2, 500, time(), 2, nil)
ns.Prices:Record(FUSE, 40, 40, 500, time(), 40, nil)
table.insert(recipes[DYN_RECIPE].reagents, { itemID = FUSE, quantity = 1 })
ns.Cost:InvalidateIndex()
plans = Profit:Analyse(DYN_RECIPE, nil, "auction").hourPlans
check("buy the powder, make the fuse", plans.best.kind, "mix")
check("the fuse is made", plans.best.made[FUSE], true)
check("the powder is bought", plans.best.made[POWDER], nil)
check("6s: dynamite and one fuse", plans.best.seconds, 6)
table.remove(recipes[DYN_RECIPE].reagents)
recipes[FUSE_RECIPE] = nil
ns.Cost:InvalidateIndex()

print("")
print("times unknown")
ns.db.castTimes[POWDER_RECIPE] = nil
plans = Profit:Analyse(DYN_RECIPE, nil, "auction").hourPlans
check("powder never cast: buying still has an hour", plans.best.kind, "buy")
check("making has none", plans.make.perHour, nil)
ns.db.castTimes[POWDER_RECIPE] = 5
ns.db.castTimes[DYN_RECIPE] = nil
check("the craft never cast: no plans", Profit:Analyse(DYN_RECIPE, nil, "auction").hourPlans, nil)
ns.db.castTimes[DYN_RECIPE] = 5

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print("")
print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then error(("%d check(s) failed"):format(failed)) end
