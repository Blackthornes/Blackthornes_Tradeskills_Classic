-- Blackthornes Tradeskills -- UI/NeverMakeBox.lua
-- Asks before the x on a sub-craft sets it to Buy for good.
--
-- On a sub-craft the x is Queue:NeverMake: its item is bought from then on,
-- not made. It looked like a plain "take it off", so a player clicked it on
-- Heavy Blasting Powder and the queue went on buying the powder for more
-- than its Heavy Stone cost (2026-10-22, the owner approved the words).

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local NeverMakeBox = ns.NewModule("NeverMakeBox")

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local WIDTH = 300
local INSET = 18
local BUTTON_WIDTH = 110

--- What the sub-craft makes, in its rarity colour, else the recipe's name.
function NeverMakeBox.Name(entry)
    local recipe = entry and ns.Recipes and ns.Recipes.GetAny and ns.Recipes:GetAny(entry.recipeID)
    local itemID = recipe and recipe.outputItemID
    local name = itemID and Util and Util.GetItemLabel and Util.GetItemLabel(itemID)
    if type(name) ~= "string" or name == "" then
        name = (recipe and recipe.name) or L["this"]
    end
    local r, g, b
    if itemID and Util and Util.GetItemQualityColor then r, g, b = Util.GetItemQualityColor(itemID) end
    if r and not name:find("|c") then
        name = ("|cff%02x%02x%02x%s|r"):format(math.floor(r * 255 + 0.5),
            math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5), name)
    end
    return name
end

function NeverMakeBox:Build()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", "BlackthornesTSNeverMakeBox", UIParent)
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
        ns.Titanforged:Dress(frame, { close = function() NeverMakeBox:Hide() end })
    else
        Theme.AddGameOutline(frame, { style = "dialog", color = "natural" })
    end
    if Theme.Halo then Theme.Halo(frame, 10, 0.10) end
    if type(UISpecialFrames) == "table" then tinsert(UISpecialFrames, "BlackthornesTSNeverMakeBox") end

    local title = Theme.CreateLabel(frame, "normal", "text")
    title:SetPoint("TOPLEFT", INSET, -22)
    title:SetPoint("RIGHT", frame, "RIGHT", -INSET - 16, 0)
    title:SetWordWrap(true)
    title:SetJustifyH("LEFT")
    self.title = title

    local note = Theme.CreateLabel(frame, "small", "muted")
    note:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    note:SetWidth(WIDTH - INSET * 2)
    note:SetWordWrap(true)
    note:SetJustifyH("LEFT")
    note:SetText(L["The queue will buy it instead, from now on."] .. "\n"
        .. L["You can undo this in Settings, Queue."])
    self.note = note

    self.buy = Widgets.CreateButton(frame, L["Buy It"], function() NeverMakeBox:BuyIt() end,
        { width = BUTTON_WIDTH, height = 24, primary = true })
    self.buy:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -12)

    self.keep = Widgets.CreateButton(frame, L["Keep Making"], function() NeverMakeBox:Hide() end,
        { width = BUTTON_WIDTH, height = 24 })
    self.keep:SetPoint("LEFT", self.buy, "RIGHT", 8, 0)

    self.frame = frame
    if ns.SharedWindow and ns.SharedWindow.KeepSpot then ns.SharedWindow.KeepSpot(frame, "ts.nevermake") end
    return frame
end

--- Ask before setting a sub-craft to Buy, beside `anchor` when given.
-- Anything that is not a sub-craft is not asked about.
-- @return true when the box opened
function NeverMakeBox:Ask(entry, anchor)
    if not (entry and entry.isDependency) then return false end
    local frame = self:Build()
    self.entry = entry

    self.title:SetText(L.Format("Stop making %s?", NeverMakeBox.Name(entry)))

    frame:ClearAllPoints()
    if anchor and anchor.GetRight then
        frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 8, 0)
    else
        frame:SetPoint("CENTER")
    end
    frame:Show()
    if ns.Titanforged and ns.Titanforged.Opened then pcall(ns.Titanforged.Opened, ns.Titanforged, frame) end
    self:FitHeight()
    return true
end

function NeverMakeBox:Hide()
    if self.frame then self.frame:Hide() end
    self.entry = nil
end

function NeverMakeBox:IsShown()
    return self.frame ~= nil and self.frame:IsShown()
end

--- Buy It: the sub-craft is never made again (Queue:NeverMake).
function NeverMakeBox:BuyIt()
    local entry = self.entry
    self:Hide()
    if entry and ns.Queue and ns.Queue.NeverMake then ns.Queue:NeverMake(entry) end
end

--- Grow the box to its title and note, whatever the text size.
function NeverMakeBox:FitHeight()
    local function Height(label)
        local ok, height = pcall(label.GetStringHeight, label)
        return ok and type(height) == "number" and height or 14
    end
    self.frame:SetHeight(math.ceil(22 + Height(self.title) + 8 + Height(self.note) + 12 + 24 + 16))
end

--- The x on a sub-craft's row: ask first, or set it straight to Buy when
--- the box is not loaded.
function NeverMakeBox.Click(entry, anchor)
    if NeverMakeBox:Ask(entry, anchor) then return end
    if ns.Queue and ns.Queue.NeverMake then ns.Queue:NeverMake(entry) end
end
