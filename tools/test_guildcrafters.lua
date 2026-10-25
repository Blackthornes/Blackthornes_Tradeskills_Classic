-- Guildmates who can make a craft (a player asked, the owner said guild
-- only, 2026-10-24): Logic/GuildCrafters.lua.
--
-- What must hold:
--   1. Off by default: nothing goes out and nothing is taken.
--   2. On: a hello goes to the guild, and guildmates swap recipe lists by
--      whisper; WhoCanMake names the ones who know a recipe, by full name.
--   3. Only the GUILD channel's hellos count, and a whisper is heard only
--      from someone whose hello came first.
--   4. Lists are checked: junk IDs are dropped, and nothing is saved.
--   5. A guildmate not heard from in a while, or shown offline on the
--      roster, is not named.
--   6. A changed recipe list goes out again; turning it off forgets all.

local saved = {}
for _, name in ipairs({ "time", "GetTime", "UnitName", "C_ChatInfo", "C_Timer", "InCombatLockdown",
                        "IsInGuild", "SendAddonMessage", "ERR_CHAT_PLAYER_NOT_FOUND_S",
                        "GetNumGuildMembers", "GetGuildRosterInfo", "ChatFrame_SendTell" }) do
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
IsInGuild = function() return true end
ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
SendAddonMessage = nil

local network = {}
local current
local roster = {}

C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    SendAddonMessage = function(prefix, text, channel, target)
        -- The server takes "Name-Realm" for a whisper; the realm is not part of
        -- the name these pretend clients go by.
        if type(target) == "string" then target = (target:gsub("%-[^%-]+$", "")) end
        assert(#text <= 255, "a message over 255 bytes went out")
        network[#network + 1] = { from = current.full, text = text, channel = channel, target = target }
        return 0
    end,
}
UnitName = function() return current.first end
GetNumGuildMembers = function() return #roster end
GetGuildRosterInfo = function(index)
    local row = roster[index]
    return row[1], "Member", 1, 30, "Mage", "Zone", "", "", row[2]
end

local function NewClient(first, last, recipes)
    local ns = {}
    ns.VERSION = "1.0"
    ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
    ns.NewModule = function(module) local m = {}; ns[module] = m; return m end
    ns.RegisterCommand = function() end
    ns.RegisterEvent = function() end
    ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end

    local settings = {}
    ns.db = { characters = {} }
    ns.Config = {
        Get = function(_, key) return settings[key] end,
        Set = function(_, key, value) settings[key] = value end,
        GetRealmKey = function() return "Forever-Alliance" end,
        GetCharacterKey = function() return "Player-1-" .. first end,
        ReadSurname = function() return last end,
    }
    local known = {}
    for _, id in ipairs(recipes) do known[id] = { name = "r" .. id } end
    ns.Recipes = {
        GetAll = function() return known end,
        IsDropped = function() return false end,
    }

    local client = { first = first, full = first .. " " .. last, ns = ns, settings = settings, known = known }
    current = client
    for _, file in ipairs({ "Core/Serialize.lua", "Core/Comm.lua", "Logic/GuildCrafters.lua" }) do
        assert(loadfile(lfs_cwd .. "/" .. file))("Blackthornes_TS", ns)
    end
    ns.Comm:OnEnable()
    ns.GuildCrafters:OnEnable()
    return client
end

local clients = {}
local whispers, guildSent = 0, 0

local function Deliver(client, message)
    current = client
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
            if message.channel == "GUILD" then
                guildSent = guildSent + 1
                for _, client in ipairs(clients) do
                    if client.full ~= message.from then Deliver(client, message) end
                end
            elseif message.channel == "WHISPER" then
                whispers = whispers + 1
                for _, client in ipairs(clients) do
                    if client.full:lower() == tostring(message.target):lower() then Deliver(client, message) end
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

local function Names(client, recipeID)
    current = client
    return table.concat(client.ns.GuildCrafters:WhoCanMake(recipeID), ", ")
end

--------------------------------------------------------------------------------
print("\noff by default")
--------------------------------------------------------------------------------

local ana = NewClient("Ana", "Smith", { 18560, 3914 })
local bob = NewClient("Bob", "Jones", { 18560, 1000123 })
local cara = NewClient("Cara", "Lee", { 3914 })
clients = { ana, bob, cara }

check("the setting starts unset", ana.settings.guildCrafters, nil)
current = ana
check("off: no hello", ana.ns.GuildCrafters:Hello(true), false)
ana.ns.GuildCrafters:Tick()
Run()
check("off: nothing went to the guild", guildSent, 0)
check("off: nobody is named", Names(ana, 18560), "")

--------------------------------------------------------------------------------
print("\nturned on")
--------------------------------------------------------------------------------

for _, client in ipairs(clients) do
    current = client
    client.ns.GuildCrafters:SetOn(true)
    Run()
end
check("the setting is saved", ana.settings.guildCrafters, true)
check("hellos went to the guild", guildSent >= 3, true)
check("lists went by whisper", whispers > 0, true)
check("Ana sees Bob for Mooncloth", Names(ana, 18560), "Bob Jones")
check("Ana sees Cara for the other", Names(ana, 3914), "Cara Lee")
check("Cara sees both for Mooncloth", Names(cara, 18560), "Ana Smith, Bob Jones")
check("a Forever recipe ID comes through", Names(cara, 1000123), "Bob Jones")
check("never yourself", Names(bob, 1000123), "")
check("a recipe nobody knows", Names(ana, 77), "")
check("nothing is saved", next(ana.ns.db), "characters")

--------------------------------------------------------------------------------
print("\nonly the guild, only after a hello")
--------------------------------------------------------------------------------

clock = clock + 2 * 60   -- past the minute after Ana's first hello
current = ana
local before = Names(ana, 555)
ana.ns.GuildCrafters:OnList("Dan Black", { h = "x", r = "ff" }, "WHISPER")
check("a list from someone never heard is ignored", Names(ana, 555), before)
ana.ns.GuildCrafters:OnHello("Dan Black", "abc", "WHISPER")
check("a hello by whisper is not a guildmate", ana.ns.GuildCrafters.held["dan black"], nil)
ana.ns.GuildCrafters:OnHello("Dan Black", "abc:1", "GUILD")
network = {}
ana.ns.GuildCrafters:OnList("Dan Black", { h = "abc", r = "ff,zzzzzzzzzzzz,-1,0,,ff,hello" }, "WHISPER")
check("Dan's good ID is kept", Names(ana, 555), "Dan Black")
local count = 0
for _ in pairs(ana.ns.GuildCrafters.held["dan black"].set) do count = count + 1 end
check("junk IDs are dropped", count, 1)
ana.ns.GuildCrafters:OnList("Dan Black", "not a table", "WHISPER")
ana.ns.GuildCrafters:OnList("Dan Black", { h = {}, r = "ff" }, "WHISPER")
check("bad tables change nothing", Names(ana, 555), "Dan Black")

--------------------------------------------------------------------------------
print("\nonline")
--------------------------------------------------------------------------------

roster = { { "Bob Jones", false }, { "Cara Lee", true } }
current = ana
ana.ns.GuildCrafters:ReadRoster()
check("Bob shown offline is let go", Names(ana, 18560), "")
check("Cara online stays", Names(ana, 3914), "Cara Lee")
roster = { { "Dan", false } }
ana.ns.GuildCrafters:ReadRoster()
check("a first name alone on the roster counts too", Names(ana, 555), "")
check("someone not on the roster is never named", Names(ana, 3914), "")
roster = {}
ana.ns.GuildCrafters.members = nil

clock = clock + 26 * 60
check("not heard in a while: not named", Names(ana, 3914), "")
current = cara
cara.ns.GuildCrafters.helloAt = nil
cara.ns.GuildCrafters:Tick()
Run()
check("a new hello brings them back", Names(ana, 3914), "Cara Lee")

--------------------------------------------------------------------------------
print("\na new recipe goes out again")
--------------------------------------------------------------------------------

cara.known[7777] = { name = "new" }
clock = clock + 11 * 60
current = cara
cara.ns.GuildCrafters:Tick()
Run()
check("Ana hears Cara's new recipe", Names(ana, 7777), "Cara Lee")

--------------------------------------------------------------------------------
print("\nwhisper and off")
--------------------------------------------------------------------------------

local told
ChatFrame_SendTell = function(name) told = name end
check("a click whispers by full name", ana.ns.GuildCrafters.Whisper("Cara Lee"), true)
check("the whisper target", told, "Cara Lee")

current = ana
ana.ns.GuildCrafters:SetOn(false)
check("off forgets everyone", Names(ana, 3914), "")
check("off: held is empty", next(ana.ns.GuildCrafters.held), nil)

for name, value in pairs(saved) do _G[name] = value end
print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then error(("%d check(s) failed"):format(failed)) end
