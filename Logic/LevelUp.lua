-- Blackthornes Tradeskills -- Logic/LevelUp.lua
-- The cheapest way up a profession.
--
-- The Profit tab asks what is worth making for gold. This asks a different
-- question: which of the crafts you know will raise your skill, and which of
-- those costs least to make. So the order is the skill-up colour first
-- (orange, then yellow, then green, grey last) and material cost second,
-- cheapest first.
--
-- Nothing here prices anything on its own. The difficulty is what
-- Logic/SkillUp.lua stored when the profession window was last open, and the
-- cost is Logic/Cost.lua's, the very number the Profit tab shows, so the two
-- tabs can never disagree about what a craft costs. That includes the rule
-- that an in-between material counts at whichever is cheaper, buying it or
-- making it.
--
-- Soulbound crafts are kept. They cannot be sold, which is why the Profit
-- list drops them, but they level a profession as well as anything.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local LevelUp = ns.NewModule("LevelUp")

-- Best chance of a point first. A recipe whose colour has never been read sits
-- after green and before grey: it may well be orange, and hiding it on a guess
-- would be worse than showing it lower down.
local BAND = { optimal = 1, medium = 2, easy = 3, unknown = 4, trivial = 5 }

LevelUp.BAND = BAND

-- Short words for the CHANCE column. SkillUp's own labels are sentences,
-- which is right for a tooltip and too long for a column.
LevelUp.CHANCE_LABEL = {
    optimal = L["Guaranteed"],
    medium  = L["Likely"],
    easy    = L["Small"],
    trivial = L["None"],
    unknown = L["Not read"],
}

--- Which band a row falls in.
function LevelUp.BandOf(row)
    return BAND[row and row.tier or "unknown"] or BAND.unknown
end

--- The order of the list: band, then real cost, then name.
--
-- Real cost is the materials less what the craft gets back (a vendor, the
-- auction house or a disenchant, as the Profit tab's "Profit:" choice says,
-- the most of them on "Best"), so a craft that pays some of itself
-- back ranks as the cheaper way up (asked 2026-10-05). It is the plain
-- material cost where nothing comes back.
--
-- A craft whose materials have no price goes after every priced one in its
-- band. Treating a missing price as free would put it on top, and that is
-- exactly the craft you know least about.
--
-- Every tie falls through to the recipe ID. `pairs` hands recipes over in no
-- particular order, and a comparator that can call two rows equal makes the
-- list reshuffle itself on every refresh.
function LevelUp.Compare(a, b)
    local bandA, bandB = LevelUp.BandOf(a), LevelUp.BandOf(b)
    if bandA ~= bandB then return bandA < bandB end

    local costA, costB = a.realCost or a.cost, b.realCost or b.cost
    if costA and not costB then return true end
    if costB and not costA then return false end
    if costA and costB and costA ~= costB then return costA < costB end

    local nameA, nameB = a.name or "", b.name or ""
    if nameA ~= nameB then return nameA < nameB end

    return (a.recipeID or 0) < (b.recipeID or 0)
end

--------------------------------------------------------------------------------
-- What a craft gets back
--------------------------------------------------------------------------------

local POOR = (Enum and Enum.ItemQuality and Enum.ItemQuality.Poor) or 0

-- The item's quality, from the saved facts when Disenchant has them, else the
-- client. nil while the item is not loaded.
local function QualityOf(itemID)
    local Disenchant = ns.Disenchant
    if Disenchant and Disenchant.GetItemFacts then
        local facts = Disenchant:GetItemFacts(itemID)
        if facts and facts.quality then return facts.quality end
    end

    if ns.Util.HasFunction("C_Item.GetItemInfo") then
        local ok, _, _, quality = pcall(C_Item.GetItemInfo, itemID)
        if ok and type(quality) == "number" then return quality end
    end

    return nil
end

-- What one listing of the item pays once sold, or nil when the auction house
-- has never priced it. The Sell tab's own price chooser, less the cut and
-- deposits. A price the addon worked out from the materials is not a market,
-- so it never counts here: when every listing is yours the market value
-- stands instead.
local function AuctionReturn(itemID, costDetail)
    local Profit, Prices = ns.Profit, ns.Prices
    if not (Profit and Profit.ChoosePostPrice and Profit.NetFromListing) then return nil end

    local price, basis = Profit:ChoosePostPrice(itemID, costDetail)
    if basis == "derived" then return nil end
    if basis == "uncontested" then
        price = Prices and Prices.GetValue and Prices:GetValue(itemID, "market") or nil
    end
    if not price or price <= 0 then return nil end

    local net = Profit:NetFromListing(itemID, price)
    return net > 0 and math.floor(net + 0.5) or nil
end

--- What one craft gets back, each way it can be turned into gold.
--
-- The house rules: a grey item is worth what a vendor pays and nothing more,
-- and a disenchant counts at its most likely result alone (rarer ones are a
-- bonus). Disenchanted materials still have to be sold, so they lose the
-- auction house cut like any listing. A soulbound craft never reaches the
-- auction house, but a vendor and a disenchant still take it.
--
-- @return { vendor, auction, disenchant, best, bestWay, method } in copper
--   for one craft (its whole yield), any of them nil; bestWay is "vendor",
--   "auction" or "disenchant", the way the Profit tab's choice counts.
--   nil when the craft makes no item.
function LevelUp:GetReturns(recipe, costDetail)
    local itemID = recipe and recipe.outputItemID
    if not itemID then return nil end

    local yield = (costDetail and costDetail.yield) or 1
    local result = {}

    local vendor = ns.Util.GetVendorSellPrice and ns.Util.GetVendorSellPrice(itemID) or nil
    if vendor and vendor > 0 then result.vendor = math.floor(vendor * yield + 0.5) end

    local quality = QualityOf(itemID)

    if quality ~= nil and quality ~= POOR then
        -- Not loaded yet counts as sellable, as on the Profit tab.
        local soulbound = ns.Util.IsBoundOnPickup and ns.Util.IsBoundOnPickup(itemID)

        if not soulbound then
            local auction = AuctionReturn(itemID, costDetail)
            if auction then result.auction = math.floor(auction * yield + 0.5) end
        end

        local Disenchant = ns.Disenchant
        if Disenchant and Disenchant.IsDisenchantable and Disenchant:IsDisenchantable(itemID) then
            local value = Disenchant:GetValue(itemID)
            if value and value > 0 then
                local cut = ns.Config:Get("auctionCut") or 0.05
                result.disenchant = math.floor(value * (1 - cut) * yield + 0.5)
            end
        end
    end

    -- The Profit tab's "Profit:" choice decides which way counts (asked
    -- 2026-10-09), so the two tabs value a craft the same way. On "Best",
    -- whichever pays most; on one way alone, that way or nothing back.
    local method = LevelUp.Method()
    result.method = method

    local Profit = ns.Profit
    local ways = Profit and Profit.METHOD_WAYS and Profit.METHOD_WAYS[method]
        or (method == "best" and { "vendor", "auction", "disenchant" })
        or (method == "vendordisenchant" and { "vendor", "disenchant" }) or nil
    if not ways then
        if result[method] then result.best, result.bestWay = result[method], method end
        return result
    end

    -- Ties go to the vendor, then the auction house: the surer sale.
    -- "Vendor and DE" leaves the auction house out.
    for _, way in ipairs(ways) do
        if result[way] and (not result.best or result[way] > result.best) then
            result.best, result.bestWay = result[way], way
        end
    end

    return result
end

--- How a craft's return is counted: the Profit tab's choice ("best",
--- "auction", "vendor", "vendordisenchant" or "disenchant"), "best" when
--- there is none.
function LevelUp.Method()
    local Profit = ns.Profit
    local method = Profit and Profit.GetMethod and Profit:GetMethod() or nil
    if method == "auction" or method == "vendor" or method == "disenchant"
        or method == "vendordisenchant" then return method end
    return "best"
end

--------------------------------------------------------------------------------
-- Gold on hand (a player asked, the owner said build it, 2026-10-22)
--------------------------------------------------------------------------------

--- What buying the materials one craft is short of would cost, bank
--- counted as owned: 0 when the bags and bank hold them all, nil when a
--- missing one has no price.
function LevelUp.ToBuy(costDetail)
    if type(costDetail) ~= "table" then return nil end
    local total = 0
    for _, reagent in ipairs(costDetail.reagents or {}) do
        local short = reagent.shortfall or 0
        if short > 0 then
            if not reagent.unitCost then return nil end
            total = total + reagent.unitCost * short
        end
    end
    return math.floor(total + 0.5)
end

--- The gold the character playing carries, in copper; nil when the client
--- will not say.
function LevelUp.Purse()
    if type(GetMoney) ~= "function" then return nil end
    local ok, money = pcall(GetMoney)
    return ok and type(money) == "number" and money or nil
end

--- How much short the purse is of buying what one craft is missing.
-- @return need, have when the missing materials cost more than is carried;
--   nil otherwise (or when either is not known)
function LevelUp:ShortOfGold(row, purse)
    local need = row and row.toBuy
    purse = purse or LevelUp.Purse()
    if type(need) ~= "number" or type(purse) ~= "number" then return nil end
    if need > purse then return need, purse end
    return nil
end

--- The red line under a craft whose missing materials cost more than the
--- gold carried, or nil.
function LevelUp:ShortNote(row, purse)
    local need, have = self:ShortOfGold(row, purse)
    if not need then return nil end
    local function Money(copper) return ns.Util.FormatMoney(copper, { noColor = true }) end
    return L.Format("You need about %s to buy what's missing. You have %s.", Money(need), Money(have))
end

--- One row of the list.
--
-- @return { recipeID, name, outputItemID, skillLineID, tier, skillUp,
--           cost, costDetail, returns, back, backWay, realCost,
--           craftableNow, missing, toBuy }
--   cost is the material cost of one craft in copper, or nil when a
--   material has no price. back is the most one craft gets back (backWay
--   says how), and realCost the cost less that, below zero when the craft
--   pays. missing is how many materials are short for one craft, counting
--   the bank, the same way the Profit tab's breakdown does.
--- Every item a known craft uses, on any character: what can be a sub-craft.
-- @return { [itemID] = true }
function LevelUp:GetMaterialSet()
    local set = {}
    local function add(recipes)
        for _, recipe in pairs(recipes or {}) do
            for _, reagent in ipairs(type(recipe) == "table" and recipe.reagents or {}) do
                set[reagent.itemID] = true
            end
        end
    end

    -- Read in place rather than through Recipes:GetAccountWide, which copies
    -- every recipe and this runs on every redraw.
    add(ns.Recipes:GetAll())
    for _, record in pairs((ns.db and ns.db.characters) or {}) do
        if type(record) == "table" then add(record.recipes) end
    end
    return set
end

--- The recipes the list is drawn from: this character's, and with `alts`
--- every other character's too (2026-10-09: an alt's Lesser Mana
--- Potion or blasting powder could not be marked from here).
-- @return { [recipeID] = recipe }, { [recipeID] = characterKey } for those
--   only another character knows
function LevelUp:ListedRecipes(alts)
    local own = ns.Recipes:GetAll()
    if not alts then return own, {} end

    local list, knownBy = {}, {}
    local selfKey = ns.Config.GetCharacterKey and ns.Config:GetCharacterKey() or nil
    for recipeID, recipe in pairs(own) do
        if not (ns.Recipes.IsDropped and ns.Recipes:IsDropped(recipe)) then list[recipeID] = recipe end
    end

    -- In a fixed order, so the same character is named every time.
    local keys = {}
    for characterKey, record in pairs((ns.db and ns.db.characters) or {}) do
        if characterKey ~= selfKey and type(record) == "table" then keys[#keys + 1] = characterKey end
    end
    table.sort(keys)

    for _, characterKey in ipairs(keys) do
        for recipeID, recipe in pairs(ns.db.characters[characterKey].recipes or {}) do
            local dropped = ns.Recipes.IsDropped and ns.Recipes:IsDropped(recipe, characterKey)
            if type(recipe) == "table" and not list[recipeID] and not dropped then
                list[recipeID] = recipe
                knownBy[recipeID] = characterKey
            end
        end
    end
    return list, knownBy
end

--- Build one row of the list.
-- @param materials  GetMaterialSet's answer, to say whether the craft makes
--   something another craft uses (`isMaterial`); worked out when not given
function LevelUp:BuildRow(recipeID, recipe, materials)
    recipe = recipe or ns.Recipes:GetAny(recipeID)
    if not recipe then return nil end
    materials = materials or self:GetMaterialSet()

    local skillUp = ns.SkillUp and ns.SkillUp:GetForRecipe(recipeID, recipe) or nil
    local costDetail = ns.Cost:GetCraftCost(recipeID)

    local missing = 0
    for _, reagent in ipairs((costDetail and costDetail.reagents) or {}) do
        if (reagent.shortfall or 0) > 0 then missing = missing + 1 end
    end

    local cost = costDetail and costDetail.priceable and costDetail.total or nil
    local toBuy = LevelUp.ToBuy(costDetail)
    local returns = self:GetReturns(recipe, costDetail)
    local back = returns and returns.best or nil

    return {
        recipeID = recipeID,
        name = recipe.name,
        outputItemID = recipe.outputItemID,
        skillLineID = recipe.skillLineID,
        tier = skillUp and skillUp.tier or "unknown",
        skillUp = skillUp,
        cost = cost,
        costDetail = costDetail,
        returns = returns,
        back = back,
        backWay = returns and returns.bestWay or nil,
        realCost = cost and back and (cost - back) or nil,
        craftableNow = ns.Profit:GetCraftableCount(recipeID),
        missing = missing,
        toBuy = toBuy,
        isMaterial = recipe.outputItemID ~= nil and materials[recipe.outputItemID] == true,
        neverSubCraft = ns.Cost.IsNeverSubCraft and ns.Cost:IsNeverSubCraft(recipeID) or false,
        -- "make", "buy" or nil, and whether a vendor sells it, for the
        -- SUB-CRAFT button's Vendor, Make and Buy.
        subChoice = ns.Cost.SubCraftChoice and ns.Cost:SubCraftChoice(recipeID) or nil,
        vendorSells = recipe.outputItemID ~= nil and ns.Vendor.GetUnitPrice ~= nil
            and ns.Vendor:GetUnitPrice(recipe.outputItemID) ~= nil or false,
    }
end

--- Every recipe this character knows, in levelling order.
--
-- @param opts.skillLines  a set { [skillLineID] = true } to keep, or nil for
--   every profession. A set rather than one ID because Forever lists each
--   profession under two skill-line IDs and a recipe may carry either.
-- @param opts.includeTrivial  keep grey recipes (always last)
-- @param opts.craftableOnly   keep only what the bags cover right now
-- @param opts.canAfford       leave out crafts whose missing materials cost
--   more than the gold carried ("Can afford")
-- @param opts.search          part of a name, any case
-- @param opts.subCraftsOnly   keep only crafts whose item another craft
--   uses, grey ones too, from every character: where to mark one never to
--   make as a sub-craft. A craft only another character knows says who
--   (`knownBy`).
function LevelUp:GetRanked(opts)
    opts = opts or {}

    local needle = opts.search and opts.search ~= "" and opts.search:lower() or nil
    local rows = {}
    local materials = self:GetMaterialSet()

    local recipes, knownBy = self:ListedRecipes(opts.subCraftsOnly)
    local purse = opts.canAfford and LevelUp.Purse() or nil

    for recipeID, recipe in pairs(recipes) do
        local keep = not opts.skillLines or opts.skillLines[recipe.skillLineID]

        -- Not a profession this character has dropped.
        if keep and not knownBy[recipeID] and ns.Recipes.IsDropped
            and ns.Recipes:IsDropped(recipe) then
            keep = false
        end

        if keep and needle then
            keep = (recipe.name or ""):lower():find(needle, 1, true) ~= nil
        end

        if keep and opts.subCraftsOnly then
            keep = recipe.outputItemID ~= nil and materials[recipe.outputItemID] == true
        end

        if keep then
            local row = self:BuildRow(recipeID, recipe, materials)
            if row then row.knownBy = knownBy[recipeID] end

            if row then
                -- A sub-craft gone grey is still made to go into others,
                -- often the very one to stop making.
                local showGrey = opts.includeTrivial or opts.subCraftsOnly
                if row.tier == "trivial" and not showGrey then row = nil end
                if row and opts.craftableOnly and row.craftableNow < 1 then row = nil end
                if row and purse and self:ShortOfGold(row, purse) then row = nil end
            end

            if row then rows[#rows + 1] = row end
        end
    end

    table.sort(rows, LevelUp.Compare)

    return rows
end

--------------------------------------------------------------------------------
-- The Craft button
--------------------------------------------------------------------------------

--- What the Craft button should do for this recipe right now.
--
-- The same rules the Queue tab's Craft button follows, so the two never
-- disagree: a craft only starts from its own profession window, so when that
-- window is not the one open the click opens it instead (through
-- ProfessionOpener's secure button, since addon code may not cast); a craft
-- never asks for more than the bags make, or the game stops partway.
--
-- @param wanted  how many the player typed
-- @return { kind = "stop"|"open"|"craft"|"none", text, status, count, profession }
function LevelUp:CraftAction(recipeID, wanted)
    local Crafting = ns.Crafting

    if Crafting:IsBusy() then
        return { kind = "stop", text = L["Stop"], status = L["Crafting. Click Stop to end after this one."] }
    end

    local ready, reason = Crafting:GetReadiness(recipeID)

    if not ready then
        local status = reason == L["need materials"]
            and L["You are short of materials for this one."]
            or L.Format("Cannot craft: %s.", reason or L["unknown reason"])
        return { kind = "none", text = L["Craft"], status = status }
    end

    local craftable = ns.Profit:GetCraftableCount(recipeID)
    local count = math.max(1, math.min(tonumber(wanted) or 1, craftable))

    local opener = ns.ProfessionOpener

    -- In travel form or the like, the first click leaves it (the secure
    -- button, as for opening a window); the next opens or crafts.
    local leave = opener and opener.LeaveFormStep and opener:LeaveFormStep()
    if leave then
        return {
            kind = "open",
            text = L["Leave form"],
            status = L["Click to leave your form, then click again to craft. Not in combat."],
            count = count,
            profession = leave,
        }
    end

    if opener and not opener:WindowShowsRecipe(recipeID) then
        local profession = opener:ProfessionFor(recipeID)

        if profession then
            return {
                kind = "open",
                text = L.Format("Open %s", profession.name),
                status = L.Format("Opens your %s window. Click again to craft.", profession.name),
                count = count,
                profession = profession,
            }
        end
    end

    local status = L.Format("Makes %d now.", count)
    if (tonumber(wanted) or 1) > craftable then
        status = L.Format("Your bags only have materials for %d.", craftable)
    end

    return { kind = "craft", text = L.Format("Craft %d", count), status = status, count = count }
end

--------------------------------------------------------------------------------
-- The profession last open
--------------------------------------------------------------------------------

--- Which skill line the open profession window is showing.
--
-- Worked out from the recipes it lists rather than from a profession API, so
-- the answer is always an ID that the cached recipes actually carry. The
-- window can show a few recipes from elsewhere, so the most common skill line
-- wins.
function LevelUp:ReadOpenSkillLine()
    if not ns.Util.HasFunction("C_TradeSkillUI.GetAllRecipeIDs") then return nil end

    local ok, recipeIDs = pcall(C_TradeSkillUI.GetAllRecipeIDs)
    if not ok or type(recipeIDs) ~= "table" then return nil end

    local counts, best, bestCount = {}, nil, 0

    for _, recipeID in ipairs(recipeIDs) do
        local recipe = ns.Recipes:Get(recipeID)
        local skillLineID = recipe and recipe.skillLineID

        if skillLineID then
            counts[skillLineID] = (counts[skillLineID] or 0) + 1

            if counts[skillLineID] > bestCount then
                best, bestCount = skillLineID, counts[skillLineID]
            end
        end
    end

    return best
end

--- Remember the profession that was open, per character, so the tab opens on
--- it even at the auction house with no profession window up.
function LevelUp:NoteOpenProfession()
    local skillLineID = self:ReadOpenSkillLine()
    if not skillLineID then return end

    local record = ns.Recipes:GetCharacterRecord(true)
    if record then record.lastSkillLine = skillLineID end
end

function LevelUp:GetLastSkillLine()
    local record = ns.Recipes:GetCharacterRecord(false)
    return record and record.lastSkillLine or nil
end

function LevelUp:OnEnable()
    -- After Recipes has had a chance to harvest, so a first visit to a
    -- profession still finds its recipes in the cache. The list event fires
    -- in bursts while the window settles, so the reads are coalesced.
    local function Later()
        if LevelUp.noteTimer then LevelUp.noteTimer:Cancel() end
        LevelUp.noteTimer = C_Timer.NewTimer(1.5, function()
            LevelUp.noteTimer = nil
            LevelUp:NoteOpenProfession()
        end)
    end

    ns.RegisterEvent(self, "TRADE_SKILL_SHOW", Later)
    ns.RegisterEvent(self, "TRADE_SKILL_LIST_UPDATE", Later)
end
