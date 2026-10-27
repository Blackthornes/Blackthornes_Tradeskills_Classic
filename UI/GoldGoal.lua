-- Blackthornes Tradeskills -- UI/GoldGoal.lua
-- Goblin Gold's bar: your gold on this realm and side, a goal, and small
-- rewards on the way to it.
--
-- Asked 2026-10-17, from a mockup. A small bar that stays on screen while
-- "Gold Tracker" is ticked: the total counting up rather than jumping,
-- today's gold, a glowing fill with a tick at each tenth of the goal, and
-- the gold still to go. New gold floats up off the fill. Each tenth lights
-- its tick, bursts a few coins and plays a coin sound; the goal opens a
-- window with how long it took and a box for the next one. Today's gold
-- glows when it beats your best day. Hovering the bar lists every
-- character it counts. Drag it anywhere; the grip below its corner sizes
-- it, right-click for the normal size.
--
-- Logic/GoldGoal.lua works out the numbers and when to cheer; this only
-- draws. Nothing is built until the bar is first turned on, and nothing is
-- drawn while it is hidden. Motion follows the Window effects setting.
--
-- The glow-up (asked 2026-10-18, from a mockup): a star breathes at the end
-- of the gold and a soft light runs along it, as on Farmer's XP bar; a glint
-- crosses the coin, the total flashes as it counts, Today pulses while it
-- beats your best day, gold gems cap the bar, each tenth is a small diamond
-- and a few sparkles twinkle on the gold. All of it is animations the game
-- plays, set again only when Window effects or the gold's width moves.
-- Subtle keeps the star and a slower light; Off keeps everything still.

local ADDON, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local GoldGoalUI = {}
ns.GoldGoalUI = GoldGoalUI

local COPPER_PER_GOLD = 10000

GoldGoalUI.WIDTH = 270
GoldGoalUI.HEIGHT = 78
local PAD = 10
local BAR_HEIGHT = 12
local COIN = [[Interface\Icons\INV_Misc_Coin_01]]
local EMBLEM = [[Interface\Icons\INV_Misc_Coin_02]]
local GLOW = ([[Interface\AddOns\%s\Media\Frame\Glow]]):format(ADDON)
-- Drawn by tools/make_gold_art.py; rerun it, never edit the TGAs.
local GEM = ([[Interface\AddOns\%s\Media\Frame\GoldGem]]):format(ADDON)
local SPARKLE = ([[Interface\AddOns\%s\Media\Frame\GoldSparkle]]):format(ADDON)

-- Window effects: { star's grow, star's dim, seconds a breath, sweep's
-- light, sweep's speed in pixels a second, rest between sweeps, and the
-- touches only Full has }. Off has none, so nothing moves.
GoldGoalUI.MOTION = {
    full = { grow = 1.18, dim = 0.7, breath = 1.1, light = 0.32, speed = 90, rest = 1.5,
        twinkle = true, glint = true, pulse = true },
    subtle = { grow = 1.07, dim = 0.88, breath = 1.6, light = 0.16, speed = 60, rest = 3 },
}
GoldGoalUI.SWEEP = 48
-- Where the sparkles sit along the gold, as a share of its width.
GoldGoalUI.TWINKLES = { 0.16, 0.39, 0.62, 0.86 }
-- A tenth's diamond, and how much bigger it is once reached.
GoldGoalUI.TICK = 7
GoldGoalUI.TICK_LIT = 9

-- The game's own sounds, by id: the loot window's coins for a tenth, the
-- achievement toast for the goal, the level-up chime if that one will not.
GoldGoalUI.SOUNDS = {
    step = { 120, 878 },
    goal = { 12891, 888 },
}

-- Weekday names for "Best day: Tuesday", by date("%w").
local WEEKDAYS = {
    [0] = L["Sunday"], L["Monday"], L["Tuesday"], L["Wednesday"],
    L["Thursday"], L["Friday"], L["Saturday"],
}

local function Motion() return ns.Motion end
local function Level()
    local motion = Motion()
    return motion and motion.Level and motion.Level() or "full"
end

local function Money(copper, parts)
    return Util.FormatMoney(copper, parts and { parts = parts } or { short = true })
end

--------------------------------------------------------------------------------
-- Sound
--------------------------------------------------------------------------------

--- Play a cheer's sound, unless Goblin Gold's sound is unticked.
function GoldGoalUI.Play(which)
    if ns.Config and ns.Config:Get("goldTrackerSound") == false then return false end
    if type(PlaySound) ~= "function" then return false end
    for _, id in ipairs(GoldGoalUI.SOUNDS[which] or {}) do
        local ok, willPlay = pcall(PlaySound, id, "Master")
        if ok and willPlay then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- Place and size
--------------------------------------------------------------------------------

local function Scale()
    local percent = tonumber(ns.Config and ns.Config:Get("goldTrackerScale")) or 100
    return math.max(0.5, math.min(1.5, percent / 100))
end

--- Put the bar where it was left: its top left corner, in UIParent's own
--- units, so a new size keeps it in place.
function GoldGoalUI:Place()
    local frame = self.frame
    if not frame then return end
    local scale = Scale()
    frame:SetScale(scale)
    frame:ClearAllPoints()

    local x = tonumber(ns.Config:Get("goldTrackerX"))
    local y = tonumber(ns.Config:Get("goldTrackerY"))
    if x and y then
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    else
        frame:SetPoint("TOP", UIParent, "TOP", 0, -120 / scale)
    end
end

local function SavePlace(frame)
    local scale = frame:GetScale() or 1
    local left, top = frame:GetLeft(), frame:GetTop()
    if not (left and top) then return end
    ns.Config:Set("goldTrackerX", math.floor(left * scale + 0.5))
    ns.Config:Set("goldTrackerY", math.floor(top * scale + 0.5))
end

--- Back to the top of the screen at its normal size.
function GoldGoalUI:ResetPlace()
    ns.Config:Set("goldTrackerX", nil)
    ns.Config:Set("goldTrackerY", nil)
    ns.Config:Set("goldTrackerScale", 100)
    self:Place()
end

--- The grip below the bottom right corner: drag to size the bar from its
--- top left corner, right-click for the normal size.
local function BuildGrip(frame)
    local grip = Theme.CreatePanel(frame, "panel", "borderLit")
    grip:SetSize(14, 14)
    grip:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", -4, -3)
    grip:EnableMouse(true)

    for row = 0, 2 do
        for column = 2 - row, 2 do
            local dot = grip:CreateTexture(nil, "ARTWORK")
            dot:SetSize(2, 2)
            dot:SetPoint("BOTTOMRIGHT", grip, "BOTTOMRIGHT", -3 - (2 - column) * 3, 3 + (2 - row) * 3)
            dot:SetColorTexture(Theme.Unpack("accent"))
        end
    end

    grip:SetScript("OnMouseDown", function(self, button)
        if button == "RightButton" then
            ns.Config:Set("goldTrackerScale", 100)
            SavePlace(frame)
            GoldGoalUI:Place()
            return
        end
        local scale = frame:GetScale() or 1
        self.left, self.top = (frame:GetLeft() or 0) * scale, (frame:GetTop() or 0) * scale
        self:SetScript("OnUpdate", function()
            local cx = GetCursorPosition()
            local ui = UIParent:GetEffectiveScale()
            if not (cx and ui and ui > 0) then return end
            local new = math.max(0.5, math.min(1.5, (cx / ui - self.left) / GoldGoalUI.WIDTH))
            frame:SetScale(new)
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", self.left / new, self.top / new)
        end)
    end)
    grip:SetScript("OnMouseUp", function(self)
        if not self:GetScript("OnUpdate") then return end
        self:SetScript("OnUpdate", nil)
        ns.Config:Set("goldTrackerScale", math.floor((frame:GetScale() or 1) * 100 + 0.5))
        SavePlace(frame)
    end)
    grip:SetScript("OnEnter", function(self)
        Theme.SetBorderColor(self, "accent")
        if GameTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(L["Drag to change the size. Right-click for the normal size."], 1, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    grip:SetScript("OnLeave", function(self)
        Theme.SetBorderColor(self, "borderLit")
        if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
    return grip
end

--------------------------------------------------------------------------------
-- The bar
--------------------------------------------------------------------------------

--- A tenth's diamond: dark metal until reached, then bright gold and a
--- little bigger.
function GoldGoalUI.LightTick(tick, lit)
    local size = lit and GoldGoalUI.TICK_LIT or GoldGoalUI.TICK
    tick:SetSize(size, size)
    pcall(tick.SetDesaturated, tick, not lit)
    if lit then
        tick:SetVertexColor(1, 1, 1, 1)
    else
        tick:SetVertexColor(0.42, 0.42, 0.46, 0.9)
    end
    tick.lit = lit and true or false
end

function GoldGoalUI:Build()
    if self.frame then return self.frame end

    local frame = Theme.CreatePanel(UIParent, "window", "metal")
    frame:SetSize(self.WIDTH, self.HEIGHT)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePlace(self)
    end)
    frame:SetScript("OnEnter", function() GoldGoalUI:ShowCard() end)
    frame:SetScript("OnLeave", function() GoldGoalUI:HideCard() end)
    frame:SetScript("OnShow", function() GoldGoalUI:Refresh(true) end)
    Theme.TopSheen(frame, 0.06)
    Theme.Halo(frame, 6, 0.16)
    self.frame = frame

    -- The emblem: a gold coin in a gold ring, in a warm glow, with a glint
    -- that crosses it now and then.
    local ring = Theme.CreatePanel(frame, "well", "accent")
    ring:SetSize(34, 34)
    ring:SetPoint("TOPLEFT", PAD, -PAD)
    local coinGlow = frame:CreateTexture(nil, "BACKGROUND", nil, 4)
    coinGlow:SetPoint("CENTER", ring, "CENTER", 0, 0)
    coinGlow:SetSize(58, 58)
    coinGlow:SetTexture(GLOW)
    pcall(coinGlow.SetBlendMode, coinGlow, "ADD")
    coinGlow:SetVertexColor(Theme.Unpack("accent", 0.4))
    local emblem = ring:CreateTexture(nil, "ARTWORK")
    emblem:SetPoint("TOPLEFT", 2, -2)
    emblem:SetPoint("BOTTOMRIGHT", -2, 2)
    emblem:SetTexture(EMBLEM)
    emblem:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    self.emblem = ring

    local glintClip = CreateFrame("Frame", nil, ring)
    glintClip:SetPoint("TOPLEFT", 2, -2)
    glintClip:SetPoint("BOTTOMRIGHT", -2, 2)
    pcall(glintClip.SetClipsChildren, glintClip, true)
    local glint = glintClip:CreateTexture(nil, "OVERLAY")
    glint:SetTexture(GLOW)
    pcall(glint.SetBlendMode, glint, "ADD")
    glint:SetSize(12, 44)
    glint:SetPoint("CENTER", glintClip, "LEFT", -8, 0)
    glint:SetVertexColor(1, 0.97, 0.85, 1)
    glint:SetAlpha(0)
    self.glint = glint

    local title = Theme.CreateLabel(frame, "tiny", "accent")
    title:SetPoint("TOPLEFT", ring, "TOPRIGHT", 8, 0)
    title:SetText(L["Goblin Gold"])

    local total = Theme.CreateLabel(frame, 17, "text")
    pcall(total.SetFont, total, Theme.FONT, 17, "OUTLINE")
    total:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    self.total = total

    -- A light behind the total that flares while it counts up.
    local totalGlow = frame:CreateTexture(nil, "BACKGROUND", nil, 4)
    totalGlow:SetPoint("LEFT", total, "LEFT", -10, 0)
    totalGlow:SetSize(120, 30)
    totalGlow:SetTexture(GLOW)
    pcall(totalGlow.SetBlendMode, totalGlow, "ADD")
    totalGlow:SetVertexColor(Theme.Unpack("accentHi", 0.6))
    totalGlow:SetAlpha(0)
    self.totalGlow = totalGlow

    local todayValue = Theme.CreateLabel(frame, "small", "profit", "RIGHT")
    todayValue:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -PAD - 13)
    self.todayValue = todayValue

    local todayLabel = Theme.CreateLabel(frame, "tiny", "muted", "RIGHT")
    todayLabel:SetPoint("BOTTOMRIGHT", todayValue, "TOPRIGHT", 0, 2)
    todayLabel:SetText(L["Today"])

    -- A soft gold glow behind Today's number when it beats your best day:
    -- the house glow art, faded at every edge and kept inside the rim, not a
    -- flat box.
    local todayGlow = frame:CreateTexture(nil, "BACKGROUND", nil, 3)
    todayGlow:SetPoint("LEFT", todayValue, "LEFT", -12, 0)
    todayGlow:SetPoint("RIGHT", frame, "RIGHT", -4, 0)
    todayGlow:SetHeight(24)
    todayGlow:SetTexture(GLOW)
    pcall(todayGlow.SetBlendMode, todayGlow, "ADD")
    todayGlow:SetVertexColor(Theme.Unpack("accent", 0.35))
    todayGlow:Hide()
    self.todayGlow = todayGlow

    -- The bar: a dark well, a gold fill bright on top and deeper below with
    -- a light along its top, a gold gem at each end and a small diamond at
    -- each tenth.
    local track = Theme.CreatePanel(frame, "well", "border")
    track:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD + 12)
    track:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, PAD + 12)
    track:SetHeight(BAR_HEIGHT)
    self.track = track
    self.trackWidth = self.WIDTH - 2 * PAD

    local fill = track:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMLEFT", 1, 1)
    fill:SetWidth(1)
    fill:SetColorTexture(Theme.Unpack("accent"))
    Theme.SetGradientAlpha(fill, "VERTICAL", "accent", 0.7, 1)
    self.fill = fill

    -- The deeper gold along the bottom half.
    local depth = track:CreateTexture(nil, "ARTWORK", nil, 1)
    depth:SetPoint("BOTTOMLEFT", fill, "BOTTOMLEFT")
    depth:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT")
    depth:SetHeight(math.floor(BAR_HEIGHT / 2))
    self.depthOK = Theme.SetGradientAlpha(depth, "VERTICAL", "ink", 0.45, 0) and true or false
    depth:Hide()
    self.depth = depth

    local shine = track:CreateTexture(nil, "OVERLAY")
    shine:SetPoint("TOPLEFT", fill, "TOPLEFT")
    shine:SetPoint("TOPRIGHT", fill, "TOPRIGHT")
    shine:SetHeight(2)
    shine:SetColorTexture(Theme.Unpack("accentHi", 0.85))
    self.shine = shine

    -- The light that runs along the gold, kept inside it.
    local sweepClip = CreateFrame("Frame", nil, track)
    sweepClip:SetPoint("TOPLEFT", track, "TOPLEFT", 1, -1)
    sweepClip:SetPoint("BOTTOMLEFT", track, "BOTTOMLEFT", 1, 1)
    sweepClip:SetWidth(1)
    pcall(sweepClip.SetClipsChildren, sweepClip, true)
    local sweep = sweepClip:CreateTexture(nil, "OVERLAY", nil, 2)
    sweep:SetTexture(GLOW)
    pcall(sweep.SetBlendMode, sweep, "ADD")
    sweep:SetSize(self.SWEEP, BAR_HEIGHT * 2)
    sweep:SetPoint("CENTER", sweepClip, "LEFT", -self.SWEEP / 2, 0)
    sweep:SetVertexColor(1, 0.95, 0.8, 1)
    sweep:SetAlpha(0)
    self.sweepClip, self.sweep = sweepClip, sweep

    -- Sparkles that twinkle on the gold, inside it too.
    self.twinkles = {}
    for index = 1, #self.TWINKLES do
        local spark = sweepClip:CreateTexture(nil, "OVERLAY", nil, 3)
        spark:SetTexture(SPARKLE)
        pcall(spark.SetBlendMode, spark, "ADD")
        spark:SetSize(9, 9)
        spark:SetAlpha(0)
        self.twinkles[index] = spark
    end

    local glow = track:CreateTexture(nil, "OVERLAY", nil, 2)
    glow:SetPoint("TOPLEFT", -3, 3)
    glow:SetPoint("BOTTOMRIGHT", 3, -3)
    pcall(glow.SetBlendMode, glow, "ADD")
    glow:SetColorTexture(Theme.Unpack("accentHi", 0.35))
    glow:SetAlpha(0)
    self.barGlow = glow

    self.ticks = {}
    for step = 1, ns.GoldGoal.STEPS - 1 do
        local tick = track:CreateTexture(nil, "OVERLAY", nil, 4)
        tick:SetTexture(GEM)
        tick:SetSize(GoldGoalUI.TICK, GoldGoalUI.TICK)
        tick:SetPoint("CENTER", track, "LEFT", self.trackWidth * step / ns.GoldGoal.STEPS, 0)
        self.ticks[step] = tick
        GoldGoalUI.LightTick(tick, false)
    end

    -- A gold gem at each end, in a little glow.
    self.caps = {}
    -- Kept 6 pixels in from the window's edge and clear of the coin's ring.
    for index, side in ipairs({ "LEFT", "RIGHT" }) do
        local inset = side == "LEFT" and 2 or -2
        local capGlow = track:CreateTexture(nil, "OVERLAY", nil, 5)
        capGlow:SetTexture(GLOW)
        pcall(capGlow.SetBlendMode, capGlow, "ADD")
        capGlow:SetSize(24, 24)
        capGlow:SetPoint("CENTER", track, side, inset, 0)
        capGlow:SetVertexColor(Theme.Unpack("accentHi", 0.4))
        local cap = track:CreateTexture(nil, "OVERLAY", nil, 6)
        cap:SetTexture(GEM)
        cap:SetSize(12, 12)
        cap:SetPoint("CENTER", track, side, inset, 0)
        self.caps[index] = cap
    end

    -- The star at the end of the gold, breathing.
    local spark = track:CreateTexture(nil, "OVERLAY", nil, 7)
    spark:SetTexture(SPARKLE)
    pcall(spark.SetBlendMode, spark, "ADD")
    spark:SetSize(BAR_HEIGHT + 18, BAR_HEIGHT + 18)
    spark:SetVertexColor(1, 0.93, 0.72, 1)
    spark:SetPoint("CENTER", track, "LEFT", 1, 0)
    spark:Hide()
    self.spark = spark
    local sparkGlow = track:CreateTexture(nil, "OVERLAY", nil, 6)
    sparkGlow:SetTexture(GLOW)
    pcall(sparkGlow.SetBlendMode, sparkGlow, "ADD")
    sparkGlow:SetSize(BAR_HEIGHT * 2.6, BAR_HEIGHT * 2.6)
    sparkGlow:SetPoint("CENTER", spark, "CENTER", 0, 0)
    sparkGlow:SetVertexColor(1, 0.92, 0.65, 0.55)
    sparkGlow:Hide()
    self.sparkGlow = sparkGlow

    local share = Theme.CreateLabel(frame, "tiny", "muted")
    share:SetPoint("TOPLEFT", track, "BOTTOMLEFT", 0, -3)
    self.share = share

    local togo = Theme.CreateLabel(frame, "tiny", "muted", "RIGHT")
    togo:SetPoint("TOPRIGHT", track, "BOTTOMRIGHT", 0, -3)
    self.togo = togo

    -- The line that says a tenth was reached, above the bar.
    local cheer = Theme.CreateLabel(frame, "normal", "gilt", "CENTER")
    pcall(cheer.SetFont, cheer, Theme.FONT, Theme.sizes.normal, "OUTLINE")
    cheer:SetPoint("BOTTOM", frame, "TOP", 0, 6)
    cheer:SetAlpha(0)
    self.cheerLine = cheer

    self.grip = BuildGrip(frame)
    self.floats, self.coins = {}, {}
    self:MakeMotion()

    -- The dark glass that thins out while Transparent is on: the window, the
    -- coin's well and the bar's well, and the halo round the rim. The gold,
    -- the gems, the coin and the rim stay as they are.
    self.glass = { frame.background, ring.background, track.background }
    for _, halo in ipairs(frame.haloTextures or {}) do self.glass[#self.glass + 1] = halo end
    self:ApplySeeThrough()

    frame:Hide()
    self:Place()
    return frame
end

--------------------------------------------------------------------------------
-- Transparent
--------------------------------------------------------------------------------

-- Asked 2026-10-19, as Farmer's panels have it (its UI/SeeThrough.lua): the
-- bar's dark glass thins out so the world shows through, every word gets a
-- black shadow so it still reads, and the glass comes back while the mouse
-- is on the bar. Saved as goldTrackerSeeThrough, 0 (Off, the default) to 3;
-- never rename it. Only the bar's own textures are faded.

--- How much of the glass stays, by level: Some, More, Most.
GoldGoalUI.SEE_THROUGH = { 0.5, 0.3, 0.15 }
--- The words /bts gold transparent takes, by level from 0.
GoldGoalUI.SEE_THROUGH_WORDS = { [0] = "off", "some", "more", "most" }
--- How often the mouse is looked for, and how long the glass takes to change.
GoldGoalUI.SEE_THROUGH_LOOK = 0.1
GoldGoalUI.SEE_THROUGH_FADE = 0.2

--- The bar's level, 0 (off) to #SEE_THROUGH.
function GoldGoalUI.SeeThroughLevel()
    local level = tonumber(ns.Config and ns.Config:Get("goldTrackerSeeThrough"))
    if not level or not GoldGoalUI.SEE_THROUGH[level] then return 0 end
    return level
end

--- The levels' names as a player reads them, from 0 (off).
function GoldGoalUI.SeeThroughNames()
    return { [0] = L["Off"], L["Some"], L["More"], L["Most"] }
end

-- The shadow each word had before, so turning it off puts that back.
local shadowBefore = setmetatable({}, { __mode = "k" })

local function ShadeText(region, on)
    if type(region) ~= "table" or type(region.GetObjectType) ~= "function" then return end
    local ok, kind = pcall(region.GetObjectType, region)
    if not ok or kind ~= "FontString" then return end
    if on then
        if not shadowBefore[region] then
            local okOffset, x, y = pcall(region.GetShadowOffset, region)
            local okColor, r, g, b, a = pcall(region.GetShadowColor, region)
            shadowBefore[region] = {
                x = okOffset and tonumber(x) or 0, y = okOffset and tonumber(y) or 0,
                r = okColor and tonumber(r) or 0, g = okColor and tonumber(g) or 0,
                b = okColor and tonumber(b) or 0, a = okColor and tonumber(a) or 1,
            }
        end
        pcall(region.SetShadowColor, region, 0, 0, 0, 1)
        pcall(region.SetShadowOffset, region, 1, -1)
    else
        local was = shadowBefore[region]
        if not was then return end
        shadowBefore[region] = nil
        pcall(region.SetShadowColor, region, was.r, was.g, was.b, was.a)
        pcall(region.SetShadowOffset, region, was.x, was.y)
    end
end

--- A black shadow under every word on `frame` and the frames inside it.
function GoldGoalUI.ShadeAll(frame, on)
    if type(frame) ~= "table" then return end
    if type(frame.GetRegions) == "function" then
        local regions = { pcall(frame.GetRegions, frame) }
        for i = 2, #regions do ShadeText(regions[i], on) end
    end
    if type(frame.GetChildren) == "function" then
        local children = { pcall(frame.GetChildren, frame) }
        for i = 2, #children do GoldGoalUI.ShadeAll(children[i], on) end
    end
end

--- Every piece of the glass at `shown` (1 is the usual dark glass).
function GoldGoalUI:SetGlass(shown)
    self.glassShown = shown
    for _, texture in ipairs(self.glass or {}) do
        pcall(texture.SetAlpha, texture, shown)
    end
end

local function MouseOn(frame)
    if not frame or type(frame.IsMouseOver) ~= "function" then return false end
    local ok, over = pcall(frame.IsMouseOver, frame)
    return ok and over == true
end

--- Put the bar in step with its setting: the glass, the shadows and the
--- watcher that brings the glass back under the mouse. The watcher runs
--- only while the bar shows and Transparent is on.
function GoldGoalUI:ApplySeeThrough()
    local frame = self.frame
    if not frame then return end
    local level = GoldGoalUI.SeeThroughLevel()
    local on = level > 0
    GoldGoalUI.ShadeAll(frame, on)

    if not on then
        if self.seeWatch then self.seeWatch:SetScript("OnUpdate", nil) end
        self:SetGlass(1)
        return
    end

    local clear = GoldGoalUI.SEE_THROUGH[level]
    self:SetGlass(MouseOn(frame) and 1 or clear)
    if not self.seeWatch then self.seeWatch = CreateFrame("Frame", nil, frame) end
    local wait = 0
    self.seeWatch:SetScript("OnUpdate", function(_, elapsed)
        elapsed = tonumber(elapsed) or 0
        wait = wait - elapsed
        if wait <= 0 then
            wait = GoldGoalUI.SEE_THROUGH_LOOK
            self.glassTarget = MouseOn(frame) and 1 or clear
        end
        local target = self.glassTarget or clear
        local shown = self.glassShown or 1
        if shown == target then return end
        if Level() == "off" then
            self:SetGlass(target)
            return
        end
        local step = elapsed / GoldGoalUI.SEE_THROUGH_FADE
        if shown < target then
            self:SetGlass(math.min(target, shown + step))
        else
            self:SetGlass(math.max(target, shown - step))
        end
    end)
end

--- Set the bar's level, 0 (off) to #SEE_THROUGH. False for a level it lacks.
function GoldGoalUI:SetSeeThrough(level)
    level = tonumber(level)
    if not level or (level ~= 0 and not GoldGoalUI.SEE_THROUGH[level]) then return false end
    ns.Config:Set("goldTrackerSeeThrough", level)
    self.glassTarget = nil
    self:ApplySeeThrough()
    return true
end

--- Show or hide the bar as the setting says.
function GoldGoalUI:Apply()
    local on = ns.GoldGoal and ns.GoldGoal:IsOn()
    if not on then
        if self.frame then self.frame:Hide() end
        self:HideCard()
        return
    end
    self:Build()
    self:Place()
    self.frame:Show()
end

local function FillWidth(self, total, goal)
    if not (goal and goal > 0) then return 0 end
    return math.max(0, math.min(1, total / goal)) * (self.trackWidth - 2)
end

local function DrawTotal(self, total, goal)
    self.total:SetText(Money(total))
    local width = FillWidth(self, total, goal)
    local shown = width >= 1
    self.fill:SetWidth(math.max(1, width))
    self.fill:SetShown(shown)
    self.shine:SetShown(shown)
    if self.depth then self.depth:SetShown(shown and self.depthOK ~= false) end

    -- The star sits on the end of the gold.
    self.spark:ClearAllPoints()
    self.spark:SetPoint("CENTER", self.track, "LEFT", 1 + width, 0)
    self.spark:SetShown(shown)
    self.sparkGlow:SetShown(shown)
    self:FitSweep(width)
end

--- Draw what moved. `force` draws even when nothing did.
function GoldGoalUI:Refresh(force)
    local frame = self.frame
    if not (frame and frame:IsShown()) then return end

    local GoldGoal = ns.GoldGoal
    local now = time()
    local key = GoldGoal.version .. ":" .. tostring(ns.GoldLog and ns.GoldLog.DayKey and ns.GoldLog.DayKey(now))
    if key == self.drawnKey and not force then return end
    self.drawnKey = key

    local total = GoldGoal:Total(now)
    local goal = GoldGoal:Goal()
    local record = GoldGoal:Record(false)
    local step = GoldGoal.Step(total, goal)

    if Level() ~= self.motionLevel then self:ApplyMotion() end

    -- The total counts up from what was shown, and the fill with it. On
    -- Full it starts bright and settles back to its own colour.
    local from = self.shownTotal
    self.shownTotal = total
    local motion = Motion()
    local level = Level()
    if from and from ~= total and motion and level ~= "off" then
        local flash = level == "full" and total > from
        local tr, tg, tb = Theme.Unpack("text")
        local hr, hg, hb = Theme.Unpack("accentHi")
        motion:Run(self, "count", 0.8, function(p)
            DrawTotal(self, from + (total - from) * p, goal)
            if flash then
                local q = math.min(1, p * 1.25)
                self.total:SetTextColor(hr + (tr - hr) * q, hg + (tg - hg) * q, hb + (tb - hb) * q)
                self.totalGlow:SetAlpha(1 - q)
            end
        end, { done = function()
            self.total:SetTextColor(tr, tg, tb)
            self.totalGlow:SetAlpha(0)
        end })
    else
        if motion then motion:Stop(self, "count") end
        DrawTotal(self, total, goal)
        self.total:SetTextColor(Theme.Unpack("text"))
        self.totalGlow:SetAlpha(0)
    end

    -- The tenths reached light up.
    for index, tick in ipairs(self.ticks) do
        local lit = (goal and index <= step) and true or false
        if tick.lit ~= lit then GoldGoalUI.LightTick(tick, lit) end
    end

    -- Today, glowing past your best day.
    local today = GoldGoal:Today()
    if today then
        self.todayValue:SetText((today > 0 and "+" or "") .. Money(today, 1))
        self.todayValue:SetTextColor(Theme.Unpack(today >= 0 and "profit" or "loss"))
    else
        self.todayValue:SetText("")
    end
    local best = GoldGoal:BestDay(now)
    local beats = today and best and best > 0 and today > best
    self.todayGlow:SetShown(beats and true or false)
    if beats then self.todayValue:SetTextColor(Theme.Unpack("accentHi")) end
    self:PulseToday(beats)

    if goal then
        local percent = math.floor(math.min(1, total / goal) * 100)
        self.share:SetText(L.Format("%d%% of %s", percent, Money(goal, 1)))
        if total >= goal then
            self.togo:SetText(L["Goal reached!"])
            self.togo:SetTextColor(Theme.Unpack("accentHi"))
        else
            self.togo:SetText(L.Format("%s to go", Money(goal - total, 1)))
            self.togo:SetTextColor(Theme.Unpack("muted"))
        end
        self.track:Show()
    else
        self.share:SetText(L["No goal yet. Set one in Settings."])
        self.togo:SetText("")
        self.track:Show()
    end

    if self.card and self.card:IsShown() then self:ShowCard() end
    return record
end

--------------------------------------------------------------------------------
-- Motion: the star's breath, the light along the gold, the sparkles, the
-- coin's glint and Today's pulse
--------------------------------------------------------------------------------

-- All of them are animations the game plays, so nothing here runs a frame
-- at a time; they are set again only when Window effects or the gold's
-- width moves.

local function Group(region, looping)
    if not region then return nil end
    local ok, group = pcall(region.CreateAnimationGroup, region)
    if not ok or type(group) ~= "table" then return nil end
    pcall(group.SetLooping, group, looping)
    return group
end

local function Anim(group, kind)
    if not group then return nil end
    local ok, anim = pcall(group.CreateAnimation, group, kind)
    if ok and type(anim) == "table" then return anim end
    return nil
end

local function Stop(group)
    if group then pcall(group.Stop, group) end
end

local function Play(group)
    if group then pcall(group.Play, group) end
end

local function SetAlphaAnim(anim, from, to, seconds, order, delay)
    if not anim then return end
    anim:SetFromAlpha(from)
    anim:SetToAlpha(to)
    anim:SetDuration(seconds)
    if order then anim:SetOrder(order) end
    if delay then anim:SetStartDelay(delay) end
    anim:SetSmoothing("IN_OUT")
end

function GoldGoalUI:MakeMotion()
    local breath = Group(self.spark, "BOUNCE")
    self.breath = breath
    self.breathScale = Anim(breath, "Scale")
    self.breathDim = Anim(breath, "Alpha")

    local glow = Group(self.sparkGlow, "BOUNCE")
    self.glowBreath = glow
    self.glowDim = Anim(glow, "Alpha")

    local sweep = Group(self.sweep, "REPEAT")
    self.sweepGroup = sweep
    self.sweepMove = Anim(sweep, "Translation")
    self.sweepLight = Anim(sweep, "Alpha")
    self.sweepWidth = 0

    -- Each sparkle flashes in and out, then waits, each at its own time.
    self.twinkleGroups = {}
    for index, spark in ipairs(self.twinkles) do
        local group = Group(spark, "REPEAT")
        if group then
            pcall(function()
                local rise = Anim(group, "Alpha")
                SetAlphaAnim(rise, 0, 1, 0.35, 1, 0.55 * index)
                local fall = Anim(group, "Alpha")
                SetAlphaAnim(fall, 1, 0, 0.45, 2)
                fall:SetEndDelay(1.6)
                local grow = Anim(group, "Scale")
                if grow.SetScaleFrom then
                    grow:SetScaleFrom(0.4, 0.4)
                    grow:SetScaleTo(1, 1)
                else
                    grow:SetScale(2.5, 2.5)
                end
                grow:SetDuration(0.35)
                grow:SetOrder(1)
                grow:SetStartDelay(0.55 * index)
            end)
            self.twinkleGroups[index] = group
        end
    end

    -- The glint crosses the coin, then rests a few seconds.
    local glint = Group(self.glint, "REPEAT")
    if glint then
        pcall(function()
            local move = Anim(glint, "Translation")
            move:SetOffset(46, 0)
            move:SetDuration(0.7)
            move:SetOrder(1)
            move:SetStartDelay(1)
            move:SetEndDelay(4)
            local light = Anim(glint, "Alpha")
            light:SetFromAlpha(0.8)
            light:SetToAlpha(0.8)
            light:SetDuration(0.7)
            light:SetOrder(1)
            light:SetStartDelay(1)
        end)
        self.glintGroup = glint
    end

    -- Today's glow breathing while it beats your best day.
    local pulse = Group(self.todayGlow, "BOUNCE")
    if pulse then
        pcall(SetAlphaAnim, Anim(pulse, "Alpha"), 1, 0.4, 1.1)
        self.todayPulse = pulse
    end
end

--- Sets every motion for Window effects: Full, Subtle or none.
function GoldGoalUI:ApplyMotion()
    local level = Level()
    self.motionLevel = level
    local spec = self.MOTION[level]

    Stop(self.breath)
    Stop(self.glowBreath)
    Stop(self.sweepGroup)
    Stop(self.glintGroup)
    for _, group in pairs(self.twinkleGroups or {}) do Stop(group) end
    if self.sweep then self.sweep:SetAlpha(0) end
    if self.glint then self.glint:SetAlpha(0) end
    for _, spark in ipairs(self.twinkles or {}) do spark:SetAlpha(0) end

    if spec then
        pcall(function()
            local scale = self.breathScale
            if scale then
                if scale.SetScaleFrom then
                    scale:SetScaleFrom(1, 1)
                    scale:SetScaleTo(spec.grow, spec.grow)
                else
                    scale:SetScale(spec.grow, spec.grow)
                end
                scale:SetDuration(spec.breath)
                scale:SetSmoothing("IN_OUT")
            end
            SetAlphaAnim(self.breathDim, 1, spec.dim, spec.breath)
            SetAlphaAnim(self.glowDim, 1, 0.35, spec.breath)
        end)
        Play(self.breath)
        Play(self.glowBreath)
        if spec.glint then Play(self.glintGroup) end
    end

    self:FitSweep(self.sweepWidth or 0, true)
    self:PulseToday(self.pulsing)
end

--- The light runs the gold's width at an even pace, then rests, and the
--- sparkles sit along it. Set again only when the width moves by 2 or more.
function GoldGoalUI:FitSweep(width, force)
    width = math.floor(tonumber(width) or 0)
    if not self.sweepClip then return end
    if not force and math.abs(width - (self.sweepWidth or 0)) < 2 then return end
    self.sweepWidth = width
    self.sweepClip:SetWidth(math.max(1, width))

    local spec = self.MOTION[self.motionLevel or Level()]

    -- The sparkles: only on Full, and only on gold wide enough to hold them.
    for index, spark in ipairs(self.twinkles or {}) do
        local x = math.floor(width * self.TWINKLES[index])
        local fits = spec and spec.twinkle and x >= 6 and x <= width - 8
        spark:ClearAllPoints()
        spark:SetPoint("CENTER", self.sweepClip, "LEFT", x, index % 2 == 0 and -2 or 2)
        local group = self.twinkleGroups and self.twinkleGroups[index]
        if fits then
            if not (group and group.IsPlaying and select(2, pcall(group.IsPlaying, group)) == true) then
                Play(group)
            end
        else
            Stop(group)
            spark:SetAlpha(0)
        end
    end

    if not (spec and self.sweepGroup and self.sweepMove) or width < self.SWEEP then
        Stop(self.sweepGroup)
        if self.sweep then self.sweep:SetAlpha(0) end
        return
    end
    local travel = width + self.SWEEP
    local seconds = travel / spec.speed
    pcall(function()
        local move = self.sweepMove
        move:SetOffset(travel, 0)
        move:SetDuration(seconds)
        move:SetOrder(1)
        local light = self.sweepLight
        if light then
            light:SetFromAlpha(spec.light)
            light:SetToAlpha(spec.light)
            light:SetDuration(seconds)
            light:SetOrder(1)
        end
        -- The rest: the light waits out of sight before the next run.
        move:SetEndDelay(spec.rest)
    end)
    Stop(self.sweepGroup)
    Play(self.sweepGroup)
end

--- Today's glow breathes while it beats your best day, on Full only;
--- otherwise it stays still.
function GoldGoalUI:PulseToday(on)
    on = on and true or false
    local spec = self.MOTION[self.motionLevel or Level()]
    local play = on and spec and spec.pulse
    if play == self.pulsePlaying and on == self.pulsing then return end
    self.pulsing = on
    self.pulsePlaying = play
    if play then Play(self.todayPulse) else Stop(self.todayPulse) end
end

--------------------------------------------------------------------------------
-- Rewards
--------------------------------------------------------------------------------

--- Where the fill ends, from the bar's left edge.
local function TipX(self)
    local goal = ns.GoldGoal:Goal()
    local width = FillWidth(self, self.shownTotal or 0, goal)
    return math.max(8, math.min(self.trackWidth - 8, width))
end

--- New gold rising off the end of the fill and fading.
function GoldGoalUI:Float(amount)
    local frame = self.frame
    if not (frame and frame:IsShown()) or Level() ~= "full" then return end

    local label
    for _, candidate in ipairs(self.floats) do
        if not candidate.busy then label = candidate break end
    end
    if not label then
        if #self.floats >= 6 then return end
        label = Theme.CreateLabel(frame, "small", "gilt", "CENTER")
        pcall(label.SetFont, label, Theme.FONT, Theme.sizes.small, "OUTLINE")
        self.floats[#self.floats + 1] = label
    end

    label.busy = true
    label:SetText("+" .. Money(amount, 1))
    local x = TipX(self)
    ns.Motion:Run(label, "float", 1.4, function(p)
        label:ClearAllPoints()
        label:SetPoint("BOTTOM", self.track, "TOPLEFT", x, 4 + 26 * p)
        label:SetAlpha(1 - p * p)
    end, { done = function()
        label:SetAlpha(0)
        label.busy = false
    end, ease = false })
end

--- A handful of coins bursting from a point on the bar.
local function Burst(self, x, count)
    if Level() ~= "full" then return end
    for index = 1, count do
        local coin = self.coins[index]
        if not coin then
            coin = self.frame:CreateTexture(nil, "OVERLAY", nil, 5)
            coin:SetSize(10, 10)
            coin:SetTexture(COIN)
            coin:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            coin:SetAlpha(0)
            self.coins[index] = coin
        end
        local angle = math.pi * (0.15 + 0.7 * (index - 1) / math.max(1, count - 1))
        local reach = 26 + (index % 3) * 8
        local dx, dy = math.cos(angle) * reach, math.sin(angle) * reach
        ns.Motion:Run(coin, "burst", 0.9, function(p)
            coin:ClearAllPoints()
            -- Out and up, then falling a little as it fades.
            coin:SetPoint("CENTER", self.track, "LEFT", x + dx * p, dy * p - 18 * p * p)
            coin:SetAlpha(p < 0.6 and 1 or (1 - p) / 0.4)
        end, { done = function() coin:SetAlpha(0) end, delay = (index % 4) * 0.03 })
    end
end

--- The bar flares and the line above it says how far you are.
local function StepCheer(self, cheer)
    local x = self.trackWidth * cheer.step / ns.GoldGoal.STEPS
    Burst(self, x, 8)

    self.cheerLine:SetText(L.Format("%d%% there!", math.floor(cheer.step * 100 / ns.GoldGoal.STEPS + 0.5)))
    local motion = ns.Motion
    motion:Run(self.cheerLine, "cheer", 3, function(p)
        self.cheerLine:SetAlpha(p < 0.1 and p * 10 or p > 0.75 and (1 - p) * 4 or 1)
    end, { ease = false })
    motion:Run(self.barGlow, "flare", 1.2, function(p)
        self.barGlow:SetAlpha(math.sin(p * math.pi))
    end, { ease = false })
    motion:Run(self.frame, "halo", 1.2, function(p)
        Theme.SetHalo(self.frame, 0.10 + 0.35 * math.sin(p * math.pi))
    end, { ease = false })

    local tick = self.ticks[cheer.step]
    if tick then
        motion:Run(tick, "pop", 0.6, function(p)
            local size = GoldGoalUI.TICK_LIT + 8 * math.sin(p * math.pi)
            tick:SetSize(size, size)
        end, { ease = false })
    end
end

--- A cheer from Logic/GoldGoal.lua.
function GoldGoalUI:Cheer(cheer)
    if not cheer then return end
    self:Apply()
    if not (self.frame and self.frame:IsShown()) then return end
    self:Refresh(true)

    if cheer.kind == "goal" then
        GoldGoalUI.Play("goal")
        Burst(self, self.trackWidth - 8, 12)
        self:ShowGoalWindow(cheer)
    else
        GoldGoalUI.Play("step")
        StepCheer(self, cheer)
    end
end

--------------------------------------------------------------------------------
-- Words
--------------------------------------------------------------------------------

--- "Took 11 days", "Took 3 hours", "Took under an hour".
function GoldGoalUI.TookText(seconds)
    seconds = tonumber(seconds)
    if not seconds then return nil end
    local days = math.floor(seconds / 86400)
    if days >= 2 then return L.Format("Took %d days", days) end
    if days == 1 then return L["Took 1 day"] end
    local hours = math.floor(seconds / 3600)
    if hours >= 2 then return L.Format("Took %d hours", hours) end
    if hours == 1 then return L["Took 1 hour"] end
    return L["Took under an hour"]
end

--- "Tuesday, 612g" for a day this week, "612g, 12 days ago" before it.
function GoldGoalUI.BestDayText(net, day, now)
    if not (net and day and ns.GoldLog and ns.GoldLog.KeyStart) then return nil end
    now = now or time()
    local start = ns.GoldLog.KeyStart(day)
    local ago = math.floor((ns.GoldLog.DayStart(now) - start) / 86400 + 0.5)
    if ago <= 6 then
        local weekday = WEEKDAYS[tonumber(date("%w", start))] or ""
        return L.Format("%s, %s", weekday, Money(net, 1))
    end
    return L.Format("%s, %d days ago", Money(net, 1), ago)
end

--------------------------------------------------------------------------------
-- The hover card
--------------------------------------------------------------------------------

local CARD_ROW = 20

local function CardRow(card, index)
    local row = card.rows[index]
    if row then return row end

    row = CreateFrame("Frame", nil, card)
    row:SetHeight(CARD_ROW)
    row.band = row:CreateTexture(nil, "BACKGROUND")
    row.band:SetAllPoints(row)
    row.line = row:CreateTexture(nil, "BORDER")
    row.line:SetPoint("BOTTOMLEFT", 0, 0)
    row.line:SetPoint("BOTTOMRIGHT", 0, 0)
    row.line:SetHeight(1)
    row.line:SetColorTexture(Theme.Unpack("border", 0.6))
    row.chip = row:CreateTexture(nil, "ARTWORK")
    row.chip:SetSize(9, 9)
    row.chip:SetPoint("LEFT", 8, 0)
    row.chip:Hide()
    row.left = Theme.CreateLabel(row, "small", "text")
    row.left:SetPoint("LEFT", 8, 0)
    row.note = Theme.CreateLabel(row, "tiny", "muted")
    row.note:SetPoint("LEFT", row.left, "RIGHT", 6, 0)
    row.right = Theme.CreateLabel(row, "small", "text", "RIGHT")
    row.right:SetPoint("RIGHT", -8, 0)
    card.rows[index] = row
    return row
end

local function Width(label)
    return Theme.TextWidth(label) or 0
end

local function SourceColor(key)
    local source = ns.GoldLog and ns.GoldLog.GetSource and ns.GoldLog:GetSource(key)
    return source and source.color
end

-- A whole count with its thousands grouped, the game's way when it can.
function GoldGoalUI.Count(n)
    n = math.floor(tonumber(n) or 0)
    if type(BreakUpLargeNumbers) == "function" then
        local ok, text = pcall(BreakUpLargeNumbers, n)
        if ok and type(text) == "string" then return text end
    end
    local text = tostring(n)
    local grouped
    repeat
        text, grouped = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    until grouped == 0
    return text
end

local function Muted(text)
    return "|c" .. (ns.COLORS and ns.COLORS.muted or "ff9a9a9a") .. text .. "|r"
end

--- Where this week's gold came from, and the game's all-time numbers,
--- added to the card's lines (asked 2026-10-20, from a mockup).
function GoldGoalUI.SourceLines(lines, sources)
    if type(sources) ~= "table" then return lines end
    local week = {}

    local quests = sources.quests
    if quests and ((quests.gold or 0) > 0 or (quests.count or 0) > 0) then
        local right = Money(quests.gold or 0, 2)
        if (quests.count or 0) > 0 and (quests.gold or 0) > 0 then
            right = right .. "  " .. Muted(L.Format("%s each", Money(math.floor(quests.gold / quests.count + 0.5), 2)))
        end
        week[#week + 1] = { left = L["Quests"], chip = SourceColor("quests"),
            note = (quests.count or 0) > 0 and L.Format("%d done", quests.count) or nil, right = right }
    end

    local mobs = sources.mobs
    local mobGold = mobs and mobs.gold or sources.lootGold or 0
    if (mobs and (mobs.kills or 0) > 0) or mobGold > 0 then
        local right = Money(mobGold, 2)
        local kills = mobs and mobs.kills or 0
        if kills > 0 and mobGold + (mobs.loot or 0) > 0 then
            right = right .. "  " .. Muted(L.Format("%s each",
                Money(math.floor((mobGold + (mobs.loot or 0)) / kills + 0.5), 2)))
        end
        week[#week + 1] = { left = L["Mobs"], chip = SourceColor("loot"),
            note = kills > 0 and L.Format("%d killed", kills) or nil, right = right }
        if mobs and (mobs.loot or 0) > 0 then
            week[#week + 1] = { left = L["Their loot is worth"],
                right = L.Format("%s more", Money(mobs.loot, 2)) }
        end
    end

    for _, key in ipairs({ "auctionSales", "vendorSales" }) do
        if (sources[key] or 0) > 0 then
            local source = ns.GoldLog:GetSource(key)
            week[#week + 1] = { left = source.text, chip = source.color, right = Money(sources[key], 2) }
        end
    end

    if week[1] then
        lines[#lines + 1] = { left = L["THIS WEEK"], heading = true }
        for _, line in ipairs(week) do lines[#lines + 1] = line end
    end

    local allTime = sources.allTime or {}
    local always = {}
    if allTime.quests then always[#always + 1] = { left = L["Quests done"], right = GoldGoalUI.Count(allTime.quests) } end
    if allTime.kills then always[#always + 1] = { left = L["Mobs killed"], right = GoldGoalUI.Count(allTime.kills) } end
    if allTime.questGold then always[#always + 1] = { left = L["Gold from quests"], right = Money(allTime.questGold, 2) } end
    if allTime.looted then always[#always + 1] = { left = L["Gold looted"], right = Money(allTime.looted, 2) } end
    if always[1] then
        lines[#lines + 1] = { left = L["ALL TIME"], heading = true }
        for _, line in ipairs(always) do lines[#lines + 1] = line end
    end
    return lines
end

--- The card under the bar: every character counted, then the week, the
--- best day and how long to the goal.
function GoldGoalUI:ShowCard()
    local frame = self.frame
    if not (frame and frame:IsShown()) then return end

    local card = self.card
    if not card then
        card = Theme.CreatePanel(frame, "glassAlt", "metal")
        card:SetFrameStrata("TOOLTIP")
        card.rows = {}
        self.card = card
    end

    local GoldGoal = ns.GoldGoal
    local now = time()
    local members = GoldGoal:Members(now)
    local total = 0
    for _, member in ipairs(members) do total = total + member.gold end
    local goal = GoldGoal:Goal()

    local lines = {}
    for _, member in ipairs(members) do
        local note
        if member.isCurrent then
            note = L["Playing now"]
        elseif member.at then
            note = L.Format("Seen %s", Util.FormatAgeAgo(math.max(0, now - member.at)))
        end
        lines[#lines + 1] = { left = member.name, note = note,
            right = member.known and Money(member.gold, 2) or "--" }
    end

    lines[#lines + 1] = { left = members[2] and L.Format("All %d", #members) or L["All"],
        right = Money(total, 2), strong = true }

    local week = GoldGoal:Week()
    if week then
        lines[#lines + 1] = { left = L["This week"],
            right = (week > 0 and "+" or "") .. Money(week, 1), color = week >= 0 and "profit" or "loss" }
    end
    local bestText = GoldGoalUI.BestDayText(GoldGoal:BestDay(now))
    if bestText then lines[#lines + 1] = { left = L["Best day"], right = bestText } end
    if goal and total < goal then
        local days = GoldGoal:DaysToGo(total, goal)
        if days then
            lines[#lines + 1] = { left = L["At this week's pace"],
                right = days == 1 and L["about 1 day to go"] or L.Format("about %d days to go", days) }
        end
    end

    GoldGoalUI.SourceLines(lines, GoldGoal:Sources(now))

    -- Wide enough for its longest line, measured, so nothing is cut short.
    local width = 220
    for index, line in ipairs(lines) do
        local row = CardRow(card, index)
        row.left:SetText(line.left)
        row.left:SetTextColor(Theme.Unpack(line.heading and "accent" or line.strong and "accentHi" or "text"))
        row.left:ClearAllPoints()
        if line.chip then
            row.chip:SetColorTexture(line.chip[1], line.chip[2], line.chip[3], 1)
            row.chip:Show()
            row.left:SetPoint("LEFT", 21, 0)
        else
            row.chip:Hide()
            row.left:SetPoint("LEFT", 8, 0)
        end
        row.note:SetText(line.note or "")
        row.right:SetText(line.right or "")
        row.right:SetTextColor(Theme.Unpack(line.color or (line.strong and "accentHi" or "text")))
        local need = 16 + (line.chip and 13 or 0) + Width(row.left) + (line.note and 6 + Width(row.note) or 0) + 18 + Width(row.right)
        width = math.max(width, math.ceil(need))
    end

    for index, line in ipairs(lines) do
        local row = card.rows[index]
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1 - (index - 1) * CARD_ROW)
        row:SetWidth(width)
        row.band:SetColorTexture(Theme.Unpack(index % 2 == 1 and "glass" or "glassAlt"))
        row:Show()
    end
    for index = #lines + 1, #card.rows do card.rows[index]:Hide() end

    card:SetSize(width + 2, #lines * CARD_ROW + 2)
    card:ClearAllPoints()
    local below = (frame:GetBottom() or 0) * (frame:GetEffectiveScale() or 1) > 240
    if below then
        card:SetPoint("TOP", frame, "BOTTOM", 0, -20)
    else
        card:SetPoint("BOTTOM", frame, "TOP", 0, 24)
    end
    card:Show()
end

function GoldGoalUI:HideCard()
    if self.card then self.card:Hide() end
end

--------------------------------------------------------------------------------
-- The goal reached
--------------------------------------------------------------------------------

local function BuildGoalWindow()
    -- The house frame: gold rim, the Tradeskills plate and the red close
    -- gem. Without it, the old accent border and sheen.
    local titan = ns.Titanforged
    local window = Theme.CreatePanel(UIParent, "window", not titan and "accent" or false)
    window:SetSize(300, titan and 224 or 210)
    window:SetFrameStrata("DIALOG")
    window:SetPoint("TOP", UIParent, "TOP", 0, -150)
    window:EnableMouse(true)
    window:SetMovable(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    if titan then
        titan:Dress(window, { title = L["Tradeskills"], close = function() window:Hide() end })
    else
        Theme.TopSheen(window, 0.08)
    end
    Theme.Halo(window, 10, 0.30)

    _G.BlackthornesTSGoldGoalReached = window
    if type(UISpecialFrames) == "table" and type(tinsert) == "function" then
        tinsert(UISpecialFrames, "BlackthornesTSGoldGoalReached")
    end

    window.title = Theme.CreateLabel(window, 20, "gilt", "CENTER")
    pcall(window.title.SetFont, window.title, Theme.FONT, 20, "OUTLINE")
    window.title:SetPoint("TOP", 0, titan and -28 or -16)
    window.title:SetText(L["Goal reached!"])

    window.amount = Theme.CreateLabel(window, "large", "text", "CENTER")
    window.amount:SetPoint("TOP", window.title, "BOTTOM", 0, -6)

    window.lines = {}
    for index = 1, 3 do
        local line = Theme.CreateLabel(window, "small", "muted", "CENTER")
        line:SetPoint("TOP", window.amount, "BOTTOM", 0, -8 - (index - 1) * 16)
        window.lines[index] = line
    end

    local nextLabel = Theme.CreateLabel(window, "small", "text")
    nextLabel:SetText(L["Next Goal:"])

    window.box = Widgets.CreateNumberBox(window, { width = 80, min = 1, max = 99999999 })
    local unit = Theme.CreateLabel(window, "small", "muted")
    unit:SetText("g")

    -- Lined up across the middle, measured.
    local rowWidth = Width(nextLabel) + 6 + 80 + 4 + Width(unit)
    nextLabel:SetPoint("BOTTOMLEFT", window, "BOTTOM", -rowWidth / 2, 50)
    window.box:SetPoint("LEFT", nextLabel, "RIGHT", 6, 0)
    unit:SetPoint("LEFT", window.box, "RIGHT", 4, 0)

    window.set = Widgets.CreateButton(window, L["Set"], function()
        local gold = window.box:GetValue()
        if gold and gold > 0 then ns.GoldGoal:SetGoalGold(gold) end
        window:Hide()
    end, { width = 90, height = 22, primary = true })
    window.done = Widgets.CreateButton(window, L["Done"], function() window:Hide() end,
        { width = 90, height = 22 })
    window.set:SetPoint("BOTTOMRIGHT", window, "BOTTOM", -4, 14)
    window.done:SetPoint("BOTTOMLEFT", window, "BOTTOM", 4, 14)

    window:Hide()
    return window
end

function GoldGoalUI:ShowGoalWindow(cheer)
    local window = self.goalWindow or BuildGoalWindow()
    self.goalWindow = window

    local GoldGoal = ns.GoldGoal
    window.amount:SetText(Money(cheer.goal, 1))

    local texts = {}
    texts[#texts + 1] = GoldGoalUI.TookText(cheer.took)
    local bestText = GoldGoalUI.BestDayText(GoldGoal:BestDay())
    if bestText then texts[#texts + 1] = L.Format("Best day: %s", bestText) end
    local from = GoldGoal:MostlyFrom()
    if from then texts[#texts + 1] = L.Format("Mostly from %s", from) end
    for index, line in ipairs(window.lines) do line:SetText(texts[index] or "") end

    local suggest = GoldGoal.NextGoal(GoldGoal:Total())
    window.box:SetValue(math.floor(suggest / COPPER_PER_GOLD))
    window:Show()

    local motion = ns.Motion
    if motion and Level() == "full" then
        motion:Run(window, "rise", 0.5, function(p)
            window:SetAlpha(p)
            pcall(window.SetScale, window, 0.9 + 0.1 * (ns.Motion.EaseOutBack and ns.Motion.EaseOutBack(p) or p))
        end, { ease = false })
    end
end
