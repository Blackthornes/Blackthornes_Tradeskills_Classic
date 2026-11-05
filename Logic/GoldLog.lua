-- Blackthornes Tradeskills -- Logic/GoldLog.lua
-- Every change to your gold, and where it came from or went.
--
-- Asked by a player on 2026-10-06: income and spending by source over a
-- session, a day, a week or any stretch of days, as a chart. The Sales tab's
-- mail ledger only knows the auction house; this watches the purse itself.
--
-- The game says that gold changed (PLAYER_MONEY), never why. So the why is
-- worked out from what was happening at that moment, most certain first:
--
--   1. A call that is about to move gold was just made: a post (the deposit),
--      a purchase on the auction house, taking a mail's gold, sending a mail,
--      a repair, a flight, a quest turned in, coins looted. Each leaves a
--      short-lived tag, used by the next change of the right sign.
--   2. A window is open (or just closed): auction house, vendor, mailbox,
--      trainer, flight master, trade.
--   3. Anything else is "Other".
--
-- Gold mailed between your own characters is kept as "Your characters" and
-- left out of income and spending: it moved, it was not made or spent.
--
-- Kept per realm like the mail ledger, in hour buckets for the last 8 days
-- and day buckets for 400 days, with no character names. The session's own
-- changes are held in memory only.
--
-- Quests handed in are counted a day at a time beside the gold (asked
-- 2026-10-20, for Goblin Gold's gold a quest): `questsDone[YYYYMMDD] = n`
-- in the same realm's log, kept as long as the days. Never renamed.

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

local GoldLog = ns.NewModule("GoldLog")

--------------------------------------------------------------------------------
-- Sources
--------------------------------------------------------------------------------

-- In the order the chart stacks them and the legend lists them. The colours
-- are picked to stay apart from one another on the dark window.
GoldLog.SOURCES = {
    { key = "auctionSales", text = L["Auction sales"],    color = { 0.31, 0.82, 0.55 } },
    { key = "vendorSales",  text = L["Vendor sales"],     color = { 0.53, 0.78, 0.95 } },
    { key = "loot",         text = L["Loot"],             color = { 0.98, 0.84, 0.35 } },
    { key = "quests",       text = L["Quests"],           color = { 0.78, 0.60, 0.98 } },
    { key = "auctionBuys",  text = L["Auction buys"],     color = { 0.92, 0.42, 0.33 } },
    { key = "auctionFees",  text = L["Auction deposits"], color = { 0.96, 0.62, 0.30 } },
    { key = "vendorBuys",   text = L["Vendor buys"],      color = { 0.42, 0.62, 0.98 } },
    { key = "repairs",      text = L["Repairs"],          color = { 0.70, 0.70, 0.74 } },
    { key = "training",     text = L["Training"],         color = { 0.95, 0.50, 0.75 } },
    { key = "flights",      text = L["Flights"],          color = { 0.40, 0.85, 0.85 } },
    { key = "mail",         text = L["Mail"],             color = { 0.85, 0.75, 0.55 } },
    { key = "trade",        text = L["Trades"],           color = { 0.65, 0.88, 0.40 } },
    { key = "other",        text = L["Other"],            color = { 0.55, 0.57, 0.62 } },
    -- Never in income or spending, never charted: listed on its own.
    { key = "transfer",     text = L["Your characters"],  color = { 0.45, 0.47, 0.52 }, moved = true },
}

local SOURCE_BY_KEY = {}
for index, source in ipairs(GoldLog.SOURCES) do
    source.order = index
    SOURCE_BY_KEY[source.key] = source
end

function GoldLog:GetSource(key)
    return SOURCE_BY_KEY[key] or SOURCE_BY_KEY.other
end

local HOUR = 3600
local DAY = 86400
local KEEP_HOURS = 8 * DAY
local KEEP_DAYS = 400

-- How long a tag left by a call waits for the gold change it explains. The
-- server answers in well under a second; a mailbox Take all can queue many.
local TAG_LIFE = 10

-- How long after a window closes a change still counts as that window's. A
-- trade's gold lands after the trade window has closed.
local CLOSE_GRACE = 3

-- The session's changes kept in memory for the session chart.
local MAX_SESSION = 2000

--------------------------------------------------------------------------------
-- Saved data
--------------------------------------------------------------------------------

--- This realm's log: { hours = { [hourStart] = bucket }, days = { [YYYYMMDD] = bucket } },
--- where a bucket is { [source] = { i = copper in, o = copper out } }.
function GoldLog:GetLog(realmKey)
    if not ns.db then return { hours = {}, days = {}, questsDone = {} } end

    realmKey = realmKey or ns.Config:GetRealmKey()
    ns.db.goldLog = ns.db.goldLog or {}

    local log = ns.db.goldLog[realmKey]
    if type(log) ~= "table" then
        log = {}
        ns.db.goldLog[realmKey] = log
    end
    if type(log.hours) ~= "table" then log.hours = {} end
    if type(log.days) ~= "table" then log.days = {} end
    if type(log.questsDone) ~= "table" then log.questsDone = {} end

    return log
end

--- The day a moment falls on, as YYYYMMDD in local time.
function GoldLog.DayKey(t)
    return tonumber(date("%Y%m%d", t))
end

--- Local midnight of the day `t` falls on, `offset` days later.
function GoldLog.DayStart(t, offset)
    local parts = date("*t", t)
    -- Noon first, so a clock change that day cannot land it on the wrong day,
    -- then back to midnight of that day.
    local noon = time({ year = parts.year, month = parts.month,
        day = parts.day + (offset or 0), hour = 12 })
    local p = date("*t", noon)
    return time({ year = p.year, month = p.month, day = p.day, hour = 0 })
end

local function AddTo(bucketTable, key, source, amount)
    local bucket = bucketTable[key]
    if type(bucket) ~= "table" then
        bucket = {}
        bucketTable[key] = bucket
    end

    local line = bucket[source]
    if type(line) ~= "table" then
        line = { i = 0, o = 0 }
        bucket[source] = line
    end

    if amount > 0 then
        line.i = (line.i or 0) + amount
    else
        line.o = (line.o or 0) - amount
    end
end

--- Write one change down. `amount` is signed: gold in is positive.
function GoldLog:Record(source, amount, t)
    amount = tonumber(amount)
    if not amount or amount == 0 then return end

    t = t or time()
    source = SOURCE_BY_KEY[source] and source or "other"

    local log = self:GetLog()
    AddTo(log.hours, t - (t % HOUR), source, amount)
    AddTo(log.days, GoldLog.DayKey(t), source, amount)

    local session = self.session
    if session then
        session[#session + 1] = { t = t, source = source, amount = amount }
        if #session > MAX_SESSION then table.remove(session, 1) end
    end

    -- Goblin Gold floats new gold up off its bar (Logic/GoldGoal.lua).
    local GoldGoal = ns.GoldGoal
    if GoldGoal and GoldGoal.OnRecord then pcall(GoldGoal.OnRecord, GoldGoal, source, amount) end
end

--- A quest handed in, counted under the day it was handed in.
function GoldLog:NoteQuest(t)
    t = t or time()
    local log = self:GetLog()
    local key = GoldLog.DayKey(t)
    log.questsDone[key] = (tonumber(log.questsDone[key]) or 0) + 1
end

--- Quests handed in over the last `days` days, today included.
function GoldLog:QuestsDone(days, now)
    now = now or time()
    local log = self:GetLog()
    local count = 0
    for back = 0, (days or 7) - 1 do
        count = count + (tonumber(log.questsDone[GoldLog.DayKey(GoldLog.DayStart(now, -back) + 43200)]) or 0)
    end
    return count
end

--- Hour buckets past 8 days are folded away (their days already hold them),
--- and day buckets past 400 days dropped.
function GoldLog:Prune(now)
    now = now or time()
    local log = self:GetLog()

    for hourStart in pairs(log.hours) do
        if type(hourStart) ~= "number" or hourStart < now - KEEP_HOURS then
            log.hours[hourStart] = nil
        end
    end

    local oldest = GoldLog.DayKey(now - KEEP_DAYS * DAY)
    for dayKey in pairs(log.days) do
        if type(dayKey) ~= "number" or dayKey < oldest then
            log.days[dayKey] = nil
        end
    end
    for dayKey in pairs(log.questsDone) do
        if type(dayKey) ~= "number" or dayKey < oldest then
            log.questsDone[dayKey] = nil
        end
    end
end

--------------------------------------------------------------------------------
-- Working out the why
--------------------------------------------------------------------------------

-- Tags left by calls, oldest first: { source, sign, at }. sign is 1 for gold
-- coming in, -1 for gold going out.
local tags = {}

-- window -> { open = true } or { closedAt = t }
local windows = {}

local WINDOW_SOURCE = {
    auction  = { [1] = "auctionSales", [-1] = "auctionBuys" },
    merchant = { [1] = "vendorSales",  [-1] = "vendorBuys" },
    mail     = { [1] = "mail",         [-1] = "mail" },
    trainer  = { [1] = "other",        [-1] = "training" },
    taxi     = { [1] = "other",        [-1] = "flights" },
    trade    = { [1] = "trade",        [-1] = "trade" },
    loot     = { [1] = "loot",         [-1] = "other" },
}

-- Checked in this order when more than one is open.
local WINDOW_ORDER = { "trade", "loot", "mail", "auction", "merchant", "trainer", "taxi" }

function GoldLog:Tag(source, sign, now)
    tags[#tags + 1] = { source = source, sign = sign, at = now or time() }
end

function GoldLog:SetWindow(window, open, now)
    if open then
        windows[window] = { open = true }
    else
        windows[window] = { closedAt = now or time() }
    end
end

local function WindowOpen(window, now)
    local state = windows[window]
    if not state then return false end
    if state.open then return true end
    return state.closedAt ~= nil and now - state.closedAt <= CLOSE_GRACE
end

--- Is the cursor in repair mode at a vendor? Then gold out is a repair.
local function Repairing()
    if type(InRepairMode) ~= "function" then return false end
    local ok, repairing = pcall(InRepairMode)
    return ok and repairing == true
end

--- Which source a change of `amount` belongs to.
function GoldLog:Classify(amount, now)
    now = now or time()
    local sign = amount > 0 and 1 or -1

    -- The oldest live tag of the right sign is spent on this change.
    local index = 1
    while index <= #tags do
        local tag = tags[index]
        if now - tag.at > TAG_LIFE then
            table.remove(tags, index)
        elseif tag.sign == sign then
            table.remove(tags, index)
            return tag.source
        else
            index = index + 1
        end
    end

    if sign < 0 and WindowOpen("merchant", now) and Repairing() then
        return "repairs"
    end

    for _, window in ipairs(WINDOW_ORDER) do
        if WindowOpen(window, now) then return WINDOW_SOURCE[window][sign] end
    end

    return "other"
end

--- For the tests: forget every tag and window.
function GoldLog:ResetContext()
    tags = {}
    windows = {}
end

--------------------------------------------------------------------------------
-- The purse
--------------------------------------------------------------------------------

local function Money()
    if type(GetMoney) ~= "function" then return nil end
    local ok, money = pcall(function() return tonumber(GetMoney()) end)
    return ok and money or nil
end

--- The purse changed: write down by how much, and why.
function GoldLog:OnMoney(now)
    local money = Money()
    if not money then return end

    local last = self.lastMoney
    self.lastMoney = money
    -- Before the world has loaded the purse can read 0 and then the real
    -- amount, which would be written down as a fortune from nowhere.
    if not last or not self.ready then return end

    local delta = money - last
    if delta == 0 then return end

    now = now or time()
    self:Record(self:Classify(delta, now), delta, now)
    pcall(self.NoteGold, self, money, now)
end

--------------------------------------------------------------------------------
-- Your own characters
--------------------------------------------------------------------------------

--- Is `name` ("Name", "Name-Realm" or "Name Surname") one of this
--- account's characters?
--
-- Forever names can repeat, so mail to an alt is addressed "Name Surname"
-- (QueueMail.MailName). Read as one name it matched nobody, and gold sent
-- to an alt was counted as spent.
function GoldLog:IsOwnCharacter(name)
    if type(name) ~= "string" or name == "" or not ns.db then return false end

    local short = name:match("^([^%-]+)") or name
    local realm = name:match("%-(.+)$")

    local first, last = short:match("^(%S+)%s+(.-)%s*$")
    if first then short = first end

    -- Characters are filed by GUID now ("Player-1234-..."), so the name and
    -- realm come from the record itself; only a record saved before that
    -- still carries them in its "Name-Realm" key.
    for key, record in pairs(ns.db.characters or {}) do
        if type(key) == "string" then
            local fields = type(record) == "table" and record or {}
            local keyName = type(fields.name) == "string" and fields.name ~= "" and fields.name
                or key:match("^([^%-]+)")
            local keyRealm = type(fields.realm) == "string" and fields.realm ~= "" and fields.realm
                or key:match("%-(.+)$")
            local surname = type(fields.surname) == "string"
                and fields.surname ~= "" and fields.surname or nil
            if keyName == short
                and (not last or not surname or surname:lower() == last:lower())
                and (not realm or not keyRealm
                or SameRealm(keyRealm, realm)) then
                return true
            end
        end
    end

    return false
end

--- Taking mail number `index`: the tag its gold leaves, if it moves any.
--- Gold on it comes in; a cash on delivery charge goes out.
function GoldLog:NoteTakeMail(index)
    if type(GetInboxHeaderInfo) ~= "function" then return end

    local ok, _, _, _, _, money, cod = pcall(GetInboxHeaderInfo, index)
    if not ok then return end

    if (tonumber(money) or 0) > 0 then
        self:Tag(self:MailSource(index), 1)
    elseif (tonumber(cod) or 0) > 0 then
        self:Tag("mail", -1)
    end
end

--- Gold on mail number `index`: what kind of gold is it?
function GoldLog:MailSource(index)
    if type(GetInboxHeaderInfo) ~= "function" then return "mail" end

    local ok, _, _, sender, subject, money = pcall(GetInboxHeaderInfo, index)
    if not ok then return "mail" end

    if ns.MailHaul and ns.MailHaul.Classify then
        local okKind, kind = pcall(ns.MailHaul.Classify, ns.MailHaul,
            { subject = subject, sender = sender, money = money, index = index })
        if okKind then
            if kind == "sold" then return "auctionSales" end
            -- A bid you lost: the gold you bid coming back.
            if kind == "outbid" then return "auctionBuys" end
        end
    end

    if self:IsOwnCharacter(sender) then return "transfer" end
    return "mail"
end

--------------------------------------------------------------------------------
-- Reading it back
--------------------------------------------------------------------------------

-- Periods offered on the Sales tab, in menu order.
GoldLog.PERIODS = {
    { text = L["Session"], value = "session" },
    { text = L["Today"],   value = "today" },
    { text = L["7d"],      value = "week" },
    { text = L["30d"],     value = "month" },
    { text = L["3m"],      value = "quarter" },
    { text = L["Year"],    value = "year" },
    { text = L["All"],     value = "all" },
    { text = L["Pick dates"], value = "pick" },
}

-- How many days back each day period reaches, today in.
GoldLog.PERIOD_DAYS = { week = 7, month = 30, quarter = 91, year = 365 }

--- The first day anything was written down, as the day's midnight, or nil.
function GoldLog:FirstDay()
    local first
    for dayKey in pairs(self:GetLog().days) do
        if type(dayKey) == "number" and (not first or dayKey < first) then first = dayKey end
    end
    return first and GoldLog.KeyStart(first) or nil
end

local function NewBin(label, from, to)
    return { label = label, from = from, to = to, sources = {} }
end

local function AddBucket(bin, bucket)
    for source, line in pairs(type(bucket) == "table" and bucket or {}) do
        if SOURCE_BY_KEY[source] and type(line) == "table" then
            local into = bin.sources[source]
            if not into then
                into = { i = 0, o = 0 }
                bin.sources[source] = into
            end
            into.i = into.i + (tonumber(line.i) or 0)
            into.o = into.o + (tonumber(line.o) or 0)
        end
    end
end

--- Days between two YYYYMMDD keys' midnights, `from` first, as day starts.
local function DayStarts(fromStart, toStart)
    local starts = {}
    local day = fromStart
    local guard = 0
    while day <= toStart and guard < 800 do
        starts[#starts + 1] = day
        local nextDay = GoldLog.DayStart(day, 1)
        if nextDay <= day then break end
        day = nextDay
        guard = guard + 1
    end
    return starts
end

--- Midnight of a YYYYMMDD key.
function GoldLog.KeyStart(dayKey)
    local year = math.floor(dayKey / 10000)
    local month = math.floor(dayKey / 100) % 100
    local day = dayKey % 100
    return time({ year = year, month = month, day = day, hour = 0 })
end

--- The chart's bins for a period.
--
-- @param period  "session" | "today" | "week" | "month" | "pick"
-- @param fromKey, toKey  YYYYMMDD, for "pick"
-- @return array of bins { label, from, to, sources = { [source] = { i, o } } }
function GoldLog:Bins(period, fromKey, toKey, now)
    now = now or time()
    local log = self:GetLog()
    local bins = {}

    if period == "session" then
        local started = self.sessionStart or now
        local span = math.max(now - started, 1)
        -- Up to twelve bars, none narrower than five minutes.
        local width = math.max(300, math.ceil(span / 12))
        local count = math.max(1, math.ceil(span / width))

        for index = 1, count do
            local from = started + (index - 1) * width
            bins[index] = NewBin(date("%H:%M", from), from, from + width)
        end

        for _, change in ipairs(self.session or {}) do
            local index = math.min(count, math.max(1, math.floor((change.t - started) / width) + 1))
            AddBucket(bins[index], { [change.source] = {
                i = change.amount > 0 and change.amount or 0,
                o = change.amount < 0 and -change.amount or 0,
            } })
        end

        return bins
    end

    if period == "today" then
        local midnight = GoldLog.DayStart(now)
        for hour = 0, 23 do
            local from = midnight + hour * HOUR
            bins[#bins + 1] = NewBin(("%02d"):format(hour), from, from + HOUR)
        end
        -- Hour buckets start on the clock's hour (UTC), the bins on the
        -- local one. Where the zone is offset by a half or quarter hour the
        -- two never meet, and looking a bin's start up as a key found
        -- nothing; each bucket goes to the bin its start falls in instead.
        for key, bucket in pairs(log.hours) do
            if type(key) == "number" then
                local index = math.floor((key - midnight) / HOUR)
                if index >= 0 and index < 24 then AddBucket(bins[index + 1], bucket) end
            end
        end
        return bins
    end

    local fromStart, toStart
    if period == "pick" and fromKey and toKey then
        fromStart, toStart = GoldLog.KeyStart(math.min(fromKey, toKey)), GoldLog.KeyStart(math.max(fromKey, toKey))
    elseif period == "all" then
        toStart = GoldLog.DayStart(now)
        -- From the first day kept, and never fewer than seven bars.
        fromStart = math.min(self:FirstDay() or toStart, GoldLog.DayStart(now, -6))
    else
        local days = GoldLog.PERIOD_DAYS[period] or 7
        toStart = GoldLog.DayStart(now)
        fromStart = GoldLog.DayStart(now, -(days - 1))
    end

    local starts = DayStarts(fromStart, toStart)

    -- Past about two months a bar a day is too thin to read: a bar a week.
    local perBin = #starts > 62 and 7 or 1

    for index = 1, #starts, perBin do
        local first = starts[index]
        local last = starts[math.min(#starts, index + perBin - 1)]
        local bin = NewBin(date(perBin > 1 and "%b %d" or "%d", first), first, GoldLog.DayStart(last, 1))
        for step = index, math.min(#starts, index + perBin - 1) do
            AddBucket(bin, log.days[GoldLog.DayKey(starts[step])])
        end
        bins[#bins + 1] = bin
    end

    return bins
end

--- Everything in a set of bins added up.
-- @return { income, spending, moved, sources = { [source] = { i, o } } }
function GoldLog:Totals(bins)
    local totals = { income = 0, spending = 0, moved = 0, sources = {} }

    for _, bin in ipairs(bins) do
        for source, line in pairs(bin.sources) do
            local into = totals.sources[source]
            if not into then
                into = { i = 0, o = 0 }
                totals.sources[source] = into
            end
            into.i = into.i + line.i
            into.o = into.o + line.o

            if SOURCE_BY_KEY[source].moved then
                totals.moved = totals.moved + line.i + line.o
            else
                totals.income = totals.income + line.i
                totals.spending = totals.spending + line.o
            end
        end
    end

    totals.net = totals.income - totals.spending
    return totals
end

--- Days with anything written down, newest first, as YYYYMMDD.
function GoldLog:Days()
    local days = {}
    for dayKey in pairs(self:GetLog().days) do
        if type(dayKey) == "number" then days[#days + 1] = dayKey end
    end
    table.sort(days, function(a, b) return a > b end)
    return days
end

--------------------------------------------------------------------------------
-- Your gold over time
--------------------------------------------------------------------------------

-- A player asked (2026-10-22, the owner said yes from a mockup): a line of
-- your total gold over the chart. For all your characters it is worked back
-- from the gold they have now and what came in and went out since, so it
-- reaches back as far as the log does. The log keeps no names, so for the
-- character playing its gold is written down as it changes, by GUID, in
-- this realm's log as `goldByCharacter[guid] = { hours, days }` (never
-- renamed), kept as long as the log's own buckets; its line starts there.

local function CharacterGold(create)
    local key = ns.Config and ns.Config.GetCharacterKey and ns.Config:GetCharacterKey()
    -- A character known only by its name is no place to keep one.
    if type(key) ~= "string" or not key:find("^Player%-") then return nil end

    local log = GoldLog:GetLog()
    if type(log.goldByCharacter) ~= "table" then
        if not create then return nil end
        log.goldByCharacter = {}
    end
    local record = log.goldByCharacter[key]
    if type(record) ~= "table" then
        if not create then return nil end
        record = { hours = {}, days = {} }
        log.goldByCharacter[key] = record
    end
    if type(record.hours) ~= "table" then record.hours = {} end
    if type(record.days) ~= "table" then record.days = {} end
    return record
end

--- Write down the gold the character playing has now.
function GoldLog:NoteGold(money, t)
    money = tonumber(money)
    if not money then return end
    local record = CharacterGold(true)
    if not record then return end
    t = t or time()
    record.hours[t - (t % HOUR)] = money
    record.days[GoldLog.DayKey(t)] = money
end

--- The character playing's kept gold past the log's own reach let go.
function GoldLog:PruneGold(now)
    now = now or time()
    local log = self:GetLog()
    if type(log.goldByCharacter) ~= "table" then return end
    local oldest = GoldLog.DayKey(now - KEEP_DAYS * DAY)
    for _, record in pairs(log.goldByCharacter) do
        if type(record) == "table" then
            for hourStart in pairs(type(record.hours) == "table" and record.hours or {}) do
                if type(hourStart) ~= "number" or hourStart < now - KEEP_HOURS then record.hours[hourStart] = nil end
            end
            for dayKey in pairs(type(record.days) == "table" and record.days or {}) do
                if type(dayKey) ~= "number" or dayKey < oldest then record.days[dayKey] = nil end
            end
        end
    end
end

-- What came in less what went out, from `t` on, never counting gold moved
-- between your own characters. `hourly` reads the hour buckets.
local function NetSince(log, t, hourly)
    local net = 0
    local function Add(bucket)
        for source, line in pairs(type(bucket) == "table" and bucket or {}) do
            local known = SOURCE_BY_KEY[source]
            if known and not known.moved and type(line) == "table" then
                net = net + (tonumber(line.i) or 0) - (tonumber(line.o) or 0)
            end
        end
    end
    if hourly then
        for key, bucket in pairs(log.hours) do
            if type(key) == "number" and key >= t then Add(bucket) end
        end
    else
        for dayKey, bucket in pairs(log.days) do
            if type(dayKey) == "number" and GoldLog.KeyStart(dayKey) >= t then Add(bucket) end
        end
    end
    return net
end

-- The session's own changes from `t` on, moved gold counted or not.
local function SessionSince(t, withMoved)
    local net = 0
    for _, change in ipairs(GoldLog.session or {}) do
        if change.t >= t and (withMoved or not SOURCE_BY_KEY[change.source].moved) then
            net = net + change.amount
        end
    end
    return net
end

-- The newest kept reading at or before `t`.
local function Reading(readings, t, byDay)
    local best, value
    for key, money in pairs(readings) do
        local at = byDay and GoldLog.KeyStart(key) or key
        if type(at) == "number" and at < t and (not best or at > best) then
            best, value = at, tonumber(money)
        end
    end
    return value
end

--- Your gold at the end of each bin from GoldLog:Bins.
--
-- @param who  "all" (every character on this realm and side) or "character"
-- @param period  the bins' period, so the right buckets are read
-- @return array, one entry a bin: copper, or false where it is not known
function GoldLog:Line(bins, who, period, now)
    now = now or time()
    local line = {}
    local log = self:GetLog()
    local hourly = period == "today"

    if who == "character" then
        local money = Money()
        local record = CharacterGold(false)
        for index, bin in ipairs(bins) do
            local at = math.min(bin.to, now)
            local value
            if period == "session" or at >= now then
                value = money and (money - SessionSince(at, true)) or nil
            elseif record then
                value = Reading(hourly and record.hours or record.days, at, not hourly)
            end
            line[index] = value or false
        end
        return line
    end

    local total
    local GoldGoal = ns.GoldGoal
    if GoldGoal and GoldGoal.Total then
        local ok, sum = pcall(GoldGoal.Total, GoldGoal, now, true)
        if ok then total = tonumber(sum) end
    end
    if not total then return line end

    for index, bin in ipairs(bins) do
        local at = math.min(bin.to, now)
        if at >= now then
            line[index] = total
        elseif period == "session" then
            line[index] = total - SessionSince(at, false)
        else
            line[index] = total - NetSince(log, at, hourly)
        end
    end
    return line
end

--------------------------------------------------------------------------------
-- Watching
--------------------------------------------------------------------------------

--- Watch a game call without replacing it, so the game's own call is unaffected.
local function Watch(owner, name, fn)
    if type(hooksecurefunc) ~= "function" then return end

    if owner then
        if type(owner) == "table" and type(owner[name]) == "function" then
            pcall(hooksecurefunc, owner, name, function(...) pcall(fn, ...) end)
        end
    elseif type(_G[name]) == "function" then
        pcall(hooksecurefunc, name, function(...) pcall(fn, ...) end)
    end
end

function GoldLog:OnEnable()
    self.session = {}
    self.sessionStart = time()
    self.lastMoney = Money()

    pcall(self.Prune, self)
    pcall(self.PruneGold, self)

    ns.RegisterEvent(self, "PLAYER_MONEY", function() GoldLog:OnMoney() end)
    ns.RegisterEvent(self, "PLAYER_ENTERING_WORLD", function()
        -- A fresh reading, so gold that changed during a loading screen is
        -- not put down to whatever happens next.
        GoldLog.lastMoney = Money() or GoldLog.lastMoney
        GoldLog.ready = true
        if GoldLog.lastMoney then pcall(GoldLog.NoteGold, GoldLog, GoldLog.lastMoney) end
    end)

    local function Window(window, showEvent, hideEvent)
        ns.RegisterEvent(self, showEvent, function() GoldLog:SetWindow(window, true) end)
        ns.RegisterEvent(self, hideEvent, function() GoldLog:SetWindow(window, false) end)
    end

    Window("auction", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED")
    Window("merchant", "MERCHANT_SHOW", "MERCHANT_CLOSED")
    Window("mail", "MAIL_SHOW", "MAIL_CLOSED")
    Window("trainer", "TRAINER_SHOW", "TRAINER_CLOSED")
    Window("taxi", "TAXIMAP_OPENED", "TAXIMAP_CLOSED")
    Window("trade", "TRADE_SHOW", "TRADE_CLOSED")
    Window("loot", "LOOT_OPENED", "LOOT_CLOSED")

    -- Coins looted, said in chat as they land.
    ns.RegisterEvent(self, "CHAT_MSG_MONEY", function() GoldLog:Tag("loot", 1) end)

    ns.RegisterEvent(self, "QUEST_TURNED_IN", function(_, _, _, _, money)
        if (tonumber(money) or 0) > 0 then GoldLog:Tag("quests", 1) end
        GoldLog:NoteQuest()
    end)

    -- The auction house: a post's deposit, and buying.
    local auctions = _G.C_AuctionHouse
    Watch(auctions, "PostItem", function() GoldLog:Tag("auctionFees", -1) end)
    Watch(auctions, "PostCommodity", function() GoldLog:Tag("auctionFees", -1) end)
    Watch(auctions, "PlaceBid", function() GoldLog:Tag("auctionBuys", -1) end)
    Watch(auctions, "ConfirmCommoditiesPurchase", function() GoldLog:Tag("auctionBuys", -1) end)

    -- The mailbox: whose gold is being taken, and gold being sent.
    local function TakeMail(index) GoldLog:NoteTakeMail(index) end
    Watch(nil, "TakeInboxMoney", TakeMail)
    Watch(nil, "AutoLootMailItem", TakeMail)
    Watch(nil, "SendMail", function(recipient)
        GoldLog:Tag(GoldLog:IsOwnCharacter(recipient) and "transfer" or "mail", -1)
    end)

    Watch(nil, "RepairAllItems", function() GoldLog:Tag("repairs", -1) end)
    Watch(nil, "TakeTaxiNode", function() GoldLog:Tag("flights", -1) end)
end
