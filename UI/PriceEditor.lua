-- Blackthornes Tradeskills -- UI/PriceEditor.lua
-- Your own price for one listing, from Ready to sell.
--
-- Asked 2026-10-08: a player wanted to sell under market value to get rid of
-- a bad buy, and was going back to the plain auction house to type the price.
-- "Some way to super easily see the suggested price, 7s 21c, and change that
-- to 6s. Then I can easily see 6 units * 6s = 36s total. Or change the 43s 26c
-- to 40s and have it broken up by unit."
--
-- So: the price each, how many, and the total, all three editable and kept in
-- step, with the suggested price beside them and one click back to it. The
-- price lasts the session (Posting.chosenPrice); keeping it for good is the
-- Prices tab's "Use this price", offered here as a tick box, off unless ticked.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local PriceEditor = ns.NewModule("PriceEditor")

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local WIDTH = 320
local HEIGHT = 300

-- Below the notes: a gap, the tick box, a gap, the buttons and the margin
-- under them. The notes wrap to as many lines as they need, and the window
-- grows to fit them (the first in-game look had them running into the tick
-- box, 2026-10-08).
local BELOW_NOTES = 10 + 18 + 12 + 24 + 14

-- From the window's top to the notes, for the first draw, before the game
-- has laid the window out and can say.
local NOTES_TOP = 190
local INSET = 18
local LABEL_WIDTH = 64

--------------------------------------------------------------------------------
-- Sums, kept apart from the frame so they can be tested
--------------------------------------------------------------------------------

--- Whether the game says this item is a commodity: nil when it cannot tell.
local function IsCommodity(line)
    if line.isCommodity ~= nil then return line.isCommodity end
    if ns.Scanner and ns.Scanner.IsCommodity then return ns.Scanner:IsCommodity(line.itemID) end
    return nil
end

--- The market value, from the scans alone (a price of the player's own is
--- not the market).
local function Market(itemID)
    local prices = ns.Prices
    if not prices then return nil end
    local ok, value
    if prices.GetScanValue then
        ok, value = pcall(prices.GetScanValue, prices, itemID, "market")
    else
        ok, value = pcall(prices.GetValue, prices, itemID, "market")
    end
    return ok and type(value) == "number" and value > 0 and value or nil
end

--- What to tell the player about a price, worst first.
-- @return list of { text, colour }, and whether listing would be refused
function PriceEditor.Notes(line, price, quantity)
    local notes, refused = {}, false
    if not price then
        notes[1] = { L["Type a price each, or a total."], "muted" }
        return notes, true
    end

    local Posting = ns.Posting
    local function Money(copper) return Util.FormatMoney(copper, { noColor = true }) end

    local floor, why = Posting:GetPriceFloor(line.itemID, true)
    if floor and price < floor then
        notes[#notes + 1] = { L.Format("Under %s each: %s, so it will not be listed.", Money(floor), why or L["too low"]), "loss" }
        refused = true
    end

    local cost = Posting:BelowCost(line.itemID, price)
    if cost then
        notes[#notes + 1] = { L.Format("Under the %s the materials cost. Turn on '%s' in Settings to list it.",
            Money(cost), L["Recommend selling at a loss"]), "loss" }
        refused = true
    end

    local paid = Posting:BelowCraftedCost(line.itemID, price)
    if paid then
        notes[#notes + 1] = { L.Format("Under the %s you paid to make it. Turn off '%s' in Settings to list it.",
            Money(paid), L["Never below what I paid"]), "loss" }
        refused = true
    end

    local market = Market(line.itemID)
    if market and price < market then
        local under = math.floor((market - price) / market * 100 + 0.5)
        if under >= 1 then
            notes[#notes + 1] = { L.Format("%d%% under market value (%s each).", under, Money(market)), "warn" }
        end
    elseif market and price > market then
        local over = math.floor((price - market) / market * 100 + 0.5)
        if over >= 1 then
            notes[#notes + 1] = { L.Format("%d%% over market value (%s each).", over, Money(market)), "muted" }
        end
    end

    if IsCommodity(line) == false and ns.Util.SilverOnly() then
        notes[#notes + 1] = { L["Gear is listed in whole silver."], "muted" }
    end

    if not refused and ns.Profit and ns.Profit.NetFromListing then
        local ok, net = pcall(ns.Profit.NetFromListing, ns.Profit, line.itemID, price)
        if ok and type(net) == "number" then
            notes[#notes + 1] = { L.Format("You get about %s after the auction house's cut.",
                Money(math.max(0, math.floor(net * (quantity or 1))))), "muted" }
        end
    end

    return notes, refused
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

--- Gold, silver and copper boxes in a row, read and set as copper.
local function MoneyBoxes(parent, onCommit)
    local money = { boxes = {} }
    local last

    local function Coin(width, max, suffix)
        local box = Widgets.CreateNumberBox(parent, {
            width = width, height = 20, min = 0, max = max, background = "panel",
            onChange = function() onCommit(money:Get()) end,
        })
        if last then box:SetPoint("LEFT", last, "RIGHT", 4, 0) end

        local mark = Theme.CreateLabel(parent, "small", "text")
        mark:SetPoint("LEFT", box, "RIGHT", 2, 0)
        mark:SetText(suffix)

        money.boxes[#money.boxes + 1] = box
        last = mark
        return box
    end

    money.gold = Coin(48, 214748, "|cffffd700g|r")
    money.silver = Coin(30, 99, "|cffc7c7cfs|r")
    money.copper = Coin(30, 99, "|cffeda55fc|r")

    function money:SetPoint(...) self.gold:SetPoint(...) end

    function money:Get()
        return (self.gold:GetValue() or 0) * 10000 + (self.silver:GetValue() or 0) * 100
            + (self.copper:GetValue() or 0)
    end

    function money:Set(copper)
        local gold, silver, copperPart = Util.SplitMoney(copper or 0)
        self.gold:SetValue(gold, true)
        self.silver:SetValue(silver, true)
        self.copper:SetValue(copperPart, true)
    end

    function money:Flush()
        for _, box in ipairs(self.boxes) do
            local edit = box.editBox
            if type(edit.HasFocus) == "function" and edit:HasFocus() then edit:ClearFocus() end
        end
    end

    function money:Hover(title, text)
        for _, box in ipairs(self.boxes) do
            box.editBox:SetScript("OnEnter", function()
                Theme.SetBorderColor(box, "borderLit")
                GameTooltip:SetOwner(box, "ANCHOR_TOP")
                GameTooltip:SetText(title, 1, 1, 1)
                GameTooltip:AddLine(text, 0.9, 0.9, 0.9, true)
                GameTooltip:Show()
            end)
            box.editBox:SetScript("OnLeave", function()
                Theme.SetBorderColor(box, "border")
                GameTooltip:Hide()
            end)
        end
    end

    return money
end

-- Also the list rules window's money boxes (UI/ListRulesWindow.lua).
PriceEditor.MoneyBoxes = MoneyBoxes

local function RowLabel(parent, text, anchor, y)
    local label = Theme.CreateLabel(parent, "small", "muted")
    label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y)
    label:SetWidth(LABEL_WIDTH)
    label:SetText(text)
    return label
end

function PriceEditor:Build()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", "BlackthornesTSPriceEditor", UIParent)
    frame:SetSize(WIDTH, HEIGHT)
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
        ns.Titanforged:Dress(frame, { title = L["Your price"], close = function() PriceEditor:Hide() end })
    else
        Theme.AddGameOutline(frame, { style = "dialog", color = "natural" })
    end
    Theme.Halo(frame, 10, 0.10)
    if type(UISpecialFrames) == "table" then tinsert(UISpecialFrames, "BlackthornesTSPriceEditor") end

    -- The item, as on its row.
    local icon = Theme.CreateItemIcon(frame, 16)
    icon:SetPoint("TOPLEFT", INSET, -34)
    self.icon = icon
    if Widgets.ItemHotspot then Widgets.ItemHotspot(icon) end

    local name = Theme.CreateLabel(frame, "normal", "text")
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    name:SetPoint("RIGHT", frame, "RIGHT", -INSET, 0)
    name:SetWordWrap(false)
    self.name = name

    -- What Ready to sell suggested, and the way back to it.
    local suggested = RowLabel(frame, L["Suggested"], icon, -14)
    local suggestedValue = Theme.CreateLabel(frame, "small", "accent")
    suggestedValue:SetPoint("LEFT", suggested, "RIGHT", 0, 0)
    self.suggested = suggestedValue

    self.reset = Widgets.CreateButton(frame, L["Use suggested"], function()
        PriceEditor:SetPrice(nil)
    end, { width = 100, height = 20 })
    self.reset:SetPoint("RIGHT", frame, "RIGHT", -INSET, 0)
    self.reset:SetPoint("TOP", suggested, "TOP", 0, 4)

    -- Each, how many, and the total: change any one and the others follow.
    local each = RowLabel(frame, L["Each"], suggested, -16)
    self.each = MoneyBoxes(frame, function(copper) PriceEditor:SetPrice(copper) end)
    self.each:SetPoint("LEFT", each, "RIGHT", 0, 0)
    self.each:Hover(L["Price each"], L["What one sells for. The total updates to match."])

    local count = RowLabel(frame, L["How many"], each, -16)
    self.quantity = Widgets.CreateNumberBox(frame, {
        width = 48, height = 20, min = 1, background = "panel",
        onChange = function(value) PriceEditor:SetQuantity(value) end,
    })
    self.quantity:SetPoint("LEFT", count, "RIGHT", 0, 0)
    self.ofLabel = Theme.CreateLabel(frame, "small", "dim")
    self.ofLabel:SetPoint("LEFT", self.quantity, "RIGHT", 6, 0)

    local total = RowLabel(frame, L["Total"], count, -16)
    self.total = MoneyBoxes(frame, function(copper) PriceEditor:SetTotal(copper) end)
    self.total:SetPoint("LEFT", total, "RIGHT", 0, 0)
    self.total:Hover(L["Total"], L["What they all sell for together, split over how many you list."])

    local divider = Theme.CreateDivider(frame)
    divider:SetPoint("TOPLEFT", total, "BOTTOMLEFT", 0, -12)
    divider:SetPoint("RIGHT", frame, "RIGHT", -INSET, 0)

    -- Warnings, worst first: refused, under market, rounding, what you get.
    local notes = Theme.CreateLabel(frame, "small", "muted")
    notes:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -8)
    notes:SetWidth(WIDTH - INSET * 2)
    notes:SetWordWrap(true)
    notes:SetJustifyV("TOP")
    self.notes = notes

    self.keep = Widgets.CreateCheckbox(frame, L["Keep as my price"], nil, false)
    self.keep:SetPoint("TOPLEFT", notes, "BOTTOMLEFT", 0, -10)
    self.keep:HookScript("OnEnter", function(box)
        GameTooltip:SetOwner(box, "ANCHOR_TOP")
        GameTooltip:SetText(L["Saves this price on the Prices tab and uses it from now on. Unticked, it lasts until you log out."], 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    self.keep:HookScript("OnLeave", function() GameTooltip:Hide() end)

    self.list = Widgets.CreateButton(frame, L["List"], function() PriceEditor:List() end,
        { width = 110, height = 24, primary = true })
    self.list:SetPoint("BOTTOMRIGHT", -INSET, 14)

    self.done = Widgets.CreateButton(frame, L["Done"], function() PriceEditor:Done() end,
        { width = 80, height = 24,
          tooltip = L["Keeps this price and closes. Nothing is listed."] })
    self.done:SetPoint("RIGHT", self.list, "LEFT", -8, 0)

    self.frame = frame
    return frame
end

--------------------------------------------------------------------------------
-- Opening and editing
--------------------------------------------------------------------------------

--- Open the editor for a Ready to sell line, beside `anchor` when given.
function PriceEditor:Open(line, anchor)
    if not line or not line.itemID then return end
    local frame = self:Build()

    self.line = line
    self.keep:SetChecked(false)

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

function PriceEditor:Hide()
    if self.frame then self.frame:Hide() end
    self.line = nil
end

function PriceEditor:IsShown()
    return self.frame ~= nil and self.frame:IsShown()
end

local function Redraw()
    if ns.PostPanel and ns.PostPanel.Refresh then ns.PostPanel:Refresh() end
    if ns.UI and ns.UI.RefreshActiveTab then ns.UI:RefreshActiveTab() end
end

--- Set the price each (nil: back to the suggested price).
function PriceEditor:SetPrice(price)
    local line = self.line
    if not line then return end
    if price ~= nil and price < 1 then price = nil end
    ns.Posting:ApplyPrice(line, price)
    self:Draw()
    Redraw()
end

--- Set the total: split over how many are listed.
function PriceEditor:SetTotal(total)
    local line = self.line
    if not line then return end
    local quantity = line.postQuantity or 1
    self:SetPrice(ns.Posting:PriceFromTotal(total, quantity, IsCommodity(line)))
end

function PriceEditor:SetQuantity(quantity)
    local line = self.line
    if not line then return end
    ns.Posting:ApplyQuantity(line, quantity)
    self:Draw()
    Redraw()
end

--- Whatever is half-typed goes in, as Enter would: a button click does not
--- take the keyboard from a box.
function PriceEditor:Flush()
    if not self.frame then return end
    self.each:Flush()
    self.total:Flush()
    local edit = self.quantity.editBox
    if type(edit.HasFocus) == "function" and edit:HasFocus() then edit:ClearFocus() end
end

--- Save the price on the Prices tab when "Keep as my price" is ticked.
function PriceEditor:KeepIfTicked()
    local line = self.line
    if not (line and self.keep:GetChecked() and line.priceBasis == "chosen" and line.unitPrice) then return end
    if not (ns.Prices and ns.Prices.SetMine) then return end

    local name
    if Util.HasFunction and Util.HasFunction("C_Item.GetItemInfo") then
        local ok, itemName = pcall(C_Item.GetItemInfo, line.itemID)
        if ok and type(itemName) == "string" and itemName ~= "" then name = itemName end
    end
    ns.Prices:SetMine(line.itemID, line.unitPrice, "use", name)
    ns.Print(L.Format("saved %s as your price for %s on the Prices tab.",
        Util.FormatMoney(line.unitPrice), line.label or Util.GetItemLabel(line.itemID)))
end

function PriceEditor:Done()
    self:Flush()
    self:KeepIfTicked()
    self:Hide()
    Redraw()
end

function PriceEditor:List()
    self:Flush()
    local line = self.line
    if not line or not line.unitPrice then return end

    self:KeepIfTicked()
    local itemID, quantity, price = line.itemID, line.postQuantity, line.unitPrice
    self:Hide()
    ns.Posting:Request(itemID, quantity, price)
end

--- Grow or shrink the window to its notes, so nothing runs into the tick
--- box or the buttons whatever the text size.
function PriceEditor:FitHeight()
    local frame, notes = self.frame, self.notes
    local ok, textHeight = pcall(notes.GetStringHeight, notes)
    if not ok or type(textHeight) ~= "number" then textHeight = 0 end
    notes:SetHeight(math.max(1, textHeight))

    local top = NOTES_TOP
    local okTop, frameTop = pcall(frame.GetTop, frame)
    local okNotes, notesTop = pcall(notes.GetTop, notes)
    if okTop and okNotes and type(frameTop) == "number" and type(notesTop) == "number"
        and frameTop > notesTop then
        top = frameTop - notesTop
    end

    frame:SetHeight(math.max(HEIGHT, math.ceil(top + textHeight + BELOW_NOTES)))
end

function PriceEditor:Draw()
    local line = self.line
    if not line or not self.frame then return end

    Theme.SetItemIcon(self.icon, line.itemID, line.link)
    self.name:SetText(line.label or Util.GetItemLabel(line.itemID))
    local r, g, b = Util.GetItemQualityColor(line.itemID)
    if r then self.name:SetTextColor(r, g, b) else self.name:SetTextColor(Theme.Unpack("text")) end

    local suggested = line.priceBasis == "chosen" and line.suggestedPrice or line.unitPrice
    self.suggested:SetText(suggested and L.Format("%s each", Util.FormatMoney(suggested)) or L["no price yet"])
    self.reset:SetEnabledState(line.priceBasis == "chosen")

    local maxQuantity = line.maxQuantity or line.count or 1
    local quantity = line.postQuantity or maxQuantity
    self.quantity:SetLimits(1, math.max(1, maxQuantity))
    self.quantity:SetValue(quantity, true)
    self.ofLabel:SetText(L.Format("of %d", maxQuantity))

    local price = line.unitPrice
    self.each:Set(price or 0)
    self.total:Set(price and price * quantity or 0)

    local notes, refused = PriceEditor.Notes(line, price, quantity)
    local parts = {}
    for _, note in ipairs(notes) do
        parts[#parts + 1] = ("|c%s%s|r"):format(ns.COLORS[note[2]] or ns.COLORS.muted, note[1])
    end
    self.notes:SetText(table.concat(parts, "\n"))
    self:FitHeight()

    self.list:SetText(L.Format("List %d", quantity))
    self.list:SetEnabledState(price ~= nil and not refused)
    self.list.tooltipText = refused
        and L["This price won't be listed. The note above says why."]
        or (price and L.Format("List %d at %s each, %s in all.", quantity,
            Util.FormatMoney(price, { noColor = true }),
            Util.FormatMoney(price * quantity, { noColor = true })))
end
