-- Blackthornes -- UI/SharedMinimap.lua
-- One minimap button for every Blackthornes addon (a player asked, the owner
-- said build it from a mockup, 2026-10-28).
--
-- The same file in all five addons; a fix to it belongs in all five. There
-- is no shared core addon, so every copy signs up in one global table,
-- `_G.BlackthornesMinimap`, as it loads, and each addon joins with its own
-- button once it has built it (`SharedMinimap:Join`). The copy with the
-- highest FILE_VERSION draws the shared button and its menu (the first to
-- load on a tie), so raise it when a change needs the newer copy.
--
-- "Combine Addon Buttons:" in each addon's Settings, ticked unless unticked
-- (the owner, 2026-10-28: on by default). Ticked, with two or more addons
-- loaded, each addon's own button is hidden (our own frames, never the
-- game's) and one gold gem button shows; a click opens a menu with a dark
-- glass row for each addon. A row's left-click opens the addon, right-click
-- its settings, and the addon may give shift and middle clicks their own
-- jobs. Unticked, every addon keeps its own button as before.
--
-- Saved in every loaded addon's account save, account wide, never rename
-- them: `minimapButton` ("shared" or "each", nil reads as "shared"),
-- `minimapButtonAt` (when it was set; the newest wins, so a change in one
-- addon is the answer in all) and `minimapSharedAngle` (where the shared
-- button sits on the ring, nil until it is dragged: then it starts where
-- the first addon's own button sits).

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local SharedMinimap = {}
ns.SharedMinimap = SharedMinimap

local FILE_VERSION = 1
SharedMinimap.FILE_VERSION = FILE_VERSION

local TITLE = "Blackthornes AddOns"
local PLATE = "BLACKTHORNES"
local ICON = [[Interface\Icons\INV_Misc_Gem_Topaz_02]]
local MENU_WIDTH = 300
local ROW_HEIGHT = 42
local PAD = 12
local EDGE = 6

local hub = _G.BlackthornesMinimap
if type(hub) ~= "table" then
    hub = {}
    _G.BlackthornesMinimap = hub
end
hub.entries = hub.entries or {}
hub.copies = hub.copies or {}
hub.copies[#hub.copies + 1] = { version = FILE_VERSION, api = SharedMinimap, ns = ns }

--- The copy that draws: the highest FILE_VERSION, the first loaded on a tie.
function SharedMinimap.Drawer()
    local best
    for _, copy in ipairs(hub.copies) do
        if not best or (copy.version or 0) > (best.version or 0) then best = copy end
    end
    return best
end

local function IsDrawer()
    local best = SharedMinimap.Drawer()
    return best and best.api == SharedMinimap
end

--- Every addon that joined, in its menu order.
function SharedMinimap.Entries()
    local list = {}
    for _, entry in pairs(hub.entries) do list[#list + 1] = entry end
    table.sort(list, function(a, b)
        if (a.order or 99) ~= (b.order or 99) then return (a.order or 99) < (b.order or 99) end
        return tostring(a.key) < tostring(b.key)
    end)
    return list
end

local function SaveOf(entry)
    if type(entry.db) ~= "function" then return nil end
    local ok, db = pcall(entry.db)
    if ok and type(db) == "table" then return db end
    return nil
end

--- Whether the buttons are combined: the newest answer any save holds,
--- ticked when none says.
function SharedMinimap.Combined()
    local value, at = nil, -1
    for _, entry in pairs(hub.entries) do
        local db = SaveOf(entry)
        if db and db.minimapButton ~= nil then
            local when = tonumber(db.minimapButtonAt) or 0
            if when > at then value, at = db.minimapButton, when end
        end
    end
    return value ~= "each"
end

--- Tick or untick it, in every loaded addon's save at once.
function SharedMinimap.SetCombined(on)
    local now = (time and time()) or 0
    for _, entry in pairs(hub.entries) do
        local db = SaveOf(entry)
        if db then
            db.minimapButton = on and "shared" or "each"
            db.minimapButtonAt = now
        end
    end
    SharedMinimap.Apply()
end

--- True while this addon's own button should stay out of sight.
function SharedMinimap.Hides(key)
    if not hub.entries[key] then return false end
    local count = 0
    for _ in pairs(hub.entries) do count = count + 1 end
    return count >= 2 and SharedMinimap.Combined()
end

--- An addon signs up with its own button built. `entry` holds key, order,
--- name, icon, blurb, button, angle (its own button's angle), open,
--- settings, shift and middle (optional), db (its account save).
function SharedMinimap:Join(entry)
    if type(entry) ~= "table" or not entry.key then return end
    hub.entries[entry.key] = entry
    SharedMinimap.Apply()
end

--- Show and hide the buttons a moment later, so a burst of joins at login
--- does it once.
function SharedMinimap.Apply()
    if hub.pending then return end
    hub.pending = true
    local function Run()
        hub.pending = false
        local drawer = SharedMinimap.Drawer()
        if drawer and drawer.api.ApplyNow then drawer.api.ApplyNow() end
    end
    if C_Timer and C_Timer.After then C_Timer.After(0, Run) else Run() end
end

function SharedMinimap.ApplyNow()
    local combined = false
    local count = 0
    for _ in pairs(hub.entries) do count = count + 1 end
    if count >= 2 then combined = SharedMinimap.Combined() end

    for _, entry in pairs(hub.entries) do
        local button = entry.button
        if button then
            if combined then button:Hide() else button:Show() end
        end
    end

    if combined then
        local button = SharedMinimap.Build()
        if button then
            SharedMinimap.Reposition()
            button:Show()
        end
    else
        if hub.button then hub.button:Hide() end
        if hub.menu then hub.menu:Hide() end
    end
end

--------------------------------------------------------------------------------
-- Where the shared button sits
--------------------------------------------------------------------------------

local function Radius()
    local size = Minimap and Minimap:GetWidth()
    if not size or size <= 0 then size = 140 end
    return size / 2 + 5
end

--- The saved angle, else where the first addon's own button sits.
function SharedMinimap.Angle()
    local list = SharedMinimap.Entries()
    for _, entry in ipairs(list) do
        local db = SaveOf(entry)
        if db and type(db.minimapSharedAngle) == "number" then return db.minimapSharedAngle end
    end
    local first = list[1]
    if first and type(first.angle) == "function" then
        local ok, angle = pcall(first.angle)
        if ok and type(angle) == "number" then return angle end
    end
    return math.rad(200)
end

local function SaveAngle(angle)
    for _, entry in pairs(hub.entries) do
        local db = SaveOf(entry)
        if db then db.minimapSharedAngle = angle end
    end
end

function SharedMinimap.Reposition()
    local button = hub.button
    if not button or not Minimap then return end
    local angle = SharedMinimap.Angle()
    local radius = Radius()
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

--------------------------------------------------------------------------------
-- The shared button
--------------------------------------------------------------------------------

function SharedMinimap.Build()
    if hub.button then return hub.button end
    if not IsDrawer() or not Minimap or not CreateFrame then return nil end
    local Theme = ns.Theme

    local button = CreateFrame("Button", "BlackthornesMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetPoint("CENTER")
    background:SetColorTexture(Theme.Unpack("window"))

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER")
    icon:SetTexture(ICON)
    icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture([[Interface\Minimap\MiniMap-TrackingBorder]])

    if button.SetHighlightTexture then
        pcall(button.SetHighlightTexture, button,
            [[Interface\Minimap\UI-Minimap-ZoomButton-Highlight]], "ADD")
    end

    button:SetMovable(true)
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", function(self)
        if hub.menu then hub.menu:Hide() end
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            local angle = math.atan2((cy / scale) - my, (cx / scale) - mx)
            SaveAngle(angle)
            SharedMinimap.Reposition()
        end)
    end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    button:SetScript("OnClick", function()
        SharedMinimap.ToggleMenu()
    end)

    button:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(TITLE)
        for _, entry in ipairs(SharedMinimap.Entries()) do
            GameTooltip:AddLine(entry.name, 0.5, 0.5, 0.5)
        end
        GameTooltip:AddLine(L["Click to pick an addon"], 0.7, 0.7, 0.7)
        GameTooltip:AddLine(L["Drag to move it round the minimap"], 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    hub.button = button

    -- The minimap's size can settle after login, or change later.
    if C_Timer and C_Timer.NewTicker then
        local width = Minimap:GetWidth()
        C_Timer.NewTicker(5, function()
            if Minimap:GetWidth() ~= width then
                width = Minimap:GetWidth()
                SharedMinimap.Reposition()
            end
        end)
    end
    return button
end

--------------------------------------------------------------------------------
-- The menu
--------------------------------------------------------------------------------

--- What a click on a row does, by mouse button and Shift.
function SharedMinimap.Run(entry, mouseButton, shift)
    local fn = entry.open
    if mouseButton == "RightButton" then
        fn = entry.settings or entry.open
    elseif mouseButton == "MiddleButton" and entry.middle then
        fn = entry.middle
    elseif shift and entry.shift then
        fn = entry.shift
    end
    if type(fn) == "function" then pcall(fn) end
end

local function PaintRow(row, hovered)
    local Theme = ns.Theme
    local key = hovered and "glassHover" or (row.index % 2 == 1 and "glass" or "glassAlt")
    row.fill:SetColorTexture(Theme.Unpack(key))
    if hovered then row.edge:Show() else row.edge:Hide() end
end

local function MakeRow(menu, index)
    local Theme = ns.Theme
    local row = CreateFrame("Button", nil, menu)
    row:SetHeight(ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
    row.index = index

    row.fill = row:CreateTexture(nil, "BACKGROUND")
    row.fill:SetAllPoints()

    local line = row:CreateTexture(nil, "BORDER")
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    line:SetColorTexture(Theme.Unpack("border", 0.6))

    row.edge = row:CreateTexture(nil, "ARTWORK")
    row.edge:SetWidth(2)
    row.edge:SetPoint("TOPLEFT")
    row.edge:SetPoint("BOTTOMLEFT")
    row.edge:SetColorTexture(Theme.Unpack("accentHi"))

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(24, 24)
    row.icon:SetPoint("LEFT", 10, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    row.name = Theme.CreateLabel(row, "normal", "accentHi")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 10, 1)
    row.name:SetPoint("RIGHT", row, "RIGHT", -10, 0)

    row.blurb = Theme.CreateLabel(row, "small", "muted")
    row.blurb:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
    row.blurb:SetPoint("RIGHT", row, "RIGHT", -10, 0)
    row.blurb:SetWordWrap(true)

    row:SetScript("OnEnter", function(self) PaintRow(self, true) end)
    row:SetScript("OnLeave", function(self) PaintRow(self, false) end)
    row:SetScript("OnClick", function(self, mouseButton)
        if hub.menu then hub.menu:Hide() end
        if self.entry then
            SharedMinimap.Run(self.entry, mouseButton, IsShiftKeyDown and IsShiftKeyDown())
        end
    end)
    PaintRow(row, false)
    return row
end

function SharedMinimap.BuildMenu()
    if hub.menu then return hub.menu end
    local Theme = ns.Theme

    local menu = CreateFrame("Frame", "BlackthornesMinimapMenu", UIParent)
    menu:SetWidth(MENU_WIDTH)
    menu:SetFrameStrata("DIALOG")
    menu:SetToplevel(true)
    menu:SetClampedToScreen(true)
    menu:EnableMouse(true)
    menu:Hide()
    Theme.Fill(menu, "window")

    -- The house frame: gold rim, the name on a plate and the red close gem.
    if ns.Titanforged and ns.Titanforged.Dress then
        local ok, trim = pcall(ns.Titanforged.Dress, ns.Titanforged, menu, {
            title = PLATE,
            close = function() menu:Hide() end,
        })
        if ok and trim and ns.Titanforged.Reach and menu.SetClampRectInsets then
            local left, right, top, bottom = ns.Titanforged.Reach(trim)
            menu:SetClampRectInsets(-left, right, top, -bottom)
        end
    else
        Theme.Border(menu, "accent")
    end

    menu.rows = {}

    menu.foot = Theme.CreateLabel(menu, "small", "muted", "CENTER")
    menu.foot:SetWordWrap(true)
    menu.foot:SetPoint("BOTTOMLEFT", PAD, PAD)
    menu.foot:SetPoint("BOTTOMRIGHT", -PAD, PAD)

    -- Escape closes it, and so does a click anywhere else.
    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "BlackthornesMinimapMenu")
    end
    menu:SetScript("OnShow", function(self) pcall(self.RegisterEvent, self, "GLOBAL_MOUSE_DOWN") end)
    menu:SetScript("OnHide", function(self) pcall(self.UnregisterEvent, self, "GLOBAL_MOUSE_DOWN") end)
    menu:SetScript("OnEvent", function(self)
        local over = self:IsMouseOver() or (hub.button and hub.button:IsMouseOver())
        if not over then self:Hide() end
    end)

    hub.menu = menu
    return menu
end

--- Lay out a row for each addon, the foot under them, and the menu's height.
function SharedMinimap.Fill(menu)
    local list = SharedMinimap.Entries()
    local top = 28
    for index, entry in ipairs(list) do
        local row = menu.rows[index] or MakeRow(menu, index)
        menu.rows[index] = row
        row.entry = entry
        row.icon:SetTexture(entry.icon)
        row.name:SetText(entry.name or entry.key)
        row.blurb:SetText(entry.blurb or "")
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", menu, "TOPLEFT", EDGE, -top)
        row:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -EDGE, -top)
        PaintRow(row, false)
        row:Show()
        top = top + ROW_HEIGHT
    end
    for index = #list + 1, #menu.rows do menu.rows[index]:Hide() end

    menu.foot:SetText(L["Click a name to open it. Right-click for its settings."])
    local footHeight = math.max(menu.foot:GetStringHeight() or 14, 14)
    menu:SetHeight(top + 10 + footHeight + PAD)
end

--- Open the menu beside the button, toward the middle of the screen.
function SharedMinimap.ToggleMenu()
    local menu = SharedMinimap.BuildMenu()
    if menu:IsShown() then
        menu:Hide()
        return
    end
    if GameTooltip then GameTooltip:Hide() end
    SharedMinimap.Fill(menu)

    local button = hub.button
    menu:ClearAllPoints()
    if button and UIParent then
        local x, y = button:GetCenter()
        local width, height = UIParent:GetWidth(), UIParent:GetHeight()
        local scale = (button:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
        x, y = (x or 0) * scale, (y or 0) * scale
        local vertical = (y > (height or 0) / 2) and "TOP" or "BOTTOM"
        if x > (width or 0) / 2 then
            menu:SetPoint(vertical .. "RIGHT", button, vertical .. "LEFT", -8, 0)
        else
            menu:SetPoint(vertical .. "LEFT", button, vertical .. "RIGHT", 8, 0)
        end
    else
        menu:SetPoint("CENTER")
    end
    menu:Show()
end
