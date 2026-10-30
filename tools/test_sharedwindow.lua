-- The one Blackthornes window (UI/SharedWindow.lua), outside WoW. The same
-- test in all five Blackthornes addons.
--
-- What must hold:
--   1. Off unless ticked; ticking writes every save, and the newest wins.
--   2. Only an addon whose pages moved in (host) is hosted, and only while on.
--   3. The rail has a button for each addon, in order.
--   4. Picking an addon that moved in lays its pages in and lets the last
--      one go; one that has not opens its own window.
--   5. The pick, place and scale are kept in every save; closing lets the
--      pages go; unticking closes the window.

local NAMES = { "CreateFrame", "UIParent", "C_Timer", "time", "BlackthornesWindow",
    "UISpecialFrames", "GetCursorPosition" }
local saved = {}
for _, name in ipairs(NAMES) do saved[name] = _G[name] end

local function Object()
    local o = { shown = true, scripts = {}, scale = 1, left = 100, top = 600 }
    function o:Show() self.shown = true end
    function o:Hide()
        local was = self.shown
        self.shown = false
        if was and self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    function o:IsShown() return self.shown end
    function o:SetScript(name, fn) self.scripts[name] = fn end
    function o:SetText(text) self.text = text end
    function o:SetTexture(texture) self.texture = texture end
    function o:SetScale(scale) self.scale = scale end
    function o:GetScale() return self.scale end
    function o:GetLeft() return self.left end
    function o:GetTop() return self.top end
    function o:GetEffectiveScale() return 1 end
    function o:GetFrameLevel() return 1 end
    function o:IsMouseOver() return false end
    function o:CreateTexture() return Object() end
    function o:CreateFontString() return Object() end
    return setmetatable(o, { __index = function() return function() end end })
end

CreateFrame = function() local f = Object(); f.shown = true; return f end
UIParent = Object()
C_Timer = nil
UISpecialFrames = {}
local clock = 1000
time = function() return clock end
BlackthornesWindow = nil

local ns = {
    Theme = {
        Unpack = function() return 0, 0, 0, 1 end,
        Fill = function() end,
        Border = function() end,
        CreateLabel = function() return Object() end,
    },
}
local chunk = assert(loadfile(lfs_cwd .. "/UI/SharedWindow.lua"))
chunk("Blackthornes_Test", ns)
local SW = ns.SharedWindow
assert(SW, "SharedWindow loads")

local log = {}
local function Entry(key, order, db, hosted)
    local entry = {
        key = key, order = order, name = key, icon = "icon-" .. key,
        db = function() return db end,
        open = function() log[#log + 1] = "open " .. key end,
        settings = function() log[#log + 1] = "settings " .. key end,
    }
    if hosted then
        entry.host = {
            enter = function(area) assert(area, "enter gets the area"); log[#log + 1] = "enter " .. key end,
            leave = function() log[#log + 1] = "leave " .. key end,
        }
    end
    return entry
end

-- 1. Off unless ticked.
local dbA, dbB, dbC = {}, {}, {}
local a = Entry("alpha", 1, dbA, true)
local b = Entry("beta", 2, dbB, false)
local c = Entry("gamma", 3, dbC, true)
SW:Join(c)
SW:Join(a)
SW:Join(b)
assert(not SW.On(), "off unless ticked")
SW.SetOn(true)
assert(SW.On(), "ticked")
assert(dbA.oneWindow == true and dbB.oneWindow == true and dbC.oneWindow == true, "every save says on")
assert(dbA.oneWindowAt == clock, "the time is kept")
dbB.oneWindow, dbB.oneWindowAt = false, clock + 10
assert(not SW.On(), "the newest answer wins")
SW.SetOn(true)

-- 2. Only an addon that moved in is hosted.
assert(SW.Hosts("alpha") and not SW.Hosts("beta"), "only hosts moved-in pages")
assert(not SW.Hosts("nobody"), "an unknown addon is not hosted")

-- 3 and 4. Open on the first that moved in; the rail is in order.
assert(SW.Open(), "opens")
assert(SW.IsOpen(), "shown")
local frame = BlackthornesWindow.frame
assert(frame.rail.buttons[1].entry == a and frame.rail.buttons[2].entry == b
    and frame.rail.buttons[3].entry == c, "rail in order")
assert(frame.rail.buttons[3].icon.texture == "icon-gamma", "rail shows the icon")
assert(log[#log] == "enter alpha", "the first that moved in shows")
assert(dbA.oneWindowPick == "alpha" and dbC.oneWindowPick == "alpha", "the pick is kept everywhere")

assert(not SW.Pick("beta"), "one that has not moved in is not picked")
assert(log[#log] == "open beta", "it opens its own window")

assert(SW.Pick("gamma"), "picks the next")
assert(log[#log - 1] == "leave alpha" and log[#log] == "enter gamma", "the last one lets go first")
frame.rail.buttons[1].scripts.OnClick(frame.rail.buttons[1], "RightButton")
assert(log[#log] == "settings alpha", "right-click opens its settings")

-- 5. Place and scale.
frame.scripts.OnDragStop(frame)
assert(dbA.oneWindowLeft == 100 and dbB.oneWindowTop == 600, "the place is kept everywhere")
frame.grip.scripts.OnClick(frame.grip, "RightButton")
assert(dbA.oneWindowScale == 100, "right-click is the normal size")
assert(SW.Clamp(10) == 50 and SW.Clamp(400) == 150 and SW.Clamp(nil) == 100, "the scale stays in range")

SW.Close()
assert(log[#log] == "leave gamma", "closing lets the pages go")
assert(SW.Open(), "opens again")
assert(log[#log] == "enter gamma", "on the addon picked last")
SW.SetOn(false)
assert(not SW.IsOpen(), "unticking closes it")
assert(not SW.Hosts("gamma"), "nothing is hosted while off")

for _, name in ipairs(NAMES) do _G[name] = saved[name] end
print("test_sharedwindow: ok")
