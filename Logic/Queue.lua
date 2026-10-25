-- Blackthornes Tradeskills -- Logic/Queue.lua
-- The craft queue and the shopping list derived from it.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Queue = ns.NewModule("Queue")

--------------------------------------------------------------------------------
-- Entries
--------------------------------------------------------------------------------

function Queue:GetAll()
    return (ns.db and ns.db.queue) or {}
end

function Queue:Count()
    return #self:GetAll()
end

--- @param manualOnly skip derived sub-craft entries
function Queue:Find(recipeID, manualOnly)
    local fallbackIndex, fallback

    for index, entry in ipairs(self:GetAll()) do
        if entry.recipeID == recipeID then
            -- A recipe can be both asked for and required by something
            -- else. The manual entry is the one the player controls.
            if not entry.isDependency then
                return index, entry
            end

            fallbackIndex, fallback = fallbackIndex or index, fallback or entry
        end
    end

    if manualOnly then return nil end
    return fallbackIndex, fallback
end

-- How far to chase "this reagent is cheaper to make than to buy". Matches the
-- depth the cost engine itself recurses to.
local MAX_DEPENDENCY_DEPTH = 3

--------------------------------------------------------------------------------
-- Who makes what
--------------------------------------------------------------------------------

-- The queue is shared by every character on the account. Each craft
-- remembers who queued it (`owner`), and each sub-craft who makes it
-- (`crafter`) and for whom (`forCharacters`), so the plan reads the same
-- whichever character is logged in: Ana queues a bag, her tailor alt is
-- given the bolts, and logging into the tailor shows them as made for Ana.

-- Set with the list to buy, further down; Queue:Add calls it.
local DropBuysFor

local function SelfKey()
    return ns.Config.GetCharacterKey and ns.Config:GetCharacterKey() or nil
end

local function CharacterRecord(characterKey)
    local characters = ns.db and ns.db.characters
    local record = characterKey and characters and characters[characterKey]
    if type(record) == "table" then return record end
end

--- Are sub-crafts given to whichever character makes them for less?
-- Only when switched on in Settings. Off, or with no characters on record,
-- the queue only ever plans for the character logged in, and the shopping
-- list recommends the other character instead.
function Queue:SharesWithAlts()
    if ns.Config:Get("queueAltCrafting") ~= true then return false end
    return CharacterRecord(SelfKey()) ~= nil
end

--- Can one character mail the other? The same realm, and the same faction
--- where both are known.
function Queue:CanMail(fromKey, toKey)
    if fromKey == toKey then return true end

    local from, to = CharacterRecord(fromKey), CharacterRecord(toKey)
    if not (from and to) then return false end

    if from.realm and to.realm and from.realm ~= to.realm then return false end
    if from.faction and to.faction and from.faction ~= to.faction then return false end
    return true
end

--- Does this character know the recipe, in a profession it still has?
function Queue:Knows(characterKey, recipeID)
    local record = CharacterRecord(characterKey)
    local recipe = record and record.recipes and record.recipes[recipeID]
    if not recipe then return false end

    if ns.Recipes.IsDropped and ns.Recipes:IsDropped(recipe, characterKey) then
        return false
    end
    return true
end

--- Every character on record, in a fixed order, so a choice between two
--- equal ones is the same whoever is logged in.
local function SortedCharacterKeys()
    local keys = {}
    for characterKey, record in pairs((ns.db and ns.db.characters) or {}) do
        if type(record) == "table" then keys[#keys + 1] = characterKey end
    end
    table.sort(keys)
    return keys
end

--- Which character makes this queued craft.
--
-- A sub-craft says. A craft you queued is made by whoever queued it when
-- they know it, else by another character who does and can mail it back.
-- A craft queued before owners were kept is made here when this character
-- knows it.
function Queue:GetCrafter(entry)
    if entry.crafter then return entry.crafter end

    local owner = entry.owner
    if owner and self:Knows(owner, entry.recipeID) then return owner end

    local selfKey = SelfKey()
    if not owner and self:Knows(selfKey, entry.recipeID) then return selfKey end

    for _, characterKey in ipairs(SortedCharacterKeys()) do
        if self:Knows(characterKey, entry.recipeID)
            and (not owner or self:CanMail(characterKey, owner)) then
            return characterKey
        end
    end

    local _, knownBy = ns.Recipes:GetAny(entry.recipeID)
    return knownBy or owner or selfKey
end

--- Who a queued craft is for, other than the character making it.
-- @return list of character keys in a fixed order, empty when it is the
--   crafter's own
function Queue:GetRecipients(entry)
    local crafter = self:GetCrafter(entry)
    local seen, list = {}, {}

    local function add(characterKey)
        if characterKey and characterKey ~= crafter and not seen[characterKey] then
            seen[characterKey] = true
            list[#list + 1] = characterKey
        end
    end

    for characterKey in pairs(entry.forCharacters or {}) do add(characterKey) end
    table.sort(list)

    -- A craft you queued that another character makes goes back to you.
    if not entry.isDependency then add(entry.owner) end

    return list
end

--- How many of an item a character holds: bags, bank and, unless switched
--- off, mailbox. Live for the character logged in; for anyone else as last
--- seen, plus what has been mailed to them since.
function Queue:HeldBy(characterKey, itemID)
    if not characterKey or characterKey == SelfKey() then
        -- Mail an alt sent here counts until the mailbox is read, as it does
        -- for any other character. Logged in before opening the mailbox, the
        -- crafter saw none of the Medium Leather sent to it and the queue
        -- made it again, with its Light Leather to mail (2026-10-11).
        local held = ns.Inventory:GetOwnedCount(itemID)
        if ns.QueueMail and ns.QueueMail.InFlight then
            held = held + ns.QueueMail:InFlight(characterKey or SelfKey(), itemID)
        end
        return held
    end

    local record = CharacterRecord(characterKey)
    if not record then return 0 end

    local held = ((record.inventory and record.inventory[itemID]) or 0)
        + ((record.bank and record.bank[itemID]) or 0)

    if ns.Config:Get("countMailAsStock") ~= false then
        held = held + ((record.mail and record.mail[itemID]) or 0)
    end

    if ns.QueueMail and ns.QueueMail.InFlight then
        held = held + ns.QueueMail:InFlight(characterKey, itemID)
    end

    return held
end

--- How much of what HeldBy counts is mail: in the character's mailbox, or
--- sent to it and not yet seen arrive. Counted the same way HeldBy counts
--- it, so HeldBy less this is what its bags and bank hold. Butler's jobs
--- put a mailbox visit first when a craft counts on it (2026-10-13).
function Queue:InMailFor(characterKey, itemID)
    local inMail = 0
    if not characterKey or characterKey == SelfKey() then
        if ns.Inventory and ns.Inventory.GetMailCount then
            inMail = ns.Inventory:GetMailCount(itemID) or 0
        end
    else
        local record = CharacterRecord(characterKey)
        if record and ns.Config:Get("countMailAsStock") ~= false then
            inMail = (record.mail and record.mail[itemID]) or 0
        end
    end
    if ns.QueueMail and ns.QueueMail.InFlight then
        inMail = inMail + ns.QueueMail:InFlight(characterKey or SelfKey(), itemID)
    end
    return inMail
end

--- Every recipe every character knows, by the item it makes.
local function MakersByOutput()
    local byOutput = {}

    for _, characterKey in ipairs(SortedCharacterKeys()) do
        local record = CharacterRecord(characterKey)
        for recipeID, recipe in pairs(record.recipes or {}) do
            local itemID = type(recipe) == "table" and recipe.outputItemID
            local dropped = itemID and ns.Recipes.IsDropped
                and ns.Recipes:IsDropped(recipe, characterKey)
            -- Nor a craft marked never to make as a sub-craft (Cost.lua).
            local never = ns.Cost.IsNeverSubCraft and ns.Cost:IsNeverSubCraft(recipeID)
            if itemID and not dropped and not never then
                local list = byOutput[itemID] or {}
                list[#list + 1] = { characterKey = characterKey, recipeID = recipeID, recipe = recipe }
                byOutput[itemID] = list
            end
        end
    end

    -- pairs() gives a character's recipes in no fixed order.
    for _, list in pairs(byOutput) do
        table.sort(list, function(a, b)
            if a.characterKey ~= b.characterKey then return a.characterKey < b.characterKey end
            return a.recipeID < b.recipeID
        end)
    end

    return byOutput
end

--- What mailing a material costs for each one made, when the one making it
--- is not the one using it: a stamp a stack attached (QueueMail.POSTAGE),
--- for each character it goes to. 0 when nobody needs a mail.
function Queue.PostagePerUnit(itemID, need, makerKey)
    local units = need and tonumber(need.units) or 0
    if units <= 0 then return 0 end
    local mails = 0
    for crafter in pairs(need.crafters or {}) do
        if crafter ~= makerKey then mails = mails + 1 end
    end
    if mails == 0 then return 0 end
    local stack = ns.BagsFull and ns.BagsFull.MaxStack and ns.BagsFull.MaxStack(itemID)
    stack = math.max(1, tonumber(stack) or 1)
    local stamp = ns.QueueMail and ns.QueueMail.POSTAGE or 30
    return mails * math.ceil(units / stack) * stamp / units
end

--- Who should make a material, when making it beats buying it.
--
-- Only characters who can mail it to everyone who needs it. Something that
-- binds when picked up cannot be mailed, so only a character who needs it
-- can make it. Among those who can, the character who needs it comes first
-- (nothing to send), then the one who queued the craft, then the cheapest,
-- then a fixed order.
--
-- A material the queue was already making (`keep`, from the last plan) stays
-- with whoever was making it when buying it has since become cheaper, and the
-- answer says so with `buyCheaper`. See RebuildDependencies.
--
-- @param need { crafters = { [key] = true }, owner }
-- @param keep { recipeID, crafter } or nil
-- @return { characterKey, recipeID, recipe, buyCheaper } or nil to buy it
function Queue:PickMaker(itemID, need, makers, keep)
    local candidates = makers[itemID]
    if not candidates then return nil end

    local bound = ns.Util and ns.Util.IsBoundOnPickup
        and ns.Util.IsBoundOnPickup(itemID) == true
    local buyUnit = ns.Cost:GetReagentUnitCost(itemID)
    -- Set to Make on the Level Up tab: made whatever buying costs.
    if ns.Cost.ItemChoice and ns.Cost:ItemChoice(itemID) == "make" then buyUnit = nil end

    local best, kept
    for _, candidate in ipairs(candidates) do
        local reachable = true
        for crafter in pairs(need.crafters) do
            if bound then
                reachable = reachable and candidate.characterKey == crafter
            else
                reachable = reachable and self:CanMail(candidate.characterKey, crafter)
            end
        end

        if reachable then
            local cost = ns.Cost:GetCraftCost(candidate.recipeID)
            local unit = cost and cost.priceable and cost.perUnit
            -- Made on another character, it has to be mailed: count the
            -- postage, so an alt only makes it when that still beats buying
            -- (the owner, 2026-10-20).
            if unit then unit = unit + Queue.PostagePerUnit(itemID, need, candidate.characterKey) end

            if unit and (not buyUnit or unit < buyUnit) then
                local rank = need.crafters[candidate.characterKey] and 0
                    or (candidate.characterKey == need.owner and 1) or 2

                if not best or rank < best.rank
                    or (rank == best.rank and unit < best.unit) then
                    best = { characterKey = candidate.characterKey, recipeID = candidate.recipeID,
                        recipe = candidate.recipe, rank = rank, unit = unit }
                end
            elseif keep and candidate.characterKey == keep.crafter
                and candidate.recipeID == keep.recipeID then
                kept = { characterKey = candidate.characterKey, recipeID = candidate.recipeID,
                    recipe = candidate.recipe, buyCheaper = true }
            end
        end
    end

    return best or kept
end

--- How many of a material are still short once what is held is used.
--
-- One material can be needed at two levels: Copper Bars for a Copper
-- Modulator and for the Copper Bolts that go into it. Each level used to
-- take the whole of what you hold off its own need, so the same bars were
-- counted twice, too few were queued, and a second trip to the forge came
-- later. What one level takes is now gone for the next.
-- @param pool [itemID] = held and not yet used, filled as it goes
-- @param held what is held now, as this level counts it
-- @return the shortfall, never below 0
local function HeldPool(pool, itemID, held, units)
    local free = pool[itemID]
    if free == nil then free = held else free = math.min(free, held) end
    free = math.max(0, free or 0)
    pool[itemID] = math.max(0, free - units)
    return math.max(0, units - free)
end

--- The sub-crafts for every character at once (see SharesWithAlts).
--
-- The same walk as for one character: requirements summed per material over
-- each level, the shortfall made into crafts. What differs is who makes them
-- and what counts as already held: what everyone the material is for holds,
-- and what the one making it holds, since what they made waits to be sent.
local BoughtBeyondMail

function Queue:DeriveAcrossCharacters(manual, derived, maxDepth, planned)
    local makers = MakersByOutput()
    planned = planned or {}
    local selfKey = SelfKey()
    -- What is held of each material and not yet spoken for (see HeldPool).
    local pool = {}

    local function process(entries, depth)
        if depth >= maxDepth or #entries == 0 then return end

        local needs, order = {}, {}

        for _, entry in ipairs(entries) do
            local recipe = ns.Recipes:GetAny(entry.recipeID)
            local crafter = self:GetCrafter(entry)

            for _, reagent in ipairs((recipe and recipe.reagents) or {}) do
                local need = needs[reagent.itemID]
                if not need then
                    need = { units = 0, parents = {}, crafters = {} }
                    needs[reagent.itemID] = need
                    order[#order + 1] = reagent.itemID
                end

                need.units = need.units + reagent.quantity * entry.quantity
                need.parents[entry.recipeID] = true
                need.crafters[crafter] = true
                need.owner = need.owner or entry.owner
            end
        end

        -- A fixed order, so the same queue always derives the same plan.
        table.sort(order)

        local nextLevel = {}

        for _, itemID in ipairs(order) do
            local need = needs[itemID]
            local maker = self:PickMaker(itemID, need, makers, planned[itemID])

            if maker then
                local held = 0
                for characterKey in pairs(need.crafters) do
                    held = held + self:HeldBy(characterKey, itemID)
                end
                if not need.crafters[maker.characterKey] then
                    held = held + self:HeldBy(maker.characterKey, itemID)
                end
                -- The single-character plan counts auction buys still in
                -- the mail as held; this one left them out, so a material
                -- just bought was queued as a sub-craft all the same.
                if need.crafters[selfKey] or maker.characterKey == selfKey then
                    held = held + BoughtBeyondMail(itemID)
                end

                local short = HeldPool(pool, itemID, held, need.units)

                if short > 0 then
                    local perCraft = math.max(1, maker.recipe.quantityMin or 1)

                    local entry = {
                        recipeID = maker.recipeID,
                        quantity = math.ceil(short / perCraft),
                        isDependency = true,
                        forRecipes = need.parents,
                        forCharacters = need.crafters,
                        crafter = maker.characterKey,
                        owner = need.owner,
                        buyCheaper = maker.buyCheaper or nil,
                        depth = depth,
                        addedAt = time(),
                    }

                    derived[#derived + 1] = entry
                    nextLevel[#nextLevel + 1] = entry
                end
            end
        end

        process(nextLevel, depth + 1)
    end

    process(manual, 0)
end

--- What a character makes for someone else.
-- @return list of { entry, recipients = { keys } }
function Queue:GetHelping(characterKey)
    characterKey = characterKey or SelfKey()
    local list = {}

    for _, entry in ipairs(self:GetAll()) do
        if self:GetCrafter(entry) == characterKey then
            local recipients = self:GetRecipients(entry)
            if #recipients > 0 then
                list[#list + 1] = { entry = entry, recipients = recipients }
            end
        end
    end

    return list
end

local function ShortName(characterKey)
    if ns.Recipes.GetShortCharacterName then
        return ns.Recipes:GetShortCharacterName(characterKey)
    end
    return ns.Recipes:GetCharacterName(characterKey)
end

function Queue:JoinNames(keys)
    local names = {}
    for index, characterKey in ipairs(keys) do names[index] = ShortName(characterKey) end
    return table.concat(names, ", ")
end

--- Who a queued craft is for and who makes it, as the character logged in
--- sees it. Longest wording first, so a row can use the first that fits.
-- @return list of texts, empty when it is all this character's own
function Queue:DescribeWho(entry)
    local viewer = SelfKey()
    local crafter = self:GetCrafter(entry)
    local recipients = self:GetRecipients(entry)

    local others = {}
    for _, characterKey in ipairs(recipients) do
        if characterKey ~= viewer then others[#others + 1] = characterKey end
    end

    local texts = {}

    if crafter == viewer then
        if #others > 0 then
            local names = self:JoinNames(others)
            texts[#texts + 1] = L.Format("you make this for %s", names)
            texts[#texts + 1] = L.Format("for %s", names)
        end
        return texts
    end

    local maker = ShortName(crafter)
    if #others > 0 then
        local names = self:JoinNames(others)
        texts[#texts + 1] = L.Format("%s makes this for %s", maker, names)
        texts[#texts + 1] = L.Format("%s, for %s", maker, names)
    elseif #recipients > 0 then
        texts[#texts + 1] = L.Format("%s makes this for you", maker)
    else
        texts[#texts + 1] = L.Format("%s's craft", maker)
    end
    texts[#texts + 1] = L.Format("on %s", maker)

    return texts
end

--- Rebuild every sub-craft in the queue from the crafts you actually asked for.
--
-- Dependencies are derived, never stored independently. Storing them would mean
-- keeping them in step with the parents by hand: remove a parent and its
-- sub-craft is orphaned, halve a parent and the sub-craft is now wrong. Deriving
-- them makes both impossible, and handles two parents needing the same reagent
-- without double-counting.
--
-- Deeper dependencies are placed first, so the queue reads in the order you can
-- actually work through it.
--- Auction buys still in the mail that a mail count of `inMail` does not
--- already hold: all of them when no mail was counted, otherwise those
--- bought since the mailbox was read, or the excess over what it showed.
--- With no count given, the mailbox's own is used.
function BoughtBeyondMail(itemID, inMail)
    local buys = ns.AHBuys
    if not buys then return 0 end
    local pending = buys:GetPending(itemID)
    if pending <= 0 then return 0 end
    if inMail == nil then inMail = ns.Inventory:GetMailCount(itemID) end
    if (inMail or 0) <= 0 then return pending end
    return math.max(buys:GetUnread(itemID), pending - inMail, 0)
end

--- The profession a queued craft is made in, by English name, so the
--- same profession under its two skill lines is one. "?" when unknown.
function Queue:ProfessionOf(entry)
    local recipe = entry and ns.Recipes:GetAny(entry.recipeID)
    local line = recipe and recipe.skillLineID
    local names = ns.Recipes.SKILL_LINE_PROFESSIONS
    if line == nil then return "?" end
    return (names and names[line]) or tostring(line)
end

--- One sub-craft per recipe and crafter.
--
-- A material needed at two levels (Copper Bars for a Copper Modulator and
-- for the Copper Bolts that go in it) was queued twice, once at each
-- level, and the two rows sat apart with the bolts between them: bars, then
-- bolts, then bars again. They are one row now, at the deeper of the two
-- levels, for everything both were for.
local function MergeSubCrafts(derived)
    local merged, byKey = {}, {}
    for _, entry in ipairs(derived) do
        local key = tostring(entry.recipeID) .. "|" .. tostring(entry.crafter)
        local into = byKey[key]
        if not into then
            local forRecipes, forCharacters = {}, nil
            for id in pairs(entry.forRecipes or {}) do forRecipes[id] = true end
            if entry.forCharacters then
                forCharacters = {}
                for id in pairs(entry.forCharacters) do forCharacters[id] = true end
            end
            entry.forRecipes, entry.forCharacters = forRecipes, forCharacters
            byKey[key] = entry
            merged[#merged + 1] = entry
        else
            into.quantity = into.quantity + entry.quantity
            into.depth = math.max(into.depth or 0, entry.depth or 0)
            for id in pairs(entry.forRecipes or {}) do into.forRecipes[id] = true end
            if entry.forCharacters then
                into.forCharacters = into.forCharacters or {}
                for id in pairs(entry.forCharacters) do into.forCharacters[id] = true end
            end
            -- Kept only while buying is cheaper for every part of it.
            into.buyCheaper = (into.buyCheaper and entry.buyCheaper) or nil
            into.owner = into.owner or entry.owner
        end
    end
    return merged
end

--- The sub-crafts in the order to make them.
--
-- A player found the queue sending them from the forge to the anvil and
-- back (2026-10-19). Sub-crafts are now grouped by profession: one that
-- makes things for another comes first (every bar is smelted before any
-- Blacksmithing or Engineering part), and a profession's crafts stay
-- together. Within a profession, deepest first, then by recipe, so a
-- rebuild never moves rows around. A craft is never placed before a
-- sub-craft of its own.
local function OrderSubCrafts(derived, manual)
    local profession, deepest = {}, {}
    for _, entry in ipairs(derived) do
        local name = Queue:ProfessionOf(entry)
        profession[entry] = name
        deepest[name] = math.max(deepest[name] or 0, (entry.depth or 0) + 1)
    end
    for _, entry in ipairs(manual) do
        local name = Queue:ProfessionOf(entry)
        profession[entry] = name
        deepest[name] = deepest[name] or 0
    end

    -- Who each sub-craft is for, by recipe.
    local byRecipe = {}
    for _, list in ipairs({ derived, manual }) do
        for _, entry in ipairs(list) do
            byRecipe[entry.recipeID] = byRecipe[entry.recipeID] or {}
            table.insert(byRecipe[entry.recipeID], entry)
        end
    end

    -- Which professions feed which: Mining into Blacksmithing and so on.
    local feeds, waitsOn = {}, {}
    for name in pairs(deepest) do feeds[name], waitsOn[name] = {}, 0 end
    local children = {}
    for _, entry in ipairs(derived) do
        for parentID in pairs(entry.forRecipes or {}) do
            for _, parent in ipairs(byRecipe[parentID] or {}) do
                if parent ~= entry then
                    children[parent] = (children[parent] or 0) + 1
                    local from, to = profession[entry], profession[parent]
                    if from ~= to and not feeds[from][to] then
                        feeds[from][to] = true
                        waitsOn[to] = waitsOn[to] + 1
                    end
                end
            end
        end
    end

    local function Earlier(a, b)
        if deepest[a] ~= deepest[b] then return deepest[a] > deepest[b] end
        return a < b
    end

    -- Professions in order: one nothing left feeds, the deepest first. A
    -- loop (two professions feeding each other) falls back to the deepest.
    local rank, left = {}, {}
    for name in pairs(deepest) do left[#left + 1] = name end
    while #left > 0 do
        local pick, pickIndex, free
        for index, name in ipairs(left) do
            local isFree = waitsOn[name] <= 0
            local better
            if not pick then better = true
            elseif isFree ~= free then better = isFree
            else better = Earlier(name, pick) end
            if better then pick, pickIndex, free = name, index, isFree end
        end
        table.remove(left, pickIndex)
        rank[pick] = #left
        for to in pairs(feeds[pick]) do waitsOn[to] = waitsOn[to] - 1 end
    end
    -- rank counts down as picked, so a bigger number goes first.

    local function Before(a, b)
        local ra, rb = rank[profession[a]], rank[profession[b]]
        if ra ~= rb then return ra > rb end
        if (a.depth or 0) ~= (b.depth or 0) then return (a.depth or 0) > (b.depth or 0) end
        if a.recipeID ~= b.recipeID then return a.recipeID < b.recipeID end
        return tostring(a.crafter) < tostring(b.crafter)
    end

    -- Placed one at a time: of the sub-crafts whose own sub-crafts are all
    -- placed, the first by Before. A loop places the first left.
    local ordered, placed = {}, {}
    for _ = 1, #derived do
        local pick
        for _, entry in ipairs(derived) do
            if not placed[entry] and (children[entry] or 0) == 0
                and (not pick or Before(entry, pick)) then
                pick = entry
            end
        end
        if not pick then
            for _, entry in ipairs(derived) do
                if not placed[entry] and (not pick or Before(entry, pick)) then pick = entry end
            end
        end
        placed[pick] = true
        ordered[#ordered + 1] = pick
        for parentID in pairs(pick.forRecipes or {}) do
            for _, parent in ipairs(byRecipe[parentID] or {}) do
                if parent ~= pick and children[parent] then
                    children[parent] = children[parent] - 1
                end
            end
        end
    end
    return ordered
end

function Queue:RebuildDependencies()
    local queue = self:GetAll()

    -- Everything the player asked for directly. Dependencies are discarded and
    -- recalculated from these.
    local manual = {}
    for _, entry in ipairs(queue) do
        if not entry.isDependency then
            manual[#manual + 1] = entry
        end
    end

    -- What the last plan was making, by the item it makes. A player on
    -- Discord (2026-10-05): halfway through turning scraps into light
    -- leather, buying medium leather became cheaper than making it, so the
    -- medium leather dropped off the queue, the light leather with it, and
    -- the leather already made had nothing left to go into. A sub-craft
    -- already planned now stays when buying turns cheaper, marked
    -- `buyCheaper` so the queue can say so; Buy instead (BuyInstead) takes it
    -- off. Only what was planned: a material the queue was not making is
    -- still only made when that is cheaper.
    local planned = {}
    for _, entry in ipairs(queue) do
        local recipe = entry.isDependency and ns.Recipes:GetAny(entry.recipeID)
        if recipe and recipe.outputItemID then
            planned[recipe.outputItemID] = {
                recipeID = entry.recipeID,
                crafter = entry.crafter,
                buyCheaper = entry.buyCheaper,
            }
        end
    end

    local derived = {}

    if ns.Config:Get("autoQueueSubCrafts") ~= false and self:SharesWithAlts() then
        self:DeriveAcrossCharacters(manual, derived, MAX_DEPENDENCY_DEPTH, planned)
    elseif ns.Config:Get("autoQueueSubCrafts") ~= false then
        local selfKey = SelfKey()
        local pool = {}

        local function process(entries, depth)
            if depth >= MAX_DEPENDENCY_DEPTH or #entries == 0 then return end

            -- Sum requirements across everything at this level first, so a
            -- reagent needed by two crafts is counted once, not twice.
            local needs = {}

            for _, entry in ipairs(entries) do
                local cost = ns.Cost:GetCraftCost(entry.recipeID)

                for _, reagent in ipairs((cost and cost.reagents) or {}) do
                    -- `crafted` means the cost engine found making it
                    -- cheaper. One already being made stays (see above).
                    if reagent.crafted or planned[reagent.itemID] then
                        local need = needs[reagent.itemID]
                            or { units = 0, parents = {} }

                        need.units = need.units + (reagent.quantity * entry.quantity)
                        need.parents[entry.recipeID] = true
                        need.cheaper = need.cheaper or reagent.crafted

                        needs[reagent.itemID] = need
                    end
                end
            end

            local nextLevel = {}

            for itemID, need in pairs(needs) do
                local subRecipeID = ns.Cost:FindRecipeForItem(itemID)
                local subRecipe = subRecipeID and ns.Recipes:GetAny(subRecipeID)

                if subRecipe then
                    local short = HeldPool(pool, itemID,
                        ns.Inventory:GetOwnedCount(itemID) + BoughtBeyondMail(itemID), need.units)

                    if short > 0 then
                        -- Missing units become crafts, since one craft can
                        -- produce several.
                        local perCraft = math.max(1, subRecipe.quantityMin or 1)

                        local entry = {
                            recipeID = subRecipeID,
                            quantity = math.ceil(short / perCraft),
                            isDependency = true,
                            forRecipes = need.parents,
                            crafter = selfKey,
                            buyCheaper = (not need.cheaper) or nil,
                            depth = depth,
                            addedAt = time(),
                        }

                        derived[#derived + 1] = entry
                        nextLevel[#nextLevel + 1] = entry
                    end
                end
            end

            process(nextLevel, depth + 1)
        end

        process(manual, 0)
    end

    -- A sub-craft's own sub-crafts come before it, and each profession's
    -- sub-crafts are done together (OrderSubCrafts).
    derived = OrderSubCrafts(MergeSubCrafts(derived), manual)

    for index = #queue, 1, -1 do
        queue[index] = nil
    end

    for _, entry in ipairs(derived) do
        queue[#queue + 1] = entry
    end

    for _, entry in ipairs(manual) do
        queue[#queue + 1] = entry
    end

    -- Said once, when buying first turns cheaper, not on every rebuild.
    for _, entry in ipairs(derived) do
        local recipe = entry.buyCheaper and ns.Recipes:GetAny(entry.recipeID)
        local before = recipe and planned[recipe.outputItemID]
        if before and not before.buyCheaper then
            local name = ns.Recipes.GetDisplayLink and ns.Recipes:GetDisplayLink(entry.recipeID)
                or recipe.name or L["a sub-craft"]
            ns.Print(L.Format("buying %s is now cheaper than making it. It stays on the queue. Click Buy instead on the Queue tab to take it off.",
                name))
        end
    end
end

--- Take a sub-craft off the queue and buy its item instead.
--
-- For a sub-craft kept after buying turned cheaper (`buyCheaper`). Its item
-- goes back on the shopping list, and whatever only went into it leaves the
-- queue too. If making it turns cheaper again, it comes back like any other.
-- Every sub-craft row making the same item goes: one item often goes into
-- two crafts (light leather into medium leather and into boots), and a row
-- left behind kept the item planned, so the rebuild put the clicked row
-- straight back and the button seemed to do nothing (2026-10-09).
function Queue:BuyInstead(entry)
    local queue = self:GetAll()
    if not (entry and entry.recipeID) then return false end

    -- A rebuild makes new sub-craft rows, so a row clicked before its redraw
    -- holds an old one; the queued sub-craft of the same recipe stands in.
    local present = false
    for index = 1, #queue do
        local other = queue[index]
        if other == entry or (entry.isDependency and other.isDependency
            and other.recipeID == entry.recipeID) then
            present = true
            break
        end
    end
    if not present then return false end

    local recipe = ns.Recipes:GetAny(entry.recipeID)
    local output = recipe and recipe.outputItemID

    local function sameItem(other)
        if other == entry then return true end
        if not (entry.isDependency and other.isDependency) then return false end
        if other.recipeID == entry.recipeID then return true end
        local otherRecipe = output and ns.Recipes:GetAny(other.recipeID)
        return otherRecipe ~= nil and otherRecipe.outputItemID == output
    end

    for index = #queue, 1, -1 do
        if sameItem(queue[index]) then table.remove(queue, index) end
    end

    self:RebuildDependencies()
    self:Notify()
    return true
end

--- Never make this sub-craft again: buy its item instead, now and from now
--- on (Cost:SetNeverSubCraft). The x on a sub-craft's row in the Queue tab
--- and the craft pane. Settings > Queue lists it, with Allow to undo.
function Queue:NeverMake(entry)
    if not (entry and entry.isDependency) then return false end

    local recipe = ns.Recipes:GetAny(entry.recipeID)
    local name = (recipe and recipe.name) or L.Format("recipe %s", tostring(entry.recipeID))
    ns.Cost:SetNeverSubCraft(entry.recipeID, true, recipe and recipe.name)

    ns.Print(L.Format("%s is no longer made as a sub-craft. The queue buys it instead. To undo it, click Allow under Settings, Queue, Never made as sub-crafts.",
        name))
    return true
end

--- The hover for the x on a sub-craft's row.
function Queue:NeverMakeTooltip(entry)
    local recipe = entry and ns.Recipes:GetAny(entry.recipeID)
    local name = (recipe and recipe.name) or L["this"]
    return L.Format("Never make %s as a sub-craft", name) .. "\n"
        .. L["Buys it instead from now on. You can still queue it on its own. Undo it with Allow in Settings, Queue."]
end

--- What one of a sub-craft's items costs to buy and to make, for the note
--- on a kept sub-craft.
-- @return buy, make  (copper each, either nil when unknown)
function Queue:GetBuyOrMake(entry)
    local recipe = entry and ns.Recipes:GetAny(entry.recipeID)
    if not (recipe and recipe.outputItemID) then return nil, nil end

    local buy = ns.Cost:GetReagentUnitCost(recipe.outputItemID)
    local cost = ns.Cost:GetCraftCost(entry.recipeID)
    return buy, cost and cost.priceable and cost.perUnit or nil
end

--- Re-derive the sub-crafts for the character just logged in.
--
-- The queue is shared by every character, but which materials are cheaper to
-- make depends on who is making them. Sub-crafts were only re-derived when the
-- queue changed, so logging into the tailor the Queue tab had suggested left
-- the bolts off its queue. With "Suggest other characters" on, that character
-- now finds the bolts queued and their wool on the shopping list, and the one
-- that cannot make them goes back to buying them.
function Queue:OnEnable()
    if ns.Config:Get("suggestOtherCharacters") == false
        and ns.Config:Get("queueAltCrafting") ~= true then return end
    if not (C_Timer and C_Timer.After) then return end

    -- A moment's grace so the bags have been read: sub-crafts are sized
    -- against what is already owned.
    C_Timer.After(3, function() Queue:RefreshForCharacter() end)
end

--- Rebuild the sub-crafts and say which ones this character now makes.
-- @return the sub-craft entries that were not in the queue before
function Queue:RefreshForCharacter()
    if self:Count() == 0 then return {} end

    local before = {}
    for _, entry in ipairs(self:GetAll()) do
        if entry.isDependency then before[entry.recipeID] = true end
    end

    self:RebuildDependencies()

    -- Shared, the plan does not change with who logs in, so what this
    -- character makes for the others is what it is told.
    local shared = self:SharesWithAlts()
    if shared then self:AnnounceHelping() end

    local added = {}
    for _, entry in ipairs(self:GetAll()) do
        if entry.isDependency and not before[entry.recipeID] and shared then
            added[#added + 1] = entry
        elseif entry.isDependency and not before[entry.recipeID] then
            added[#added + 1] = entry

            local recipe = ns.Recipes:GetAny(entry.recipeID)
            local parents = self:GetDependencyParents(entry)

            ns.Print(L.Format("queued %d x %s for %s. This character can make it for less than it costs to buy, so its materials are on the shopping list.",
                entry.quantity, (recipe and recipe.name) or L["a sub-craft"],
                    #parents > 0 and table.concat(parents, ", ") or L["another craft"]))
        end
    end

    self:Notify()
    return added
end

-- More than this many lines at login is a wall of chat; the rest are counted.
local HELPING_LINES = 4

--- Tell this character what it makes for the others, once at login.
function Queue:AnnounceHelping()
    local helping = self:GetHelping()
    if #helping == 0 then return end

    for index, help in ipairs(helping) do
        if index > HELPING_LINES then
            ns.Print(L.Format("and %d more for your other characters. The Queue tab has them all.",
                #helping - HELPING_LINES))
            break
        end

        local entry = help.entry
        local recipe = ns.Recipes:GetAny(entry.recipeID)
        local name = (recipe and recipe.name) or L["a craft"]
        local parents = entry.isDependency and self:GetDependencyParents(entry) or {}

        if #parents > 0 then
            ns.Print(L.Format("helping %s: make %d x %s for %s.", self:JoinNames(help.recipients),
                entry.quantity, name, table.concat(parents, ", ")))
        else
            ns.Print(L.Format("helping %s: make %d x %s.", self:JoinNames(help.recipients),
                entry.quantity, name))
        end
    end
end

--- The crafts this dependency exists to serve, for display.
function Queue:GetDependencyParents(entry)
    local names = {}

    for parentID in pairs(entry.forRecipes or {}) do
        local parent = ns.Recipes:GetAny(parentID)
        names[#names + 1] = (parent and parent.name) or L["another craft"]
    end

    table.sort(names)
    return names
end

--- Add crafts to the queue, merging into an existing entry for the same recipe.
--
-- The cost and profit at the moment of queueing are recorded so the queue can
-- later say "this was worth 4g when you queued it, it is worth 40s now" rather
-- than quietly re-pricing and pretending nothing changed.
--
-- @param options { depth, forRecipeID } -- internal, for dependency queueing
function Queue:Add(recipeID, quantity, options)
    quantity = tonumber(quantity) or 1
    -- "1e999" typed into a box is a number, an endless one; saved, every
    -- "%d" that showed the queue would raise from then on.
    if quantity ~= quantity or quantity == math.huge or quantity == -math.huge then
        return nil, L["that is not a quantity"]
    end
    quantity = math.max(1, math.floor(quantity))
    options = options or {}

    -- GetAny: an alt's craft can be queued from the account-wide view, and
    -- the Craft button reports whose character it needs.
    local recipe = ns.Recipes:GetAny(recipeID)
    if not recipe then return false end

    local analysis = ns.Profit:Analyse(recipeID)

    -- Queued to make: whatever was on the list to buy for it now comes from
    -- the craft's own materials.
    DropBuysFor(recipe.outputItemID)

    local _, existing = self:Find(recipeID, true)
    if existing then
        existing.quantity = existing.quantity + quantity
    else
        local queue = self:GetAll()
        queue[#queue + 1] = {
            recipeID = recipeID,
            quantity = quantity,
            addedAt = time(),
            -- Who queued it. More of the same craft queued on another
            -- character adds to this entry and leaves the first owner.
            owner = SelfKey(),
            snapshotCost = analysis and analysis.totalCost or nil,
            snapshotProfit = analysis and analysis.profit or nil,
        }
    end

    self:RebuildDependencies()
    self:Notify()
    return true
end

--- Queue each of these crafts up to its Max on hand (Keep in stock per item).
--
-- Room is read fresh for every craft rather than taken from the analyses,
-- because two recipes can make the same item and the first one queued uses up
-- the second one's room. A craft with no number set goes up to what your
-- sales taught (Auctions:GetLearnedLimit); one that never sold either is
-- skipped, not queued without end. The queue is rebuilt and announced once,
-- at the end.
--
-- @param analyses list of Profit:Analyse results (the rows on screen)
-- @return crafts queued, items those make, crafts skipped for having no
--         limit, crafts queued on a learned limit
function Queue:AddUpToLimit(analyses)
    local crafts, items, noLimit, learnedCrafts = 0, 0, 0, 0
    local queue = self:GetAll()

    for _, analysis in ipairs(analyses or {}) do
        local recipe = analysis.recipeID and ns.Recipes:GetAny(analysis.recipeID)

        if recipe and recipe.outputItemID then
            local room, _, _, _, _, _, _, _, learned = ns.Auctions:GetRoom(recipe.outputItemID, nil, true)

            if room == nil then
                noLimit = noLimit + 1
            else
                local count = ns.Profit.RoomInCrafts(room, recipe) or 0

                if count > 0 then
                    local _, existing = self:Find(analysis.recipeID, true)
                    if existing then
                        existing.quantity = existing.quantity + count
                    else
                        local current = ns.Profit:Analyse(analysis.recipeID)
                        queue[#queue + 1] = {
                            recipeID = analysis.recipeID,
                            quantity = count,
                            addedAt = time(),
                            owner = SelfKey(),
                            snapshotCost = current and current.totalCost or nil,
                            snapshotProfit = current and current.profit or nil,
                        }
                    end

                    crafts = crafts + count
                    if learned then learnedCrafts = learnedCrafts + count end
                    items = items + count * math.max(1, recipe.quantityMin or 1)
                end
            end
        end
    end

    if crafts > 0 then
        self:RebuildDependencies()
        self:Notify()
    end

    return crafts, items, noLimit, learnedCrafts
end

--- The recipe that makes `itemID`, for queueing another of it: one already
--- in the queue first, then the character playing's own, then an alt's.
function Queue:RecipeFor(itemID)
    for _, entry in ipairs(self:GetAll()) do
        local recipe = not entry.isDependency and ns.Recipes:GetAny(entry.recipeID)
        if recipe and recipe.outputItemID == itemID then return entry.recipeID, recipe end
    end
    for recipeID, recipe in pairs(ns.Recipes:GetAll()) do
        if recipe.outputItemID == itemID then return recipeID, recipe end
    end
    for _, recipe in ipairs(ns.Recipes:GetAccountWideOutputs()) do
        if recipe.outputItemID == itemID and recipe.recipeID then return recipe.recipeID, recipe end
    end
    return nil
end

--- One of your auctions sold: queue one more of it while there is room
--- under Keep in stock, or under what your sales taught when no number is
--- set (the owner, 2026-10-11: stock that tops itself up). Never for a craft
--- that loses money, nor while "Wait until it runs low" is waiting.
--- @return the recipe ID queued, or nil and why: "off", "nocraft",
---   "nostock" (no number to keep), "full", "waiting", "loss" or "failed"
function Queue:RestockSold(itemID)
    if not itemID or ns.Config:Get("restockOnSale") == false then return nil, "off" end
    local recipeID = self:RecipeFor(itemID)
    if not recipeID then return nil, "nocraft" end

    local room, _, _, _, _, _, waiting = ns.Auctions:GetRoom(itemID, nil, true)
    if not room then return nil, "nostock" end
    if waiting then return nil, "waiting" end
    if room <= 0 then return nil, "full" end

    local ok, analysis = pcall(ns.Profit.Analyse, ns.Profit, recipeID)
    if ok and analysis and analysis.profit and analysis.profit <= 0 then return nil, "loss" end

    if self:Add(recipeID, 1) then return recipeID end
    return nil, "failed"
end

function Queue:SetQuantity(recipeID, quantity)
    quantity = math.floor(tonumber(quantity) or 0)

    local index, entry = self:Find(recipeID)
    if not entry then return false end

    if quantity <= 0 then
        table.remove(self:GetAll(), index)
    else
        entry.quantity = quantity
    end

    -- Sub-crafts are sized from the parents, so any change re-derives them.
    self:RebuildDependencies()
    self:Notify()
    return true
end

function Queue:Remove(recipeID)
    local index = self:Find(recipeID)
    if not index then return false end

    table.remove(self:GetAll(), index)

    -- Removing a parent removes whatever only existed to serve it.
    self:RebuildDependencies()
    self:Notify()
    return true
end

function Queue:Clear()
    local queue = self:GetAll()
    for i = #queue, 1, -1 do
        queue[i] = nil
    end
    -- Clear all empties the shopping list too, so nothing is left to buy
    -- for a list the player just threw away.
    self:ClearBuys()
    self:Notify()
end

-- Moves on every change to the queue, so a lookup built from it (Butler's
-- needs) knows when to build again.
Queue.version = 0

--- The queue's sub-crafts in one line, to tell whether a rebuild moved them.
local function DependencyKey(queue)
    local parts = {}
    for _, entry in ipairs(queue) do
        if entry.isDependency then
            parts[#parts + 1] = ("%s:%s:%s"):format(tostring(entry.recipeID),
                tostring(entry.quantity), tostring(entry.crafter))
        end
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

--- Bags changed (Inventory, once per burst, with the items whose count
--- moved). Sub-crafts are sized by what is held, and were only rebuilt
--- when the queue changed or a mail went, so taking the Medium Leather out
--- of the mailbox left its sub-craft, and the Light Leather for it, queued
--- (2026-10-11). Only an item the queue makes or uses rebuilds, and the
--- queue only says it changed when the sub-crafts did.
-- @param changed { [itemID] = true }
-- @return true when the sub-crafts changed
function Queue:HoldingsChanged(changed)
    if type(changed) ~= "table" or next(changed) == nil then return false end
    local queue = self:GetAll()
    if #queue == 0 then return false end

    local touched = false
    for _, entry in ipairs(queue) do
        local recipe = ns.Recipes and ns.Recipes:GetAny(entry.recipeID)
        if recipe then
            if recipe.outputItemID and changed[recipe.outputItemID] then touched = true end
            for _, reagent in ipairs(recipe.reagents or {}) do
                if changed[reagent.itemID] then touched = true break end
            end
        end
        if touched then break end
    end
    if not touched then return false end

    local before = DependencyKey(queue)
    self:RebuildDependencies()
    if DependencyKey(self:GetAll()) == before then return false end
    self:Notify()
    return true
end

function Queue:Notify()
    Queue.version = (Queue.version or 0) + 1
    if ns.Crafting and ns.Crafting.OnQueueChanged then
        ns.Crafting:OnQueueChanged()
    end
    if ns.UI and ns.UI.OnQueueUpdated then
        ns.UI:OnQueueUpdated()
    end
    -- Farmer goals made from the queue follow it (Logic/FarmerGoals.lua).
    if ns.FarmerGoals and ns.FarmerGoals.QueueChanged then
        ns.FarmerGoals:QueueChanged()
    end
end

--------------------------------------------------------------------------------
-- Things to buy rather than make
--------------------------------------------------------------------------------

-- Blackthornes Equipment's Queue it button (a player asked on Discord, 2026-10-10)
-- puts gear the character cannot make on the shopping list, or the
-- materials of a recipe it still has to learn. Each line is
-- { itemID, count, forItem, owner, addedAt }, kept account wide in
-- `queueBuys` (never rename it), and shows only to the character it is for
-- (`owner`), since an upgrade is one character's. A line goes when the gear
-- it is for is queued as a craft, owned or worn, when its row's x is
-- clicked, or with Clear all.

local function Buys(create)
    if not ns.db then return {} end
    if type(ns.db.queueBuys) ~= "table" then
        if not create then return {} end
        ns.db.queueBuys = {}
    end
    return ns.db.queueBuys
end

local function OwnsItem(itemID)
    local inventory = ns.Inventory
    if not (inventory and itemID) then return false end
    local ok, owned = pcall(function()
        return inventory:GetOwnedCount(itemID) + inventory:GetEquippedCount(itemID)
    end)
    return ok and (owned or 0) > 0
end

local function MineToSee(line, selfKey)
    return line.owner == nil or line.owner == selfKey
end

--- This character's lines, after letting go of any whose gear is owned.
-- A handful of lines at most, so cheap enough for every shopping list.
function Queue:GetBuys()
    local buys, mine = Buys(false), {}
    local selfKey = SelfKey()

    for index = #buys, 1, -1 do
        local line = buys[index]
        if type(line) ~= "table" or not line.itemID then
            -- Unreadable: skipped, never deleted.
        elseif MineToSee(line, selfKey) and line.forItem and OwnsItem(line.forItem) then
            table.remove(buys, index)
        elseif MineToSee(line, selfKey) then
            table.insert(mine, 1, line)
        end
    end
    return mine
end

--- Is anything on this character's list to buy?
function Queue:HasBuys()
    return #self:GetBuys() > 0
end

--- Let go of the lines for the gear a craft now makes: the craft's own
--- materials replace them, so they would be bought twice.
DropBuysFor = function(itemID)
    if not itemID then return false end
    local buys, dropped = Buys(false), false
    local selfKey = SelfKey()
    for index = #buys, 1, -1 do
        local line = buys[index]
        if type(line) == "table" and line.forItem == itemID and MineToSee(line, selfKey) then
            table.remove(buys, index)
            dropped = true
        end
    end
    return dropped
end

--- Have `count` of an item on the shopping list for a piece of gear. Set,
--- not added, so a second click on the same gear changes nothing.
-- @param itemID   what to buy
-- @param count    how many
-- @param forItem  the gear it is for (the item itself when buying the gear)
-- @param forRecipe  optional { recipeID, name, crafts }: materials for a
--   recipe to learn and skill up with (Level Up's Learn next and Road to 300).
--   Such a line is not tied to owning an item, which the first craft would,
--   so it stays until its x, Clear all, or the recipe is learned
--   (Queue:QueueLearned turns it into the craft).
-- @return true, or nil and why
function Queue:EnsureBuy(itemID, count, forItem, forRecipe)
    itemID, forItem = tonumber(itemID), tonumber(forItem)
    count = math.floor(tonumber(count) or 1)
    if not itemID or count < 1 then return nil, L["nothing to buy"] end
    if not ns.db then return nil, L["Tradeskills has not loaded its saved data yet"] end
    local recipeID = type(forRecipe) == "table" and tonumber(forRecipe.recipeID) or nil
    if recipeID then
        forItem = nil
    else
        forItem = forItem or itemID
        if OwnsItem(forItem) then return nil, L["you already have it"] end
    end

    local selfKey = SelfKey()
    local buys = Buys(true)
    for _, line in ipairs(buys) do
        if type(line) == "table" and line.itemID == itemID and line.forItem == forItem
            and line.forRecipe == recipeID and MineToSee(line, selfKey) then
            local crafts = recipeID and tonumber(forRecipe.crafts) or nil
            if line.count == count and line.forRecipeCrafts == crafts then return true end
            line.count = count
            line.forRecipeCrafts = crafts
            self:Notify()
            return true
        end
    end

    buys[#buys + 1] = {
        itemID = itemID, count = count, forItem = forItem,
        forRecipe = recipeID, forRecipeName = recipeID and forRecipe.name or nil,
        forRecipeCrafts = recipeID and tonumber(forRecipe.crafts) or nil,
        owner = selfKey, addedAt = time(),
    }
    self:Notify()
    return true
end

--- Once this character knows a recipe whose materials went on the list to
--- buy (Queue Step or Queue materials on a recipe still to learn), queue the
--- craft itself and take those lines off, so the materials count once.
-- @return how many crafts went in the queue
function Queue:QueueLearned()
    local selfKey = SelfKey()
    local record = CharacterRecord(selfKey)
    local known = record and type(record.recipes) == "table" and record.recipes
    if not known then return 0 end
    local buys = Buys(false)

    -- How many crafts each learned recipe's lines were for.
    local crafts = {}
    for _, line in ipairs(buys) do
        local recipeID = type(line) == "table" and line.forRecipe
        local recipe = recipeID and known[recipeID]
        if recipe and MineToSee(line, selfKey) then
            local want = tonumber(line.forRecipeCrafts)
            if not want then
                -- An older line: as many crafts as its count covers.
                for _, reagent in ipairs(recipe.reagents or {}) do
                    if reagent.itemID == line.itemID then
                        want = math.ceil(line.count / math.max(1, reagent.quantity or 1))
                    end
                end
            end
            if want and want > 0 then crafts[recipeID] = math.max(crafts[recipeID] or 0, want) end
        end
    end

    local queued = 0
    for recipeID, count in pairs(crafts) do
        if self:Ensure(recipeID, count) then
            queued = queued + 1
            for index = #buys, 1, -1 do
                local line = buys[index]
                if type(line) == "table" and line.forRecipe == recipeID and MineToSee(line, selfKey) then
                    table.remove(buys, index)
                end
            end
        end
    end
    if queued > 0 then self:Notify() end
    return queued
end

--- Take an item off this character's list to buy (the x on its row).
function Queue:RemoveBuys(itemID)
    local buys, removed = Buys(false), false
    local selfKey = SelfKey()
    for index = #buys, 1, -1 do
        local line = buys[index]
        if type(line) == "table" and line.itemID == itemID and MineToSee(line, selfKey) then
            table.remove(buys, index)
            removed = true
        end
    end
    if removed then self:Notify() end
    return removed
end

--- Empty this character's list to buy. Other characters' lines stay.
function Queue:ClearBuys()
    local buys = Buys(false)
    local selfKey = SelfKey()
    for index = #buys, 1, -1 do
        local line = buys[index]
        if type(line) == "table" and MineToSee(line, selfKey) then table.remove(buys, index) end
    end
end

--- Have at least `quantity` of a craft queued. For Blackthornes Equipment:
--- a second click on the same gear queues no more.
-- @return true, or nil and why
function Queue:Ensure(recipeID, quantity)
    recipeID = tonumber(recipeID)
    quantity = math.max(1, math.floor(tonumber(quantity) or 1))
    if not recipeID then return nil, L["no recipe"] end
    if not ns.Recipes:GetAny(recipeID) then
        return nil, L["Tradeskills has not seen this recipe yet: open the profession window once on the character who knows it"]
    end

    local _, existing = self:Find(recipeID, true)
    if existing then
        if existing.quantity >= quantity then return true end
        if not self:SetQuantity(recipeID, quantity) then return nil, L["the queue would not take it"] end
        return true
    end
    if not self:Add(recipeID, quantity) then return nil, L["the queue would not take it"] end
    return true
end

--- What the queue holds for a piece of gear: "craft" when a craft of it is
--- queued, "buy" when it or its materials are on the list to buy, else nil.
function Queue:ForUpgrade(itemID)
    itemID = tonumber(itemID)
    if not itemID then return nil end
    for _, entry in ipairs(self:GetAll()) do
        if not entry.isDependency then
            local recipe = ns.Recipes:GetAny(entry.recipeID)
            if recipe and recipe.outputItemID == itemID then return "craft" end
        end
    end
    for _, line in ipairs(self:GetBuys()) do
        if line.forItem == itemID then return "buy" end
    end
    return nil
end

--- Open the window on the Queue tab, where the shopping list is.
function Queue:ShowQueue()
    if not (ns.UI and ns.UI.Show) then return false end
    ns.UI:Show()
    if ns.UI.SelectTab then ns.UI:SelectTab("queue") end
    return true
end

--------------------------------------------------------------------------------
-- Kept for one redraw
--------------------------------------------------------------------------------

-- Each finished craft redraws the Queue tab and the craft pane, which
-- between them asked for the entry costs and the shopping list three or
-- four times in one go, each build pricing every material again. While a
-- redraw runs (Queue:Keeping), the first answer is kept and handed to the
-- rest, and forgotten the moment the queue, the bags, a setting or a price
-- moves; outside a redraw nothing is kept. A hitch each time a craft
-- finished (2026-10-11).

local keeping = 0
local kept = {}

local function KeepKey()
    return ("%s:%s:%s:%s"):format(tostring(Queue.version), tostring(ns.Inventory and ns.Inventory.changes),
        tostring(ns.Config and ns.Config.changes), tostring(ns.Prices and ns.Prices.changes))
end

local function Kept(name, build)
    if keeping == 0 then return build() end
    local key = KeepKey()
    local entry = kept[name]
    if entry and entry.key == key then return entry.value end
    local value = build()
    kept[name] = { key = key, value = value }
    return value
end

local function Done(ok, ...)
    keeping = keeping - 1
    if keeping == 0 then kept = {} end
    if not ok then error((...), 0) end
    return ...
end

--- Run fn (a redraw) with the entry costs and the shopping list built at
--- most once for it. Passes fn's results and errors on.
function Queue:Keeping(fn, ...)
    keeping = keeping + 1
    return Done(pcall(fn, ...))
end

--- The cost and profit of each queued craft, by entry.
function Queue:GetEntryCosts()
    return Kept("costs", function() return self:BuildEntryCosts() end)
end

--- What the queue still needs, line by line. Within a redraw the same list
--- goes to every caller: a caller may add fields to a line, never take any
--- away or reorder the list.
function Queue:GetShoppingList()
    return Kept("shopping", function() return self:BuildShoppingList() end)
end

--------------------------------------------------------------------------------
-- Derived views
--------------------------------------------------------------------------------

--- Totals across the whole queue.
--
-- Sub-crafts count as crafts but add no cost or profit of their own. A craft's
-- cost already prices each reagent the cheaper way, so when the bolts for a
-- bag are cheaper to make, the bag's cost already includes the wool. Adding
-- the bolt crafts on top paid for that wool twice. Nor are the bolts sold, so
-- they earn no profit.
function Queue:GetTotals()
    local totals = { crafts = 0, cost = 0, profit = 0, priceable = true }
    local entries = self:GetEntryCosts()

    for _, entry in ipairs(self:GetAll()) do
        local priced = entries[entry]

        totals.crafts = totals.crafts + entry.quantity

        if entry.isDependency then
            -- Counted inside the craft it serves.
        elseif priced then
            totals.cost = totals.cost + priced.cost
            if priced.profit then
                totals.profit = totals.profit + priced.profit
            else
                totals.priceable = false
            end
        else
            totals.priceable = false
        end
    end

    return totals
end

--- What each queued craft costs and earns for all the times it is queued.
--
-- One craft's cost times the count is right unless "Charge market price" is
-- unticked. Then the materials in the bags are free, but only as many as
-- there are: 20 bolts in the bags pay for the first bags queued, not for
-- every one of them, and not again for the next craft in the queue that
-- uses bolts. So the bags are shared out down the queue, first come first
-- served, and everything past them costs what it would to buy.
--
-- @return { [entry] = { cost = copper, profit = copper } } for every entry
--   that is not a sub-craft and whose materials can be priced; profit is
--   nil when what it makes has no price
function Queue:BuildEntryCosts()
    local result = {}
    local cashView = not ns.Config:Get("valueOwnedMaterials")
    local bagsLeft = {}

    -- What the queue is making, by item. On Discord (2026-10-07):
    -- with "Queue sub-crafts" off the leather was bought, To buy went up,
    -- and every row and the footer still priced it as made from scraps.
    -- A material is costed as made only when a sub-craft on the queue makes
    -- it, and as bought otherwise, so the rows match To buy.
    local made = {}
    for _, entry in ipairs(self:GetAll()) do
        local recipe = entry.isDependency and ns.Recipes:GetAny(entry.recipeID)
        if recipe and recipe.outputItemID then made[recipe.outputItemID] = true end
    end

    -- Bought off the auction house, each craft goes further up the
    -- listings (Cost:CostOfMany): 3 at 10s and the rest at 14s make 20
    -- cost more than 20 x 10s, as To buy says. The listings are shared
    -- down the queue, so two crafts using the same cloth do not both buy
    -- the cheap ones.
    local boughtSoFar = {}
    local function BuyMore(reagent, more)
        if more <= 0 then return 0 end
        local itemID, unit, source = reagent.itemID, reagent.unitCost or 0, reagent.source
        local before = boughtSoFar[itemID] or 0
        boughtSoFar[itemID] = before + more
        local was = ns.Cost:CostOfMany(itemID, before, unit, source) or unit * before
        local now = ns.Cost:CostOfMany(itemID, before + more, unit, source) or unit * (before + more)
        return now - was
    end

    for _, entry in ipairs(self:GetAll()) do
        local analysis = not entry.isDependency and ns.Profit:Analyse(entry.recipeID)
        local count = entry.quantity
        local cost

        -- The materials are costed even when what the craft makes has no
        -- price (an enchant makes no item at all): the footer's materials
        -- said 0c beside To buy's 348g on 112 boots enchants.
        if analysis and analysis.priceable then cost = analysis.totalCost * count end

        if analysis then
            local planned = ns.Cost:GetCraftCost(entry.recipeID, nil, nil, { made = made })
            if planned and planned.priceable then
                cost = planned.total * count
            end
        end

        if cost then

            -- Every line at what it is worth, then the bags taken off
            -- ("Charge market price" unticked) and what is bought priced
            -- up the listings.
            local full = ns.Cost:GetCraftCost(entry.recipeID, nil, nil,
                { valueOwned = true, made = made })

            if full and full.priceable then
                cost = 0

                for _, reagent in ipairs(full.reagents) do
                    local itemID, needed = reagent.itemID, reagent.quantity * count
                    local unit = reagent.unitCost or 0
                    local free = 0

                    if cashView then
                        if bagsLeft[itemID] == nil then
                            bagsLeft[itemID] = ns.Inventory:GetBagCount(itemID)
                        end
                        free = math.min(needed, bagsLeft[itemID])
                        bagsLeft[itemID] = bagsLeft[itemID] - free
                    end

                    if not reagent.crafted and (reagent.source == "buy" or reagent.source == "mine") then
                        cost = cost + BuyMore(reagent, needed - free)
                    else
                        cost = cost + unit * (needed - free)
                    end
                end
            end

            -- Profit moves with cost one for one: the sale and its cut are
            -- the same however the materials were paid for. No sale price,
            -- no profit: only the materials are known.
            result[entry] = {
                cost = cost,
                profit = analysis.priceable
                    and (analysis.profit * count + analysis.totalCost * count - cost) or nil,
            }
        end
    end

    return result
end

--- Everything the queue needs, minus what is in the bags, aggregated.
--
-- Reagents are summed across the whole queue before subtracting inventory, so
-- two recipes sharing a reagent do not each claim the same stack.
--
-- A reagent the queue is making itself is not bought as well. Sub-crafts are
-- only queued when making the reagent is cheaper than buying it, and their
-- own materials are already on this list, so listing the reagent too asked
-- you to pay for it twice.
--- Every material a queued craft still needs: { [itemID] = how many }.
--
-- The same items the shopping list covers, without its pricing, stock counts
-- or alt offers. Posting asks this every second at the auction house to keep
-- queued reagents off the sale list, and the full list is too heavy for that.
function Queue:GetReservedItems()
    local required, queuedToMake = {}, {}

    for _, entry in ipairs(self:GetAll()) do
        local recipe = ns.Recipes:GetAny(entry.recipeID)
        if recipe then
            for _, reagent in ipairs(recipe.reagents or {}) do
                required[reagent.itemID] = (required[reagent.itemID] or 0)
                    + (reagent.quantity * entry.quantity)
            end
            if entry.isDependency and recipe.outputItemID then
                queuedToMake[recipe.outputItemID] = (queuedToMake[recipe.outputItemID] or 0)
                    + entry.quantity * math.max(1, recipe.quantityMin or 1)
            end
        end
    end

    local reserved = {}
    for itemID, needed in pairs(required) do
        local short = needed - (queuedToMake[itemID] or 0)
        if short > 0 then reserved[itemID] = short end
    end
    return reserved
end

function Queue:BuildShoppingList()
    local required = {}
    local queuedToMake = {}

    -- Shared with the alts, a material another character uses is first
    -- taken from what that character already holds: the tailor's own wool
    -- goes into the tailor's bolts, and only the rest is yours to get.
    local shared = self:SharesWithAlts()
    local selfKey = SelfKey()
    local forOthers = {}

    for _, entry in ipairs(self:GetAll()) do
        -- GetAny, as everywhere else the queue is read: an alt's craft queued
        -- from the account-wide view still needs its materials gathered.
        local recipe = ns.Recipes:GetAny(entry.recipeID)
        local crafter = shared and self:GetCrafter(entry) or selfKey

        if recipe then
            for _, reagent in ipairs(recipe.reagents or {}) do
                local units = reagent.quantity * entry.quantity
                required[reagent.itemID] = (required[reagent.itemID] or 0) + units

                if crafter ~= selfKey then
                    local byCharacter = forOthers[reagent.itemID] or {}
                    byCharacter[crafter] = (byCharacter[crafter] or 0) + units
                    forOthers[reagent.itemID] = byCharacter
                end
            end
        end

        -- GetAny, as RebuildDependencies sizes these from the same record.
        local made = entry.isDependency and ns.Recipes:GetAny(entry.recipeID)
        if made and made.outputItemID then
            queuedToMake[made.outputItemID] = (queuedToMake[made.outputItemID] or 0)
                + entry.quantity * math.max(1, made.quantityMin or 1)
        end
    end

    -- What this character asked to buy rather than make (EnsureBuy).
    local wanted = {}
    for _, line in ipairs(self:GetBuys()) do
        required[line.itemID] = (required[line.itemID] or 0) + line.count
        local forItems = wanted[line.itemID] or {}
        forItems[#forItems + 1] = { forItem = line.forItem, count = line.count,
            forRecipe = line.forRecipe, forRecipeName = line.forRecipeName }
        wanted[line.itemID] = forItems
    end

    local list = {}

    -- On unless unticked in Settings. Shared across lines so the alts' recipes
    -- are gathered once per list, not once per material.
    local altContext = ns.Config:Get("suggestOtherCharacters") ~= false and {} or nil

    for itemID, needed in pairs(required) do
        needed = needed - (queuedToMake[itemID] or 0)

        -- What the others need of it, and how much of that they hold.
        local othersNeed, othersHold = nil, 0
        for characterKey, units in pairs(forOthers[itemID] or {}) do
            othersNeed = othersNeed or {}
            othersNeed[characterKey] = units
            othersHold = othersHold + math.min(units, self:HeldBy(characterKey, itemID))
        end
        needed = needed - othersHold

        if needed > 0 then
            -- A shopping list asks "must I buy this", so it counts the bank: you
            -- already own it, it just needs collecting.
            local inBags = ns.Inventory:GetBagCount(itemID)
            local inBank = ns.Inventory:GetBankCount(itemID)
            local have = inBags + inBank

            -- A sub-craft was sized against everything owned, mail included, so
            -- whatever of this it leaves over is already owned. Counting it the
            -- same way keeps the two from disagreeing about what is left to buy.
            local inMail = 0
            if queuedToMake[itemID] then
                inMail = ns.Inventory:GetMailCount(itemID)
            end

            -- Bought on the auction house and waiting in the mail: yours, so
            -- not to be bought again. A mail count already taken holds the
            -- ones the mailbox showed; only the rest are added.
            local bought = ns.AHBuys and ns.AHBuys:GetPending(itemID) or 0
            inMail = inMail + BoughtBeyondMail(itemID, inMail)
            have = have + inMail

            local shortfall = math.max(0, needed - have)

            -- The same auction price material cost uses, so a lone listing far
            -- below the rest is left out here too.
            local auction = ns.Prices:GetValue(itemID, "lowest")
            local vendor = ns.Vendor:GetUnitPrice(itemID)

            -- All that is still to buy, up the listings from the last scan
            -- (Prices:GetCostFor), past the ones bought since it.
            local auctionCost
            if auction and shortfall > 0 and ns.Prices.GetCostFor then
                local skip = 0
                local record = ns.Prices:Get(itemID)
                if ns.AHBuys and ns.AHBuys.BoughtSince and type(record) == "table" and record.seen then
                    skip = ns.AHBuys:BoughtSince(itemID, record.seen)
                end
                auctionCost = ns.Prices:GetCostFor(itemID, shortfall, skip)
            end
            local auctionEach = auctionCost and math.floor(auctionCost / shortfall + 0.5) or auction

            -- Cheaper from a vendor means the shopping list should send you to
            -- one, not to the auction house.
            -- A vendor that never runs out always wins, unless the player
            -- asked for the auction house to be offered too (2026-10-13).
            -- Not one set to Buy on the Level Up tab, while it is listed.
            local skipVendor = auctionEach ~= nil and ns.Cost.SkipsVendor
                and ns.Cost:SkipsVendor(itemID)
            local fromVendor = vendor ~= nil and not skipVendor and (not auctionEach
                or vendor <= auctionEach or ns.Vendor:KeepsInStock(itemID))
            local unitCost = fromVendor and vendor or auctionEach
            local estimatedCost
            if fromVendor then
                estimatedCost = vendor * shortfall
            elseif auctionCost then
                estimatedCost = auctionCost
            elseif unitCost then
                estimatedCost = unitCost * shortfall
            end

            -- What was paid for it on the auction house today, against what
            -- this list had said; amber when well over (AHBuys.OVERPAID).
            local paid, paidUnits, paidEstimate
            if ns.AHBuys and ns.AHBuys.PaidFor then
                paid, paidUnits, paidEstimate = ns.AHBuys:PaidFor(itemID, needed)
            end

            -- Where to go, and what the choice is worth. Only a genuine choice
            -- when both sources actually have the item.
            local source = "unknown"
            if fromVendor then
                source = "vendor"
            elseif auction then
                source = "auction"
            end

            -- Only when the place picked is the cheaper one: a vendor kept
            -- for an item it never runs out of saves nothing when the
            -- auction house lists it for less.
            local savingPerUnit
            if vendor and auction then
                savingPerUnit = math.max(0, fromVendor and (auction - vendor) or (vendor - auction))
            end

            list[#list + 1] = {
                itemID = itemID,
                needed = needed,
                have = have,
                inBags = inBags,
                inBank = inBank,
                inMail = inMail,
                -- Of those, bought on the auction house and not taken yet.
                bought = math.min(bought, inMail),
                -- True when you own enough only by counting the bank, so the row
                -- can say "go to the bank" rather than implying you can craft now.
                needsBankTrip = inBags < needed and inBags + inBank >= needed,
                -- The same for the mailbox. A sub-craft's leftovers can be
                -- waiting there, and the row said "in bank" for them.
                needsMailTrip = inBags + inBank < needed and have >= needed,
                shortfall = shortfall,
                -- Each, on average, for the shortfall: up the listings.
                unitCost = unitCost,
                estimatedCost = estimatedCost,
                paid = paid,
                paidUnits = paidUnits,
                paidEstimate = paidEstimate,
                overpaid = ns.AHBuys and ns.AHBuys.Overpaid
                    and ns.AHBuys.Overpaid(paid, paidEstimate) or false,
                fromVendor = fromVendor,
                vendorLimited = fromVendor and ns.Vendor:IsLimited(itemID) or false,
                source = source,
                vendorUnit = vendor,
                auctionUnit = auction,
                -- Both prices known: how much choosing the cheaper one saves.
                savingPerUnit = savingPerUnit,
                savingTotal = savingPerUnit and (savingPerUnit * shortfall) or nil,
                onAlts = ns.Inventory:GetAltTotal(itemID),
                -- { [characterKey] = units } of this the others' crafts use,
                -- and how many of those they already hold.
                forOthers = othersNeed,
                othersHold = othersHold,
                -- { { forItem, count }, ... } asked for by EnsureBuy: the
                -- row gets an x, and the tooltip says what it is for.
                buys = wanted[itemID],
                -- Cheaper to make on another character, when asked to look.
                altCraft = altContext and shortfall > 0
                    and self:GetAltCraftOffer(itemID, shortfall, unitCost, altContext) or nil,
            }
        end
    end

    table.sort(list, function(a, b)
        if (a.shortfall > 0) ~= (b.shortfall > 0) then
            return a.shortfall > 0
        end
        -- A last tie-break, so equal rows (every "no data" one at 0) keep
        -- their places between refreshes instead of swapping.
        if (a.estimatedCost or 0) ~= (b.estimatedCost or 0) then
            return (a.estimatedCost or 0) > (b.estimatedCost or 0)
        end
        return (a.itemID or 0) < (b.itemID or 0)
    end)

    return list
end

--------------------------------------------------------------------------------
-- Making a material on another character
--------------------------------------------------------------------------------

--- Every recipe your other characters know, by the item it makes.
--
-- The logged-in character is left out: whatever it can make, the cost engine
-- already weighs against buying and queues as a sub-craft when cheaper.
local function AltRecipesByOutput()
    local byOutput = {}
    if not (ns.db and ns.db.characters) then return byOutput end

    local selfKey = SelfKey()

    for characterKey, record in pairs(ns.db.characters) do
        -- Only characters who could mail it here.
        if characterKey ~= selfKey and type(record) == "table"
            and Queue:CanMail(characterKey, selfKey) then
            for recipeID, recipe in pairs(record.recipes or {}) do
                local itemID = recipe.outputItemID
                -- Not from a profession that character has dropped.
                local dropped = ns.Recipes.IsDropped and ns.Recipes:IsDropped(recipe, characterKey)
                -- Nor one marked never to make as a sub-craft.
                local never = ns.Cost.IsNeverSubCraft and ns.Cost:IsNeverSubCraft(recipeID)
                if itemID and not dropped and not never then
                    local list = byOutput[itemID] or {}
                    list[#list + 1] = { characterKey = characterKey, recipeID = recipeID, recipe = recipe }
                    byOutput[itemID] = list
                end
            end
        end
    end

    return byOutput
end

--- Display names that tell apart two characters sharing a name.
local function CharacterNames()
    local names = {}
    if ns.Recipes.GetCharacters then
        for _, entry in ipairs(ns.Recipes:GetCharacters()) do
            names[entry.key] = entry.name
        end
    end
    return names
end

--- The cheapest way another of your characters can make a material this
--- character has to buy, when that beats buying it.
--
-- Only ever a suggestion. The queue cannot craft on another character, so the
-- shopping list still says buy it; this is the reason to log over, make it
-- there and mail it across. Items that bind on pickup cannot be mailed, so they
-- are never suggested.
--
-- @param units how many are still needed
-- @param buyUnitCost what one costs to buy, or nil when nobody sells it
-- @return nil, or { characterKey, characterName, recipeID, recipeName,
--                   unitCost, crafts, saving }  (saving nil when unpriced)
function Queue:GetAltCraftOffer(itemID, units, buyUnitCost, context)
    if not itemID or not units or units <= 0 then return nil end
    if ns.Cost:FindRecipeForItem(itemID) then return nil end
    if ns.Util.IsBoundOnPickup and ns.Util.IsBoundOnPickup(itemID) == true then return nil end

    context = context or {}
    context.byOutput = context.byOutput or AltRecipesByOutput()

    local candidates = context.byOutput[itemID]
    if not candidates then return nil end

    context.names = context.names or CharacterNames()

    local best
    for _, candidate in ipairs(candidates) do
        local cost = ns.Cost:GetCraftCost(candidate.recipeID)
        local unitCost = cost and cost.priceable and cost.perUnit

        if unitCost and (not buyUnitCost or unitCost < buyUnitCost) then
            local name = context.names[candidate.characterKey]
                or ns.Recipes:GetCharacterName(candidate.characterKey)

            if not best or unitCost < best.unitCost
                or (unitCost == best.unitCost and name < best.characterName) then
                local perCraft = math.max(1, candidate.recipe.quantityMin or 1)

                best = {
                    characterKey = candidate.characterKey,
                    characterName = name,
                    recipeID = candidate.recipeID,
                    recipeName = candidate.recipe.name,
                    unitCost = unitCost,
                    crafts = math.ceil(units / perCraft),
                    saving = buyUnitCost and math.floor((buyUnitCost - unitCost) * units) or nil,
                }
            end
        end
    end

    return best
end

--- What is still to buy, and how many of those lines have no price.
-- @param lines  the shopping list when the caller already has it. Building
--   it walks the queue, the bags and every character's recipes, and the Buy
--   view built it again every second just for this total.
function Queue:GetShoppingTotal(lines)
    local total, unknown = 0, 0

    for _, line in ipairs(lines or self:GetShoppingList()) do
        if line.shortfall > 0 then
            if line.estimatedCost then
                total = total + line.estimatedCost
            else
                unknown = unknown + 1
            end
        end
    end

    return total, unknown
end

--- Shopping totals split by where you have to go to get them.
-- @param lines  the shopping list when the caller already has it
-- @return summary table keyed by source, plus grand totals
function Queue:GetGatherSummary(lines)
    local summary = {
        vendor = { count = 0, cost = 0 },
        auction = { count = 0, cost = 0 },
        unknown = { count = 0, cost = 0 },
        total = 0,
        outstanding = 0,
        satisfied = 0,
        saving = 0,
    }

    for _, line in ipairs(lines or self:GetShoppingList()) do
        if line.shortfall > 0 then
            summary.outstanding = summary.outstanding + 1

            local bucket = summary[line.source] or summary.unknown
            bucket.count = bucket.count + 1
            bucket.cost = bucket.cost + (line.estimatedCost or 0)

            summary.total = summary.total + (line.estimatedCost or 0)
            summary.saving = summary.saving + (line.savingTotal or 0)
        else
            summary.satisfied = summary.satisfied + 1
        end
    end

    return summary
end
