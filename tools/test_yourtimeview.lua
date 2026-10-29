-- UI/YourTimeView.lua outside WoW: the Profit tab's Your time view.
--
--   1. Rows sort by the best gold an hour, crafts not timed yet last.
--   2. A row shows both hours, the buy profit and which way is best; one
--      not timed yet says "Not enough yet" and "--".
--   3. "Only with your farming pace" leaves out crafts not timed.
--   4. Picking a row fills the pane: the three ways, the materials with how
--      you farm each, a bought one marked bought; picking it again clears.
--   5. Without Farmer the footer says to turn it on.

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
  return Stub({ text = "", shown = true,
    SetText = function(self, v) self.text = tostring(v) end,
    SetShown = function(self, v) self.shown = v and true or false end,
    Show = function(self) self.shown = true end,
    Hide = function(self) self.shown = false end,
    SetTextColor = function(self, r, g, b) self.color = table.concat({ r, g, b }, ",") end,
  GetWidth = function() return 66 end })
end

local function Frame()
  local f = Label()
  f.CreateFontString = function() return Label() end
  f.CreateTexture = function() return Stub() end
  f.IsVisible = function() return true end
  return f
end

CreateFrame = function() return Frame() end
GameTooltip = Stub()
C_Timer = { After = function() end }
C_Item = { GetItemInfo = function() return "item" end }

ns.Theme = {
  SetRowName = function(label, text) label:SetText(text) end,
  SetRowLine = function(label, text) label:SetText(text) end,
  FitWhole = function(label, text) label:SetText(text); return 0, 13 end,
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

local list, queued
ns.Widgets = {
  SEARCH_WIDTH = 170,
  CreateSearchBox = function() return Stub() end,
  CreateCheckbox = function(_, _, onChange) return Stub({ onChange = onChange }) end,
  CreateButton = function() return Frame() end,
  CreateScrollList = function(_, opts)
    list = Frame()
    list.opts = opts
    list.SetData = function(self, d) self.data = d end
    return list
  end,
  ShowItemOnly = function() end,
}
ns.Util = {
  FormatMoney = function(c) return tostring(c) .. "c" end,
  GetItemLabel = function(id) return "item" .. id end,
  ColorItemName = function(_, name) return name end,
  ColoredItemName = function(id) return "item" .. tostring(id) end,
  GetItemName = function(id, fallback) return fallback or ("item" .. tostring(id)) end,
  Uncolored = function(t) return t end,
  -- Item 12 is green; the others the client has not sent yet.
  GetItemQualityColor = function(id) if id == 12 then return 0.1, 1, 0 end end,
}
ns.RegisterEvent = function() end
ns.Print = function() end
ns.Queue = { Add = function(_, id, n) queued = { id, n } end }
ns.CraftTime = { Format = function(s) return tostring(s) .. "s" end }

local hasFarmer = true
local rows = {
  { recipeID = 1, name = "Slow Shirt", outputItemID = 11, yield = 1, made = 500, buyProfit = 50,
    bought = 0, farmSeconds = 600, craftSeconds = 5, farmCraft = 2000, farmSell = 1500,
    best = "craft", bestValue = 2000,
    mats = { { itemID = 101, count = 4, seconds = 600,
               pace = { seconds = 150, kind = "kill", source = "Vale Bandit" } },
             { itemID = 102, count = 1, bought = 10 } } },
  { recipeID = 2, name = "Herb Potion", outputItemID = 12, yield = 1, made = 300, buyProfit = 20,
    bought = 0, farmSeconds = 60, craftSeconds = 3, farmCraft = 9000, farmSell = 12000,
    best = "raw", bestValue = 12000,
    mats = { { itemID = 103, count = 2, seconds = 60,
               pace = { seconds = 30, kind = "gather", source = "Peacebloom", zone = "Elwynn Forest" } } } },
  { recipeID = 3, name = "Untimed Boots", outputItemID = 13, yield = 1, made = 900, buyProfit = 300,
    mats = { { itemID = 104, count = 3, samples = 7 } }, missing = { itemID = 104, samples = 7 } },
}
ns.CraftOrFarm = {
  HasFarmer = function() return hasFarmer end,
  Rows = function() return rows, false end,
  Build = function() end,
}

assert(loadfile(lfs_cwd .. "/UI/Columns.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/UI/YourTimeView.lua"))("Blackthornes_TS", ns)
local View = ns.YourTimeView

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

print("\nyour time: rows")
check("every craft listed", #list.data, 3)
check("best an hour first", list.data[1].name, "Herb Potion")
check("then the next", list.data[2].name, "Slow Shirt")
check("not timed yet last", list.data[3].name, "Untimed Boots")

local function Draw(entry)
  local row = Frame()
  list.opts.createRow(row)
  list.opts.updateRow(row, entry)
  return row
end
local potion = Draw(rows[2])
check("the name in its rarity colour", potion.name.color, "0.1,1,0")
check("farm + craft", potion.cells.farmCraft.text, "9000c")
check("farm + sell", potion.cells.farmSell.text, "12000c")
check("buy + craft", potion.cells.buyCraft.text, "20c")
check("best says sell the mats", potion.cells.best.text, "Sell the mats")
local boots = Draw(rows[3])
check("no rarity known yet, plain text", boots.name.color, "1,1,1")
check("not timed shows --", boots.cells.farmCraft.text, "--")
check("and says not enough yet", boots.cells.best.text, "Not enough yet")
check("the footer counts", View._widgets.summary.text, "3 crafts  ·  2 timed from your farming")

print("\nyour time: filter")
View._state.paceOnly = true
View.Redraw()
check("only timed crafts", #list.data, 2)
View._state.paceOnly = false
View.Redraw()

print("\nyour time: the pane")
local detail = View._widgets.detail
check("nothing picked, it says how", detail.subtitle.text, "Pick a craft to see where your time goes.")
list.opts.onClick(rows[1], nil, "LeftButton")
check("picked, the title is the craft", detail.title.text, "Slow Shirt")
check("farm then craft an hour", detail.ways[1].value.text, "2000c an hour")
check("its time split", detail.ways[1].note.text, "600s farming, 5s crafting")
check("buy then craft is per craft", detail.ways[3].value.text, "50c")
check("the farmed material", detail.materials[1].label.text, "4x item101")
check("with how you farm it", detail.materials[1].how.text, "1 every 150s from Vale Bandit")
check("the bought one", detail.materials[2].how.text, "Bought from a vendor")
check("unused lines hidden", detail.materials[3].shown, false)
list.opts.onClick(rows[3], nil, "LeftButton")
check("too little farming says how many", detail.materials[1].how.text, "Not enough yet (7 of your 20)")
check("and what to farm", detail.ways[1].note.text, "Farm some item104 and this fills in.")
list.opts.onClick(rows[3], nil, "LeftButton")
check("picked again, cleared", detail.title.text, "Your time")
list.opts.onClick(rows[2], nil, "RightButton")
check("right-click queues one", queued and queued[1] == 2 and queued[2] == 1, true)

print("\nyour time: no Farmer")
hasFarmer = false
View.Redraw()
check("the footer says to turn it on", View._widgets.summary.text,
  "Turn on Blackthornes Farmer to see your farming time.")

print(("\n%s"):format(failures == 0 and "all checks passed" or (failures .. " failure(s)")))
if failures > 0 then error(("%d check(s) failed"):format(failures)) end
