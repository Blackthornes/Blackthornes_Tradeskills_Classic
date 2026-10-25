-- Blackthornes Tradeskills -- Data/Vendor.lua
-- What a vendor will sell you, and for how much.
--
-- On a Classic-era realm this matters more than it looks. Thread, vials, and
-- similar reagents cost a few copper from any trade goods vendor, and people
-- routinely list them on the auction house for many times that. Pricing those
-- reagents from auction data alone either inflates the craft cost or, when
-- nothing is listed at all, marks the recipe unpriceable and hides it.
--
-- Prices are learned by watching merchants, and until a merchant has been seen
-- selling something, Data/VendorPrices.lua says what Classic's vendors charge
-- for it. A player who has never stood at a trade goods vendor still gets vials
-- and thread costed at the shop price instead of the auction house's (a player's
-- report, 2026-10-02). What a merchant is seen charging always wins.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Vendor = ns.NewModule("Vendor")

local Util = ns.Util

--------------------------------------------------------------------------------
-- Storage
--------------------------------------------------------------------------------

-- Vendor prices are fixed and identical everywhere, so this is account-wide
-- rather than per realm.
function Vendor:GetTable()
    if not ns.db then return {} end

    ns.db.vendorPrices = ns.db.vendorPrices or {}
    return ns.db.vendorPrices
end

--- Copper for one unit, or nil if no vendor sells it.
function Vendor:GetUnitPrice(itemID)
    local record = self:GetTable()[itemID]
    if not record then
        return ns.VENDOR_PRICES and ns.VENDOR_PRICES[itemID] or nil
    end

    -- Items bought with honour, tokens or similar are not purchasable with
    -- gold, so they have no meaningful cash price.
    if record.extendedCost then return nil end

    return record.price
end

function Vendor:IsLimited(itemID)
    local record = self:GetTable()[itemID]
    return record ~= nil and record.limited == true
end

--- True when a vendor sells this for gold without a stock limit, so it is
--- never worth sending the player to the auction house for it (the owner,
--- 2026-10-13: Red Dye was offered there). Only what the addon knows: a
--- price seen at a merchant, or the shipped table, which holds only items
--- most vendors sell without a limit. "Offer the auction house for vendor
--- items" (`vendorItemsOnAuction`, off unless ticked) turns this off, and
--- the cheaper of the two wins again.
function Vendor:KeepsInStock(itemID)
    if ns.Config and ns.Config.Get and ns.Config:Get("vendorItemsOnAuction") == true then
        return false
    end
    -- Nor one the player set to Buy on the Level Up tab.
    if ns.Cost and ns.Cost.SkipsVendor and ns.Cost:SkipsVendor(itemID) then
        return false
    end
    return self:GetUnitPrice(itemID) ~= nil and not self:IsLimited(itemID)
end

function Vendor:Count()
    return Util.Count(self:GetTable())
end

--------------------------------------------------------------------------------
-- What a vendor really pays
--------------------------------------------------------------------------------

-- Forever's vendors pay less than the game's own item data says for some
-- items, and on charged items neither the item info nor the tooltip shows
-- it: Minor Wizard Oil reads 5s and a vendor pays 1s (a player's report,
-- 2026-10-09), which put a 1s "flip" on the Deals tab that lost 3s. So what
-- a vendor actually paid, read off the merchant's buyback list after a sale,
-- beats everything else. Until one is sold, this short list of payouts seen
-- on Forever stands in, in copper for one.
ns.FOREVER_SELL_PRICES = {
    [20744] = 100, -- Minor Wizard Oil (item data says 5s)
}

-- Account wide, like the shop prices: [itemID] = { pay = copper for one, at = time() }.
function Vendor:GetPaidTable()
    if not ns.db then return {} end

    ns.db.vendorPaid = ns.db.vendorPaid or {}
    return ns.db.vendorPaid
end

--- What a vendor pays for one, as seen on Forever, or nil when nobody has
--- seen one sold.
-- @return copper, and "sold" (a sale of yours) or "reported" (the list above)
function Vendor:GetPaid(itemID)
    if not itemID then return nil end

    local record = self:GetPaidTable()[itemID]
    if type(record) == "table" and type(record.pay) == "number" then
        return record.pay, "sold"
    end

    local reported = ns.FOREVER_SELL_PRICES[itemID]
    if reported then return reported, "reported" end

    return nil
end

local function BuybackItemID(index)
    if Util.HasFunction("C_MerchantFrame.GetBuybackItemID") then
        local ok, itemID = pcall(C_MerchantFrame.GetBuybackItemID, index)
        if ok and type(itemID) == "number" and itemID > 0 then return itemID end
    end

    if Util.HasFunction("GetBuybackItemLink") then
        local ok, link = pcall(GetBuybackItemLink, index)
        if ok and type(link) == "string" then return tonumber(link:match("item:(%d+)")) end
    end

    return nil
end

--- Read what the merchant paid for everything on the buyback list. The
--- price there is for the whole stack sold.
-- @return how many payouts were new or changed
function Vendor:ReadBuyback()
    if not Util.HasFunction("GetNumBuybackItems") or not Util.HasFunction("GetBuybackItemInfo") then
        return 0
    end

    local ok, count = pcall(GetNumBuybackItems)
    if not ok or type(count) ~= "number" then return 0 end

    local paid, changed = self:GetPaidTable(), 0
    local sales = {}

    for index = 1, count do
        local itemID = BuybackItemID(index)
        local read, _, _, price, quantity = pcall(GetBuybackItemInfo, index)

        -- Inside a pcall too: a value the client keeps secret raises when
        -- compared.
        local fine, pay = pcall(function()
            if itemID and read and type(price) == "number" and type(quantity) == "number"
                    and quantity > 0 and price >= 0 then
                return math.floor(price / quantity)
            end
        end)

        if fine and pay then
            local record = paid[itemID]
            if type(record) ~= "table" or record.pay ~= pay then
                changed = changed + 1
            end
            paid[itemID] = { pay = pay, at = time() }
            sales[#sales + 1] = { itemID = itemID, quantity = quantity, price = price }
        end
    end

    -- What is new on the list was just sold: the Sales tab's Profit by method.
    if ns.MethodProfit then pcall(ns.MethodProfit.NoteBuyback, ns.MethodProfit, sales) end

    if changed > 0 then
        ns.Debug(("learned what a vendor pays for %d item(s)"):format(changed))
        -- Lists that read vendor prices rebuild when the item facts change.
        if ns.Disenchant then
            ns.Disenchant.factsVersion = (ns.Disenchant.factsVersion or 0) + 1
        end
        if ns.UI and ns.UI.RefreshActiveTab then ns.UI:RefreshActiveTab() end
    end

    return changed
end

--------------------------------------------------------------------------------
-- Reading a merchant
--------------------------------------------------------------------------------

--- Resolve the item behind a merchant slot.
--
-- C_MerchantFrame.GetItemInfo does not carry an item ID on this client, so the
-- link is the reliable source. Name lookup is a last resort, since it only
-- works for items already cached.
local function GetMerchantItemID(index, info)
    if info and info.itemID then return info.itemID, "info" end

    if Util.HasFunction("GetMerchantItemLink") then
        local ok, link = pcall(GetMerchantItemLink, index)
        if ok and link then
            local itemID = tonumber(link:match("item:(%d+)"))
            if itemID then return itemID, "link" end
        end
    end

    if info and info.name and Util.HasFunction("C_Item.GetItemInfoInstant") then
        local ok, itemID = pcall(C_Item.GetItemInfoInstant, info.name)
        if ok and itemID then return itemID, "name" end
    end

    return nil, "unresolved"
end

-- Era has no C_MerchantFrame.GetItemInfo, only the classic call, whose
-- returns are laid into the same shape here.
local function MerchantItemInfo(index)
    if Util.HasFunction("C_MerchantFrame.GetItemInfo") then
        local ok, info = pcall(C_MerchantFrame.GetItemInfo, index)
        if ok and type(info) == "table" then return info end
    end
    if Util.HasFunction("GetMerchantItemInfo") then
        local ok, name, _, price, stackCount, numAvailable, _, _, extendedCost =
            pcall(GetMerchantItemInfo, index)
        if ok and name then
            return { name = name, price = price, stackCount = stackCount,
                numAvailable = numAvailable, hasExtendedCost = extendedCost }
        end
    end
    return nil
end
Vendor.MerchantItemInfo = MerchantItemInfo

function Vendor:Scan()
    if not (Util.HasFunction("C_MerchantFrame.GetItemInfo") or Util.HasFunction("GetMerchantItemInfo")) then
        return 0
    end

    -- Rebuilt every scan: merchant slot indices are only valid for the vendor
    -- currently open.
    self.merchantItems = {}

    local countOk, numItems
    if Util.HasFunction("GetMerchantNumItems") then
        countOk, numItems = pcall(GetMerchantNumItems)
    end

    if not countOk or not numItems or numItems == 0 then
        ns.Debug("could not read what this vendor sells")
        return 0
    end

    local prices = self:GetTable()
    local learned, unresolved = 0, 0

    for index = 1, numItems do
        local info = MerchantItemInfo(index)

        if info and type(info.price) == "number" and info.price > 0 then
            local itemID, method = GetMerchantItemID(index, info)

            if itemID then
                -- Vendors sell in stacks; we want the price of one unit.
                local stack = math.max(1, info.stackCount or 1)

                local record = {
                    price = math.floor(info.price / stack),
                    stack = stack,
                    -- numAvailable is -1 for unlimited stock. A limited item
                    -- cannot be relied on for bulk crafting.
                    limited = (info.numAvailable or -1) >= 0,
                    extendedCost = info.hasExtendedCost == true,
                    seenAt = time(),
                    method = method,
                }
                -- Learned means changed: every buy and sale at a vendor
                -- scans it again, and reading the same prices back is not
                -- news worth throwing the cost index away for.
                local was = prices[itemID]
                if type(was) ~= "table" or was.price ~= record.price or was.stack ~= record.stack
                    or was.limited ~= record.limited or was.extendedCost ~= record.extendedCost then
                    learned = learned + 1
                end
                prices[itemID] = record

                self.merchantItems[itemID] = {
                    index = index,
                    price = math.floor(info.price / stack),
                    -- What one click actually costs. The unit price above is
                    -- floored, so a bundle of 5 for 1s read as 20c each and 3
                    -- of them as 60c, when the vendor charges the whole 1s.
                    bundlePrice = info.price,
                    stack = stack,
                    numAvailable = info.numAvailable or -1,
                    extendedCost = info.hasExtendedCost == true,
                }
            else
                unresolved = unresolved + 1
            end
        end
    end

    if learned > 0 then
        ns.Debug(("learned %d vendor price(s), %d could not be read"):format(learned, unresolved))

        ns.Cost:InvalidateIndex()
        if ns.UI then ns.UI:RefreshActiveTab() end
    end

    -- Where this vendor stands and what it sells, for the vendor map pins.
    if ns.VendorPins then pcall(ns.VendorPins.Learn, ns.VendorPins, self.merchantItems) end

    self.lastUnresolved = unresolved
    return learned
end

--------------------------------------------------------------------------------
-- Buying what the queue needs
--------------------------------------------------------------------------------

Vendor.isMerchantOpen = false

function Vendor:CanBuy()
    if not self.isMerchantOpen then
        return false, L["no vendor is open"]
    end
    if not Util.HasFunction("BuyMerchantItem") then
        return false, L["Buying doesn't work here."]
    end
    return true
end

--- Is this material cheaper on the auction house than at this vendor, with
--- enough listed there to cover what is short?
--
-- The auction price is the cheapest posting from someone else at the last
-- look, leaving out a lone low one. Only what was actually listed counts:
-- with nothing up, the market value is no price anyone can buy at, and the
-- vendor is the only place to get it. A tie goes to the vendor, which is a
-- sure purchase.
--
-- The cheapest posting can be a few units in front of a shelf of dearer
-- ones, so the market value, the going price across the cheaper part of
-- what is listed, has to be under the vendor price as well. Going by the
-- cheapest alone, 3 thread at 8c and the rest at 15c sent all 20 that were
-- short to the auction house, against 10c each here.
--
-- The player's own listings are left out of both the price and the count.
-- Counted, his own auction was "the cheaper one" and the vendor buy was
-- skipped when nobody else had any cheaper.
local function CheaperAtAuction(itemID, stock, shortfall)
    -- A shop that never runs out is where it is bought, whatever is listed.
    if stock.numAvailable < 0 and not stock.extendedCost and Vendor:KeepsInStock(itemID) then
        return false
    end

    local Prices = ns.Prices
    if not Prices or not Prices.Get then return false end

    local record = Prices:Get(itemID)
    if type(record) ~= "table" then return false end

    -- A book read with no owners (rivalMin, ownMin and a lone low all unset)
    -- still has its cheapest listing as a rival price.
    local auction = record.rivalMin
    if not auction and not record.ownMin and not record.ignoredLow then auction = record.min end
    if not auction or auction <= 0 then return false end

    local own = 0
    if ns.Auctions and ns.Auctions.GetPostedCount then
        local ok, count = pcall(ns.Auctions.GetPostedCount, ns.Auctions, itemID)
        own = ok and tonumber(count) or 0
    end
    if (record.quantity or 0) - own < shortfall then return false end

    -- What one really costs here. A bundle's stored unit price is floored,
    -- so it is worked out from the bundle price instead.
    local vendorUnit = stock.price
    if stock.stack and stock.stack > 1 and stock.bundlePrice then
        vendorUnit = stock.bundlePrice / stock.stack
    end

    if record.market and record.market >= vendorUnit then return false end

    return auction < vendorUnit
end

--- Queue shortfalls that this vendor can actually supply, where it is the
--- cheaper place to buy them.
-- @return lines, totalCost, how many were left for the auction house because
--   they are cheaper there
function Vendor:GetNeeded()
    local lines, total, cheaperElsewhere = {}, 0, 0

    if not self.isMerchantOpen or not self.merchantItems then
        return lines, 0, 0
    end

    for _, line in ipairs(ns.Queue:GetShoppingList()) do
        local stock = self.merchantItems[line.itemID]

        -- Items bought with tokens or honour cannot be paid for in gold.
        local buyable = line.shortfall > 0 and stock and not stock.extendedCost

        if buyable and CheaperAtAuction(line.itemID, stock, line.shortfall) then
            cheaperElsewhere = cheaperElsewhere + 1
        elseif buyable then
            local affordable = line.shortfall

            -- Limited stock: never ask for more than the vendor has.
            if stock.numAvailable >= 0 then
                affordable = math.min(affordable, stock.numAvailable * stock.stack)
            end
            local limited = affordable < line.shortfall

            if affordable > 0 then
                local cost = affordable * stock.price
                if stock.stack > 1 and stock.bundlePrice then
                    cost = math.ceil(affordable / stock.stack) * stock.bundlePrice
                end

                lines[#lines + 1] = {
                    itemID = line.itemID,
                    index = stock.index,
                    amount = affordable,
                    unitPrice = stock.price,
                    cost = cost,
                    stack = stock.stack,
                    bundlePrice = stock.bundlePrice,
                    short = limited,
                }

                total = total + cost
            end
        end
    end

    return lines, total, cheaperElsewhere
end

--- How many are in the bags right now, read fresh.
local function BagCount(itemID)
    local Inventory = ns.Inventory
    if not (Inventory and Inventory.GetBagCount) then return 0 end
    if Inventory.InvalidateBagCounts then Inventory:InvalidateBagCounts() end
    local ok, count = pcall(Inventory.GetBagCount, Inventory, itemID)
    return ok and tonumber(count) or 0
end

--- Buy everything the queue needs from the open vendor.
--
-- Purchases are chunked and re-checked against your actual bags between each
-- one, rather than fired blindly in a loop: if a purchase silently fails, or
-- you already had more than expected, this stops instead of over-buying.
function Vendor:BuyNeeded()
    local allowed, reason = self:CanBuy()
    if not allowed then
        ns.Print(reason)
        return false
    end

    if self.buying then
        ns.Print(L["already buying"])
        return false
    end

    local lines, total, cheaperElsewhere = self:GetNeeded()
    if #lines == 0 then
        if cheaperElsewhere > 0 then
            ns.Print(L["the auction house has it all for less."])
        else
            ns.Print(L["this vendor has nothing your queue needs."])
        end
        return false
    end

    local moneyOk, money = pcall(GetMoney)
    if moneyOk and money and money < total then
        ns.Warn(L.Format("that would cost %s and you have %s",
            Util.FormatMoney(total), Util.FormatMoney(money)))
        return false
    end

    self.buying = true
    self.buyIndex = 1
    self.buySpent = 0
    self.buyLines = lines
    self.buySteps = 0
    self.buyPurchased = {}
    self.settling = nil

    -- What the bags held before, so the end of the run can tell when the
    -- purchases have actually arrived (see FinishBuying).
    self.buyStartBags = {}
    for _, line in ipairs(lines) do
        self.buyStartBags[line.itemID] = BagCount(line.itemID)
    end

    ns.Print(L.Format("buying %d material(s) for %s...", #lines, Util.FormatMoney(total)))

    self:BuyStep()
    return true
end

-- How long the button waits for bought items to show up in the bags before
-- it is drawn from whatever the bags say.
local SETTLE_SECONDS = 3

-- A hard ceiling on purchase calls, so a miscount can never spend
-- unbounded gold in a runaway loop.
local MAX_BUY_STEPS = 60

function Vendor:BuyStep()
    if not self.buying then return end

    self.buySteps = self.buySteps + 1
    if self.buySteps > MAX_BUY_STEPS then
        ns.Warn(L["stopped after a lot of buys. Click again for more."])
        self:FinishBuying()
        return
    end

    local line = self.buyLines[self.buyIndex]
    if not line then
        self:FinishBuying()
        return
    end

    -- How much of this item this run has already bought.
    --
    -- This tally, not the live bag count, is what stops the purchase. Bag
    -- updates are asynchronous: checking GetItemCount a fraction of a second
    -- after buying can still return the pre-purchase number, and deciding from
    -- that buys the same item twice.
    local purchased = self.buyPurchased[line.itemID] or 0
    local remaining = line.amount - purchased

    -- Live shortfall is still consulted, but only ever to buy LESS. If bag
    -- counts have caught up and show the need already met, stop early; if they
    -- lag, the tally above has already capped us.
    local liveShortfall
    for _, current in ipairs(ns.Queue:GetShoppingList()) do
        if current.itemID == line.itemID then
            liveShortfall = current.shortfall
            break
        end
    end

    if liveShortfall then
        remaining = math.min(remaining, liveShortfall)
    end

    if remaining <= 0 then
        self.buyIndex = self.buyIndex + 1
        C_Timer.After(0.1, function() Vendor:BuyStep() end)
        return
    end

    -- One merchant stack per call is the reliable maximum. An item sold one
    -- at a time (thread, vials) can still be bought a bag stack at once, up to
    -- what the merchant says one purchase may hold; one per click turned a
    -- queue needing 40 thread into 40 purchases and hit the stop below.
    local perCall = math.max(1, line.stack)
    if perCall == 1 and Util.HasFunction("GetMerchantItemMaxStack") then
        local ok, most = pcall(GetMerchantItemMaxStack, line.index)
        if ok and type(most) == "number" and most > 1 then perCall = most end
    end
    local amount = math.min(remaining, perCall)

    local ok = pcall(BuyMerchantItem, line.index, amount)
    if not ok then
        ns.Warn(L.Format("could not buy %s", Util.GetItemLabel(line.itemID)))
        self.buyIndex = self.buyIndex + 1
    else
        self.buyPurchased[line.itemID] = purchased + amount
        -- By the bundle where the vendor sells in bundles: the unit price is
        -- floored, and "about 60c spent" for 3 of a 5-for-1s bundle was 1s.
        if line.stack and line.stack > 1 and line.bundlePrice then
            self.buySpent = self.buySpent + math.ceil(amount / line.stack) * line.bundlePrice
        else
            self.buySpent = self.buySpent + (amount * line.unitPrice)
        end
    end

    -- Long enough for BAG_UPDATE to land, so the live check above is meaningful
    -- rather than always reading stale counts.
    C_Timer.After(0.35, function() Vendor:BuyStep() end)
end

function Vendor:FinishBuying()
    if not self.buying then return end

    -- The last purchase is often still on its way to the bags when the run
    -- ends. Redrawn now, the button read the old counts and came back as
    -- "Buy materials 1s 8c" for the 12 thread just bought, and nothing
    -- redrew it once they landed (2026-10-03). So it stays on
    -- "Buying..." until the bags hold what was bought, checked again on
    -- every bag update, or until SETTLE_SECONDS have passed.
    local waiting
    for itemID, amount in pairs(self.buyPurchased or {}) do
        if amount > 0 then
            waiting = waiting or {}
            waiting[itemID] = ((self.buyStartBags or {})[itemID] or 0) + amount
        end
    end

    self.buying = false
    self.buyLines = nil
    self.buyPurchased = nil
    self.buyStartBags = nil
    self.settling = waiting

    ns.Print(L.Format("done buying (about %s spent)", Util.FormatMoney(self.buySpent or 0)))

    if waiting then
        -- A purchase the game turned down (bags full) never arrives, so the
        -- wait has an end. The token keeps an old run's timer off a new one.
        local token = {}
        self.settleToken = token
        C_Timer.After(SETTLE_SECONDS, function()
            if Vendor.settleToken == token and Vendor.settling then
                Vendor.settling = nil
                Vendor:Redraw()
            end
        end)
        -- Already there when the bags were quick; otherwise "Buying..." holds.
        self:CheckSettled()
        if self.settling and ns.UI then ns.UI:UpdateMerchantButton() end
        return
    end

    self:Redraw()
end

--- The button and the open tab, after the bags changed under them.
function Vendor:Redraw()
    if ns.UI then
        ns.UI:UpdateMerchantButton()
        ns.UI:RefreshActiveTab()
    end
end

--- Have the purchases from the last run reached the bags? Once they all
--- have, the button is drawn from the new counts.
function Vendor:CheckSettled()
    if not self.settling then return end

    for itemID, target in pairs(self.settling) do
        if BagCount(itemID) >= target then
            self.settling[itemID] = nil
        end
    end

    if next(self.settling) == nil then
        self.settling = nil
        self:Redraw()
    end
end

--- Buying, or waiting for what was just bought to reach the bags.
function Vendor:IsBuying()
    return self.buying == true or self.settling ~= nil
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function Vendor:OnEnable()
    ns.RegisterEvent(self, "MERCHANT_SHOW", function()
        Vendor.isMerchantOpen = true

        -- The merchant list is not always populated on the event itself.
        -- A vendor closed inside the wait has nothing left to read, and
        -- attaching then left the button floating where the window had been.
        C_Timer.After(0.2, function()
            if not Vendor.isMerchantOpen then return end
            Vendor:Scan()
            pcall(Vendor.ReadBuyback, Vendor)
            if ns.UI then ns.UI:AttachToMerchant() end
        end)
    end)

    -- These come one a stack bought or sold, so a run of buys is a run of
    -- them; one read a moment after the last, not one each.
    ns.RegisterEvent(self, "MERCHANT_UPDATE", function()
        if Vendor.updateTimer then return end
        Vendor.updateTimer = C_Timer.NewTimer(0.2, function()
            Vendor.updateTimer = nil
            if not Vendor.isMerchantOpen then return end
            Vendor:Scan()
            -- Selling something puts it on the buyback list.
            pcall(Vendor.ReadBuyback, Vendor)
            if ns.UI then ns.UI:UpdateMerchantButton() end
        end)
    end)

    -- Bags changed at the vendor: things just bought arriving, or bought
    -- by hand, or moved. The button only redrew on vendor events, so it
    -- kept offering what the bags already held.
    ns.RegisterEvent(self, "BAG_UPDATE_DELAYED", function()
        if not Vendor.isMerchantOpen or Vendor.buying then return end
        -- Something sold leaves the bags; the buyback list says for how much.
        pcall(Vendor.ReadBuyback, Vendor)
        if Vendor.settling then
            Vendor:CheckSettled()
        elseif ns.UI then
            if ns.Inventory and ns.Inventory.InvalidateBagCounts then
                ns.Inventory:InvalidateBagCounts()
            end
            ns.UI:UpdateMerchantButton()
        end
    end)

    ns.RegisterEvent(self, "MERCHANT_CLOSED", function()
        Vendor.isMerchantOpen = false
        Vendor.merchantItems = nil

        -- Walking away mid-purchase must not leave a timer buying things.
        if Vendor.buying then Vendor:FinishBuying() end
        Vendor.settling = nil

        if ns.UI and ns.UI.merchantButton then
            ns.UI.merchantButton:Hide()
        end
    end)
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

ns.RegisterCommand("vendor", L["show learned vendor prices"], function()
    local count = ns.Vendor:Count()

    if count == 0 then
        ns.Print(L["no vendor prices learned yet. Open a trade goods vendor once"])
        return
    end

    ns.Print(L.Format("%d vendor price(s) learned", count))

    local shown = 0
    for itemID, record in pairs(ns.Vendor:GetTable()) do
        if shown < 15 then
            ns.PrintRaw(("  %s  %s%s"):format(
                Util.GetItemLabel(itemID),
                Util.FormatMoney(record.price),
                record.limited and ("  |cff7a8089" .. L["(limited stock)"] .. "|r") or ""))
            shown = shown + 1
        end
    end
end)
