-- The Bank view's total, its prices for items not loaded yet, and its titles.
--
-- Four things went wrong, each seen without an error:
--   1. The footer's gold total counts up to a new value. Type a letter in
--      the search and take it out again within the count, and the old count
--      finished after the new total was drawn: the whole list sat over the
--      filtered total.
--   2. An item the client had not loaded has no quality to go by, so a grey
--      one was valued at its auction price, against the vendor-only rule.
--   3. Nothing drew the view again when such an item loaded, so it stayed
--      "item 1234" with no worth until something else refreshed it.
--   4. The picked item's title and the line under it were cut off with "..."
--      for a long name or a long line of coins.

local GLOBALS = { "CreateFrame", "GameTooltip", "C_Item", "C_Timer", "time", "Enum" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local function noop() end

--- Text as it shows on screen, without colour or link codes.
local function Plain(text)
    return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1"))
end

local function Stub(fields)
    local frame = fields or {}
    frame.GetParent = frame.GetParent or function() return Stub() end
    return setmetatable(frame, { __index = function(self, key)
        if type(key) == "string" and key:match("^%u") then
            rawset(self, key, noop)
            return noop
        end
    end })
end

local SIZES = { tiny = 10, small = 11, normal = 12, large = 14 }

--- A label that measures its text: 0.6 of the font size a letter.
local function Label(size)
    return Stub({
        text = "", size = SIZES[size] or size or 12, wrap = false,
        SetText = function(self, value) self.text = tostring(value) end,
        GetText = function(self) return self.text end,
        SetFont = function(self, _, fontSize) self.size = fontSize end,
        SetWordWrap = function(self, on) self.wrap = on and true or false end,
        GetStringWidth = function(self) return #Plain(self.text) * self.size * 0.6 end,
    })
end

local frames = {}
local function Frame()
    local frame = Stub({
        shown = true, scripts = {},
        Show = function(self) self.shown = true end,
        Hide = function(self) self.shown = false end,
        SetShown = function(self, on) self.shown = on and true or false end,
        SetScript = function(self, name, fn) self.scripts[name] = fn end,
        CreateTexture = function() return Stub() end,
        CreateFontString = function() return Label() end,
    })
    frames[#frames + 1] = frame
    return frame
end

CreateFrame = function() return Frame() end
GameTooltip = Stub()
Enum = nil

local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }

local now = 1790000000
time = function() return now end

-- Items: 1 Silk Cloth, 2 Wool Cloth, 3 a grey Broken Fang, 4 a recipe with a
-- long name, 5 a costly gem, 6 leather the client loads late. `loaded` is
-- what the client has cached.
local ITEMS = {
    [1] = { name = "Silk Cloth", quality = 1, sell = 38 },
    [2] = { name = "Wool Cloth", quality = 1, sell = 33 },
    [3] = { name = "Broken Fang", quality = 0, sell = 5 },
    [4] = { name = "Formula: Enchant Bracer - Superior Stamina", quality = 2, sell = 1000 },
    [5] = { name = "Star Ruby", quality = 2, sell = 10000 },
    [6] = { name = "Thick Leather", quality = 1, sell = 20 },
}
local loaded = { [1] = true, [2] = true, [4] = true, [5] = true }

C_Item = {
    GetItemInfo = function(itemID)
        local item = loaded[itemID] and ITEMS[itemID]
        if not item then return nil end
        local link = ("|cffffffff|Hitem:%d::::|h[%s]|h|r"):format(itemID, item.name)
        return item.name, link, item.quality, nil, nil, nil, nil, nil, nil, nil, item.sell
    end,
}

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = noop
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = noop, noop, noop, noop

local handlers = {}
ns.RegisterEvent = function(_, event, fn) handlers[event] = fn; return true end

ns.Theme = {
    FitWhole = function(label, text) label:SetText(text); return 0, 13 end,
    SetRowLine = function(label, text) label:SetText(text) end,
    FONT = "font",
    sizes = SIZES,
    Unpack = function(key) return key end,
    CreateLabel = function(_, size) return Label(size) end,
    CreatePanel = function() return Frame() end,
    AccentStripe = noop,
    CreateItemIcon = function() return Stub() end,
    SetItemIcon = noop,
    CreateBar = function() return Stub({ Set = noop }) end,
    CreateHeading = function() return Label("tiny") end,
}

local list
ns.Widgets = {
    CreateSearchBox = function(_, _, onChange) return Stub({ onChange = onChange }) end,
    CreateDropdown = function(_, _, onSelect) return Stub({ onSelect = onSelect }) end,
    CreateCheckbox = function() return Stub() end,
    CreateScrollList = function(_, opts)
        list = Stub({ opts = opts, data = {}, visible = true })
        function list:SetData(data) self.data = data end
        function list:IsVisible() return self.visible end
        return list
    end,
}

-- Auction prices: the grey fang has one the addon must never use.
local AUCTION = { [1] = 100, [2] = 50, [3] = 999, [4] = 2000, [5] = 99999, [6] = 300 }
ns.Prices = { GetValue = function(_, itemID) return AUCTION[itemID] end }
ns.Config = { GetCharacterKey = function() return "Player-main" end }
ns.db = { characters = {
    ["Player-main"] = { name = "Main", bank = { [1] = 20, [2] = 20 }, bankAt = 1000 },
} }
ns.Recipes = { GetCharacters = function()
    return { { key = "Player-main", name = "Main", isCurrent = true, bankAt = 1000 } }
end }

for _, path in ipairs({ "Core/Util.lua", "Logic/Banks.lua", "UI/Columns.lua", "UI/BankView.lua" }) do
    assert(loadfile(lfs_cwd .. "/" .. path))("Blackthornes_TS", ns)
end

local BankView, Banks, Util = ns.BankView, ns.Banks, ns.Util

local passed, failed = 0, 0
local function check(label, got, expected)
    local ok = got == expected
    if ok then passed = passed + 1 else failed = failed + 1 end
    print(("  %-56s %-14s %s"):format(label, tostring(got), ok and "ok" or
        ("FAILED, expected " .. tostring(expected))))
end

local view = Frame()
BankView.Build(view)
local widgets = BankView._widgets

--- Run every running count for `seconds`.
local function Run(seconds)
    for _ = 1, math.floor(seconds / 0.05 + 0.5) do
        for _, frame in ipairs(frames) do
            local step = frame.scripts.OnUpdate
            if step then step(frame, 0.05) end
        end
    end
end

local function Money(copper) return Plain(Util.FormatMoney(copper, { short = true })) end

--------------------------------------------------------------------------------
print("")
print("the footer total after a quick search")
--------------------------------------------------------------------------------

BankView.Refresh()
Run(1)
local total = 0
for _, entry in ipairs(list.data) do total = total + (entry.worth or 0) end
check("the full list is worth silk and wool",          total, 20 * 100 + 20 * 50)
check("the footer counts up to it",                    Plain(widgets.total.text), Money(total))

-- A letter typed and taken out again before the count is done.
widgets.search.onChange("s")
Run(0.1)
widgets.search.onChange("")
check("the whole list is back",                        #list.data, 2)
Run(1)
check("and the footer settles on its total",           Plain(widgets.total.text), Money(total))

-- Stopped halfway, a count carries on from where it got to.
widgets.search.onChange("s")
Run(0.3)
widgets.search.onChange("")
Run(1)
check("a count cut short ends on the new total",       Plain(widgets.total.text), Money(total))

--------------------------------------------------------------------------------
print("")
print("an item the client has not loaded")
--------------------------------------------------------------------------------

Banks.waiting = false
check("a grey item not loaded gets no auction price",  Banks:UnitWorth(3), nil)
check("and the view is told something is waiting",    Banks.waiting, true)

loaded[3] = true
check("loaded, it is worth what a vendor pays",        Banks:UnitWorth(3), 5)
loaded[3] = nil

--------------------------------------------------------------------------------
print("")
print("the view draws again once items load")
--------------------------------------------------------------------------------

ns.db.characters["Player-main"].bank[6] = 4
BankView.Refresh()

local function Find(itemID)
    for _, entry in ipairs(list.data) do
        if entry.itemID == itemID then return entry end
    end
end

check("the leather not loaded yet has no worth",       Find(6) and Find(6).worth, nil)

-- The game's answer for an item that does not exist: asking again would only
-- bring the same answer back.
timers = {}
handlers.GET_ITEM_INFO_RECEIVED(nil, "GET_ITEM_INFO_RECEIVED", 9999, false)
check("an item that does not exist draws nothing",     #timers, 0)

timers = {}
handlers.GET_ITEM_INFO_RECEIVED()
handlers.GET_ITEM_INFO_RECEIVED()
check("a burst of items is one redraw",                #timers, 1)

loaded[6] = true
timers[1]()
check("drawn again, it has its name",                  Find(6) and Find(6).name, "Thick Leather")
check("and its worth",                                 Find(6) and Find(6).worth, 4 * 300)

timers = {}
handlers.GET_ITEM_INFO_RECEIVED()
check("nothing waiting, nothing drawn",                #timers, 0)

loaded[6] = nil
BankView.Refresh()
list.visible = false
timers = {}
handlers.GET_ITEM_INFO_RECEIVED()
check("nor while the view is hidden",                  #timers, 0)
list.visible = true
loaded[6] = true

--------------------------------------------------------------------------------
print("")
print("the picked item's title and the line under it fit")
--------------------------------------------------------------------------------

ns.db.characters["Player-main"].bank[4] = 1
ns.db.characters["Player-main"].bank[5] = 1
BankView.Refresh()

local detail = BankView._widgets and BankView._widgets.detail
local function Pick(itemID)
    BankView._state.selected = itemID
    BankView.Refresh()
end

-- 256 pixels beside the icon.
Pick(4)
check("a long name steps down a size",                 detail and detail.title.size, 12)
check("and takes two lines rather than end in ...",    detail and detail.title.wrap, true)

Pick(1)
check("a short name is back at its own size",          detail and detail.title.size, 14)
check("on one line",                                   detail and detail.title.wrap, false)

-- 9g 99s 99c each: every coin does not fit beside the count and the total.
Pick(5)
local line = detail and Plain(detail.subtitle.text) or ""
check("the line under it fits",                        #line * 11 * 0.6 <= 256, true)
check("with the amounts in fewer coins",               line:find("99c", 1, true) == nil, true)
check("and still says what one is worth",              line:find("each", 1, true) ~= nil, true)

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print("")
print(("%d passed, %d failed"):format(passed, failed))
assert(failed == 0, "bank view checks failed")
