-- Blackthornes Tradeskills -- Logic/SellOut.lua
-- Keep one more of a craft that sold out before its listings ran out, and
-- one fewer again once it keeps coming back unsold.
--
-- The owner asked (2026-10-13): when every copy of a craft you listed sells
-- within the auction's time (8 hours by default), Keep in stock for that
-- item goes up by 1. It only ever goes up, once a window, and only while
-- "Raise it when it sells out" is ticked (raiseStockOnSellOut, off unless
-- ticked).
--
-- A window opens when a listing of a craft is confirmed (Posting calls
-- NotePosted) and ends when the longest listing in it would run out; a
-- listing confirmed before then joins it. Nothing is decided until this
-- character's mailbox is read in full after the window ended (Mail:Read
-- calls MailRead), since that is the only place a listing that did not sell
-- shows up. Then:
--
--   * anything of it back in the mail (expired or cancelled) since the window
--     opened: not a sell out, the window closes and counts as unsold;
--     after UNSOLD_ROUNDS (3) unsold windows in a row, a number this raised
--     comes down by 1 (the owner, 2026-10-16), never below the number it
--     started from (`base`), and only while it is still the number this
--     set (one typed by hand is the new start);
--   * nothing back and at least one sale seen (a sale mail or the game's sale
--     notice): every copy sold, so the item's number goes up by 1 and the
--     unsold count starts again;
--   * nothing back and no sale seen yet: the sale mail can come an hour
--     late, so the window waits for the next reading.
--
-- Only an item with a number gets one more: no limit stays no limit. The
-- new number is set on the item itself (Auctions:SetLimit), so it shows in
-- the Profit tab's detail pane like one typed there.
--
-- Saved, never renamed: sellOutWatch[realm][character][itemID] = a list of
-- { from, ends, units }, sellOutRaised[itemID] = { at, from, to, base,
-- lowered } (account wide, like postLimits) for the Profit tab's note and
-- the floor, and sellOutUnsold[itemID] = unsold windows in a row.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local SellOut = ns.NewModule("SellOut")

-- Seconds an auction stays up for each postDuration (Logic/Posting.lua).
SellOut.SECONDS = { [1] = 2 * 3600, [2] = 8 * 3600, [3] = 24 * 3600 }
SellOut.LABELS = { [1] = L["2 hours"], [2] = L["8 hours"], [3] = L["24 hours"] }

-- An expired auction's mail can take a moment to land.
SellOut.SLACK = 120

-- A window never settled (its mailbox never read) is let go after this.
SellOut.FORGET_AFTER = 30 * 86400

-- Unsold windows in a row before a raised number comes down by 1.
SellOut.UNSOLD_ROUNDS = 3

local function Now() return time() end

function SellOut:IsOn()
    return ns.Config:Get("raiseStockOnSellOut") == true
end

local function Watch(who, create)
    if not ns.db or not who then return nil end
    local realmKey = ns.Config:GetRealmKey()
    if not create and not (ns.db.sellOutWatch and ns.db.sellOutWatch[realmKey]) then return nil end
    ns.db.sellOutWatch = ns.db.sellOutWatch or {}
    ns.db.sellOutWatch[realmKey] = ns.db.sellOutWatch[realmKey] or {}
    local realm = ns.db.sellOutWatch[realmKey]
    if create then realm[who] = realm[who] or {} end
    return realm[who]
end

local function Who()
    return ns.Config.GetCharacterKey and ns.Config:GetCharacterKey() or nil
end

--- Is this item one of your crafts?
local function IsCraft(itemID)
    if not (ns.Auctions and ns.Auctions.ProfessionOf) then return false end
    local ok, profession = pcall(ns.Auctions.ProfessionOf, ns.Auctions, itemID)
    return ok and profession ~= nil
end

--- A listing of `units` of an item was confirmed on the auction house.
function SellOut:NotePosted(itemID, units, duration)
    if not itemID or not self:IsOn() or not IsCraft(itemID) then return end
    units = math.floor(tonumber(units) or 0)
    if units <= 0 then return end

    local seconds = self.SECONDS[duration or ns.Config:Get("postDuration") or 2] or self.SECONDS[2]
    local now = Now()
    local watch = Watch(Who(), true)
    if not watch then return end

    local list = watch[itemID] or {}
    watch[itemID] = list

    local open = list[#list]
    if open and now < open.ends then
        open.units = open.units + units
        open.ends = math.max(open.ends, now + seconds)
        open.duration = math.max(open.duration or duration or 2, duration or 2)
    else
        list[#list + 1] = { from = now, ends = now + seconds, units = units, duration = duration }
    end
end

--- Was anything of the item sent back to this character since `from`, and
--- did any of it sell?
local function Outcome(itemID, who, from)
    local returned, sold = false, false

    local Mail = ns.Mail
    if Mail and Mail.GetLedger then
        local names = Mail.NameIndex and Mail:NameIndex() or {}
        local entries = Mail:GetLedger().entries or {}
        -- Newest last: walk back only as far as the window.
        for index = #entries, 1, -1 do
            local entry = entries[index]
            if (entry.t or 0) < from then break end
            if entry.who == nil or entry.who == who then
                local id = entry.itemID or names[entry.name]
                if id == itemID then
                    if entry.kind == "sold" then
                        sold = true
                    elseif (entry.kind == "expired" or entry.kind == "removed")
                        and (entry.sent or entry.t or 0) >= from then
                        returned = true
                    end
                end
            end
        end

        if not sold and Mail.GetHeardList then
            for _, heard in ipairs(Mail:GetHeardList()) do
                if (heard.t or 0) >= from and (heard.who == nil or heard.who == who)
                    and (heard.itemID or names[heard.name]) == itemID then
                    sold = true
                    break
                end
            end
        end
    end

    return returned, sold
end
SellOut.Outcome = Outcome

--- The number this feature started from, while the item's number is still
--- the one it last set; nil once the player typed another.
local function Base(itemID, limit)
    local record = ns.db.sellOutRaised and ns.db.sellOutRaised[itemID]
    if type(record) ~= "table" or record.to ~= limit then return nil end
    return tonumber(record.base) or tonumber(record.from), record
end

local function Unsold(itemID, count)
    ns.db.sellOutUnsold = ns.db.sellOutUnsold or {}
    ns.db.sellOutUnsold[itemID] = count and count > 0 and count or nil
end

--- Give the item one more in Keep in stock. Returns the old and new numbers,
--- or nil when it has no number to raise.
function SellOut:Raise(itemID, window)
    local Auctions = ns.Auctions
    if not (Auctions and Auctions.GetLimit and Auctions.SetLimit) then return nil end

    local limit, source = Auctions:GetLimit(itemID)
    limit = tonumber(limit) or 0
    if limit <= 0 then return nil end

    -- Where it started: the item's own number, or the usual one (own false),
    -- so Reset puts back exactly what was there.
    local base, before = Base(itemID, limit)
    local own
    if base then
        own = before.own
    else
        base, own = limit, source == "item"
    end
    Auctions:SetLimit(itemID, limit + 1)
    Unsold(itemID, nil)

    ns.db.sellOutRaised = ns.db.sellOutRaised or {}
    ns.db.sellOutRaised[itemID] = { at = Now(), from = limit, to = limit + 1, base = base, own = own }

    local label = ns.Util and ns.Util.GetItemLabel and ns.Util.GetItemLabel(itemID) or tostring(itemID)
    local length = self.LABELS[window and window.duration or 2] or self.LABELS[2]
    local line = L.Format("Every %s you listed sold within %s, so Keep in stock for it is now %d.",
        label, length, limit + 1)
    ns.Print(("|cffffd100%s|r"):format(line))
    self:Cheer()
    return limit, limit + 1
end

--- Some of the item came back unsold. After UNSOLD_ROUNDS of those in a
--- row, take back one of the raises. Returns the old and new numbers when
--- it lowered.
function SellOut:Unsold(itemID)
    local Auctions = ns.Auctions
    if not (Auctions and Auctions.GetLimit and Auctions.SetLimit) then return nil end
    local count = ((ns.db.sellOutUnsold or {})[itemID] or 0) + 1

    local limit = tonumber((Auctions:GetLimit(itemID))) or 0
    local base = Base(itemID, limit)
    if not base or limit <= base then
        -- Nothing this raised is left to take back.
        Unsold(itemID, nil)
        return nil
    end
    if count < self.UNSOLD_ROUNDS then
        Unsold(itemID, count)
        return nil
    end

    local _, before = Base(itemID, limit)
    Auctions:SetLimit(itemID, limit - 1)
    Unsold(itemID, nil)
    ns.db.sellOutRaised[itemID] = { at = Now(), from = limit, to = limit - 1, base = base,
        own = before and before.own, lowered = true }

    local label = ns.Util and ns.Util.GetItemLabel and ns.Util.GetItemLabel(itemID) or tostring(itemID)
    local line = L.Format("%s came back unsold %d times in a row, so Keep in stock for it is now %d.",
        label, self.UNSOLD_ROUNDS, limit - 1)
    ns.Print(("|cffffd100%s|r"):format(line))
    return limit, limit - 1
end

function SellOut:Cheer()
    if type(PlaySound) ~= "function" then return end
    local kits = type(_G.SOUNDKIT) == "table" and _G.SOUNDKIT or {}
    pcall(ns.PlaySound or PlaySound, kits.IG_QUEST_LIST_COMPLETE or 878, "Master")
end

--- This character's mailbox was just read. Settle every window that has run
--- out. `complete` is false when part of the inbox could not be seen.
function SellOut:MailRead(complete)
    if not complete then return end
    local who = Who()
    local watch = Watch(who, false)
    if not watch then return end

    local now = Now()
    for itemID, list in pairs(watch) do
        local keep = {}
        for _, window in ipairs(list) do
            if now < window.ends + self.SLACK then
                keep[#keep + 1] = window
            elseif now > window.ends + self.FORGET_AFTER then
                -- Never settled: let it go.
            else
                local returned, sold = Outcome(itemID, who, window.from)
                if returned then
                    -- Not every copy sold.
                    if self:IsOn() then self:Unsold(itemID) end
                elseif sold then
                    if self:IsOn() then self:Raise(itemID, window) end
                else
                    keep[#keep + 1] = window
                end
            end
        end
        watch[itemID] = #keep > 0 and keep or nil
    end
end

--- Every item whose Keep in stock this changed and that still has the
--- number it set, as { itemID, base, limit }, by name.
function SellOut:Changed()
    local list = {}
    local Auctions = ns.Auctions
    if not (ns.db and ns.db.sellOutRaised and Auctions and Auctions.GetLimit) then return list end
    for itemID, record in pairs(ns.db.sellOutRaised) do
        if type(record) == "table" then
            local limit, source = Auctions:GetLimit(itemID)
            local base = source == "item" and Base(itemID, tonumber(limit))
            if base and base ~= limit then
                list[#list + 1] = { itemID = itemID, base = base, limit = limit,
                    name = ns.Util and ns.Util.GetItemLabel and ns.Util.GetItemLabel(itemID) or tostring(itemID) }
            end
        end
    end
    table.sort(list, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return list
end

--- Put an item's Keep in stock back to where it was before this changed
--- it: its own number, or the usual one. Returns true when it did.
function SellOut:Reset(itemID)
    local Auctions = ns.Auctions
    local record = ns.db and ns.db.sellOutRaised and ns.db.sellOutRaised[itemID]
    if type(record) ~= "table" or not (Auctions and Auctions.SetLimit) then return false end
    local base = Base(itemID, tonumber((Auctions:GetLimit(itemID))))
    if base then
        if record.own == false then
            Auctions:SetLimit(itemID, nil)
        else
            Auctions:SetLimit(itemID, base)
        end
    end
    ns.db.sellOutRaised[itemID] = nil
    Unsold(itemID, nil)
    return base ~= nil
end

--- When Keep in stock for an item was last raised this way, as
--- { at, from, to }, or nil.
function SellOut:GetRaised(itemID)
    local raised = ns.db and ns.db.sellOutRaised
    local record = raised and itemID and raised[itemID]
    return type(record) == "table" and record or nil
end
