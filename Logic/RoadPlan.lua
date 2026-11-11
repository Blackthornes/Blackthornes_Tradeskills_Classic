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
-- 1 / chance crafts. Green starts halfway from yellow to grey, as the game
-- paints it. A step is one recipe in one colour; it ends where the
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
--
-- Pick By (the owner said build it, 2026-10-27, from a mockup): "lowest"
-- ranks recipes by what their materials cost, as before; "real" takes off
-- what one craft sells back for (LevelUp:GetReturns), so a craft that pays
-- some back can win. Kept account wide in `roadPickBy` (never rename it).

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local RoadPlan = ns.NewModule("RoadPlan")

RoadPlan.TARGET = 300

-- Classic's ranks by Classic skill line: { learn at, level, price, cap }.
-- Cooking and First Aid have only Journeyman at a trainer: their Expert is
-- a book sold by a vendor and their Artisan comes from a quest chain (the
-- owner said build it, 2026-11-08). Such a rank carries `how`:
--   { kind = "book", item, sellers = { A = { name, zone, x, y }, H = ... } }
--   { kind = "quest", chain = { A = { { questID, title, giver, zone, x, y }, ... }, H = ... } }
-- The last quest's giver teaches the rank. Each book, quest and spot is in
-- the Forever client's game tables (build 70862); a spot the game saw
-- (VendorPins) wins. Artisan's price is not known, so it has none.
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
    [185] = {                            -- Cooking
        { 50, 10, 500, 150 },
        { 125, 1, 10000, 225, how = { kind = "book", item = 16072, title = "Expert Cookbook", sellers = {
            A = { "Shandrina", "Ashenvale", 49.5, 67.1 },
            H = { "Wulan", "Desolace", 26.2, 69.6 },
        } } },
        { 225, 35, nil, 300, how = { kind = "quest", chain = {
            A = { { 6612, "I Know A Guy...", "Daryl Riknussun", "Ironforge", 60.1, 36.4 },
                  { 6610, "Clamlette Surprise", "Dirge Quikcleave", "Tanaris", 52.6, 28.1 } },
            H = { { 6611, "To Gadgetzan You Go!", "Zamja", "Orgrimmar", 57.4, 53.5 },
                  { 6610, "Clamlette Surprise", "Dirge Quikcleave", "Tanaris", 52.6, 28.1 } },
        } } },
    },
    [129] = {                            -- First Aid
        { 50, 10, 500, 150 },
        { 125, 1, 10000, 225, how = { kind = "book", item = 16084, title = "Expert First Aid - Under Wraps", sellers = {
            A = { "Deneb Walker", "Arathi Highlands", 27.0, 58.8 },
            H = { "Balai Lok'Wein", "Dustwallow Marsh", 36.5, 30.4 },
        } } },
        { 225, 40, nil, 300, how = { kind = "quest", chain = {
            A = { { 6625, "Alliance Trauma", "Nissa Firestone", "Ironforge", 55.1, 58.3 },
                  { 6624, "Triage", "Doctor Gustaf VanHowzen", "Dustwallow Marsh", 67.8, 49.0 } },
            H = { { 6623, "Horde Trauma", "Arnok", "Orgrimmar", 34.2, 84.6 },
                  { 6622, "Triage", "Doctor Gregory Victor", "Arathi Highlands", 73.4, 36.9 } },
        } } },
    },
    -- Fishing (the owner said build it, 2026-11-08): Apprentice and
    -- Journeyman at a trainer, Expert from a book sold in Booty Bay (the
    -- 5th field is the town the words name), Artisan from Nat Pagle's
    -- quest. A step between them is a zone to fish, not a craft
    -- (RoadPlan.FishPlan). Book 16083 and quest 6607 are in the Forever
    -- client's game tables (build 70862); the spots are Classic's until a
    -- spot the game saw (VendorPins) takes over.
    [356] = {
        { 1, 1, 10, 75 },
        { 50, 10, 500, 150 },
        { 125, 20, 10000, 225, how = { kind = "book", item = 16083, title = "Expert Fishing - The Bass and You", sellers = {
            A = { "Old Man Heming", "Stranglethorn Vale", 27.4, 77.2, "Booty Bay" },
            H = { "Old Man Heming", "Stranglethorn Vale", 27.4, 77.2, "Booty Bay" },
        } } },
        { 225, 35, nil, 300, how = { kind = "quest", chain = {
            A = { { 6607, "Nat Pagle, Angler Extreme", "Nat Pagle", "Dustwallow Marsh", 58.4, 60.2 } },
            H = { { 6607, "Nat Pagle, Angler Extreme", "Nat Pagle", "Dustwallow Marsh", 58.4, 60.2 } },
        } } },
    },
}

-- Another recipe takes over a step only when it is this much cheaper a
-- point, so the road doesn't flip between two near the same.
RoadPlan.SWITCH = 0.85

-- By real cost a craft never counts for less than this share of what its
-- materials cost, however well it sells: the road can't bank on every one
-- selling, and a cost at or below 0 can't be ranked a point.
RoadPlan.REAL_FLOOR = 0.2

-- Recipes priced a frame while the plan is worked out.
RoadPlan.BUDGET = 12

local function Classic(skillLineID)
    local book = ns.RecipeBook
    return book and book.ClassicLine and book.ClassicLine(skillLineID) or skillLineID
end

--- Where a recipe turns green: halfway from yellow to grey, as the game
--- paints it (LearnNext.Tier gives the same).
function RoadPlan.GreenFrom(record)
    return math.floor((record.yellow + record.grey) / 2)
end

--- The colour a recipe is at a skill: "optimal" (orange), "medium"
--- (yellow), "easy" (green) or "trivial" (grey).
function RoadPlan.Tier(record, skill)
    if skill >= record.grey then return "trivial" end
    if skill < record.yellow then return "optimal" end
    if skill < RoadPlan.GreenFrom(record) then return "medium" end
    return "easy"
end

--- The chance a craft gives a point at a skill: 1 below yellow, falling to
--- 0 at grey; 0 below the skill the recipe needs.
function RoadPlan.Chance(record, skill)
    local yellow, grey = record.yellow, record.grey
    if not (yellow and grey) or skill < (record.skill or 0) or skill >= grey then return 0 end
    if skill < yellow then return 1 end
    return (grey - skill) / math.max(1, grey - yellow)
end

--- What a vendor pays for one of an item, or nil.
function RoadPlan.SellValue(itemID)
    local util = ns.Util
    if not (itemID and util and util.GetVendorSellPrice) then return nil end
    local ok, value = pcall(util.GetVendorSellPrice, itemID)
    if ok and type(value) == "number" and value > 0 then return value end
    return nil
end

--- What one craft of a recipe takes and what it makes back: { cost (one
--- craft, copper), reagents = { { itemID, quantity, unit } }, sells (one
--- item made, copper, or nil), back (one craft, copper, or nil) }, or nil
--- when a material has no price.
function RoadPlan.Price(record)
    if not (ns.Cost and record and record.reagents and #record.reagents > 0) then return nil end
    local ok, detail = pcall(ns.Cost.GetCraftCost, ns.Cost, record.recipeID, nil, nil,
        { valueOwned = true, recipe = record })
    if not ok or type(detail) ~= "table" or type(detail.reagents) ~= "table" then return nil end

    -- A material nobody lists or sells (raw meat, clams) is worth what a
    -- vendor pays for it: that is what using it costs you. Only a material
    -- with neither leaves the recipe unpriced.
    local reagents, cost = {}, 0
    for _, line in ipairs(detail.reagents) do
        local unit = line.unitCost
        if not unit then unit = RoadPlan.SellValue(line.itemID) end
        if not unit then return nil end
        reagents[#reagents + 1] = { itemID = line.itemID, quantity = line.quantity or 1, unit = unit }
        cost = cost + unit * (line.quantity or 1)
    end

    local sells, back
    if ns.LevelUp and ns.LevelUp.GetReturns then
        local got, returns = pcall(ns.LevelUp.GetReturns, ns.LevelUp, record, detail)
        local yield = ((record.quantityMin or 1) + (record.quantityMax or record.quantityMin or 1)) / 2
        if got and type(returns) == "table" and (returns.best or 0) > 0 then
            sells = math.floor(returns.best / math.max(1, yield) + 0.5)
            back = returns.best
        end
    end
    return { cost = cost, reagents = reagents, sells = sells, back = back }
end

-- The classic skill line for a profession's English name, for a line the
-- client gives that ClassicLine does not know (Cooking and First Aid have a
-- second ID on Forever too, and only the classic one is in RANKS).
local function LineByName(profession)
    local recipes = ns.Recipes
    if not (recipes and recipes.EnglishProfessionName and recipes.SKILL_LINE_PROFESSIONS) then return nil end
    local ok, english = pcall(recipes.EnglishProfessionName, profession)
    if not ok or not english then return nil end
    for line, name in pairs(recipes.SKILL_LINE_PROFESSIONS) do
        if name == english and RoadPlan.RANKS[line] then return line end
    end
end

-- The Classic line a recipe belongs to. A recipe a profession window showed
-- carries the window's skill line, which for Cooking and First Aid is a
-- second ID ClassicLine does not know, so it goes by its profession's name.
local function LineOf(record, memo)
    local line = Classic(record.skillLineID)
    if RoadPlan.RANKS[line] then return line end
    local key = tostring(record.skillLineID) .. "|" .. tostring(record.profession)
    local found = memo[key]
    if found == nil then
        found = LineByName({ skillLineID = record.skillLineID, name = record.profession }) or false
        memo[key] = found
    end
    return found or line
end

--- The recipes that could level a profession: known, or taught by a trainer
--- or vendor of the player's side. Each { record, known, place }.
function RoadPlan:Candidates(line)
    local list = {}
    local book = ns.RecipeBook
    if not book then return list end
    local all = book:GetAll()
    -- A recipe Forever remade under the same name (Basic Campfire, grey at
    -- 5 on Forever) takes the place of the Classic one, whose colours are
    -- no longer the game's.
    local memo, remade = {}, {}
    for _, record in pairs(all) do
        if record.forever and record.name and LineOf(record, memo) == line then
            remade[record.name:lower()] = true
        end
    end
    for _, record in pairs(all) do
        if LineOf(record, memo) == line and record.yellow and record.grey
            and record.reagents and #record.reagents > 0
            and not (not record.forever and record.name and remade[record.name:lower()]) then
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

--- How the road picks its recipes: "lowest" (what the materials cost) or
--- "real" (less what one craft sells back for).
function RoadPlan.PickBy()
    local ok, value = pcall(function() return ns.Config and ns.Config:Get("roadPickBy") end)
    return (ok and value == "real") and "real" or "lowest"
end

-- What a point costs with a recipe at a skill, with its learning price
-- spread over the points it can still give.
local function PointCost(candidate, skill, learned, real)
    local chance = RoadPlan.Chance(candidate.record, skill)
    if chance <= 0 or not candidate.price then return nil end
    local craft = candidate.price.cost
    if real then
        -- Never below a share of the materials: a craft that sells for more
        -- than it costs would otherwise have a cost below 0, which looks
        -- cheaper a point the lower its chance falls, and the road stayed
        -- on it all the way to grey (144 yellow crafts for 20 points).
        craft = math.max(craft - (candidate.price.back or 0), craft * RoadPlan.REAL_FLOOR)
    end
    local cost = craft / chance
    if not candidate.known and not learned[candidate.record.recipeID] then
        local left = math.max(1, candidate.record.grey - skill)
        cost = cost + ((candidate.place and candidate.place.price) or 0) / left
    end
    return cost
end

local function Best(candidates, skill, learned, real)
    local best, bestCost
    for _, candidate in ipairs(candidates) do
        local cost = PointCost(candidate, skill, learned, real)
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
-- @param opts.owned       { [itemID] = { bags, bank, alts } }, or nil to read them
-- @param opts.pickBy      "lowest" (the default) or "real"
-- @return { steps, current, total, saved, back, stuck, skill, max, pickBy }
function RoadPlan:Plan(opts)
    if opts.line == RoadPlan.FISHING then return RoadPlan.FishPlan(opts) end
    local line, now = opts.line, opts.skill or 0
    local ranks = RoadPlan.RANKS[line] or {}
    local candidates = opts.candidates or {}
    local real = opts.pickBy == "real"
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
                    level = rank[2], cost = rank[3], how = rank.how, from = p, to = p, done = done,
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

                local candidate = Best(candidates, p, learned, real)
                if not candidate then
                    if not done then stuck = p end
                    break
                end
                local record = candidate.record
                -- The colour the game paints it at this skill: orange to
                -- yellow, yellow to halfway to grey, then green to grey.
                local tier = RoadPlan.Tier(record, p)
                local orange = tier == "optimal"
                local bandEnd = orange and record.yellow
                    or tier == "medium" and RoadPlan.GreenFrom(record)
                    or record.grey
                limit = math.min(limit, bandEnd)

                local q, crafts = p, 0
                repeat
                    crafts = crafts + 1 / RoadPlan.Chance(record, q)
                    q = q + 1
                    local other, otherCost = Best(candidates, q, learned, real)
                    local mine = PointCost(candidate, q, learned, real)
                    local switch = other and other ~= candidate and otherCost and mine
                        and otherCost < mine * RoadPlan.SWITCH
                until q >= limit or switch

                local step = {
                    kind = "craft", record = record, recipeID = record.recipeID, name = record.name,
                    outputItemID = record.outputItemID, from = p, to = q,
                    crafts = math.max(1, math.ceil(crafts - 1e-9)),
                    orange = orange, tier = tier, done = done, price = candidate.price,
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

    -- What the character owns comes off once, step by step: bags, bank,
    -- then what the other characters it can mail hold.
    local pool = {}
    local function Owned(itemID)
        local have = pool[itemID]
        if have then return have end
        local given = opts.owned and opts.owned[itemID]
        if given then
            have = { bags = given[1] or 0, bank = given[2] or 0, alts = given[3] or 0 }
        else
            local inv = ns.Inventory
            local okBags, bags = pcall(inv.GetBagCount, inv, itemID)
            local okBank, bank = pcall(inv.GetBankCount, inv, itemID)
            have = { bags = okBags and tonumber(bags) or 0, bank = okBank and tonumber(bank) or 0,
                alts = RoadPlan.AltsHold(itemID) }
        end
        pool[itemID] = have
        return have
    end

    local total, saved, back, current = 0, 0, 0, nil
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
                    local fromAlts = math.min(need - fromBags - fromBank, have.alts or 0)
                    have.alts = (have.alts or 0) - fromAlts
                    local buy = need - fromBags - fromBank - fromAlts
                    step.needs[#step.needs + 1] = {
                        itemID = reagent.itemID, count = need, bags = fromBags, bank = fromBank,
                        alts = fromAlts, buy = buy,
                    }
                    cost = cost + buy * reagent.unit
                    saved = saved + (fromBags + fromBank + fromAlts) * reagent.unit
                end
                step.cost = cost
                back = back + ((step.price and step.price.back) or 0) * step.crafts
            end
            total = total + (step.cost or 0)
        end
    end

    return {
        steps = steps, current = current, total = total, saved = saved, back = back, stuck = stuck,
        skill = now, max = opts.max, line = line, pickBy = real and "real" or "lowest",
    }
end

--- How many of an item the character playing's other characters hold:
--- bags, bank and (unless turned off) mail, as last saved, only those it
--- can mail (same realm and side, not another account's), each character
--- once under all of its records. A viewer asked (2026-10-28): an alt
--- farms for the main, and the road counts what it gathered.
function RoadPlan.AltsHold(itemID)
    local records = ns.db and ns.db.characters
    local me = ns.Config and ns.Config:GetCharacterKey()
    if type(records) ~= "table" or not me then return 0 end
    local chars, queue = ns.Characters, ns.Queue
    local withMail = not (ns.Config.Get and ns.Config:Get("countMailAsStock") == false)
    local counted, total = {}, 0
    for key, record in pairs(records) do
        local ok, skip = pcall(function()
            if type(record) ~= "table" or record.linkedFrom ~= nil then return true end
            if key == me or (chars and chars.IsPlaying and chars:IsPlaying(key)) then return true end
            if queue and queue.CanMail and not queue:CanMail(me, key) then return true end
            for _, other in ipairs(counted) do
                if chars and chars.Same and chars:Same(key, other) then return true end
            end
            return false
        end)
        if ok and not skip then
            counted[#counted + 1] = key
            local held = ((type(record.inventory) == "table" and record.inventory[itemID]) or 0)
                + ((type(record.bank) == "table" and record.bank[itemID]) or 0)
            if withMail then held = held + ((type(record.mail) == "table" and record.mail[itemID]) or 0) end
            total = total + (tonumber(held) or 0)
        end
    end
    return total
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
-- Cooking and First Aid from the Professions book, for a client whose
-- trade skill lines leave the secondary professions out.
local function FromBook()
    local found = {}
    local getAll, getInfo = rawget(_G, "GetProfessions"), rawget(_G, "GetProfessionInfo")
    if type(getAll) ~= "function" or type(getInfo) ~= "function" then return found end
    local ok, indexes = pcall(function() return { getAll() } end)
    if not ok then return found end
    for i = 1, 6 do
        local index = indexes[i]
        if type(index) == "number" then
            local read, entry = pcall(function()
                local name, _, rank, maxRank, _, _, skillLine = getInfo(index)
                if type(name) ~= "string" or name == "" then return nil end
                return {
                    name = name .. "",
                    skillLineID = type(skillLine) == "number" and skillLine + 0 or nil,
                    skillLevel = type(rank) == "number" and rank + 0 or 0,
                    maxSkillLevel = type(maxRank) == "number" and maxRank + 0 or 0,
                }
            end)
            if read and entry and entry.maxSkillLevel > 0 then found[#found + 1] = entry end
        end
    end
    return found
end

function RoadPlan:Professions()
    local list, seen = {}, {}
    local recipes = ns.Recipes
    local ok, learned = pcall(function() return recipes and recipes:GetLearnedProfessions() end)
    local all = {}
    for _, profession in ipairs(ok and type(learned) == "table" and learned or {}) do all[#all + 1] = profession end
    for _, profession in ipairs(FromBook()) do all[#all + 1] = profession end
    for _, profession in ipairs(all) do
        local line = Classic(profession.skillLineID)
        if not RoadPlan.RANKS[line] then line = LineByName(profession) end
        if not line and RoadPlan.IsFishingName(profession.name) then line = RoadPlan.FISHING end
        if line and RoadPlan.RANKS[line] and not seen[line] then
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
        RoadPlan.PickBy(),
        -- Farmer's fishing pace moves with every cast it counts.
        profession.line == RoadPlan.FISHING and tostring(RoadPlan.FarmerPaceVersion()) or "",
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
            level = level, candidates = candidates, pickBy = RoadPlan.PickBy(),
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

local function Side()
    local ok, faction = pcall(function()
        local fn = rawget(_G, "UnitFactionGroup")
        local value = fn and fn("player")
        if type(value) == "string" then return value .. "" end
    end)
    if not ok then return nil end
    if faction == "Alliance" then return "A" end
    if faction == "Horde" then return "H" end
    return nil
end

local function QuestDone(questID)
    local ok, done = pcall(function()
        local log = rawget(_G, "C_QuestLog")
        local fn = log and log.IsQuestFlaggedCompleted or rawget(_G, "IsQuestFlaggedCompleted")
        return fn and fn(questID) == true
    end)
    return ok and done or false
end

--- A quest's title as the game gives it, else the data's English one.
local function QuestTitle(questID, fallback)
    local ok, title = pcall(function()
        local log = rawget(_G, "C_QuestLog")
        local value = log and log.GetTitleForQuestID and log.GetTitleForQuestID(questID)
        if type(value) == "string" and value ~= "" then return value .. "" end
    end)
    return ok and title or fallback
end

local function Spot(kind, name, zone, x, y)
    local place = { kind = kind, name = name, zone = zone, x = x, y = y }
    local pins = ns.VendorPins
    if pins and pins.SeenAt then
        local ok, seen = pcall(pins.SeenAt, pins, name, zone)
        if ok and type(seen) == "table" and seen.x and seen.y then
            place.x, place.y, place.mapID = seen.x, seen.y, seen.mapID
        end
    end
    return place
end

--- For a rank learned from a book or quests: what to do now, for the
--- character's side. { kind = "book", place, item, title } or { kind =
--- "quest", place, quest, title, last (true on the chain's last quest),
--- teacher (the last quest's place) }, or nil.
function RoadPlan.HowNow(how)
    if not how then return nil end
    local side = Side()
    if not side then return nil end
    if how.kind == "book" then
        local seller = how.sellers and how.sellers[side]
        if not seller then return nil end
        return { kind = "book", item = how.item, title = how.title,
            place = Spot("vendor", seller[1], seller[2], seller[3], seller[4]) }
    end
    local chain = how.chain and how.chain[side]
    if not chain or #chain == 0 then return nil end
    local index = #chain
    for i, quest in ipairs(chain) do
        if not QuestDone(quest[1]) then index = i break end
    end
    local quest, final = chain[index], chain[#chain]
    return {
        kind = "quest", quest = quest[1], title = QuestTitle(quest[1], quest[2]), last = index == #chain,
        place = Spot("quest", quest[3], quest[4], quest[5], quest[6]),
        teacher = Spot("quest", final[3], final[4], final[5], final[6]),
    }
end

--- Where a step's Show the Way goes: the trainer for a trainer step, the
--- trainer or vendor that teaches a recipe still to learn.
function RoadPlan:PlaceFor(step, line)
    if not step then return nil end
    -- A zone to fish: only your own best spot there, never a made up one.
    if step.kind == "fish" then return step.best and step.best.place or nil end
    if step.kind == "trainer" and step.how then
        local now = RoadPlan.HowNow(step.how)
        return now and now.place
    end
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
    if step.kind == "fish" then name = place.name end
    if step.how then name = place.name end
    return ns.LearnNext:ShowTheWay({ place = place, record = step.record, name = name or "" })
end

--------------------------------------------------------------------------------
-- Fishing (the owner said build it, 2026-11-08, from a mockup)
--
-- Nothing is crafted, so a step between the ranks is a zone to fish in,
-- "Fish in ZONE", from one skill to the next. A catch below 75 gives a
-- point; past it a point takes (skill - 50) / 25 catches, Classic's rule.
-- Where Farmer is loaded, its own count of your casts gives your pace and
-- the spot you fished most in that zone, read only and in a pcall;
-- without it a catch is FISH_SECONDS. Fish get away in a zone until your
-- skill (lure included) reaches its level, so a step whose zone is above
-- you names a lure: the smallest in your bags that covers the gap, else
-- the best one a vendor sells that your skill can use. A lure lasts
-- LURE_MINUTES. No Queue Step, Queue All or Pick By: nothing is made.
--------------------------------------------------------------------------------

RoadPlan.FISHING = 356
RoadPlan.FISH_SECONDS = 18
RoadPlan.LURE_MINUTES = 10
-- From a zone's level plus this, no fish gets away there without a lure.
RoadPlan.FISH_COVER = 95

-- The two zones near home to fish first, by race, else by side.
RoadPlan.FISH_HOMES = {
    Human = { "Elwynn Forest", "Westfall" },
    Dwarf = { "Dun Morogh", "Loch Modan" },
    Gnome = { "Dun Morogh", "Loch Modan" },
    NightElf = { "Teldrassil", "Darkshore" },
    Orc = { "Durotar", "The Barrens" },
    Troll = { "Durotar", "The Barrens" },
    Tauren = { "Mulgore", "The Barrens" },
    Scourge = { "Tirisfal Glades", "Silverpine Forest" },
    A = { "Elwynn Forest", "Westfall" },
    H = { "Durotar", "The Barrens" },
}
RoadPlan.FISH_FAR = { "Stranglethorn Vale", "Feralas" }

-- The skill each zone's fish need before none get away (Classic's).
RoadPlan.FISH_LEVELS = {
    ["Elwynn Forest"] = -70, ["Dun Morogh"] = -70, ["Teldrassil"] = -70,
    ["Durotar"] = -70, ["Mulgore"] = -70, ["Tirisfal Glades"] = -70,
    ["Westfall"] = -20, ["Loch Modan"] = -20, ["Darkshore"] = -20,
    ["The Barrens"] = -20, ["Silverpine Forest"] = -20,
    ["Stranglethorn Vale"] = 130, ["Feralas"] = 205,
}

-- Lures, best first: { item, bonus, skill to use it, vendor sells it }.
-- Each is in the Forever client's game tables; vendors of both sides sell
-- the three marked (ForeverVendorSpots).
RoadPlan.LURES = {
    { 6533, 100, 100 },
    { 6532, 75, 100, true },
    { 7307, 75, 100 },
    { 6530, 50, 50, true },
    { 6811, 50, 50 },
    { 6529, 25, 0, true },
}

--- Is this the client's name for Fishing? (A client that gives no skill
--- line for it in the Professions book.)
function RoadPlan.IsFishingName(name)
    if type(name) ~= "string" or name == "" then return false end
    if name == "Fishing" then return true end
    local ok, spell = pcall(function()
        local api = rawget(_G, "C_Spell")
        local value = api and api.GetSpellName and api.GetSpellName(7620)
        if not value then
            local fn = rawget(_G, "GetSpellInfo")
            value = fn and fn(7620)
        end
        if type(value) == "string" and value ~= "" then return value .. "" end
    end)
    return ok and spell == name or false
end

--- Catches from one skill to another.
function RoadPlan.FishCatches(from, to)
    local catches = 0
    for skill = from, to - 1 do
        catches = catches + (skill < 75 and 1 or (skill - 50) / 25)
    end
    return math.max(0, math.ceil(catches - 1e-9))
end

local function Farmer()
    local farmer = rawget(_G, "BlackthornesFarmer")
    local fishing = type(farmer) == "table" and rawget(farmer, "Fishing")
    if type(fishing) == "table" and type(fishing.Spots) == "function"
        and type(fishing.SecondsPerCast) == "function" then
        return fishing
    end
end

function RoadPlan.FarmerPaceVersion()
    local fishing = Farmer()
    return fishing and tonumber(rawget(fishing, "paceVersion")) or 0
end

--- Your pace and best spot from Farmer: { seconds (a cast, or nil), best =
--- { name, place } or nil }, or nil without Farmer. A zone's own spots give
--- its pace, else every spot you fished.
function RoadPlan.FarmerFishing(zone)
    local fishing = Farmer()
    if not fishing then return nil end
    local function Pace(spots)
        local seconds, casts = 0, 0
        for _, summary in ipairs(spots or {}) do
            local ok, each = pcall(fishing.SecondsPerCast, fishing, summary.key)
            local count = tonumber(summary.casts) or 0
            if ok and type(each) == "number" and each > 0 and count > 0 then
                seconds, casts = seconds + each * count, casts + count
            end
        end
        if casts > 0 then return seconds / casts end
    end
    local ok, here = pcall(fishing.Spots, fishing, zone)
    here = ok and type(here) == "table" and here or {}
    local seconds = Pace(here)
    if not seconds then
        local okAll, all = pcall(fishing.Spots, fishing, nil)
        seconds = okAll and type(all) == "table" and Pace(all) or nil
    end
    local best
    for _, summary in ipairs(here) do
        local spot = type(summary.spot) == "table" and summary.spot or {}
        local name = type(spot.location) == "string" and spot.location ~= "" and spot.location
            or type(spot.school) == "string" and spot.school ~= "" and spot.school or nil
        local coords = type(spot.coords) == "table" and spot.coords
        if name then
            best = { name = name }
            if coords and tonumber(coords[1]) and tonumber(coords[2]) then
                best.place = { kind = "spot", name = name, zone = zone,
                    x = tonumber(coords[1]), y = tonumber(coords[2]) }
            end
            break
        end
    end
    return { seconds = seconds, best = best }
end

local function Race()
    local ok, token = pcall(function()
        local fn = rawget(_G, "UnitRace")
        local _, value = fn and fn("player")
        if type(value) == "string" then return value .. "" end
    end)
    return ok and token or nil
end

local function LurePrice(item)
    local vendor = ns.Vendor
    if vendor and vendor.GetUnitPrice then
        local ok, price = pcall(vendor.GetUnitPrice, vendor, item)
        if ok and type(price) == "number" and price > 0 then return price end
    end
    local prices = ns.VENDOR_PRICES
    return prices and tonumber(prices[item]) or nil
end

local function BagCount(item, owned)
    if owned then
        local given = owned[item]
        return given and (given[1] or 0) or 0
    end
    local inv = ns.Inventory
    local ok, bags = pcall(function() return inv:GetBagCount(item) end)
    return ok and tonumber(bags) or 0
end

--- The lure for a gap at a skill: { item, bonus, have, price }.
function RoadPlan.PickLure(gap, skill, owned)
    local mine
    for i = #RoadPlan.LURES, 1, -1 do
        local lure = RoadPlan.LURES[i]
        if lure[2] >= gap and lure[3] <= skill then
            local have = BagCount(lure[1], owned)
            if have > 0 then mine = { item = lure[1], bonus = lure[2], have = have } break end
        end
    end
    if not mine then
        for _, lure in ipairs(RoadPlan.LURES) do
            if lure[4] and lure[3] <= skill then
                mine = { item = lure[1], bonus = lure[2], have = BagCount(lure[1], owned) }
                break
            end
        end
    end
    if not mine then return nil end
    for _, lure in ipairs(RoadPlan.LURES) do
        if lure[1] == mine.item and lure[4] then mine.price = LurePrice(lure[1]) end
    end
    return mine
end

--- The road for Fishing; the same shape as Plan's, with `fishing` and
--- `hours` added.
function RoadPlan.FishPlan(opts)
    local ranks = RoadPlan.RANKS[RoadPlan.FISHING]
    local now, max, level = opts.skill or 0, opts.max or 0, opts.level or 0
    local side = opts.side or Side()
    local homes = RoadPlan.FISH_HOMES[opts.race or Race() or ""] or RoadPlan.FISH_HOMES[side or "A"]
        or RoadPlan.FISH_HOMES.A
    local zones = { homes[1], homes[2], RoadPlan.FISH_FAR[1], RoadPlan.FISH_FAR[2] }
    local bounds = { { 1, 75 }, { 75, 125 }, { 125, 225 }, { 225, 300 } }
    local farmer = opts.farmer
    local steps = {}

    for index, rank in ipairs(ranks) do
        local done = max >= rank[4]
        steps[#steps + 1] = {
            kind = "trainer", rank = rank, at = rank[1], cap = rank[4], level = rank[2],
            cost = rank[3], how = rank.how, from = rank[1], to = rank[1], done = done or nil,
            locked = not done and level < rank[2] or nil,
        }
        local zone, span = zones[index], bounds[index]
        local fish = { kind = "fish", zone = zone, from = span[1], to = span[2], reach = RoadPlan.FISH_LEVELS[zone] }
        if now >= span[2] then
            fish.done = true
        else
            fish.from = math.max(span[1], now)
            local read = farmer
            if read == nil then read = RoadPlan.FarmerFishing(zone) or false end
            fish.catches = RoadPlan.FishCatches(fish.from, fish.to)
            fish.paced = read and read.seconds and true or nil
            fish.each = read and read.seconds or RoadPlan.FISH_SECONDS
            fish.seconds = fish.catches * fish.each
            fish.best = read and read.best or nil
        end
        steps[#steps + 1] = fish
    end

    local total, seconds, current = 0, 0, nil
    for index, step in ipairs(steps) do
        if not step.done then
            current = current or index
            if step.kind == "fish" then
                seconds = seconds + step.seconds
                local reach = step.reach
                if reach and step.from < reach + RoadPlan.FISH_COVER then
                    if step.from >= reach then
                        step.lure = { cover = true }
                    else
                        local lure = RoadPlan.PickLure(reach - step.from, step.from, opts.owned)
                        if lure then
                            local short = RoadPlan.FishCatches(step.from, math.min(reach, step.to)) * step.each
                            lure.need = math.max(1, math.ceil(short / 60 / RoadPlan.LURE_MINUTES - 1e-9))
                            lure.cost = lure.price and math.max(0, lure.need - lure.have) * lure.price or 0
                            total = total + lure.cost
                            step.lure = lure
                        end
                    end
                    if step.lure then step.lure.reach = reach end
                end
            else
                total = total + (step.cost or 0)
            end
        end
    end

    if current then steps[current].current = true end
    return {
        steps = steps, current = current, total = total, saved = 0, back = 0,
        skill = now, max = max, line = RoadPlan.FISHING, pickBy = "lowest",
        fishing = true, seconds = seconds,
    }
end

--- The footer's time: about N hours of fishing, at least 1.
function RoadPlan.FishHours(plan)
    return math.max(1, math.floor((plan and plan.seconds or 0) / 3600 + 0.5))
end

--- The words on a Fishing step: { title, chip, range, lines, tip }.
function RoadPlan.FishTexts(step, professionName, level, current)
    local texts = { lines = {} }
    if step.kind == "fish" then
        texts.title = L.Format("Fish in %s", ns.Spots and ns.Spots.Show and ns.Spots.Show(step.zone) or step.zone)
        texts.range = L.Format("%d to %d", step.from, step.to)
        if step.done then return texts end
        if current then texts.chip = L["Now"] end
        local count = current and L.Format("About %d more catches.", step.catches)
            or L.Format("About %d catches.", step.catches)
        if step.paced then
            count = count .. " " .. L.Format("At your pace, about %d minutes.",
                math.max(1, math.floor(step.seconds / 60 + 0.5)))
        end
        texts.lines[1] = count
        if step.best then texts.lines[2] = L.Format("Best spot you've fished here: %s.", step.best.name) end
        local lure = step.lure
        if lure then
            local tip = { L.Format("Fish get away here until you reach %d.", lure.reach) }
            if lure.cover then
                tip[2] = L["Your skill and lure cover it."]
            else
                tip[2] = L.Format("Put on a %s (+%d) first.", RoadPlan.ItemName(lure.item), lure.bonus)
                if lure.have > 0 then tip[3] = L.Format("You have %d.", lure.have) end
            end
            texts.tip = table.concat(tip, " ")
        end
        return texts
    end

    local index = 1
    for i, rank in ipairs(RoadPlan.RANKS[RoadPlan.FISHING]) do
        if rank == step.rank then index = i end
    end
    texts.range = tostring(step.at)
    if index == 1 then
        texts.title = L.Format("Train Apprentice %s", professionName)
    elseif index == 2 then
        texts.title = L.Format("Train Journeyman %s", professionName)
    elseif index == 3 then
        texts.title = L.Format("Buy %s", RoadPlan.ItemName(step.how.item, step.how.title))
    else
        local chain = step.how.chain[Side() or "A"] or step.how.chain.A
        texts.title = L.Format("Do the quest %s", QuestTitle(chain[1][1], chain[1][2]))
    end
    if index == 4 and not step.done then texts.chip = L.Format("Level %d", step.level)
    elseif step.locked then texts.chip = L.Format("Level %d", step.level) end
    if step.done then return texts end

    if index <= 2 then
        local place = not step.locked and RoadPlan:PlaceFor(step, RoadPlan.FISHING)
        if place and place.zone then texts.lines[1] = L.Format("%s trainer in %s", professionName, place.zone) end
    elseif index == 3 then
        local seller = step.how.sellers[Side() or "A"] or step.how.sellers.A
        texts.lines[1] = L.Format("%s sells it in %s. Read it to learn Expert %s.",
            seller[1], seller[5] or seller[2], professionName)
    else
        local now = RoadPlan.HowNow(step.how)
        local giver = now and now.place or {}
        local chain = step.how.chain[Side() or "A"] or step.how.chain.A
        texts.lines[1] = L.Format("Start with %s in %s. Catch the four rare fish he asks for. Then he teaches you Artisan %s.",
            giver.name or chain[1][3], giver.zone or chain[1][4], professionName)
    end
    if step.locked then texts.lines[#texts.lines + 1] = L.Format("You're level %d.", level or 0) end
    return texts
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
    if (need.alts or 0) > 0 then parts[#parts + 1] = L.Format("Your other characters have %d.", need.alts) end
    if need.bags == 0 and need.buy > 0 then parts[#parts + 1] = L.Format("Buy %d.", need.buy) end
    return table.concat(parts, " ")
end

local TRAIN = {
    function(profession) return L.Format("Train Journeyman %s", profession) end,
    function(profession) return L.Format("Train Expert %s", profession) end,
    function(profession) return L.Format("Train Artisan %s", profession) end,
}

-- A rank learned from a book or a quest, not at a trainer.
local LEARN = {
    function(profession) return L.Format("Train Journeyman %s", profession) end,
    function(profession) return L.Format("Learn Expert %s", profession) end,
    function(profession) return L.Format("Learn Artisan %s", profession) end,
}

--- Does what the character and its other characters hold cover every
--- material of a step still to make? Then the rest they gather can go
--- elsewhere.
function RoadPlan.Covered(step)
    if step.done or step.kind ~= "craft" or not step.needs or #step.needs == 0 then return false end
    for _, need in ipairs(step.needs) do
        if (need.buy or 0) > 0 then return false end
    end
    return true
end

--- What a step says: { title, chip, range, lines = { ... } }.
-- @param professionName  the profession's name as the client gives it
-- @param level           the character's level
function RoadPlan.Texts(step, professionName, level, line)
    if line == RoadPlan.FISHING then
        return RoadPlan.FishTexts(step, professionName, level, step.current)
    end
    local texts = { lines = {} }
    if step.kind == "trainer" then
        local index = 1
        for i, rank in ipairs(RoadPlan.RANKS[line] or {}) do
            if rank == step.rank then index = i end
        end
        texts.title = (TRAIN[index] or TRAIN[1])(professionName)
        if step.how then
            texts.title = (LEARN[index] or LEARN[1])(professionName)
        end
        if step.locked then
            texts.chip = L.Format("level %d", step.level)
            texts.range = L.Format("at %d", step.at)
            texts.lines[1] = L.Format("You're level %d.", level or 0)
        else
            texts.range = L.Format("at %d, raises your cap to %d", step.at, step.cap)
        end
        local now = step.how and not step.done and RoadPlan.HowNow(step.how)
        if now and now.kind == "book" then
            local place = now.place
            texts.lines = { L.Format("Buy %s from %s in %s.", ItemName(now.item, now.title), place.name, place.zone) }
        elseif now and now.last then
            local lines = { L.Format("Do the quest %s for %s in %s. Then they teach you.",
                now.title, now.place.name, now.place.zone) }
            if step.locked then lines[2] = L.Format("You're level %d.", level or 0) end
            texts.lines = lines
        elseif now then
            local lines = {
                L.Format("Start with the quest %s from %s in %s.", now.title, now.place.name, now.place.zone),
                L.Format("It leads to %s in %s, who teaches you.", now.teacher.name, now.teacher.zone),
            }
            if step.locked then lines[3] = L.Format("You're level %d.", level or 0) end
            texts.lines = lines
        elseif not step.locked and not step.how then
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
    if step.orange then
        texts.chip = L["every craft"]
    elseif step.tier == "easy" then
        texts.chip = L["some crafts"]
    else
        texts.chip = L["most crafts"]
    end
    for _, need in ipairs(step.needs or {}) do texts.lines[#texts.lines + 1] = RoadPlan.NeedText(need) end
    if RoadPlan.Covered(step) then texts.lines[#texts.lines + 1] = L["You have enough for this step."] end
    if step.learn then
        if step.learn.kind == "trainer" then
            -- Where the trainer stands, as the row's Show the Way aims (the
            -- owner, 2026-10-23: a lone "Trainer" said nothing).
            local zone = step.learn.zone
            texts.lines[#texts.lines + 1] = zone
                and L.Format("Learn it from the %s trainer in %s.", professionName, zone)
                or L.Format("Learn it from the %s trainer.", professionName)
        else
            local zone = step.learn.zone
            texts.lines[#texts.lines + 1] = zone
                and L.Format("You don't know this recipe yet. Buy it from a vendor in %s.", zone)
                or L["You don't know this recipe yet. Buy it from a vendor."]
        end
    end
    if step.sells and step.sells > 0 and ns.Util and ns.Util.FormatMoney then
        texts.lines[#texts.lines + 1] = L.Format("Sells for about %s each, so it pays some back.",
            ns.Util.FormatMoney(step.sells, { short = true }))
    end
    return texts
end
