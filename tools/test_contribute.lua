-- Sending data to the addon's maker (Logic/Contribute.lua, 2026-10-18).
--
-- What must hold:
--   1. Off by default, North America only, and a recipient never sends.
--   2. A player who ticked it whispers both recipients; whichever is online
--      asks, takes the table once, says so, and keeps it apart.
--   3. The same data again is not asked for; nobody else is answered;
--      junk is left out; nothing flows back to the player.

local saved, stubbed = {}, { "time", "GetTime", "UnitName", "C_ChatInfo", "C_Timer", "InCombatLockdown",
                        "SendAddonMessage", "ERR_CHAT_PLAYER_NOT_FOUND_S", "GetCurrentRegion",
                        "GetCurrentRegionName", "PlaySound", "UIErrorsFrame", "date",
                        "GetNormalizedRealmName", "GetRealmName" }
for _, name in ipairs(stubbed) do saved[name] = _G[name] end

local passed, failed = 0, 0
local function check(label, got, want)
    if want == nil then want = true end
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
date = function() return "Oct 18 14:02" end
C_Timer = { NewTicker = function() return { Cancel = function() end } end, After = function() end }
InCombatLockdown = function() return false end
ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
SendAddonMessage = nil
GetCurrentRegionName = nil
local region = 1
GetCurrentRegion = function() return region end
-- The owner's Era characters are on Ashkandi; a whisper reaches only there.
local realm = "Ashkandi"
GetNormalizedRealmName = function() return realm end
GetRealmName = nil
local sounds, flashes = 0, {}
PlaySound = function() sounds = sounds + 1 end
UIErrorsFrame = { AddMessage = function(_, text) flashes[#flashes + 1] = text end }

local network, current = {}, nil
C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    SendAddonMessage = function(_, text, channel, target)
        -- The server takes "Name-Realm" for a whisper; the realm is not part of
        -- the name these pretend clients go by.
        if type(target) == "string" then target = (target:gsub("%-[^%-]+$", "")) end
        assert(#text <= 255, "a message over 255 bytes went out")
        network[#network + 1] = { from = current.full, text = text, channel = channel, target = target }
        return 0
    end,
}
UnitName = function() return current.first end

local function NewClient(full)
    -- Era characters have no last name.
    local first, last = full:match("^(%S+) (%S+)$")
    if not first then first = full end
    local ns = {}
    ns.NewModule = function(module) local m = {}; ns[module] = m; return m end
    ns.RegisterCommand, ns.RegisterEvent = function() end, function() end
    local chat = {}
    ns.Print = function(text) chat[#chat + 1] = text end
    ns.PrintRaw, ns.Debug = function() end, function() end
    local settings = {}
    ns.db = { settings = settings }
    ns.Config = {
        Get = function(_, key) return settings[key] end,
        Set = function(_, key, value) settings[key] = value end,
        ReadSurname = function() return last end,
    }
    for _, file in ipairs({ "Core/Serialize.lua", "Core/Comm.lua", "Logic/Contribute.lua" }) do
        assert(loadfile(lfs_cwd .. "/" .. file))("Blackthornes_TS", ns)
    end
    local client = { full = full, first = first, ns = ns, settings = settings, chat = chat, online = true }
    current = client
    ns.Comm:OnEnable()
    ns.Contribute:OnEnable()
    return client
end

local clients = {}
local function Run()
    for _ = 1, 600 do
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
                if client.online and message.channel == "WHISPER" and message.target == client.full then
                    current = client
                    client.ns.Comm:CHAT_MSG_ADDON("CHAT_MSG_ADDON", "BTSshare", message.text,
                        message.channel, message.from)
                end
            end
        end
    end
end

local ana = NewClient("Ana Smith")
local farmer = NewClient("Blackthornes")
local wither = NewClient("Blacklock")
local carl = NewClient("Carl Jones")
clients = { ana, farmer, wither, carl }
-- Both of the owner's characters are on one account: one save between them.
wither.ns.db = farmer.ns.db
wither.settings = farmer.settings
wither.ns.Config.Get = farmer.ns.Config.Get
wither.ns.Config.Set = farmer.ns.Config.Set

ana.ns.db.disenchantLog = { items = {
    [2589] = { casts = 4, got = { [10940] = { times = 4, total = 7, min = 1, max = 3 } } },
    [9999] = { casts = 2, got = { [10938] = { times = 9, total = 1 } } },   -- times past casts: left out
} }
ana.ns.db.recipeSkills = { [2406] = { skill = 110, profession = "Leatherworking", teaches = "x", at = 5 } }

print("\nchoosing")
local C = ana.ns.Contribute
check("off by default", C:On(), false)
check("the shipped list names two characters", #C:Recipients(), 2)
realm = "Mankrik"
check("on another realm nobody is named", #C:Recipients(), 0)
realm = nil
check("with the realm not read, nobody is named", #C:Recipients(), 0)
realm = "Ashkandi"
check("realms compare without spaces or case",
    C.RealmKey("Ana-Some Realm") == C.RealmKey("Bob-somerealm") and C.RealmKey("Ana") == nil)
check("no Forever character is named", (function()
    for _, name in ipairs(C.RECIPIENTS) do
        if name:find(" ", 1, true) or not name:find("-Ashkandi$") then return false end
    end
    return true
end)())
current = farmer
check("Blackthornes receives", farmer.ns.Contribute:Receiving())
realm = "Mankrik"
check("the same name on another realm does not", farmer.ns.Contribute:Receiving(), false)
realm = "Ashkandi"
current = wither
check("Blacklock receives", wither.ns.Contribute:Receiving())
current = carl
check("anyone else does not", carl.ns.Contribute:Receiving(), false)
current = ana
check("not sending while off", C:Sending(), false)
C:SetOn(true)
check("sending once ticked", C:Sending())
region = 3
check("Europe sends nothing", C:Sending(), false)
region = 110
check("the Forever test client's 110 is not this copy's", C:Sending(), false)
region = 1
current = farmer
farmer.settings.shareData = true
check("a recipient never sends", farmer.ns.Contribute:Sending(), false)

print("\nsending")
farmer.online, wither.online = false, true
current = ana
C:Hello()
Run()
local store = farmer.ns.db.sharedData
local id = ana.ns.db.shareDataId
check("the online character took it", type(store) == "table" and type(store[id]) == "table")
local got = store and store[id] or {}
check("disenchants came whole", got.disenchants and got.disenchants[2589] and got.disenchants[2589].g[10940].n, 7)
check("a bad material count was left out", got.disenchants ~= nil and next(got.disenchants[9999].g) == nil)
check("recipe skills came", got.skills and got.skills[2406], 110)
check("nothing but numbers: no profession name", type(got.skills and got.skills[2406]), "number")
check("one chat line names the sender", wither.chat[1], "Got disenchants and recipe levels from Ana Smith.")
check("with a sound", sounds, 1)
check("and a line on screen", #flashes, 1)
check("the sender heard nothing back", #ana.chat, 0)
check("it is logged", farmer.ns.db.sharedDataLog and #farmer.ns.db.sharedDataLog, 1)
check("the player's own disenchant log is untouched", farmer.ns.db.disenchantLog == nil)

print("\nagain")
-- One account: only one of the two is ever online at once.
farmer.online, wither.online = true, false
local lines = #wither.chat
clock = clock + 3600
current = ana
C:Hello()
Run()
check("the same data again is not asked for", #wither.chat + #farmer.chat, lines)

ana.ns.db.recipeSkills[2407] = { skill = 125 }
clock = clock + 3600
current = ana
C:Hello()
Run()
check("new data is taken once", #wither.chat + #farmer.chat, lines + 1)
check("and replaces the old", farmer.ns.db.sharedData[id].skills[2407], 125)

print("\nstrangers and junk")
current = ana
local before = #network
ana.ns.Contribute:OnAsk("Carl Jones", id, "WHISPER")
check("someone not on the list is never answered", #network + ana.ns.Comm:Pending(), before)
current = carl
carl.ns.Contribute:OnHello("Ana Smith", id .. ":abc", "WHISPER")
check("someone not on the list never asks", carl.ns.Comm:Pending(), 0)
current = farmer
farmer.ns.Contribute.current = nil
farmer.ns.Contribute:OnTable("Ana Smith", { i = id, d = {}, s = {} }, "WHISPER")
check("a table nobody asked for is not kept", farmer.ns.db.sharedData[id].skills[2407], 125)
check("junk is refused", farmer.ns.Contribute:Clean({ d = "x", s = {} }) == nil)
check("big numbers are left out", next(farmer.ns.Contribute:Clean({ d = {}, s = { [5] = 99999 } }).s) == nil)

print("\nthe log")
current = farmer
farmer.ns.Contribute:PrintLog()
check("lists who sent data", farmer.chat[#farmer.chat], "Oct 18 14:02: data from Ana Smith.")
farmer.ns.db.sharedDataLog = nil
farmer.ns.Contribute:PrintLog()
check("says when nobody has", farmer.chat[#farmer.chat], "Nobody has shared data with you yet.")

-- By name, so a global that was nil before goes back to nil.
for _, name in ipairs(stubbed) do _G[name] = saved[name] end
print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then error(("%d contribute check(s) failed"):format(failed)) end
