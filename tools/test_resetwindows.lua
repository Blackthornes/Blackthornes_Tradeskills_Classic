-- "Window Places:" Reset and /bts resetwindows (a player's window slid off
-- the screen, 2026-11-11), outside WoW.
--
-- What must hold:
--   1. The main window's everyday and auction house spots, the arrow's and
--      Your Way There's are cleared, and each window shown is placed again.
--   2. The gold bar and My Auctions use their own ResetPlace.
--   3. Sizes stay as they were.
--   4. The sell list is put away away from the auction house, and docked
--      again at it; one never built is left alone.
--   5. The command is registered and does the same.

local GLOBALS = { "CreateFrame", "UIParent", "C_Timer", "Minimap", "GetTime", "time" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local function noop() end
local function NewFrame()
    return setmetatable({}, { __index = function(_, k)
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
local commands = {}
ns.RegisterCommand = function(name, _, fn) commands[name] = fn end
local printed = {}
ns.Print = function(text) printed[#printed + 1] = text end
ns.PrintRaw, ns.Debug, ns.Warn = noop, noop, noop
ns.RegisterEvent = function() return true end
ns.Config = { Get = noop, Set = noop }
ns.Scanner = { isAuctionHouseOpen = false }
ns.Theme, ns.Widgets = {}, {}
ns.Crafting = {}

local calls = {}
local function Count(name) return function() calls[name] = (calls[name] or 0) + 1 end end
ns.PostPanel = { Refresh = noop, Place = noop, Hide = Count("panelHide"), Attach = Count("panelAttach") }

assert(loadfile(lfs_cwd .. "/Core/Util.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/UI/Main.lua"))("Blackthornes_TS", ns)

local UI = ns.UI
UI.RestorePosition = Count("mainRestore")
UI.window = NewFrame()
ns.GoldGoalUI = { ResetPlace = Count("goldReset") }
ns.AuctionTrackerUI = { ResetPlace = Count("trackerReset") }
ns.WayArrowUI = { frame = NewFrame(), RestorePosition = Count("arrowRestore") }
ns.TravelCard = { frame = NewFrame(), RestorePlace = Count("cardRestore") }

local passed, failed = 0, 0
local function check(label, got, want)
    if got == want then passed = passed + 1 else
        failed = failed + 1
        print(string.format("FAIL %s: got %s, want %s", label, tostring(got), tostring(want)))
    end
end

local function Fresh()
    ns.db = {
        windowPosition = { point = "TOPLEFT", x = 10, y = -5000, scale = 1 },
        auctionWindowPosition = { point = "BOTTOMRIGHT", x = 0, y = -900, scale = 1 },
        wayArrowX = 5, wayArrowY = -800, travelCardX = 3000, travelCardY = 4,
        windowScale = 1.2, wayArrowSize = 75, travelCardScale = 90,
    }
    calls = {}
end

-- 1 to 4, away from the auction house, the sell list left up.
Fresh()
ns.PostPanel.frame = NewFrame()
UI:ResetWindowPlaces()
check("everyday spot cleared", ns.db.windowPosition, nil)
check("auction spot cleared", ns.db.auctionWindowPosition, nil)
check("arrow cleared", ns.db.wayArrowX == nil and ns.db.wayArrowY == nil, true)
check("card cleared", ns.db.travelCardX == nil and ns.db.travelCardY == nil, true)
check("main placed again", calls.mainRestore, 1)
check("arrow placed again", calls.arrowRestore, 1)
check("card placed again", calls.cardRestore, 1)
check("gold bar reset", calls.goldReset, 1)
check("my auctions reset", calls.trackerReset, 1)
check("sizes kept", ns.db.windowScale == 1.2 and ns.db.wayArrowSize == 75 and ns.db.travelCardScale == 90, true)
check("sell list put away", calls.panelHide, 1)
check("sell list not docked", calls.panelAttach, nil)

-- At the auction house the sell list docks again.
Fresh()
ns.Scanner.isAuctionHouseOpen = true
UI:ResetWindowPlaces()
check("sell list docked", calls.panelAttach, 1)
check("sell list not hidden", calls.panelHide, nil)
ns.Scanner.isAuctionHouseOpen = false

-- A sell list never built, and an arrow and card never built, are left alone.
Fresh()
ns.PostPanel.frame = nil
ns.WayArrowUI.frame, ns.TravelCard.frame = nil, nil
UI:ResetWindowPlaces()
check("unbuilt sell list left", (calls.panelHide or 0) + (calls.panelAttach or 0), 0)
check("unbuilt arrow left", calls.arrowRestore, nil)
check("unbuilt card left", calls.cardRestore, nil)
check("unbuilt arrow still cleared", ns.db.wayArrowX, nil)

-- 5. The command.
Fresh()
printed = {}
check("command registered", type(commands.resetwindows), "function")
commands.resetwindows("")
check("command clears", ns.db.windowPosition, nil)
check("command says so", printed[1], "Every Tradeskills window is back where it starts.")

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print(string.format("test_resetwindows: %d passed, %d failed", passed, failed))
if failed > 0 then
    error(string.format("%d check(s) failed", failed))
end
