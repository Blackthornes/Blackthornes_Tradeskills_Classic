-- Profit by way (Discord, 2026-10-06): what a craft makes sold at
-- the auction house, sold to a vendor and disenchanted, and a profit for
-- whichever pays most or for one way alone.

-- Tests share one Lua state, so every global replaced here is put back,
-- including the ones that were not set at all.
local GLOBALS = { "CreateFrame", "GetTime", "time", "C_Item" }
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

local BELT, LINEN, RECIPE, DUST, ESSENCE = 5000, 2589, 300, 10940, 10938

-- What a vendor pays is the eleventh return: 80c for the belt.
C_Item = { GetItemInfo = function(itemID)
    return "item " .. itemID, "link", 1, 1, 1, "", "", 1, "", "", itemID == BELT and 80 or 1
end }

local recipe = { recipeID = RECIPE, name = "Linen Belt", outputItemID = BELT,
    quantityMin = 1, quantityMax = 1, reagents = { { itemID = LINEN, quantity = 7 } } }

-- Two listings to sell: the first runs out and keeps its deposit, so one
-- deposit counts. A sale hands the deposit back (see the end).
local settings = { undercutCopper = 1, auctionCut = 0.05, expectedRelists = 2, minProfit = 0,
    staleAfterSeconds = 48 * 3600, valueOwnedMaterials = true, unscannedMarkupPercent = 50,
    priceUnscannedCrafts = true }

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterEvent = noop
local commands, printed = {}, {}
ns.RegisterCommand = function(name, _, fn) commands[name] = fn end
ns.Print = function(text) printed[#printed + 1] = text end
ns.PrintRaw = function(text) printed[#printed + 1] = text end
ns.Debug, ns.Warn = noop, noop

local priceTable = {}
ns.Config = {
    Get = function(_, key) return settings[key] end,
    GetCharacterKey = function() return "Me" end,
    GetPriceTable = function() return priceTable end,
}
ns.Recipes = {
    GetAll = function() return { [RECIPE] = recipe } end,
    Get = function() return recipe end,
    GetAny = function() return recipe, "Me" end,
    GetAccountWide = function() return { [RECIPE] = recipe } end,
    GetCharacterName = function() return "Me" end,
    IsDropped = function() return false end,
    Find = function() return { recipe } end,
    GetDisplayLink = function() return "[Linen Belt]" end,
}
ns.Inventory = {
    GetBagCount = function() return 0 end, GetCharacterBagCount = function() return 0 end,
    GetBankCount = function() return 0 end, GetOwnedCount = function() return 0 end,
    GetAltTotal = function() return 0 end,
}
ns.Vendor = { GetUnitPrice = function() return nil end }
ns.Scanner = { GetCommodityStatus = function() return true end }
ns.Auctions = { GetRoom = function() return nil, 0, 0, 0, 0, 0 end }

assert(loadfile(lfs_cwd .. "/Core/Util.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Data/Prices.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Cost.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Profit.lua"))("Blackthornes_TS", ns)

-- A deposit of 3c a belt is known from the last listing.
ns.Posting = { GetCachedUnitDeposit = function() return 3 end }

local Profit = ns.Profit

-- The belt disenchants to 2s of materials at the most likely result, and
-- needs Enchanting 50. Who can disenchant is set per check below.
local enchanterSkill
local disenchantable = true
ns.Disenchant = {
    IsDisenchantable = function() return disenchantable end,
    GetValue = function()
        if disenchantable then
            return 200, nil, { outcomes = { { itemID = DUST, counted = true }, { itemID = ESSENCE } } }
        end
    end,
    GetBestEnchanter = function() return enchanterSkill, enchanterSkill and "Ana" or nil end,
    GetItemFacts = function() return { skill = 50 } end,
}

local passed, failed = 0, 0
local function check(label, got, want)
    local ok = got == want
    if ok then passed = passed + 1 else failed = failed + 1 end
    print(string.format("  %-58s %-10s %s", label, tostring(got), ok and "ok" or
        ("WRONG, wanted " .. tostring(want))))
end

local function Printed(fragment)
    for _, line in ipairs(printed) do
        if tostring(line):find(fragment, 1, true) then return true end
    end
    return false
end

-- Linen at 10c: 70c of materials a belt. A rival lists it at 60c, under
-- the vendor's 80c, and a 3c deposit is known.
ns.Prices:Record(LINEN, 10, 10, 500, time(), 10, nil)
ns.Prices:Record(BELT, 65, 60, 4, time(), 60, nil)
-- The dust the belt breaks into was last scanned three days ago.
ns.Prices:Record(DUST, 50, 50, 20, time() - 3 * 86400, 50, nil)

print("")
print("asked the old way, nothing changes")

local a = Profit:Analyse(RECIPE)
check("it is still the vendor's sale", a.via, "vendor")
check("making 10c", a.profit, 10)
check("every way is still worked out", a.ways.disenchant ~= nil and a.ways.auction ~= nil, true)
check("disenchanted it makes 2s less the cut, less 70c", a.ways.disenchant.profit, 120)

print("")
print("the best way, with an enchanter who can break it")

enchanterSkill = 75
a = Profit:Analyse(RECIPE, nil, "best")
check("disenchanting pays most", a.via, "disenchant")
check("so the profit is that", a.profit, 120)
check("valued at what it disenchants to", a.unitRevenue, 200)
check("less the cut on the materials", a.cut, 10)
check("with no deposit", a.deposit, 0)
check("and it says how", a.priceBasis, "disenchant")
check("margin is on what it disenchants to", a.margin, 120 / 200)
-- A player (Discord, 2026-10-08): AGE said "DE" here instead of an age.
check("its age is the dust's scan, not the belt's", a.age, 3 * 86400)
check("which is past the stale limit", a.stale, true)
check("read off the material it is valued at", a.ageItemID, DUST)

local lines = Profit:DescribeWays(a)
check("all three ways are described", #lines, 3)
check("vendor first", lines[1].way, "vendor")
check("the one chosen is marked", lines[3].chosen, true)
check("and only that one", lines[1].chosen, false)

print("")
print("nobody can disenchant it")

enchanterSkill = nil
a = Profit:Analyse(RECIPE, nil, "best")
check("the vendor pays most of what is left", a.via, "vendor")
check("making 10c", a.profit, 10)
check("the disenchant line says why", Profit:DescribeWays(a)[3].note, "no enchanter")

enchanterSkill = 20
a = Profit:Analyse(RECIPE, nil, "best")
check("an enchanter below the skill it needs does not count either", a.via, "vendor")
check("and the line says so", Profit:DescribeWays(a)[3].note, "skill too low")

print("")
print("one way alone")

a = Profit:Analyse(RECIPE, nil, "auction")
check("ranked by the AH, the listing's profit", a.via, "auction")
check("is a loss: 59c less the cut and deposit, less 70c", math.floor(a.profit * 100 + 0.5), -1695)
check("priced as the listing", a.priceBasis, "undercut")
check("with its deposit", a.deposit, 3)

a = Profit:Analyse(RECIPE, nil, "vendor")
check("ranked by the vendor, 10c", a.profit, 10)
check("a vendor's row keeps the belt's own scan for /bts why", a.age, 0)

a = Profit:Analyse(RECIPE, nil, "disenchant")
check("ranked by disenchanting, its profit even with no enchanter", a.profit, 120)

disenchantable = false
a = Profit:Analyse(RECIPE, nil, "disenchant")
check("something that cannot be disenchanted has no profit that way", a.priceable, nil)
check("and says why", a.reason, "cannot be disenchanted")
check("it is not listed", #Profit:GetRanked({ method = "disenchant", minProfit = 0 }), 0)
check("but is, ranked the best way", #Profit:GetRanked({ method = "best", minProfit = 0 }), 1)
check("with only two ways, both are described", #Profit:DescribeWays(Profit:Analyse(RECIPE, nil, "best")), 2)
disenchantable = true

print("")
print("vendor and DE, the AH left out (asked 2026-11-12)")

enchanterSkill = 75
a = Profit:Analyse(RECIPE, nil, "vendordisenchant")
check("disenchanting still wins when someone can break it", a.via, "disenchant")
check("at its profit", a.profit, 120)
enchanterSkill = nil
a = Profit:Analyse(RECIPE, nil, "vendordisenchant")
check("with no enchanter the vendor wins", a.via, "vendor")
check("making 10c", a.profit, 10)
ns.Prices:Record(BELT, 900000, 900000, 4, time(), 900000, nil)
check("the AH pays most of all now", Profit:Analyse(RECIPE, nil, "best").via, "auction")
check("but vendor and DE never picks it", Profit:Analyse(RECIPE, nil, "vendordisenchant").via, "vendor")
ns.Prices:Record(BELT, 65, 60, 4, time(), 60, nil)
settings.profitBy = "vendordisenchant"
check("the pick is kept", Profit:GetMethod(), "vendordisenchant")
check("it is listed", #Profit:GetRanked({ method = "vendordisenchant", minProfit = 0 }), 1)
settings.profitBy = nil

check("the tag names the AH", Profit.WayTag("auction"):find("(AH)", 1, true) ~= nil, true)
check("the vendor", Profit.WayTag("vendor"):find("(Vendor)", 1, true) ~= nil, true)
check("and disenchanting", Profit.WayTag("disenchant"):find("(DE)", 1, true) ~= nil, true)
check("no way, no tag", Profit.WayTag(nil), "")

print("")
print("the choice kept in Settings")

check("nothing picked is the best way", Profit:GetMethod(), "best")
settings.profitBy = "vendor"
check("a pick is kept", Profit:GetMethod(), "vendor")
settings.profitBy = "nonsense"
check("anything else is the best way", Profit:GetMethod(), "best")

enchanterSkill = 75
settings.profitBy = "best"
printed = {}
commands.why("Linen Belt")
check("/bts why follows it", Printed("disenchanting pays most"), true)
check("and lists every way", Printed("If vendored"), true)
settings.profitBy = nil

print("")
print("sold on the first listing, the deposit comes back")

settings.expectedRelists = 1
a = Profit:Analyse(RECIPE, nil, "auction")
check("no deposit is lost", a.deposit, 0)
check("but the one paid up front is known", a.depositHeld, 3)
check("so the listing pays 3c more", math.floor(a.profit * 100 + 0.5), -1395)
check("and a listing's net keeps it all", math.floor(Profit:NetFromListing(BELT, 84) * 10 + 0.5), 798)
printed = {}
ns.Prices:Record(BELT, 200, 200, 4, time(), 200, nil)
settings.profitBy = "auction"
commands.why("Linen Belt")
settings.profitBy = nil
check("/bts why says it comes back", Printed("back when it sells"), true)
settings.expectedRelists = 0
check("a saved 0 loses none either", Profit.LostListings(), 0)
settings.expectedRelists = 3
check("three listings lose two", Profit.LostListings(), 2)
settings.expectedRelists = 1

print("")
print("a slow seller is expected to lose one deposit")

local demand = { [BELT] = "low" }
ns.Demand = { Get = function(_, id) return demand[id] and { level = demand[id] } or nil end }
check("low demand loses one", Profit.LostListings(BELT), 1)
check("other items lose none", Profit.LostListings(LINEN), 0)
check("asked with no item, only the setting counts", Profit.LostListings(), 0)
a = Profit:Analyse(RECIPE, nil, "auction")
check("the craft pays the 3c deposit", a.deposit, 3)
check("a listing's net loses it too", math.floor(Profit:NetFromListing(BELT, 84) * 10 + 0.5), 768)
settings.expectedRelists = 3
check("a saved number above one still wins", Profit.LostListings(BELT), 2)
demand[BELT] = "some"
settings.expectedRelists = 1
check("some demand loses none", Profit.LostListings(BELT), 0)
ns.Demand = nil
settings.expectedRelists = 2

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print("")
print(("%d passed, %d failed"):format(passed, failed))
assert(failed == 0, "profit by way checks failed")
