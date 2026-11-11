-- Logic/RoadPlan.lua outside WoW.
--
-- Road to 300 (the owner said build it, 2026-10-20). What must hold:
--   1. The chance a craft gives a point: 1 below yellow, (grey - skill) /
--      (grey - yellow) from yellow to grey, 0 at grey.
--   2. Each stretch takes the recipe cheapest a point, known or taught by a
--      trainer or vendor of the player's side; its price counted once.
--   3. A step is one recipe in one colour: orange is "every craft",
--      yellow "most crafts", green (from halfway to grey) "some crafts",
--      and its crafts are 1 / chance a point.
--   4. Trainer steps at Classic's ranks, Journeyman at 50 to 150 and so on,
--      a level chip and "You're level N." when the level is short.
--   5. Steps below the skill now are done; what the bags and bank hold
--      comes off once, in order, and the footer says how much it saved.
--   6. Queue Step queues a known recipe's crafts, or a recipe still to
--      learn's materials on the list to buy; Queue All every step left.
--   7. The plan is kept by key and worked out again when it moves.
--   8. The list shows the steps left first, the done ones after.

local GLOBALS = { "time", "GetTime", "UnitFactionGroup", "GetRealZoneText", "GetLocale",
  "UnitLevel", "C_Timer", "C_Map", "C_QuestLog", "GetProfessions", "GetProfessionInfo" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {} ns[name] = m return m end
local printed = {}
ns.Print = function(text) printed[#printed + 1] = text end
ns.Debug = function() end

time = function() return 1000 end
GetTime = function() return 1000 end
UnitFactionGroup = function() return "Alliance" end
GetRealZoneText = function() return "Ironforge" end
GetLocale = function() return "enUS" end
UnitLevel = function() return 15 end
C_Timer = nil
C_Map = nil

local settings = { auctionCut = 0.05, valueOwnedMaterials = true }
ns.Config = {
  Get = function(_, key) return settings[key] end,
  GetCharacterKey = function() return "me" end,
}
ns.Util = {
  FormatMoney = function(c) return tostring(c) .. "c" end,
  HasFunction = function() return false end,
  GetItemLabel = function(id)
    local names = { [2840] = "Copper Bar", [2835] = "Rough Stone", [3470] = "Rough Grinding Stone",
      [2851] = "Copper Chain Belt", [2862] = "Rough Sharpening Stone", [3478] = "Coarse Grinding Stone",
      [2836] = "Coarse Stone" }
    return names[id] or ("item " .. id)
  end,
  Uncolored = function(text) return text end,
  GetVendorSellPrice = function(id) return ({ [5467] = 9, [6889] = 2 })[id] end,
}

local BAR, ROUGH, COARSE = 2840, 2835, 2836
ns.RECIPE_BOOK = {
  PROFESSIONS = { [164] = "Blacksmithing", [185] = "Cooking" },
  RECIPES = {
    -- Rough Sharpening Stone, a starter: orange to 15, grey at 45.
    [1] = { 164, 1, 2862, 1, 1, { ROUGH, 1 }, "Rough Sharpening Stone", s = 1 },
    -- Rough Grinding Stone, known: orange to 45, grey at 65.
    [2] = { 164, 25, 3470, 1, 1, { ROUGH, 2 }, "Rough Grinding Stone", t = 10 },
    -- Copper Chain Belt, taught by a trainer: orange to 120, grey 150.
    [3] = { 164, 35, 2851, 1, 1, { BAR, 6 }, "Copper Chain Belt", t = 50 },
    -- Coarse Grinding Stone, from a trainer at 75, cheap.
    [4] = { 164, 75, 3478, 1, 1, { COARSE, 2 }, "Coarse Grinding Stone", t = 200 },
    -- Taught by nobody: never on the road.
    [5] = { 164, 30, 9999, 1, 1, { BAR, 1 }, "Dropped Thing" },
    -- Cooking: Classic's Basic Campfire, Forever's remade one (grey at 5)
    -- and Roasted Kodo Meat, known, from meat nobody lists.
    [818] = { 185, 1, 0, 1, 1, { 4470, 1 }, "Basic Campfire", s = 1 },
    [1229737] = { 185, 1, 279981, 1, 1, { 4470, 1 }, "Basic Campfire", f = 1, y = 1, g = 5, s = 1 },
    [6414] = { 185, 35, 5474, 2, 2, { 5467, 1, 2678, 1 }, "Roasted Kodo Meat" },
    [8604] = { 185, 1, 6888, 1, 1, { 6889, 1, 2678, 1 }, "Herb Baked Egg", s = 1 },
  },
  ITEMS = {},
}
ns.LEARN_SPOTS = {
  SKILLS = {
    [1] = { 1, 15, 45 },
    [2] = { 25, 45, 65 },
    [3] = { 35, 120, 150 },
    [4] = { 75, 300, 310 },
    [5] = { 30, 300, 310 },
    [818] = { 1, 25, 75 },
    [6414] = { 35, 75, 115 },
    [8604] = { 1, 45, 85 },
  },
  TRAINERS = {
    [164] = {
      { "Horde Hank", "Orgrimmar", 50, 50, "H", 300 },
      { "Apprentice Al", "Ironforge", 10, 20, "A", 75 },
      { "Journey Jo", "Ironforge", 52, 41, "A", 150 },
      { "Master Mo", "Ironforge", 50, 40, "A", 300 },
    },
  },
  MATERIALS = {},
  MADE = {},
  VENDORS = {},
}

local prices = { [BAR] = 20, [ROUGH] = 5, [COARSE] = 3, [4470] = 1, [2678] = 1 }
ns.Prices = { GetValue = function(_, id) return prices[id] end, scanCount = 1 }
ns.Vendor = {
  GetUnitPrice = function() return nil end,
  IsLimited = function() return false end,
  GetTable = function() return {} end,
}
local bags = { [BAR] = 51 }
local bank = { [BAR] = 10 }
ns.Inventory = {
  changes = 1,
  GetBagCount = function(_, id) return bags[id] or 0 end,
  GetBankCount = function(_, id) return bank[id] or 0 end,
  GetCharacterBagCount = function(_, _, id) return bags[id] or 0 end,
}
ns.Recipes = {
  GetAny = function() return nil end,
  GetAll = function() return {} end,
  GetAccountWide = function()
    return { [1] = { knownBy = { "me" } }, [2] = { knownBy = { "me" } }, [6414] = { knownBy = { "me" } } }
  end,
  GetShortCharacterName = function(_, key) return key end,
  GetLearnedProfessions = function()
    return { { name = "Blacksmithing", skillLineID = 2938, skillLevel = 62, maxSkillLevel = 75, learned = true } }
  end,
}
ns.db = { characters = { me = { recipesCachedAt = 5 } } }
ns.charDb = {}

assert(loadfile(lfs_cwd .. "/Logic/Cost.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/RecipeBook.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Waypoints.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/LearnNext.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/RoadPlan.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Welcome.lua"))("Blackthornes_TS", ns)
ns.LevelUp = {
  GetReturns = function(_, record)
    if record.outputItemID == 2851 then return { best = 1800, bestWay = "auction" } end
    return nil
  end,
}

local Road = ns.RoadPlan
local failures = 0
local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(string.format("  FAIL  %-56s got %s, wanted %s", label, tostring(got), tostring(want)))
  else
    print(string.format("  ok    %-56s %s", label, tostring(got)))
  end
end

print("\nthe chance of a point")
local belt = ns.RecipeBook:Get(3)
check("below yellow, every craft", Road.Chance(belt, 60), 1)
check("halfway from yellow to grey", Road.Chance(belt, 135), 0.5)
check("grey gives nothing", Road.Chance(belt, 150), 0)

print("\nthe colours, as the game paints them")
-- Light Armor Kit: yellow at 30, green at 45, grey at 60.
local kit = { yellow = 30, grey = 60, skill = 1 }
check("orange below yellow", Road.Tier(kit, 29), "optimal")
check("yellow from 30", Road.Tier(kit, 30), "medium")
check("still yellow at 44", Road.Tier(kit, 44), "medium")
check("green from 45", Road.GreenFrom(kit), 45)
check("green at 51", Road.Tier(kit, 51), "easy")
check("grey at 60", Road.Tier(kit, 60), "trivial")
local kitPlan = Road:Plan({
  line = 164, skill = 25, max = 150, level = 15,
  candidates = { { record = { recipeID = 88, name = "Light Armor Kit", skill = 1, yellow = 30, grey = 60,
    reagents = { { itemID = BAR, quantity = 1 } } }, known = true,
    price = { cost = 10, reagents = { { itemID = BAR, quantity = 1, unit = 10 } } } } },
  owned = {},
})
local bands = {}
for _, step in ipairs(kitPlan.steps) do
  if not step.done and step.kind == "craft" then bands[#bands + 1] = step end
end
check("three steps: orange, yellow, green", #bands, 3)
check("orange to 30", bands[1] and bands[1].to, 30)
check("yellow from 30 to 45", bands[2] and (bands[2].from .. "-" .. bands[2].to), "30-45")
check("yellow: most crafts", bands[2] and Road.Texts(bands[2], "Blacksmithing", 15, 164).chip, "most crafts")
check("green from 45 to 60", bands[3] and (bands[3].from .. "-" .. bands[3].to), "45-60")
check("green: some crafts", bands[3] and Road.Texts(bands[3], "Blacksmithing", 15, 164).chip, "some crafts")
check("below what it needs, nothing", Road.Chance(belt, 20), 0)

print("\nthe professions")
local professions = Road:Professions()
check("one crafting profession", #professions, 1)
check("by its Classic line", professions[1].line, 164)
check("with its skill", professions[1].skill, 62)

print("\nthe road at Blacksmithing 62 / 75, level 15")
local plan = Road:Get(professions[1])
check("a plan", plan ~= nil, true)
local steps = plan.steps
local function Find(test)
  for index, step in ipairs(steps) do if test(step) then return step, index end end
end

local current = steps[plan.current]
check("the step to do now is not done", current and not current.done, true)
check("steps before it are done", steps[1].done, true)
local firstDone = steps[1]
check("the road walked starts at 1", firstDone.from, 1)

local journeyman, jIndex = Find(function(s) return s.kind == "trainer" and s.cap == 150 end)
check("Journeyman is a step", journeyman ~= nil, true)
check("not done: the cap is 75", journeyman and not journeyman.done, true)
check("learned at 50", journeyman and journeyman.at, 50)
check("Journeyman's price", journeyman and journeyman.cost, 450)
check("the level is enough", journeyman and journeyman.locked, nil)
check("the trainer is the step to do now", jIndex, plan.current)
local texts = Road.Texts(journeyman, "Blacksmithing", 15, 164)
check("its title", texts.title, "Train Journeyman Blacksmithing")
check("its range", texts.range, "at 50, raises your cap to 150")
check("the nearest trainer of your side", texts.lines[1], "Blacksmithing trainer in Ironforge")
check("who teaches that far", Road:PlaceFor(journeyman, 164).name, "Journey Jo")

local grinding = steps[plan.current + 1]
check("a known recipe first, while it is cheapest", grinding.recipeID, 2)
check("from the skill now", grinding.from, 62)
check("green past halfway to grey (55): some crafts", Road.Texts(grinding, "Blacksmithing", 15, 164).chip, "some crafts")
check("green: the game's colour", grinding.tier, "easy")
check("1 / chance a point: 2 points take 17 crafts", grinding.crafts, 17)
check("known: nothing to learn", grinding.learn, nil)

local beltStep = Find(function(s) return s.kind == "craft" and s.recipeID == 3 and not s.done end)
check("the belt takes over where cheaper", beltStep and beltStep.from, 64)
check("to the cap the next recipe beats it", beltStep and beltStep.to, 75)
check("every craft a point", beltStep and beltStep.crafts, 11)
check("still to learn, at its trainer", beltStep and beltStep.learn and beltStep.learn.kind, "trainer")
texts = Road.Texts(beltStep, "Blacksmithing", 15, 164)
check("Make N item", texts.title, "Make 11 Copper Chain Belt")
check("chip", texts.chip, "every craft")
check("range", texts.range, "64 to 75")
check("materials from bags then bank", texts.lines[1],
  "Needs 66 Copper Bar. You have 51, buy 5. Your banker has 10.")
check("where it is learned, with the trainer's zone", texts.lines[2],
  "Learn it from the Blacksmithing trainer in " .. tostring(beltStep.learn.zone) .. ".")
check("the trainer has a zone", beltStep.learn.zone ~= nil, true)
local vendorStep = { kind = "craft", crafts = 44, from = 1, to = 45, orange = true, name = "Slitherskin Mackerel",
  needs = {}, learn = { kind = "vendor", zone = "Tirisfal Glades" } }
check("a vendor recipe says it isn't known yet, and where to buy it",
  Road.Texts(vendorStep, "Cooking", 9, 185).lines[1],
  "You don't know this recipe yet. Buy it from a vendor in Tirisfal Glades.")
vendorStep.learn.zone = nil
check("and without a zone", Road.Texts(vendorStep, "Cooking", 9, 185).lines[1],
  "You don't know this recipe yet. Buy it from a vendor.")
check("sells some back", texts.lines[#texts.lines], "Sells for about 1800c each, so it pays some back.")
check("cost: what to buy and the recipe", beltStep.cost, 5 * 20 + 50)

local coarse = Find(function(s) return s.kind == "craft" and s.recipeID == 4 end)
check("a cheaper recipe takes over when reached", coarse ~= nil, true)
check("never the recipe no one teaches", Find(function(s) return s.recipeID == 5 end), nil)

local artisan = Find(function(s) return s.kind == "trainer" and s.cap == 300 end)
check("Artisan is locked at level 15", artisan and artisan.locked, true)
texts = Road.Texts(artisan, "Blacksmithing", 15, 164)
check("Artisan's title", texts.title, "Train Artisan Blacksmithing")
check("level chip", texts.chip, "level 35")
check("at its skill", texts.range, "at 200")
check("says your level", texts.lines[1], "You're level 15.")

check("the road reaches 300", steps[#steps].to == 300 or steps[#steps].kind == "trainer", true)
check("nothing stuck", plan.stuck, nil)
check("saved: what you own, priced", plan.saved, 61 * 20)
local sum = 0
for _, step in ipairs(steps) do if not step.done then sum = sum + (step.cost or 0) end end
check("the total is the steps left", plan.total, sum)

local walkedDone = Find(function(s) return s.done and s.kind == "craft" end)
check("a done step's text", Road.Texts(walkedDone, "Blacksmithing", 15, 164).chip, nil)

print("\nwhat you own comes off once")
local plain = { recipeID = 77, name = "Plain", skill = 1, yellow = 40, grey = 80,
  reagents = { { itemID = BAR, quantity = 1 } } }
local small = Road:Plan({
  line = 164, skill = 10, max = 75, level = 15,
  candidates = { { record = plain, known = true,
    price = { cost = 20, reagents = { { itemID = BAR, quantity = 1, unit = 20 } } } } },
  owned = { [BAR] = { 40, 5 } },
})
local orange, after
for _, step in ipairs(small.steps) do
  if not step.done and step.kind == "craft" then
    if step.orange then orange = step elseif not after then after = step end
  end
end
check("orange from 10 to 40: 30 crafts", orange and orange.crafts, 30)
check("all from the bags", orange and orange.needs[1].bags, 30)
check("the next step gets what is left", after and after.needs[1].bags, 10)
check("then the bank", after and after.needs[1].bank, 2)
check("saved is what was used", small.saved, 45 * 20)
check("a road past its last recipe says where it stops", small.stuck, 80)

print("\nwhat your other characters hold")
local covered = Road:Plan({
  line = 164, skill = 10, max = 75, level = 15,
  candidates = { { record = plain, known = true,
    price = { cost = 20, reagents = { { itemID = BAR, quantity = 1, unit = 20 } } } } },
  owned = { [BAR] = { 10, 5, 100 } },
})
local first, second
for _, step in ipairs(covered.steps) do
  if not step.done and step.kind == "craft" then
    if not first then first = step elseif not second then second = step end
  end
end
check("bags, bank, then the other characters", first and first.needs[1].alts, 15)
check("nothing to buy on the first step", first and first.needs[1].buy, 0)
texts = Road.Texts(first, "Blacksmithing", 15, 164)
check("names what the others hold", texts.lines[1],
  "Needs 30 Copper Bar. You have 10. Your banker has 5. Your other characters have 15.")
check("says the step is covered", texts.lines[2], "You have enough for this step.")
check("a step still short is not covered", Road.Covered(beltStep), false)

local savedDb, savedChars, savedQueue = ns.db, ns.Characters, ns.Queue
ns.db = { characters = {
  me = { inventory = { [BAR] = 99 } },
  alt = { inventory = { [BAR] = 3 }, bank = { [BAR] = 4 }, mail = { [BAR] = 5 } },
  old = { inventory = { [BAR] = 50 } },
  other = { inventory = { [BAR] = 70 }, linkedFrom = "x" },
  horde = { inventory = { [BAR] = 80 } },
} }
ns.Characters = {
  IsPlaying = function(_, key) return key == "me" end,
  Same = function(_, a, b) return (a == "old" and b == "alt") or (a == "alt" and b == "old") end,
}
ns.Queue = { CanMail = function(_, _, to) return to ~= "horde" end }
local alts = Road.AltsHold(BAR)
check("alts: bags, bank and mail, each character once, never the other side or account",
  alts == 12 or alts == 50, true)
settings.countMailAsStock = false
check("mail left out when it does not count", Road.AltsHold(BAR) == 7 or Road.AltsHold(BAR) == 50, true)
settings.countMailAsStock = nil
ns.db, ns.Characters, ns.Queue = savedDb, savedChars, savedQueue

print("\nkept by key")
check("the same plan again", Road:Get(professions[1]), plan)
ns.Inventory.changes = 2
check("a new one once the bags move", Road:Get(professions[1]) ~= plan, true)

print("\nqueue")
local ensured, bought = {}, {}
ns.Queue = {
  Ensure = function(_, id, count) ensured[id] = count return true end,
  EnsureBuy = function(_, id, count, _, forRecipe) bought[id] = { count, forRecipe } return true end,
}
check("a recipe to learn puts its materials to buy", Road:QueueStep(beltStep), true)
check("all of them", bought[BAR] and bought[BAR][1], 66)
check("tied to the recipe", bought[BAR] and bought[BAR][2].recipeID, 3)
local known = { kind = "craft", recipeID = 2, crafts = 7, needs = {} }
check("a known recipe is queued", Road:QueueStep(known), true)
check("its crafts", ensured[2], 7)
check("a trainer step queues nothing", Road:QueueStep(journeyman), false)
ensured, bought = {}, {}
local count = Road:QueueAll(plan)
check("Queue All: every craft step left", count > 1, true)
check("never a done step", ensured[1], nil)

print("\ndone steps go to the foot of the list")
local a, b, c, d = { done = true }, { done = true }, {}, {}
local shown = Road.Shown({ a, b, c, d })
check("the step to do now is first", shown[1], c)
check("then the next one left", shown[2], d)
check("done steps after, in order", shown[3] == a and shown[4] == b, true)
check("nothing lost", #shown, 4)
check("the plan keeps its own order", plan.steps[1].done, true)

print("\nPick By: lowest or real cost")
local cheap = { recipeID = 81, name = "Cheap", skill = 1, yellow = 40, grey = 80,
  reagents = { { itemID = BAR, quantity = 1 } } }
local sells = { recipeID = 82, name = "Sells", skill = 1, yellow = 40, grey = 80,
  reagents = { { itemID = BAR, quantity = 2 } } }
local function PickPlan(pickBy)
  return Road:Plan({
    line = 164, skill = 10, max = 75, level = 15, pickBy = pickBy, owned = {},
    candidates = {
      { record = cheap, known = true, price = { cost = 20, back = 0,
        reagents = { { itemID = BAR, quantity = 1, unit = 20 } } } },
      { record = sells, known = true, price = { cost = 30, back = 25,
        reagents = { { itemID = BAR, quantity = 2, unit = 15 } } } },
    },
  })
end
local function FirstCraft(p)
  for _, step in ipairs(p.steps) do
    if not step.done and step.kind == "craft" then return step end
  end
end
local lowest = PickPlan(nil)
check("the usual pick is lowest cost", lowest.pickBy, "lowest")
check("lowest cost takes the cheaper craft", FirstCraft(lowest).recipeID, 81)
check("nothing comes back from it", lowest.back, 0)
local real = PickPlan("real")
check("real cost is kept on the plan", real.pickBy, "real")
check("real cost takes the craft that sells back", FirstCraft(real).recipeID, 82)
check("what selling brings back", real.back > 0, true)
check("To 300 still counts what you spend", real.total > lowest.total, true)
check("the setting is lowest unless picked", Road.PickBy(), "lowest")
local before = Road:Get(professions[1])
settings.roadPickBy = "real"
check("the setting reads real once picked", Road.PickBy(), "real")
local switched = Road:Get(professions[1])
check("a new pick makes a new plan", switched ~= before, true)
check("planned by real cost", switched and switched.pickBy, "real")
settings.roadPickBy = "junk"
check("anything else reads as lowest", Road.PickBy(), "lowest")
settings.roadPickBy = nil

print("\nReal cost: a craft that sells for more than it costs")
-- Alchemy at 87: both early crafts pay. The road used to stay on the elixir
-- to grey, 144 crafts for 100 to 120.
local function Potion(id, name, skill, yellow, grey, cost, back)
  return { record = { recipeID = id, name = name, skill = skill, yellow = yellow, grey = grey,
    reagents = { { itemID = BAR, quantity = 1 } } }, known = true,
    price = { cost = cost, back = back, reagents = { { itemID = BAR, quantity = 1, unit = cost } } } }
end
local paying = Road:Plan({
  line = 171, skill = 87, max = 150, level = 30, pickBy = "real", owned = {},
  candidates = {
    Potion(91, "Pays A", 50, 80, 120, 287, 318),
    Potion(92, "Pays B", 80, 80, 100, 70, 118),
    Potion(93, "Orange", 90, 120, 150, 300, 150),
    Potion(94, "Later", 110, 135, 175, 350, 200),
  },
})
local most, lowChance, reach = 0, 1, 0
for _, step in ipairs(paying.steps) do
  if not step.done and step.kind == "craft" then
    most = math.max(most, step.to <= 125 and step.crafts or 0)
    if step.recipeID == 91 or step.recipeID == 92 then
      lowChance = math.min(lowChance, Road.Chance(step.record, step.to - 1))
    end
    reach = math.max(reach, step.to)
  end
end
check("no long yellow step before 125", most < 40, true)
check("a paying craft is left before its chance gets small", lowChance >= 0.1, true)
check("the road still goes on", reach >= 150, true)
check("a paying craft still wins while its chance is good", FirstCraft(paying).recipeID, 92)

print("\nCooking and First Aid: Expert from a book, Artisan from quests")
local cookPlan = Road:Plan({ line = 185, skill = 125, max = 150, level = 31, candidates = {} })
local expertBook
for _, step in ipairs(cookPlan.steps) do
  if step.kind == "trainer" and step.cap == 225 then expertBook = step end
end
check("Cooking's Expert is a step", expertBook ~= nil, true)
check("it is learned from a book", expertBook and expertBook.how and expertBook.how.kind, "book")
check("the book costs 1g", expertBook and expertBook.cost, 10000)
local bookTexts = Road.Texts(expertBook, "Cooking", 31, 185)
check("its title", bookTexts.title, "Learn Expert Cooking")
check("its range", bookTexts.range, "at 125, raises your cap to 225")
check("the Alliance seller", bookTexts.lines[1], "Buy Expert Cookbook from Shandrina in Ashenvale.")
check("Show the Way goes to the seller", Road:PlaceFor(expertBook, 185).name, "Shandrina")

local doneQuests = {}
C_QuestLog = { IsQuestFlaggedCompleted = function(id) return doneQuests[id] == true end }
local artisan = { kind = "trainer", rank = Road.RANKS[185][3], how = Road.RANKS[185][3].how,
  at = 225, cap = 300, level = 35, locked = true }
local artTexts = Road.Texts(artisan, "Cooking", 31, 185)
check("Artisan's title", artTexts.title, "Learn Artisan Cooking")
check("a level chip while too low", artTexts.chip, "level 35")
check("starts with the first quest", artTexts.lines[1],
  "Start with the quest I Know A Guy... from Daryl Riknussun in Ironforge.")
check("says who teaches it", artTexts.lines[2], "It leads to Dirge Quikcleave in Tanaris, who teaches you.")
check("and the level", artTexts.lines[3], "You're level 31.")
check("no price is shown", artisan.cost, nil)
doneQuests[6612] = true
artisan.locked = nil
artTexts = Road.Texts(artisan, "Cooking", 40, 185)
check("the last quest once the first is done", artTexts.lines[1],
  "Do the quest Clamlette Surprise for Dirge Quikcleave in Tanaris. Then they teach you.")
check("Show the Way moves along", Road:PlaceFor(artisan, 185).name, "Dirge Quikcleave")
UnitFactionGroup = function() return "Horde" end
doneQuests = {}
local aid = { kind = "trainer", rank = Road.RANKS[129][3], how = Road.RANKS[129][3].how, at = 225, cap = 300, level = 40 }
check("Horde First Aid starts with Arnok", Road.Texts(aid, "First Aid", 40, 129).lines[1],
  "Start with the quest Horde Trauma from Arnok in Orgrimmar.")
local aidBook = { kind = "trainer", rank = Road.RANKS[129][2], how = Road.RANKS[129][2].how, at = 125, cap = 225, level = 1 }
check("Horde First Aid book seller", Road.Texts(aidBook, "First Aid", 40, 129).lines[1],
  "Buy Expert First Aid - Under Wraps from Balai Lok'Wein in Dustwallow Marsh.")
UnitFactionGroup = function() return "Alliance" end
C_QuestLog = nil

print("\nthe Welcome card's picks order the roads")
ns.Recipes.GetLearnedProfessions = function()
  return {
    { name = "Blacksmithing", skillLineID = 2938, skillLevel = 62, maxSkillLevel = 75, learned = true },
    { name = "Tailoring", skillLineID = 197, skillLevel = 10, maxSkillLevel = 75, learned = true },
    { name = "Mining", skillLineID = 186, skillLevel = 50, maxSkillLevel = 75, learned = true },
  }
end
check("gathering left out, by name", #Road:Professions(), 2)
ns.Welcome:SetPicks({ 197 })
check("a pick comes first", Road:Professions()[1].name, "Tailoring")

print("\nCooking and First Aid in the list")
ns.Welcome:SetPicks({})
ns.Recipes.SKILL_LINE_PROFESSIONS = { [2938] = "Blacksmithing", [164] = "Blacksmithing",
  [185] = "Cooking", [129] = "First Aid" }
ns.Recipes.EnglishProfessionName = function(p)
  return ns.Recipes.SKILL_LINE_PROFESSIONS[p.skillLineID] or p.name
end
ns.Recipes.GetLearnedProfessions = function()
  return {
    { name = "Blacksmithing", skillLineID = 2938, skillLevel = 62, maxSkillLevel = 75, learned = true },
    { name = "Cooking", skillLineID = 2950, skillLevel = 40, maxSkillLevel = 75, learned = true },
  }
end
local function HasLine(list, line)
  for _, p in ipairs(list) do if p.line == line then return p end end
end
local cooking = HasLine(Road:Professions(), 185)
check("Cooking under a second ID, by name", cooking and cooking.skill, 40)
GetProfessions = function() return nil, nil, nil, nil, 5, 6 end
GetProfessionInfo = function(index)
  if index == 5 then return "Cooking", nil, 40, 75, nil, nil, 185 end
  if index == 6 then return "First Aid", nil, 120, 150, nil, nil, 129 end
end
local list = Road:Professions()
check("First Aid from the Professions book", HasLine(list, 129) and HasLine(list, 129).skill, 120)
check("Cooking listed once", #list, 3)
GetProfessionInfo = function(index)
  if index == 6 then return "First Aid", nil, 0, 0, nil, nil, 129 end
end
check("an unlearned one is left out", HasLine(Road:Professions(), 129), nil)

print("\nthe Cooking road uses real recipes")
Road:Forget()
local cookPlan = Road:Get({ line = 185, skill = 74, max = 150, name = "Cooking" })
local usesOld, kodo, campfires = false, false, 0
for _, step in ipairs(cookPlan.steps) do
  if step.recipeID == 818 then usesOld = true end
  if step.kind == "craft" and step.name == "Basic Campfire" and not step.done then campfires = campfires + 1 end
  if step.name == "Roasted Kodo Meat" and not step.done then kodo = true end
end
check("Classic's Basic Campfire left out", usesOld, false)
check("no campfire steps from 74", campfires, 0)
check("Roasted Kodo Meat from meat nobody lists", kodo, true)
check("goes past 75", (cookPlan.stuck or 300) > 75, true)
local kodoPrice = Road.Price(ns.RecipeBook:Get(6414))
check("unlisted meat priced at what a vendor pays", kodoPrice and kodoPrice.cost, 10)

print("\nthe Cooking road after the cooking window was open")
-- The window gives Cooking's second skill line, which ClassicLine does not
-- know: the recipes it showed still belong on the Cooking road.
ns.db.seenRecipes = {
  [1229737] = { name = "Basic Campfire", skillLineID = 2950, reagents = { { itemID = 4470, quantity = 1 } } },
  [6414] = { name = "Roasted Kodo Meat", outputItemID = 5474, skillLineID = 2950,
    reagents = { { itemID = 5467, quantity = 1 }, { itemID = 2678, quantity = 1 } } },
  [8604] = { name = "Herb Baked Egg", outputItemID = 6888, skillLineID = 2950,
    reagents = { { itemID = 6889, quantity = 1 }, { itemID = 2678, quantity = 1 } } },
}
ns.RecipeBook:Invalidate()
Road:Forget()
cookPlan = Road:Get({ line = 185, skill = 74, max = 150, name = "Cooking" })
usesOld, kodo, campfires = false, false, 0
for _, step in ipairs(cookPlan.steps) do
  if step.recipeID == 818 then usesOld = true end
  if step.kind == "craft" and step.name == "Basic Campfire" and not step.done then campfires = campfires + 1 end
  if step.name == "Roasted Kodo Meat" and not step.done then kodo = true end
end
check("seen: Classic's Basic Campfire left out", usesOld, false)
check("seen: no campfire steps from 74", campfires, 0)
check("seen: Roasted Kodo Meat on the road", kodo, true)
check("seen: goes past 75", (cookPlan.stuck or 300) > 75, true)
ns.db.seenRecipes = nil
ns.RecipeBook:Invalidate()

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print("")
if failures > 0 then error(string.format("%d road to 300 check(s) failed", failures)) end
print("  all road to 300 checks passed")
print("")
