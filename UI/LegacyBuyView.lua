-- Blackthornes Tradeskills -- UI/LegacyBuyView.lua
-- The buy plan on the drawer's Buy view, on Era's older auction house.
--
-- A click on a Buy row (or its Search) opens the plan for that item at the
-- foot of the list: the cheapest stacks that cover the need, the next one
-- lit, what they come to, and one gold button that buys one stack a click
-- (Logic/LegacyBuy.lua works it all out). The same row again closes it.
-- Only on a client with the older auction house; Forever's Buy view is
-- untouched.

local _, ns = ...

local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local LegacyBuyView = ns.NewModule("LegacyBuyView")

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local STACK_ROW = 20
local STACKS_SHOWN = 5
local PAD = 8

function LegacyBuyView:Applies()
    return ns.LegacyBuy ~= nil and ns.LegacyBuy:Applies()
end

--- A click on a Buy row: open its plan, or close it when it is the one open.
-- @return true when the click was this view's
function LegacyBuyView:Toggle(line)
    if not self:Applies() or type(line) ~= "table" or type(line.itemID) ~= "number" then return false end
    local buy = ns.LegacyBuy
    if buy:IsOpenFor(line.itemID) then
        buy:Close()
    elseif not buy:Open(line.itemID, line.shortfall) then
        return false
    end
    return true
end

-- The name is the row's `name`, set through Theme.SetRowName, so a long one
-- drops a size and wraps and the scroll list grows that row to fit.
local function StackRow(row)
    row.name = Theme.CreateLabel(row, "small", "text", "LEFT")
    row.name:SetPoint("LEFT", row, "LEFT", 8, 0)
    row.right = Theme.CreateLabel(row, "small", "text", "RIGHT")
    row.right:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.name:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
    row.left = row.name
end

local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t "

local function UpdateStackRow(row, entry)
    local state = ns.LegacyBuy.state
    local name = state and state.name or ""
    local text = ("%d %s"):format(entry.count, name)
    if entry.bought then
        Theme.SetRowName(row.name, CHECK .. "|c" .. ns.COLORS.profit .. text .. "|r")
    else
        Theme.SetRowName(row.name, text)
    end
    local each = Util.FormatMoney(Util.UnitPriceFromStack(state and state.itemID, entry.buyout, entry.count)
        or math.floor(entry.buyout / entry.count))
    row.right:SetText(Util.FormatMoney(entry.buyout) .. "  |c" .. ns.COLORS.muted
        .. "(" .. L.Format("%s each", each) .. ")|r")
end

--- Built inside the drawer, at the foot of the Buy list.
function LegacyBuyView:Build(body, frame, opts)
    if self.panel or not self:Applies() then return end
    local panel = CreateFrame("Frame", nil, body)
    panel:SetPoint("LEFT", frame, "LEFT", opts.edge + 3, 0)
    panel:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
    panel:SetPoint("BOTTOM", frame, "BOTTOM", 0, opts.bottom)
    Theme.Fill(panel, "well")
    Theme.Border(panel, "border", 0.8)
    panel:Hide()
    self.panel = panel

    local heading = Theme.CreateLabel(panel, "tiny", "accent", "LEFT")
    heading:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -6)
    heading:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)
    self.heading = heading

    local stacks = Widgets.CreateScrollList(panel, {
        rowHeight = STACK_ROW,
        createRow = StackRow,
        updateRow = UpdateStackRow,
        isSelected = function(entry)
            local state = ns.LegacyBuy.state
            return state and state.plan and state.plan.stacks[1] == entry or false
        end,
    })
    stacks:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", -PAD + 1, -4)
    stacks:SetPoint("RIGHT", panel, "RIGHT", -1, 0)
    self.stacks = stacks

    local summary = Theme.CreateLabel(panel, "small", "text", "LEFT")
    summary:SetPoint("LEFT", panel, "LEFT", PAD, 0)
    summary:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)
    summary:SetWordWrap(true)
    self.summary = summary

    local note = Theme.CreateLabel(panel, "tiny", "muted", "LEFT")
    note:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -3)
    note:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)
    note:SetWordWrap(true)
    self.note = note

    local button = Widgets.CreateButton(body, "", function()
        -- The plan is done: open the next line's.
        local nextLine = LegacyBuyView.nextLine
        if nextLine then
            LegacyBuyView.nextLine = nil
            if ns.PostPanel then ns.PostPanel:OpenShoppingLine(nextLine) end
            return
        end
        ns.LegacyBuy:Buy()
        LegacyBuyView:Refresh()
    end, { width = 150, height = 22, primary = true })
    button:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(opts.edge + 6), opts.edge + 6)
    button:Hide()
    self.button = button
end

-- A plan the Disenchanting tab's Buy button opened is that tab's to show.
local function DrawerPlan()
    local buy = ns.LegacyBuy
    local state = buy and buy.state
    if state and state.source == "disenchant" then return nil end
    return state
end

function LegacyBuyView:IsOpen()
    return self.panel ~= nil and DrawerPlan() ~= nil
end

--- What the summary says for a plan.
function LegacyBuyView.SummaryText(plan)
    local total = Util.FormatMoney(plan.total)
    local count = #plan.stacks
    if count == 1 then
        if plan.extra > 0 then
            return L.Format("1 stack, %d in all (%d extra). Total %s.", plan.units, plan.extra, total)
        end
        return L.Format("1 stack, %d in all. Total %s.", plan.units, total)
    end
    if plan.extra > 0 then
        return L.Format("%d stacks, %d in all (%d extra). Total %s.", count, plan.units, plan.extra, total)
    end
    return L.Format("%d stacks, %d in all. Total %s.", count, plan.units, total)
end

--- The rows: stacks bought this time first, then the plan.
local function Rows(state)
    local rows = {}
    for _, stack in ipairs(state.boughtStacks or {}) do rows[#rows + 1] = stack end
    for _, stack in ipairs(state.plan and state.plan.stacks or {}) do rows[#rows + 1] = stack end
    return rows
end

function LegacyBuyView:Refresh()
    if not self.panel then return end
    local buy = ns.LegacyBuy
    local state = DrawerPlan()
    local onBuy = ns.PostPanel and ns.PostPanel.view == "buy"
    if not state or not onBuy then
        self.panel:Hide()
        self.button:Hide()
        return
    end

    self.heading:SetText(L.Format("CHEAPEST WAY TO GET %d", state.need))

    local rows = Rows(state)
    local shown = math.min(math.max(#rows, 0), STACKS_SHOWN)
    self.stacks:SetHeight(math.max(shown, 0) * STACK_ROW)
    self.stacks:SetShown(shown > 0)
    self.stacks:SetData(rows)

    local plan = state.plan
    local summaryText, noteText = "", ""
    if state.status == "reading" and not plan then
        summaryText = L["Looks up every listing of this item."]
    elseif plan then
        local all = { stacks = {}, units = 0, total = 0, extra = 0 }
        for _, stack in ipairs(rows) do
            all.stacks[#all.stacks + 1] = stack
            all.units = all.units + stack.count
            all.total = all.total + stack.buyout
        end
        all.extra = math.max(0, all.units - state.need)
        if #all.stacks > 0 then summaryText = LegacyBuyView.SummaryText(all) end
        local notes = {}
        if plan.skipped then notes[#notes + 1] = L["Stacks that cost too much were left out."] end
        if plan.short > 0 then
            notes[#notes + 1] = "|c" .. ns.COLORS.loss
                .. L.Format("Not enough for sale. You still need %d.", plan.short) .. "|r"
        end
        noteText = table.concat(notes, "\n")
    end

    self.summary:ClearAllPoints()
    if shown > 0 then
        self.summary:SetPoint("TOPLEFT", self.stacks, "BOTTOMLEFT", PAD - 1, -6)
    else
        self.summary:SetPoint("TOPLEFT", self.heading, "BOTTOMLEFT", 0, -6)
    end
    self.summary:SetPoint("RIGHT", self.panel, "RIGHT", -PAD, 0)
    self.summary:SetText(summaryText)
    self.note:SetText(noteText)
    self.note:SetShown(noteText ~= "")

    local height = 6 + (self.heading:GetStringHeight() or 10) + 4 + shown * STACK_ROW
        + 6 + (self.summary:GetStringHeight() or 12)
        + (noteText ~= "" and (3 + (self.note:GetStringHeight() or 10)) or 0) + 8
    self.panel:SetHeight(height)
    self.panel:Show()

    local stack, ready = buy:Next()
    self.nextLine = nil
    local label
    if stack and state.status ~= "done" then
        label = L.Format("Buy %d for %s", stack.count, Util.FormatMoney(stack.buyout, { icons = true }))
    elseif state.status == "done" then
        -- Done here: the next thing on the Buy list that still needs buying.
        local nextLine = ns.PostPanel and ns.PostPanel.NextBuyLine and ns.PostPanel:NextBuyLine(state.itemID)
        local name = nextLine and Util.GetItemName(nextLine.itemID)
        if name then
            self.nextLine = nextLine
            label = L.Format("Next: %s", name)
            ready = true
        end
    end
    if label then
        self.button:SetText(label)
        local width = Theme.MeasureText and Theme.MeasureText("small", label)
        self.button:SetWidth(math.max(150, (width or 0) + 24))
        self.button:SetEnabledState(ready)
        self.button:Show()
    else
        self.button:Hide()
    end
end

--- How much room the plan takes at the foot of the list, 0 when closed.
function LegacyBuyView:Height()
    if not (self.panel and self.panel:IsShown()) then return 0 end
    return self.panel:GetHeight() or 0
end
