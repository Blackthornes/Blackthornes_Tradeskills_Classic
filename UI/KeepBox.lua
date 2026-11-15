-- Blackthornes Tradeskills -- UI/KeepBox.lua
-- How many of an item to keep on this character, opened by right-clicking
-- a row on the Sell list (Logic/KeepHere.lua, a player asked, the owner
-- said build it, 2026-10-18).

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local KeepBox = ns.NewModule("KeepBox")

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local WIDTH = 300
local INSET = 18
local BUTTON_WIDTH = 100

--- The box's title for an item, the item's name in its rarity colour.
function KeepBox.Title(itemID, label)
    local name = label or Util.GetItemLabel(itemID)
    local r, g, b = Util.GetItemQualityColor(itemID)
    if r and type(name) == "string" and not name:find("|c") then
        name = ("|cff%02x%02x%02x%s|r"):format(math.floor(r * 255 + 0.5),
            math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5), name)
    end
    return L.Format("Keep %s on this character", name)
end

function KeepBox:Build()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", "BlackthornesTSKeepBox", UIParent)
    frame:SetSize(WIDTH, 150)
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
        ns.Titanforged:Dress(frame, { close = function() KeepBox:Hide() end })
    else
        Theme.AddGameOutline(frame, { style = "dialog", color = "natural" })
    end
    Theme.Halo(frame, 10, 0.10)
    if type(UISpecialFrames) == "table" then tinsert(UISpecialFrames, "BlackthornesTSKeepBox") end

    local title = Theme.CreateLabel(frame, "normal", "text")
    title:SetPoint("TOPLEFT", INSET, -22)
    title:SetPoint("RIGHT", frame, "RIGHT", -INSET - 16, 0)
    title:SetWordWrap(true)
    title:SetJustifyH("LEFT")
    self.title = title

    self.box = Widgets.CreateNumberBox(frame, {
        width = 70, height = 22, min = 0, max = ns.KeepHere.MOST, background = "panel",
        justify = "LEFT", allowEmpty = true, placeholder = "0",
    })
    self.box:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    self.box.editBox:HookScript("OnEnterPressed", function() KeepBox:Save() end)

    local note = Theme.CreateLabel(frame, "small", "muted")
    note:SetPoint("TOPLEFT", self.box, "BOTTOMLEFT", 0, -8)
    note:SetWidth(WIDTH - INSET * 2)
    note:SetWordWrap(true)
    note:SetJustifyH("LEFT")
    note:SetText(L["Anything past this number can go on the Sell list. 0 clears it."])
    self.note = note

    self.save = Widgets.CreateButton(frame, L["Save"], function() KeepBox:Save() end,
        { width = BUTTON_WIDTH, height = 24, primary = true })
    self.save:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -12)

    self.all = Widgets.CreateButton(frame, L["Keep All"], function() KeepBox:Save(ns.KeepHere.MOST) end,
        { width = BUTTON_WIDTH, height = 24 })
    self.all:SetPoint("LEFT", self.save, "RIGHT", 8, 0)

    self.frame = frame
    if ns.SharedWindow and ns.SharedWindow.KeepSpot then ns.SharedWindow.KeepSpot(frame, "ts.keepbox") end
    return frame
end

--- Open the box for a Sell list line, beside `anchor` when given.
function KeepBox:Open(line, anchor)
    if not line or not line.itemID or not ns.KeepHere then return end
    local frame = self:Build()
    self.itemID = line.itemID

    self.title:SetText(KeepBox.Title(line.itemID, line.label))
    local count = ns.KeepHere:Count(line.itemID)
    self.box:SetValue(count and not ns.KeepHere.IsAll(count) and count or nil, true)

    frame:ClearAllPoints()
    if anchor and anchor.GetRight then
        frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 8, 0)
    else
        frame:SetPoint("CENTER")
    end
    frame:Show()
    if ns.Titanforged and ns.Titanforged.Opened then pcall(ns.Titanforged.Opened, ns.Titanforged, frame) end
    self:FitHeight()
end

function KeepBox:Hide()
    if self.frame then self.frame:Hide() end
    self.itemID = nil
end

function KeepBox:IsShown()
    return self.frame ~= nil and self.frame:IsShown()
end

--- Save the number typed, or `count` (Keep All), and close.
function KeepBox:Save(count)
    local itemID = self.itemID
    if not itemID then return end
    if count == nil then
        local edit = self.box.editBox
        if type(edit.HasFocus) == "function" and edit:HasFocus() then edit:ClearFocus() end
        count = tonumber(edit:GetText()) or 0
    end
    self:Hide()
    local done, why = ns.KeepHere:Set(itemID, count)
    if not done and why then ns.Print(why) end
end

--- Grow the box to its title and note, whatever the text size.
function KeepBox:FitHeight()
    local frame = self.frame
    local function Height(label)
        local ok, height = pcall(label.GetStringHeight, label)
        return ok and type(height) == "number" and height or 14
    end
    frame:SetHeight(math.ceil(22 + Height(self.title) + 10 + 22 + 8 + Height(self.note) + 12 + 24 + 16))
end
