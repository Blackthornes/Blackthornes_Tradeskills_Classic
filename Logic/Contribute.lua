-- Blackthornes Tradeskills -- Logic/Contribute.lua
-- Data a player chooses to send to the addon's maker.
--
-- Asked 2026-10-18 by the owner, as Farmer already does for drops: players
-- who opt in send what their own disenchants gave and the skill each recipe
-- needs on Forever, so both can be folded into the shipped data at a
-- release. Off by default: one tick box on the About page of Settings.
-- Never announced.
--
-- The conversation, one way:
--   * A player with it ticked whispers a short hello ("Q<id>:<hash>") to
--     each name in RECIPIENTS, soon after login and every five minutes. The
--     hash says what they have; nothing in chat or Settings says whether
--     anyone was there (Comm hides the game's "No player named ..." line).
--   * Only the characters named in RECIPIENTS answer, and only for a hash
--     they have not taken: "R<id>" asks for it. The sender answers only a
--     recipient asking for its own id, at most every SEND_GAP, with one
--     table ("K"). Nothing ever flows back to the player.
--   * What goes: the sender's own disenchant results by item
--     (disenchantLog.items) and the recipe skills its tooltips gave
--     (recipeSkills). Game IDs and numbers only; no names, nothing taken
--     from anyone else. Both are the same in every language, so any client
--     sends.
--   * On the receiving side each sender's latest table replaces the one
--     before (`sharedData[id]`), so nothing is ever counted twice. It never
--     joins the receiver's own disenchants or recipe skills, and nothing in
--     the windows reads it. One sender is taken at a time, the next as
--     soon as one is done (or given up after SYNC_TIMEOUT), each at most
--     every SYNC_GAP, and at most MAX_SENDERS are kept.
--   * When a table comes in, one chat line says so, with a sound and a
--     line on screen. `/bts share data log` (typed only) lists them.
--   * Only North American players send (InRegion), since a whisper never
--     crosses regions.
--
-- Saved, account wide, never renamed: `shareData` (the player's choice, in
-- settings), `shareDataId`, and on a receiving account `sharedData` and
-- `sharedDataLog`.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Contribute = ns.NewModule("Contribute")

local Comm = ns.Comm

-- The characters data is sent to, as Name-Realm. Kept only here, never
-- shown to players. This is the Classic Era copy: the owner's Era
-- characters (2026-10-26), never Forever's. A whisper on Era only reaches
-- the same realm, so a name is used only by players on its realm
-- (Recipients); anyone else has nobody to send to and sees no tick box.
Contribute.RECIPIENTS = {
    "Blackthornes-Ashkandi",
    "Blacklock-Ashkandi",
}

-- North America only, as in Farmer: GetCurrentRegion's 1 is the Americas;
-- a client that will not say sends nothing.
Contribute.REGIONS = { [1] = true }
Contribute.REGION_NAME = "US"

Contribute.HELLO_SECONDS = 300    -- a hello every five minutes (the owner, 2026-10-26)
Contribute.FIRST_HELLO = 30       -- and this long after login
Contribute.SYNC_GAP = 300         -- one sender taken at most this often
Contribute.SYNC_TIMEOUT = 1800    -- an ask left unanswered this long is given up (a big
                                  -- table takes a while at Comm's pace)
Contribute.SEND_GAP = 300         -- a sender answers a recipient at most this often
Contribute.PAYLOAD_KEEP = 1800    -- the table and its hash are built at most this often
Contribute.MAX_SENDERS = 500
Contribute.MAX_ITEMS = 3000       -- disenchanted items in one table
Contribute.MAX_SKILLS = 5000      -- recipe skills in one table
Contribute.MAX_ID = 10000000      -- an item ID past this is not an item
Contribute.MAX_CASTS = 100000
Contribute.MAX_SKILL = 450
Contribute.LOG_KEEP = 100
Contribute.LOG_SHOW = 20

Contribute.queue = {}      -- receiving: { id, name } waiting their turn
Contribute.sentTo = {}     -- sending: recipient key -> time last answered

local function Now()
    return type(time) == "function" and time() or 0
end

local function ValidId(id)
    return type(id) == "string" and #id >= 6 and #id <= 16 and id:match("^%x+$") ~= nil
end

local function WholeNumber(value, low, high)
    return type(value) == "number" and value == math.floor(value) and value >= low and value <= high
end

--------------------------------------------------------------------------------
-- Who and where
--------------------------------------------------------------------------------

--- "Ana-Some Realm" -> "somerealm": a name's realm as two realms are
--- compared, or nil when it names none.
local function RealmKey(name)
    local realm = type(name) == "string" and name:match("%-(.+)$") or nil
    if not realm then return nil end
    realm = realm:gsub("[%s%-']", ""):lower()
    return realm ~= "" and realm or nil
end
Contribute.RealmKey = RealmKey

--- The realm of the character playing, as RealmKey gives it, or nil.
local function MyRealm()
    local ok, realm = pcall(function()
        local name = type(GetNormalizedRealmName) == "function" and GetNormalizedRealmName() or nil
        if (not name or name == "") and type(GetRealmName) == "function" then name = GetRealmName() end
        return name .. ""
    end)
    if not ok then return nil end
    return RealmKey("x-" .. realm)
end
Contribute.MyRealm = MyRealm

--- The recipients as { key, name }: only those on the realm of the character
--- playing (a name with no realm counts on any), since a whisper reaches no
--- other; with the realm not read, none that name one.
function Contribute:Recipients()
    local list, seen = {}, {}
    local here
    for _, name in ipairs(self.RECIPIENTS) do
        local key = type(name) == "string" and Comm.NameKey(name)
        local realm = key and RealmKey(name)
        if realm then
            here = here or MyRealm() or false
            if realm ~= here then key = nil end
        end
        if key and not seen[key] then
            seen[key] = true
            list[#list + 1] = { key = key, name = name }
        end
    end
    return list
end

function Contribute:IsRecipient(name)
    local key = Comm.NameKey(name)
    if not key then return false end
    for _, recipient in ipairs(self:Recipients()) do
        if recipient.key == key then return true end
    end
    return false
end

--- True when the character playing is one of the recipients, by its name
--- on its own realm.
function Contribute:Receiving()
    local mine = Comm.PlayerName and Comm.PlayerName()
    if type(mine) ~= "string" or mine == "" then return false end
    return self:IsRecipient(mine)
end

function Contribute:On()
    return ns.Config ~= nil and ns.Config:Get("shareData") == true
end

function Contribute:InRegion()
    if type(GetCurrentRegion) == "function" then
        local ok, region = pcall(GetCurrentRegion)
        if ok and type(region) == "number" then return self.REGIONS[region] == true end
    end
    if type(GetCurrentRegionName) == "function" then
        local ok, name = pcall(GetCurrentRegionName)
        if ok and type(name) == "string" then return name == self.REGION_NAME end
    end
    return false
end

function Contribute:Sending()
    return self:On() and #self:Recipients() > 0 and self:InRegion() and not self:Receiving()
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

--- This account's id, made once and kept.
function Contribute:Id()
    if not ns.db then return nil end
    if not ValidId(ns.db.shareDataId) then
        local parts = {}
        for i = 1, 12 do parts[i] = string.format("%x", math.random(0, 15)) end
        ns.db.shareDataId = table.concat(parts)
    end
    return ns.db.shareDataId
end

--- What goes: the player's own disenchant results and recipe skills, as
--- plain numbers keyed by game IDs.
function Contribute:Payload()
    local payload = { d = {}, s = {} }
    local log = ns.db and ns.db.disenchantLog
    local items = type(log) == "table" and type(log.items) == "table" and log.items or {}
    local count = 0
    for itemID, record in pairs(items) do
        if count >= self.MAX_ITEMS then break end
        if WholeNumber(itemID, 1, self.MAX_ID) and type(record) == "table"
            and WholeNumber(record.casts, 1, self.MAX_CASTS) and type(record.got) == "table" then
            local got = {}
            for materialID, entry in pairs(record.got) do
                if WholeNumber(materialID, 1, self.MAX_ID) and type(entry) == "table"
                    and WholeNumber(entry.times, 1, record.casts)
                    and WholeNumber(entry.total, 1, record.casts * 50) then
                    got[materialID] = { t = entry.times, n = entry.total }
                end
            end
            payload.d[itemID] = { c = record.casts, g = got }
            count = count + 1
        end
    end
    count = 0
    local skills = ns.db and ns.db.recipeSkills
    for itemID, record in pairs(type(skills) == "table" and skills or {}) do
        if count >= self.MAX_SKILLS then break end
        if WholeNumber(itemID, 1, self.MAX_ID) and type(record) == "table"
            and WholeNumber(record.skill, 1, self.MAX_SKILL) then
            payload.s[itemID] = record.skill
            count = count + 1
        end
    end
    return payload
end

function Contribute:Hash(payload)
    local ok, text = pcall(ns.Serialize.EncodeCanonical, payload)
    return ok and type(text) == "string" and Comm.Hash(text) or nil
end

--- Nothing to send while both lists are empty.
local function Empty(payload)
    return next(payload.d) == nil and next(payload.s) == nil
end

--- The table and its hash, built at most every PAYLOAD_KEEP and kept per
--- id: a hello goes every five minutes, and building and hashing the whole
--- table each time would be a hitch for a player with a lot of it. The ask
--- sends this same build, so what a recipient keeps always carries the hash
--- it last heard and nothing is asked for twice.
function Contribute:Built()
    local id = self:Id()
    local built = self.built
    if built and built.id == id and Now() - built.at < self.PAYLOAD_KEEP then return built end
    local payload = self:Payload()
    built = { id = id, payload = payload, hash = self:Hash(payload), empty = Empty(payload), at = Now() }
    self.built = built
    return built
end

function Contribute:Hello()
    if not self:Sending() then return end
    local built = self:Built()
    local id, hash = built.id, built.hash
    if not id or built.empty or not hash then return end
    for _, recipient in ipairs(self:Recipients()) do
        Comm:Send("Q", id .. ":" .. hash, "WHISPER", recipient.name)
    end
end

--- A recipient asked for this account's table.
function Contribute:OnAsk(sender, body, channel)
    if channel ~= "WHISPER" or not self:Sending() or not self:IsRecipient(sender) then return end
    if body ~= self:Id() then return end
    local key = Comm.NameKey(sender)
    local last = self.sentTo[key]
    if last and Now() - last < self.SEND_GAP then return end
    local built = self:Built()
    if built.empty or not built.hash then return end
    self.sentTo[key] = Now()
    local payload = built.payload
    payload.i, payload.h = built.id, built.hash
    Comm:SendTable("K", payload, "WHISPER", sender)
end

--------------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------------

local function Store(create)
    if not ns.db then return nil end
    if type(ns.db.sharedData) ~= "table" then
        if not create then return nil end
        ns.db.sharedData = {}
    end
    return ns.db.sharedData
end

--- A hello from a player: ask for their table when it is new to us.
function Contribute:OnHello(sender, body, channel)
    if channel ~= "WHISPER" or not self:Receiving() or Comm.IsMe(sender) then return end
    local id, hash = (body or ""):match("^(%x+):(%w+)$")
    if not ValidId(id) or not Comm.FromBase36(hash) then return end
    local held = (Store(false) or {})[id]
    if type(held) == "table" then
        if held.hash == hash then return end
        if Now() - (tonumber(held.at) or 0) < self.SYNC_GAP then return end
    end
    for _, waiting in ipairs(self.queue) do
        if waiting.id == id then waiting.name = sender return end
    end
    if #self.queue >= 50 then return end
    self.queue[#self.queue + 1] = { id = id, name = sender }
    self:Next()
end

--- Ask the next one in line, unless one is being waited on.
function Contribute:Next()
    local current = self.current
    if current and Now() - current.at < self.SYNC_TIMEOUT then return end
    self.current = nil
    local waiting = table.remove(self.queue, 1)
    if not waiting then return end
    self.current = { id = waiting.id, key = Comm.NameKey(waiting.name), at = Now() }
    Comm:Send("R", waiting.id, "WHISPER", waiting.name)
    -- One that never answers is given up, and the next asked, without
    -- waiting for another hello.
    if type(C_Timer) == "table" and C_Timer.After then
        C_Timer.After(self.SYNC_TIMEOUT + 1, function() Contribute:Next() end)
    end
end

--- Only numbers in the shapes Payload makes; anything else is left out.
function Contribute:Clean(value)
    if type(value) ~= "table" or type(value.d) ~= "table" or type(value.s) ~= "table" then return nil end
    local clean, items, skills = { d = {}, s = {} }, 0, 0
    for itemID, record in pairs(value.d) do
        items = items + 1
        if items > self.MAX_ITEMS then return nil end
        if WholeNumber(itemID, 1, self.MAX_ID) and type(record) == "table"
            and WholeNumber(record.c, 1, self.MAX_CASTS) and type(record.g) == "table" then
            local got, kinds = {}, 0
            for materialID, entry in pairs(record.g) do
                kinds = kinds + 1
                if kinds > 20 then break end
                if WholeNumber(materialID, 1, self.MAX_ID) and type(entry) == "table"
                    and WholeNumber(entry.t, 1, record.c) and WholeNumber(entry.n, 1, record.c * 50) then
                    got[materialID] = { t = entry.t, n = entry.n }
                end
            end
            clean.d[itemID] = { c = record.c, g = got }
        end
    end
    for itemID, skill in pairs(value.s) do
        skills = skills + 1
        if skills > self.MAX_SKILLS then return nil end
        if WholeNumber(itemID, 1, self.MAX_ID) and WholeNumber(skill, 1, self.MAX_SKILL) then
            clean.s[itemID] = skill
        end
    end
    return clean
end

function Contribute:OnTable(sender, value, channel)
    local current = self.current
    if channel ~= "WHISPER" or not self:Receiving() or not current then return end
    if Comm.NameKey(sender) ~= current.key or type(value) ~= "table" or value.i ~= current.id then return end
    self.current = nil

    local clean = self:Clean(value)
    if clean then
        local store = Store(true)
        store[current.id] = {
            at = Now(),
            hash = type(value.h) == "string" and #value.h <= 12 and value.h or nil,
            disenchants = clean.d,
            skills = clean.s,
        }
        self:Trim(store)
        local name = Comm.Plain(sender) or "?"
        name = name:match("^([^%-]+)") or name
        self:Note(name)
        local line = L.Format("Got disenchants and recipe levels from %s.", name)
        ns.Print(line)
        self:Alert(line)
    end
    self:Next()
end

--- Past MAX_SENDERS, the one heard from longest ago goes.
function Contribute:Trim(store)
    local count, oldest, oldestAt = 0, nil, nil
    for id, entry in pairs(store) do
        count = count + 1
        local at = type(entry) == "table" and tonumber(entry.at) or 0
        if not oldestAt or at < oldestAt then oldest, oldestAt = id, at end
    end
    if count > self.MAX_SENDERS and oldest then store[oldest] = nil end
end

--- A sound and a line across the screen as the chat line goes out. Only a
--- receiving character ever gets here.
function Contribute:Alert(line)
    if type(PlaySound) == "function" then
        local kits = type(_G.SOUNDKIT) == "table" and _G.SOUNDKIT or {}
        pcall(PlaySound, kits.IG_QUEST_LIST_COMPLETE or 878, "Master")
    end
    local frame = _G.UIErrorsFrame
    if type(frame) == "table" and type(frame.AddMessage) == "function" then
        pcall(frame.AddMessage, frame, line, 1, 0.82, 0.2, 1)
    end
end

function Contribute:Note(name)
    if type(ns.db) ~= "table" then return end
    if type(ns.db.sharedDataLog) ~= "table" then ns.db.sharedDataLog = {} end
    local log = ns.db.sharedDataLog
    log[#log + 1] = { at = Now(), name = tostring(name) }
    while #log > self.LOG_KEEP do table.remove(log, 1) end
end

--- The shares kept, newest first, as lines for chat.
function Contribute:LogLines()
    local log = type(ns.db) == "table" and ns.db.sharedDataLog
    local lines = {}
    if type(log) ~= "table" then return lines end
    for i = #log, math.max(1, #log - self.LOG_SHOW + 1), -1 do
        local entry = log[i]
        if type(entry) == "table" then
            local ok, when = pcall(date, "%b %d %H:%M", tonumber(entry.at) or 0)
            when = ok and when or "?"
            lines[#lines + 1] = L.Format("%s: data from %s.", when, tostring(entry.name))
        end
    end
    return lines
end

function Contribute:PrintLog()
    local lines = self:LogLines()
    if #lines == 0 then
        ns.Print(L["Nobody has shared data with you yet."])
        return
    end
    for _, line in ipairs(lines) do ns.Print(line) end
end

--------------------------------------------------------------------------------
-- The choice
--------------------------------------------------------------------------------

--- Start or stop the hellos to match the setting.
function Contribute:Apply()
    if self:Sending() then
        if not self.ticker and type(C_Timer) == "table" then
            self.ticker = C_Timer.NewTicker(self.HELLO_SECONDS, function() Contribute:Hello() end)
            C_Timer.After(self.FIRST_HELLO, function() Contribute:Hello() end)
        end
    elseif self.ticker then
        pcall(self.ticker.Cancel, self.ticker)
        self.ticker = nil
    end
end

function Contribute:SetOn(on)
    if not ns.Config then return end
    ns.Config:Set("shareData", on == true)
    self:Apply()
end

function Contribute:Describe()
    if self:On() then return L["Sharing your data with Blackthornes is on. Thank you."] end
    return L["Sharing your data with Blackthornes is off."]
end

--- `/bts share data [on|off|log]`, read by AccountLink's share command.
function Contribute:Command(rest)
    local choice = (rest or ""):lower()
    if choice == "log" then return self:PrintLog() end
    if choice == "on" or choice == "off" then self:SetOn(choice == "on") end
    ns.Print(self:Describe())
end

function Contribute:OnEnable()
    Comm:On("Q", function(...) Contribute:OnHello(...) end)
    Comm:On("R", function(...) Contribute:OnAsk(...) end)
    Comm:OnTable("K", function(...) Contribute:OnTable(...) end)
    self:Apply()
end
