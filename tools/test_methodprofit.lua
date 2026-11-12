-- Logic/MethodProfit.lua outside WoW: profit by the way it was made.
--
--   1. What was paid on the auction house becomes a cost, averaged per item.
--   2. Auction sales sort into crafted, flipped and other by their cost.
--   3. A vendor's buyback list gives sales: the first look is the baseline,
--      what is new afterwards was just sold, and a repeat look adds nothing.
--   4. A disenchant is the materials' worth against what the item cost.
--   5. A period holds only what happened inside it; loot has no cost and
--      counts as all profit, with its units counted as unknown.

local ns = {}
ns.NewModule = function(name) local m = {} ns[name] = m return m end
ns.RegisterEvent = function() return true end

local now = 10000000
time = function() return now end

ns.Config = { GetRealmKey = function() return "Realm-A" end }
ns.db = {}
ns.Util = {}

local BOLT, CLOTH, LOOT, SWORD, DUST = 100, 200, 300, 400, 500
local crafted = { [BOLT] = { cost = 800 } }
ns.CraftedCost = {
  Get = function(_, id) return crafted[id] end,
  NewSaleCache = function() return {} end,
  SaleCost = function(_, entry) return entry.estimate end,
}
ns.Disenchant = { GetMaterialPrice = function(_, id) if id == DUST then return 50 end end }

local ledger = { entries = {} }
ns.Mail = {
  GetLedger = function() return ledger end,
  NameIndex = function() return {} end,
}
ns.GoldLog = {
  sessionStart = now - 600,
  DayStart = function(t) return t - (t % 86400) end,
  KeyStart = function(k) return k end,
}

assert(loadfile(lfs_cwd .. "/Logic/MethodProfit.lua"))("Blackthornes_TS", ns)
local MP = ns.MethodProfit
local failures = 0

local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(string.format("  FAIL  %-52s got %s, wanted %s", label, tostring(got), tostring(want)))
  else
    print(string.format("  ok    %-52s %s", label, tostring(got)))
  end
end

print("costs")
check("nothing bought: no cost", MP:BuyCost(CLOTH), nil)
MP:NoteBought(CLOTH, 10, 1000)
MP:NoteBought(CLOTH, 10, 1400)
check("average of what was paid", MP:BuyCost(CLOTH), 120)
MP:NoteBought(CLOTH, 0, 500)
MP:NoteBought(CLOTH, 5, nil)
check("junk purchases are ignored", MP:BuyCost(CLOTH), 120)

local ORE = 600
check("nothing bought: no summary", MP:BoughtSummary(ORE), nil)
MP:NoteBought(ORE, 10, 1000)
MP:NoteBought(ORE, 10, 1400)
now = now + 50
MP:NoteBought(ORE, 4, 600)
local bought = MP:BoughtSummary(ORE)
check("the newest buy, each", bought.each, 150)
check("and when", bought.at, now)
check("the average over every buy", bought.average, 125)
check("units in all", bought.units, 24)
check("buys in all", bought.buys, 3)
now = now + MP.BUY_LIFE + 1
check("too old to count: no summary", MP:BoughtSummary(ORE), nil)
now = now - MP.BUY_LIFE - 51
check("a craft cost wins", select(2, MP:CostOf(BOLT)), "made")
check("else what was bought", select(2, MP:CostOf(CLOTH)), "bought")
check("loot has none", MP:CostOf(LOOT), nil)

print("\nauction sales")
ledger.entries = {
  { kind = "sold", itemID = BOLT, net = 1000, deposit = 0, t = now - 100, cost = 800 },
  { kind = "sold", itemID = CLOTH, net = 500, deposit = 20, t = now - 100, cost = 120, bought = true },
  { kind = "sold", itemID = CLOTH, net = 300, deposit = 0, t = now - 90 },
  { kind = "sold", itemID = LOOT, net = 700, deposit = 0, t = now - 80 },
  { kind = "sold", itemID = SWORD, net = 900, deposit = 0, t = now - 70, estimate = 400 },
  { kind = "expired", itemID = LOOT, t = now - 60 },
  { kind = "sold", itemID = BOLT, net = 5000, deposit = 0, t = now - 99999999 },
}
local s = MP:Summary(now - 3600, now + 1)
check("crafted: stamped cost and an estimate", s.methods.crafted.n, 2)
check("crafted profit", s.methods.crafted.profit, (1000 - 800) + (900 - 400))
check("flipped: stamped, and by what was bought", s.methods.flipped.n, 2)
check("flipped profit leaves the deposit out", s.methods.flipped.profit, (480 - 120) + (300 - 120))
check("other: loot", s.methods.other.n, 1)
check("loot counts as all profit", s.methods.other.profit, 700)
check("its units are unknown", s.methods.other.unknown, 1)
check("an expiry sold nothing", s.total.n, 5)
check("old sales are outside the period", s.methods.crafted.items[BOLT].n, 1)
check("items sort best first", s.methods.crafted.list[1].itemID, SWORD)

print("\nfarmed, from Blackthornes Farmer")
check("without Farmer there is no Farmed", s.methods.farmed.n, 0)
local asked = 0
BlackthornesFarmer = { Looted = { Has = function(_, id) asked = asked + 1; return id == LOOT end } }
s = MP:Summary(now - 3600, now + 1)
check("looted by you: Farmed", s.methods.farmed.n, 1)
check("and all profit", s.methods.farmed.profit, 700)
check("no longer under Other", s.methods.other.n, 0)
check("a flip you also looted stays a flip", s.methods.flipped.n, 2)
check("Farmer is asked once an item", asked, 1)
BlackthornesFarmer = { Looted = { Has = function() error("boom") end } }
s = MP:Summary(now - 3600, now + 1)
check("a Farmer that raises: back to Other", s.methods.other.n, 1)
BlackthornesFarmer = nil
s = MP:Summary(now - 3600, now + 1)

print("\nvendor buyback")
local list = { { itemID = LOOT, quantity = 2, price = 40 } }
MP:NoteBuyback(list)
s = MP:Summary(now - 3600, now + 1)
check("first look is the baseline", s.methods.vendored.n, 0)
MP:NoteBuyback(list)
check("a repeat look adds nothing", MP:Summary(now - 3600, now + 1).methods.vendored.n, 0)
list = { { itemID = LOOT, quantity = 2, price = 40 }, { itemID = CLOTH, quantity = 4, price = 20 } }
MP:NoteBuyback(list)
s = MP:Summary(now - 3600, now + 1)
check("a new one was just sold", s.methods.vendored.n, 4)
check("its income", s.methods.vendored.income, 20)
check("cost is what it cost on the auction house", s.methods.vendored.cost, 480)
check("a loss is a loss", s.methods.vendored.profit, 20 - 480)
list[#list + 1] = { itemID = LOOT, quantity = 2, price = 40 }
MP:NoteBuyback(list)
check("the same stack again is another sale", MP:Summary(now - 3600, now + 1).methods.vendored.n, 6)
MP.buybackSeen = nil
MP:NoteBuyback(list)
check("a new visit starts a new baseline", MP:Summary(now - 3600, now + 1).methods.vendored.n, 6)

print("\ndisenchant")
MP:NoteDisenchant(SWORD, { [DUST] = 3 })
s = MP:Summary(now - 3600, now + 1)
check("materials' worth is income", s.methods.disenchanted.income, 150)
check("an item with no cost known is unknown", s.methods.disenchanted.unknown, 1)
MP:NoteDisenchant(CLOTH, { [DUST] = 1 })
s = MP:Summary(now - 3600, now + 1)
check("cost is what the item cost", s.methods.disenchanted.cost, 120)

print("\nperiods")
check("outside the period: nothing", MP:Summary(now + 10, now + 20).total.n, 0)
local from, to = MP.Range("session", nil, nil, now)
check("session starts when the session did", from, now - 600)
from, to = MP.Range("week", nil, nil, now)
check("a week back", now - from, 7 * 86400)
from = MP.Range("quarter", nil, nil, now)
check("3m: 91 days back", now - from, 91 * 86400)
from = MP.Range("year", nil, nil, now)
check("a year back", now - from, 365 * 86400)
from = MP.Range("all", nil, nil, now)
check("all: from the start", from, 0)
check("totals add up", MP:Summary(now - 3600, now + 1).total.profit,
  s.methods.crafted.profit + s.methods.flipped.profit + s.methods.other.profit
  + s.methods.vendored.profit + s.methods.disenchanted.profit)

print("\nkeeping")
local log = MP:GetLog()
log.events[#log.events + 1] = { t = now - 500 * 86400, m = "vendored", id = LOOT, n = 1, inc = 1 }
local before = #log.events
MP:Prune()
check("old events go", #log.events, before - 1)

if failures > 0 then error(failures .. " failure(s)") end
