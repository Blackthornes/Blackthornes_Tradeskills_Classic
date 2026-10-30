-- Blackthornes -- UI/RowMenu.lua
-- The one menu a right-click on any row opens (the owner said build it,
-- 2026-10-29, from the unified look's mockups): a thin gold rim round dark
-- glass, the row's name in gold on top, then a line for each thing the row
-- can do, the usual one first. Butler's verdict menu was the look.
--
-- It never does anything by itself: it waits for a click on a line, and goes
-- when a line is clicked, when the mouse leaves it, or after a few seconds
-- if the mouse never comes onto it. Shift-click and Alt-click shortcuts on
-- the rows still work; actions the game guards (a craft, a cast) stay
-- buttons, since a menu can't do them.
--
-- The same file in all five addons (a fix to it belongs in all five).
--
--   ns.RowMenu:Open(lines, opts)
--     lines: { { text, run, checked, disabled }, ... }
--     opts:  { title } (the row's name, shown in gold)

local _, ns = ...

local RowMenu = {}
ns.RowMenu = RowMenu

local ROW = 22
local PAD = 10
local INSET = 4
local TITLE = 22
RowMenu.WAIT = 6
RowMenu.MIN_WIDTH = 150

local function Color(key, alpha)
    local theme = ns.Theme
    if theme and theme.Unpack then
        local ok, r, g, b, a = pcall(theme.Unpack, key, alpha)
        if ok and r then return r, g, b, a or alpha or 1 end
    end
    return 0.8, 0.65, 0.3, alpha or 1
end

local function Label(parent, size, key, justify)
    local theme = ns.Theme
    if theme and theme.CreateLabel then return theme.CreateLabel(parent, size, key, justify) end
    return parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
end

local function Measure(label, text)
    label:SetText(text or "")
    local ok, width = pcall(label.GetStringWidth, label)
    if ok and type(width) == "number" and width > 0 then return width end
    return #(text or "") * 6
end

local function Paint(line, hover)
    local index = line.index or 1
    line.stripe:SetColorTexture(Color(hover and "glassHover" or (index % 2 == 1 and "glass" or "glassAlt")))
    line.edge:SetShown(hover and true or false)
    if line.disabled then
        line.label:SetTextColor(Color("dim"))
    else
        line.label:SetTextColor(Color(hover and "accentHi" or "text"))
    end
end

local function CreateLine(menu, index)
    local line = CreateFrame("Button", nil, menu)
    line.index = index
    line:SetHeight(ROW)
    pcall(line.RegisterForClicks, line, "LeftButtonUp", "RightButtonUp")
    line.stripe = line:CreateTexture(nil, "BACKGROUND")
    line.stripe:SetAllPoints()
    line.rule = line:CreateTexture(nil, "BORDER")
    line.rule:SetPoint("BOTTOMLEFT")
    line.rule:SetPoint("BOTTOMRIGHT")
    line.rule:SetHeight(1)
    line.rule:SetColorTexture(Color("border", 0.6))
    line.edge = line:CreateTexture(nil, "ARTWORK")
    line.edge:SetPoint("TOPLEFT")
    line.edge:SetPoint("BOTTOMLEFT")
    line.edge:SetWidth(2)
    line.edge:SetColorTexture(Color("accentHi"))
    line.label = Label(line, "small", "text", "LEFT")
    line.label:SetPoint("LEFT", PAD, 0)
    line.label:SetPoint("RIGHT", -PAD, 0)
    line:SetScript("OnClick", function(self) RowMenu:Pick(self) end)
    line:SetScript("OnEnter", function(self)
        RowMenu.entered = true
        Paint(self, true)
    end)
    line:SetScript("OnLeave", function(self)
        Paint(self, false)
        if C_Timer and C_Timer.After then
            C_Timer.After(0.3, function() RowMenu:CloseIfLeft() end)
        end
    end)
    Paint(line, false)
    line:Hide()
    return line
end

function RowMenu:Build()
    if self.frame then return self.frame end
    local menu = CreateFrame("Frame", nil, UIParent)
    menu.fill = menu:CreateTexture(nil, "BACKGROUND")
    menu.fill:SetAllPoints()
    menu.fill:SetColorTexture(Color("window"))
    local theme = ns.Theme
    if theme and theme.Border then pcall(theme.Border, menu, "accent") end
    pcall(menu.SetFrameStrata, menu, "FULLSCREEN_DIALOG")
    pcall(menu.SetToplevel, menu, true)
    pcall(menu.SetClampedToScreen, menu, true)
    menu:EnableMouse(true)
    menu:Hide()
    menu.title = Label(menu, "small", "accent", "LEFT")
    menu.title:SetPoint("TOPLEFT", PAD, -6)
    menu.rule = menu:CreateTexture(nil, "BORDER")
    menu.rule:SetHeight(1)
    menu.rule:SetColorTexture(Color("metal", 0.9))
    menu.lines = {}
    menu:SetScript("OnEnter", function() RowMenu.entered = true end)
    menu:SetScript("OnLeave", function()
        if C_Timer and C_Timer.After then
            C_Timer.After(0.3, function() RowMenu:CloseIfLeft() end)
        end
    end)
    self.frame = menu
    return menu
end

--- Open the menu at the mouse with `lines`. Returns the menu, or nil when
--- there is nothing to offer.
function RowMenu:Open(lines, opts)
    if type(lines) ~= "table" or #lines == 0 then return nil end
    opts = opts or {}
    local menu = self:Build()
    local top = INSET
    if opts.title then
        menu.title:SetText(opts.title)
        menu.title:Show()
        menu.rule:ClearAllPoints()
        menu.rule:SetPoint("TOPLEFT", INSET + 2, -TITLE)
        menu.rule:SetPoint("TOPRIGHT", -INSET - 2, -TITLE)
        menu.rule:Show()
        top = TITLE + 2
    else
        menu.title:Hide()
        menu.rule:Hide()
    end
    local width = RowMenu.MIN_WIDTH
    if opts.title then width = math.max(width, Measure(menu.title, opts.title) + PAD * 2 + INSET * 2) end
    for index, spec in ipairs(lines) do
        local line = menu.lines[index] or CreateLine(menu, index)
        menu.lines[index] = line
        line.run = spec.run
        line.disabled = spec.disabled and true or false
        local text = spec.text or ""
        if spec.checked then text = "|TInterface\\Buttons\\UI-CheckBox-Check:14:14:0:0|t " .. text end
        width = math.max(width, Measure(line.label, text) + PAD * 2 + INSET * 2)
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", INSET, -top - (index - 1) * ROW)
        line:SetPoint("TOPRIGHT", -INSET, -top - (index - 1) * ROW)
        Paint(line, false)
        line:Show()
    end
    for index = #lines + 1, #menu.lines do menu.lines[index]:Hide() end
    menu:SetSize(math.ceil(width), top + #lines * ROW + INSET)
    menu:ClearAllPoints()
    local x, y = 0, 0
    if GetCursorPosition then
        local ok, cx, cy = pcall(GetCursorPosition)
        local okScale, scale = pcall(UIParent.GetEffectiveScale, UIParent)
        if ok and type(cx) == "number" and okScale and type(scale) == "number" and scale > 0 then
            x, y = cx / scale, cy / scale
        end
    end
    menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x - 8, y + 8)
    self.entered = false
    self.openedAt = GetTime and GetTime() or 0
    menu:Show()
    if C_Timer and C_Timer.After then
        local opened = self.openedAt
        C_Timer.After(RowMenu.WAIT, function()
            if not self.entered and self.openedAt == opened then self:Close() end
        end)
    end
    return menu
end

function RowMenu:Pick(line)
    if not line or line.disabled then return end
    local run = line.run
    self:Close()
    if type(run) == "function" then
        local ok, err = pcall(run)
        if not ok and ns.Debug then ns.Debug("row menu:", tostring(err)) end
    end
end

function RowMenu:CloseIfLeft()
    local menu = self.frame
    if not (menu and menu:IsShown()) then return end
    local ok, over = pcall(menu.IsMouseOver, menu)
    if ok and over then return end
    self:Close()
end

function RowMenu:Close()
    if self.frame then self.frame:Hide() end
end

function RowMenu:IsShown()
    return self.frame ~= nil and self.frame:IsShown()
end

return RowMenu
