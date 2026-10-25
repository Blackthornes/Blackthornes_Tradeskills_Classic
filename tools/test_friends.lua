-- Friends (the owner, 2026-10-25): a player shared with a friend through
-- "Your Other Account" and got the friend's characters in their own list.
-- Logic/GuildCrafters.lua (Friends:) and Logic/AccountLink.lua.
--
-- What must hold:
--   1. Two players who name each other under Friends swap recipe lists by
--      whisper, with Guild Crafters off and no guild; each shows the other
--      as a friend who can make it, never as a guildmate.
--   2. Someone not named is never heard, and never told anything.
--   3. Nothing is saved: no character of a friend joins the list.
--   4. A name under Friends is never an account link partner, and copies it
--      sent before are set aside, not deleted; your own and your other
--      account's stay.
--   5. A friend away, or taken off the list, is no longer named.

local saved = {}
for _, name in ipairs({ "time", "GetTime", "UnitName", "C_ChatInfo", "C_Timer", "InCombatLockdown",
                        "IsInGuild", "SendAddonMessage", "ERR_CHAT_PLAYER_NOT_FOUND_S",
                        "GetNumGuildMembers", "GetGuildRosterInfo" }) do
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
    After = function(_, fn) fn() end,
}
InCombatLockdown = function() return false end
local inGuild = false
IsInGuild = function() return inGuild end
GetNumGuildMembers = function() return 0 end
GetGuildRosterInfo = function() return nil end
ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
SendAddonMessage = nil

local network = {}
local current

C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    SendAddonMessage = function(prefix, text, channel, target)
        if type(target) == "string" then target = (target:gsub("%-[^%-]+$", "")) end
        assert(#text <= 255, "a message over 255 bytes went out")
        network[#network + 1] = { from = current.full, text = text, channel = channel, target = target }
        return 0
    end,
}
UnitName = function() return current.first end

local function NewClient(first, last, recipes)
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

    local settings = { linkNames = "", friendNames = "" }
    local priceTable = {}
    ns.db = { characters = {}, postedAuctions = {}, priceHistory = {} }
    ns.Config = {
        Get = function(_, key) return settings[key] end,
        Set = function(_, key, value) settings[key] = value end,
        GetRealmKey = function() return "Era-Alliance" end,
        GetCharacterKey = function() return "Player-1-" .. first end,
        GetPriceTable = function() return priceTable end,
        ReadSurname = function() return last end,
    }
    local known = {}
    for _, id in ipairs(recipes) do known[id] = { name = "r" .. id } end
    ns.Recipes = {
        GetAll = function() return known end,
        IsDropped = function() return false end,
        ForgetCharacter = function(_, key)
            ns.db.characters[key] = nil
            return true
        end,
    }

    local client = { first = first, full = first .. " " .. last, ns = ns, settings = settings, known = known }
    current = client
    for _, file in ipairs({ "Core/Serialize.lua", "Core/Comm.lua", "Data/Prices.lua",
                            "Data/PriceHistory.lua", "Logic/AccountLink.lua", "Logic/GuildCrafters.lua" }) do
        assert(loadfile(lfs_cwd .. "/" .. file))("Blackthornes_TS", ns)
    end
    ns.Comm:OnEnable()
    ns.AccountLink:OnEnable()
    ns.GuildCrafters:OnEnable()
    return client
end

local clients = {}
local heardBy = {}

local function Deliver(client, message)
    current = client
    heardBy[client.full] = (heardBy[client.full] or 0) + 1
    client.ns.Comm:CHAT_MSG_ADDON("CHAT_MSG_ADDON", "BTSshare", message.text, message.channel, message.from)
end

local function Run(rounds)
    for _ = 1, rounds or 400 do
        uptime = uptime + 3
        for _, client in ipairs(clients) do
            current = client
            client.ns.Comm:Pump()
        end
        local batch = network
        network = {}
        for _, message in ipairs(batch) do
            for _, client in ipairs(clients) do
                if message.channel == "GUILD" and inGuild and client.full ~= message.from then
                    Deliver(client, message)
                elseif message.channel == "WHISPER"
                    and client.full:lower() == tostring(message.target):lower() then
                    Deliver(client, message)
                end
            end
        end
        local busy = #network > 0
        for _, client in ipairs(clients) do
            if client.ns.Comm:Pending() > 0 then busy = true end
        end
        if not busy and #batch == 0 then return end
    end
end

local function Friends(client, recipeID)
    current = client
    return table.concat(client.ns.GuildCrafters:WhoCanMakeFriends(recipeID), ", ")
end
local function Guild(client, recipeID)
    current = client
    return table.concat(client.ns.GuildCrafters:WhoCanMake(recipeID), ", ")
end
local function Tick(client)
    current = client
    client.ns.GuildCrafters:Tick()
end

--------------------------------------------------------------------------------
print("\ntwo friends who name each other")
--------------------------------------------------------------------------------

local ana = NewClient("Ana", "Smith", { 18560, 3914 })
local bob = NewClient("Bob", "Jones", { 18560, 1000123 })
local eve = NewClient("Eve", "Gray", { 7777 })
clients = { ana, bob, eve }

current = ana; ana.ns.GuildCrafters:SetFriends("Bob Jones")
current = bob; bob.ns.GuildCrafters:SetFriends("  Ana Smith ")
current = eve; eve.ns.GuildCrafters:SetFriends("Ana Smith")
check("the box is saved trimmed", bob.settings.friendNames, "Ana Smith")
check("Guild Crafters is still off", ana.settings.guildCrafters, nil)

Tick(ana); Tick(bob); Tick(eve)
Run()
check("Ana sees Bob as a friend for Mooncloth", Friends(ana, 18560), "Bob Jones")
check("Bob sees Ana for the other", Friends(bob, 3914), "Ana Smith")
check("a Forever recipe ID comes through", Friends(ana, 1000123), "Bob Jones")
check("never yourself", Friends(bob, 1000123), "")
check("a friend is never on the guild line", Guild(ana, 18560), "")

--------------------------------------------------------------------------------
print("\nonly names typed")
--------------------------------------------------------------------------------

check("Ana never hears Eve", Friends(ana, 7777), "")
check("Ana keeps nothing for Eve", ana.ns.GuildCrafters.held["eve gray"], nil)
check("Eve gets no list from Ana", Friends(eve, 18560), "")
current = ana
ana.ns.GuildCrafters:OnList("Eve Gray", { h = "x", r = "60f" }, "WHISPER")
check("a list Eve pushes is ignored", Friends(ana, 7777), "")
ana.ns.GuildCrafters:OnHello("Eve Gray", "abc:1", "GUILD")
check("a guild hello from Eve is ignored while Guild Crafters is off", ana.ns.GuildCrafters.held["eve gray"], nil)
check("nothing is saved", next(ana.ns.db.characters), nil)

--------------------------------------------------------------------------------
print("\nnever your other account")
--------------------------------------------------------------------------------

current = ana
ana.settings.linkNames = "Bob Jones, Cara Lee"
local partners = ana.ns.AccountLink:GetPartners()
check("a friend is left out of Your Other Account", #partners, 1)
check("your own other account stays", partners[1] and partners[1].key, "cara lee")
check("a friend's whisper is no partner", ana.ns.AccountLink:PartnerFor("Bob Jones"), nil)

ana.ns.db.characters["Player-1-Ana"] = { name = "Ana" }
ana.ns.db.characters["Player-9-Bob"] = { name = "Bob", linkedFrom = "Bob Jones", recipes = { [1] = {} } }
ana.ns.db.characters["Player-9-Bobalt"] = { name = "Bobalt", linkedFrom = "Bob Jones" }
ana.ns.db.characters["Player-8-Cara"] = { name = "Cara", linkedFrom = "Cara Lee" }
check("two copies set aside", ana.ns.AccountLink:SetAsideFriends(), 2)
check("the friend's character left the list", ana.ns.db.characters["Player-9-Bob"], nil)
check("and was kept, not deleted", ana.ns.db.friendCopies["Player-9-Bob"].name, "Bob")
check("its recipes kept too", ana.ns.db.friendCopies["Player-9-Bob"].recipes[1] ~= nil, true)
check("your own stays", ana.ns.db.characters["Player-1-Ana"].name, "Ana")
check("your other account's stays", ana.ns.db.characters["Player-8-Cara"].name, "Cara")
check("a second time moves nothing", ana.ns.AccountLink:SetAsideFriends(), 0)

--------------------------------------------------------------------------------
print("\nguild and friends together")
--------------------------------------------------------------------------------

inGuild = true
for _, client in ipairs(clients) do
    current = client
    client.ns.GuildCrafters:SetOn(true)
    Run()
end
check("Bob is still a friend, not a guildmate", Friends(ana, 18560), "Bob Jones")
check("the guild line has Eve, not Bob", Guild(ana, 7777), "Eve Gray")
check("Bob is not on Ana's guild line", Guild(ana, 18560), "")
current = ana
ana.ns.GuildCrafters:SetOn(false)
check("turning the guild off keeps friends", Friends(ana, 18560), "Bob Jones")
check("and lets the guild go", Guild(ana, 7777), "")
inGuild = false

--------------------------------------------------------------------------------
print("\naway, and taken off")
--------------------------------------------------------------------------------

current = ana
ana.ns.Comm.onOffline("bob jones")
check("a friend away is not named", Friends(ana, 18560), "")
current = bob
bob.ns.GuildCrafters.friendHello = {}
Tick(bob)
Run()
check("a new hello brings them back", Friends(ana, 18560), "Bob Jones")
current = ana
ana.ns.GuildCrafters:SetFriends("")
check("taken off the list: not named", Friends(ana, 18560), "")
check("and let go", ana.ns.GuildCrafters.held["bob jones"], nil)

for name, value in pairs(saved) do _G[name] = value end
print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then error(("%d check(s) failed"):format(failed)) end
