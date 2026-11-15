-- Pause and the player's own order on the craft queue, outside WoW (the
-- owner said build it, 2026-11-14).
--
-- What must hold:
--   1. A paused row is passed over by Craft Next, and so is the craft a
--      paused part goes into. Resume brings both back.
--   2. Move Up, Move Down and Move to Top move a row, but never a part
--      below the craft it feeds.
--   3. The order and a paused part stay when the sub-crafts are worked out
--      again. Clear all forgets the order.
--   4. With an order of its own, Craft Next keeps it, whatever bag space says.

local GLOBALS = { "GetTime", "time", "C_Timer", "C_TradeSkillUI", "GetZoneText",
    "GetSubZoneText", "UnitGUID" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local function noop() end
GetTime = function() return 100 end
time = function() return 100000 end
C_Timer = { After = noop, NewTicker = function() return { Cancel = noop } end }
GetZoneText = function() return "Elwynn Forest" end
GetSubZoneText = function() return "Goldshire" end
C_TradeSkillUI = {}

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = noop
ns.RegisterEvent = noop
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = noop, noop, noop, noop
ns.Util = { HasFunction = function() return false end }
local config = {}
ns.Config = { Get = function(_, key) return config[key] end, GetCharacterKey = function() return "me" end }
ns.BagsFull = { MaxStack = function() return 20 end }

local RECIPES = {
    [10] = { name = "Bolt", outputItemID = 2, reagents = { { itemID = 1, quantity = 1 } } },
    [20] = { name = "Shirt", outputItemID = 3, reagents = { { itemID = 1, quantity = 1 } } },
    [30] = { name = "Robe", outputItemID = 4, reagents = { { itemID = 2, quantity = 1 } } },
}
ns.Recipes = { GetAny = function(_, id) return RECIPES[id], "me" end }
ns.Inventory = { changes = 0, GetBagCount = function() return 10 end,
    GetOwnedCount = function(_, id) return id == 2 and 0 or 10 end }
ns.Profit = { GetCraftableCount = function() return 5 end }
ns.Cost = {
    GetCraftCost = function(_, id)
        if id == 30 then return { reagents = { { itemID = 2, quantity = 1, crafted = true } } } end
        return nil
    end,
    FindRecipeForItem = function(_, itemID) return itemID == 2 and 10 or nil end,
}
ns.db = { queue = {} }

assert(loadfile(lfs_cwd .. "/Logic/Queue.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Crafting.lua"))("Blackthornes_TS", ns)
local Queue, Crafting = ns.Queue, ns.Crafting
Crafting.isTradeSkillOpen = true

local passed, failed = 0, 0
local function check(label, got, want)
    local ok = got == want
    if ok then passed = passed + 1 else failed = failed + 1 end
    print(string.format("  %-60s %-24s %s", label, tostring(got), ok and "ok" or
        ("WRONG, wanted " .. tostring(want))))
end

local function Name(entry) return entry and RECIPES[entry.recipeID].name end
local function Next() return Name((Crafting:GetNextReady())) end
local function Order()
    local names = {}
    for i, entry in ipairs(Queue:GetAll()) do names[i] = Name(entry) end
    return table.concat(names, ",")
end
local function Row(name)
    for _, entry in ipairs(Queue:GetAll()) do
        if Name(entry) == name then return entry end
    end
end

-- A robe made from a bolt (a part), and a shirt.
config.craftFreesSpaceFirst = false
ns.db.queue = { { recipeID = 30, quantity = 1, crafter = "me" }, { recipeID = 20, quantity = 1, crafter = "me" } }
Queue:RebuildDependencies()
check("the bolt is worked out as a part", Order(), "Bolt,Robe,Shirt")
check("the bolt is part of the robe", Queue.IsPartOf(Row("Bolt"), Row("Robe")), true)

-- 1. Pause.
check("Craft Next starts with the bolt", Next(), "Bolt")
Queue:SetPaused(Row("Bolt"), true)
local held, byPart = Queue:Held(Row("Robe"))
check("a paused part holds its craft", held, true)
check("and says it is held by a part", byPart, true)
check("Craft Next skips both", Next(), "Shirt")
check("ready count leaves them out", (Crafting:GetQueueReadiness()), 1)
Queue:SetPaused(Row("Bolt"), false)
check("resumed, the bolt is next again", Next(), "Bolt")
Queue:SetPaused(Row("Shirt"), true)
check("a paused row on its own", (Queue:Held(Row("Shirt"))), true)
Queue:SetPaused(Row("Shirt"), false)

-- 2. Moves.
check("the robe can't go above its bolt", Queue:CanMoveUp(Row("Robe")), false)
check("the bolt can't go below its robe", Queue:CanMoveDown(Row("Bolt")), false)
check("the bolt is already on top", Queue:CanMoveTop(Row("Bolt")), false)
check("a refused move does nothing", Queue:Move(Row("Robe"), "up"), false)
check("the shirt can move up", Queue:Move(Row("Shirt"), "up"), true)
check("past the robe", Order(), "Bolt,Shirt,Robe")
check("to the top", Queue:Move(Row("Shirt"), "top"), true)
check("the shirt is first", Order(), "Shirt,Bolt,Robe")
check("the robe's top is after its bolt", Queue:Move(Row("Robe"), "top"), false)
check("and moves down", Queue:Move(Row("Shirt"), "down"), true)
check("below the bolt", Order(), "Bolt,Shirt,Robe")
Queue:Move(Row("Shirt"), "top")

-- 3. A rebuild keeps the order and the pause.
Queue:SetPaused(Row("Bolt"), true)
Queue:RebuildDependencies()
check("the order stays after a rebuild", Order(), "Shirt,Bolt,Robe")
check("the paused part stays paused", Row("Bolt").paused, true)
Queue:SetPaused(Row("Bolt"), false)

-- 4. Own order beats bag space.
config.craftFreesSpaceFirst = nil
check("with an order of its own", Queue:HasOwnOrder(), true)
check("Craft Next keeps it", Next(), "Shirt")

Queue:Clear()
check("Clear all forgets the order", ns.db.queueOrder, nil)

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then error(failed .. " failed") end
