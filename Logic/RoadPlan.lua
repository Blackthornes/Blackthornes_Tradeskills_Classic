-- Blackthornes Tradeskills -- Logic/RoadPlan.lua
-- Road to 300 (the owner said build it, 2026-10-20, from a mockup): the
-- whole way up one profession, from the skill the character has to 300,
-- laid out as steps on the Level Up tab (UI/RoadView.lua).
--
-- Each stretch of skill takes the recipe that costs least for each point it
-- gives there: a recipe the character knows, or one a trainer or vendor of
-- their side teaches (Logic/LearnNext.lua), its price counted once. Below
-- yellow every craft gives a point; from yellow to grey the chance falls
-- to nothing, (grey - skill) / (grey - yellow), so a point takes
-- 1 / chance crafts. A step is one recipe in one colour; it ends where the
-- colour changes, a trainer is due or another recipe is clearly cheaper.
--
-- Trainer steps follow Classic's ranks: Journeyman at 50 (level 10) to 150,
-- Expert at 125 (level 20) to 225, Artisan at 200 (level 35) to 300.
--
-- What the character owns (bags, then bank) is taken off the materials
-- once, step by step in order. Steps below the skill the character has are
-- shown done. Nothing is saved: the plan is kept by a key (skill, cap,
-- level, recipes, bags, scans) and worked out again only when it moves,
-- the recipes priced a few a frame.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local RoadPlan = ns.NewModule("RoadPlan")

RoadPlan.TARGET = 300

-- Classic's ranks by Classic skill line: { learn at, level, price, cap }.
-- Cooking and First Aid have only Journeyman at a trainer.
local function Ranks(journeyman, expert, artisan)
    local list = { { 50, 10, journeyman, 150 } }
    if expert then list[2] = { 125, 20, expert, 225 } end
    if artisan then list[3] = { 200, 35, artisan, 300 } end
    return list
end
RoadPlan.RANKS = {
    [171] = Ranks(450, 5000, 45000),     -- Alchemy
    [164] = Ranks(450, 4500, 50000),     -- Blacksmithing
    [333] = Ranks(500, 5000, 50000),     -- Enchanting
    [202] = Ranks(450, 4500, 45000),     -- Engineering
    [165] = Ranks(500, 5000, 50000),     -- Leatherworking
    [197] = Ranks(450, 4500, 50000),     -- Tailoring
    [185] = Ranks(500),                  -- Cooking
    [129] = Ranks(500),                  -- First Aid
}

-- Another recipe takes over a step only when it is this much cheaper a
-- point, so the road doesn't flip between two near the same.
RoadPlan.SWITCH = 0.85

-- Recipes priced a frame while the plan is worked out.
RoadPlan.BUDGET = 12

local function Classic(skillLineID)
    local book = ns.RecipeBook
    return book and book.ClassicLine and book.ClassicLine(skillLineID) or skillLineID
end

--- The chance a craft gives a point at a skill: 1 below yellow, falling to
--- 0 at grey; 0 below the skill the recipe needs.
function RoadPlan.Chance(record, skill)
    local yellow, grey = record.yellow, record.grey
    if not (yellow and grey) or skill < (record.skill or 0) or skill >= grey then return 0 end
    if skill < yellow then return 1 end
    return (grey - skill) / math.max(1, grey - yellow)
end

--- What one craft of a recipe takes and what it makes back: { cost (one
--- craft, copper), reagents = { { itemID, quantity, unit } }, sells (one
--- item made, copper, or nil) }, or nil when a material has no price.
function RoadPlan.Price(record)
    if not (ns.Cost and record and record.reagents and #record.reagents > 0) then return nil end
    local ok, detail = pcall(ns.Cost.GetCraftCost, ns.Cost, record.recipeID, nil, nil,
        { valueOwned = true, recipe = record })
    if not ok or type(detail) ~= "table" or not detail.priceable then return nil end

    local reagents, cost = {}, 0
    for _, line in ipairs(detail.reagents or {}) do
        local unit = line.unitCost or 0
        reagents[#reagents + 1] = { itemID = line.itemID, quantity = line.quantity or 1, unit = unit }
        cost = cost + unit * (line.quantity or 1)
    end

    local sells
    if ns.LevelUp and ns.LevelUp.GetReturns then
        local got, returns = pcall(ns.LevelUp.GetReturns, ns.LevelUp, record, detail)
        local yield = ((record.quantityMin or 1) + (record.quantityMax or record.quantityMin or 1)) / 2
        if got and type(returns) == "table" and (returns.best or 0) > 0 then
            sells = math.floor(returns.best / math.max(1, yield) + 0.5)
        end
    end
    return { cost = cost, reagents = reagents, sells = sells }
end

--- The recipes that could level a profession: known, or taught by a trainer
--- or vendor of the player's side. Each { record, known, place }.
function RoadPlan:Candidates(line)
    local list = {}
    local book = ns.RecipeBook
    if not book then return list end
    for _, record in pairs((book:GetAll())) do
        if Classic(record.skillLineID) == line and record.yellow and record.grey
            and record.reagents and #record.reagents > 0 then
            local known = record.starter or book:KnowsIt(record)
            local place
            if not known and (record.trainerCost or record.recipeItems) and ns.LearnNext then
                local ok, where = pcall(ns.LearnNext.Place, ns.LearnNext, record)
                place = ok and where or nil
            end
            if known or place then
                list[#list + 1] = { record = record, known = known, place = place }
            end
        end
    end
    table.sort(list, function(a, b) return a.record.recipeID < b.record.recipeID end)
    return list
end

-- What a point costs with a recipe at a skill, with its learning price
-- spread over the points it can still give.
local function PointCost(candidate, skill, learned)
    local chance = RoadPlan.Chance(candidate.record, skill)
    if chance <= 0 or not candidate.price then return nil end
    local cost = candidate.price.cost / chance
    if not candidate.known and not learned[candidate.record.recipeID] then
        local left = math.max(1, candidate.record.grey - skill)
        cost = cost + ((candidate.place and candidate.place.price) or 0) / left
    end
    return cost
end

local function Best(candidates, skill, learned)
    local best, bestCost
    for _, candidate in ipairs(candidates) do
        local cost = PointCost(candidate, skill, learned)
        if cost and (not bestCost or cost < bestCost) then best, bestCost = candidate, cost end
    end
    return best, bestCost
end

--- The road, worked out from priced candidates.
--
-- @param opts.line        the Classic skill line
-- @param opts.skill       the character's skill now
-- @param opts.max         the cap the character has trained to
-- @param opts.level       the character's level
-- @param opts.candidates  Candidates' list, each with `price` (Price's)
-- @param opts.owned       { [itemID] = { bags, bank } }, or nil to read them
-- @return { steps, current, total, saved, stuck, skill, max }
function RoadPlan:Plan(opts)
    local line, now = opts.line, opts.skill or 0
    local ranks = RoadPlan.RANKS[line] or {}
    local candidates = opts.candidates or {}
    local learned = {}
    local steps = {}
    local stuck

    -- The cap a rank set raises it to, the first rank still to train.
    local function NextRank(cap)
        for _, rank in ipairs(ranks) do
            if rank[4] > cap then return rank end
        end
    end

    -- One stretch of the road: from skill `from` up to `to`, starting at
    -- cap `cap`. done: the stretch already walked.
    local function Walk(from, to, cap, done)
        local p = from
        while p < to do
            local rank = NextRank(cap)
            if rank and p >= rank[1] and (not done or rank[4] <= (opts.max or 0)) then
                steps[#steps + 1] = {
                    kind = "trainer", rank = rank, at = rank[1], cap = rank[4],
                    level = rank[2], cost = rank[3], from = p, to = p, done = done,
                    locked = not done and (opts.level or 0) < rank[2] or nil,
                }
                cap = rank[4]
            else
                local limit = math.min(to, cap)
                if rank and p < rank[1] then limit = math.min(limit, rank[1]) end
                if p >= limit then
                    if not done then stuck = p end
                    break
                end

                local candidate = Best(candidates, p, learned)
                if not candidate then
                    if not done then stuck = p end
                    break
                end
                local record = candidate.record
                local orange = p < record.yellow
                local bandEnd = orange and record.yellow or record.grey
                limit = math.min(limit, bandEnd)

                local q, crafts = p, 0
                repeat
                    crafts = crafts + 1 / RoadPlan.Chance(record, q)
                    q = q + 1
                    local other, otherCost = Best(candidates, q, learned)
                    local mine = PointCost(candidate, q, learned)
                    local switch = other and other ~= candidate and otherCost and mine
                        and otherCost < mine * RoadPlan.SWITCH
                until q >= limit or switch

                local step = {
                    kind = "craft", record = record, recipeID = record.recipeID, name = record.name,
                    outputItemID = record.outputItemID, from = p, to = q,
                    crafts = math.max(1, math.ceil(crafts - 1e-9)),
                    orange = orange, done = done, price = candidate.price,
                    sells = candidate.price and candidate.price.sells,
                }
                if not candidate.known and not learned[record.recipeID] then
                    step.learn = candidate.place
                end
                learned[record.recipeID] = true
                steps[#steps + 1] = step
                p = q
            end
        end
        return cap
    end

    -- The road already walked, from the first point and the first cap.
    local startCap = math.min(75, opts.max or 75)
    if now > 1 then Walk(1, now, startCap, true) end
    learned = {}
    for _, candidate in ipairs(candidates) do
        if candidate.known then learned[candidate.record.recipeID] = true end
    end
    Walk(now, RoadPlan.TARGET, math.max(opts.max or 75, startCap), false)

    -- What the character owns comes off once, step by step.
    local pool = {}
    local function Owned(itemID)
        local have = pool[itemID]
        if have then return have end
        local given = opts.owned and opts.owned[itemID]
        if given then
            have = { bags = given[1] or 0, bank = given[2] or 0 }
        else
            local inv = ns.Inventory
            local okBags, bags = pcall(inv.GetBagCount, inv, itemID)
            local okBank, bank = pcall(inv.GetBankCount, inv, itemID)
            have = { bags = okBags and tonumber(bags) or 0, bank = okBank and tonumber(bank) or 0 }
        end
        pool[itemID] = have
        return have
    end

    local total, saved, current = 0, 0, nil
    for index, step in ipairs(steps) do
        if not step.done then
            current = current or index
            if step.kind == "craft" then
                step.needs = {}
                local cost = (step.learn and step.learn.price) or 0
                for _, reagent in ipairs(step.price and step.price.reagents or {}) do
                    local need = reagent.quantity * step.crafts
                    local have = Owned(reagent.itemID)
                    local fromBags = math.min(need, have.bags)
                    have.bags = have.bags - fromBags
                    local fromBank = math.min(need - fromBags, have.bank)
                    have.bank = have.bank - fromBank
                    local buy = need - fromBags - fromBank
                    step.needs[#step.needs + 1] = {
                        itemID = reagent.itemID, count = need, bags = fromBags, bank = fromBank, buy = buy,
                    }
                    cost = cost + buy * reagent.unit
                    saved = saved + (fromBags + fromBank) * reagent.unit
                end
                step.cost = cost
            end
            total = total + (step.cost or 0)
        end
    end

    return {
        steps = steps, current = current, total = total, saved = saved, stuck = stuck,
        skill = now, max = opts.max, line = line,
    }
end

--- The steps as the list shows them: the ones left first, in order, then
--- the ones done, in order (the owner asked 2026-10-20). The plan's own
--- order stays as it is, for "Step N of M", the meter and Queue All.
function RoadPlan.Shown(steps)
    local open, done = {}, {}
    for _, step in ipairs(steps or {}) do
        if step.done then done[#done + 1] = step else open[#open + 1] = step end
    end
    for _, step in ipairs(done) do open[#open + 1] = step end
    return open
end

--------------------------------------------------------------------------------
-- The character's professions, and the plan kept by key
--------------------------------------------------------------------------------

--- The crafting professions the character playing has, each { name (the
--- client's), line (Classic), skill, max }, the ones picked on the Welcome
--- card first (Logic/Welcome.lua), then by name.
function RoadPlan:Professions()
    local list, seen = {}, {}
    local recipes = ns.Recipes
    local ok, learned = pcall(function() return recipes and recipes:GetLearnedProfessions() end)
    for _, profession in ipairs(ok and type(learned) == "table" and learned or {}) do
        local line = Classic(profession.skillLineID)
        if RoadPlan.RANKS[line] and not seen[line] then
            seen[line] = true
            list[#list + 1] = {
                name = profession.name, line = line,
                skill = profession.skillLevel or 0, max = profession.maxSkillLevel or 0,
            }
        end
    end
    local order = {}
    for index, line in ipairs(ns.Welcome and ns.Welcome:Picks() or {}) do order[line] = index end
    table.sort(list, function(a, b)
        local x, y = order[a.line] or 99, order[b.line] or 99
        if x ~= y then return x < y end
        return a.name < b.name
    end)
    return list
end

function RoadPlan.Level()
    local fn = rawget(_G, "UnitLevel")
    if type(fn) ~= "function" then return 0 end
    local ok, level = pcall(function()
        local v = fn("player")
        if type(v) == "number" then return v + 0 end
    end)
    return ok and level or 0
end

local function Key(profession, level)
    local db = ns.db and ns.db.characters
    local me = ns.Config and ns.Config:GetCharacterKey()
    local record = db and me and db[me]
    return table.concat({
        profession.line, profession.skill, profession.max, level,
        tostring(record and record.recipesCachedAt or 0),
        tostring(ns.Inventory and ns.Inventory.changes or 0),
        tostring(ns.Prices and ns.Prices.scanCount or 0),
        tostring(ns.Queue and ns.Queue.version or 0),
    }, "|")
end

local kept = {}      -- [line] = { key, plan }
local job            -- the plan being worked out

--- The plan for a profession, kept until its key moves. Worked out a few
--- recipes a frame where the game runs timers; onReady is called when one
--- that was not ready is done.
-- @return the plan, or nil while it is being worked out
function RoadPlan:Get(profession, onReady)
    if not profession then return nil end
    local level = RoadPlan.Level()
    local key = Key(profession, level)
    local have = kept[profession.line]
    if have and have.key == key then return have.plan end
    if job and job.key == key then
        job.onReady = onReady or job.onReady
        return have and have.plan or nil
    end

    local candidates = self:Candidates(profession.line)
    local function Finish()
        local plan = self:Plan({
            line = profession.line, skill = profession.skill, max = profession.max,
            level = level, candidates = candidates,
        })
        kept[profession.line] = { key = key, plan = plan }
        return plan
    end

    local after = rawget(_G, "C_Timer") and C_Timer.After
    if type(after) ~= "function" then
        for _, candidate in ipairs(candidates) do candidate.price = RoadPlan.Price(candidate.record) end
        return Finish()
    end

    local this = { key = key, onReady = onReady, index = 0 }
    job = this
    local function Slice()
        if job ~= this then return end
        for _ = 1, RoadPlan.BUDGET do
            this.index = this.index + 1
            local candidate = candidates[this.index]
            if not candidate then
                job = nil
                local plan = Finish()
                if this.onReady then pcall(this.onReady, plan) end
                return
            end
            candidate.price = RoadPlan.Price(candidate.record)
        end
        after(0, Slice)
    end
    after(0, Slice)
    return have and have.plan or nil
end

--- Forget every kept plan (a test, or a price the player changed).
function RoadPlan:Forget()
    for line in pairs(kept) do kept[line] = nil end
    job = nil
end

--------------------------------------------------------------------------------
-- What the buttons do
--------------------------------------------------------------------------------

--- Queue Step: the step's crafts in the queue, or for a recipe still to
--- learn, its materials on the list to buy (as Learn next's Queue materials).
-- @return true when something went on
function RoadPlan:QueueStep(step)
    local queue = ns.Queue
    if not (step and step.kind == "craft" and queue) then return false end
    if not step.learn and queue.Ensure then
        local ok, done = pcall(queue.Ensure, queue, step.recipeID, step.crafts)
        return ok and done and true or false
    end
    if not queue.EnsureBuy then return false end
    local forRecipe = { recipeID = step.recipeID, name = step.name, crafts = step.crafts }
    local any = false
    for _, need in ipairs(step.needs or {}) do
        if need.count > 0 then
            local ok, done = pcall(queue.EnsureBuy, queue, need.itemID, need.count, nil, forRecipe)
            if ok and done then any = true end
        end
    end
    return any
end

--- Queue All: every step still to do.
-- @return how many steps went on
function RoadPlan:QueueAll(plan)
    local count = 0
    for _, step in ipairs(plan and plan.steps or {}) do
        if not step.done and step.kind == "craft" and self:QueueStep(step) then count = count + 1 end
    end
    return count
end

--- Where a step's Show the Way goes: the trainer for a trainer step, the
--- trainer or vendor that teaches a recipe still to learn.
function RoadPlan:PlaceFor(step, line)
    if not step then return nil end
    if step.kind == "trainer" then
        return ns.LearnNext and ns.LearnNext.TrainerFor and ns.LearnNext:TrainerFor(line, step.cap)
    end
    return step.learn
end

--- Show the Way: the map pin and a line in chat, as Learn Next does.
function RoadPlan:ShowTheWay(step, line, professionName)
    local place = self:PlaceFor(step, line)
    if not (place and ns.LearnNext) then return false end
    local name = step.kind == "trainer" and professionName or step.name
    return ns.LearnNext:ShowTheWay({ place = place, record = step.record, name = name or "" })
end

--------------------------------------------------------------------------------
-- The words on a step
--------------------------------------------------------------------------------

local function ItemName(itemID, fallback)
    local Util = ns.Util
    local label = Util and Util.GetItemLabel and itemID and Util.GetItemLabel(itemID)
    if type(label) == "string" and Util.Uncolored then label = Util.Uncolored(label) end
    -- "item 1234" is GetItemLabel's stand-in while the item has not loaded.
    if type(label) == "string" and label ~= "" and label ~= L.Format("item %d", itemID) then return label end
    return fallback or (itemID and L.Format("item %d", itemID)) or ""
end
RoadPlan.ItemName = ItemName

--- One material's line: "Needs 78 Copper Bar. You have 51, buy 27."
function RoadPlan.NeedText(need)
    local parts = { L.Format("Needs %d %s.", need.count, ItemName(need.itemID)) }
    if need.bags > 0 then
        if need.buy > 0 then
            parts[#parts + 1] = L.Format("You have %d, buy %d.", need.bags, need.buy)
        else
            parts[#parts + 1] = L.Format("You have %d.", need.bags)
        end
    end
    if need.bank > 0 then parts[#parts + 1] = L.Format("Your banker has %d.", need.bank) end
    if need.bags == 0 and need.buy > 0 then parts[#parts + 1] = L.Format("Buy %d.", need.buy) end
    return table.concat(parts, " ")
end

local TRAIN = {
    function(profession) return L.Format("Train Journeyman %s", profession) end,
    function(profession) return L.Format("Train Expert %s", profession) end,
    function(profession) return L.Format("Train Artisan %s", profession) end,
}

--- What a step says: { title, chip, range, lines = { ... } }.
-- @param professionName  the profession's name as the client gives it
-- @param level           the character's level
function RoadPlan.Texts(step, professionName, level, line)
    local texts = { lines = {} }
    if step.kind == "trainer" then
        local index = 1
        for i, rank in ipairs(RoadPlan.RANKS[line] or {}) do
            if rank == step.rank then index = i end
        end
        texts.title = (TRAIN[index] or TRAIN[1])(professionName)
        if step.locked then
            texts.chip = L.Format("level %d", step.level)
            texts.range = L.Format("at %d", step.at)
            texts.lines[1] = L.Format("You're level %d.", level or 0)
        else
            texts.range = L.Format("at %d, raises your cap to %d", step.at, step.cap)
            local place = not step.done and RoadPlan:PlaceFor(step, line)
            if place and place.zone then
                texts.lines[1] = L.Format("%s trainer in %s", professionName, place.zone)
            end
        end
        return texts
    end

    texts.title = L.Format("Make %d %s", step.crafts, ItemName(step.outputItemID, step.name))
    texts.range = L.Format("%d to %d", step.from, step.to)
    if step.done then return texts end
    texts.chip = step.orange and L["every craft"] or L["most crafts"]
    for _, need in ipairs(step.needs or {}) do texts.lines[#texts.lines + 1] = RoadPlan.NeedText(need) end
    if step.learn then
        if step.learn.kind == "trainer" then
            -- Where the trainer stands, as the row's Show the Way aims (the
            -- owner, 2026-10-23: a lone "Trainer" said nothing).
            local zone = step.learn.zone
            texts.lines[#texts.lines + 1] = zone
                and L.Format("Learn it from the %s trainer in %s.", professionName, zone)
                or L.Format("Learn it from the %s trainer.", professionName)
        else
            local kind, zone = ns.LearnNext.WhereText(step.learn)
            texts.lines[#texts.lines + 1] = zone and (kind .. "  " .. zone) or kind
        end
    end
    if step.sells and step.sells > 0 and ns.Util and ns.Util.FormatMoney then
        texts.lines[#texts.lines + 1] = L.Format("Sells for about %s each, so it pays some back.",
            ns.Util.FormatMoney(step.sells, { short = true }))
    end
    return texts
end
