-- Craft Next skips a craft that needs a tool or station you are not near,
-- outside WoW (the owner said build it, 2026-11-14).
--
-- What must hold:
--   1. The game's own answer (GetRecipeRequirements) wins: an unmet need
--      makes the craft not ready, "Needs a NAME".
--   2. With no answer from the game, the "Requires X" refusal right after
--      a craft starts teaches it; later refusals are not taken.
--   3. A learned skip goes when you move to another zone or subzone.
--   4. GetNextReady passes over it.

local GLOBALS = { "GetTime", "time", "C_Timer", "C_TradeSkillUI", "GetZoneText",
    "GetSubZoneText", "SPELL_FAILED_REQUIRES_SPELL_FOCUS" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local function noop() end
local now = 100
GetTime = function() return now end
time = function() return 100000 end
C_Timer = { After = noop, NewTicker = function() return { Cancel = noop } end }
local zone, sub = "Elwynn Forest", "Goldshire"
GetZoneText = function() return zone end
GetSubZoneText = function() return sub end
SPELL_FAILED_REQUIRES_SPELL_FOCUS = "Requires %s"
local requirements = {}
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
}
ns.Recipes = { GetAny = function(_, id) return RECIPES[id], "me" end }
ns.Inventory = { changes = 0, GetBagCount = function() return 10 end, GetOwnedCount = function() return 10 end }
ns.Profit = { GetCraftableCount = function() return 5 end }
ns.Cost = { GetCraftCost = function() return nil end, FindRecipeForItem = function() return nil end }
ns.db = { queue = {} }

assert(loadfile(lfs_cwd .. "/Logic/Queue.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Crafting.lua"))("Blackthornes_TS", ns)
local Crafting = ns.Crafting
Crafting.isTradeSkillOpen = true
config.craftFreesSpaceFirst = false

local passed, failed = 0, 0
local function check(label, got, want)
    local ok = got == want
    if ok then passed = passed + 1 else failed = failed + 1 end
    print(string.format("  %-60s %-24s %s", label, tostring(got), ok and "ok" or
        ("WRONG, wanted " .. tostring(want))))
end

local function Next()
    local entry = Crafting:GetNextReady()
    return entry and RECIPES[entry.recipeID].name
end

ns.db.queue = { { recipeID = 10, quantity = 1 }, { recipeID = 20, quantity = 1 } }

-- 1. The game says what is missing.
C_TradeSkillUI.GetRecipeRequirements = function(id) return requirements[id] end
requirements[10] = { { name = "Spinning Wheel", met = false } }
local ready, why = Crafting:GetReadiness(10)
check("an unmet need makes it not ready", ready, false)
check("and says what it needs", why, "Needs a Spinning Wheel")
check("Craft Next passes over it", Next(), "Shirt")
requirements[10] = { { name = "Spinning Wheel", met = true } }
check("met, it is ready again", (Crafting:GetReadiness(10)), true)

-- 2. No answer: learn from the refusal.
C_TradeSkillUI.GetRecipeRequirements = nil
check("refusal line read", Crafting.ToolFromError("Requires Spinning Wheel"), "Spinning Wheel")
check("another message is not", Crafting.ToolFromError("You are too far away"), nil)
Crafting.lastStart = { recipeID = 10, at = now }
now = now + 5
Crafting:OnUIError("UI_ERROR_MESSAGE", 0, "Requires Spinning Wheel")
check("a late refusal teaches nothing", (Crafting:GetReadiness(10)), true)
Crafting.lastStart = { recipeID = 10, at = now }
now = now + 1
Crafting:OnUIError("UI_ERROR_MESSAGE", 0, "Requires Spinning Wheel")
ready, why = Crafting:GetReadiness(10)
check("a refusal right after the start skips it", ready, false)
check("with the tool's name", why, "Needs a Spinning Wheel")
check("Craft Next passes over it too", Next(), "Shirt")

-- 3. Moving clears it.
sub = "Northshire Valley"
Crafting:OnZoneChanged()
check("a new subzone looks again", (Crafting:GetReadiness(10)), true)
check("and Craft Next goes back to it", Next(), "Bolt")

ns.db.queue = {}
for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print("")
if failed > 0 then
    error(string.format("FAIL -- %d of %d queue tool checks wrong", failed, passed + failed))
end
print(string.format("PASS -- Craft Next skips crafts that need a tool (%d checks)", passed))
