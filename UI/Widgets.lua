-- Blackthornes Tradeskills -- UI/Widgets.lua
-- Reusable controls, built from scratch so the addon looks like one piece of
-- software rather than a pile of Blizzard templates.
--
-- The important one is CreateScrollList: it recycles a fixed handful of row
-- frames regardless of how many rows the data has. With 600+ recipes and
-- thousands of auction items, a frame per row would stutter badly.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Widgets = {}
ns.Widgets = Widgets

local Theme = ns.Theme

--------------------------------------------------------------------------------
-- Motion
--
-- Farmer's small tweens, so the two addons move alike: a button easing into
-- its hover colour, a window fading up as it opens with its glow flaring, the
-- gold line under the tabs gliding to the one picked. The "Window effects"
-- setting picks Full, Subtle (no rise, shorter fades) or Off (every tween
-- lands at its end at once).
--
-- One OnUpdate on one small frame, shown only while something is moving, so
-- an idle window costs nothing per frame. A tween that errors is dropped
-- rather than raised: a hover colour must never break a click.
--------------------------------------------------------------------------------

local Motion = {}
ns.Motion = Motion

Motion.tweens = {}

--- "full", "subtle" or "off", from the Window effects setting.
function Motion.Level()
    local level = ns.Config and ns.Config.Get and ns.Config:Get("windowEffects")
    if level == "off" or level == "subtle" then return level end
    return "full"
end

function Motion.EaseOut(p)
    return 1 - (1 - p) ^ 3
end

--- Overshoots a touch and settles, for things that should feel like they
--- landed.
function Motion.EaseOutBack(p)
    local c = 1.4
    return 1 + (c + 1) * (p - 1) ^ 3 + c * (p - 1) ^ 2
end

--- Two colours mixed, `p` of the way from `a` to `b`. Each is a palette key
--- or an { r, g, b, a } list.
function Motion.Mix(a, b, p, alphaA, alphaB)
    local r1, g1, b1, a1
    if type(a) == "table" then r1, g1, b1, a1 = a[1], a[2], a[3], alphaA or a[4] or 1
    else r1, g1, b1, a1 = Theme.Unpack(a, alphaA) end

    local r2, g2, b2, a2
    if type(b) == "table" then r2, g2, b2, a2 = b[1], b[2], b[3], alphaB or b[4] or 1
    else r2, g2, b2, a2 = Theme.Unpack(b, alphaB) end

    return r1 + (r2 - r1) * p, g1 + (g2 - g1) * p, b1 + (b2 - b1) * p, a1 + (a2 - a1) * p
end

function Motion:Driver()
    if self.driver then return self.driver end

    local driver = CreateFrame("Frame", nil, UIParent)
    driver:SetScript("OnUpdate", function(_, elapsed) Motion:Step(elapsed) end)
    driver:Hide()

    self.driver = driver
    return driver
end

local function Finish(tween)
    pcall(tween.apply, 1)
    if tween.done then pcall(tween.done) end
end

--- Run `apply(p)` with p going 0 to 1 over `duration` seconds.
--
-- `owner` and `slot` name the tween: a new one for the same owner and slot
-- replaces the old, so hovering on and off quickly never leaves two fighting.
-- opts: delay (seconds before it starts), done (called at the end), ease
-- (a function of p; EaseOut unless given, false for linear).
function Motion:Run(owner, slot, duration, apply, opts)
    opts = opts or {}

    self:Stop(owner, slot)

    local tween = { owner = owner, slot = slot, duration = duration or 0.2,
        apply = apply, done = opts.done, age = -(opts.delay or 0) }

    local ease = opts.ease
    if ease == nil then ease = Motion.EaseOut end
    tween.ease = ease or nil

    if self.Level() == "off" or tween.duration <= 0 then
        Finish(tween)
        return
    end

    -- Drawn at its start now, so nothing flashes at its end for a frame
    -- before the first step.
    pcall(apply, 0)

    self.tweens[#self.tweens + 1] = tween
    self:Driver():Show()
end

--- Stop a running tween where it is. `finish` lands it at its end first.
function Motion:Stop(owner, slot, finish)
    for index = #self.tweens, 1, -1 do
        local tween = self.tweens[index]
        if tween.owner == owner and (slot == nil or tween.slot == slot) then
            table.remove(self.tweens, index)
            if finish then Finish(tween) end
        end
    end
end

--- Whether a tween is running for this owner (and slot, when given).
function Motion:Running(owner, slot)
    for _, tween in ipairs(self.tweens) do
        if tween.owner == owner and (slot == nil or tween.slot == slot) then return true end
    end
    return false
end

--- Land every running tween at its end. For the tests, and for effects
--- being turned off mid-animation.
function Motion:FinishAll()
    local tweens = self.tweens
    self.tweens = {}
    for _, tween in ipairs(tweens) do Finish(tween) end
    if self.driver then self.driver:Hide() end
end

function Motion:Step(elapsed)
    elapsed = tonumber(elapsed) or 0

    local live = {}
    local tweens = self.tweens
    self.tweens = live

    for _, tween in ipairs(tweens) do
        tween.age = tween.age + elapsed

        if tween.age >= 0 then
            local p = math.min(1, tween.age / tween.duration)
            local eased = tween.ease and tween.ease(p) or p
            local ok = pcall(tween.apply, eased)

            if not ok or p >= 1 then
                if ok and tween.done then pcall(tween.done) end
            else
                live[#live + 1] = tween
            end
        else
            live[#live + 1] = tween
        end
    end

    -- Tweens started from inside an apply or done landed in `live` already.
    if #self.tweens == 0 and self.driver then self.driver:Hide() end
end

-- Blended values, kept here rather than as fields on the frames so they never
-- collide with a frame's own keys.
Motion.values = setmetatable({}, { __mode = "k" })

--- Where Blend last left `owner`'s `slot`: 0 until it has moved.
function Motion:Value(owner, slot)
    local values = self.values[owner]
    return values and values[slot] or 0
end

function Motion:SetValue(owner, slot, value)
    local values = self.values[owner]
    if not values then
        values = {}
        self.values[owner] = values
    end
    values[slot] = value
end

--- Ease a number kept on `owner` toward `target`, calling `apply(value)` as
--- it goes. Starts from wherever the last one left it, so a hover that is
--- undone halfway turns round smoothly instead of jumping.
function Motion:Blend(owner, slot, target, duration, apply)
    local from = self:Value(owner, slot)
    if from == target and not self:Running(owner, slot) then
        apply(target)
        return
    end

    self:Run(owner, slot, duration, function(p)
        local value = from + (target - from) * p
        self:SetValue(owner, slot, value)
        apply(value)
    end, { ease = false })
end

--- Fade a window up as it opens: from clear, and a few pixels low, with its
--- glow (Theme.Halo) flaring and settling.
--
-- Only the alpha and one point's offset move, so the window's saved spot is
-- never touched: the last step puts back exactly the point it started with.
-- `rise` 0 keeps it still, for a panel docked beside another window.
function Motion:Open(frame, rise)
    if not frame then return end

    -- Opened again before the last opening finished: land that one first,
    -- which puts its point back, or the window would start from the
    -- lowered spot and settle a few pixels further down every time.
    self:Stop(frame, "open", true)

    local rest = frame.haloTextures and frame.haloRest
    if rest then
        self:Run(frame, "halo", 0.7, function(p)
            Theme.SetHalo(frame, rest * 3.2 + (rest - rest * 3.2) * p)
        end)
    end

    local level = self.Level()
    if level == "off" then
        frame:SetAlpha(1)
        return
    end

    rise = level == "full" and (rise or 8) or 0

    local point, relativeTo, relativePoint, x, y = frame:GetPoint(1)
    local canMove = rise ~= 0 and point ~= nil and type(x) == "number" and type(y) == "number"
        and (frame.GetNumPoints == nil or frame:GetNumPoints() == 1)

    self:Run(frame, "open", level == "full" and 0.2 or 0.12, function(p)
        frame:SetAlpha(p)
        if canMove then
            frame:SetPoint(point, relativeTo, relativePoint, x, y - rise * (1 - p))
        end
    end)
end

--- A window's glow at rest again, and the window drawn in full, at once: for
--- a window hidden mid-opening, so it never comes back half faded.
function Motion:Settle(frame)
    if not frame then return end
    self:Stop(frame, "open", true)
    self:Stop(frame, "halo", true)
end

if ns.RegisterCommand then
    ns.RegisterCommand("effects", "how much the windows move: /bts effects [full|subtle|off]", function(args)
        local choice = (args or ""):lower():gsub("%s", "")
        local said = {
            full = "window effects: full. Windows fade up and glow as they open, and buttons ease.",
            subtle = "window effects: subtle. Shorter fades, and nothing rises.",
            off = "window effects off. /bts effects full turns them back on.",
        }

        if not said[choice] then
            ns.Print(("window effects are %s. /bts effects full, subtle or off changes them."):format(
                Motion.Level()))
            return
        end

        ns.Config:Set("windowEffects", choice)
        if choice == "off" then Motion:FinishAll() end
        ns.Print(said[choice])
        if ns.UI and ns.UI.RefreshActiveTab then ns.UI:RefreshActiveTab() end
    end)
end

--------------------------------------------------------------------------------
-- Button
--------------------------------------------------------------------------------

function Widgets.CreateButton(parent, text, onClick, opts)
    opts = opts or {}

    local button = CreateFrame("Button", nil, parent)
    button:SetSize(opts.width or 90, opts.height or 22)

    -- Titanforged (2026-10-04): every button is raised metal, a dark face
    -- in a gold edge with a gold label, lit and glowing under the mouse. The
    -- primary action is solid gold with dark lettering, so the one button
    -- that does the main thing on a screen stands out at a glance.
    local baseKey = opts.primary and "accent" or "row"
    local hotFill = opts.primary and "accentHi" or opts.danger and "rowHover" or "rowActive"

    button.background = Theme.Fill(button, baseKey)

    -- A danger button (opts.danger: takes something away, like Ignore)
    -- wears red, label and edge, so it never reads as plain text.
    local borderKey = opts.primary and "accentHi" or opts.danger and "loss" or "metal"
    local borderAlpha = opts.danger and 0.7 or nil
    -- Dark lettering only on a gold face: a primary button given its own
    -- dark resting colour (opts.baseColor) keeps the gold label, or its text
    -- would be dark on dark.
    -- The Blizzard window style has no gold face: every button wears the
    -- game's red with a gold label (UI/BlizzardLook.lua). A client missing
    -- that art keeps the house face, so the label is picked to suit it.
    local Look = ns.BlizzardLook
    local blizzard = Look and Look.DressesButtons()
    local goldFace = opts.primary and not opts.baseColor and not blizzard
    local labelKey = goldFace and "ink" or opts.danger and "loss" or "gilt"
    local labelHot = goldFace and "ink" or opts.danger and "loss" or { 1, 0.953, 0.784 }
    Theme.Border(button, borderKey, borderAlpha)
    button.sheen = Theme.TopSheen(button, 0.10)
    if Theme.Bevel then button.bevel = { Theme.Bevel(button) } end

    -- An explicit resting colour, for buttons that sit over the game world and
    -- need to stay fully opaque rather than picking up the panel palette.
    button.baseColor = opts.baseColor

    local function ApplyBaseColor(self)
        if self.disabled then
            self.background:SetColorTexture(Theme.Unpack("panel"))
        elseif self.baseColor then
            self.background:SetColorTexture(unpack(self.baseColor))
        else
            self.background:SetColorTexture(Theme.Unpack(baseKey))
        end
    end

    button.ApplyBaseColor = ApplyBaseColor

    button.label = Theme.CreateLabel(button, opts.fontSize or "small",
        labelKey, "CENTER")
    -- Held inside the button, so a label longer than the button ends in
    -- "..." instead of spilling over whatever sits beside it. The little
    -- symbol buttons (+, -, x) stay centred: their insets would leave no
    -- room for the symbol itself.
    -- Narrow buttons ("Set goal", "Queue tab") get thinner insets, or their
    -- labels would be the ones cut short.
    if (opts.width or 90) >= 40 then
        local inset = (opts.width or 90) < 70 and 2 or 4
        button.label:SetPoint("LEFT", inset, 0)
        button.label:SetPoint("RIGHT", -inset, 0)
        button.label:SetWordWrap(false)
    else
        button.label:SetPoint("CENTER")
    end
    button.label:SetText(text)

    function button:SetText(value)
        self.label:SetText(value)
    end

    -- The edge at rest: red while the button waits for its second click.
    local function ApplyBorder(self)
        if self.outline then return end
        if self.disabled then
            Theme.SetBorderColor(self, "border", 0.6)
        elseif self.confirming then
            Theme.SetBorderColor(self, "loss")
        else
            Theme.SetBorderColor(self, borderKey, borderAlpha)
        end
    end

    local function ApplyLabelColor(self, p)
        if self.disabled or self.confirming then
            self.label:SetTextColor(Theme.Unpack(self.disabled and "dim" or "loss"))
        else
            self.label:SetTextColor(Motion.Mix(labelKey, labelHot, p or 0))
        end
    end

    -- Every button glows round its edge under the mouse, as Farmer's do;
    -- the primary one glows a little even at rest. A button sitting over
    -- the game world (opts.baseColor) keeps to its own look.
    local haloRest = opts.primary and 0.12 or 0
    if Theme.Halo and not opts.baseColor then
        Theme.Halo(button, 5, haloRest, opts.danger and "loss" or "accent")
    end

    --- How lit the button is: 0 at rest, 1 under the mouse. Everything the
    --- mouse changes is drawn from this one number, so easing it eases the
    --- lot, and a state change mid-hover redraws from where the hover is.
    local hotEdge = opts.danger and "loss" or "accentHi"

    local function Light(self, p)
        if self.disabled then p = 0 end

        local r, g, b, a
        if self.disabled then
            r, g, b, a = Theme.Unpack("panel")
        elseif self.baseColor then
            r, g, b, a = self.baseColor[1], self.baseColor[2], self.baseColor[3], self.baseColor[4] or 1
        else
            r, g, b, a = Theme.Unpack(baseKey)
        end
        if not self.baseColor and not self.disabled then
            local hr, hg, hb = Theme.Unpack(hotFill)
            r, g, b = r + (hr - r) * p, g + (hg - g) * p, b + (hb - b) * p
        else
            local hr, hg, hb = Theme.Unpack("rowHover")
            r, g, b = r + (hr - r) * p, g + (hg - g) * p, b + (hb - b) * p
        end

        -- Held down, the fill sinks a shade toward the window behind it, so
        -- the press shows in the button as well as in its label.
        if rawget(self, "held") and not self.disabled then
            local wr, wg, wb = Theme.Unpack("window")
            r, g, b = r + (wr - r) * 0.35, g + (wg - g) * 0.35, b + (wb - b) * 0.35
        end

        self.background:SetColorTexture(r, g, b, a)

        -- An outlined button keeps its own edge colour; drawing over it here
        -- would undo the outline on the first mouseover.
        if not self.outline then
            local edges = rawget(self, "borderTextures")
            if self.disabled or self.confirming or p <= 0 or type(edges) ~= "table" then
                ApplyBorder(self)
            else
                local er, eg, eb, ea = Motion.Mix(borderKey, hotEdge, p, borderAlpha or 1, 1)
                for _, edge in ipairs(edges) do
                    edge:SetColorTexture(er, eg, eb, ea)
                end
            end
        end

        if rawget(self, "haloTextures") then
            Theme.SetHalo(self, self.disabled and 0 or haloRest + (0.4 - haloRest) * p)
        end
        ApplyLabelColor(self, p)
    end

    local HOVER_TIME = 0.12

    function button:SetEnabledState(enabled)
        self.disabled = not enabled
        ApplyLabelColor(self)
        Light(self, Motion:Value(self, "hover"))
    end

    --- Waiting for a second click to confirm ("Really clear?"): red label
    --- and a red edge until it is set back.
    function button:SetConfirming(on)
        self.confirming = on and true or false
        ApplyLabelColor(self)
        Light(self, Motion:Value(self, "hover"))
    end

    button:SetScript("OnEnter", function(self)
        Motion:Blend(self, "hover", 1, HOVER_TIME, function(value) Light(self, value) end)

        -- tooltipText is set at runtime, so a button can explain why it is
        -- currently unavailable rather than just looking dead.
        local text = self.tooltipText or opts.tooltip

        -- A button showing a countdown or "wait" says what it is waiting
        -- for first, since the label alone cannot.
        if self.waitingLabel == true and type(self.waitTip) == "string" then
            local wait = L.Format("|c%sWaiting: %s.|r", ns.COLORS.warn, self.waitTip)
            text = text and (wait .. "\n\n" .. text) or wait
        end

        -- A button can draw its own tooltip (List Next's preview); the
        -- wait line still goes first.
        if type(rawget(self, "tooltipFunc")) == "function" then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            local wait = self.waitingLabel == true and type(self.waitTip) == "string"
                and L.Format("|c%sWaiting: %s.|r", ns.COLORS.warn, self.waitTip) or nil
            local ok, drawn = pcall(self.tooltipFunc, self, GameTooltip, wait)
            if ok and drawn then
                GameTooltip:Show()
                return
            end
        end

        if text then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(text, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)

    button:SetScript("OnLeave", function(self)
        Motion:Blend(self, "hover", 0, HOVER_TIME * 1.5, function(value) Light(self, value) end)
        GameTooltip:Hide()
    end)

    -- The label dips a pixel while the button is held, so a click feels
    -- pressed. Every point the label has moves together, and goes back to
    -- exactly where it was.
    button:SetScript("OnMouseDown", function(self)
        if self.disabled or rawget(self, "pressedPoints") then return end

        self.held = true
        Light(self, Motion:Value(self, "hover"))

        local count = self.label.GetNumPoints and self.label:GetNumPoints()
        if type(count) ~= "number" or count < 1 then return end

        local points = {}
        for index = 1, count do
            local point, relativeTo, relativePoint, x, y = self.label:GetPoint(index)
            if not (point and type(x) == "number" and type(y) == "number") then return end
            points[index] = { point, relativeTo, relativePoint, x, y }
        end

        self.pressedPoints = points
        self.label:ClearAllPoints()
        for _, p in ipairs(points) do self.label:SetPoint(p[1], p[2], p[3], p[4], p[5] - 1) end
    end)

    local function Release(self)
        if rawget(self, "held") then
            self.held = nil
            Light(self, Motion:Value(self, "hover"))
        end

        local points = rawget(self, "pressedPoints")
        if not points then return end

        self.pressedPoints = nil
        self.label:ClearAllPoints()
        for _, p in ipairs(points) do self.label:SetPoint(p[1], p[2], p[3], p[4], p[5]) end
    end

    button:SetScript("OnMouseUp", Release)
    if button.HookScript then button:HookScript("OnHide", Release) end

    button:SetScript("OnClick", function(self, mouseButton)
        if self.disabled then return end
        if onClick then onClick(self, mouseButton) end
    end)

    if blizzard then Look.Button(button) end

    return button
end

--------------------------------------------------------------------------------
-- Item tooltip
--------------------------------------------------------------------------------

--- Start a tooltip for an item row with the game's own tooltip for the item,
--- the one the bags show, so hovering a name inside the addon shows the item
--- itself (2026-09-26). The addon's value lines join it the same way
--- they join any item tooltip. Falls back to the plain name when the game
--- cannot draw the item.
--
-- The caller adds its own lines after this and calls GameTooltip:Show().
function Widgets.ShowItemTooltip(owner, anchor, itemID, fallback, link)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")

    local shown = false
    -- A link shows that very copy, random suffix and all.
    if link and GameTooltip.SetHyperlink then
        shown = pcall(GameTooltip.SetHyperlink, GameTooltip, link)
    end
    if not shown and itemID and GameTooltip.SetItemByID then
        shown = pcall(GameTooltip.SetItemByID, GameTooltip, itemID)
    end

    local ok, count = pcall(GameTooltip.NumLines, GameTooltip)
    if not shown or not ok or (tonumber(count) or 0) == 0 then
        GameTooltip:SetText(fallback or L["item"], 1, 1, 1)
        return false
    end

    return true
end

--- A row whose whole tooltip is the item's own.
function Widgets.ShowItemOnly(owner, itemID, fallback)
    if not itemID then return end
    Widgets.ShowItemTooltip(owner, "ANCHOR_RIGHT", itemID, fallback)
    GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- Checkbox
--------------------------------------------------------------------------------

function Widgets.CreateCheckbox(parent, text, onToggle, initial)
    local checkbox = CreateFrame("Button", nil, parent)
    checkbox:SetHeight(18)

    local box = CreateFrame("Frame", nil, checkbox)
    box:SetSize(14, 14)
    box:SetPoint("LEFT")
    -- A small dark well in a gold edge, glowing when ticked (Titanforged).
    Theme.Fill(box, "well")
    Theme.Border(box, "metal")
    if Theme.Halo then Theme.Halo(box, 4, 0) end

    local tick = box:CreateTexture(nil, "OVERLAY")
    tick:SetPoint("CENTER")
    tick:SetSize(8, 8)
    tick:SetColorTexture(Theme.Unpack("accent"))
    checkbox.tick = tick

    local label = Theme.CreateLabel(checkbox, "small", "text")
    label:SetPoint("LEFT", box, "RIGHT", 6, 0)
    label:SetText(text)
    checkbox.label, checkbox.box = label, box

    checkbox:SetWidth(label:GetStringWidth() + 24)
    checkbox.checked = initial and true or false

    local function PaintBox(hovered)
        tick:SetShown(checkbox.checked)
        tick:SetColorTexture(Theme.Unpack(checkbox.checked and "accentHi" or "accent"))
        Theme.SetBorderColor(box, checkbox.checked and "accentHi"
            or hovered and "accent" or "metal")
        if rawget(box, "haloTextures") then
            Theme.SetHalo(box, checkbox.checked and 0.3 or hovered and 0.15 or 0)
        end
    end

    PaintBox(false)

    function checkbox:SetChecked(value)
        self.checked = value and true or false
        PaintBox(false)
    end

    function checkbox:GetChecked()
        return self.checked
    end

    --- New words beside the box, the box widened to fit them.
    function checkbox:SetLabel(words)
        label:SetText(words)
        self:SetWidth(label:GetStringWidth() + 24)
    end

    checkbox:SetScript("OnClick", function(self)
        self:SetChecked(not self.checked)

        -- Ticked by hand, the tick pops in: a little past full size, then
        -- settles. Set from code (a page refreshing) it is simply there.
        if self.checked then
            Motion:Run(tick, "pop", 0.22, function(p)
                local size = math.max(1, 8 * p)
                tick:SetSize(size, size)
            end, { ease = Motion.EaseOutBack })
        end

        if onToggle then onToggle(self.checked) end
    end)

    checkbox:SetScript("OnEnter", function()
        Motion:Blend(checkbox, "hover", 1, 0.12, function(p)
            label:SetTextColor(Motion.Mix("text", "accent", p))
        end)
        PaintBox(true)
    end)
    checkbox:SetScript("OnLeave", function()
        Motion:Blend(checkbox, "hover", 0, 0.18, function(p)
            label:SetTextColor(Motion.Mix("text", "accent", p))
        end)
        PaintBox(false)
    end)

    if ns.BlizzardLook then ns.BlizzardLook.Checkbox(checkbox, box, tick) end

    return checkbox
end

--------------------------------------------------------------------------------
-- Search box
--------------------------------------------------------------------------------

-- One width for the search box on every tab's option bar, so it sits in the
-- same place whichever tab is open.
Widgets.SEARCH_WIDTH = 170

function Widgets.CreateSearchBox(parent, placeholder, onChange)
    local container = Theme.CreatePanel(parent, "row")
    container:SetHeight(22)

    -- Sunk into the window, and glowing gold while it has the keyboard
    -- (Titanforged).
    if Theme.Recess then Theme.Recess(container) end
    if Theme.Halo then Theme.Halo(container, 6, 0) end

    -- The game's own magnifier, so the box reads as search at a glance, as
    -- Farmer's does. It turns gold while the box has the keyboard.
    local icon = container:CreateTexture(nil, "ARTWORK")
    icon:SetSize(12, 12)
    icon:SetPoint("LEFT", 6, 0)
    icon:SetTexture([[Interface\Common\UI-Searchbox-Icon]])
    icon:SetVertexColor(Theme.Unpack("muted"))
    container.icon = icon

    local editBox = CreateFrame("EditBox", nil, container)
    editBox:SetPoint("TOPLEFT", 22, 0)
    editBox:SetPoint("BOTTOMRIGHT", -20, 0)
    editBox:SetAutoFocus(false)
    editBox:SetFont(Theme.FONT, Theme.sizes.small, "")
    editBox:SetTextColor(Theme.Unpack("text"))

    local hint = Theme.CreateLabel(container, "small", "dim")
    hint:SetPoint("LEFT", 22, 0)
    hint:SetText(placeholder or L["Search"])
    container.hint = hint

    -- A target bigger than the letter on it, filling the gap the edit box
    -- leaves at the right, and lit gold under the mouse so it reads as a
    -- button.
    local clear = CreateFrame("Button", nil, container)
    clear:SetSize(18, 18)
    clear:SetPoint("RIGHT", -2, 0)

    local clearLabel = Theme.CreateLabel(clear, "small", "muted", "CENTER")
    clearLabel:SetPoint("CENTER")
    clearLabel:SetText("x")
    clear:Hide()

    local function LightClear(p) clearLabel:SetTextColor(Motion.Mix("muted", "accent", p)) end
    clear:SetScript("OnEnter", function(self) Motion:Blend(self, "hover", 1, 0.1, LightClear) end)
    clear:SetScript("OnLeave", function(self) Motion:Blend(self, "hover", 0, 0.15, LightClear) end)

    -- It hides under the mouse when clicked; it comes back unlit.
    clear:SetScript("OnHide", function(self)
        Motion:Stop(self, "hover")
        Motion:SetValue(self, "hover", 0)
        LightClear(0)
    end)

    local function Update()
        local text = editBox:GetText()
        hint:SetShown(text == "")
        clear:SetShown(text ~= "")
        if onChange then onChange(text) end
    end

    -- Gold edge while typing, lit on hover, so it is clear where the keys go.
    -- Both ease in and out; the keyboard's gold wins over the mouse's light.
    local function Paint()
        local hover = Motion:Value(container, "hover")
        local focus = Motion:Value(container, "focus")

        local r1, g1, b1 = Motion.Mix("border", "borderLit", hover)
        local r2, g2, b2 = Theme.Unpack("accent")
        local r, g, b = r1 + (r2 - r1) * focus, g1 + (g2 - g1) * focus, b1 + (b2 - b1) * focus
        for _, edge in ipairs(container.borderTextures or {}) do edge:SetColorTexture(r, g, b, 1) end
        if rawget(container, "haloTextures") then Theme.SetHalo(container, 0.3 * focus) end

        icon:SetVertexColor(Motion.Mix("muted", "accent", math.max(focus, hover * 0.4)))
    end

    local function PaintEdge()
        Motion:Blend(container, "focus", editBox:HasFocus() and 1 or 0, 0.15, Paint)
        Motion:Blend(container, "hover", container:IsMouseOver() and 1 or 0, 0.12, Paint)
    end

    editBox:SetScript("OnEditFocusGained", PaintEdge)
    editBox:SetScript("OnEditFocusLost", PaintEdge)
    container:SetScript("OnEnter", PaintEdge)
    container:SetScript("OnLeave", PaintEdge)
    editBox:SetScript("OnEnter", PaintEdge)
    editBox:SetScript("OnLeave", PaintEdge)
    container:EnableMouse(true)

    editBox:SetScript("OnTextChanged", Update)
    editBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)
    editBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    clear:SetScript("OnClick", function()
        editBox:SetText("")
        editBox:ClearFocus()
    end)

    container.editBox = editBox

    function container:GetText() return editBox:GetText() end
    function container:SetText(value) editBox:SetText(value or "") end

    return container
end

--------------------------------------------------------------------------------
-- Number box
--------------------------------------------------------------------------------

--- A small numeric field that validates on focus loss.
--
-- Values are clamped rather than rejected: silently refusing input leaves the
-- player wondering what they typed wrong.
-- @param opts { width, height, background, min, max, decimals,
--   onChange = function(value) }
function Widgets.CreateNumberBox(parent, opts)
    opts = opts or {}

    local container = Theme.CreatePanel(parent, opts.background or "row")
    container:SetSize(opts.width or 60, opts.height or 22)

    -- The bounds live on the container, not in opts, so a box reused across
    -- the rows of a list can take the limits of whatever it is showing.
    container.min, container.max = opts.min, opts.max

    local editBox = CreateFrame("EditBox", nil, container)
    editBox:SetPoint("TOPLEFT", 5, 0)
    editBox:SetPoint("BOTTOMRIGHT", -5, 0)
    editBox:SetAutoFocus(false)
    editBox:SetJustifyH(opts.justify or "RIGHT")
    editBox:SetFont(Theme.FONT, Theme.sizes.small, "")
    editBox:SetTextColor(Theme.Unpack("text"))

    local decimals = opts.decimals or 0

    local function Format(value)
        if decimals > 0 then
            return string.format("%." .. decimals .. "f", value)
        end
        return tostring(math.floor(value + 0.5))
    end

    function container:GetValue()
        return tonumber(editBox:GetText())
    end

    --- Change the bounds, clamping what is already in the box to fit them.
    function container:SetLimits(min, max)
        self.min, self.max = min, max
        if self.value then self:SetValue(self.value, true) end
    end

    -- With opts.allowEmpty the box may be left empty, which means "no
    -- number of its own": its value is nil and opts.placeholder shows,
    -- greyed (Keep in stock by profession, 2026-10-13).
    local placeholder
    if opts.allowEmpty then
        placeholder = container:CreateFontString(nil, "OVERLAY")
        placeholder:SetFont(Theme.FONT, Theme.sizes.small, "")
        placeholder:SetTextColor(Theme.Unpack("dim"))
        placeholder:SetPoint("TOPLEFT", 5, 0)
        placeholder:SetPoint("BOTTOMRIGHT", -5, 0)
        placeholder:SetJustifyH(opts.justify or "RIGHT")
        placeholder:SetText(opts.placeholder or "")
    end

    local function ShowPlaceholder()
        if not placeholder then return end
        local focused = editBox.HasFocus and editBox:HasFocus()
        placeholder:SetShown(not focused and (editBox:GetText() or "") == "")
    end

    function container:SetPlaceholder(text)
        if placeholder then placeholder:SetText(text or "") end
    end

    function container:SetValue(value, silent)
        if opts.allowEmpty and tonumber(value) == nil then
            local changed = self.value ~= nil
            self.value = nil
            editBox:SetText("")
            ShowPlaceholder()
            if changed and not silent and opts.onChange then opts.onChange(nil) end
            return
        end

        value = tonumber(value) or self.min or 0

        -- A whole-number box stores a whole number. Typing 5.5 used to show
        -- 6 but hand 5.5 to the setting behind it, and a limit of 5.5 then
        -- broke every "%d" that printed it.
        if (opts.decimals or 0) == 0 then value = math.floor(value + 0.5) end

        if self.min and value < self.min then value = self.min end
        if self.max and value > self.max then value = self.max end

        local changed = value ~= self.value
        self.value = value
        editBox:SetText(Format(value))
        ShowPlaceholder()

        -- Only a change is reported. Clicking into a box and away again is
        -- not a decision, and a per-item box that reported its unchanged
        -- default wrote that default down as an override for the item.
        if changed and not silent and opts.onChange then
            opts.onChange(value)
        end
    end

    local function Commit()
        -- ClearFocus fires OnEditFocusLost, which calls back here; without this
        -- guard the change handler runs twice per edit.
        if container.committing then return end
        container.committing = true

        -- Reverting to the last good value beats leaving unparsable text on
        -- screen that looks like it was accepted.
        if opts.allowEmpty and (editBox:GetText() or ""):match("^%s*$") then
            container:SetValue(nil)
        else
            container:SetValue(container:GetValue() or container.value or 0)
        end
        editBox:ClearFocus()
        ShowPlaceholder()

        container.committing = false
    end

    editBox:SetScript("OnEnterPressed", Commit)
    editBox:SetScript("OnEditFocusLost", Commit)
    editBox:SetScript("OnEscapePressed", function(self)
        container:SetValue(container.value, true)
        self:ClearFocus()
        ShowPlaceholder()
    end)
    if placeholder then
        editBox:SetScript("OnEditFocusGained", function() placeholder:Hide() end)
    end

    container:SetScript("OnEnter", function(self) Theme.SetBorderColor(self, "borderLit") end)
    container:SetScript("OnLeave", function(self) Theme.SetBorderColor(self, "border") end)
    container:EnableMouse(true)

    container.editBox = editBox
    return container
end

--------------------------------------------------------------------------------
-- Dropdown
--------------------------------------------------------------------------------

-- Rows a menu shows at once. A longer list (every character, in the bank
-- view's filter) scrolls with the mouse wheel instead of running off the
-- screen.
local MENU_ROWS = 12
local MENU_ROW_HEIGHT = 20

--- An option's words without a "Sort: " or "Show: " lead-in, for a box too
--- narrow for all of them: what is left still names the choice.
local function ShortOptionText(text)
    return type(text) == "string" and text:match("^[^:]+:%s+(.+)$") or text
end

--- Minimal dropdown. options is an array of { text, value }.
--
-- An option with `header = true` is a line of dim words that cannot be
-- picked, to split a long menu into groups.
--
-- With `opts.multi`, any number of options can be ticked at once (a player's
-- Sell to menu, 2026-10-07): the value is a set, { [value] = true }, a click
-- ticks or unticks one and leaves the menu open, onSelect gets the new set,
-- and the box shows `opts.summary(set)`, or the ticked options' words.
function Widgets.CreateDropdown(parent, options, onSelect, opts)
    opts = opts or {}
    local multi = opts.multi and true or false

    local dropdown = Theme.CreatePanel(parent, "row")
    dropdown:SetSize(opts.width or 140, 22)
    dropdown:EnableMouse(true)
    Theme.TopSheen(dropdown)

    local label = Theme.CreateLabel(dropdown, "small", "text")
    label:SetPoint("LEFT", 6, 0)
    label:SetPoint("RIGHT", -18, 0)
    dropdown.label = label

    -- A small solid arrow pointing down where a letter "v" stood, drawn from
    -- four rows of plain colour (7, 5, 3 and 1 pixels wide) the way the rest
    -- of the theme is drawn, so it needs no texture file.
    local arrow = {}
    for row = 0, 3 do
        local bar = dropdown:CreateTexture(nil, "ARTWORK")
        bar:SetSize(7 - row * 2, 1)
        bar:SetPoint("TOPLEFT", dropdown, "RIGHT", -13 + row, 2 - row)
        bar:SetColorTexture(Theme.Unpack("muted"))
        arrow[#arrow + 1] = bar
    end

    local menu = Theme.CreatePanel(parent, "panel", "borderLit")
    menu:SetFrameStrata("DIALOG")
    -- A box at the foot of a window opens upward (opts.up), so its menu
    -- stays over the window rather than hanging below it.
    if opts.up then
        menu:SetPoint("BOTTOMLEFT", dropdown, "TOPLEFT", 0, 2)
        menu:SetPoint("BOTTOMRIGHT", dropdown, "TOPRIGHT", 0, 2)
    else
        menu:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 0, -2)
        menu:SetPoint("TOPRIGHT", dropdown, "BOTTOMRIGHT", 0, -2)
    end
    menu:Hide()

    -- The first option a long menu is showing, and a slim bar down its right
    -- edge saying how far through the list that is.
    menu.first = 1
    local thumb = menu:CreateTexture(nil, "OVERLAY")
    thumb:SetWidth(3)
    thumb:SetColorTexture(Theme.Unpack("borderLit"))
    thumb:Hide()

    dropdown.options = options or {}
    dropdown.selected = multi and {} or nil

    --- Is this option the one picked, or one of those ticked?
    local function IsOn(option)
        if option.header then return false end
        if multi then return dropdown.selected[option.value] == true end
        return option.value == dropdown.selected
    end

    local entries = {}

    local function Rebuild()
        for _, entry in ipairs(entries) do
            entry:Hide()
        end

        local count = #dropdown.options
        local shown = math.min(count, MENU_ROWS)
        local scrolls = count > shown
        menu.first = math.max(1, math.min(menu.first or 1, count - shown + 1))

        -- The room an entry's words have: the menu's width less the entry's
        -- insets, and less the bar when there is one.
        local width = dropdown:GetWidth()
        local room = type(width) == "number" and (width - 18 - (scrolls and 6 or 0)) or nil

        for index, option in ipairs(dropdown.options) do
            local entry = entries[index]

            if not entry then
                entry = CreateFrame("Button", nil, menu)
                entry:SetHeight(MENU_ROW_HEIGHT)
                -- Drawn in full and faded with SetAlpha: made with a colour
                -- alpha of 0, as it was, no hover ever showed.
                entry.highlight = Theme.Fill(entry, "rowHover", nil, "ARTWORK")
                entry.highlight:SetAlpha(0)
                entry.label = Theme.CreateLabel(entry, "small", "text")
                entry.label:SetPoint("LEFT", 8, 0)
                entry.label:SetPoint("RIGHT", -8, 0)

                -- The option picked now wears the gold edge.
                entry.mark = Theme.AccentStripe(entry, 2)
                entry.mark:Hide()

                local function Light(value) entry.highlight:SetAlpha(value) end
                entry:SetScript("OnEnter", function(self) Motion:Blend(self, "hover", 1, 0.08, Light) end)
                entry:SetScript("OnLeave", function(self) Motion:Blend(self, "hover", 0, 0.15, Light) end)

                entries[index] = entry
            end

            -- Only the window of options the menu is showing is placed; an
            -- entry made just now for one outside it starts hidden too.
            local slot = index - menu.first
            if slot >= 0 and slot < shown then
                local y = -4 - slot * MENU_ROW_HEIGHT
                entry:SetPoint("TOPLEFT", 1, y)
                entry:SetPoint("TOPRIGHT", scrolls and -7 or -1, y)
                Theme.FitText(entry.label, { option.text, ShortOptionText(option.text) }, room)
                -- A ticked option in a multiple choice menu is lit and an
                -- unticked one dimmed, so it reads as on and off.
                local color = IsOn(option) and "accent" or (option.header or multi) and "dim" or "text"
                entry.label:SetTextColor(Theme.Unpack(color))
                entry.mark:SetShown(IsOn(option))
                entry:EnableMouse(not option.header)
                entry:Show()
            else
                entry:Hide()
            end

            entry:SetScript("OnClick", function()
                if option.header then return end

                if multi then
                    local set = {}
                    for value, on in pairs(dropdown.selected) do set[value] = on end
                    set[option.value] = not set[option.value] or nil
                    dropdown:SetValue(set)
                    Rebuild()
                    if onSelect then onSelect(dropdown:GetValue(), option) end
                    return
                end

                dropdown:SetValue(option.value)
                menu:Hide()
                if onSelect then onSelect(option.value, option) end
            end)
        end

        menu:SetHeight(math.max(8, shown * MENU_ROW_HEIGHT + 8))

        thumb:SetShown(scrolls)
        if scrolls then
            local track = shown * MENU_ROW_HEIGHT
            local size = math.max(12, math.floor(track * shown / count))
            local offset = math.floor((track - size) * (menu.first - 1) / (count - shown) + 0.5)
            thumb:SetHeight(size)
            thumb:ClearAllPoints()
            thumb:SetPoint("TOPRIGHT", -2, -4 - offset)
        end
    end

    function dropdown:SetOptions(newOptions)
        self.options = newOptions or {}

        if multi then
            self:SetValue(self.selected)
            Rebuild()
            return
        end

        -- Keep the current selection if it still exists, else fall back to
        -- the first option that can be picked.
        local stillValid, first = false, nil
        for _, option in ipairs(self.options) do
            if not option.header then
                if first == nil then first = option end
                if option.value == self.selected then stillValid = true break end
            end
        end

        local value = self.selected
        if not stillValid then value = first and first.value end

        -- The box is drawn every time, not only on a fall back. A first
        -- option with no value ("All professions") matched the nil a new
        -- box starts with, so its name was never drawn and the box stayed
        -- blank until something was picked.
        self:SetValue(value)
        Rebuild()
    end

    function dropdown:SetValue(value)
        if multi then
            local set = {}
            for key, on in pairs(type(value) == "table" and value or {}) do
                if on then set[key] = true end
            end
            self.selected = set

            -- The box says what is ticked, in the tab's words when it has some.
            local text = opts.summary and opts.summary(set)
            if not text then
                local names = {}
                for _, option in ipairs(self.options) do
                    if not option.header and set[option.value] then names[#names + 1] = option.text end
                end
                text = #names > 0 and table.concat(names, ", ") or (opts.placeholder or "")
            end
            local width = self:GetWidth()
            Theme.FitText(label, { text, ShortOptionText(text) },
                type(width) == "number" and (width - 24) or nil)
            return
        end

        self.selected = value

        for _, option in ipairs(self.options) do
            if not option.header and option.value == value then
                -- The whole wording when it fits, else without its "Sort: "
                -- lead-in, rather than cut off with "...".
                local width = self:GetWidth()
                Theme.FitText(label, { option.text, ShortOptionText(option.text) },
                    type(width) == "number" and (width - 24) or nil)
                return
            end
        end

        label:SetText(opts.placeholder or "")
    end

    function dropdown:GetValue()
        if multi then
            local set = {}
            for key in pairs(self.selected) do set[key] = true end
            return set
        end
        return self.selected
    end

    --- Down from the box, or up from it when the screen has no room below
    --- and has room above.
    local function Place()
        local up = false
        pcall(function()
            local scale = dropdown:GetEffectiveScale()
            local need = (menu:GetHeight() + 2) * scale
            local below = dropdown:GetBottom() * scale
            local above = UIParent:GetTop() * UIParent:GetEffectiveScale() - dropdown:GetTop() * scale
            up = below < need and above >= need
        end)

        menu:ClearAllPoints()
        if up then
            menu:SetPoint("BOTTOMLEFT", dropdown, "TOPLEFT", 0, 2)
            menu:SetPoint("BOTTOMRIGHT", dropdown, "TOPRIGHT", 0, 2)
        else
            menu:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 0, -2)
            menu:SetPoint("TOPRIGHT", dropdown, "BOTTOMRIGHT", 0, -2)
        end
    end

    --- Moves the menu onto UIParent, scaled to match the box. A menu left
    --- inside a scrolling list was clipped by it and ran off the window's
    --- foot with its last options out of sight.
    local function Lift()
        pcall(function()
            if not UIParent then return end
            if menu:GetParent() ~= UIParent then menu:SetParent(UIParent) end
            local scale = dropdown:GetEffectiveScale() / UIParent:GetEffectiveScale()
            if type(scale) == "number" and scale > 0 then menu:SetScale(scale) end
            menu:SetFrameStrata("DIALOG")
        end)
    end

    dropdown:SetScript("OnMouseDown", function()
        if menu:IsShown() then
            menu:Hide()
        else
            -- A long menu opens with the choice made in view, near its middle.
            for index, option in ipairs(dropdown.options) do
                if not multi and not option.header and option.value == dropdown.selected then
                    menu.first = index - math.floor(MENU_ROWS / 2)
                    break
                end
            end

            -- The menu opens on UIParent at the box's own size, so a list
            -- that scrolls (Settings' pages) can't cut it off at its edge.
            Lift()
            Rebuild()
            Place()
            menu:Show()
            menu:Raise()
            Motion:Run(menu, "open", 0.12, function(p) menu:SetAlpha(p) end)
        end
    end)

    -- The wheel moves a long menu a row at a time.
    menu:EnableMouseWheel(true)
    menu:SetScript("OnMouseWheel", function(_, delta)
        local count = #dropdown.options
        if count <= MENU_ROWS then return end

        local step = (tonumber(delta) or 0) > 0 and -1 or 1
        local first = math.max(1, math.min(count - MENU_ROWS + 1, menu.first + step))
        if first ~= menu.first then
            menu.first = first
            Rebuild()
        end
    end)

    -- A click anywhere else closes the menu, as the game's own menus do. The
    -- event is asked for only while the menu is open, and inside a pcall: a
    -- client that does not know it raises, and then the menu simply stays
    -- open until picked from or clicked shut, as before.
    menu:SetScript("OnShow", function(self)
        pcall(self.RegisterEvent, self, "GLOBAL_MOUSE_DOWN")
        local ok, top = pcall(dropdown.GetTop, dropdown)
        self.openTop = ok and type(top) == "number" and top or nil
    end)

    -- On UIParent the menu no longer moves out of sight with a list that
    -- scrolls, so it closes once its box has scrolled away.
    menu:SetScript("OnUpdate", function(self)
        if not self.openTop then return end
        local ok, top = pcall(dropdown.GetTop, dropdown)
        if ok and type(top) == "number" and math.abs(top - self.openTop) > 0.5 then
            self:Hide()
        end
    end)
    menu:SetScript("OnHide", function(self)
        pcall(self.UnregisterEvent, self, "GLOBAL_MOUSE_DOWN")
    end)
    menu:SetScript("OnEvent", function(self)
        if self:IsMouseOver() or dropdown:IsMouseOver() then return end
        self:Hide()
    end)

    -- Its tab closing takes the menu with it, or it would be found still
    -- open the next time the tab is shown.
    dropdown:SetScript("OnHide", function() menu:Hide() end)

    --- How lit the box is under the mouse: its edge and its arrow.
    local function Light(p)
        local r, g, b = Motion.Mix("border", "borderLit", p)
        for _, edge in ipairs(dropdown.borderTextures or {}) do edge:SetColorTexture(r, g, b, 1) end
        local ar, ag, ab = Motion.Mix("muted", "accent", p)
        for _, bar in ipairs(arrow) do bar:SetColorTexture(ar, ag, ab, 1) end
    end

    dropdown:SetScript("OnEnter", function(self) Motion:Blend(self, "hover", 1, 0.12, Light) end)
    dropdown:SetScript("OnLeave", function(self) Motion:Blend(self, "hover", 0, 0.18, Light) end)

    dropdown.menu = menu
    dropdown:SetOptions(options)

    return dropdown
end

--------------------------------------------------------------------------------
-- Progress bar
--------------------------------------------------------------------------------

function Widgets.CreateProgressBar(parent)
    local bar = Theme.CreatePanel(parent, "panel")
    bar:SetHeight(4)

    local fill = bar:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMLEFT", 1, 1)
    fill:SetColorTexture(Theme.Unpack("accent"))
    fill:SetWidth(1)

    -- A brighter sliver at the leading edge, so the bar reads as moving.
    local tip = bar:CreateTexture(nil, "OVERLAY")
    tip:SetPoint("TOPRIGHT", fill, "TOPRIGHT")
    tip:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT")
    tip:SetWidth(2)
    tip:SetColorTexture(1, 0.92, 0.65, 0.9)

    -- And a soft gold spark round it, spilling past the bar's edges.
    local spark = bar:CreateTexture(nil, "OVERLAY", nil, 1)
    spark:SetPoint("RIGHT", fill, "RIGHT", 4, 0)
    spark:SetSize(14, 10)
    Theme.SetGradientAlpha(spark, "HORIZONTAL", "accent", 0, 0.55)
    pcall(spark.SetBlendMode, spark, "ADD")
    spark:Hide()

    bar.fill, bar.spark = fill, spark

    local shown = 0

    local function Draw(fraction)
        shown = fraction
        fill:SetWidth(math.max(1, (bar:GetWidth() - 2) * fraction))
        local moving = fraction > 0 and fraction < 1
        tip:SetShown(moving)
        spark:SetShown(moving)
    end

    --- Glide to `fraction` (0 to 1) rather than jump, so a scan's progress
    --- flows. Going back down (a new scan starting) jumps, as does `instant`.
    function bar:SetProgress(fraction, instant)
        fraction = math.max(0, math.min(1, tonumber(fraction) or 0))

        if instant or fraction <= shown or not self:IsVisible() then
            Motion:Stop(self, "fill")
            Draw(fraction)
            return
        end

        local from = shown
        Motion:Run(self, "fill", 0.25, function(p) Draw(from + (fraction - from) * p) end)
    end

    bar:SetProgress(0)
    return bar
end

--------------------------------------------------------------------------------
-- Tab strip
--------------------------------------------------------------------------------

-- Room either side of a tab's name, and the narrowest a tab gets, when the
-- tabs are sized to their names.
local TAB_PAD = 20
local TAB_MIN = 56

--- Widths for tabs sized to their names: each name measured with room either
--- side, and what is left of `room` shared out, a little each, so a strip of
--- a few tabs does not stretch them wide. Nil when a name cannot be measured,
--- or when they do not all fit `room`.
local function NameWidths(buttons, room)
    local widths, total = {}, 0
    for index, button in ipairs(buttons) do
        local width = Theme.TextWidth(button.label)
        if not width then return nil end
        widths[index] = math.max(TAB_MIN, math.ceil(width) + TAB_PAD)
        total = total + widths[index]
    end

    if room and total > room then return nil end

    local extra = room and math.min(24, math.floor((room - total) / #buttons)) or 0
    for index in ipairs(widths) do widths[index] = widths[index] + extra end
    return widths
end

-- Hanging tabs (opts.hanging): how tall a tab is, and how far the one
-- showing reaches up over the window's rim to join it.
local HANG_HEIGHT = 26
local HANG_JOIN = 5

--- The metal edge round a hanging tab: down both sides and along the foot.
local function HangingEdges(button)
    local Gradient = ns.Titanforged and ns.Titanforged.Gradient
    local metalLo, metal = { 0.357, 0.267, 0.086 }, { 0.690, 0.545, 0.235 }
    local hi = { 0.941, 0.831, 0.541 }

    local function Edge(a, b, width, height)
        local edge = button:CreateTexture(nil, "BORDER", nil, 2)
        edge:SetPoint(a)
        edge:SetPoint(b)
        if width then edge:SetWidth(width) else edge:SetHeight(height) end
        return edge
    end

    local left = Edge("TOPLEFT", "BOTTOMLEFT", 2)
    local right = Edge("TOPRIGHT", "BOTTOMRIGHT", 2)
    local foot = Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 2)
    button.edges = { left, right, foot }

    if Gradient then
        Gradient(left, "VERTICAL", hi, metalLo)
        Gradient(right, "VERTICAL", metal, metalLo)
        Gradient(foot, "HORIZONTAL", metal, hi)
    else
        for _, edge in ipairs({ left, right, foot }) do edge:SetColorTexture(Theme.Unpack("metal")) end
    end
end

--- A row of tabs. Each tab is { key, text, width }; a tab given no width is
--- as wide as its name needs, and opts.width is the room all of them have.
--- opts.hanging hangs them below the strip's top edge, as the game's own
--- windows wear their tabs: anchor the strip's top to the window's bottom.
function Widgets.CreateTabStrip(parent, tabs, onSelect, opts)
    opts = opts or {}
    local hanging = opts.hanging and true or false

    local strip = CreateFrame("Frame", nil, parent)
    strip:SetHeight(28)

    strip.tabs = {}
    strip.selected = nil

    -- In the Blizzard window style a resting tab's name is the game's gold,
    -- and hanging tabs wear the character window's tab art.
    local Look = ns.BlizzardLook
    local blizzard = Look and Look.On()
    local restKey = blizzard and "gilt" or "muted"

    --- How lit a tab is under the mouse, 0 to 1: its wash, its underline
    --- and its label.
    local function Hover(button, p)
        button.hover:SetAlpha(p)
        button.underline:SetAlpha(p)
        if strip.selected ~= button.key then
            button.label:SetTextColor(Motion.Mix(restKey, "text", p))
        end
    end

    for index, tab in ipairs(tabs) do
        local button = CreateFrame("Button", nil, strip)
        button:SetHeight(hanging and HANG_HEIGHT or 28)

        button.background = Theme.Fill(button, "panel")
        button.hover = Theme.Fill(button, "rowHover", 0.45, "BORDER")
        button.hover:SetAlpha(0)

        if hanging then
            HangingEdges(button)
            -- Each tab glows faintly gold when it is the one showing.
            if Theme.Halo then Theme.Halo(button, 6, 0) end
        end

        -- The tab showing sits in a soft gold light rising from its line.
        button.lit = button:CreateTexture(nil, "BORDER", nil, 1)
        button.lit:SetAllPoints(button)
        Theme.SetGradientAlpha(button.lit, "VERTICAL", "accent", hanging and 0.28 or 0.14, 0)
        button.lit:Hide()

        -- Under the mouse, a faint line along the tab's foot echoes the gold
        -- one under the tab showing. It is inset from the tab's edges and
        -- drawn on the tab, below the layer the gold line rides on, so the
        -- gold line passes over it as it slides, and the tab showing never
        -- lights its own.
        button.underline = button:CreateTexture(nil, "ARTWORK")
        button.underline:SetPoint("BOTTOMLEFT", 10, 0)
        button.underline:SetPoint("BOTTOMRIGHT", -10, 0)
        button.underline:SetHeight(1)
        button.underline:SetColorTexture(Theme.Unpack("muted"))
        button.underline:SetAlpha(0)

        -- A step smaller on a narrow tab given its width, so its name stays
        -- inside it. Tabs sized to their names are sized below.
        local labelSize = tab.width and tab.width < 90 and "small" or "normal"
        button.label = Theme.CreateLabel(button, labelSize, restKey, "CENTER")
        button.label:SetPoint("CENTER", 0, 0)
        button.label:SetText(tab.text)

        if blizzard and hanging then Look.Tab(button) end

        button.key = tab.key
        button.fixedWidth = tab.width

        button:SetScript("OnClick", function(self)
            strip:Select(self.key)
            if onSelect then onSelect(self.key) end
        end)

        button:SetScript("OnEnter", function(self)
            if strip.selected == self.key then return end
            Motion:Blend(self, "hover", 1, 0.12, function(p) Hover(self, p) end)
        end)

        button:SetScript("OnLeave", function(self)
            Motion:Blend(self, "hover", 0, 0.18, function(p) Hover(self, p) end)
        end)

        strip.tabs[index] = button
    end

    -- Tabs given no width are as wide as their names, at the full size when
    -- all of them fit opts.width and a step smaller when not. Twelve equal
    -- tabs left "Disenchanting" and "Vendor Flips" running into their
    -- neighbours. When a name cannot be measured they share the room
    -- equally, as all tabs used to.
    local sized, room = {}, opts.width
    for _, button in ipairs(strip.tabs) do
        if button.fixedWidth then
            if room then room = room - button.fixedWidth end
        else
            sized[#sized + 1] = button
        end
    end

    local widths = {}
    if #sized > 0 then
        local named = NameWidths(sized, room)
        if not named then
            for _, button in ipairs(sized) do
                button.label:SetFont(Theme.FONT, Theme.sizes.small, "")
            end
            named = NameWidths(sized, room)
        end

        for index, button in ipairs(sized) do
            widths[button] = named and named[index]
                or (room and math.min(96, math.floor(room / #sized)) or 96)
        end
    end

    -- Hanging tabs stand a little apart, so each reads as its own tab.
    local gap = hanging and 3 or 0
    local x = 0
    for _, button in ipairs(strip.tabs) do
        local width = button.fixedWidth or widths[button]
        if hanging then
            button:SetPoint("TOPLEFT", x, 0)
            width = math.max(1, width - gap)
        else
            button:SetPoint("BOTTOMLEFT", x, 0)
        end
        button:SetWidth(width)
        button.left, button.span = x, width
        x = x + width + gap
    end

    strip:SetWidth(math.max(x, 1))

    -- One gold line for the whole strip, gliding to the tab picked, with a
    -- soft glow over it: Farmer's tabs do the same. Both ride on a layer of
    -- their own above the tabs. Drawn on the strip itself they sat under
    -- every tab's fill (a frame's children draw over it) and never showed.
    local layer = CreateFrame("Frame", nil, strip)
    layer:SetAllPoints(strip)
    local ok, level = pcall(strip.GetFrameLevel, strip)
    if ok and type(level) == "number" then layer:SetFrameLevel(level + 3) end
    strip.lineLayer = layer

    local line = layer:CreateTexture(nil, "OVERLAY")
    line:SetHeight(2)
    line:SetColorTexture(Theme.Unpack("accent"))
    line:Hide()
    strip.line = line

    local glow = layer:CreateTexture(nil, "ARTWORK")
    glow:SetHeight(7)
    glow:SetPoint("BOTTOMLEFT", line, "BOTTOMLEFT", -2, 0)
    glow:SetPoint("BOTTOMRIGHT", line, "BOTTOMRIGHT", 2, 0)
    Theme.SetGradientAlpha(glow, "VERTICAL", "accent", 0.32, 0)
    pcall(glow.SetBlendMode, glow, "ADD")
    glow:Hide()
    strip.lineGlow = glow
    if blizzard and hanging then Look.TabStrip(strip) end

    --- Put the line under `button`, sliding there from wherever it is now,
    --- so a tab picked mid-slide turns the line round rather than making it
    --- jump back first.
    local function MarkTab(button)
        local fromX, fromWidth = strip.lineX or button.left, strip.lineWidth or button.span
        local still = fromX == button.left and fromWidth == button.span

        line:Show()
        glow:Show()

        -- Hung from the tab it is heading for, so it lands exactly under it;
        -- only the distance still to go is worked out.
        Motion:Run(line, "slide", still and 0 or 0.22, function(p)
            local x = fromX + (button.left - fromX) * p
            local width = fromWidth + (button.span - fromWidth) * p
            strip.lineX, strip.lineWidth = x, width

            line:ClearAllPoints()
            line:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", x - button.left, 0)
            line:SetWidth(math.max(1, width))
        end)
    end

    function strip:Select(key)
        self.selected = key

        for _, button in ipairs(self.tabs) do
            local active = button.key == key
            Motion:Stop(button, "hover")
            Motion:SetValue(button, "hover", 0)
            button.hover:SetAlpha(0)
            button.underline:SetAlpha(0)
            button.lit:SetShown(active)
            button.label:SetTextColor(Theme.Unpack(active and (hanging and "accentHi" or "accent") or restKey))
            button.background:SetColorTexture(Theme.Unpack(active and "header" or (hanging and "window" or "panel")))
            if hanging then
                -- The tab showing is taller, reaching up over the window's
                -- rim so it joins the window, and glows.
                button:ClearAllPoints()
                button:SetPoint("TOPLEFT", strip, "TOPLEFT", button.left, active and HANG_JOIN or 0)
                button:SetHeight(HANG_HEIGHT + (active and HANG_JOIN or 0))
                if rawget(button, "haloTextures") then Theme.SetHalo(button, active and 0.22 or 0) end
            end
            if active then MarkTab(button) end
            if blizzard then Look.SelectTab(button, active) end
        end
    end

    return strip
end

--------------------------------------------------------------------------------
-- Virtualized scroll list
--------------------------------------------------------------------------------

--- A list that recycles row frames.
--
-- @param opts
--   rowHeight  pixel height of one row
--   createRow  function(row) -- build the row's children once
--   updateRow  function(row, data, index) -- fill a row with data
--   onClick    function(data, index, mouseButton)
--   onEnter / onLeave  function(row, data)
--   isSelected function(data) -- true for the row the detail pane is showing,
--              which is then drawn lit with a gold edge
--- Light a scrollbar's thumb gold while the mouse is over the bar.
function Widgets.LightThumb(bar, thumb)
    -- The Blizzard window style draws the thumb as the game's knob, lit by
    -- tint (UI/BlizzardLook.lua).
    local Look = ns.BlizzardLook
    if Look then Look.Thumb(thumb) end

    bar:EnableMouse(true)
    bar:HookScript("OnEnter", function()
        if not (Look and Look.LightThumb(thumb, true)) then thumb:SetColorTexture(Theme.Unpack("accent")) end
    end)
    bar:HookScript("OnLeave", function()
        if not (Look and Look.LightThumb(thumb, false)) then thumb:SetColorTexture(Theme.Unpack("metal")) end
    end)
end

--------------------------------------------------------------------------------
-- Scroll frame
--------------------------------------------------------------------------------
-- Sortable column headings
--------------------------------------------------------------------------------

-- Blizzard's own list sort arrow, pointing down; flipped for smallest first.
local SORT_ARROW = [[Interface\Buttons\UI-SortArrow]]

-- Room a heading keeps beside its words for the sort arrow: 8 wide, 2 off
-- the words.
Widgets.SORT_ARROW_ROOM = 10

-- A heading's words are given this much more than they measure. Laid out
-- to the exact pixel, the game can find them a hair too wide and draw
-- nothing at all (the Prices tab's TREND heading went blank while it
-- sorted, 2026-10-14).
Widgets.HEADING_SLACK = 2

-- The widest amount a money column is made to hold whole, every coin shown.
-- One digit of gold: at level 30 most amounts are under 10g, and every
-- pixel more goes from the item names. A larger amount is measured down to
-- "12g 35s" (Theme.SetMoneyText).
Widgets.MONEY_SAMPLE = "9g 99s 99c"

--- Widen a list's columns so every heading shows whole beside its sort arrow
--- and every money column holds a full amount, never ending in "..."
--- (a player's request, 2026-10-07). Measured, since the game's font runs
--- wider than any width picked by eye.
--
-- Each column is a table with `width` (the least it is given; kept as
-- `baseWidth`, so calling this again starts over), and optionally `label`
-- (its heading), `money = true` and `sample` (a wider amount to hold, for a
-- list with room to spare). A money column's width is measured
-- whole, from its heading and MONEY_SAMPLE, once they can be measured: its
-- own width was picked by eye, and the room it saves goes to the names. Call it before the rows and headings are
-- laid out, which then read `width` as before. A centred heading needs no
-- more room than another: SortableHeadings narrows it while it sorts.
-- @param texts  optional function(column) returning the heading's text, or
--   a list of every text it can show, for a tab whose labels live elsewhere
function Widgets.FitColumns(columns, texts)
    local measure = Theme.MeasureText
    if type(measure) ~= "function" then return end

    for _, column in ipairs(columns) do
        column.baseWidth = column.baseWidth or column.width
        local need = column.baseWidth or 0

        local headings = texts and texts(column) or column.label
        if type(headings) ~= "table" then headings = { headings } end
        local room = Widgets.SORT_ARROW_ROOM + Widgets.HEADING_SLACK
        for _, text in ipairs(headings) do
            local width = measure("tiny", text)
            if type(width) == "number" then need = math.max(need, width + room) end
        end

        if column.money then
            local width = measure("small", column.sample or Widgets.MONEY_SAMPLE)
            if type(width) == "number" then
                need = width + 2
                for _, text in ipairs(headings) do
                    local heading = measure("tiny", text)
                    if type(heading) == "number" then need = math.max(need, heading + room) end
                end
            end
        end

        column.width = need
    end
end

--- Make a list's column headings sort it when clicked (a player's request,
--- 2026-10-02).
--
-- The first click on a heading sorts by that column, biggest first (names A
-- to Z); a second click turns it round; a third gives the list back its own
-- order. The heading lit in the accent colour, with an arrow beside it, is the
-- one sorting the list. Nothing is saved: the tab opens in its own order.
--
-- @param labels  { [key] = fontString } the headings, as the tab made them
-- @param values  { [key] = function(row) return number or string end }; a
--   heading with no entry here is not made clickable
-- @param onChange  called after a click, to redraw the list
-- @return sorter with :Sort(rows) (a sorted copy) and :Sync() (match
--   each click area to its heading's visibility after a layout change)
function Widgets.SortableHeadings(labels, values, onChange)
    local sorter = { key = nil, ascending = false, buttons = {} }

    -- A centred heading's words sit in the middle of their column, so the
    -- arrow beside them would need room on both sides. Instead, while it
    -- sorts the list, the heading gives up the arrow's room on its left
    -- (it is laid out by its right edge), which moves its words over by
    -- half of it and leaves the arrow that room before them.
    local function Narrow(button, active)
        local label = button.label
        if not (label.GetJustifyH and label:GetJustifyH() == "CENTER") then return end

        local ok, current = pcall(label.GetWidth, label)
        if not ok or type(current) ~= "number" or current <= 0 then return end

        -- The tab may have laid the heading out again since it was narrowed.
        if button.narrowed ~= current then button.fullWidth = current end

        if active then
            -- Never narrower than its words, or they vanish.
            local words = Theme.TextWidth and Theme.TextWidth(label) or nil
            local least = type(words) == "number" and math.ceil(words) + Widgets.HEADING_SLACK or 1
            button.narrowed = math.min(button.fullWidth,
                math.max(least, button.fullWidth - Widgets.SORT_ARROW_ROOM))
            label:SetWidth(button.narrowed)
        else
            label:SetWidth(button.fullWidth)
            button.narrowed = nil
        end
    end

    local function Paint()
        for key, button in pairs(sorter.buttons) do
            local active = sorter.key == key
            if active or not button.restColor then
                button.label:SetTextColor(Theme.Unpack(active and "accent" or "muted"))
            else
                button.label:SetTextColor(unpack(button.restColor))
            end

            local arrow = button.arrow
            arrow:SetShown(active)
            if active then
                if sorter.ascending then
                    arrow:SetTexCoord(0, 0.5625, 1, 0)
                else
                    arrow:SetTexCoord(0, 0.5625, 0, 1)
                end

                -- Beside the words, in the room the heading keeps for it
                -- (Widgets.FitColumns), so it never lies over the next one.
                local width = Theme.TextWidth and Theme.TextWidth(button.label) or nil
                if type(width) ~= "number" then width = 0 end
                arrow:ClearAllPoints()
                local justify = button.label.GetJustifyH and button.label:GetJustifyH() or "LEFT"
                if justify == "RIGHT" or justify == "CENTER" then
                    arrow:SetPoint("RIGHT", button.label, justify, -math.ceil(justify == "CENTER"
                        and width / 2 or width) - 2, 0)
                else
                    arrow:SetPoint("LEFT", button.label, "LEFT", math.ceil(width) + 2, 0)
                end
            end
            Narrow(button, active)
        end
    end

    for key, label in pairs(labels) do
        if values[key] then
            local button = CreateFrame("Button", nil, label:GetParent())
            button:SetPoint("TOPLEFT", label, "TOPLEFT", 0, 2)
            button:SetPoint("BOTTOMRIGHT", label, "BOTTOMRIGHT", 0, -2)
            button.label = label

            local arrow = button:CreateTexture(nil, "OVERLAY")
            arrow:SetSize(8, 7)
            pcall(arrow.SetTexture, arrow, SORT_ARROW)
            arrow:Hide()
            button.arrow = arrow

            button:SetScript("OnClick", function()
                if sorter.key ~= key then
                    sorter.key = key
                    -- Names read A to Z; numbers biggest first.
                    sorter.ascending = sorter.isText and sorter.isText[key] or false
                elseif sorter.ascending == ((sorter.isText and sorter.isText[key]) or false) then
                    sorter.ascending = not sorter.ascending
                else
                    sorter.key = nil
                end

                Paint()
                if onChange then onChange(sorter.key, sorter.ascending) end
            end)
            button:SetScript("OnEnter", function()
                if sorter.key ~= key then
                    label:SetTextColor(Theme.Unpack("text"))
                end
            end)
            button:SetScript("OnLeave", Paint)

            -- Its own colour when it is not the one sorting: some lists draw
            -- their headings dimmer than others.
            local ok, r, g, b = pcall(label.GetTextColor, label)
            button.restColor = ok and type(r) == "number" and { r, g, b } or nil

            sorter.buttons[key] = button
        end
    end

    --- Which headings hold names, so they start A to Z.
    function sorter:SetText(keys)
        self.isText = {}
        for _, key in ipairs(keys) do self.isText[key] = true end
    end

    --- Back to the list's own order, as when a tab changes what its
    --- columns hold.
    function sorter:Reset()
        self.key = nil
        Paint()
    end

    function sorter:Sync()
        for _, button in pairs(self.buttons) do
            button:SetShown(button.label:IsShown())
        end
        if self.key and self.buttons[self.key] and not self.buttons[self.key]:IsShown() then
            self.key = nil
        end
        Paint()
    end

    --- The rows in the clicked heading's order, as a new list; the rows as
    --- given when no heading is clicked. Rows with no value go last either
    --- way round, and rows that tie keep the order they came in.
    function sorter:Sort(given)
        local get = self.key and values[self.key]
        if not get or type(given) ~= "table" then return given end

        local rows, position = {}, {}
        for index, row in ipairs(given) do
            rows[index] = row
            position[row] = index
        end

        local ascending = self.ascending
        table.sort(rows, function(a, b)
            local left, right = get(a), get(b)
            if type(left) == "string" then left = left:lower() end
            if type(right) == "string" then right = right:lower() end

            if left == nil or right == nil or type(left) ~= type(right) then
                if (left == nil) ~= (right == nil) then return right == nil end
                return position[a] < position[b]
            end

            if left ~= right then
                if ascending then return left < right end
                return left > right
            end
            return position[a] < position[b]
        end)

        return rows
    end

    Paint()
    return sorter
end

--------------------------------------------------------------------------------

--- A plain scrolling container for a laid-out panel.
--
-- Distinct from CreateScrollList, which recycles rows for a long uniform list.
-- This one scrolls a fixed set of real frames, which is what a settings page
-- needs: every control exists at once and keeps its own anchors.
--
-- Build into `scroll.content` rather than into the frame itself.
function Widgets.CreateScrollFrame(parent, opts)
    opts = opts or {}

    local scroll = CreateFrame("ScrollFrame", nil, parent)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)
    scroll.content = content

    -- Parented to `parent`, not to the scroll child: anything inside the child
    -- scrolls with it, and a scrollbar that slides itself off the screen is a
    -- memorable bug to chase.
    local bar = CreateFrame("Slider", nil, parent)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(8)
    bar:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 8, 0)
    bar:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 8, 0)
    bar:SetValueStep(1)
    bar:SetObeyStepOnDrag(true)
    bar:SetValue(0)
    bar:Hide()

    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints(bar)
    track:SetColorTexture(Theme.Unpack("panel"))

    local thumb = bar:CreateTexture(nil, "ARTWORK")
    thumb:SetColorTexture(Theme.Unpack("metal"))
    thumb:SetSize(8, 40)
    bar:SetThumbTexture(thumb)
    Widgets.LightThumb(bar, thumb)

    scroll.scrollbar = bar

    bar:SetScript("OnValueChanged", function(_, value)
        scroll:SetVerticalScroll(value)
    end)

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        bar:SetValue(bar:GetValue() - delta * (opts.step or 40))
    end)

    --- Recompute how far there is to scroll, and show the bar only if there is.
    function scroll:UpdateRange()
        local view = self:GetHeight() or 0
        local height = content:GetHeight() or 0
        local range = math.max(0, height - view)

        bar:SetMinMaxValues(0, range)

        -- Shrinking content can leave the view scrolled past the end.
        if bar:GetValue() > range then bar:SetValue(range) end

        bar:SetShown(range > 0)

        if range > 0 and view > 0 then
            -- Thumb length tracks the visible fraction, so the bar says how
            -- much more there is rather than just that there is more.
            thumb:SetHeight(math.max(20, view * (view / height)))
        end
    end

    --- Size the content to whatever was built into it.
    --
    -- Measured from the children rather than tracked by hand: this panel is a
    -- chain of anchors, so nothing here knows the total height, and a guessed
    -- one is either a dead region at the bottom or content you cannot reach.
    function scroll:FitContent(padding)
        local top = content:GetTop()
        if not top then return false end

        local lowest = top

        for _, child in ipairs({ content:GetChildren() }) do
            local bottom = child:IsShown() and child:GetBottom()
            if bottom and bottom < lowest then lowest = bottom end
        end

        for _, region in ipairs({ content:GetRegions() }) do
            local bottom = region.GetBottom and region:GetBottom()
            if bottom and bottom < lowest then lowest = bottom end
        end

        content:SetHeight(math.max(1, top - lowest + (padding or 16)))
        self:UpdateRange()
        return true
    end

    scroll:SetScript("OnSizeChanged", function(self, width)
        content:SetWidth(width)
        self:UpdateRange()
    end)

    return scroll
end

--- What a row's tooltip describes, kept steady across redraws: the lists
--- build their entries afresh each time, so the entry itself would count
--- as new on every redraw.
local function TipIdentity(entry)
    if type(entry) ~= "table" then return entry end
    return entry.itemID or entry.recipeID or entry.key or entry
end

--- Whether the game's tooltip is showing for `frame` now.
local function OwnsTooltip(frame)
    if type(GameTooltip) ~= "table" or type(GameTooltip.IsOwned) ~= "function" then return false end
    local ok, owned = pcall(GameTooltip.IsOwned, GameTooltip, frame)
    return ok and owned == true
end

--- The item a list row stands for: its own item, else what its recipe makes.
--- A list can name it itself with opts.searchItem(data), or return false to
--- keep shift-clicks to itself.
function Widgets.RowItemID(data, searchItem)
    if type(data) ~= "table" then return nil end
    if searchItem then return searchItem(data) or nil end

    local itemID = tonumber(data.itemID) or tonumber(data.outputItemID)
    if itemID then return itemID end

    local recipeID = tonumber(data.recipeID)
    local recipes = ns.Recipes
    if recipeID and recipes and recipes.GetAny then
        local ok, recipe = pcall(recipes.GetAny, recipes, recipeID)
        if ok and type(recipe) == "table" then return tonumber(recipe.outputItemID) end
    end
end

--- Put an item's link in the chat box being typed in, as a shift-click on
--- the bags does. Nothing when no chat box is open.
-- @return true when the link went in
function Widgets.LinkToChat(itemID, link)
    if type(link) ~= "string" and itemID and ns.Util and ns.Util.HasFunction("C_Item.GetItemInfo") then
        local ok, _, itemLink = pcall(C_Item.GetItemInfo, itemID)
        if ok then link = itemLink end
    end
    if type(link) ~= "string" then return false end

    local util = _G.ChatFrameUtil
    local insert = (type(util) == "table" and type(util.InsertLink) == "function" and util.InsertLink)
        or _G.ChatEdit_InsertLink
    if type(insert) ~= "function" then return false end

    local ok, inserted = pcall(insert, link)
    return ok and inserted and true or false
end

--- One shift-click for every item the addon shows (the owner, 2026-10-12):
--- with the auction house open it searches the house for the item, else it
--- puts the item's link in the chat box being typed in, as the bags do.
-- @return true when the click was taken
function Widgets.ItemShiftClick(itemID, link)
    if not (IsShiftKeyDown and IsShiftKeyDown()) then return false end
    itemID = tonumber(itemID)
    if not itemID and type(link) == "string" then itemID = tonumber(link:match("item:(%d+)")) end
    if not itemID then return false end

    -- The drawer's Lists view is adding to a list: the item goes on it.
    local lists = ns.ShoppingListsView
    if lists and lists.TakeItem and lists:TakeItem(itemID, true) then return true end

    if ns.Scanner and ns.Scanner.isAuctionHouseOpen then
        if not (ns.UI and ns.UI.SearchAuctionHouse) then return false end
        ns.UI:SearchAuctionHouse(itemID)
        return true
    end

    return Widgets.LinkToChat(itemID, link)
end

--- Shift-click on a list row: search the auction house for its item, or
--- link it in chat with the house closed.
-- @return true when the click was taken
function Widgets.ShiftClickSearch(data, searchItem)
    if not (IsShiftKeyDown and IsShiftKeyDown()) then return false end

    local itemID = Widgets.RowItemID(data, searchItem)
    if not itemID then return false end

    local link = type(data.link) == "string" and data.link or nil
    return Widgets.ItemShiftClick(itemID, link)
end

--- A spot over an item icon (and, with `cover`, the line it sits on) that
--- shows the item's tooltip and takes the shift-click: for the icons in
--- detail panes and reports, which are not list rows. It reads the item
--- Theme.SetItemIcon last gave the icon, and shows only with the icon.
function Widgets.ItemHotspot(icon, cover)
    if not icon then return nil end
    local spot = CreateFrame("Button", nil, icon:GetParent())
    spot:SetPoint("TOPLEFT", icon, "TOPLEFT")
    spot:SetPoint("BOTTOMRIGHT", cover or icon, "BOTTOMRIGHT")
    if spot.RegisterForClicks then spot:RegisterForClicks("LeftButtonUp") end

    spot:SetScript("OnEnter", function(self)
        local itemID, link = Theme.IconItem(icon)
        if not itemID then return end
        Widgets.ShowItemTooltip(self, "ANCHOR_RIGHT", itemID, nil, link)
        if ns.Scanner and ns.Scanner.isAuctionHouseOpen then
            GameTooltip:AddLine(L["Shift-click to search the auction house"], 0.6, 0.6, 0.6)
        end
        GameTooltip:Show()
    end)
    spot:SetScript("OnLeave", function() GameTooltip:Hide() end)
    spot:SetScript("OnClick", function()
        Widgets.ItemShiftClick(Theme.IconItem(icon))
    end)

    Theme.SetIconSpot(icon, spot)
    return spot
end

function Widgets.CreateScrollList(parent, opts)
    local list = CreateFrame("Frame", nil, parent)

    local rowHeight = opts.rowHeight or 22

    list.data = {}
    list.rows = {}
    list.offset = 0

    local scrollbar = CreateFrame("Slider", nil, list)
    scrollbar:SetOrientation("VERTICAL")
    scrollbar:SetWidth(8)
    scrollbar:SetPoint("TOPRIGHT", 0, 0)
    scrollbar:SetPoint("BOTTOMRIGHT", 0, 0)
    scrollbar:SetValueStep(1)
    scrollbar:SetObeyStepOnDrag(true)

    local track = scrollbar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints(scrollbar)
    track:SetColorTexture(Theme.Unpack("panel"))

    local thumb = scrollbar:CreateTexture(nil, "ARTWORK")
    thumb:SetColorTexture(Theme.Unpack("metal"))
    thumb:SetSize(8, 40)
    scrollbar:SetThumbTexture(thumb)
    Widgets.LightThumb(scrollbar, thumb)

    list.scrollbar = scrollbar

    -- Whole rows only: a row that would hang past the list's bottom is not
    -- drawn. The list is a plain frame that clips nothing, and an overhanging
    -- last row once sat on top of the footer line under the Prices and
    -- Profit tabs.
    --
    -- A row is `rowHeight` tall unless a name on it wraps onto more lines
    -- than that holds (Theme.SetRowName keeps how tall in `rowNeed`); then
    -- that row alone grows to fit, so a long name never spills over its
    -- neighbours (the Profit tab, 2026-10-13). How tall each entry was drawn
    -- is kept, so the scrollbar can reach the end of a list with tall rows;
    -- an entry not drawn yet counts as `rowHeight`.
    local heights = setmetatable({}, { __mode = "k" })

    local function LabelNeed(label)
        if type(label) ~= "table" then return nil end
        local need = rawget(label, "rowNeed")
        if type(need) ~= "number" then return nil end
        -- A hidden line takes no room.
        local okShown, shown = pcall(label.IsShown, label)
        if okShown and shown == false then return nil end
        -- A label whose text has since been changed some other way (a cell
        -- blanked when its column is off) no longer needs the room.
        local ok, text = pcall(label.GetText, label)
        if ok and text ~= rawget(label, "rowNeedText") then return nil end
        return need
    end

    local function RowNeed(row)
        local need = rowHeight
        local function Take(label)
            local want = LabelNeed(label)
            if want and want + 4 > need then need = want + 4 end
        end
        Take(rawget(row, "name"))
        local cells = rawget(row, "cells")
        if type(cells) == "table" then
            for _, cell in pairs(cells) do Take(cell) end
        end
        -- Lines under the name that wrap (Theme.SetRowLine).
        local more = rawget(row, "needLabels")
        if type(more) == "table" then
            for _, label in ipairs(more) do Take(label) end
        end
        return math.ceil(need)
    end

    -- An entry not measured yet counts as tall as the ones measured are on
    -- average, so a list of long names scrolls to its end at the first try.
    local measuredSum, measuredCount = 0, 0

    local function KeepHeight(entry, need)
        if type(entry) ~= "table" then return end
        local old = heights[entry]
        if old then
            measuredSum = measuredSum - old
        else
            measuredCount = measuredCount + 1
        end
        measuredSum = measuredSum + need
        heights[entry] = need
    end

    local function ForgetHeights()
        heights = setmetatable({}, { __mode = "k" })
        measuredSum, measuredCount = 0, 0
    end

    local function HeightOf(entry)
        local known = type(entry) == "table" and heights[entry]
        if known then return known end
        if measuredCount > 0 then return math.max(rowHeight, measuredSum / measuredCount) end
        return rowHeight
    end

    --- The furthest the list can scroll: as many entries from the end as fit.
    local function MaxOffset(self, height)
        local used, index = 0, #self.data
        while index >= 1 do
            local h = HeightOf(self.data[index])
            if used + h > height then break end
            used = used + h
            index = index - 1
        end
        return math.max(0, index)
    end

    local function AcquireRow(index)
        local row = list.rows[index]
        if row then return row end

        row = CreateFrame("Button", nil, list)
        row:SetHeight(rowHeight)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        -- Dark glass: the row sits in the list's well, a faint band apart
        -- from its neighbours, with a fine line under it.
        row.background = Theme.Fill(row, "glass")
        row.line = row:CreateTexture(nil, "BACKGROUND", nil, 1)
        row.line:SetPoint("BOTTOMLEFT")
        row.line:SetPoint("BOTTOMRIGHT")
        row.line:SetHeight(1)
        row.line:SetColorTexture(Theme.Unpack("border", 0.6))
        -- Drawn in full and faded with SetAlpha. It used to be made with a
        -- colour alpha of 0, which no SetAlpha can lift, so the wash under
        -- the mouse never showed at all (Farmer had the same bug).
        row.highlight = Theme.Fill(row, "glassHover", nil, "BORDER")
        row.highlight:SetAlpha(0)

        -- The row the detail pane is showing sits in a faint gold light from
        -- its left edge.
        if Theme.GlowBand then row.glowBand = Theme.GlowBand(row, 0.08) end

        -- A gold edge on the row under the mouse, as Farmer's lists do, so the
        -- eye can follow a row across a wide table.
        row.hoverEdge = Theme.AccentStripe(row, 2)
        row.hoverEdge:SetDrawLayer("OVERLAY")
        row.hoverEdge:SetColorTexture(Theme.Unpack("accentHi"))
        row.hoverEdge:Hide()

        -- Titanforged: under the mouse the row lights from the left too, a
        -- soft gold wash fading across it and a glow off the gold edge. Only
        -- that row: both are dark and hidden at rest.
        row.hoverWash = row:CreateTexture(nil, "BORDER", nil, 1)
        row.hoverWash:SetAllPoints(row)
        row.hoverWash:Hide()

        row.edgeGlow = row:CreateTexture(nil, "ARTWORK", nil, 7)
        row.edgeGlow:SetPoint("TOPLEFT", 2, 0)
        row.edgeGlow:SetPoint("BOTTOMLEFT", 2, 0)
        row.edgeGlow:SetWidth(10)
        pcall(row.edgeGlow.SetBlendMode, row.edgeGlow, "ADD")
        row.edgeGlow:Hide()

        if opts.createRow then
            opts.createRow(row)
        end

        local function Light(value)
            row.highlight:SetAlpha(value)
            if Theme.LightGradient then
                Theme.LightGradient(row.hoverWash, "HORIZONTAL", "accent", 0.10, 0, value)
                Theme.LightGradient(row.edgeGlow, "HORIZONTAL", "accentHi", 0.25, 0, value)
            end
        end

        row:SetScript("OnEnter", function(self)
            Motion:Blend(self, "hover", 1, 0.1, Light)
            self.hoverEdge:Show()
            if opts.onEnter and self.data then
                self.tipFor = TipIdentity(self.data)
                opts.onEnter(self, self.data)
            end
        end)

        row:SetScript("OnLeave", function(self)
            Motion:Blend(self, "hover", 0, 0.18, Light)
            self.hoverEdge:SetShown(self.selected and true or false)
            self.tipFor = nil
            if opts.onLeave then opts.onLeave(self, self.data) end
        end)

        row:SetScript("OnClick", function(self, mouseButton)
            -- Shift-click any item row with the auction house open and the
            -- house searches for it (2026-10-04). Right-click stays
            -- what each list already made it.
            if self.data and Widgets.ShiftClickSearch(self.data, opts.searchItem) then return end

            if self.data and opts.onClick then
                opts.onClick(self.data, self.dataIndex, mouseButton, self)

                -- A click may have changed which row is selected.
                if opts.isSelected then list:Refresh() end
            end
        end)

        list.rows[index] = row
        return row
    end

    --- Lay the rows out from the scroll offset down, each as tall as it
    --- needs. Returns how many were drawn and whether every entry from the
    --- offset to the end was.
    local function Layout(self, height, maxOffset)
        local right = maxOffset > 0 and -10 or 0
        local y, index, drawn = 0, 0, 0
        local full = false

        -- No row is shorter than `rowHeight`, so none is made that could
        -- not fit.
        while y + rowHeight <= height do
            index = index + 1
            local dataIndex = index + self.offset
            local entry = self.data[dataIndex]
            if not entry then
                full = true
                break
            end

            local row = AcquireRow(index)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -y)
            row:SetPoint("TOPRIGHT", right, -y)
            row.data = entry
            row.dataIndex = dataIndex

            -- Alternating bands make a dense table far easier to track
            -- across, and must follow the data row, not the frame.
            row.selected = opts.isSelected and opts.isSelected(entry) or false

            if row.selected then
                row.background:SetColorTexture(Theme.Unpack("glassActive"))
            else
                row.background:SetColorTexture(Theme.Unpack(
                    dataIndex % 2 == 0 and "glassAlt" or "glass"))
            end

            row.hoverEdge:SetShown(row.selected or row:IsMouseOver())
            local band = rawget(row, "glowBand")
            if band then band:SetShown(row.selected) end

            if opts.updateRow then
                opts.updateRow(row, entry, dataIndex)
            end

            local need = RowNeed(row)
            KeepHeight(entry, need)

            if y + need > height then
                row.data = nil
                row:Hide()
                break
            end

            row:SetHeight(need)
            row:Show()
            y = y + need
            drawn = index
        end

        for spare = drawn + 1, #self.rows do
            local row = self.rows[spare]
            row.data = nil
            row:Hide()
        end

        return drawn, full
    end

    local function Draw(self)
        local total = #self.data
        local height = self:GetHeight()
        if type(height) ~= "number" or height < 0 then height = 0 end

        local maxOffset = MaxOffset(self, height)
        if self.offset > maxOffset then self.offset = maxOffset end

        -- Rows give up 10px to the scrollbar while it shows. A table whose
        -- column headings sit outside the list is told, so its headings can
        -- move in step; otherwise every right-aligned value sat 10px left of
        -- its heading whenever the list scrolled.
        local function Scrollbar(hasScrollbar)
            if opts.onScrollbarShown and self.hadScrollbar ~= hasScrollbar then
                self.hadScrollbar = hasScrollbar
                opts.onScrollbarShown(hasScrollbar)
            end
        end
        Scrollbar(maxOffset > 0)

        local drawn, full = Layout(self, height, maxOffset)

        -- Drawing measured the rows on screen. When one grew, the list may
        -- reach further than it thought (or need a scrollbar it had not got);
        -- lay it out once more with what is now known. Scrolled as far as it
        -- goes with the last entries still out of sight (taller than they
        -- were counted), it lets the reader go on until they show.
        local measured = MaxOffset(self, height)
        if not full and self.offset >= measured then
            measured = math.max(measured, total - math.max(1, drawn))
        end
        if measured ~= maxOffset then
            local hadBar = maxOffset > 0
            maxOffset = measured
            local moved = self.offset > maxOffset
            if moved then self.offset = maxOffset end
            if moved or hadBar ~= (maxOffset > 0) then
                Scrollbar(maxOffset > 0)
                drawn = Layout(self, height, maxOffset)
            end
        end

        scrollbar:SetMinMaxValues(0, maxOffset)
        scrollbar:SetShown(maxOffset > 0)

        -- The thumb is as long as the share of the list on screen, as the
        -- scroll frame's is, so it says how much more there is rather than
        -- only that there is more.
        if maxOffset > 0 and drawn > 0 and total > 0 then
            thumb:SetHeight(math.max(20, math.floor(height * drawn / total)))
        end

        if scrollbar:GetValue() ~= self.offset then
            scrollbar:SetValue(self.offset)
        end

        -- The row under the mouse may be showing a different entry now (the
        -- list scrolled, or was rebuilt under the cursor). Its tooltip is
        -- drawn again for that entry rather than left describing the last.
        if opts.onEnter then
            for index = 1, #self.rows do
                local row = self.rows[index]
                local tipFor = row and rawget(row, "tipFor")
                if tipFor ~= nil and row.data and TipIdentity(row.data) ~= tipFor
                    and row:IsMouseOver() and OwnsTooltip(row) then
                    row.tipFor = TipIdentity(row.data)
                    opts.onEnter(row, row.data)
                end
            end
        end
    end

    --- Draw the rows. Never inside itself: reading the list's height
    --- settles the game's layout, which can run OnSizeChanged (and with it
    --- Refresh) right there, and once a row's columns were laid out again
    --- mid-draw each pass set off the next until the stack ran out (Level
    --- Up, 2026-10-13). A call that comes while drawing asks for one more
    --- pass once this one is done, a few at most.
    local REDRAW_PASSES = 3
    local drawing, drawAgain = false, false
    function list:Refresh()
        if drawing then
            drawAgain = true
            return
        end
        drawing = true
        local passes, ok, err = 0, true, nil
        repeat
            drawAgain = false
            passes = passes + 1
            ok, err = pcall(Draw, self)
        until not ok or not drawAgain or passes >= REDRAW_PASSES
        drawing, drawAgain = false, false
        if not ok then error(err, 0) end
    end

    --- True while the rows are being drawn (for the tests).
    function list:IsDrawing()
        return drawing
    end

    --- Replace the rows, keeping the reader where they were.
    --
    -- The scroll position used to reset here. Nothing noticed while the lists
    -- were short, but the Post tab rebuilds itself once a second at the
    -- auction house, and once it started showing a whole bagful that meant a
    -- list that snapped back to the top every second and could not be
    -- scrolled at all. Refresh already clamps the offset to what the new data
    -- allows, so keeping it is safe; a caller showing a genuinely different
    -- list asks for the top with ScrollToTop.
    function list:SetData(data)
        self.data = data or {}
        self:Refresh()
    end

    function list:ScrollToTop()
        self.offset = 0
        self:Refresh()
    end

    function list:GetData()
        return self.data
    end

    scrollbar:SetScript("OnValueChanged", function(_, value)
        local newOffset = math.floor(value + 0.5)
        if newOffset ~= list.offset then
            list.offset = newOffset
            list:Refresh()
        end
    end)

    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(self, delta)
        local _, maxOffset = scrollbar:GetMinMaxValues()
        local newOffset = math.max(0, math.min(maxOffset, self.offset - (delta * 3)))

        if newOffset ~= self.offset then
            self.offset = newOffset
            self:Refresh()
        end
    end)

    -- Only a real change of size draws again; the game can say so more
    -- than once for the same size while it settles.
    local sizedWidth, sizedHeight
    list:SetScript("OnSizeChanged", function(self, width, height)
        if width ~= nil and width == sizedWidth and height == sizedHeight then return end
        -- A new width wraps names differently, so the heights kept go.
        if width ~= sizedWidth then ForgetHeights() end
        sizedWidth, sizedHeight = width, height
        self:Refresh()
    end)

    return list
end
