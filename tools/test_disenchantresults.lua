-- What gear can break into, on its tooltip, for an enchanter (a player
-- asked, 2026-10-29).
--
--   1. A character that knows Disenchant gets a line for each result, its
--      count and its chance, most likely first.
--   2. A character that doesn't, an item that can't be broken, or the row
--      picked Off, gets none.
--   3. On Shift (the usual pick) the lines wait for Shift and say so.

local failures = 0
local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(string.format("  FAIL  %-52s got %s, wanted %s", label, tostring(got), tostring(want)))
  else
    print(string.format("  ok    %-52s %s", label, tostring(got)))
  end
end

local saved = { IsShiftKeyDown = IsShiftKeyDown }

local ns = {}
ns.NewModule = function(name) local m = {} ns[name] = m return m end

local settings = {}
ns.Config = { Get = function(_, key) return settings[key] end }
ns.Util = {
  Round = function(v, d)
    local m = 10 ^ (d or 0)
    return math.floor(v * m + 0.5) / m
  end,
  ColorItemName = function(_, name) return name end,
  GetItemLabel = function(id) return "item" .. id end,
}

local knows = true
ns.Disenchanter = { Knows = function() return knows end }

local NAMES = { [10940] = "Strange Dust", [10939] = "Greater Magic Essence", [10978] = "Small Glimmering Shard" }
ns.Disenchant = {
  MaterialName = function(_, id) return NAMES[id] end,
  GetOutcomes = function(_, id)
    if id ~= 1 then return nil end
    return {
      { itemID = 10940, chance = 0.75, min = 2, max = 3 },
      { itemID = 10939, chance = 0.20, min = 1, max = 2 },
      { itemID = 10978, chance = 0.05, min = 1, max = 1 },
    }
  end,
}

local shift = false
IsShiftKeyDown = function() return shift end

local ItemTooltip
do
  local realNew = ns.NewModule
  ns.NewModule = function(name) local m = realNew(name); ItemTooltip = m; return m end
  assert(loadfile(lfs_cwd .. "/UI/ItemTooltip.lua"))("Blackthornes_TS", ns)
  ns.NewModule = realNew
end

local function Lines(id)
  local lines = {}
  ItemTooltip:AddDisenchantResults(lines, id)
  return lines
end

--------------------------------------------------------------------------------
print("\nan enchanter")
--------------------------------------------------------------------------------

local lines = Lines(1)
check("a line for each result", #lines, 3)
check("the likeliest first, with its count", lines[1][1]:match("^%s*(.-)$"), "Strange Dust x2-3")
check("and its chance", lines[1][2], "75%")
check("a range of one and two", lines[2][1]:match("^%s*(.-)$"), "Greater Magic Essence x1-2")
check("a single one has no count", lines[3][1]:match("^%s*(.-)$"), "Small Glimmering Shard")
check("its chance", lines[3][2], "5%")

--------------------------------------------------------------------------------
print("\nnone")
--------------------------------------------------------------------------------

check("an item that can't be broken", #Lines(2), 0)
knows = false
check("a character without Disenchant", #Lines(1), 0)
knows = nil
check("a client that won't say", #Lines(1), 0)
knows = true
settings.tooltipDisenchantResults = false
check("picked Off", #Lines(1), 0)
settings.tooltipDisenchantResults = nil

--------------------------------------------------------------------------------
print("\non Shift")
--------------------------------------------------------------------------------

ns.TooltipShift = {
  Shows = function(_, key)
    if key == "disenchant" and settings.tooltipDisenchantShift == true then return shift end
    return true
  end,
}
settings.tooltipDisenchantShift = true
lines = Lines(1)
check("Shift up: held back", #lines, 0)
check("and the hint is asked for", lines.held, true)
shift = true
check("Shift down: shown", #Lines(1), 3)
ns.TooltipShift = nil

IsShiftKeyDown = saved.IsShiftKeyDown
if failures > 0 then error(("%d check(s) failed"):format(failures)) end
print("\ntest_disenchantresults: ok")
