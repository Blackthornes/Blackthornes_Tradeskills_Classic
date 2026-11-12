-- Blackthornes Tradeskills -- Logic/HourPlans.lua
-- Gold an hour, buying the parts or making them.
--
-- A Discord player asked (2026-11-12, the owner said build it, casting time
-- only): for a craft whose parts can be bought or made (Coarse Dynamite from
-- bought Coarse Blasting Powder, or from Coarse Stone made into it), which
-- earns more an hour. Making a part usually earns more each time, but takes
-- longer, so buying it can earn more an hour.
--
-- Two plans, and the best of every mix between them:
--   buy   buy every material, make only the final item
--   make  make each part this character (or an alt, while alts make
--         sub-crafts) can make, at the costing's price for it
-- With up to MAX_CHOICES parts that can be both bought and made, each one is
-- tried made and bought (2^n mixes); past that, only all made or all bought.
--
-- Profit follows the Profit: choice (Logic/Profit.lua's analysis.profit, the
-- sale price picked by profitBy), changed only by what the parts cost. Time
-- is casting only (the owner, 2026-11-12: "cast time only"): the final cast,
-- each part's casts, and a disenchant cast an item when sold that way.
-- Clicking, buying and selling are not counted. Nothing is saved.
--
-- Off unless "Gold an Hour:" is ticked (profitGoldAnHour); Profit:Analyse
-- asks only then, as analysis.hourPlans.

local _, ns = ...

local HourPlans = ns.NewModule("HourPlans")

HourPlans.MAX_CHOICES = 6

--- Whether "Gold an Hour:" is ticked.
function HourPlans:IsOn()
    return ns.Config ~= nil and ns.Config:Get("profitGoldAnHour") == true
end

--- How many of a reagent line still have to be bought or made, after what
--- the cash-out-of-pocket view counts as free (the same rule as
--- Cost:GetCraftCost).
local function Need(entry)
    local quantity = entry.quantity or 0
    if entry.source == "owned" then return 0 end
    local valueOwned = ns.Config:Get("valueOwnedMaterials")
    local free = (not valueOwned) and math.min(quantity, entry.inBags or 0) or 0
    return math.max(0, quantity - free)
end

--- Buying `need` of an item: copper, or nil when nobody sells it.
local function BuyOption(itemID, need)
    local unit, source = ns.Cost:GetReagentUnitCost(itemID)
    if not unit then return nil end
    local cost = ns.Cost:CostOfMany(itemID, need, unit, source)
    if not cost then return nil end
    return { cost = cost, seconds = 0, source = source }
end

--- Making `need` of an item: { cost, seconds, recipeID }, or nil when no
--- character can make it. seconds is nil when a cast in it is unknown.
local function MakeOption(entry, need)
    local itemID = entry.itemID
    local sub, unit = entry.crafted and entry.subCost, nil
    if sub then
        unit = entry.unitCost
    else
        -- Not over a price the player set for it, as the costing does.
        if entry.source == "mine" then return nil end
        local subRecipeID = ns.Cost:FindRecipeForItem(itemID)
        if not subRecipeID then subRecipeID = ns.Cost:AltRecipeFor(itemID) end
        if not subRecipeID then return nil end
        sub = ns.Cost:GetCraftCost(subRecipeID, 1)
        if not (sub and sub.priceable and sub.perUnit) then return nil end
        unit = sub.perUnit
    end
    if not (sub and sub.recipeID and unit) then return nil end

    local yield = (sub.yield and sub.yield > 0) and sub.yield or 1
    local time = ns.CraftTime:ForCost(sub.recipeID, sub)
    local seconds = time.seconds and (time.seconds * need / yield) or nil
    return { cost = unit * need, seconds = seconds, recipeID = sub.recipeID }
end

--- Works out the plans for one analysis (Profit:Analyse's, with `cost` its
--- costing). nil when the final cast's time is unknown, or nothing can be
--- weighed.
-- @return {
--   buy  = plan or nil (nil when a part can't be bought),
--   make = plan or nil (nil when no part can be made, or the same as buy),
--   best = the plan earning most an hour,
--   parts = { { itemID, need, canBuy, canMake } },
-- } where a plan is { kind ("buy", "make" or "mix"), profit, seconds,
--   perHour, made = { [itemID] = true } }; seconds and perHour are nil
--   when a part's cast is unknown
function HourPlans:For(recipeID, analysis)
    if not (analysis and analysis.cost and analysis.cost.total and analysis.profit) then return nil end
    local cost = analysis.cost

    local cast = ns.CraftTime:GetCast(recipeID)
    if not cast then return nil end
    local yield = (cost.yield and cost.yield > 0) and cost.yield or 1
    local base = cast
    if analysis.via == "disenchant" then
        local de = ns.CraftTime:GetCast(ns.CraftTime.DISENCHANT_SPELL)
        if not de then return nil end
        base = base + de * yield
    end

    -- What every part costs and takes either way. A part with only one way
    -- is fixed; only parts with both ways are choices.
    local fixedCost, fixedSeconds, fixedMade = 0, 0, {}
    local choices, parts = {}, {}
    local makeAny, buyAll = false, true
    for _, entry in ipairs(cost.reagents or {}) do
        local need = Need(entry)
        if need > 0 then
            local buy = BuyOption(entry.itemID, need)
            local make = MakeOption(entry, need)
            parts[#parts + 1] = { itemID = entry.itemID, need = need,
                canBuy = buy ~= nil, canMake = make ~= nil }
            if buy and make then
                choices[#choices + 1] = { itemID = entry.itemID, buy = buy, make = make }
                makeAny = true
            elseif buy then
                fixedCost = fixedCost + buy.cost
            elseif make then
                if not make.seconds then return nil end
                fixedCost = fixedCost + make.cost
                fixedSeconds = fixedSeconds + make.seconds
                fixedMade[entry.itemID] = true
                makeAny, buyAll = true, false
            else
                return nil
            end
        end
    end

    local others = analysis.profit + cost.total

    local function Plan(picks)
        local total, seconds = fixedCost, base + fixedSeconds
        local made, any = {}, next(fixedMade) ~= nil
        for itemID in pairs(fixedMade) do made[itemID] = true end
        local allMade = true
        for i, choice in ipairs(choices) do
            if picks[i] then
                total = total + choice.make.cost
                -- A part's cast never seen: the plan still has a profit, but no hour.
                seconds = (seconds and choice.make.seconds) and (seconds + choice.make.seconds) or nil
                made[choice.itemID] = true
                any = true
            else
                total = total + choice.buy.cost
                allMade = false
            end
        end
        local kind = "buy"
        if any then kind = allMade and "make" or "mix" end
        local profit = others - total
        return { kind = kind, profit = profit, seconds = seconds,
            perHour = seconds and ns.CraftTime.PerHour(profit, seconds) or nil, made = made }
    end

    local allBuy, allMake = {}, {}
    for i = 1, #choices do allMake[i] = true end

    -- Buying every part works only when every part can be bought.
    local buyPlan = buyAll and Plan(allBuy) or nil
    local makePlan = makeAny and Plan(allMake) or nil
    if buyPlan and makePlan and not next(makePlan.made) then makePlan = nil end

    local best
    local function Consider(plan)
        if plan and plan.perHour and (not best or plan.perHour > best.perHour) then best = plan end
    end
    Consider(buyPlan)
    Consider(makePlan)

    local n = #choices
    if n >= 2 and n <= self.MAX_CHOICES then
        for mask = 1, 2 ^ n - 2 do
            local picks = {}
            for i = 1, n do picks[i] = math.floor(mask / 2 ^ (i - 1)) % 2 == 1 end
            local plan = Plan(picks)
            if plan and plan.kind == "make" then plan.kind = "mix" end
            Consider(plan)
        end
    end

    if not best then return nil end
    return { buy = buyPlan, make = makePlan, best = best, parts = parts }
end
