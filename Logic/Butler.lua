-- Blackthornes Tradeskills -- Logic/Butler.lua
-- What Tradeskills knows about one item, for Blackthornes Butler (2026-10-10).
--
-- Butler tells the player what to do with each item in the bags: keep it,
-- sell it, post it, disenchant it, mail it to an alt. It asks this, inside a
-- pcall and read only:
--
--   _G.BlackthornesTS.Butler:Advise(item)   -- item ID or link; a table, or nil
--
-- Every field may be nil when it is not known:
--
--   auction        copper for one, sold on the auction house, after the cut
--                  and the deposit (Profit:NetFromListing on the smoothed
--                  market price). nil for greys (vendor only), gear that
--                  binds when picked up, and items never priced.
--   auctionNow     copper for one sold at today's cheapest listing that is
--                  not the player's own, after the cut and the deposit, from
--                  the player's own scan while it is fresh (Prices:IsStale).
--                  nil when there is no auction value, nobody else is
--                  listing it, or the scan is old. Butler compares it with
--                  `auction` to hold back items selling below their usual
--                  price (2026-10-13).
--   belowCost      copper one costs to make, when the price the Sell list
--                  would list it at is under that and Tradeskills would not
--                  list it (Posting:BelowCost, or "Never below what I paid"
--                  with Posting:BelowCraftedCost). nil when it is no craft,
--                  the price covers the cost, or "Recommend selling at a
--                  loss" is on. Butler then holds it back rather than say
--                  Auction (2026-10-13).
--   fast           true when it sells well (Demand "high"), false when it
--                  rarely sells ("low"), nil in between or with no data.
--   disenchant     copper a disenchant of one is likely to give
--                  (Disenchant:GetValue), nil when it cannot be broken or
--                  its material has no price.
--   canDisenchant  true when the character playing knows Disenchant and has
--                  the Enchanting skill this one needs; false when not, or
--                  when it cannot be disenchanted at all.
--   enchanter      when the character playing cannot: the short name of the
--                  disenchanter typed in Settings, else of the alt on this
--                  account (same realm and faction) with the most Enchanting
--                  that is enough.
--   disenchanter   the disenchanter typed in Settings (full name) when this
--                  item is gear the Mail page sends there: green up to the
--                  quality picked, can be disenchanted, does not bind when
--                  picked up, not crafted, no upgrade for the character playing
--                  (QueueMail:GoesToDisenchanter, 2026-10-11). nil with no
--                  disenchanter typed. A soulbound copy is Butler's to leave
--                  out.
--   need           how many the character playing's own queued crafts still
--                  use from its bags (what they use, less what it makes and
--                  what is in its bank), as the Mail panel works it out.
--   mailTo,        the alt whose queued crafts this character's bags can
--   mailCount      supply, and how many (QueueMail:GetDeliveries).
--   bought         how many the account bought on the auction house to
--                  disenchant (DisenchantBuys:Count, 2026-10-11), nil when
--                  none.
--   forEnchanting  a green this character can disenchant, not crafted,
--                  whose likely material (Butler.LIKELY_OUTCOME) its own
--                  Enchanting still lacks for the crafts that give a point
--                  every time (2026-10-13): { recipe (the craft's name),
--                  material (item ID), materialName, short (how many it
--                  lacks, after bags, bank and mailbox), yield (about how
--                  many one disenchant gives) }. nil otherwise.
--   youDisenchant  true when the character playing is the disenchanter
--                  (QueueMail:IsDisenchanterPlaying: the name typed in
--                  Settings, else the one "Pick one for me" would pick),
--                  nil otherwise. For Butler's "Disenchant greens here",
--                  which is off unless ticked there (the owner, 2026-10-14).
--   crafted        true for a green some recipe makes, asked only while
--                  `youDisenchant` is true; nil otherwise.
--
-- Butler's right-click menu marks or unmarks one (2026-10-11):
--
--   _G.BlackthornesTS.Butler:SetBoughtToDisenchant(itemID, on, count)
--     -- true, or false and why; never raises
--
-- Butler asks once per bag item, a hundred times in a burst. So the queue,
-- the mail plan and the characters' Enchanting are read once into a lookup
-- and kept until the queue changes (Queue.version), the bags change
-- (Inventory.changes) or LOOKUP_SECONDS pass, whichever comes first; it is
-- built again on the next question, never on a timer. Each question is then
-- a few table reads and the per-item prices.
--
-- Butler's "All characters" list (2026-10-10) asks one more thing, once
-- each time that list is built, never per item:
--
--   _G.BlackthornesTS.Butler:Holdings()   -- a list, or nil
--
-- One entry per character Tradeskills has a record for, the character
-- playing first (Recipes:GetCharacters' order and names):
--
--   key            the character's GUID, as Tradeskills keys it ("Name-Realm"
--                  for a character not seen since before GUIDs).
--   name           the name Recipes:GetCharacters gives (told apart by
--                  level and class when two share it).
--   short          the short name (Recipes:GetShortCharacterName).
--   realm, faction as recorded, or nil.
--   isCurrent      true for the character playing.
--   playing        true for the character playing under any of its
--                  records (Characters:IsPlaying); never mail or log out for it.
--   linked         the character it came through when it is on another
--                  account of yours (Logic/AccountLink.lua), else nil.
--   bags, bank,    { [itemID] = count }, each a fresh copy: the bags of the
--   mail           character playing are read live (Inventory:GetBagCounts),
--                  everything else is the last snapshot.
--   bagsAt,        when each was last read (time()), nil when never; the
--   bankAt, mailAt live bags say now.
--   gold, goldAt   copper on the character when last seen, and when
--                  (the bags' snapshot time); live for the character
--                  playing. nil when never recorded (2026-10-11, for
--                  Butler's gold top-ups).
--
-- At a mailbox and the bank (2026-10-11), Butler asks two more things:
--
--   _G.BlackthornesTS.Butler:FillMail(name, items, money)   -- true, or false and why
--   _G.BlackthornesTS.Butler:FromBank()              -- { [itemID] = count }, or nil
--
-- FillMail fills the game's Send Mail page for one of the player's
-- characters (QueueMail:Fill, the same one the Mail panel uses): `name` is
-- the short name Advise gave as mailTo or enchanter, `items` a list of
-- { itemID, count }, `money` optional copper put in the gold boxes (gold
-- alone is a mail too; never with COD ticked, never more than the purse
-- less postage). The player presses Send; what goes is written down by
-- QueueMail's own SendMail hook, as for the Mail panel. FromBank says what
-- the character playing's own queued crafts still want from its bank: what
-- they use, less what it makes and what it carries, no more than its bank
-- holds.
--
-- Butler's step list for jobs on other characters (the owner asked
-- 2026-10-11 for a way to "go craft Medium Leather on another, then send it
-- back") asks two more:
--
--   _G.BlackthornesTS.Butler:Jobs()             -- a list, or nil; reads only
--   _G.BlackthornesTS.Butler:Craft(recipeID)    -- true, or false and why
--   _G.BlackthornesTS.Butler:Profession(recipeID)  -- { name, spell, open }, or nil
--
-- Jobs is one entry per character with something to do in the queue, the
-- character playing first, then by name: { key, name (full), isCurrent,
-- steps }. Each step is a craft, { kind = "craft", recipeID, itemID, name,
-- count (items it makes), crafts, forNames (full names it is for, other
-- than the crafter), slots (bag slots making it frees; the character
-- playing only, nil when the setting is off), ready, missing = { { itemID, count, from, vendor } } }
-- (`vendor`: copper for one when a vendor sells it), or a
-- mail, { kind = "mail", to (full name), items = { { itemID, count } },
-- crafts, forCraft }: what the character playing can send now
-- (QueueMail:GetDeliveries), and for the others what they made for someone
-- and still owe (QueueMail:GetOwedBy). A craft held up for materials
-- another character carries or banks names it as the missing item's
-- `from`, and that character gets a mail step to the crafter first
-- (`forCraft`), so it can be done before the craft. A profession cooldown
-- that is up (Logic/Cooldowns.lua, 2026-10-12) is a step too, { kind =
-- "cooldown", name (its group: "Transmute"), craft (the craft's name),
-- recipeID, or itemID for an item such as the Salt Shaker }. Mail waiting
-- for a character (2026-10-13) is one step first on its line, { kind =
-- "pickup", items = { { itemID, count } }, forCraft }: materials its
-- crafts count on that sit in its mailbox or are on their way
-- (`forCraft`), and anything else mailed to it not yet seen arrive
-- (QueueMail:InFlightItems). A Butler that
-- does not know the kind leaves it out. Only characters this one can mail (same realm and
-- side), never another account's. Craft makes the character playing's
-- queued craft of that recipe, from Butler's click: started when its
-- profession window shows it, else the Queue tab opens on its Open button.
-- A ready cooldown craft is made once, queued or not, with the window open.
--
-- Butler's gold goals (the owner said build it, 2026-10-13) ask what the
-- trainers' recipes cost that the character playing could learn now:
--
--   _G.BlackthornesTS.Butler:LearnCost()   -- a table, or nil; reads only
--
-- { [Classic skill line] = { skill, count, cost } } for each profession the
-- character has, counting the recipes a trainer teaches (a price in the
-- data) that the skill reaches, that are not learned, and that still give
-- skill (not grey). A profession whose recipes were never read (its window
-- never opened) is left out, since every recipe would look unlearned. Kept
-- LEARN_COST_SECONDS, or until the recipes are read again.
--
-- At a vendor (2026-10-14, the owner asked for the Buy materials button in
-- Butler too), Butler's Buy from a vendor row asks two more:
--
--   _G.BlackthornesTS.Butler:VendorOffer()     -- a table, or nil; reads only
--   _G.BlackthornesTS.Butler:BuyFromVendor()   -- true, or false and why
--
-- VendorOffer is what the Buy materials button over the vendor window would
-- buy (Vendor:GetNeeded): { count (materials), cost (copper in all), items =
-- { { itemID, amount, cost, short } }, cheaperElsewhere (materials left
-- for the auction house), buying (a run is going or settling) }. nil while
-- no vendor is open or its list is not read yet. BuyFromVendor is that
-- button's click (Vendor:BuyNeeded): the same checks, the same one stack a
-- step, and it says in chat why when it buys nothing.
--
-- Butler's tooltip line "Vendors sell it for 25c" (2026-10-22, a player
-- asked for what an NPC vendor charges, the owner said build it) asks:
--
--   _G.BlackthornesTS.Butler:VendorPrice(itemID)   -- copper for one, or nil
--
-- Vendor:GetUnitPrice's answer: a price seen at a merchant, else the shipped
-- Classic price for materials vendors keep in stock; nil for anything no
-- vendor is known to sell or that costs tokens. Never raises, writes nothing.
--
-- Butler's "For your quests" line (2026-10-14, a player asked to buy what
-- open quests need) has a Search button at the auction house:
--
--   _G.BlackthornesTS.Butler:SearchAuctions(items)   -- true and how, or false and why
--
-- items is { { itemID, count } }. Several are looked up in one search
-- (ShoppingLists:SearchMany, the Lists view's own) and it answers true,
-- "all"; where the game takes one a search, the first is searched with its
-- count for the buy box (UI:SearchAuctionHouse) and it answers true, "one",
-- so Butler's next click sends the rest. Never raises.
--
-- Butler's "Cheapest Skill-Up" line (a player asked, the owner said build
-- it, 2026-10-19) shows the Level Up tab's top pick for each profession:
--
--   _G.BlackthornesTS.Butler:NextSkillUp()      -- a list, or nil; reads only
--   _G.BlackthornesTS.Butler:QueueSkillUp(id)   -- true, or false and why
--
-- One entry per profession the character playing is still levelling
-- (skill under its max for now): { profession (the client's name), skill,
-- max, recipeID, itemID, name, tier ("optimal" or "medium"), cost (copper,
-- the REAL COST column: materials less what it gets back, below 0 when the
-- craft pays), queued (true while the queue holds it) }, by profession
-- name. Only a sure or likely point with a priced cost is offered. A
-- profession at its cap for now (2026-10-20, the owner: send the player to
-- the trainer) is { profession, english (its English name), skill, max,
-- capped = true } with no recipe, so Butler can name the rank to train.
-- QueueSkillUp puts one in the queue (Queue:Ensure).
--
-- Butler's "Craft When It Pays More" (2026-10-19, a player asked, the
-- owner said build it, off unless ticked in Butler) asks, only while that
-- is on, whether a bag item is worth more made into something:
--
--   _G.BlackthornesTS.Butler:CraftFor(item, carried, skip)   -- a table, or nil; reads only
--   _G.BlackthornesTS.Butler:QueueCraft(recipeID, crafts)  -- true, or false and why
--
-- CraftFor looks only at recipes the character playing knows (not a
-- dropped profession) that use the item and make something to sell. Each
-- is valued as the Profit tab's Best does (Profit:Analyse "best": auction,
-- vendor or disenchant, after the cut and the deposit; an auction the
-- output rarely sells at counts at Butler.SLOW of itself; an estimate with
-- no real price never counts), less the other materials at their usual
-- cost (Cost:GetCraftCost, owned ones at their worth). The best answers
-- { recipeID, name (the recipe's), itemID (what it makes), per (how many
-- of the item one craft uses), crafts (how many the `carried` copies make,
-- else the bags'), perItem (copper one of the item is worth made into it),
-- needs = { { itemID, count } } (other materials the bags lack for those
-- crafts) }. nil when nothing it knows uses the item, or for no craft.
-- `skip`, optional, is { [recipeID] = anything } for crafts the player
-- told Butler to stop suggesting (2026-10-26); those are passed over, so
-- the next best answers. Butler weighs perItem against its own best price. QueueCraft is
-- Queue:Ensure: at least that many crafts queued.
--
-- Butler's CLAUDE.md and its Logic/Sisters.lua lean on these calls and these
-- fields: keep them stable, or change both repos together.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Butler = ns.NewModule("Butler")

-- Advise takes a bag copy's link as well as an item ID (2026-10-15), so a
-- random suffix is priced as it sells. Butler passes the link only when
-- this says so; an older Tradeskills is asked by item ID.
Butler.TAKES_LINK = true

-- How long a lookup is trusted when nothing says it changed: mail sent, a
-- bank visit or an alt's record are not counted by any version.
local LOOKUP_SECONDS = 2

local GREY = 0

local lookup, lookupKey, lookupAt

local function Now()
    return type(GetTime) == "function" and GetTime() or 0
end

local function SelfKey()
    local config = ns.Config
    return config and config.GetCharacterKey and config:GetCharacterKey() or nil
end

local function Characters()
    local characters = ns.db and ns.db.characters
    return type(characters) == "table" and characters or {}
end

--- Is a saved profession entry Enchanting? Recipes knows it by skill line
--- in any client language; the English name stands in without it.
local function IsEnchanting(profession)
    local recipes = ns.Recipes
    if recipes and type(recipes.IsEnchanting) == "function" then
        return recipes.IsEnchanting(profession) == true
    end
    return profession.name == "Enchanting"
end

--- A character's Enchanting skill, or nil when it has none on record.
local function EnchantingSkill(record)
    if type(record) ~= "table" then return nil end
    for _, profession in ipairs(type(record.professions) == "table" and record.professions or {}) do
        if type(profession) == "table" and IsEnchanting(profession)
            and profession.learned ~= false then
            return tonumber(profession.skillLevel) or 0
        end
    end
    return nil
end

local function ShortName(characterKey)
    local recipes = ns.Recipes
    if recipes and recipes.GetShortCharacterName then
        local ok, name = pcall(recipes.GetShortCharacterName, recipes, characterKey)
        if ok and type(name) == "string" then return name end
    end
    return characterKey
end

--- What this character's own crafts use from its bags: { [itemID] = units }.
-- The same sum QueueMail:GetDeliveries keeps back before it offers any to
-- an alt.
local function OwnNeeds(selfKey)
    local needs = {}
    local mail = ns.QueueMail
    if not (selfKey and mail and mail.GetPlan and ns.Queue and ns.Queue.GetAll) then return needs end

    local uses, makes = mail:GetPlan()
    local myUse, myMake = uses[selfKey] or {}, makes[selfKey] or {}
    local inventory = ns.Inventory

    for itemID, used in pairs(myUse) do
        local bank = inventory and inventory.GetBankCount and inventory:GetBankCount(itemID) or 0
        local left = used - (myMake[itemID] or 0) - bank
        if left > 0 then needs[itemID] = left end
    end
    return needs
end

--- For each item, the alt the bags can best supply: { [itemID] = { name, count } }.
local function MailTargets()
    local targets = {}
    local mail = ns.QueueMail
    if not (mail and mail.GetDeliveries) then return targets end

    for _, delivery in ipairs(mail:GetDeliveries() or {}) do
        for _, item in ipairs(delivery.items or {}) do
            local best = targets[item.itemID]
            if not best or item.count > best.count then
                targets[item.itemID] = { name = ShortName(delivery.to), count = item.count }
            end
        end
    end
    return targets
end

--- The alts on this account that can be mailed and have Enchanting, most
--- skill first: { { name, skill } }.
local function Enchanters(selfKey)
    local list = {}
    local queue = ns.Queue
    for characterKey, record in pairs(Characters()) do
        local skill = EnchantingSkill(record)
        if skill and characterKey ~= selfKey and record.linkedFrom == nil
            and not (ns.QueueMail and ns.QueueMail.IsPlaying and ns.QueueMail:IsPlaying(characterKey))
            and (not (queue and queue.CanMail) or queue:CanMail(selfKey, characterKey)) then
            list[#list + 1] = { name = ShortName(characterKey), skill = skill }
        end
    end
    table.sort(list, function(a, b)
        if a.skill ~= b.skill then return a.skill > b.skill end
        return a.name < b.name
    end)
    return list
end

--- The disenchanter typed in Settings: { name, skill (nil when unknown),
--- quality (the best one mailed) }, or nil.
local function Chosen()
    local mail = ns.QueueMail
    if not (mail and mail.GetDisenchanter) then return nil end
    local typed = mail:GetDisenchanter()
    if not typed then return nil end

    local key = mail.FindCharacter and mail:FindCharacter(typed)
    local record = key and Characters()[key]
    return {
        name = record and ShortName(key) or typed,
        -- Known only for one of your own characters; one on another account
        -- was picked by the player, who knows what it can break.
        skill = record and EnchantingSkill(record) or nil,
        known = record ~= nil,
        quality = mail.GetDisenchantQuality and mail:GetDisenchantQuality() or 4,
    }
end

--- Does the character playing know Disenchant? nil when the client will not say.
local function KnowsDisenchant()
    local disenchanter = ns.Disenchanter
    if disenchanter and disenchanter.Knows then
        local ok, known = pcall(disenchanter.Knows, disenchanter)
        if ok then return known end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Levelling Enchanting with your own greens (the owner, 2026-10-13)
--------------------------------------------------------------------------------

-- An outcome this likely is one a disenchant can be counted on for: a
-- green's dust (75%) or essence (15 to 20%), never its rare shard (5%).
Butler.LIKELY_OUTCOME = 0.15

local function IsEnchantingRecipe(recipe)
    if type(recipe) ~= "table" then return false end
    local lines = ns.Recipes and ns.Recipes.SKILL_LINE_PROFESSIONS
    if type(lines) == "table" and lines[recipe.skillLineID] == "Enchanting" then return true end
    return recipe.profession == "Enchanting"
end

--- How many more crafts of a known recipe give a point every time at
--- `skill`. The profession window's own reading wins when it was taken at
--- this skill; otherwise up to the recipe's yellow, when the book knows it.
local function OrangeLeft(recipeID, recipe, skill)
    local book = ns.RecipeBook and ns.RecipeBook.Get and ns.RecipeBook:Get(recipeID)
    local yellow = book and tonumber(book.yellow)
    local read = type(recipe.skillUp) == "table" and recipe.skillUp or nil
    if read and read.tier and tonumber(read.skill) == skill then
        if read.tier ~= "optimal" then return 0 end
        return yellow and math.max(1, yellow - skill) or 1
    end
    if yellow then return math.max(0, yellow - skill) end
    if read and read.tier == "optimal" and read.skill == nil then return 1 end
    return 0
end

--- What one craft of a recipe costs, or nil when it can't be priced.
local function CraftCost(recipeID)
    local cost = ns.Cost
    if not (cost and cost.GetCraftCost) then return nil end
    local ok, detail = pcall(cost.GetCraftCost, cost, recipeID)
    if ok and type(detail) == "table" and detail.priceable then return tonumber(detail.total) end
    return nil
end

--- The disenchant materials the character playing still lacks for the
--- Enchanting crafts that give a point every time:
--- { [materialID] = { short, recipe } }.
-- The orange recipes are taken cheapest first, each for the points the ones
-- before it do not reach, so the stretch from the skill up is counted once.
-- What the character owns (bags, bank and mailbox) comes off, so it stops
-- once there is enough.
local function EnchantingShort(skill)
    local short = {}
    local recipes, disenchant = ns.Recipes, ns.Disenchant
    if not (skill and skill > 0 and recipes and recipes.GetAll
            and disenchant and disenchant.IsMaterial) then
        return short
    end

    local orange = {}
    for recipeID, recipe in pairs(recipes:GetAll() or {}) do
        if IsEnchantingRecipe(recipe)
            and not (recipes.IsDropped and recipes:IsDropped(recipe)) then
            local left = OrangeLeft(recipeID, recipe, skill)
            if left > 0 then
                orange[#orange + 1] = { recipeID = recipeID, recipe = recipe, top = skill + left,
                    cost = CraftCost(recipeID) }
            end
        end
    end
    table.sort(orange, function(a, b)
        if (a.cost ~= nil) ~= (b.cost ~= nil) then return a.cost ~= nil end
        if a.cost and a.cost ~= b.cost then return a.cost < b.cost end
        return a.recipeID < b.recipeID
    end)

    local covered, want, why = skill, {}, {}
    for _, craft in ipairs(orange) do
        if craft.top > covered then
            local crafts = craft.top - covered
            covered = craft.top
            for _, reagent in ipairs(type(craft.recipe.reagents) == "table" and craft.recipe.reagents or {}) do
                local id = type(reagent) == "table" and tonumber(reagent.itemID)
                if id and disenchant:IsMaterial(id) then
                    want[id] = (want[id] or 0) + crafts * (tonumber(reagent.quantity) or 1)
                    why[id] = why[id] or craft.recipe.name
                end
            end
        end
    end

    local inventory = ns.Inventory
    for id, wanted in pairs(want) do
        local have = inventory and inventory.GetOwnedCount and inventory:GetOwnedCount(id) or 0
        if wanted > have then short[id] = { short = wanted - have, recipe = why[id] } end
    end
    return short
end

--- A green this character can break that gives a material its Enchanting
--- still lacks for a sure point: { recipe, material, materialName, short,
--- yield }, or nil. Never crafted gear.
local function ForEnchanting(itemID, kept, quality, canDisenchant)
    if quality ~= 2 or canDisenchant ~= true or next(kept.enchanting) == nil then return nil end
    local book = ns.RecipeBook
    if book and book.IsCrafted and book:IsCrafted(itemID) then return nil end
    local disenchant = ns.Disenchant
    local outcomes = disenchant and disenchant.GetOutcomes and disenchant:GetOutcomes(itemID)
    if type(outcomes) ~= "table" then return nil end

    local best
    for _, outcome in ipairs(outcomes) do
        local wanted = kept.enchanting[outcome.itemID]
        if wanted and (outcome.chance or 0) >= Butler.LIKELY_OUTCOME
            and (not best or outcome.chance > best.chance) then
            best = outcome
        end
    end
    if not best then return nil end

    local wanted = kept.enchanting[best.itemID]
    local average = best.average or ((best.min or 1) + (best.max or best.min or 1)) / 2
    return {
        recipe = wanted.recipe,
        material = best.itemID,
        materialName = disenchant.MaterialName and disenchant:MaterialName(best.itemID) or nil,
        short = wanted.short,
        yield = best.chance * average,
    }
end

--- Is the character playing the disenchanter? true or nil.
local function DisenchanterHere()
    local mail = ns.QueueMail
    if not (mail and mail.IsDisenchanterPlaying) then return nil end
    local ok, here = pcall(mail.IsDisenchanterPlaying, mail)
    return (ok and here == true) or nil
end

local function Build()
    local selfKey = SelfKey()
    local selfSkill = EnchantingSkill(Characters()[selfKey])
    return {
        need = OwnNeeds(selfKey),
        mail = MailTargets(),
        selfSkill = selfSkill,
        enchanting = EnchantingShort(selfSkill),
        knows = KnowsDisenchant(),
        enchanters = Enchanters(selfKey),
        chosen = Chosen(),
        youDisenchant = DisenchanterHere(),
    }
end

--- The kept lookup, built again when the queue or bags moved or it is old.
local function Lookup()
    local key = ("%s:%s"):format(tostring(ns.Queue and ns.Queue.version),
        tostring(ns.Inventory and ns.Inventory.changes))
    local now = Now()
    if lookup and lookupKey == key and (now - lookupAt) < LOOKUP_SECONDS then
        return lookup
    end
    lookup, lookupKey, lookupAt = Build(), key, now
    return lookup
end

--- Forget the kept lookup (for tests).
function Butler:Forget()
    lookup, lookupKey, lookupAt = nil, nil, nil
end

--------------------------------------------------------------------------------
-- The answer
--------------------------------------------------------------------------------

local function Quality(itemID)
    local facts = ns.Disenchant and ns.Disenchant.GetItemFacts and ns.Disenchant:GetItemFacts(itemID)
    if facts and facts.quality then return facts.quality end

    if type(C_Item) == "table" and type(C_Item.GetItemQualityByID) == "function" then
        local ok, quality = pcall(C_Item.GetItemQualityByID, itemID)
        if ok then return tonumber(quality) end
    end
    return nil
end

--- The price of one, by the copy's link when Butler gave one: a random
--- suffix ("of the Monkey") with a price of its own is worth that.
local function PriceOf(itemID, link, which)
    local prices = ns.Prices
    if not prices then return nil end
    if link and prices.GetLinkValue then return (prices:GetLinkValue(link, which)) end
    if which == "rival" then return prices:GetScanValue(itemID, "rival") end
    return prices:GetValue(itemID, which)
end

local function Auction(itemID, quality, link)
    if quality == nil or quality == GREY then return nil end
    local util = ns.Util
    if util and util.IsBoundOnPickup and util.IsBoundOnPickup(itemID) == true then return nil end

    local price = PriceOf(itemID, link, "market")
    if not price or price <= 0 then return nil end

    local net = ns.Profit:NetFromListing(itemID, price)
    return math.max(0, math.floor(net + 0.5))
end

--- What one fetches at the cheapest listing that is not the player's, after
--- the cut and the deposit, only while the scan is fresh.
local function AuctionNow(itemID, auction, link)
    if not auction then return nil end
    local prices = ns.Prices
    if not (prices and prices.GetScanValue and prices.IsStale) then return nil end
    if prices:IsStale(itemID) then return nil end
    local rival = PriceOf(itemID, link, "rival")
    if not rival or rival <= 0 then return nil end
    local net = ns.Profit:NetFromListing(itemID, rival)
    return math.max(0, math.floor(net + 0.5))
end

--- What one costs to make, when the Sell list's price for it is under that
--- and Posting would refuse the listing. Only crafts are priced here, so the
--- other bag items cost one table read.
local function BelowCost(itemID, auction)
    if not auction then return nil end
    local posting, cost, made = ns.Posting, ns.Cost, ns.CraftedCost
    if not (posting and posting.BelowCost and posting.GetPostPrice) then return nil end
    local craft = cost and cost.FindAnyRecipeForItem and cost:FindAnyRecipeForItem(itemID)
    if not craft and not (made and made.Get and made:Get(itemID)) then return nil end

    local price = posting.GetChosenPrice and posting:GetChosenPrice(itemID)
    if not price then price = posting:GetPostPrice(itemID) end
    if type(price) ~= "number" or price <= 0 then return nil end

    local unitCost = posting:BelowCost(itemID, price)
    if not unitCost and posting.BelowCraftedCost then
        unitCost = posting:BelowCraftedCost(itemID, price)
    end
    if type(unitCost) ~= "number" then return nil end
    return math.floor(unitCost + 0.5)
end

local function Fast(itemID)
    local reading = ns.Demand and ns.Demand:Get(itemID)
    if not reading then return nil end
    if reading.level == "high" then return true end
    if reading.level == "low" then return false end
    return nil
end

--- Can this character break it, and if not, who can?
-- @return disenchant, canDisenchant, enchanter
local function Breaking(itemID, kept, quality)
    local disenchant = ns.Disenchant
    if not disenchant then return nil, nil, nil end

    local able = disenchant:IsDisenchantable(itemID)
    if able == nil then return nil, nil, nil end
    if not able then return nil, false, nil end

    local value, _, breakdown = disenchant:GetValue(itemID)
    local needs = breakdown and breakdown.facts and breakdown.facts.skill

    local function Enough(skill)
        return skill ~= nil and (needs == nil or skill >= needs)
    end

    -- Knowing the spell with no skill on record yet counts as able.
    local can = kept.knows ~= false
        and (Enough(kept.selfSkill) or (kept.selfSkill == nil and kept.knows == true))
    if can then return value, true, nil end

    local chosen = kept.chosen
    if chosen and (quality == nil or quality <= chosen.quality)
        and (not chosen.known or Enough(chosen.skill)) then
        return value, false, chosen.name
    end

    for _, alt in ipairs(kept.enchanters) do
        if Enough(alt.skill) then return value, false, alt.name end
    end
    return value, false, nil
end

--- How many the account bought to disenchant, or nil for none.
local function Bought(itemID)
    local buys = ns.DisenchantBuys
    local count = buys and buys.Count and buys:Count(itemID) or 0
    return count > 0 and count or nil
end

--- The disenchanter typed in Settings, when the Mail page sends it this item.
local function Disenchanter(itemID, kept, quality)
    local chosen, mail = kept.chosen, ns.QueueMail
    if not (chosen and mail and mail.GoesToDisenchanter) then return nil end
    if mail:GoesToDisenchanter(itemID, quality) then return chosen.name end
    return nil
end

--- Made by a profession? true or nil.
local function Crafted(itemID)
    local book = ns.RecipeBook
    if not (book and book.IsCrafted) then return nil end
    local ok, made = pcall(book.IsCrafted, book, itemID)
    return (ok and made == true) or nil
end

local function Answer(itemID, link)
    local kept = Lookup()
    local quality = Quality(itemID)
    local disenchant, canDisenchant, enchanter = Breaking(itemID, kept, quality)
    local mail = kept.mail[itemID]

    local auction = Auction(itemID, quality, link)
    return {
        auction = auction,
        auctionNow = AuctionNow(itemID, auction, link),
        belowCost = BelowCost(itemID, auction),
        fast = Fast(itemID),
        disenchant = disenchant,
        canDisenchant = canDisenchant,
        enchanter = enchanter,
        disenchanter = Disenchanter(itemID, kept, quality),
        need = kept.need[itemID],
        mailTo = mail and mail.name or nil,
        mailCount = mail and mail.count or nil,
        bought = Bought(itemID),
        forEnchanting = ForEnchanting(itemID, kept, quality, canDisenchant),
        youDisenchant = kept.youDisenchant,
        crafted = kept.youDisenchant and quality == 2 and Crafted(itemID) or nil,
    }
end

--- Everything Tradeskills can say about one item, for Butler.
-- Never raises, writes nothing; nil when the item ID is not one or anything
-- goes wrong. A fresh table each time, so Butler may keep or change it.
-- `item` is an item ID or the bag copy's link: a link prices a random suffix
-- ("of the Monkey") as that suffix sells, when its price is known.
function Butler:Advise(item)
    local itemID, link = tonumber(item), nil
    if not itemID and type(item) == "string" then
        local okID, fromLink = pcall(function() return tonumber(item:match("item:(%d+)")) end)
        if okID and fromLink then itemID, link = fromLink, item end
    end
    if not itemID then return nil end
    local ok, answer = pcall(Answer, itemID, link)
    if ok then return answer end
    return nil
end

--------------------------------------------------------------------------------
-- Crafts worth more than the item (Butler's "Craft When It Pays More")
--------------------------------------------------------------------------------

-- An auction the output rarely sells at counts at this much of itself, as
-- Butler counts a slow seller of its own.
Butler.SLOW = 0.75

--- [itemID] = { recipeID, ... } for the recipes the character playing knows
--- that use it and make an item.
local function ReagentIndex()
    local index = {}
    local recipes = ns.Recipes
    if not (recipes and recipes.GetAll) then return index end
    local selfKey = SelfKey()
    for recipeID, recipe in pairs(recipes:GetAll() or {}) do
        if type(recipe) == "table" and recipe.outputItemID
            and not (recipes.IsDropped and recipes:IsDropped(recipe, selfKey)) then
            for _, reagent in ipairs(type(recipe.reagents) == "table" and recipe.reagents or {}) do
                local id = type(reagent) == "table" and tonumber(reagent.itemID)
                if id and id ~= recipe.outputItemID then
                    local list = index[id] or {}
                    index[id] = list
                    list[#list + 1] = recipeID
                end
            end
        end
    end
    return index
end

--- What one craft of a recipe puts in the pocket, sold the best way: copper,
--- or nil when it has no real price.
local function CraftNet(recipeID)
    local profit = ns.Profit
    if not (profit and profit.Analyse) then return nil end
    local ok, analysis = pcall(profit.Analyse, profit, recipeID, SelfKey(), "best")
    if not ok or type(analysis) ~= "table" or not analysis.priceable then return nil end
    local way = analysis.ways and analysis.via and analysis.ways[analysis.via]
    if type(way) ~= "table" or not way.revenue then return nil end
    if way.basis == "derived" or way.basis == "uncontested" then return nil end
    local net = way.revenue - (way.cut or 0) - (way.deposit or 0)
    if analysis.via == "auction" then
        local reading = ns.Demand and ns.Demand.Get and ns.Demand:Get(analysis.outputItemID)
        if reading and reading.level == "low" then net = net * Butler.SLOW end
    end
    return net
end

--- One recipe weighed for one item, or nil.
local function Weigh(itemID, recipeID, carried)
    local recipe = ns.Recipes:Get(recipeID)
    if not recipe then return nil end
    local per = 0
    for _, reagent in ipairs(recipe.reagents or {}) do
        if tonumber(reagent.itemID) == itemID then per = per + (tonumber(reagent.quantity) or 1) end
    end
    if per <= 0 then return nil end
    local crafts = math.floor(carried / per)
    if crafts < 1 then return nil end

    local net = CraftNet(recipeID)
    if not net then return nil end

    local okCost, cost = pcall(ns.Cost.GetCraftCost, ns.Cost, recipeID, nil, nil, { valueOwned = true })
    if not okCost or type(cost) ~= "table" or not cost.priceable then return nil end

    local others, needs = 0, {}
    for _, line in ipairs(cost.reagents or {}) do
        if line.itemID ~= itemID then
            others = others + (line.lineCost or 0)
            local want = (line.quantity or 0) * crafts
            local inBags = line.inBags or 0
            if want > inBags then needs[#needs + 1] = { itemID = line.itemID, count = want - inBags } end
        end
    end

    return {
        recipeID = recipeID,
        name = recipe.name,
        itemID = recipe.outputItemID,
        per = per,
        crafts = crafts,
        perItem = math.floor((net - others) / per),
        needs = needs,
    }
end

--- The craft that makes one of this item worth the most, or nil.
-- Only while Butler's setting is on: Butler asks nothing otherwise.
function Butler:CraftFor(item, carried, skip)
    local itemID = tonumber(item)
    if not itemID and type(item) == "string" then itemID = tonumber(item:match("item:(%d+)")) end
    if not itemID then return nil end
    local ok, answer = pcall(function()
        local kept = Lookup()
        kept.reagents = kept.reagents or ReagentIndex()
        local list = kept.reagents[itemID]
        if not list then return nil end
        local have = tonumber(carried)
        if not have and ns.Inventory and ns.Inventory.GetBagCount then
            have = ns.Inventory:GetBagCount(itemID)
        end
        have = have or 0

        kept.crafts = kept.crafts or {}
        local best
        if type(skip) ~= "table" then skip = nil end
        for _, recipeID in ipairs(list) do
          if not (skip and skip[recipeID] ~= nil) then
            local key = recipeID .. ":" .. itemID .. ":" .. have
            local weighed = kept.crafts[key]
            if weighed == nil then
                weighed = Weigh(itemID, recipeID, have) or false
                kept.crafts[key] = weighed
            end
            if weighed and (not best or weighed.perItem > best.perItem) then best = weighed end
          end
        end
        if not best then return nil end
        local needs = {}
        for i, need in ipairs(best.needs) do needs[i] = { itemID = need.itemID, count = need.count } end
        return { recipeID = best.recipeID, name = best.name, itemID = best.itemID, per = best.per,
            crafts = best.crafts, perItem = best.perItem, needs = needs }
    end)
    if ok then return answer end
    return nil
end

--- Queue at least `crafts` of a recipe, from Butler's Queue button.
-- @return true, or false and why; never raises
function Butler:QueueCraft(recipeID, crafts)
    local queue = ns.Queue
    if not (queue and queue.Ensure) then return false, L["the queue would not take it"] end
    local ok, done, why = pcall(queue.Ensure, queue, recipeID, crafts)
    if ok and done then return true end
    return false, ok and why or nil
end

--- Mark an item bought to disenchant, `count` of them (at least one), or
--- take the mark off. Never raises.
-- @return true, or false and why
function Butler:SetBoughtToDisenchant(itemID, on, count)
    itemID = tonumber(itemID)
    local buys = ns.DisenchantBuys
    if not itemID or not buys then return false, L["Tradeskills can't mark that."] end
    local ok, err = pcall(function()
        if on then
            buys:Mark(itemID, math.max(1, tonumber(count) or 1))
        else
            buys:Unmark(itemID)
        end
    end)
    if not ok then return false, tostring(err) end
    return true
end

--------------------------------------------------------------------------------
-- Every character's bags, bank and mail, for Butler's All characters list
--------------------------------------------------------------------------------

--- A copy of an { [itemID] = count } table, keeping only real counts.
local function Counts(counts)
    local copy = {}
    if type(counts) ~= "table" then return copy end
    for itemID, count in pairs(counts) do
        if type(itemID) == "number" and type(count) == "number" and count > 0 then
            copy[itemID] = count
        end
    end
    return copy
end

local function Stamp(value)
    return type(value) == "number" and value or nil
end

local function LiveBags()
    local inventory = ns.Inventory
    if not (inventory and inventory.GetBagCounts) then return nil end
    local ok, live = pcall(inventory.GetBagCounts, inventory)
    if ok and type(live) == "table" then return live end
    return nil
end

local function Holdings()
    local list = {}
    local records = Characters()
    local recipes = ns.Recipes
    if not (recipes and recipes.GetCharacters) then return list end

    for _, character in ipairs(recipes:GetCharacters()) do
        local record = records[character.key]
        if type(record) == "table" then
            local entry = {
                key = character.key,
                name = character.name,
                short = ShortName(character.key),
                realm = type(record.realm) == "string" and record.realm or nil,
                faction = type(record.faction) == "string" and record.faction or nil,
                isCurrent = character.isCurrent == true,
                -- The character playing under any of its records (an old
                -- name-realm one beside its GUID one): never one to mail,
                -- top up or log out for (Characters:IsPlaying).
                playing = character.isCurrent == true
                    or (ns.Characters ~= nil and ns.Characters:IsPlaying(character.key) == true),
                linked = character.linkedFrom,
                bank = Counts(record.bank),
                mail = Counts(record.mail),
                bankAt = Stamp(record.bankAt),
                mailAt = Stamp(record.mailAt),
            }
            -- Gold as last seen, for Butler's gold top-ups (2026-10-11):
            -- the character playing's purse is live.
            entry.gold = type(record.gold) == "number" and record.gold or nil
            entry.goldAt = entry.gold and Stamp(record.inventoryAt) or nil
            if entry.isCurrent and type(GetMoney) == "function" then
                local okMoney, money = pcall(function() return tonumber(GetMoney()) end)
                if okMoney and money then
                    entry.gold = money
                    entry.goldAt = type(time) == "function" and time() or entry.goldAt
                end
            end
            local live = entry.isCurrent and LiveBags()
            if live then
                entry.bags = Counts(live)
                entry.bagsAt = type(time) == "function" and time() or Stamp(record.inventoryAt)
            else
                entry.bags = Counts(record.inventory)
                entry.bagsAt = Stamp(record.inventoryAt)
            end
            list[#list + 1] = entry
        end
    end
    return list
end

--- What every character on record carries, banks and has waiting in the
-- mail, for Butler. Never raises, writes nothing; nil when anything goes
-- wrong. Fresh tables each time, so Butler may keep or change them.
function Butler:Holdings()
    local ok, list = pcall(Holdings)
    if ok then return list end
    return nil
end

--------------------------------------------------------------------------------
-- The mailbox and the bank, for Butler
--------------------------------------------------------------------------------

--- The character a short name from Advise or Holdings means: the one whose
-- ShortName is exactly `name`, or nil when none is. A short name can be
-- "Ana B." when two characters share a first name, which
-- QueueMail:FindCharacter cannot read back (the mail went to "Ana B.").
-- More than one record can give the same short name (a character kept
-- under two keys, or a linked copy), so of those the best is taken: one of
-- this account's own, on this realm, then the lowest key. The character
-- playing, under any of its records, is never the answer.
local function CharacterNamed(name)
    local selfRecord = Characters()[SelfKey() or ""]
    local realm = type(selfRecord) == "table" and selfRecord.realm or nil

    -- "Ana S." also matches any "Ana S..." by full name, in case the short
    -- names were worked out differently when Advise gave this one.
    local first, initial = name:match("^(%S+) (%S+)%.$")
    local prefix = first and (first .. " " .. initial)
    local recipes = ns.Recipes
    local function Matches(characterKey)
        if ShortName(characterKey) == name then return true end
        if not (prefix and recipes and recipes.GetCharacterName) then return false end
        local ok, full = pcall(recipes.GetCharacterName, recipes, characterKey)
        return ok and type(full) == "string" and full:sub(1, #prefix) == prefix
    end

    local mail = ns.QueueMail
    local function Playing(characterKey)
        return mail and mail.IsPlaying and mail:IsPlaying(characterKey) == true
    end

    local best, bestScore
    for characterKey, record in pairs(Characters()) do
        if type(record) == "table" and not Playing(characterKey) and Matches(characterKey) then
            local score = (record.linkedFrom == nil and 2 or 0)
                + ((realm and record.realm == realm) and 1 or 0)
            if not best or score > bestScore
                or (score == bestScore and tostring(characterKey) < tostring(best)) then
                best, bestScore = characterKey, score
            end
        end
    end
    return best
end

--- Fill the game's Send Mail page for one of the player's characters.
-- `name` is a short name (as Advise gives it) or a name typed in Settings;
-- `items` is a list of { itemID, count }. Nothing is sent: the player
-- presses Send. Never raises. Never fills a mail to the character playing
-- (a player found one, 2026-10-11): that is "false" and why.
-- @return true when filling started, or false and why; then the name the
--   mail is addressed to, in full
function Butler:FillMail(name, items, money)
    local mail = ns.QueueMail
    if not (mail and mail.Fill) then return false, L["Tradeskills cannot fill mail here"] end
    if type(name) ~= "string" or name == "" then return false, L["nobody to mail"] end
    money = tonumber(money)
    money = money and money >= 1 and math.floor(money) or nil
    if type(items) ~= "table" then items = {} end
    if #items == 0 and not money then return false, L["nothing to mail"] end

    local list = {}
    for _, item in ipairs(items) do
        local itemID = type(item) == "table" and tonumber(item.itemID)
        local count = type(item) == "table" and tonumber(item.count)
        if itemID and count and count > 0 then
            list[#list + 1] = { itemID = itemID, count = math.floor(count) }
        end
    end
    if #list == 0 and not money then return false, L["nothing to mail"] end

    local toSelf = L["that's the character you're on"]
    local recipient
    local ok, started, why = pcall(function()
        local key = CharacterNamed(name) or (mail.FindCharacter and mail:FindCharacter(name))
        if key == nil and mail.IsPlayingName and mail:IsPlayingName(name) then return false, toSelf end
        if key ~= nil and mail.IsPlaying and mail:IsPlaying(key) then return false, toSelf end
        recipient = key and mail.MailName and mail.MailName(Characters()[key]) or name
        if mail.IsPlayingName and mail:IsPlayingName(recipient) then return false, toSelf end
        return mail:Fill({ recipient = recipient, items = list, money = money,
            subject = #list == 0 and "Gold from Blackthornes Butler" or "From Blackthornes Butler" },
            Butler.FillDone)
    end)
    if not ok then return false, L["Tradeskills could not fill the mail"] end
    if started == true then return true, nil, recipient end
    return false, why
end

--- What a mail Butler filled left out, said in chat: Butler's window
--- covers the mail panel that would say it (two herbs went missing from a
--- mail with nothing said, 2026-10-13).
function Butler.FillDone(attached, leftOver)
    if not (leftOver and leftOver > 0) then return end
    if ns.QueueMail and ns.QueueMail.splitBlocked then
        ns.Print(L["Free one bag slot to split a stack, then press the button again."])
    else
        ns.Print(L.Format("%d attached; the rest go in the next mail. Press Send.", attached or 0))
    end
end

local function FromBank()
    local wants = {}
    local selfKey = SelfKey()
    local mail, inventory = ns.QueueMail, ns.Inventory
    if not (selfKey and mail and mail.GetPlan and inventory) then return wants end

    local uses, makes = mail:GetPlan()
    local myUse, myMake = uses[selfKey] or {}, makes[selfKey] or {}
    for itemID, used in pairs(myUse) do
        local carried = inventory.GetBagCount and inventory:GetBagCount(itemID) or 0
        local banked = inventory.GetBankCount and inventory:GetBankCount(itemID) or 0
        local short = used - (myMake[itemID] or 0) - carried
        local take = math.min(short, banked)
        if take > 0 then wants[itemID] = take end
    end

    -- And what its mail for another character's craft has to take out of
    -- the bank first (a player opened the bank with the leather for one
    -- in it, and Butler stayed shut, 2026-10-11).
    for _, job in ipairs(Butler:Jobs() or {}) do
        if job.isCurrent then
            for _, step in ipairs(job.steps) do
                for _, item in ipairs(step.kind == "mail" and step.forCraft and step.items or {}) do
                    if item.bank then
                        local banked = inventory.GetBankCount and inventory:GetBankCount(item.itemID) or 0
                        wants[item.itemID] = math.min(banked, (wants[item.itemID] or 0) + item.bank)
                    end
                end
            end
        end
    end
    return wants
end

--- What the character playing's own queued crafts want from its bank, and
-- what its mail for another character's craft has to take out first:
-- { [itemID] = count }. Never raises, writes nothing; nil on any error.
function Butler:FromBank()
    local ok, wants = pcall(FromBank)
    if ok then return wants end
    return nil
end

--------------------------------------------------------------------------------
-- Jobs across characters, for Butler's step list
--------------------------------------------------------------------------------

local function FullName(characterKey)
    local recipes = ns.Recipes
    if recipes and recipes.GetCharacterName then
        local ok, name = pcall(recipes.GetCharacterName, recipes, characterKey)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    return tostring(characterKey)
end

local function ItemList(counts)
    local list = {}
    for itemID, count in pairs(type(counts) == "table" and counts or {}) do
        if type(itemID) == "number" and type(count) == "number" and count > 0 then
            list[#list + 1] = { itemID = itemID, count = count }
        end
    end
    table.sort(list, function(a, b) return a.itemID < b.itemID end)
    return list
end

-- Are two records the same character? Characters:Same, the one test.
local function SameCharacter(_, a, b)
    if a == b then return true end
    return ns.Characters ~= nil and ns.Characters:Same(a, b) == true
end

-- The other character holding the most of an item in its bags and bank,
-- never another account's. The character playing counts, read live, so
-- the leather it holds is a step on its own line (a player logged in on
-- the holder and the mail step was gone, 2026-10-11); its other records
-- never do. The key, how many, and for the character playing how many of
-- them are in its bags; or nil.
local function Holder(records, crafterKey, itemID, Playing, selfKey)
    local bestKey, bestCount = nil, 0
    for key, record in pairs(records) do
        if key ~= crafterKey and type(record) == "table" and not record.linkedFrom and not Playing(key) then
            local count = 0
            if type(record.inventory) == "table" then count = count + (tonumber(record.inventory[itemID]) or 0) end
            if type(record.bank) == "table" then count = count + (tonumber(record.bank[itemID]) or 0) end
            if count > bestCount or (count == bestCount and count > 0 and tostring(key) < tostring(bestKey)) then
                bestKey, bestCount = key, count
            end
        end
    end
    local inventory = ns.Inventory
    if selfKey and not Playing(crafterKey) and inventory and inventory.GetBagCount then
        local bags = inventory:GetBagCount(itemID) or 0
        local bank = inventory.GetBankCount and inventory:GetBankCount(itemID) or 0
        if bags + bank > 0 and bags + bank >= bestCount then
            return selfKey, bags + bank, bags
        end
    end
    if bestKey then return bestKey, bestCount end
    return nil
end

--- Copper for one from a vendor, or nil when no vendor is known to sell it.
local function VendorPrice(itemID)
    local vendor = ns.Vendor
    if not (vendor and vendor.GetUnitPrice) then return nil end
    local ok, price = pcall(vendor.GetUnitPrice, vendor, itemID)
    price = ok and tonumber(price) or nil
    if price and price > 0 then return price end
    return nil
end

local function Jobs()
    local list = {}
    local queue, mail = ns.Queue, ns.QueueMail
    local selfKey = SelfKey()
    if not (selfKey and queue and queue.GetAll and queue.GetCrafter and ns.Recipes) then return list end

    local records = Characters()
    local byKey = {}
    local function Playing(characterKey)
        return characterKey == selfKey
            or (mail and mail.IsPlaying and mail:IsPlaying(characterKey) == true)
    end

    -- A character's entry, made the first time it has a step. The character
    -- playing, under any of its records, is one entry.
    local function Job(characterKey)
        local playing = Playing(characterKey)
        local key = playing and selfKey or characterKey
        if byKey[key] then return byKey[key] end
        local record = records[key]
        if type(record) ~= "table" or record.linkedFrom then return nil end
        -- Another record of a character already listed (an old name-realm
        -- one beside its GUID one) is that character, never a second line
        -- (a player was told to log out for the character they were on,
        -- 2026-10-11).
        for otherKey, other in pairs(byKey) do
            if SameCharacter(records, otherKey, key) then
                -- Named by its GUID record, which has the whole name.
                if tostring(key):find("^Player%-") and not tostring(other.key):find("^Player%-") then
                    other.key, other.name = key, FullName(key)
                end
                byKey[key] = other
                return other
            end
        end
        if not playing and not queue:CanMail(selfKey, key) then return nil end
        local job = { key = key, name = FullName(key), isCurrent = playing, steps = {} }
        byKey[key] = job
        return job
    end

    for _, entry in ipairs(queue:GetAll()) do
        local recipe = type(entry) == "table" and ns.Recipes:GetAny(entry.recipeID)
        local crafts = type(entry) == "table" and tonumber(entry.quantity) or 0
        if recipe and crafts > 0 then
            local crafter = queue:GetCrafter(entry)
            local job = crafter and Job(crafter)
            if job then
                local forNames = {}
                for _, characterKey in ipairs(queue:GetRecipients(entry)) do
                    if not Playing(characterKey) or not job.isCurrent then
                        forNames[#forNames + 1] = FullName(characterKey)
                    end
                end
                local missing = {}
                job.wants = job.wants or {}
                for _, reagent in ipairs(recipe.reagents or {}) do
                    local want = (reagent.quantity or 0) * crafts
                    job.wants[reagent.itemID] = (job.wants[reagent.itemID] or 0) + want
                    local held = queue:HeldBy(job.key, reagent.itemID) or 0
                    if want > held then
                        -- `vendor`: copper for one when a vendor sells it, so
                        -- Butler lists it under Buy from a vendor (the owner,
                        -- 2026-10-13).
                        missing[#missing + 1] = { itemID = reagent.itemID, count = want - held,
                            vendor = VendorPrice(reagent.itemID) }
                    end
                end
                -- Bag slots making it frees, for the character playing only
                -- (the bags are read live), while "Craft what frees bag
                -- space first" is on.
                local slots
                if job.isCurrent and ns.Crafting and ns.Crafting.FreesSpaceFirst and ns.Crafting:FreesSpaceFirst() then
                    local okSlots, freed = pcall(ns.Crafting.SlotsFreed, ns.Crafting, entry)
                    if okSlots and type(freed) == "number" then slots = freed end
                end
                job.steps[#job.steps + 1] = {
                    kind = "craft",
                    slots = slots,
                    recipeID = entry.recipeID,
                    itemID = recipe.outputItemID,
                    name = recipe.name,
                    crafts = crafts,
                    count = crafts * math.max(1, recipe.quantityMin or 1),
                    forNames = forNames,
                    ready = #missing == 0,
                    missing = missing,
                }
            end
        end
    end

    -- A craft held up for materials another character has: that character
    -- mails them over first, so its line can come first in Butler (the
    -- owner, 2026-10-11: a sub-craft whose materials are on hand goes to
    -- the top). An old name-realm record of the crafter itself counts as
    -- the crafter's own.
    local blocked, counted = {}, {}
    for _, job in pairs(byKey) do
        if not counted[job] then
            counted[job] = true
            for _, step in ipairs(job.steps) do
                if step.kind == "craft" and not step.ready then blocked[#blocked + 1] = { job = job, step = step } end
            end
        end
    end
    table.sort(blocked, function(a, b)
        if a.job.name ~= b.job.name then return a.job.name < b.job.name end
        return (a.step.recipeID or 0) < (b.step.recipeID or 0)
    end)
    for _, item in ipairs(blocked) do
        local job, step = item.job, item.step
        local still = {}
        for _, need in ipairs(step.missing) do
            local holderKey, holderCount, inBags = Holder(records, job.key, need.itemID, Playing, selfKey)
            if holderKey and SameCharacter(records, holderKey, job.key) then
                need.count = need.count - holderCount
                if need.count > 0 then still[#still + 1] = need end
            else
                still[#still + 1] = need
                local holder = holderKey and queue:CanMail(holderKey, job.key) and Job(holderKey)
                if holder then
                    local count = math.min(holderCount, need.count)
                    need.from = holder.name
                    local to = job.name
                    local letter
                    for _, other in ipairs(holder.steps) do
                        if other.kind == "mail" and other.to == to and other.forCraft then letter = other end
                    end
                    if not letter then
                        letter = { kind = "mail", to = to, items = {}, crafts = false, forCraft = true }
                        table.insert(holder.steps, 1, letter)
                    end
                    -- What the character playing has to take out of its bank first.
                    local bank = inBags and math.max(0, count - inBags) or 0
                    letter.items[#letter.items + 1] = { itemID = need.itemID, count = count,
                        bank = bank > 0 and bank or nil }
                end
            end
        end
        step.missing = still
        step.ready = #still == 0
    end

    -- What the character playing can mail now, as the Mail panel has it.
    if mail and mail.GetDeliveries then
        local job = Job(selfKey)
        for _, delivery in ipairs(job and mail:GetDeliveries() or {}) do
            local to = FullName(delivery.to)
            -- A material already in a letter for a craft to the same
            -- character is that letter's, never a second step.
            local letter
            for _, step in ipairs(job.steps) do
                if step.kind == "mail" and step.forCraft and step.to == to then letter = step end
            end
            local items = {}
            for _, item in ipairs(delivery.items or {}) do
                local same
                for _, other in ipairs(letter and letter.items or {}) do
                    if other.itemID == item.itemID then same = other end
                end
                if same then
                    if (tonumber(item.count) or 0) > same.count then same.count = item.count end
                else
                    items[#items + 1] = { itemID = item.itemID, count = item.count }
                end
            end
            if #items > 0 and not Playing(delivery.to) then
                job.steps[#job.steps + 1] = { kind = "mail", to = to,
                    items = items, crafts = delivery.crafts == true }
            end
        end
    end

    -- The others: what they made for someone and still owe.
    if mail and mail.GetOwedBy then
        local keys = {}
        for characterKey in pairs(records) do keys[#keys + 1] = characterKey end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, fromKey in ipairs(keys) do
            if not Playing(fromKey) then
                local owed = mail:GetOwedBy(fromKey)
                local targets = {}
                for toKey in pairs(owed) do targets[#targets + 1] = toKey end
                table.sort(targets, function(a, b) return tostring(a) < tostring(b) end)
                for _, toKey in ipairs(targets) do
                    local items = ItemList(owed[toKey])
                    -- Never a mail to itself, under any record of it.
                    local job = #items > 0 and not SameCharacter(records, fromKey, toKey)
                        and not (Playing(toKey) and Playing(fromKey)) and Job(fromKey)
                    if job then
                        job.steps[#job.steps + 1] = { kind = "mail", to = FullName(toKey),
                            items = items, crafts = true }
                    end
                end
            end
        end
    end

    -- Mail waiting for a character (the owner, 2026-10-13: "if a character
    -- needs to visit the mail for something sent to it, butler should move
    -- that up the priority list"): materials its crafts count on that sit
    -- in its mailbox or are still on their way, and anything else mailed
    -- to it and not yet seen arrive. One "pickup" step, first on its line.
    local waiting = {}
    local function Wait(job, itemID, count, forCraft)
        local pickup = waiting[job]
        if not pickup then
            pickup = { kind = "pickup", items = {}, byID = {}, forCraft = false }
            waiting[job] = pickup
        end
        local item = pickup.byID[itemID]
        if not item then
            item = { itemID = itemID, count = 0 }
            pickup.byID[itemID] = item
            pickup.items[#pickup.items + 1] = item
        end
        item.count = math.max(item.count, count)
        pickup.forCraft = pickup.forCraft or forCraft
    end
    local listed = {}
    for _, job in pairs(byKey) do
        if not listed[job] then
            listed[job] = true
            local key = job.isCurrent and selfKey or job.key
            for itemID, want in pairs(queue.InMailFor and job.wants or {}) do
                local inMail = queue:InMailFor(key, itemID) or 0
                if inMail > 0 then
                    local inHand = math.max(0, (queue:HeldBy(key, itemID) or 0) - inMail)
                    local fromMail = math.min(inMail, want - inHand)
                    if fromMail > 0 then Wait(job, itemID, fromMail, true) end
                end
            end
        end
    end
    if mail and mail.InFlightItems then
        local keys = {}
        for characterKey in pairs(records) do keys[#keys + 1] = characterKey end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, toKey in ipairs(keys) do
            for itemID, count in pairs(mail:InFlightItems(toKey)) do
                local job = count > 0 and Job(toKey)
                if job then Wait(job, itemID, count, false) end
            end
        end
    end
    for job, pickup in pairs(waiting) do
        pickup.byID = nil
        table.sort(pickup.items, function(a, b) return a.itemID < b.itemID end)
        table.insert(job.steps, 1, pickup)
    end
    for _, job in pairs(byKey) do job.wants = nil end

    -- A profession cooldown that is up (a transmute, Mooncloth): a step on
    -- that character's line, so Butler can send the player there
    -- (Logic/Cooldowns.lua; the owner asked 2026-10-12).
    local cooldowns = ns.Cooldowns
    if cooldowns and cooldowns.ReadyList then
        for _, ready in ipairs(cooldowns:ReadyList()) do
            local job = Job(ready.key)
            if job then
                job.steps[#job.steps + 1] = { kind = "cooldown", recipeID = ready.recipeID,
                    itemID = ready.itemID, name = ready.group, craft = ready.name }
            end
        end
    end

    local seen = {}
    for _, job in pairs(byKey) do
        if #job.steps > 0 and not seen[job] then
            seen[job] = true
            list[#list + 1] = job
        end
    end
    table.sort(list, function(a, b)
        if a.isCurrent ~= b.isCurrent then return a.isCurrent end
        if a.name ~= b.name then return a.name < b.name end
        return tostring(a.key) < tostring(b.key)
    end)
    return list
end

--- Every character's jobs in the queue, for Butler's step list. Never
--- raises, writes nothing; nil on any error. Fresh tables each time.
function Butler:Jobs()
    local ok, list = pcall(Jobs)
    if ok then return list end
    return nil
end

--- Make the character playing's queued craft of a recipe, from Butler's
--- click (a craft needs a real click, and Butler's is one). Started when
--- the profession window shows the recipe; otherwise the Queue tab opens,
--- where the Open button opens the profession. Never raises.
-- @return true and "crafting" or "opened", or false and why
function Butler:Craft(recipeID)
    recipeID = tonumber(recipeID)
    if not recipeID then return false, L["nothing to craft"] end
    local ok, done, why = pcall(function()
        local queue, crafting = ns.Queue, ns.Crafting
        local selfKey = SelfKey()
        local entry
        for _, queued in ipairs(queue:GetAll()) do
            if queued.recipeID == recipeID and (tonumber(queued.quantity) or 0) > 0
                and queue:GetCrafter(queued) == selfKey then
                entry = queued
                break
            end
        end
        -- A profession cooldown that is up is made once, queued or not.
        local cooldowns = ns.Cooldowns
        if not entry and cooldowns and cooldowns.ReadyHere and cooldowns:ReadyHere(recipeID) then
            entry = { recipeID = recipeID, quantity = 1, cooldown = true }
        end
        if not entry then return false, L["it's no longer in your queue"] end
        local ready, reason = crafting:GetReadiness(recipeID)
        if not ready then return false, reason end
        if crafting:IsBusy() then return false, L["already crafting"] end
        local opener = ns.ProfessionOpener
        if opener and opener.InBlockingForm and opener:InBlockingForm() then
            return false, L["leave your form first"]
        end
        local shows = crafting.isTradeSkillOpen
            and (not (opener and opener.WindowShowsRecipe) or opener:WindowShowsRecipe(recipeID))
        if shows then
            if crafting:Start(recipeID, entry.quantity) then return true, "crafting" end
            return false, L["the game didn't start it"]
        end
        if entry.cooldown then return false, L["open your profession first"] end
        if queue:ShowQueue() then return true, "opened" end
        return false, L["open your profession first"]
    end)
    if not ok then return false, L["Tradeskills could not start the craft"] end
    return done == true, why
end

--- The profession a recipe is made in, for Butler's Craft button (the owner
--- asked 2026-10-15 for it to open the profession, as the Queue tab's craft
--- button does): `name` as the client gives it, `spell` the spell that opens
--- its window (Smelting for Mining), `open` true while the profession window
--- shows the recipe, so a click crafts. Opening it is a cast, so Butler lays
--- a secure button of its own set to `spell` over its Craft button. nil for
--- a recipe with no window to open or one not known. Never raises.
function Butler:Profession(recipeID)
    recipeID = tonumber(recipeID)
    if not recipeID then return nil end
    local ok, result = pcall(function()
        local opener = ns.ProfessionOpener
        if not (opener and opener.ProfessionFor) then return nil end
        local profession = opener:ProfessionFor(recipeID)
        if type(profession) ~= "table" or type(profession.spell) ~= "string" then return nil end
        local open = ns.Crafting and ns.Crafting.isTradeSkillOpen
            and (not opener.WindowShowsRecipe or opener:WindowShowsRecipe(recipeID))
        return { name = profession.name, spell = profession.spell, open = open and true or false }
    end)
    if ok and type(result) == "table" then return result end
    return nil
end

--- Butler takes over the mailbox (the owner picked it, 2026-10-11): while
-- its window is up at a mailbox it says `covered` true, and the mail panel
-- beside the mailbox (UI/QueueMailPanel.lua) steps aside; false brings it
-- back. Never raises.
function Butler:Mailbox(covered)
    pcall(function()
        local panel = ns.QueueMailPanel
        if not panel then return end
        panel.coveredByButler = covered == true
        if panel.coveredByButler then
            if panel.frame then panel.frame:Hide() end
        else
            panel:Refresh()
        end
    end)
end

--------------------------------------------------------------------------------
-- Trainer recipes to learn, for Butler's gold goals
--------------------------------------------------------------------------------

local LEARN_COST_SECONDS = 30
local learnCost, learnCostKey, learnCostAt

--- The character playing's recipes stamp: moves when they are read again.
local function RecipesStamp()
    local record = Characters()[SelfKey() or ""]
    return type(record) == "table" and tostring(record.recipesCachedAt or 0) or "0"
end

local function LearnCost()
    local book, skillUp = ns.RecipeBook, ns.SkillUp
    if not (book and skillUp and book.GetAll and skillUp.ReadSkillLevels) then return nil end
    local key = (SelfKey() or "?") .. ":" .. RecipesStamp()
    if learnCost and learnCostKey == key and Now() - (learnCostAt or 0) < LEARN_COST_SECONDS then
        return learnCost
    end

    local classic = book.ClassicLine or function(id) return id end
    local skills = {}
    for line, level in pairs(skillUp:ReadSkillLevels() or {}) do
        skills[classic(line)] = math.max(skills[classic(line)] or 0, tonumber(level) or 0)
    end

    local answer, knowsSome = {}, {}
    local records = book:GetAll() or {}
    for _, record in pairs(records) do
        local line = classic(record.skillLineID)
        if skills[line] and book:KnowsIt(record) then knowsSome[line] = true end
    end
    local LearnNext = ns.LearnNext
    for _, record in pairs(records) do
        local line = classic(record.skillLineID)
        local skill, needs = skills[line], record.skill
        if skill and knowsSome[line] and needs and needs <= skill and record.trainerCost
            and not record.starter and not book:KnowsIt(record) then
            local tier = LearnNext and LearnNext.Tier and LearnNext.Tier(record, skill) or "unknown"
            if tier == "unknown" and LearnNext and skill >= needs + (LearnNext.UNKNOWN_GREY or 75) then
                tier = "trivial"
            end
            if tier ~= "trivial" then
                local entry = answer[line]
                if not entry then
                    entry = { skill = skill, count = 0, cost = 0, recipes = {} }
                    answer[line] = entry
                end
                entry.count = entry.count + 1
                entry.cost = entry.cost + (tonumber(record.trainerCost) or 0)
                entry.recipes[#entry.recipes + 1] = {
                    recipeID = record.recipeID, name = record.name, cost = tonumber(record.trainerCost) or 0,
                }
            end
        end
    end
    for line in pairs(knowsSome) do
        if not answer[line] then answer[line] = { skill = skills[line], count = 0, cost = 0, recipes = {} } end
    end
    for _, entry in pairs(answer) do
        table.sort(entry.recipes, function(a, b)
            if a.cost ~= b.cost then return a.cost < b.cost end
            return (a.name or "") < (b.name or "")
        end)
    end

    learnCost, learnCostKey, learnCostAt = answer, key, Now()
    return answer
end

--- The trainers' recipes the character playing could learn now, by
--- profession, for Butler's gold goals. Never raises, writes nothing; nil
--- on any error. A fresh table each time.
function Butler:LearnCost()
    local ok, answer = pcall(LearnCost)
    if not (ok and type(answer) == "table") then return nil end
    local copy = {}
    for line, entry in pairs(answer) do
        local recipes = {}
        for i, recipe in ipairs(entry.recipes or {}) do
            recipes[i] = { recipeID = recipe.recipeID, name = recipe.name, cost = recipe.cost }
        end
        copy[line] = { skill = entry.skill, count = entry.count, cost = entry.cost, recipes = recipes }
    end
    return copy
end

--------------------------------------------------------------------------------
-- The cheapest next skill point, for Butler's Jobs
--------------------------------------------------------------------------------

local SKILL_UP_SECONDS = 30
local skillUp, skillUpKey, skillUpAt

-- The tiers Butler offers: a sure point, then a likely one.
local SKILL_UP_TIERS = { optimal = true, medium = true }

local function ReadLine(skillLineID)
    local trade = C_TradeSkillUI
    if not (skillLineID and type(trade) == "table" and type(trade.GetProfessionInfoBySkillLineID) == "function") then
        return nil
    end
    local ok, info = pcall(trade.GetProfessionInfoBySkillLineID, skillLineID)
    if ok and type(info) == "table" then return info end
    return nil
end

--- The character's learned professions, found by skill line, by the
--- client's name and by the English name of either of Forever's two IDs.
local function LearnedLookup()
    local byLine, byName, byEnglish = {}, {}, {}
    local recipes = ns.Recipes
    if not (recipes and recipes.GetLearnedProfessions) then return byLine, byName, byEnglish end
    local ok, list = pcall(recipes.GetLearnedProfessions, recipes)
    local english = recipes.SKILL_LINE_PROFESSIONS or {}
    for _, entry in ipairs(ok and type(list) == "table" and list or {}) do
        if type(entry) == "table" and (tonumber(entry.maxSkillLevel) or 0) > 0 and entry.name then
            local info = { professionName = entry.name, skillLevel = entry.skillLevel,
                maxSkillLevel = entry.maxSkillLevel }
            if entry.skillLineID then byLine[entry.skillLineID] = info end
            byName[entry.name] = info
            local word = english[entry.skillLineID]
                or (recipes.EnglishProfessionName and recipes.EnglishProfessionName(entry))
            if word then byEnglish[word] = info end
        end
    end
    return byLine, byName, byEnglish
end

--- A recipe's profession with its levels. Forever lists each profession
--- under two skill-line IDs and only one of them may carry the levels, so
--- a recipe tagged with the other found nothing and Butler's line stayed
--- empty (2026-10-20). The other ID, and the last good read Recipes keeps,
--- fill in for it.
local function ProfessionOf(skillLineID, lookup)
    local info = ReadLine(skillLineID)
    if info and (tonumber(info.maxSkillLevel) or 0) > 0 and info.professionName then return info end
    if not skillLineID then return nil end
    lookup.byLine = lookup.byLine or { LearnedLookup() }
    local byLine, byName, byEnglish = lookup.byLine[1], lookup.byLine[2], lookup.byLine[3]
    local found = byLine[skillLineID]
        or (info and info.professionName and byName[info.professionName])
    local english = ns.Recipes and ns.Recipes.SKILL_LINE_PROFESSIONS
        and ns.Recipes.SKILL_LINE_PROFESSIONS[skillLineID]
    if not english and info and info.professionName and ns.Recipes.EnglishProfessionName then
        english = ns.Recipes.EnglishProfessionName(info.professionName)
    end
    if not found and english then
        found = byEnglish[english]
        if not found then
            for otherID, other in pairs(ns.Recipes.SKILL_LINE_PROFESSIONS) do
                if other == english and otherID ~= skillLineID then
                    local sibling = ReadLine(otherID)
                    if sibling and (tonumber(sibling.maxSkillLevel) or 0) > 0 and sibling.professionName then
                        return sibling
                    end
                end
            end
        end
    end
    return found
end

--- A profession at its cap for now: Butler names the trainer's next rank.
--- `english` is the profession's English name, whatever the client's.
local function Capped(name, skill, max, skillLineID)
    local recipes = ns.Recipes
    local english = recipes and recipes.SKILL_LINE_PROFESSIONS and recipes.SKILL_LINE_PROFESSIONS[skillLineID]
    if not english and recipes and recipes.EnglishProfessionName then
        local ok, word = pcall(recipes.EnglishProfessionName, name)
        english = ok and word or nil
    end
    return { profession = name, english = english, skill = skill, max = max, capped = true }
end

local function NextSkillUp()
    local levelUp = ns.LevelUp
    if not (levelUp and levelUp.GetRanked) then return nil end
    local key = table.concat({ SelfKey() or "?", RecipesStamp(),
        tostring(ns.Queue and ns.Queue.version), tostring(ns.Inventory and ns.Inventory.changes),
        tostring(ns.Prices and ns.Prices.scanCount),
        -- "Can afford" on the Level Up tab, and the gold it is held to.
        tostring(ns.Config and ns.Config:Get("levelUpCanAfford") == true),
        tostring(levelUp.Purse and levelUp.Purse()) }, ":")
    if skillUp and skillUpKey == key and Now() - (skillUpAt or 0) < SKILL_UP_SECONDS then
        return skillUp
    end

    -- GetRanked's order is the Level Up tab's: the first row of each
    -- profession that fits is its top pick.
    local answer, seen, lookup = {}, {}, {}
    local canAfford = ns.Config and ns.Config:Get("levelUpCanAfford") == true
    for _, row in ipairs(levelUp:GetRanked({ canAfford = canAfford }) or {}) do
        local info = ProfessionOf(row.skillLineID, lookup)
        local name = info and info.professionName
        local cost = row.realCost or row.cost
        if name and not seen[name] then
            local skill, max = tonumber(info.skillLevel) or 0, tonumber(info.maxSkillLevel) or 0
            if skill >= max then
                seen[name] = true
                answer[#answer + 1] = Capped(name, skill, max, row.skillLineID)
            elseif SKILL_UP_TIERS[row.tier] and type(cost) == "number" then
                seen[name] = true
                answer[#answer + 1] = {
                    profession = name, skill = skill, max = max,
                    recipeID = row.recipeID, itemID = row.outputItemID, name = row.name,
                    tier = row.tier, cost = math.floor(cost + 0.5),
                    toBuy = row.toBuy,
                }
            end
        end
    end
    -- A profession at its cap with nothing on the Level Up tab (gathering
    -- ones have no crafts) still says it is capped, from the saved read.
    local recipes = ns.Recipes
    if recipes and recipes.GetLearnedProfessions then
        local ok, list = pcall(recipes.GetLearnedProfessions, recipes)
        for _, entry in ipairs(ok and type(list) == "table" and list or {}) do
            local skill, max = type(entry) == "table" and tonumber(entry.skillLevel), type(entry) == "table" and tonumber(entry.maxSkillLevel)
            if skill and max and max > 0 and skill >= max and entry.name and not seen[entry.name] then
                seen[entry.name] = true
                answer[#answer + 1] = Capped(entry.name, skill, max, entry.skillLineID)
            end
        end
    end
    table.sort(answer, function(a, b) return a.profession < b.profession end)

    skillUp, skillUpKey, skillUpAt = answer, key, Now()
    return answer
end

--- The cheapest craft for the next skill point in each profession the
--- character playing is still levelling. Never raises, writes nothing; nil
--- on any error. A fresh table each time.
function Butler:NextSkillUp()
    local ok, answer = pcall(NextSkillUp)
    if not (ok and type(answer) == "table") then return nil end
    local queue = ns.Queue
    local copy = {}
    for _, entry in ipairs(answer) do
        local queued = false
        if entry.recipeID and queue and queue.Find then
            local found, index = pcall(queue.Find, queue, entry.recipeID)
            queued = found and index ~= nil
        end
        copy[#copy + 1] = {
            profession = entry.profession, skill = entry.skill, max = entry.max,
            recipeID = entry.recipeID, itemID = entry.itemID, name = entry.name,
            tier = entry.tier, cost = entry.cost, queued = queued,
            capped = entry.capped, english = entry.english,
            toBuy = entry.toBuy,
        }
    end
    return copy
end

--- Butler's Queue button on that line: one of the craft in the queue.
-- @return true, or false and why. Never raises.
function Butler:QueueSkillUp(recipeID)
    recipeID = tonumber(recipeID)
    if not recipeID then return false, L["no recipe"] end
    local queue = ns.Queue
    if not (queue and queue.Ensure) then return false, L["the queue would not take it"] end
    local ok, done, why = pcall(queue.Ensure, queue, recipeID, 1)
    if ok and done then return true end
    return false, ok and why or L["the queue would not take it"]
end

--------------------------------------------------------------------------------
-- The queue's materials at the open vendor, for Butler's Buy from a vendor row
--------------------------------------------------------------------------------

--- What the Buy materials button over the vendor window would buy. nil
--- while no vendor is open or its list is not read yet. Never raises,
--- writes nothing; a fresh table each time.
function Butler:VendorOffer()
    local ok, offer = pcall(function()
        local vendor = ns.Vendor
        if not (vendor and vendor.isMerchantOpen and vendor.merchantItems) then return nil end
        if vendor:IsBuying() then
            return { count = 0, cost = 0, items = {}, cheaperElsewhere = 0, buying = true }
        end
        local lines, total, cheaper = vendor:GetNeeded()
        local items = {}
        for _, line in ipairs(lines) do
            items[#items + 1] = { itemID = line.itemID, amount = line.amount, cost = line.cost,
                short = line.short and true or nil }
        end
        return { count = #items, cost = tonumber(total) or 0, items = items,
            cheaperElsewhere = tonumber(cheaper) or 0, buying = false }
    end)
    if ok and type(offer) == "table" then return offer end
    return nil
end

--- Buy what the queue needs from the open vendor, from Butler's click: the
--- Buy materials button's own click, so the same checks and the same run.
--- Chat says why when nothing is bought. Never raises.
-- @return true when a run started, or false and why
function Butler:BuyFromVendor()
    local ok, started, why = pcall(function()
        local vendor = ns.Vendor
        if not vendor then return false, L["no vendor is open"] end
        local allowed, reason = vendor:CanBuy()
        if not allowed then return false, reason end
        local began = vendor:BuyNeeded()
        if ns.UI and ns.UI.UpdateMerchantButton then pcall(ns.UI.UpdateMerchantButton, ns.UI) end
        return began == true
    end)
    if not ok then return false, L["Tradeskills could not buy from this vendor"] end
    return started == true, why
end

--- What a vendor charges for one, for Butler's tooltip line. Copper, or
--- nil when no vendor is known to sell it. Never raises, writes nothing.
function Butler:VendorPrice(itemID)
    itemID = tonumber(itemID)
    if not itemID then return nil end
    return VendorPrice(itemID)
end

--- Look up items on the auction house, from Butler's Search click. Every
--- item at once where the game allows it, else the first with its count.
-- @return true and "all" or "one", or false and why
function Butler:SearchAuctions(items)
    local ok, done, how = pcall(function()
        local ids, counts = {}, {}
        for _, item in ipairs(type(items) == "table" and items or {}) do
            local itemID = type(item) == "table" and tonumber(item.itemID)
            if itemID and itemID > 0 and not counts[itemID] then
                ids[#ids + 1] = math.floor(itemID)
                counts[math.floor(itemID)] = math.max(1, math.floor(tonumber(item.count) or 1))
            end
        end
        if #ids == 0 then return false, L["Nothing on this list to look for on the auction house."] end
        local scanner = ns.Scanner
        if not (scanner and scanner.isAuctionHouseOpen) then return false, L["open the auction house first"] end
        if scanner.isScanning then return false, L["a scan is running; search again once it finishes"] end
        local lists = ns.ShoppingLists
        if #ids > 1 and lists and lists.SearchMany then
            local sent, why = lists:SearchMany(ids, counts)
            if sent then return true, "all" end
            if why ~= "single" then return false, why end
        end
        -- UI:SearchAuctionHouse says in chat why when it can't.
        if ns.UI and ns.UI.SearchAuctionHouse and ns.UI:SearchAuctionHouse(ids[1], counts[ids[1]]) then
            return true, #ids > 1 and "one" or "all"
        end
        return false, nil
    end)
    if not ok then return false, L["Tradeskills could not search the auction house"] end
    return done == true, how
end

--------------------------------------------------------------------------------
-- The player's shopping lists, for Butler's bank alt
--------------------------------------------------------------------------------

--- The lists the player made on the auction house drawer's Lists view
--- (ShoppingLists), so Butler can mail everything on one to a bank alt (a
--- player asked, the owner said build it, 2026-10-14). The craft queue's
--- list is not one of them. Never raises, writes nothing; nil on any error.
-- @return { { name, id, items = { [itemID] = want } } ... } in the player's
--   order, fresh tables each time, and ShoppingLists.version
function Butler:Lists()
    local ok, lists, version = pcall(function()
        local shopping = ns.ShoppingLists
        if not (shopping and shopping.Readable) then return nil end
        local out = {}
        for _, readable in ipairs(shopping:Readable()) do
            local list = readable.list
            local items = {}
            for _, item in ipairs(type(list.items) == "table" and list.items or {}) do
                local itemID = type(item) == "table" and tonumber(item.id)
                if itemID and itemID > 0 then
                    items[math.floor(itemID)] = math.max(0, math.floor(tonumber(item.want) or 0))
                end
            end
            out[#out + 1] = { name = list.name, id = tonumber(list.id), items = items }
        end
        return out, tonumber(shopping.version) or 0
    end)
    if ok and type(lists) == "table" then return lists, version end
    return nil
end
