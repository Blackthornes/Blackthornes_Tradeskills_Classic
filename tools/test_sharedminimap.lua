-- The shared minimap button (UI/SharedMinimap.lua), outside WoW. The same
-- test in all five Blackthornes addons.
--
-- What must hold:
--   1. One addon alone keeps its own button and no shared one shows.
--   2. Two addons, nothing saved: combined, own buttons hidden, the shared
--      button shown (on by default).
--   3. Unticking writes "each" in every save and gives the buttons back.
--   4. The newest save's answer wins.
--   5. A row's left-click opens, right-click opens settings, middle and
--      shift go to their own jobs, and fall back to open when not given.
--   6. The menu lays out a row for each addon.

local NAMES = { "CreateFrame", "UIParent", "Minimap", "GameTooltip", "C_Timer", "time",
    "BlackthornesMinimap", "UISpecialFrames", "IsShiftKeyDown", "GetCursorPosition" }
local saved = {}
for _, name in ipairs(NAMES) do saved[name] = _G[name] end

-- A frame that answers any call; the few that matter are real.
local function Object()
    local o = { shown = true, scripts = {}, text = nil }
    function o:Show() self.shown = true end
    function o:Hide() self.shown = false end
    function o:IsShown() return self.shown end
    function o:SetScript(name, fn) self.scripts[name] = fn end
    function o:SetText(text) self.text = text end
    function o:GetWidth() return 140 end
    function o:GetHeight() return 600 end
    function o:GetCenter() return 100, 100 end
    function o:GetEffectiveScale() return 1 end
    function o:GetStringHeight() return 14 end
    function o:IsMouseOver() return false end
    function o:CreateTexture() return Object() end
    function o:CreateFontString() return Object() end
    return setmetatable(o, { __index = function() return function() end end })
end

CreateFrame = function() return Object() end
UIParent = Object()
Minimap = Object()
GameTooltip = Object()
C_Timer = nil
UISpecialFrames = {}
local clock = 1000
time = function() return clock end
BlackthornesMinimap = nil

local ns = {
    Theme = {
        Unpack = function() return 0, 0, 0, 1 end,
        Fill = function() end,
        Border = function() end,
        CreateLabel = function() return Object() end,
    },
}
local chunk = assert(loadfile(lfs_cwd .. "/UI/SharedMinimap.lua"))
chunk("Blackthornes_Test", ns)
local SM = ns.SharedMinimap
assert(SM, "SharedMinimap loads")

local function Entry(key, order, db)
    local calls = {}
    local entry = {
        key = key, order = order, name = "Blackthornes " .. key, icon = "icon", blurb = "blurb",
        button = Object(), db = function() return db end, calls = calls,
        angle = function() return 1 end,
        open = function() calls[#calls + 1] = "open" end,
        settings = function() calls[#calls + 1] = "settings" end,
    }
    return entry
end

-- 1. One addon alone.
local dbA, dbB = {}, {}
local a = Entry("alpha", 1, dbA)
SM:Join(a)
assert(a.button:IsShown(), "one addon keeps its own button")
assert(not SM.Hides("alpha"), "one addon is never hidden")
assert(not BlackthornesMinimap.button or not BlackthornesMinimap.button:IsShown(), "no shared button for one")

-- 2. Two addons, on by default.
local b = Entry("beta", 2, dbB)
b.middle = function() b.calls[#b.calls + 1] = "middle" end
b.shift = function() b.calls[#b.calls + 1] = "shift" end
SM:Join(b)
assert(SM.Combined(), "combined unless unticked")
assert(SM.Hides("alpha") and SM.Hides("beta"), "both hide")
assert(not a.button:IsShown() and not b.button:IsShown(), "own buttons hidden")
assert(BlackthornesMinimap.button and BlackthornesMinimap.button:IsShown(), "shared button shows")

-- 3. Unticking.
SM.SetCombined(false)
assert(dbA.minimapButton == "each" and dbB.minimapButton == "each", "every save says each")
assert(dbA.minimapButtonAt == clock, "the time is kept")
assert(a.button:IsShown() and b.button:IsShown(), "own buttons back")
assert(not BlackthornesMinimap.button:IsShown(), "shared button hidden")

-- 4. The newest answer wins.
dbA.minimapButton, dbA.minimapButtonAt = "shared", clock + 10
assert(SM.Combined(), "the newer shared wins")
dbB.minimapButton, dbB.minimapButtonAt = "each", clock + 20
assert(not SM.Combined(), "the newer each wins")
SM.SetCombined(true)
assert(SM.Combined() and not a.button:IsShown(), "ticked again")

-- 5. Clicks on a row.
SM.Run(b, "LeftButton", false)
SM.Run(b, "RightButton", false)
SM.Run(b, "MiddleButton", false)
SM.Run(b, "LeftButton", true)
assert(table.concat(b.calls, ",") == "open,settings,middle,shift", "row clicks: " .. table.concat(b.calls, ","))
SM.Run(a, "MiddleButton", false)
SM.Run(a, "LeftButton", true)
assert(table.concat(a.calls, ",") == "open,open", "no middle or shift job opens it")

-- 6. The menu.
SM.ToggleMenu()
local menu = BlackthornesMinimap.menu
assert(menu and menu:IsShown(), "menu opens")
assert(menu.rows[1].entry == a and menu.rows[2].entry == b, "rows in order")
SM.ToggleMenu()
assert(not menu:IsShown(), "a second click closes it")

for _, name in ipairs(NAMES) do _G[name] = saved[name] end
print("test_sharedminimap: ok")
