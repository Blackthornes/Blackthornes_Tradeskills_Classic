-- Blackthornes Tradeskills -- Data/Scanner.lua
-- Auction house scanning.
--
-- Forever exposes C_AuctionHouse.ReplicateItems, retail's bulk snapshot call,
-- so a full sweep is one request plus a read loop rather than hundreds of
-- throttled browse pages. The read loop is still tens of thousands of rows, so
-- it runs through a frame-budgeted worker instead of blocking the client.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Scanner = ns.NewModule("Scanner")

local Util = ns.Util

-- The random suffix a link names, or nil (Util.LinkSuffix, when there).
local function LinkSuffix(link)
    if type(link) ~= "string" or type(Util.LinkSuffix) ~= "function" then return nil end
    return Util.LinkSuffix(link)
end

-- Blizzard rate-limits the bulk snapshot hard. Asking more often than this just
-- returns the same cached data and wastes the allowance.
local REPLICATE_COOLDOWN = 15 * 60

-- How long to wait for the quick full scan to answer before scanning page by
-- page instead. It was six seconds, and as the auction house filled up the
-- server took longer than that to build the snapshot: every quick scan gave
-- way to the page-by-page one even hours after the last (2026-10-03).
-- An answer that comes later still is read anyway; see
-- REPLICATE_ITEM_LIST_UPDATE.
local QUICK_SCAN_WAIT = 30

-- A browse sweep that never reports itself complete would otherwise page for
-- ever, one throttled request at a time.
local MAX_BROWSE_PAGES = 40

-- How many pages a page-by-page sweep is drawn against. The game never says
-- how many pages there are, so the bar fills toward this and the label gives
-- the real count read so far.
local BROWSE_PAGES_FOR_BAR = 20

-- How long to wait for a targeted search to answer before deciding it never
-- will. Leaving the wait open is what left the searching indicator turning.
local SEARCH_TIMEOUT = 8

-- How long one page of a page-by-page sweep may take to answer, timed from
-- when that page was asked for.
local BROWSE_TIMEOUT = 15

-- Enum.ItemCommodityStatus.Commodity, hardcoded only as a fallback.
local COMMODITY_STATUS = (Enum and Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Commodity) or 2
local ITEM_STATUS = (Enum and Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Item) or 1

Scanner.isAuctionHouseOpen = false
Scanner.isScanning = false

--------------------------------------------------------------------------------
-- Identity
--------------------------------------------------------------------------------

-- Undercutting the cheapest listing is only correct when that listing belongs
-- to somebody else. Beating your own auction by a copper just walks your own
-- price down, which on a quiet realm compounds with every relist.

local function GetPlayerIdentity()
    if Scanner.playerName then
        return Scanner.playerName, Scanner.playerFullName, Scanner.playerSurname, Scanner.playerRealm
    end

    local ok, name = pcall(UnitName, "player")
    Scanner.playerName = (ok and name) or "?"

    local realmOk, realm = pcall(GetRealmName)
    if realmOk and realm then
        -- ownerFullName arrives as Name-Realm with spaces stripped.
        Scanner.playerRealm = realm:gsub("%s", "")
        Scanner.playerFullName = Scanner.playerName .. "-" .. Scanner.playerRealm
    end

    -- Forever lets any number of characters share a first name, so a first
    -- name alone is not you. Asked once a session: finding it looks through
    -- the game's functions, which is far too slow to do for every row.
    if ns.Config and ns.Config.ReadSurname then
        local surnameOk, surname = pcall(ns.Config.ReadSurname, ns.Config)
        if surnameOk and type(surname) == "string" and surname ~= "" then
            Scanner.playerSurname = surname
        end
    end

    return Scanner.playerName, Scanner.playerFullName, Scanner.playerSurname, Scanner.playerRealm
end

-- A seller's name and realm, from "Name" or "Name-Realm".
local function SplitOwner(text)
    if type(text) ~= "string" or text == "" then return nil end

    local name, realm = text:match("^(.-)%-([^%-]+)$")
    if not name or name == "" then return text, nil end

    return name, (realm:gsub("%s", ""))
end

function Scanner:IsOwnAuction(owner, ownerFullName)
    local name, fullName, surname, realm = GetPlayerIdentity()

    -- With a last name known, only the whole name is you. A rival who shares
    -- your first name used to be read as you, and your own listings were then
    -- never undercut against theirs.
    if surname then
        local wanted = name .. " " .. surname

        local function Matches(text)
            local rowName, rowRealm = SplitOwner(text)
            if rowRealm and realm and rowRealm ~= realm then return false end

            -- A row that carries only a first name cannot be told apart, and
            -- whether Forever writes the seller that way is not yet known.
            -- Reading your own listing as a rival's would have you undercut
            -- yourself, which costs more than the rare same-name rival.
            if rowName and not rowName:find(" ", 1, true) then return rowName == name end

            return rowName == wanted
        end

        return Matches(ownerFullName) or Matches(owner)
    end

    -- No last name to go on (a character without one, or a client that will
    -- not say), so the first name is all there is.
    if ownerFullName and fullName and ownerFullName == fullName then return true end
    if owner and owner == name then return true end

    return false
end

--------------------------------------------------------------------------------
-- Commodity status cache
--------------------------------------------------------------------------------

-- Whether an item is a commodity decides how to read its price, and the answer
-- never changes for an item, so it is kept in the database and travels with
-- it. It used to live only for the session, and only for items you happened
-- to be holding: every craft you had not made yet was priced as an item
-- auction, whole-silver step included, so a 45c commodity showed as 1s.
local sessionCommodity = {}

local function CommodityStore()
    if not ns.db then return sessionCommodity end
    ns.db.commodity = ns.db.commodity or {}
    return ns.db.commodity
end

-- Items looked for in the bags and not found, cleared whenever the bags
-- change and never trusted for long in case that event is missed. A full
-- scan asked about every row, and for anything not held that was a walk of
-- every bag slot per row.
local notHeld = {}
local NOT_HELD_SECONDS = 10

function Scanner:ForgetNotHeld()
    notHeld = {}
end

--- Find an item in the bags, as an ItemLocation.
--
-- GetItemCommodityStatus wants a location rather than an ID, so commodity
-- status can only be determined for something you are actually holding.
local function LocateInBags(itemID)
    if type(_G.ItemLocation) ~= "table" then return nil end

    -- Every container being carried, not the four ordinary bags: an item held
    -- only in a reagent bag would otherwise have no commodity status, and
    -- commodity status is what decides how the thing is priced and listed.
    for _, bag in ipairs(ns.Inventory:GetCarriedBags()) do
        local slotsOk, slots = pcall(C_Container.GetContainerNumSlots, bag)

        if slotsOk and slots then
            for slot = 1, slots do
                local infoOk, info = pcall(C_Container.GetContainerItemInfo, bag, slot)

                if infoOk and info and info.itemID == itemID then
                    -- A colon method: ItemLocation has to be passed as self.
                    local ok, location =
                        pcall(ItemLocation.CreateFromBagAndSlot, ItemLocation, bag, slot)

                    if ok and location then
                        local validOk, valid = pcall(location.IsValid, location)
                        if validOk and valid then return location end
                    end
                end
            end
        end
    end
end

--- Does the auction house sell this by the stack rather than as one listing?
--
-- This decides whether posting uses PostCommodity or PostItem, and getting it
-- wrong means the auction house declines the listing with no explanation.
--
-- On this client GetItemCommodityStatus takes an ItemLocation. An item ID, an
-- item link and an item key are all rejected with "bad argument #1", which a
-- pcall turns into a silent "not a commodity" for everything.
function Scanner:IsCommodity(itemID, location)
    return self:GetCommodityStatus(itemID, location) == true
end

--- Commodity or not, or nil when nobody has been able to say yet.
--
-- Three answers rather than two, because "not known" and "not a commodity"
-- want different handling from anything estimating a price: the second is a
-- whole-silver item auction, the first is a guess either way.
--
-- @param location  optional ItemLocation the caller already holds, as the
--   posting path does. It is asked about directly, so a listing never
--   depends on the bag memo below being fresh.
function Scanner:GetCommodityStatus(itemID, location)
    if not itemID then return nil end

    local known = CommodityStore()[itemID]
    if known ~= nil then return known end

    if not Util.HasFunction("C_AuctionHouse.GetItemCommodityStatus") then
        return nil
    end

    if not location then
        local missedAt = notHeld[itemID]
        if missedAt and (GetTime() - missedAt) < NOT_HELD_SECONDS then return nil end

        location = LocateInBags(itemID)
        if not location then
            -- Not held, so there is nothing to ask about. Remembered only
            -- briefly: the answer becomes available as soon as one is in
            -- the bags.
            notHeld[itemID] = GetTime()
            return nil
        end
    end

    local ok, status = pcall(C_AuctionHouse.GetItemCommodityStatus, location)
    if not ok then
        if not self.warnedCommodityStatus then
            self.warnedCommodityStatus = true
            ns.Warn(L["the game wouldn't say whether this item is a commodity, so posting it may go wrong."])
        end
        return nil
    end

    -- Only a clear answer is kept for good. Unknown (0, item data not in yet)
    -- was saved as "not a commodity" and priced listings per stack.
    if status ~= COMMODITY_STATUS and status ~= ITEM_STATUS then return nil end
    local result = (status == COMMODITY_STATUS)

    self:LearnCommodity(itemID, result)
    return result
end

--- Remember what a search or the client said about an item.
--
-- A targeted search answers through one of two events, and which one is the
-- status: a commodity's book arrives as COMMODITY_SEARCH_RESULTS_UPDATED and
-- an item auction's as ITEM_SEARCH_RESULTS_UPDATED. So the status can be
-- learned for something you have never held, which is most of what the
-- Profit tab is pricing.
function Scanner:LearnCommodity(itemID, isCommodity)
    if not itemID or type(isCommodity) ~= "boolean" then return end
    CommodityStore()[itemID] = isCommodity
end

--------------------------------------------------------------------------------
-- Full scan
--------------------------------------------------------------------------------

--- Whether a scan of any kind can run.
--
-- The bulk snapshot being rate limited is not a reason to refuse: browsing
-- is slower but always available, so the button should still work.
function Scanner:CanFullScan()
    if not self.isAuctionHouseOpen then
        return false, L["the auction house must be open"]
    end
    if self.isScanning then
        return false, L["a scan is already running"]
    end
    if self.scanQueued or self.browseQueued then
        return false, L["a scan is already waiting to start"]
    end

    local caps = ns.Compat:Get().auction
    if not caps.hasReplicate and not caps.hasBrowseQuery and not caps.hasLegacyQuery then
        return false, L["Scanning doesn't work here."]
    end

    return true
end

--- Seconds until the bulk snapshot is usable again, or nil if it is ready.
function Scanner:GetSnapshotCooldown()
    if not ns.Compat:Get().auction.hasReplicate then return nil end

    local last = ns.db and ns.db.lastReplicateRequest or 0
    local remaining = REPLICATE_COOLDOWN - (time() - last)

    return remaining > 0 and remaining or nil
end

function Scanner:StartFullScan()
    local allowed, reason = self:CanFullScan()
    if not allowed then
        ns.Print(reason)
        return false
    end

    -- Era's older auction house has its own reader (Data/LegacyScan.lua).
    if ns.LegacyScan and ns.LegacyScan:Applies() then
        return ns.LegacyScan:Start()
    end

    self.scanStartedAt = GetTime()
    -- Wall-clock start, so a finished scan can tell its own records from
    -- ones a search wrote while it ran (Prices:ClearMissing).
    self.scanStartedWall = time()

    -- Snapshot when it is available, browse when it is not. Both end up in
    -- the same price database.
    local cooldown = self:GetSnapshotCooldown()
    if cooldown and ns.db.lastReplicateByOther then
        -- With Auctionator loaded it is most likely the one that asked, and
        -- its scan when the auction house opens is a setting it can turn off.
        if type(rawget(_G, "Auctionator")) == "table" then
            ns.Print(L["Another addon just did a full scan, so doing a page by page scan instead. Turn off Auctionator's scan when the auction house opens to get the quick scan back."])
        else
            ns.Print(L["Another addon just did a full scan, so doing a page by page scan instead."])
        end
        return self:StartBrowseScan()
    end
    if cooldown then
        -- Says when it was last used as well, so a cooldown nobody remembers
        -- starting can be checked against what the player was doing then.
        ns.Print(L.Format("the quick full scan was last used %s and can be used again in %s, so scanning page by page instead",
            Util.FormatAgeAgo(REPLICATE_COOLDOWN - cooldown),
                cooldown < 60 and L["under a minute"] or Util.FormatAge(cooldown)))
        return self:StartBrowseScan()
    end

    ns.Print(L["asking for a quick full scan..."])

    -- Queued rather than sent. A scan is the addon's heaviest use of a channel
    -- the player is also posting on, so it waits behind anything they clicked
    -- and behind Blizzard's own sell frame. isScanning is set when the request
    -- actually goes out, so a queued scan does not grey out the Post button.
    self.scanQueued = true

    ns.AHQueue:Request({
        name = "quick full scan",
        key = "scan",
        priority = ns.AHQueue.PRIORITY.scan,
        expires = 60,

        send = function()
            Scanner.scanQueued = false
            Scanner.isScanning = true

            -- Stamped here, when the request really goes out, and not when it
            -- was queued. A queued scan can wait behind the player's posting
            -- and then give up, or be cancelled by closing the auction house,
            -- and stamping it at queue time started a fifteen minute cooldown
            -- for a scan the server never heard about.
            ns.db.lastReplicateRequest = time()
            ns.db.lastReplicateAnswered = nil
            ns.db.lastReplicateByOther = nil
            Scanner.awaitingReplicate = true

            Scanner.sendingOwnReplicate = true
            local sent = pcall(C_AuctionHouse.ReplicateItems)
            Scanner.sendingOwnReplicate = false
            if not sent then
                Scanner.awaitingReplicate = false
                ns.Print(L["the game refused the quick full scan, so scanning page by page instead"])
                Scanner:StartBrowseScan()
                return true
            end

            -- ReplicateItems is throttled server-side to roughly once every
            -- fifteen minutes, and when it is on cooldown it does not answer at
            -- all -- no event, no error. Our own cooldown record can also be
            -- lost, so silence here is expected rather than exceptional. Fall
            -- back to browsing instead of leaving the player watching nothing.
            -- A big auction house is also slow to answer, so the wait is
            -- generous and a late answer still takes over from the browse.
            Scanner.timeoutHandle = C_Timer.NewTimer(QUICK_SCAN_WAIT, function()
                Scanner.timeoutHandle = nil
                if Scanner.isScanning and not Scanner.isReading then
                    ns.Print(L.Format("the quick full scan has not answered in %d seconds, so scanning page by page until it does",
                        QUICK_SCAN_WAIT))
                    Scanner:StartBrowseScan()
                end
            end)

            return true
        end,

        onGiveUp = function()
            Scanner.scanQueued = false

            if not Scanner.isScanning then
                if not (ns.AHQueue and ns.AHQueue.IsFlushing and ns.AHQueue:IsFlushing()) then
                    ns.Print(L["the auction house stayed busy; the scan was not sent."])
                end
                if ns.UI then ns.UI:OnScanComplete() end
            end
        end,
    })

    return true
end

--------------------------------------------------------------------------------
-- Browse scan
--------------------------------------------------------------------------------

-- The paged fallback. It returns less per item than the bulk snapshot -- the
-- cheapest listing and the total quantity, rather than the whole order book --
-- but it is not rate limited, so it always works. Exact rival prices come from
-- the targeted search done before posting anyway.

function Scanner:StartBrowseScan()
    if self.isBrowsing or self.browseQueued then return false end

    if not Util.HasFunction("C_AuctionHouse.SendBrowseQuery") then
        self.isScanning = false
        ns.Warn(L["this version of the game does not let addons scan page by page either"])
        return false
    end

    self.browsePages = 0
    self.browseRowsSeen = nil
    self.browseLast = nil
    self.scanStartedAt = self.scanStartedAt or GetTime()

    -- isBrowsing is deliberately not set yet. It means "our browse query is out
    -- and the next results event is ours", and setting it while the request is
    -- still waiting its turn would make us read the player's own search as a
    -- scan -- and then page through it, one throttled request at a time.
    self.browseQueued = true

    ns.Print(L["scanning the auction house page by page..."])

    if self.verbose then
        -- A rejected event registration is silent and looks exactly like a
        -- hung scan, so state it up front.
        local unknown = ns.GetUnknownEvents()
        for _, event in ipairs({
            "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
            "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
        }) do
            ns.PrintRaw(("  %s: %s"):format(event,
                unknown[event] and "|cffe5604fREJECTED|r" or "|cff4fd18bregistered|r"))
        end
    end

    self:QueueBrowseQuery("", {
        onSend = function()
            Scanner.browseQueued = false
            Scanner.isScanning = true
            Scanner.isBrowsing = true
            Scanner.browseForeign = false
        end,

        onGiveUp = function()
            Scanner.browseQueued = false
            Scanner.isScanning = false
            Scanner.isBrowsing = false

            if not (ns.AHQueue and ns.AHQueue.IsFlushing and ns.AHQueue:IsFlushing()) then
                ns.Warn(L["the auction house stayed busy; the scan was not sent."])
            end
            if ns.UI then ns.UI:OnScanComplete() end
        end,
    })

    return true
end

--- Send one browse query, paced, and start the no-answer timer when it goes.
--
-- The timeout is armed on send rather than on queue: a request still waiting its
-- turn has not failed to answer, and warning about it was how a polite wait
-- looked like a hung scan.
function Scanner:QueueBrowseQuery(searchString, opts)
    opts = opts or {}

    ns.AHQueue:Request({
        name = "browse query",
        key = "browse",
        priority = ns.AHQueue.PRIORITY.scan,
        expires = 60,
        onGiveUp = opts.onGiveUp,

        send = function()
            if opts.onSend then opts.onSend() end

            -- Marked so the watch on every browse send (OnEnable) can tell
            -- this one from a search somebody else started.
            Scanner.sendingOwnBrowse = true
            local ok = pcall(C_AuctionHouse.SendBrowseQuery, {
                searchString = searchString or "",
                sorts = {},
                filters = {},
                itemClassFilters = {},
                minLevel = 0,
                maxLevel = 0,
            })
            Scanner.sendingOwnBrowse = false

            if not ok then
                ns.Warn(L["the game refused the page-by-page scan"])
                return false
            end

            Scanner:ArmBrowseTimeout()

            return true
        end,
    })
end

--- Start (or restart) the wait for the next page of a sweep to answer.
--
-- Armed each time a request actually goes out, the first query and every
-- page after it, and stopped when a page lands. It used to be armed once, on
-- the first query, and never again. Paging is paced at eight requests in
-- fifteen seconds, so a sweep still going strong reached page 8 just as that
-- one timer ran out, and was declared dead while it was waiting its turn.
function Scanner:ArmBrowseTimeout()
    if self.browseTimeout then self.browseTimeout:Cancel() end

    self.browseTimeout = C_Timer.NewTimer(BROWSE_TIMEOUT, function()
        Scanner.browseTimeout = nil
        if not Scanner.isBrowsing then return end

        ns.Warn(L.Format("the page-by-page scan stopped answering after %ds, so keeping the %d page(s) read",
            BROWSE_TIMEOUT, Scanner.browsePages or 0))

        -- Finish it properly rather than just stopping: save what was read,
        -- hide the progress bar and give the Scan button back. Only setting
        -- the flags left the bar sitting at its last value for good.
        Scanner:CommitBrowseResults(Scanner:SweepSoFar())

        -- Blizzard's own list is waiting on the same results we are, so a
        -- query that never answered leaves its spinner turning.
        Scanner:SettleSearchDisplay("the page-by-page scan did not answer")
    end)
end

function Scanner:StopBrowseTimeout()
    if self.browseTimeout then
        self.browseTimeout:Cancel()
        self.browseTimeout = nil
    end
end

function Scanner:Report(...)
    if self.verbose then
        ns.Print(...)
    else
        ns.Debug(...)
    end
end

function Scanner:OnBrowseResults()
    if not self.isBrowsing then
        -- Somebody else's query filled the shared results -- the player's own
        -- search, most likely. There is nothing of ours to page or to finish,
        -- but the rows are real prices and reading them is free.
        local learned = self:CapturePassiveBrowse()
        pcall(self.SettleNameSearch, self)

        -- Or fast listing's one search for the whole Sell list.
        if ns.Posting and ns.Posting.OnCheckResults then
            pcall(ns.Posting.OnCheckResults, ns.Posting)
        end

        self:Report(("picked up %d price(s) from a search the addon did not start")
            :format(learned))
        return
    end

    local ok, results = pcall(C_AuctionHouse.GetBrowseResults)
    if not ok or type(results) ~= "table" then
        self:Report("the search results could not be read")
        return
    end

    -- A page arrived, so the wait for it is over. The next one is timed from
    -- when it is actually asked for, not from now.
    self:StopBrowseTimeout()

    self:Report(("page %d: %d row(s)"):format(self.browsePages + 1, #results))

    -- Browse results accumulate across the pages of one query, so a set that has
    -- shrunk is not our sweep any more: a different query -- the player's own
    -- search, most likely -- has taken the shared results over. Paced paging made
    -- a sweep long enough for that to be likely, so take the smaller set as the
    -- end of ours rather than paging through somebody else's search.
    --
    -- "What was read so far" is the last page of ours, kept below: by now the
    -- shared results hold the other search, and committing those kept its
    -- twenty rows and threw the sweep away. Likewise once anybody else's
    -- search has gone out, the next page cannot be trusted to be ours.
    if (self.browseRowsSeen and #results < self.browseRowsSeen) or self.browseForeign then
        self:Report("another search replaced the results; keeping what was read so far")
        self:CommitBrowseResults(self:SweepSoFar())
        return
    end

    self.browseRowsSeen = #results
    self.browseLast = results
    self.browsePages = self.browsePages + 1

    local full = true
    -- Whether the game said, in so many words, that this set is whole. Only
    -- that may mark unseen items sold out; assuming it (no function, or a
    -- call that failed) is fine for "stop paging" but not for clearing.
    local saidWhole = false
    if Util.HasFunction("C_AuctionHouse.HasFullBrowseResults") then
        local fullOk, hasFull = pcall(C_AuctionHouse.HasFullBrowseResults)
        full = (not fullOk) or hasFull
        saidWhole = fullOk and hasFull == true
    end

    if not full and self.browsePages < MAX_BROWSE_PAGES then
        -- Results accumulate, so simply ask for the next page.
        if ns.UI and ns.UI.SetScanProgress then
            ns.UI:SetScanProgress(math.min(0.95, self.browsePages / BROWSE_PAGES_FOR_BAR))
        end

        -- Paced like everything else. This used to fire the instant each page
        -- landed, which is a request per server reply for as long as the sweep
        -- ran -- the single largest drain on an allowance the player's own
        -- posting needs a share of.
        --
        -- A page can land while the last ask for one is still waiting its
        -- turn, when something else asked for more of the same results.
        -- Queued again under the same key, the waiting one was replaced and
        -- its give-up ran, which ended the sweep after that page. It is
        -- taken out quietly first instead.
        if ns.AHQueue.Cancel then ns.AHQueue:Cancel("browse-more", true) end

        ns.AHQueue:Request({
            name = "browse page",
            key = "browse-more",
            priority = ns.AHQueue.PRIORITY.scan,
            expires = 60,

            send = function()
                if not Scanner.isBrowsing then return true end
                if not pcall(C_AuctionHouse.RequestMoreBrowseResults) then return false end

                Scanner:ArmBrowseTimeout()
                return true
            end,

            onGiveUp = function()
                -- Commit what we have rather than abandon the sweep: a partial
                -- price update beats none, and it releases the shared results.
                if not Scanner.isBrowsing then return end

                -- Not when the auction house has just closed, though: the
                -- queue lets its waiting requests go before the scanner hears
                -- of the close, and this read a walk-away as a finished scan.
                -- The scanner's own close handler cancels the scan.
                if ns.AHQueue.IsFlushing and ns.AHQueue:IsFlushing() then return end

                Scanner:CommitBrowseResults(Scanner:SweepSoFar())
            end,
        })
        return
    end

    -- Only a sweep the game says is whole may mark missing items sold out.
    -- One stopped at the page cap has not looked everywhere, and results
    -- after anybody else's search went out may be that search's, not ours:
    -- the results slot is shared, and a first page cannot tell them apart.
    --
    -- Nor is one stopped at the cap a full scan at all. Stamped as one, it
    -- hid the deals on the pages it never reached (they looked older than
    -- the scan), so it is reported as stopped at the page limit instead.
    local capped = not full
    self:CommitBrowseResults(results, {
        ended = not capped,
        capped = capped,
        whole = full and saidWhole and not self.browseForeign,
    })
end

--- The rows of the last page this sweep accepted as its own.
function Scanner:SweepSoFar()
    if self.browseLast then return self.browseLast end
    local ok, partial = pcall(C_AuctionHouse.GetBrowseResults)
    return (ok and type(partial) == "table") and partial or {}
end

--- Read one browse row into a rival price and an own price.
--
-- A browse row is one price for the whole item, and its only clue about
-- ownership is containsOwnerItem, which means "you have at least one listing
-- of this item among these results". It does NOT mean the cheapest listing
-- is yours, and reading it that way is how a rival who had undercut you got
-- recorded as you: rivalMin went to nil, the Profit tab said you held the
-- lowest, and the listing sat.
--
-- So the flag is settled against your own auctions as last read back: the
-- row is yours only when you have this item listed at exactly that price.
-- Otherwise the price is a rival's, and your own price is whatever is known.
-- When your auctions have never been read the row counts as a rival's:
-- undercutting yourself by a silver costs less than never undercutting
-- anybody.
--
-- A row at your own price says nothing about rivals AT that price. Measured
-- 2026-09-20 on Heavy Woolen Gloves: we listed at 63s and 64s, and other
-- sellers sat at 63s and 64s too. The row reads 63s, yours, and only an
-- exact search can tell that tie from a lead. So a rival already on record
-- at or above your price is kept -- the row does not contradict it -- and
-- the third value asks the caller to settle the row with an exact search
-- when nothing is on record.
--
-- @return rivalMin, ownMin, unsettled
local function SplitBrowseRow(itemID, price, ownerFlag)
    if ownerFlag ~= true then return price, nil, false end

    local own = ns.Auctions and ns.Auctions.GetOwnMinPrice
        and ns.Auctions:GetOwnMinPrice(itemID) or nil
    local record = ns.Prices.Get and ns.Prices:Get(itemID) or nil

    if own and own == price then
        local rival = record and record.rivalMin
        if rival and rival >= price then return rival, price, false end
        return nil, price, true
    end

    return price, own or (record and record.ownMin) or nil, false
end

Scanner.SplitBrowseRow = SplitBrowseRow

--- Keep the price of each random suffix a combined browse row saw.
function Scanner.RecordRowSuffixes(item, now)
    if type(item.suffixes) ~= "table" or not (ns.Prices and ns.Prices.RecordSuffix) then return end
    for suffix, own in pairs(item.suffixes) do
        ns.Prices:RecordSuffix(item.itemID, suffix, own.price, own.price, own.rival, own.quantity, now)
    end
end

-- Gear that can carry a random suffix: weapons and armour (classes 2 and 4)
-- of green quality or better. Only these rows of a full scan are asked for
-- their link, so a scan of the whole auction house asks for few.
local SUFFIX_CLASSES = { [2] = true, [4] = true }

function Scanner.MayHaveSuffix(itemID, quality, memo)
    if type(quality) ~= "number" or quality < 2 then return false end
    if memo and memo[itemID] ~= nil then return memo[itemID] end

    local classID
    local api = _G.C_Item
    local instant = type(api) == "table" and api.GetItemInfoInstant or _G.GetItemInfoInstant
    if type(instant) == "function" then
        local ok, _, _, _, _, _, class = pcall(instant, itemID)
        if ok then classID = tonumber(class) end
    end

    local may = classID ~= nil and SUFFIX_CLASSES[classID] == true
    if memo then memo[itemID] = may end
    return may
end

--- The suffix of a full scan's row, or nil. Read inside a pcall.
function Scanner.ReplicateSuffix(index)
    if not Util.HasFunction("C_AuctionHouse.GetReplicateItemLink") then return nil end
    local ok, link = pcall(C_AuctionHouse.GetReplicateItemLink, index)
    if not ok or type(link) ~= "string" then return nil end
    return LinkSuffix(link)
end

--- Browse rows put together into one reading per item.
--
-- An item can come back as several rows, one per item key: gear with a
-- random suffix ("of the Bear", "of the Eagle") shares one itemID. Recorded a
-- row at a time, each row overwrote the one before, so the item kept
-- whichever row came last as its cheapest and its count, and was counted as
-- scanned once per row. Taken together, the cheapest row is the price and
-- the counts add up. Whose price each row is still goes through
-- SplitBrowseRow, row by row.
--
-- @param seen optional set, filled with every itemID a row names, priced or not
-- @return items in the order first seen, each { itemID, price, quantity,
--   rivalMin, ownMin, ask }, then the rows with no item or price, then the
--   rows priced past what anyone could pay
local function CombineBrowseRows(results, seen)
    local items, byItem = {}, {}
    local skipped, implausible = 0, 0

    for _, result in ipairs(results) do
        local itemID = result.itemKey and result.itemKey.itemID
        local price = result.minPrice

        if itemID and seen then seen[itemID] = true end

        if not (itemID and price and price > 0) then
            skipped = skipped + 1

        -- A browse row carries one price and nothing to fall back on, so a
        -- row priced past what anyone could pay is passed over whole
        -- rather than recorded as what the item is worth.
        elseif not ns.Prices.IsCredible(price) then
            implausible = implausible + 1

        else
            local rivalMin, ownMin, ask = SplitBrowseRow(itemID, price, result.containsOwnerItem)

            local item = byItem[itemID]
            if not item then
                item = { itemID = itemID, price = price, quantity = 0 }
                byItem[itemID] = item
                items[#items + 1] = item
            end

            item.price = math.min(item.price, price)
            item.quantity = item.quantity + (result.totalQuantity or 0)

            -- A row for one random suffix also keeps that suffix's own price
            -- (Prices:RecordSuffix), beside the item's.
            local suffix = tonumber(result.itemKey.itemSuffix) or 0
            if suffix ~= 0 then
                item.suffixes = item.suffixes or {}
                local own = item.suffixes[suffix]
                if not own then
                    own = { price = price, quantity = 0 }
                    item.suffixes[suffix] = own
                end
                own.price = math.min(own.price, price)
                own.quantity = own.quantity + (result.totalQuantity or 0)
                if rivalMin and (not own.rival or rivalMin < own.rival) then own.rival = rivalMin end
            end
            if rivalMin and (not item.rivalMin or rivalMin < item.rivalMin) then item.rivalMin = rivalMin end
            if ownMin and (not item.ownMin or ownMin < item.ownMin) then item.ownMin = ownMin end
            item.ask = item.ask or ask
        end
    end

    -- A row at your own price wants an exact search only while no rival is
    -- known. Another row of the item naming one settles it, the same way a
    -- rival already on record does in SplitBrowseRow.
    for _, item in ipairs(items) do
        item.ask = item.ask and item.rivalMin == nil
    end

    return items, skipped, implausible
end

--- @param opts.ended true when paging reached its natural end, so this was
---   a full scan rather than one cut short.
--- @param opts.capped true when paging stopped at the page limit, so the
---   end of the auction house was never reached.
--- @param opts.whole true when the sweep read the whole auction house, so an
---   item it did not see has sold out. Partial sweeps leave the rest alone.
---   Passing true is the same as both.
function Scanner:CommitBrowseResults(results, opts)
    if opts == true then opts = { ended = true, whole = true } end
    opts = opts or {}
    local complete = opts.whole == true

    self:StopBrowseTimeout()
    self.browseLast = nil

    self.isBrowsing = false
    self.isScanning = false

    local recorded = 0
    local now = time()
    local unsettled = {}
    local seen = {}

    local items, skipped, implausible = CombineBrowseRows(results, seen)

    for _, item in ipairs(items) do
        -- A browse row is one price, not a book, so market and minimum are
        -- the same figure here: the item's cheapest row.
        ns.Prices:Record(item.itemID, item.price, item.price, item.quantity, now,
            item.rivalMin, item.ownMin)
        Scanner.RecordRowSuffixes(item, now)

        if item.ask then unsettled[#unsettled + 1] = item.itemID end

        recorded = recorded + 1
    end

    if skipped > 0 then
        self:Report(("%d row(s) had no item or price"):format(skipped))
    end

    -- Plus anything Prices itself refused, so a price that got past the row
    -- filter and was stopped at the database is still reported rather than
    -- quietly dropped.
    implausible = implausible + ns.Prices:TakeImplausibleCount()

    if implausible > 0 then
        local ceiling = Util.FormatMoney(ns.Prices.MAX_CREDIBLE_COPPER, { noColor = true, short = true })
        if implausible == 1 then
            ns.Print(L.Format("%d listing ignored: priced above %s", implausible, ceiling))
        else
            ns.Print(L.Format("%d listings ignored: priced above %s", implausible, ceiling))
        end
    end

    self:FollowUpOwned(unsettled)

    local soldOut = 0
    if complete then
        local why
        soldOut, why = ns.Prices:ClearMissingIfWhole(seen, self.scanStartedWall, now)
        if why then self:Report(why .. ", so no item is marked sold out") end
    end

    self.verbose = false

    -- Only a scan that ran to its end counts as a full scan. A cut-short one
    -- stamped as full hid every deal it had not reached (they looked older
    -- than the scan) and put off the next automatic scan for two days.
    local elapsed = GetTime() - (self.scanStartedAt or GetTime())
    if opts.ended then
        ns.Prices:SetLastFullScan(now)
        ns.Print(L.Format("scan complete: %s items in %.1fs", Util.Comma(recorded), elapsed))
    elseif opts.capped then
        -- Remembered apart from the full scan stamp, so the automatic scan
        -- does not start the same capped sweep again on every visit.
        if ns.db and ns.Config.GetRealmKey then
            ns.db.lastCappedScanByRealm = ns.db.lastCappedScanByRealm or {}
            ns.db.lastCappedScanByRealm[ns.Config:GetRealmKey()] = now
        end
        ns.Print(L.Format("scan stopped at the %d page limit: %s items updated in %.1fs. Items on later pages were not reached, so this does not count as a full scan.",
            MAX_BROWSE_PAGES, Util.Comma(recorded), elapsed))
    else
        ns.Print(L.Format("scan stopped early: %s items updated in %.1fs", Util.Comma(recorded), elapsed))
    end
    if soldOut > 0 then
        ns.Print(L.Format("%s item(s) sold out since they were last seen", Util.Comma(soldOut)))
    end

    if ns.UI and ns.UI.OnScanComplete then
        ns.UI:OnScanComplete({ items = recorded, soldOut = soldOut })
    end

    -- Written out rather than held until logout, because this client loses
    -- saved variables and a crash would cost the scan. Deferred, though:
    -- serialising the database and writing several large CVars in the frame
    -- a scan completes puts that work right where the client is busiest.
    if ns.Persist then ns.Persist:SaveLater() end
end

function Scanner:REPLICATE_ITEM_LIST_UPDATE()
    -- Only an answer to our own request: another addon can ask too.
    if not self.awaitingReplicate or self.isReading then return end

    local ok, numItems = pcall(C_AuctionHouse.GetNumReplicateItems)
    local answered = ok and type(numItems) == "number" and numItems > 0

    -- A late answer, after the wait ran out and the page-by-page scan took
    -- over. It used to be thrown away, and the snapshot is the whole
    -- auction house where the browse is forty pages at most, so the browse
    -- is stopped and the snapshot read instead. Stopped first: running both
    -- would have the quick scan finishing end the other one halfway.
    local late = self.isBrowsing or self.browseQueued
    if late then
        if not answered then return end
        self:StopBrowse()
        ns.Print(L["the quick full scan answered after all, so reading it instead"])
    end

    if self.timeoutHandle then
        self.timeoutHandle:Cancel()
        self.timeoutHandle = nil
    end

    self.awaitingReplicate = false

    if not answered then
        ns.Print(L["the quick full scan came back empty, so scanning page by page instead"])
        self:StartBrowseScan()
        return
    end

    ns.db.lastReplicateAnswered = time()

    -- The page-by-page scan may already have finished, and the snapshot is
    -- still the fuller picture.
    self.isScanning = true

    self:ReadReplicateResults(numItems)
end

--- Stop a page-by-page sweep without saving it, for a quick scan that has
--- answered and will price everything it would have.
function Scanner:StopBrowse()
    self:StopBrowseTimeout()

    self.isBrowsing = false
    self.browseQueued = false
    self.browseLast = nil
    self.browseRowsSeen = nil

    if ns.AHQueue then
        ns.AHQueue:Cancel("browse", true)
        ns.AHQueue:Cancel("browse-more", true)
    end
end

--- Walk the snapshot, accumulating per-item listings.
--
-- source, optional, reads the rows from somewhere else in the same shape:
-- Era's older auction house (Data/LegacyScan.lua). Its fields: first (the
-- first index, 0 when not given), info(index) (GetReplicateItemInfo's
-- returns), link(index), partial (true when the rows may not be the whole
-- house, so nothing is marked sold out) and onFinish (called once, done or
-- cancelled).
function Scanner:ReadReplicateResults(numItems, source)
    self.isReading = true

    local readInfo = source and source.info or function(index)
        return C_AuctionHouse.GetReplicateItemInfo(index)
    end
    local readSuffix = source and source.link
        and function(index) return LinkSuffix(source.link(index)) end
        or Scanner.ReplicateSuffix
    local first = source and source.first or 0

    local observations = {}
    local skipped = 0
    local implausible = 0
    -- Every item with a live listing, priced or not, and the rows that could
    -- not be read at all. See the sold-out pass in onDone.
    local seen = {}
    local unreadable = 0
    -- Commodities read in this scan; see the one-off reset in onDone.
    local commodities = {}
    -- Each random suffix's listings, { [itemID] = { [suffix] = listings } },
    -- and which items can have one at all (Scanner.MayHaveSuffix).
    local suffixObservations = {}
    local suffixGear = {}

    -- GetReplicateItemInfo is 0-based.
    local indices = {}
    for i = 0, numItems - 1 do
        indices[i + 1] = i + first
    end

    local worker = Util.NewWorker({
        budgetMs = ns.Config:Get("scanBudgetMs") or 8,

        onItem = function(index)
            -- GetReplicateItemInfo returns, in order: name, texture, count,
            -- qualityID, usable, level, levelColHeader, minBid, minIncrement,
            -- buyoutPrice, bidAmount, highBidder, bidderFullName, owner,
            -- ownerFullName, saleStatus, itemID, hasAllInfo.
            local ok, _, _, count, quality, _, _, _, _, _, buyoutPrice,
                  _, _, _, owner, ownerFullName, saleStatus, itemID =
                      pcall(readInfo, index)

            if not ok or not itemID then
                unreadable = unreadable + 1
                skipped = skipped + 1
                return
            end

            -- saleStatus 1 means the auction already sold; it is not on offer.
            if saleStatus == 1 then
                skipped = skipped + 1
                return
            end

            -- On offer, so not sold out, even when it has no buyout to read.
            seen[itemID] = true

            if not buyoutPrice or buyoutPrice <= 0 then
                skipped = skipped + 1
                return
            end

            local quantity = count or 1

            -- Every row quotes its whole quantity, commodities included. They
            -- were read as priced per unit, and /bts verify in game on Linen
            -- Cloth (2026-09-29) settled it: a fresh search said 40c each, the
            -- quick scan had stored 83c, and the market was 16 times too high.
            -- A commodity row can hold more than a stack, so the stack-size
            -- guard item auctions use does not apply to it.
            --
            -- That includes a commodity nobody has told us is one yet, which
            -- is most reagents. No item auction holds more than a stack, so a
            -- row that does is a commodity's. Read as an item auction, the
            -- stack-size guard kept its whole price as the price of one, and
            -- Wool Cloth at 1s each was stored at 40s.
            local unitPrice
            if self:IsCommodity(itemID)
                or (quantity > 1 and quantity > (Util.GetMaxStackSize(itemID) or quantity)) then
                commodities[itemID] = true
                if quantity > 1 and buyoutPrice >= quantity then
                    unitPrice = math.floor(buyoutPrice / quantity + 0.5)
                else
                    unitPrice = buyoutPrice
                end
            else
                unitPrice = Util.UnitPriceFromStack(itemID, buyoutPrice, quantity)
            end

            -- A price nothing can pay is not a market observation, so it is
            -- dropped here rather than allowed to drag the item's mean up.
            -- Summarise's outlier pass cannot be relied on for this: it works
            -- off the cheapest quarter of the book, and an item whose only
            -- listing is a troll price has no cheap end to judge against.
            if unitPrice <= 0 then
                skipped = skipped + 1
                return
            end

            if not ns.Prices.IsCredible(unitPrice) then
                implausible = implausible + 1
                skipped = skipped + 1
                return
            end

            local listings = observations[itemID]
            if not listings then
                listings = {}
                observations[itemID] = listings
            end

            local listing = {
                unitPrice = unitPrice,
                quantity = quantity,
                isOwn = self:IsOwnAuction(owner, ownerFullName),
                -- Only counted, for the Stats tab's sellers (Data/StatsLog.lua).
                seller = type(owner) == "string" and owner or nil,
            }
            listings[#listings + 1] = listing

            -- The same listing under its random suffix too, when it has one.
            if not commodities[itemID] and Scanner.MayHaveSuffix(itemID, quality, suffixGear) then
                local suffix = readSuffix(index)
                if suffix then
                    local bySuffix = suffixObservations[itemID]
                    if not bySuffix then
                        bySuffix = {}
                        suffixObservations[itemID] = bySuffix
                    end
                    local own = bySuffix[suffix]
                    if not own then
                        own = {}
                        bySuffix[suffix] = own
                    end
                    own[#own + 1] = listing
                end
            end
        end,

        onProgress = function(fraction)
            if ns.UI and ns.UI.SetScanProgress then
                ns.UI:SetScanProgress(fraction)
            end
        end,

        onDone = function()
            local startedWall = self.scanStartedWall
            local now = time()

            -- Market value is an average carried from scan to scan, so the
            -- ones built from whole-row prices would take many scans to come
            -- down. Once, the first time this reading prices it, a commodity
            -- starts its market afresh from this scan. Its history is kept.
            --
            -- Marked on each price rather than once for the account: prices
            -- are kept per realm and faction, and one account-wide mark let
            -- only the first realm scanned start afresh. That old mark,
            -- commodityRowPriceFixed, is left in the saved data unread.
            local table_ = ns.Prices:GetTable()
            for itemID in pairs(commodities) do
                local record = table_ and table_[itemID]
                if record and observations[itemID] and not record.rowPriceFixed then
                    record.market = nil
                end
            end

            local recorded = ns.Prices:CommitScan(observations, now)

            -- Each random suffix beside its item, now the item has a price.
            if ns.Prices.CommitSuffixes then
                for itemID, bySuffix in pairs(suffixObservations) do
                    ns.Prices:CommitSuffixes(itemID, bySuffix, now)
                end
            end

            -- After the commit, so a commodity priced for the first time in
            -- this scan is marked too and never starts afresh later.
            for itemID in pairs(commodities) do
                local record = table_ and table_[itemID]
                if record and observations[itemID] then record.rowPriceFixed = true end
            end

            local elapsed = GetTime() - (self.scanStartedAt or GetTime())

            -- The snapshot is the whole auction house, so an item it did not
            -- list has sold out. A row that could not be read at all might be
            -- any item, though, so a snapshot with more than a handful of
            -- those does not get to decide. (Prices:ClearMissing also refuses
            -- to clear a large share of the book in one go.)
            local soldOut = 0
            if source and source.partial then
                self:Report("the scan may not have seen every page, so no item is marked sold out this time")
            elseif unreadable <= 5 then
                local why
                soldOut, why = ns.Prices:ClearMissingIfWhole(seen, startedWall, now)
                if why then self:Report(why .. ", so no item is marked sold out") end
            else
                self:Report(("%d row(s) could not be read, so no item is marked sold out this time"):format(unreadable))
            end

            self.isScanning = false
            self.isReading = false
            if source and source.onFinish then source.onFinish() end

            ns.Print(L.Format("scan complete: %s listings across %s items in %.1fs%s",
                Util.Comma(numItems - skipped), Util.Comma(recorded), elapsed,
                skipped > 0 and L.Format(" (%s skipped)", Util.Comma(skipped)) or ""))

            if soldOut > 0 then
                ns.Print(L.Format("%s item(s) sold out since they were last seen", Util.Comma(soldOut)))
            end

            implausible = implausible + ns.Prices:TakeImplausibleCount()

            if implausible > 0 then
                local ceiling = Util.FormatMoney(ns.Prices.MAX_CREDIBLE_COPPER, { noColor = true, short = true })
                if implausible == 1 then
                    ns.Print(L.Format("%s listing ignored: priced above %s", Util.Comma(implausible), ceiling))
                else
                    ns.Print(L.Format("%s listings ignored: priced above %s", Util.Comma(implausible), ceiling))
                end
            end

            if ns.UI and ns.UI.OnScanComplete then
                ns.UI:OnScanComplete({ items = recorded, soldOut = soldOut })
            end
        end,

        onCancel = function()
            self.isScanning = false
            self.isReading = false
            if source and source.onFinish then source.onFinish() end
            ns.Print(L["scan cancelled"])

            if ns.UI and ns.UI.OnScanComplete then
                ns.UI:OnScanComplete()
            end
        end,
    })

    self.worker = worker
    worker:Start(indices)

    ns.Print(L.Format("reading %s listings...", Util.Comma(numItems)))
end

function Scanner:CancelScan()
    if self.browseTimeout then
        self.browseTimeout:Cancel()
        self.browseTimeout = nil
    end

    if self.timeoutHandle then
        self.timeoutHandle:Cancel()
        self.timeoutHandle = nil
    end

    self.isBrowsing = false
    self.scanQueued = false
    self.browseQueued = false
    self.awaitingReplicate = false
    if ns.LegacyScan then ns.LegacyScan:Stop() end

    -- A cancelled sweep's last page must not stand in for the next sweep's
    -- rows, where it would be recorded as prices read just now.
    self.browseLast = nil

    self:ClearSearchState()

    -- Anything of ours still waiting for a turn is no longer wanted, and a
    -- request sent after the player cancelled spends their allowance for nothing.
    if ns.AHQueue then
        ns.AHQueue:Cancel("scan", true)
        ns.AHQueue:Cancel("browse", true)
        ns.AHQueue:Cancel("browse-more", true)
    end

    if self.worker and self.worker:IsRunning() then
        self.worker:Cancel()
    else
        self.isScanning = false
        self.isReading = false

        if ns.UI then ns.UI:OnScanComplete() end
    end
end

function Scanner:GetProgress()
    if self.worker and self.worker:IsRunning() then
        return self.worker:GetProgress()
    end
    return nil
end

--- What the scan is doing right now, read from the scanner's own state, for
--- the progress bar on the auction house bar.
--
-- Returns nil when no scan is running or waiting. Otherwise a table:
--   text      what to show beside the bar
--   fraction  0 to 1, or nil while there is nothing to measure yet
function Scanner:GetScanStatus()
    local legacy = ns.LegacyScan and ns.LegacyScan:Status()
    if legacy then return legacy end

    if self.isReading then
        local fraction = self:GetProgress() or 0
        return {
            text = L.Format("Reading listings %d%%", math.floor(fraction * 100)),
            fraction = fraction,
        }
    end

    if self.isBrowsing then
        local pages = self.browsePages or 0
        return {
            text = pages == 0 and L["Scanning page 1"]
                or L.Format("Scanning page %d (%d read)", pages + 1, pages),
            fraction = math.min(0.95, pages / BROWSE_PAGES_FOR_BAR),
        }
    end

    -- Before the quick-scan line: after the quick scan goes unanswered the
    -- scan is still "running" while the page-by-page one waits its turn,
    -- and the bar said it was asking for a quick scan all that time.
    if self.browseQueued then
        return { text = L["Waiting to start the page-by-page scan"] }
    end

    if self.isScanning then
        return { text = L["Asking for a quick scan"] }
    end

    if self.scanQueued then
        return { text = L["Waiting to start the scan"] }
    end

    return nil
end

--------------------------------------------------------------------------------
-- Targeted scan
--------------------------------------------------------------------------------

-- A full snapshot gives breadth but only shallow depth per item. Before acting
-- on a specific item it is worth asking for its real order book.

-- Rows of the addon's own browse scan that showed your price with nothing
-- on record about rivals. Looked up one at a time with an exact search, at
-- background priority, never over a search the player is waiting on.
local MAX_FOLLOW_UP = 8

function Scanner:FollowUpOwned(itemIDs)
    if not itemIDs or #itemIDs == 0 then return end

    self.followUp = {}
    for i = 1, math.min(#itemIDs, MAX_FOLLOW_UP) do
        self.followUp[i] = itemIDs[i]
    end

    self:NextFollowUp()
end

function Scanner:NextFollowUp()
    local list = self.followUp
    if not list or #list == 0 or not self.isAuctionHouseOpen then
        self.followUp = nil
        return
    end

    -- Somebody is waiting on a search. Come back rather than take the slot.
    if self.pendingItem then
        C_Timer.After(3, function() Scanner:NextFollowUp() end)
        return
    end

    local itemID = table.remove(list, 1)

    self:ScanItem(itemID, function(_, _, _, _, _, _, status)
        -- Pushed aside by a click: the slot is busy, so wait before the next.
        if status == "superseded" then
            C_Timer.After(3, function() Scanner:NextFollowUp() end)
        else
            Scanner:NextFollowUp()
        end
    end, { priority = ns.AHQueue and ns.AHQueue.PRIORITY.scan, quiet = true })
end

--- Search for one item's real order book.
--
-- @param opts  optional; `priority` overrides the urgent default, for a
--   follow-up nobody is waiting on. `itemKey` searches that exact key: the
--   one the auction house gives a copy in the bags, which for a random
--   suffix item ("Lead Band of the Wolf") names its suffix. Searched by item
--   ID alone, such an item's own listings never came back, and the post
--   price fell back to a market average across every suffix (kronosbest's
--   report, 2026-10-02: 80s asked with "of the Wolf" listed at 40s).
function Scanner:ScanItem(itemID, callback, opts)
    opts = opts or {}

    if not self.isAuctionHouseOpen then
        ns.Print(L["the auction house must be open"])
        return false
    end

    local itemKey = type(opts.itemKey) == "table" and opts.itemKey.itemID == itemID and opts.itemKey or nil
    if not itemKey then
        local keyOk, made = pcall(C_AuctionHouse.MakeItemKey, itemID)
        if not keyOk or not made then
            ns.Warn(L.Format("could not look up item %s", tostring(itemID)))
            return false
        end
        itemKey = made
    end

    -- Remembered per suffix, so a search for one suffix is never served as
    -- the checked price of another.
    local suffix = tonumber(itemKey.itemSuffix) or 0
    local recentKey = suffix ~= 0 and (itemID .. ":" .. suffix) or itemID

    -- Asking again about something we just looked at spends throttle budget
    -- for an answer that has not changed.
    self.recentItemScans = self.recentItemScans or {}

    local last = self.recentItemScans[recentKey]
    if last and (GetTime() - last) < 20 then
        -- Answered from a search made moments ago. That is still a checked
        -- price, not a check that failed to happen, and the caller is told
        -- which so it does not warn about a stale number that is not stale.
        if callback then callback(itemID, nil, nil, nil, nil, nil, "recent") end
        return true
    end

    -- A new search supersedes the old one, timer and all. Whoever was waiting
    -- on the old one is told so now: dropped silently, its five-second
    -- fallback fired and listed at a price nobody had checked.
    local superseded = self.pendingItem
    self:ClearSearchState()

    if superseded then
        -- Its answer will never be read, so it is not a recent check: asked
        -- about again within twenty seconds, it has to be searched again
        -- rather than served as "recent" at the old price.
        self.recentItemScans[superseded.recentKey or superseded.itemID] = nil

        if superseded.callback then
            superseded.callback(superseded.itemID, nil, nil, nil, nil, nil, "superseded")
        end
    end

    -- Kept by identity as well as in the shared slot. The queue tells a request
    -- it replaced to give up only after the replacement is already installed,
    -- so a give-up that looked at the shared slot was reading its successor:
    -- it cleared the new request, told the new caller its check had failed,
    -- and the new search then never went out. Two List clicks a second apart
    -- during a scan were enough to list at an unchecked price.
    -- quiet: a background follow-up nobody clicked for says nothing when it
    -- goes unanswered, since there is no price the player is waiting on.
    local mine = { itemID = itemID, itemKey = itemKey, recentKey = recentKey,
        callback = callback, quiet = opts.quiet }
    self.pendingItem = mine

    -- Urgent priority: this is only reached because the player clicked something
    -- and is waiting on the price, so it goes ahead of any background sweep, and
    -- it is the one kind of request allowed out while Blizzard's sell frame is
    -- open.
    Util.WhenAuctionReady(function()
        if Scanner.pendingItem ~= mine then return end

        Scanner.recentItemScans[recentKey] = GetTime()

        -- Cheapest first, as Blizzard's own search asks: with no order a
        -- deep listing could come back without its cheapest rows.
        local sorts = {}
        local order = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price
        if order ~= nil then sorts[1] = { sortOrder = order, reverseSort = false } end

        if not pcall(C_AuctionHouse.SendSearchQuery, itemKey, sorts, true) then
            local refused = Scanner.pendingItem
            Scanner.pendingItem = nil

            ns.Warn(L["the game refused the search"])

            -- Say so now rather than leaving the caller to time out. A button
            -- that sits doing nothing for five seconds before admitting the
            -- check never happened reads as a broken button.
            if refused and refused.callback then
                refused.callback(itemID, nil, nil, nil, nil, nil, "unavailable")
            end
            return
        end

        -- Search results are one slot of client state shared with Blizzard's own
        -- lists, and nothing fires when a request is dropped. Without this the
        -- pending search stayed here for the rest of the session, and whatever
        -- was waiting on that state kept waiting with it.
        Scanner.searchTimeout = C_Timer.NewTimer(SEARCH_TIMEOUT, function()
            Scanner.searchTimeout = nil

            -- A search its caller gave up on still gets its display settled:
            -- this timer is the only thing that does it when the auction house
            -- drops a query without a word.
            if Scanner.abandonedItem == mine then
                Scanner.abandonedItem = nil
                Scanner:SettleSearchDisplay("a search did not answer")
                return
            end

            local pending = Scanner.pendingItem
            if not pending or pending.itemID ~= itemID then return end

            Scanner.pendingItem = nil

            -- Ask again next time rather than serving this silence as a checked
            -- price for the next twenty seconds.
            Scanner.recentItemScans[recentKey] = nil

            if not pending.quiet then
                ns.Warn(L["the auction house did not answer that search; using the last known price."])
            end
            Scanner:SettleSearchDisplay("a search did not answer")

            if pending.callback then
                pending.callback(itemID, nil, nil, nil, nil, nil, "unavailable")
            end
        end)
    end, function()
        -- Never got a turn. Hand back what we already know rather than leaving
        -- the caller waiting forever. Only for this request, though: if a newer
        -- search has taken the slot, this one was already told "superseded"
        -- and the newer one is still waiting for its turn.
        if Scanner.pendingItem ~= mine then return end
        Scanner.pendingItem = nil

        if not mine.quiet and not (ns.AHQueue and ns.AHQueue.IsFlushing and ns.AHQueue:IsFlushing()) then
            ns.Warn(L["the auction house stayed busy; using the last known price."])
        end
        if mine.callback then
            mine.callback(itemID, nil, nil, nil, nil, nil, "unavailable")
        end
    end, {
        name = ("price check for %s"):format(Util.GetItemLabel(itemID)),
        key = "item-search",
        priority = opts.priority or ns.AHQueue.PRIORITY.urgent,
        expires = 6,
    })

    return true
end

--------------------------------------------------------------------------------
-- Passive capture
--------------------------------------------------------------------------------

-- Auction house results are one piece of shared client state, and the events
-- that announce them are not addressed to whoever asked. When the player types
-- into Blizzard's own search box, or clicks a row in its list, exactly the same
-- events fire and exactly the same getters answer -- so the prices they found
-- can be read straight out, for no request and no throttle budget at all.
--
-- The addon used to drop all of that on the floor, because the handlers began
-- by checking the results were its own. They still do; this is what happens
-- instead of the early return.
--
-- Two rules keep it safe:
--
--  * It never sends anything. Paging through somebody else's search is what
--    the old early returns were really guarding against, and passive capture
--    reads whatever has already arrived and stops there.
--  * It never records an empty answer. A targeted search of ours coming back
--    empty is information -- nothing is listed, so there is nobody to undercut
--    -- but an empty shared results set is just as likely to be a set that was
--    cleared for the next query. Clearing a real rival price on that guess is
--    how the addon would talk itself into listing far under value, so a
--    passive observation may only ever add a price, never remove one.
--    The one exception is a search by an item's own name whose whole answer
--    leaves it out (SettleNameSearch, below).

-- The same rows arrive several times over as a search fills in, and a browse
-- of the whole house repeats every item the player scrolls past. Recording a
-- price we already hold at the same figure only pushes the moving average
-- toward a number it is already at and fills the history with copies, so the
-- same price for the same item is ignored for this long.
local PASSIVE_REPEAT_SECONDS = 60

-- How many of the most recent captures `/bts learned` shows.
local PASSIVE_RECENT = 8

function Scanner:PassiveCaptureEnabled()
    return ns.Config:Get("learnFromSearches") ~= false
end

--- Record one price observed from a search the addon did not make.
--
-- Returns true only when the database actually changed, so callers can report
-- what happened rather than what was attempted.
function Scanner:RecordPassive(itemID, marketValue, minBuyout, quantity, rivalMin, ownMin, ignoredLow, ladder)
    if not itemID or not marketValue or marketValue <= 0 then return false end

    self.passiveSeen = self.passiveSeen or {}

    local now = GetTime()
    local seen = self.passiveSeen[itemID]

    if seen and seen.price == marketValue and (now - seen.at) < PASSIVE_REPEAT_SECONDS then
        return false
    end

    self.passiveSeen[itemID] = { at = now, price = marketValue }

    ns.Prices:Record(itemID, marketValue, minBuyout, quantity or 0, time(), rivalMin, ownMin, ignoredLow, ladder)

    self.passiveCount = (self.passiveCount or 0) + 1

    self.passiveItems = self.passiveItems or {}
    if not self.passiveItems[itemID] then
        self.passiveItems[itemID] = true
        self.passiveItemCount = (self.passiveItemCount or 0) + 1
    end

    self.passiveRecent = self.passiveRecent or {}
    table.insert(self.passiveRecent, 1, {
        itemID = itemID,
        price = minBuyout or marketValue,
        at = time(),
    })
    while #self.passiveRecent > PASSIVE_RECENT do
        table.remove(self.passiveRecent)
    end

    return true
end

--- Read the shared browse results after somebody else's query filled them.
function Scanner:CapturePassiveBrowse()
    if not self:PassiveCaptureEnabled() then return 0 end
    if not Util.HasFunction("C_AuctionHouse.GetBrowseResults") then return 0 end

    local ok, results = pcall(C_AuctionHouse.GetBrowseResults)
    if not ok or type(results) ~= "table" then return 0 end

    local learned = 0

    -- One price per item, not a book, so market and minimum are the same
    -- figure -- the same reading CommitBrowseResults makes of the same rows,
    -- ownership included and an item's rows taken together. A row priced
    -- past what anyone can pay is passed over for the same reason it is there.
    for _, item in ipairs((CombineBrowseRows(results))) do
        if self:RecordPassive(item.itemID, item.price, item.price, item.quantity,
            item.rivalMin, item.ownMin) then
            learned = learned + 1
        end
        Scanner.RecordRowSuffixes(item, time())
    end

    if learned > 0 and ns.Persist then ns.Persist:SaveLater() end

    return learned
end

--- Forget the last price passive capture read for an item, so the next
--- reading is recorded even at the same price: after a buy or an empty
--- search, the same price again is another listing, not a repeat.
function Scanner:ForgetPassive(itemID)
    if self.passiveSeen and itemID then self.passiveSeen[itemID] = nil end
end

--------------------------------------------------------------------------------
-- "No items found"
--------------------------------------------------------------------------------
--
-- A player found the Disenchanting tab still listing an item after searching
-- the auction house for it by name and getting "no items found". Passive
-- capture never records an empty answer (see above): an empty shared set is
-- as likely to be one cleared for the next query. A search by an item's own
-- name is different: when the whole answer to it is in and the item is not
-- in it, nobody is selling one, and that is recorded like a sold out item
-- (Prices:RecordEmpty), whoever typed it.
--
-- Which item a search names: the one the addon's own search buttons sent
-- (UI:SearchAuctionHouse calls ExpectSearch), else a row of the
-- Disenchanting tab with exactly that name. Any other query sent after it
-- owns the results, so it stops waiting (NameSearchSent).

-- Seconds a search by name may take to answer.
Scanner.NAME_SEARCH_WAIT = 10

--- The addon is about to search for this item by name.
function Scanner:ExpectSearch(itemID, name)
    if not itemID or type(name) ~= "string" or name == "" then return end
    self.expectedSearch = { itemID = itemID, text = name:lower() }
end

--- The item a search text names exactly, or nil.
function Scanner:ItemNamedBy(text)
    if type(text) ~= "string" or text == "" then return nil end
    local lower = text:lower()

    local expected = self.expectedSearch
    if expected and expected.text == lower then return expected.itemID end

    local shown = ns.Disenchant and ns.Disenchant.shownRows
    if type(shown) == "table" then
        for _, row in ipairs(shown) do
            if type(row.name) == "string" and row.name:lower() == lower then return row.itemID end
        end
    end
    return nil
end

--- A query went out (hooked, after the client's own). Only a plain browse by
--- an item's name, with no filter that could hide it, is waited on.
function Scanner:NameSearchSent(query)
    self.nameSearch = nil
    if self.isBrowsing or self.sendingOwnBrowse or type(query) ~= "table" then return end

    if (tonumber(query.minLevel) or 0) > 0 or (tonumber(query.maxLevel) or 0) > 0 then return end
    if type(query.itemClassFilters) == "table" and #query.itemClassFilters > 0 then return end

    local filters = type(Enum) == "table" and Enum.AuctionHouseFilter
    if type(query.filters) == "table" and type(filters) == "table" then
        for _, filter in ipairs(query.filters) do
            if filter == filters.UsableOnly or filter == filters.UpgradesOnly then return end
        end
    end

    local itemID = self:ItemNamedBy(query.searchString)
    self.expectedSearch = nil
    if itemID then self.nameSearch = { itemID = itemID, at = GetTime() } end
end

--- Browse results came in: does the search by name we wait on have its
--- whole answer, without the item? Then nobody is selling one.
-- @return true when the item was recorded as not listed
function Scanner:SettleNameSearch()
    local search = self.nameSearch
    if not search then return false end
    if GetTime() - search.at > self.NAME_SEARCH_WAIT then
        self.nameSearch = nil
        return false
    end

    local ok, results = pcall(C_AuctionHouse.GetBrowseResults)
    if not ok or type(results) ~= "table" then return false end

    for _, row in ipairs(results) do
        local key = type(row) == "table" and row.itemKey
        if type(key) == "table" and key.itemID == search.itemID then
            -- Listed: passive capture has just read its price.
            self.nameSearch = nil
            return false
        end
    end

    -- Only the client saying the answer is whole will do; more rows may
    -- still come (AUCTION_HOUSE_BROWSE_RESULTS_ADDED). A client without the
    -- call can only be believed when nothing at all came back.
    local whole
    if Util.HasFunction("C_AuctionHouse.HasFullBrowseResults") then
        local fullOk, full = pcall(C_AuctionHouse.HasFullBrowseResults)
        whole = fullOk and full == true
    else
        whole = #results == 0
    end
    if not whole then return false end

    self.nameSearch = nil
    ns.Prices:RecordEmpty(search.itemID)
    self:ForgetPassive(search.itemID)
    self:Report(("item %d is not listed: recorded as sold out"):format(search.itemID))

    if ns.Persist then ns.Persist:SaveLater() end
    if ns.UI and ns.UI.RefreshActiveTab then pcall(ns.UI.RefreshActiveTab, ns.UI) end
    return true
end

--- Record the order book of a search the player ran on a single item.
function Scanner:CapturePassiveListings(itemID, listings)
    if not self:PassiveCaptureEnabled() then return false end

    -- Empty is not recorded; see the rules above.
    if not listings or #listings == 0 then return false end

    local marketValue, minBuyout, quantity, rivalMin, ownMin, ignoredLow, ladder =
        ns.Prices:Summarise(listings, ns.Prices:GetScanValue(itemID, "market"))
    if not marketValue then return false end

    -- The player is looking at what they may buy: what the shopping list
    -- said before this is the estimate a purchase is held to.
    if ns.Prices.KeepBeforeLook then ns.Prices:KeepBeforeLook(itemID) end

    local learned = self:RecordPassive(itemID, marketValue, minBuyout, quantity, rivalMin, ownMin, ignoredLow, ladder)

    if learned and ns.Persist then ns.Persist:SaveLater() end

    return learned
end

--------------------------------------------------------------------------------
-- Shared search state
--------------------------------------------------------------------------------

-- Browse and search results are one set of client state, shared with Blizzard's
-- auction house frame. Whichever query was sent last owns it, so our price check
-- and Blizzard's sell-tab search overwrite each other -- and a query dropped by
-- the throttle leaves whatever was waiting on that state waiting for ever. Hence
-- both halves of this: never leave a request of ours pending, and when one does
-- go missing, settle the shared state on the way out.

--- Forget any search of ours that is in flight, timer included.
--- Drop a search whose caller has stopped waiting for it.
--
-- A price check gives up at five seconds and goes on with the last known
-- price, while the search itself may still answer up to three seconds later.
-- That late answer is not a check of the price the player was already shown,
-- so it is no longer this caller's: it is read like anybody else's results.
-- The search is also forgotten as a recent one, or the next click within
-- twenty seconds was told "recent" and treated as checked when it never was.
--
-- Matched by the caller's own callback, so a newer search for the same item
-- from somewhere else is left alone.
function Scanner:AbandonItemScan(callback)
    local pending = self.pendingItem
    if callback == nil or not pending or pending.callback ~= callback then return false end

    -- The timer is kept, with nobody waiting on it: it is what settles
    -- Blizzard's results panel if the auction house never answers. Cancelled
    -- here, the panel could sit on "searching" for the rest of the visit.
    self.pendingItem = nil
    self.abandonedItem = pending
    if self.recentItemScans then self.recentItemScans[pending.recentKey or pending.itemID] = nil end

    return true
end

function Scanner:ClearSearchState()
    if self.searchTimeout then
        self.searchTimeout:Cancel()
        self.searchTimeout = nil
    end

    self.pendingItem = nil
    self.abandonedItem = nil
end

--- What the player has typed into Blizzard's search box, if it can be read.
local function GetBlizzardSearchText()
    local frame = _G.AuctionHouseFrame
    if type(frame) ~= "table" then return nil end

    local bar = frame.SearchBar
    local box = type(bar) == "table" and bar.SearchBox

    if type(box) ~= "table" or type(box.GetText) ~= "function" then return nil end

    local ok, text = pcall(box.GetText, box)
    return ok and text or nil
end

--- Put the shared browse state back into a finished condition.
--
-- Blizzard's list shows its searching indicator for exactly as long as
-- HasFullBrowseResults reports false, and nothing else will ever set that true
-- if the query it was waiting on got dropped. So when the auction house is open
-- and that state is still unfinished after a request of ours went missing, send
-- one more query -- the player's own search text where it can be read -- so a
-- results event actually arrives and the indicator clears.
--
-- Once per visit to the auction house: this is a repair, and a repair that
-- retries is just the loop that caused the problem.
function Scanner:SettleSearchDisplay(reason)
    if not self.isAuctionHouseOpen then return false end
    if self.settledSearchDisplay then return false end

    -- A page-by-page scan waiting its turn shares the "browse" slot in the
    -- queue: this query would replace it, and the scan would never run. Its
    -- own queries settle the display anyway.
    if self.browseQueued or self.isBrowsing then return false end

    if not Util.HasFunction("C_AuctionHouse.HasFullBrowseResults") then return false end

    local ok, hasFull = pcall(C_AuctionHouse.HasFullBrowseResults)
    if not ok or hasFull then return false end

    self.settledSearchDisplay = true

    ns.Debug(("tidying the auction house search results: %s"):format(
        reason or "no reason"))

    -- No onSend, so isBrowsing stays false and OnBrowseResults treats what
    -- comes back as somebody else's results rather than a page of a sweep. That
    -- is the intent: this query exists to let the client finish a search it is
    -- stuck on, and it must not restart paging. Passive capture will read the
    -- rows it returns, which is a bonus and not the reason for sending it.
    self:QueueBrowseQuery(GetBlizzardSearchText() or "")

    return true
end

function Scanner:COMMODITY_SEARCH_RESULTS_UPDATED(_, itemID)
    if not itemID then return end

    local pending = self.pendingItem
    local ours = pending ~= nil and pending.itemID == itemID

    -- Your place in line, for an item you have up (MyAuctions, read only).
    if ns.MyAuctions and ns.MyAuctions.NoteCommodityPlaces then ns.MyAuctions:NoteCommodityPlaces(itemID) end

    -- Not ours, and not wanted: leave the results alone exactly as before.
    if not ours and not self:PassiveCaptureEnabled() then return end

    local listings, raw = {}, {}
    local ok, count = pcall(C_AuctionHouse.GetNumCommoditySearchResults, itemID)

    if ok and count then
        for i = 1, count do
            local infoOk, info = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, itemID, i)
            if infoOk and info and info.unitPrice then
                -- Priced past what anyone can pay, it is junk rather than a
                -- market observation, so it never reaches Summarise. It still
                -- goes into raw: `/bts listings` reports what the client said.
                if ns.Prices.IsCredible(info.unitPrice) then
                    local quantity = info.quantity or 1
                    local ownUnits = tonumber(info.numOwnerItems)

                    -- A price level holds everyone's units at that price. When
                    -- the client says how many of them are yours, only those
                    -- are yours: a level you share with a rival is still a
                    -- rival price, and calling it all yours had the next
                    -- listing undercut the level above instead.
                    if info.containsOwnerItem == true and ownUnits and ownUnits > 0
                        and ownUnits < quantity then
                        listings[#listings + 1] = {
                            unitPrice = info.unitPrice, quantity = ownUnits, isOwn = true,
                        }
                        listings[#listings + 1] = {
                            unitPrice = info.unitPrice, quantity = quantity - ownUnits, isOwn = false,
                        }
                    else
                        listings[#listings + 1] = {
                            unitPrice = info.unitPrice,
                            quantity = quantity,
                            isOwn = info.containsOwnerItem == true,
                        }
                    end
                end

                raw[#raw + 1] = {
                    quantity = info.quantity or 1,
                    unitPrice = info.unitPrice,
                    ownerFlag = info.containsOwnerItem,
                    ownUnits = info.numOwnerItems,
                }
            end
        end
    end

    -- Recorded here as well as on the item path. Without it `/bts listings`
    -- answered a commodity search with whatever item was searched before it,
    -- under that item's name.
    self.lastItemListings = { itemID = itemID, raw = raw, isCommodity = true }

    -- A book of unit-priced listings only ever comes back for a commodity.
    -- Read off the raw rows, not the priced book: whether an item is a
    -- commodity is true regardless of what anyone listed it for, and a book
    -- emptied by the credibility filter would otherwise unlearn it.
    if #raw > 0 then self:LearnCommodity(itemID, true) end

    if not ours then
        self:CapturePassiveListings(itemID, listings)
        return
    end

    self:FinishItemScan(itemID, listings, true)
end

function Scanner:ITEM_SEARCH_RESULTS_UPDATED(_, itemKey)
    local pending = self.pendingItem

    -- An event with no key at all can only be read as an answer to whatever we
    -- asked about last; one that carries a key speaks for itself.
    local ours = pending ~= nil
        and (type(itemKey) ~= "table" or itemKey.itemID == nil or itemKey.itemID == pending.itemID)

    -- Read the book with the key that describes it: ours when it is our search,
    -- the event's own otherwise. The getters take the key, not the item id, so
    -- without one there is nothing to read.
    local key = ours and pending.itemKey or itemKey
    if type(key) ~= "table" then return end

    local itemID = key.itemID or (ours and pending.itemID)
    if not itemID then return end

    -- Your place in line, for an item you have up (MyAuctions, read only).
    if key.itemID and ns.MyAuctions and ns.MyAuctions.NoteItemPlaces then ns.MyAuctions:NoteItemPlaces(key) end

    if not ours and not self:PassiveCaptureEnabled() then return end

    local listings = {}
    local raw = {}
    local bySuffix = {}

    local ok, count = pcall(C_AuctionHouse.GetNumItemSearchResults, key)

    if ok and count then
        for i = 1, count do
            local infoOk, info = pcall(C_AuctionHouse.GetItemSearchResultInfo, key, i)
            if infoOk and info and info.buyoutAmount and info.buyoutAmount > 0 then
                local quantity = info.quantity or 1
                local unitPrice = Util.UnitPriceFromStack(itemID, info.buyoutAmount, quantity)

                -- Kept as the client gave them, so `/bts listings` can show
                -- what was read rather than what was concluded from it.
                raw[#raw + 1] = {
                    buyoutAmount = info.buyoutAmount,
                    quantity = quantity,
                    maxStack = Util.GetMaxStackSize(itemID),
                    unitPrice = unitPrice,

                    -- Kept unnormalised, because nil and false mean different
                    -- things here: false is "the client says this is not
                    -- yours", nil is "the client never said". Pricing has to
                    -- collapse them, a diagnostic must not -- undercutting
                    -- your own listing by a silver every repost, and this
                    -- client not reporting ownership at all, look identical
                    -- from the chat frame and want opposite responses.
                    ownerFlag = info.containsOwnerItem,
                }

                -- Junk prices stay out of the book for the same reason as on
                -- the commodity path, and stay in raw for the same reason too.
                if ns.Prices.IsCredible(unitPrice) then
                    local listing = {
                        unitPrice = unitPrice,
                        quantity = quantity,
                        isOwn = info.containsOwnerItem == true,
                    }
                    listings[#listings + 1] = listing

                    -- Under its random suffix too: the key's own, or the
                    -- listing's link when the search was for every suffix.
                    local suffix = tonumber(key.itemSuffix) or 0
                    if suffix == 0 then suffix = LinkSuffix(info.itemLink) or 0 end
                    if suffix ~= 0 then
                        bySuffix[suffix] = bySuffix[suffix] or {}
                        table.insert(bySuffix[suffix], listing)
                    end
                end
            end
        end
    end

    self.lastItemListings = { itemID = itemID, raw = raw }

    -- A listing with a stack buyout is an item auction, so the item is not a
    -- commodity, and that is now known without ever holding one.
    if #raw > 0 then self:LearnCommodity(itemID, false) end

    if not ours then
        if self:CapturePassiveListings(itemID, listings) and next(bySuffix) and ns.Prices.CommitSuffixes then
            ns.Prices:CommitSuffixes(itemID, bySuffix, time())
        end
        return
    end

    self:FinishItemScan(itemID, listings, false)
    -- After the item's own price, so the suffixes have one to sit beside.
    if next(bySuffix) and ns.Prices.CommitSuffixes then ns.Prices:CommitSuffixes(itemID, bySuffix, time()) end
end

function Scanner:FinishItemScan(itemID, listings, isCommodity)
    local pending = self.pendingItem
    self.pendingItem = nil

    local marketValue, minBuyout, quantity, rivalMin, ownMin, ignoredLow, ladder =
        ns.Prices:Summarise(listings, ns.Prices:GetScanValue(itemID, "market"))

    -- As CapturePassiveListings: the estimate from before this look is kept.
    if ns.Prices.KeepBeforeLook then ns.Prices:KeepBeforeLook(itemID) end

    -- "fresh" and "empty" both mean the auction house answered. They are told
    -- apart because an empty answer is information -- there is nothing listed
    -- -- while no answer at all leaves us on old data.
    local status = "fresh"

    if marketValue then
        ns.Prices:Record(itemID, marketValue, minBuyout, quantity, nil, rivalMin, ownMin, ignoredLow, ladder)
    else
        -- The search came back with nothing in it. Recording that is the whole
        -- point of asking: it clears the rival price, so the next listing
        -- cannot undercut a seller who has already sold out or expired.
        status = "empty"
        ns.Prices:RecordEmpty(itemID)
    end

    -- A price just checked: fast listing lists it on the next click.
    if ns.Posting and ns.Posting.NoteChecked then
        pcall(ns.Posting.NoteChecked, ns.Posting, itemID, pending and pending.itemKey)
    end

    if pending and pending.callback then
        pending.callback(itemID, marketValue, minBuyout, quantity, isCommodity,
            listings, status)
    end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function Scanner:AUCTION_HOUSE_SHOW()
    self.isAuctionHouseOpen = true
    -- A new visit: purchases are held to what the list says from now on.
    if ns.Prices.ForgetBeforeLook then ns.Prices:ForgetBeforeLook() end
    self.settledSearchDisplay = false

    -- Give the auction house a moment to be ready for queries. Longer than it
    -- strictly needs, on purpose: the player often opens the house to post
    -- something, and a sweep starting underneath their first click is how their
    -- own listing ended up refused for going too fast.
    C_Timer.After(3, function() Scanner:ConsiderAutoScan() end)
end

--- Scan without being asked when there is nothing useful to work from.
--
-- The Forever beta can start a session with no saved data at all. Rather
-- than leave the addon looking broken until the player finds the Scan
-- button, rebuild the price database on the spot. A full sweep is one
-- request and a read loop, so this costs seconds, not minutes.
function Scanner:ConsiderAutoScan(attempt)
    if ns.Config:Get("autoScan") == false then return end
    if self.isScanning or self.scanQueued then return end

    -- Queueing behind the sell frame would also work, but then a scan nobody
    -- asked for sits in the queue until it expires. Come back later instead, and
    -- give up quietly if the player is selling the whole time.
    attempt = attempt or 1

    if ns.AHQueue:PlayerIsSelling() then
        if attempt > 4 then return end

        ns.Debug("waiting to scan: Blizzard's Sell tab is open")
        C_Timer.After(20, function() Scanner:ConsiderAutoScan(attempt + 1) end)
        return
    end

    local allowed = self:CanFullScan()
    if not allowed then return end

    local count = ns.Prices:Count()
    -- A sweep that stopped at the page limit is not a full scan, but it is
    -- as far as a sweep can get here, so repeating it at once gains nothing.
    local lastScan = ns.Prices:GetLastScan()

    local stale = not lastScan
        or (time() - lastScan) > (ns.Config:Get("staleAfterSeconds") or 172800)

    if count > 0 and not stale then return end

    ns.Print(count == 0
        and L["no price data, so scanning automatically"]
        or L["prices are out of date, so scanning automatically"])

    self:StartFullScan()
end

function Scanner:AUCTION_HOUSE_CLOSED()
    self.isAuctionHouseOpen = false
    self.settledSearchDisplay = false
    self:CancelScan()
end

function Scanner:OnEnable()
    -- Every browse search, whoever sends it. A search sent while a sweep is
    -- out means the next results may be that search's, so the sweep can no
    -- longer claim to have seen the whole auction house. hooksecurefunc
    -- watches without replacing, so Blizzard's own call is untouched.
    -- Favourites and item-key searches fill the same results slot (the Buy
    -- tab runs a favourites search by itself), so they count too.
    if type(hooksecurefunc) == "function" and type(C_AuctionHouse) == "table" then
        local function Foreign()
            if Scanner.isBrowsing and not Scanner.sendingOwnBrowse then
                Scanner.browseForeign = true
            end
        end
        -- Another addon asking for the quick full scan uses up the same
        -- fifteen minutes. Ours asked then would go unanswered and only
        -- give way to the page-by-page scan half a minute later, so the
        -- cooldown is stamped here and the next scan goes straight to pages.
        if type(C_AuctionHouse.ReplicateItems) == "function" then
            pcall(hooksecurefunc, C_AuctionHouse, "ReplicateItems", function()
                if Scanner.sendingOwnReplicate or not ns.db then return end
                ns.db.lastReplicateRequest = time()
                ns.db.lastReplicateAnswered = nil
                ns.db.lastReplicateByOther = true
            end)
        end

        for _, name in ipairs({ "SendBrowseQuery", "SearchForFavorites", "SearchForItemKeys" }) do
            if type(C_AuctionHouse[name]) == "function" then
                pcall(hooksecurefunc, C_AuctionHouse, name, function(query)
                    Foreign()
                    -- Whichever query went last owns the results, so only a
                    -- browse by name can be read as "not listed" (NameSearchSent).
                    pcall(Scanner.NameSearchSent, Scanner, name == "SendBrowseQuery" and query or nil)
                end)
            end
        end
    end

    ns.RegisterEvent(self, "AUCTION_HOUSE_SHOW", self.AUCTION_HOUSE_SHOW)
    ns.RegisterEvent(self, "AUCTION_HOUSE_CLOSED", self.AUCTION_HOUSE_CLOSED)
    ns.RegisterEvent(self, "REPLICATE_ITEM_LIST_UPDATE", self.REPLICATE_ITEM_LIST_UPDATE)

    -- Browse results arrive as either event depending on whether this is a
    -- fresh query or another page of one.
    ns.RegisterEvent(self, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", self.OnBrowseResults)
    ns.RegisterEvent(self, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", self.OnBrowseResults)
    ns.RegisterEvent(self, "COMMODITY_SEARCH_RESULTS_UPDATED", self.COMMODITY_SEARCH_RESULTS_UPDATED)
    ns.RegisterEvent(self, "ITEM_SEARCH_RESULTS_UPDATED", self.ITEM_SEARCH_RESULTS_UPDATED)

    -- What is and is not in the bags is only worth remembering until they
    -- change.
    ns.RegisterEvent(self, "BAG_UPDATE_DELAYED", self.ForgetNotHeld)
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

ns.RegisterCommand("scan", L["scan the auction house (open it first)"], function()
    ns.Scanner:StartFullScan()
end)

ns.RegisterCommand("cancel", L["stop the running scan"], function()
    ns.Scanner:CancelScan()
end)

-- What the addon knows about the quick full scan's cooldown, and what a
-- running scan is doing. The cooldown is the server's, so this can only say
-- when the addon last really sent the request and whether anything came back.
ns.RegisterCommand("scanstatus", L["show when the quick full scan was last used and what a scan is doing"], function()
    local S = ns.Scanner
    local sent = ns.db and ns.db.lastReplicateRequest
    local answered = ns.db and ns.db.lastReplicateAnswered

    if not sent then
        ns.Print("quick full scan: not used since this was recorded")
    else
        ns.Print(("quick full scan: last sent %s, %s"):format(
            Util.FormatAgeAgo(time() - sent),
            answered and answered >= sent and ("and it answered after %ds"):format(answered - sent)
                or "and it did not answer"))
    end

    local cooldown = S:GetSnapshotCooldown()
    ns.Print(cooldown and ("the addon will wait %s before asking again"):format(
            cooldown < 60 and "under a minute" or Util.FormatAge(cooldown))
        or "the addon will ask for it on the next scan")

    if S.isBrowsing or S.browseQueued then
        ns.Print(("page-by-page scan running: %d page(s) read, %s"):format(
            S.browsePages or 0,
            S.browseTimeout and "waiting for the next page to answer" or "waiting its turn to ask for the next page"))
    elseif S.scanQueued then
        ns.Print("quick full scan waiting its turn to be sent")
    elseif S.isScanning then
        ns.Print("a scan is running")
    else
        ns.Print("no scan running")
    end
end)

-- Forces the paged path, skipping the rate-limited snapshot entirely. Useful
-- when the snapshot is unavailable and for testing the fallback on its own.
ns.RegisterCommand("browse", L["scan page by page, skipping the quick full scan"], function()
    if not ns.Scanner.isAuctionHouseOpen then
        ns.Print(L["the auction house must be open"])
        return
    end

    ns.Scanner:CancelScan()
    ns.Scanner.scanStartedAt = GetTime()
    ns.Scanner.scanStartedWall = time()
    ns.Scanner.verbose = true
    ns.Scanner:StartBrowseScan()
end)

-- Proves, rather than assumes, that the bulk snapshot's prices are being read
-- with the right units: a targeted search is authoritative, so if the two
-- disagree the snapshot maths is wrong.
ns.RegisterCommand("listings", L["what the last price check found"], function()
    local last = ns.Scanner.lastItemListings

    if not last or not last.raw or #last.raw == 0 then
        ns.Print("no price check has come back yet. Click List on something first")
        return
    end

    ns.Print(("what the auction house said about %s"):format(Util.GetItemLabel(last.itemID)))

    for i = 1, math.min(#last.raw, 10) do
        local entry = last.raw[i]

        -- A quantity above the stack size is the misreport worth seeing: it is
        -- the total on offer, not this listing's stack, and dividing by it is
        -- what priced a Linen Bag at one copper.
        local suspect = entry.maxStack and entry.quantity > entry.maxStack

        ns.PrintRaw(("  %2d. buyout %s  qty %d  stacks to %s  -> %s each%s%s"):format(
            i,
            Util.FormatMoney(entry.buyoutAmount or entry.unitPrice, { noColor = true }),
            entry.quantity,
            entry.maxStack and tostring(entry.maxStack) or "unknown",
            Util.FormatMoney(entry.unitPrice, { noColor = true }),
            entry.ownerFlag == true and "  <-- yours" or "",
            suspect and "  <-- qty is not a stack size, so the price was not divided" or ""))
    end

    if #last.raw > 10 then
        ns.PrintRaw(("  ... and %d more"):format(#last.raw - 10))
    end

    -- Pricing skips your own listings when picking a rival to undercut, which
    -- only works if the client says which are yours. If it never says, every
    -- repost undercuts your own auction by a silver, and nothing on screen
    -- would look wrong. So report whether the answer was given, not just what
    -- it was.
    local mine, answered = 0, 0

    for i = 1, #last.raw do
        local flag = last.raw[i].ownerFlag
        if flag ~= nil then answered = answered + 1 end
        if flag == true then mine = mine + 1 end
    end

    if answered == 0 then
        ns.Warn(("the game did not say who owns any of those %d listing(s), "):format(#last.raw)
            .. "so your own auctions cannot be told apart from anyone else's.")
    else
        ns.PrintRaw(("  owner known for %d of %d; %d of them yours"):format(
            answered, #last.raw, mine))
    end
end)

ns.RegisterCommand("verify", L["<itemID>: compare the scanned price with a fresh search"], function(args)
    local itemID = tonumber(args:match("(%d+)"))
    if not itemID then
        ns.Print("usage: /bts verify <itemID>")
        return
    end

    local before = ns.Prices:Get(itemID)
    local snapshotMarket = before and before.market
    local snapshotMin = before and before.min

    ns.Print(("checking item %d against a fresh search..."):format(itemID))

    ns.Scanner:ScanItem(itemID, function(_, marketValue, minBuyout, quantity, isCommodity, _, status)
        -- Only an answered search can say nobody is selling it.
        if status == "recent" then
            ns.Print("that item was searched under 20 seconds ago; run this again shortly.")
            return
        elseif status == "superseded" or status == "unavailable" then
            ns.Warn("the search did not get an answer; try again in a moment.")
            return
        end

        if not marketValue then
            ns.Warn("nobody has that item listed right now")
            return
        end

        ns.PrintRaw(("  now:      market %s   min %s   qty %d   %s"):format(
            Util.FormatMoney(marketValue), Util.FormatMoney(minBuyout), quantity or 0,
            isCommodity and "commodity" or "item auction"))

        if snapshotMin then
            ns.PrintRaw(("  scanned:  market %s   min %s"):format(
                Util.FormatMoney(snapshotMarket), Util.FormatMoney(snapshotMin)))

            local ratio = minBuyout > 0 and (snapshotMin / minBuyout) or 0
            if ratio > 0.9 and ratio < 1.1 then
                ns.PrintRaw(("  |c%sthe two agree|r"):format(ns.COLORS.profit))
            else
                ns.PrintRaw(("  |c%sMISMATCH: the scanned price is %.2fx the price now|r"):format(
                    ns.COLORS.loss, ratio))
            end
        else
            ns.PrintRaw("  no scanned price yet; run /bts scan first to compare")
        end
    end)
end)

-- Reports the OUTCOME of passive capture, not that it is switched on: how many
-- prices this session actually took from searches the addon did not make, and
-- which items they were. A diagnostic that says "enabled" would have been true
-- the whole time the handlers were dropping every row on the floor.
ns.RegisterCommand("learned", L["prices picked up from your own auction house searches"], function()
    local Scanner = ns.Scanner

    if not Scanner:PassiveCaptureEnabled() then
        ns.Print("learning from your searches is turned off in Settings, under Advanced")
        return
    end

    local count = Scanner.passiveCount or 0

    if count == 0 then
        ns.Print("no prices learned from your searches yet this session")

        if not Scanner.isAuctionHouseOpen then
            ns.PrintRaw("  the auction house is closed; search for something with it open")
        else
            ns.PrintRaw("  type in the auction house search box and run this again")
        end
        return
    end

    ns.Print(("%s price update%s from %s item%s, learned from your own searches"):format(
        Util.Comma(count), count == 1 and "" or "s",
        Util.Comma(Scanner.passiveItemCount or 0),
        (Scanner.passiveItemCount or 0) == 1 and "" or "s"))

    for _, entry in ipairs(Scanner.passiveRecent or {}) do
        ns.PrintRaw(("  %s  %s  %s"):format(
            Util.GetItemLabel(entry.itemID),
            Util.FormatMoney(entry.price, { noColor = true }),
            Util.FormatAgeAgo(time() - entry.at)))
    end
end)
