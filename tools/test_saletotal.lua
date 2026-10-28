-- Sale Total on top of the auction house drawer (2026-10-28).
--
-- What must hold:
--   1. Off unless ticked: nothing is drawn.
--   2. It counts what the Sell list's title counts: shown lines, not held.
--   3. After a scan it counts up from nothing to the total, an item at a
--      time, then says how far it moved and cheers once.
--   4. Effects Off shows the number at once.
--   5. Leaving the auction house mid-count lands it on the total.
--   6. With nothing moving, no OnUpdate runs.

local saved = {}
for _, key in ipairs({ "CreateFrame", "C_Timer", "PlaySound", "SOUNDKIT" }) do saved[key] = _G[key] end

local function Region()
    local r = { shown = true, alpha = 1, text = "" }
    local function noop() end
    for _, m in ipairs({ "SetPoint", "ClearAllPoints", "SetSize", "SetHeight", "SetWidth", "EnableMouse",
        "SetTexture", "SetBlendMode", "SetTextColor", "SetScale", "SetColorTexture", "SetJustifyH" }) do r[m] = noop end
    function r:Show() self.shown = true end
    function r:Hide() self.shown = false; if self.scripts and self.scripts.OnHide then self.scripts.OnHide(self) end end
    function r:SetShown(v) if v then self:Show() else self:Hide() end end
    function r:IsShown() return self.shown end
    function r:SetAlpha(a) self.alpha = a end
    function r:SetText(t) self.text = t end
    function r:GetWidth() return 344 end
    function r:SetProgress(p) self.progress = p end
    function r:CreateTexture() return Region() end
    r.scripts = {}
    function r:SetScript(which, fn) self.scripts[which] = fn end
    return r
end
CreateFrame = function() return Region() end
C_Timer = { After = function() end }
local sounds = 0
PlaySound = function() sounds = sounds + 1 end
SOUNDKIT = { LOOT_WINDOW_COIN_SOUND = 120 }

local settings = { saleTotal = true }
local level = "full"
local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.Config = { Get = function(_, k) return settings[k] end, Set = function(_, k, v) settings[k] = v end }
ns.Motion = { Level = function() return level end }
ns.Util = {
    Comma = function(n) return tostring(n) end,
    FormatMoney = function(c) return tostring(c) .. "c" end,
}
ns.Theme = {
    Fill = function() end, TopSheen = function() end, Border = function() end, Halo = function() end,
    SetHalo = function() end, SetGradientAlpha = function() end,
    Unpack = function() return 1, 1, 1, 1 end,
    CreateLabel = function() return Region() end,
}
ns.Widgets = { CreateProgressBar = function() return Region() end }
ns.PostPanel = { frame = Region(), IsShown = function() return true end, Refresh = function() end }

assert(loadfile(lfs_cwd .. "/UI/SaleTotal.lua"))("Blackthornes_TS", ns)
local S = ns.SaleTotal

local lines = {
    { postTotal = 32000 },
    { postTotal = 18400 },
    { postTotal = 999999, held = true },
    { postTotal = 6400000 },
}

-- 2. Shown lines not held back.
local worths, total = S.Worths(lines)
assert(#worths == 3 and total == 32000 + 18400 + 6400000, "held lines are left out")
assert(S.IsBig(6400000, total) and not S.IsBig(18400, total), "only a big share shines")
assert(S.StepFor(3) <= S.STEP_MOST and S.StepFor(1000) * 1000 <= S.PLAY + 1e-9, "the count never runs long")
assert(S.ChangeText(nil, 5) == nil and S.ChangeText(5, 5) == nil, "no change line without a last total")
assert(S.ChangeText(100, 300):find("Up", 1, true), "up says up")
assert(S.ChangeText(300, 100):find("Down", 1, true), "down says down")
assert(S.Money(14725099):find("1472", 1, true), "gold shows")

-- 1. Off draws nothing.
settings.saleTotal = false
S:Update(lines)
assert(S.frame == nil, "off builds nothing")
settings.saleTotal = true

-- First look: the total at once, nothing moving.
S:Update(lines)
assert(S.frame and S.frame:IsShown(), "on shows the plaque")
assert(S.shown == total and S.frame.scripts.OnUpdate == nil, "first look shows the total, still")

-- 3. A scan: counts up from nothing, then cheers once.
lines[1].postTotal = 52000
local after = select(2, S.Worths(lines))
S:ScanFinished()
S:Update(lines)
assert(S.play and S.shown == 0, "the count starts from nothing")
local onUpdate = S.frame.scripts.OnUpdate
assert(onUpdate, "it moves while counting")
for _ = 1, 400 do
    if not S.frame.scripts.OnUpdate then break end
    S.frame.scripts.OnUpdate(S.frame, 0.05)
end
assert(S.play == nil and S.shown == after, "the count lands on the total")
assert(S.cheer and S.change and S.change:find("Up", 1, true), "it cheers and says how far it moved")
assert(sounds == 1, "one coin sound")
assert(S.frame.scripts.OnUpdate == nil, "6: nothing runs once still")

-- 4. Effects Off: at once.
level = "off"
S:ScanFinished()
S:Update(lines)
assert(S.play == nil and S.shown == after, "off lands at once")
level = "full"

-- 5. Leaving mid-count lands it.
S:ScanFinished()
S:Update(lines)
S.frame.scripts.OnUpdate(S.frame, 0.05)
S.frame:Hide()
assert(S.play == nil and S.shown == after and S.cheer == nil, "leaving lands the total quietly")

-- 6. On for new saves (the owner, 2026-10-28); a value already saved is kept.
local file = io.open("Core/Config.lua") or io.open("../Core/Config.lua")
local config = assert(file, "Core/Config.lua"):read("*a")
file:close()
assert(config:find("saleTotal = true,", 1, true), "on unless unticked")

for key, value in pairs(saved) do _G[key] = value end
print("test_saletotal: ok")
