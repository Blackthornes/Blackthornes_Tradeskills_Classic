-- Share Shopping Lists (2026-11-07): one account's shopping lists and its
-- craft queue's list show, read only, on the other account, with both
-- sides ticked.
--
-- Bob, on the first account, keeps a list "Leather run" and has crafts
-- queued. Loom, on the second account, has a list of its own. With Share
-- Shopping Lists ticked on both sides, each sees the other's lists under
-- that account's name. Only item IDs, counts and list names go; a change
-- goes over a few seconds later; unticked on either side, they go away;
-- nothing taken from Loom is ever sent on by Bob.
--
-- Drives the real AccountLink.lua, ShoppingLists.lua and Serialize.lua.

local LEATHER, THREAD, WOOL, BOLT = 2318, 2320, 2592, 2997
local BOB, LOOM = "Player-1-BOB", "Player-2-LOOM"

local clock = 2000000
time = function() return clock end
GetTime = function() return clock end

-- C_Timer runs nothing by itself: the test moves the clock and fires what
-- is due, as the game would.
local timers = {}
C_Timer = {
    After = function(seconds, fn) timers[#timers + 1] = { at = clock + seconds, fn = fn } end,
    NewTicker = function() return { Cancel = function() end } end,
}
local function advance(seconds)
    clock = clock + seconds
    local due = {}
    for i = #timers, 1, -1 do
        if timers[i].at <= clock then due[#due + 1] = table.remove(timers, i) end
    end
    for i = #due, 1, -1 do due[i].fn() end
end

-- The pretend chat: what one side whispers waits here until delivered.
local wire = {}
local sides = {}

local function NewSide(me, partnerName, guid)
    local ns = {}
    ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
    ns.RegisterCommand, ns.RegisterEvent = function() end, function() end
    ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end
    ns.L = setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

    local side = { me = me, ns = ns, settings = { linkNames = partnerName, linkShareLists = true },
                   owned = {}, handlers = {}, sent = {} }
    ns.Config = {
        Get = function(_, key) return side.settings[key] end,
        Set = function(_, key, value) side.settings[key] = value end,
        GetCharacterKey = function() return guid end,
        GetRealmKey = function() return "realm" end,
    }
    ns.Util = {
        IsBoundOnPickup = function() return false end,
        HasFunction = function() return false end,
        GetItemLabel = function(id) return "[item " .. id .. "]" end,
        FormatMoney = function(c) return tostring(c) end,
    }
    ns.Inventory = {
        GetOwnedCount = function(_, id) return side.owned[id] or 0 end,
        GetBagCount = function() return 0 end,
        GetBankCount = function() return 0 end,
        GetMailCount = function() return 0 end,
        GetAltTotal = function() return 0 end,
    }
    ns.Prices = { GetValue = function() return 100 end }
    ns.Recipes = { GetAll = function() return {} end, GetAny = function() end,
                   ForgetCharacter = function(_, guid) ns.db.characters[guid] = nil end }
    ns.Comm = {
        NameKey = function(name) return type(name) == "string" and name:lower():gsub("%-.*", "") or nil end,
        IsMe = function(name) return name == me end,
        Hash = function(text)
            local h = 0
            for i = 1, #text do h = (h * 31 + text:byte(i)) % 2147483647 end
            return tostring(h)
        end,
        Send = function(_, kind, text, channel, target)
            side.sent[#side.sent + 1] = kind
            wire[#wire + 1] = { from = me, to = target, kind = kind, body = text, channel = channel }
        end,
        SendTable = function(_, kind, value, channel, target)
            side.sent[#side.sent + 1] = kind
            local encoded = ns.Serialize.Encode(value)
            wire[#wire + 1] = { from = me, to = target, kind = kind, encoded = encoded, channel = channel }
        end,
        On = function(_, kind, fn) side.handlers[kind] = fn end,
        OnTable = function(_, kind, fn) side.handlers[kind] = fn end,
    }
    ns.db = { characters = { [guid] = { name = me, realm = "Realm", faction = "Horde", recipes = {} } } }
    -- The craft queue's needs, as Logic/Queue.lua would give them.
    side.queue = {}
    ns.Queue = {}

    assert(loadfile(lfs_cwd .. "/Core/Serialize.lua"))("Blackthornes_TS", ns)
    assert(loadfile(lfs_cwd .. "/Logic/ShoppingLists.lua"))("Blackthornes_TS", ns)
    assert(loadfile(lfs_cwd .. "/Logic/AccountLink.lua"))("Blackthornes_TS", ns)
    ns.ShoppingLists.QueueLines = function(self)
        local lines = {}
        for _, need in ipairs(side.queue) do lines[#lines + 1] = self:Line(need[1], need[2]) end
        return lines
    end
    ns.AccountLink:OnEnable()
    sides[me] = side
    return side
end

-- Deliver everything on the wire, the answers too, until it is quiet.
local function deliver()
    local rounds = 0
    while #wire > 0 do
        rounds = rounds + 1
        assert(rounds < 500, "the two sides never stopped talking")
        local message = table.remove(wire, 1)
        local to = sides[message.to]
        if to then
            local handler = to.handlers[message.kind]
            if handler then
                if message.encoded then
                    local ok, value = to.ns.Serialize.Decode(message.encoded)
                    assert(ok, "a table that would not decode")
                    handler(message.from, value, message.channel)
                else
                    handler(message.from, message.body, message.channel)
                end
            end
        end
    end
end

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

local function find(list, pred)
    for _, v in ipairs(list) do if pred(v) then return v end end
end

local bob = NewSide("Bob", "Loom", BOB)
local loom = NewSide("Loom", "Bob", LOOM)
local BobLists, LoomLists = bob.ns.ShoppingLists, loom.ns.ShoppingLists

local run = BobLists:Make("Leather run")
BobLists:Add(run, LEATHER, 40)
BobLists:Add(run, THREAD, 10)
bob.owned[LEATHER] = 12
bob.queue = { { BOLT, 6 } }
local mine = LoomLists:Make("Wool")
LoomLists:Add(mine, WOOL, 20)
-- Making the lists above set quick sends going, and each side has its
-- login check waiting; this test calls Check by hand, so let them go.
for i = #timers, 1, -1 do timers[i] = nil end

print("\nwhat goes out")

local own = bob.ns.AccountLink:OwnLists()
check("Bob's list goes with its name", own.lists[1] and own.lists[1].n == "Leather run")
check("only item IDs and counts", own.lists[1].i[1][1] == LEATHER and own.lists[1].i[1][2] == 40
    and own.lists[1].i[1][3] == 12)
check("nothing else is on an item", #own.lists[1].i[1] == 3)
check("and the craft queue's list", own.queue[1] and own.queue[1][1] == BOLT and own.queue[1][2] == 6)
check("the manifest names a hash for them", type(bob.ns.AccountLink:Manifest().lists) == "string")
bob.settings.linkShareLists = nil
check("off unless ticked: the hash says off", bob.ns.AccountLink:Manifest().lists == "off")
bob.settings.linkShareLists = true

print("\nthe first sync")

bob.ns.AccountLink:Check()
deliver()
local seen = LoomLists:Linked()
local leather = find(seen, function(l) return l.name == "Leather run (Bob)" end)
check("Loom sees Bob's list under Bob's name", leather ~= nil)
check("and Bob's craft queue", find(seen, function(l) return l.name == "Craft queue (Bob)" end) ~= nil)
local lines = LoomLists:LinkedLines(leather.key)
check("how many Bob has and needs", lines[1].itemID == LEATHER and lines[1].have == 12 and lines[1].need == 28)
check("Loom's own list is not touched", #LoomLists:Lines(mine) == 1)
check("Bob sees Loom's list too", find(BobLists:Linked(), function(l) return l.name == "Wool (Loom)" end) ~= nil)
check("Bob never sends Loom's list back out", #bob.ns.AccountLink:OwnLists().lists == 1)

local before = #bob.sent
bob.ns.AccountLink:Check()
deliver()
local asked = 0
for i = before + 1, #bob.sent do if bob.sent[i] == "U" then asked = asked + 1 end end
check("nothing new: the lists are not sent again", asked == 0)

print("\na change goes over soon")

BobLists:SetWant(run, LEATHER, 60)
check("not at once", #wire == 0)
advance(2)
BobLists:SetWant(run, THREAD, 15)
advance(4)
check("still waiting while changes come", #wire == 0)
advance(2)
check("then one message", #wire == 1 and wire[1].kind == "M")
deliver()
leather = find(LoomLists:Linked(), function(l) return l.name == "Leather run (Bob)" end)
check("Loom has the new count", LoomLists:LinkedLines(leather.key)[1].want == 60)

bob.queue = { { BOLT, 6 }, { WOOL, 3 } }
bob.ns.Queue.Notify = nil
bob.ns.AccountLink:ListsChanged()
advance(6)
deliver()
local queue = find(LoomLists:Linked(), function(l) return l.queue end)
check("a queue change goes over too", #LoomLists:LinkedLines(queue.key) == 2)

print("\nturning it off")

loom.settings.linkShareLists = false
loom.ns.AccountLink:ListsTicked(false)
check("unticked on Loom: Bob's lists go there", #LoomLists:Linked() == 0
    and loom.ns.db.linkedShoppingLists == nil)
advance(6)
deliver()
check("and Bob is told, so Loom's go there too", #BobLists:Linked() == 0
    and bob.ns.db.linkedShoppingLists == nil)
loom.settings.linkShareLists = true
loom.ns.AccountLink:ListsTicked(true)
advance(6)
deliver()
check("ticked again, both come back", #LoomLists:Linked() >= 2 and #BobLists:Linked() == 1)

bob.ns.AccountLink:Forget("Loom")
check("forgetting the other account lets its lists go", #BobLists:Linked() == 0)

print("\nnothing odd is kept")

local clean = bob.ns.AccountLink.CleanLists({
    queue = { { BOLT, 2, 0 }, { "x", 2 }, { 0, 2 }, { BOLT, 0 }, { BOLT, -3 }, "junk" },
    lists = {
        { n = "|cffff0000Red|r", i = { { WOOL, 5, -2 } } },
        { n = "", i = { { WOOL, 1 } } },
        { n = 12, i = {} },
        "junk",
    },
})
check("a bad item is dropped", #clean.queue == 1)
check("a name loses its colour codes", clean.lists[1] and clean.lists[1].n == "Red")
check("a count below none reads as none", clean.lists[1].i[1][3] == 0)
check("a list with no name is dropped", #clean.lists == 1)

local stranger = #(bob.ns.db.linkedShoppingLists or {})
bob.ns.AccountLink:OnLists("Stranger", { hash = "1", data = { lists = { { n = "Mine", i = { { WOOL, 1 } } } } } }, "WHISPER")
check("lists from anyone else are never taken", bob.ns.db.linkedShoppingLists == nil and stranger == 0)

print(("\n%d checks passed"):format(checks))
