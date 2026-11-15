-- Blackthornes Tradeskills -- Logic/GoldGoal.lua
-- Goblin Gold: the gold on every character of this realm and side, added up,
-- and how close it is to a goal you set.
--
-- Asked 2026-10-17, from a mockup: Tradeskills already keeps each
-- character's gold (Data/Inventory.lua's snapshot, `record.gold`), so it
-- can add it up across the realm and side you are playing on, show it on a
-- small bar, and cheer each tenth of a goal on the way. Off until ticked.
--
-- The character playing counts live (GetMoney); the others as last seen.
-- Records of one character (a GUID one and an old name-realm one) count
-- once (Characters:Same). Characters from your other account count too, as
-- the Characters tab shows them. Guild data never reaches it.
--
-- Each tenth of the goal is cheered once: `best` keeps the highest tenth
-- reached, so gold that dips and comes back (a mail in flight between your
-- characters) never cheers twice. Setting a goal starts `best` at the
-- tenth you are already on. A cheer waits while you fight, trade at the
-- auction house or have one of the game's panels open.
--
-- Saved, account wide, never renamed: `goldGoals[realmKey] = { goal,
-- setAt, best, reachedAt }`. UI/GoldGoal.lua draws it.
--
-- A player asked (2026-10-21, the owner said build it) for it to count the
-- character playing alone. "Count Gold On:" (`goldTrackerCount`, "all"
-- unless "character" is picked, never rename it) picks it. Counting one
-- character, its goal is its own, kept by GUID in
-- `goldGoalCharacters[guid]` (the same fields; never rename it), so the
-- realm's goal is left as it was. Today, this week and where the gold came
-- from stay the realm's: the gold log is kept per realm.

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

local GoldGoal = ns.NewModule("GoldGoal")

local COPPER_PER_GOLD = 10000

-- Tenths of the goal; the tenth is the goal itself.
GoldGoal.STEPS = 10
-- Money events come in bursts (a mailbox full of sales): the total is
-- read once, this long after the last.
GoldGoal.SETTLE = 0.3
-- How often a held cheer looks again whether you are free.
GoldGoal.RETRY = 2
-- Moved whenever the total, the goal or a character's gold may have moved,
-- so the bar draws again only then.
GoldGoal.version = 0

--------------------------------------------------------------------------------
-- Reading the client
--------------------------------------------------------------------------------

local function Plain(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(function(...)
        local v = fn(...)
        if type(v) == "string" and v ~= "" then return v .. "" end
    end, ...)
    return ok and value or nil
end

local function Money()
    if type(GetMoney) ~= "function" then return nil end
    local ok, money = pcall(function() return tonumber(GetMoney()) end)
    return ok and money or nil
end

local function Fold(text)
    if type(text) ~= "string" then return nil end
    return (text:lower():gsub("%s+", ""))
end

function GoldGoal:IsOn()
    return ns.Config and ns.Config:Get("goldTracker") == true
end

--- True while it counts only the character playing.
function GoldGoal:OnlyThisCharacter()
    return ns.Config and ns.Config:Get("goldTrackerCount") == "character" or false
end

--- Count every character of this realm and side ("all") or only the one
--- playing ("character").
function GoldGoal:SetCount(mode)
    if not ns.Config then return end
    ns.Config:Set("goldTrackerCount", mode == "character" and "character" or "all")
    self.pending = nil
    self:Changed()
end

--------------------------------------------------------------------------------
-- The total
--------------------------------------------------------------------------------

--- The realm and side of the character playing, as its record has them
--- when the client will not say.
function GoldGoal:Here()
    local realm = Plain(GetRealmName)
    local faction = Plain(UnitFactionGroup, "player")

    if (not realm or not faction) and ns.db and ns.db.characters and ns.Config then
        local record = ns.db.characters[ns.Config:GetCharacterKey()]
        if type(record) == "table" then
            realm = realm or (type(record.realm) == "string" and record.realm or nil)
            faction = faction or (type(record.faction) == "string" and record.faction or nil)
        end
    end

    return realm, faction
end

local function SameCharacter(a, b)
    if a == b then return true end
    local Characters = ns.Characters
    if not (Characters and Characters.Same) then return false end
    local ok, same = pcall(Characters.Same, Characters, a, b)
    return ok and same == true
end

local function NameOf(key)
    local Recipes = ns.Recipes
    if Recipes and Recipes.GetCharacterName then
        local ok, name = pcall(Recipes.GetCharacterName, Recipes, key)
        if ok and type(name) == "string" then return name end
    end
    return tostring(key)
end

--- Every character counted, most gold first: { key, name (whole), gold,
--- at (when its gold was read), isCurrent, linked }. `everyone` counts
--- the whole realm and side whatever Goblin Gold is set to count.
function GoldGoal:Members(now, everyone)
    local members = {}
    if not (ns.db and type(ns.db.characters) == "table") then return members end

    now = now or time()
    local selfKey = ns.Config and ns.Config:GetCharacterKey()
    local realm, faction = self:Here()
    realm, faction = RealmKey(realm), Fold(faction)
    local onlyHere = not everyone and self:OnlyThisCharacter()

    -- GUID keys first, so a character's GUID record is the one counted and
    -- an old name-realm record of it is the one left out.
    local keys = {}
    for key, record in pairs(ns.db.characters) do
        if type(record) == "table" then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b)
        if (a == selfKey) ~= (b == selfKey) then return a == selfKey end
        local ga, gb = tostring(a):find("^Player%-") ~= nil, tostring(b):find("^Player%-") ~= nil
        if ga ~= gb then return ga end
        return tostring(a) < tostring(b)
    end)

    for _, key in ipairs(keys) do
        local record = ns.db.characters[key]
        local isCurrent = key == selfKey
        local here = isCurrent or (not onlyHere and realm ~= nil and faction ~= nil
            and RealmKey(record.realm) == realm and Fold(record.faction) == faction)

        if here then
            local counted = false
            for _, member in ipairs(members) do
                if SameCharacter(member.key, key) then counted = true break end
            end

            if not counted then
                local gold = isCurrent and Money() or nil
                if gold == nil then gold = tonumber(record.gold) end
                members[#members + 1] = {
                    key = key,
                    name = NameOf(key),
                    gold = gold or 0,
                    known = gold ~= nil,
                    at = isCurrent and now or tonumber(record.inventoryAt),
                    isCurrent = isCurrent,
                    linked = type(record.linkedFrom) == "string" and record.linkedFrom or nil,
                }
            end
        end
    end

    table.sort(members, function(a, b)
        if a.gold ~= b.gold then return a.gold > b.gold end
        return a.name < b.name
    end)

    return members
end

--- The gold of every character counted, in copper, and how many there are.
function GoldGoal:Total(now, everyone)
    local total, count = 0, 0
    for _, member in ipairs(self:Members(now, everyone)) do
        total = total + member.gold
        count = count + 1
    end
    return total, count
end

--------------------------------------------------------------------------------
-- The goal
--------------------------------------------------------------------------------

-- The character playing's own goal record, by GUID, made when `create`.
local function CharacterRecord(create)
    local key = ns.Config and ns.Config:GetCharacterKey()
    -- A character known only by its name is no place to keep one.
    if type(key) ~= "string" or not key:find("^Player%-") then return nil end

    if type(ns.db.goldGoalCharacters) ~= "table" then
        if not create then return nil end
        ns.db.goldGoalCharacters = {}
    end

    local record = ns.db.goldGoalCharacters[key]
    if type(record) ~= "table" then
        if not create then return nil end
        record = {}
        ns.db.goldGoalCharacters[key] = record
    end
    return record
end

--- This realm and side's goal record, or the character playing's while it
--- counts only that one, made when `create`.
function GoldGoal:Record(create)
    if not ns.db then return nil end
    if self:OnlyThisCharacter() then return CharacterRecord(create) end
    local realmKey = ns.Config and ns.Config:GetRealmKey()
    -- A realm or side the client would not read is no place to keep one.
    if not realmKey or realmKey:find("^UnknownRealm%-") then return nil end

    if type(ns.db.goldGoals) ~= "table" then
        if not create then return nil end
        ns.db.goldGoals = {}
    end

    local record = ns.db.goldGoals[realmKey]
    if type(record) ~= "table" then
        if not create then return nil end
        record = {}
        ns.db.goldGoals[realmKey] = record
    end
    return record
end

--- The goal in copper, or nil.
function GoldGoal:Goal()
    local record = self:Record(false)
    local goal = record and tonumber(record.goal)
    if goal and goal > 0 then return goal end
    return nil
end

--- Which tenth `total` has reached of `goal`: 0 to STEPS.
function GoldGoal.Step(total, goal)
    if not (goal and goal > 0) then return 0 end
    return math.max(0, math.min(GoldGoal.STEPS, math.floor((total or 0) * GoldGoal.STEPS / goal)))
end

--- Set the goal, in copper (nil or 0 takes it away). Tenths already
--- reached are not cheered.
function GoldGoal:SetGoal(copper, now)
    copper = tonumber(copper)
    if copper then copper = math.floor(copper) end

    local record = self:Record(true)
    if not record then return false end

    if not copper or copper <= 0 then
        record.goal, record.setAt, record.best, record.reachedAt = nil, nil, nil, nil
    else
        now = now or time()
        local total = self:Total(now)
        record.goal = copper
        record.setAt = now
        record.best = GoldGoal.Step(total, copper)
        record.reachedAt = record.best >= GoldGoal.STEPS and now or nil
    end

    self.pending = nil
    self:Changed()
    return true
end

--- Set the goal in whole gold.
function GoldGoal:SetGoalGold(gold)
    gold = tonumber(gold)
    return self:SetGoal(gold and gold * COPPER_PER_GOLD or nil)
end

--- A next goal to offer once one is reached: the next round number past
--- the gold you have, about half again as much.
function GoldGoal.NextGoal(total)
    local gold = math.max(1, math.floor((total or 0) / COPPER_PER_GOLD))
    local want = gold * 1.5
    local step = 10 ^ math.max(0, math.floor(math.log10(want)) - 1)
    if want / step > 50 then step = step * 5 end
    return math.ceil(want / step) * step * COPPER_PER_GOLD
end

--------------------------------------------------------------------------------
-- What the gold log says
--------------------------------------------------------------------------------

local function Net(period)
    local GoldLog = ns.GoldLog
    if not (GoldLog and GoldLog.Bins and GoldLog.Totals) then return nil end
    local ok, totals = pcall(function() return GoldLog:Totals(GoldLog:Bins(period)) end)
    return ok and totals and totals.net or nil
end

--- Gold made today, gold moved between your characters left out.
function GoldGoal:Today() return Net("today") end

--- The last seven days the same way.
function GoldGoal:Week() return Net("week") end

local function DayNet(bucket)
    local GoldLog = ns.GoldLog
    local net = 0
    for source, line in pairs(bucket) do
        local info = GoldLog:GetSource(source)
        if type(line) == "table" and not (info and info.moved) then
            net = net + (tonumber(line.i) or 0) - (tonumber(line.o) or 0)
        end
    end
    return net
end

--- The best day before today: its net and its YYYYMMDD. Worked out once
--- a day, since days gone by do not change.
function GoldGoal:BestDay(now)
    local GoldLog = ns.GoldLog
    if not (GoldLog and GoldLog.GetLog and GoldLog.DayKey) then return nil end

    now = now or time()
    local today = GoldLog.DayKey(now)
    local kept = self.bestDay
    if kept and kept.today == today then return kept.net, kept.day end

    local best, bestDay
    local ok = pcall(function()
        for day, bucket in pairs(GoldLog:GetLog().days) do
            if type(day) == "number" and day < today and type(bucket) == "table" then
                local net = DayNet(bucket)
                if net > 0 and (not best or net > best) then best, bestDay = net, day end
            end
        end
    end)
    if not ok then return nil end

    self.bestDay = { today = today, net = best, day = bestDay }
    return best, bestDay
end

--- About how many days to the goal at this week's pace, or nil.
function GoldGoal:DaysToGo(total, goal)
    goal = goal or self:Goal()
    if not goal then return nil end
    total = total or self:Total()
    if total >= goal then return 0 end
    local week = self:Week()
    if not week or week <= 0 then return nil end
    return math.max(1, math.ceil((goal - total) / (week / 7)))
end

--------------------------------------------------------------------------------
-- Where this week's gold came from
--------------------------------------------------------------------------------

-- The game's own Statistics, by ID (asked 2026-10-20). Read only when the
-- client has GetStatistic; one it does not give is left out.
GoldGoal.STATISTICS = {
    quests = 98,       -- Quests completed
    kills = 1197,      -- Total kills
    questGold = 326,   -- Gold from quest rewards, in copper
    looted = 333,      -- Gold looted, in copper
}

--- A statistic as a number: plain digits, or a money string with the
--- game's coin icons. nil when the client has none or shows "--".
function GoldGoal.Statistic(id)
    if type(GetStatistic) ~= "function" then return nil end
    local ok, value = pcall(GetStatistic, id)
    if not ok then return nil end
    local okRead, number = pcall(function()
        if type(value) == "number" then return value end
        if type(value) ~= "string" then return nil end
        if value:find("|T") then
            local copper, found = 0, false
            for amount, texture in value:gmatch("([%d,%.]+)%s*|T([^|]+)|t") do
                amount = tonumber((amount:gsub("[^%d]", "")))
                texture = texture:lower()
                local unit = texture:find("gold") and 10000 or texture:find("silver") and 100
                    or texture:find("copper") and 1
                if amount and unit then copper, found = copper + amount * unit, true end
            end
            return found and copper or nil
        end
        local digits = value:gsub("[%s,%.]", "")
        if digits:match("^%d+$") then return tonumber(digits) end
        return nil
    end)
    if okRead and type(number) == "number" and number >= 0 then return number end
    return nil
end

--- This week's gold by where it came from, with how many quests and kills
--- were behind it, and the game's all-time numbers.
--- @return { quests = { gold, count }, mobs = { gold, kills, loot } or nil,
---   auctionSales, vendorSales, allTime = { quests, kills, questGold, looted } }
function GoldGoal:Sources(now)
    local GoldLog = ns.GoldLog
    now = now or time()
    local result = { allTime = {} }
    if GoldLog and GoldLog.Bins and GoldLog.Totals then
        local ok, totals = pcall(function() return GoldLog:Totals(GoldLog:Bins("week", nil, nil, now)) end)
        local sources = ok and totals and totals.sources or {}
        local function In(key) return sources[key] and tonumber(sources[key].i) or 0 end
        local okCount, quests = pcall(GoldLog.QuestsDone, GoldLog, 7, now)
        result.quests = { gold = In("quests"), count = okCount and quests or 0 }
        result.lootGold = In("loot")
        result.auctionSales = In("auctionSales")
        result.vendorSales = In("vendorSales")
    end

    -- Kills and what their loot was worth are Blackthornes Farmer's own
    -- log; without it the mob lines are left out.
    local farmer = _G.BlackthornesFarmer
    local stats = type(farmer) == "table" and farmer.Stats
    if type(stats) == "table" and type(stats.KillsAndLoot) == "function" then
        local ok, week = pcall(stats.KillsAndLoot, stats, 7)
        if ok and type(week) == "table" and tonumber(week.kills) then
            result.mobs = { gold = result.lootGold or 0, kills = tonumber(week.kills) or 0,
                loot = tonumber(week.loot) or 0 }
        end
    end

    for key, id in pairs(GoldGoal.STATISTICS) do
        local value = GoldGoal.Statistic(id)
        if value and value > 0 then result.allTime[key] = value end
    end
    return result
end

--- Where most of the gold came from since the goal was set: the source's
--- name as the Sales tab shows it, or nil.
function GoldGoal:MostlyFrom(now)
    local GoldLog = ns.GoldLog
    local record = self:Record(false)
    if not (GoldLog and record and record.setAt) then return nil end

    now = now or time()
    local ok, text = pcall(function()
        local totals = GoldLog:Totals(GoldLog:Bins("pick",
            GoldLog.DayKey(record.setAt), GoldLog.DayKey(now), now))
        local bestKey, bestIn
        for source, line in pairs(totals.sources) do
            local info = GoldLog:GetSource(source)
            if not (info and info.moved) and line.i > 0 and (not bestIn or line.i > bestIn) then
                bestKey, bestIn = source, line.i
            end
        end
        local info = bestKey and GoldLog:GetSource(bestKey)
        return info and info.text
    end)
    return ok and text or nil
end

--------------------------------------------------------------------------------
-- Cheers
--------------------------------------------------------------------------------

local function Shown(frame)
    if type(frame) ~= "table" or type(frame.IsShown) ~= "function" then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return ok and shown == true
end

--- Too busy for a cheer: in a fight, at the auction house, or with one of
--- the game's own panels open.
function GoldGoal:Busy()
    if type(InCombatLockdown) == "function" then
        local ok, fighting = pcall(InCombatLockdown)
        if ok and fighting then return true end
    end
    if Shown(_G.AuctionHouseFrame) or Shown(_G.AuctionFrame) then return true end
    if type(GetUIPanel) == "function" then
        for _, where in ipairs({ "left", "center", "doublewide", "fullscreen" }) do
            local ok, panel = pcall(GetUIPanel, where)
            if ok and panel then return true end
        end
    end
    return false
end

--- Look whether the total passed a tenth not cheered yet. Returns the
--- cheer it made, if any: { kind = "step" | "goal", step, goal, took }.
function GoldGoal:Check(now)
    if not self:IsOn() then return nil end
    local record = self:Record(false)
    local goal = record and tonumber(record.goal)
    if not (goal and goal > 0) then return nil end

    now = now or time()
    local step = GoldGoal.Step(self:Total(now), goal)
    local best = tonumber(record.best) or 0
    if step <= best then return nil end

    record.best = step
    local cheer
    if step >= GoldGoal.STEPS then
        record.reachedAt = now
        cheer = { kind = "goal", step = step, goal = goal,
            took = record.setAt and math.max(0, now - record.setAt) or nil }
    else
        cheer = { kind = "step", step = step, goal = goal }
    end

    -- Two tenths passed while busy are one cheer, the bigger.
    if not self.pending or self.pending.step < cheer.step then self.pending = cheer end
    self:Flush()
    return cheer
end

--- Hand a held cheer to the bar once you are free.
function GoldGoal:Flush()
    local cheer = self.pending
    if not cheer then return end

    if self:Busy() then
        if not self.retrying and C_Timer and C_Timer.After then
            self.retrying = true
            C_Timer.After(GoldGoal.RETRY, function()
                GoldGoal.retrying = false
                GoldGoal:Flush()
            end)
        end
        return
    end

    self.pending = nil
    local UI = ns.GoldGoalUI
    if UI and UI.Cheer then pcall(UI.Cheer, UI, cheer) end
end

--------------------------------------------------------------------------------
-- Watching
--------------------------------------------------------------------------------

--- Something moved: redraw the bar, and look for a cheer.
function GoldGoal:Changed()
    GoldGoal.version = GoldGoal.version + 1
    local UI = ns.GoldGoalUI
    if UI and UI.Refresh then pcall(UI.Refresh, UI) end
    self:Check()
end

--- Coalesce a burst of money events into one read.
function GoldGoal:Soon()
    if self.waiting then return end
    if not (C_Timer and C_Timer.After) then
        self:Changed()
        return
    end
    self.waiting = true
    C_Timer.After(GoldGoal.SETTLE, function()
        GoldGoal.waiting = false
        GoldGoal:Changed()
    end)
end

--- From GoldLog:Record: gold that came in floats up off the bar. Gold
--- from your own characters is not new, so it does not.
function GoldGoal:OnRecord(source, amount)
    if not self:IsOn() or source == "transfer" then return end
    amount = tonumber(amount)
    if not amount or amount <= 0 then return end
    local UI = ns.GoldGoalUI
    if UI and UI.Float then pcall(UI.Float, UI, amount) end
end

--- Turn it on or off.
function GoldGoal:SetOn(on)
    ns.Config:Set("goldTracker", on and true or false)
    local UI = ns.GoldGoalUI
    if UI and UI.Apply then pcall(UI.Apply, UI) end
    if on then self:Changed() end
end

function GoldGoal:OnEnable()
    ns.RegisterEvent(self, "PLAYER_MONEY", function() if GoldGoal:IsOn() then GoldGoal:Soon() end end)
    ns.RegisterEvent(self, "PLAYER_ENTERING_WORLD", function()
        if C_Timer and C_Timer.After then
            C_Timer.After(3, function()
                local UI = ns.GoldGoalUI
                if UI and UI.Apply then pcall(UI.Apply, UI) end
                if GoldGoal:IsOn() then GoldGoal:Changed() end
            end)
        end
    end)
    for _, event in ipairs({ "PLAYER_REGEN_ENABLED", "AUCTION_HOUSE_CLOSED", "MAIL_CLOSED",
            "MERCHANT_CLOSED", "BANKFRAME_CLOSED", "TRADE_CLOSED" }) do
        ns.RegisterEvent(self, event, function() GoldGoal:Flush() end)
    end
end

--------------------------------------------------------------------------------
-- Command
--------------------------------------------------------------------------------

ns.RegisterCommand("gold", L["Goblin Gold: your gold on this realm and side (on, off, goal 5000, reset, transparent)"], function(args)
    args = (args or ""):lower()
    local word, rest = args:match("^%s*(%a+)%s*(.-)%s*$")
    local UI = ns.GoldGoalUI

    if word == "on" or word == "off" then
        GoldGoal:SetOn(word == "on")
        ns.Print(word == "on" and L["Goblin Gold: on."] or L["Goblin Gold: off."])
    elseif word == "goal" then
        local gold = tonumber((rest or ""):gsub("[,g%s]", ""), 10)
        if gold and gold > 0 then
            GoldGoal:SetGoalGold(gold)
            ns.Print(L.Format("Goblin Gold: your goal is %s.", ns.Util.FormatMoney(gold * COPPER_PER_GOLD)))
        else
            GoldGoal:SetGoal(nil)
            ns.Print(L["Goblin Gold: no goal now."])
        end
    elseif word == "test" then
        -- Typed only, never in the help line: shows a cheer without
        -- saving anything, so the sounds and the look can be tried.
        if not GoldGoal:IsOn() then
            ns.Print(L["Goblin Gold: turn it on first with /bts gold on."])
        elseif UI then
            local total = GoldGoal:Total()
            local goal = GoldGoal:Goal() or GoldGoal.NextGoal(total)
            if rest == "goal" then
                pcall(UI.Cheer, UI, { kind = "goal", step = GoldGoal.STEPS, goal = goal, took = 3 * 86400, test = true })
            elseif rest == "float" then
                pcall(UI.Float, UI, 48 * COPPER_PER_GOLD)
            else
                local step = math.max(1, math.min(GoldGoal.STEPS - 1, GoldGoal.Step(total, goal) + 1))
                pcall(UI.Cheer, UI, { kind = "step", step = step, goal = goal, test = true })
            end
        end
    elseif word == "transparent" then
        local level
        for index = 0, 3 do
            if UI and UI.SEE_THROUGH_WORDS and UI.SEE_THROUGH_WORDS[index] == rest then level = index end
        end
        if not (UI and UI.SetSeeThrough) then
            return
        elseif level then
            UI:SetSeeThrough(level)
            ns.Print(L.Format("Goblin Gold transparent: %s.", UI.SeeThroughNames()[level]))
        else
            ns.Print(L["Type /bts gold transparent off, some, more or most."])
        end
    elseif word == "reset" then
        if UI and UI.ResetPlace then UI:ResetPlace() end
        ns.Print(L["Goblin Gold: the bar is back in its place."])
    else
        local total, count = GoldGoal:Total()
        ns.Print(L.Format("Goblin Gold: %s on %d characters.", ns.Util.FormatMoney(total), count))
    end

    if ns.UI and ns.UI.RefreshActiveTab then pcall(ns.UI.RefreshActiveTab, ns.UI) end
end)
