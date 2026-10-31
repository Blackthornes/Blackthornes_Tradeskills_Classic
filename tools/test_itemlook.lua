-- UI/ItemLook.lua: the thin quality ring round an item's icon. The same
-- file and test in all five addons.

local checks = 0
local function check(cond, what)
    if not cond then error("itemlook: " .. what, 2) end
    checks = checks + 1
end

local function NewTexture(parent)
    local t = { shown = true, parent = parent, points = {} }
    function t:GetParent() return self.parent end
    function t:GetDrawLayer() return self.layer or "ARTWORK", self.sub or 0 end
    function t:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function t:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
    function t:Show() self.shown = true end
    function t:Hide() self.shown = false end
    function t:SetShown(on) self.shown = on and true or false end
    function t:IsShown() return self.shown end
    return t
end

local function NewFrame()
    local f = { made = {} }
    function f:CreateTexture(_, layer, _, sub)
        local t = NewTexture(self)
        t.layer, t.sub = layer, sub
        self.made[#self.made + 1] = t
        return t
    end
    return f
end

local saved = {
    C_Item = rawget(_G, "C_Item"),
    GetItemInfo = rawget(_G, "GetItemInfo"),
    ITEM_QUALITY_COLORS = rawget(_G, "ITEM_QUALITY_COLORS"),
}
C_Item = {
    GetItemQualityByID = function(id)
        if id == 2589 then return 1 end
        if id == 4561 then return 2 end
        return nil
    end,
}
GetItemInfo = nil
ITEM_QUALITY_COLORS = nil

local ns = {}
local chunk = assert(loadfile((rawget(_G, "lfs_cwd") or ".") .. "/UI/ItemLook.lua"))
chunk("Test", ns)
local ItemLook = ns.ItemLook
check(ItemLook ~= nil, "module is set on ns")

-- Colours: the game's table first, else our own.
local r, g, b = ItemLook.Color(2)
check(r == 0.12 and g == 1.00 and b == 0.00, "green from our own table")
ITEM_QUALITY_COLORS = { [2] = { r = 0.1, g = 0.9, b = 0.2 } }
r = ItemLook.Color(2)
check(r == 0.1, "the game's colour wins")
ITEM_QUALITY_COLORS = nil
check(ItemLook.Color(nil) == nil, "no quality, no colour")
check(ItemLook.Color(42) == nil, "unknown quality, no colour")

-- Quality by item.
check(ItemLook.QualityOf(4561) == 2, "quality by ID")
check(ItemLook.QualityOf(9999) == nil, "not loaded yet")
check(ItemLook.QualityOf(nil) == nil, "nothing given")

-- The ring sits behind the icon and follows it.
local frame = NewFrame()
local icon = frame:CreateTexture(nil, "ARTWORK", nil, 0)
ItemLook.Attach(icon)
local ring = ItemLook.RingOf(icon)
check(ring ~= nil, "a ring is made")
check(ring.layer == "ARTWORK" and ring.sub == -1, "drawn just behind the icon")
check(#ring.points == 2, "anchored to the icon's corners")
check(ring.shown == false, "no ring before a quality")
check(ItemLook.Attach(icon) == ItemLook.Attach(icon), "attaching twice keeps one ring")

ItemLook.SetItem(icon, 4561)
check(ring.shown == true, "a green item shows its ring")
check(ring.color[2] == 1.00 and ring.color[4] == ItemLook.ALPHA, "in green, full strength")
check(ItemLook.QualityShown(icon) == 2, "remembers the quality")

icon:Hide()
check(ring.shown == false, "hides with the icon")
icon:Show()
check(ring.shown == true, "shows with the icon")
icon:SetShown(false)
check(ring.shown == false, "SetShown follows too")
icon:SetShown(true)

ItemLook.SetItem(icon, 2589)
check(ring.color[4] == ItemLook.PLAIN_ALPHA, "a white item's ring is softer")

ItemLook.SetItem(icon, 9999)
check(ring.shown == false, "an item not loaded yet has no ring")
ItemLook.SetItem(icon, 9999, 3)
check(ring.shown == true and ItemLook.QualityShown(icon) == 3, "a quality the caller knows is used")
ItemLook.SetQuality(icon, nil)
check(ring.shown == false, "nil takes the ring away")

-- An icon that is never attached gets one on first use; a texture with no
-- parent to draw on is left alone without an error.
local loose = NewTexture(nil)
ItemLook.SetItem(loose, 4561)
check(ItemLook.RingOf(loose) == nil, "no parent, no ring, no error")
local other = frame:CreateTexture(nil, "OVERLAY", nil, -8)
ItemLook.SetItem(other, 4561)
check(ItemLook.RingOf(other).sub == -8, "never below the lowest sublevel")

C_Item = saved.C_Item
GetItemInfo = saved.GetItemInfo
ITEM_QUALITY_COLORS = saved.ITEM_QUALITY_COLORS
print(("  itemlook: %d checks passed"):format(checks))
