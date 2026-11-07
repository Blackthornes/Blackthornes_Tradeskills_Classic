-- Share Craft Queue (Trent, 2026-11-07, a player with three accounts):
-- one account's characters say what their queued crafts still need, and
-- the other account's mail suggestions offer it.
--
-- Loom, on the second account, has three Bolt of Woolen Cloth queued and
-- holds three wool of the nine they use. Bob, on the first account, holds
-- wool. With Share Craft Queue ticked on both sides, Bob's mailbox offers
-- Loom six wool; with it off on either side, nothing.
--
-- Drives the real Queue.lua, QueueMail.lua and AccountLink.lua.

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end

local clock = 1000000
time = function() return clock end
GetTime = function() return clock end

local BOLT, WOOL = 2997, 2592
local BOB, ALT, LOOM, FAR = "Player-1-BOB", "Player-1-ALT", "Player-2-LOOM", "Player-2-FAR"

ns.Util = { IsBoundOnPickup = function() return false end }

local settings = { linkShareQueue = true, linkNames = "Loom" }
local currentKey = BOB
ns.Config = {
    Get = function(_, key) return settings[key] end,
    GetCharacterKey = function() return currentKey end,
}

ns.Comm = {
    NameKey = function(name) return type(name) == "string" and name:lower():gsub("%-.*", "") or nil end,
    IsMe = function() return false end,
    Hash = function(text) return #text end,
}

local BOLT_RECIPE = { recipeID = 20, name = "Bolt of Woolen Cloth", outputItemID = BOLT,
    quantityMin = 1, quantityMax = 1, reagents = { { itemID = WOOL, quantity = 3 } } }

ns.Recipes = {
    GetAll = function()
        local record = ns.db.characters[currentKey]
        return record and record.recipes or {}
    end,
    GetAny = function(self, id)
        for key, record in pairs(ns.db.characters) do
            if record.recipes and record.recipes[id] then return record.recipes[id], key end
        end
    end,
    GetCharacterName = function(_, key) return ns.db.characters[key].name end,
}

local bags = {}
ns.Inventory = {
    GetBagCount = function(_, id) return bags[id] or 0 end,
    GetBankCount = function() return 0 end,
    GetMailCount = function() return 0 end,
    GetOwnedCount = function(_, id) return bags[id] or 0 end,
    GetAltTotal = function() return 0 end,
}

assert(loadfile(lfs_cwd .. "/Logic/Queue.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Core/Characters.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/QueueMail.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/AccountLink.lua"))("Blackthornes_TS", ns)

local Queue, QueueMail, AccountLink = ns.Queue, ns.QueueMail, ns.AccountLink

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

-- Loom's account, logged in as Loom.
local function loomAccount()
    currentKey = LOOM
    bags = { [WOOL] = 3 }
    AccountLink.plan = nil
    ns.db = {
        characters = {
            [LOOM] = { name = "Loom", surname = "Weaver", realm = "Forever Realm 3 PvE", faction = "Horde",
                       recipes = { [20] = BOLT_RECIPE }, mailAt = 5 },
            [FAR] = { name = "Far", realm = "Elsewhere", faction = "Horde", recipes = {} },
        },
        queue = { { recipeID = 20, quantity = 3, owner = LOOM } },
    }
end

-- Bob's account, logged in as Bob, holding wool.
local function bobAccount()
    currentKey = BOB
    bags = { [WOOL] = 20 }
    ns.db = {
        characters = {
            [BOB] = { name = "Bob", realm = "Forever Realm 7 PvE", faction = "Horde", recipes = {} },
            [ALT] = { name = "Alt", realm = "Forever Realm 7 PvE", faction = "Horde", recipes = {} },
        },
        queue = {},
    }
end

local function woolTo(key)
    for _, d in ipairs(QueueMail:GetDeliveries()) do
        if d.to == key then
            for _, item in ipairs(d.items) do
                if item.itemID == WOOL then return item.count end
            end
        end
    end
    return 0
end

print("\nwhat goes out")

loomAccount()
local needs = AccountLink:QueueNeeds(LOOM)
check("Loom still needs six wool", needs and needs[WOOL] == 6)
check("and nothing else", needs and next(needs, next(needs)) == nil)
check("a character with nothing queued needs nothing", AccountLink:QueueNeeds(FAR) == nil)

local payload = AccountLink:Payload(LOOM, ns.db.characters[LOOM])
check("the payload carries the needs", payload.queueNeeds and payload.queueNeeds[WOOL] == 6)
check("and when Loom last read the mailbox", payload.mailAt == 5)

settings.linkShareQueue = false
AccountLink.plan = nil
payload = AccountLink:Payload(LOOM, ns.db.characters[LOOM])
check("untick it and no needs go out", payload.queueNeeds == nil)
settings.linkShareQueue = nil
payload = AccountLink:Payload(LOOM, ns.db.characters[LOOM])
check("it is off unless ticked", payload.queueNeeds == nil)
settings.linkShareQueue = true
AccountLink.plan = nil
payload = AccountLink:Payload(LOOM, ns.db.characters[LOOM])

print("\nwhat is taken")

bobAccount()
check("Bob takes Loom", AccountLink:Accept("Loom", payload, 1) == true)
check("with the needs", ns.db.characters[LOOM].queueNeeds[WOOL] == 6)
check("as a linked character", ns.db.characters[LOOM].linkedFrom == "Loom")

local bad = { guid = LOOM, name = "Loom", queueNeeds = { [WOOL] = "lots", [-4] = 2, [BOLT] = 0, x = 1 } }
AccountLink:Accept("Loom", bad, 2)
check("junk needs are dropped", ns.db.characters[LOOM].queueNeeds == nil)

local many = { guid = LOOM, name = "Loom", queueNeeds = {} }
for i = 1, 500 do many.queueNeeds[i] = 1 end
AccountLink:Accept("Loom", many, 3)
local kept = 0
for _ in pairs(ns.db.characters[LOOM].queueNeeds) do kept = kept + 1 end
check("at most MAX_NEEDS are kept", kept == AccountLink.MAX_NEEDS)

settings.linkShareQueue = false
AccountLink:Accept("Loom", payload, 4)
check("unticked here, the needs are not kept", ns.db.characters[LOOM].queueNeeds == nil)
settings.linkShareQueue = true
AccountLink:Accept("Loom", payload, 5)

check("one of Bob's own characters is never overwritten",
    AccountLink:Accept("Loom", { guid = ALT, name = "Alt", queueNeeds = { [WOOL] = 9 } }, 6) == nil
    and ns.db.characters[ALT].queueNeeds == nil)

print("\nBob's mail suggestions")

check("Bob is offered six wool for Loom", woolTo(LOOM) == 6)
check("Loom is a linked needer", QueueMail:LinkedNeeders(BOB)[1] == LOOM)

settings.linkShareQueue = false
check("unticked here, nothing is offered", woolTo(LOOM) == 0)
settings.linkShareQueue = true

bags = { [WOOL] = 4 }
check("never more than the bags hold", woolTo(LOOM) == 4)
bags = { [WOOL] = 20 }

ns.db.characters[LOOM].faction = "Alliance"
check("the other side is never offered", woolTo(LOOM) == 0)
ns.db.characters[LOOM].faction = "Horde"

ns.db.characters[LOOM].realm = "Another Realm"
check("nor another realm", woolTo(LOOM) == 0)
ns.db.characters[LOOM].realm = "Forever Realm 3 PvE"

print("\nwool on its way")

QueueMail:NoteSent(LOOM, { { itemID = WOOL, count = 4 } })
check("four sent leaves two to offer", woolTo(LOOM) == 2)

clock = clock + 7200
ns.db.characters[LOOM].mailAt = clock - 10
ns.db.characters[LOOM].queueNeeds = { [WOOL] = 2 }
check("once Loom reads the mailbox, the new needs stand alone", woolTo(LOOM) == 2)

ns.db.characters[LOOM].queueNeeds = nil
check("needs met, nothing is offered", woolTo(LOOM) == 0)

print(("\n%d checks passed"):format(checks))
