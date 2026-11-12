-- Blackthornes Tradeskills -- Logic/MerchantsFavor.lua
-- What a point of Merchant's Favor costs, bought through Waylaid Crates.
--
-- A player's idea (2026-10-08): handing in a Waylaid Crate does not depend on
-- your professions, so the crate and the materials that fill it can both be
-- bought on the auction house. One crate costs
--
--     the crate + its cheapest bundle - the silver the turn-in pays back
--
-- and that over the favor it pays is the price of one favor. The crates and
-- their bundles are Data/WaylaidCrates.lua.
--
-- Rewards are learned from the game. When a filled ("Sealed") crate leaves
-- the bags and Merchant's Favor and money come in within a few seconds, that
-- is what the crate paid, kept account wide in merchantsFavor.rewards by the
-- sealed crate's item ID. Filling a crate is seen the same way (a Waylaid
-- Crate goes, a Sealed one comes), which says which sealed crate each kind
-- turns into. Until a turn-in is seen, the rewards players report stand in,
-- marked as such; Artisan crates have none. None of this has been seen in
-- game yet: Merchant's Favor may be a currency or an item, so both are
-- watched.
--
-- No character names are kept: only item IDs, amounts and when.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Util = ns.Util

local MerchantsFavor = ns.NewModule("MerchantsFavor")

-- A turn-in, the favor and the money it pays arrive as separate events, in
-- no promised order. Ones this close together are the same turn-in.
local MATCH_SECONDS = 5

-- How long after the last of them to wait before deciding.
local SETTLE_SECONDS = 2

local FAVOR_NAME = "merchant's favor"

--------------------------------------------------------------------------------
-- Saved data
--------------------------------------------------------------------------------

--- The account-wide store. Never rename these keys: they hold what was
--- learned in game.
--
--   crateIDs[crateKey] = itemID     a crate found in the game by its name
--   links[crateKey]    = sealedID   the sealed crate that kind fills into
--   rewards[sealedID]  = { favor, money, turnIns, at }
--   favorCurrency      = currencyID  Merchant's Favor, when it is a currency
--   favorItem          = itemID      Merchant's Favor, when it is an item
local function Store()
    local db = ns.db
    if not db then return nil end

    db.merchantsFavor = db.merchantsFavor or {}
    local store = db.merchantsFavor
    store.crateIDs = store.crateIDs or {}
    store.links = store.links or {}
    store.rewards = store.rewards or {}
    return store
end

--- Bumped whenever something a list shows has changed, so it rebuilds.
MerchantsFavor.version = 0

local function Changed()
    MerchantsFavor.version = MerchantsFavor.version + 1
end

local function Now()
    return GetTime and GetTime() or 0
end

--------------------------------------------------------------------------------
-- Names
--------------------------------------------------------------------------------

--- The item's name if the client has it, else asks for it and says nil.
local function ItemName(itemID)
    if not Util.HasFunction("C_Item.GetItemInfo") then return nil end

    local ok, name = pcall(C_Item.GetItemInfo, itemID)
    if ok and type(name) == "string" then return name end

    if Util.HasFunction("C_Item.RequestLoadItemDataByID") then
        pcall(C_Item.RequestLoadItemDataByID, itemID)
    end
    return nil
end

--- True when `word` stands as a whole word in `text`.
local function HasWord(text, word)
    return text:find("%f[%w]" .. word .. "%f[%W]") ~= nil
end

--- The crate a "Waylaid Crate: ..." name is, or nil.
function MerchantsFavor.CrateForName(name)
    if type(name) ~= "string" then return nil end

    local lower = name:lower()
    if not lower:find("^waylaid crate") then return nil end

    for _, crate in ipairs(ns.WAYLAID_CRATES or {}) do
        local all = true
        for _, word in ipairs(crate.words) do
            if not HasWord(lower, word) then
                all = false
                break
            end
        end
        if all then return crate end
    end
    return nil
end

--- True for a filled crate's name ("Sealed Apprentice Crate"). Players
--- call it sealed; the fill spell is "stock crate", so that word is
--- taken too.
function MerchantsFavor.IsSealedName(name)
    if type(name) ~= "string" then return false end
    local lower = name:lower()
    return (lower:find("^sealed ") ~= nil or lower:find("^stocked ") ~= nil) and HasWord(lower, "crate")
end

function MerchantsFavor.IsFavorName(name)
    return type(name) == "string" and name:lower() == FAVOR_NAME
end

-- itemID -> { kind = "crate" | "sealed" | "favor", crate } or false, once
-- its name is known.
local kinds = {}

--- What an item is to this module, from its name: a Waylaid Crate (and
--- which), a sealed crate, Merchant's Favor, or nil.
function MerchantsFavor:Classify(itemID)
    local known = kinds[itemID]
    if known ~= nil then return known or nil end

    local name = ItemName(itemID)
    if not name then return nil end

    -- A secret value in an instance raises when read; it is no crate.
    local ok, kind = pcall(function()
        local crate = MerchantsFavor.CrateForName(name)
        if crate then return { kind = "crate", crate = crate } end
        if MerchantsFavor.IsSealedName(name) then return { kind = "sealed" } end
        if MerchantsFavor.IsFavorName(name) then return { kind = "favor" } end
        return false
    end)
    if not ok then kind = false end

    kinds[itemID] = kind
    if kind and kind.kind == "crate" then self:NoteCrateID(kind.crate, itemID) end
    return kind or nil
end

--- Keep the item ID the game gave a crate. The game's beats the typed one.
function MerchantsFavor:NoteCrateID(crate, itemID)
    local store = Store()
    if not store or store.crateIDs[crate.key] == itemID then return end
    store.crateIDs[crate.key] = itemID
    Changed()
end

function MerchantsFavor:GetCrateID(crate)
    local store = Store()
    return (store and store.crateIDs[crate.key]) or crate.id
end

--- Look through the item IDs where Forever's new items sit for crates not
--- found yet. Once a session; names the client does not have yet are asked
--- for and read as they arrive (OnItemInfo).
function MerchantsFavor:FindCrates()
    if self.searched then return end
    self.searched = true

    local range = ns.WAYLAID_CRATE_ID_RANGE
    if not range then return end

    for itemID = range[1], range[2] do self:Classify(itemID) end
end

function MerchantsFavor:OnItemInfo(itemID)
    local range = ns.WAYLAID_CRATE_ID_RANGE
    if not self.searched or not range or type(itemID) ~= "number" then return end
    if itemID < range[1] or itemID > range[2] or kinds[itemID] ~= nil then return end
    self:Classify(itemID)
end

--------------------------------------------------------------------------------
-- Rewards
--------------------------------------------------------------------------------

--- What handing in this crate pays.
--
-- @return favor, money (copper), source, turnIns
--   source is "learned" (seen paid, turnIns times), "reported" (what players
--   say, not seen here yet) or nil when nobody knows (Artisan crates).
function MerchantsFavor:GetReward(crate)
    local store = Store()
    local sealed = store and store.links[crate.key]
    local learned = sealed and store.rewards[sealed]

    if learned and learned.favor then
        return learned.favor, learned.money or 0, "learned", learned.turnIns or 1
    end

    if crate.favor then return crate.favor, crate.silver or 0, "reported" end
    return nil, nil, nil
end

--- Keep one turn-in's reward.
--
-- The smallest favor seen is the crate's: the Performance Bonus perk now and
-- then doubles a turn-in, and the first crate a character hands in is said
-- to bring a one-off bonus too.
function MerchantsFavor:Learn(sealedID, favor, money)
    local store = Store()
    if not store or not sealedID or not favor or favor <= 0 then return end

    local reward = store.rewards[sealedID] or {}
    store.rewards[sealedID] = reward

    reward.turnIns = (reward.turnIns or 0) + 1
    if not reward.favor or favor < reward.favor then
        reward.favor = favor
        reward.money = money or 0
    end
    reward.at = time()
    Changed()
end

-- What has come in and gone out lately, waiting to be put together.
local recent = {}

--- Put a turn-in together with the favor and money that came with it.
function MerchantsFavor:Resolve()
    local now = Now()
    local turnIn, favor, money = recent.turnIn, recent.favor, recent.money

    if turnIn and favor and math.abs(favor.at - turnIn.at) <= MATCH_SECONDS then
        local paid = (money and math.abs(money.at - turnIn.at) <= MATCH_SECONDS) and money.amount or 0
        self:Learn(turnIn.id, favor.amount, paid)
        recent = {}
        return
    end

    -- A sealed crate sold or thrown away, or favor from something else.
    for key, event in pairs(recent) do
        if now - event.at > MATCH_SECONDS * 2 then recent[key] = nil end
    end
end

local function Settle()
    if C_Timer and C_Timer.After then
        C_Timer.After(SETTLE_SECONDS, function() MerchantsFavor:Resolve() end)
    else
        MerchantsFavor:Resolve()
    end
end

function MerchantsFavor:NoteFavor(amount)
    if type(amount) ~= "number" or amount <= 0 then return end
    recent.favor = { amount = amount, at = Now() }
    Settle()
end

function MerchantsFavor:NoteMoney(amount)
    if type(amount) ~= "number" or amount <= 0 then return end
    recent.money = { amount = amount, at = Now() }
    if recent.turnIn or recent.favor then Settle() end
end

function MerchantsFavor:NoteTurnIn(sealedID)
    recent.turnIn = { id = sealedID, at = Now() }
    Settle()
end

--- Compare the crates and favor in the bags with the last look.
function MerchantsFavor:OnBags()
    local counts = ns.Inventory and ns.Inventory:GetBagCounts() or {}

    local held = {}
    for itemID, count in pairs(counts) do
        if self:Classify(itemID) then held[itemID] = count end
    end

    local before = self.held
    self.held = held
    if not before then return end

    local seen, emptied, filled, handed = {}, nil, nil, nil
    local function Look(itemID)
        if seen[itemID] then return end
        seen[itemID] = true

        local change = (held[itemID] or 0) - (before[itemID] or 0)
        if change == 0 then return end

        local kind = self:Classify(itemID)
        if kind.kind == "crate" and change < 0 then
            emptied = kind.crate
        elseif kind.kind == "sealed" and change > 0 then
            filled = itemID
        elseif kind.kind == "sealed" and change < 0 then
            handed = itemID
        elseif kind.kind == "favor" then
            self:NoteFavorItem(itemID)
            if change > 0 then self:NoteFavor(change) end
        end
    end
    for itemID in pairs(held) do Look(itemID) end
    for itemID in pairs(before) do Look(itemID) end

    local store = Store()
    if emptied and filled and store and store.links[emptied.key] ~= filled then
        store.links[emptied.key] = filled
        Changed()
    end

    if handed then self:NoteTurnIn(handed) end
end

function MerchantsFavor:OnCurrency(currencyID, _, change)
    if not currencyID or not Util.HasFunction("C_CurrencyInfo.GetCurrencyInfo") then return end

    self.currencyNames = self.currencyNames or {}
    local name = self.currencyNames[currencyID]
    if name == nil then
        local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)
        name = ok and type(info) == "table" and info.name or false
        self.currencyNames[currencyID] = name
    end

    if MerchantsFavor.IsFavorName(name or nil) then
        local store = Store()
        if store and store.favorCurrency ~= currencyID then store.favorCurrency = currencyID end
        self:NoteFavor(change)
        self:CheckGoal()
    end
end

function MerchantsFavor:OnMoney()
    if type(GetMoney) ~= "function" then return end
    local money = GetMoney()
    if self.money and money > self.money then self:NoteMoney(money - self.money) end
    self.money = money
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

--- What one of an item costs to buy for a bundle: the reagent price the
--- rest of the addon uses (a vendor's price where one sells it, else the
--- cheapest listing), and "vendor" when a shop sets it.
--
-- A shop seen with limited stock sells a few at a time, never a bundle's
-- twenty, so here it gives way to the auction house whenever there is a
-- listing. A bundle of 20 Heavy Leather read 20s, 1s each, against 10s 58c
-- on the auction house (2026-10-09); a shop is the likeliest source, and
-- the panel now marks a bundle a vendor priced, so it shows if not.
local function UnitCost(itemID)
    if not (ns.Cost and ns.Cost.GetReagentUnitCost) then
        return ns.Prices and ns.Prices:GetValue(itemID, "lowest"), nil
    end

    local cost, source = ns.Cost:GetReagentUnitCost(itemID)
    if source == "vendor" and ns.Vendor and ns.Vendor.IsLimited and ns.Vendor:IsLimited(itemID) then
        local auction = ns.Prices and ns.Prices:GetValue(itemID, "lowest")
        if auction then return auction, nil end
    end
    return cost, source == "vendor" and "vendor" or nil
end

--- What one of an item costs made from bought materials, and the recipe,
--- when one of the player's characters knows a craft for it.
function MerchantsFavor.MakeCost(itemID)
    local cost = ns.Cost
    if not (itemID and cost and cost.FindAnyRecipeForItem and cost.GetMaterialValue) then return nil end
    local recipeID = cost:FindAnyRecipeForItem(itemID)
    if not recipeID then return nil end
    local perUnit = cost:GetMaterialValue(recipeID)
    if not perUnit then return nil end
    return perUnit, recipeID
end

--- How many crafts make `items` of a recipe's item, and what they use:
--- crafts, { { itemID, count } }. A recipe making two a craft needs half
--- the crafts; one the addon has not read gives nil.
function MerchantsFavor.CraftPlan(recipeID, items)
    local recipe = recipeID and ns.Recipes and ns.Recipes.GetAny and ns.Recipes:GetAny(recipeID)
    if type(recipe) ~= "table" then return nil end

    local yield = ((recipe.quantityMin or 1) + (recipe.quantityMax or 1)) / 2
    if yield <= 0 then yield = 1 end
    local crafts = math.max(1, math.ceil((items or 1) / yield))

    local reagents = {}
    for _, reagent in ipairs(recipe.reagents or {}) do
        if reagent.itemID and reagent.quantity then
            reagents[#reagents + 1] = { itemID = reagent.itemID, count = reagent.quantity * crafts }
        end
    end
    return crafts, reagents
end

--- How many of an item this character has, in its bags, bank and mail.
function MerchantsFavor.Owned(itemID)
    local inventory = ns.Inventory
    if not (itemID and inventory) then return 0 end
    if inventory.GetOwnedCount then return inventory:GetOwnedCount(itemID) or 0 end
    return inventory.GetBagCount and inventory:GetBagCount(itemID) or 0
end

--- Every crate, with what it costs to buy and fill and what a favor costs.
--
-- A bundle needing more than one stack of its material is marked overStack:
-- the game cannot fill a crate from more than one stack (a known Forever
-- issue, 2026-09-18), so with opts.skipOverStack it is never the cheapest.
--
-- @param opts { skipOverStack }
-- @return rows, cheapest favor first; crates nobody knows the reward for,
--   or that are not priced, come last
function MerchantsFavor:GetRows(opts)
    opts = opts or {}
    local rows = {}

    for _, crate in ipairs(ns.WAYLAID_CRATES or {}) do
        local itemID = self:GetCrateID(crate)
        -- Only what is listed now: with none on the auction house there is
        -- no crate to buy, so no price and no total (Prices:ListedNow).
        local cratePrice, noneListed
        if itemID and ns.Prices then cratePrice, noneListed = ns.Prices:ListedNow(itemID) end
        -- How many are listed at that price, and in all.
        local onAHAtPrice, onAHTotal
        if itemID and ns.Prices and ns.Prices.ListedCounts then
            onAHAtPrice, onAHTotal = ns.Prices:ListedCounts(itemID, cratePrice)
        end

        local bundles, best = {}, nil
        for _, bundle in ipairs(crate.bundles) do
            local materialID, count = bundle[1], bundle[2]
            local unit, from = UnitCost(materialID)
            local stack = Util.GetMaxStackSize(materialID)

            local entry = {
                itemID = materialID,
                count = count,
                unit = unit,
                cost = unit and unit * count or nil,
                vendor = from == "vendor",
                overStack = (stack ~= nil and count > stack) or false,
            }
            entry.buy = entry.cost

            -- Made from bought materials, when that is cheaper (a player
            -- asked, 2026-10-18): only for a craft one of the player's
            -- characters knows.
            local make, recipeID = MerchantsFavor.MakeCost(materialID)
            if make then
                entry.make = make * count
                entry.recipeID = recipeID
                if not entry.cost or entry.make < entry.cost then
                    entry.unit, entry.cost, entry.made, entry.vendor = make, entry.make, true, false
                end
            end
            bundles[#bundles + 1] = entry

            local usable = not (entry.overStack and opts.skipOverStack)
            if entry.cost and usable and (not best or entry.cost < best.cost) then best = entry end
        end
        if best then best.best = true end

        local favor, money, source, turnIns = self:GetReward(crate)

        local total
        if cratePrice and best then total = cratePrice + best.cost - (money or 0) end

        local perFavor
        if total and favor and favor > 0 then perFavor = total / favor end

        rows[#rows + 1] = {
            key = crate.key,
            crate = crate,
            itemID = itemID,
            name = crate.label,
            tier = crate.tier,
            cratePrice = cratePrice,
            noneListed = noneListed or nil,
            bundles = bundles,
            best = best,
            bundleCost = best and best.cost,
            favor = favor,
            money = money,
            source = source,
            turnIns = turnIns,
            total = total,
            perFavor = perFavor,
            have = MerchantsFavor.Owned(itemID),
            onAHAtPrice = onAHAtPrice,
            onAHTotal = onAHTotal,
        }
    end

    table.sort(rows, function(a, b)
        if (a.perFavor ~= nil) ~= (b.perFavor ~= nil) then return a.perFavor ~= nil end
        if a.perFavor and a.perFavor ~= b.perFavor then return a.perFavor < b.perFavor end
        if a.tier ~= b.tier then return a.tier < b.tier end
        return a.name < b.name
    end)

    return rows
end

--- The row for a Waylaid Crate item, for its tooltip, or nil for anything
--- else. The rows are laid out once and kept until something moves or a
--- few seconds pass, since a tooltip is drawn again and again.
local ROW_KEEP = 5
function MerchantsFavor:RowForItem(itemID)
    if type(itemID) ~= "number" then return nil end
    local kind = self:Classify(itemID)
    if not (kind and kind.kind == "crate") then return nil end

    local now = Now()
    local kept = self.tipRows
    if not kept or kept.version ~= MerchantsFavor.version or now - kept.at > ROW_KEEP then
        local rows = self:GetRows({ skipOverStack = ns.Config and ns.Config:Get("favorSkipOverStack") ~= false })
        kept = { version = MerchantsFavor.version, at = now, byKey = {} }
        for _, row in ipairs(rows) do kept.byKey[row.key] = row end
        self.tipRows = kept
    end
    return kept.byKey[kind.crate.key]
end

--------------------------------------------------------------------------------
-- The favor goal (the owner said build it, 2026-10-20, from a mockup)
--------------------------------------------------------------------------------

--- Keep the item ID Merchant's Favor has, when it is an item.
function MerchantsFavor:NoteFavorItem(itemID)
    local store = Store()
    if store and store.favorItem ~= itemID then store.favorItem = itemID end
end

--- The favor goal typed on the Favors and Writs tab, or nil when none.
function MerchantsFavor.Goal()
    local goal = ns.Config and tonumber(ns.Config:Get("favorGoal"))
    if goal and goal > 0 then return math.floor(goal) end
    return nil
end

--- Set the goal; nil or 0 clears it.
function MerchantsFavor:SetGoal(goal)
    goal = tonumber(goal)
    if goal and goal > 0 then goal = math.floor(goal) else goal = nil end
    if ns.Config then ns.Config:Set("favorGoal", goal) end
    self.goalTenth, self.goalFor = nil, nil
    self:CheckGoal()
    Changed()
end

--- A currency's amount from the currency list, by name: Merchant's Favor
--- before its ID is known.
local function CurrencyByName()
    if not (Util.HasFunction("C_CurrencyInfo.GetCurrencyListSize")
        and Util.HasFunction("C_CurrencyInfo.GetCurrencyListInfo")) then return nil end
    local ok, size = pcall(C_CurrencyInfo.GetCurrencyListSize)
    if not ok or type(size) ~= "number" then return nil end
    for index = 1, math.min(size, 200) do
        local got, info = pcall(C_CurrencyInfo.GetCurrencyListInfo, index)
        if got and type(info) == "table" and not info.isHeader
            and MerchantsFavor.IsFavorName(info.name) and type(info.quantity) == "number" then
            return info.quantity
        end
    end
    return nil
end

--- How much Merchant's Favor the character playing has, or nil when the
--- game has not said yet.
function MerchantsFavor:FavorHave()
    local store = Store()
    if store and store.favorCurrency and Util.HasFunction("C_CurrencyInfo.GetCurrencyInfo") then
        local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, store.favorCurrency)
        if ok and type(info) == "table" and type(info.quantity) == "number" then return info.quantity end
    end
    if store and store.favorItem then return MerchantsFavor.Owned(store.favorItem) end
    return CurrencyByName()
end

--- What it takes to reach the goal by the cheapest crate.
--
-- Favor comes only when a crate is handed in, so what was bought toward the
-- goal is counted by the crates and bundle materials held: each crate the
-- plan needs is one Waylaid Crate and one bundle, and those already owned
-- (bags and bank) come off the gold.
--
-- @param goal favor wanted, nil for the saved goal
-- @param rows GetRows' answer, nil to read them
-- @return nil without a goal, else { goal, have, need, best (the row),
--   crates, cratesHave, bundlesHave, materialHave, gold, reached }
function MerchantsFavor:GetPlan(goal, rows)
    goal = tonumber(goal) or MerchantsFavor.Goal()
    if not goal or goal <= 0 then return nil end

    local have = self:FavorHave()
    local plan = { goal = goal, have = have, need = math.max(0, goal - (have or 0)) }
    plan.reached = have ~= nil and have >= goal
    if plan.need <= 0 then return plan end

    rows = rows or self:GetRows({ skipOverStack = ns.Config and ns.Config:Get("favorSkipOverStack") ~= false })
    for _, row in ipairs(rows) do
        if row.perFavor and row.favor and row.favor > 0 and row.best then
            plan.best = row
            break
        end
    end
    local best = plan.best
    if not best then return plan end

    local bundle = best.best
    plan.crates = math.ceil(plan.need / best.favor)
    plan.cratesHave = math.min(plan.crates, best.have or 0)
    plan.materialHave = MerchantsFavor.Owned(bundle.itemID)
    plan.bundlesHave = math.min(plan.crates, math.floor(plan.materialHave / math.max(1, bundle.count)))
    local gold = (plan.crates - plan.cratesHave) * (best.cratePrice or 0)
        + (plan.crates - plan.bundlesHave) * (bundle.cost or 0)
        - plan.crates * (best.money or 0)
    plan.gold = math.max(0, gold)
    return plan
end

--- One auction house buy a listing at a time: a crate, then a bundle's
--- material, for every crate the plan needs. A step is done once the bags
--- and bank hold it.
-- @return steps { { itemID, count, price, done, crate } }, how many left
function MerchantsFavor.Steps(plan)
    local steps, left = {}, 0
    local best = plan and plan.best
    if not (best and plan.crates and best.itemID) then return steps, 0 end

    local bundle = best.best
    local buyEach = bundle.buy or bundle.cost
    for i = 1, plan.crates do
        local crateDone = (best.have or 0) >= i
        steps[#steps + 1] = { itemID = best.itemID, count = 1, price = best.cratePrice, done = crateDone, crate = true }
        local bundleDone = (plan.materialHave or 0) >= i * bundle.count
        steps[#steps + 1] = { itemID = bundle.itemID, count = bundle.count, price = buyEach, done = bundleDone }
        if not crateDone then left = left + 1 end
        if not bundleDone then left = left + 1 end
    end
    return steps, left
end

-- The game's own sounds, by id: coins for a tenth, the achievement toast
-- for the goal (Goblin Gold's).
MerchantsFavor.SOUNDS = {
    tenth = { 120, 878 },
    goal = { 12891, 888 },
}

local function Play(which)
    if type(PlaySound) ~= "function" then return end
    for _, id in ipairs(MerchantsFavor.SOUNDS[which] or {}) do
        local ok, willPlay = pcall(ns.PlaySound or PlaySound, id, "Master")
        if ok and willPlay then return end
    end
end

--- Chime each tenth of the goal reached, and cheer the goal. The first look
--- this session (or after the goal changes) only notes where it stands, so
--- a login or a dip and climb back plays nothing.
-- @return "tenth", "goal" or nil
function MerchantsFavor:CheckGoal()
    local goal = MerchantsFavor.Goal()
    local have = goal and self:FavorHave()
    if not (goal and have) then return nil end

    local tenth = math.min(10, math.floor(have * 10 / goal))
    if self.goalFor ~= goal or not self.goalTenth then
        self.goalFor, self.goalTenth = goal, tenth
        return nil
    end
    if tenth <= self.goalTenth then return nil end
    self.goalTenth = tenth
    Changed()

    if tenth >= 10 then
        Play("goal")
        ns.Print(L["Favor goal reached!"])
        return "goal"
    end
    Play("tenth")
    return "tenth"
end

--- Make (or fill) a shopping list named Merchant's Favor with what the goal
--- still needs to buy: the crates and the bundles' material.
-- @return the list's index, or nil and why
function MerchantsFavor:AddToList(plan)
    local lists = ns.ShoppingLists
    if not (lists and lists.All and lists.Make and lists.Add) then return nil, L["Shopping lists aren't ready yet."] end
    plan = plan or self:GetPlan()
    local best = plan and plan.best
    if not (best and plan.crates and best.itemID) then return nil, L["There's nothing to buy for your goal yet."] end

    local name = L["Merchant's Favor"]
    local index
    for i, list in ipairs(lists:All() or {}) do
        if list.name == name then index = i break end
    end
    if not index then index = lists:Make(name) end
    if not index then return nil, L["Shopping lists aren't ready yet."] end

    -- Set to what the goal needs, so a second click never doubles it.
    local function Put(itemID, want)
        if not (lists.SetWant and lists:SetWant(index, itemID, want)) then lists:Add(index, itemID, want) end
    end
    Put(best.itemID, plan.crates)
    Put(best.best.itemID, plan.crates * best.best.count)
    return index
end

--------------------------------------------------------------------------------
-- Search Both and Queue Craft (the Deals tab's two views)
--------------------------------------------------------------------------------

--- An item's name as the client gives it, or nil.
function MerchantsFavor.NameOf(itemID)
    return itemID and ItemName(itemID) or nil
end

--- The names of a list of { itemID } joined for a chat line or hover.
function MerchantsFavor.NamesOf(items)
    local names = {}
    for _, item in ipairs(items or {}) do
        local name = ItemName(item.itemID)
        if name then names[#names + 1] = name end
    end
    return table.concat(names, ", ")
end

--- Look up a crate or writ and what goes with it in one search, each with
--- how many: picking one in the results fills the buy box with that many
--- (UI/BuyQuantity.lua). Where the game takes one item a search, the first
--- goes alone. Never buys.
-- @param items { { itemID, count } }, the crate or writ first
-- @param firstName, secondName for the chat line
-- @return true when a search was sent
function MerchantsFavor:SearchBoth(items, firstName, secondName)
    local ids, counts = {}, {}
    for _, item in ipairs(items or {}) do
        local itemID = tonumber(item.itemID)
        if itemID then
            if not counts[itemID] then ids[#ids + 1] = itemID end
            counts[itemID] = (counts[itemID] or 0) + math.max(1, math.floor(tonumber(item.count) or 1))
        end
    end
    if #ids == 0 then return false end

    local lists = ns.ShoppingLists
    if #ids > 1 and lists and lists.SearchMany then
        local sent, why = lists:SearchMany(ids, counts)
        if sent then
            ns.Print(L.Format("Searching the auction house for %s and %s.", firstName or "?", secondName or "?"))
            return true
        end
        if why ~= "single" then
            ns.Print(why)
            return false
        end
    end
    return ns.UI and ns.UI.SearchAuctionHouse and ns.UI:SearchAuctionHouse(ids[1], counts[ids[1]]) or false
end

--- Queue enough crafts of a recipe to make `items` of its item, and say so.
-- @return true when the queue took it
function MerchantsFavor:QueueCraft(recipeID, items, name)
    local crafts = MerchantsFavor.CraftPlan(recipeID, items)
    if not (crafts and ns.Queue and ns.Queue.Ensure) then return false end

    -- Each click adds to what is queued already, as the chat line says.
    local existing
    if ns.Queue.Find then existing = select(2, ns.Queue:Find(recipeID, true)) end
    local want = crafts + (existing and existing.quantity or 0)
    local ok, why = ns.Queue:Ensure(recipeID, want)
    if not ok then
        if why then ns.Print(why) end
        return false
    end
    ns.Print(L.Format("Added %d %s to your craft queue.", items, name or "?"))
    return true
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

--- Run an event's work, quietly: an instance hands out secret values that
--- raise when compared, and a crate count is never worth an error box.
local function Quietly(fn)
    return function(_, _, ...)
        pcall(fn, MerchantsFavor, ...)
    end
end

function MerchantsFavor:OnEnable()
    self:OnMoney()
    self:OnBags()

    ns.RegisterEvent(self, "BAG_UPDATE_DELAYED", Quietly(function(module)
        module:OnBags()
        module:CheckGoal()
    end))
    ns.RegisterEvent(self, "PLAYER_MONEY", Quietly(self.OnMoney))
    ns.RegisterEvent(self, "CURRENCY_DISPLAY_UPDATE", Quietly(self.OnCurrency))
    ns.RegisterEvent(self, "GET_ITEM_INFO_RECEIVED", Quietly(self.OnItemInfo))
end
