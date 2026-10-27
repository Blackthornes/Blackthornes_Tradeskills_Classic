-- Blackthornes Tradeskills -- Data/LegacyScan.lua
-- The Scan button the Classic Era way.
--
-- Era has the older auction house: no C_AuctionHouse, only QueryAuctionItems,
-- GetAuctionItemInfo, GetNumAuctionItems and AUCTION_ITEM_LIST_UPDATE. Like
-- Forever's Scan, it asks for the quick full scan (QueryAuctionItems with
-- getAll) when the game allows it, once every fifteen minutes, and reads the
-- house page by page when it does not. Either way the rows go through
-- Scanner:ReadReplicateResults, a few each frame, into the same prices, so
-- everything after the scan works as it does on Forever.
--
-- Scanner:StartFullScan hands over to this file only when the client has the
-- older auction house (Compat's auction.mode "legacy"), so Forever never uses it.

local _, ns = ...

local LegacyScan = ns.NewModule("LegacyScan")

local Util = ns.Util
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

-- The game's quick full scan is allowed once every fifteen minutes.
local FULL_COOLDOWN = 15 * 60
-- How long to wait for the quick full scan before reading page by page.
LegacyScan.FULL_WAIT = 30
-- The quick full scan's rows can come in more than one burst; read once they stop.
LegacyScan.FULL_SETTLE = 1.5
-- A page's rows are read a moment after it answers, so its item details are in.
LegacyScan.PAGE_SETTLE = 0.3
-- A page that has not answered in this long ends the scan, keeping what was read.
LegacyScan.PAGE_TIMEOUT = 15
-- How often to look whether the game takes the next query.
LegacyScan.POLL = 0.1
-- Rows on one page of the auction house.
LegacyScan.PER_PAGE = 50
-- A sweep that never ends on its own still stops here.
LegacyScan.MAX_PAGES = 5000

-- A price check before a listing reads at most this many pages of the item.
LegacyScan.ITEM_PAGES = 3
-- and stops asking for more after this long, inside the caller's own wait.
LegacyScan.ITEM_BUDGET = 3.5

LegacyScan.state = nil
LegacyScan.itemSearch = nil
LegacyScan.generation = 0

--- True on a client with the older auction house only.
function LegacyScan:Applies()
    local caps = ns.Compat and ns.Compat:Get() and ns.Compat:Get().auction
    return caps ~= nil and caps.mode == "legacy"
end

local function CanQuery()
    if type(CanSendAuctionQuery) ~= "function" then return true, false end
    local ok, canQuery, canQueryAll = pcall(CanSendAuctionQuery)
    if not ok then return false, false end
    return canQuery and true or false, canQueryAll and true or false
end

local function ItemIDFromLink(link)
    if type(link) ~= "string" then return nil end
    return tonumber(link:match("item:(%d+)"))
end

local function Scanner() return ns.Scanner end

function LegacyScan:Done()
    local scanner = Scanner()
    scanner.isScanning = false
    scanner.isReading = false
    self.state = nil
    if ns.UI and ns.UI.OnScanComplete then ns.UI:OnScanComplete() end
end

--- Run fn once the game takes a query, giving up after PAGE_TIMEOUT.
function LegacyScan:WhenCanQuery(fn, onGiveUp)
    local generation = self.generation
    local waited = 0
    local function Look()
        if generation ~= LegacyScan.generation then return end
        if CanQuery() then
            fn()
            return
        end
        waited = waited + LegacyScan.POLL
        if waited >= LegacyScan.PAGE_TIMEOUT then
            onGiveUp()
            return
        end
        C_Timer.After(LegacyScan.POLL, Look)
    end
    Look()
end

function LegacyScan:Start()
    local scanner = Scanner()
    self:Stop()

    scanner.scanStartedAt = GetTime()
    scanner.scanStartedWall = time()
    scanner.isScanning = true
    self.state = { kind = "starting" }

    -- The game says whether the quick full scan is free once it takes a query
    -- at all, so wait for that first.
    self:WhenCanQuery(function()
        local _, canQueryAll = CanQuery()
        if canQueryAll then
            LegacyScan:StartFull()
            return
        end

        local last = ns.db and ns.db.lastReplicateRequest or 0
        local cooldown = FULL_COOLDOWN - (time() - last)
        if cooldown > 0 and not (ns.db and ns.db.lastReplicateByOther) then
            ns.Print(L.Format("the quick full scan was last used %s and can be used again in %s, so scanning page by page instead",
                Util.FormatAgeAgo(FULL_COOLDOWN - cooldown),
                cooldown < 60 and L["under a minute"] or Util.FormatAge(cooldown)))
        else
            ns.Print(L["Another addon just did a full scan, so doing a page by page scan instead."])
        end
        LegacyScan:StartPages()
    end, function()
        ns.Warn(L["the auction house stayed busy; the scan was not sent."])
        LegacyScan:Done()
    end)

    return true
end

--------------------------------------------------------------------------------
-- The quick full scan
--------------------------------------------------------------------------------

function LegacyScan:StartFull()
    ns.Print(L["asking for a quick full scan..."])

    ns.db.lastReplicateRequest = time()
    ns.db.lastReplicateAnswered = nil
    ns.db.lastReplicateByOther = nil

    self.state = { kind = "full" }
    self.sendingOwn = true
    local sent = pcall(QueryAuctionItems, "", nil, nil, 0, false, nil, true, false, nil)
    self.sendingOwn = false

    if not sent then
        ns.Print(L["the game refused the quick full scan, so scanning page by page instead"])
        self:StartPages()
        return
    end

    local generation = self.generation
    self.state.timeout = C_Timer.NewTimer(self.FULL_WAIT, function()
        if generation ~= LegacyScan.generation then return end
        local state = LegacyScan.state
        if state and state.kind == "full" and not state.answered then
            ns.Print(L.Format("the quick full scan has not answered in %d seconds, so scanning page by page until it does",
                LegacyScan.FULL_WAIT))
            LegacyScan:StartPages()
        end
    end)
end

function LegacyScan:FullSettled()
    local ok, batch = pcall(GetNumAuctionItems, "list")
    batch = ok and tonumber(batch) or 0
    if batch <= 0 then
        ns.Print(L["the quick full scan came back empty, so scanning page by page instead"])
        self:StartPages()
        return
    end
    ns.db.lastReplicateAnswered = time()
    self:ReadList(batch)
end

--- Read the auction house list as it stands now, the quick full scan's answer.
function LegacyScan:ReadList(batch)
    local state = { kind = "reading" }
    self.state = state
    local scanner = Scanner()
    scanner.isScanning = true

    local source
    source = {
        first = 1,
        info = function(index)
            -- The player's own search replaced the list mid-read.
            if state.moved then return nil end
            local values = { GetAuctionItemInfo("list", index) }
            if not values[17] then
                values[17] = ItemIDFromLink(GetAuctionItemLink("list", index))
            end
            return unpack(values, 1, 18)
        end,
        link = function(index)
            if state.moved then return nil end
            return GetAuctionItemLink("list", index)
        end,
        onFinish = function()
            if LegacyScan.state == state then LegacyScan.state = nil end
        end,
    }
    state.source = source
    scanner:ReadReplicateResults(batch, source)
end

--------------------------------------------------------------------------------
-- Page by page
--------------------------------------------------------------------------------

function LegacyScan:StartPages()
    if self.state and self.state.timeout then self.state.timeout:Cancel() end
    self.generation = self.generation + 1

    Scanner().isScanning = true
    self.state = { kind = "pages", page = 0, read = 0, rows = {} }
    ns.Print(L["scanning the auction house page by page..."])
    self:SendPage()
end

function LegacyScan:SendPage()
    local state = self.state
    if not state or state.kind ~= "pages" then return end

    self:WhenCanQuery(function()
        if LegacyScan.state ~= state then return end
        state.awaiting = true
        state.retried = nil
        LegacyScan.sendingOwn = true
        local sent = pcall(QueryAuctionItems, "", nil, nil, state.page, false, nil, false, false, nil)
        LegacyScan.sendingOwn = false
        if not sent then
            state.awaiting = false
            ns.Warn(L["the game refused the page-by-page scan"])
            LegacyScan:FinishPages(true)
            return
        end
        LegacyScan:ArmPageTimeout()
    end, function()
        if LegacyScan.state ~= state then return end
        LegacyScan:PagesStalled()
    end)
end

function LegacyScan:ArmPageTimeout()
    local state = self.state
    if state.timeout then state.timeout:Cancel() end
    state.timeout = C_Timer.NewTimer(self.PAGE_TIMEOUT, function()
        if LegacyScan.state ~= state or not state.awaiting then return end
        LegacyScan:PagesStalled()
    end)
end

function LegacyScan:PagesStalled()
    local state = self.state
    ns.Warn(L.Format("the page-by-page scan stopped answering after %ds, so keeping the %d page(s) read",
        self.PAGE_TIMEOUT, state.read))
    self:FinishPages(true)
end

local function PackRow(index)
    local _, _, count, quality, _, _, _, _, _, buyout, _, _, _, owner, ownerFull, saleStatus, itemID =
        GetAuctionItemInfo("list", index)
    local link = GetAuctionItemLink("list", index)
    itemID = itemID or ItemIDFromLink(link)
    return { count, quality, buyout, owner, ownerFull, saleStatus, itemID, link }
end

function LegacyScan:ReadPage()
    local state = self.state
    if not state or state.kind ~= "pages" or not state.awaiting then return end

    local ok, batch, total = pcall(GetNumAuctionItems, "list")
    batch = ok and tonumber(batch) or 0
    total = ok and tonumber(total) or 0

    -- The quick full scan answered after all: the whole house is in the list.
    if batch > self.PER_PAGE then
        if state.timeout then state.timeout:Cancel() end
        ns.Print(L["the quick full scan answered after all, so reading it instead"])
        ns.db.lastReplicateAnswered = time()
        self:ReadList(batch)
        return
    end

    local rows = {}
    local missing = false
    for index = 1, batch do
        local readOk, row = pcall(PackRow, index)
        if readOk and row[7] then
            rows[#rows + 1] = row
        else
            missing = true
        end
    end

    -- Item details still on their way: look once more before moving on.
    if missing and not state.retried then
        state.retried = true
        C_Timer.After(self.PAGE_SETTLE * 2, function() LegacyScan:ReadPage() end)
        return
    end

    state.awaiting = false
    if state.timeout then state.timeout:Cancel(); state.timeout = nil end

    for _, row in ipairs(rows) do state.rows[#state.rows + 1] = row end
    state.read = state.read + 1
    state.pages = math.max(1, math.ceil(total / self.PER_PAGE))

    if state.page + 1 < state.pages and state.page + 1 < self.MAX_PAGES then
        state.page = state.page + 1
        self:SendPage()
    else
        self:FinishPages(false)
    end
end

function LegacyScan:FinishPages(partial)
    local state = self.state
    if not state or state.kind ~= "pages" then return end
    if state.timeout then state.timeout:Cancel() end
    self.generation = self.generation + 1

    local rows = state.rows
    if #rows == 0 then
        self:Done()
        return
    end

    local reading = { kind = "reading" }
    self.state = reading
    Scanner():ReadReplicateResults(#rows, {
        first = 1,
        partial = partial or state.foreign,
        info = function(index)
            local row = rows[index]
            if not row then return nil end
            return nil, nil, row[1], row[2], nil, nil, nil, nil, nil, row[3],
                nil, nil, nil, row[4], row[5], row[6], row[7], true
        end,
        link = function(index) return rows[index] and rows[index][8] end,
        onFinish = function()
            if LegacyScan.state == reading then LegacyScan.state = nil end
        end,
    })
end

--------------------------------------------------------------------------------
-- One item's price, before a listing
--------------------------------------------------------------------------------

local function ItemName(itemID)
    local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if type(info) ~= "function" then return nil end
    local ok, name = pcall(info, itemID)
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

--- Scanner:ScanItem the Era way: search the item by its exact name, read
--- its listings and settle through Scanner:FinishItemScan, so the price and
--- the callback are the same as on Forever.
function LegacyScan:ScanItem(itemID, callback, opts)
    local scanner = Scanner()
    opts = opts or {}

    if not scanner.isAuctionHouseOpen then
        ns.Print(L["the auction house must be open"])
        return false
    end
    -- A scan holds the list; the caller lists at the last known price.
    if self.state then return false end

    local name = ItemName(itemID)
    if not name then return false end

    -- Asked about moments ago: that is still a checked price.
    scanner.recentItemScans = scanner.recentItemScans or {}
    local last = scanner.recentItemScans[itemID]
    if last and (GetTime() - last) < 20 then
        if callback then callback(itemID, nil, nil, nil, nil, nil, "recent") end
        return true
    end

    local superseded = scanner.pendingItem
    scanner:ClearSearchState()
    self.itemSearch = nil
    if superseded then
        scanner.recentItemScans[superseded.recentKey or superseded.itemID] = nil
        if superseded.callback then
            superseded.callback(superseded.itemID, nil, nil, nil, nil, nil, "superseded")
        end
    end

    local mine = { itemID = itemID, recentKey = itemID, callback = callback, quiet = opts.quiet }
    scanner.pendingItem = mine

    local search = { mine = mine, name = name, page = 0, listings = {}, startedAt = GetTime() }
    self.itemSearch = search
    self:SendItemPage(search)
    return true
end

--- A search the player asked for (the AH buttons on the Gather, Sell and
--- other tabs), shown in the game's own Browse list. Sent once the game takes
--- a query, as the game's own Search button would be, and never mid-scan
--- (UI:SearchAuctionHouse checks). Not marked as ours, so a price check out
--- steps aside for it, as it does for the player's own Search.
-- @return true when it was sent
function LegacyScan:Browse(name, onGiveUp)
    if type(name) ~= "string" or name == "" or type(QueryAuctionItems) ~= "function" then
        return false
    end
    self:WhenCanQuery(function()
        local sent = pcall(QueryAuctionItems, name, nil, nil, 0, false, nil, false, false, nil)
        if not sent and onGiveUp then onGiveUp(true) end
    end, function()
        if onGiveUp then onGiveUp(false) end
    end)
    return true
end

-- Whether this search is still the one wanted.
function LegacyScan:ItemLive(search)
    return self.itemSearch == search and Scanner().pendingItem == search.mine
end

function LegacyScan:SendItemPage(search)
    self:WhenCanQuery(function()
        if not LegacyScan:ItemLive(search) then return end
        search.awaiting = true
        search.retried = nil
        LegacyScan.sendingOwn = true
        local sent = pcall(QueryAuctionItems, search.name, nil, nil, search.page, false, nil, false, true, nil)
        LegacyScan.sendingOwn = false
        if not sent then
            search.awaiting = false
            LegacyScan:FinishItem(search, true)
            return
        end
        Scanner().recentItemScans[search.mine.itemID] = GetTime()
    end, function()
        LegacyScan:FinishItem(search, true)
    end)
end

function LegacyScan:ReadItemPage(search)
    if not search.awaiting then return end
    if not self:ItemLive(search) then
        if self.itemSearch == search then self.itemSearch = nil end
        return
    end

    local itemID = search.mine.itemID
    local ok, batch, total = pcall(GetNumAuctionItems, "list")
    batch = ok and tonumber(batch) or 0
    total = ok and tonumber(total) or 0

    local rows, missing = {}, false
    for index = 1, batch do
        local readOk, row = pcall(PackRow, index)
        if readOk and row[7] then
            rows[#rows + 1] = row
        else
            missing = true
        end
    end

    -- Item details still on their way: look once more.
    if missing and not search.retried then
        search.retried = true
        C_Timer.After(self.PAGE_SETTLE * 2, function() LegacyScan:ReadItemPage(search) end)
        return
    end
    search.awaiting = false
    search.read = (search.read or 0) + 1

    local scanner = Scanner()
    for _, row in ipairs(rows) do
        local count, buyout = tonumber(row[1]) or 1, tonumber(row[3]) or 0
        if row[7] == itemID and buyout > 0 then
            local unitPrice = Util.UnitPriceFromStack(itemID, buyout, count)
            if ns.Prices.IsCredible(unitPrice) then
                search.listings[#search.listings + 1] = {
                    unitPrice = unitPrice,
                    quantity = count,
                    isOwn = scanner:IsOwnAuction(row[4], row[5]) == true,
                }
            end
        end
    end

    local pages = math.max(1, math.ceil(total / self.PER_PAGE))
    if search.page + 1 < pages and search.page + 1 < self.ITEM_PAGES
            and GetTime() - search.startedAt < self.ITEM_BUDGET then
        search.page = search.page + 1
        self:SendItemPage(search)
    else
        self:FinishItem(search)
    end
end

function LegacyScan:FinishItem(search, failed)
    if self.itemSearch == search then self.itemSearch = nil end
    local scanner = Scanner()
    local mine = search.mine
    if scanner.pendingItem ~= mine then return end

    -- Nothing read at all: no answer, never an empty house.
    if failed and not search.read then
        scanner.pendingItem = nil
        scanner.recentItemScans[mine.itemID] = nil
        if mine.callback then mine.callback(mine.itemID, nil, nil, nil, nil, nil, "unavailable") end
        return
    end

    scanner:FinishItemScan(mine.itemID, search.listings, false)
end

--------------------------------------------------------------------------------
-- Events and status
--------------------------------------------------------------------------------

function LegacyScan:AUCTION_ITEM_LIST_UPDATE()
    local search = self.itemSearch
    if search and search.awaiting and not search.settling then
        search.settling = true
        C_Timer.After(self.PAGE_SETTLE, function()
            search.settling = false
            LegacyScan:ReadItemPage(search)
        end)
    end

    local state = self.state
    if not state then return end

    if state.kind == "full" then
        state.answered = true
        if state.timeout then state.timeout:Cancel(); state.timeout = nil end
        if state.settle then state.settle:Cancel() end
        local generation = self.generation
        state.settle = C_Timer.NewTimer(self.FULL_SETTLE, function()
            if generation ~= LegacyScan.generation or LegacyScan.state ~= state then return end
            LegacyScan:FullSettled()
        end)
    elseif state.kind == "pages" and state.awaiting and not state.settling then
        state.settling = true
        C_Timer.After(self.PAGE_SETTLE, function()
            state.settling = false
            if LegacyScan.state == state then LegacyScan:ReadPage() end
        end)
    end
end

--- Someone else's search (the player's, or another addon's).
function LegacyScan:OnQuery(getAll)
    if self.sendingOwn then return end

    if getAll and ns.db then
        ns.db.lastReplicateRequest = time()
        ns.db.lastReplicateAnswered = nil
        ns.db.lastReplicateByOther = true
    end

    -- A price check out: the answer coming is that search's, not ours.
    local search = self.itemSearch
    if search and search.awaiting then
        self.itemSearch = nil
        local scanner = Scanner()
        local mine = search.mine
        if scanner.pendingItem == mine then
            scanner.pendingItem = nil
            if scanner.recentItemScans then scanner.recentItemScans[mine.itemID] = nil end
            if mine.callback then mine.callback(mine.itemID, nil, nil, nil, nil, nil, "superseded") end
        end
    end

    local state = self.state
    if not state then return end
    if state.kind == "reading" then
        -- The list being read is replaced, so the rest of it is not ours.
        state.moved = true
        if state.source then state.source.partial = true end
    elseif state.kind == "pages" then
        state.foreign = true
        if state.awaiting then
            -- The answer coming is that search's, so ask for this page again.
            state.awaiting = false
            local generation = self.generation
            C_Timer.After(self.PAGE_SETTLE, function()
                if generation == LegacyScan.generation and LegacyScan.state == state then
                    LegacyScan:SendPage()
                end
            end)
        end
    end
end

--- What the scan is doing, for the bar; nil while Scanner's own reading says it.
function LegacyScan:Status()
    local state = self.state
    if not state or state.kind == "reading" then return nil end

    if state.kind == "pages" then
        local read = state.read or 0
        return {
            text = read == 0 and L["Scanning page 1"]
                or L.Format("Scanning page %d (%d read)", read + 1, read),
            fraction = state.pages and math.min(0.95, read / state.pages) or nil,
        }
    end

    return { text = L["Asking for a quick scan"] }
end

function LegacyScan:Stop()
    self.generation = self.generation + 1
    self.itemSearch = nil
    local state = self.state
    if state then
        if state.timeout then state.timeout:Cancel() end
        if state.settle then state.settle:Cancel() end
    end
    self.state = nil
end

function LegacyScan:OnEnable()
    if not self:Applies() then return end

    if type(hooksecurefunc) == "function" and type(QueryAuctionItems) == "function" then
        pcall(hooksecurefunc, "QueryAuctionItems", function(_, _, _, _, _, _, getAll)
            pcall(LegacyScan.OnQuery, LegacyScan, getAll and true or false)
        end)
    end

    ns.RegisterEvent(self, "AUCTION_ITEM_LIST_UPDATE", self.AUCTION_ITEM_LIST_UPDATE)
end
