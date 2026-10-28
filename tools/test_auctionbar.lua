-- The Scan bar is the drawer's header (UI/Main.lua's GetAuctionBar).
--
-- At the auction house the bar is asked for first, and making it builds the
-- drawer, which asks for the bar again for its header. The inner call made
-- the bar the drawer showed; the outer call then made a second one and hung
-- Scan and Post Crafted on that, so the drawer's header had neither
-- (2026-10-13: "where is the scan button now?"). There must be one bar, and
-- it must be the drawer's header.

local GLOBALS = { "CreateFrame", "UIParent", "C_Timer", "Minimap", "GetTime", "time" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local function noop() end
local NewFrame
local function Create() return NewFrame() end
NewFrame = function()
    return setmetatable({}, { __index = function(_, k)
        if type(k) == "string" and k:match("^Create") then return Create end
        if type(k) == "string" and k:match("^%u") then return noop end
    end })
end
CreateFrame = function() return NewFrame() end
UIParent = NewFrame()
Minimap = nil
GetTime = function() return 0 end
time = function() return 100000 end
C_Timer = { After = noop, NewTicker = function() return { Cancel = noop } end }

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = noop
ns.RegisterEvent = function() return true end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = noop, noop, noop, noop
ns.db = {}
ns.Queue, ns.Inventory, ns.Prices, ns.Config, ns.Auctions = {}, {}, {}, {}, {}
ns.Scanner = { isAuctionHouseOpen = true, isScanning = false }
ns.Posting = { IsBlocked = function() return false end }
ns.Theme = {
    Fill = noop, TopSheen = noop, AccentStripe = noop,
    CreateDivider = function() return NewFrame() end,
    CreateLabel = function() return NewFrame() end,
    Unpack = function() return 1, 1, 1, 1 end,
}
ns.Widgets = { CreateProgressBar = function() return NewFrame() end }

-- The drawer, built the way UI/PostPanel.lua builds it: its frame first,
-- then the bar asked for as its header.
ns.PostPanel = {}
function ns.PostPanel:Build()
    if self.frame then return self.frame end
    self.frame = NewFrame()
    self.header = ns.UI:GetAuctionBar()
    return self.frame
end

assert(loadfile(lfs_cwd .. "/Core/Util.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/UI/Main.lua"))("Blackthornes_TS", ns)

local UI = ns.UI

local passed, failed = 0, 0
local function check(label, got, want)
    local ok = got == want
    if ok then passed = passed + 1 else failed = failed + 1 end
    print(string.format("  %-58s %-6s %s", label, tostring(got), ok and "ok" or
        ("WRONG, wanted " .. tostring(want))))
end

print("")
print("the bar asked for before the drawer is built")

local bar = UI:GetAuctionBar()
check("the drawer was built", ns.PostPanel.frame ~= nil, true)
check("the bar the buttons go on is the drawer's header", bar == ns.PostPanel.header, true)
check("asked again, the same bar", UI:GetAuctionBar() == bar, true)

-- Post Crafted is taken off the header for now (2026-10-16), with its
-- code kept behind UI.POST_CRAFTED_BUTTON. Scan keeps its place, and the
-- status line runs up to Scan alone.
print("")
print("the header without Post Crafted")

local made = 0
ns.Widgets.CreateButton = function()
    made = made + 1
    local button = NewFrame()
    button.GetWidth = function() return 56 end
    return button
end
bar.GetWidth = function() return 350 end
local statusWidth
if bar.status then bar.status.SetWidth = function(_, width) statusWidth = width end end

check("the button is off", UI.POST_CRAFTED_BUTTON, false)
UI.auctionButton = ns.Widgets.CreateButton()
made = 0
UI:AttachPostButton()
check("no Post Crafted button is made", UI.postButton, nil)
check("no button made at all", made, 0)
if bar.status then
    check("the status runs up to Scan", statusWidth, 350 - 10 - 10 - 56 - 10)
end
UI:UpdatePostButton()
check("updating it does nothing and raises nothing", UI.postButton, nil)
UI.auctionButton = nil

for key, value in pairs(saved) do _G[key] = value end

print("")
print(("%d passed, %d failed"):format(passed, failed))
assert(failed == 0, "auction bar checks failed")
