-- Blackthornes Tradeskills -- UI/ListRulesWindow.lua
-- "Rules for NAME": the rules a list on the Lists view gives everything on
-- it (Logic/ListRules.lua), from the Rules button under an open list (the
-- owner said build it, 2026-10-19, from a mockup; every word his).
--
-- Two sections of dark glass rows: WHEN YOU SELL (Lowest Price, Highest
-- Price, When Cheaper, Keep Listed, Post For, Keep in Bags) and WHEN YOU BUY
-- (Most I'll Pay), then
-- "An item's own setting still wins." and Clear. An empty box is no rule.
-- Each change is saved as it is made, and nothing else is touched.
--
-- Also the small gold tag ("chip") the Lists view and the Sell list put on
-- a row: CreateChip.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local ListRulesUI = ns.NewModule("ListRulesUI")

local Theme = ns.Theme
local Widgets = ns.Widgets

local WIDTH = 420
local INSET = 14
local ROW_HEIGHT = 32
local LABEL_WIDTH = 108
local HEADING_HEIGHT = 24

--------------------------------------------------------------------------------
-- The tag
--------------------------------------------------------------------------------

--- A small tag with a gold edge: a list's name, "N rules" or "Own price".
-- chip:Set(text, kind, hover) shows it ("own" draws it blue), chip:Set(nil)
-- hides it.
function ListRulesUI.CreateChip(parent)
    local chip = CreateFrame("Frame", nil, parent)
    chip:SetHeight(14)
    chip.fill = Theme.Fill(chip, "glassActive", 0.95)
    Theme.Border(chip, "metal", 0.9)
    chip.label = Theme.CreateLabel(chip, "tiny", "accentHi", "CENTER")
    chip.label:SetPoint("CENTER", 0, 0)
    chip:EnableMouse(true)
    chip:Hide()

    function chip:Set(text, kind, hover)
        if not text then
            self.hover = nil
            self:Hide()
            return
        end
        self.label:SetText(text)
        if kind == "own" then
            self.label:SetTextColor(Theme.Unpack("rested"))
            Theme.SetBorderColor(self, "alliance", 0.9)
        else
            self.label:SetTextColor(Theme.Unpack("accentHi"))
            Theme.SetBorderColor(self, "metal", 0.9)
        end
        local width = Theme.TextWidth and Theme.TextWidth(self.label) or nil
        self:SetWidth(math.max(24, (tonumber(width) or (#text * 6)) + 12))
        self.hover = hover
        self:Show()
    end

    chip:SetScript("OnEnter", function(self)
        if not self.hover then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(self.hover, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    chip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return chip
end

--- "1 rule" or "N rules", for the Lists view.
function ListRulesUI.CountText(count)
    if not count or count < 1 then return nil end
    return count == 1 and L["1 rule"] or L.Format("%d rules", count)
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

local function Rules() return ns.ListRules end

-- Lowest Price is a set price, or a percent of the market price or of what
-- one cost to make (2026-10-28, the owner said build it).
local FLOOR_KINDS = {
    { text = L["Set Price"], value = "floor" },
    { text = L["% of Market"], value = "floorMarket" },
    { text = L["% of Cost"], value = "floorCost" },
}
local UNDER_KINDS = {
    { text = L["List Anyway"], value = "list" },
    { text = L["Wait"], value = "wait" },
}

--- A hover on a frame: a title and lines under it.
local function Hover(frame, title, lines)
    frame:EnableMouse(true)
    local before = frame.GetScript and frame:GetScript("OnEnter")
    local after = frame.GetScript and frame:GetScript("OnLeave")
    frame:SetScript("OnEnter", function(self, ...)
        if before then before(self, ...) end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(title, 1, 1, 1)
        for _, line in ipairs(lines) do GameTooltip:AddLine(line, 0.9, 0.9, 0.9, true) end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function(self, ...)
        if after then after(self, ...) end
        GameTooltip:Hide()
    end)
end

--- A row of dark glass with its label, by place.
local function Row(frame, y, place, text)
    local row = CreateFrame("Frame", nil, frame)
    row:SetPoint("TOPLEFT", INSET, y)
    row:SetPoint("TOPRIGHT", -INSET, y)
    row:SetHeight(ROW_HEIGHT)
    Theme.Fill(row, place % 2 == 1 and "glass" or "glassAlt")
    local line = row:CreateTexture(nil, "BORDER")
    line:SetColorTexture(Theme.Unpack("border", 0.6))
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")

    local label = Theme.CreateLabel(row, "small", "text")
    label:SetPoint("LEFT", 8, 0)
    label:SetWidth(LABEL_WIDTH)
    label:SetText(text)
    row.label = label
    return row
end

local function Heading(frame, y, text)
    local heading = Theme.CreateHeading(frame, text, "small")
    heading:SetPoint("TOPLEFT", INSET, y - 6)
    return heading
end

local function Note(row, anchor, text)
    local note = Theme.CreateLabel(row, "small", "muted")
    note:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
    note:SetText(text)
    return note
end

--- A number box with - and + beside it; empty is no rule.
local function Counter(row, field, max)
    local minus = Widgets.CreateButton(row, "-", function()
        local value = (row.box:GetValue() or 0) - 1
        ListRulesUI:Save(field, value > 0 and value or nil)
    end, { width = 20, height = 20 })
    minus:SetPoint("LEFT", row.label, "RIGHT", 0, 0)

    row.box = Widgets.CreateNumberBox(row, {
        width = 52, height = 20, min = 1, max = max, background = "panel",
        allowEmpty = true, justify = "CENTER",
        onChange = function(value) ListRulesUI:Save(field, value) end,
    })
    row.box:SetPoint("LEFT", minus, "RIGHT", 4, 0)

    local plus = Widgets.CreateButton(row, "+", function()
        ListRulesUI:Save(field, math.min(max, (row.box:GetValue() or 0) + 1))
    end, { width = 20, height = 20 })
    plus:SetPoint("LEFT", row.box, "RIGHT", 4, 0)
    return plus
end

--- Gold, silver and copper boxes (the price editor's); 0 is no rule.
local function Money(row, field, anchor)
    local make = ns.PriceEditor and ns.PriceEditor.MoneyBoxes
    if not make then return nil end
    local money = make(row, function(copper) ListRulesUI:Save(field, copper) end)
    money:SetPoint("LEFT", anchor or row.label, "RIGHT", anchor and 8 or 0, 0)
    return money
end

--- Lowest Price: which kind, then money boxes or a percent box.
function ListRulesUI:BuildFloor(row)
    self.floorKind = Widgets.CreateDropdown(row, FLOOR_KINDS, function(kind)
        ListRulesUI:PickFloor(kind)
    end, { width = 110 })
    self.floorKind:SetPoint("LEFT", row.label, "RIGHT", 0, 0)
    self.floorKind.menu:SetFrameStrata("FULLSCREEN_DIALOG")

    -- Each kind's boxes sit in a holder, so the other kind's can hide.
    local money = CreateFrame("Frame", nil, row)
    money:SetSize(170, ROW_HEIGHT)
    money:SetPoint("LEFT", self.floorKind, "RIGHT", 0, 0)
    self.floorMoneyHolder = money
    local make = ns.PriceEditor and ns.PriceEditor.MoneyBoxes
    if make then
        self.floor = make(money, function(copper) ListRulesUI:Save("floor", copper) end)
        self.floor:SetPoint("LEFT", money, "LEFT", 8, 0)
    end

    local percent = CreateFrame("Frame", nil, row)
    percent:SetSize(90, ROW_HEIGHT)
    percent:SetPoint("LEFT", self.floorKind, "RIGHT", 0, 0)
    self.floorPercentHolder = percent
    self.floorPercent = Widgets.CreateNumberBox(percent, {
        width = 52, height = 20, min = 1, max = Rules().MAX_PERCENT, background = "panel",
        allowEmpty = true, justify = "CENTER",
        onChange = function(value)
            local kind = ListRulesUI.floorPick
            if kind == "floorMarket" or kind == "floorCost" then ListRulesUI:Save(kind, value) end
        end,
    })
    self.floorPercent:SetPoint("LEFT", percent, "LEFT", 8, 0)
    local mark = Theme.CreateLabel(percent, "small", "text")
    mark:SetPoint("LEFT", self.floorPercent, "RIGHT", 4, 0)
    mark:SetText(L["%"])

    Hover(row, L["Lowest Price"], {
        L["The least it lists for. Pick a set price, or a percent of the market price or of what it cost to make, so one rule fits every item on the list."],
    })
end

--- A new kind of Lowest Price: the old one comes off, and the box is empty
--- until a number goes in.
function ListRulesUI:PickFloor(kind)
    if self.drawing or not self:List() then return end
    self.floorPick = kind
    for _, field in ipairs(Rules().FLOORS) do
        if field ~= kind then Rules():Set(self.index, field, nil) end
    end
    self:Save(kind, nil)
end

function ListRulesUI:Build()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", "BlackthornesTSListRules", UIParent)
    frame:SetWidth(WIDTH)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()

    Theme.Fill(frame, "window")
    if ns.Titanforged then
        ns.Titanforged:Dress(frame, { title = L["Rules"], close = function() ListRulesUI:Hide() end })
    else
        Theme.AddGameOutline(frame, { style = "dialog", color = "natural" })
    end
    if Theme.Halo then Theme.Halo(frame, 10, 0.10) end
    if type(UISpecialFrames) == "table" then tinsert(UISpecialFrames, "BlackthornesTSListRules") end

    local y = -32
    Heading(frame, y, L["WHEN YOU SELL"])
    y = y - HEADING_HEIGHT

    local floor = Row(frame, y, 1, L["Lowest Price:"])
    self:BuildFloor(floor)
    y = y - ROW_HEIGHT

    local high = Row(frame, y, 2, L["Highest Price:"])
    self.high = Money(high, "high")
    Hover(high, L["Highest Price"], {
        L["The most it lists for. When the auction house asks more, it lists at this price."],
    })
    y = y - ROW_HEIGHT

    local under = Row(frame, y, 3, L["When Cheaper:"])
    self.under = Widgets.CreateDropdown(under, UNDER_KINDS, function(value)
        ListRulesUI:Save("wait", value == "wait" and 1 or nil)
    end, { width = 118 })
    self.under:SetPoint("LEFT", under.label, "RIGHT", 0, 0)
    self.under.menu:SetFrameStrata("FULLSCREEN_DIALOG")
    Hover(under, L["When Cheaper"], {
        L["What to do when others sell it for less than your price."],
        L["List Anyway: list it at your price."],
        L["Wait: keep it in your bags until the price comes back up."],
    })
    y = y - ROW_HEIGHT

    local listed = Row(frame, y, 4, L["Keep Listed:"])
    Note(listed, Counter(listed, "listed", Rules().MAX_LISTED), L["stacks at a time"])
    self.listed = listed.box
    y = y - ROW_HEIGHT

    local duration = Row(frame, y, 5, L["Post For:"])
    -- A drop-down of the three lengths (the owner, 2026-10-23: drop-downs,
    -- never < > pickers). With no rule it shows the drawer's, dimmed.
    local lengths = (ns.Posting and ns.Posting.DURATIONS) or {}
    self.duration = Widgets.CreateDropdown(duration, lengths, function(value)
        ListRulesUI:Save("duration", value)
    end, { width = 110 })
    self.duration:SetPoint("LEFT", duration.label, "RIGHT", 0, 0)
    -- Over the rows below it, not under them.
    self.duration.menu:SetFrameStrata("FULLSCREEN_DIALOG")
    self.durationText = self.duration.label
    y = y - ROW_HEIGHT

    local bags = Row(frame, y, 6, L["Keep in Bags:"])
    Note(bags, Counter(bags, "bags", Rules().MAX_BAGS), L["of each"])
    self.bags = bags.box
    y = y - ROW_HEIGHT - 8

    Heading(frame, y, L["WHEN YOU BUY"])
    y = y - HEADING_HEIGHT

    local pay = Row(frame, y, 1, L["Most I'll Pay:"])
    self.maxPay = Money(pay, "maxPay")
    if self.maxPay then
        local last = self.maxPay.copper
        local each = Theme.CreateLabel(pay, "small", "muted")
        each:SetPoint("LEFT", last, "RIGHT", 16, 0)
        each:SetText(L["each"])
    end
    y = y - ROW_HEIGHT - 10

    local foot = Theme.CreateLabel(frame, "small", "muted")
    foot:SetPoint("TOPLEFT", INSET, y - 6)
    foot:SetText(L["An item's own setting still wins."])

    self.clear = Widgets.CreateButton(frame, L["Clear"], function()
        if ListRulesUI:List() then Rules():Clear(ListRulesUI.index) end
        ListRulesUI:Draw()
    end, { width = 70, height = 22 })
    self.clear:SetPoint("TOPRIGHT", -INSET, y)

    frame:SetHeight(-y + 22 + INSET)
    self.frame = frame
    return frame
end

--- The list shown and its place now, or nil when it is gone. Held by the
--- list itself, since deleting one above it moves its place.
function ListRulesUI:List()
    local held = self.held
    if not (held and ns.ShoppingLists) then return nil end
    for index, list in ipairs(ns.ShoppingLists:All()) do
        if list == held then
            self.index = index
            return list
        end
    end
    self.index = nil
    return nil
end

--- Open the rules of the list at `index`, beside `anchor` when given.
function ListRulesUI:Open(index, anchor)
    if not (ns.ShoppingLists and ns.ShoppingLists:Get(index)) then return end
    local frame = self:Build()
    self.index, self.held = index, ns.ShoppingLists:Get(index)
    self.floorPick = nil
    frame:ClearAllPoints()
    if anchor and anchor.GetRight then
        frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 8, 0)
    else
        frame:SetPoint("CENTER")
    end
    frame:Show()
    if ns.Titanforged and ns.Titanforged.Opened then pcall(ns.Titanforged.Opened, ns.Titanforged, frame) end
    self:Draw()
end

function ListRulesUI:Toggle(index, anchor)
    if self.frame and self.frame:IsShown() and self:List() and self.index == index then return self:Hide() end
    self:Open(index, anchor)
end

function ListRulesUI:Hide()
    if self.frame then self.frame:Hide() end
    self.index, self.held, self.floorPick = nil, nil, nil
end

--- Save one rule and show it again, and let the Lists view redraw.
function ListRulesUI:Save(field, value)
    if self.drawing or not self:List() then return end
    Rules():Set(self.index, field, value)
    self:Draw()
    if ns.ShoppingListsView and ns.ShoppingListsView.Refresh then
        pcall(ns.ShoppingListsView.Refresh, ns.ShoppingListsView, true)
    end
end

function ListRulesUI:Draw()
    local list = self:List()
    if not list then return self:Hide() end
    if not self.frame then return end
    local rules = Rules().Of(list)

    -- The plate names the list, and grows to fit it.
    self.title = L.Format("Rules for %s", list.name)
    local trim = rawget(self.frame, "titan")
    local plate = type(trim) == "table" and rawget(trim, "plate")
    if type(plate) == "table" and type(plate.SetTitle) == "function" then pcall(plate.SetTitle, plate, self.title) end

    -- The kind set wins; with none set, the one last picked, else Set Price.
    local kind = (rules.floorMarket and "floorMarket") or (rules.floorCost and "floorCost")
        or (rules.floor and "floor") or self.floorPick or "floor"
    self.floorPick = kind
    local percent = kind ~= "floor"

    self.drawing = true
    self.floorKind:SetValue(kind)
    self.floorMoneyHolder:SetShown(not percent)
    self.floorPercentHolder:SetShown(percent)
    if self.floor then self.floor:Set(rules.floor or 0) end
    self.floorPercent:SetValue(percent and rules[kind] or nil, true)
    if self.high then self.high:Set(rules.high or 0) end
    self.under:SetValue(rules.wait and "wait" or "list")
    if self.maxPay then self.maxPay:Set(rules.maxPay or 0) end
    self.listed:SetValue(rules.listed, true)
    self.bags:SetValue(rules.bags, true)
    self.drawing = nil

    if rules.duration then
        self.duration:SetValue(rules.duration)
        self.durationText:SetTextColor(Theme.Unpack("text"))
    else
        self.duration:SetValue((ns.Config and ns.Config:Get("postDuration")) or 2)
        self.durationText:SetTextColor(Theme.Unpack("dim"))
    end
end
