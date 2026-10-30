-- Logic/FarmerGoals.lua outside WoW.
--
-- The Gather tab's "Set Goal" button hands a material to Blackthornes Farmer.
-- What must hold:
--   1. Without Farmer (or a Farmer too old to have goals) it is not offered,
--      and a click says so instead of throwing.
--   2. With Farmer, Farmer's own Goals:Set gets the item's plain name (no
--      colour codes, no link) and the amount the row needs.
--   3. Farmer's refusal is passed on in chat; a Farmer that throws does not
--      break Tradeskills.
--   4. Success prints, opens Farmer's Goals panel and plays a sound.

local printed = {}
local sounds = {}
PlaySound = function(kit) sounds[#sounds + 1] = kit end
SOUNDKIT = { IG_QUEST_LIST_COMPLETE = 878 }

local names = { [2770] = "Copper Ore" }
C_Item = { GetItemNameByID = function(id) return names[id] end }

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {} ns[name] = m return m end
ns.Print = function(text) printed[#printed + 1] = text end

local chunk = assert(loadfile(lfs_cwd .. "/Logic/FarmerGoals.lua"))
chunk("Blackthornes_TS", ns)

local FarmerGoals = ns.FarmerGoals
local failures = 0

local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(string.format("  FAIL  %-52s got %s, wanted %s",
      label, tostring(got), tostring(want)))
  else
    print(string.format("  ok    %-52s %s", label, tostring(got)))
  end
end

local function last() return printed[#printed] or "" end

print("\nwithout Farmer")
BlackthornesFarmer = nil
check("not offered", FarmerGoals:Available(), false)
check("a click does not throw", (FarmerGoals:SetGoal(2770, 40)), false)
check("and says why", last():find("not loaded", 1, true) ~= nil, true)

BlackthornesFarmer = { Goals = {} }
check("a Farmer with no goals is not offered", FarmerGoals:Available(), false)

print("\nwith Farmer")
local calls = {}
local shown = 0
local goals = {}
BlackthornesFarmer = {
  Goals = {
    Find = function(_, name) return goals[name] end,
    Set = function(_, name, amount)
      calls[#calls + 1] = { name = name, amount = amount }
      if amount < 1 then return nil, "the amount has to be 1 or more" end
      goals[name] = { item = name, target = amount, have = 6 }
      return goals[name]
    end,
  },
  GoalsUI = { Show = function() shown = shown + 1 end },
}
check("offered", FarmerGoals:Available(), true)

check("set", (FarmerGoals:SetGoal(2770, 40)), true)
check("Farmer got the plain name", calls[1].name, "Copper Ore")
check("and the amount needed", calls[1].amount, 40)
check("chat says set", last():find("Farmer goal set", 1, true) ~= nil, true)
check("chat says how many to go", last():find("You have 6, 34 to go", 1, true) ~= nil, true)
check("Goals panel opened", shown, 1)
check("sound played", sounds[#sounds], 878)

FarmerGoals:SetGoal(2770, 50)
check("second time says updated", last():find("Farmer goal updated", 1, true) ~= nil, true)

local before = #sounds
check("Farmer's refusal is a no", (FarmerGoals:SetGoal(2770, 0)), false)
check("and is passed on", last():find("amount has to be 1 or more", 1, true) ~= nil, true)
check("no sound for a refusal", #sounds, before)

check("an item the game has not named yet", (FarmerGoals:SetGoal(9999, 5)), false)
check("does not reach Farmer", #calls, 3)

print("\nset all goals at once")
names[2589] = "Linen Cloth"
names[2318] = "Light Leather"
calls, shown = {}, 0
before = #sounds
local count = FarmerGoals:SetGoals({
  { itemID = 2770, needed = 20 },
  { itemID = 2589, needed = 0 },     -- Farmer refuses this one
  { itemID = 2318, needed = 12 },
  { itemID = 9999, needed = 3 },     -- no name yet
})
check("two set", count, 2)
check("Farmer asked for the three it could name", #calls, 3)
check("in list order", calls[3].name, "Light Leather")
local all = table.concat(printed, "\n", #printed - 1)
check("summary names them", all:find("2 Farmer goals set:|r Copper Ore, Light Leather", 1, true) ~= nil, true)
check("and says what was not set, and why", all:find("Linen Cloth (the amount has to be 1 or more)", 1, true) ~= nil, true)
check("one sound for the lot", #sounds, before + 1)
check("Goals panel opened once", shown, 1)

before = #sounds
check("an empty list sets nothing", FarmerGoals:SetGoals({}), 0)
check("and says so", last():find("Nothing still needed", 1, true) ~= nil, true)
check("no sound for nothing", #sounds, before)

BlackthornesFarmer.Goals.Set = function() error("boom") end
check("a Farmer that throws is a no", (FarmerGoals:SetGoal(2770, 5)), false)
check("and a no for all", FarmerGoals:SetGoals({ { itemID = 2770, needed = 5 } }), 0)

BlackthornesFarmer = nil
check("set all without Farmer sets nothing", FarmerGoals:SetGoals({ { itemID = 2770, needed = 5 } }), 0)

print("\ngoals follow the queue")
-- A Farmer with real goals: Set keeps a target, Remove takes it off.
local goals = {}
local have = { ["Copper Ore"] = 6, ["Light Leather"] = 0, ["Linen Cloth"] = 0 }
BlackthornesFarmer = { Goals = {
  Find = function(_, name) return goals[name] end,
  Set = function(_, name, amount)
    if amount < 1 then return nil, "the amount has to be 1 or more" end
    if (have[name] or 0) >= amount then return nil, "you already have that many" end
    goals[name] = goals[name] or { item = name }
    goals[name].target, goals[name].have = amount, have[name] or 0
    return goals[name]
  end,
  Remove = function(_, name) local was = goals[name] goals[name] = nil return was ~= nil end,
}, GoalsUI = { Show = function() end } }

local settings = {}
ns.db = {}
ns.Config = {
  GetCharacterKey = function() return "me" end,
  Get = function(_, key) return settings[key] end,
}
local shopping = {}
ns.Queue = { GetShoppingList = function() return shopping end }
local waits = 0
C_Timer = { After = function(_, fn) waits = waits + 1 fn() end }

FarmerGoals:SetGoal(2770, 40)
FarmerGoals:SetGoal(2318, 12)
check("Set goal remembers the queue's goal", ns.db.farmerGoalsFromQueue.me[2770].target, 40)

-- The queue grows: more ore needed; the leather is no longer queued.
shopping = { { itemID = 2770, needed = 60 } }
FarmerGoals:QueueChanged()
check("waits for the burst to end", waits, 1)
check("the ore goal grows with the queue", goals["Copper Ore"].target, 60)
check("the leather goal goes", goals["Light Leather"], nil)
check("and is no longer followed", ns.db.farmerGoalsFromQueue.me[2318], nil)
check("chat says so in one line", last():find("now Copper Ore 60; no longer needed: Light Leather", 1, true) ~= nil, true)

-- The player changes the goal in Farmer: theirs now, never moved again.
goals["Copper Ore"].target = 80
shopping = { { itemID = 2770, needed = 20 } }
FarmerGoals:QueueChanged()
check("a goal the player changed is left alone", goals["Copper Ore"].target, 80)
check("and let go", ns.db.farmerGoalsFromQueue.me[2770], nil)

-- Already have what the queue needs now: the goal goes.
FarmerGoals:SetGoal(2770, 40)
shopping = { { itemID = 2770, needed = 5 } }
FarmerGoals:QueueChanged()
check("already holding enough takes the goal off", goals["Copper Ore"], nil)

-- Turned off: nothing moves.
FarmerGoals:SetGoal(2770, 40)
settings.farmerGoalsFollowQueue = false
shopping = {}
FarmerGoals:QueueChanged()
check("with following off, nothing moves", goals["Copper Ore"] and goals["Copper Ore"].target, 40)
settings.farmerGoalsFollowQueue = nil

-- A goal the player made in Farmer, not from the queue, is never touched.
goals["Linen Cloth"] = { item = "Linen Cloth", target = 30 }
FarmerGoals:QueueChanged()
check("Farmer's own goals are never touched", goals["Linen Cloth"].target, 30)

-- No followed goals: the queue changing does nothing at all.
ns.db.farmerGoalsFromQueue.me = {}
waits = 0
FarmerGoals:QueueChanged()
check("nothing followed, nothing worked out", waits, 0)

print("")
if failures > 0 then
  error(string.format("%d Farmer goal check(s) failed", failures))
end
print("  all Farmer goal checks passed")
print("")
