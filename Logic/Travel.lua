-- Blackthornes -- Logic/Travel.lua
-- Trips for the arrows (the owner, 2026-10-21: "guide players outside of
-- current zones and across continents"). A place in another zone or on the
-- other continent gets a way there, step by step, and the arrow points at
-- the next stop instead of straight over mountains and sea.
--
-- The travel map:
--
--   * Flight masters and the flights between them, from the Forever client's
--     game tables (Data/Travel.lua, tools/make_travel.py). Only your side's,
--     and only flights this character knows: read at a flight master when
--     its map opens (TAXIMAP_OPENED), kept per character by GUID in
--     `travelFlights[guid] = { [node] = true }`. Never one it has not seen.
--   * Boats and zeppelins between docks (Data/Travel.lua), your side's.
--   * Your Hearthstone, once the spot it lands on has been seen: kept,
--     account wide, by the inn's name in `travelHearth[bind]`.
--   * Walking between any two stops on one continent. When the walk passes
--     through other zones (Data/TravelZones.lua), the arrow aims at the spot
--     you crossed that border before (`travelCrossings["From|To"]`, account
--     wide, learned as you walk), else at the nearest edge of the next zone,
--     "toward NAME". Never a made up spot.
--
-- The quickest way is a shortest-path search over that map, cost in
-- seconds. The plan is worked out again only when it could have changed (a
-- new place, a zone change, a landing, a flight learned) or every REPLAN
-- seconds, never mid flight, never in a fight. The steps already behind you
-- are counted so "Step 2 of 3" holds as you go.
--
-- The same file goes in every Blackthornes addon (a fix to it belongs in
-- all of them). What is different in each addon comes through
-- `ns.TravelHost` (see Host below), so this file never names one. Each copy
-- signs up in `_G.BlackthornesTravel`, and what one copy has learned (the
-- flights you know, where you crossed, where your Hearthstone lands) the
-- others read too, so a flight learned with one addon loaded counts in all.
--
-- Saved in each addon's account save, never renamed: `arrowRoute` (on
-- unless ticked), `travelFlights`, `travelCrossings`, `travelHearth`.
-- Nothing is shared with anyone.

local addonName, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Travel = ns.NewModule("Travel")

Travel.FILE_VERSION = 2

-- Rough speeds and waits, yards a second and seconds.
Travel.WALK_SPEED = 8
Travel.WALK_DETOUR = 1.25
Travel.FLIGHT_SPEED = 32
Travel.FLIGHT_DETOUR = 1.3
Travel.FLIGHT_WAIT = 20
Travel.RIDE_COST = { boat = 300, zeppelin = 240 }
Travel.HEARTH_COST = 40

-- How near a stop counts as there, yards.
Travel.AT_STOP = 30

-- Seconds between plans while nothing happened.
Travel.REPLAN = 15

-- Hearthstone: the item and the spell it casts.
Travel.HEARTHSTONE = 6948
Travel.HEARTH_SPELL = 8690

-- A crossing keeps the average of at most this many walks.
Travel.CROSSING_KEEP = 20

-- The map type the client gives a continent.
local CONTINENT = 2

local DATA = ns.TRAVEL_DATA or { flights = {}, paths = {}, docks = {}, rides = {} }
Travel.DATA = DATA
local ZONES = ns.TRAVEL_ZONES or { maps = {}, borders = {}, inside = {}, aliases = {} }
Travel.ZONES = ZONES

--------------------------------------------------------------------------------
-- Reading the client
--------------------------------------------------------------------------------

local function Read(fn, ...)
    if type(fn) ~= "function" then return nil end
    local result = { pcall(fn, ...) }
    if not result[1] then return nil end
    return unpack(result, 2)
end

--- Text the client gave, or nil for nil, numbers and secret values.
function Travel.Readable(value)
    local kind = type(value)
    if kind == "number" or kind == "boolean" or value == nil then return nil end
    local ok, text = pcall(function() local copy = value .. "" return copy ~= "" and copy or nil end)
    return ok and type(text) == "string" and text or nil
end

--- A number the client gave, or nil for anything else and secret values.
function Travel.Number(value)
    local kind = type(value)
    if kind == "string" or kind == "boolean" or value == nil then return nil end
    local ok, number = pcall(function() local copy = value + 0 return copy == copy and copy or nil end)
    return ok and type(number) == "number" and number or nil
end

local Readable, Number = Travel.Readable, Travel.Number

local function Clock()
    return type(GetTime) == "function" and (Read(GetTime) or 0) or 0
end

local function Map() return type(_G.C_Map) == "table" and _G.C_Map or nil end

--- A point on map `mapID` (0 to 1 each way) as the world sees it:
--- continent, north, west in yards, or nil when the client will not say.
function Travel.WorldPos(mapID, x, y)
    local map = Map()
    if not (map and mapID and x and y) then return nil end
    if type(map.GetWorldPosFromMapPos) ~= "function" or type(CreateVector2D) ~= "function" then return nil end
    local ok, continent, position = pcall(map.GetWorldPosFromMapPos, mapID, CreateVector2D(x, y))
    if not ok or type(position) ~= "table" then return nil end
    local read, north, west = pcall(position.GetXY, position)
    if not read then return nil end
    continent, north, west = Number(continent), Number(north), Number(west)
    if not (continent and north and west) then return nil end
    return continent, north, west
end

--- A world point as a spot on the map it lies on: { map, x, y }, or nil.
function Travel.MapPos(continent, north, west)
    local map = Map()
    if not (map and continent and north and west) then return nil end
    if type(map.GetMapPosFromWorldPos) ~= "function" or type(CreateVector2D) ~= "function" then return nil end
    local ok, mapID, position = pcall(map.GetMapPosFromWorldPos, continent, CreateVector2D(north, west))
    if not ok or type(position) ~= "table" then return nil end
    local read, x, y = pcall(position.GetXY, position)
    mapID = Number(mapID)
    if not (read and mapID) then return nil end
    x, y = Number(x), Number(y)
    if not (x and y) then return nil end
    return { map = mapID, x = x, y = y }
end

--- The continent map the map `mapID` sits on, or nil.
function Travel.ContinentOf(mapID)
    local map = Map()
    for _ = 1, 8 do
        local info = map and mapID and Read(map.GetMapInfo, mapID)
        if type(info) ~= "table" then return nil end
        local ok, kind, parent = pcall(function() return info.mapType, info.parentMapID end)
        if not ok then return nil end
        if Number(kind) == CONTINENT then return mapID end
        parent = Number(parent)
        if not parent or parent <= 0 then return nil end
        mapID = parent
    end
    return nil
end

--------------------------------------------------------------------------------
-- What each addon fills in
--------------------------------------------------------------------------------

-- `ns.TravelHost` may give any of these; what it leaves out is done here.
local Defaults = {}

--- The account save this addon keeps its travel keys in.
function Defaults.DB() return ns.db end

--- The character playing, by GUID, or nil while the client will not say.
function Defaults.Owner()
    return type(UnitGUID) == "function" and Readable(Read(UnitGUID, "player")) or nil
end

--- A zone by its English name: "Elwynn" (a flight master's), a capital and
--- the zone it sits in all become the zone itself.
function Defaults.ZoneOf(zone)
    if type(zone) ~= "string" then return nil end
    zone = ZONES.aliases[zone] or zone
    return ZONES.inside[zone] or zone
end

--- The zone's name as the client shows it, for the words on screen.
function Defaults.Show(zone)
    local mapID = type(zone) == "string" and ZONES.maps[zone]
    local map = Map()
    local info = mapID and map and Read(map.GetMapInfo, mapID)
    local name = type(info) == "table" and Readable(Read(function() return info.name end))
    return name or zone
end

--- The zone a map is, or sits in, by the zone list's map IDs.
local MAP_ZONES = {}
for zone, mapID in pairs(ZONES.maps) do MAP_ZONES[mapID] = zone end
Travel.MAP_ZONES = MAP_ZONES

function Travel.ZoneOfMap(mapID)
    local map = Map()
    for _ = 1, 6 do
        if not mapID then return nil end
        if MAP_ZONES[mapID] then return MAP_ZONES[mapID] end
        local info = map and Read(map.GetMapInfo, mapID)
        if type(info) ~= "table" then return nil end
        local parent = Number(Read(function() return info.parentMapID end))
        if not parent or parent <= 0 then return nil end
        mapID = parent
    end
    return nil
end

--- Where you stand: { map, x, y, continent, north, west, zone }, or nil.
function Defaults.Here()
    local map = Map()
    local mapID = map and Number(Read(map.GetBestMapForUnit, "player"))
    if not mapID then return nil end
    local position = Read(map.GetPlayerMapPosition, mapID, "player")
    if type(position) ~= "table" then return nil end
    local ok, x, y = pcall(position.GetXY, position)
    x, y = ok and Number(x), ok and Number(y)
    if not (x and y) or (x == 0 and y == 0) then return nil end
    local here = { map = mapID, x = x, y = y }
    here.continent, here.north, here.west = Travel.WorldPos(mapID, x, y)
    here.zone = Travel.ZoneOfMap(mapID)
    return here
end

--- Inside a dungeon, raid or battleground.
function Defaults.InInstance()
    return type(IsInInstance) == "function" and Read(IsInInstance) and true or false
end

--- What tells two places apart, for keeping a plan.
function Defaults.Key(target)
    return ("%s|%s|%s|%s|%s"):format(tostring(target.name), tostring(target.zone), tostring(target.map),
        tostring(target.x or target.mx), tostring(target.y or target.my))
end

--- The arrow should work out what it shows again.
function Defaults.Changed() end

--- The arrow should draw again soon.
function Defaults.Refresh() end

--- The arrow's state as last drawn, for the card and the map line.
function Defaults.State() return nil end

function Defaults.Print(text) if ns.Print then ns.Print(text) end end

local Host = setmetatable({}, {
    __index = function(_, key)
        local host = ns.TravelHost
        local fn = type(host) == "table" and host[key]
        return type(fn) == "function" and fn or Defaults[key]
    end,
})
Travel.Host = Host
Travel.Defaults = Defaults

--------------------------------------------------------------------------------
-- Every copy, for what the others learned
--------------------------------------------------------------------------------

local shared = _G.BlackthornesTravel
if type(shared) ~= "table" then
    shared = { copies = {} }
    _G.BlackthornesTravel = shared
end
shared.copies = type(shared.copies) == "table" and shared.copies or {}
shared.copies[addonName or "?"] = { version = Travel.FILE_VERSION, module = Travel }

--- Every copy's module, this one first.
function Travel.Copies()
    local list = { Travel }
    for _, copy in pairs(shared.copies) do
        if type(copy) == "table" and type(copy.module) == "table" and copy.module ~= Travel then
            list[#list + 1] = copy.module
        end
    end
    return list
end

--- A table one copy keeps, read safely: its own save's `key`.
function Travel:Saved(key)
    local ok, value = pcall(function()
        local db = self.Host.DB()
        return type(db) == "table" and db[key] or nil
    end)
    return ok and type(value) == "table" and value or nil
end

--------------------------------------------------------------------------------
-- Switches and what you have learned
--------------------------------------------------------------------------------

local function DB() return Host.DB() end

function Travel.IsOn()
    local db = DB()
    return type(db) == "table" and db.arrowRoute ~= false
end

function Travel:SetOn(on)
    local db = DB()
    if type(db) ~= "table" then return end
    db.arrowRoute = on and true or false
    self:Forget()
    Host.Changed()
end

local function Store(key)
    local db = DB()
    if type(db[key]) ~= "table" then db[key] = {} end
    return db[key]
end

--- The flights this character knows, as this addon keeps them:
--- { [node] = true }, or nil while the client will not say who is playing.
function Travel:KnownFlights()
    local guid = Host.Owner()
    if not guid or type(DB()) ~= "table" then return nil end
    local all = Store("travelFlights")
    if type(all[guid]) ~= "table" then all[guid] = {} end
    return all[guid]
end

--- The flights this character knows, as any loaded addon kept them.
function Travel:AllFlights()
    local guid = Host.Owner()
    local known = {}
    if not guid then return known end
    for _, copy in ipairs(Travel.Copies()) do
        local all = copy.Saved and copy:Saved("travelFlights")
        local mine = all and all[guid]
        if type(mine) == "table" then
            for node, yes in pairs(mine) do
                if yes == true then known[node] = true end
            end
        end
    end
    return known
end

--- "A", "H", or nil while the client will not say.
function Travel.Side()
    if type(UnitFactionGroup) ~= "function" then return nil end
    local faction = Readable(Read(UnitFactionGroup, "player"))
    if faction == "Alliance" then return "A" end
    if faction == "Horde" then return "H" end
    return nil
end

local function SideAllows(rowSide, side)
    if rowSide == "AH" then return true end
    return side ~= nil and rowSide == side
end

--- Reads the flight master's map: the flights it shows as known.
function Travel:ReadFlightMap()
    local known = self:KnownFlights()
    if not known then return 0 end
    local added = 0

    local taxi = _G.C_TaxiMap
    local map = Map()
    local mapID = map and Number(Read(map.GetBestMapForUnit, "player"))
    local nodes = taxi and mapID and Read(taxi.GetAllTaxiNodes, mapID)
    if type(nodes) == "table" then
        for _, node in ipairs(nodes) do
            local ok, id, state = pcall(function() return node.nodeID, node.state end)
            id, state = ok and Number(id), ok and Number(state)
            -- Current (0) or reachable (1); unreachable (2) is not known.
            if id and DATA.flights[id] and (state == 0 or state == 1) and not known[id] then
                known[id], added = true, added + 1
            end
        end
    elseif type(NumTaxiNodes) == "function" then
        -- An older client: by name, English only.
        local byName = {}
        for id, row in pairs(DATA.flights) do byName[row[1]] = id end
        for index = 1, Number(Read(NumTaxiNodes)) or 0 do
            local kind = Readable(Read(TaxiNodeGetType, index))
            local id = byName[Readable(Read(TaxiNodeName, index)) or ""]
            if id and (kind == "CURRENT" or kind == "REACHABLE") and not known[id] then
                known[id], added = true, added + 1
            end
        end
    end
    if added > 0 then self:Forget() end
    return added
end

--- Keeps where you crossed from one zone into the next, on foot.
function Travel:NoteCrossing(from, to, here)
    if not (from and to and from ~= to and here and here.continent) then return end
    local near = false
    for _, zone in ipairs(ZONES.borders[from] or {}) do
        if zone == to then near = true end
    end
    if not near then return end

    local crossings = Store("travelCrossings")
    local key = from .. "|" .. to
    local kept = crossings[key]
    if type(kept) ~= "table" or kept[1] ~= here.continent then
        crossings[key] = { here.continent, math.floor(here.north + 0.5), math.floor(here.west + 0.5), 1 }
        return
    end
    local count = math.min((tonumber(kept[4]) or 1), Travel.CROSSING_KEEP)
    kept[2] = math.floor((kept[2] * count + here.north) / (count + 1) + 0.5)
    kept[3] = math.floor((kept[3] * count + here.west) / (count + 1) + 0.5)
    kept[4] = count + 1
end

--- The kept row `key` of the table `name`, this addon's first, else
--- another loaded addon's.
function Travel:Kept(name, key)
    for _, copy in ipairs(Travel.Copies()) do
        local all = copy.Saved and copy:Saved(name)
        if all and type(all[key]) == "table" then return all[key] end
    end
    return nil
end

--- The spot you crossed from `from` into `to` before: continent, north, west.
function Travel:Crossing(from, to)
    local kept = self:Kept("travelCrossings", from .. "|" .. to)
    if not kept then return nil end
    return tonumber(kept[1]), tonumber(kept[2]), tonumber(kept[3])
end

--- Where your Hearthstone takes you, when that spot has been seen and it is
--- ready: { continent, north, west, zone, name }, or nil.
function Travel:Hearth()
    local bind = type(GetBindLocation) == "function" and Readable(Read(GetBindLocation))
    local kept = bind and self:Kept("travelHearth", bind)
    if not kept then return nil end

    local count = Number(Read(_G.GetItemCount or (_G.C_Item and _G.C_Item.GetItemCount), Travel.HEARTHSTONE))
    if not count or count < 1 then return nil end
    local getCooldown = (_G.C_Container and _G.C_Container.GetItemCooldown) or _G.GetItemCooldown
    local start, duration = Read(getCooldown, Travel.HEARTHSTONE)
    start, duration = Number(start) or 0, Number(duration) or 0
    if start > 0 and duration > 2 and start + duration - Clock() > 1 then return nil end

    return { continent = kept[1], north = kept[2], west = kept[3], zone = kept[4], name = bind }
end

--------------------------------------------------------------------------------
-- The plan
--------------------------------------------------------------------------------

local function Distance(a, b)
    local north, west = a.north - b.north, a.west - b.west
    return math.sqrt(north * north + west * west)
end

local function WalkCost(a, b)
    return Distance(a, b) * Travel.WALK_DETOUR / Travel.WALK_SPEED
end

--- A flight master's name as players say it: "Stormwind", not
--- "Stormwind, Elwynn".
function Travel.ShortName(name)
    return (type(name) == "string" and name:match("^([^,]+)")) or name
end

--- The stops this character can use: flight masters it knows, docks of its
--- side. Each { key, kind, name, continent, north, west, zone, node, dock }.
function Travel:Stops(side, known)
    local stops = {}
    for id, row in pairs(DATA.flights or {}) do
        if known and known[id] and SideAllows(row[2], side) then
            stops["f" .. id] = {
                key = "f" .. id, kind = "flight", node = id, name = Travel.ShortName(row[1]),
                continent = row[3], north = row[4], west = row[5], zone = Defaults.ZoneOf(row[6]),
            }
        end
    end
    for key, row in pairs(DATA.docks or {}) do
        stops["d" .. key] = {
            key = "d" .. key, kind = "dock", dock = key, name = row[1],
            continent = row[2], north = row[3], west = row[4], zone = Defaults.ZoneOf(row[5]),
        }
    end
    return stops
end

--- The rides between stops: { [from] = { { to, kind, cost }, ... } }.
function Travel:Rides(stops, side)
    local rides = {}
    local function Add(from, to, kind, cost)
        if not (stops[from] and stops[to]) then return end
        rides[from] = rides[from] or {}
        table.insert(rides[from], { to = to, kind = kind, cost = cost })
    end

    local paths = DATA.paths or {}
    local lengths = DATA.lengths or {}
    for index = 1, #paths - 1, 2 do
        local from, to = "f" .. paths[index], "f" .. paths[index + 1]
        if stops[from] and stops[to] then
            -- How far the flight really goes, from the tables; a guess from
            -- the straight line only when they have no points for it.
            local yards = lengths[(index + 1) / 2]
            if not yards or yards <= 0 then
                yards = Distance(stops[from], stops[to]) * Travel.FLIGHT_DETOUR
            end
            local cost = yards / Travel.FLIGHT_SPEED
            Add(from, to, "fly", cost)
        end
    end
    for _, ride in ipairs(DATA.rides or {}) do
        if SideAllows(ride[4], side) then
            local cost = Travel.RIDE_COST[ride[3]] or 300
            Add("d" .. ride[1], "d" .. ride[2], ride[3], cost)
            Add("d" .. ride[2], "d" .. ride[1], ride[3], cost)
        end
    end
    return rides
end

--- The quickest way from `from` to `to` (each { continent, north, west,
--- zone }): a list of legs { kind, from, to, cost }, kind "walk", "fly",
--- "boat", "zeppelin" or "hearth", and the whole cost in seconds. Nil when
--- there is no way the character can take.
function Travel:Search(from, to, side, known, hearth)
    local stops = self:Stops(side, known)
    stops.start = { key = "start", kind = "start", continent = from.continent, north = from.north, west = from.west, zone = from.zone }
    stops.goal = { key = "goal", kind = "goal", continent = to.continent, north = to.north, west = to.west, zone = to.zone, name = to.name }
    if hearth then
        stops.hearth = { key = "hearth", kind = "hearth", continent = hearth.continent, north = hearth.north,
            west = hearth.west, zone = hearth.zone, name = hearth.name }
    end
    local rides = self:Rides(stops, side)
    if hearth then rides.start = { { to = "hearth", kind = "hearth", cost = Travel.HEARTH_COST } } end

    local cost, back, how, done = { start = 0 }, {}, {}, {}
    while true do
        local current, best
        for key, value in pairs(cost) do
            if not done[key] and (not best or value < best) then current, best = key, value end
        end
        if not current or current == "goal" then break end
        done[current] = true
        local stop = stops[current]

        local function Relax(key, kind, extra)
            local total = best + extra
            if not done[key] and (cost[key] == nil or total < cost[key]) then
                cost[key], back[key], how[key] = total, current, kind
            end
        end

        for key, other in pairs(stops) do
            if key ~= current and key ~= "start" and key ~= "hearth" and other.continent == stop.continent then
                Relax(key, "walk", WalkCost(stop, other))
            end
        end
        for _, ride in ipairs(rides[current] or {}) do Relax(ride.to, ride.kind, ride.cost) end
    end

    if cost.goal == nil then return nil end
    local legs, key = {}, "goal"
    while key ~= "start" do
        table.insert(legs, 1, { kind = how[key], from = stops[back[key]], to = stops[key] })
        key = back[key]
    end
    return legs, cost.goal
end

--- Legs as the steps a player reads. A walk to a stop folds into the ride
--- that leaves from it, flights in a row are one flight, and only the last
--- walk is a step of its own.
function Travel.Steps(legs)
    local steps = {}
    for _, leg in ipairs(legs or {}) do
        local last = steps[#steps]
        if leg.kind == "walk" then
            if leg.to.kind == "goal" then
                table.insert(steps, { kind = "walk", to = leg.to, from = leg.from })
            end
        elseif leg.kind == "fly" and last and last.kind == "fly" and last.to == leg.from then
            last.to = leg.to
        else
            table.insert(steps, { kind = leg.kind, from = leg.from, to = leg.to })
        end
    end
    return steps
end

--- The zones a walk on one continent passes through, in order, by the zone
--- borders (Data/TravelZones.lua); nil when the borders do not join them.
function Travel.ZonePath(from, to)
    local borders = ZONES.borders
    if not (from and to and borders[from] and borders[to]) then return nil end
    if from == to then return { from } end
    local back, queue, head = { [from] = false }, { from }, 1
    while queue[head] do
        local zone = queue[head]
        head = head + 1
        for _, near in ipairs(borders[zone] or {}) do
            if back[near] == nil then
                back[near] = zone
                if near == to then
                    local path = { to }
                    local step = zone
                    while step do
                        table.insert(path, 1, step)
                        step = back[step] or nil
                    end
                    return path
                end
                table.insert(queue, near)
            end
        end
    end
    return nil
end

--- A place as world coordinates: { continent, north, west, zone, name }.
--- A target gives `map` with `x`, `y` (0 to 1) or `mx`, `my` (0 to 1), or a
--- zone with `coords` (0 to 100), or only a zone (its middle).
function Travel:WorldOf(target)
    if type(target) ~= "table" then return nil end
    local zone = Host.ZoneOf(target.zone)
    local continent, north, west
    local x, y = target.mx or target.x, target.my or target.y
    if target.map and x and y and x <= 1 and y <= 1 then
        continent, north, west = Travel.WorldPos(target.map, x, y)
    end
    if not continent and zone then
        local mapID = ZONES.maps[zone]
        local coords = type(target.coords) == "table" and target.coords
        local cx = coords and tonumber(coords[1]) and coords[1] / 100 or 0.5
        local cy = coords and tonumber(coords[2]) and coords[2] / 100 or 0.5
        if mapID then continent, north, west = Travel.WorldPos(mapID, cx, cy) end
    end
    if not continent then return nil end
    return { continent = continent, north = north, west = west, zone = zone, name = target.name }
end

--- Whether a place is worth a trip: on the other continent, or a walk that
--- passes through another zone first.
function Travel.WorthATrip(here, place)
    if not (here and place and here.continent) then return false end
    if place.continent ~= here.continent then return true end
    local path = Travel.ZonePath(Host.ZoneOf(here.zone), place.zone)
    return path ~= nil and #path >= 3
end

function Travel:Forget()
    self.plan = nil
end

--- Stop on the card: no trip for this place; the arrow points straight
--- again until it is aimed somewhere else.
function Travel:StopTrip()
    self.stopped = self.plan and self.plan.key or self.lastKey
    self.plan = nil
    Host.Changed()
end

--- Works out the plan for `target` from `here` when it is due. Keeps the
--- steps already behind you counted.
function Travel:Plan(target, here, clock)
    local place = self:WorldOf(target)
    if not place then self.plan = nil return nil end
    local key = Host.Key(target)

    local plan = self.plan
    if plan and plan.key ~= key then plan = nil end
    if plan and plan.frozen then return plan end
    if plan and not self.due and clock - (plan.at or 0) < Travel.REPLAN and clock >= (plan.at or 0) then
        return plan
    end
    self.due = false

    if not Travel.WorthATrip(here, place) then
        self.plan = nil
        return nil
    end

    local legs, cost = self:Search(here, place, Travel.Side(), self:AllFlights(), self:Hearth())
    local steps = Travel.Steps(legs)
    if not legs or #steps == 0 then
        self.plan = nil
        return nil
    end
    local done, behind = 0, {}
    if plan then
        done = math.max(0, (plan.done or 0) + (#plan.steps - #steps))
        for _, step in ipairs(plan.behind or {}) do behind[#behind + 1] = step end
        -- The steps that dropped off the front are behind you now.
        for index = 1, math.min(done - (plan.done or 0), #plan.steps) do
            behind[#behind + 1] = plan.steps[index]
        end
        while #behind > done do table.remove(behind, 1) end
    end
    local previous = plan and plan.steps[1]
    self.plan = { key = key, place = place, steps = steps, cost = cost, done = done, behind = behind, at = clock }
    if previous and done > (plan.done or 0) and self.OnNext then self:OnNext(steps[1]) end
    return self.plan
end

--------------------------------------------------------------------------------
-- What the arrow shows for a step
--------------------------------------------------------------------------------

--- Where the arrow aims for walking toward `goal` from `here`: the goal, or
--- the way into the next zone when the walk passes through others first.
--- Returns continent, north, west and the zone it heads toward (or nil).
function Travel:Toward(here, goal)
    if here.continent ~= goal.continent then return nil end
    local path = Travel.ZonePath(Host.ZoneOf(here.zone), Host.ZoneOf(goal.zone))
    if not path or #path < 3 then return goal.continent, goal.north, goal.west, nil end

    local nextZone = path[2]
    local continent, north, west = self:Crossing(path[1], nextZone)
    if continent == here.continent then return continent, north, west, nextZone end

    -- The nearest edge of the next zone's map.
    local mapID = ZONES.maps[nextZone]
    if mapID then
        local c1, n1, w1 = Travel.WorldPos(mapID, 0, 0)
        local c2, n2, w2 = Travel.WorldPos(mapID, 1, 1)
        if c1 == here.continent and c2 == here.continent then
            local edgeNorth = math.max(math.min(n1, n2), math.min(math.max(n1, n2), here.north))
            local edgeWest = math.max(math.min(w1, w2), math.min(math.max(w1, w2), here.west))
            return c1, edgeNorth, edgeWest, nextZone
        end
    end
    return goal.continent, goal.north, goal.west, nil
end

--- The step's words: the line ("Take the boat to Theramore") and the small
--- line under it, without the distance.
function Travel.StepWords(step, atStop, onTaxi)
    local to = step.to and Travel.ShortName(step.to.name) or "?"
    if step.kind == "fly" then
        if onTaxi then return L.Format("Fly to %s", to), "" end
        return L.Format("Fly to %s", to), L["Talk to the flight master"]
    elseif step.kind == "boat" then
        if atStop then return L.Format("Wait here for the boat to %s", to), L["Get on when it stops"] end
        return L.Format("Take the boat to %s", to), ""
    elseif step.kind == "zeppelin" then
        if atStop then return L.Format("Wait here for the zeppelin to %s", to), L["Get on when it stops"] end
        return L.Format("Take the zeppelin to %s", to), ""
    elseif step.kind == "hearth" then
        return L["Use your Hearthstone"], L.Format("It takes you to %s", to)
    end
    return L.Format("Walk to %s", to), ""
end

--- Everything the arrow needs while a trip is on: { index, count, line,
--- small, continent, north, west, toward, step, plan, point }, or nil when
--- the arrow should point as it always has.
function Travel:Use(target, here, clock)
    if not Travel.IsOn() or not (here and here.continent) then return nil end

    local key = Host.Key(target)
    self.lastKey = key
    if self.stopped then
        if self.stopped == key then return nil end
        self.stopped = nil
    end

    local onTaxi = type(UnitOnTaxi) == "function" and Read(UnitOnTaxi, "player") == true
    if self.plan then self.plan.frozen = onTaxi or nil end
    local inFight = type(InCombatLockdown) == "function" and Read(InCombatLockdown) == true
    local plan = (inFight and self.plan and self.plan.key == key) and self.plan
        or self:Plan(target, here, clock or Clock())
    if not plan then return nil end

    local step = plan.steps[1]
    local trip = { index = plan.done + 1, count = plan.done + #plan.steps, step = step, plan = plan, onTaxi = onTaxi }

    local aim = step.kind == "walk" and step.to or step.from
    if step.kind == "hearth" then aim = nil end
    local atStop = false
    if aim then
        local continent, north, west, toward = self:Toward(here, aim)
        trip.continent, trip.north, trip.west, trip.toward = continent, north, west, toward
        if continent == here.continent and not toward then
            atStop = Distance(here, aim) <= Travel.AT_STOP
        end
    end
    trip.line, trip.small = Travel.StepWords(step, atStop and step.kind ~= "walk", onTaxi)
    if trip.toward then
        local toward = L.Format("toward %s", Host.Show(trip.toward))
        trip.small = trip.small ~= "" and (trip.small .. ", " .. toward) or toward
    end
    trip.atStop = atStop
    return trip
end

--- The steps of a trip to `target` from where you stand, as lines to print,
--- and the next stop as { map, x, y, name } for a map pin; nil when the
--- place needs no trip. For the addons whose Show the Way pins a place.
function Travel:Guide(target)
    if not Travel.IsOn() then return nil end
    local here = Host.Here()
    if not (here and here.continent) or Host.InInstance() then return nil end
    self.stopped, self.due = nil, true
    local trip = self:Use(target, here, Clock())
    if not trip then return nil end
    local lines = {}
    for index, step in ipairs(trip.plan.steps) do
        lines[#lines + 1] = ("%d. %s"):format(trip.index + index - 1, (Travel.StepWords(step)))
    end
    local point
    if trip.continent and trip.continent == here.continent then
        point = Travel.MapPos(trip.continent, trip.north, trip.west)
        if point then point.name = trip.line end
    end
    return { lines = lines, point = point, trip = trip }
end

--- Minutes the rest of the trip takes, about.
function Travel.Minutes(plan)
    return math.max(1, math.floor(((plan and plan.cost) or 0) / 60 + 0.5))
end

--- "Next: Take the boat to Theramore." once a step is behind you.
function Travel:OnNext(step)
    if not step then return end
    local line = Travel.StepWords(step, false, false)
    Host.Print(L.Format("Next: %s.", line))
end

--------------------------------------------------------------------------------
-- Watching for what changes a plan
--------------------------------------------------------------------------------

function Travel:Due()
    self.due = true
    Host.Refresh()
end

function Travel:OnZoneChanged()
    local here = Host.Here()
    local zone = here and Host.ZoneOf(here.zone)
    local onTaxi = type(UnitOnTaxi) == "function" and Read(UnitOnTaxi, "player") == true
    local inside = Host.InInstance()
    if zone and self.lastZone and zone ~= self.lastZone and not onTaxi and not inside and not self.hearthing then
        self:NoteCrossing(self.lastZone, zone, here)
    end
    if zone then self.lastZone = zone end

    if self.hearthing and here and here.continent and Clock() - self.hearthing.at < 60 then
        local saved = Store("travelHearth")
        saved[self.hearthing.bind] = { here.continent, math.floor(here.north + 0.5), math.floor(here.west + 0.5), zone }
    end
    self.hearthing = nil
    self:Due()
end

local function Later(seconds, fn)
    if C_Timer and C_Timer.After then C_Timer.After(seconds, fn) else fn() end
end

function Travel:OnEnable()
    ns.RegisterEvent(self, "TAXIMAP_OPENED", function() Travel:ReadFlightMap() end)
    ns.RegisterEvent(self, "ZONE_CHANGED_NEW_AREA", function()
        Later(1, function() Travel:OnZoneChanged() end)
    end)
    ns.RegisterEvent(self, "PLAYER_CONTROL_GAINED", function() Travel:Due() end)
    ns.RegisterEvent(self, "PLAYER_ENTERING_WORLD", function()
        Later(2, function() Travel:OnZoneChanged() end)
    end)
    local register = ns.RegisterPlayerEvent or ns.RegisterEvent
    register(self, "UNIT_SPELLCAST_SUCCEEDED", function(_, _, unit, _, spellID)
        if unit ~= "player" or Number(spellID) ~= Travel.HEARTH_SPELL then return end
        local bind = type(GetBindLocation) == "function" and Readable(Read(GetBindLocation))
        if bind then Travel.hearthing = { bind = bind, at = Clock() } end
    end)
end
