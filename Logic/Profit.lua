-- Blackthornes Tradeskills -- Logic/Profit.lua
-- Is it worth making?
--
-- The headline number is profit per craft after the auction house takes its
-- cut. It is deliberately reported alongside confidence and liquidity, because
-- a 900% margin on an item that sells twice a month is not an opportunity, and
-- a table that ranks purely on margin will put exactly those items on top.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Profit = ns.NewModule("Profit")

local Util = ns.Util

-- Shown wherever an unpriceable craft says why: the Profit tab's detail
-- panel, the craft pane's tooltip and /bts why.
local SOULBOUND_REASON = L["binds on pickup, so it cannot be sold"]

--------------------------------------------------------------------------------
-- What to list at
--------------------------------------------------------------------------------

--- About the deposit for listing `quantity` of an item, from what the
--- auction house said before; nil until it has said.
local function HeldDeposit(itemID, quantity)
    local posting = ns.Posting
    if not posting then return nil end
    if posting.EstimateDeposit then return posting:EstimateDeposit(itemID, quantity) end
    local unit = posting.GetCachedUnitDeposit and posting:GetCachedUnitDeposit(itemID)
    return unit and math.floor(unit * quantity + 0.5) or nil
end

--- Net profit for one craft, if a unit sold at this price.
--
-- The same arithmetic Analyse does, split out so the price can be chosen by
-- asking what each candidate would actually earn.
local function ProfitAtPrice(recipe, cost, unitPrice)
    if not recipe or not cost or not cost.priceable or not unitPrice then return nil end

    local yield = cost.yield or 1
    local revenue = unitPrice * yield
    local cut = revenue * (ns.Config:Get("auctionCut") or 0.05)

    local held = HeldDeposit(recipe.outputItemID, yield)
    local deposit = held and held * Profit.LostListings(recipe.outputItemID) or 0

    return (revenue - cut) - (cost.total or 0) - deposit
end

-- Used when the setting has never been written, so the rule still holds on a
-- database saved before it existed.
local DEFAULT_MARKUP_PERCENT = 50

--- What to charge when nothing is competing: what the materials are worth,
--- plus a markup.
--
-- Two situations reach this, and they are different facts about the world
-- that happen to want the same number:
--
--   * Nobody has ever listed one, so there is no market to read at all. That
--     is not the same as the craft being worthless, and returning nothing for
--     it kept the craft out of the Profit tab and unlistable from the Sell
--     tab -- exactly the position a new recipe starts in.
--   * Every listing on the book is yours. Market value then largely reflects
--     your own prices, so holding at it means charging whatever you happened
--     to charge last time, forever, with nobody undercutting you.
--
-- In both, the materials answer: whatever they are worth, plus the markup in
-- Settings. It is never written back into the price database, because a
-- number the addon worked out must not come back an hour later looking like
-- something the auction house said. A rival listing beats it outright.
--
-- @param knownCost  a costing the caller already has, used only when it is
--   for this same recipe and is already the full-value one. Analyse costs
--   every recipe before it asks for a price, and the profession panes analyse
--   hundreds of recipes at a time, so a second walk of the same tree is worth
--   avoiding.
-- @return price, why  -- nil when there is no recipe, no material price, or
--   the setting is off. why names the markup and the material value, without
--   saying why nothing is competing; the caller knows which case it is in
--   and says so.
function Profit:DeriveFromMaterials(itemID, knownCost)
    if not itemID then return nil end
    if ns.Config:Get("priceUnscannedCrafts") == false then return nil end

    -- Any character's recipe: an alt's craft is worth as much to sell.
    local recipeID = ns.Cost:FindAnyRecipeForItem(itemID)
    if not recipeID then return nil end

    -- Full material value, not the cash-out-of-pocket view: a craft is not
    -- worth less to sell because its reagents happen to be paid for already.
    -- The two are the same walk while materials are valued at market, which
    -- is the default, so the caller's costing can stand in for it -- but only
    -- when it is a costing of this very recipe. Two recipes can make the same
    -- item, and pricing one off the other's materials would be a wrong number
    -- presented as a right one.
    local perUnit

    if knownCost and knownCost.recipeID == recipeID and knownCost.priceable
        and knownCost.perUnit and ns.Config:Get("valueOwnedMaterials") ~= false then
        perUnit = knownCost.perUnit
    else
        perUnit = ns.Cost:GetMaterialValue(recipeID)
    end

    if not perUnit or perUnit <= 0 then return nil end

    local markup = ns.Config:Get("unscannedMarkupPercent")
    if type(markup) ~= "number" then markup = DEFAULT_MARKUP_PERCENT end

    local price = math.floor(perUnit * (1 + markup / 100))

    -- Never under what a vendor pays for it. Below that, walking to a vendor
    -- beats the listing outright, and Posting's own floor would refuse it --
    -- so the estimate would be a price nothing could be done with.
    local vendor = Util.GetVendorSellPrice(itemID)
    if vendor and vendor > price then price = vendor end

    price = math.max(1, price)

    -- Cheap reagents cannot produce an impossible price, but a restored
    -- database carrying one can, and this is a price the player may post at.
    if not ns.Prices.IsCredible(price) then return nil end

    return price, L.Format("%d%% over the %s its materials are worth",
        markup, Util.FormatMoney(perUnit, { noColor = true }))
end

--- Round a no-competition price for the kind of auction it will be listed as.
--
-- Upwards on an item auction, unlike an undercut. There is no rival to get
-- beneath, and rounding down by up to a silver can put a cheap craft under
-- what its materials cost, which Posting would then refuse to list.
local function RoundForSale(price, isCommodity)
    if isCommodity then return price end
    return Util.CeilToSilver(price)
end

--- The unit price to list an item at, and why.
--
-- Commodities take any price down to the copper, so undercutting works the way
-- it always has. Item auctions only take whole gold and silver, which makes
-- the smallest undercut available a whole silver rather than a copper. On a
-- cheap item that is a large fraction of the price to give away in order to
-- beat sellers you could simply have matched.
--
-- So an item auction matches the cheapest rival at the silver it is listed at,
-- and only drops the extra silver when the sale would still clear the minimum
-- profit setting. Anything the profit cannot be worked out for matches, since
-- the unknown case is the one where giving gold away is least defensible.
--
-- @return price, basis, why, uncertain  -- basis is "undercut", "match",
--   "market", "derived", "uncontested", "mine", "floor", "list" (raised to
--   its list's Lowest Price), "highest" (lowered to the Highest the player
--   set) or "overcut", and nil price when there is
--   nothing to go on. "derived" (never scanned) and "uncontested" (scanned,
--   but every listing is yours) are both the material-value figure from
--   DeriveFromMaterials above, and are the two bases that are not evidence
--   of what anybody else is charging. why is a sentence explaining a match
--   or either of those, since none of those words says on its own where the
--   number came from. uncertain is true when the item's commodity status is
--   not known, see below. A fifth return, waits, is true when the player
--   said to wait while others sell for less than their Lowest Price: the
--   price is that Lowest Price, and the Sell list holds the item back.
-- @param knownCost  optional, passed straight to DeriveFromMaterials; see
--   there for when it is used and when it is ignored.
-- @param link optional: the copy to be listed. A random suffix ("of the
--   Monkey") is priced as that suffix sells, when a recent price is kept.
function Profit:ChoosePostPrice(itemID, knownCost, link)
    if not itemID then return nil, nil end

    -- A price the player set on the Prices tab (2026-10-06): "use"
    -- lists at it, "floor" undercuts as usual but never goes below it.
    -- A "floor" may also carry Highest and When Cheaper (2026-10-28).
    local mine, mode, high, wait
    if ns.Prices.GetMine then mine, mode = ns.Prices:GetMine(itemID) end
    if mode == "floor" and ns.Prices.GetMyLimits then high, wait = ns.Prices:GetMyLimits(itemID) end

    -- Else its list's Lowest Price (Logic/ListRules.lua, 2026-10-19):
    -- undercuts as usual, never below it; and its Highest Price and When
    -- Cheaper (2026-10-28). The Lowest Price may be a percent of the
    -- market price or of what one cost to make.
    local listName
    if not mine and ns.ListRules then
        mine, listName = ns.ListRules:Floor(itemID, knownCost)
        mode = mine and "floor" or nil
        if ns.ListRules.Limits then
            local limitsName
            high, wait, limitsName = ns.ListRules:Limits(itemID)
            listName = listName or limitsName
        end
    end
    if not mine and not high then return self:ChooseMarketPostPrice(itemID, knownCost, link) end

    local status
    if ns.Scanner.GetCommodityStatus then
        status = ns.Scanner:GetCommodityStatus(itemID)
    else
        status = ns.Scanner:IsCommodity(itemID)
    end
    local floor = mine and RoundForSale(mine, status ~= false)

    if mode == "use" then
        return floor, "mine", L["your own price, set on the Prices tab"], status == nil
    end

    local price, basis, why, uncertain = self:ChooseMarketPostPrice(itemID, knownCost, link)

    -- Highest: never list above it. An item auction takes whole silver only,
    -- so it rounds down. Under the Lowest Price it means nothing and is left out.
    local top = high and (status == false and Util.RoundToSilver(high) or high)
    if top and floor and top < floor then top = nil end

    if floor and (not price or price < floor) then
        -- When Cheaper, Wait: others are selling for less, so it stays in
        -- the bags. Only while others really are: a price worked out from
        -- the materials, or one where every listing is yours, is no rival.
        local waits = wait and price and basis ~= "derived" and basis ~= "uncontested" or nil
        if listName then
            return floor, "list", L.Format("Following your %s list.", listName), status == nil, waits
        end
        return floor, "floor", L["the least you set on the Prices tab"], status == nil, waits
    end

    if top and price and price > top then
        if listName then
            return top, "highest", L.Format("Following your %s list.", listName), status == nil
        end
        return top, "highest", L["the most you set on the Prices tab"], status == nil
    end
    return price, basis, why, uncertain
end

-- Why a price matches the cheapest rival when Undercut by is set to 0c.
local MATCH_BY_CHOICE = L["your Undercut By is set to 0c, so it matches the cheapest listing"]

--- ChoosePostPrice from the auction house alone, before the player's own
--- price is applied. Same returns.
function Profit:ChooseMarketPostPrice(itemID, knownCost, link)
    if not itemID then return nil, nil end

    -- The copy's own suffix price when the link names one with a recent
    -- price, else the item's.
    local function Read(which)
        if link and ns.Prices.GetLinkValue then return (ns.Prices:GetLinkValue(link, which)) end
        return ns.Prices:GetValue(itemID, which)
    end

    -- "rival" excludes your own auctions, so listing a second one does not
    -- undercut the first.
    local rival = Read("rival")

    -- true, false or nil. Nil is something never held and never searched
    -- for, which is most crafts not yet made, and it is priced WITHOUT the
    -- whole-silver step: the step floors anything under a silver up to one,
    -- so guessing "item auction" overstated a cheap commodity's revenue by
    -- up to double, while guessing "commodity" only understates an item
    -- auction's by the silver it would be rounded to.
    local status
    if ns.Scanner.GetCommodityStatus then
        status = ns.Scanner:GetCommodityStatus(itemID)
    else
        status = ns.Scanner:IsCommodity(itemID)
    end

    local isCommodity = status ~= false
    local uncertain = status == nil

    -- Nobody to undercut, so nothing is holding the price down to what the
    -- competition charges. What the materials are worth plus the markup is
    -- the answer in both the cases below.
    if not rival then
        local market = Read("market")
        local materials, markup = self:DeriveFromMaterials(itemID, knownCost)

        -- Nothing scanned, ever. Not the same as an empty auction house: an
        -- item seen before keeps its market value through an empty search, so
        -- this is only reached by something the addon has never had a price
        -- for. A stale price is still evidence and is left alone.
        if not market then
            if not materials then return nil, nil end

            return RoundForSale(materials, isCommodity), "derived",
                L.Format("no scan has priced this, so it is %s", markup), uncertain
        end

        market = math.max(1, math.floor(market))

        -- Scanned, and every listing on the book is yours. Market value is
        -- then mostly a reflection of your own prices, so holding at it means
        -- charging roughly what you charged last time for as long as nobody
        -- turns up to compete. With no competition the markup over materials
        -- is what the craft is worth selling at.
        --
        -- Only ever upwards. A market value already above the markup is a
        -- real observation of what these have sold for, and giving that up
        -- would be cutting your own price for no reason.
        --
        -- That also settles this rather than letting it run: listing at the
        -- markup pulls market value towards it over the next few scans,
        -- since your listings are the only ones in it, until market reaches
        -- the markup and holds there. The price stops moving; only the label
        -- changes, from "no competition" back to market value.
        if materials and materials > market then
            return RoundForSale(materials, isCommodity), "uncontested",
                L.Format("nothing else is listed, so it is %s", markup), uncertain
        end

        if isCommodity then return market, "market", nil, uncertain end

        return Util.RoundToSilver(market), "market"
    end

    local undercut = ns.Config:Get("undercutCopper") or 1

    -- Overcutting (the owner, 2026-10-15): post just under the big stack
    -- rather than under a few cheap ones that will sell first anyway.
    if status == true and not (link and Util.LinkSuffix and Util.LinkSuffix(link)) then
        local over, why = self:Overcut(itemID, rival, undercut)
        if over then return over, "overcut", why, uncertain end
    end

    -- Undercut by 0c is the player turning undercutting off (asked on
    -- Discord, 2026-10-09): list at the cheapest rival's own price, for
    -- commodities and item auctions alike, and say that is why.
    if undercut <= 0 then
        local price = math.max(1, math.floor(rival))
        if not isCommodity then price = Util.RoundToSilver(price) end
        return price, "match", MATCH_BY_CHOICE, uncertain
    end

    if isCommodity then
        return math.max(1, math.floor(rival - undercut)), "undercut", nil, uncertain
    end

    local matchPrice = Util.RoundToSilver(rival)
    local underPrice = Util.RoundToSilver(math.max(1, math.floor(rival - undercut)))

    -- A rival already sitting at the lowest price the server allows leaves
    -- nothing below it, so matching is the only move.
    if underPrice >= matchPrice then
        return matchPrice, "match", L["the game won't allow a price below the rival's"]
    end

    local recipeID = ns.Cost:FindAnyRecipeForItem(itemID)
    local recipe = recipeID and ns.Recipes:GetAny(recipeID)
    local cost = recipeID and ns.Cost:GetCraftCost(recipeID)
    local profit = ProfitAtPrice(recipe, cost, underPrice)

    if not profit then
        return matchPrice, "match",
            L.Format("the cost to make this is unknown, so dropping %s was not worth the risk",
                Util.FormatMoney(matchPrice - underPrice, { noColor = true }))
    end

    local minProfit = ns.Config:Get("minProfit") or 0

    if profit >= minProfit then return underPrice, "undercut" end

    return matchPrice, "match",
        L.Format("undercutting to %s leaves %s profit, below your %s minimum",
            Util.FormatMoney(underPrice, { noColor = true }),
            Util.FormatMoney(profit, { noColor = true }),
            Util.FormatMoney(minProfit, { noColor = true }))
end

--------------------------------------------------------------------------------
-- Overcutting
--------------------------------------------------------------------------------

-- The owner asked (2026-10-15): optionally post a little up the book, just
-- under the price where the big stacks sit, when the few cheaper listings
-- below it should sell within a day. Off unless ticked (`overcutting`,
-- never rename it). Stackable goods only: gear is listed a piece at a time.
--
-- A step is the big stack when it holds at least WALL_MIN and at least
-- WALL_RATIO times everything cheaper. The cheaper ones must add up to no
-- more than a day of sales (Prices:GetUnitsSoldPerDay), the steps must be
-- read within FRESH seconds and still start at the cheapest rival, and the
-- price may sit at most CAP over the scanned market value.
Profit.OVERCUT = { WALL_MIN = 5, WALL_RATIO = 2, FRESH = 3600, CAP = 1.25 }

-- What the switch does, in Settings and on the auction house drawer.
Profit.OVERCUT_HELP = L["Posts just under the big stack when a few cheaper ones should sell within a day. Only for things that stack."]

function Profit:Overcutting()
    return ns.Config:Get("overcutting") == true
end

--- The overcut price for one, or nil when Overcutting is off or the book
--- does not call for it.
-- @return price, why, wall (the big stack's price), count (how many there),
--   ahead (how many cheaper ones sell first)
function Profit:Overcut(itemID, rival, undercut)
    if not self:Overcutting() or not itemID or not rival then return nil end
    local rules = Profit.OVERCUT

    local record = ns.Prices.GetTable and ns.Prices:GetTable()[itemID]
    if type(record) ~= "table" then return nil end
    local ladder = record.ladder
    if not (ns.Prices.ValidLadder and ns.Prices.ValidLadder(ladder)) then return nil end
    if ladder[1] ~= rival then return nil end
    if type(record.ladderAt) ~= "number" or time() - record.ladderAt > rules.FRESH then return nil end

    if ns.Demand and ns.Demand.Get then
        local ok, demand = pcall(ns.Demand.Get, ns.Demand, itemID)
        if ok and type(demand) == "table" and demand.level == "low" then return nil end
    end

    local perDay
    if ns.Prices.GetUnitsSoldPerDay then
        local ok, value = pcall(ns.Prices.GetUnitsSoldPerDay, ns.Prices, itemID)
        perDay = ok and tonumber(value) or nil
    end
    if not perDay or perDay <= 0 then return nil end

    local ahead, wall, count = 0, nil, nil
    for i = 1, #ladder, 2 do
        local price, units = ladder[i], ladder[i + 1]
        if i > 1 and units >= rules.WALL_MIN and units >= ahead * rules.WALL_RATIO then
            wall, count = price, units
            break
        end
        ahead = ahead + units
        if ahead > perDay then return nil end
    end
    if not wall then return nil end

    local price = math.max(1, math.floor(wall - math.max(0, undercut or 1)))
    if price <= rival then return nil end

    local market = ns.Prices.GetScanValue and ns.Prices:GetScanValue(itemID, "market")
    if market and price > market * rules.CAP then return nil end

    local why = ahead == 1 and L["1 cheaper one should sell first, then yours"]
        or L.Format("%d cheaper ones should sell first, then yours", ahead)
    return price, why, wall, count, ahead
end

--------------------------------------------------------------------------------
-- Single recipe
--------------------------------------------------------------------------------

--- How many crafts the current bags support.
--
-- Bags only, deliberately. The crafting UI cannot pull from the bank, so
-- counting bank stock here would claim you can craft things you cannot.
function Profit:GetCraftableCount(recipeID, characterKey)
    local recipe, owner = ns.Recipes:GetAny(recipeID)
    if not recipe or not recipe.reagents or #recipe.reagents == 0 then return 0 end

    characterKey = characterKey or owner

    local possible = math.huge

    for _, reagent in ipairs(recipe.reagents) do
        -- Counted against whoever would do the crafting, not against you.
        local have = ns.Inventory:GetCharacterBagCount(characterKey, reagent.itemID)
        local canMake = math.floor(have / reagent.quantity)

        if canMake < possible then possible = canMake end
        if possible == 0 then break end
    end

    return possible == math.huge and 0 or possible
end

--- How much having some already drags a craft down the ranking.
--
-- There is no cap to configure and deliberately so. The reason a craft you
-- already hold ten of is a worse use of the next hour than an equally
-- profitable one you hold none of is not a rule about inventory -- it is that
-- the eleventh only sells once the other ten have, so the gold comes back
-- roughly ten times slower. Profit per unit of time, not profit.
--
-- Hence dividing rather than filtering: hold none and nothing changes at all,
-- hold some and the craft slides down by about as much as it deserves. Nothing
-- is ever hidden by this, so a craft cannot silently vanish from the list.
local function StockDivisor(pipeline)
    local weight = ns.Config:Get("stockPenalty")
    if weight == nil then weight = 1 end

    if weight <= 0 or not pipeline or pipeline <= 0 then return 1 end

    return 1 + (pipeline * weight)
end

--- The value a craft is ranked on: its profit, set against what you already
--- have of it.
--
-- A loss is left alone. Dividing a negative number by a larger divisor moves it
-- closer to zero, which would promote the worst crafts in the list for the sole
-- reason that you are already sitting on a pile of them.
local function RankValue(analysis, field)
    local value = analysis[field]
    if value == nil then return -math.huge end

    if value > 0 then
        return value / (analysis.stockDivisor or 1)
    end

    return value
end

--- How many CRAFTS fit in the room left under the posted limit.
--
-- The limit and the room under it are counted in ITEMS, because that is what
-- goes up for sale. Every queue is counted in CRAFTS. A recipe that yields
-- five per craft makes those two numbers differ by five, so clamping a craft
-- count straight against the item room lets a limit of ten become fifty items
-- on the auction house.
--
-- quantityMin rather than the average yield, matching Logic/Queue.lua,
-- Logic/Crafting.lua and Data/Auctions.lua: the panes must agree with each
-- other on the same recipe, and a fraction of a craft is not a thing.
--
-- Any room at all allows one craft. You cannot make part of one, and refusing
-- the craft outright would stall a queue on a recipe that still has shelf
-- space.
local function RoomInCrafts(room, recipe)
    if room == nil then return nil end
    if room <= 0 then return 0 end

    local perCraft = math.max(1, (recipe and recipe.quantityMin) or 1)

    return math.max(1, math.floor(room / perCraft))
end

-- Exposed for tools/test_mail.lua. These two decide the order of the list the
-- player actually reads, and they are the part most likely to want tuning, so
-- they are testable without standing up the whole analysis.
Profit._StockDivisor = StockDivisor
Profit._RankValue = RankValue

-- Exposed for tools/test_craftroom.lua, and called directly by the panes
-- when they hold a recipe but no analysis.
Profit.RoomInCrafts = RoomInCrafts

--- What the Profit tab's Max button fills in: whichever runs out first,
--- materials or room under the limit. Room left at all allows one craft,
--- but none left is 0. It said 1 there, and Add queued one past the limit.
---
--- With no Keep in Stock set, `learnedRoom` (crafts up to what your sales
--- taught) is the answer, as Queue All has it: "0/3" fills in 3 (a player
--- asked, the owner said yes, 2026-10-22).
function Profit.MaxCrafts(craftableNow, roomInCrafts, learnedRoom)
    if roomInCrafts == nil and learnedRoom ~= nil then return math.max(0, learnedRoom) end
    if roomInCrafts and roomInCrafts <= 0 then return 0 end

    local most = math.max(1, craftableNow or 1)
    if roomInCrafts then most = math.max(1, math.min(most, roomInCrafts)) end
    return most
end

--- What one unit listed at a price pays once sold: the price, less the
--- auction house's cut and the deposits lost to relisting. A deposit not yet
--- known counts as none, so this never undersells the listing.
function Profit:NetFromListing(itemID, unitPrice)
    local cut = ns.Config:Get("auctionCut") or 0.05
    local deposit = ns.Posting:GetCachedUnitDeposit(itemID) or 0
    if deposit <= 0 then return unitPrice * (1 - cut) end
    return unitPrice * (1 - cut) - deposit * Profit.LostListings(itemID)
end

--- How many deposits a sale is expected to lose.
--
-- The auction house hands the deposit back with the money when an item
-- sells, so only a listing that runs out or is cancelled keeps it. The
-- saved `expectedRelists` counts the listings it takes to sell (1, the
-- default, sells on the first), so the deposits lost are one fewer. Counting
-- one deposit on every sale took it off profit twice over.
--
-- An item that sells slowly (Demand "low") is expected to run out once
-- before it sells, so it loses at least one deposit (the owner, 2026-10-20).
-- @param itemID optional; without it only the saved number counts
function Profit.LostListings(itemID)
    local listings = tonumber(ns.Config:Get("expectedRelists")) or 1
    local lost = math.max(0, math.floor(listings) - 1)
    if itemID and lost < 1 and ns.Demand and ns.Demand.Get then
        local ok, demand = pcall(ns.Demand.Get, ns.Demand, itemID)
        if ok and type(demand) == "table" and demand.level == "low" then lost = 1 end
    end
    return lost
end

--------------------------------------------------------------------------------
-- Ways to turn a craft into gold
--------------------------------------------------------------------------------

-- A player's request (Discord, 2026-10-06): see what a craft makes sold at
-- the auction house, sold to a vendor and disenchanted, and rank the list by
-- whichever is picked. "best" takes whichever pays most, as the Level Up
-- tab's GETS BACK does. Ties go to the vendor, then the auction house: the
-- surer sale.
Profit.WAYS = { "vendor", "auction", "disenchant" }

-- What the Profit tab's switch offers, in its order.
Profit.METHODS = { "best", "auction", "vendor", "disenchant" }

-- Short names, for the VIA column and the switch.
Profit.WAY_LABELS = { auction = L["AH"], vendor = L["Vendor"], disenchant = L["DE"] }

-- How /bts why names where a material's price came from (Cost's sources).
local SOURCE_NOTES = {
    buy = L["buy"], vendor = L["vendor"], craft = L["craft"], owned = L["owned"],
}

-- Why a craft has no profit when the list is ranked by one way only.
local NO_WAY_REASON = {
    auction = L["no auction price"],
    vendor = L["no vendor price"],
    disenchant = L["cannot be disenchanted"],
}

--- Can one of your characters disenchant this? Read from what each last
--- recorded, so an alt counts without logging in. nil when nobody knows
--- Enchanting, false when nobody has the skill for this item yet.
local function CanDisenchant(itemID)
    local Disenchant = ns.Disenchant
    if not (Disenchant and Disenchant.GetBestEnchanter) then return nil end

    local skill = Disenchant:GetBestEnchanter()
    if skill == nil then return nil end

    local facts = Disenchant.GetItemFacts and Disenchant:GetItemFacts(itemID)
    local needs = type(facts) == "table" and facts.skill or nil
    return needs == nil or skill >= needs
end

--- The method the Profit tab and its commands rank by: Settings' choice,
--- or "best".
function Profit:GetMethod()
    local method = ns.Config:Get("profitBy")
    for _, known in ipairs(self.METHODS) do
        if known == method then return method end
    end
    return "best"
end

--- The ways a craft can be turned into gold, for the row tooltip, the
--- detail pane and /bts why. Empty when there is only one: the profit
--- already says it.
-- @return { { way, label, profit, chosen, note }, ... } in Profit.WAYS order
function Profit:DescribeWays(analysis)
    local lines = {}
    local ways = analysis and analysis.ways
    if not ways then return lines end

    local labels = { auction = L["If sold at AH"], vendor = L["If vendored"], disenchant = L["If disenchanted"] }

    for _, way in ipairs(self.WAYS) do
        local option = ways[way]
        if option then
            local note
            if way == "disenchant" then
                if option.canDisenchant == nil then
                    note = L["no enchanter"]
                elseif option.canDisenchant == false then
                    note = L["skill too low"]
                end
            end
            lines[#lines + 1] = { way = way, label = labels[way], profit = option.profit,
                chosen = analysis.via == way, note = note }
        end
    end

    if #lines < 2 then return {} end
    return lines
end

--- Full profitability breakdown for one recipe.
--
-- @param method nil for the sale the Sell tab would make (max(auction,
--   vendor), the house rule), "best" for whichever of auction, vendor and
--   disenchanting pays most, or one of those alone. analysis.ways holds
--   all three either way, and analysis.via names the one the profit is for.
--- What a craft makes a day on the auction house: its profit each times
--- about how many sell a day (Prices:GetUnitsSoldPerDay, the Stats tab's
--- number), no more than Keep in stock lists at once. The Profit tab's
--- A DAY, in place of gold an hour, which said nothing of whether it sells
--- (the owner, 2026-10-16). Only for a craft sold on the auction house.
-- @return copper a day, how many that counts, and true when Keep in stock
--         cut the count; nil while there is no sales estimate
function Profit:PerDay(analysis, itemID)
    if analysis.via ~= "auction" or type(analysis.profitPerUnit) ~= "number" then return nil end
    local ok, sells = pcall(ns.Prices.GetUnitsSoldPerDay, ns.Prices, itemID)
    if not ok or type(sells) ~= "number" or sells <= 0 then return nil end

    local capped = false
    if ns.Auctions and ns.Auctions.GetLimit then
        local fine, limit = pcall(ns.Auctions.GetLimit, ns.Auctions, itemID)
        limit = fine and tonumber(limit) or 0
        if limit > 0 and sells > limit then sells, capped = limit, true end
    end
    return analysis.profitPerUnit * sells, sells, capped
end

function Profit:Analyse(recipeID, characterKey, method)
    local recipe, owner = ns.Recipes:GetAny(recipeID)
    if not recipe then return nil end

    local crafter = characterKey or owner

    local analysis = {
        recipeID = recipeID,
        name = recipe.name,
        outputItemID = recipe.outputItemID,
        skillLineID = recipe.skillLineID,
        owner = crafter,
        ownerName = ns.Recipes:GetCharacterName(crafter),
        -- For the narrow WHO column; the full name goes in the row's tooltip.
        ownerShortName = ns.Recipes.GetShortCharacterName
            and ns.Recipes:GetShortCharacterName(crafter) or nil,
        isMine = crafter == ns.Config:GetCharacterKey(),
    }

    local cost = ns.Cost:GetCraftCost(recipeID)
    analysis.cost = cost

    -- Whether the character playing can make it: an alt's recipe, or one of
    -- a dropped profession, has no time or gold an hour (a player asked,
    -- 2026-10-09), since those only mean something for crafts you can cast.
    local myRecipe = ns.Recipes.Get and ns.Recipes:Get(recipeID)
    analysis.knownByMe = myRecipe ~= nil and not (ns.Recipes.IsDropped
        and ns.Recipes:IsDropped(myRecipe, ns.Config:GetCharacterKey()))

    -- How long one takes, sub-crafts included, before the early exits: the
    -- time needs no price.
    if ns.CraftTime and cost and analysis.knownByMe then
        local timing = ns.CraftTime:ForCost(recipeID, cost)
        analysis.craftTime = timing
        analysis.craftSeconds = timing.seconds
    end

    -- Read before the early exits below, so a craft that cannot be priced can
    -- still say it would raise your skill.
    analysis.skillUp = ns.SkillUp and ns.SkillUp:GetForRecipe(recipeID, recipe) or nil

    if not recipe.outputItemID then
        -- Enchants and similar have no sellable output item.
        analysis.reason = L["makes nothing that can be sold"]
        return analysis
    end

    -- What the craft is worth disenchanted, read before the early exits
    -- below: a craft that cannot be sold may still be worth breaking down.
    -- Shown beside the sale price, never ranked on.
    if ns.Disenchant then
        analysis.disenchantable = ns.Disenchant:IsDisenchantable(recipe.outputItemID) or nil
        if analysis.disenchantable then
            local breakdown
            analysis.disenchantValue, analysis.disenchantPartial, breakdown =
                ns.Disenchant:GetValue(recipe.outputItemID)

            -- The material the value is read off, whose price's age is the
            -- age of a disenchant profit.
            for _, outcome in ipairs((breakdown and breakdown.outcomes) or {}) do
                if outcome.counted then analysis.disenchantMaterial = outcome.itemID end
            end
        end
    end

    -- Binds on pickup: the thing made is soulbound the moment it exists, so
    -- there is no sale to cost and no profit to rank on. Out of the list the
    -- same way an unpriced craft is, which keeps it off the skill-up star too,
    -- while "Show unpriced" and the craft pane still show it with its skill-up
    -- colour for anyone levelling on it. Unknown (not cached yet) is kept: the
    -- tab redraws when the item arrives, and a craft that may well sell should
    -- not vanish on a guess.
    if Util.IsBoundOnPickup and Util.IsBoundOnPickup(recipe.outputItemID) then
        analysis.soulbound = true
        analysis.reason = SOULBOUND_REASON
        return analysis
    end

    -- Revenue is what you will actually be paid, which means undercutting the
    -- cheapest listing rather than assuming you get the market average. If
    -- nothing is listed there is no competition to undercut, so the smoothed
    -- market value is the only estimate available.
    -- "rival" excludes your own auctions. If the only listing is yours there is
    -- nobody to undercut, so we hold at market rather than walking our own
    -- price down a copper at a time.
    local competitor = ns.Prices:GetValue(recipe.outputItemID, "rival")

    -- Shown for context so the full picture is visible: the overall cheapest
    -- listing and your own, alongside the rival price actually being undercut.
    local priceRecord = ns.Prices:Get(recipe.outputItemID)
    analysis.overallMin = priceRecord and priceRecord.min or nil
    analysis.ownListing = priceRecord and priceRecord.ownMin or nil

    -- Priced through the same chooser the Sell tab posts at, so the profit
    -- shown here is the profit of the listing that would actually be made.
    -- On an item auction that may be a match rather than an undercut, because
    -- the server will not take a price with copper in it.
    local unitRevenue, basis, _, uncertain =
        self:ChoosePostPrice(recipe.outputItemID, cost)

    -- The listing on its own, kept for analysis.ways before a vendor that
    -- pays more takes its place below.
    local listPrice, listBasis, listUncertain = unitRevenue, basis, uncertain

    -- Worth whichever pays more, that listing or a vendor (the house rule:
    -- max(auction, vendor)). Under what a vendor pays, Posting refuses the
    -- listing anyway, so the vendor is the sale that would be made. A craft
    -- shown as a loss and hidden could be making money at the vendor.
    --
    -- Compared on what each puts in your pocket, as Vendor Flips compares
    -- (a player's report, 2026-10-02): a listing loses the house's cut and its
    -- deposit, a vendor pays in full. A 1g listing against a 97s vendor price
    -- is the vendor's sale, though 1g is the bigger number.
    local vendor = Util.GetVendorSellPrice(recipe.outputItemID)
    if vendor and (not unitRevenue
            or vendor >= self:NetFromListing(recipe.outputItemID, unitRevenue)) then
        unitRevenue, basis, uncertain = vendor, "vendor", nil
    end

    analysis.priceBasis = basis
    -- Set when the price above is the materials-plus-markup estimate rather
    -- than anything the auction house said. Every display of the number
    -- checks this: an estimate presented as a market price is how you end up
    -- crafting for a demand that was never measured.
    analysis.priceDerived = basis == "derived" or nil
    -- Set when the item is scanned but every listing is yours, so the price
    -- above is the markup over materials rather than what anyone else
    -- charges. Told apart from priceDerived because there IS scan data here,
    -- and the age and confidence beside it are real.
    analysis.priceUncontested = basis == "uncontested" or nil
    -- Set when nobody has been able to say whether the output sells as a
    -- commodity or an item auction, so the price above is the plain undercut
    -- and may round to a silver when it is actually listed.
    analysis.priceUncertain = uncertain or nil

    if competitor then
        analysis.competitorPrice = competitor
        analysis.undercut = true
        analysis.matchedRival = basis == "match"
    else
        analysis.undercut = false
        analysis.youHoldLowest = ns.Prices:HoldsLowest(recipe.outputItemID)
    end

    -- What you already hold, listed or otherwise. Crafting past this gets
    -- you nothing you do not already own, and ties up gold doing it. Read
    -- before the price checks below, since none of it needs a price: a craft
    -- with no price still has a Keep in stock limit.
    local room, posted, onHand, queued, limit, inMail, waiting, extra =
        ns.Auctions:GetRoom(recipe.outputItemID)

    analysis.posted = posted
    analysis.onHand = onHand
    analysis.inMail = inMail or 0
    analysis.stock = posted + onHand + analysis.inMail
    analysis.queuedElsewhere = queued
    analysis.postLimit = limit
    analysis.postRoom = room
    analysis.roomInCrafts = RoomInCrafts(room, recipe)
    analysis.atPostLimit = room ~= nil and room <= 0
    -- Held back only by "Wait until it runs low", not by the limit itself.
    analysis.waitingForLow = waiting == true
    analysis.restockAt = waiting and ns.Auctions:GetRestockAt() or nil
    analysis.fastSellerExtra = extra or 0
    -- The limit as set, without the fast-seller extra: what the Keep in
    -- stock box shows and saves, or each edit would add the extra again.
    analysis.baseLimit = room ~= nil and math.max(0, (limit or 0) - (extra or 0)) or 0
    -- With no number set, what your sales taught: Queue All and a sale's
    -- restock use it, and the detail pane says so.
    analysis.learnedLimit = room == nil and ns.Auctions.GetLearnedLimit
        and ns.Auctions:GetLearnedLimit(recipe.outputItemID) or nil
    -- And the crafts that leaves room for, which Max fills in.
    if analysis.learnedLimit then
        local learnedRoom = ns.Auctions:GetRoom(recipe.outputItemID, nil, true)
        analysis.learnedRoomInCrafts = RoomInCrafts(learnedRoom, recipe)
    end

    -- Ranked by disenchanting, a craft no auction or vendor prices may
    -- still be worth breaking down.
    local countsDisenchant = (method == "best" or method == "disenchant")
        and analysis.disenchantValue ~= nil

    if not unitRevenue and not countsDisenchant then
        -- A craft can land here with priced materials when the estimate is
        -- switched off, and with unpriced ones either way; the reason below
        -- covers both, since the output is what has no price in each.
        analysis.reason = L["output has no price data"]
        return analysis
    end

    if not cost or not cost.priceable then
        analysis.reason = L["a reagent has no price data"]
        analysis.unpriced = cost and cost.unpriced or nil
        return analysis
    end

    local yield = cost.yield or 1

    analysis.yield = yield

    -- One item disenchanted against one item sold at the price above.
    if analysis.disenchantValue and unitRevenue and analysis.disenchantValue > unitRevenue then
        analysis.disenchantBeatsSale = true
    end

    analysis.totalCost = cost.total
    analysis.costPerUnit = cost.perUnit

    local auctionCut = ns.Config:Get("auctionCut") or 0.05

    -- Every way to turn the craft into gold, each costed in full.
    local ways = {}

    if listPrice then
        local revenue = listPrice * yield
        local cut = revenue * auctionCut

        -- The deposit is paid up front and comes back when the item sells,
        -- so only the listings expected to run out first cost it.
        local held = HeldDeposit(recipe.outputItemID, yield)
        local deposit = held and held * Profit.LostListings(recipe.outputItemID) or 0

        ways.auction = { unit = listPrice, revenue = revenue, cut = cut, deposit = deposit,
            depositHeld = held, depositKnown = held ~= nil, basis = listBasis, uncertain = listUncertain,
            profit = revenue - cut - cost.total - deposit }
    end

    -- A vendor takes no cut and asks no deposit.
    if vendor and vendor > 0 then
        local revenue = vendor * yield
        ways.vendor = { unit = vendor, revenue = revenue, cut = 0, deposit = 0,
            depositKnown = true, basis = "vendor", profit = revenue - cost.total }
    end

    -- The most likely result, less the cut on selling the materials. No
    -- deposit: the materials' is small, and nobody can say which listing
    -- they would join.
    if analysis.disenchantValue and analysis.disenchantValue > 0 then
        local revenue = analysis.disenchantValue * yield
        local cut = revenue * auctionCut
        ways.disenchant = { unit = analysis.disenchantValue, revenue = revenue, cut = cut,
            deposit = 0, depositKnown = true, basis = "disenchant",
            partial = analysis.disenchantPartial,
            canDisenchant = CanDisenchant(recipe.outputItemID),
            profit = revenue - cut - cost.total }
    end

    analysis.ways = ways

    -- Which way the profit shown is for.
    local via
    if method == nil then
        -- The sale the Sell tab would make, decided above.
        via = basis == "vendor" and "vendor" or "auction"
    elseif method == "best" then
        for _, way in ipairs(self.WAYS) do
            local option = ways[way]
            -- Disenchanting counts only when one of your characters can.
            local usable = option and (way ~= "disenchant" or option.canDisenchant == true)
            if usable and (not via or option.profit > ways[via].profit) then via = way end
        end
    else
        via = method
    end

    local chosen = via and ways[via]
    if not chosen then
        analysis.reason = method and NO_WAY_REASON[method] or L["output has no price data"]
        return analysis
    end

    analysis.via = via
    analysis.priceBasis = chosen.basis
    analysis.priceDerived = chosen.basis == "derived" or nil
    analysis.priceUncontested = chosen.basis == "uncontested" or nil
    analysis.priceUncertain = chosen.uncertain or nil
    if analysis.undercut then analysis.matchedRival = chosen.basis == "match" end

    analysis.unitRevenue = chosen.unit
    analysis.revenue = chosen.revenue
    analysis.cut = chosen.cut
    analysis.netRevenue = chosen.revenue - chosen.cut
    analysis.depositKnown = chosen.depositKnown
    analysis.deposit = chosen.deposit
    analysis.depositHeld = chosen.depositHeld

    analysis.profit = chosen.profit
    analysis.profitPerUnit = analysis.profit / yield

    -- Gold an hour, for the time the crafts take. Disenchanted, each item
    -- made is a disenchant cast more.
    local seconds = analysis.craftSeconds
    if seconds and via == "disenchant" then
        local cast = ns.CraftTime:GetCast(ns.CraftTime.DISENCHANT_SPELL)
        seconds = cast and (seconds + cast * yield) or nil
    end
    analysis.timeSeconds = seconds
    analysis.goldPerHour = ns.CraftTime and ns.CraftTime.PerHour(analysis.profit, seconds) or nil

    -- Margin is profit against revenue; ROI is profit against the gold you must
    -- actually front. They rank very differently and both are worth seeing.
    analysis.margin = analysis.revenue > 0 and (analysis.profit / analysis.revenue) or 0
    analysis.roi = cost.total > 0 and (analysis.profit / cost.total) or 0

    analysis.confidence, analysis.confidenceReason = ns.Prices:GetConfidence(recipe.outputItemID)
    analysis.liquidity = ns.Prices:GetSalesPerDay(recipe.outputItemID)
    analysis.perDay, analysis.perDaySells, analysis.perDayCapped = self:PerDay(analysis, recipe.outputItemID)
    -- The age of the price the profit is for (Discord, 2026-10-08):
    -- a disenchant is valued at its material, so that scan's age is the one
    -- that says how far to trust it. A vendor's price does not age; the
    -- output's own scan stays here for /bts why and the row draws a dash.
    local agedItem = via == "disenchant" and analysis.disenchantMaterial or recipe.outputItemID
    analysis.ageItemID = agedItem
    analysis.stale = ns.Prices:IsStale(agedItem)
    analysis.age = ns.Prices:GetAge(agedItem)

    analysis.craftableNow = self:GetCraftableCount(recipeID, crafter)
    analysis.priceable = true

    -- Everything already committed to this item: what you hold, plus what the
    -- queue is about to make. This is what pushes a craft down the list.
    analysis.pipeline = analysis.stock + queued
    analysis.stockDivisor = StockDivisor(analysis.pipeline)

    -- Worth a star: it raises your skill and it pays. Only a mark -- the
    -- ranking is untouched, so nothing moves up the list for being a skill up
    -- and nothing is hidden for not being one.
    analysis.recommended = ns.SkillUp and ns.SkillUp:IsWorthIt(analysis) or false

    return analysis
end

--------------------------------------------------------------------------------
-- Ignored crafts
--------------------------------------------------------------------------------

-- Asked 2026-10-03: a way to "permanently add a profit listed craft to
-- ignore so it no longer appears in the recommended list". Kept for the whole
-- account, and Settings lists them with a Restore button, so a misclick is
-- never for good.

function Profit:IsIgnored(recipeID)
    return recipeID ~= nil and ns.db ~= nil and ns.db.ignoredCrafts ~= nil
        and ns.db.ignoredCrafts[recipeID] ~= nil
end

--- Ignore a craft (ignored = true) or bring it back (false).
function Profit:SetIgnored(recipeID, ignored, name)
    if not ns.db or not recipeID then return end
    ns.db.ignoredCrafts = ns.db.ignoredCrafts or {}

    if ignored then
        local known = ns.Recipes and ns.Recipes.GetAny and ns.Recipes:GetAny(recipeID)
        ns.db.ignoredCrafts[recipeID] = name or (known and known.name)
            or ("recipe " .. tostring(recipeID))
    else
        ns.db.ignoredCrafts[recipeID] = nil
    end

    if ns.UI and ns.UI.RefreshActiveTab then ns.UI:RefreshActiveTab() end
    -- The pane beside the profession window leaves ignored crafts out too.
    if ns.CraftPanel and ns.CraftPanel.RequestRefresh then ns.CraftPanel:RequestRefresh() end
end

--- The ignored crafts, A to Z: { { recipeID, name }, ... }.
function Profit:GetIgnored()
    local list = {}
    for recipeID, name in pairs(ns.db and ns.db.ignoredCrafts or {}) do
        list[#list + 1] = { recipeID = recipeID,
                            name = type(name) == "string" and name or ("recipe " .. tostring(recipeID)) }
    end
    table.sort(list, function(a, b)
        local left, right = a.name:lower(), b.name:lower()
        if left ~= right then return left < right end
        return a.recipeID < b.recipeID
    end)
    return list
end

--------------------------------------------------------------------------------
-- Ranking
--------------------------------------------------------------------------------

--- Analyse every cached recipe.
-- @param opts { craftableOnly, minProfit, minMargin, includeUnpriceable,
--               includeIgnored, skillLineID, sortBy = "profit"|"margin"|"roi",
--               method = see Analyse }
function Profit:GetRanked(opts)
    opts = opts or {}

    local minProfit = opts.minProfit or ns.Config:Get("minProfit") or 0
    local minMargin = (opts.minMargin or ns.Config:Get("minMarginPercent") or 0) / 100

    local results = {}

    -- Account-wide pulls in every character's cached recipes, each analysed
    -- against the bags of whoever actually knows it.
    -- Crafts of a profession the character has dropped are left out.
    local source = opts.accountWide and ns.Recipes:GetAccountWide(true) or ns.Recipes:GetAll()

    for recipeID, recipe in pairs(source) do
        local dropped = not opts.accountWide and ns.Recipes.IsDropped ~= nil
            and ns.Recipes:IsDropped(recipe)
        -- An ignored craft is never analysed, so it is gone everywhere this
        -- list is used: the rows, Queue All and the empty-list message.
        local ignored = not opts.includeIgnored and self:IsIgnored(recipeID)
        local analysis = not dropped and not ignored and self:Analyse(recipeID, nil, opts.method) or nil

        if analysis then
            local keep = true

            if not analysis.priceable then
                keep = opts.includeUnpriceable == true
            else
                if analysis.profit < minProfit then keep = false end
                if keep and analysis.margin < minMargin then keep = false end
                if keep and opts.craftableOnly and analysis.craftableNow < 1 then keep = false end

                -- Already holding as many as you want listed. Not a row
                -- already on screen, though: queueing up to the limit would
                -- make it vanish under the cursor.
                if keep and analysis.atPostLimit
                   and ns.Config:Get("hideAtPostLimit") ~= false
                   and not opts.ignorePostLimit
                   and not (opts.keepOrder and opts.keepOrder[recipeID]) then
                    keep = false
                end
            end

            if keep and opts.skillLineID and analysis.skillLineID ~= opts.skillLineID then
                keep = false
            end

            if keep then
                results[#results + 1] = analysis
            end
        end
    end

    local sortBy = opts.sortBy or "profit"

    -- Ranked on profit adjusted for what you already hold; the columns still
    -- show the real figure, because that is the number you are deciding on.
    -- opts.ignoreStock is for callers that want the raw order, such as the
    -- tests and anything reporting on the market rather than on your shelf.
    --
    -- opts.keepOrder ({ [recipeID] = place }) holds rows already on screen
    -- where they are, and anything new goes after them in the usual order.
    -- Queueing counts as stock you will have, so without it a right-click
    -- to queue dropped the row and the next click queued something else.
    local keepOrder = opts.keepOrder

    table.sort(results, function(a, b)
        if keepOrder then
            local ka, kb = keepOrder[a.recipeID], keepOrder[b.recipeID]
            if ka and kb then return ka < kb end
            if ka or kb then return ka ~= nil end
        end

        local left = opts.ignoreStock and (a[sortBy] or -math.huge) or RankValue(a, sortBy)
        local right = opts.ignoreStock and (b[sortBy] or -math.huge) or RankValue(b, sortBy)

        if left == right then
            -- Two recipes can share a name, so the recipe ID settles the
            -- rest; otherwise those rows swapped places on every redraw.
            if (a.name or "") ~= (b.name or "") then
                return (a.name or "") < (b.name or "")
            end
            return (a.recipeID or 0) < (b.recipeID or 0)
        end
        return left > right
    end)

    return results
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function ProfitColor(value)
    return value >= 0 and ns.COLORS.profit or ns.COLORS.loss
end

-- The last list shown to the player, so they can refer to a row by its number
-- instead of hunting for an internal recipe ID.
Profit.lastListing = {}

--- Turn player input into a single recipe.
-- Accepts a row number from the last listing, a shift-clicked item link, an
-- item or recipe ID, or part of a recipe name.
-- @return recipe, errorMessage, ambiguousMatches
function Profit:Resolve(query)
    query = (query or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if query == "" then
        return nil, L["type a name, shift-click an item, or give a row number from /bts top"]
    end

    -- Plain small numbers are row numbers from the last listing, which is what
    -- someone reading that list will naturally type.
    local rowNumber = tonumber(query)
    if rowNumber and self.lastListing[rowNumber] then
        return self.lastListing[rowNumber]
    end

    local matches = ns.Recipes:Find(query)

    if #matches == 0 then
        return nil, L.Format("none of your recipes match '%s'", query)
    end

    if #matches > 1 then
        -- An exact name match wins outright even if it also prefixes others.
        local needle = query:lower()
        if (matches[1].name or ""):lower() == needle then
            return matches[1]
        end
        return nil, nil, matches
    end

    return matches[1]
end

ns.RegisterCommand("top", L["[count]: most profitable crafts right now"], function(args)
    -- At least one: "/bts top 0" printed a heading over an empty list.
    local limit = math.max(1, tonumber(args:match("(%d+)")) or 10)

    if ns.Recipes:Count() == 0 then
        ns.Print(L["no recipes read yet. Open a profession window once"])
        return
    end

    if ns.Prices:Count() == 0 then
        ns.Print(L["no price data yet. Run |cffc8a44d/bts scan|r at the auction house"])
        return
    end

    local ranked = ns.Profit:GetRanked({ sortBy = "profit", method = ns.Profit:GetMethod() })

    if #ranked == 0 then
        ns.Print(L["nothing is profitable with the current price data"])
        return
    end

    local shown = math.min(limit, #ranked)
    ns.Print(L.Format("top %d by profit per craft", shown))

    wipe(ns.Profit.lastListing)

    for i = 1, shown do
        local entry = ranked[i]
        ns.Profit.lastListing[i] = ns.Recipes:Get(entry.recipeID)

        local flags = {}
        if entry.stale then flags[#flags + 1] = L["stale"] end
        if entry.craftableNow > 0 then flags[#flags + 1] = L.Format("can make %d", entry.craftableNow) end
        if (entry.confidence or 0) < 0.4 and entry.confidenceReason then
            flags[#flags + 1] = entry.confidenceReason
        end

        ns.PrintRaw(L.Format("  |c%s%2d.|r %s  |c%s%s|r  (%d%% margin)  %s",
            ns.COLORS.accent, i,
            ns.Recipes:GetDisplayLink(entry.recipeID),
            ProfitColor(entry.profit), Util.FormatMoney(entry.profit, { short = true }),
            math.floor((entry.margin or 0) * 100),
            #flags > 0 and ("|c%s[%s]|r"):format(ns.COLORS.muted, table.concat(flags, ", ")) or ""))
    end

    ns.PrintRaw(L.Format("|c%sFor detail: |r|c%s/bts why 1|r|c%s, or /bts why <name>, or shift-click an item into the command.|r",
        ns.COLORS.muted, ns.COLORS.accent, ns.COLORS.muted))
end)

ns.RegisterCommand("why", L["<name, link or row number>: full cost breakdown"], function(args)
    local recipe, errorMessage, ambiguous = ns.Profit:Resolve(args)

    if ambiguous then
        ns.Print(L.Format("several recipes match '%s':", args))

        wipe(ns.Profit.lastListing)
        for i = 1, math.min(#ambiguous, 10) do
            ns.Profit.lastListing[i] = ambiguous[i]
            ns.PrintRaw(("  |c%s%2d.|r %s"):format(
                ns.COLORS.accent, i, ns.Recipes:GetDisplayLink(ambiguous[i].recipeID)))
        end

        ns.PrintRaw(L.Format("|c%sRun |r|c%s/bts why <number>|r|c%s to pick one.|r",
            ns.COLORS.muted, ns.COLORS.accent, ns.COLORS.muted))
        return
    end

    if not recipe then
        ns.Print(errorMessage)
        return
    end

    local analysis = ns.Profit:Analyse(recipe.recipeID, nil, ns.Profit:GetMethod())
    if not analysis then
        ns.Print(L["that recipe is no longer saved"])
        return
    end

    ns.Print(ns.Recipes:GetDisplayLink(recipe.recipeID))

    if not analysis.priceable then
        ns.PrintRaw(("  |c%s%s|r"):format(ns.COLORS.warn, analysis.reason or L["cannot be priced"]))

        if analysis.unpriced then
            for _, itemID in ipairs(analysis.unpriced) do
                ns.PrintRaw(L.Format("    |c%sno auction data for|r %s",
                    ns.COLORS.muted, Util.GetItemLabel(itemID)))
            end
        end
        return
    end

    for _, reagent in ipairs(analysis.cost.reagents) do
        local maker = reagent.madeBy and ns.Cost and ns.Cost.MadeByName and ns.Cost.MadeByName(reagent.madeBy)
        local note = maker and L.Format("made by %s", maker)
            or reagent.crafted and L["cheaper to craft"]
            or reagent.source == "mine" and L["my price"] or SOURCE_NOTES[reagent.source] or reagent.source
        local shortfall = reagent.shortfall > 0
            and L.Format(" |c%sneed %d more|r", ns.COLORS.warn, reagent.shortfall)
            or ""

        ns.PrintRaw(("  %dx %s  @ %s = %s  |c%s%s|r%s"):format(
            reagent.quantity, Util.GetItemLabel(reagent.itemID),
            Util.FormatMoney(reagent.unitCost), Util.FormatMoney(reagent.lineCost),
            ns.COLORS.muted, note or "", shortfall))
    end

    ns.PrintRaw(L.Format("  material cost   %s", Util.FormatMoney(analysis.totalCost)))

    if analysis.priceBasis == "disenchant" then
        ns.PrintRaw(L.Format("  |c%sdisenchanting pays most, so it is valued at its most likely result|r",
            ns.COLORS.profit))
        ns.PrintRaw(L.Format("  disenchants to  %s  (makes %.1f)",
            Util.FormatMoney(analysis.unitRevenue), analysis.yield))
    elseif analysis.priceBasis == "vendor" then
        -- Said before the number: this one is not going to the auction house.
        if analysis.undercut then
            ns.PrintRaw(L.Format("  cheapest rival  %s", Util.FormatMoney(analysis.competitorPrice)))
        end
        ns.PrintRaw(L.Format("  |c%sa vendor pays more than a listing would, so it is valued at that|r",
            ns.COLORS.profit))
        ns.PrintRaw(L.Format("  vendor pays     %s  (makes %.1f)",
            Util.FormatMoney(analysis.unitRevenue), analysis.yield))
    elseif analysis.priceBasis == "mine" or analysis.priceBasis == "floor"
        or analysis.priceBasis == "highest" then
        local said = L["raised to the least you set on the Prices tab"]
        if analysis.priceBasis == "mine" then
            said = L["priced at your own price, set on the Prices tab"]
        elseif analysis.priceBasis == "highest" then
            said = L["lowered to the most you set on the Prices tab"]
        end
        ns.PrintRaw(("  |c%s%s|r"):format(ns.COLORS.warn, said))
        ns.PrintRaw(L.Format("  you post at     %s  (makes %.1f)",
            Util.FormatMoney(analysis.unitRevenue), analysis.yield))
    elseif analysis.undercut then
        ns.PrintRaw(L.Format("  cheapest rival  %s", Util.FormatMoney(analysis.competitorPrice)))
        ns.PrintRaw(L.Format("  you post at     %s  (makes %.1f)",
            Util.FormatMoney(analysis.unitRevenue), analysis.yield))
    elseif analysis.priceUncontested then
        -- Said before the number: nobody is competing, so this price is your
        -- own materials plus the markup, not what the market is doing.
        ns.PrintRaw(L.Format("  |c%snobody else is listing one, so this is priced off your materials|r",
            ns.COLORS.profit))
        ns.PrintRaw(L.Format("  you post at     %s  (makes %.1f)",
            Util.FormatMoney(analysis.unitRevenue), analysis.yield))
    elseif analysis.youHoldLowest then
        ns.PrintRaw(L.Format("  |c%syou already have the cheapest listing, so staying at market price|r",
            ns.COLORS.profit))
        ns.PrintRaw(L.Format("  you post at     %s  (makes %.1f)",
            Util.FormatMoney(analysis.unitRevenue), analysis.yield))
    elseif analysis.priceDerived then
        -- Said before the number, not after it: this one is the addon's own
        -- estimate and reading it as a market price is the mistake to avoid.
        ns.PrintRaw(L.Format("  |c%snever scanned, so estimated from material value|r",
            ns.COLORS.warn))
        ns.PrintRaw(L.Format("  estimate at     %s  (makes %.1f)",
            Util.FormatMoney(analysis.unitRevenue), analysis.yield))
    else
        ns.PrintRaw(L.Format("  none listed     posting at market %s  (makes %.1f)",
            Util.FormatMoney(analysis.unitRevenue), analysis.yield))
    end
    if analysis.priceBasis == "vendor" then
        ns.PrintRaw(L.Format("  |c%sno auction cut or deposit on a vendor sale|r", ns.COLORS.muted))
    elseif analysis.priceBasis == "disenchant" then
        ns.PrintRaw(L.Format("  cut on the materials -%s", Util.FormatMoney(analysis.cut)))
    else
        ns.PrintRaw(L.Format("  auction cut     -%s", Util.FormatMoney(analysis.cut)))

        if analysis.depositKnown and (analysis.deposit or 0) <= 0 and analysis.depositHeld then
            ns.PrintRaw(L.Format("  deposit         %s, back when it sells", Util.FormatMoney(analysis.depositHeld)))
        elseif analysis.depositKnown then
            ns.PrintRaw(L.Format("  deposit         -%s", Util.FormatMoney(analysis.deposit)))
        else
            ns.PrintRaw(L.Format("  |c%sdeposit unknown until you visit an auction house|r",
                ns.COLORS.muted))
        end
    end
    ns.PrintRaw(L.Format("  |c%sprofit          %s|r  (%.0f%% margin, %.0f%% return on cost)",
        ProfitColor(analysis.profit), Util.FormatMoney(analysis.profit),
        math.floor(analysis.margin * 100), math.floor(analysis.roi * 100)))
    for _, line in ipairs(ns.Profit:DescribeWays(analysis)) do
        ns.PrintRaw(("  |c%s%s|r  %s%s"):format(line.chosen and ns.COLORS.accent or ns.COLORS.muted,
            line.label, Util.FormatMoney(line.profit), line.note and ("  |c%s%s|r"):format(ns.COLORS.muted, line.note) or ""))
    end
    ns.PrintRaw(L.Format("  |c%sconfidence %d%%%s, data read %s|r",
        ns.COLORS.muted, math.floor((analysis.confidence or 0) * 100),
        analysis.confidenceReason and (" (" .. analysis.confidenceReason .. ")") or "",
        Util.FormatAgeAgo(analysis.age)))
end)

--- What the client says about binding, for every cached recipe's output.
--
-- The Profit list drops a craft on the strength of one number out of
-- GetItemInfo. This is how to see that number rather than trust it: how many
-- outputs read as bound, how many as sellable, how many the client has not
-- cached yet, and which crafts were taken out.
ns.RegisterCommand("soulbound", L["which crafts are left out of the Profit list for binding on pickup"],
function()
    local bound, free, unknown = {}, 0, 0
    local byType = {}

    for recipeID, recipe in pairs(ns.Recipes:GetAll()) do
        if recipe.outputItemID then
            local isBound, bindType = Util.IsBoundOnPickup(recipe.outputItemID)

            if bindType then
                byType[bindType] = (byType[bindType] or 0) + 1
            end

            if isBound == nil then
                unknown = unknown + 1
            elseif isBound then
                bound[#bound + 1] = recipeID
            else
                free = free + 1
            end
        end
    end

    ns.Print(L.Format("|c%sSoulbound crafts|r", ns.COLORS.accent))
    ns.PrintRaw(L.Format("  %d bind on pickup (left out), %d can be sold, %d not loaded by the game yet",
        #bound, free, unknown))

    local types = {}
    for bindType, count in pairs(byType) do
        types[#types + 1] = ("type %d: %d"):format(bindType, count)
    end
    table.sort(types)
    ns.PrintRaw(("  |c%sbind type the game gave: %s  (1 pickup, 2 equip, 3 use, 4 quest)|r"):format(
        ns.COLORS.muted, #types > 0 and table.concat(types, ", ") or "nothing answered"))

    table.sort(bound, function(a, b)
        local left, right = ns.Recipes:GetAny(a), ns.Recipes:GetAny(b)
        return ((left and left.name) or "") < ((right and right.name) or "")
    end)

    for i = 1, math.min(#bound, 15) do
        ns.PrintRaw("    " .. ns.Recipes:GetDisplayLink(bound[i]))
    end

    if #bound > 15 then
        ns.PrintRaw(L.Format("    |c%s...and %d more|r", ns.COLORS.muted, #bound - 15))
    end
end)
