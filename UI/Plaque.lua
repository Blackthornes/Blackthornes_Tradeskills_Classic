-- Blackthornes -- UI/Plaque.lua
-- The gold plaque: the look of a button that sits out on the screen on its
-- own (the owner picked it from a mockup, 2026-10-27, "Option B"). A gold
-- rim with a red gem at each end round dark glass, the item's own icon in a
-- small gold frame, and two short lines: what a click does, and a second
-- line under it (what it uses, how much it gains). It glows softly while it
-- waits for a click.
--
-- The same file in Pets, Equipment and Farmer (a fix to it belongs in all
-- three). Our own art only: flat colours, the house gem and the item's
-- icon from the client. Nothing of the game's frames is touched.
--
-- `Plaque.Create(parent, opts)` makes the button (opts: name, template for
-- a secure button, width for a fixed width whose second line wraps, else
-- it grows to fit its words). It answers:
--   :SetLines(first, second)   the two lines; second may be nil
--   :SetSecondColor(r, g, b)   the second line's colour (nil for the usual)
--   :SetIcon(texture)          a file ID or path; nil hides the frame
--   :SetGlowing(on)            the soft glow that breathes while it waits
--   :Flash()                   one bright gold flash, a small reward
-- The glow breathes only with Effects on Full (Motion.Level), sits still on
-- Subtle and is off on Off. It is one animation the game plays, only while
-- shown, so nothing runs each frame.

local ADDON, ns = ...

local Plaque = {}
ns.Plaque = Plaque

Plaque.HEIGHT = 40
Plaque.RIM = 2
Plaque.ICON = 30
Plaque.PAD = 6
Plaque.GEM = 11
Plaque.GLOW = 7
Plaque.BREATHE = 1.4

-- The rim's gold, top to bottom: bright, deep, dark at the waist, warm.
Plaque.RIM_TOP = { 0.98, 0.89, 0.60 }
Plaque.RIM_MID = { 0.79, 0.57, 0.18 }
Plaque.RIM_WAIST = { 0.54, 0.35, 0.09 }
Plaque.RIM_FOOT = { 0.89, 0.72, 0.35 }
-- The dark glass inside.
Plaque.GLASS_TOP = { 0.157, 0.125, 0.086, 0.96 }
Plaque.GLASS_FOOT = { 0.055, 0.043, 0.031, 0.96 }
Plaque.GLASS_HOT = { 0.220, 0.176, 0.110, 0.98 }
Plaque.FIRST = { 0.97, 0.84, 0.48 }
Plaque.FIRST_HOT = { 1, 0.95, 0.78 }
Plaque.SECOND = { 0.80, 0.73, 0.55 }

local GEM_ART = ([[Interface\AddOns\%s\Media\Frame\CloseGem.tga]]):format(ADDON)

--- A vertical colour gradient, bottom to top; a flat colour when the
--- client can't draw one.
local function Gradient(texture, bottom, top)
    texture:SetColorTexture(1, 1, 1, 1)
    local ok = false
    if type(CreateColor) == "function" and type(texture.SetGradient) == "function" then
        ok = pcall(texture.SetGradient, texture, "VERTICAL",
            CreateColor(bottom[1], bottom[2], bottom[3], bottom[4] or 1),
            CreateColor(top[1], top[2], top[3], top[4] or 1))
    end
    if not ok then
        texture:SetColorTexture(top[1], top[2], top[3], top[4] or 1)
    end
end
Plaque.Gradient = Gradient

--- How wide `text` is at `size`: the addon's own measure, Tradeskills'
--- MeasureText or the others' TextWidth(size, text), 0 when it can't say.
local function TextWidth(size, text)
    local Theme = ns.Theme
    local measure = Theme.MeasureText or Theme.TextWidth
    local ok, width = pcall(measure, size, text)
    return (ok and type(width) == "number") and width or 0
end
Plaque.TextWidth = TextWidth

--- How tall a wrapped label's words stand at `room` wide: the game's own
--- answer, else lines counted from the words' width.
function Plaque.TextHeight(label, size, room)
    local text = label:GetText() or ""
    if text == "" then return 0 end
    local ok, high = pcall(label.GetStringHeight, label)
    if ok and type(high) == "number" and high > 0 then return high end
    local Theme = ns.Theme
    local line = (Theme.sizes and Theme.sizes[size] or 12) + 2
    local wide = TextWidth(size, text)
    return line * math.max(1, math.ceil(wide / math.max(1, room)))
end

local function Level()
    local Motion = ns.Motion
    return Motion and Motion.Level and Motion.Level() or "full"
end

--- A soft gold glow round the outside of `frame`, on a frame of its own so
--- its alpha can breathe without touching the plaque.
local function GlowFrame(owner)
    local glow = CreateFrame("Frame", nil, owner)
    glow:SetAllPoints(owner)
    glow:SetFrameLevel(math.max(0, (owner:GetFrameLevel() or 1) - 1))
    if ns.Theme and ns.Theme.Halo then
        ns.Theme.Halo(glow, Plaque.GLOW, 0.55, "accent")
    end
    glow:Hide()

    if type(glow.CreateAnimationGroup) == "function" then
        local ok, group = pcall(glow.CreateAnimationGroup, glow)
        if ok and group then
            pcall(group.SetLooping, group, "BOUNCE")
            local ok2, fade = pcall(group.CreateAnimation, group, "Alpha")
            if ok2 and fade then
                pcall(fade.SetFromAlpha, fade, 1)
                pcall(fade.SetToAlpha, fade, 0.35)
                pcall(fade.SetDuration, fade, Plaque.BREATHE)
                pcall(fade.SetSmoothing, fade, "IN_OUT")
                glow.breathe = group
            end
        end
    end
    return glow
end

function Plaque.Create(parent, opts)
    opts = opts or {}
    local Theme = ns.Theme
    local RIM, PAD, ICON = Plaque.RIM, Plaque.PAD, Plaque.ICON

    local button = CreateFrame("Button", opts.name, parent, opts.template)
    button:SetHeight(opts.height or Plaque.HEIGHT)
    local fixedWidth = opts.width
    if opts.width then button:SetWidth(opts.width) end

    local glow = GlowFrame(button)
    button.glow = glow

    -- The rim: two halves, each its own gradient, so the gold has a waist.
    local rimTop = button:CreateTexture(nil, "BACKGROUND", nil, 1)
    rimTop:SetPoint("TOPLEFT")
    rimTop:SetPoint("TOPRIGHT")
    rimTop:SetPoint("BOTTOM", button, "CENTER")
    Gradient(rimTop, Plaque.RIM_MID, Plaque.RIM_TOP)
    local rimFoot = button:CreateTexture(nil, "BACKGROUND", nil, 1)
    rimFoot:SetPoint("BOTTOMLEFT")
    rimFoot:SetPoint("BOTTOMRIGHT")
    rimFoot:SetPoint("TOP", button, "CENTER")
    Gradient(rimFoot, Plaque.RIM_FOOT, Plaque.RIM_WAIST)

    local glass = button:CreateTexture(nil, "BACKGROUND", nil, 2)
    glass:SetPoint("TOPLEFT", RIM, -RIM)
    glass:SetPoint("BOTTOMRIGHT", -RIM, RIM)
    Gradient(glass, Plaque.GLASS_FOOT, Plaque.GLASS_TOP)
    button.glass = glass

    local shine = button:CreateTexture(nil, "BACKGROUND", nil, 3)
    shine:SetPoint("TOPLEFT", glass, "TOPLEFT")
    shine:SetPoint("TOPRIGHT", glass, "TOPRIGHT")
    shine:SetHeight(1)
    shine:SetColorTexture(1, 0.9, 0.63, 0.18)

    -- The icon in a small gold frame of its own.
    local frameTex = button:CreateTexture(nil, "BORDER", nil, 1)
    frameTex:SetSize(ICON + 4, ICON + 4)
    frameTex:SetPoint("LEFT", RIM + 3, 0)
    Gradient(frameTex, Plaque.RIM_WAIST, Plaque.RIM_TOP)
    local well = button:CreateTexture(nil, "BORDER", nil, 2)
    well:SetPoint("TOPLEFT", frameTex, "TOPLEFT", 2, -2)
    well:SetPoint("BOTTOMRIGHT", frameTex, "BOTTOMRIGHT", -2, 2)
    well:SetColorTexture(0.105, 0.078, 0.051, 1)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", well, "TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -1, 1)
    pcall(icon.SetTexCoord, icon, 0.08, 0.92, 0.08, 0.92)
    button.icon, button.iconFrame, button.iconWell = icon, frameTex, well

    -- A red gem at each end, on the rim.
    button.gems = {}
    for _, side in ipairs({ "LEFT", "RIGHT" }) do
        local gem = button:CreateTexture(nil, "OVERLAY", nil, 2)
        gem:SetSize(Plaque.GEM, Plaque.GEM)
        gem:SetTexture(GEM_ART)
        gem:SetPoint("CENTER", button, side, 0, 0)
        button.gems[#button.gems + 1] = gem
    end

    -- The bright flash a reward lights, over everything but the words.
    local flash = button:CreateTexture(nil, "OVERLAY", nil, 1)
    flash:SetPoint("TOPLEFT", RIM, -RIM)
    flash:SetPoint("BOTTOMRIGHT", -RIM, RIM)
    flash:SetColorTexture(1, 0.85, 0.4, 1)
    pcall(flash.SetBlendMode, flash, "ADD")
    flash:SetAlpha(0)
    button.flash = flash

    local first = Theme.CreateLabel(button, "normal", "gilt", "LEFT")
    first:SetTextColor(unpack(Plaque.FIRST))
    first:SetShadowOffset(1, -1)
    first:SetShadowColor(0, 0, 0, 1)
    local second = Theme.CreateLabel(button, "small", "muted", "LEFT")
    second:SetTextColor(unpack(Plaque.SECOND))
    second:SetShadowOffset(1, -1)
    second:SetShadowColor(0, 0, 0, 1)
    if opts.width then
        pcall(first.SetWordWrap, first, true)
        pcall(second.SetWordWrap, second, true)
    end
    button.first, button.second = first, second
    local baseHeight = opts.height or Plaque.HEIGHT

    local function TextLeft()
        return (icon:IsShown() and (RIM + 3 + ICON + 4 + PAD)) or (RIM + PAD + 4)
    end

    local function Layout()
        local left = TextLeft()
        local right = RIM + PAD + 4
        first:ClearAllPoints()
        second:ClearAllPoints()
        local hasSecond = (second:GetText() or "") ~= ""
        if hasSecond then
            first:SetPoint("BOTTOMLEFT", button, "LEFT", left, 1)
            second:SetPoint("TOPLEFT", button, "LEFT", left, -1)
        else
            first:SetPoint("LEFT", button, "LEFT", left, 0)
        end
        second:SetShown(hasSecond)
        if fixedWidth then
            -- A fixed width wraps both lines and grows taller to fit them,
            -- so a longer word in another language is never cut short.
            local room = math.max(20, fixedWidth - left - right)
            first:SetWidth(room)
            second:SetWidth(room)
            local high1 = Plaque.TextHeight(first, "normal", room)
            local high2 = hasSecond and Plaque.TextHeight(second, "small", room) or 0
            local words = high1 + (hasSecond and (2 + high2) or 0)
            first:ClearAllPoints()
            second:ClearAllPoints()
            first:SetPoint("TOPLEFT", button, "LEFT", left, words / 2)
            if hasSecond then second:SetPoint("TOPLEFT", first, "BOTTOMLEFT", 0, -2) end
            local height = math.max(baseHeight, math.ceil(words) + 2 * (RIM + PAD))
            button:SetHeight(height)
            button.fitHeight = height
            return
        end
        local wide = TextWidth("normal", first:GetText() or "")
        if hasSecond then wide = math.max(wide, TextWidth("small", second:GetText() or "")) end
        button:SetWidth(math.max(opts.minWidth or 60, left + wide + right + 4))
    end
    button.Layout = Layout

    function button:SetLines(text1, text2)
        first:SetText(text1 or "")
        second:SetText(text2 or "")
        Layout()
    end

    function button:SetSecondColor(r, g, b)
        if r then second:SetTextColor(r, g, b) else second:SetTextColor(unpack(Plaque.SECOND)) end
    end

    function button:SetIcon(texture)
        local shown = texture ~= nil
        if shown then icon:SetTexture(texture) end
        icon:SetShown(shown)
        frameTex:SetShown(shown)
        well:SetShown(shown)
        Layout()
    end

    function button:SetGlowing(on)
        local level = Level()
        local breathe = rawget(glow, "breathe")
        if not on or level == "off" then
            if breathe then pcall(breathe.Stop, breathe) end
            glow:Hide()
            return
        end
        glow:Show()
        if breathe then
            pcall(level == "full" and breathe.Play or breathe.Stop, breathe)
        end
    end

    --- One quick gold flash, fading out (Effects on Full or Subtle).
    function button:Flash()
        if Level() == "off" then return end
        local Motion = ns.Motion
        if not (Motion and Motion.Run) then return end
        Motion:Run(flash, "flash", 0.6, function(p)
            flash:SetAlpha(0.55 * (1 - p))
        end)
    end

    local function Light(p)
        local r1, g1, b1, a1 = unpack(Plaque.GLASS_TOP)
        local r2, g2, b2, a2 = unpack(Plaque.GLASS_HOT)
        Gradient(glass, Plaque.GLASS_FOOT, {
            r1 + (r2 - r1) * p, g1 + (g2 - g1) * p, b1 + (b2 - b1) * p, a1 + (a2 - a1) * p,
        })
        local f, h = Plaque.FIRST, Plaque.FIRST_HOT
        first:SetTextColor(f[1] + (h[1] - f[1]) * p, f[2] + (h[2] - f[2]) * p, f[3] + (h[3] - f[3]) * p)
    end
    button.Light = Light

    button:SetScript("OnEnter", function(self)
        local Motion = ns.Motion
        if Motion and Motion.Blend then Motion:Blend(self, "hover", 1, 0.12, Light) else Light(1) end
    end)
    button:SetScript("OnLeave", function(self)
        local Motion = ns.Motion
        if Motion and Motion.Blend then Motion:Blend(self, "hover", 0, 0.18, Light) else Light(0) end
    end)

    button:SetIcon(nil)
    return button
end
