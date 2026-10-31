-- Blackthornes Tradeskills -- UI/Tab_Stats.lua
-- One item at a time, in charts.
--
-- The owner asked (2026-10-14) for a Stats tab like Farmer's, to look at
-- one item and see everything known about it drawn out. The numbers come
-- from Logic/ItemStats.lua; this only draws them, from plain colour
-- textures like the price graph and the Sales tab's chart.
--
-- Left, the items worth looking at: what you craft, what you starred and
-- what you sold, searchable across every priced item. Right, the item's
-- header with four numbers, then cards: the price graph, the cheapest
-- times of the week, where each sale's gold goes, your listings, sales by
-- week, stock at each scan, the price from each source, the last ninety
-- days, who else sells it, how fast yours sell and money by method.
--
-- Smooth play: drawn only while the tab shows, for the item picked, and
-- again only when ItemStats:Key moves, a moment after the event that moved
-- it. Bars grow in when an item is picked (Window effects). A best week is
-- cheered once ("Best week cheer", statsCheer).

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local UI = ns.UI

local StatsUI = {}
ns.StatsUI = StatsUI

local LIST_WIDTH = 236
local ROW_HEIGHT = 22
local HEADER_HEIGHT = 50
local KPI_HEIGHT = 50
local GAP = 8
local PAD = 10
local HEADING_ROOM = 24
-- After the last change, how long before the tab draws again.
local REDRAW_DELAY = 0.3
-- How long the bars take to grow in.
local GROW = 0.45

local DAY = 24 * 3600

local state = {
    search = "",
    selected = nil,
    key = nil,
    stats = nil,
}

local widgets = {}

--------------------------------------------------------------------------------
-- Words
--------------------------------------------------------------------------------

local function Money(copper)
    if copper == nil then return "|c" .. ns.COLORS.muted .. "--|r" end
    return Util.FormatMoney(math.floor(copper + (copper < 0 and -0.5 or 0.5)), { short = true })
end

local function Count(n)
    return Util.Comma(math.floor((n or 0) + 0.5))
end

local function Percent(fraction)
    return ("%d%%"):format(math.floor((fraction or 0) * 100 + 0.5))
end

--- A plain name without asking the game to load anything it has not.
local function PlainName(itemID)
    if Util.HasFunction and Util.HasFunction("C_Item.IsItemDataCachedByID") then
        local ok, cached = pcall(C_Item.IsItemDataCachedByID, itemID)
        if ok and cached == true then
            local okName, name = pcall(C_Item.GetItemInfo, itemID)
            if okName and type(name) == "string" then return name end
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- The list
--------------------------------------------------------------------------------

--- itemID -> saved name for what you craft, starred and sold. Read from
--- saved data only.
local function Candidates()
    local names, picked = {}, {}

    local ledger = ns.Mail and ns.Mail.GetLedger and select(2, pcall(ns.Mail.GetLedger, ns.Mail))
    for _, entry in ipairs(type(ledger) == "table" and type(ledger.entries) == "table" and ledger.entries or {}) do
        if type(entry) == "table" and entry.itemID and entry.kind == "sold" then
            picked[entry.itemID] = true
            if type(entry.name) == "string" then names[entry.itemID] = entry.name end
        end
    end

    for _, record in pairs(ns.db and type(ns.db.characters) == "table" and ns.db.characters or {}) do
        for _, recipe in pairs(type(record) == "table" and type(record.recipes) == "table" and record.recipes or {}) do
            local itemID = type(recipe) == "table" and recipe.outputItemID
            if itemID then
                picked[itemID] = true
                if not names[itemID] and type(recipe.name) == "string" then names[itemID] = recipe.name end
            end
        end
    end

    local favourites = ns.Prices and ns.Prices.GetFavourites and ns.Prices:GetFavourites() or {}
    for itemID, name in pairs(favourites) do
        if type(itemID) == "number" then
            picked[itemID] = true
            if not names[itemID] and type(name) == "string" then names[itemID] = name end
        end
    end

    return picked, names
end

--- What you sold of each item in the last 30 days, in copper.
local function RecentNet(now)
    local net = {}
    local ledger = ns.Mail and ns.Mail.GetLedger and select(2, pcall(ns.Mail.GetLedger, ns.Mail))
    for _, entry in ipairs(type(ledger) == "table" and type(ledger.entries) == "table" and ledger.entries or {}) do
        if type(entry) == "table" and entry.kind == "sold" and entry.itemID
            and type(entry.t) == "number" and now - entry.t <= 30 * DAY then
            net[entry.itemID] = (net[entry.itemID] or 0) + (tonumber(entry.net) or 0)
        end
    end
    return net
end

--- The rows: with no search, what you craft, starred or sold; with one,
--- every priced item too, by name. Sold most in the last 30 days first,
--- then worth most.
local function BuildList(search)
    search = (search or ""):lower()
    local picked, names = Candidates()
    local prices = ns.Prices and ns.Prices.GetTable and ns.Prices:GetTable() or {}

    if search ~= "" then
        for itemID in pairs(prices) do picked[itemID] = true end
    end

    local net = RecentNet(time())
    local rows = {}
    for itemID in pairs(picked) do
        local name = names[itemID] or PlainName(itemID)
        local keep = search == "" or (name and name:lower():find(search, 1, true) ~= nil)
            or tostring(itemID) == search
        if keep then
            local record = prices[itemID]
            rows[#rows + 1] = {
                itemID = itemID,
                name = name or "",
                net = net[itemID] or 0,
                worth = type(record) == "table" and tonumber(record.market) or 0,
            }
        end
    end

    table.sort(rows, function(a, b)
        if a.net ~= b.net then return a.net > b.net end
        if a.worth ~= b.worth then return a.worth > b.worth end
        return a.itemID < b.itemID
    end)
    return rows
end

-- For the tests.
UI._StatsList = BuildList

local function CreateRow(row)
    row.icon = Theme.CreateItemIcon(row, 16)
    row.icon:SetPoint("LEFT", 6, 0)

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("LEFT", 28, 0)
    row.name:SetPoint("RIGHT", -70, 0)

    row.worth = Theme.CreateLabel(row, "tiny", "muted", "RIGHT")
    row.worth:SetPoint("RIGHT", -6, 0)
    row.worth:SetWidth(64)
end

local function UpdateRow(row, entry)
    entry.label = Util.GetItemLabel(entry.itemID)
    Theme.SetRowName(row.name, entry.label)
    Theme.SetItemNameColor(row.name, entry.itemID)
    Theme.SetItemIcon(row.icon, entry.itemID)
    Theme.SetMoneyText(row.worth, entry.worth > 0 and entry.worth or nil, { short = true })
end

--------------------------------------------------------------------------------
-- Drawing helpers
--------------------------------------------------------------------------------

--- r, g, b part way from one palette colour to another.
local function Mix(fromKey, toKey, p)
    local r1, g1, b1 = Theme.Unpack(fromKey)
    local r2, g2, b2 = Theme.Unpack(toKey)
    p = math.max(0, math.min(1, p or 0))
    return r1 + (r2 - r1) * p, g1 + (g2 - g1) * p, b1 + (b2 - b1) * p
end

--- A card: dark glass with a fine border, a heading and pools of bars and
--- labels drawn fresh on each redraw.
local function CreateCard(parent, heading, height)
    local card = Theme.CreatePanel(parent, "glass", "border")
    card.height = height
    card.textures, card.labels = {}, {}
    card.usedTextures, card.usedLabels = 0, 0
    card.grow = {}

    if heading then
        card.heading = Theme.CreateHeading(card, heading)
        card.heading:SetPoint("TOPLEFT", PAD, -8)
    end

    card.empty = Theme.CreateLabel(card, "small", "dim", "CENTER")
    card.empty:SetPoint("LEFT", PAD + 6, -8)
    card.empty:SetPoint("RIGHT", -PAD - 6, -8)
    card.empty:SetWordWrap(true)
    card.empty:Hide()

    function card:Reset()
        for _, texture in ipairs(self.textures) do texture:Hide() end
        for _, label in ipairs(self.labels) do label:Hide() end
        self.usedTextures, self.usedLabels = 0, 0
        self.grow = {}
        self.empty:Hide()
    end

    --- A flat texture in the card, `left` and `top` from its top left.
    function card:Box(left, top, width, height, r, g, b, a, layer)
        self.usedTextures = self.usedTextures + 1
        local texture = self.textures[self.usedTextures]
        if not texture then
            texture = self:CreateTexture(nil, "ARTWORK")
            self.textures[self.usedTextures] = texture
        end
        texture:SetDrawLayer(layer or "ARTWORK")
        pcall(texture.SetBlendMode, texture, "BLEND")
        texture:ClearAllPoints()
        texture:SetPoint("TOPLEFT", self, "TOPLEFT", left, -top)
        texture:SetSize(math.max(1, width), math.max(1, height))
        texture:SetColorTexture(r, g, b, a or 1)
        texture:Show()
        return texture
    end

    --- A bar standing on `bottom` (from the card's top), growing up.
    function card:Column(left, bottom, width, height, r, g, b, a)
        height = math.max(1, height)
        local texture = self:Box(left, bottom - height, width, height, r, g, b, a)
        texture:ClearAllPoints()
        texture:SetPoint("BOTTOMLEFT", self, "TOPLEFT", left, -bottom)
        self.grow[#self.grow + 1] = { texture = texture, size = height, tall = true }
        return texture
    end

    --- A bar lying from `left`, growing right.
    function card:Row(left, top, width, height, r, g, b, a)
        width = math.max(1, width)
        local texture = self:Box(left, top, width, height, r, g, b, a)
        self.grow[#self.grow + 1] = { texture = texture, size = width }
        return texture
    end

    function card:Text(text, size, color, left, top, width, justify)
        self.usedLabels = self.usedLabels + 1
        local label = self.labels[self.usedLabels]
        if not label then
            label = Theme.CreateLabel(self, "small", "text")
            self.labels[self.usedLabels] = label
        end
        label:SetFont(Theme.FONT, Theme.sizes[size] or Theme.sizes.small, "")
        label:SetTextColor(Theme.Unpack(color or "text"))
        label:SetJustifyH(justify or "LEFT")
        label:ClearAllPoints()
        label:SetPoint("TOPLEFT", self, "TOPLEFT", left, -top)
        -- A pooled label keeps an earlier width unless told otherwise.
        label:SetWidth(width or 0)
        label:SetText(text or "")
        label:Show()
        return label
    end

    --- Draw a column of labels down the left and say where the bars can
    --- start: past the widest of them (German runs longer), never under
    --- `least` and never past half the card, so no label ends in "...".
    function card:LabelColumn(texts, top, step, least, width)
        local widest = 0
        for index, text in ipairs(texts) do
            local label = self:Text(text, "small", "muted", PAD, top + (index - 1) * step)
            widest = math.max(widest, Theme.TextWidth(label) or 0)
        end
        return PAD + math.min(math.max(least, math.ceil(widest) + 8), math.floor(width / 2))
    end

    function card:Empty(text)
        self.empty:SetText(text)
        self.empty:Show()
    end

    --- Grow the bars drawn since Reset, when `animate` is set.
    function card:Grow(animate)
        local grow = self.grow
        if not animate or #grow == 0 or not ns.Motion then return end
        ns.Motion:Run(self, "grow", GROW, function(p)
            for _, bar in ipairs(grow) do
                local size = math.max(1, bar.size * p)
                if bar.tall then bar.texture:SetHeight(size) else bar.texture:SetWidth(size) end
            end
        end)
    end

    return card
end

--------------------------------------------------------------------------------
-- The cards
--------------------------------------------------------------------------------

local DAYS_SHOWN = { 2, 3, 4, 5, 6, 7, 1 }   -- Monday first; date()'s wday 1 is Sunday
local DAY_NAMES = { L["Sun"], L["Mon"], L["Tue"], L["Wed"], L["Thu"], L["Fri"], L["Sat"] }

local function HourWord(hour)
    if ns.PriceHistory and ns.PriceHistory.HourText then return ns.PriceHistory.HourText(hour) end
    return tostring(hour)
end

local Draw = {}

--- The cheapest price by day and hour: green where it ran cheap, gold
--- where it ran dear, dark where nothing was scanned.
function Draw.heat(card, stats, width)
    local heat = stats.heat
    if not heat or (heat.count or 0) == 0 then
        card:Empty(L["Scan the auction house at different times of day to fill this in."])
        return
    end

    local labelWidth = 30
    local top = HEADING_ROOM + 4
    local cellW = (width - PAD * 2 - labelWidth) / 24
    local cellH = 11
    local spread = (heat.high or 0) - (heat.low or 0)

    for row, wday in ipairs(DAYS_SHOWN) do
        local y = top + (row - 1) * (cellH + 1)
        card:Text(DAY_NAMES[wday], "tiny", "dim", PAD, y)
        for slot = 1, 24 do
            local value = heat.cells[wday] and heat.cells[wday][slot]
            local x = PAD + labelWidth + (slot - 1) * cellW
            if value then
                local p = spread > 0 and (value - heat.low) / spread or 0.5
                local r, g, b = Mix("profit", "accent", p)
                card:Box(x, y, cellW - 1, cellH, r, g, b, 0.35 + 0.55 * math.abs(p - 0.5) * 2)
            else
                local r, g, b = Theme.Unpack("glassAlt")
                card:Box(x, y, cellW - 1, cellH, r, g, b, 1)
            end
        end
    end

    local hoursTop = top + 7 * (cellH + 1) + 2
    for _, hour in ipairs({ 0, 6, 12, 18 }) do
        card:Text(HourWord(hour), "tiny", "dim", PAD + labelWidth + hour * cellW, hoursTop)
    end

    local caption
    if heat.buyHour and heat.sellHour then
        caption = L.Format("Cheapest around %s, dearest around %s.", HourWord(heat.buyHour), HourWord(heat.sellHour))
    elseif heat.steady then
        caption = L["It costs about the same all day."]
    else
        caption = L["Keep scanning at different hours to learn its cheapest time."]
    end
    card:Text(caption, "tiny", "muted", PAD, hoursTop + 14, width - PAD * 2)
end

--- Where the price of one goes: materials, the auction house's cut, the
--- deposit and what you keep.
function Draw.cost(card, stats, width)
    local craft = stats.craft
    if not craft then
        card:Empty(L["You don't craft this, so there is no cost to show."])
        return
    end
    if not craft.costEach then
        card:Empty(craft.reason or L["Its materials have no price yet."])
        return
    end

    local sell = craft.sellEach or stats.worth or 0
    local materials = craft.costEach or 0
    local cut = craft.cutEach or 0
    local deposit = craft.depositEach or 0
    local keep = craft.profitEach or (sell - materials - cut - deposit)

    local parts = {
        { L["Materials"], materials, "metal" },
        { L["Auction house cut"], cut, "loss" },
        { L["Deposit"], deposit, "warn" },
        { L["You keep"], math.max(0, keep), "profit" },
    }

    local total = 0
    for _, part in ipairs(parts) do total = total + part[2] end
    local barWidth = width - PAD * 2
    local top = HEADING_ROOM + 4

    if total > 0 then
        local x = PAD
        for _, part in ipairs(parts) do
            local share = part[2] / total * barWidth
            if share >= 1 then
                local r, g, b = Theme.Unpack(part[3])
                card:Row(x, top, share - 1, 12, r, g, b, 0.9)
                x = x + share
            end
        end
    end

    local y = top + 20
    card:Text(L["Sells for"], "small", "muted", PAD, y)
    card:Text(Money(sell), "small", "text", PAD, y, barWidth, "RIGHT")
    for _, part in ipairs(parts) do
        y = y + 15
        local r, g, b = Theme.Unpack(part[3])
        card:Box(PAD, y + 3, 6, 6, r, g, b, 1)
        card:Text(part[1], "small", "muted", PAD + 12, y)
        if part[1] == L["You keep"] then
            local label = card:Text(Money(keep), "small", keep >= 0 and "profit" or "loss", PAD, y, barWidth, "RIGHT")
            if keep < 0 then label:SetText(L.Format("%s, a loss", Money(keep))) end
        else
            card:Text(Money(part[2]), "small", "text", PAD, y, barWidth, "RIGHT")
        end
    end
end

--- Your listings: what sold, what came back, what you took down.
function Draw.listings(card, stats, width)
    local listings = stats.listings
    local judged = listings and (listings.sold + listings.expired + listings.cancelled) or 0
    if judged == 0 then
        card:Empty(L["Nothing listed yet. Your sales and returns show here as the mail comes in."])
        return
    end

    local lines = {
        { L["Sold"], listings.sold, "profit" },
        { L["Came back"], listings.expired, "loss" },
        { L["Taken down"], listings.cancelled, "dim" },
    }
    local most = math.max(listings.sold, listings.expired, listings.cancelled, 1)
    local barLeft = card:LabelColumn({ lines[1][1], lines[2][1], lines[3][1] }, HEADING_ROOM + 6, 18, 80, width)
    local barRoom = width - barLeft - PAD - 90
    local y = HEADING_ROOM + 6

    for _, line in ipairs(lines) do
        local r, g, b = Theme.Unpack(line[3])
        card:Row(barLeft, y + 1, math.max(1, line[2] / most * barRoom), 10, r, g, b, 0.85)
        card:Text(Count(line[2]), "small", "text", barLeft + barRoom + 6, y)
        y = y + 18
    end

    if listings.sellThrough then
        card:Text(Percent(listings.sellThrough), "title", "accentHi", width - PAD - 70, HEADING_ROOM + 4, 70, "RIGHT")
        card:Text(L["sold"], "tiny", "muted", width - PAD - 70, HEADING_ROOM + 24, 70, "RIGHT")
    end

    if listings.bestEach then
        y = y + 4
        local r, g, b = Theme.Unpack("gilt")
        card:Box(PAD, y + 3, 7, 7, r, g, b, 1)
        card:Text(L.Format("Best sale: %s each", Money(listings.bestEach)), "small", "gilt", PAD + 13, y)
    end
end

--- Sales by week, oldest on the left; the best week lit gold.
function Draw.weeks(card, stats, width, height, animate)
    local weeks = stats.weeks
    if not weeks then
        card:Empty(L["No sales yet. Each week you sell it shows here."])
        return
    end

    local count = #weeks
    local most = 1
    for _, week in ipairs(weeks) do most = math.max(most, week.net) end

    local plotTop = HEADING_ROOM + 18
    local plotBottom = height - 22
    local room = plotBottom - plotTop
    local slot = (width - PAD * 2) / count
    local barWidth = math.max(4, slot - 8)

    for index = count, 1, -1 do
        local week = weeks[index]
        local column = count - index
        local x = PAD + column * slot + (slot - barWidth) / 2
        local best = weeks.best == index
        if week.net > 0 then
            local tall = week.net / most * room
            if best then
                local r, g, b = Theme.Unpack("gilt")
                local glow = card:Box(x - 3, plotBottom - tall - 3, barWidth + 6, tall + 3, r, g, b, 0.18, "BACKGROUND")
                pcall(glow.SetBlendMode, glow, "ADD")
                card:Column(x, plotBottom, barWidth, tall, r, g, b, 1)
            else
                local r, g, b = Theme.Unpack("metal")
                card:Column(x, plotBottom, barWidth, tall, r, g, b, 0.9)
            end
        else
            local r, g, b = Theme.Unpack("border")
            card:Box(x, plotBottom - 1, barWidth, 1, r, g, b, 1)
        end
        card:Text(index == 1 and L["now"] or L.Format("%dw", index - 1), "tiny", best and "gilt" or "dim",
            x - 6, plotBottom + 4, barWidth + 12, "CENTER")
    end

    if weeks.best then
        local best = weeks[weeks.best]
        local words = weeks.best == 1 and L["Best week yet, this week"] or L["Best week"]
        card:Text(L.Format("%s: %s from %s sold", words, Money(best.net), Count(best.units)), "tiny", "gilt",
            PAD, HEADING_ROOM, width - PAD * 2)
    end
end

--- How many were listed at each of the last scans.
function Draw.stock(card, stats, width, height)
    local stock = stats.stock
    if #stock == 0 then
        card:Empty(L["Scan the auction house to see how many are listed."])
        return
    end

    local most = 1
    for _, reading in ipairs(stock) do most = math.max(most, reading.q) end

    local plotTop = HEADING_ROOM + 18
    local plotBottom = height - 12
    local room = plotBottom - plotTop
    local slot = (width - PAD * 2) / math.max(#stock, 6)
    local barWidth = math.max(4, slot - 6)

    for index, reading in ipairs(stock) do
        local x = PAD + (index - 1) * slot + (slot - barWidth) / 2
        local last = index == #stock
        local r, g, b = Theme.Unpack(last and "accent" or "metal")
        card:Column(x, plotBottom, barWidth, math.max(1, reading.q / most * room), r, g, b, last and 1 or 0.75)
    end

    local now = stock[#stock]
    card:Text(L.Format("%s listed at the last scan, %s at the most", Count(now.q), Count(most)), "tiny", "muted",
        PAD, HEADING_ROOM, width - PAD * 2)
end

local SOURCE_WORDS = {
    scans = L["Your scans"],
    guild = L["Your guild"],
    realm = L["Your realm"],
    tsm = "TradeSkillMaster",
    auctionator = "Auctionator",
    vendorPays = L["A vendor pays"],
    vendorSells = L["A vendor sells it for"],
}

--- The price each source gives, side by side.
function Draw.sources(card, stats, width)
    local sources = stats.sources or {}
    if #sources == 0 then
        card:Empty(L["No price from anywhere yet."])
        return
    end

    local most = 1
    for _, source in ipairs(sources) do most = math.max(most, source.value) end

    local words = {}
    for index, source in ipairs(sources) do words[index] = SOURCE_WORDS[source.key] or source.key end
    local barLeft = card:LabelColumn(words, HEADING_ROOM + 6, 17, 120, width)
    local barRoom = width - barLeft - PAD - 84
    local y = HEADING_ROOM + 6
    for _, source in ipairs(sources) do
        local vendor = source.key == "vendorPays" or source.key == "vendorSells"
        local r, g, b = Theme.Unpack(vendor and "border" or (source.key == "scans" and "accent" or "metal"))
        card:Row(barLeft, y + 2, math.max(1, source.value / most * barRoom), 9, r, g, b, 0.9)
        card:Text(Money(source.value), "small", "text", barLeft + barRoom + 4, y, 80, "RIGHT")
        y = y + 17
    end
end

--- The last ninety days: the day's cheapest price, and what sold.
function Draw.long(card, stats, width, height)
    local days = stats.days or {}
    if #days == 0 then
        card:Empty(L["Starts from today. Each day you scan adds a day here, up to ninety."])
        return
    end

    local today = math.floor(stats.now / DAY)
    local first = math.max(days[1].day, today - 89)
    local span = math.max(7, today - first + 1)
    local most, mostSold = 1, 1
    for _, entry in ipairs(days) do
        most = math.max(most, entry.cheapest or 0)
        mostSold = math.max(mostSold, entry.sold or 0)
    end

    local plotTop = HEADING_ROOM + 18
    local plotBottom = height - 26
    local room = plotBottom - plotTop
    local slot = (width - PAD * 2) / span
    local barWidth = math.max(1, slot - 1)

    for _, entry in ipairs(days) do
        local column = entry.day - (today - span + 1)
        if column >= 0 and column < span then
            local x = PAD + column * slot
            if entry.cheapest then
                local r, g, b = Theme.Unpack("accent")
                card:Column(x, plotBottom, barWidth, entry.cheapest / most * room, r, g, b, 0.75)
            end
            if (entry.sold or 0) > 0 then
                local r, g, b = Theme.Unpack("profit")
                card:Column(x, plotBottom + 14, barWidth, math.max(2, entry.sold / mostSold * 10), r, g, b, 0.9)
            end
        end
    end

    card:Text(L.Format("Cheapest each day, highest %s. Green below is what sold.", Money(most)), "tiny", "muted",
        PAD, HEADING_ROOM, width - PAD * 2)
    if #days < 7 then
        card:Text(L.Format("%d of 90 days saved so far", #days), "tiny", "dim", PAD, height - 12, width - PAD * 2, "RIGHT")
    end
end

--- How many sell it, how much the biggest holds, and yours.
function Draw.sellers(card, stats, width, height)
    local sellers = stats.sellers or {}
    local last = sellers[#sellers]
    if not last then
        card:Empty(L["Fills in from your next full scan of the auction house."])
        return
    end

    card:Text(Count(last.sellers), "title", "accentHi", PAD, HEADING_ROOM + 2)
    card:Text(last.sellers == 1 and L["seller at the last full scan"] or L["sellers at the last full scan"],
        "tiny", "muted", PAD + 34, HEADING_ROOM + 6, width - PAD * 2 - 34)

    local y = HEADING_ROOM + 30
    local lines = {
        { L["Biggest seller has"], last.top, "loss" },
        { L["You have"], last.yours, "profit" },
    }
    local barLeft = card:LabelColumn({ lines[1][1], lines[2][1] }, y, 17, 130, width)
    local barRoom = width - barLeft - PAD - 40
    for _, line in ipairs(lines) do
        local r, g, b = Theme.Unpack(line[3])
        local track = card:Box(barLeft, y + 2, barRoom, 9, Theme.Unpack("glassAlt"))
        track:SetDrawLayer("BORDER")
        card:Row(barLeft, y + 2, math.max(1, (line[2] or 0) / 100 * barRoom), 9, r, g, b, 0.9)
        card:Text(("%d%%"):format(line[2] or 0), "small", "text", barLeft + barRoom + 4, y, 36, "RIGHT")
        y = y + 17
    end

    -- How the count moved over the readings kept.
    if #sellers >= 2 then
        local most = 1
        for _, reading in ipairs(sellers) do most = math.max(most, reading.sellers or 0) end
        local bottom = height - 10
        local slot = (width - PAD * 2) / #sellers
        for index, reading in ipairs(sellers) do
            local r, g, b = Theme.Unpack(index == #sellers and "accent" or "metal")
            card:Column(PAD + (index - 1) * slot, bottom, math.max(2, slot - 3),
                math.max(1, (reading.sellers or 0) / most * (bottom - y - 6)), r, g, b, 0.7)
        end
    end
end

local SPEED_WORDS = { L["Under 2 hours"], L["2 to 8 hours"], L["8 to 24 hours"], L["Longer"] }

--- How long your listings took to sell.
function Draw.speed(card, stats, width)
    local times = stats.sellTimes
    if not times then
        card:Empty(L["Fills in as your listings sell, from today on."])
        return
    end

    local most, total = 1, 0
    for _, count in ipairs(times) do most, total = math.max(most, count), total + count end

    local words = {}
    for index in ipairs(times) do words[index] = SPEED_WORDS[index] end
    local barLeft = card:LabelColumn(words, HEADING_ROOM + 6, 17, 100, width)
    local barRoom = width - barLeft - PAD - 40
    local y = HEADING_ROOM + 6
    local colours = { "profit", "accent", "warn", "loss" }
    for index, count in ipairs(times) do
        local r, g, b = Theme.Unpack(colours[index])
        card:Row(barLeft, y + 2, math.max(1, count / most * barRoom), 9, r, g, b, 0.9)
        card:Text(Count(count), "small", "text", barLeft + barRoom + 4, y, 36, "RIGHT")
        y = y + 17
    end
    card:Text(L.Format("%s sales timed", Count(total)), "tiny", "dim", PAD, y + 2, width - PAD * 2, "RIGHT")
end

local METHOD_WORDS = {}
for _, method in ipairs(ns.MethodProfit and ns.MethodProfit.METHODS or {}) do
    METHOD_WORDS[method.key] = method.text
end

--- Money it made in the last 30 days, by how.
function Draw.methods(card, stats, width)
    local methods = stats.methods
    if not methods then
        card:Empty(L["Nothing sold in the last 30 days."])
        return
    end

    local most = 1
    for _, method in ipairs(methods) do most = math.max(most, math.abs(method.profit)) end

    local barLeft = PAD + 96
    local barRoom = width - barLeft - PAD - 96
    local y = HEADING_ROOM + 6
    for _, method in ipairs(methods) do
        card:Text(METHOD_WORDS[method.key] or method.key, "small", "muted", PAD, y)
        local r, g, b = Theme.Unpack(method.profit >= 0 and "profit" or "loss")
        card:Row(barLeft, y + 2, math.max(1, math.abs(method.profit) / most * barRoom), 9, r, g, b, 0.85)
        card:Text(Money(method.profit), "small", method.profit >= 0 and "profit" or "loss",
            barLeft + barRoom + 4, y, 92, "RIGHT")
        y = y + 17
    end
end

-- In the order they are placed, after the price graph.
-- Each card's hover says what it shows (a player asked what the cards mean).
local CARDS = {
    { key = "heat",     heading = L["CHEAPEST TIMES THIS WEEK"], height = 150,
      hint = L["Green squares are the cheapest times of day and gold ones the dearest. Buy in the green and sell in the gold."] },
    { key = "cost",     heading = L["WHERE EACH SALE GOES"],     height = 142,
      hint = L["What one sale pays, split into the materials, the auction house's cut, the deposit and what you keep."] },
    { key = "weeks",    heading = L["SALES BY WEEK"],            height = 150,
      hint = L["How much gold this item made you each week."] },
    { key = "listings", heading = L["YOUR LISTINGS"],            height = 124,
      hint = L["How many of your auctions sold, came back or were taken down."] },
    { key = "long",     heading = L["LAST 90 DAYS"],             height = 142,
      hint = L["The price over the last three months, to see if it's going up or down."] },
    { key = "stock",    heading = L["LISTED AT EACH SCAN"],      height = 124,
      hint = L["How many were up for sale each time you scanned."] },
    { key = "sellers",  heading = L["WHO ELSE SELLS IT"],        height = 142,
      hint = L["How many others sold it at your last full scan, and how many the biggest seller had next to yours."] },
    { key = "sources",  heading = L["PRICE BY SOURCE"],          height = 142,
      hint = L["The price each place gives, such as your scans, your guild or a vendor."] },
    { key = "speed",    heading = L["HOW FAST YOURS SELL"],      height = 124,
      hint = L["How long your auctions take to sell, from when you post them."] },
    { key = "methods",  heading = L["LAST 30 DAYS BY METHOD"],   height = 124,
      hint = L["What this item made you in the last 30 days, by how you got it: crafted, farmed, flipped and more."] },
}

local GRAPH_HEIGHT = 180

--- A card's hover: its heading, then what it shows.
function StatsUI.ShowHint(card)
    if not card or not card.hint then return end
    GameTooltip:SetOwner(card, "ANCHOR_TOP")
    if card.heading and card.heading.GetText then
        GameTooltip:AddLine(card.heading:GetText(), Theme.Unpack("accentHi"))
    end
    GameTooltip:AddLine(card.hint, 0.85, 0.85, 0.85, true)
    GameTooltip:Show()
end
StatsUI.CARDS = CARDS

--------------------------------------------------------------------------------
-- The header
--------------------------------------------------------------------------------

StatsUI.BAR_WIDTH = 44

--- The lines the Sold a day tile's hover shows: what the market wants,
--- then your own listings. Each { left, right } or { left } alone.
function StatsUI.MarketLines(stats)
    local lines = {}
    local market = stats and stats.market
    if market then
        if market.perDay then
            lines[#lines + 1] = { L["Sells a day"], market.perDay < 1 and L["under 1"]
                or L.Format("about %s", Count(market.perDay)) }
        end
        if market.listed then
            lines[#lines + 1] = { L["Up for sale now"], Count(market.listed) }
        end
        lines[#lines + 1] = { L["Stock that sells a day"], Percent(market.share) }
        if market.daysToSell then
            local days = market.daysToSell
            lines[#lines + 1] = { L["Time to sell what's up"], days < 1 and L["under a day"]
                or days < 1.5 and L["about 1 day"]
                or L.Format("about %d days", math.floor(days + 0.5)) }
        elseif market.listed and market.listed > 0 and market.perDay == 0 then
            lines[#lines + 1] = { L["Time to sell what's up"], L["none sold yet"] }
        end
    end

    local listings = stats and stats.listings
    local ended = listings and (listings.sold or 0) + (listings.expired or 0) or 0
    if ended > 0 then
        lines[#lines + 1] = { L["Your own listings"], L.Format("%d of %d sold", listings.sold or 0, ended) }
    end
    return lines
end

local function ShowMarket(tile)
    local lines = StatsUI.MarketLines(tile.stats)
    if #lines == 0 then return end
    GameTooltip:SetOwner(tile, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(L["What the market wants"], Theme.Unpack("accentHi"))
    for _, line in ipairs(lines) do
        GameTooltip:AddDoubleLine(line[1], line[2], 0.85, 0.85, 0.85, 1, 1, 1)
    end
    GameTooltip:AddLine(L["From your auction scans."], 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

local function AddMarketBar(tile)
    local bar = tile:CreateTexture(nil, "ARTWORK")
    bar:SetSize(StatsUI.BAR_WIDTH, 4)
    bar:SetPoint("TOPRIGHT", tile, "TOPRIGHT", -8, -26)
    bar:SetColorTexture(1, 1, 1, 0.12)
    bar.fill = tile:CreateTexture(nil, "OVERLAY")
    bar.fill:SetHeight(4)
    bar.fill:SetPoint("LEFT", bar, "LEFT", 0, 0)
    bar:Hide()
    bar.fill:Hide()
    tile.bar = bar

    tile:EnableMouse(true)
    tile:SetScript("OnEnter", ShowMarket)
    tile:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function CreateTile(parent, title, market)
    local tile = Theme.CreatePanel(parent, "glass", "border")
    tile:SetHeight(KPI_HEIGHT)
    Theme.TopSheen(tile)

    tile.title = Theme.CreateLabel(tile, "tiny", "muted")
    tile.title:SetPoint("TOPLEFT", 8, -6)
    tile.title:SetText(title)

    tile.value = Theme.CreateLabel(tile, "large", "text")
    tile.value:SetPoint("TOPLEFT", 8, -19)
    tile.value:SetPoint("RIGHT", -8, 0)

    tile.note = Theme.CreateLabel(tile, "tiny", "dim")
    tile.note:SetPoint("BOTTOMLEFT", 8, 5)
    tile.note:SetPoint("RIGHT", -8, 0)
    if market then AddMarketBar(tile) end
    return tile
end

local function FillTiles(stats)
    local tiles = widgets.tiles

    tiles[1].value:SetText(Money(stats.worth))
    if stats.change then
        local up = stats.change >= 0
        local change = Percent(math.abs(stats.change))
        tiles[1].note:SetText(up and L.Format("up %s from a week ago", change)
            or L.Format("down %s from a week ago", change))
        tiles[1].note:SetTextColor(Theme.Unpack(up and "profit" or "loss"))
    else
        tiles[1].note:SetText(L["no price from a week ago yet"])
        tiles[1].note:SetTextColor(Theme.Unpack("dim"))
    end

    local craft = stats.craft
    if craft and craft.profitEach then
        tiles[2].value:SetText(Money(craft.profitEach))
        tiles[2].value:SetTextColor(Theme.ProfitColor(craft.profitEach))
        tiles[2].note:SetText(L.Format("costs %s to make", Money(craft.costEach)))
    else
        tiles[2].value:SetText(Money(nil))
        tiles[2].value:SetTextColor(Theme.Unpack("text"))
        tiles[2].note:SetText(craft and L["no price for it yet"] or L["you don't craft this"])
    end
    tiles[2].note:SetTextColor(Theme.Unpack("dim"))

    if stats.soldPerDay then
        tiles[3].value:SetText(("%.1f"):format(stats.soldPerDay))
    else
        tiles[3].value:SetText(Money(nil))
    end
    -- What the market does, as a number (a player asked, 2026-10-16), with a
    -- bar for the share; your own sales only when no scan says yet.
    local market, demand = stats.market, stats.demand
    local bar = tiles[3].bar
    if market then
        local color = ns.Demand and ns.Demand:Color({ level = market.level }) or "text"
        tiles[3].note:SetText(L.Format("%s of stock sells a day", Percent(market.share)))
        tiles[3].note:SetTextColor(Theme.Unpack(color))
        bar.fill:SetColorTexture(Theme.Unpack(color))
        bar.fill:SetWidth(math.max(1, StatsUI.BAR_WIDTH * math.min(1, market.share)))
        bar:Show()
        bar.fill:Show()
    elseif demand and ns.Demand and ns.Demand.Describe then
        tiles[3].note:SetText(ns.Demand:Describe(demand))
        tiles[3].note:SetTextColor(Theme.Unpack(ns.Demand:Color(demand)))
        bar:Hide()
        bar.fill:Hide()
    else
        tiles[3].note:SetText(L["by your scans"])
        tiles[3].note:SetTextColor(Theme.Unpack("dim"))
        bar:Hide()
        bar.fill:Hide()
    end
    tiles[3].stats = stats

    local week = stats.week
    tiles[4].value:SetText(Count(week and week.sold or 0))
    if week and (week.expired or 0) > 0 then
        tiles[4].note:SetText(L.Format("%s came back", Count(week.expired)))
    else
        tiles[4].note:SetText(L["in the last 7 days"])
    end
    tiles[4].note:SetTextColor(Theme.Unpack("dim"))
end

--------------------------------------------------------------------------------
-- Laying out and drawing
--------------------------------------------------------------------------------

--- Place the tiles and the cards for the width the panel has.
local function Layout()
    local panel = widgets.panel
    local width = panel:GetWidth() or 0
    if width <= 0 then return false end

    local tileWidth = (width - PAD * 2 - GAP * 3) / 4
    for index, tile in ipairs(widgets.tiles) do
        tile:ClearAllPoints()
        tile:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + (index - 1) * (tileWidth + GAP), -(HEADER_HEIGHT + 4))
        tile:SetWidth(tileWidth)
    end

    local scroll = widgets.scroll
    local inner = (scroll:GetWidth() or width) - 12
    if inner <= 0 then inner = width - PAD * 2 - 12 end
    scroll.content:SetWidth(inner)

    widgets.graphCard:ClearAllPoints()
    widgets.graphCard:SetPoint("TOPLEFT", scroll.content, "TOPLEFT", 0, 0)
    widgets.graphCard:SetSize(inner, GRAPH_HEIGHT)

    local column = (inner - GAP) / 2
    local heights = { GRAPH_HEIGHT + GAP, GRAPH_HEIGHT + GAP }
    for _, definition in ipairs(CARDS) do
        local card = widgets.cards[definition.key]
        local side = heights[1] <= heights[2] and 1 or 2
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", scroll.content, "TOPLEFT", (side - 1) * (column + GAP), -heights[side])
        card:SetSize(column, definition.height)
        card.width = column
        heights[side] = heights[side] + definition.height + GAP
    end

    scroll.content:SetHeight(math.max(heights[1], heights[2]))
    if scroll.UpdateRange then scroll:UpdateRange() end
    widgets.laidOutAt = width
    return true
end

--- Cheer a best week, once a week for each item.
local function MaybeCheer(stats)
    local weeks = stats.weeks
    if not weeks or weeks.best ~= 1 then return end
    if ns.Config and ns.Config:Get("statsCheer") == false then return end

    local others = 0
    for index = 2, #weeks do if weeks[index].net > 0 then others = others + 1 end end
    if others == 0 then return end

    local week = ns.ItemStats.WeekOf(stats.now)
    if not ns.StatsLog or ns.StatsLog:Cheered(stats.itemID, week) then return end
    ns.StatsLog:SetCheered(stats.itemID, week)

    if type(PlaySound) == "function" then
        local kit = type(SOUNDKIT) == "table" and SOUNDKIT.IG_QUEST_LIST_COMPLETE or 878
        pcall(PlaySound, kit, "Master")
    end

    local card = widgets.cards.weeks
    if card and card.haloTextures and ns.Motion then
        ns.Motion:Run(card, "cheer", 1.4, function(p)
            Theme.SetHalo(card, 0.5 * (1 - p), "gilt")
        end)
    end
end

--- Draw the item picked; `animate` grows the bars in.
local function Draw_(animate)
    local stats = state.stats
    local panel = widgets.panel
    local shown = stats ~= nil and stats.itemID ~= nil

    panel.empty:SetShown(not shown)
    panel.name:SetShown(shown)
    panel.icon:SetShown(shown)
    panel.sub:SetShown(shown)
    panel.ahButton:SetShown(shown)
    for _, tile in ipairs(widgets.tiles) do tile:SetShown(shown) end
    widgets.scroll:SetShown(shown)
    if not shown then return end

    if widgets.laidOutAt ~= panel:GetWidth() then Layout() end

    local itemID = stats.itemID
    Theme.SetItemIcon(panel.icon, itemID)
    Theme.SetRowName(panel.name, Util.GetItemLabel(itemID))

    local bits = {}
    if stats.craft then bits[#bits + 1] = L["You craft this"] end
    if ns.Prices and ns.Prices.IsFavourite and ns.Prices:IsFavourite(itemID) then bits[#bits + 1] = L["starred"] end
    local age = ns.Prices and ns.Prices.GetAge and ns.Prices:GetAge(itemID)
    if age then
        bits[#bits + 1] = L.Format("scanned %s", Util.FormatAgeAgo(age))
    else
        bits[#bits + 1] = L["not scanned yet"]
    end
    panel.sub:SetText(table.concat(bits, "  ·  "))

    FillTiles(stats)

    if widgets.graph then widgets.graph:SetItem(itemID) end

    for _, definition in ipairs(CARDS) do
        local card = widgets.cards[definition.key]
        card:Reset()
        local ok, err = pcall(Draw[definition.key], card, stats, card.width or 300, definition.height, animate)
        if not ok then
            card:Reset()
            card:Empty(L["This chart could not be drawn."])
            if ns.Debug then ns.Debug("stats card", definition.key, tostring(err)) end
        end
        card:Grow(animate)
    end

    MaybeCheer(stats)
end

--- Build again when what it reads moved, and draw.
local function Redraw(animate)
    if not widgets.panel then return end
    local itemID = state.selected
    if not itemID then
        state.stats, state.key = nil, nil
        Draw_(false)
        return
    end

    -- Bars grow in when an item is picked and when the tab opens.
    animate = animate or state.grow
    state.grow = nil

    local key = ns.ItemStats:Key(itemID)
    if key == state.key and state.stats and not animate then return end
    state.key = key
    state.stats = ns.ItemStats:Build(itemID)
    Draw_(animate)
end

local function Select(itemID)
    state.selected = itemID
    state.key = nil
    if widgets.list then widgets.list:Refresh() end
    Redraw(true)
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function BuildPanel(container)
    local panel = Theme.CreatePanel(container, "window")
    Theme.AccentStripe(panel, 2, 0.6)
    widgets.panel = panel

    panel.icon = Theme.CreateItemIcon(panel, 34)
    panel.icon:SetPoint("TOPLEFT", PAD + 2, -10)
    if Widgets.ItemHotspot then Widgets.ItemHotspot(panel.icon) end

    panel.name = Theme.CreateLabel(panel, "title", "accentHi")
    panel.name:SetPoint("TOPLEFT", PAD + 46, -11)
    panel.name:SetPoint("RIGHT", panel, "RIGHT", -140, 0)

    panel.sub = Theme.CreateLabel(panel, "tiny", "muted")
    panel.sub:SetPoint("TOPLEFT", panel.name, "BOTTOMLEFT", 0, -5)
    panel.sub:SetPoint("RIGHT", panel, "RIGHT", -140, 0)

    panel.ahButton = Widgets.CreateButton(panel, L["Search AH"], function()
        if state.selected then UI:SearchAuctionHouse(state.selected) end
    end, { width = 110, height = 22, tooltip = L["Search the auction house for this item"] })
    panel.ahButton:SetPoint("TOPRIGHT", -PAD, -12)

    widgets.tiles = {
        CreateTile(panel, L["WORTH NOW"]),
        CreateTile(panel, L["PROFIT EACH"]),
        CreateTile(panel, L["SOLD A DAY"], true),
        CreateTile(panel, L["YOU SOLD THIS WEEK"]),
    }

    local scroll = Widgets.CreateScrollFrame(panel, { step = 60 })
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -(HEADER_HEIGHT + KPI_HEIGHT + 12))
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD - 8, PAD)
    widgets.scroll = scroll

    local graphCard = Theme.CreatePanel(scroll.content, "glass", "border")
    widgets.graphCard = graphCard
    if ns.PriceGraph then
        local graph = ns.PriceGraph.Create(graphCard, { heading = L["PRICE, HOUR BY HOUR"], ticks = true })
        graph:SetPoint("TOPLEFT", PAD, -8)
        graph:SetPoint("BOTTOMRIGHT", -PAD, 8)
        widgets.graph = graph
    end

    widgets.cards = {}
    for _, definition in ipairs(CARDS) do
        local card = CreateCard(scroll.content, definition.heading, definition.height)
        Theme.Halo(card, 6, 0, "gilt")
        card.hint = definition.hint
        card:EnableMouse(true)
        card:SetScript("OnEnter", StatsUI.ShowHint)
        card:SetScript("OnLeave", function() GameTooltip:Hide() end)
        widgets.cards[definition.key] = card
    end

    panel.empty = Theme.CreateLabel(panel, "small", "dim", "CENTER")
    panel.empty:SetPoint("CENTER")
    panel.empty:SetWidth(360)
    panel.empty:SetWordWrap(true)
    panel.empty:SetText(L["Pick an item on the left to see its charts."])

    panel:SetScript("OnSizeChanged", function()
        widgets.laidOutAt = nil
        if state.stats then Draw_(false) end
    end)

    return panel
end

--- What the list is built from, so a refresh that moved none of it (a
--- craft, a post) keeps the rows it has: the search, the ledger, the
--- prices, the stars and every character's recipes.
local function ListKey()
    local ledger = ns.Mail and ns.Mail.GetLedger and select(2, pcall(ns.Mail.GetLedger, ns.Mail))
    local entries = type(ledger) == "table" and type(ledger.entries) == "table" and ledger.entries or {}
    local last = entries[#entries]
    local stars = 0
    local favourites = ns.Prices and ns.Prices.GetFavourites and ns.Prices:GetFavourites() or {}
    for _ in pairs(favourites) do stars = stars + 1 end
    local recipes = 0
    for _, record in pairs(ns.db and type(ns.db.characters) == "table" and ns.db.characters or {}) do
        if type(record) == "table" and type(record.recipesCachedAt) == "number" then
            recipes = recipes + record.recipesCachedAt
        end
    end
    return table.concat({ state.search or "", #entries, type(last) == "table" and tostring(last.t) or "",
        tostring(ns.Prices and ns.Prices.changes or 0), stars, recipes,
        -- And the day, so "the last 30 days" moves on.
        math.floor(time() / DAY) }, "\1")
end

local function RefreshList()
    if not widgets.list then return end
    local key = ListKey()
    if key == widgets.listKey then return end
    widgets.listKey = key
    local rows = BuildList(state.search)
    widgets.list:SetData(rows)
    widgets.emptyLabel:SetShown(#rows == 0)
    widgets.emptyLabel:SetText(state.search ~= "" and L["Nothing matches that search."]
        or L["Nothing to show yet. Items you craft, star or sell show here."])
    if state.search ~= "" then
        if Widgets.EmptyAction then Widgets.EmptyAction(widgets.emptyLabel, L["Clear Search"], function() widgets.search:SetText("") end) end
    elseif Widgets.EmptyAction then Widgets.EmptyAction(widgets.emptyLabel, nil) end

    if not state.selected and rows[1] then Select(rows[1].itemID) end
end

local function Build(container)
    local search = Widgets.CreateSearchBox(container, L["Search items"], function(text)
        state.search = text or ""
        RefreshList()
        if widgets.list then widgets.list:ScrollToTop() end
    end)
    search:SetPoint("TOPLEFT", 8, -8)
    search:SetWidth(LIST_WIDTH)
    widgets.search = search

    local list = Widgets.CreateScrollList(container, {
        rowHeight = ROW_HEIGHT,
        createRow = CreateRow,
        updateRow = UpdateRow,
        onEnter = function(row, entry) Widgets.ShowItemOnly(row, entry.itemID, entry.label) end,
        onLeave = function() GameTooltip:Hide() end,
        isSelected = function(entry) return entry.itemID == state.selected end,
        onClick = function(entry) Select(entry.itemID) end,
    })
    list:SetPoint("TOPLEFT", search, "BOTTOMLEFT", 0, -8)
    list:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 8, 8)
    list:SetWidth(LIST_WIDTH)
    widgets.list = list

    local emptyLabel = Theme.CreateLabel(container, "small", "dim", "CENTER")
    emptyLabel:SetPoint("TOP", list, "TOP", 0, -30)
    emptyLabel:SetWidth(LIST_WIDTH - 20)
    emptyLabel:SetWordWrap(true)
    widgets.emptyLabel = emptyLabel
    if Widgets.DressEmpty then Widgets.DressEmpty(emptyLabel) end

    local panel = BuildPanel(container)
    panel:SetPoint("TOPLEFT", container, "TOPLEFT", LIST_WIDTH + 24, -8)
    panel:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -8, 8)
end

--- Called by the window whenever something moved: the list now, the
--- charts a moment later, once.
local function Refresh()
    if not widgets.list then return end
    RefreshList()

    -- Opened just now: drawn at once.
    if not state.key then
        Redraw(false)
        return
    end

    if StatsUI.pending then return end
    StatsUI.pending = true
    local function Later()
        StatsUI.pending = nil
        if StatsUI.Showing() then Redraw(false) end
    end
    if C_Timer and C_Timer.After then C_Timer.After(REDRAW_DELAY, Later) else Later() end
end

--- True while the Prices tab shows its Stats view.
function StatsUI.Showing()
    local Prices = ns.PricesUI
    if Prices and Prices.ShowingStats then return Prices:ShowingStats() end
    return UI.activeTab == "stats"
end

--- Pick an item for the charts, when one is given (the Details view's pick).
function StatsUI:Pick(itemID)
    if not itemID or itemID == state.selected then return end
    state.selected = itemID
    state.key = nil
    if widgets.list then Select(itemID) end
end

--- Open the window on the Prices tab's Stats view, at `itemID` when given.
function StatsUI:ShowItem(itemID)
    if itemID then
        state.selected = itemID
        state.key = nil
    end
    UI:Show()
    UI:SelectTab("prices")
    if ns.PricesUI then ns.PricesUI:ShowView("stats", itemID) end
    if itemID then Select(itemID) end
end

--- `/bts stats [item]`: an item link, ID or name, else the tab as it was.
function StatsUI.ItemFromText(text)
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end

    local linked = tonumber(text:match("item:(%d+)"))
    if linked then return linked end
    if tonumber(text) then return tonumber(text) end

    local rows = BuildList(text)
    local wanted = text:lower()
    for _, row in ipairs(rows) do
        if row.name:lower() == wanted then return row.itemID end
    end
    return rows[1] and rows[1].itemID or nil
end

ns.RegisterCommand("stats", L["open an item's charts, the one you name or link"], function(rest)
    local itemID = StatsUI.ItemFromText(rest)
    if rest and rest:match("%S") and not itemID then
        ns.Print(L["No item by that name to show."])
    end
    StatsUI:ShowItem(itemID)
end)

-- Its own tab until 2026-10-29; now the Prices tab's Stats view
-- (UI/Tab_Prices.lua builds it).
StatsUI.view = {
    key = "stats",
    build = Build,
    refresh = Refresh,
    onShow = function()
        state.key = nil
        state.grow = true
    end,
}
