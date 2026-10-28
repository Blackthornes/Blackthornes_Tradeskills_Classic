-- Blackthornes Tradeskills -- Data/Prices.lua
-- The price database: what an item costs, what it is worth, and how confident
-- we are about either number.
--
-- Everything here is derived from our own scans. There is no external data
-- source, so the honest thing to do is track how thin the evidence is and
-- surface that alongside the number, rather than presenting a single
-- authoritative-looking price built from three listings.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Prices = ns.NewModule("Prices")

local Util = ns.Util

-- How much of a new scan's value replaces the running average. Low enough that
-- one weird scan cannot swing a price, high enough to track a real move.
local EMA_ALPHA = 0.3

-- Fraction of an item's listed quantity treated as "the market" when pricing.
-- Only the cheap end of the book matters: nobody sells at the 40th percentile.
local MARKET_DEPTH = 0.25

-- Outlier guards, applied against the first-pass weighted mean.
local OUTLIER_LOW = 0.30
local OUTLIER_HIGH = 3.00

-- A lone listing this far under everything else is not the price to beat.
-- Asked 2026-09-26: "make undercut ignore a lone low posting".
local LONE_LOW = 1 / 3

-- The most copper a price is allowed to be before it is read as junk rather
-- than as a market observation.
--
-- 2026-09-21: a full scan came back with a listing at 9,999,990,200 copper --
-- about 999,999g -- which went into the database as that item's market value
-- and minimum, and then failed the save outright, because the client's own
-- number formatting cannot write a value past the signed 32-bit range.
-- Serialize handles the writing now, but the price still had no business being
-- treated as what the item is worth: the cap on a classic-era character's purse
-- is the same 2^31 copper, so nobody can pay it, nobody buys at it, and a craft
-- priced off it goes to the top of the Profit list and never sells.
--
-- Anything at or below this is kept exactly as the client reported it. Only the
-- impossible is refused.
local MAX_CREDIBLE_COPPER = 2 ^ 31 - 1

Prices.MAX_CREDIBLE_COPPER = MAX_CREDIBLE_COPPER

--- Could this price actually be paid, and is it a number at all?
-- Nil is credible: "no price" is a real state and is not what this rejects.
function Prices.IsCredible(price)
    if price == nil then return true end

    return type(price) == "number"
        and price == price                  -- NaN fails every comparison below
        and price >= 0
        and price <= MAX_CREDIBLE_COPPER
end

-- How many price steps of the book are kept for buying many at once. A craft
-- that needs 20 of something cannot all be bought at the cheapest listing
-- when only 3 are listed there (a player asked, the owner agreeing 2026-10-11),
-- so the cost of N walks up these steps. A handful covers a run of crafts;
-- past the last step, what is left is priced at it. Ten since Overcutting
-- (2026-10-15), which looks for the big stack a few steps up the book.
local LADDER_STEPS = 10

Prices.LADDER_STEPS = LADDER_STEPS

-- Keeping full history for every item on the auction house would bloat
-- SavedVariables badly, so history is a short ring and stale items are pruned.
local MAX_HISTORY = 12
local PRUNE_AFTER_SECONDS = 21 * 24 * 3600

--------------------------------------------------------------------------------
-- Market value
--------------------------------------------------------------------------------

--- Is the cheapest listing a lone one far below the rest of the book?
--
-- Someone else's single listing under a third of the next listing up, and
-- under a third of what the item has been selling for when that is known.
-- Following it down would list well under value to chase one seller, and
-- anyone buying clears it in one purchase anyway. Two listings down there
-- are a real price drop and are left alone, as is a listing with nothing
-- above it to compare against.
--
-- So is one that holds half or more of everything listed. Nobody clears
-- that in one purchase: 1000 Linen at 10c, with 60 more at 50c, is where
-- Linen sells now. Skipped, it left the price to beat at 50c while the 1000
-- sat at 10c. A stack among several, the usual lone listing, is still
-- skipped.
--
-- @param listings sorted cheapest first
-- @param reference the item's stored market value, or nil
-- @param totalQuantity units across the whole book
local function IsLoneLow(listings, reference, totalQuantity)
    local first, second = listings[1], listings[2]
    if not first or not second or first.isOwn then return false end

    local quantity = first.quantity or 1
    if quantity > 1 and quantity * 2 >= (totalQuantity or quantity) then return false end

    if first.unitPrice >= second.unitPrice * LONE_LOW then return false end
    if reference and reference > 0 and first.unitPrice >= reference * LONE_LOW then return false end

    return true
end

--- The cheap end of the book as it can be bought: other sellers' listings,
--- cheapest first, one step per price, kept flat as { price, count, price,
--- count, ... } so the saved data stays small. Your own listings cannot be
--- bought, so they are left out.
-- @param listings sorted cheapest first, the lone low listing already out
local function BuildLadder(listings)
    local ladder = {}
    for i = 1, #listings do
        local listing = listings[i]
        if not listing.isOwn then
            local n = #ladder
            local quantity = listing.quantity or 1
            if n > 0 and ladder[n - 1] == listing.unitPrice then
                ladder[n] = ladder[n] + quantity
            elseif n >= LADDER_STEPS * 2 then
                break
            else
                ladder[n + 1] = listing.unitPrice
                ladder[n + 2] = quantity
            end
        end
    end
    return ladder
end

--- Collapse one item's listings into a single representative unit price.
-- @param listings array of { unitPrice = copper, quantity = n, isOwn = bool }
-- @param reference the item's stored market value, when known. Only used to
--   decide whether the cheapest listing is a lone low one.
-- @return marketValue, minBuyout, totalQuantity, rivalMin, ownMin, ignoredLow,
--   ladder
--   ignoredLow is the price of a lone low listing left out of rivalMin and
--   market value, or nil. ladder is the first price steps of other sellers'
--   listings (BuildLadder), empty when none are listed.
function Prices:Summarise(listings, reference)
    if not listings or #listings == 0 then
        return nil, nil, 0, nil, nil, nil, nil
    end

    table.sort(listings, function(a, b) return a.unitPrice < b.unitPrice end)

    local totalQuantity = 0
    for i = 1, #listings do
        totalQuantity = totalQuantity + (listings[i].quantity or 1)
    end

    -- What it costs to buy one right now is still the true cheapest.
    local minBuyout = listings[1].unitPrice

    -- Everything below works on the book without the lone low listing, so it
    -- is neither undercut nor allowed to drag market value down. The caller's
    -- table is left as it was.
    local ignoredLow
    if IsLoneLow(listings, reference, totalQuantity) then
        ignoredLow = listings[1].unitPrice

        local rest = {}
        for i = 2, #listings do rest[#rest + 1] = listings[i] end
        listings = rest
    end

    -- The price to undercut is the cheapest listing that is not yours.
    --
    -- Listings are sorted ascending, so this finds the cheapest rival wherever
    -- it sits relative to your own auction: if somebody has posted far below
    -- you, that is the price you have to beat to sell, and this picks it up.
    -- Skipping your own listings only stops you undercutting yourself; it never
    -- hides a cheaper competitor.
    --
    -- Market value still counts your listings: they are part of the market.
    local ladder = BuildLadder(listings)

    local rivalMin, ownMin
    for i = 1, #listings do
        local listing = listings[i]

        if listing.isOwn then
            ownMin = ownMin or listing.unitPrice
        else
            rivalMin = rivalMin or listing.unitPrice
        end

        if rivalMin and ownMin then break end
    end

    -- First pass: weighted mean over the cheapest slice of the book.
    local targetQuantity = math.max(1, math.floor(totalQuantity * MARKET_DEPTH + 0.5))
    local takenQuantity, weightedSum = 0, 0

    for i = 1, #listings do
        local listing = listings[i]
        local quantity = listing.quantity or 1
        local take = math.min(quantity, targetQuantity - takenQuantity)

        if take <= 0 then break end

        weightedSum = weightedSum + listing.unitPrice * take
        takenQuantity = takenQuantity + take
    end

    if takenQuantity == 0 then
        return minBuyout, minBuyout, totalQuantity, rivalMin, ownMin, ignoredLow, ladder
    end

    local firstPass = weightedSum / takenQuantity

    -- Second pass: drop listings that are absurd relative to the first pass.
    -- A single 1-copper troll listing should not define the market, and neither
    -- should someone's 500g fat-finger.
    local low, high = firstPass * OUTLIER_LOW, firstPass * OUTLIER_HIGH
    local keptQuantity, keptSum = 0, 0

    for i = 1, #listings do
        local listing = listings[i]
        local quantity = listing.quantity or 1

        if listing.unitPrice >= low and listing.unitPrice <= high then
            local take = math.min(quantity, targetQuantity - keptQuantity)
            if take > 0 then
                keptSum = keptSum + listing.unitPrice * take
                keptQuantity = keptQuantity + take
            end
        end
    end

    local marketValue = keptQuantity > 0 and (keptSum / keptQuantity) or firstPass

    return math.floor(marketValue + 0.5), minBuyout, totalQuantity, rivalMin, ownMin, ignoredLow, ladder
end

--------------------------------------------------------------------------------
-- Recording
--------------------------------------------------------------------------------

function Prices:GetTable()
    return ns.Config:GetPriceTable()
end

-- Which item each recent change was about, so a list can redo only the rows
-- those items fill rather than rebuild itself for one price (the owner's
-- smooth play rule). Keyed by the change's number: an item ID, or false for
-- a change that touched no one item. Only the last TOUCH_KEPT are kept.
Prices.touched = {}
local TOUCH_KEPT = 32

--- Count a change to the prices, and remember which item it was about.
function Prices:Touch(itemID)
    Prices.changes = (Prices.changes or 0) + 1
    Prices.touched[Prices.changes] = itemID or false
    Prices.touched[Prices.changes - TOUCH_KEPT] = nil
end

--- The items changed since change number `since`, as { [itemID] = true },
--- or nil when that cannot be told: too many changes, one that touched no
--- one item, or one counted without Touch (a guild's prices). nil means
--- build again from scratch.
function Prices:TouchedSince(since)
    local now = Prices.changes or 0
    if type(since) ~= "number" or since > now or now - since > TOUCH_KEPT then return nil end
    local items = {}
    for change = since + 1, now do
        local itemID = Prices.touched[change]
        if not itemID then return nil end
        items[itemID] = true
    end
    return items
end

--- Is this a ladder that can be walked: pairs of a credible price and a
--- count above 0, cheapest first?
local function ValidLadder(ladder)
    if type(ladder) ~= "table" or #ladder < 2 or #ladder % 2 ~= 0 then return false end
    local last = -1
    for i = 1, #ladder, 2 do
        local price, count = ladder[i], ladder[i + 1]
        if type(price) ~= "number" or not Prices.IsCredible(price) or price < last then return false end
        if type(count) ~= "number" or count <= 0 then return false end
        last = price
    end
    return true
end

Prices.ValidLadder = ValidLadder

--- How many others had listed at `price` or less in the last look at the
--- book (your own listings are never in it), so a real deal stands apart
--- from one lonely cheap item. nil when the book was not read (a browse
--- row, a guildmate's price) or no price is given.
function Prices.CountAtOrBelow(record, price)
    if type(record) ~= "table" or type(price) ~= "number" then return nil end
    local ladder = record.ladder
    if not ValidLadder(ladder) then return nil end
    local count = 0
    for i = 1, #ladder, 2 do
        if ladder[i] > price then break end
        count = count + ladder[i + 1]
    end
    return count
end

--- Fold one item's scan result into the database.
-- @param ladder the book's first price steps (Summarise), when this reading
--   saw the listings. nil from a reading that saw only the cheapest price (a
--   browse row): the ladder on record is kept while its first step is still
--   the cheapest rival, and dropped when it is not.
function Prices:Record(itemID, marketValue, minBuyout, quantity, scannedAt, rivalMin, ownMin, ignoredLow, ladder)
    -- Lets a list know prices moved without comparing every record.
    Prices:Touch(itemID)

    if not itemID or not marketValue then return end

    -- Every path that learns a price ends up here -- browse rows, the full
    -- replicate scan, targeted searches and the passive capture of the
    -- player's own searches -- so this is the one place that has to hold. A
    -- junk price is refused rather than stored; the item keeps whatever it
    -- already had, which is worth more than a number nobody can pay.
    if not Prices.IsCredible(marketValue) then
        Prices.implausible = (Prices.implausible or 0) + 1
        Prices.lastImplausible = { itemID = itemID, price = marketValue, at = time() }
        return nil, "implausible"
    end

    -- The book's own figures are dropped individually: an item can have one
    -- absurd listing above a shelf of sane ones, and losing the sane market
    -- value with it would be the worse trade.
    if not Prices.IsCredible(minBuyout) then minBuyout = nil end
    if not Prices.IsCredible(rivalMin) then rivalMin = nil end
    if not Prices.IsCredible(ownMin) then ownMin = nil end
    if not Prices.IsCredible(ignoredLow) then ignoredLow = nil end

    scannedAt = scannedAt or time()

    local prices = self:GetTable()
    local record = prices[itemID]

    if not record then
        record = { scans = 0, history = {} }
        prices[itemID] = record
    end

    -- EMA, seeded on first sight so a brand new item is not anchored to zero.
    if record.market then
        record.market = math.floor(record.market * (1 - EMA_ALPHA) + marketValue * EMA_ALPHA + 0.5)
    else
        record.market = marketValue
    end

    if ladder ~= nil then
        record.ladder = ValidLadder(ladder) and ladder or nil
        -- When the steps were read, so Overcutting trusts only a fresh book.
        -- A browse row that keeps the ladder below leaves this as it was.
        record.ladderAt = record.ladder and scannedAt or nil
    elseif record.ladder and not (rivalMin and record.ladder[1] == rivalMin) then
        record.ladder = nil
        record.ladderAt = nil
    end

    record.min = minBuyout
    -- nil when every listing is yours, which is a real and meaningful state:
    -- there is nobody to undercut.
    record.rivalMin = rivalMin
    record.ownMin = ownMin
    record.ignoredLow = ignoredLow
    record.quantity = quantity
    record.seen = scannedAt
    record.scans = (record.scans or 0) + 1
    Prices.NoteDaily(record, scannedAt, quantity)
    Prices.NoteTrend(record, scannedAt)

    local history = record.history
    history[#history + 1] = { t = scannedAt, m = record.market, q = quantity }
    while #history > MAX_HISTORY do
        table.remove(history, 1)
    end

    -- The hour by hour graph keeps the cheapest posting, as buying sees it.
    if ns.PriceHistory then
        ns.PriceHistory:Note(itemID, Prices.LowestListed(record), scannedAt)
        ns.PriceHistory:NoteListed(itemID, quantity, scannedAt)
    end

    -- The Stats tab's ninety days: the cheapest of each day, and its sales.
    if ns.StatsLog then
        local days = type(record.daily) == "table" and record.daily.days
        local count = type(days) == "table" and #days or 0
        local sold = count >= 2 and days[count - 1] == math.floor(scannedAt / 86400) and days[count] or nil
        pcall(ns.StatsLog.NoteDay, ns.StatsLog, itemID, Prices.LowestListed(record), sold, scannedAt)
    end

    return record
end

--- Record that a search came back with nothing listed at all.
--
-- An empty order book is an observation, not a failed scan, and the two have
-- to be told apart. Recording nothing leaves the last scan's rivalMin in
-- place, and the next listing then undercuts a seller who has already sold
-- out or expired -- which is the exact mistake a fresh price check exists to
-- prevent.
--
-- The smoothed market value survives on purpose: what an item is worth does
-- not become unknown the moment nobody happens to be selling one. What does
-- go is everything that describes the current book, because there isn't one.
function Prices:RecordEmpty(itemID, scannedAt)
    -- Lets a list know prices moved without comparing every record.
    Prices:Touch(itemID)

    if not itemID then return end

    scannedAt = scannedAt or time()

    local prices = self:GetTable()
    local record = prices[itemID]

    if not record then
        record = { scans = 0, history = {} }
        prices[itemID] = record
    end

    record.min = nil
    -- nil rivalMin is already the understood "nobody to undercut" state, so
    -- pricing needs no new case for this: GetPostPrice falls through to
    -- market value on its own.
    record.rivalMin = nil
    record.ownMin = nil
    record.ignoredLow = nil
    record.ladder = nil
    record.quantity = 0
    record.seen = scannedAt
    record.scans = (record.scans or 0) + 1
    Prices.NoteDaily(record, scannedAt, 0)

    record.history = record.history or {}

    local history = record.history
    history[#history + 1] = { t = scannedAt, m = record.market, q = 0 }
    while #history > MAX_HISTORY do
        table.remove(history, 1)
    end

    -- Sold out counts on the volume bars: none listed this hour.
    if ns.PriceHistory then ns.PriceHistory:NoteListed(itemID, 0, scannedAt) end

    return record
end

--- You bought from this item's listings: what you bought is no longer there.
--
-- A player found the Disenchanting tab still offering an item at the price
-- of the listing they had just bought, the last one at that price, until
-- the next scan. The client may or may not show the listings again after a
-- buy, so the record is put right here, from what was paid.
--
-- The units bought come off the cheapest on record, and anything on record
-- under the price paid goes too: you would have bought the cheapest, so a
-- cheaper one had already gone. The rest of the ladder stays; with no ladder to
-- say what comes next, the cheapest rival is unknown (nil) until the next
-- look, so nothing is offered at a price nobody is selling at. No price
-- history is written: nothing was scanned, and your own buy says nothing
-- about Demand.
--
-- @param unitPrice what one listing's unit cost, or nil for a commodity,
--   where one buy takes the cheapest units whatever their price
-- @param quantity  how many were bought
-- @param askedAt   time() the buy was asked for. A record read after that
--   already saw the book without it, and is left alone.
-- @return true when the record changed
function Prices:NoteBought(itemID, unitPrice, quantity, askedAt)
    local record = itemID and self:GetTable()[itemID]
    if type(record) ~= "table" then return false end
    if askedAt and (record.seen or 0) > askedAt then return false end

    quantity = math.max(1, math.floor(tonumber(quantity) or 1))
    local paid = tonumber(unitPrice)

    local cheapest = record.rivalMin
    if record.ignoredLow and (not cheapest or record.ignoredLow < cheapest) then cheapest = record.ignoredLow end
    if not cheapest then return false end
    if paid and paid < cheapest - 1 then return false end
    local unitPrice = paid or cheapest

    local left = quantity

    -- The lone low listing first: it is the cheapest of all, and one unit.
    if record.ignoredLow and record.ignoredLow <= unitPrice + 1 then
        record.ignoredLow = nil
        left = left - 1
    end

    if ValidLadder(record.ladder) then
        local kept = {}
        for i = 1, #record.ladder, 2 do
            local price, count = record.ladder[i], record.ladder[i + 1]
            -- Under the price paid had already gone (a copper either way is
            -- the same listing: a stack's unit price is rounded). The units
            -- bought come off the cheapest of the rest.
            if paid and price < paid - 1 then
                count = 0
            elseif left > 0 then
                local take = math.min(left, count)
                count, left = count - take, left - take
            end
            if count > 0 then
                kept[#kept + 1] = price
                kept[#kept + 1] = count
            end
        end
        record.ladder = #kept >= 2 and kept or nil
        record.rivalMin = record.ladder and record.ladder[1] or nil
    else
        record.ladder = nil
        if left > 0 and record.rivalMin and record.rivalMin <= unitPrice + 1 then record.rivalMin = nil end
    end

    record.quantity = math.max(0, (tonumber(record.quantity) or 0) - quantity)

    local min = record.rivalMin
    for _, price in ipairs({ record.ignoredLow or false, record.ownMin or false }) do
        if price and (not min or price < min) then min = price end
    end
    record.min = min

    self:Touch(itemID)
    return true
end

--- After a complete full scan, mark every item it did not see as sold out.
--
-- A full scan used to update only the items it found. Anything that had sold
-- out or expired since the last scan kept its old listing on record, so the
-- tabs went on showing a cheapest price nobody was selling at, and the next
-- listing undercut a seller who was already gone.
--
-- Only a scan that read the whole auction house may do this. A scan cut
-- short (page cap, timeout, another search taking the results over) did not
-- look everywhere, so what it missed is unknown, not sold out. Records
-- written since the scan started are left alone too: a search made during
-- the scan is newer than anything the scan read.
--
-- @param seen      { [itemID] = true } for every item the scan read a row of
-- @param startedAt time() when the scan began
-- @return how many items were marked sold out
function Prices:ClearMissing(seen, startedAt, scannedAt)
    scannedAt = scannedAt or time()
    startedAt = startedAt or scannedAt

    local gone = {}
    for itemID, record in pairs(self:GetTable()) do
        local listed = (record.quantity or 0) > 0 or record.min or record.rivalMin or record.ownMin
        if listed and not seen[itemID] and (record.seen or 0) < startedAt then
            gone[#gone + 1] = itemID
        end
    end

    for _, itemID in ipairs(gone) do
        self:RecordEmpty(itemID, scannedAt)
    end

    return #gone
end

--- When this realm and faction last had a full scan.
--
-- Prices are kept per realm and faction, so the stamp is too. One stamp for
-- the whole account made an Alliance scan at 10:00 read as "scanned 5m ago"
-- on a Horde character with two-day-old prices, hid that character's deals
-- (they looked older than the scan) and skipped its automatic scan. The old
-- account-wide stamp is read only until the first scan after the update:
-- after that it belongs to whichever realm wrote it last, not to this one.
function Prices:GetLastFullScan()
    local db = ns.db
    if not db then return nil end
    local byRealm = db.lastFullScanByRealm
    if not byRealm then return db.lastFullScan end
    local key = ns.Config and ns.Config.GetRealmKey and ns.Config:GetRealmKey()
    return key and byRealm[key] or nil
end

--- When this realm and faction last had a scan of any kind: a full one, or a
--- sweep that stopped at the page limit.
--
-- On a big auction house every sweep stops at the page limit, so it never
-- gets a full scan stamp. Deal lists judged by the full scan stamp alone
-- kept days-old listings, and the header said "never scanned". Only clearing
-- sold-out items needs a real full scan; that still reads GetLastFullScan.
-- The second value is true when the newest scan is the one that stopped at
-- the page limit.
function Prices:GetLastScan()
    local full = self:GetLastFullScan()
    local db = ns.db
    local key = ns.Config and ns.Config.GetRealmKey and ns.Config:GetRealmKey()
    local capped = db and key and db.lastCappedScanByRealm and db.lastCappedScanByRealm[key]
    if capped and (not full or capped > full) then return capped, true end
    return full, false
end
function Prices:SetLastFullScan(at)

    local db = ns.db
    if not db then return end
    local key = ns.Config and ns.Config.GetRealmKey and ns.Config:GetRealmKey()
    if key then
        db.lastFullScanByRealm = db.lastFullScanByRealm or {}
        db.lastFullScanByRealm[key] = at
    end
end

--------------------------------------------------------------------------------
-- Telling other addons a scan finished
--------------------------------------------------------------------------------

-- Farmer asks to hear when a scan has written its prices (2026-10-14), so it
-- can look at its board again with them. Nothing else here waits on it.
Prices.scanWatchers = Prices.scanWatchers or {}
Prices.scanCount = Prices.scanCount or 0

--- Call `fn(info)` each time a scan finishes and has written prices:
--- info = { items = how many it recorded, at = time() }. Each watcher runs
--- in a pcall, so one that raises never stops the scan or the others.
--- Returns true when it is watching.
function Prices:WatchScans(fn)
    if type(fn) ~= "function" then return false end
    for _, watcher in ipairs(self.scanWatchers) do
        if watcher == fn then return true end
    end
    self.scanWatchers[#self.scanWatchers + 1] = fn
    return true
end

--- A scan finished with `result` (UI:OnScanComplete's): tell the watchers.
--- A cancelled scan, or one that recorded nothing, says nothing.
function Prices:ScanFinished(result)
    if type(result) ~= "table" or (tonumber(result.items) or 0) <= 0 then return end
    self.scanCount = self.scanCount + 1

    local info = { items = tonumber(result.items), at = time() }
    for _, watcher in ipairs(self.scanWatchers) do
        local ok, err = pcall(watcher, info)
        if not ok and ns.Debug then ns.Debug("scan watcher:", tostring(err)) end
    end
end

--- ClearMissing, for a scan that believes it read the whole auction house.
--
-- The last line of defence for the player's prices. A scan that saw far
-- fewer items than the last whole one on this realm is not trusted to say
-- what sold out: that is what a stray search looks like. Unlike a fixed
-- share of the book, the check heals itself: a market that really did
-- shrink is refused once, and accepted when the next scan finds about the
-- same smaller number. One small stray search is not taken as the new size,
-- so it cannot open the way for the next one.
--
-- With no whole scan remembered yet on this realm, what the saved prices
-- say is listed stands in for it.
--
-- @return how many items were marked sold out, and why none were if so
function Prices:ClearMissingIfWhole(seen, startedAt, scannedAt)
    local count = 0
    for _ in pairs(seen) do count = count + 1 end

    local db = ns.db or {}
    local key = ns.Config and ns.Config.GetRealmKey and ns.Config:GetRealmKey() or "?"
    db.sweepSeenByRealm = db.sweepSeenByRealm or {}
    db.sweepRefusedByRealm = db.sweepRefusedByRealm or {}

    local last = db.sweepSeenByRealm[key]
    if not last then
        last = 0
        for _, record in pairs(self:GetTable()) do
            if (record.quantity or 0) > 0 or record.min or record.rivalMin or record.ownMin then
                last = last + 1
            end
        end
    end

    if count < last / 2 then
        local refused = db.sweepRefusedByRealm[key]
        local agrees = refused and math.abs(count - refused) <= refused * 0.1
        if not agrees then
            db.sweepRefusedByRealm[key] = count
            return 0, L.Format("the scan saw %d items, compared with %d last time", count, last)
        end
    end

    db.sweepSeenByRealm[key] = count
    db.sweepRefusedByRealm[key] = nil
    return self:ClearMissing(seen, startedAt, scannedAt)
end

--- Commit a whole scan at once: { [itemID] = { {unitPrice, quantity}, ... } }.
-- Returns the number of items recorded.
function Prices:CommitScan(observations, scannedAt)
    scannedAt = scannedAt or time()

    local recorded = 0
    for itemID, listings in pairs(observations) do
        -- How many sell it, for the Stats tab; the names go no further.
        if ns.StatsLog then pcall(ns.StatsLog.NoteSellers, ns.StatsLog, itemID, listings, scannedAt) end

        local marketValue, minBuyout, quantity, rivalMin, ownMin, ignoredLow, ladder =
            self:Summarise(listings, self:GetScanValue(itemID, "market"))
        if marketValue then
            self:Record(itemID, marketValue, minBuyout, quantity, scannedAt, rivalMin, ownMin, ignoredLow, ladder)
            recorded = recorded + 1
        end
    end

    self:SetLastFullScan(scannedAt)
    return recorded
end

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

function Prices:Get(itemID)
    return self:GetTable()[itemID]
end

--- The cheapest posting at the last look, yours included, leaving out a lone
--- one far below the rest (see IsLoneLow). nil when nothing was listed.
--
-- The one reading of "what does it cost" that material cost, the tooltip and
-- the Enchanting tab share, so a single troll listing cannot make a craft
-- look cheap to make in one place and not in another. Two or more low
-- listings are a real price and count.
function Prices.LowestListed(record)
    if type(record) ~= "table" then return nil end

    local lowest = record.rivalMin
    if record.ownMin and (not lowest or record.ownMin < lowest) then lowest = record.ownMin end
    if not lowest and not record.ignoredLow then lowest = record.min end
    return lowest
end

--- What buying one costs on the auction house now: the cheapest posting at
--- the last look (LowestListed, or a lone low listing when it is all there
--- is). A record that says nothing is listed answers nil and true, so a
--- list can show it blank rather than at its average (a player asked,
--- 2026-10-11, for the Waylaid crate and writ columns). An item never read
--- at all falls back to GetValue's "lowest", the best guess there is.
-- @return copper or nil, and true when none are listed
function Prices:ListedNow(itemID)
    local record = itemID and self:GetTable()[itemID]
    if type(record) ~= "table" then return self:GetValue(itemID, "lowest"), false end

    local lowest = Prices.LowestListed(record) or record.ignoredLow
    if lowest then return lowest, false end
    return nil, true
end

--- How many are on the auction house: at `price` or less (other sellers,
--- from the last look at the book), and in all as last scanned. Either is
--- nil when it was not read.
function Prices:ListedCounts(itemID, price)
    local record = itemID and self:GetTable()[itemID]
    if type(record) ~= "table" then return nil, nil end
    local total = tonumber(record.quantity)
    return Prices.CountAtOrBelow(record, price), total
end

--- Best estimate of what one unit is worth.
--
-- `which` is one of:
--   "market" (default) smoothed value, for valuing what you already own
--   "min"              cheapest listing, what it costs you to buy right now
--   "rival"            cheapest listing that is not yours, the price to undercut
--
-- "rival" deliberately does not fall back to `min`: if the only listing is
-- yours, there is nobody to undercut, and pretending otherwise would have you
-- undercut yourself.
--
-- A price the player set on the Prices tab (see My prices below) wins over
-- all but "rival": "use" replaces the scanned price, "floor" lifts it.
-- Rival stays the auction house's own, since it is the price to undercut.
-- Gaps take your guild's prices, then your realm's (Logic/GuildPrices.lua,
-- Logic/RealmPrices.lua); an item nobody has priced may take TradeSkillMaster's (Logic/TSMPrices.lua),
-- then Auctionator's (Logic/AuctionatorPrices.lua), or the other way round
-- when "Price Order:" says Auctionator first (`priceOrder`). A stale price of your
-- own also gives way to Auctionator's when Auctionator saw the item later.
-- GetScanValue answers from the scans alone.
function Prices:GetValue(itemID, which)
    local scanned = self:GetScanValue(itemID, which)
    if which == "rival" then return scanned end

    -- Guildmates' prices (Logic/GuildPrices.lua, off unless the player turns
    -- it on) fill a gap: an item never priced here, or one whose price has
    -- gone stale while theirs is newer. A fresh scan of your own always wins.
    -- Only asked when it could be used: their answer is sorted out of every
    -- guildmate's, and prices are read many times a redraw.
    local filled
    local guild = ns.GuildPrices
    if guild and guild.IsOn and guild:IsOn() and (not scanned or self:IsStale(itemID)) then
        local shared, sharedAt = guild:GetValue(itemID, which)
        if shared then
            local record = self:GetTable()[itemID]
            local seen = type(record) == "table" and record.seen or 0
            if not scanned or (self:IsStale(itemID) and sharedAt > seen) then
                scanned = shared
                filled = true
            end
        end
    end

    -- Then your realm's (Logic/RealmPrices.lua, off unless ticked), the same
    -- way, only where your guild had nothing to give.
    local realm = ns.RealmPrices
    if not filled and realm and realm.IsOn and realm:IsOn() and (not scanned or self:IsStale(itemID)) then
        local shared, sharedAt = realm:GetValue(itemID, which)
        if shared then
            local record = self:GetTable()[itemID]
            local seen = type(record) == "table" and record.seen or 0
            if not scanned or (self:IsStale(itemID) and sharedAt > seen) then
                scanned = shared
                filled = true
            end
        end
    end

    -- TradeSkillMaster's price (Logic/TSMPrices.lua, on unless unticked)
    -- only for an item neither you, your guildmates nor your realm have priced.
    -- With "Price Order:" set to Auctionator first (`priceOrder`), Auctionator
    -- is asked before TSM here.
    local auctionatorFirst = ns.Config and ns.Config:Get("priceOrder") == "auctionator"
    if not scanned and auctionatorFirst then
        local auctionator = ns.AuctionatorPrices
        if auctionator and auctionator.GetValue then
            scanned = auctionator:GetValue(itemID, which)
            if scanned and auctionator.Used then auctionator:Used() end
        end
    end
    if not scanned then
        local tsm = ns.TSMPrices
        if tsm and tsm.GetValue then
            scanned = tsm:GetValue(itemID, which)
            if scanned and tsm.Used then tsm:Used() end
        end
    end
    -- Then Auctionator's (Logic/AuctionatorPrices.lua, on unless unticked).
    -- It also takes over from your own price once that has gone stale, when
    -- Auctionator saw the item more recently, as guild and realm prices may.
    -- Asked only for a stale price nobody else replaced.
    if scanned and not filled and self:IsStale(itemID) then
        local auctionator = ns.AuctionatorPrices
        local age = self:GetAge(itemID)
        if age and auctionator and auctionator.NewerThan and auctionator:NewerThan(itemID, age) then
            local newer = auctionator:GetValue(itemID, which)
            if newer then
                scanned = newer
                if auctionator.Used then auctionator:Used() end
            end
        end
    end
    if not scanned then
        local auctionator = ns.AuctionatorPrices
        if auctionator and auctionator.GetValue then
            scanned = auctionator:GetValue(itemID, which)
            if scanned and auctionator.Used then auctionator:Used() end
        end
    end

    local mine, mode = self:GetMine(itemID)
    if not mine then return scanned end

    if mode == "use" then return mine end
    if not scanned or scanned < mine then return mine end
    return scanned
end

--- What the scans alone say an item is worth, leaving out any price the
--- player set. Same `which` as GetValue.
function Prices:GetScanValue(itemID, which)
    local record = self:GetTable()[itemID]
    if not record then return nil end

    if which == "min" then
        return record.min or record.market
    elseif which == "rival" then
        return record.rivalMin
    elseif which == "lowest" then
        -- The cheapest posting, leaving out a lone one far below the rest.
        -- With nothing listed at the last look, the market value is the best
        -- there is.
        return Prices.LowestListed(record) or record.market
    end

    return record.market or record.min
end

--------------------------------------------------------------------------------
-- Random suffixes
--------------------------------------------------------------------------------

-- Gear with a random suffix ("Lead Band of the Monkey", "... of the Spirit")
-- shares one item ID, and the item's price is every suffix's together. A
-- player asked (2026-10-15) for the good rolls to be worth what they sell
-- for, so each suffix seen at the auction house keeps a price of its own
-- beside the item's: `record.suffixes[suffix] = { market, min, rival,
-- quantity, seen }` (never rename it). The item's own price is unchanged.

-- The most suffixes kept for one item. Classic gear has at most about forty,
-- and the oldest seen goes first.
Prices.SUFFIX_MOST = 40

-- A suffix price older than this is not used; the item's price stands in.
Prices.SUFFIX_KEEP = 14 * 24 * 3600

--- The suffix a link names, or nil for none.
function Prices.SuffixOf(link)
    return Util.LinkSuffix(link)
end

--- Keep one suffix's reading. Only beside a price the item already has.
-- `rival` is the cheapest listing not yours, nil when every one is yours.
function Prices:RecordSuffix(itemID, suffix, marketValue, minBuyout, rival, quantity, scannedAt)
    suffix = tonumber(suffix)
    if not (itemID and suffix and suffix ~= 0) then return nil end
    if type(marketValue) ~= "number" or marketValue <= 0 or not Prices.IsCredible(marketValue) then return nil end

    local record = self:GetTable()[itemID]
    if type(record) ~= "table" then return nil end

    if not Prices.IsCredible(minBuyout) then minBuyout = nil end
    if not Prices.IsCredible(rival) then rival = nil end

    local suffixes = record.suffixes
    if type(suffixes) ~= "table" then
        suffixes = {}
        record.suffixes = suffixes
    end

    local entry = suffixes[suffix]
    if type(entry) ~= "table" then
        -- Room for a new one: the oldest seen goes.
        local count, oldest, oldestAt = 0, nil, nil
        for key, other in pairs(suffixes) do
            count = count + 1
            local at = type(other) == "table" and tonumber(other.seen) or 0
            if not oldestAt or at < oldestAt then oldest, oldestAt = key, at end
        end
        if count >= Prices.SUFFIX_MOST and oldest ~= nil then suffixes[oldest] = nil end

        entry = {}
        suffixes[suffix] = entry
    end

    if entry.market then
        entry.market = math.floor(entry.market * (1 - EMA_ALPHA) + marketValue * EMA_ALPHA + 0.5)
    else
        entry.market = marketValue
    end
    entry.min = minBuyout
    entry.rival = rival
    entry.quantity = quantity
    entry.seen = scannedAt or time()

    Prices:Touch(itemID)
    return entry
end

--- Keep a reading for each suffix among `bySuffix` ({ [suffix] = listings },
--- listings as CommitScan takes them), beside the item's own price.
function Prices:CommitSuffixes(itemID, bySuffix, scannedAt)
    if type(bySuffix) ~= "table" then return 0 end
    local kept = 0
    for suffix, listings in pairs(bySuffix) do
        local reference = self:GetSuffixValue(itemID, suffix, "market")
        local marketValue, minBuyout, quantity, rivalMin = self:Summarise(listings, reference)
        if marketValue and self:RecordSuffix(itemID, suffix, marketValue, minBuyout, rivalMin, quantity, scannedAt) then
            kept = kept + 1
        end
    end
    return kept
end

--- One suffix's price, or nil when it has none recent enough. Same `which`
--- as GetScanValue ("lowest" reads as "min").
function Prices:GetSuffixValue(itemID, suffix, which)
    suffix = tonumber(suffix)
    if not (itemID and suffix and suffix ~= 0) then return nil end
    local record = self:GetTable()[itemID]
    local suffixes = type(record) == "table" and record.suffixes
    local entry = type(suffixes) == "table" and suffixes[suffix]
    if type(entry) ~= "table" then return nil end
    if (tonumber(entry.seen) or 0) < time() - Prices.SUFFIX_KEEP then return nil end

    if which == "rival" then return entry.rival end
    if which == "min" or which == "lowest" then return entry.min or entry.market end
    return entry.market or entry.min
end

--- One suffix's saved reading, recent or not, or nil.
function Prices:GetSuffixEntry(itemID, suffix)
    suffix = tonumber(suffix)
    if not (itemID and suffix and suffix ~= 0) then return nil end
    local record = self:GetTable()[itemID]
    local suffixes = type(record) == "table" and record.suffixes
    local entry = type(suffixes) == "table" and suffixes[suffix]
    return type(entry) == "table" and entry or nil
end

--- The name the client gives one suffix of an item ("Lead Band of the
--- Monkey"), or nil while it is not loaded. Read inside a pcall.
function Prices.SuffixName(itemID, suffix)
    local api = _G.C_Item
    local info = type(api) == "table" and api.GetItemInfo or _G.GetItemInfo
    if type(info) ~= "function" then return nil end
    local ok, name = pcall(info, ("item:%d:0:0:0:0:0:%d"):format(itemID, suffix))
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

--- Every suffix of an item with a recent price, dearest first:
--- { { suffix, market, min, rival, seen, name } }.
function Prices:SuffixRows(itemID)
    local rows = {}
    local record = itemID and self:GetTable()[itemID]
    local suffixes = type(record) == "table" and record.suffixes
    if type(suffixes) ~= "table" then return rows end
    local oldest = time() - Prices.SUFFIX_KEEP
    for suffix, entry in pairs(suffixes) do
        if type(entry) == "table" and tonumber(entry.market) and (tonumber(entry.seen) or 0) >= oldest then
            rows[#rows + 1] = {
                suffix = suffix, market = entry.market, min = entry.min, rival = entry.rival,
                seen = entry.seen, name = Prices.SuffixName(itemID, suffix),
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.market ~= b.market then return a.market > b.market end
        return (tonumber(a.suffix) or 0) < (tonumber(b.suffix) or 0)
    end)
    return rows
end

--- What one copy is worth, by its link: its suffix's own price when one is
--- kept, else the item's (GetValue). Second: true when the suffix's price
--- answered. A price the player set on the Prices tab still wins.
function Prices:GetLinkValue(link, which)
    local itemID = type(link) == "string" and tonumber(link:match("item:(%d+)")) or tonumber(link)
    if not itemID then return nil end

    local suffix = type(link) == "string" and Prices.SuffixOf(link) or nil
    if suffix and which == "rival" then
        -- Someone else's cheapest of this suffix, from a reading fresh
        -- enough to undercut, nil when only yours were listed. Another
        -- suffix's rival is never this one's, so once the item keeps suffix
        -- prices the item's own rival does not stand in.
        local record = self:GetTable()[itemID]
        if type(record) == "table" and type(record.suffixes) == "table" then
            local entry = self:GetSuffixEntry(itemID, suffix)
            local fresh = ns.Config and ns.Config:Get("staleAfterSeconds") or (48 * 3600)
            if entry and (tonumber(entry.seen) or 0) >= time() - fresh then
                return entry.rival, true
            end
            return nil, false
        end
    elseif suffix then
        local own = self:GetSuffixValue(itemID, suffix, which)
        if own then
            local mine, mode = self:GetMine(itemID)
            if mine and (mode == "use" or own < mine) then return mine, false end
            return own, true
        end
    end

    return self:GetValue(itemID, which), false
end

--------------------------------------------------------------------------------
-- Buying many
--------------------------------------------------------------------------------

--- What buying `count` costs walking up a ladder, after the first `skip`
--- units (already bought since it was read) are passed over. Past the last
--- step, the rest are priced at it. Each step is lifted to `floor` when one
--- is given.
local function Walk(ladder, count, skip, floor)
    local total, left, last = 0, count, nil
    skip = skip or 0
    for i = 1, #ladder, 2 do
        local price, units = ladder[i], ladder[i + 1]
        if floor and price < floor then price = floor end
        last = price
        if skip >= units then
            skip = skip - units
        else
            local take = math.min(units - skip, left)
            skip = 0
            total = total + price * take
            left = left - take
            if left <= 0 then return total end
        end
    end
    return total + last * left
end

Prices.Walk = Walk

--- What buying `count` of an item costs on the auction house, going up the
--- listings from the last scan rather than paying the cheapest price for all
--- of them.
--
-- Answers as GetValue(itemID, "lowest") does for one: the player's own "use"
-- price is the price of every one, a "floor" lifts every step, and with no
-- book to walk (a stale scan, a guildmate's price, one browse row) it is that
-- one price times the count.
--
-- @param skip units bought since the scan, whose listings are gone
-- @param record a record to read instead of the one on file (CostBeforeLook)
-- @return copper, or nil when the item has no auction price
function Prices:GetCostFor(itemID, count, skip, record)
    count = math.floor(tonumber(count) or 0)
    if count <= 0 then return 0 end

    local mine, mode = self:GetMine(itemID)
    if mine and mode == "use" then return mine * count end

    local current = record == nil
    record = record or self:GetTable()[itemID]
    local ladder = type(record) == "table" and record.ladder
    local stale = type(record) ~= "table" or not record.seen
        or time() - record.seen > (ns.Config:Get("staleAfterSeconds") or (48 * 3600))
    if ValidLadder(ladder) and not stale then
        return Walk(ladder, count, skip, mode == "floor" and mine or nil)
    end

    local unit
    if current then
        unit = self:GetValue(itemID, "lowest")
    else
        unit = Prices.LowestListed(record) or (type(record) == "table" and record.market) or nil
        if unit and mine and mode == "floor" and unit < mine then unit = mine end
    end
    return unit and unit * count or nil
end

-- The book as it stood before the player looked an item up at this visit to
-- the auction house, by item. The player's own search records the listings
-- they are about to buy from, so what the shopping list said beforehand
-- would be gone by the time they pay. Not saved; emptied each visit.
Prices.beforeLook = {}

--- Keep the item's book as it is, once a visit, before a search of the
--- player's own records over it.
function Prices:KeepBeforeLook(itemID)
    if not itemID or self.beforeLook[itemID] ~= nil then return end
    local record = self:GetTable()[itemID]
    if type(record) ~= "table" then
        self.beforeLook[itemID] = false
        return
    end
    self.beforeLook[itemID] = {
        ladder = record.ladder, rivalMin = record.rivalMin, ownMin = record.ownMin,
        min = record.min, ignoredLow = record.ignoredLow, market = record.market,
        seen = record.seen,
    }
end

function Prices:ForgetBeforeLook()
    self.beforeLook = {}
end

--- What buying `count` was estimated at before the player looked it up:
--- the book kept by KeepBeforeLook, else the one on file.
-- @param boughtSince function(seen) -> units bought since a scan at `seen`
function Prices:CostBeforeLook(itemID, count, boughtSince)
    local kept = self.beforeLook[itemID]
    local record = kept or self:GetTable()[itemID]
    local seen = type(record) == "table" and record.seen or nil
    local skip = (seen and boughtSince) and boughtSince(seen) or 0
    return self:GetCostFor(itemID, count, skip, kept or nil)
end

--- True when your own auction is currently the cheapest listing.
function Prices:HoldsLowest(itemID)
    local record = self:GetTable()[itemID]
    if not record or not record.ownMin then return false end

    return record.rivalMin == nil or record.ownMin < record.rivalMin
end

function Prices:GetAge(itemID)
    local record = self:GetTable()[itemID]
    if not record or not record.seen then return nil end
    return time() - record.seen
end

function Prices:IsStale(itemID)
    local age = self:GetAge(itemID)
    if not age then return true end
    return age > (ns.Config:Get("staleAfterSeconds") or (48 * 3600))
end

--- Rough sale velocity, 0..1.
--
-- Quantity shrinking between scans implies sales; quantity growing implies
-- restocking. Restocking masks sales, so this systematically under-reports and
-- is only ever presented as a confidence hint, never as a sale rate.
function Prices:GetLiquidity(itemID)
    local record = self:GetTable()[itemID]
    if not record or not record.history or #record.history < 2 then
        return nil
    end

    local history = record.history
    local drops, total = 0, 0

    for i = 2, #history do
        local previous = history[i - 1].q or 0
        local current = history[i].q or 0

        if previous > 0 then
            if current < previous then
                drops = drops + (previous - current)
            end
            total = total + previous
        end
    end

    if total == 0 then return nil end
    return Util.Clamp(drops / total, 0, 1)
end

-- Scans closer together than this are one look at the book for Demand, so
-- scanning every minute neither waters the reading down nor lets listings
-- that come and go inflate it.
local SALES_GAP = 15 * 60

-- Time the readings must span before the stock's movement says anything.
local SALES_MIN_SPAN = 3600

Prices.SALES_GAP = SALES_GAP
Prices.SALES_MIN_SPAN = SALES_MIN_SPAN

--- Share of an item's listed stock that goes per day, 0..1, however often it
-- was scanned.
--
-- GetLiquidity counts per scan, so the same item reads quieter the more often
-- it is scanned. This one spaces the readings by the clock: looks less than
-- SALES_GAP apart count once, the drops in stock are added up, and the total is
-- divided by the average stock and by the days the readings span. An empty
-- answer is left out (it cannot say whether the stock sold or expired), and
-- nothing is answered for under SALES_MIN_SPAN of readings. Like GetLiquidity
-- it under-reports, because a restock hides sales.
-- @return nil when there is not enough time or stock to go on
--- The stock's movement over the kept readings: listings gone, the average
-- stock, and the days the readings span. nil when there is too little to go on.
local function StockMovement(record)
    if not record or type(record.history) ~= "table" then return nil end

    local kept = {}
    for _, point in ipairs(record.history) do
        local q = point.q
        if type(point.t) == "number" and type(q) == "number" and q > 0 then
            local last = kept[#kept]
            if not last or point.t - last.t >= SALES_GAP then
                kept[#kept + 1] = point
            end
        end
    end

    if #kept < 2 then return nil end

    local span = kept[#kept].t - kept[1].t
    if span < SALES_MIN_SPAN then return nil end

    local drops, stock = 0, 0
    for i = 2, #kept do
        local previous, current = kept[i - 1].q, kept[i].q
        if current < previous then drops = drops + (previous - current) end
        stock = stock + previous
    end

    if stock == 0 then return nil end

    return drops, stock / (#kept - 1), span / 86400
end

function Prices:GetSalesPerDay(itemID)
    local drops, average, days = StockMovement(self:GetTable()[itemID])
    if not drops then return nil end
    return Util.Clamp(drops / average / days, 0, 1)
end

--- About how many leave the auction house a day, from the same readings as
-- GetSalesPerDay. An estimate: the game never says what sold, so listings
-- that expire or are taken down count too, and a restock hides sales.
-- @return nil when there is not enough time or stock to go on
function Prices:GetUnitsSoldPerDay(itemID)
    local drops, _, days = StockMovement(self:GetTable()[itemID])
    if not drops then return nil end
    return drops / days
end

--------------------------------------------------------------------------------
-- The last seven days, a day at a time
--------------------------------------------------------------------------------

-- A player asked (2026-10-13) for the tooltip to show sales over the last
-- seven days. The twelve kept readings rarely reach back a week, so each
-- record also keeps `daily` (never rename it): `days`, flat day, count pairs
-- for up to DAILY_KEEP days (day = time() / 86400, rounded down; a pair for
-- every day a scan saw it, 0 when nothing went), and `t`, `q`, the reading
-- the next drop is measured from. Readings closer than SALES_GAP count once,
-- as in GetSalesPerDay, and a drop across more than a day is not put on any
-- one day, since nobody can say which day it went.
local DAY = 86400
local DAILY_KEEP = 7
Prices.DAILY_KEEP = DAILY_KEEP

function Prices.NoteDaily(record, at, quantity)
    if type(record) ~= "table" or type(at) ~= "number" then return end

    local daily = record.daily
    if type(daily) ~= "table" or type(daily.days) ~= "table" then
        daily = { days = {} }
        record.daily = daily
    end

    local days = daily.days
    local today = math.floor(at / DAY)
    local count = #days

    if count >= 2 and days[count - 1] > today then return end
    if count < 2 or days[count - 1] ~= today then
        days[count + 1] = today
        days[count + 2] = 0
        count = count + 2
    end

    -- An empty book says nothing about whether the stock sold or expired.
    if type(quantity) == "number" and quantity > 0 then
        if type(daily.t) ~= "number" or type(daily.q) ~= "number" then
            daily.t, daily.q = at, quantity
        elseif at - daily.t >= SALES_GAP then
            if at - daily.t <= DAY and quantity < daily.q then
                days[count] = days[count] + (daily.q - quantity)
            end
            daily.t, daily.q = at, quantity
        end
    end

    -- Keep only the last DAILY_KEEP days.
    local oldest = today - DAILY_KEEP + 1
    while days[1] and days[1] < oldest do
        table.remove(days, 1)
        table.remove(days, 1)
    end
end

--- The last seven days, oldest first, today last: how many left the auction
--- house each day by your scans, or false for a day nothing scanned it.
--- nil when the item has no daily record.
function Prices:GetDailySales(itemID, now)
    local record = self:GetTable()[itemID]
    local daily = record and record.daily
    if type(daily) ~= "table" or type(daily.days) ~= "table" or #daily.days < 2 then return nil end

    local today = math.floor((now or time()) / DAY)
    local byDay = {}
    for index = 1, #daily.days - 1, 2 do
        local day, sold = daily.days[index], daily.days[index + 1]
        if type(day) == "number" and type(sold) == "number" then byDay[day] = sold end
    end

    local out, any = {}, false
    for day = today - DAILY_KEEP + 1, today do
        local sold = byDay[day]
        out[#out + 1] = sold ~= nil and sold or false
        if sold ~= nil then any = true end
    end
    return any and out or nil
end

--------------------------------------------------------------------------------
-- The trend: market value now against its average over a week or two
--------------------------------------------------------------------------------

-- A player asked (2026-10-14, the owner agreeing) for a sortable trend on
-- the Prices tab and the tooltip: how far an item's market value now sits
-- above or below its average over the last 7 or 14 days. The twelve kept
-- readings rarely reach back that far, so each record also keeps `trend`
-- (never rename it): flat day, copper pairs (day = time() / 86400, rounded
-- down), the market value as the last scan of that day left it, for up to
-- TREND_KEEP days. One pair a day, so it stays small for every item.
Prices.TREND_KEEP = 14
-- Fewer days scanned than this in the period says nothing yet.
Prices.TREND_MIN_DAYS = 3
-- The periods a player can pick, in days.
Prices.TREND_PERIODS = { 7, 14 }

function Prices.NoteTrend(record, at)
    if type(record) ~= "table" or type(at) ~= "number" or type(record.market) ~= "number" then return end

    local list = record.trend
    if type(list) ~= "table" then
        list = {}
        record.trend = list
    end

    local today = math.floor(at / DAY)
    local count = #list
    if count >= 2 and type(list[count - 1]) == "number" and list[count - 1] > today then return end
    if count >= 2 and list[count - 1] == today then
        list[count] = record.market
    else
        list[count + 1] = today
        list[count + 2] = record.market
    end

    local oldest = today - Prices.TREND_KEEP + 1
    while type(list[1]) == "number" and list[1] < oldest do
        table.remove(list, 1)
        table.remove(list, 1)
    end
end

--- The period the trend reads, in days: 7 unless 14 was picked.
function Prices:TrendDays()
    local days = ns.Config and ns.Config.Get and ns.Config:Get("priceTrendDays")
    return days == 14 and 14 or 7
end

--- How far the market value now sits from its average over the last `days`
--- days (the picked period when not given), as a fraction: 0.24 is 24% above.
--- nil when fewer than TREND_MIN_DAYS days in the period were scanned.
-- @return fraction or nil, days scanned in the period
function Prices:GetTrend(itemID, days, now)
    local record = itemID and self:GetTable()[itemID]
    if type(record) ~= "table" or type(record.market) ~= "number" or record.market <= 0 then return nil, 0 end
    local list = record.trend
    if type(list) ~= "table" then return nil, 0 end

    days = days or self:TrendDays()
    local from = math.floor((now or time()) / DAY) - days + 1
    local sum, count = 0, 0
    for index = 1, #list - 1, 2 do
        local day, value = list[index], list[index + 1]
        if type(day) == "number" and type(value) == "number" and day >= from and value > 0 then
            sum = sum + value
            count = count + 1
        end
    end

    if count < self.TREND_MIN_DAYS then return nil, count end
    local average = sum / count
    return (record.market - average) / average, count
end

--- "+24%", "-12%", "0%": the trend as the lists and tooltip show it, and
--- the colour it is drawn in.
function Prices.TrendText(trend)
    if type(trend) ~= "number" then return nil end
    local percent = trend >= 0 and math.floor(trend * 100 + 0.5) or -math.floor(-trend * 100 + 0.5)
    if percent > 0 then return ("+%d%%"):format(percent), "profit" end
    if percent < 0 then return ("%d%%"):format(percent), "loss" end
    return "0%", "muted"
end

--- How much to trust this item's price: scan count, recency and depth.
-- Returns 0..1 and a short reason for the weakest factor.
-- Above this, a component is not worth calling out as a weakness.
local WEAKNESS_THRESHOLD = 0.8

function Prices:GetConfidence(itemID)
    local record = self:GetTable()[itemID]
    if not record then return 0, L["never seen"] end

    local scanScore = Util.Clamp((record.scans or 0) / 5, 0, 1)
    local depthScore = Util.Clamp((record.quantity or 0) / 20, 0, 1)

    local age = self:GetAge(itemID) or math.huge
    local staleAfter = ns.Config:Get("staleAfterSeconds") or (48 * 3600)
    local ageScore = Util.Clamp(1 - (age / staleAfter), 0, 1)

    local score = (scanScore * 0.3) + (depthScore * 0.3) + (ageScore * 0.4)

    -- Name what is holding the number down, and only when something is.
    --
    -- This used to pick a weakest link unconditionally, off a <= comparison
    -- that resolves ties in favour of the first branch. An item scanned
    -- seconds ago, deep and seen often, has all three scores at 1, so every
    -- one of those ties went to age and it reported "99% (stale data)" about
    -- data that could not have been fresher. A diagnostic that confidently
    -- names the wrong cause is worse than one that says nothing.
    local weakest = math.min(scanScore, depthScore, ageScore)
    if weakest >= WEAKNESS_THRESHOLD then return score, nil end

    local reason
    if ageScore == weakest then
        reason = L["stale data"]
    elseif depthScore == weakest then
        reason = L["few listed"]
    else
        reason = L["few scans"]
    end

    return score, reason
end

--------------------------------------------------------------------------------
-- Favourites
--------------------------------------------------------------------------------

-- Asked 2026-10-06 (a player): star the items you keep an eye on, like Spider
-- Silk, and show only those on the Prices tab. Kept for the whole account in
-- `favouritePrices`, by item, with the item's name so a search still finds
-- one the game has not loaded. Separate from the price table, so a price
-- pruned for age never takes a favourite with it.

function Prices:IsFavourite(itemID)
    return itemID ~= nil and ns.db ~= nil and type(ns.db.favouritePrices) == "table"
        and ns.db.favouritePrices[itemID] ~= nil
end

--- Star an item (on = true) or take its star off (false).
function Prices:SetFavourite(itemID, on, name)
    if not ns.db or not itemID then return end
    if type(ns.db.favouritePrices) ~= "table" then ns.db.favouritePrices = {} end

    if on then
        if type(name) ~= "string" or name == "" then
            name = ns.db.favouritePrices[itemID]
            if type(name) ~= "string" then name = true end
        end
        ns.db.favouritePrices[itemID] = name
    else
        ns.db.favouritePrices[itemID] = nil
    end

    -- A starred item keeps an hour by hour price history from the next scan.
    if ns.PriceHistory then ns.PriceHistory:Retrack() end
end

--- itemID -> saved name (or true when none was known).
function Prices:GetFavourites()
    return ns.db and type(ns.db.favouritePrices) == "table" and ns.db.favouritePrices or {}
end

--------------------------------------------------------------------------------
-- My prices
--------------------------------------------------------------------------------

-- Asked 2026-10-06 (a player): set your own price on an item. Two kinds:
--   "use"    this price instead of the auction price, everywhere: a reagent
--            you make for less than the auction house asks.
--   "floor"  the auction price, but never below this: a craft worth more
--            to you than the auction house is paying right now.
-- Kept per realm, like the price table, in `myPrices[realm][itemID] =
-- { price, mode, name, high, under }`. Never rename it. Apart from the price table, so
-- pruning old prices never takes a player's own price with it.

local MY_MODES = { use = true, floor = true }

local function MyPrices(create)
    if not ns.db then return nil end

    if type(ns.db.myPrices) ~= "table" then
        if not create then return nil end
        ns.db.myPrices = {}
    end

    local realmKey = ns.Config:GetRealmKey()
    local realm = ns.db.myPrices[realmKey]
    if type(realm) ~= "table" then
        if not create then return nil end
        realm = {}
        ns.db.myPrices[realmKey] = realm
    end
    return realm
end

--- The price the player set on an item, and its kind ("use" or "floor").
--- nil when none is set. A saved entry this cannot read is left alone.
function Prices:GetMine(itemID)
    local realm = itemID and MyPrices(false)
    local entry = realm and realm[itemID]
    if type(entry) ~= "table" then return nil end

    local price = tonumber(entry.price)
    if not price or price < 1 or not MY_MODES[entry.mode] then return nil end
    return math.floor(price), entry.mode
end

--- Set the player's price on an item. A price of nil or 0 clears it.
-- @return true when saved or cleared, false when the price was refused
function Prices:SetMine(itemID, price, mode, name)
    if not itemID then return false end
    price = tonumber(price)

    if not price or price < 1 then
        local realm = MyPrices(false)
        if realm and realm[itemID] ~= nil then
            realm[itemID] = nil
            Prices:Touch(itemID)
        end
        return true
    end

    if not Prices.IsCredible(price) then return false end
    if not MY_MODES[mode] then mode = "use" end

    local realm = MyPrices(true)
    if not realm then return false end

    local old = realm[itemID]
    if type(name) ~= "string" or name == "" then
        name = type(old) == "table" and type(old.name) == "string" and old.name or nil
    end

    -- Highest and When Cheaper (below) stay with the price when it changes.
    local high = type(old) == "table" and old.high or nil
    local under = type(old) == "table" and old.under or nil
    realm[itemID] = { price = math.floor(price), mode = mode, name = name, high = high, under = under }
    Prices:Touch(itemID)
    return true
end

-- Highest and When Cheaper (the owner said yes, 2026-10-28), kept on the
-- same entry beside a "floor" price, never renamed:
--   high   copper: never list above it (Highest)
--   under  "wait": keep it in the bags while the auction house is under
--          the floor (When Cheaper: Wait); nil lists at the floor, as before
-- Read only while the entry is a "floor" price; a "use" price is used as it is.

--- The limits on a "floor" price: highest (copper or nil) and whether to
--- wait while the auction house is cheaper (true or nil).
function Prices:GetMyLimits(itemID)
    local _, mode = self:GetMine(itemID)
    if mode ~= "floor" then return nil, nil end
    local entry = MyPrices(false)[itemID]
    local high = tonumber(entry.high)
    high = high and high >= 1 and math.floor(high) or nil
    return high, entry.under == "wait" or nil
end

--- Set Highest on an item with a price of its own. nil or 0 takes it off.
-- @return true when saved or cleared, false when the item has no price set
function Prices:SetMyHigh(itemID, high)
    local realm = itemID and MyPrices(false)
    local entry = realm and realm[itemID]
    if type(entry) ~= "table" then return false end
    high = tonumber(high)
    if high and high >= 1 then
        if not Prices.IsCredible(high) then return false end
        high = math.floor(high)
    else
        high = nil
    end
    if entry.high ~= high then
        entry.high = high
        Prices:Touch(itemID)
    end
    return true
end

--- Set When Cheaper on an item with a price of its own: true waits, false
--- or nil lists at the floor.
function Prices:SetMyWait(itemID, wait)
    local realm = itemID and MyPrices(false)
    local entry = realm and realm[itemID]
    if type(entry) ~= "table" then return false end
    local under = wait and "wait" or nil
    if entry.under ~= under then
        entry.under = under
        Prices:Touch(itemID)
    end
    return true
end

--- itemID -> { price, mode, name } for this realm.
function Prices:GetAllMine()
    return MyPrices(false) or {}
end

--------------------------------------------------------------------------------
-- Maintenance
--------------------------------------------------------------------------------

--- Drop items nobody has listed in weeks, so the database does not grow forever.
function Prices:Prune()
    local prices = self:GetTable()
    local cutoff = time() - PRUNE_AFTER_SECONDS

    local removed = 0
    for itemID, record in pairs(prices) do
        if (record.seen or 0) < cutoff then
            prices[itemID] = nil
            removed = removed + 1
        end
    end

    if removed > 0 then
        ns.Debug(("removed %d old price(s)"):format(removed))
    end
    return removed
end

function Prices:Count()
    return Util.Count(self:GetTable())
end

--- Clear out prices a restored database is already carrying that nothing can
--- pay. One such record is what broke the save on 2026-09-21, and a database
--- that came back from macro storage or the data addon with one in it would
--- otherwise keep pricing off it for weeks. The per-field figures go one at a
--- time; only a record whose market value itself is impossible is dropped.
-- @return recordsDropped, fieldsCleared
function Prices:Scrub()
    local prices = self:GetTable()
    local dropped, cleared = 0, 0

    for itemID, record in pairs(prices) do
        if not Prices.IsCredible(record.market) then
            prices[itemID] = nil
            dropped = dropped + 1
        else
            for _, field in ipairs({ "min", "rivalMin", "ownMin" }) do
                if not Prices.IsCredible(record[field]) then
                    record[field] = nil
                    cleared = cleared + 1
                end
            end
            if type(record.suffixes) == "table" then
                for suffix, entry in pairs(record.suffixes) do
                    if type(entry) ~= "table" or not Prices.IsCredible(entry.market) then
                        record.suffixes[suffix] = nil
                        cleared = cleared + 1
                    end
                end
            end
        end
    end

    if dropped > 0 or cleared > 0 then
        ns.Warn(L.Format("removed %d price(s) and %d figure(s) above %s, more than anyone could pay",
            dropped, cleared, Util.FormatMoney(MAX_CREDIBLE_COPPER, { noColor = true, short = true })))
    end

    return dropped, cleared
end

--- How many prices have been refused since the count was last taken, and the
--- last one refused. Reset by reading, so a scan reports its own tally.
function Prices:TakeImplausibleCount()
    local count, last = Prices.implausible or 0, Prices.lastImplausible
    Prices.implausible, Prices.lastImplausible = 0, nil
    return count, last
end

function Prices:OnEnable()
    self:Scrub()
    self:Prune()
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

ns.RegisterCommand("price", L["<item link or name>: what the auction house says"], function(args)
    -- Shift-clicking an item into chat is the natural way to name one.
    local itemID = tonumber(args:match("item:(%d+)")) or tonumber(args:match("^%s*(%d+)%s*$"))

    if not itemID then
        local name = args:gsub("^%s+", ""):gsub("%s+$", "")
        if name ~= "" and Util.HasFunction("C_Item.GetItemInfoInstant") then
            local ok, resolved = pcall(C_Item.GetItemInfoInstant, name)
            if ok then itemID = resolved end
        end
    end

    if not itemID then
        ns.Print(L["usage: /bts price <shift-clicked item, or exact item name>"])
        return
    end

    local record = ns.Prices:Get(itemID)
    if not record then
        ns.Print(L.Format("no auction data for %s. Run |cffc8a44d/bts scan|r at the auction house",
            Util.GetItemLabel(itemID)))

        -- There may still be a price to give: something this account can make
        -- is valued off its materials until a scan finds a real one. Asked of
        -- the chooser, so this cannot quote a different number from the one
        -- the Sell tab would list at.
        local estimate, basis, why = ns.Profit:ChoosePostPrice(itemID)

        if estimate and basis == "derived" then
            ns.PrintRaw(L.Format("  |c%syou would list at %s (an estimate, not a market price)|r",
                ns.COLORS.warn, Util.FormatMoney(estimate)))
            if why then ns.PrintRaw(("    %s"):format(why)) end
        end
        return
    end

    local confidence, reason = ns.Prices:GetConfidence(itemID)
    local liquidity = ns.Prices:GetSalesPerDay(itemID)

    ns.Print(Util.GetItemLabel(itemID))
    ns.PrintRaw(L.Format("  market %s   min %s   qty %d",
        Util.FormatMoney(record.market), Util.FormatMoney(record.min), record.quantity or 0))

    if record.rivalMin then
        -- Asked of the chooser rather than worked out again here, so this
        -- cannot drift from the price the Sell tab would actually use.
        local postPrice, basis, why = ns.Profit:ChoosePostPrice(itemID)

        ns.PrintRaw(L.Format("  cheapest rival %s   you would post at %s (%s)",
            Util.FormatMoney(record.rivalMin),
            Util.FormatMoney(postPrice or record.rivalMin),
            basis or L["no price"]))

        -- "match" on its own does not say whether undercutting was rejected
        -- on the numbers or never costed at all, and those want different
        -- things from you.
        if why then ns.PrintRaw(("    %s"):format(why)) end
    else
        -- No rival on record. Asked of the chooser for the same reason as
        -- above: this must not drift from the price the Sell tab would use.
        local postPrice, basis, why = ns.Profit:ChoosePostPrice(itemID)

        if ns.Prices:HoldsLowest(itemID) then
            ns.PrintRaw(L.Format("  |c%syou hold the lowest listing|r", ns.COLORS.profit))
        end

        if postPrice then
            ns.PrintRaw(L.Format("  no rival listed   you would post at %s (%s)",
                Util.FormatMoney(postPrice), basis or L["no price"]))
            if why then ns.PrintRaw(("    %s"):format(why)) end
        end
    end
    ns.PrintRaw(L.Format("  seen %s over %d scan(s)",
        Util.FormatAgeAgo(ns.Prices:GetAge(itemID)), record.scans or 0))
    ns.PrintRaw(L.Format("  confidence %d%%%s   stock moving %s",
        math.floor(confidence * 100), reason and (" (" .. reason .. ")") or "",
        liquidity and ("%d%%"):format(math.floor(liquidity * 100)) or L["unknown"]))
end)
