-- Era's buy plan, one item after another (UI/PostPanel.lua,
-- UI/LegacyBuyView.lua, UI/Main.lua).
--
-- The owner said build it (2026-10-29):
--   1. A plan that is done offers the next Buy line still to buy: list
--      order from the one after it, then from the top, never a vendor
--      material or the same item.
--   2. On Era with the drawer up, the AH buttons on the Queue panel, the
--      Gather tab and the Lists open that item's plan on Buy. Off Era, or
--      with the drawer away, they search as before.
--   3. On Era the search buttons' hover only says what they do.

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.Print, ns.Debug, ns.Warn = function() end, function() end, function() end
ns.RegisterEvent = function() return true end

local function Stub(fields)
    local frame = fields or {}
    return setmetatable(frame, { __index = function(self, key)
        local noop = function() end
        rawset(self, key, noop)
        return noop
    end })
end
CreateFrame = function() return Stub() end
C_Timer = { After = function() end }
GetTime = function() return 100 end

ns.Theme = { sizes = { tiny = 10, small = 11, normal = 12 },
    CreateLabel = function() return Stub() end, CreateDivider = function() return Stub() end,
    Unpack = function(key) return key end, MeasureText = function(_, text) return #text * 6 end }
ns.Widgets = { CreateButton = function() return Stub() end }
ns.Util = { FormatMoney = function(c) return tostring(c) end }
ns.COLORS = { accent = "ffffd100" }
ns.Config = { Get = function() return nil end, Set = function() end }
ns.Collapse = { IsCollapsed = function() return false end }

local PostPanel
do
    local realNew = ns.NewModule
    ns.NewModule = function(name) local m = realNew(name); PostPanel = m; return m end
    assert(loadfile(lfs_cwd .. "/UI/PostPanel.lua"))("Blackthornes_TS", ns)
    ns.NewModule = realNew
end

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

-- 1
local lines = {
    { itemID = 1, shortfall = 4 },
    { itemID = 2, shortfall = 0 },
    { itemID = 3, shortfall = 5, fromVendor = true },
    { itemID = 4, shortfall = 2 },
}
PostPanel.ShoppingLines = function() return lines end
check("after the first, the next still short", PostPanel:NextBuyLine(1).itemID == 4)
check("skips a line with all it needs and a vendor material", PostPanel:NextBuyLine(2).itemID == 4)
check("after the last, back to the top", PostPanel:NextBuyLine(4).itemID == 1)
lines = { { itemID = 1, shortfall = 4 } }
check("nothing else to buy, no next", PostPanel:NextBuyLine(1) == nil)

-- 2
local era, opened, views = true, {}, {}
ns.LegacyScan = { Applies = function() return era end }
ns.LegacyBuyView = { Applies = function() return era end }
ns.LegacyBuy = {
    IsOpenFor = function(_, id) return opened.id == id end,
    Open = function(_, id, need) opened = { id = id, need = need }; return true end,
}
local shown = true
PostPanel.frame = Stub({ IsShown = function() return shown end })
PostPanel.view = "sell"
PostPanel.SetView = function(self, view) self.view = view; views[#views + 1] = view end
PostPanel.Refresh = function() end

check("Era, drawer up: the plan opens", PostPanel:OpenBuyPlan(7, 3) == true)
check("for that item and how many", opened.id == 7 and opened.need == 3)
check("on the Buy view", PostPanel.view == "buy")
check("again for the same item: kept open", PostPanel:OpenBuyPlan(7, 3) == true and #views == 1)
shown = false
check("drawer away: no plan", PostPanel:OpenBuyPlan(8, 1) == false)
shown, era = true, false
check("off Era: no plan", PostPanel:OpenBuyPlan(8, 1) == false)

-- UI:SearchOrPlan falls back to the usual search.
local UI = { }
ns.Scanner = { isAuctionHouseOpen = true }
local Main = assert(io.open(lfs_cwd .. "/UI/Main.lua")):read("*a")
local body = Main:match("(function UI:SearchOrPlan.-\nend)\n")
check("SearchOrPlan is in Main.lua", body ~= nil)
local searched
UI.SearchAuctionHouse = function(_, id) searched = id; return true end
assert((loadstring or load)("local UI, ns = ...\n" .. body))(UI, ns)
era, opened = true, {}
searched = nil
UI:SearchOrPlan(9, 2)
check("Era: the plan, no Browse search", opened.id == 9 and searched == nil)
era = false
UI:SearchOrPlan(10, 2)
check("off Era: the usual search", searched == 10)
era = true
ns.Scanner.isScanning = true
opened, searched = {}, nil
UI:SearchOrPlan(11, 2)
check("mid-scan: left to the usual search's guard", opened.id == nil and searched == 11)
ns.Scanner.isScanning = false

-- 3
era = true
check("Era: the short hover", PostPanel.SearchTip("long") == "Searches the auction house.")
era = false
check("off Era: as it was", PostPanel.SearchTip("long") == "long")

print(("\nbuy plan next: %d checks passed"):format(checks))
