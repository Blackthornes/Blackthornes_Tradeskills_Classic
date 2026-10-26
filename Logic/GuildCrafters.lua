-- Blackthornes Tradeskills -- Logic/GuildCrafters.lua
-- Which guildmates online can make a craft.
--
-- A player asked (2026-10-24) to see, on a craft, who else using the addon
-- knows the recipe, and to whisper them. The owner said guild only: never
-- the realm. Off unless ticked; Settings, Sharing: `guildCrafters` (never
-- rename it). When on:
--   * A hello goes to the guild (GUILD addon channel) 40 s after login and
--     every ten minutes, with a hash of the recipes this character knows:
--     B<hash>, and B<hash>:1 the first time a session ("send me yours").
--   * A guildmate whose hello carries a hash other than the one held asks
--     for the list by whisper (N), at most every ten minutes, and gets it
--     whispered back as a table (L: { h = hash, r = "id,id,..." }, the IDs
--     in base 36). The first hello of a session is answered the same way.
--   * Only recipe IDs and the sender's name go. Nothing is saved: the lists
--     are kept for the session only, so a guildmate's recipes are never
--     written into anyone's save.
--   * A guildmate counts as online while heard from within ONLINE_FOR, and
--     the guild roster says so when it can be read (a name it shows as
--     offline is dropped at once).
--   * A whisper is heard only from a guildmate whose hello came first, or
--     in the minute after our own first hello (the answers to it). Once the
--     guild roster has been read, only names on it are ever shown.
--
-- Friends (the owner, 2026-10-25): a player shared with a friend through
-- "Your Other Account" and got the friend's characters in their own list.
-- Names typed under "Friends:" (`friendNames`, never rename it) swap the
-- same hello and list by whisper, whether or not Guild Crafters is ticked,
-- and show on their own line on the Profit tab. Only names typed there are
-- whispered or heard, so both sides have to name each other. Nothing is
-- saved, so a friend's characters never join this account's own.

local _, ns = ...

local GuildCrafters = ns.NewModule("GuildCrafters")

local Comm = ns.Comm

GuildCrafters.ASK_AFTER = 40          -- seconds after login for the first hello
GuildCrafters.HELLO_EVERY = 10 * 60
GuildCrafters.ONLINE_FOR = 25 * 60    -- heard within this counts as online
GuildCrafters.ASK_EVERY = 10 * 60     -- one ask a guildmate, at most this often
GuildCrafters.ANSWER_EVERY = 10 * 60  -- one list to a guildmate, at most this often
GuildCrafters.MAX_GUILDMATES = 300
GuildCrafters.MAX_RECIPES = 3000
GuildCrafters.MAX_RECIPE_ID = 10000000
GuildCrafters.ANSWER_WAIT = 10        -- the first hello's answers are spread over this
GuildCrafters.OPEN_FOR = 60           -- after our first hello, answers are taken from guildmates not heard yet

GuildCrafters.held = {}               -- [name key] = { name, hash, set, at }
GuildCrafters.asked = {}              -- [name key] = when we last asked
GuildCrafters.answered = {}           -- [name key] = when we last sent our list
GuildCrafters.friendHello = {}        -- [name key] = when we last whispered a friend hello
GuildCrafters.MAX_FRIENDS = 20

local function Now()
    local ok, now = pcall(time)
    return ok and now or 0
end

local function InGuild()
    local ok, yes = pcall(IsInGuild)
    return ok and yes == true
end

function GuildCrafters:IsOn()
    return ns.Config and ns.Config:Get("guildCrafters") == true
end

--- The names typed under Friends, as { key = "ana", name = "Ana" }.
function GuildCrafters:Friends()
    local list, seen = {}, {}
    local text = ns.Config and ns.Config:Get("friendNames")
    if type(text) ~= "string" then return list end
    for part in text:gmatch("[^,;]+") do
        local name = part:gsub("^%s+", ""):gsub("%s+$", "")
        local key = Comm.NameKey(name)
        if key and not seen[key] and #name <= 48 and not Comm.IsMe(name) then
            seen[key] = true
            list[#list + 1] = { key = key, name = name }
            if #list >= self.MAX_FRIENDS then break end
        end
    end
    return list
end

--- The friend a name is, or nil. Matched by the whole name, or by the
--- first word when only that was typed or only that came.
function GuildCrafters:IsFriend(name)
    local key = Comm.NameKey(name)
    if not key then return nil end
    local first = key:match("^(%S+)")
    for _, friend in ipairs(self:Friends()) do
        if friend.key == key or friend.key == first or friend.key:match("^(%S+)") == key then
            return friend
        end
    end
    return nil
end

--- Anything to do at all: Guild Crafters ticked, or a friend named.
function GuildCrafters:Busy()
    return self:IsOn() or #self:Friends() > 0
end

--------------------------------------------------------------------------------
-- What this character knows
--------------------------------------------------------------------------------

--- The recipe IDs this character knows, sorted, and their hash.
function GuildCrafters:Mine()
    local ids = {}
    local recipes = ns.Recipes and ns.Recipes:GetAll() or {}
    local key = ns.Config and ns.Config:GetCharacterKey()
    for recipeID, recipe in pairs(recipes) do
        if type(recipeID) == "number" and recipeID > 0 and recipeID == math.floor(recipeID)
            and recipeID <= self.MAX_RECIPE_ID
            and not (ns.Recipes.IsDropped and ns.Recipes:IsDropped(recipe, key)) then
            ids[#ids + 1] = recipeID
        end
    end
    table.sort(ids)
    while #ids > self.MAX_RECIPES do table.remove(ids) end

    local parts = {}
    for index, recipeID in ipairs(ids) do parts[index] = Comm.ToBase36(recipeID) end
    local text = table.concat(parts, ",")
    return text, Comm.Hash(text), #ids
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

function GuildCrafters:Hello(first)
    if not self:IsOn() or not InGuild() then return false end
    local _, hash, count = self:Mine()
    if count == 0 and not first then return false end
    self.lastHash = hash
    if first then self.openUntil = Now() + self.OPEN_FOR end
    Comm:Send("B", hash .. (first and ":1" or ""), "GUILD")
    return true
end

--- Whisper a hello to each friend, at most every HELLO_EVERY, sooner when
--- the recipes changed. The first of a session asks for their list too.
function GuildCrafters:HelloFriends(now)
    now = now or Now()
    local _, hash, count = self:Mine()
    local sent = 0
    for _, friend in ipairs(self:Friends()) do
        local last = self.friendHello[friend.key]
        if not last or now - last >= self.HELLO_EVERY or hash ~= self.friendHash then
            local first = last == nil
            if count > 0 or first then
                self.friendHello[friend.key] = now
                if Comm.NoteWhisper then Comm:NoteWhisper(friend.name) end
                Comm:Send("B", hash .. (first and ":1" or ""), "WHISPER", friend.name)
                sent = sent + 1
            end
        end
    end
    self.friendHash = hash
    return sent
end

function GuildCrafters:SendList(target, now)
    now = now or Now()
    local key = Comm.NameKey(target)
    if not key then return false end
    if self.answered[key] and now - self.answered[key] < self.ANSWER_EVERY then return false end
    local text, hash, count = self:Mine()
    if count == 0 then return false end
    self.answered[key] = now
    Comm:SendTable("L", { h = hash, r = text }, "WHISPER", target)
    return true
end

--------------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------------

local function Keep(self, key)
    if self.held[key] then return self.held[key] end
    local count = 0
    for _ in pairs(self.held) do count = count + 1 end
    if count >= self.MAX_GUILDMATES then return nil end
    local entry = {}
    self.held[key] = entry
    return entry
end

function GuildCrafters:OnHello(sender, body, channel, now)
    if Comm.IsMe(sender) then return end
    local friend = self:IsFriend(sender)
    if channel == "GUILD" then
        if not self:IsOn() and not friend then return end
    elseif channel ~= "WHISPER" or not friend then
        return
    end
    now = now or Now()
    local key = Comm.NameKey(sender)
    if not key then return end
    local hash, flag = tostring(body or ""):match("^(%w+)(:?1?)$")
    if not hash or #hash > 8 then return end

    local entry = Keep(self, key)
    if not entry then return end
    entry.name = sender:match("^[^%-]+") or sender
    entry.at = now
    entry.gone = nil
    entry.friend = friend and true or nil

    if entry.hash ~= hash and (not self.asked[key] or now - self.asked[key] >= self.ASK_EVERY) then
        self.asked[key] = now
        Comm:Send("N", "", "WHISPER", sender)
    end

    if flag == ":1" and channel == "WHISPER" then
        -- Only this friend heard it: no need to wait.
        self:SendList(sender, now)
    elseif flag == ":1" then
        -- Everyone in the guild hears it; the answers are spread out a little.
        local wait = 2 + math.random() * (self.ANSWER_WAIT - 2)
        if C_Timer and C_Timer.After then
            C_Timer.After(wait, function() GuildCrafters:SendList(sender) end)
        else
            self:SendList(sender, now)
        end
    end
end

--- Someone heard on the guild channel this session, or, just after our own
--- first hello, someone answering it.
function GuildCrafters:Known(sender, now)
    local key = Comm.NameKey(sender)
    if not key or Comm.IsMe(sender) then return nil end
    local friend = self:IsFriend(sender)
    local held = self.held[key]
    if held then
        -- A guildmate heard while Guild Crafters was on counts only while it is.
        if friend or self:IsOn() then
            held.friend = friend and true or nil
            return held
        end
        return nil
    end
    if friend or (self:IsOn() and self.openUntil and (now or Now()) <= self.openUntil) then
        local entry = Keep(self, key)
        if entry then
            entry.name = sender:match("^[^%-]+") or sender
            entry.at = now or Now()
            entry.friend = friend and true or nil
        end
        return entry
    end
    return nil
end

function GuildCrafters:OnAsk(sender, _, channel, now)
    if channel ~= "WHISPER" then return end
    if not self:Known(sender, now) then return end
    self:SendList(sender, now)
end

--- A guildmate's list, read as plain data and checked.
function GuildCrafters:OnList(sender, value, channel, now)
    if channel ~= "WHISPER" or type(value) ~= "table" then return end
    local entry = self:Known(sender, now)
    if not entry then return end
    local hash, text = value.h, value.r
    if type(hash) ~= "string" or #hash > 8 or type(text) ~= "string" then return end

    local set, count = {}, 0
    for part in text:gmatch("[^,]+") do
        local recipeID = Comm.FromBase36(part)
        if recipeID and recipeID > 0 and recipeID <= self.MAX_RECIPE_ID then
            if not set[recipeID] then
                count = count + 1
                if count > self.MAX_RECIPES then break end
                set[recipeID] = true
            end
        end
    end
    entry.hash, entry.set = hash, set
    entry.at = now or Now()
    entry.name = sender:match("^[^%-]+") or sender
    self.version = (self.version or 0) + 1
    if ns.UI and ns.UI.RefreshActiveTab then pcall(ns.UI.RefreshActiveTab, ns.UI) end
end

--------------------------------------------------------------------------------
-- Who is online
--------------------------------------------------------------------------------

--- Read the guild roster: names it shows offline are let go. A name it does
--- not show (another way of writing names) is left to the heard time.
function GuildCrafters:ReadRoster()
    local ok, count = pcall(GetNumGuildMembers)
    if not ok or type(count) ~= "number" or count <= 0 then return end
    local online, seen = {}, {}
    for index = 1, math.min(count, 1000) do
        -- In a pcall as a whole: the client can hand over values that raise
        -- when compared.
        pcall(function()
            local name, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(index)
            local fullKey = Comm.NameKey(Comm.Plain(name))
            if not fullKey then return end
            local here = isOnline == true or isOnline == 1
            for _, k in ipairs({ fullKey, fullKey:match("^(%S+)") }) do
                seen[k] = true
                if here then online[k] = true end
            end
        end)
    end
    -- Who is in the guild at all: a name not on the roster is never shown.
    self.members = seen
    for key, entry in pairs(self.held) do
        local firstKey = key:match("^(%S+)")
        local match = seen[key] and key or (seen[firstKey] and firstKey)
        if match and not online[match] then entry.gone = true end
    end
end

local function IsOnline(entry, now)
    if entry.gone or type(entry.at) ~= "number" or now - entry.at > GuildCrafters.ONLINE_FOR then
        return false
    end
    local members = GuildCrafters.members
    -- A friend need not be in the guild.
    if members and entry.name and not entry.friend then
        local key = Comm.NameKey(entry.name)
        if not (members[key] or members[key:match("^(%S+)")]) then return false end
    end
    return true
end

--- The guildmates online who know a recipe, by name, sorted. Friends are
--- left out here and listed by WhoCanMakeFriends.
function GuildCrafters:WhoCanMake(recipeID, now, friends)
    if type(recipeID) ~= "number" then return {} end
    if not friends and not self:IsOn() then return {} end
    now = now or Now()
    local names = {}
    for _, entry in pairs(self.held) do
        if (entry.friend == true) == (friends == true)
            and entry.set and entry.set[recipeID] and entry.name and IsOnline(entry, now) then
            names[#names + 1] = entry.name
        end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

--- The friends online who know a recipe, by name, sorted.
function GuildCrafters:WhoCanMakeFriends(recipeID, now)
    return self:WhoCanMake(recipeID, now, true)
end

--- "No player named" came back for a name just whispered: that friend is
--- away for now.
function GuildCrafters:OnOffline(key)
    if not key then return end
    for heldKey, entry in pairs(self.held) do
        if entry.friend and (heldKey == key or heldKey:match("^(%S+)") == key) then entry.gone = true end
    end
end

--- The Friends box changed: let go of anyone no longer named. The hello
--- and setting copies aside wait for Enter (Settings), so half a name
--- does nothing.
function GuildCrafters:SetFriends(text)
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    ns.Config:Set("friendNames", text)
    for key, entry in pairs(self.held) do
        if entry.friend and not self:IsFriend(entry.name or key) then self.held[key] = nil end
    end
    for key in pairs(self.friendHello) do
        if not self:IsFriend(key) then self.friendHello[key] = nil end
    end
    self.version = (self.version or 0) + 1
end

--- Open the chat box with a whisper to this guildmate, by full name.
function GuildCrafters.Whisper(name)
    if type(name) ~= "string" or name == "" then return false end
    if type(ChatFrame_SendTell) == "function" and pcall(ChatFrame_SendTell, name) then return true end
    if type(ChatFrameUtil) == "table" and type(ChatFrameUtil.SendTell) == "function"
        and pcall(ChatFrameUtil.SendTell, name) then return true end
    return false
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function GuildCrafters:SetOn(on)
    ns.Config:Set("guildCrafters", on == true)
    if on then
        if self:Hello(true) then self.helloAt, self.saidHello = Now(), true end
    else
        -- Friends stay: they are not part of the guild switch.
        for key, entry in pairs(self.held) do
            if not entry.friend then self.held[key] = nil end
        end
        self.openUntil, self.members = nil, nil
        self.version = (self.version or 0) + 1
    end
end

function GuildCrafters:Tick(now)
    now = now or Now()
    if #self:Friends() > 0 then self:HelloFriends(now) end
    if not self:IsOn() then return end
    local _, hash = self:Mine()
    if not self.helloAt or now - self.helloAt >= self.HELLO_EVERY or hash ~= self.lastHash then
        if self:Hello(not self.saidHello) then
            self.helloAt, self.saidHello = now, true
        end
    end
    if C_GuildInfo and C_GuildInfo.GuildRoster then pcall(C_GuildInfo.GuildRoster)
    elseif type(GuildRoster) == "function" then pcall(GuildRoster) end
end

function GuildCrafters:OnEnable()
    Comm:On("B", function(...) GuildCrafters:OnHello(...) end)
    Comm:On("N", function(...) GuildCrafters:OnAsk(...) end)
    Comm:OnTable("L", function(...) GuildCrafters:OnList(...) end)
    if ns.RegisterEvent then
        ns.RegisterEvent(self, "GUILD_ROSTER_UPDATE", function() GuildCrafters:ReadRoster() end)
    end
    if C_Timer then
        C_Timer.After(self.ASK_AFTER, function() GuildCrafters:Tick() end)
        -- Looked at once a minute; Tick decides whether a hello goes.
        self.ticker = C_Timer.NewTicker(60, function() GuildCrafters:Tick() end)
    end
end
