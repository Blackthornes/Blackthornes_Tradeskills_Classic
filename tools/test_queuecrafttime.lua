-- How long the queue takes to cast (a player asked, 2026-11-12).
--
-- What must hold:
--   1. Each entry adds its count times one cast (CraftTime:GetCast), the
--      sub-crafts too.
--   2. A craft with no known cast is counted apart and never guessed.
--   3. The time is split by who makes the craft.
--   4. With no craft timed, seconds is nil, so nothing says "about 0s".
--   5. The hover lists each character, most time first, "You" for the one
--      playing, then "Not timed yet" with its count.

local GLOBALS = { "CreateFrame", "GameTooltip", "UIParent" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local failures = 0
local function check(label, got, want)
  if got == want then
    print("  ok   " .. label)
  else
    failures = failures + 1
    print(string.format("  FAIL %s: got %s, want %s", label, tostring(got), tostring(want)))
  end
end

local function Stub()
  return setmetatable({}, { __index = function() return function() return Stub() end end })
end
CreateFrame = function() return Stub() end
UIParent = Stub()
GameTooltip = Stub()

local ns = {}
ns.NewModule = function(name) local m = ns[name] or {} ns[name] = m return m end
ns.RegisterEvent = function() end
ns.RegisterCommand = function() end
ns.Print, ns.Debug, ns.Warn = function() end, function() end, function() end
ns.db = {}

assert(loadfile(lfs_cwd .. "/Logic/Queue.lua"))("Blackthornes_TS", ns)

local CASTS = { [1] = 3, [2] = 5 }   -- recipe 3 has no known time
ns.CraftTime = {
  GetCast = function(_, recipeID) return CASTS[recipeID] end,
  Format = function(seconds) return seconds and (seconds .. "s") or "?" end,
}

local entries = {
  { recipeID = 1, quantity = 4, crafter = "me" },
  { recipeID = 2, quantity = 2, crafter = "alt", isDependency = true },
  { recipeID = 3, quantity = 6, crafter = "alt" },
  { recipeID = 1, quantity = 0, crafter = "me" },
}
local fake = setmetatable({
  GetAll = function() return entries end,
  GetCrafter = function(_, entry) return entry.crafter end,
}, { __index = ns.Queue })

local info = ns.Queue.GetCraftTime(fake)
check("1. seconds is every timed cast", info.seconds, 4 * 3 + 2 * 5)
check("1. timed crafts counted", info.timed, 6)
check("2. untimed crafts counted apart", info.untimed, 6)
check("3. my share", info.byCrafter.me, 12)
check("3. alt's share, sub-crafts too", info.byCrafter.alt, 10)
check("3. alt's untimed crafts", info.untimedBy.alt, 6)

entries = { { recipeID = 3, quantity = 2, crafter = "me" } }
local none = ns.Queue.GetCraftTime(fake)
check("4. nothing timed means no seconds", none.seconds, nil)
check("4. still says what is untimed", none.untimed, 2)

-- The hover lines, from UI/Tab_Queue.lua's QueueTimeTip.
ns.Characters = { IsPlaying = function(_, key) return key == "me" end }
ns.Recipes = { GetCharacterName = function(_, key) return key == "alt" and "Ana Stonebrook" or nil end }
ns.Columns = { Register = function() end }
ns.L = false   -- the file falls back to English keys
local chunk = assert(loadfile(lfs_cwd .. "/UI/Tab_Queue.lua"))
pcall(chunk, "Blackthornes_TS", setmetatable(ns, { __index = function() return Stub() end }))
setmetatable(ns, nil)

local Tip = ns.QueueTimeTip
check("5. the tip loaded", type(Tip) == "table", true)
if type(Tip) == "table" then
  local lines = Tip.Lines(info)
  check("5. three lines", #lines, 3)
  check("5. most time first", lines[1] and lines[1].left, "You")
  check("5. its time", lines[1] and lines[1].right, "12s")
  check("5. the alt by whole name", lines[2] and lines[2].left, "Ana Stonebrook")
  check("5. untimed last", lines[3] and lines[3].left, "Not timed yet")
  check("5. untimed count", lines[3] and lines[3].right, "6 crafts")
  check("5. nothing for no info", #Tip.Lines(nil), 0)
end

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end
if failures > 0 then error(failures .. " check(s) failed") end
