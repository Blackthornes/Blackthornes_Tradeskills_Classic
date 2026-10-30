-- Tradeskills' window in the one Blackthornes window (UI/Main.lua's TSTabs,
-- the owner said build it, 2026-10-30).
--
-- What must hold:
--   1. Off unless ticked: the window opens in its own place.
--   2. Ticked, opening Tradeskills opens the one window on it, with the
--      window laid into its area, bare of its own size grip, at scale 1.
--   3. Settings is a tab in the same area.
--   4. Closing the window closes the one window; closing the one window
--      gives the window back its own place, size and scale.
--   5. "One Window:" writes every save, and Settings opens again where it
--      now belongs.
--   6. At the auction house the sell drawer goes in an Auction House tab,
--      the window narrows to it and only the tabs that go with it show;
--      walking away gives everything back, and a one window opened for the
--      visit closes. Let go there, the drawer goes back beside the house.

local GLOBALS = { "CreateFrame", "UIParent", "GameTooltip", "GetCursorPosition", "C_Timer",
    "UISpecialFrames", "tinsert", "GetTime", "time", "BlackthornesWindow" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local function noop() end

local SCREEN_W, SCREEN_H = 1280, 720

-- Frames that remember their size, scale, points and scripts. The window's
-- edges are worked out from its one point, in its own units, as the game
-- does: an offset from UIParent's corner or centre, divided by its scale.
local function Region(parent)
    local region = { parent = parent, shown = true, width = 0, height = 0, scale = 1,
        points = {}, scripts = {}, frameLevel = 1 }

    region.SetSize = function(self, w, h) self.width, self.height = w, h end
    region.SetWidth = function(self, w) self.width = w end
    region.SetHeight = function(self, h) self.height = h end
    region.GetWidth = function(self) return self.width end
    region.GetHeight = function(self) return self.height end
    region.SetScale = function(self, s) self.scale = s end
    region.GetScale = function(self) return self.scale end
    region.GetEffectiveScale = function(self) return self.scale end
    region.SetPoint = function(self, point, relativeTo, relativePoint, x, y)
        if type(relativeTo) ~= "table" then
            relativeTo, relativePoint, x, y = self.parent, point, relativeTo, relativePoint
        end
        self.points = { { point, relativeTo, relativePoint, x or 0, y or 0 } }
    end
    region.ClearAllPoints = function(self) self.points = {} end
    region.GetPoint = function(self)
        local p = self.points[1]
        if not p then return nil end
        return p[1], p[2], p[3], p[4], p[5]
    end
    region.GetLeft = function(self)
        local p = self.points[1]
        if not p then return nil end
        if p[3] == "BOTTOMLEFT" then return p[4] end
        if p[3] == "CENTER" then return SCREEN_W / (2 * self.scale) + p[4] - self.width / 2 end
    end
    region.GetTop = function(self)
        local p = self.points[1]
        if not p then return nil end
        if p[3] == "BOTTOMLEFT" then return p[5] end
        if p[3] == "CENTER" then return SCREEN_H / (2 * self.scale) + p[5] + self.height / 2 end
    end
    region.GetRight = function(self)
        local left = self:GetLeft()
        return left and left + self.width
    end
    region.GetBottom = function(self)
        local top = self:GetTop()
        return top and top - self.height
    end
    region.Show = function(self) self.shown = true end
    region.Hide = function(self)
        local was = self.shown
        self.shown = false
        if was and self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    region.IsShown = function(self) return self.shown end
    region.SetScript = function(self, name, fn) self.scripts[name] = fn end
    region.GetScript = function(self, name) return self.scripts[name] end
    region.HookScript = function(self, name, fn)
        local old = self.scripts[name]
        self.scripts[name] = function(...) if old then old(...) end fn(...) end
    end
    region.SetParent = function(self, p) self.parent = p end
    region.GetParent = function(self) return self.parent end
    region.SetShown = function(self, on) if on then self:Show() else self:Hide() end end
    region.GetFrameLevel = function(self) return self.frameLevel end
    region.SetFrameLevel = function(self, level) self.frameLevel = level end
    region.CreateTexture = function(self) return Region(self) end
    region.CreateFontString = function(self) return Region(self) end
    region.GetStringWidth = function() return 40 end
    region.GetUnboundedStringWidth = function() return 40 end
    region.GetStringHeight = function() return 12 end

    return setmetatable(region, { __index = function(_, key)
        if type(key) == "string" and key:match("^%u") then return noop end
    end })
end

CreateFrame = function(_, _, parent) return Region(parent) end
UIParent = Region()
UIParent.width, UIParent.height = SCREEN_W, SCREEN_H

GameTooltip = Region()
GameTooltip.SetOwner = function(self, owner) self.owner, self.lines = owner, {} end
GameTooltip.IsOwned = function(self, frame) return self.owner == frame end
GameTooltip.SetText = function(self, text) self.lines = { text } end
GameTooltip.AddLine = function(self, text) self.lines[#self.lines + 1] = text end

local cursorX, cursorY = 0, 0
GetCursorPosition = function() return cursorX, cursorY end
C_Timer = { After = noop }
UISpecialFrames = {}
tinsert = table.insert
GetTime = function() return 0 end
time = function() return 1000 end
BlackthornesWindow = nil

local settings = {}
local commands = {}
local reflows = 0

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = ns[name] or {}; ns[name] = m; return m end
ns.RegisterCommand = function(name, _, fn) commands[name] = fn end
ns.RegisterEvent = function() return true end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = noop, noop, noop, noop
ns.db = { global = {}, settings = settings }
ns.Config = {
    DEFAULTS = { settings = { windowScale = 1 } },
    Get = function(_, key) return settings[key] end,
    Set = function(_, key, value) settings[key] = value end,
}
ns.Scanner = { isAuctionHouseOpen = false }
local versionAsked = 0
ns.VersionLabel = function() versionAsked = versionAsked + 1; return "v0.42.0" end

local function Load(path)
    assert(loadfile(lfs_cwd .. path))("Blackthornes_TS", ns)
end

Load("/Core/Util.lua")
Load("/UI/Theme.lua")
Load("/UI/Widgets.lua")
Load("/UI/Main.lua")
Load("/UI/SharedWindow.lua")

local UI = ns.UI
ns.PostPanel = { Reflow = function() reflows = reflows + 1 end }

local UI, Tabs, SW = ns.UI, ns.TSTabs, ns.SharedWindow
ns.PostPanel = { Reflow = function() reflows = reflows + 1 end }
ns.Prices = { Count = function() return 0 end, GetLastScan = function() return nil end }
ns.Recipes = { Count = function() return 0 end }
ns.Scanner.isScanning = false
UI.UpdateHeader = function() end
UI:RegisterTab({ key = "profit", text = "Profit", order = 1 })
UI:RegisterTab({ key = "sales", text = "Sales", order = 5 })
UI:RegisterTab({ key = "settings", text = "Settings", order = 9 })
settings.windowScale = 0.8

local passed, failed = 0, 0
local function check(label, ok)
    if ok then passed = passed + 1 else failed = failed + 1 end
    print(string.format("  %-60s %s", label, ok and "ok" or "WRONG"))
end

UI.minimapButton = Region()
ns.SharedMinimap = { Join = noop }
UI:JoinSharedMinimap()
local hub = _G.BlackthornesWindow
check("Tradeskills joins with its window", hub.entries.tradeskills and hub.entries.tradeskills.host == Tabs.host)

print("1. off")
UI:Show()
check("opens by itself", UI.window:IsShown() and not Tabs:Hosted())
check("at its own size", UI.window:GetScale() == 0.8)
UI:Hide()

print("2. on")
SW.SetOn(true)
UI:Show()
local area = hub.frame and hub.frame.area
check("the one window opens", hub.frame and hub.frame:IsShown())
check("on Tradeskills", hub.current == hub.entries.tradeskills and ns.db.oneWindowPick == "tradeskills")
check("the window is in it", Tabs:Hosted() and UI.window:GetParent() == area and UI.window:IsShown())
check("at scale 1", UI.window:GetScale() == 1)
check("without its own size grip", not UI.sizeGrip:IsShown())
local before = ns.db.windowPosition
UI:SavePosition()
check("keeps no place of its own", ns.db.windowPosition == before)

print("3. settings")
UI:OpenSettings()
check("Settings shows in the same area", UI.activeTab == "settings" and UI.window:GetParent() == area
    and UI.window:IsShown() and hub.frame:IsShown())

print("4. closing")
UI:Hide()
check("closing it closes the one window", not hub.frame:IsShown() and not Tabs:Hosted())
check("the window is back on its own", UI.window:GetParent() == UIParent and not UI.window:IsShown())
check("with its grip", UI.sizeGrip:IsShown())
check("at its own size again", UI.window:GetScale() == 0.8 and UI.window:GetWidth() == 1120)
UI:Show()
check("it opens in the one window again", Tabs:Hosted() and hub.frame:IsShown())
hub.frame:Hide()
check("the one window's close lets it go", not Tabs:Hosted() and UI.window:GetParent() == UIParent
    and not UI.window:IsShown())

print("5. the setting")
local other = {}
SW:Join({ key = "pets", order = 3, name = "Pets", db = function() return other end })
UI:OpenSettings()
check("Settings opens in the one window", Tabs:Hosted() and UI.activeTab == "settings")
Tabs:SetOneWindow(false)
check("unticked in every save", ns.db.oneWindow == false and other.oneWindow == false)
check("Settings opens on its own", not Tabs:Hosted() and UI.window:IsShown()
    and UI.window:GetParent() == UIParent and UI.activeTab == "settings")
Tabs:SetOneWindow(true)
check("ticked in every save", ns.db.oneWindow == true and other.oneWindow == true)
check("and Settings moves into the one window", Tabs:Hosted() and UI.window:IsShown()
    and UI.activeTab == "settings")

print("6. at the auction house")
local laidIn, laidOut, attached = nil, 0, 0
ns.PostPanel = {
    Reflow = function() reflows = reflows + 1 end,
    LayIn = function(self, container) self.inside = container; laidIn = container end,
    LayOut = function(self) self.inside = nil; laidOut = laidOut + 1 end,
    Attach = function() attached = attached + 1 end,
}
local strip = UI.tabStrip
check("away from it, no Auction House tab", not strip:Shows("auctionhouse") and strip:Shows("sales"))
UI:SelectTab("auctionhouse")
check("and asking for it opens Profit", UI.activeTab == "profit")
hub.frame.area.width = 1120
local wide = hub.frame:GetWidth()
ns.Scanner.isAuctionHouseOpen = true
Tabs:AuctionOpened()
check("the Auction House tab shows", UI.activeTab == "auctionhouse" and strip:Shows("auctionhouse"))
check("the drawer is laid in it", laidIn ~= nil and laidIn == UI.tabs.auctionhouse.container)
check("only the tabs that go with it", strip:Shows("profit") and strip:Shows("settings")
    and not strip:Shows("sales"))
check("the window narrows to it", hub.frame:GetWidth() == wide - (1120 - UI.AUCTION_TAB_WIDTH))
check("the window's own Scan steps aside", not UI.scanButton:IsShown())
UI:SelectTab("profit")
check("Profit gets the whole width", hub.frame:GetWidth() == wide and UI.scanButton:IsShown())
UI:SelectTab("auctionhouse")
check("never kept as the last tab", ns.db.lastTab ~= "auctionhouse")
Tabs:AuctionClosed()
ns.Scanner.isAuctionHouseOpen = false
check("the drawer comes out", laidOut == 1 and not ns.PostPanel.inside)
check("the tabs come back", strip:Shows("sales") and not strip:Shows("auctionhouse"))
check("off the Auction House tab, at the whole width", UI.activeTab ~= "auctionhouse"
    and hub.frame:GetWidth() == wide)
check("the one window stays up", hub.frame:IsShown() and Tabs:Hosted())

hub.frame:Hide()
check("closed before the visit", not hub.frame:IsShown())
ns.Scanner.isAuctionHouseOpen = true
Tabs:AuctionOpened()
check("the auction house opens it on the Auction House tab", hub.frame:IsShown() and Tabs:Hosted()
    and UI.activeTab == "auctionhouse")
Tabs:AuctionClosed()
ns.Scanner.isAuctionHouseOpen = false
check("and it closes again as you walk away", not hub.frame:IsShown() and not Tabs:Hosted())

ns.Scanner.isAuctionHouseOpen = true
Tabs:AuctionOpened()
local before = attached
hub.frame:Hide()
check("closed at the auction house, the drawer goes back beside it", not ns.PostPanel.inside
    and attached == before + 1)
Tabs:AuctionClosed()
ns.Scanner.isAuctionHouseOpen = false
check("off the Auction House tab after", not Tabs.atAuction)

SW.SetOn(false)
for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end
print(string.format("onewindow: %d passed, %d failed", passed, failed))
if failed > 0 then error("onewindow: " .. failed .. " failed") end
