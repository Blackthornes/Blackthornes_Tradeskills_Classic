-- Blackthornes -- UI/TravelCard.lua
-- "Your Way There": the steps of the arrow's trip (Logic/Travel.lua) as
-- dark glass rows, the one to do now lit with a gold edge, the ones behind
-- you dimmed with Done, then about how long the rest takes, Stop and Show
-- on Map. The owner said build it (2026-10-21) from the mockup.
--
-- It shows only while the arrow is on a trip and the dial shows, and is
-- drawn again only when the steps or the one you are on change. Its close
-- gem only puts the card away (`TravelCard:Close`): the arrow still leads
-- the way, and the card comes back when the arrow is aimed somewhere else.
-- Stop ends the trip. Its own
-- frame on UIParent; it can be dragged, and keeps its place in
-- `travelCardX`/`travelCardY` and its size in `travelCardScale` (account
-- wide, never rename them).
--
-- The same file in every addon whose arrow takes trips (a fix to it belongs
-- in all of them); the addon's own parts come through Travel.Host.

local addonName, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local TravelCard = ns.NewModule("TravelCard")

local Theme = ns.Theme
local Widgets = ns.Widgets

local function Host() return ns.Travel.Host end
local function DB() local db = Host().DB() return type(db) == "table" and db or nil end

local WIDTH = 330
local PADDING = 12
local ROW = 40
local TOP = 34
local FOOT = 44
-- At most this many rows; a longer trip shows the ones around the step you
-- are on.
TravelCard.MAX_ROWS = 6

--- How tall a wrapped label stands at a width, never less than its lines
--- by measure (German runs about 30% longer, so a step's words can take
--- two lines); kept here so the file stays the same in every addon.
function TravelCard.Tall(label, size, width)
    local text = label and label.GetText and label:GetText()
    if type(text) ~= "string" or text == "" then return 0 end
    local line = ((Theme.sizes and tonumber(Theme.sizes[size])) or 12) + 2
    local ok, wide = pcall(label.GetStringWidth, label)
    wide = ok and tonumber(wide) or 0
    local lines = 1
    if width and width > 0 then lines = math.max(1, math.ceil(wide / width)) end
    local _, breaks = text:gsub("\n", "")
    local tall = (lines + breaks) * line
    local got, real = pcall(label.GetStringHeight, label)
    real = got and tonumber(real) or 0
    return math.ceil(math.max(tall, real))
end

function TravelCard:Build()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", tostring(addonName):gsub("_", "") .. "TravelCard", UIParent)
    frame:SetSize(WIDTH, TOP + ROW + FOOT)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:Hide()
    self.frame = frame

    Theme.Fill(frame, "window")
    local trim
    if ns.Titanforged then
        trim = ns.Titanforged:Dress(frame, {
            title = L["Your Way There"],
            close = function() TravelCard:Close() end,
        })
    else
        Theme.Border(frame, "borderLit")
    end

    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        TravelCard:SavePlace()
    end)

    if Widgets.ApplySize then Widgets.ApplySize(frame, DB() and DB().travelCardScale) end
    if Widgets.CreateSizeGrip then
        self.sizeGrip = Widgets.CreateSizeGrip(frame, {
            below = trim and ns.Titanforged.Reach and select(4, ns.Titanforged.Reach(trim)) or 0,
            get = function() return DB() and DB().travelCardScale end,
            save = function(percent) if DB() then DB().travelCardScale = percent end end,
        })
    end

    self.rows = {}
    for index = 1, TravelCard.MAX_ROWS do
        local row = CreateFrame("Frame", nil, frame)
        row:SetPoint("TOPLEFT", PADDING, -(TOP + (index - 1) * ROW))
        row:SetPoint("TOPRIGHT", -PADDING, -(TOP + (index - 1) * ROW))
        row:SetHeight(ROW)
        row.fill = row:CreateTexture(nil, "BACKGROUND")
        row.fill:SetAllPoints()
        row.edge = row:CreateTexture(nil, "BORDER")
        row.edge:SetPoint("TOPLEFT")
        row.edge:SetPoint("BOTTOMLEFT")
        row.edge:SetWidth(3)
        row.edge:SetColorTexture(Theme.Unpack("accentHi"))
        row.line = row:CreateTexture(nil, "BORDER")
        row.line:SetPoint("BOTTOMLEFT")
        row.line:SetPoint("BOTTOMRIGHT")
        row.line:SetHeight(1)
        row.line:SetColorTexture(Theme.Unpack("border", 0.6))

        row.status = Theme.CreateLabel(row, "small", "muted", "RIGHT")
        row.status:SetPoint("TOPRIGHT", -8, -6)
        row.title = Theme.CreateLabel(row, "normal", "text")
        row.title:SetPoint("TOPLEFT", 10, -6)
        row.title:SetPoint("RIGHT", row.status, "LEFT", -6, 0)
        row.title:SetWordWrap(true)
        row.sub = Theme.CreateLabel(row, "small", "muted")
        row.sub:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -2)
        row.sub:SetPoint("RIGHT", -8, 0)
        row.sub:SetWordWrap(true)
        row:Hide()
        self.rows[index] = row
    end

    self.time = Theme.CreateLabel(frame, "small", "muted")
    self.time:SetPoint("BOTTOMLEFT", PADDING + 2, PADDING + 8)

    self.show = Widgets.CreateButton(frame, L["Show on Map"], function() TravelCard:ShowOnMap() end,
        { primary = true })
    self.show:SetPoint("BOTTOMRIGHT", -PADDING, PADDING)
    self.stop = Widgets.CreateButton(frame, L["Stop"], function() TravelCard:Stop() end)
    self.stop:SetPoint("RIGHT", self.show, "LEFT", -8, 0)

    self:RestorePlace()
    return frame
end

function TravelCard:SavePlace()
    local frame = self.frame
    local db = DB()
    if not (frame and db) then return end
    local ok, left, top = pcall(function() return frame:GetLeft(), frame:GetTop() end)
    if ok and left and top then db.travelCardX, db.travelCardY = left, top end
end

function TravelCard:RestorePlace()
    local frame = self.frame
    frame:ClearAllPoints()
    local db = DB()
    local x, y = db and tonumber(db.travelCardX), db and tonumber(db.travelCardY)
    if x and y then
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    else
        frame:SetPoint("RIGHT", UIParent, "RIGHT", -60, 60)
    end
end

--- What a row says under its step.
function TravelCard.SubLine(step)
    if step.kind == "fly" then return L["Talk to the flight master"] end
    if step.kind == "boat" or step.kind == "zeppelin" then return L["Get on when it stops"] end
    if step.kind == "hearth" then
        return L.Format("It takes you to %s", ns.Travel.ShortName(step.to and step.to.name) or "?")
    end
    return step.to and step.to.zone and Host().Show(step.to.zone) or ""
end

--- The rows for a plan: { title, sub, status, now, done }, the steps behind
--- you first.
function TravelCard.Rows(plan)
    local rows = {}
    local number = 0
    for _, step in ipairs(plan.behind or {}) do
        number = number + 1
        rows[#rows + 1] = { title = ("%d. %s"):format(number, (ns.Travel.StepWords(step))),
            sub = TravelCard.SubLine(step), status = L["Done"], done = true }
    end
    for index, step in ipairs(plan.steps or {}) do
        number = number + 1
        rows[#rows + 1] = { title = ("%d. %s"):format(number, (ns.Travel.StepWords(step))),
            sub = TravelCard.SubLine(step), status = index == 1 and L["Now"] or "", now = index == 1 }
    end
    -- A long trip: the step you are on, and what is around it.
    local now = #(plan.behind or {}) + 1
    local first = math.max(1, math.min(now - 1, #rows - TravelCard.MAX_ROWS + 1))
    local shown = {}
    for index = first, math.min(#rows, first + TravelCard.MAX_ROWS - 1) do shown[#shown + 1] = rows[index] end
    return shown
end

--- "About 6 minutes".
function TravelCard.TimeText(plan)
    local minutes = ns.Travel.Minutes(plan)
    if minutes == 1 then return L["About 1 minute"] end
    return L.Format("About %d minutes", minutes)
end

--- Shows the card for the dial's state, or hides it.
function TravelCard:Update(state)
    local trip = type(state) == "table" and state.trip
    if not trip or not trip.plan then
        if self.frame then self.frame:Hide() end
        self.drawnKey = nil
        return
    end
    local plan = trip.plan
    if self.closedKey then
        if self.closedKey == plan.key then
            if self.frame then self.frame:Hide() end
            return
        end
        self.closedKey = nil
    end
    self.shownPlan = plan.key
    local key = ("%s|%d|%d|%s"):format(plan.key or "", plan.done or 0, #plan.steps, trip.line or "")
    local frame = self:Build()
    if key ~= self.drawnKey then
        self.drawnKey = key
        local rows = TravelCard.Rows(plan)
        local y = TOP
        for index, row in ipairs(self.rows) do
            local data = rows[index]
            if data then
                row.title:SetText(data.title)
                row.sub:SetText(data.sub)
                row.status:SetText(data.status)
                local glass = data.now and "glassActive" or (index % 2 == 0 and "glassAlt" or "glass")
                row.fill:SetColorTexture(Theme.Unpack(glass, 0.92))
                row.edge:SetShown(data.now and true or false)
                row.title:SetTextColor(Theme.Unpack(data.now and "accentHi" or "text"))
                row.status:SetTextColor(Theme.Unpack(data.done and "good" or data.now and "accentHi" or "muted"))
                row:SetAlpha(data.done and 0.6 or 1)
                -- A step whose words wrap makes its row taller and moves
                -- the rows under it down, never over them.
                local inner = WIDTH - PADDING * 2
                local statusWide = tonumber(select(2, pcall(row.status.GetStringWidth, row.status))) or 0
                local tall = 6 + TravelCard.Tall(row.title, "normal", inner - 10 - 8 - statusWide - 6)
                    + 2 + TravelCard.Tall(row.sub, "small", inner - 10 - 8) + 4
                local height = math.max(ROW, tall)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", PADDING, -y)
                row:SetPoint("TOPRIGHT", -PADDING, -y)
                row:SetHeight(height)
                y = y + height
                row:Show()
            else
                row:Hide()
            end
        end
        self.time:SetText(TravelCard.TimeText(plan))
        frame:SetHeight(y + FOOT)
    end
    frame:Show()
end

function TravelCard:Hide()
    if self.frame then self.frame:Hide() end
    self.drawnKey = nil
end

--- The close gem: only the card goes, for this place. The arrow keeps
--- leading the way step by step.
function TravelCard:Close()
    self.closedKey = self.shownPlan or self.closedKey
    self:Hide()
end

--- Stop: the trip ends and the arrow points straight again, as before.
function TravelCard:Stop()
    if ns.Travel then ns.Travel:StopTrip() end
    self:Hide()
end

--- Opens the world map, on the whole world when the trip crosses the sea.
function TravelCard:ShowOnMap()
    if type(InCombatLockdown) == "function" and InCombatLockdown() then return end
    local state = Host().State()
    local trip = type(state) == "table" and state.trip
    local here = Host().Here()
    local mapID
    local plan = trip and trip.plan
    if plan and here and plan.place and plan.place.continent ~= here.continent then
        mapID = ns.TravelMap and ns.TravelMap.WORLD
    elseif here then
        mapID = ns.Travel.ContinentOf(here.map)
    end
    if type(OpenWorldMap) == "function" then
        pcall(OpenWorldMap, mapID)
    elseif type(ToggleWorldMap) == "function" then
        pcall(ToggleWorldMap)
    end
    return trip
end
