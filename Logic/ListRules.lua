-- Blackthornes Tradeskills -- Logic/ListRules.lua
-- Rules for a whole list (the owner said build it, 2026-10-19, from a
-- mockup): a list on the Lists view (Logic/ShoppingLists.lua) can carry a
-- few rules that every item on it follows, so a rule is set once for a
-- whole list instead of item by item.
--
-- Kept on the list itself, `shoppingLists[i].rules` (never rename it):
--   floor    copper: List all and List never go under it (Lowest Price)
--   listed   stacks: no more than this many up at a time (Keep Listed)
--   duration 1, 2 or 3, as postDuration: how long it goes up (Post For)
--   bags     units: this many stay in the bags (Keep in Bags)
--   maxPay   copper: the buy box fills only with what costs this or less
--            each (Most I'll Pay)
-- and since 2026-10-28 (the owner said yes):
--   floorMarket  percent: Lowest Price as a percent of the market price
--   floorCost    percent: Lowest Price as a percent of what one cost to
--                make (the last craft, else the materials today)
--                (floor, floorMarket and floorCost: one at a time)
--   high     copper: never list above it (Highest Price)
--   wait     1: keep it in the bags while the auction house is under the
--            Lowest Price (When Cheaper: Wait); unset lists at the floor
-- A field left out has no rule. A new list has none, so nothing changes
-- until the player sets one.
--
-- An item's own setting always wins: its own price on the Prices tab beats
-- Lowest Price, and the bigger keep wins (Butler's, Tradeskills' own, the
-- list's). On two lists, the one higher up on the Lists view wins.
--
-- Each list also gets a stable `id` (a number, made once, never renamed),
-- so Butler can keep its own rules for a list by id when it is renamed.

local _, ns = ...

local ListRules = ns.NewModule("ListRules")

ListRules.FIELDS = { "floor", "listed", "duration", "bags", "maxPay",
    "floorMarket", "floorCost", "high", "wait" }
-- The three ways to set Lowest Price; setting one takes the others off.
ListRules.FLOORS = { "floor", "floorMarket", "floorCost" }
ListRules.MAX_PERCENT = 1000
ListRules.MAX_LISTED = 99
ListRules.MAX_BAGS = 99999
-- The most the gold box takes (214748g), as the price editor.
ListRules.MAX_MONEY = 214748 * 10000 + 9999

local LIMITS = {
    floor = { 1, ListRules.MAX_MONEY },
    listed = { 1, ListRules.MAX_LISTED },
    duration = { 1, 3 },
    bags = { 1, ListRules.MAX_BAGS },
    maxPay = { 1, ListRules.MAX_MONEY },
    floorMarket = { 1, ListRules.MAX_PERCENT },
    floorCost = { 1, ListRules.MAX_PERCENT },
    high = { 1, ListRules.MAX_MONEY },
    wait = { 1, 1 },
}

local IS_FLOOR = { floor = true, floorMarket = true, floorCost = true }

local function Lists() return ns.ShoppingLists end

--- A rule's value as kept: a whole number in range, or nil for no rule.
function ListRules.Clean(field, value)
    local limit = LIMITS[field]
    value = tonumber(value)
    if not limit or not value then return nil end
    value = math.floor(value)
    if value < limit[1] then return nil end
    return math.min(limit[2], value)
end

--- The list's rules, cleaned: a fresh table holding only the rules set.
function ListRules.Of(list)
    local out = {}
    local rules = type(list) == "table" and list.rules
    if type(rules) ~= "table" then return out end
    for _, field in ipairs(ListRules.FIELDS) do
        out[field] = ListRules.Clean(field, rules[field])
    end
    return out
end

--- How many rules a list has.
function ListRules.Count(list)
    local count = 0
    for _ in pairs(ListRules.Of(list)) do count = count + 1 end
    return count
end

--- Set one rule on the list at `index`; nil or 0 takes it off.
-- @return true when the list is there
function ListRules:Set(index, field, value)
    local list = Lists() and Lists():Get(index)
    if not list or not LIMITS[field] then return false end
    if type(list.rules) ~= "table" then list.rules = {} end
    local clean = ListRules.Clean(field, value)
    local changed = list.rules[field] ~= clean
    if clean and IS_FLOOR[field] then
        for _, other in ipairs(ListRules.FLOORS) do
            if other ~= field and list.rules[other] ~= nil then
                list.rules[other] = nil
                changed = true
            end
        end
    end
    if changed then
        list.rules[field] = clean
        if next(list.rules) == nil then list.rules = nil end
        Lists():Touch()
    end
    return true
end

--- Take every rule off a list.
function ListRules:Clear(index)
    local list = Lists() and Lists():Get(index)
    if not list then return false end
    if list.rules ~= nil then
        list.rules = nil
        Lists():Touch()
    end
    return true
end

-- [itemID] = { name, index, id, rules }, laid out once per lists version.
local lookup, lookupVersion

--- The list whose rules an item follows: the first on the Lists view that
--- holds it and has any rule, or nil.
-- @return { name, index, id, rules } (do not change it)
function ListRules:For(itemID)
    local lists = Lists()
    itemID = tonumber(itemID)
    if not lists or not itemID or not ns.db then return nil end
    if lookup == nil or lookupVersion ~= lists.version then
        lookup, lookupVersion = {}, lists.version
        for _, held in ipairs(lists:Readable()) do
            local rules = ListRules.Of(held.list)
            if next(rules) ~= nil then
                local entry = { name = held.list.name, index = held.index, id = held.list.id, rules = rules }
                for _, item in ipairs(type(held.list.items) == "table" and held.list.items or {}) do
                    local id = type(item) == "table" and tonumber(item.id)
                    if id and lookup[id] == nil then lookup[id] = entry end
                end
            end
        end
    end
    return lookup[itemID]
end

--- One rule for an item: its value and the list's name, or nil.
function ListRules:Rule(itemID, field)
    local entry = self:For(itemID)
    local value = entry and entry.rules[field]
    if value then return value, entry.name end
    return nil
end

--- What one of an item cost to make: the last craft, else a costing the
--- caller has for its recipe, else what the materials are worth today.
function ListRules.CostOf(itemID, knownCost)
    local made = ns.CraftedCost and ns.CraftedCost.Get and ns.CraftedCost:Get(itemID)
    if made and made.cost and made.cost > 0 then return made.cost end
    local recipeID = ns.Cost and ns.Cost.FindAnyRecipeForItem and ns.Cost:FindAnyRecipeForItem(itemID)
    if not recipeID then return nil end
    if type(knownCost) == "table" and knownCost.recipeID == recipeID and knownCost.priceable
        and (knownCost.perUnit or 0) > 0 then
        return knownCost.perUnit
    end
    if ns.Cost.GetMaterialValue then
        local ok, value = pcall(ns.Cost.GetMaterialValue, ns.Cost, recipeID)
        if ok and type(value) == "number" and value > 0 then return value end
    end
    return nil
end

--- An item's Lowest Price from its list in copper, worked out from a
--- percent when it is set that way; nil when there is nothing to work from.
local function FloorFor(entry, itemID, knownCost)
    local rules = entry.rules
    if rules.floor then return rules.floor end
    local base
    if rules.floorMarket then
        base = ns.Prices and ns.Prices.GetValue and ns.Prices:GetValue(itemID, "market")
    elseif rules.floorCost then
        base = ListRules.CostOf(itemID, knownCost)
    else
        return nil
    end
    if type(base) ~= "number" or base <= 0 then return nil end
    local floor = math.floor(base * (rules.floorMarket or rules.floorCost) / 100 + 0.5)
    if floor < 1 then return nil end
    return floor
end

local function HasFloor(rules)
    return rules.floor or rules.floorMarket or rules.floorCost
end

local function OwnPrice(itemID)
    return ns.Prices and ns.Prices.GetMine and ns.Prices:GetMine(itemID) ~= nil
end

--- The least an item may be listed at by its list, unless the Prices tab
--- has a price of its own for it (that wins).
-- @param knownCost optional: a costing the caller already has, for % of Cost
-- @return copper, the list's name; or nil
function ListRules:Floor(itemID, knownCost)
    local entry = self:For(itemID)
    if not entry or not HasFloor(entry.rules) or OwnPrice(itemID) then return nil end
    local floor = FloorFor(entry, itemID, knownCost)
    if not floor then return nil end
    return floor, entry.name
end

--- The list's Highest Price and When Cheaper for an item, unless the Prices
--- tab has a price of its own for it (that wins, with its own limits).
-- @return highest (copper or nil), wait (true or nil), the list's name
function ListRules:Limits(itemID)
    local entry = self:For(itemID)
    if not entry or OwnPrice(itemID) then return nil end
    local high, wait = entry.rules.high, entry.rules.wait and true or nil
    if not high and not wait then return nil end
    return high, wait, entry.name
end

--- True when the item is on a list with Lowest Price but its own price on
--- the Prices tab wins, with the list's name.
function ListRules:OwnPriceWins(itemID)
    local entry = self:For(itemID)
    if entry and (HasFloor(entry.rules) or entry.rules.high or entry.rules.wait) and OwnPrice(itemID) then
        return true, entry.name
    end
    return false
end

--- How long an item goes up for: its list's Post For, else the setting.
function ListRules:Duration(itemID)
    local duration = itemID and self:Rule(itemID, "duration")
    if duration then return duration end
    return (ns.Config and ns.Config:Get("postDuration")) or 2
end

--- How big one stack of the item is, as the game says (1 when it won't).
function ListRules.StackSize(itemID)
    local size
    if C_Item and type(C_Item.GetItemMaxStackSizeByID) == "function" then
        local ok, value = pcall(C_Item.GetItemMaxStackSizeByID, itemID)
        size = ok and tonumber(value) or nil
    end
    if not size and type(GetItemInfo) == "function" then
        local ok, value = pcall(function() return select(8, GetItemInfo(itemID)) end)
        size = ok and tonumber(value) or nil
    end
    return math.max(1, math.floor(size or 1))
end

--- Keep Listed for an item: how many more units may go up, and how many
--- stacks are up now.
-- @return room (units, 0 when full), stacksUp; or nil when no rule
function ListRules:ListedRoom(itemID)
    local stacks = self:Rule(itemID, "listed")
    if not stacks then return nil end
    local size = ListRules.StackSize(itemID)
    local up = 0
    if ns.Auctions and ns.Auctions.GetOwnPostedCount then
        local ok, count = pcall(ns.Auctions.GetOwnPostedCount, ns.Auctions, itemID)
        up = ok and tonumber(count) or 0
    end
    return math.max(0, stacks * size - up), math.ceil(up / size)
end
