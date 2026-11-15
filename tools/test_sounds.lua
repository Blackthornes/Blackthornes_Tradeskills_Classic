-- Every sound can be switched off in Settings, and the two new ones play
-- when they should (the owner and a player, 2026-10-02).
--
-- What must hold:
--   1. Bags filling up warns once, as the last slot goes, never at login.
--   2. Its switch silences the sound but still says so in chat.
--   3. A run of crafts that made something chimes when it ends; a single
--      craft or a run that made nothing does not.
--   4. Every sound has a default of on.

local GLOBALS = { "GetTime", "time", "PlaySound", "C_Container", "SOUNDKIT", "UnitCastingInfo" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local function noop() end
local now = 100
GetTime = function() return now end
time = function() return 100000 end
SOUNDKIT = nil
UnitCastingInfo = function() return nil end

local played = {}
PlaySound = function(kit) played[#played + 1] = kit; return true end

local free = { [0] = 4, [1] = 2 }
C_Container = { GetContainerNumFreeSlots = function(bag) return free[bag], 0 end }

local ns = {}
local printed = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = noop
ns.RegisterEvent = noop
ns.Print = function(text) printed[#printed + 1] = text end
ns.PrintRaw, ns.Debug, ns.Warn = noop, noop, noop
ns.Util = { HasFunction = function() return false end }

local settings = {}
ns.Config = { Get = function(_, key) return settings[key] end, GetCharacterKey = function() return "me" end }

local bags = {}
ns.Inventory = {
    GetCarriedBags = function() return { 0, 1 } end,
    GetBagCount = function(_, id) return bags[id] or 0 end,
}

assert(loadfile(lfs_cwd .. "/Logic/BagsFull.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Crafting.lua"))("Blackthornes_TS", ns)

local passed, failed = 0, 0
local function check(label, got, want)
    local ok = got == want
    if ok then passed = passed + 1 else failed = failed + 1 end
    print(string.format("  %-58s %-8s %s", label, tostring(got), ok and "ok" or
        ("WRONG, wanted " .. tostring(want))))
end

print("bags full")

do
    local BagsFull = ns.BagsFull
    BagsFull:Check()
    check("six free slots: quiet", #played, 0)

    free = { [0] = 0, [1] = 0 }
    BagsFull:Check()
    check("the last slot fills: one warning", #played, 1)
    check("and a line in chat", printed[#printed], "your bags are full")

    BagsFull:Check()
    check("still full: no second warning", #played, 1)

    BagsFull.lastFree = nil
    BagsFull:Check()
    check("full at login: quiet", #played, 1)

    free = { [0] = 1, [1] = 0 }
    BagsFull:Check()
    settings.bagsFullSound = false
    free = { [0] = 0, [1] = 0 }
    local lines = #printed
    BagsFull:Check()
    check("switched off: no sound", #played, 1)
    check("but chat still says so", #printed, lines + 1)
    settings.bagsFullSound = nil
end

print("")
print("a run of crafts finishes")

do
    local Crafting = ns.Crafting
    played = {}

    bags = { [2996] = 5 }
    Crafting:AnnounceRunDone({ requested = 5, outputItemID = 2996, before = 0 })
    check("five bolts made: a chime", #played, 1)

    Crafting:AnnounceRunDone({ requested = 1, outputItemID = 2996, before = 0 })
    check("a single craft: quiet", #played, 1)

    Crafting:AnnounceRunDone({ requested = 5, outputItemID = 2996, before = 5 })
    check("nothing made: quiet", #played, 1)

    settings.craftDoneSound = false
    Crafting:AnnounceRunDone({ requested = 5, outputItemID = 2996, before = 0 })
    check("switched off: quiet", #played, 1)
    settings.craftDoneSound = nil
end

print("")
print("Mute All Sounds")

do
    -- The same helpers as Core/Init.lua: every call goes through them.
    local muted = false
    ns.Muted = function() return muted end
    ns.PlaySound = function(...)
        if ns.Muted and ns.Muted() then return false end
        return PlaySound(...)
    end
    played = {}
    free = { [0] = 1, [1] = 0 }
    ns.BagsFull:Check()
    muted = true
    free = { [0] = 0, [1] = 0 }
    local lines = #printed
    ns.BagsFull:Check()
    check("muted: no sound", #played, 0)
    check("but chat still says so", #printed, lines + 1)

    bags = { [2996] = 5 }
    ns.Crafting:AnnounceRunDone({ requested = 5, outputItemID = 2996, before = 0 })
    check("muted: no chime either", #played, 0)
    muted = false
    ns.Crafting:AnnounceRunDone({ requested = 5, outputItemID = 2996, before = 0 })
    check("back on: the chime plays", #played, 1)
    ns.Muted, ns.PlaySound = nil, nil
end

print("")
print("every sound starts on")

do
    local config = {}
    config.NewModule = function(name) local m = {}; config[name] = m; return m end
    config.RegisterCommand, config.RegisterEvent = noop, noop
    config.Util = ns.Util
    local ok = pcall(assert(loadfile(lfs_cwd .. "/Core/Config.lua")), "Blackthornes_TS", config)
    local defaults = ok and config.Config and config.Config.DEFAULTS and config.Config.DEFAULTS.settings or {}
    for _, key in ipairs({ "saleAlarm", "scanSounds", "mailReportSound", "craftDoneSound",
            "bagsFullSound", "disenchantSound", "altCraftSound", "goalSound" }) do
        check(key, defaults[key], true)
    end
    check("the sale alarm starts on the cash register", defaults.saleSound, "register")
end

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print("")
if failed > 0 then
    error(string.format("FAIL -- %d of %d sound checks wrong", failed, passed + failed))
end
print(string.format("PASS -- every sound has a switch and plays when it should (%d checks)", passed))
