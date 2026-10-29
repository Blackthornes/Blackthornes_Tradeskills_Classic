-- The Sale Total in the auction house drawer's header, left of Scan (the
-- owner said build it, 2026-10-28, from a mockup; on unless unticked; moved
-- into the header and turned to count up, 2026-10-29, from a mockup whose
-- words he approved).
--
-- It starts at 0 each time the auction house opens and counts up with every
-- listing that goes up (Posting:ResolvePending calls NoteListed), by what
-- that listing should bring in after the auction house cut
-- (Profit:NetFromListing). Under it, small, "of 2,450g": what this visit's
-- listings and everything still on the Sell list come to together, or "all
-- listed" once the list is empty. In the header it still shows with the
-- drawer folded.
--
-- A listing sends coins from its row to the number, which rolls up, pops
-- and glows, with "+45g" rising off it; each round number passed
-- (MilestoneStep) pops a chip. Effects Subtle keeps the rolling number
-- only; Off shows the new total at once. There is no "best" (the owner,
-- 2026-10-29) and nothing about scans.
--
-- Saved, account wide, never rename it: `saleTotal` (the switch, nil reads
-- as on). `saleTotalBest` and `saleTotalLast` stay in the save, unread.
-- What was listed is kept for the visit only. Nothing is drawn or run while
-- the counter is hidden.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local SaleTotal = ns.NewModule("SaleTotal")

SaleTotal.GAP = 8               -- between the counter and the button right of it
SaleTotal.COINS = 20            -- coin textures kept for flights
SaleTotal.COIN_TEXTURE = [[Interface\MoneyFrame\UI-GoldIcon]]

local COPPER_PER_GOLD = 10000

local function Level()
    return ns.Motion and ns.Motion.Level() or "full"
end

--------------------------------------------------------------------------------
-- Working it out (no frames, so the tests read these straight)
--------------------------------------------------------------------------------

--- Whether the counter is wanted at all.
function SaleTotal:IsOn()
    return not (ns.Config and ns.Config:Get("saleTotal") == false)
end

--- What one listing of `quantity` at `unitPrice` should bring in, after the
--- auction house cut.
function SaleTotal.Net(itemID, unitPrice, quantity)
    unitPrice, quantity = tonumber(unitPrice) or 0, tonumber(quantity) or 1
    if unitPrice <= 0 or quantity <= 0 then return 0 end
    local each = unitPrice
    local Profit = ns.Profit
    if Profit and Profit.NetFromListing then
        local ok, net = pcall(Profit.NetFromListing, Profit, itemID, unitPrice)
        if ok and type(net) == "number" then each = net end
    end
    return math.max(0, each * quantity)
end

--- What the lines still on the Sell list should bring in, and how many there
--- are. Held lines (kept for the other addons) count for nothing.
function SaleTotal.Left(lines)
    local total, count = 0, 0
    for _, line in ipairs(lines or {}) do
        if not line.held and line.itemID then
            count = count + 1
            local quantity = tonumber(line.postQuantity)
            if line.unitPrice and quantity then
                total = total + SaleTotal.Net(line.itemID, line.unitPrice, quantity)
            else
                total = total + (tonumber(line.postTotal) or 0)
            end
        end
    end
    return total, count
end

--- The round number milestones fall on near `copper`: 10g, 100g, 1,000g
--- and so on, the power of ten below the total, never under 10g.
function SaleTotal.MilestoneStep(copper)
    local gold = (tonumber(copper) or 0) / COPPER_PER_GOLD
    if gold < 100 then return 10 * COPPER_PER_GOLD end
    local power = math.floor(math.log10(gold) + 1e-9)
    return (10 ^ power) * COPPER_PER_GOLD
end

--- The milestone passed going from `from` to `to`, or nil.
function SaleTotal.Crossed(from, to)
    from, to = tonumber(from) or 0, tonumber(to) or 0
    if to <= from then return nil end
    local step = SaleTotal.MilestoneStep(to)
    local mark = math.floor(to / step) * step
    if mark > from and mark > 0 then return mark end
    return nil
end

--- Whole gold, "1,234".
function SaleTotal.Gold(copper)
    local gold = math.floor((tonumber(copper) or 0) / COPPER_PER_GOLD + 0.5)
    local Util = ns.Util
    if Util and Util.Comma then return Util.Comma(gold) end
    return tostring(gold)
end

--- Money as the counter shows it: gold with its coins in their colours,
--- silver and copper only while it is under 100g, and "0g" for nothing.
function SaleTotal.MoneyText(copper)
    local Util = ns.Util
    copper = math.max(0, math.floor((copper or 0) + 0.5))
    if not Util or not Util.FormatMoney then return tostring(copper) end
    if copper == 0 then
        -- "0g" in the gold coin's colour, as the mockup has it.
        return (Util.FormatMoney(COPPER_PER_GOLD, { short = true }):gsub("^1", "0", 1))
    end
    return Util.FormatMoney(copper, { short = true })
end

--- The small line under the number.
function SaleTotal.UnderText(listed, left)
    if (left or 0) <= 0 then
        return (listed or 0) > 0 and L["all listed"] or ""
    end
    return L.Format("of %s", SaleTotal.MoneyText((listed or 0) + left))
end

--------------------------------------------------------------------------------
-- What was listed this visit
--------------------------------------------------------------------------------

SaleTotal.listed = 0        -- copper, this visit
SaleTotal.listings = 0      -- listings that went up, this visit
SaleTotal.left = 0          -- copper still on the Sell list
SaleTotal.count = 0         -- lines still on the Sell list

--- The auction house opened: start again at 0.
function SaleTotal:NewVisit()
    self.listed, self.listings = 0, 0
    if self.counter then
        self:Settle()
        self:SetNumber(0)
        self:DrawUnder()
    end
end

--- A listing went up (Posting:ResolvePending). Counts it, and plays it.
function SaleTotal:NoteListed(itemID, quantity, unitPrice)
    local amount = SaleTotal.Net(itemID, unitPrice, quantity)
    if amount <= 0 then return end
    local from = self.listed or 0
    self.listed = from + amount
    self.listings = (self.listings or 0) + 1
    -- What it was worth leaves the list's share at once, so "of" holds
    -- still until the list catches up.
    self.left = math.max(0, (self.left or 0) - amount)
    if not self:Showing() then
        self:SetNumber(self.listed)
        return
    end
    self:Play(itemID, from, self.listed, amount)
    self:DrawUnder()
end

--------------------------------------------------------------------------------
-- The counter
--------------------------------------------------------------------------------

--- Build the counter on the drawer's header, once. UI:AttachPostButton
--- calls it with the button the counter sits left of.
function SaleTotal:Attach(bar, rightOf)
    if not bar then return end
    if not self.counter then self:Build(bar) end
    local counter = self.counter
    counter:ClearAllPoints()
    if rightOf then
        counter:SetPoint("RIGHT", rightOf, "LEFT", -SaleTotal.GAP, 0)
    else
        counter:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
    end
    counter:SetShown(self:IsOn())
    self:Fit()
end

function SaleTotal:Build(bar)
    local Theme = ns.Theme
    local counter = CreateFrame("Frame", nil, bar)
    counter:SetHeight((bar.GetHeight and bar:GetHeight()) or 44)
    counter:SetWidth(60)
    counter:EnableMouse(true)
    self.counter = counter
    self.bar = bar

    -- The light behind the number: brighter the more it has been fed.
    local glow = counter:CreateTexture(nil, "BACKGROUND", nil, 3)
    glow:SetPoint("TOPLEFT", -14, -2)
    glow:SetPoint("BOTTOMRIGHT", 4, 2)
    glow:Hide()
    self.glow = glow

    local label = Theme.CreateLabel(counter, "tiny", "accent", "RIGHT")
    label:SetPoint("TOPRIGHT", counter, "TOPRIGHT", 0, -3)
    label:SetText(L["Sale Total:"])
    self.label = label

    -- The number sits on its own frame, so a pop scales it alone.
    local holder = CreateFrame("Frame", nil, counter)
    holder:SetSize(60, 18)
    holder:SetPoint("RIGHT", counter, "RIGHT", 0, 0)
    self.holder = holder

    local number = holder:CreateFontString(nil, "OVERLAY")
    number:SetFont(Theme.FONT, (Theme.sizes.title or 16) + 2, "OUTLINE")
    number:SetTextColor(Theme.Unpack("accentHi"))
    number:SetJustifyH("RIGHT")
    number:SetPoint("RIGHT", holder, "RIGHT", 0, 0)
    self.number = number

    local under = Theme.CreateLabel(counter, "tiny", "muted", "RIGHT")
    under:SetPoint("BOTTOMRIGHT", counter, "BOTTOMRIGHT", 0, 3)
    self.under = under

    -- "+45g", rising off the number as a listing lands.
    local gain = Theme.CreateLabel(counter, "tiny", "profit", "RIGHT")
    gain:SetPoint("BOTTOMRIGHT", label, "TOPRIGHT", 0, 1)
    gain:Hide()
    self.gain = gain

    -- A milestone passed: the round number, rising off the total.
    local chip = CreateFrame("Frame", nil, counter)
    chip:SetSize(60, 16)
    chip:SetFrameLevel(counter:GetFrameLevel() + 6)
    Theme.Fill(chip, "ink", 0.95)
    Theme.Border(chip, "accentHi", 1)
    local chipText = Theme.CreateLabel(chip, "tiny", "accentHi", "CENTER")
    chipText:SetPoint("CENTER")
    chip.text = chipText
    chip:Hide()
    self.chip = chip

    -- Coins for the flights, over the whole drawer, made once and reused.
    self.coins, self.free = {}, {}
    local drawer = (bar.GetParent and bar:GetParent()) or bar
    local layer = CreateFrame("Frame", nil, drawer)
    layer:SetAllPoints(drawer)
    layer:SetFrameLevel(counter:GetFrameLevel() + 8)
    self.coinLayer = layer
    for index = 1, SaleTotal.COINS do
        local coin = layer:CreateTexture(nil, "OVERLAY")
        coin:SetTexture(SaleTotal.COIN_TEXTURE)
        coin:SetSize(12, 12)
        coin:Hide()
        self.coins[index] = coin
        self.free[#self.free + 1] = coin
    end

    counter:SetScript("OnEnter", function(owner) SaleTotal:ShowTooltip(owner) end)
    counter:SetScript("OnLeave", function() GameTooltip:Hide() end)
    counter:SetScript("OnHide", function() SaleTotal:Settle() end)

    self.shown = self.listed or 0
    self:SetNumber(self.shown)
    self:DrawUnder()
    return counter
end

--- Whether the counter shows now.
function SaleTotal:Showing()
    return self.counter ~= nil and self.counter:IsShown()
end

--- How much of the header the counter takes, with its gap.
function SaleTotal:Width()
    if not self:Showing() then return 0 end
    return (self.counterWidth or 0) + SaleTotal.GAP
end

--- As wide as its widest line, measured. The header's words give way when
--- it grows (UI:FitAuctionText).
function SaleTotal:Fit()
    if not self.counter then return end
    local Theme = ns.Theme
    local widest = 0
    for _, text in ipairs({ self.label, self.number, self.under }) do
        local width = (Theme.TextWidth and Theme.TextWidth(text)) or 0
        if type(width) == "number" and width > widest then widest = width end
    end
    widest = math.ceil(widest) + 2
    if self.holder then self.holder:SetWidth(widest) end
    if widest ~= self.counterWidth then
        self.counterWidth = widest
        self.counter:SetWidth(widest)
        if ns.UI and ns.UI.FitAuctionText then ns.UI:FitAuctionText() end
    end
end

function SaleTotal:SetNumber(copper)
    self.shown = copper or 0
    if self.number then
        self.number:SetText(SaleTotal.MoneyText(self.shown))
        self:Fit()
    end
end

function SaleTotal:DrawUnder()
    if not self.under then return end
    self.under:SetText(SaleTotal.UnderText(self.listed, self.left))
    self:Fit()
end

--- Light the glow behind the number to `p` of its strength.
function SaleTotal:Light(p)
    if self.glow and ns.Theme and ns.Theme.LightGradient then
        ns.Theme.LightGradient(self.glow, "HORIZONTAL", "accent", 0, 0.30, p)
    end
end

--- Roll the number to `target` over `duration`.
function SaleTotal:Roll(target, duration)
    local Motion = ns.Motion
    if not Motion or Level() == "off" then
        self:SetNumber(target)
        return
    end
    Motion:SetValue(self, "value", self.shown or 0)
    Motion:Blend(self, "value", target, duration or 0.35, function(value)
        SaleTotal:SetNumber(value)
    end)
end

--- The number grows and settles, its glow flaring and fading.
function SaleTotal:Pop(size, glow)
    local Motion = ns.Motion
    if not Motion or Level() ~= "full" or not self.holder then return end
    size = size or 0.12
    local holder = self.holder
    Motion:Run(self, "pop", 0.32, function(p)
        holder:SetScale(1 + math.sin(p * math.pi) * size)
    end, { ease = false, done = function() holder:SetScale(1) end })

    self.heat = math.min(1, (self.heat or 0) + (glow or 0.25))
    local from = self.heat
    Motion:Run(self, "glow", 1.2, function(p)
        SaleTotal.heat = from * (1 - p)
        SaleTotal:Light(SaleTotal.heat)
    end)
end

--- "+45g" rises off the number and fades.
function SaleTotal:Gain(amount)
    local gain, Motion = self.gain, ns.Motion
    if not gain or not Motion or Level() ~= "full" then return end
    gain:SetText("+" .. SaleTotal.Gold(amount) .. "g")
    gain:Show()
    local label = self.label
    Motion:Run(gain, "rise", 1.1, function(p)
        gain:ClearAllPoints()
        gain:SetPoint("BOTTOMRIGHT", label, "TOPRIGHT", 0, 1 + p * 10)
        gain:SetAlpha(p > 0.6 and (1 - p) / 0.4 or 1)
    end, { ease = false, done = function() gain:Hide() end })
end

--- Where to send coins at: the number's middle, in the layer's offsets.
local function Target(self)
    local layer = self.coinLayer
    local lx, ly = layer:GetLeft() or 0, layer:GetBottom() or 0
    local hx, hy = self.holder:GetLeft(), self.holder:GetBottom()
    local width = self.holder.GetWidth and self.holder:GetWidth() or 40
    if type(width) ~= "number" then width = 40 end
    if not hx or not hy then return nil end
    return hx - lx + width / 2, hy - ly + 9
end

--- A coin flies from `fromX, fromY` (offsets in the drawer) to the number.
function SaleTotal:Fly(fromX, fromY, delay, done)
    local Motion = ns.Motion
    local coin = table.remove(self.free or {})
    local toX, toY
    if coin and self.holder and self.coinLayer then toX, toY = Target(self) end
    if not coin or not Motion or not toX then
        if coin then table.insert(self.free, coin) end
        if done then done() end
        return
    end
    local layer = self.coinLayer
    local lift = 30 + math.random(0, 20)

    coin:ClearAllPoints()
    coin:SetPoint("CENTER", layer, "BOTTOMLEFT", fromX, fromY)
    coin:SetAlpha(1)
    coin:Show()
    Motion:Run(coin, "fly", 0.5, function(p)
        local x = fromX + (toX - fromX) * p
        local y = fromY + (toY - fromY) * p + math.sin(p * math.pi) * lift
        coin:ClearAllPoints()
        coin:SetPoint("CENTER", layer, "BOTTOMLEFT", x, y)
        coin:SetAlpha(p > 0.85 and (1 - p) / 0.15 or 1)
    end, { delay = delay, ease = Motion.EaseOut, done = function()
        coin:Hide()
        local free = SaleTotal.free
        free[#free + 1] = coin
        if done then done() end
    end })
end

--- Where an item's row stands in the drawer, as offsets from its bottom
--- left, or nil when it is scrolled out of sight or gone.
function SaleTotal:RowSpot(itemID)
    local PostPanel = ns.PostPanel
    local layer = self.coinLayer
    local lx, ly = layer and layer:GetLeft() or 0, layer and layer:GetBottom() or 0
    local rows = PostPanel and PostPanel.list and PostPanel.list.rows
    for _, row in ipairs(rows or {}) do
        local data = row.data
        if data and data.itemID == itemID and row.IsShown and row:IsShown() then
            local right, bottom, top = row:GetRight(), row:GetBottom(), row:GetTop()
            if right and bottom and top then
                return right - lx - 40, (bottom + top) / 2 - ly
            end
        end
    end
    return nil
end

--- Pop the chip for a milestone passed.
function SaleTotal:Milestone(copper)
    local chip, Motion = self.chip, ns.Motion
    if not chip or not Motion or Level() ~= "full" then return end
    chip.text:SetText(SaleTotal.Gold(copper) .. "g")
    chip:SetWidth(math.max(40, ((ns.Theme.TextWidth and ns.Theme.TextWidth(chip.text)) or 30) + 14))
    local number = self.number
    chip:Show()
    Motion:Run(chip, "rise", 1.4, function(p)
        chip:ClearAllPoints()
        chip:SetPoint("BOTTOMRIGHT", number, "TOPLEFT", -4, -6 + p * 14)
        chip:SetScale(p < 0.2 and (0.6 + 2 * p) or 1)
        chip:SetAlpha(p > 0.7 and (1 - p) / 0.3 or 1)
    end, { ease = false, done = function() chip:Hide() end })
    self:Pop(0.2, 0.6)
    self:Shower(6)
end

--- A few coins burst up off the number and fall away.
function SaleTotal:Shower(count)
    local Motion, layer = ns.Motion, self.coinLayer
    if not Motion or Level() ~= "full" or not layer or not self.holder then return end
    local x0, y0 = Target(self)
    if not x0 then return end
    for index = 1, count or 8 do
        local coin = table.remove(self.free)
        if not coin then return end
        local dx = (math.random() - 0.5) * 100
        local up = 30 + math.random() * 30
        coin:Show()
        Motion:Run(coin, "fly", 0.9, function(p)
            coin:ClearAllPoints()
            coin:SetPoint("CENTER", layer, "BOTTOMLEFT", x0 + dx * p, y0 + up * 4 * p * (1 - p) - 20 * p)
            coin:SetAlpha(1 - p)
        end, { delay = index * 0.03, ease = false, done = function()
            coin:Hide()
            local free = SaleTotal.free
            free[#free + 1] = coin
        end })
    end
end

--- A listing landed: coins from its row, the number rolling up from `from`
--- to `to`, "+45g", and a chip for a round number passed.
function SaleTotal:Play(itemID, from, to, amount)
    local land = function()
        SaleTotal:Roll(to, 0.35)
        SaleTotal:Pop(0.1, 0.3)
        SaleTotal:Gain(amount)
        local mark = SaleTotal.Crossed(from, to)
        if mark then SaleTotal:Milestone(mark) end
    end
    if Level() ~= "full" then
        land()
        return
    end
    local x, y = self:RowSpot(itemID)
    if not x then
        land()
        return
    end
    self:Fly(x, y, 0, land)
    if amount >= 2 * COPPER_PER_GOLD then self:Fly(x - 6, y + 4, 0.08) end
    if amount >= 20 * COPPER_PER_GOLD then self:Fly(x + 4, y - 3, 0.16) end
end

--- Land everything at once: the counter went away mid flight.
function SaleTotal:Settle()
    if ns.Motion then ns.Motion:Stop(self, nil, true) end
    for _, coin in ipairs(self.coins or {}) do
        if ns.Motion then ns.Motion:Stop(coin, nil) end
        coin:Hide()
    end
    self.free = {}
    for index, coin in ipairs(self.coins or {}) do self.free[index] = coin end
    if self.chip then self.chip:Hide() end
    if self.gain then self.gain:Hide() end
    if self.holder then self.holder:SetScale(1) end
    if self.number and self.shown ~= self.listed then self:SetNumber(self.listed or 0) end
    self:Light(0)
end

--------------------------------------------------------------------------------
-- What the drawer calls
--------------------------------------------------------------------------------

--- Show or hide the counter by the setting. Returns whether it shows.
function SaleTotal:SetShown(show)
    if not self.counter then return false end
    show = show ~= false and self:IsOn() or false
    if show ~= self.counter:IsShown() then
        self.counter:SetShown(show)
        if ns.UI and ns.UI.FitAuctionText then ns.UI:FitAuctionText() end
    end
    return show
end

--- What is still on the Sell list. From PostPanel:Refresh on Sell.
-- @param lines the lines Sell shows; held ones count for nothing
-- @param heldBack how many were kept for the other addons
function SaleTotal:Update(lines, heldBack)
    self.left, self.count = SaleTotal.Left(lines)
    self.heldBack = heldBack or 0
    self:DrawUnder()
end

function SaleTotal:ShowTooltip(owner)
    if not GameTooltip then return end
    local Theme = ns.Theme
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
    GameTooltip:SetText(L["Sale Total"], Theme.Unpack("accentHi"))
    GameTooltip:AddLine(L["What the items you listed this visit should bring in, after the auction house cut. It starts again at 0 each time you open the auction house."],
        1, 1, 1, true)
    GameTooltip:AddLine(" ")
    local r, g, b = Theme.Unpack("muted")
    local listings = self.listings or 0
    GameTooltip:AddDoubleLine(L["Listed:"], L.Format("%d of %d", listings, listings + (self.count or 0)),
        r, g, b, 1, 1, 1)
    GameTooltip:AddDoubleLine(L["Still to List:"], SaleTotal.MoneyText(self.left or 0), r, g, b, 1, 1, 1)
    if (self.heldBack or 0) > 0 then
        GameTooltip:AddDoubleLine(L["Held Back:"], L.Format("%d (not counted)", self.heldBack), r, g, b, 1, 1, 1)
    end
    GameTooltip:Show()
end

--- Each visit to the auction house starts at 0.
function SaleTotal:OnInitialize()
    if ns.RegisterEvent then
        ns.RegisterEvent(self, "AUCTION_HOUSE_SHOW", function() SaleTotal:NewVisit() end)
    end
end
