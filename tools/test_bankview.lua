-- The Characters tab's Bank view, drawn without a game client.
--
-- Builds the tab, flips it to the Bank view the way the switch and /bts bank
-- do, and checks the list, the summary, the overview pane and a picked item.
-- The widget layer only remembers what was written to it, as in
-- tools/test_enchantingtab.lua.

local saved = { CreateFrame = CreateFrame, GameTooltip = GameTooltip, C_Item = C_Item, C_Timer = C_Timer }

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
local commands = {}
ns.RegisterCommand = function(name, _, fn) commands[name] = fn end
ns.Print = function() end
ns.RegisterEvent = function() return true end

local function Stub(fields)
    local frame = fields or {}
    frame.GetParent = frame.GetParent or function() return Stub() end
    frame.GetFrameLevel = frame.GetFrameLevel or function() return 1 end
    frame.GetStringWidth = frame.GetStringWidth or function() return 60 end
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
    })
end

local function Frame()
    return Stub({
        shown = true,
        Show = function(self) self.shown = true end,
        Hide = function(self) self.shown = false end,
        SetShown = function(self, v) self.shown = v and true or false end,
        CreateTexture = function() return Stub() end,
    })
end

CreateFrame = function() return Frame() end
C_Timer = { After = function() end }

local tooltip = { lines = {} }
GameTooltip = Stub({
    AddLine = function(_, text) tooltip.lines[#tooltip.lines + 1] = text end,
    AddDoubleLine = function(_, left, right) tooltip.lines[#tooltip.lines + 1] = left .. "=" .. right end,
})

C_Item = { GetItemInfo = function(itemID)
    if itemID == 1 then return "Silk Cloth", nil, 1, nil, nil, nil, nil, nil, nil, nil, 38 end
end }

ns.Theme = {
    FitWhole = function(label, text) label:SetText(text); return 0, 13 end,
    SetRowLine = function(label, text) label:SetText(text) end,
    SetRowName = function(label, text) label:SetText(text) end,
    FONT = "font",
    sizes = { tiny = 10, small = 11, normal = 12, large = 14 },
    Unpack = function(key) return key end,
    CreateLabel = function() return Label() end,
    CreatePanel = function() return Frame() end,
    CreateDivider = function() return Stub() end,
    AccentStripe = function() return Stub() end,
    CreateItemIcon = function() return Stub() end,
    SetItemIcon = function() end,
    SetItemNameColor = function() return false end,
    CreateBar = function()
        return Stub({ Set = function(self, fraction) self.fraction = fraction end })
    end,
    CreateHeading = function() return Label() end,
    StyleHeading = function(label) label.rule = Stub(); return label end,
    ProfitColor = function() return "profit" end,
    -- What the Characters view next door draws with.
    Fill = function() return Stub() end,
    Border = function() return {} end,
    SetBorderColor = function() end,
    SetMoneyText = function(label, copper) label:SetText(tostring(copper)) end,
    SetGradientAlpha = function() end,
}

local lists = {}
ns.Widgets = {
    CreateSearchBox = function(_, _, onChange) return Stub({ onChange = onChange }) end,
    CreateDropdown = function(_, _, onSelect) return Stub({ onSelect = onSelect }) end,
    CreateCheckbox = function(_, _, onToggle) return Stub({ onToggle = onToggle }) end,
    CreateButton = function() return Stub() end,
    CreateTabStrip = function(_, _, onSelect) return Stub({ onSelect = onSelect }) end,
    ShowItemTooltip = function() return true end,
    CreateScrollList = function(_, opts)
        local list = Stub({ opts = opts, data = {} })
        function list:SetData(data) self.data = data end
        lists[#lists + 1] = list
        return list
    end,
}

ns.Util = {
    HasFunction = function(path) return path == "C_Item.GetItemInfo" end,
    GetVendorSellPrice = function(itemID) return itemID == 1 and 38 or nil end,
    FormatMoney = function(copper) return copper and (tostring(copper) .. "c") or "--" end,
    Comma = function(n) return tostring(n) end,
    GetItemLabel = function(itemID) return "item" .. itemID end,
    FormatAgeAgo = function() return "1 day ago" end,
    Count = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end,
}

ns.Prices = { GetValue = function(_, itemID) return itemID == 1 and 100 or nil end }
ns.Config = { GetCharacterKey = function() return "Player-main" end }
ns.db = { characters = {
    ["Player-main"] = { name = "Main", bank = { [1] = 20 }, bankAt = 1000, recipes = {} },
    ["Player-alt"] = { name = "Alt", bank = { [1] = 40, [2] = 3 }, bankAt = 2000, recipes = {} },
    ["Player-new"] = { name = "New", recipes = {} },
} }
ns.Recipes = { GetCharacters = function()
    return {
        { key = "Player-main", name = "Main", isCurrent = true, bankAt = 1000, recipeCount = 0 },
        { key = "Player-alt", name = "Alt", bankAt = 2000, recipeCount = 0 },
        { key = "Player-new", name = "New", recipeCount = 0 },
    }
end }

local tab
ns.UI = {
    RegisterTab = function(_, definition) tab = definition end,
    RefreshActiveTab = function() end,
    Show = function() end,
    SelectTab = function() end,
}

for _, path in ipairs({ "Logic/Banks.lua", "UI/Columns.lua", "UI/BankView.lua", "UI/Tab_Characters.lua" }) do
    assert(loadfile(lfs_cwd .. "/" .. path))("Blackthornes_TS", ns)
end

assert(tab and tab.key == "characters", "the Characters tab registered")

local container = Frame()
tab.build(container)

-- Two lists: the characters, then the bank.
assert(#lists == 2, "both views built")
local bankList = lists[2]

-- Starts on the characters view; /bts bank flips it.
commands.bank()
tab.refresh()

local data = bankList.data
assert(#data == 2, "silk and the unnamed item, got " .. #data)
assert(data[1].itemID == 1 and data[1].total == 60, "silk first, by worth")

-- A row draws, and its tooltip names who holds it.
local row = Frame()
bankList.opts.createRow(row)
bankList.opts.updateRow(row, data[1])
assert(row.cells.have.text == "60")
assert(row.cells.who.text == "2 characters")
assert(row.cells.worth.text == "6000c", "worth " .. row.cells.worth.text)

bankList.opts.onEnter(row, data[1])
local joined = table.concat(tooltip.lines, "|")
assert(joined:find("Alt=bank 40", 1, true) and joined:find("Main=bank 20", 1, true),
    "tooltip lists holders: " .. joined)

-- Picking an item, then picking it again, goes back to the overview.
bankList.opts.onClick(data[1])
assert(bankList.opts.isSelected(data[1]), "silk selected")
bankList.opts.onClick(data[1])
assert(not bankList.opts.isSelected(data[1]), "second click clears it")

-- A search with no match says so.
ns.BankView._state.search = "zzz"
ns.BankView.Refresh()
assert(#bankList.data == 0)
ns.BankView._state.search = ""
ns.BankView.Refresh()
assert(#bankList.data == 2)

CreateFrame, GameTooltip, C_Item, C_Timer = saved.CreateFrame, saved.GameTooltip, saved.C_Item, saved.C_Timer
