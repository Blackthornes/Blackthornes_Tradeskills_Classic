-- Clear Items on the Characters tab (2026-11-10).
--
-- A player's jobs sent them to mail items alts had long since used. Clear
-- Items forgets one character's saved bags, bank, mail and gold, and
-- nothing else; never the character playing.

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

UnitName = function() return "Bob" end
UnitGUID = function() return "Player-1-A" end
UnitClass = function() return "Mage", "MAGE" end
UnitLevel = function() return 40 end
UnitFactionGroup = function() return "Horde" end
GetRealmName = function() return "Forever PvE" end
time = time or os.time

-- The client's profession list: both of Forever's IDs for each profession.
-- maxSkillLevel 0 is unlearned, or not loaded yet.
local levels = { [197] = 0, [2942] = 0, [186] = 0, [2950] = 0 }
C_TradeSkillUI = {
    GetAllProfessionTradeSkillLines = function() return { 2942, 197, 2950, 186 } end,
    GetProfessionInfoBySkillLineID = function(id)
        local names = { [197] = "Tailoring", [2942] = "Tailoring", [186] = "Mining", [2950] = "Mining" }
        return { professionName = names[id], skillLevel = levels[id], maxSkillLevel = levels[id] }
    end,
}

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() end
ns.Warn, ns.Print, ns.PrintRaw, ns.Debug = function() end, function() end, function() end, function() end
ns.COLORS = {}
ns.Util = {
    Count = function(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end,
    CopyDeep = function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end,
}
ns.Compat = { Get = function() return { tradeskill = { hasAllProfessionLines = true } } end }

assert(loadfile(lfs_cwd .. "/Core/Config.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Data/Recipes.lua"))("Blackthornes_TS", ns)

local SELF, ALT = "Player-1-A", "Player-1-B"
ns.db = { characters = {
    [SELF] = { name = "Bob", inventory = { [1] = 5 }, inventoryAt = 10, gold = 50 },
    [ALT] = { name = "Mirel", surname = "Ash", recipes = { [10] = { recipeID = 10, name = "Robe" } },
              professions = { { name = "Tailoring" } },
              inventory = { [1] = 300 }, inventoryAt = 100, gold = 9000,
              bank = { [2] = 40 }, bankAt = 110, mail = { [3] = 2 }, mailAt = 120,
              mailExpiry = { count = 1 }, mailMoney = 5000 },
} }
ns.Config.characterKey = SELF
local Recipes = ns.Recipes

print("\nclearing an alt")
check("it clears", Recipes:ClearItems(ALT) == true)
local alt = ns.db.characters[ALT]
for _, field in ipairs({ "inventory", "inventoryAt", "gold", "bank", "bankAt", "mail", "mailAt", "mailExpiry", "mailMoney" }) do
    check("forgets " .. field, alt[field] == nil)
end
check("keeps its recipes", alt.recipes[10] ~= nil)
check("keeps its professions", alt.professions[1].name == "Tailoring")
check("keeps its name", alt.name == "Mirel")
check("keeps when it was last seen", alt.seenAt == 100)
check("notes when it was cleared", type(alt.clearedAt) == "number")

print("\nnever the character playing")
check("refused", Recipes:ClearItems(SELF) == false)
check("its bags stay", ns.db.characters[SELF].inventory[1] == 5)
check("a character not on record is refused", Recipes:ClearItems("Nobody") == false)

print(("\n  %d checks passed\n"):format(checks))
