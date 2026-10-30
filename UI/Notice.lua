-- Blackthornes -- UI/Notice.lua
-- One note on screen for every addon (the owner said build it, 2026-10-29,
-- from the unified look's mockups): a dark glass card under the top of the
-- screen with an icon and gold words, which holds a few seconds and fades.
-- Notes from any of the five stack in one slot, one under the next, so two
-- never land on top of each other.
--
-- There is no shared core addon: every copy signs up in
-- `_G.BlackthornesNotice` and lays its cards out with the others' (the same
-- way What's New and the sister note share). The same file in all five
-- addons (a fix to it belongs in all five).
--
--   ns.Notice:Show(text, { icon, hold, key })
--     key: a second note with the same key replaces the first.

local _, ns = ...

local Notice = {}
ns.Notice = Notice

Notice.TOP = -150
Notice.GAP = 6
Notice.HEIGHT = 36
Notice.HOLD = 4
Notice.FADE_IN = 0.25
Notice.FADE_OUT = 0.8
Notice.ICON = [[Interface\Icons\INV_Misc_Note_01]]
Notice.MOST = 4

local ICON_SIZE = 22
local PAD = 10

local shared = rawget(_G, "BlackthornesNotice")
if type(shared) ~= "table" then
    shared = { cards = {} }
    _G.BlackthornesNotice = shared
end
shared.cards = shared.cards or {}

local function Color(key, alpha)
    local theme = ns.Theme
    if theme and theme.Unpack then
        local ok, r, g, b, a = pcall(theme.Unpack, key, alpha)
        if ok and r then return r, g, b, a or alpha or 1 end
    end
    return 0.8, 0.65, 0.3, alpha or 1
end

local function Now()
    local fn = rawget(_G, "GetTime")
    return type(fn) == "function" and fn() or os.time()
end

--- Lay every addon's cards out, newest at the top.
function Notice.Layout()
    local y = Notice.TOP
    for _, card in ipairs(shared.cards) do
        card:ClearAllPoints()
        card:SetPoint("TOP", UIParent, "TOP", 0, y)
        y = y - Notice.HEIGHT - Notice.GAP
    end
end

local function Remove(card)
    for index, other in ipairs(shared.cards) do
        if other == card then
            table.remove(shared.cards, index)
            break
        end
    end
    card:Hide()
    card.key = nil
    Notice.Layout()
end
Notice.Remove = Remove

local pool = {}

local function CreateCard()
    local card = CreateFrame("Frame", nil, UIParent)
    pcall(card.SetFrameStrata, card, "HIGH")
    card:SetHeight(Notice.HEIGHT)
    pcall(card.EnableMouse, card, false)
    card.fill = card:CreateTexture(nil, "BACKGROUND")
    card.fill:SetAllPoints()
    card.fill:SetColorTexture(Color("glass", 0.94))
    local theme = ns.Theme
    if theme and theme.Border then pcall(theme.Border, card, "accent", 0.9) end
    if theme and theme.Halo then pcall(theme.Halo, card, 8, 0.18) end
    card.icon = card:CreateTexture(nil, "ARTWORK")
    card.icon:SetSize(ICON_SIZE, ICON_SIZE)
    card.icon:SetPoint("LEFT", PAD, 0)
    pcall(card.icon.SetTexCoord, card.icon, 0.07, 0.93, 0.07, 0.93)
    if theme and theme.CreateLabel then
        card.text = theme.CreateLabel(card, "normal", "accentHi", "LEFT")
    else
        card.text = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    end
    card.text:SetPoint("LEFT", card.icon, "RIGHT", 8, 0)
    card:SetScript("OnUpdate", function(self)
        local age = Now() - (self.shownAt or 0)
        local hold = self.hold or Notice.HOLD
        if age < Notice.FADE_IN then
            self:SetAlpha(math.max(0, age / Notice.FADE_IN))
        elseif age < Notice.FADE_IN + hold then
            self:SetAlpha(1)
        elseif age < Notice.FADE_IN + hold + Notice.FADE_OUT then
            self:SetAlpha(1 - (age - Notice.FADE_IN - hold) / Notice.FADE_OUT)
        else
            Remove(self)
            pool[#pool + 1] = self
        end
    end)
    card:Hide()
    return card
end

--- Show a note. Returns the card.
function Notice:Show(text, opts)
    if type(text) ~= "string" or text == "" then return nil end
    opts = opts or {}
    local card
    if opts.key then
        for _, other in ipairs(shared.cards) do
            if other.key == opts.key then card = other break end
        end
    end
    if not card then
        card = table.remove(pool) or CreateCard()
        table.insert(shared.cards, 1, card)
        while #shared.cards > Notice.MOST do
            local oldest = shared.cards[#shared.cards]
            Remove(oldest)
        end
    end
    card.key = opts.key
    card.hold = opts.hold
    card.icon:SetTexture(opts.icon or Notice.ICON)
    card.text:SetText(text)
    local ok, width = pcall(card.text.GetStringWidth, card.text)
    if not (ok and type(width) == "number" and width > 0) then width = #text * 6 end
    card.text:SetWidth(width + 2)
    card:SetWidth(PAD + ICON_SIZE + 8 + width + 2 + PAD + 4)
    card.shownAt = Now()
    card:SetAlpha(0)
    card:Show()
    Notice.Layout()
    return card
end

--- How many notes show now, from every addon.
function Notice:Count()
    return #shared.cards
end

return Notice
