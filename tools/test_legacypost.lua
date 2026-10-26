-- Listing on Era's older auction house (Logic/Posting.lua, Data/Auctions.lua).
--
-- Era has no C_AuctionHouse. The Yes on the box used to call Forever's
-- PostItem, which Era does not have, so the click raised and nothing went
-- up. What must hold:
--   1. A listing puts the bag slot in the auction slot and calls
--      PostAuction with the stack's price, bid and buyout the same. Never
--      StartAuction while PostAuction is there: Era refuses the old name.
--   2. Yes on the box lists the same way, and never raises.
--   3. Something left in the auction slot goes back first.
--   4. List Next's first click checks the Sell list one item at a time,
--      saying so once, and the clicks after it list with no box.
--   5. Your auctions are read from Era's own list, so a listing is
--      confirmed as gone up.
--   6. A stack put in the auction slot is never listed in the same click
--      (Era answers "Internal auction error"): the first click puts it in,
--      the next lists it, and the next stack goes in ahead of its click.
--   7. Two copies of one item (two pairs of boots): the copy in the
--      auction slot is the one listed. Quick clicks never swap the copies
--      round, never repeat "ready to list", and never send a new price
--      check while one is out.

local GLOBALS = { "CreateFrame", "C_Container", "ItemLocation", "GetTime", "time", "C_Timer",
    "StaticPopupDialogs", "StaticPopup_Show", "StaticPopup_Hide", "StaticPopup_Visible",
    "C_AuctionHouse", "ClearCursor", "ClickAuctionSellItemButton", "StartAuction", "PostAuction",
    "GetAuctionSellItemInfo", "GetNumAuctionItems", "GetAuctionItemInfo", "GetAuctionItemLink",
    "GetOwnerAuctionItems" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local function noop() end
local function Blank()
    return setmetatable({}, { __index = function(_, k)
        if type(k) == "string" and k:match("^%u") then return noop end
    end })
end

local clock = 1000
CreateFrame = function() return Blank() end
GetTime = function() return clock end
time = function() return 100000 + clock end

local timers = {}
C_Timer = {
    After = function(seconds, fn) timers[#timers + 1] = { at = clock + seconds, fn = fn } end,
    NewTicker = function() return { Cancel = noop } end,
    NewTimer = function() return { Cancel = noop } end,
}
local function Advance(seconds)
    local target = clock + seconds
    while true do
        local nextTimer
        for _, t in ipairs(timers) do
            if not t.done and t.at <= target and (not nextTimer or t.at < nextTimer.at) then nextTimer = t end
        end
        if not nextTimer then break end
        clock = math.max(clock, nextTimer.at)
        nextTimer.done = true
        nextTimer.fn()
    end
    clock = target
end

local LINEN, SCORPID, BOOTS = 2589, 5464, 2309

local bags
local function FillBags()
    bags = { [0] = {
        { itemID = LINEN, stackCount = 17 },
        { itemID = SCORPID, stackCount = 10 },
    } }
end
FillBags()

-- The cursor and the auction slot, as Era keeps them. A stack in the
-- auction slot stays in its bag slot, locked; a listed one is gone.
local cursor, sellSlot, calls = nil, nil, {}
C_Container = {
    GetContainerNumSlots = function(bag) return bags[bag] and #bags[bag] or 0 end,
    GetContainerItemInfo = function(bag, slot)
        local e = bags[bag] and bags[bag][slot]
        if e and not e.gone then
            return { itemID = e.itemID, stackCount = e.stackCount, isLocked = e == sellSlot }
        end
    end,
    GetContainerItemLink = function() return nil end,
    PickupContainerItem = function(bag, slot)
        calls[#calls + 1] = "pickup"
        cursor = bags[bag][slot]
    end,
}
ItemLocation = nil
ClearCursor = function() cursor = nil end
ClickAuctionSellItemButton = function()
    calls[#calls + 1] = "slot"
    cursor, sellSlot = sellSlot, cursor
end
GetAuctionSellItemInfo = function()
    if sellSlot then
        return "item", nil, sellSlot.stackCount, nil, nil, nil, nil, nil, nil, sellSlot.itemID
    end
end

-- Your auctions: { itemID, count, buyout }.
local owned = {}
local started = {}
local oldCalls = 0
local function Listed(bid, buyout, duration, stackSize, numStacks, acknowledged)
    started[#started + 1] = { bid = bid, buyout = buyout, duration = duration,
        stackSize = stackSize, numStacks = numStacks, item = sellSlot and sellSlot.itemID,
        acknowledged = acknowledged }
    if sellSlot then
        owned[#owned + 1] = { sellSlot.itemID, stackSize, buyout }
        sellSlot.gone = true
    end
    sellSlot = nil
end
PostAuction = Listed
-- Era still has the old name, and calling it is refused.
StartAuction = function()
    oldCalls = oldCalls + 1
    error("StartAuction is refused")
end
GetNumAuctionItems = function(which) if which == "owner" then return #owned, #owned end return 0, 0 end
GetAuctionItemInfo = function(which, index)
    local row = which == "owner" and owned[index]
    if not row then return nil end
    return "x", 0, row[2], 1, true, 1, "", 0, 0, row[3], 0, false, nil,
        "Me", "Me-Realm", 0, row[1], true
end
GetAuctionItemLink = function() return nil end
GetOwnerAuctionItems = noop
C_AuctionHouse = nil

local popup
StaticPopupDialogs = {}
StaticPopup_Show = function(which, text, _, data)
    popup = Blank()
    popup.which, popup.text, popup.data = which, text, data
    return popup
end
StaticPopup_Visible = function(which) return popup and popup.which == which and popup or nil end
StaticPopup_Hide = function() popup = nil end

local said = {}
local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = noop
local handlers = {}
ns.RegisterEvent = function(_, event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], fn)
    return true
end
ns.Print = function(text) said[#said + 1] = text end
ns.Warn = function(text) said[#said + 1] = "WARN " .. text end
ns.PrintRaw, ns.Debug = noop, noop
ns.LegacyScan = { Applies = function() return true end }
ns.Compat = { Get = function() return { auction = { mode = "legacy" } } end }

local settings = { postDuration = 2, verifyPriceBeforePosting = true }
ns.db = {}
ns.Config = {
    Get = function(_, k) return settings[k] end,
    Set = function(_, k, v) settings[k] = v end,
    GetRealmKey = function() return "Realm-Horde" end,
    GetCharacterKey = function() return "Player-1" end,
}

local searches = {}
ns.Scanner = {
    isAuctionHouseOpen = true, isScanning = false,
    IsCommodity = function() return false end,
    ScanItem = function(_, itemID, cb)
        searches[#searches + 1] = { itemID = itemID, cb = cb }
        return true
    end,
    AbandonItemScan = noop,
}
-- The search answering: as Scanner:FinishItemScan does.
local function Answer(index)
    local search = searches[index]
    ns.Posting:NoteChecked(search.itemID)
    search.cb(search.itemID, 11, 11, 10, false, {}, "fresh")
end

local MARKET = { [LINEN] = 29, [SCORPID] = 11, [BOOTS] = 2020 }
ns.Prices = {
    GetValue = function(_, itemID, key) if key == "market" then return MARKET[itemID] end end,
    GetScanValue = function(_, itemID, key) if key == "market" then return MARKET[itemID] end end,
    Get = function() return {} end,
    IsCredible = function(price) return type(price) == "number" and price > 0 end,
}
ns.Inventory = {
    GetCarriedBags = function() return { 0 } end,
    GetBagCount = function(_, itemID)
        local n = 0
        for _, e in ipairs(bags[0]) do
            if e.itemID == itemID and not e.gone then n = n + e.stackCount end
        end
        return n
    end,
}
ns.Recipes = { GetAccountWide = function() return {} end }
ns.Queue = { GetReservedItems = function() return {} end }
ns.Cost = { FindAnyRecipeForItem = function() return nil end }
ns.Profit = {
    ChoosePostPrice = function(_, itemID) return MARKET[itemID], "market" end,
    Analyse = function() return {} end,
}
ns.AHQueue = {
    Yield = noop, NoteSend = noop, PRIORITY = { urgent = 10, normal = 5 },
    SecondsUntilReady = function() return 0 end,
    Request = function() return true end,
}
ns.UI = { RefreshActiveTab = noop, UpdatePostButton = noop, OnAuctionsUpdated = noop }
-- What the drawer's Sell list shows, for the stack put in ahead.
local shown = {}
ns.PostPanel = { ShownLines = function() return shown end }

assert(loadfile(lfs_cwd .. "/Core/Util.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Posting.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Data/Auctions.lua"))("Blackthornes_TS", ns)

local Posting = ns.Posting
Posting:OnEnable()

local passed, failed = 0, 0
local function check(label, got, want)
    local ok = got == want
    if ok then passed = passed + 1 else failed = failed + 1 end
    print(string.format("  %-62s %-8s %s", label, tostring(got), ok and "ok" or
        ("WRONG, wanted " .. tostring(want))))
end
local function Said(fragment)
    local n = 0
    for _, line in ipairs(said) do
        if line:find(fragment, 1, true) then n = n + 1 end
    end
    return n
end

local function Reset()
    said, popup, searches, started, calls, owned, timers = {}, nil, {}, {}, {}, {}, {}
    cursor, sellSlot, shown = nil, nil, {}
    Posting.confirming, Posting.pending, Posting.others, Posting.requesting = nil, nil, nil, {}
    Posting:ForgetChecks()
    FillBags()
    -- Leaving the auction house forgets a stack put in.
    for _, h in ipairs(handlers.AUCTION_HOUSE_CLOSED or {}) do h() end
end

-- A click that lists: the first puts the stack in, the next lists it.
local function PostTwice(itemID, quantity, price)
    Posting:Post(itemID, quantity, price)
    Advance(1)
    return pcall(Posting.Post, Posting, itemID, quantity, price)
end

print("")
print("one listing")

Reset()
local ok = pcall(Posting.Post, Posting, SCORPID, 10, 11)
check("the first click does not raise", ok, true)
check("it lists nothing yet", #started, 0)
check("the stack is in the auction slot", sellSlot and sellSlot.itemID, SCORPID)
check("it says the next click lists it", Said("is ready to list"), 1)
check("no warning", Said("WARN"), 0)
Posting:Post(SCORPID, 10, 11)
check("a click straight after still waits", #started, 0)
check("and keeps the stack in the slot", sellSlot and sellSlot.itemID, SCORPID)
Advance(1)
ok = pcall(Posting.Post, Posting, SCORPID, 10, 11)
check("the next click does not raise", ok, true)
check("PostAuction is called", #started, 1)
check("never the old StartAuction", oldCalls, 0)
check("with the maintenance warning read", started[1] and started[1].acknowledged, true)
check("with the stack's price as buyout", started[1] and started[1].buyout, 110)
check("and the same as bid", started[1] and started[1].bid, 110)
check("for the length picked", started[1] and started[1].duration, 2)
check("the whole stack, once", started[1] and started[1].stackSize, 10)
check("one stack", started[1] and started[1].numStacks, 1)
check("of the item asked for", started[1] and started[1].item, SCORPID)
check("nothing left on the cursor", cursor, nil)

print("")
print("the game says the slot took it")

Reset()
Posting:Post(SCORPID, 10, 11)
for _, h in ipairs(handlers.NEW_AUCTION_UPDATE or {}) do h() end
Posting:Post(SCORPID, 10, 11)
check("the next click lists it at once", #started, 1)

print("")
print("Yes on the box")

Reset()
Posting:Confirm(SCORPID, 10, 11, { state = "fresh" })
check("the box shows", popup ~= nil, true)
local accept = StaticPopupDialogs.BLACKTHORNES_TS_CONFIRM_POST.OnAccept
ok = pcall(accept, popup)
check("Yes does not raise", ok, true)
check("Yes puts the stack in", sellSlot and sellSlot.itemID, SCORPID)
Advance(1)
Posting:Post(SCORPID, 10, 11)
check("and the next click lists it", #started, 1)

print("")
print("something left in the auction slot")

Reset()
sellSlot = { itemID = 9999 }
PostTwice(LINEN, 17, 29)
check("it goes back first", calls[1], "slot")
check("then the stack goes in", started[1] and started[1].item, LINEN)

print("")
print("checking the list, then listing")

Reset()
local lines = { { itemID = SCORPID, unitPrice = 11 }, { itemID = LINEN, unitPrice = 29 } }
shown = lines
local began, count = Posting:CheckAll(lines)
check("the first click checks", began, true)
check("both items", count, 2)
check("one search at a time", #searches, 1)
check("while it runs, the button checks prices", Posting:WouldCheckAll(lines[1], lines), true)
Answer(1)
Advance(0.1)
check("then the next", #searches, 2)
Answer(2)
Advance(0.1)
check("the check is done", Posting:CheckingAll(), false)
check("said once when done", Said("checked the prices of 2 items"), 1)
check("the first stack goes in ahead", sellSlot and sellSlot.itemID, SCORPID)
check("no line for each item", Said("checking the current price"), 0)
check("now the button lists", Posting:WouldCheckAll(lines[1], lines), false)
check("nothing listed by the check", #started, 0)
Advance(1)
Posting:Request(SCORPID, 10, 11)
check("a click lists it", #started, 1)
check("with no box", popup, nil)
check("and no search", #searches, 2)
-- The check put the first stack in, so the click above listed it.

print("")
print("a search that never answers")

Reset()
Posting:CheckAll(lines)
Advance(7)
check("the next item is searched anyway", #searches, 2)

print("")
print("the listing is confirmed")

Reset()
ns.Auctions:ReadOwned()   -- as on opening the auction house
PostTwice(SCORPID, 10, 11)
check("waiting to be confirmed", Posting.pending ~= nil, true)
Advance(20)
check("confirmed", Posting.pending, nil)
check("said it went up", Said("listed 10 x"), 1)
check("your auctions read from Era's list", ns.Auctions:GetOwnPostedCount(SCORPID), 10)

print("")
print("after a listing, the next stack goes in")

Reset()
shown = { { itemID = SCORPID, unitPrice = 11 }, { itemID = LINEN, unitPrice = 29 } }
ns.Auctions:ReadOwned()
PostTwice(SCORPID, 10, 11)
check("listed", #started, 1)
Advance(20)
check("the next stack is in the slot", sellSlot and sellSlot.itemID, LINEN)
Posting:Post(LINEN, 17, 29)
check("one click lists it", #started, 2)

print("")
print("walking away")

Reset()
Posting:Post(SCORPID, 10, 11)
for _, h in ipairs(handlers.AUCTION_HOUSE_CLOSED or {}) do h() end
sellSlot = nil   -- the game sends it back to the bags
Posting:Post(SCORPID, 10, 11)
check("the stack goes in again, nothing listed", #started, 0)

print("")
print("a client with only the old StartAuction")

Reset()
PostAuction = nil
StartAuction = Listed
PostTwice(SCORPID, 10, 11)
check("lists with StartAuction", #started, 1)
check("at the stack's price", started[1] and started[1].buyout, 110)

print("")
print("two pairs of boots, clicked fast")

Reset()
bags[0][#bags[0] + 1] = { itemID = BOOTS, stackCount = 1 }
bags[0][#bags[0] + 1] = { itemID = BOOTS, stackCount = 1 }
local firstBoots = bags[0][#bags[0] - 1]
shown = { { itemID = BOOTS, unitPrice = 2020 } }
ns.Auctions:ReadOwned()
for _ = 1, 6 do Posting:Post(BOOTS, 2, 2020) end
check("the first pair goes in", sellSlot, firstBoots)
check("and stays there through the clicks", #calls, 2)
check("said once", Said("is ready to list"), 1)
check("nothing listed too soon", #started, 0)
Advance(1)
Posting:Post(BOOTS, 2, 2020)
check("the next click lists it", #started, 1)
check("one pair", started[1] and started[1].stackSize, 1)
Advance(20)
check("the other pair goes in", sellSlot and sellSlot.itemID, BOOTS)
Posting:Post(BOOTS, 1, 2020)
check("and the click after lists it", #started, 2)
check("both pairs listed", firstBoots.gone, true)

print("")
print("quick clicks while the price is checked")

Reset()
for _ = 1, 5 do Posting:Request(BOOTS, 1, 2020) end
check("one search", #searches, 1)
check("said once", Said("checking the current price"), 1)
Answer(1)
check("one box", popup ~= nil, true)
Advance(6)
check("still one search", #searches, 1)

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print("")
print(("%d passed, %d failed"):format(passed, failed))
assert(failed == 0, "Era listing checks failed")
