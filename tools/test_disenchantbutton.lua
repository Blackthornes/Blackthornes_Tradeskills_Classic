-- The Disenchant button the Profit and Disenchanting tabs share, drawn
-- without a game client on frames whose visibility follows their parents and
-- whose OnHide runs when a parent hides, as in the game.
--
-- What must hold:
--   1. A tab redrawn while hidden never takes the secure button from the tab
--      on screen. The button the player sees disenchants the item it names,
--      and it goes away with its tab and with the window.
--   2. The bags lists pick only an item worth more disenchanted than sold,
--      and light the row they pick. With none, the button shows unset and
--      the line beside it says why; a click on an item still sets it.
--   3. On the Profit tab, a craft's Disenchant button that cannot be used
--      says why on its tooltip.
--   4. The Disenchanting tab names the tick box that hid every deal.
--   5. A "breaks into" line's name gets the room its price leaves, and wraps.
--   6. Bag rows hand their link to the item icon, for the upgrade arrow.
--   7. The secure button wears the primary button's gold edge.

-- Tests share one Lua state, so every global replaced here is put back,
-- including the ones that were not set at all.
local GLOBALS = { "CreateFrame", "UIParent", "GameTooltip", "C_Timer", "InCombatLockdown",
    "GetTime", "time", "IsPlayerSpell", "IsSpellKnown", "C_Container", "C_Spell",
    "GetSpellInfo", "C_SpellBook" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local function noop() end

--------------------------------------------------------------------------------
-- Frames
--------------------------------------------------------------------------------

-- Methods do nothing unless named here, and plain fields read as nil.
local proto = {}
local Frame

function proto:IsShown() return self.shown end
function proto:IsVisible()
    local frame = self
    while frame do
        if not frame.shown then return false end
        frame = frame.parent
    end
    return true
end

local function Family(frame, out)
    out = out or {}
    for _, child in ipairs(frame.children) do
        out[#out + 1] = child
        Family(child, out)
    end
    return out
end

local function RunScripts(frame, name, ...)
    for _, fn in ipairs(frame.scriptList[name] or {}) do fn(frame, ...) end
end

-- Hiding a frame runs OnHide on everything under it that was showing.
local function SetShown(frame, on)
    on = on and true or false
    if frame.shown == on then return end

    local family = Family(frame)
    family[#family + 1] = frame
    local before = {}
    for _, member in ipairs(family) do before[member] = member:IsVisible() end

    frame.shown = on

    for _, member in ipairs(family) do
        local now = member:IsVisible()
        if before[member] and not now then RunScripts(member, "OnHide") end
        if now and not before[member] then RunScripts(member, "OnShow") end
    end
end

function proto:Show() SetShown(self, true) end
function proto:Hide() SetShown(self, false) end
function proto:SetShown(on) SetShown(self, on) end
function proto:SetScript(name, fn) self.scriptList[name] = fn and { fn } or nil end
function proto:HookScript(name, fn)
    self.scriptList[name] = self.scriptList[name] or {}
    table.insert(self.scriptList[name], fn)
end
function proto:GetScript(name) return self.scriptList[name] and self.scriptList[name][1] end
function proto:SetAttribute(key, value) self.attributes[key] = value end
function proto:GetAttribute(key) return self.attributes[key] end
function proto:EnableMouse(on) self.mouse = on and true or false end
function proto:SetFrameStrata(strata) self.strata = strata end
function proto:GetFrameStrata()
    return self.strata or (self.parent and self.parent:GetFrameStrata()) or "MEDIUM"
end
function proto:SetFrameLevel(level) self.level = level end
function proto:GetFrameLevel() return self.level or 5 end
function proto:GetLeft() return 100 end
function proto:GetBottom() return 100 end
function proto:GetEffectiveScale() return 1 end
function proto:SetWidth(width) self.width = width end
function proto:GetWidth() return self.width or 100 end
function proto:SetHeight(height) self.height = height end
function proto:GetHeight() return self.height or 24 end
function proto:SetSize(width, height) self.width, self.height = width, height end
function proto:GetParent() return self.parent end
function proto:IsMouseOver() return false end
function proto:SetText(text) self.text = text end
function proto:GetText() return self.text end
function proto:SetTextColor(color) self.color = color end
function proto:SetWordWrap(on) self.wrap = on and true or false end

-- Six pixels a character, colour codes left out, and twelve a line.
function proto:GetStringWidth()
    local plain = tostring(self.text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return #plain * 6
end
function proto:GetStringHeight()
    if not self.wrap or not self.width then return 12 end
    return math.max(1, math.ceil(self:GetStringWidth() / self.width)) * 12
end

function proto:CreateTexture() return Frame("Texture", self) end
function proto:CreateFontString() return Frame("FontString", self) end

Frame = function(kind, parent, name)
    local frame = { kind = kind, parent = parent, children = {}, shown = true,
        scriptList = {}, attributes = {}, name = name, mouse = true }
    if parent then table.insert(parent.children, frame) end
    return setmetatable(frame, { __index = function(_, key)
        if proto[key] then return proto[key] end
        if type(key) == "string" and key:match("^%u") then return noop end
    end })
end

UIParent = Frame("Frame", nil, "UIParent")
CreateFrame = function(kind, name, parent) return Frame(kind, parent or UIParent, name) end
GameTooltip = Frame("GameTooltip", UIParent)

local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
local function RunTimers()
    local due = timers
    timers = {}
    for _, fn in ipairs(due) do fn() end
end

InCombatLockdown = function() return false end
GetTime = function() return 100 end
time = os.time
local knows = true
IsPlayerSpell = function() return knows end
IsSpellKnown, C_Spell, GetSpellInfo, C_SpellBook = nil, nil, nil, nil

-- Bag 0: a belt, boots, a crafted robe and a cloak.
local BELT, BOOTS, ROBE, CLOAK, DEAL = 5001, 5002, 5003, 5004, 5005
local bag0 = { [1] = BELT, [2] = BOOTS, [3] = ROBE, [4] = CLOAK }
C_Container = {
    GetContainerNumSlots = function(bag) return bag == 0 and 16 or 0 end,
    GetContainerItemID = function(bag, slot) return bag == 0 and bag0[slot] or nil end,
}

--------------------------------------------------------------------------------
-- The addon around the two tabs
--------------------------------------------------------------------------------

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = noop
ns.Print, ns.Warn, ns.Debug, ns.PrintRaw = noop, noop, noop, noop

local events = {}
ns.RegisterEvent = function(owner, event, fn)
    events[event] = events[event] or {}
    table.insert(events[event], { owner = owner, fn = fn })
    return true
end
local function Fire(event, ...)
    for _, handler in ipairs(events[event] or {}) do handler.fn(handler.owner, event, ...) end
end

ns.Util = {
    HasFunction = function(path)
        local value = _G
        for part in path:gmatch("[^.]+") do value = type(value) == "table" and value[part] or nil end
        return type(value) == "function"
    end,
    FormatMoney = function(copper) return tostring(copper or 0) end,
    FormatAge = function() return "1h" end,
    FormatAgeAgo = function() return "1h ago" end,
    GetItemLabel = function(itemID) return "item" .. tostring(itemID) end,
    ColorItemName = function(_, name) return name end,
    ColoredItemName = function(id) return "item" .. tostring(id) end,
    GetItemName = function(id, fallback) return fallback or ("item" .. tostring(id)) end,
    GetItemQualityColor = noop,
    Round = function(value) return value end,
}

local panels = {}
local function Label(parent) return Frame("FontString", parent) end
ns.Theme = {
    FitWhole = function(label, text) label:SetText(text); return 0, 13 end,
    SetRowLine = function(label, text) label:SetText(text) end,
    SetRowName = function(label, text) label:SetText(text) end,
    SetItemNameColor = function() return false end,
    FONT = "font", sizes = { tiny = 10, small = 11 },
    Fill = function(frame) return Frame("Texture", frame) end,
    Border = function(frame, key, alpha) frame.borderKey, frame.borderAlpha = key, alpha end,
    SetBorderColor = noop,
    CreateLabel = function(parent) return Label(parent) end,
    CreatePanel = function(parent, key)
        local panel = Frame("Frame", parent)
        if key == "window" then panels[#panels + 1] = panel end
        return panel
    end,
    CreateDivider = function(parent) return Frame("Texture", parent) end,
    CreateHeading = function(parent) return Label(parent) end,
    CreateItemIcon = function(parent) return Frame("Texture", parent) end,
    SetItemIcon = function(icon, itemID, link) icon.itemID, icon.link = itemID, link end,
    AccentStripe = function(parent) return Frame("Texture", parent) end,
    Unpack = function(key) return key end,
    ProfitColor = function(value) return (value or 0) >= 0 and "profit" or "loss" end,
    CreateMark = function(parent) return Frame("Texture", parent) end,
    SetMark = noop,
    -- Theme.CreateBar's shape: a plain table, not a frame.
    CreateBar = function(parent)
        local bar = { track = Frame("Texture", parent), fill = Frame("Texture", parent) }
        function bar:Set(value) self.value = value end
        function bar:SetPoint() end
        return bar
    end,
    SetMoneyText = function(label, copper) label:SetText(tostring(copper or 0)) end,
}

local made = { buttons = {}, dropdowns = {}, checkboxes = {}, lists = {}, strips = {} }
ns.Widgets = {
    CreateButton = function(parent, text, onClick)
        local button = Frame("Button", parent)
        button.label, button.onClick, button.enabled = text, onClick, true
        function button:SetEnabledState(on) self.enabled = on and true or false end
        made.buttons[#made.buttons + 1] = button
        return button
    end,
    CreateSearchBox = function(parent) return Frame("EditBox", parent) end,
    CreateNumberBox = function(parent)
        local box = Frame("Frame", parent)
        box.editBox = Frame("EditBox", box)
        return box
    end,
    CreateTabStrip = function(parent, tabs, onSelect)
        local strip = Frame("Frame", parent)
        strip.tabs, strip.onSelect = tabs, onSelect
        strip.Select = function(self, key) self.selected = key end
        made.strips[#made.strips + 1] = strip
        return strip
    end,
    CreateCheckbox = function(parent, text, onClick)
        local box = Frame("CheckButton", parent)
        box.label, box.onClick = text, onClick
        made.checkboxes[#made.checkboxes + 1] = box
        return box
    end,
    CreateDropdown = function(parent, _, onSelect)
        local dropdown = Frame("Frame", parent)
        dropdown.select = onSelect
        made.dropdowns[#made.dropdowns + 1] = dropdown
        return dropdown
    end,
    -- Remembers which rows were lit at the last draw.
    CreateScrollList = function(parent, opts)
        local list = Frame("Frame", parent)
        list.opts = opts
        function list:Refresh()
            self.lit = {}
            for index, entry in ipairs(self.data or {}) do self.lit[index] = opts.isSelected(entry) end
        end
        function list:SetData(data) self.data = data; self:Refresh() end
        made.lists[#made.lists + 1] = list
        return list
    end,
    ShowItemTooltip = function() return true end,
}

local tabs = {}
ns.UI = {
    RegisterTab = function(_, tab) tabs[tab.key] = tab end,
    RefreshActiveTab = noop,
    SearchAuctionHouse = function() return true end,
}

local function BagRow(itemID, name, gain, extra)
    local row = { kind = "bag", itemID = itemID, name = name, count = 1, value = 1000,
        sells = 1000 - gain, sellsAt = "auction", gain = gain, beatsSale = gain > 0,
        link = ("|cff1eff00|Hitem:%d::::::-12|h[%s of the Monkey]|h|r"):format(itemID, name),
        breakdown = { facts = { itemLevel = 20, qualityName = "uncommon", skill = 1 }, outcomes = {} } }
    for key, value in pairs(extra or {}) do row[key] = value end
    return row
end

local bagRows, craftRows, auctionRows = {}, {}, {}

ns.Disenchant = {
    GetBagRows = function(_, opts)
        if not (opts and opts.beatsOnly) then return bagRows end
        local out = {}
        for _, row in ipairs(bagRows) do if row.beatsSale then out[#out + 1] = row end end
        return out
    end,
    GetCraftRows = function() return craftRows end,
    GetMaterialRows = function() return {} end,
    GetAuctionRows = function() return auctionRows, 0, 0 end,
    GetBestEnchanter = function() return 300, "Me" end,
    WasRequested = function() return true end,
    IsDisenchantable = function(_, itemID) return itemID >= BELT and itemID <= DEAL end,
    LEARN_AFTER = 10,
}
ns.DisenchantLog = { GetSession = function() return 0, 0 end }
ns.Prices = { Count = function() return 1 end, changes = 0,
    GetAge = function() return 60 end, IsStale = function() return false end }
ns.Config = { Get = function() return 0 end }
ns.Scanner = { isAuctionHouseOpen = false }
ns.Inventory = { GetCarriedBags = function() return { 0 } end }
ns.Recipes = { Count = function() return 1 end, GetAll = function() return {} end,
    GetAccountWide = function() return {} end, IsDropped = function() return false end }
ns.Queue = { Add = noop }
ns.VendorFlips = {
    GetAuctionRows = function() return {}, 0, 0 end,
    GetResaleRows = function() return {}, 0, 0 end,
    MIN_RESALE_SCANS = 5,
}
ns.Auctions = { SetLimit = noop }

-- The Profit tab's crafts: a robe that can be disenchanted.
local craftRows = {}
ns.Profit = {
    GetRanked = function() return craftRows end,
    Analyse = function(_, recipeID)
        for _, analysis in ipairs(craftRows) do
            if analysis.recipeID == recipeID then return analysis end
        end
    end,
    GetMethod = function() return "best" end,
    MaxCrafts = function() return 1 end,
}

assert(loadfile(lfs_cwd .. "/UI/Disenchanter.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/UI/Columns.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/UI/Tab_Profit.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/UI/Tab_Disenchanting.lua"))("Blackthornes_TS", ns)

local Disenchanter = ns.Disenchanter
Disenchanter:OnEnable()

-- The window as UI/Main.lua builds it: one container per tab, shown before
-- the tab is drawn.
local window = Frame("Frame", UIParent, "BlackthornesTSWindow")
local content = Frame("Frame", window)
local containers = {}
for _, key in ipairs({ "profit", "disenchanting", "queue" }) do
    local container = Frame("Frame", content)
    container:Hide()
    containers[key] = container
    if tabs[key] then tabs[key].build(container) end
end

local function SelectTab(key)
    for other, container in pairs(containers) do container:SetShown(other == key) end
    if tabs[key] then tabs[key].refresh() end
end

--- The one widget of a kind made under a tab's container.
local function Under(key, list, match)
    for _, widget in ipairs(list) do
        local frame = widget.parent
        while frame and frame ~= containers[key] do frame = frame.parent end
        if frame and (not match or match(widget)) then return widget end
    end
end

local function Labelled(text)
    return function(widget) return widget.label == text end
end

local en = {
    button = Under("profit", made.buttons, Labelled("Disenchant")),
    list = Under("profit", made.lists),
    detail = Under("profit", panels),
}
local de = {
    button = Under("disenchanting", made.buttons, Labelled("Disenchant")),
    -- Pages since 2026-10-22; select() keeps the steps below readable.
    view = Under("disenchanting", made.strips),
    list = Under("disenchanting", made.lists),
    hideTooHigh = Under("disenchanting", made.checkboxes, Labelled("Only ones I can disenchant")),
    detail = Under("disenchanting", panels),
}

de.view.select = function(value) de.view.onSelect(value) end

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

--- The item the secure button would disenchant now, or nil when it is down.
local function Armed()
    local overlay = Disenchanter.overlay
    if overlay and overlay:IsShown() then return Disenchanter.itemID end
    return nil
end

--- Click a row of a tab's list, the way the list does.
local function ClickRow(tab, itemID)
    for _, entry in ipairs(tab.list.data or {}) do
        if entry.itemID == itemID or entry.outputItemID == itemID then
            tab.list.opts.onClick(entry, 1, "LeftButton")
            tab.list:Refresh()
            return entry
        end
    end
    error("no row for item " .. tostring(itemID))
end

check("both tabs found their Disenchant button", en.button and de.button and en.button ~= de.button)

--------------------------------------------------------------------------------
print("\na redraw queued by a tab the player has left")
--------------------------------------------------------------------------------

bagRows = { BagRow(BELT, "Belt", 800), BagRow(BOOTS, "Boots", 200) }
craftRows[1] = { recipeID = 77, outputItemID = ROBE, name = "Robe", priceable = true, totalCost = 50,
    revenue = 100, unitRevenue = 100, profit = 50, margin = 1, disenchantable = true,
    disenchantValue = 900, disenchantBeatsSale = true, craftableNow = 1 }

window:Show()
SelectTab("disenchanting")
de.view.select("bag")
check("the Disenchanting bags list sets the button on its top item", Armed() == BELT
    and Disenchanter.anchor == de.button)

-- An item the addon asked for arrives, and the tab queues a redraw.
Fire("GET_ITEM_INFO_RECEIVED", 777, true)
check("the Disenchanting tab queued its redraw", #timers == 1)

-- The player moves to the Profit tab and picks a robe they carry.
SelectTab("profit")
ClickRow(en, ROBE)
check("the Profit tab's button is set on the robe", Armed() == ROBE and Disenchanter.anchor == en.button)

RunTimers()
check("the hidden tab's redraw leaves it there", Armed() == ROBE and Disenchanter.anchor == en.button)
check("a hidden tab's button cannot take it", Disenchanter:Arm(de.button, BELT, 0, 1) == false
    and Armed() == ROBE)

SelectTab("queue")
check("moving to another tab takes the button away", not Disenchanter.overlay:IsShown())

SelectTab("profit")
check("coming back sets it again", Armed() == ROBE)
window:Hide()
check("closing the window takes it away", not Disenchanter.overlay:IsShown())

-- The other way round: a craft on the Profit tab, then the bags on the
-- Disenchanting tab.
window:Show()
SelectTab("profit")
ClickRow(en, ROBE)
check("a carried craft sets the button on the robe", Armed() == ROBE)

Fire("GET_ITEM_INFO_RECEIVED", 778, true)
SelectTab("disenchanting")
check("the Disenchanting tab sets it on its own pick", Armed() == BELT and Disenchanter.anchor == de.button)
RunTimers()
check("the Profit tab's late redraw does not aim it at the robe", Armed() == BELT
    and Disenchanter.overlay:GetAttribute("target-slot") == 1)

--------------------------------------------------------------------------------
print("\nwhich item the bags lists pick")
--------------------------------------------------------------------------------

-- Choosing the view again clears the pick, so the list picks afresh.
de.view.select("auction")
de.view.select("bag")
check("the top item worth more disenchanted is picked", Armed() == BELT)
check("and its row is lit as soon as it is picked", de.list.lit[1] == true and de.list.lit[2] == false)

-- Everything left sells for more than it disenchants for.
bagRows = { BagRow(BOOTS, "Boots", -100), BagRow(CLOAK, "Cloak", -300) }
tabs.disenchanting.refresh()
check("nothing that sells for more is picked for you", Armed() == nil)
check("the button shows, unset", de.button:IsShown() and de.button.enabled == false)
check("and the line beside it says why", de.detail.disenchantStatus:IsShown()
    and de.detail.disenchantStatus.text
        == "Nothing here is worth more disenchanted than sold. Click one to disenchant it anyway.")
check("so does its tooltip", de.button.tooltipText == de.detail.disenchantStatus.text)

ClickRow(de, CLOAK)
check("a click on one still sets the button on it", Armed() == CLOAK and de.button.enabled == true)
tabs.disenchanting.refresh()
check("and it stays there through a redraw", Armed() == CLOAK)

-- The cloak is disenchanted and leaves the bags; only the boots are left.
bagRows = { BagRow(BOOTS, "Boots", -100) }
tabs.disenchanting.refresh()
check("the boots do not take its place", Armed() == nil and de.button.enabled == false)

SelectTab("profit")
--------------------------------------------------------------------------------
print("\na craft whose Disenchant button cannot be used")
--------------------------------------------------------------------------------

knows = false
ClickRow(en, ROBE)
check("the button shows, unset", en.button:IsShown() and en.button.enabled == false and Armed() == nil)
check("and its tooltip says why", en.button.tooltipText == "This character does not know Disenchant.")
knows = true
ClickRow(en, ROBE)
check("once it can be used, it is set", en.button:IsShown() and en.button.enabled == true
    and Armed() == ROBE)

bag0[3] = nil
ClickRow(en, ROBE)
check("a craft not in the bags has no button", not en.button:IsShown() and Armed() == nil)
bag0[3] = ROBE

--------------------------------------------------------------------------------
print("\nthe Disenchanting tab with every deal hidden")
--------------------------------------------------------------------------------

SelectTab("disenchanting")
de.view.select("auction")
auctionRows = { { kind = "auction", itemID = DEAL, name = "Listed Chest", value = 800, buy = 500,
    net = 760, gain = 260, margin = 0.52, needs = 250, canDisenchant = false,
    breakdown = { facts = {}, outcomes = {} } } }
ns.Prices.changes = 1
de.hideTooHigh.onClick(true)

local emptyLabel
for _, frame in ipairs(containers.disenchanting.children) do
    if frame.kind == "FontString" and frame.shown and type(frame.text) == "string"
        and frame.text:find("Untick") then emptyLabel = frame end
end
check("it names the tick box that hid them", emptyLabel and emptyLabel.text
    == "None of your characters can disenchant the 1 item found yet. Untick \"Only ones I can disenchant\" to see it.")
de.hideTooHigh.onClick(false)
check("unticked, the deal is listed", #de.list.data == 1)

--------------------------------------------------------------------------------
print("\nwhat an item breaks into")
--------------------------------------------------------------------------------

de.view.select("bag")
bagRows = { BagRow(BELT, "Belt", 800, { breakdown = { facts = {}, outcomes = {
    { itemID = 16203, name = "Greater Eternal Essence", chance = 0.225, min = 1, max = 2, price = 123456 },
    { itemID = 10940, name = "Dust", chance = 0.75, min = 1, max = 1, price = 5 },
} } }) }
tabs.disenchanting.refresh()

local wide, short = de.detail.outcomeLines[1], de.detail.outcomeLines[2]
-- "123456 each" is 66 pixels here, so the name has 276 - 18 - 6 - 66.
check("a name gets the room its price leaves", wide.name.width == 186)
check("and wraps, the line growing to fit", wide.name.wrap == true and wide.frame.height == 26)
check("a short one keeps one line", short.frame.height == 16)

--------------------------------------------------------------------------------
print("\nbag rows and the upgrade arrow")
--------------------------------------------------------------------------------

local function DrawnIcon(tab, entry)
    local row = Frame("Button", tab.list)
    tab.list.opts.createRow(row)
    tab.list.opts.updateRow(row, entry)
    return row.icon
end

local belt = de.list.data[1]
check("a Disenchanting bag row hands its link to the icon", DrawnIcon(de, belt).link == belt.link)
check("and so does the detail panel", de.detail.icon.link == belt.link)

--------------------------------------------------------------------------------
print("\nhow the secure button looks")
--------------------------------------------------------------------------------

check("it wears the primary button's gold edge", Disenchanter.overlay.borderKey == "accent"
    and Disenchanter.overlay.borderAlpha == 0.55)

window:Hide()
for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print(("\n%d check(s) passed\n"):format(checks))
