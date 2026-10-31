-- Blackthornes Tradeskills -- UI/VendorPins.lua
-- Gold pins on the world map at vendors that sell what the queue needs for
-- less than the auction house (Logic/VendorPins.lua works out which).
--
-- A player asked, the owner said build it (2026-10-18, from a mockup). Only
-- on the world map, for the map it shows. A pin is our own frame on the
-- map's canvas in the house look (the owner said build it, 2026-10-19, from
-- a mockup): a gold rim round a bag, a gold gem on top, a glow that
-- breathes, how many queue items it has on a gold badge, the vendor's name
-- under it on a zoomed-in map or one with few pins, the vendors that save
-- less a size smaller, and a beam of light under the one a click pinned.
-- Hovering it opens our own card (gold rim, dark glass rows, coin colours)
-- naming the vendor, what it has for the queue and what buying there
-- saves; a click puts the game's map pin on it, or TomTom's
-- arrow when TomTom is installed (the map pin when TomTom says no), says
-- so in chat, and the pins sit under the game's own. Butler's Buy from a
-- vendor row and the vendor window still do the buying.
--
-- Smooth play: a driver looks four times a second, and only while the map
-- shows does it do more than one check. The pins are laid out again only
-- when the map, its zoom, the queue, the bags, the prices or a learned
-- vendor moved (a key), reusing the same frames. Nothing Blizzard's is
-- hidden, shown or written on: the pins are children of the map's canvas.

local ADDON, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Util = ns.Util

local VendorPinsUI = {}
ns.VendorPinsUI = VendorPinsUI

-- How often the driver looks, in seconds.
VendorPinsUI.LOOK = 0.25
-- The pin's size on screen, at any zoom.
VendorPinsUI.SIZE = 36
-- The pins that save less are this much smaller.
VendorPinsUI.SMALL = 0.82
-- With this many pins or fewer, names show under them at any zoom.
VendorPinsUI.NAMES_MOST = 4
-- Levels over the map's art and the parts explored.
VendorPinsUI.ABOVE = 5

local ROUND = [[Interface\CharacterFrame\TempPortraitAlphaMask]]
local BAG = [[Interface\Icons\INV_Misc_Bag_10]]
local GLOW = ([[Interface\AddOns\%s\Media\Frame\Glow.tga]]):format(ADDON)
local GEM = ([[Interface\AddOns\%s\Media\Frame\GoldGem.tga]]):format(ADDON)

local function Number(value)
    local ok, copy = pcall(function() return tonumber(value) end)
    return ok and copy or nil
end

--- The world map's canvas, the map it shows, and how far it is zoomed.
function VendorPinsUI.WorldView()
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
    width = okW and Number(width) or nil
    height = okH and Number(height) or nil
    if not (width and height and width > 0 and height > 0) then return nil end

    local zoomedIn = false
    if type(scroll) == "table" and type(scroll.IsZoomedIn) == "function" then
        local ok, value = pcall(scroll.IsZoomedIn, scroll)
        zoomedIn = ok and value == true
    end

    return { canvas = canvas, mapID = mapID, scale = scale, width = width, height = height,
        zoomedIn = zoomedIn }
end

--- The frame level the pins count up from: the canvas's own, or, on a zone
--- map, the parts you have explored, which the game lays over the map's art
--- as pins of their own (Farmer's MapMarkers.BaseLevel: a glow at the
--- canvas's level was drawn under them).
function VendorPinsUI.BaseLevel(canvas)
    local okLevel, level = pcall(canvas.GetFrameLevel, canvas)
    level = okLevel and Number(level) or 1
    local map = _G.WorldMapFrame
    if type(map) ~= "table" then return level end

    local top
    if type(map.EnumeratePinsByTemplate) == "function" then
        local ok, step, state, key = pcall(map.EnumeratePinsByTemplate, map, "MapExplorationPinTemplate")
        if ok and type(step) == "function" then
            for _ = 1, 64 do
                local okNext, nextKey, value = pcall(step, state, key)
                if not okNext or nextKey == nil then break end
                key = nextKey
                local pin = type(nextKey) == "table" and nextKey or value
                if type(pin) == "table" and type(pin.GetFrameLevel) == "function" then
                    local okPin, pinLevel = pcall(pin.GetFrameLevel, pin)
                    pinLevel = okPin and Number(pinLevel)
                    if pinLevel and (not top or pinLevel > top) then top = pinLevel end
                end
            end
        end
    end
    if not top and type(map.GetPinFrameLevelsManager) == "function" then
        local ok, manager = pcall(map.GetPinFrameLevelsManager, map)
        if ok and type(manager) == "table" and type(manager.GetValidFrameLevel) == "function" then
            local okKept, kept = pcall(manager.GetValidFrameLevel, manager, "PIN_FRAME_LEVEL_MAP_EXPLORATION")
            top = okKept and Number(kept) or nil
        end
    end
    if top and top > level then return top end
    return level
end

--- The level of the game's own map pin (the one a click sets), so ours sit
--- under it: drawn over it, ours hid the very pin the click put there.
function VendorPinsUI.WaypointLevel()
    local map = _G.WorldMapFrame
    if type(map) ~= "table" then return nil end
    local level
    if type(map.EnumeratePinsByTemplate) == "function" then
        local ok, step, state, key = pcall(map.EnumeratePinsByTemplate, map, "WaypointLocationPinTemplate")
        if ok and type(step) == "function" then
            for _ = 1, 8 do
                local okNext, nextKey, value = pcall(step, state, key)
                if not okNext or nextKey == nil then break end
                key = nextKey
                local pin = type(nextKey) == "table" and nextKey or value
                if type(pin) == "table" and type(pin.GetFrameLevel) == "function" then
                    local okPin, pinLevel = pcall(pin.GetFrameLevel, pin)
                    pinLevel = okPin and Number(pinLevel)
                    if pinLevel and (not level or pinLevel < level) then level = pinLevel end
                end
            end
        end
    end
    if not level and type(map.GetPinFrameLevelsManager) == "function" then
        local ok, manager = pcall(map.GetPinFrameLevelsManager, map)
        if ok and type(manager) == "table" and type(manager.GetValidFrameLevel) == "function" then
            local okKept, kept = pcall(manager.GetValidFrameLevel, manager, "PIN_FRAME_LEVEL_WAYPOINT_LOCATION")
            level = okKept and Number(kept) or nil
        end
    end
    return level
end

--- The level our pins take: over the map's art and the parts explored,
--- under the game's map pin when there is room between them.
function VendorPinsUI.PinLevel(canvas)
    local base = VendorPinsUI.BaseLevel(canvas)
    local level = base + VendorPinsUI.ABOVE
    local waypoint = VendorPinsUI.WaypointLevel()
    if waypoint and waypoint <= level and waypoint - 1 > base then level = waypoint - 1 end
    return level
end

--------------------------------------------------------------------------------
-- The pin and its hover card
--------------------------------------------------------------------------------

--- What the pin's hover says, as lines: { left, right, color }, an item's
--- line also carrying its itemID and count for the card's icon and colour.
function VendorPinsUI.TooltipLines(vendor, hasTomTom)
    local lines = { { vendor.name or "?", nil, "white" } }
    lines[#lines + 1] = { L["Has what your queue needs:"], nil, "gold" }
    for _, item in ipairs(vendor.items or {}) do
        lines[#lines + 1] = { Util.GetItemLabel(item.itemID) .. " x" .. item.count,
            Util.FormatMoney(item.cost), "white", itemID = item.itemID, count = item.count }
    end
    if (vendor.saving or 0) > 0 then
        lines[#lines + 1] = { L.Format("Saves you %s over the auction house.", Util.FormatMoney(vendor.saving)),
            nil, "green" }
    end
    -- A click aims the arrow (Logic/WayArrow.lua), which hands off to
    -- TomTom's when "Use TomTom:" is ticked.
    local hint = L["Click to set a map pin."]
    local tomtomOn = not (ns.TomTom and ns.TomTom.IsOn) or ns.TomTom.IsOn()
    if hasTomTom and tomtomOn then
        hint = L["Click for a TomTom arrow."]
    elseif ns.WayArrow and ns.WayArrow.AimAt then
        hint = L["Click for an arrow."]
    end
    lines[#lines + 1] = { hint, nil, "blue" }
    return lines
end

--- How each pin looks, in the order For gave them (the biggest saving
--- first): the ones that save less are a size smaller, the one a click
--- pinned is lit, and names show under the pins only on a zoomed-in map
--- or one with few pins, so they never pile up.
function VendorPinsUI.Looks(vendors, pinned, zoomedIn)
    local looks = {}
    local top = vendors[1] and (vendors[1].saving or 0) or 0
    local names = zoomedIn == true or #vendors <= VendorPinsUI.NAMES_MOST
    for index, vendor in ipairs(vendors) do
        looks[index] = {
            small = (vendor.saving or 0) < top,
            pinned = pinned ~= nil and vendor.npcID == pinned,
            name = names,
            count = #(vendor.items or {}),
        }
    end
    return looks
end

local COLORS = {
    white = { 0.945, 0.831, 0.533 },
    gold = { 0.784, 0.643, 0.302 },
    green = { 0.310, 0.820, 0.545 },
    blue = { 0.28, 0.71, 1 },
}

local CARD_PAD = 10
local CARD_ROW = 22
local CARD_ICON = 18

local function CardRow(card, index)
    local row = card.rows[index]
    if row then return row end
    row = CreateFrame("Frame", nil, card)
    row:SetHeight(CARD_ROW)
    row.band = row:CreateTexture(nil, "BACKGROUND")
    row.band:SetAllPoints(row)
    row.line = row:CreateTexture(nil, "BORDER")
    row.line:SetPoint("BOTTOMLEFT", 0, 0)
    row.line:SetPoint("BOTTOMRIGHT", 0, 0)
    row.line:SetHeight(1)
    row.line:SetColorTexture(Theme.Unpack("border", 0.6))
    row.icon = Theme.CreateItemIcon(row, CARD_ICON)
    row.icon:SetPoint("LEFT", 6, 0)
    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.cost = Theme.CreateLabel(row, "small", "text", "RIGHT")
    row.cost:SetPoint("RIGHT", -8, 0)
    card.rows[index] = row
    return row
end

local function Corner(card, point, x, y)
    local gem = card:CreateTexture(nil, "OVERLAY")
    gem:SetSize(10, 10)
    gem:SetTexture(GEM)
    gem:SetPoint("CENTER", card, point, x, y)
    return gem
end

local function Card()
    local card = VendorPinsUI.card
    if card then return card end
    card = CreateFrame("Frame", nil, _G.UIParent)
    card:SetFrameStrata("TOOLTIP")
    pcall(card.SetClampedToScreen, card, true)
    Theme.Fill(card, "well", 0.96)
    Theme.Border(card, "accent")
    local sheen = card:CreateTexture(nil, "BACKGROUND", nil, 1)
    sheen:SetPoint("TOPLEFT", 1, -1)
    sheen:SetPoint("TOPRIGHT", -1, -1)
    sheen:SetHeight(28)
    if not Theme.SetGradientAlpha(sheen, "VERTICAL", "accent", 0, 0.14) then sheen:Hide() end
    Corner(card, "TOPLEFT", 1, -1)
    Corner(card, "TOPRIGHT", -1, -1)
    Corner(card, "BOTTOMLEFT", 1, 1)
    Corner(card, "BOTTOMRIGHT", -1, 1)
    card.head = Theme.CreateLabel(card, "large", "accentHi")
    card.lead = Theme.CreateLabel(card, "small", "accent")
    card.save = Theme.CreateLabel(card, "small", "profit")
    card.hint = Theme.CreateLabel(card, "small", "text")
    card.hint:SetTextColor(unpack(COLORS.blue))
    card.rows = {}
    card:Hide()
    VendorPinsUI.card = card
    return card
end

local function Width(label)
    return Theme.TextWidth(label) or 0
end

--- The hover card beside a pin: the vendor in gold, then each material on
--- a dark glass row with its icon, its name in its rarity colour and its
--- cost in coin colours, what buying there saves, and what a click does.
function VendorPinsUI:ShowCard(pin)
    local vendor = pin.vendor
    if not vendor then return end
    local hasTomTom = ns.Waypoints and ns.Waypoints:HasTomTom() or false
    local card = Card()

    local items, save, hint = {}, nil, nil
    local lines = VendorPinsUI.TooltipLines(vendor, hasTomTom)
    for index = 3, #lines do
        local line = lines[index]
        if line.itemID then
            items[#items + 1] = line
        elseif line[3] == "green" then
            save = line[1]
        else
            hint = line[1]
        end
    end

    card.head:SetText(lines[1][1])
    card.lead:SetText(lines[2][1])
    local width = math.max(Width(card.head), Width(card.lead))

    for index, line in ipairs(items) do
        local row = CardRow(card, index)
        Theme.SetItemIcon(row.icon, line.itemID)
        -- How many sits on the icon's corner, as in the bags (UI/ItemLook.lua).
        if ns.ItemLook then
            ns.ItemLook.SetCount(row.icon, line.count)
            row.name:SetText(Util.GetItemName(line.itemID))
        else
            row.name:SetText(Util.GetItemName(line.itemID) .. " x" .. line.count)
        end
        Theme.SetItemNameColor(row.name, line.itemID)
        row.cost:SetText(line[2] or "")
        row.band:SetColorTexture(Theme.Unpack(index % 2 == 1 and "glass" or "glassAlt"))
        width = math.max(width, 6 + CARD_ICON + 6 + Width(row.name) + 18 + Width(row.cost) + 8)
    end
    for index = #items + 1, #card.rows do card.rows[index]:Hide() end

    card.save:SetText(save or "")
    card.save:SetShown(save ~= nil)
    card.hint:SetText(hint or "")
    width = math.max(width, save and Width(card.save) or 0, Width(card.hint))
    width = math.ceil(math.max(200, width))

    local y = -CARD_PAD
    card.head:ClearAllPoints()
    card.head:SetPoint("TOPLEFT", card, "TOPLEFT", CARD_PAD, y)
    y = y - (Theme.sizes.large or 14) - 6
    card.lead:ClearAllPoints()
    card.lead:SetPoint("TOPLEFT", card, "TOPLEFT", CARD_PAD, y)
    y = y - (Theme.sizes.small or 11) - 6
    for index = 1, #items do
        local row = card.rows[index]
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", card, "TOPLEFT", CARD_PAD, y)
        row:SetWidth(width)
        row:Show()
        y = y - CARD_ROW
    end
    y = y - 8
    if save then
        card.save:ClearAllPoints()
        card.save:SetPoint("TOPLEFT", card, "TOPLEFT", CARD_PAD, y)
        y = y - (Theme.sizes.small or 11) - 6
    end
    card.hint:ClearAllPoints()
    card.hint:SetPoint("TOPLEFT", card, "TOPLEFT", CARD_PAD, y)
    y = y - (Theme.sizes.small or 11) - CARD_PAD

    card:SetSize(width + CARD_PAD * 2, -y)
    card:ClearAllPoints()
    card:SetPoint("LEFT", pin, "RIGHT", 12, 0)
    card.pin = pin
    card:Show()
end

function VendorPinsUI:HideCard()
    if self.card then
        self.card:Hide()
        self.card.pin = nil
    end
end

local function Motion()
    local motion = ns.Motion
    return motion and motion.Level and motion.Level() or "full"
end

--- The glow's slow breath: one looping animation the game plays, so
--- nothing here runs a frame at a time.
local function Breath(texture)
    local ok, group = pcall(texture.CreateAnimationGroup, texture)
    if not ok or type(group) ~= "table" then return nil end
    pcall(group.SetLooping, group, "BOUNCE")
    local okAlpha, alpha = pcall(group.CreateAnimation, group, "Alpha")
    if okAlpha and type(alpha) == "table" then
        alpha:SetFromAlpha(0.45)
        alpha:SetToAlpha(1)
        alpha:SetDuration(1.3)
        alpha:SetSmoothing("IN_OUT")
    end
    local okScale, scale = pcall(group.CreateAnimation, group, "Scale")
    if okScale and type(scale) == "table" then
        pcall(scale.SetScaleFrom, scale, 0.92, 0.92)
        pcall(scale.SetScaleTo, scale, 1.08, 1.08)
        scale:SetDuration(1.3)
        scale:SetSmoothing("IN_OUT")
    end
    return group
end

--- Light a pin as it rests, as the one a click pinned, or under the mouse.
function VendorPinsUI.Light(pin)
    local lit = pin.hovered or pin.pinned
    pin.ring:SetVertexColor(Theme.Unpack(lit and "accentHi" or "accent"))
    pin.glow:SetVertexColor(Theme.Unpack(lit and "accentHi" or "accent"))
    pin.beam:SetShown(pin.pinned == true)
    local breathing = Motion() == "full" and not pin.hovered
    if pin.breath and breathing then
        pin.glow:SetAlpha(lit and 1 or 0.75)
        if not pin.breath:IsPlaying() then pcall(pin.breath.Play, pin.breath) end
    else
        if pin.breath then pcall(pin.breath.Stop, pin.breath) end
        pin.glow:SetAlpha(lit and 1 or 0.6)
    end
end

function VendorPinsUI.CreatePin(parent)
    local size = VendorPinsUI.SIZE
    local pin = CreateFrame("Frame", nil, parent)
    pin:SetSize(size, size)
    pin:EnableMouse(true)

    local beam = pin:CreateTexture(nil, "BACKGROUND", nil, -1)
    beam:SetPoint("BOTTOM", pin, "CENTER", 0, 0)
    beam:SetSize(7, size * 1.6)
    if not Theme.SetGradientAlpha(beam, "VERTICAL", "accentHi", 0.9, 0) then
        beam:SetColorTexture(Theme.Unpack("accentHi", 0.45))
    end
    beam:Hide()

    local glow = pin:CreateTexture(nil, "BACKGROUND")
    glow:SetPoint("CENTER")
    glow:SetSize(size * 2.2, size * 2.2)
    glow:SetTexture(GLOW)
    pcall(glow.SetBlendMode, glow, "ADD")

    local ring = pin:CreateTexture(nil, "BORDER")
    ring:SetAllPoints(pin)
    ring:SetTexture(ROUND)

    local face = pin:CreateTexture(nil, "ARTWORK", nil, -1)
    face:SetPoint("TOPLEFT", 3, -3)
    face:SetPoint("BOTTOMRIGHT", -3, 3)
    face:SetTexture(ROUND)
    face:SetVertexColor(Theme.Unpack("well"))

    local icon = pin:CreateTexture(nil, "ARTWORK", nil, 1)
    icon:SetPoint("TOPLEFT", 5, -5)
    icon:SetPoint("BOTTOMRIGHT", -5, 5)
    icon:SetTexture(BAG)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    pcall(icon.SetMask, icon, ROUND)

    local gem = pin:CreateTexture(nil, "OVERLAY")
    gem:SetSize(11, 11)
    gem:SetPoint("CENTER", pin, "TOP", 0, 0)
    gem:SetTexture(GEM)

    local badge = pin:CreateTexture(nil, "OVERLAY", nil, 1)
    badge:SetSize(15, 15)
    badge:SetPoint("CENTER", pin, "BOTTOMRIGHT", -3, 3)
    badge:SetTexture(ROUND)
    badge:SetVertexColor(Theme.Unpack("accentHi"))
    local count = pin:CreateFontString(nil, "OVERLAY")
    count:SetFont(Theme.FONT, 10, "")
    count:SetTextColor(Theme.Unpack("ink"))
    count:SetPoint("CENTER", badge, "CENTER", 0, 0)

    local name = pin:CreateFontString(nil, "OVERLAY")
    name:SetFont(Theme.FONT, Theme.sizes.small or 11, "OUTLINE")
    name:SetTextColor(Theme.Unpack("gilt"))
    pcall(name.SetShadowOffset, name, 1, -1)
    pcall(name.SetShadowColor, name, 0, 0, 0, 1)
    name:SetPoint("TOP", pin, "BOTTOM", 0, -3)

    pin.beam, pin.glow, pin.ring, pin.icon = beam, glow, ring, icon
    pin.badge, pin.count, pin.label = badge, count, name
    pin.breath = Breath(glow)

    pin:SetScript("OnEnter", function(self)
        self.hovered = true
        VendorPinsUI.Light(self)
        VendorPinsUI:ShowCard(self)
    end)
    pin:SetScript("OnLeave", function(self)
        self.hovered = false
        VendorPinsUI.Light(self)
        VendorPinsUI:HideCard()
    end)
    pin:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" or not self.vendor then return end
        if ns.VendorPins then ns.VendorPins:ShowTheWay(self.vendor) end
    end)
    return pin
end

--- Dress a pin for one vendor and its look.
function VendorPinsUI.Dress(pin, vendor, look)
    pin.vendor = vendor
    pin.pinned = look.pinned
    pin.count:SetText(look.count > 0 and tostring(look.count) or "")
    pin.badge:SetShown(look.count > 0)
    pin.count:SetShown(look.count > 0)
    pin.label:SetText(vendor.name or "")
    pin.label:SetShown(look.name and (vendor.name or "") ~= "")
    VendorPinsUI.Light(pin)
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

VendorPinsUI.pins = {}
VendorPinsUI.used = 0

--- The key that says the pins need laying out again.
function VendorPinsUI.KeyFor(view)
    local vp = ns.VendorPins
    return ("%d:%s:%s:%s:%s:%d:%d:%d:%d"):format(view.mapID, view.scale, view.width, view.height,
        tostring(view.zoomedIn),
        vp and vp.version or 0,
        ns.Queue and ns.Queue.version or 0,
        ns.Inventory and ns.Inventory.changes or 0,
        ns.Prices and ns.Prices.scanCount or 0)
end

local function PutAway(self)
    self:HideCard()
    for index = 1, #self.pins do self.pins[index]:Hide() end
    self.used = 0
end

function VendorPinsUI:Draw()
    local on = ns.VendorPins and ns.VendorPins:IsOn()
    local view = on and VendorPinsUI.WorldView() or nil
    if not view then
        if self.used > 0 then PutAway(self) end
        self.key = nil
        return
    end

    local key = VendorPinsUI.KeyFor(view)
    if key == self.key then return end
    self.key = key

    if self.canvas ~= view.canvas then
        PutAway(self)
        self.pins = {}
        self.canvas = view.canvas
    end

    local vendors = ns.VendorPins:For(view.mapID)
    local looks = VendorPinsUI.Looks(vendors, ns.VendorPins.pinned, view.zoomedIn)
    local level = VendorPinsUI.PinLevel(view.canvas)

    self.used = 0
    for index, vendor in ipairs(vendors) do
        local look = looks[index]
        local scale = (look.small and VendorPinsUI.SMALL or 1) / view.scale
        self.used = self.used + 1
        local pin = self.pins[self.used]
        if not pin then
            pin = VendorPinsUI.CreatePin(view.canvas)
            self.pins[self.used] = pin
        end
        VendorPinsUI.Dress(pin, vendor, look)
        pin:SetScale(scale)
        pin:SetFrameLevel(level)
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", view.canvas, "TOPLEFT",
            vendor.x / 100 * view.width / scale, -vendor.y / 100 * view.height / scale)
        pin:Show()
    end
    for index = self.used + 1, #self.pins do self.pins[index]:Hide() end
    -- A card left up for a pin laid out again shows its new numbers.
    local card = self.card
    if card and card:IsShown() and card.pin and card.pin:IsShown() then
        self:ShowCard(card.pin)
    elseif card and card:IsShown() then
        self:HideCard()
    end
end

function VendorPinsUI:Start()
    if self.driver then return end
    local driver = CreateFrame("Frame")
    local waited = 0
    driver:SetScript("OnUpdate", function(_, elapsed)
        waited = waited + (elapsed or 0)
        if waited < VendorPinsUI.LOOK then return end
        waited = 0
        local ok, err = pcall(VendorPinsUI.Draw, VendorPinsUI)
        if not ok then
            -- Tried again on the next look, never every frame with an error.
            VendorPinsUI.key = nil
            ns.Debug("vendor pins: " .. tostring(err))
        end
    end)
    self.driver = driver
end

if type(_G.CreateFrame) == "function" and type(_G.C_Timer) == "table" then
    _G.C_Timer.After(0, function() VendorPinsUI:Start() end)
end
