-- Blackthornes Tradeskills -- UI/Welcome.lua
-- The Welcome card (the owner said build it, 2026-10-20, from a mockup):
-- shown once per character the first time the window opens, it asks which
-- professions to level. Show My Road keeps the picks and opens Road to 300
-- (UI/RoadView.lua) on the first; Not Now closes it. Either way it never
-- comes back by itself; Settings opens it again. Logic/Welcome.lua keeps
-- what it saves.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local WelcomeUI = ns.NewModule("WelcomeUI")

local Theme = ns.Theme
local Widgets = ns.Widgets

local WIDTH = 340
local INSET = 18

function WelcomeUI:Build()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", "BlackthornesTSWelcome", UIParent)
    frame:SetSize(WIDTH, 220)
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
        ns.Titanforged:Dress(frame, { title = L["Welcome"], close = function() WelcomeUI:NotNow() end })
    else
        Theme.AddGameOutline(frame, { style = "dialog", color = "natural" })
    end
    if Theme.Halo then Theme.Halo(frame, 10, 0.10) end
    if type(UISpecialFrames) == "table" then tinsert(UISpecialFrames, "BlackthornesTSWelcome") end

    local intro = Theme.CreateLabel(frame, "normal", "text")
    intro:SetPoint("TOPLEFT", INSET, -30)
    intro:SetWidth(WIDTH - INSET * 2)
    intro:SetWordWrap(true)
    intro:SetJustifyH("LEFT")
    intro:SetText(L["Pick the professions you want to level. We'll lay out the road for each one and keep it up to date as you play."])
    self.intro = intro

    self.picks = CreateFrame("Frame", nil, frame)
    self.picks:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -12)
    self.picks:SetSize(WIDTH - INSET * 2, 24)
    self.boxes = {}

    local note = Theme.CreateLabel(frame, "small", "muted")
    note:SetPoint("TOPLEFT", self.picks, "BOTTOMLEFT", 0, -10)
    note:SetWidth(WIDTH - INSET * 2)
    note:SetWordWrap(true)
    note:SetJustifyH("LEFT")
    note:SetText(L["You can change this any time in Settings."])
    self.note = note

    self.show = Widgets.CreateButton(frame, L["Show My Road"], function() WelcomeUI:ShowMyRoad() end,
        { width = 120, height = 24, primary = true })
    self.show:SetPoint("BOTTOMRIGHT", -INSET, 16)

    self.notNow = Widgets.CreateButton(frame, L["Not Now"], function() WelcomeUI:NotNow() end,
        { width = 90, height = 24 })
    self.notNow:SetPoint("RIGHT", self.show, "LEFT", -8, 0)

    self.frame = frame
    if ns.SharedWindow and ns.SharedWindow.KeepSpot then ns.SharedWindow.KeepSpot(frame, "ts.welcome") end
    return frame
end

--- One tick box a profession, the picks kept ticked (all of them the
--- first time).
function WelcomeUI:FillPicks()
    local professions = ns.RoadPlan:Professions()
    local picked = {}
    local saved = ns.Welcome:Picks()
    for _, line in ipairs(saved) do picked[line] = true end
    local any = #saved > 0

    for _, box in ipairs(self.boxes) do box:Hide() end
    self.lines = {}
    for index, profession in ipairs(professions) do
        local box = self.boxes[index]
        if not box then
            box = Widgets.CreateCheckbox(self.picks, "", function() end, false)
            self.boxes[index] = box
        end
        box:ClearAllPoints()
        box:SetPoint("TOPLEFT", 0, -(index - 1) * 24)
        box:SetLabel(("%s  %d"):format(profession.name, profession.skill))
        box:SetChecked(not any or picked[profession.line] == true)
        box:Show()
        self.lines[index] = profession.line
    end
    self.picks:SetHeight(math.max(24, #professions * 24))
end

--- Grow the card to its words and picks, whatever the text size.
function WelcomeUI:FitHeight()
    local function Height(label)
        local ok, height = pcall(label.GetStringHeight, label)
        return ok and type(height) == "number" and height or 14
    end
    self.frame:SetHeight(math.ceil(30 + Height(self.intro) + 12 + (self.picks:GetHeight() or 24)
        + 10 + Height(self.note) + 16 + 24 + 16))
end

--- Open the card. From Settings it opens whether or not it was seen.
function WelcomeUI:Show()
    local frame = self:Build()
    self:FillPicks()
    frame:ClearAllPoints()
    local window = ns.UI and ns.UI.window
    if window and window.IsShown and window:IsShown() then
        frame:SetPoint("CENTER", window, "CENTER", 0, 0)
    else
        frame:SetPoint("CENTER")
    end
    frame:Show()
    if frame.Raise then frame:Raise() end
    if ns.Titanforged and ns.Titanforged.Opened then pcall(ns.Titanforged.Opened, ns.Titanforged, frame) end
    self:FitHeight()
end

--- The first time the window opens on this character.
function WelcomeUI:MaybeShow()
    if not (ns.Welcome and ns.Welcome:Due()) then return false end
    self:Show()
    return true
end

function WelcomeUI:Hide()
    if self.frame then self.frame:Hide() end
end

--- The lines ticked, in the order shown.
function WelcomeUI:Ticked()
    local list = {}
    for index, line in ipairs(self.lines or {}) do
        local box = self.boxes[index]
        if box and box:GetChecked() then list[#list + 1] = line end
    end
    return list
end

function WelcomeUI:NotNow()
    ns.Welcome:MarkSeen()
    self:Hide()
end

function WelcomeUI:ShowMyRoad()
    local picks = self:Ticked()
    ns.Welcome:SetPicks(picks)
    ns.Welcome:MarkSeen()
    self:Hide()
    if ns.LevelUpTab and ns.LevelUpTab.ShowRoad then ns.LevelUpTab.ShowRoad(picks[1]) end
end
