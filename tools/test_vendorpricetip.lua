-- The vendor price as the last line of an item's tooltip (UI/VendorPriceTip.lua,
-- asked 2026-10-27).
--
--   1. One item's vendor price goes on, in coin, once per draw.
--   2. Nothing for an item a vendor won't buy, or with the value lines off or
--      held for Shift.
--   3. A bag slot waits for the SetBagItem post-hook, so the line lands after
--      the stack line; anything else takes it from the item hook.
--   4. A cleared tooltip gets the line again on its next draw.

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.COLORS = { accent = "ffc8a44d" }
ns.RegisterEvent = function() end

local SELL = { [2447] = 1, [4306] = 150 }
ns.Util = {
  GetVendorSellPrice = function(id) return SELL[id] end,
  FormatMoney = function(copper) return ("<%d>"):format(copper) end,
}

local enabled, shows = true, true
local shownItem
ns.ItemTooltip = {
  IsEnabled = function() return enabled end,
  Shows = function() return shows end,
  ItemForTooltip = function() return shownItem end,
}

local BAG_SLOT = { [0] = { [3] = 2447 } }
C_Container = {
  GetContainerItemID = function(bag, slot) return BAG_SLOT[bag] and BAG_SLOT[bag][slot] end,
}

local function Tooltip()
  local t = { lines = {} }
  function t:AddDoubleLine(left, right) self.lines[#self.lines + 1] = left .. "=" .. right end
  function t:Show() end
  function t:GetOwner() return self.owner end
  return t
end

local hooked = {}
hooksecurefunc = function(object, name, fn) hooked[name] = fn end
GameTooltip = Tooltip()
GameTooltip.SetBagItem = function() end

local VendorPriceTip
do
  local realNew = ns.NewModule
  ns.NewModule = function(name) local m = realNew(name); VendorPriceTip = m; return m end
  assert(loadfile(lfs_cwd .. "/UI/VendorPriceTip.lua"))("Blackthornes_TS", ns)
  ns.NewModule = realNew
end

local function check(label, got, want)
  if got ~= want then
    error(("%s: got %s, want %s"):format(label, tostring(got), tostring(want)), 2)
  end
end

VendorPriceTip:Install()
check("bag hook in", VendorPriceTip.bagHooked, true)

-- 1. A link: the item hook puts it on, once.
local link = Tooltip()
shownItem = 4306
VendorPriceTip:OnItem(link)
VendorPriceTip:OnItem(link)
check("one line", #link.lines, 1)
check("the price", link.lines[1], "Vendor price=<150>")

-- 4. Cleared, it goes on again.
VendorPriceTip.Forget(link)
VendorPriceTip:OnItem(link)
check("again after clear", #link.lines, 2)

-- 2. No vendor price, value lines off, held for Shift.
local none = Tooltip()
shownItem = 99999
VendorPriceTip:OnItem(none)
check("no vendor price", #none.lines, 0)
shownItem = 4306
enabled = false
VendorPriceTip:OnItem(none)
check("value lines off", #none.lines, 0)
enabled, shows = true, false
VendorPriceTip:OnItem(none)
check("held for Shift", #none.lines, 0)
shows = true

-- 3. A bag slot: the item hook waits, the bag hook puts it on, after
-- whatever came between.
local parent = { GetID = function() return 0 end }
GameTooltip.owner = { GetParent = function() return parent end, GetID = function() return 3 end }
shownItem = 2447
VendorPriceTip:OnItem(GameTooltip)
check("bag slot waits", #GameTooltip.lines, 0)
GameTooltip:AddDoubleLine("Stack of 3", "42c")
hooked.SetBagItem(GameTooltip, 0, 3)
check("then the line", #GameTooltip.lines, 2)
check("last", GameTooltip.lines[2], "Vendor price=<1>")
hooked.SetBagItem(GameTooltip, 0, 3)
check("not twice", #GameTooltip.lines, 2)

print("  ok    vendor price tooltip line")
