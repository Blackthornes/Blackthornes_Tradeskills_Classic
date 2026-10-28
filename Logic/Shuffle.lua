-- Blackthornes Tradeskills -- Logic/Shuffle.lua
-- Shuffles: every way to turn one item into gold (a player asked, the owner
-- said build it from a mockup, 2026-10-25).
--
-- Start with a stack of one item ("20 Copper Ore") and follow it through the
-- crafts that use it, up to DEPTH crafts deep: smelt it, make something from
-- the bars, then sell what you made, sell it to a vendor or disenchant it.
-- Each way is a row: what you put in (the stack at its sell value, plus the
-- other materials the crafts need, bought), what you get back, and the gain.
-- Its steps say what each is worth if you stopped there and sold, so the
-- step worth the most is the best place to stop.
--
-- Prices are the usual ones: Prices:GetValue (your scans, then your guild,
-- TSM and Auctionator) after the cut and deposit, a vendor's price, or what
-- a disenchant most likely gives (Disenchant:GetValue). A grey is the
-- vendor's price only. Other materials cost what Cost:GetReagentCost says;
-- a craft with one it can't price is left out, never guessed.
--
-- With "Only My Recipes" ticked only the crafts the character playing knows
-- count; unticked, every recipe in the book.
--
-- Worked out only while the Shuffles view asks (UI/ShuffleView.lua), a few
-- steps a frame (BUDGET), and kept KEEP seconds. Nothing is saved.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Shuffle = ns.NewModule("Shuffle")

-- Holdings looked at a frame.
Shuffle.BUDGET = 40
-- Seconds a worked-out answer is kept.
Shuffle.KEEP = 60
-- How many crafts a way can take.
Shuffle.DEPTH = 3
-- At most this many holdings are looked at for one start, so a common
-- cloth with a hundred uses stays quick.
Shuffle.MAX_NODES = 3000
-- Ways shown, best gain first ("Sell it as it is" always among them).
Shuffle.MAX_WAYS = 12
-- Mining, whose crafts are smelts.
Shuffle.MINING = 186

Shuffle.version = 0

local function Clock()
    return type(GetTime) == "function" and GetTime() or 0
end

--------------------------------------------------------------------------------
-- Prices
--------------------------------------------------------------------------------

local function Quality(itemID)
    local getInfo = (type(C_Item) == "table" and C_Item.GetItemInfo) or rawget(_G, "GetItemInfo")
    if type(getInfo) ~= "function" then return nil end
    local ok, quality = pcall(function() return select(3, getInfo(itemID)) end)
    return ok and tonumber(quality) or nil
end

--- What one sells for on the auction house after the cut and deposit, and
--- to a vendor, each in copper or nil. A grey has no auction price.
function Shuffle:Prices(itemID, cache)
    if cache and cache[itemID] then
        local kept = cache[itemID]
        return kept.ah, kept.vendor
    end

    local vendor = ns.Util and ns.Util.GetVendorSellPrice and ns.Util.GetVendorSellPrice(itemID) or nil
    vendor = tonumber(vendor)
    if vendor and vendor <= 0 then vendor = nil end

    local auction
    if Quality(itemID) ~= 0 then
        local ok, market = pcall(ns.Prices.GetValue, ns.Prices, itemID)
        if ok and type(market) == "number" and market > 0 then
            local fine, net = pcall(ns.Profit.NetFromListing, ns.Profit, itemID, market)
            if fine and type(net) == "number" and net > 0 then auction = net end
        end
    end

    if cache then cache[itemID] = { ah = auction or false, vendor = vendor or false } end
    return auction, vendor
end

--- The better of the two, and which: "ah" or "vendor". Nil when neither.
function Shuffle:Best(itemID, cache)
    local ah, vendor = self:Prices(itemID, cache)
    ah, vendor = ah or nil, vendor or nil
    if ah and (not vendor or ah >= vendor) then return ah, "ah" end
    if vendor then return vendor, "vendor" end
    return nil
end

--- What disenchanting one gives: { value, itemID, average, yours }, or nil.
function Shuffle:Breaks(itemID, cache)
    local key = "de" .. itemID
    if cache and cache[key] ~= nil then return cache[key] or nil end

    local found
    local Disenchant = ns.Disenchant
    if Disenchant and Disenchant.IsDisenchantable then
        local ok, can = pcall(Disenchant.IsDisenchantable, Disenchant, itemID)
        if ok and can then
            local fine, value, _, breakdown = pcall(Disenchant.GetValue, Disenchant, itemID)
            if fine and type(value) == "number" and value > 0 and type(breakdown) == "table" then
                for _, outcome in ipairs(breakdown.outcomes or {}) do
                    if outcome.counted then
                        found = { value = value, itemID = outcome.itemID, average = outcome.average or 1,
                            yours = type(breakdown.facts) == "table" and breakdown.facts.source == "yours" }
                        break
                    end
                end
            end
        end
    end

    if cache then cache[key] = found or false end
    return found
end

--------------------------------------------------------------------------------
-- Recipes by what they use
--------------------------------------------------------------------------------

local function YieldOf(recipe)
    local low, high = tonumber(recipe.quantityMin) or 1, tonumber(recipe.quantityMax) or low
    local yield = (low + high) / 2
    return yield > 0 and yield or 1
end
Shuffle.YieldOf = YieldOf

--- The recipes the character playing knows, by recipe ID.
function Shuffle:Known()
    local known = {}
    local Recipes = ns.Recipes
    local ok, all = pcall(Recipes.GetAll, Recipes)
    for recipeID, recipe in pairs(ok and type(all) == "table" and all or {}) do
        local dropped = Recipes.IsDropped and Recipes:IsDropped(recipe)
        if not dropped and recipe.outputItemID then known[recipeID] = recipe end
    end
    return known
end

--- For each item, the recipes that use it: { [itemID] = { recipe, ... } }.
--- Only the character's own with `mine`, else the whole book too.
function Shuffle:Index(mine)
    local known = self:Known()
    local index, seen = {}, {}

    local function Add(recipeID, recipe, isKnown)
        if seen[recipeID] or not recipe.outputItemID then return end
        seen[recipeID] = true
        local entry = { id = recipeID, recipe = recipe, known = isKnown }
        for _, reagent in ipairs(recipe.reagents or {}) do
            local itemID = reagent.itemID
            if itemID and (tonumber(reagent.quantity) or 0) > 0 then
                local list = index[itemID]
                if not list then list = {}; index[itemID] = list end
                list[#list + 1] = entry
            end
        end
    end

    for recipeID, recipe in pairs(known) do Add(recipeID, recipe, true) end
    if not mine and ns.RecipeBook and ns.RecipeBook.GetAll then
        local ok, book = pcall(ns.RecipeBook.GetAll, ns.RecipeBook)
        for recipeID, recipe in pairs(ok and type(book) == "table" and book or {}) do
            Add(recipe.recipeID or recipeID, recipe, false)
        end
    end
    return index
end

--- Items in the bags some recipe uses: { { itemID, count } }, by item ID.
function Shuffle:Starts(mine)
    local index = self:Index(mine)
    local counts = ns.Inventory and ns.Inventory.GetBagCounts and ns.Inventory:GetBagCounts() or {}
    local list = {}
    for itemID, count in pairs(counts) do
        if index[itemID] and (tonumber(count) or 0) > 0 then
            list[#list + 1] = { itemID = itemID, count = count }
        end
    end
    table.sort(list, function(a, b) return a.itemID < b.itemID end)
    return list
end

--------------------------------------------------------------------------------
-- Words
--------------------------------------------------------------------------------

local function IsMining(recipe)
    return tonumber(recipe.skillLineID) == Shuffle.MINING or recipe.profession == "Mining"
end

-- The verb of each part of a way's name, first and later in the name.
local VERBS = {
    smelt = { L["Smelt"], L["smelt"] },
    make = { L["Make"], L["make"] },
    sell = { L["Sell"], L["sell"] },
    vendor = { L["Vendor"], L["vendor"] },
    de = { L["Disenchant"], L["disenchant"] },
}

--- "Smelt, make, disenchant", "Smelt and sell", "Sell it as it is".
function Shuffle.WayName(parts)
    if #parts <= 1 and (parts[1] == nil or parts[1] == "sell") then return L["Sell it as it is"] end
    local words = {}
    for index, part in ipairs(parts) do
        words[index] = VERBS[part][index == 1 and 1 or 2]
    end
    if #words == 1 then return words[1] end
    if #words == 2 then return L.Format("%s and %s", words[1], words[2]) end
    local text = words[1]
    for index = 2, #words do text = L.Format("%s, %s", text, words[index]) end
    return text
end

local function EnglishClient()
    local locale = type(GetLocale) == "function" and GetLocale() or "enUS"
    return type(locale) ~= "string" or locale:sub(1, 2) == "en"
end

--- An item's name, or nil while the client hasn't loaded it.
function Shuffle.ItemName(itemID)
    local getInfo = (type(C_Item) == "table" and C_Item.GetItemInfo) or rawget(_G, "GetItemInfo")
    if type(getInfo) == "function" then
        local ok, name = pcall(getInfo, itemID)
        if ok and type(name) == "string" then return name end
    end
    local Disenchant = ns.Disenchant
    return Disenchant and Disenchant.MaterialName and Disenchant:MaterialName(itemID) or nil
end

--- A short name for the chain: on an English client the last word before
--- " of " ("Runed Copper Belt" is Belt, "Strange Dust" is Dust); the whole
--- name elsewhere, since word order differs.
function Shuffle.ShortName(name)
    if type(name) ~= "string" then return "?" end
    if not EnglishClient() then return name end
    local base = name:match("^(.-) of ") or name
    return base:match("(%S+)%s*$") or name
end

--- "Ore, Bar, Belt, Dust".
function Shuffle.ChainText(itemIDs)
    local text
    for _, itemID in ipairs(itemIDs) do
        local short = Shuffle.ShortName(Shuffle.ItemName(itemID))
        text = text and L.Format("%s, %s", text, short) or short
    end
    return text or ""
end

--- The profession and skill the character has for a recipe's line, or nil.
local function SkillFor(recipe)
    local ok, learned = pcall(ns.Recipes.GetLearnedProfessions, ns.Recipes)
    for _, profession in ipairs(ok and type(learned) == "table" and learned or {}) do
        if (recipe.skillLineID and profession.skillLineID == recipe.skillLineID)
            or (recipe.profession and profession.name == recipe.profession) then
            return profession.name, tonumber(profession.skillLevel)
        end
    end
end

--------------------------------------------------------------------------------
-- Working out the ways
--------------------------------------------------------------------------------

local function Step(kind, itemID, count, how, worth)
    return { kind = kind, itemID = itemID, count = count, how = how, worth = worth }
end

--- Mark the best place to stop and the steps that lose gold.
local function Finish(way)
    local best
    for index, step in ipairs(way.steps) do
        local before = way.steps[index - 1]
        step.change = before and (step.worth - before.worth) or 0
        step.loss = before ~= nil and step.worth < before.worth
        if not best or step.worth > way.steps[best].worth then best = index end
    end
    if best then way.steps[best].best = true end
    way.best = best
end

local function Copy(list)
    local copy = {}
    for index, value in ipairs(list) do copy[index] = value end
    return copy
end

--- One holding's ways out: sell it, vendor it, disenchant it. `node` is
--- { itemID, count, spent, leftover, steps, parts, chain, crafts, buys }.
function Shuffle:Ends(node, start, cache, out)
    local ah, vendor = self:Prices(node.itemID, cache)
    ah, vendor = ah or nil, vendor or nil
    local depth = #node.crafts

    local function Add(kind, value, how, extra)
        local steps = Copy(node.steps)
        local last = steps[#steps]
        local parts = Copy(node.parts)
        local chain = Copy(node.chain)
        local back = value + node.leftover
        if extra then
            steps[#steps + 1] = extra
            chain[#chain + 1] = extra.itemID
        else
            -- The last step is where it's sold, at this end's price.
            local copy = {}
            for key, field in pairs(last) do copy[key] = field end
            copy.how, copy.worth = how, back - node.spent
            steps[#steps] = copy
        end
        parts[#parts + 1] = kind
        local way = {
            name = Shuffle.WayName(parts), parts = parts, chain = chain, steps = steps,
            putIn = start.value + node.spent, back = back, crafts = node.crafts, buys = node.buys,
            ends = kind, startID = start.itemID, startCount = start.count,
        }
        way.gain = way.back - way.putIn
        Finish(way)
        out[#out + 1] = way
    end

    if depth == 0 then
        local value, how = self:Best(node.itemID, cache)
        if value then Add("sell", value * node.count, how) end
    else
        if ah then Add("sell", ah * node.count, "ah") end
        if vendor and (not ah or vendor > 0) then Add("vendor", vendor * node.count, "vendor") end
    end

    local breaks = self:Breaks(node.itemID, cache)
    if breaks then
        local value = breaks.value * node.count
        local step = Step("de", breaks.itemID, breaks.average * node.count, "de",
            value + node.leftover - node.spent)
        step.yours = breaks.yours
        Add("de", value, "de", step)
    end
end

--- The holdings one craft makes from `node`, or nil when it can't.
function Shuffle:Craft(node, entry, cache)
    local recipe = entry.recipe
    local need = 0
    for _, reagent in ipairs(recipe.reagents or {}) do
        if reagent.itemID == node.itemID then need = need + (tonumber(reagent.quantity) or 0) end
    end
    if need <= 0 then return nil end
    local crafts = math.floor(node.count / need)
    if crafts < 1 then return nil end

    local output = recipe.outputItemID
    for _, itemID in ipairs(node.chain) do
        if itemID == output then return nil end
    end

    -- The other materials, bought.
    local spent, buys = 0, {}
    for itemID, count in pairs(node.buys) do buys[itemID] = count end
    for _, reagent in ipairs(recipe.reagents or {}) do
        if reagent.itemID ~= node.itemID then
            local count = (tonumber(reagent.quantity) or 0) * crafts
            if count > 0 then
                local ok, cost = pcall(ns.Cost.GetReagentCost, ns.Cost, reagent.itemID, count)
                if not ok or type(cost) ~= "number" then return nil end
                spent = spent + cost
                buys[reagent.itemID] = (buys[reagent.itemID] or 0) + count
            end
        end
    end

    -- What's left of the stack sells as it is.
    local left = node.count - crafts * need
    local leftover = node.leftover
    if left > 0 then
        local value = self:Best(node.itemID, cache)
        leftover = leftover + (value or 0) * left
    end

    local count = crafts * YieldOf(recipe)
    local value, how = self:Best(output, cache)
    local spentNow = node.spent + spent
    local step = Step("craft", output, count, how, (value or 0) * count + leftover - spentNow)
    step.recipeID, step.known, step.verb = entry.id, entry.known, IsMining(recipe) and "smelt" or "make"
    step.recipe = recipe

    local steps, parts, chain, list = Copy(node.steps), Copy(node.parts), Copy(node.chain), Copy(node.crafts)
    steps[#steps + 1] = step
    parts[#parts + 1] = step.verb
    chain[#chain + 1] = output
    list[#list + 1] = { recipeID = entry.id, crafts = crafts, known = entry.known }

    return { itemID = output, count = count, spent = spentNow, leftover = leftover,
        steps = steps, parts = parts, chain = chain, crafts = list, buys = buys }
end

--- Keep the best ways: the top MAX_WAYS by gain, "Sell it as it is"
--- always, and one way a name and chain.
function Shuffle.Pick(ways)
    table.sort(ways, function(a, b)
        if a.gain ~= b.gain then return a.gain > b.gain end
        if #a.steps ~= #b.steps then return #a.steps < #b.steps end
        return a.name < b.name
    end)
    local kept, seen, plain = {}, {}, nil
    for _, way in ipairs(ways) do
        local key = way.name .. "|" .. table.concat(way.chain, ",")
        if #way.crafts == 0 and way.ends == "sell" then plain = plain or way end
        if not seen[key] and #kept < Shuffle.MAX_WAYS then
            seen[key] = true
            kept[#kept + 1] = way
        end
    end
    if plain and not seen[plain.name .. "|" .. table.concat(plain.chain, ",")] then
        kept[#kept] = plain
    end
    for index, way in ipairs(kept) do way.id = index end
    return kept
end

--- Notes on each step: "You know this recipe.", the loss note and so on.
function Shuffle.Notes(way)
    for _, step in ipairs(way.steps) do
        if step.loss then
            step.note = L["This step loses gold. Sell before it."]
        elseif step.kind == "craft" and step.known then
            local profession, skill = SkillFor(step.recipe)
            if IsMining(step.recipe) and profession and skill then
                step.note = L.Format("You know this. %s %d.", profession, skill)
            else
                step.note = L["You know this recipe."]
            end
        elseif step.kind == "de" and step.yours then
            step.note = L["From what you have broken before."]
        end
    end
end

local function Key(itemID, count, mine)
    local scan = ns.Prices and ns.Prices.GetLastScan and ns.Prices:GetLastScan() or 0
    return ("%d:%d:%s:%s"):format(itemID, count, mine and "1" or "0", tostring(scan))
end

--- The ways for `count` of `itemID`, as last worked out, or nil; and
--- whether they need working out again.
function Shuffle:Get(itemID, count, mine)
    local key = Key(itemID, count, mine)
    if self.key ~= key or not self.ways then return nil, true end
    local age = Clock() - (self.builtAt or 0)
    return self.ways, age > Shuffle.KEEP or age < 0
end

--- Work out the ways, a few holdings a frame. `done(ways)` is called when
--- they are ready (at once with `now`, as the tests do).
function Shuffle:Build(itemID, count, mine, done, now)
    itemID, count = tonumber(itemID), math.floor(tonumber(count) or 0)
    if not itemID or count < 1 then
        if done then done({}) end
        return
    end

    local key = Key(itemID, count, mine)
    self.run = (self.run or 0) + 1
    local run = self.run
    local index, cache, found = self:Index(mine), {}, {}

    local value = self:Best(itemID, cache)
    local start = { itemID = itemID, count = count, value = (value or 0) * count }
    local _, how = self:Best(itemID, cache)
    local first = Step("start", itemID, count, how or "ah", start.value)

    local queue = { { itemID = itemID, count = count, spent = 0, leftover = 0, steps = { first },
        parts = {}, chain = { itemID }, crafts = {}, buys = {} } }
    local head, looked = 1, 0

    local function Done()
        local ways = Shuffle.Pick(found)
        for _, way in ipairs(ways) do Shuffle.Notes(way) end
        self.key, self.ways, self.builtAt = key, ways, Clock()
        self.version = self.version + 1
        if done then pcall(done, ways) end
    end

    local function Work()
        if run ~= self.run then return end
        local stop = looked + Shuffle.BUDGET
        while head <= #queue and (now or looked < stop) do
            local node = queue[head]
            queue[head] = false
            head = head + 1
            looked = looked + 1

            local ok = pcall(self.Ends, self, node, start, cache, found)
            if ok and #node.crafts < Shuffle.DEPTH and looked < Shuffle.MAX_NODES then
                for _, entry in ipairs(index[node.itemID] or {}) do
                    local fine, made = pcall(self.Craft, self, node, entry, cache)
                    if fine and made then queue[#queue + 1] = made end
                end
            end
            if looked >= Shuffle.MAX_NODES then head = #queue + 1 end
        end
        if head > #queue then
            Done()
        elseif type(C_Timer) == "table" and C_Timer.After then
            C_Timer.After(0, Work)
        else
            now = true
            Work()
        end
    end

    Work()
end

--------------------------------------------------------------------------------
-- Buttons
--------------------------------------------------------------------------------

--- True when every craft on the way is one you know.
function Shuffle.CanQueue(way)
    if not way or #way.crafts == 0 then return false end
    for _, craft in ipairs(way.crafts) do
        if not craft.known then return false end
    end
    return true
end

--- Queue each craft on the way. True, or nil and why. The view shows
--- Queue It only when every craft is known.
function Shuffle:Queue(way)
    if not Shuffle.CanQueue(way) then return nil end
    for _, craft in ipairs(way.crafts) do
        local ok, done, why = pcall(ns.Queue.Ensure, ns.Queue, craft.recipeID, craft.crafts)
        if not ok then return nil, nil end
        if not done then return nil, why end
    end
    return true
end

--- Put the start and the materials to buy on a shopping list named for the
--- start, set to what the way needs, so a second click never doubles it.
-- @return the list's index and name, or nil and why
function Shuffle:AddToList(way)
    local lists = ns.ShoppingLists
    if not (way and lists and lists.All and lists.Make and lists.Add) then
        return nil, L["Shopping lists aren't ready yet."]
    end
    local name = Shuffle.ItemName(way.startID) or tostring(way.startID)
    local index
    for i, list in ipairs(lists:All() or {}) do
        if list.name == name then index = i break end
    end
    if not index then
        local made, why = lists:Make(name)
        if not made then return nil, why or L["Shopping lists aren't ready yet."] end
        index = made
    end

    local function Put(itemID, want)
        want = math.ceil(want)
        if want < 1 then return end
        if not (lists.SetWant and lists:SetWant(index, itemID, want)) then lists:Add(index, itemID, want) end
    end
    Put(way.startID, way.startCount)
    for itemID, count in pairs(way.buys or {}) do Put(itemID, count) end
    local list = lists.Get and lists:Get(index)
    return index, type(list) == "table" and list.name or name
end

--- How many disenchants your odds come from, all told.
function Shuffle.BrokenSoFar()
    local log = ns.DisenchantLog
    local ok, data = pcall(function() return log and log:GetTable() end)
    local total = 0
    for _, entry in pairs(ok and type(data) == "table" and type(data.items) == "table" and data.items or {}) do
        total = total + (type(entry) == "table" and tonumber(entry.casts) or 0)
    end
    return total
end
