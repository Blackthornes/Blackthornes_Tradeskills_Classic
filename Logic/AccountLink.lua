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

-- How often partners are said hello to, or told what changed.
AccountLink.CHECK_SECONDS = 600
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
function AccountLink:Manifest()
    local manifest, count = {}, 0
    for guid, record in pairs(self:OwnCharacters()) do
        count = count + 1
        if count > MAX_CHARACTERS then break end
        local ok, text = pcall(ns.Serialize.EncodeCanonical, self:Payload(guid, record))
        if ok then manifest[guid] = Comm.Hash(text) end
    end
    return manifest
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

local CLEANERS = {
    name = CleanString, realm = CleanString, faction = CleanString, class = CleanString,
    surname = CleanString, level = CleanNumber, gold = CleanNumber,
    recipes = CleanRecipes, professions = CleanProfessions, professionLines = CleanLines,
    inventory = CleanCounts, bank = CleanCounts, mail = CleanCounts,
    recipesCachedAt = CleanNumber, inventoryAt = CleanNumber, bankAt = CleanNumber, mailAt = CleanNumber,
    race = CleanString, classFile = CleanString, zone = CleanString,
    xp = CleanNumber, xpMax = CleanNumber, restXP = CleanNumber, played = CleanNumber, seenAt = CleanNumber,
    resting = function(value) if type(value) == "boolean" then return value end end,
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
    for _, guid in ipairs(gone) do ns.Recipes:ForgetCharacter(guid) end
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

    -- Either side's check syncs both ways: answered with this side's own,
    -- unless it went out a moment ago (which is what stops the two
    -- answering each other for ever).
    if not state.manifestAt or time() - state.manifestAt > 60 then self:SendManifest(state) end

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
        self:Changed()
    else
        ns.Debug("share: a character from", tostring(sender), "was not taken:", tostring(why))
    end
end

function AccountLink:OnOffline(key)
    local state = self.partners[key]
    if state then state.online = false end
end

--------------------------------------------------------------------------------
-- Status, for Settings and /bts share
--------------------------------------------------------------------------------

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
