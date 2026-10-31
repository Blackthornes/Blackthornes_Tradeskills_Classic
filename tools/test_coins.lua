-- UI/Coins.lua: money as the game's coins, each in its own column.
-- The same file and test in all five addons.

local checks = 0
local function check(cond, what)
    if not cond then error("coins: " .. what, 2) end
    checks = checks + 1
end

local root = rawget(_G, "lfs_cwd") or "."

local function NewLabel()
    local l = { shown = true, text = "", points = {} }
    function l:SetText(t) self.text = t end
    function l:GetText() return self.text end
    function l:GetStringWidth() return #(self.text:gsub("|T.-|t", "WW")) * 5 end
    function l:SetJustifyH(j) self.justify = j end
    function l:SetWordWrap(w) self.wrap = w end
    function l:SetWidth(w) self.width = w end
    function l:SetTextColor(r, g, b) self.color = { r, g, b } end
    function l:ClearAllPoints() self.points = {} end
    function l:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function l:Show() self.shown = true end
    function l:Hide() self.shown = false end
    return l
end

local ns = {}
local chunk = assert(loadfile(root .. "/UI/Coins.lua"))
chunk("Blackthornes_Test", ns)
local Coins = ns.Coins
check(Coins ~= nil, "module is set on ns")

-- Splitting.
local g, s, c = Coins.Split(31560)
check(g == 3 and s == 15 and c == 60, "3g 15s 60c")
check(Coins.Split(nil) == nil, "no amount, no split")
check(Coins.Split(0 / 0) == nil, "not a number, no split")
g, s, c = Coins.Split(-5)
check(g == 0 and s == 0 and c == 0, "below 0 is 0")

-- Coins with nothing in them are left out.
local parts = Coins.Parts(400)
check(parts.silver == 4 and parts.copper == nil and parts.gold == nil, "4s alone")
parts = Coins.Parts(34000)
check(parts.gold == 3 and parts.silver == 40 and parts.copper == nil, "3g 40s")
parts = Coins.Parts(10005)
check(parts.gold == 1 and parts.silver == nil and parts.copper == 5, "1g and 5c, no silver")
parts = Coins.Parts(0)
check(parts.copper == 0 and parts.silver == nil, "0 shows as 0 copper")

-- The game's own coins.
check(Coins.Part(12, "silver"):find("UI%-SilverIcon"), "silver's coin")
check(Coins.Text(160):find("^|cffffffff1|T"), "white numbers")
check(Coins.Text(nil) == "", "no text for no amount")

-- Columns.
local made = 0
local coins = Coins.Create({}, function() made = made + 1; return NewLabel() end)
check(made == 3, "three columns")
check(coins.copper.justify == "RIGHT" and coins.gold.wrap == false, "right-aligned, one line")
check(coins.gold.width > coins.copper.width, "gold's column is the widest")
check(coins.copper.text == "" and coins.copper.shown == false, "empty and hidden until set")
check(Coins.Width(coins) == coins.widths.gold + coins.widths.silver + coins.widths.copper + 2 * Coins.GAP,
    "width is the three columns and the gaps")

local anchor = {}
Coins.Place(coins, anchor, "RIGHT", -6, 0)
check(coins.copper.points[1][2] == anchor and coins.copper.points[1][4] == -6, "copper at the edge")
check(coins.silver.points[1][2] == coins.copper, "silver left of copper")
check(coins.gold.points[1][2] == coins.silver, "gold left of silver")

check(Coins.Set(coins, 160) == true, "shown")
check(coins.silver.shown and coins.copper.shown and not coins.gold.shown, "1s 60c in two columns")
check(coins.silver.text:find("^1|T") and coins.copper.text:find("^60|T"), "each number in its column")
check(coins.copper.color[1] == 1 and coins.copper.color[3] == 1, "white")
check(Coins.Shown(coins), "says it is shown")
Coins.Set(coins, 400)
check(coins.silver.shown and not coins.copper.shown and coins.copper.text == "", "4s leaves copper empty")
check(Coins.Set(coins, nil) == false and not coins.silver.shown and not Coins.Shown(coins), "nil hides it")
check(Coins.Set(nil, 5) == false, "no columns, nothing to do")

-- Without a way to measure, the usual widths.
local plain = Coins.Create({ CreateFontString = function() local l = NewLabel(); l.GetStringWidth = nil; return l end })
check(plain.widths.gold == Coins.WIDTHS.gold, "usual gold width")

print(("  coins: %d checks passed"):format(checks))
