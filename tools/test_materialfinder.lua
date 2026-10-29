-- Find a material (Logic/MaterialFinder.lua and the Disenchanting tab's
-- view), drawn without a game client.
--
-- Asked 2026-10-16, after a player wanted to know what to break, make or
-- farm for the best odds at a Large Radiant Shard, and what had given them
-- one before. What this pins down:
--   * the odds and cost for one material, from the same chances the tab uses;
--   * what your own disenchants gave it, and whether you made or looted it;
--   * the ways: in your bags (best odds first), on the auction house and by
--     a craft (cheapest a shard first), and from Farmer's own kills;
--   * the ways are kept, and worked out again when the bags move;
--   * Farmer missing or raising leaves the rest standing;
--   * the view shows each way under its heading, with its own columns, and
--     its buttons queue the craft or open the mob in Farmer.

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
local printed = {}
ns.Print = function(text) printed[#printed + 1] = text end
ns.Debug, ns.Warn = function() end, function() end
ns.RegisterEvent = function() return true end

--------------------------------------------------------------------------------
-- A widget layer that only remembers what was written to it
--------------------------------------------------------------------------------

local function Stub(fields)
    local frame = fields or {}

    frame.GetParent = frame.GetParent or function() return Stub() end
    frame.IsVisible = frame.IsVisible or function() return true end

    return setmetatable(frame, { __index = function(self, key)
        local noop = function() end
        rawset(self, key, noop)
        return noop
    end })
end

local function Shown(fields)
    fields = fields or {}
    fields.shown = true
    fields.SetShown = function(self, value) self.shown = value and true or false end
    fields.Show = function(self) self.shown = true end
    fields.Hide = function(self) self.shown = false end
    return Stub(fields)
end

local labels = {}
local function Label()
    local label
    label = Shown({
        text = "",
        SetText = function(self, value) self.text = tostring(value) end,
        GetText = function(self) return self.text end,
        SetTextColor = function(self, a) self.color = a end,
    })
    labels[#labels + 1] = label
    return label
end

--- Some label now showing text that matches, or nil.
local function Showing(pattern)
    for _, label in ipairs(labels) do
        if label.shown and label.text:find(pattern) then return label.text end
    end
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
    CreateHeading = function() return Shown() end,
    CreateItemIcon = function() return Shown() end,
    SetItemIcon = function() end,
    AccentStripe = function() return Stub() end,
    Unpack = function(key) return key end,
    ProfitColor = function(value) return (value or 0) >= 0 and "profit" or "loss" end,
}

local checkboxes, dropdown, buttons, pages = {}, nil, {}, nil

ns.Widgets = {
    CreateTabStrip = function(_, tabs, onSelect)
        pages = Shown({ tabs = tabs, onSelect = onSelect, Select = function(self, key) self.selected = key end })
        return pages
    end,
    CreateSearchBox = function() return Stub() end,
    CreateDropdown = function(_, options, onSelect)
        dropdown = { options = options, select = onSelect }
        return Stub()
    end,
    CreateCheckbox = function(_, text, onToggle)
        local box = Shown({ onToggle = onToggle })
        checkboxes[text] = box
        return box
    end,
    CreateButton = function(_, text, onClick)
        local button = Shown({
            onClick = onClick,
            SetEnabledState = function(self, value) self.enabled = value end,
        })
        buttons[text] = button
        return button
    end,
    ShowItemTooltip = function() return true end,
}

local lists = {}
ns.Widgets.CreateScrollList = function(_, opts)
    local list = Stub({ SetData = function(self, data) self.data = data end, opts = opts })
    lists[#lists + 1] = list
    return list
end

ns.Util = {
    FormatMoney = function(copper) return tostring(copper or 0) end,
    FormatAge = function() return "1h" end,
    FormatAgeAgo = function() return "1h ago" end,
    GetItemLabel = function(itemID) return "item" .. tostring(itemID) end,
    ColorItemName = function(_, name) return name end,
    ColoredItemName = function(id) return "item" .. tostring(id) end,
    GetItemName = function(id, fallback) return fallback or ("item" .. tostring(id)) end,
    GetItemQualityColor = function() end,
    Round = function(v) return v end,
}


local SHARD, DUST = 11178, 10

local clock = 100
GetTime = function() return clock end

ns.Prices = { Count = function() return 1 end, changes = 0, GetLastScan = function() return 5 end,
    GetAge = function() return 60 end, IsStale = function() return false end,
    GetValue = function(_, id) return id == SHARD and 4800 or nil end }
ns.Config = { Get = function() return 0 end }
ns.Scanner = { isAuctionHouseOpen = false }
ns.Inventory = { changes = 0, GetBagCounts = function() return { [SHARD] = 3 } end }
local queued
ns.Queue = { version = 0, Add = function(_, recipeID, quantity) queued = { recipeID, quantity }; return true end }
ns.Recipes = { Count = function() return 1 end,
    GetAccountWideOutputs = function() return { { outputItemID = 61 } } end }

local function Gives(chance) return { facts = {}, outcomes = { { itemID = SHARD, chance = chance, min = 1, max = 1 } } } end

local bagRows = {
    { kind = "bag", itemID = 42, name = "Cindercloth Boots", count = 2, breakdown = Gives(0.05) },
    { kind = "bag", itemID = 41, name = "Ironfeather Shoulders", count = 1, breakdown = Gives(1) },
    { kind = "bag", itemID = 43, name = "Linen Belt", count = 1,
      breakdown = { facts = {}, outcomes = { { itemID = DUST, chance = 1, min = 1, max = 2 } } } },
}
local auctionRows = {
    { kind = "auction", itemID = 51, name = "Blue Bracers", buy = 30000, gain = 0, breakdown = Gives(1) },
    { kind = "auction", itemID = 52, name = "Green Gloves", buy = 1000, gain = 0, breakdown = Gives(0.05) },
}
local craftRows = {
    { kind = "craft", recipeID = 900, itemID = 61, name = "Cindercloth Robe", cost = 9000,
      craftableNow = 2, breakdown = Gives(0.05) },
}
local OUTCOMES = { [41] = Gives(1).outcomes, [42] = Gives(0.05).outcomes }
local NAMES = { [41] = "Ironfeather Shoulders", [61] = "Cindercloth Robe", [70] = "Linen Shirt",
    [SHARD] = "Large Radiant Shard", [DUST] = "Strange Dust" }

local bagAsks = 0
ns.Disenchant = {
    MATERIALS = { { itemID = DUST, name = "Strange Dust" }, { itemID = SHARD, name = "Large Radiant Shard" } },
    GetBestEnchanter = function() return 300 end,
    GetAuctionRows = function() return auctionRows, 0, 0 end,
    GetBagRows = function() bagAsks = bagAsks + 1; return bagRows end,
    GetCraftRows = function() return craftRows end,
    GetOutcomes = function(_, itemID) return OUTCOMES[itemID] or {} end,
    ItemName = function(_, itemID) return NAMES[itemID] end,
    WasRequested = function() return false end,
}

ns.DisenchantLog = {
    version = 1,
    GetSession = function() return 0, 0 end,
    GetTable = function() return { items = {
        [41] = { casts = 4, got = { [SHARD] = { times = 4, total = 4 } } },
        [61] = { casts = 22, got = { [SHARD] = { times = 1, total = 1 } } },
        [70] = { casts = 3, got = { [DUST] = { times = 3, total = 5 } } },
    } } end,
}

local carrying = { [41] = true, [42] = true }
local armed = {}
ns.Disenchanter = {
    Check = function(_, itemID)
        if carrying[itemID] then return { ok = true, bag = 0, slot = 1 } end
        return { ok = false, why = "That item is no longer in your bags." }
    end,
    Arm = function(self, anchor, itemID) self.anchor = anchor; armed[#armed + 1] = itemID; return true end,
    Disarm = function(self) self.anchor = nil end,
}

local farmAsked, opened = {}, nil
local farmRaises = false
_G.BlackthornesFarmer = { DisenchantFarm = {
    Best = function(_, gives)
        if farmRaises then error("boom") end
        farmAsked[41] = gives(41)
        if farmAsked[41] <= 0 then return {} end
        return { { mob = "Felpaw Ravager", zone = "Felwood", shownZone = "Felwood", kills = 30, perKill = 0.11,
            perHour = 11, items = { { id = 41, name = "Ironfeather Shoulders", corpses = 3 } } } }
    end,
    DroppedBy = function(_, itemID) return itemID == 41 and "Felpaw Ravager" or nil end,
    Show = function(_, mob) opened = mob; return true end,
} }

assert(loadfile(lfs_cwd .. "/Logic/MaterialFinder.lua"))("Blackthornes_TS", ns)
local Finder = ns.MaterialFinder

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

print("\nodds")
local chance, each, expected = Finder.Odds({ { itemID = 5, chance = 0.5, min = 1, max = 3 } }, 5)
check("chance, how many and the average", chance == 0.5 and each == 2 and expected == 1)
check("nothing for a material it never gives", Finder.Odds({ { itemID = 6, chance = 1, min = 1, max = 1 } }, 5) == nil)
check("every time", Finder.OddsText(1) == "Every time")
check("one in twenty", Finder.OddsText(0.05) == "1 in 20")
check("one in nine kills", Finder.KillText(0.11) == "1 in 9 kills")
check("two a kill", Finder.KillText(2) == "2 a kill")
check("how many one gives", Finder:Gives(41, SHARD) == 1 and Finder:Gives(99, SHARD) == 0)

print("\nwhat you've gotten it from")
local had = Finder:Had(SHARD)
check("the two items that gave it", #had == 2)
check("most times first", had[1].itemID == 41 and had[1].times == 4 and had[1].casts == 4)
check("looted, from Farmer", had[1].how == "looted" and had[1].mob == "Felpaw Ravager")
check("made by you", had[2].itemID == 61 and had[2].how == "made")

print("\nthe ways")
local ways = Finder:Ways(SHARD)
check("bags, best odds first", #ways.bag == 2 and ways.bag[1].itemID == 41 and ways.bag[2].itemID == 42)
check("an item that never gives it is left out", ways.bag[3] == nil)
check("auction house, cheapest a shard first", ways.auction[1].itemID == 52 and ways.auction[1].costEach == 20000
    and ways.auction[2].costEach == 30000)
check("a craft, by its materials", ways.craft[1].recipeID == 900 and ways.craft[1].costEach == 180000)
check("a row keeps the tab's own row", ways.bag[1].source == bagRows[2])
check("Farmer's mob", ways.farm[1] and ways.farm[1].mob == "Felpaw Ravager" and ways.farm[1].perKill == 0.11)
check("Farmer is told what each item gives", farmAsked[41] == 1)

local asks = bagAsks
Finder:Ways(SHARD)
check("kept while nothing moves", bagAsks == asks)
ns.Inventory.changes = 1
Finder:Ways(SHARD)
check("worked out again when the bags move", bagAsks == asks + 1)

farmRaises = true
Finder:Forget()
ways = Finder:Ways(SHARD)
check("Farmer raising leaves the rest", #ways.farm == 0 and #ways.bag == 2)
farmRaises = false
Finder:Forget()

check("opens on the best material you've had", Finder:FirstPick() == SHARD)

print("\nthe view")
local tabs = {}
ns.UI = Stub({ RegisterTab = function(_, registered) tabs[registered.key] = registered end })
assert(loadfile(lfs_cwd .. "/UI/Columns.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/UI/Tab_Disenchanting.lua"))("Blackthornes_TS", ns)

local tab = tabs.disenchanting
tab.build(Stub())
tab.refresh()
local list = lists[#lists]
check("it still opens on the auction house", list.data == auctionRows)

check("a page for it", pages ~= nil and pages.tabs[3].key == "material")
pages.onSelect("material")

local data = list.data
local headings = {}
for _, row in ipairs(data) do
    if row.kind == "section" then headings[#headings + 1] = row.name end
end
check("each way under its heading", table.concat(headings, ",")
    == "YOU'VE GOTTEN IT FROM,BREAK WHAT YOU HAVE,BUY AND BREAK,MAKE AND BREAK,FARM AND BREAK")
check("the auction tick boxes step aside", not checkboxes["Only deals over my minimums"].shown
    and not checkboxes["Only where disenchanting pays more"].shown)
check("the count line says what you have", Showing("^You have 3  ·  Sells for 4800$") ~= nil)

local function RowOf(kind)
    for _, row in ipairs(data) do if row.kind == kind then return row end end
end

-- Cells, right to left: COST EACH, ODDS, WHERE.
local row = Stub()
list.opts.createRow(row)
list.opts.updateRow(row, data[1])
check("a heading's row", row.name.text == "YOU'VE GOTTEN IT FROM" and row.cells[1].text == "")

list.opts.updateRow(row, RowOf("had"))
check("how many of yours gave it", row.cells[2].text == "4 of 4")
check("and where you got it", row.cells[3].text == "Looted, Felpaw Ravager")

list.opts.updateRow(row, RowOf("auction"))
check("an auction's cost a shard", row.cells[1].text == "20000" and row.cells[2].text == "1 in 20"
    and row.cells[3].text == "Auction house")

list.opts.updateRow(row, RowOf("farm"))
check("a mob's hour, odds and zone", row.cells[1].text == "about 11 an hour" and row.cells[2].text == "1 in 9 kills"
    and row.cells[3].text == "Felwood")

print("\npicking rows")
local disenchant = buttons["Disenchant"]
local action = buttons["Queue one"]

list.opts.onClick(data[1], 1, "LeftButton")
check("a heading can't be picked", not action.shown and not disenchant.shown)

list.opts.onClick(RowOf("bag"), 2, "LeftButton")
check("an item in the bags gets the Disenchant button", disenchant.shown and armed[#armed] == 41)

list.opts.onClick(RowOf("craft"), 3, "LeftButton")
check("a craft offers to queue one", action.shown and not disenchant.shown)
action.onClick()
check("and queues it", queued and queued[1] == 900 and queued[2] == 1)

list.opts.onClick(RowOf("farm"), 4, "LeftButton")
check("a mob offers Farmer", action.shown)
action.onClick()
check("and opens it there", opened == "Felpaw Ravager")

print("\nanother material")
dropdown.select(DUST)
local only = list.data
check("another material lists its own", #only == 4 and only[2].itemID == 70 and only[4].itemID == 43)

pages.onSelect("auction")
check("back to the auction house", list.data == auctionRows)

print(("\n%d check(s) passed\n"):format(checks))
