-- Blackthornes Tradeskills -- Logic/Cost.lua
-- What it costs to make one of something.
--
-- Two rules drive everything here:
--   * A missing price is never treated as a free reagent. A recipe with an
--     unpriced reagent is reported as unpriceable, not as wildly profitable.
--   * Reagents you already own still cost what they are worth, unless you
--     explicitly switch to the cash-out-of-pocket view. Ignoring opportunity
--     cost is the single easiest way to talk yourself into a bad craft.

local _, ns = ...

local Cost = ns.NewModule("Cost")

-- How deep to chase "should I craft this reagent instead of buying it".
local MAX_SUBCRAFT_DEPTH = 3

--------------------------------------------------------------------------------
-- Reagent pricing
--------------------------------------------------------------------------------

--- What one unit of a reagent costs to buy, whatever is already owned.
--
-- The cash-out-of-pocket view is applied in GetCraftCost, where the quantity
-- is known. Applied here, one unit in the bags made the whole line free: one
-- bolt held, and all three a bag needs cost nothing. A bolt could then never
-- be cheaper to make than to buy, so once the first queued bolt was made,
-- the rest of them dropped off the queue.
--
-- @return copper, source  -- source is "vendor", "buy", "mine" (the player's
--   own price, from the Prices tab) or nil when unknown
function Cost:GetReagentUnitCost(itemID)
    -- A price the player set wins (2026-10-06). "use" is the cost,
    -- whoever sells it; "floor" is the least it costs, vendor or auction.
    local mine, mode
    if ns.Prices.GetMine then mine, mode = ns.Prices:GetMine(itemID) end
    if mine and mode == "use" then return mine, "mine" end

    -- Buying means paying the asking price, not the smoothed market average.
    -- A lone listing far below the rest is left out, as the undercut rule
    -- leaves it out (2026-09-26): one seller's single cheap unit is
    -- gone after one purchase and cannot supply a run of crafts, so pricing
    -- every craft off it overstated profit and the only-seller price.
    local auction = ns.Prices:GetValue(itemID, "lowest")
    local vendor = ns.Vendor:GetUnitPrice(itemID)

    -- A sub-craft set to Buy on the Level Up tab is priced off the auction
    -- house, not the vendor (2026-10-13): a shop that sells two at a time
    -- cannot supply a run of crafts. The vendor stays the fallback while
    -- nothing is listed, so it is never left unpriced.
    if vendor and auction and self:SkipsVendor(itemID) then vendor = nil end

    -- Anything a vendor sells costs the vendor price (2026-10-02).
    -- People list vendor-sold thread and vials on the auction house for many
    -- times the shop price, and paying that is a choice, not a cost. The one
    -- exception is a shop seen with limited stock: it sells a few now and
    -- then and cannot supply a run of crafts, so whatever is listed is what
    -- one really costs, dearer or not (a player found Wild Steelbloom at a
    -- far shop's 50c against 18s listed, 2026-10-18). The shop stays the
    -- price while nothing is listed. Merchant's Favor crates do the same.
    local limited = ns.Vendor.IsLimited and ns.Vendor:IsLimited(itemID)
    if vendor and not (limited and auction) then
        if mine and vendor < mine then return mine, "mine" end
        return vendor, "vendor"
    end

    -- GetValue has already lifted the auction price to a floor.
    if mine and auction == mine then return auction, "mine" end

    if auction then
        return auction, "buy"
    end

    return nil, nil
end

--- What `count` of a reagent costs to buy.
--
-- Priced as GetReagentUnitCost prices one, except that what comes off the
-- auction house is bought up the listings from the last scan: when 3 are
-- listed at 10s and the rest at 14s, 20 do not cost 20 x 10s (a player
-- asked, the owner agreeing 2026-10-11). A vendor's price is the same for
-- every one.
-- @param skip units already bought since the scan (their listings are gone)
-- @return copper, source  (as GetReagentUnitCost), or nil
function Cost:GetReagentCost(itemID, count, skip)
    local unit, source = self:GetReagentUnitCost(itemID)
    return self:CostOfMany(itemID, count, unit, source, skip), source
end

--- GetReagentCost for a unit price and source already looked up.
function Cost:CostOfMany(itemID, count, unit, source, skip)
    count = math.max(0, math.floor(tonumber(count) or 0))
    if not unit then return nil end
    if count == 0 then return 0 end

    if source == "buy" or (source == "mine" and not ns.Vendor:GetUnitPrice(itemID)) then
        local total = ns.Prices.GetCostFor and ns.Prices:GetCostFor(itemID, count, skip)
        if total then return total end
    end
    return unit * count
end

--------------------------------------------------------------------------------
-- Craft cost
--------------------------------------------------------------------------------

--- Which cached recipe, if any, produces this item.
function Cost:FindRecipeForItem(itemID)
    if self.recipeByOutput == nil or self.recipeIndexStale then
        self:RebuildOutputIndex()
    end
    return self.recipeByOutput[itemID]
end

--- Which recipe, known by any character on the account, produces this item.
--- The logged-in character's own comes first.
--
-- For pricing, where what an item sells for does not depend on who is logged
-- in. FindRecipeForItem stays with this character's crafts, because it is
-- what offers sub-crafts, and only those can be made here. Priced through it,
-- a bank alt posting what the crafter mailed it never undercut ("the cost to
-- make this is unknown") and got no markup over materials.
function Cost:FindAnyRecipeForItem(itemID)
    local own = self:FindRecipeForItem(itemID)
    if own then return own end
    return self.anyRecipeByOutput and self.anyRecipeByOutput[itemID]
end

function Cost:RebuildOutputIndex()
    local index = {}

    for recipeID, recipe in pairs(ns.Recipes:GetAll()) do
        -- A dropped profession's crafts are not offered as sub-crafts, nor
        -- is one the player said never to make as a sub-craft.
        local dropped = ns.Recipes.IsDropped and ns.Recipes:IsDropped(recipe)
        if recipe.outputItemID and not dropped and not self:IsNeverSubCraft(recipeID) then
            index[recipe.outputItemID] = recipeID
        end
    end

    -- Every character's crafts, for FindAnyRecipeForItem, leaving out each
    -- one's dropped professions as above.
    local anywhere = {}

    if ns.Recipes.GetAccountWide then
        for recipeID, recipe in pairs(ns.Recipes:GetAccountWide(true)) do
            if recipe.outputItemID then
                anywhere[recipe.outputItemID] = recipeID
            end
        end
    end

    self.recipeByOutput = index
    self.anyRecipeByOutput = anywhere
    self.altRecipeByOutput = self:BuildAltIndex()
    self.recipeIndexStale = false
end

--------------------------------------------------------------------------------
-- Parts an alt makes
--------------------------------------------------------------------------------

-- A player asked, the owner said yes (2026-10-24): a part only another of
-- your characters can make was priced at what buying it costs, so a craft
-- the account could make cheaply looked dear. With "Alts Make Sub-Crafts"
-- ticked (queueAltCrafting, the switch that hands sub-crafts to alts), such
-- a part is priced at its materials plus postage, and its line says who
-- makes it. The queue already gives that alt the craft and the mailbox the
-- mail (Queue:DeriveAcrossCharacters). Left out, and so bought as before:
-- a craft with a cooldown (Mooncloth, transmutes), which can't be made as
-- many times as a queue wants; one marked never to make as a sub-craft; a
-- dropped profession's; an alt this character can't mail; and anything
-- that binds when picked up, which can't be mailed.

--- Every other character's crafts by the item they make, for AltRecipeFor.
--- @return [itemID] = { recipeID, characterKey }
function Cost:BuildAltIndex()
    local list = {}
    local selfKey = ns.Config.GetCharacterKey and ns.Config:GetCharacterKey() or nil
    local characters = ns.db and ns.db.characters
    local queue = ns.Queue
    if not (selfKey and type(characters) == "table" and queue and queue.CanMail) then return list end

    local keys = {}
    for characterKey, record in pairs(characters) do
        if type(record) == "table" and characterKey ~= selfKey then keys[#keys + 1] = characterKey end
    end
    -- A fixed order, so the same alt is named whoever looks.
    table.sort(keys)

    local cooldowns = ns.Cooldowns
    for _, characterKey in ipairs(keys) do
        local record = characters[characterKey]
        if queue:CanMail(characterKey, selfKey) and type(record.recipes) == "table" then
            for recipeID, recipe in pairs(record.recipes) do
                local itemID = type(recipe) == "table" and recipe.outputItemID
                local dropped = itemID and ns.Recipes.IsDropped
                    and ns.Recipes:IsDropped(recipe, characterKey)
                local cooldown = itemID and cooldowns and cooldowns.HasCooldown
                    and cooldowns:HasCooldown(recipeID)
                if itemID and not list[itemID] and not dropped and not cooldown
                    and not self:IsNeverSubCraft(recipeID) then
                    list[itemID] = { recipeID = recipeID, characterKey = characterKey }
                end
            end
        end
    end
    return list
end

--- The whole name of the alt who makes a part (reagent.madeBy), for its line.
function Cost.MadeByName(characterKey)
    if not characterKey then return nil end
    local recipes = ns.Recipes
    local name = recipes and recipes.GetCharacterName and recipes:GetCharacterName(characterKey)
    return type(name) == "string" and name ~= "" and name or nil
end

--- The craft another of your characters would make this part with, while
--- alts make sub-crafts. nil when the character playing can make it itself.
--- @return recipeID, characterKey
function Cost:AltRecipeFor(itemID)
    if not itemID then return nil end
    if not (ns.Queue and ns.Queue.SharesWithAlts and ns.Queue:SharesWithAlts()) then return nil end
    if self.recipeByOutput == nil or self.recipeIndexStale then
        self:RebuildOutputIndex()
    end
    if self.recipeByOutput[itemID] then return nil end
    local alt = self.altRecipeByOutput and self.altRecipeByOutput[itemID]
    if not alt then return nil end
    if ns.Util and ns.Util.IsBoundOnPickup and ns.Util.IsBoundOnPickup(itemID) == true then
        return nil
    end
    return alt.recipeID, alt.characterKey
end

function Cost:InvalidateIndex()
    self.recipeIndexStale = true
    self.choiceByItem = nil
end

--------------------------------------------------------------------------------
-- Never made as a sub-craft
--------------------------------------------------------------------------------

-- On Discord (2026-10-07): scraps to light leather to medium to heavy
-- costs more crafting time than it saves, and "Queue sub-crafts" is all or
-- nothing. A craft marked here is never made to go into another one: its
-- item is bought instead, in every cost, the queue and the shopping list.
-- It can still be queued and sold as itself. Separate from the Profit tab's
-- Ignore, which is about what to sell, not how to make it.
--
-- Saved account wide in `neverSubCrafts`, recipeID -> the craft's name, so
-- Settings can list one the character playing does not know.

function Cost:IsNeverSubCraft(recipeID)
    local marked = recipeID ~= nil and ns.db ~= nil and ns.db.neverSubCrafts
    return marked and marked[recipeID] ~= nil or false
end

--- Never make this craft as a sub-craft (never = true), or allow it again.
-- Everything worked out from sub-crafts is worked out again at once: the
-- queue's sub-crafts, its costs and every tab showing them.
function Cost:SetNeverSubCraft(recipeID, never, name)
    if not ns.db or not recipeID then return end
    ns.db.neverSubCrafts = ns.db.neverSubCrafts or {}

    if never then
        local known = ns.Recipes and ns.Recipes.GetAny and ns.Recipes:GetAny(recipeID)
        ns.db.neverSubCrafts[recipeID] = name or (known and known.name)
            or ("recipe " .. tostring(recipeID))
        -- Buy and Make are one choice: never both.
        if ns.db.alwaysSubCrafts then ns.db.alwaysSubCrafts[recipeID] = nil end
    else
        ns.db.neverSubCrafts[recipeID] = nil
    end

    self:Changed()
end

--------------------------------------------------------------------------------
-- Vendor, Make or Buy
--------------------------------------------------------------------------------

-- On Discord (2026-10-13): Lesser Mana Potion is sold by a vendor two at a
-- time, so pricing every craft that uses it off the vendor was no help for
-- a run of them. A sub-craft's button on the Level Up tab picks how its
-- item is got when another craft needs it:
--   Vendor (nil)  the usual: the vendor's price for what a vendor sells,
--                 else the cheaper of buying and making it
--   "make"        always made, whatever buying costs
--   "buy"         never made (neverSubCrafts), and priced off the auction
--                 house rather than a vendor while anything is listed
-- Make is saved account wide in `alwaysSubCrafts`, recipeID -> the craft's
-- name, beside `neverSubCrafts`, which keeps Buy as it always has.

function Cost:IsAlwaysSubCraft(recipeID)
    local marked = recipeID ~= nil and ns.db ~= nil and ns.db.alwaysSubCrafts
    return marked and marked[recipeID] ~= nil or false
end

--- "make", "buy" or nil (the usual) for a craft.
function Cost:SubCraftChoice(recipeID)
    if self:IsNeverSubCraft(recipeID) then return "buy" end
    if self:IsAlwaysSubCraft(recipeID) then return "make" end
    return nil
end

--- Set a craft's choice: "make", "buy", or nil for the usual.
function Cost:SetSubCraftChoice(recipeID, choice, name)
    if not ns.db or not recipeID then return end
    if choice == "buy" then
        return self:SetNeverSubCraft(recipeID, true, name)
    end

    ns.db.neverSubCrafts = ns.db.neverSubCrafts or {}
    ns.db.alwaysSubCrafts = ns.db.alwaysSubCrafts or {}
    ns.db.neverSubCrafts[recipeID] = nil
    if choice == "make" then
        local known = ns.Recipes and ns.Recipes.GetAny and ns.Recipes:GetAny(recipeID)
        ns.db.alwaysSubCrafts[recipeID] = name or (known and known.name)
            or ("recipe " .. tostring(recipeID))
    else
        ns.db.alwaysSubCrafts[recipeID] = nil
    end

    self:Changed()
end

--- "make", "buy" or nil for an item, from the choice on any craft that
--- makes it. Looked up for every material priced, so laid out once and
--- kept until a choice or the recipes change.
function Cost:ItemChoice(itemID)
    if not itemID or not ns.db then return nil end
    if self.recipeIndexStale then self.choiceByItem = nil end

    local byItem = self.choiceByItem
    if not byItem then
        byItem = {}
        local getAny = ns.Recipes and ns.Recipes.GetAny
        for _, pair in ipairs({ { ns.db.alwaysSubCrafts, "make" }, { ns.db.neverSubCrafts, "buy" } }) do
            for recipeID in pairs(pair[1] or {}) do
                local recipe = getAny and ns.Recipes:GetAny(recipeID)
                if recipe and recipe.outputItemID then
                    -- Buy is laid out last, so it wins a clash.
                    byItem[recipe.outputItemID] = pair[2]
                end
            end
        end
        self.choiceByItem = byItem
    end
    return byItem[itemID]
end

--- True when the vendor's price is not to be used for this item.
function Cost:SkipsVendor(itemID)
    return self:ItemChoice(itemID) == "buy"
end

--- A choice moved: everything worked out from sub-crafts is worked out
--- again at once, the queue's sub-crafts, its costs and every tab showing them.
function Cost:Changed()
    self:InvalidateIndex()

    if ns.Queue and ns.Queue.RebuildDependencies then
        ns.Queue:RebuildDependencies()
        ns.Queue:Notify()
    end
    if ns.UI and ns.UI.RefreshActiveTab then ns.UI:RefreshActiveTab() end
end

--- The crafts never made as sub-crafts, A to Z:
--- { { recipeID, name, outputItemID }, ... }. outputItemID is nil for a
--- craft no character on record knows any more.
function Cost:GetNeverSubCrafts()
    return self:ListMarked(ns.db and ns.db.neverSubCrafts)
end

--- The crafts set to Make (always made as sub-crafts), as GetNeverSubCrafts.
function Cost:GetAlwaysSubCrafts()
    return self:ListMarked(ns.db and ns.db.alwaysSubCrafts)
end

function Cost:ListMarked(marked)
    local list = {}
    for recipeID, name in pairs(marked or {}) do
        local known = ns.Recipes and ns.Recipes.GetAny and ns.Recipes:GetAny(recipeID)
        list[#list + 1] = {
            recipeID = recipeID,
            name = type(name) == "string" and name or ("recipe " .. tostring(recipeID)),
            outputItemID = known and known.outputItemID or nil,
        }
    end
    table.sort(list, function(a, b)
        local left, right = a.name:lower(), b.name:lower()
        if left ~= right then return left < right end
        return a.recipeID < b.recipeID
    end)
    return list
end

--- The craft a material would be made with, had it not been marked never
--- to make as a sub-craft. For saying "bought, never made" beside it.
function Cost:NeverMadeRecipeFor(itemID)
    if not itemID or not (ns.db and ns.db.neverSubCrafts and next(ns.db.neverSubCrafts)) then
        return nil
    end
    for recipeID in pairs(ns.db.neverSubCrafts) do
        local recipe = ns.Recipes:GetAny(recipeID)
        if recipe and recipe.outputItemID == itemID then return recipeID end
    end
    return nil
end

--- Total reagent cost for one craft of a recipe.
--
-- @param opts.valueOwned  force the market-price view even when the player
--   has chosen cash-out-of-pocket. Pricing something off its materials needs
--   what they are worth, not what is left to pay for them. Carried down
--   through sub-crafts so the whole tree is valued the same way.
--
-- @param opts.made  { [itemID] = true } for the materials the queue is making.
--   Given, a material is priced as made when it is in the set and as bought
--   when it is not, whatever is cheaper today, so a queued craft costs
--   what the queue will actually do. Carried down through sub-crafts.
--
-- @param opts.recipe  cost this recipe record instead of looking the ID up
--   among the recipes characters know: a recipe nobody has learned yet
--   (Logic/RecipeBook.lua). Not carried down to sub-crafts, which are
--   always ones this character can make.
--
-- @return result table:
--   total        copper cost of a single craft, or nil when unpriceable
--   perUnit      cost per output item
--   reagents     array of { itemID, quantity, unitCost, lineCost, source,
--                           have, shortfall, crafted, toMake, subCost,
--                           madeBy (the alt who makes it, when not made here) }
--   unpriced     array of itemIDs with no price data
--   priceable    false when any reagent has no price
function Cost:GetCraftCost(recipeID, depth, visited, opts)
    depth = depth or 0
    visited = visited or {}

    -- GetAny, so a craft that lives on an alt can still be costed. Material
    -- cost is realm-wide regardless of who does the crafting.
    local recipe
    if opts and opts.recipe then
        recipe = opts.recipe
        opts = { valueOwned = opts.valueOwned, made = opts.made }
    else
        recipe = ns.Recipes:GetAny(recipeID)
    end
    if not recipe then return nil end

    -- A recipe whose reagent is made by a recipe that needs the first item
    -- would otherwise recurse forever.
    if visited[recipeID] then return nil end
    visited[recipeID] = true

    local result = {
        recipeID = recipeID,
        reagents = {},
        unpriced = {},
        priceable = true,
        total = 0,
    }

    local valueOwned = (opts and opts.valueOwned) or ns.Config:Get("valueOwnedMaterials")

    for _, reagent in ipairs(recipe.reagents or {}) do
        local itemID, quantity = reagent.itemID, reagent.quantity

        local unitCost, source = self:GetReagentUnitCost(itemID)
        local crafted = false
        local subCost
        -- The other character who makes it, when it is not made here.
        local madeBy

        -- If we know how to make this reagent and making it is cheaper than
        -- buying it, price it at the cheaper option and flag it as a sub-craft
        -- so the queue can sequence it first.
        if depth < MAX_SUBCRAFT_DEPTH then
            local subRecipeID = self:FindRecipeForItem(itemID)
            -- Else another of your characters, while alts make sub-crafts.
            local altKey
            if not subRecipeID then subRecipeID, altKey = self:AltRecipeFor(itemID) end

            local made = opts and opts.made
            if made and not made[itemID] then subRecipeID = nil end

            -- Not over a price the player chose to use for it.
            if subRecipeID and not visited[subRecipeID] and source ~= "mine" then
                local subResult = self:GetCraftCost(subRecipeID, depth + 1, visited, opts)
                local perUnit = subResult and subResult.priceable and subResult.perUnit

                -- Made on an alt, it comes by mail: the postage counts too,
                -- as it does when the queue picks who makes it.
                if perUnit and altKey and ns.Queue and ns.Queue.PostagePerUnit then
                    perUnit = perUnit + ns.Queue.PostagePerUnit(itemID,
                        { units = quantity, crafters = { [ns.Config:GetCharacterKey()] = true } }, altKey)
                end

                if perUnit then
                    -- Set to Make on the Level Up tab: made whatever buying costs.
                    local always = self:ItemChoice(itemID) == "make"
                    if not unitCost or made or always or perUnit < unitCost then
                        unitCost = perUnit
                        source = "craft"
                        crafted = true
                        subCost = subResult
                        madeBy = altKey
                    end
                end
            end
        end

        -- Owned, not just carried: the breakdown answers "do I have this",
        -- and bank stock counts. Whether you can craft right now is a separate
        -- question, answered by Profit:GetCraftableCount using bags alone.
        local inBags = ns.Inventory:GetBagCount(itemID)
        local have = inBags + ns.Inventory:GetBankCount(itemID)

        -- Cash-out-of-pocket view: what is in the bags is already paid for,
        -- but only that many. The rest of the line is still bought or made.
        local free = (not valueOwned) and math.min(quantity, inBags) or 0
        local lineCost = unitCost and (unitCost * (quantity - free)) or nil
        -- Bought, more than one goes up the listings (GetReagentCost).
        if lineCost and (source == "buy" or source == "mine") and quantity - free > 1 then
            lineCost = self:CostOfMany(itemID, quantity - free, unitCost, source) or lineCost
        end
        if free > 0 and free >= quantity then
            unitCost, source, lineCost = 0, "owned", 0
        end

        local entry = {
            itemID = itemID,
            quantity = quantity,
            unitCost = unitCost,
            lineCost = lineCost,
            source = source,
            crafted = crafted,
            -- How many of it the sub-craft makes, and that sub-craft's own
            -- costing, for the time a craft takes (Logic/CraftTime.lua).
            toMake = (crafted and source == "craft") and (quantity - free) or 0,
            subCost = subCost,
            madeBy = madeBy,
            have = have,
            inBags = inBags,
            shortfall = math.max(0, quantity - have),
        }

        result.reagents[#result.reagents + 1] = entry

        if unitCost then
            result.total = result.total + entry.lineCost
        else
            result.priceable = false
            result.unpriced[#result.unpriced + 1] = itemID
        end
    end

    visited[recipeID] = nil

    if not result.priceable then
        -- What the priced reagents come to, and the unpriced ones that bind on
        -- pickup and so can never be bought (Demonic Rune in Felcloth Robe,
        -- a player's report 2026-11-14). The total stays nil, so no profit
        -- is ever made up; a tooltip can still show the part it knows.
        result.partial = result.total
        result.bound = {}
        local allBound = true
        for _, unpricedID in ipairs(result.unpriced) do
            local isBound = ns.Util and ns.Util.IsBoundOnPickup
                and ns.Util.IsBoundOnPickup(unpricedID)
            if isBound then
                result.bound[#result.bound + 1] = unpricedID
            else
                allBound = false
            end
        end
        result.onlyBound = allBound and #result.bound > 0
        result.total = nil
        result.perUnit = nil
        return result
    end

    -- Recipes with a variable yield are valued at the average, which is the
    -- honest expectation over many crafts even though any single craft differs.
    local averageYield = ((recipe.quantityMin or 1) + (recipe.quantityMax or 1)) / 2
    if averageYield <= 0 then averageYield = 1 end
    -- Master Chef (a Legacy perk) gives extra results when this character
    -- cooks. Read only from the game; with nothing read it stays as it was.
    if ns.Legacy and ns.Recipes and ns.Recipes.SKILL_LINE_PROFESSIONS
        and ns.Recipes.SKILL_LINE_PROFESSIONS[recipe.skillLineID] == "Cooking"
        and type(ns.Recipes.Get) == "function" and ns.Recipes:Get(recipeID) == recipe then
        local ok, extra = pcall(ns.Legacy.CookingYield, ns.Legacy)
        if ok and type(extra) == "number" and extra > 1 then
            averageYield = averageYield * extra
        end
    end

    result.yield = averageYield
    result.perUnit = result.total / averageYield

    return result
end

--- What the materials for one unit of a recipe's output are worth.
--
-- Deliberately not the same question as "what will this craft cost me now":
-- reagents already in the bags count at market price here however the
-- cash-out-of-pocket setting is set, because a craft does not become worth
-- less to sell because the materials are already paid for.
--
-- @return perUnit copper, or nil when any reagent has no price at all
function Cost:GetMaterialValue(recipeID)
    local cost = self:GetCraftCost(recipeID, nil, nil, { valueOwned = true })

    if not cost or not cost.priceable then return nil end

    return cost.perUnit, cost
end

--------------------------------------------------------------------------------
-- Shortfalls
--------------------------------------------------------------------------------

--- Reagents missing for N crafts, aggregated and priced.
function Cost:GetShortfall(recipeID, craftCount)
    craftCount = craftCount or 1

    local recipe = ns.Recipes:GetAny(recipeID)
    if not recipe then return nil end

    local missing = {}

    for _, reagent in ipairs(recipe.reagents or {}) do
        local needed = reagent.quantity * craftCount
        local have = ns.Inventory:GetOwnedCount(reagent.itemID)
        local short = math.max(0, needed - have)

        if short > 0 then
            -- Priced as GetReagentCost prices it: the vendor price for
            -- what a vendor sells, else up the auction listings, lone low
            -- listing aside.
            local unitCost = self:GetReagentUnitCost(reagent.itemID)
            local estimatedCost = self:GetReagentCost(reagent.itemID, short)

            missing[#missing + 1] = {
                itemID = reagent.itemID,
                needed = needed,
                have = have,
                shortfall = short,
                unitCost = unitCost,
                estimatedCost = estimatedCost,
                onAlts = ns.Inventory:GetAltTotal(reagent.itemID),
            }
        end
    end

    return missing
end

function Cost:OnEnable()
    self:InvalidateIndex()
end
