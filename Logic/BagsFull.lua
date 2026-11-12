-- Blackthornes Tradeskills -- Logic/BagsFull.lua
-- A warning the moment your bags fill up.
--
-- Asked for by a player (2026-10-02) for long crafting and
-- disenchanting runs, where the game stops the run quietly when there is
-- nowhere to put the next item. Only the ordinary bags count: a full herb
-- bag still leaves room for everything else. The warning sounds when the
-- last free slot goes, not while the bags stay full, and never at login.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local BagsFull = ns.NewModule("BagsFull")

-- ALARM_CLOCK_WARNING_2: short and plain, unlike the sale alarm's raid
-- warning. Read from the game's own table when it has one.
local WARNING_SOUND = 12867

--- Free slots in the ordinary bags, or nil when the game will not say.
function BagsFull:CountFree()
    if not (C_Container and C_Container.GetContainerNumFreeSlots) then return nil end

    local free, read = 0, false
    for _, bag in ipairs(ns.Inventory:GetCarriedBags()) do
        local ok, slots, family = pcall(C_Container.GetContainerNumFreeSlots, bag)
        if ok and type(slots) == "number" and (family == nil or family == 0) then
            free = free + slots
            read = true
        end
    end

    return read and free or nil
end

function BagsFull:Check()
    local free = self:CountFree()
    if free == nil then return end

    local before = self.lastFree
    self.lastFree = free

    if before and before > 0 and free == 0 then
        self:Warn()
    end
end

function BagsFull:Warn()
    ns.Print(L["your bags are full"])

    -- Settings: SOUNDS, Bags are full.
    if ns.Config:Get("bagsFullSound") == false or type(PlaySound) ~= "function" then return end

    local kits = type(_G.SOUNDKIT) == "table" and _G.SOUNDKIT or {}
    pcall(ns.PlaySound or PlaySound, kits.ALARM_CLOCK_WARNING_2 or WARNING_SOUND, "Master")
end

function BagsFull:OnEnable()
    ns.RegisterEvent(self, "BAG_UPDATE_DELAYED", function() self:Check() end)
    ns.RegisterEvent(self, "PLAYER_ENTERING_WORLD", function()
        -- A fresh reading, so bags already full at login stay quiet.
        self.lastFree = nil
        self:Check()
    end)
end

--------------------------------------------------------------------------------
-- Batches that fit the bags
--------------------------------------------------------------------------------
--
-- Asked for by a player (2026-10-05) for big vendor and disenchant
-- shuffles: a thousand wands is a thousand wood and a thousand essence, about
-- 150 slots, and the bags hold 30. Buying it all at once filled the bags and
-- the game quietly refused the rest. So the Buy materials button, and the
-- mailbox's Take next batch, bring only what fits, in step: the same share of
-- every material the queue needs, so what arrives makes whole crafts.

-- Slots left free by default: room for the crafts, the odd drop, a new quest
-- item.
local DEFAULT_SPARE = 5

--- Bag slots kept free by a batch.
function BagsFull:GetSpare()
    local spare = ns.Config and tonumber(ns.Config:Get("bagSpareSlots"))
    if not spare then return DEFAULT_SPARE end
    return math.max(0, math.floor(spare))
end

--- Slots a batch may fill, and the free slots it counted from, or nil when
--- the game will not say.
function BagsFull:Room()
    local free = self:CountFree()
    if free == nil then return nil end
    return math.max(0, free - self:GetSpare()), free
end

--- How many of an item one bag slot holds. 1 when the game does not say, so
--- a batch is too small rather than too big.
function BagsFull.MaxStack(itemID)
    -- The retail call is GetItemMaxStackSizeByID; it was asked for under a
    -- name the client does not have, so every batch was sized as if nothing
    -- stacked. The kept item-info read (Posting uses the same two) comes
    -- first, since a scan has usually filled it already.
    local util = ns.Util
    if util and type(util.GetMaxStackSize) == "function" then
        local ok, stack = pcall(util.GetMaxStackSize, itemID)
        if ok and type(stack) == "number" and stack >= 1 then return stack end
    end
    if C_Item and type(C_Item.GetItemMaxStackSizeByID) == "function" then
        local ok, stack = pcall(C_Item.GetItemMaxStackSizeByID, itemID)
        if ok and type(stack) == "number" and stack >= 1 then return stack end
    end
    if type(GetItemInfo) == "function" then
        local ok, _, _, _, _, _, _, _, stack = pcall(GetItemInfo, itemID)
        if ok and type(stack) == "number" and stack >= 1 then return stack end
    end
    return 1
end

--- The new slots `amount` more of an item takes, once the part stack already
--- in the bags is topped up.
function BagsFull.SlotsFor(itemID, amount, inBags)
    if not amount or amount <= 0 then return 0 end
    local stack = BagsFull.MaxStack(itemID)
    local have = tonumber(inBags) or 0
    local topUp = 0
    if have > 0 and have % stack ~= 0 then topUp = stack - have % stack end
    return math.ceil(math.max(0, amount - topUp) / stack)
end

--- How much of the share `share` (0 to 1) of what the queue needs is still to
--- come into the bags.
local function Bring(line, share)
    local needed = tonumber(line.needed) or 0
    local inBags = tonumber(line.inBags) or 0
    -- The small amount taken off keeps 0.14 * 1000 at 140, not 141.
    local target = math.min(needed, math.ceil(needed * share - 1e-9))
    return math.max(0, target - inBags)
end

local function SlotsAt(list, share)
    local slots = 0
    for _, line in ipairs(list) do
        slots = slots + BagsFull.SlotsFor(line.itemID, Bring(line, share), line.inBags)
    end
    return slots
end

--- The next batch for a shopping list (Queue:GetShoppingList's lines).
--
-- Every material in the list counts toward the room, wherever it comes from:
-- at a vendor, room is kept for what is still to come from the mailbox or the
-- auction house, so the wood bought matches the essence that will join it.
--
-- @param room slots the batch may fill (see Room)
-- @return { share = 0..1 (1: all of it fits), bring = { [itemID] = units },
--           batches = about how many batches the rest of the queue takes }
function BagsFull:PlanBatch(list, room)
    room = math.max(0, tonumber(room) or 0)
    local all = SlotsAt(list, 1)

    local share = 1
    if all > room then
        -- The most the room takes. Bring only grows with the share, so a
        -- halving search finds it.
        local low, high = 0, 1
        for _ = 1, 40 do
            local middle = (low + high) / 2
            if SlotsAt(list, middle) <= room then low = middle else high = middle end
        end
        share = low
    end

    local bring = {}
    for _, line in ipairs(list) do
        bring[line.itemID] = Bring(line, share)
    end

    local batches = 1
    if all > room then
        batches = room > 0 and math.ceil(all / room) or math.huge
    end

    return { share = share, bring = bring, batches = batches, slots = all }
end
