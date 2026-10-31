-- The mail panel beside the one window (2026-10-30): while the one window
-- sits docked at the mailbox, the queue's mail panel goes to its right, so
-- the two never cover each other; undocked it goes back beside the mailbox.

local ns = { L = setmetatable({ Format = string.format }, { __index = function(_, key) return key end }) }
ns.RegisterEvent = function() end
ns.Theme, ns.Widgets, ns.Util = {}, {}, {}

local function Frame(shown)
  return { shown = shown, IsShown = function(self) return self.shown end }
end

local docked = Frame(true)
local place, dockedFrame = nil, nil
local watchers = {}
ns.SharedWindow = {
  Place = function() return place end,
  DockedFrame = function() return dockedFrame end,
  Watch = function(fn) watchers[#watchers + 1] = fn end,
}

local oldMail, oldOpen = _G.MailFrame, _G.OpenMailFrame
_G.MailFrame = Frame(true)
_G.OpenMailFrame = Frame(false)

assert(loadfile(lfs_cwd .. "/UI/QueueMailPanel.lua"))("Blackthornes_TS", ns)
local Panel = ns.QueueMailPanel

local panel = {}
function panel:ClearAllPoints() self.point = nil end
function panel:SetPoint(_, anchor, rel, x, y) self.point = { anchor = anchor, rel = rel, x = x, y = y } end
Panel.frame = panel

-- Not docked: beside the mailbox.
Panel:Place()
assert(panel.point.anchor == _G.MailFrame, "beside the mailbox while nothing is docked")
assert(#watchers == 1, "listens to the one window once")

-- Docked at the mailbox: beside the one window, once a watcher says so.
place, dockedFrame = "mail", docked
watchers[1]()
assert(panel.point.anchor == docked, "beside the docked one window")
assert(panel.point.rel == "TOPRIGHT", "to its right")

-- Placed again on its own timer: still beside it, and still one listener.
Panel:Place()
assert(panel.point.anchor == docked, "stays beside the docked window")
assert(#watchers == 1, "still one listener")

-- Docked somewhere else: not followed.
place = "vendor"
watchers[1]()
assert(panel.point.anchor == _G.MailFrame, "a window docked at a vendor is not followed")

-- Undocked: back beside the open letter when one is open.
place, dockedFrame = nil, nil
_G.OpenMailFrame.shown = true
watchers[1]()
assert(panel.point.anchor == _G.OpenMailFrame, "back beside the open letter")

-- Without the one window at all, the old place still works.
ns.SharedWindow = nil
Panel.anchoredTo = nil
_G.OpenMailFrame.shown = false
Panel:Place()
assert(panel.point.anchor == _G.MailFrame, "without the one window, beside the mailbox")

_G.MailFrame, _G.OpenMailFrame = oldMail, oldOpen
print("test_queuemaildock: ok")
