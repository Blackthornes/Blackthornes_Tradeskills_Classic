-- Blackthornes Tradeskills -- UI/ItemTooltip.lua
-- What an item is worth on the auction house, on the item's own tooltip.
--
-- The Profit tab answers "what should I make", and UI/RecipeValue.lua answers
-- "what does this recipe sell for" in the profession window. This answers the
-- same question about a thing you are already pointing at: a stack in your
-- bags, a reagent on a vendor's list, a link somebody pasted in chat.
--
-- Two things shape every decision below.
--
-- **The hook is not assumed.** Retail grew a data-driven tooltip system
-- (`TooltipDataProcessor`) in 10.0 and the older `OnTooltipSetItem` script is
-- gone there; Classic still has the script and nothing else. This client has
-- retail's auction and profession APIs on a 1.60 interface number, so it is
-- not safely either one. Every shape known to work is installed, whichever of
-- them the client actually fires does the work, and `/bts tip` reports which
-- one fired and how many tooltips have actually carried a value -- not which
-- hook was installed, because a hook that never fires installs perfectly.
--
-- **Answered in game 2026-09-22: it is `TooltipDataProcessor`**, 113 tooltips
-- in one session, with the other two installed alongside and never firing.
-- They stay installed anyway -- that is one measurement on one build, and the
-- guard below already makes carrying them free.
--
-- **A price is not the same claim as no price.** An item nothing has been seen
-- selling for prints "not scanned yet", never a zero and never silence: on a
-- crowded recipe row silence is the only option, but a tooltip has room to say
-- which of the two it means. That line is held back for items that cannot be
-- auctioned at all -- soulbound gear, quest items -- so hovering your own
-- equipment does not produce a running commentary about the auction house.
--
-- Blizzard's tooltips are hooked and appended to. None is assigned to and no
-- field of ours is written onto one: what has already been decorated lives in
-- a weak table keyed by the tooltip.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local ItemTooltip = ns.NewModule("ItemTooltip")

local Util = ns.Util

-- Tooltips worth decorating by name, for the clients where hooking is done
-- per frame. GameTooltip covers bags, bank, merchants, the auction house and
-- the character sheet; ItemRefTooltip is the one a chat link opens.
local TOOLTIP_NAMES = { "GameTooltip", "ItemRefTooltip" }

-- Blizzard's item class for quest items, which have no auction value by
-- definition. Read from Enum when the client offers it; this is the fallback.
local CLASS_QUEST = 12

-- `bindType` 1 is bind-on-pickup. Anything carrying it in a bag is already
-- bound and cannot be listed.
local BIND_ON_PICKUP = 1

-- A price older than the "stale" setting still gets shown -- it is the best
-- anyone has -- but it says how old it is, because acting on a week-old price
-- is a different decision from acting on this morning's.
local STALE_COLOR = "muted"

--------------------------------------------------------------------------------
-- Talking to frames that may not answer
--------------------------------------------------------------------------------

-- Same pair as UI/RecipeValue.lua, and for the same reason: a missing method
-- on this client raises rather than returning nil, and a bare
-- `select(2, pcall(...))` hands back the *error message*, which is truthy.

local function Try(fn, ...)
    if type(fn) ~= "function" then return nil end

    local ok, value = pcall(fn, ...)
    if ok then return value end

    return nil
end

local function Index(object, key) return object[key] end

local function Field(object, key)
    if type(object) ~= "table" then return nil end

    -- A named function rather than a new one per read: this runs for every
    -- field asked of every tooltip, each time the game redraws it.
    local ok, value = pcall(Index, object, key)
    if not ok then return nil end

    return value
end

--------------------------------------------------------------------------------
-- The setting
--------------------------------------------------------------------------------

--- Is the decoration switched on?
--
-- `~= false` rather than `== true`: a setting never written is nil, and this
-- one is on by default.
function ItemTooltip:IsEnabled()
    if not ns.Config then return true end
    return ns.Config:Get("showValueOnItemTooltips") ~= false
end

-- Off, Shift or Always for each line (asked 2026-10-18, UI/TooltipShift.lua).
-- Tradeskills keeps settings in Config, so each line's Shift choice is a
-- setting of its own (never rename them). The sales lines have no Off: their
-- Shift choice is the tick box they always had, `tooltipSalesShift`.
ItemTooltip.SHIFT_SETTINGS = {
    value   = "tooltipValueShift",
    sales   = "tooltipSalesShift",
    trend   = "tooltipTrendShift",
    recipe  = "tooltipRecipeShift",
    enchant = "tooltipEnchantShift",
    crate   = "tooltipCrateShift",
    disenchant = "tooltipDisenchantShift",
}

local TooltipShift = ns.TooltipShift
if TooltipShift then
    TooltipShift.KEYS = { "value", "sales", "trend", "recipe", "enchant", "crate", "disenchant" }

    function TooltipShift.Read(key)
        local name = ItemTooltip.SHIFT_SETTINGS[key]
        return name ~= nil and ns.Config ~= nil and ns.Config:Get(name) == true
    end

    function TooltipShift.Write(key, on)
        local name = ItemTooltip.SHIFT_SETTINGS[key]
        if name and ns.Config then ns.Config:Set(name, on and true or false) end
    end
end

-- A crate's Shift lines (Crate on the AH, You Have, Next Best) show while
-- Shift is held even with its lines on Always, so Shift redraws a tooltip
-- holding them back too.
if TooltipShift then
    local anyShift = TooltipShift.AnyShift
    function TooltipShift:AnyShift()
        if ItemTooltip.crateHeld then return true end
        return anyShift(self)
    end
end

--- May this line go on the tooltip now? Asked each time a tooltip is built.
function ItemTooltip.Shows(key)
    local shift = ns.TooltipShift
    if shift then return shift:Shows(key) end
    -- Without the shared file (a test loading this one alone): the sales
    -- lines' tick box as it always worked, the rest always.
    if key ~= "sales" then return true end
    if not (ns.Config and ns.Config:Get("tooltipSalesShift") == true) then return true end
    local ok, down = pcall(function() return IsShiftKeyDown and IsShiftKeyDown() end)
    return ok and down == true
end

--------------------------------------------------------------------------------
-- Which item a tooltip is showing
--------------------------------------------------------------------------------

--- A positive item ID as a plain number, or nil.
-- type() says "number" even for a value the game will not let the addon read,
-- and the first comparison or table lookup with one raises. So the test and
-- a copy happen inside a pcall.
local function PlainID(value)
    if type(value) ~= "number" then return nil end
    local ok, id = pcall(function() if value > 0 then return value + 0 end end)
    if ok then return id end
    return nil
end
ItemTooltip.PlainID = PlainID

--- The item ID inside an item link, or nil.
--
-- A link is `|cff...|Hitem:2589:0:0:...|h[Linen Cloth]|h|r`. Matching on the
-- `item:` prefix rather than the first run of digits keeps the colour code out
-- of it, and refuses a spell or enchant link outright rather than reading its
-- ID as an item's.
function ItemTooltip.ItemIDFromLink(link)
    if type(link) ~= "string" then return nil end

    -- Matched inside a pcall: a link the game will not let the addon read (a
    -- tooltip in a dungeon) raises when matched, and is simply no item.
    local ok, id = pcall(function()
        return link:match("|Hitem:(%d+)") or link:match("^item:(%d+)")
    end)
    if not ok or not id then return nil end

    return tonumber(id)
end

--- The item a tooltip is currently describing.
--
-- Three ways, because which of them exists is exactly what is unknown about
-- this client:
--   * the data table a modern post-call is handed, which carries the ID
--   * `TooltipUtil.GetDisplayedItem`, retail's replacement for GetItem
--   * `tooltip:GetItem()`, which Classic still has
--
-- Both of the last two answer `name, link` and the first of those is no use
-- here, so they are called through pcall rather than Try -- Try forwards one
-- return value, and taking the first of a pair would read the item's *name*
-- as its link and find no item at all. That is what this looks like in game:
-- an addon that loads, hooks everything, and decorates nothing.
function ItemTooltip:ItemForTooltip(tooltip, data)
    local fromData = PlainID(Field(data, "id"))
    if fromData then return fromData end

    local displayed = Field(_G.TooltipUtil, "GetDisplayedItem")

    if type(displayed) == "function" then
        local ok, _, link, id = pcall(displayed, tooltip)

        if ok then
            local plainID = PlainID(id)
            if plainID then return plainID end

            local fromLink = self.ItemIDFromLink(link)
            if fromLink then return fromLink end
        end
    end

    local getItem = Field(tooltip, "GetItem")

    if type(getItem) == "function" then
        local ok, _, link = pcall(getItem, tooltip)

        if ok then
            local fromGetItem = self.ItemIDFromLink(link)
            if fromGetItem then return fromGetItem end
        end
    end

    return nil
end

--- The link of the copy a tooltip shows, or nil. Only asked for its random
--- suffix ("of the Monkey"), so a copy is priced as the copy it is.
function ItemTooltip:LinkForTooltip(tooltip, data)
    local fromData = Field(data, "hyperlink")
    if type(fromData) == "string" then return fromData end

    for _, getter in ipairs({ Field(_G.TooltipUtil, "GetDisplayedItem"), Field(tooltip, "GetItem") }) do
        if type(getter) == "function" then
            local ok, _, link = pcall(getter, tooltip)
            if ok and type(link) == "string" then return link end
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- How many of it
--------------------------------------------------------------------------------

--- How many sit in this bag slot, or nil for one (or none we can read).
--
-- The tooltip itself does not carry the count -- only the call that was handed
-- a bag and a slot knows it -- which is why `SetBagItem` is hooked even on a
-- client where something else is doing the decorating.
function ItemTooltip.StackCountIn(bag, slot)
    local container = _G.C_Container

    local get = Field(container, "GetContainerItemInfo")
    if type(get) ~= "function" then return nil end

    -- Called through pcall directly rather than Try, which forwards only the
    -- first return value and would throw the legacy signature's count away.
    local ok, first, second = pcall(get, bag, slot)
    if not ok then return nil end

    -- Modern: one table, with the count on it. Older: a list, count second.
    local count = Field(first, "stackCount")
    if type(count) ~= "number" then count = second end

    if type(count) ~= "number" or count <= 1 then return nil end

    return count
end

--------------------------------------------------------------------------------
-- What to say
--------------------------------------------------------------------------------

--- Could this item be sold at auction at all?
--
-- Only used to decide whether *silence* or *"not scanned yet"* is the honest
-- answer for an item with no price. Getting it wrong costs a line of noise on
-- a tooltip, never a wrong number.
--
-- An item the client has not cached yet answers nil, and nil is treated as
-- "do not say anything": the next hover has the data and can speak then.
function ItemTooltip.IsAuctionable(itemID)
    if not itemID then return nil end
    if not Util.HasFunction("C_Item.GetItemInfo") then return nil end

    local ok, name, _, _, _, _, _, _, _, _, _, _, classID, _, bindType =
        pcall(C_Item.GetItemInfo, itemID)

    if not ok or not name then return nil end

    local questClass = CLASS_QUEST
    local enum = _G.Enum
    local itemClass = Field(enum, "ItemClass")
    local fromEnum = Field(itemClass, "Questitem") or Field(itemClass, "QuestItem")
    if type(fromEnum) == "number" then questClass = fromEnum end

    if classID == questClass then return false end
    if bindType == BIND_ON_PICKUP then return false end

    return true
end

--- The lines to append for one item, in order.
--
-- Each is `{ label, value, muted }`. Returning an empty list means "say
-- nothing at all", which is a different outcome from a list holding the
-- not-scanned line, and the diagnostic counts them separately.
--
-- The value is the smoothed market value of one unit -- the same number
-- UI/RecipeValue.lua puts beside a recipe -- rather than the cheapest current
-- listing. "What is this worth" is the question a tooltip is asked; what it
-- would cost to buy one right now is a question asked at the auction house,
-- where the Prices tab answers it with the whole book.
function ItemTooltip:LinesFor(itemID, count, link)
    local lines = {}

    if not itemID or not ns.Prices then return lines end

    -- Grey (poor) items are worth what a vendor pays, never an auction
    -- price (a standing rule for both addons), and the game's own tooltip
    -- already gives the vendor price. So nothing is added for them.
    -- Read and compared inside the pcall: in a dungeon the game can hand
    -- back values that raise when compared.
    local poorOk, poor = pcall(function()
        local _, _, quality = C_Item.GetItemInfo(itemID)
        return quality == 0
    end)
    if poorOk and poor then return lines end

    local mine = self:MyPriceLine(itemID)
    if mine then lines[#lines + 1] = mine end

    -- The auction house's own figure: the player's price has its own line.
    local value
    if ns.Prices.GetScanValue then
        value = ns.Prices:GetScanValue(itemID, "market")
    else
        value = ns.Prices:GetValue(itemID, "market")
    end

    -- A stored zero is a scan that saw no listings, not an item the market
    -- values at nothing.
    if not value or value <= 0 then
        if self.IsAuctionable(itemID) then
            -- Searched and found empty is not the same as never looked at.
            local record = ns.Prices.Get and ns.Prices:Get(itemID)
            lines[#lines + 1] = { L["Auction value"],
                (record and record.quantity == 0) and L["none listed"] or L["not scanned yet"], true }
        end

        self:AddDemandLines(lines, itemID)

        local disenchant = self:DisenchantLine(itemID)
        if disenchant then lines[#lines + 1] = disenchant end
        self:AddDisenchantResults(lines, itemID)

        self:AddCraftedLines(lines, itemID)
        self:AddRecipeLines(lines, itemID)
        self:AddSealedLines(lines, itemID)
        self:AddCrateLines(lines, itemID)

        return lines
    end

    local text = Util.FormatMoney(value, { short = true })

    -- An old price is still the best anyone has, so it is shown -- with its
    -- age, which is the part that decides whether to trust it.
    if ns.Prices.IsStale and ns.Prices:IsStale(itemID) then
        local age = ns.Prices:GetAge(itemID)
        if age then
            text = L.Format("%s  (%s)", text, Util.FormatAgeAgo(age))
        end
    end

    lines[#lines + 1] = { L["Auction value"], text }

    -- A random suffix with a price of its own ("of the Monkey" can sell for
    -- far more than "of the Spirit"): what this one goes for.
    local roll = link and ns.Prices.SuffixOf and ns.Prices.SuffixOf(link)
    local rollValue = roll and ns.Prices:GetSuffixValue(itemID, roll, "market")
    if rollValue and rollValue > 0 then
        lines[#lines + 1] = { L["This one"], Util.FormatMoney(rollValue, { short = true }) }
    end

    local lowest = self:LowestLine(itemID)
    if lowest then lines[#lines + 1] = lowest end

    local trend = self:TrendLine(itemID)
    if trend then
        if ItemTooltip.Shows("trend") then
            lines[#lines + 1] = trend
        else
            lines.held = true
        end
    end

    if count and count > 1 then
        lines[#lines + 1] = {
            L.Format("Stack of %d", count),
            Util.FormatMoney(value * count, { short = true }),
            stack = true,
        }
    end

    self:AddDemandLines(lines, itemID)

    local disenchant = self:DisenchantLine(itemID)
    if disenchant then lines[#lines + 1] = disenchant end
    self:AddDisenchantResults(lines, itemID)

    self:AddCraftedLines(lines, itemID)
    self:AddRecipeLines(lines, itemID)
    self:AddSealedLines(lines, itemID)
    self:AddCrateLines(lines, itemID)

    return lines
end

--- What a sealed writ has opened into, once the player has opened one
--- (`Writs:SealedInfo`, learned from their own openings).
function ItemTooltip:AddSealedLines(lines, itemID)
    local writs = ns.Writs
    if not (writs and writs.SealedInfo and writs.IsSealed) then return end
    if not writs:IsSealed(itemID) then return end

    local info = writs:SealedInfo(itemID, 5)
    if not info then return end

    lines[#lines + 1] = { L.Format("You opened %d", info.opens), "" }
    for _, row in ipairs(info.rows) do
        lines[#lines + 1] = { row.writ.name, L.Format("%d of %d", row.count, info.opens) }
    end
    if info.worth then
        lines[#lines + 1] = { L["Writ inside worth about"], Util.FormatMoney(info.worth, { short = true }) }
    end
end

--- What a Waylaid Crate costs to fill and pays back (the owner said build
--- it, 2026-10-20): its cheapest bundle, what that costs, the silver and
--- favor the turn-in pays and what one favor comes to, from the Favors and
--- Writs tab's own sums. With Shift held: the crate's own price, how much of
--- the bundle you have and the next cheapest bundle.
function ItemTooltip:AddCrateLines(lines, itemID)
    self.crateHeld = nil
    if ns.Config and ns.Config:Get("tooltipCrateCosts") == false then return end
    local favor = ns.MerchantsFavor
    if not (favor and favor.RowForItem) then return end
    local row = favor:RowForItem(itemID)
    if not row then return end
    if not ItemTooltip.Shows("crate") then
        lines.held = true
        return
    end

    local function Money(value) return Util.FormatMoney(value, { short = true }) end
    local best = row.best
    if best then
        local name = favor.NameOf(best.itemID) or "?"
        lines[#lines + 1] = { L["Fill It With"], L.Format("%d %s", best.count, name) }
        if best.cost then lines[#lines + 1] = { L["Fills For"], Money(best.cost) } end
    end
    if row.favor then
        local back = (row.money or 0) > 0
            and L.Format("%s and %d favor", Money(row.money), row.favor)
            or L.Format("%d favor", row.favor)
        lines[#lines + 1] = { L["Pays Back"], back }
    end
    if row.perFavor then
        lines[#lines + 1] = { L["Each Favor"], Money(math.floor(row.perFavor + 0.5)), color = "accent" }
    end

    local shift = ns.TooltipShift
    if not (shift and shift.ShiftDown()) then
        lines.held = true
        self.crateHeld = true
        return
    end
    lines[#lines + 1] = { L["Crate on the AH"], row.cratePrice and Money(row.cratePrice) or L["none listed"] }
    if best then
        local have = favor.Owned(best.itemID)
        lines[#lines + 1] = { L["You Have"], L.Format("%d of %d", math.min(have, best.count), best.count) }
    end
    local next
    for _, bundle in ipairs(row.bundles or {}) do
        if bundle ~= best and bundle.cost and (not next or bundle.cost < next.cost) then next = bundle end
    end
    if next then
        local name = favor.NameOf(next.itemID) or "?"
        lines[#lines + 1] = { L["Next Best"], L.Format("%d %s", next.count, name) }
    end
end

--- The market value now against its average over the picked period
--- (2026-10-14), green up and red down, as the Prices tab's TREND column.
--- nil while too few days were scanned, or with the line turned off.
function ItemTooltip:TrendLine(itemID)
    if ns.Config and ns.Config:Get("tooltipTrend") == false then return nil end
    local prices = ns.Prices
    if not (prices and type(prices.GetTrend) == "function" and prices.TrendText) then return nil end

    local days = prices:TrendDays()
    local ok, trend = pcall(prices.GetTrend, prices, itemID, days)
    if not ok then return nil end
    local text, color = prices.TrendText(trend)
    if not text then return nil end

    local label = days == 14 and L["Trend (14 days)"] or L["Trend (7 days)"]
    return { label, text, color = color }
end

--- The price the player set on the Prices tab, in gold so it stands out
--- from the auction figures, saying how it is used. nil when none is set.
function ItemTooltip:MyPriceLine(itemID)
    if type(ns.Prices.GetMine) ~= "function" then return nil end

    local mine, mode = ns.Prices:GetMine(itemID)
    if not mine then return nil end

    return { L["My price"], L.Format("%s  (%s)", Util.FormatMoney(mine, { short = true }),
        mode == "use" and L["used instead of AH"] or L["never below"]), color = "warn" }
end

--- On a recipe item: what it teaches, who knows it, what one craft costs,
--- sells and disenchants for, and how many crafts pay the recipe back
--- (Logic/RecipeBook.lua, asked 2026-10-05). Nothing for any other item.
function ItemTooltip:AddRecipeLines(lines, itemID)
    if not (ns.RecipeBook and ns.RecipeBook.TooltipLines) then return end

    local ok, recipe = pcall(ns.RecipeBook.TooltipLines, ns.RecipeBook, itemID)
    if not ok or type(recipe) ~= "table" then return end
    if #recipe > 0 and not ItemTooltip.Shows("recipe") then
        lines.held = true
        return
    end

    for _, line in ipairs(recipe) do lines[#lines + 1] = line end
end

--- What it cost the last time you made one, what it last went up at, and
--- what listing it now makes over that cost (Logic/CraftedCost.lua, asked
--- 2026-10-05). Nothing for an item you have not crafted.
function ItemTooltip:AddCraftedLines(lines, itemID)
    if not (ns.CraftedCost and ns.CraftedCost.Lines) then return end

    local ok, crafted = pcall(ns.CraftedCost.Lines, ns.CraftedCost, itemID)
    if not ok or type(crafted) ~= "table" then return end

    for _, line in ipairs(crafted) do lines[#lines + 1] = line end
end

--- How well it sells (Logic/Demand.lua), coloured by level. Nothing when
--- there is no reading yet. `short` leaves out the market's share of stock,
--- which the sales lines below it say in numbers.
function ItemTooltip:DemandLine(itemID, short)
    if not (ns.Demand and ns.Demand.Get) then return nil end

    local ok, reading = pcall(ns.Demand.Get, ns.Demand, itemID)
    if not ok or not reading then return nil end

    local text = ns.Demand:TooltipText(reading)
    if short and reading.source == "market" then text = ns.Demand:Label(reading) end

    return { L["Demand"], text, color = ns.Demand:Color(reading) }
end

--------------------------------------------------------------------------------
-- Sales details under Demand
--------------------------------------------------------------------------------

-- A player asked (2026-10-13), the owner agreeing: under Demand, about how
-- many sell a day, how many are listed now, the last seven days and what
-- you sold this week. Shown always, or only while Shift is held when
-- "Sales Details:" Shift or Always (`tooltipSalesShift`, true for Shift, off unless picked,
-- never rename it) is on. The game never says what sold, so "Sold a day"
-- and the seven days are worked out from your own scans and say so.

-- The tallest bar, in pixels, and each bar's width. No taller than a
-- tooltip line, or the bars stick out past the line and, as the last line,
-- past the tooltip's edge (a player's report, 2026-10-18).
ItemTooltip.BAR_HEIGHT = 10
ItemTooltip.BAR_WIDTH = 5

-- Under this change between the older and newer days, the trend is steady.
ItemTooltip.STEADY_TREND = 0.10

-- Complete days with a scan the trend needs (today is left out: it is not over).
ItemTooltip.TREND_DAYS = 4

local BAR_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local BAR_DAY   = { 110, 150, 130 }
local BAR_TODAY = { 79, 209, 139 }
local BAR_NONE  = { 122, 128, 137 }

-- The sales lines sit under Demand, a step in.
local INDENT = "   "

--- Whether the sales lines go on the tooltip now.
function ItemTooltip:ShowsSalesDetails()
    return ItemTooltip.Shows("sales")
end

--- One inline bar, its foot on the line's foot.
local function Bar(height, color)
    local full = ItemTooltip.BAR_HEIGHT
    local offset = -math.floor((full - height) / 2 + 0.5)
    return ("|T%s:%d:%d:0:%d:8:8:0:8:0:8:%d:%d:%d|t"):format(
        BAR_TEXTURE, height, ItemTooltip.BAR_WIDTH, offset, color[1], color[2], color[3])
end

--- The seven days as bars, today last and brightest. A day nothing scanned
--- it is a flat grey mark.
function ItemTooltip.Bars(days)
    local most = 0
    for _, sold in ipairs(days) do
        if sold and sold > most then most = sold end
    end

    local parts = {}
    for index, sold in ipairs(days) do
        if sold == false then
            parts[#parts + 1] = Bar(1, BAR_NONE)
        else
            local height = most > 0 and math.max(1, math.floor(ItemTooltip.BAR_HEIGHT * sold / most + 0.5)) or 1
            parts[#parts + 1] = Bar(height, index == #days and BAR_TODAY or BAR_DAY)
        end
    end
    return table.concat(parts, " ")
end

--- Up, down or steady: the newer half of the complete days scanned against
--- the older half. nil when too few days were scanned to say.
-- @return a fraction (0.18 for up 18%), or nil
function ItemTooltip.Trend(days)
    local scanned = {}
    for index = 1, #days - 1 do
        if days[index] ~= false then scanned[#scanned + 1] = days[index] end
    end
    if #scanned < ItemTooltip.TREND_DAYS then return nil end

    local half = math.floor(#scanned / 2)
    local older, newer = 0, 0
    for index = 1, half do older = older + scanned[index] end
    for index = #scanned - half + 1, #scanned do newer = newer + scanned[index] end

    if older == 0 then return nil end
    return (newer - older) / older
end

--- "about 34", "less than 1": the estimate in plain words.
local function AboutText(perDay)
    if perDay < 1 then return L["less than 1"] end
    return L.Format("about %d", math.floor(perDay + 0.5))
end

--- Demand, then (when shown) the four sales lines under it.
function ItemTooltip:AddDemandLines(lines, itemID)
    local details = self:ShowsSalesDetails()

    local demand = self:DemandLine(itemID, details)
    if demand then lines[#lines + 1] = demand end

    if not details then
        lines.held = true
        return
    end

    local prices = ns.Prices

    if prices and type(prices.GetUnitsSoldPerDay) == "function" then
        local ok, perDay = pcall(prices.GetUnitsSoldPerDay, prices, itemID)
        if ok and type(perDay) == "number" then
            lines[#lines + 1] = { INDENT .. L["Sold a day"], L.Format("%s (from your scans)", AboutText(perDay)) }
        end
    end

    local record = prices and type(prices.Get) == "function" and prices:Get(itemID)
    if type(record) == "table" and type(record.quantity) == "number" and record.seen then
        local age = prices.GetAge and prices:GetAge(itemID)
        local count = tostring(record.quantity)
        if age then
            lines[#lines + 1] = { INDENT .. L["Listed now"], L.Format("%s  (scanned %s)", count, Util.FormatAgeAgo(age)) }
        else
            lines[#lines + 1] = { INDENT .. L["Listed now"], count }
        end
    end

    if prices and type(prices.GetDailySales) == "function" then
        local ok, days = pcall(prices.GetDailySales, prices, itemID)
        if ok and type(days) == "table" then
            local trend = ItemTooltip.Trend(days)
            local text, color = self.Bars(days), nil
            if trend and trend >= self.STEADY_TREND then
                text = L.Format("%s  up %d%%", text, math.floor(trend * 100 + 0.5))
                color = "profit"
            elseif trend and trend <= -self.STEADY_TREND then
                text = L.Format("%s  down %d%%", text, math.floor(-trend * 100 + 0.5))
                color = "warn"
            elseif trend then
                text = L.Format("%s  steady", text)
            end
            lines[#lines + 1] = { INDENT .. L["Last 7 days"], text, color = color }
        end
    end

    if ns.Demand and type(ns.Demand.Week) == "function" then
        local ok, week = pcall(ns.Demand.Week, ns.Demand, itemID)
        if ok and type(week) == "table" and (week.sold > 0 or week.expired > 0) then
            local text
            if week.expired > 0 then
                text = L.Format("%d this week, %d expired", week.sold, week.expired)
            else
                text = L.Format("%d this week", week.sold)
            end
            lines[#lines + 1] = { INDENT .. L["You sold"], text }
        end
    end
end

--- What one of the item is worth disenchanted, for anything that can be.
--- Nothing at all for an item that cannot, or when none of what it breaks
--- into has been scanned yet.
function ItemTooltip:DisenchantLine(itemID)
    if not ns.Disenchant then return nil end

    local value, partial = ns.Disenchant:GetValue(itemID)
    if not value then return nil end

    local text = Util.FormatMoney(value, { short = true })
    if partial then text = L.Format("%s or more", text) end

    return { L["Disenchant value"], text }
end

--- What the item can break into and the chance of each, under its
--- disenchant value, for a character that knows Disenchant (a player asked,
--- 2026-10-29). The chances are the ones the Disenchanting tab shows: the
--- built-in table, or your own results once there are enough.
--- "Disenchant Results on Tooltips:" on the Look page
--- (`tooltipDisenchantResults`, on unless picked Off, never rename it).
function ItemTooltip:AddDisenchantResults(lines, itemID)
    if ns.Config and ns.Config:Get("tooltipDisenchantResults") == false then return end
    if not (ns.Disenchant and ns.Disenchanter and ns.Disenchanter.Knows) then return end
    if ns.Disenchanter:Knows() ~= true then return end

    local ok, outcomes = pcall(ns.Disenchant.GetOutcomes, ns.Disenchant, itemID)
    if not ok or type(outcomes) ~= "table" or #outcomes == 0 then return end

    if not ItemTooltip.Shows("disenchant") then
        lines.held = true
        return
    end

    for _, outcome in ipairs(outcomes) do
        local name = ns.Disenchant:MaterialName(outcome.itemID) or Util.GetItemLabel(outcome.itemID)
        name = Util.ColorItemName(outcome.itemID, name) or name
        local low, high = outcome.min, outcome.max
        if low and high and high > 1 then
            name = low == high and ("%s x%d"):format(name, low) or ("%s x%d-%d"):format(name, low, high)
        end
        lines[#lines + 1] = { INDENT .. name, ("%s%%"):format(Util.Round((outcome.chance or 0) * 100, 1)) }
    end
end

--- The cheapest listing the last scan saw, beside the smoothed value
--- (2026-09-26: "items should show the lowest seller value in addition to
--- auction value"). Marked when the cheapest one is your own. A lone
--- listing far below the rest is left out, as the Enchanting pane and the
--- undercut leave it out, so the tooltip does not quote a price that one
--- purchase would clear.
function ItemTooltip:LowestLine(itemID)
    if type(ns.Prices.Get) ~= "function" then return nil end

    local record = ns.Prices:Get(itemID)
    if type(record) ~= "table" then return nil end

    local lowest = record.min
    if lowest and ns.Prices.LowestListed then
        lowest = ns.Prices.LowestListed(record) or lowest
    end
    if not lowest or lowest <= 0 then
        -- Scanned, and nobody had one up: say so rather than leave it out.
        return { L["Lowest posting"], L["none listed"], true }
    end

    local text = Util.FormatMoney(lowest, { short = true })

    if record.ownMin and record.ownMin <= lowest then
        text = L.Format("%s  (yours)", text)
    end

    return { L["Lowest posting"], text }
end

--------------------------------------------------------------------------------
-- Writing it on
--------------------------------------------------------------------------------

-- What has already been decorated. Weak keys, so a tooltip the client throws
-- away takes its entry with it, and no field of ours is written onto a
-- Blizzard frame.
--
-- More than one hook is installed on purpose -- see the header -- so more than
-- one of them may fire for the same tooltip. This is what stops that showing
-- up as the line appearing twice: a tooltip is marked with the item and the
-- line count it had once we were finished, and a later call for the same item
-- that finds the tooltip no shorter than that has nothing left to do. Clearing
-- the tooltip drops the mark, so the next draw is decorated again.
local decorated = setmetatable({}, { __mode = "k" })

function ItemTooltip.Forget(tooltip)
    decorated[tooltip] = nil
end

--- A line was held back for Shift: "Hold Shift for more." once.
function ItemTooltip:HeldBack(tooltip)
    local shift = ns.TooltipShift
    if not shift then return end
    -- The hint shows the tooltip again, which can re-enter the hook.
    local was = self.writing
    self.writing = true
    pcall(shift.Held, shift, tooltip)
    self.writing = was
end

function ItemTooltip:AlreadyOn(tooltip, itemID)
    local mark = decorated[tooltip]

    if not mark or mark.itemID ~= itemID then return false end

    local now = Try(Field(tooltip, "NumLines"), tooltip)

    -- Cannot tell: assume it is already there. A missing line is a smaller
    -- fault than the same line printed twice.
    if type(now) ~= "number" then return true end

    return now >= mark.lines
end

-- AddDoubleLine takes colour components, not escape codes, so the hex the rest
-- of the addon works in is split out here. Bytes 1-2 are alpha.
local function Component(hex, first)
    return (tonumber(hex:sub(first, first + 1), 16) or 255) / 255
end

--- Put one `{ label, value, muted }` line on a tooltip.
local function WriteLine(tooltip, line)
    local add = Field(tooltip, "AddDoubleLine")
    if type(add) ~= "function" then return end

    local labelColor = ns.COLORS.accent
    local valueColor = (line.color and ns.COLORS[line.color])
        or (line[3] and ns.COLORS[STALE_COLOR]) or ns.COLORS.text

    Try(add, tooltip, line[1], line[2],
        Component(labelColor, 3), Component(labelColor, 5), Component(labelColor, 7),
        Component(valueColor, 3), Component(valueColor, 5), Component(valueColor, 7))
end

--- Append one item's lines to a tooltip.
-- @return "valued", "unscanned", "quiet", "duplicate" or "noitem"
function ItemTooltip:Decorate(tooltip, data, count)
    if type(tooltip) ~= "table" then return "noitem" end
    if not self:IsEnabled() then return "quiet" end

    -- Adding lines makes the tooltip taller, which means showing it again; on
    -- a client where that re-enters the hook, this is what stops it.
    if self.writing then return "duplicate" end

    local itemID = self:ItemForTooltip(tooltip, data)
    if not itemID then return "noitem" end

    if self:AlreadyOn(tooltip, itemID) then return "duplicate" end

    local lines = self:LinesFor(itemID, count, self:LinkForTooltip(tooltip, data))
    if #lines == 0 then
        if lines.held then self:HeldBack(tooltip) end
        return "quiet"
    end

    if type(Field(tooltip, "AddDoubleLine")) ~= "function" then return "noitem" end

    -- Every value line on Shift, and Shift is up: only the hint goes on.
    if not ItemTooltip.Shows("value") then
        self:HeldBack(tooltip)
        return "held"
    end

    self.writing = true

    for i = 1, #lines do
        WriteLine(tooltip, lines[i])
    end
    if lines.held then self:HeldBack(tooltip) end

    -- A tooltip that has grown has to be told to resize. Harmless where the
    -- client does it already, required where a hooked setter is what got us
    -- here.
    Try(Field(tooltip, "Show"), tooltip)
    self:ResizeSoon(tooltip, itemID)

    self.writing = false

    decorated[tooltip] = {
        itemID = itemID,
        count = count,
        lines = Try(Field(tooltip, "NumLines"), tooltip) or 0,
    }

    self.seen = (self.seen or 0) + 1

    local outcome = lines[1][3] and "unscanned" or "valued"
    self.counts[outcome] = (self.counts[outcome] or 0) + 1

    return outcome
end

--- Size the tooltip again on the next frame. The width is worked out when
--- it is shown, and a line of inline bars could be measured short then, so
--- the trend after the bars ran past the right edge (a player's report,
--- 2026-10-18). Only while it shows and is still marked for that item.
function ItemTooltip:ResizeSoon(tooltip, itemID)
    if not (C_Timer and C_Timer.After) then return end
    C_Timer.After(0, function()
        local mark = decorated[tooltip]
        if not (mark and mark.itemID == itemID) then return end
        if Try(Field(tooltip, "IsShown"), tooltip) ~= true then return end
        self.writing = true
        Try(Field(tooltip, "Show"), tooltip)
        self.writing = false
    end)
end

--- Add the stack total to a tooltip that was already given its unit value.
--
-- The count arrives late and there is nothing to be done about it. Every hook
-- available here fires *after* the call that built the tooltip, and only that
-- call was told which bag slot it was drawing -- so by the time the count is
-- readable, whichever hook fired first has already written the unit value.
-- Rather than fight the ordering, the stack line is a second, separate append.
--
-- Assigning a field on `GameTooltip` to pre-empt the count would taint it, so
-- that is not an option this addon has.
--
-- @return true if a line was added
function ItemTooltip:AddStackLine(tooltip, count)
    if not count or count <= 1 then return false end
    if not self:IsEnabled() then return false end
    if self.writing then return false end
    if not ItemTooltip.Shows("value") then return false end

    local mark = decorated[tooltip]

    -- Nothing decorated yet, or the stack total is already on: either way
    -- there is nothing for this to do.
    if not mark or mark.count then return false end

    -- The tooltip may have moved on to another item since it was marked.
    if self:ItemForTooltip(tooltip) ~= mark.itemID then return false end

    local lines = self:LinesFor(mark.itemID, count)

    -- No stack line means the item has no price, and "a stack of 20 of
    -- nothing" is not worth saying.
    local stackLine
    for _, line in ipairs(lines) do
        if line.stack then stackLine = line end
    end
    if not stackLine then return false end

    self.writing = true

    WriteLine(tooltip, stackLine)
    Try(Field(tooltip, "Show"), tooltip)
    self:ResizeSoon(tooltip, itemID)

    self.writing = false

    mark.count = count
    mark.lines = Try(Field(tooltip, "NumLines"), tooltip) or mark.lines

    return true
end

--- The entry point every hook funnels into, so the counting is in one place.
function ItemTooltip:OnTooltip(tooltip, data, source, count)
    -- A backstop: whatever this tooltip holds, a value the game will not let
    -- the addon read costs the price line, never a Lua error on hover. And
    -- `writing` is cleared, or one error would silently stop every tooltip
    -- for the rest of the session.
    local ok, outcome = pcall(self.Decorate, self, tooltip, data, count)
    if not ok then
        self.writing = false
        return "noitem"
    end

    if outcome == "valued" or outcome == "unscanned" then
        self.fired[source] = (self.fired[source] or 0) + 1
    end

    return outcome
end

--------------------------------------------------------------------------------
-- Getting told about a tooltip
--------------------------------------------------------------------------------

-- Retail 10.0 replaced the `OnTooltipSetItem` script with a data-driven
-- post-call; Classic has the script and nothing else. Which of the two this
-- client has cannot be established from outside the game, so both are
-- installed and whichever fires does the work -- the duplicate guard above is
-- what makes installing both safe.

--- Retail 10.0 and later: the tooltip announces its own data.
function ItemTooltip:InstallDataProcessor()
    local processor = _G.TooltipDataProcessor
    local dataType = Field(Field(_G.Enum, "TooltipDataType"), "Item")

    if type(processor) ~= "table" or dataType == nil then return false end

    local add = Field(processor, "AddTooltipPostCall")
    if type(add) ~= "function" then return false end

    return (pcall(add, dataType, function(tooltip, data)
        ItemTooltip:OnTooltip(tooltip, data, "TooltipDataProcessor")
    end))
end

--- Classic, and retail before 10.0: a script on each tooltip frame.
function ItemTooltip:InstallScriptHooks()
    local installed = 0

    for i = 1, #TOOLTIP_NAMES do
        local tooltip = _G[TOOLTIP_NAMES[i]]
        local hook = Field(tooltip, "HookScript")

        if type(hook) == "function" then
            local ok = pcall(hook, tooltip, "OnTooltipSetItem", function(shown)
                ItemTooltip:OnTooltip(shown, nil, "OnTooltipSetItem")
            end)

            if ok then installed = installed + 1 end

            -- Forgetting on clear is what lets the same item be decorated
            -- again on its next draw.
            pcall(hook, tooltip, "OnTooltipCleared", function(shown)
                ItemTooltip.Forget(shown)
            end)
        end
    end

    return installed > 0
end

-- The calls that put an item into GameTooltip. `SetBagItem` is hooked whatever
-- else took, because it is the only place a stack count can be read. The rest
-- are a fallback for a client that fires neither hook above, and are skipped
-- when one of them did -- eleven post-hooks on every tooltip is not a cost to
-- pay for nothing.
local STACK_SETTER = "SetBagItem"

local FALLBACK_SETTERS = {
    "SetInventoryItem", "SetHyperlink", "SetLootItem", "SetMerchantItem",
    "SetBuybackItem", "SetQuestItem", "SetTradePlayerItem",
    "SetTradeTargetItem", "SetAuctionItem", "SetGuildBankItem",
}

--- Hook one GameTooltip setter, post-call.
local function HookSetter(hook, tooltip, name, handler)
    if type(Field(tooltip, name)) ~= "function" then return false end

    return (pcall(hook, tooltip, name, handler))
end

--- Hook the calls that put an item into a tooltip.
-- @param fallback  also hook the setters that are only needed when no other
--                  hook fired
function ItemTooltip:InstallSetterHooks(fallback)
    local hook = _G.hooksecurefunc
    local tooltip = _G.GameTooltip

    if type(hook) ~= "function" or type(tooltip) ~= "table" then return false end

    local installed = 0

    if HookSetter(hook, tooltip, STACK_SETTER, function(shown, bag, slot)
        local count = ItemTooltip.StackCountIn(bag, slot)

        -- Decorate first: on a client with no other hook this is what puts the
        -- value on at all, and it can take the count with it.
        ItemTooltip:OnTooltip(shown, nil, "setter hooks", count)

        -- On a client that does have one, the value went on before the count
        -- was readable, so the stack total follows separately.
        ItemTooltip:AddStackLine(shown, count)
    end) then
        installed = installed + 1
    end

    if fallback then
        for i = 1, #FALLBACK_SETTERS do
            if HookSetter(hook, tooltip, FALLBACK_SETTERS[i], function(shown)
                ItemTooltip:OnTooltip(shown, nil, "setter hooks")
            end) then
                installed = installed + 1
            end
        end
    end

    return installed > 0
end

function ItemTooltip:InstallHooks()
    local installed = {}

    installed["TooltipDataProcessor"] = self:InstallDataProcessor()
    installed["OnTooltipSetItem"] = self:InstallScriptHooks()

    local fallback = not installed["TooltipDataProcessor"]
        and not installed["OnTooltipSetItem"]

    installed["setter hooks"] = self:InstallSetterHooks(fallback)

    self.installed = installed

    return installed
end

--------------------------------------------------------------------------------
-- Diagnostic
--------------------------------------------------------------------------------

-- `/bts tip` reports what has actually happened, not what was set up. A hook
-- that never fires installs perfectly, and "hooked the tooltip" would be true
-- of a client that never calls it -- which is the failure this exists to
-- catch. Every number below was counted on a real tooltip.
--
-- `/bts tip <link or id>` answers the other question: not whether the hook
-- works, but what the addon would say about that item. The two failures look
-- identical in game -- nothing on the tooltip -- and this tells them apart.

local function DescribeItem(itemID)
    ns.Print(("|c%s%s|r"):format(ns.COLORS.accent, Util.GetItemLabel(itemID)))

    local lines = ItemTooltip:LinesFor(itemID, nil)

    if #lines == 0 then
        ns.PrintRaw(("  |c%snothing would be shown: no price, and it is not"
            .. " something you could auction|r"):format(ns.COLORS.muted))
        return
    end

    for i = 1, #lines do
        ns.PrintRaw(("  |c%s%s|r  %s"):format(
            ns.COLORS.muted, lines[i][1], lines[i][2]))
    end
end

function ItemTooltip:PrintReport(input)
    local itemID = tonumber(input) or self.ItemIDFromLink(input)

    if itemID then
        DescribeItem(itemID)
        return
    end

    ns.Print(("|c%sAuction value on item tooltips|r"):format(ns.COLORS.accent))

    if not self:IsEnabled() then
        ns.PrintRaw(("  |c%sswitched off in Settings|r"):format(ns.COLORS.muted))
        return
    end

    local firing = {}
    for source, count in pairs(self.fired) do
        firing[#firing + 1] = ("%s (%d)"):format(source, count)
    end

    table.sort(firing)

    ns.PrintRaw(("  |c%stooltip types seen|r  %s"):format(
        ns.COLORS.muted, #firing > 0 and table.concat(firing, ", ") or "none yet"))

    ns.PrintRaw(("  |c%sitem tooltips checked|r  %d"):format(
        ns.COLORS.muted, self.seen or 0))

    ns.PrintRaw(("  |c%sshowing a value|r  %d"):format(
        ns.COLORS.muted, self.counts.valued or 0))

    ns.PrintRaw(("  |c%ssaying not scanned yet|r  %d"):format(
        ns.COLORS.muted, self.counts.unscanned or 0))

    if (self.seen or 0) == 0 then
        local installed = {}
        for source, ok in pairs(self.installed or {}) do
            if ok then installed[#installed + 1] = source end
        end

        table.sort(installed)

        ns.PrintRaw(("  |c%stooltip types watched|r  %s"):format(
            ns.COLORS.muted, #installed > 0 and table.concat(installed, ", ") or "none"))

        ns.PrintRaw(("  |c%sHover an item, then run this again.|r"):format(
            ns.COLORS.muted))
    end

    if ns.EnchantTooltip and ns.EnchantTooltip.ReportLines then
        for _, line in ipairs(ns.EnchantTooltip:ReportLines()) do
            ns.PrintRaw(("  |c%s%s|r  %s"):format(ns.COLORS.muted, line[1], line[2]))
        end
    end

    ns.PrintRaw(("  |c%s/bts tip <item link> says what one item would show.|r"):format(
        ns.COLORS.muted))
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function ItemTooltip:OnEnable()
    self.fired = {}
    self.counts = {}
    self.seen = 0

    self:InstallHooks()

    ns.RegisterCommand("tip",
        L["show what the auction value on item tooltips is doing"], function(input)
            ItemTooltip:PrintReport((input or ""):gsub("^%s+", ""):gsub("%s+$", ""))
        end)
end
