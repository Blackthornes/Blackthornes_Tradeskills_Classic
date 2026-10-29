-- Cancelling on Era's older auction house (Logic/MyAuctions.lua,
-- Data/Auctions.lua, UI/AuctionsView.lua; the owner said try it,
-- 2026-10-29).
--
-- What must hold:
--   1. Era's auctions carry a key (item, count, buyout, which of those),
--      since the game gives no auction ID.
--   2. A cancel reads the list again right before and calls the game's
--      CancelAuction with where that auction sits now.
--   3. If the game turns it down (an error, a blocked call, or two that
--      never went), there are no Cancel buttons for the rest of the
--      session. Check Places is never offered on Era.

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
local said = {}
ns.Print = function(text) said[#said + 1] = text end
ns.Debug = function() end
local handlers = {}
ns.RegisterEvent = function(owner, event, fn)
    handlers[event] = function(...) fn(owner, event, ...) end
    return true
end

local clock = 100
GetTime = function() return clock end
time = function() return 5000 end
C_Timer = { After = function() end }
C_AuctionHouse = nil

ns.Util = {
    HasFunction = function() return false end,
    GetItemLabel = function(id) return "Item " .. id end,
    FormatMoney = function(c) return tostring(c) .. "c" end,
}
ns.Config = { GetCharacterKey = function() return "Player-1" end }
ns.Characters = { IsPlaying = function(_, key) return key == "Player-1" end }
ns.Scanner = { isAuctionHouseOpen = true }
ns.Posting = { IsThrottled = function() return false end }

-- The game's list of your auctions: two the same, then another.
local owner = {
    { count = 5, buyout = 500, itemID = 7 },
    { count = 5, buyout = 500, itemID = 7 },
    { count = 1, buyout = 900, itemID = 8 },
}
GetNumAuctionItems = function(kind) assert(kind == "owner"); return #owner end
GetAuctionItemInfo = function(kind, i)
    local a = owner[i]
    return "x", nil, a.count, 1, true, 1, nil, 0, 0, a.buyout, 0, nil, nil, nil, nil, a.sold and 1 or 0, a.itemID
end

local Auctions = {}
ns.Auctions = Auctions
do
    local src = assert(io.open(lfs_cwd .. "/Data/Auctions.lua")):read("*a")
    for _, name in ipairs({ "LegacyTuple", "LegacyKey", "LegacyIndexOf", "LegacyOwnedInfo" }) do
        local body = src:match("(function Auctions%." .. name .. "%(.-\nend)\n")
        assert(body, name)
        assert((loadstring or load)("local Auctions, STATUS_ACTIVE = ...\n" .. body))(Auctions, 0)
    end
end
Auctions.IsLegacy = function() return true end

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

-- 1
local key2 = Auctions.LegacyKey(Auctions.LegacyTuple(7, 5, 500), 2)
check("the second of two the same is told apart", Auctions.LegacyIndexOf(key2) == 2)
check("the other item", Auctions.LegacyIndexOf(Auctions.LegacyKey(Auctions.LegacyTuple(8, 1, 900), 1)) == 3)
check("gone is nil", Auctions.LegacyIndexOf(Auctions.LegacyKey(Auctions.LegacyTuple(9, 1, 1), 1)) == nil)

assert(loadfile(lfs_cwd .. "/Logic/MyAuctions.lua"))("Blackthornes_TS", ns)
local MyAuctions = ns.MyAuctions
MyAuctions:OnEnable()

-- 2
local calls = {}
CancelAuction = function(index) calls[#calls + 1] = index end
check("Era with CancelAuction: Cancel shows", MyAuctions:CanEverCancel() == true)
check("Era: never Check Places", MyAuctions:CanEverCheckPlaces() == false and MyAuctions:CanCheckPlaces() == false)

local key3 = Auctions.LegacyKey(Auctions.LegacyTuple(8, 1, 900), 1)
Auctions.live = { { auctionID = key3, legacy = true, itemID = 8, quantity = 1, mine = true } }
-- The list moved up since the read: the first one sold and went.
table.remove(owner, 1)
local ok = MyAuctions:Cancel({ auctionID = key3, itemID = 8, quantity = 1, mine = true })
check("a cancel went out", ok == true)
check("at where it sits now", calls[1] == 2)

-- Read back still there, twice: the buttons go.
clock = clock + 10
MyAuctions:OnRead(Auctions.live, true, {})
check("one miss: still offered", MyAuctions:CanEverCancel() == true)
MyAuctions:Cancel({ auctionID = key3, itemID = 8, quantity = 1, mine = true })
clock = clock + 10
MyAuctions:OnRead(Auctions.live, true, {})
check("two in a row that never went: no Cancel", MyAuctions:CanEverCancel() == false)

-- 3
MyAuctions.legacyBlocked = nil
MyAuctions.legacyMisses = 0
check("back for the blocked check", MyAuctions:CanEverCancel() == true)
handlers.ADDON_ACTION_BLOCKED("Blackthornes_TS", "CancelAuction()")
check("the game blocked it: no Cancel", MyAuctions:CanEverCancel() == false)

MyAuctions.legacyBlocked = nil
CancelAuction = function() error("blocked") end
ok = MyAuctions:Cancel({ auctionID = key3, itemID = 8, quantity = 1, mine = true })
check("an error: refused", ok == false)
check("and no Cancel after", MyAuctions:CanEverCancel() == false)

MyAuctions.legacyBlocked = nil
CancelAuction = nil
check("no CancelAuction at all: no Cancel", MyAuctions:CanEverCancel() == false)
check("and a row says so without words", select(2, MyAuctions:CanCancel({})) == nil)

print(("\nera cancel: %d checks passed"):format(checks))
