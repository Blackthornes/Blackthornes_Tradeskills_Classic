-- Gear from Blackthornes Equipment's Queue it button (a player asked, 2026-10-10).
--
-- A crafted upgrade the character can make is queued (Queue:Ensure); one it
-- cannot puts the gear, or the materials of a recipe still to learn, on the
-- shopping list (Queue:EnsureBuy). A second click changes nothing, queuing
-- the craft lets go of its materials so they are not bought twice, and a
-- line goes once the gear is owned or worn.

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() end
ns.Print = function() end
ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end
ns.Util = {}

time = time or os.time

local selfKey = "Ana-Realm"
ns.Config = {
    Get = function(_, key) if key == "suggestOtherCharacters" then return false end end,
    GetCharacterKey = function() return selfKey end,
}

local GAUNTLETS_RECIPE, GAUNTLETS = 3323, 3472
local BAR, STONE, CLOAK = 2840, 3470, 5000
local recipes = {
    [GAUNTLETS_RECIPE] = { recipeID = GAUNTLETS_RECIPE, outputItemID = GAUNTLETS, quantityMin = 1,
        reagents = { { itemID = BAR, quantity = 8 }, { itemID = STONE, quantity = 2 } } },
}
ns.Recipes = {
    Get = function(_, id) return recipes[id] end,
    GetAny = function(_, id) return recipes[id] end,
    GetDisplayLink = function(_, id) return "recipe" .. tostring(id) end,
}

local bags, worn = {}, {}
ns.Inventory = {
    GetBagCount = function(_, itemID) return bags[itemID] or 0 end,
    GetBankCount = function() return 0 end,
    GetMailCount = function() return 0 end,
    GetOwnedCount = function(_, itemID) return bags[itemID] or 0 end,
    GetEquippedCount = function(_, itemID) return worn[itemID] or 0 end,
    GetAltTotal = function() return 0 end,
}
ns.Prices = { GetValue = function() return 100 end }
ns.Vendor = { GetUnitPrice = function() return nil end, IsLimited = function() return false end }
ns.Cost = {
    GetCraftCost = function() return { reagents = {} } end,
    FindRecipeForItem = function() return nil end,
}
ns.Profit = { Analyse = function() return nil end }

local notified = 0
ns.UI = { OnQueueUpdated = function() notified = notified + 1 end }

ns.db = { queue = {}, queueBuys = {} }

assert(loadfile(lfs_cwd .. "/Logic/Queue.lua"))("Blackthornes_TS", ns)
local Queue = ns.Queue

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

local function Line(itemID)
    for _, line in ipairs(Queue:GetShoppingList()) do
        if line.itemID == itemID then return line end
    end
end

print("\nbuying gear nobody on the account makes")

check("the gear goes on the list", Queue:EnsureBuy(CLOAK, 1, CLOAK) == true)
check("as a line to buy", Line(CLOAK) and Line(CLOAK).needed == 1 and Line(CLOAK).shortfall == 1)
check("which says what it is for", Line(CLOAK).buys and Line(CLOAK).buys[1].forItem == CLOAK)
check("and the queue says so", Queue:ForUpgrade(CLOAK) == "buy")
Queue:EnsureBuy(CLOAK, 1, CLOAK)
check("a second click buys no more", Line(CLOAK).needed == 1 and #ns.db.queueBuys == 1)

selfKey = "Bob-Realm"
check("another character does not see it", Line(CLOAK) == nil and Queue:ForUpgrade(CLOAK) == nil)
selfKey = "Ana-Realm"

bags[CLOAK] = 1
check("bought: the line goes", Line(CLOAK) == nil and #ns.db.queueBuys == 0)
local ok, why = Queue:EnsureBuy(CLOAK, 1, CLOAK)
check("and owned gear is not put back", ok == nil and type(why) == "string")
bags[CLOAK] = nil

print("\nthe materials of a recipe still to learn")

Queue:EnsureBuy(BAR, 8, GAUNTLETS)
Queue:EnsureBuy(STONE, 2, GAUNTLETS)
check("both materials are on the list", Line(BAR).needed == 8 and Line(STONE).needed == 2)
check("for the gauntlets", Queue:ForUpgrade(GAUNTLETS) == "buy")

bags[BAR] = 3
check("what is in the bags counts", Line(BAR).shortfall == 5)
bags[BAR] = nil

print("\nlearned: queuing the craft")

check("the craft is queued", Queue:Ensure(GAUNTLETS_RECIPE, 1) == true)
check("the queue says so", Queue:ForUpgrade(GAUNTLETS) == "craft")
check("its materials are wanted once, not twice", Line(BAR).needed == 8 and Line(STONE).needed == 2)
check("the bought lines went", Line(BAR).buys == nil and #ns.db.queueBuys == 0)
Queue:Ensure(GAUNTLETS_RECIPE, 1)
local _, entry = Queue:Find(GAUNTLETS_RECIPE, true)
check("a second click queues no more", entry.quantity == 1)

ok, why = Queue:Ensure(99999, 1)
check("an unknown recipe says why", ok == nil and type(why) == "string")

print("\nthe x and Clear all")

Queue:EnsureBuy(CLOAK, 1, CLOAK)
selfKey = "Bob-Realm"
Queue:EnsureBuy(CLOAK, 1, CLOAK)
selfKey = "Ana-Realm"
check("each character has its own line", #ns.db.queueBuys == 2)
notified = 0
check("the x takes it off", Queue:RemoveBuys(CLOAK) == true and Line(CLOAK) == nil)
check("and redraws", notified == 1)
check("only for this character", #ns.db.queueBuys == 1)
Queue:EnsureBuy(STONE, 2, GAUNTLETS)
Queue:Clear()
check("Clear all empties this character's list", not Queue:HasBuys() and #ns.db.queueBuys == 1)

worn[GAUNTLETS] = 1
selfKey = "Bob-Realm"
Queue:EnsureBuy(BAR, 8, GAUNTLETS)
check("gear already worn is not put on the list", Line(BAR) == nil)

print("\nan old save without the list")

ns.db.queueBuys = nil
check("reads as empty", not Queue:HasBuys() and Queue:GetShoppingList() ~= nil)
worn[GAUNTLETS] = nil
check("and makes the list when asked", Queue:EnsureBuy(CLOAK, 1, CLOAK) == true and #ns.db.queueBuys == 1)

print("\nmaterials to learn a recipe and skill up (Learn next)")

ns.db.queueBuys = {}
selfKey = "Ana-Realm"
bags[GAUNTLETS] = 1
local learn = { recipeID = GAUNTLETS_RECIPE, name = "Gauntlets" }
check("go on the list though one is owned", Queue:EnsureBuy(BAR, 40, nil, learn) == true)
check("and stay on it", Line(BAR) and Line(BAR).needed == 40)
check("saying the recipe they are for", Line(BAR).buys[1].forRecipe == GAUNTLETS_RECIPE
    and Line(BAR).buys[1].forRecipeName == "Gauntlets")
Queue:EnsureBuy(BAR, 40, nil, learn)
check("a second click buys no more", #ns.db.queueBuys == 1)
check("never an upgrade to buy", Queue:ForUpgrade(GAUNTLETS) == nil)
bags[GAUNTLETS] = nil

print("\nlearning the recipe queues the craft (Road to 300's Queue Step)")

ns.db.queue, ns.db.queueBuys = {}, {}
ns.db.characters = { ["Ana-Realm"] = { recipes = {} } }
selfKey = "Ana-Realm"
Queue:EnsureBuy(BAR, 40, nil, { recipeID = GAUNTLETS_RECIPE, name = "Gauntlets", crafts = 5 })
Queue:EnsureBuy(STONE, 10, nil, { recipeID = GAUNTLETS_RECIPE, name = "Gauntlets", crafts = 5 })
check("the line keeps how many crafts it was for", ns.db.queueBuys[1].forRecipeCrafts == 5)
check("nothing is queued while the recipe is unknown", Queue:QueueLearned() == 0
    and #ns.db.queue == 0 and #ns.db.queueBuys == 2)
ns.db.characters["Ana-Realm"].recipes[GAUNTLETS_RECIPE] = recipes[GAUNTLETS_RECIPE]
check("once learned, the craft goes in the queue", Queue:QueueLearned() == 1)
local _, entry = Queue:Find(GAUNTLETS_RECIPE, true)
check("as many crafts as the step asked for", entry and entry.quantity == 5)
check("and its materials leave the list to buy", #ns.db.queueBuys == 0)
check("a second look queues nothing more", Queue:QueueLearned() == 0)

ns.db.queue, ns.db.queueBuys = {}, {}
table.insert(ns.db.queueBuys, { itemID = BAR, count = 24, forRecipe = GAUNTLETS_RECIPE,
    forRecipeName = "Gauntlets", owner = "Ana-Realm" })
Queue:QueueLearned()
_, entry = Queue:Find(GAUNTLETS_RECIPE, true)
check("an older line works out its crafts from its count", entry and entry.quantity == 3)

ns.db.queue, ns.db.queueBuys = {}, {}
table.insert(ns.db.queueBuys, { itemID = BAR, count = 8, forRecipe = GAUNTLETS_RECIPE,
    forRecipeCrafts = 1, owner = "Bob-Realm" })
check("another character's line is left alone", Queue:QueueLearned() == 0 and #ns.db.queueBuys == 1)
ns.db.characters = nil

print(("\n%d checks passed"):format(checks))
