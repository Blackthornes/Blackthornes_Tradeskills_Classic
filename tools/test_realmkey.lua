-- One realm, two accounts (2026-11-05): Forever's GetRealmName names the
-- server behind the realm, and a player's two accounts on one realm can sit
-- on different ones ("CAMWOW US2 Realm 7 PvE" and "CAMWOW US2 Realm 3 PvE").
-- The second account's characters were left out of "This realm" on the
-- Characters tab and could not be mailed. Drives the real Queue.lua.

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end
ns.Util = {}
ns.Config = { Get = function() return nil end, GetCharacterKey = function() return "Player-6933-A" end }
ns.db = { characters = {
    ["Player-6933-A"] = { name = "Ana Thorn", realm = "CAMWOW US2 Realm 7 PvE", faction = "Alliance" },
    ["Player-6929-B"] = { name = "Bo Thorn", realm = "CAMWOW US2 Realm 3 PvE", faction = "Alliance",
        linkedFrom = "Ana Thorn" },
    ["Player-6929-C"] = { name = "Cy Thorn", realm = "CAMWOW US2 Realm 3 PvE", faction = "Horde" },
    ["Player-7000-D"] = { name = "Di Thorn", realm = "CAMWOW US2 Realm 4 PvP", faction = "Alliance" },
    ["Player-7000-E"] = { name = "Ed Thorn", realm = "?", faction = "Alliance" },
} }

assert(loadfile(lfs_cwd .. "/Logic/Queue.lua"))("Blackthornes_TS", ns)
local Queue = ns.Queue

local failures = 0
local function check(label, got, want)
    local ok = got == want
    if not ok then failures = failures + 1 end
    print(("  %s  %-50s %s"):format(ok and "ok  " or "FAIL", label, tostring(got)))
end

print("realms: one realm, two accounts")
check("the other account's server counts as this realm", Queue:CanMail("Player-6933-A", "Player-6929-B"), true)
check("the other side still cannot be mailed", Queue:CanMail("Player-6933-A", "Player-6929-C"), false)
check("another kind of realm is another realm", Queue:CanMail("Player-6933-A", "Player-7000-D"), false)
check("a realm not read yet is not held against it", Queue:CanMail("Player-6933-A", "Player-7000-E"), true)

if failures > 0 then error(failures .. " realm check(s) failed") end
print("all checks passed")
