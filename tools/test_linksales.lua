-- Share Sales (2026-11-07): one account's own sales show on the other
-- account's Sales and Stats tabs, with both sides ticked.
--
-- Loom, on the second account, sold some wool and had a bolt expire. Bob,
-- on the first account, sold some wool too. With Share Sales ticked on
-- both sides, Bob's ledger reads both; with it off on either side, only
-- his own. A sale sent twice counts once, nothing Bob took from Loom is
-- ever sent back out, and no buyer's name leaves Loom's account.
--
-- Drives the real AccountLink.lua and Mail.lua.

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end

local clock = 2000000
time = function() return clock end
GetTime = function() return clock end

local BOLT, WOOL = 2997, 2592
local BOB, ALT, LOOM, FAR = "Player-1-BOB", "Player-1-ALT", "Player-2-LOOM", "Player-2-FAR"
local BOB_REALM, LOOM_REALM = "foreverrealm7pve-horde", "foreverrealm3pve-horde"

ns.Util = { IsBoundOnPickup = function() return false end }

local settings = { linkShareSales = true, linkNames = "Loom" }
local currentKey, currentRealm = BOB, BOB_REALM
ns.Config = {
    Get = function(_, key) return settings[key] end,
    GetCharacterKey = function() return currentKey end,
    GetRealmKey = function() return currentRealm end,
}

ns.Comm = {
    NameKey = function(name) return type(name) == "string" and name:lower():gsub("%-.*", "") or nil end,
    IsMe = function() return false end,
    Hash = function(text) return #text end,
}

local forgotten = {}
ns.Recipes = {
    GetAll = function() return {} end,
    GetAny = function() end,
    GetCharacterName = function(_, key) return ns.db.characters[key].name end,
    ForgetCharacter = function(_, guid) forgotten[guid] = true; ns.db.characters[guid] = nil end,
}

ns.Inventory = {
    GetBagCount = function() return 0 end,
    GetBankCount = function() return 0 end,
    GetMailCount = function() return 0 end,
    GetOwnedCount = function() return 0 end,
    GetAltTotal = function() return 0 end,
}

assert(loadfile(lfs_cwd .. "/Data/Mail.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/AccountLink.lua"))("Blackthornes_TS", ns)

local Mail, AccountLink = ns.Mail, ns.AccountLink

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- Loom's account, logged in as Loom.
local function loomAccount()
    currentKey, currentRealm = LOOM, LOOM_REALM
    Mail.mergedEntries = nil
    ns.db = {
        characters = {
            [LOOM] = { name = "Loom", surname = "Weaver", realm = "Forever Realm 3 PvE", faction = "Horde", recipes = {} },
            [FAR] = { name = "Far", realm = "Elsewhere", faction = "Horde", recipes = {} },
        },
        mailLedger = {
            [LOOM_REALM] = { seen = {}, entries = {
                { t = 100, kind = "sold", who = LOOM, itemID = WOOL, name = "Wool Cloth",
                  quantity = 20, net = 950, gross = 1000, cut = 50, deposit = 10, buyer = "Somebody" },
                { t = 200, kind = "expired", who = LOOM, itemID = BOLT, name = "Bolt of Woolen Cloth", quantity = 5 },
                { t = 300, kind = "removed", who = LOOM, itemID = BOLT, name = "Bolt of Woolen Cloth", quantity = 1 },
                -- Far's, not Loom's: never in Loom's payload.
                { t = 250, kind = "sold", who = FAR, itemID = WOOL, quantity = 1, net = 40 },
                -- Something Loom once took from a partner: never sent on.
                { t = 260, kind = "sold", who = LOOM, itemID = WOOL, quantity = 1, net = 30, linked = true },
                -- Not a sale, refund or cancel.
                { t = 270, kind = "bought", who = LOOM, itemID = WOOL, quantity = 1, net = 30 },
            } },
        },
    }
end

-- Bob's account, logged in as Bob, with a sale of his own.
local function bobAccount()
    currentKey, currentRealm = BOB, BOB_REALM
    Mail.mergedEntries = nil
    ns.db = {
        characters = {
            [BOB] = { name = "Bob", realm = "Forever Realm 7 PvE", faction = "Horde", recipes = {} },
            [ALT] = { name = "Alt", realm = "Forever Realm 7 PvE", faction = "Horde", recipes = {} },
        },
        mailLedger = {
            [BOB_REALM] = { seen = {}, entries = {
                { t = 150, kind = "sold", who = BOB, itemID = WOOL, name = "Wool Cloth", quantity = 10, net = 500 },
            } },
        },
    }
end

print("\nwhat goes out")

loomAccount()
local sales = AccountLink:OwnSales(LOOM)
local list = sales and sales[LOOM_REALM]
check("Loom's own sales go out", list and #list == 3)
check("oldest first", list and list[1].t == 100 and list[3].t == 300)
check("never a buyer's name", list and list[1].buyer == nil)
check("with what it paid", list and list[1].net == 950 and list[1].gross == 1000
    and list[1].cut == 50 and list[1].deposit == 10 and list[1].quantity == 20)
local kinds = {}
for _, sale in ipairs(list or {}) do kinds[sale.kind] = true end
check("sold, expired and cancelled", kinds.sold and kinds.expired and kinds.removed and not kinds.bought)
check("nothing taken from a partner is sent on", (function()
    for _, sale in ipairs(list or {}) do if sale.t == 260 then return false end end
    return true
end)())
check("another character's sales are its own", AccountLink:OwnSales(FAR)[LOOM_REALM][1].t == 250)

local payload = AccountLink:Payload(LOOM, ns.db.characters[LOOM])
check("the payload carries them", payload.sales and #payload.sales[LOOM_REALM] == 3)

settings.linkShareSales = false
check("untick it and no sales go out", AccountLink:Payload(LOOM, ns.db.characters[LOOM]).sales == nil)
settings.linkShareSales = nil
check("it is off unless ticked", AccountLink:Payload(LOOM, ns.db.characters[LOOM]).sales == nil)
settings.linkShareSales = true

local entries = ns.db.mailLedger[LOOM_REALM].entries
for i = 1, 300 do
    entries[#entries + 1] = { t = 1000 + i, kind = "sold", who = LOOM, itemID = WOOL, quantity = 1, net = 1 }
end
local capped = AccountLink:OwnSales(LOOM)[LOOM_REALM]
check("at most MAX_SALES go out", #capped == AccountLink.MAX_SALES)
check("the newest ones", capped[#capped].t == 1300)
for _ = 1, 300 do table.remove(entries) end

print("\nwhat is taken")

bobAccount()
check("Bob takes Loom", AccountLink:Accept("Loom", payload, 1) == true)
local held = ns.db.linkedSales and ns.db.linkedSales[BOB_REALM] and ns.db.linkedSales[BOB_REALM][LOOM]
check("filed under Bob's own realm", held ~= nil and ns.db.linkedSales[LOOM_REALM] == nil)
check("kept apart from Bob's own ledger", #ns.db.mailLedger[BOB_REALM].entries == 1)
check("each marked as Loom's and shared", held.entries[1].who == LOOM and held.entries[1].linked == true)

AccountLink:Accept("Loom", payload, 2)
check("sent again, it counts once", #ns.db.linkedSales[BOB_REALM][LOOM].entries == 3)

local doubled = { guid = LOOM, name = "Loom", sales = { [LOOM_REALM] = {
    { t = 100, kind = "sold", itemID = WOOL, quantity = 20, net = 950 },
    { t = 100, kind = "sold", itemID = WOOL, quantity = 20, net = 950 },
} } }
AccountLink:Accept("Loom", doubled, 3)
check("the same sale twice in one send counts once", #ns.db.linkedSales[BOB_REALM][LOOM].entries == 1)

local junk = { guid = LOOM, name = "Loom", sales = { [LOOM_REALM] = {
    { t = 100, kind = "stolen", itemID = WOOL, net = 5 },
    { kind = "sold", itemID = WOOL, net = 5 },
    { t = 100, kind = "sold", net = 5 },
    { t = 100, kind = "sold", itemID = WOOL, net = "lots" },
    { t = 100, kind = "sold", itemID = WOOL, net = -5, quantity = 0, buyer = "Somebody", who = BOB },
    "nonsense",
}, [12] = { { t = 1, kind = "sold", itemID = WOOL } } } }
AccountLink:Accept("Loom", junk, 4)
local cleaned = ns.db.linkedSales[BOB_REALM] and ns.db.linkedSales[BOB_REALM][LOOM]
check("junk is dropped", cleaned and #cleaned.entries == 1)
local kept = cleaned and cleaned.entries[1]
check("a bad number is dropped, never trusted", kept and kept.net == nil and kept.quantity == nil)
check("and a buyer's name is never kept", kept and kept.buyer == nil and kept.who == LOOM)

settings.linkShareSales = false
AccountLink:Accept("Loom", payload, 5)
check("unticked here, nothing is kept", ns.db.linkedSales[BOB_REALM] == nil
    or ns.db.linkedSales[BOB_REALM][LOOM] == nil)
settings.linkShareSales = true
AccountLink:Accept("Loom", payload, 6)

check("one of Bob's own characters is never overwritten",
    AccountLink:Accept("Loom", { guid = ALT, name = "Alt", sales = payload.sales }, 7) == nil
    and (ns.db.linkedSales[BOB_REALM][ALT] == nil))

print("\nBob's Sales tab")

local merged = Mail:Entries()
check("both accounts' entries", #merged == 4)
check("in time order", merged[1].t == 100 and merged[2].t == 150 and merged[3].t == 200 and merged[4].t == 300)
check("read again, nothing is built twice", Mail:Entries() == merged)

local summary = Mail:GetSummary(WOOL)
check("wool sold on both accounts", summary.sold == 2 and summary.soldUnits == 30 and summary.net == 1450)
local bolts = Mail:GetSummary(BOLT)
check("Loom's bolt expired and one was cancelled", bolts.expired == 1 and bolts.cancelled == 1)
check("Recent sales show Loom's too", Mail:GetRecent(10)[1].t == 300)

ns.db.sellThroughRolledAt = { [BOB_REALM] = 500 }
check("Loom's sales were never in Bob's carried-over history", Mail:GetSummary(WOOL).sold == 1
    and Mail:GetSummary(WOOL).net == 950)
ns.db.sellThroughRolledAt = nil

settings.linkShareSales = false
check("unticked here, only Bob's own", #Mail:Entries() == 1 and Mail:GetSummary(WOOL).sold == 1)
settings.linkShareSales = true

local own = ns.db.mailLedger[BOB_REALM].entries
own[#own + 1] = { t = 400, kind = "sold", who = BOB, itemID = WOOL, quantity = 1, net = 60 }
check("a new sale of Bob's shows at once", #Mail:Entries() == 5 and Mail:Entries()[5].t == 400)

print("\nasking again and letting go")

ns.db.characters[LOOM].linkHash = 6
AccountLink:AskAgain()
check("ticking it asks for Loom again", ns.db.characters[LOOM].linkHash == nil)

ns.db.characters[LOOM].linkedFrom = nil
AccountLink.salesVersion = AccountLink.salesVersion + 1
check("a character no longer linked counts for nothing", #Mail:Entries() == 2)
ns.db.characters[LOOM].linkedFrom = "Loom"
AccountLink.salesVersion = AccountLink.salesVersion + 1

AccountLink:Forget("Loom")
check("forgetting Loom lets go of the sales", forgotten[LOOM]
    and (ns.db.linkedSales[BOB_REALM] == nil or ns.db.linkedSales[BOB_REALM][LOOM] == nil))
check("and Bob's own stay", #Mail:Entries() == 2)

print(("\n%d checks passed"):format(checks))
