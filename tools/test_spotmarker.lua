-- UI/SpotMarker.lua outside WoW (the same file in Pets, Tradeskills, Butler
-- and Farmer). Forever turns the game's own map pin down (a German player
-- found nothing at the Crossroads, 2026-10-29), so Show the way lays our own
-- gold marker. What must hold:
--   1. It is laid only on a place with a map and a spot.
--   2. It is drawn only on its own map, placed by the canvas.
--   3. Without the game's pin it goes once you stand on it; with the pin it
--      goes with the pin; a zone-only marker stays.
--   4. Waves only with Effects Full; Subtle and Off hold still.

local GLOBALS = { "CreateFrame", "UIParent", "GetTime", "WorldMapFrame", "C_Map" }
local saved = {}
for _, key in ipairs(GLOBALS) do saved[key] = _G[key] end

local failures = 0
local function check(name, got, want)
  local good = got == want
  if not good then failures = failures + 1 end
  print(("  %s  %-52s %s"):format(good and "ok  " or "FAIL", name, tostring(got)))
end

-- A frame or texture that takes any call and keeps what matters.
local function Stub(fields)
  local object = fields or {}
  object._shown = object._shown ~= false
  return setmetatable(object, { __index = function(_, key)
    if key == "Show" then return function(self) self._shown = true end end
    if key == "Hide" then return function(self) self._shown = false end end
    if key == "IsShown" then return function(self) return self._shown end end
    if key == "SetPoint" then return function(self, ...) self._point = { ... } end end
    if key == "GetWidth" then return function(self) return self._width or 0 end end
    if key == "GetHeight" then return function(self) return self._height or 0 end end
    if key == "GetFrameLevel" then return function() return 1 end end
    if key == "CreateTexture" or key == "CreateFontString" then return function() return Stub() end end
    if key == "SetText" then return function(self, text) self._text = text end end
    return function() end
  end })
end

CreateFrame = function() return Stub() end
UIParent = Stub()
local now = 100
GetTime = function() return now end

local ns = {}
ns.NewModule = function(name) local m = {} ns[name] = m return m end
ns.Theme = {
  Unpack = function() return 1, 1, 1, 1 end,
  CreateLabel = function() return Stub() end,
}
assert(loadfile(lfs_cwd .. "/UI/SpotMarker.lua"))("Blackthornes_TS", ns)
local Marker = ns.SpotMarker

print("\nlaying it")
check("no map, no marker", Marker:Show({ x = 10, y = 10 }), false)
local arrow = { ARRIVED = 15, Measure = function(north, west) return math.sqrt(north * north + west * west) end }
local away = 80
arrow.Here = function() return { map = 1413, x = 0.5, y = 0.3 } end
arrow.Offset = function() return away, 0 end
check("a place with a map and spot", Marker:Show({ map = 1413, x = 52, y = 30 },
  { name = "Crossroads", arrow = arrow }), true)
local light = Marker.current
check("kept with its name", light and light.name, "Crossroads")
check("no game pin", light and light.gamePin, false)

print("\nwhen it goes")
Marker.arriveSince = 0
check("waits a moment before looking", Marker:Done(0.2), false)
check("far away it stays", Marker:Done(1), false)
away = 10
check("standing on it, it goes", Marker:Done(1), true)
Marker:Show({ map = 1413, x = 50, y = 50 }, { name = "Somewhere", area = true })
check("a zone marker stays", Marker:Done(5), false)
local pinOn = true
C_Map = { HasUserWaypoint = function() return pinOn end }
Marker:Show({ map = 1413, x = 52, y = 30 }, { gamePin = true })
check("with the game's pin it stays", Marker:Done(1), false)
pinOn = false
check("and goes with it", Marker:Done(1), true)
C_Map = nil

print("\non the world map")
Marker:Show({ map = 1413, x = 50, y = 50 }, { name = "Crossroads" })
local canvas = Stub({ _width = 1000, _height = 600 })
local shownMap = 1413
WorldMapFrame = Stub({
  GetCanvas = function() return canvas end,
  GetMapID = function() return shownMap end,
  ScrollContainer = { GetCanvasScale = function() return 1 end },
})
Marker:Draw()
check("drawn on its own map", Marker.spot ~= nil and Marker.spot:IsShown(), true)
local point = Marker.spot and Marker.spot._point
check("in the middle of the canvas", point and ("%s,%s"):format(point[4], point[5]), "500,-300")
check("named", Marker.spot and Marker.spot.label._text, "Crossroads")
shownMap = 1414
Marker:Draw()
check("hidden on another map", Marker.spot:IsShown(), false)
Marker:Clear()
check("cleared", Marker.current, nil)

print("\nthe look")
check("waves go out on Full", #Marker.Look(1, "full").waves > 0, true)
check("then only the glow breathes", #Marker.Look(Marker.WAVE_FOR + 1, "full").waves, 0)
check("Subtle has no waves", #Marker.Look(1, "subtle").waves, 0)
check("Off holds still", #Marker.Look(1, "off").waves, 0)

for _, key in ipairs(GLOBALS) do _G[key] = saved[key] end

print("")
if failures > 0 then error(string.format("%d spot marker check(s) failed", failures)) end
print("  all spot marker checks passed")
print("")
