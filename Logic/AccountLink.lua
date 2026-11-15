-- Blackthornes Tradeskills -- Logic/AccountLink.lua
-- Your characters on another account of yours, shared in game.
--
-- Asked 2026-10-07 (on Discord, the owner agreeing): recipes, bags,
-- gold and auctions from a second account, without a desktop app. Each side
-- names a character on the other account in Settings (Sharing), and while
-- both are logged in each sends the other its characters. They then show up
-- wherever this account's own alts do: the Characters tab, alt counts,
-- "Bob can make this", Keep in stock.
--
-- What keeps it safe:
--   * Only whispers, only from a name this side added, and only when that
--     side added this one too (a hello from anyone else gets no answer).
--   * A received character is a copy, marked `linkedFrom`. It never
--     replaces, merges into or deletes one of this account's own
--     characters, and is never passed on to anyone else.
--   * Only known fields are taken, each checked for its type; strings lose
--     their "|" (no colour, link or texture codes from someone else).
--   * Each side chooses what it sends (recipes, bags, gold, auctions).
--
-- Saved as ordinary character records in `characters[guid]`, with
-- `linkedFrom`, `linkedAt` and `linkHash`. Never rename those: a record
-- without `linkedFrom` would read as one of this account's own.
--
-- A name also typed under Friends (`friendNames`, the owner 2026-10-25) is
-- a friend, not your account: it is never a partner here, and copies it
-- sent before are set aside in `friendCopies[guid]` (never rename it), out
-- of the Characters list and every count, but not deleted.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local AccountLink = ns.NewModule("AccountLink")

local Comm = ns.Comm

-- What a character always carries, and what each Share setting adds.
-- The Characters tab's notes (Logic/CharacterNotes.lua) go with the
-- identity, so the other account's characters show their XP, rest, zone
-- and played time too.
local IDENTITY = { "name", "realm", "faction", "class", "level", "surname",
                   "race", "classFile", "xp", "xpMax", "restXP", "resting", "zone", "played", "seenAt" }
AccountLink.SECTIONS = {
    { setting = "linkShareRecipes", fields = { "professions", "professionLines", "recipes", "recipesCachedAt" } },
    { setting = "linkShareBags", fields = { "inventory", "inventoryAt", "bank", "bankAt", "mail", "mailAt" } },
    { setting = "linkShareGold", fields = { "gold" } },
}

-- Share Craft Queue (the owner, 2026-11-07, a player with three accounts):
-- each own character's queued crafts' materials it still needs, item IDs
-- and counts only, so the other account's mail suggestions can send them.
-- Off unless ticked on both sides (`linkShareQueue`); never relayed, since
-- only this account's own characters go out. `mailAt` rides along so a
-- mail sent to one clears once it reads its mailbox, bags shared or not.
AccountLink.QUEUE_SETTING = "linkShareQueue"
AccountLink.MAX_NEEDS = 200

-- Share Sales (the owner, 2026-11-07): each own character's own auction
-- sales, expiries and cancellations from this account's mail ledger, so the
-- other account's Sales and Stats tabs show both. Off unless ticked on both
-- sides (`linkShareSales`, never rename it). Only entries this account wrote
-- itself go out, never one taken from a partner (`linked`), and never who
-- bought it. The receiver keeps them apart in `linkedSales[realm][guid]`
-- (never rename it), replaced whole each time, so a sale sent again is
-- never counted twice. Data/Mail.lua's `Entries` reads them in.
AccountLink.SALES_SETTING = "linkShareSales"
AccountLink.MAX_SALES = 200
AccountLink.SALE_KINDS = { sold = true, expired = true, removed = true }
AccountLink.salesVersion = 0

-- Share Shopping Lists (the owner, 2026-11-07): this account's shopping
-- lists and its craft queue's list, item IDs and counts only (how many are
-- wanted and how many this account has), so the other account can buy for
-- it at the auction house. Off unless ticked on both sides
-- (`linkShareLists`, never rename it). Only this account's own lists go
-- out, never one taken from a partner, so nothing is passed on. The
-- receiver keeps them apart in `linkedShoppingLists[partner key]` (never
-- rename it), replaced whole each time, and shows them read only.
-- The manifest carries `lists`: the hash of what would be sent, or "off".
-- U (table) is the lists themselves, V asks for them.
AccountLink.LISTS_SETTING = "linkShareLists"
AccountLink.LISTS_KEY = "lists"
AccountLink.MAX_LIST_ITEMS = 1000

-- Share Prices (the owner, 2026-11-07): this account's own auction scan
-- prices (market value, cheapest listing and when each was seen) for its
-- realm and side, so the other account's prices stay as fresh as the
-- newest scan on either. No tick box of its own (the owner, 2026-11-07:
-- "If they are sharing accounts thats enough already"): it runs whenever
-- the two accounts name each other. Only prices this account scanned
-- itself go out, never ones taken from a partner, the guild or the realm,
-- so nothing is passed on. The receiver keeps them apart in
-- `linkedPrices[realm key][partner key] = { at, count, items = { [itemID]
-- = { market, lowest, seen } } }` (never rename it), and Prices:GetValue
-- uses one where it was seen after this account's own (PriceFor).
-- The manifest carries `prices`: "<last scan, base 36>@<realm key>", or
-- "off". E asks for what was seen after a time; O is one batch of prices,
-- "<scan time>:id,market,lowest,age;..." in base 36, each batch complete
-- in itself, so a lost one only loses its own prices.
AccountLink.PRICES_KEY = "prices"
AccountLink.PRICES_USE_FOR = 3 * 24 * 3600   -- a price older than this is not sent or used
AccountLink.PRICES_KEEP = 7 * 24 * 3600      -- and is let go after this
AccountLink.PRICES_MAX_ITEMS = 5000          -- the most sent at a time
AccountLink.PRICES_MAX_STORED = 20000        -- the most kept from one partner
AccountLink.PRICES_ASK_WAIT = 10 * 60        -- an ask unanswered this long may go again
AccountLink.PRICES_TAKE_FOR = 30 * 60        -- batches are taken this long after an ask
AccountLink.PRICES_ANSWER_GAP = 60           -- at most one answer a partner a minute
AccountLink.PRICES_MAX_ITEM_ID = 10000000

-- How often partners are said hello to, or told what changed.
AccountLink.CHECK_SECONDS = 600
-- A change that should not wait for the next check (a new sale) goes to
-- online partners this many seconds later (SendSoon), at most this late.
AccountLink.SOON_DELAY = 5
AccountLink.SOON_MOST_WAIT = 30
local MAX_CHARACTERS = 60
local MAX_STRING = 120

--------------------------------------------------------------------------------
-- Partners
--------------------------------------------------------------------------------

AccountLink.partners = {}   -- name key -> { name, online, heardAt }

local function Setting(key)
    return ns.Config and ns.Config:Get(key)
end

--- The names typed in Settings, as { key = "ana", name = "Ana" }.
function AccountLink:GetPartners()
    local list, seen = {}, {}
    local text = Setting("linkNames")
    if type(text) ~= "string" then return list end

    for part in text:gmatch("[^,;]+") do
        local name = part:gsub("^%s+", ""):gsub("%s+$", "")
        local key = Comm.NameKey(name)
        local friend = ns.GuildCrafters and ns.GuildCrafters.IsFriend
            and ns.GuildCrafters:IsFriend(name)
        if key and not seen[key] and #name <= 48 and not friend then
            seen[key] = true
            list[#list + 1] = { key = key, name = name }
        end
    end
    return list
end

--- The partner a sender is, or nil for anyone else.
function AccountLink:PartnerFor(sender)
    local key = Comm.NameKey(sender)
    if not key or Comm.IsMe(sender) then return nil end
    for _, partner in ipairs(self:GetPartners()) do
        if partner.key == key then
            local state = self.partners[key]
            if not state then
                state = { name = partner.name }
                self.partners[key] = state
            end
            return state, partner
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- What is sent
--------------------------------------------------------------------------------

local function IsGUID(key)
    return type(key) == "string" and #key <= 40 and key:match("^Player%-[%w%-]+$") ~= nil
end
AccountLink.IsGUID = IsGUID

--- This account's own characters: filed by GUID, and not a copy from
--- someone else. A linked copy is never sent on.
function AccountLink:OwnCharacters()
    local own = {}
    for key, record in pairs((ns.db and ns.db.characters) or {}) do
        if IsGUID(key) and type(record) == "table" and record.linkedFrom == nil then
            own[key] = record
        end
    end
    return own
end

local function CopyRecipes(recipes)
    local out = {}
    for recipeID, recipe in pairs(recipes) do
        if type(recipeID) == "number" and type(recipe) == "table" then
            -- When it was read and whether it still skills up only matter
            -- on the character's own account.
            out[recipeID] = {
                name = recipe.name,
                outputItemID = recipe.outputItemID,
                quantityMin = recipe.quantityMin,
                quantityMax = recipe.quantityMax,
                skillLineID = recipe.skillLineID,
                reagents = recipe.reagents,
            }
        end
    end
    return out
end

--- What one of this account's characters still needs for its queued crafts:
--- what they use, less what it makes itself and what it holds or has on its
--- way. { [itemID] = count }, never empty; nil when it needs nothing.
function AccountLink:QueueNeeds(guid)
    local QueueMail, Queue = ns.QueueMail, ns.Queue
    if not (QueueMail and QueueMail.GetPlan and Queue and Queue.HeldBy) then return nil end

    -- The plan is the same for every character in one manifest.
    local now = (type(GetTime) == "function" and GetTime()) or 0
    if not self.plan or self.plan.at ~= now then
        local ok, uses, makes = pcall(QueueMail.GetPlan, QueueMail)
        self.plan = { at = now, uses = ok and uses or {}, makes = ok and makes or {} }
    end

    local uses = self.plan.uses[guid]
    if type(uses) ~= "table" then return nil end
    local makes = self.plan.makes[guid] or {}
    local needs, count = {}, 0
    for itemID, used in pairs(uses) do
        local ok, held = pcall(Queue.HeldBy, Queue, guid, itemID)
        local left = used - (makes[itemID] or 0) - ((ok and tonumber(held)) or 0)
        if left > 0 and count < self.MAX_NEEDS then
            needs[itemID] = left
            count = count + 1
        end
    end
    return next(needs) and needs or nil
end

--- One of this account's characters' own ledger entries, by realm key:
--- { [realmKey] = { entry, ... } }, oldest first, at most MAX_SALES all
--- told (the newest kept). nil when there are none. Only the fields the
--- Sales and Stats tabs read; never the buyer.
local SALE_FIELDS = { "t", "kind", "itemID", "name", "quantity", "net", "gross",
    "cut", "deposit", "estimated", "cost", "bought" }

function AccountLink:OwnSales(guid)
    local found = {}
    for realmKey, ledger in pairs((ns.db and ns.db.mailLedger) or {}) do
        local entries = type(realmKey) == "string" and type(ledger) == "table"
            and type(ledger.entries) == "table" and ledger.entries
        for _, entry in ipairs(entries or {}) do
            if type(entry) == "table" and entry.who == guid and not entry.linked
                and self.SALE_KINDS[entry.kind] and type(entry.t) == "number" then
                found[#found + 1] = { realm = realmKey, entry = entry }
            end
        end
    end
    if #found == 0 then return nil end
    table.sort(found, function(a, b) return a.entry.t > b.entry.t end)

    local sales = {}
    for index = math.min(#found, self.MAX_SALES), 1, -1 do
        local one = found[index]
        local copy = {}
        for _, field in ipairs(SALE_FIELDS) do copy[field] = one.entry[field] end
        sales[one.realm] = sales[one.realm] or {}
        table.insert(sales[one.realm], copy)
    end
    return sales
end

--- One character as it goes out, with only what the Share settings allow.
function AccountLink:Payload(guid, record)
    local payload = { guid = guid }
    for _, field in ipairs(IDENTITY) do payload[field] = record[field] end

    for _, section in ipairs(self.SECTIONS) do
        if Setting(section.setting) ~= false then
            for _, field in ipairs(section.fields) do
                local value = record[field]
                if field == "recipes" and type(value) == "table" then value = CopyRecipes(value) end
                payload[field] = value
            end
        end
    end

    if Setting(self.QUEUE_SETTING) == true then
        payload.queueNeeds = self:QueueNeeds(guid)
        payload.mailAt = record.mailAt
    end

    if Setting(self.SALES_SETTING) == true then
        payload.sales = self:OwnSales(guid)
    end

    if Setting("linkShareAuctions") ~= false then
        local auctions = {}
        for realmKey, realm in pairs((ns.db and ns.db.postedAuctions) or {}) do
            local reading = type(realm) == "table" and type(realm.byCharacter) == "table"
                and realm.byCharacter[guid]
            if type(reading) == "table" then auctions[realmKey] = reading end
        end
        if next(auctions) then payload.auctions = auctions end
    end

    return payload
end

--- guid -> hash of what would be sent, so the other side asks only for the
--- characters that changed.
--- With `only` (a set of guids), just those characters: the other side asks
--- only for what is listed, and leaves the rest as it holds them.
function AccountLink:Manifest(only)
    local manifest, count = {}, 0
    for guid, record in pairs(self:OwnCharacters()) do
        if not only or only[guid] then
            count = count + 1
            if count > MAX_CHARACTERS then break end
            local ok, text = pcall(ns.Serialize.EncodeCanonical, self:Payload(guid, record))
            if ok then manifest[guid] = Comm.Hash(text) end
        end
    end
    if not only or only[self.LISTS_KEY] then manifest[self.LISTS_KEY] = self:ListsHash() end
    if not only or only[self.PRICES_KEY] then manifest[self.PRICES_KEY] = self:PricesHash() end
    return manifest
end

--- This account's own shopping lists and its craft queue's list, as sent:
--- { lists = { { n = name, i = { { id, want, have }, ... } }, ... },
---   queue = { { id, want, have }, ... } }. Never a list from a partner.
function AccountLink:OwnLists()
    local out = { lists = {}, queue = {} }
    local lists = ns.ShoppingLists
    if not lists then return out end
    local total = 0
    local function Take(into, id, want, have)
        if total >= self.MAX_LIST_ITEMS then return end
        id, want, have = tonumber(id), tonumber(want), tonumber(have) or 0
        if not id or not want or want < 1 then return end
        total = total + 1
        into[#into + 1] = { math.floor(id), math.floor(want), math.max(0, math.floor(have)) }
    end
    local ok, queue = pcall(lists.QueueLines, lists)
    for _, line in ipairs(ok and type(queue) == "table" and queue or {}) do
        Take(out.queue, line.itemID, line.want, line.have)
    end
    for _, held in ipairs(lists:Readable()) do
        local list = { n = held.list.name, i = {} }
        local okLines, lines = pcall(lists.Lines, lists, held.index)
        for _, line in ipairs(okLines and type(lines) == "table" and lines or {}) do
            Take(list.i, line.itemID, line.want, line.have)
        end
        out.lists[#out.lists + 1] = list
    end
    return out
end

--- The hash of what OwnLists would send, or "off" while not sharing them.
function AccountLink:ListsHash()
    if Setting(self.LISTS_SETTING) ~= true then return "off" end
    local ok, text = pcall(ns.Serialize.EncodeCanonical, self:OwnLists())
    return ok and Comm.Hash(text) or "off"
end

--------------------------------------------------------------------------------
-- What is taken
--------------------------------------------------------------------------------

--- A string with every chat code taken out: colours, links, textures and
--- atlases, then any "|" left over.
local function CleanString(value)
    if type(value) ~= "string" then return nil end
    value = value:sub(1, MAX_STRING)
        :gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        :gsub("|T.-|t", ""):gsub("|A.-|a", "")
        :gsub("|H.-|h", ""):gsub("|h", "")
    return (value:gsub("|", ""))
end
AccountLink.CleanString = CleanString

local function CleanNumber(value)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        return nil
    end
    return value
end

--- itemID -> count, and nothing else.
local function CleanCounts(value)
    if type(value) ~= "table" then return nil end
    local out = {}
    for itemID, count in pairs(value) do
        itemID, count = CleanNumber(itemID), CleanNumber(count)
        if itemID and count and count > 0 and itemID > 0 then
            out[math.floor(itemID)] = math.floor(count)
        end
    end
    return out
end

local function CleanRecipes(value)
    if type(value) ~= "table" then return nil end
    local out = {}
    for recipeID, recipe in pairs(value) do
        recipeID = CleanNumber(recipeID)
        if recipeID and type(recipe) == "table" and CleanNumber(recipe.outputItemID)
            and type(recipe.reagents) == "table" then
            local reagents = {}
            for _, reagent in ipairs(recipe.reagents) do
                local itemID = type(reagent) == "table" and CleanNumber(reagent.itemID)
                local quantity = type(reagent) == "table" and CleanNumber(reagent.quantity)
                if itemID and quantity and quantity > 0 then
                    reagents[#reagents + 1] = { itemID = itemID, quantity = quantity }
                end
            end
            if #reagents > 0 then
                out[recipeID] = {
                    recipeID = recipeID,
                    name = CleanString(recipe.name) or "?",
                    outputItemID = recipe.outputItemID,
                    quantityMin = CleanNumber(recipe.quantityMin) or 1,
                    quantityMax = CleanNumber(recipe.quantityMax) or CleanNumber(recipe.quantityMin) or 1,
                    skillLineID = CleanNumber(recipe.skillLineID),
                    reagents = reagents,
                }
            end
        end
    end
    return out
end

local function CleanProfessions(value)
    if type(value) ~= "table" then return nil end
    local out = {}
    for _, profession in ipairs(value) do
        if type(profession) == "table" and type(profession.name) == "string" and #out < 12 then
            out[#out + 1] = {
                name = CleanString(profession.name),
                skillLevel = CleanNumber(profession.skillLevel) or 0,
                maxSkillLevel = CleanNumber(profession.maxSkillLevel) or 0,
                learned = profession.learned == true,
                skillLineID = CleanNumber(profession.skillLineID),
            }
        end
    end
    return out
end

local function CleanLines(value)
    if type(value) ~= "table" then return nil end
    local out = {}
    for skillLineID, learned in pairs(value) do
        if CleanNumber(skillLineID) and type(learned) == "boolean" then out[skillLineID] = learned end
    end
    return out
end

--- Queue needs: counts, at most MAX_NEEDS of them.
local function CleanNeeds(value)
    local out = CleanCounts(value)
    if not out then return nil end
    local kept, count = {}, 0
    for itemID, n in pairs(out) do
        count = count + 1
        if count > AccountLink.MAX_NEEDS then break end
        kept[itemID] = n
    end
    return next(kept) and kept or nil
end

local CLEANERS = {
    name = CleanString, realm = CleanString, faction = CleanString, class = CleanString,
    surname = CleanString, level = CleanNumber, gold = CleanNumber,
    recipes = CleanRecipes, professions = CleanProfessions, professionLines = CleanLines,
    inventory = CleanCounts, bank = CleanCounts, mail = CleanCounts,
    recipesCachedAt = CleanNumber, inventoryAt = CleanNumber, bankAt = CleanNumber, mailAt = CleanNumber,
    race = CleanString, classFile = CleanString, zone = CleanString,
    xp = CleanNumber, xpMax = CleanNumber, restXP = CleanNumber, played = CleanNumber, seenAt = CleanNumber,
    resting = function(value) if type(value) == "boolean" then return value end end,
    queueNeeds = CleanNeeds,
}

--- One auction reading: { items = counts, updatedAt, listings }.
local function CleanReading(reading)
    if type(reading) ~= "table" then return nil end
    local listings = {}
    for _, listing in ipairs(type(reading.listings) == "table" and reading.listings or {}) do
        local itemID = type(listing) == "table" and CleanNumber(listing.itemID)
        if itemID and #listings < 400 then
            listings[#listings + 1] = {
                itemID = itemID,
                quantity = CleanNumber(listing.quantity) or 1,
                unit = CleanNumber(listing.unit),
                ends = CleanNumber(listing.ends),
                band = CleanNumber(listing.band),
            }
        end
    end
    return {
        items = CleanCounts(reading.items) or {},
        updatedAt = CleanNumber(reading.updatedAt),
        listings = listings,
    }
end

--- One key for a realm, the same on every account of one player: case,
--- spaces and Forever's "Realm N" part dropped. The same few lines are in
--- Queue, QueueMail, GoldGoal and GoldLog.
local function RealmKey(name)
    if type(name) ~= "string" or name == "" or name == "?" then return nil end
    local key = name:lower():gsub("%s", ""):gsub("realm%d+", "")
    if key == "" then return nil end
    return key
end

--- A partner's realm key as this account files it: our own key when it is
--- the same realm and side, else as sent.
local function OurRealmKey(theirs)
    local ours = ns.Config and ns.Config.GetRealmKey and ns.Config:GetRealmKey()
    if type(ours) == "string" and theirs ~= ours and RealmKey(theirs) and RealmKey(theirs) == RealmKey(ours) then
        return ours
    end
    return theirs
end
AccountLink.OurRealmKey = OurRealmKey

--- One partner sale, or nil: a known kind, a time and an item.
local function CleanSale(value)
    if type(value) ~= "table" or not AccountLink.SALE_KINDS[value.kind] then return nil end
    local t = CleanNumber(value.t)
    local itemID = CleanNumber(value.itemID)
    if itemID and itemID <= 0 then itemID = nil end
    local name = CleanString(value.name)
    if not t or t <= 0 or not (itemID or (name and name ~= "")) then return nil end
    local function Money(field)
        local n = CleanNumber(value[field])
        return n and n >= 0 and math.floor(n) or nil
    end
    local quantity = CleanNumber(value.quantity)
    return {
        t = math.floor(t), kind = value.kind,
        itemID = itemID and math.floor(itemID) or nil,
        name = name ~= "" and name or nil,
        quantity = quantity and quantity >= 1 and math.floor(quantity) or nil,
        net = Money("net"), gross = Money("gross"), cut = Money("cut"),
        deposit = Money("deposit"), cost = Money("cost"),
        estimated = value.estimated == true or nil,
        bought = value.bought == true or nil,
        linked = true,
    }
end

--- A partner character's sales, cleaned: { [realmKey] = entries } filed
--- under our own realm key, each list oldest first, at most MAX_SALES all
--- told, the same sale only once.
local function CleanSales(value, guid)
    if type(value) ~= "table" then return {} end
    local out, count, seen = {}, 0, {}
    for realmKey, list in pairs(value) do
        if type(realmKey) == "string" and #realmKey <= 80 and type(list) == "table" then
            local ours = AccountLink.OurRealmKey(realmKey)
            for _, raw in ipairs(list) do
                local sale = count < AccountLink.MAX_SALES and CleanSale(raw)
                if sale then
                    sale.who = guid
                    local key = table.concat({ ours, sale.t, sale.kind, tostring(sale.itemID or sale.name),
                        tostring(sale.quantity), tostring(sale.net) }, "|")
                    if not seen[key] then
                        seen[key] = true
                        out[ours] = out[ours] or {}
                        table.insert(out[ours], sale)
                        count = count + 1
                    end
                end
            end
        end
    end
    for _, list in pairs(out) do
        table.sort(list, function(a, b) return a.t < b.t end)
    end
    return out
end

--- A partner's shopping lists, as OwnLists sends them, checked: numbers
--- in range and a name with no chat codes, nothing else.
local function CleanListItems(value, budget)
    local out = {}
    if type(value) ~= "table" then return out end
    local MAX = ns.ShoppingLists and ns.ShoppingLists.MAX_WANT or 99999
    for _, item in ipairs(value) do
        if budget.left <= 0 then break end
        if type(item) == "table" then
            local id, want, have = CleanNumber(item[1]), CleanNumber(item[2]), CleanNumber(item[3]) or 0
            if id and want and id >= 1 and id < 10000000 and want >= 1 then
                budget.left = budget.left - 1
                out[#out + 1] = { math.floor(id), math.min(MAX, math.floor(want)),
                                  math.max(0, math.min(MAX * 10, math.floor(have))) }
            end
        end
    end
    return out
end

local function CleanLists(value)
    if type(value) ~= "table" then return nil end
    local budget = { left = AccountLink.MAX_LIST_ITEMS }
    local out = { queue = CleanListItems(value.queue, budget), lists = {} }
    local maxLists = ns.ShoppingLists and ns.ShoppingLists.MAX_LISTS or 50
    local maxName = ns.ShoppingLists and ns.ShoppingLists.MAX_NAME or 40
    for _, list in ipairs(type(value.lists) == "table" and value.lists or {}) do
        if #out.lists >= maxLists then break end
        local name = type(list) == "table" and CleanString(list.n)
        name = name and name:gsub("^%s+", ""):gsub("%s+$", ""):sub(1, maxName)
        if name and name ~= "" then
            out.lists[#out.lists + 1] = { n = name, i = CleanListItems(list.i, budget) }
        end
    end
    return out
end
AccountLink.CleanLists = CleanLists

--- Keep a partner's shopping lists, replacing what it sent before. nil lets
--- them go. Only while this side shares lists too.
function AccountLink:KeepLists(state, lists, hash)
    local key = state and Comm.NameKey(state.name)
    if not key or not ns.db then return end
    local all = ns.db.linkedShoppingLists
    if lists == nil then
        if type(all) == "table" and all[key] ~= nil then
            all[key] = nil
            if next(all) == nil then ns.db.linkedShoppingLists = nil end
            if ns.ShoppingLists then ns.ShoppingLists:Touch() end
        end
        return
    end
    if type(all) ~= "table" then all = {}; ns.db.linkedShoppingLists = all end
    all[key] = { from = state.name, at = time(), hash = hash, lists = lists.lists, queue = lists.queue }
    if ns.ShoppingLists then ns.ShoppingLists:Touch() end
end

--- Let every partner's lists go (this side unticked Share Shopping Lists).
function AccountLink:DropLists()
    if ns.db and ns.db.linkedShoppingLists ~= nil then
        ns.db.linkedShoppingLists = nil
        if ns.ShoppingLists then ns.ShoppingLists:Touch() end
    end
end

--- Keep a partner character's sales apart, replacing what it sent before.
--- Empty (or this side unticked) drops it everywhere.
function AccountLink:KeepSales(guid, sales)
    if type(ns.db.linkedSales) ~= "table" and next(sales) == nil then return end
    ns.db.linkedSales = type(ns.db.linkedSales) == "table" and ns.db.linkedSales or {}
    local all = ns.db.linkedSales
    for realmKey, realm in pairs(all) do
        if type(realm) == "table" and realm[guid] ~= nil and not sales[realmKey] then
            realm[guid] = nil
            if next(realm) == nil then all[realmKey] = nil end
        end
    end
    for realmKey, list in pairs(sales) do
        if type(all[realmKey]) ~= "table" then all[realmKey] = {} end
        all[realmKey][guid] = { at = time(), entries = list }
    end
    self.salesVersion = (self.salesVersion or 0) + 1
end
AccountLink.CleanSales = CleanSales

--- Store a character a partner sent.
-- @return true, or nil and why it was refused
function AccountLink:Accept(sender, payload, hash)
    local state = self:PartnerFor(sender)
    if not state then return nil, "not a partner" end
    if type(payload) ~= "table" or not IsGUID(payload.guid) then return nil, "not a character" end

    local guid = payload.guid
    local characters = ns.db and ns.db.characters
    if type(characters) ~= "table" then return nil, "no saved data" end
    if guid == ns.Config:GetCharacterKey() then return nil, "this character" end

    local existing = characters[guid]
    if existing ~= nil and (type(existing) ~= "table" or existing.linkedFrom == nil) then
        return nil, "one of this account's own characters"
    end

    local record = { linkedFrom = state.name, linkedAt = time(), linkHash = hash }
    for field, clean in pairs(CLEANERS) do
        local value = clean(payload[field])
        if value ~= nil then record[field] = value end
    end
    -- Kept only while this side shares queues too.
    if Setting(self.QUEUE_SETTING) ~= true then record.queueNeeds = nil end
    record.name = record.name or "?"
    record.recipes = record.recipes or {}
    record.inventory = record.inventory or {}

    -- Its listings, under the realm they were read on. A linked character
    -- that no longer shares auctions stops counting toward Keep in stock.
    local auctions = type(payload.auctions) == "table" and payload.auctions or {}
    for realmKey, realm in pairs(ns.db.postedAuctions or {}) do
        if type(realm) == "table" and type(realm.byCharacter) == "table" and auctions[realmKey] == nil then
            realm.byCharacter[guid] = nil
        end
    end
    for realmKey, reading in pairs(auctions) do
        local clean = type(realmKey) == "string" and #realmKey <= 80 and CleanReading(reading)
        if clean then
            ns.db.postedAuctions = ns.db.postedAuctions or {}
            local realm = ns.db.postedAuctions[realmKey]
            if type(realm) ~= "table" then
                realm = { items = {} }
                ns.db.postedAuctions[realmKey] = realm
            end
            realm.byCharacter = realm.byCharacter or {}
            realm.byCharacter[guid] = clean
        end
    end

    -- Its sales, apart from this account's own ledger, only while this side
    -- shares sales too.
    local sales = Setting(self.SALES_SETTING) == true and CleanSales(payload.sales, guid) or {}
    self:KeepSales(guid, sales)

    characters[guid] = record
    self.changed = true
    return true
end

--- Forget every character a partner sent (all partners when name is nil).
-- Only copies: never one of this account's own characters.
-- @return how many were forgotten
function AccountLink:Forget(name)
    local key = name and Comm.NameKey(name)
    local gone = {}
    for guid, record in pairs((ns.db and ns.db.characters) or {}) do
        if type(record) == "table" and record.linkedFrom ~= nil
            and (not key or Comm.NameKey(record.linkedFrom) == key) then
            gone[#gone + 1] = guid
        end
    end
    for _, guid in ipairs(gone) do
        ns.Recipes:ForgetCharacter(guid)
        if ns.db then self:KeepSales(guid, {}) end
    end
    local lists = ns.db and ns.db.linkedShoppingLists
    if type(lists) == "table" then
        for partnerKey in pairs(lists) do
            if not key or partnerKey == key then self:KeepLists({ name = partnerKey }, nil) end
        end
    end
    if #gone > 0 then self:Changed() end
    return #gone
end

--- Move every copy a friend sent out of the character list, into
--- `friendCopies`. Nothing is deleted; it is only no longer read.
-- @return how many were set aside
function AccountLink:SetAsideFriends()
    local crafters = ns.GuildCrafters
    local characters = ns.db and ns.db.characters
    if not (crafters and crafters.IsFriend and type(characters) == "table") then return 0 end
    local moved = {}
    for guid, record in pairs(characters) do
        if type(record) == "table" and type(record.linkedFrom) == "string"
            and crafters:IsFriend(record.linkedFrom) then
            moved[#moved + 1] = guid
        end
    end
    if #moved == 0 then return 0 end
    ns.db.friendCopies = type(ns.db.friendCopies) == "table" and ns.db.friendCopies or {}
    for _, guid in ipairs(moved) do
        ns.db.friendCopies[guid] = characters[guid]
        ns.Recipes:ForgetCharacter(guid)
    end
    self:Changed()
    return #moved
end

--- Ask every partner for each of its characters again, the next time
--- they swap: the sales a partner sent while this side was unticked were
--- let go, and an unchanged character is never sent twice by itself.
function AccountLink:AskAgain()
    for _, record in pairs((ns.db and ns.db.characters) or {}) do
        if type(record) == "table" and record.linkedFrom ~= nil then record.linkHash = nil end
    end
    if self.Check then pcall(self.Check, self) end
end

--- How many characters each partner has sent: { [name] = count }.
function AccountLink:CountLinked()
    local counts, total = {}, 0
    for _, record in pairs((ns.db and ns.db.characters) or {}) do
        if type(record) == "table" and type(record.linkedFrom) == "string" then
            counts[record.linkedFrom] = (counts[record.linkedFrom] or 0) + 1
            total = total + 1
        end
    end
    return counts, total
end

function AccountLink:Changed()
    self.changed = nil
    if ns.Cost and ns.Cost.InvalidateIndex then pcall(ns.Cost.InvalidateIndex, ns.Cost) end
    if ns.PriceHistory and ns.PriceHistory.Retrack then ns.PriceHistory:Retrack() end
    if ns.UI and ns.UI.RefreshActiveTab then pcall(ns.UI.RefreshActiveTab, ns.UI) end
end

--------------------------------------------------------------------------------
-- The conversation
--------------------------------------------------------------------------------
-- H hello, A hello back: the other side is there and paired.
-- M (table) manifest: guid -> hash of each character it would send.
-- W (table) want: the guids whose hash differs from the copy held.
-- C (table) character: { hash = ..., data = payload }.
-- V ask for the shopping lists, U (table) the lists: { hash, data }.
-- E ask for prices seen after a time, O one batch of prices.

local function Whisper(kind, text, target)
    return Comm:Send(kind, text, "WHISPER", target)
end

function AccountLink:Hello(partnerName)
    Whisper("H", ns.VERSION or "", partnerName)
end

function AccountLink:SendManifest(state)
    state.manifestAt = time()
    Comm:SendTable("M", self:Manifest(), "WHISPER", state.name)
end

--- Something shared about one of this account's characters just changed.
--- Online partners hear about that character SOON_DELAY seconds later
--- rather than at the next check. More changes meanwhile wait with it, so a
--- burst goes as one, but never longer than SOON_MOST_WAIT. Any shared
--- feature can call it once it has checked its own setting.
function AccountLink:SendSoon(guid)
    if not (IsGUID(guid) or guid == self.LISTS_KEY or guid == self.PRICES_KEY) or not C_Timer or not C_Timer.After then return end
    local now = GetTime and GetTime() or time()
    self.soonDirty = self.soonDirty or {}
    self.soonDirty[guid] = true
    self.soonFirst = self.soonFirst or now
    if self.soonToken and now - self.soonFirst >= self.SOON_MOST_WAIT then return end
    local token = (self.soonToken or 0) + 1
    self.soonToken = token
    C_Timer.After(self.SOON_DELAY, function()
        if AccountLink.soonToken == token then AccountLink:SendChanged() end
    end)
end

--- Tell every online partner about the characters waiting in SendSoon.
--- Returns how many partners were told.
function AccountLink:SendChanged()
    local dirty = self.soonDirty
    self.soonDirty, self.soonFirst, self.soonToken = nil, nil, nil
    if not dirty then return 0 end
    local manifest = self:Manifest(dirty)
    if next(manifest) == nil then return 0 end
    local sent = 0
    for _, partner in ipairs(self:GetPartners()) do
        local state = self.partners[partner.key]
        if state and state.online then
            state.manifestAt = time()
            Comm:SendTable("M", manifest, "WHISPER", state.name)
            sent = sent + 1
        end
    end
    return sent
end

--- A character's ledger just changed (Data/Mail.lua: a sale written down or
--- its gold released). With Share Sales ticked, partners hear soon.
function AccountLink:SalesChanged(guid)
    if Setting(self.SALES_SETTING) == true then self:SendSoon(guid) end
end

--- A shopping list or the craft queue just changed. With Share Shopping
--- Lists ticked, partners hear soon.
function AccountLink:ListsChanged()
    if Setting(self.LISTS_SETTING) == true then self:SendSoon(self.LISTS_KEY) end
end

--- Share Shopping Lists was ticked or unticked here. Ticked, online
--- partners are asked for theirs; unticked, theirs go and they are told.
function AccountLink:ListsTicked(on)
    if on then
        for _, partner in ipairs(self:GetPartners()) do
            local state = self.partners[partner.key]
            if state and state.online then Whisper("V", "", state.name) end
        end
    else
        self:DropLists()
    end
    self:SendSoon(self.LISTS_KEY)
end

--- Say hello to every partner not yet heard from, and tell the ones who
--- are what changed. Called at login, every CHECK_SECONDS, and by Sync now.
function AccountLink:Check()
    for _, partner in ipairs(self:GetPartners()) do
        local state = self.partners[partner.key] or { name = partner.name }
        self.partners[partner.key] = state
        state.name = partner.name
        if state.online then
            self:SendManifest(state)
        else
            self:Hello(partner.name)
        end
    end
end

function AccountLink:OnHello(sender, _, channel, isReply)
    if channel ~= "WHISPER" then return end
    local state = self:PartnerFor(sender)
    if not state then return end

    state.online, state.heardAt = true, time()
    if not isReply then Whisper("A", ns.VERSION or "", state.name) end
    self:SendManifest(state)
end

function AccountLink:OnManifest(sender, manifest, channel)
    if channel ~= "WHISPER" then return end
    local state = self:PartnerFor(sender)
    if not state then return end
    state.online, state.heardAt = true, time()
    self:NoteSynced(sender)

    -- Either side's check syncs both ways: answered with this side's own,
    -- unless it went out a moment ago (which is what stops the two
    -- answering each other for ever).
    if not state.manifestAt or time() - state.manifestAt > 60 then self:SendManifest(state) end

    self:OnListsHash(state, manifest[self.LISTS_KEY])
    self:OnPricesHash(state, manifest[self.PRICES_KEY])

    local characters = (ns.db and ns.db.characters) or {}
    local want = {}
    for guid, hash in pairs(manifest) do
        if IsGUID(guid) and type(hash) == "string" and #want < MAX_CHARACTERS then
            local held = characters[guid]
            if held == nil or (type(held) == "table" and held.linkedFrom ~= nil and held.linkHash ~= hash) then
                want[#want + 1] = guid
            end
        end
    end
    if #want > 0 then Comm:SendTable("W", want, "WHISPER", state.name) end
end

function AccountLink:OnWant(sender, want, channel)
    if channel ~= "WHISPER" then return end
    local state = self:PartnerFor(sender)
    if not state then return end

    local own = self:OwnCharacters()
    local count = 0
    for _, guid in ipairs(want) do
        local record = own[guid]
        if record and count < MAX_CHARACTERS then
            count = count + 1
            local payload = self:Payload(guid, record)
            local ok, text = pcall(ns.Serialize.EncodeCanonical, payload)
            if ok then
                Comm:SendTable("C", { hash = Comm.Hash(text), data = payload }, "WHISPER", state.name)
            end
        end
    end
    if count > 0 then state.sentAt = time() end
end

function AccountLink:OnCharacter(sender, value, channel)
    if channel ~= "WHISPER" then return end
    local hash = type(value.hash) == "string" and value.hash:sub(1, 16) or nil
    local ok, why = self:Accept(sender, value.data, hash)
    if ok then
        local state = self:PartnerFor(sender)
        if state then state.receivedAt = time() end
        self:NoteSynced(sender)
        self:Changed()
    else
        ns.Debug("share: a character from", tostring(sender), "was not taken:", tostring(why))
    end
end

--- A partner's manifest said what its lists hash to ("off" when it does
--- not share them). Ask for them when they changed and this side shares.
function AccountLink:OnListsHash(state, hash)
    if type(hash) ~= "string" then return end
    if hash == "off" or Setting(self.LISTS_SETTING) ~= true then
        self:KeepLists(state, nil)
        return
    end
    local held = ns.db and type(ns.db.linkedShoppingLists) == "table"
        and ns.db.linkedShoppingLists[Comm.NameKey(state.name)]
    if type(held) ~= "table" or held.hash ~= hash:sub(1, 16) then Whisper("V", "", state.name) end
end

function AccountLink:OnListsWanted(sender, _, channel)
    if channel ~= "WHISPER" then return end
    local state = self:PartnerFor(sender)
    if not state or Setting(self.LISTS_SETTING) ~= true then return end
    local data = self:OwnLists()
    local ok, text = pcall(ns.Serialize.EncodeCanonical, data)
    if ok then Comm:SendTable("U", { hash = Comm.Hash(text), data = data }, "WHISPER", state.name) end
end

function AccountLink:OnLists(sender, value, channel)
    if channel ~= "WHISPER" then return end
    local state = self:PartnerFor(sender)
    if not state or Setting(self.LISTS_SETTING) ~= true or type(value) ~= "table" then return end
    local lists = CleanLists(value.data)
    if not lists then return end
    local hash = type(value.hash) == "string" and value.hash:sub(1, 16) or nil
    self:KeepLists(state, lists, hash)
end

function AccountLink:OnOffline(key)
    local state = self.partners[key]
    if state then state.online = false end
end

--------------------------------------------------------------------------------
-- Share Prices
--------------------------------------------------------------------------------

--- Prices go across whenever accounts are linked: no tick box of their own.
function AccountLink:PricesOn()
    return #self:GetPartners() > 0
end

local function OurRealm()
    local key = ns.Config and ns.Config.GetRealmKey and ns.Config:GetRealmKey()
    return type(key) == "string" and key or nil
end

--- When this account last scanned its realm, or nil.
local function LastScan()
    local prices = ns.Prices
    if not (prices and prices.GetLastScan) then return nil end
    local ok, at = pcall(prices.GetLastScan, prices)
    return ok and type(at) == "number" and at or nil
end

--- "<last scan>@<realm key>" for the manifest, or "off" while not sharing
--- prices or with no scan recent enough to share.
function AccountLink:PricesHash(now)
    if not self:PricesOn() then return "off" end
    local at, realm = LastScan(), RealmKey(OurRealm())
    now = now or time()
    if not at or not realm or now - at > self.PRICES_USE_FOR then return "off" end
    return Comm.ToBase36(math.floor(at)) .. "@" .. realm
end

--- This account's own prices seen after `since`, as O message bodies:
--- newest first, at most PRICES_MAX_ITEMS. Never a price taken from anyone.
function AccountLink:PriceBatches(since, now)
    local prices = ns.Prices
    if not (prices and prices.GetTable and prices.IsCredible) then return {} end
    local table_ = prices:GetTable()
    if type(table_) ~= "table" then return {} end
    now = now or time()
    local floor = math.max(tonumber(since) or 0, now - self.PRICES_USE_FOR)

    local ids = {}
    for itemID, record in pairs(table_) do
        -- As Guild Prices: an item searched with nothing listed keeps a seen
        -- time but no market value, and a sold out one an old value.
        if type(itemID) == "number" and type(record) == "table" and type(record.seen) == "number"
            and record.seen > floor and record.seen <= now + 3600 and type(record.market) == "number"
            and prices.IsCredible(record.market) and (tonumber(record.quantity) or 1) > 0 then
            ids[#ids + 1] = itemID
        end
    end
    table.sort(ids, function(a, b)
        local sa, sb = table_[a].seen, table_[b].seen
        if sa ~= sb then return sa > sb end
        return a < b
    end)

    local head = "O" .. Comm.ToBase36(math.floor(now)) .. ":"
    local batches, parts, length = {}, {}, #head
    for index = 1, math.min(#ids, self.PRICES_MAX_ITEMS) do
        local record = table_[ids[index]]
        local market = math.floor(record.market + 0.5)
        local lowest = prices.LowestListed and prices.LowestListed(record)
        local lowText = ""
        if lowest and prices.IsCredible(lowest) and math.floor(lowest + 0.5) ~= market then
            lowText = Comm.ToBase36(math.floor(lowest + 0.5))
        end
        local age = math.max(0, math.floor(now - record.seen))
        local entry = Comm.ToBase36(ids[index]) .. "," .. Comm.ToBase36(market) .. "," .. lowText
            .. "," .. (age > 0 and Comm.ToBase36(age) or "") .. ";"
        if length + #entry > Comm.MAX_MESSAGE then
            batches[#batches + 1] = head:sub(2) .. table.concat(parts)
            parts, length = {}, #head
        end
        parts[#parts + 1] = entry
        length = length + #entry
    end
    if #parts > 0 then batches[#batches + 1] = head:sub(2) .. table.concat(parts) end
    return batches, #ids
end

--- What this realm holds from each partner: { [partner key] = held }.
local function PriceStore(create)
    local realm = OurRealm()
    if not realm or not ns.db then return nil end
    local all = ns.db.linkedPrices
    if type(all) ~= "table" then
        if not create then return nil end
        all = {}
        ns.db.linkedPrices = all
    end
    local mine = all[realm]
    if type(mine) ~= "table" then
        if not create then return nil end
        mine = {}
        all[realm] = mine
    end
    return mine
end

--- Ask a partner for the prices seen since what is held from it.
function AccountLink:AskPrices(state)
    local store = PriceStore(false)
    local held = store and store[Comm.NameKey(state.name)]
    local since = type(held) == "table" and tonumber(held.at) or 0
    state.pricesAskedAt = time()
    Whisper("E", Comm.ToBase36(math.floor(since)), state.name)
end

--- A partner's manifest said when it last scanned and where ("off" when
--- it does not share prices). Ask when that is newer than what is held.
function AccountLink:OnPricesHash(state, value)
    if type(value) ~= "string" or not self:PricesOn() then return end
    if value == "off" then
        self:DropPrices(Comm.NameKey(state.name))
        return
    end
    local atText, realm = value:match("^(%w+)@(.+)$")
    local at = Comm.FromBase36(atText)
    if not at or realm ~= RealmKey(OurRealm()) then return end
    local store = PriceStore(false)
    local held = store and store[Comm.NameKey(state.name)]
    if type(held) == "table" and tonumber(held.at) and held.at >= at then return end
    if state.pricesAskedAt and time() - state.pricesAskedAt < self.PRICES_ASK_WAIT then return end
    self:AskPrices(state)
end

--- E: a partner asks for this account's prices seen after a time.
function AccountLink:OnPricesWanted(sender, body, channel)
    if channel ~= "WHISPER" then return end
    local state = self:PartnerFor(sender)
    if not state or not self:PricesOn() then return end
    local now = time()
    if state.pricesSentAt and now - state.pricesSentAt < self.PRICES_ANSWER_GAP then return end
    state.pricesSentAt = now
    local since = Comm.FromBase36(type(body) == "string" and body or "") or 0
    for _, batch in ipairs(self:PriceBatches(since, now)) do Whisper("O", batch, state.name) end
end

--- O: one batch of a partner's prices, taken only after asking for them.
function AccountLink:OnPrices(sender, body, channel)
    if channel ~= "WHISPER" or type(body) ~= "string" then return end
    local state = self:PartnerFor(sender)
    if not state or not self:PricesOn() then return end
    local now = time()
    if not state.pricesAskedAt or now - state.pricesAskedAt > self.PRICES_TAKE_FOR then return end
    local key = Comm.NameKey(state.name)
    local prices = ns.Prices
    if not key or not (prices and prices.IsCredible) then return end

    local atText, list = body:match("^(%w+):(.*)$")
    local at = Comm.FromBase36(atText)
    if not at or at > now + 3600 or now - at > self.PRICES_KEEP then return end

    local store = PriceStore(true)
    if not store then return end
    local held = store[key]
    if type(held) ~= "table" or type(held.items) ~= "table" then
        held = { items = {}, count = 0 }
        store[key] = held
    end
    held.count = tonumber(held.count) or 0

    local taken = 0
    for idText, marketText, lowText, ageText in list:gmatch("(%w+),(%w+),(%w*),(%w*);") do
        local itemID, market = Comm.FromBase36(idText), Comm.FromBase36(marketText)
        local lowest = lowText ~= "" and Comm.FromBase36(lowText) or market
        local age = ageText ~= "" and Comm.FromBase36(ageText) or 0
        local seen = age and at - age
        if itemID and itemID > 0 and itemID <= self.PRICES_MAX_ITEM_ID and itemID == math.floor(itemID)
            and prices.IsCredible(market) and prices.IsCredible(lowest)
            and seen and now - seen <= self.PRICES_USE_FOR then
            local old = held.items[itemID]
            if type(old) ~= "table" then
                if held.count < self.PRICES_MAX_STORED then
                    held.items[itemID] = { market, lowest, seen }
                    held.count = held.count + 1
                    taken = taken + 1
                end
            elseif (tonumber(old[3]) or 0) < seen then
                old[1], old[2], old[3] = market, lowest, seen
                taken = taken + 1
            end
            if ns.PriceHistory and ns.PriceHistory.Fill then pcall(ns.PriceHistory.Fill, ns.PriceHistory, itemID, lowest, seen) end
        end
    end
    if not tonumber(held.at) or held.at < at then held.at = at end
    if taken > 0 then prices.changes = (prices.changes or 0) + 1 end
end

--- A partner's price for an item and when it was seen, or nil: the newest
--- any partner sent within PRICES_USE_FOR. `which` as Prices:GetValue:
--- "min" or "lowest" read the cheapest listing, "rival" is never answered.
function AccountLink:PriceFor(itemID, which, now)
    if which == "rival" or not self:PricesOn() then return nil end
    local store = PriceStore(false)
    if not store then return nil end
    now = now or time()
    local value, newest
    for _, held in pairs(store) do
        local item = type(held) == "table" and type(held.items) == "table" and held.items[itemID]
        local seen = type(item) == "table" and tonumber(item[3])
        if seen and now - seen <= self.PRICES_USE_FOR and (not newest or seen > newest) then
            local price = (which == "min" or which == "lowest") and item[2] or item[1]
            if type(price) == "number" then value, newest = price, seen end
        end
    end
    return value, newest
end

--- How many prices are held from a partner (by name) and when it last
--- scanned, or nil.
function AccountLink:PricesHeld(name)
    local store = PriceStore(false)
    local held = store and store[Comm.NameKey(name)]
    if type(held) ~= "table" or (tonumber(held.count) or 0) <= 0 then return nil end
    return held.count, tonumber(held.at)
end

--- Let a partner's prices go (by key), or every partner's on every realm.
function AccountLink:DropPrices(key)
    local all = ns.db and ns.db.linkedPrices
    if type(all) ~= "table" then return end
    local dropped = false
    if key then
        for _, realm in pairs(all) do
            if type(realm) == "table" and realm[key] ~= nil then realm[key] = nil; dropped = true end
        end
    else
        ns.db.linkedPrices = nil
        dropped = true
    end
    if dropped and ns.Prices then ns.Prices.changes = (ns.Prices.changes or 0) + 1 end
end

--- Let prices older than PRICES_KEEP go, and partners left with none.
function AccountLink:PrunePrices(now)
    local all = ns.db and ns.db.linkedPrices
    if type(all) ~= "table" then return end
    now = now or time()
    for realmKey, realm in pairs(all) do
        if type(realm) == "table" then
            for key, held in pairs(realm) do
                local count = 0
                if type(held) == "table" and type(held.items) == "table" then
                    for itemID, item in pairs(held.items) do
                        local seen = type(item) == "table" and tonumber(item[3])
                        if not seen or now - seen > self.PRICES_KEEP then
                            held.items[itemID] = nil
                        else
                            count = count + 1
                        end
                    end
                    held.count = count
                end
                if count == 0 then realm[key] = nil end
            end
            if next(realm) == nil then all[realmKey] = nil end
        else
            all[realmKey] = nil
        end
    end
    if next(all) == nil then ns.db.linkedPrices = nil end
end

--- A scan wrote prices. While linked, partners hear soon.
function AccountLink:PricesChanged()
    if self:PricesOn() then self:SendSoon(self.PRICES_KEY) end
end

--------------------------------------------------------------------------------
-- Status, for Settings and /bts share
--------------------------------------------------------------------------------

--- When each partner last told us what it has (a manifest) or sent a
--- character, kept account wide in `linkSyncedAt[name key]` so it lasts
--- past a reload. Never rename it.
function AccountLink:NoteSynced(sender)
    local key = Comm.NameKey(sender)
    if not key or not ns.db then return end
    ns.db.linkSyncedAt = ns.db.linkSyncedAt or {}
    ns.db.linkSyncedAt[key] = time()
end

--- The time a partner (by name) last synced, or nil.
function AccountLink:LastSynced(name)
    local key = Comm.NameKey(name)
    local saved = ns.db and ns.db.linkSyncedAt
    local at = key and type(saved) == "table" and saved[key]
    return type(at) == "number" and at or nil
end

--- "Last Synced: Ana Smith, 2 minutes ago", one line a partner, or nil
--- when no other account is named.
function AccountLink:LastSyncedText()
    local partners = self:GetPartners()
    if #partners == 0 then return nil end
    local lines = {}
    for _, partner in ipairs(partners) do
        local at = self:LastSynced(partner.name)
        local when = at and ns.Util.FormatAgeAgo(math.max(0, time() - at)) or L["Not yet"]
        lines[#lines + 1] = L.Format("Last Synced: %s, %s", partner.name, when)
    end
    return table.concat(lines, "\n")
end

function AccountLink:Describe()
    local partners = self:GetPartners()
    if #partners == 0 then return L["Not sharing with another account."] end

    local counts = self:CountLinked()
    local parts = {}
    for _, partner in ipairs(partners) do
        local state = self.partners[partner.key] or {}
        local held = 0
        for name, count in pairs(counts) do
            if Comm.NameKey(name) == partner.key then held = held + count end
        end
        local status = state.online and L["online"] or L["not heard from this session"]
        if held == 1 then
            parts[#parts + 1] = L.Format("%s: %s, %d character held", partner.name, status, held)
        else
            parts[#parts + 1] = L.Format("%s: %s, %d characters held", partner.name, status, held)
        end
        local priceCount, scanAt = self:PricesHeld(partner.name)
        if priceCount and scanAt and self:PricesOn() then
            parts[#parts + 1] = L.Format("%d prices from their scan %s", priceCount,
                ns.Util.FormatAgeAgo(math.max(0, time() - scanAt)))
        end
    end
    local pending = Comm:Pending()
    if pending == 1 then
        parts[#parts + 1] = L.Format("%d message waiting to go", pending)
    elseif pending > 1 then
        parts[#parts + 1] = L.Format("%d messages waiting to go", pending)
    end
    return table.concat(parts, ".  ") .. "."
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function AccountLink:OnEnable()
    Comm:On("H", function(sender, body, channel) AccountLink:OnHello(sender, body, channel, false) end)
    Comm:On("A", function(sender, body, channel) AccountLink:OnHello(sender, body, channel, true) end)
    Comm:OnTable("M", function(...) AccountLink:OnManifest(...) end)
    Comm:OnTable("W", function(...) AccountLink:OnWant(...) end)
    Comm:OnTable("C", function(...) AccountLink:OnCharacter(...) end)
    Comm:On("V", function(...) AccountLink:OnListsWanted(...) end)
    Comm:OnTable("U", function(...) AccountLink:OnLists(...) end)
    Comm:On("E", function(...) AccountLink:OnPricesWanted(...) end)
    Comm:On("O", function(...) AccountLink:OnPrices(...) end)
    pcall(self.PrunePrices, self)
    -- A scan that wrote prices: partners hear a few seconds later.
    if ns.Prices and ns.Prices.WatchScans then
        ns.Prices:WatchScans(function() AccountLink:PricesChanged() end)
    end
    Comm.onOffline = function(key)
        AccountLink:OnOffline(key)
        if ns.GuildCrafters and ns.GuildCrafters.OnOffline then ns.GuildCrafters:OnOffline(key) end
    end
    self:SetAsideFriends()

    -- After the login rush, then now and then.
    C_Timer.After(20, function() AccountLink:Check() end)
    self.ticker = C_Timer.NewTicker(self.CHECK_SECONDS, function() AccountLink:Check() end)
end

--------------------------------------------------------------------------------
-- /bts share (each has a button or box in Settings, Sharing)
--------------------------------------------------------------------------------

function AccountLink:SetNames(text)
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    ns.Config:Set("linkNames", text)
end

ns.RegisterCommand("share", L["share with your other account and guild: with <names>, sync, guild on|off, forget, test"],
    function(args)
        local word, rest = (args or ""):match("^(%S*)%s*(.-)%s*$")
        word = (word or ""):lower()

        if word == "with" then
            AccountLink:SetNames(rest)
            AccountLink:Check()
            ns.Print(rest ~= "" and L.Format("sharing with: %s", rest) or L["not sharing with another account"])
        elseif word == "sync" then
            AccountLink:Check()
            ns.Print(L["asked your other account for anything new"])
        elseif word == "guild" then
            local on = (rest or ""):lower() == "on"
            ns.Config:Set("guildPrices", on)
            ns.Print(on and L["guild prices on"] or L["guild prices off"])
        elseif word == "realm" then
            local on = (rest or ""):lower() == "on"
            if ns.RealmPrices then ns.RealmPrices:SetOn(on) else ns.Config:Set("realmPrices", on) end
            ns.Print(on and L["realm prices on"] or L["realm prices off"])
        elseif word == "forget" then
            local count = AccountLink:Forget(rest ~= "" and rest or nil)
            if count == 1 then
                ns.Print(L.Format("forgot %d character from your other account", count))
            else
                ns.Print(L.Format("forgot %d characters from your other account", count))
            end
        elseif word == "test" then
            ns.Comm:Test()
        elseif word == "channel" then
            -- Typed only, and left out of the help line: a check for Claude.
            ns.KeepCheck("share channel", ns.Comm.ChannelTest, ns.Comm)
        elseif word == "data" and ns.Contribute then
            -- Typed only, and left out of the help line.
            ns.Contribute:Command(rest)
        else
            ns.Print(AccountLink:Describe())
            local synced = AccountLink:LastSyncedText()
            if synced then ns.PrintRaw("  " .. (synced:gsub("\n", "\n  "))) end
            if ns.GuildPrices then ns.PrintRaw("  " .. ns.GuildPrices:Describe()) end
            if ns.RealmPrices and ns.RealmPrices:IsOn() then ns.PrintRaw("  " .. ns.RealmPrices:Describe()) end
        end
    end)

-- Settings had a Forget their characters button; it is typed now (the
-- owner, 2026-10-15), since Settings never deletes data.
ns.RegisterCommand("forgetlinked", L["remove the copies of your other account's characters (add confirm)"],
    function(args)
        if not (args or ""):lower():match("^%s*confirm%s*$") then
            ns.Print(L["This removes the copies of your other account's characters. Your own stay. Type /bts forgetlinked confirm to do it."])
            return
        end
        local count = AccountLink:Forget() or 0
        if count == 1 then
            ns.Print(L.Format("forgot %d character from your other account", count))
        else
            ns.Print(L.Format("forgot %d characters from your other account", count))
        end
        if ns.UI and ns.UI.RefreshActiveTab then ns.UI:RefreshActiveTab() end
    end)
