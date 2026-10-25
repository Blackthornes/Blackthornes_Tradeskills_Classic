-- UI/ShuffleView.lua outside WoW: the Profit tab's Shuffles view.
--
--   1. With nothing picked the list is empty and says how to start.
--   2. Picking a start draws every way, the best one picked first.
--   3. A row shows its name, chain and gain with a sign.
--   4. The pane shows each step, "Best place to stop" on the best one and
--      the note on a step that loses gold.
--   5. Queue It shows only for a way you can queue.
--   6. A disenchant step brings the odds line.

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
  f.HookScript = function(self, what, fn) local h = rawget(self, "hookFns") or {}; rawset(self, "hookFns", h); h[what] = fn end
  return f
end

CreateFrame = function() return Frame() end
GameTooltip = Stub()
C_Timer = { After = function() end }
time = function() return 1000 end

ns.Theme = {
  SetRowName = function(label, text) label:SetText(text) end,
  CreateLabel = function() return Label() end,
  CreatePanel = function() return Frame() end,
  AccentStripe = function() end,
  CreateHeading = function() return Label() end,
  CreateDivider = function() return Stub() end,
  SetMoneyText = function(label, copper) label:SetText(tostring(copper) .. "c") end,
  ProfitColor = function() return 1, 1, 1 end,
  Unpack = function() return 1, 1, 1, 1 end,
}

local list, dropdown, buttons = nil, nil, {}
ns.Widgets = {
  CreateCheckbox = function(_, _, onChange) return Stub({ onChange = onChange }) end,
  CreateButton = function(_, text, onClick)
    local b = Frame(); b.onClick = onClick; buttons[text] = b; return b
  end,
  CreateDropdown = function(_, _, onPick)
    dropdown = Frame()
    dropdown.label = Label()
    dropdown.onPick = onPick
    dropdown.SetOptions = function(self, o) self.options = o end
    dropdown.SetValue = function(self, v) self.value = v end
    return dropdown
  end,
  CreateNumberBox = function()
    local box = Frame()
    box.SetValue = function(self, v) self.value = v end
    box.GetValue = function(self) return self.value end
    return box
  end,
  CreateScrollList = function(_, opts)
    list = Frame()
    list.opts = opts
    list.SetData = function(self, d) self.data = d end
    return list
  end,
}
ns.Util = {
  FormatMoney = function(c) return tostring(c) .. "c" end,
  ColoredItemName = function(id, name) return name or ("item" .. tostring(id)) end,
  FormatAgeAgo = function(s) return tostring(s) .. "s ago" end,
}
ns.RegisterEvent = function() end
ns.Print = function() end
ns.Prices = { GetLastScan = function() return 900 end }

local names = { [1] = "Copper Ore", [2] = "Copper Bar", [3] = "Runed Copper Belt", [4] = "Strange Dust" }
local ways = {
  { id = 1, name = "Smelt, make, sell", chain = { 1, 2, 3 }, putIn = 240, back = 1425, gain = 1185, best = 3,
    crafts = { { recipeID = 300, crafts = 10 } }, queueable = true,
    steps = {
      { kind = "start", itemID = 1, count = 10, worth = 190, how = "ah" },
      { kind = "craft", verb = "smelt", itemID = 2, count = 10, worth = 470, change = 280, how = "ah",
        note = "You know this. Mining 75." },
      { kind = "craft", verb = "make", itemID = 3, count = 5, worth = 1425, change = 955, how = "ah", best = true },
    } },
  { id = 2, name = "Smelt, make, disenchant", chain = { 1, 2, 3, 4 }, putIn = 240, back = 750, gain = -60, best = 3,
    crafts = {},
    steps = {
      { kind = "start", itemID = 1, count = 10, worth = 190, how = "ah" },
      { kind = "craft", verb = "smelt", itemID = 2, count = 10, worth = 470, change = 280, how = "ah" },
      { kind = "craft", verb = "make", itemID = 3, count = 5, worth = 1425, change = 955, how = "ah", best = true },
      { kind = "de", itemID = 4, count = 7.5, worth = 750, change = -675, how = "de", loss = true,
        note = "This step loses gold. Sell before it." },
    } },
}
ns.Shuffle = {
  ItemName = function(id) return names[id] end,
  ChainText = function(chain)
    local out = {}
    for _, id in ipairs(chain) do out[#out + 1] = names[id] end
    return table.concat(out, ", ")
  end,
  Starts = function() return { { itemID = 1, count = 10 } } end,
  Get = function(_, itemID) if itemID == 1 then return ways, false end end,
  Build = function() end,
  CanQueue = function(way) return way.queueable == true end,
  BrokenSoFar = function() return 9 end,
}

assert(loadfile(lfs_cwd .. "/UI/Columns.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/UI/ShuffleView.lua"))("Blackthornes_TS", ns)
local View = ns.ShuffleView

local failures = 0
local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(string.format("  FAIL  %-52s got %s, wanted %s", label, tostring(got), tostring(want)))
  else
    print(string.format("  ok    %-52s %s", label, tostring(got)))
  end
end

local view = Frame()
View.Build(view)
local widgets = View._widgets

print("\nshuffles: nothing picked")
check("the bags fill the start box", #dropdown.options, 1)
check("named by the item", dropdown.options[1].text, "Copper Ore")
View.Refresh()
check("no rows yet", #list.data, 0)
check("says how to start", widgets.empty.text,
  "Pick something to start with. You'll see every way to turn it into gold.")
check("pane shows no steps", widgets.detail.steps[1].shown, false)
check("no Queue It yet", widgets.detail.queue.shown, false)

print("\nshuffles: a start picked")
dropdown.onPick(1)
check("every way listed", #list.data, 2)
check("all ten from the bags", View._state.count, 10)
check("the count box follows", widgets.count.value, 10)
check("the empty text hides", widgets.empty.shown, false)
check("the first way is picked", View._state.selected, 1)

local row = Frame()
list.opts.createRow(row)
list.opts.updateRow(row, ways[1])
check("row name", row.name.text, "Smelt, make, sell")
check("row chain", row.chain.text, "Copper Ore, Copper Bar, Runed Copper Belt")
check("row steps", row.cells.steps.text, "3")
check("row gain has a plus", row.cells.gain.text, "+1185c")
list.opts.updateRow(row, ways[2])
check("a losing way has a minus", row.cells.gain.text, "-60c")

local detail = widgets.detail
check("pane title", detail.title.text, "Smelt, make, sell")
check("start step words", detail.steps[1].text.text, "Start with 10 Copper Ore")
check("smelt step words", detail.steps[2].text.text, "Smelt into 10 Copper Bar")
check("make step words", detail.steps[3].text.text, "Make 5 Runed Copper Belt")
check("how it sells", detail.steps[2].how.text, "(AH)")
check("change after a step", detail.steps[2].change.text, "+280c")
check("the best step says so", detail.steps[3].best.shown, true)
check("other steps don't", detail.steps[2].best.shown, false)
check("the skill note", detail.steps[2].note.text, "You know this. Mining 75.")
check("unused lines hide", detail.steps[4].shown, false)
check("Queue It for a way you know", detail.queue.shown, true)
check("no odds without a disenchant", detail.odds.text, "")
check("scan age", widgets.scan.text, "Prices from your scan 100s ago")

print("\nshuffles: the disenchant way")
list.opts.onClick(ways[2])
check("picked", View._state.selected, 2)
check("de step words", detail.steps[4].text.text, "Disenchant into about 8 Strange Dust")
check("de label", detail.steps[4].how.text, "(DE)")
check("loss note", detail.steps[4].note.text, "This step loses gold. Sell before it.")
check("loss change", detail.steps[4].change.text, "-675c")
check("no Queue It", detail.queue.shown, false)
check("odds line", detail.odds.text, "Disenchant odds come from what you've broken. 9 so far.")

print("\nshuffles: signs")
check("zero has no sign", View.Signed(0), "0c")

if failures > 0 then error(failures .. " shuffle view checks failed") end
print("\nshuffle view checks passed")
