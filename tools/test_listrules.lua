-- Rules for a whole list (Logic/ListRules.lua), and where they reach:
-- Profit:ChoosePostPrice (Lowest Price), Posting:DurationFor (Post For),
-- BuyQuantity.UnitsUpTo (Most I'll Pay).
--
-- What must hold:
--   1. A new list has no rules; a rule is kept cleaned and in range, an
--      empty one is taken off, and Clear takes them all off.
--   2. Each list gets a stable id that survives a rename and a delete
--      above it.
--   3. An item follows the first list holding it that has a rule.
--   4. Its own price on the Prices tab beats the list's Lowest Price.
--   5. Keep Listed counts stacks up and the room left.
--   6. Post For changes only that list's items' length.
--   7. Most I'll Pay counts only the cheap enough units, past your own.

local function noop() end

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand, ns.RegisterEvent = noop, noop
ns.Debug, ns.Warn, ns.Print = noop, noop, noop
ns.L = setmetatable({ Format = string.format }, { __index = function(_, key) return key end })
ns.Util = { HasFunction = function() return false end }
ns.db = {}

local settings = { postDuration = 2 }
ns.Config = { Get = function(_, key) return settings[key] end }

local mine = {}
local marketOf = {}
ns.Prices = {
    GetMine = function(_, id) if mine[id] then return mine[id], "floor" end end,
    GetValue = function(_, id) return marketOf[id] end,
}

local posted = {}
ns.Auctions = { GetOwnPostedCount = function(_, id) return posted[id] or 0 end }

C_Item = { GetItemMaxStackSizeByID = function(id) return id == 900 and 1 or 20 end }

assert(loadfile(lfs_cwd .. "/Logic/ShoppingLists.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/ListRules.lua"))("Blackthornes_TS", ns)
local Lists, Rules = ns.ShoppingLists, ns.ListRules

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

local PEACE, MAGE, SILK, BAND = 2447, 785, 4306, 900

print("\nlist rules")

-- 1. Setting and clearing
local herbs = Lists:Make("Herbs")
Lists:Add(herbs, PEACE, 40)
Lists:Add(herbs, MAGE, 40)
local cloth = Lists:Make("Cloth to sell")
Lists:Add(cloth, SILK, 10)
Lists:Add(cloth, PEACE, 5)

check("a new list has no rules", Rules.Count(Lists:Get(herbs)) == 0 and Rules:For(PEACE) == nil)
local version = Lists.version
check("a rule is set", Rules:Set(herbs, "floor", 3000) and Rules.Of(Lists:Get(herbs)).floor == 3000)
check("setting one moves the lists' version", Lists.version > version)
Rules:Set(herbs, "listed", 500)
check("Keep Listed stays in range", Rules.Of(Lists:Get(herbs)).listed == Rules.MAX_LISTED)
Rules:Set(herbs, "duration", 7)
check("Post For stays in range", Rules.Of(Lists:Get(herbs)).duration == 3)
Rules:Set(herbs, "bags", "20.6")
check("Keep in Bags is a whole number", Rules.Of(Lists:Get(herbs)).bags == 20)
Rules:Set(herbs, "maxPay", 4500)
check("five rules counted", Rules.Count(Lists:Get(herbs)) == 5)
Rules:Set(herbs, "bags", 0)
check("0 takes a rule off", Rules.Of(Lists:Get(herbs)).bags == nil and Rules.Count(Lists:Get(herbs)) == 4)
check("a rule that is not one is refused", Rules:Set(herbs, "colour", 3) == false)
check("a list that is gone is refused", Rules:Set(9, "floor", 1) == false)
Lists:Get(herbs).rules.listed = "junk"
check("a broken value in the save reads as no rule", Rules.Of(Lists:Get(herbs)).listed == nil)
Rules:Set(herbs, "listed", 5)

-- 2. Stable ids
local herbsId = Lists:Get(herbs).id
check("each list has an id", type(herbsId) == "number" and Lists:Get(cloth).id ~= herbsId)
Lists:Rename(herbs, "Potion herbs")
check("a rename keeps it", Lists:Get(herbs).id == herbsId)
local clothId = Lists:Get(cloth).id
Lists:Delete(herbs)
local newOne = Lists:Make("Ore")
Lists:Readable()
check("a delete above keeps the next one's", Lists:Get(1).id == clothId)
cloth = 1
check("a new list never takes an old id", Lists:Get(newOne).id ~= herbsId and Lists:Get(newOne).id ~= clothId)

-- 3. Which list an item follows
herbs = Lists:Make("Herbs")
Lists:Add(herbs, PEACE, 40)
Lists:Add(herbs, MAGE, 40)
Rules:Set(herbs, "floor", 3000)
Rules:Set(herbs, "listed", 5)
Rules:Set(herbs, "duration", 3)
check("an item on no list with rules follows none", Rules:For(SILK) == nil)
check("an item follows its list", Rules:For(MAGE) and Rules:For(MAGE).name == "Herbs")
Rules:Set(cloth, "floor", 100)
check("on two lists, the higher one wins", Rules:For(PEACE).name == "Cloth to sell")
check("its floor is that list's", Rules:Floor(PEACE) == 100)
check("the other list's still holds its own items", Rules:Floor(MAGE) == 3000)

-- 4. Its own price wins
mine[MAGE] = 2000
check("its own price beats the list's floor", Rules:Floor(MAGE) == nil)
check("and says so", Rules:OwnPriceWins(MAGE) == true)
check("an item without one does not", Rules:OwnPriceWins(SILK) == false)
mine[MAGE] = nil

-- 5. Keep Listed
posted[MAGE] = 45
local room, up = Rules:ListedRoom(MAGE)
check("5 stacks of 20 with 45 up leaves 55", room == 55)
check("45 up is 3 stacks", up == 3)
posted[MAGE] = 120
room, up = Rules:ListedRoom(MAGE)
check("full leaves no room", room == 0 and up == 6)
check("no rule gives nothing", Rules:ListedRoom(SILK) == nil)

-- 6. Post For
check("its list's length", Rules:Duration(MAGE) == 3)
check("the usual length otherwise", Rules:Duration(SILK) == 2)

-- 7. Clear
check("Clear takes them all", Rules:Clear(herbs) and Rules:For(MAGE) == nil
    and Lists:Get(herbs).rules == nil)

print("\nthe price, the length and the buy box")

-- Lowest Price in the price chosen.
local status = true
ns.Scanner = { GetCommodityStatus = function() return status end }
local market = 0
ns.Profit = nil
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.Util.RoundToSilver = function(v) return v end
ns.Util.LinkSuffix = function() return nil end
assert(loadfile(lfs_cwd .. "/Logic/Profit.lua"))("Blackthornes_TS", ns)
ns.Profit.ChooseMarketPostPrice = function() return market, "undercut" end

Rules:Set(herbs, "floor", 3000)
market = 2500
local price, basis, why = ns.Profit:ChoosePostPrice(MAGE)
check("raised to its list's Lowest Price", price == 3000 and basis == "list")
check("saying which list", why == "Following your Herbs list.")
market = 4000
price, basis = ns.Profit:ChoosePostPrice(MAGE)
check("above it, the usual price", price == 4000 and basis == "undercut")
market = 2500
price, basis = ns.Profit:ChoosePostPrice(SILK)
check("an item on no list is as before", price == 2500 and basis == "undercut")

print("\npercent floors, Highest and When Cheaper")

-- Lowest Price as a percent: one kind at a time.
Rules:Set(herbs, "floorMarket", 150)
check("% of Market takes the place of a set price",
    Rules.Of(Lists:Get(herbs)).floor == nil and Rules.Of(Lists:Get(herbs)).floorMarket == 150)
check("a percent stays in range", Rules:Set(herbs, "floorMarket", 5000)
    and Rules.Of(Lists:Get(herbs)).floorMarket == Rules.MAX_PERCENT)
Rules:Set(herbs, "floorMarket", 150)
marketOf[MAGE] = 2001
check("150% of a 20.01s market is 30.02s", Rules:Floor(MAGE) == 3002)
marketOf[MAGE] = nil
check("no market price, no Lowest Price", Rules:Floor(MAGE) == nil)

local made, recipes, materials = {}, {}, {}
ns.CraftedCost = { Get = function(_, id) return made[id] end }
ns.Cost = {
    FindAnyRecipeForItem = function(_, id) return recipes[id] end,
    GetMaterialValue = function(_, recipeID)
        if materials[recipeID] == "boom" then error("no price") end
        return materials[recipeID]
    end,
}
Rules:Set(herbs, "floorCost", 200)
check("% of Cost takes the place of % of Market",
    Rules.Of(Lists:Get(herbs)).floorMarket == nil and Rules.Of(Lists:Get(herbs)).floorCost == 200)
check("not made by any recipe: no Lowest Price", Rules:Floor(MAGE) == nil)
recipes[MAGE] = 77
materials[77] = 500
check("today's materials: twice 5s", Rules:Floor(MAGE) == 1000)
check("a costing the caller has for that recipe wins",
    Rules:Floor(MAGE, { recipeID = 77, priceable = true, perUnit = 400 }) == 800)
check("one for another recipe is not used",
    Rules:Floor(MAGE, { recipeID = 78, priceable = true, perUnit = 400 }) == 1000)
made[MAGE] = { cost = 300 }
check("the last craft's cost wins over both",
    Rules:Floor(MAGE, { recipeID = 77, priceable = true, perUnit = 400 }) == 600)
made[MAGE], materials[77] = nil, "boom"
check("a costing that fails is no Lowest Price", Rules:Floor(MAGE) == nil)
materials[77] = 500

-- Highest Price and When Cheaper
check("no limits yet", Rules:Limits(MAGE) == nil)
Rules:Set(herbs, "high", 5000)
Rules:Set(herbs, "wait", 1)
local high, wait, listName = Rules:Limits(MAGE)
check("the list's limits", high == 5000 and wait == true and listName == "Herbs")
check("When Cheaper is on or off", Rules:Set(herbs, "wait", 3) and Rules.Of(Lists:Get(herbs)).wait == 1)
mine[MAGE] = 2000
check("its own price beats the list's limits too", Rules:Limits(MAGE) == nil)
check("and says so", Rules:OwnPriceWins(MAGE) == true)
mine[MAGE] = nil

-- In the price chosen. Lowest Price here is 2 x 5s = 10s.
market = 800
local waits
price, basis, why, _, waits = ns.Profit:ChoosePostPrice(MAGE)
check("under the Lowest Price: lists at it", price == 1000 and basis == "list")
check("and waits, since others sell for less", waits == true)
ns.Profit.ChooseMarketPostPrice = function() return market, "derived" end
price, basis, why, _, waits = ns.Profit:ChoosePostPrice(MAGE)
check("a price from the materials is no rival: no wait", price == 1000 and waits == nil)
ns.Profit.ChooseMarketPostPrice = function() return market, "undercut" end
market = 9000
price, basis, why = ns.Profit:ChoosePostPrice(MAGE)
check("over the Highest Price: lists at it", price == 5000 and basis == "highest")
check("saying which list", why == "Following your Herbs list.")
market = 3000
price, basis = ns.Profit:ChoosePostPrice(MAGE)
check("between the two: the usual price", price == 3000 and basis == "undercut")
Rules:Set(herbs, "floorCost", 0)
Rules:Set(herbs, "wait", 0)
market = 9000
price, basis = ns.Profit:ChoosePostPrice(MAGE)
check("Highest alone still holds", price == 5000 and basis == "highest")
Rules:Set(herbs, "high", 0)
Rules:Set(herbs, "floor", 3000)

-- Post For in the posting length.
assert(loadfile(lfs_cwd .. "/Logic/Posting.lua"))("Blackthornes_TS", ns)
Rules:Set(herbs, "duration", 1)
check("a listing goes up for its list's length", ns.Posting:DurationFor(MAGE) == 1)
check("others for the usual one", ns.Posting:DurationFor(SILK) == 2)

-- Most I'll Pay counts the cheap units.
ns.Theme = nil
assert(loadfile(lfs_cwd .. "/UI/BuyQuantity.lua"))("Blackthornes_TS", ns)
local listings = {
    { unitPrice = 40, quantity = 10, own = 2 },
    { unitPrice = 45, quantity = 5, own = 0 },
    { unitPrice = 60, quantity = 50, own = 0 },
}
check("units at or under the price, less your own", ns.BuyQuantity.UnitsUpTo(listings, 45) == 13)
check("none cheap enough is 0", ns.BuyQuantity.UnitsUpTo(listings, 10) == 0)
check("no listings is nil", ns.BuyQuantity.UnitsUpTo(nil, 45) == nil)


print("\nthe Rules window")

-- Frames that remember what is set on them and answer anything else.
local function Stub()
    local f = { scripts = {}, shown = true }
    function f:SetScript(name, fn) self.scripts[name] = fn end
    function f:GetScript(name) return self.scripts[name] end
    function f:SetShown(on) self.shown = on and true or false end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:IsShown() return self.shown end
    function f:CreateTexture() return Stub() end
    return setmetatable(f, { __index = function() return noop end })
end
CreateFrame = function() return Stub() end
UIParent = Stub()
GameTooltip = Stub()
ns.Theme = setmetatable({
    Unpack = function() return 1, 1, 1, 1 end,
    CreateLabel = function() return Stub() end,
    CreateHeading = function() return Stub() end,
}, { __index = function() return noop end })
local function Box()
    local box = Stub()
    box.editBox = Stub()
    function box:SetValue(value) self.value = value end
    function box:GetValue() return self.value end
    return box
end
local drops = {}
ns.Widgets = {
    CreateButton = function() return Stub() end,
    CreateNumberBox = function(_, opts)
        local box = Box()
        box.onChange = opts.onChange
        return box
    end,
    CreateDropdown = function(_, options, onSelect)
        local drop = Box()
        drop.menu, drop.label, drop.options, drop.onSelect = Stub(), Stub(), options, onSelect
        drops[#drops + 1] = drop
        return drop
    end,
}
local moneys = {}
ns.PriceEditor = { MoneyBoxes = function(_, onCommit)
    local money = { onCommit = onCommit, copper = Stub() }
    function money:SetPoint() end
    function money:Set(copper) self.value = copper end
    moneys[#moneys + 1] = money
    return money
end }
assert(loadfile(lfs_cwd .. "/UI/ListRulesWindow.lua"))("Blackthornes_TS", ns)
local UI = ns.ListRulesUI
Rules:Clear(herbs)
UI:Open(herbs)
check("opens on Set Price", UI.floorKind:GetValue() == "floor")
check("with the money boxes showing", UI.floorMoneyHolder.shown and not UI.floorPercentHolder.shown)
check("When Cheaper starts at List Anyway", UI.under:GetValue() == "list")
UI.floor.onCommit(2500)
check("a set price saves", Rules.Of(Lists:Get(herbs)).floor == 2500)

UI.floorKind.onSelect("floorCost")
check("% of Cost takes the set price off", Rules.Of(Lists:Get(herbs)).floor == nil)
check("and shows the percent box", UI.floorPercentHolder.shown and not UI.floorMoneyHolder.shown)
check("the kind stays picked while it is empty", UI.floorKind:GetValue() == "floorCost")
UI.floorPercent.onChange(150)
check("a percent saves as that kind", Rules.Of(Lists:Get(herbs)).floorCost == 150)
UI:Draw()
check("drawn again, it shows that percent", UI.floorPercent:GetValue() == 150)

UI.floorKind.onSelect("floorMarket")
UI.floorPercent.onChange(90)
local rules = Rules.Of(Lists:Get(herbs))
check("% of Market swaps it", rules.floorMarket == 90 and rules.floorCost == nil)

UI.high.onCommit(40000)
check("Highest Price saves", Rules.Of(Lists:Get(herbs)).high == 40000)
UI.high.onCommit(0)
check("0 takes it off", Rules.Of(Lists:Get(herbs)).high == nil)

UI.under.onSelect("wait")
check("Wait saves", Rules.Of(Lists:Get(herbs)).wait == 1)
UI:Draw()
check("and shows", UI.under:GetValue() == "wait")
UI.under.onSelect("list")
check("List Anyway takes it off", Rules.Of(Lists:Get(herbs)).wait == nil)

UI:Hide()
Rules:Set(herbs, "floor", 700)
UI:Open(herbs)
check("opened again, it reads what is saved", UI.floorKind:GetValue() == "floor"
    and UI.floor.value == 700)

print(("\n%d checks passed"):format(checks))
