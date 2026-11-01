-- The Queue tab's "Open <profession>" button, measured without a game client.
--
-- What matters here: the right spell is cast for the right recipe (Mining is
-- opened by Smelting, gathering skills have nothing to open), the secure
-- button is never touched in combat, and a click is only ever reported as a
-- success once a window has really opened.

local ns = {}
local printed, warned = {}, {}
local events = {}

ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.Print = function(msg) printed[#printed + 1] = msg end
ns.Warn = function(msg) warned[#warned + 1] = msg end
ns.RegisterEvent = function(_, event, fn) events[event] = fn end
ns.RegisterCommand = function(name, _, fn) ns["cmd_" .. name] = fn end

local RECIPES = {
  [1] = { recipeID = 1, name = "Bolt of Linen Cloth", skillLineID = 2948 },
  [2] = { recipeID = 2, name = "Smelt Copper",        skillLineID = 186 },
  [3] = { recipeID = 3, name = "Mystery",             skillLineID = 99999 },
  [4] = { recipeID = 4, name = "Skinning thing",      skillLineID = 393 },
  [5] = { recipeID = 5, name = "No line" },
  [6] = { recipeID = 6, name = "Classic sub-line",    skillLineID = 2827 },
}
ns.Recipes = { GetAny = function(_, id) return RECIPES[id] end }
ns.Crafting = { isTradeSkillOpen = false }

local openSet = nil
ns.CraftPanel = { GetOpenRecipeIDs = function() return openSet end }

-- The client
local inCombat = false
function InCombatLockdown() return inCombat end
-- The game's own setting was on in the first in-game test; the secure
-- button must still listen for the release.
function GetCVarBool() return true end
function GetTime() return 100 end

local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }

C_TradeSkillUI = {
  GetProfessionInfoBySkillLineID = function(id)
    if id == 2948 then return { professionName = "Tailoring" } end
    if id == 2827 then return { professionName = "Classic Tailoring", parentProfessionName = "Tailoring" } end
    return nil
  end,
}
C_Spell = { GetSpellName = function(id) if id == 2656 then return "Smelting" end end }

local function NewFrame()
  local f = { shown = false, attrs = {}, scripts = {}, hooks = {} }
  function f:Show() if inCombat then error("protected: Show in combat") end; self.shown = true end
  function f:Hide() if inCombat then error("protected: Hide in combat") end; self.shown = false end
  function f:IsShown() return self.shown end
  function f:IsVisible() return self.shown end
  function f:SetAttribute(k, v) if inCombat then error("protected") end; self.attrs[k] = v end
  function f:GetAttribute(k) return self.attrs[k] end
  function f:SetScript(k, fn) self.scripts[k] = fn end
  function f:GetScript(k) return self.scripts[k] end
  function f:HookScript(k, fn) self.hooks[k] = fn end
  function f:RegisterForClicks(d) self.clicks = d end
  f.strata, f.level = "MEDIUM", 3
  f.mouse = true
  function f:EnableMouse(v) self.mouse = v end
  function f:CreateTexture() return { SetAllPoints = function() end, SetColorTexture = function() end, SetPoint = function() end, SetSize = function() end } end
  function f:SetFrameStrata(v) self.strata = v end
  function f:GetFrameStrata() return self.strata end
  function f:SetFrameLevel(v) self.level = v end
  function f:GetFrameLevel() return self.level end
  function f:ClearAllPoints() end
  function f:SetPoint(...) self.point = { ... } end
  function f:SetSize(w, h) self.w, self.h = w, h end
  function f:GetLeft() return 10 end
  function f:GetBottom() return 20 end
  function f:GetWidth() return 220 end
  function f:GetHeight() return 26 end
  function f:GetEffectiveScale() return 1 end
  function f:IsMouseOver() return false end
  function f:IsMouseEnabled() return self.mouse end
  return f
end

UIParent = NewFrame()
local created = {}
function CreateFrame(kind, name, parent, template)
  local f = NewFrame()
  f.kind, f.name, f.parent, f.template = kind, name, parent, template
  created[#created + 1] = f
  return f
end

ns.Theme = {
  Fill = function() return { SetColorTexture = function() end } end,
  Border = function() end,
  CreateLabel = function() return { SetPoint = function() end, SetWordWrap = function() end, SetText = function(self, t) self.text = t end } end,
  Unpack = function() return 0, 0, 0, 1 end,
}

local chunk = assert(loadfile(lfs_cwd .. "/UI/ProfessionOpener.lua"))
chunk("Blackthornes_TS", ns)
local Opener = ns.ProfessionOpener
Opener:OnEnable()

local function check(cond, msg) if not cond then error(msg, 2) end end

-- Which profession ------------------------------------------------------------

local p = Opener:ProfessionFor(1)
check(p and p.name == "Tailoring" and p.spell == "Tailoring", "tailoring recipe should cast Tailoring")

p = Opener:ProfessionFor(2)
check(p and p.name == "Mining" and p.spell == "Smelting", "mining recipe should cast Smelting, got " .. tostring(p and p.spell))

p = Opener:ProfessionFor(6)
check(p and p.name == "Tailoring", "a sub-line should use its parent profession's name")

check(Opener:ProfessionFor(3) == nil, "an unknown skill line has nothing to open")
check(Opener:ProfessionFor(4) == nil, "skinning has no window")
check(Opener:ProfessionFor(5) == nil, "no skill line, no guess")

-- Is the right window open ----------------------------------------------------

check(Opener:WindowShowsRecipe(1) == false, "closed window shows nothing")
ns.Crafting.isTradeSkillOpen = true
openSet = { [1] = true }
openSet = nil
check(Opener:WindowShowsRecipe(1) == true, "open window the client will not describe gets the benefit of the doubt")
openSet = { [2] = true }
check(Opener:WindowShowsRecipe(1) == false, "smelting window open does not make tailoring")
check(Opener:WindowShowsRecipe(2) == true, "smelting window makes smelting")
ns.Crafting.isTradeSkillOpen = false

-- Arming ----------------------------------------------------------------------

local craftButton = NewFrame()
craftButton.shown = true

check(Opener:Arm(craftButton, Opener:ProfessionFor(1), 1), "arm out of combat")
local overlay = Opener.overlay
check(overlay.template == "SecureActionButtonTemplate", "overlay must be a secure action button")
check(overlay.parent == UIParent, "overlay must not be parented to the addon window (it would protect it)")
check(overlay.attrs.type == "spell" and overlay.attrs.spell == "Tailoring", "overlay casts Tailoring")
check(craftButton.mouse == false, "the craft button under the Open button stops taking the mouse")
check(overlay.label.text == "Open Tailoring", "the visible Open button names the profession")
check(overlay.clicks == "AnyUp", "one click direction only, or the second cast closes the window")
check(overlay.attrs.useOnKeyDown == false, "a template that checks direction must act on the release")
check(overlay.shown, "overlay shows over a visible button")
check(overlay.point and overlay.point[4] == 10 and overlay.point[5] == 20, "overlay placed on the craft button")
check(Opener:IsArmed(), "IsArmed")

-- Our window is top-level: clicking it raises its level. The secure button
-- must follow, or it sits under the craft button and the click misses it
-- (the first in-game try did exactly this).
craftButton.strata, craftButton.level = "HIGH", 40
craftButton.hooks.OnUpdate(craftButton)
check(overlay.strata == "DIALOG" and overlay.level > 40,
  "overlay must stay above a raised craft button, got " .. overlay.strata .. " " .. overlay.level)

-- Moving to a mining recipe re-targets the same button.
Opener:Arm(craftButton, Opener:ProfessionFor(2), 2)
check(overlay.attrs.spell == "Smelting", "re-arm changes the spell")
check(#created == 1, "one secure button, reused")

-- Combat: nothing protected is touched, and the wish is remembered.
events.PLAYER_REGEN_DISABLED()
check(not overlay.shown, "hidden as combat starts")
check(craftButton.mouse == true, "the craft button takes clicks again in combat")
inCombat = true
check(Opener:Arm(craftButton, Opener:ProfessionFor(1), 1) == false, "arm refuses in combat")
check(Opener:Disarm() == false, "disarm refuses in combat")
check(overlay.attrs.spell == "Smelting", "spell untouched in combat")
craftButton.hooks.OnHide(craftButton) -- must not error in combat
inCombat = false

check(Opener:Disarm(), "disarm out of combat")
check(not overlay.shown and not Opener:IsArmed(), "disarmed overlay is hidden")
check(craftButton.mouse == true, "disarming gives the craft button its clicks back")

-- Reporting -------------------------------------------------------------------

Opener:Arm(craftButton, Opener:ProfessionFor(1), 1)
overlay.scripts.PreClick(overlay, "LeftButton", false)
check(#printed == 0 and #warned == 0, "a click alone reports nothing yet")
events.TRADE_SKILL_SHOW()
check(printed[1] and printed[1]:find("opened your Tailoring window"), "window opening is reported")
timers[#timers]()
check(#warned == 0, "the timeout after a success stays quiet")

overlay.scripts.PreClick(overlay, "LeftButton", false)
timers[#timers]()
check(warned[1] and warned[1]:find("no profession window opened"), "a click that opened nothing is reported as a miss")

-- The window opens but its event is not heard: the open window is what
-- counts, so this is a success, not a miss.
local p, wn = #printed, #warned
overlay.scripts.PreClick(overlay, "LeftButton", false)
ns.Crafting.isTradeSkillOpen = true
openSet = { [1] = true }
timers[#timers]()
check(#warned == wn, "an open window is not reported as a miss")
check(#printed == p + 1 and printed[#printed]:find("opened your Tailoring window"), "an open window is reported as opened")
ns.Crafting.isTradeSkillOpen = false

-- A click that reaches the craft button out of combat is a miss, not combat.
local w = #warned
Opener:MissedClick()
check(#warned == w + 1 and warned[#warned]:find("missed"), "a missed click out of combat says so")
inCombat = true
Opener:MissedClick()
check(printed[#printed]:find("combat"), "a missed click in combat names combat")
inCombat = false

-- A window opening with no click pending is not claimed as ours.
local before = #printed
events.TRADE_SKILL_SHOW()
check(#printed == before, "unrelated window opening is not reported")

-- A German client names Skinning "Kürschnerei": still no window, by its
-- skill line.
RECIPES[7] = { recipeID = 7, name = "Skinning thing", skillLineID = 2947 }
local englishInfo = C_TradeSkillUI.GetProfessionInfoBySkillLineID
C_TradeSkillUI.GetProfessionInfoBySkillLineID = function(id)
  if id == 2947 then return { professionName = "Kürschnerei" } end
  return englishInfo(id)
end
check(Opener:ProfessionFor(7) == nil, "a gathering skill in German has no window")
C_TradeSkillUI.GetProfessionInfoBySkillLineID = englishInfo

-- Era has no GetProfessionInfoBySkillLineID: the name and the spell come
-- from the client's own spell name, so a German client opens Schneiderei
-- (a player saw "Tailoring öffnen" do nothing, 2026-11-01).
RECIPES[8] = { recipeID = 8, name = "Linen cloak", skillLineID = 197 }
RECIPES[9] = { recipeID = 9, name = "Copper bar", skillLineID = 186 }
local savedTSUI, savedSpell = C_TradeSkillUI, C_Spell
C_TradeSkillUI = nil
C_Spell = { GetSpellName = function(id)
  if id == 3908 then return "Schneiderei" end
  if id == 2575 then return "Bergbau" end
  if id == 2656 then return "Verhüttung" end
end }
local de = Opener:ProfessionFor(8)
check(de and de.name == "Schneiderei" and de.spell == "Schneiderei",
  "German tailoring casts Schneiderei, got " .. tostring(de and de.spell))
de = Opener:ProfessionFor(9)
check(de and de.name == "Bergbau" and de.spell == "Verhüttung", "German mining casts Verhüttung")
C_Spell = { GetSpellName = function() return nil end }
local savedInfo = GetSpellInfo
GetSpellInfo = nil
de = Opener:ProfessionFor(8)
GetSpellInfo = savedInfo
check(de and de.spell == "Tailoring", "with no spell name the English one stands in")
C_TradeSkillUI, C_Spell = savedTSUI, savedSpell

-- Leaving a form first (the owner said yes, 2026-10-13) ---------------------

local class, form = "WARRIOR", 1
UnitClass = function() return "Bob", class end
GetShapeshiftForm = function() return form end
check(Opener:LeaveFormStep() == nil, "a warrior's stance is no form to leave")
class = "DRUID"
local leave = Opener:LeaveFormStep()
check(leave and leave.leaveForm, "a druid in a form leaves it first")
form = 0
check(Opener:LeaveFormStep() == nil, "out of form, nothing to leave")
form = 3

local formButton = NewFrame()
formButton.shown = true
check(Opener:Arm(formButton, leave, 1), "arm Leave form out of combat")
local secure = Opener.overlay
check(secure.attrs.type == "macro" and secure.attrs.macrotext == "/cancelform",
  "Leave form runs /cancelform, got " .. tostring(secure.attrs.type))
check(secure.attrs.spell == nil, "and casts nothing else in the same click")
check(secure.shown, "the secure button covers the craft button")

local refreshed = 0
ns.UI = { RefreshActiveTab = function() refreshed = refreshed + 1 end }
events.UPDATE_SHAPESHIFT_FORM()
form = 0
events.UPDATE_SHAPESHIFT_FORM()
check(refreshed == 2, "leaving the form redraws the button")
events.UPDATE_SHAPESHIFT_FORM()
check(refreshed == 2, "a form event with nothing changed redraws nothing")

check(Opener:Arm(formButton, Opener:ProfessionFor(1), 1), "the next click opens the profession")
check(secure.attrs.type == "spell" and secure.attrs.spell == "Tailoring" and secure.attrs.macrotext == nil,
  "set back to casting the profession")

form = 3
inCombat = true
local said = #printed
Opener:MissedClick()
check(#printed == said + 1 and printed[#printed]:find("combat"), "in combat, it says a form cannot be left from here")
inCombat = false
form, class = 0, "WARRIOR"
UnitClass, GetShapeshiftForm = nil, nil
check(Opener:InBlockingForm() == false, "a client without the calls is never in a form")
ns.UI = nil

print("profession opener: all checks passed")
