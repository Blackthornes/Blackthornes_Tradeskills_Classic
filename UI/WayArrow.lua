-- Blackthornes Tradeskills -- UI/WayArrow.lua
-- The arrow's dial for Show the way (2026-10-22), Farmer's, Equipment's
-- and Pets' arrow brought over: a gold ring with corner gems and a glowing
-- arrow that turns as you turn. Logic/WayArrow.lua works out where and how
-- far; this file only draws it. The art is Media/Arrow/*.tga, drawn by
-- tools/make_arrow_art.py.
--
-- The place sits on a plate across the top of the ring, the distance under
-- it, then the zone. Drag to move. Once you are there the arrow gives way
-- to a green check. Shown only while Show the way has aimed it, put away
-- with its red gem, and hidden inside dungeons.

local ADDON, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local ArrowUI = ns.NewModule("WayArrowUI")

local Theme = ns.Theme

local MEDIA = ([[Interface\AddOns\%s\Media\]]):format(ADDON)
ArrowUI.RING = MEDIA .. [[Arrow\Ring]]
ArrowUI.ARROW = MEDIA .. [[Arrow\Blade]]
ArrowUI.ARROW_GLOW = MEDIA .. [[Arrow\BladeGlow]]
ArrowUI.GLOW = MEDIA .. [[Frame\Glow]]
local CHECK = [[Interface\RaidFrame\ReadyCheck-Ready]]

local RING = 84
-- The dial lies back like a compass on the ground, so the blade cannot be
-- turned flat: tools/make_arrow_art.py draws it at TURNS headings, COLUMNS
-- a row, and the frame nearest the way to go is shown.
local TURNS = 64
local COLUMNS = 8
local PLATE_HEIGHT = 20
local MIN_WIDTH = 150
local MAX_WIDTH = 320
-- The room the arrow leaves under Farmer's XP bar.
local CLEAR_GAP = 4
-- How big the whole arrow is drawn, in percent (Settings, "Arrow Size:").
-- Classic's arrow stood at 65% before the choice came (the owner,
-- 2026-10-24: it stood too large), so 65 is the usual size here.
ArrowUI.SIZES = { 50, 65, 100 }
ArrowUI.USUAL = 65

-- Redrawn this often, seconds: smooth to the eye, cheap to run.
local STEP = 0.03

local function Clock()
    if type(GetTime) ~= "function" then return 0 end
    local ok, now = pcall(GetTime)
    return ok and tonumber(now) or 0
end

-- Gold while it points the way, green once you are there, pale blue when it
-- cannot point (far away, no position).
local TINTS = {
    point = { 1.00, 0.82, 0.32 },
    arrived = { 0.31, 0.95, 0.55 },
    rest = { 0.55, 0.65, 1.00 },
}

--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------

--- The frame of the art drawn nearest `turn` (radians, anticlockwise from
--- straight ahead): 0 to TURNS - 1.
function ArrowUI.FrameFor(turn)
    return math.floor(turn / (2 * math.pi) * TURNS + 0.5) % TURNS
end

--- Show frame `index` of a sheet laid out COLUMNS a row.
local function ShowFrame(texture, index)
    local column = index % COLUMNS
    local row = math.floor(index / COLUMNS)
    local rows = TURNS / COLUMNS
    pcall(texture.SetTexCoord, texture,
        column / COLUMNS, (column + 1) / COLUMNS, row / rows, (row + 1) / rows)
end

local function Additive(texture)
    pcall(texture.SetBlendMode, texture, "ADD")
    return texture
end

function ArrowUI:Build()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", "BlackthornesTSWayArrow", UIParent)
    frame:SetSize(MIN_WIDTH, RING + PLATE_HEIGHT + 56)
    pcall(frame.SetScale, frame, ArrowUI.Scale())
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")

    -- The dial: a breathing glow behind the ring, the ring, then the arrow
    -- with its own glow.
    local dial = CreateFrame("Frame", nil, frame)
    dial:SetSize(RING, RING)
    dial:SetPoint("TOP", frame, "TOP", 0, -(PLATE_HEIGHT / 2 + 2))
    self.dial = dial

    local halo = Additive(dial:CreateTexture(nil, "BACKGROUND"))
    halo:SetTexture(ArrowUI.GLOW)
    halo:SetSize(RING * 1.6, RING * 1.6)
    halo:SetPoint("CENTER")
    self.halo = halo

    local ring = dial:CreateTexture(nil, "ARTWORK")
    ring:SetTexture(ArrowUI.RING)
    ring:SetAllPoints(dial)
    self.ring = ring

    -- The blade and its glow fill the dial: each frame of the art covers
    -- exactly the ring's square.
    local arrow = dial:CreateTexture(nil, "OVERLAY", nil, 1)
    arrow:SetTexture(ArrowUI.ARROW)
    arrow:SetAllPoints(dial)
    self.arrow = arrow

    local arrowGlow = Additive(dial:CreateTexture(nil, "OVERLAY", nil, 2))
    arrowGlow:SetTexture(ArrowUI.ARROW_GLOW)
    arrowGlow:SetAllPoints(dial)
    self.arrowGlow = arrowGlow
    ShowFrame(arrow, 0)
    ShowFrame(arrowGlow, 0)
    self.shownFrame = 0

    local check = dial:CreateTexture(nil, "OVERLAY", nil, 3)
    check:SetTexture(CHECK)
    check:SetSize(34, 34)
    check:SetPoint("CENTER")
    check:Hide()
    self.check = check

    local mark = Theme.CreateLabel(dial, "title", "accentHi", "CENTER")
    pcall(mark.SetFont, mark, Theme.FONT, 26, "OUTLINE")
    mark:SetPoint("CENTER", 0, 1)
    mark:SetText("?")
    mark:Hide()
    self.mark = mark

    -- The plate across the ring's top: the place.
    local plate = CreateFrame("Frame", nil, frame)
    plate:SetHeight(PLATE_HEIGHT)
    plate:SetPoint("TOP", frame, "TOP", 0, 0)
    plate:SetFrameLevel(dial:GetFrameLevel() + 5)
    Theme.Fill(plate, "ink", 0.96)
    Theme.Border(plate, "accentHi")
    Theme.Halo(plate, 5, 0.18)
    self.plate = plate

    -- The house close gem, just past the plate's right end, clear of the
    -- place's name: puts it away.
    if ns.Titanforged and ns.Titanforged.CloseGem then
        local close = ns.Titanforged.CloseGem(frame, function() ArrowUI:Close() end)
        close:SetSize(18, 18)
        close:ClearAllPoints()
        close:SetPoint("LEFT", plate, "RIGHT", 4, 0)
        close:SetFrameLevel(plate:GetFrameLevel() + 1)
        self.close = close
    end

    local title = Theme.CreateLabel(plate, "normal", "gilt", "CENTER")
    title:SetPoint("CENTER", 0, 0)
    self.title = title

    -- Under the ring: how far, where, and where the spot comes from.
    local distance = Theme.CreateLabel(frame, "large", "text", "CENTER")
    pcall(distance.SetFont, distance, Theme.FONT, 14, "OUTLINE")
    distance:SetPoint("TOP", dial, "BOTTOM", 0, -4)
    self.distance = distance

    local place = Theme.CreateLabel(frame, "small", "muted", "CENTER")
    pcall(place.SetFont, place, Theme.FONT, Theme.sizes.small, "OUTLINE")
    place:SetPoint("TOP", distance, "BOTTOM", 0, -3)
    self.place = place

    local note = Theme.CreateLabel(frame, "tiny", "good", "CENTER")
    pcall(note.SetFont, note, Theme.FONT, Theme.sizes.small, "OUTLINE")
    note:SetPoint("TOP", place, "BOTTOM", 0, -2)
    self.note = note

    frame:SetScript("OnDragStart", function(self)
        ArrowUI.dragging = true
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        ArrowUI:SavePosition()
        ArrowUI:AvoidXPBar()
        ArrowUI.dragging = nil
    end)
    frame:SetScript("OnUpdate", function(_, elapsed) ArrowUI:Step(elapsed) end)

    self.frame = frame
    self:RestorePosition()
    frame:Hide()
    return frame
end

--------------------------------------------------------------------------------
-- The close gem
--------------------------------------------------------------------------------

--- The close gem: the arrow put away until Show the way aims it again.
function ArrowUI:Close()
    ns.WayArrow:Clear()
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- One arrow at a time
--
-- Farmer, Equipment, Pets, Butler and Tradeskills each have an arrow,
-- and the owner asked (2026-10-08) that only one be up at a time. They agree through one
-- global table, BlackthornesArrows, made by whichever loads first:
--   wants[addon]   true while that addon's arrow has something to show
--   claims[addon]  when the player last turned it on or aimed it (GetTime)
-- Of those wanting to show, the one with the latest claim is drawn; the
-- others wait hidden and come back once it is turned off or has nothing to
-- show. An addon on its own always wins. The same lines are in every addon
-- with an arrow; a change to them belongs in all of them.
--------------------------------------------------------------------------------

local ME = "Tradeskills"

local function Shared()
    local shared = rawget(_G, "BlackthornesArrows")
    if type(shared) ~= "table" then
        shared = {}
        _G.BlackthornesArrows = shared
    end
    if type(shared.wants) ~= "table" then shared.wants = {} end
    if type(shared.claims) ~= "table" then shared.claims = {} end
    return shared
end

--- This arrow was turned on or aimed: it goes on top.
function ArrowUI:Claim()
    Shared().claims[ME] = Clock()
end

--- Say whether this arrow wants to show; true when it is the one shown.
function ArrowUI.Wins(wants)
    local shared = Shared()
    shared.wants[ME] = wants and true or nil
    if not wants then return false end
    local best, bestAt
    for name, wanting in pairs(shared.wants) do
        local at = tonumber(shared.claims[name]) or 0
        if wanting and (not best or at > bestAt or (at == bestAt and tostring(name) < best)) then
            best, bestAt = tostring(name), at
        end
    end
    return best == ME
end

--- The words for a state with nothing to point at.
function ArrowUI.Words(state)
    local mode = state.mode
    if mode == "blind" then
        return L["Can't see you here"], L["The game won't say where you are"], "", "muted"
    end
    return state.distance or "", state.place or "", state.note or "", state.noteColor or "muted"
end

--- How wide a label's words are: by size and text, or by the label, as the
--- addon's Theme measures.
local function Width(size, label)
    local ok, width = pcall(Theme.TextWidth, size, label:GetText())
    if not (ok and type(width) == "number" and width > 0) then
        ok, width = pcall(Theme.TextWidth, label)
    end
    return ok and tonumber(width) or 0
end
ArrowUI.Width = Width

--- Lay the labels out and size the frame to the widest, measured.
function ArrowUI:Fit()
    local widest = Width("normal", self.title) + 28
    self.plate:SetWidth(math.max(RING + 16, widest))

    for _, entry in ipairs({ { "large", self.distance }, { "small", self.place }, { "small", self.note } }) do
        widest = math.max(widest, Width(entry[1], entry[2]) + 16)
    end

    local width = math.min(MAX_WIDTH, math.max(MIN_WIDTH, math.ceil(widest)))
    self.frame:SetWidth(width)
    -- Wrapped rather than cut off when a long place name runs past the most.
    for _, label in ipairs({ self.distance, self.place, self.note }) do
        label:SetWidth(width - 8)
        label:SetWordWrap(true)
    end
end

--- Draw the state now. `force` relays the words even when they read the
--- same.
function ArrowUI:Draw(force)
    local frame = self.frame
    if not frame then return end

    local state = ns.WayArrow:State(Clock())
    self.state = state

    -- Nothing aimed at: out of the way until Show the way is clicked.
    if state.mode == "off" or state.mode == "inside" then
        ArrowUI.Wins(false)
        ns.TomTom:Clear()
        if ns.TravelCard then ns.TravelCard:Hide() end
        frame:Hide()
        return
    end

    -- Another Blackthornes arrow was aimed more lately: wait, hidden.
    if not ArrowUI.Wins(true) then
        ns.TomTom:Clear()
        if ns.TravelCard then ns.TravelCard:Hide() end
        frame:Hide()
        return
    end

    -- The steps of a trip, beside the dial or TomTom's arrow alike.
    if ns.TravelCard then ns.TravelCard:Update(state) end

    -- TomTom installed and used: its arrow shows the way, so the dial hides
    -- and only one arrow is on screen. The driver below keeps it current.
    if ns.TomTom:Take(state) then
        frame:Hide()
        return
    end

    -- The plate carries the place or nothing: never a name for the dial.
    local title = state.name or ""
    self.plate:SetShown(title ~= "")
    local distance, place, note, noteColor = ArrowUI.Words(state)

    -- Joined by hand: a table here was one more for the collector 33 times
    -- a second.
    local key = title .. "\n" .. distance .. "\n" .. place .. "\n" .. note .. "\n" .. noteColor
    if force or key ~= self.drawnKey then
        self.drawnKey = key
        self.title:SetText(title)
        self.distance:SetText(distance)
        self.place:SetText(place)
        self.note:SetText(note)
        self.note:SetTextColor(Theme.Unpack(noteColor))
        self.distance:SetTextColor(Theme.Unpack(state.mode == "arrived" and "good" or "text"))
        self:Fit()
    end

    local pointing = state.mode == "point"
    local arrived = state.mode == "arrived"
    self.arrow:SetShown(pointing)
    self.arrowGlow:SetShown(pointing)
    self.check:SetShown(arrived)
    self.mark:SetShown(not pointing and not arrived)

    local tint = pointing and TINTS.point or arrived and TINTS.arrived or TINTS.rest
    -- The blade carries its own gold and light; only its glow is tinted.
    self.arrow:SetVertexColor(1, 1, 1)
    self.arrowGlow:SetVertexColor(tint[1], tint[2], tint[3])
    self.halo:SetVertexColor(tint[1], tint[2], tint[3])
    self.mark:SetTextColor(tint[1], tint[2], tint[3])

    if pointing and state.turn then
        self:Turn(state.turn)
    end

    if not frame:IsShown() then self:AvoidXPBar() end
    frame:Show()
end

--- Turn the arrow toward `turn` (radians, anticlockwise). Eased on Full so
--- it swings rather than snaps; straight there otherwise. Only a new frame
--- touches the textures.
function ArrowUI:Turn(turn)
    local shown = self.shownTurn
    if shown and ns.Motion.Level() == "full" then
        local gap = turn - shown
        while gap > math.pi do gap = gap - 2 * math.pi end
        while gap < -math.pi do gap = gap + 2 * math.pi end
        turn = shown + gap * 0.35
    end
    self.shownTurn = turn
    local index = ArrowUI.FrameFor(turn)
    if index == self.shownFrame then return end
    self.shownFrame = index
    ShowFrame(self.arrow, index)
    ShowFrame(self.arrowGlow, index)
end

--- The glow: breathing on Full, still otherwise, brighter once you are there.
function ArrowUI:Breathe(now)
    local level = ns.Motion.Level()
    local arrived = self.state and self.state.mode == "arrived"
    local rest = arrived and 0.55 or 0.32
    local alpha = rest
    if level == "full" then
        local speed = arrived and 5 or 2.2
        alpha = rest + 0.16 * math.sin(now * speed)
    elseif level == "off" then
        alpha = rest * 0.6
    end
    self.halo:SetAlpha(alpha)
    self.arrowGlow:SetAlpha(math.min(1, alpha + 0.25))
end

function ArrowUI:Step(elapsed)
    self.since = (self.since or 0) + (elapsed or 0)
    if self.since < STEP then return end
    self.since = 0

    local ok, err = pcall(self.Draw, self)
    if not ok then ns.Debug("way arrow:", tostring(err)) end
    if self.frame:IsShown() then pcall(self.Breathe, self, Clock()) end
end

--- Show or hide it as the place aimed at says. The dial keeps itself
--- current while shown; a hidden dial is woken by its driver below.
function ArrowUI:Refresh()
    if not ns.db then return end
    if not ns.WayArrow.IsOn() then
        -- Nothing to wake while nothing is aimed at: the driver rests.
        if self.driver then self.driver:Hide() end
        ArrowUI.Wins(false)
        ns.TomTom:Clear()
        if self.frame then self.frame:Hide() end
        return
    end
    if self.driver then self.driver:Show() end
    self:Build()
    local ok, err = pcall(self.Draw, self, true)
    if not ok then ns.Debug("way arrow:", tostring(err)) end
end

--------------------------------------------------------------------------------
-- Position
--------------------------------------------------------------------------------

--- The arrow's size as a scale: the percent picked under "Arrow Size:"
--- (`wayArrowSize`, account wide, nil for the usual 65), else the usual.
function ArrowUI.Scale()
    local percent = tonumber(type(ns.db) == "table" and ns.db.wayArrowSize)
    for _, size in ipairs(ArrowUI.SIZES) do
        if percent == size then return size / 100 end
    end
    return ArrowUI.USUAL / 100
end

--- The size picked, in percent.
function ArrowUI.Size()
    return math.floor(ArrowUI.Scale() * 100 + 0.5)
end

--- Draws the whole arrow, plate and words too, at `percent` (50, 65 or
--- 100). 65 saves nothing, so nobody's save changes until a smaller size
--- is picked. The arrow stays where it was left.
function ArrowUI:SetSize(percent)
    percent = tonumber(percent)
    local known = false
    for _, size in ipairs(ArrowUI.SIZES) do
        if percent == size then known = true end
    end
    if not known or type(ns.db) ~= "table" then return end
    ns.db.wayArrowSize = percent ~= ArrowUI.USUAL and percent or nil
    local frame = self.frame
    if not frame then return end
    pcall(frame.SetScale, frame, ArrowUI.Scale())
    self:RestorePosition()
end

function ArrowUI:SavePosition()
    local frame = self.frame
    local ok, x, y = pcall(function() return frame:GetCenter() end)
    if not (ok and type(x) == "number" and type(y) == "number") then return end

    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
    -- Kept in the screen's own units, so a new size keeps the spot.
    local scale = ArrowUI.Scale()
    ns.db.wayArrowX, ns.db.wayArrowY = x * scale, y * scale
end

--- Farmer's XP bar can come up after the arrow, so the arrow listens for
--- it rather than looking on a timer: the bar's own show and size change,
--- and, while the bar is not built yet, Farmer building it.
function ArrowUI:WatchXPBar()
    if self.watchingBar then return end
    pcall(function()
        local farmer = _G.BlackthornesFarmer
        local xp = farmer and farmer.XPBarUI
        if not xp then return end
        self.watchingBar = true
        local function Watch()
            local bar = xp.frame
            if bar and ArrowUI.watchedBar ~= bar then
                ArrowUI.watchedBar = bar
                local function Check() ArrowUI:AvoidXPBar() end
                bar:HookScript("OnShow", Check)
                bar:HookScript("OnSizeChanged", Check)
                -- The bar gone (the level cap, or turned off): back to the
                -- saved spot, which AvoidXPBar never changed.
                bar:HookScript("OnHide", function() ArrowUI:RestorePosition() end)
            end
            if bar then ArrowUI:AvoidXPBar() end
        end
        if xp.frame then
            Watch()
        elseif hooksecurefunc and type(xp.Build) == "function" then
            hooksecurefunc(xp, "Build", function() pcall(Watch) end)
        end
    end)
end

--- With Farmer's XP bar showing, an arrow that overlaps it sits just below
--- it: the whole arrow, the plate and its close gem too. The saved spot is
--- never changed, so it goes back when the bar is gone.
function ArrowUI:AvoidXPBar()
    local frame = self.frame
    if not frame then return end
    self:WatchXPBar()
    pcall(function()
        local farmer = _G.BlackthornesFarmer
        local bar = farmer and farmer.XPBarUI and farmer.XPBarUI.frame
        if not (bar and bar:IsShown()) then return end
        -- Each rect in screen units, since the arrow is drawn smaller than
        -- the bar.
        local function Rect(part)
            local x, y, w, h = part:GetRect()
            if not x then return end
            local s = part:GetEffectiveScale() or 1
            return x * s, y * s, w * s, h * s
        end
        local barLeft, barBottom, barWidth, barHeight = Rect(bar)
        if not barLeft then return end
        local left, bottom, right, top
        for _, part in ipairs({ frame, self.plate, self.close }) do
            local x, y, w, h = Rect(part)
            if x and (part == frame or part:IsShown()) then
                left = math.min(left or x, x)
                bottom = math.min(bottom or y, y)
                right = math.max(right or x + w, x + w)
                top = math.max(top or y + h, y + h)
            end
        end
        if not left then return end
        local gap = CLEAR_GAP
        if left < barLeft + barWidth + gap and right > barLeft - gap
            and bottom < barBottom + barHeight + gap and top > barBottom - gap then
            frame:ClearAllPoints()
            frame:SetPoint("TOP", bar, "BOTTOM", 0, -(gap + 2) / ArrowUI.Scale())
        end
    end)
end

function ArrowUI:RestorePosition()
    local frame = self.frame
    if not frame then return end
    frame:ClearAllPoints()
    if ns.db.wayArrowX and ns.db.wayArrowY then
        local scale = ArrowUI.Scale()
        frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", ns.db.wayArrowX / scale, ns.db.wayArrowY / scale)
    else
        -- Top middle, under where the game puts its own messages.
        frame:SetPoint("TOP", UIParent, "TOP", 0, -140 / ArrowUI.Scale())
    end
    self:AvoidXPBar()
end

function ArrowUI:ResetPosition()
    ns.db.wayArrowX, ns.db.wayArrowY = nil, nil
    self:RestorePosition()
end

--------------------------------------------------------------------------------
-- Keeping up
--------------------------------------------------------------------------------

function ArrowUI:OnEnable()
    -- The dial's own OnUpdate stops while it is hidden, so a small driver
    -- wakes it once a second: leaving a dungeon, say. It does nothing while
    -- the arrow has no place.
    local driver = CreateFrame("Frame", nil, UIParent)
    driver.since = 0
    driver:SetScript("OnUpdate", function(selfDriver, elapsed)
        selfDriver.since = selfDriver.since + (elapsed or 0)
        if selfDriver.since < 1 then return end
        selfDriver.since = 0
        if ns.WayArrow.IsOn() and not (ArrowUI.frame and ArrowUI.frame:IsShown()) then
            ArrowUI:Refresh()
        end
    end)
    driver:Show()
    self.driver = driver

    self:Refresh()
    ns.RegisterEvent(self, "PLAYER_ENTERING_WORLD", function() ArrowUI:Refresh() end)
end
