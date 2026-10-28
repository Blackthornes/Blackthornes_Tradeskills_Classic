-- The collapse button on the side panels (UI/Collapse.lua), without a game
-- client: that a click folds the body away and back, that the state is
-- remembered in settings, and that the sell list and craft pane ask for the
-- title strip's height while folded rather than their measured one.

local passed, failed = 0, 0

local function check(label, got, want)
  local ok = got == want
  if ok then passed = passed + 1 else failed = failed + 1 end
  print(string.format("  %-56s %-8s %s", label, tostring(got), ok and "ok" or
    ("WRONG, wanted " .. tostring(want))))
end

local settings = {}

local ns = {}
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.Theme, ns.Util = {}, {}
ns.Config = {
  Get = function(_, key) return settings[key] end,
  Set = function(_, key, value) settings[key] = value end,
}

-- Just enough of a frame and a button for Attach to work on.
local function Frame()
  local f = { shown = true, points = {} }
  function f:SetShown(v) self.shown = v and true or false end
  function f:IsShown() return self.shown end
  function f:ClearAllPoints() self.points = {} end
  function f:SetPoint(...) self.points[#self.points + 1] = { ... } end
  function f:SetHeight(h) self.height = h end
  function f:GetHeight() return self.height end
  return f
end

ns.Widgets = {
  CreateButton = function(_, text, onClick)
    local b = Frame()
    b.text = text
    function b:SetText(v) self.text = v end
    function b:Click() onClick(self, "LeftButton") end
    return b
  end,
}

assert(loadfile(lfs_cwd .. "/UI/Collapse.lua"))("Blackthornes_TS", ns)
local Collapse = ns.Collapse

print("")

local panel, header, title, body = Frame(), Frame(), Frame(), Frame()
local toggled = {}

local button = Collapse.Attach(panel, {
  key = "testCollapsed",
  header = header,
  title = title,
  body = body,
  onToggle = function(collapsed) toggled[#toggled + 1] = collapsed end,
})

check("starts open: body showing", body:IsShown(), true)
check("starts open: button offers to collapse", button.text, "-")
check("open: the panel keeps its measured height", Collapse.Height("testCollapsed", 500), 500)
check("the title sits just right of the button", title.points[1][2], button)
check("folded height is no less than the bevel needs", Collapse.HEIGHT >= 44, true)

button:Click()
check("one click: body hidden", body:IsShown(), false)
check("one click: button offers to expand", button.text, "+")
check("one click: remembered in settings", settings.testCollapsed, true)
check("one click: the panel is told it folded", toggled[1], true)
check("folded: the height is the title strip", Collapse.Height("testCollapsed", 500), Collapse.HEIGHT)

button:Click()
check("second click: body back", body:IsShown(), true)
check("second click: remembered as open", settings.testCollapsed, false)
check("second click: the panel is told it opened", toggled[2], false)

-- A panel built after a reload comes up the way it was left.
settings.laterCollapsed = true
local later, laterBody = Frame(), Frame()
local laterButton = Collapse.Attach(later, { key = "laterCollapsed", header = Frame(), title = Frame(), body = laterBody })
check("built folded after a reload: body hidden", laterBody:IsShown(), false)
check("built folded after a reload: button offers to expand", laterButton.text, "+")

--------------------------------------------------------------------------------
-- A dressed panel gets the gold fold gem on its trim instead
--------------------------------------------------------------------------------

local function Texture()
  local t = Frame()
  for _, name in ipairs({ "SetTexture", "SetSize", "SetAllPoints", "SetVertexColor", "SetBlendMode",
      "SetColorTexture", "SetAlpha" }) do t[name] = function() end end
  return t
end

local function GemFrame(parent)
  local f = Frame()
  f.parent, f.scripts = parent, {}
  function f:SetSize(w, h) self.width, self.height = w, h end
  function f:GetWidth() return self.width end
  function f:CreateTexture() return Texture() end
  function f:SetScript(name, fn) self.scripts[name] = fn end
  return f
end

CreateFrame = function(_, _, parent) return GemFrame(parent) end

local closeGem = GemFrame()
closeGem:SetSize(26, 26)
local trim = GemFrame()
trim.closeButton = closeGem
local dressed, dressedHeader, dressedTitle, dressedBody = Frame(), Frame(), Frame(), Frame()
dressed.titan = trim
dressedTitle:SetPoint("LEFT", dressedHeader, "LEFT", 10, 0)

local gem = Collapse.Attach(dressed, { key = "gemCollapsed", header = dressedHeader, title = dressedTitle, body = dressedBody })
check("dressed: the button is the fold gem", gem.isGem, true)
check("the gem rides on the trim", gem.parent, trim)
check("the gem sits beside the close gem", gem.points[1][2], closeGem)
check("left of the close gem", gem.points[1][4] < 0, true)
check("the title stays where it was", dressedTitle.points[1][2], dressedHeader)
check("open: a bar on the gem, no plus", gem.gemGlyph.down.shown, false)
check("open: offers to collapse", gem.tooltipText, "Collapse this window")

gem.scripts.OnClick(gem)
check("gem click: body hidden", dressedBody:IsShown(), false)
check("gem click: remembered in settings", settings.gemCollapsed, true)
check("gem click: a plus on the gem", gem.gemGlyph.down.shown, true)
check("gem click: offers to expand", gem.tooltipText, "Expand this window")
gem.scripts.OnClick(gem)
check("gem again: body back", dressedBody:IsShown(), true)
check("gem again: remembered as open", settings.gemCollapsed, false)

-- The craft pane has no close gem: its gem takes that corner.
local bare = GemFrame()
local lone, loneBody = Frame(), Frame()
lone.titan = bare
local loneGem = Collapse.Attach(lone, { key = "loneCollapsed", header = Frame(), title = Frame(), body = loneBody })
check("no close gem: the gem sits in the top right corner", loneGem.points[1][3], "TOPRIGHT")
check("no close gem: on the trim", loneGem.points[1][2], bare)

CreateFrame = nil

--------------------------------------------------------------------------------
-- The sell list uses it
--------------------------------------------------------------------------------

local PostPanel
do
  local realNew = ns.NewModule
  ns.NewModule = function(name) local m = realNew(name); PostPanel = m; return m end
  assert(loadfile(lfs_cwd .. "/UI/PostPanel.lua"))("Blackthornes_TS", ns)
  ns.NewModule = realNew
end

local AH = {
  GetTop = function() return 1091 end,
  GetBottom = function() return 551 end,
  GetRight = function() return 851 end,
}

ns.UI = { window = nil, FindAuctionFrame = function() return AH end }

settings.postPanelCollapsed = false
check("sell list open: auction window's height", PostPanel:TargetHeight(), 1091 - 551)

settings.postPanelCollapsed = true
check("sell list folded: its header, with Scan", PostPanel:TargetHeight(), PostPanel.FOLDED_HEIGHT)

ns.UI.FindAuctionFrame = function() return nil end
check("sell list folded, no auction window: still the strip",
  PostPanel:TargetHeight(true), PostPanel.FOLDED_HEIGHT)
check("no auction window, not asked for a fallback: leave it alone",
  PostPanel:TargetHeight(false), nil)

--------------------------------------------------------------------------------
-- The craft pane skips its expensive refresh while folded
--------------------------------------------------------------------------------

local CraftPanel
do
  local realNew = ns.NewModule
  ns.NewModule = function(name) local m = realNew(name); CraftPanel = m; return m end
  assert(loadfile(lfs_cwd .. "/UI/CraftPanel.lua"))("Blackthornes_TS", ns)
  ns.NewModule = realNew
end

local rowsAsked = 0
CraftPanel.GetRows = function() rowsAsked = rowsAsked + 1; return {} end
CraftPanel.FindTradeSkillFrame = function() return nil end
CraftPanel.frame = Frame()
CraftPanel.title = Frame()
function CraftPanel.title:SetText(v) self.text = v end
ns.Queue = { Count = function() return 3 end }

settings.craftPaneCollapsed = true
CraftPanel:Refresh()
check("craft pane folded: no recipes priced", rowsAsked, 0)
check("craft pane folded: the title carries the queue count",
  CraftPanel.title.text, "Craft queue (3 queued)")

CraftPanel:ApplyHeight()
check("craft pane folded: title strip height", CraftPanel.frame.height, Collapse.HEIGHT)

print(("\ncollapse: %d checks passed, %d wrong"):format(passed, failed))
if failed > 0 then error(("collapse: %d check(s) wrong"):format(failed)) end
