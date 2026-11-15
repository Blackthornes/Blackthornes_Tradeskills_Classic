-- Export Prices and Import Prices (the owner, 2026-11-13): auction prices
-- carried between computers by text, newer ones only.
--
-- What must hold:
--   1. Nothing recent: nothing to export, and it says so.
--   2. Round trip: a new item comes over with its market value and cheapest.
--   3. A newer price replaces an older one and drops the old book's fields.
--   4. An older or equal price never replaces what is held.
--   5. The same code twice changes nothing more.
--   6. Another realm or side is refused; so are damaged and foreign codes.
--   7. One bad record refuses the whole code and changes nothing.
--   8. Long exports come in parts that each import on their own.
--   9. Only recent credible prices of the book are exported.

local passed, failed = 0, 0
local function check(label, got, want)
    if got == want then
        passed = passed + 1
        print(("  ok    %-62s %s"):format(label, tostring(got)))
    else
        failed = failed + 1
        print(("  FAIL  %-62s got %s, want %s"):format(label, tostring(got), tostring(want)))
    end
end

local saved_time = time
local clock = 1790000000
time = function() return clock end

local function NewClient(realmKey)
    local ns = {}
    ns.VERSION = "1.0"
    ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
    ns.Util = { Comma = tostring, FormatAgeAgo = function() return "just now" end }
    ns.NewModule = function(module) local m = {}; ns[module] = m; return m end
    ns.RegisterCommand = function() end
    ns.RegisterEvent = function() end
    ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end
    ns.L = setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

    local priceTable = {}
    ns.db = { characters = {}, postedAuctions = {}, priceHistory = {} }
    ns.Config = {
        Get = function() return nil end,
        Set = function() end,
        GetRealmKey = function() return realmKey end,
        GetCharacterKey = function() return "Player-1-A" end,
        GetPriceTable = function() return priceTable end,
        ReadSurname = function() return nil end,
    }
    for _, file in ipairs({ "Core/Serialize.lua", "Core/Comm.lua", "Data/Prices.lua",
                            "Logic/PriceTransfer.lua" }) do
        assert(loadfile(lfs_cwd .. "/" .. file))("Blackthornes_TS", ns)
    end
    return ns
end

local a = NewClient("Test Realm-Alliance")
local b = NewClient("Test Realm-Alliance")

print("Nothing to carry")
local parts, why = a.PriceTransfer:Export()
check("no prices, nothing to export", parts, nil)
check("and it says why", type(why), "string")

print("Round trip")
local at = clock - 3600
local pa = a.Prices:GetTable()
pa[100] = { market = 5000, min = 4800, rivalMin = 4700, seen = at, scans = 3, history = {}, quantity = 9 }
pa[200] = { market = 123456, seen = at - 86400, scans = 1, history = {} }
pa[300] = { market = 777, min = 700, seen = clock - 40 * 86400, scans = 1, history = {} }   -- too old
pa[400] = { market = 0, seen = at }                                                         -- no price
parts = a.PriceTransfer:Export()
check("one part", #parts, 1)
check("two recent prices go", a.PriceTransfer:Describe(), 2)
check("code has no pipe", parts[1]:find("|", 1, true), nil)

local ok, message = b.PriceTransfer:Import(parts[1])
check("import ok", ok, true)
check("says what it took", message:find("took 2 new", 1, true) ~= nil, true)
local pb = b.Prices:GetTable()
check("market came over", pb[100].market, 5000)
check("cheapest came over", pb[100].min, 4800)
check("seen came over", pb[100].seen, at)
check("no min stays none", pb[200].min, nil)
check("old price not carried", pb[300], nil)
check("rival lowest not carried", pb[100].rivalMin, nil)

print("Repeat and newer")
ok, message = b.PriceTransfer:Import(parts[1])
check("same code again is fine", ok, true)
check("but nothing new", message:find("took 0 new price(s) and 0 newer", 1, true) ~= nil, true)

pb[100].rivalMin, pb[100].quantity = 4700, 9
pa[100].market, pa[100].seen = 5500, at + 600
parts = a.PriceTransfer:Export()
ok, message = b.PriceTransfer:Import(parts[1])
check("newer price replaces", pb[100].market, 5500)
check("seen moves", pb[100].seen, at + 600)
check("old book fields dropped", pb[100].rivalMin, nil)
check("old quantity dropped", pb[100].quantity, nil)
check("scans kept", pb[100].scans, 1)

print("Older is kept")
pb[200].market, pb[200].seen = 999, at + 5000
parts = a.PriceTransfer:Export()
b.PriceTransfer:Import(parts[1])
check("newer local price stays", pb[200].market, 999)
check("older code did not touch it", pb[200].seen, at + 5000)

print("Refusals")
local c = NewClient("Other Realm-Alliance")
ok = c.PriceTransfer:Import(parts[1])
check("other realm refused", ok, false)
check("nothing came over", next(c.Prices:GetTable()), nil)
local d = NewClient("Test Realm-Horde")
ok = d.PriceTransfer:Import(parts[1])
check("other side refused", ok, false)
ok = b.PriceTransfer:Import("hello there")
check("not a code refused", ok, false)
ok = b.PriceTransfer:Import("")
check("empty refused", ok, false)
local damaged = parts[1]:gsub("(~)(%w+)(;)", "%1%2%3", 1):sub(1, -3) .. "zz;"
ok = b.PriceTransfer:Import(damaged)
check("damaged code refused", ok, false)

print("One bad record refuses all")
local realm = "TestRealm-Alliance"
local body = "2s:3k::" .. a.Comm.ToBase36(clock - 100) .. ";zz:zz:zz"   -- last record is short
local bad = table.concat({ "BTSP1", realm, "1/1", a.Comm.Hash(realm .. body), body }, "~")
local before = b.Prices.changes
ok = b.PriceTransfer:Import(bad)
check("bad record refuses the code", ok, false)
check("nothing changed", b.Prices.changes, before)

print("Whitespace from pasting")
parts = a.PriceTransfer:Export()
local spaced = parts[1]:gsub("(.-;)", "%1\n  ")
local e = NewClient("Test Realm-Alliance")
ok = e.PriceTransfer:Import(spaced)
check("line breaks and spaces are fine", ok, true)

print("Parts")
local f = NewClient("Test Realm-Alliance")
local pf = f.Prices:GetTable()
for id = 1000, 1600 do pf[id] = { market = 100000 + id, min = 99000 + id, seen = clock - id, scans = 1, history = {} } end
f.PriceTransfer.PART_CHARS = 1500
parts = f.PriceTransfer:Export()
check("splits into parts", #parts > 1, true)
local g = NewClient("Test Realm-Alliance")
local total = 0
for index = #parts, 1, -1 do
    ok, message = g.PriceTransfer:Import(parts[index])
    check("part " .. index .. " imports alone", ok, true)
end
local count = 0
for _ in pairs(g.Prices:GetTable()) do count = count + 1 end
check("every item arrived", count, 601)
check("last message names the part", message:find("(part 1 of " .. #parts .. ")", 1, true) ~= nil, true)

time = saved_time
print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
