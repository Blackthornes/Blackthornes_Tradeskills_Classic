-- Material lines in the recipe panes show the item's own tooltip on hover
-- (a player asked, 2026-11-09). Widgets.HoverItemLine reads the item the
-- line was last filled with; the "and N more" line has none and shows nothing.

local ns = {}
ns.Theme = {
    Fill = function() return { SetColorTexture = function() end, SetAlpha = function() end } end,
    Unpack = function() return 1, 1, 1, 1 end,
    Border = function() end,
    CreateLabel = function() return {} end,
}
ns.Util = { HasFunction = function() return true end }

local function Frame()
    local frame = { scripts = {} }
    frame.SetScript = function(self, name, fn) self.scripts[name] = fn end
    frame.EnableMouse = function(self, on) self.mouse = on end
    return setmetatable(frame, { __index = function() return function() end end })
end
CreateFrame = function() return Frame() end

local shown, hidden, owner = {}, 0, nil
GameTooltip = {
    SetOwner = function(_, o) owner = o end,
    SetItemByID = function(_, id) shown[#shown + 1] = id end,
    NumLines = function() return 3 end,
    SetText = function() end,
    Show = function() end,
    Hide = function() hidden = hidden + 1 end,
}

do
    local chunk = assert(loadfile(lfs_cwd .. "/UI/Widgets.lua"))
    chunk("Blackthornes_TS", ns)
end
local Widgets = ns.Widgets

local passed, failed = 0, 0
local function check(label, got, want)
    local ok = got == want
    if ok then passed = passed + 1 else failed = failed + 1 end
    print(string.format("  %-50s %-10s %s", label, tostring(got), ok and "ok" or
        ("WRONG, wanted " .. tostring(want))))
end

print("")
print("a material line")
local line = Widgets.HoverItemLine(Frame())
check("takes the mouse", line.mouse, true)

line.itemID, line.itemName = 2589, "Linen Cloth"
line.scripts.OnEnter(line)
check("a hover shows the item", shown[1], 2589)
check("over the line", owner, line)

line.scripts.OnLeave(line)
check("leaving hides the tooltip", hidden, 1)

line.itemID, line.itemName = nil, nil
line.scripts.OnEnter(line)
check("the 'and N more' line shows nothing", #shown, 1)

check("no line is no error", Widgets.HoverItemLine(nil), nil)

print("")
if failed > 0 then
    error(("%d hover line check(s) failed"):format(failed))
end
print(("  hover item line: all %d checks passed"):format(passed))
