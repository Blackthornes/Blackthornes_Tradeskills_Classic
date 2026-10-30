-- The shared house pieces (UI/HouseKit.lua, UI/RowMenu.lua, UI/Notice.lua,
-- UI/SharedChoices.lua), outside WoW. The same test in all five Blackthornes
-- addons.
--
-- What must hold:
--   1. View tabs are as wide as their words, sit side by side, light the one
--      picked, call back only on a change, and can hide one.
--   2. A chip lights when selected and is as wide as its words.
--   3. The empty block shows its line, and a button only when given one.
--   4. The row menu opens with a line each, runs the one clicked and goes;
--      a disabled line does nothing; nothing to offer opens nothing.
--   5. Notes from two addons stack one under the next, never on top, and a
--      second note with the same key replaces the first.
--   6. A shared choice reaches every other addon, never comes back, and an
--      addon that raises does not stop the rest.
--   7. Panel gems fold and close, and say which by a bar or a plus.

local NAMES = { "CreateFrame", "UIParent", "GetTime", "C_Timer", "GetCursorPosition",
    "BlackthornesNotice", "BlackthornesSharedChoices" }
local saved = {}
for _, name in ipairs(NAMES) do saved[name] = _G[name] end
BlackthornesNotice, BlackthornesSharedChoices = nil, nil

local now = 100
GetTime = function() return now end
local timers = {}
C_Timer = { After = function(delay, fn) timers[#timers + 1] = fn end }
GetCursorPosition = function() return 300, 400 end

local function Object(parent)
    local o = { shown = true, parent = parent, scripts = {}, points = {}, w = 0, h = 0, alpha = 1 }
    function o:Show() self.shown = true end
    function o:Hide() self.shown = false end
    function o:SetShown(on) self.shown = on and true or false end
    function o:IsShown() return self.shown end
    function o:SetScript(name, fn) self.scripts[name] = fn end
    function o:GetScript(name) return self.scripts[name] end
    function o:SetSize(w, h) self.w, self.h = w, h end
    function o:SetWidth(w) self.w = w end
    function o:SetHeight(h) self.h = h end
    function o:GetWidth() return self.w end
    function o:GetHeight() return self.h end
    function o:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function o:ClearAllPoints() self.points = {} end
    function o:SetAllPoints() end
    function o:SetAlpha(a) self.alpha = a end
    function o:GetAlpha() return self.alpha end
    function o:EnableMouse() end
    function o:SetFrameStrata() end
    function o:SetToplevel() end
    function o:SetClampedToScreen() end
    function o:RegisterForClicks() end
    function o:IsMouseOver() return false end
    function o:GetEffectiveScale() return 1 end
    function o:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
    function o:SetTexture(path) self.texture = path end
    function o:SetTexCoord() end
    function o:SetText(text) self.text = text end
    function o:GetText() return self.text end
    function o:SetTextColor(r, g, b) self.textColor = { r, g, b } end
    function o:SetJustifyH() end
    function o:SetWordWrap() end
    function o:GetStringWidth() return #(self.text or "") * 6 end
    function o:CreateTexture() return Object(self) end
    function o:CreateFontString() return Object(self) end
    return o
end
CreateFrame = function(_, _, parent) return Object(parent) end
UIParent = Object(nil)

local function MakeNs(name)
    local theme = {
        Unpack = function(key, alpha) return 0.5, 0.5, 0.5, alpha or 1 end,
        CreateLabel = function(parent) return Object(parent) end,
        Border = function() end,
    }
    local ns = { Theme = theme, L = setmetatable({}, { __index = function(_, k) return k end }) }
    ns.Widgets = {
        CreateButton = function(parent, text, onClick)
            local b = Object(parent)
            b.text, b.onClick = text, onClick
            return b
        end,
    }
    for _, file in ipairs({ "UI/HouseKit.lua", "UI/RowMenu.lua", "UI/Notice.lua", "UI/SharedChoices.lua" }) do
        assert(loadfile(lfs_cwd .. "/" .. file))(name, ns)
    end
    return ns
end

local ns = MakeNs("Blackthornes_One")
local other = MakeNs("Blackthornes_Two")

-- 1. View tabs.
local picked = {}
local strip = ns.Widgets.CreateViewTabs(UIParent, {
    { key = "mine", text = "My Crafts" },
    { key = "time", text = "Your Time" },
    { key = "learn", text = "Recipes to Learn" },
}, function(key) picked[#picked + 1] = key end, { selected = "mine" })
assert(strip.selected == "mine", "the first view is picked")
assert(#picked == 0, "picking at build time calls nothing")
local mine, learn = strip.byKey.mine, strip.byKey.learn
assert(learn.wide > mine.wide, "a longer name makes a wider tab")
assert(mine.wide == #"My Crafts" * 6 + 24, "as wide as its words and padding")
assert(mine.top.shown and not learn.top.shown, "only the picked tab has its gold top")
learn:GetScript("OnClick")(learn)
assert(strip.selected == "learn" and picked[1] == "learn", "a click picks and calls back")
strip:Select("learn")
assert(#picked == 1, "picking the one already picked calls nothing")
strip:SetTabShown("time", false)
assert(not strip.byKey.time.shown, "a hidden view's tab goes")
assert(strip.used == mine.wide + learn.wide + 3, "the others close up")

-- 2. A chip.
local clicked = 0
local chip = ns.Widgets.CreateChip(UIParent, "Vendor", function() clicked = clicked + 1 end)
assert(chip:GetWidth() == math.max(34, #"Vendor" * 6 + 16), "a chip is as wide as its words")
assert(not chip:IsSelected() and not chip.under.shown, "unpicked at first")
chip:SetSelected(true)
assert(chip:IsSelected() and chip.under.shown, "selected lights it")
chip:GetScript("OnClick")(chip)
assert(clicked == 1, "a click calls back")

-- 3. The empty block.
local empty = ns.Widgets.CreateEmpty(UIParent)
empty:Set("Nothing matches your search.")
assert(empty.text.text == "Nothing matches your search.", "it shows its line")
assert(empty.button == nil, "no button without a next step")
local cleared = false
empty:Set("Nothing matches your search.", "Clear Search", function() cleared = true end)
assert(empty.button and empty.button.shown and empty.button.text == "Clear Search", "the button shows")
empty.button.onClick()
assert(cleared, "the button does the next step")
empty:SetText("Pick a row.")
assert(not empty.button.shown, "a line alone hides the button")

-- 4. The row menu.
local ran = {}
assert(ns.RowMenu:Open({}) == nil, "nothing to offer opens nothing")
local menu = ns.RowMenu:Open({
    { text = "Queue One", run = function() ran[#ran + 1] = "queue" end },
    { text = "Search the Auction House", run = function() ran[#ran + 1] = "search" end },
    { text = "Off", run = function() ran[#ran + 1] = "off" end, disabled = true },
}, { title = "Copper Bar" })
assert(menu.shown and menu.title.text == "Copper Bar", "it opens with the row's name")
assert(menu.lines[1].shown and menu.lines[3].shown, "a line for each")
menu.lines[3]:GetScript("OnClick")(menu.lines[3])
assert(#ran == 0 and menu.shown, "a disabled line does nothing")
menu.lines[2]:GetScript("OnClick")(menu.lines[2])
assert(ran[1] == "search" and not menu.shown, "a click runs its line and closes")
ns.RowMenu:Open({ { text = "Track", run = function() end } })
assert(not menu.lines[2].shown, "lines from before go")

-- 5. Notes stack across addons.
local first = ns.Notice:Show("Your bags are full.", { key = "bags" })
local second = other.Notice:Show("You have no Healthstone.")
assert(ns.Notice:Count() == 2 and other.Notice:Count() == 2, "both addons see both notes")
local y1, y2 = first.points[1][5], second.points[1][5]
assert(y1 ~= y2, "two notes never land on the same spot")
assert(y2 == ns.Notice.TOP, "the newest is on top")
ns.Notice:Show("Your bags are full.", { key = "bags" })
assert(ns.Notice:Count() == 2, "the same key replaces its note")
now = now + 100
first:GetScript("OnUpdate")(first)
assert(ns.Notice:Count() == 1 and not first.shown, "a note goes once it has faded")
assert(second.points[1][5] == ns.Notice.TOP, "the rest move up")

-- 6. Shared choices.
local heard = {}
ns.SharedChoices:Join("One", function(choice, value)
    heard[#heard + 1] = "one:" .. choice
    ns.SharedChoices:Changed(choice, value)
end)
other.SharedChoices:Join("Two", function(choice, value)
    heard[#heard + 1] = "two:" .. choice .. "=" .. tostring(value)
    other.SharedChoices:Changed(choice, value)
end)
BlackthornesSharedChoices.members.Three = function() error("broken") end
local took = ns.SharedChoices:Changed("textSize", "large")
assert(took == 1, "one other addon took it, the broken one skipped")
assert(#heard == 1 and heard[1] == "two:textSize=large", "it never comes back")
assert(ns.SharedChoices:Changed("nothing", 1) == 0, "only the shared choices go")

-- 7. Panel gems.
local header = Object(UIParent)
local folds, closes = {}, 0
local gems = ns.Widgets.CreatePanelGems(header, {
    onFold = function(on) folds[#folds + 1] = on end,
    onClose = function() closes = closes + 1 end,
})
assert(gems.fold and gems.close, "a fold gem and a close gem")
assert(not gems.fold.down.shown, "open, the fold gem shows a bar")
gems.fold:GetScript("OnClick")(gems.fold)
assert(folds[1] == true and gems.folded and gems.fold.down.shown, "a click folds and shows a plus")
gems.fold:GetScript("OnClick")(gems.fold)
assert(folds[2] == false and not gems.fold.down.shown, "again opens")
gems.close:GetScript("OnClick")(gems.close)
assert(closes == 1, "the close gem closes")
gems:SetFolded(true)
assert(gems.folded and #folds == 2, "SetFolded calls nothing back")

for _, name in ipairs(NAMES) do _G[name] = saved[name] end
print("test_housekit: ok")
