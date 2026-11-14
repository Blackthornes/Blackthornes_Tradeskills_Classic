-- Blackthornes Tradeskills -- Logic/CraftProfit.lua
-- What one craft sells for, what its mats cost and the profit, for the
-- game's own profession window (the owner picked option B, 2026-11-14).
--
-- One answer feeds the recipe rows (UI/RecipeValue.lua), their hover and the
-- card under the reagents (UI/CraftProfitCard.lua), so the three never
-- disagree. Each mat is priced at the cheaper of the auction house and a
-- vendor, owned or not, and tagged with where that price came from. Nothing
-- is ever guessed: a mat or a sale with no price leaves the profit empty.
--
-- Worked out on demand and kept per recipe until a price or a setting moves,
-- or `KEEP` seconds pass, since the rows ask four times a second.

local _, ns = ...

local CraftProfit = ns.NewModule("CraftProfit")

CraftProfit.KEEP = 30

local POOR = (Enum and Enum.ItemQuality and Enum.ItemQuality.Poor) or 0

local kept = {}

local function Try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if not ok then return nil end
    return a, b, c, d
end

local function Now()
    return (type(GetTime) == "function" and GetTime()) or os.time()
end

local function Stamp()
    return tostring(ns.Prices and ns.Prices.changes) .. ":" .. tostring(ns.Config and ns.Config.changes)
end

--- Is the output a grey? Greys only ever go to a vendor.
function CraftProfit.IsGrey(itemID)
    if type(C_Item) == "table" and type(C_Item.GetItemQualityByID) == "function" then
        local quality = tonumber((Try(C_Item.GetItemQualityByID, itemID)))
        if quality ~= nil then return quality == POOR end
    end
    local getInfo = (type(C_Item) == "table" and C_Item.GetItemInfo) or _G.GetItemInfo
    local _, _, quality = Try(getInfo, itemID)
    return tonumber(quality) == POOR
end

--- Sold one listing at a time (gear), so the auction house takes whole silver.
local function IsItemAuction(itemID)
    local status = ns.Scanner and ns.Scanner.GetCommodityStatus
        and Try(ns.Scanner.GetCommodityStatus, ns.Scanner, itemID)
    if status ~= nil then return status == false end
    if type(C_Item) == "table" and type(C_Item.GetItemInfoInstant) == "function" then
        local _, _, _, _, _, classID = Try(C_Item.GetItemInfoInstant, itemID)
        return classID == 2 or classID == 4
    end
    return false
end

--- What one of the item brings in: the auction house after its cut, or a
--- vendor when that pays more. Greys at vendor only.
-- @return copper, way ("auction" or "vendor"), or nil when nothing is known
function CraftProfit.SellsFor(itemID, costEach)
    if not itemID then return nil end
    local vendor = ns.Util and ns.Util.GetVendorSellPrice and ns.Util.GetVendorSellPrice(itemID)
    if vendor and vendor <= 0 then vendor = nil end

    if CraftProfit.IsGrey(itemID) then
        if vendor then return vendor, "vendor" end
        return nil
    end

    local net
    if ns.Profit then
        local price = Try(ns.Profit.ChoosePostPrice, ns.Profit, itemID, costEach)
        if price and price > 0 and ns.Posting and ns.Posting.NormalisePrice then
            price = ns.Posting:NormalisePrice(price, not IsItemAuction(itemID)) or price
        end
        if price and price > 0 then
            net = Try(ns.Profit.NetFromListing, ns.Profit, itemID, price)
            if net and net <= 0 then net = nil end
        end
    end

    if net and (not vendor or net >= vendor) then return net, "auction" end
    if vendor then return vendor, "vendor" end
    return nil
end

--- One craft's figures, worked out fresh.
local function Work(recipeID)
    local recipe = ns.Recipes and ns.Recipes:GetAny(recipeID)
    if not recipe then return nil end

    local result = {
        recipeID = recipeID,
        outputItemID = recipe.outputItemID,
        reagents = {},
        bound = {},
        unpriced = {},
    }

    local low, high = recipe.quantityMin or 1, recipe.quantityMax or 1
    local yield = (low + high) / 2
    if yield <= 0 then yield = 1 end
    result.yield = yield
    if low == high and low > 1 then result.makes = low end

    local total = 0
    for _, reagent in ipairs(recipe.reagents or {}) do
        local itemID, quantity = reagent.itemID, reagent.quantity or 1
        local unit, source
        if ns.Cost then unit, source = ns.Cost:GetReagentUnitCost(itemID) end
        local line
        if unit then
            line = ns.Cost:CostOfMany(itemID, quantity, unit, source) or (unit * quantity)
        end
        local entry = {
            itemID = itemID,
            quantity = quantity,
            unitCost = unit,
            lineCost = line,
            way = unit and (source == "vendor" and "vendor" or "auction") or nil,
        }
        result.reagents[#result.reagents + 1] = entry
        if line then
            total = total + line
        else
            local isBound = ns.Util and ns.Util.IsBoundOnPickup and ns.Util.IsBoundOnPickup(itemID)
            entry.bound = isBound or nil
            if isBound then
                result.bound[#result.bound + 1] = itemID
            else
                result.unpriced[#result.unpriced + 1] = itemID
            end
        end
    end

    if #result.unpriced == 0 and #result.bound == 0 then
        result.cost = total
    elseif #result.unpriced == 0 then
        -- Only mats that bind on pickup lack a price: they can never be
        -- bought, so the rest is shown and the bound ones named.
        result.partial = total
        result.onlyBound = true
    end

    if recipe.outputItemID then
        local costEach = result.cost and (result.cost / yield) or nil
        local each, way = CraftProfit.SellsFor(recipe.outputItemID, costEach)
        if each then
            result.sellsEach = each
            result.sells = each * yield
            result.sellsWay = way
        end
    end

    if result.sells and result.cost then
        result.profit = result.sells - result.cost
    elseif result.sells and result.onlyBound then
        result.boundProfit = result.sells - result.partial
    end

    return result
end

--- The figures for one craft, kept until a price or setting moves.
-- @return { recipeID, outputItemID, yield, makes, reagents = { { itemID,
--   quantity, unitCost, lineCost, way ("auction"/"vendor"), bound } },
--   cost, partial, onlyBound, bound, unpriced, sells, sellsEach, sellsWay,
--   profit, boundProfit }, or nil for a recipe nobody knows
function CraftProfit:For(recipeID)
    if not recipeID then return nil end
    local stamp, now = Stamp(), Now()
    local entry = kept[recipeID]
    if entry and entry.stamp == stamp and now - entry.at < self.KEEP then
        return entry.result
    end
    local ok, result = pcall(Work, recipeID)
    if not ok then result = nil end
    kept[recipeID] = { stamp = stamp, at = now, result = result }
    return result
end

--- Forget what was kept, so the next ask works it out again.
function CraftProfit:Forget()
    kept = {}
end

--- An item's plain name in its quality colour, never a bracketed link.
function CraftProfit.ItemName(itemID)
    local getInfo = (type(C_Item) == "table" and C_Item.GetItemInfo) or _G.GetItemInfo
    local name, _, quality = Try(getInfo, itemID)
    if type(name) ~= "string" or name == "" then
        if type(C_Item) == "table" and type(C_Item.RequestLoadItemDataByID) == "function" then
            Try(C_Item.RequestLoadItemDataByID, itemID)
        end
        local L = ns.L
        return L and L.Format and L.Format("item %d", itemID) or ("item " .. tostring(itemID))
    end
    if ns.Util and ns.Util.ColorItemName then
        local colored = Try(ns.Util.ColorItemName, itemID, name, quality)
        if type(colored) == "string" and colored ~= "" then return colored end
    end
    return name
end

--- The bound mats by count and name: "4 Demonic Rune".
function CraftProfit.BoundNames(figures)
    local parts = {}
    for _, itemID in ipairs(figures and figures.bound or {}) do
        local quantity = 0
        for _, entry in ipairs(figures.reagents) do
            if entry.itemID == itemID then quantity = quantity + (entry.quantity or 0) end
        end
        local name = CraftProfit.ItemName(itemID)
        parts[#parts + 1] = quantity > 1 and (quantity .. " " .. name) or name
    end
    return table.concat(parts, ", ")
end

--------------------------------------------------------------------------------
-- Words and money, shared by the row, its hover and the card
--------------------------------------------------------------------------------

local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local MINUS = "\226\136\146" -- the minus sign, wider than a hyphen

local function Color(key, fallback)
    return (ns.COLORS and ns.COLORS[key]) or fallback
end

local function Money(copper)
    if ns.Util and ns.Util.FormatMoney then
        return ns.Util.FormatMoney(math.abs(copper), { short = true })
    end
    return tostring(math.floor(math.abs(copper) + 0.5)) .. "c"
end

--- "No price", greyed.
function CraftProfit.NoPrice()
    return "|c" .. Color("muted", "ff7a8089") .. L["No price"] .. "|r"
end

--- A profit as the rows show it: "+5g 3s" green, "−2s" red.
function CraftProfit.SignedMoney(copper)
    if type(copper) ~= "number" then return CraftProfit.NoPrice() end
    if math.floor(math.abs(copper) + 0.5) == 0 then return Money(0) end
    if copper > 0 then
        return "|c" .. Color("profit", "ff4fd18b") .. "+|r" .. Money(copper)
    end
    return "|c" .. Color("loss", "ffe5604f") .. MINUS .. "|r" .. Money(copper)
end

--- The text for a recipe row's right column, or "No price".
function CraftProfit.RowText(figures)
    if not figures then return CraftProfit.NoPrice() end
    if figures.profit then return CraftProfit.SignedMoney(figures.profit) end
    if figures.boundProfit then
        -- The part that could be priced, then a small "+" for the bound mats.
        return CraftProfit.SignedMoney(figures.boundProfit)
            .. "|c" .. Color("muted", "ff7a8089") .. "+|r"
    end
    return CraftProfit.NoPrice()
end

--- The three lines, as { label, value } pairs: Sells For, Mats Cost, Profit.
-- `makes` is the "Makes 2" note for Sells For, or nil.
function CraftProfit.Lines(figures)
    local lines = {}
    if not figures then
        lines[1] = { label = L["Sells For:"], value = CraftProfit.NoPrice() }
        lines[2] = { label = L["Mats Cost:"], value = CraftProfit.NoPrice() }
        lines[3] = { label = L["Profit:"], value = CraftProfit.NoPrice() }
        return lines
    end

    local makes = figures.makes and L.Format(L["Makes %d"], figures.makes) or nil
    lines[1] = {
        label = L["Sells For:"],
        value = figures.sells and Money(figures.sells) or CraftProfit.NoPrice(),
        makes = makes,
    }

    local cost
    if figures.cost then
        cost = Money(figures.cost)
    elseif figures.onlyBound then
        cost = L.Format(L["%s, plus %s"], Money(figures.partial or 0), CraftProfit.BoundNames(figures))
    else
        cost = CraftProfit.NoPrice()
    end
    lines[2] = { label = L["Mats Cost:"], value = cost }

    local profit
    if figures.profit then
        profit = CraftProfit.SignedMoney(figures.profit)
    elseif figures.boundProfit then
        profit = L.Format(L["%s, plus %s"], CraftProfit.SignedMoney(figures.boundProfit), CraftProfit.BoundNames(figures))
    else
        profit = CraftProfit.NoPrice()
    end
    lines[3] = { label = L["Profit:"], value = profit }

    return lines
end

--- "AH" or "Vendor" for one mat's price, coloured as the rest of the addon does.
function CraftProfit.WayText(way)
    if way == "vendor" then return "|cffe8cc8f" .. L["Vendor"] .. "|r" end
    if way == "auction" then return "|cff7db0ff" .. L["AH"] .. "|r" end
    return ""
end

CraftProfit.Money = Money
