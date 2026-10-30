-- Blackthornes Tradeskills -- UI/FavorsView.lua
-- The auction house drawer's Favors view (the owner said build it,
-- 2026-10-20, from a mockup): while a favor goal is set on the Favors and
-- Writs tab, the drawer lists what the goal still needs, a crate, then the
-- bundle that fills it, for every crate (MerchantsFavor.Steps), with one
-- gold Buy Next at the foot.
--
-- One click buys one listing, never a loop. A material sold in stacks is
-- two clicks: Buy Next asks the game for the real price of that many
-- (C_AuctionHouse.StartCommoditiesPurchase), the button then shows the
-- total, and only Pay spends it (ConfirmCommoditiesPurchase). A crate is
-- sold one at a time, so Buy Next searches for it and the player buys it in
-- the game's own window. Steps count as done from the bags and bank, and
-- from what was bought this visit until it shows there.

local _, ns = ...

local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local FavorsView = ns.NewModule("FavorsView")

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local ROW_HEIGHT = 36
local ICON_SIZE = 24

-- How long Buy Next waits for the game's price, and for the buy to go
-- through, before it lets go.
FavorsView.QUOTE_WAIT = 10
FavorsView.BUY_WAIT = 15

-- C_AuctionHouse's commodity status: 1 is an item sold one at a time.
local NOT_A_STACK = 1

-- The one buy under way: { itemID, count, phase = "asking" | "quoted" |
-- "buying", total }, or nil.
FavorsView.pending = nil

-- Bought this visit, by item: { count, ownedAt }. Counted toward the steps
-- until the bags or bank show it (mail can hold it a while).
FavorsView.bought = {}

local function Money(copper)
    return Util.FormatMoney(copper or 0, { noColor = true, short = true })
end

local function Now()
    return type(GetTime) == "function" and GetTime() or 0
end

local function After(seconds, fn)
    if C_Timer and C_Timer.After then C_Timer.After(seconds, fn) end
end

local function ItemName(itemID)
    return (Util.GetItemLabel and Util.GetItemLabel(itemID)) or L["that item"]
end

local function Moved()
    FavorsView.key = nil
    if ns.PostPanel and ns.PostPanel.Refresh then ns.PostPanel:Refresh() end
end

--------------------------------------------------------------------------------
-- The steps
--------------------------------------------------------------------------------

--- What was bought this visit and is not in the bags or bank yet.
function FavorsView:Extra(itemID)
    local entry = self.bought[itemID]
    if not entry then return 0 end
    local owned = ns.MerchantsFavor.Owned(itemID)
    local arrived = math.max(0, owned - (entry.ownedAt or owned))
    local left = math.max(0, entry.count - arrived)
    if left == 0 then self.bought[itemID] = nil end
    return left
end

--- The plan and its steps, with this visit's buys counted.
-- @return steps, left, plan
function FavorsView:Steps()
    local MerchantsFavor = ns.MerchantsFavor
    if not (MerchantsFavor and MerchantsFavor.Goal()) then return {}, 0, nil end
    local plan = MerchantsFavor:GetPlan()
    local best = plan and plan.best
    if best and plan.crates then
        local crateExtra = self:Extra(best.itemID)
        local bundleExtra = self:Extra(best.best.itemID)
        if crateExtra > 0 or bundleExtra > 0 then
            local copy = {}
            for k, v in pairs(best) do copy[k] = v end
            copy.have = (best.have or 0) + crateExtra
            local shown = {}
            for k, v in pairs(plan) do shown[k] = v end
            shown.best = copy
            shown.materialHave = (plan.materialHave or 0) + bundleExtra
            plan = shown
        end
    end
    local steps, left = MerchantsFavor.Steps(plan)
    return steps, left, plan
end

--- The first step still to buy, or nil.
function FavorsView.NextStep(steps)
    for _, step in ipairs(steps or {}) do
        if not step.done then return step end
    end
    return nil
end

--- "buy" for a material sold in stacks (or one the game can't say yet),
--- "search" for one sold one at a time. A crate is always "search".
function FavorsView.Kind(step)
    if not step or step.crate then return "search" end
    if not Util.HasFunction("C_AuctionHouse.StartCommoditiesPurchase") then return "search" end
    if Util.HasFunction("C_AuctionHouse.GetItemCommodityStatus") then
        local ok, status = pcall(function()
            local value = C_AuctionHouse.GetItemCommodityStatus(step.itemID)
            if type(value) == "number" then return value end
            local enum = rawget(_G, "Enum") and Enum.ItemCommodityStatus
            if enum and value == enum.Item then return NOT_A_STACK end
            return nil
        end)
        if ok and status == NOT_A_STACK then return "search" end
    end
    return "buy"
end

--------------------------------------------------------------------------------
-- The clicks
--------------------------------------------------------------------------------

--- Let go of the buy under way, telling the game when it was asked.
function FavorsView:Cancel()
    local pending = self.pending
    if not pending then return end
    self.pending = nil
    if pending.phase ~= "buying" and Util.HasFunction("C_AuctionHouse.CancelCommoditiesPurchase") then
        pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    end
    Moved()
end

local function CouldNot(itemID)
    ns.Print(L.Format("Couldn't buy %s. Try again.", ItemName(itemID)))
end

--- Buy Next was clicked: one listing, never more.
function FavorsView:BuyNext()
    local pending = self.pending
    if pending and pending.phase == "quoted" then return self:Pay(pending) end
    if pending then return end

    local steps = self:Steps()
    local step = FavorsView.NextStep(steps)
    if not step then return end

    if FavorsView.Kind(step) == "search" then
        if ns.UI and ns.UI.SearchAuctionHouse then ns.UI:SearchAuctionHouse(step.itemID, step.count) end
        return
    end

    local ok = pcall(C_AuctionHouse.StartCommoditiesPurchase, step.itemID, step.count)
    if not ok then return CouldNot(step.itemID) end
    local mine = { itemID = step.itemID, count = step.count, phase = "asking" }
    self.pending = mine
    Moved()
    After(FavorsView.QUOTE_WAIT, function()
        if FavorsView.pending == mine and mine.phase == "asking" then
            FavorsView:Cancel()
            CouldNot(mine.itemID)
        end
    end)
end

--- Pay was clicked: spend the total the button shows.
function FavorsView:Pay(pending)
    if type(GetMoney) == "function" then
        local ok, money = pcall(GetMoney)
        if ok and type(money) == "number" and pending.total and money < pending.total then
            ns.Print(L.Format("You need %s for that.", Util.FormatMoney(pending.total, { noColor = true })))
            return
        end
    end
    local ok = Util.HasFunction("C_AuctionHouse.ConfirmCommoditiesPurchase")
        and pcall(C_AuctionHouse.ConfirmCommoditiesPurchase, pending.itemID, pending.count)
    if not ok then
        self:Cancel()
        return CouldNot(pending.itemID)
    end
    pending.phase = "buying"
    pending.at = Now()
    Moved()
    After(FavorsView.BUY_WAIT, function()
        if FavorsView.pending == pending and pending.phase == "buying" then
            FavorsView.pending = nil
            Moved()
            CouldNot(pending.itemID)
        end
    end)
end

--------------------------------------------------------------------------------
-- What the game answers
--------------------------------------------------------------------------------

function FavorsView:PriceUpdated(total)
    local pending = self.pending
    total = tonumber(total)
    if not (pending and total) then return end
    pending.total = math.floor(total)
    pending.phase = "quoted"
    Moved()
end

function FavorsView:Unavailable()
    local pending = self.pending
    if not pending then return end
    self.pending = nil
    Moved()
    ns.Print(L.Format("Nobody is selling %d %s right now.", pending.count, ItemName(pending.itemID)))
end

function FavorsView:Succeeded()
    local pending = self.pending
    if not (pending and pending.phase == "buying") then return end
    self.pending = nil
    local entry = self.bought[pending.itemID]
    if entry then
        entry.count = entry.count + pending.count
    else
        self.bought[pending.itemID] = { count = pending.count, ownedAt = ns.MerchantsFavor.Owned(pending.itemID) }
    end
    ns.Print(L.Format("Bought %d %s.", pending.count, ItemName(pending.itemID)))
    Moved()
end

function FavorsView:Failed()
    local pending = self.pending
    if not pending then return end
    self.pending = nil
    Moved()
    CouldNot(pending.itemID)
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function CreateRow(row)
    row.icon = Theme.CreateItemIcon(row, ICON_SIZE)
    row.icon:SetPoint("LEFT", 8, 0)

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("TOPLEFT", 8 + ICON_SIZE + 8, -4)
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -90, -4)

    row.detail = Theme.CreateLabel(row, "tiny", "muted")
    row.detail:SetPoint("TOPLEFT", 8 + ICON_SIZE + 8, -20)
    row.detail:SetPoint("TOPRIGHT", row, "TOPRIGHT", -90, -20)
    row.detail:SetWordWrap(false)

    -- The next one to buy carries a gold edge.
    row.edge = Theme.AccentStripe(row, 3)
    row.edge:Hide()

    row.badge = Theme.CreateLabel(row, "tiny", "muted", "RIGHT")
    row.badge:SetPoint("RIGHT", row, "RIGHT", -8, 0)
end

local function UpdateRow(row, step)
    Theme.SetItemIcon(row.icon, step.itemID)
    local label = ItemName(step.itemID)
    if step.count and step.count > 1 then label = L.Format("%d %s", step.count, label) end
    if Theme.SetRowName then Theme.SetRowName(row.name, label) else row.name:SetText(label) end
    local r, g, b = Util.GetItemQualityColor(step.itemID)
    if r then row.name:SetTextColor(r, g, b) else row.name:SetTextColor(Theme.Unpack("text")) end

    row.detail:SetText(step.price and step.price > 0
        and L.Format("About %s", Money(step.price))
        or L["No price yet"])

    row.edge:SetShown(step.isNext == true)
    row.icon:SetAlpha(step.done and 0.45 or 1)
    if step.done then
        row.badge:SetText(L["Got It"])
        row.badge:SetTextColor(Theme.Unpack("profit"))
    else
        row.badge:SetText(step.isNext and L["Next"] or "")
        row.badge:SetTextColor(Theme.Unpack("accent"))
    end
end

local function ShowTooltip(row, step)
    Widgets.ShowItemTooltip(row, "ANCHOR_LEFT", step.itemID)
end

--------------------------------------------------------------------------------
-- Built inside the drawer
--------------------------------------------------------------------------------

function FavorsView:Build(body, frame, topAnchor, opts)
    if self.list then return end
    opts = opts or {}

    local list = Widgets.CreateScrollList(body, {
        rowHeight = ROW_HEIGHT,
        createRow = CreateRow,
        updateRow = UpdateRow,
        onEnter = ShowTooltip,
        onLeave = function() GameTooltip:Hide() end,
    })
    list:SetPoint("TOPLEFT", topAnchor, "BOTTOMLEFT", 0, -4)
    list:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, opts.bottom or 49)
    self.list = list

    local pad = opts.edge or 11
    local footMiddle = pad + (opts.footHeight or 34) / 2

    local width = 110
    if Theme.MeasureText then
        for _, word in ipairs({ L["Buy Next"], L.Format("Pay %s", "888g 88s") }) do
            local ok, measured = pcall(Theme.MeasureText, "small", word)
            if ok and type(measured) == "number" then width = math.max(width, measured + 20) end
        end
    end
    local buy = Widgets.CreateButton(body, L["Buy Next"], function() FavorsView:BuyNext() end,
        { width = width, height = 22, primary = true })
    buy:SetPoint("RIGHT", frame, "BOTTOMRIGHT", -(pad + 6), footMiddle)
    self.buy = buy

    local note = Theme.CreateLabel(body, "tiny", "muted")
    note:SetPoint("LEFT", frame, "BOTTOMLEFT", pad + 8, footMiddle)
    note:SetPoint("RIGHT", buy, "LEFT", -8, 0)
    note:SetWordWrap(true)
    self.note = note

    local empty = Theme.CreateLabel(body, "small", "dim", "CENTER")
    empty:SetPoint("CENTER", list, "CENTER")
    empty:SetWidth(300)
    empty:SetWordWrap(true)
    self.empty = empty

    self.parts = { list, buy, note }
    self:SetShown(false)

    ns.RegisterEvent(self, "COMMODITY_PRICE_UPDATED", function(_, _, _, total) FavorsView:PriceUpdated(total) end)
    ns.RegisterEvent(self, "COMMODITY_PRICE_UNAVAILABLE", function() FavorsView:Unavailable() end)
    ns.RegisterEvent(self, "COMMODITY_PURCHASE_SUCCEEDED", function() FavorsView:Succeeded() end)
    ns.RegisterEvent(self, "COMMODITY_PURCHASE_FAILED", function() FavorsView:Failed() end)
    ns.RegisterEvent(self, "AUCTION_HOUSE_CLOSED", function()
        if FavorsView.pending then FavorsView:Cancel() end
    end)
end

function FavorsView:SetShown(on)
    self.shown = on and true or false
    for _, part in ipairs(self.parts or {}) do part:SetShown(self.shown) end
    if self.empty and not self.shown then self.empty:Hide() end
    if self.shown then self.key = nil end
end

--- Built again only when the bags, a scan, the favor or a buy moved: the
--- drawer refreshes every second.
function FavorsView:Refresh(force)
    if not (self.list and self.shown) then return end
    local MerchantsFavor = ns.MerchantsFavor
    local key = ("%d:%d:%d:%s"):format(MerchantsFavor and MerchantsFavor.version or 0,
        ns.Inventory and ns.Inventory.changes or 0, ns.Prices and ns.Prices.changes or 0,
        tostring(MerchantsFavor and MerchantsFavor.Goal()))
    if not force and key == self.key then return end
    self.key = key

    local steps, left, plan = self:Steps()
    self.plan, self.left = plan, left
    local nextStep = FavorsView.NextStep(steps)
    for _, step in ipairs(steps) do step.isNext = step == nextStep end
    self.list:SetData(steps)

    self.empty:SetShown(#steps == 0)
    if #steps == 0 then
        self.empty:SetText(plan and plan.reached and L["Favor goal reached!"]
            or L["No crate has a price yet. Scan the auction house first."])
    end

    if #steps > 0 and left == 0 then
        self.note:SetText(L["All bought. Fill the crates and take them to the Supply Officer."])
    elseif left > 0 then
        self.note:SetText(L.Format("%d left for your goal. One click buys one listing.", left))
    else
        self.note:SetText("")
    end

    local pending = self.pending
    if pending and pending.phase == "quoted" and pending.total then
        self.buy:SetText(L.Format("Pay %s", Money(pending.total)))
        self.buy:SetEnabledState(true)
    else
        self.buy:SetText(L["Buy Next"])
        self.buy:SetEnabledState(nextStep ~= nil and pending == nil)
    end
end

--- The drawer's summary line.
function FavorsView:Summary()
    local plan = self.plan
    if not plan then return "" end
    local parts = { L.Format("%d of %d favor", math.min(plan.have or 0, plan.goal), plan.goal) }
    if plan.gold and plan.gold > 0 then
        parts[#parts + 1] = L.Format("about %s to go", ("|c%s%s|r"):format(ns.COLORS.accent, Money(plan.gold)))
    end
    return table.concat(parts, "  ·  ")
end

--- The drawer's header title.
function FavorsView:Title()
    return L["Your favor goal"]
end
