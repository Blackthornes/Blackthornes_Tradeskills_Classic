-- The mouse wheel at the auction house (2026-10-16).
--
-- What must hold:
--   1. Off unless ticked: nothing is bound, whatever the drawer does.
--   2. Ticked, the wheel is bound only while the drawer shows, and given
--      back when it goes.
--   3. Wheel up lists the next stack, wheel down cancels the next undercut.
--   4. A flick (notches close together) does one thing, not several.
--   5. In a fight the bindings wait for the fight to end.
--   6. A press and its release do one thing.
--   7. Era: while the last listing goes in, notches do nothing, and the
--      first notch once it is ready lists.

local GLOBALS = { "CreateFrame", "UIParent", "GetTime", "InCombatLockdown",
    "SetOverrideBindingClick", "ClearOverrideBindings" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local function noop() end

local named = {}
local function Frame(name)
    local frame = { scripts = {}, hooks = {} }
    function frame:SetScript(which, fn) self.scripts[which] = fn end
    function frame:HookScript(which, fn) self.hooks[which] = fn end
    for _, method in ipairs({ "SetSize", "SetAlpha", "EnableMouse", "RegisterForClicks" }) do
        frame[method] = noop
    end
    if name then named[name] = frame end
    return frame
end
CreateFrame = function(_, name) return Frame(name) end
UIParent = {}

local clock = 100
GetTime = function() return clock end
local fighting = false
InCombatLockdown = function() return fighting end

local bindings = {}
SetOverrideBindingClick = function(_, _, key, button) bindings[key] = button end
ClearOverrideBindings = function() bindings = {} end

local handlers = {}
local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterEvent = function(_, event, fn) handlers[event] = fn; return true end

local settings = {}
ns.Config = { Get = function(_, k) return settings[k] end, Set = function(_, k, v) settings[k] = v end }

local shown = false
local listed, cancelled = 0, 0
ns.PostPanel = {
    view = "sell",
    IsShown = function() return shown end,
    ListNext = function() listed = listed + 1 end,
}
ns.MyAuctions = { CancelNext = function() cancelled = cancelled + 1 end }

assert(loadfile(lfs_cwd .. "/UI/AuctionWheel.lua"))("Blackthornes_TS", ns)
local Wheel = ns.AuctionWheel

local drawer = Frame()
local function Show() shown = true; drawer.hooks.OnShow() end
local function Hide() shown = false; drawer.hooks.OnHide() end
Wheel:Watch(drawer)

-- 1. Off unless ticked.
Show()
assert(next(bindings) == nil, "nothing is bound while the setting is off")
Hide()

-- 2. Ticked: bound only while the drawer shows.
settings.mouseWheelListing = true
Wheel:Update()
assert(next(bindings) == nil, "nothing is bound away from the auction house")
Show()
assert(bindings.MOUSEWHEELUP == Wheel.LIST_BUTTON, "wheel up is bound to the list button")
assert(bindings.MOUSEWHEELDOWN == Wheel.CANCEL_BUTTON, "wheel down is bound to the cancel button")

-- 3. Each direction does its job, through the named buttons a binding clicks.
named[Wheel.LIST_BUTTON].scripts.OnClick(nil, "LeftButton", true)
assert(listed == 1, "wheel up lists the next stack")
clock = clock + 1
named[Wheel.CANCEL_BUTTON].scripts.OnClick(nil, "LeftButton", true)
assert(cancelled == 1, "wheel down cancels the next undercut")

-- 6. The release of the same press does nothing more.
clock = clock + 1
named[Wheel.LIST_BUTTON].scripts.OnClick(nil, "LeftButton", true)
named[Wheel.LIST_BUTTON].scripts.OnClick(nil, "LeftButton", false)
assert(listed == 2, "a press and its release list once")

-- 4. A flick: notches close together do one thing.
clock = clock + 1
for _ = 1, 5 do
    named[Wheel.LIST_BUTTON].scripts.OnClick(nil, "LeftButton", true)
    clock = clock + 0.05
end
assert(listed == 3, "a flick lists one stack, got " .. listed)

-- 7. Notches while the last listing goes in do nothing; the first once it
-- is ready lists, with no wait of its own after the ones held back.
local settling = true
ns.Posting = { Settling = function() return settling end }
clock = clock + 1
for _ = 1, 5 do
    named[Wheel.LIST_BUTTON].scripts.OnClick(nil, "LeftButton", true)
    clock = clock + 0.1
end
assert(listed == 3, "nothing lists while the last listing goes in")
settling = false
named[Wheel.LIST_BUTTON].scripts.OnClick(nil, "LeftButton", true)
assert(listed == 4, "the first notch once ready lists")
ns.Posting = nil
listed = 3

-- On another view, Sell's lines are read fresh.
clock = clock + 1
ns.PostPanel.view = "auctions"
ns.PostPanel.shownLines = { "old" }
named[Wheel.LIST_BUTTON].scripts.OnClick(nil, "LeftButton", true)
assert(ns.PostPanel.shownLines == nil and listed == 4, "another view reads Sell's lines fresh")

-- 2. The drawer goes: the wheel is given back, and a stray click does nothing.
Hide()
assert(next(bindings) == nil, "the wheel is given back when the drawer goes")
clock = clock + 1
assert(Wheel:List() == false and listed == 4, "nothing lists away from the auction house")

-- Unticked while open: given back at once.
Show()
assert(bindings.MOUSEWHEELUP, "bound again on the next visit")
settings.mouseWheelListing = false
Wheel:Update()
assert(next(bindings) == nil, "unticking gives the wheel back")
settings.mouseWheelListing = true
Hide()

-- 5. In a fight the change waits for the fight to end.
fighting = true
Show()
assert(next(bindings) == nil, "bindings wait out a fight")
fighting = false
handlers.PLAYER_REGEN_ENABLED()
assert(bindings.MOUSEWHEELUP, "bound once the fight ends")
Hide()

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end
print("test_auctionwheel: all passed")
