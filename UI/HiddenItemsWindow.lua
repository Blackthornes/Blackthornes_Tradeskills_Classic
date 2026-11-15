-- Blackthornes Tradeskills -- UI/HiddenItemsWindow.lua
-- The items the player hid from the Sell tab with its x, each with Restore.
--
-- A player could not find their elixirs on the Sell tab (2026-11-06): the
-- only things kept off it now are the ones the player hid, and the Hidden
-- button on the Sell tab opens this list to bring one back (the owner
-- approved the mockup). The list is Posting:GetIgnored(); Restore is
-- Posting:SetIgnored(itemID, false), which redraws the Sell tab itself.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local HiddenItems = ns.NewModule("HiddenItemsWindow")

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local WIDTH = 340
local INSET = 18
local ROW_HEIGHT = 26
local ROWS = 10
local BUTTON_WIDTH = 86

HiddenItems.ROWS = ROWS

--- The item's name in its rarity colour, else the name kept when it was hidden.
function HiddenItems.Name(entry)
    local name = Util and Util.GetItemLabel and Util.GetItemLabel(entry.itemID)
    if type(name) ~= "string" or name == "" then name = entry.name end
    local r, g, b
    if Util and Util.GetItemQualityColor then r, g, b = Util.GetItemQualityColor(entry.itemID) end
    if r and not name:find("|c") then
        name = ("|cff%02x%02x%02x%s|r"):format(math.floor(r * 255 + 0.5),
            math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5), name)
    end
    return name
end

--- How many items are hidden now.
function HiddenItems.Count()
    if not (ns.Posting and ns.Posting.GetIgnored) then return 0 end
    return #ns.Posting:GetIgnored()
end

local function MakeRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row.band = row:CreateTexture(nil, "BACKGROUND")
    row.band:SetAllPoints(row)
    row.line = row:CreateTexture(nil, "BORDER")
    row.line:SetPoint("BOTTOMLEFT")
    row.line:SetPoint("BOTTOMRIGHT")
    row.line:SetHeight(1)
    row.line:SetColorTexture(Theme.Unpack("border", 0.6))

    row.restore = Widgets.CreateButton(row, L["Restore"], function()
        if row.itemID and ns.Posting then ns.Posting:SetIgnored(row.itemID, false) end
        HiddenItems:Refresh()
    end, { width = BUTTON_WIDTH, height = 20 })
    row.restore:SetPoint("RIGHT", row, "RIGHT", -4, 0)

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("LEFT", row, "LEFT", 8, 0)
    row.name:SetPoint("RIGHT", row.restore, "LEFT", -8, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(true)
    row.index = index
    return row
end

function HiddenItems:Build()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", "BlackthornesTSHiddenItems", UIParent)
    frame:SetSize(WIDTH, 200)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:EnableMouseWheel(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetScript("OnMouseWheel", function(_, delta) HiddenItems:Scroll(-delta) end)
    frame:Hide()

    Theme.Fill(frame, "window")
    if ns.Titanforged then
        ns.Titanforged:Dress(frame, { close = function() HiddenItems:Hide() end })
    else
        Theme.AddGameOutline(frame, { style = "dialog", color = "natural" })
    end
    if Theme.Halo then Theme.Halo(frame, 10, 0.10) end
    if type(UISpecialFrames) == "table" then tinsert(UISpecialFrames, "BlackthornesTSHiddenItems") end

    local title = Theme.CreateLabel(frame, "normal", "text")
    title:SetPoint("TOPLEFT", INSET, -22)
    title:SetPoint("RIGHT", frame, "RIGHT", -INSET - 16, 0)
    title:SetJustifyH("LEFT")
    title:SetText(L["Hidden Items"])
    self.title = title

    local hint = Theme.CreateLabel(frame, "small", "muted")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    hint:SetWidth(WIDTH - INSET * 2)
    hint:SetWordWrap(true)
    hint:SetJustifyH("LEFT")
    hint:SetText(L["You hid these from the Sell tab. Click Restore to bring one back."])
    self.hint = hint

    local list = CreateFrame("Frame", nil, frame)
    list:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -10)
    list:SetWidth(WIDTH - INSET * 2)
    Theme.Fill(list, "glassAlt")
    self.list = list

    self.rows = {}
    for index = 1, ROWS do
        local row = MakeRow(list, index)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
        row:SetPoint("RIGHT", list, "RIGHT", 0, 0)
        row.band:SetColorTexture(Theme.Unpack(index % 2 == 1 and "glass" or "glassAlt"))
        self.rows[index] = row
    end

    local footer = Theme.CreateLabel(frame, "small", "muted")
    footer:SetJustifyH("LEFT")
    self.footer = footer

    self.restoreAll = Widgets.CreateButton(frame, L["Restore All"], function() HiddenItems:RestoreAll() end,
        { width = 110, height = 22, primary = true })

    self.offset = 0
    self.frame = frame
    if ns.SharedWindow and ns.SharedWindow.KeepSpot then ns.SharedWindow.KeepSpot(frame, "ts.hidden") end
    return frame
end

function HiddenItems:Show(anchor)
    local frame = self:Build()
    self.offset = 0
    frame:ClearAllPoints()
    if anchor and anchor.GetRight then
        frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 8, 0)
    else
        frame:SetPoint("CENTER")
    end
    frame:Show()
    if ns.Titanforged and ns.Titanforged.Opened then pcall(ns.Titanforged.Opened, ns.Titanforged, frame) end
    self:Refresh()
end

function HiddenItems:Hide()
    if self.frame then self.frame:Hide() end
end

function HiddenItems:IsShown()
    return self.frame ~= nil and self.frame:IsShown()
end

function HiddenItems:Toggle(anchor)
    if self:IsShown() then self:Hide() else self:Show(anchor) end
end

function HiddenItems:Scroll(step)
    local total = HiddenItems.Count()
    local most = math.max(0, total - ROWS)
    self.offset = math.max(0, math.min(most, (self.offset or 0) + (step or 0)))
    self:Refresh()
end

--- Restore All: every hidden item goes back on the Sell tab.
function HiddenItems:RestoreAll()
    if not (ns.Posting and ns.Posting.GetIgnored) then return end
    for _, entry in ipairs(ns.Posting:GetIgnored()) do
        ns.Posting:SetIgnored(entry.itemID, false)
    end
    self:Refresh()
end

function HiddenItems:Refresh()
    if not (self.frame and self.frame:IsShown()) then return end
    local items = ns.Posting and ns.Posting.GetIgnored and ns.Posting:GetIgnored() or {}
    local most = math.max(0, #items - ROWS)
    if (self.offset or 0) > most then self.offset = most end

    local shown = math.max(1, math.min(ROWS, #items))
    for index, row in ipairs(self.rows) do
        local entry = items[(self.offset or 0) + index]
        if entry then
            row.itemID = entry.itemID
            row.name:SetText(HiddenItems.Name(entry))
            row.restore:Show()
            row:Show()
        elseif index == 1 and #items == 0 then
            row.itemID = nil
            row.name:SetText(L["Nothing is hidden."])
            row.name:SetTextColor(Theme.Unpack("muted"))
            row.restore:Hide()
            row:Show()
        else
            row.itemID = nil
            row:Hide()
        end
        if entry then row.name:SetTextColor(Theme.Unpack("text")) end
    end
    self.list:SetHeight(shown * ROW_HEIGHT)

    self.footer:ClearAllPoints()
    self.footer:SetPoint("TOPLEFT", self.list, "BOTTOMLEFT", 0, -12)
    self.footer:SetText(L.Format("%d hidden", #items))
    self.restoreAll:ClearAllPoints()
    self.restoreAll:SetPoint("RIGHT", self.list, "RIGHT", 0, 0)
    self.restoreAll:SetPoint("TOP", self.list, "BOTTOM", 0, -8)
    self.restoreAll:SetShown(#items > 1)

    local ok, hintHeight = pcall(self.hint.GetStringHeight, self.hint)
    hintHeight = ok and type(hintHeight) == "number" and hintHeight or 28
    self.frame:SetHeight(math.ceil(22 + 16 + 6 + hintHeight + 10 + shown * ROW_HEIGHT + 8 + 22 + 16))
end
