-- A whole-number box stores a whole number, and only a change is reported.
--
-- Two bugs in one widget. Typing 5.5 into a box with no decimals showed 6
-- but handed 5.5 to the setting behind it, and a posted limit of 5.5 then
-- broke every "%d" that printed it. And clicking into a box and away again
-- reported the unchanged value as a change: on the Profit tab's "Keep in
-- stock" box that wrote the account-wide default down as a per-item override.

local ns = {}
ns.Theme = {
    Fill = function() return { SetColorTexture = function() end, SetAlpha = function() end } end,
    Unpack = function() return 0, 0, 0, 1 end,
    Border = function() end,
    SetBorderColor = function() end,
    CreatePanel = function() return CreateFrame() end,
    CreateLabel = function() return {} end,
    FONT = "font",
    sizes = { small = 10 },
}

local function Frame()
    local frame = { scripts = {}, text = "" }
    frame.SetScript = function(self, name, fn) self.scripts[name] = fn end
    frame.SetText = function(self, text) self.text = text end
    frame.GetText = function(self) return self.text end
    frame.ClearFocus = function(self)
        if self.scripts.OnEditFocusLost then self.scripts.OnEditFocusLost(self) end
    end
    return setmetatable(frame, { __index = function() return function() end end })
end

CreateFrame = function() return Frame() end
ns.Theme.CreatePanel = function() return Frame() end

assert(loadfile(lfs_cwd .. "/UI/Widgets.lua"))("Blackthornes_TS", ns)
local Widgets = ns.Widgets

local passed, failed = 0, 0
local function check(label, got, want)
    local ok = got == want
    if ok then passed = passed + 1 else failed = failed + 1 end
    print(string.format("  %-56s %-8s %s", label, tostring(got), ok and "ok" or
        ("WRONG, wanted " .. tostring(want))))
end

local reported = {}
local box = Widgets.CreateNumberBox(Frame(), {
    min = 0, max = 999,
    onChange = function(value) reported[#reported + 1] = value end,
})

print("")
print("a whole-number box")

box:SetValue(5, true)
check("filled without reporting",           #reported, 0)

box:SetValue("5.5")
check("five and a half is stored as six",   box.value, 6)
check("and six is what was reported",       reported[#reported], 6)

local before = #reported
box:SetValue(6)
check("setting the same value again reports nothing", #reported, before)

box:SetValue(7)
check("a real change is reported",          reported[#reported], 7)

-- A button waiting for its second click ("Click Again") wears a red edge,
-- and a mouse passing over it does not take the red away.
local edge = {}
ns.Theme.SetBorderColor = function(frame, key) edge[frame] = key end
ns.Theme.CreateLabel = function() return Frame() end
ns.Theme.TopSheen = function() end
GameTooltip = GameTooltip or Frame()

local armedButton = Widgets.CreateButton(Frame(), "Clear all", function() end)
-- The stub frame answers every unknown field; this button has no outline.
armedButton.outline, armedButton.disabled, armedButton.baseColor = false, false, false
armedButton:SetConfirming(true)
check("an armed button has a red edge",         edge[armedButton], "loss")
armedButton.scripts.OnEnter(armedButton)
check("hovering keeps it red",                  edge[armedButton], "loss")
armedButton.scripts.OnLeave(armedButton)
check("and so does leaving",                    edge[armedButton], "loss")
armedButton:SetConfirming(false)
check("back to normal once disarmed",           edge[armedButton], "metal")

print("")
if failed > 0 then error(("%d check(s) failed"):format(failed), 0) end
print(("all %d number box checks passed"):format(passed))
