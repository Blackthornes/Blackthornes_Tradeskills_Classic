-- "Open at AH:" and "Open at Professions:" (a player's request, 2026-11-05),
-- outside WoW. Ticked (the default), Tradeskills comes up by itself at the
-- auction house and the craft pane beside a profession window, as before.
-- Unticked, nothing comes up until the player opens it on that visit.

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

local later = {}
C_Timer = {
    After = function(_, fn) later[#later + 1] = fn end,
    NewTicker = function() return { Cancel = noop } end,
}
local function RunLater()
    local due = later
    later = {}
    for _, fn in ipairs(due) do fn() end
end

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = noop
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = noop, noop, noop, noop

local handlers = {}
ns.RegisterEvent = function(owner, event, fn)
    handlers[event] = handlers[event] or {}
    handlers[event][#handlers[event] + 1] = { owner = owner, fn = fn }
    return true
end
local function Fire(event, ...)
    for _, entry in ipairs(handlers[event] or {}) do entry.fn(entry.owner, event, ...) end
end

local settings = {}
ns.Config = {
    Get = function(_, key) return settings[key] end,
    Set = function(_, key, value) settings[key] = value end,
}
ns.db = {}
ns.Scanner = { isAuctionHouseOpen = false }
ns.Theme, ns.Widgets = {}, {}
ns.PostPanel = { Refresh = noop, Place = noop, Hide = noop }
ns.Crafting = {}

assert(loadfile(lfs_cwd .. "/Core/Util.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/UI/Main.lua"))("Blackthornes_TS", ns)

local UI = ns.UI
local attached = 0
local realAttach = UI.AttachToAuctionHouse
for _, name in ipairs({ "Build", "BuildMinimapButton", "HookAltClickSearch", "UpdateHeader",
    "OpenWithShop", "CloseWithShop", "RestorePosition", "UpdateWaitLabels",
    "RefreshActiveTab", "RepositionMinimapButton", "UpdatePostButton" }) do
    UI[name] = noop
end
-- Only the gate at the top of the real one is under test.
UI.FindAuctionFrame = function() attached = attached + 1; error("stop") end
UI.AttachToAuctionHouse = function(self) pcall(realAttach, self) end

UI:OnEnable()

local passed, failed = 0, 0
local function check(label, got, want)
    local ok = got == want
    if ok then passed = passed + 1 else failed = failed + 1 end
    print(string.format("  %-58s %-6s %s", label, tostring(got), ok and "ok" or
        ("WRONG, wanted " .. tostring(want))))
end

local function Visit()
    ns.Scanner.isAuctionHouseOpen = true
    Fire("AUCTION_HOUSE_SHOW")
    RunLater()
end

print("")
print("at the auction house")

Visit()
check("never set: it comes up by itself", attached > 0, true)

settings.openAtAuction = false
attached = 0
Visit()
check("unticked: nothing comes up", attached, 0)
UI:AskedAtAuction()
RunLater()
check("the player opens it: it comes up then", attached > 0, true)
attached = 0
UI:AskedAtAuction()
RunLater()
check("and only once a visit", attached, 0)
attached = 0
Visit()
check("the next visit waits again", attached, 0)

settings.openAtAuction = true
attached = 0
Visit()
check("ticked again: it comes up by itself", attached > 0, true)

print("")
print("beside a profession window")

assert(loadfile(lfs_cwd .. "/UI/CraftPanel.lua"))("Blackthornes_TS", ns)
local CraftPanel = ns.CraftPanel
local panes = 0
CraftPanel.Attach = function() panes = panes + 1 end
CraftPanel:OnEnable()

Fire("TRADE_SKILL_SHOW")
check("never set: the craft pane opens", panes, 1)
settings.openAtProfessions = false
Fire("TRADE_SKILL_SHOW")
check("unticked: it stays shut", panes, 1)
settings.openAtProfessions = true
Fire("TRADE_SKILL_SHOW")
check("ticked again: it opens", panes, 2)

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print("")
if failed > 0 then
    error(string.format("%d check(s) failed", failed))
end
print("all checks passed")
