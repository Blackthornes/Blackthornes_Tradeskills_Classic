-- Blackthornes Tradeskills -- Data/Auctions.lua
-- What you already have listed.
--
-- Crafting more of something you have sitting unsold on the auction house is
-- how you end up undercutting yourself and tying up gold. This reads your own
-- auctions and caches them per realm, so the profit table can stop recommending
-- an item once you are holding as many as you want listed.

local _, ns = ...

local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Auctions = ns.NewModule("Auctions")

local Util = ns.Util

-- Enum.AuctionStatus.Active. A sold auction is no longer competing for a buyer,
-- so it must not count toward your posted limit.
local STATUS_ACTIVE = (Enum and Enum.AuctionStatus and Enum.AuctionStatus.Active) or 0

--------------------------------------------------------------------------------
-- Storage
--------------------------------------------------------------------------------

function Auctions:GetTable()
    if not ns.db then return {} end

    local realmKey = ns.Config:GetRealmKey()

    ns.db.postedAuctions = ns.db.postedAuctions or {}
    ns.db.postedAuctions[realmKey] = ns.db.postedAuctions[realmKey] or { items = {} }

    return ns.db.postedAuctions[realmKey]
end

--- Who is reading: listings are kept per character within the realm.
local function CharacterKey()
    return ns.Config.GetCharacterKey and ns.Config:GetCharacterKey() or "?"
end

--- Units of an item that came back in the mail (expired or cancelled) for a
--- character since its auctions were last read.
--
-- A reading only changes at the auction house. Between visits, a listing
-- that expired was still counted as listed while the same stack also sat in
-- the mailbox, so Keep in stock counted it twice until the next visit.
--
-- What matters is when the auction ended, not when its mail was read. A
-- stack cancelled or expired before the reading is already missing from it,
-- and taking it off a second time when the mail was opened later read 5
-- still listed as none. An entry's `sent` is when its mail went out; one
-- written before that was kept has only `t`, when the inbox was read.
local function ReturnedSince(itemID, who, since)
    if not since or not (ns.Mail and ns.Mail.GetLedger) then return 0 end

    local ok, ledger = pcall(ns.Mail.GetLedger, ns.Mail)
    if not ok or type(ledger) ~= "table" or not ledger.entries then return 0 end

    local returned = 0
    local entries = ledger.entries

    -- Oldest first, so walk back only as far as the reading. A mail is
    -- always sent before it is read, so nothing further back can count.
    for index = #entries, 1, -1 do
        local entry = entries[index]
        if (entry.t or 0) <= since then break end

        if entry.itemID == itemID and (entry.kind == "expired" or entry.kind == "removed")
            and (who == nil or entry.who == who) and (entry.sent or entry.t) > since then
            returned = returned + (entry.quantity or 0)
        end
    end

    return returned
end

-- The longest an auction stays up: Blizzard's own Sell tab on Forever offers
-- 2, 8 and 24 hours (DURATIONS in Logic/Posting.lua). Everything in a reading
-- older than that has sold or come back since.
local LONGEST_AUCTION = 24 * 3600

--- Is a reading too old to have anything in it still listed?
local function Outlived(updatedAt)
    return updatedAt ~= nil and updatedAt < time() - LONGEST_AUCTION
end

--- How many units of an item you currently have listed, on every character
--- on this realm and faction.
--
-- The game only shows each character its own auctions. The stored reading
-- used to be whichever character last opened the auction house, so Keep in
-- stock forgot an alt's listings the moment another character looked.
-- Each character's last reading is now kept and added up.
--
-- Except a reading older than the longest auction. An alt whose listings sold
-- and who never went back to the auction house kept them counted for good: a
-- sale sends gold rather than the item, so nothing ever took them off.
function Auctions:GetPostedCount(itemID)
    if not itemID then return 0 end

    local record = self:GetTable()
    local byCharacter = record.byCharacter

    -- Saved before readings were kept per character: nobody knows whose it
    -- is, so it stands until a character reads its own.
    if not byCharacter or next(byCharacter) == nil then
        if Outlived(record.updatedAt) then return 0 end
        local listed = record.items[itemID] or 0
        return math.max(0, listed - ReturnedSince(itemID, nil, record.updatedAt))
    end

    local total = 0
    for who, reading in pairs(byCharacter) do
        local listed = (reading.items and reading.items[itemID]) or 0
        if listed > 0 and not Outlived(reading.updatedAt) then
            total = total + math.max(0, listed - ReturnedSince(itemID, who, reading.updatedAt))
        end
    end
    return total
end

-- The most a time band can mean, for a listing whose seconds were not given:
-- Enum.AuctionHouseTimeLeftBand Short, Medium, Long, VeryLong.
local BAND_MOST = { [0] = 30 * 60, [1] = 2 * 3600, [2] = 12 * 3600, [3] = 48 * 3600 }

--- Every listing from each character's last reading on this realm.
--
-- A reading only changes at the auction house, so each row says when it was
-- read and when it ends. One that has ended since has sold or come back in the
-- mail; the reading cannot say which.
--
-- @return array of { itemID, quantity, unit, ends, who, readAt, ended },
--         and how many characters have been read since listings were kept
function Auctions:GetListings()
    local record = self:GetTable()
    local out, characters = {}, 0
    local now = time()

    for who, reading in pairs(record.byCharacter or {}) do
        if type(reading.listings) == "table" then
            characters = characters + 1

            for _, listing in ipairs(reading.listings) do
                local ends = listing.ends
                if not ends and listing.band and BAND_MOST[listing.band] then
                    ends = (reading.updatedAt or now) + BAND_MOST[listing.band]
                end

                out[#out + 1] = {
                    itemID = listing.itemID,
                    quantity = listing.quantity or 1,
                    unit = listing.unit,
                    ends = ends,
                    roughEnd = listing.ends == nil,
                    who = who,
                    readAt = reading.updatedAt,
                    ended = ends ~= nil and ends <= now
                        or Outlived(reading.updatedAt),
                }
            end
        end
    end

    return out, characters
end

--- How many units of an item this character has listed. Verifying a new
--- listing compares against this, since a reading only ever shows your own.
function Auctions:GetOwnPostedCount(itemID)
    if not itemID then return 0 end

    local record = self:GetTable()
    local reading = record.byCharacter and record.byCharacter[CharacterKey()]
    if reading then return (reading.items and reading.items[itemID]) or 0 end

    return record.items[itemID] or 0
end

--- The auction IDs of an item you had listed at the last read this session,
--- as a set, or nil when nothing has been read since login.
function Auctions:GetOwnedIDs(itemID)
    if not self.ownedIDs or not itemID then return nil end
    local copy = {}
    for auctionID in pairs(self.ownedIDs[itemID] or {}) do copy[auctionID] = true end
    return copy
end

--- The cheapest unit price you have an item listed at, or nil when your
--- auctions have not been read or hold none of it.
function Auctions:GetOwnMinPrice(itemID)
    if not itemID then return nil end
    local prices = self:GetTable().prices
    return prices and prices[itemID] or nil
end

--- When your auctions were last read, or nil if never.
function Auctions:GetAge()
    local updatedAt = self:GetTable().updatedAt
    if not updatedAt then return nil end
    return time() - updatedAt
end

--------------------------------------------------------------------------------
-- Limits
--------------------------------------------------------------------------------

--- The cap for one item: its own number, else its profession's, else the
--- account-wide default (a player asked for one number per profession,
--- the owner agreeing 2026-10-13). Zero means no limit.
-- @return the limit, then where it came from: "item", "profession" (with
--         the profession's English name) or "default"
function Auctions:GetLimit(itemID)
    if not ns.db then return 0, "default" end

    ns.db.postLimits = ns.db.postLimits or {}

    local override = ns.db.postLimits[itemID]
    if override ~= nil then return override, "item" end

    -- Only looked up while a profession has a number, so the Profit tab's
    -- one question a row costs nothing more for everyone else.
    local byProfession = ns.db.professionStockLimits
    if byProfession and next(byProfession) ~= nil then
        local profession = self:ProfessionOf(itemID)
        local limit = profession and tonumber(byProfession[profession])
        if limit then return limit, "profession", profession end
    end

    return ns.Config:Get("maxPostedPerItem") or 0, "default"
end

-- [itemID] = the English name of the profession that makes it, from every
-- character's saved recipes. Laid out once and again only when a
-- character's recipes are read again (their recipesCachedAt) or a
-- character comes or goes.
local professionIndex, professionIndexKey

local function ProfessionIndexKey()
    local count, stamp = 0, 0
    for _, record in pairs(ns.db.characters or {}) do
        count = count + 1
        stamp = stamp + (tonumber(record.recipesCachedAt) or 0)
    end
    return count .. ":" .. stamp
end

local function ProfessionIndex()
    if not ns.db then return {} end
    local key = ProfessionIndexKey()
    if professionIndex and professionIndexKey == key then return professionIndex end

    local english = ns.Recipes and ns.Recipes.EnglishProfessionName
    local index = {}
    for _, record in pairs(ns.db.characters or {}) do
        for _, recipe in pairs(record.recipes or {}) do
            local itemID = recipe.outputItemID
            if itemID and not index[itemID] and recipe.skillLineID and english then
                local ok, name = pcall(english, { skillLineID = recipe.skillLineID })
                if ok and name then index[itemID] = name end
            end
        end
    end

    professionIndex, professionIndexKey = index, key
    return index
end

--- The English name of the profession that makes an item, or nil.
function Auctions:ProfessionOf(itemID)
    if not itemID then return nil end
    return ProfessionIndex()[itemID]
end

--- The professions any of your characters make things with, by English
--- name, sorted: the ones Settings offers a number for.
function Auctions:StockProfessions()
    local seen, list = {}, {}
    for _, name in pairs(ProfessionIndex()) do
        if not seen[name] then
            seen[name] = true
            list[#list + 1] = name
        end
    end
    -- One already given a number stays listed, even with its recipes gone.
    for name in pairs(ns.db and ns.db.professionStockLimits or {}) do
        if not seen[name] then
            seen[name] = true
            list[#list + 1] = name
        end
    end
    table.sort(list)
    return list
end

--- A profession's name as the client shows it (German on a German
--- client), from its English name; the English name when the client
--- will not say.
function Auctions:ProfessionLabel(profession)
    local lines = ns.Recipes and ns.Recipes.SKILL_LINE_PROFESSIONS
    local get = C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID
    if type(lines) == "table" and type(get) == "function" then
        for skillLineID, english in pairs(lines) do
            if english == profession then
                local ok, name = pcall(function()
                    local info = get(skillLineID)
                    local value = type(info) == "table" and info.professionName
                    if type(value) == "string" and value ~= "" then return value .. "" end
                end)
                if ok and name then return name end
            end
        end
    end
    return L[profession] or profession
end

--- A profession's own number, or nil when it uses the default.
function Auctions:GetProfessionLimit(profession)
    local limits = ns.db and ns.db.professionStockLimits
    return limits and tonumber(limits[profession]) or nil
end

--- Set a profession's number. nil clears it back to the default; 0 is no
--- limit for that profession.
function Auctions:SetProfessionLimit(profession, limit)
    if not ns.db or type(profession) ~= "string" or profession == "" then return end

    ns.db.professionStockLimits = ns.db.professionStockLimits or {}
    ns.db.professionStockLimits[profession] = tonumber(limit)
        and math.max(0, math.floor(tonumber(limit))) or nil

    if ns.UI then ns.UI:RefreshActiveTab() end
end

--- Forget the profession index. Tests call it; the key catches real changes.
function Auctions:ForgetProfessions()
    professionIndex, professionIndexKey = nil, nil
end

--- How many to keep in stock when no number is set, learned from your own
--- sales (the owner, 2026-10-11: Queue All should work on the first day).
--
-- About two days of what sold over the last week: the ledger's sold entries
-- (Data/Mail.lua) plus sales heard in chat whose mail is not read yet, at
-- least 1 once anything sold and never more than LEARN_MOST. nil when
-- nothing sold that week. The fold over the ledger is kept until the ledger
-- or the heard list changes, since the Profit tab asks once per row.
Auctions.LEARN_DAYS = 7
Auctions.LEARN_HOLD_DAYS = 2
Auctions.LEARN_MOST = 20

local learnedCache, learnedKey

local function LearnedUnits()
    local Mail = ns.Mail
    if not (Mail and Mail.GetLedger) then return {} end

    local entries = Mail:GetLedger().entries or {}
    local heard = Mail.GetHeardList and Mail:GetHeardList() or {}
    local last = entries[#entries]
    local lastHeard = heard[#heard]
    local today = math.floor(time() / 3600)
    local key = ("%d:%s:%d:%s:%d"):format(#entries, tostring(last and last.t),
        #heard, tostring(lastHeard and lastHeard.t), today)
    if learnedCache and learnedKey == key then return learnedCache end

    local since = time() - Auctions.LEARN_DAYS * 86400
    local names = Mail.NameIndex and Mail:NameIndex() or {}
    local units = {}

    for _, entry in ipairs(entries) do
        if entry.kind == "sold" and (entry.t or 0) >= since then
            local itemID = entry.itemID or names[entry.name]
            if itemID then units[itemID] = (units[itemID] or 0) + (entry.quantity or 1) end
        end
    end
    for _, sale in ipairs(heard) do
        if not sale.collected and (sale.t or 0) >= since then
            local itemID = sale.itemID or names[sale.name]
            if itemID then units[itemID] = (units[itemID] or 0) + 1 end
        end
    end

    learnedCache, learnedKey = units, key
    return units
end

function Auctions:LearnsFromSales()
    return ns.Config:Get("learnStockFromSales") ~= false
end

function Auctions:GetLearnedLimit(itemID)
    if not itemID or not self:LearnsFromSales() then return nil end
    local ok, units = pcall(LearnedUnits)
    local sold = ok and units[itemID] or nil
    if not sold or sold <= 0 then return nil end
    local keep = math.ceil(sold * Auctions.LEARN_HOLD_DAYS / Auctions.LEARN_DAYS)
    return math.max(1, math.min(Auctions.LEARN_MOST, keep))
end

--- Forget the learned fold. Tests call it; the key catches real changes.
function Auctions:ForgetLearned()
    learnedCache, learnedKey = nil, nil
end

--- The extra a fast seller may hold beyond its cap, or 0.
--
-- Only your own sales count as "confirmed": the Sales tab's ledger has to show
-- at least three of your listings ended and six in ten of those sold (Demand's
-- "High" from your own record). The market's movement alone never raises it,
-- since that only guesses at what other people sold.
function Auctions:GetFastSellerExtra(itemID)
    if ns.Config:Get("fastSellerBoost") ~= true then return 0 end

    local extra = math.floor(tonumber(ns.Config:Get("fastSellerExtra")) or 0)
    if extra <= 0 or not (ns.Demand and ns.Demand.Get) then return 0 end

    local ok, reading = pcall(ns.Demand.Get, ns.Demand, itemID)
    if ok and reading and reading.source == "yours" and reading.level == "high" then
        return extra
    end
    return 0
end

--- The amount to wait for before making more, or nil when restocking
-- whenever there is room under the cap (the old way, and the default).
function Auctions:GetRestockAt()
    if ns.Config:Get("restockWhenLow") ~= true then return nil end
    return math.max(0, math.floor(tonumber(ns.Config:Get("restockAt")) or 0))
end

--- Set a per-item cap. Passing nil clears the override back to the default.
function Auctions:SetLimit(itemID, limit)
    if not ns.db or not itemID then return end

    ns.db.postLimits = ns.db.postLimits or {}
    ns.db.postLimits[itemID] = limit and math.max(0, math.floor(limit)) or nil

    if ns.UI then ns.UI:RefreshActiveTab() end
end

function Auctions:HasOverride(itemID)
    return ns.db and ns.db.postLimits and ns.db.postLimits[itemID] ~= nil
end

--- How many more you could usefully make.
--
-- The limit covers everything you already have, because an item sitting in your
-- bags is no different from one on the auction house: making another does not
-- get you anything you do not already own. Three sources count against it:
--
--   posted  units listed on the auction house
--   onHand  units in bags and bank (equipped gear is not counted -- it is in
--           use, not stock)
--   inMail  units waiting in the mailbox, which is where an expired auction
--           lands; owned, but in neither of the two above
--   queued  units the craft queue will produce, so queueing 2 and looking again
--           does not then suggest 2 more
--
-- The mailbox is reported apart from the bags rather than folded in, because
-- "2 held" and "2 on their way back from a listing that did not sell" mean
-- quite different things to someone deciding what to make next.
--
-- Two settings change that (asked 2026-10-10):
--
--   restock at   with "Wait until it runs low" ticked, nothing more is made
--                while what you hold (queued included) is above this; once it
--                drops to it, the room is back up to the cap. So 0 means
--                only when you have none left.
--   fast sellers with "Fast sellers keep more" ticked, an item your own
--                sales show selling well gets that many more on its cap.
--
-- @param useLearned with no number set, use what your sales taught
--        (GetLearnedLimit): Queue All and restocking a sale pass it
-- @return remaining, posted, onHand, queued, limit, inMail, waiting, extra,
--         learned
--         remaining is nil when uncapped; limit includes the fast-seller
--         extra; waiting is true when the room is 0 only because stock has
--         not yet dropped to the restock amount; learned is the learned
--         number when that is the limit used
function Auctions:GetRoom(itemID, ignoreRecipeID, useLearned)
    local limit = self:GetLimit(itemID)
    local learned
    if limit <= 0 and useLearned then
        learned = self:GetLearnedLimit(itemID)
        limit = learned or 0
    end
    local posted = self:GetPostedCount(itemID)
    local onHand = ns.Inventory:GetBagCount(itemID) + ns.Inventory:GetBankCount(itemID)
    local inMail = ns.Inventory:GetMailCount(itemID)

    local queued = 0
    for _, entry in ipairs(ns.Queue:GetAll()) do
        -- A sub-craft queued for another craft is used up by it, so it is
        -- not stock: 30 bolts queued for 10 bags left none to sell, yet hid
        -- bolts from the Profit tab as "at your limit".
        if entry.recipeID ~= ignoreRecipeID and not entry.isDependency then
            local recipe = ns.Recipes:GetAny(entry.recipeID)

            if recipe and recipe.outputItemID == itemID then
                local perCraft = math.max(1, recipe.quantityMin or 1)
                queued = queued + (entry.quantity * perCraft)
            end
        end
    end

    if limit <= 0 then
        return nil, posted, onHand, queued, 0, inMail
    end

    local extra = self:GetFastSellerExtra(itemID)
    limit = limit + extra

    local held = posted + onHand + inMail + queued
    local remaining = math.max(0, limit - held)

    -- Whether stock has run low is read from what you hold, not what is
    -- queued: counting the queue, one craft queued with + put the rest of the
    -- restock out of reach. The room is still filled up to the limit with the
    -- queue counted, so queueing twice never goes over it.
    local restockAt = self:GetRestockAt()
    local waiting = false
    if restockAt and remaining > 0 and held - queued > restockAt then
        remaining, waiting = 0, true
    end

    return remaining, posted, onHand, queued, limit, inMail, waiting, extra, learned
end

--- Everything you already hold of an item: listed, bags, bank and mailbox.
function Auctions:GetStock(itemID)
    return self:GetPostedCount(itemID) + ns.Inventory:GetOwnedCount(itemID)
end

--------------------------------------------------------------------------------
-- Reading owned auctions
--------------------------------------------------------------------------------

--- Re-read what this character has listed.
-- @param opts { priority, force } -- raise the priority when a click is waiting
--   on the answer, as verifying a listing is, and force past the coalescing
--   window when that answer is the only thing that settles whether a listing
--   went up. Without force, the refresh fired half a second after an auction
--   was created swallowed the verification refresh three seconds later, and a
--   listing that went up perfectly well was reported as "could not tell".
function Auctions:Refresh(opts)
    opts = opts or {}

    if not ns.Scanner.isAuctionHouseOpen then return false end

    -- Era's older auction house keeps your auctions on the client: nothing
    -- to query through the queue, only the list to read.
    if not Util.HasFunction("C_AuctionHouse.QueryOwnedAuctions") then
        if not Auctions.IsLegacy() then return false end
        local now = GetTime()
        if not opts.force and self.lastRefresh and (now - self.lastRefresh) < 5 then
            return false
        end
        self.lastRefresh = now
        if type(_G.GetOwnerAuctionItems) == "function" then pcall(GetOwnerAuctionItems) end
        self:ScheduleConfirm()
        return true
    end

    -- Several things want this at once after a listing, and each one is a
    -- throttled request. Coalesce them.
    local now = GetTime()
    if not opts.force and self.lastRefresh and (now - self.lastRefresh) < 5 then
        return false
    end
    self.lastRefresh = now

    Util.WhenAuctionReady(function()
        pcall(C_AuctionHouse.QueryOwnedAuctions, {})

        -- The reply may or may not be announced, so go and read it either way.
        Auctions:ScheduleConfirm()
    end, nil, {
        name = "owned auctions",
        key = "owned-auctions",
        -- Bookkeeping, so it waits behind anything the player clicked. It is
        -- also what settles whether a listing went up, so it must not be
        -- starved: a generous expiry rather than a high priority.
        priority = opts.priority or ns.AHQueue.PRIORITY.normal,
        expires = 30,
    })

    return true
end

-- How long after a query goes out we look for the answer ourselves, in seconds.
--
-- Forever has OWNED_AUCTIONS_UPDATED and does fire it -- measured in game, four
-- times in one session -- but not when a listing needs confirming. Waiting five
-- seconds to be told meant a listing that went up perfectly well was reported as
-- "could not tell whether that listing went up" on every single post.
--
-- The reads themselves work: `/bts auctions` returns the right count and item
-- straight after a query. So the answer is read directly rather than waited for,
-- several times, because the server's reply lands some unpredictable moment
-- after the query rather than at a knowable one.
local CONFIRM_DELAYS = { 0.6, 1.4, 2.4, 3.6, 4.8 }

--- Do two itemID -> quantity maps hold the same thing?
--
-- Reading is cheap but redrawing the UI is not, and these reads now happen on a
-- timer rather than only when something changed.
local function SameCounts(a, b)
    if not a then return false end

    for itemID, quantity in pairs(a) do
        if b[itemID] ~= quantity then return false end
    end

    for itemID in pairs(b) do
        if a[itemID] == nil then return false end
    end

    return true
end

--- Read what the client says we have listed right now, and store it.
--
-- Local reads only. Nothing here is throttled, so it is safe to call repeatedly
-- while waiting for a reply to land.
--
-- @param opts.final  settle a pending listing with whatever is read, even if the
--   item is not there. A read that has not seen the server's reply yet must not
--   be allowed to say a listing failed, so only the last read of a sequence --
--   or the client's own announcement, where there is one -- may do that.
function Auctions:ReadOwned(opts)
    opts = opts or {}

    -- A read-back timed for a listing can land after the auction house has
    -- closed, when the game's list of your auctions reads empty. Storing that
    -- said nothing was listed, and Keep in stock suggested crafting more.
    if ns.Scanner and ns.Scanner.isAuctionHouseOpen == false then return end

    local GetInfo
    local ok, count
    if Util.HasFunction("C_AuctionHouse.GetNumOwnedAuctions") then
        ok, count = pcall(C_AuctionHouse.GetNumOwnedAuctions)
        GetInfo = C_AuctionHouse.GetOwnedAuctionInfo
    elseif Auctions.IsLegacy() then
        ok, count = pcall(GetNumAuctionItems, "owner")
        GetInfo = Auctions.LegacyOwnedInfo
    else
        return
    end
    if not ok or not count then return end

    local items = {}
    local prices = {}
    local ids = {}
    local listings = {}
    -- This session only, with each auction's ID and link: what the drawer's
    -- Auctions view lists and cancels (Logic/MyAuctions.lua).
    local live = {}
    -- Auctions marked sold, so a cancel that lost the race to a buyer says so.
    local sold = {}
    local readAt = time()

    for index = 1, count do
        local infoOk, info = pcall(GetInfo, index)

        if infoOk and info then
            local itemID = info.itemKey and info.itemKey.itemID

            -- status is nil on some clients; treat only an explicit non-active
            -- status as sold rather than discarding everything.
            local active = info.status == nil or info.status == STATUS_ACTIVE

            -- Every auction's id, sold ones too. They only tell a new listing
            -- apart, and one bought within seconds is already marked sold
            -- when it is read back: counted as active only, it was reported
            -- as refused by the auction house.
            if itemID and info.auctionID then
                ids[itemID] = ids[itemID] or {}
                ids[itemID][info.auctionID] = true
            end

            if info.auctionID and not active then sold[info.auctionID] = true end

            if itemID and active then
                local quantity = info.quantity or 1
                items[itemID] = (items[itemID] or 0) + quantity

                -- The cheapest unit price you have it listed at. A commodity
                -- listing carries a unit price; an item auction carries the
                -- stack's buyout. This is what lets a browse row that says
                -- "you have a listing here" be read as yours or a rival's.
                local unit = tonumber(info.unitPrice)
                if not unit and tonumber(info.buyoutAmount) and info.buyoutAmount > 0 then
                    -- A commodity's buyout is already the price of one (it is
                    -- listed by unit price); dividing it by the quantity read
                    -- 20 Linen at 30c as 1c each.
                    if ns.Scanner and ns.Scanner.IsCommodity and ns.Scanner:IsCommodity(itemID) then
                        unit = info.buyoutAmount
                    else
                        unit = Util.UnitPriceFromStack(itemID, info.buyoutAmount, quantity)
                    end
                end

                if unit and unit > 0 and (not prices[itemID] or unit < prices[itemID]) then
                    prices[itemID] = unit
                end

                -- Each listing as it stands, for the Sales tab's Still listed
                -- view. When it ends is read from the seconds left where the
                -- client gives them, else from the rough time band.
                local listing = { itemID = itemID, quantity = quantity }
                if unit and unit > 0 then listing.unit = unit end
                local secondsOk, seconds = pcall(function() return tonumber(info.timeLeftSeconds) end)
                if secondsOk and seconds and seconds >= 0 then
                    listing.ends = readAt + seconds
                else
                    local bandOk, band = pcall(function() return tonumber(info.timeLeft) end)
                    if bandOk and band then listing.band = band end
                end
                listings[#listings + 1] = listing

                if info.auctionID then
                    local linkOk, link = pcall(function()
                        return type(info.itemLink) == "string" and info.itemLink or nil
                    end)
                    local bidOk, hasBid = pcall(function()
                        return (tonumber(info.bidAmount) or 0) > 0 and info.bidder ~= nil
                    end)
                    live[#live + 1] = {
                        auctionID = info.auctionID,
                        itemID = itemID,
                        link = linkOk and link or nil,
                        quantity = quantity,
                        unit = listing.unit,
                        ends = listing.ends,
                        band = listing.band,
                        hasBid = bidOk and hasBid or false,
                        -- The exact key, random suffix and all, so Check
                        -- Places searches this very item (MyAuctions).
                        itemKey = type(info.itemKey) == "table" and info.itemKey or nil,
                    }
                end
            end
        end
    end

    local record = self:GetTable()
    local changed = record.auctionCount ~= count or not SameCounts(record.items, items)

    -- Counted so `/bts auctions` can say whether a reading ever happened. An
    -- item with nothing listed and an item never read for at all look the
    -- same in the stored table, and only one of those is a bug.
    self.readCount = (self.readCount or 0) + 1

    record.items = items
    record.prices = prices

    record.byCharacter = record.byCharacter or {}
    record.byCharacter[CharacterKey()] = { items = items, updatedAt = time(), listings = listings }
    -- This session only: auction IDs are for telling a new listing apart.
    self.ownedIDs = ids
    self.live, self.liveAt = live, readAt
    if ns.MyAuctions and ns.MyAuctions.OnRead then ns.MyAuctions:OnRead(live, opts.final, sold) end
    record.updatedAt = time()
    record.auctionCount = count

    if changed then
        ns.Debug(("read %d of your auction(s), %d different item(s)"):format(
            count, Util.Count(items)))
    end

    -- A listing waiting to be verified is settled by what we actually hold,
    -- which is authoritative in a way that event timing is not. Several items
    -- can be waiting at once, each settled by its own item ID.
    local Posting = ns.Posting
    local waiting
    if Posting and Posting.AllPending then
        waiting = Posting:AllPending()
    else
        waiting = { Posting and Posting.pending }
    end

    for _, pending in ipairs(waiting) do
        -- Still waiting for a query sent after it was listed: a reading from
        -- before would say it is missing.
        if pending.verifying and not pending.awaiting then
            local posted = items[pending.itemID] or 0

            -- A listing of this item that was not there before is the new one.
            -- The count alone can miss it: one of yours selling since the last
            -- read leaves the count where it was.
            local appeared = false
            if pending.idsBefore then
                for auctionID in pairs(ids[pending.itemID] or {}) do
                    if not pending.idsBefore[auctionID] then appeared = true break end
                end
            end

            -- Several auctions (copies listed back to back, or many from one
            -- click) are settled once all of them show, or on the last reading,
            -- so the first to appear does not report the rest as missing.
            local wanted = 1
            if (pending.quantity or 1) > 1 and not pending.isCommodity then
                wanted = pending.quantity
            end
            local gained = posted - (pending.postedBefore or 0)

            if opts.final or gained >= wanted or (wanted == 1 and appeared) then
                Posting:ResolvePending(posted, appeared, pending)
            end
        end
    end

    if changed and ns.UI then
        ns.UI:OnAuctionsUpdated()
    end
end

--- True on Era's older auction house, which has no C_AuctionHouse.
function Auctions.IsLegacy()
    return ns.LegacyScan ~= nil and ns.LegacyScan.Applies ~= nil and ns.LegacyScan:Applies() == true
end

--- One of your auctions on Era, in the shape GetOwnedAuctionInfo gives.
--- Era gives no auction ID and the stack's buyout; a sold one waits for
--- its money in the list, so it is marked sold rather than active.
function Auctions.LegacyOwnedInfo(index)
    local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, saleStatus, itemID =
        GetAuctionItemInfo("owner", index)
    if not itemID then return nil end

    local link
    if type(_G.GetAuctionItemLink) == "function" then
        local okLink, value = pcall(GetAuctionItemLink, "owner", index)
        if okLink and type(value) == "string" then link = value end
    end

    return {
        itemKey = { itemID = itemID },
        quantity = tonumber(count) or 1,
        buyoutAmount = tonumber(buyout) or 0,
        status = (saleStatus == 1) and (STATUS_ACTIVE + 1) or nil,
        itemLink = link,
    }
end

--- Era tells us when your list changed, after a listing goes up among
--- other times. Only a read: the listing's own read back settles it.
function Auctions:OnLegacyOwnedUpdate()
    if not Auctions.IsLegacy() then return end
    self:ReadOwned()
end

--- The client announcing that owned auctions changed, where it does so.
function Auctions:OnOwnedAuctionsUpdated()
    -- Counted, because registering this event and actually receiving it are two
    -- different things on this client and only the second one is any use.
    -- Reading registration as proof of delivery is what had the addon waiting
    -- on an announcement that did not come, and a successful listing reporting
    -- "could not tell".
    self.ownedEventCount = (self.ownedEventCount or 0) + 1

    -- The server has answered, so this reading is as good as it is going to get.
    self:ReadOwned({ final = true })
end

--- Go and look for the reply, rather than trusting it to be announced.
--
-- Each query supersedes the last, so a sequence still running when a newer query
-- goes out stops rather than resolving a listing against a stale reading.
function Auctions:ScheduleConfirm()
    local token = (self.confirmToken or 0) + 1
    self.confirmToken = token

    -- This query went out after every listing waiting on one, so its readings
    -- may settle them (Posting:VerifyPending).
    local Posting = ns.Posting
    if Posting and Posting.AllPending then
        for _, pending in ipairs(Posting:AllPending()) do pending.awaiting = nil end
    end

    for i = 1, #CONFIRM_DELAYS do
        local isLast = (i == #CONFIRM_DELAYS)

        C_Timer.After(CONFIRM_DELAYS[i], function()
            if Auctions.confirmToken ~= token then return end

            Auctions:ReadOwned({ final = isLast })
        end)
    end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function Auctions:OnEnable()
    -- This client accepts the registration. Whether it ever sends the event is
    -- a separate question, and the answer appears to be no -- which is not
    -- something a registration check can tell you, so both are recorded and
    -- `/bts auctions` reports them separately. Verification depends on neither.
    self.ownedEventCount = 0
    self.hasOwnedEvent = ns.RegisterEvent(
        self, "OWNED_AUCTIONS_UPDATED", self.OnOwnedAuctionsUpdated) and true or false
    ns.RegisterEvent(self, "AUCTION_OWNED_LIST_UPDATE", self.OnLegacyOwnedUpdate)

    self.openRefreshes = 0

    ns.RegisterEvent(self, "AUCTION_HOUSE_SHOW", function()
        -- Slight delay: the auction house is not ready to answer queries the
        -- instant it opens.
        C_Timer.After(0.5, function()
            -- Forced past the coalescing window, which the other callers want
            -- and this one does not. Opening the house is the moment the
            -- stored reading is most likely to be wrong -- listings sold or
            -- expired while it was shut -- and closing and reopening within
            -- five seconds is an ordinary thing to do, not a duplicate.
            Auctions.openRefreshes = (Auctions.openRefreshes or 0) + 1
            Auctions:Refresh({ force = true })
        end)
    end)

    -- Posting or cancelling changes the count, so re-read rather than drift.
    ns.RegisterEvent(self, "AUCTION_HOUSE_AUCTION_CREATED", function()
        C_Timer.After(0.5, function() Auctions:Refresh() end)
    end)

    -- Forced: cancelling several in a row fell inside the five-second
    -- window, and the count kept the later ones as still listed.
    ns.RegisterEvent(self, "AUCTION_CANCELED", function()
        C_Timer.After(0.5, function() Auctions:Refresh({ force = true }) end)
    end)
end

--------------------------------------------------------------------------------
-- Diagnostics
--------------------------------------------------------------------------------

-- Verification of a listing rests entirely on being able to read your own
-- auctions. If that reading is broken, a successful post looks like a failure,
-- so it needs to be checkable on its own.
ns.RegisterCommand("auctions", L["show the auctions the game says you have up"], function()
    if not ns.Scanner.isAuctionHouseOpen then
        ns.Print(L["the auction house must be open"])
        return
    end

    local hasQuery = Util.HasFunction("C_AuctionHouse.QueryOwnedAuctions")
    local hasCount = Util.HasFunction("C_AuctionHouse.GetNumOwnedAuctions")
    local hasInfo = Util.HasFunction("C_AuctionHouse.GetOwnedAuctionInfo")

    ns.Print("your auctions")
    ns.PrintRaw(("  QueryOwnedAuctions:   %s"):format(hasQuery and "yes" or "no"))
    ns.PrintRaw(("  GetNumOwnedAuctions:  %s"):format(hasCount and "yes" or "no"))
    ns.PrintRaw(("  GetOwnedAuctionInfo:  %s"):format(hasInfo and "yes" or "no"))
    local announces
    if not Auctions.hasOwnedEvent then
        announces = "not in this version of the game"
    elseif (Auctions.ownedEventCount or 0) > 0 then
        announces = ("yes, %d time(s) this session"):format(Auctions.ownedEventCount)
    else
        announces = "listening, but it has not happened this session"
    end

    ns.PrintRaw(("  change alerts:        %s"):format(announces))

    if hasCount then
        local ok, count = pcall(C_AuctionHouse.GetNumOwnedAuctions)
        ns.PrintRaw(("  count right now:      %s"):format(
            ok and tostring(count) or "call failed"))

        if ok and count and count > 0 and hasInfo then
            for index = 1, math.min(count, 8) do
                local infoOk, info = pcall(C_AuctionHouse.GetOwnedAuctionInfo, index)

                if infoOk and info then
                    ns.PrintRaw(("    %d: item=%s qty=%s status=%s"):format(
                        index,
                        tostring(info.itemKey and info.itemKey.itemID),
                        tostring(info.quantity),
                        tostring(info.status)))
                else
                    ns.PrintRaw(("    %d: could not be read"):format(index))
                end
            end
        end
    end

    -- What the rest of the addon actually reads, as against what the calls
    -- above can do. The complaint that started this was that the craft list
    -- ignored posted auctions, and "nothing is listed" and "the reading never
    -- happened" look identical in the stored table -- so report the stored
    -- answer and how it got there, not the attempt.
    local record = Auctions:GetTable()
    local age = Auctions:GetAge()

    ns.PrintRaw(("  stored for this realm: %d item(s), %s"):format(
        Util.Count(record.items or {}),
        age and ("read %ds ago"):format(age) or "never read"))
    ns.PrintRaw(("  times read:           %d this session, %d when the auction house opened"):format(
        Auctions.readCount or 0, Auctions.openRefreshes or 0))

    -- And whether the limit is doing anything, which is the other half of
    -- "why is it still suggesting this". A limit of zero is no limit, and a
    -- limit nothing has reached suppresses nothing.
    local cap = ns.Config:Get("maxPostedPerItem") or 0

    if cap <= 0 then
        ns.PrintRaw("  keep in stock:        no limit set (Settings)")
    else
        -- Every cached recipe, which is hundreds of calls. Acceptable in a
        -- command run by hand, and it is the only honest way to answer "how
        -- many crafts is this actually holding back".
        local atLimit = 0
        for recipeID in pairs(ns.Recipes:GetAll()) do
            local analysis = ns.Profit:Analyse(recipeID)
            if analysis and analysis.atPostLimit then atLimit = atLimit + 1 end
        end

        ns.PrintRaw(("  keep in stock:        %d per item"):format(cap))
        ns.PrintRaw(("  crafts at that limit: %d, not suggested"):format(atLimit))
    end
    for _, profession in ipairs(Auctions:StockProfessions()) do
        local own = Auctions:GetProfessionLimit(profession)
        if own then
            ns.PrintRaw(("  keep in stock:        %d for %s"):format(own, profession))
        end
    end

    -- Re-query, then report again: the count above may predate any reply.
    --
    -- Paced like every other request even though this is a diagnostic run by
    -- hand. A command that quietly spends the player's allowance is a poor thing
    -- to reach for when the complaint is that the allowance ran out.
    if hasQuery then
        ns.PrintRaw("  asking the auction house again...")

        Util.WhenAuctionReady(function()
            pcall(C_AuctionHouse.QueryOwnedAuctions, {})

            C_Timer.After(2, function()
                local ok, count = pcall(C_AuctionHouse.GetNumOwnedAuctions)
                ns.Print(("after asking again: %s auction(s)"):format(
                    ok and tostring(count) or "call failed"))
            end)
        end, function()
            if not (ns.AHQueue and ns.AHQueue.IsFlushing and ns.AHQueue:IsFlushing()) then
                ns.Warn("the auction house stayed busy, so it was not asked again.")
            end
        end, {
            name = "your auctions (check)",
            key = "owned-auctions",
            priority = ns.AHQueue.PRIORITY.urgent,
            expires = 10,
        })
    end
end)
