-- Blackthornes Tradeskills -- Logic/LearnNext.lua
-- Learn next (the owner said build it, 2026-10-12): the recipes the
-- character playing has not learned that would raise their skill now, with
-- where to learn each, so the Level Up tab keeps going past what they know.
--
-- Only recipes a trainer or a vendor teaches: a drop or a quest cannot be
-- shown the way to. The skill each needs and when it turns yellow and grey
-- are Forever's (Data/LearnSpots.lua, laid over the book in
-- Logic/RecipeBook.lua); a recipe still a few points out of reach is listed
-- after the rest, "At 120". The trainer or vendor picked is on the player's
-- side, the nearest on the continent they are on, else in the zone they
-- are in when one is, else in a city of theirs.
-- A trainer or vendor stands where the game saw it, when its window has
-- been opened or the shipped Forever spots have it (VendorPins:SeenAt),
-- else at Classic's spot.
-- Show the way aims the arrow at them (Logic/WayArrow.lua), or, where the
-- arrow can't find the map, puts the game's own map pin on them, or
-- TomTom's arrow when TomTom is installed (Logic/Waypoints.lua).

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local LearnNext = ns.NewModule("LearnNext")

-- How many points out of reach a recipe is still listed, greyed.
LearnNext.REACH = 15

-- How far past a recipe's skill one with no yellow and grey known stops
-- being listed.
LearnNext.UNKNOWN_GREY = 75

-- A city of each side, where a trainer is likeliest to be found by a player
-- who is out in a zone that has none.
local CITIES = {
    A = { ["Stormwind City"] = true, ["Ironforge"] = true, ["Darnassus"] = true },
    H = { ["Orgrimmar"] = true, ["Thunder Bluff"] = true, ["Undercity"] = true },
}

local function Spots()
    return ns.LEARN_SPOTS or {}
end

local function Plain(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(function(...)
        local v = fn(...)
        if type(v) == "string" and v ~= "" then return v .. "" end
    end, ...)
    return ok and value or nil
end

local function Side()
    local faction = Plain(rawget(_G, "UnitFactionGroup"), "player")
    if faction == "Alliance" then return "A" end
    if faction == "Horde" then return "H" end
    return nil
end

local function OnSide(fac, side)
    return not side or not fac or fac == "" or fac:find(side, 1, true) ~= nil
end

--- The zone the character is in, in the data's English name where the
--- client names it so, else as the client names it.
local function HereZone()
    local name = Plain(rawget(_G, "GetRealZoneText")) or Plain(rawget(_G, "GetZoneText"))
    -- A client in another language names the zone in its own words ("Wald
    -- von Elwynn"); the map the character is on says which of the data's
    -- English zones that is.
    local Waypoints = ns.Waypoints
    if Waypoints and Waypoints.English and not Waypoints.English() and Waypoints.ZONE_MAPS then
        local map = rawget(_G, "C_Map")
        local ok, mapID = pcall(function()
            local id = map and map.GetBestMapForUnit and map.GetBestMapForUnit("player")
            if type(id) == "number" then return id + 0 end
        end)
        if ok and mapID then
            for zone, id in pairs(Waypoints.ZONE_MAPS) do
                if id == mapID then return zone end
            end
        end
    end
    return name
end

-- How long where the character stands is kept, so a list of many rows reads
-- it once.
LearnNext.HERE_KEEP = 2

local hereAt, hereKept

--- Where the character stands in the world: { continent, north, west }, or
--- nil when the client won't say (inside a dungeon, or no map).
local function HereInWorld()
    local now = type(_G.GetTime) == "function" and tonumber(_G.GetTime()) or 0
    if hereAt and now - hereAt < LearnNext.HERE_KEEP then return hereKept or nil end
    hereAt, hereKept = now, false
    local arrow = ns.WayArrow
    if arrow and arrow.Here then
        local ok, here = pcall(arrow.Here, arrow)
        if ok and type(here) == "table" and here.continent and here.north and here.west then
            hereKept = here
        end
    end
    return hereKept or nil
end

local worldOf = {}

--- Where a place stands in the world: continent, north, west, or nil. Its
--- own map where the game saw it, else its zone's map. Kept once read, since
--- a place never moves.
local function PlaceInWorld(place)
    if not (place and place.x and place.y) then return nil end
    local mapID = place.mapID
    if not mapID then
        local maps = ns.Waypoints and ns.Waypoints.ZONE_MAPS
        mapID = maps and place.zone and maps[place.zone]
    end
    local arrow = ns.WayArrow
    if not (mapID and arrow and arrow.WorldPos) then return nil end
    local key = mapID .. "|" .. place.x .. "|" .. place.y
    local kept = worldOf[key]
    if kept == nil then
        local ok, continent, north, west = pcall(arrow.WorldPos, mapID, place.x / 100, place.y / 100)
        kept = ok and continent and north and west and { continent, north, west } or false
        worldOf[key] = kept
    end
    if not kept then return nil end
    return kept[1], kept[2], kept[3]
end

--- The place nearest the character on the continent they are on, or nil
--- when none can be measured there.
local function Closest(places)
    local here = HereInWorld()
    if not here then return nil end
    local best, bestDistance
    for _, place in ipairs(places) do
        local continent, north, west = PlaceInWorld(place)
        if continent == here.continent then
            local dn, dw = north - here.north, west - here.west
            local distance = dn * dn + dw * dw
            if not bestDistance or distance < bestDistance then
                best, bestDistance = place, distance
            end
        end
    end
    return best
end

--- The best of a list of places { zone, ... }: the nearest on the continent
--- the character is on, else the one in the zone they are in, then one of
--- their side's cities, then the first.
local function Nearest(places, side)
    local closest = Closest(places)
    if closest then return closest end
    local here = HereZone()
    local cities = side and CITIES[side] or {}
    local city
    for _, place in ipairs(places) do
        if here and place.zone == here then return place end
        if not city and cities[place.zone] then city = place end
    end
    return city or places[1]
end

--- Where the game saw a vendor or trainer stand (Logic/VendorPins.lua), or nil.
local function SeenAt(name, zone, kind)
    local pins = ns.VendorPins
    if not (pins and pins.SeenAt) then return nil end
    local ok, seen = pcall(pins.SeenAt, pins, name, zone, kind)
    return ok and type(seen) == "table" and seen or nil
end

--- Where a recipe is learned: the trainer or vendor to go to.
--
-- @return { kind = "trainer" | "vendor", name, zone, x, y, price, itemID,
--   mapID (only where the game saw a vendor stand) } or nil when neither teaches it on the player's side
function LearnNext:Place(record)
    if not record then return nil end
    local side = Side()
    local spots = Spots()

    local trainers, sideTop = {}, nil
    if record.trainerCost then
        local line = ns.RecipeBook.ClassicLine and ns.RecipeBook.ClassicLine(record.skillLineID)
            or record.skillLineID
        local needs = record.classicSkill or record.skill or 0
        for _, row in ipairs((spots.TRAINERS or {})[line] or {}) do
            if OnSide(row[5], side) then sideTop = math.max(sideTop or 0, row[6] or 0) end
            if OnSide(row[5], side) and (row[6] or 0) >= needs then
                local seen = SeenAt(row[1], row[2], "trainer")
                trainers[#trainers + 1] = {
                    kind = "trainer", name = row[1], zone = row[2],
                    x = seen and seen.x or row[3], y = seen and seen.y or row[4],
                    mapID = seen and seen.mapID, price = record.trainerCost,
                }
            end
        end
    end

    local vendors = {}
    for _, itemID in ipairs(record.recipeItems or {}) do
        local book = ns.RECIPE_BOOK and ns.RECIPE_BOOK.ITEMS and ns.RECIPE_BOOK.ITEMS[itemID]
        local list = book and book.v
        for i = 1, list and #list - 2 or 0, 3 do
            if OnSide(list[i + 2], side) then
                -- Where the game saw the vendor stand wins over Classic's
                -- spot: Forever moved some.
                local seen = SeenAt(list[i], list[i + 1])
                local where = seen and { seen.x, seen.y }
                    or (spots.VENDORS or {})[list[i] .. "|" .. (list[i + 1] or "")]
                vendors[#vendors + 1] = {
                    kind = "vendor", name = list[i], zone = list[i + 1] ~= "" and list[i + 1] or nil,
                    x = where and where[1], y = where and where[2], mapID = seen and seen.mapID,
                    price = book[2], itemID = itemID,
                }
            end
        end
    end

    -- A trainer first: it is how most recipes are learned, and the cheaper.
    local place = Nearest(trainers, side) or Nearest(vendors, side)
    if place then return place end

    -- A trainer teaches it (it has a trainer's price) but none the data
    -- places teaches that high: Classic's Artisan trainers stand in places
    -- the data has no spot for. Still listed, with no spot to pin, rather
    -- than left out of the list.
    if record.trainerCost and sideTop and (record.classicSkill or record.skill or 0) > sideTop then
        return { kind = "trainer", name = L["an Artisan trainer"], price = record.trainerCost }
    end
    return nil
end

--- The nearest trainer of the player's side for a profession who teaches
--- up to a skill, for Road to 300's trainer steps (2026-10-20).
-- @param line   the Classic skill line
-- @param needs  the skill they must teach to
-- @return { kind = "trainer", name, zone, x, y } or nil
function LearnNext:TrainerFor(line, needs)
    local side = Side()
    local trainers = {}
    for _, row in ipairs((Spots().TRAINERS or {})[line] or {}) do
        if OnSide(row[5], side) and (row[6] or 0) >= (needs or 0) then
            -- Where the game saw the trainer stand wins over Classic's spot.
            local seen = SeenAt(row[1], row[2], "trainer")
            trainers[#trainers + 1] = {
                kind = "trainer", name = row[1], zone = row[2],
                x = seen and seen.x or row[3], y = seen and seen.y or row[4],
                mapID = seen and seen.mapID,
            }
        end
    end
    return Nearest(trainers, side)
end

--- The skill up colour an unlearned recipe gives at a skill, from Forever's
--- yellow and grey; "unknown" when they are not known.
function LearnNext.Tier(record, skill)
    local yellow, grey = record.yellow, record.grey
    if not (yellow and grey and skill) then return "unknown" end
    if skill >= grey then return "trivial" end
    if skill < yellow then return "optimal" end
    if skill < math.floor((yellow + grey) / 2) then return "medium" end
    return "easy"
end

--- How many the bags make, by the recipe's materials.
local function Makes(record)
    local reagents = record.reagents
    if not reagents or #reagents == 0 then return 0 end
    local me = ns.Config and ns.Config:GetCharacterKey()
    local possible = math.huge
    for _, reagent in ipairs(reagents) do
        local ok, have = pcall(ns.Inventory.GetCharacterBagCount, ns.Inventory, me, reagent.itemID)
        local can = math.floor(((ok and tonumber(have)) or 0) / math.max(1, reagent.quantity or 1))
        if can < possible then possible = can end
        if possible == 0 then break end
    end
    return possible == math.huge and 0 or possible
end

--- One row, in the Level Up list's shape, plus where to learn it.
function LearnNext:BuildRow(record, skill)
    local place = self:Place(record)
    if not place then return nil end

    local value = ns.RecipeBook:Value(record) or {}
    local tier = LearnNext.Tier(record, skill)
    local needs = record.skill or 0

    return {
        recipeID = record.recipeID,
        record = record,
        name = record.name or L.Format("recipe %s", record.recipeID),
        outputItemID = record.outputItemID,
        skillLineID = record.skillLineID,
        tier = tier,
        cost = value.cost,
        costDetail = value.costDetail,
        returns = value.returns,
        back = value.back,
        backWay = value.backWay,
        realCost = value.cost and value.back and (value.cost - value.back) or nil,
        craftableNow = Makes(record),
        learnNext = true,
        locked = needs > skill,
        needs = needs,
        place = place,
        price = place.price,
        skill = skill,
    }
end

--- The recipes to learn next, cheapest way up first, those still out of
--- reach last.
--
-- @param opts.skills  { [Classic skill line] = the character's skill }
-- @param opts.search  part of a name, any case
-- @return rows (BuildRow's)
function LearnNext:GetRows(opts)
    opts = opts or {}
    local skills = opts.skills or {}
    if not next(skills) or not ns.RecipeBook then return {} end
    local needle = opts.search and opts.search ~= "" and opts.search:lower() or nil
    local classic = ns.RecipeBook.ClassicLine or function(id) return id end

    local open, locked = {}, {}
    for _, record in pairs((ns.RecipeBook:GetAll())) do
        local skill = skills[classic(record.skillLineID)]
        local needs = record.skill
        if skill and needs and not record.starter
            and (record.trainerCost or record.recipeItems)
            and needs <= skill + LearnNext.REACH
            and (not needle or (record.name or ""):lower():find(needle, 1, true))
            and not ns.RecipeBook:KnowsIt(record) then
            local tier = LearnNext.Tier(record, math.max(skill, needs))
            -- With no yellow and grey known, a recipe this far below the
            -- skill is grey all the same: Classic's go grey within this.
            if tier == "unknown" and skill >= needs + LearnNext.UNKNOWN_GREY then tier = "trivial" end
            if tier ~= "trivial" then
                local row = self:BuildRow(record, skill)
                if row then
                    if row.locked then locked[#locked + 1] = row else open[#open + 1] = row end
                end
            end
        end
    end

    local compare = ns.LevelUp and ns.LevelUp.Compare
    if compare then table.sort(open, compare) end
    table.sort(locked, function(a, b)
        if a.needs ~= b.needs then return a.needs < b.needs end
        if compare then return compare(a, b) end
        return a.name < b.name
    end)
    for _, row in ipairs(locked) do open[#open + 1] = row end
    return open
end

--- The words for where: "Trainer" or "Vendor", and the zone beside a vendor.
function LearnNext.WhereText(place)
    if not place then return "", nil end
    if place.kind == "trainer" then return L["Trainer"], nil end
    return L["Vendor"], place.zone
end

--- What to pin the map for: the recipe item's name or the recipe's.
local function WhatFor(row)
    local item = row.place and row.place.itemID
    local name = item and ns.Util and ns.Util.GetItemLabel and ns.Util.GetItemLabel(item)
    if name and ns.Util.Uncolored then name = ns.Util.Uncolored(name) end
    -- "item 1234" (in the client's language) is GetItemLabel's stand-in
    -- while the item has not loaded: the recipe's own name says more.
    if type(name) == "string" and name ~= "" and name ~= L.Format("item %d", item) then return name end
    return row.name
end

local WHY = {
    nospot = L["no exact spot is known for them"],
    noclient = L["this client cannot put a pin on the map"],
    nomap = L["the map for that zone could not be found"],
}

--- The way there to a trainer or vendor far away, by Logic/Travel.lua (the
--- same file in every Blackthornes addon): its steps and the first stop to
--- pin, or nil when it is near, "Guide Me:" is off or no way is known.
function LearnNext.Guide(place, who)
    local Travel = ns.Travel
    if not (Travel and Travel.IsOn and Travel.IsOn() and place.zone and place.x and place.y) then return nil end
    local mapID = ns.Waypoints and ns.Waypoints:MapFor(place.zone)
    local target = { name = who, zone = place.zone, map = mapID,
        mx = mapID and place.x / 100 or nil, my = mapID and place.y / 100 or nil,
        coords = { place.x, place.y } }
    local ok, guide = pcall(Travel.Guide, Travel, target)
    if not ok or type(guide) ~= "table" or type(guide.point) ~= "table" or #guide.lines == 0 then return nil end
    return guide
end

--- Show the way: the arrow on the trainer or vendor, else the map pin (or
--- TomTom's arrow), and a line in chat that says where.
-- @return true when a pin or waypoint was set
function LearnNext:ShowTheWay(row)
    local place = row and row.place
    if not place then return false end
    local what = WhatFor(row)
    local who = place.name or L["them"]

    local ok, why
    local Waypoints = ns.Waypoints
    -- Our own marker always goes on the map (the game's pin often won't).
    local marked = Waypoints and Waypoints:Mark(place, who) or false

    -- The arrow (Logic/WayArrow.lua), the same as the other addons': it
    -- leads the way step by step with "Guide Me:" ticked, and hands off to
    -- TomTom's arrow when "Use TomTom:" is.
    local arrow = ns.WayArrow
    if arrow and arrow.AimAt then
        local aimed, took = pcall(arrow.AimAt, arrow, place, ("%s (%s)"):format(who, what))
        if aimed and took then
            ns.Print(L.Format("The arrow shows the way to %s (%s).", who, what))
            return true
        end
    end

    -- In another zone or across the sea, with "Guide Me:" ticked: the steps
    -- in chat, and the pin on the first stop (Logic/Travel.lua).
    local guide = LearnNext.Guide(place, who)
    if guide then
        local stop = { mapID = guide.point.map, x = guide.point.x * 100, y = guide.point.y * 100 }
        if Waypoints and Waypoints:HasTomTom() then
            ok = Waypoints:TomTom(stop, guide.point.name)
        end
        if not ok and Waypoints then ok = Waypoints:Pin(stop) end
        if ok then
            ns.Print(L.Format("The way to %s (%s), with a pin on the first stop:", who, what))
            local say = ns.PrintRaw or ns.Print
            for _, line in ipairs(guide.lines) do say("  " .. line) end
            return true
        end
    end

    if Waypoints and Waypoints:HasTomTom() then
        ok, why = Waypoints:TomTom(place, ("%s (%s)"):format(who, what))
    end
    local pinned
    if not ok and Waypoints then
        ok, why = Waypoints:Pin(place)
        pinned = ok
    end
    -- With the game's pin on, the marker goes when the pin does.
    if pinned and marked then Waypoints:Mark(place, who, true) end
    if not ok and marked then ok = true end

    if ok then
        ns.Print(L.Format("Pinned %s (%s) on your map, %s %s, %s.", who, what,
            place.zone, place.x, place.y))
    elseif place.zone then
        ns.Print(L.Format("Can't pin %s (%s): %s. They are in %s.", who, what,
            WHY[why] or L["no exact spot is known for them"], place.zone))
    else
        ns.Print(L.Format("Can't pin %s (%s): %s.", who, what,
            WHY[why] or L["no exact spot is known for them"]))
    end
    return ok == true
end

--- Where a recipe is learned, by its ID (a recipe's ID is its spell ID),
--- for Equipment's Enchants view. A fresh table, or nil when no trainer or
--- vendor of the player's side teaches it.
-- @return { kind ("trainer" or "vendor"), name, zone, x, y, price }
function LearnNext:WhereFor(recipeID)
    local book = ns.RecipeBook
    if not (book and book.Get) then return nil end
    local ok, record = pcall(book.Get, book, tonumber(recipeID))
    if not ok or type(record) ~= "table" then return nil end
    local placed, place = pcall(self.Place, self, record)
    if not placed or not place then return nil end
    return {
        kind = place.kind, name = place.name, zone = place.zone,
        x = place.x, y = place.y, price = place.price, mapID = place.mapID,
    }
end

--- Show the way to where a recipe is learned, by its ID: the same pin and
--- chat line as the Level Up tab's button.
-- @return true when a pin or waypoint was set
function LearnNext:ShowTheWayFor(recipeID)
    local book = ns.RecipeBook
    if not (book and book.Get) then return false end
    local ok, record = pcall(book.Get, book, tonumber(recipeID))
    if not ok or type(record) ~= "table" then return false end
    local place = self:Place(record)
    if not place then return false end
    return self:ShowTheWay({
        place = place, record = record,
        name = record.name or L.Format("recipe %s", record.recipeID),
    })
end

--- Queue materials: the materials for the crafts that give a skill point
--- for sure (until the recipe turns yellow, at least one), on the list to
--- buy. Set, not added, so a second click changes nothing.
-- @return how many lines were put on the list
function LearnNext:QueueMaterials(row)
    if not (row and row.record and ns.Queue and ns.Queue.EnsureBuy) then return 0 end
    local record = row.record
    local crafts = 1
    if record.yellow and row.skill and record.yellow > math.max(row.skill, row.needs or 0) then
        crafts = record.yellow - math.max(row.skill, row.needs or 0)
    end
    -- Tied to the recipe, not to its item: the first craft makes the item,
    -- and a line for owned gear lets itself go.
    local forRecipe = { recipeID = record.recipeID, name = row.name, crafts = crafts }
    local added = 0
    for _, reagent in ipairs(record.reagents or {}) do
        local ok, done = pcall(ns.Queue.EnsureBuy, ns.Queue, reagent.itemID,
            (reagent.quantity or 1) * crafts, nil, forRecipe)
        if ok and done then added = added + 1 end
    end
    if added > 0 then
        ns.Print(crafts == 1
            and L.Format("Put the materials for one %s on your list to buy.", row.name)
            or L.Format("Put the materials for %d %s on your list to buy, enough until it turns yellow.", crafts, row.name))
    else
        ns.Print(L.Format("Nothing for %s went on your list to buy.", row.name))
    end
    return added
end
