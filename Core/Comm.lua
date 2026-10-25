-- Blackthornes Tradeskills -- Core/Comm.lua
-- Addon messages: talking to the same addon on another player's client.
--
-- Asked 2026-10-07 (on Discord, the owner agreeing): share a player's
-- characters between their own accounts, and auction prices within a guild,
-- without a desktop app. Logic/AccountLink.lua and Logic/GuildPrices.lua are
-- the two features; this file is only the wire they share.
--
-- What the client allows, as on retail (not yet measured on Forever; /bts
-- share test reports it):
--   * A message is at most 255 bytes, under a registered prefix of up to 16.
--   * Each prefix is throttled: a short burst, then about one a second. A
--     throttled send is refused, not queued, so this file queues and paces.
--   * WHISPER reaches one character on the same realm; GUILD the guild.
--
-- Everything that arrives is data from another client, and nothing here or
-- in the features ever runs it: tables come through Core/Serialize.lua,
-- which can only produce data, and every value is checked before use.

local _, ns = ...

local Comm = ns.NewModule("Comm")

Comm.PREFIX = "BTSshare"

-- 255 is the client's limit for the whole message.
Comm.MAX_MESSAGE = 255

-- A chunk header is "D" + kind + id,index,total + ":", at most 14 bytes.
local CHUNK_DATA = 236

-- What one sender may have arriving at once, and for how long a part-sent
-- table is waited on. A transfer bigger than this is dropped, not stored.
Comm.MAX_CHUNKS = 1500
Comm.MAX_PARTIAL = 8
local PARTIAL_TIMEOUT = 180

-- Pacing: a burst of this many, then one every this many seconds.
local BURST = 8
local REFILL_SECONDS = 1.0

-- Send results the client calls a throttle: tried again later.
local THROTTLE_CODES = { [3] = true, [8] = true }

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

--- A whole, non-negative number in base 36: "1a2b". Shorter than decimal on
--- the wire, which is what decides how many prices fit in a message.
function Comm.ToBase36(number)
    number = math.floor(tonumber(number) or 0)
    if number <= 0 then return "0" end
    local out = {}
    while number > 0 do
        local digit = number % 36
        out[#out + 1] = DIGITS:sub(digit + 1, digit + 1)
        number = (number - digit) / 36
    end
    return string.reverse(table.concat(out))
end

function Comm.FromBase36(text)
    if type(text) ~= "string" or text == "" or #text > 12 or text:find("[^0-9a-z]") then return nil end
    return tonumber(text, 36)
end

--- A 32-bit hash of a string, the same on every client. For telling
--- whether a character changed since it was last sent, never for security.
function Comm.Hash(text)
    local hash = 5381
    for i = 1, #text do
        hash = (hash * 33 + text:byte(i)) % 4294967296
    end
    return Comm.ToBase36(hash)
end

-- Bytes a message must not carry: the client refuses a NUL, and a pipe or a
-- line break has a meaning in chat text. \001 is the escape itself.
local ESCAPES = { ["\001"] = "\001\001", ["\000"] = "\001\002", ["|"] = "\001\003",
                  ["\n"] = "\001\004", ["\r"] = "\001\005" }
local UNESCAPES = { ["\001"] = "\001", ["\002"] = "\000", ["\003"] = "|",
                    ["\004"] = "\n", ["\005"] = "\r" }

function Comm.Escape(text)
    return (text:gsub("[%z\001|\n\r]", ESCAPES))
end

function Comm.Unescape(text)
    return (text:gsub("\001(.)", UNESCAPES))
end

--- A plain copy of a string the client handed over, or nil. Inside a
--- dungeon the client can hand addons names that raise when compared, so
--- the test and the copy happen inside the pcall.
local function CopyPlain(value)
    if type(value) ~= "string" or value == "" then return nil end
    return value .. ""
end

function Comm.Plain(value)
    -- A named function, not a new one per call: every addon's messages
    -- come through here, hundreds a second in a raid.
    local ok, copy = pcall(CopyPlain, value)
    return ok and copy or nil
end

--- "Ana-Realm" -> "ana": how two names are compared. Realms are dropped,
--- since a whisper only ever reaches the same realm.
function Comm.NameKey(name)
    if type(name) ~= "string" then return nil end
    local short = name:match("^([^%-]+)") or name
    short = short:gsub("^%s+", ""):gsub("%s+$", "")
    if short == "" then return nil end
    return short:lower()
end

local function FirstName()
    local ok, name = pcall(function() return UnitName("player") .. "" end)
    return ok and name or nil
end

local surname, surnameAsked
--- This character's last name, when the game will say it (Config:ReadSurname).
local function Surname()
    if surnameAsked then return surname end
    local config = ns.Config
    if config and config.ReadSurname then
        local ok, found = pcall(config.ReadSurname, config)
        -- A read that raised (a name the game would not let the addon see
        -- just then) is asked again next time, not remembered as "none".
        if not ok then return nil end
        surnameAsked = true
        if type(found) == "string" and found ~= "" then surname = found end
    end
    return surname
end

--- The name whispers reach this character by. Forever lets characters share
--- a first name, so a whisper needs the first and last name together, and
--- an addon message's sender reads that way too: "Ana Smith", no realm
--- (seen 2026-10-07: a whisper to the first name alone found nobody).
local function PlayerName()
    local first = FirstName()
    local last = first and Surname()
    if last then return first .. " " .. last end
    return first
end
Comm.PlayerName = PlayerName

--- Did this character send it? By the whole name when the last name is
--- known; by the first word when the game would not say the last name.
function Comm.IsMe(sender)
    local key = Comm.NameKey(sender)
    if not key then return false end
    if key == Comm.NameKey(PlayerName()) then return true end
    if Surname() then return false end
    return key:match("^(%S+)") == Comm.NameKey(FirstName())
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

Comm.queue = {}
Comm.sent, Comm.refused, Comm.retried = 0, 0, 0
local tokens, lastRefill = BURST, nil
-- Started from the clock, not 0: after a /reload the first transfer reused
-- the last session's ID, and a partner still holding half of that one merged
-- the old parts with the new.
local nextTransfer = math.floor((type(time) == "function" and time() or 0) % 1296)

local function Now()
    local ok, now = pcall(GetTime)
    return ok and now or 0
end

--- "Ana" -> "Ana-Realm", this character's realm, for a whisper. On Classic
--- Era (2026-10-25) a whisper by the bare name never arrived for one player,
--- even to themselves, and arrived with the realm on; a name that already
--- carries a realm is left as it is.
local function WithRealm(target)
    if type(target) ~= "string" or target == "" or target:find("-", 1, true) then return target end
    local ok, realm = pcall(function()
        local name = type(GetNormalizedRealmName) == "function" and GetNormalizedRealmName() or nil
        if (not name or name == "") and type(GetRealmName) == "function" then
            name = (GetRealmName() or ""):gsub("[%s%-]", "")
        end
        return name .. ""
    end)
    if not ok or not realm or realm == "" then return target end
    return target .. "-" .. realm
end
Comm.WithRealm = WithRealm

--- Hand one message to the client. "sent", "throttled", or "failed" and why.
function Comm.RawSend(text, channel, target)
    if channel == "WHISPER" then target = WithRealm(target) end
    local ok, result
    if type(C_ChatInfo) == "table" and type(C_ChatInfo.SendAddonMessage) == "function" then
        ok, result = pcall(C_ChatInfo.SendAddonMessage, Comm.PREFIX, text, channel, target)
    elseif type(SendAddonMessage) == "function" then
        ok, result = pcall(SendAddonMessage, Comm.PREFIX, text, channel, target)
    else
        return "failed", "no SendAddonMessage"
    end

    if not ok then return "failed", tostring(result) end
    -- Older clients return nothing; newer ones true/false or a result code.
    if result == nil or result == true or result == 0 then return "sent" end
    if type(result) == "number" and THROTTLE_CODES[result] then return "throttled", result end
    if result == false then return "throttled", false end
    return "failed", result
end

local function InCombat()
    local ok, inCombat = pcall(InCombatLockdown)
    return ok and inCombat == true
end

--- Send what the pacing allows. Waits out combat: nothing here is urgent,
--- and a fight is no time to spend the frame on it.
function Comm:Pump()
    if #self.queue == 0 then
        if self.ticker then self.ticker:Cancel() self.ticker = nil end
        return
    end
    if InCombat() then return end

    local now = Now()
    if lastRefill then
        tokens = math.min(BURST, tokens + (now - lastRefill) / REFILL_SECONDS)
    end
    lastRefill = now

    while tokens >= 1 and #self.queue > 0 do
        local message = self.queue[1]
        local outcome, why = Comm.RawSend(message.text, message.channel, message.target)

        if outcome == "throttled" then
            -- Left at the front; the bucket starts again from empty.
            tokens = 0
            message.tries = (message.tries or 0) + 1
            self.retried = self.retried + 1
            if message.tries > 10 then
                table.remove(self.queue, 1)
                self.refused = self.refused + 1
            end
            return
        end

        table.remove(self.queue, 1)
        tokens = tokens - 1
        if outcome == "sent" then
            self.sent = self.sent + 1
            if message.channel == "WHISPER" and message.target then
                self:NoteWhisper(message.target)
            end
        else
            self.refused = self.refused + 1
            self.lastRefusal = why
        end
    end
end

local function StartPump()
    if Comm.ticker or type(C_Timer) ~= "table" then return end
    Comm.ticker = C_Timer.NewTicker(0.25, function() Comm:Pump() end)
end

--- Queue one message: a kind letter and its text, escaped already.
function Comm:Send(kind, text, channel, target)
    local message = kind .. (text or "")
    if #message > Comm.MAX_MESSAGE then return false end
    self.queue[#self.queue + 1] = { text = message, channel = channel, target = target }
    self:Pump()
    StartPump()
    return true
end

--- Queue a whole table, cut into as many messages as it takes.
-- @return how many messages it took
function Comm:SendTable(kind, value, channel, target)
    local ok, encoded = pcall(ns.Serialize.Encode, value)
    if not ok or type(encoded) ~= "string" then return 0 end

    local text = Comm.Escape(encoded)
    local total = math.max(1, math.ceil(#text / CHUNK_DATA))
    if total > Comm.MAX_CHUNKS then return 0 end

    nextTransfer = (nextTransfer + 1) % 1296
    local id = Comm.ToBase36(nextTransfer)
    local count = Comm.ToBase36(total)

    for index = 1, total do
        local part = text:sub((index - 1) * CHUNK_DATA + 1, index * CHUNK_DATA)
        self:Send("D", kind .. id .. "," .. Comm.ToBase36(index) .. "," .. count .. ":" .. part,
            channel, target)
    end
    return total
end

--- Is anything still waiting to go out?
function Comm:Pending()
    return #self.queue
end

--------------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------------

Comm.handlers = {}
Comm.tableHandlers = {}
Comm.received = 0
local partial = {}

--- fn(sender, text, channel) for a one-message kind.
function Comm:On(kind, fn) self.handlers[kind] = fn end

--- fn(sender, value, channel) for a kind sent with SendTable.
function Comm:OnTable(kind, fn) self.tableHandlers[kind] = fn end

local function Dispatch(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then ns.Debug("share: a message could not be read:", tostring(err)) end
end

--- Drops the transfers that went quiet; answers how many of `sender`'s
--- are still in flight, so one sender's stuck transfers cap only theirs.
local function DropExpired(now, sender)
    local count = 0
    local prefix = sender .. "\001"
    for key, entry in pairs(partial) do
        if now - entry.at > PARTIAL_TIMEOUT then
            partial[key] = nil
        elseif key:sub(1, #prefix) == prefix then
            count = count + 1
        end
    end
    return count
end

local function ReceiveChunk(sender, body, channel)
    local kind, id, index, total, data = body:match("^(%a)(%w+),(%w+),(%w+):(.*)$")
    index, total = Comm.FromBase36(index), Comm.FromBase36(total)
    if not kind or not index or not total or total < 1 or total > Comm.MAX_CHUNKS
        or index < 1 or index > total then return end
    if not Comm.tableHandlers[kind] then return end

    local now = Now()
    local key = sender .. "\001" .. channel .. "\001" .. kind .. id
    local entry = partial[key]
    if not entry then
        if DropExpired(now, sender) >= Comm.MAX_PARTIAL then return end
        entry = { parts = {}, have = 0, total = total, at = now }
        partial[key] = entry
    end
    if entry.total ~= total then partial[key] = nil return end

    entry.at = now
    if not entry.parts[index] then
        entry.parts[index] = data
        entry.have = entry.have + 1
    end
    if entry.have < total then return end

    partial[key] = nil
    local text = Comm.Unescape(table.concat(entry.parts, "", 1, total))
    local ok, value = ns.Serialize.Decode(text)
    if ok and type(value) == "table" then
        Dispatch(Comm.tableHandlers[kind], sender, value, channel)
    end
end

--- One addon message arrived. Everything about it is read as plain data.
function Comm:CHAT_MSG_ADDON(_, prefix, text, channel, sender, target, zoneChannelID, localID, channelName)
    -- The prefix first: most messages are other addons', and theirs are
    -- dropped before anything else of them is copied.
    prefix = Comm.Plain(prefix)
    if prefix ~= Comm.PREFIX then return end
    text, channel, sender = Comm.Plain(text), Comm.Plain(channel), Comm.Plain(sender)
    if not text or not channel or not sender then return end
    if #text > Comm.MAX_MESSAGE then return end

    self.received = self.received + 1
    if self.testing then self:NoteTestEcho(text, sender) end
    if self.channelTest then
        self:NoteChannelEcho(text, sender, channel, Comm.Plain(target), localID, Comm.Plain(channelName))
    end

    local kind, body = text:sub(1, 1), text:sub(2)
    if kind == "D" then
        ReceiveChunk(sender, body, channel)
    elseif self.handlers[kind] then
        -- A channel's name and number come along for handlers that listen to
        -- one (Logic/RealmPrices.lua); the others take only the first three.
        Dispatch(self.handlers[kind], sender, body, channel, Comm.Plain(channelName), Comm.Plain(target))
    end
end

--------------------------------------------------------------------------------
-- Whispers to someone not playing
--------------------------------------------------------------------------------

-- Whispering a character who is not logged in puts "No player named X is
-- currently playing" in chat. Saying hello to a partner who is offline is
-- normal here, so that line is kept out of chat for names just whispered,
-- and tells the features the partner is away.
local whispered = {}

function Comm:NoteWhisper(name)
    local key = Comm.NameKey(name)
    if key then whispered[key] = Now() end
end

local notFoundPattern
local function NotFoundName(message)
    if not notFoundPattern then
        local format = type(ERR_CHAT_PLAYER_NOT_FOUND_S) == "string" and ERR_CHAT_PLAYER_NOT_FOUND_S
            or "No player named '%s' is currently playing."
        notFoundPattern = "^" .. format:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)") .. "$"
    end
    return message:match(notFoundPattern)
end

function Comm.FilterNotFound(_, _, message)
    -- Nobody whispered lately: no line to hide, and nothing to read.
    if next(whispered) == nil then return false end
    local plain = Comm.Plain(message)
    if not plain then return false end
    local name = NotFoundName(plain)
    local key = name and Comm.NameKey(name)
    local at = key and whispered[key]
    if not at or Now() - at > 10 then return false end

    if Comm.onOffline then pcall(Comm.onOffline, key) end
    return true
end

--------------------------------------------------------------------------------
-- The test (/bts share test)
--------------------------------------------------------------------------------

--- Whisper this character a few messages and report what the client did:
--- whether the prefix registered, what each send returned, whether they
--- came back, how the sender's name reads, and where pacing starts.
function Comm:Test()
    local me = PlayerName()
    if not me then ns.Print("share test: the game would not say this character's name") return end

    local registered = self.registered
    ns.Print(("share test: prefix %s registered: %s, whispering \"%s\""):format(
        Comm.PREFIX, tostring(registered), me))
    -- Keeps "No player named" out of chat if the name is still wrong.
    self:NoteWhisper(me)

    self.testing = { at = Now(), echoes = 0, sender = nil }

    local full = ("T"):rep(Comm.MAX_MESSAGE)
    local outcome, why = Comm.RawSend(full, "WHISPER", me)
    ns.PrintRaw(("  a 255-byte whisper to yourself: %s %s"):format(outcome, tostring(why or "")))
    local tooLong, whyLong = Comm.RawSend(full .. "T", "WHISPER", me)
    ns.PrintRaw(("  a 256-byte one (should be refused): %s %s"):format(tooLong, tostring(whyLong or "")))

    local results = {}
    for i = 1, 12 do
        local burst = Comm.RawSend("t" .. i, "WHISPER", me)
        results[#results + 1] = burst
    end
    ns.PrintRaw("  12 in a row: " .. table.concat(results, ", "))

    local inGuild = false
    pcall(function() inGuild = IsInGuild() == true end)
    if inGuild then
        local guildOutcome = Comm.RawSend("tguild", "GUILD")
        ns.PrintRaw("  one to your guild: " .. guildOutcome)
    else
        ns.PrintRaw("  not in a guild, so guild messages were not tried")
    end

    C_Timer.After(3, function()
        local test = Comm.testing
        Comm.testing = nil
        if not test then return end
        ns.PrintRaw(("  came back: %d message(s), sender read as \"%s\""):format(
            test.echoes, tostring(test.sender or "nothing arrived")))
        ns.PrintRaw("  Paste these lines in the thread so the sharing can be checked against them.")
    end)
end

function Comm:NoteTestEcho(text, sender)
    local first = text:sub(1, 1)
    if first ~= "T" and first ~= "t" then return end
    self.testing.echoes = self.testing.echoes + 1
    self.testing.sender = sender
end

--------------------------------------------------------------------------------
-- The channel check (/bts share channel)
--------------------------------------------------------------------------------

-- The owner picked it (2026-10-20): auction prices shared between players
-- of the same realm over a hidden chat channel, not only the guild. Before
-- anything is built, this asks the client what it allows: whether an addon
-- can join a channel of its own, send addon messages on it ("CHANNEL"),
-- hear its own come back, how big one may be, how fast they may go, and
-- whether the join and leave lines can be kept out of chat. It joins a
-- test channel, sends a few dozen short messages, leaves again and saves
-- every line it printed for Claude. Nothing is shared and nothing is kept.

Comm.TEST_CHANNEL = "BTSPriceTest"

-- How many to send at once, and how many paced, one every PACED_GAP seconds.
Comm.CHANNEL_BURST = 30
Comm.CHANNEL_PACED = 20
local PACED_GAP = 0.5
-- Seconds to wait for the join, for messages to come back, for the leave.
local JOIN_WAIT, ECHO_WAIT, LEAVE_WAIT = 2, 3, 2

local function After(seconds, fn)
    if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
        C_Timer.After(seconds, fn)
    else
        fn()
    end
end

--- Print a line of the channel check, and add it to the saved check when it
--- arrives after the check's own frame (the timers below).
local function ChannelLine(text)
    ns.PrintRaw(text)
    local test = Comm.channelTest
    if not (test and test.late) then return end
    local db = ns.db and ns.db.global
    local probe = type(db) == "table" and db.lastProbe
    if type(probe) == "table" and probe.check == "share channel" and type(probe.lines) == "table" then
        probe.lines[#probe.lines + 1] = text
    end
end

--- The channel's number and name as the client gives them; 0 when not in it.
function Comm.ChannelNumber(name)
    if type(GetChannelName) ~= "function" then return 0 end
    local ok, id, shown = pcall(GetChannelName, name)
    if not ok then return 0 end
    return tonumber(id) or 0, Comm.Plain(shown)
end

--- How many chat channels this character is in now.
local function ChannelCount()
    if type(GetChannelList) ~= "function" then return nil end
    local ok, count = pcall(function() return select("#", GetChannelList()) / 3 end)
    return ok and count or nil
end

--- Hides the test channel's join and leave lines and counts them.
function Comm.FilterChannelNotice(_, _, notice, _, _, channelString, _, _, _, _, channelName)
    local test = Comm.channelTest
    if not test then return false end
    local name = Comm.Plain(channelName) or Comm.Plain(channelString) or ""
    if not name:lower():find(Comm.TEST_CHANNEL:lower(), 1, true) then return false end
    test.hidden = test.hidden + 1
    test.notices[#test.notices + 1] = Comm.Plain(notice) or "?"
    return true
end

local function Describe(outcome, why)
    if why == nil or why == "" then return outcome end
    return outcome .. " (" .. tostring(why) .. ")"
end

function Comm:ChannelTest()
    if InCombat() then ns.Print("share channel: try again out of a fight") return end
    if self.channelTest then ns.Print("share channel: the check is already running") return end

    local name = Comm.TEST_CHANNEL
    local test = { echoes = {}, hidden = 0, notices = {}, late = false }
    self.channelTest = test

    ns.Print("share channel: checking a hidden chat channel for sharing prices. It takes about 20 seconds.")
    ChannelLine(("  prefix %s registered: %s"):format(Comm.PREFIX, tostring(self:Register())))
    ChannelLine(("  calls: JoinTemporaryChannel %s, JoinChannelByName %s, LeaveChannelByName %s, GetChannelName %s, C_ChatInfo.SendAddonMessage %s"):format(
        tostring(type(JoinTemporaryChannel) == "function"), tostring(type(JoinChannelByName) == "function"),
        tostring(type(LeaveChannelByName) == "function"), tostring(type(GetChannelName) == "function"),
        tostring(type(C_ChatInfo) == "table" and type(C_ChatInfo.SendAddonMessage) == "function")))
    ChannelLine("  channels you are in now: " .. tostring(ChannelCount() or "unknown"))

    if not self.noticeFilter and type(ChatFrame_AddMessageEventFilter) == "function" then
        self.noticeFilter = pcall(ChatFrame_AddMessageEventFilter, "CHAT_MSG_CHANNEL_NOTICE",
            Comm.FilterChannelNotice)
    end

    local already = Comm.ChannelNumber(name)
    local join, ok, a, b = "none", false, nil, nil
    if already > 0 then
        join = "already in it"
    elseif type(JoinTemporaryChannel) == "function" then
        join = "JoinTemporaryChannel"
        ok, a, b = pcall(JoinTemporaryChannel, name)
    elseif type(JoinChannelByName) == "function" then
        join = "JoinChannelByName"
        ok, a, b = pcall(JoinChannelByName, name)
    end
    if join ~= "already in it" then
        ChannelLine(("  join with %s: %s, returned %s, %s"):format(join,
            ok and "ran" or "raised", tostring(a), tostring(b)))
    end

    test.late = true
    After(JOIN_WAIT, function() Comm:ChannelSend(name) end)
end

function Comm:ChannelSend(name)
    local test = self.channelTest
    if not test then return end
    local id, shown = Comm.ChannelNumber(name)
    ChannelLine(("  in the channel after %d seconds: %s (number %d, named \"%s\")"):format(
        JOIN_WAIT, tostring(id > 0), id, tostring(shown or "")))
    ChannelLine("  channels you are in now: " .. tostring(ChannelCount() or "unknown"))
    if id <= 0 then
        ChannelLine("  could not join, so nothing was sent")
        return self:ChannelLeave(name)
    end

    local target = tostring(id)
    local outcome, why = Comm.RawSend("cL" .. ("L"):rep(Comm.MAX_MESSAGE - 2), "CHANNEL", target)
    ChannelLine("  a 255-byte message: " .. Describe(outcome, why))
    outcome, why = Comm.RawSend("cX" .. ("X"):rep(Comm.MAX_MESSAGE - 1), "CHANNEL", target)
    ChannelLine("  a 256-byte one (should be refused): " .. Describe(outcome, why))

    local results, firstRefused, sent = {}, nil, 0
    for i = 1, Comm.CHANNEL_BURST do
        outcome, why = Comm.RawSend("cA" .. i, "CHANNEL", target)
        if outcome == "sent" then
            sent = sent + 1
        elseif not firstRefused then
            firstRefused = i
            results[#results + 1] = ("#%d %s"):format(i, Describe(outcome, why))
        end
    end
    ChannelLine(("  %d at once: %d went, first refused %s"):format(Comm.CHANNEL_BURST, sent,
        firstRefused and results[1] or "none"))
    test.burstSent = sent

    -- Paced: one every PACED_GAP seconds, after the burst's echoes are in.
    After(ECHO_WAIT, function()
        ChannelLine(("  came back from that: long %d, at once %d, sender read as \"%s\", channel %s, target %s, number %s, name %s"):format(
            test.echoes.L or 0, test.echoes.A or 0, tostring(test.sender or "nothing arrived"),
            tostring(test.channel), tostring(test.target), tostring(test.localID), tostring(test.channelName)))
        local paced, refused = 0, 0
        local function Step(i)
            if i > Comm.CHANNEL_PACED then
                ChannelLine(("  %d paced, one every %.1f s: %d went, %d refused"):format(
                    Comm.CHANNEL_PACED, PACED_GAP, paced, refused))
                After(ECHO_WAIT, function()
                    ChannelLine(("  came back from the paced ones: %d"):format(test.echoes.B or 0))
                    Comm:ChannelLeave(name)
                end)
                return
            end
            local result, reason = Comm.RawSend("cB" .. i, "CHANNEL", target)
            if result == "sent" then paced = paced + 1 else
                refused = refused + 1
                if refused == 1 then ChannelLine(("  paced #%d refused: %s"):format(i, Describe(result, reason))) end
            end
            After(PACED_GAP, function() Step(i + 1) end)
        end
        Step(1)
    end)
end

function Comm:ChannelLeave(name)
    if type(LeaveChannelByName) == "function" then pcall(LeaveChannelByName, name) end
    After(LEAVE_WAIT, function()
        local test = Comm.channelTest
        local id = Comm.ChannelNumber(name)
        ChannelLine(("  left the channel: %s"):format(tostring(id <= 0)))
        if test then
            ChannelLine(("  join and leave lines kept out of chat: %d (%s)"):format(test.hidden,
                #test.notices > 0 and table.concat(test.notices, ", ") or "none seen"))
        end
        ChannelLine("  done. Type /reload so Claude can read these lines.")
        Comm.channelTest = nil
    end)
end

--- One of the channel check's own messages came back.
function Comm:NoteChannelEcho(text, sender, channel, target, localID, channelName)
    local test = self.channelTest
    if text:sub(1, 1) ~= "c" then return end
    local phase = text:sub(2, 2)
    test.echoes[phase] = (test.echoes[phase] or 0) + 1
    test.sender, test.channel, test.target = sender, channel, target
    test.localID, test.channelName = localID, channelName
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function Comm:Register()
    if self.registered ~= nil then return self.registered end

    local ok, result
    if type(C_ChatInfo) == "table" and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function" then
        ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, Comm.PREFIX)
    elseif type(RegisterAddonMessagePrefix) == "function" then
        ok, result = pcall(RegisterAddonMessagePrefix, Comm.PREFIX)
    end
    -- true, nil (older clients) or result code 0 all mean it took.
    self.registered = ok == true and (result == nil or result == true or result == 0)
    return self.registered
end

function Comm:OnEnable()
    self:Register()
    ns.RegisterEvent(self, "CHAT_MSG_ADDON", self.CHAT_MSG_ADDON)
    if type(ChatFrame_AddMessageEventFilter) == "function" then
        pcall(ChatFrame_AddMessageEventFilter, "CHAT_MSG_SYSTEM", Comm.FilterNotFound)
    end
end
