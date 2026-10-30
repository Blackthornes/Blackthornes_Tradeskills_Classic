-- The Vendor Flips tab: items on the auction house listed for less than a
-- vendor pays for them (2026-09-28).
--
-- What this pins down:
--   * profit is the vendor price less the cheapest listing from someone
--     else, per item, with no auction house cut;
--   * a lone low listing that pricing ignores is still the price to buy at;
--   * his own listings, items worth more than a vendor pays, items a vendor
--     will not buy, and listings the last scan did not see are left out;
--   * the vendor price comes from the saved item facts: an item the client
--     has let go of stays listed and is not read again, and items saved
--     before sell prices were kept are read once more;
--   * nothing new is read while the auction house is open;
--   * the Minimum profit and margin from Settings hold rows back;
--   * the tab draws the rows, rebuilds only when prices change, and the scan
--     message names the best flip with a sound.

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
local commands = {}
ns.RegisterCommand = function(name, _, fn) commands[name] = fn end
local handlers = {}
ns.RegisterEvent = function(_, event, fn) handlers[event] = handlers[event] or {}; table.insert(handlers[event], fn) end

local printed = {}
ns.Print = function(text) printed[#printed + 1] = text end
ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end

-- Put back at the end: every suite shares one Lua runtime.
local saved = { C_Item = C_Item, GetTime = GetTime, CreateFrame = CreateFrame,
                PlaySound = PlaySound, SOUNDKIT = SOUNDKIT, GameTooltip = GameTooltip,
                C_Timer = C_Timer, C_TooltipInfo = C_TooltipInfo }

CreateFrame = function()
    local frame = {}
    for _, name in ipairs({ "SetScript", "Show", "Hide", "SetPoint", "SetSize" }) do
        frame[name] = function() end
    end
    return frame
end

GetTime = function() return 1 end
time = time or os.time

-- itemID -> quality, vendor sell price
local items = {
    [3001] = { 1, 500 },    -- listed at 200: a 300 flip
    [3002] = { 1, 500 },    -- only his own listing
    [3003] = { 2, 1000 },   -- a lone low listing at 100
    [3004] = { 1, 50 },     -- listed above what a vendor pays
    [3005] = { 1, 0 },      -- a vendor will not buy it
    [3006] = { 0, 30 },     -- a grey at 29: one copper
}

local reads, loads, evicted = {}, {}, {}

C_Item = {
    GetItemInfo = function(itemID)
        reads[itemID] = (reads[itemID] or 0) + 1
        local item = items[itemID]
        if not item or evicted[itemID] then return nil end
        return "item" .. itemID, nil, item[1], 10, 1, "Trade Goods", "Cloth", 20,
            "", 1, item[2], 7, 1, 2
    end,
    GetItemInfoInstant = function(itemID)
        return itemID, "Trade Goods", "Cloth", "", 1, 7, 1
    end,
    RequestLoadItemDataByID = function(itemID) loads[itemID] = (loads[itemID] or 0) + 1 end,
}

assert(loadfile(lfs_cwd .. "/Core/Util.lua"))("Blackthornes_TS", ns)

local records = {
    [3001] = { rivalMin = 200, quantity = 12, ladder = { 200, 4, 260, 8 } },
    [3002] = { ownMin = 100, quantity = 1 },
    [3003] = { rivalMin = 900, ignoredLow = 100, quantity = 2 },
    [3004] = { rivalMin = 80, quantity = 5 },
    [3005] = { rivalMin = 1, quantity = 5 },
    [3006] = { rivalMin = 29, quantity = 1 },
}

local config = { auctionCut = 0.05, minProfit = 0, minMarginPercent = 0 }

ns.Config = {
    Get = function(_, key) return config[key] end,
    GetCharacterKey = function() return "Tester-Realm" end,
}
ns.Prices = {
    GetTable = function() return records end,
    GetValue = function() return nil end,
    GetAge = function() return 600 end,
    IsStale = function(_, itemID) return itemID == 3003 end,
    Count = function() return 6 end,
    -- As Data/Prices.lua counts it: the book's steps at the price or less.
    CountAtOrBelow = function(record, price)
        if type(record.ladder) ~= "table" then return nil end
        local count = 0
        for i = 1, #record.ladder, 2 do
            if record.ladder[i] <= price then count = count + record.ladder[i + 1] end
        end
        return count
    end,
}
ns.Recipes = {
    GetCharacterName = function(_, key) return (key:match("^([^-]+)")) end,
}

ns.db = { characters = {} }

assert(loadfile(lfs_cwd .. "/Logic/Disenchant.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/VendorFlips.lua"))("Blackthornes_TS", ns)

local VendorFlips = ns.VendorFlips

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

local function Find(rows, itemID)
    for _, row in ipairs(rows) do
        if row.itemID == itemID then return row end
    end
end

print("\nwhich auctions are listed")

local rows = VendorFlips:GetAuctionRows()

local first = Find(rows, 3001)
check("an item under vendor price is listed", first ~= nil)
check("bought at the cheapest rival listing", first.buy == 200)
check("a vendor pays 500", first.vendor == 500)
check("profit is 500 - 200 = 300, no auction cut", first.gain == 300)
check("margin is profit over the buy price", math.abs(first.margin - 1.5) < 1e-9)
check("it says how many are listed", first.listed == 12)
check("and how many at the price it is bought at", first.qty == 4)

check("his own listing is not a flip", Find(rows, 3002) == nil)

local lone = Find(rows, 3003)
check("a lone low listing is the one to buy", lone and lone.buy == 100 and lone.loneLow and lone.gain == 900)
check("and an old scan is marked stale", lone.stale == true)
check("with no book read, no count", lone.qty == nil)

check("an item over vendor price is left out", Find(rows, 3004) == nil)
check("an item a vendor will not buy is left out", Find(rows, 3005) == nil)
check("a grey one copper under vendor counts", Find(rows, 3006) and Find(rows, 3006).gain == 1)

check("best profit first", rows[1].itemID == 3003 and rows[2].itemID == 3001)

print("\nonly deals, and the minimums from Settings")

local deals, hidden = VendorFlips:GetAuctionRows({ profitableOnly = true })
check("nothing held back with no minimums", #deals == 3 and hidden == 0)

config.minProfit = 50
deals, hidden = VendorFlips:GetAuctionRows({ profitableOnly = true })
check("Minimum profit holds the one copper grey back", Find(deals, 3006) == nil)
check("the others clear it", Find(deals, 3001) ~= nil and Find(deals, 3003) ~= nil)
check("and it says how many were held back", hidden == 1)
config.minProfit = 0

config.minMarginPercent = 200
deals = VendorFlips:GetAuctionRows({ profitableOnly = true })
check("Minimum margin holds the 150% flip back", Find(deals, 3001) == nil)
check("the 900% one clears it", Find(deals, 3003) ~= nil)
config.minMarginPercent = 0

print("\nonly what the last scan saw")

ns.db.lastFullScan = 1000
records[3001].seen = 999
check("a listing the last scan did not see is not a flip", Find(VendorFlips:GetAuctionRows(), 3001) == nil)
records[3001].seen = 1200
check("one a later search saw is", Find(VendorFlips:GetAuctionRows(), 3001) ~= nil)
records[3001].seen, ns.db.lastFullScan = nil, nil

-- On a big auction house every sweep stops at the page limit and never gets
-- a full scan stamp. That sweep still decides what counts as seen.
ns.Prices.GetLastScan = function() return 1000, true end
records[3001].seen = 999
check("a listing a capped sweep did not see is not a flip", Find(VendorFlips:GetAuctionRows(), 3001) == nil)
records[3001].seen = 1200
check("one it saw is", Find(VendorFlips:GetAuctionRows(), 3001) ~= nil)
records[3001].seen, ns.Prices.GetLastScan = nil, nil

print("\nvendor prices come from the saved item facts")

check("the sell price is kept in the saved data", ns.db.itemFacts[3001] and ns.db.itemFacts[3001].v == 500)
check("a vendor that buys nothing is kept as 0", ns.db.itemFacts[3005].v == 0)

evicted[3001] = true
reads = {}
for _ = 1, 3 do VendorFlips:GetAuctionRows() end
check("the item stays listed after the client lets it go", Find(VendorFlips:GetAuctionRows(), 3001) ~= nil)
check("and is not read from the client again", reads[3001] == nil)
evicted[3001] = nil

-- Items the Disenchanting tab remembered before sell prices were kept.
ns.db.itemFacts[3001] = { n = "item3001", q = 1, l = 10, c = 7, e = "" }
C_Item.IsItemDataCachedByID = function() return true end
check("an item saved without a sell price is read again", Find(VendorFlips:GetAuctionRows(), 3001) ~= nil)
check("and now has it", ns.db.itemFacts[3001].v == 500)
C_Item.IsItemDataCachedByID = nil

check("the disenchant facts still read the same", ns.Disenchant:GetItemFacts(3001).quality == 1)

print("\nthe tooltip's sell price wins over the item info's")

-- Forever changed some sell prices from Classic's and only the tooltip has
-- the new one: Greater Magic Wand's item info says 15s 35c, its tooltip 1c
-- (2026-10-03). It sat on the tab as a 1435% flip.
local tooltipPrices, tooltipReads = { [3001] = 1 }, {}
C_TooltipInfo = {
    GetItemByID = function(itemID)
        tooltipReads[itemID] = (tooltipReads[itemID] or 0) + 1
        if not items[itemID] then return nil end
        local lines = { { type = 0, leftText = "item" .. itemID } }
        if tooltipPrices[itemID] then
            lines[#lines + 1] = { type = 11, price = tooltipPrices[itemID] }
        end
        return { id = itemID, lines = lines }
    end,
}
C_Item.IsItemDataCachedByID = function() return true end

-- Saved before the tooltip was read: the Classic price, no vt.
ns.db.itemFacts[3001] = { n = "item3001", q = 1, l = 10, c = 7, e = "", v = 500 }
check("an item priced before the tooltip was read is read again and drops off",
    Find(VendorFlips:GetAuctionRows(), 3001) == nil)
check("its saved price is now the tooltip's 1c", ns.db.itemFacts[3001].v == 1 and ns.db.itemFacts[3001].vt)
check("its other facts are kept", ns.Disenchant:GetItemFacts(3001).quality == 1)
check("an item whose tooltip agrees is still a flip", Find(VendorFlips:GetAuctionRows(), 3003) ~= nil)

tooltipReads = {}
for _ = 1, 3 do VendorFlips:GetAuctionRows() end
check("the tooltip is read once, not on every redraw", tooltipReads[3001] == nil and tooltipReads[3003] == nil)

-- An item whose tooltip shows no sell price keeps the item info's.
ns.db.itemFacts[3004] = nil
items[3004][2] = 50
check("no sell price line keeps the item info's price", ns.Disenchant:GetSellPrice(3004) == 50)

ns.Util._ForgetItemMemo()
check("the shared vendor price reads the tooltip too", ns.Util.GetVendorSellPrice(3001) == 1)
check("and keeps the item info's when the tooltip shows none", ns.Util.GetVendorSellPrice(3004) == 50)

-- Early 10.0 builds hand line fields over as an args list.
C_TooltipInfo.GetItemByID = function()
    return { lines = { { args = { { field = "type", intVal = 11 }, { field = "price", intVal = 7 } } } } }
end
check("an args-list tooltip line is read", ns.Util.GetTooltipSellPrice(3001) == 7)

printed = {}
commands.sellprice("3001")
check("/bts sellprice says both prices", printed[1] and printed[1]:find("item info", 1, true)
    and printed[1]:find("tooltip", 1, true))

ns.Util._ForgetItemMemo()
C_TooltipInfo, C_Item.IsItemDataCachedByID = nil, nil
ns.db.itemFacts[3001] = nil
ns.Disenchant:_ForgetItems()

print("\nnothing new is read while the auction house is open")

ns.Disenchant:_ForgetItems()
VendorFlips:GetAuctionRows()          -- the known items, read while it is shut
local knownCount = #VendorFlips:GetAuctionRows()

ns.Scanner = { isAuctionHouseOpen = true }
items[3007] = { 1, 900 }
records[3007] = { rivalMin = 10, quantity = 1 }
loads, reads = {}, {}
local openRows, _, pending = VendorFlips:GetAuctionRows()
check("items already known still list at the auction house", #openRows == knownCount)
check("a new item is not read or fetched while it is open", reads[3007] == nil and loads[3007] == nil)
check("and is counted as waiting", pending == 1)

ns.Scanner.isAuctionHouseOpen = false
check("it is listed once the auction house closes", Find(VendorFlips:GetAuctionRows(), 3007) ~= nil)
records[3007], items[3007] = nil, nil
ns.Scanner = nil

print("\n/bts vendordeals")

printed = {}
commands.vendordeals()
local said = table.concat(printed, "\n")
check("it says when the last scan was", said:find("last scan", 1, true) ~= nil)
check("and what a fresh build would show", said:find("built fresh now", 1, true) ~= nil)
check("and what a vendor pays for each", said:find("vendor pays", 1, true) ~= nil)

print("\nthe scan message")

local chimed
SOUNDKIT = { LOOT_WINDOW_COIN_SOUND = 7, UI_EPICLOOT_TOAST = 1 }
PlaySound = function(kit) chimed = kit end

printed = {}
local count = VendorFlips:AnnounceDeals()
check("it counts the flips", count == 3)
check("it names the best one", printed[1] and printed[1]:find("Vendor flips", 1, true)
    and printed[1]:find("item3003", 1, true))
check("with the sound of coins", chimed == 7)

-- Settings: Sound when a scan finishes, turned off. The message still shows.
config.scanSounds = false
printed, chimed = {}, nil
VendorFlips:AnnounceDeals()
check("with scan sounds off, the message and no sound", #printed == 1 and chimed == nil)
config.scanSounds = nil

local backup = records
records = { [3004] = { rivalMin = 80 } }
printed, chimed = {}, nil
check("no flips, no message", VendorFlips:AnnounceDeals() == 0 and #printed == 0 and chimed == nil)
records = backup

--------------------------------------------------------------------------------
-- The tab
--------------------------------------------------------------------------------

print("\nthe Deals tab, for vendor flips")

local function Stub(fields)
    local frame = fields or {}
    frame.IsVisible = frame.IsVisible or function() return true end
    return setmetatable(frame, { __index = function(self, key)
        local noop = function() end
        rawset(self, key, noop)
        return noop
    end })
end

local function Label()
    return Stub({
        text = "",
        SetText = function(self, value) self.text = tostring(value) end,
        GetText = function(self) return self.text end,
        SetTextColor = function(self, a) self.color = a end,
        SetShown = function(self, value) self.shown = value end,
    })
end

CreateFrame = function() return Stub() end
C_Timer = { After = function() end }
GameTooltip = Stub()

local bars, labels = {}, {}
ns.Theme = {
    SetRowName = function(label, text) label:SetText(text) end,
    SetItemNameColor = function() return false end,
    CreateLabel = function()
        local label = Label()
        labels[#labels + 1] = label
        return label
    end,
    CreatePanel = function() return Stub() end,
    CreateDivider = function() return Stub() end,
    Unpack = function(key) return key end,
    ProfitColor = function(value) return (value or 0) >= 0 and "profit" or "loss" end,
    AccentStripe = function() return Stub() end,
    CreateItemIcon = function() return Stub() end,
    SetItemIcon = function() end,
    CreateHeading = function() return Stub() end,
    CreateBar = function()
        local bar = Stub({ track = Stub(), Set = function(self, value) self.value = value end })
        bars[#bars + 1] = bar
        return bar
    end,
    -- Nothing here can be measured, so every coin and the full wording.
    SetMoneyText = function(label, copper, opts) label:SetText(ns.Util.FormatMoney(copper, opts)) end,
    FitText = function(label, texts) label:SetText(texts[1]); return texts[1] end,
}

local checkboxes, lists, dropdowns = {}, {}, {}
local searched
local pages = {}
ns.Widgets = {
    CreateTabStrip = function(_, tabs, onSelect)
        local options = {}
        for index, tab in ipairs(tabs) do options[index] = { text = tab.text, value = tab.key } end
        local strip = Stub({ options = options, onSelect = onSelect,
            Select = function(self, key) self.value = key end })
        pages[#pages + 1] = strip
        return strip
    end,
    CreateDropdown = function(_, options, onSelect, opts)
        local dropdown = Stub({ options = options, onSelect = onSelect, opts = opts })
        dropdowns[#dropdowns + 1] = dropdown
        return dropdown
    end,
    CreateSearchBox = function(_, _, onChange) searched = onChange; return Stub() end,
    CreateCheckbox = function(_, text, onToggle) local box = Stub({ onToggle = onToggle }); checkboxes[text] = box; return box end,
    CreateButton = function() return Stub() end,
    ShowItemTooltip = function() return true end,
    CreateScrollList = function(_, opts)
        local list = Stub({ opts = opts, SetData = function(self, data) self.data = data end,
            -- Read raw: a stub answers any other key with a function.
            ScrollToTop = function(self) self.toTop = (rawget(self, "toTop") or 0) + 1 end })
        lists[#lists + 1] = list
        return list
    end,
}

local sent = {}
ns.Scanner = { isAuctionHouseOpen = true, QueueBrowseQuery = function(_, text) sent[#sent + 1] = text end }

local tabs = {}
ns.UI = Stub({
    RegisterTab = function(_, tab) tabs[tab.key] = tab end,
    SearchAuctionHouse = function(_, itemID) sent[#sent + 1] = "item" .. itemID; return true end,
})

assert(loadfile(lfs_cwd .. "/UI/Columns.lua"))("Blackthornes_TS", ns)

ns.DEALS_FLIPS = true  -- the flips, put away for now, are still tested
assert(loadfile(lfs_cwd .. "/UI/Tab_Deals.lua"))("Blackthornes_TS", ns)

local tab = tabs.deals
check("vendor flips are on the Deals tab", tab and tab.text == "Deals")

tab.build(Stub())

-- Sell to: Vendor only, as the Vendor Flips tab was.
local sellTo = dropdowns[1]
check("the Sell to menu takes more than one way", sellTo and sellTo.opts and sellTo.opts.multi == true)
-- Disenchanting went back to its own tab (2026-10-08): only these two.
check("it offers the auction house and a vendor, not disenchanting", #sellTo.options == 2
    and sellTo.options[1].value == "auction" and sellTo.options[2].value == "vendor")
check("the box says All with both ticked", sellTo.opts.summary({ auction = true, vendor = true })
    == "Sell to: All")
check("and names the way otherwise", sellTo.opts.summary({ vendor = true })
    == "Sell to: Vendor")
sellTo.onSelect({ vendor = true })

local list = lists[#lists]
check("the flips are listed", list.data and #list.data == 3 and Find(list.data, 3001) ~= nil)

local row = Stub()
list.opts.createRow(row)
list.opts.updateRow(row, Find(list.data, 3001))

-- Right to left: PROFIT, MARGIN, GETS, BUY, QTY, AGE, VIA.
check("PROFIT shows the gain in green", row.cells[1].text ~= "" and row.cells[1].color == "profit")
check("MARGIN shows 150%", row.cells[2].text == "150%")
check("GETS and BUY show prices", row.cells[3].text ~= "" and row.cells[4].text ~= "")
check("QTY says how many at the buy price", row.cells[5].text == "4" and row.cells[5].color == "text")
check("VIA says Vendor", row.cells[7].text == "Vendor")
local loneRow = Stub()
list.opts.createRow(loneRow)
list.opts.updateRow(loneRow, Find(list.data, 3003))
check("QTY with no book read is a dash", loneRow.cells[5].text == "--")

list.opts.onClick(Find(list.data, 3001), 1, "LeftButton")
check("picking a row fills the profit bar", bars[1] and math.abs(bars[1].value - 0.6) < 1e-9)

list.opts.menu(Find(list.data, 3003))[1].run()
check("right-click's menu searches the auction house for it first", sent[#sent] == "item3003")

--- The detail pane's note on where the buy price came from.
local function Note()
    for _, label in ipairs(labels) do
        if label.text:find("^The buy price is") then return label.text end
    end
    return ""
end

local function Showing(text)
    for _, label in ipairs(labels) do
        if label.text == text then return true end
    end
    return false
end

check("a lone low listing says so, in words short enough to fit", Showing("Buy for (lone low)"))
check("the note gives the scan's age", Note():find("(10m ago)", 1, true) ~= nil)
check("and that it may have sold", Note():find("may have sold", 1, true) ~= nil)

-- The list is kept for hours; the age is read when the row is picked.
ns.Prices.GetAge = function() return 7200 end
list.opts.onClick(Find(list.data, 3003), 1, "LeftButton")
check("picked again later, the note's age is read again", Note():find("(2h ago)", 1, true) ~= nil)
ns.Prices.GetAge = function() return 600 end

-- A new search or filter is a different list, so it starts at the top.
local tops = rawget(list, "toTop") or 0
searched("item")
check("a new search starts the list at the top", rawget(list, "toTop") == tops + 1)
checkboxes["Only deals over my minimums"].onToggle(false)
check("so does a filter", rawget(list, "toTop") == tops + 2)
checkboxes["Only deals over my minimums"].onToggle(true)
searched("")

config.minProfit = 50
tab.refresh()
check("Settings minimums hold the grey back", Find(list.data, 3006) == nil)
checkboxes["Only deals over my minimums"].onToggle(false)
check("unticking shows it", Find(list.data, 3006) ~= nil)
checkboxes["Only deals over my minimums"].onToggle(true)
config.minProfit = 0

-- Redraws for bag changes and auction events reuse the list; walking every
-- scanned item each time pushed bag items out of the client's memory.
tab.refresh()
local builds = VendorFlips.rowBuilds
tab.refresh()
tab.refresh()
check("a redraw with nothing changed does not walk every item again", VendorFlips.rowBuilds == builds)
ns.Prices.changes = 1
tab.refresh()
check("new prices do", VendorFlips.rowBuilds == builds + 1)
ns.Prices.changes = nil

-- Items that waited while the auction house was open are read once it shuts.
local later = {}
C_Timer.After = function(_, fn) later[#later + 1] = fn end
builds = VendorFlips.rowBuilds
ns.Scanner.isAuctionHouseOpen = false
for _, fn in ipairs(handlers.AUCTION_HOUSE_CLOSED or {}) do fn(nil, "AUCTION_HOUSE_CLOSED") end
for _, fn in ipairs(later) do fn() end
check("closing the auction house rebuilds the list", VendorFlips.rowBuilds == builds + 1)
C_Timer.After = function() end

records = {}
ns.Prices.Count = function() return 0 end
ns.Prices.changes = 2
tab.refresh()
check("with no scan it says to scan", list.data and #list.data == 0)

--------------------------------------------------------------------------------
-- Sell to: Auction house (a player's idea, 2026-10-06)
--------------------------------------------------------------------------------

print("\nbuy under the usual price and list it again")

local deposits = {}
ns.Posting = { GetCachedUnitDeposit = function(_, itemID) return deposits[itemID] end }
ns.Profit = {
    NetFromListing = function(_, itemID, unitPrice)
        return unitPrice * (1 - (config.auctionCut or 0.05)) - (deposits[itemID] or 0)
    end,
}
local demandLevels = {}
ns.Demand = {
    Get = function(_, itemID)
        local level = demandLevels[itemID]
        return level and { level = level, source = "market", rate = 0.2 } or nil
    end,
    Label = function(_, reading) return reading and (reading.level == "high" and "High" or reading.level == "some" and "Some" or "Low") end,
    Color = function(_, reading) return reading and "profit" or "muted" end,
    Rank = function(_, reading) return reading and 3 or 0 end,
    TooltipText = function(_, reading) return reading and "High (20% of its stock sells a day)" end,
}

--- A record seen in `count` scans: every earlier one at `usual`, the latest
--- (which found the cheap listing) at `latest`.
local function Seen(count, usual, latest, fields)
    local record = fields
    record.seen = 5000
    record.history = {}
    for index = 1, count do
        local last = index == count
        record.history[index] = { t = last and 5000 or 1000 + index, m = last and latest or usual, q = 10 }
    end
    record.market = latest
    return record
end

items[4005] = { 0, 10 }
for itemID = 4001, 4007 do
    if not items[itemID] then items[itemID] = { 1, 10 } end
    demandLevels[itemID] = "high"
end
demandLevels[4004] = "low"

records = {
    [4001] = Seen(6, 1000, 700, { rivalMin = 500, quantity = 10 }),
    [4002] = Seen(6, 1000, 900, { rivalMin = 800, ignoredLow = 200, quantity = 4 }),
    [4003] = Seen(3, 1000, 700, { rivalMin = 500, quantity = 10 }),
    [4004] = Seen(6, 1000, 700, { rivalMin = 500, quantity = 10 }),
    [4005] = Seen(6, 1000, 700, { rivalMin = 500, quantity = 10 }),
    [4006] = Seen(6, 1000, 990, { rivalMin = 970, quantity = 10 }),
    [4007] = Seen(6, 1000, 700, { rivalMin = 500, quantity = 10 }),
}
deposits[4007] = 100
ns.Prices.Count = function() return 7 end

check("the usual price leaves out the scan that found the deal", VendorFlips.UsualPrice(records[4001]) == 1000)
check("and is the middle value, so one odd scan does not move it",
    VendorFlips.UsualPrice(Seen(6, 1000, 1, { history = nil })) == 1000)
local odd = Seen(6, 1000, 700, {})
odd.history[2].m = 90000
check("a single high scan does not either", VendorFlips.UsualPrice(odd) == 1000)
check("fewer than five scans has no usual price", VendorFlips.UsualPrice(records[4003]) == nil)

local resale, held, thin = VendorFlips:GetResaleRows()
local plain = Find(resale, 4001)
check("bought at 5s, usually 10s: listed", plain ~= nil)
check("it lists again at the usual price", plain.resell == 1000 and plain.usual == 1000 and not plain.capped)
check("profit is 10s less the 5% cut less 5s", plain.gain == 450)
check("its demand is carried", plain.demand and plain.demand.level == "high")
check("the deposit is not known yet", plain.depositKnown == false)

local loneResale = Find(resale, 4002)
check("a lone low listing lists again beside the next one up", loneResale and loneResale.buy == 200
    and loneResale.resell == 800 and loneResale.capped and loneResale.gain == 560)

check("a known deposit comes off the profit", Find(resale, 4007).gain == 350 and Find(resale, 4007).depositKnown)

check("too few scans is held back", Find(resale, 4003) == nil)
check("Low demand is held back", Find(resale, 4004) == nil)
check("a grey item is held back", Find(resale, 4005) == nil)
check("and those three are counted as thin", thin == 3)
check("a listing the cut eats is no flip", Find(resale, 4006) == nil)
check("best profit first", resale[1].itemID == 4002 and resale[2].itemID == 4001)
check("nothing held by minimums with none set", held == 0)

config.minProfit = 400
local kept, heldBack = VendorFlips:GetResaleRows({ profitableOnly = true })
check("Minimum profit holds the 3s 50c one back", Find(kept, 4007) == nil and heldBack == 1)
config.minProfit = 0

demandLevels[4001] = nil
check("no demand reading is held back too", Find(VendorFlips:GetResaleRows(), 4001) == nil)
demandLevels[4001] = "high"

ns.db.lastFullScan = 6000
check("a listing the last scan did not see is no flip", #VendorFlips:GetResaleRows() == 0)
ns.db.lastFullScan = nil

print("\nthe Sell to menu")

ns.Prices.changes = 3
sellTo.onSelect({ auction = true })
check("ticking only Auction house lists the resale flips", list.data and #list.data == 3 and Find(list.data, 4001) ~= nil)

row = Stub()
list.opts.createRow(row)
list.opts.updateRow(row, Find(list.data, 4001))
check("GETS shows the price it lists again at", row.cells[3].text ~= "")
check("VIA says AH", row.cells[7].text == "AH")

list.opts.onClick(Find(list.data, 4002), 1, "LeftButton")
check("the detail says what it usually sells for", Showing("Usually sells for"))
check("and that it lists beside the next listing", Showing("List again at (next listing)"))

ns.Scanner.isAuctionHouseOpen = true
printed = {}
list.opts.menu(Find(list.data, 4001))[1].run()
check("right-click's menu still searches for it first", sent[#sent] == "item4001")
check("and says what is worth buying to list again", printed[1] and printed[1]:find("worth buying to list again", 1, true))
ns.Scanner.isAuctionHouseOpen = false

sellTo.onSelect({ vendor = true })
check("back on Vendor the resale rows are gone", Find(list.data, 4001) == nil)

sellTo.onSelect({})
check("with no way ticked, nothing is listed", list.data and #list.data == 0)

print("\nan item more than one way pays on")

-- Bought at 5s: a vendor pays 9s, and it usually sells for 20s.
items[4008] = { 1, 900 }
demandLevels[4008] = "high"
records[4008] = Seen(6, 2000, 700, { rivalMin = 500, quantity = 3 })
ns.Prices.changes = 4
sellTo.onSelect({ auction = true, vendor = true })

local both = Find(list.data, 4008)
local count = 0
for _, entry in ipairs(list.data) do if entry.itemID == 4008 then count = count + 1 end end
check("it is listed once", count == 1)
check("on the way that pays most", both and both.via == "AH" and both.gain == 1400)
check("with the other way kept for the detail", both.others and #both.others == 1
    and both.others[1].via == "Vendor" and both.others[1].gain == 400)

list.opts.onClick(both, 1, "LeftButton")
local other
for _, label in ipairs(labels) do
    if label.text:find("^Other ways: sold to a vendor") then other = label.text end
end
check("and the detail says what the other way makes", other ~= nil)

sellTo.onSelect({ vendor = true })
both = Find(list.data, 4008)
check("with the auction house unticked, it shows as a vendor flip", both and both.via == "Vendor"
    and both.others == nil)

for _, key in ipairs({ "C_Item", "GetTime", "CreateFrame", "PlaySound", "SOUNDKIT",
                      "GameTooltip", "C_Timer", "C_TooltipInfo" }) do
    _G[key] = saved[key]
end

print(("\n%d checks passed"):format(checks))
