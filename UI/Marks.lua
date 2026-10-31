-- Blackthornes -- UI/Marks.lua
-- One small mark and colour for what to do with an item (the owner said
-- build it, 2026-10-31, from the design review's mockups): a gold coin for
-- Sell, a blue letter for Mail, a green lock for Keep, a purple star for
-- Disenchant, a grey bank for Bank, a green arrow for an upgrade and an
-- amber glass for Look at it; the auction house's tag, hourglass and lock;
-- Equipment's coin, ! , door and anvil for where gear comes from; and a paw,
-- star or grey circle for pet food. The words stay as they are, in the
-- mark's colour. Nothing is saved and no words are new.
--
-- The same file in all five addons (a fix to it belongs in all five), and so
-- is tools/make_mark_art.py, which draws Media/Marks/Marks.tga: every mark
-- white with a thin dark edge in one sheet, tinted here, so one picture
-- serves every colour and both window styles.
--
--   ns.Marks.Attach(texture)          -- once, as the line is made
--   ns.Marks.Set(texture, kind)       -- nil hides it
--   ns.Marks.Color(kind)              -- r, g, b, or nil
--   ns.Marks.Paint(fontString, kind)  -- the words in the mark's colour
--   ns.Marks.KindOf(texture)          -- the kind shown, or nil

local ADDON, ns = ...

local Marks = {}
ns.Marks = Marks

Marks.FILE_VERSION = 1
Marks.TEXTURE = ([[Interface\AddOns\%s\Media\Marks\Marks]]):format(ADDON or "")

-- The sheet: four across, four down, in tools/make_mark_art.py's order.
Marks.COLUMNS = 4
Marks.ROWS = 4
Marks.CELLS = {
    coin = 0, letter = 1, lock = 2, star = 3,
    bank = 4, upgrade = 5, look = 6, tag = 7,
    hourglass = 8, quest = 9, door = 10, anvil = 11,
    paw = 12, never = 13,
}

-- The colours, the game's own where it has one.
local GOLD = { 1.00, 0.82, 0.25 }
local BLUE = { 0.45, 0.68, 1.00 }
local GREEN = { 0.40, 0.85, 0.50 }
local BRIGHT_GREEN = { 0.30, 0.95, 0.40 }
local PURPLE = { 0.74, 0.52, 1.00 }
local GREY = { 0.68, 0.68, 0.70 }
local AMBER = { 1.00, 0.68, 0.25 }
local RED = { 0.95, 0.38, 0.32 }

-- What each kind of line shows: its mark and its colour.
Marks.KINDS = {
    -- What to do with an item (Butler, and the bag window).
    sell = { "coin", GOLD },
    mail = { "letter", BLUE },
    keep = { "lock", GREEN },
    disenchant = { "star", PURPLE },
    bank = { "bank", GREY },
    upgrade = { "upgrade", BRIGHT_GREEN },
    look = { "look", AMBER },
    -- The auction house's Sell list (Tradeskills).
    list = { "tag", GOLD },
    waiting = { "hourglass", AMBER },
    kept = { "lock", GREEN },
    -- Where gear comes from (Equipment).
    vendor = { "coin", GOLD },
    quest = { "quest", { 1.00, 0.86, 0.10 } },
    dungeon = { "door", RED },
    craft = { "anvil", AMBER },
    -- Pet food (Pets).
    eats = { "paw", GREEN },
    buff = { "star", PURPLE },
    never = { "never", GREY },
}

-- The size a mark is drawn at beside a line's words.
Marks.SIZE = 12

local shown = setmetatable({}, { __mode = "k" })

-- r, g, b for a kind, or nil.
function Marks.Color(kind)
    local entry = kind and Marks.KINDS[kind]
    if not entry then return nil end
    return entry[2][1], entry[2][2], entry[2][3]
end

-- The texture coordinates of a mark in the sheet.
function Marks.Coords(mark)
    local index = Marks.CELLS[mark]
    if not index then return nil end
    local column = index % Marks.COLUMNS
    local row = math.floor(index / Marks.COLUMNS)
    local w, h = 1 / Marks.COLUMNS, 1 / Marks.ROWS
    return column * w, (column + 1) * w, row * h, (row + 1) * h
end

function Marks.Attach(texture)
    if not texture then return end
    pcall(texture.SetTexture, texture, Marks.TEXTURE)
    if texture.SetSize then pcall(texture.SetSize, texture, Marks.SIZE, Marks.SIZE) end
    texture:Hide()
end

-- Shows the kind's mark in its colour, or hides it for nil or a kind not
-- known.
function Marks.Set(texture, kind)
    if not texture then return end
    local entry = kind and Marks.KINDS[kind]
    if not entry then
        shown[texture] = nil
        texture:Hide()
        return
    end
    pcall(texture.SetTexture, texture, Marks.TEXTURE)
    local left, right, top, bottom = Marks.Coords(entry[1])
    if texture.SetTexCoord then pcall(texture.SetTexCoord, texture, left, right, top, bottom) end
    if texture.SetVertexColor then
        pcall(texture.SetVertexColor, texture, entry[2][1], entry[2][2], entry[2][3], 1)
    end
    shown[texture] = kind
    texture:Show()
end

function Marks.KindOf(texture)
    return texture and shown[texture]
end

-- Colours the words to match their mark; nil leaves them as they are.
function Marks.Paint(fontString, kind)
    local r, g, b = Marks.Color(kind)
    if fontString and r and fontString.SetTextColor then
        fontString:SetTextColor(r, g, b)
    end
end
