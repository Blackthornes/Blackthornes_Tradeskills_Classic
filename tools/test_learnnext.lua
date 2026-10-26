-- Logic/LearnNext.lua and Logic/Waypoints.lua outside WoW.
--
-- Learn next (the owner said build it, 2026-10-12). What must hold:
--   1. Forever's skills are laid over the book (Data/LearnSpots.lua): the
--      skill to learn, yellow and grey; Classic's is kept as classicSkill.
--      Forever's materials and item made replace Classic's where they differ.
--   2. The skill up colour of a recipe not learned comes from its yellow
--      and grey.
--   3. The list holds recipes the character playing has not learned that a
--      trainer or vendor teaches and that raise the skill now, orange first;
--      a few points out of reach come last, locked; grey, starter, known,
--      drop-only and far-off recipes are left out.
--   4. The trainer is on the player's side and teaches that far; the
--      nearest on the continent the character is on wins, else the zone
--      they are in, then a city of theirs. A vendor carries its
--      spot.
--   5. Show the way pins the game's map, or hands TomTom the place when it
--      is installed, and says where in chat; with neither it says why not.
--   6. Queue materials puts enough on the list to craft until yellow.

-- Tests share one Lua state: every global set here is put back at the end.
local GLOBALS = { "time", "GetTime", "UnitFactionGroup", "GetRealZoneText", "GetLocale",
  "C_Map", "UiMapPoint", "C_SuperTrack", "TomTom" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {} ns[name] = m return m end
local printed = {}
ns.Print = function(text) printed[#printed + 1] = text end
ns.Debug = function() end

local now = 1000000
time = function() return now end
GetTime = function() return now end
UnitFactionGroup = function() return "Alliance" end
local zoneHere = "Elwynn Forest"
GetRealZoneText = function() return zoneHere end
GetLocale = function() return "enUS" end

local settings = { auctionCut = 0.05, valueOwnedMaterials = true }
ns.Config = {
  Get = function(_, key) return settings[key] end,
  GetCharacterKey = function() return "me" end,
}
ns.Util = {
  FormatMoney = function(c) return tostring(c) .. "c" end,
  HasFunction = function() return false end,
  GetItemLabel = function(id) return id == 5000 and "Pattern: Belt" or ("item " .. id) end,
  Uncolored = function(text) return text end,
}

local LEATHER, THREAD = 2318, 2320
ns.RECIPE_BOOK = {
  PROFESSIONS = { [165] = "Leatherworking" },
  RECIPES = {
    [1] = { 165, 1, 101, 1, 1, { LEATHER, 1 }, "Starter Strap", s = 1 },
    [2] = { 165, 90, 102, 1, 1, { LEATHER, 4, THREAD, 1 }, "Trained Boots", t = 500 },
    [3] = { 165, 120, 103, 1, 1, { LEATHER, 2 }, "Vendor Belt" },
    [4] = { 165, 95, 104, 1, 1, { LEATHER, 1 }, "Known Gloves", t = 100 },
    [5] = { 165, 60, 105, 1, 1, { LEATHER, 1 }, "Grey Cap", t = 50 },
    [6] = { 165, 110, 106, 1, 1, { LEATHER, 1 }, "Soon Cloak", t = 900 },
    [7] = { 165, 100, 107, 1, 1, { LEATHER, 1 }, "Dropped Vest" },
    [8] = { 165, 150, 108, 1, 1, { LEATHER, 1 }, "Far Kilt", t = 2000 },
    [9] = { 165, 160, 109, 1, 1, { LEATHER, 1 }, "Expert Hood", t = 3000 },
  },
  ITEMS = {
    [5000] = { 3, 400, v = { "Hordey", "Orgrimmar", "H", "Alli", "Wetlands", "A" } },
    [5001] = { 7, 100, d = 40 },
  },
}

ns.LEARN_SPOTS = {
  -- Classic 120 moved down to 100 for the belt; the boots stay at 90.
  SKILLS = {
    [2] = { 90, 95, 125 },
    [3] = { 100, 110, 130 },
    [4] = { 95, 115, 135 },
    [5] = { 60, 80, 100 },
    [6] = { 110, 125, 145 },
    [8] = { 150, 170, 190 },
    [9] = { 95, 112, 140 },
  },
  TRAINERS = {
    [165] = {
      { "Apprentice Al", "Elwynn Forest", 10, 20, "A", 75 },
      { "Hordey Trainer", "Orgrimmar", 50, 50, "H", 300 },
      { "Journey Jo", "Stormwind City", 60, 70, "A", 150 },
      { "Journey Jen", "Elwynn Forest", 40, 45, "A", 150 },
      { "Gnome Gus", "Ironforge", 30, 30, "A", 150 },
      { "Expert Ed", "Ironforge", 35, 35, "A", 225 },
    },
  },
  MATERIALS = { [6] = { THREAD, 2 } },
  MADE = { [6] = 206 },
  VENDORS = { ["Alli|Wetlands"] = { 25, 25 }, ["Hordey|Orgrimmar"] = { 1, 1 } },
}

local prices = { [LEATHER] = 10, [THREAD] = 5 }
ns.Prices = { GetValue = function(_, id) return prices[id] end }
ns.Vendor = {
  GetUnitPrice = function() return nil end,
  IsLimited = function() return false end,
  GetTable = function() return {} end,
}
local bags = { [LEATHER] = 9, [THREAD] = 1 }
ns.Inventory = {
  GetBagCount = function(_, id) return bags[id] or 0 end,
  GetBankCount = function() return 0 end,
  GetCharacterBagCount = function(_, key, id) return key == "me" and bags[id] or 0 end,
}
ns.Recipes = {
  GetAny = function() return nil end,
  GetAll = function() return {} end,
  GetAccountWide = function() return { [4] = { outputItemID = 104, knownBy = { "me" } } } end,
  GetShortCharacterName = function(_, key) return key end,
}

ns.db = {}

assert(loadfile(lfs_cwd .. "/Logic/Cost.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/RecipeBook.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Waypoints.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/LearnNext.lua"))("Blackthornes_TS", ns)

-- LevelUp's order, without the rest of it.
local BAND = { optimal = 1, medium = 2, easy = 3, unknown = 4, trivial = 5 }
ns.LevelUp = {
  GetReturns = function() return nil end,
  Compare = function(a, b)
    if BAND[a.tier] ~= BAND[b.tier] then return BAND[a.tier] < BAND[b.tier] end
    return a.name < b.name
  end,
}

local LN, Book = ns.LearnNext, ns.RecipeBook
local failures = 0
local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(string.format("  FAIL  %-56s got %s, wanted %s", label, tostring(got), tostring(want)))
  else
    print(string.format("  ok    %-56s %s", label, tostring(got)))
  end
end

local function Names(rows)
  local names = {}
  for _, row in ipairs(rows) do names[#names + 1] = row.name end
  return table.concat(names, ", ")
end

local function Find(rows, name)
  for _, row in ipairs(rows) do if row.name == name then return row end end
end

print("\nForever's skills")
local belt = Book:Get(3)
check("the skill to learn is Forever's", belt.skill, 100)
check("Classic's is kept", belt.classicSkill, 120)
check("yellow", belt.yellow, 110)
check("grey", belt.grey, 130)
check("GetSkill answers Forever's", Book:GetSkill(3), 100)
local cloak = Book:Get(6)
check("Forever's materials replace Classic's", cloak.reagents[1].itemID, THREAD)
check("with Forever's count", cloak.reagents[1].quantity, 2)
check("only Forever's", #cloak.reagents, 1)
check("Forever's item made", cloak.outputItemID, 206)
check("a recipe Forever left alone keeps the book's", Book:Get(2).reagents[2].itemID, THREAD)
check("ClassicLine maps the modern line", Book.ClassicLine(2945), 165)

print("\nskill up colour")
check("below yellow is orange", LN.Tier(belt, 105), "optimal")
check("yellow to halfway is yellow", LN.Tier(belt, 115), "medium")
check("halfway to grey is green", LN.Tier(belt, 125), "easy")
check("grey", LN.Tier(belt, 130), "trivial")
check("unknown without yellow", LN.Tier({}, 100), "unknown")
do
  local book = ns.RECIPE_BOOK.RECIPES
  book[10] = { 165, 100, 110, 1, 1, { LEATHER, 1 }, "Unread Wrap", t = 100 }
  ns.RecipeBook.merged = nil
  local function Listed(skill)
    for _, row in ipairs(LN:GetRows({ skills = { [165] = skill } })) do
      if row.name == "Unread Wrap" then return true end
    end
    return false
  end
  check("no yellow known: listed near its skill", Listed(110), true)
  check("and not once far past it", Listed(180), false)
  book[10] = nil
  ns.RecipeBook.merged = nil
end

print("\nthe list at Leatherworking 100")
local rows = LN:GetRows({ skills = { [165] = 100 } })
check("what is listed, locked last", Names(rows),
  "Expert Hood, Vendor Belt, Trained Boots, Soon Cloak")
check("starter, known, grey, drop and far off left out", Find(rows, "Grey Cap") == nil
  and Find(rows, "Known Gloves") == nil and Find(rows, "Starter Strap") == nil
  and Find(rows, "Dropped Vest") == nil and Find(rows, "Far Kilt") == nil, true)
check("the cloak is locked", Find(rows, "Soon Cloak").locked, true)
check("needing 110", Find(rows, "Soon Cloak").needs, 110)
check("boots yellow", Find(rows, "Trained Boots").tier, "medium")
check("belt orange", Find(rows, "Vendor Belt").tier, "optimal")
check("the bags make one pair of boots", Find(rows, "Trained Boots").craftableNow, 1)
check("no profession, no list", #LN:GetRows({ skills = {} }), 0)
check("search", Names(LN:GetRows({ skills = { [165] = 100 }, search = "belt" })), "Vendor Belt")

print("\nwhere to learn")
local boots = Find(rows, "Trained Boots")
check("a trainer in the zone you are in", boots.place.name, "Journey Jen")
check("at the trainer's price", boots.price, 500)
check("never the apprentice for a 90 recipe", boots.place.name ~= "Apprentice Al", true)
zoneHere = "Duskwood"
check("else in a city of your side", LN:Place(Book:Get(2)).name, "Journey Jo")
local artisan = LN:Place({ trainerCost = 5000, skillLineID = 165, classicSkill = 240, skill = 240 })
check("past every trainer placed, an Artisan trainer with no spot",
  artisan and artisan.kind == "trainer" and artisan.name == "an Artisan trainer" and artisan.zone == nil, true)
check("a trainer's recipe the side's trainers teach is never that",
  LN:Place({ trainerCost = 5000, skillLineID = 165, classicSkill = 200, skill = 200 }).name, "Expert Ed")
zoneHere = "Wald von Elwynn"
GetLocale = function() return "deDE" end
C_Map = { GetBestMapForUnit = function() return 1429 end }
check("a Deutsch client in the zone you are in, by its map", LN:Place(Book:Get(2)).name, "Journey Jen")
GetLocale = function() return "enUS" end
C_Map = nil
zoneHere = "Elwynn Forest"
local hood = Find(rows, "Expert Hood")
check("an Expert's recipe goes to an Expert", hood and hood.place.name, "Expert Ed")
local vendor = Find(rows, "Vendor Belt").place
check("a vendor on your side", vendor.name, "Alli")
check("with its spot", ("%s %s,%s"):format(vendor.zone, vendor.x, vendor.y), "Wetlands 25,25")
check("and the pattern's price", vendor.price, 400)
check("trainer words", (LN.WhereText(boots.place)), "Trainer")
local kind, zone = LN.WhereText(vendor)
check("vendor words and zone", kind .. " " .. zone, "Vendor Wetlands")

print("\nshow the way")
local pinned, tracked
C_Map = {
  SetUserWaypoint = function(point) pinned = point end,
  GetBestMapForUnit = function() return 1429 end,
  GetMapInfo = function(id)
    if id == 1429 then return { name = "Elwynn Forest", parentMapID = 13 } end
    if id == 13 then return { name = "Eastern Kingdoms", parentMapID = 0 } end
  end,
  GetMapChildrenInfo = function() return { { name = "Wetlands", mapID = 1437 }, { name = "Elwynn Forest", mapID = 1429 } } end,
}
UiMapPoint = { CreateFromCoordinates = function(map, x, y) return { map = map, x = x, y = y } end }
C_SuperTrack = { SetSuperTrackedUserWaypoint = function(on) tracked = on end }
check("pinned", LN:ShowTheWay(Find(rows, "Vendor Belt")), true)
check("on the zone's map", pinned and pinned.map, 1437)
check("at the spot", pinned and pinned.x, 0.25)
check("the game's arrow follows it", tracked, true)
check("chat says where", printed[#printed], "Pinned Alli (Pattern: Belt) on your map, Wetlands 25, 25.")

local added
TomTom = {
  AddWaypoint = function(_, map, x, y, opts) added = { map = map, x = x, title = opts.title } return "uid" end,
  RemoveWaypoint = function() end,
}
pinned = nil
check("TomTom takes it when installed", LN:ShowTheWay(boots), true)
check("TomTom's map", added and added.map, 1429)
check("TomTom's x", added and added.x, 0.4)
check("its title", added and added.title, "Journey Jen (Trained Boots)")
check("no game pin then", pinned, nil)
TomTom = nil

-- "Guide Me:" is on until the player unticks it (Logic/Travel.lua).
if ns.Travel and ns.Travel.IsOn then
    local kept = ns.db.arrowRoute
    ns.db.arrowRoute = nil
    check("Guide Me is on when never set", ns.Travel.IsOn(), true)
    ns.db.arrowRoute = false
    check("and off once unticked", ns.Travel.IsOn(), false)
    ns.db.arrowRoute = kept
end

-- Far away with "Guide Me:" ticked (Logic/Travel.lua): the steps in chat
-- and the pin on the first stop.
local asked
ns.Travel = {
  IsOn = function() return true end,
  Guide = function(_, target)
    asked = target
    return { lines = { "1. Fly to Menethil Harbor", "2. Walk to Wetlands" },
      point = { map = 1429, x = 0.5, y = 0.45, name = "Fly to Menethil Harbor" } }
  end,
}
pinned = nil
local before = #printed
check("guided: pinned", LN:ShowTheWay(Find(rows, "Vendor Belt")), true)
check("the place asked for", asked and asked.zone .. " " .. asked.mx, "Wetlands 0.25")
check("the pin is on the first stop", pinned and pinned.map .. " " .. pinned.y, "1429 0.45")
check("chat says the way", printed[before + 1], "The way to Alli (Pattern: Belt), with a pin on the first stop:")
ns.Travel.IsOn = function() return false end
pinned = nil
LN:ShowTheWay(Find(rows, "Vendor Belt"))
check("off: the place itself", pinned and pinned.map, 1437)
ns.Travel = nil

print("\nthe arrow")
-- Logic/WayArrow.lua, the same dial as the other addons': Show the way aims
-- it, with no map pin behind it.
ns.charDb = {}
assert(loadfile(lfs_cwd .. "/Logic/WayArrow.lua"))("Blackthornes_TS", ns)
pinned = nil
check("Show the way aims the arrow", LN:ShowTheWay(Find(rows, "Vendor Belt")), true)
local aimedAt = ns.charDb.wayArrowPlace
check("on the zone's map", aimedAt and aimedAt.map, 1437)
check("at the spot", aimedAt and aimedAt.x, 0.25)
check("named for who and what", aimedAt and aimedAt.name, "Alli (Pattern: Belt)")
check("no map pin behind it", pinned, nil)
check("chat says so", printed[#printed], "The arrow shows the way to Alli (Pattern: Belt).")
ns.WayArrow:Clear()
check("its close puts it away", ns.charDb.wayArrowPlace, nil)
-- A zone the map can't be found for: the pin as before.
local findMap = ns.Waypoints.MapFor
ns.Waypoints.MapFor = function() return nil end
check("no map: the arrow can't take it", ns.WayArrow:AimAt({ zone = "Nowhere", x = 10, y = 10 }, "x"), false)
ns.Waypoints.MapFor = findMap
ns.WayArrow, ns.charDb = nil, nil

-- UI/WayArrow.lua draws the arrow smaller, and a spot saved before keeps
-- its place: it is kept in UIParent's units and turned back on placing.
do
    local f = io.open(lfs_cwd .. "/UI/WayArrow.lua", "r")
    local text = f and f:read("*a") or ""
    if f then f:close() end
    local usual = tonumber(text:match("ArrowUI%.USUAL = (%d+)"))
    check("the arrow is drawn smaller", usual ~= nil and usual < 100, true)
    check("its size is set on the frame", text:find("pcall(frame.SetScale, frame, ArrowUI.Scale())", 1, true) ~= nil, true)
    check("a saved spot is turned back into the arrow's units",
        text:find("ns.db.wayArrowX / scale, ns.db.wayArrowY / scale", 1, true) ~= nil, true)
    check("and saved in UIParent's units",
        text:find("ns.db.wayArrowX, ns.db.wayArrowY = x * scale, y * scale", 1, true) ~= nil, true)
end

print("\nwhere the game saw the vendor")
-- Logic/VendorPins.lua knows where a vendor stood when its window was
-- opened; that wins over Classic's spot (the owner, 2026-10-22).
ns.VendorPins = { SeenAt = function(_, name, zone)
  if name == "Alli" and zone == "Wetlands" then return { mapID = 1437, x = 61.5, y = 30.2 } end
end }
local moved = Find(LN:GetRows({ skills = { [165] = 100 } }), "Vendor Belt").place
check("the spot the game saw", moved and ("%s,%s"):format(moved.x, moved.y), "61.5,30.2")
check("on the map it was seen on", moved and moved.mapID, 1437)
pinned = nil
check("Show the way pins it", LN:ShowTheWayFor(3), true)
check("there", pinned and pinned.x, 0.615)
ns.VendorPins = { SeenAt = function(_, name, _, kind)
  if kind == "trainer" and name == "Journey Jen" then return { mapID = 1429, x = 11, y = 22 } end
end }
local trainerSeen = LN:Place(Book:Get(2))
check("a trainer where the game saw it", trainerSeen and ("%s %s,%s"):format(trainerSeen.name, trainerSeen.x, trainerSeen.y),
  "Journey Jen 11,22")
ns.VendorPins = { SeenAt = function() error("broken") end }
check("a broken lookup keeps Classic's spot", LN:WhereFor(3).x, 25)
ns.VendorPins = nil

print("\nwhere for Equipment, by recipe ID")
local where = LN:WhereFor(3)
check("a vendor's place", where and where.kind .. " " .. where.name, "vendor Alli")
check("with its zone and spot", where and ("%s %s,%s"):format(where.zone, where.x, where.y), "Wetlands 25,25")
check("a fresh table each time", LN:WhereFor(3) ~= where, true)
check("nothing teaches a starter recipe", LN:WhereFor(1), nil)
check("an unknown recipe has no place", LN:WhereFor(99999), nil)
pinned = nil
check("Show the way by recipe ID", LN:ShowTheWayFor(3), true)
check("pins the same spot", pinned and pinned.map, 1437)
check("an unknown recipe pins nothing", LN:ShowTheWayFor(99999), false)

C_Map, UiMapPoint = nil, nil
check("no pin on a client without one", LN:ShowTheWay(boots), false)
check("and says why", printed[#printed],
  "Can't pin Journey Jen (Trained Boots): this client cannot put a pin on the map. They are in Elwynn Forest.")
check("probe line", ns.Waypoints:ProbeText():find("map pin NO", 1, true) ~= nil, true)

print("\nqueue materials")
local buys = {}
ns.Queue = { EnsureBuy = function(_, itemID, count, forItem, forRecipe)
  buys[itemID] = { count, forItem, forRecipe } return true end }
check("one material", LN:QueueMaterials(Find(rows, "Vendor Belt")), 1)
check("enough until yellow", buys[LEATHER] and buys[LEATHER][1], 20)
check("tied to the recipe, not the belt", buys[LEATHER] and buys[LEATHER][2], nil)
check("the recipe it is for", buys[LEATHER] and buys[LEATHER][3] and buys[LEATHER][3].name, "Vendor Belt")
buys = {}
LN:QueueMaterials(boots)
check("one craft once already yellow", buys[LEATHER] and buys[LEATHER][1], 4)

print("\nwhat Butler's gold goals read")
ns.SkillUp = { ReadSkillLevels = function() return { [2945] = 100, [165] = 100 } end }
ns.db.characters = { me = { recipesCachedAt = 5 } }
assert(loadfile(lfs_cwd .. "/Logic/Butler.lua"))("Blackthornes_TS", ns)
local cost = ns.Butler:LearnCost()
local lw = cost and cost[165]
check("by Classic skill line", lw ~= nil, true)
check("trainer recipes the skill reaches, not learned, not grey", lw and lw.count, 2)
check("what they cost", lw and lw.cost, 3500)
check("the skill", lw and lw.skill, 100)
check("each recipe named", lw and lw.recipes and #lw.recipes, 2)
check("with its ID and price", lw and lw.recipes and lw.recipes[1].recipeID ~= nil
  and lw.recipes[1].cost > 0, true)
check("cheapest first", lw and lw.recipes and lw.recipes[1].cost <= lw.recipes[2].cost, true)
ns.Recipes.GetAccountWide = function() return {} end
Book.known = nil
ns.db.characters.me.recipesCachedAt = 6
local unread = ns.Butler:LearnCost()
check("a profession never read is left out", unread and unread[165], nil)
ns.SkillUp = nil
check("never raises", ns.Butler:LearnCost() ~= false, true)

print("\nthe nearest trainer on your continent")
-- A pretend world: each zone's map sits on a continent at an offset, a
-- point 0 to 1 on it is that offset plus 1000 yards a whole map.
local CONTINENT = { [1429] = 0, [1453] = 0, [1426] = 0, [1455] = 0, [1413] = 1 }
local OFFSET = {
  [1429] = { 0, 0 },        -- Elwynn Forest
  [1453] = { 0, 300 },      -- Stormwind City
  [1426] = { 3000, 0 },     -- Dun Morogh
  [1455] = { 3200, 0 },     -- Ironforge
  [1413] = { 0, 0 },        -- The Barrens
}
local standing
local savedArrow, savedPins = ns.WayArrow, ns.VendorPins
ns.WayArrow = {
  Here = function() return standing end,
  WorldPos = function(mapID, x, y)
    local at = OFFSET[mapID]
    if not at then return nil end
    return CONTINENT[mapID], at[1] + x * 1000, at[2] + y * 1000
  end,
}
local function StandIn(mapID, x, y)
  now = now + 10
  if not mapID then standing = nil return end
  local continent, north, west = ns.WayArrow.WorldPos(mapID, x, y)
  standing = { map = mapID, x = x, y = y, continent = continent, north = north, west = west }
end

zoneHere = "Dun Morogh"
StandIn(1426, 0.3, 0.3)
local near = LN:TrainerFor(165, 150)
check("next to Ironforge: its trainer", near and near.zone, "Ironforge")
check("the closer of the two there", near and near.name, "Gnome Gus")

zoneHere = "Elwynn Forest"
StandIn(1429, 0.4, 0.4)
near = LN:TrainerFor(165, 150)
check("in Elwynn: the one there", near and near.name, "Journey Jen")
near = LN:TrainerFor(165, 225)
check("only one teaches that far: it, however far", near and near.name, "Expert Ed")

StandIn(1413, 0.5, 0.5)
zoneHere = "The Barrens"
near = LN:TrainerFor(165, 150)
check("none on this continent: a city of your side", near and near.zone, "Stormwind City")

StandIn(nil)
zoneHere = "Elwynn Forest"
near = LN:TrainerFor(165, 150)
check("where you stand unknown: the zone you're in", near and near.name, "Journey Jen")

-- Where the game saw the trainer stand counts, not Classic's spot.
ns.VendorPins = {
  SeenAt = function(_, name)
    if name == "Gnome Gus" then return { mapID = 1429, x = 50, y = 50 } end
  end,
}
StandIn(1429, 0.5, 0.5)
near = LN:TrainerFor(165, 150)
check("a spot the game saw wins", near and near.name, "Gnome Gus")
check("and carries its map", near and near.mapID, 1429)
check("and its spot", near and near.x, 50)
ns.WayArrow, ns.VendorPins = savedArrow, savedPins

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print("")
if failures > 0 then error(string.format("%d learn next check(s) failed", failures)) end
print("  all learn next checks passed")
print("")
