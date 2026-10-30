-- Words fitted to their room, and the layout fixes that came with them,
-- outside WoW.
--
-- What must hold:
--   1. A label takes the longest wording that fits it, and a money cell drops
--      to fewer coins, measured past the label's own width (a retail client
--      reports no more than a fixed-width label draws).
--   2. Tabs given no width are as wide as their names, all twelve inside the
--      window, a step smaller when they do not fit at full size. The gold
--      line rides above the tabs, and a hover line never lights under the tab
--      showing.
--   3. A dropdown's face shows the first option's name from the start, even
--      when its value is nil ("All professions"). A long menu shows twelve
--      rows and scrolls, opens with the choice in view, and opens upward near
--      the foot of the screen. A narrow box drops its "Show: " lead-in.
--   4. A list's thumb is as long as the share on screen, and a row's tooltip
--      follows the row under the mouse as the list scrolls.
--   5. A held button's fill sinks a shade; the collapse button draws its
--      plus and minus.
--   6. The minimap button starts at 170 degrees, clear of Farmer's at 200,
--      and keeps a saved angle. Its icon swells under the mouse and dips
--      when pressed.
--   7. The auction house bar's status line fits its room, with the whole of
--      it a hover away. The transfer dialog's code scrolls.
--   8. Settings: pages along the top, descriptions as tooltips until Show
--      descriptions is ticked, and a search that finds a setting on any page.
--      A redraw leaves a number being typed alone; Clear price data
--      (typed now) clears the page-limit stamp; Reset puts the side panels
--      right.
--   9. Prices: a new search, filter or sort starts at the top, and a redraw
--      keeps the place. "now" for an age under a minute.
--  10. Characters: each side under its heading, the side playing first;
--      two professions and how many more, the tooltip lists them all; a
--      click opens the best crafts, leaving out a dropped profession's.

-- Tests share one Lua state, so every global replaced here is put back,
-- including the ones that were not set at all.
local GLOBALS = { "CreateFrame", "UIParent", "CreateColor", "GameTooltip", "Minimap", "GetTime",
    "time", "C_Timer", "UISpecialFrames", "tinsert" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local function noop() end

--- The words a label draws, without colour codes.
local function Plain(text)
    return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

--- Characters, not bytes: the dot between professions is two bytes.
local function Length(text)
    return #(Plain(text):gsub("[\128-\191]", ""))
end

-- Frames, textures and font strings in one. Words are half their font size
-- wide per character. GetStringWidth stops at a fixed-width label's width,
-- as a retail client's can; GetUnboundedStringWidth measures all of it.
local function Region(parent, frameType)
    local level = type(parent) == "table" and rawget(parent, "frameLevel") or 0
    local region = { frameType = frameType, parent = parent, shown = true, alpha = 1,
        width = 0, height = 0, points = {}, scripts = {}, events = {}, children = {},
        textures = {}, strings = {}, fontSize = 12, wrap = false, frameLevel = level + 1 }

    region.Show = function(self)
        local was = self.shown
        self.shown = true
        if not was and self.scripts.OnShow then self.scripts.OnShow(self) end
    end
    region.Hide = function(self)
        local was = self.shown
        self.shown = false
        if was and self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    region.SetShown = function(self, on) if on then self:Show() else self:Hide() end end
    region.IsShown = function(self) return self.shown end
    region.IsVisible = function(self) return self.shown end
    region.SetAlpha = function(self, a) self.alpha = a end
    region.GetAlpha = function(self) return self.alpha end
    region.SetWidth = function(self, w) self.width = w end
    region.SetHeight = function(self, h) self.height = h end
    region.GetWidth = function(self) return self.width end
    region.GetHeight = function(self) return self.height end
    region.SetSize = function(self, w, h) self.width, self.height = w, h end
    region.SetColorTexture = function(self, r, g, b, a) self.color = { r, g, b, a or 1 } end
    region.SetGradient = function(self, orientation, from, to) self.gradient = { orientation, from, to } end
    region.SetTexture = function(self, path) self.texture = path end
    region.SetTextColor = function(self, r, g, b, a) self.textColor = { r, g, b, a } end
    region.SetFont = function(self, _, size) self.fontSize = size end
    region.SetText = function(self, text) self.text = text end
    region.GetText = function(self) return self.text end
    region.SetWordWrap = function(self, on) self.wrap = on and true or false end
    region.GetUnboundedStringWidth = function(self) return Length(self.text) * self.fontSize / 2 end
    region.GetStringWidth = function(self)
        local width = self:GetUnboundedStringWidth()
        if self.width > 0 and width > self.width then return self.width end
        return width
    end
    region.GetStringHeight = function(self)
        local width = self:GetUnboundedStringWidth()
        if width == 0 then return 0 end
        local lines = (self.wrap and self.width > 0) and math.ceil(width / self.width) or 1
        return lines * (self.fontSize + 2)
    end
    region.SetScript = function(self, name, fn) self.scripts[name] = fn end
    region.GetScript = function(self, name) return self.scripts[name] end
    region.HookScript = function(self, name, fn)
        local old = self.scripts[name]
        self.scripts[name] = function(...)
            if old then old(...) end
            fn(...)
        end
    end

    -- As the game does: the short forms fill in the parent and the same
    -- point, and setting a point the region already has moves that one.
    region.SetPoint = function(self, point, a, b, c, d)
        local relativeTo, relativePoint, x, y
        if a == nil or type(a) == "number" then
            relativeTo, relativePoint, x, y = self.parent, point, a or 0, b or 0
        elseif type(b) == "string" then
            relativeTo, relativePoint, x, y = a, b, c or 0, d or 0
        else
            relativeTo, relativePoint, x, y = a, point, b or 0, c or 0
        end

        local anchor = { point, relativeTo, relativePoint, x, y }
        for index, existing in ipairs(self.points) do
            if existing[1] == point then
                self.points[index] = anchor
                return
            end
        end
        self.points[#self.points + 1] = anchor
    end
    region.ClearAllPoints = function(self) self.points = {} end
    region.GetNumPoints = function(self) return #self.points end
    region.GetPoint = function(self, index)
        local p = self.points[index or 1]
        if not p then return nil end
        return p[1], p[2], p[3], p[4], p[5]
    end

    region.IsMouseOver = function(self) return self.mouseOver == true end
    region.RegisterEvent = function(self, event) self.events[event] = true end
    region.UnregisterEvent = function(self, event) self.events[event] = nil end
    region.CreateTexture = function(self)
        local texture = Region(self, "Texture")
        self.textures[#self.textures + 1] = texture
        return texture
    end
    region.CreateFontString = function(self)
        local label = Region(self, "FontString")
        self.strings[#self.strings + 1] = label
        return label
    end
    region.GetParent = function(self) return self.parent end
    region.GetFrameLevel = function(self) return self.frameLevel end
    region.SetFrameLevel = function(self, value) self.frameLevel = value end
    region.GetEffectiveScale = function() return 1 end
    region.GetTop = function(self) return rawget(self, "top") end
    region.GetBottom = function(self) return rawget(self, "bottom") end
    region.GetChildren = function(self) return unpack(self.children) end

    -- Sliders: a value kept inside its range, and a change reported.
    region.GetMinMaxValues = function(self) return self.min or 0, self.max or 0 end
    region.SetMinMaxValues = function(self, lo, hi)
        self.min, self.max = lo, hi
        if self.value then self:SetValue(self.value) end
    end
    region.GetValue = function(self) return self.value or 0 end
    region.SetValue = function(self, v)
        if type(self.min) == "number" and v < self.min then v = self.min end
        if type(self.max) == "number" and v > self.max then v = self.max end
        local changed = v ~= self.value
        self.value = v
        if changed and self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v) end
    end
    region.SetThumbTexture = function(self, thumb) self.thumb = thumb end

    -- Scroll frames.
    region.GetVerticalScroll = function(self) return self.verticalScroll or 0 end
    region.SetVerticalScroll = function(self, value) self.verticalScroll = value end
    region.GetVerticalScrollRange = function(self) return self.scrollRange or 0 end

    -- Edit boxes keep the keyboard the game's way: only SetFocus and
    -- ClearFocus change it, and losing it runs OnEditFocusLost.
    region.SetFocus = function(self) self.focus = true end
    region.HasFocus = function(self) return self.focus == true end
    region.ClearFocus = function(self)
        if not self.focus then return end
        self.focus = false
        if self.scripts.OnEditFocusLost then self.scripts.OnEditFocusLost(self) end
    end

    -- Any other method does nothing. Fields read as nil, as on a real frame.
    return setmetatable(region, { __index = function(_, key)
        if type(key) == "string" and key:match("^%u") then return noop end
    end })
end

CreateFrame = function(frameType, _, parent)
    local frame = Region(parent, frameType)
    if type(parent) == "table" and rawget(parent, "children") then
        parent.children[#parent.children + 1] = frame
    end
    return frame
end
UIParent = Region()
UIParent.top = 768
CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end

GameTooltip = Region()
GameTooltip.shown = false
GameTooltip.lines = {}
GameTooltip.SetOwner = function(self, owner) self.owner, self.lines = owner, {} end
GameTooltip.IsOwned = function(self, frame) return self.owner == frame end
GameTooltip.SetText = function(self, text) self.text, self.lines = text, { text } end
GameTooltip.AddLine = function(self, text) self.lines[#self.lines + 1] = text end
GameTooltip.NumLines = function(self) return #self.lines end
GameTooltip.Show = function(self) self.shown = true end
GameTooltip.Hide = function(self) self.shown, self.owner = false, nil end

Minimap = Region()
Minimap.width = 140

local NOW = 1000000
local clock = 5000
time = function() return NOW end
GetTime = function() return clock end
C_Timer = { After = noop, NewTicker = function() return { Cancel = noop } end }
UISpecialFrames = {}
tinsert = table.insert

--------------------------------------------------------------------------------
-- The addon around the files under test
--------------------------------------------------------------------------------

local settings = {}
local records = {}
local lastScan, capped, scanStatus
local characters = {}
local analysed = {}
local calls = {}

local function Count(name) calls[name] = (calls[name] or 0) + 1 end

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = ns[name] or {}; ns[name] = m; return m end
ns.RegisterCommand = noop
ns.RegisterEvent = function() return true end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = noop, noop, noop, noop

ns.db = { global = {}, characters = {}, prices = {}, postLimits = {} }
ns.Config = {
    DEFAULTS = { settings = { undercutCopper = 1, postPanelCollapsed = false, craftPaneCollapsed = false } },
    Get = function(_, key) return settings[key] end,
    Set = function(_, key, value) settings[key] = value end,
    GetRealmKey = function() return "Forever" end,
    GetLoadDiagnostics = function() return { globalType = "table" } end,
    IsFirstRun = function() return false end,
}

ns.Prices = {
    GetTable = function() return records end,
    Get = function(_, itemID) return records[itemID] end,
    GetAge = function(_, itemID)
        local record = records[itemID]
        return record and record.seen and (NOW - record.seen)
    end,
    GetSalesPerDay = function() return nil end,
    IsStale = function() return false end,
    Count = function()
        local count = 0
        for _ in pairs(records) do count = count + 1 end
        return count
    end,
    GetLastScan = function() return lastScan, capped end,
    GetConfidence = function() return 1, nil end,
    HoldsLowest = function() return true end,
    Prune = function() return 0 end,
}

-- One recipe made from every priced item, so "Only what I craft with" keeps
-- them all.
local everyItem = {}
for index = 1, 40 do everyItem[index] = { itemID = 1000 + index } end

ns.Recipes = {
    GetAll = function() return { { reagents = everyItem } } end,
    Count = function() return 0 end,
    GetCharacters = function() return characters end,
    IsDropped = function(_, recipe, key) return key == "A" and recipe.skillLineID == 197 end,
    ForgetCharacter = noop,
}

ns.Profit = {
    Analyse = function(_, recipeID)
        analysed[#analysed + 1] = recipeID
        return { priceable = true, profit = 4123, name = "Craft " .. recipeID, craftableNow = 1,
            recipeID = recipeID }
    end,
}

ns.VersionLabel = function() return "v0.42.0" end
ns.Scanner = {
    isAuctionHouseOpen = false,
    GetScanStatus = function() return scanStatus end,
    CanFullScan = function() return true end,
    GetSnapshotCooldown = function() return nil end,
}
ns.Auctions = { GetAge = function() return nil end }
ns.Inventory = { GetBankAge = function() return nil end }
ns.Queue = { RebuildDependencies = function() Count("rebuild") end, Notify = function() Count("notify") end }
ns.RecipeValue = { Refresh = function() Count("recipeValue") end }
ns.SisterNote = { IsOn = function() return true end, SetOn = noop }
ns.Transfer = {
    Export = function() return "CODE" end,
    Describe = function() return 1, 2, 3 end,
    Import = function() return true, "imported" end,
}

local function Load(path)
    assert(loadfile(lfs_cwd .. path))("Blackthornes_TS", ns)
end

Load("/Core/Util.lua")
Load("/UI/TooltipShift.lua")
Load("/UI/Theme.lua")
Load("/UI/Widgets.lua")
Load("/UI/HouseKit.lua")
Load("/UI/Columns.lua")
Load("/UI/Collapse.lua")
Load("/UI/PriceGraph.lua")
Load("/UI/Main.lua")
Load("/UI/Tab_Prices.lua")
Load("/UI/Tab_Characters.lua")
Load("/UI/Tab_Settings.lua")

local Theme, Widgets, Motion, UI = ns.Theme, ns.Widgets, ns.Motion, ns.UI

-- The tabs keep their controls to themselves; these keep a copy of each one
-- made, in the order made, and the buttons by their words.
local made, buttons, allButtons = {}, {}, {}
for _, name in ipairs({ "CreateScrollList", "CreateSearchBox", "CreateCheckbox", "CreateDropdown",
                         "CreateNumberBox", "SortableHeadings" }) do
    local real = Widgets[name]
    made[name] = {}
    Widgets[name] = function(...)
        local widget = real(...)
        table.insert(made[name], widget)
        return widget
    end
end
do
    local real = Widgets.CreateButton
    Widgets.CreateButton = function(parent, text, ...)
        local button = real(parent, text, ...)
        buttons[text] = button
        allButtons[#allButtons + 1] = button
        return button
    end
end

local passed, failed = 0, 0

local function check(label, got, want)
    local ok = got == want
    if ok then passed = passed + 1 else failed = failed + 1 end
    print(string.format("  %-64s %-12s %s", label, tostring(got), ok and "ok" or
        ("WRONG, wanted " .. tostring(want))))
end

local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-6 end

local function Same(color, key)
    local r, g, b = Theme.Unpack(key)
    return color ~= nil and near(color[1], r) and near(color[2], g) and near(color[3], b)
end

local function Shown(frames)
    local count = 0
    for _, frame in ipairs(frames) do if frame.shown then count = count + 1 end end
    return count
end

--------------------------------------------------------------------------------
print("")
print("fitting words")

local cell = Theme.CreateLabel(Region(), "small", "text", "RIGHT")
cell:SetWidth(50)
Theme.SetMoneyText(cell, 123456, { short = true })
check("a money cell too narrow for every coin drops one", Plain(cell.text), "12g 35s")
cell:SetWidth(80)
Theme.SetMoneyText(cell, 123456, { short = true })
check("with room, every coin", Plain(cell.text), "12g 34s 56c")

cell:SetText("a line of words wider than its label")
check("the client's own measure stops at the label's width", cell:GetStringWidth(), 80)
check("TextWidth measures the whole of it", Theme.TextWidth(cell), 36 * 5.5)

local line = Theme.CreateLabel(Region(), "tiny", "muted")
line:SetWidth(100)
check("FitText takes the first wording that fits",
    Theme.FitText(line, { "a much longer wording than this line has room for", "a short one" }), "a short one")
check("and puts it on the label", line.text, "a short one")
check("when none fits, the last and shortest",
    Theme.FitText(line, { string.rep("x", 40), string.rep("y", 30) }), string.rep("y", 30))
check("given the room, it measures to that",
    Theme.FitText(line, { "twenty-one characters", "short" }, 60), "short")
local loose = Theme.CreateLabel(Region(), "tiny", "muted")
check("a label with no width to fit gets the first",
    Theme.FitText(loose, { "the whole wording", "short" }), "the whole wording")

--------------------------------------------------------------------------------
print("")
print("the tabs")

-- Every tab the window has, in its order. The room is the window's: 1120 wide,
-- less its 11-pixel edges and 16 more.
local NAMES = { "Profit", "Level Up", "Disenchanting", "Deals", "Queue", "Gather", "Post", "Prices",
    "Sales", "Characters", "Settings" }
local ROOM = 1120 - 2 * 11 - 16

local function Definitions()
    local definitions = {}
    for index, name in ipairs(NAMES) do definitions[index] = { key = name, text = name } end
    return definitions
end

local function Total(strip)
    local total = 0
    for _, tab in ipairs(strip.tabs) do total = total + tab.span end
    return total
end

local function Roomy(strip)
    for _, tab in ipairs(strip.tabs) do
        if tab.span < Theme.TextWidth(tab.label) + 20 then return false end
    end
    return true
end

local strip = Widgets.CreateTabStrip(Region(), Definitions(), nil, { width = ROOM })
check("all eleven fit across the window", Total(strip) <= ROOM, true)
check("at the full size", strip.tabs[4].label.fontSize, 12)
check("each with room either side of its name", Roomy(strip), true)
check("a long name gets a wider tab than a short one", strip.tabs[10].span > strip.tabs[7].span, true)
check("each starts where the last ended", strip.tabs[5].left, strip.tabs[4].left + strip.tabs[4].span)

-- Less room than the eleven names take at the full size.
local TIGHT = 700
local tight = Widgets.CreateTabStrip(Region(), Definitions(), nil, { width = TIGHT })
check("short of room, a step smaller", tight.tabs[4].label.fontSize, 11)
check("and still all inside it", Total(tight) <= TIGHT, true)
check("names still inside their tabs", Roomy(tight), true)

local realTextWidth = Theme.TextWidth
Theme.TextWidth = function() return nil end
local blind = Widgets.CreateTabStrip(Region(), Definitions(), nil, { width = ROOM })
Theme.TextWidth = realTextWidth
check("names that cannot be measured share the room equally, up to 96 each", blind.tabs[4].span,
    math.min(96, math.floor(ROOM / #NAMES)))

local fixed = Widgets.CreateTabStrip(Region(), {
    { key = "sell", text = "Sell", width = 120 }, { key = "buy", text = "Buy", width = 120 } })
check("tabs given a width keep it", fixed.tabs[2].left + fixed.tabs[2].span, 240)

check("the gold line rides on a layer of its own", strip.line:GetParent() == strip.lineLayer, true)
check("above the tabs, whose fill hid it", strip.lineLayer.frameLevel > strip.tabs[1].frameLevel, true)

strip:Select("Characters")
Motion:Step(1)
local _, under = strip.line:GetPoint(1)
check("it lands under a wide tab", under == strip.tabs[10], true)
check("as wide as that tab", near(strip.line.width, strip.tabs[10].span), true)

local other = strip.tabs[7]
other.scripts.OnEnter(other)
Motion:Step(1)
check("another tab under the mouse shows a faint line", other.underline.alpha, 1)
other.scripts.OnLeave(other)
Motion:Step(1)
check("which goes when the mouse does", other.underline.alpha, 0)

local showing = strip.tabs[10]
showing.scripts.OnEnter(showing)
Motion:Step(1)
check("the tab showing never lights a line of its own", showing.underline.alpha, 0)

other.scripts.OnEnter(other)
Motion:Step(0.05)
strip:Select("Prices")
check("a tab picked while lit drops its hover line", other.underline.alpha, 0)
Motion:FinishAll()

--------------------------------------------------------------------------------
print("")
print("dropdowns")

local profession = Widgets.CreateDropdown(Region(), {
    { text = "All professions", value = nil },
    { text = "Tailoring", value = 197 },
}, nil, { width = 150 })
local face = profession.strings[1]
check("a first option with no value names itself from the start", face.text, "All professions")
profession:SetValue(197)
profession:SetOptions({ { text = "All professions", value = nil }, { text = "Tailoring 300", value = 197 } })
check("an option renamed is redrawn on the box", face.text, "Tailoring 300")
profession:SetOptions({ { text = "All professions", value = nil } })
check("a choice taken away falls back to the first", face.text, "All professions")
check("and the value with it", profession:GetValue(), nil)

--- The slim bar down a menu's right edge.
local function MenuThumb(dropdown)
    for _, texture in ipairs(dropdown.menu.textures) do
        if texture.width == 3 then return texture end
    end
end

local many = {}
for index = 1, 30 do many[index] = { text = "Character " .. index, value = index } end
local long = Widgets.CreateDropdown(Region(), many, nil, { width = 160 })
local entries = long.menu.children
check("an entry for each option", #entries, 30)
check("only twelve of them placed", Shown(entries), 12)

local thumb = MenuThumb(long)

long:SetValue(25)
long.scripts.OnMouseDown(long)
Motion:FinishAll()
check("a long menu is twelve rows tall", long.menu.height, 12 * 20 + 8)
check("and opens with the choice in view", entries[25].shown, true)
check("as far down as the list goes", entries[19].shown and entries[30].shown and not entries[18].shown, true)
check("the choice wears the gold edge", entries[25].mark.shown, true)
check("a bar down its edge says where it is", thumb ~= nil and thumb.shown, true)
check("at the foot of its track", select(5, thumb:GetPoint(1)), -4 - (240 - 96))

long.menu.scripts.OnMouseWheel(long.menu, 1)
check("the wheel moves it up a row", entries[18].shown and not entries[30].shown, true)
for _ = 1, 40 do long.menu.scripts.OnMouseWheel(long.menu, 1) end
check("no further than the first", entries[1].shown and not entries[13].shown, true)
check("still twelve", Shown(entries), 12)
for _ = 1, 40 do long.menu.scripts.OnMouseWheel(long.menu, -1) end
check("and down no further than the last", entries[30].shown and not entries[18].shown, true)
check("opened with no place on screen known, it drops down", long.menu.points[1][1], "TOPLEFT")

long.scripts.OnMouseDown(long)
long.bottom, long.top = 30, 52
long.scripts.OnMouseDown(long)
check("near the foot of the screen it opens upward", long.menu.points[1][1], "BOTTOMLEFT")
check("from the top of the box", long.menu.points[1][2] == long and long.menu.points[1][3], "TOPLEFT")
long.scripts.OnMouseDown(long)
long.bottom, long.top = 600, 622
long.scripts.OnMouseDown(long)
check("with room below, down as before", long.menu.points[1][1], "TOPLEFT")
long.scripts.OnMouseDown(long)

-- A group heading in a menu (Recipes to learn, 2026-10-07).
local grouped = Widgets.CreateDropdown(Region(), {
    { text = "Other professions", header = true },
    { text = "Tailoring", value = 197 },
}, nil, { width = 150 })
check("a heading is never the fall back", grouped:GetValue(), 197)
grouped.scripts.OnMouseDown(grouped)
local headingEntry = grouped.menu.children[1]
headingEntry.scripts.OnClick(headingEntry)
check("clicking a heading picks nothing", grouped:GetValue(), 197)
check("and leaves the menu open", grouped.menu.shown, true)
grouped.scripts.OnMouseDown(grouped)

-- More than one ticked at once (the Deals tab's Sell to, 2026-10-07).
local picked
local multi = Widgets.CreateDropdown(Region(), {
    { text = "Auction house", value = "auction" },
    { text = "Disenchant", value = "disenchant" },
    { text = "Vendor", value = "vendor" },
}, function(set) picked = set end, { width = 160, multi = true,
    summary = function(set) return set.vendor and "Sell to: has Vendor" or "Sell to: no Vendor" end })
multi:SetValue({ auction = true, vendor = true })
check("a multiple choice box shows its summary", multi.strings[1].text, "Sell to: has Vendor")
multi.scripts.OnMouseDown(multi)
local vendorEntry = multi.menu.children[3]
vendorEntry.scripts.OnClick(vendorEntry)
check("a click unticks one", picked and picked.vendor == nil and picked.auction == true, true)
check("and the menu stays open for the next", multi.menu.shown, true)
check("the box says so", multi.strings[1].text, "Sell to: no Vendor")
check("a ticked one wears the gold edge", multi.menu.children[1].mark.shown, true)
check("an unticked one does not", vendorEntry.mark.shown, false)
local given = multi:GetValue()
given.disenchant = true
check("the set handed out is a copy", multi:GetValue().disenchant, nil)
multi.scripts.OnMouseDown(multi)

local short = Widgets.CreateDropdown(Region(), many, nil, { width = 160 })
short:SetOptions({ many[1], many[2], many[3] })
short.scripts.OnMouseDown(short)
check("a short menu is as tall as its options", short.menu.height, 3 * 20 + 8)
check("with no bar", MenuThumb(short).shown, false)
short.scripts.OnMouseDown(short)

local view = Widgets.CreateDropdown(Region(), {
    { text = "Show: Deals on the auction house", value = "auction" },
    { text = "Show: Items in your bags", value = "bag" },
}, nil, { width = 170 })
check("a box too narrow drops the \"Show: \" lead-in", view.strings[1].text, "Deals on the auction house")
view:SetValue("bag")
check("and keeps it when it fits", view.strings[1].text, "Show: Items in your bags")

--------------------------------------------------------------------------------
print("")
print("lists")

local entered = {}
local list = Widgets.CreateScrollList(Region(), {
    rowHeight = 20,
    onEnter = function(row, entry)
        entered[#entered + 1] = entry.itemID
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        GameTooltip:SetText("item " .. entry.itemID)
        GameTooltip:Show()
    end,
    onLeave = function() GameTooltip:Hide() end,
})
list.height = 100

local function Items(count)
    local data = {}
    for index = 1, count do data[index] = { itemID = 100 + index } end
    return data
end

list:SetData(Items(20))
check("the thumb is as long as the share on screen", list.scrollbar.thumb.height, 25)
list:SetData(Items(200))
check("never shorter than a grip", list.scrollbar.thumb.height, 20)
list:SetData(Items(20))

local row = list.rows[2]
row.mouseOver = true
row.scripts.OnEnter(row)
check("hovering a row shows its item", GameTooltip.text, "item 102")
list.scripts.OnMouseWheel(list, -1)
check("scrolled under the mouse, the tooltip follows the row", GameTooltip.text, "item 105")
check("drawn for that item once", entered[#entered], 105)

local drawn = #entered
list:SetData(Items(20))
check("a redraw of the same items draws nothing again", #entered, drawn)

GameTooltip:SetOwner(Region(), "ANCHOR_TOP")
list.scripts.OnMouseWheel(list, -1)
check("a tooltip something else took is left alone", #entered, drawn)

row.scripts.OnLeave(row)
row.mouseOver = false
list.scripts.OnMouseWheel(list, 1)
check("after the mouse leaves, nothing is drawn", #entered, drawn)

--------------------------------------------------------------------------------
print("")
print("buttons")

local held = Widgets.CreateButton(Region(), "Queue all", noop)
held.scripts.OnMouseDown(held)
local down = held.background.color
local r, g, b = Theme.Unpack("row")
check("a held button's fill sinks a shade", down[1] < r and down[2] < g and down[3] < b, true)
held.scripts.OnMouseUp(held)
check("and comes back on release", Same(held.background.color, "row"), true)
held.scripts.OnMouseDown(held)
held:Hide()
check("or when the button hides mid-press", Same(held.background.color, "row"), true)

local dead = Widgets.CreateButton(Region(), "Buy", noop)
dead:SetEnabledState(false)
dead.scripts.OnMouseDown(dead)
check("a disabled button does not press", Same(dead.background.color, "panel"), true)

local panel, header = Region(), Region()
local body = Region(panel)
local foldTitle = Theme.CreateLabel(header, "normal", "accent")
local fold = ns.Collapse.Attach(panel, { key = "testFold", header = header, title = foldTitle, body = body })
check("the collapse button draws its sign rather than a letter", fold.label.text, "")
check("a minus while open", fold.glyph.bar.shown and not fold.glyph.stem.shown, true)
fold.scripts.OnClick(fold, "LeftButton")
check("a plus once folded", fold.glyph.stem.shown, true)
check("and the panel folds", body.shown, false)
fold.scripts.OnClick(fold, "LeftButton")
check("a minus again when opened", fold.glyph.stem.shown, false)

--------------------------------------------------------------------------------
print("")
print("the minimap button")

local function Angle(button)
    local _, relativeTo, _, x, y = button:GetPoint(1)
    if relativeTo ~= Minimap then return nil end
    return math.floor(math.deg(math.atan2(y, x)) + 0.5)
end

UI:BuildMinimapButton()
local minimapButton = UI.minimapButton
check("it starts at 170 degrees, clear of Farmer's at 200", Angle(minimapButton), 170)
ns.db.minimapAngle = math.rad(45)
UI:RepositionMinimapButton()
check("a saved angle is kept as it is", Angle(minimapButton), 45)
ns.db.minimapAngle = nil

local icon
for _, texture in ipairs(minimapButton.textures) do
    if texture.texture == [[Interface\Icons\Trade_BlackSmithing]] then icon = texture end
end
minimapButton.scripts.OnEnter(minimapButton)
Motion:Step(1)
check("its icon swells under the mouse", icon.width, 20)
local said = table.concat(GameTooltip.lines, "\n")
check("and the tooltip says it can be dragged", said:find("Drag to move", 1, true) ~= nil, true)
-- A player asked to see which version he runs from the button (2026-10-09).
check("its second line is the version", GameTooltip.lines[2], "v0.42.0")
minimapButton.scripts.OnMouseDown(minimapButton)
check("pressed, it dips", icon.width, 16)
minimapButton.scripts.OnMouseUp(minimapButton)
Motion:Step(1)
check("and springs back to its hover size", near(icon.width, 20), true)
minimapButton.scripts.OnLeave(minimapButton)
Motion:Step(1)
check("then rests at its own", near(icon.width, 18), true)

--------------------------------------------------------------------------------
print("")
print("the auction house bar")

local bar = UI:GetAuctionBar()
check("its status line has a width before the buttons come", bar.status.width, 350 - 10 - 10)

bar.status:SetWidth(150)
lastScan, capped = NOW - 3 * 3600, true
UI:RefreshAuctionStatus()
check("a line too long for its room says less", bar.status.text, "Last scan 3h ago (page limit)")
bar.scripts.OnEnter(bar)
check("the whole of it a hover away", GameTooltip.owner == bar and GameTooltip.text,
    "Last scan 3h ago, stopped at the page limit")
bar.scripts.OnLeave(bar)
check("gone when the mouse leaves", GameTooltip.shown, false)

lastScan, capped = nil, nil
UI:RefreshAuctionStatus()
check("no scan yet, in short", bar.status.text, "No scan yet")

scanStatus = { text = "Waiting to start the page-by-page scan" }
UI:RefreshAuctionStatus()
check("a scan waiting its turn, in short", bar.status.text, "Waiting to scan")
scanStatus = { text = "Reading listings 42%", fraction = 0.42 }
UI:RefreshAuctionStatus()
check("a line that fits is left whole", bar.status.text, "Reading listings 42%")
check("with nothing kept for a tooltip", bar.statusFull, nil)
bar.scripts.OnEnter(bar)
check("so hovering shows none", GameTooltip.owner == bar, false)
bar.scripts.OnLeave(bar)
scanStatus = nil

bar:Show()
UI:CelebrateScan({ items = 12345, soldOut = 67 })
check("a finished scan says what it found, as fits", bar.status.text, "Scan complete: 12,345 prices")
check("the whole of it kept for the tooltip", bar.statusFull, "Scan complete: 12,345 prices updated, 67 sold out")

clock = clock + 10
bar.status:SetWidth(436)
lastScan, capped = NOW - 3 * 3600, true
UI:RefreshAuctionStatus()
check("with room, the whole line", bar.status.text, "Last scan 3h ago, stopped at the page limit")
check("and no tooltip", bar.statusFull, nil)

print("")
print("the transfer dialog")

UI:ShowTransferDialog("export")
local dialog = UI.transferDialog
local scroll = dialog.editBox:GetParent()
local slider
for _, child in ipairs(scroll:GetParent().children) do
    if child.frameType == "Slider" then slider = child end
end
check("the code box has a bar down its edge", slider ~= nil, true)
check("hidden while the code fits", slider.shown, false)
scroll.scrollRange = 300
scroll.scripts.OnScrollRangeChanged(scroll, 0, 300)
check("shown once it does not", slider.shown, true)
scroll.scripts.OnMouseWheel(scroll, -1)
check("the wheel moves the code down", scroll.verticalScroll, 30)
check("and the bar with it", slider.value, 30)
for _ = 1, 20 do scroll.scripts.OnMouseWheel(scroll, -1) end
check("no further than its end", scroll.verticalScroll, 300)
slider:SetValue(120)
check("dragging the bar moves the code", scroll.verticalScroll, 120)
UI:ShowTransferDialog("import")
check("a new code starts at its top", scroll.verticalScroll, 0)
check("and so does the bar", slider.value, 0)

--------------------------------------------------------------------------------
-- The tabs themselves, built as the window builds them.
--------------------------------------------------------------------------------

-- What the tabs make, counted from here.
for name in pairs(made) do made[name] = {} end

UI.window = Region(UIParent)
UI.window.width = 1120
UI.header = Region(UI.window)
UI:BuildTabs()

-- The tabs showing: the Auction House tab is left out away from the
-- auction house.
local showing = {}
for _, tab in ipairs(UI.tabStrip.tabs) do
    if not tab.leftOut then showing[#showing + 1] = tab end
end
check("the window's own tabs are sized to their names", showing[2].span > showing[1].span, true)
check("the Auction House tab is left out", UI.tabStrip:Shows("auctionhouse"), false)

print("")
print("Settings")

--- The number box on the row whose label says `text`.
local function NumberBox(text)
    for _, box in ipairs(made.CreateNumberBox) do
        local label = box:GetParent().strings[1]
        if label and label.text == text then return box end
    end
end

UI:SelectTab("settings")
local undercut = NumberBox("Undercut By:")
settings.undercutCopper = 3
UI.tabs.settings.refresh()
check("a box shows the stored value", undercut.editBox.text, "3")
undercut.editBox:SetFocus()
undercut.editBox:SetText("25")
UI.tabs.settings.refresh()
check("a redraw leaves a number being typed alone", undercut.editBox.text, "25")
undercut.editBox.scripts.OnEnterPressed(undercut.editBox)
check("Enter saves it", settings.undercutCopper, 25)
check("and lets go of the keyboard", undercut.editBox:HasFocus(), false)
UI.tabs.settings.refresh()
check("the next redraw shows it", undercut.editBox.text, "25")

-- Pages (2026-10-08): the settings sit on category pages picked along the
-- top, with what each does in a tooltip until Show descriptions is ticked.

--- The page holder a control's row sits on: row, page, scroll, holder.
local function Holder(control)
    return control:GetParent():GetParent():GetParent():GetParent()
end

--- The tick box beside `text`, wherever it is.
local function Tick(text)
    for _, box in ipairs(made.CreateCheckbox) do
        if box.strings[1] and box.strings[1].text == text then return box end
    end
end

local describe = Tick("Show Descriptions")
local undercutRow = undercut:GetParent()
local disenchanterBox
for _, box in ipairs(made.CreateSearchBox) do
    local label = box:GetParent().strings[1]
    if label and label.text == "Disenchanter:" then disenchanterBox = box end
end

check("Settings opens on Pricing", Holder(undercut).shown, true)
check("the mailbox page waits", Holder(disenchanterBox).shown, false)
check("descriptions start as tooltips", rawget(undercutRow, "hint").shown, false)
check("so a row is one line high", undercutRow.height, 24)

undercutRow.mouseOver = true
undercutRow.scripts.OnEnter(undercutRow)
check("hovering a row lights it", undercutRow.hover.shown, true)
check("and its tooltip names it", GameTooltip.lines[1], "Undercut By:")
check("then says what it does", (GameTooltip.lines[2] or ""):find("cheapest listing", 1, true) ~= nil, true)
undercutRow.mouseOver = false
undercutRow.scripts.OnUpdate(undercutRow)
check("leaving it lets go", undercutRow.hover.shown, false)
check("and hides the tooltip", GameTooltip.shown, false)

describe.scripts.OnClick(describe)
check("Show descriptions is saved", settings.settingsDescriptions, true)
check("and puts the line under each row", rawget(undercutRow, "hint").shown, true)
check("which grows to fit it", undercutRow.height >= 40, true)
describe.scripts.OnClick(describe)
check("unticked, back to one line", undercutRow.height, 24)

local bar = describe:GetParent()
local find
for _, box in ipairs(made.CreateSearchBox) do
    if box:GetParent() == bar then find = box end
end
find.editBox:SetText("disenchanter")
find.editBox.scripts.OnTextChanged(find.editBox)
check("a search shows the page with what it found", Holder(disenchanterBox).shown, true)
check("and remembers it", settings.settingsPage, "mail")
check("the page it left is hidden", Holder(undercut).shown, false)
find.editBox:SetText("")
find.editBox.scripts.OnTextChanged(find.editBox)
check("clearing the search stays put", settings.settingsPage, "mail")

local pricingButton
for _, child in ipairs(bar.children) do
    if child.strings[1] and child.strings[1].text == "PRICING" then pricingButton = child end
end
pricingButton.scripts.OnClick(pricingButton)
check("a click on the switch shows its page", Holder(undercut).shown, true)
check("and saves it", settings.settingsPage, "pricing")

-- Tooltips page (2026-10-29): the tooltip lines left the Look page for a
-- page of their own.
local tooltipsButton, valueTick
for _, child in ipairs(bar.children) do
    if child.strings[1] and child.strings[1].text == "TOOLTIPS" then tooltipsButton = child end
end
for _, list in pairs(made) do
    for _, control in ipairs(list) do
        local parent = control.GetParent and control:GetParent()
        local label = parent and rawget(parent, "strings") and parent.strings[1]
        if not valueTick and label and label.text == "Value on Tooltips:" then valueTick = control end
    end
end
check("the value line has a control there", valueTick ~= nil, true)
check("Settings has a Tooltips page", tooltipsButton ~= nil, true)
if tooltipsButton and valueTick then
    tooltipsButton.scripts.OnClick(tooltipsButton)
    check("the tooltip rows sit on it", Holder(valueTick).shown, true)
    check("and it is saved", settings.settingsPage, "tooltips")
    pricingButton.scripts.OnClick(pricingButton)
end

--- The control on the row whose label says `text`, if Settings offers one.
local function Offered(text)
    for _, kind in ipairs({ "CreateCheckbox", "CreateNumberBox" }) do
        for _, control in ipairs(made[kind]) do
            local label = control:GetParent().strings[1]
            if label and label.text == text then return control end
        end
    end
end

-- A button placed on a settings row stays inside its column (a player's
-- report, 2026-10-09: Recipes to learn sat 340 pixels in, past the edge,
-- and covered the next column).
local spills = {}
for text, button in pairs(buttons) do
    local row = button:GetParent()
    local point, relativeTo, _, x = button:GetPoint(1)
    if row and row.width == 400 and point == "TOPLEFT" and relativeTo == row
        and x + button.width > row.width then
        spills[#spills + 1] = text
    end
end
table.sort(spills)
check("no settings button runs past its column", table.concat(spills, ", "), "")
local recipesButton
for _, button in ipairs(allButtons) do
    local label = button:GetParent() and button:GetParent().strings and button:GetParent().strings[1]
    if label and label.text == "Recipes to Learn:" then recipesButton = button end
end
check("Recipes to learn has its own row", recipesButton ~= nil, true)

-- The confirmation's Yes is the click that lists, so there is no switch
-- to turn it off: one was offered and never did anything.
check("no switch that does nothing: every listing is confirmed", Offered("Confirm before each listing"), nil)
check("the price check is still offered", Offered("Check Price First:") ~= nil, true)

-- The owner (2026-10-15): no Undercutting button, and nothing in Settings
-- deletes data; those are typed commands now.
check("no Undercutting button", Offered("Undercutting") == nil and buttons["Turn undercut off"] == nil, true)
check("no Clear price data button", buttons["Clear price data"], nil)
check("no Reset to defaults button", buttons["Reset to defaults"], nil)
check("no Forget their characters button", buttons["Forget their characters"], nil)
settings.undercutCopper = 0
UI.tabs.settings.refresh()
check("Undercut By 0 shows 0", undercut.editBox.text, "0")
undercut.editBox:SetFocus()
undercut.editBox:SetText("4")
undercut.editBox.scripts.OnEnterPressed(undercut.editBox)
check("and takes a new amount", settings.undercutCopper, 4)

ns.db.prices = { Forever = { [1] = {} }, Elsewhere = { [2] = {} } }
ns.db.lastCappedScanByRealm = { Forever = 900, Elsewhere = 800 }
UI:ClearPriceData()
check("Clear price data clears this realm's page-limit stamp", ns.db.lastCappedScanByRealm.Forever, nil)
check("and keeps another realm's", ns.db.lastCappedScanByRealm.Elsewhere, 800)

-- A sell list folded down to its header.
local sellFrame, sellHeader = Region(UIParent), Region()
local sellBody = Region(sellFrame)
local sellTitle = Theme.CreateLabel(sellHeader, "normal", "accent")
settings.postPanelCollapsed = true
local sellButton = ns.Collapse.Attach(sellFrame,
    { key = "postPanelCollapsed", header = sellHeader, title = sellTitle, body = sellBody })
ns.PostPanel = {
    frame = sellFrame,
    ApplyHeight = function() Count("height") end,
    Refresh = function() Count("panel") end,
}
check("the sell list starts folded", sellBody.shown, false)

UI:ResetSettings()
check("Reset to defaults opens the folded sell list", sellBody.shown, true)
check("whose button turns back to a minus", sellButton.glyph.stem.shown, false)
check("measures it again", calls.height, 1)
check("and redraws it", calls.panel, 1)
check("queued sub-crafts are worked out again", calls.rebuild == 1 and calls.notify == 1, true)
check("and the profession window's values", calls.recipeValue, 1)
ns.PostPanel = nil

--------------------------------------------------------------------------------
print("")
print("Prices")

for index = 1, 40 do
    records[1000 + index] = { market = 100 * index, min = 90 * index, quantity = index, seen = NOW - 30 }
end
records[1001].market = 123456

local pricesList = made.CreateScrollList[1]
local pricesSearch = made.CreateSearchBox[1]
local craftWith = made.CreateCheckbox[1]
local sorter = made.SortableHeadings[1]
pricesList.height = 220

UI:SelectTab("prices")
local top = pricesList.rows[1]
check("ten rows on screen", #pricesList.rows, 10)
check("an age under a minute reads \"now\"", top.cells.age.text, "now")
check("a money cell with room shows every coin", Plain(top.cells.market.text), "12g 34s 56c")
top.cells.market:SetWidth(50)
UI.tabs.prices.refresh()
check("a narrower one, fewer coins", Plain(top.cells.market.text), "12g 35s")
top.cells.market:SetWidth(80)

local function ScrollDown()
    for _ = 1, 5 do pricesList.scripts.OnMouseWheel(pricesList, -1) end
end

ScrollDown()
check("scrolled down the list", pricesList.offset, 15)
UI.tabs.prices.refresh()
check("a redraw keeps the place", pricesList.offset, 15)

pricesSearch.editBox:SetText("item")
pricesSearch.editBox.scripts.OnTextChanged(pricesSearch.editBox)
check("a new search starts at the top", pricesList.offset, 0)
ScrollDown()
pricesSearch.editBox:SetText("")
pricesSearch.editBox.scripts.OnTextChanged(pricesSearch.editBox)
check("so does clearing it", pricesList.offset, 0)

ScrollDown()
craftWith.scripts.OnClick(craftWith)
check("so does a filter", pricesList.offset, 0)
craftWith.scripts.OnClick(craftWith)

-- No sort menu any more (2026-10-06): the headings sort.
ScrollDown()
sorter.buttons.name.scripts.OnClick(sorter.buttons.name)
check("and a new sort", pricesList.offset, 0)
check("by the heading clicked", sorter.key, "name")

--------------------------------------------------------------------------------
print("")
print("Characters")

local function Profession(name, level) return { name = name, skillLevel = level, learned = true } end

ns.db.characters = {
    A = { recipes = { [101] = { skillLineID = 197 }, [102] = { skillLineID = 171 } } },
}
characters = {
    { key = "A", name = "Aldra Stormvale", realm = "Forever", gold = 1234567, recipeCount = 120,
      faction = "Horde", race = "Orc", class = "Mage", classFile = "MAGE", level = 25, levelShare = 0.4,
      rested = 80, restedGuess = true, zone = "Durotar", played = 90000, seenAt = NOW - 3600,
      mailCount = 5, inventoryAt = NOW - 3600, professions = {
        Profession("Tailoring", 300), Profession("Enchanting", 300), Profession("Alchemy", 300),
        Profession("Cooking", 300), Profession("First Aid", 300), Profession("Fishing", 300) } },
    { key = "B", name = "Brannoc Ironhill", realm = "Forever", gold = 500, recipeCount = 3, isCurrent = true,
      faction = "Alliance", level = 30, rested = 150,
      professions = { Profession("Mining", 75), Profession("Herbalism", 80) } },
}

local charactersList = made.CreateScrollList[2]
charactersList.height = 400
UI:SelectTab("characters")

local function Rows()
    local out = {}
    for index, row in ipairs(charactersList.rows) do
        if row.data then out[index] = row end
    end
    return out
end

local rows = Rows()
check("the side you're playing comes first", rows[1].name.text, "ALLIANCE")
check("with how many are on it", rows[1].count.text, "1 character")
check("its character under it", rows[2].name.text, "Brannoc Ironhill")
check("the character playing is here now", rows[2].cells.seen.text, "Here now")
check("rested to the top says Full", rows[2].cells.rested.text, "Full")
check("then the other side", rows[3].name.text, "HORDE")
local aldra = rows[4]
check("one line a row: race and class moved to the hover", aldra.sub.text, "")
check("two professions, then how many more",
    aldra.cells.professions.text, "Alchemy 300\nCooking 300  +4")
check("rested as a share of a level", aldra.cells.rested.text, "80%")
check("mail waiting", aldra.cells.mail.text, "5")
check("time played", aldra.cells.played.text, "1d 1h")
check("when last seen", aldra.cells.seen.text, "1h ago")

aldra.mouseOver = true
aldra.scripts.OnEnter(aldra)
local listed = 0
for _, line in ipairs(GameTooltip.lines) do
    if tostring(line):find(" 300$") then listed = listed + 1 end
end
check("hovering the row lists every profession", GameTooltip.owner == aldra and listed, 6)
aldra.scripts.OnLeave(aldra)
aldra.mouseOver = false

aldra.scripts.OnClick(aldra, "LeftButton")
rows = Rows()
check("a click opens a line under the character", rows[5] and rows[5].data.kind, "card")
check("a dropped profession's crafts are left out of the best crafts", table.concat(analysed, ","), "102")
check("the open line names the best craft", rows[5].card.crafts[1].name.text, "Craft 102")

rows[3].scripts.OnClick(rows[3], "LeftButton")
rows = Rows()
check("a click on a side's heading folds it", rows[4], nil)
rows[3].scripts.OnClick(rows[3], "LeftButton")

local chips = ns.CharactersTab._widgets.chips
chips[2].scripts.OnClick(chips[2])
rows = Rows()
check("Show: Horde leaves only the Horde", rows[1].name.text, "HORDE")
chips[1].scripts.OnClick(chips[1])

-- Realm: This Realm by default, All Realms, then each realm by name.
local realm = ns.CharactersTab._widgets.realm
characters[#characters + 1] = { key = "C", name = "Corwen Ashby", realm = "Other Shore", gold = 10,
    recipeCount = 1, faction = "Horde", level = 12, professions = {} }
UI:SelectTab("characters")
local function Named(name)
    for _, row in pairs(Rows()) do
        if row.name.text == name and row.data.kind == "char" then return true end
    end
    return false
end
check("the tab opens on the realm you're playing", Named("Corwen Ashby"), false)
check("with its own characters", Named("Aldra Stormvale"), true)
local realmNames = {}
for _, option in ipairs(realm.options) do realmNames[#realmNames + 1] = option.text end
check("This Realm, All Realms, then each realm", table.concat(realmNames, ","),
    "This Realm,All Realms,Forever,Other Shore")
local function PickRealm(index)
    local entry = realm.menu.children[index]
    entry.scripts.OnClick(entry)
end
PickRealm(2)
check("All Realms shows every character", Named("Corwen Ashby") and Named("Brannoc Ironhill"), true)
PickRealm(4)
check("a realm by name shows only its characters",
    Named("Corwen Ashby") and not Named("Aldra Stormvale") and not Named("Brannoc Ironhill"), true)
characters[#characters] = nil
UI:SelectTab("characters")
check("a realm no one is on any more goes back to This Realm", realm:GetValue(), "\1here")

--------------------------------------------------------------------------------
print("")
print("Queue")

-- The queued amount is typed (asked 2026-10-05: taking 100 off a craft meant
-- clicking - a hundred times, and 100 lost its last digit). The real rows,
-- built and drawn by the Queue tab's own list.
local quantities = {}
ns.Queue.SetQuantity = function(_, recipeID, quantity) quantities[recipeID] = quantity end
ns.Recipes.GetAny = function(_, recipeID) return { name = "Craft " .. recipeID, outputItemID = recipeID } end
ns.Crafting = { GetReadiness = function() return true end }
ns.Queue.GetDependencyParents = function() return { "Craft 701" } end
ns.CraftProgress = { Create = function(_, parent) return Region(parent) end }

Load("/UI/Tab_Queue.lua")
local listsBefore = #made.CreateScrollList
UI.tabs.queue.build(Region(UI.window))
local craftList = made.CreateScrollList[listsBefore + 1]
craftList.height = 200

local own = { recipeID = 701, quantity = 120 }
local sub = { recipeID = 702, quantity = 36, isDependency = true }
craftList:SetData({ own, sub })
local ownRow, subRow = craftList.rows[1], craftList.rows[2]

check("the queued amount is in a box you can type in", ownRow.quantity.editBox.text, "120")
local digits = Theme.CreateLabel(Region(), "small", "text")
digits:SetText("9999")
check("wide enough for four digits and the box's edges",
    ownRow.quantity:GetWidth() >= Theme.TextWidth(digits) + 10, true)
ownRow.quantity.editBox:SetFocus()
ownRow.quantity.editBox:SetText("20")
craftList:Refresh()
check("a redraw leaves an amount being typed alone", ownRow.quantity.editBox.text, "20")
ownRow.quantity.editBox.scripts.OnEnterPressed(ownRow.quantity.editBox)
check("Enter sets the queued amount", quantities[701], 20)
check("and lets go of the keyboard", ownRow.quantity.editBox:HasFocus(), false)
ownRow.quantity.editBox:SetFocus()
ownRow.quantity.editBox:SetText("0")
ownRow.quantity.editBox.scripts.OnEnterPressed(ownRow.quantity.editBox)
check("0 takes the craft off the queue", quantities[701], 0)
check("a sub-craft has no box", subRow.quantity:IsShown(), false)
check("but shows its amount", subRow.count.text, "36")

quantities[701] = nil
ownRow.quantity.editBox:SetFocus()
ownRow.quantity.editBox:SetText("55")
craftList:SetData({ { recipeID = 703, quantity = 4 } })
check("a row now showing another craft drops what was typed", ownRow.quantity.editBox.text, "4")
check("without queuing it for either craft", quantities[701] == nil and quantities[703] == nil, true)

-- Names in the colour of what they make (asked 2026-10-07). An item the
-- client has not sent yet starts in the text colour and takes its colour
-- when GET_ITEM_INFO_RECEIVED says it is here.
local rarity = { [701] = { 0.12, 1.00, 0.00 }, [702] = { 0.00, 0.44, 0.87 } }
local savedQuality, savedRegister, savedAfter = ns.Util.GetItemQualityColor, ns.RegisterEvent, C_Timer.After
ns.Util.GetItemQualityColor = function(itemID)
    local c = rarity[itemID]
    if c then return c[1], c[2], c[3] end
end
local itemArrived
ns.RegisterEvent = function(_, event, fn)
    if event == "GET_ITEM_INFO_RECEIVED" then itemArrived = fn end
    return true
end
C_Timer.After = function(_, fn) fn() end
local textColor = { Theme.Unpack("text") }

listsBefore = #made.CreateScrollList
UI.tabs.queue.build(Region(UI.window))
craftList = made.CreateScrollList[listsBefore + 1]
craftList.height = 200
craftList:SetData({ { recipeID = 701, quantity = 2 }, { recipeID = 702, quantity = 1, isDependency = true },
    { recipeID = 704, quantity = 1 } })
local green, blue, late = craftList.rows[1], craftList.rows[2], craftList.rows[3]
check("a queued craft's name is its rarity colour", green.name.textColor[2], 1.00)
check("a sub-craft's too", blue.name.textColor[3], 0.87)
check("an item not sent yet starts in the text colour", late.name.textColor[1], textColor[1])
rarity[704] = { 0.64, 0.21, 0.93 }
check("the tab listens for the item arriving", type(itemArrived), "function")
itemArrived()
check("and colours it when it does", late.name.textColor[1], 0.64)

ns.Util.GetItemQualityColor, ns.RegisterEvent, C_Timer.After = savedQuality, savedRegister, savedAfter

--------------------------------------------------------------------------------

print("")
print("the price graph")

-- The Profit tab's graph is laid out before the tab first shows. Drawn then,
-- at no width, its times sat bunched at the left until something redrew it.
local savedHistory = ns.PriceHistory
ns.PriceHistory = ns.PriceHistory or { HourText = function(hour) return tostring(hour) end }
local graphParent = Region(UIParent)
local graph = ns.PriceGraph.Create(graphParent, { picker = true, ticks = true })
graph:Hide()
graph:SetItems({})
check("drawn before it has a size, it knows to draw again", graph:OutOfSize(), true)
graph.plot.width, graph.plot.height = 300, 120
graph.plot.scripts.OnSizeChanged(graph.plot)
check("a size arriving while hidden waits", graph.drawnWidth, 0)
graph:Show()
check("and is drawn at its size on show", graph.drawnWidth, 300)
local _, _, _, tickX = graph.ticks[2]:GetPoint(1)
check("the times spread across the plot", near(tickX, 6 + 300 / 3), true)
check("nothing left to catch up", graph:OutOfSize(), false)
local drawn = 0
local realRefresh = graph.Refresh
graph.Refresh = function(self) drawn = drawn + 1; return realRefresh(self) end
graph:Hide()
graph:Show()
check("shown again at the same size, nothing is redrawn", drawn, 0)
graph.plot.width = 360
graph.plot.scripts.OnSizeChanged(graph.plot)
check("a new size while showing is drawn at once", graph.drawnWidth, 360)
ns.PriceHistory = savedHistory

--------------------------------------------------------------------------------

Motion:FinishAll()

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print("")
print(("%d passed, %d failed"):format(passed, failed))
assert(failed == 0, "word fitting checks failed")
