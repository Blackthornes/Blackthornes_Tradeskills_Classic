-- Buying what the queue needs on Era's older auction house (Logic/LegacyBuy.lua).
--
-- Era sells whole stacks, each at its own price. The plan takes the
-- cheapest stacks that cover the need, at most a quarter over it, leaves
-- out stacks over half again the usual price and the player's own, and the
-- button buys one stack a click.

local GLOBALS = { "CreateFrame", "GetTime", "time", "C_Timer", "C_Item", "C_AuctionHouse",
    "QueryAuctionItems", "GetAuctionItemInfo", "GetAuctionItemLink", "GetNumAuctionItems",
    "CanSendAuctionQuery", "hooksecurefunc", "PlaceAuctionBid", "unpack" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local function noop() end
unpack = unpack or table.unpack
CreateFrame = function() return setmetatable({}, { __index = function() return noop end }) end
C_AuctionHouse = nil
local clock = 1000
GetTime = function() return clock end
time = function() return 100000 + clock end

local timers = {}
local function Timer(delay, fn)
    local t = { at = clock + delay, fn = fn }
    t.Cancel = function() t.cancelled = true end
    timers[#timers + 1] = t
    return t
end
C_Timer = { After = function(d, fn) Timer(d, fn) end, NewTimer = Timer,
    NewTicker = function() return { Cancel = noop } end }
local function Advance(seconds)
    local target = clock + seconds
    while true do
        local nextTimer
        for _, t in ipairs(timers) do
            if not t.cancelled and not t.done and t.at <= target and (not nextTimer or t.at < nextTimer.at) then
                nextTimer = t
            end
        end
        if not nextTimer then break end
        clock = math.max(clock, nextTimer.at)
        nextTimer.done = true
        nextTimer.fn()
    end
    clock = target
end

local LINEN = 2589
C_Item = { GetItemInfo = function(id) if id == LINEN then return "Linen Cloth" end end }

-- The auction house: rows { count, buyout, owner }, 50 a page.
local house, list, total = {}, {}, 0
local queries, bids = {}, {}
local hooks = {}
hooksecurefunc = function(name, fn) hooks[name] = hooks[name] or {}; table.insert(hooks[name], fn) end
local events = {}
local function Fire(event, ...) for _, fn in ipairs(events[event] or {}) do fn(...) end end

QueryAuctionItems = function(text, _, _, page)
    queries[#queries + 1] = { text = text, page = page }
    for _, fn in ipairs(hooks.QueryAuctionItems or {}) do fn() end
    list = {}
    for i = page * 50 + 1, math.min(#house, page * 50 + 50) do list[#list + 1] = house[i] end
    total = #house
end
GetNumAuctionItems = function() return #list, total end
GetAuctionItemInfo = function(_, index)
    local row = list[index]
    if not row then return nil end
    return "Linen Cloth", 0, row[1], 1, true, 1, "", 0, 0, row[2], 0, false, nil,
        row[3], row[3] and (row[3] .. "-Realm") or nil, 0, LINEN, true
end
GetAuctionItemLink = function() return nil end
CanSendAuctionQuery = function() return true, false end
local money = 100000
PlaceAuctionBid = function(_, index, amount)
    bids[#bids + 1] = { row = list[index], amount = amount }
end

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterEvent = function(owner, event, fn)
    events[event] = events[event] or {}
    table.insert(events[event], function(...) fn(owner, event, ...) end)
    return true
end
ns.Print, ns.Warn, ns.Debug, ns.PrintRaw = noop, noop, noop, noop
ns.Compat = { Get = function() return { auction = { mode = "legacy" } } end }
ns.Scanner = { isAuctionHouseOpen = true,
    IsOwnAuction = function(_, owner) return owner == "Me" end }
local usual = nil
ns.Prices = { GetValue = function() return usual end }
ns.AHBuys = { Money = function() return money end }
local changes = 0
ns.PostPanel = { OnLegacyBuy = function() changes = changes + 1 end }

assert(loadfile(lfs_cwd .. "/Core/Util.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Data/LegacyScan.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/LegacyBuy.lua"))("Blackthornes_TS", ns)
local LegacyBuy = ns.LegacyBuy
LegacyBuy:OnEnable()

local passed, failed = 0, 0
local function check(label, condition)
    if condition then passed = passed + 1; print(("  ok    %s"):format(label))
    else failed = failed + 1; print(("  FAIL  %s"):format(label)) end
end

local function L(count, buyout, own) return { count = count, buyout = buyout, own = own } end
local function Counts(plan)
    local out = {}
    for _, s in ipairs(plan.stacks) do out[#out + 1] = s.count end
    table.sort(out)
    return table.concat(out, ",")
end

print("")
print("the cheapest stacks that cover the need")

local plan = LegacyBuy.Plan({ L(20, 520), L(20, 540), L(10, 300), L(5, 400), L(20, 900) }, 45, 56)
check("45 from 20, 20 and 10", Counts(plan) == "10,20,20" and plan.units == 50 and plan.extra == 5)
check("its total", plan.total == 1360)
check("the cheapest each comes first", plan.stacks[1].buyout == 520)

plan = LegacyBuy.Plan({ L(20, 520), L(20, 540), L(5, 150), L(5, 150) }, 40, 50)
check("an exact need takes no extra", Counts(plan) == "20,20" and plan.extra == 0)

plan = LegacyBuy.Plan({ L(20, 200), L(1, 50), L(1, 50) }, 2, 2)
check("a big stack past a quarter extra is not taken", Counts(plan) == "1,1")

plan = LegacyBuy.Plan({ L(20, 200) }, 2, 2)
check("with nothing inside the quarter, the least extra there is", Counts(plan) == "20" and plan.extra == 18)

plan = LegacyBuy.Plan({ L(20, 400, true), L(20, 600) }, 20, 25)
check("your own stacks are never bought", Counts(plan) == "20" and plan.total == 600)

plan = LegacyBuy.Plan({ L(10, 100), L(10, 1000) }, 20, 25, 10)
check("a stack over half again the usual price is left out", Counts(plan) == "10" and plan.skipped)
check("and what is still needed is said", plan.short == 10)

plan = LegacyBuy.Plan({}, 8, 10)
check("nothing for sale needs everything", #plan.stacks == 0 and plan.short == 8)

plan = LegacyBuy.Plan({ L(10, 100), L(10, 900) }, 20, 25)
check("no usual price, nothing is left out", Counts(plan) == "10,10" and not plan.skipped)

print("")
print("reading, then buying one stack a click")

house = {}
for i = 1, 55 do house[i] = { 20, 2000 + i * 10, "Rival" } end
house[53] = { 20, 500, "Cheap" }
house[54] = { 20, 600, "Me" }
house[55] = { 10, 300, "Other" }

check("it opens for the need", LegacyBuy:Open(LINEN, 25) == true)
Advance(0.2)
check("it searches by the exact name, page one", queries[1] and queries[1].text == "Linen Cloth" and queries[1].page == 0)
Fire("AUCTION_ITEM_LIST_UPDATE"); Advance(1)
check("then page two", queries[2] and queries[2].page == 1)
Fire("AUCTION_ITEM_LIST_UPDATE"); Advance(1)
local state = LegacyBuy.state
check("a plan is made", state.plan ~= nil and Counts(state.plan) == "10,20")
local stack, ready = LegacyBuy:Next()
check("the cheapest stack is next, and its page is loaded", stack.buyout == 500 and ready)
check("the plan was redrawn", changes > 0)

LegacyBuy:Buy()
check("a click buys it at its buyout", #bids == 1 and bids[1].row[3] == "Cheap" and bids[1].amount == 500)
check("only once until it goes through", not select(2, LegacyBuy:Next()))
money = money - 500
table.remove(house, 53)
Fire("PLAYER_MONEY")
check("bought, and counted", state.bought == 20 and #state.boughtStacks == 1)
Advance(0.2)
Fire("AUCTION_ITEM_LIST_UPDATE"); Advance(1)
stack, ready = LegacyBuy:Next()
check("the next stack is found where it moved", stack.count == 10 and ready)

-- Someone else bought it first.
table.remove(house, 54)
list = {}
LegacyBuy:Buy()
check("a stack gone is not bid on", #bids == 1)
Advance(0.2)
for _ = 1, 3 do Fire("AUCTION_ITEM_LIST_UPDATE"); Advance(1) end
stack = LegacyBuy:Next()
check("it looks again and plans what is left", stack ~= nil and stack.count == 20 and state.plan.short == 0)

QueryAuctionItems("Something else", nil, nil, 0)
check("a search of your own lets go of the loaded page", not select(2, LegacyBuy:Next()))

Fire("AUCTION_HOUSE_CLOSED")
check("closing the auction house closes the plan", LegacyBuy.state == nil)

print("")
print("seller names that come in late")

-- Era fills in a seller's name a moment after the row.
house = { { 20, 400, nil }, { 20, 900, "Rival" } }
local lateNames = { [1] = "Me" }
check("it opens", LegacyBuy:Open(LINEN, 20) == true)
Advance(0.2)
local lateQuery = #queries
Fire("AUCTION_ITEM_LIST_UPDATE"); Advance(0.3)
for i, name in pairs(lateNames) do house[i][3] = name; if list[i] then list[i][3] = name end end
Advance(1)
state = LegacyBuy.state
check("a page with a name missing is read once more", #queries == lateQuery)
check("and your own stack, named late, is left out", state.plan and Counts(state.plan) == "20"
    and state.plan.total == 900)

house = { { 20, 500, nil } }
check("it opens again", LegacyBuy:Open(LINEN, 20) == true)
Advance(0.2)
Fire("AUCTION_ITEM_LIST_UPDATE"); Advance(1)
stack, ready = LegacyBuy:Next()
check("a name still missing after the second look plans it anyway", stack and stack.buyout == 500 and ready)
house[1][3] = "Rival"
local before = #bids
LegacyBuy:Buy()
check("and the name arriving later doesn't stop the buy", #bids == before + 1)
Fire("AUCTION_HOUSE_CLOSED")

-- The Buy button's price uses the game's coin icons, which read on gold.
local priced = ns.Util.FormatMoney(230, { icons = true })
check("the Buy button's price shows coin icons", priced:find("UI-SilverIcon", 1, true)
    and priced:find("UI-CopperIcon", 1, true) and priced:find("^2") ~= nil)
check("coin icons leave out the coloured letters", not priced:find("|cff", 1, true))

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print("")
print(("%d passed, %d failed"):format(passed, failed))
assert(failed == 0, "legacy buy checks failed")
