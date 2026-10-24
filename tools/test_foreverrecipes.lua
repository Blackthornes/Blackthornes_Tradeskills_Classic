-- Data/ForeverRecipes.lua and Logic/RecipeBook.lua outside WoW: the
-- recipes Forever added show among the recipes to learn before anyone has
-- opened a profession window (the owner, 2026-10-17).
--
--   1. The shipped file lays its recipes and recipe items into the book,
--      marked, and never over a row the book already has.
--   2. The book lists them with Forever's yellow and grey, their recipe
--      items and the profession.
--   3. One that makes the same item as a Classic recipe of another
--      profession is never taken for it: a window's new ID for the Classic
--      recipe still finds the Classic one.
--   4. A window's recipe under the same ID wins over the shipped row.
--   5. Where to learn it says it is new on Forever, never "a quest,
--      reputation or the other faction".

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {} ns[name] = m return m end

local now = 1000000
time = function() return now end
GetTime = function() return now end
UnitFactionGroup = function() return "Alliance" end

ns.Config = { Get = function() return nil end, GetCharacterKey = function() return "me" end }
ns.Util = { FormatMoney = function(c) return tostring(c) .. "c" end, HasFunction = function() return false end }
ns.Recipes = {
  GetAny = function() return nil end,
  GetAll = function() return {} end,
  GetAccountWide = function() return {} end,
  GetShortCharacterName = function(_, key) return key end,
}
ns.Vendor = { GetTable = function() return {} end, GetUnitPrice = function() return nil end }
ns.Prices = { GetValue = function() return nil end }

local POTION = 118
ns.RECIPE_BOOK = {
  PROFESSIONS = { [129] = "First Aid", [171] = "Alchemy", [165] = "Leatherworking" },
  RECIPES = {
    [2330] = { 171, 1, POTION, 1, 1, { 2447, 1, 765, 1, 3371, 1 }, "Minor Healing Potion", s = 1 },
  },
  ITEMS = {},
}

local failures = 0
local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(string.format("  FAIL  %-60s got %s, wanted %s", label, tostring(got), tostring(want)))
  else
    print(string.format("  ok    %-60s %s", label, tostring(got)))
  end
end

print("\nthe shipped file")
local real = { PROFESSIONS = {}, RECIPES = { [1244431] = "kept" }, ITEMS = {} }
local fileNs = { RECIPE_BOOK = real }
assert(loadfile(lfs_cwd .. "/Data/ForeverRecipes.lua"))("Blackthornes_TS", fileNs)
local count, marked, items = 0, 0, 0
for id, row in pairs(real.RECIPES) do
  if type(row) == "table" then
    count = count + 1
    if row.f == 1 and id >= 1000000 then marked = marked + 1 end
  end
end
for _, row in pairs(real.ITEMS) do
  if row.f == 1 and real.RECIPES[row[1]] then items = items + 1 end
end
check("it adds hundreds of recipes", count > 500, true)
check("every one marked and in Forever's range", marked, count)
check("its recipe items teach recipes it added", items > 500, true)
check("a row the book has is never replaced", real.RECIPES[1244431], "kept")
check("without a book it does nothing", pcall(loadfile(lfs_cwd .. "/Data/ForeverRecipes.lua"), "x", {}), true)

print("\nin the book")
ns.RECIPE_BOOK.RECIPES[1244431] = { 129, 55, POTION, 1, 1, { 3371, 1, 2678, 1 }, "Minor Healing Potion", f = 1, y = 55, g = 95 }
ns.RECIPE_BOOK.RECIPES[1255019] = { 165, 120, 252000, 1, 1, { 2318, 4 }, "Blue Suede Bracers", f = 1, y = 125, g = 150 }
ns.RECIPE_BOOK.ITEMS[252888] = { 1255019, 2400, f = 1 }

-- A window showed Alchemy's potion under an ID of the game's own.
ns.db = { seenRecipes = {
  [1240000] = { name = "Minor Healing Potion", outputItemID = POTION, skillLineID = 171, reagents = {} },
} }
assert(loadfile(lfs_cwd .. "/Logic/RecipeBook.lua"))("Blackthornes_TS", ns)
local Book = ns.RecipeBook

local bracers = Book:Get(1255019)
check("a Forever recipe is listed", bracers and bracers.name, "Blue Suede Bracers")
check("marked as Forever's", bracers.forever, true)
check("with its profession", bracers.profession, "Leatherworking")
check("turns yellow where the game says", bracers.yellow, 125)
check("and grey", bracers.grey, 150)
check("its recipe item teaches it", Book:ForItem(252888).recipeID, 1255019)

local firstAid = Book:Get(1244431)
check("First Aid's potion stays First Aid's", firstAid.profession, "First Aid")
check("the window's Alchemy potion found Alchemy's recipe", Book:Get(1240000).profession, "Alchemy")
check("the old Classic ID still finds Alchemy's", Book:Get(2330).recipeID, 1240000)

print("\nwhere to learn it")
local _, lines = Book:LearnFrom(bracers)
check("its recipe item names no Forever", lines[1], nil)
local _, firstLines = Book:LearnFrom(firstAid)
check("nor one with no recipe item", firstLines[1], nil)

print("\na window wins")
ns.db.seenRecipes[1255019] = { name = "Blue Suede Bracers", outputItemID = 252000, skillLineID = 165,
  reagents = { { itemID = 2318, quantity = 6 } } }
Book:Invalidate()
bracers = Book:Get(1255019)
check("the window's materials win", bracers.reagents[1].quantity, 6)
check("still Forever's", bracers.forever, true)
check("and seen in game", bracers.seenInGame, true)

if failures > 0 then error(("%d Forever recipe check(s) failed"):format(failures)) end
print("\n  Forever recipes: all checks passed")
