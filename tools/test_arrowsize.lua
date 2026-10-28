-- Arrow Size (the owner, 2026-10-26): the whole arrow can be drawn at 50%,
-- 65% or 100%. On Era 65% is the usual size (the arrow already stood there)
-- and saves nothing, so nobody's arrow changes until a size is picked, and a
-- new size keeps the arrow's spot.

local ns = {}
ns.L = setmetatable({}, { __index = function(_, key) return key end })
ns.NewModule = function(name) local m = {} ns[name] = m return m end
ns.db = {}
assert(loadfile(lfs_cwd .. "/UI/WayArrow.lua"))("Blackthornes_TS", ns)
local ArrowUI, db = ns.WayArrowUI, ns.db

local failures = 0
local function check(label, ok)
    if not ok then
        failures = failures + 1
        print("  FAIL arrow size: " .. label)
    end
end

check("65% until one is picked", ArrowUI.Scale() == 0.65 and ArrowUI.Size() == 65)
ArrowUI:SetSize(100)
check("100% is kept", db.wayArrowSize == 100 and ArrowUI.Scale() == 1)
ArrowUI:SetSize(75)
check("a size not offered is ignored", db.wayArrowSize == 100)
db.wayArrowSize = "junk"
check("a bad save reads as 65%", ArrowUI.Scale() == 0.65)
ArrowUI:SetSize(65)
check("65% saves nothing", db.wayArrowSize == nil)

-- The spot is kept in the screen's own units.
local placed
local frame = {
    ClearAllPoints = function() end,
    SetPoint = function(_, point, _, _, x, y) placed = { point = point, x = x, y = y } end,
    SetScale = function(self, scale) self.scale = scale end,
    GetCenter = function() return 200, 100 end,
}
ArrowUI.frame = frame
ArrowUI.AvoidXPBar = function() end
db.wayArrowX, db.wayArrowY = 400, 300
ArrowUI:SetSize(50)
check("drawn at half size", frame.scale == 0.5)
check("the spot stays on screen", placed and math.abs(placed.x - 800) < 0.01
    and math.abs(placed.y - 600) < 0.01)
check("the saved spot is untouched", db.wayArrowX == 400 and db.wayArrowY == 300)
ArrowUI:SavePosition()
check("a drag saves screen units", db.wayArrowX == 100 and db.wayArrowY == 50)
ArrowUI:SetSize(65)
check("back to 65%", frame.scale == 0.65)

ArrowUI.frame, ArrowUI.AvoidXPBar = nil, nil
if failures > 0 then error(string.format("%d arrow size check(s) failed", failures)) end
print("  all arrow size checks passed")
print("")
