-- The craft pane beside Era's Enchanting window (UI/CraftPanel.lua).
--
-- Era's Enchanting has a window of its own, CraftFrame, opened by
-- CRAFT_SHOW. The pane used to hear only TRADE_SKILL_SHOW, so an enchanter
-- never saw it. It docks to the window opened last, moves to the other one
-- when that closes, and goes when both are shut.

local passed, failed = 0, 0
local function check(label, got, want)
  local ok = got == want
  if ok then passed = passed + 1 else failed = failed + 1 end
  print(string.format("  %-56s %-16s %s", label, tostring(got), ok and "ok" or
    ("WRONG, wanted " .. tostring(want))))
end

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.Theme, ns.Util = {}, {}
ns.Config = { Get = function() return nil end, Set = function() end }
ns.RegisterCommand = function() end
local handlers = {}
ns.RegisterEvent = function(owner, event, fn)
  handlers[event] = handlers[event] or {}
  table.insert(handlers[event], function(...) fn(owner, event, ...) end)
end
local function Fire(event, ...)
  for _, fn in ipairs(handlers[event] or {}) do fn(...) end
end
C_Timer = { After = function() end }

local era = true
ns.Crafting = { isTradeSkillOpen = true, EraWindows = function() return era and {} or nil end }

local function GameFrame()
  return { GetObjectType = function() return "Frame" end }
end
TradeSkillFrame, CraftFrame = GameFrame(), GameFrame()

local CraftPanel
do
  local realNew = ns.NewModule
  ns.NewModule = function(name) local m = realNew(name); CraftPanel = m; return m end
  assert(loadfile(lfs_cwd .. "/UI/CraftPanel.lua"))("Blackthornes_TS", ns)
  ns.NewModule = realNew
end

-- Where the pane is, without building it.
local shown, dockedTo = false, nil
CraftPanel.Attach = function(self)
  shown = true
  dockedTo = select(2, self:FindTradeSkillFrame())
end
CraftPanel.Hide = function() shown, dockedTo = false, nil end

CraftPanel:OnEnable()
print("")

check("nothing open: no window to dock to", CraftPanel:FindTradeSkillFrame(), nil)

Fire("CRAFT_SHOW")
check("Enchanting opens: the pane shows", shown, true)
check("Enchanting opens: docked to it", dockedTo, "CraftFrame")

Fire("TRADE_SKILL_SHOW")
check("Tailoring opens too: docked to the newer one", dockedTo, "TradeSkillFrame")

Fire("TRADE_SKILL_CLOSE")
check("Tailoring closes: still shown", shown, true)
check("Tailoring closes: back beside Enchanting", dockedTo, "CraftFrame")

Fire("CRAFT_CLOSE")
check("both closed: the pane goes", shown, false)

Fire("TRADE_SKILL_SHOW")
Fire("CRAFT_SHOW")
Fire("CRAFT_CLOSE")
check("Enchanting closes first: beside Tailoring", dockedTo, "TradeSkillFrame")
Fire("TRADE_SKILL_CLOSE")
check("then Tailoring closes: the pane goes", shown, false)

-- Off Era the old list stands: the first profession frame found.
era = false
check("off Era: the profession frame", select(2, CraftPanel:FindTradeSkillFrame()), "TradeSkillFrame")

print(("\nenchant pane: %d checks passed, %d wrong"):format(passed, failed))
if failed > 0 then error(("enchant pane: %d check(s) wrong"):format(failed)) end
