-- The Gather tab's footer (UI/Tab_Gather.lua), from the owner's UI review
-- (2026-10-29): label and value only, on one line.
--
--   1. Vendor:, Auction House: and Total: each with its amount.
--   2. The rest (how many still needed, the saving, the unpriced count) is
--      on the total's hover; an amber mark shows only while one is unpriced.
--   3. Grouping is a tick box; unticked, the list goes by cost.

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })

local function Stub(fields)
    return setmetatable(fields or {}, { __index = function(self, key)
        local noop = function() end
        rawset(self, key, noop)
        return noop
    end })
end

local function Label()
    return Stub({ text = "", shown = true,
        SetText = function(self, v) self.text = tostring(v) end,
        GetText = function(self) return self.text end,
        SetShown = function(self, v) self.shown = v and true or false end,
        Show = function(self) self.shown = true end,
        Hide = function(self) self.shown = false end })
end

local function Frame()
    local f = Label()
    f.CreateFontString = function() return Label() end
    f.CreateTexture = function() return Stub() end
    f.IsVisible = function() return true end
    return f
end

CreateFrame = function() return Frame() end
GameTooltip = Stub()
C_Timer = { After = function() end }

local labels = {}
ns.Theme = {
    CreateLabel = function() local l = Label(); labels[#labels + 1] = l; return l end,
    CreateDivider = function() return Stub() end,
    Unpack = function() return 1, 1, 1, 1 end,
}

local checkbox, list
ns.Widgets = {
    CreateCheckbox = function(_, text, onClick, checked)
        local box = Stub({ text = text, checked = checked, onClick = onClick })
        if text == "Group: Where to buy" then checkbox = box end
        return box
    end,
    CreateButton = function() return Stub() end,
    CreateScrollList = function() list = Stub({ SetData = function(self, d) self.data = d end }); return list end,
}
ns.Util = {
    GetItemLabel = function(id) return "[Item " .. id .. "]" end,
    FormatMoney = function(c) return tostring(c) .. "c" end,
}
ns.Columns = Stub({ Place = function() return 0 end })
ns.FarmerGoals = { Available = function() return false end }
ns.RegisterEvent = function() return true end

local shopping = {
    { itemID = 1, shortfall = 2, estimatedCost = 10, source = "auction" },
    { itemID = 2, shortfall = 3, estimatedCost = 50, source = "vendor" },
}
local summary = {
    outstanding = 2, satisfied = 1, total = 60, saving = 5,
    vendor = { count = 1, cost = 50 }, auction = { count = 1, cost = 10 }, unknown = { count = 0 },
}
ns.Queue = {
    GetShoppingList = function() return shopping end,
    GetGatherSummary = function() return summary end,
    Count = function() return 1 end,
}

local tab
ns.UI = { RegisterTab = function(_, spec) tab = spec end }

assert(loadfile(lfs_cwd .. "/UI/Tab_Gather.lua"))("Blackthornes_TS", ns)

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

local function Has(text)
    for _, l in ipairs(labels) do if l.text == text and l.shown then return true end end
    return false
end

tab.build(Frame())
tab.refresh()

-- 1
check("vendor and its amount", Has("Vendor: 50c"))
check("auction house and its amount", Has("Auction House: 10c"))
check("total and its amount", Has("Total: 60c"))

-- 2
local lines = ns.GatherTab.TotalLines(summary)
local joined = {}
for _, line in ipairs(lines) do joined[#joined + 1] = line[1] end
joined = table.concat(joined, "|")
check("how many still needed is on the hover", joined:find("2 of 3 materials still needed", 1, true) ~= nil)
check("and the saving", joined:find("saves 5c", 1, true) ~= nil)
check("no unpriced line while all are priced", joined:find("no price data", 1, true) == nil)
check("and no mark", not Has("*"))
summary.unknown.count = 2
tab.refresh()
check("an unpriced material brings the mark", Has("*"))
joined = {}
for _, line in ipairs(ns.GatherTab.TotalLines(summary)) do joined[#joined + 1] = line[1] end
check("and its line on the hover", table.concat(joined, "|"):find("2 materials with no price data", 1, true) ~= nil)

-- 3
check("grouped by where to buy at first", checkbox and checkbox.checked == true
    and list.data[1].source == "vendor")
checkbox.onClick(false)
check("unticked: by cost, dearest first", list.data[1].estimatedCost == 50 and list.data[2].estimatedCost == 10)

print(("\n%d check(s) passed\n"):format(checks))
