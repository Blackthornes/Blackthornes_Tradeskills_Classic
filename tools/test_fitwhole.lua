-- Text whole, never cut to "..." (the owner's UI review, 2026-10-29).
--
-- What must hold:
--   1. Theme.FitWhole keeps a label's own size when the text fits.
--   2. Too long, it tries the smaller sizes, then wraps in the last and says
--      how much taller it stands.
--   3. Theme.SetRowLine marks a wrapped second line so its row grows, and
--      clears the mark once the text fits again.

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterEvent = function() return true end
ns.COLORS = {}

local CHAR = { [10] = 5, [12] = 6, [14] = 7 }

local function Label(width)
    local label = { width = width, wrap = true, size = 12, text = "" }
    label.SetFont = function(self, _, size) self.size = size end
    label.SetWordWrap = function(self, on) self.wrap = on end
    label.SetText = function(self, text) self.text = text end
    label.GetText = function(self) return self.text end
    label.GetWidth = function(self) return self.width end
    label.GetUnboundedStringWidth = function(self) return #self.text * (CHAR[self.size] or 6) end
    label.GetStringHeight = function(self)
        local lines = self.wrap and math.ceil(#self.text * (CHAR[self.size] or 6) / self.width) or 1
        return lines * (self.size + 2)
    end
    return setmetatable(label, { __index = function() return function() end end })
end

local function Region()
    return setmetatable({}, { __index = function() return function() end end })
end
CreateFrame = function() return Region() end
UIParent = Region()

assert(loadfile(lfs_cwd .. "/UI/Theme.lua"))("Blackthornes_TS", ns)
local Theme = ns.Theme
Theme.sizes = { tiny = 10, small = 12, normal = 14 }

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

-- 1
local label = Label(120)
local extra = Theme.FitWhole(label, "short words", { "small", "tiny" })
check("short text keeps its size", extra == 0 and label.size == 12 and label.wrap == false)
check("and is all there", label.text == "short words")

-- 2
label = Label(120)
extra = Theme.FitWhole(label, ("x"):rep(22), { "small", "tiny" })
check("a size smaller when that fits", extra == 0 and label.size == 10 and label.wrap == false)
label = Label(120)
extra = Theme.FitWhole(label, ("x"):rep(40), { "small", "tiny" })
check("too long even then: wrapped, never cut", label.wrap == true and label.text == ("x"):rep(40))
check("and it says how much taller", extra == 12)

-- 3
local line = Label(100)
Theme.SetRowLine(line, ("y"):rep(50), 20)
check("a wrapped row line asks for room", line.rowNeed == 20 + 12 + 24 and line.rowNeedText == ("y"):rep(50))
Theme.SetRowLine(line, "fits", 20)
check("one that fits asks for none", rawget(line, "rowNeed") == nil)

print(("\n%d check(s) passed\n"):format(checks))
