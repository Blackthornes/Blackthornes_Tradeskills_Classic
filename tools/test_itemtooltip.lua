-- What goes on an item's tooltip, and how often.
--
-- The hooking cannot be measured outside the game -- which of the three shapes
-- this client fires is exactly the unknown -- but everything that decides what
-- a tooltip *says* can be, and four things in it are worth a test:
--
--   1. An item nobody has scanned must not print a price. A zero reads as
--      "this sells for nothing", which is a claim about the market.
--   2. ...but it must not be silent either, when the item is something you
--      could actually sell. Silence and "not scanned yet" look the same on a
--      tooltip and mean completely different things.
--   3. Installing three hooks is only safe because a second one finds the line
--      already there. If the duplicate guard breaks, every tooltip in the game
--      says everything twice.
--   4. The stack total arrives after the unit value, because only the call
--      that built the tooltip knew which bag slot it was drawing. It has to
--      land on the tooltip anyway, and exactly once.

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end

ns.COLORS = {
  accent = "ffc8a44d",
  muted  = "ff7a8089",
  text   = "ffe6e8ec",
}

ns.Print = function() end
ns.PrintRaw = function() end
ns.RegisterCommand = function() end

-- Money formatting is not under test: the stub says plainly what it was
-- handed, so a wrong *number* is visible rather than hidden behind spelling.
ns.Util = {
  FormatMoney = function(copper) return ("<%d>"):format(copper) end,
  FormatAgeAgo = function(seconds) return ("%dh ago"):format(seconds / 3600) end,
  GetItemLabel = function(itemID) return ("item %d"):format(itemID) end,
  HasFunction = function(path) return path == "C_Item.GetItemInfo" end,
}

--------------------------------------------------------------------------------
-- The world the tooltips are read against
--------------------------------------------------------------------------------

local LINEN_CLOTH   = 2589   -- priced, fresh, stacks
local COPPER_BAR    = 2840   -- priced, but the price is old
local SILK_CLOTH    = 4306   -- scanned, nothing was listed
local RUNECLOTH     = 14047  -- never scanned, but sellable
local BOUND_SWORD   = 7001   -- never scanned, and bind-on-pickup
local QUEST_TOKEN   = 9999   -- never scanned, and a quest item

local PRICES = {
  [LINEN_CLOTH] = 2300,
  [COPPER_BAR]  = 1500,
  [SILK_CLOTH]  = 0,
}

local STALE = { [COPPER_BAR] = true }
local AGES  = { [COPPER_BAR] = 3 * 3600 }

ns.Prices = {
  GetValue = function(_, itemID, which)
    assert(which == "market", "a tooltip shows market value, got " .. tostring(which))
    return PRICES[itemID]
  end,
  IsStale = function(_, itemID) return STALE[itemID] == true end,
  GetAge = function(_, itemID) return AGES[itemID] end,
}

ns.Config = { Get = function(_, key) return ns.settings and ns.settings[key] end }
ns.settings = {}

-- GetItemInfo's twelfth and fourteenth returns are the ones that decide
-- whether an unpriced item is worth mentioning at all.
local ITEMS = {
  [LINEN_CLOTH] = { classID = 7,  bindType = 0 },
  [COPPER_BAR]  = { classID = 7,  bindType = 0 },
  [SILK_CLOTH]  = { classID = 7,  bindType = 0 },
  [RUNECLOTH]   = { classID = 7,  bindType = 0 },
  [BOUND_SWORD] = { classID = 2,  bindType = 1 },
  [QUEST_TOKEN] = { classID = 12, bindType = 0 },
}

C_Item = {
  GetItemInfo = function(itemID)
    local item = ITEMS[itemID]
    if not item then return nil end

    return ("item %d"):format(itemID), nil, nil, nil, nil, nil, nil, nil, nil,
      nil, nil, item.classID, nil, item.bindType
  end,
}

local ItemTooltip
do
  local realNew = ns.NewModule
  ns.NewModule = function(name) local m = realNew(name); ItemTooltip = m; return m end
  local chunk = assert(loadfile(lfs_cwd .. "/UI/ItemTooltip.lua"))
  chunk("Blackthornes_TS", ns)
  ns.NewModule = realNew
end

-- OnEnable installs hooks, which need a game. The counters it also sets up are
-- read by Decorate, so they are set here instead.
ItemTooltip.fired = {}
ItemTooltip.counts = {}
ItemTooltip.seen = 0

--------------------------------------------------------------------------------
-- A tooltip, in as much detail as this needs
--------------------------------------------------------------------------------

local function Tooltip(itemID)
  local tooltip = { lines = {}, shown = 0, base = 4 }

  function tooltip:AddDoubleLine(left, right)
    self.lines[#self.lines + 1] = { left, right }
  end

  -- Real tooltips start with the name, the binding, the stack size and so on.
  -- Counting those matters: the duplicate guard compares line counts.
  function tooltip:NumLines() return self.base + #self.lines end
  function tooltip:Show() self.shown = self.shown + 1 end

  function tooltip:GetItem()
    if not self.itemID then return nil end
    return ("item %d"):format(self.itemID),
      ("|cffffffff|Hitem:%d:0:0:0|h[thing]|h|r"):format(self.itemID)
  end

  -- What the client does between draws, and what the real OnTooltipCleared
  -- hook is wired to.
  function tooltip:Clear()
    self.lines = {}
    ItemTooltip.Forget(self)
  end

  tooltip.itemID = itemID

  return tooltip
end

local function check(label, got, want)
  if got ~= want then
    error(("%s: expected %s, got %s"):format(label, tostring(want), tostring(got)), 2)
  end
end

--------------------------------------------------------------------------------
-- Reading an item out of a link
--------------------------------------------------------------------------------

check("a full item link",
  ItemTooltip.ItemIDFromLink("|cffffffff|Hitem:2589:0:0:0:0:0:0:0|h[Linen Cloth]|h|r"),
  2589)

check("a bare item string", ItemTooltip.ItemIDFromLink("item:2589"), 2589)

-- A spell link's ID is not an item's, and pricing item 25 because somebody
-- linked spell 25 would be a wrong number with nothing to hint at it.
check("a spell link is refused",
  ItemTooltip.ItemIDFromLink("|cff71d5ff|Hspell:25:0|h[Stealth]|h|r"), nil)

check("an enchant link is refused",
  ItemTooltip.ItemIDFromLink("|Henchant:7457|h[Fiery Weapon]|h"), nil)

check("nothing at all", ItemTooltip.ItemIDFromLink(nil), nil)

--------------------------------------------------------------------------------
-- What a tooltip would say
--------------------------------------------------------------------------------

local lines = ItemTooltip:LinesFor(LINEN_CLOTH, nil)
check("a priced item gets one line", #lines, 1)
check("labelled", lines[1][1], "Auction value")
check("with its value", lines[1][2], "<2300>")
check("and is not muted", lines[1][3], nil)

-- Rule 1. Each of these is a different unknown; none of them is a price.
lines = ItemTooltip:LinesFor(SILK_CLOTH, nil)
check("a scanned-but-unsold item is not priced", lines[1][2], "not scanned yet")
assert(lines[1][2] ~= "<0>", "a stored zero must never print as a price")

-- Rule 2. This is sellable, so say which unknown it is.
lines = ItemTooltip:LinesFor(RUNECLOTH, nil)
check("an unscanned sellable item says so", lines[1][2], "not scanned yet")
check("quietly", lines[1][3], true)

-- ...and this is not sellable, so say nothing. Hovering your own gear must not
-- produce a running commentary about the auction house.
check("a soulbound item says nothing", #ItemTooltip:LinesFor(BOUND_SWORD, nil), 0)
check("a quest item says nothing", #ItemTooltip:LinesFor(QUEST_TOKEN, nil), 0)

-- An item the client has not cached at all: no answer either way, so nothing.
check("an uncached item says nothing", #ItemTooltip:LinesFor(123456, nil), 0)

check("no item at all", #ItemTooltip:LinesFor(nil, nil), 0)

--------------------------------------------------------------------------------
-- Old prices are shown, and dated
--------------------------------------------------------------------------------

-- A stale price is still the best anyone has, so it is shown. What makes it
-- safe to act on is knowing how old it is.
lines = ItemTooltip:LinesFor(COPPER_BAR, nil)
check("a stale price is still shown", lines[1][2], "<1500>  (3h ago)")

--------------------------------------------------------------------------------
-- Stacks
--------------------------------------------------------------------------------

lines = ItemTooltip:LinesFor(LINEN_CLOTH, 20)
check("a stack adds a second line", #lines, 2)
check("named for the count", lines[2][1], "Stack of 20")
check("worth the multiple", lines[2][2], ("<%d>"):format(2300 * 20))

check("a single item adds nothing", #ItemTooltip:LinesFor(LINEN_CLOTH, 1), 1)

-- A stack of something with no price has no total worth stating.
check("an unpriced stack stays one line", #ItemTooltip:LinesFor(RUNECLOTH, 20), 1)

--------------------------------------------------------------------------------
-- Rule 3: the same tooltip is only decorated once
--------------------------------------------------------------------------------

-- Three hooks are installed because which one this client fires is unknown.
-- More than one firing is expected; more than one *writing* is the bug.

local tooltip = Tooltip(LINEN_CLOTH)

check("the first hook writes", ItemTooltip:Decorate(tooltip, nil, nil), "valued")
check("one line went on", #tooltip.lines, 1)

check("the second hook does not",
  ItemTooltip:Decorate(tooltip, nil, nil), "duplicate")
check("still one line", #tooltip.lines, 1)

check("nor the third", ItemTooltip:Decorate(tooltip, nil, nil), "duplicate")
check("still one line", #tooltip.lines, 1)

-- The client redraws the same item: the line has to come back, or a tooltip
-- shows a value once and never again.
tooltip:Clear()
check("a redraw is decorated again", ItemTooltip:Decorate(tooltip, nil, nil), "valued")
check("with its line", #tooltip.lines, 1)

-- The tooltip moves on to a different item without being cleared, which is
-- what a fast hover does. Showing the previous item's price would be a wrong
-- number presented as a right one.
tooltip.itemID = COPPER_BAR
check("a new item is decorated", ItemTooltip:Decorate(tooltip, nil, nil), "valued")
check("with the new item's price", tooltip.lines[#tooltip.lines][2], "<1500>  (3h ago)")

--------------------------------------------------------------------------------
-- Rule 4: the stack total arrives late and still lands
--------------------------------------------------------------------------------

-- Every hook available fires after the call that built the tooltip, and only
-- that call knew the bag slot. So the unit value is already written by the
-- time the count can be read, and the stack total is a second append.

tooltip = Tooltip(LINEN_CLOTH)

ItemTooltip:Decorate(tooltip, nil, nil)
check("the value went on without a count", #tooltip.lines, 1)

check("the count lands afterwards", ItemTooltip:AddStackLine(tooltip, 20), true)
check("as a second line", #tooltip.lines, 2)
check("with the stack total", tooltip.lines[2][2], ("<%d>"):format(2300 * 20))

-- ...and only once, however many setters fire.
check("a second count is refused", ItemTooltip:AddStackLine(tooltip, 20), false)
check("still two lines", #tooltip.lines, 2)

-- A client that hands the count over in time writes both at once, and the late
-- append then has nothing to do.
tooltip = Tooltip(LINEN_CLOTH)
ItemTooltip:Decorate(tooltip, nil, 20)
check("both lines at once", #tooltip.lines, 2)
check("no second stack line", ItemTooltip:AddStackLine(tooltip, 20), false)
check("still two lines", #tooltip.lines, 2)

-- A count for a tooltip nothing has decorated is not an invitation to write a
-- stack total on its own.
tooltip = Tooltip(LINEN_CLOTH)
check("an undecorated tooltip is left alone", ItemTooltip:AddStackLine(tooltip, 20), false)
check("with nothing on it", #tooltip.lines, 0)

-- The tooltip has moved on since it was decorated: the count belongs to the
-- item that is gone, and multiplying this item's price by it would be wrong.
tooltip = Tooltip(LINEN_CLOTH)
ItemTooltip:Decorate(tooltip, nil, nil)
tooltip.itemID = COPPER_BAR
check("a count for a different item is refused",
  ItemTooltip:AddStackLine(tooltip, 20), false)
check("with nothing added", #tooltip.lines, 1)

--------------------------------------------------------------------------------
-- The item a tooltip is showing
--------------------------------------------------------------------------------

-- The data a modern post-call is handed says outright which item it is.
check("data wins",
  ItemTooltip:ItemForTooltip(Tooltip(LINEN_CLOTH), { id = COPPER_BAR }), COPPER_BAR)

-- With no data, the link the tooltip is rendering is read.
check("otherwise the link",
  ItemTooltip:ItemForTooltip(Tooltip(LINEN_CLOTH), nil), LINEN_CLOTH)

check("a tooltip showing nothing", ItemTooltip:ItemForTooltip(Tooltip(nil), nil), nil)

--------------------------------------------------------------------------------
-- The setting
--------------------------------------------------------------------------------

check("on by default", ItemTooltip:IsEnabled(), true)

ns.settings.showValueOnItemTooltips = false
check("off when switched off", ItemTooltip:IsEnabled(), false)

tooltip = Tooltip(LINEN_CLOTH)
check("and nothing is written", ItemTooltip:Decorate(tooltip, nil, nil), "quiet")
check("nothing at all", #tooltip.lines, 0)
check("not even a stack total", ItemTooltip:AddStackLine(tooltip, 20), false)

ns.settings.showValueOnItemTooltips = true
check("on when switched on", ItemTooltip:IsEnabled(), true)

--------------------------------------------------------------------------------
-- The lowest posting, beside the market value (2026-09-26)
--------------------------------------------------------------------------------

local RECORDS = {
  [LINEN_CLOTH] = { market = 2300, min = 1900 },
  [COPPER_BAR]  = { market = 1500, min = 1400, ownMin = 1400 },
  [SILK_CLOTH]  = { market = 0 },
}
ns.Prices.Get = function(_, itemID) return RECORDS[itemID] end

lines = ItemTooltip:LinesFor(LINEN_CLOTH, nil)
check("the lowest posting follows the value", lines[2][1], "Lowest posting")
check("at the cheapest listing", lines[2][2], "<1900>")

lines = ItemTooltip:LinesFor(COPPER_BAR, nil)
check("the cheapest one yours says so", lines[2][2], "<1400>  (yours)")

RECORDS[LINEN_CLOTH].min = nil
lines = ItemTooltip:LinesFor(LINEN_CLOTH, nil)
check("nobody listing says so", lines[2][2], "none listed")
check("quietly", lines[2][3], true)
RECORDS[LINEN_CLOTH].min = 1900

lines = ItemTooltip:LinesFor(SILK_CLOTH, nil)
check("an unpriced item gets no lowest line", #lines, 1)

-- A lone listing far below the rest is left out, as the Enchanting pane
-- leaves it out. The real helper is borrowed from Data/Prices.lua, so this
-- reads the book the same way the rest of the addon does.
do
  local module
  local priceNs = {
    NewModule = function() module = {}; return module end,
    Util = {}, RegisterCommand = function() end,
  }
  assert(loadfile(lfs_cwd .. "/Data/Prices.lua"))("Blackthornes_TS", priceNs)
  ns.Prices.LowestListed = module.LowestListed
end

-- As Summarise records a book of 200, 1900, 1900: the 200 is ignored.
RECORDS[LINEN_CLOTH] = { market = 2300, min = 200, rivalMin = 1900, ignoredLow = 200 }
lines = ItemTooltip:LinesFor(LINEN_CLOTH, nil)
check("a lone low listing is left out", lines[2][2], "<1900>")

-- Two low ones are a real price and count.
RECORDS[LINEN_CLOTH] = { market = 2300, min = 200, rivalMin = 200 }
lines = ItemTooltip:LinesFor(LINEN_CLOTH, nil)
check("two low listings count", lines[2][2], "<200>")

RECORDS[LINEN_CLOTH] = { market = 2300, min = 1900 }
ns.Prices.LowestListed = nil

lines = ItemTooltip:LinesFor(LINEN_CLOTH, 20)
check("a stack total comes after it", lines[3][1], "Stack of 20")

tooltip = Tooltip(LINEN_CLOTH)
ItemTooltip:Decorate(tooltip, nil, nil)
check("value and lowest go on together", #tooltip.lines, 2)
check("the late stack total still lands", ItemTooltip:AddStackLine(tooltip, 20), true)
check("as the stack line, not the lowest again", tooltip.lines[3][2], ("<%d>"):format(2300 * 20))

-- How well it sells, from Logic/Demand.lua, after the price lines.
ns.Demand = {
    Get = function(_, itemID)
        if itemID == LINEN_CLOTH then return { level = "low" } end
    end,
    TooltipText = function() return "Low (you sold 1 of 8 listed)" end,
    Color = function() return "loss" end,
}
lines = ItemTooltip:LinesFor(LINEN_CLOTH, nil)
check("demand follows the price", lines[#lines][1], "Demand")
check("saying why", lines[#lines][2], "Low (you sold 1 of 8 listed)")
check("in its colour", lines[#lines].color, "loss")
check("an item with no reading has no demand line", ItemTooltip:LinesFor(SILK_CLOTH, nil)[2] == nil
    or ItemTooltip:LinesFor(SILK_CLOTH, nil)[#ItemTooltip:LinesFor(SILK_CLOTH, nil)][1] ~= "Demand", true)
ns.Demand = nil

-- A sealed writ the player has opened says what came out.
ns.Writs = {
    IsSealed = function(_, itemID) return itemID == LINEN_CLOTH end,
    SealedInfo = function()
        return { opens = 6, worth = 12000, rows = {
            { writ = { name = "Bolt of Silk Cloth" }, count = 3 },
            { writ = { name = "Heavy Leather" }, count = 2 },
        } }
    end,
}
lines = ItemTooltip:LinesFor(LINEN_CLOTH, nil)
local opened
for i, line in ipairs(lines) do
    if line[1] == "You opened 6" then opened = i end
end
check("a sealed writ says how many were opened", opened ~= nil, true)
check("then each writ that came out", lines[opened + 1][1] .. " " .. lines[opened + 1][2], "Bolt of Silk Cloth 3 of 6")
check("and what the writ inside is worth", lines[opened + 3][1], "Writ inside worth about")
check("other items get no sealed lines", #ItemTooltip:LinesFor(SILK_CLOTH, nil) > 0
    and ItemTooltip:LinesFor(SILK_CLOTH, nil)[1][1] ~= "You opened 6", true)
ns.Writs = nil

ns.Prices.Get = nil

-- What you paid on the auction house (a player asked, 2026-11-12): the newest
-- buy each and when, the average with Shift held, nothing never bought.
time = time or os.time
local realTime = time
time = function() return 1000000 end
local summaries = {
    [LINEN_CLOTH] = { each = 875, at = 1000000 - 2 * 3600, average = 910, units = 60, buys = 4 },
    [COPPER_BAR] = { each = 300, at = 1000000 - 3600, average = 300, units = 5, buys = 1 },
}
ns.MethodProfit = { BoughtSummary = function(_, itemID) return summaries[itemID] end }

local function Find(list, label)
    for _, line in ipairs(list) do if line[1] == label then return line end end
end

lines = ItemTooltip:LinesFor(LINEN_CLOTH, nil)
check("bought for says each and when", Find(lines, "Bought for") and Find(lines, "Bought for")[2], "<875> each  (2h ago)")
check("several buys give an average", Find(lines, "Average paid") and Find(lines, "Average paid")[2], "<910>  (60 in 4 buys)")
lines = ItemTooltip:LinesFor(COPPER_BAR, nil)
check("one buy has no average", Find(lines, "Average paid"), nil)
check("but still says what it cost", Find(lines, "Bought for") ~= nil, true)
check("never bought, nothing said", Find(ItemTooltip:LinesFor(SILK_CLOTH, nil), "Bought for"), nil)

-- Shift up: the average waits, and Shift redraws the tooltip for it.
local shiftDown = false
ns.TooltipShift = { Shows = function() return true end, ShiftDown = function() return shiftDown end }
lines = ItemTooltip:LinesFor(LINEN_CLOTH, nil)
check("the average waits for Shift", Find(lines, "Average paid"), nil)
check("and says to hold Shift", lines.held, true)
check("so Shift redraws it", ItemTooltip.boughtHeld, true)
shiftDown = true
lines = ItemTooltip:LinesFor(LINEN_CLOTH, nil)
check("Shift held shows the average", Find(lines, "Average paid") ~= nil, true)

-- The line on Shift: nothing until Shift is held.
ns.TooltipShift = { Shows = function(_, key) return key ~= "bought" end, ShiftDown = function() return false end }
lines = ItemTooltip:LinesFor(LINEN_CLOTH, nil)
check("on Shift, bought for waits", Find(lines, "Bought for"), nil)
check("and is held", lines.held, true)
ns.TooltipShift = nil

ns.settings.tooltipBoughtFor = false
check("turned off, nothing", Find(ItemTooltip:LinesFor(LINEN_CLOTH, nil), "Bought for"), nil)
ns.settings.tooltipBoughtFor = nil
ns.MethodProfit = nil
time = realTime

print("test_itemtooltip: ok")
