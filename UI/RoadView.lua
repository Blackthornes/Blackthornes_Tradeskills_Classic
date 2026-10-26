-- Blackthornes Tradeskills -- UI/RoadView.lua
-- Road to 300 on the Level Up tab (the owner said build it, 2026-10-20,
-- from a mockup): one profession's way up as steps, from Logic/RoadPlan.lua.
--
-- A dark glass row a step, the one to do now in gold with a gold edge,
-- the ones passed ticked and dim, at the foot of the list. Above: the profession, its skill, which
-- step and a meter of the steps. Below: what the rest costs, what the
-- bags and bank take off, and Queue All. The plan is asked for only while
-- this view shows, and worked out again only when its key moves.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local RoadView = ns.NewModule("RoadView")

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local ROW_HEIGHT = 46
local RIGHT_WIDTH = 220
local METER_HEIGHT = 6

local state = { line = nil }

-- The game's own tick, since the font has no check mark.
local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t"
local widgets = {}

local function TierColorCode(tier)
    local skillUp = ns.SkillUp
    if skillUp and skillUp.GetTierColorCode then
        local ok, code = pcall(skillUp.GetTierColorCode, skillUp, tier)
        if ok and type(code) == "string" then return code end
    end
    return "|cffffffff"
end

local function Picked()
    local list = ns.RoadPlan:Professions()
    for _, profession in ipairs(list) do
        if profession.line == state.line then return profession, list end
    end
    return list[1], list
end

--- Fit a button to its words, as the other tabs do. The house button keeps
--- its words in `button.label` (it has no GetFontString), measured drawn in
--- full and at the font size, so "Show the Way" never ends in "...".
function RoadView.Fit(button)
    local label = button.label or (button.GetFontString and button:GetFontString())
    local width = label and Theme.TextWidth and Theme.TextWidth(label)
    local text = label and label.GetText and label:GetText()
    if Theme.MeasureText and type(text) == "string" then
        local ok, measured = pcall(Theme.MeasureText, "small", text)
        if ok and type(measured) == "number" then width = math.max(width or 0, measured) end
    end
    if type(width) == "number" and width > 0 then
        button:SetWidth(math.max(button:GetWidth() or 0, math.ceil(width + 20)))
    end
end
local Fit = RoadView.Fit

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function CreateRow(row)
    row.icon = Theme.CreateItemIcon(row, 16)
    row.icon:SetPoint("TOPLEFT", 8, -5)

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("TOPLEFT", 30, -6)

    row.chip = Theme.CreateLabel(row, "tiny", "accent")
    row.chip:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
    row.chipBack = row:CreateTexture(nil, "ARTWORK")
    row.chipBack:SetPoint("TOPLEFT", row.chip, "TOPLEFT", -4, 2)
    row.chipBack:SetPoint("BOTTOMRIGHT", row.chip, "BOTTOMRIGHT", 4, -2)
    row.chipBack:SetColorTexture(Theme.Unpack("glassActive"))

    row.range = Theme.CreateLabel(row, "tiny", "muted", "RIGHT")
    row.range:SetPoint("TOPRIGHT", row, "TOPRIGHT", -RIGHT_WIDTH + 90, -7)

    row.cost = Theme.CreateLabel(row, "small", "text", "RIGHT")
    row.cost:SetPoint("TOPRIGHT", row, "TOPRIGHT", -12, -6)
    row.cost:SetWidth(90)

    row.cells = {}
    row.cells.lines = Theme.CreateLabel(row, "tiny", "muted")
    row.cells.lines:SetPoint("TOPLEFT", 30, -22)
    row.cells.lines:SetPoint("RIGHT", row, "RIGHT", -RIGHT_WIDTH, 0)
    row.cells.lines:SetWordWrap(true)
    row.cells.lines:SetJustifyV("TOP")

    row.queue = Widgets.CreateButton(row, L["Queue Step"], function()
        if row.data then RoadView:QueueStep(row.data) end
    end, { width = 80, height = 18 })
    Fit(row.queue)
    row.queue:SetPoint("TOPRIGHT", row, "TOPRIGHT", -12, -22)

    row.way = Widgets.CreateButton(row, L["Show the Way"], function()
        local profession = Picked()
        if row.data and profession then
            ns.RoadPlan:ShowTheWay(row.data, profession.line, profession.name)
        end
    end, { width = 80, height = 18 })
    Fit(row.way)
end

local function UpdateRow(row, step)
    local profession = Picked()
    local texts = ns.RoadPlan.Texts(step, profession and profession.name or "", ns.RoadPlan.Level(),
        profession and profession.line)
    local plan = RoadView.plan
    local current = plan and plan.steps[plan.current] == step

    if step.kind == "craft" and step.outputItemID then
        Theme.SetItemIcon(row.icon, step.outputItemID)
        row.icon:Show()
    else
        row.icon:Hide()
    end

    local title = texts.title
    if step.done then
        title = CHECK .. " " .. title
        row.name:SetTextColor(Theme.Unpack("dim"))
    elseif step.kind == "craft" then
        title = TierColorCode(step.tier or (step.orange and "optimal" or "medium")) .. title .. "|r"
        row.name:SetTextColor(Theme.Unpack("text"))
    else
        row.name:SetTextColor(Theme.Unpack(current and "accentHi" or "accent"))
    end
    row.name:SetText(title)

    row.chip:SetText(texts.chip or "")
    row.chip:SetShown(texts.chip ~= nil)
    row.chipBack:SetShown(texts.chip ~= nil)
    if step.locked then row.chip:SetTextColor(Theme.Unpack("loss")) else row.chip:SetTextColor(Theme.Unpack("accent")) end

    row.range:SetText(texts.range or "")

    if step.done then
        row.cost:SetText(L["Done"])
        row.cost:SetTextColor(Theme.Unpack("dim"))
    else
        row.cost:SetTextColor(Theme.Unpack("text"))
        Theme.SetMoneyText(row.cost, step.cost or 0, { short = true })
    end

    local text = table.concat(texts.lines, "\n")
    local lines = row.cells.lines
    lines:SetText(text)
    local ok, height = pcall(lines.GetStringHeight, lines)
    lines.rowNeed = 22 + (ok and type(height) == "number" and height or 12) + 4
    lines.rowNeedText = text

    local place = not step.done and ns.RoadPlan:PlaceFor(step, profession and profession.line)
    row.queue:SetShown(not step.done and step.kind == "craft")
    row.way:ClearAllPoints()
    if row.queue:IsShown() then
        row.way:SetPoint("TOPRIGHT", row.queue, "TOPLEFT", -6, 0)
    else
        row.way:SetPoint("TOPRIGHT", row, "TOPRIGHT", -12, -22)
    end
    row.way:SetShown(place ~= nil and place ~= false)
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

function RoadView:Build(view)
    local toolbar = CreateFrame("Frame", nil, view)
    toolbar:SetPoint("TOPLEFT", 8, -8)
    toolbar:SetPoint("TOPRIGHT", -8, -8)
    toolbar:SetHeight(24)

    widgets.dropdown = Widgets.CreateDropdown(toolbar, {}, function(value)
        state.line = value
        if widgets.list then widgets.list:ScrollToTop() end
        RoadView:Refresh()
    end, { width = 150 })
    widgets.dropdown:SetPoint("LEFT", 0, 0)

    widgets.heading = Theme.CreateLabel(toolbar, "normal", "accent")
    widgets.heading:SetPoint("LEFT", widgets.dropdown, "RIGHT", 14, 0)

    widgets.stepOf = Theme.CreateLabel(toolbar, "small", "muted", "RIGHT")
    widgets.stepOf:SetPoint("RIGHT", 0, 0)

    -- The meter: one piece a step, gold up to the step to do now.
    local meter = CreateFrame("Frame", nil, view)
    meter:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -6)
    meter:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -6)
    meter:SetHeight(METER_HEIGHT)
    widgets.meter = meter
    widgets.pieces = {}

    local footer = CreateFrame("Frame", nil, view)
    footer:SetPoint("BOTTOMLEFT", 8, 8)
    footer:SetPoint("BOTTOMRIGHT", -8, 8)
    footer:SetHeight(40)

    widgets.queueAll = Widgets.CreateButton(footer, L["Queue All"], function()
        local count = ns.RoadPlan:QueueAll(RoadView.plan)
        ns.Print(L.Format("%d queued", count))
    end, { width = 100, height = 24, primary = true })
    Fit(widgets.queueAll)
    widgets.queueAll:SetPoint("RIGHT", 0, 0)

    widgets.totalLabel = Theme.CreateLabel(footer, "normal", "text")
    widgets.totalLabel:SetPoint("TOPLEFT", 0, -2)
    widgets.totalLabel:SetText(L["To 300:"])
    widgets.total = Theme.CreateLabel(footer, "normal", "text")
    widgets.total:SetPoint("LEFT", widgets.totalLabel, "RIGHT", 8, 0)

    widgets.saved = Theme.CreateLabel(footer, "small", "muted")
    widgets.saved:SetPoint("TOPLEFT", widgets.totalLabel, "BOTTOMLEFT", 0, -4)
    widgets.saved:SetPoint("RIGHT", widgets.queueAll, "LEFT", -12, 0)
    widgets.saved:SetWordWrap(true)

    local well = CreateFrame("Frame", nil, view)
    well:SetPoint("TOPLEFT", meter, "BOTTOMLEFT", 0, -8)
    well:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", 0, 8)
    if Theme.Recess then Theme.Recess(well) end

    widgets.list = Widgets.CreateScrollList(well, {
        rowHeight = ROW_HEIGHT,
        createRow = CreateRow,
        updateRow = UpdateRow,
        isSelected = function(step)
            local plan = RoadView.plan
            return plan ~= nil and plan.current ~= nil and plan.steps[plan.current] == step
        end,
    })
    widgets.list:SetAllPoints(well)

    widgets.empty = Theme.CreateLabel(well, "small", "muted", "CENTER")
    widgets.empty:SetPoint("CENTER")
    widgets.empty:SetWidth(360)
    widgets.empty:SetWordWrap(true)

    self.built = true
end

local function DrawMeter(plan)
    local meter, pieces = widgets.meter, widgets.pieces
    local steps = plan and plan.steps or {}
    local width = meter:GetWidth()
    if type(width) ~= "number" or width <= 0 then width = 600 end
    local count = #steps
    local gap = 2
    local each = count > 0 and (width - gap * (count - 1)) / count or 0
    for index = 1, math.max(count, #pieces) do
        local piece = pieces[index]
        if index <= count then
            if not piece then
                piece = meter:CreateTexture(nil, "ARTWORK")
                pieces[index] = piece
            end
            piece:ClearAllPoints()
            piece:SetPoint("TOPLEFT", (index - 1) * (each + gap), 0)
            piece:SetSize(math.max(1, each), METER_HEIGHT)
            local key = steps[index].done and "metal"
                or (index == plan.current and "accentHi")
                or "border"
            piece:SetColorTexture(Theme.Unpack(key))
            piece:Show()
        elseif piece then
            piece:Hide()
        end
    end
end

function RoadView:Refresh()
    if not self.built then return end
    local profession, list = Picked()

    local options = {}
    for _, entry in ipairs(list) do options[#options + 1] = { text = entry.name, value = entry.line } end
    widgets.dropdown:SetOptions(options)
    state.line = profession and profession.line or nil
    widgets.dropdown:SetValue(state.line)

    if not profession then
        self.plan = nil
        widgets.heading:SetText("")
        widgets.stepOf:SetText("")
        widgets.list:SetData({})
        widgets.empty:SetText(L["Learn a profession to see its road."])
        widgets.empty:Show()
        widgets.total:SetText("")
        widgets.saved:SetText("")
        DrawMeter(nil)
        return
    end

    widgets.heading:SetText(("%s  %d / %d"):format(profession.name:upper(), profession.skill, profession.max))

    local plan = ns.RoadPlan:Get(profession, function()
        if widgets.list and widgets.list:IsVisible() then RoadView:Refresh() end
    end)
    self.plan = plan
    if not plan then
        widgets.list:SetData({})
        widgets.empty:Hide()
        return
    end

    widgets.list:SetData(ns.RoadPlan.Shown(plan.steps))
    if plan.current then
        widgets.stepOf:SetText(L.Format("Step %d of %d", plan.current, #plan.steps))
    else
        widgets.stepOf:SetText("")
    end
    DrawMeter(plan)

    if plan.stuck then
        widgets.empty:SetText(#plan.steps == 0 and L.Format("Nothing found to level past %d yet.", plan.stuck) or "")
        widgets.empty:SetShown(#plan.steps == 0)
    else
        widgets.empty:Hide()
    end

    Theme.SetMoneyText(widgets.total, plan.total or 0, { short = true })
    if (plan.saved or 0) > 0 then
        widgets.saved:SetText(L.Format("What you own already takes off %s.",
            Util.FormatMoney(plan.saved, { short = true })))
    elseif plan.stuck then
        widgets.saved:SetText(L.Format("Nothing found to level past %d yet.", plan.stuck))
    else
        widgets.saved:SetText("")
    end
end

--- Queue Step, with a line in chat.
function RoadView:QueueStep(step)
    if not ns.RoadPlan:QueueStep(step) then return end
    if step.learn then
        ns.Print(L.Format("You don't know %s yet, so its materials went on your list to buy. It goes in your queue once you learn it.", step.name))
    else
        ns.Print(L.Format("queued %dx %s", step.crafts, step.name))
    end
end

--- Open on a profession, by its Classic skill line.
function RoadView:Pick(line)
    state.line = line
    if self.built then self:Refresh() end
end
