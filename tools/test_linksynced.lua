-- Last Synced (2026-11-07): Settings > Sharing says when the other account
-- last told this one what it has, and the time lasts past a reload.
--
-- Drives the real AccountLink.lua.

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end

local clock = 2000000
time = function() return clock end
GetTime = function() return clock end

ns.Util = {
    IsBoundOnPickup = function() return false end,
    FormatAgeAgo = function(seconds) return math.floor(seconds / 60) .. " minutes ago" end,
}

local settings = { linkNames = "Loom Weaver" }
ns.Config = {
    Get = function(_, key) return settings[key] end,
    GetCharacterKey = function() return "Player-1-BOB" end,
    GetRealmKey = function() return "realm" end,
}

local sent = {}
ns.Comm = {
    NameKey = function(name) return type(name) == "string" and name:lower():gsub("%-.*", "") or nil end,
    IsMe = function() return false end,
    Hash = function(text) return #text end,
    SendTable = function(_, kind) sent[#sent + 1] = kind end,
    Send = function() end,
    Whisper = function() end,
    Pending = function() return 0 end,
}
ns.Recipes = { GetAll = function() return {} end, GetAny = function() end }
ns.Inventory = setmetatable({}, { __index = function() return function() return 0 end end })

assert(loadfile(lfs_cwd .. "/Logic/AccountLink.lua"))("Blackthornes_TS", ns)
local AL = ns.AccountLink
ns.db = { characters = {} }

-- Nothing heard yet.
assert(AL:LastSynced("Loom Weaver") == nil)
assert(AL:LastSyncedText() == "Last Synced: Loom Weaver, Not yet", AL:LastSyncedText())

-- Their list comes in: synced now, kept in the account save.
AL:OnManifest("Loom Weaver", {}, "WHISPER")
assert(ns.db.linkSyncedAt["loom weaver"] == clock)
clock = clock + 120
assert(AL:LastSyncedText() == "Last Synced: Loom Weaver, 2 minutes ago", AL:LastSyncedText())

-- Someone not named, or not by whisper, changes nothing.
AL:OnManifest("Stranger", {}, "WHISPER")
AL:OnManifest("Loom Weaver", {}, "GUILD")
assert(ns.db.linkSyncedAt["stranger"] == nil)
assert(AL:LastSynced("Loom Weaver") == clock - 120)

-- No other account named: no line at all.
settings.linkNames = ""
assert(AL:LastSyncedText() == nil)

print("test_linksynced: ok")
