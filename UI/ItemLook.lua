-- Blackthornes -- UI/ItemLook.lua
-- How an item looks in a list (the owner said build it, 2026-10-31, from the
-- design review's mockups): a thin ring round its icon in the game's quality
-- colour (grey, white, green, blue, purple and up), the same colour the
-- game gives its name. Nothing is saved and no words are new.
--
-- The same file in all five addons (a fix to it belongs in all five). Each
-- addon calls it from its own icon and name code:
--
--   ns.ItemLook.Attach(icon)              -- once, as the icon is made
--   ns.ItemLook.SetQuality(icon, quality) -- nil takes the ring away
--   ns.ItemLook.SetItem(icon, item)       -- by item ID or link
--   ns.ItemLook.QualityOf(item)           -- 0 to 7, or nil while not loaded
--   ns.ItemLook.Color(quality)            -- r, g, b, or nil
--   ns.ItemLook.SetCount(icon, count)     -- the stack count in the corner
--
-- The ring is one texture just behind the icon, one pixel larger on every
-- side, so nothing new sits over the icon and it needs no art. It follows
-- the icon: hidden with it and shown with it.
--
-- A stack's count sits in the icon's bottom right corner in the game's own
-- bag number font, as the bags show it, and only for more than one, so a
-- list says "Linen Cloth" with 20 on its icon instead of "Linen Cloth x20".
-- It follows the icon the same way.

local _, ns = ...

local ItemLook = {}
ns.ItemLook = ItemLook

-- How far the ring reaches past the icon, in pixels.
ItemLook.RING = 1
-- How strong the ring is: plain grey and white ones a little softer, so the
-- greens and blues stand out the way they do in the bags.
ItemLook.ALPHA = 0.9
ItemLook.PLAIN_ALPHA = 0.55

-- The game's quality colours, for a client without ITEM_QUALITY_COLORS.
ItemLook.COLORS = {
    [0] = { 0.62, 0.62, 0.62 },
    [1] = { 1.00, 1.00, 1.00 },
    [2] = { 0.12, 1.00, 0.00 },
    [3] = { 0.00, 0.44, 0.87 },
    [4] = { 0.64, 0.21, 0.93 },
    [5] = { 1.00, 0.50, 0.00 },
    [6] = { 0.90, 0.80, 0.50 },
    [7] = { 0.00, 0.80, 1.00 },
}

-- Kept beside each icon, weakly, so nothing is written on the texture.
local looks = setmetatable({}, { __mode = "k" })

local function Number(value)
    local ok, n = pcall(function() return value + 0 end)
    if ok and type(n) == "number" then return n end
    return nil
end

--- A quality's colour as the game draws it: r, g, b, or nil.
function ItemLook.Color(quality)
    quality = Number(quality)
    if not quality then return nil end
    local game = rawget(_G, "ITEM_QUALITY_COLORS")
    local color = type(game) == "table" and game[quality]
    if type(color) == "table" and Number(color.r) then
        return color.r, color.g, color.b
    end
    local own = ItemLook.COLORS[quality]
    if own then return own[1], own[2], own[3] end
    return nil
end

--- An item's quality (0 to 7) by item ID or link, or nil while the client
--- has not loaded it.
function ItemLook.QualityOf(item)
    if item == nil then return nil end
    local itemAPI = rawget(_G, "C_Item")
    local id = Number(item)
    if id and type(itemAPI) == "table" and type(itemAPI.GetItemQualityByID) == "function" then
        local ok, quality = pcall(itemAPI.GetItemQualityByID, id)
        quality = ok and Number(quality) or nil
        if quality then return quality end
    end
    local info = type(itemAPI) == "table" and itemAPI.GetItemInfo or rawget(_G, "GetItemInfo")
    if type(info) == "function" then
        local ok, _, _, quality = pcall(info, item)
        quality = ok and Number(quality) or nil
        if quality then return quality end
    end
    return nil
end

--- Show the ring when the icon is shown and has a quality, and the count
--- when it is shown and has one.
local function Sync(icon)
    local look = looks[icon]
    if not look then return end
    local okShown, shown = pcall(icon.IsShown, icon)
    shown = (okShown and shown) and true or false
    if look.ring then
        look.ring:SetShown((look.quality ~= nil and shown) and true or false)
    end
    if look.countText then
        look.countText:SetShown((look.count ~= nil and shown) and true or false)
    end
end

--- Give an icon its ring. Safe to call more than once.
function ItemLook.Attach(icon)
    if type(icon) ~= "table" or looks[icon] then return looks[icon] end
    local look = {}
    looks[icon] = look

    local okParent, parent = pcall(icon.GetParent, icon)
    if okParent and parent and type(parent.CreateTexture) == "function" then
        local layer, sublevel = "ARTWORK", 0
        if type(icon.GetDrawLayer) == "function" then
            local okLayer, gotLayer, gotSub = pcall(icon.GetDrawLayer, icon)
            if okLayer and type(gotLayer) == "string" then
                layer, sublevel = gotLayer, Number(gotSub) or 0
            end
        end
        local okRing, ring = pcall(parent.CreateTexture, parent, nil, layer, nil,
            math.max(-8, sublevel - 1))
        if okRing and ring then
            local reach = ItemLook.RING
            ring:SetPoint("TOPLEFT", icon, "TOPLEFT", -reach, reach)
            ring:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", reach, -reach)
            ring:Hide()
            look.ring = ring
        end
    end

    -- Follow the icon's showing and hiding.
    local show, hide, setShown = icon.Show, icon.Hide, icon.SetShown
    if type(show) == "function" then
        icon.Show = function(self, ...) show(self, ...); Sync(self) end
    end
    if type(hide) == "function" then
        icon.Hide = function(self, ...) hide(self, ...); Sync(self) end
    end
    if type(setShown) == "function" then
        icon.SetShown = function(self, ...) setShown(self, ...); Sync(self) end
    end
    return look
end

--- Ring the icon in a quality's colour; nil (or a quality with no colour)
--- takes the ring away.
function ItemLook.SetQuality(icon, quality)
    local look = looks[icon] or ItemLook.Attach(icon)
    if not look then return end
    local r, g, b = ItemLook.Color(quality)
    look.quality = r and Number(quality) or nil
    if look.ring and r then
        local alpha = (look.quality or 0) <= 1 and ItemLook.PLAIN_ALPHA or ItemLook.ALPHA
        look.ring:SetColorTexture(r, g, b, alpha)
    end
    Sync(icon)
end

--- Ring the icon for an item (ID or link); `quality` when the caller has it.
--- Returns the quality used, or nil while the item is not loaded.
function ItemLook.SetItem(icon, item, quality)
    quality = Number(quality) or ItemLook.QualityOf(item)
    ItemLook.SetQuality(icon, quality)
    return quality
end

-- The game's bag number font, else the plain one, outlined.
ItemLook.COUNT_FONTS = { "NumberFontNormal", "NumberFont_Outline_Med", "GameFontHighlightSmall" }
ItemLook.COUNT_SIZE = 12

local function MakeCount(icon, look)
    local okParent, parent = pcall(icon.GetParent, icon)
    if not (okParent and parent and type(parent.CreateFontString) == "function") then return nil end
    local ok, text = pcall(parent.CreateFontString, parent, nil, "OVERLAY")
    if not ok or not text then return nil end
    local fonted = false
    for _, name in ipairs(ItemLook.COUNT_FONTS) do
        local font = rawget(_G, name)
        if type(font) == "table" and type(text.SetFontObject) == "function" then
            if pcall(text.SetFontObject, text, font) then fonted = true; break end
        end
    end
    if not fonted and type(text.SetFont) == "function" then
        pcall(text.SetFont, text, "Fonts\\ARIALN.TTF", ItemLook.COUNT_SIZE, "OUTLINE")
    end
    if type(text.SetJustifyH) == "function" then text:SetJustifyH("RIGHT") end
    if type(text.SetTextColor) == "function" then text:SetTextColor(1, 1, 1) end
    text:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -1, 1)
    text:Hide()
    look.countText = text
    return text
end

--- Put a stack's count in the icon's corner; 1, 0 or nil shows none.
function ItemLook.SetCount(icon, count)
    local look = looks[icon] or ItemLook.Attach(icon)
    if not look then return end
    count = Number(count)
    if count and count > 1 then
        local text = look.countText or MakeCount(icon, look)
        look.count = math.floor(count)
        if text then text:SetText(tostring(look.count)) end
    else
        look.count = nil
    end
    Sync(icon)
end

--- The count an icon shows, or nil.
function ItemLook.CountShown(icon)
    local look = looks[icon]
    return look and look.count or nil
end

--- The count's font string, for the tests.
function ItemLook.CountOf(icon)
    local look = looks[icon]
    return look and look.countText or nil
end

--- The quality an icon was last ringed with, or nil.
function ItemLook.QualityShown(icon)
    local look = looks[icon]
    return look and look.quality or nil
end

--- The ring texture, for the tests.
function ItemLook.RingOf(icon)
    local look = looks[icon]
    return look and look.ring or nil
end
