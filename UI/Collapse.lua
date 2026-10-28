-- Blackthornes Tradeskills -- UI/Collapse.lua
-- The header strip on the side panels, and the fold button that folds a
-- panel down to that strip and opens it back up: the gold gem on the
-- panel's trim, beside its close gem (2026-10-27, as on every other window).
--
-- The sell list and the craft pane both sit beside a Blizzard window and take
-- up a lot of the screen. Closing them outright means losing them until the
-- window is reopened, so this folds one away instead and remembers that it
-- was folded.
--
-- The strip is the main window's header in miniature (gold stripe down the
-- left, a faint sheen on top, a lit rule underneath), so the side panels read
-- as part of the same addon.
--
-- A panel hands over a `body` frame holding everything below the header. The
-- header stays on the panel itself, so it is still there to read and click
-- when the body is hidden.

local ADDON, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Collapse = {}
ns.Collapse = Collapse

-- Inside the gold dialog bevel, the same inset the main window's header uses.
local EDGE_PAD = 11
local HEADER_HEIGHT = 28

-- Folded height: the bevel, the header strip, the bevel again.
Collapse.HEIGHT = EDGE_PAD + HEADER_HEIGHT + EDGE_PAD

-- Where a panel's content starts, a little under the header's rule.
Collapse.CONTENT_TOP = -(EDGE_PAD + HEADER_HEIGHT + 7)

local BUTTON_SIZE = 16

--- Is this panel folded down to its header?
--
-- Read from settings each time rather than kept on the frame, so the answer
-- is right before the panel has ever been built.
function Collapse.IsCollapsed(key)
    return ns.Config ~= nil and ns.Config:Get(key) == true
end

--- The height a panel should take: its header strip when folded, else `full`.
function Collapse.Height(key, full)
    if Collapse.IsCollapsed(key) then return Collapse.HEIGHT end
    return full
end

--- The house header strip across the top of a side panel.
-- @return header, title
function Collapse.CreateHeader(frame, text)
    local Theme = ns.Theme

    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT", EDGE_PAD, -EDGE_PAD)
    header:SetPoint("TOPRIGHT", -EDGE_PAD, -EDGE_PAD)
    header:SetHeight(HEADER_HEIGHT)

    Theme.Fill(header, "header")
    Theme.TopSheen(header, 0.07)
    Theme.AccentStripe(header, 3)

    local rule = Theme.CreateDivider(header, "borderLit")
    rule:SetPoint("BOTTOMLEFT")
    rule:SetPoint("BOTTOMRIGHT")

    local title = Theme.CreateLabel(header, "normal", "accent")
    title:SetText(text)

    -- Stands in for the button until Attach puts one there.
    title:SetPoint("LEFT", header, "LEFT", 10, 0)

    return header, title
end

--- A plus drawn on the button from two bars of plain colour, the way the
--- theme draws everything, so it reads as a control rather than a letter.
--- Hung from the label, so it dips with it when pressed. Nil on a button
--- that cannot draw, which keeps its text "+" and "-".
local function CreateGlyph(button)
    if type(button.CreateTexture) ~= "function" or not button.label then return nil end

    local ok, glyph = pcall(function()
        local r, g, b = ns.Theme.Unpack("text")
        local bar = button:CreateTexture(nil, "OVERLAY")
        bar:SetSize(8, 2)
        bar:SetPoint("CENTER", button.label, "CENTER", 0, 0)
        bar:SetColorTexture(r, g, b, 1)

        local stem = button:CreateTexture(nil, "OVERLAY")
        stem:SetSize(2, 8)
        stem:SetPoint("CENTER", button.label, "CENTER", 0, 0)
        stem:SetColorTexture(r, g, b, 1)

        return { bar = bar, stem = stem }
    end)

    return ok and glyph or nil
end

--------------------------------------------------------------------------------
-- The fold gem
--------------------------------------------------------------------------------

-- On a dressed panel the fold button is the house gold gem, left of the red
-- close gem as on every other window (UI/FoldWindow.lua draws the same one);
-- with no close gem it takes the close gem's corner. The panel still folds
-- here, down to its header, and remembers it.
local GEM = 22
local GEM_GAP = 2
local CLOSE_OUT = 8

local INK = { 0.165, 0.110, 0.024 }
local GOLD = { 0.910, 0.784, 0.451 }

-- The game's own minimize and maximize art, for the Blizzard window style.
local ATLAS = {
    fold = { "RedButton-Condense", "RedButton-Condense-Pressed" },
    open = { "RedButton-Expand", "RedButton-Expand-Pressed" },
    highlight = "RedButton-Highlight",
}

local function Media(name)
    return ([[Interface\AddOns\%s\Media\Frame\%s]]):format(ADDON or "Blackthornes_TS", name)
end

local function Call(object, method, ...)
    local fn = object and object[method]
    if type(fn) ~= "function" then return false end
    return pcall(fn, object, ...)
end

local function Width(object)
    local ok, value = Call(object, "GetWidth")
    if ok and type(value) == "number" and value > 0 then return value end
    return nil
end

local function HasAtlas(name)
    local textures = C_Texture
    if type(textures) ~= "table" or type(textures.GetAtlasInfo) ~= "function" then return false end
    local ok, info = pcall(textures.GetAtlasInfo, name)
    return ok and info ~= nil
end

local function UseAtlas(button)
    for _, name in ipairs({ ATLAS.fold[1], ATLAS.fold[2], ATLAS.open[1], ATLAS.open[2], ATLAS.highlight }) do
        if not HasAtlas(name) then return false end
    end
    if not (Call(button, "SetNormalAtlas", ATLAS.fold[1])
        and Call(button, "SetPushedAtlas", ATLAS.fold[2])
        and Call(button, "SetHighlightAtlas", ATLAS.highlight, "ADD")) then
        return false
    end
    button.atlas = true
    return true
end

local function Bar(button)
    local bar = button:CreateTexture(nil, "OVERLAY", nil, 2)
    bar:SetColorTexture(INK[1], INK[2], INK[3], 1)
    return bar
end

--- The gold gem with its glow, a lit copy for the mouse, and a bar (open)
--- or a plus (folded) on its face.
local function DrawGem(button)
    local glow = button:CreateTexture(nil, "BACKGROUND")
    glow:SetTexture(Media("Glow"))
    glow:SetPoint("CENTER")
    glow:SetSize(GEM * 2.2, GEM * 2.2)
    glow:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)
    pcall(glow.SetBlendMode, glow, "ADD")

    local gem = button:CreateTexture(nil, "ARTWORK")
    gem:SetTexture(Media("FoldGem"))
    gem:SetAllPoints(button)

    local lit = button:CreateTexture(nil, "ARTWORK", nil, 1)
    lit:SetTexture(Media("FoldGem"))
    lit:SetAllPoints(button)
    pcall(lit.SetBlendMode, lit, "ADD")

    local across = Bar(button)
    across:SetSize(10, 3)
    across:SetPoint("CENTER", 0, 0)
    local down = Bar(button)
    down:SetSize(3, 10)
    down:SetPoint("CENTER", 0, 0)

    local function Light(p)
        glow:SetAlpha(0.25 + 0.55 * p)
        lit:SetAlpha(0.45 * p)
    end
    Light(0)

    button.Light = Light
    button.gemGlyph = { across = across, down = down }
end

local function GemTooltip(button)
    if not GameTooltip then return end
    GameTooltip:SetOwner(button, "ANCHOR_TOP")
    GameTooltip:SetText(button.tooltipText, 1, 1, 1)
    GameTooltip:Show()
end

local function CreateGem(trim, onClick)
    local button = CreateFrame("Button", nil, trim)
    button.isGem = true

    local close = rawget(trim, "closeButton")
    local size = GEM
    if rawget(trim, "blizzard") and close then size = Width(close) or GEM end
    button:SetSize(size, size)
    if close then
        local closeSize = Width(close) or 26
        button:SetPoint("CENTER", close, "CENTER", -(closeSize / 2 + size / 2 + GEM_GAP), 0)
    else
        button:SetPoint("CENTER", trim, "TOPRIGHT", -CLOSE_OUT, -CLOSE_OUT)
    end

    if not (rawget(trim, "blizzard") and UseAtlas(button)) then DrawGem(button) end

    button:SetScript("OnEnter", function(self)
        self.hovered = true
        local light = rawget(self, "Light")
        if light then
            if ns.Motion and type(ns.Motion.Blend) == "function" then ns.Motion:Blend(self, "hover", 1, 0.12, light) else light(1) end
        end
        GemTooltip(self)
    end)
    button:SetScript("OnLeave", function(self)
        self.hovered = false
        local light = rawget(self, "Light")
        if light then
            if ns.Motion and type(ns.Motion.Blend) == "function" then ns.Motion:Blend(self, "hover", 0, 0.18, light) else light(0) end
        end
        if GameTooltip then GameTooltip:Hide() end
    end)
    button:SetScript("OnClick", function() onClick() end)

    return button
end

local function UpdateButton(button, collapsed)
    button.tooltipText = collapsed and L["Expand this window"] or L["Collapse this window"]
    if rawget(button, "isGem") then
        if rawget(button, "atlas") then
            local art = collapsed and ATLAS.open or ATLAS.fold
            Call(button, "SetNormalAtlas", art[1])
            Call(button, "SetPushedAtlas", art[2])
        elseif rawget(button, "gemGlyph") then
            button.gemGlyph.down:SetShown(collapsed)
        end
        if rawget(button, "hovered") then GemTooltip(button) end
        return
    end

    local glyph = rawget(button, "glyph")
    if glyph then
        button:SetText("")
        glyph.stem:SetShown(collapsed)
    else
        button:SetText(collapsed and "+" or "-")
    end
end

--- Put the fold button on a panel: the gold gem on a dressed panel's trim,
--- else a small button at the left of its header.
--
-- opts.key       settings key that remembers the state between sessions
-- opts.header    the strip from CreateHeader
-- opts.title     its title, moved over to make room for a header button
-- opts.body      the frame holding everything that folds away
-- opts.onToggle  called with the new state after it changes; the panel
--                re-measures its height and refreshes itself there
function Collapse.Attach(frame, opts)
    local function Toggle()
        local collapsed = not Collapse.IsCollapsed(opts.key)

        ns.Config:Set(opts.key, collapsed)
        Collapse.Apply(frame)

        if opts.onToggle then opts.onToggle(collapsed) end
    end

    local trim = type(frame) == "table" and rawget(frame, "titan") or nil
    local button
    if trim and type(CreateFrame) == "function" then
        button = CreateGem(trim, Toggle)
    else
        button = ns.Widgets.CreateButton(opts.header, "-", Toggle, { width = BUTTON_SIZE, height = BUTTON_SIZE })

        button.glyph = CreateGlyph(button)
        button:SetPoint("LEFT", opts.header, "LEFT", 8, 0)

        opts.title:ClearAllPoints()
        opts.title:SetPoint("LEFT", button, "RIGHT", 7, 0)
    end

    frame.collapse = { button = button, key = opts.key, body = opts.body }
    Collapse.Apply(frame)

    return button
end

--- Show or hide the body to match the saved state. The caller sets the height.
function Collapse.Apply(frame)
    local state = frame.collapse
    if not state then return end

    local collapsed = Collapse.IsCollapsed(state.key)

    state.body:SetShown(not collapsed)
    UpdateButton(state.button, collapsed)
end

--- A band behind the controls along a panel's bottom edge, topped with the
--- same lit rule as the header, so the footer reads as its own shelf.
function Collapse.CreateFooter(body, height)
    local Theme = ns.Theme

    local band = body:CreateTexture(nil, "BACKGROUND", nil, 1)
    band:SetPoint("BOTTOMLEFT", EDGE_PAD, EDGE_PAD)
    band:SetPoint("BOTTOMRIGHT", -EDGE_PAD, EDGE_PAD)
    band:SetHeight(height)
    band:SetColorTexture(Theme.Unpack("header"))

    local rule = Theme.CreateDivider(body, "borderLit")
    rule:SetPoint("BOTTOMLEFT", band, "TOPLEFT")
    rule:SetPoint("BOTTOMRIGHT", band, "TOPRIGHT")

    return band
end
