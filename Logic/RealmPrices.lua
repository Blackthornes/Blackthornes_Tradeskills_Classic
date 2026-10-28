-- Blackthornes Tradeskills -- Logic/RealmPrices.lua
-- Auction prices shared with players on your realm, over a hidden channel.
--
-- The owner said build it (2026-10-20, from a mockup whose words he
-- approved), after asking for live prices without an app or a server. Guild
-- sharing (Logic/GuildPrices.lua) was chosen over the whole server on
-- 2026-10-07 for fear of made-up prices, so this one asks more before it
-- believes anything. Tradeskills only: Farmer stays guild at most.
--
-- On unless unticked for new saves (the owner, 2026-10-28; a save made
-- before keeps its value); Settings, Sharing, YOUR REALM: `realmPrices`.
-- When on:
--   * Tradeskills joins a hidden chat channel named for the realm's side
--     (CHANNEL_BASE plus A, H or N) and keeps its join and leave lines out of
--     chat. The probe of 2026-10-20 found Forever lets addons join one and
--     send to it, but throttles hard: about 8 at once, and one every half
--     second was still too fast. So a scan goes out a message every
--     SEND_GAP seconds, at most once an hour, never in a fight, and not at
--     all when MIN_SENDERS others already shared a scan from about then.
--   * Only item numbers and prices go out. Senders are kept by a hash of
--     their name, never the name, in `realmPrices[realm][itemID]` (never
--     rename it).
--   * A price is used only once MIN_SENDERS players have sent one for the
--     item, and the middle of the last SENDERS_PER_ITEM is taken, so one
--     player's silly price is outvoted. A price far from a fresh one of your
--     own is not taken at all.
--   * It only fills gaps, after your own scans and your guild's prices
--     (Data/Prices.lua). Used for USE_FOR, kept KEEP, as guild prices are.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local RealmPrices = ns.NewModule("RealmPrices")

local Comm = ns.Comm

local HOUR = 3600
RealmPrices.CHANNEL_BASE = "BTSPrices"
RealmPrices.SHARE_EVERY = HOUR
RealmPrices.SCAN_FRESH = 30 * 60      -- only a scan this recent is shared
RealmPrices.HEARD_COVERS = 30 * 60    -- others' scans this close cover yours
RealmPrices.KEEP = 7 * 24 * HOUR
RealmPrices.USE_FOR = 3 * 24 * HOUR
RealmPrices.MAX_ITEMS = 2000          -- items one share sends
RealmPrices.MIN_SENDERS = 3           -- players needed before a price is used
RealmPrices.SENDERS_PER_ITEM = 5      -- the last prices kept for an item
RealmPrices.FAR = 10
RealmPrices.MAX_PER_SENDER_HOUR = 4000
RealmPrices.MAX_ITEM_ID = 10000000
RealmPrices.MAX_STORED = 20000        -- items kept for a realm
RealmPrices.SEND_GAP = 3              -- seconds between messages to the channel
RealmPrices.JOIN_DELAY = 20           -- seconds after login before joining

--------------------------------------------------------------------------------
-- Saved data
--------------------------------------------------------------------------------

function RealmPrices:IsOn()
    return ns.Config and ns.Config:Get("realmPrices") == true
end

local function RealmTable(create)
    local db = ns.db
    if not db then return nil end
    if type(db.realmPrices) ~= "table" then
        if not create then return nil end
        db.realmPrices = {}
    end
    local key = ns.Config:GetRealmKey()
    local realm = db.realmPrices[key]
    if type(realm) ~= "table" then
        if not create then return nil end
        realm = {}
        db.realmPrices[key] = realm
    end
    return realm
end

-- An item's entry is a flat list, four values per player:
-- their name's hash, when their scan was, market value, cheapest listing.
local STRIDE = 4

--- Who sent it, as kept: a hash of the name, never the name.
function RealmPrices.SenderKey(sender)
    local key = Comm.NameKey(sender)
    return key and ("h" .. Comm.Hash(key)) or nil
end

--- Keep one player's price for an item: replaces their last one, else the
--- oldest when the item already has SENDERS_PER_ITEM.
function RealmPrices:Store(itemID, sender, at, market, lowest)
    local realm = RealmTable(true)
    if not realm then return end

    local list = realm[itemID]
    if type(list) ~= "table" then
        if type(self.stored) ~= "number" then self.stored = self:Count() end
        if self.stored >= self.MAX_STORED then return end
        self.stored = self.stored + 1
        list = {}
        realm[itemID] = list
    end

    local slot, oldest, oldestAt
    for index = 1, #list, STRIDE do
        if list[index] == sender then slot = index break end
        if not oldestAt or (list[index + 1] or 0) < oldestAt then oldest, oldestAt = index, list[index + 1] or 0 end
    end
    if not slot then
        if #list / STRIDE < self.SENDERS_PER_ITEM then
            slot = #list + 1
        else
            slot = oldest
        end
    end
    if slot ~= #list + 1 and (list[slot + 1] or 0) > at then return end

    list[slot], list[slot + 1], list[slot + 2], list[slot + 3] = sender, at, market, lowest or market
    self.version = (self.version or 0) + 1
end

local function Median(values)
    table.sort(values)
    local count = #values
    if count == 0 then return nil end
    if count % 2 == 1 then return values[(count + 1) / 2] end
    return math.floor((values[count / 2] + values[count / 2 + 1]) / 2 + 0.5)
end

--- What players on the realm say an item is worth: the middle of their last
--- prices, once MIN_SENDERS of them are fresh. `which` as GuildPrices.
-- @return copper, and when the newest of those scans was; nil without
function RealmPrices:GetValue(itemID, which, now)
    if which == "rival" then return nil end
    local realm = RealmTable(false)
    local list = realm and realm[itemID]
    if type(list) ~= "table" then return nil end

    now = now or time()
    local values, newest = {}, nil
    for index = 1, #list, STRIDE do
        local at = list[index + 1]
        local value = (which == "min" or which == "lowest") and list[index + 3] or list[index + 2]
        if type(at) == "number" and type(value) == "number" and now - at <= self.USE_FOR then
            values[#values + 1] = value
            if not newest or at > newest then newest = at end
        end
    end
    if #values < self.MIN_SENDERS then return nil end
    return Median(values), newest
end

--- Drop prices older than KEEP, and items left with none.
function RealmPrices:Prune(now)
    now = now or time()
    local removed = 0
    self.stored = nil
    for _, realm in pairs((ns.db and ns.db.realmPrices) or {}) do
        if type(realm) == "table" then
            for itemID, list in pairs(realm) do
                local kept = {}
                if type(list) == "table" then
                    for index = 1, #list, STRIDE do
                        if type(list[index + 1]) == "number" and now - list[index + 1] <= self.KEEP then
                            for offset = 0, STRIDE - 1 do kept[#kept + 1] = list[index + offset] end
                        end
                    end
                end
                if #kept == 0 then
                    realm[itemID] = nil
                    removed = removed + 1
                elseif #kept < #list then
                    realm[itemID] = kept
                end
            end
        end
    end
    self.version = (self.version or 0) + 1
    return removed
end

--- Items kept for this realm, and how many players sent them. The players
--- are counted only when asked (the Settings line), and again only after
--- something new was kept.
function RealmPrices:Count()
    local realm = RealmTable(false)
    local count = 0
    for _ in pairs(realm or {}) do count = count + 1 end
    return count
end

function RealmPrices:Players()
    if self.playersAt == self.version and self.players then return self.players end
    local seen, players = {}, 0
    for _, list in pairs(RealmTable(false) or {}) do
        if type(list) == "table" then
            for index = 1, #list, STRIDE do
                local who = list[index]
                if who ~= nil and not seen[who] then seen[who] = true players = players + 1 end
            end
        end
    end
    self.players, self.playersAt = players, self.version
    return players
end

--------------------------------------------------------------------------------
-- The channel
--------------------------------------------------------------------------------

local function InCombat()
    local ok, inCombat = pcall(InCombatLockdown)
    return ok and inCombat == true
end

--- The hidden channel's name: one per side, as the auction house is.
function RealmPrices:ChannelName()
    local side = "N"
    local ok, faction = pcall(UnitFactionGroup, "player")
    faction = ok and Comm.Plain(faction) or nil
    if faction == "Alliance" then side = "A" elseif faction == "Horde" then side = "H" end
    return self.CHANNEL_BASE .. side
end

--- Is this channel name (as a message or a notice gives it) ours?
function RealmPrices:IsOurs(text)
    text = Comm.Plain(text)
    if type(text) ~= "string" then return false end
    return text:lower():find(self.CHANNEL_BASE:lower(), 1, true) ~= nil
end

--- Our channel's join and leave lines are kept out of chat.
function RealmPrices.FilterNotice(_, _, _, _, _, channelString, _, _, _, _, channelName)
    return RealmPrices:IsOurs(channelName) or RealmPrices:IsOurs(channelString)
end

function RealmPrices:Join()
    if not self:IsOn() then return false end
    local name = self:ChannelName()
    if Comm.ChannelNumber(name) > 0 then return true end
    if InCombat() then self.joinAfterFight = true return false end
    if not self.filtered and type(ChatFrame_AddMessageEventFilter) == "function" then
        self.filtered = pcall(ChatFrame_AddMessageEventFilter, "CHAT_MSG_CHANNEL_NOTICE", RealmPrices.FilterNotice)
    end
    if type(JoinTemporaryChannel) == "function" then
        pcall(JoinTemporaryChannel, name)
    elseif type(JoinChannelByName) == "function" then
        pcall(JoinChannelByName, name)
    end
    return false
end

function RealmPrices:Leave()
    self.outbox = nil
    local name = self:ChannelName()
    if Comm.ChannelNumber(name) > 0 and type(LeaveChannelByName) == "function" then
        pcall(LeaveChannelByName, name)
    end
end

--- Turn it on or off: the setting, and the channel with it.
function RealmPrices:SetOn(on)
    ns.Config:Set("realmPrices", on == true)
    if on then self:Join() else self:Leave() end
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------
-- Y<scan time>: "I am about to share a scan from then".
-- Z<scan time>:<id>,<market>[,<lowest>];...  as guild prices' P messages.

--- When this realm's prices were last shared: { at, scanAt }, or nil.
function RealmPrices:LastSent()
    local sent = ns.db and ns.db.realmPricesSent
    local mine = type(sent) == "table" and sent[ns.Config:GetRealmKey()]
    return type(mine) == "table" and mine or nil
end

--- How many others shared a scan from about `scanAt`.
function RealmPrices:Covering(scanAt)
    local count = 0
    for _, at in pairs(self.heard or {}) do
        if at >= scanAt - self.HEARD_COVERS then count = count + 1 end
    end
    return count
end

--- Why the last scan is not being shared now, or nil when it should be.
function RealmPrices:WhyNotShare(now)
    now = now or time()
    if not self:IsOn() then return "off" end
    if self.outbox and #self.outbox > 0 then return "still sending" end

    local scanAt = ns.Prices:GetLastScan()
    if not scanAt or now - scanAt > self.SCAN_FRESH then return "no recent scan" end

    local mine = self:LastSent()
    if mine and mine.scanAt and mine.scanAt >= scanAt then return "already shared" end
    if mine and mine.at and now - mine.at < self.SHARE_EVERY then return "shared within the hour" end
    if self:Covering(scanAt) >= self.MIN_SENDERS then return "others shared one" end
    if Comm.ChannelNumber(self:ChannelName()) <= 0 then return "not in the channel" end
    return nil, scanAt
end

function RealmPrices:Share(now)
    now = now or time()
    local why, scanAt = self:WhyNotShare(now)
    if why then return false, why end

    -- The guild's batching, with this file's limits.
    local batches, head, count = ns.GuildPrices.Batches(self, scanAt)
    if #batches == 0 then return false, "nothing priced" end

    ns.db.realmPricesSent = type(ns.db.realmPricesSent) == "table" and ns.db.realmPricesSent or {}
    ns.db.realmPricesSent[ns.Config:GetRealmKey()] = { at = now, scanAt = scanAt }

    local outbox = { { kind = "Y", text = Comm.ToBase36(scanAt) } }
    for _, body in ipairs(batches) do
        outbox[#outbox + 1] = { kind = "Z", text = head:sub(2) .. body }
    end
    self.outbox = outbox
    ns.Debug(("realm prices: sharing %d price(s) in %d message(s)"):format(count, #batches))
    return true, count
end

--- One message to the channel, when the last has gone and no fight is on.
function RealmPrices:Drip()
    local outbox = self.outbox
    if not outbox or #outbox == 0 then self.outbox = nil return end
    if not self:IsOn() then self.outbox = nil return end
    if InCombat() or Comm:Pending() > 0 then return end
    local id = Comm.ChannelNumber(self:ChannelName())
    if id <= 0 then self:Join() return end
    local message = table.remove(outbox, 1)
    Comm:Send(message.kind, message.text, "CHANNEL", tostring(id))
end

--------------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------------

local function FromUs(channel, channelName, target)
    return channel == "CHANNEL" and (RealmPrices:IsOurs(channelName) or RealmPrices:IsOurs(target))
end

function RealmPrices:OnAnnounce(sender, body, channel, channelName, target)
    if not FromUs(channel, channelName, target) or Comm.IsMe(sender) or not self:IsOn() then return end
    local who = self.SenderKey(sender)
    local at = Comm.FromBase36(body)
    if not who or not at or at > time() + HOUR then return end
    self.heard = self.heard or {}
    if not self.heard[who] or at > self.heard[who] then self.heard[who] = at end
end

local function TooFar(itemID, value)
    local own = ns.Prices:GetTable()[itemID]
    if type(own) ~= "table" or type(own.market) ~= "number" or ns.Prices:IsStale(itemID) then return false end
    return value > own.market * RealmPrices.FAR or value * RealmPrices.FAR < own.market
end

function RealmPrices:OnPrices(sender, body, channel, channelName, target)
    if not FromUs(channel, channelName, target) or Comm.IsMe(sender) or not self:IsOn() then return end
    local who = self.SenderKey(sender)
    if not who then return end

    local atText, list = body:match("^(%w+):(.*)$")
    local at = Comm.FromBase36(atText)
    local now = time()
    if not at or at > now + HOUR or now - at > self.USE_FOR then return end

    self.counts = self.counts or {}
    local tally = self.counts[who]
    if not tally or now - tally.from > HOUR then
        tally = { from = now, items = 0 }
        self.counts[who] = tally
    end

    local taken = 0
    for idText, marketText, lowestText in list:gmatch("(%w+),(%w+),?(%w*);") do
        if tally.items >= self.MAX_PER_SENDER_HOUR then break end
        tally.items = tally.items + 1

        local itemID, market = Comm.FromBase36(idText), Comm.FromBase36(marketText)
        local lowest = lowestText ~= "" and Comm.FromBase36(lowestText) or market
        if itemID and itemID > 0 and itemID <= self.MAX_ITEM_ID and itemID == math.floor(itemID)
            and ns.Prices.IsCredible(market) and ns.Prices.IsCredible(lowest)
            and not TooFar(itemID, market) then
            self:Store(itemID, who, at, market, lowest)
            taken = taken + 1
        end
    end
    if taken > 0 then ns.Prices.changes = (ns.Prices.changes or 0) + 1 end
end

--------------------------------------------------------------------------------
-- Status and lifecycle
--------------------------------------------------------------------------------

function RealmPrices:Describe()
    if not self:IsOn() then return L["Realm prices are off."] end
    local count = self:Count()
    if count == 0 then
        return L["Listening for prices from your realm. A price is used once 3 players agree on it."]
    end
    local shown = ns.Util and ns.Util.Comma and ns.Util.Comma(count) or tostring(count)
    local players = self:Players()
    local line
    if count == 1 and players == 1 then
        line = L.Format("%s realm price kept, from %d player.", shown, players)
    elseif count == 1 then
        line = L.Format("%s realm price kept, from %d players.", shown, players)
    elseif players == 1 then
        line = L.Format("%s realm prices kept, from %d player.", shown, players)
    else
        line = L.Format("%s realm prices kept, from %d players.", shown, players)
    end
    local parts = { line }
    local mine = self:LastSent()
    if mine and mine.at and ns.Util and ns.Util.FormatAgeAgo then
        parts[#parts + 1] = L.Format("You last shared %s.", ns.Util.FormatAgeAgo(time() - mine.at))
    end
    return table.concat(parts, "  ")
end

function RealmPrices:OnEnable()
    self:Prune()
    Comm:On("Y", function(...) RealmPrices:OnAnnounce(...) end)
    Comm:On("Z", function(...) RealmPrices:OnPrices(...) end)

    ns.RegisterEvent(self, "PLAYER_REGEN_ENABLED", function()
        if RealmPrices.joinAfterFight then
            RealmPrices.joinAfterFight = nil
            RealmPrices:Join()
        end
    end)
    if type(C_Timer) == "table" then
        C_Timer.After(self.JOIN_DELAY, function() RealmPrices:Join() end)
        -- Looked at once a minute; Share decides whether anything goes.
        self.ticker = C_Timer.NewTicker(60, function()
            if RealmPrices:IsOn() then
                RealmPrices:Join()
                RealmPrices:Share()
            end
        end)
        self.dripper = C_Timer.NewTicker(self.SEND_GAP, function() RealmPrices:Drip() end)
    end
end
