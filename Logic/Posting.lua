-- Blackthornes Tradeskills -- Logic/Posting.lua
-- What to sell, at what price, and listing it.
--
-- Posting is the one part of the addon that can lose gold outright, so it is
-- deliberately the least automatic: one click per listing, the price on the
-- button before it is pressed, and a refusal to list below material cost
-- unless you allow it.
--
-- Success is verified against your actual auctions rather than assumed from
-- an event, because AUCTION_HOUSE_AUCTION_CREATED fires for anything -- a
-- listing you made by hand included -- and claiming credit for that is worse
-- than reporting nothing. The Post tab also shows the price split into
-- Blizzard's gold/silver/copper boxes, so listing by hand stays easy when the
-- auction house is misbehaving.

local _, ns = ...

local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Posting = ns.NewModule("Posting")

local Util = ns.Util


-- How long to wait before asking the server what actually got listed. The
-- auction house is throttled and the reply can lag several seconds, so asking
-- immediately reads the state from before the listing.
local POST_VERIFY_DELAY = 3

-- How long a remembered deposit is served without asking the client again.
-- Short enough that changing the listing length is felt immediately -- that is
-- keyed separately anyway -- and long enough that a list rebuilding once a
-- second asks once rather than sixty times.
local DEPOSIT_CACHE_SECONDS = 30

-- How long a listing may stay unverified before we admit we do not know. Longer
-- than the request's own wait in the queue plus the reads that follow it.
local VERIFY_GIVE_UP = 15

-- How many different items may be waiting to be confirmed at once. Each is
-- told apart by its item ID, so they need not wait for each other (the owner,
-- 2026-10-13: the five seconds between listings); this only keeps a burst of
-- clicks from piling up more checks than the auction house can answer. Six
-- since fast listing (2026-10-14): listings close together share one read
-- back (VERIFY_SHARE), so more of them cost no more requests.
local MAX_CONFIRMING = 6
Posting.MAX_CONFIRMING = MAX_CONFIRMING

-- A listing's read back waits for a newer listing's when that one is due
-- this soon, so a run of quick listings is confirmed by one read rather than
-- one each. Never later than VERIFY_SHARE_MOST past its own time, so a long
-- run still gets read.
local VERIFY_SHARE = 1.6
local VERIFY_SHARE_MOST = 3

-- Fast listing (the owner, 2026-10-14: players asked for posting quicker
-- than five seconds a listing). A price checked this recently lists on the
-- click itself, with no Yes/No box: the click is the real one the game
-- wants. Older, it is checked again first.
local FRESH_FOR = 120
Posting.FRESH_FOR = FRESH_FOR

-- One search for the whole Sell list asks about this many items at most.
local CHECK_ALL_MOST = 50

-- How long the answer to that search is waited for.
local CHECK_ALL_WAIT = 8

-- A cheapest listing under this share of market value may be a lone one far
-- below the rest, which only a search for that one item can tell (it reads
-- the whole book). Such an item is left to that search.
local CHECK_ALL_FAR_UNDER = 0.5

-- Confirmed against Blizzard's own Sell tab on Forever, which offers 2, 8 and
-- 24 hours: this is a Classic auction house, not retail's 12/24/48. The choice
-- is the length every listing goes up for, and sets its deposit.
local DURATIONS = {
    { text = L["2 hours"], value = 1 },
    { text = L["8 hours"], value = 2 },
    { text = L["24 hours"], value = 3 },
}

Posting.DURATIONS = DURATIONS

--- How long an item goes up for: its list's Post For (Logic/ListRules.lua),
--- else the length picked in the drawer and on the Post tab.
function Posting:DurationFor(itemID)
    if ns.ListRules then
        local ok, duration = pcall(ns.ListRules.Duration, ns.ListRules, itemID)
        if ok and tonumber(duration) then return duration end
    end
    return ns.Config:Get("postDuration") or 2
end

--------------------------------------------------------------------------------
-- Capability
--------------------------------------------------------------------------------

--- True once this client has been *seen* refusing an addon-created auction.
--
-- Deliberately not inferred from issecurevariable: that reports whether a
-- variable is untainted, which is true of nearly every Blizzard function an
-- addon has not overwritten, and says nothing about whether calling it is
-- allowed. Reading it as proof of protection was a mistake that removed a
-- working feature.
function Posting:IsBlocked()
    return self.blocked == true
end

--- Record that the client refused an auction started from addon code.
function Posting:MarkBlocked()
    if self.blocked then return end

    self.blocked = true
    ns.Warn(L["the game will not let addons list auctions."])
    ns.Warn(L["Ready to sell still shows what to list and at what price."])

    if ns.UI then ns.UI:RefreshActiveTab() end
end

--- Whether a listing can be attempted right now, and why not when it cannot.
-- @param itemID optional: the item about to be listed. Another copy of the
--   item still being confirmed can go straight away (see Post).
function Posting:CanPost(itemID)
    if self:IsBlocked() then
        return false, L["the game will not let addons list auctions"]
    end

    if not ns.Scanner.isAuctionHouseOpen then
        return false, L["the auction house must be open"]
    end

    if ns.Scanner.isScanning then
        return false, L["wait for the scan to finish"]
    end

    -- Restored as a real gate. It was demoted to advisory to unstick a button
    -- that never re-checked it, and the cost of that was our own traffic
    -- pushing the auction house into "You're doing that too fast" -- which
    -- blocks the player's own manual listings, not just ours. The one-second
    -- ticker now re-checks this, so a refusal here clears on its own.
    if self:IsThrottled() then
        return false, L["the auction house is busy, try again in a moment"]
    end

    -- Only one listing is in flight at a time, because a second one started
    -- before the first is confirmed cannot be told apart from it when the
    -- owned auctions are read back.
    --
    -- This gate used to live in Post alone, which is the last step. So a click
    -- spent a live price check and put up a confirmation dialog, and only after
    -- the player clicked that did anything mention the listing still settling.
    -- Refusing here means the buttons know, and SecondsUntilPostable can count
    -- it down instead of the player discovering it at the end.
    --
    -- Another copy of the same item is the exception (2026-10-04: "post
    -- them one at a time, just like the Blizzard AH UI does", not five seconds
    -- apart). Its listing joins the one being confirmed and both are counted
    -- together, so nothing has to be told apart.
    --
    -- And a different item no longer waits either (2026-10-13): each listing
    -- is confirmed by its own item ID, so several can be checked at once. Only
    -- a pile of them waits, so the checks never outrun the auction house.
    if self:ConfirmingFull(itemID) then
        return false, L["still confirming the last listing"]
    end

    return true
end

--- How long until the next listing can be attempted, and why it is waiting.
--
-- Posting from a click runs at urgent priority, which is deliberately exempt
-- from the stand-down that keeps background scans out of the player's way. So
-- the wait between two of the player's own posts is the pacing gap and the
-- rolling budget, not the six second courtesy -- asking the queue at the wrong
-- priority here would report a wait the player never actually serves.
--
-- Refusals that are not waits (no auction house, a client that will not take
-- addon auctions) return nothing, because they have their own wording already
-- and a countdown would imply they clear on their own.
--
-- @param itemID optional: the item about to be listed. Another copy of the
--   item being confirmed does not wait for it (see CanPost).
-- @return seconds, reason
function Posting:SecondsUntilPostable(itemID)
    if self:IsBlocked() then return 0, nil end
    if not ns.Scanner.isAuctionHouseOpen then return 0, nil end

    if ns.Scanner.isScanning then
        return 0, L["waiting for the scan to finish"]
    end

    local seconds, reason =
        ns.AHQueue:SecondsUntilReady(ns.AHQueue.PRIORITY.urgent)

    -- A fresh price lists on the click with no search, so the spacing kept
    -- between our own requests is not a wait this click serves. Counting it
    -- down after each listing read as "wait" on a button that would list.
    if self:FastListing() and (itemID == nil or self:IsFresh(itemID))
            and not (ns.AHQueue.backoffUntil and GetTime() < ns.AHQueue.backoffUntil) then
        seconds, reason = 0, nil
    end

    -- Listings still being confirmed no longer hold the next one back (each
    -- is told apart by its item), so the wait is the auction house's own
    -- spacing above. Only a pile of them waits, until the oldest settles,
    -- which is not a length that can honestly be named.
    if self:ConfirmingFull(itemID) then
        reason = L["still confirming the last listing"]
    end

    -- CanPost gates on this separately, so a countdown that ignored it would
    -- run to zero and leave the button still refusing.
    if self:IsThrottled() then
        reason = reason or L["the auction house is busy"]
    end

    return seconds, reason
end

--- The listing of this item still being confirmed, if any.
--
-- `pending` is the newest listing; older ones of other items wait in
-- `others`, by item ID, until their own check settles them.
function Posting:PendingFor(itemID)
    if itemID == nil then return nil end
    if self.pending and self.pending.itemID == itemID then return self.pending end
    local others = rawget(self, "others")
    return type(others) == "table" and others[itemID] or nil
end

--- Every listing still being confirmed, newest last.
function Posting:AllPending()
    local list = {}
    local others = rawget(self, "others")
    if type(others) == "table" then
        for _, pending in pairs(others) do
            if pending ~= self.pending then list[#list + 1] = pending end
        end
        table.sort(list, function(a, b) return (a.startedAt or 0) < (b.startedAt or 0) end)
    end
    if self.pending then list[#list + 1] = self.pending end
    return list
end

--- Is this listing still one being confirmed (not settled, not joined)?
function Posting:IsPending(pending)
    if not pending then return false end
    if self.pending == pending then return true end
    local others = rawget(self, "others")
    return type(others) == "table" and others[pending.itemID] == pending
end

--- Settle one listing: it is no longer waited on. The newest of the others
--- takes its place as `pending`, so whatever reads that still sees one.
function Posting:DropPending(pending)
    if not pending then return end
    local others = rawget(self, "others")
    if type(others) == "table" and others[pending.itemID] == pending then
        others[pending.itemID] = nil
    end
    if self.pending == pending then
        self.pending = nil
        if type(others) == "table" then
            local newest
            for _, other in pairs(others) do
                if not newest or (other.startedAt or 0) > (newest.startedAt or 0) then newest = other end
            end
            if newest then
                others[newest.itemID] = nil
                self.pending = newest
            end
        end
    end
end

--- Are so many other items being confirmed that this one should wait?
function Posting:ConfirmingFull(itemID)
    local count = 0
    for _, pending in ipairs(self:AllPending()) do
        if not (itemID and pending.itemID == itemID) then count = count + 1 end
    end
    return count >= MAX_CONFIRMING
end

--- Is the auction house still catching up?
--
-- Advisory, not a block. A request sent while throttled can be dropped
-- silently, but this client can sit unready for a long time, and refusing to
-- even try leaves a button that never works and never says why. The listing
-- is verified against the server afterwards either way, so a dropped one is
-- reported rather than assumed successful.
function Posting:IsThrottled()
    if not Util.HasFunction("C_AuctionHouse.IsThrottledMessageSystemReady") then
        return false
    end

    local ok, ready = pcall(C_AuctionHouse.IsThrottledMessageSystemReady)
    return ok and not ready
end

--- Whether live prices and deposits are available, and why not when they are not.
function Posting:CanPrice()
    if not ns.Scanner.isAuctionHouseOpen then
        return false, L["open the auction house for deposits and live prices"]
    end
    return true
end

--------------------------------------------------------------------------------
-- Finding stock
--------------------------------------------------------------------------------

-- Era's auction slot (2026-10-25, the owner saw "Internal auction error"):
-- a stack put in the auction slot and listed in the same click is refused,
-- since the server has not taken the stack into the slot yet. So the next
-- stack goes in ahead of the click (Posting:PrepareNext), and a click lists
-- only what the slot already holds. While it sits there its bag slot is
-- locked; that one slot still counts as the item's.
local held   -- { itemID, bag, slot, at, ready }
local HELD_SETTLE = 1   -- seconds before a stack put in counts as taken

--- The auction slot's item: its name and item ID (nil when the client
--- does not say), or nil when it is empty.
local function SellSlotItem()
    if type(_G.GetAuctionSellItemInfo) ~= "function" then return nil end
    local ok, name, _, _, _, _, _, _, _, _, id = pcall(GetAuctionSellItemInfo)
    if not ok or not name then return nil end
    return name, tonumber(id)
end

--- Whether the auction slot holds this item.
local function SellSlotHolds(itemID)
    local name, id = SellSlotItem()
    if not name then return false end
    if id then return id == itemID end
    local getInfo = (type(C_Item) == "table" and C_Item.GetItemInfo) or _G.GetItemInfo
    if type(getInfo) ~= "function" then return false end
    local ok, wanted = pcall(getInfo, itemID)
    return ok and wanted ~= nil and wanted == name
end

--- The bag slot whose stack sits in the auction slot, for this item.
local function HeldSlot(itemID)
    if not held or held.itemID ~= itemID or not SellSlotHolds(itemID) then return nil end
    return held.bag, held.slot
end

--- Is the copy in this bag slot soulbound? A bound copy can never be
--- auctioned, whatever the item's bind type says: a green that binds when
--- equipped is bound once worn, and Era has no IsSellItemValid to say so.
--- The slot's own info first, else C_Item.IsBound; unknown reads as free.
local function SlotBound(info, bag, slot)
    if type(info) == "table" and info.isBound ~= nil then return info.isBound == true end
    if type(_G.ItemLocation) ~= "table" or type(C_Item) ~= "table"
            or type(C_Item.IsBound) ~= "function" then
        return false
    end
    local ok, bound = pcall(function()
        return C_Item.IsBound(ItemLocation:CreateFromBagAndSlot(bag, slot))
    end)
    return ok and bound == true
end
Posting.SlotBound = SlotBound

--- How many of an item the bags hold that are not soulbound.
local function FreeCount(itemID)
    local total = 0
    for _, bag in ipairs(ns.Inventory:GetCarriedBags()) do
        local slotsOk, slots = pcall(C_Container.GetContainerNumSlots, bag)
        if slotsOk and slots then
            for slot = 1, slots do
                local infoOk, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
                if infoOk and info and info.itemID == itemID and not SlotBound(info, bag, slot) then
                    total = total + (info.stackCount or 1)
                end
            end
        end
    end
    return total
end

--- Bag slot holding an item, skipping locked and soulbound slots.
-- @return bag, slot, stackCount
local function FindInBags(itemID)
    -- Era: the stack already waiting in the auction slot comes first. Its
    -- bag slot is locked, so walking the bags would find another copy
    -- (two pairs of boots), put that one in, send this one back, and the
    -- next click would swap them again, never listing either.
    local heldBag, heldSlot = HeldSlot(itemID)
    if heldBag then
        local infoOk, info = pcall(C_Container.GetContainerItemInfo, heldBag, heldSlot)
        if infoOk and info and info.itemID == itemID and not SlotBound(info, heldBag, heldSlot) then
            return heldBag, heldSlot, info.stackCount or 1
        end
    end

    -- Inventory owns the list of containers the character is carrying, reagent
    -- bag included. Keeping a second list here is how the sell list came to
    -- offer a different set of items than the counts said you had.
    for _, bag in ipairs(ns.Inventory:GetCarriedBags()) do
        local slotsOk, slots = pcall(C_Container.GetContainerNumSlots, bag)

        if slotsOk and slots then
            for slot = 1, slots do
                local infoOk, info = pcall(C_Container.GetContainerItemInfo, bag, slot)

                if infoOk and info and info.itemID == itemID and not info.isLocked
                        and not SlotBound(info, bag, slot) then
                    return bag, slot, info.stackCount or 1
                end
            end
        end
    end
end

--- Everything the character is carrying, from one walk of the bags.
--
-- GetPostable used to ask FindInBags about every item it considered, and
-- FindInBags walks every bag from the beginning. On crafted stock that was a
-- handful of walks. Offering the whole bag makes it one walk per distinct
-- item, three times a second while the auction house is open, so the list is
-- built from a single pass instead.
--
-- @return order  the itemIDs found, in bag order
-- @return slots  { [itemID] = { bag, slot, stackCount } } naming the first
--   unlocked slot holding each -- the slot a listing is actually made from.
--   An item held only in locked slots gets an entry with no bag, which reads
--   the same as FindInBags finding nothing: it cannot be listed right now.
local function IndexBags()
    local order, slots = {}, {}
    local heldBag, heldSlot
    if held then heldBag, heldSlot = HeldSlot(held.itemID) end

    for _, bag in ipairs(ns.Inventory:GetCarriedBags()) do
        local slotsOk, count = pcall(C_Container.GetContainerNumSlots, bag)

        if slotsOk and count then
            for slot = 1, count do
                local infoOk, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
                local itemID = infoOk and info and info.itemID

                if itemID then
                    local entry = slots[itemID]

                    if not entry then
                        entry = {}
                        slots[itemID] = entry
                        order[#order + 1] = itemID
                    end

                    -- The stack in the auction slot is the one listed, so
                    -- it wins over a copy found earlier in the bags.
                    local isHeld = bag == heldBag and slot == heldSlot
                    -- A soulbound copy is never listed, so it never names
                    -- the slot or counts toward what can be posted.
                    local bound = SlotBound(info, bag, slot)
                    if not bound then
                        entry.free = (entry.free or 0) + (info.stackCount or 1)
                    end
                    local usable = (not info.isLocked or isHeld) and not bound
                    if usable and (not entry.bag or (isHeld and not entry.inSellSlot)) then
                        entry.inSellSlot = isHeld or nil
                        entry.bag, entry.slot = bag, slot
                        entry.stackCount = info.stackCount or 1
                        -- The copy that will be listed, so a random suffix
                        -- item shows as "Lead Band of the Wolf", not "Lead
                        -- Band". Read inside the pcall'd info above.
                        entry.link = info.hyperlink
                    end
                    if entry.quality == nil then
                        entry.quality = tonumber(info.quality)
                    end
                end
            end
        end
    end

    return order, slots
end

-- Poor quality (grey) items only ever go to a vendor: the house rule prices
-- them at vendor only, and Butler says "vendor only" for them, so no list
-- here offers to post one. The bag slot's own quality first, else the
-- client's answer for the item.
local POOR = (Enum and Enum.ItemQuality and Enum.ItemQuality.Poor) or 0

local function IsGrey(itemID, held)
    local quality = held and held.quality
    if quality == nil and type(C_Item) == "table" and type(C_Item.GetItemQualityByID) == "function" then
        local ok, value = pcall(C_Item.GetItemQualityByID, itemID)
        quality = ok and tonumber(value) or nil
    end
    local getInfo = (type(C_Item) == "table" and C_Item.GetItemInfo) or _G.GetItemInfo
    if quality == nil and type(getInfo) == "function" then
        local ok, _, _, value = pcall(getInfo, itemID)
        quality = ok and tonumber(value) or nil
    end
    return quality == POOR
end

--- A validated ItemLocation for a bag slot, or nil.
--
-- IsValid matters: a location built from a slot that has since changed still
-- looks like an object but points at nothing, and the client does float maths
-- on these in CalculateItemDeposit and IsSellItemValid.
local function MakeLocation(bag, slot)
    if type(_G.ItemLocation) ~= "table" then return nil end

    local ok, location = pcall(ItemLocation.CreateFromBagAndSlot, ItemLocation, bag, slot)
    if not ok or not location then return nil end

    local validOk, valid = pcall(location.IsValid, location)
    if not validOk or not valid then return nil end

    return location
end

--- The auction house's key for the copy of an item that would be listed,
--- when it has a random suffix; nil otherwise.
--
-- A search by item ID alone names no suffix, and for "Lead Band of the Wolf"
-- that search did not come back with the Wolf listings at 40s, so the price
-- fell back to an average across every Lead Band: 80s (kronosbest's report,
-- 2026-10-02). The key the client gives the bag copy names its suffix, so the
-- check undercuts that suffix's own listings. Items with no suffix keep the
-- search they had.
function Posting:GetSearchKey(itemID)
    if not (C_AuctionHouse and C_AuctionHouse.GetItemKeyFromItem) then return nil end

    local bag, slot = FindInBags(itemID)
    if not bag then return nil end

    local linkOk, link = pcall(C_Container.GetContainerItemLink, bag, slot)
    if not linkOk or not Util.LinkSuffix(link) then return nil end

    local location = MakeLocation(bag, slot)
    if not location then return nil end

    local ok, key = pcall(C_AuctionHouse.GetItemKeyFromItem, location)
    if not ok or type(key) ~= "table" or key.itemID ~= itemID then return nil end

    ns.Debug(("searching %s by its suffix (%s)"):format(link, tostring(key.itemSuffix)))
    return key
end

-- Enum.ItemBind values meaning a copy sitting in a bag is already soulbound:
-- 1 binds on being picked up, 4 is a quest item. Written out rather than read
-- from Enum.ItemBind, because this client's Enum tables have been patchy and
-- a nil lookup here would hide sellable stock instead of junk.
local BOUND_ON_PICKUP = { [1] = true, [4] = true }

--- Does this item bind on pickup, so the copy in the bags cannot be auctioned?
--
-- Only consulted when C_AuctionHouse.IsSellItemValid is missing. That call is
-- the real answer; this is a guess, and it exists because the Post tab now
-- offers the whole bag -- without it, a client lacking that function would
-- list every hearthstone and quest item as something to sell.
--
-- Unknown reads as not bound, so an item the client has not cached yet is
-- offered rather than quietly missing from the list.
local function LooksBound(itemID)
    if not Util.HasFunction("C_Item.GetItemInfo") then return false end

    -- bindType is the fourteenth return.
    local ok, _, _, _, _, _, _, _, _, _, _, _, _, _, bindType =
        pcall(C_Item.GetItemInfo, itemID)

    if not ok or type(bindType) ~= "number" then return false end

    return BOUND_ON_PICKUP[bindType] == true
end

--- Can this item be auctioned at all, and how many of it?
--
-- Several copies of an item that does not stack, in one listing click
--------------------------------------------------------------------------------

-- Asked 2026-10-04: Mana Oils do not stack, so each went up on its own
-- click, with the wait for the last one to be confirmed in between. The
-- auction house's item listing takes a quantity: for an item that does not
-- stack it puts up that many separate auctions, one per copy, which is what
-- Blizzard's own Sell tab does with its quantity box. So one click lists
-- them all, still one listing click and one Yes from the player.
--
-- Only for items that cannot stack and have no random suffix: copies of
-- "Lead Band" with different suffixes are different items to a buyer, and a
-- stackable item auction still draws from the one slot it names.
--
-- When a batch of an item comes back with only one listed (or none), that
-- item goes back to one at a time for the rest of the session.
--
-- Reported 2026-10-04: "multiposting works sometimes for crafted items and
-- other times it does not". One doubtful reading used to turn this off for
-- every item until the next login, and the first listing of a visit is
-- measured against a count from the last visit, so a sale in between made a
-- full batch read as one. Now only a reading that can tell new auctions
-- apart counts, and only against the item it was about.
Posting.manyRefused = {}

--- Can this item's copies not stack? Item info that has not loaded yet
--- answers nothing, so the client's own stack size call is asked too.
local function MaxStack(itemID)
    local maxStack = Util.GetMaxStackSize(itemID)
    if maxStack then return maxStack end

    local api = _G.C_Item
    if type(api) == "table" and type(api.GetItemMaxStackSizeByID) == "function" then
        local ok, value = pcall(api.GetItemMaxStackSizeByID, itemID)
        if ok and type(value) == "number" and value >= 1 then return value end
    end
end

function Posting:CanPostMany(itemID, link)
    if type(self.manyRefused) ~= "table" then self.manyRefused = {} end
    if self.manyRefused[itemID] then return false end
    if link and Util.LinkSuffix(link) then return false end
    return MaxStack(itemID) == 1
end

--------------------------------------------------------------------------------
-- These take an ItemLocation and read the auction house's sell state, which
-- was investigated as a cause of Blizzard's own Sell tab failing with
-- "Internal auction error". It was ruled out: the error occurs with this addon
-- disabled entirely, so it is a realm-side problem and these calls are safe.
--
-- @param held  optional { bag, slot } the caller already found, so a list
--   building many of these does not re-walk the bags for each one. A table
--   with no bag means the caller looked and there is no slot to list from.
-- @return sellable, postableCount
function Posting:GetSellInfo(itemID, held)
    local bag, slot

    if held then
        bag, slot = held.bag, held.slot
    else
        bag, slot = FindInBags(itemID)
    end

    if not bag then return false, 0 end

    -- Era asks nothing of a location; the bag slot is enough there.
    local location = MakeLocation(bag, slot)
    if not location and not Posting.IsLegacy() then return false, 0 end

    local sellable = true
    if Util.HasFunction("C_AuctionHouse.IsSellItemValid") then
        local ok, valid = pcall(C_AuctionHouse.IsSellItemValid, location, false)
        if ok then sellable = valid and true or false end
    else
        sellable = not LooksBound(itemID)
    end

    -- Soulbound copies are left out of the count.
    local count = ns.Inventory:GetBagCount(itemID)
    local free = held and held.free
    if free == nil then free = FreeCount(itemID) end
    if count and free < count then count = free end
    if Util.HasFunction("C_AuctionHouse.GetAvailablePostCount") then
        local ok, available = pcall(C_AuctionHouse.GetAvailablePostCount, location)
        if ok and available then count = available end
    end

    return sellable, count
end

--------------------------------------------------------------------------------
-- Pricing
--------------------------------------------------------------------------------

--- The price to list one unit at, and why.
--
-- One line, so the Sell tab, the Profit tab and /bts price can never quote
-- three different numbers for the same item. The rules live in
-- Profit:ChoosePostPrice, which is also where the whole-silver step that item
-- auctions impose is applied.
--
-- @return price, basis, why, uncertain, waits  -- as Profit:ChoosePostPrice
--
-- A random suffix ("of the Monkey") is priced as the copy that would be
-- listed, the first unlocked one in the bags, when its suffix has a price.
-- `link` false says the caller already knows the copy has none.
function Posting:GetPostPrice(itemID, link)
    if link == nil then link = self:ListedCopy(itemID) end
    return ns.Profit:ChoosePostPrice(itemID, nil, link or nil)
end

-- The link of the copy each item would be listed from, when it names a random
-- suffix, kept until the bags change (Inventory.changes). The Sell list asks
-- for every line, three times a second at the auction house, so only gear
-- that can have a suffix is looked for, and once per change of the bags.
Posting.copyLinks = { key = nil, links = {} }

function Posting:ListedCopy(itemID)
    if not itemID then return nil end
    local key = ns.Inventory and ns.Inventory.changes
    local kept = self.copyLinks
    if kept.key ~= key or key == nil then
        kept.key, kept.links = key, {}
    end
    local link = kept.links[itemID]
    if link ~= nil then return link or nil end

    link = false
    local quality
    local api = _G.C_Item
    if type(api) == "table" and type(api.GetItemQualityByID) == "function" then
        local ok, value = pcall(api.GetItemQualityByID, itemID)
        quality = ok and tonumber(value) or nil
    end
    local Scanner = ns.Scanner
    local may = quality == nil or (Scanner and Scanner.MayHaveSuffix and Scanner.MayHaveSuffix(itemID, quality))
    if may and C_Container and C_Container.GetContainerItemLink then
        local bag, slot = FindInBags(itemID)
        if bag then
            local ok, held = pcall(function()
                local text = C_Container.GetContainerItemLink(bag, slot)
                return type(text) == "string" and text .. "" or nil
            end)
            if ok and held and Util.LinkSuffix(held) then link = held end
        end
    end
    kept.links[itemID] = link
    return link or nil
end

--------------------------------------------------------------------------------
-- Deposits
--------------------------------------------------------------------------------

--- Deposit per unit, remembered from the last time it could be calculated.
--
-- The client only works deposits out at the auction house, but profit has to
-- account for them everywhere.
function Posting:GetCachedUnitDeposit(itemID)
    if not ns.db or not itemID then return nil end

    local record = ns.db.deposits and ns.db.deposits[itemID]
    if not record then return nil end

    -- A deposit quoted for a different listing length is not this one.
    if record.duration ~= self:DurationFor(itemID) then return nil end

    return record.unit
end

function Posting:CacheUnitDeposit(itemID, deposit, quantity, duration)
    if not ns.db or not itemID or not deposit or deposit <= 0 then return end

    ns.db.deposits = ns.db.deposits or {}
    quantity = math.max(1, math.floor(tonumber(quantity) or 1))

    -- Kept exact. A deposit is worked out on the whole stack and rarely
    -- divides evenly: flooring 39c for 20 to 1c each made the next refresh
    -- show 20c, and a cheap stack could cache a deposit of 0.
    local record = {
        unit = deposit / quantity,
        quantity = quantity,
        least = deposit,
        leastQuantity = quantity,
        duration = duration,
        at = time(),
    }

    -- The auction house asks a least deposit on any listing (players see 1s
    -- for one and for twenty alike), so a small listing's share each runs
    -- high. The biggest listing seen gives the truest share, and the
    -- smallest says where that floor sits.
    local old = ns.db.deposits[itemID]
    if type(old) == "table" and old.duration == duration then
        local oldQuantity = tonumber(old.quantity)
        if oldQuantity and oldQuantity > quantity and tonumber(old.unit) then
            record.unit, record.quantity = old.unit, oldQuantity
        end
        local oldLeast = tonumber(old.least)
        local oldLeastQuantity = tonumber(old.leastQuantity)
        if oldLeast and oldLeastQuantity and oldLeastQuantity < quantity then
            record.least, record.leastQuantity = oldLeast, oldLeastQuantity
        end
    end

    ns.db.deposits[itemID] = record
end

--- The deposit a remembered record gives for a listing of `quantity`:
--- the share each times the count, but never under the least deposit the
--- auction house was seen to ask.
function Posting.DepositFromRecord(record, quantity)
    if type(record) ~= "table" or not tonumber(record.unit) then return nil end

    quantity = math.max(1, quantity or 1)
    local deposit = math.floor(record.unit * quantity + 0.5)

    -- Only a floor when the small listing paid more each than the big one.
    -- Without that, its deposit is just the same share for fewer.
    local least = tonumber(record.least)
    local leastQuantity = tonumber(record.leastQuantity)
    if least and leastQuantity and least > record.unit * leastQuantity + 1 then
        deposit = math.max(deposit, least)
    end

    return math.max(1, deposit)
end

--- About what a listing of `quantity` costs to put up, from what the
--- auction house said before. nil until one was worked out at this length.
function Posting:EstimateDeposit(itemID, quantity)
    if not self:GetCachedUnitDeposit(itemID) then return nil end
    return Posting.DepositFromRecord(ns.db.deposits[itemID], quantity)
end

function Posting:GetDeposit(itemID, quantity)
    -- Away from an auction house the cached figure is the only honest answer.
    if not ns.Scanner.isAuctionHouseOpen then
        return self:EstimateDeposit(itemID, quantity)
    end

    -- A deposit is a property of the item and the listing length, not of the
    -- moment, so asking the client again for one worked out seconds ago buys
    -- nothing. It matters now that the Post tab offers the whole bag and
    -- rebuilds itself every second: without this, a bagful of items means a
    -- hundred deposit calculations a second, at the auction house, which is
    -- exactly where this addon must stay out of the way.
    local record = ns.db and ns.db.deposits and ns.db.deposits[itemID]
    local cached = self:GetCachedUnitDeposit(itemID)

    if cached and record and record.at
        and (time() - record.at) < DEPOSIT_CACHE_SECONDS then
        return Posting.DepositFromRecord(record, quantity)
    end

    local duration = self:DurationFor(itemID)

    if ns.Scanner:IsCommodity(itemID) then
        if Util.HasFunction("C_AuctionHouse.CalculateCommodityDeposit") then
            local ok, deposit = pcall(C_AuctionHouse.CalculateCommodityDeposit,
                itemID, duration, quantity)

            if ok and deposit then
                self:CacheUnitDeposit(itemID, deposit, quantity, duration)
                return deposit
            end
        end
        return nil
    end

    if Util.HasFunction("C_AuctionHouse.CalculateItemDeposit") then
        local bag, slot = FindInBags(itemID)
        local location = bag and MakeLocation(bag, slot)

        if location then
            local ok, deposit = pcall(C_AuctionHouse.CalculateItemDeposit,
                location, duration, quantity)

            if ok and deposit then
                self:CacheUnitDeposit(itemID, deposit, quantity, duration)
                return deposit
            end
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- How many to list
--------------------------------------------------------------------------------

-- How many of each item the player has chosen to list, when they want fewer
-- than everything they are holding.
--
-- Session-only, and deliberately so. Bags change underneath a remembered
-- number -- a stack sold, split, or topped up by a craft -- and a saved "12"
-- applied to a later stack of 3 would list the wrong amount without anyone
-- asking. Every read is clamped against what is actually postable right now,
-- and an item never touched lists everything, which is what the button did
-- before this existed.
Posting.chosenQuantity = {}

--- How many of an item to list, given what could go up.
-- @param maxQuantity the most that can be listed in one go
function Posting:GetChosenQuantity(itemID, maxQuantity)
    maxQuantity = maxQuantity or 0
    if maxQuantity < 1 then return 0 end

    local chosen = itemID and self.chosenQuantity[itemID]
    if not chosen then return maxQuantity end

    return math.max(1, math.min(chosen, maxQuantity))
end

--- Remember how many of an item to list.
--
-- Stored unclamped: the player may set 20 while holding 5, craft more, and
-- expect the 20 back. Clamping happens on the way out instead.
function Posting:SetChosenQuantity(itemID, quantity)
    if not itemID then return end

    quantity = tonumber(quantity)
    if not quantity then return end

    self.chosenQuantity[itemID] = math.max(1, math.floor(quantity))
    Posting.changes = (Posting.changes or 0) + 1
end

--- Forget a choice, so the item goes back to listing everything.
function Posting:ClearChosenQuantity(itemID)
    if itemID then self.chosenQuantity[itemID] = nil end
    Posting.changes = (Posting.changes or 0) + 1
end

--- Change how many a line will list, and everything that follows from it.
--
-- The line is updated in place rather than rebuilt, because rebuilding the
-- list scrolls it back to the top -- losing your place every time you type a
-- number is worse than the problem being solved.
-- @return the quantity actually applied, after clamping
function Posting:ApplyQuantity(line, quantity)
    if not line then return end

    local maxQuantity = line.maxQuantity or line.count or 1

    self:SetChosenQuantity(line.itemID, quantity)
    quantity = self:GetChosenQuantity(line.itemID, maxQuantity)

    -- Asking for everything is not a choice to remember: keeping it would pin
    -- the item at today's stack size, so crafting ten more would still list
    -- only the old number.
    if quantity >= maxQuantity then
        self:ClearChosenQuantity(line.itemID)
    end

    line.postQuantity = quantity
    line.postTotal = line.unitPrice and (line.unitPrice * quantity) or nil
    line.deposit = self:GetDeposit(line.itemID, quantity)

    return quantity
end

--------------------------------------------------------------------------------
-- A price of the player's own, for now
--------------------------------------------------------------------------------

-- Asked 2026-10-08: a player wanted to sell under market value to get rid of
-- a bad buy, without going back to the plain auction house to type it. The
-- price editor on Ready to sell (UI/PriceEditor.lua) sets a price per unit,
-- or a total split over the stack, for that item.
--
-- Session-only, like the quantity above: a dump price is for this visit, and
-- one kept for good would go on undercutting the market next week. Keeping
-- it for good is the Prices tab's "Use this price", which the editor offers
-- as a tick box and never sets on its own.
Posting.chosenPrice = {}

--- A price the auction house will take for this item: whole silver for an
--- item auction, any copper for a commodity. Rounded down, since the point
--- of a price typed by hand is that it sells at or under what was asked.
function Posting:NormalisePrice(price, isCommodity)
    price = tonumber(price)
    if not price or price < 1 then return nil end
    price = math.floor(price)
    if isCommodity == false then return Util.RoundToSilver(price) end
    return price
end

--- The unit price that makes up a total over `quantity`, rounded down so the
--- listing never comes to more than the total asked for (40s over 6 is
--- 6s 66c each, 39s 96c in all).
function Posting:PriceFromTotal(total, quantity, isCommodity)
    total, quantity = tonumber(total), tonumber(quantity)
    if not total or total < 1 or not quantity or quantity < 1 then return nil end
    return self:NormalisePrice(math.floor(total / math.floor(quantity)), isCommodity)
end

--- The price the player set for this item this session, or nil.
function Posting:GetChosenPrice(itemID)
    return itemID and self.chosenPrice[itemID] or nil
end

--- Set the price for this item this session; nil goes back to the suggested
--- price. Saved rules (the Prices tab's My price) are not touched.
function Posting:SetChosenPrice(itemID, price)
    if not itemID then return end
    price = tonumber(price)
    if price and price >= 1 then
        self.chosenPrice[itemID] = math.floor(price)
    else
        self.chosenPrice[itemID] = nil
    end
    Posting.changes = (Posting.changes or 0) + 1
end

--- Change the price a line will list at, in place, as ApplyQuantity does.
-- @param price  copper per unit, or nil to go back to the suggested price
-- @return the unit price now on the line
function Posting:ApplyPrice(line, price)
    if not line then return end

    if line.suggestedPrice == nil and line.priceBasis ~= "chosen" then
        line.suggestedPrice, line.suggestedBasis = line.unitPrice, line.priceBasis
    end

    local commodity = line.isCommodity
    if commodity == nil and ns.Scanner and ns.Scanner.IsCommodity then
        commodity = ns.Scanner:IsCommodity(line.itemID)
    end
    price = self:NormalisePrice(price, commodity)
    self:SetChosenPrice(line.itemID, price)

    if price then
        line.unitPrice, line.priceBasis = price, "chosen"
    else
        line.unitPrice, line.priceBasis = line.suggestedPrice, line.suggestedBasis
    end

    local unit = line.unitPrice
    local quantity = line.postQuantity or line.maxQuantity or line.count or 1
    line.postTotal = unit and (unit * quantity) or nil
    line.total = unit and (unit * (line.count or quantity)) or nil

    local belowCrafted = unit ~= nil and self:BelowCraftedCost(line.itemID, unit) ~= nil
    local underFloor = unit ~= nil and line.lossFloor ~= nil and unit < line.lossFloor
    line.belowCrafted = belowCrafted or nil
    line.atALoss = belowCrafted or underFloor
    if belowCrafted and not underFloor then
        line.lossReason = "crafted"
    elseif line.lossReason == "crafted" then
        line.lossReason = line.lossFloorReason
    end

    return unit
end

--------------------------------------------------------------------------------
-- What to list
--------------------------------------------------------------------------------

--- The lowest a listing may go before it costs the player something, and why.
--
-- Two different floors, and the higher one wins.
--
-- Material cost is the obvious one, but it only exists for things made from a
-- recipe this account knows. Everything else in a player's bags -- gathered
-- mats, drops, vendor trash -- has no cost to compare against, and that was the
-- bug: `price < unitCost` cannot be true when unitCost is nil, so those lines
-- were never flagged however little they were about to sell for.
--
-- What a vendor pays is the floor that always exists. Listing below it is worse
-- than walking to a vendor, before the auction house takes its cut or keeps the
-- deposit on a listing nobody wants at that price either.
--
-- @return floor   copper, or nil if neither is known
-- @return reason  "cost" or "vendor", naming which floor applies
-- @return vendor  the vendor price itself, for display
--- True when a vendor pays at least what one would bring on the auction
--- house after its cut, so it is better sold to a vendor. A player asked
--- (2026-10-17) for Tradeskills to say so, rather than list it as a loss.
function Posting.VendorPaysMore(itemID, price, vendorPrice)
    if not price or not vendorPrice or vendorPrice <= 0 then return false end
    local ok, net = pcall(ns.Profit.NetFromListing, ns.Profit, itemID, price)
    if not ok or type(net) ~= "number" then net = price end
    return net <= vendorPrice
end

function Posting:GetLossFloor(itemID, unitCost)
    local vendorPrice = Util.GetVendorSellPrice(itemID)

    local floor, reason = unitCost, unitCost and "cost" or nil

    if vendorPrice and (not floor or vendorPrice > floor) then
        floor, reason = vendorPrice, "vendor"
    end

    return floor, reason, vendorPrice
end

--------------------------------------------------------------------------------
-- Ignored items
--------------------------------------------------------------------------------

-- Asked 2026-10-04: "an ignore button ... for items in the sell list so they
-- can be set to no longer appear in the list". The same shape as ignored
-- crafts on the Profit tab: kept for the whole account, by item, with the
-- item's name so Settings can list it with a Restore button.

--- The item's plain name, for Settings to list. Read inside a pcall: the
--- client can hand back a value that raises when touched.
local function PlainName(itemID)
    if Util.HasFunction("C_Item.GetItemInfo") then
        local ok, name = pcall(C_Item.GetItemInfo, itemID)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    return "item " .. tostring(itemID)
end

function Posting:IsIgnored(itemID)
    return itemID ~= nil and ns.db ~= nil and ns.db.ignoredSellItems ~= nil
        and ns.db.ignoredSellItems[itemID] ~= nil
end

--- Ignore an item (ignored = true) or bring it back (false).
function Posting:SetIgnored(itemID, ignored, name)
    if not ns.db or not itemID then return end
    Posting.changes = (Posting.changes or 0) + 1
    ns.db.ignoredSellItems = ns.db.ignoredSellItems or {}

    if ignored then
        if type(name) ~= "string" or name == "" then name = PlainName(itemID) end
        ns.db.ignoredSellItems[itemID] = name
    else
        ns.db.ignoredSellItems[itemID] = nil
    end

    if ns.PostPanel and ns.PostPanel.Refresh then ns.PostPanel:Refresh() end
    if ns.UI and ns.UI.RefreshActiveTab then ns.UI:RefreshActiveTab() end
end

--- The ignored items, A to Z: { { itemID, name }, ... }.
function Posting:GetIgnored()
    local list = {}
    for itemID, name in pairs(ns.db and ns.db.ignoredSellItems or {}) do
        list[#list + 1] = { itemID = itemID,
                            name = type(name) == "string" and name or ("item " .. tostring(itemID)) }
    end
    table.sort(list, function(a, b)
        local left, right = a.name:lower(), b.name:lower()
        if left ~= right then return left < right end
        return a.itemID < b.itemID
    end)
    return list
end

--- Items in your bags worth listing.
--
-- @param opts.includeAll  everything sellable in the bags, not only what one
--   of this account's recipes makes. The number of each reagent a queued
--   craft is waiting on is still held back, because listing those costs
--   real work to undo.
-- @param opts.showHeld  keep rows another addon wants all of kept (line.held,
--   the reason), so the Sell list can show them dimmed; nothing that picks
--   what to list ever takes one.
-- @param opts.includeUnpriced  keep items no scan has ever priced, which only
--   the Post tab wants; every caller that picks something to list on the
--   player's behalf must not see them.
--
-- Items the player ignored are never offered, on any list: ignoring one
-- means not selling it, so Post Crafted and Post ALL leave it alone too.
function Posting:GetPostable(opts)
    opts = opts or {}

    local outputs = {}

    -- Straight from the saved recipes: GetAccountWide copies every recipe of
    -- every character, and this runs every second at the auction house.
    local recipes = ns.Recipes.GetAccountWideOutputs and ns.Recipes:GetAccountWideOutputs()
        or ns.Recipes:GetAccountWide()
    for _, recipe in pairs(recipes) do
        if recipe.outputItemID then
            outputs[recipe.outputItemID] = recipe.recipeID
        end
    end

    -- Never offer to sell what a queued craft is waiting on. Listing your
    -- own reagents is the one mistake here that costs real work to undo.
    -- Crafted stock included: a bolt made for a queued bag is still a
    -- reagent, and Post Crafted offered it when it was the priciest stack.
    -- Only the number the queue needs is held back, so one queued bag does
    -- not keep sixty bolts off the list.
    local reserved = {}

    if ns.Queue.GetReservedItems then
        reserved = ns.Queue:GetReservedItems()
    else
        for _, entry in ipairs(ns.Queue:GetShoppingList() or {}) do
            if entry.itemID then reserved[entry.itemID] = true end
        end
    end

    local lines = {}
    local order, slots = IndexBags()

    -- Why each item in the bags was left out, for /bts readysell.
    local skipped = {}

    -- How many were left for a vendor, for the drawer's summary line.
    local vendorPile = 0

    for _, itemID in ipairs(order) do
        -- Reagents the queue needs are offered too, less the number it needs
        -- (held back below), as crafted stock is: one queued craft needing
        -- six Linen Cloth kept all two hundred off the whole-bag lists.
        local wanted = outputs[itemID] ~= nil or opts.includeAll

        if not wanted then
            skipped[itemID] = "not asked for"
        elseif self:IsIgnored(itemID) then
            wanted = false
            skipped[itemID] = "ignored (Settings, Ignored items)"
        elseif IsGrey(itemID, slots[itemID]) then
            wanted = false
            skipped[itemID] = "grey, sells to a vendor"
        end

        if wanted then
            local held = slots[itemID]

            local sellable, count = self:GetSellInfo(itemID, held)
            local copy = held and held.link and Util.LinkSuffix(held.link) and held.link or nil
            local price, basis, _, _, waits = self:GetPostPrice(itemID, copy or false)

            -- A price the player set this session wins, with the suggested
            -- one kept beside it for the editor's reset.
            local suggested, suggestedBasis = price, basis
            local chosen = self:GetChosenPrice(itemID)
            if chosen then
                price, basis = self:NormalisePrice(chosen, ns.Scanner:IsCommodity(itemID)), "chosen"
            end

            local keep = reserved[itemID]
            if keep and count then
                count = count - (type(keep) == "number" and keep or count)
            end

            -- What the other Blackthornes addons want kept (a Farmer goal,
            -- an upgrade, pet food, Butler's lists, a quest, a clam worth
            -- more opened): only that many held back. All of it held, the
            -- row still shows dimmed with why when the caller asks
            -- (showHeld), so the player can list it by hand, but List all
            -- and Post Crafted never pick it (GetNextPostable).
            local heldAll, kept, keptWhy
            -- The list the item is on (Logic/ListRules.lua): its Keep in
            -- Bags is one more keep, the bigger one wins.
            local listRule = ns.ListRules and ns.ListRules:For(itemID)
            if count and count > 0 then
                local hold, why = 0, nil
                if ns.SisterKeeps then
                    local ok, sister, sisterWhy = pcall(ns.SisterKeeps.Hold, ns.SisterKeeps, itemID, held, count, price)
                    sister = ok and tonumber(sister) or 0
                    if sister > 0 and type(sisterWhy) == "string" then hold, why = sister, sisterWhy end
                end
                local bags = listRule and listRule.rules.bags
                if bags and bags > hold then
                    hold, why = bags, L.Format("Following your %s list.", listRule.name)
                end
                if hold > 0 and why then
                    if hold >= count then
                        heldAll = why
                    else
                        count, kept, keptWhy = count - hold, hold, why
                    end
                end
            end

            -- Keep Listed: no more up than the list allows. Full, it waits
            -- (dimmed, as a keep: its List button still lists it).
            local listRoom, listUp
            if listRule and count and count > 0 and not heldAll then
                listRoom, listUp = ns.ListRules:ListedRoom(itemID)
                if listRoom and listRoom <= 0 then
                    heldAll = L.Format("Waiting, already %d up", listUp)
                elseif listRoom and listRoom < count then
                    count = listRoom
                end
            end

            -- When Cheaper, Wait (the Prices tab or its list, 2026-10-28):
            -- others sell it for less than the least the player set, so it
            -- waits in the bags, dimmed as a keep. A price typed this
            -- session still lists, and so does its own List button.
            if waits and not chosen and count and count > 0 and not heldAll then
                heldAll = L["Waiting, others are selling for less"]
            end

            if keep and count and count <= 0 then
                skipped[itemID] = "kept for a queued craft"
            elseif heldAll and not opts.showHeld then
                skipped[itemID] = "kept for another addon: " .. heldAll
            elseif not sellable then
                skipped[itemID] = "the auction house says it cannot be sold"
            elseif not count or count <= 0 then
                skipped[itemID] = "the auction house says none can be posted"
            elseif not price and opts.includeAll and not opts.includeUnpriced then
                skipped[itemID] = "no price"
            end

            -- What it cost to make one, so a listing below that can be
            -- flagged rather than quietly recommended.
            local analysis = outputs[itemID]
                and ns.Profit:Analyse(outputs[itemID])
            local unitCost = analysis and analysis.costPerUnit

            local lossFloor, lossReason, vendorPrice =
                self:GetLossFloor(itemID, unitCost)

            -- Worth more at a vendor than the auction house pays after its
            -- cut: it goes to the vendor pile, not this list. A price the
            -- player typed this session still lists.
            local toVendor = basis ~= "chosen" and Posting.VendorPaysMore(itemID, price, vendorPrice)
            if toVendor and sellable and count and count > 0
                    and not (heldAll and not opts.showHeld) then
                vendorPile = vendorPile + 1
                skipped[itemID] = "a vendor pays more"
            end

            -- Under what the last craft of it cost, with that guard on.
            local belowCrafted = price ~= nil
                and self:BelowCraftedCost(itemID, price) ~= nil
            local madeFor = ns.CraftedCost and ns.CraftedCost:Get(itemID)

            local isCommodity = ns.Scanner:IsCommodity(itemID)

            -- Commodities sell from across the bags at once; item
            -- auctions come from a single slot, so gear goes up one
            -- listing at a time. That is the ceiling, not the amount:
            -- the player may have asked for fewer.
            local maxQuantity = (isCommodity or self:CanPostMany(itemID, held and held.link))
                and count
                or math.min(count, (held and held.stackCount) or 1)

            local postQuantity = self:GetChosenQuantity(itemID, maxQuantity)

            -- Without a price there is nothing to list it at, and a guess on
            -- someone's bag contents is worse than a skip -- so the buttons
            -- that pick something to list never see one. The Post tab asks
            -- for them anyway with includeUnpriced: it draws the row, says
            -- there is no price and offers to go and find one, which beats an
            -- item the player is holding being silently absent from a list
            -- that claims to show their bags.
            local needsPrice = opts.includeAll and not opts.includeUnpriced

            if sellable and count > 0 and (price or not needsPrice)
                    and (opts.showHeld or not heldAll) and not toVendor then
                lines[#lines + 1] = {
                    itemID = itemID,
                    recipeID = outputs[itemID],
                    count = count,
                    unitPrice = price,
                    priceBasis = basis,
                    suggestedPrice = suggested,
                    suggestedBasis = suggestedBasis,
                    unitCost = unitCost,
                    vendorPrice = vendorPrice,
                    lossFloor = lossFloor,
                    lossFloorReason = lossReason,
                    lossReason = (belowCrafted and not (price and lossFloor and price < lossFloor))
                        and "crafted" or lossReason,
                    atALoss = belowCrafted or (price ~= nil and lossFloor ~= nil
                        and price < lossFloor),
                    belowCrafted = belowCrafted or nil,
                    craftedCost = madeFor and madeFor.cost or nil,
                    postQuantity = postQuantity,
                    maxQuantity = maxQuantity,
                    quantityChosen = postQuantity ~= maxQuantity,
                    total = price and (price * count) or nil,
                    postTotal = price and (price * postQuantity) or nil,
                    deposit = self:GetDeposit(itemID, postQuantity),
                    isCommodity = isCommodity,
                    -- Whether one of this account's recipes makes it, so the
                    -- tab can tell crafted stock from the rest of the bag.
                    isCrafted = outputs[itemID] ~= nil,
                    -- Why another addon wants it all kept, or how many it
                    -- kept back and why (SisterKeeps).
                    held = heldAll,
                    kept = kept,
                    keptWhy = keptWhy,
                    -- The copy itself when it has a random suffix: the item
                    -- ID alone names only "Lead Band".
                    link = held and Util.LinkSuffix(held.link) and held.link or nil,
                    label = held and Util.LinkSuffix(held.link) and held.link
                        or Util.GetItemLabel(itemID),
                    -- The list whose rules it follows, for the row's tag,
                    -- and whether its own price on the Prices tab wins.
                    listName = listRule and listRule.name or nil,
                    ownPriceWins = listRule and ns.ListRules:OwnPriceWins(itemID) or nil,
                }
            end
        end
    end

    table.sort(lines, function(a, b)
        local left, right = a.total or 0, b.total or 0
        if left ~= right then return left > right end

        -- Ties used to be left to table.sort, which is not stable. With the
        -- whole bag on show, every unpriced row is worth the same nothing, so
        -- the bottom of the list reshuffled itself once a second. itemID is
        -- an arbitrary order, but it is the same arbitrary order every time.
        return (a.itemID or 0) < (b.itemID or 0)
    end)

    if opts.includeAll and not opts.includeUnpriced then
        self:WatchReadyToSell(lines, skipped)
    end

    return lines, vendorPile
end

--------------------------------------------------------------------------------
-- /bts readysell: what comes and goes on Ready to sell, and why
--------------------------------------------------------------------------------

local readyWatch = { untilTime = nil, last = nil }

--- Compare this Ready to sell list with the last one while a watch runs,
--- and say which items appeared or dropped out and why.
function Posting:WatchReadyToSell(lines, skipped)
    if not readyWatch.untilTime then return end

    if GetTime() > readyWatch.untilTime then
        readyWatch.untilTime, readyWatch.last = nil, nil
        ns.Print(("readysell: watch finished, %d change(s) seen"):format(readyWatch.changes or 0))

        -- Whether the Disenchanting list walked every scanned item meanwhile.
        if ns.Disenchant then
            ns.Print(("readysell: the Disenchanting list was rebuilt %d time(s) during the watch")
                :format((ns.Disenchant.rowBuilds or 0) - (readyWatch.builds or 0)))
        end
        return
    end

    local now = {}
    for _, line in ipairs(lines) do now[line.itemID] = true end

    local last = readyWatch.last
    readyWatch.last = now
    if not last then
        ns.Print(("readysell: watching for %d seconds, %d item(s) listed now")
            :format(readyWatch.seconds, #lines))
        return
    end

    for itemID in pairs(last) do
        if not now[itemID] then
            readyWatch.changes = (readyWatch.changes or 0) + 1
            ns.Print(("readysell: %s dropped out: %s"):format(Util.GetItemLabel(itemID),
                skipped[itemID] or "no longer in your bags"))
        end
    end

    for itemID in pairs(now) do
        if not last[itemID] then
            readyWatch.changes = (readyWatch.changes or 0) + 1
            ns.Print(("readysell: %s came back"):format(Util.GetItemLabel(itemID)))
        end
    end
end

ns.RegisterCommand("readysell", L["watch Ready to sell for 15 seconds and say why items come and go"], function()
    readyWatch.seconds = 15
    readyWatch.untilTime = GetTime() + readyWatch.seconds
    readyWatch.last, readyWatch.changes = nil, 0
    readyWatch.builds = ns.Disenchant and ns.Disenchant.rowBuilds or 0

    if not (ns.Scanner and ns.Scanner.isAuctionHouseOpen) then
        ns.Print("readysell: open the auction house first, Ready to sell only updates there")
        readyWatch.untilTime = nil
        return
    end

    ns.Print("readysell: watching, leave the windows as they are for 15 seconds")
end)

--- Would Post refuse this line's price outright (under the price floor)?
--- Such a line is never next: Post Crafted kept offering the same item,
--- refusing it after the price check and confirm, with everything else
--- stuck behind it.
function Posting:IsUnderFloor(line)
    if not line.unitPrice then return false end
    local floor = self:GetPriceFloor(line.itemID, line.priceBasis == "chosen")
    return floor ~= nil and line.unitPrice < floor
end

--- The most valuable stack worth listing right now.
--
-- Skips anything unpriced, anything under the price floor, and anything
-- that would sell below material cost unless losses are explicitly allowed.

-- @param lines  a GetPostable list already made, to save making it again
-- @param opts.skipSettling  pass over items with a listing still being
--   confirmed (fast listing: a second click on it before the bags catch up
--   must not list it twice). The second return says whether any were.
function Posting:GetNextPostable(opts, lines)
    local allowLoss = ns.Config:Get("allowPostingAtALoss") == true
    local skipSettling = type(opts) == "table" and opts.skipSettling
    local settling = false

    for _, line in ipairs(lines or self:GetPostable(opts)) do
        if line.unitPrice and (allowLoss or not line.atALoss) and not line.belowCrafted
            and not line.held and not self:IsUnderFloor(line) then
            if skipSettling and self:PendingFor(line.itemID) then
                settling = true
            else
                return line
            end
        end
    end

    return nil, settling
end

--- Count and total value of everything worth listing.
function Posting:GetSummary(opts, lines)
    local allowLoss = ns.Config:Get("allowPostingAtALoss") == true

    local count, total = 0, 0
    for _, line in ipairs(lines or self:GetPostable(opts)) do
        if line.unitPrice and (allowLoss or not line.atALoss) and not line.belowCrafted
            and not line.held and not self:IsUnderFloor(line) then
            count = count + 1
            total = total + (line.total or 0)
        end
    end

    return count, total
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function Posting:OnEnable()
    if self:IsBlocked() then
        ns.Debug("the game blocks addons from posting; the addon will only suggest prices")
    end

    -- Listing something by hand changes what is left to list, and what counts
    -- against your posted-stock limits.
    ns.RegisterEvent(self, "AUCTION_HOUSE_AUCTION_CREATED", function()
        ns.Auctions:Refresh()

        if ns.UI then
            ns.UI:RefreshActiveTab()
            ns.UI:UpdatePostButton()
        end
    end)

    -- Walking away with a confirmation still up takes it down too. Left up,
    -- its Yes could list later, back at the auction house, at a price
    -- checked minutes before.
    -- Era: the auction slot changed. A stack put in has been taken.
    ns.RegisterEvent(self, "NEW_AUCTION_UPDATE", function()
        if held and SellSlotHolds(held.itemID) then held.ready = true end
    end)

    ns.RegisterEvent(self, "AUCTION_HOUSE_CLOSED", function()
        -- Prices move while away: the next visit checks them again.
        Posting:ForgetChecks()
        held = nil

        local data = Posting.confirming
        Posting.confirming = nil

        local okVisible, visible = pcall(StaticPopup_Visible, "BLACKTHORNES_TS_CONFIRM_POST")
        if not (okVisible and visible) then return end

        pcall(StaticPopup_Hide, "BLACKTHORNES_TS_CONFIRM_POST")
        if data then
            ns.Print(L.Format("the auction house closed, so %s was not listed.",
                Util.GetItemLabel(data.itemID)))
        end
    end)
end

--------------------------------------------------------------------------------
-- Diagnostics
--------------------------------------------------------------------------------

-- Kept because the answer is not obvious and the symptoms mislead: a protected
-- call returns without error and simply does nothing.
ns.RegisterCommand("taint", L["check whether the game lets this addon post and craft for you"], function()
    ns.Print("what the game lets addons do")

    local secure = issecure and issecure()
    ns.PrintRaw(("  issecure() here:              %s"):format(tostring(secure)))

    if type(C_AuctionHouse) == "table" and issecurevariable then
        local ok, isSecure = pcall(issecurevariable, C_AuctionHouse, "PostItem")
        ns.PrintRaw(("  PostItem is a secure value:   %s"):format(
            ok and tostring(isSecure) or "could not check"))
    end

    if type(C_TradeSkillUI) == "table" and issecurevariable then
        local ok, isSecure = pcall(issecurevariable, C_TradeSkillUI, "CraftRecipe")
        ns.PrintRaw(("  CraftRecipe is secure:        %s"):format(
            ok and tostring(isSecure) or "could not check"))
    end

    ns.PrintRaw(("  addon posting blocked:        %s"):format(
        tostring(ns.Posting:IsBlocked())))
    ns.PrintRaw(("  addon crafting blocked:       %s"):format(
        tostring(ns.Crafting:IsBlocked())))
end)

--------------------------------------------------------------------------------
-- Listing
--------------------------------------------------------------------------------

--- List one item. Must be called from a hardware event.
--- True on Era's older auction house, which has no C_AuctionHouse.
function Posting.IsLegacy()
    return ns.LegacyScan ~= nil and ns.LegacyScan.Applies ~= nil and ns.LegacyScan:Applies() == true
end

--- Put a bag slot's stack in Era's auction slot, sending back whatever was
--- there. Needs no click, so it can be done ahead of one.
-- @return true when the stack went in
local function PlaceInSellSlot(itemID, bag, slot)
    local pickup = C_Container and C_Container.PickupContainerItem or _G.PickupContainerItem
    if type(pickup) ~= "function" or type(_G.ClickAuctionSellItemButton) ~= "function" then
        return false
    end
    local button = _G.AuctionsItemButton

    pcall(ClearCursor)

    -- Something already in the auction slot goes back to the bags first.
    if SellSlotItem() then
        pcall(ClickAuctionSellItemButton, button, "LeftButton")
        pcall(ClearCursor)
    end

    if not pcall(pickup, bag, slot) then
        pcall(ClearCursor)
        return false
    end
    local placed = pcall(ClickAuctionSellItemButton, button, "LeftButton")
    pcall(ClearCursor)
    if not placed then return false end

    held = { itemID = itemID, bag = bag, slot = slot, at = GetTime() }
    return true
end

--- Whether the stack put in the auction slot has had time to be taken.
local function HeldReady(itemID)
    if not HeldSlot(itemID) then return false end
    return held.ready == true or GetTime() - (held.at or 0) >= HELD_SETTLE
end

--- List one stack the Era way: PostAuction on the stack already in the
--- auction slot, at the stack's price. Bid and buyout are the same, so
--- nobody wins it for less than the price shown. The click that called it
--- is the hardware event PostAuction needs.
--
-- A stack not yet in the slot is put in, and this click lists nothing
-- ("placed"): listing in the same click is refused with the game's
-- "Internal auction error" (seen 2026-10-25).
--
-- Never StartAuction while PostAuction is there: Era still has the old
-- name, but calling it is refused and the game's "This addon has been
-- disabled" box comes up (seen 2026-10-25). StartAuction is only for a
-- client with no PostAuction.
-- @return true; or false and "placed" or "waiting"; or false and the game's reason (may be nil)
local function LegacyStart(itemID, bag, slot, quantity, unitPrice, duration)
    local postAuction = type(_G.PostAuction) == "function" and _G.PostAuction or nil
    local start = not postAuction and type(_G.StartAuction) == "function" and _G.StartAuction or nil
    if not (postAuction or start) then return false, nil end

    local heldBag, heldSlot = HeldSlot(itemID)
    if heldBag ~= bag or heldSlot ~= slot then
        if not PlaceInSellSlot(itemID, bag, slot) then return false, nil end
        return false, "placed"
    end
    -- Already in and said so: a quick click again just waits.
    if not HeldReady(itemID) then return false, "waiting" end

    local stackPrice = math.max(1, math.floor(unitPrice * quantity))
    local ok, err
    if postAuction then
        -- The last true says the warning about upcoming maintenance was
        -- read; without it a listing may fail before a maintenance.
        ok, err = pcall(postAuction, stackPrice, stackPrice, duration, quantity, 1, true)
    else
        ok, err = pcall(start, stackPrice, stackPrice, duration, quantity, 1)
    end
    pcall(ClearCursor)
    if ok then held = nil end
    return ok, err
end

--- Era: put the next stack List Next will list in the auction slot, so the
--- click after lists it. Out of a fight, at the auction house, with nothing
--- on the cursor; a stack already there for it stays.
function Posting:PrepareNext()
    if not Posting.IsLegacy() or not (ns.Scanner and ns.Scanner.isAuctionHouseOpen) then return end
    if InCombatLockdown and InCombatLockdown() then return end
    if CursorHasItem and CursorHasItem() then return end

    local lines
    if ns.PostPanel and ns.PostPanel.ShownLines then
        local ok, shown = pcall(ns.PostPanel.ShownLines, ns.PostPanel)
        lines = ok and shown or nil
    end
    local line = self:GetNextPostable({ skipSettling = true }, lines)
    if line then self:PrepareFor(line.itemID) end
end

--- Era: put one item's stack in the auction slot ahead of the click that
--- lists it, so that click lists straight away (the owner, 2026-10-26:
--- every listing took two presses). Asked when the Sell list draws, after
--- each listing and when the mouse goes over a List button.
--
-- Left alone: a fight, something on the cursor, an item the player put in
-- the auction slot by hand, and a Yes/No box up for another item (its Yes
-- lists the stack that is in).
-- @return true when the stack is in the auction slot now
function Posting:PrepareFor(itemID)
    if not itemID or not Posting.IsLegacy() then return false end
    if not (ns.Scanner and ns.Scanner.isAuctionHouseOpen) then return false end
    if InCombatLockdown and InCombatLockdown() then return false end
    if CursorHasItem and CursorHasItem() then return false end
    if HeldSlot(itemID) then return true end

    local inSlot = SellSlotItem()
    if inSlot and not (held and SellSlotHolds(held.itemID)) then return false end
    local box = rawget(self, "confirming")
    if type(box) == "table" and box.itemID ~= itemID then return false end

    local bag, slot = FindInBags(itemID)
    if not bag then return false end
    return PlaceInSellSlot(itemID, bag, slot)
end

function Posting:Post(itemID, quantity, unitPrice, byHand)
    local allowed, reason = self:CanPost(itemID)
    if not allowed then
        ns.Print(reason)
        return false
    end

    -- Another copy of an item still being confirmed: this listing joins it,
    -- and the check counts both (see CanPost). Other items being confirmed
    -- carry on beside it.
    local previous = self:PendingFor(itemID)

    local sellable, available = self:GetSellInfo(itemID)
    if not sellable then
        ns.Print(L.Format("%s cannot be auctioned", Util.GetItemLabel(itemID)))
        return false
    end

    quantity = math.max(1, math.min(quantity or available, available))

    -- The slot the listing will draw from, found once and used throughout:
    -- for the commodity question below, which the client only answers for a
    -- location, and for the post call itself.
    local bag, slot, slotStack = FindInBags(itemID)

    -- Era's older auction house posts from the bag slot itself
    -- (LegacyStart), so it needs no item location.
    local legacy = Posting.IsLegacy()
    local location = bag and not legacy and MakeLocation(bag, slot)

    if not bag or (not legacy and not location) then
        ns.Warn(L["could not find that item in your bags"])
        return false
    end

    local isCommodity = not legacy and ns.Scanner:IsCommodity(itemID, location)

    -- An item auction draws from the one slot it references, so gear goes up
    -- one listing at a time, unless it is copies of an item that does not
    -- stack (CanPostMany), which the auction house lists one per copy.
    local many = false
    if not isCommodity then
        local okLink, link = pcall(C_Container.GetContainerItemLink, bag, slot)
        -- Era: one stack a click, from the slot found.
        if quantity > 1 and not legacy and self:CanPostMany(itemID, okLink and link or nil) then
            many = true
        else
            quantity = math.min(quantity, slotStack or 1)
        end
    end

    if available < 1 then
        ns.Print(L["you have none of that to list"])
        return false
    end

    unitPrice = math.floor(unitPrice or self:GetPostPrice(itemID) or 0)
    if unitPrice < 1 then
        ns.Print(L["no price data for that item. Scan the auction house first"])
        return false
    end

    -- Last line of defence on the price, wherever it came from. PostItem takes
    -- whole gold and silver and silently swallows anything with copper in it,
    -- which is the internal error the client shows for a listing that never
    -- happens. A price arriving here from a caller has not necessarily been
    -- through the chooser, so it is rounded again rather than trusted.
    if not isCommodity and not Util.IsWholeSilver(unitPrice) then
        local rounded = Util.RoundToSilver(unitPrice)

        ns.Print(L.Format("item auctions only take whole silver, so %s becomes %s",
            Util.FormatMoney(unitPrice), Util.FormatMoney(rounded)))

        unitPrice = rounded
    end

    -- A nonsense price is caught before anything irreversible happens. This
    -- is separate from the material-cost check below: that one is about
    -- profit, this one is about the number being wrong.
    local floor, why = self:GetPriceFloor(itemID, byHand)

    if floor and unitPrice < floor then
        ns.Warn(L.Format("not listing %s at %s: %s.",
            Util.GetItemLabel(itemID), Util.FormatMoney(unitPrice), why or L["the price looks wrong"]))
        ns.Warn(L.Format("expected at least %s. Run a scan, or list it by hand.",
            Util.FormatMoney(floor)))
        return false
    end

    -- Refuse to list below what the materials cost. An undercut war can drive
    -- the rival price under your own cost, and following it down loses gold on
    -- every sale.
    local unitCost = self:BelowCost(itemID, unitPrice)
    if unitCost then
        ns.Warn(L.Format("not listing %s at %s, the materials cost %s",
            Util.GetItemLabel(itemID),
            Util.FormatMoney(unitPrice), Util.FormatMoney(unitCost)))
        ns.Warn(L["turn on 'Recommend selling at a loss' in Settings to allow it."])
        return false
    end

    -- Under what the last craft of it cost, with that guard turned on.
    local paid, net = self:BelowCraftedCost(itemID, unitPrice)
    if paid then
        ns.Warn(ns.CraftedCost:RefusalText(itemID, unitPrice, paid, net))
        ns.Warn(L["turn off 'Never below what I paid' in Settings to allow it."])
        return false
    end

    local duration = self:DurationFor(itemID)

    -- Put back as they were if the game refuses the listing.
    local savedPending = self.pending
    local savedOthers = {}
    if type(rawget(self, "others")) == "table" then
        for key, value in pairs(self.others) do savedOthers[key] = value end
    end

    -- The newest listing is `pending`; the one it takes over from (another
    -- item) waits in `others`, and this item's earlier copy is replaced by
    -- the joined listing below.
    if type(rawget(self, "others")) ~= "table" then self.others = {} end
    if previous then self.others[itemID] = nil end
    if self.pending and self.pending ~= previous then
        self.others[self.pending.itemID] = self.pending
    end

    self.pending = {
        itemID = itemID,
        quantity = quantity,
        unitPrice = unitPrice,
        isCommodity = isCommodity,
        many = many,
        -- Measured against afterwards, so success is verified rather than
        -- inferred from an event that fires for any auction at all.
        postedBefore = ns.Auctions:GetOwnPostedCount(itemID),
        idsBefore = ns.Auctions.GetOwnedIDs and ns.Auctions:GetOwnedIDs(itemID) or nil,
        startedAt = GetTime(),
    }

    -- Joining a listing still being confirmed: measured from before the
    -- first of them, and checked once for all of them, a few seconds after
    -- the last click. A check already out was asked before this listing
    -- existed, so it no longer settles anything: the joined listing is a new
    -- one, not yet being checked, and gets a fresh check of its own. Checks
    -- out for other items carry on.
    if previous then
        local joined = self.pending
        joined.quantity = (previous.quantity or 1) + quantity
        joined.postedBefore = previous.postedBefore
        joined.idsBefore = previous.idsBefore
        joined.many = many or previous.many
        joined.joined = true
    end

    local ok, err
    if legacy then
        ok, err = LegacyStart(itemID, bag, slot, quantity, unitPrice, duration)
    elseif isCommodity then
        ok, err = pcall(C_AuctionHouse.PostCommodity, location, duration, quantity, unitPrice)
    else
        -- Buyout only, with no starting bid. Blizzard's own Sell tab does this
        -- whenever Buyout Mode is ticked, and sending bid and buyout as the
        -- same value is the one place our call differed from theirs.
        --
        -- It also means nobody can win the item for less than the price you
        -- were shown, which was the point of matching them in the first place.
        ok, err = pcall(C_AuctionHouse.PostItem, location, duration, quantity,
            nil, unitPrice)
    end

    -- The listing went down the auction house's throttled channel like any
    -- other request, so our own requests space themselves out after it.
    if ns.AHQueue.NoteSend then ns.AHQueue:NoteSend() end

    if not ok then
        -- The earlier copies are still up and still to be confirmed.
        self.pending = savedPending
        self.others = savedOthers

        if err == "placed" then
            -- Era: the stack is going into the auction slot; the next
            -- click lists it.
            ns.Print(L.Format("%s is ready to list. Click again to list it.",
                self:ListedCopy(itemID) or Util.GetItemLabel(itemID)))
        elseif err == "waiting" then
            -- Era: the stack is still settling in the auction slot from a
            -- click moments ago, which already said so.
        elseif err == nil then
            -- Era: the stack never reached the auction slot.
            ns.Warn(L["could not find that item in your bags"])
        elseif tostring(err):lower():find("addon") then
            self:MarkBlocked()
        else
            ns.Warn(L.Format("the game refused the listing: %s",
                (tostring(err):gsub("^.-:%d+: ", ""))))
        end
        return false
    end

    -- The return value is not a success flag. PostCommodity returns false on
    -- a listing that is genuinely created, so reading it as a refusal reports
    -- failure on every successful commodity sale. Only the server's own view
    -- settles this, which is what VerifyPending goes and asks for.
    ns.Print(L.Format("listing %dx %s at %s each",
        quantity, Util.GetItemLabel(itemID), Util.FormatMoney(unitPrice)))

    if ns.CraftedCost then ns.CraftedCost:NotePosted(itemID, unitPrice) end

    -- Nothing of ours competes with a listing that is settling. Verification is
    -- urgent and still gets through; scans and bookkeeping wait.
    ns.AHQueue:Yield(POST_VERIFY_DELAY + 2, L["your listing is going through"])

    -- The auction house is throttled and can take several seconds to reply, so
    -- wait, then ask the server what is actually listed.
    local listing = self.pending
    C_Timer.After(POST_VERIFY_DELAY, function() Posting:VerifyPending(listing) end)

    -- Era: the next stack goes in the auction slot once the bags catch up.
    if legacy then C_Timer.After(HELD_SETTLE, function() Posting:PrepareNext() end) end
    return true
end

--------------------------------------------------------------------------------
-- Price floor
--------------------------------------------------------------------------------

--- The lowest price worth listing at, below which something has gone wrong.
--
-- Exists because a bad price is silent and expensive: a scroll worth a silver
-- was once about to be listed at one copper, from an auction house search
-- whose quantity field meant something other than assumed. A guard here does
-- not need to know why the number is wrong, only that it cannot be right.
--
-- @param byHand  the price is one the player typed (the price editor): the
--   fifth-of-market guard stands aside, since selling far under market is
--   then the point. The vendor floor still holds.
-- @return floor, why
function Posting:GetPriceFloor(itemID, byHand)
    local floor, why = 0, nil

    -- Below what a vendor pays, selling it to a vendor is strictly better.
    -- Remembered for the session: this runs for every line, every second,
    -- at the auction house.
    local sellPrice = Util.GetVendorSellPrice(itemID)
    if sellPrice and sellPrice > 0 then
        floor, why = sellPrice, L["a vendor pays more than that"]
    end

    -- A fifth of market value. Wide enough for a real undercut war, narrow
    -- enough to catch an order of magnitude going missing.
    local market = not byHand and ns.Prices:GetValue(itemID, "market")
    if market and market > 0 then
        local fraction = math.floor(market * 0.2)
        if fraction > floor then
            floor, why = fraction, L["that is a fraction of what it normally sells for"]
        end
    end

    if floor < 1 then return nil end
    return floor, why
end

--------------------------------------------------------------------------------
-- Confirmation
--------------------------------------------------------------------------------

-- Blizzard's own popup rather than a custom frame: it is already the thing
-- players trust for "are you sure", and its button click is a hardware event,
-- which posting requires.

-- Adding a key is fine. Assigning the global itself is not: writing
-- "StaticPopupDialogs = StaticPopupDialogs or {}" from addon code taints the
-- global variable, and then Blizzard's own popup machinery reads a tainted
-- value and gets "blocked from an action only available to the Blizzard UI"
-- the next time it shows any dialog of its own.
if type(StaticPopupDialogs) == "table" then

StaticPopupDialogs["BLACKTHORNES_TS_CONFIRM_POST"] = {
    text = "%s",
    button1 = L["List It"],
    button2 = L["Skip"],
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    -- Above the default dialogs, so it is not buried by the auction house.
    preferredIndex = 3,
    -- Widens the popup and keeps the text to the middle, which leaves room
    -- on the left for the item's icon beside the four lines. The icon is
    -- drawn over the alert sign that goes there (ShowConfirmIcon).
    showAlert = true,

    OnAccept = function(self)
        local data = (self and self.data) or Posting.confirming
        if not data then return end

        Posting.confirming = nil
        Posting:Post(data.itemID, data.quantity, data.unitPrice, data.byHand)
    end,

    -- "override" is the game replacing this dialog with the next one (a
    -- second List click while it was open): not a skip, and clearing the
    -- listing here left the new dialog's Yes with nothing to list.
    OnCancel = function(_, _, reason)
        if reason == "override" then return end
        Posting.confirming = nil
        ns.Print(L["skipped."])
    end,

    -- The game lends this popup frame to other dialogs later, so the icon
    -- goes with this one.
    OnHide = function(self)
        Posting:HideConfirmIcon(self)
    end,
}

end

--- Show the confirmation for a listing whose price is already settled.
--
-- Four lines, in the player's words: what it normally sells for, the cheapest
-- listing from anyone else, what is about to go up, and the question. Anything
-- more buried the one number that matters.
--
-- @param check what the price check found, or nil when there was none:
--   { state }. state is "fresh" (the auction house answered and had
--   listings), "recent" (answered moments ago), "empty" (answered, nothing
--   listed) or "unavailable" (no answer).
function Posting:Confirm(itemID, quantity, unitPrice, check)
    self:ShowConfirm(itemID, quantity, unitPrice, self:BuildConfirmText(itemID, quantity, unitPrice, check),
        check and check.byHand)
end

--- The confirmation's text, kept apart from the dialog so it can be tested.
function Posting:BuildConfirmText(itemID, quantity, unitPrice, check)
    check = check or {}

    local function Money(copper)
        return Util.FormatMoney(copper, { noColor = true })
    end

    -- The auction house's own figure, beside the price the player set. A
    -- random suffix reads its own, when one is kept.
    local copy = self:ListedCopy(itemID)
    local suffixMarket = copy and ns.Prices.GetSuffixValue
        and ns.Prices:GetSuffixValue(itemID, Util.LinkSuffix(copy), "market")
    local market = suffixMarket or (ns.Prices.GetScanValue and ns.Prices:GetScanValue(itemID, "market"))
        or ns.Prices:GetValue(itemID, "market")
    local NONE = L["none"]
    local marketText = (market and market > 0) and Money(market) or NONE

    -- Someone else's cheapest, never the player's own: the price being
    -- competed with. The check has just rewritten it, and an empty auction
    -- house has just cleared it, so nil here really does mean nobody.
    local lowest
    if copy and ns.Prices.GetLinkValue then
        lowest = ns.Prices:GetLinkValue(copy, "rival")
    else
        lowest = ns.Prices:GetValue(itemID, "rival")
    end
    local lowestText = (lowest and lowest > 0) and Money(lowest) or NONE

    -- Only the player's own listings are up: say so, rather than "none"
    -- beside an auction house that plainly has one.
    if lowestText == NONE then
        local record = ns.Prices:Get(itemID)
        local own = record and record.ownMin
        if own and own > 0 then lowestText = L.Format("%s (yours)", Money(own)) end
    end

    -- A lone listing far below the rest is not undercut. Say so, or the
    -- dialog disagrees with the auction house the player is looking at.
    local record = ns.Prices:Get(itemID)
    if record and record.ignoredLow then
        lowestText = L.Format("%s (ignored a lone one at %s)", lowestText, Money(record.ignoredLow))
    end

    if check.state == "unavailable" then
        lowestText = L.Format("%s (could not check, last seen)", lowestText)
    end

    -- The price about to go up is the one number that matters, so it is
    -- drawn in gold to stand out from the two it is being compared with.
    local postingText = ("|c%s%s|r"):format(ns.COLORS.accent, Money(unitPrice))
    if quantity > 1 then
        postingText = L.Format("%s each, %d x %s", postingText, quantity, Util.GetItemLabel(itemID))
    else
        postingText = ("%s, %s"):format(postingText, Util.GetItemLabel(itemID))
    end

    local text = L.Format("Average Market Value: %s\nLowest Market Posting: %s\nPosting at: %s",
        marketText, lowestText, postingText)

    -- The one case worth a fifth line: this listing loses gold. Any
    -- character's recipe, so a bank alt listing the crafter's work is told
    -- as well.
    local recipeID = ns.Cost:FindAnyRecipeForItem(itemID)
    local analysis = recipeID and ns.Profit:Analyse(recipeID)
    local unitCost = analysis and analysis.costPerUnit

    if unitCost and unitPrice < unitCost then
        text = text .. "\n|cffE5604F" .. L.Format("Below the %s it cost to make.", Money(unitCost)) .. "|r"
    end

    -- A price the player typed: said so, and how far under market it is,
    -- since that guard stood aside for it.
    if check.byHand then
        local under = (market and market > 0 and unitPrice < market)
            and math.floor((market - unitPrice) / market * 100 + 0.5) or 0
        if under >= 1 then
            text = text .. ("\n|c%s%s|r"):format(ns.COLORS.warn, L.Format("Your own price, %d%% under market value.", under))
        else
            text = text .. "\n" .. L["Your own price."]
        end
    end

    return text .. "\n\n" .. L["List it at this price, or skip it."]
end

-- The item's icon in the confirmation, one texture per popup frame it has
-- been shown in. Kept here rather than written onto the game's frames.
local confirmIcons = setmetatable({}, { __mode = "k" })

-- The question mark icon, for an item whose icon the game has not got yet.
local UNKNOWN_ICON = 134400

-- Narrower than this, the popup did not make room beside its text, and an
-- icon would sit on top of the words.
local WIDE_POPUP = 400

--- Put the item's icon beside the confirmation's text. It is not a line of
--- its own: the four lines stay exactly as they were.
function Posting:ShowConfirmIcon(dialog, itemID)
    if type(dialog) ~= "table" or type(dialog.CreateTexture) ~= "function" then return false end

    local ok, shown = pcall(function()
        local width = dialog:GetWidth()
        if not width or width < WIDE_POPUP then return false end

        local icon = confirmIcons[dialog]
        if not icon then
            icon = dialog:CreateTexture(nil, "OVERLAY", nil, 7)
            confirmIcons[dialog] = icon
        end

        -- Over the alert sign when there is one, so the sign never shows
        -- through; otherwise where it would have been.
        local name = dialog.GetName and dialog:GetName()
        local alert = dialog.AlertIcon or (name and _G[name .. "AlertIcon"])

        icon:ClearAllPoints()
        if type(alert) == "table" and alert.IsShown and alert:IsShown() then
            icon:SetAllPoints(alert)
        else
            icon:SetSize(36, 36)
            icon:SetPoint("LEFT", dialog, "LEFT", 24, 0)
        end

        icon:SetTexture(Util.GetItemIcon(itemID) or UNKNOWN_ICON)
        icon:Show()
        return true
    end)

    return ok and shown or false
end

function Posting:HideConfirmIcon(dialog)
    local icon = dialog and confirmIcons[dialog]
    if icon then pcall(icon.Hide, icon) end
end

function Posting:ShowConfirm(itemID, quantity, unitPrice, text, byHand)
    local confirming = { itemID = itemID, quantity = quantity, unitPrice = unitPrice, byHand = byHand or nil }
    self.confirming = confirming

    local dialog = StaticPopup_Show("BLACKTHORNES_TS_CONFIRM_POST", text, nil, confirming)
    if dialog then
        -- Set again after showing: replacing an open dialog cancels the old
        -- one first, on clients that do not say it was an override.
        self.confirming = confirming
        dialog.data = confirming

        -- Only the dialog now showing carries an icon, whichever frame an
        -- earlier one used.
        for frame in pairs(confirmIcons) do
            if frame ~= dialog then self:HideConfirmIcon(frame) end
        end
        self:ShowConfirmIcon(dialog, itemID)
    else
        self.confirming = nil
        ns.Warn(L["could not open the confirmation dialog; nothing was listed."])
    end
end

--- Search the auction house for one item's price, without listing anything.
--
-- The Post tab offers the whole bag now, and a bag holds things no scan has
-- ever covered: a drop, a gathered stack, something bought this morning. Such
-- a row used to be a dead button beside a tooltip telling the player to go and
-- scan, and on a client that shows no Lua error a button that does nothing
-- looks exactly like a broken one.
--
-- This is the same single-item search the addon already makes immediately
-- before every listing, pointed at the row the player asked about. It never
-- posts: the price lands in the price table and the caller redraws.
--
-- @param onDone  called with (itemID, price, status) once the search settles.
--   status is Scanner's -- "fresh", "recent", "empty", "unavailable" or
--   "superseded". price is nil when nothing is listed and nothing is known.
-- @return true if a search actually went out
function Posting:CheckPrice(itemID, onDone)
    if not itemID then return false end

    local allowed, reason = self:CanPrice()
    if not allowed then
        ns.Print(reason or L["cannot check prices right now"])
        if onDone then onDone(itemID, nil, "unavailable") end
        return false
    end

    ns.Print(L.Format("checking the current price of %s...", self:ListedCopy(itemID) or Util.GetItemLabel(itemID)))

    -- One answer only. A search can settle through the callback, through the
    -- fallback timer, or through both, and reporting twice would redraw the
    -- row underneath a price it had already been drawn with.
    local settled = false

    local function Settle(status)
        if settled then return end
        settled = true

        -- Read the price back after the search, never before. A search that
        -- came back empty has just cleared the rival price, and an empty
        -- auction house is an answer rather than a failure.
        local price = self:GetPostPrice(itemID)

        if onDone then onDone(itemID, price, status) end
    end

    local function OnAnswer(_, _, _, _, _, _, status)
        Settle(status or "fresh")
    end

    C_Timer.After(5, function()
        if settled then return end

        -- The search may still answer after this. It is no longer this
        -- check's answer, so it must not be served as a checked price later.
        ns.Scanner:AbandonItemScan(OnAnswer)

        ns.Warn(L["the price check did not come back."])
        Settle("unavailable")
    end)

    -- quiet: this check says for itself when nothing came back, and the
    -- search's own "using the last known price" is wrong here, with no price.
    local started = ns.Scanner:ScanItem(itemID, OnAnswer,
        { quiet = true, itemKey = self:GetSearchKey(itemID), link = self:ListedCopy(itemID) })

    if not started then Settle("unavailable") end

    return started and true or false
end

--- What one of these cost to make, when `price` is under it and listing at a
--- loss is not allowed; nil when the listing may go ahead on cost.
function Posting:BelowCost(itemID, price)
    if not price or ns.Config:Get("allowPostingAtALoss") == true then return nil end

    -- Any character's recipe, so a bank alt holds back a craft the crafter
    -- mailed it just as the crafter would.
    local recipeID = ns.Cost:FindAnyRecipeForItem(itemID)
    local analysis = recipeID and ns.Profit:Analyse(recipeID)
    local unitCost = analysis and analysis.costPerUnit

    if unitCost and price < unitCost then return unitCost end
    return nil
end

--- What the last craft of one cost, when "Never below what I paid" is on and
--- `price` brings in less than that after the cut; nil otherwise.
-- @return cost, net
function Posting:BelowCraftedCost(itemID, price)
    if not ns.CraftedCost then return nil end
    return ns.CraftedCost:Refuses(itemID, price)
end

--- Say why a listing at `price` would be refused, before any dialog asks
--- about it. Asking "Do you wish to continue?" and refusing after Yes is the
--- same answer, one click later and after a question it had no use for.
-- @return true when it would be refused (and was said)
function Posting:RefusesEarly(itemID, price, byHand)
    -- Under what a vendor pays, or a fraction of market after a dump.
    local floor, why = self:GetPriceFloor(itemID, byHand)
    if floor and price and price < floor then
        ns.Warn(L.Format("not listing %s at %s: %s. Expected at least %s.",
            Util.GetItemLabel(itemID), Util.FormatMoney(price), why or L["the price looks wrong"],
            Util.FormatMoney(floor)))
        return true
    end

    -- Under what the materials cost, with selling at a loss turned off.
    local unitCost = self:BelowCost(itemID, price)
    if unitCost then
        ns.Warn(L.Format("not listing %s at %s, the materials cost %s",
            Util.GetItemLabel(itemID), Util.FormatMoney(price), Util.FormatMoney(unitCost)))
        ns.Warn(L["turn on 'Recommend selling at a loss' in Settings to allow it."])
        return true
    end

    -- Under what the last craft of it cost, with that guard turned on.
    local paid, net = self:BelowCraftedCost(itemID, price)
    if paid then
        ns.Warn(ns.CraftedCost:RefusalText(itemID, price, paid, net) .. ".")
        ns.Warn(L["turn off 'Never below what I paid' in Settings to allow it."])
        return true
    end

    return false
end

--------------------------------------------------------------------------------
-- Fast listing
--------------------------------------------------------------------------------
--
-- Asked 2026-10-14: "can we speed up the posting speed on the AH instead of
-- waiting 5 seconds". The wait was ours: every click searched for its one
-- item, waited for the answer, then asked Yes or No, and the Yes was the
-- click that listed. Now one search checks every price on the Sell list,
-- and while an item's price is fresh (FRESH_FOR) its click lists it at once.
-- Every guard Post has still runs, and each listing is still read back.

--- Is fast listing on? On unless unticked.
function Posting:FastListing()
    return ns.Config:Get("fastListing") ~= false
end

--- The auction house has just told us what this item sells for.
-- @param itemKey optional: the key searched. A search for one random suffix
--   ("of the Monkey") is not the price of the plain item, so it is not kept.
function Posting:NoteChecked(itemID, itemKey)
    if not itemID then return end
    if type(itemKey) == "table" and (tonumber(itemKey.itemSuffix) or 0) ~= 0 then return end
    if type(rawget(self, "checkedAt")) ~= "table" then self.checkedAt = {} end
    self.checkedAt[itemID] = GetTime()
end

--- Was this item's price checked recently enough to list on the click?
function Posting:IsFresh(itemID)
    local checked = rawget(self, "checkedAt")
    local at = type(checked) == "table" and itemID and checked[itemID]
    return type(at) == "number" and (GetTime() - at) <= FRESH_FOR
end

--- Forget every check: the auction house closed, and prices move while away.
function Posting:ForgetChecks()
    self.checkedAt = {}
    self.bulkTried = {}
    self.checkAll = nil
end

--- Was this item in a search of the whole list lately? Then one that came
--- back without its price is searched for alone, not asked about again.
function Posting:BulkTried(itemID)
    local tried = rawget(self, "bulkTried")
    local at = type(tried) == "table" and itemID and tried[itemID]
    return type(at) == "number" and (GetTime() - at) <= FRESH_FOR
end

--- The cheapest price from someone else in one browse row, or nil when the
--- row cannot say. A row holding one of yours at its lowest price may be
--- yours alone; only your own listings being dearer settles it.
function Posting.RivalFromRow(itemID, price, ownerFlag)
    if type(price) ~= "number" or price <= 0 then return nil end
    if ownerFlag ~= true then return price end

    local own = ns.Auctions and ns.Auctions.GetOwnMinPrice and ns.Auctions:GetOwnMinPrice(itemID) or nil
    if type(own) == "number" and own > price then return price end
    return nil
end

--- Would List Next's click on this line only check prices? The same test
--- PostPanel:ListNext makes before it calls CheckAll, and the same reasons
--- CheckAll would not start, so the button can say so before the click.
function Posting:WouldCheckAll(line, lines)
    if not (line and line.itemID) then return false end
    if not self:FastListing() then return false end
    if self:IsFresh(line.itemID) then return false end
    if self:CheckingAll() then return true end
    if self:BulkTried(line.itemID) then return false end
    if ns.Config:Get("verifyPriceBeforePosting") == false then return false end

    local scanner = ns.Scanner
    if not (scanner and scanner.isAuctionHouseOpen) or scanner.isScanning then return false end
    if not self.IsLegacy() and not (Util.HasFunction("C_AuctionHouse.SearchForItemKeys")
            and Util.HasFunction("C_AuctionHouse.MakeItemKey")) then
        return false
    end

    for _, other in ipairs(lines or {}) do
        if other.itemID and not other.link and not self:IsFresh(other.itemID) then return true end
    end
    return false
end

--- Check every price on a list in one search.
--
-- The game's search for several items at once (SearchForItemKeys) answers
-- with the cheapest listing of each, the way Search all does on the Buy
-- view. One request instead of one a listing, and the clicks after it list
-- straight away. Items with a random suffix are left out: one copy's price
-- is not another's.
-- @return true and how many were asked about, or false and why
function Posting:CheckAll(lines)
    local scanner = ns.Scanner
    if not (scanner and scanner.isAuctionHouseOpen) then
        return false, L["the auction house must be open"]
    end
    if scanner.isScanning then return false, L["wait for the scan to finish"] end
    if self.IsLegacy() then return self:CheckAllLegacy(lines) end
    if not (Util.HasFunction("C_AuctionHouse.SearchForItemKeys")
            and Util.HasFunction("C_AuctionHouse.MakeItemKey")) then
        return false
    end

    local keys, wanted = {}, {}
    for _, line in ipairs(lines or {}) do
        local itemID = line.itemID
        if itemID and not line.link and not wanted[itemID] and not self:IsFresh(itemID) then
            local ok, key = pcall(C_AuctionHouse.MakeItemKey, itemID)
            if ok and type(key) == "table" then
                keys[#keys + 1] = key
                wanted[itemID] = true
            end
            if #keys >= CHECK_ALL_MOST then break end
        end
    end
    if #keys == 0 then return false end

    local check = { wanted = wanted, count = #keys, found = 0 }
    self.checkAll = check

    if type(rawget(self, "bulkTried")) ~= "table" then self.bulkTried = {} end
    local now = GetTime()
    for itemID in pairs(wanted) do self.bulkTried[itemID] = now end

    ns.AHQueue:Request({
        name = ("price check for %d items"):format(#keys),
        key = "price-check-all",
        priority = ns.AHQueue.PRIORITY.urgent,
        expires = 8,
        send = function()
            if rawget(Posting, "checkAll") ~= check then return true end
            if not pcall(C_AuctionHouse.SearchForItemKeys, keys, {}) then
                Posting.checkAll = nil
                ns.Warn(L["the game refused the search"])
                return false
            end
            check.sentAt = GetTime()
            return true
        end,
        onGiveUp = function()
            if rawget(Posting, "checkAll") == check then Posting.checkAll = nil end
        end,
    })

    return true, #keys
end

-- Era: how long one item's check may take before the next goes out.
local LEGACY_CHECK_WAIT = 6

--- Is Era's check of the whole list still going, one item at a time?
function Posting:CheckingAll()
    local check = rawget(self, "checkAll")
    return type(check) == "table" and check.legacy == true
end

--- CheckAll on Era's older auction house, which searches one item at a
--- time. Each item on the list is searched by name in turn, and each answer
--- marks it checked (Scanner:FinishItemScan), so the clicks after it list
--- straight away with no Yes/No box. One check up front, then one listing a
--- click.
-- @return true and how many were asked about, or false
function Posting:CheckAllLegacy(lines)
    if self:CheckingAll() then
        local running = self.checkAll
        return true, running.count, true
    end

    local queue, wanted = {}, {}
    for _, line in ipairs(lines or {}) do
        local itemID = line.itemID
        if itemID and not line.link and not wanted[itemID] and not self:IsFresh(itemID) then
            queue[#queue + 1] = itemID
            wanted[itemID] = true
            if #queue >= CHECK_ALL_MOST then break end
        end
    end
    if #queue == 0 then return false end

    local check = { wanted = wanted, queue = queue, count = #queue, found = 0, legacy = true }
    self.checkAll = check

    if type(rawget(self, "bulkTried")) ~= "table" then self.bulkTried = {} end
    local now = GetTime()
    for itemID in pairs(wanted) do self.bulkTried[itemID] = now end

    local function Redraw()
        if ns.PostPanel and ns.PostPanel.Refresh then pcall(ns.PostPanel.Refresh, ns.PostPanel) end
    end

    local Next
    Next = function()
        if rawget(Posting, "checkAll") ~= check then return end

        local scanner = ns.Scanner
        if not (scanner and scanner.isAuctionHouseOpen) or scanner.isScanning then
            Posting.checkAll = nil
            Redraw()
            return
        end

        local itemID = table.remove(check.queue, 1)
        if not itemID then
            Posting.checkAll = nil
            if check.found > 0 then
                ns.Print(L.Format("checked the prices of %d items. Each click on List all now lists one.", check.found))
            end
            Posting:PrepareNext()
            if ns.UI and ns.UI.RefreshActiveTab then pcall(ns.UI.RefreshActiveTab, ns.UI) end
            Redraw()
            return
        end

        local done = false
        local function OnAnswer()
            if done then return end
            done = true
            if Posting:IsFresh(itemID) then check.found = check.found + 1 end
            check.wanted[itemID] = nil
            Redraw()
            C_Timer.After(0, Next)
        end

        C_Timer.After(LEGACY_CHECK_WAIT, function()
            if done then return end
            ns.Scanner:AbandonItemScan(OnAnswer)
            done = true
            Next()
        end)

        if not ns.Scanner:ScanItem(itemID, OnAnswer, { quiet = true, link = Posting:ListedCopy(itemID) }) then
            done = true
            C_Timer.After(0.2, Next)
        end
    end

    Next()
    return true, check.count
end

--- Browse results came in that the scanner did not ask for: read the ones
--- a CheckAll is waiting on. Called from Scanner:OnBrowseResults.
-- @return how many items it found a fresh price for
function Posting:OnCheckResults()
    local check = rawget(self, "checkAll")
    if type(check) ~= "table" or not check.sentAt then return 0 end
    if GetTime() - check.sentAt > CHECK_ALL_WAIT then
        self.checkAll = nil
        return 0
    end
    if not Util.HasFunction("C_AuctionHouse.GetBrowseResults") then return 0 end

    local ok, results = pcall(C_AuctionHouse.GetBrowseResults)
    if not ok or type(results) ~= "table" then return 0 end

    -- An item's rows taken together: the cheapest of them, and whether the
    -- game marked that cheapest as holding one of yours.
    local byItem = {}
    for _, row in ipairs(results) do
        local key = type(row) == "table" and row.itemKey
        local itemID = type(key) == "table" and key.itemID
        local price = row and row.minPrice
        if itemID and check.wanted[itemID] and (tonumber(key.itemSuffix) or 0) == 0
                and type(price) == "number" and price > 0 then
            local item = byItem[itemID]
            if not item then
                item = { price = price, owner = row.containsOwnerItem, quantity = 0 }
                byItem[itemID] = item
            elseif price < item.price then
                item.price, item.owner = price, row.containsOwnerItem
            end
            item.quantity = item.quantity + (tonumber(row.totalQuantity) or 0)
        end
    end

    local found = 0
    for itemID, item in pairs(byItem) do
        local rival = self.RivalFromRow(itemID, item.price, item.owner)
        local market = ns.Prices.GetScanValue and ns.Prices:GetScanValue(itemID, "market")
            or ns.Prices:GetValue(itemID, "market")
        local credible = not ns.Prices.IsCredible or ns.Prices.IsCredible(item.price)

        -- Only a price a single search would not read differently: someone
        -- else's, not far under the usual (a lone low one is that search's
        -- to judge), and the item seen before, so there is a usual at all.
        if rival and credible and type(market) == "number" and market > 0
                and rival >= market * CHECK_ALL_FAR_UNDER then
            local own = item.owner == true and ns.Auctions and ns.Auctions.GetOwnMinPrice
                and ns.Auctions:GetOwnMinPrice(itemID) or nil
            -- Recorded as a search the player made would be; the same
            -- reading again (passive capture got there first) is kept once.
            ns.Scanner:RecordPassive(itemID, item.price, item.price, item.quantity, rival, own)
            self:NoteChecked(itemID)
            check.wanted[itemID] = nil
            found = found + 1
        end
    end

    if found > 0 then
        check.found = (check.found or 0) + found
        if ns.Persist and ns.Persist.SaveLater then ns.Persist:SaveLater() end
        if ns.UI and ns.UI.RefreshActiveTab then pcall(ns.UI.RefreshActiveTab, ns.UI) end
        if ns.PostPanel and ns.PostPanel.Refresh then pcall(ns.PostPanel.Refresh, ns.PostPanel) end
    end

    if not check.told and (check.found or 0) > 0 then
        check.told = true
        ns.Print(L.Format("checked the prices of %d items. Each click on List all now lists one.", check.found))
    end

    return found
end

--- List this item on this click, without the Yes/No box? Only while its
--- price is fresh and it is not a copy with a random suffix. A listing under
--- what it cost to make asks first only while selling at a loss is off
--- (the owner, 2026-10-28: ticking it is the player saying yes to losses).
function Posting:CanListOnClick(itemID, price)
    if not self:FastListing() then return false end
    if not (ns.Scanner and ns.Scanner.isAuctionHouseOpen) then return false end
    if not self:IsFresh(itemID) then return false end
    if self:GetSearchKey(itemID) then return false end

    if ns.Config:Get("allowPostingAtALoss") ~= true then
        local recipeID = ns.Cost:FindAnyRecipeForItem(itemID)
        local analysis = recipeID and ns.Profit:Analyse(recipeID)
        local unitCost = analysis and analysis.costPerUnit
        if unitCost and price and price < unitCost then return false end
    end

    return true
end

--- Check the current price, then ask, then post. This is what the buttons call.
--
-- The price check is a real auction house search for this one item, not a
-- reading of the last full scan. A snapshot is minutes old by the time you
-- act on it, and undercutting a price that has since moved lists you above
-- the rival you were trying to beat.
--
-- The search is asynchronous and posting needs a hardware event, so the
-- confirmation click is what actually creates the listing. That ordering is
-- deliberate: search, show the fresh number, and let the click commit it.
function Posting:Request(itemID, quantity, unitPrice)
    local allowed, reason = self:CanPost(itemID)
    if not allowed then
        ns.Print(reason or L["cannot post right now"])
        return false
    end

    quantity = quantity or 1

    -- A price the player set in the price editor is the one listed, checked
    -- or not: the check only brings the market figures up to date beside it.
    local chosen = self:GetChosenPrice(itemID)
    if chosen then
        unitPrice = self:NormalisePrice(chosen, ns.Scanner:IsCommodity(itemID))
    end
    unitPrice = unitPrice or self:GetPostPrice(itemID) or 0

    -- Fast listing: the price was checked moments ago, so this click lists
    -- it, read back from the check rather than the number the row was drawn
    -- with. Post refuses anything the box would have (CanPost, the floors,
    -- the costs), and says why.
    local fastPrice = chosen and unitPrice or self:GetPostPrice(itemID) or unitPrice
    if self:CanListOnClick(itemID, fastPrice) then
        if self:RefusesEarly(itemID, fastPrice, chosen ~= nil) then return false end
        return self:Post(itemID, quantity, fastPrice, chosen ~= nil) and true or false
    end

    local verify = ns.Config:Get("verifyPriceBeforePosting") ~= false

    if not verify or not ns.Scanner.isAuctionHouseOpen then
        if self:RefusesEarly(itemID, unitPrice, chosen ~= nil) then return false end
        -- No check to wait for, so this click can list it (the owner,
        -- 2026-10-28). Fast listing unticked brings the box back.
        if self:FastListing() and ns.Scanner.isAuctionHouseOpen then
            return self:Post(itemID, quantity, unitPrice, chosen ~= nil) and true or false
        end
        self:Confirm(itemID, quantity, unitPrice, { byHand = chosen ~= nil })
        return true
    end

    -- An earlier click on this item is still waiting for its check, which
    -- brings up the box when it answers. Quick clicks while it is out add
    -- nothing: on Era each one was another search of the auction house,
    -- and a run of them kept it busy and listed nothing.
    self.requesting = self.requesting or {}
    if Posting.IsLegacy() and (self.requesting[itemID] or 0) > 0 then return true end

    ns.Print(L.Format("checking the current price of %s...", self:ListedCopy(itemID) or Util.GetItemLabel(itemID)))

    -- Whether an earlier click on this item is still waiting for its check.
    -- Only then is a "recent" answer already on its way to a dialog; the
    -- search still out may be anybody's (a scan's follow-up, a deep scan).
    local alreadyAsking = (self.requesting[itemID] or 0) > 0
    self.requesting[itemID] = (self.requesting[itemID] or 0) + 1

    -- A search that never answers must not leave the click doing nothing, so
    -- fall back to the price we already had and say that is what happened.
    local settled = false

    local function Proceed(state)
        if settled then return end
        settled = true
        Posting.requesting[itemID] = math.max(0, (Posting.requesting[itemID] or 1) - 1)

        -- Another search took the slot before this one answered, so the
        -- price was never checked. Verifying is on, so nothing is listed on
        -- an unchecked number; the click is cheap to repeat.
        if state == "superseded" then
            -- Taken over by a newer click on this same item, whose check is
            -- still out and will bring up the dialog itself. Saying "click
            -- it again" then was wrong, with the dialog about to appear.
            if (Posting.requesting[itemID] or 0) > 0 then return end

            ns.Print(L.Format("the price check for %s was interrupted by another search; nothing was listed. Click it again.",
                Util.GetItemLabel(itemID)))
            return
        end

        -- The auction house closed while the check was out. A listing can
        -- only be made there, and a confirm popping up after walking away
        -- asks about something that cannot happen.
        if ns.Scanner.isAuctionHouseOpen == false then
            ns.Print(L.Format("the auction house closed before the price check for %s came back; nothing was listed.",
                Util.GetItemLabel(itemID)))
            return
        end

        -- A second click while this item's search is still out. That search
        -- will bring up the dialog when it answers; showing one now would be
        -- at the price from before the check, and then a second dialog for
        -- the same item would follow it.
        if state == "recent" and alreadyAsking then
            local pending = ns.Scanner.pendingItem
            if pending and pending.itemID == itemID then return end
        end

        -- Read the price back after the check, never before. A search that
        -- found nothing has just cleared the rival price, and this is where
        -- that becomes a listing at market value instead of an undercut of
        -- a seller who is not there.
        local price = self:GetPostPrice(itemID) or unitPrice
        if chosen then price = unitPrice end

        -- A price the listing step will refuse (under what a vendor pays, a
        -- fraction of market after a rival's dump, or under what it cost to
        -- make) is said now rather than after Yes.
        if self:RefusesEarly(itemID, price, chosen ~= nil) then return end

        -- Fast listing (the owner, 2026-10-28): the check came back, so the
        -- next click lists it with no Yes/No box. Listing needs a real
        -- click, and this answer came later on its own. A check that did
        -- not leave the price fresh (no answer, a random suffix) still asks.
        if self:CanListOnClick(itemID, price) then
            -- Era: the stack goes in the auction slot now, so that next
            -- click is the one that lists it.
            if Posting.IsLegacy() then self:PrepareFor(itemID) end
            ns.Print(L.Format("%s is ready to list. Click again to list it.",
                self:ListedCopy(itemID) or Util.GetItemLabel(itemID)))
            if ns.PostPanel and ns.PostPanel.Refresh then pcall(ns.PostPanel.Refresh, ns.PostPanel) end
            return
        end

        self:Confirm(itemID, quantity, price, { state = state, byHand = chosen ~= nil })
    end

    local function OnAnswer(_, _, _, _, _, _, status)
        Proceed(status or "fresh")
    end

    C_Timer.After(5, function()
        if settled then return end

        -- The search can still answer for up to three more seconds. By then
        -- the confirm is up at the last known price, so that answer is not
        -- this click's any more: no second warning when it gives up, and not
        -- a "recent" check that would let the next click skip searching.
        ns.Scanner:AbandonItemScan(OnAnswer)

        if ns.Scanner.isAuctionHouseOpen == false then
            Proceed("closed")
            return
        end

        ns.Warn(L["the price check did not come back; using the last known price."])
        Proceed("unavailable")
    end)

    local started = ns.Scanner:ScanItem(itemID, OnAnswer,
        { itemKey = self:GetSearchKey(itemID), link = self:ListedCopy(itemID) })

    if not started then
        Proceed("unavailable")
    end

    return true
end

--------------------------------------------------------------------------------
-- Verification
--------------------------------------------------------------------------------

--- Ask what we actually own, rather than guessing from the absence of an event.
-- @param target the listing whose timer ran; the newest when not given.
function Posting:VerifyPending(target)
    target = target or self.pending
    if not target or target.verifying then return end

    -- Another copy was listed since this timer was set: it replaced this one,
    -- and that listing's own timer checks them both.
    if not self:IsPending(target) then return end
    if GetTime() - (target.startedAt or 0) < POST_VERIFY_DELAY - 0.05 then return end

    -- A newer listing whose own read back is moments away reads this one
    -- too (a read settles every listing made before it went out), so a run
    -- of quick listings costs one request, not one each.
    local share = self:ShareVerify(target)
    if share then
        C_Timer.After(share, function() Posting:VerifyPending(target) end)
        return
    end

    -- An attempt older than this has already given up; leaving it in place lets
    -- an unrelated auction be mistaken for it.
    if (GetTime() - (target.startedAt or 0)) > 60 then
        self:DropPending(target)
        return
    end

    target.verifying = true

    -- Readings from a query sent before this listing existed must not settle
    -- it: a read-back still running from another item's check would report
    -- this one as missing. It waits for the next query to go out
    -- (Auctions:ScheduleConfirm clears this), and other items' checks run on.
    target.awaiting = true

    -- A newer listing's read is already asked for: it goes out after this
    -- listing was made, so it settles this one too, and no second read is
    -- spent. Out already, it is good for this one as it stands.
    local riding = self:NewerVerifying(target)
    if riding then
        target.awaiting = riding.awaiting
    else
        ns.Auctions:Refresh({ priority = ns.AHQueue.PRIORITY.urgent, force = true })
    end

    -- This listing's own give-up: another listing being verified when the
    -- timer runs is not this one, and must not be settled by it.
    local token = target

    -- Refresh reads the answer back itself once the query goes out, so this is
    -- no longer the thing that settles a listing: it is the backstop for a query
    -- that never went out at all, which is the one case where "could not tell"
    -- is the honest answer. It has to outlast the queue's own wait, or a slow
    -- send gets reported as a failure while the reading is still on its way.
    C_Timer.After(VERIFY_GIVE_UP, function()
        if Posting:IsPending(token) and token.verifying then
            Posting:ResolvePending(nil, nil, token)
        end
    end)
end

--- How long this listing's read back should wait for a newer listing's,
--- or nil to read now.
function Posting:ShareVerify(target)
    local now = GetTime()
    local latest = (target.startedAt or 0) + POST_VERIFY_DELAY + VERIFY_SHARE_MOST
    if now >= latest then return nil end

    local due
    for _, other in ipairs(self:AllPending()) do
        if other ~= target and not other.verifying
                and (other.startedAt or 0) > (target.startedAt or 0) then
            local at = (other.startedAt or 0) + POST_VERIFY_DELAY
            if at > now and at - now <= VERIFY_SHARE and (not due or at > due) then due = at end
        end
    end
    if not due then return nil end

    -- Just after the newer one's, so its read is the one queued.
    return math.min(due, latest) - now + 0.05
end

--- A listing made after this one whose read back is already asked for.
function Posting:NewerVerifying(target)
    for _, other in ipairs(self:AllPending()) do
        if other ~= target and other.verifying
                and (other.startedAt or 0) > (target.startedAt or 0) then
            return other
        end
    end
end

--- Called once the owned-auction list has been re-read.
-- @param posted number now listed, or nil if that could not be determined
-- @param appeared true when a listing of the item not there before was seen
-- @param target the listing settled; the newest when not given
function Posting:ResolvePending(posted, appeared, target)
    local pending = target or self.pending
    if not pending then return end

    self:DropPending(pending)

    -- Several auctions in one go, from one click (CanPostMany) or copies
    -- listed back to back: how many went up. One of several from one click
    -- means the auction house took only the first, so the rest go one per
    -- click. A commodity's quantity is one auction, so it is not counted.
    local several = (pending.quantity or 1) > 1 and not pending.isCommodity
    local gained = posted and (posted - (pending.postedBefore or 0)) or 0
    local refused = false
    if pending.many and not pending.joined and posted and pending.idsBefore
        and gained < pending.quantity and gained <= 1 then
        if type(self.manyRefused) ~= "table" then self.manyRefused = {} end
        self.manyRefused[pending.itemID] = true
        refused = true
    end

    -- What went up, for Keep in stock's sell-out raise (Logic/SellOut.lua).
    local went
    if several and posted and gained >= pending.quantity then went = pending.quantity
    elseif several and posted and gained > 0 then went = gained
    elseif not several and posted and (appeared or posted > (pending.postedBefore or 0)) then
        went = pending.quantity or 1
    end
    if went and ns.SellOut then
        pcall(ns.SellOut.NotePosted, ns.SellOut, pending.itemID, went, Posting:DurationFor(pending.itemID))
    end
    if went and ns.StatsLog then
        -- A commodity goes up as one auction, however many units it holds.
        pcall(ns.StatsLog.NotePosted, ns.StatsLog, pending.itemID, pending.isCommodity and 1 or went)
    end

    if several and posted and gained >= pending.quantity then
        ns.Print(L.Format("listed %d x %s", pending.quantity, Util.GetItemLabel(pending.itemID)))

    elseif several and posted and posted > 0 and not pending.idsBefore then
        -- Measured against last visit's count (see below), so a shortfall
        -- may only be listings that sold since. Nothing is concluded from it.
        ns.Print(L.Format("%s: you have %d listed now. This was the first check since the auction house opened, so the new listings could not be told apart from older ones.",
            Util.GetItemLabel(pending.itemID), posted))

    elseif several and posted and gained > 0 then
        ns.Print(L.Format("listed %d of %d x %s.", gained, pending.quantity, Util.GetItemLabel(pending.itemID)))
        if refused then
            ns.Print(L["the auction house took one at a time, so the rest go up one per click."])
        end

    elseif posted and (appeared or posted > (pending.postedBefore or 0)) then
        ns.Print(L.Format("listed %s", Util.GetItemLabel(pending.itemID)))

    elseif posted and posted > 0 and not pending.idsBefore then
        -- Listed before your auctions had been read this visit, so the count
        -- it is measured against is from last time. Listings that sold since
        -- then made a good listing read as missing. What is there can only be
        -- reported, not told apart.
        ns.Print(L.Format("%s: you have %d listed now. This was the first check since the auction house opened, so the new listing could not be told apart from older ones.",
            Util.GetItemLabel(pending.itemID), posted))

    elseif posted then
        -- The server answered and it is not there: it genuinely did not go up.
        ns.Warn(L.Format("%s did not appear in your auctions.",
            Util.GetItemLabel(pending.itemID)))
        if pending.many and not pending.joined then
            ns.Warn(L["listing several at once may not work here, so the next click lists one."])
        else
            ns.Warn(L["Nothing was listed. Click it again to try once more."])
        end
    else
        ns.Warn(L["could not tell whether that listing went up. Check your Auctions tab"])
    end

    -- Era: another copy of this item waited while this one was confirmed
    -- (a second pair of boots); it goes in now, so the next click lists it.
    if Posting.IsLegacy() then self:PrepareNext() end

    if ns.UI then
        ns.UI:RefreshActiveTab()
        ns.UI:UpdatePostButton()
    end
end

--- Sample the auction house throttle over a few seconds.
--
-- Posting blocks while the throttle says it is busy, so if this client never
-- reports ready that block is a bug on our side rather than a real wait.
ns.RegisterCommand("throttle", L["check how often the auction house is ready for requests"], function()
    ns.AHQueue:Report()

    if not ns.Util.HasFunction("C_AuctionHouse.IsThrottledMessageSystemReady") then
        ns.Print("the game gives no busy signal here; requests are just spaced out over time.")
        return
    end

    ns.Print("watching whether the auction house is busy for 10s...")

    local samples, ready = 0, 0

    local ticker
    ticker = C_Timer.NewTicker(0.5, function()
        samples = samples + 1

        local ok, isReady = pcall(C_AuctionHouse.IsThrottledMessageSystemReady)
        if ok and isReady then ready = ready + 1 end

        if samples >= 20 then
            ticker:Cancel()

            ns.Print(("the auction house was ready %d of %d times over 10s."):format(ready, samples))

            if ready == 0 then
                ns.Warn("never ready, so posting would always be blocked. Please report this so the addon stops waiting on it.")
            end
        end
    end)
end)

--- Attempt one listing and report every step, including the raw return value.
--
-- Exists because "prints a message but nothing happens" has several different
-- causes that look identical from the chat frame: the call being refused, the
-- call succeeding but the server dropping it, or the listing genuinely being
-- created and the addon failing to notice.
ns.RegisterCommand("posttest", L["try one listing and show every step: /bts posttest [name]"], function(args)
    local line

    if args and args ~= "" then
        local needle = args:lower()

        for _, candidate in ipairs(ns.Posting:GetPostable({ includeAll = true })) do
            if (candidate.label or ""):lower():find(needle, 1, true) then
                line = candidate
                break
            end
        end

        if not line then
            ns.Print(("nothing sellable matching '%s'."):format(args))
            return
        end
    else
        line = ns.Posting:GetNextPostable({ includeAll = true })
    end

    if not line then
        ns.Print("nothing in your bags with a known price to test with.")
        return
    end

    local itemID, quantity, unitPrice = line.itemID, line.postQuantity, line.unitPrice

    ns.Print("posttest build 3")
    ns.Print(("posttest: %s x%d at %s"):format(
        Util.GetItemLabel(itemID), quantity, Util.FormatMoney(unitPrice)))

    local allowed, reason = ns.Posting:CanPost()
    ns.PrintRaw(("  can post: %s%s"):format(tostring(allowed),
        allowed and "" or (" (" .. tostring(reason) .. ")")))
    ns.PrintRaw(("  throttled: %s"):format(tostring(ns.Posting:IsThrottled())))

    local sellable, available = ns.Posting:GetSellInfo(itemID)
    ns.PrintRaw(("  sellable: %s, available: %s"):format(
        tostring(sellable), tostring(available)))

    local isCommodity = ns.Scanner:IsCommodity(itemID)
    ns.PrintRaw(("  commodity: %s"):format(tostring(isCommodity)))

    -- The value we compare against. A status that reads 2 while the enum
    -- calls Commodity something else would classify everything wrongly.
    if Enum and Enum.ItemCommodityStatus then
        local names = {}
        for key, value in pairs(Enum.ItemCommodityStatus) do
            names[#names + 1] = ("%s=%s"):format(tostring(key), tostring(value))
        end
        table.sort(names)
        ns.PrintRaw(("  enum: %s"):format(table.concat(names, " ")))
    else
        ns.PrintRaw("  enum: Enum.ItemCommodityStatus missing")
    end

    -- Where that answer comes from. If these functions are missing, every
    -- item reads as "not a commodity" and the wrong post call gets used.
    -- The usage message says this takes an "item", which could be an ID, a
    -- link, or an ItemLocation. Rather than guess again, try each and report
    -- which one the client accepts.
    if Util.HasFunction("C_AuctionHouse.GetItemCommodityStatus") then
        local bagID, slotID = FindInBags(itemID)

        local candidates = {
            { "itemID", itemID },
            { "link", select(2, pcall(C_Item.GetItemInfo, itemID)) },
            { "location", bagID and MakeLocation(bagID, slotID) },
            { "itemKey", Util.HasFunction("C_AuctionHouse.MakeItemKey")
                and select(2, pcall(C_AuctionHouse.MakeItemKey, itemID)) or nil },
        }

        for _, candidate in ipairs(candidates) do
            local label, value = candidate[1], candidate[2]

            if value == nil then
                ns.PrintRaw(("  status(%s): not available"):format(label))
            else
                local statusOk, status = pcall(C_AuctionHouse.GetItemCommodityStatus, value)

                ns.PrintRaw(("  status(%s): ok=%s value=%s"):format(
                    label, tostring(statusOk),
                    tostring(status):gsub("Usage:.*", "Usage omitted")))
            end
        end
    end

    local bag, slot = FindInBags(itemID)
    local location = bag and MakeLocation(bag, slot)
    ns.PrintRaw(("  bag %s slot %s, location: %s"):format(
        tostring(bag), tostring(slot), location and "made" or "nil"))

    if not location then return end

    -- What the auction house itself says about this exact slot, before we
    -- ask it to list anything.
    if Util.HasFunction("C_AuctionHouse.IsSellItemValid") then
        local validOk, valid, err = pcall(C_AuctionHouse.IsSellItemValid, location, true)
        ns.PrintRaw(("  IsSellItemValid: ok=%s valid=%s err=%s"):format(
            tostring(validOk), tostring(valid), tostring(err)))
    end

    if Util.HasFunction("C_AuctionHouse.GetAvailablePostCount") then
        local countOk, postable = pcall(C_AuctionHouse.GetAvailablePostCount, location)
        ns.PrintRaw(("  GetAvailablePostCount: ok=%s value=%s"):format(
            tostring(countOk), tostring(postable)))
    end

    -- The two deposit calls do not agree on their first argument: the
    -- commodity one takes an item ID, the item one takes a location.
    local depositFn = isCommodity and "CalculateCommodityDeposit" or "CalculateItemDeposit"
    if Util.HasFunction("C_AuctionHouse." .. depositFn) then
        local subject = isCommodity and itemID or location

        local depOk, deposit = pcall(C_AuctionHouse[depositFn], subject,
            ns.Config:Get("postDuration") or 2, quantity)

        ns.PrintRaw(("  %s: ok=%s value=%s"):format(
            depositFn, tostring(depOk),
            tostring(deposit):gsub("Usage:.*", "Usage omitted")))
    end

    local before = ns.Auctions:GetOwnPostedCount(itemID)
    ns.PrintRaw(("  listed before: %d"):format(before))

    local duration = ns.Config:Get("postDuration") or 2

    local ok, returned
    if isCommodity then
        ok, returned = pcall(C_AuctionHouse.PostCommodity, location, duration, quantity, unitPrice)
    else
        ok, returned = pcall(C_AuctionHouse.PostItem, location, duration, quantity, unitPrice, unitPrice)
    end

    -- The distinction that matters: an error means the call was refused, a
    -- false return means the auction house declined, and nil usually means
    -- it accepted.
    ns.PrintRaw(("  call: ok=%s  returned=%s (%s)"):format(
        tostring(ok), tostring(returned), type(returned)))

    C_Timer.After(4, function()
        ns.Auctions:Refresh()

        C_Timer.After(2, function()
            local after = ns.Auctions:GetOwnPostedCount(itemID)

            ns.PrintRaw(("  listed after: %d"):format(after))

            if after > before then
                ns.Print("|cff4FD18Bthe listing was created.|r")
            else
                ns.Print("|cffE5604Fnothing was listed, the server refused it.|r")
            end
        end)
    end)
end)

--- Ask the client what arguments its auction functions expect.
--
-- A call with no arguments fails with a usage string naming the real
-- signature. That is how the commodity-status call was found to want an
-- ItemLocation rather than an item ID, after three wrong guesses.
--
-- Creates nothing: every call here is designed to fail.
ns.RegisterCommand("sig", L["show which auction functions this version of the game has"], function()
    -- PostItem and PostCommodity are deliberately absent. Calling them at all
    -- outside a real click trips "Interface action failed because of an
    -- AddOn", so probing their signature costs a scary red error for a string
    -- we already have: PostItem(item, duration, quantity [, bid, buyout]).
    local names = {
        "CalculateItemDeposit", "CalculateCommodityDeposit",
        "GetItemCommodityStatus", "IsSellItemValid", "GetAvailablePostCount",
        "MakeItemKey", "IsThrottledMessageSystemReady",
    }

    ns.Print("auction functions")

    -- The Classic posting path, which may be what item auctions still want.
    local legacy = {}
    for _, name in ipairs({ "PostAuction", "StartAuction", "ClickAuctionSellItemButton",
        "GetAuctionSellItemInfo", "CalculateAuctionDeposit", "PickupContainerItem" }) do
        local present = type(_G[name]) == "function"
            or (name == "PickupContainerItem" and C_Container
                and type(C_Container.PickupContainerItem) == "function")

        legacy[#legacy + 1] = ("%s=%s"):format(name, present and "yes" or "no")
    end
    ns.PrintRaw(("  |cffC8A44Dold-style|r %s"):format(table.concat(legacy, " ")))

    for _, name in ipairs(names) do
        if not Util.HasFunction("C_AuctionHouse." .. name) then
            ns.PrintRaw(("  %s: |cffE5604Fmissing|r"):format(name))
        else
            local ok, err = pcall(C_AuctionHouse[name])

            if ok then
                ns.PrintRaw(("  %s: accepted no arguments"):format(name))
            else
                -- The usage line is the part worth reading; the file and line
                -- prefix is noise.
                local usage = tostring(err)
                    :gsub("^.-Usage:%s*", "")
                    :gsub("^.-:%d+:%s*", "")

                ns.PrintRaw(("  |cffC8A44D%s|r: %s"):format(name, usage))
            end
        end
    end
end)

--- Try one specific PostItem argument shape, and report whether it listed.
--
-- Blizzard's own Sell tab lists this item; our call with apparently the same
-- data is refused. So the difference is in how the arguments are passed, and
-- guessing has already been wrong twice. This walks the plausible shapes one
-- click at a time.
--
-- A slash command counts as a hardware event, which is why this can post at
-- all. It stops as soon as one works.
local POST_VARIANTS = {
    { name = "bid nil, buyout set",
      build = function(price) return nil, price end },

    { name = "bid = buyout",
      build = function(price) return price, price end },

    { name = "bid only, no buyout",
      build = function(price) return price, nil end },

    { name = "bid 1c under buyout",
      build = function(price) return math.max(1, price - 1), price end },

    { name = "no prices at all",
      build = function() return nil, nil end },

    { name = "the old Classic way: sell slot, then StartAuction",
      legacy = true,
      build = function(price) return price, price end },
}

--- The Classic way: put the item in the auction slot, then start the auction.
--
-- Forever is Classic content on the modern API, and the two posting paths may
-- not have been unified. Commodities demonstrably work through PostCommodity;
-- item auctions may still expect this.
local function TryLegacyPost(bagID, slotID, bid, buyout, duration)
    local missing = {}

    for _, name in ipairs({ "ClickAuctionSellItemButton", "StartAuction" }) do
        if type(_G[name]) ~= "function" then missing[#missing + 1] = name end
    end

    local pickup = C_Container and C_Container.PickupContainerItem or _G.PickupContainerItem
    if type(pickup) ~= "function" then missing[#missing + 1] = "PickupContainerItem" end

    if #missing > 0 then
        return false, "this version of the game has no " .. table.concat(missing, ", ")
    end

    -- Anything already on the cursor would be put into the slot instead.
    pcall(ClearCursor)

    local pickedUp = pcall(pickup, bagID, slotID)
    if not pickedUp then
        pcall(ClearCursor)
        return false, "could not pick the item up"
    end

    local clicked = pcall(ClickAuctionSellItemButton)
    if not clicked then
        pcall(ClearCursor)
        return false, "could not place it in the auction slot"
    end

    local ok, err = pcall(StartAuction, bid, buyout, duration)

    -- Whatever happened, do not leave the item stuck to the cursor.
    pcall(ClearCursor)

    if not ok then
        return false, tostring(err):gsub("^.-:%d+: ", "")
    end

    return true
end

ns.RegisterCommand("posttry", L["try one way of calling PostItem: /bts posttry <n> [name]"], function(args)
    local index, needle = (args or ""):match("^(%d+)%s*(.*)$")
    index = tonumber(index)

    if not index or not POST_VARIANTS[index] then
        ns.Print("ways to try:")
        for i, variant in ipairs(POST_VARIANTS) do
            ns.PrintRaw(("  |cffC8A44D/bts posttry %d|r  %s"):format(i, variant.name))
        end
        ns.PrintRaw("  add part of an item name to choose what to list.")
        return
    end

    local line
    for _, candidate in ipairs(ns.Posting:GetPostable({ includeAll = true })) do
        if needle == "" or (candidate.label or ""):lower():find(needle:lower(), 1, true) then
            if not ns.Scanner:IsCommodity(candidate.itemID) then
                line = candidate
                break
            end
        end
    end

    if not line then
        ns.Print("no item auction in your bags matching that. Commodities already work.")
        return
    end

    local itemID, quantity, price = line.itemID, line.postQuantity, line.unitPrice

    local bagID, slotID = FindInBags(itemID)
    local location = bagID and MakeLocation(bagID, slotID)
    if not location then
        ns.Warn(L["could not find that item in your bags"])
        return
    end

    local variant = POST_VARIANTS[index]
    local bid, buyout = variant.build(price)
    local duration = ns.Config:Get("postDuration") or 2

    ns.Print(("posttry %d (%s): %s x%d, bid=%s buyout=%s duration=%s"):format(
        index, variant.name, Util.GetItemLabel(itemID), quantity,
        tostring(bid), tostring(buyout), tostring(duration)))

    local before = ns.Auctions:GetOwnPostedCount(itemID)

    if variant.legacy then
        local worked, why = TryLegacyPost(bagID, slotID, bid, buyout, duration)
        ns.PrintRaw(("  old-style call: %s%s"):format(
            tostring(worked), why and (": " .. why) or ""))
    else
        local ok, returned = pcall(C_AuctionHouse.PostItem, location, duration, quantity, bid, buyout)
        ns.PrintRaw(("  call: ok=%s returned=%s"):format(tostring(ok), tostring(returned)))
    end

    C_Timer.After(4, function()
        ns.Auctions:Refresh()

        C_Timer.After(2, function()
            local after = ns.Auctions:GetOwnPostedCount(itemID)

            if after > before then
                ns.Print(("|cff4FD18Bway %d worked: %s.|r"):format(index, variant.name))
                ns.Print("report which number worked so it can be made the default.")
            else
                ns.Print(("|cffE5604Fway %d did not list.|r Try the next one."):format(index))
            end
        end)
    end)
end)

--- Watch what Blizzard's own Sell tab passes when a listing succeeds.
--
-- Six argument shapes have now failed while the default UI lists the same item
-- without complaint, so the difference is something not being guessed. Rather
-- than try a seventh, hook the call and read the arguments off a posting that
-- actually works.
--
-- hooksecurefunc observes without replacing, so Blizzard's call is unaffected
-- and nothing here can taint it.
ns.RegisterCommand("watchpost", L["show what Blizzard's Sell tab sends when you post"], function()
    if Posting.watching then
        ns.Print("already watching. Post something with Blizzard's Sell tab.")
        return
    end

    local function Describe(value)
        if type(value) ~= "table" then return tostring(value) end

        -- An ItemLocation prints as a table; the bag and slot are the point.
        local ok, bagID, slotID = pcall(value.GetBagAndSlot, value)
        if ok and bagID then
            return ("location(bag %s slot %s)"):format(tostring(bagID), tostring(slotID))
        end

        local keyOk, itemID = pcall(function() return value.itemID end)
        if keyOk and itemID then
            return ("itemKey(%s)"):format(tostring(itemID))
        end

        return "table"
    end

    local function Log(label, ...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = ("%d=%s"):format(i, Describe((select(i, ...))))
        end

        ns.Print(("|cff4FD18B%s|r %s"):format(label, table.concat(parts, "  ")))
    end

    local hooked = {}

    if C_AuctionHouse then
        for _, name in ipairs({ "PostItem", "PostCommodity", "SetSellItem" }) do
            if type(C_AuctionHouse[name]) == "function" then
                hooksecurefunc(C_AuctionHouse, name, function(...)
                    Log("C_AuctionHouse." .. name, ...)
                end)
                hooked[#hooked + 1] = name
            end
        end
    end

    for _, name in ipairs({ "StartAuction", "ClickAuctionSellItemButton" }) do
        if type(_G[name]) == "function" then
            hooksecurefunc(name, function(...) Log(name, ...) end)
            hooked[#hooked + 1] = name
        end
    end

    if #hooked == 0 then
        ns.Warn("nothing to watch; this version of the game has none of the posting functions.")
        return
    end

    Posting.watching = true

    ns.Print(("watching: %s"):format(table.concat(hooked, ", ")))
    ns.Print("now post an item with Blizzard's own Sell tab, and report what prints.")
end)
