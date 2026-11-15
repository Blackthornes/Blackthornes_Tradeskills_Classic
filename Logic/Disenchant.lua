-- Blackthornes Tradeskills -- Logic/Disenchant.lua
-- What an item is worth broken down into enchanting materials.
--
-- The game does not tell addons what an item disenchants into: there is no
-- call that answers it, and the result is only known once the spell has been
-- cast. So the chances below are built in. They are the Classic disenchant
-- table as players have long published it (item quality, item level and
-- whether it is armour or a weapon decide the result), which is the table
-- this Classic-era realm has behaved like so far. If Forever turns out to
-- differ, this table is the one place to change.
--
-- The value is the expected worth of one disenchant: for every material it
-- can give, the chance times the average count times that material's
-- auction value. It is a long-run average, not a promise about any one cast.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Disenchant = ns.NewModule("Disenchant")

local Util = ns.Util

--------------------------------------------------------------------------------
-- The materials
--------------------------------------------------------------------------------

-- Classic item IDs.
local STRANGE_DUST, SOUL_DUST, VISION_DUST, DREAM_DUST, ILLUSION_DUST =
    10940, 11083, 11137, 11176, 16204

local LESSER_MAGIC, GREATER_MAGIC = 10938, 10939
local LESSER_ASTRAL, GREATER_ASTRAL = 10998, 11082
local LESSER_MYSTIC, GREATER_MYSTIC = 11134, 11135
local LESSER_NETHER, GREATER_NETHER = 11174, 11175
local LESSER_ETERNAL, GREATER_ETERNAL = 16202, 16203

local SMALL_GLIMMERING, LARGE_GLIMMERING = 10978, 11084
local SMALL_GLOWING, LARGE_GLOWING = 11138, 11139
local SMALL_RADIANT, LARGE_RADIANT = 11177, 11178
local SMALL_BRILLIANT, LARGE_BRILLIANT = 14343, 14344
local NEXUS_CRYSTAL = 20725

--- Every material a disenchant can give, lowest level first, with the name
--- to show before the client has the item cached.
Disenchant.MATERIALS = {
    { itemID = STRANGE_DUST,     name = "Strange Dust",           kind = "dust" },
    { itemID = LESSER_MAGIC,     name = "Lesser Magic Essence",   kind = "essence" },
    { itemID = GREATER_MAGIC,    name = "Greater Magic Essence",  kind = "essence" },
    { itemID = SMALL_GLIMMERING, name = "Small Glimmering Shard", kind = "shard" },
    { itemID = LESSER_ASTRAL,    name = "Lesser Astral Essence",  kind = "essence" },
    { itemID = GREATER_ASTRAL,   name = "Greater Astral Essence", kind = "essence" },
    { itemID = SOUL_DUST,        name = "Soul Dust",              kind = "dust" },
    { itemID = LARGE_GLIMMERING, name = "Large Glimmering Shard", kind = "shard" },
    { itemID = LESSER_MYSTIC,    name = "Lesser Mystic Essence",  kind = "essence" },
    { itemID = SMALL_GLOWING,    name = "Small Glowing Shard",    kind = "shard" },
    { itemID = VISION_DUST,      name = "Vision Dust",            kind = "dust" },
    { itemID = GREATER_MYSTIC,   name = "Greater Mystic Essence", kind = "essence" },
    { itemID = LARGE_GLOWING,    name = "Large Glowing Shard",    kind = "shard" },
    { itemID = LESSER_NETHER,    name = "Lesser Nether Essence",  kind = "essence" },
    { itemID = SMALL_RADIANT,    name = "Small Radiant Shard",    kind = "shard" },
    { itemID = DREAM_DUST,       name = "Dream Dust",             kind = "dust" },
    { itemID = GREATER_NETHER,   name = "Greater Nether Essence", kind = "essence" },
    { itemID = LARGE_RADIANT,    name = "Large Radiant Shard",    kind = "shard" },
    { itemID = LESSER_ETERNAL,   name = "Lesser Eternal Essence", kind = "essence" },
    { itemID = SMALL_BRILLIANT,  name = "Small Brilliant Shard",  kind = "shard" },
    { itemID = ILLUSION_DUST,    name = "Illusion Dust",          kind = "dust" },
    { itemID = GREATER_ETERNAL,  name = "Greater Eternal Essence", kind = "essence" },
    { itemID = LARGE_BRILLIANT,  name = "Large Brilliant Shard",  kind = "shard" },
    { itemID = NEXUS_CRYSTAL,    name = "Nexus Crystal",          kind = "shard" },
}

local MATERIAL_NAME = {}
for _, material in ipairs(Disenchant.MATERIALS) do
    MATERIAL_NAME[material.itemID] = material.name
end

--------------------------------------------------------------------------------
-- The table
--------------------------------------------------------------------------------

-- Uncommon (green) items. Each band covers item levels up to `upTo`. Armour
-- mostly gives dust; a weapon swaps the dust and essence chances, so it
-- mostly gives essence. The shard chance is the same for both.
--
-- weaponEssence is Forever's own: green weapons of item level 21 to 30 give
-- Greater Magic Essence, not the astral essence Classic's table names, while
-- their dust and shard are Classic's. Seen in game 2026-10-07 to 09: twelve
-- Dire Wands (item level 26) gave Greater Magic 7 times, Soul Dust 3 and
-- Large Glimmering 2, and a player's Forester's Axe (item level 23) gave
-- Greater Magic too. Armour of the same levels still gives astral.
local UNCOMMON = {
    { upTo = 15,  dust = { STRANGE_DUST, 1, 2 },  essence = { LESSER_MAGIC, 1, 2 },
      chances = { 0.80, 0.20, 0 } },
    { upTo = 20,  dust = { STRANGE_DUST, 2, 3 },  essence = { GREATER_MAGIC, 1, 2 },
      shard = SMALL_GLIMMERING, chances = { 0.75, 0.20, 0.05 } },
    { upTo = 25,  dust = { STRANGE_DUST, 4, 6 },  essence = { LESSER_ASTRAL, 1, 2 },
      weaponEssence = { GREATER_MAGIC, 1, 2 },
      shard = SMALL_GLIMMERING, chances = { 0.75, 0.15, 0.10 } },
    { upTo = 30,  dust = { SOUL_DUST, 1, 2 },     essence = { GREATER_ASTRAL, 1, 2 },
      weaponEssence = { GREATER_MAGIC, 1, 2 },
      shard = LARGE_GLIMMERING, chances = { 0.75, 0.20, 0.05 } },
    { upTo = 35,  dust = { SOUL_DUST, 2, 5 },     essence = { LESSER_MYSTIC, 1, 2 },
      shard = SMALL_GLOWING, chances = { 0.75, 0.20, 0.05 } },
    { upTo = 40,  dust = { VISION_DUST, 1, 2 },   essence = { GREATER_MYSTIC, 1, 2 },
      shard = LARGE_GLOWING, chances = { 0.75, 0.20, 0.05 } },
    { upTo = 45,  dust = { VISION_DUST, 2, 5 },   essence = { LESSER_NETHER, 1, 2 },
      shard = SMALL_RADIANT, chances = { 0.75, 0.20, 0.05 } },
    { upTo = 50,  dust = { DREAM_DUST, 1, 2 },    essence = { GREATER_NETHER, 1, 2 },
      shard = LARGE_RADIANT, chances = { 0.75, 0.20, 0.05 } },
    { upTo = 55,  dust = { DREAM_DUST, 2, 5 },    essence = { LESSER_ETERNAL, 1, 2 },
      shard = SMALL_BRILLIANT, chances = { 0.75, 0.20, 0.05 } },
    { upTo = 60,  dust = { ILLUSION_DUST, 1, 2 }, essence = { GREATER_ETERNAL, 1, 2 },
      shard = LARGE_BRILLIANT, chances = { 0.75, 0.20, 0.05 } },
    { upTo = math.huge, dust = { ILLUSION_DUST, 2, 5 }, essence = { GREATER_ETERNAL, 2, 3 },
      shard = LARGE_BRILLIANT, chances = { 0.75, 0.20, 0.05 } },
}

-- Rare (blue) items give a single shard, armour and weapons alike.
local RARE = {
    { upTo = 25, outcomes = { { SMALL_GLIMMERING, 1.0, 1, 1 } } },
    { upTo = 30, outcomes = { { LARGE_GLIMMERING, 1.0, 1, 1 } } },
    { upTo = 35, outcomes = { { SMALL_GLOWING, 1.0, 1, 1 } } },
    { upTo = 40, outcomes = { { LARGE_GLOWING, 1.0, 1, 1 } } },
    { upTo = 45, outcomes = { { SMALL_RADIANT, 1.0, 1, 1 } } },
    { upTo = 50, outcomes = { { LARGE_RADIANT, 1.0, 1, 1 } } },
    { upTo = 55, outcomes = { { SMALL_BRILLIANT, 1.0, 1, 1 } } },
    { upTo = math.huge, outcomes = { { LARGE_BRILLIANT, 0.995, 1, 1 },
                                     { NEXUS_CRYSTAL, 0.005, 1, 1 } } },
}

-- Epic (purple) items.
local EPIC = {
    { upTo = 45, outcomes = { { SMALL_RADIANT, 1.0, 2, 4 } } },
    { upTo = 50, outcomes = { { LARGE_RADIANT, 1.0, 2, 4 } } },
    { upTo = 55, outcomes = { { SMALL_BRILLIANT, 1.0, 2, 4 } } },
    { upTo = 60, outcomes = { { NEXUS_CRYSTAL, 1.0, 1, 1 } } },
    { upTo = math.huge, outcomes = { { NEXUS_CRYSTAL, 1.0, 1, 2 } } },
}

-- The Enchanting skill needed, by item level. Roughly: the published figures
-- vary a little between sources.
local SKILL = {
    { upTo = 20, skill = 1 },   { upTo = 25, skill = 25 },  { upTo = 30, skill = 50 },
    { upTo = 35, skill = 75 },  { upTo = 40, skill = 100 }, { upTo = 45, skill = 125 },
    { upTo = 50, skill = 150 }, { upTo = 55, skill = 175 }, { upTo = 60, skill = 200 },
    { upTo = math.huge, skill = 225 },
}

-- Item classes that can be disenchanted.
local CLASS_WEAPON, CLASS_ARMOR = 2, 4

-- Worn in a slot, but never disenchantable: shirts and tabards.
local NOT_DISENCHANTABLE_SLOT = { INVTYPE_BODY = true, INVTYPE_TABARD = true }

-- Wands made by Enchanting cannot be disenchanted (found in game), though
-- they look like any other wand. By item ID, and by name in case the client
-- numbers them differently.
local NOT_DISENCHANTABLE_ITEM = {
    [11287] = true, -- Lesser Magic Wand
    [11288] = true, -- Greater Magic Wand
    [11289] = true, -- Lesser Mystic Wand
    [11290] = true, -- Greater Mystic Wand
}
local NOT_DISENCHANTABLE_NAME = {
    ["Lesser Magic Wand"] = true, ["Greater Magic Wand"] = true,
    ["Lesser Mystic Wand"] = true, ["Greater Mystic Wand"] = true,
}

local QUALITY_NAME = { [2] = "uncommon", [3] = "rare", [4] = "epic" }
-- The same, shown to players.
local QUALITY_WORDS = { uncommon = L["uncommon"], rare = L["rare"], epic = L["epic"] }
Disenchant.QUALITY_WORDS = QUALITY_WORDS

local function Band(bands, itemLevel)
    for _, band in ipairs(bands) do
        if itemLevel <= band.upTo then return band end
    end
end

--------------------------------------------------------------------------------
-- Reading an item
--------------------------------------------------------------------------------

-- What the client has told us about each item. An item's quality, level
-- and slot never change, so they are kept in the saved data once read and
-- the client is never asked about that item again.
--
-- Why it matters (2026-09-27 and 28): the client's item cache is
-- small. Reading a thousand scanned weapons and armour through it pushed the
-- items in his bags out, and while an item is out the auction house calls it
-- unsellable, so Ready to sell dropped half its rows every other second. An
-- item the tab had just read could also be gone again a moment later, so
-- the tab's own count flipped too. Reading each item once, the moment the
-- client sends it, and remembering it for good ends both.
local sessionFacts = {}

local function Store()
    if ns.db then
        ns.db.itemFacts = ns.db.itemFacts or {}
        return ns.db.itemFacts
    end
    return sessionFacts
end

-- Items asked for and not yet answered: never read again until the client
-- says it has them, since reading an item it has not got makes it fetch the
-- item all over again. And how many times each was asked for, so an item
-- that never arrives is given up on rather than asked for for ever.
local waiting, attempts, arrived = {}, {}, {}

-- Whether each item is a weapon or armour, from the instant lookup.
local gearMemo = {}

-- An answer that never comes should not strand an item: ask again after this,
-- up to MAX_ATTEMPTS times in all.
local WAIT_SECONDS = 10
local MAX_ATTEMPTS = 2

-- What vt is set to once the tooltip has been read for its price and its
-- charges. Older saves have true: read for the price only.
local TOOLTIP_READ = 2

-- New items asked for per second. Few enough that the client can hold them
-- beside everything else it has loaded.
Disenchant.REQUESTS_PER_SECOND = 20

local budget = { second = nil, used = 0 }

local function Now()
    return type(GetTime) == "function" and GetTime() or 0
end

--- Is the auction house open? Nothing new is read then: that is when the
--- items in the bags must stay loaded, since the auction house refuses to
--- sell one the client has let go of.
local function AuctionHouseOpen()
    return ns.Scanner ~= nil and ns.Scanner.isAuctionHouseOpen == true
end

local function TakeRequest()
    if AuctionHouseOpen() then return false end

    local now = math.floor(Now())
    if budget.second ~= now then
        budget.second, budget.used = now, 0
    end
    if budget.used >= Disenchant.REQUESTS_PER_SECOND then return false end
    budget.used = budget.used + 1
    return true
end

--- Read an item from the client and keep it, or nil when the client does
--- not have it right now.
local function Remember(itemID)
    if not Util.HasFunction("C_Item.GetItemInfo") then return nil end

    local ok, name, _, quality, itemLevel, _, _, _, _, equipLoc, _, sellPrice, classID =
        pcall(C_Item.GetItemInfo, itemID)

    if not ok or not name or type(quality) ~= "number" or type(itemLevel) ~= "number" then
        return nil
    end

    -- v is what a vendor pays for one, 0 when it buys nothing. Kept for the
    -- Deals tab; items read before it existed have none yet. The
    -- tooltip's price wins over GetItemInfo's, which on Forever can still be
    -- Classic's (Util.GetTooltipSellPrice). vt says the tooltip was read, so
    -- prices saved before that are read once more.
    -- vt is 2 since the tooltip's charges are kept too (ch), so consumables
    -- read before that are read once more for them.
    local fromTooltip, tooltipRead, charges = Util.GetTooltipSellPrice(itemID)
    if fromTooltip then sellPrice = fromTooltip end

    local facts = { n = name, q = quality, l = itemLevel, c = classID, e = equipLoc,
                    v = type(sellPrice) == "number" and sellPrice or 0,
                    vt = tooltipRead and TOOLTIP_READ or nil,
                    ch = charges }
    Store()[itemID] = facts
    waiting[itemID], attempts[itemID] = nil, nil

    -- Lets a list know its rows may have changed without walking every item.
    Disenchant.factsVersion = (Disenchant.factsVersion or 0) + 1
    return facts
end

-- Items whose saved price was read again this session for the tooltip's.
local tooltipRetried = {}

-- Only consumables carry charges worth knowing about (oils, mostly), so
-- only they are read again for them: every item at once would crowd the
-- client's item cache the way the comment on Remember warns.
local CLASS_CONSUMABLE = 0
local function NeedsTooltip(known)
    if not known.vt then return true end
    return known.vt ~= TOOLTIP_READ and known.c == CLASS_CONSUMABLE
end

--- Did this addon ask the client for this item, and is it on its way or
--- just arrived? The tabs redraw only for those. Not for items read long
--- ago: Ready to sell reloads bag items all the time at the auction house,
--- and redrawing the whole list for each of those kept it churning.
function Disenchant:WasRequested(itemID)
    if waiting[itemID] or attempts[itemID] then return true end
    return arrived[itemID] ~= nil and Now() - arrived[itemID] < WAIT_SECONDS
end

--- The client has sent an item: read it now, while it is certainly there.
function Disenchant:OnItemInfoReceived(itemID, success)
    if not itemID or not waiting[itemID] then return end
    waiting[itemID] = nil
    arrived[itemID] = Now()
    if success ~= false then Remember(itemID) end
end

--- Has the client been asked for this item as often as it will be, with no
--- answer? Such an item is not "still being read": counting it that way kept
--- "N more listed items not checked yet" on screen all session.
function Disenchant:GaveUp(itemID)
    if (attempts[itemID] or 0) < MAX_ATTEMPTS then return false end
    return not (waiting[itemID] and Now() - waiting[itemID] < WAIT_SECONDS)
end

--- Read an item the saved facts do not have (or have without a sell price):
--- straight away when the client already holds it, otherwise ask for it and
--- return nil until it arrives.
local function Fetch(itemID)
    local known

    -- On its way: wait for the client to say so.
    if waiting[itemID] and Now() - waiting[itemID] < WAIT_SECONDS then return nil end
    if (attempts[itemID] or 0) >= MAX_ATTEMPTS then return nil end

    -- Nothing new is looked at while the auction house is open, not even
    -- to ask whether the client holds it: Ready to sell needs the room.
    if AuctionHouseOpen() then return nil end

    -- Only an item the client says it already holds is read straight
    -- away. Without that answer, reading it could set off a fetch, so it
    -- waits its turn like any other.
    if Util.HasFunction("C_Item.IsItemDataCachedByID") then
        local ok, answer = pcall(C_Item.IsItemDataCachedByID, itemID)
        if ok and answer == true then known = Remember(itemID) end
    elseif TakeRequest() then
        -- A client that cannot say: a read may fetch, so it spends the
        -- same allowance a request would.
        known = Remember(itemID)
    end

    if not known then
        -- Asked for a few at a time, and read when it arrives.
        if not TakeRequest() then return nil end

        attempts[itemID] = (attempts[itemID] or 0) + 1
        waiting[itemID] = Now()
        if Util.HasFunction("C_Item.RequestLoadItemDataByID") then
            pcall(C_Item.RequestLoadItemDataByID, itemID)
        end
        return nil
    end

    return known
end

--- What the game says about an item that decides its disenchant.
--
-- @return facts { quality, itemLevel, isWeapon, equipLoc }, a fresh copy the
--   caller may add to, or nil when the client has not sent the item yet.
function Disenchant:GetItemFacts(itemID)
    if not itemID then return nil end

    local known = Store()[itemID] or Fetch(itemID)
    if not known then return nil end

    return {
        quality = known.q,
        itemLevel = known.l,
        classID = known.c,
        isWeapon = known.c == CLASS_WEAPON,
        equipLoc = known.e,
    }
end

--- What a vendor pays for one of an item, from the same saved facts, so a
--- list of thousands of scanned items never reads them through the client's
--- small item cache on a redraw.
--
-- @return copper (0 when a vendor will not buy it), or nil while the item
--   has not been read yet. Items remembered before sell prices were kept
--   are read again, a few a second like any other, and so are items whose
--   price was saved before the tooltip was read for it: until then the old
--   price stands.
function Disenchant:GetSellPrice(itemID)
    if not itemID then return nil end

    -- What a vendor on Forever was seen paying beats what the client says.
    local paid = ns.Vendor and ns.Vendor.GetPaid and ns.Vendor:GetPaid(itemID)
    if paid then return paid end

    local known = Store()[itemID]
    if not known or known.v == nil then
        known = Fetch(itemID)
    elseif NeedsTooltip(known) and not tooltipRetried[itemID] and Util.HasFunction("C_TooltipInfo.GetItemByID") then
        -- Once a session: an item whose tooltip never has lines keeps the
        -- price it has rather than being read on every redraw.
        local fresh = Fetch(itemID)
        if fresh then
            tooltipRetried[itemID] = true
            known = fresh
        end
    end

    return known and known.v
end

--- Is the vendor price for this item one the game's data may have wrong,
--- because the item has charges and no sale on Forever has said what a
--- vendor pays for it?
function Disenchant:SellPriceUnsure(itemID)
    if ns.Vendor and ns.Vendor.GetPaid and ns.Vendor:GetPaid(itemID) then return false end
    local known = Store()[itemID]
    return known ~= nil and (known.ch or 0) > 0
end

--- Forget what was read about items (for tests).
function Disenchant:_ForgetItems()
    sessionFacts, waiting, attempts, arrived, tooltipRetried = {}, {}, {}, {}, {}
    gearMemo = {}
    if ns.db then ns.db.itemFacts = {} end
    budget.second, budget.used = nil, 0
end

ns.RegisterEvent(Disenchant, "GET_ITEM_INFO_RECEIVED", function(_, _, itemID, success)
    Disenchant:OnItemInfoReceived(itemID, success)
end)

--- Can this item be disenchanted at all? Only green, blue and purple armour
--- and weapons can.
--
-- @return true, false, or nil when the item is not cached yet.
function Disenchant:IsDisenchantable(itemID)
    local facts = self:GetItemFacts(itemID)
    if not facts then return nil end

    if not QUALITY_NAME[facts.quality] then return false end
    if facts.classID ~= CLASS_WEAPON and facts.classID ~= CLASS_ARMOR then return false end
    if NOT_DISENCHANTABLE_SLOT[facts.equipLoc] then return false end
    if NOT_DISENCHANTABLE_ITEM[itemID] then return false end

    local known = Store()[itemID]
    if known and NOT_DISENCHANTABLE_NAME[known.n] then return false end

    return true
end

-- Your own results take over from the table for a group of items once this
-- many of them have been disenchanted and recorded.
Disenchant.LEARN_AFTER = 10

-- And for one item, once it has been disenchanted this many times.
Disenchant.ITEM_LEARN_AFTER = 3

--- Chances from recorded results ({ casts, got }), most likely first.
local function Learned(record)
    local shaped = {}

    for materialID, got in pairs(record.got or {}) do
        shaped[#shaped + 1] = {
            itemID = materialID,
            chance = got.times / record.casts,
            min = got.min, max = got.max,
            average = got.total / got.times,
        }
    end

    table.sort(shaped, function(a, b)
        if a.chance ~= b.chance then return a.chance > b.chance end
        return a.itemID < b.itemID
    end)

    return shaped
end

--- Where the chances came from, for notes: "your own 4 disenchants of this
--- item" or "your own 12 disenchants of items like this".
function Disenchant:YoursPhrase(facts)
    if facts.byItem then
        return L.Format("your own %d disenchants of this item", facts.casts or 0)
    end
    return L.Format("your own %d disenchants of items like this", facts.casts or 0)
end

--- Which row of the table an item falls in, as a key for recording results.
--
-- Items in the same row break into the same things, so results are pooled
-- by row rather than by item: ten different level 22 green chests teach as
-- much as ten of the same one.
local function BandKey(facts, band)
    local top = band.upTo == math.huge and "top" or tostring(band.upTo)

    if facts.quality == 2 then
        return ("%d:%s:%s"):format(facts.quality, facts.isWeapon and "weapon" or "armor", top)
    end

    return ("%d:any:%s"):format(facts.quality, top)
end

local COLOUR_WORD = { [2] = "green", [3] = "blue", [4] = "purple" }

-- The colour and kind in words, one whole phrase each so a translation can
-- order them its own way.
local KIND_WORDS = {
    [2] = { weapon = L["green weapon"], armor = L["green armor"], any = L["green items"] },
    [3] = { weapon = L["blue weapon"], armor = L["blue armor"], any = L["blue items"] },
    [4] = { weapon = L["purple weapon"], armor = L["purple armor"], any = L["purple items"] },
}

--- A key from BandKey in words: "green armor, item level 21 to 25".
function Disenchant:DescribeKey(key)
    local quality, kind, top = tostring(key or ""):match("^(%d):(%a+):(%w+)$")
    quality = tonumber(quality)
    if not quality or not COLOUR_WORD[quality] then return tostring(key) end

    local bands = quality == 2 and UNCOMMON or quality == 3 and RARE or EPIC
    local upTo = top == "top" and math.huge or tonumber(top)

    local from = 1
    for _, band in ipairs(bands) do
        if band.upTo == upTo then break end
        from = band.upTo + 1
    end

    local levels
    if upTo == math.huge then
        levels = L.Format("item level %d and up", from)
    elseif from <= 1 then
        levels = L.Format("item level %d and below", upTo)
    else
        levels = L.Format("item level %d to %d", from, upTo)
    end

    local what = KIND_WORDS[quality][kind]
        or ("%s %s"):format(COLOUR_WORD[quality], kind == "any" and "items" or kind)
    return L.Format("%s, %s", what, levels)
end

--- What one disenchant of this item can give.
--
-- From your own recorded disenchants when there are enough of them for this
-- item (facts.byItem) or this kind of item (facts.source == "yours"),
-- otherwise from the built-in table (facts.source == "table"). facts.casts
-- is how many of yours are recorded.
--
-- @return outcomes { { itemID, chance, min, max, average }, ... }, facts
--   nil when the item cannot be disenchanted or is not cached yet.
function Disenchant:GetOutcomes(itemID)
    if not self:IsDisenchantable(itemID) then return nil end

    local facts = self:GetItemFacts(itemID)
    local level = facts.itemLevel
    local outcomes = {}
    local band

    if facts.quality == 2 then
        band = Band(UNCOMMON, level)
        local dustChance, essenceChance, shardChance =
            band.chances[1], band.chances[2], band.chances[3]

        if facts.isWeapon then
            dustChance, essenceChance = essenceChance, dustChance
        end

        -- Most likely first, so the list reads in the order it will happen.
        local dust = { band.dust[1], dustChance, band.dust[2], band.dust[3] }
        local essenceRow = facts.isWeapon and band.weaponEssence or band.essence
        local essence = { essenceRow[1], essenceChance, essenceRow[2], essenceRow[3] }

        if essenceChance > dustChance then
            outcomes[1], outcomes[2] = essence, dust
        else
            outcomes[1], outcomes[2] = dust, essence
        end

        if band.shard and shardChance > 0 then
            outcomes[3] = { band.shard, shardChance, 1, 1 }
        end
    else
        band = Band(facts.quality == 3 and RARE or EPIC, level)

        for index, outcome in ipairs(band.outcomes) do
            outcomes[index] = outcome
        end
    end

    local shaped = {}
    for index, outcome in ipairs(outcomes) do
        shaped[index] = {
            itemID = outcome[1], chance = outcome[2],
            min = outcome[3], max = outcome[4],
        }
    end

    facts.skill = Band(SKILL, level).skill
    facts.key = BandKey(facts, band)
    facts.source = "table"
    facts.casts = 0
    facts.byItem = nil

    local log = ns.DisenchantLog

    -- Your own results, once there are enough to trust over the table.
    local learned = log and log:GetBand(facts.key)
    if learned then
        facts.casts = learned.casts or 0

        if facts.casts >= self.LEARN_AFTER then
            shaped = Learned(learned)
            facts.source = "yours"
        end
    end

    -- This item's own results, when they say it breaks into something else:
    -- Forever can break one item differently from its row of the table
    -- (2026-10-07, a player's Dire Wands gave magic essences where the table
    -- says astral), and pooled with its row that would stay hidden for a
    -- long while. When they agree, the bigger pool gives the better odds.
    --
    -- Three casts are enough when the table's likeliest result never came
    -- out of it. When it did, three casts are only luck (three dust, one an
    -- essence, ties to the essence), so the item waits for LEARN_AFTER.
    local own = log and log.GetItem and log:GetItem(itemID)
    if own and (own.casts or 0) >= self.ITEM_LEARN_AFTER then
        local mine = Learned(own)
        local tableTopSeen = shaped[1] and own.got and own.got[shaped[1].itemID] ~= nil
        if mine[1] and (not shaped[1] or mine[1].itemID ~= shaped[1].itemID)
            and (not tableTopSeen or own.casts >= self.LEARN_AFTER) then
            shaped = mine
            facts.source = "yours"
            facts.casts = own.casts
            facts.byItem = true
        end
    end
    facts.qualityName = QUALITY_NAME[facts.quality]

    return shaped, facts
end

--------------------------------------------------------------------------------
-- Value
--------------------------------------------------------------------------------

--- The auction value of one of a material, or nil when it has never been
--- priced. Its lowest posting, leaving out a lone one far below the rest
--- (2026-09-27: "based on DE mat's lowest posting value disregarding
--- outliers"), since that is what the materials would sell for today.
function Disenchant:GetMaterialPrice(itemID)
    local value = ns.Prices and ns.Prices:GetValue(itemID, "lowest")
    if not value or value <= 0 then return nil end
    return value
end

--- What disenchanting one of this item gives, in copper: its most likely
--- outcome. Anything rarer is a bonus and is not counted.
--
-- @return value, partial, breakdown
--   value     nil when the item cannot be disenchanted, is not cached, or
--             its most likely material has no price yet
--   partial   always nil now; kept so callers need not change
--   breakdown { outcomes = { { itemID, name, chance, min, max, average,
--             price, worth }, ... }, facts }
function Disenchant:GetValue(itemID)
    local outcomes, facts = self:GetOutcomes(itemID)
    if not outcomes then return nil end

    -- Valued at the most likely outcome alone (2026-10-03:
    -- "disenchant value should be based on the highest chance outcome. Lucky
    -- disenchants are a bonus."). A 20% essence or a 5% shard is not what
    -- the next disenchant gives, so counting a share of it made breaking
    -- an item down look better than it usually is.
    local likely
    for index, outcome in ipairs(outcomes) do
        if not likely or outcome.chance > outcomes[likely].chance then likely = index end
    end

    local lines = {}
    local value

    for index, outcome in ipairs(outcomes) do
        local average = outcome.average or (outcome.min + outcome.max) / 2
        local price = self:GetMaterialPrice(outcome.itemID)
        local worth = price and (price * average) or nil

        if index == likely and worth then value = worth end

        lines[index] = {
            itemID = outcome.itemID,
            name = MATERIAL_NAME[outcome.itemID],
            chance = outcome.chance,
            min = outcome.min,
            max = outcome.max,
            average = average,
            price = price,
            -- What this outcome is worth when it is the one you get.
            worth = worth,
            -- The outcome the value is; every other one is a bonus.
            counted = index == likely,
        }
    end

    local breakdown = { outcomes = lines, facts = facts }

    if not value then return nil, nil, breakdown end

    -- Never partial: only the one outcome counts, and it is priced.
    return math.floor(value + 0.5), nil, breakdown
end

--- Is this item an enchanting material a disenchant can give?
function Disenchant:IsMaterial(itemID)
    return MATERIAL_NAME[itemID] ~= nil
end

--- A material's name, whether or not the client has it cached.
function Disenchant:MaterialName(itemID)
    return MATERIAL_NAME[itemID]
end

--- An item's plain name from the saved facts alone, never asking the client:
--- safe to call for every row of a long list. nil when never read.
function Disenchant:KnownName(itemID)
    local known = itemID and Store()[itemID]
    return known and known.n or nil
end

--- An item's plain name, for a list row that colours it by rarity itself.
function Disenchant:ItemName(itemID)
    local known = Store()[itemID]
    if known and known.n then return known.n end

    if Util.HasFunction("C_Item.GetItemInfo") then
        local ok, name = pcall(C_Item.GetItemInfo, itemID)
        if ok and name then return name end
    end

    return MATERIAL_NAME[itemID] or L.Format("item %s", tostring(itemID))
end

--------------------------------------------------------------------------------
-- Lists for the Profit tab and the Prices tab's enchanting materials
--------------------------------------------------------------------------------

--- Does disenchanting beat the alternative? No known alternative counts as
--- yes: a disenchant with a value is then the only number on the table.
local function Beats(value, alternative)
    if not value then return false end
    if not alternative then return true end
    return value > alternative
end

Disenchant._Beats = Beats

--- Every craft this character knows that makes something disenchantable.
--
-- Soulbound crafts are included on purpose: they cannot be sold, which is why
-- the Profit list drops them, and that is exactly when disenchanting is the
-- way to turn one into gold. Their alternative is what a vendor pays.
--
-- @param opts { beatsOnly }
-- @return rows, ranked on what disenchanting makes over the materials
function Disenchant:GetCraftRows(opts)
    opts = opts or {}

    local rows = {}
    -- The materials a disenchant gives still have to be sold, so the profit
    -- here is net of the auction house cut, as it is on the Disenchanting tab.
    local cut = ns.Config and ns.Config:Get("auctionCut") or 0.05

    for recipeID, recipe in pairs(ns.Recipes:GetAll()) do
        local itemID = recipe.outputItemID

        -- Crafts of a profession the character has dropped are left out, as
        -- the Profit tab leaves them out.
        local dropped = ns.Recipes.IsDropped ~= nil and ns.Recipes:IsDropped(recipe)

        if itemID and not dropped and self:IsDisenchantable(itemID) then
            local value, partial, breakdown = self:GetValue(itemID)
            local analysis = ns.Profit:Analyse(recipeID) or {}

            local cost = analysis.cost
            local costEach = cost and cost.priceable and cost.perUnit or nil

            local sells, sellsAt
            if analysis.soulbound then
                sells, sellsAt = Util.GetVendorSellPrice(itemID), "vendor"
            else
                if analysis.unitRevenue then
                    sells = analysis.unitRevenue
                    -- Analyse takes a vendor's price when it pays more than
                    -- the listing, and says so in its basis.
                    sellsAt = analysis.priceBasis == "vendor" and "vendor"
                        or analysis.priceDerived and "estimate" or "auction"
                elseif ns.Profit.ChoosePostPrice then
                    -- Analyse stops before the sale price when a reagent has
                    -- no price, but what the craft sells for does not depend
                    -- on its reagents. Without this the craft showed "no
                    -- price" and counted as worth more disenchanted.
                    local listAt, basis = ns.Profit:ChoosePostPrice(itemID)
                    if listAt then
                        sells, sellsAt = listAt, basis == "derived" and "estimate" or "auction"
                    end
                end

                -- Never under what a vendor pays, as the bags list prices it.
                local vendor = Util.GetVendorSellPrice(itemID)
                if vendor and (not sells or vendor > sells) then
                    sells, sellsAt = vendor, "vendor"
                end
            end

            local net = value and math.floor(value * (1 - cut) + 0.5) or nil
            local gain = (net and costEach) and (net - costEach) or nil

            -- A craft is only worth making to disenchant when what it breaks
            -- into pays for its materials (a player's report, 2026-10-02). A
            -- soulbound craft beat its vendor price and showed as a win while
            -- every one made lost money against what went into it.
            local beatsSale = Beats(value, sells)
            local losesToMaterials = beatsSale and gain ~= nil and gain <= 0

            local row = {
                kind = "craft",
                recipeID = recipeID,
                itemID = itemID,
                name = recipe.name,
                value = value,
                net = net,
                partial = partial,
                breakdown = breakdown,
                cost = costEach,
                sells = sells,
                sellsAt = sellsAt,
                soulbound = analysis.soulbound,
                craftableNow = analysis.craftableNow
                    or (ns.Profit.GetCraftableCount and ns.Profit:GetCraftableCount(recipeID)) or 0,
                gain = gain,
                beatsSale = beatsSale and not losesToMaterials,
                -- Beats selling, but not the cost of the materials.
                losesToMaterials = losesToMaterials or nil,
            }

            if not opts.beatsOnly or row.beatsSale then
                rows[#rows + 1] = row
            end
        end
    end

    -- Best return on the materials first. A craft with no value or no cost
    -- sits below every one that has both.
    table.sort(rows, function(a, b)
        local left, right = a.gain or -math.huge, b.gain or -math.huge
        if left ~= right then return left > right end

        local leftValue, rightValue = a.value or -1, b.value or -1
        if leftValue ~= rightValue then return leftValue > rightValue end

        return (a.name or "") < (b.name or "")
    end)

    return rows
end

--- The bag link of the first copy found of each item in `wanted`.
--
-- Random-suffix gear ("of the Monkey") shares its item ID with every other
-- suffix of the same item, and only the link says which one this is. The
-- upgrade arrow on a row asks with it.
local function BagLinks(wanted)
    local links = {}
    if not next(wanted) or not (ns.Inventory and ns.Inventory.GetCarriedBags)
        or not Util.HasFunction("C_Container.GetContainerItemID")
        or not Util.HasFunction("C_Container.GetContainerItemLink") then
        return links
    end

    -- Read inside a pcall: in an instance the client can hand out values
    -- that raise when they are compared or used as a key. The link is
    -- copied in there too (the `.. ""`), so one the client will not let
    -- addons read raises here rather than wherever the row is drawn.
    local function Read(bag, slot)
        local itemID = C_Container.GetContainerItemID(bag, slot)
        if not itemID or not wanted[itemID] or links[itemID] then return end

        local link = C_Container.GetContainerItemLink(bag, slot)
        if type(link) == "string" then links[itemID] = link .. "" end
    end

    for _, bag in ipairs(ns.Inventory:GetCarriedBags()) do
        local gotSlots, slots = pcall(C_Container.GetContainerNumSlots, bag)
        if gotSlots and type(slots) == "number" then
            for slot = 1, slots do pcall(Read, bag, slot) end
        end
    end

    return links
end

--- Every disenchantable item in the bags.
--
-- Its alternative is selling it: the auction value, or a vendor when it binds
-- on pickup or the vendor pays more. An item that bound when it was equipped
-- looks the same from here, and the tab says so.
--
-- @param opts { beatsOnly }
function Disenchant:GetBagRows(opts)
    opts = opts or {}

    local rows = {}
    local counts = ns.Inventory and ns.Inventory:GetBagCounts() or {}

    -- One link per item, the copy carried: the row's icon is judged as it,
    -- and a random suffix ("of the Monkey") is priced as that suffix sells.
    local wanted = {}
    for itemID in pairs(counts) do
        if self:IsDisenchantable(itemID) then wanted[itemID] = true end
    end
    local links = BagLinks(wanted)

    for itemID, count in pairs(counts) do
        if wanted[itemID] then
            local value, partial, breakdown = self:GetValue(itemID)

            local vendor = Util.GetVendorSellPrice(itemID)
            local bound = Util.IsBoundOnPickup(itemID) == true
            local link = links[itemID]
            local auction
            if not bound then
                if link and ns.Prices.GetLinkValue then
                    auction = ns.Prices:GetLinkValue(link, "market")
                else
                    auction = ns.Prices:GetValue(itemID, "market")
                end
            end
            if auction and auction <= 0 then auction = nil end

            local sells, sellsAt = auction, "auction"
            if not sells or (vendor and vendor > sells) then
                sells, sellsAt = vendor, "vendor"
            end

            local row = {
                kind = "bag",
                itemID = itemID,
                name = Disenchant:ItemName(itemID),
                count = count,
                value = value,
                partial = partial,
                breakdown = breakdown,
                sells = sells,
                sellsAt = sells and sellsAt or nil,
                soulbound = bound,
                gain = (value and sells) and (value - sells) or value,
                beatsSale = Beats(value, sells),
                link = link,
            }

            -- Bought on the auction house to disenchant: no more than carried.
            local buys = ns.DisenchantBuys
            local bought = buys and buys.Count and buys:Count(itemID) or 0
            if bought > 0 then row.bought = math.min(bought, count) end

            if not opts.beatsOnly or row.beatsSale or row.bought then
                rows[#rows + 1] = row
            end
        end
    end

    -- What was bought to disenchant comes first, then the best.
    table.sort(rows, function(a, b)
        if (a.bought ~= nil) ~= (b.bought ~= nil) then return a.bought ~= nil end
        local left, right = a.gain or -math.huge, b.gain or -math.huge
        if left ~= right then return left > right end
        return a.itemID < b.itemID
    end)

    return rows
end

--- Every enchanting material with its price and how many are in the bags.
function Disenchant:GetMaterialRows()
    local rows = {}

    for _, material in ipairs(self.MATERIALS) do
        local itemID = material.itemID

        rows[#rows + 1] = {
            kind = "material",
            itemID = itemID,
            name = material.name,
            materialKind = material.kind,
            price = self:GetMaterialPrice(itemID),
            age = ns.Prices and ns.Prices:GetAge(itemID) or nil,
            stale = ns.Prices and ns.Prices:IsStale(itemID) or nil,
            have = ns.Inventory and ns.Inventory:GetBagCount(itemID) or 0,
        }
    end

    return rows
end

--------------------------------------------------------------------------------
-- Auction house deals, for the Disenchanting tab
--------------------------------------------------------------------------------

--- Is a saved profession entry Enchanting? Recipes knows it by skill line
--- in any client language; the English name stands in without it.
local function IsEnchanting(profession)
    local recipes = ns.Recipes
    if recipes and type(recipes.IsEnchanting) == "function" then
        return recipes.IsEnchanting(profession) == true
    end
    return profession.name == "Enchanting"
end

--- The best Enchanting skill among your characters, and whose it is.
--
-- Read from what each character last recorded, so an alt's enchanter counts
-- without logging in. nil when none of them has Enchanting.
function Disenchant:GetBestEnchanter()
    local best, who

    local characters = ns.db and ns.db.characters
    if type(characters) ~= "table" then return nil end

    for characterKey, record in pairs(characters) do
        for _, profession in ipairs(type(record) == "table" and record.professions or {}) do
            if type(profession) == "table" and IsEnchanting(profession) and profession.learned ~= false then
                local level = profession.skillLevel or 0
                if not best or level > best then
                    best = level
                    who = ns.Recipes and ns.Recipes:GetCharacterName(characterKey) or characterKey
                end
            end
        end
    end

    return best, who
end

--- Weapons and armour only, asked of the instant lookup, which answers
--- without the item being cached. Saves asking the client to load thousands
--- of scanned items that could never be disenchanted.
local function CouldBeGear(itemID)
    local known = gearMemo[itemID]
    if known ~= nil then return known end

    if not Util.HasFunction("C_Item.GetItemInfoInstant") then return true end

    local ok, _, _, _, _, _, classID = pcall(C_Item.GetItemInfoInstant, itemID)
    if not ok or classID == nil then return true end

    -- Asked once a session: an item's class never changes.
    gearMemo[itemID] = classID == CLASS_WEAPON or classID == CLASS_ARMOR
    return gearMemo[itemID]
end

--- What buying one from someone else costs right now: their cheapest
--- listing at the last look. A lone low listing that pricing leaves out is
--- still one you can buy, and the best buy of all, so it counts here.
local function BuyPrice(record)
    local price = record.rivalMin
    if record.ignoredLow and (not price or record.ignoredLow < price) then
        price = record.ignoredLow
    end
    if price and price > 0 then return price end
end

Disenchant._BuyPrice = BuyPrice

--- Can your best enchanter break this? nil when no character has Enchanting.
local function CanDisenchant(skill, needs)
    if skill == nil then return nil end
    return needs == nil or skill >= needs
end

--- Every disenchantable item someone else has on the auction house, with
--- what buying and disenchanting one makes.
--
-- Profit is the disenchant value less the auction house cut you pay when
-- you sell the materials, less the buy price. Margin is that profit over the
-- buy price. Your own listings are left out: buying back your own item is
-- not a deal.
--
-- @param opts { profitableOnly, minProfit, minMargin }
--   profitableOnly keeps rows that clear minProfit (at least 1 copper) and
--   minMargin (a percent); both default to Settings.
-- @return rows best profit first, how many profitable rows were held back
--   by the minimums, and how many listed items are still to be read (none
--   are read while the auction house is open)
--- What GetAuctionRows works out once for every row.
function Disenchant:AuctionContext(opts)
    opts = opts or {}
    local skill, enchanter = self:GetBestEnchanter()
    return {
        profitableOnly = opts.profitableOnly,
        cut = ns.Config and ns.Config:Get("auctionCut") or 0.05,
        minProfit = opts.minProfit or (ns.Config and ns.Config:Get("minProfit")) or 0,
        minMargin = (opts.minMargin or (ns.Config and ns.Config:Get("minMarginPercent")) or 0) / 100,
        skill = skill,
        enchanter = enchanter,
        -- Only what the last scan (or a search since) actually saw. A listing
        -- missing from the last scan has sold or expired, but its record keeps
        -- the old price, so without this it stays listed as a deal for days.
        since = (ns.Prices.GetLastScan and ns.Prices:GetLastScan() or (ns.db and ns.db.lastFullScan)),
    }
end

--- One item's place in the auction list.
-- @return "row" and the row, "hidden" (profitable but under the minimums),
--   "pending" (listed, not read yet), or nil when it is not in the list
function Disenchant:AuctionRow(itemID, record, ctx)
    local buy = type(record) == "table" and BuyPrice(record)
    if buy and ctx.since and (record.seen or 0) < ctx.since then buy = nil end

    local disenchantable = buy and CouldBeGear(itemID) and self:IsDisenchantable(itemID)
    if buy and disenchantable == nil and CouldBeGear(itemID) and not self:GaveUp(itemID) then
        return "pending"
    end
    if not disenchantable then return nil end

    local value, partial, breakdown = self:GetValue(itemID)
    if not value then return nil end

    local facts = breakdown.facts or {}
    local net = math.floor(value * (1 - ctx.cut) + 0.5)
    local gain = net - buy

    local row = {
        kind = "auction",
        itemID = itemID,
        name = self:ItemName(itemID),
        buy = buy,
        loneLow = record.ignoredLow ~= nil and buy == record.ignoredLow or nil,
        listed = record.quantity,
        value = value,
        net = net,
        partial = partial,
        breakdown = breakdown,
        gain = gain,
        margin = gain / buy,
        beatsSale = gain > 0,
        needs = facts.skill,
        enchanter = ctx.enchanter,
        enchanterSkill = ctx.skill,
        -- nil when no character has Enchanting at all.
        canDisenchant = CanDisenchant(ctx.skill, facts.skill),
        age = ns.Prices:GetAge(itemID),
        stale = ns.Prices:IsStale(itemID),
    }

    local clears = gain > 0 and gain >= ctx.minProfit and row.margin >= ctx.minMargin

    if not ctx.profitableOnly or clears then return "row", row end
    if gain > 0 then return "hidden" end
    return nil
end

local function BestFirst(a, b)
    if a.gain ~= b.gain then return a.gain > b.gain end
    return a.itemID < b.itemID
end

--- Every disenchantable item someone else has on the auction house, with
--- what buying and disenchanting one makes.
--
-- Profit is the disenchant value less the auction house cut you pay when
-- you sell the materials, less the buy price. Margin is that profit over the
-- buy price. Your own listings are left out: buying back your own item is
-- not a deal.
--
-- @param opts { profitableOnly, minProfit, minMargin }
--   profitableOnly keeps rows that clear minProfit (at least 1 copper) and
--   minMargin (a percent); both default to Settings.
-- @return rows best profit first, how many profitable rows were held back
--   by the minimums, how many listed items are still to be read (none
--   are read while the auction house is open), and each item's place
--   ([itemID] = "row", "hidden" or "pending"), for PatchAuctionRows
function Disenchant:GetAuctionRows(opts)
    -- Counted for /bts readysell, which says how often this ran.
    self.rowBuilds = (self.rowBuilds or 0) + 1

    local rows, hidden, pending, places = {}, 0, 0, {}
    local prices = ns.Prices and ns.Prices:GetTable() or {}
    local ctx = self:AuctionContext(opts)

    for itemID, record in pairs(prices) do
        local place, row = self:AuctionRow(itemID, record, ctx)
        places[itemID] = place
        if place == "row" then
            rows[#rows + 1] = row
        elseif place == "hidden" then
            hidden = hidden + 1
        elseif place == "pending" then
            pending = pending + 1
        end
    end

    table.sort(rows, BestFirst)

    return rows, hidden, pending, places
end

--- Redo the rows of a few items in a list GetAuctionRows built, in place:
--- a buy or an empty search changes one item, and walking every price again
--- for it is the kind of rebuild the owner's smooth play rule rules out.
-- @param built { rows, hidden, pending, places } as GetAuctionRows gave them
-- @param items { [itemID] = true }
-- @return false, with nothing changed, when a full rebuild is needed: one
--   of the items is a disenchanting material, whose price moves every row
function Disenchant:PatchAuctionRows(built, items, opts)
    for itemID in pairs(items) do
        if self:IsMaterial(itemID) then return false end
    end

    local prices = ns.Prices and ns.Prices:GetTable() or {}
    local ctx = self:AuctionContext(opts)
    local rows, places = built.rows, built.places

    for itemID in pairs(items) do
        local old = places[itemID]
        if old == "hidden" then built.hidden = built.hidden - 1 end
        if old == "pending" then built.pending = built.pending - 1 end
        if old == "row" then
            for i = #rows, 1, -1 do
                if rows[i].itemID == itemID then table.remove(rows, i) end
            end
        end

        local place, row = self:AuctionRow(itemID, prices[itemID], ctx)
        places[itemID] = place
        if place == "hidden" then built.hidden = built.hidden + 1 end
        if place == "pending" then built.pending = built.pending + 1 end
        if place == "row" then
            -- Into its place, best profit first, as the full build sorts.
            local at = #rows + 1
            for i = 1, #rows do
                if BestFirst(row, rows[i]) then at = i break end
            end
            table.insert(rows, at, row)
        end
    end

    self.rowPatches = (self.rowPatches or 0) + 1
    return true
end

--- After a scan: say how many deals it found and the best one, with a chime
--- when there is at least one worth having. Quiet when there are none.
function Disenchant:AnnounceDeals()
    local ok, all = pcall(self.GetAuctionRows, self, { profitableOnly = true })
    if not ok or type(all) ~= "table" then return 0 end

    -- Only deals one of your characters can break at their Enchanting skill
    -- today. The tab still lists the rest, marked; the message is what says
    -- "go and buy", so it leaves them out. With no enchanter known at all,
    -- canDisenchant is nil and every deal counts, as before.
    local rows = {}
    for _, row in ipairs(all) do
        if row.canDisenchant ~= false then rows[#rows + 1] = row end
    end
    if #rows == 0 then return 0 end

    local best = rows[1]
    local total = 0
    for _, row in ipairs(rows) do total = total + row.gain end

    ns.Print(L.Format("Disenchant deals: %d on the auction house, worth %s together. The best is %s for %s, which makes %s. See the Disenchanting tab.",
        #rows, Util.FormatMoney(total, { noColor = true }),
        Util.GetItemLabel(best.itemID), Util.FormatMoney(best.buy, { noColor = true }),
        Util.FormatMoney(best.gain, { noColor = true })))

    -- Settings: Sound when a scan finishes.
    if (not ns.Config or ns.Config:Get("scanSounds") ~= false) and type(PlaySound) == "function" then
        local kits = type(_G.SOUNDKIT) == "table" and _G.SOUNDKIT or {}
        if kits.UI_EPICLOOT_TOAST then pcall(ns.PlaySound or PlaySound, kits.UI_EPICLOOT_TOAST, "Master") end
    end

    return #rows
end

--------------------------------------------------------------------------------
-- Command
--------------------------------------------------------------------------------

--- /bts de <item link or ID>: what the addon thinks an item disenchants into.
local function Report(input)
    local itemID = tonumber((input or ""):match("item:(%d+)") or (input or ""):match("(%d+)"))

    if not itemID then
        ns.Print(L["usage: /bts de <item link or item ID>"])
        return
    end

    local disenchantable = Disenchant:IsDisenchantable(itemID)

    if disenchantable == nil then
        ns.Print(L.Format("the game hasn't loaded %s yet, try again in a moment", Util.GetItemLabel(itemID)))
        return
    elseif not disenchantable then
        ns.Print(L.Format("%s cannot be disenchanted", Util.GetItemLabel(itemID)))
        return
    end

    local value, partial, breakdown = Disenchant:GetValue(itemID)
    local facts = breakdown and breakdown.facts or {}

    ns.Print(L.Format(facts.isWeapon and L["%s: item level %d, %s weapon, needs Enchanting about %d"]
            or L["%s: item level %d, %s armor, needs Enchanting about %d"],
        Util.GetItemLabel(itemID), facts.itemLevel or 0, QUALITY_WORDS[facts.qualityName] or facts.qualityName or "?",
        facts.skill or 0))

    if facts.source == "yours" then
        ns.Print(L.Format("  from %s", Disenchant:YoursPhrase(facts)))
    else
        ns.Print(L.Format("  from the built-in table (you've done %d, and your own results take over at %d)",
            facts.casts or 0, Disenchant.LEARN_AFTER))
    end

    for _, line in ipairs(breakdown and breakdown.outcomes or {}) do
        local count = line.min == line.max and tostring(line.min)
            or ("%d-%d"):format(line.min, line.max)

        ns.Print(("  %s%%  %sx %s  %s%s"):format(
            Util.Round(line.chance * 100, 1), count, Util.ColorItemName(line.itemID, line.name) or Util.GetItemLabel(line.itemID),
            line.price and L.Format("%s each", Util.FormatMoney(line.price, { noColor = true })) or L["no price"],
            line.counted and "" or L["  (bonus)"]))
    end

    if value then
        ns.Print(L.Format(partial and L["disenchant value %s (some materials have no price yet)"] or L["disenchant value %s"],
            Util.FormatMoney(value, { noColor = true })))
    else
        ns.Print(L["disenchant value unknown, since the most likely material hasn't been scanned yet"])
    end
end

Disenchant._Report = Report

ns.RegisterCommand("de", L["<item link or ID>: what an item disenchants into and its value"], Report)

--------------------------------------------------------------------------------
-- /bts dedeals: why each disenchant deal is on the Disenchanting tab
--------------------------------------------------------------------------------

local function Ago(stamp)
    if not stamp then return "never" end
    return Util.FormatAgeAgo(math.max(0, time() - stamp))
end

ns.RegisterCommand("dedeals", L["say why each disenchant deal on the Disenchanting tab is there"], function()
    local lastScan = (ns.Prices.GetLastScan and ns.Prices:GetLastScan() or (ns.db and ns.db.lastFullScan))
    ns.Print(("dedeals: last scan %s, price records changed %d time(s) since /reload")
        :format(Ago(lastScan), ns.Prices and ns.Prices.changes or 0))

    local shown = Disenchant.shownRows
    if shown then
        ns.Print(("dedeals: the tab's list was built %s, %d row(s)")
            :format(Ago(Disenchant.shownBuiltAt), #shown))
    else
        ns.Print("dedeals: the tab has not built its list since /reload (open the Disenchanting tab)")
    end

    local fresh = Disenchant:GetAuctionRows({ profitableOnly = true })
    ns.Print(("dedeals: built fresh now it would have %d deal(s)"):format(#fresh))

    local prices = ns.Prices and ns.Prices:GetTable() or {}
    for index, row in ipairs(shown or fresh) do
        if index > 5 then break end
        local record = prices[row.itemID] or {}
        ns.Print(("dedeals: %s (%d): buy %s, last seen %s%s, cheapest other seller %s, lone low %s, yours %s")
            :format(row.name or "?", row.itemID,
                Util.FormatMoney(row.buy, { noColor = true }),
                Ago(record.seen),
                (lastScan and record.seen and record.seen < lastScan) and " (NOT in the last scan)" or "",
                record.rivalMin and Util.FormatMoney(record.rivalMin, { noColor = true }) or "none",
                record.ignoredLow and Util.FormatMoney(record.ignoredLow, { noColor = true }) or "none",
                record.ownMin and Util.FormatMoney(record.ownMin, { noColor = true }) or "none"))
    end
end)
