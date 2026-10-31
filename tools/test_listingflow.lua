-- Listing from a click to the auction house, outside WoW.
--
-- What must hold:
--   1. A price under what the item cost to make is refused before the
--      confirmation, not after Yes (with selling at a loss off, the default).
--   2. A confirmation still up when the auction house closes goes with it, so
--      its Yes cannot list later at a price checked minutes before.
--   3. A second click on the same item while its check is out does not say
--      "interrupted, click it again": the newer check brings up the dialog.
--   4. The auction house closing with a price check waiting in the queue
--      brings up no confirmation out in the world.
--   5. A new listing bought within seconds still reads as listed, not as
--      refused by the auction house.
--   6. A reagent the queue needs some of is still offered on the whole-bag
--      lists, less the number the queue needs.

-- Tests share one Lua state, so every global replaced here is put back,
-- including the ones that were not set at all.
local GLOBALS = { "CreateFrame", "C_Container", "ItemLocation", "GetTime", "time", "C_Timer",
    "StaticPopupDialogs", "StaticPopup_Show", "StaticPopup_Hide", "StaticPopup_Visible",
    "C_AuctionHouse" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local function noop() end

local function Blank()
    return setmetatable({}, { __index = function(_, k)
        if type(k) == "string" and k:match("^%u") then return noop end
    end })
end

CreateFrame = function() return Blank() end
GetTime = function() return 1000 end
time = function() return 100000 end

local timers = {}
C_Timer = {
    After = function(seconds, fn) timers[#timers + 1] = { seconds = seconds, fn = fn } end,
    NewTicker = function() return { Cancel = noop } end,
    NewTimer = function() return { Cancel = noop } end,
}

local ITEM, LINEN = 4321, 2589

-- One stack of 5 of the crafted item and 200 Linen Cloth.
local bags = { [0] = { { itemID = ITEM, stackCount = 5 }, { itemID = LINEN, stackCount = 200 } } }
C_Container = {
    GetContainerNumSlots = function(bag) return bags[bag] and #bags[bag] or 0 end,
    GetContainerItemInfo = function(bag, slot)
        local e = bags[bag] and bags[bag][slot]
        if e then return { itemID = e.itemID, stackCount = e.stackCount, isLocked = false } end
    end,
}
ItemLocation = { CreateFromBagAndSlot = function() return { IsValid = function() return true end } end }

-- The game's popups, as far as these checks need them.
local popup
StaticPopupDialogs = {}
StaticPopup_Show = function(which, text, _, data)
    popup = Blank()
    popup.which, popup.text, popup.data = which, text, data
    return popup
end
StaticPopup_Visible = function(which) return popup and popup.which == which and popup or nil end
StaticPopup_Hide = function(which)
    if popup and popup.which == which then
        local dialog = StaticPopupDialogs[which]
        if dialog and dialog.OnHide then dialog.OnHide(popup) end
        popup = nil
    end
end

local said = {}
local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = noop

local handlers = {}
ns.RegisterEvent = function(owner, event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], fn)
    return true
end
local function Fire(event, ...)
    for _, fn in ipairs(handlers[event] or {}) do fn(event, ...) end
end

ns.Print = function(text) said[#said + 1] = text end
ns.Warn = function(text) said[#said + 1] = "WARN " .. text end
ns.PrintRaw, ns.Debug = noop, noop

local settings = { postDuration = 2, verifyPriceBeforePosting = true, askBeforeListing = true }
ns.db = {}
ns.Config = {
    Get = function(_, k) return settings[k] end,
    Set = function(_, k, v) settings[k] = v end,
    GetRealmKey = function() return "Realm-Alliance" end,
    GetCharacterKey = function() return "Player-1" end,
}

-- The price check: the next answer is handed over by the test.
local checks = {}
ns.Scanner = {
    isAuctionHouseOpen = true, isScanning = false,
    IsCommodity = function() return true end,
    ScanItem = function(_, itemID, cb)
        -- A newer search for the same thing replaces the older one.
        for _, check in ipairs(checks) do
            if not check.done then
                check.done = true
                check.cb(itemID, nil, nil, nil, nil, nil, "superseded")
            end
        end
        checks[#checks + 1] = { itemID = itemID, cb = cb }
        return true
    end,
    AbandonItemScan = noop,
}
local function Answer(status)
    local check = checks[#checks]
    check.done = true
    check.cb(check.itemID, 300, 300, 5, true, {}, status or "fresh")
end

ns.Prices = {
    GetValue = function(_, _, key) if key == "market" then return 600 end if key == "rival" then return 301 end end,
    Get = function() return {} end,
}
ns.Inventory = {
    GetCarriedBags = function() return { 0 } end,
    GetBagCount = function(_, itemID) return itemID == LINEN and 200 or 5 end,
}
ns.Recipes = { GetAccountWide = function() return { [77] = { recipeID = 77, outputItemID = ITEM } } end }
ns.Queue = { GetReservedItems = function() return { [LINEN] = 6 } end }
ns.Cost = { FindRecipeForItem = function(_, itemID) return itemID == ITEM and 77 or nil end }
ns.Cost.FindAnyRecipeForItem = ns.Cost.FindRecipeForItem
ns.Profit = {
    ChoosePostPrice = function() return 300, "undercut" end,      -- 3s each
    Analyse = function() return { costPerUnit = 500 } end,         -- 5s to make
}
ns.AHQueue = { Yield = noop, PRIORITY = { urgent = 10 }, MIN_SPACING = 1.2,
    SecondsUntilReady = function() return 0 end }

C_AuctionHouse = { PostCommodity = function() said[#said + 1] = "POSTED" end }

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
    for _, line in ipairs(said) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

local function Reset()
    said, popup, checks = {}, nil, {}
    Posting.confirming, Posting.pending, Posting.requesting = nil, nil, {}
    ns.Scanner.isAuctionHouseOpen = true
end

print("")
print("under what it cost to make")

Reset()
Posting:Request(ITEM, 5, 300)
Answer("fresh")
check("the List It or Skip box asks", popup ~= nil, true)
check("and nothing is listed yet", Said("POSTED"), false)

Reset()
settings.verifyPriceBeforePosting = false
Posting:Request(ITEM, 5, 300)
check("without a price check, it asks too", popup ~= nil, true)
settings.verifyPriceBeforePosting = true

Reset()
settings.allowPostingAtALoss = true
Posting:Request(ITEM, 5, 300)
Answer("fresh")
check("with selling at a loss on, it asks", popup ~= nil, true)
settings.allowPostingAtALoss = nil

print("")
print("the auction house closing")

Reset()
settings.allowPostingAtALoss = true
Posting:Request(ITEM, 5, 300)
Answer("fresh")
check("the confirmation is up", popup ~= nil, true)
ns.Scanner.isAuctionHouseOpen = false
Fire("AUCTION_HOUSE_CLOSED")
check("closing the auction house takes it down", popup, nil)
check("with nothing left to list", Posting.confirming, nil)
check("and says so", Said("was not listed"), true)

Reset()
Fire("AUCTION_HOUSE_CLOSED")
check("closed with nothing up, nothing is said", #said, 0)
settings.allowPostingAtALoss = nil

print("")
print("a second click while the first is checking")

Reset()
settings.allowPostingAtALoss = true
Posting:Request(ITEM, 5, 300)
Posting:Request(ITEM, 5, 300)
check("the first is not called interrupted", Said("interrupted"), false)
Answer("fresh")
check("the second brings up the confirmation", popup ~= nil, true)

Reset()
Posting:Request(ITEM, 5, 300)
Posting:Request(LINEN, 5, 30)
check("another item's search taking over still says so", Said("interrupted"), true)
settings.allowPostingAtALoss = nil

print("")
print("a check waiting in the queue when the auction house closes")

do
    -- The real queue: the check waits its turn, and the close flushes it.
    local queueNS = {}
    queueNS.NewModule = function(name) local m = {}; queueNS[name] = m; return m end
    local closeHandler
    queueNS.RegisterEvent = function(_, event, fn)
        if event == "AUCTION_HOUSE_CLOSED" then closeHandler = fn end
        return true
    end
    queueNS.RegisterCommand, queueNS.Debug, queueNS.Print = noop, noop, noop
    queueNS.Util = ns.Util
    queueNS.Scanner = ns.Scanner

    local chunk = assert(loadfile(lfs_cwd .. "/Core/AHQueue.lua"))
    chunk("Blackthornes_TS", queueNS)
    if queueNS.AHQueue.OnEnable then queueNS.AHQueue:OnEnable() end

    Reset()
    local stillOpen
    queueNS.AHQueue.Flush = function() stillOpen = ns.Scanner.isAuctionHouseOpen end
    queueNS.AHQueue.StopDraining = noop
    if closeHandler then closeHandler() end
    check("the queue says closed before giving up its requests", stillOpen, false)
end

print("")
print("a new listing bought within seconds")

do
    local owned = {}
    C_AuctionHouse.GetNumOwnedAuctions = function() return #owned end
    C_AuctionHouse.GetOwnedAuctionInfo = function(index) return owned[index] end

    Reset()
    ns.Auctions:ReadOwned()
    Posting.pending = { itemID = ITEM, quantity = 5, unitPrice = 300, verifying = true,
        postedBefore = 0, idsBefore = ns.Auctions:GetOwnedIDs(ITEM) or {} }

    -- Read back: the new auction is there, already sold.
    owned[1] = { auctionID = 9001, itemKey = { itemID = ITEM }, quantity = 5, status = 1, unitPrice = 300 }
    ns.Auctions:ReadOwned({ final = true })
    check("it reads as listed", Said("listed item") or Said("listed " .. ITEM), true)
    check("not as refused", Said("did not appear"), false)
    check("and is not counted as still for sale", ns.Auctions:GetTable().items[ITEM], nil)
end

print("")
print("reagents the queue needs some of")

do
    local line
    for _, entry in ipairs(Posting:GetPostable({ includeAll = true })) do
        if entry.itemID == LINEN then line = entry end
    end
    check("the whole-bag list still offers Linen Cloth", line ~= nil, true)
    check("less the 6 the queue needs", line and line.count, 194)
end

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print("")
print(("%d passed, %d failed"):format(passed, failed))
assert(failed == 0, "listing checks failed")
