-- Blackthornes Tradeskills -- Logic/LegacyBuy.lua
-- Buying what the queue needs on Era's older auction house.
--
-- Forever sells materials from one pool: ask for 45 and the game takes the
-- cheapest 45. Era sells whole stacks, each from its own seller at its own
-- price, so 45 Linen Cloth might be a stack of 20, another of 20 and one of
-- 10. This reads every stack of one item, works out the cheapest mix that
-- covers what is needed (the owner, 2026-10-27: at most a quarter extra,
-- and stacks over half again the usual price left out), and buys one stack
-- a click, since the game takes a real click for every buyout.
--
-- Only on a client with the older auction house (LegacyScan:Applies), so
-- Forever never uses it. Nothing touches a Blizzard frame. Buys are counted
-- by AHBuys's PlaceAuctionBid watch, as a buy made in the game's own list is.

local _, ns = ...

local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local LegacyBuy = ns.NewModule("LegacyBuy")

local Util = ns.Util

-- At most this much over the need (a quarter: need 40, buy at most 50).
LegacyBuy.EXTRA = 0.25
-- Stacks over this times the usual price for one are left out.
LegacyBuy.TOO_DEAR = 1.5
-- Pages of one item read at most.
LegacyBuy.MAX_PAGES = 10
-- The DP never looks past this many units, whatever the need.
LegacyBuy.MAX_UNITS = 5000
-- A buy whose gold has not left by now did not go through.
LegacyBuy.BUY_WAIT = 4
-- A page that has not answered in this long gives up.
LegacyBuy.PAGE_WAIT = 10
-- A buy whose gold leaves after BUY_WAIT still counts up to this long after.
LegacyBuy.LATE_WAIT = 30
-- How often to look whether the auction house takes our next search.
LegacyBuy.POLL = 0.2

LegacyBuy.state = nil

function LegacyBuy:Applies()
    return ns.LegacyScan ~= nil and ns.LegacyScan:Applies()
end

--------------------------------------------------------------------------------
-- The plan
--------------------------------------------------------------------------------

--- The cheapest stacks that cover a need.
-- @param listings { { count, buyout, own } }; own stacks are never picked
-- @param need units wanted now
-- @param most the most units the plan may come to (need plus the extra)
-- @param usual copper for one, or nil: stacks over TOO_DEAR times it are left out
-- @return { stacks (cheapest each first), units, total, extra, short, skipped }
function LegacyBuy.Plan(listings, need, most, usual)
    need = math.max(0, math.floor(tonumber(need) or 0))
    most = math.max(need, math.floor(tonumber(most) or need))
    local plan = { stacks = {}, units = 0, total = 0, extra = 0, short = 0, skipped = false }
    if need <= 0 then return plan end

    local pool, available, biggest = {}, 0, 0
    for _, listing in ipairs(listings or {}) do
        local count, buyout = tonumber(listing.count), tonumber(listing.buyout)
        if count and count > 0 and buyout and buyout > 0 and not listing.own then
            if usual and usual > 0 and buyout / count > usual * LegacyBuy.TOO_DEAR then
                plan.skipped = true
            else
                pool[#pool + 1] = listing
                available = available + count
                biggest = math.max(biggest, count)
            end
        end
    end

    local function Finish(picked)
        table.sort(picked, function(a, b)
            local ua, ub = a.buyout / a.count, b.buyout / b.count
            if ua ~= ub then return ua < ub end
            return a.count > b.count
        end)
        for _, listing in ipairs(picked) do
            plan.stacks[#plan.stacks + 1] = listing
            plan.units = plan.units + listing.count
            plan.total = plan.total + listing.buyout
        end
        plan.extra = math.max(0, plan.units - need)
        plan.short = math.max(0, need - plan.units)
        return plan
    end

    -- Not enough for sale: every stack there is.
    if available <= need then return Finish(pool) end

    -- Least cost to make exactly u units, each stack at most once. Any mix
    -- with the least extra over the need stays under need + biggest, so the
    -- table never needs to go further than that or the quarter, whichever
    -- is more.
    local limit = math.min(math.max(most, need + biggest - 1), LegacyBuy.MAX_UNITS)
    local cost, stacks = { [0] = 0 }, { [0] = 0 }
    local took = {}
    for i, listing in ipairs(pool) do
        local count, buyout = listing.count, listing.buyout
        local row = {}
        for u = limit, count, -1 do
            local before = cost[u - count]
            if before then
                local try, used = before + buyout, stacks[u - count] + 1
                local now = cost[u]
                if not now or try < now or (try == now and used < stacks[u]) then
                    cost[u], stacks[u] = try, used
                    row[u] = true
                end
            end
        end
        took[i] = row
    end

    local function Better(u, best)
        if not cost[u] then return false end
        if not best then return true end
        if cost[u] ~= cost[best] then return cost[u] < cost[best] end
        return stacks[u] < stacks[best]
    end

    -- The cheapest inside the quarter, else the least extra there is.
    local best
    for u = need, math.min(most, limit) do
        if Better(u, best) then best = u end
    end
    if not best then
        for u = need, limit do
            if cost[u] then best = u; break end
        end
    end
    -- The table stopped short of every mix (a need past MAX_UNITS): all of it.
    if not best then return Finish(pool) end

    local picked, u = {}, best
    for i = #pool, 1, -1 do
        if u <= 0 then break end
        if took[i][u] then
            picked[#picked + 1] = pool[i]
            u = u - pool[i].count
        end
    end
    return Finish(picked)
end

--------------------------------------------------------------------------------
-- Reading the stacks
--------------------------------------------------------------------------------

local function ItemName(itemID)
    local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if type(info) ~= "function" then return nil end
    local ok, name = pcall(info, itemID)
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

local function ItemIDFromLink(link)
    if type(link) ~= "string" then return nil end
    return tonumber(link:match("item:(%d+)"))
end

local function ReadRow(index)
    local _, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, ownerFull, _, itemID =
        GetAuctionItemInfo("list", index)
    if not itemID then
        local ok, link = pcall(GetAuctionItemLink, "list", index)
        itemID = ok and ItemIDFromLink(link) or nil
    end
    return { count = tonumber(count) or 0, buyout = tonumber(buyout) or 0,
        owner = owner, ownerFull = ownerFull, itemID = itemID, index = index }
end

-- Era fills in a seller's name a moment after the row, so a name missing on
-- either side is no mismatch.
local function Same(a, b)
    return a and b and a.itemID == b.itemID and a.count == b.count
        and a.buyout == b.buyout
        and (a.owner == nil or b.owner == nil or a.owner == b.owner)
end

--- What the item's usual price for one is, from the scans.
function LegacyBuy:Usual(itemID)
    if not (ns.Prices and ns.Prices.GetValue) then return nil end
    local ok, value = pcall(ns.Prices.GetValue, ns.Prices, itemID, "market")
    value = ok and tonumber(value) or nil
    return value and value > 0 and value or nil
end

local function Changed()
    if ns.PostPanel and ns.PostPanel.OnLegacyBuy then pcall(ns.PostPanel.OnLegacyBuy, ns.PostPanel) end
    local tab = ns.DisenchantingTab
    if tab and tab.OnLegacyBuy then pcall(tab.OnLegacyBuy, tab) end
end

--- Start on an item: read every stack, then work out the plan.
-- @param opts optional: maxEach (copper for one: dearer stacks are left
--   out), source ("disenchant" for the Disenchanting tab's Buy button) and
--   more (after each buy, plan one more, so it keeps going while stacks
--   under maxEach are left)
-- @return true when the plan is on its way
function LegacyBuy:Open(itemID, need, opts)
    if not self:Applies() then return false end
    itemID, need = tonumber(itemID), tonumber(need)
    if not itemID or not need or need <= 0 then return false end
    local scanner = ns.Scanner
    if scanner and not scanner.isAuctionHouseOpen then return false end
    if ns.LegacyScan.state then return false end
    local name = ItemName(itemID)
    if not name then return false end

    self:Close(true)
    self.state = {
        itemID = itemID, name = name, need = need, bought = 0,
        most = need + math.floor(need * self.EXTRA),
        status = "reading", page = 0, listings = {},
        maxEach = opts and tonumber(opts.maxEach) or nil,
        source = opts and opts.source or nil,
        more = opts and opts.more and true or nil,
        -- Gear with a random suffix is listed as "Northern Shortsword of
        -- Strength", which a search for the exact name never finds. The
        -- Disenchanting tab searches by name alone; rows are kept by item ID.
        exact = not (opts and opts.source == "disenchant"),
    }
    self:SendPage(self.state, 0)
    Changed()
    return true
end

function LegacyBuy:Close(quiet)
    local state = self.state
    if state and state.timer then state.timer:Cancel() end
    self.state = nil
    if not quiet then Changed() end
end

--- Is the plan open for this item, from this place (nil for the drawer's
--- Buy view, "disenchant" for the Disenchanting tab)?
function LegacyBuy:IsOpenFor(itemID, source)
    return self.state ~= nil and self.state.itemID == itemID and self.state.source == source
end

--- A scan or a price check of ours has the auction house's list: our
--- search waits for it, or the two would read each other's answers.
function LegacyBuy.ScanBusy()
    local scan = ns.LegacyScan
    if not scan then return false end
    if scan.state ~= nil then return true end
    local search = scan.itemSearch
    return type(search) == "table" and search.awaiting == true
end

local function CanQuery()
    if type(CanSendAuctionQuery) ~= "function" then return true end
    local ok, canQuery = pcall(CanSendAuctionQuery)
    return ok and canQuery and true or false
end

--- Run fn once the game takes a search and no scan of ours holds the list.
--- Kept to this plan alone: a scan starting or ending never drops it, so a
--- plan waiting here always hears back. The wait for the game counts toward
--- giving up; the wait for a scan does not (closing the auction house
--- closes the plan).
function LegacyBuy:WhenFree(state, fn, onGiveUp)
    local waited = 0
    local function Look()
        if LegacyBuy.state ~= state then return end
        if LegacyBuy.ScanBusy() then
            C_Timer.After(LegacyBuy.POLL, Look)
            return
        end
        if CanQuery() then
            fn()
            return
        end
        waited = waited + LegacyBuy.POLL
        if waited >= LegacyBuy.PAGE_WAIT then
            onGiveUp()
            return
        end
        C_Timer.After(LegacyBuy.POLL, Look)
    end
    Look()
end

function LegacyBuy:SendPage(state, page)
    state.awaiting = nil
    self:WhenFree(state, function()
        if LegacyBuy.state ~= state then return end
        state.awaiting = page
        state.loaded = nil
        LegacyBuy.sending = true
        ns.LegacyScan.sendingOwn = true
        local sent = pcall(QueryAuctionItems, state.name, nil, nil, page, false, nil, false, state.exact, nil)
        ns.LegacyScan.sendingOwn = false
        LegacyBuy.sending = false
        if not sent then
            state.awaiting = nil
            LegacyBuy:Stalled(state)
            return
        end
        if state.timer then state.timer:Cancel() end
        state.timer = C_Timer.NewTimer(LegacyBuy.PAGE_WAIT, function()
            if LegacyBuy.state == state and state.awaiting == page then
                state.awaiting = nil
                LegacyBuy:Stalled(state)
            end
        end)
    end, function()
        if LegacyBuy.state == state then LegacyBuy:Stalled(state) end
    end)
end

-- No answer: plan with what was read, or let it go when nothing was.
function LegacyBuy:Stalled(state)
    if state.status == "reading" and (state.read or 0) > 0 then
        self:MakePlan(state)
    elseif state.status == "reading" then
        self:Close()
    else
        state.status = "ready"
        Changed()
    end
end

function LegacyBuy:AUCTION_ITEM_LIST_UPDATE()
    local state = self.state
    if not state or state.awaiting == nil or state.settling then return end
    state.settling = true
    C_Timer.After(ns.LegacyScan.PAGE_SETTLE, function()
        state.settling = false
        if LegacyBuy.state == state then LegacyBuy:ReadPage(state) end
    end)
end

function LegacyBuy:ReadPage(state)
    local page = state.awaiting
    if page == nil then return end
    if state.timer then state.timer:Cancel(); state.timer = nil end

    local ok, batch, total = pcall(GetNumAuctionItems, "list")
    batch = ok and tonumber(batch) or 0
    total = ok and tonumber(total) or 0
    local rows, missing = {}, false
    for index = 1, batch do
        local readOk, row = pcall(ReadRow, index)
        if readOk and row.itemID then
            row.page = page
            rows[#rows + 1] = row
            -- Its seller's name is still on its way: look once more, so your
            -- own stacks are known as yours.
            if row.owner == nil and row.itemID == state.itemID then missing = true end
        else
            missing = true
        end
    end
    if missing and not state.retried then
        state.retried = true
        C_Timer.After(ns.LegacyScan.PAGE_SETTLE * 2, function()
            if LegacyBuy.state == state then LegacyBuy:ReadPage(state) end
        end)
        return
    end
    state.retried = nil
    state.awaiting = nil
    state.loaded = { page = page, rows = rows }

    if state.status == "reading" then
        local scanner = ns.Scanner
        for _, row in ipairs(rows) do
            if row.itemID == state.itemID and row.buyout > 0 and row.count > 0 then
                row.own = scanner and scanner.IsOwnAuction
                    and scanner:IsOwnAuction(row.owner, row.ownerFull) == true or false
                state.listings[#state.listings + 1] = row
            end
        end
        state.read = (state.read or 0) + 1
        local pages = math.max(1, math.ceil(total / ns.LegacyScan.PER_PAGE))
        if page + 1 < pages and page + 1 < self.MAX_PAGES then
            self:SendPage(state, page + 1)
        else
            self:MakePlan(state)
        end
        return
    end

    self:FindNext(state)
end

function LegacyBuy:MakePlan(state)
    local need = state.need - state.bought
    if need <= 0 then
        state.status = "done"
        state.plan = nil
        Changed()
        return
    end
    local listings, usual = state.listings, self:Usual(state.itemID)
    if state.maxEach then
        -- Only stacks at or under the price for one; the usual price has no say.
        listings, usual = {}, nil
        for _, listing in ipairs(state.listings) do
            if listing.count > 0 and listing.buyout / listing.count <= state.maxEach then
                listings[#listings + 1] = listing
            end
        end
    end
    state.plan = self.Plan(listings, need, state.most - state.bought, usual)
    state.status = "ready"
    self:FindNext(state)
end

--- The next stack of the plan, on the page the game has loaded, so the next
--- click buys it at once. Loads its page when it is not.
function LegacyBuy:FindNext(state)
    local plan = state.plan
    local nextStack = plan and plan.stacks[1]
    state.target = nil
    if not nextStack then
        state.status = "done"
        Changed()
        return
    end
    local loaded = state.loaded
    if loaded then
        for _, row in ipairs(loaded.rows) do
            if Same(row, nextStack) then
                state.target = row
                state.status = "ready"
                Changed()
                return
            end
        end
        -- Its page was read and it is gone or moved: read the item again.
        if loaded.page == nextStack.page then
            self:Reread(state)
            return
        end
    end
    state.status = "loading"
    self:SendPage(state, nextStack.page)
    Changed()
end

function LegacyBuy:Reread(state)
    if state.reread and state.reread >= 3 then
        -- Still not found: wait for a press, which looks again from the start.
        state.status = "ready"
        state.stuck = true
        Changed()
        return
    end
    state.stuck = nil
    state.reread = (state.reread or 0) + 1
    state.status = "reading"
    state.listings = {}
    state.read = 0
    self:SendPage(state, 0)
    Changed()
end

--------------------------------------------------------------------------------
-- Buying
--------------------------------------------------------------------------------

--- What the button says and whether it can be pressed.
-- @return the next stack (or nil), and true when a click buys it now
function LegacyBuy:Next()
    local state = self.state
    local stack = state and state.plan and state.plan.stacks[1]
    return stack, state ~= nil and state.status == "ready"
        and (state.target ~= nil or state.stuck == true)
end

local function Counted(state, stack)
    state.bought = state.bought + stack.count
    -- Keep going: one more each time, while any are left under maxEach.
    if state.more then
        state.need = state.bought + 1
        state.most = state.need
    end
    stack.bought = true
    state.boughtStacks = state.boughtStacks or {}
    state.boughtStacks[#state.boughtStacks + 1] = stack
    for i, listing in ipairs(state.listings) do
        if listing == stack then table.remove(state.listings, i); break end
    end
end

--- The button's click: one stack. A real click, as the game asks.
function LegacyBuy:Buy()
    local state = self.state
    if not state then return false end
    local stack, ready = self:Next()
    if not stack then return false end
    if state.stuck and not state.target then
        state.reread = nil
        self:Reread(state)
        return false
    end
    if not ready then
        if state.status == "ready" then self:FindNext(state) end
        return false
    end
    local target = state.target
    -- Read the row again: the list may have moved since.
    local ok, row = pcall(ReadRow, target.index)
    if not ok or not Same(row, stack) then
        state.loaded = nil
        self:FindNext(state)
        return false
    end

    local money = ns.AHBuys and ns.AHBuys.Money and ns.AHBuys:Money()
    -- The last buy given up on: its gold gone means it went through, so the
    -- plan is worked out again first. Still here, it never will.
    local late = state.late
    state.late = nil
    if late and late.money and money and late.money - money >= late.stack.buyout then
        Counted(state, late.stack)
        state.loaded = nil
        state.reread = nil
        self:Reread(state)
        return false
    end
    -- Short of gold the game buys nothing and says little: say so, and keep
    -- the stack ready for when there is enough.
    if money and money < stack.buyout then
        if ns.Warn then ns.Warn(L["not enough gold on you"]) end
        return false
    end
    local placed = pcall(PlaceAuctionBid, "list", target.index, stack.buyout)
    if not placed then return false end

    state.status = "buying"
    state.buying = { stack = stack, money = money, at = GetTime() }
    state.target = nil
    if state.timer then state.timer:Cancel() end
    state.timer = C_Timer.NewTimer(self.BUY_WAIT, function()
        if LegacyBuy.state == state and state.buying then LegacyBuy:BuyFailed(state) end
    end)
    Changed()
    return true
end

-- Gold left: the stack is bought.
function LegacyBuy:PLAYER_MONEY()
    local state = self.state
    local buying = state and state.buying
    local money = ns.AHBuys and ns.AHBuys:Money()
    if not buying then
        -- A buy given up on whose gold left after all: count it, or the
        -- plan buys that much again.
        local late = state and state.late
        if not late then return end
        if GetTime() - (late.at or 0) > self.LATE_WAIT then
            state.late = nil
            return
        end
        if not (late.money and money and late.money - money >= late.stack.buyout) then return end
        state.late = nil
        Counted(state, late.stack)
        state.loaded = nil
        state.reread = nil
        -- A look under way plans with the new count when it ends.
        if state.status ~= "reading" then self:Reread(state) end
        return
    end
    if buying.money and money and buying.money - money < buying.stack.buyout then return end
    state.buying = nil
    if state.timer then state.timer:Cancel(); state.timer = nil end
    Counted(state, buying.stack)
    -- The list the game holds changed with the buy.
    state.loaded = nil
    state.reread = nil
    self:MakePlan(state)
end

-- Someone else bought it first, or the game said no: look again. The gold
-- can still leave a moment later on a slow server (PLAYER_MONEY's late buy).
function LegacyBuy:BuyFailed(state)
    local buying = state.buying
    state.buying = nil
    state.loaded = nil
    if buying and buying.money then
        state.late = { stack = buying.stack, money = buying.money, at = GetTime() }
    end
    self:Reread(state)
end

-- A search that is not ours replaced the list the game holds.
function LegacyBuy:OnQuery()
    if self.sending then return end
    local state = self.state
    if not state then return end
    state.loaded = nil
    state.target = nil
    if state.status == "reading" or state.status == "loading" then
        -- The answer coming is that search's: ask again after it.
        local page = state.awaiting
        if page ~= nil then
            C_Timer.After(ns.LegacyScan.PAGE_SETTLE, function()
                if LegacyBuy.state == state then LegacyBuy:SendPage(state, page) end
            end)
            state.awaiting = nil
        end
    elseif state.status == "ready" then
        Changed()
    end
end

function LegacyBuy:OnEnable()
    if not self:Applies() then return end
    if type(hooksecurefunc) == "function" and type(QueryAuctionItems) == "function" then
        pcall(hooksecurefunc, "QueryAuctionItems", function()
            pcall(LegacyBuy.OnQuery, LegacyBuy)
        end)
    end
    ns.RegisterEvent(self, "AUCTION_ITEM_LIST_UPDATE", self.AUCTION_ITEM_LIST_UPDATE)
    ns.RegisterEvent(self, "PLAYER_MONEY", self.PLAYER_MONEY)
    ns.RegisterEvent(self, "AUCTION_HOUSE_CLOSED", function() LegacyBuy:Close() end)
end
