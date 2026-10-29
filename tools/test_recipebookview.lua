-- UI/RecipeBookView.lua outside WoW: the Profit tab's Recipes to learn view.
--
--   1. It opens on a profession the character playing has, before the rest.
--   2. Every row draws: money in the columns, "no item" for an enchant,
--      "--" where nothing is priced, "Known" for a learned one.
--   3. Picking a row fills the pane: one craft's worth, materials, where to
--      learn it; picking it again goes back to the overview.
--   4. A profession can be picked by part of its name (/bts recipes leath).
--   5. SKILL is green within the character's skill, amber above it.
--   6. The Level Up tab's copy keeps its own filters and asks for skill
--      order; the switch shows one view at a time and redraws only that one.
--   7. With showSkill it shows the picked profession's skill, or all of
--      yours under All professions; the Profit tab's copy shows none.

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })

local function Stub(fields)
  local frame = fields or {}
  return setmetatable(frame, { __index = function(self, key)
    local noop = function() end
    rawset(self, key, noop)
    return noop
  end })
end

local function Label()
  return Stub({ text = "", SetText = function(self, v) self.text = tostring(v) end,
    GetWidth = function() return 66 end })
end

local function Frame()
  local f = Stub()
  f.CreateFontString = function() return Label() end
  f.CreateTexture = function() return Stub() end
  return f
end

CreateFrame = function() return Frame() end
GameTooltip = Stub()
C_Timer = { After = function() end }
C_Item = { GetItemInfo = function() return "item" end }

ns.Theme = {
  SetRowName = function(label, text) label:SetText(text) end,
  SetItemNameColor = function() return false end,
  CreateLabel = function() return Label() end,
  CreateItemIcon = function() return Stub() end,
  SetItemIcon = function() end,
  CreatePanel = function() return Frame() end,
  AccentStripe = function() end,
  CreateHeading = function() return Label() end,
  CreateDivider = function() return Stub() end,
  SetMoneyText = function(label, copper) label:SetText(tostring(copper) .. "c") end,
  ProfitColor = function() return 1, 1, 1 end,
  Unpack = function() return 1, 1, 1, 1 end,
}

local list, dropdown, strip
ns.Widgets = {
  CreateSearchBox = function() return Stub() end,
  CreateCheckbox = function() return Stub() end,
  CreateDropdown = function()
    dropdown = Stub({ SetOptions = function(self, o) self.options = o end,
      SetValue = function(self, v) self.value = v end })
    return dropdown
  end,
  CreateScrollList = function(_, opts)
    list = Stub({ opts = opts, SetData = function(self, d) self.data = d end })
    return list
  end,
  ShowItemOnly = function() end,
  CreateTabStrip = function(_, tabs, onSelect)
    strip = Stub({ tabs = {}, defs = tabs, onSelect = onSelect,
      Select = function(self, key) self.selected = key end })
    return strip
  end,
}

ns.Util = {
  FormatMoney = function(c) return tostring(c) .. "c" end,
  GetItemLabel = function(id) return "item" .. id end,
  Uncolored = function(t) return t end,
  -- Item 2307 is Uncommon; item 5 (a known recipe's) is Rare; others not loaded.
  GetItemQualityColor = function(id)
    if id == 2307 then return 0.12, 1, 0 end
    if id == 5 then return 0, 0.44, 0.87 end
  end,
}
ns.RegisterEvent = function() end

local record = { recipeID = 1, name = "Fine Leather Boots", profession = "Leatherworking", skill = 90,
  outputItemID = 2307, recipeItems = { 2406 } }
local enchant = { recipeID = 2, name = "Enchant Bracer", profession = "Enchanting", skill = 1,
  recipeItems = { 6342 } }

local rows = {
  { recipeID = 1, record = record, name = record.name, skill = 90, outputItemID = 2307,
    cost = 80, auction = 200, disenchant = 120, profit = 120, price = 900, learn = "Drop" },
  { recipeID = 2, record = enchant, name = enchant.name, skill = 1, learn = "Trainer" },
  { recipeID = 3, record = record, name = "Known Thing", skill = 5, outputItemID = 5, known = true,
    learn = "Trainer" },
}
local asked
ns.RecipeBook = {
  GetProfessions = function() return { "Enchanting", "Leatherworking" } end,
  List = function(_, opts) asked = opts return rows end,
  LearnFrom = function() return "Drop", { "World drop (569 kinds of creature)" } end,
  KnownByText = function() return nil end,
  Value = function()
    return { cost = 80, profit = 120, backWay = "auction", price = 900, priceHow = "auction",
      payback = 8, returns = { auction = 200, disenchant = 120 },
      costDetail = { reagents = { { itemID = 2318, quantity = 7, lineCost = 70 } } } }
  end,
}
ns.Recipes = { GetLearnedProfessions = function() return { { name = "Leatherworking" } } end }

assert(loadfile(lfs_cwd .. "/UI/Columns.lua"))("Blackthornes_TS", ns)

assert(loadfile(lfs_cwd .. "/UI/RecipeBookView.lua"))("Blackthornes_TS", ns)
local View = ns.RecipeBookView

local failures = 0
local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(string.format("  FAIL  %-52s got %s, wanted %s", label, tostring(got), tostring(want)))
  else
    print(string.format("  ok    %-52s %s", label, tostring(got)))
  end
end

View.Build(Frame())
View.Refresh()

print("\nopening")
check("opens on the character's profession", View._state.profession, "Leatherworking")
check("which the list was asked for", asked.profession, "Leatherworking")
check("learned ones left out", asked.includeKnown, false)
check("its own profession is offered first", dropdown.options[2].text, "Leatherworking")
check("then a line saying the rest are others", dropdown.options[3].text, "Other professions")
check("which cannot be picked", dropdown.options[3].header, true)
check("then the rest", dropdown.options[4].text, "Enchanting")
check("every row listed", #list.data, 3)

print("\nrows")
local lastRow
local function Draw(entry)
  local row = Frame()
  list.opts.createRow(row)
  row.name.SetTextColor = function(self, r, g, b, a) self.color = { r, g, b, a } end
  list.opts.updateRow(row, entry)
  lastRow = row
  return row.cells
end
local boots = Draw(rows[1])
check("cost", boots.cost.text, "80c")
check("sells", boots.sells.text, "200c")
check("disenchant", boots.disenchant.text, "120c")
check("profit", boots.profit.text, "120c")
check("recipe price", boots.price.text, "900c")
check("learn from", boots.learn.text, "Drop")
local ench = Draw(rows[2])
check("an enchant makes no item", ench.sells.text, "no item")
check("an unpriced profit is a dash", ench.profit.text, "--")
check("an unpriced cost is a dash", ench.cost.text, "--")
check("a known one says so", Draw(rows[3]).learn.text, "Known")
check("a known one keeps its rarity, faded", lastRow.name.color[3] .. "/" .. lastRow.name.color[4], "0.87/0.55")
Draw(rows[1])
check("the name is in its rarity colour", lastRow.name.color[1] .. "/" .. lastRow.name.color[4], "0.12/1")
Draw(rows[2])
check("an enchant with no item stays plain", lastRow.name.color[1], 1)
list.opts.onEnter(Frame(), rows[1])
list.opts.onEnter(Frame(), rows[2])

print("\nthe pane")
list.opts.onClick(rows[1])
check("picking a row selects it", View._state.selected, 1)
check("the pane names it", View._widgets.detail.title.text, "Fine Leather Boots")
check("with who knows it", View._widgets.detail.subtitle.text,
  "Leatherworking 90  ·  nobody on this account knows it")
check("cost first", View._widgets.detail.values[1].label.text, "Cost to make")
check("payback last", View._widgets.detail.values[6].value.text, "8 crafts")
check("materials", View._widgets.detail.materials[1].label.text, "7x item2318")
check("where to learn", View._widgets.detail.learn.text, "World drop (569 kinds of creature)")
list.opts.onClick(rows[1])
check("picking it again goes back", View._state.selected, nil)
check("to the overview", View._widgets.detail.title.text, "Recipes to learn")

print("\npicking a profession by name")
View.SetProfession("ench")
check("part of a name is enough", View._state.profession, "Enchanting")

print("\nthe skill column")
ns.Recipes.GetLearnedProfessions = function() return { { name = "Leatherworking", skillLevel = 95 } } end
local colors = {}
ns.Theme.Unpack = function(key) colors[#colors + 1] = key return 1, 1, 1, 1 end
View.Refresh()
local function SkillColor(entry)
  colors = {}
  local row = Frame()
  list.opts.createRow(row)
  row.cells = row.cells
  local cell
  list.opts.updateRow(row, entry)
  return row.cells.skill, colors
end
local learnable = { recipeID = 9, record = record, name = "x", skill = 90, profession = "Leatherworking",
  outputItemID = 1, learn = "Trainer" }
local _, c1 = SkillColor(learnable)
local found = false
for _, key in ipairs(c1) do if key == "profit" then found = true end end
check("a recipe within your skill is green", found, true)
learnable.skill = 120
local _, c2 = SkillColor(learnable)
found = false
for _, key in ipairs(c2) do if key == "warn" then found = true end end
check("one above your skill is amber", found, true)
ns.Theme.Unpack = function() return 1, 1, 1, 1 end

print("\na second copy for Level Up")
local mainList = list
local second = View.New({ order = "skill" })
second.Build(Frame())
second.Refresh()
check("the Level Up copy asks for skill order", asked.order, "skill")
check("it keeps its own list", list ~= mainList, true)
second.SetProfession("ench")
View.SetProfession("leath")
check("its own profession", second._state.profession, "Enchanting")
check("does not move the other's", View._state.profession, "Leatherworking")

print("\nthe skill at the top right")
check("the Profit copy shows none", View._widgets.skill, nil)
ns.Recipes.GetLearnedProfessions = function()
  return { { name = "Enchanting", skillLevel = 206, maxSkillLevel = 225 },
           { name = "Tailoring", skillLevel = 150, maxSkillLevel = 150 } }
end
local third = View.New({ order = "skill", showSkill = true })
third.Build(Frame())
third.SetProfession("ench")
third.Refresh()
check("the picked profession's skill", third._widgets.skill.text, "ENCHANTING  206 / 225")
third._state.profession = "all"
third.Refresh()
check("every one of yours under All professions", third._widgets.skill.text,
  "ENCHANTING  206 / 225   ·   TAILORING  150 / 150")

print("\nthe switch at the top of a tab")
local built, refreshed = nil, 0
local tab = View.WithSwitch({ mainKey = "recipes", mainText = "MY RECIPES", mainTip = "tip",
  buildMain = function(frame) built = frame end, refreshMain = function() refreshed = refreshed + 1 end,
  learn = second })
tab.Build(Frame())
check("the tab's own view is built", built ~= nil, true)
check("and shown first", tab.view, "recipes")
check("and drawn", refreshed, 1)
check("the views are tabs", strip and #strip.defs, 2)
check("the tab showing is lit", strip.selected, "recipes")
strip.onSelect("learn")
check("a tab click shows its view", tab.view, "learn")
check("and lights that tab", strip.selected, "learn")
tab.ShowView("recipes")
tab.ShowView("learn")
check("the switch moves to Recipes to learn", tab.view, "learn")
tab.Refresh()
check("which redraws the list, not the tab's view", refreshed, 2)
tab.ShowView("nonsense")
check("an unknown view falls back to the tab's own", tab.view, "recipes")

if failures > 0 then error(("%d recipes view check(s) failed"):format(failures)) end
print("\n  recipes to learn view: all checks passed")
