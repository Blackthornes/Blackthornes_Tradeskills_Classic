-- Blackthornes Tradeskills -- Logic/AHBuys.lua
-- What you bought on the auction house and have not taken from the mail yet.
--
-- A purchase goes to the mailbox, not the bags. The shopping list counts bags
-- and bank, so the twenty Linen you just bought still read "need 20" until you
-- walked to a mailbox, and the buy quantity box offered to buy them again.
-- Each purchase is kept here, per character, until it is taken from the mail.
--
-- Everything is read from the client, never assumed: the quantity is the one
-- handed to the purchase call (a commodity's ConfirmCommoditiesPurchase, or the
-- listing a buyout was placed on), it only counts once the client says it went
-- through (the purchase event, or the gold leaving), and it stops counting when
-- the attachment is taken or a reading of the mailbox no longer shows it.
--
-- Nothing here touches a Blizzard frame. The calls are watched with
-- hooksecurefunc, which runs after Blizzard's own and changes nothing.

local _, ns = ...

local AHBuys = ns.NewModule("AHBuys")

local Util = ns.Util

-- Seconds a purchase may still be on its way to the mailbox. A reading of the
-- mailbox sooner than this that does not show it yet leaves it alone.
AHBuys.GRACE = 300

-- Auction mail is kept 30 days. Anything older is gone, whatever happened.
AHBuys.MAX_AGE = 30 * 24 * 3600

-- A purchase that has not been confirmed by now never went through.
AHBuys.CONFIRM_WINDOW = 30

-- Enough for a long shopping trip, small enough for the saved data.
AHBuys.MAX_KEPT = 100

-- What each purchase cost, against what the shopping list had estimated for
-- it (a player asked, the owner agreeing 2026-10-11). Kept a week, and the
-- shopping list shows the last day's.
AHBuys.PAID_MAX_AGE = 7 * 24 * 3600
AHBuys.PAID_SHOWN = 24 * 3600

-- Paying more than this times the estimate is flagged in amber.
AHBuys.OVERPAID = 1.25

-- Seconds after a purchase in which gold leaving is still its price.
AHBuys.SETTLE_WINDOW = 10

--------------------------------------------------------------------------------
-- Storage
--------------------------------------------------------------------------------

--- This character's purchases, oldest first: { {itemID, quantity, at}, ... }.
-- Per character, because the mail goes to the one who bought.
function AHBuys:GetList(create)
    local record = ns.Recipes and ns.Recipes.GetCharacterRecord
        and ns.Recipes:GetCharacterRecord(create)
    if not record then return nil end
    if create and type(record.ahBuys) ~= "table" then record.ahBuys = {} end
    return type(record.ahBuys) == "table" and record.ahBuys or nil
end

local function Now() return time() end

--- This character's purchase prices, oldest first:
--- { {itemID, quantity, paid, estimate, at}, ... }. paid is nil when the
--- client never said; estimate is nil when the item had no price.
function AHBuys:GetPaidList(create)
    local record = ns.Recipes and ns.Recipes.GetCharacterRecord
        and ns.Recipes:GetCharacterRecord(create)
    if not record then return nil end
    if create and type(record.ahPaid) ~= "table" then record.ahPaid = {} end
    return type(record.ahPaid) == "table" and record.ahPaid or nil
end

--- Drop what is too old to be in the mail any more, and anything unreadable.
function AHBuys:Prune(list)
    list = list or self:GetList(false)
    local now = Now()
    if list then
        for i = #list, 1, -1 do
            local buy = list[i]
            if type(buy) ~= "table" or not tonumber(buy.itemID) or (tonumber(buy.quantity) or 0) <= 0
                or now - (tonumber(buy.at) or 0) > self.MAX_AGE then
                table.remove(list, i)
            end
        end
        while #list > self.MAX_KEPT do table.remove(list, 1) end
    end

    local paid = self:GetPaidList(false)
    if paid then
        for i = #paid, 1, -1 do
            local buy = paid[i]
            if type(buy) ~= "table" or not tonumber(buy.itemID) or (tonumber(buy.quantity) or 0) <= 0
                or now - (tonumber(buy.at) or 0) > self.PAID_MAX_AGE then
                table.remove(paid, i)
            end
        end
        while #paid > self.MAX_KEPT do table.remove(paid, 1) end
    end
end

--- Units of an item bought on the auction house at or after `at`: listings
--- a scan from then still shows, though they are gone.
function AHBuys:BoughtSince(itemID, at)
    local list = self:GetPaidList(false)
    if not list or not itemID or not at then return 0 end
    local total = 0
    for _, buy in ipairs(list) do
        if buy.itemID == itemID and (tonumber(buy.at) or 0) >= at then
            total = total + (tonumber(buy.quantity) or 0)
        end
    end
    return total
end

--- What the last day's purchases of an item cost, newest first, until they
--- cover `units`.
-- @return paid, paidUnits, estimate (estimate nil when any of them had none),
--   or nil when none were bought with a price the client gave
function AHBuys:PaidFor(itemID, units)
    local list = self:GetPaidList(false)
    if not list or not itemID then return nil end
    local since = Now() - self.PAID_SHOWN
    local paid, count, estimate = 0, 0, 0
    for i = #list, 1, -1 do
        local buy = list[i]
        if count >= (units or math.huge) then break end
        if buy.itemID == itemID and (tonumber(buy.at) or 0) >= since and tonumber(buy.paid) then
            paid = paid + buy.paid
            count = count + (tonumber(buy.quantity) or 0)
            estimate = estimate and tonumber(buy.estimate) and (estimate + buy.estimate) or nil
        end
    end
    if count <= 0 then return nil end
    return paid, count, estimate
end

--- Paid more than OVERPAID times the estimate?
function AHBuys.Overpaid(paid, estimate)
    return paid ~= nil and estimate ~= nil and estimate > 0 and paid > estimate * AHBuys.OVERPAID
end

--- Units of an item bought and not yet taken from the mail.
-- Honours "count mail as stock", like every other mail count.
function AHBuys:GetPending(itemID)
    if not itemID then return 0 end
    if ns.Config and ns.Config:Get("countMailAsStock") == false then return 0 end
    local list = self:GetList(false)
    if not list then return 0 end
    local total = 0
    for _, buy in ipairs(list) do
        if buy.itemID == itemID then total = total + (tonumber(buy.quantity) or 0) end
    end
    return total
end

--- Units bought since the mailbox was last read: the ones a mail count
--- cannot include yet. What came before is in the reading, or was trimmed.
function AHBuys:GetUnread(itemID)
    if not itemID then return 0 end
    if ns.Config and ns.Config:Get("countMailAsStock") == false then return 0 end
    local list = self:GetList(false)
    if not list then return 0 end
    local record = ns.Recipes:GetCharacterRecord(false)
    local readAt = record and tonumber(record.mailAt) or 0
    local total = 0
    for _, buy in ipairs(list) do
        if buy.itemID == itemID and (tonumber(buy.at) or 0) > readAt then
            total = total + (tonumber(buy.quantity) or 0)
        end
    end
    return total
end

local function Changed()
    if ns.UI then
        if ns.UI.OnInventoryUpdated then
            pcall(ns.UI.OnInventoryUpdated, ns.UI)
        elseif ns.UI.RefreshActiveTab then
            pcall(ns.UI.RefreshActiveTab, ns.UI)
        end
    end
end

--- Put a purchase down.
function AHBuys:Record(itemID, quantity)
    itemID, quantity = tonumber(itemID), tonumber(quantity)
    if not itemID or not quantity or quantity <= 0 then return end
    local list = self:GetList(true)
    if not list then return end
    list[#list + 1] = { itemID = itemID, quantity = quantity, at = Now() }
    self:Prune(list)
    ns.Debug(("auction buy: %d x %d, waiting in the mail"):format(quantity, itemID))
    Changed()
end

--- Take units off an item's purchases, oldest first.
function AHBuys:Remove(itemID, quantity, list)
    list = list or self:GetList(false)
    if not list or not itemID then return 0 end
    local left = tonumber(quantity) or 0
    local removed = 0
    for i = 1, #list do
        if left <= 0 then break end
        local buy = list[i]
        if buy and buy.itemID == itemID then
            local take = math.min(left, buy.quantity)
            buy.quantity = buy.quantity - take
            left, removed = left - take, removed + take
        end
    end
    for i = #list, 1, -1 do
        if (list[i].quantity or 0) <= 0 then table.remove(list, i) end
    end
    return removed
end

--------------------------------------------------------------------------------
-- Buying
--------------------------------------------------------------------------------

-- The purchase the client was asked for and has not answered yet.
-- { itemID, quantity, at, auctionID }
AHBuys.awaiting = nil

--- What the shopping list would have said these units cost, before the
--- player looked them up (Prices:CostBeforeLook): the vendor's price for
--- what a vendor sells, else up the auction listings.
function AHBuys:Estimate(itemID, quantity)
    local vendor = ns.Vendor and ns.Vendor.GetUnitPrice and ns.Vendor:GetUnitPrice(itemID)
    local auction
    if ns.Prices and ns.Prices.CostBeforeLook then
        local ok, cost = pcall(ns.Prices.CostBeforeLook, ns.Prices, itemID, quantity,
            function(seen) return AHBuys:BoughtSince(itemID, seen) end)
        auction = ok and tonumber(cost) or nil
    end
    if vendor and (not auction or vendor * quantity <= auction) then return vendor * quantity end
    return auction
end

-- The price the auction house last quoted for a commodity purchase:
-- { itemID, quantity, total, at }.
AHBuys.quote = nil

function AHBuys:OnStartCommodities(itemID, quantity)
    self.quote = { itemID = tonumber(itemID), quantity = tonumber(quantity), at = Now() }
end

function AHBuys:OnPriceUpdated(unitPrice, totalPrice)
    local quote = self.quote
    if quote and Now() - quote.at <= self.CONFIRM_WINDOW then quote.total = tonumber(totalPrice) end
end

function AHBuys:Await(itemID, quantity, auctionID, price)
    itemID, quantity = tonumber(itemID), tonumber(quantity)
    if not itemID or not quantity or quantity <= 0 then return end

    -- A commodity's total comes from the quote for this item and count.
    local quoted
    local quote = self.quote
    if not price and quote and quote.itemID == itemID and quote.quantity == quantity
        and Now() - quote.at <= self.CONFIRM_WINDOW then
        quoted = quote.total
    end

    -- The last purchase's gold has left by now, or its price stays as given.
    self.settling = nil
    self.awaiting = { itemID = itemID, quantity = quantity, at = Now(),
        auctionID = auctionID, money = self:Money(), price = tonumber(price),
        quoted = quoted, estimate = self:Estimate(itemID, quantity) }
end

--- Write down what a purchase cost. The gold that left is the surest
--- figure; the buyout or the quote stand in until it does, and a purchase
--- confirmed before the gold leaves is settled when it does (OnMoney).
function AHBuys:NotePaid(wait)
    local list = self:GetPaidList(true)
    if not list then return end
    local entry = { itemID = wait.itemID, quantity = wait.quantity, at = Now(),
        estimate = wait.estimate, paid = wait.price or wait.quoted }
    list[#list + 1] = entry

    local money = wait.money and self:Money()
    if money and wait.money - money > 0 then
        entry.paid = wait.money - money
    elseif wait.money then
        self.settling = { entry = entry, money = wait.money, at = Now() }
    end

    -- A cost to measure a later sale or disenchant against. One still
    -- waiting for the gold to leave is written down when it does.
    if not self.settling or self.settling.entry ~= entry then
        self:NoteCost(entry)
    end
end

function AHBuys:NoteCost(entry)
    if ns.MethodProfit then
        pcall(ns.MethodProfit.NoteBought, ns.MethodProfit, entry.itemID, entry.quantity, entry.paid)
    end
end

function AHBuys:Money()
    local ok, money = pcall(GetMoney)
    return ok and tonumber(money) or nil
end

--- The client said the purchase went through.
function AHBuys:Confirm(auctionID)
    local wait = self.awaiting
    if not wait then return end
    if Now() - wait.at > self.CONFIRM_WINDOW then self.awaiting = nil; return end
    -- An item purchase names its auction; another one's answer is not ours.
    if auctionID and wait.auctionID and auctionID ~= wait.auctionID then return end
    self.awaiting = nil
    self:NotePaid(wait)
    -- What was bought is off the auction house now, so the lists that offer
    -- it (Disenchanting, Deals) stop offering it at that price. Before
    -- Record, whose redraw then shows it. An item's buyout names its unit
    -- price; a commodity's buy takes the cheapest units, so none is given.
    if ns.Prices and ns.Prices.NoteBought then
        local unit = wait.price and Util.UnitPriceFromStack(wait.itemID, wait.price, wait.quantity) or nil
        local ok, changed = pcall(ns.Prices.NoteBought, ns.Prices, wait.itemID, unit, wait.quantity, wait.at)
        -- Seen again at the same price, it is another listing: read it.
        if ok and changed and ns.Scanner and ns.Scanner.ForgetPassive then
            ns.Scanner:ForgetPassive(wait.itemID)
        end
    end
    self:Record(wait.itemID, wait.quantity)
    -- Bought after a search from the Disenchanting tab: marked to disenchant.
    local buys = ns.DisenchantBuys
    if buys and buys.OnBought then pcall(buys.OnBought, buys, wait.itemID, wait.quantity) end
    -- Bought from a shopping list's search: its results look again.
    local lists = ns.ShoppingListsView
    if lists and lists.OnBought then pcall(lists.OnBought, lists, wait.itemID, wait.quantity) end
end

function AHBuys:Fail()
    self.awaiting = nil
end

--- Gold leaving right after a purchase was asked for is the purchase: a
--- client that sends no purchase event still pays.
function AHBuys:OnMoney()
    local settling = self.settling
    if settling then
        self.settling = nil
        local money = self:Money()
        if money and settling.money - money > 0 and Now() - settling.at <= self.SETTLE_WINDOW then
            settling.entry.paid = settling.money - money
            Changed()
        end
        self:NoteCost(settling.entry)
    end

    local wait = self.awaiting
    if not wait or not wait.money then return end
    local money = self:Money()
    -- Less than the buyout leaving (a deposit, a repair) is not the buy.
    if money and wait.money - money >= (wait.price or 1) then self:Confirm(wait.auctionID) end
end

--- A commodity: the item and how many are named in the call itself.
function AHBuys:OnConfirmCommodities(itemID, quantity)
    self:Await(itemID, quantity)
end

-- The last item search shown, so a buyout can be matched to its listing.
AHBuys.lastItemKey = nil

function AHBuys:OnItemResults(itemKey)
    if type(itemKey) == "table" and itemKey.itemID then self.lastItemKey = itemKey end
end

--- An item auction: PlaceBid names only the auction, so its listing is found
--- among the results shown. A bid below the buyout is not a purchase yet,
--- and only a buyout is counted.
function AHBuys:OnPlaceBid(auctionID, bidAmount)
    local key = self.lastItemKey
    local auctions = _G.C_AuctionHouse
    if not key or not auctionID or type(auctions) ~= "table" then return end
    local ok, count = pcall(auctions.GetNumItemSearchResults, key)
    if not ok or not tonumber(count) then return end
    for i = 1, count do
        local infoOk, info = pcall(auctions.GetItemSearchResultInfo, key, i)
        if infoOk and type(info) == "table" and info.auctionID == auctionID then
            local buyout = tonumber(info.buyoutAmount)
            if buyout and buyout > 0 and (tonumber(bidAmount) or 0) >= buyout then
                local itemID = (type(info.itemKey) == "table" and info.itemKey.itemID) or key.itemID
                self:Await(itemID, info.quantity or 1, auctionID, buyout)
            end
            return
        end
    end
end

--- An item auction on Era's older auction house: PlaceAuctionBid names the
--- row of the list it was placed on, which still holds it right after the
--- call. Only a buyout is counted, as above. Era's buy plan
--- (Logic/LegacyBuy.lua) and a buy in the game's own list both come here.
function AHBuys:OnLegacyBid(listType, index, bidAmount)
    if type(GetAuctionItemInfo) ~= "function" then return end
    local ok, _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID =
        pcall(GetAuctionItemInfo, listType, index)
    if not ok then return end
    if not itemID and type(GetAuctionItemLink) == "function" then
        local linkOk, link = pcall(GetAuctionItemLink, listType, index)
        itemID = linkOk and type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
    end
    buyout = tonumber(buyout)
    if itemID and buyout and buyout > 0 and (tonumber(bidAmount) or 0) >= buyout then
        self:Await(itemID, tonumber(count) or 1, nil, buyout)
    end
end

--------------------------------------------------------------------------------
-- The mailbox
--------------------------------------------------------------------------------

local wonPattern

--- Is this an auction you won? nil when the client has no subject to tell.
local function IsWon(subject)
    if wonPattern == nil then
        wonPattern = ns.Mail and ns.Mail.SubjectPattern
            and ns.Mail.SubjectPattern(_G.AUCTION_WON_MAIL_SUBJECT) or false
    end
    if not wonPattern or type(subject) ~= "string" then return nil end
    return subject:match(wonPattern) ~= nil
end

function AHBuys:ResetMatcher() wonPattern = nil end

local function Subject(index)
    if not Util.HasFunction("GetInboxHeaderInfo") then return nil end
    local ok, _, _, _, subject = pcall(GetInboxHeaderInfo, index)
    return ok and subject or nil
end

--- An attachment is being taken: what it holds is noted, and stops waiting
--- once the inbox shows it gone (SettleTakes).
-- Only a won auction's, where the client can tell; otherwise any.
--
-- The take is only asked for here. With the bags full the server refuses
-- it and the attachment stays, and striking the purchase off at the ask
-- put it back on the shopping list to be bought a second time.
function AHBuys:OnTake(index, slot)
    if not ns.Mail or not index then return end
    if IsWon(Subject(index)) == false then return end
    local list = self:GetList(false)
    if not list or #list == 0 then return end

    local first, last = slot, slot
    if not slot then
        first, last = 1, tonumber(_G.ATTACHMENTS_MAX_RECEIVE) or 16
    end

    self.takes = self.takes or {}
    for s = first, last do
        local itemID, quantity = ns.Mail:ReadAttachment(index, s)
        if itemID then
            self.takes[#self.takes + 1] = { index = index, slot = s, itemID = itemID, quantity = quantity or 1 }
        end
    end
end

--- The inbox changed: a take whose attachment has gone went through.
--- One still there as it was is waited on (a whole mail is taken one
--- attachment at a time), until the mailbox closes.
function AHBuys:SettleTakes()
    local takes = self.takes
    if not takes or #takes == 0 then return end
    local list = self:GetList(false)
    if not list then self.takes = nil return end

    local kept, removed = {}, 0
    for _, take in ipairs(takes) do
        local itemID, quantity = ns.Mail:ReadAttachment(take.index, take.slot)
        if itemID == take.itemID and (quantity or 1) == take.quantity then
            kept[#kept + 1] = take
        else
            removed = removed + self:Remove(take.itemID, take.quantity, list)
        end
    end
    self.takes = #kept > 0 and kept or nil
    if removed > 0 then Changed() end
end

--- A complete reading of the mailbox: a purchase it does not show (taken by
--- something we did not see, or returned) stops counting. One too new to
--- have arrived is left alone.
function AHBuys:Reconcile(mails, complete, more)
    if not complete or more then return end
    local list = self:GetList(false)
    if not list or #list == 0 then return end

    local shown = {}
    for _, mail in ipairs(mails or {}) do
        if IsWon(mail.subject) ~= false then
            for _, attachment in ipairs(mail.attachments or {}) do
                shown[attachment.itemID] = (shown[attachment.itemID] or 0)
                    + (attachment.quantity or 1)
            end
        end
    end

    -- Oldest first, as the mail is shown. One too young to have arrived is
    -- left alone and takes no room: room goes to what had time to arrive.
    local now, changed = Now(), false
    for _, buy in ipairs(list) do
        if now - (tonumber(buy.at) or 0) >= self.GRACE then
            local left = shown[buy.itemID] or 0
            if left < buy.quantity then
                buy.quantity, changed = left, true
            end
            shown[buy.itemID] = left - buy.quantity
        end
    end

    for i = #list, 1, -1 do
        if list[i].quantity <= 0 then table.remove(list, i) end
    end
    if changed then Changed() end
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

local function Watch(owner, name, fn)
    if type(hooksecurefunc) ~= "function" then return false end
    if owner then
        if type(owner) == "table" and type(owner[name]) == "function" then
            return pcall(hooksecurefunc, owner, name, function(...) pcall(fn, ...) end)
        end
    elseif type(_G[name]) == "function" then
        return pcall(hooksecurefunc, name, function(...) pcall(fn, ...) end)
    end
    return false
end

function AHBuys:OnEnable()
    pcall(self.Prune, self)

    local auctions = _G.C_AuctionHouse
    Watch(auctions, "StartCommoditiesPurchase", function(itemID, quantity)
        AHBuys:OnStartCommodities(itemID, quantity)
    end)
    ns.RegisterEvent(self, "COMMODITY_PRICE_UPDATED", function(_, _, unitPrice, totalPrice)
        AHBuys:OnPriceUpdated(unitPrice, totalPrice)
    end)
    Watch(auctions, "ConfirmCommoditiesPurchase", function(itemID, quantity)
        AHBuys:OnConfirmCommodities(itemID, quantity)
    end)
    Watch(auctions, "PlaceBid", function(auctionID, bidAmount)
        AHBuys:OnPlaceBid(auctionID, bidAmount)
    end)

    ns.RegisterEvent(self, "ITEM_SEARCH_RESULTS_UPDATED", function(_, _, itemKey)
        AHBuys:OnItemResults(itemKey)
    end)
    ns.RegisterEvent(self, "COMMODITY_PURCHASE_SUCCEEDED", function() AHBuys:Confirm() end)
    ns.RegisterEvent(self, "COMMODITY_PURCHASE_FAILED", function() AHBuys:Fail() end)
    -- A buyout that fails because the listing just sold says so only here;
    -- without it the ask lived on, and the next gold leaving confirmed it.
    ns.RegisterEvent(self, "AUCTION_HOUSE_SHOW_ERROR", function() AHBuys:Fail() end)
    ns.RegisterEvent(self, "MAIL_INBOX_UPDATE", function() AHBuys:SettleTakes() end)
    ns.RegisterEvent(self, "MAIL_CLOSED", function() AHBuys.takes = nil end)
    ns.RegisterEvent(self, "AUCTION_HOUSE_PURCHASE_COMPLETED", function(_, _, auctionID)
        AHBuys:Confirm(auctionID)
    end)
    ns.RegisterEvent(self, "PLAYER_MONEY", function() AHBuys:OnMoney() end)

    if type(auctions) ~= "table" then
        Watch(nil, "PlaceAuctionBid", function(listType, index, bidAmount)
            AHBuys:OnLegacyBid(listType, index, bidAmount)
        end)
    end

    Watch(nil, "TakeInboxItem", function(index, slot) AHBuys:OnTake(index, slot) end)
    Watch(nil, "AutoLootMailItem", function(index) AHBuys:OnTake(index) end)
end
