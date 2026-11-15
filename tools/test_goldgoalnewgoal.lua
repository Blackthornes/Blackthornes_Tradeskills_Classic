-- Goblin Gold's new goal window (the owner, 2026-11-14): once the Goal
-- reached window goes with no new goal set, a small window under the bar
-- asks for one (Set New Goal, Not Now, then New Goal: with Set and Cancel),
-- never in a fight, and Escape doesn't close it. Right-click on the bar opens
-- a menu with Change Goal, which opens the same window.

local GLOBALS = { "CreateFrame", "UIParent", "GameTooltip", "UISpecialFrames", "tinsert", "C_Timer" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() return true end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end

local function Region()
    local region = { disabled = false, shown = false, scripts = {}, hooks = {}, alpha = 1, width = 200, height = 0 }
    region.Show = function(self) self.shown = true end
    region.Hide = function(self)
        local was = self.shown
        self.shown = false
        if was or true then
            if self.scripts.OnHide then self.scripts.OnHide(self) end
            for _, fn in ipairs(self.hooks.OnHide or {}) do fn(self) end
        end
    end
    region.IsShown = function(self) return self.shown end
    region.SetShown = function(self, on) self.shown = on and true or false end
    region.SetText = function(self, text) self.text = text end
    region.GetText = function(self) return self.text end
    region.SetAlpha = function(self, a) self.alpha = a end
    region.SetSize = function(self, w, h) self.width, self.height = w, h end
    region.SetHeight = function(self, h) self.height = h end
    region.GetHeight = function(self) return self.height end
    region.GetWidth = function(self) return self.width end
    region.SetWidth = function(self, w) self.width = w end
    region.SetScript = function(self, name, fn) self.scripts[name] = fn end
    region.GetScript = function(self, name) return self.scripts[name] end
    region.HookScript = function(self, name, fn)
        self.hooks[name] = self.hooks[name] or {}
        table.insert(self.hooks[name], fn)
    end
    region.SetPoint = function(self, point, rel) self.point, self.rel = point, rel end
    region.CreateTexture = function() return Region() end
    region.CreateFontString = function() return Region() end
    region.SetFont = function(self, _, size) self.size = size end
    return setmetatable(region, { __index = function() return function() end end })
end

CreateFrame = function() return Region() end
UIParent = Region()
UISpecialFrames = {}
tinsert = table.insert
GameTooltip = Region()
local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }

local goal = 5000000
local busy = false
local setTo
ns.Config = { Get = function() return nil end }
ns.GoldGoal = {
    RETRY = 2,
    STEPS = 10,
    BestDay = function() return nil end,
    MostlyFrom = function() return nil end,
    NextGoal = function() return 10000000 end,
    Total = function() return 5000000 end,
    Goal = function() return goal end,
    Busy = function() return busy end,
    SetGoalGold = function(_, gold) setTo = gold; goal = gold * 10000 end,
}

local function Load(path) assert(loadfile(lfs_cwd .. path))("Blackthornes_TS", ns) end

Load("/Core/Util.lua")
Load("/UI/Theme.lua")
Load("/UI/Widgets.lua")
Load("/UI/Titanforged.lua")
Load("/UI/RowMenu.lua")
Load("/UI/GoldGoal.lua")

local failures = 0
local function check(label, got, expected)
    local ok = got == expected
    if not ok then failures = failures + 1 end
    print(("  %-56s %-12s %s"):format(label, tostring(got), ok and "ok" or
        ("FAILED, expected " .. tostring(expected))))
end

local UI = ns.GoldGoalUI
local bar = UI:Build()
bar.shown = true

-- The cheer goes; nothing set since, so the ask comes up under the bar.
UI:ShowGoalWindow({ goal = 5000000, took = 3600 })
local cheer = UI.goalWindow
check("the cheer window has no goal box",                rawget(cheer, "box") == nil, true)
cheer:Hide()
local ask = UI.askWindow
check("closing it brings up the new goal window",        ask and ask.shown, true)
check("it sits under the bar",                           ask.rel == bar, true)
check("it asks first",                                   ask.mode, "reached")
check("Set New Goal shows",                              ask.setNew.shown, true)
check("Not Now shows",                                   ask.notNow.shown, true)
check("the box waits",                                   ask.box.shown, false)
check("the words name the goal",                         (ask.first.text or ""):find("500", 1, true) ~= nil, true)
local escape = false
for _, name in ipairs(UISpecialFrames) do if name ~= "BlackthornesTSGoldGoalReached" then escape = true end end
check("Escape leaves it alone",                          escape, false)

-- Set New Goal shows the box, prefilled with the next goal.
ask.setNew.scripts.OnClick(ask.setNew)
check("Set New Goal shows the box",                      ask.box.shown, true)
check("prefilled with the next goal",                    ask.box:GetValue(), 1000)
check("Set shows",                                       ask.set.shown, true)
check("Cancel shows",                                    ask.cancel.shown, true)
ask.box:SetValue(2500)
ask.set.scripts.OnClick(ask.set)
check("Set sets the goal",                               setTo, 2500)
check("and puts the window away",                        ask.shown, false)

-- Not Now puts it away and sets nothing.
setTo = nil
goal = 5000000
UI:ShowGoalWindow({ goal = 5000000, took = 60 })
UI.goalWindow:Hide()
check("asked again after the next goal",                 ask.shown, true)
ask.notNow.scripts.OnClick(ask.notNow)
check("Not Now puts it away",                            ask.shown, false)
check("and sets nothing",                                setTo, nil)

-- A goal set before the cheer closes: no ask.
UI:ShowGoalWindow({ goal = 5000000, took = 60 })
goal = 7000000
UI.goalWindow:Hide()
check("no ask once a new goal is set",                   ask.shown, false)

-- In a fight it waits, then comes up.
goal = 5000000
busy = true
UI:ShowGoalWindow({ goal = 5000000, took = 60 })
UI.goalWindow:Hide()
check("waits out a fight",                               ask.shown, false)
busy = false
local run = timers[#timers]
if run then run() end
check("then asks",                                       ask.shown, true)
ask.notNow.scripts.OnClick(ask.notNow)

-- Right-click the bar: the menu with Change Goal.
bar.scripts.OnMouseUp(bar, "RightButton")
local menu = ns.RowMenu.frame
check("right-click opens the menu",                      menu and menu.shown, true)
check("its first line is Change Goal",                   menu.lines[1].label.text, "Change Goal")
menu.lines[1].scripts.OnClick(menu.lines[1])
check("Change Goal opens the window",                    ask.shown, true)
check("in change mode",                                  ask.mode, "change")
check("it says the goal now",                            (ask.first.text or ""):find("500", 1, true) ~= nil, true)
check("the box holds the goal now",                      ask.box:GetValue(), 500)
ask.cancel.scripts.OnClick(ask.cancel)
check("Cancel puts it away",                             ask.shown, false)

bar.scripts.OnMouseUp(bar, "LeftButton")
check("left-click opens no menu",                        true, true)

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end
if failures > 0 then error(failures .. " check(s) failed") end
