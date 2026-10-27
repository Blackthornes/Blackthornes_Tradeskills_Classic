-- The Goal reached window wears the house frame (UI audit, 2026-10-27):
-- the gold rim, the Tradeskills plate and a red close gem that puts it
-- away, with Escape, its words and its Next Goal box as before.

local GLOBALS = { "CreateFrame", "UIParent", "GameTooltip", "UISpecialFrames", "tinsert" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() return true end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end

local function Region()
    local region = { shown = false, scripts = {}, alpha = 1, width = 200, height = 0 }
    region.Show = function(self) self.shown = true end
    region.Hide = function(self)
        self.shown = false
        if self.scripts.OnHide then self.scripts.OnHide(self) end
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

ns.Config = { Get = function() return nil end }
ns.GoldGoal = {
    BestDay = function() return nil end,
    MostlyFrom = function() return nil end,
    NextGoal = function() return 20000000 end,
    Total = function() return 10000000 end,
}

local function Load(path) assert(loadfile(lfs_cwd .. path))("Blackthornes_TS", ns) end

Load("/Core/Util.lua")
Load("/UI/Theme.lua")
Load("/UI/Widgets.lua")
Load("/UI/Titanforged.lua")
Load("/UI/GoldGoal.lua")

local failures = 0
local function check(label, got, expected)
    local ok = got == expected
    if not ok then failures = failures + 1 end
    print(("  %-56s %-12s %s"):format(label, tostring(got), ok and "ok" or
        ("FAILED, expected " .. tostring(expected))))
end

local UI = ns.GoldGoalUI
UI:ShowGoalWindow({ goal = 10000000, took = 3600 })
local window = UI.goalWindow

check("the window shows",                                window and window.shown, true)
check("it wears the house frame",                        window.titan ~= nil, true)
check("with the plate",                                  window.titan and window.titan.plate ~= nil, true)
local gem = window.titan and window.titan.closeButton
check("and a red close gem",                             gem ~= nil, true)
gem.scripts.OnClick(gem)
check("which puts it away",                              window.shown, false)
local escape = false
for _, name in ipairs(UISpecialFrames) do
    if name == "BlackthornesTSGoldGoalReached" then escape = true end
end
check("Escape still closes it",                          escape, true)
check("the Next Goal box is still there",                window.box ~= nil, true)
check("the three lines are still there",                 #window.lines, 3)

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end
if failures > 0 then error(failures .. " check(s) failed") end
