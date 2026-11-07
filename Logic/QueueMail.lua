-- Blackthornes Tradeskills -- Logic/QueueMail.lua
-- What to mail to your other characters for the shared craft queue.
--
-- The queue gives each craft to a character (Logic/Queue.lua, "Who makes
-- what"). The tailor makes the bolts for Ana's bag, so the tailor needs
-- the wool, and Ana needs the bolts once they are made. At a mailbox this
-- works out what the character logged in holds that another one needs, and
-- UI/QueueMailPanel.lua offers to fill a mail with it.
--
-- Nothing is ever sent from here. The panel fills in the name and the
-- attachments, and the player presses Send: postage costs money, and a mail
-- cannot be taken back once sent.
--
-- What has been mailed is written down (`BlackthornesTSDB.queueMail.sent`),
-- because the other character's bags are only known as they were when it
-- last logged out. Without it, every visit to the mailbox would offer the
-- same wool again until the tailor logged in.
--
-- Crafts made for someone else are written down too (`queueMail.owed`): a
-- craft you queued that only an alt can make is taken off the queue as the
-- alt makes it, and the record is what says the result still has to go back.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

--- One key for a realm name, the same on every account of one player.
--- Forever's GetRealmName names the server behind the realm, and each of a
--- player's accounts can sit on a different one ("CAMWOW US2 Realm 7 PvE"
--- on one, "CAMWOW US2 Realm 3 PvE" on the other), so the key drops spaces,
--- case and the "Realm N" part. The same few lines are in Tab_Characters,
--- Queue, QueueMail, Butler, GoldGoal and GoldLog.
local function RealmKey(name)
    if type(name) ~= "string" or name == "" or name == "?" then return nil end
    local key = name:lower():gsub("%s", ""):gsub("realm%d+", "")
    if key == "" then return nil end
    return key
end

local function SameRealm(a, b)
    local ka, kb = RealmKey(a), RealmKey(b)
    return ka ~= nil and ka == kb
end

local QueueMail = ns.NewModule("QueueMail")

-- How many items one mail carries. The client's own number where it has one.
local function MaxAttachments()
    local max = tonumber(_G.ATTACHMENTS_MAX_SEND)
    if max and max > 0 then return max end
    return 12
end
QueueMail.MaxAttachments = MaxAttachments

-- A mail between characters can take an hour to arrive. Until the one it
-- went to has looked in its mailbox after that, what was sent counts as
-- theirs, on its way.
local DELIVERY_WAIT = 3600

-- Records of what was sent are let go after this, whatever happened.
local KEEP_SENT = 3 * 24 * 3600

--------------------------------------------------------------------------------
-- Storage
--------------------------------------------------------------------------------

local function Store()
    if not ns.db then return nil end
    local store = ns.db.queueMail
    if type(store) ~= "table" then
        store = {}
        ns.db.queueMail = store
    end
    if type(store.sent) ~= "table" then store.sent = {} end
    if type(store.owed) ~= "table" then store.owed = {} end
    return store
end

local function SelfKey()
    return ns.Config:GetCharacterKey()
end

local function CharacterRecord(characterKey)
    local record = ns.db and ns.db.characters and ns.db.characters[characterKey]
    if type(record) == "table" then return record end
end

local function Now()
    return (type(time) == "function" and time()) or 0
end

--- Is a record of something sent to this character still on its way?
local function StillComing(sent, record)
    if Now() - (sent.at or 0) > KEEP_SENT then return false end
    local mailAt = record and record.mailAt
    -- Mail to your own characters lands at once; only another account's
    -- (a linked one's) takes the hour. Waiting the hour for an alt counted
    -- the wool twice, in its mailbox and still on its way.
    local wait = (record and record.linkedFrom) and DELIVERY_WAIT or 0
    if mailAt and mailAt > (sent.at or 0) + wait then return false end
    return true
end

--- How many of an item have been mailed to a character and not yet seen
--- arrive. Logic/Queue.lua counts these as the character's own.
function QueueMail:InFlight(characterKey, itemID)
    local store = Store()
    local list = store and store.sent[characterKey]
    if type(list) ~= "table" then return 0 end

    local record = CharacterRecord(characterKey)
    local total = 0
    for _, sent in ipairs(list) do
        if sent.itemID == itemID and StillComing(sent, record) then
            total = total + (sent.count or 0)
        end
    end
    return total
end

--- Everything mailed to a character and not yet seen arrive, by item:
--- { [itemID] = count }. Read only (Butler's jobs: a mailbox to visit).
function QueueMail:InFlightItems(characterKey)
    local store = Store()
    local list = store and store.sent[characterKey]
    local items = {}
    if type(list) ~= "table" then return items end

    local record = CharacterRecord(characterKey)
    for _, sent in ipairs(list) do
        if type(sent) == "table" and sent.itemID and StillComing(sent, record) then
            items[sent.itemID] = (items[sent.itemID] or 0) + (sent.count or 0)
        end
    end
    return items
end

--- Forget what has arrived or is too old to matter.
function QueueMail:Prune()
    local store = Store()
    if not store then return end

    for characterKey, list in pairs(store.sent) do
        if type(list) == "table" then
            local record = CharacterRecord(characterKey)
            local kept = {}
            for _, sent in ipairs(list) do
                if type(sent) == "table" and StillComing(sent, record) then
                    kept[#kept + 1] = sent
                end
            end
            store.sent[characterKey] = #kept > 0 and kept or nil
        end
    end
end

--- A craft was made for another character. Logic/Crafting.lua calls this.
function QueueMail:NoteMadeFor(toKey, itemID, count)
    local store = Store()
    if not (store and toKey and itemID and count and count > 0) then return end

    local fromKey = SelfKey()
    if toKey == fromKey then return end

    local mine = store.owed[fromKey] or {}
    store.owed[fromKey] = mine
    local theirs = mine[toKey] or {}
    mine[toKey] = theirs
    theirs[itemID] = (theirs[itemID] or 0) + count
end

--- What this character still owes another: { [itemID] = count }.
function QueueMail:GetOwed(toKey)
    local store = Store()
    local mine = store and store.owed[SelfKey()]
    return (mine and mine[toKey]) or {}
end

--- What any character still owes the others, as made for them and not yet
--- mailed: { [toKey] = { [itemID] = count } }. Read only (Butler's jobs).
function QueueMail:GetOwedBy(fromKey)
    local store = Store()
    local owed = store and fromKey and store.owed[fromKey]
    return type(owed) == "table" and owed or {}
end

--- Mail went out. Writes down what it carried, and takes it off what was owed.
-- @param items list of { itemID, count }
function QueueMail:NoteSent(toKey, items)
    local store = Store()
    if not (store and toKey) then return end

    local list = store.sent[toKey] or {}
    store.sent[toKey] = list

    local owed = self:GetOwed(toKey)
    local at = Now()

    for _, item in ipairs(items or {}) do
        if item.itemID and (item.count or 0) > 0 then
            list[#list + 1] = { itemID = item.itemID, count = item.count, at = at, from = SelfKey() }

            if owed[item.itemID] then
                local left = owed[item.itemID] - item.count
                owed[item.itemID] = left > 0 and left or nil
            end
        end
    end
end

--------------------------------------------------------------------------------
-- What to send
--------------------------------------------------------------------------------

--- The materials each character's queued crafts use, and what each makes.
-- @return uses { [key] = { [itemID] = units } }, makes { [key] = { [itemID] = units } }
function QueueMail:GetPlan()
    local uses, makes = {}, {}
    local Queue = ns.Queue

    for _, entry in ipairs(Queue:GetAll()) do
        local recipe = ns.Recipes:GetAny(entry.recipeID)
        if recipe then
            local crafter = Queue:GetCrafter(entry)

            local used = uses[crafter] or {}
            uses[crafter] = used
            for _, reagent in ipairs(recipe.reagents or {}) do
                used[reagent.itemID] = (used[reagent.itemID] or 0) + reagent.quantity * entry.quantity
            end

            if entry.isDependency and recipe.outputItemID then
                local made = makes[crafter] or {}
                makes[crafter] = made
                made[recipe.outputItemID] = (made[recipe.outputItemID] or 0)
                    + entry.quantity * math.max(1, recipe.quantityMin or 1)
            end
        end
    end

    return uses, makes
end

local function Bound(itemID)
    return ns.Util and ns.Util.IsBoundOnPickup and ns.Util.IsBoundOnPickup(itemID) == true
end

--- The items this character can make: the outputs of its own recipes.
local function OwnOutputs()
    local outputs = {}
    local ok, recipes = pcall(ns.Recipes.GetAll, ns.Recipes)
    for _, recipe in pairs((ok and type(recipes) == "table" and recipes) or {}) do
        if type(recipe) == "table" and recipe.outputItemID then
            outputs[recipe.outputItemID] = true
        end
    end
    return outputs
end

--- The linked characters this one can mail whose queues need something,
--- by key. Empty unless Share Craft Queue is ticked here.
function QueueMail:LinkedNeeders(selfKey)
    local list = {}
    if not (ns.Config and ns.Config:Get("linkShareQueue") == true) then return list end
    selfKey = selfKey or SelfKey()
    for key, record in pairs((ns.db and ns.db.characters) or {}) do
        if type(record) == "table" and record.linkedFrom ~= nil
            and type(record.queueNeeds) == "table" and next(record.queueNeeds)
            and key ~= selfKey and not self:IsPlaying(key)
            and ns.Queue:CanMail(selfKey, key) then
            list[#list + 1] = key
        end
    end
    table.sort(list)
    return list
end

--- What the character logged in can send to whom, right now.
--
-- For each other character the queue gives crafts to: what those crafts
-- use, less what that character makes itself, holds, or has on its way.
-- Then the crafts made here for them that are still owed. Each is limited
-- to what is in these bags (only the bags can go in a mail) beyond what
-- this character's own crafts use.
--
-- Finished crafts go in a delivery of their own (`crafts = true`), ahead of
-- the materials for the same character. Asked 2026-10-06: "if your alt is
-- doing a craft and completes it, when they go back to the mail there
-- should be a button to send their alt craft to the character that needs
-- it". A craft is what this character can make and the other one's queued
-- crafts use (bolts for Ana's bag), or what it made from a craft another
-- character queued (`owed`).
--
-- All of it is offered whether or not alts are given sub-crafts (asked the
-- same day: "also if they hold a material that other character needs to
-- complete something in the queue"). The queue is shared either way, so a
-- craft only an alt knows is the alt's to make with the setting off too,
-- and the materials for it can be in another character's bags. The setting
-- only decides whether sub-crafts are handed to alts.
--
-- @return list of { to = key, name, crafts, subject, items = { { itemID, count, made } } },
--   by name, a character's crafts before its materials, items by item
function QueueMail:GetDeliveries()
    local deliveries = {}
    local Queue = ns.Queue
    if not (ns.db and Queue and Queue.CanMail) then return deliveries end

    local selfKey = SelfKey()
    if not CharacterRecord(selfKey) then return deliveries end
    local uses, makes = self:GetPlan()
    local myUse, myMake = uses[selfKey] or {}, makes[selfKey] or {}
    local canMake = OwnOutputs()

    -- What these bags can spare, item by item, worked out as it is asked for.
    local spare = {}
    local function Spare(itemID)
        if spare[itemID] == nil then
            local bags = ns.Inventory:GetBagCount(itemID)
            -- Your own crafts come first, and use the bank before the bags.
            local own = math.max(0, (myUse[itemID] or 0) - (myMake[itemID] or 0)
                - ns.Inventory:GetBankCount(itemID))
            spare[itemID] = math.max(0, bags - own)
        end
        return spare[itemID]
    end

    local byKey = {}
    local function Give(toKey, itemID, count, made)
        if count <= 0 or Bound(itemID) then return end
        local give = math.min(count, Spare(itemID))
        if give <= 0 then return end
        spare[itemID] = spare[itemID] - give

        local key = made and (toKey .. "#crafts") or toKey
        local delivery = byKey[key]
        if not delivery then
            delivery = { to = toKey, name = ns.Recipes:GetCharacterName(toKey), items = {} }
            if made then
                delivery.crafts = true
                delivery.subject = "Crafts for your queue"
            end
            byKey[key] = delivery
            deliveries[#deliveries + 1] = delivery
        end

        for _, item in ipairs(delivery.items) do
            if item.itemID == itemID then
                item.count = item.count + give
                return
            end
        end
        delivery.items[#delivery.items + 1] = { itemID = itemID, count = give, made = made }
    end

    local others = {}
    for characterKey in pairs(uses) do
        if characterKey ~= selfKey and not self:IsPlaying(characterKey)
            and Queue:CanMail(selfKey, characterKey) then
            others[#others + 1] = characterKey
        end
    end
    table.sort(others)

    for _, toKey in ipairs(others) do
        local theirMake = makes[toKey] or {}
        local items = {}
        for itemID in pairs(uses[toKey]) do items[#items + 1] = itemID end
        table.sort(items)

        for _, itemID in ipairs(items) do
            local left = uses[toKey][itemID] - (theirMake[itemID] or 0)
                - Queue:HeldBy(toKey, itemID)
            Give(toKey, itemID, left, (myMake[itemID] or 0) > 0 or canMake[itemID] == true)
        end
    end

    -- A linked account's characters, for what their own queues still need
    -- (Account Link's Share Craft Queue, both sides ticked; 2026-11-07). The
    -- other account worked out the need against its own bags and mail, so
    -- only what this account mailed since and has not seen arrive comes off.
    for _, toKey in ipairs(self:LinkedNeeders(selfKey)) do
        local needs = CharacterRecord(toKey).queueNeeds
        local items = {}
        for itemID in pairs(needs) do items[#items + 1] = itemID end
        table.sort(items)
        for _, itemID in ipairs(items) do
            Give(toKey, itemID, needs[itemID] - self:InFlight(toKey, itemID), canMake[itemID] == true)
        end
    end

    -- Finished crafts for whoever queued them.
    local store = Store()
    local owedByMe = store and store.owed[selfKey] or {}
    local owedTo = {}
    for toKey in pairs(owedByMe) do
        if toKey ~= selfKey and not self:IsPlaying(toKey) and Queue:CanMail(selfKey, toKey) then
            owedTo[#owedTo + 1] = toKey
        end
    end
    table.sort(owedTo)

    for _, toKey in ipairs(owedTo) do
        local items = {}
        for itemID in pairs(owedByMe[toKey]) do items[#items + 1] = itemID end
        table.sort(items)
        for _, itemID in ipairs(items) do
            Give(toKey, itemID, owedByMe[toKey][itemID], true)
        end
    end

    table.sort(deliveries, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        if a.to ~= b.to then return a.to < b.to end
        return a.crafts == true and b.crafts ~= true
    end)

    return deliveries
end

--------------------------------------------------------------------------------
-- Gear for the disenchanter
--------------------------------------------------------------------------------

-- Asked 2026-10-04: "Setting a disenchant character to mail all BoEs to
-- (with threshold option, like only greens, or maybe only green and blues)".
-- The name is typed in Settings, so it can be any character, one on another
-- account included. What goes: green and better armour and weapons that can
-- be disenchanted, up to the quality picked, never a soulbound copy, never
-- crafted gear (asked 2026-10-11), never gear that binds when picked up, and never an upgrade for the character
-- carrying it (when Equipment is loaded to say so). Like the queue's mail,
-- nothing is sent from here: the panel fills the mail and the player
-- presses Send.

local GREEN, PURPLE = 2, 4

--- A name for comparing: lower case, spaces between words kept single.
local function Fold(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if text == "" then return nil end
    return text:lower()
end

--- A plain string from the client, or nil: read in a pcall and copied, since
--- the client can hand out values that raise when touched.
local function ClientString(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if not ok or type(value) ~= "string" then return nil end
    local copied, text = pcall(function() return value .. "" end)
    return copied and text or nil
end

--- Is the typed name the character playing? Asked for 2026-10-04: the
--- disenchanter is never offered gear to mail to itself. Matched without
--- regard to case, by first name or by first and last name (Forever's
--- characters have both), with or without the realm. The name is read from
--- the game, falling back to the saved record, so a record not yet stamped
--- this session still counts.
local function IsCharacterPlaying(typed)
    local name, realm = typed:match("^(.-)%-([^%-]+)$")
    name = Fold(name or typed)
    if not name then return false end

    local record = CharacterRecord(SelfKey()) or {}
    local first = Fold(ClientString(UnitName, "player")) or Fold(record.name)
    if not first then return false end

    local surname = Fold(record.surname)
    if not surname and ns.Config.ReadSurname then
        local ok, found = pcall(ns.Config.ReadSurname, ns.Config)
        surname = ok and Fold(found) or nil
    end

    if name ~= first and not (surname and name == first .. " " .. surname) then
        return false
    end

    -- A realm that is not this one is somebody else of the same name.
    local here = ClientString(GetRealmName) or record.realm
    if realm and type(here) == "string" then
        return realm:gsub("%s", ""):lower() == here:gsub("%s", ""):lower()
    end
    return true
end

--- Is this name, as a player would type it, the character playing?
function QueueMail:IsPlayingName(typed)
    if type(typed) ~= "string" or typed == "" then return false end
    return IsCharacterPlaying(typed) == true
end

--- Is this record the character playing? Its own key, or another record of
--- it (an old name-realm one: Characters:Same). Mail to it lands in the
--- bags it came from, so it is never offered a delivery (a player found
--- Butler filling a mail to the character they were on, 2026-10-11).
function QueueMail:IsPlaying(characterKey)
    if characterKey == nil then return false end
    if characterKey == SelfKey() then return true end
    return ns.Characters ~= nil and ns.Characters:IsPlaying(characterKey) == true
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

--- The disenchanter picked for the player while the box is empty (the
--- owner, 2026-10-11: the addons should do the work): the alt on this
--- account, on this realm and side, with the most Enchanting, when it has
--- more than the character playing. Its whole name, or nil. "Pick one for
--- me" (`disenchanterGuess`, on unless unticked) turns it off.
function QueueMail:GuessDisenchanter()
    if ns.Config:Get("disenchanterGuess") == false then return nil end
    local characters = ns.db and ns.db.characters
    if type(characters) ~= "table" then return nil end
    local selfKey = SelfKey()
    local queue = ns.Queue

    local own = EnchantingSkill(characters[selfKey]) or -1
    local bestKey, bestSkill
    for characterKey, record in pairs(characters) do
        local skill = EnchantingSkill(record)
        -- The same skill: the lower key, so the pick never flickers.
        local better = skill and skill > own and (not bestKey or skill > bestSkill
            or (skill == bestSkill and tostring(characterKey) < tostring(bestKey)))
        if better and characterKey ~= selfKey and record.linkedFrom == nil
            and not self:IsPlaying(characterKey)
            and (not (queue and queue.CanMail) or queue:CanMail(selfKey, characterKey)) then
            bestKey, bestSkill = characterKey, skill
        end
    end
    return bestKey and QueueMail.MailName(characters[bestKey]) or nil
end

--- The disenchanter's name as typed, trimmed, else the one picked for the
--- player (`GuessDisenchanter`), or nil when there is none (or it is the
--- character playing). The second return is true for a picked one.
function QueueMail:GetDisenchanter()
    local typed = ns.Config:Get("disenchanterName")
    if type(typed) == "string" then
        typed = typed:gsub("^%s+", ""):gsub("%s+$", "")
        if typed ~= "" then
            if IsCharacterPlaying(typed) then return nil end
            return typed, false
        end
    end

    local picked = self:GuessDisenchanter()
    if picked and not IsCharacterPlaying(picked) then return picked, true end
    return nil
end

--- Is the character playing the disenchanter? The name typed in Settings
--- when there is one; with the box empty and "Pick one for me" on, the
--- character with the most Enchanting, which is this one when it has some
--- and no other character it can mail has more. For Butler's "Disenchant
--- greens here" (the owner asked 2026-10-14). Never raises.
function QueueMail:IsDisenchanterPlaying()
    local typed = ns.Config:Get("disenchanterName")
    if type(typed) == "string" then
        typed = typed:gsub("^%s+", ""):gsub("%s+$", "")
        if typed ~= "" then return IsCharacterPlaying(typed) == true end
    end
    if ns.Config:Get("disenchanterGuess") == false then return false end
    local characters = ns.db and ns.db.characters
    if type(characters) ~= "table" then return false end
    local own = EnchantingSkill(characters[SelfKey()])
    if not own or own <= 0 then return false end
    return self:GuessDisenchanter() == nil
end

--- The best quality mailed to the disenchanter: 2 to 4.
function QueueMail:GetDisenchantQuality()
    local quality = tonumber(ns.Config:Get("disenchanterQuality")) or GREEN
    return math.max(GREEN, math.min(PURPLE, math.floor(quality)))
end

--- Is this copy an upgrade for the character carrying it? Asked of
--- Equipment directly, whether or not the arrows are switched on: the
--- answer here decides what leaves the bags.
local function UpgradeForMe(itemID, link)
    local compare = ns.Upgrades and ns.Upgrades.Equipment and ns.Upgrades:Equipment()
    if not compare then return false end
    local ok, result = pcall(compare.IsUpgrade, compare, link or itemID)
    return ok and result == true
end

--- Made by a profession (any recipe, learned or not)? Crafted gear stays
--- with the player (the owner, 2026-10-11: "disenchantable, non-crafted").
local function Crafted(itemID)
    local book = ns.RecipeBook
    if not (book and book.IsCrafted) then return false end
    local ok, made = pcall(book.IsCrafted, book, itemID)
    return ok and made == true
end

--- Does this item go to the disenchanter, by the rule above? Green up to the
--- quality picked, can be disenchanted, does not bind when picked up, is not
--- made by a profession, and is no upgrade for the character carrying it. A soulbound copy is the
--- caller's to leave out. Blackthornes Butler asks it too (Butler:Advise's
--- `disenchanter`), so both offer the same gear (the owner, 2026-10-11).
-- @param quality the item's quality, read when nil
-- @param link the carried copy's link, when known
function QueueMail:GoesToDisenchanter(itemID, quality, link)
    itemID = tonumber(itemID)
    if not itemID then return false end
    local Disenchant = ns.Disenchant
    if not (Disenchant and Disenchant.IsDisenchantable) then return false end
    if quality == nil and type(C_Item) == "table" and type(C_Item.GetItemQualityByID) == "function" then
        local ok, read = pcall(C_Item.GetItemQualityByID, itemID)
        quality = ok and tonumber(read) or nil
    end
    quality = tonumber(quality)
    if not quality or quality < GREEN or quality > self:GetDisenchantQuality() then return false end
    if Disenchant:IsDisenchantable(itemID) ~= true or Bound(itemID) then return false end
    if Crafted(itemID) then return false end
    return not UpgradeForMe(itemID, link)
end

--- What the bags hold for the disenchanter, as a delivery the panel can
--- draw and Fill can attach, or nil when there is nobody or nothing.
-- @return { to, name, recipient, subject, disenchant = true,
--   items = { { itemID, count, quality } } }
function QueueMail:GetDisenchantDelivery()
    local recipient = self:GetDisenchanter()
    if not recipient then return nil end

    local Disenchant = ns.Disenchant
    if not (Disenchant and Disenchant.IsDisenchantable) then return nil end
    if not (C_Container and ns.Inventory and ns.Inventory.GetCarriedBags) then return nil end

    local best = self:GetDisenchantQuality()
    local counts, order, qualities, refused = {}, {}, {}, {}

    -- Read and copied inside a pcall: the client can hand out values that
    -- raise when compared.
    local function Read(bag, slot)
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if type(info) ~= "table" or info.isBound then return nil end
        local itemID, quality = tonumber(info.itemID), tonumber(info.quality)
        local link = type(info.hyperlink) == "string" and (info.hyperlink .. "") or nil
        return itemID, quality, tonumber(info.stackCount) or 1, link
    end

    for _, bag in ipairs(ns.Inventory:GetCarriedBags()) do
        local okSlots, slots = pcall(C_Container.GetContainerNumSlots, bag)
        for slot = 1, (okSlots and tonumber(slots)) or 0 do
            local ok, itemID, quality, stack, link = pcall(Read, bag, slot)

            if ok and itemID and quality and quality >= GREEN and quality <= best
                and not refused[itemID] then
                -- One copy an upgrade keeps them all: the mail is filled by
                -- item, and could take that copy rather than another.
                if not self:GoesToDisenchanter(itemID, quality, link) then
                    refused[itemID] = true
                else
                    if not counts[itemID] then
                        order[#order + 1] = itemID
                        qualities[itemID] = quality
                    end
                    counts[itemID] = (counts[itemID] or 0) + stack
                end
            end
        end
    end

    local kept = {}
    for _, itemID in ipairs(order) do
        if not refused[itemID] then kept[#kept + 1] = itemID end
    end
    order = kept
    if #order == 0 then return nil end

    -- Best quality first.
    table.sort(order, function(a, b)
        if qualities[a] ~= qualities[b] then return qualities[a] > qualities[b] end
        return a < b
    end)

    local items = {}
    for _, itemID in ipairs(order) do
        items[#items + 1] = { itemID = itemID, count = counts[itemID], quality = qualities[itemID] }
    end

    return {
        to = self:FindCharacter(recipient),
        name = recipient,
        recipient = recipient,
        subject = "Gear to disenchant",
        disenchant = true,
        items = items,
    }
end

--------------------------------------------------------------------------------
-- Filling a mail
--------------------------------------------------------------------------------

-- Seconds between one attachment and the next. A split stack is locked until
-- the game has moved it, and the next pick-up from the bags waits for that.
local ATTACH_STEP = 0.2

-- A split is looked for in its new bag slot this often, this many times,
-- before it is given up on and left in the bags.
local SPLIT_STEP = 0.1
local SPLIT_TRIES = 20

local function Call(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

--- Which mail slots already hold something.
local function UsedSlots()
    local used, count = {}, 0
    for slot = 1, MaxAttachments() do
        local ok, name = Call(_G.GetSendMailItem, slot)
        if ok and name ~= nil then
            used[slot] = true
            count = count + 1
        end
    end
    return used, count
end

local function FreeSlot()
    local used = UsedSlots()
    for slot = 1, MaxAttachments() do
        if not used[slot] then return slot end
    end
end

--- What a bag slot holds: itemID, count, locked. nil when it is empty.
-- Copied inside the pcall: the client can hand out values that raise.
local function SlotHolds(bag, slot)
    local ok, itemID, count, locked = Call(function()
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if type(info) ~= "table" then return nil end
        return tonumber(info.itemID), tonumber(info.stackCount) or 1, info.isLocked == true
    end)
    if ok then return itemID, count, locked end
end

--- An empty slot in an ordinary bag (not a herb or mining bag, which would
--- refuse most things), skipping those in `reserved`.
--- Do two bag family masks share a bit? (A herb bag is 32, a herb's own
--- family 32 too.) Written out, since the tests' Lua has no bit library.
local function SharesFamily(a, b)
    a, b = tonumber(a) or 0, tonumber(b) or 0
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then return true end
        a, b = math.floor(a / 2), math.floor(b / 2)
    end
    return false
end

--- An item's bag family (herbs, ore, leather...), 0 when it has none or
--- the client will not say.
local function ItemFamily(itemID)
    local get = (C_Item and C_Item.GetItemFamily) or _G.GetItemFamily
    if not (itemID and get) then return 0 end
    local ok, family = pcall(get, itemID)
    return ok and tonumber(family) or 0
end

--- An empty bag slot to split part of a stack into, kept in `reserved`.
--- The stack's own bag first, since it already holds the item (herbs in a
--- herb bag, reagents in the reagent bag), then any ordinary bag, then a
--- profession bag made for the item. A herbalist's herbs were left out of
--- Butler's mail with the ordinary bags full and room in the herb bag
--- (2026-10-13).
local function EmptyBagSlot(reserved, from)
    local bags = ns.Inventory.GetCarriedBags and ns.Inventory:GetCarriedBags() or {}
    local itemFamily = from and ItemFamily(from.itemID) or 0
    local function FreeIn(bag)
        local okSlots, slots = Call(C_Container.GetContainerNumSlots, bag)
        for slot = 1, (okSlots and tonumber(slots)) or 0 do
            local key = bag .. ":" .. slot
            local okInfo, info = Call(C_Container.GetContainerItemInfo, bag, slot)
            if okInfo and info == nil and not reserved[key] then
                reserved[key] = true
                return bag, slot
            end
        end
    end
    local function Takes(bag, sameBag)
        local okFree, free, family = Call(C_Container.GetContainerNumFreeSlots, bag)
        if not (okFree and (tonumber(free) or 0) > 0) then return false end
        family = tonumber(family) or 0
        return sameBag or family == 0 or SharesFamily(family, itemFamily)
    end

    if from and from.bag ~= nil and Takes(from.bag, true) then
        local bag, slot = FreeIn(from.bag)
        if bag then return bag, slot end
    end
    for pass = 1, 2 do
        for _, bag in ipairs(bags) do
            local okFree, _, family = Call(C_Container.GetContainerNumFreeSlots, bag)
            local plain = okFree and (tonumber(family) or 0) == 0
            if bag ~= (from and from.bag) and (pass == 1) == plain and Takes(bag) then
                local found, slot = FreeIn(bag)
                if found then return found, slot end
            end
        end
    end
end

--- How many of what is in a Send Mail slot, or nil when it cannot be read.
local function AttachedCount(slot)
    local ok, name, _, _, count = Call(_G.GetSendMailItem, slot)
    if not ok or name == nil then return nil end
    local copied, n = pcall(function() return (count or 1) + 0 end)
    return copied and n or nil
end

--- The bag stacks to take for `count` of an item: whole stacks first, the
--- biggest first, and one split for the rest.
-- @return list of { bag, slot, count, split }
function QueueMail:PlanStacks(itemID, count, taken)
    local stacks = {}
    local bags = ns.Inventory.GetCarriedBags and ns.Inventory:GetCarriedBags() or {}

    for _, bag in ipairs(bags) do
        local okSlots, slots = Call(C_Container and C_Container.GetContainerNumSlots, bag)
        for slot = 1, (okSlots and tonumber(slots)) or 0 do
            local ok, info = Call(C_Container.GetContainerItemInfo, bag, slot)
            local key = bag .. ":" .. slot
            if ok and type(info) == "table" and info.itemID == itemID
                and not info.isBound and not info.isLocked and not taken[key] then
                stacks[#stacks + 1] = { bag = bag, slot = slot, size = info.stackCount or 1, key = key }
            end
        end
    end

    table.sort(stacks, function(a, b)
        if a.size ~= b.size then return a.size > b.size end
        if a.bag ~= b.bag then return a.bag < b.bag end
        return a.slot < b.slot
    end)

    local steps, left = {}, count
    -- Whole stacks that fit, then one split from a stack bigger than what is left.
    for _, stack in ipairs(stacks) do
        if left <= 0 then break end
        if stack.size <= left then
            steps[#steps + 1] = { bag = stack.bag, slot = stack.slot, count = stack.size }
            taken[stack.key] = true
            left = left - stack.size
        end
    end
    if left > 0 then
        for index = #stacks, 1, -1 do
            local stack = stacks[index]
            if not taken[stack.key] and stack.size > left then
                steps[#steps + 1] = { bag = stack.bag, slot = stack.slot, count = left, split = true }
                taken[stack.key] = true
                left = 0
                break
            end
        end
    end

    return steps
end

-- What sending one mail costs.
QueueMail.POSTAGE = 30

--- Put `copper` in the Send Mail page's gold boxes, as a player types it
--- (Blackthornes Butler's gold top-ups, 2026-10-11). Never with COD ticked,
--- and never more than the purse holds less the postage.
-- @return true, or false and why
function QueueMail.PutMoney(copper)
    copper = math.floor(tonumber(copper) or 0)
    if copper <= 0 then return true end
    local cod = _G.SendMailCODButton
    if cod and cod.GetChecked then
        local ok, checked = pcall(cod.GetChecked, cod)
        if ok and checked then return false, L["the mail is set to COD"] end
    end
    local okMoney, purse = pcall(function() return tonumber(GetMoney()) end)
    if okMoney and purse and purse < copper + QueueMail.POSTAGE then
        return false, L["not enough gold on you"]
    end
    local frame = _G.SendMailMoney
    if not frame then return false, L["the mail has no gold box"] end
    if type(_G.MoneyInputFrame_SetCopper) == "function"
        and pcall(_G.MoneyInputFrame_SetCopper, frame, copper) then
        return true
    end
    local gold = _G.SendMailMoneyGold or frame.gold
    local silver = _G.SendMailMoneySilver or frame.silver
    local bronze = _G.SendMailMoneyCopper or frame.copper
    if not (gold and silver and bronze) then return false, L["the mail has no gold box"] end
    Call(gold.SetText, gold, tostring(math.floor(copper / 10000)))
    Call(silver.SetText, silver, tostring(math.floor(copper / 100) % 100))
    Call(bronze.SetText, bronze, tostring(copper % 100))
    return true
end

--- Open the Send Mail page and fill it in for one delivery.
--
-- `delivery.money`, copper, goes in the gold boxes first (Butler's gold
-- top-ups); a delivery can be gold alone.
--
-- The name and subject go in at once, the items one at a time after. As many
-- stacks as one mail holds; what is left stays on the list for the next mail.
--
-- Part of a stack (a player's report, 2026-10-11: mailing sub-crafts to an
-- alt sent the whole stack, not what its queue needed) is first split into
-- an empty bag slot, and only once the game shows it there as its own stack
-- is it put in the mail. Dropped straight from the cursor, the mail took the
-- stack it was split from. Each attachment is then counted, and one that
-- came out bigger than asked for is taken back out of the mail. With no
-- empty bag slot to split into, that item is left for the player.
-- @param onDone function(attached, leftOver) when the last item is in
-- @return true when it started, or false and why
function QueueMail:Fill(delivery, onDone)
    if self.filling or self.taking then return false, L["still filling the last mail"] end
    if InCombatLockdown and InCombatLockdown() then return false, L["not in combat"] end

    local nameBox = _G.SendMailNameEditBox
    if not nameBox then return false, L["the mailbox is not open"] end

    -- The Send Mail tab. Its own click handler where the client has it.
    if _G.MailFrameTab2 and _G.MailFrameTab_OnClick then
        Call(_G.MailFrameTab_OnClick, _G.MailFrameTab2, 2)
    elseif _G.MailFrameTab2 and _G.MailFrameTab2.Click then
        Call(_G.MailFrameTab2.Click, _G.MailFrameTab2)
    end

    local name = delivery.recipient
        or (delivery.to and QueueMail.MailName(CharacterRecord(delivery.to)))
        or delivery.name
    Call(nameBox.SetText, nameBox, name)
    local subject = _G.SendMailSubjectEditBox
    if subject then Call(subject.SetText, subject, delivery.subject or "Materials for the craft queue") end

    -- Cleared before anything can return, so a fill with nothing to attach
    -- never repeats the last fill's "free a bag slot".
    self.splitBlocked = nil

    if delivery.money then
        local put, why = QueueMail.PutMoney(delivery.money)
        if not put then return false, why end
    end

    local _, alreadyIn = UsedSlots()
    local room = MaxAttachments() - alreadyIn

    local steps, taken = {}, {}
    for _, item in ipairs(delivery.items or {}) do
        for _, step in ipairs(self:PlanStacks(item.itemID, item.count, taken)) do
            step.itemID = item.itemID
            steps[#steps + 1] = step
        end
    end

    local leftOver = math.max(0, #steps - room)
    while #steps > room do steps[#steps] = nil end

    if #steps == 0 then
        if onDone then onDone(0, leftOver) end
        return true
    end

    self.filling = true
    local attached = 0
    local reserved = {}

    local function Finish()
        QueueMail.filling = false
        if CursorHasItem and CursorHasItem() then Call(ClearCursor) end
        if onDone then onDone(attached, leftOver) end
    end

    local function HasCursor()
        return CursorHasItem and CursorHasItem() and true or false
    end

    local function MailOpen()
        return _G.SendMailFrame and _G.SendMailFrame:IsShown()
    end

    local index = 0
    local Next

    --- Put a whole bag stack in the mail, then check what went in.
    local function Attach(step)
        local slot = FreeSlot()
        if not slot then return Finish() end

        if HasCursor() then Call(ClearCursor) end
        local picked = Call(C_Container.PickupContainerItem, step.bag, step.slot)

        if picked and HasCursor() then
            Call(_G.ClickSendMailItemButton, slot)
            if HasCursor() then
                -- The mail would not take it: put it back and stop.
                Call(ClearCursor)
                leftOver = leftOver + (#steps - index + 1)
                return Finish()
            end
            attached = attached + 1
        end

        C_Timer.After(ATTACH_STEP, function()
            -- More in the mail than asked for: never send it. The game puts
            -- it back in the bags, and it counts as not attached.
            local count = AttachedCount(slot)
            if count and count > step.count then
                Call(_G.ClickSendMailItemButton, slot, true)
                attached = attached - 1
                leftOver = leftOver + 1
            end
            Next()
        end)
    end

    --- Split part of a stack into an empty bag slot, wait for the game to
    --- show it there, then attach it as a stack of its own.
    local function SplitThenAttach(step)
        local toBag, toSlot = EmptyBagSlot(reserved, step)
        if not toBag then
            QueueMail.splitBlocked = true
            leftOver = leftOver + 1
            return Next()
        end

        if HasCursor() then Call(ClearCursor) end
        Call(C_Container.SplitContainerItem, step.bag, step.slot, step.count)
        if not HasCursor() then
            leftOver = leftOver + 1
            return Next()
        end
        Call(C_Container.PickupContainerItem, toBag, toSlot)
        if HasCursor() then
            Call(ClearCursor)
            leftOver = leftOver + 1
            return Next()
        end

        local tries = 0
        local function Settled()
            tries = tries + 1
            local itemID, count, locked = SlotHolds(toBag, toSlot)
            if itemID == step.itemID and count == step.count and not locked then
                if not MailOpen() then return Finish() end
                return Attach({ bag = toBag, slot = toSlot, count = step.count, itemID = step.itemID })
            end
            if tries >= SPLIT_TRIES or not MailOpen() then
                -- The split never showed up as asked: leave it in the bags.
                leftOver = leftOver + 1
                return Next()
            end
            C_Timer.After(SPLIT_STEP, Settled)
        end
        C_Timer.After(SPLIT_STEP, Settled)
    end

    Next = function()
        index = index + 1
        local step = steps[index]
        if not step or not MailOpen() then return Finish() end
        if step.split then return SplitThenAttach(step) end
        return Attach(step)
    end

    Next()
    return true
end

--------------------------------------------------------------------------------
-- Taking the next batch out of the mailbox
--------------------------------------------------------------------------------
--
-- Asked 2026-10-05: a thousand essence waiting in the mail is a hundred
-- slots, and the bags hold thirty. With the setting on (mailBatchTake, off by
-- default) the panel offers Take next batch: the queue's materials from the
-- mail, as much as fits with the spare slots kept (Logic/BagsFull.lua), in the
-- same share as the vendor's Buy what fits, so the two make whole crafts.
-- Mail hands out whole stacks, so a batch can run over by part of one stack.
-- Mail asking for payment on delivery (COD) is never touched.

-- The client takes one attachment at a time and needs a moment between.
local TAKE_STEP = 0.6

-- A hard ceiling on take calls, so a miscount can never loop for ever.
local MAX_TAKE_STEPS = 150

local function MaxReceive()
    local max = tonumber(_G.ATTACHMENTS_MAX_RECEIVE)
    if max and max > 0 then return max end
    return 16
end

--- Every attachment of the queue's materials in the mailbox, with where it is.
-- @return list of { index, slot, itemID, count }
local function MailAttachments(wanted)
    local found = {}
    local okCount, count = Call(_G.GetInboxNumItems)
    if not okCount then return found end

    for index = 1, tonumber(count) or 0 do
        local okHeader, _, _, _, _, _, cod, _, itemCount = Call(_G.GetInboxHeaderInfo, index)
        if okHeader and (tonumber(cod) or 0) == 0 and (tonumber(itemCount) or 0) > 0 then
            for slot = 1, MaxReceive() do
                local itemID, units = ns.Mail:ReadAttachment(index, slot)
                if itemID and wanted[itemID] then
                    found[#found + 1] = { index = index, slot = slot, itemID = itemID, count = units or 1 }
                end
            end
        end
    end
    return found
end

--- What Take next batch would take, or nil when the setting is off or the
--- mail holds nothing the queue still needs.
-- @return { items = { {itemID, count}, ... }, units, batches, spare, room,
--           noRoom (true when it would take something but the bags are full) }
function QueueMail:GetMailBatch()
    if ns.Config:Get("mailBatchTake") ~= true then return nil end
    if not (ns.Mail and ns.Mail.ReadAttachment and ns.BagsFull and ns.BagsFull.PlanBatch) then return nil end

    local shopping = ns.Queue:GetShoppingList()
    local stillNeeded = {}
    for _, line in ipairs(shopping) do
        if (line.needed or 0) > (line.inBags or 0) then stillNeeded[line.itemID] = true end
    end

    local inMail = {}
    for _, attachment in ipairs(MailAttachments(stillNeeded)) do
        inMail[attachment.itemID] = (inMail[attachment.itemID] or 0) + attachment.count
    end
    if next(inMail) == nil then return nil end

    local room = ns.BagsFull:Room()
    if not room then return nil end
    local plan = ns.BagsFull:PlanBatch(shopping, room)

    local batch = { items = {}, units = 0, batches = plan.batches, spare = ns.BagsFull:GetSpare(), room = room }
    for _, line in ipairs(shopping) do
        local count = math.min(inMail[line.itemID] or 0, plan.bring[line.itemID] or 0)
        if count > 0 then
            batch.items[#batch.items + 1] = { itemID = line.itemID, count = count }
            batch.units = batch.units + count
        end
    end

    if #batch.items == 0 then batch.noRoom = true end
    return batch
end

--- Take the next batch out of the mailbox, one attachment at a time.
-- @param onDone function(units taken, stacks taken) when it stops
-- @return true when it started, or false and why
function QueueMail:TakeBatch(onDone)
    if self.taking or self.filling then return false, L["still busy with the last one"] end
    if not ns.Mail or not ns.Mail.isOpen then return false, L["the mailbox is not open"] end
    if type(_G.TakeInboxItem) ~= "function" then
        return false, L["this version of the game does not let addons take mail"]
    end

    local batch = self:GetMailBatch()
    if not batch or #batch.items == 0 then return false, L["nothing to take that fits"] end

    local left, wanted = {}, {}
    for _, item in ipairs(batch.items) do
        left[item.itemID] = item.count
        wanted[item.itemID] = true
    end

    self.taking = true
    local units, stacks, steps, slotsLeft = 0, 0, 0, batch.room

    local function Finish()
        QueueMail.taking = false
        if onDone then onDone(units, stacks) end
    end

    local function Next()
        steps = steps + 1
        if steps > MAX_TAKE_STEPS or slotsLeft <= 0 or not ns.Mail.isOpen then return Finish() end

        -- Bags read again each time: the last stack may have filled a slot
        -- this did not count on.
        local free = ns.BagsFull:CountFree()
        if free and free <= ns.BagsFull:GetSpare() then return Finish() end

        -- The inbox read afresh too: taking an attachment can move the mail
        -- it came from, or empty it and close the gap.
        local pick
        for _, attachment in ipairs(MailAttachments(wanted)) do
            if (left[attachment.itemID] or 0) > 0 then
                pick = attachment
                break
            end
        end
        if not pick then return Finish() end

        if not Call(_G.TakeInboxItem, pick.index, pick.slot) then return Finish() end

        left[pick.itemID] = left[pick.itemID] - pick.count
        units = units + pick.count
        stacks = stacks + 1
        slotsLeft = slotsLeft - 1

        C_Timer.After(TAKE_STEP, Next)
    end

    Next()
    return true
end

--------------------------------------------------------------------------------
-- Writing down what was sent
--------------------------------------------------------------------------------

--- The name to mail a character by: first and last name when the last one is
--- known. Forever lets any number of characters share a first name, so the
--- first name alone (all the To box got, 2026-10-06) can reach a stranger or
--- nobody.
function QueueMail.MailName(record)
    if type(record) ~= "table" or type(record.name) ~= "string" then return nil end
    if type(record.surname) == "string" and record.surname ~= "" then
        return record.name .. " " .. record.surname
    end
    return record.name
end

--- Which of your characters a typed name means: one on this realm with that
--- first and last name, or with that first name when only one has it.
function QueueMail:FindCharacter(typed)
    if type(typed) ~= "string" or typed == "" then return nil end

    local selfRecord = CharacterRecord(SelfKey())
    local realm = selfRecord and selfRecord.realm
    local wanted, wantedRealm = typed:match("^([^-]+)-?(.*)$")
    wanted = Fold(wanted or typed)
    if not wanted then return nil end
    if wantedRealm ~= nil and wantedRealm ~= "" then realm = wantedRealm end
    local first, last = wanted:match("^(%S+) (.+)$")

    local function Named(record)
        if first then
            return record.name:lower() == first
                and type(record.surname) == "string" and Fold(record.surname) == last
        end
        return record.name:lower() == wanted
    end

    local found
    for characterKey, record in pairs((ns.db and ns.db.characters) or {}) do
        if type(record) == "table" and type(record.name) == "string"
            and Named(record)
            and (not realm or not record.realm or SameRealm(record.realm, realm)) then
            if found then return nil end
            found = characterKey
        end
    end

    if found and self:IsPlaying(found) then return nil end
    return found
end

--- What is attached to the mail being written: list of { itemID, count }.
local function ReadAttachments()
    local items = {}
    for slot = 1, MaxAttachments() do
        local ok, name, itemID, _, count = Call(_G.GetSendMailItem, slot)
        if ok and name ~= nil then
            local okCopy, id, n = pcall(function() return itemID + 0, (count or 1) + 0 end)
            if okCopy and id then items[#items + 1] = { itemID = id, count = n } end
        end
    end
    return items
end

--- SendMail was called. What it carries is written down once the game says
--- it went (MAIL_SEND_SUCCESS); a failed send is forgotten.
function QueueMail:OnSendMail(recipient)
    local ok, copied = pcall(function() return recipient .. "" end)
    local toKey = ok and self:FindCharacter(copied) or nil
    if not toKey then
        self.pending = nil
        return
    end
    -- Read as the mail goes. Should the game have emptied the page first,
    -- the last reading taken while it was being filled stands in.
    local items = ReadAttachments()
    if #items == 0 and self.lastAttachments then items = self.lastAttachments end
    self.pending = { to = toKey, items = items }
end

function QueueMail:OnSendSuccess()
    local pending = self.pending
    self.pending = nil
    if not pending or #pending.items == 0 then return end

    self:NoteSent(pending.to, pending.items)
    self.lastAttachments = nil
    if ns.QueueMailPanel and ns.QueueMailPanel.OnSent then ns.QueueMailPanel:OnSent(pending.to) end
    if ns.Queue then
        ns.Queue:RebuildDependencies()
        ns.Queue:Notify()
    end
end

function QueueMail:OnEnable()
    self:Prune()

    if type(hooksecurefunc) == "function" and type(_G.SendMail) == "function" then
        pcall(hooksecurefunc, "SendMail", function(recipient)
            QueueMail:OnSendMail(recipient)
        end)
    end

    ns.RegisterEvent(self, "MAIL_SEND_SUCCESS", function() QueueMail:OnSendSuccess() end)
    ns.RegisterEvent(self, "MAIL_FAILED", function() QueueMail.pending = nil end)

    -- What is attached, each time it changes, for OnSendMail.
    ns.RegisterEvent(self, "MAIL_SEND_INFO_UPDATE", function()
        QueueMail.lastAttachments = ReadAttachments()
    end)
    ns.RegisterEvent(self, "MAIL_CLOSED", function() QueueMail.lastAttachments = nil end)
end
