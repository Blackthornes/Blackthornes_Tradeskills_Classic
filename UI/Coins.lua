-- Blackthornes -- UI/Coins.lua
-- Money in a list as the game shows it (the owner said build it,
-- 2026-10-31, from the design review's mockups): a white number with the
-- game's gold, silver or copper coin after it, each coin in its own column,
-- right-aligned, so "4s" and "1s 60c" line up and bigger amounts look
-- bigger. A coin with nothing in it is left out. Nothing is saved and no
-- words are new.
--
-- The same file in all five addons (a fix to it belongs in all five).
--
--   local coins = ns.Coins.Create(parent, make)  -- make() gives a font string
--   ns.Coins.Place(coins, relativeTo, relativePoint, x, y)  -- copper's right edge
--   ns.Coins.Set(coins, copper)   -- nil hides it; true when shown
--   ns.Coins.Width(coins)         -- how wide the three columns are
--   ns.Coins.Text(copper)         -- the same, as one line of text

local _, ns = ...

local Coins = {}
ns.Coins = Coins

Coins.FILE_VERSION = 1
Coins.ORDER = { "gold", "silver", "copper" }
Coins.ICONS = {
    gold = [[Interface\MoneyFrame\UI-GoldIcon]],
    silver = [[Interface\MoneyFrame\UI-SilverIcon]],
    copper = [[Interface\MoneyFrame\UI-CopperIcon]],
}
-- The widest each column needs to be, measured on these as the game draws
-- them; the numbers after are for a client that can't measure.
Coins.SAMPLES = { gold = "8888", silver = "88", copper = "88" }
Coins.WIDTHS = { gold = 44, silver = 28, copper = 28 }
Coins.GAP = 4

--- Gold, silver and copper in an amount of copper, or nil for no amount.
function Coins.Split(copper)
    if type(copper) ~= "number" or copper ~= copper then return nil end
    local amount = math.floor(math.max(0, copper) + 0.5)
    return math.floor(amount / 10000), math.floor((amount % 10000) / 100), amount % 100
end

--- The parts that show: { gold = n, silver = n, copper = n }, with a coin
--- that holds nothing left out (0 shows as 0 copper). nil for no amount.
function Coins.Parts(copper)
    local gold, silver, copperPart = Coins.Split(copper)
    if not gold then return nil end
    local parts = {}
    if gold > 0 then parts.gold = gold end
    if silver > 0 then parts.silver = silver end
    if copperPart > 0 or (gold == 0 and silver == 0) then parts.copper = copperPart end
    return parts
end

function Coins.Icon(coin)
    return ("|T%s:0:0:2:0|t"):format(Coins.ICONS[coin])
end

function Coins.Part(number, coin)
    return tostring(number) .. Coins.Icon(coin)
end

--- The amount as one line, white numbers and coins, for a place with no
--- columns. "" for no amount.
function Coins.Text(copper)
    local parts = Coins.Parts(copper)
    if not parts then return "" end
    local pieces = {}
    for _, coin in ipairs(Coins.ORDER) do
        if parts[coin] then pieces[#pieces + 1] = Coins.Part(parts[coin], coin) end
    end
    return "|cffffffff" .. table.concat(pieces, " ") .. "|r"
end

local function Measure(label, coin)
    local width
    if label.GetStringWidth then
        label:SetText(Coins.Part(Coins.SAMPLES[coin], coin))
        local ok, measured = pcall(label.GetStringWidth, label)
        if ok and type(measured) == "number" and measured > 0 then width = math.ceil(measured) + 2 end
        label:SetText("")
    end
    return width or Coins.WIDTHS[coin]
end

--- Three columns on parent. make() gives each a font string in the list's
--- own font; without it the game's small white one.
function Coins.Create(parent, make)
    local coins = { widths = {} }
    for _, coin in ipairs(Coins.ORDER) do
        local label
        if make then
            label = make()
        else
            label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        end
        if label.SetJustifyH then label:SetJustifyH("RIGHT") end
        if label.SetWordWrap then label:SetWordWrap(false) end
        coins[coin] = label
        coins.widths[coin] = Measure(label, coin)
        if label.SetWidth then label:SetWidth(coins.widths[coin]) end
        label:Hide()
    end
    return coins
end

--- Copper's right edge goes at the point given; silver and gold sit to its
--- left, each in its own column.
function Coins.Place(coins, relativeTo, relativePoint, x, y)
    if not coins then return end
    coins.copper:ClearAllPoints()
    coins.copper:SetPoint("RIGHT", relativeTo, relativePoint or "RIGHT", x or 0, y or 0)
    coins.silver:ClearAllPoints()
    coins.silver:SetPoint("RIGHT", coins.copper, "LEFT", -Coins.GAP, 0)
    coins.gold:ClearAllPoints()
    coins.gold:SetPoint("RIGHT", coins.silver, "LEFT", -Coins.GAP, 0)
end

function Coins.Width(coins)
    if not coins then return 0 end
    return coins.widths.gold + coins.widths.silver + coins.widths.copper + 2 * Coins.GAP
end

--- Shows the amount, or hides the columns for nil. True when shown.
function Coins.Set(coins, copper)
    if not coins then return false end
    local parts = Coins.Parts(copper)
    coins.amount = parts and copper or nil
    for _, coin in ipairs(Coins.ORDER) do
        local label = coins[coin]
        if parts and parts[coin] then
            label:SetText(Coins.Part(parts[coin], coin))
            if label.SetTextColor then label:SetTextColor(1, 1, 1) end
            label:Show()
        else
            label:SetText("")
            label:Hide()
        end
    end
    return parts ~= nil
end

function Coins.Shown(coins)
    return coins ~= nil and coins.amount ~= nil
end
