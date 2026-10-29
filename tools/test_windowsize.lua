-- The main window's size, outside WoW (a player's request, 2026-10-07: too
-- big on a 4K screen).
--
-- What must hold:
--   1. A size is kept between 50% and 150%, to a whole percent; "small",
--      "80", "80%" and "0.8" all read as 80%; names read "Small (80%)", and
--      a dragged size reads as its percent.
--   2. The window opens at the saved size, never bigger than the screen.
--   3. A new size keeps the top left corner where it was, is saved, and the
--      saved position remembers the size it was taken at; a position saved
--      at another size (or before sizes, at 1) lands on the same spot.
--   4. Dragging the grip sizes the window from its top left corner and saves
--      the size on release; right-click puts it back to normal.
--   5. The sell list measures a sized window in its own units.

local GLOBALS = { "CreateFrame", "UIParent", "GameTooltip", "GetCursorPosition", "C_Timer",
    "UISpecialFrames", "tinsert", "GetTime" }
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

local UI = ns.UI
ns.PostPanel = { Reflow = function() reflows = reflows + 1 end }

local passed, failed = 0, 0

local function near(a, b) return type(a) == "number" and math.abs(a - b) < 0.001 end

local function check(label, got, want)
    local ok
    if type(want) == "number" then ok = near(got, want) else ok = got == want end
    if ok then passed = passed + 1 else failed = failed + 1 end
    print(string.format("  %-60s %-10s %s", label, tostring(got), ok and "ok" or
        ("WRONG, wanted " .. tostring(want))))
end

print("")
print("1. sizes and their names")
check("nothing saved: normal", UI.ClampScale(nil), 1)
check("too small: 50%", UI.ClampScale(0.1), 0.5)
check("too big: 150%", UI.ClampScale(9), 1.5)
check("to a whole percent", UI.ClampScale(0.873), 0.87)
check("not a number: normal", UI.ClampScale(0 / 0), 1)
check("\"small\"", UI.ParseSize("small"), 0.8)
check("\"Large\"", UI.ParseSize("Large"), 1.2)
check("\"80%\"", UI.ParseSize("80%"), 0.8)
check("\"80\"", UI.ParseSize("80"), 0.8)
check("\"0.8\"", UI.ParseSize("0.8"), 0.8)
check("\"tiny\": not a size", UI.ParseSize("tiny"), nil)
check("nothing: not a size", UI.ParseSize(""), nil)
check("named", UI.ScaleText(1), "Normal (100%)")
check("named, small", UI.ScaleText(0.8), "Small (80%)")
check("dragged to", UI.ScaleText(0.87), "87%")

print("2. opening at the saved size")
settings.windowScale = 0.8
UI:Build()
local window = UI.window
check("opens at 80%", window:GetScale(), 0.8)
-- A player asked to see at a glance which version he runs (2026-10-09).
check("no version line in the header", UI.versionLabel, nil)
settings.windowScale = 1.5
check("150% on a 1280x720 screen: as big as fits", UI:GetWindowScale() < 1.5, true)
check("and the whole window fits", (1120 + 30) * UI:GetWindowScale() <= SCREEN_W, true)
settings.windowScale = 0.8

print("3. a new size from its top left corner")
window:ClearAllPoints()
window:SetScale(1)
window:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 100, 600)
local now = UI:SetWindowScale(0.5)
check("sized to 50%", window:GetScale(), 0.5)
check("returns the size it took", now, 0.5)
check("saved", settings.windowScale, 0.5)
check("left edge stays on screen at 100", window:GetLeft() * window:GetScale(), 100)
check("top edge stays on screen at 600", window:GetTop() * window:GetScale(), 600)
check("position saved with its size", ns.db.windowPosition.scale, 0.5)
check("the sell list told", reflows > 0, true)

ns.db.windowPosition = { point = "CENTER", relativePoint = "CENTER", x = 100, y = 50 }
UI:RestorePosition("windowPosition")
local _, _, _, x, y = window:GetPoint()
check("a position from before sizes, at 50%: x doubled", x, 200)
check("and y doubled", y, 100)

ns.db.windowPosition = { point = "CENTER", relativePoint = "CENTER", x = 100, y = 50, scale = 0.5 }
UI:RestorePosition("windowPosition")
_, _, _, x, y = window:GetPoint()
check("a position saved at this size: as saved", x, 100)

print("4. the grip")
local grip = UI.sizeGrip
check("there is a grip", grip ~= nil, true)
check("hung below the bottom right corner", select(3, grip:GetPoint()), "BOTTOMRIGHT")

window:ClearAllPoints()
window:SetScale(1)
window:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 50, 700)
-- Pressed 10 right of and 15 below the corner, where the grip hangs.
cursorX, cursorY = 50 + 1120 + 10, 700 - 548 - 15
grip.scripts.OnMouseDown(grip, "LeftButton")
check("sizing", grip.sizing, true)
-- Moved to where the corner would be at 80%.
cursorX, cursorY = 50 + 1120 * 0.8 + 10, 700 - 548 * 0.8 - 15
grip.scripts.OnUpdate(grip)
check("drawn at 80% while dragging", window:GetScale(), 0.8)
check("top left stays put (left)", window:GetLeft() * window:GetScale(), 50)
check("top left stays put (top)", window:GetTop() * window:GetScale(), 700)
cursorX, cursorY = 50 + 1120 * 0.3, 700 - 548 * 0.3
grip.scripts.OnUpdate(grip)
check("never under 50%", window:GetScale(), 0.5)
cursorX, cursorY = 50 + 1120 * 0.8 + 10, 700 - 548 * 0.8 - 15
grip.scripts.OnUpdate(grip)
grip.scripts.OnMouseUp(grip, "LeftButton")
check("saved on release", settings.windowScale, 0.8)
check("stopped", grip.scripts.OnUpdate, nil)
grip.scripts.OnMouseDown(grip, "RightButton")
check("right-click: normal again", window:GetScale(), 1)
check("and saved", settings.windowScale, 1)

grip.scripts.OnEnter(grip)
check("its tooltip names the size", GameTooltip.lines[1], "Normal (100%)")

print("5. /bts size")
commands.size("small")
check("/bts size small", settings.windowScale, 0.8)
commands.size("115%")
check("/bts size 115%", settings.windowScale, 1.15)
commands.size("tiny")
check("/bts size tiny changes nothing", settings.windowScale, 1.15)

print("6. the sell list measures a sized window in screen units")
do
    local postNs = { NewModule = function() return {} end, Theme = {}, Widgets = {}, Util = {} }
    local PostPanel
    postNs.NewModule = function() PostPanel = {}; return PostPanel end
    assert(loadfile(lfs_cwd .. "/UI/PostPanel.lua"))("Blackthornes_TS", postNs)

    local AH = { GetTop = function() return 1091 end, GetBottom = function() return 551 end,
        GetRight = function() return 851 end }
    -- Its own units at 50%: 2154 to 4274 wide, top at 1168, which on the
    -- screen is 1077 to 2137, top at 584.
    postNs.UI = { window = { IsShown = function() return true end, GetScale = function() return 0.5 end,
        GetLeft = function() return 2154 end, GetRight = function() return 4274 end,
        GetTop = function() return 1168 end } }
    check("stops above the window's real top", PostPanel:DesiredHeight(AH), 1091 - (584 + 6))
end

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print(string.format("\n%d passed, %d failed", passed, failed))
assert(failed == 0, "window size checks failed")
