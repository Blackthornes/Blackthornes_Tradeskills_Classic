-- Logic/Butler.lua's Jobs and Craft outside WoW.
--
-- Butler's step list asks Tradeskills for every character's jobs in the
-- queue (the owner asked 2026-10-11 for a way to craft on another
-- character and send it back). What must hold:
--   1. One entry per character with a step, the character playing first,
--      then by name; full names, never shortened.
--   2. A craft step says what it makes, for whom, and what it still needs.
--   3. The character playing's mail is the Mail panel's deliveries; the
--      others' is what they made and still owe.
--   4. Characters on another realm, side or account are left out.
--   5. Craft starts the craft only with the profession open, else opens
--      the Queue tab; never raises.

GetTime = function() return 100 end

local ns = {}
ns.NewModule = function(name) local m = {} ns[name] = m return m end

local ANA, WITHER, CY, LINKED = "Player-1", "Player-2", "Player-3", "Player-4"
ns.db = {
  characters = {
    [ANA] = { name = "Ana", surname = "Blackthorne", realm = "R", faction = "Alliance" },
    [WITHER] = { name = "Blackthornes", surname = "Wither", realm = "R", faction = "Alliance" },
    [CY] = { name = "Cy", surname = "Horde", realm = "R", faction = "Horde" },
    [LINKED] = { name = "Lin", surname = "Ked", realm = "R", faction = "Alliance", linkedFrom = ANA },
  },
}
local selfKey = ANA
ns.Config = { GetCharacterKey = function() return selfKey end, Get = function() return nil end }

local recipes = {
  [10] = { name = "Medium Leather", outputItemID = 2319, quantityMin = 1,
    reagents = { { itemID = 2318, quantity = 4 } } },
  [11] = { name = "Linen Bag", outputItemID = 4238, reagents = { { itemID = 2996, quantity = 3 } } },
  [12] = { name = "Orc Thing", outputItemID = 9, reagents = {} },
}
ns.Recipes = {
  GetAny = function(_, recipeID) return recipes[recipeID] end,
  GetCharacterName = function(_, key)
    local r = ns.db.characters[key]
    return r.name .. " " .. r.surname
  end,
}

local queue = {
  { recipeID = 10, quantity = 20, isDependency = true, crafter = WITHER, forCharacters = { [ANA] = true } },
  { recipeID = 11, quantity = 1, owner = ANA, crafter = ANA },
  { recipeID = 12, quantity = 1, crafter = CY },
  { recipeID = 11, quantity = 2, crafter = LINKED },
}
local held = { [WITHER] = { [2318] = 80 }, [ANA] = { [2996] = 1 } }
ns.Queue = {
  GetAll = function() return queue end,
  GetCrafter = function(_, entry) return entry.crafter end,
  GetRecipients = function(_, entry)
    local list = {}
    for key in pairs(entry.forCharacters or {}) do if key ~= entry.crafter then list[#list + 1] = key end end
    return list
  end,
  HeldBy = function(_, key, itemID) return (held[key] or {})[itemID] or 0 end,
  CanMail = function(_, from, to)
    return ns.db.characters[from].faction == ns.db.characters[to].faction
  end,
}
local owed = { [WITHER] = { [ANA] = { [2319] = 5 } } }
ns.QueueMail = {
  IsPlaying = function(_, key) return key == selfKey end,
  GetDeliveries = function()
    return { { to = WITHER, name = "Blackthornes Wither", items = { { itemID = 2318, count = 30 } } } }
  end,
  GetOwedBy = function(_, from) return owed[from] or {} end,
}

local vendorPrices = {}
ns.Vendor = { GetUnitPrice = function(_, itemID) return vendorPrices[itemID] end }
assert(loadfile(lfs_cwd .. "/Core/Characters.lua"))("Blackthornes_TS", ns)
local chunk = assert(loadfile(lfs_cwd .. "/Logic/Butler.lua"))
chunk("Blackthornes_TS", ns)
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

print("\njobs")
local jobs = Butler:Jobs()
check("two characters have jobs", #jobs, 2)
check("the character playing first", jobs[1].name, "Ana Blackthorne")
check("and says so", jobs[1].isCurrent, true)
check("then the alt, by full name", jobs[2].name, "Blackthornes Wither")
check("the alt is not the one playing", jobs[2].isCurrent, false)

local bag = jobs[1].steps[1]
check("Ana crafts the bag", bag.kind, "craft")
check("one of them", bag.count, 1)
check("short of linen", bag.ready, false)
check("by two", bag.missing[1] and bag.missing[1].count, 2)
check("for nobody else", #bag.forNames, 0)
check("no vendor sells linen", bag.missing[1] and bag.missing[1].vendor, nil)
vendorPrices[2996] = 10
check("a vendor material says what one costs", Butler:Jobs()[1].steps[1].missing[1].vendor, 10)
ns.Vendor.IsLimited = function(_, itemID) return itemID == 2996 end
check("a shop with limited stock is never named", Butler:Jobs()[1].steps[1].missing[1].vendor, nil)
ns.Vendor.IsLimited = nil
vendorPrices[2996] = nil
local send = jobs[1].steps[2]
check("then mails the leather over", send.kind, "mail")
check("to the alt, by full name", send.to, "Blackthornes Wither")
check("30 of it", send.items[1].count, 30)

local leather = jobs[2].steps[1]
check("the alt crafts leather", leather.name, "Medium Leather")
check("20 of it", leather.count, 20)
check("and has what it takes", leather.ready, true)
check("for Ana", leather.forNames[1], "Ana Blackthorne")
local back = jobs[2].steps[2]
check("then mails back what it made", back.kind, "mail")
check("to Ana", back.to, "Ana Blackthorne")
check("five owed", back.items[1].count, 5)

print("\nwhen the alt plays")
selfKey = WITHER
jobs = Butler:Jobs()
check("the alt comes first", jobs[1].name, "Blackthornes Wither")
check("its craft first", jobs[1].steps[1].kind, "craft")
check("Ana is next", jobs[2] and jobs[2].name, "Ana Blackthorne")
selfKey = ANA

print("\nmaterials on another character come first")
local DEE = "Player-5"
ns.db.characters[DEE] = { name = "Dee", surname = "Tanner", realm = "R", faction = "Alliance",
  inventory = { [2318] = 50 }, bank = { [2318] = 10 } }
held[WITHER][2318] = 0
jobs = Butler:Jobs()
local dee
for _, job in ipairs(jobs) do if job.name == "Dee Tanner" then dee = job end end
check("the character with the leather gets a job", dee ~= nil, true)
check("to mail it first", dee and dee.steps[1].kind, "mail")
check("to the crafter", dee and dee.steps[1].to, "Blackthornes Wither")
check("for a craft", dee and dee.steps[1].forCraft, true)
check("all 60 it has toward the 80", dee and dee.steps[1].items[1].count, 60)
local waiting = jobs[3] and jobs[3].name == "Blackthornes Wither" and jobs[3] or jobs[2]
check("the craft still waits", waiting.steps[1].ready, false)
check("and says who has it", waiting.steps[1].missing[1].from, "Dee Tanner")

print("\nan old record of the crafter counts as its own")
ns.db.characters[DEE] = nil
ns.db.characters["Blackthornes-R"] = { name = "Blackthornes", realm = "R", faction = "Alliance",
  inventory = { [2318] = 80 } }
jobs = Butler:Jobs()
check("no one else gets a job", #jobs, 2)
check("the craft is ready", jobs[2].steps[1].ready, true)
ns.db.characters["Blackthornes-R"] = nil
held[WITHER][2318] = 80

print("\nan old record of another character is that character")
local LEGACY = "Ana-R"
ns.db.characters[LEGACY] = { name = "Ana", realm = "R", faction = "Alliance" }
owed[LEGACY] = { [ANA] = { [2319] = 8 } }
queue[#queue + 1] = { recipeID = 12, quantity = 1, crafter = LEGACY }
selfKey = WITHER
jobs = Butler:Jobs()
local anas, selfMail = 0, false
for _, job in ipairs(jobs) do
  if job.name:find("^Ana") then anas = anas + 1 end
  for _, step in ipairs(job.steps) do
    if step.kind == "mail" and step.to == job.name then selfMail = true end
  end
end
check("one line for Ana, not two", anas, 1)
check("no step mails a character to itself", selfMail, false)
check("named in full", jobs[2] and jobs[2].name, "Ana Blackthorne")
selfKey = ANA
ns.db.characters[LEGACY] = nil
owed[LEGACY] = nil
queue[#queue] = nil

print("\nthe character playing holds the materials")
held[WITHER][2318] = 0
ns.Inventory = {
  GetBagCount = function(_, itemID) if itemID == 2318 then return 20 end return 0 end,
  GetBankCount = function(_, itemID) if itemID == 2318 then return 20 end return 0 end,
}
jobs = Butler:Jobs()
local mine = jobs[1]
check("its own line comes first", mine.name, "Ana Blackthorne")
local letter = mine.steps[1]
check("a mail for the craft first", letter.kind == "mail" and letter.forCraft, true)
check("to the crafter", letter.to, "Blackthornes Wither")
check("all 40, bags and bank", letter.items[1].count, 40)
check("20 to take from the bank first", letter.items[1].bank, 20)
local leatherMails = 0
for _, step in ipairs(mine.steps) do
  for _, item in ipairs(step.kind == "mail" and step.items or {}) do
    if item.itemID == 2318 then leatherMails = leatherMails + 1 end
  end
end
check("the leather is in one mail, not two", leatherMails, 1)
local crafter
for _, job in ipairs(jobs) do if job.name == "Blackthornes Wither" then crafter = job end end
check("the craft says who has it", crafter and crafter.steps[1].missing[1].from, "Ana Blackthorne")
ns.QueueMail.GetPlan = function() return {}, {} end
check("Take from bank brings out what the mail needs", Butler:FromBank()[2318], 20)
ns.QueueMail.GetPlan = nil
selfKey = WITHER
jobs = Butler:Jobs()
check("never the crafter's own bags when it plays", jobs[1].steps[1].missing[1].from, nil)
selfKey = ANA
ns.Inventory = nil
held[WITHER][2318] = 80

print("\nmail waiting comes first")
-- The alt's leather is in its mailbox, and Ana has gloves on their way.
local inMail = { [WITHER] = { [2318] = 50 } }
ns.Queue.InMailFor = function(_, key, itemID) return (inMail[key] or {})[itemID] or 0 end
ns.QueueMail.InFlightItems = function(_, key) if key == ANA then return { [7001] = 1 } end return {} end
jobs = Butler:Jobs()
local wither, ana
for _, job in ipairs(jobs) do
  if job.key == WITHER then wither = job end
  if job.key == ANA then ana = job end
end
local pickup = wither and wither.steps[1]
check("the alt's first step is its mailbox", pickup and pickup.kind, "pickup")
check("for the craft's leather", pickup and pickup.forCraft, true)
check("only what its bags and bank lack", pickup and pickup.items[1].count, 50)
check("then its craft", wither and wither.steps[2].kind, "craft")
local gloves = ana and ana.steps[1]
check("mail on its way is a pickup too", gloves and gloves.kind, "pickup")
check("not for a craft", gloves and gloves.forCraft, false)
check("the gloves", gloves and gloves.items[1].itemID, 7001)
inMail[WITHER][2318] = 0
ns.QueueMail.InFlightItems = nil
jobs = Butler:Jobs()
local none = true
for _, job in ipairs(jobs) do
  for _, step in ipairs(job.steps) do if step.kind == "pickup" then none = false end end
end
check("nothing waiting, no pickup", none, true)
ns.Queue.InMailFor = nil

print("\ncraft")
local started, shown = nil, 0
ns.Crafting = {
  isTradeSkillOpen = false,
  GetReadiness = function(_, id) if id == 11 then return true end return false, "on someone else" end,
  IsBusy = function() return false end,
  Start = function(_, id, count) started = { id, count } return true end,
}
ns.Queue.ShowQueue = function() shown = shown + 1 return true end
local ok, why = Butler:Craft(11)
check("closed profession opens the Queue tab", why, "opened")
check("and starts nothing", started, nil)
ns.Crafting.isTradeSkillOpen = true
ok, why = Butler:Craft(11)
check("open profession crafts", why, "crafting")
check("the queued amount", started and started[2], 1)
ok, why = Butler:Craft(10)
check("not this character's craft", ok, false)
check("says why", why, "it's no longer in your queue")

print("\nprofession for the Craft button")
ns.ProfessionOpener = {
  ProfessionFor = function(_, id) if id == 11 then return { name = "Tailoring", spell = "Tailoring", skillLineID = 197 } end end,
  WindowShowsRecipe = function(_, id) return id == 11 end,
}
local profession = Butler:Profession(11)
check("names the profession", profession and profession.name, "Tailoring")
check("and the spell that opens it", profession and profession.spell, "Tailoring")
check("open while the window shows it", profession and profession.open, true)
ns.Crafting.isTradeSkillOpen = false
profession = Butler:Profession(11)
check("closed window says so", profession and profession.open, false)
check("no window to open is nil", Butler:Profession(99), nil)
check("no recipe is nil", Butler:Profession(nil), nil)
ns.ProfessionOpener.ProfessionFor = function() error("boom") end
check("never raises", Butler:Profession(11), nil)
ns.ProfessionOpener = nil
ns.Crafting.isTradeSkillOpen = true

print("\nprofession cooldowns")
ns.Cooldowns = {
  ReadyList = function() return { { key = WITHER, group = "Mooncloth", name = "Mooncloth", recipeID = 18560 },
    { key = CY, group = "Transmute", name = "Transmute: Arcanite", recipeID = 17187 } } end,
  ReadyHere = function(_, recipeID) return recipeID == 12 end,
}
jobs = Butler:Jobs()
local alt
for _, job in ipairs(jobs) do if job.key == WITHER then alt = job end end
local cooldown = alt and alt.steps[#alt.steps]
check("a ready cooldown is the alt's step", cooldown and cooldown.kind, "cooldown")
check("named by its group", cooldown and cooldown.name, "Mooncloth")
check("with its recipe", cooldown and cooldown.recipeID, 18560)
local horde = false
for _, job in ipairs(jobs) do if job.key == CY then horde = true end end
check("never for a character this one can't mail", horde, false)
ns.Crafting.GetReadiness = function() return true end
started = nil
ok, why = Butler:Craft(12)
check("a ready cooldown crafts unqueued", why, "crafting")
check("one of it", started and started[2], 1)
ns.Crafting.isTradeSkillOpen = false
ok, why = Butler:Craft(12)
check("with the profession closed it says to open it", why, "open your profession first")
ns.Cooldowns = nil

print("\nslots freed")
local setting = true
ns.Crafting.FreesSpaceFirst = function() return setting end
ns.Crafting.SlotsFreed = function(_, entry) return entry.recipeID == 11 and 3 or 0 end
jobs = Butler:Jobs()
local function craftOf(job, recipeID)
  for _, step in ipairs(job.steps) do
    if step.kind == "craft" and step.recipeID == recipeID then return step end
  end
end
check("the character playing gets the slots", craftOf(jobs[1], 11).slots, 3)
check("another character's craft has none", craftOf(jobs[2], 10).slots, nil)
setting = false
jobs = Butler:Jobs()
check("none with the setting off", craftOf(jobs[1], 11).slots, nil)

ns.Crafting.GetReadiness = function() error("boom") end
check("never raises", (Butler:Craft(11)), false)
ns.Queue.GetAll = function() error("boom") end
check("Jobs gives nil on an error", Butler:Jobs(), nil)

print("")
if failures > 0 then
  error(string.format("%d Butler jobs check(s) failed", failures))
end
print("  all Butler jobs checks passed")
print("")
