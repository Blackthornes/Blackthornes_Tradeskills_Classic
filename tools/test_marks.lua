-- UI/Marks.lua: the small mark and colour before what to do with an item.
-- The same file and test in all five addons.

local checks = 0
local function check(cond, what)
    if not cond then error("marks: " .. what, 2) end
    checks = checks + 1
end

local root = rawget(_G, "lfs_cwd") or "."

local function NewTexture()
    local t = { shown = true }
    function t:SetTexture(path) self.path = path end
    function t:SetTexCoord(l, r, top, b) self.coords = { l, r, top, b } end
    function t:SetVertexColor(r, g, b, a) self.color = { r, g, b, a } end
    function t:SetSize(w, h) self.size = { w, h } end
    function t:Show() self.shown = true end
    function t:Hide() self.shown = false end
    return t
end

local ns = {}
local chunk = assert(loadfile(root .. "/UI/Marks.lua"))
chunk("Blackthornes_Test", ns)
local Marks = ns.Marks
check(Marks ~= nil, "module is set on ns")
check(Marks.TEXTURE == [[Interface\AddOns\Blackthornes_Test\Media\Marks\Marks]], "the sheet is in this addon's folder")

-- Every kind names a mark the sheet has, and a colour.
for kind, entry in pairs(Marks.KINDS) do
    check(Marks.CELLS[entry[1]] ~= nil, kind .. " names a mark the sheet has")
    local r, g, b = Marks.Color(kind)
    check(r and g and b, kind .. " has a colour")
end
check(Marks.Color("nothing") == nil, "a kind not known has no colour")

-- The order matches the tool that draws the sheet.
local tool = assert(io.open(root .. "/tools/make_mark_art.py", "r"))
local source = tool:read("*a")
tool:close()
local order = {}
local list = source:match("MARKS = %[(.-)%]")
for name in list:gmatch('%("(%w+)",') do order[#order + 1] = name end
check(#order > 0, "the tool lists its marks")
for index, name in ipairs(order) do
    check(Marks.CELLS[name] == index - 1, name .. " sits where the tool draws it")
end
check(#order <= Marks.COLUMNS * Marks.ROWS, "every mark fits in the sheet")

-- The sheet is there and is the size the coordinates assume.
local art = io.open(root .. "/Media/Marks/Marks.tga", "rb")
check(art ~= nil, "Media/Marks/Marks.tga is there")
local header = art:read(18)
art:close()
local width = header:byte(13) + header:byte(14) * 256
local height = header:byte(15) + header:byte(16) * 256
check(width == 128 and height == 128, "128 by 128")
check(header:byte(17) == 32, "32-bit, with its own alpha")

-- Coordinates.
local l, r, t, b = Marks.Coords("coin")
check(l == 0 and r == 0.25 and t == 0 and b == 0.25, "the coin is the first cell")
l, r, t, b = Marks.Coords("paw")
check(l == 0 and r == 0.25 and t == 0.75 and b == 1, "the paw starts the last row")
check(Marks.Coords("nothing") == nil, "no cell for a mark not known")

-- Showing and hiding one.
local tex = NewTexture()
Marks.Attach(tex)
check(tex.shown == false, "hidden until a kind is set")
check(tex.size[1] == Marks.SIZE, "drawn at the mark's size")
Marks.Set(tex, "mail")
check(tex.shown == true and Marks.KindOf(tex) == "mail", "Mail shows")
check(tex.path == Marks.TEXTURE, "from the sheet")
l, r = Marks.Coords("letter")
check(tex.coords[1] == l and tex.coords[2] == r, "the letter's cell")
check(tex.color[3] == 1.00 and tex.color[1] < 0.5, "in blue")
Marks.Set(tex, "sell")
check(tex.color[1] == 1.00 and tex.color[2] == 0.82, "Sell is gold")
Marks.Set(tex, nil)
check(tex.shown == false and Marks.KindOf(tex) == nil, "nil hides it")
Marks.Set(tex, "nothing")
check(tex.shown == false, "a kind not known hides it")
Marks.Set(nil, "sell")

-- The words take the mark's colour.
local words = { SetTextColor = function(self, r2, g2, b2) self.color = { r2, g2, b2 } end }
Marks.Paint(words, "disenchant")
check(words.color and words.color[3] == 1.00, "Disenchant's words in purple")
words.color = nil
Marks.Paint(words, nil)
check(words.color == nil, "no kind leaves the words alone")

print(("  marks: %d checks passed"):format(checks))
