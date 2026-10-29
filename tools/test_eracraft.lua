-- Crafting from Era's old profession windows.
--
-- Era has no C_TradeSkillUI.CraftRecipe: a craft is made by its place in the
-- open window, DoTradeSkill(index, count), and Enchanting's own window makes
-- one a click with DoCraft(index). Clicking Craft on Era used to raise
-- "attempt to call a nil value". DoCraft is the game's own: from addon code
-- it is blocked, so an enchant is only picked here and UI/SecureCraft.lua's
-- secure button presses the window's Create button.

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

UnitName = function() return "Ana" end
UnitGUID = function() return "Player-1-A" end
GetRealmName = function() return "Era Realm" end
time = time or os.time
C_TradeSkillUI = nil
local now = 100
GetTime = function() return now end
UnitCastingInfo = function() return nil end

local tradeLines = {
    { "Leather", "header" },
    { "Handstitched Leather Cloak", "optimal" },
    { "Light Armor Kit", "easy" },
}
GetTradeSkillLine = function() return "Leatherworking", 20, 75 end
GetNumTradeSkills = function() return #tradeLines end
GetTradeSkillInfo = function(i) return tradeLines[i][1], tradeLines[i][2] end

local craftLines = { { "Enchant Bracer - Minor Health", nil, "optimal" } }
GetCraftDisplaySkillLine = function() return "Enchanting", 10, 75 end
GetNumCrafts = function() return #craftLines end
GetCraftInfo = function(i) return craftLines[i][1], craftLines[i][2], craftLines[i][3] end

local made = {}
DoTradeSkill = function(index, count) made[#made + 1] = { "trade", index, count } end
DoCraft = function(index) made[#made + 1] = { "craft", index } end
local selected = 0
GetCraftSelectionIndex = function() return selected end
SelectCraft = function(index) selected = index end
local setSelections = 0
CraftFrame_SetSelection = function(index) setSelections = setSelections + 1; SelectCraft(index) end
local stopped = false
StopTradeSkillRepeat = function() stopped = true end
local repeatLeft = 1
GetTradeskillRepeatCount = function() return repeatLeft end

C_Timer = { NewTimer = function() return { Cancel = function() end } end,
    NewTicker = function(_, fn) return { fn = fn, Cancel = function() end } end,
    After = function() end }

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
local handlers = {}
ns.RegisterEvent = function(owner, event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], function(...) fn(owner, event, ...) end)
    return true
end
local function Fire(event, ...)
    for _, fn in ipairs(handlers[event] or {}) do fn(...) end
end
local printed = {}
ns.Print = function(text) printed[#printed + 1] = text end
ns.Warn = ns.Print
ns.PrintRaw, ns.Debug = function() end, function() end
ns.Util = { HasFunction = function() return false end,
    Count = function(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end }
ns.Compat = { TradeskillMode = function() return "legacy" end }

local SELF = "Player-1-A"
local mine = {
    [9070] = { name = "Handstitched Leather Cloak", skillLineID = 165, outputItemID = 7276 },
    [2152] = { name = "Light Armor Kit", skillLineID = 165, outputItemID = 2304 },
    [2149] = { name = "Handstitched Leather Boots", skillLineID = 165, outputItemID = 2302 },
    [7418] = { name = "Enchant Bracer - Minor Health", skillLineID = 333 },
    [2963] = { name = "Bolt of Linen Cloth", skillLineID = 197, outputItemID = 2996 },
}
ns.Recipes = {
    SKILL_LINE_PROFESSIONS = { [165] = "Leatherworking", [333] = "Enchanting", [197] = "Tailoring" },
    EnglishProfessionName = function(name) return name end,
    OnWindowChanged = function() end, OnTradeSkillUpdate = function() end,
    GetAll = function() return mine end,
    GetAny = function(_, id) return mine[id], SELF end,
    GetDisplayLink = function(_, id) return mine[id] and mine[id].name or "?" end,
}
ns.Config = { GetCharacterKey = function() return SELF end }
ns.Profit = { GetCraftableCount = function() return 3 end }
ns.Inventory = { GetBagCount = function() return 0 end }
ns.Queue = { GetAll = function() return {} end }
ns.EraRecipes = nil

assert(loadfile(lfs_cwd .. "/Data/EraRecipes.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Crafting.lua"))("Blackthornes_TS", ns)
local Era, Crafting = ns.EraRecipes, ns.Crafting
Era:OnEnable()
Crafting:OnEnable()
Crafting.RememberOutputs = function() end

print("\nno window open")
check("nothing to craft from", Era:OpenRecipeIDs() == nil)

print("\nthe Leatherworking window")
Fire("TRADE_SKILL_SHOW")
check("counts as a profession window", Crafting.isTradeSkillOpen)
local open = Era:OpenRecipeIDs()
check("its recipes", open[9070] and open[2152])
check("a recipe a heading hides still belongs here", open[2149])
check("not another profession's", not open[2963] and not open[7418])

print("\nCraft makes it by its place in the window")
check("started", Crafting:Start(9070, 2) == true)
check("DoTradeSkill with the line and how many", made[1] and made[1][1] == "trade"
    and made[1][2] == 2 and made[1][3] == 2)
check("no error printed", not printed[1]:find("refused"))

print("\na run with crafts left between two casts")
repeatLeft = 2
Fire("UNIT_SPELLCAST_SUCCEEDED", "player", nil, 9070)
now = now + 1
check("still crafting", Crafting:IsStillCrafting())
now = now + 5
check("but not long after the last cast", not Crafting:IsStillCrafting())
Crafting:Stop()
check("Stop ends Era's repeat", stopped)
check("and the run", not Crafting:IsBusy())
repeatLeft = 1

print("\nthe list moved since it was laid out")
table.insert(tradeLines, 2, { "Armor Kits", "header" })
made = {}
check("started", Crafting:Start(2152, 1) == true)
check("found at its new place", made[1] and made[1][2] == 4)
Crafting:Stop()

print("\na recipe a folded heading hides")
made, printed = {}, {}
check("not started", Crafting:Start(2149, 1) == false)
check("nothing called", #made == 0)
check("says so", printed[1] == "cannot craft that")

print("\nEnchanting's own window")
Fire("CRAFT_SHOW")
check("its enchant", Era:OpenRecipeIDs()[7418])
made, printed = {}, {}
check("not from a plain click", Crafting:Start(7418, 5) == false)
check("DoCraft never called from addon code", #made == 0)
check("nothing picked", selected == 0)
check("says so", printed[1] == "cannot craft that")
check("started from the secure button", Crafting:Start(7418, 5, true) == true)
check("DoCraft still never called", #made == 0)
check("the enchant picked in the window", selected == 1 and setSelections == 1)
check("counted as one", Crafting.active.requested == 1)
Crafting:Stop()
check("picked again only when it moved", Crafting:Start(7418, 1, true) == true and setSelections == 1)
Crafting:Stop()

print("\nthe secure button")
assert(loadfile(lfs_cwd .. "/UI/SecureCraft.lua"))("Blackthornes_TS", ns)
local Secure = ns.SecureCraft
local createShown = true
CraftCreateButton = { IsVisible = function() return createShown end }
check("an enchant needs it", Secure:Needed(7418))
check("a trade craft does not", not Secure:Needed(9070))
createShown = false
check("not without the Create button", not Secure:Needed(7418))
createShown = true
Secure.anchor = { disabled = false }
Secure.resolve = function() return 7418, 4 end
check("a click starts it", Secure:OnClicked() == true)
check("busy now", Crafting:IsBusy())
check("a second click stops it", Secure:OnClicked() == false and not Crafting:IsBusy())
Secure.anchor.disabled = true
check("a dead button presses nothing", Secure:OnClicked() == false and not Crafting:IsBusy())
Secure.anchor, Secure.resolve = nil, nil

print("\nclosing one of two windows")
Fire("TRADE_SKILL_CLOSE")
check("the other still counts", Crafting.isTradeSkillOpen)
Fire("CRAFT_CLOSE")
check("both closed", not Crafting.isTradeSkillOpen)

print(("\n%d checks passed"):format(checks))
