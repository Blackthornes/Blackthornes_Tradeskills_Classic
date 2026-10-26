-- Logic/Butler.lua outside WoW: CraftFor and QueueCraft (2026-10-19).
--
-- Butler's "Craft When It Pays More" asks which known craft makes a bag item
-- worth the most. What must hold:
--   1. Only recipes the character playing knows, not a dropped profession,
--      that use the item; the output is never its own reagent.
--   2. Worth one item = (best way's net, less the other materials) / per.
--   3. A slow auction counts at Butler.SLOW; a price with no real reading
--      (derived, uncontested) never counts.
--   4. crafts follows what is carried; needs lists what the bags lack.
--   5. QueueCraft is Queue:Ensure and never raises.

local now = 100
GetTime = function() return now end

local ns = {}
ns.NewModule = function(name) local m = {} ns[name] = m return m end

local SELF = "Player-1"
ns.db = { characters = { [SELF] = { name = "Mia", realm = "R", faction = "Alliance", professions = {} } } }
ns.Config = { GetCharacterKey = function() return SELF end, Get = function() end }
ns.Prices = { GetValue = function() return nil end }
ns.Disenchanter = { Knows = function() return false end }
ns.Queue = { version = 0, GetAll = function() return {} end }
ns.QueueMail = { GetDeliveries = function() return {} end }
ns.Disenchant = {
  GetItemFacts = function() return nil end,
  IsDisenchantable = function() return false end,
}
ns.RecipeBook = { Get = function() return nil end, IsCrafted = function() return false end }

local WOOL, BOLT, DUST, SEED, OIL, OTHER = 2592, 2997, 10940, 17034, 20744, 9999
local recipes = {
  [1] = { name = "Bolt of Woolen Cloth", outputItemID = BOLT, skillLineID = 197,
    reagents = { { itemID = WOOL, quantity = 3 } } },
  [2] = { name = "Minor Mana Oil", outputItemID = OIL, skillLineID = 333,
    reagents = { { itemID = DUST, quantity = 3 }, { itemID = SEED, quantity = 1 } } },
  [3] = { name = "Wool Thing", outputItemID = OTHER, skillLineID = 197,
    reagents = { { itemID = WOOL, quantity = 6 } } },
  [4] = { name = "Dropped Craft", outputItemID = OTHER, skillLineID = 999,
    reagents = { { itemID = WOOL, quantity = 1 } } },
}
local dropped = { [4] = true }
ns.Recipes = {
  GetAll = function() return recipes end,
  Get = function(_, id) return recipes[id] end,
  IsDropped = function(_, recipe) return dropped[recipe == recipes[4] and 4 or 0] == true end,
  GetShortCharacterName = function(_, key) return ns.db.characters[key].name end,
}

-- One craft's best way: { via, revenue, cut, deposit, basis }.
local ways = {
  [1] = { via = "auction", revenue = 1000, cut = 50, deposit = 10, basis = "market" },
  [2] = { via = "vendor", revenue = 2000, cut = 0, deposit = 0, basis = "vendor" },
  [3] = { via = "auction", revenue = 900, cut = 0, deposit = 0, basis = "market" },
  [4] = { via = "auction", revenue = 99999, cut = 0, deposit = 0, basis = "market" },
}
ns.Profit = {
  NetFromListing = function(_, _, unit) return unit end,
  Analyse = function(_, recipeID)
    local w = ways[recipeID]
    if not w then return nil end
    return { priceable = true, via = w.via, outputItemID = recipes[recipeID].outputItemID,
      ways = { [w.via] = { revenue = w.revenue, cut = w.cut, deposit = w.deposit, basis = w.basis } } }
  end,
}
local demand = {}
ns.Demand = { Get = function(_, itemID) return demand[itemID] and { level = demand[itemID] } end }

local bags = { [WOOL] = 12, [DUST] = 6, [SEED] = 0 }
local seedCost = 100
ns.Cost = { GetCraftCost = function(_, recipeID)
  local recipe = recipes[recipeID]
  local lines = {}
  for _, r in ipairs(recipe.reagents) do
    local cost = r.itemID == SEED and seedCost or 5
    lines[#lines + 1] = { itemID = r.itemID, quantity = r.quantity, lineCost = cost * r.quantity,
      inBags = bags[r.itemID] or 0 }
  end
  return { priceable = true, reagents = lines }
end }
ns.Inventory = { changes = 0,
  GetBagCount = function(_, itemID) return bags[itemID] or 0 end,
  GetOwnedCount = function(_, itemID) return bags[itemID] or 0 end,
  GetBankCount = function() return 0 end }

local queued = {}
ns.Queue.Ensure = function(_, recipeID, n)
  if recipeID == 77 then return nil, "no such recipe" end
  if recipeID == 78 then error("broken") end
  queued[recipeID] = n
  return true
end

assert(loadfile(lfs_cwd .. "/Core/Characters.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Butler.lua"))("Blackthornes_TS", ns)
local Butler = ns.Butler

local failures = 0
local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(string.format("  FAIL  %-52s got %s, wanted %s", label, tostring(got), tostring(want)))
  else
    print(string.format("  ok    %-52s %s", label, tostring(got)))
  end
end

print("\nthe best known craft for the item")
local wool = Butler:CraftFor(WOOL)
-- Bolt: (1000 - 60) / 3 = 313 each. Wool Thing: 900 / 6 = 150. Dropped one left out.
check("wool goes into bolts", wool and wool.recipeID, 1)
check("its name", wool and wool.name, "Bolt of Woolen Cloth")
check("what it makes", wool and wool.itemID, BOLT)
check("three a craft", wool and wool.per, 3)
check("12 in the bags make 4", wool and wool.crafts, 4)
check("worth each, after the cut and deposit", wool and wool.perItem, 313)
check("nothing else needed", wool and #wool.needs, 0)
check("by link too", Butler:CraftFor("|cffffffff|Hitem:2592::|h[Wool Cloth]|h|r").recipeID, 1)
check("carried given wins over the bags", Butler:CraftFor(WOOL, 7).crafts, 2)
check("too few for one craft: nil", Butler:CraftFor(WOOL, 2), nil)
local skipped = Butler:CraftFor(WOOL, nil, { [1] = "Bolt of Woolen Cloth" })
check("a craft turned off in Butler is passed over", skipped and skipped.recipeID, 3)
check("the next best's worth", skipped and skipped.perItem, 150)
check("a skip list that isn't a table is ignored", Butler:CraftFor(WOOL, nil, "x").recipeID, 1)

print("\nother materials")
local dust = Butler:CraftFor(DUST)
-- Oil: (2000 - 100 seed) / 3 = 633. Six dust make 2, which need 2 seeds.
check("dust into oil", dust and dust.recipeID, 2)
check("seed taken off", dust and dust.perItem, 633)
check("needs one line", dust and #dust.needs, 1)
check("the seed", dust and dust.needs[1].itemID, SEED)
check("two seeds short", dust and dust.needs[1].count, 2)
bags[SEED] = 5
Butler:Forget()
check("seeds in the bags: needs nothing", #Butler:CraftFor(DUST).needs, 0)

print("\nprices it won't count on")
demand[BOLT] = "low"
Butler:Forget()
check("a slow seller counts at SLOW", Butler:CraftFor(WOOL).perItem, math.floor(940 * Butler.SLOW / 3))
demand[BOLT] = nil
ways[1].basis = "derived"
Butler:Forget()
check("no real price: the next craft", Butler:CraftFor(WOOL).recipeID, 3)
ways[3].basis = "uncontested"
Butler:Forget()
check("none real: nil", Butler:CraftFor(WOOL), nil)
ways[1].basis, ways[3].basis = "market", "market"
check("an item no recipe uses: nil", Butler:CraftFor(12345), nil)
check("nonsense: nil", Butler:CraftFor("nope"), nil)
ns.Profit.Analyse = function() error("broken") end
Butler:Forget()
check("Profit raises: nil", Butler:CraftFor(WOOL), nil)

print("\nqueueing")
check("queues the crafts", Butler:QueueCraft(1, 4), true)
check("as many as asked", queued[1], 4)
local ok, why = Butler:QueueCraft(77, 1)
check("refused: false", ok, false)
check("and why", why, "no such recipe")
check("raises: false", (Butler:QueueCraft(78, 1)), false)

print("")
if failures > 0 then
  error(string.format("%d CraftFor check(s) failed", failures))
end
print("  all CraftFor checks passed")
print("")
