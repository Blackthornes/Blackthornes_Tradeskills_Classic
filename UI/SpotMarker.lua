-- Blackthornes -- UI/SpotMarker.lua
-- The big gold marker Show on Map lays on the world map: an icon in a wide
-- gold ring with two waves going out for a few seconds, then a slow glow,
-- the place's name under it. Effects Subtle keeps a still glow, Off holds
-- still. It is our own frame on the map's canvas, so it shows even when the
-- game turns its own pin down, as Forever does (a German player found
-- nothing at the Crossroads, 2026-10-29). The same file in Pets,
-- Tradeskills, Butler and Farmer; Equipment's MapPins has the same marker.
-- A fix to one belongs in all.
--
-- SpotMarker:Show(place, opts) with place { map (the zone's map ID), x, y }
-- (0 to 100) and opts { icon, name, gamePin, area, arrow }. It goes when
-- another place is shown, when the game's pin it came with is taken off
-- (gamePin), or, with no game pin, when you stand on it (opts.arrow: the
-- addon's arrow module, with Here, Offset, Measure and ARRIVED). A zone-only
-- marker (area) stays until the next Show. Nothing is saved, and it holds no
-- words of its own: the caller passes the name. Every map call is in a
-- pcall; a map this cannot read simply shows no marker.

local _, ns = ...

local SpotMarker = ns.NewModule("SpotMarker")

local Theme = ns.Theme

local ROUND = [[Interface\CharacterFrame\TempPortraitAlphaMask]]

SpotMarker.SIZE = 34
SpotMarker.STEP = 0.2         -- seconds between looks at the map
SpotMarker.ARRIVE_LOOK = 1    -- seconds between looks at where you stand
SpotMarker.WAVE_FOR = 4       -- seconds the waves run after a Show
SpotMarker.WAVE_TIME = 1.6    -- seconds one wave takes to go out
SpotMarker.WAVE_GROW = 2.6    -- how far a wave grows, times the ring
SpotMarker.ICON = [[Interface\Icons\INV_Misc_Map_01]]

local function Number(value)
    local ok, copy = pcall(function() return tonumber(value) end)
    return ok and copy or nil
end

local function Now()
    return type(_G.GetTime) == "function" and _G.GetTime() or 0
end

--- Lay the marker on `place`. Returns true when one was laid.
function SpotMarker:Show(place, opts)
    opts = type(opts) == "table" and opts or {}
    local map = type(place) == "table" and Number(place.map)
    local x = type(place) == "table" and Number(place.x)
    local y = type(place) == "table" and Number(place.y)
    if not (map and x and y) then
        self:Clear()
        return false
    end
    self.current = {
        place = place, map = map, x = x, y = y,
        icon = opts.icon or self.ICON, name = opts.name or place.name,
        gamePin = opts.gamePin and true or false, area = opts.area and true or false,
        arrow = opts.arrow, at = Now(),
    }
    self.key, self.arriveSince = nil, 0
    self:Wake()
    return true
end

function SpotMarker:Clear()
    self.current, self.key = nil, nil
    if self.spot then self.spot:Hide() end
    if self.driver then self.driver:Hide() end
end

--- The marker's look `age` seconds after it was laid, by the effects level:
--- { glow, waves = { { size, alpha }, ... } }. Waves only on Full, for
--- WAVE_FOR seconds; then the glow breathes. Subtle keeps a still glow.
function SpotMarker.Look(age, level)
    local look = { glow = 0.5, waves = {} }
    if level == "off" then return look end
    if level ~= "full" then
        look.glow = 0.55
        return look
    end
    age = math.max(0, age or 0)
    if age < SpotMarker.WAVE_FOR then
        look.glow = 0.7
        for wave = 0, 1 do
            local start = wave * SpotMarker.WAVE_TIME / 2
            if age >= start then
                local t = ((age - start) % SpotMarker.WAVE_TIME) / SpotMarker.WAVE_TIME
                look.waves[#look.waves + 1] = {
                    size = SpotMarker.SIZE * (1 + (SpotMarker.WAVE_GROW - 1) * t),
                    alpha = 0.7 * (1 - t),
                }
            end
        end
    else
        look.glow = 0.45 + 0.25 * math.sin((age - SpotMarker.WAVE_FOR) * 2.4)
    end
    return look
end

--- What the world map is showing: { canvas, mapID, scale, width, height },
--- or nil when it is shut or cannot be read.
function SpotMarker:View()
    local map = _G.WorldMapFrame
    if type(map) ~= "table" then return nil end
    local okShown, shown = pcall(map.IsShown, map)
    if not (okShown and shown) then return nil end

    local canvas
    if type(map.GetCanvas) == "function" then
        local ok, value = pcall(map.GetCanvas, map)
        if ok then canvas = value end
    end
    canvas = canvas or (map.ScrollContainer and map.ScrollContainer.Child)
    if type(canvas) ~= "table" then return nil end

    local mapID
    if type(map.GetMapID) == "function" then
        local ok, value = pcall(map.GetMapID, map)
        if ok then mapID = Number(value) end
    end
    if not mapID then return nil end

    local scale = 1
    local scroll = map.ScrollContainer
    if type(scroll) == "table" and type(scroll.GetCanvasScale) == "function" then
        local ok, value = pcall(scroll.GetCanvasScale, scroll)
        scale = ok and Number(value) or 1
    end
    if not scale or scale <= 0 then scale = 1 end

    local okW, width = pcall(canvas.GetWidth, canvas)
    local okH, height = pcall(canvas.GetHeight, canvas)
    width, height = okW and Number(width), okH and Number(height)
    if not (width and height and width > 0 and height > 0) then return nil end

    return { canvas = canvas, mapID = mapID, scale = scale, width = width, height = height }
end

function SpotMarker:Make(canvas)
    local size = self.SIZE
    local spot = CreateFrame("Frame", nil, canvas)
    spot:SetSize(size, size)
    pcall(spot.EnableMouse, spot, false)

    local glow = spot:CreateTexture(nil, "BACKGROUND")
    glow:SetPoint("CENTER")
    glow:SetSize(size + 26, size + 26)
    glow:SetTexture(ROUND)
    glow:SetVertexColor(Theme.Unpack("accent"))
    pcall(glow.SetBlendMode, glow, "ADD")
    spot.glow = glow

    spot.waves = {}
    for index = 1, 2 do
        local wave = spot:CreateTexture(nil, "BACKGROUND", nil, 1)
        wave:SetPoint("CENTER")
        wave:SetSize(size, size)
        wave:SetTexture(ROUND)
        wave:SetVertexColor(Theme.Unpack("accent"))
        pcall(wave.SetBlendMode, wave, "ADD")
        wave:Hide()
        spot.waves[index] = wave
    end

    local ring = spot:CreateTexture(nil, "BORDER")
    ring:SetPoint("CENTER")
    ring:SetSize(size, size)
    ring:SetTexture(ROUND)
    ring:SetVertexColor(Theme.Unpack("accent"))

    local icon = spot:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("CENTER")
    icon:SetSize(size - 6, size - 6)
    pcall(icon.SetMask, icon, ROUND)
    spot.icon = icon

    local label = Theme.CreateLabel(spot, "normal", "accent", "CENTER")
    label:SetPoint("TOP", spot, "BOTTOM", 0, -3)
    pcall(label.SetShadowOffset, label, 1, -1)
    pcall(label.SetShadowColor, label, 0, 0, 0, 1)
    spot.label = label

    spot:SetScript("OnUpdate", function(frame) SpotMarker:Animate(frame) end)
    return spot
end

--- One frame of the marker's motion; runs only while it shows.
function SpotMarker:Animate(spot)
    local light = self.current
    if not light then return end
    local level = ns.Motion and ns.Motion.Level and ns.Motion.Level() or "full"
    local look = SpotMarker.Look(Now() - (light.at or Now()), level)
    spot.glow:SetAlpha(look.glow)
    for index, wave in ipairs(spot.waves) do
        local shape = look.waves[index]
        if shape then
            wave:SetSize(shape.size, shape.size)
            wave:SetAlpha(shape.alpha)
            wave:Show()
        else
            wave:Hide()
        end
    end
end

--- Place the marker on the map shown, or hide it when that is another map.
--- Re-placed only when the map, zoom or marker changed.
function SpotMarker:Draw()
    local light = self.current
    local view = light and self:View() or nil
    local key = view and ("%d:%s:%s:%s:%s"):format(view.mapID, view.scale, view.width, view.height,
        tostring(light.at)) or "none"
    if key == self.key then return end
    self.key = key
    if not (view and view.mapID == light.map) then
        if self.spot then self.spot:Hide() end
        return
    end
    local spot = self.spot
    if not spot or spot.canvas ~= view.canvas then
        if spot then spot:Hide() end
        spot = self:Make(view.canvas)
        spot.canvas = view.canvas
        self.spot = spot
    end
    local okLevel, level = pcall(view.canvas.GetFrameLevel, view.canvas)
    level = (okLevel and Number(level) or 1) + 22
    local scale = 1 / view.scale
    spot.icon:SetTexture(light.icon or self.ICON)
    spot.label:SetText(light.name or "")
    spot:SetScale(scale)
    spot:SetFrameLevel(level)
    spot:ClearAllPoints()
    spot:SetPoint("CENTER", view.canvas, "TOPLEFT",
        light.x / 100 * view.width / scale, -light.y / 100 * view.height / scale)
    self:Animate(spot)
    spot:Show()
end

--- Whether the game's own pin is still on the map. A client that won't say
--- keeps the marker. Asked only for a marker that came with a game pin.
function SpotMarker.PinStillSet()
    local map = _G.C_Map
    if type(map) ~= "table" or type(map.HasUserWaypoint) ~= "function" then return true end
    local ok, has = pcall(map.HasUserWaypoint)
    if not ok then return true end
    return has == true
end

--- True when the player stands on the marker's spot, by the arrow it came
--- with (within its ARRIVED yards).
function SpotMarker.Reached(light)
    local arrow = light and light.arrow
    if not (type(arrow) == "table" and arrow.Here and arrow.Offset and arrow.Measure) then return false end
    local ok, reached = pcall(function()
        local here = arrow:Here()
        if not here then return false end
        light.target = light.target or {}
        local north, west = arrow.Offset(here, light.map, light.x / 100, light.y / 100, light.target)
        if not north then return false end
        local yards = arrow.Measure(north, west)
        return yards <= (arrow.ARRIVED or arrow.ARRIVED_NODE or 15)
    end)
    return ok and reached or false
end

--- Is the marker done with? One that came with the game's pin goes with
--- it. One without looks about once a second whether you stand on it. A
--- zone-only marker stays.
function SpotMarker:Done(elapsed)
    local light = self.current
    if not light then return false end
    if light.gamePin then return not SpotMarker.PinStillSet() end
    if light.area then return false end
    self.arriveSince = (self.arriveSince or 0) + (elapsed or 0)
    if self.arriveSince < SpotMarker.ARRIVE_LOOK then return false end
    self.arriveSince = 0
    return SpotMarker.Reached(light)
end

function SpotMarker:Step(elapsed)
    self.since = (self.since or 0) + (elapsed or 0)
    if self.since < self.STEP then return end
    local spent = self.since
    self.since = 0
    if self:Done(spent) then
        self:Clear()
        return
    end
    local ok, err = pcall(self.Draw, self)
    if not ok and ns.Debug then ns.Debug("spot marker:", tostring(err)) end
end

--- The driver runs only while a marker is set.
function SpotMarker:Wake()
    if not self.driver then
        local driver = CreateFrame("Frame", nil, UIParent)
        driver:SetScript("OnUpdate", function(_, elapsed) SpotMarker:Step(elapsed) end)
        self.driver = driver
    end
    self.since = self.STEP
    self.driver:Show()
end
