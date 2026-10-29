-- The Disenchanting tab: items on the auction house worth buying to
-- disenchant (2026-09-27).
--
-- What this pins down:
--   * profit is the disenchant value, less the auction house cut on the
--     materials, less the cheapest listing from someone else;
--   * a lone low listing that pricing ignores is still the price to buy at;
--   * his own listings, trade goods and items with no priced materials are
--     left out;
--   * the Minimum profit and margin from Settings hold rows back, and the
--     count of those is reported;
--   * items his best enchanter cannot break yet are kept but marked;
--   * the tab draws those rows, and the scan message names the best deal.

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
                C_Timer = C_Timer }

CreateFrame = function()
    local frame = {}
    for _, name in ipairs({ "SetScript", "Show", "Hide", "SetPoint", "SetSize" }) do
        frame[name] = function() end
    end
    return frame
end

GetTime = function() return 1 end
time = time or os.time

local STRANGE_DUST, LESSER_ASTRAL, SMALL_GLIMMERING = 10940, 10998, 10978

-- itemID -> quality, itemLevel, equipLoc, classID
local items = {
    [2001] = { 2, 22, "INVTYPE_CHEST", 4 },   -- green armour, needs Enchanting 25
    [2002] = { 2, 22, "INVTYPE_LEGS", 4 },    -- only his own listing
    [2003] = { 2, 22, "INVTYPE_HAND", 4 },    -- a lone low listing
    [2004] = { 2, 22, "", 7 },                -- trade goods
    [2005] = { 3, 33, "INVTYPE_FEET", 4 },    -- blue, its shard has no price
    [2006] = { 2, 22, "INVTYPE_WAIST", 4 },   -- costs more than it gives
    [2007] = { 2, 12, "INVTYPE_WRIST", 4 },   -- low level, needs Enchanting 1
}

local instantAsked = {}

C_Item = {
    GetItemInfo = function(itemID)
        local item = items[itemID]
        if not item then return nil end
        return "item" .. itemID, nil, item[1], item[2], 1, "Armor", "Cloth", 1,
            item[3], 1, 50, item[4], 1, 2
    end,
    GetItemInfoInstant = function(itemID)
        instantAsked[itemID] = true
        local item = items[itemID]
        if not item then return nil end
        return itemID, "Armor", "Cloth", item[3], 1, item[4], 1
    end,
}

assert(loadfile(lfs_cwd .. "/Core/Util.lua"))("Blackthornes_TS", ns)

local materialPrices = { [STRANGE_DUST] = 160, [LESSER_ASTRAL] = 1000, [SMALL_GLIMMERING] = 2000 }

local records = {
    [2001] = { rivalMin = 500, quantity = 3 },
    [2002] = { ownMin = 100, quantity = 1 },
    [2003] = { rivalMin = 900, ignoredLow = 300, quantity = 2 },
    [2004] = { rivalMin = 1 },
    [2005] = { rivalMin = 1 },
    [2006] = { rivalMin = 5000 },
    [2007] = { rivalMin = 10 },
}

local config = { auctionCut = 0.05, minProfit = 0, minMarginPercent = 0 }

ns.Config = {
    Get = function(_, key) return config[key] end,
    GetCharacterKey = function() return "Tester-Realm" end,
}
ns.Prices = {
    GetTable = function() return records end,
    GetValue = function(_, itemID) return materialPrices[itemID] end,
    GetAge = function() return 600 end,
    IsStale = function(_, itemID) return itemID == 2003 end,
    Count = function() return 7 end,
}
ns.Recipes = {
    GetCharacterName = function(_, key) return (key:match("^([^-]+)")) end,
}

ns.db = { characters = {} }

local function Enchanter(level)
    ns.db.characters = {
        ["Alt-Realm"] = { professions = { { name = "Enchanting", skillLevel = level, learned = true } } },
        ["Main-Realm"] = { professions = { { name = "Tailoring", skillLevel = 150, learned = true } } },
    }
end

assert(loadfile(lfs_cwd .. "/Logic/Disenchant.lua"))("Blackthornes_TS", ns)

local Disenchant = ns.Disenchant

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

Enchanter(50)
local rows = Disenchant:GetAuctionRows()

-- A level 22 green chest.
-- (Before 2026-10-03 every outcome counted by its chance. Now only the most
-- likely does: 5 dust on average at 160 = 800. Less 5% cut: 760.)
local chest = Find(rows, 2001)
check("the green chest is listed", chest ~= nil)
check("its disenchant value is 800", chest.value == 800)
check("the auction cut comes off: 760", chest.net == 760)
check("bought at the cheapest rival listing", chest.buy == 500)
check("profit is 760 - 500 = 260", chest.gain == 260)
check("margin is profit over the buy price", math.abs(chest.margin - 0.52) < 1e-9)
check("it says how many are listed", chest.listed == 3)

check("his own listing is not a deal", Find(rows, 2002) == nil)

local gloves = Find(rows, 2003)
check("a lone low listing is the one to buy", gloves and gloves.buy == 300 and gloves.loneLow)
check("and an old scan is marked stale", gloves.stale == true)

check("trade goods are left out", Find(rows, 2004) == nil)
check("an item with no priced material is left out", Find(rows, 2005) == nil)
check("trade goods were skipped before loading them", instantAsked[2004] == true)

local belt = Find(rows, 2006)
check("a loss is still listed without the deals filter", belt and belt.gain < 0 and not belt.beatsSale)

check("best profit first", rows[1].gain >= rows[2].gain and rows[#rows].itemID == 2006)

print("\nonly deals, and the minimums from Settings")

local deals, hidden = Disenchant:GetAuctionRows({ profitableOnly = true })
check("a loss is not a deal", Find(deals, 2006) == nil)
check("nothing held back with no minimums", hidden == 0)

config.minProfit = 300
deals, hidden = Disenchant:GetAuctionRows({ profitableOnly = true })
check("Minimum profit holds the 260 chest back", Find(deals, 2001) == nil)
check("the gloves still clear it", Find(deals, 2003) ~= nil)
check("and it says how many were held back", hidden >= 1)
config.minProfit = 0

config.minMarginPercent = 100
deals = Disenchant:GetAuctionRows({ profitableOnly = true })
check("Minimum margin holds the 52% chest back", Find(deals, 2001) == nil)
config.minMarginPercent = 0

print("\nwho can disenchant it")

Enchanter(10)
rows = Disenchant:GetAuctionRows()
chest = Find(rows, 2001)
check("the chest needs 25", chest.needs == 25)
check("Enchanting 10 cannot break it, but it is still shown", chest.canDisenchant == false)
check("it names the enchanter", chest.enchanter == "Alt" and chest.enchanterSkill == 10)
check("the low level bracers need 1, so 10 can", Find(rows, 2007).canDisenchant == true)

Enchanter(50)
check("Enchanting 50 can", Find(Disenchant:GetAuctionRows(), 2001).canDisenchant == true)

ns.db.characters = {}
check("no enchanter at all is nil, not false", Find(Disenchant:GetAuctionRows(), 2001).canDisenchant == nil)

print("\nthe list holds steady while the client's cache comes and goes")

-- The client's item cache is small: an item it answered a moment ago can be
-- gone again. Once read, an item must stay on the list, and must not be read
-- from the client again (reading it would fetch it and push his bag items
-- out, which made Ready to sell drop rows).
local realInfo = C_Item.GetItemInfo
local loads, reads = {}, {}
local evicted = {}
C_Item.GetItemInfo = function(itemID)
    reads[itemID] = (reads[itemID] or 0) + 1
    if evicted[itemID] then return nil end
    return realInfo(itemID)
end
C_Item.RequestLoadItemDataByID = function(itemID) loads[itemID] = (loads[itemID] or 0) + 1 end

Disenchant:GetAuctionRows()
evicted[2001] = true
reads = {}
local counts = {}
for pass = 1, 4 do counts[pass] = #Disenchant:GetAuctionRows() end
check("the same count on every redraw", counts[1] == counts[2] and counts[2] == counts[3] and counts[3] == counts[4])
check("the chest stays listed after the client lets it go", Find(Disenchant:GetAuctionRows(), 2001) ~= nil)
check("and it is not read from the client again", reads[2001] == nil)
check("what was read is kept in the saved data", ns.db.itemFacts[2001] and ns.db.itemFacts[2001].l == 22)

-- An item the client has not sent: asked for once, not read while it is on
-- its way, and read the moment it arrives, before the cache can drop it.
Disenchant:_ForgetItems()
evicted = { [2001] = true }
loads, reads = {}, {}
C_Item.IsItemDataCachedByID = function(itemID) return not evicted[itemID] end
for _ = 1, 5 do Disenchant:GetAuctionRows() end
check("an uncached item is asked for once", loads[2001] == 1)
check("not read while it is on its way", reads[2001] == nil)

evicted[2001] = nil
Disenchant:OnItemInfoReceived(2001, true)
evicted[2001] = true   -- and gone again straight after
check("read the moment it arrives", reads[2001] == 1)
check("the tab redraws for an item it asked for", Disenchant:WasRequested(2001))
check("but not for items it never asked about", not Disenchant:WasRequested(999999))
GetTime = function() return 60 end
check("nor for one read long ago that something else reloads", not Disenchant:WasRequested(2001))
GetTime = function() return 1 end
check("it is listed from then on", Find(Disenchant:GetAuctionRows(), 2001) ~= nil)

-- A big scan asks for a few new items a second, not all of them at once.
Disenchant:_ForgetItems()
C_Item.GetItemInfo = function() return nil end
C_Item.IsItemDataCachedByID = function() return false end
loads = {}
for itemID = 5001, 5200 do records[itemID] = { rivalMin = 10 } end
Disenchant:GetAuctionRows()
local asked = 0
for _ in pairs(loads) do asked = asked + 1 end
check("only the per-second budget is asked for", asked == Disenchant.REQUESTS_PER_SECOND)

-- One that never arrives is asked for again later, then given up on.
for step = 1, 40 do
    GetTime = function() return 100 * step end
    Disenchant:GetAuctionRows()
end
local most, twice = 0, 0
for _, count in pairs(loads) do
    most = math.max(most, count)
    if count == 2 then twice = twice + 1 end
end
check("an item that never arrives is asked for again", twice > 0)
check("but twice at most", most == 2)
GetTime = function() return 1 end

for itemID = 5001, 5200 do records[itemID] = nil end
C_Item.IsItemDataCachedByID = nil
C_Item.GetItemInfo = realInfo
C_Item.RequestLoadItemDataByID = nil
Disenchant:_ForgetItems()

print("\nnothing new is read while the auction house is open")

-- The auction house refuses to sell an item the client has let go of, so
-- reading new items there pushed his bag items out and Ready to sell lost
-- rows (2026-09-28). What is already known still lists.
Disenchant:_ForgetItems()
Disenchant:GetAuctionRows()               -- the known items, read while it is shut
local knownCount = #Disenchant:GetAuctionRows()

ns.Scanner = { isAuctionHouseOpen = true }
local fetched = {}
C_Item.RequestLoadItemDataByID = function(itemID) fetched[itemID] = true end
local askedCached = 0
C_Item.IsItemDataCachedByID = function(itemID)
    if itemID == 2008 then askedCached = askedCached + 1 end
    return itemID ~= 2008
end
records[2008] = { rivalMin = 10 }

local openRows, _, pending = Disenchant:GetAuctionRows()
check("items already known still list at the auction house", #openRows == knownCount)
check("a new item is not fetched while it is open", next(fetched) == nil)
check("and is counted as waiting", pending == 1)
check("the client is not even asked whether it holds it", askedCached == 0)

ns.Scanner.isAuctionHouseOpen = false
Disenchant:GetAuctionRows()
check("it is fetched once the auction house closes", fetched[2008] == true)

records[2008] = nil
ns.Scanner = nil
C_Item.RequestLoadItemDataByID, C_Item.IsItemDataCachedByID = nil, nil
Disenchant:_ForgetItems()

print("\nonly what the last scan saw")

ns.db.lastFullScan = 1000
records[2001].seen = 999      -- gone from the last scan: sold or expired
check("a listing the last scan did not see is not a deal", Find(Disenchant:GetAuctionRows(), 2001) == nil)
records[2001].seen = 1000
check("one it did see is", Find(Disenchant:GetAuctionRows(), 2001) ~= nil)
records[2001].seen = 1200     -- a search after the scan
check("and so is one a later search saw", Find(Disenchant:GetAuctionRows(), 2001) ~= nil)
records[2001].seen, ns.db.lastFullScan = nil, nil

-- On a big auction house every sweep stops at the page limit and never gets
-- a full scan stamp. That sweep still decides what counts as seen.
ns.Prices.GetLastScan = function() return 1000, true end
records[2001].seen = 999
check("a listing a capped sweep did not see is not a deal", Find(Disenchant:GetAuctionRows(), 2001) == nil)
records[2001].seen = 1200
check("one a later search saw still is", Find(Disenchant:GetAuctionRows(), 2001) ~= nil)
records[2001].seen, ns.Prices.GetLastScan = nil, nil

print("\n/bts dedeals")

ns.db.lastFullScan = 1000
records[2001].seen = 999
printed = {}
commands.dedeals()
local said = table.concat(printed, "\n")
check("it says when the last scan was", said:find("last scan", 1, true) ~= nil)
check("and what a fresh build would show", said:find("built fresh now", 1, true) ~= nil)
records[2001].seen, ns.db.lastFullScan = nil, nil

print("\nthe scan message")

Enchanter(50)
local chimed
SOUNDKIT = { UI_EPICLOOT_TOAST = 1 }
PlaySound = function(kit) chimed = kit end

printed = {}
local count = Disenchant:AnnounceDeals()
check("it counts the deals", count >= 2)
check("it names the best one", printed[1] and printed[1]:find("Disenchant deals", 1, true)
    and printed[1]:find("item2003", 1, true))
check("with a chime", chimed == 1)

-- Settings: Sound when a scan finishes, turned off. The message still shows.
config.scanSounds = false
printed, chimed = {}, nil
Disenchant:AnnounceDeals()
check("with scan sounds off, the message and no sound", #printed == 1 and chimed == nil)
config.scanSounds = nil

-- Only deals a character can break at today's skill count.
local function Breakable()
    local n = 0
    for _, row in ipairs(Disenchant:GetAuctionRows({ profitableOnly = true })) do
        if row.canDisenchant ~= false then n = n + 1 end
    end
    return n
end
Enchanter(10)
local allDeals = #Disenchant:GetAuctionRows({ profitableOnly = true })
check("some deals need more skill than Enchanting 10", Breakable() < allDeals)
printed = {}
check("the message counts only deals Enchanting 10 can break",
    Disenchant:AnnounceDeals() == Breakable())
ns.db.characters = {}
check("with no enchanter known, every deal counts", Disenchant:AnnounceDeals() == allDeals)
Enchanter(50)

local backup = records
records = { [2006] = { rivalMin = 5000 } }
printed, chimed = {}, nil
check("no deals, no message", Disenchant:AnnounceDeals() == 0 and #printed == 0 and chimed == nil)
records = backup

--------------------------------------------------------------------------------
-- The tab
--------------------------------------------------------------------------------

print("\nthe Disenchanting tab")

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
        SetTextColor = function(self, a) self.color = a end,
        SetShown = function(self, value) self.shown = value end,
    })
end

CreateFrame = function() return Stub() end
C_Timer = { After = function() end }
GameTooltip = Stub()

ns.Theme = {
    FitWhole = function(label, text) label:SetText(text); return 0, 13 end,
    SetRowLine = function(label, text) label:SetText(text) end,
    SetRowName = function(label, text) label:SetText(text) end,
    SetItemNameColor = function() return false end,
    CreateLabel = function() return Label() end,
    CreatePanel = function() return Stub() end,
    CreateDivider = function() return Stub() end,
    Unpack = function(key) return key end,
    ProfitColor = function(value) return (value or 0) >= 0 and "profit" or "loss" end,
    AccentStripe = function() return Stub() end,
    CreateItemIcon = function() return Stub() end,
    SetItemIcon = function() end,
    CreateHeading = function() return Stub() end,
}

local checkboxes, lists = {}, {}
ns.Widgets = {
    CreateTabStrip = function() return Stub() end,
    CreateSearchBox = function() return Stub() end,
    CreateDropdown = function() return Stub() end,
    CreateCheckbox = function(_, text, onToggle) local box = Stub({ onToggle = onToggle }); checkboxes[text] = box; return box end,
    CreateButton = function() return Stub() end,
    ShowItemTooltip = function() return true end,
    CreateScrollList = function(_, opts)
        local list = Stub({ opts = opts, SetData = function(self, data) self.data = data end })
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

assert(loadfile(lfs_cwd .. "/UI/Tab_Disenchanting.lua"))("Blackthornes_TS", ns)

local tab = tabs.disenchanting
check("the tab registers as Disenchanting", tab and tab.text == "Disenchanting")
check("it sits after Post and before Level Up", tab.order > 4 and tab.order < 6)

tab.build(Stub())
tab.refresh()

local list = lists[#lists]
check("deals only by default: no loss listed", list.data and Find(list.data, 2006) == nil)
check("a deal is listed", Find(list.data, 2001) ~= nil)

local row = Stub()
list.opts.createRow(row)
list.opts.updateRow(row, Find(list.data, 2001))

-- Right to left: PROFIT, MARGIN, DISENCHANT, BUY, SKILL, AGE.
check("PROFIT shows 260 in green", row.cells[1].text:find("60", 1, true) and row.cells[1].color == "profit")
check("MARGIN shows 52%", row.cells[2].text == "52%")
check("BUY shows the price", row.cells[4].text ~= "")
check("SKILL shows what it needs", row.cells[5].text == "25" and row.cells[5].color == "dim")

-- Reported 2026-10-08: the names drew white. Most rows are items read in an
-- earlier session that the client's cache no longer holds, so the name's
-- rarity comes from the facts kept in the saved data, without asking the
-- client for the item again.
local cachedInfo, cachedLoad = C_Item.GetItemInfo, C_Item.RequestLoadItemDataByID
local asked = 0
ITEM_QUALITY_COLORS = { [2] = { r = 0.12, g = 1, b = 0 } }
C_Item.GetItemInfo = function() return nil end
C_Item.RequestLoadItemDataByID = function() asked = asked + 1 end
list.opts.updateRow(row, Find(list.data, 2001))
check("a green item's name is green with the client's cache empty", row.name.color == 0.12)
check("and the client was not asked for it", asked == 0)
C_Item.GetItemInfo, C_Item.RequestLoadItemDataByID = cachedInfo, cachedLoad
ITEM_QUALITY_COLORS = nil

checkboxes["Only deals over my minimums"].onToggle(false)
check("unticking shows the loss too", Find(list.data, 2006) ~= nil)

Enchanter(10)
tab.refresh()
list.opts.updateRow(row, Find(list.data, 2001))
check("too high for his enchanters: SKILL in red", row.cells[5].color == "loss")

checkboxes["Only ones I can disenchant"].onToggle(true)
check("and hidden when asked", Find(list.data, 2001) == nil and Find(list.data, 2007) ~= nil)
checkboxes["Only ones I can disenchant"].onToggle(false)

list.opts.onClick(Find(list.data, 2003), 1, "RightButton")
check("right-click searches the auction house for it", sent[#sent] == "item2003")

-- Redraws for bag changes and auction events reuse the list; walking every
-- scanned item each time pushed bag items out of the client's memory.
local builds = Disenchant.rowBuilds
tab.refresh()
tab.refresh()
check("a redraw with nothing changed does not walk every item again", Disenchant.rowBuilds == builds)
ns.Prices.changes = 1
tab.refresh()
check("new prices do", Disenchant.rowBuilds == builds + 1)

-- A buy, or a search that finds none, changes one item: only its row is
-- redone (a player found a ring still offered after buying the last one).
local chestBuy = records[2001].rivalMin
records[2001].rivalMin = nil
ns.Prices.TouchedSince = function(_, since) return since == 1 and { [2001] = true } or nil end
ns.Prices.changes = 2
builds = Disenchant.rowBuilds
tab.refresh()
check("the last one bought: its row goes, the list is not walked again",
    Disenchant.rowBuilds == builds and Find(list.data, 2001) == nil and Find(list.data, 2003) ~= nil)

records[2001].rivalMin = 700
ns.Prices.TouchedSince = function(_, since) return since == 2 and { [2001] = true } or nil end
ns.Prices.changes = 3
tab.refresh()
check("a dearer listing seen later comes back at its price",
    Disenchant.rowBuilds == builds and Find(list.data, 2001) and Find(list.data, 2001).buy == 700)
local patchedOrder = {}
for i, row in ipairs(list.data) do patchedOrder[i] = row.itemID end

ns.Prices.TouchedSince = function() return { [STRANGE_DUST] = true } end
ns.Prices.changes = 4
tab.refresh()
check("a material's price moves every row, so the list is built again", Disenchant.rowBuilds == builds + 1)
local same = #patchedOrder == #list.data
for i, row in ipairs(list.data) do same = same and patchedOrder[i] == row.itemID end
check("and the patched list matched the full build", same)

ns.Prices.TouchedSince = function() return nil end
ns.Prices.changes = 5
tab.refresh()
check("changes it cannot name build it again", Disenchant.rowBuilds == builds + 2)

records[2001].rivalMin = chestBuy
ns.Prices.TouchedSince = nil
ns.Prices.changes = nil

-- Items that waited while the auction house was open are read once it shuts.
local later = {}
C_Timer.After = function(_, fn) later[#later + 1] = fn end
builds = Disenchant.rowBuilds
ns.Scanner.isAuctionHouseOpen = false
for _, fn in ipairs(handlers.AUCTION_HOUSE_CLOSED or {}) do fn(ns.UI, "AUCTION_HOUSE_CLOSED") end
for _, fn in ipairs(later) do fn() end
check("closing the auction house rebuilds the list", Disenchant.rowBuilds == builds + 1)
ns.Scanner.isAuctionHouseOpen = true
C_Timer.After = function() end

ns.Scanner.isAuctionHouseOpen = false
printed = {}
list.opts.onClick(Find(list.data, 2003), 1, "RightButton")
check("with the auction house shut it says to open it", #sent == 1 and printed[1]:find("Open the auction house", 1, true))

for _, key in ipairs({ "C_Item", "GetTime", "CreateFrame", "PlaySound", "SOUNDKIT",
                      "GameTooltip", "C_Timer" }) do
    _G[key] = saved[key]
end

print(("\n%d checks passed"):format(checks))
