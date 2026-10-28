-- One odd scan must not throw off an item's usual price (the owner,
-- 2026-10-28: a cloak that sold for about 10s read 45g after one scan saw
-- only two listed at 150g each).
--
--   1. A scan more than 3 times above or below the usual price is held back.
--   2. Three such scans in a row, the same way, and the usual price jumps
--      straight to the new one.
--   3. An ordinary scan in between starts the count again.
--   4. Ordinary scans average in as before; a new item takes its first scan.

local failures = 0
local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(string.format("  FAIL  %-52s got %s, wanted %s", label, tostring(got), tostring(want)))
  else
    print(string.format("  ok    %-52s %s", label, tostring(got)))
  end
end

local Prices
do
  local priceNs = {
    NewModule = function() Prices = {}; return Prices end,
    Util = { Clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end },
    RegisterCommand = function() end,
    Config = { Get = function() return nil end },
  }
  assert(loadfile(lfs_cwd .. "/Data/Prices.lua"))("Blackthornes_TS", priceNs)
end

print("\nheld back")
local r = {}
Prices.Smooth(r, 1000)
check("a new item takes its first scan", r.market, 1000)
Prices.Smooth(r, 1100)
check("an ordinary scan averages in", r.market, 1030)
Prices.Smooth(r, 1500000)
check("one 150g scan is held back", r.market, 1030)
Prices.Smooth(r, 1000)
check("the next ordinary scan averages in", r.market, 1021)
check("and the count starts again", r.odd, nil)

print("\nbelieved after three")
Prices.Smooth(r, 50000)
Prices.Smooth(r, 52000)
check("two high scans: still held", r.market, 1021)
Prices.Smooth(r, 51000)
check("the third moves it straight there", r.market, 51000)

print("\ndown as well")
Prices.Smooth(r, 100)
Prices.Smooth(r, 200)
check("two low scans: still held", r.market, 51000)
Prices.Smooth(r, 300000)
check("a high one between starts the count again", r.odd.n, 1)
Prices.Smooth(r, 100)
check("one way only counts that way", r.odd.n, 1)

print("\nthe cloak")
local cloak = { market = 395319 }
Prices.Smooth(cloak, 9952)
Prices.Smooth(cloak, 10000)
Prices.Smooth(cloak, 9952)
check("a poisoned price comes back after three scans", cloak.market, 9952)

if failures > 0 then error(("%d check(s) failed"):format(failures)) end
print("\ntest_oddscan: ok")
