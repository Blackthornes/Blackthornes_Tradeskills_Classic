-- Sale Total (a player asked, the owner said build it from a mockup,
-- 2026-10-28): a gold plaque on top of the auction house drawer with what
-- the Sell list could sell for. When a scan finishes it counts the total
-- up from nothing, item by item, with a "+3g 20s" floating off for each,
-- a shine and sparks when one item adds a lot, and a small cheer at the
-- end saying how far it moved since the last scan. Off unless ticked
-- (`saleTotal`, the Auction house page, never rename it).
--
-- Smooth play: it only adds up the Sell list's own totals (PostPanel:Refresh
-- hands them over), and its OnUpdate runs only while something moves.
-- Effects Subtle keeps the count but drops the shine, sparks and floats;
-- Off shows the number at once.

local ADDON, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local SaleTotal = ns.NewModule("SaleTotal")

-- How long the count after a scan takes, however long the list.
SaleTotal.PLAY = 2.5
-- The longest one item's step may take, for a short list.
SaleTotal.STEP_MOST = 0.4
-- One item adding this share of the total, and at least BIG_LEAST copper,
-- shines.
SaleTotal.BIG = 0.10
SaleTotal.BIG_LEAST = 10000
-- How fast the shown number closes on the one it rolls to.
SaleTotal.ROLL = 9
-- How long a float, the shine and the end glow last.
SaleTotal.FLOAT_FOR = 1.1
SaleTotal.SHINE_FOR = 0.7
SaleTotal.GLOW_FOR = 2.5
SaleTotal.WIDTH = 344
SaleTotal.HEIGHT = 62

local MEDIA = ([[Interface\AddOns\%s\Media\Frame\]]):format(ADDON or "Blackthornes_TS")
local GOLD_ICON   = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"
local GOLD_TEXT, SILVER_TEXT, COPPER_TEXT = "ffffd451", "ffd8dde2", "ffe0915a"

--- Whether the setting is on.
function SaleTotal:IsOn()
    return ns.Config ~= nil and ns.Config:Get("saleTotal") == true
end

local function Level()
    return ns.Motion and ns.Motion.Level and ns.Motion.Level() or "full"
end

local function Comma(n)
    if ns.Util and ns.Util.Comma then return ns.Util.Comma(n) end
    return tostring(n)
end

--- Copper as coloured gold, silver and copper with the game's coin icons.
--- Every coin shows once there is gold, so the number does not jump about
--- as it counts.
function SaleTotal.Money(copper)
    copper = math.max(0, math.floor((tonumber(copper) or 0) + 0.5))
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local rest = copper % 100
    local parts = {}
    if gold > 0 then
        parts[#parts + 1] = ("|c%s%s|r%s"):format(GOLD_TEXT, Comma(gold), GOLD_ICON)
    end
    if gold > 0 or silver > 0 then
        parts[#parts + 1] = ("|c%s%s|r%s"):format(SILVER_TEXT, gold > 0 and ("%02d"):format(silver) or silver, SILVER_ICON)
    end
    parts[#parts + 1] = ("|c%s%s|r%s"):format(COPPER_TEXT,
        (gold > 0 or silver > 0) and ("%02d"):format(rest) or rest, COPPER_ICON)
    return table.concat(parts, " ")
end

--- A short amount for a float or the change line: the two biggest coins.
function SaleTotal.Short(copper)
    local Util = ns.Util
    if Util and Util.FormatMoney then return Util.FormatMoney(copper, { noColor = true, parts = 2 }) end
    return tostring(copper)
end

--- What each line on the Sell list adds, as PostPanel's title counts it:
--- every shown line not held back, with a price.
function SaleTotal.Worths(lines)
    local worths, total = {}, 0
    for _, line in ipairs(lines or {}) do
        local worth = not line.held and tonumber(line.postTotal) or 0
        if worth > 0 then
            worths[#worths + 1] = worth
            total = total + worth
        end
    end
    return worths, total
end

--- How long each item's step takes for a list of `count`.
function SaleTotal.StepFor(count)
    if count <= 0 then return 0 end
    return math.min(SaleTotal.STEP_MOST, SaleTotal.PLAY / count)
end

--- Whether one item adding `add` to `total` is a big one.
function SaleTotal.IsBig(add, total)
    return add >= SaleTotal.BIG_LEAST and total > 0 and add >= SaleTotal.BIG * total
end

--- The line under the number once the count is done.
function SaleTotal.ChangeText(before, after)
    if not before or before == after then return nil end
    if after > before then
        return L.Format("Up %s since your last scan", SaleTotal.Short(after - before)), "profit"
    end
    return L.Format("Down %s since your last scan", SaleTotal.Short(before - after)), "muted"
end

--- A scan has finished with prices: the next look at the Sell list counts
--- it up. Asked for at once while the drawer shows.
function SaleTotal:ScanFinished()
    if not self:IsOn() then return end
    self.pending = true
    local panel = ns.PostPanel
    if panel and panel.IsShown and panel:IsShown() and C_Timer and C_Timer.After then
        C_Timer.After(0.3, function() panel:Refresh() end)
    end
end

--- The scan's progress, from the drawer's header (UI:RefreshAuctionStatus):
--- a fraction while one runs, nil otherwise.
function SaleTotal:Scanning(fraction, running)
    if not (self.frame and self.frame:IsShown()) or self.play then return end
    if running then
        self.frame.bar:Show()
        self.frame.bar:SetProgress(fraction or 0)
        self:SetMeta(L["Scanning"], "text")
        self.scanning = true
    elseif self.scanning then
        self.scanning = nil
        self.frame.bar:Hide()
        self:SetMeta(self.change, self.changeColor)
    end
end

--- The Sell list as PostPanel:Refresh drew it.
function SaleTotal:Update(lines)
    if not self:IsOn() then
        if self.frame then self.frame:Hide() end
        return
    end
    local frame = self:Build()
    if not frame then return end
    frame:Show()

    local worths, total = SaleTotal.Worths(lines)
    self.total = total

    if self.pending then
        self.pending = nil
        self:Play(worths, total)
        return
    end
    if self.play then return end

    if self.shown == nil or Level() == "off" then
        self.shown, self.target = total, total
        self:Draw()
    elseif total ~= self.target then
        self.target = total
        self:Wake()
    end
end

--- Count the total up from nothing, an item at a time.
function SaleTotal:Play(worths, total)
    local before = self.target
    self.cheer, self.change, self.changeColor = nil, nil, nil
    if Level() == "off" or #worths == 0 then
        self.shown, self.target = total, total
        self:Finish(before, total, false)
        return
    end
    self.play = { worths = worths, total = total, before = before, index = 0, wait = 0,
        step = SaleTotal.StepFor(#worths) }
    self.shown, self.target = 0, 0
    if self.frame then
        self.frame.bar:Show()
        self.frame.bar:SetProgress(0)
    end
    self:Draw()
    self:Wake()
end

function SaleTotal:Finish(before, total, cheer)
    self.play = nil
    self.change, self.changeColor = SaleTotal.ChangeText(before, total)
    self.cheer = L["Scan done. Your Sell list is ready."]
    if self.frame then
        self.frame.bar:SetProgress(1)
        self.frame.bar:Hide()
        self.frame.cheer:SetText(self.cheer)
        self:SetMeta(self.change, self.changeColor)
        if cheer and Level() == "full" then
            self.glowLeft, self.glowKey = SaleTotal.GLOW_FOR, "profit"
        end
    end
    if cheer and (not ns.Config or ns.Config:Get("scanSounds") ~= false) and type(PlaySound) == "function" then
        local kits = type(_G.SOUNDKIT) == "table" and _G.SOUNDKIT or {}
        pcall(PlaySound, kits.LOOT_WINDOW_COIN_SOUND or 120, "Master")
    end
    self:Draw()
    self:Wake()
end

--- One frame's worth of moving. True while anything still moves.
function SaleTotal:Tick(elapsed)
    local busy = false
    local play = self.play

    if play then
        busy = true
        play.wait = play.wait - elapsed
        while play.wait <= 0 and play.index < #play.worths do
            play.index = play.index + 1
            local add = play.worths[play.index]
            self.target = self.target + add
            play.wait = play.wait + play.step
            self:Landed(add, play.total)
        end
        if self.frame then
            self.frame.bar:SetProgress(play.index / #play.worths)
            self:SetMeta(L.Format("%d priced, %d to go", play.index, #play.worths - play.index), "text")
        end
        if play.index >= #play.worths and math.abs(self.target - self.shown) < 1 then
            self.shown = self.target
            self:Finish(play.before, play.total, true)
            return true
        end
    end

    if self.shown ~= self.target then
        local gap = self.target - self.shown
        if math.abs(gap) < 1 then
            self.shown = self.target
        else
            self.shown = self.shown + gap * math.min(1, elapsed * SaleTotal.ROLL)
        end
        busy = true
        self:Draw()
    end

    local frame = self.frame
    if frame then
        for _, float in ipairs(frame.floats) do
            if float.left and float.left > 0 then
                float.left = math.max(0, float.left - elapsed)
                local p = 1 - float.left / SaleTotal.FLOAT_FOR
                float:SetPoint("RIGHT", frame, "TOPRIGHT", -12, -26 + 22 * p)
                float:SetAlpha(math.min(1, 3 * (1 - p)))
                if float.left == 0 then float:Hide() end
                busy = true
            end
        end
        if self.shineLeft and self.shineLeft > 0 then
            self.shineLeft = math.max(0, self.shineLeft - elapsed)
            local p = 1 - self.shineLeft / SaleTotal.SHINE_FOR
            frame.shine:SetPoint("LEFT", frame, "LEFT", -60 + (frame:GetWidth() + 60) * p, 0)
            frame.shine:SetAlpha(math.sin(math.pi * p) * 0.8)
            for i, spark in ipairs(frame.sparks) do
                spark:SetAlpha(math.sin(math.pi * math.min(1, p * 1.4 + i * 0.05)) * 0.9)
            end
            busy = true
        end
        if self.glowLeft and self.glowLeft > 0 then
            self.glowLeft = math.max(0, self.glowLeft - elapsed)
            local Theme = ns.Theme
            if Theme and Theme.SetHalo then
                Theme.SetHalo(frame, 0.12 + 0.5 * self.glowLeft / SaleTotal.GLOW_FOR, self.glowKey or "accent")
            end
            if self.glowLeft == 0 and Theme and Theme.SetHalo then Theme.SetHalo(frame, 0.12, "accent") end
            busy = true
        end
    end
    return busy
end

--- One item counted: a float, and for a big one the shine.
function SaleTotal:Landed(add, total)
    local frame = self.frame
    if not frame or Level() ~= "full" then return end
    local big = SaleTotal.IsBig(add, total)
    local float = frame.floats[frame.nextFloat]
    frame.nextFloat = frame.nextFloat % #frame.floats + 1
    float:SetText("+" .. SaleTotal.Short(add))
    float:SetTextColor(1, big and 0.95 or 0.83, big and 0.66 or 0.32)
    float:SetScale(big and 1.25 or 1)
    float.left = SaleTotal.FLOAT_FOR
    float:Show()
    if big then
        self.shineLeft = SaleTotal.SHINE_FOR
        local Theme = ns.Theme
        self.glowLeft, self.glowKey = math.max(self.glowLeft or 0, 0.8), "accent"
    end
end

function SaleTotal:Wake()
    local frame = self.frame
    if not frame or frame.awake then return end
    frame.awake = true
    frame:SetScript("OnUpdate", function(_, elapsed)
        if not SaleTotal:Tick(elapsed) then
            frame.awake = nil
            frame:SetScript("OnUpdate", nil)
        end
    end)
end

function SaleTotal:Draw()
    local frame = self.frame
    if not frame then return end
    frame.money:SetText(SaleTotal.Money(self.shown or 0))
    frame.cheer:SetShown(self.cheer ~= nil and self.play == nil)
end

function SaleTotal:SetMeta(text, color)
    local frame = self.frame
    if not frame then return end
    frame.meta:SetText(text or "")
    local Theme = ns.Theme
    if Theme and Theme.Unpack then frame.meta:SetTextColor(Theme.Unpack(color or "muted")) end
end

--- The plaque, on top of the drawer and inside its parent, so it shows,
--- hides and moves with it; it stays while the drawer is folded.
function SaleTotal:Build()
    if self.frame then return self.frame end
    local panel = ns.PostPanel
    local parent = panel and panel.frame
    local Theme, Widgets = ns.Theme, ns.Widgets
    if not (parent and Theme and Widgets and CreateFrame) then return nil end

    local frame = CreateFrame("Frame", "BlackthornesTSSaleTotal", parent)
    frame:SetSize(SaleTotal.WIDTH, SaleTotal.HEIGHT)
    frame:SetPoint("BOTTOM", parent, "TOP", 0, 18)
    frame:EnableMouse(true)
    if frame.SetClampedToScreen then frame:SetClampedToScreen(true) end

    Theme.Fill(frame, "header")
    Theme.TopSheen(frame, 0.07)
    Theme.Border(frame, "accent", 0.8)
    Theme.Halo(frame, 8, 0.12)

    local label = Theme.CreateLabel(frame, "small", "accent")
    label:SetPoint("TOPLEFT", 12, -8)
    label:SetText(L["Sale Total:"])

    local cheer = Theme.CreateLabel(frame, "small", "profit", "RIGHT")
    cheer:SetPoint("TOPRIGHT", -12, -8)
    cheer:SetPoint("LEFT", label, "RIGHT", 8, 0)
    cheer:Hide()
    frame.cheer = cheer

    local money = Theme.CreateLabel(frame, "title", "text")
    money:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
    frame.money = money

    local bar = Widgets.CreateProgressBar(frame)
    bar:SetHeight(4)
    bar:SetPoint("BOTTOMLEFT", 12, 20)
    bar:SetPoint("BOTTOMRIGHT", -12, 20)
    bar:Hide()
    frame.bar = bar

    local meta = Theme.CreateLabel(frame, "tiny", "muted")
    meta:SetPoint("BOTTOMLEFT", 12, 7)
    meta:SetPoint("BOTTOMRIGHT", -12, 7)
    frame.meta = meta

    -- The light that sweeps across for a big one.
    local shine = frame:CreateTexture(nil, "OVERLAY")
    shine:SetSize(60, SaleTotal.HEIGHT - 4)
    shine:SetPoint("LEFT", frame, "LEFT", -60, 0)
    Theme.SetGradientAlpha(shine, "HORIZONTAL", "accent", 0, 0.5)
    pcall(shine.SetBlendMode, shine, "ADD")
    shine:SetAlpha(0)
    frame.shine = shine

    frame.sparks = {}
    for i, spot in ipairs({ { 40, -2 }, { 170, -50 }, { 300, -6 }, { 250, -56 } }) do
        local spark = frame:CreateTexture(nil, "OVERLAY", nil, 2)
        spark:SetTexture(MEDIA .. "GoldSparkle")
        spark:SetSize(i % 2 == 0 and 12 or 16, i % 2 == 0 and 12 or 16)
        spark:SetPoint("CENTER", frame, "TOPLEFT", spot[1], spot[2])
        pcall(spark.SetBlendMode, spark, "ADD")
        spark:SetAlpha(0)
        frame.sparks[i] = spark
    end

    frame.floats, frame.nextFloat = {}, 1
    for i = 1, 4 do
        local float = Theme.CreateLabel(frame, "normal", "accent", "RIGHT")
        float:SetPoint("RIGHT", frame, "TOPRIGHT", -12, -26)
        float:Hide()
        frame.floats[i] = float
    end

    -- Leaving the auction house mid-count lands it at once, quietly; the
    -- cheer is for this visit only.
    frame:SetScript("OnHide", function() SaleTotal:Hidden() end)

    self.frame = frame
    return frame
end

function SaleTotal:Hidden()
    local play = self.play
    if play then
        self.play = nil
        self.shown, self.target = play.total, play.total
        self.change, self.changeColor = SaleTotal.ChangeText(play.before, play.total)
    end
    self.cheer, self.shineLeft, self.glowLeft, self.scanning = nil, nil, nil, nil
    local frame = self.frame
    if frame then
        for _, float in ipairs(frame.floats) do float.left = nil; float:Hide() end
        frame.shine:SetAlpha(0)
        for _, spark in ipairs(frame.sparks) do spark:SetAlpha(0) end
        frame.bar:Hide()
        local Theme = ns.Theme
        if Theme and Theme.SetHalo then Theme.SetHalo(frame, 0.12, "accent") end
    end
    self:SetMeta(self.change, self.changeColor)
    self:Draw()
end
