-- Blackthornes Tradeskills -- UI/Theme.lua
-- Palette and panel construction.
--
-- Everything is built from plain textures rather than Blizzard backdrops, which
-- keeps the look consistent, avoids depending on BackdropTemplate being present,
-- and gives crisp one-pixel borders instead of the default bevelled frames.

local ADDON, ns = ...

local Theme = {}
ns.Theme = Theme

Theme.colors = {
    window    = { 0.055, 0.063, 0.078 },   -- #0E1014 outermost shell
    panel     = { 0.086, 0.094, 0.114 },   -- #16181D
    header    = { 0.110, 0.122, 0.145 },
    row       = { 0.133, 0.145, 0.172 },   -- #22252C
    rowAlt    = { 0.106, 0.118, 0.141 },
    rowHover  = { 0.180, 0.200, 0.239 },
    rowActive = { 0.220, 0.190, 0.110 },
    -- Dark glass (2026-10-10, asked to calm the gold glare behind list
    -- rows): table rows sit in the well they are recessed in, a faint band
    -- apart, with a fine line under each. Hover and the picked row lift a
    -- little and keep the gold to their edge.
    glass       = { 0.067, 0.075, 0.094 },   -- #111318
    glassAlt    = { 0.039, 0.047, 0.063 },   -- #0A0C10, the well itself
    glassHover  = { 0.094, 0.106, 0.129 },   -- #181B21
    glassActive = { 0.141, 0.122, 0.078 },   -- #241F14, gold in the dark

    border    = { 0.204, 0.224, 0.263 },
    borderLit = { 0.302, 0.333, 0.388 },

    accent    = { 0.784, 0.643, 0.302 },   -- #C8A44D
    -- Titanforged (2026-10-04): the lit gold of a hovered edge, the gold of
    -- a button's label, the dark ink on a gold button, the dark well a list
    -- sits recessed in, and the dim metal edge of a button at rest.
    accentHi  = { 0.945, 0.831, 0.533 },   -- #F1D488
    gilt      = { 0.941, 0.824, 0.494 },   -- #F0D27E
    ink       = { 0.110, 0.078, 0.024 },   -- #1C1406
    well      = { 0.039, 0.047, 0.063 },   -- #0A0C10
    metal     = { 0.541, 0.427, 0.180 },   -- #8A6D2E
    profit    = { 0.310, 0.820, 0.545 },   -- #4FD18B
    loss      = { 0.898, 0.376, 0.310 },   -- #E5604F
    warn      = { 0.910, 0.757, 0.353 },

    -- The Characters tab (2026-10-16): each side's colour on its heading,
    -- rested XP's blue and the XP bar's purple, as the game draws them.
    horde     = { 0.784, 0.208, 0.169 },
    alliance  = { 0.239, 0.490, 0.878 },
    rested    = { 0.435, 0.659, 1.000 },
    xp        = { 0.541, 0.361, 0.839 },

    text      = { 0.902, 0.910, 0.925 },   -- #E6E8EC
    -- Secondary text, a step brighter than Farmer's so the small print in
    -- the dense tables (ages, column headings, hints) is readable.
    muted     = { 0.545, 0.569, 0.608 },   -- #8B919B
    dim       = { 0.420, 0.440, 0.482 },   -- #6B707B

    -- Untinted, for Blizzard border textures that already carry their own
    -- gold colouring and only look muddy when tinted again.
    natural   = { 1, 1, 1 },
}

local FONT do
    local ok, path = pcall(function() return (GameFontNormal:GetFont()) end)
    FONT = (ok and path) or [[Fonts\FRIZQT__.TTF]]
end

Theme.FONT = FONT

-- The sizes at Normal text size.
Theme.BASE_SIZES = {
    tiny = 10,
    small = 11,
    normal = 12,
    large = 14,
    title = 16,
}

-- Text size (asked 2026-10-07: "I'm getting old"): Large and Larger add a
-- point or two to every size this addon draws, inside a window of the same
-- size. Window size scales the whole window instead; the two stack.
Theme.TEXT_STEPS = { normal = 0, large = 1, larger = 2 }

-- Read once, the first time a size is asked for after the saved settings
-- are in: text drawn before a change and after it would not match, so a
-- change waits for /reload.
local textStep

--- The points added to every size: 0, 1 or 2.
function Theme.TextStep()
    if textStep then return textStep end
    if not (ns.db and ns.Config) then return 0 end
    textStep = Theme.TEXT_STEPS[ns.Config:Get("textSize")] or 0
    return textStep
end

-- Looked up rather than stored, so the step is added wherever a size is
-- read: Theme.sizes.small is 11 at Normal, 13 at Larger.
Theme.sizes = setmetatable({}, {
    __index = function(_, key)
        local base = Theme.BASE_SIZES[key]
        if base then return base + Theme.TextStep() end
    end,
})

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

function Theme.Unpack(key, alpha)
    local color = Theme.colors[key] or Theme.colors.text
    return color[1], color[2], color[3], alpha or 1
end

--- Colour for a gold amount: green above zero, red below, muted at exactly zero.
function Theme.ProfitColor(value)
    if not value or value == 0 then return Theme.Unpack("muted") end
    if value > 0 then return Theme.Unpack("profit") end
    return Theme.Unpack("loss")
end

--- Flat filled texture covering a frame.
function Theme.Fill(frame, key, alpha, layer)
    local texture = frame:CreateTexture(nil, layer or "BACKGROUND")
    texture:SetAllPoints(frame)
    texture:SetColorTexture(Theme.Unpack(key, alpha))
    return texture
end

--- One-pixel border drawn as four edge textures, so it stays crisp at any size.
function Theme.Border(frame, key, alpha)
    local r, g, b, a = Theme.Unpack(key or "border", alpha)
    local edges = {}

    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local edge = frame:CreateTexture(nil, "BORDER")
        edge:SetColorTexture(r, g, b, a)

        if side == "TOP" then
            edge:SetPoint("TOPLEFT")
            edge:SetPoint("TOPRIGHT")
            edge:SetHeight(1)
        elseif side == "BOTTOM" then
            edge:SetPoint("BOTTOMLEFT")
            edge:SetPoint("BOTTOMRIGHT")
            edge:SetHeight(1)
        elseif side == "LEFT" then
            edge:SetPoint("TOPLEFT")
            edge:SetPoint("BOTTOMLEFT")
            edge:SetWidth(1)
        else
            edge:SetPoint("TOPRIGHT")
            edge:SetPoint("BOTTOMRIGHT")
            edge:SetWidth(1)
        end

        edges[#edges + 1] = edge
    end

    frame.borderTextures = edges
    return edges
end

function Theme.SetBorderColor(frame, key, alpha)
    if not frame.borderTextures then return end

    local r, g, b, a = Theme.Unpack(key, alpha)
    for _, edge in ipairs(frame.borderTextures) do
        edge:SetColorTexture(r, g, b, a)
    end
end

--- A panel: filled background plus a border.
function Theme.CreatePanel(parent, backgroundKey, borderKey)
    local panel = CreateFrame("Frame", nil, parent)
    panel.background = Theme.Fill(panel, backgroundKey or "panel")

    if borderKey ~= false then
        Theme.Border(panel, borderKey or "border")
    end

    return panel
end

--- A text label.
function Theme.CreateLabel(parent, size, colorKey, justify)
    local label = parent:CreateFontString(nil, "OVERLAY")
    label:SetFont(FONT, Theme.sizes[size] or size or Theme.sizes.normal, "")
    label:SetTextColor(Theme.Unpack(colorKey or "text"))
    label:SetJustifyH(justify or "LEFT")
    label:SetWordWrap(false)
    return label
end

-- One unanchored label per size, for measuring text no label holds yet.
local measures = {}

--- How wide `text` is at a label size, as the game draws it, or nil when it
--- cannot be measured. For widths worked out before any label holds the
--- text, such as a column fitted to its heading.
function Theme.MeasureText(size, text)
    if type(text) ~= "string" or text == "" then return nil end

    local label = measures[size]
    if not label then
        if not UIParent then return nil end
        label = Theme.CreateLabel(UIParent, size, "muted")
        label:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 0, -200)
        label:SetAlpha(0)
        measures[size] = label
    end

    label:SetText(text)
    local width = Theme.TextWidth(label)
    return width and math.ceil(width) or nil
end

--- How wide a label's text is when drawn in full, or nil when it cannot be
--- measured. A retail client can report only the part a fixed-width label
--- draws, which never looks too wide; GetUnboundedStringWidth, where the
--- client has it, measures all of it.
function Theme.TextWidth(label)
    for _, method in ipairs({ "GetUnboundedStringWidth", "GetStringWidth" }) do
        local measure = label[method]
        if type(measure) == "function" then
            local ok, width = pcall(measure, label)
            if ok and type(width) == "number" and width > 0 then return width end
        end
    end
    return nil
end

--- Put the first of `texts` that fits on a label: the full wording first,
--- then shorter ones, so a label says less rather than ending in "...".
--- When none fits it keeps the last, the shortest. A label that cannot be
--- measured gets the first. `room` is the width to fit, the label's own
--- width when not given (so the label needs a width or two anchors).
--- Returns the text it put there.
function Theme.FitText(label, texts, room)
    room = room or label:GetWidth()
    local measurable = type(room) == "number" and room > 0

    local chosen
    for _, text in ipairs(texts) do
        chosen = text
        label:SetText(text)
        if not measurable then break end

        local width = Theme.TextWidth(label)
        if width == nil or width <= room then break end
    end

    return chosen
end

--- An item's name on a list row, whole, never cut to "...": on one line in
--- the label's own size when it fits, else in the smaller size, wrapped onto
--- as many lines as it takes (a player's screenshot, 2026-10-07: "Deviate
--- S..."). The label is laid out by both its ends, so its width is the room.
---
--- A wrapped name keeps how tall it is in `label.rowNeed` (with the text it
--- was worked out for in `label.rowNeedText`), and the scroll list makes that
--- row taller to hold it. Without that a name of three lines spilled over the
--- rows above and below it (the Profit tab, 2026-10-13: "Woolen Reagent Bag
--- Red" over "Swashbuckler's Shirt").
function Theme.SetRowName(label, text, size)
    size = Theme.sizes[size or "small"] or Theme.sizes.small
    pcall(label.SetFont, label, FONT, size, "")
    pcall(label.SetWordWrap, label, false)
    pcall(label.SetHeight, label, 0)
    label.rowNeed, label.rowNeedText = nil, nil
    label:SetText(text)

    local ok, room = pcall(label.GetWidth, label)
    if not ok or type(room) ~= "number" or room <= 0 then return end
    local width = Theme.TextWidth(label)
    if type(width) ~= "number" or width <= room then return end

    local small = math.min(size, Theme.sizes.tiny)
    pcall(label.SetFont, label, FONT, small, "")
    pcall(label.SetWordWrap, label, true)
    label:SetText(text)

    -- How tall the wrapped name stands: what the game says, and never less
    -- than a line for each time the name's width goes into the room.
    local lineHeight = small + 2
    local smallWidth = Theme.TextWidth(label) or width
    local need = math.max(2, math.ceil(smallWidth / room)) * lineHeight
    local okHeight, height = pcall(label.GetStringHeight, label)
    if okHeight and type(height) == "number" and height > need then need = height end
    need = math.ceil(need)
    pcall(label.SetHeight, label, need)
    label.rowNeed, label.rowNeedText = need, text
end

--- Put text on a label whole, never cut to "...": in the first of `sizes`
--- (label size keys, the label's own first) it fits on one line in, else
--- wrapped in the last. The label is laid out by both its ends, so its
--- width is the room. Returns how much taller than one line it now stands,
--- for the frame holding it to grow by, 0 when it fits on one line or
--- cannot be measured, and how tall one line of it is.
function Theme.FitWhole(label, text, sizes)
    sizes = sizes or { "small", "tiny" }
    pcall(label.SetWordWrap, label, false)
    local ok, room = pcall(label.GetWidth, label)
    local measurable = ok and type(room) == "number" and room > 0
    local size = Theme.sizes.small
    for _, key in ipairs(sizes) do
        size = Theme.sizes[key] or Theme.sizes.small
        pcall(label.SetFont, label, FONT, size, "")
        label:SetText(text)
        if not measurable then return 0, size + 2 end
        local width = Theme.TextWidth(label)
        if width == nil or width <= room then return 0, size + 2 end
    end

    pcall(label.SetWordWrap, label, true)
    label:SetText(text)
    -- How tall it stands: what the game says, and never less than a line
    -- for each time its width goes into the room.
    local lineHeight = size + 2
    local width = Theme.TextWidth(label) or room
    local need = math.max(2, math.ceil(width / room)) * lineHeight
    local okHeight, height = pcall(label.GetStringHeight, label)
    if okHeight and type(height) == "number" and height > need then need = height end
    return math.ceil(need - lineHeight), lineHeight
end

--- A second line on a list row, whole: wrapped when it is too long, and the
--- scroll list grows that row to hold it (`rowNeed` is how far down the row
--- it reaches, from `top`, its distance from the row's top). The row lists
--- it in `row.needLabels`.
function Theme.SetRowLine(label, text, top, sizes)
    label.rowNeed, label.rowNeedText = nil, nil
    local extra, lineHeight = Theme.FitWhole(label, text, sizes or { "tiny" })
    if extra > 0 then
        label.rowNeed, label.rowNeedText = math.ceil(top + lineHeight + extra), text
    end
end

--- Colour a label holding an item's name in that item's rarity, as the game
--- draws it, else in `fallback` (a colour key, "text" when nil). Returns true
--- when it took the rarity, false while the client does not have the item
--- yet, so the caller can draw it again when the item arrives.
function Theme.SetItemNameColor(label, itemID, fallback, knownQuality)
    local Util = ns.Util
    if itemID and Util and Util.GetItemQualityColor then
        local ok, r, g, b = pcall(Util.GetItemQualityColor, itemID, knownQuality)
        if ok and r then
            label:SetTextColor(r, g, b)
            return true
        end
    end
    label:SetTextColor(Theme.Unpack(fallback or "text"))
    return false
end

--- Put a money amount on a label in as much detail as fits its width: every
--- coin, then the two largest, then the largest alone, rounded. Measured, so
--- a narrow cell never ends in "..." halfway through an amount. A label that
--- cannot be measured gets every coin.
function Theme.SetMoneyText(label, copper, opts)
    local function Format(parts)
        local options = {}
        for key, value in pairs(opts or {}) do options[key] = value end
        options.parts = parts
        return ns.Util.FormatMoney(copper, options)
    end

    label:SetText(Format(nil))
    if copper == nil then return end

    local room = label:GetWidth()
    if type(room) ~= "number" or room <= 0 then return end

    for _, parts in ipairs({ 2, 1 }) do
        local width = Theme.TextWidth(label)
        if width == nil or width <= room then return end
        label:SetText(Format(parts))
    end
end

--- Wrap a frame in Blizzard's classic bevelled tooltip border.
--
-- Used for controls that sit out in the game world rather than inside our own
-- window: the flat one-pixel border reads well against a dark panel but
-- disappears against terrain, bags and Blizzard's own art. The chunky gold
-- edge is instantly recognisable as an interactive UI element.
--
-- The overlay is mouse-transparent, so it decorates without stealing clicks.
-- Border presets. `edge` is the texture ring's thickness.
--
-- A backdrop edge draws *inside* its own rectangle, and these Blizzard textures
-- are authored to sit ON the frame edge with content padded inward -- that is
-- why every Blizzard panel has a wide margin. So the overlay matches the frame
-- exactly (expand = 0) and callers pad their contents by `pad`. Pushing the
-- overlay outward instead leaves the ring floating with a visible gap.
Theme.outlines = {
    tooltip = { file = [[Interface\Tooltips\UI-Tooltip-Border]], edge = 16, pad = 5 },
    dialog  = { file = [[Interface\DialogFrame\UI-DialogBox-Border]], edge = 32, pad = 11 },
}

function Theme.AddGameOutline(frame, opts)
    opts = opts or {}

    local preset = Theme.outlines[opts.style or "tooltip"] or Theme.outlines.tooltip

    local edgeSize = opts.edgeSize or preset.edge

    -- How far the overlay reaches beyond the frame. Zero keeps the bevel flush
    -- against the edge, which is what these textures expect.
    local expand = opts.expand or 0

    local created, overlay = pcall(CreateFrame, "Frame", nil, frame, "BackdropTemplate")

    if created and overlay and overlay.SetBackdrop then
        overlay:SetPoint("TOPLEFT", -expand, expand)
        overlay:SetPoint("BOTTOMRIGHT", expand, -expand)
        overlay:EnableMouse(false)

        -- Above the frame's own art but below its children, so the bevel never
        -- draws across the title or the tabs.
        overlay:SetFrameLevel(math.max(0, frame:GetFrameLevel()))

        -- Edge only: the frame keeps its own dark fill.
        local applied = pcall(overlay.SetBackdrop, overlay, {
            edgeFile = preset.file,
            edgeSize = edgeSize,
        })

        if applied then
            pcall(overlay.SetBackdropBorderColor, overlay, Theme.Unpack(opts.color or "accent"))
            frame.outline = overlay
            return overlay
        end

        overlay:Hide()
    end

    -- BackdropTemplate is unavailable or refused: fall back to a hand-drawn
    -- double ring, which still separates the frame from whatever is behind it.
    local outer = CreateFrame("Frame", nil, frame)
    outer:SetPoint("TOPLEFT", -2, 2)
    outer:SetPoint("BOTTOMRIGHT", 2, -2)
    outer:SetFrameLevel(frame:GetFrameLevel() + 1)
    outer:EnableMouse(false)

    Theme.Border(outer, "window")
    Theme.Border(frame, opts.color or "accent")

    frame.outline = outer
    return outer
end

--- Sink a panel into the window, as the game's inset panels sit: a darker
--- well, a shadow falling from its top edge and a faint light along its foot.
function Theme.Recess(frame)
    if frame.background then frame.background:SetColorTexture(Theme.Unpack("well")) end

    local shadow = frame:CreateTexture(nil, "BACKGROUND", nil, 3)
    shadow:SetPoint("TOPLEFT", 1, -1)
    shadow:SetPoint("TOPRIGHT", -1, -1)
    shadow:SetHeight(14)
    shadow:SetColorTexture(0, 0, 0, 1)
    local ok = type(CreateColor) == "function" and type(shadow.SetGradient) == "function"
        and pcall(shadow.SetGradient, shadow, "VERTICAL", CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.6))
    if not ok then shadow:Hide() end

    local foot = frame:CreateTexture(nil, "BORDER", nil, 2)
    foot:SetPoint("BOTTOMLEFT", 1, 0)
    foot:SetPoint("BOTTOMRIGHT", -1, 0)
    foot:SetHeight(1)
    foot:SetColorTexture(1, 1, 1, 0.05)

    if frame.borderTextures then
        Theme.SetBorderColor(frame, "border", 0.8)
        -- The top edge in shadow, so the panel reads as sunk rather than raised.
        local top = frame.borderTextures[1]
        if top then top:SetColorTexture(0.016, 0.020, 0.028, 1) end
    end
    return shadow
end

--- A button's metal: a light along its top half and a shade along its
--- bottom, over whatever fill it has, so it reads as raised and pressable.
function Theme.Bevel(frame)
    local shine = frame:CreateTexture(nil, "BORDER", nil, -1)
    shine:SetPoint("TOPLEFT", 1, -1)
    shine:SetPoint("TOPRIGHT", -1, -1)
    shine:SetPoint("BOTTOM", frame, "CENTER")
    shine:SetColorTexture(1, 1, 1, 0.06)

    local shade = frame:CreateTexture(nil, "BORDER", nil, -1)
    shade:SetPoint("BOTTOMLEFT", 1, 1)
    shade:SetPoint("BOTTOMRIGHT", -1, 1)
    shade:SetPoint("TOP", frame, "CENTER")
    shade:SetColorTexture(0, 0, 0, 0.22)

    if type(CreateColor) == "function" and type(shine.SetGradient) == "function" then
        pcall(shine.SetGradient, shine, "VERTICAL", CreateColor(1, 1, 1, 0.02), CreateColor(1, 1, 1, 0.12))
        pcall(shade.SetGradient, shade, "VERTICAL", CreateColor(0, 0, 0, 0.35), CreateColor(0, 0, 0, 0.02))
    end
    return shine, shade
end

--- Thin horizontal rule.
function Theme.CreateDivider(parent, key)
    local divider = parent:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(Theme.Unpack(key or "border"))
    divider:SetHeight(1)
    return divider
end

--------------------------------------------------------------------------------
-- House trim, shared with Blackthornes Farmer
--
-- The two addons are worn together, so they share the same few touches: a
-- gold stripe down the left of a header, headings in the accent colour over a
-- thin rule, item icons beside item names, and thin bars under a number that
-- is a share of something.
--------------------------------------------------------------------------------

--- A gold stripe down the left edge of a header or band.
function Theme.AccentStripe(frame, width, alpha)
    local stripe = frame:CreateTexture(nil, "ARTWORK")
    stripe:SetPoint("TOPLEFT")
    stripe:SetPoint("BOTTOMLEFT")
    stripe:SetWidth(width or 3)
    stripe:SetColorTexture(Theme.Unpack("accent", alpha))
    return stripe
end

--- A faint lighter line along the top edge, so a flat fill reads as a raised
--- surface rather than a hole.
function Theme.TopSheen(frame, alpha)
    local sheen = frame:CreateTexture(nil, "BORDER")
    sheen:SetPoint("TOPLEFT", 1, -1)
    sheen:SetPoint("TOPRIGHT", -1, -1)
    sheen:SetHeight(1)
    sheen:SetColorTexture(1, 1, 1, alpha or 0.05)
    return sheen
end

--- Shade `texture` from one alpha of a palette colour to another, along
--- "VERTICAL" (bottom to top) or "HORIZONTAL" (left to right). Where the
--- client cannot draw a gradient it gets one flat, fainter wash instead.
function Theme.SetGradientAlpha(texture, orientation, key, fromAlpha, toAlpha)
    local r, g, b = Theme.Unpack(key or "accent")
    texture:SetColorTexture(1, 1, 1, 1)

    local ok = false
    if type(CreateColor) == "function" and type(texture.SetGradient) == "function" then
        ok = pcall(texture.SetGradient, texture, orientation,
            CreateColor(r, g, b, fromAlpha), CreateColor(r, g, b, toAlpha))
    end

    if not ok then
        texture:SetColorTexture(r, g, b, math.max(fromAlpha, toAlpha) * 0.4)
    end
    return ok
end

--- Light a gradient made by Theme.SetGradientAlpha to `p` of its full
--- strength, hiding it at 0. The alpha goes into the gradient itself and the
--- texture hides when dark: faded with SetAlpha alone, the rows' hover wash
--- showed lit on every row of a list on Forever (seen 2026-10-10).
function Theme.LightGradient(texture, orientation, key, fromAlpha, toAlpha, p)
    p = math.max(0, math.min(1, tonumber(p) or 0))
    texture:SetShown(p > 0)
    if p > 0 then
        Theme.SetGradientAlpha(texture, orientation, key, fromAlpha * p, toAlpha * p)
    end
end

--- A soft gold glow fading down from the top of a header: the same light
--- Farmer's headers carry. Left out where the client draws no gradient.
function Theme.HeaderGlow(frame, height, alpha)
    local glow = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    glow:SetPoint("TOPLEFT")
    glow:SetPoint("TOPRIGHT")
    glow:SetHeight(height or 18)

    if not Theme.SetGradientAlpha(glow, "VERTICAL", "accent", 0, alpha or 0.10) then
        glow:Hide()
    end
    return glow
end

--- A gold wash across a band, brightest at its left edge and gone by its
--- right: the light a selected row or tab sits in. Hidden until shown.
function Theme.GlowBand(frame, alpha, key)
    local band = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
    band:SetAllPoints(frame)
    Theme.SetGradientAlpha(band, "HORIZONTAL", key or "accent", alpha or 0.16, 0)
    band:Hide()
    return band
end

--- A soft glow round the outside of a frame, fading out from its edge: the
--- neon edge Farmer's windows wear. Returns the four sides, so a caller can
--- brighten or dim them together with Theme.SetHalo. Where the client cannot
--- draw a gradient the glow is a flat, fainter band instead.
function Theme.Halo(frame, spread, alpha, key)
    spread = spread or 6
    local sides = {}

    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local halo = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
        pcall(halo.SetBlendMode, halo, "ADD")

        if side == "TOP" or side == "BOTTOM" then
            local out = side == "TOP" and 1 or -1
            halo:SetPoint(side .. "LEFT", frame, side .. "LEFT", 0, out * spread)
            halo:SetPoint(side .. "RIGHT", frame, side .. "RIGHT", 0, out * spread)
            halo:SetHeight(spread)
        else
            local out = side == "LEFT" and -1 or 1
            halo:SetPoint("TOP" .. side, frame, "TOP" .. side, out * spread, 0)
            halo:SetPoint("BOTTOM" .. side, frame, "BOTTOM" .. side, out * spread, 0)
            halo:SetWidth(spread)
        end

        halo.side = side
        sides[#sides + 1] = halo
    end

    frame.haloTextures = sides
    -- Where it settles; Motion:Open flares it from brighter as a window opens.
    frame.haloRest = alpha or 0.12
    frame.haloKey = key
    Theme.SetHalo(frame, frame.haloRest, key)
    return sides
end

--- Relight a halo drawn by Theme.Halo: `alpha` at the frame's edge, in the
--- palette colour `key` (the halo's own colour unless given).
function Theme.SetHalo(frame, alpha, key)
    local sides = frame and frame.haloTextures
    if not sides then return end

    key = key or frame.haloKey or "accent"
    alpha = math.max(0, tonumber(alpha) or 0)

    for _, halo in ipairs(sides) do
        -- The bright end sits against the frame: the bottom of the band
        -- above it, the top of the band below, and so on.
        if halo.side == "TOP" then
            Theme.SetGradientAlpha(halo, "VERTICAL", key, alpha, 0)
        elseif halo.side == "BOTTOM" then
            Theme.SetGradientAlpha(halo, "VERTICAL", key, 0, alpha)
        elseif halo.side == "LEFT" then
            Theme.SetGradientAlpha(halo, "HORIZONTAL", key, 0, alpha)
        else
            Theme.SetGradientAlpha(halo, "HORIZONTAL", key, alpha, 0)
        end
        halo:SetShown(alpha > 0)
    end
end

--- A section heading: small accent capitals with a rule running off to the
--- right, the way Farmer's settings sections read.
--
-- Returns the label; the rule hangs off it as label.rule.
function Theme.CreateHeading(parent, text, size)
    local label = Theme.CreateLabel(parent, size or "tiny", "accent")
    label:SetText(text)
    return Theme.StyleHeading(label, parent)
end

--- Restyle a heading label made elsewhere as a section heading: accent, with
--- the rule. Showing or hiding the label takes the rule with it.
function Theme.StyleHeading(label, parent)
    label:SetTextColor(Theme.Unpack("accent"))
    if label.rule then return label end

    parent = parent or label:GetParent()

    local rule = parent:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(Theme.Unpack("border"))
    rule:SetHeight(1)
    rule:SetPoint("LEFT", label, "RIGHT", 6, 0)
    rule:SetPoint("RIGHT", parent, "RIGHT", -12, 0)
    label.rule = rule

    local show, hide, setShown = label.Show, label.Hide, label.SetShown
    function label:Show() show(self); rule:Show() end
    function label:Hide() hide(self); rule:Hide() end
    function label:SetShown(on) setShown(self, on); rule:SetShown(on) end

    return label
end

local FALLBACK_ICON = [[Interface\Icons\INV_Misc_QuestionMark]]

-- The upgrade arrow: the game's own bag arrow, the one Blackthornes Equipment
-- puts on bag items, so both mean the same. The fallback is a green arrow
-- every client has, turned to point up.
local UPGRADE_ATLAS = "bags-greenarrow"
local UPGRADE_FALLBACK = [[Interface\Buttons\UI-MicroStream-Green]]

local function HasAtlas(name)
    if type(C_Texture) ~= "table" or type(C_Texture.GetAtlasInfo) ~= "function" then
        return false
    end
    local ok, found = pcall(C_Texture.GetAtlasInfo, name)
    return ok and found ~= nil
end

-- Kept beside the icons, weakly, so none of it can clash with a texture's own
-- fields: icon -> { size, upgrade, arrow }.
local iconState = setmetatable({}, { __mode = "k" })

--- The arrow for an icon, made the first time an upgrade is shown on it.
local function UpgradeArrow(icon, state)
    if state.arrow then return state.arrow end

    local parent = icon:GetParent()
    local ok, arrow = pcall(parent.CreateTexture, parent, nil, "OVERLAY", nil, 7)
    if not ok or not arrow then return nil end

    local size = math.max(8, math.floor(state.size * 0.6 + 0.5))
    arrow:SetSize(size, size)
    arrow:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)

    local usedAtlas = HasAtlas(UPGRADE_ATLAS) and pcall(arrow.SetAtlas, arrow, UPGRADE_ATLAS)
    if not usedAtlas then
        arrow:SetTexture(UPGRADE_FALLBACK)
        -- The stream arrow points down; flipped, it points up.
        arrow:SetTexCoord(0, 1, 1, 0)
    end
    arrow:Hide()

    state.arrow = arrow
    return arrow
end

--- Show the arrow when the icon is shown and its item is an upgrade.
local function ShowArrow(icon)
    local state = iconState[icon]
    if not state then return end
    local on = state.upgrade and icon:IsShown()
    local arrow = on and UpgradeArrow(icon, state) or state.arrow
    if arrow then arrow:SetShown(on and true or false) end
    -- A shift-click spot (Widgets.ItemHotspot) is there only with the icon.
    if state.spot then state.spot:SetShown(icon:IsShown() and state.itemID ~= nil) end
end

--- An item icon, trimmed of its built-in border the way the bags draw it.
--- The arrow follows the icon, so a row that hides its icon hides the arrow.
function Theme.CreateItemIcon(parent, size)
    local icon = parent:CreateTexture(nil, "ARTWORK")
    icon:SetSize(size or 16, size or 16)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    iconState[icon] = { size = size or 16, upgrade = false }

    local show, hide, setShown = icon.Show, icon.Hide, icon.SetShown
    function icon:Show() show(self); ShowArrow(self) end
    function icon:Hide() hide(self); ShowArrow(self) end
    function icon:SetShown(on) setShown(self, on); ShowArrow(self) end

    icon:Hide()
    return icon
end

--- Show an item's icon, or the question mark while the game has not sent it.
--- Hidden when there is no item at all. Gear that is an upgrade for the
--- character playing gets the green arrow (only with Blackthornes Equipment
--- loaded; see Logic/Upgrades.lua). `link`, when the caller has a bag item's
--- link, has a random-suffix item judged as the copy it is.
function Theme.SetItemIcon(icon, itemID, link)
    if not icon then return end

    local state = iconState[icon]
    if not itemID then
        if state then
            state.upgrade = false
            state.itemID, state.link = nil, nil
        end
        icon:Hide()
        return
    end

    if state then
        state.upgrade = ns.Upgrades ~= nil and ns.Upgrades:IsUpgrade(itemID, link)
        state.itemID, state.link = tonumber(itemID), link
    end
    icon:SetTexture((ns.Util and ns.Util.GetItemIcon and ns.Util.GetItemIcon(itemID))
        or FALLBACK_ICON)
    icon:Show()
end

--- Show a spell's icon (an enchant, which makes no item), with the green
--- arrow when `upgrade` is true. Hidden when the client gives no icon.
function Theme.SetSpellIcon(icon, spellID, upgrade)
    if not icon then return end

    local texture
    if spellID then
        if type(C_Spell) == "table" and type(C_Spell.GetSpellTexture) == "function" then
            local ok, found = pcall(C_Spell.GetSpellTexture, spellID)
            if ok then texture = found end
        end
        if not texture and type(GetSpellTexture) == "function" then
            local ok, found = pcall(GetSpellTexture, spellID)
            if ok then texture = found end
        end
    end

    local state = iconState[icon]
    if state then
        state.upgrade = texture ~= nil and upgrade == true
        state.itemID, state.link = nil, nil
    end
    if not texture then
        icon:Hide()
        return
    end
    icon:SetTexture(texture)
    icon:Show()
end

--- The item an icon was last given by Theme.SetItemIcon, and its link.
function Theme.IconItem(icon)
    local state = icon and iconState[icon]
    if not state then return nil end
    return state.itemID, state.link
end

--- Give an icon a frame that comes and goes with it (Widgets.ItemHotspot).
function Theme.SetIconSpot(icon, spot)
    local state = icon and iconState[icon]
    if not state then return false end
    state.spot = spot
    ShowArrow(icon)
    return true
end

--- A thin bar: a dark track with a coloured fill, for a number that is a share
--- of something (a margin, a sell-through, progress toward a goal).
function Theme.CreateBar(parent, width, height)
    local track = parent:CreateTexture(nil, "BORDER")
    track:SetSize(width or 40, height or 2)
    track:SetColorTexture(Theme.Unpack("rowAlt"))

    local fill = parent:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", track, "TOPLEFT")
    fill:SetPoint("BOTTOMLEFT", track, "BOTTOMLEFT")
    fill:SetWidth(1)

    local bar = { track = track, fill = fill, width = width or 40 }

    --- `fraction` 0 to 1, or nil to hide the bar.
    function bar:Set(fraction, colorKey)
        if not fraction then
            self.track:Hide()
            self.fill:Hide()
            return
        end

        fraction = math.max(0, math.min(1, fraction))
        self.fill:SetWidth(math.max(1, self.width * fraction))
        self.fill:SetColorTexture(Theme.Unpack(colorKey or "accent"))
        self.track:Show()
        self.fill:SetShown(fraction > 0)
    end

    function bar:SetPoint(...)
        self.track:ClearAllPoints()
        self.track:SetPoint(...)
    end

    bar:Set(nil)
    return bar
end

--------------------------------------------------------------------------------
-- The skill-up mark
--------------------------------------------------------------------------------

--- Where the addon's own art lives.
--
-- Built from the folder name the client hands us rather than written out, so
-- the texture still resolves if the addon is installed under another name.
local MEDIA = ([[Interface\AddOns\%s\Media\]]):format(ADDON)
Theme.MEDIA = MEDIA

-- How the mark on a recommended craft is drawn. Three of them because this is
-- the one part of the addon that cannot be checked outside the game: a texture
-- path that does not resolve draws nothing at all and looks exactly like a
-- feature that failed. `/bts star` switches between them in the moment rather
-- than waiting on another build.
--
--   star -- this addon's own gold star, generated by tools/make_star.py
--   raid -- the game's raid-target star, which every client has had for years
--   pip  -- a plain gold square, drawn from a colour texture, which cannot fail
Theme.marks = {
    star = { file = "SkillUpStar", size = 13 },
    raid = { blizzard = [[Interface\TargetingFrame\UI-RaidTargetingIcons]],
             coords = { 0, 0.25, 0, 0.25 }, size = 14 },
    pip  = { size = 7 },
}

-- How loudly the mark is drawn per tier. Orange is a point for certain and
-- gets the full star; yellow is very likely and gets a smaller, quieter one.
-- Size and weight rather than colour, because the art is already gold and
-- tinting gold orange only makes it muddy.
local MARK_TIERS = {
    optimal = { scale = 1.00, alpha = 1.00 },
    medium  = { scale = 0.80, alpha = 0.75 },

    -- Green: a skill up is possible but not likely. Only the craft pane draws
    -- it, since that pane marks every recipe that can still level you; the
    -- Profit tab only ever asks for the two tiers above.
    easy    = { scale = 0.65, alpha = 0.55 },
}

function Theme.CurrentMarkStyle()
    local style = ns.Config and ns.Config:Get("skillUpMarker")
    if style and Theme.marks[style] then return style end
    return "star"
end

function Theme.ApplyMarkStyle(mark, style)
    style = style or Theme.CurrentMarkStyle()

    local preset = Theme.marks[style] or Theme.marks.star

    mark.baseSize = preset.size
    mark:SetSize(preset.size, preset.size)

    if preset.file then
        mark:SetTexture(MEDIA .. preset.file)
        mark:SetTexCoord(0, 1, 0, 1)
        mark:SetVertexColor(1, 1, 1)
    elseif preset.blizzard then
        mark:SetTexture(preset.blizzard)
        mark:SetTexCoord(unpack(preset.coords))
        mark:SetVertexColor(1, 1, 1)
    else
        mark:SetColorTexture(Theme.Unpack("accent"))
        mark:SetTexCoord(0, 1, 0, 1)
    end

    mark.style = style
end

--- The mark a row wears when a craft both raises your skill and pays.
function Theme.CreateMark(parent)
    local mark = parent:CreateTexture(nil, "OVERLAY")
    Theme.ApplyMarkStyle(mark)
    mark:Hide()
    return mark
end

--- Show the mark for a tier, or hide it when there is nothing to say.
--
-- Rows are recycled and the style can change under them, so the style is
-- checked here rather than only when the row was built.
function Theme.SetMark(mark, tier)
    if not mark then return end

    local shape = tier and MARK_TIERS[tier]

    if not shape then
        mark:Hide()
        return
    end

    if mark.style ~= Theme.CurrentMarkStyle() then
        Theme.ApplyMarkStyle(mark)
    end

    local size = math.max(4, math.floor((mark.baseSize or 13) * shape.scale + 0.5))
    mark:SetSize(size, size)
    mark:SetAlpha(shape.alpha)
    mark:Show()
end
