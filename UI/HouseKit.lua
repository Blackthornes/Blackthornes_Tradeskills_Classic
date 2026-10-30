-- Blackthornes -- UI/HouseKit.lua
-- Small pieces every Blackthornes window shares (the owner said build
-- them all, 2026-10-29, from the unified look's mockups):
--
--   * View tabs: small tabs that sit on top of a list, one a view
--     (Tradeskills' My Crafts / Your Time, Farmer's This Session / Overall).
--     Unpicked tabs are dark gold metal with a gold label; the picked one
--     opens into the list below, dark glass with a bright gold top edge.
--     Each is as wide as its words, so German fits; never wrapped or cut.
--   * Chips: the house filter chip, for "which kinds" on a filter row.
--   * The empty block: the addon's emblem faint, one short line, and a gold
--     button when there is a next step ("Clear Search", "Show All").
--   * Panel gems: the gold fold gem and red close gem for panels that stay
--     up while you play (Farmer's Kills & Loot, Equipment's Upgrade Hunts).
--
-- The same file in all five addons (a fix to it belongs in all five). It
-- reads only the shared parts of each addon's Theme (Fill, Border,
-- CreateLabel, Unpack) and sets Widgets.CreateViewTabs, Widgets.CreateEmpty
-- and, where the addon has none of its own, Widgets.CreateChip.

local ADDON, ns = ...

local HouseKit = {}
ns.HouseKit = HouseKit

local EMBLEM = ([[Interface\AddOns\%s\Media\Frame\Emblem.tga]]):format(ADDON)

local function Theme() return ns.Theme end

local function Color(key, alpha)
    local theme = Theme()
    if theme and theme.Unpack then
        local ok, r, g, b, a = pcall(theme.Unpack, key, alpha)
        if ok and r then return r, g, b, a or alpha or 1 end
    end
    return 0.8, 0.65, 0.3, alpha or 1
end

local function Fill(frame, key, alpha, layer)
    local tex = frame:CreateTexture(nil, layer or "BACKGROUND")
    tex:SetAllPoints()
    tex:SetColorTexture(Color(key, alpha))
    return tex
end

local function Label(parent, size, key, justify)
    local theme = Theme()
    if theme and theme.CreateLabel then return theme.CreateLabel(parent, size, key, justify) end
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if justify and label.SetJustifyH then label:SetJustifyH(justify) end
    return label
end

-- How wide `text` is in `label`'s font, measured, never guessed by eye.
local function Measure(label, text)
    label:SetText(text or "")
    local ok, width = pcall(label.GetStringWidth, label)
    if ok and type(width) == "number" and width > 0 then return width end
    return #(text or "") * 6
end
HouseKit.Measure = Measure

--------------------------------------------------------------------------------
-- View tabs
--------------------------------------------------------------------------------

HouseKit.TAB_HEIGHT = 22
HouseKit.TAB_PAD = 12
HouseKit.TAB_GAP = 3

local function PaintTab(tab, picked, hover)
    if picked then
        tab.fill:SetColorTexture(Color("glassActive"))
        tab.top:SetColorTexture(Color("accentHi"))
        tab.top:Show()
        tab.label:SetTextColor(Color("accentHi"))
    else
        tab.fill:SetColorTexture(Color(hover and "glassHover" or "metal", hover and 1 or 0.55))
        tab.top:Hide()
        tab.label:SetTextColor(Color(hover and "accentHi" or "accent"))
    end
end

--- Small tabs for a tab's views. `tabs` is a list of { key, text };
--- `onSelect(key)` runs when one is clicked. Returns the strip, whose
--- :Select(key, silent), :SetTabShown(key, shown), :SetTabText(key, text)
--- and .selected are what callers use.
function HouseKit.CreateViewTabs(parent, tabs, onSelect, opts)
    opts = opts or {}
    local strip = CreateFrame("Frame", nil, parent)
    strip:SetHeight(opts.height or HouseKit.TAB_HEIGHT)
    strip.tabs, strip.byKey, strip.selected = {}, {}, nil

    -- A fine gold line along the bottom, the list's top edge.
    strip.base = strip:CreateTexture(nil, "BORDER")
    strip.base:SetPoint("BOTTOMLEFT")
    strip.base:SetPoint("BOTTOMRIGHT")
    strip.base:SetHeight(1)
    strip.base:SetColorTexture(Color("accent", 0.55))

    local function Layout()
        local x = 0
        for _, tab in ipairs(strip.tabs) do
            if tab.hidden then
                tab:Hide()
            else
                tab:ClearAllPoints()
                tab:SetPoint("BOTTOMLEFT", strip, "BOTTOMLEFT", x, 0)
                tab:SetWidth(tab.wide)
                tab:Show()
                x = x + tab.wide + HouseKit.TAB_GAP
            end
        end
        strip.used = math.max(0, x - HouseKit.TAB_GAP)
        if not opts.width then strip:SetWidth(math.max(strip.used, 1)) end
    end
    strip.Layout = Layout

    for _, spec in ipairs(tabs) do
        local tab = CreateFrame("Button", nil, strip)
        tab:SetHeight(opts.height or HouseKit.TAB_HEIGHT)
        tab.key = spec.key
        tab.fill = Fill(tab, "metal", 0.55)
        local theme = Theme()
        if theme and theme.Border then pcall(theme.Border, tab, "metal", 0.8) end
        tab.top = tab:CreateTexture(nil, "ARTWORK")
        tab.top:SetPoint("TOPLEFT")
        tab.top:SetPoint("TOPRIGHT")
        tab.top:SetHeight(2)
        tab.label = Label(tab, opts.size or "small", "accent", "CENTER")
        tab.label:SetPoint("CENTER", 0, 0)
        if tab.label.SetWordWrap then tab.label:SetWordWrap(false) end
        tab.wide = math.ceil(Measure(tab.label, spec.text) + HouseKit.TAB_PAD * 2)
        tab:SetScript("OnClick", function(self) strip:Select(self.key) end)
        tab:SetScript("OnEnter", function(self) PaintTab(self, strip.selected == self.key, true) end)
        tab:SetScript("OnLeave", function(self) PaintTab(self, strip.selected == self.key, false) end)
        PaintTab(tab, false, false)
        strip.tabs[#strip.tabs + 1] = tab
        strip.byKey[spec.key] = tab
    end
    if opts.width then strip:SetWidth(opts.width) end

    function strip:Select(key, silent)
        if not self.byKey[key] then return end
        local changed = self.selected ~= key
        self.selected = key
        for _, tab in ipairs(self.tabs) do PaintTab(tab, tab.key == key, false) end
        if changed and not silent and onSelect then onSelect(key) end
    end
    function strip:SetTabShown(key, shown)
        local tab = self.byKey[key]
        if not tab then return end
        tab.hidden = not shown
        Layout()
    end
    function strip:SetTabText(key, text)
        local tab = self.byKey[key]
        if not tab then return end
        tab.wide = math.ceil(Measure(tab.label, text) + HouseKit.TAB_PAD * 2)
        Layout()
    end
    function strip:Keys()
        local keys = {}
        for _, tab in ipairs(self.tabs) do keys[#keys + 1] = tab.key end
        return keys
    end

    Layout()
    if opts.selected then strip:Select(opts.selected, true) end
    return strip
end

--------------------------------------------------------------------------------
-- Chips
--------------------------------------------------------------------------------

local function PaintChip(chip, hover)
    local on = chip.selectedOn
    chip.fill:SetColorTexture(Color(on and "glassActive" or (hover and "glassHover" or "glass")))
    chip.under:SetShown(on and true or false)
    chip.label:SetTextColor(Color(on and "accentHi" or (hover and "text" or "muted")))
end

--- A house filter chip, sized to its words. :SetSelected(on) lights it.
function HouseKit.CreateChip(parent, text, onClick, opts)
    opts = opts or {}
    local chip = CreateFrame("Button", nil, parent)
    chip:SetHeight(opts.height or 18)
    chip.fill = Fill(chip, "glass")
    local theme = Theme()
    if theme and theme.Border then pcall(theme.Border, chip, "metal", 0.7) end
    chip.under = chip:CreateTexture(nil, "ARTWORK")
    chip.under:SetPoint("BOTTOMLEFT", 3, 1)
    chip.under:SetPoint("BOTTOMRIGHT", -3, 1)
    chip.under:SetHeight(1)
    chip.under:SetColorTexture(Color("accent"))
    chip.label = Label(chip, "tiny", "muted", "CENTER")
    chip.label:SetPoint("CENTER")
    chip:SetWidth(math.max(34, math.ceil(Measure(chip.label, text) + 16)))
    function chip:SetSelected(on)
        self.selectedOn = on and true or false
        PaintChip(self, false)
    end
    function chip:IsSelected() return self.selectedOn == true end
    function chip:SetText(value)
        self:SetWidth(math.max(34, math.ceil(Measure(self.label, value) + 16)))
    end
    chip:SetScript("OnClick", function(self) if onClick then onClick(self) end end)
    chip:SetScript("OnEnter", function(self) PaintChip(self, true) end)
    chip:SetScript("OnLeave", function(self) PaintChip(self, false) end)
    chip:SetSelected(opts.selected)
    return chip
end

--- Lay chips in a row from `anchor`'s right (or `x` in from its left),
--- `gap` apart. Returns the x past the last.
function HouseKit.RowOfChips(chips, anchor, x, gap)
    gap = gap or 4
    x = x or 0
    for _, chip in ipairs(chips) do
        chip:ClearAllPoints()
        chip:SetPoint("LEFT", anchor, "LEFT", x, 0)
        local ok, width = pcall(chip.GetWidth, chip)
        x = x + ((ok and type(width) == "number") and width or 34) + gap
    end
    return x
end

--------------------------------------------------------------------------------
-- The empty block
--------------------------------------------------------------------------------

--- The block an empty list shows: the emblem faint, one line, and an
--- optional gold button. :Set(text, buttonText, onClick) fills it; a nil
--- buttonText hides the button.
function HouseKit.CreateEmpty(parent, opts)
    opts = opts or {}
    local block = CreateFrame("Frame", nil, parent)
    block:SetSize(opts.width or 320, 110)
    block.emblem = block:CreateTexture(nil, "ARTWORK")
    block.emblem:SetSize(44, 44)
    block.emblem:SetPoint("TOP", 0, 0)
    pcall(block.emblem.SetTexture, block.emblem, EMBLEM)
    block.emblem:SetAlpha(0.22)
    block.text = Label(block, "normal", "muted", "CENTER")
    block.text:SetPoint("TOP", block.emblem, "BOTTOM", 0, -8)
    block.text:SetWidth(opts.width or 320)
    if block.text.SetWordWrap then block.text:SetWordWrap(true) end

    local function MakeButton()
        if rawget(block, "button") then return rawget(block, "button") end
        local Widgets = ns.Widgets
        if Widgets and Widgets.CreateButton then
            block.button = Widgets.CreateButton(block, " ", function()
                local run = rawget(block, "onClick")
                if run then run() end
            end, { primary = true, height = 22, width = 120 })
        end
        local button = rawget(block, "button")
        if button then button:SetPoint("TOP", block.text, "BOTTOM", 0, -10) end
        return button
    end

    function block:Set(text, buttonText, onClick)
        self.text:SetText(text or "")
        self.onClick = onClick
        if buttonText then
            local button = MakeButton()
            if button then
                if button.SetText then button:SetText(buttonText) end
                local width = Measure(self.text, buttonText) + 32
                self.text:SetText(text or "")
                if button.SetWidth then button:SetWidth(math.max(110, math.ceil(width))) end
                button:Show()
            end
        elseif rawget(self, "button") then
            rawget(self, "button"):Hide()
        end
    end
    -- The old empty lines answered SetText; so does the block.
    function block:SetText(text) self:Set(text) end
    function block:GetText() return self.text:GetText() end
    return block
end

--------------------------------------------------------------------------------
-- Panel gems
--------------------------------------------------------------------------------

local MEDIA = ([[Interface\AddOns\%s\Media\Frame\]]):format(ADDON)
HouseKit.PANEL_GEM = 16

local function Text(key)
    local L = ns.L
    return L and L[key] or key
end

local function GemButton(parent, art, glowKey, size)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(size, size)
    local glow = button:CreateTexture(nil, "BACKGROUND")
    pcall(glow.SetTexture, glow, MEDIA .. "Glow")
    glow:SetPoint("CENTER")
    glow:SetSize(size * 2.2, size * 2.2)
    if glow.SetVertexColor then pcall(glow.SetVertexColor, glow, Color(glowKey)) end
    if glow.SetBlendMode then pcall(glow.SetBlendMode, glow, "ADD") end
    local gem = button:CreateTexture(nil, "ARTWORK")
    pcall(gem.SetTexture, gem, MEDIA .. art)
    gem:SetAllPoints(button)
    local lit = button:CreateTexture(nil, "ARTWORK", nil, 1)
    pcall(lit.SetTexture, lit, MEDIA .. art)
    lit:SetAllPoints(button)
    if lit.SetBlendMode then pcall(lit.SetBlendMode, lit, "ADD") end
    local function Light(p)
        glow:SetAlpha(0.25 + 0.55 * p)
        lit:SetAlpha(0.45 * p)
    end
    Light(0)
    button.Light = Light
    button.glow = glow
    return button
end

--- A panel's fold gem and close gem, the house pair, for panels that stay up
--- while you play (they are not dressed windows, so FoldWindow can't take
--- them). opts: onFold(folded), onClose, size. Returns { fold, close } with
--- :SetFolded(on). The close gem sits at the header's right, the fold gem
--- left of it.
function HouseKit.CreatePanelGems(header, opts)
    opts = opts or {}
    local size = opts.size or HouseKit.PANEL_GEM
    local gems = { folded = false }

    local close = GemButton(header, "CloseGem", "loss", size)
    close:SetPoint("RIGHT", header, "RIGHT", -5, 0)
    gems.close = close

    local fold = GemButton(header, "FoldGem", "accent", size)
    fold:SetPoint("RIGHT", close, "LEFT", -4, 0)
    local function Bar(w, h)
        local bar = fold:CreateTexture(nil, "OVERLAY", nil, 2)
        bar:SetColorTexture(0.12, 0.08, 0.03, 1)
        bar:SetSize(w, h)
        bar:SetPoint("CENTER", 0, 0)
        return bar
    end
    fold.across = Bar(math.floor(size * 0.55), 2)
    fold.down = Bar(2, math.floor(size * 0.55))
    fold.down:Hide()
    gems.fold = fold

    local function Tip(button, text)
        if not GameTooltip then return end
        GameTooltip:SetOwner(button, "ANCHOR_TOP")
        GameTooltip:SetText(text, 1, 1, 1)
        GameTooltip:Show()
    end
    local function Hover(button, on, text)
        if ns.Motion and type(ns.Motion.Blend) == "function" then
            ns.Motion:Blend(button, "hover", on and 1 or 0, on and 0.12 or 0.18, button.Light)
        else
            button.Light(on and 1 or 0)
        end
        if on then Tip(button, text()) elseif GameTooltip then GameTooltip:Hide() end
    end
    fold:SetScript("OnEnter", function(self)
        Hover(self, true, function()
            return gems.folded and Text("Expand this window") or Text("Collapse this window")
        end)
    end)
    fold:SetScript("OnLeave", function(self) Hover(self, false) end)
    fold:SetScript("OnClick", function()
        gems:SetFolded(not gems.folded)
        if opts.onFold then opts.onFold(gems.folded) end
    end)
    close:SetScript("OnEnter", function(self) Hover(self, true, function() return Text("Close") end) end)
    close:SetScript("OnLeave", function(self) Hover(self, false) end)
    close:SetScript("OnClick", function() if opts.onClose then opts.onClose() end end)

    function gems:SetFolded(on)
        self.folded = on and true or false
        if self.folded then self.fold.down:Show() else self.fold.down:Hide() end
    end
    return gems
end

-- Hung on Widgets, so each addon calls them the way it calls the rest.
local Widgets = ns.Widgets
if Widgets then
    Widgets.CreateViewTabs = Widgets.CreateViewTabs or HouseKit.CreateViewTabs
    Widgets.CreateEmpty = Widgets.CreateEmpty or HouseKit.CreateEmpty
    Widgets.CreateChip = Widgets.CreateChip or HouseKit.CreateChip
    Widgets.CreatePanelGems = Widgets.CreatePanelGems or HouseKit.CreatePanelGems
end

return HouseKit
