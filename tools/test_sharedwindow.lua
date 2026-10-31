-- The one Blackthornes window (UI/SharedWindow.lua), outside WoW. The same
-- test in all five Blackthornes addons.
--
-- What must hold:
--   1. On unless unticked; a choice writes every save, and the newest wins.
--   2. Only an addon whose pages moved in (host) is hosted, and only while on.
--   3. The rail has a button for each addon, in order.
--   4. Picking an addon that moved in lays its pages in and lets the last
--      one go; one that has not opens its own window.
--   5. The pick, place and scale are kept in every save; closing lets the
--      pages go; unticking closes the window.
--   6. Docking: up when the game's auction house, mailbox, vendor or
--      trainer opens, it sits beside it with the rail as a row along the
--      top, the area the same size; moving it there keeps its own place;
--      when the game's window closes it goes back to its place and the
--      addon open before, and stays closed when it was closed before.
--   7. At the auction house, while Tradeskills shows, the row of addon
--      buttons is left out; another addon picked there brings it back.
--   8. An open letter: docked at the mailbox, the window moves beside the
--      letter while it shows and back beside the mailbox when it closes;
--      watchers hear each dock, move and undock, and DockedFrame gives the
--      window only while it is docked.
--   9. Kept beside: while a game window is open, the window docks once the
--      game shows its window late, and is placed beside it again when the
--      game's window moves or this one changes width; nothing else moves it.

local NAMES = { "CreateFrame", "UIParent", "C_Timer", "time", "BlackthornesWindow",
    "UISpecialFrames", "GetCursorPosition", "GetTime", "MailFrame", "OpenMailFrame", "MerchantFrame", "AuctionFrame" }
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
    function o:HookScript(name, fn)
        self.hooks = rawget(self, "hooks") or {}
        self.hooks[name] = self.hooks[name] or {}
        table.insert(self.hooks[name], fn)
    end
    function o:Fire(name)
        for _, fn in ipairs((rawget(self, "hooks") or {})[name] or {}) do fn(self) end
    end
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
    function o:SetSize(w, h) self.width, self.height = w, h end
    function o:SetWidth(w) self.width = w end
    function o:SetHeight(h) self.height = h end
    function o:GetWidth() return self.width or 0 end
    function o:GetHeight() return self.height or 0 end
    function o:GetRight() return self.right end
    function o:ClearAllPoints() self.point = nil end
    function o:SetPoint(...) self.point = { ... } end
    return setmetatable(o, { __index = function() return function() end end })
end

CreateFrame = function() local f = Object(); f.shown = true; return f end
UIParent = Object()
C_Timer = nil
UISpecialFrames = {}
local clock = 1000
time = function() return clock end
BlackthornesWindow = nil
local now = 50
GetTime = function() return now end

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

-- 1. On unless unticked.
local dbA, dbB, dbC = {}, {}, {}
local a = Entry("alpha", 1, dbA, true)
local b = Entry("beta", 2, dbB, false)
local c = Entry("gamma", 3, dbC, true)
SW:Join(c)
SW:Join(a)
SW:Join(b)
assert(SW.On(), "on unless unticked")
assert(dbA.oneWindow == nil, "nothing is written until a choice")
SW.SetOn(false)
assert(not SW.On(), "unticked")
assert(dbA.oneWindow == false and dbC.oneWindow == false, "every save says off")
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
-- 6. Docking. Up on gamma, the game's mailbox opens.
MailFrame = Object()
MailFrame.right, MailFrame.top = 500, 700
OpenMailFrame = Object()
OpenMailFrame.shown = false
OpenMailFrame.right, OpenMailFrame.top = 860, 690
local width, height = frame:GetWidth(), frame:GetHeight()
dbA.oneWindowLeft, dbA.oneWindowTop = 100, 600
local heard = 0
SW.Watch(function() heard = heard + 1 end)
SW.Watch(function() error("a broken watcher") end)
assert(SW.DockedFrame() == nil, "nothing docked yet")
now = now + 5
SW.Arrived("mail")
assert(SW.Docked() and SW.Place() == "mail", "docks at the mailbox")
assert(SW.DockedFrame() == frame and heard == 1, "watchers hear it dock, past a broken one")
-- 8. A letter opens beside the mailbox: the window steps past it, and back.
OpenMailFrame.shown = true
OpenMailFrame:Fire("OnShow")
assert(frame.point and frame.point[4] == 860 + SW.DOCK_GAP and frame.point[5] == 690, "beside the open letter")
assert(heard == 2, "watchers hear it move")
OpenMailFrame:Hide()
OpenMailFrame:Fire("OnHide")
assert(frame.point and frame.point[4] == 500 + SW.DOCK_GAP and frame.point[5] == 700, "back beside the mailbox")
SW.Arrived("mail")
assert(#OpenMailFrame.hooks.OnShow == 1, "the letter is watched once")
assert(frame:GetWidth() == width - SW.RAIL_WIDTH - 8 and frame:GetHeight() == height + SW.ROW_HEIGHT + 8,
    "narrower by the rail, taller by the row")
assert(frame.point and frame.point[4] == 500 + SW.DOCK_GAP and frame.point[5] == 700, "beside the game's window")
assert(frame.rail.buttons[1].name.shown == false, "the row shows emblems only")
SW.Open("alpha")
assert(SW.Docked() and BlackthornesWindow.current == a, "an addon can take it over while docked")
frame.left = 1
frame.scripts.OnDragStop(frame)
assert(dbA.oneWindowLeft == 100, "moving it while docked keeps its own place")
heard = 0
SW.Left("mail")
assert(not SW.Docked() and frame:GetWidth() == width and frame:GetHeight() == height, "back to its own size")
assert(heard == 1 and SW.DockedFrame() == nil, "watchers hear it undock")
OpenMailFrame.shown = true
OpenMailFrame:Fire("OnShow")
assert(not SW.Docked() and frame.point[4] == 100, "a letter after the mailbox closed moves nothing")
OpenMailFrame.shown = false
assert(frame.point and frame.point[4] == 100 and frame.point[5] == 600, "back to its own place")
assert(BlackthornesWindow.current == c and log[#log] == "enter gamma", "back on the addon open before")
assert(frame.rail.buttons[1].name.shown == true, "the rail again")

-- Closed, an addon opens it at the vendor and closes it as it leaves.
MerchantFrame = Object()
MerchantFrame.right, MerchantFrame.top = 400, 650
SW.Close()
SW.Arrived("vendor")
assert(not SW.Docked(), "nothing to dock while closed")
now = now + 5
SW.Open("alpha")
assert(SW.Docked(), "opened at the vendor, it docks")
SW.Close()
SW.Left("vendor")
assert(not SW.IsOpen() and not SW.Docked(), "closed before, it stays closed")

-- Up on gamma, the addon opens before the game's event is heard.
now = now + 5
SW.Open("gamma")
SW.Open("alpha")
SW.Arrived("vendor")
assert(SW.Docked(), "docks when the event comes after")
SW.Close()
SW.Left("vendor")
assert(SW.IsOpen() and BlackthornesWindow.current == c and not SW.Docked(), "reopens on the addon open before")

-- At the auction house too.
AuctionFrame = Object()
AuctionFrame.right, AuctionFrame.top = 840, 720
now = now + 5
SW.Arrived("auction")
assert(SW.Docked() and SW.Place() == "auction", "docks at the auction house")
assert(frame.point and frame.point[4] == 840 + SW.DOCK_GAP and frame.point[5] == 720, "beside the auction house")
assert(SW.RowShown() and frame.rail.shown ~= false, "another addon keeps its row there")
SW.Left("auction")
assert(not SW.Docked() and SW.IsOpen() and BlackthornesWindow.current == c, "back on its own after the auction house")

-- 7. Tradeskills alone at the auction house.
local dbT = {}
local t = Entry("tradeskills", 5, dbT, true)
SW:Join(t)
now = now + 5
width, height = frame:GetWidth(), frame:GetHeight()
SW.Arrived("auction")
SW.Open("tradeskills")
assert(SW.Docked() and BlackthornesWindow.current == t, "Tradeskills shows at the auction house")
assert(not SW.RowShown() and frame.rail.shown == false, "no row of addon buttons there")
assert(frame:GetWidth() == width - SW.RAIL_WIDTH - 8 and frame:GetHeight() == height,
    "narrower by the rail, no taller")
SW.Pick("alpha")
assert(SW.RowShown() and frame.rail.shown == true and frame:GetHeight() == height + SW.ROW_HEIGHT + 8,
    "another addon picked there brings the row back")
SW.Pick("tradeskills")
assert(frame.rail.shown == false and frame:GetHeight() == height, "and Tradeskills leaves it out again")
SW.Left("auction")
assert(not SW.Docked() and frame:GetWidth() == width and frame:GetHeight() == height
    and frame.rail.shown == true, "back to its own size, rail and all")
assert(BlackthornesWindow.current == c, "back on the addon open before")

-- Opened by Tradeskills as the auction house opens, with the event first.
SW.Close()
now = now + 5
SW.Arrived("auction")
SW.Open("tradeskills")
assert(SW.Docked() and frame.rail.shown == false and frame:GetHeight() == height, "no row when opened there")
SW.Close()
SW.Left("auction")
assert(not SW.Docked() and frame:GetHeight() == height and frame.rail.shown == true, "its own size again")
SW.Open("gamma")

-- 9. Kept beside the auction house. The game shows its window late.
AuctionFrame.shown = false
now = now + 5
SW.Arrived("auction")
SW.Open("tradeskills")
assert(not SW.Docked(), "nothing to sit beside yet")
assert(frame.watch and frame.watch.scripts.OnUpdate, "a watcher looks while shown")
AuctionFrame.shown = true
frame.watch.wait = 0
frame.watch.scripts.OnUpdate(frame.watch, 0.05)
assert(SW.Docked() and frame.point[4] == 840 + SW.DOCK_GAP, "docks once the game's window shows")
heard = 0
assert(SW.Keep() == false and heard == 0, "nothing moved, nothing placed")
frame.point = { "TOPLEFT", UIParent, "BOTTOMLEFT", 300, 720 }
assert(SW.Keep() == false and frame.point[4] == 300, "dragged by hand, it stays")
AuctionFrame.right = 860
assert(SW.Keep() and frame.point[4] == 860 + SW.DOCK_GAP and heard == 1, "the game's window moved: beside it again")
frame.point = { "TOPLEFT", UIParent, "BOTTOMLEFT", 300, 720 }
frame:SetWidth(frame:GetWidth() - 200)
assert(SW.Keep() and frame.point[4] == 860 + SW.DOCK_GAP, "narrower: placed beside it again")
AuctionFrame.right = 840
SW.Close()
SW.Left("auction")
assert(not SW.Docked() and SW.Keep() == false, "nothing to keep once it closes")
SW.Open("gamma")

SW.SetOn(false)
assert(not SW.IsOpen(), "unticking closes it")
assert(not SW.Hosts("gamma"), "nothing is hosted while off")

for _, name in ipairs(NAMES) do _G[name] = saved[name] end
print("test_sharedwindow: ok")
