-- Blackthornes Tradeskills -- Logic/MyAuctions.lua
-- The auction house drawer's Auctions view (a player asked, the owner
-- agreeing 2026-10-14, from a mockup): every auction you have up, the ones
-- someone has undercut first, each with a Cancel button.
--
-- What it reads is what Data/Auctions.lua already reads at the auction house
-- (QueryOwnedAuctions, GetOwnedAuctionInfo), kept for the session with each
-- auction's ID (`Auctions.live`). Other characters' auctions come from their
-- last reading (`Auctions:GetListings`), shown but never cancellable here.
--
-- Undercut means your price for one is above the cheapest listing that is not
-- yours (`Prices:GetScanValue(id, "rival")`), from a scan no older than
-- FRESH. An older scan says nothing rather than guess.
--
-- Cancelling: C_AuctionHouse.CancelAuction wants a real click for each
-- auction, so it is only ever called straight from a button's click, one
-- auction a click, never queued and never in a loop. Whether it went through
-- is read back from your auctions, as a listing is. A cancelled auction's
-- item comes back in the mail, and its deposit is not returned, so listing it
-- again costs a new one: each row says about how much.
--
-- Places in line (a player asked, the owner said build it from a mockup,
-- 2026-10-20): "Cheapest" is true but says nothing about the auctions at
-- your price listed before yours, which sell first. Every search that comes
-- back for an item you have up (yours, the player's own, Check Places) is
-- read once more for it (`NoteItemPlaces`, `NoteCommodityPlaces`): an item
-- auction learns how many others at its price and suffix come before it in
-- the list, a commodity how many units of others share its price. Kept for
-- the session only, shown while under FRESH old.

local _, ns = ...

local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local MyAuctions = ns.NewModule("MyAuctions")

local Util = ns.Util

-- How old a scan may be and still say whether you were undercut.
MyAuctions.FRESH = 3600

-- How long a cancel may go unseen before it is called a failure.
MyAuctions.CANCEL_WAIT = 6

-- Moves when something the list shows changed (a read, a cancel).
MyAuctions.version = 0

local function CharacterKey()
    return ns.Config and ns.Config.GetCharacterKey and ns.Config:GetCharacterKey() or nil
end

local function IsPlaying(who)
    if ns.Characters and ns.Characters.IsPlaying then
        local ok, playing = pcall(ns.Characters.IsPlaying, ns.Characters, who)
        if ok then return playing and true or false end
    end
    return who ~= nil and who == CharacterKey()
end

local function AuctionHouseOpen()
    return ns.Scanner ~= nil and ns.Scanner.isAuctionHouseOpen == true
end

--- What the scans say about one of your auctions.
-- @return state ("undercut", "cheapest", "overcut" or "unknown"), the cheapest
--         price not yours (nil when none), and how far under you it is (for
--         "overcut", the big stack's price)
--
-- A random suffix ("of the Monkey") is judged against its own suffix's
-- listings when the scans keep them: another suffix's cheaper copy is not
-- undercutting yours.
function MyAuctions:Judge(itemID, unit, link)
    local Prices = ns.Prices
    if not (Prices and itemID) then return "unknown" end

    local suffix = link and ns.Util and ns.Util.LinkSuffix and ns.Util.LinkSuffix(link)
    local record = suffix and Prices.GetTable and Prices:GetTable()[itemID]
    if suffix and type(record) == "table" and type(record.suffixes) == "table" and Prices.GetSuffixEntry then
        if not unit then return "unknown" end
        local entry = Prices:GetSuffixEntry(itemID, suffix)
        local seen = entry and tonumber(entry.seen)
        if not seen or time() - seen > self.FRESH then return "unknown" end
        local rival = tonumber(entry.rival)
        if not rival or rival <= 0 then return "cheapest", nil end
        if unit > rival then return "undercut", rival, unit - rival end
        return "cheapest", rival
    end

    local age = Prices.GetAge and Prices:GetAge(itemID)
    if not age or age > self.FRESH then return "unknown" end

    if not unit then return "unknown" end
    local rival = Prices:GetScanValue(itemID, "rival")
    if not rival or rival <= 0 then return "cheapest", rival end
    if unit > rival then
        -- Overcutting (2026-10-15): an auction posted just under the big
        -- stack is where it was meant to be, while the book still says so.
        local Profit = ns.Profit
        if Profit and Profit.Overcut then
            local ok, over, _, wall = pcall(Profit.Overcut, Profit, itemID, rival,
                ns.Config and ns.Config:Get("undercutCopper") or 1)
            if ok and over and wall and unit <= wall then return "overcut", rival, wall end
        end
        return "undercut", rival, unit - rival
    end
    return "cheapest", rival
end

--- Your other characters' listings as last read (never raises).
function MyAuctions:Listings()
    local Auctions = ns.Auctions
    if not (Auctions and Auctions.GetListings) then return {} end
    local ok, listings = pcall(Auctions.GetListings, Auctions)
    return ok and type(listings) == "table" and listings or {}
end

--- itemID -> the prices each of every auction of yours up, on any character.
function MyAuctions:OwnUnits(listings)
    local own = {}
    local function Note(itemID, unit)
        if itemID and type(unit) == "number" then
            own[itemID] = own[itemID] or {}
            own[itemID][#own[itemID] + 1] = unit
        end
    end
    for _, auction in ipairs((ns.Auctions and ns.Auctions.live) or {}) do Note(auction.itemID, auction.unit) end
    for _, listing in ipairs(listings or self:Listings()) do
        if not listing.ended then Note(listing.itemID, listing.unit) end
    end
    return own
end

--- Judge, but the scan's "not yours" leaves out only the character that
--- scanned: a cheaper auction of your own on another character is not
--- someone undercutting you.
function MyAuctions:JudgeOwn(itemID, unit, ownUnits, link)
    local state, rival, gap = self:Judge(itemID, unit, link)
    if state == "undercut" and rival and ownUnits then
        for _, own in ipairs(ownUnits[itemID] or {}) do
            if own < unit and math.abs(own - rival) <= 1 then return "cheapest", rival end
        end
    end
    return state, rival, gap
end

--- About what listing it again would cost: the client's own cancel cost when
--- it has one, else the deposit Tradeskills remembers for that item.
-- @return copper or nil, and whether it is only an estimate
function MyAuctions:Deposit(row)
    if not row then return nil end

    local AH = _G.C_AuctionHouse
    if row.auctionID and type(AH) == "table" and type(AH.GetCancelCost) == "function" then
        local ok, cost = pcall(AH.GetCancelCost, row.auctionID)
        cost = ok and tonumber(cost) or nil
        if cost and cost > 0 then return cost, false end
    end

    local record = ns.db and ns.db.deposits and ns.db.deposits[row.itemID]
    local deposit
    if ns.Posting and ns.Posting.DepositFromRecord then
        deposit = ns.Posting.DepositFromRecord(record, row.quantity or 1)
    elseif type(record) == "table" and tonumber(record.unit) then
        deposit = math.max(1, math.floor(record.unit * (row.quantity or 1) + 0.5))
    end
    if deposit then return deposit, true end
    return nil
end

--- A cancel that costs more in a new deposit than the gap it closes.
function MyAuctions:GapSmallerThanDeposit(row)
    if not (row and row.gap) then return false end
    local deposit = self:Deposit(row)
    return deposit ~= nil and row.gap * (row.quantity or 1) < deposit
end

--- Every auction to show, in the order the view draws them.
-- @return rows, and a summary { up, undercut, worth, alts, read }
function MyAuctions:Rows()
    local rows = {}
    local summary = { up = 0, undercut = 0, worth = 0, alts = 0, read = false }
    local Auctions = ns.Auctions
    if not Auctions then return rows, summary end

    local now = time()
    local cancelling = self.cancelling or {}

    local listings = self:Listings()
    local ownUnits = self:OwnUnits(listings)
    local function JudgeRow(row) return self:JudgeOwn(row.itemID, row.unit, ownUnits, row.link) end

    if Auctions.live then
        summary.read = true
        for _, auction in ipairs(Auctions.live) do
            local row = {}
            for k, v in pairs(auction) do row[k] = v end
            row.mine = true
            row.state, row.rival, row.gap = JudgeRow(row)
            row.cancelling = cancelling[row.auctionID] ~= nil
            self:AttachPlace(row, now)
            rows[#rows + 1] = row
            summary.up = summary.up + 1
            if row.state == "undercut" and not row.cancelling then summary.undercut = summary.undercut + 1 end
            summary.worth = summary.worth + (row.unit or 0) * (row.quantity or 1)
        end
    end

    -- Other characters, as last read: never this one, which is read live.
    for _, listing in ipairs(listings) do
        if not listing.ended and not IsPlaying(listing.who) then
            local row = {}
            for k, v in pairs(listing) do row[k] = v end
            row.alt = true
            row.state, row.rival, row.gap = JudgeRow(row)
            rows[#rows + 1] = row
            summary.alts = summary.alts + 1
        end
    end

    local order = { undercut = 1, cheapest = 2, overcut = 2, unknown = 3 }
    table.sort(rows, function(a, b)
        if (a.alt or false) ~= (b.alt or false) then return not a.alt end
        local oa, ob = order[a.state] or 9, order[b.state] or 9
        if oa ~= ob then return oa < ob end
        -- Cheapest, but others at that price sell first: those first.
        if (a.behind or false) ~= (b.behind or false) then return a.behind or false end
        -- Most money under first, then soonest to end.
        local ga = (a.gap or 0) * (a.quantity or 1)
        local gb = (b.gap or 0) * (b.quantity or 1)
        if ga ~= gb then return ga > gb end
        return (a.ends or math.huge) < (b.ends or math.huge)
    end)

    for _, row in ipairs(rows) do
        row.left = row.ends and math.max(0, row.ends - now) or nil
    end

    return rows, summary
end

local function IsLegacy()
    return ns.Auctions ~= nil and ns.Auctions.IsLegacy ~= nil and ns.Auctions.IsLegacy() == true
end

-- Era cancels with its own CancelAuction(index). If the game turns that
-- down, the Cancel buttons go for the rest of the session.
MyAuctions.LEGACY_MISSES = 2

--- Whether this client lets the Auctions view cancel at all. When not, its
--- Cancel buttons are not shown.
function MyAuctions:CanEverCancel()
    if IsLegacy() then
        return not self.legacyBlocked and type(_G.CancelAuction) == "function"
    end
    return Util.HasFunction("C_AuctionHouse.CancelAuction")
end

--- Whether Check Places can work on this client: Era's searches never
--- carry places, so there it is not shown.
function MyAuctions:CanEverCheckPlaces()
    return not IsLegacy()
end

--- Whether the player can cancel right now, and why not.
function MyAuctions:CanCancel(row)
    if not AuctionHouseOpen() then return false, L["the auction house must be open"] end
    if not self:CanEverCancel() then return false end
    if row and row.alt then return false, L["Log in on that character to cancel it."] end
    if row and not row.auctionID then return false, L["Scan your auctions again first."] end
    if row and (row.cancelling or (row.auctionID and self.cancelling and self.cancelling[row.auctionID])) then
        return false, L["Already cancelling that one."]
    end
    if ns.Scanner and ns.Scanner.isScanning then return false, L["wait for the scan to finish"] end
    if ns.Posting and ns.Posting.IsThrottled and ns.Posting:IsThrottled() then
        return false, L["the auction house is busy, try again in a moment"]
    end

    local AH = _G.C_AuctionHouse
    if row and type(AH) == "table" and type(AH.CanCancelAuction) == "function" then
        local ok, can = pcall(AH.CanCancelAuction, row.auctionID)
        if ok and can == false then return false, L["The auction house won't let you cancel that one."] end
    end
    return true
end

local function StillUp(auctionID)
    for _, auction in ipairs((ns.Auctions and ns.Auctions.live) or {}) do
        if auction.auctionID == auctionID then return auction end
    end
end

--- Cancel one auction. Call it only from a click: the game asks for one.
-- @return true, or false and why
function MyAuctions:Cancel(row)
    if type(row) ~= "table" then return false end

    -- Read again: the row may be from before the last read.
    local auction = row.auctionID and StillUp(row.auctionID)
    if row.mine and not auction then
        return false, L["That auction is gone already."]
    end

    local allowed, reason = self:CanCancel(row)
    if not allowed then return false, reason end

    local ok, err
    if auction and auction.legacy then
        -- Era: where it sits now, read again right before, since the list
        -- moves up after every cancel.
        local index = ns.Auctions.LegacyIndexOf(row.auctionID)
        if not index then return false, L["That auction is gone already."] end
        ok, err = pcall(_G.CancelAuction, index)
        if not ok then self.legacyBlocked = true end
    else
        ok, err = pcall(C_AuctionHouse.CancelAuction, row.auctionID)
    end
    if not ok then
        ns.Debug("cancel failed: " .. tostring(err))
        return false, L["The game would not cancel it."]
    end

    if ns.AHQueue and ns.AHQueue.NoteSend then ns.AHQueue:NoteSend() end
    self.cancelling = self.cancelling or {}
    self.cancelling[row.auctionID] = { at = GetTime(), itemID = row.itemID, quantity = row.quantity,
        legacy = auction and auction.legacy or nil }
    self.cancelCount = (self.cancelCount or 0) + 1
    self.version = self.version + 1

    -- Read back whether it went, as a listing is.
    if ns.Auctions and ns.Auctions.Refresh then
        C_Timer.After(0.5, function() ns.Auctions:Refresh({ force = true }) end)
    end
    return true
end

--- The undercut auction the foot button cancels next: the most money under.
function MyAuctions:NextUndercut(rows)
    rows = rows or self:Rows()
    local AH = _G.C_AuctionHouse
    for _, row in ipairs(rows) do
        if row.mine and row.state == "undercut" and not row.cancelling then
            -- One the game won't cancel would be picked on every click.
            local refused = false
            if row.auctionID and type(AH) == "table" and type(AH.CanCancelAuction) == "function" then
                local ok, can = pcall(AH.CanCancelAuction, row.auctionID)
                refused = ok and can == false
            end
            if not refused then return row end
        end
    end
end

--- Cancel the next undercut auction, from the foot button's click.
function MyAuctions:CancelNext()
    local row = self:NextUndercut()
    if not row then
        ns.Print(L["None of your auctions are undercut."])
        return false
    end
    local ok, reason = self:Cancel(row)
    if not ok and reason then ns.Print(reason) end
    return ok
end

--- A read of your auctions: settle what was being cancelled.
function MyAuctions:OnRead(live, final, sold)
    local cancelling = self.cancelling
    self.version = self.version + 1
    if not cancelling or next(cancelling) == nil then return end

    local up = {}
    for _, auction in ipairs(live or {}) do up[auction.auctionID] = true end

    local now = GetTime()
    for auctionID, pending in pairs(cancelling) do
        local label = Util.GetItemLabel(pending.itemID) or L["that item"]
        if sold and sold[auctionID] then
            cancelling[auctionID] = nil
            ns.Print(L.Format("%s sold before the cancel went through.", label))
        elseif not up[auctionID] then
            cancelling[auctionID] = nil
            self.cancelledCount = (self.cancelledCount or 0) + 1
            self.legacyMisses = 0
            ns.Print(L.Format("Cancelled %s. It comes back to you in the mail.", label))
        elseif final and now - pending.at >= self.CANCEL_WAIT then
            cancelling[auctionID] = nil
            ns.Print(L.Format("%s is still up. The cancel didn't go through.", label))
            -- On Era, two in a row that never went: the game is not letting
            -- this through, so the buttons go.
            if pending.legacy then
                self.legacyMisses = (self.legacyMisses or 0) + 1
                if self.legacyMisses >= self.LEGACY_MISSES then self.legacyBlocked = true end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Places in line
--------------------------------------------------------------------------------

-- auctionID -> { ahead, at }: other auctions at your price and suffix listed
-- before yours, as the last search showed them.
MyAuctions.places = {}

-- itemID -> { units = { [unit price] = others' units at it }, at }.
MyAuctions.more = {}

-- Prices this close count as the same price (unit prices of stacks round).
local SAME_PRICE = 1

local function LiveAuctions()
    return (ns.Auctions and ns.Auctions.live) or {}
end

--- Whether you have an auction of this item up, so a search for it is worth
--- reading again for places.
function MyAuctions:Wants(itemID)
    if not itemID then return false end
    for _, auction in ipairs(LiveAuctions()) do
        if auction.itemID == itemID then return true end
    end
    return false
end

local function SuffixOf(link)
    return (link and Util.LinkSuffix and Util.LinkSuffix(link)) or 0
end

--- Read an item search's rows, in the order the auction house lists them.
-- rows: { { auctionID, unit, own, suffix } }. Returns how many places moved.
function MyAuctions:NotePlaces(itemID, rows, at)
    if not (itemID and type(rows) == "table") then return 0 end
    at = at or time()

    local mine = {}
    for _, auction in ipairs(LiveAuctions()) do
        if auction.itemID == itemID and auction.auctionID then mine[auction.auctionID] = auction end
    end
    if next(mine) == nil then return 0 end

    local noted = 0
    for i, row in ipairs(rows) do
        local auction = row.auctionID and mine[row.auctionID]
        if auction and auction.unit then
            local suffix = SuffixOf(auction.link)
            local ahead = 0
            for j = 1, i - 1 do
                local other = rows[j]
                if not other.own and other.unit and math.abs(other.unit - auction.unit) <= SAME_PRICE
                    and (other.suffix or 0) == suffix then
                    ahead = ahead + 1
                end
            end
            self.places[row.auctionID] = { ahead = ahead, at = at }
            noted = noted + 1
        end
    end
    if noted > 0 then self.version = self.version + 1 end
    return noted
end

--- Read a commodity search's price levels.
-- levels: { { unit, quantity, ownUnits } }.
function MyAuctions:NoteMore(itemID, levels, at)
    if not (itemID and type(levels) == "table") then return false end
    local units = {}
    for _, level in ipairs(levels) do
        if level.unit and (level.ownUnits or 0) > 0 then
            units[level.unit] = math.max(0, (level.quantity or 0) - level.ownUnits)
        end
    end
    if next(units) == nil then return false end
    self.more[itemID] = { units = units, at = at or time() }
    self.version = self.version + 1
    return true
end

--- After an item search came back: read its rows for places (never raises).
function MyAuctions:NoteItemPlaces(key)
    if type(key) ~= "table" or not self:Wants(key.itemID) then return end
    local AH = _G.C_AuctionHouse
    local ok = pcall(function()
        local count = AH.GetNumItemSearchResults(key)
        if not count or count <= 0 then return end
        local keySuffix = tonumber(key.itemSuffix) or 0
        local rows = {}
        for i = 1, count do
            local info = AH.GetItemSearchResultInfo(key, i)
            if info and (tonumber(info.buyoutAmount) or 0) > 0 then
                local quantity = info.quantity or 1
                local suffix = keySuffix ~= 0 and keySuffix or SuffixOf(info.itemLink)
                rows[#rows + 1] = {
                    auctionID = info.auctionID,
                    unit = Util.UnitPriceFromStack(key.itemID, info.buyoutAmount, quantity),
                    own = info.containsOwnerItem == true,
                    suffix = suffix,
                }
            end
        end
        self:NotePlaces(key.itemID, rows)
    end)
    if not ok then ns.Debug("places: an item search could not be read") end
end

--- After a commodity search came back: read its levels (never raises).
function MyAuctions:NoteCommodityPlaces(itemID)
    if not self:Wants(itemID) then return end
    local AH = _G.C_AuctionHouse
    local ok = pcall(function()
        local count = AH.GetNumCommoditySearchResults(itemID)
        if not count or count <= 0 then return end
        local levels = {}
        for i = 1, count do
            local info = AH.GetCommoditySearchResultInfo(itemID, i)
            if info and info.unitPrice then
                levels[#levels + 1] = {
                    unit = info.unitPrice,
                    quantity = info.quantity or 1,
                    ownUnits = info.containsOwnerItem == true and (tonumber(info.numOwnerItems) or 0) or 0,
                }
            end
        end
        self:NoteMore(itemID, levels)
    end)
    if not ok then ns.Debug("places: a commodity search could not be read") end
end

--- Lay what the searches said on one of your rows: `ahead` (auctions
--- before it) or `more` (others' units at its price), with `placeAt`, and
--- `behind` when a cheapest auction has others selling first.
function MyAuctions:AttachPlace(row, now)
    now = now or time()
    local place = row.auctionID and self.places[row.auctionID]
    if place and now - place.at <= self.FRESH then
        row.ahead, row.placeAt = place.ahead, place.at
    else
        local more = row.itemID and self.more[row.itemID]
        if more and now - more.at <= self.FRESH and row.unit then
            for unit, others in pairs(more.units) do
                if math.abs(unit - row.unit) <= SAME_PRICE then
                    row.more, row.placeAt = others, more.at
                    break
                end
            end
        end
    end
    row.behind = row.state == "cheapest" and ((row.ahead or 0) > 0 or (row.more or 0) > 0) or nil
end

--- Whether Check Places can run now, and why not.
function MyAuctions:CanCheckPlaces()
    if not self:CanEverCheckPlaces() then return false end
    if not AuctionHouseOpen() then return false, L["the auction house must be open"] end
    if self.checking then return false end
    if ns.Scanner and ns.Scanner.isScanning then return false, L["wait for the scan to finish"] end
    if #LiveAuctions() == 0 then return false end
    return true
end

--- Check Places: search each item you have up, one at a time, in the
--- background. Each answer is read for places as it comes back.
function MyAuctions:CheckPlaces()
    local can, reason = self:CanCheckPlaces()
    if not can then
        if reason then ns.Print(reason) end
        return false
    end

    local list, seen = {}, {}
    for _, auction in ipairs(LiveAuctions()) do
        local suffix = auction.itemKey and tonumber(auction.itemKey.itemSuffix) or SuffixOf(auction.link)
        local id = auction.itemID and (auction.itemID .. ":" .. suffix)
        if id and not seen[id] then
            seen[id] = { itemID = auction.itemID, itemKey = auction.itemKey }
            list[#list + 1] = seen[id]
        elseif id and not seen[id].itemKey then
            -- One copy with the exact key is enough to search them all.
            seen[id].itemKey = auction.itemKey
        end
    end
    self.checking = list
    self.version = self.version + 1
    self:CheckNext()
    return true
end

function MyAuctions:CheckNext()
    local list = self.checking
    local Scanner = ns.Scanner
    if not list or #list == 0 or not (Scanner and Scanner.isAuctionHouseOpen) then
        self.checking = nil
        self.version = self.version + 1
        return
    end

    -- A search the player is waiting on goes first.
    if Scanner.pendingItem then
        C_Timer.After(3, function() MyAuctions:CheckNext() end)
        return
    end

    local item = table.remove(list, 1)
    local started = Scanner:ScanItem(item.itemID, function(_, _, _, _, _, _, status)
        if status == "superseded" then
            C_Timer.After(3, function() MyAuctions:CheckNext() end)
        else
            MyAuctions:CheckNext()
        end
    end, {
        itemKey = item.itemKey,
        priority = ns.AHQueue and ns.AHQueue.PRIORITY and ns.AHQueue.PRIORITY.scan,
        quiet = true,
    })
    if not started then self:CheckNext() end
end

--- The game said no to Era's CancelAuction from here.
function MyAuctions:OnBlocked(_, addon, func)
    if not IsLegacy() then return end
    if type(func) == "string" and func:find("CancelAuction", 1, true) then
        self.legacyBlocked = true
        self.version = self.version + 1
    end
end

function MyAuctions:OnEnable()
    ns.RegisterEvent(self, "ADDON_ACTION_BLOCKED", self.OnBlocked)
    ns.RegisterEvent(self, "ADDON_ACTION_FORBIDDEN", self.OnBlocked)
end

--- For /bts probe: which cancel calls this client has, and what happened.
function MyAuctions:ProbeText()
    local AH = _G.C_AuctionHouse
    local function Has(name) return type(AH) == "table" and type(AH[name]) == "function" end
    local parts = {
        Has("CancelAuction") and "cancel yes" or "cancel NO",
        type(_G.CancelAuction) == "function" and "era cancel yes" or "era cancel NO",
        self.legacyBlocked and "era cancel blocked" or "era cancel not blocked",
        Has("GetCancelCost") and "cancel cost yes" or "cancel cost NO",
        Has("CanCancelAuction") and "can cancel yes" or "can cancel NO",
    }
    parts[#parts + 1] = ("tried %d, went %d"):format(self.cancelCount or 0, self.cancelledCount or 0)
    return table.concat(parts, ", ")
end
