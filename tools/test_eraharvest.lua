-- Profession windows read the Classic Era way.
--
-- Era has no C_TradeSkillUI recipe calls: its profession window is read by
-- position (GetTradeSkillInfo), Enchanting has a window of its own
-- (GetCraftInfo), and professions and levels come from the skill list
-- (GetSkillLineInfo). Data/EraRecipes.lua reads them into the same recipe
-- records Forever's harvest makes, keyed by spell ID: from the recipe link
-- when the client gives one, else Classic's book by what it makes, then by
-- name.

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

UnitName = function() return "Ana" end
UnitGUID = function() return "Player-1-A" end
UnitClass = function() return "Mage", "MAGE" end
UnitLevel = function() return 30 end
UnitFactionGroup = function() return "Alliance" end
GetRealmName = function() return "Era Realm" end
time = time or os.time
C_TradeSkillUI = nil
Enum = {}

-- The skill list: a heading, two professions, a weapon skill.
local skills = {
    { "Professions", true, 0, 0 },
    { "Tailoring", false, 75, 150 },
    { "Enchanting", false, 40, 75 },
    { "Swords", false, 30, 150 },
}
GetNumSkillLines = function() return #skills end
GetSkillLineInfo = function(i)
    local s = skills[i]
    return s[1], s[2], false, s[3], 0, 0, s[4]
end
GetSpellInfo = function(id)
    local names = { [3908] = "Tailoring", [7411] = "Enchanting" }
    return names[id]
end

-- The Tailoring window. Line 3 makes the same item two recipes make, line 4
-- has a material not loaded yet, line 5 is in no book.
local tradeLines = {
    { "Cloth", "header" },
    { "Bolt of Linen Cloth", "trivial", item = 2996, made = { 1, 1 }, mats = { { 2589, 2 } } },
    { "Brown Linen Robe", "optimal", item = 6238, made = { 1, 1 }, mats = { { 2996, 3 }, { 2320, 2 } } },
    { "Linen Belt", "medium", item = 7026, made = { 1, 1 }, mats = { { 2996, 1 }, { false, 1 } } },
    { "Forever Shirt", "easy", item = 99999, made = { 1, 1 }, mats = { { 2996, 1 } } },
}
local tradeName, tradeRank = "Tailoring", 75
local recipeLinks = false
GetTradeSkillLine = function() return tradeName, tradeRank, 150 end
GetNumTradeSkills = function() return #tradeLines end
GetTradeSkillInfo = function(i) return tradeLines[i][1], tradeLines[i][2] end
GetTradeSkillItemLink = function(i)
    local line = tradeLines[i]
    return line.item and ("|Hitem:%d::::|h[x]|h"):format(line.item) or nil
end
GetTradeSkillRecipeLink = function(i)
    if not recipeLinks then return nil end
    return ("|Henchant:%d|h[x]|h"):format(5000 + i)
end
GetTradeSkillNumMade = function(i) return unpack(tradeLines[i].made) end
GetTradeSkillNumReagents = function(i) return #tradeLines[i].mats end
GetTradeSkillReagentInfo = function(i, r) return "mat", nil, tradeLines[i].mats[r][2], 0 end
GetTradeSkillReagentItemLink = function(i, r)
    local id = tradeLines[i].mats[r][1]
    return id and ("|Hitem:%d::::|h[m]|h"):format(id) or nil
end

-- The Enchanting window: an enchant, a rod, and Beast Training's lines.
local craftName = "Enchanting"
local craftLines = {
    { "Enchant Bracer - Minor Health", nil, "optimal", link = "|Henchant:7418|h[Enchant]|h",
      mats = { { 10940, 1 } } },
    { "Runed Copper Rod", nil, "easy", link = "|Hitem:6218::::|h[Rod]|h", mats = { { 6217, 1 }, { 10940, 1 } } },
}
GetCraftDisplaySkillLine = function() return craftName, 40, 75 end
GetNumCrafts = function() return #craftLines end
GetCraftInfo = function(i) return craftLines[i][1], craftLines[i][2], craftLines[i][3] end
GetCraftItemLink = function(i) return craftLines[i].link end
GetCraftNumReagents = function(i) return #craftLines[i].mats end
GetCraftReagentInfo = function(i, r) return "mat", nil, craftLines[i].mats[r][2], 0 end
GetCraftReagentItemLink = function(i, r) return ("|Hitem:%d::::|h[m]|h"):format(craftLines[i].mats[r][1]) end

-- Timers and a worker the test runs by hand.
local timers = {}
C_Timer = {
    NewTimer = function(_, fn)
        local t = { fn = fn, Cancel = function(self) self.cancelled = true end }
        timers[#timers + 1] = t
        return t
    end,
    NewTicker = function() return { Cancel = function() end } end,
}
local function RunTimers()
    local due = timers
    timers = {}
    for _, t in ipairs(due) do if not t.cancelled then t.fn() end end
end

local worker
local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
local handlers = {}
ns.RegisterEvent = function(owner, event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], function(...) fn(owner, event, ...) end)
    return true
end
local function Fire(event)
    for _, fn in ipairs(handlers[event] or {}) do fn() end
end
ns.Warn, ns.Print, ns.PrintRaw, ns.Debug = function() end, function() end, function() end, function() end
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.Util = {
    Count = function(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end,
    CopyDeep = function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end,
    HasFunction = function() return false end,
    NewWorker = function(opts)
        worker = { opts = opts, items = {}, index = 0, running = false }
        function worker:Start(items) self.items, self.index, self.running = items, 0, true return self end
        function worker:Cancel()
            if not self.running then return end
            self.running = false
            if self.opts.onCancel then self.opts.onCancel(self) end
        end
        function worker:Finish()
            while self.running do
                self.index = self.index + 1
                self.opts.onItem(self.items[self.index], self.index, self)
                if self.running and self.index >= #self.items then
                    self.running = false
                    if self.opts.onDone then self.opts.onDone(self) end
                end
            end
        end
        return worker
    end,
}
local caps = { tradeskill = { mode = "legacy", hasAllProfessionLines = false } }
ns.Compat = { Get = function() return caps end, TradeskillMode = function() return caps.tradeskill.mode end }

-- Classic's book. Two recipes make the robe's item, so it is told apart by
-- name.
ns.RECIPE_BOOK = { RECIPES = {
    [2963] = { 197, 1, 2996, 1, 1, { 2589, 2 }, "Bolt of Linen Cloth" },
    [7623] = { 197, 10, 6238, 1, 1, { 2996, 3, 2320, 2 }, "Brown Linen Robe" },
    [7624] = { 197, 10, 6238, 1, 1, { 2996, 3, 2320, 2 }, "White Linen Robe" },
    [8776] = { 197, 15, 7026, 1, 1, { 2996, 1, 2320, 1 }, "Linen Belt" },
    [7421] = { 333, 1, 6218, 1, 1, { 6217, 1, 10940, 1 }, "Runed Copper Rod" },
} }

assert(loadfile(lfs_cwd .. "/Core/Config.lua"))("Blackthornes_TS", ns)
ns.Config.Get = function() return nil end
assert(loadfile(lfs_cwd .. "/Data/Recipes.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Data/EraRecipes.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/SkillUp.lua"))("Blackthornes_TS", ns)

local SELF = "Player-1-A"
ns.db = { characters = { [SELF] = { name = "Ana", recipes = {}, inventory = {} } } }
ns.Config.characterKey = SELF

local Recipes, Era = ns.Recipes, ns.EraRecipes
Recipes:OnEnable()
Era:OnEnable()
local function Saved(id) return ns.db.characters[SELF].recipes[id] end

print("\nprofessions from the skill list")
local professions = Recipes:GetProfessions()
check("two professions, weapon skills left out", #professions == 2)
check("by Classic's skill lines", professions[1].skillLineID == 333 and professions[2].skillLineID == 197)
check("with their levels", professions[2].skillLevel == 75 and professions[2].maxSkillLevel == 150)
check("Butler's levels too", ns.SkillUp:ReadSkillLevels()[197] == 75)
local record = ns.db.characters[SELF]
check("learned lines saved", record.professionLines[197] == true and record.professionLines[333] == true)
check("a profession the list leaves out reads as dropped", record.professionLines[171] == false)

print("\na German client knows its professions by their spells")
Era._Forget()
Recipes._ForgetProfessionNames()
GetSpellInfo = function(id) return ({ [3908] = "Schneiderei", [7411] = "Verzauberkunst" })[id] end
skills[2][1], skills[3][1] = "Schneiderei", "Verzauberkunst"
check("Schneiderei is Tailoring", Recipes.EnglishProfessionName("Schneiderei") == "Tailoring")
check("and reads as its skill line", Era:SkillLevels()[197] == 75 and Era:SkillLevels()[333] == 40)
skills[2][1], skills[3][1] = "Tailoring", "Enchanting"
Era._Forget()
Recipes._ForgetProfessionNames()

print("\nat login the skill list is empty")
local saved = skills
skills = {}
local lines, any = Era:ProfessionLines()
check("nothing is called dropped", next(lines) == nil and not any)
skills = saved

print("\nnothing is read while no window is open")
Fire("TRADE_SKILL_UPDATE")
RunTimers()
check("no harvest", worker == nil)

print("\nthe Tailoring window")
Fire("TRADE_SKILL_SHOW")
RunTimers()
check("a harvest started", worker and worker.running)
worker:Finish()
check("found by what it makes", Saved(2963) and Saved(2963).outputItemID == 2996)
check("two makers of one item told apart by name", Saved(7623) and not Saved(7624))
check("its materials", Saved(7623).reagents[1].itemID == 2996 and Saved(7623).reagents[2].quantity == 2)
check("its skill line", Saved(7623).skillLineID == 197)
check("its colour", Saved(7623).skillUp and Saved(7623).skillUp.tier == "optimal"
    and Saved(2963).skillUp.tier == "trivial")
check("a material not loaded yet leaves the line for later", Saved(8776) == nil)
check("a line no book knows is left out", (function()
    for id in pairs(record.recipes) do if id ~= 2963 and id ~= 7623 then return false end end
    return true
end)())

print("\nthe next update reads the line once its material loads")
tradeLines[4].mats[2][1] = 2320
worker = nil
Fire("TRADE_SKILL_UPDATE")
RunTimers()
check("read again", worker ~= nil)
worker:Finish()
check("the belt now", Saved(8776) and #Saved(8776).reagents == 2)

print("\na craft's bag change reads nothing new")
worker = nil
Fire("TRADE_SKILL_UPDATE")
RunTimers()
check("nothing read", worker == nil)
tradeRank = 76
Fire("TRADE_SKILL_UPDATE")
RunTimers()
check("a skill point reads again", worker ~= nil)
worker:Finish()

print("\nthe window closes partway through")
worker = nil
tradeRank = 77
Fire("TRADE_SKILL_UPDATE")
RunTimers()
Fire("TRADE_SKILL_CLOSE")
worker:Finish()
check("the harvest stopped", not worker.running and not Recipes.harvesting)
worker = nil
Fire("TRADE_SKILL_UPDATE")
RunTimers()
check("and a closed window is never read", worker == nil)

print("\na recipe link names the spell")
recipeLinks = true
Fire("TRADE_SKILL_SHOW")
RunTimers()
worker:Finish()
check("the link wins over the book", Saved(5005) and Saved(5005).name == "Forever Shirt")
Fire("TRADE_SKILL_CLOSE")
recipeLinks = false

print("\nthe Enchanting window")
worker = nil
Fire("CRAFT_SHOW")
RunTimers()
check("a harvest started", worker ~= nil)
worker:Finish()
check("an enchant by its link", Saved(7418) and Saved(7418).outputItemID == nil
    and Saved(7418).skillLineID == 333)
check("a rod by what it makes", Saved(7421) and Saved(7421).outputItemID == 6218)
check("with its colour", Saved(7418).skillUp and Saved(7418).skillUp.tier == "optimal")
Fire("CRAFT_CLOSE")

print("\nBeast Training's window is no profession")
craftName = nil
local before = ns.Util.Count(record.recipes)
craftLines[1].link = "|Henchant:9999|h[x]|h"
worker = nil
Fire("CRAFT_SHOW")
RunTimers()
check("nothing read", worker == nil and ns.Util.Count(record.recipes) == before)
Fire("CRAFT_CLOSE")

print("\nForever's client never uses it")
caps.tradeskill.mode = "modern"
local hooked = false
ns.RegisterEvent = function() hooked = true return true end
Era:OnEnable()
check("no Era events on a modern client", not hooked)

print(("\n%d checks passed"):format(checks))
