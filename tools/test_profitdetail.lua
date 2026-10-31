-- The Profit tab's detail pane with a long list of materials, and its WHO
-- column with two-part names.
--
-- Seven or more materials ran the list into the summary block below it. The
-- list now stops where it fits and ends in a "+N more materials" line whose
-- tooltip holds the whole list.
--
-- WHO is a narrow column and "Bob Ashenmoor" was cut off. It now shows the
-- first name, and the last name's initial as well when another character has
-- the same first name. The full name is on the row's tooltip.

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

--------------------------------------------------------------------------------
-- Short names
--------------------------------------------------------------------------------

print("\nshort names for the WHO column")

do
    local ns = {}
    ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
    ns.RegisterCommand = function() end
    ns.RegisterEvent = function() end
    ns.Warn, ns.Print, ns.PrintRaw, ns.Debug = function() end, function() end, function() end, function() end
    ns.COLORS = {}
    ns.Util = { Count = function(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end }
    ns.Cost = { InvalidateIndex = function() end }
    ns.Compat = { Get = function() return { tradeskill = {} } end }

    assert(loadfile(lfs_cwd .. "/Core/Config.lua"))("Blackthornes_TS", ns)
    assert(loadfile(lfs_cwd .. "/Data/Recipes.lua"))("Blackthornes_TS", ns)

    ns.db = { characters = {
        ["Player-1-A"] = { name = "Bob", surname = "Ashenmoor" },
        ["Player-1-B"] = { name = "Bob", surname = "Blackthorne" },
        ["Player-1-C"] = { name = "Mirel", surname = "Blackthorne" },
        ["Player-1-D"] = { name = "Tomas" },
        ["Old-Forever PvE"] = { name = "Grunt" },
        ["Player-1-E"] = { name = "Aria", surname = "\195\137lan" },
        ["Player-1-F"] = { name = "Aria", surname = "Stone" },
    } }

    local Recipes = ns.Recipes
    -- Never shortened (the owner's rule, 2026-10-11): first and last name.
    check("a first name no one else has keeps its last name",
        Recipes:GetShortCharacterName("Player-1-C") == "Mirel Blackthorne")
    check("a shared first name keeps the whole last name",
        Recipes:GetShortCharacterName("Player-1-A") == "Bob Ashenmoor")
    check("and the other one its own",
        Recipes:GetShortCharacterName("Player-1-B") == "Bob Blackthorne")
    check("a character with no last name known keeps its name",
        Recipes:GetShortCharacterName("Player-1-D") == "Tomas")
    check("an old record keeps its name", Recipes:GetShortCharacterName("Old-Forever PvE") == "Grunt")
    check("an accented last name is whole",
        Recipes:GetShortCharacterName("Player-1-E") == "Aria \195\137lan")
end

--------------------------------------------------------------------------------
-- The Profit tab, drawn without a game client
--------------------------------------------------------------------------------

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() end
ns.Print, ns.Debug, ns.Warn = function() end, function() end, function() end

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

local labels = {}
local function Label()
    local label = Stub({
        text = "",
        shown = true,
        Show = function(self) self.shown = true end,
        Hide = function(self) self.shown = false end,
        SetShown = function(self, v) self.shown = v and true or false end,
        IsShown = function(self) return self.shown end,
        SetText = function(self, value) self.text = tostring(value) end,
        SetTextColor = function() end,
    })
    labels[#labels + 1] = label
    return label
end

-- Every frame remembers whether it is shown and what runs on mouse-over.
local headingBottom, summaryTop

local function Frame()
    return Stub({
        GetTop = function() return summaryTop end,
        shown = true,
        scripts = {},
        Show = function(self) self.shown = true end,
        Hide = function(self) self.shown = false end,
        SetShown = function(self, v) self.shown = v and true or false end,
        SetScript = function(self, name, fn) self.scripts[name] = fn end,
    })
end

local frames = {}
CreateFrame = function() local f = Frame(); frames[#frames + 1] = f; return f end
C_Timer = { After = function() end, NewTicker = function() return Stub() end }

local tooltip = {}
GameTooltip = Stub({
    SetOwner = function() tooltip = {} end,
    SetText = function(_, text) tooltip[#tooltip + 1] = text end,
    AddLine = function(_, text) tooltip[#tooltip + 1] = text end,
    AddDoubleLine = function(_, left) tooltip[#tooltip + 1] = left end,
    IsShown = function() return true end,
})

ns.Theme = {
    SetRowName = function(label, text) label:SetText(text) end,
    SetItemNameColor = function() return false end,
    FONT = "font",
    sizes = { tiny = 10, small = 11, normal = 12, large = 14, title = 16 },
    CreateLabel = function() return Label() end,
    CreatePanel = function() return Frame() end,
    CreateDivider = function() return Stub() end,
    Unpack = function(key) return key end,
    ProfitColor = function(value) return (value or 0) >= 0 and "profit" or "loss" end,
    CreateMark = function() return Stub({ tier = false }) end,
    SetMark = function(mark, tier) mark.tier = tier or false end,
    AccentStripe = function() return Stub() end,
    CreateItemIcon = function() return Stub() end,
    SetItemIcon = function() end,
    SetMoneyText = function(label, copper, opts) label:SetText(ns.Util.FormatMoney(copper, opts)) end,
    CreateBar = function() return Stub() end,
    -- Where the MATERIALS heading ends, once the pane is laid out.
    CreateHeading = function() return Stub({ rule = Stub(), GetBottom = function() return headingBottom end }) end,
    StyleHeading = function(label) label.rule = Stub(); return label end,
}

local checkboxes = {}
ns.Widgets = {
    CreateSearchBox = function() return Stub() end,
    CreateDropdown = function() return Stub() end,
    CreateCheckbox = function(_, text, onChange)
        local box = Stub({ SetShown = function() end })
        checkboxes[text] = onChange
        return box
    end,
    ShowItemTooltip = function() return true end,
    ShowItemOnly = function() end,
    CreateNumberBox = function() return Stub({ editBox = Stub() }) end,
    CreateButton = function() return Stub() end,
}

ns.Util = {
    GetItemQualityColor = function() end,
    FormatMoney = function(copper) return tostring(copper or 0) end,
    FormatAge = function() return "1h" end,
    GetItemLabel = function(itemID) return "item" .. tostring(itemID) end,
    FormatAgeAgo = function() return "1h ago" end,
    Round = function(v) return v end,
    HasFunction = function() return false end,
}

local reagents = {}
for i = 1, 9 do
    reagents[i] = { itemID = 500 + i, quantity = 1, shortfall = 0, lineCost = 10 }
end

local analyses = {
    { recipeID = 1, name = "Big Kit", outputItemID = 11, priceable = true, totalCost = 90,
      revenue = 700, unitRevenue = 700, profit = 565, margin = 0.8, craftableNow = 1,
      cost = { reagents = reagents },
      ownerName = "Bob Ashenmoor", ownerShortName = "Bob A.", isMine = true },
}

ns.Profit = { GetRanked = function() return analyses end, Analyse = function() return analyses[1] end,
              MaxCrafts = function(craftableNow) return math.max(1, craftableNow or 1) end }
ns.Recipes = { Count = function() return 1 end, GetAll = function() return {} end,
               GetAccountWide = function() return {} end, IsDropped = function() return false end }
ns.Prices = { Count = function() return 1 end }
ns.Auctions = { SetLimit = function() end }
local settings = {}
ns.Config = { Get = function(_, key)
    if settings[key] ~= nil then return settings[key] end
    return 0
end, Set = function(_, key, value) settings[key] = value end }
-- The price graph, drawn where the materials go.
local graphFrame
ns.PriceGraph = { Create = function()
    graphFrame = Frame()
    graphFrame.SetItems = function(self, items) self.items = items end
    return graphFrame
end }
ns.Queue = { Add = function() end }

local lists = {}
ns.Widgets.CreateScrollList = function(_, opts)
    local list = Stub({ SetData = function(self, data) self.data = data end })
    list.opts = opts
    lists[#lists + 1] = list
    return list
end

local tabs = {}
ns.UI = Stub({ RegisterTab = function(_, registered) tabs[registered.key] = registered end })

assert(loadfile(lfs_cwd .. "/UI/Columns.lua"))("Blackthornes_TS", ns)

assert(loadfile(lfs_cwd .. "/UI/Tab_Profit.lua"))("Blackthornes_TS", ns)

tabs.profit.build(Stub())
tabs.profit.refresh()
local list = lists[#lists]

print("\na craft with nine materials")

list.opts.onClick(analyses[1], 1, "LeftButton")

local shownLines, moreLabel = 0, nil
for _, label in ipairs(labels) do
    if label.text:match("^item%d") then shownLines = shownLines + 1 end
    if label.text:match("more materials") then moreLabel = label end
end

-- Six lines fit: five materials and the line saying how many more.
check("only the materials that fit are listed", shownLines == 5)
check("the last line says how many more", moreLabel and moreLabel.text == "+4 more materials")

-- The label's frame is the one whose tooltip lists them all.
local moreFrame
for _, frame in ipairs(frames) do
    if rawget(frame, "label") == moreLabel then moreFrame = frame end
end
check("the more line is shown", moreFrame and moreFrame.shown)
tooltip = {}
moreFrame.scripts.OnEnter(moreFrame)
check("its tooltip lists every material", #tooltip == 1 + 9 and tooltip[10] == "1x item509")

print("\nthe same craft in a taller pane")

-- Room for eleven lines between the heading and the summary.
headingBottom, summaryTop = 400, 200
analyses[1] = setmetatable({ recipeID = 2 }, { __index = analyses[1] })
list.opts.onClick(analyses[1], 1, "LeftButton")

shownLines = 0
for _, label in ipairs(labels) do
    if label.text:match("^item%d") then shownLines = shownLines + 1 end
end
check("all nine materials are listed when they fit", shownLines == 9)
check("and there is no more line", not moreFrame.shown)

print("\nthe WHO column")

checkboxes["All characters"](true)
local row = Stub()
list.opts.createRow(row)
list.opts.updateRow(row, analyses[1])
check("WHO shows the short name", row.cells.who.text == "Bob A.")

tooltip = {}
list.opts.onEnter(row, analyses[1])
local named = false
for _, line in ipairs(tooltip) do
    if tostring(line):find("Bob Ashenmoor", 1, true) then named = true end
end
check("the row's tooltip has the full name", named)

print("\nthe price graph has room")

-- With the graph up, the summary keeps only its main rows, so the graph is
-- tall enough to read. The rest come back with the materials.
local function Row(text)
    for _, label in ipairs(labels) do
        if label.text == text then return label end
    end
end
local cut, deposit, profit, perHour = Row("Auction cut"), Row("Deposit"), Row("Profit"), Row("A day")
check("the rows are there to start with", cut and deposit and profit and perHour and cut.shown and deposit.shown)

settings.profitShowsGraph = true
analyses[1] = setmetatable({ recipeID = 3 }, { __index = analyses[1] })
list.opts.onClick(analyses[1], 1, "LeftButton")
check("the graph shows", graphFrame.shown)
check("the auction cut steps aside", not cut.shown)
check("and the deposit", not deposit.shown)
check("profit stays", profit.shown)
check("and so does a day", perHour.shown)

settings.profitShowsGraph = false
analyses[1] = setmetatable({ recipeID = 4 }, { __index = analyses[1] })
list.opts.onClick(analyses[1], 1, "LeftButton")
check("back to the materials, the graph goes", not graphFrame.shown)
check("and the cut comes back", cut.shown)
check("with the deposit", deposit.shown)

print("\nthe STOCK column's hover")
local StockLine = ns.ProfitTab.StockLine
check("a typed number says so", StockLine({ stock = 1, postLimit = 4 }) == "You have 1. You keep 4 (Keep in Stock).")
check("a learned one says where it came from",
    StockLine({ stock = 0, learnedLimit = 3 }) == "You have 0. You keep 3 (learned from your sales).")
check("no number, no line", StockLine({ stock = 2 }) == nil)

print(("\n%d check(s) passed\n"):format(checks))
