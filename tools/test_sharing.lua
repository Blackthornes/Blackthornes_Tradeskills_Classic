-- Sharing (on Discord, 2026-10-07): characters between two accounts
-- of one player, and prices within a guild, over addon messages.
--
-- What must hold:
--   1. The wire: escaping, base 36 and chunking come back exactly; a table
--      too big is not sent; a throttled send is tried again, not lost; the
--      "No player named" line is hidden only for a name just whispered.
--   2. Two accounts that each named the other swap their characters, and
--      only the ones that changed the next time.
--   3. Nothing is taken from anyone not named, from anything but a whisper,
--      or over one of this account's own characters; a copy is never sent
--      on; "|" codes are stripped; Share settings decide what goes.
--   4. Forget removes only the copies.
--   5. Guild prices: sent from a recent scan, parsed back exactly, the
--      middle of three guildmates used, a price far from a fresh one of your
--      own refused, your own fresh scan always wins, a stale one gives way,
--      not sent again within the hour or when a guildmate covered it, and
--      the price graph gets the hours you did not scan; an item seen with
--      nothing listed and no market value is left out, not an error.

local saved = {}
for _, name in ipairs({ "time", "GetTime", "UnitName", "C_ChatInfo", "C_Timer", "InCombatLockdown",
                        "IsInGuild", "SendAddonMessage", "ERR_CHAT_PLAYER_NOT_FOUND_S" }) do
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
IsInGuild = function() return true end
ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
SendAddonMessage = nil

--------------------------------------------------------------------------------
-- Clients
--------------------------------------------------------------------------------

local network = {}       -- messages on their way: { from, text, channel, target }
local current            -- the client whose code is running
local throttleNext = 0   -- how many sends to refuse as throttled

C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    SendAddonMessage = function(prefix, text, channel, target)
        -- The server takes "Name-Realm" for a whisper; the realm is not part of
        -- the name these pretend clients go by.
        if type(target) == "string" then target = (target:gsub("%-[^%-]+$", "")) end
        assert(#text <= 255, "a message over 255 bytes went out")
        if throttleNext > 0 then
            throttleNext = throttleNext - 1
            return 3
        end
        network[#network + 1] = { from = current.name, text = text, channel = channel, target = target }
        return 0
    end,
}
UnitName = function() return current.name end

local function NewClient(name, realmKey, surname)
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

    local settings = { linkNames = "", guildPrices = false }
    local priceTable = {}
    ns.db = { characters = {}, postedAuctions = {}, priceHistory = {} }
    ns.Config = {
        Get = function(_, key) return settings[key] end,
        Set = function(_, key, value) settings[key] = value end,
        GetRealmKey = function() return realmKey end,
        GetCharacterKey = function() return "Player-1-" .. name end,
        GetPriceTable = function() return priceTable end,
        ReadSurname = function() return surname end,
    }
    ns.Recipes = {
        ForgetCharacter = function(_, key)
            ns.db.characters[key] = nil
            return true
        end,
    }

    for _, file in ipairs({ "Core/Serialize.lua", "Core/Comm.lua", "Data/Prices.lua",
                            "Data/PriceHistory.lua", "Logic/AccountLink.lua", "Logic/GuildPrices.lua" }) do
        assert(loadfile(lfs_cwd .. "/" .. file))("Blackthornes_TS", ns)
    end

    local client = { name = name, ns = ns, settings = settings }
    current = client
    ns.Comm:OnEnable()
    ns.AccountLink:OnEnable()
    ns.GuildPrices:OnEnable()
    return client
end

local clients = {}

--- Send everything queued and deliver it, until the network is quiet.
local function Run(rounds)
    for _ = 1, rounds or 400 do
        uptime = uptime + 2
        for _, client in ipairs(clients) do
            current = client
            client.ns.Comm:Pump()
        end
        if #network == 0 then
            local busy = false
            for _, client in ipairs(clients) do
                if client.ns.Comm:Pending() > 0 then busy = true end
            end
            if not busy then return end
        end
        local batch = network
        network = {}
        for _, message in ipairs(batch) do
            for _, client in ipairs(clients) do
                local whisperToThem = message.channel == "WHISPER" and message.target == client.name
                local guild = message.channel == "GUILD" and client.guild == true
                if whisperToThem or guild then
                    current = client
                    client.ns.Comm:CHAT_MSG_ADDON("CHAT_MSG_ADDON", "BTSshare", message.text,
                        message.channel, message.from .. "-Realm")
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
print("\nthe wire")
--------------------------------------------------------------------------------

local ana = NewClient("Ana", "Forever-Alliance")
local bob = NewClient("Bob", "Forever-Alliance")
clients = { ana, bob }
local Comm = ana.ns.Comm

local nasty = "a|cff00ff00b\0c\001d\ne\rf\001\002"
check("escape round trip", Comm.Unescape(Comm.Escape(nasty)), nasty)
check("escaped has no pipe", Comm.Escape(nasty):find("|", 1, true), nil)
check("escaped has no NUL", Comm.Escape(nasty):find("\0", 1, true), nil)
check("base 36 round trip", Comm.FromBase36(Comm.ToBase36(1790000000)), 1790000000)
check("base 36 of zero", Comm.ToBase36(0), "0")
check("base 36 refuses junk", Comm.FromBase36("12$"), nil)
check("name key drops the realm", Comm.NameKey("Ana-Some Realm"), "ana")

local Serialize = ana.ns.Serialize
local one = { b = 2, a = 1, [3] = { z = true, y = "x" } }
local two = { [3] = { y = "x", z = true }, a = 1, b = 2 }
check("canonical encoding ignores key order", Serialize.EncodeCanonical(one), Serialize.EncodeCanonical(two))
check("and hashes the same", Comm.Hash(Serialize.EncodeCanonical(one)), Comm.Hash(Serialize.EncodeCanonical(two)))

-- A table over many messages, with throttling in the middle.
local got
bob.ns.Comm:OnTable("X", function(sender, value, channel) got = { sender = sender, value = value, channel = channel } end)
local big = { text = ("Linen Cloth|r "):rep(300), list = {} }
for i = 1, 200 do big.list[i] = i * 7 end
current = ana
local chunks = Comm:SendTable("X", big, "WHISPER", "Bob")
check("a big table takes several messages", chunks > 5, true)
throttleNext = 3
Run()
check("it arrives whole", got and got.value.text, big.text)
check("every number too", got and got.value.list[200], 1400)
check("from the sender", got and got.sender, "Ana-Realm")
check("throttled sends were tried again", Comm.retried >= 1, true)

local huge = { text = ("x"):rep(236 * (Comm.MAX_CHUNKS + 1)) }
check("a table too big is not sent", Comm:SendTable("X", huge, "WHISPER", "Bob"), 0)

-- One sender's stuck transfers cap only that sender's. Eight of Carl's
-- first parts, never finished, used to stop Dora's table from arriving.
do
    local arrived
    bob.ns.Comm:OnTable("X", function(_, value) arrived = value end)
    current = bob
    local b36 = Comm.ToBase36
    for id = 1, bob.ns.Comm.MAX_PARTIAL do
        bob.ns.Comm:CHAT_MSG_ADDON("CHAT_MSG_ADDON", Comm.PREFIX,
            "DX" .. b36(1000 + id) .. "," .. b36(1) .. "," .. b36(2) .. ":stuck", "WHISPER", "Carl-Realm")
    end
    local text = bob.ns.Serialize.Encode({ hello = "Dora" })
    bob.ns.Comm:CHAT_MSG_ADDON("CHAT_MSG_ADDON", Comm.PREFIX,
        "DX" .. b36(1) .. "," .. b36(1) .. "," .. b36(2) .. ":" .. text:sub(1, 3), "WHISPER", "Dora-Realm")
    bob.ns.Comm:CHAT_MSG_ADDON("CHAT_MSG_ADDON", Comm.PREFIX,
        "DX" .. b36(1) .. "," .. b36(2) .. "," .. b36(2) .. ":" .. text:sub(4), "WHISPER", "Dora-Realm")
    check("another sender's table still arrives past one sender's stuck ones", arrived and arrived.hello, "Dora")
    bob.ns.Comm:OnTable("X", nil)
end

-- Hidden only for a name just whispered.
current = ana
Comm:NoteWhisper("Carl")
check("not-found line hidden for a name just whispered",
    Comm.FilterNotFound(nil, "CHAT_MSG_SYSTEM", "No player named 'Carl' is currently playing."), true)
check("but not for anyone else",
    Comm.FilterNotFound(nil, "CHAT_MSG_SYSTEM", "No player named 'Dora' is currently playing."), false)
uptime = uptime + 30
check("nor once it is old",
    Comm.FilterNotFound(nil, "CHAT_MSG_SYSTEM", "No player named 'Carl' is currently playing."), false)

-- Forever: a whisper needs the first and last name, and the sender reads so.
local eve = NewClient("Eve", "Forever-Alliance", "Stone")
check("the name whispers use has the last name", eve.ns.Comm.PlayerName(), "Eve Stone")
check("a sender with my full name is me", eve.ns.Comm.IsMe("Eve Stone"), true)
check("another Eve is not", eve.ns.Comm.IsMe("Eve Rivers"), false)
current = ana
check("without a last name, the first word decides", ana.ns.Comm.IsMe("Ana Whoever"), true)
check("and someone else is not me", ana.ns.Comm.IsMe("Bob Smith"), false)

-- A name the game would not let the addon read (in a dungeon) is asked
-- for again next time, not remembered as "no last name" for the session.
local fay = NewClient("Fay", "Forever-Alliance", "Hill")
local asks = 0
fay.ns.Config.ReadSurname = function()
    asks = asks + 1
    if asks == 1 then error("attempt to compare a secret string value", 0) end
    return "Hill"
end
current = fay
check("a read that raised gives no last name yet", fay.ns.Comm.PlayerName(), "Fay")
check("the next ask gets it", fay.ns.Comm.PlayerName(), "Fay Hill")
check("and it is kept from then on", asks, 2)
fay.ns.Comm.PlayerName()
check("asked no more", asks, 2)

--------------------------------------------------------------------------------
print("\naccounts")
--------------------------------------------------------------------------------

network = {}
ana.ns.db.characters = {
    ["Player-1-Ana"] = {
        name = "Ana", realm = "Realm", class = "Mage", level = 30, gold = 123456,
        professions = { { name = "Tailoring", skillLevel = 150, maxSkillLevel = 225, learned = true } },
        recipes = { [3915] = { name = "Bolt of Wool|r", outputItemID = 2997, quantityMin = 1, quantityMax = 1,
                               skillLineID = 197, cachedAt = 5, reagents = { { itemID = 2592, quantity = 3 } } } },
        inventory = { [2592] = 40 },
        bank = { [2589] = 200 },
    },
    ["Player-1-Ana2"] = { name = "Annie|TInterface\\Icons\\x:0|t", recipes = {}, inventory = { [2770] = 5 } },
    ["Ana-Realm"] = { name = "Old key", recipes = {}, inventory = {} },
    ["Player-9-Linked"] = { name = "Somebody", linkedFrom = "Zed", recipes = {}, inventory = {} },
}
ana.ns.db.postedAuctions = { ["Forever-Alliance"] = { items = {}, byCharacter = {
    ["Player-1-Ana"] = { items = { [2997] = 4 }, updatedAt = clock, listings = { { itemID = 2997, quantity = 4, unit = 900 } } },
} } }
bob.ns.db.characters = {
    ["Player-2-Bob"] = { name = "Bob", recipes = {}, inventory = { [2589] = 1 } },
}

-- Only Ana names the other side: nothing is shared.
ana.settings.linkNames = "Bob"
current = ana
ana.ns.AccountLink:Check()
Run()
check("one-sided: Bob holds nothing of Ana's", bob.ns.db.characters["Player-1-Ana"], nil)
check("and Ana nothing of Bob's", ana.ns.db.characters["Player-2-Bob"], nil)

-- Both name each other.
bob.settings.linkNames = "Ana, Someone Else"
current = ana
ana.ns.AccountLink:Check()
Run()
local copy = bob.ns.db.characters["Player-1-Ana"]
check("Bob now has Ana", copy and copy.name, "Ana")
check("marked as a copy from Ana", copy and copy.linkedFrom, "Ana")
check("with her gold", copy and copy.gold, 123456)
check("her bags", copy and copy.inventory[2592], 40)
check("her bank", copy and copy.bank[2589], 200)
check("her recipe, pipes stripped", copy and copy.recipes[3915].name, "Bolt of Wool")
check("without the read time", copy and copy.recipes[3915].cachedAt, nil)
check("her professions", copy and copy.professions[1].name, "Tailoring")
check("her auctions, under the realm",
    bob.ns.db.postedAuctions["Forever-Alliance"].byCharacter["Player-1-Ana"].items[2997], 4)
check("the second character, texture code stripped", bob.ns.db.characters["Player-1-Ana2"].name,
    "Annie")
check("an old name-realm key is not sent", bob.ns.db.characters["Ana-Realm"], nil)
check("a copy Ana holds is not sent on", bob.ns.db.characters["Player-9-Linked"], nil)
check("Ana has Bob", ana.ns.db.characters["Player-2-Bob"] and ana.ns.db.characters["Player-2-Bob"].linkedFrom, "Bob")
check("Bob's own character untouched", bob.ns.db.characters["Player-2-Bob"].linkedFrom, nil)

-- Nothing changed: the next check sends no characters.
local sentBefore = ana.ns.Comm.sent
clock = clock + 600
current = bob
bob.ns.AccountLink:Check()
Run()
local quiet = ana.ns.Comm.sent - sentBefore
check("nothing changed: Ana only answers the hello and manifest", quiet <= 3, true)

-- A change goes across.
ana.ns.db.characters["Player-1-Ana"].gold = 999
clock = clock + 600
current = bob
bob.ns.AccountLink:Check()
Run()
check("a change is sent", bob.ns.db.characters["Player-1-Ana"].gold, 999)

-- Share settings: Ana stops sharing gold and auctions.
ana.settings.linkShareGold = false
ana.settings.linkShareAuctions = false
clock = clock + 600
current = bob
bob.ns.AccountLink:Check()
Run()
check("gold no longer shared", bob.ns.db.characters["Player-1-Ana"].gold, nil)
check("bags still shared", bob.ns.db.characters["Player-1-Ana"].inventory[2592], 40)
check("her auctions no longer count",
    bob.ns.db.postedAuctions["Forever-Alliance"].byCharacter["Player-1-Ana"], nil)

-- Refusals.
local AccountLink = bob.ns.AccountLink
current = bob
local payload = { guid = "Player-2-Bob", name = "Evil", gold = 1 }
check("over one of my own characters: refused", (AccountLink:Accept("Ana-Realm", payload)), nil)
check("my own character kept", bob.ns.db.characters["Player-2-Bob"].name, "Bob")
check("from someone not named: refused", (AccountLink:Accept("Mallory-Realm", { guid = "Player-7-M", name = "M" })), nil)
check("nothing stored", bob.ns.db.characters["Player-7-M"], nil)
check("a key that is not a GUID: refused", (AccountLink:Accept("Ana-Realm", { guid = "../x", name = "M" })), nil)
bob.ns.AccountLink:OnCharacter("Ana-Realm", { data = { guid = "Player-1-Guild", name = "G" } }, "GUILD")
check("a character over the guild channel is ignored", bob.ns.db.characters["Player-1-Guild"], nil)
check("junk fields are dropped", (AccountLink:Accept("Ana-Realm",
    { guid = "Player-1-Ana3", name = "Ok", inventory = { [1] = "lots", [2] = 3 }, gold = "much", evil = function() end })), true)
check("  a count that is not a number", bob.ns.db.characters["Player-1-Ana3"].inventory[1], nil)
check("  a real count kept", bob.ns.db.characters["Player-1-Ana3"].inventory[2], 3)
check("  gold that is not a number", bob.ns.db.characters["Player-1-Ana3"].gold, nil)
check("  an unknown field", bob.ns.db.characters["Player-1-Ana3"].evil, nil)

-- Forget only removes copies.
local forgotten = AccountLink:Forget()
check("forget removed the copies", forgotten, 3)
check("and kept my own", bob.ns.db.characters["Player-2-Bob"] ~= nil, true)

--------------------------------------------------------------------------------
print("\nguild prices")
--------------------------------------------------------------------------------

network = {}
local carl = NewClient("Carl", "Forever-Alliance")
local dora = NewClient("Dora", "Forever-Alliance")
clients = { ana, bob, carl, dora }
for _, client in ipairs(clients) do
    client.guild = true
    client.settings.guildPrices = true
end
-- Bob tracks Linen Cloth on the price graph.
bob.ns.db.characters = { ["Player-2-Bob"] = { name = "Bob", inventory = {},
    recipes = { [1] = { outputItemID = 2996, reagents = { { itemID = 2589, quantity = 2 } } } } } }

local function Scan(client, prices, at)
    current = client
    local table = client.ns.Prices:GetTable()
    for itemID, price in pairs(prices) do
        table[itemID] = { market = price, min = price - 10, rivalMin = price - 10, seen = at, scans = 1, history = {} }
    end
    client.ns.db.lastFullScanByRealm = { ["Forever-Alliance"] = at }
end

-- Three guildmates, one of them wrong about Linen Cloth.
Scan(ana, { [2589] = 1000, [2592] = 500 }, clock - 60)
Scan(carl, { [2589] = 1100 }, clock - 60)
Scan(dora, { [2589] = 900000 }, clock - 60)

-- Searched with nothing listed and never priced: seen, but no market value.
ana.ns.Prices:GetTable()[4306] = { seen = clock - 60, scans = 1, quantity = 0, history = {} }
-- Sold out in that scan: an old market value, nothing listed.
ana.ns.Prices:GetTable()[4338] = { market = 700, seen = clock - 60, scans = 3, quantity = 0, history = {} }

current = ana
check("Ana shares her scan", (ana.ns.GuildPrices:Share()), true)
check("no market value, or sold out: left out", (select(3, ana.ns.GuildPrices:Batches(clock - 60))), 2)
Run()
current = carl
check("Carl's scan is covered by Ana's", select(2, carl.ns.GuildPrices:Share()), "a guildmate shared one")
carl.ns.GuildPrices.heard = nil
check("without that, Carl shares", (carl.ns.GuildPrices:Share()), true)
current = dora
dora.ns.GuildPrices.heard = nil
dora.ns.GuildPrices:Share()
Run()

current = bob
local GuildPrices = bob.ns.GuildPrices
check("the middle of three is used", (GuildPrices:GetValue(2589)), 1100)
check("the cheapest listing comes too", (GuildPrices:GetValue(2589, "lowest")), 1090)
check("an item from one guildmate", (GuildPrices:GetValue(2592)), 500)
check("rival is never answered", GuildPrices:GetValue(2589, "rival"), nil)
check("Bob has no scan: GetValue uses the guild's", bob.ns.Prices:GetValue(2589), 1100)
check("the price graph got the hour", #bob.ns.PriceHistory:GetPoints(2589), 1)
check("an untracked item is not graphed", #bob.ns.PriceHistory:GetPoints(2592), 0)

current = ana
check("Ana does not keep her own echo", ana.ns.GuildPrices:GetValue(2592), nil)
check("not sent again within the hour", select(2, ana.ns.GuildPrices:Share()), "already shared")

-- What Settings says.
current = bob
check("Bob's status says what came in", GuildPrices:Status(),
    "Got " .. GuildPrices:Count() .. " prices from your guild just now.")
current = ana
check("Ana's says what she shared too",
    ana.ns.GuildPrices:Status():find("You shared 2 prices just now.", 1, true) ~= nil, true)
do
    local fresh = NewClient("Gus", "Forever-Alliance")
    current = fresh
    fresh.settings.guildPrices = true
    check("before anything comes in", fresh.ns.GuildPrices:Status(),
        "No prices from your guild yet. They come in after a guildmate scans the auction house.")
    IsInGuild = function() return false end
    check("out of a guild", fresh.ns.GuildPrices:Status(), "You're not in a guild on this character.")
    IsInGuild = function() return true end
    fresh.settings.guildPrices = false
    check("turned off", fresh.ns.GuildPrices:Status(), "Guild prices are off.")
end

-- A guildmate who logs in after the scan asks, and one guildmate sends it again.
do
    local timers = {}
    local realAfter = C_Timer.After
    C_Timer.After = function(delay, fn) timers[#timers + 1] = { delay = delay, fn = fn, client = current } end
    local fay = NewClient("Fay", "Forever-Alliance")
    fay.guild = true
    fay.settings.guildPrices = true
    clients[#clients + 1] = fay
    timers = {}
    current = fay
    check("Fay asks after logging in", fay.ns.GuildPrices:Ask(), true)
    Run()
    table.sort(timers, function(a, b) return a.delay < b.delay end)
    check("more than one guildmate could answer", #timers >= 2, true)
    for _, timer in ipairs(timers) do
        current = timer.client
        timer.fn()
        Run()
    end
    current = fay
    -- Whoever's wait comes up first answers (the waits are partly random),
    -- so check an item every scanned guildmate has.
    check("Fay has the guild's prices now", fay.ns.GuildPrices:GetValue(2589) ~= nil, true)
    local answered = 0
    for _, client in ipairs(clients) do
        if client.ns.GuildPrices.answeredAt then answered = answered + 1 end
    end
    check("only one guildmate sent it again", answered, 1)
    current = ana
    check("asked again within the hour, nothing goes", (function()
        timers = {}
        for _, client in ipairs(clients) do
            if client.ns.GuildPrices.answeredAt then
                current = client
                client.ns.GuildPrices:OnAsk("Hal-Realm", Comm.ToBase36(0), "GUILD")
            end
        end
        return #timers
    end)(), 0)
    C_Timer.After = realAfter
    -- Fay stays out of what follows.
    clients[#clients] = nil
end

-- Bob's own fresh scan always wins, and a far-off price is refused.
Scan(bob, { [2589] = 1500 }, clock)
current = bob
check("Bob's fresh scan wins", bob.ns.Prices:GetValue(2589), 1500)
do
    -- A fresh scan of his own wins, so the guild is not even asked.
    local asked, real = 0, GuildPrices.GetValue
    GuildPrices.GetValue = function(...) asked = asked + 1; return real(...) end
    bob.ns.Prices:GetValue(2589)
    check("with his own fresh price the guild's is not worked out", asked, 0)
    GuildPrices.GetValue = real
end
GuildPrices:OnPrices("Eve-Realm", Comm.ToBase36(clock) .. ":" .. Comm.ToBase36(2589) .. ","
    .. Comm.ToBase36(15000000) .. ";", "GUILD")
check("a price 10,000 times his own is refused", (GuildPrices:GetValue(2589)), 1100)
-- A guildmate sending item IDs no item has, without end, used to grow the
-- save with every one of them.
GuildPrices:OnPrices("Eve-Realm", Comm.ToBase36(clock) .. ":" .. Comm.ToBase36(GuildPrices.MAX_ITEM_ID + 1) .. ","
    .. Comm.ToBase36(1000) .. ";", "GUILD")
check("an item ID past any item is refused", GuildPrices:GetValue(GuildPrices.MAX_ITEM_ID + 1), nil)
do
    local before = GuildPrices:Count()
    local wasMax = GuildPrices.MAX_STORED
    GuildPrices.MAX_STORED = before + 2
    GuildPrices.stored = nil
    local body = { Comm.ToBase36(clock) .. ":" }
    for id = 50001, 50010 do
        body[#body + 1] = Comm.ToBase36(id) .. "," .. Comm.ToBase36(1000) .. ";"
    end
    GuildPrices:OnPrices("Eve-Realm", table.concat(body), "GUILD")
    check("a realm keeps so many items and no more", GuildPrices:Count(), before + 2)
    check("a kept item still takes a newer price", (GuildPrices:GetValue(50001)), 1000)
    GuildPrices:OnPrices("Eve-Realm", Comm.ToBase36(clock + 1) .. ":" .. Comm.ToBase36(50001) .. ","
        .. Comm.ToBase36(1200) .. ";", "GUILD")
    check("and is updated past the cap", (GuildPrices:GetValue(50001)), 1200)
    GuildPrices.MAX_STORED = wasMax
    GuildPrices.stored = nil
end
bob.settings.staleAfterSeconds = 3600
bob.ns.Prices:GetTable()[2589].seen = clock - 7200
check("once his is stale, the newer guild price wins", bob.ns.Prices:GetValue(2589), 1100)
bob.settings.guildPrices = false
check("guild prices off: his own again", bob.ns.Prices:GetValue(2589), 1500)
bob.settings.guildPrices = true

-- Junk and old messages.
local before = GuildPrices:Count()
GuildPrices:OnPrices("Eve-Realm", "zz$:1,2;", "GUILD")
GuildPrices:OnPrices("Eve-Realm", Comm.ToBase36(clock - 30 * 86400) .. ":" .. Comm.ToBase36(4) .. ",5;", "GUILD")
GuildPrices:OnPrices("Eve-Realm", Comm.ToBase36(clock) .. ":" .. Comm.ToBase36(5) .. ",5;", "WHISPER")
check("junk, month-old and whispered prices are not kept", GuildPrices:Count(), before)

clock = clock + 8 * 86400
check("a week later they are pruned", GuildPrices:Prune() > 0, true)
check("and nothing is left", GuildPrices:Count(), 0)

-- A whisper goes to "Name-Realm" (Classic Era, 2026-10-25: a bare name
-- never arrived for one player).
local oldNormal, oldRealm = GetNormalizedRealmName, GetRealmName
GetNormalizedRealmName, GetRealmName = function() return "Ashkandi" end, nil
check("a bare name gets this realm", Comm.WithRealm("Ana"), "Ana-Ashkandi")
check("a name with a realm is left alone", Comm.WithRealm("Ana-Other"), "Ana-Other")
GetNormalizedRealmName, GetRealmName = nil, function() return "Old Blanchy" end
check("else the realm's name without spaces", Comm.WithRealm("Ana"), "Ana-OldBlanchy")
GetNormalizedRealmName = nil
GetRealmName = nil
check("no realm known: the name as it was", Comm.WithRealm("Ana"), "Ana")
local sentTo
local oldSend = C_ChatInfo.SendAddonMessage
GetNormalizedRealmName = function() return "Ashkandi" end
C_ChatInfo.SendAddonMessage = function(_, _, _, target) sentTo = target return 0 end
Comm.RawSend("x", "WHISPER", "Bob")
check("a whisper is sent with the realm", sentTo, "Bob-Ashkandi")
Comm.RawSend("x", "GUILD")
check("a guild message has no target", sentTo, nil)
C_ChatInfo.SendAddonMessage = oldSend
GetNormalizedRealmName, GetRealmName = oldNormal, oldRealm

--------------------------------------------------------------------------------

for name, value in pairs(saved) do _G[name] = value end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then error(("%d sharing check(s) failed"):format(failed)) end
