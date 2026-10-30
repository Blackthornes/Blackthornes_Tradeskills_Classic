-- Blackthornes Tradeskills -- Logic/DisenchantLog.lua
-- What your own disenchants actually gave.
--
-- The built-in table in Logic/Disenchant.lua is the published Classic one,
-- and nothing guarantees Forever matches it. So every disenchant you do is
-- recorded here: which item went in, and what came out. Results are pooled
-- by row of the table (quality, item level band, armor or weapon), and once
-- a row has enough of them, Disenchant:GetOutcomes uses yours instead. They
-- are kept per item too, and an item's own results win once it has a few,
-- since Forever does not break every item the way its row says.
--
-- Knowing what came out is easy: it is the loot window that opens after the
-- cast. Knowing what went in is the hard part, because the game does not say
-- which item a Disenchant was cast on. Three ways are tried, best first:
--
--   * the loot window's source, which on a modern client names the item the
--     loot came from;
--   * the bag slot you clicked while the spell was waiting for a target;
--   * the item name the game passes with the cast, matched against the bags;
--   * our own Disenchant button, which says which item it aimed at;
--   * the one disenchantable item the game locks in the bags while the
--     spell is cast on it (Classic Era names no item any other way).
--
-- Each record notes which one found the item, and `/bts delog` shows it, so
-- the first disenchant in game says which of these this client supports.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local DisenchantLog = ns.NewModule("DisenchantLog")

local Util = ns.Util

-- Disenchant's spell ID on Classic. The name is checked too, in case Forever
-- numbers it differently: the English one, and the one this client gives
-- that spell ID ("Entzaubern" on a German client).
local DISENCHANT_SPELL = 13262
local DISENCHANT_NAME = "Disenchant"

-- How long after the cast finishes the loot window may take to open.
local LOOT_WINDOW = 5

-- How long a clicked bag slot stays the likely target.
local AIM_WINDOW = 30

-- Recent disenchants kept for /bts delog.
local RECENT_KEPT = 20

local aimed        -- { itemID, from, at }: the item the spell was pointed at
local cast         -- { itemID, from, at }: a Disenchant that just finished

--------------------------------------------------------------------------------
-- Storage
--------------------------------------------------------------------------------

--- Account wide: what an item breaks into does not depend on who breaks it.
function DisenchantLog:GetTable()
    if not ns.db then return { bands = {}, recent = {}, missed = 0 } end

    local log = ns.db.disenchantLog or {}
    ns.db.disenchantLog = log

    log.bands = log.bands or {}
    log.recent = log.recent or {}
    log.missed = log.missed or 0

    -- Per item results came later (2026-10-07). The first time, the recent
    -- list fills them in, so those disenchants are not lost.
    if not log.items then
        log.items = {}
        for _, entry in ipairs(log.recent) do
            if entry.itemID and type(entry.results) == "table" then
                DisenchantLog.Add(log.items, entry.itemID, entry.results)
            end
        end
    end

    return log
end

--- Count one disenchant into a { casts, got } record.
local function AddTo(record, results)
    record.casts = record.casts + 1

    local newFinds = {}
    for materialID, count in pairs(results) do
        local got = record.got[materialID] or { times = 0, total = 0 }
        record.got[materialID] = got
        if got.times == 0 and record.casts > 1 then newFinds[#newFinds + 1] = materialID end

        got.times = got.times + 1
        got.total = got.total + count
        got.min = got.min and math.min(got.min, count) or count
        got.max = got.max and math.max(got.max, count) or count
    end

    return newFinds
end

--- Count one disenchant into a table of records by key.
function DisenchantLog.Add(records, key, results)
    local record = records[key] or { casts = 0, got = {} }
    records[key] = record
    return record, AddTo(record, results)
end

--- One item's own results, or nil when it has never been disenchanted.
function DisenchantLog:GetItem(itemID)
    if not itemID then return nil end
    return self:GetTable().items[itemID]
end

--- The pooled results for one row of the table, or nil when there are none.
function DisenchantLog:GetBand(key)
    if not key then return nil end
    return self:GetTable().bands[key]
end

--- Add one disenchant: the item that went in and what came out.
--
-- @param results { [materialID] = count }
-- @return true when it was recorded
function DisenchantLog:Record(itemID, results, from)
    local _, facts = ns.Disenchant:GetOutcomes(itemID)
    if not facts or not facts.key then return false, L["that item cannot be disenchanted"] end

    -- What one of these was expected to give, before this one counts.
    local usual = ns.Disenchant:GetValue(itemID)

    -- One bought to disenchant has been (Logic/DisenchantBuys.lua).
    local buys = ns.DisenchantBuys
    if buys and buys.Used then pcall(buys.Used, buys, itemID, 1) end

    local log = self:GetTable()
    local band, newFinds = DisenchantLog.Add(log.bands, facts.key, results)
    local item = DisenchantLog.Add(log.items, itemID, results)

    -- Did this one show the item breaks differently from its row?
    local _, now = ns.Disenchant:GetOutcomes(itemID)
    local itemLearned = now and now.byItem and not facts.byItem and item or nil

    table.insert(log.recent, 1, {
        itemID = itemID, results = results, from = from,
        at = time and time() or 0,
    })
    while #log.recent > RECENT_KEPT do table.remove(log.recent) end

    if ns.MethodProfit then pcall(ns.MethodProfit.NoteDisenchant, ns.MethodProfit, itemID, results) end

    self:Announce(itemID, results, facts.key, band, usual, newFinds, itemLearned)
    self:AddToSession(results)

    -- Lists built from these results know to rebuild.
    self.version = (self.version or 0) + 1

    if ns.UI and ns.UI.RefreshActiveTab then ns.UI:RefreshActiveTab() end

    return true
end

--------------------------------------------------------------------------------
-- Telling you what was learnt
--------------------------------------------------------------------------------

-- A disenchant counts as lucky when it gave this much more than usual.
local LUCKY = 1.5

local function Colour(key, text)
    return ("|c%s%s|r"):format(ns.COLORS[key], text)
end

local function MaterialLabel(materialID)
    return ns.Disenchant:MaterialName(materialID) or Util.GetItemLabel(materialID)
end

--- What the materials would sell for, or nil when none has a price.
local function Worth(results)
    local total, priced = 0, false
    for materialID, count in pairs(results) do
        local price = ns.Disenchant:GetMaterialPrice(materialID)
        if price then
            total = total + price * count
            priced = true
        end
    end
    return priced and total or nil
end

--- A line across the middle of the screen, where the game shows quest updates.
local function Flash(text)
    local frame = _G.UIErrorsFrame
    if type(frame) == "table" and type(frame.AddMessage) == "function" then
        pcall(frame.AddMessage, frame, text, 0.31, 0.82, 0.55, 1)
    end
end

--- A sound: the level up fanfare for a kind of item learnt, a softer one for
--- anything else worth noticing.
local function Chime(big)
    if type(PlaySound) ~= "function" then return end
    -- Settings: SOUNDS, Disenchant finds.
    if ns.Config and ns.Config:Get("disenchantSound") == false then return end
    local kits = type(_G.SOUNDKIT) == "table" and _G.SOUNDKIT or {}
    local kit = big and (kits.LEVELUPSOUND or 888) or kits.UI_EPICLOOT_TOAST
    if kit then pcall(PlaySound, kit, "Master") end
end

DisenchantLog._Flash, DisenchantLog._Chime = Flash, Chime

--- Say what that disenchant gave and what it taught.
function DisenchantLog:Announce(itemID, results, key, band, usual, newFinds, item)
    local Disenchant = ns.Disenchant
    local learnAfter = Disenchant.LEARN_AFTER
    local kind = Disenchant:DescribeKey(key)

    local parts = {}
    for materialID, count in pairs(results) do
        parts[#parts + 1] = ("%d %s"):format(count, MaterialLabel(materialID))
    end
    table.sort(parts)

    local worth = Worth(results)
    local progress
    if band.casts < learnAfter then
        progress = L.Format("learning %s: %d of %d", kind, band.casts, learnAfter)
    else
        progress = L.Format("%s: %d recorded", kind, band.casts)
    end

    ns.Print(L.Format("%s %s: %s%s. %s.",
        Colour("profit", L["Disenchanted"]), Util.GetItemLabel(itemID), table.concat(parts, ", "),
            worth and L.Format(", worth %s", Util.FormatMoney(worth)) or "", Colour("muted", progress)))

    local big = false

    if band.casts == learnAfter then
        local odds = {}
        for materialID, got in pairs(band.got) do
            odds[#odds + 1] = { name = MaterialLabel(materialID), chance = got.times / band.casts }
        end
        table.sort(odds, function(a, b)
            if a.chance ~= b.chance then return a.chance > b.chance end
            return a.name < b.name
        end)
        for index, odd in ipairs(odds) do
            odds[index] = ("%s %d%%"):format(odd.name, math.floor(odd.chance * 100 + 0.5))
        end

        ns.Print(L.Format("%s %s now uses your own results: %s. From now on, its value follows what you actually get.",
            Colour("accent", L["Learned:"]), kind, table.concat(odds, ", ")))
        Flash(L.Format("Learned: %s", kind))
        big = true
    end

    -- An item that breaks differently from its row now uses its own results.
    if item then
        local odds = {}
        for materialID, got in pairs(item.got) do
            odds[#odds + 1] = { name = MaterialLabel(materialID), chance = got.times / item.casts }
        end
        table.sort(odds, function(a, b)
            if a.chance ~= b.chance then return a.chance > b.chance end
            return a.name < b.name
        end)
        for index, odd in ipairs(odds) do
            odds[index] = ("%s %d%%"):format(odd.name, math.floor(odd.chance * 100 + 0.5))
        end

        ns.Print(L.Format("%s %s does not break the way the table says for %s, so it now uses your own results: %s.",
            Colour("accent", L["Learned:"]), Util.GetItemLabel(itemID), kind, table.concat(odds, ", ")))
        Flash(L.Format("Learned: %s", Util.GetItemLabel(itemID)))
        big = true
    end

    for _, materialID in ipairs(newFinds or {}) do
        ns.Print(L.Format("%s %s can come from %s.", Colour("accent", L["New find:"]),
            MaterialLabel(materialID), kind))
        Flash(L.Format("New find: %s", MaterialLabel(materialID)))
    end

    local lucky = worth and usual and usual > 0 and worth >= usual * LUCKY
    if lucky then
        ns.Print(L.Format("%s That one was worth %s; about %s is usual.",
            Colour("accent", L["Lucky:"]), Util.FormatMoney(worth), Util.FormatMoney(usual)))
        if #(newFinds or {}) == 0 then
            Flash(L.Format("Lucky disenchant: %s", Util.FormatMoney(worth, { noColor = true })))
        end
    end

    if big then
        Chime(true)
    elseif lucky or #(newFinds or {}) > 0 then
        Chime(false)
    end
end

--- This session's running total, for the Disenchanting tab's bags list.
-- Kept in memory only: it starts again at zero after a /reload.
function DisenchantLog:AddToSession(results)
    local session = self.session or { count = 0, worth = 0 }
    self.session = session

    session.count = session.count + 1
    session.worth = session.worth + (Worth(results) or 0)
end

--- How many disenchants this session and what their materials are worth.
function DisenchantLog:GetSession()
    local session = self.session
    if not session then return 0, 0 end
    return session.count, session.worth
end

--- A disenchant that finished but could not be recorded, and why.
function DisenchantLog:Miss(reason)
    local log = self:GetTable()
    log.missed = log.missed + 1
    log.lastMiss = reason

    ns.Print(L.Format("could not record that disenchant: %s. /bts delog has more.", reason))
end

--------------------------------------------------------------------------------
-- Watching
--------------------------------------------------------------------------------

local function Now()
    return GetTime and GetTime() or 0
end

--- Is this the player? Read inside a pcall: in an instance the game can hand
--- over a value that refuses to be compared.
local function IsPlayer(unit)
    local ok, yes = pcall(function() return unit == "player" end)
    return ok and yes == true
end

local function SpellName(spellID)
    local name
    if Util.HasFunction("C_Spell.GetSpellName") then
        local gotName, value = pcall(C_Spell.GetSpellName, spellID)
        if gotName then name = value end
    elseif type(GetSpellInfo) == "function" then
        local gotName, value = pcall(GetSpellInfo, spellID)
        if gotName then name = value end
    end
    return name
end

-- The client's own name for Disenchant, read once it answers.
local clientName

local function ClientName()
    if clientName then return clientName end
    local ok, name = pcall(function()
        local value = SpellName(DISENCHANT_SPELL)
        if type(value) == "string" and value ~= "" then return value .. "" end
    end)
    if ok and name then clientName = name end
    return clientName
end

local function IsDisenchant(spellID)
    local ok, yes = pcall(function() return spellID == DISENCHANT_SPELL end)
    if ok and yes then return true end

    local name = SpellName(spellID)
    local own = ClientName()
    local same, match = pcall(function()
        return name == DISENCHANT_NAME or (own ~= nil and name == own)
    end)
    return same and match == true
end

DisenchantLog._IsDisenchant = IsDisenchant

local function ItemAt(bag, slot)
    if not Util.HasFunction("C_Container.GetContainerItemID") then return nil end
    local ok, itemID = pcall(C_Container.GetContainerItemID, bag, slot)
    if ok and type(itemID) == "number" then return itemID end
    return nil
end

--- A bag slot was clicked. If a spell was waiting for a target, that slot's
--- item is what it was pointed at.
function DisenchantLog:OnBagClick(bag, slot)
    if type(SpellIsTargeting) ~= "function" then return end

    local ok, targeting = pcall(SpellIsTargeting)
    if not ok or not targeting then return end

    local itemID = ItemAt(bag, slot)
    if itemID then
        aimed = { itemID = itemID, from = "click", at = Now() }
    end
end

--- Our own Disenchant button aimed the spell at this item.
function DisenchantLog:Aim(itemID, from)
    if type(itemID) ~= "number" then return end
    aimed = { itemID = itemID, from = from or "button", at = Now() }
end

--- The disenchantable item the game has locked in the bags, while one
--- Disenchant is being cast on it. nil when there is none, or more than one
--- kind (something else is being moved too), since a guess would be wrong.
function DisenchantLog:LockedInBags()
    if not Util.HasFunction("C_Container.GetContainerNumSlots")
        or not Util.HasFunction("C_Container.GetContainerItemInfo") then return nil end

    local found
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        local okSlots, slots = pcall(C_Container.GetContainerNumSlots, bag)
        for slot = 1, (okSlots and type(slots) == "number") and slots or 0 do
            local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
            local itemID = ok and type(info) == "table" and info.isLocked == true and info.itemID or nil
            if type(itemID) == "number" and ns.Disenchant:IsDisenchantable(itemID) then
                if found and found ~= itemID then return nil end
                found = itemID
            end
        end
    end
    return found
end

--- No fresh aim yet: take the item the cast has locked, if there is one.
function DisenchantLog:AimAtLocked()
    if aimed and Now() - aimed.at < AIM_WINDOW then return end
    local itemID = self:LockedInBags()
    if itemID then aimed = { itemID = itemID, from = "locked", at = Now() } end
end

--- The disenchantable item in the bags with this name, if there is one.
function DisenchantLog:FindInBags(name)
    if type(name) ~= "string" or name == "" then return nil end

    local counts = ns.Inventory and ns.Inventory:GetBagCounts() or {}

    for itemID in pairs(counts) do
        if ns.Disenchant:IsDisenchantable(itemID) then
            local itemName = ns.Disenchant:ItemName(itemID)
            -- Random-suffix items carry "of the Bear" after the base name.
            if itemName == name or name:sub(1, #itemName + 1) == itemName .. " " then
                return itemID
            end
        end
    end

    return nil
end

function DisenchantLog:OnCastSent(_, unit, target, _, spellID)
    if not IsPlayer(unit) then return end

    -- A click that aimed some other spell, an enchant say, is not this one.
    if not IsDisenchant(spellID) then
        aimed = nil
        return
    end

    local ok, name = pcall(function() return target .. "" end)
    local named = ok and self:FindInBags(name) or nil

    -- The click is the better witness, unless the name the game sends says
    -- it was some other item.
    local clicked = aimed and Now() - aimed.at < AIM_WINDOW and aimed.itemID or nil
    if clicked and (not named or named == clicked) then return end

    if named then
        aimed = { itemID = named, from = "name", at = Now() }
    end
end

--- The cast has begun, so its item is locked in the bags now.
function DisenchantLog:OnCastStart(_, unit, _, spellID)
    if not IsPlayer(unit) or not IsDisenchant(spellID) then return end
    self:AimAtLocked()
end

function DisenchantLog:OnCastSucceeded(_, unit, _, spellID)
    if not IsPlayer(unit) or not IsDisenchant(spellID) then return end

    -- Still locked until the loot is taken, if the start was missed.
    self:AimAtLocked()

    local fresh = aimed and Now() - aimed.at < AIM_WINDOW
    cast = {
        itemID = fresh and aimed.itemID or nil,
        from = fresh and aimed.from or nil,
        at = Now(),
    }
    aimed = nil
end

--- The item a loot slot came from, when the game says.
local function LootSourceItem(slot)
    if type(GetLootSourceInfo) ~= "function" then return nil end
    if not Util.HasFunction("C_Item.GetItemIDByGUID") then return nil end

    local ok, guid = pcall(GetLootSourceInfo, slot)
    if not ok or type(guid) ~= "string" then return nil end

    local checked, isItem = pcall(function() return guid:sub(1, 5) == "Item-" end)
    if not checked or not isItem then return nil end

    local gotID, itemID = pcall(C_Item.GetItemIDByGUID, guid)
    if gotID and type(itemID) == "number" then return itemID end

    return nil
end

--- Read the loot window, if it belongs to the Disenchant that just finished.
function DisenchantLog:OnLootReady()
    if not cast then return end

    local pending = cast
    if Now() - pending.at > LOOT_WINDOW then
        cast = nil
        return
    end

    if type(GetNumLootItems) ~= "function" then return end
    local gotCount, slots = pcall(GetNumLootItems)
    if not gotCount or type(slots) ~= "number" or slots < 1 then return end

    -- Read once: LOOT_READY and LOOT_OPENED both fire.
    cast = nil

    local results, itemID, from = {}, pending.itemID, pending.from
    local any = false

    for slot = 1, slots do
        -- Matched and counted inside the pcall too: in an instance the client
        -- can hand out a link or a count that raises when it is read. The ID
        -- is copied in there (the `+ 0`), so it is a plain number after.
        local gotLink, materialID = pcall(function()
            local link = GetLootSlotLink(slot)
            local id = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
            return id and id + 0
        end)
        if not gotLink then materialID = nil end

        if not materialID or not ns.Disenchant:IsMaterial(materialID) then
            self:Miss(L["the loot was not enchanting materials"])
            return
        end

        local gotInfo, quantity = pcall(function()
            local _, _, count = GetLootSlotInfo(slot)
            return math.max(1, tonumber(count) or 1)
        end)
        if not gotInfo then quantity = 1 end

        results[materialID] = (results[materialID] or 0) + quantity
        any = true

        local source = LootSourceItem(slot)
        if source then itemID, from = source, "loot" end
    end

    if not any then return end

    if not itemID then
        self:Miss(L["the game did not say which item was disenchanted"])
        return
    end

    local recorded, why = self:Record(itemID, results, from)
    if not recorded then self:Miss(why or L["unknown"]) end
end

--------------------------------------------------------------------------------
-- Command
--------------------------------------------------------------------------------

local FROM = {
    loot = L["loot window"],
    click = L["bag click"],
    name = L["cast name"],
    button = L["Disenchant button"],
    locked = L["item in use"],
}

local function Describe(results)
    local parts = {}
    for materialID, count in pairs(results or {}) do
        parts[#parts + 1] = ("%dx %s"):format(count,
            ns.Disenchant:MaterialName(materialID) or Util.GetItemLabel(materialID))
    end
    table.sort(parts)
    return table.concat(parts, ", ")
end

local function Report(input)
    local log = DisenchantLog:GetTable()

    if (input or ""):lower() == "reset" then
        ns.db.disenchantLog = nil
        DisenchantLog.version = (DisenchantLog.version or 0) + 1
        ns.Print(L["your recorded disenchants are cleared, so values come from the built-in table again"])
        if ns.UI and ns.UI.RefreshActiveTab then ns.UI:RefreshActiveTab() end
        return
    end

    local total, groups, trusted = 0, 0, 0
    for _, band in pairs(log.bands) do
        total = total + (band.casts or 0)
        groups = groups + 1
        if (band.casts or 0) >= ns.Disenchant.LEARN_AFTER then trusted = trusted + 1 end
    end

    ns.Print(L.Format("%s recorded across %s; %s your results (after %d each)",
        total == 1 and L.Format("%d disenchant", total) or L.Format("%d disenchants", total),
        groups == 1 and L.Format("%d kind of item", groups) or L.Format("%d kinds of item", groups),
        trusted == 1 and L.Format("%d kind uses", trusted) or L.Format("%d kinds use", trusted),
        ns.Disenchant.LEARN_AFTER))

    local items = {}
    for itemID in pairs(log.items) do
        local _, facts = ns.Disenchant:GetOutcomes(itemID)
        if facts and facts.byItem then items[#items + 1] = Util.GetItemLabel(itemID) end
    end
    if #items > 0 then
        table.sort(items)
        ns.Print(L.Format("breaking differently from the table, so using their own results: %s",
            table.concat(items, ", ")))
    end

    if log.missed > 0 then
        ns.Print(L.Format("%d could not be recorded; the last because %s", log.missed, log.lastMiss or "?"))
    end

    for index = 1, math.min(5, #log.recent) do
        local entry = log.recent[index]
        ns.Print(L.Format("  %s gave %s (item found by %s)", Util.GetItemLabel(entry.itemID),
            Describe(entry.results), FROM[entry.from] or entry.from or "?"))
    end

    if total == 0 and log.missed == 0 then
        ns.Print(L["disenchant something, then run /bts delog again to see it recorded"])
    end
end

DisenchantLog._Report = Report

ns.RegisterCommand("delog", L["your recorded disenchants; /bts delog reset clears them"], Report)

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

function DisenchantLog:OnEnable()
    -- Only the player's casts are wanted (ns.RegisterPlayerEvent).
    local RegisterForPlayer = ns.RegisterPlayerEvent or ns.RegisterEvent
    RegisterForPlayer(self, "UNIT_SPELLCAST_SENT", self.OnCastSent)
    RegisterForPlayer(self, "UNIT_SPELLCAST_START", self.OnCastStart)
    RegisterForPlayer(self, "UNIT_SPELLCAST_SUCCEEDED", self.OnCastSucceeded)
    ns.RegisterEvent(self, "LOOT_READY", self.OnLootReady)
    ns.RegisterEvent(self, "LOOT_OPENED", self.OnLootReady)

    -- Watch bag clicks without replacing them: hooksecurefunc runs after
    -- Blizzard's own call and changes nothing about it.
    if type(hooksecurefunc) == "function" and type(C_Container) == "table" then
        for _, name in ipairs({ "UseContainerItem", "PickupContainerItem" }) do
            if type(C_Container[name]) == "function" then
                pcall(hooksecurefunc, C_Container, name, function(bag, slot)
                    DisenchantLog:OnBagClick(bag, slot)
                end)
            end
        end
    end

    -- Classic Era's bags may call the old global names instead.
    if type(hooksecurefunc) == "function" then
        for _, name in ipairs({ "UseContainerItem", "PickupContainerItem" }) do
            local global = _G[name]
            local tableOne = type(C_Container) == "table" and C_Container[name] or nil
            if type(global) == "function" and global ~= tableOne then
                pcall(hooksecurefunc, name, function(bag, slot)
                    DisenchantLog:OnBagClick(bag, slot)
                end)
            end
        end
    end
end
