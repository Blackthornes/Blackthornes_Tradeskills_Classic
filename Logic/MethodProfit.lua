-- Blackthornes Tradeskills -- Logic/MethodProfit.lua
-- What you made, by the way you made it.
--
-- Asked by a player on 2026-10-11 (the owner agreeing): is there a place that
-- shows the profit from crafting, disenchanting, vendoring and flipping
-- individual items? The Sales tab knew auction profit for crafted items only,
-- and the gold chart knows sources but not items. This brings them together:
--
--   Crafted       auction sales of things you made, against what they cost
--   Flipped       auction sales of things you bought on the auction house
--   Vendored      things a vendor bought from you
--   Disenchanted  what the materials are worth, against what the item cost
--   Farmed        auction sales of things you looted, gathered or fished
--                 (Blackthornes Farmer's records say so; no cost, all profit)
--   Other         auction sales of things with no cost known
--
-- Auction sales are read from the Sales tab's mail ledger, as they stand.
-- Vendor sales and disenchants have no ledger, so each is written down as it
-- happens (`events`), per realm, with no names. What was paid for an item on
-- the auction house is kept as a short list per item (`buys`) so a later sale
-- or disenchant has a cost to be measured against.
--
-- A cost is the craft cost when the item was crafted (Logic/CraftedCost.lua),
-- else the average of what was paid for it on the auction house. An item
-- with neither (loot) has no cost: it counts as all profit, and the figures
-- say how many units that was.
--
-- Nothing here is written into the ledger or rewrites an old record.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local MethodProfit = ns.NewModule("MethodProfit")

local Util = ns.Util

--- In the order they are listed.
MethodProfit.METHODS = {
    { key = "crafted",      text = L["Crafted"],      hint = L["sold at auction, made by you"] },
    { key = "flipped",      text = L["Flipped"],      hint = L["bought at auction, sold again"] },
    { key = "vendored",     text = L["Vendored"],     hint = L["sold to a vendor"] },
    { key = "disenchanted", text = L["Disenchanted"], hint = L["broken down for materials"] },
    { key = "farmed",       text = L["Farmed"],       hint = L["sold at auction, looted or gathered by you"] },
    { key = "other",        text = L["Other sales"],  hint = L["sold at auction, cost not known"] },
}

--- Did you loot, gather or fish this yourself? Asked of Blackthornes
--- Farmer (`Looted:Has`, 2026-10-16), inside a pcall, read only; false
--- without Farmer. `cache` keeps the answers for one Summary.
function MethodProfit:Farmed(itemID, cache)
    if not itemID then return false end
    if cache and cache[itemID] ~= nil then return cache[itemID] end

    local answer = false
    local farmer = rawget(_G, "BlackthornesFarmer")
    local looted = type(farmer) == "table" and farmer.Looted
    if type(looted) == "table" and type(looted.Has) == "function" then
        local ok, has = pcall(looted.Has, looted, itemID)
        answer = ok and has == true
    end
    if cache then cache[itemID] = answer end
    return answer
end

local DAY = 86400

-- Events kept per realm and for how long.
MethodProfit.MAX_EVENTS = 3000
MethodProfit.KEEP = 400 * DAY

-- Purchases kept per item, and how long one is used as a cost.
MethodProfit.MAX_BUYS = 20
MethodProfit.BUY_LIFE = 60 * DAY

--------------------------------------------------------------------------------
-- Storage
--------------------------------------------------------------------------------

--- This realm's record: { events = {...}, buys = { [itemID] = {...} } }.
function MethodProfit:GetLog()
    if not ns.db then return { events = {}, buys = {} } end

    ns.db.methodLog = ns.db.methodLog or {}
    local realm = ns.Config:GetRealmKey()
    local log = ns.db.methodLog[realm]

    if type(log) ~= "table" then
        log = {}
        ns.db.methodLog[realm] = log
    end
    if type(log.events) ~= "table" then log.events = {} end
    if type(log.buys) ~= "table" then log.buys = {} end

    return log
end

local function Now() return time() end

--------------------------------------------------------------------------------
-- Costs
--------------------------------------------------------------------------------

--- A purchase on the auction house: what was paid, in all, for how many.
function MethodProfit:NoteBought(itemID, quantity, paid)
    quantity = tonumber(quantity)
    paid = tonumber(paid)
    if not itemID or not quantity or quantity <= 0 or not paid or paid <= 0 then return end

    local buys = self:GetLog().buys
    local list = buys[itemID]
    if type(list) ~= "table" then
        list = {}
        buys[itemID] = list
    end

    list[#list + 1] = { n = quantity, paid = paid, at = Now() }
    while #list > self.MAX_BUYS do table.remove(list, 1) end
end

--- What one of an item cost on the auction house, on average, over the
--- purchases still counted; nil when there are none.
function MethodProfit:BuyCost(itemID)
    local list = itemID and self:GetLog().buys[itemID]
    if type(list) ~= "table" then return nil end

    local since = Now() - self.BUY_LIFE
    local units, paid = 0, 0
    for _, buy in ipairs(list) do
        if type(buy) == "table" and (tonumber(buy.at) or 0) >= since then
            units = units + (tonumber(buy.n) or 0)
            paid = paid + (tonumber(buy.paid) or 0)
        end
    end

    if units <= 0 then return nil end
    return math.floor(paid / units + 0.5)
end

--- What one of an item cost you, and how that is known.
-- @return each, "made" | "bought", or nil when it cost you nothing known
function MethodProfit:CostOf(itemID)
    local made = itemID and ns.CraftedCost and ns.CraftedCost:Get(itemID)
    if made then return made.cost, "made" end

    local each = self:BuyCost(itemID)
    if each then return each, "bought" end

    return nil
end

--------------------------------------------------------------------------------
-- Writing it down
--------------------------------------------------------------------------------

--- One thing sold to a vendor or disenchanted.
-- @param method  "vendored" or "disenchanted"
function MethodProfit:Record(method, itemID, units, income, cost, at)
    if not itemID or (tonumber(units) or 0) <= 0 then return end

    local log = self:GetLog()
    local events = log.events

    events[#events + 1] = {
        t = at or Now(), m = method, id = itemID, n = units,
        inc = math.max(0, tonumber(income) or 0), c = cost,
    }

    if #events > self.MAX_EVENTS then table.remove(events, 1) end
    self.version = (self.version or 0) + 1
end

--- Drop events too old to be asked for. Quietly, once per login.
function MethodProfit:Prune()
    local events = self:GetLog().events
    local oldest = Now() - self.KEEP
    for i = #events, 1, -1 do
        local event = events[i]
        if type(event) ~= "table" or (tonumber(event.t) or 0) < oldest then
            table.remove(events, i)
        end
    end
end

--- A disenchant: what the materials are worth against what the item cost.
function MethodProfit:NoteDisenchant(itemID, results)
    if not itemID or type(results) ~= "table" then return end

    local worth = 0
    for materialID, count in pairs(results) do
        local price = ns.Disenchant and ns.Disenchant:GetMaterialPrice(materialID)
        if price then worth = worth + price * (tonumber(count) or 0) end
    end

    local each = self:CostOf(itemID)
    self:Record("disenchanted", itemID, 1, worth, each)
end

--- The vendor's buyback list as it stands: { {itemID, quantity, price} }, the
--- price for the whole stack. Whatever is new since the last look was just
--- sold. The first look of a visit is the baseline: those were sold before.
function MethodProfit:NoteBuyback(list)
    if type(list) ~= "table" then return end

    local now = {}
    local sample = {}
    for _, item in ipairs(list) do
        local key = ("%s:%s:%s"):format(item.itemID, item.quantity, item.price)
        now[key] = (now[key] or 0) + 1
        sample[key] = item
    end

    local before = self.buybackSeen
    self.buybackSeen = now
    if not before then return end

    for key, count in pairs(now) do
        local extra = count - (before[key] or 0)
        if extra > 0 then
            local item = sample[key]
            local units = item.quantity * extra
            local each = self:CostOf(item.itemID)
            self:Record("vendored", item.itemID, units, item.price * extra,
                each and each * units or nil)
        end
    end
end

--------------------------------------------------------------------------------
-- Asking
--------------------------------------------------------------------------------

--- The start and end of a period, as the gold chart counts it.
-- @param period  "session" | "today" | "week" | "month" | "pick"
-- @return from, to (to is exclusive)
function MethodProfit.Range(period, fromKey, toKey, now)
    now = now or Now()
    local GoldLog = ns.GoldLog

    if period == "session" then
        return (GoldLog and GoldLog.sessionStart) or now, now + 1
    elseif period == "today" then
        return GoldLog.DayStart(now), now + 1
    elseif period == "month" then
        return now - 30 * DAY, now + 1
    elseif period == "quarter" then
        return now - 91 * DAY, now + 1
    elseif period == "year" then
        return now - 365 * DAY, now + 1
    elseif period == "all" then
        return 0, now + 1
    elseif period == "pick" and fromKey and toKey then
        local low, high = math.min(fromKey, toKey), math.max(fromKey, toKey)
        return GoldLog.KeyStart(low), GoldLog.DayStart(GoldLog.KeyStart(high), 1)
    end

    return now - 7 * DAY, now + 1
end

local function NewGroup()
    return { n = 0, income = 0, cost = 0, unknown = 0, items = {} }
end

local function Add(group, itemID, units, income, cost)
    group.n = group.n + units
    group.income = group.income + income
    group.cost = group.cost + (cost or 0)
    if not cost then group.unknown = group.unknown + units end

    local item = group.items[itemID or 0]
    if not item then
        item = { itemID = itemID, n = 0, income = 0, cost = 0, unknown = 0 }
        group.items[itemID or 0] = item
    end
    item.n = item.n + units
    item.income = item.income + income
    item.cost = item.cost + (cost or 0)
    if not cost then item.unknown = item.unknown + units end
end

--- Everything made between `from` and `to`, by method.
-- @return { methods = { [key] = group }, total = group }, where a group is
--   { n, income, cost, unknown, profit, list = { item, ... } } and each item
--   the same for one item, best profit first.
function MethodProfit:Summary(from, to)
    local methods = {}
    for _, method in ipairs(self.METHODS) do methods[method.key] = NewGroup() end

    -- Auction sales, from the ledger.
    local mail = ns.Mail
    if mail and (mail.Entries or mail.GetLedger) then
        local names = mail.NameIndex and mail:NameIndex() or {}
        local costs = ns.CraftedCost and ns.CraftedCost:NewSaleCache()
        local farmed = {}

        local entries = mail.Entries and mail:Entries() or mail:GetLedger().entries
        for _, entry in ipairs(entries) do
            local t = tonumber(entry.t) or 0
            if entry.kind == "sold" and t >= from and t < to then
                local itemID = entry.itemID or names[entry.name]
                local units = math.max(1, tonumber(entry.quantity) or 1)
                local income = math.max(0, (entry.net or 0) - (entry.deposit or 0))
                local key, each = "other", nil

                if entry.bought and type(entry.cost) == "number" then
                    key, each = "flipped", entry.cost
                elseif type(entry.cost) == "number" then
                    key, each = "crafted", entry.cost
                elseif ns.CraftedCost then
                    local est = ns.CraftedCost:SaleCost(entry, itemID, costs)
                    if est then
                        key, each = "crafted", est
                    else
                        local paid = itemID and self:BuyCost(itemID)
                        if paid then key, each = "flipped", paid end
                    end
                end

                -- No cost known, but you got it yourself: Farmed.
                if key == "other" and self:Farmed(itemID, farmed) then key = "farmed" end

                Add(methods[key], itemID, units, income, each and each * units or nil)
            end
        end
    end

    -- Vendor sales and disenchants, as they were written down.
    for _, event in ipairs(self:GetLog().events) do
        local t = tonumber(event.t) or 0
        local group = methods[event.m]
        if group and t >= from and t < to then
            Add(group, event.id, tonumber(event.n) or 1, tonumber(event.inc) or 0,
                tonumber(event.c))
        end
    end

    local total = NewGroup()
    for _, method in ipairs(self.METHODS) do
        local group = methods[method.key]
        group.profit = group.income - group.cost

        group.list = {}
        for _, item in pairs(group.items) do
            item.profit = item.income - item.cost
            group.list[#group.list + 1] = item
        end
        table.sort(group.list, function(a, b)
            if a.profit ~= b.profit then return a.profit > b.profit end
            return (a.itemID or 0) < (b.itemID or 0)
        end)

        total.n = total.n + group.n
        total.income = total.income + group.income
        total.cost = total.cost + group.cost
        total.unknown = total.unknown + group.unknown
    end
    total.profit = total.income - total.cost

    return { methods = methods, total = total }
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function MethodProfit:OnEnable()
    pcall(self.Prune, self)

    -- A new visit starts a new baseline for the buyback list.
    ns.RegisterEvent(self, "MERCHANT_CLOSED", function()
        MethodProfit.buybackSeen = nil
    end)
end
