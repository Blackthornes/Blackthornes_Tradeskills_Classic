-- The Potential Sale Total in the drawer's header, counting up as you list
-- (2026-10-28, counting up since 2026-10-29).
--
-- What must hold:
--   1. Net takes the auction house cut; Left skips held lines and counts the
--      rest.
--   2. Milestones fall on round numbers: 10g under 100g, then the power of
--      ten below the total.
--   3. Only the label and the number: "Potential Sale Total:" and no line
--      under the number.
--   4. On by default; off when unticked.
--   5. A visit starts at 0, each listing counts up by its net and comes off
--      what is left, and nothing is written to the save.

local GLOBALS = { "CreateFrame", "GetTime", "GameTooltip" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local function check(cond, message)
    if not cond then error(message, 2) end
end

local G = 10000

-- A frame, texture or font string that takes any call.
local function Stub()
    local object = { shown = true, text = "" }
    return setmetatable(object, { __index = function(_, key)
        if key == "IsShown" then return function(self) return self.shown end end
        if key == "SetShown" then return function(self, on) self.shown = on and true or false end end
        if key == "Show" then return function(self) self.shown = true end end
        if key == "Hide" then return function(self) self.shown = false end end
        if key == "SetText" then return function(self, text) self.text = text end end
        if key == "GetFrameLevel" then return function() return 1 end end
        if key == "CreateTexture" or key == "CreateFontString" then return function() return Stub() end end
        return function() end
    end })
end
CreateFrame = function() return Stub() end
local clock = 100
GetTime = function() return clock end
GameTooltip = Stub()

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
local settings = {}
ns.Config = { Get = function(_, k) return settings[k] end, Set = function(_, k, v) settings[k] = v end }
ns.Util = {
    Comma = function(n) return tostring(n) end,
    FormatMoney = function(c) return tostring(math.floor(c / 10000)) .. "g" end,
}
-- The auction house keeps 5%.
ns.Profit = { NetFromListing = function(_, _, unit) return unit * 0.95 end }
ns.Theme = {
    FONT = "font", sizes = { title = 16 },
    Fill = function() return Stub() end, Border = function() end,
    AccentStripe = function() return Stub() end, SetGradientAlpha = function() end,
    LightGradient = function() end, CreateLabel = function() return Stub() end,
    Unpack = function() return 1, 1, 1, 1 end, TextWidth = function() return 40 end,
}
-- Subtle: the number rolls, no coins fly; every tween lands at once.
ns.Motion = {
    Level = function() return "subtle" end,
    Run = function(_, _, _, _, apply, opts) apply(1); if opts and opts.done then opts.done() end end,
    Stop = function() end, SetValue = function() end,
    Blend = function(_, _, _, target, _, apply) apply(target) end,
    EaseOut = function(p) return p end, EaseOutBack = function(p) return p end,
}

assert(loadfile(lfs_cwd .. "/UI/SaleTotal.lua"))("Blackthornes_TS", ns)
local ST = ns.SaleTotal

-- 1. Net and Left.
check(ST.Net(1, 100 * G, 2) == 190 * G, "a listing counts its net, times the stack")
check(ST.Net(1, 0, 5) == 0, "nothing priced counts nothing")
local left, count = ST.Left({
    { itemID = 1, unitPrice = 10 * G, postQuantity = 2 },
    { itemID = 2, unitPrice = 50 * G, postQuantity = 1, held = true },
    { itemID = 3, postTotal = 4 * G },
})
check(left == 19 * G + 4 * G, "held lines are left out; a line with no price uses its total")
check(count == 2, "held lines are not counted")

-- 2. Milestones.
check(ST.MilestoneStep(40 * G) == 10 * G, "under 100g milestones are every 10g")
check(ST.MilestoneStep(450 * G) == 100 * G, "at 450g they are every 100g")
check(ST.MilestoneStep(1000 * G) == 1000 * G, "at 1,000g every 1,000g")
check(ST.Crossed(95 * G, 104 * G) == 100 * G, "passing 100g is a milestone")
check(ST.Crossed(101 * G, 150 * G) == nil, "no round number passed, no milestone")
check(ST.Crossed(150 * G, 100 * G) == nil, "going down is never a milestone")

check(ST.MoneyText(0) == "0g", "nothing shows as 0g")

-- 4. The switch.
check(ST:IsOn(), "on by default")
settings.saleTotal = false
check(not ST:IsOn(), "off when unticked")
settings.saleTotal = nil

-- 5. A visit.
local bar = Stub()
ST:Attach(bar, Stub())
check(ST.counter and ST.counter:IsShown(), "the counter shows in the header")
check(ST:Width() > 0, "it takes room the header text gives way to")
-- 3. The label and the number only.
check(ST.label.text == "Potential Sale Total:", "the label reads Potential Sale Total:")
check(ST.under == nil and ST.UnderText == nil and ST.DrawUnder == nil, "there is no second line")
ST:Update({ { itemID = 1, unitPrice = 100 * G, postQuantity = 1 },
            { itemID = 2, unitPrice = 20 * G, postQuantity = 1 } }, 0)
check(ST.left == 114 * G and ST.count == 2, "the Sell list's net is what is left")
ST:NoteListed(1, 1, 100 * G)
check(ST.listed == 95 * G and ST.listings == 1, "a listing counts up by its net")
check(ST.left == 19 * G, "and comes off what is left")
check(ST.number.text ~= nil, "the number is drawn")
ST:NewVisit()
check(ST.listed == 0 and ST.listings == 0, "a new visit starts at 0")
check(settings.saleTotalBest == nil and settings.saleTotalLast == nil, "nothing is saved")
settings.saleTotal = false
check(ST:SetShown(true) == false and not ST.counter:IsShown(), "unticked, the counter hides")
check(ST:Width() == 0, "hidden, it takes no room")
settings.saleTotal = nil

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end
print("test_saletotal: ok")
