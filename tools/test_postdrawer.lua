-- The Tradeskills drawer beside the auction house (UI/PostPanel.lua).
--
-- The owner's mockup (2026-10-13): one drawer the full height of the auction
-- window, Scan and Post Crafted in its header, List all at its foot.
--
-- What must hold:
--   1. Folded, the drawer is its header, so Scan is still in reach.
--   2. The close gem puts it away until the auction house is opened again.
--   3. List all lists the most valuable stack Sell shows, one a click, and
--      says how many are left to list.
--   4. Search all on Buy (2026-10-14) looks up every line the auction house
--      sells at once, with each shortfall, or one a click where the game
--      takes one a search; vendor materials are left out.

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

ns.Theme = {
    sizes = { tiny = 10, small = 11, normal = 12 },
    CreateLabel = function() return Stub() end,
    CreateDivider = function() return Stub() end,
    Unpack = function(key) return key end,
    MeasureText = function(_, text) return #text * 6 end,
}
ns.Widgets = { CreateButton = function() return Stub() end }
ns.Util = { FormatMoney = function(c) return tostring(c) end }
ns.COLORS = { accent = "ffffd100" }

local settings = {}
ns.Config = { Get = function(_, key) return settings[key] end, Set = function(_, key, v) settings[key] = v end }
ns.Collapse = { IsCollapsed = function(key) return settings[key] == true end }

local said, requested
ns.Print = function(text) said = text end
ns.Posting = {
    GetNextPostable = function(_, _, lines)
        for _, line in ipairs(lines or {}) do
            if line.unitPrice and not line.atALoss then return line end
        end
    end,
    GetSummary = function(_, _, lines)
        local count = 0
        for _, line in ipairs(lines or {}) do
            if line.unitPrice and not line.atALoss then count = count + 1 end
        end
        return count, 0
    end,
    CanPost = function() return true end,
    Request = function(_, itemID, quantity, price) requested = { itemID, quantity, price } end,
}

local PostPanel
local realNew = ns.NewModule
ns.NewModule = function(name) local m = realNew(name); PostPanel = m; return m end
assert(loadfile(lfs_cwd .. "/UI/PostPanel.lua"))("Blackthornes_TS", ns)

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

-- 1
local AH = { GetTop = function() return 1091 end, GetBottom = function() return 551 end,
    GetRight = function() return 851 end }
ns.UI = { FindAuctionFrame = function() return AH end }
settings.postPanelCollapsed = false
check("open: the auction window's height", PostPanel:TargetHeight() == 540)
settings.postPanelCollapsed = true
check("folded: the header, Scan strip and all", PostPanel:TargetHeight() == PostPanel.FOLDED_HEIGHT)
check("which is taller than the Scan strip itself", PostPanel.FOLDED_HEIGHT > 44)
settings.postPanelCollapsed = false

-- 2
local shown = true
PostPanel.frame = Stub({
    IsShown = function() return shown end,
    Show = function() shown = true end,
    Hide = function() shown = false end,
})
-- A buy counted (AHBuys) builds the Buy list again at once, not after its
-- couple of seconds: bought items go to the mail and nothing else redraws it.
do
    local refreshed = 0
    local realRefresh = PostPanel.Refresh
    PostPanel.Refresh = function() refreshed = refreshed + 1 end
    PostPanel.view, PostPanel.shoppingAt = "buy", 12345
    PostPanel:OnPurchase()
    check("a buy forgets the kept shopping lines", PostPanel.shoppingAt == nil)
    check("and redraws the Buy list while it shows", refreshed == 1)
    PostPanel.view, PostPanel.shoppingAt = "sell", 12345
    PostPanel:OnPurchase()
    check("on Sell it only forgets them", PostPanel.shoppingAt == nil and refreshed == 1)
    PostPanel.Refresh = realRefresh
    PostPanel.view, PostPanel.shoppingAt = nil, nil
end

PostPanel.attached = true
PostPanel:CloseForVisit()
check("the close gem puts the drawer away", shown == false)
PostPanel:Redock()
check("and it stays away while the auction house is open", shown == false)
PostPanel:Hide()
check("leaving the auction house forgets it", PostPanel.closedThisVisit == false)

-- 3
local button = Stub({ SetText = function(self, text) self.text = text end,
    SetEnabledState = function(self, on) self.enabled = on end })
PostPanel.listAll = button
local lines = {
    { itemID = 7, atALoss = true, unitPrice = 50, postQuantity = 1 },
    { itemID = 8, unitPrice = 900, postQuantity = 3 },
    { itemID = 9, unitPrice = 400, postQuantity = 2 },
}
PostPanel:UpdateListAll(lines)
check("List all counts what it can list", button.text == "List Next - 2 remaining")
check("and can be clicked", button.enabled == true)

PostPanel.shownLines = lines
PostPanel:ListNext()
check("a click lists the most valuable stack it can", requested and requested[1] == 8 and requested[2] == 3)

-- The hover previews the next stack.
local tip = { lines = {} }
function tip:SetText(text) self.lines = { text } end
function tip:AddLine(text) self.lines[#self.lines + 1] = text end
function tip:AddDoubleLine(left, right) self.lines[#self.lines + 1] = left .. "=" .. right end
local function Has(text)
    for _, line in ipairs(tip.lines) do if line == text then return true end end
    return false
end
ns.Util.GetItemLabel = function(id) return "Item " .. id end
PostPanel.shownLines = lines
PostPanel:UpdateListAll(lines)
check("the hover is drawn", PostPanel.ListNextTooltip(button, tip) == true)
check("it names the next stack", Has("Next to list") and Has("Item 8"))
check("how many at what price", Has("3 at 900 each"))
check("its total", Has("Total=2700"))
check("and what comes after", Has("Then: Item 9 x2"))

-- Still hovered after a click: the hover is drawn again for the next stack,
-- once, and never for a tooltip that belongs to something else.
local entered = 0
button.IsMouseOver = function() return true end
button.GetScript = function(_, name)
    if name == "OnEnter" then return function() entered = entered + 1 end end
end
local owner = button
GameTooltip = { IsOwned = function(_, frame) return frame == owner end }
PostPanel:UpdateListAll(lines)
check("an unchanged next stack leaves the hover alone", entered == 0)
local listed = table.remove(lines, 2)
PostPanel:UpdateListAll(lines)
check("a new next stack draws the hover again", entered == 1)
PostPanel:UpdateListAll(lines)
check("but only once", entered == 1)
owner = nil
table.insert(lines, 2, listed)
PostPanel:UpdateListAll(lines)
check("someone else's tooltip is left alone", entered == 1)
GameTooltip, button.IsMouseOver, button.GetScript = nil, nil, nil

ns.Posting.WouldCheckAll = function() return true end
PostPanel:UpdateListAll(lines)
check("a click that checks prices says so", button.text == "Check Prices - 2 to list")
PostPanel.ListNextTooltip(button, tip)
check("and its hover too", Has("Check prices first"))
tip.lines = {}
PostPanel.ListNextTooltip(button, tip, "Waiting: busy.")
check("a wait goes first", tip.lines[1] == "Waiting: busy.")
ns.Posting.WouldCheckAll = nil
PostPanel:UpdateListAll(lines)
check("back to List Next", button.text == "List Next - 2 remaining")

PostPanel:UpdateListAll({})
check("nothing to list: no count", button.text == "List Next")
check("no preview with nothing to list", PostPanel.ListNextTooltip(button, tip) == false)
check("and greyed", button.enabled == false)

requested = nil
PostPanel.shownLines = {}
PostPanel:ListNext()
check("a click with nothing to list lists nothing", requested == nil and said ~= nil)

-- 4
local shopping = {
    { itemID = 20, shortfall = 6 },
    { itemID = 21, shortfall = 0 },
    { itemID = 22, shortfall = 4, fromVendor = true },
    { itemID = 23, shortfall = 9, fromVendor = true, vendorLimited = true },
    { itemID = 24, shortfall = 2 },
}
PostPanel.ShoppingLines = function() return shopping end
local search = Stub({ SetText = function(self, text) self.text = text end,
    SetEnabledState = function(self, on) self.enabled = on end })
PostPanel.searchAll = search
PostPanel:UpdateSearchAll()
check("Search all counts what the auction house can sell", search.text == "Search all 3" and search.enabled == true)

local many, single = nil, {}
ns.ShoppingLists = { SearchMany = function(_, ids, counts) many = { ids = ids, counts = counts }; return true end }
ns.UI.SearchAuctionHouse = function(_, id, count) single[#single + 1] = { id, count }; return true end
PostPanel:SearchAll()
check("all at once, vendor-only left out", many and #many.ids == 3 and many.ids[1] == 20
    and many.ids[2] == 23 and many.ids[3] == 24 and #single == 0)
check("each with its shortfall", many.counts[20] == 6 and many.counts[23] == 9 and many.counts[24] == 2)

ns.ShoppingLists.SearchMany = function() return false, "single" end
PostPanel:SearchAll()
check("one a search: the first, then Next", single[1][1] == 20 and single[1][2] == 6 and search.text == "Next 2/3")
PostPanel:SearchAll()
PostPanel:SearchAll()
check("Next walks the rest and ends", #single == 3 and single[3][1] == 24 and search.text == "Search all 3")

shopping = {}
said = nil
PostPanel:SearchAll()
check("nothing to look for: says so", said ~= nil and #single == 3)
PostPanel:UpdateSearchAll()
check("and greyed", search.text == "Search all" and search.enabled == false)

print(("\n%d check(s) passed\n"):format(checks))
