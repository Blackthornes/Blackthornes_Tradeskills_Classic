-- The disenchant value on the Ready to sell list at the auction house.
--
-- Asked 2026-09-27: "disenchant value of items should also be displayed on
-- the Ready to sell tab when AH is open so a player can decide whether to
-- sell or DE if they are an enchanter." So: shown for an enchanter, left out
-- for anyone else, and marked when it beats the listing price.

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.Print, ns.Debug, ns.Warn = function() end, function() end, function() end

local registeredEvents = {}
ns.RegisterEvent = function(_, event, fn)
    registeredEvents[event] = fn
    return true
end

--------------------------------------------------------------------------------
-- A widget layer that only remembers what was written to it
--------------------------------------------------------------------------------

-- Any method this test does not care about answers as a no-op, so the tab can
-- build its toolbar, headings and detail panel undisturbed.
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

local function Label()
    return Stub({
        text = "",
        color = nil,
        SetText = function(self, value) self.text = tostring(value) end,
        SetTextColor = function(self, a, b, c) self.color = { a, b, c } end,
    })
end

CreateFrame = function() return Stub() end
C_Timer = { After = function() end, NewTicker = function() return Stub() end }

ns.Theme = {
    FONT = "font",
    sizes = { tiny = 10, small = 11, normal = 12, large = 14, title = 16 },
    CreateLabel = function() return Label() end,
    CreatePanel = function() return Stub() end,
    CreateDivider = function() return Stub() end,

    -- Palette entries come back as their own name, so an assertion can say
    -- which one a cell was painted with.
    Unpack = function(key) return key end,
    ProfitColor = function(value) return (value or 0) >= 0 and "profit" or "loss" end,

    -- The skill-up star. It remembers the tier it was last set to, so a row
    -- can be asked whether it is wearing one -- false rather than nil, because
    -- the stub answers a missing field with a no-op function.
    CreateMark = function() return Stub({ tier = false }) end,
    SetMark = function(mark, tier) mark.tier = tier or false end,

    -- The house trim: drawn, never asserted on.
    AccentStripe = function() return Stub() end,
    CreateItemIcon = function() return Stub() end,
    SetItemIcon = function() end,
    CreateBar = function() return Stub() end,
    CreateHeading = function() return Stub({ rule = Stub() }) end,
    StyleHeading = function(label) label.rule = Stub(); return label end,
}

ns.Widgets = {
    CreateSearchBox = function() return Stub() end,
    CreateDropdown = function() return Stub() end,
    CreateCheckbox = function() return Stub() end,
    CreateNumberBox = function() return Stub() end,
    CreateButton = function() return Stub() end,
}


ns.Util = { GetItemQualityColor = function() end, FormatMoney = function(c) return tostring(c) end }
ns.COLORS = { profit = "ff4fd18b" }

local values = { [1] = 800, [2] = 1400 }
ns.Disenchant = { GetValue = function(_, itemID) return values[itemID] end }
local known = true
ns.Disenchanter = { Knows = function() return known end }

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

local DisenchantFor = PostPanel._DisenchantFor

local value, beats = DisenchantFor({ itemID = 1, unitPrice = 700 })
check("an enchanter sees the disenchant value", value == 800)
check("marked when it beats the listing price", beats == true)

value, beats = DisenchantFor({ itemID = 2, unitPrice = 5000 })
check("and not marked when listing pays more", value == 1400 and beats == false)

check("nothing for an item that cannot be disenchanted", DisenchantFor({ itemID = 3, unitPrice = 10 }) == nil)

known = false
check("nothing for a character without Disenchant", DisenchantFor({ itemID = 1, unitPrice = 700 }) == nil)

known = nil
check("shown when the client will not say", DisenchantFor({ itemID = 1, unitPrice = 700 }) == 800)

-- The list waits while a LIST box is being typed into: redrawn mid-number,
-- the row could be showing a different item when the number is entered.
local function Row(focused, shown)
    return {
        IsShown = function() return shown ~= false end,
        quantity = { editBox = { HasFocus = function() return focused end } },
    }
end
local TypingInList = PostPanel._TypingInList
check("typing in a LIST box holds the redraw", TypingInList({ rows = { Row(false), Row(true) } }))
check("otherwise the list redraws", not TypingInList({ rows = { Row(false), Row(false) } }))
check("a hidden row does not count", not TypingInList({ rows = { Row(true, false) } }))

-- A long name wraps, and the price line moves under it instead of running
-- over it; the row grows to hold both.
do
    local points = {}
    local row = { name = {}, detail = { SetPoint = function(_, point, _, _, _, y) points[point] = y end } }
    local PlaceDetail = PostPanel._PlaceDetail
    PlaceDetail(row, nil)
    check("one line: the price line sits in its place", points.TOPLEFT == -18 and points.TOPRIGHT == -18)
    check("and the row keeps its height", row.name.rowNeed == nil)
    row.name.rowNeed = 24
    PlaceDetail(row, 24)
    check("a wrapped name pushes the price line down", points.TOPLEFT == -30 and points.TOPRIGHT == -30)
    check("and the row grows to hold it", row.name.rowNeed == 40)
end

-- The mark before the price line (UI/Marks.lua, 2026-10-31): a tag to
-- list, an hourglass while it waits, a lock while another addon keeps it.
do
    local MarkFor = PostPanel._MarkFor
    check("a row to list shows the tag", MarkFor({ itemID = 1 }) == "list")
    check("a row kept for another addon shows the lock", MarkFor({ held = "For your goal" }) == "kept")
    check("a row that waits shows the hourglass",
        MarkFor({ held = "Waiting, already 2 up", heldWaits = true }) == "waiting")
    check("no line, no mark", MarkFor(nil) == nil)

    local xs = {}
    local row = { name = {}, detail = { SetPoint = function(_, point, _, _, x) xs[point] = x end }, markGap = 22 }
    PostPanel._PlaceDetail(row, nil)
    check("the price line starts past the mark", xs.TOPLEFT == 22)
end

print(("\n%d check(s) passed\n"):format(checks))
