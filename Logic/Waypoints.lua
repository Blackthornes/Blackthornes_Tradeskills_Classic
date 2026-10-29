-- Blackthornes Tradeskills -- Logic/Waypoints.lua
-- The game's own map pin, for Learn next's Show the way (2026-10-12).
--
-- Equipment's Logic/Waypoints.lua trimmed to the pin: a zone's map ID is
-- found from the client's own map list rather than a table typed here, so a
-- map Forever numbers differently still works; a client in another language
-- names its maps in that language, so there Classic's map IDs stand in
-- (Waypoints.ZONE_MAPS). With TomTom installed its arrow takes the place
-- instead (Waypoints:TomTom), never kept past the session. Every call is
-- inside a pcall; a client without them simply cannot pin.

local _, ns = ...

local Waypoints = ns.NewModule("Waypoints")

local function Read(fn, ...)
    if type(fn) ~= "function" then return nil end
    local result = { pcall(fn, ...) }
    if not result[1] then return nil end
    return unpack(result, 2)
end

local function Plain(value)
    local ok, copy = pcall(function()
        if type(value) == "string" and value ~= "" then return value .. "" end
    end)
    return ok and copy or nil
end

local function Number(value)
    local ok, copy = pcall(function() return tonumber(value) end)
    return ok and copy or nil
end

local function Map() return type(_G.C_Map) == "table" and _G.C_Map or nil end

--------------------------------------------------------------------------------
-- Zone names on a client in another language
--
-- The data names zones in English ("Elwynn Forest"); a German client names
-- them in German ("Wald von Elwynn"), so a name alone never matches there.
-- These are Classic's map IDs for the zones the data names, the same IDs
-- the tests and Farmer use (Elwynn Forest 1429, Dun Morogh 1426). They are
-- only asked on a client that is not English, and always after the name:
-- an English client works exactly as before, and an ID Forever numbers
-- differently only means the name is used, as it always was.
--------------------------------------------------------------------------------

Waypoints.ZONE_MAPS = {
    ["Durotar"] = 1411, ["Mulgore"] = 1412, ["The Barrens"] = 1413, ["Kalimdor"] = 1414,
    ["Eastern Kingdoms"] = 1415, ["Alterac Mountains"] = 1416, ["Arathi Highlands"] = 1417,
    ["Badlands"] = 1418, ["Blasted Lands"] = 1419, ["Tirisfal Glades"] = 1420,
    ["Silverpine Forest"] = 1421, ["Western Plaguelands"] = 1422, ["Eastern Plaguelands"] = 1423,
    ["Hillsbrad Foothills"] = 1424, ["The Hinterlands"] = 1425, ["Dun Morogh"] = 1426,
    ["Searing Gorge"] = 1427, ["Burning Steppes"] = 1428, ["Elwynn Forest"] = 1429,
    ["Deadwind Pass"] = 1430, ["Duskwood"] = 1431, ["Loch Modan"] = 1432,
    ["Redridge Mountains"] = 1433, ["Stranglethorn Vale"] = 1434, ["Swamp of Sorrows"] = 1435,
    ["Westfall"] = 1436, ["Wetlands"] = 1437, ["Teldrassil"] = 1438, ["Darkshore"] = 1439,
    ["Ashenvale"] = 1440, ["Thousand Needles"] = 1441, ["Stonetalon Mountains"] = 1442,
    ["Desolace"] = 1443, ["Feralas"] = 1444, ["Dustwallow Marsh"] = 1445, ["Tanaris"] = 1446,
    ["Azshara"] = 1447, ["Felwood"] = 1448, ["Un'Goro Crater"] = 1449, ["Moonglade"] = 1450,
    ["Silithus"] = 1451, ["Winterspring"] = 1452, ["Stormwind City"] = 1453,
    ["Orgrimmar"] = 1454, ["Ironforge"] = 1455, ["Thunder Bluff"] = 1456,
    ["Darnassus"] = 1457, ["Undercity"] = 1458, ["Alterac Valley"] = 1459,
}

--- Is the client English? Nil from GetLocale counts as English, so nothing
--- changes on a client that will not say.
function Waypoints.English()
    local locale = Plain(Read(_G.GetLocale))
    return locale == nil or locale:sub(1, 2) == "en"
end

--- Can this client put a pin on the map at all?
function Waypoints:CanPin()
    local map = Map()
    return map ~= nil and type(map.SetUserWaypoint) == "function"
        and type(_G.UiMapPoint) == "table" and type(_G.UiMapPoint.CreateFromCoordinates) == "function"
end

--- A map's name and parent.
local function Info(mapID)
    local map = Map()
    local info = map and Read(map.GetMapInfo, mapID)
    if type(info) ~= "table" then return nil end
    local ok, name, parent = pcall(function() return info.name, info.parentMapID end)
    if not ok then return nil end
    return Plain(name), Number(parent)
end

--- The highest map above the one the character is on.
local function TopMap()
    local map = Map()
    local here = map and Number(Read(map.GetBestMapForUnit, "player"))
    if not here then return nil end
    local top = here
    for _ = 1, 10 do
        local _, parent = Info(top)
        if not parent or parent <= 0 then break end
        top = parent
    end
    return top
end

--- The map ID of a zone, by its name, or nil. Kept once found.
function Waypoints:MapFor(zone)
    if type(zone) ~= "string" or zone == "" then return nil end
    self.found = self.found or {}
    if self.found[zone] then return self.found[zone] end

    local map = Map()
    local top = TopMap()
    -- A miss is kept for the map it was looked for from: from another
    -- continent (or out of an instance) the zone may well be found.
    local missKey = top and (top .. "|" .. zone)
    if missKey and self.found[missKey] == false then return nil end
    local mapID
    if map and top then
        local name = Info(top)
        if name == zone then mapID = top end
        -- Every map under the top one, zones and continents alike.
        local children = not mapID and Read(map.GetMapChildrenInfo, top, nil, true)
        if type(children) == "table" then
            for _, child in ipairs(children) do
                local ok, childName, childID = pcall(function() return child.name, child.mapID end)
                if ok and Plain(childName) == zone and Number(childID) then
                    mapID = Number(childID)
                    break
                end
            end
        end
    end

    -- A client in another language names its maps in that language: then
    -- Classic's map ID for the zone, when the client knows that map.
    if not mapID and map and Waypoints.ZONE_MAPS[zone] and not Waypoints.English() then
        local id = Waypoints.ZONE_MAPS[zone]
        if type(Read(map.GetMapInfo, id)) == "table" then mapID = id end
    end

    -- Only a search that ran is kept: on a loading screen or a taxi the
    -- client has no map yet, and that must not hide the zone until /reload.
    if map and top then
        if mapID then self.found[zone] = mapID else self.found[missKey] = false end
    end
    return mapID
end

--- Put the map pin on a place { zone, x, y } (x and y 0-100 on the zone's
--- map; a map ID as `mapID` in place of the zone) and point the game's
--- arrow at it.
-- @return true, or false and why ("nospot", "noclient", "nomap")
function Waypoints:Pin(place)
    if not (place and (place.zone or place.mapID) and place.x and place.y) then return false, "nospot" end
    if not self:CanPin() then return false, "noclient" end
    local mapID = place.mapID or self:MapFor(place.zone)
    if not mapID then return false, "nomap" end
    local x, y
    mapID, x, y = Waypoints.PinnableSpot(mapID, place.x / 100, place.y / 100)
    if not mapID then return false, "noclient" end

    local ok = pcall(function()
        local point = _G.UiMapPoint.CreateFromCoordinates(mapID, x, y)
        _G.C_Map.SetUserWaypoint(point)
        local super = _G.C_SuperTrack
        if type(super) == "table" and type(super.SetSuperTrackedUserWaypoint) == "function" then
            super.SetSuperTrackedUserWaypoint(true)
        end
    end)
    if not ok then return false, "noclient" end
    -- The game can turn a pin down without a word: only a pin it kept counts.
    local map = Map()
    if map and type(map.HasUserWaypoint) == "function" and Read(map.HasUserWaypoint) == false then
        return false, "noclient"
    end
    return true
end

--- Lay our own gold marker on a place { zone or mapID, x, y } (UI/SpotMarker.lua).
--- Forever turns the game's own pin down (a German player found nothing at
--- the Crossroads, 2026-10-29), so the marker is what shows on the map; the
--- game's pin, when it takes one, is a bonus. Without one the marker goes
--- when you stand on it, by the arrow (Logic/WayArrow.lua).
-- @return true when a marker was laid
function Waypoints:Mark(place, name, gamePin)
    local marker = ns.SpotMarker
    if not (marker and marker.Show and type(place) == "table" and place.x and place.y) then return false end
    local mapID = Number(place.mapID) or self:MapFor(place.zone)
    if not mapID then return false end
    local ok, laid = pcall(marker.Show, marker, { map = mapID, x = place.x, y = place.y },
        { name = name, gamePin = gamePin, arrow = ns.WayArrow })
    return ok and laid == true
end

--- A map the game takes a pin on, and the spot (0-1) on it. Some maps (a
--- city or a building on some clients) take none: then the map around it,
--- with the spot moved over by where the one map sits on the other.
-- @return mapID, x, y, or nil when no map up the line takes a pin
function Waypoints.PinnableSpot(mapID, x, y)
    local map = Map()
    if not (map and type(map.CanSetUserWaypointOnMap) == "function") then return mapID, x, y end
    for _ = 1, 4 do
        if Read(map.CanSetUserWaypointOnMap, mapID) ~= false then return mapID, x, y end
        local _, parent = Info(mapID)
        if not parent or parent <= 0 then return nil end
        local minX, maxX, minY, maxY = Read(map.GetMapRectOnMap, mapID, parent)
        minX, maxX, minY, maxY = Number(minX), Number(maxX), Number(minY), Number(maxY)
        if not (minX and maxX and minY and maxY) then return nil end
        x = minX + x * (maxX - minX)
        y = minY + y * (maxY - minY)
        mapID = parent
    end
    return nil
end

-- TomTom (a player asked for it in Farmer, Equipment and Pets; here it is
-- read the same way): the one waypoint Tradeskills set, replaced by the next.
local function TomTomAddon()
    local tomtom = rawget(_G, "TomTom")
    if type(tomtom) ~= "table" then return nil end
    local ok, usable = pcall(function()
        return type(tomtom.AddWaypoint) == "function" and type(tomtom.RemoveWaypoint) == "function"
    end)
    return ok and usable and tomtom or nil
end

function Waypoints:HasTomTom()
    return TomTomAddon() ~= nil
end

--- Hand a place to TomTom's arrow. `title` is what its arrow says.
-- @return true, or false and why ("nospot", "notomtom", "nomap")
function Waypoints:TomTom(place, title)
    if not (place and (place.zone or place.mapID) and place.x and place.y) then return false, "nospot" end
    local tomtom = TomTomAddon()
    if not tomtom then return false, "notomtom" end
    local mapID = place.mapID or self:MapFor(place.zone)
    if not mapID then return false, "nomap" end

    if self.tomtomUID ~= nil then pcall(tomtom.RemoveWaypoint, tomtom, self.tomtomUID) end
    self.tomtomUID = nil
    local ok, uid = pcall(tomtom.AddWaypoint, tomtom, mapID, place.x / 100, place.y / 100, {
        title = title, desc = title, from = "Blackthornes Tradeskills",
        persistent = false, minimap = true, world = true, crazy = true, silent = true,
    })
    if not ok or uid == nil then return false, "notomtom" end
    self.tomtomUID = uid
    return true
end

--- One line for /bts probe.
function Waypoints:ProbeText()
    local parts = { self:CanPin() and "map pin yes" or "map pin NO" }
    local super = _G.C_SuperTrack
    parts[#parts + 1] = (type(super) == "table" and type(super.SetSuperTrackedUserWaypoint) == "function")
        and "arrow yes" or "arrow NO"
    parts[#parts + 1] = self:HasTomTom() and "TomTom installed" or "no TomTom"
    local here = Map() and Number(Read(Map().GetBestMapForUnit, "player"))
    if here and type(Map().CanSetUserWaypointOnMap) == "function" then
        parts[#parts + 1] = Read(Map().CanSetUserWaypointOnMap, here) == false
            and ("pin on map " .. here .. " NO") or ("pin on map " .. here .. " yes")
    end
    local map = Map()
    parts[#parts + 1] = (map and type(map.GetMapChildrenInfo) == "function") and "map list yes" or "map list NO"
    return table.concat(parts, ", ")
end
