-- Fast listing: one search checks the Sell list, then each click lists.
--
-- Asked 2026-10-14: "can we speed up the posting speed on the AH instead of
-- waiting 5 seconds". Every click used to search for its one item, wait for
-- the answer and then ask Yes or No. Now:
--
-- What must hold:
--   1. A price checked moments ago lists on the click: no search, no box.
--   2. A price never checked still goes the old way (search, then the box).
--   3. A listing under what it cost to make lists on the click while selling
--      at a loss is on, and is refused while it is off.
--   4. Unticked, every listing asks first.
--   5. One search checks the whole list (SearchForItemKeys), and its answer
--      makes an item fresh only when the cheapest is someone else's and not
--      far under the usual; a copy with a random suffix is never asked about.
--   6. List all: the first click checks, the next ones list, an item still
--      being confirmed is passed over, and leaving the auction house forgets
--      every check.
--   7. A fresh item's List button never counts down the request spacing.

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

local clock = 1000
CreateFrame = function() return Blank() end
GetTime = function() return clock end
time = function() return 100000 end

local timers = {}
C_Timer = {
    After = function(seconds, fn) timers[#timers + 1] = { seconds = seconds, fn = fn } end,
    NewTicker = function() return { Cancel = noop } end,
    NewTimer = function() return { Cancel = noop } end,
}

local POTION, OIL, RING, CLOAK = 929, 20748, 1500, 1501

local bags
local function FillBags()
    bags = { [0] = {
        { itemID = POTION, stackCount = 5 },
        { itemID = OIL, stackCount = 3 },
        { itemID = RING, stackCount = 1 },
        { itemID = CLOAK, stackCount = 1 },
    } }
end
FillBags()

C_Container = {
    GetContainerNumSlots = function(bag) return bags[bag] and #bags[bag] or 0 end,
    GetContainerItemInfo = function(bag, slot)
        local e = bags[bag] and bags[bag][slot]
        if e then return { itemID = e.itemID, stackCount = e.stackCount, isLocked = e.locked == true } end
    end,
    GetContainerItemLink = function() return nil end,
}
ItemLocation = { CreateFromBagAndSlot = function() return { IsValid = function() return true end } end }

local popup
StaticPopupDialogs = {}
StaticPopup_Show = function(which, text, _, data)
    popup = Blank()
    popup.which, popup.text, popup.data = which, text, data
    return popup
end
StaticPopup_Visible = function(which) return popup and popup.which == which and popup or nil end
StaticPopup_Hide = function(which) if popup and popup.which == which then popup = nil end end

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
local function Fire(event, ...)
    for _, fn in ipairs(handlers[event] or {}) do fn(event, ...) end
end

ns.Print = function(text) said[#said + 1] = text end
ns.Warn = function(text) said[#said + 1] = "WARN " .. text end
ns.PrintRaw, ns.Debug = noop, noop

local settings = { postDuration = 2, verifyPriceBeforePosting = true }
ns.db = {}
ns.Config = {
    Get = function(_, k) return settings[k] end,
    Set = function(_, k, v) settings[k] = v end,
    GetRealmKey = function() return "Realm-Alliance" end,
    GetCharacterKey = function() return "Player-1" end,
}

-- Searches for one item: counted, answered by the test.
local searches, recorded = {}, {}
ns.Scanner = {
    isAuctionHouseOpen = true, isScanning = false,
    IsCommodity = function() return true end,
    ScanItem = function(_, itemID, cb)
        searches[#searches + 1] = { itemID = itemID, cb = cb }
        return true
    end,
    AbandonItemScan = noop,
    RecordPassive = function(_, itemID, market, minBuyout, quantity, rival)
        recorded[itemID] = rival
        return true
    end,
}

local MARKET = { [POTION] = 300, [OIL] = 1000, [RING] = 5000, [CLOAK] = 800 }
ns.Prices = {
    GetValue = function(_, itemID, key)
        if key == "market" then return MARKET[itemID] end
        if key == "rival" then return recorded[itemID] end
    end,
    GetScanValue = function(_, itemID, key) if key == "market" then return MARKET[itemID] end end,
    Get = function() return {} end,
    IsCredible = function(price) return type(price) == "number" and price > 0 end,
}
ns.Inventory = {
    GetCarriedBags = function() return { 0 } end,
    GetBagCount = function(_, itemID)
        for _, e in ipairs(bags[0]) do if e.itemID == itemID then return e.stackCount end end
        return 0
    end,
}
ns.Recipes = { GetAccountWide = function() return {} end }
ns.Queue = { GetReservedItems = function() return {} end }
local costs = {}
ns.Cost = { FindAnyRecipeForItem = function(_, itemID) return costs[itemID] and itemID or nil end }
ns.Profit = {
    ChoosePostPrice = function(_, itemID) return recorded[itemID] or MARKET[itemID], "undercut" end,
    Analyse = function(_, recipeID) return { costPerUnit = costs[recipeID] } end,
}

-- The queue: requests are kept, and sent when the test says.
local queued = {}
ns.AHQueue = {
    Yield = noop, NoteSend = noop, PRIORITY = { urgent = 10 }, MIN_SPACING = 1.2,
    SecondsUntilReady = function() return 1.2, "spacing out requests to the auction house" end,
    Request = function(_, request) queued[#queued + 1] = request; return true end,
}
local function SendQueued()
    local list = queued
    queued = {}
    for _, request in ipairs(list) do request.send() end
end

local posted, keysSearched, browseRows = {}, nil, {}
C_AuctionHouse = {
    PostCommodity = function(_, _, quantity, price) posted[#posted + 1] = { quantity = quantity, price = price } end,
    MakeItemKey = function(itemID) return { itemID = itemID, itemSuffix = 0 } end,
    SearchForItemKeys = function(keys) keysSearched = keys end,
    GetBrowseResults = function() return browseRows end,
}

ns.UI = { RefreshActiveTab = noop, UpdatePostButton = noop }

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
    said, popup, searches, posted, queued, recorded, costs = {}, nil, {}, {}, {}, {}, {}
    keysSearched, browseRows = nil, {}
    Posting.confirming, Posting.pending, Posting.others, Posting.requesting = nil, nil, nil, {}
    Posting:ForgetChecks()
    ns.Scanner.isAuctionHouseOpen = true
    settings.fastListing = nil
    settings.allowPostingAtALoss = nil
    FillBags()
end

print("")
print("a price checked moments ago")

Reset()
recorded[POTION] = 290
Posting:NoteChecked(POTION)
Posting:Request(POTION, 5, 290)
check("it lists on the click", #posted, 1)
check("at the checked price", posted[1] and posted[1].price, 290)
check("with no search", #searches, 0)
check("and no Yes or No", popup, nil)

print("")
print("a price never checked")

Reset()
Posting:Request(POTION, 5, 290)
check("it searches first", #searches, 1)
check("nothing listed yet", #posted, 0)
searches[1].cb(POTION, 290, 290, 5, true, {}, "fresh")
check("then asks, as before", popup ~= nil, true)

print("")
print("under what it cost to make")

Reset()
settings.allowPostingAtALoss = true
costs[POTION] = 500
recorded[POTION] = 290
Posting:NoteChecked(POTION)
Posting:Request(POTION, 5, 290)
check("selling at a loss on: it lists on the click", #posted, 1)
check("and no Yes or No", popup, nil)

Reset()
settings.allowPostingAtALoss = false
costs[POTION] = 500
recorded[POTION] = 290
Posting:NoteChecked(POTION)
Posting:Request(POTION, 5, 290)
check("selling at a loss off: nothing listed on the click", #posted, 0)
if searches[1] then searches[1].cb(POTION, 290, 290, 5, true, {}, "recent") end
check("and no box after the check", popup, nil)
check("nothing listed after it either", #posted, 0)
settings.allowPostingAtALoss = true

print("")
print("fast listing unticked")

Reset()
settings.fastListing = false
recorded[POTION] = 290
Posting:NoteChecked(POTION)
Posting:Request(POTION, 5, 290)
check("nothing lists on the click", #posted, 0)

print("")
print("a check gone stale")

Reset()
recorded[POTION] = 290
Posting:NoteChecked(POTION)
clock = clock + Posting.FRESH_FOR + 1
check("two minutes on, it is not fresh", Posting:IsFresh(POTION), false)
clock = clock + 100

print("")
print("one search for the whole list")

Reset()
local lines = {
    { itemID = POTION }, { itemID = OIL }, { itemID = RING }, { itemID = CLOAK },
    { itemID = 1502, link = "|Hitem:1502::::::21|h[Ring of the Monkey]|h" },
}
local started, count = Posting:CheckAll(lines)
check("it goes out", started, true)
check("asking about four (not the suffix copy)", count, 4)
check("one request is queued", #queued, 1)
SendQueued()
check("as one search", keysSearched and #keysSearched, 4)

ns.Auctions:GetTable().prices = { [OIL] = 950, [CLOAK] = 900 }
browseRows = {
    { itemKey = { itemID = POTION, itemSuffix = 0 }, minPrice = 280, totalQuantity = 40 },
    -- The cheapest holds one of yours, and yours is that price: can't tell.
    { itemKey = { itemID = OIL, itemSuffix = 0 }, minPrice = 950, containsOwnerItem = true },
    -- A lone one far under the usual: the one-item search judges that.
    { itemKey = { itemID = RING, itemSuffix = 0 }, minPrice = 900, totalQuantity = 1 },
    -- Holds one of yours, but yours is dearer: the cheapest is a rival's.
    { itemKey = { itemID = CLOAK, itemSuffix = 0 }, minPrice = 790, containsOwnerItem = true },
    -- Not asked about.
    { itemKey = { itemID = 4242, itemSuffix = 0 }, minPrice = 10 },
}
check("found two of them", Posting:OnCheckResults(), 2)
check("the potion is fresh", Posting:IsFresh(POTION), true)
check("its price recorded", recorded[POTION], 280)
check("the cloak too (its cheapest is someone else's)", Posting:IsFresh(CLOAK), true)
check("not the oil (the cheapest may be yours)", Posting:IsFresh(OIL), false)
check("not the ring (far under the usual)", Posting:IsFresh(RING), false)
check("nothing not asked about", recorded[4242], nil)
check("it says the clicks list now", Said("Each click on List all now lists one"), true)

print("")
print("List all")

do
    -- The drawer's List all, against this Posting.
    local Widgets = { CreateButton = function() return Blank() end }
    ns.Widgets, ns.Theme = Widgets, { MeasureText = function() return 50 end }
    local PostPanel = { list = nil }
    ns.PostPanel = PostPanel
    local chunk = assert(loadfile(lfs_cwd .. "/UI/PostPanel.lua"))
    local ok = pcall(chunk, "Blackthornes_TS", ns)
    PostPanel = ns.PostPanel

    if ok and PostPanel and PostPanel.ListNext then
        Reset()
        local shown = {
            { itemID = POTION, unitPrice = 290, postQuantity = 5 },
            { itemID = OIL, unitPrice = 990, postQuantity = 3 },
        }
        PostPanel.shownLines = shown
        PostPanel.list = nil

        check("before it, the button says it checks prices", Posting:WouldCheckAll(shown[1], shown), true)
        PostPanel:ListNext()
        check("the first click checks the list", #queued, 1)
        check("once asked, it says List Next again", Posting:WouldCheckAll(shown[1], shown), false)
        check("and lists nothing", #posted, 0)
        SendQueued()
        browseRows = {
            { itemKey = { itemID = POTION, itemSuffix = 0 }, minPrice = 280, totalQuantity = 40 },
            { itemKey = { itemID = OIL, itemSuffix = 0 }, minPrice = 980, totalQuantity = 9 },
        }
        Posting:OnCheckResults()

        PostPanel:ListNext()
        check("the next click lists the potion", #posted, 1)
        check("at the checked price", posted[1] and posted[1].price, 280)

        PostPanel:ListNext()
        check("the next one passes over it and lists the oil", #posted, 2)
        check("at its checked price", posted[2] and posted[2].price, 980)

        PostPanel:ListNext()
        check("both settling: nothing listed twice", #posted, 2)
        check("and it says it is waiting", Said("waiting for your last listing"), true)

        settings.fastListing = false
        check("fast listing unticked: never Check Prices", Posting:WouldCheckAll({ itemID = 4243 }, { { itemID = 4243 } }), false)
        settings.fastListing = nil

        ns.Scanner.isAuctionHouseOpen = false
        Fire("AUCTION_HOUSE_CLOSED")
        check("leaving forgets the checks", Posting:IsFresh(POTION), false)
        check("away from the auction house: never Check Prices", Posting:WouldCheckAll(shown[1], shown), false)
    else
        check("the drawer loads for this test", ok, true)
    end
end

print("")
print("the List button's countdown")

Reset()
Posting:NoteChecked(POTION)
check("a fresh item does not count down the spacing", (Posting:SecondsUntilPostable(POTION)), 0)
check("one not checked still does", (Posting:SecondsUntilPostable(OIL)) > 0, true)

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print("")
print(("%d passed, %d failed"):format(passed, failed))
assert(failed == 0, "fast listing checks failed")
