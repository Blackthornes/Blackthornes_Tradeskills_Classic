-- Blackthornes Tradeskills -- UI/CraftProfitCard.lua
-- CRAFT COST AND PROFIT: a dark glass card under the reagents in the game's
-- profession window (the owner picked option B, 2026-11-14). Sells For (with
-- "Makes 2" for crafts that make more than one), one line a mat tagged AH or
-- Vendor, Mats Cost and Profit, all from Logic/CraftProfit.lua, so it always
-- agrees with the recipe rows and their hover.
--
-- Our own frame on UIParent, placed by screen position under the game's
-- reagents. No Blizzard frame is hidden, shown, moved, reparented or written
-- to; the game's pick is followed with read-only hooks and a light look while
-- the window is open. Off unless "Craft Cost and Profit:" is ticked
-- (`craftProfitInProfessionWindow`). Drawn again only when the figures change.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local CraftProfitCard = ns.NewModule("CraftProfitCard")

local Theme = ns.Theme

CraftProfitCard.WIDTH = 300      -- when the reagents won't say how wide they are
CraftProfitCard.MIN_WIDTH = 240
CraftProfitCard.PAD = 10
CraftProfitCard.GAP = 6          -- under the reagents
CraftProfitCard.LINE_GAP = 3
CraftProfitCard.LOOK = 0.5       -- how often the pick is looked at while open

local function Shown(frame)
    if type(frame) ~= "table" or type(frame.IsVisible) ~= "function" then return false end
    local ok, shown = pcall(frame.IsVisible, frame)
    return ok and shown and true or false
end

local function Field(frame, key)
    if type(frame) ~= "table" then return nil end
    local ok, value = pcall(function() return frame[key] end)
    return ok and type(value) == "table" and value or nil
end

local function Rect(frame)
    local ok, top, bottom, left, right, scale = pcall(function()
        return frame:GetTop(), frame:GetBottom(), frame:GetLeft(), frame:GetRight(), frame:GetEffectiveScale()
    end)
    if not ok or not top or not bottom or not left or not right then return nil end
    local base = UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale() or 1
    local k = (tonumber(scale) or 1) / (base > 0 and base or 1)
    return { top = top * k, bottom = bottom * k, left = left * k, right = right * k }
end

--------------------------------------------------------------------------------
-- Where it sits (read only)
--------------------------------------------------------------------------------

--- What to sit under: the lowest of the game's reagent lists that shows,
--- else the recipe pane itself. { frame, under (true: below it), game, name }.
function CraftProfitCard.FindAnchor()
    local pros = _G.ProfessionsFrame
    local page = Field(pros, "CraftingPage")
    local form = Field(page, "SchematicForm")
    if Shown(form) then
        local best, bestBottom
        for _, key in ipairs({ "Reagents", "OptionalReagents" }) do
            local part = Field(form, key)
            local rect = Shown(part) and Rect(part)
            if rect and (not bestBottom or rect.bottom < bestBottom) then
                best, bestBottom = { frame = part, under = true, game = pros, name = "SchematicForm." .. key }, rect.bottom
            end
        end
        if best then return best end
        return { frame = form, under = false, game = pros, name = "SchematicForm" }
    end
    local old = _G.TradeSkillFrame
    local detail = _G.TradeSkillDetailScrollFrame
    if Shown(detail) then return { frame = detail, under = false, game = old, name = "TradeSkillDetailScrollFrame" } end
    return nil
end

--------------------------------------------------------------------------------
-- What it says (pure)
--------------------------------------------------------------------------------

--- The card's lines, top to bottom: { kind, label, value, way }.
-- kind is "sells", "mat", "cost" or "profit".
function CraftProfitCard.Rows(figures)
    local CP = ns.CraftProfit
    local rows = {}
    if not CP then return rows end
    local lines = CP.Lines(figures)
    local sells = lines[1]
    rows[#rows + 1] = { kind = "sells", label = sells.label, value = sells.value, makes = sells.makes }
    for _, entry in ipairs(figures and figures.reagents or {}) do
        local name = CP.ItemName(entry.itemID)
        rows[#rows + 1] = {
            kind = "mat",
            label = (entry.quantity or 1) .. " " .. name,
            value = entry.lineCost and CP.Money(entry.lineCost) or CP.NoPrice(),
            way = entry.lineCost and CP.WayText(entry.way) or nil,
        }
    end
    rows[#rows + 1] = { kind = "cost", label = lines[2].label, value = lines[2].value }
    rows[#rows + 1] = { kind = "profit", label = lines[3].label, value = lines[3].value }
    return rows
end

--------------------------------------------------------------------------------
-- The card
--------------------------------------------------------------------------------

function CraftProfitCard:Build()
    if self.frame then return self.frame end
    local frame = CreateFrame("Frame", "BlackthornesTSCraftProfitCard", UIParent)
    frame:SetSize(CraftProfitCard.WIDTH, 80)
    frame:Hide()
    self.frame = frame

    Theme.Fill(frame, "glass")
    Theme.Border(frame, "accentHi", 0.7)

    local heading = Theme.CreateLabel(frame, "tiny", "accent")
    heading:SetText(L["CRAFT COST AND PROFIT"])
    heading:SetPoint("TOPLEFT", frame, "TOPLEFT", CraftProfitCard.PAD, -CraftProfitCard.PAD)
    self.heading = heading

    self.lines = {}
    self.dividers = {}
    return frame
end

--- One line of the card, made once and kept.
function CraftProfitCard:Line(index)
    local line = self.lines[index]
    if line then return line end
    local frame = self.frame
    line = {}
    line.value = Theme.CreateLabel(frame, "small", "text", "RIGHT")
    line.way = Theme.CreateLabel(frame, "tiny", "muted", "RIGHT")
    line.label = Theme.CreateLabel(frame, "small", "text", "LEFT")
    line.label:SetWordWrap(true)
    line.label:SetNonSpaceWrap(true)
    line.stripe = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    self.lines[index] = line
    return line
end

local function HideLine(line)
    line.value:Hide(); line.way:Hide(); line.label:Hide(); line.stripe:Hide()
end

--- Lay the rows out; the card grows to fit. Labels wrap, never "...".
function CraftProfitCard:Draw(figures)
    local frame = self:Build()
    local rows = CraftProfitCard.Rows(figures)
    local pad, gap = CraftProfitCard.PAD, CraftProfitCard.LINE_GAP
    local width = frame:GetWidth()
    local y = pad + (self.heading:GetStringHeight() or 10) + 6
    local matIndex = 0

    for index, row in ipairs(rows) do
        local line = self:Line(index)
        local bold = row.kind ~= "mat"
        line.label:SetFontObject(line.label:GetFontObject())
        line.label:SetTextColor(Theme.Unpack(bold and "text" or "muted"))
        local label = row.label
        if row.makes then label = label .. "  |c" .. ((ns.COLORS and ns.COLORS.muted) or "ff7a8089") .. row.makes .. "|r" end
        line.label:SetText(label)
        line.value:SetText(row.value or "")
        line.way:SetText(row.way or "")

        local valueWidth = Theme.TextWidth(line.value) or 60
        local wayWidth = row.way and ((Theme.TextWidth(line.way) or 20) + 6) or 0
        -- A long value (bound mats) wraps under the label instead of crowding it.
        local wide = valueWidth + wayWidth > (width - pad * 2) * 0.55
        line.value:ClearAllPoints()
        line.way:ClearAllPoints()
        line.label:ClearAllPoints()
        line.label:SetPoint("TOPLEFT", frame, "TOPLEFT", pad + (row.kind == "mat" and 8 or 0), -y)
        if wide then
            line.label:SetPoint("RIGHT", frame, "RIGHT", -pad, 0)
            local labelHeight = line.label:GetStringHeight() or 12
            line.value:SetWordWrap(true)
            line.value:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -pad, -(y + labelHeight + 1))
            line.value:SetPoint("LEFT", frame, "LEFT", pad + 8, 0)
            y = y + labelHeight + 1 + (line.value:GetStringHeight() or 12) + gap
        else
            line.value:SetWordWrap(false)
            line.value:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -pad, -y)
            if row.way then line.way:SetPoint("RIGHT", line.value, "LEFT", -6, 0) end
            line.label:SetPoint("RIGHT", frame, "RIGHT", -(pad + valueWidth + wayWidth + 8), 0)
            local height = math.max(line.label:GetStringHeight() or 12, line.value:GetStringHeight() or 12)
            y = y + height + gap
        end

        -- Mat lines are dark glass, alternating by place.
        if row.kind == "mat" then
            matIndex = matIndex + 1
            line.stripe:SetColorTexture(Theme.Unpack(matIndex % 2 == 1 and "glass" or "glassAlt"))
            line.stripe:ClearAllPoints()
            line.stripe:SetPoint("TOPLEFT", line.label, "TOPLEFT", -6, 2)
            line.stripe:SetPoint("RIGHT", frame, "RIGHT", -pad + 4, 0)
            line.stripe:SetPoint("BOTTOM", frame, "TOP", 0, -(y - 1))
            line.stripe:Show()
        else
            line.stripe:Hide()
        end
        line.label:Show(); line.value:Show()
        if row.way then line.way:Show() else line.way:Hide() end
    end
    for index = #rows + 1, #self.lines do HideLine(self.lines[index]) end
    frame:SetHeight(y + pad - gap)
end

--- Put the card under the reagents, at their width.
function CraftProfitCard:Place()
    local frame = self.frame
    local anchor = CraftProfitCard.FindAnchor()
    self.anchor = anchor
    if not frame or not anchor then return false end
    local rect = Rect(anchor.frame)
    local width = CraftProfitCard.WIDTH
    if rect and anchor.under then width = math.max(CraftProfitCard.MIN_WIDTH, rect.right - rect.left) end
    if math.abs((frame:GetWidth() or 0) - width) > 0.5 then
        frame:SetWidth(width)
        self.drawn = nil
    end
    frame:ClearAllPoints()
    if anchor.under then
        frame:SetPoint("TOPLEFT", anchor.frame, "BOTTOMLEFT", 0, -CraftProfitCard.GAP)
    else
        frame:SetPoint("BOTTOMLEFT", anchor.frame, "BOTTOMLEFT", CraftProfitCard.PAD, CraftProfitCard.PAD + 40)
    end
    local game = anchor.game or anchor.frame
    local okStrata, strata = pcall(game.GetFrameStrata, game)
    local okLevel, level = pcall(anchor.frame.GetFrameLevel, anchor.frame)
    if okStrata and strata then pcall(frame.SetFrameStrata, frame, strata) end
    if okLevel and level then pcall(frame.SetFrameLevel, frame, level + 30) end
    return true
end

--- The game's pick, read only.
function CraftProfitCard.GamePick()
    if ns.EnchantWindow and ns.EnchantWindow.GamePick then
        local ok, pick = pcall(ns.EnchantWindow.GamePick, ns.EnchantWindow)
        if ok then return pick end
    end
    return nil
end

function CraftProfitCard:IsOn()
    return ns.Config and ns.Config:Get("craftProfitInProfessionWindow") == true
end

--- Show, hide or redraw for how things stand.
function CraftProfitCard:Refresh()
    local on = self:IsOn()
    local pick = on and self.open and CraftProfitCard.GamePick() or nil
    local figures = pick and ns.CraftProfit and ns.CraftProfit:For(pick) or nil
    if not figures then
        if self.frame then self.frame:Hide() end
        self.drawn = nil
        return
    end
    self:Build()
    if not self:Place() then
        self.frame:Hide()
        return
    end
    -- CraftProfit keeps one table a recipe until a price or setting moves,
    -- so the same table means nothing changed.
    if self.drawn ~= figures then
        self.drawn = figures
        self:Draw(figures)
    end
    self.frame:Show()
end

function CraftProfitCard:Hook()
    if self.hooked then return end
    local form = Field(Field(_G.ProfessionsFrame, "CraftingPage"), "SchematicForm")
    local again = function() CraftProfitCard:Soon() end
    if form and type(hooksecurefunc) == "function" and type(form.Init) == "function" then
        if pcall(hooksecurefunc, form, "Init", again) then self.hooked = true end
    end
    local registry = _G.EventRegistry
    if type(registry) == "table" and type(registry.RegisterCallback) == "function" then
        if pcall(registry.RegisterCallback, registry,
            "ProfessionsRecipeListMixin.Event.OnRecipeSelected", again, self) then
            self.hooked = true
        end
    end
end

--- One look a moment after the game settles the pick.
function CraftProfitCard:Soon()
    if self.waiting then return end
    self.waiting = true
    C_Timer.After(0.05, function()
        CraftProfitCard.waiting = nil
        CraftProfitCard:Refresh()
    end)
end

--- A light look while the window is open: one pick read and a kept answer.
function CraftProfitCard:Watch()
    local watcher = self.watcher or CreateFrame("Frame")
    self.watcher = watcher
    local elapsed = 0
    watcher:SetScript("OnUpdate", function(_, step)
        elapsed = elapsed + step
        if elapsed < CraftProfitCard.LOOK then return end
        elapsed = 0
        if not CraftProfitCard.open or not CraftProfitCard:IsOn() then
            watcher:SetScript("OnUpdate", nil)
            CraftProfitCard:Refresh()
            return
        end
        CraftProfitCard:Refresh()
    end)
end

function CraftProfitCard:Opened()
    self.open = true
    if self:IsOn() then
        self:Hook()
        self:Watch()
    end
    self:Refresh()
    C_Timer.After(0.5, function() CraftProfitCard:Refresh() end)
end

function CraftProfitCard:OnEnable()
    ns.RegisterEvent(self, "TRADE_SKILL_SHOW", function() CraftProfitCard:Opened() end)
    ns.RegisterEvent(self, "TRADE_SKILL_CLOSE", function()
        CraftProfitCard.open = nil
        CraftProfitCard:Refresh()
    end)
end

--- The setting changed: start or stop following the window.
local refresh = CraftProfitCard.Refresh
function CraftProfitCard:Refresh(...)
    if self.open and self:IsOn() and not (self.watcher and self.watcher:GetScript("OnUpdate")) then
        self:Hook()
        self:Watch()
    end
    return refresh(self, ...)
end
