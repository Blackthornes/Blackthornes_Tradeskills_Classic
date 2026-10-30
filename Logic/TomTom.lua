-- Blackthornes Tradeskills -- Logic/TomTom.lua
-- The arrow's place, handed to TomTom (the owner asked 2026-10-09 for
-- Farmer's TomTom hand-off in every addon with an arrow).
--
-- When TomTom is installed and "Use TomTom" is ticked (on unless unticked),
-- the place the arrow would point at goes to TomTom as a waypoint, and
-- the dial stays hidden, so only TomTom's arrow is on screen. The waypoint
-- follows the dial: a new place swaps it, and the arrow turned off, nothing
-- to follow, a dungeon, or another Blackthornes arrow aimed later take it
-- away. Places the dial cannot point at (far away, the zone you are in)
-- have no waypoint; the dial shows them as before.
--
-- Without TomTom, nothing changes. TomTom is only read through its global,
-- inside a pcall, so a missing or different version breaks nothing: a
-- waypoint TomTom will not take falls back to the dial. Waypoints are never
-- saved in TomTom's list; they are added again after a reload. Farmer's
-- Logic/TomTom.lua does the same for the goal arrow.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local TomTomLink = ns.NewModule("TomTom")

local FROM = "Blackthornes Tradeskills"

--- TomTom's global, when it is loaded and has the calls used here.
function TomTomLink.Addon()
    local tomtom = rawget(_G, "TomTom")
    if type(tomtom) ~= "table" then return nil end
    local ok, usable = pcall(function()
        return type(tomtom.AddWaypoint) == "function" and type(tomtom.RemoveWaypoint) == "function"
    end)
    return ok and usable and tomtom or nil
end

function TomTomLink.Installed()
    return TomTomLink.Addon() ~= nil
end

--- The switch: on unless the player unticked it.
function TomTomLink.IsOn()
    return ns.db ~= nil and ns.db.useTomTom ~= false
end

function TomTomLink:SetOn(on)
    ns.db.useTomTom = on and true or false
    if ns.SharedChoices then ns.SharedChoices:Changed("useTomTom", ns.db.useTomTom) end
    if not on then self:Clear() end
    if ns.WayArrow then ns.WayArrow:Changed() end
    if ns.SettingsUI and ns.SettingsUI.Refresh then pcall(ns.SettingsUI.Refresh, ns.SettingsUI) end
end

--- True when TomTom shows the arrow's place for this state.
function TomTomLink.Fits(state)
    if not (TomTomLink.IsOn() and TomTomLink.Installed()) then return false end
    if type(state) ~= "table" or not (state.mode == "point" or state.mode == "arrived") then
        return false
    end
    local target = TomTomLink.Point(state)
    return type(target) == "table" and type(target.map) == "number"
        and type(target.mx) == "number" and type(target.my) == "number"
end

--- The place TomTom is given: the next stop on a trip (Logic/Travel.lua),
--- else the place itself.
function TomTomLink.Point(state)
    if type(state.trip) == "table" then return state.trip.point end
    return state.target
end

--- What the waypoint is called: "Mangy Wolf  6-7: Elwynn Forest".
function TomTomLink.Title(state)
    if type(state.trip) == "table" and state.trip.line then return state.trip.line end
    local place = state.target.zone or "?"
    local name = state.name
    if type(name) == "string" and name ~= "" then return name .. ": " .. place end
    return place
end

--- Is our waypoint still on TomTom? True when TomTom cannot say.
function TomTomLink.StillThere(uid)
    local tomtom = TomTomLink.Addon()
    if not (tomtom and type(tomtom.IsValidWaypoint) == "function") then return true end
    local ok, valid = pcall(tomtom.IsValidWaypoint, tomtom, uid)
    if not ok then return true end
    return valid and true or false
end

--- Give TomTom the place for `state`. True when TomTom shows it, so the
--- dial can stay hidden; false (and no waypoint of ours left) otherwise.
function TomTomLink:Take(state)
    if not TomTomLink.Fits(state) then
        self:Clear()
        return false
    end

    local target = TomTomLink.Point(state)
    local title = TomTomLink.Title(state)
    local key = ("%s|%s|%.4f|%.4f"):format(title, tostring(target.map), target.mx, target.my)
    if self.uid and self.key == key then
        if TomTomLink.StillThere(self.uid) then return true end
        -- TomTom took it off itself (it clears a waypoint on arrival, or
        -- the player removed it): the dial shows the way again, with its
        -- arrival check, until the place changes.
        self.uid, self.key, self.refused = nil, nil, key
        return false
    end
    -- TomTom turned this one down already: the dial shows it.
    if self.refused == key then return false end

    self:Clear()
    local tomtom = TomTomLink.Addon()
    local ok, uid = pcall(tomtom.AddWaypoint, tomtom, target.map, target.mx, target.my, {
        title = title, desc = title, from = FROM,
        persistent = false, minimap = true, world = true, crazy = true, silent = true,
    })
    if not ok or uid == nil then
        ns.Debug("TomTom would not take the waypoint:", tostring(uid))
        self.refused = key
        return false
    end

    self.uid, self.key, self.refused = uid, key, nil
    return true
end

--- Take our waypoint off TomTom, if there is one.
function TomTomLink:Clear()
    local uid = self.uid
    -- A place TomTom turned down is offered again after a clearing: the
    -- arrow turned off and on, or Use TomTom re-ticked, means try again,
    -- not keep the dial until the place changes.
    self.uid, self.key, self.refused = nil, nil, nil
    if uid == nil then return end
    local tomtom = TomTomLink.Addon()
    if tomtom then pcall(tomtom.RemoveWaypoint, tomtom, uid) end
end

--- One line for the arrow check.
function TomTomLink.CheckLine()
    if not TomTomLink.Installed() then
        return "  TomTom: not installed, so the dial shows the way"
    end
    if not TomTomLink.IsOn() then
        return "  TomTom: installed, not used (Settings, Use TomTom)"
    end
    return "  TomTom: yes, its arrow shows the way and the dial hides"
end
