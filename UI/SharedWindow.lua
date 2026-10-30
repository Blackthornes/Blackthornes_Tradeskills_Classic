-- Blackthornes -- UI/SharedWindow.lua
-- One window for every Blackthornes addon (the owner approved the mockups
-- and said build it, 2026-10-30): a house-look window with a rail down its
-- left side, a button for each addon loaded, and the picked addon's pages
-- beside it. One size, one size grip, one fold gem, one place.
--
-- The same file in all five addons; a fix to it belongs in all five. There
-- is no shared core addon, so, like UI/SharedMinimap.lua, every copy signs
-- up in one global table, `_G.BlackthornesWindow`, as it loads, and each
-- addon joins with `SharedWindow:Join`. The copy with the highest
-- FILE_VERSION builds and draws the window (the first to load on a tie), so
-- raise it when a change needs the newer copy.
--
-- An addon whose pages have moved in gives `host = { enter, leave }`:
-- `enter(area)` lays its pages into the window's content frame, `leave()`
-- takes them back. An addon without one still has its rail button, which
-- opens the addon's own window, so each addon works whatever has moved in.
--
-- Off unless ticked ("One Window:", nil reads as off). Saved in every loaded
-- addon's account save, account wide, never rename them: `oneWindow` (true
-- or false), `oneWindowAt` (when it was set; the newest wins), `oneWindowPick`
-- (the addon picked last), `oneWindowLeft`, `oneWindowTop` (its top left
-- corner) and `oneWindowScale` (the size grip's percent).
--
-- Docking (the owner said build it, 2026-10-30, mockup B): while the game's
-- mailbox, vendor or trainer window is open and the one window is up, it
-- sits beside the game's window, its rail turned into a small row of addon
-- buttons along the top so it stays narrow. When the game's window closes it
-- goes back to its own place, on the addon that was open before. Which addon
-- shows there is each addon's own doing (Butler opens at the mailbox and the
-- vendor). The game's frames are only read for where they stand, never
-- shown, hidden, moved or written; ours is placed by screen position.

local ADDON, ns = ...

local SharedWindow = {}
ns.SharedWindow = SharedWindow

local FILE_VERSION = 2
SharedWindow.FILE_VERSION = FILE_VERSION

local PLATE = "Blackthornes"
SharedWindow.RAIL_WIDTH = 84
SharedWindow.RAIL_BUTTON = 76
SharedWindow.WIDTH = 860
SharedWindow.HEIGHT = 520
SharedWindow.SCALE_MIN = 50
SharedWindow.SCALE_MAX = 150
local EDGE = 8
local TOP = 30
local ICON = 34
SharedWindow.ROW_HEIGHT = 40
SharedWindow.ROW_BUTTON = 34
SharedWindow.ROW_ICON = 26
SharedWindow.DOCK_GAP = 6
-- How soon after a game window closes the one window goes back to the addon
-- open before, so the addons' own closing comes first.
SharedWindow.BACK_WAIT = 0.1
-- How long an Open counts as "just before" a game window opened.
SharedWindow.PRIOR_FOR = 0.5

-- The game's windows the one window docks beside: the events that open and
-- close each, and the frames it may be (read only).
SharedWindow.PLACES = {
    mail = { show = "MAIL_SHOW", hide = "MAIL_CLOSED", frames = { "MailFrame" } },
    vendor = { show = "MERCHANT_SHOW", hide = "MERCHANT_CLOSED", frames = { "MerchantFrame" } },
    trainer = { show = "TRAINER_SHOW", hide = "TRAINER_CLOSED", frames = { "ClassTrainerFrame" } },
}

local hub = _G.BlackthornesWindow
if type(hub) ~= "table" then
    hub = {}
    _G.BlackthornesWindow = hub
end
hub.entries = hub.entries or {}
hub.copies = hub.copies or {}
hub.copies[#hub.copies + 1] = { version = FILE_VERSION, api = SharedWindow, ns = ns }

--- The copy that draws: the highest FILE_VERSION, the first loaded on a tie.
function SharedWindow.Drawer()
    local best
    for _, copy in ipairs(hub.copies) do
        if not best or (copy.version or 0) > (best.version or 0) then best = copy end
    end
    return best
end

local function IsDrawer()
    local best = SharedWindow.Drawer()
    return best and best.api == SharedWindow
end

--- Every addon that joined, in rail order.
function SharedWindow.Entries()
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

--- The first value any save holds for `key`, in rail order.
local function Read(key)
    for _, entry in ipairs(SharedWindow.Entries()) do
        local db = SaveOf(entry)
        if db and db[key] ~= nil then return db[key] end
    end
    return nil
end

--- Write `key` in every loaded addon's save.
local function WriteAll(key, value)
    for _, entry in pairs(hub.entries) do
        local db = SaveOf(entry)
        if db then db[key] = value end
    end
end

--- Whether the one window is on: the newest answer any save holds, off when
--- none says.
function SharedWindow.On()
    local value, at = nil, -1
    for _, entry in pairs(hub.entries) do
        local db = SaveOf(entry)
        if db and db.oneWindow ~= nil then
            local when = tonumber(db.oneWindowAt) or 0
            if when > at then value, at = db.oneWindow, when end
        end
    end
    return value == true
end

--- Tick or untick it, in every loaded addon's save at once. Unticked, the
--- window closes and each addon's pages go back to their own windows.
function SharedWindow.SetOn(on)
    local now = (time and time()) or 0
    for _, entry in pairs(hub.entries) do
        local db = SaveOf(entry)
        if db then
            db.oneWindow = on and true or false
            db.oneWindowAt = now
        end
    end
    if not on then SharedWindow.Close() end
end

--- An addon signs up. `entry` holds key, order, name (shown on the rail),
--- icon, open (its own window), settings, db (its account save) and, once
--- its pages have moved in, host = { enter(area), leave() }.
function SharedWindow:Join(entry)
    if type(entry) ~= "table" or not entry.key then return end
    hub.entries[entry.key] = entry
    if hub.frame and hub.frame:IsShown() then SharedWindow.FillRail() end
end

--- True when this addon's pages show in the one window rather than its own.
function SharedWindow.Hosts(key)
    local entry = hub.entries[key]
    return entry ~= nil and type(entry.host) == "table" and SharedWindow.On()
end

--------------------------------------------------------------------------------
-- Picking an addon
--------------------------------------------------------------------------------

--- The addon picked last, else the first that has moved in.
function SharedWindow.Picked()
    local key = Read("oneWindowPick")
    local entry = key and hub.entries[key]
    if entry and entry.host then return entry end
    for _, each in ipairs(SharedWindow.Entries()) do
        if each.host then return each end
    end
    return nil
end

--- Show `key`'s pages. One that has not moved in opens its own window.
function SharedWindow.Pick(key)
    local entry = hub.entries[key]
    if not entry then return false end
    if type(entry.host) ~= "table" then
        if type(entry.open) == "function" then pcall(entry.open) end
        return false
    end
    local frame = SharedWindow.Build()
    if not frame then return false end
    if hub.current and hub.current ~= entry and type(hub.current.host.leave) == "function" then
        pcall(hub.current.host.leave)
    end
    hub.current = entry
    WriteAll("oneWindowPick", key)
    if type(entry.host.enter) == "function" then pcall(entry.host.enter, frame.area) end
    SharedWindow.FillRail()
    return true
end

--- Open the window on `key`, or on the addon picked last.
function SharedWindow.Open(key)
    local entry = key and hub.entries[key] or SharedWindow.Picked()
    if not entry then return false end
    local frame = SharedWindow.Build()
    if not frame then return false end
    local wasOpen = frame:IsShown() and true or false
    hub.prior = { key = hub.current and hub.current.key, open = wasOpen, at = SharedWindow.Now() }
    if ns.FoldWindow and ns.FoldWindow.Unfold then pcall(ns.FoldWindow.Unfold, ns.FoldWindow, frame) end
    frame:Show()
    local picked = SharedWindow.Pick(entry.key)
    if hub.place then
        if not hub.docked then
            hub.back = wasOpen and { key = hub.prior.key, open = true } or nil
        end
        SharedWindow.Dock()
    elseif hub.docked then
        SharedWindow.Undock()
    end
    return picked
end

function SharedWindow.Close()
    if hub.frame then hub.frame:Hide() end
end

function SharedWindow.IsOpen()
    return hub.frame ~= nil and hub.frame:IsShown() and true or false
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

local function Clamp(percent)
    percent = tonumber(percent) or 100
    if percent < SharedWindow.SCALE_MIN then return SharedWindow.SCALE_MIN end
    if percent > SharedWindow.SCALE_MAX then return SharedWindow.SCALE_MAX end
    return percent
end
SharedWindow.Clamp = Clamp

local function SavePlace(frame)
    local ok, left, top = pcall(function() return frame:GetLeft(), frame:GetTop() end)
    if ok and type(left) == "number" and type(top) == "number" then
        WriteAll("oneWindowLeft", left)
        WriteAll("oneWindowTop", top)
    end
end

local function Place(frame)
    frame:SetScale(Clamp(Read("oneWindowScale")) / 100)
    frame:ClearAllPoints()
    local left, top = Read("oneWindowLeft"), Read("oneWindowTop")
    if type(left) == "number" and type(top) == "number" then
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    end
end

--- The house size grip below the bottom right corner: drag to scale the
--- window from its top left corner, right-click for the normal size.
local function MakeGrip(frame)
    local Theme = ns.Theme
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", -6, -3)
    grip:SetFrameLevel((frame:GetFrameLevel() or 0) + 20)
    grip:RegisterForClicks("RightButtonUp")
    Theme.Fill(grip, "panel")
    Theme.Border(grip, "borderLit")
    local dots = {}
    for row = 0, 2 do
        for column = 2 - row, 2 do
            local dot = grip:CreateTexture(nil, "ARTWORK")
            dot:SetSize(3, 3)
            dot:SetPoint("BOTTOMRIGHT", grip, "BOTTOMRIGHT", -3 - (2 - column) * 5, 3 + (2 - row) * 5)
            dot:SetColorTexture(Theme.Unpack("accent"))
            dots[#dots + 1] = dot
        end
    end
    local function Light(on)
        for _, dot in ipairs(dots) do dot:SetColorTexture(Theme.Unpack(on and "accentHi" or "accent")) end
    end
    local function Resize(percent)
        local old = frame:GetScale() or 1
        local ok, left, top = pcall(function() return frame:GetLeft(), frame:GetTop() end)
        frame:SetScale(percent / 100)
        if ok and type(left) == "number" and type(top) == "number" then
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * old / (percent / 100), top * old / (percent / 100))
        end
        WriteAll("oneWindowScale", percent)
        if hub.docked then SharedWindow.Dock(true) else SavePlace(frame) end
    end
    grip:SetScript("OnEnter", function() Light(true) end)
    grip:SetScript("OnLeave", function() if not grip.dragging then Light(false) end end)
    grip:SetScript("OnClick", function() Resize(100) end)
    grip:SetScript("OnMouseDown", function(self, mouseButton)
        if mouseButton ~= "LeftButton" then return end
        self.dragging = true
        local startX = GetCursorPosition()
        local startScale = Clamp((frame:GetScale() or 1) * 100)
        local width = SharedWindow.WIDTH
        self:SetScript("OnUpdate", function()
            local x = GetCursorPosition()
            local ui = UIParent:GetEffectiveScale() or 1
            local grow = ((x - startX) / ui) / width * 100
            Resize(Clamp(math.floor(startScale + grow + 0.5)))
        end)
    end)
    grip:SetScript("OnMouseUp", function(self)
        self.dragging = false
        self:SetScript("OnUpdate", nil)
        Light(self:IsMouseOver())
    end)
    return grip
end

function SharedWindow.Build()
    if hub.frame then return hub.frame end
    if not IsDrawer() or not CreateFrame or not UIParent then return nil end
    local Theme = ns.Theme

    local frame = CreateFrame("Frame", "BlackthornesOneWindow", UIParent)
    frame:SetSize(SharedWindow.WIDTH, SharedWindow.HEIGHT)
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Moved while docked, it stays where it was dropped for this visit,
        -- but its own place is kept for when the game's window closes.
        if not hub.docked then SavePlace(self) end
    end)
    frame:Hide()
    Theme.Fill(frame, "window")

    -- The house frame: gold rim, the name on a plate, the red close gem and,
    -- left of it, the gold fold gem.
    if ns.Titanforged and ns.Titanforged.Dress then
        local ok, trim = pcall(ns.Titanforged.Dress, ns.Titanforged, frame, {
            title = PLATE,
            close = function() frame:Hide() end,
        })
        if ok and type(trim) == "table" then
            frame.trim = trim
            if ns.Titanforged.Reach and frame.SetClampRectInsets then
                local left, right, top, bottom = ns.Titanforged.Reach(trim)
                frame:SetClampRectInsets(-left, right, top, -bottom)
            end
        end
    else
        Theme.Border(frame, "borderLit")
    end
    if ns.FoldWindow and ns.FoldWindow.Add and rawget(frame, "trim") then
        pcall(ns.FoldWindow.Add, ns.FoldWindow, frame, {})
    end

    -- The rail down the left side, and the area the picked addon's pages fill.
    local rail = CreateFrame("Frame", nil, frame)
    rail.buttons = {}
    frame.rail = rail

    local area = CreateFrame("Frame", nil, frame)
    frame.area = area
    SharedWindow.Lay(frame, false)

    frame.grip = MakeGrip(frame)

    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "BlackthornesOneWindow")
    end
    frame:SetScript("OnHide", function()
        if hub.current and type(hub.current.host) == "table" and type(hub.current.host.leave) == "function" then
            pcall(hub.current.host.leave)
        end
        hub.current = nil
    end)

    hub.frame = frame
    Place(frame)
    return frame
end

--- Lay the rail down the left side, or, docked, as a row along the top.
--- The area keeps its size either way, so the pages in it stay as they are:
--- the window loses the rail's width and gains the row's height.
function SharedWindow.Lay(frame, docked)
    local rail, area = frame.rail, frame.area
    rail:ClearAllPoints()
    area:ClearAllPoints()
    if docked then
        rail:SetPoint("TOPLEFT", frame, "TOPLEFT", EDGE, -TOP)
        rail:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -EDGE, -TOP)
        rail:SetHeight(SharedWindow.ROW_HEIGHT)
        area:SetPoint("TOPLEFT", rail, "BOTTOMLEFT", 0, -EDGE)
    else
        rail:SetPoint("TOPLEFT", frame, "TOPLEFT", EDGE, -TOP)
        rail:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", EDGE, EDGE)
        rail:SetWidth(SharedWindow.RAIL_WIDTH)
        area:SetPoint("TOPLEFT", rail, "TOPRIGHT", EDGE, 0)
    end
    area:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -EDGE, EDGE)
    frame.docked = docked and true or false
end

--------------------------------------------------------------------------------
-- The rail
--------------------------------------------------------------------------------

local function PaintButton(button, hovered)
    local Theme = ns.Theme
    local picked = button.entry ~= nil and button.entry == hub.current
    local key = picked and "glassActive" or (hovered and "glassHover" or (button.index % 2 == 1 and "glass" or "glassAlt"))
    button.fill:SetColorTexture(Theme.Unpack(key))
    if picked or hovered then button.edge:Show() else button.edge:Hide() end
    button.edge:SetColorTexture(Theme.Unpack(picked and "accentHi" or "accent"))
    button.name:SetTextColor(Theme.Unpack(picked and "accentHi" or "muted"))
end

local function MakeButton(rail, index)
    local Theme = ns.Theme
    local button = CreateFrame("Button", nil, rail)
    button:SetSize(SharedWindow.RAIL_BUTTON, SharedWindow.RAIL_BUTTON)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button.index = index

    button.fill = button:CreateTexture(nil, "BACKGROUND")
    button.fill:SetAllPoints()

    local line = button:CreateTexture(nil, "BORDER")
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    line:SetColorTexture(Theme.Unpack("border", 0.6))

    button.edge = button:CreateTexture(nil, "ARTWORK")
    button.edge:SetWidth(2)
    button.edge:SetPoint("TOPLEFT")
    button.edge:SetPoint("BOTTOMLEFT")

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetSize(ICON, ICON)
    button.icon:SetPoint("TOP", 0, -10)
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    button.name = Theme.CreateLabel(button, "small", "muted", "CENTER")
    button.name:SetWordWrap(true)
    button.name:SetPoint("TOPLEFT", button.icon, "BOTTOMLEFT", -16, -4)
    button.name:SetPoint("TOPRIGHT", button.icon, "BOTTOMRIGHT", 16, -4)

    button:SetScript("OnEnter", function(self)
        PaintButton(self, true)
        -- In the row along the top only the emblem shows: the name is the hover.
        local tip = rawget(_G, "GameTooltip")
        if hub.docked and tip and self.entry then
            pcall(function()
                tip:SetOwner(self, "ANCHOR_BOTTOM")
                tip:SetText(self.entry.name or self.entry.key)
                tip:Show()
            end)
        end
    end)
    button:SetScript("OnLeave", function(self)
        PaintButton(self, false)
        local tip = rawget(_G, "GameTooltip")
        if tip and tip.GetOwner and tip:GetOwner() == self then pcall(tip.Hide, tip) end
    end)
    button:SetScript("OnClick", function(self, mouseButton)
        local entry = self.entry
        if not entry then return end
        if mouseButton == "RightButton" and type(entry.settings) == "function" then
            pcall(entry.settings)
        else
            SharedWindow.Pick(entry.key)
        end
    end)
    return button
end

--- A button for each addon that joined, in rail order.
function SharedWindow.FillRail()
    local frame = hub.frame
    if not frame then return end
    local rail = frame.rail
    local docked = hub.docked
    local size = docked and SharedWindow.ROW_BUTTON or SharedWindow.RAIL_BUTTON
    local icon = docked and SharedWindow.ROW_ICON or ICON
    local step = 0
    local list = SharedWindow.Entries()
    for index, entry in ipairs(list) do
        local button = rail.buttons[index] or MakeButton(rail, index)
        rail.buttons[index] = button
        button.entry = entry
        button:SetSize(size, size)
        button.icon:SetSize(icon, icon)
        button.icon:ClearAllPoints()
        button.icon:SetTexture(entry.icon)
        button.name:SetText(entry.name or entry.key)
        button:ClearAllPoints()
        if docked then
            button.icon:SetPoint("CENTER")
            button.name:Hide()
            button:SetPoint("LEFT", rail, "LEFT", step, 0)
        else
            button.icon:SetPoint("TOP", 0, -10)
            button.name:Show()
            button:SetPoint("TOP", rail, "TOP", 0, -step)
        end
        PaintButton(button, false)
        button:Show()
        step = step + size + (docked and 6 or 4)
    end
    for index = #list + 1, #rail.buttons do rail.buttons[index]:Hide() end
end

--------------------------------------------------------------------------------
-- Docking beside the game's windows
--------------------------------------------------------------------------------

function SharedWindow.Now()
    local GetTime = rawget(_G, "GetTime")
    if type(GetTime) == "function" then
        local ok, now = pcall(GetTime)
        if ok and type(now) == "number" then return now end
    end
    return 0
end

local function InFight()
    local fn = rawget(_G, "InCombatLockdown")
    if type(fn) ~= "function" then return false end
    local ok, fighting = pcall(fn)
    return ok and fighting and true or false
end

--- The game's window for the place open now, read only, or nil.
local function GameFrame()
    local place = hub.place and SharedWindow.PLACES[hub.place]
    if not place then return nil end
    for _, name in ipairs(place.frames) do
        local game = rawget(_G, name)
        if type(game) == "table" then
            local ok, shown = pcall(game.IsShown, game)
            if ok and shown then return game end
        end
    end
    return nil
end

--- True while the window sits beside one of the game's windows.
function SharedWindow.Docked()
    return hub.docked == true
end

--- The place open now ("mail", "vendor" or "trainer"), or nil.
function SharedWindow.Place()
    return hub.place
end

--- Put the window beside the game's window, by screen position: its left
--- edge (portrait and all) just past the game's right edge, the tops level.
local function Beside(frame, game)
    local ok, right, top, scale = pcall(function()
        return game:GetRight(), game:GetTop(), game:GetEffectiveScale()
    end)
    if not ok or type(right) ~= "number" or type(top) ~= "number" then return false end
    if type(scale) ~= "number" or scale <= 0 then scale = 1 end
    local okOurs, ours = pcall(frame.GetEffectiveScale, frame)
    if not okOurs or type(ours) ~= "number" or ours <= 0 then ours = 1 end
    local reach = 0
    local trim = rawget(frame, "trim")
    if trim and ns.Titanforged and ns.Titanforged.Reach then
        local okReach, left = pcall(ns.Titanforged.Reach, trim)
        if okReach and type(left) == "number" then reach = left end
    end
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT",
        right * scale / ours + reach + SharedWindow.DOCK_GAP, top * scale / ours)
    return true
end

--- Dock beside the game's window open now. `again` only places it anew
--- (after a resize). Nothing moves in a fight.
function SharedWindow.Dock(again)
    local frame = hub.frame
    if not (frame and frame:IsShown() and hub.place) or InFight() then return false end
    local game = GameFrame()
    if not game then return false end
    if not hub.docked then
        hub.docked = true
        local okW, width = pcall(frame.GetWidth, frame)
        local okH, height = pcall(frame.GetHeight, frame)
        if okW and okH and type(width) == "number" and type(height) == "number" then
            frame:SetSize(width - SharedWindow.RAIL_WIDTH - EDGE,
                height + SharedWindow.ROW_HEIGHT + EDGE)
        end
        SharedWindow.Lay(frame, true)
        SharedWindow.FillRail()
    elseif not again then
        return true
    end
    return Beside(frame, game)
end

--- Back to its own place, with the rail down the left side.
function SharedWindow.Undock()
    local frame = hub.frame
    if not (frame and hub.docked) then return end
    hub.docked = false
    local okW, width = pcall(frame.GetWidth, frame)
    local okH, height = pcall(frame.GetHeight, frame)
    if okW and okH and type(width) == "number" and type(height) == "number" then
        frame:SetSize(width + SharedWindow.RAIL_WIDTH + EDGE,
            height - SharedWindow.ROW_HEIGHT - EDGE)
    end
    SharedWindow.Lay(frame, false)
    Place(frame)
    SharedWindow.FillRail()
end

--- One of the game's windows opened.
function SharedWindow.Arrived(key)
    if not SharedWindow.PLACES[key] then return end
    hub.place = key
    local frame = hub.frame
    if not (frame and frame:IsShown()) or hub.docked then return end
    -- Up already: what it showed before is what it goes back to. An addon
    -- that opened it a moment ago (Butler at the vendor) left a note of
    -- what was there before it.
    local prior = hub.prior
    if prior and SharedWindow.Now() - (prior.at or 0) <= SharedWindow.PRIOR_FOR then
        hub.back = prior.open and { key = prior.key, open = true } or nil
    else
        hub.back = { key = hub.current and hub.current.key, open = true }
    end
    -- The game shows its window on the same event: place ours a moment after.
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function() SharedWindow.Dock() end)
    else
        SharedWindow.Dock()
    end
end

--- The game's window closed: back to its own place, and, a moment later,
--- back to the addon that was open before.
function SharedWindow.Left(key)
    if hub.place ~= key then return end
    hub.place = nil
    local back = hub.back
    hub.back = nil
    if hub.docked then SharedWindow.Undock() end
    if not (back and back.open and back.key and SharedWindow.On()) then return end
    local function Return()
        if hub.place then return end
        local frame = hub.frame
        if frame and frame:IsShown() then
            if not (hub.current and hub.current.key == back.key) then SharedWindow.Pick(back.key) end
        else
            SharedWindow.Open(back.key)
        end
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(SharedWindow.BACK_WAIT, Return)
    else
        Return()
    end
end

-- Every copy listens; only the one that draws acts.
if CreateFrame then
    local events = CreateFrame("Frame")
    local which = {}
    for key, place in pairs(SharedWindow.PLACES) do
        which[place.show] = { key = key, open = true }
        which[place.hide] = { key = key, open = false }
        pcall(events.RegisterEvent, events, place.show)
        pcall(events.RegisterEvent, events, place.hide)
    end
    events:SetScript("OnEvent", function(_, event)
        if not IsDrawer() then return end
        local what = which[event]
        if not what then return end
        if what.open then SharedWindow.Arrived(what.key) else SharedWindow.Left(what.key) end
    end)
    SharedWindow.events = events
end
