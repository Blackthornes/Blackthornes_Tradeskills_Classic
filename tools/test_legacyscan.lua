-- The Scan button on Era's older auction house (Data/LegacyScan.lua).
--
-- Era has no C_AuctionHouse. Scan asks for the quick full scan when the game
-- allows it, reads page by page when it does not, and both go into the same
-- prices as Forever's scan. A search of the player's own during the scan
-- never ends up read as part of it.

-- Tests share one Lua state, so every global replaced here is put back,
-- including the ones that were not set at all.
local GLOBALS = { "CreateFrame", "GetTime", "time", "C_Timer", "C_Item", "C_AuctionHouse",
    "QueryAuctionItems", "GetAuctionItemInfo", "GetAuctionItemLink", "GetNumAuctionItems",
    "CanSendAuctionQuery", "hooksecurefunc", "unpack" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local function noop() end
unpack = unpack or table.unpack

local function Blank()
    return setmetatable({}, { __index = function(_, k)
        if type(k) == "string" and k:match("^%u") then return noop end
    end })
end

CreateFrame = function() return Blank() end
C_AuctionHouse = nil
local clock = 1000
GetTime = function() return clock end
time = function() return 100000 + clock end

-- Timers run when the test says, in the order they were set.
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

local LINEN, WOOL, SWORD = 2589, 2592, 9999
local stackSizes = { [LINEN] = 20, [WOOL] = 20, [SWORD] = 1 }
local names = { [LINEN] = "Linen Cloth", [WOOL] = "Wool Cloth", [SWORD] = "Sword" }
-- Random suffixes by their number, for gear "of the Owl".
local suffixNames = { [5] = " of the Owl", [7] = " of the Bear" }
local function FullName(itemID, suffix)
    return names[itemID] and (names[itemID] .. (suffix and suffixNames[suffix] or "")) or nil
end
C_Item = {
    GetItemInfo = function(item)
        local itemID, suffix = tonumber(item), nil
        if type(item) == "string" then
            itemID = tonumber(item:match("item:(%d+)"))
            suffix = tonumber(item:match("item:%d+:[%-%d]*:[%-%d]*:[%-%d]*:[%-%d]*:[%-%d]*:(%-?%d+)"))
        end
        local stack = stackSizes[itemID]
        if not stack then return nil end
        return FullName(itemID, suffix), "link", 1, 1, 1, "Trade Goods", "Cloth", stack
    end,
}

-- The auction house. Rows are { count, whole stack's buyout, itemID }.
local house = {}
local list = {}        -- what the "list" holds now
local listTotal = 0
local canQuery, canQueryAll = true, true
local queries = {}
local answer = true    -- whether the server answers a query
local hooks = {}
hooksecurefunc = function(name, fn) hooks[name] = fn end

QueryAuctionItems = function(text, minLevel, maxLevel, page, usable, rarity, getAll, exact)
    queries[#queries + 1] = { text = text, page = page, getAll = getAll, exact = exact }
    if hooks.QueryAuctionItems then hooks.QueryAuctionItems(text, minLevel, maxLevel, page, usable, rarity, getAll) end
    if not answer then return end
    local found = house
    if text and text ~= "" then
        found = {}
        for _, row in ipairs(house) do
            if FullName(row[3], row.suffix) == text then found[#found + 1] = row end
        end
    end
    list = {}
    if getAll then
        for i, row in ipairs(found) do list[i] = row end
    else
        for i = page * 50 + 1, math.min(#found, page * 50 + 50) do list[#list + 1] = found[i] end
    end
    listTotal = #found
end
GetNumAuctionItems = function() return #list, listTotal end
GetAuctionItemInfo = function(_, index)
    local row = list[index]
    if not row then return nil end
    local owner, ownerFull = "Rival", "Rival-TestRealm"
    if row.late then owner, ownerFull = nil, nil end
    return "x", 0, row[1], 1, true, 1, "", 0, 0, row[2], 0, false, nil,
        owner, ownerFull, 0, row[3], true
end
GetAuctionItemLink = function(_, index)
    local row = list[index]
    if not row then return nil end
    if row.suffix then
        return ("|Hitem:%d:0:0:0:0:0:%d|h[%s]|h"):format(row[3], row.suffix, FullName(row[3], row.suffix))
    end
    return "|Hitem:" .. row[3] .. "::::::::|h[x]|h"
end
CanSendAuctionQuery = function() return canQuery, canQueryAll end

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
local modules = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; modules[#modules + 1] = m; return m end
ns.RegisterCommand = noop
local events = {}
ns.RegisterEvent = function(owner, event, fn) events[event] = function(...) fn(owner, event, ...) end; return true end
local printed = {}
ns.Print = function(text) printed[#printed + 1] = text end
ns.Warn = ns.Print
ns.PrintRaw, ns.Debug = noop, noop

local realm = "TestRealm-Horde"
local priceTables = {}
ns.db = { commodity = {} }
ns.Config = {
    Get = function() return nil end,
    GetRealmKey = function() return realm end,
    GetPriceTable = function()
        priceTables[realm] = priceTables[realm] or {}
        return priceTables[realm]
    end,
}
ns.Compat = { Get = function() return { auction = { mode = "legacy", hasLegacyQuery = true } } end }
local completed = 0
ns.UI = { OnScanComplete = function() completed = completed + 1 end }

assert(loadfile(lfs_cwd .. "/Core/Util.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Data/Prices.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Data/Scanner.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Data/LegacyScan.lua"))("Blackthornes_TS", ns)

local Prices, Scanner, LegacyScan = ns.Prices, ns.Scanner, ns.LegacyScan

-- Run the worker straight through.
ns.Util.NewWorker = function(opts)
    return { Start = function(_, items)
        for _, item in ipairs(items) do opts.onItem(item) end
        if opts.onDone then opts.onDone() end
    end, IsRunning = function() return false end }
end

Scanner:OnEnable()
LegacyScan:OnEnable()

local passed, failed = 0, 0
local function check(label, condition)
    if condition then
        passed = passed + 1
        print(("  ok    %s"):format(label))
    else
        failed = failed + 1
        print(("  FAIL  %s"):format(label))
    end
end

local function Fire() if events.AUCTION_ITEM_LIST_UPDATE then events.AUCTION_ITEM_LIST_UPDATE() end end
local function Reset()
    queries, printed, timers = {}, {}, {}
    priceTables = {}
    ns.db.commodity = {}
    completed = 0
    Scanner.isAuctionHouseOpen = true
    Scanner.isScanning, Scanner.isReading = false, false
    LegacyScan:Stop()
end

print("")
print("the Scan button works without C_AuctionHouse")

Reset()
check("Scan is allowed", Scanner:CanFullScan() == true)

print("")
print("the quick full scan when the game allows it")

house = { { 20, 800, LINEN }, { 5, 200, LINEN }, { 10, 1000, WOOL }, { 1, 5000, SWORD } }
canQuery, canQueryAll = true, true
Reset()
Scanner:StartFullScan()
check("it asks for the whole house at once", #queries == 1 and queries[1].getAll == true)
check("the bar says it is asking", LegacyScan:Status() ~= nil)
Fire()
Advance(LegacyScan.FULL_SETTLE + 0.1)
check("linen is priced for one", Prices:Get(LINEN) ~= nil and Prices:Get(LINEN).min == 40)
check("wool too", Prices:Get(WOOL) ~= nil and Prices:Get(WOOL).min == 100)
check("a sword is its buyout", Prices:Get(SWORD) ~= nil and Prices:Get(SWORD).min == 5000)
check("the scan is over", not Scanner.isScanning and LegacyScan.state == nil and completed == 1)
check("the fifteen minutes start", ns.db.lastReplicateRequest ~= nil and time() - ns.db.lastReplicateRequest < 5 and not ns.db.lastReplicateByOther)

print("")
print("page by page while the quick scan waits")

house = {}
for i = 1, 120 do house[i] = { 1, 300, (i % 2 == 0) and LINEN or WOOL } end
canQuery, canQueryAll = true, false
Reset()
Scanner:StartFullScan()
check("it asks for the first page", #queries == 1 and queries[1].getAll ~= true and queries[1].page == 0)
check("and says why it is not the quick scan", #printed >= 1)
for _ = 1, 3 do
    Fire()
    Advance(LegacyScan.PAGE_SETTLE + 0.1)
end
check("it read all three pages", #queries == 3 and queries[3].page == 2)
check("every page is priced", Prices:Get(LINEN) ~= nil and Prices:Get(LINEN).min == 300
    and Prices:Get(WOOL) ~= nil and Prices:Get(WOOL).min == 300)
check("the scan is over", not Scanner.isScanning and LegacyScan.state == nil)

print("")
print("it waits for the game to take the next page")

Reset()
canQuery = false
Scanner:StartFullScan()
check("nothing is sent while the game says wait", #queries == 0)
canQuery = true
Advance(LegacyScan.POLL + 0.01)
check("and it goes as soon as the game takes it", #queries == 1)
LegacyScan:Stop()

print("")
print("the player's own search during a page scan")

Reset()
Scanner:StartFullScan()
-- The player searches before our first page answers.
answer = true
hooks.QueryAuctionItems("cloth", nil, nil, 0, false, nil, false)
Fire()
Advance(LegacyScan.PAGE_SETTLE + 0.1)
check("that answer is not read as page one; the page is asked again", #queries == 2 and queries[2].page == 0)
for _ = 1, 3 do
    Fire()
    Advance(LegacyScan.PAGE_SETTLE + 0.1)
end
check("and the scan still finishes", not Scanner.isScanning and LegacyScan.state == nil)

print("")
print("a page that never answers")

Reset()
answer = false
Scanner:StartFullScan()
Advance(LegacyScan.PAGE_TIMEOUT + 1)
check("the scan stops and gives the button back", not Scanner.isScanning and completed == 1)
answer = true

print("")
print("another addon's quick full scan")

Reset()
ns.db.lastReplicateByOther = nil
hooks.QueryAuctionItems("", nil, nil, 0, false, nil, true)
check("its fifteen minutes are noted", ns.db.lastReplicateByOther == true)

print("")
print("closing the auction house stops the scan")

Reset()
canQueryAll = false
Scanner:StartFullScan()
Scanner:AUCTION_HOUSE_CLOSED()
check("nothing is left running", LegacyScan.state == nil and not Scanner.isScanning)
local sent = #queries
Advance(LegacyScan.PAGE_TIMEOUT + 1)
check("and no page is asked for after", #queries == sent)

print("")
print("a price check before a listing searches the item by name")

house = { { 20, 800, LINEN }, { 5, 150, LINEN }, { 10, 1000, WOOL } }
canQuery, canQueryAll = true, true
Reset()
Scanner.recentItemScans = {}
local got
local started = Scanner:ScanItem(LINEN, function(_, _, _, _, _, _, status) got = status end)
check("the check goes out", started == true)
check("it asks for linen by its exact name", #queries == 1 and queries[1].text == "Linen Cloth"
    and queries[1].exact == true and not queries[1].getAll)
Fire()
Advance(LegacyScan.PAGE_SETTLE + 0.1)
check("the answer comes back fresh", got == "fresh")
check("the cheapest linen is 30c each", Prices:Get(LINEN) ~= nil and Prices:Get(LINEN).min == 30)
check("wool was not asked about", Prices:Get(WOOL) == nil)
check("nothing is left waiting", Scanner.pendingItem == nil and LegacyScan.itemSearch == nil)

got = nil
Scanner:ScanItem(LINEN, function(_, _, _, _, _, _, status) got = status end)
check("asked again at once, it is a recent check", got == "recent" and #queries == 1)

print("")
print("a price check waits for a seller's name that comes in late")

house = { { 20, 800, LINEN, late = true } }
Reset()
Scanner.recentItemScans = {}
got = nil
Scanner:ScanItem(LINEN, function(_, _, _, _, _, _, status) got = status end)
Fire()
Advance(LegacyScan.PAGE_SETTLE + 0.1)
check("with the name missing it looks once more", got == nil)
house[1].late = nil
Advance(LegacyScan.PAGE_SETTLE * 2 + 0.1)
check("then answers with the name in", got == "fresh")

print("")
print("a price check with no linen listed")

house = { { 10, 1000, WOOL } }
Reset()
Scanner.recentItemScans = {}
got = nil
Scanner:ScanItem(LINEN, function(_, _, _, _, _, _, status) got = status end)
Fire()
Advance(LegacyScan.PAGE_SETTLE + 0.1)
check("an empty house is an answer", got == "empty")

print("")
print("a price check the server never answers")

answer = false
Reset()
Scanner.recentItemScans = {}
got = nil
Scanner:ScanItem(WOOL, function(_, _, _, _, _, _, status) got = status end)
Advance(1)
check("it waits for the caller's own fallback", got == nil and Scanner.pendingItem ~= nil)
answer = true

print("")
print("the player's own search during a price check")

house = { { 20, 800, LINEN } }
Reset()
Scanner.recentItemScans = {}
got = nil
Scanner:ScanItem(LINEN, function(_, _, _, _, _, _, status) got = status end)
hooks.QueryAuctionItems("Copper Ore", nil, nil, 0, false, nil, false)
check("the check knows it was interrupted", got == "superseded" and LegacyScan.itemSearch == nil)

print("")
print("a price check waits while a scan holds the list")

canQueryAll = false
Reset()
Scanner:StartFullScan()
check("the check does not go out", Scanner:ScanItem(LINEN, function() end) == false)
LegacyScan:Stop()

print("")
print("Era's auction house takes copper")

check("32c stays 32c", ns.Util.RoundToSilver(32) == 32)
check("a whole copper price is fine", ns.Util.IsWholeSilver(32) == true)
check("rounding up keeps the copper", ns.Util.CeilToSilver(132.4) == 133)

print("")
print("the AH buttons search the game's Browse list")

house = { { 20, 800, LINEN }, { 1, 5000, SWORD } }
canQuery, canQueryAll = true, false
Reset()
local gaveUp
check("the search goes out", LegacyScan:Browse("Linen Cloth", function(r) gaveUp = r end) == true)
check("by name, first page, not the whole house", #queries == 1 and queries[1].text == "Linen Cloth"
    and queries[1].page == 0 and not queries[1].getAll)
check("the game's list now holds it", #list == 1 and list[1][3] == LINEN and gaveUp == nil)
check("a plain search stays wide", queries[1].exact == false)

Reset()
LegacyScan:Browse("Linen Cloth", nil, true)
check("an exact search asks for that name only", #queries == 1 and queries[1].exact == true)

Reset()
canQuery = false
gaveUp = nil
LegacyScan:Browse("Linen Cloth", function(r) gaveUp = r end)
check("it waits while the game is busy", #queries == 0)
canQuery = true
Advance(LegacyScan.POLL + 0.01)
check("and goes once the game is free", #queries == 1 and gaveUp == nil)

Reset()
canQuery = false
gaveUp = nil
LegacyScan:Browse("Linen Cloth", function(r) gaveUp = r end)
Advance(LegacyScan.PAGE_TIMEOUT + 1)
check("a house that stays busy says so", #queries == 0 and gaveUp == false)
canQuery = true

Reset()
local checked
Scanner:ScanItem(SWORD, function(_, _, _, _, _, _, status) checked = status end)
LegacyScan:Browse("Linen Cloth")
check("a price check out steps aside", checked == "superseded")

print("")
print("gear with a random suffix is checked by its own name")

house = { { 1, 5000, SWORD, suffix = 5 }, { 1, 3000, SWORD, suffix = 7 }, { 1, 9000, SWORD, suffix = 5 } }
canQuery, canQueryAll = true, true
Reset()
Scanner.recentItemScans = {}
priceTables[realm] = {}
local owl = "|cff1eff00|Hitem:9999:0:0:0:0:0:5|h[Sword of the Owl]|h|r"
local suffixStatus
Scanner:ScanItem(SWORD, function(_, _, _, _, _, _, status) suffixStatus = status end, { link = owl })
check("it asks for the Owl's own name", #queries == 1 and queries[1].text == "Sword of the Owl"
    and queries[1].exact == true)
Fire()
Advance(LegacyScan.PAGE_SETTLE + 0.1)
check("the answer comes back fresh", suffixStatus == "fresh")
check("the Owl keeps its own cheapest, 50s", Prices:GetSuffixEntry(SWORD, 5) ~= nil
    and Prices:GetSuffixEntry(SWORD, 5).rival == 5000)
check("the Bear is not read as the Owl", Prices:GetSuffixEntry(SWORD, 7) == nil)
check("the item has a price beside it", Prices:Get(SWORD) ~= nil)

-- Sold out: the Owl's rival goes, the item's own price stays.
house = { { 1, 3000, SWORD, suffix = 7 } }
local before = Prices:Get(SWORD).min
queries, timers = {}, {}
Scanner.recentItemScans = {}
Scanner:ScanItem(SWORD, function(_, _, _, _, _, _, status) suffixStatus = status end, { link = owl })
Fire()
Advance(LegacyScan.PAGE_SETTLE + 0.1)
check("none of the Owl left reads empty", suffixStatus == "empty")
check("so there is no Owl to undercut", Prices:GetSuffixEntry(SWORD, 5).rival == nil)
check("and the item's own price is kept", Prices:Get(SWORD).min == before)

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print("")
print(("%d passed, %d failed"):format(passed, failed))
assert(failed == 0, "legacy scan checks failed")
