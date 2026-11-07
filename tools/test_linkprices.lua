-- Prices across the account link (the owner, 2026-11-07): when two
-- accounts name each other, each one's newest auction scan reaches the
-- other, with no tick box of its own.
--
-- What must hold:
--   1. Not linked: nothing goes out and nothing is used.
--   2. Linked: a scan on one account shows up in the other's prices.
--   3. The newer scan wins, either way round.
--   4. Only an account's own prices go out: nothing taken is sent on.
--   5. A stranger's prices and another realm's are never taken.
--   6. Every message fits in one addon message.
--   7. Old prices are let go.

local saved = {}
for _, name in ipairs({ "time", "GetTime", "UnitName", "C_ChatInfo", "C_Timer", "InCombatLockdown",
                        "IsInGuild", "SendAddonMessage", "ERR_CHAT_PLAYER_NOT_FOUND_S",
                        "UnitFactionGroup" }) do
    saved[name] = _G[name]
end

local passed, failed = 0, 0
local function check(label, got, want)
    if got == want then
        passed = passed + 1
        print(("  ok    %-60s %s"):format(label, tostring(got)))
    else
        failed = failed + 1
        print(("  FAIL  %-60s got %s, want %s"):format(label, tostring(got), tostring(want)))
    end
end

local clock, uptime = 1790000000, 1000
time = function() return clock end
GetTime = function() return uptime end
C_Timer = {
    NewTicker = function() return { Cancel = function() end } end,
    After = function() end,
}
InCombatLockdown = function() return false end
IsInGuild = function() return false end
ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
SendAddonMessage = nil
UnitFactionGroup = function() return "Alliance" end

local network = {}
local current
local longest = 0

C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    SendAddonMessage = function(prefix, text, channel, target)
        if #text > longest then longest = #text end
        network[#network + 1] = { from = current.name, text = text, channel = channel, target = target }
        return 0
    end,
}
UnitName = function() return current.name end

local function NewClient(name, realmKey, partners)
    local ns = {}
    ns.VERSION = "1.0"
    ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
    ns.Util = {
        Comma = function(n) return tostring(n) end,
        FormatAgeAgo = function() return "just now" end,
    }
    ns.NewModule = function(module) local m = {}; ns[module] = m; return m end
    ns.RegisterCommand = function() end
    ns.RegisterEvent = function() end
    ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end
    ns.L = setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

    local settings = { linkNames = partners or "" }
    local priceTable = {}
    ns.db = { characters = {}, postedAuctions = {}, priceHistory = {} }
    ns.Config = {
        Get = function(_, key) return settings[key] end,
        Set = function(_, key, value) settings[key] = value end,
        GetRealmKey = function() return realmKey end,
        GetCharacterKey = function() return "Player-1-" .. name end,
        GetPriceTable = function() return priceTable end,
        ReadSurname = function() return nil end,
    }
    ns.Recipes = { ForgetCharacter = function() return true end }

    local client = { name = name, ns = ns, settings = settings, realmKey = realmKey }
    current = client
    for _, file in ipairs({ "Core/Serialize.lua", "Core/Comm.lua", "Data/Prices.lua",
                            "Data/PriceHistory.lua", "Logic/AccountLink.lua" }) do
        assert(loadfile(lfs_cwd .. "/" .. file))("Blackthornes_TS", ns)
    end
    ns.Comm:OnEnable()
    ns.AccountLink:OnEnable()
    return client
end

local clients = {}
local byName = {}

local function Run(rounds)
    for _ = 1, rounds or 400 do
        uptime = uptime + 3
        local busy = false
        for _, client in ipairs(clients) do
            current = client
            client.ns.Comm:Pump()
            if client.ns.Comm:Pending() > 0 then busy = true end
        end
        local batch = network
        network = {}
        for _, message in ipairs(batch) do
            local to = byName[tostring(message.target):lower():gsub("%-.*", "")]
            if to and message.channel == "WHISPER" then
                current = to
                to.ns.Comm:CHAT_MSG_ADDON("CHAT_MSG_ADDON", "BTSshare", message.text, "WHISPER",
                    message.from .. "-Realm", message.from, 0, 0, "")
            end
        end
        if not busy and #batch == 0 then return end
    end
end

local function Scan(client, prices, at)
    current = client
    local table_ = client.ns.Prices:GetTable()
    for itemID, price in pairs(prices) do
        table_[itemID] = { market = price, min = price - 10, rivalMin = price - 10, seen = at, scans = 1,
                           history = {}, quantity = 5 }
    end
    client.ns.db.lastFullScanByRealm = client.ns.db.lastFullScanByRealm or {}
    client.ns.db.lastFullScanByRealm[client.realmKey] = at
end

local function Value(client, itemID, which)
    current = client
    return client.ns.Prices:GetValue(itemID, which)
end

local function Check(client)
    current = client
    client.ns.AccountLink:Check()
    Run()
end

local function Add(client)
    clients[#clients + 1] = client
    byName[client.name:lower()] = client
end

--------------------------------------------------------------------------------
print("\nnot linked")
--------------------------------------------------------------------------------

local ana = NewClient("Ana", "forever-alliance", "")
local bob = NewClient("Bob", "forever-alliance", "")
Add(ana); Add(bob)
Scan(ana, { [2589] = 1000, [2592] = 500 }, clock - 60)
current = ana
check("not linked: prices are off", ana.ns.AccountLink:PricesOn(), false)
check("not linked: the manifest says off", ana.ns.AccountLink:PricesHash(), "off")
Check(ana); Check(bob)
check("not linked: Bob has no price", Value(bob, 2589), nil)
check("not linked: nothing kept", bob.ns.db.linkedPrices, nil)

--------------------------------------------------------------------------------
print("\nlinked")
--------------------------------------------------------------------------------

ana.settings.linkNames = "Bob"
bob.settings.linkNames = "Ana"
current = ana
check("linked: prices are on with no tick box", ana.ns.AccountLink:PricesOn(), true)
check("the manifest names the scan and realm", ana.ns.AccountLink:PricesHash():match("@(.+)$"),
    "forever-alliance")
Check(ana); Check(bob); Check(ana)
check("Bob gets Ana's market price", Value(bob, 2589), 1000)
check("and her cheapest listing", Value(bob, 2589, "lowest"), 990)
check("never the rival price", Value(bob, 2589, "rival"), nil)
check("both items came", Value(bob, 2592), 500)
current = bob
local count = bob.ns.AccountLink:PricesHeld("Ana")
check("Bob holds two prices from Ana", count, 2)
check("every message fits", longest <= 255, true)

--------------------------------------------------------------------------------
print("\nthe newer scan wins")
--------------------------------------------------------------------------------

clock = clock + 600
Scan(bob, { [2589] = 1200 }, clock - 30)
check("Bob's own newer scan wins", Value(bob, 2589), 1200)
clock = clock + 600
Scan(ana, { [2589] = 800 }, clock - 30)
Check(ana); Check(bob); Check(ana)
check("then Ana's newer one wins", Value(bob, 2589), 800)

--------------------------------------------------------------------------------
print("\nnothing is sent on")
--------------------------------------------------------------------------------

current = bob
local batches = bob.ns.AccountLink:PriceBatches(0)
local sent = table.concat(batches, "")
check("Bob sends only his own item", sent:find(bob.ns.Comm.ToBase36(2592) .. ",", 1, true), nil)
check("and his own price", sent:find(bob.ns.Comm.ToBase36(2589) .. ",", 1, true) ~= nil, true)

--------------------------------------------------------------------------------
print("\nstrangers and other realms")
--------------------------------------------------------------------------------

current = ana
local before = Value(ana, 3575)
ana.ns.AccountLink.partners = ana.ns.AccountLink.partners or {}
ana.ns.AccountLink:OnPrices("Carl-Realm", ana.ns.Comm.ToBase36(clock) .. ":"
    .. ana.ns.Comm.ToBase36(3575) .. ",5k,,;", "WHISPER")
check("a stranger's prices are refused", Value(ana, 3575), before)

current = ana
ana.ns.AccountLink.partners.bob.pricesAskedAt = clock - 31 * 60
ana.ns.AccountLink:OnPrices("Bob-Realm", ana.ns.Comm.ToBase36(clock) .. ":"
    .. ana.ns.Comm.ToBase36(3576) .. ",5k,,;", "WHISPER")
check("prices never asked for are refused", Value(ana, 3576), nil)

local dora = NewClient("Dora", "forever-horde", "Ana")
Add(dora)
ana.settings.linkNames = "Bob, Dora"
Scan(dora, { [4000] = 700 }, clock - 30)
Check(dora); Check(ana); Check(dora)
check("another realm's prices are not taken", Value(ana, 4000), nil)

--------------------------------------------------------------------------------
print("\nunlinked, and pruning")
--------------------------------------------------------------------------------

bob.settings.linkNames = ""
check("unlinked: Ana's prices are not used", Value(bob, 2592), nil)
bob.settings.linkNames = "Ana"
check("linked again: they come back", Value(bob, 2592), 500)

clock = clock + 8 * 24 * 3600
current = bob
bob.ns.AccountLink:PrunePrices()
check("a week on, old prices are let go", bob.ns.db.linkedPrices, nil)

for name, value in pairs(saved) do _G[name] = value end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then error(("%d checks failed"):format(failed)) end
