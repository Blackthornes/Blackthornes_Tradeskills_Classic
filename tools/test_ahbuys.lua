-- Auction house buys waiting in the mail count toward the queue.
--
-- What must hold:
--   1. A commodity bought on the auction house lowers "still needed" at once,
--      though it sits in the mailbox, and only once the client says it went
--      through (the purchase event, or the gold leaving). A failed one never
--      counts.
--   2. Taking it from the mail stops it counting, so it is never counted in
--      the bags and the mail at once. Taking an expired auction's mail of the
--      same item leaves it alone.
--   3. A reading of the mailbox that no longer shows it stops it counting,
--      unless it is too new to have arrived.
--   4. Where the list already counts the mailbox, nothing is counted twice.
--   5. A buyout counts its listing's quantity; a bid below the buyout does not.
--   6. "Count mail as stock" off leaves it out, like the rest of the mail.

-- Tests share one Lua state, so every global replaced here is put back,
-- including the ones that were not set at all.
local GLOBALS = { "time", "GetMoney", "GetInboxHeaderInfo", "AUCTION_WON_MAIL_SUBJECT",
    "C_AuctionHouse", "GetAuctionItemInfo" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local function noop() end

local clock = 100000
time = function() return clock end
local money = 50000
GetMoney = function() return money end
AUCTION_WON_MAIL_SUBJECT = "Auction won: %s"

local CLOTH, BOLT, BAG = 2589, 2996, 4240
local BOLT_RECIPE, BAG_RECIPE = 2963, 3755

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand, ns.RegisterEvent = noop, noop
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = noop, noop, noop, noop
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.Util = { HasFunction = function(name) return type(_G[name]) == "function" end }

local settings = { valueOwnedMaterials = true, autoQueueSubCrafts = true,
    suggestOtherCharacters = false, countMailAsStock = true }
ns.Config = {
    Get = function(_, key) return settings[key] end,
    GetCharacterKey = function() return "me" end,
}

local RECIPES = {
    [BOLT_RECIPE] = { recipeID = BOLT_RECIPE, name = "Bolt of Linen Cloth", outputItemID = BOLT,
        quantityMin = 1, quantityMax = 1, reagents = { { itemID = CLOTH, quantity = 2 } } },
    [BAG_RECIPE] = { recipeID = BAG_RECIPE, name = "Linen Bag", outputItemID = BAG,
        quantityMin = 1, quantityMax = 1, reagents = { { itemID = BOLT, quantity = 3 } } },
}
local record = {}
ns.Recipes = {
    GetAny = function(_, id) return RECIPES[id], "me" end,
    GetAll = function() return RECIPES end,
    GetCharacterRecord = function() return record end,
}

local bags, bank, mail = {}, {}, {}
local function MailCount(id)
    if settings.countMailAsStock == false then return 0 end
    return mail[id] or 0
end
ns.Inventory = {
    GetBagCount = function(_, id) return bags[id] or 0 end,
    GetBankCount = function(_, id) return bank[id] or 0 end,
    GetMailCount = function(_, id) return MailCount(id) end,
    GetOwnedCount = function(_, id) return (bags[id] or 0) + (bank[id] or 0) + MailCount(id) end,
    GetAltTotal = function() return 0 end,
}

local LOWEST = { [CLOTH] = 10, [BOLT] = 50 }
ns.Prices = { GetValue = function(_, id) return LOWEST[id] end }
ns.Vendor = { GetUnitPrice = function() return nil end, IsLimited = function() return false end }
ns.Profit = { Analyse = function() return nil end }
ns.db = { queue = {} }

-- The inbox as the client shows it: { subject, attachments = { {itemID, quantity} } }.
local inbox = {}
GetInboxHeaderInfo = function(index)
    local m = inbox[index]
    if not m then return nil end
    return nil, nil, "Auction House", m.subject
end
ns.Mail = {
    SubjectPattern = function(format)
        local escaped = format:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
        return "^" .. escaped:gsub("%%%%s", "(.+)")
    end,
    ReadAttachment = function(_, index, slot)
        local m = inbox[index]
        local a = m and m.attachments[slot]
        if a then return a.itemID, a.quantity end
    end,
}

assert(loadfile(lfs_cwd .. "/Logic/Cost.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Queue.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/AHBuys.lua"))("Blackthornes_TS", ns)
local Queue, AHBuys = ns.Queue, ns.AHBuys

local passed, failed = 0, 0

local function check(label, got, want)
    local ok = got == want
    if ok then passed = passed + 1 else failed = failed + 1 end
    print(string.format("  %-60s %-8s %s", label, tostring(got), ok and "ok" or
        ("WRONG, wanted " .. tostring(want))))
end

local function Line(itemID)
    for _, line in ipairs(Queue:GetShoppingList()) do
        if line.itemID == itemID then return line end
    end
end

local function Reset()
    record, bags, bank, mail, inbox = {}, {}, {}, {}, {}
    AHBuys.awaiting = nil
    AHBuys:ResetMatcher()
    ns.db.queue = {}
    clock = 100000
end

local function Buy(itemID, quantity)
    AHBuys:OnConfirmCommodities(itemID, quantity)
    AHBuys:Confirm()
end

print("a commodity bought and still in the mail")

do
    Reset()
    Queue:Add(BOLT_RECIPE, 10)          -- 20 Linen
    check("twenty needed before buying", Line(CLOTH).shortfall, 20)

    AHBuys:OnConfirmCommodities(CLOTH, 12)
    check("nothing counts until the client says it went through", Line(CLOTH).shortfall, 20)
    AHBuys:Confirm()
    local line = Line(CLOTH)
    check("bought twelve: eight still needed", line.shortfall, 8)
    check("the row knows twelve are bought", line.bought, 12)
    check("and counts them as in the mail", line.inMail, 12)

    AHBuys:OnConfirmCommodities(CLOTH, 8)
    AHBuys:Fail()
    check("a failed purchase never counts", Line(CLOTH).shortfall, 8)

    -- No purchase event on this client: the gold leaving says it.
    AHBuys:OnConfirmCommodities(CLOTH, 8)
    money = money - 80
    AHBuys:OnMoney()
    line = Line(CLOTH)
    check("paid for: nothing more to buy", line.shortfall, 0)
    check("and the row sends you to the mailbox", line.needsMailTrip, true)
    AHBuys:Confirm()
    check("a late event does not count it twice", AHBuys:GetPending(CLOTH), 20)

    AHBuys:OnConfirmCommodities(CLOTH, 5)
    clock = clock + AHBuys.CONFIRM_WINDOW + 1
    AHBuys:Confirm()
    check("an answer long after the ask is not trusted", AHBuys:GetPending(CLOTH), 20)

    -- An item buyout knows its price: a deposit leaving is not the buy.
    clock = 100000
    AHBuys:Await(CLOTH, 5, 77, 500)
    money = money - 100
    AHBuys:OnMoney()
    check("less gold leaving than the buyout confirms nothing", AHBuys:GetPending(CLOTH), 20)
    money = money - 400
    AHBuys:OnMoney()
    check("the buyout leaving does", AHBuys:GetPending(CLOTH), 25)
end

print("")
print("a quantity that is not one")

do
    Reset()
    local entry, why = Queue:Add(BOLT_RECIPE, "1e999")
    check("an endless number is refused", entry, nil)
    check("and says so", why, "that is not a quantity")
    check("nothing was queued", #Queue:GetAll(), 0)
    Queue:Add(BOLT_RECIPE, "2.7")
    check("a plain one is floored", Queue:GetAll()[1].quantity, 2)
end

print("")
print("taking it from the mail")

do
    Reset()
    Queue:Add(BOLT_RECIPE, 10)
    Buy(CLOTH, 20)
    inbox = {
        { subject = "Auction expired: Linen Cloth", attachments = { { itemID = CLOTH, quantity = 20 } } },
        { subject = "Auction won: Linen Cloth", attachments = { { itemID = CLOTH, quantity = 20 } } },
    }

    AHBuys:OnTake(1, 1)
    check("an expired auction's Linen leaves the purchase alone", AHBuys:GetPending(CLOTH), 20)

    AHBuys:OnTake(2)                    -- the whole mail, as Open All does
    check("asking for the take settles nothing yet", AHBuys:GetPending(CLOTH), 20)
    -- Full bags: the server refuses, the attachment stays, the box changes.
    AHBuys:SettleTakes()
    check("a take the server refused leaves the purchase waiting", AHBuys:GetPending(CLOTH), 20)
    -- Room made; the attachment goes and the inbox says so.
    inbox[2].attachments = {}
    AHBuys:SettleTakes()
    bags[CLOTH] = 40
    local line = Line(CLOTH)
    check("the purchase taken stops counting", AHBuys:GetPending(CLOTH), 0)
    check("counted once, in the bags", line.have, 40)
    check("nothing left to settle", AHBuys.takes, nil)

    -- Open All on a mail with two attachments: they leave one at a time.
    Reset()
    Queue:Add(BOLT_RECIPE, 10)
    Buy(CLOTH, 20)
    inbox = { { subject = "Auction won: Linen Cloth",
        attachments = { { itemID = CLOTH, quantity = 12 }, { itemID = CLOTH, quantity = 8 } } } }
    AHBuys:OnTake(1)
    inbox[1].attachments[1] = nil
    AHBuys:SettleTakes()
    check("the first attachment taken is struck off", AHBuys:GetPending(CLOTH), 8)
    check("the second is still waited on", AHBuys.takes and #AHBuys.takes, 1)
    inbox[1].attachments[2] = nil
    AHBuys:SettleTakes()
    check("then the second", AHBuys:GetPending(CLOTH), 0)
end

print("")
print("a reading of the mailbox")

do
    Reset()
    Queue:Add(BOLT_RECIPE, 10)
    Buy(CLOTH, 20)
    clock = clock + 60
    Buy(CLOTH, 5)

    -- Read 10 minutes on; the first has had time to arrive, the second not.
    clock = clock + 120
    AHBuys:Reconcile({}, true, false)
    check("a purchase too new to have arrived is kept", AHBuys:GetPending(CLOTH), 25)

    clock = clock + AHBuys.GRACE
    local mails = { { subject = "Auction won: Linen Cloth", attachments = { { itemID = CLOTH, quantity = 20 } } } }
    AHBuys:Reconcile(mails, false, false)
    check("an unfinished reading changes nothing", AHBuys:GetPending(CLOTH), 25)
    AHBuys:Reconcile(mails, true, true)
    check("nor one with more mail held back", AHBuys:GetPending(CLOTH), 25)
    AHBuys:Reconcile(mails, true, false)
    check("what the mailbox no longer shows stops counting", AHBuys:GetPending(CLOTH), 20)

    AHBuys:Reconcile({}, true, false)
    check("an empty box clears the rest", AHBuys:GetPending(CLOTH), 0)
    check("and nothing is left in the saved list", #record.ahBuys, 0)
end

print("")
print("where the list already counts the mailbox")

do
    -- Bolts are made for the bag, so the bolts' row counts the mail.
    Reset()
    bags[CLOTH] = 40
    Buy(BOLT, 6)
    Queue:Add(BAG_RECIPE, 5)            -- 15 bolts: 6 bought, 9 to make
    local made = 0
    for _, entry in ipairs(Queue:GetAll()) do
        if entry.isDependency and entry.recipeID == BOLT_RECIPE then made = made + entry.quantity end
    end
    check("only the bolts not bought are made", made, 9)
    check("bought bolts not yet read in the mail count", Line(BOLT).inMail, 6)
    check("so none are left to buy", Line(BOLT).shortfall, 0)

    -- The mailbox read after: the six are in its count now.
    mail[BOLT] = 6
    record.mailAt = clock + 1
    clock = clock + 2
    check("and are not counted a second time once it shows them", Line(BOLT).inMail, 6)

    -- An expired auction's bolts were there too.
    mail[BOLT] = 9
    check("the mailbox's own count wins when it holds more", Line(BOLT).inMail, 9)
end

print("")
print("an item auction")

do
    Reset()
    local key = { itemID = CLOTH }
    C_AuctionHouse = {
        GetNumItemSearchResults = function() return 2 end,
        GetItemSearchResultInfo = function(_, i)
            return ({ { auctionID = 71, quantity = 20, buyoutAmount = 400, itemKey = key },
                      { auctionID = 72, quantity = 7, buyoutAmount = 200, itemKey = key } })[i]
        end,
    }
    AHBuys:OnItemResults(key)

    AHBuys:OnPlaceBid(72, 150)
    AHBuys:Confirm(72)
    check("a bid below the buyout is not a purchase", AHBuys:GetPending(CLOTH), 0)

    AHBuys:OnPlaceBid(72, 200)
    AHBuys:Confirm(71)
    check("another auction's answer is not ours", AHBuys:GetPending(CLOTH), 0)
    AHBuys:Confirm(72)
    check("a buyout counts its listing's quantity", AHBuys:GetPending(CLOTH), 7)
end

print("")
print("mail not counted as stock")

do
    Reset()
    Queue:Add(BOLT_RECIPE, 10)
    Buy(CLOTH, 12)
    settings.countMailAsStock = false
    check("purchases in the mail are left out too", Line(CLOTH).shortfall, 20)
    settings.countMailAsStock = true
    check("and come back when it is on", Line(CLOTH).shortfall, 8)
end

print("")
print("kept small")

do
    Reset()
    for _ = 1, AHBuys.MAX_KEPT + 5 do Buy(CLOTH, 1) end
    check("never more than the cap kept", #record.ahBuys, AHBuys.MAX_KEPT)
    clock = clock + AHBuys.MAX_AGE + 1
    AHBuys:Prune()
    check("and nothing older than auction mail lasts", #record.ahBuys, 0)
end

print("")
print("the drawer's Buy list hears of a buy at once")

do
    -- A player saw Light Leather still short after the last stack was
    -- bought (2026-10-29): bought items go to the mail, so nothing in the
    -- bags moved to redraw the drawer.
    Reset()
    local told = 0
    ns.PostPanel = { OnPurchase = function() told = told + 1 end }
    GetAuctionItemInfo = function()
        -- name, texture, count, ..., buyout (10th), ..., itemID (17th)
        return "Linen Cloth", nil, 5, nil, nil, nil, nil, nil, nil, 400,
            nil, nil, nil, nil, nil, nil, CLOTH
    end
    AHBuys:OnLegacyBid("list", 1, 400)
    check("the buyout alone tells it nothing", told, 0)
    money = money - 400
    AHBuys:OnMoney()
    check("the gold leaving counts the buy", AHBuys:GetPending(CLOTH), 5)
    check("and tells the drawer straight away", told >= 1, true)
    ns.PostPanel = nil
end

ns.db.queue = {}
for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print("")
if failed > 0 then
    error(string.format("FAIL -- %d of %d auction buy checks wrong", failed, passed + failed))
end
print(string.format("PASS -- auction buys in the mail count toward the queue (%d checks)", passed))
