-- UI/WhatsNew.lua
-- The What's New window: the first time the game loads after an update, one
-- window says what changed in every Blackthornes addon that was updated, in
-- the words of the Discord #general post (the owner asked 2026-10-12).
--
-- This file is the same in all five addons (Farmer, Tradeskills, Equipment,
-- Pets and Butler); a fix to it belongs in all five.
--
-- One window for all of them, with no shared core addon: every copy signs up
-- in one global table, _G.BlackthornesWhatsNew, as it loads, with readers for
-- its own account save and its release notes (ns.WHATS_NEW, written into
-- Core/WhatsNewText.lua from NEWS.md by tools/make_whatsnew.py). The first
-- copy to reach PLAYER_LOGIN starts the only timer; when it fires, every copy
-- has signed up, and that one check gathers what is new in all of them. The
-- window is built by the copy with the newest FILE_VERSION (the first in
-- ADDONS on a tie), with that addon's frame, buttons and colours.
--
-- Shown once a version: each addon keeps the newest version it has shown in
-- its own account save (whatsNewSeen). After an update, the sections newer
-- than that (at most MOST) are shown; an addon that never kept one (a new
-- install, or an update from before this window) shows its newest only.
-- Nothing waits for a fight to end any longer than the fight.
--
-- The note (2026-10-13): once per account, a card at the top of the window
-- with the words of UI/About.lua (About.NOTE), the same note the About page
-- in Settings keeps. Shown with the next window that comes up by itself, or
-- alone when nothing is new; then aboutNoteSeen is set in every sister's
-- account save, so no sister shows it again.
--
-- One-time cards (2026-10-13): an addon can offer cards of its own in
-- ns.WHATS_NEW_TIPS, each { key, title, icon, paragraphs, hint, button, run,
-- due }, such as Equipment's word about its Upgrade quest. Each is looked
-- at once per account, with the next window that comes up by itself, and
-- shown only while due() says so; then it is kept in that addon's
-- whatsNewTipsSeen[key] and never shown again. Its button calls run() and
-- closes the window, unless the card says stay = true (a button that opens
-- another window, such as Settings, leaves this one up).
--
-- The thank-you (2026-10-23): one card above the note, once per account,
-- the words of About.THANKS; thanksSeen is set in every sister's save.
--
-- Saved, account wide, never renamed: whatsNewSeen (per addon), aboutNoteSeen,
-- thanksSeen,
-- whatsNewTipsSeen (per addon),
-- whatsNewPopup (on unless unticked) and whatsNewMotion (on unless
-- unticked), which are off in all when off in any, as sisterNote is, and
-- whatsNewScale (the size grip, where the addon has one). The `whatsnew`
-- command and a Settings button open it again.
--
-- Smooth play: built once, on demand, the first time it opens; filled again
-- only when it opens. The movement is the house tween clock (ns.Motion),
-- which runs only while something moves, and one looping glow the game's
-- own animation system plays while the window shows. "Motion" (in the
-- window and in Settings) lands everything at once.

local ADDON_NAME, ns = ...

local WhatsNew = ns.NewModule("WhatsNew")

-- The words through the addon's translation table where it has one (ns.L,
-- Locale/Locale.lua), else in English, so this file stays the same in all.
local L = ns.L or setmetatable({}, { __index = function(_, key) return key end })
local Format = rawget(L, "Format")
if type(Format) ~= "function" then Format = string.format end

-- Raised when this file changes in a way an older copy cannot draw: the
-- newest copy loaded builds the window.
WhatsNew.FILE_VERSION = 6

-- Seconds after login, so the window comes up once the game has settled.
WhatsNew.DELAY = 5

-- Sections shown at most for one addon after an update.
WhatsNew.MOST = 3

-- The window's width, grown when a translation's footer needs more.
WhatsNew.WIDTH = 500

-- Every sister, in the order the window lists them.
WhatsNew.ADDONS = {
    { folder = "Blackthornes_Farmer", title = "Blackthornes Farmer",
      icon = [[Interface\Icons\Trade_Mining]] },
    { folder = "Blackthornes_TS", title = "Blackthornes Tradeskills",
      icon = [[Interface\Icons\Trade_BlackSmithing]] },
    { folder = "Blackthornes_Equipment", title = "Blackthornes Equipment",
      icon = [[Interface\Icons\INV_Chest_Chain]] },
    { folder = "Blackthornes_Pets", title = "Blackthornes Pets",
      icon = [[Interface\Icons\Ability_Hunter_BeastTaming]] },
    { folder = "Blackthornes_Butler", title = "Blackthornes Butler",
      icon = [[Interface\Icons\INV_Misc_Bag_08]] },
}

local shared = _G.BlackthornesWhatsNew
if type(shared) ~= "table" then
    shared = {}
    _G.BlackthornesWhatsNew = shared
end
if type(shared.members) ~= "table" then shared.members = {} end
if type(shared.copies) ~= "table" then shared.copies = {} end
WhatsNew.shared = shared

-- Signed up as the file loads; read only later, once the saves are in.
shared.members[ADDON_NAME] = {
    store = function()
        local db = ns.db
        if type(db) == "table" then return db end
        return nil
    end,
    news = function()
        local news = ns.WHATS_NEW
        if type(news) == "table" then return news end
        return nil
    end,
    tips = function()
        local tips = ns.WHATS_NEW_TIPS
        if type(tips) == "table" then return tips end
        return nil
    end,
}
shared.copies[ADDON_NAME] = WhatsNew

--------------------------------------------------------------------------------
-- What is new
--------------------------------------------------------------------------------

local function Parts(version)
    local a, b, c = tostring(version or ""):match("^v?(%d+)%.(%d+)%.(%d+)")
    return tonumber(a), tonumber(b), tonumber(c)
end

--- True when version `a` is newer than `b`. Anything is newer than nothing.
function WhatsNew.Newer(a, b)
    local a1, a2, a3 = Parts(a)
    if not a1 then return false end
    local b1, b2, b3 = Parts(b)
    if not b1 then return true end
    if a1 ~= b1 then return a1 > b1 end
    if a2 ~= b2 then return a2 > b2 end
    return a3 > b3
end

local function Read(member, key)
    local ok, value = pcall(member[key])
    if ok and type(value) == "table" then return value end
    return nil
end

--- Every loaded sister's account save, this one's included.
function WhatsNew:Stores()
    local stores, seen = {}, {}
    for _, addon in ipairs(self.ADDONS) do
        local member = shared.members[addon.folder]
        local db = member and Read(member, "store")
        if db and not seen[db] then
            seen[db] = true
            stores[#stores + 1] = db
        end
    end
    return stores
end

local function AllOn(key)
    for _, db in ipairs(WhatsNew:Stores()) do
        if db[key] == false then return false end
    end
    return true
end

local function SetAll(key, on)
    for _, db in ipairs(WhatsNew:Stores()) do db[key] = on and true or false end
end

--- Whether the window comes up by itself after an update.
function WhatsNew:IsOn() return AllOn("whatsNewPopup") end
function WhatsNew:SetOn(on) SetAll("whatsNewPopup", on) end

--- Whether the window moves as it opens.
function WhatsNew:IsMotionOn() return AllOn("whatsNewMotion") end
function WhatsNew:SetMotionOn(on)
    SetAll("whatsNewMotion", on)
    if not on and ns.Motion and ns.Motion.FinishAll and self.frame and self.frame:IsShown() then
        pcall(ns.Motion.FinishAll, ns.Motion)
    end
end

local function Usable(section)
    return type(section) == "table" and type(section.lines) == "table" and #section.lines > 0
end

--- What to show, one entry per sister in ADDONS order:
--- { addon, sections = { { version, lines }, ... }, newest }.
--- `everything` (the command): each sister's newest section, seen or not.
function WhatsNew:Entries(everything)
    local list = {}
    for _, addon in ipairs(self.ADDONS) do
        local member = shared.members[addon.folder]
        local news = member and Read(member, "news")
        if news then
            local db = Read(member, "store")
            local seen = db and db.whatsNewSeen
            local sections = {}
            for _, section in ipairs(news) do
                if Usable(section) then
                    if everything or seen == nil then
                        sections[1] = section
                        break
                    elseif WhatsNew.Newer(section.version, seen) and #sections < self.MOST then
                        sections[#sections + 1] = section
                    end
                end
            end
            if #sections > 0 then
                list[#list + 1] = { addon = addon, sections = sections }
            end
        end
    end
    return list
end

--- Keep the newest version each sister carries as shown.
function WhatsNew:MarkSeen()
    for _, addon in ipairs(self.ADDONS) do
        local member = shared.members[addon.folder]
        local news = member and Read(member, "news")
        local db = member and Read(member, "store")
        if news and db then
            local newest = db.whatsNewSeen
            for _, section in ipairs(news) do
                if Usable(section) and WhatsNew.Newer(section.version, newest) then
                    newest = section.version
                end
            end
            db.whatsNewSeen = newest
        end
    end
end

--- Whether the note at the top is still to be shown: seen in no sister.
function WhatsNew:NoteDue()
    local About = ns.About
    if not (About and type(About.NOTE) == "table" and #About.NOTE > 0) then return false end
    for _, db in ipairs(self:Stores()) do
        if db.aboutNoteSeen then return false end
    end
    return true
end

--- The note as a card for the list.
function WhatsNew:NoteEntry()
    return {
        note = true,
        addon = { title = L["How these addons are made"], icon = [[Interface\Icons\INV_Misc_Note_01]] },
        paragraphs = ns.About.NOTE,
    }
end

--- Whether the thank-you at the very top is still to be shown: seen in no
--- sister (thanksSeen, account wide).
function WhatsNew:ThanksDue()
    local About = ns.About
    if not (About and type(About.THANKS) == "table" and #About.THANKS > 0) then return false end
    for _, db in ipairs(self:Stores()) do
        if db.thanksSeen then return false end
    end
    return true
end

--- The thank-you as a card for the list.
function WhatsNew:ThanksEntry()
    return {
        note = true,
        addon = { title = L["Thank you"], icon = [[Interface\Icons\INV_Misc_Gift_01]] },
        paragraphs = ns.About.THANKS,
    }
end

--- The one-time cards still to show, as cards for the list. Each tip is
--- looked at once: kept as seen in its addon's save whether due or not, so
--- one a player had no need of never turns up later.
function WhatsNew:TakeTips()
    local list = {}
    for _, addon in ipairs(self.ADDONS) do
        local member = shared.members[addon.folder]
        local tips = member and member.tips and Read(member, "tips")
        local db = member and Read(member, "store")
        if tips and db then
            for _, tip in ipairs(tips) do
                local seen = type(db.whatsNewTipsSeen) == "table" and db.whatsNewTipsSeen
                if type(tip) == "table" and type(tip.key) == "string" and type(tip.paragraphs) == "table"
                    and not (seen and seen[tip.key]) then
                    local due = true
                    if type(tip.due) == "function" then
                        local ok, answer = pcall(tip.due)
                        due = ok and answer and true or false
                    end
                    if type(db.whatsNewTipsSeen) ~= "table" then db.whatsNewTipsSeen = {} end
                    db.whatsNewTipsSeen[tip.key] = true
                    if due then
                        list[#list + 1] = {
                            note = true,
                            addon = { title = tip.title or addon.title, icon = tip.icon or addon.icon },
                            paragraphs = tip.paragraphs,
                            hint = tip.hint,
                            button = tip.button,
                            run = tip.run,
                            stay = tip.stay,
                        }
                    end
                end
            end
        end
    end
    return list
end

--- The copy that draws the window: the newest file, then ADDONS order.
function WhatsNew.Owner()
    local best
    for _, addon in ipairs(WhatsNew.ADDONS) do
        local copy = shared.copies[addon.folder]
        if copy and (not best or (copy.FILE_VERSION or 0) > (best.FILE_VERSION or 0)) then
            best = copy
        end
    end
    return best or WhatsNew
end

local function InCombat()
    local check = _G.InCombatLockdown
    if type(check) ~= "function" then return false end
    local ok, answer = pcall(check)
    return ok and answer and true or false
end

--- The one check after login: show what is new, once.
function WhatsNew:Check()
    if shared.checked then return end

    if InCombat() then
        -- After the fight, not in the middle of it.
        if not shared.waiting then
            shared.waiting = CreateFrame("Frame")
            shared.waiting:SetScript("OnEvent", function(frame)
                frame:UnregisterAllEvents()
                local ok, err = pcall(WhatsNew.Check, WhatsNew)
                if not ok and ns.Debug then ns.Debug("what's new:", tostring(err)) end
            end)
        end
        shared.waiting:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end

    shared.checked = true
    local list = self:Entries(false)
    -- Kept as shown even with the window turned off, so turning it back on
    -- never brings up a pile of old news.
    self:MarkSeen()
    if not self:IsOn() then return end
    if self:NoteDue() then
        table.insert(list, 1, self:NoteEntry())
        for _, db in ipairs(self:Stores()) do db.aboutNoteSeen = true end
    end
    if self:ThanksDue() then
        table.insert(list, 1, self:ThanksEntry())
        for _, db in ipairs(self:Stores()) do db.thanksSeen = true end
    end
    local at = 1
    while list[at] and list[at].note do at = at + 1 end
    for _, tip in ipairs(self:TakeTips()) do
        table.insert(list, at, tip)
        at = at + 1
    end
    if #list == 0 then return end
    WhatsNew.Owner():Open(list, true)
end

--- The command and the Settings button: open with each sister's newest,
--- or close it when it shows.
function WhatsNew:Toggle()
    local owner = WhatsNew.Owner()
    if owner.frame and owner.frame:IsShown() then
        owner:Close()
        return
    end
    local list = self:Entries(true)
    if #list == 0 then
        if ns.Print then ns.Print(L["there is no news to show yet."]) end
        return
    end
    owner:Open(list, false)
end

function WhatsNew:OnEnable()
    -- One timer for all five, started by whichever logs in first. No ticker.
    if shared.scheduled then return end
    shared.scheduled = true

    local timer = _G.C_Timer
    if not (timer and type(timer.After) == "function") then return end
    timer.After(self.DELAY, function()
        local ok, err = pcall(WhatsNew.Check, WhatsNew)
        if not ok and ns.Debug then ns.Debug("what's new:", tostring(err)) end
    end)
end

ns.RegisterCommand("whatsnew", L["open the What's New window for every Blackthornes addon"], function()
    WhatsNew:Toggle()
end)

--------------------------------------------------------------------------------
-- Looks
--------------------------------------------------------------------------------

-- The house palette, for an addon whose Theme lacks a colour. The Theme's
-- own come first, so the Blizzard window style recolours this window too.
local FALLBACK = {
    window     = { 0.055, 0.063, 0.078 },
    well       = { 0.039, 0.047, 0.063 },
    glass      = { 0.067, 0.075, 0.094 },
    glassAlt   = { 0.039, 0.047, 0.063 },
    glassHover = { 0.094, 0.106, 0.129 },
    border     = { 0.204, 0.224, 0.263 },
    accent     = { 0.784, 0.643, 0.302 },
    accentHi   = { 0.945, 0.831, 0.533 },
    gilt       = { 0.941, 0.824, 0.494 },
    ink        = { 0.110, 0.078, 0.024 },
    text       = { 0.902, 0.910, 0.925 },
    muted      = { 0.478, 0.502, 0.541 },
}

local function Color(key)
    local Theme = ns.Theme
    local colors = Theme and rawget(Theme, "colors")
    local c = type(colors) == "table" and colors[key]
    if type(c) ~= "table" then c = FALLBACK[key] or FALLBACK.text end
    return c[1], c[2], c[3]
end

local function Paint(texture, key, alpha)
    local r, g, b = Color(key)
    texture:SetColorTexture(r, g, b, alpha or 1)
end

local BASE_SIZES = { small = 11, normal = 12, large = 14, title = 16 }

--- A text size in points, Text size setting included.
local function Size(key)
    local Theme = ns.Theme
    local ok, size = pcall(function() return Theme.sizes[key] end)
    size = ok and tonumber(size)
    return size or BASE_SIZES[key] or 12
end

local function FontPath()
    local Theme = ns.Theme
    local path = Theme and rawget(Theme, "FONT")
    if type(path) == "string" then return path end
    local ok, found = pcall(function() return (GameFontNormal:GetFont()) end)
    return ok and found or [[Fonts\FRIZQT__.TTF]]
end

--- A label that wraps: never "...".
local function Text(parent, size, colorKey, layer)
    local label = parent:CreateFontString(nil, layer or "OVERLAY")
    pcall(label.SetFont, label, FontPath(), Size(size), "")
    label:SetTextColor(Color(colorKey))
    pcall(label.SetJustifyH, label, "LEFT")
    pcall(label.SetJustifyV, label, "TOP")
    pcall(label.SetWordWrap, label, true)
    pcall(label.SetNonSpaceWrap, label, true)
    label.sizeKey = size
    return label
end

--- How wide `label` wants to be, on one line.
local function Wide(label)
    local ok, width = pcall(label.GetUnboundedStringWidth, label)
    if ok and type(width) == "number" and width > 0 then return width end
    ok, width = pcall(label.GetStringWidth, label)
    if ok and type(width) == "number" then return width end
    return 0
end

--- How tall `label` is at the width it was given, wrapped.
local function Tall(label, width)
    local ok, height = pcall(label.GetStringHeight, label)
    if ok and type(height) == "number" and height > 0 then return height end
    local lineHeight = Size(label.sizeKey or "normal") + 3
    return math.max(1, math.ceil(Wide(label) / math.max(1, width))) * lineHeight
end

--- A region's width, or `default` when the client gives no number.
local function WidthOf(region, default)
    local ok, width = pcall(region.GetWidth, region)
    if ok and type(width) == "number" then return width end
    return default
end

local function Media(file)
    local Titan = ns.Titanforged
    local base = Titan and rawget(Titan, "MEDIA")
    if type(base) == "string" then return base .. file end
    return ([[Interface\AddOns\%s\Media\Frame\%s]]):format(ADDON_NAME, file)
end

local function Additive(texture) pcall(texture.SetBlendMode, texture, "ADD") end

--- Shade a texture from one alpha of a colour to another.
local function Fade(texture, orientation, key, fromAlpha, toAlpha)
    local r, g, b = Color(key)
    local Titan = ns.Titanforged
    local gradient = Titan and rawget(Titan, "Gradient")
    if type(gradient) == "function" then
        gradient(texture, orientation, { r, g, b }, { r, g, b }, fromAlpha, toAlpha)
    else
        texture:SetColorTexture(r, g, b, (fromAlpha + toAlpha) / 2)
    end
end

--- A gradient lit to `p` (0 to 1). On Forever a gradient keeps its light
--- whatever SetAlpha says, so it is drawn again at the faded alphas and
--- hidden at 0 (the same rule as Theme.LightGradient).
local function Light(texture, orientation, key, fromAlpha, toAlpha, p)
    p = math.max(0, math.min(1, tonumber(p) or 0))
    texture:SetShown(p > 0)
    if p > 0 then Fade(texture, orientation, key, fromAlpha * p, toAlpha * p) end
end

--------------------------------------------------------------------------------
-- Movement
--------------------------------------------------------------------------------

local function Moving()
    local Motion = ns.Motion
    if not (Motion and WhatsNew:IsMotionOn()) then return false end
    local ok, level = pcall(Motion.Level)
    return not (ok and level == "off")
end

--- A tween on the house clock, or its end at once with Motion off.
local function Animate(owner, slot, duration, apply, opts)
    if Moving() then
        ns.Motion:Run(owner, slot, duration, apply, opts)
        return
    end
    if ns.Motion and ns.Motion.Stop then pcall(ns.Motion.Stop, ns.Motion, owner, slot) end
    pcall(apply, 1)
    if opts and opts.done then pcall(opts.done) end
end

local function EaseBack()
    local Motion = ns.Motion
    return Motion and rawget(Motion, "EaseOutBack") or nil
end

--- A slow glow behind the main button, played by the game itself while the
--- window shows: no clock of ours runs for it.
local function Pulse(texture)
    local ok, group = pcall(texture.CreateAnimationGroup, texture)
    if not ok or type(group) ~= "table" then return nil end
    local made = pcall(function()
        group:SetLooping("BOUNCE")
        local alpha = group:CreateAnimation("Alpha")
        alpha:SetFromAlpha(0.2)
        alpha:SetToAlpha(0.95)
        alpha:SetDuration(1.1)
        alpha:SetSmoothing("IN_OUT")
    end)
    return made and group or nil
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

local PAD = 18         -- inside the rim, 6 pixels and more from the edge
local HEAD = 74        -- the kicker, the line under it and the divider
local FOOT = 54        -- the tick boxes and the Got it button
local CARD_GAP = 8
local ICON = 34
local SCROLL_STEP = 48
local THUMB = 6

local function Store()
    for _, db in ipairs(WhatsNew:Stores()) do return db end
    return nil
end

local function SavedScale()
    local db = Store()
    local percent = db and tonumber(db.whatsNewScale)
    if not percent then return 1 end
    return math.max(0.5, math.min(1.5, percent / 100))
end

function WhatsNew:Build()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", "BlackthornesWhatsNewFrame", UIParent)
    self.frame = frame
    frame:SetSize(self.WIDTH, 420)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    pcall(frame.SetFrameStrata, frame, "DIALOG")
    pcall(frame.SetToplevel, frame, true)
    pcall(frame.SetClampedToScreen, frame, true)
    frame:EnableMouse(true)
    pcall(frame.SetMovable, frame, true)
    pcall(frame.RegisterForDrag, frame, "LeftButton")
    frame:SetScript("OnDragStart", function(f) pcall(f.StartMoving, f) end)
    frame:SetScript("OnDragStop", function(f) pcall(f.StopMovingOrSizing, f) end)
    frame:Hide()

    local background = frame:CreateTexture(nil, "BACKGROUND", nil, -1)
    background:SetAllPoints(frame)
    Paint(background, "window", 0.97)

    -- The house frame: rim, plate and close gem. No portrait: the window
    -- speaks for all of them, not for the addon that drew it.
    local Titan = ns.Titanforged
    if Titan and Titan.Dress then
        local ok, trim = pcall(Titan.Dress, Titan, frame,
            { title = L["What's New"], close = function() WhatsNew:Close() end })
        if ok and trim and Titan.Reach then
            local fine, left, right, top, bottom = pcall(Titan.Reach, trim)
            if fine and left then pcall(frame.SetClampRectInsets, frame, -left, right, top, -bottom) end
        end
    end

    if type(_G.UISpecialFrames) == "table" then
        table.insert(_G.UISpecialFrames, "BlackthornesWhatsNewFrame")
    end

    -- Header: a kicker, a line under it, and a divider that draws outward.
    local kicker = Text(frame, "small", "accent")
    kicker:SetPoint("TOP", frame, "TOP", 0, -26)
    pcall(kicker.SetJustifyH, kicker, "CENTER")
    kicker:SetText(L["BLACKTHORNES ADDONS"])
    self.kicker = kicker

    local lede = Text(frame, "normal", "muted")
    lede:SetPoint("TOP", kicker, "BOTTOM", 0, -6)
    pcall(lede.SetJustifyH, lede, "CENTER")
    self.lede = lede

    local divider = CreateFrame("Frame", nil, frame)
    divider:SetHeight(9)
    divider:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(HEAD - 12))
    divider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -(HEAD - 12))
    local gem = divider:CreateTexture(nil, "ARTWORK", nil, 2)
    gem:SetSize(7, 7)
    gem:SetPoint("CENTER")
    Paint(gem, "accentHi")
    pcall(gem.SetRotation, gem, math.pi / 4)
    local leftLine = divider:CreateTexture(nil, "ARTWORK")
    leftLine:SetHeight(1)
    leftLine:SetPoint("RIGHT", gem, "LEFT", -5, 0)
    Fade(leftLine, "HORIZONTAL", "accent", 0, 0.9)
    local rightLine = divider:CreateTexture(nil, "ARTWORK")
    rightLine:SetHeight(1)
    rightLine:SetPoint("LEFT", gem, "RIGHT", 5, 0)
    Fade(rightLine, "HORIZONTAL", "accent", 0.9, 0)
    local shine = divider:CreateTexture(nil, "ARTWORK", nil, 1)
    shine:SetTexture(Media("Glow"))
    shine:SetSize(60, 18)
    shine:SetPoint("CENTER")
    shine:SetVertexColor(Color("accentHi"))
    Additive(shine)
    self.divider = { gem = gem, left = leftLine, right = rightLine, shine = shine }

    -- The list, in a well, scrolling when it is taller than the screen allows.
    local well = CreateFrame("Frame", nil, frame)
    well:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -HEAD)
    well:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, FOOT)
    local wellFill = well:CreateTexture(nil, "BACKGROUND")
    wellFill:SetAllPoints(well)
    Paint(wellFill, "well", 0.95)
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local edge = well:CreateTexture(nil, "BORDER")
        Paint(edge, "border", 0.8)
        if side == "TOP" or side == "BOTTOM" then
            edge:SetHeight(1)
            edge:SetPoint(side .. "LEFT")
            edge:SetPoint(side .. "RIGHT")
        else
            edge:SetWidth(1)
            edge:SetPoint("TOP" .. side)
            edge:SetPoint("BOTTOM" .. side)
        end
    end
    self.well = well

    local scroll = CreateFrame("ScrollFrame", nil, well)
    scroll:SetPoint("TOPLEFT", well, "TOPLEFT", 1, -1)
    scroll:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -1, 1)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1)
    pcall(scroll.SetScrollChild, scroll, child)
    pcall(scroll.EnableMouseWheel, scroll, true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        WhatsNew:ScrollTo((WhatsNew.offset or 0) - (tonumber(delta) or 0) * SCROLL_STEP)
    end)
    self.scroll, self.child = scroll, child

    -- A slim gold thumb, dragged or wheeled, shown only when it scrolls.
    local track = well:CreateTexture(nil, "ARTWORK")
    track:SetWidth(2)
    track:SetPoint("TOPRIGHT", well, "TOPRIGHT", -5, -6)
    track:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -5, 6)
    Paint(track, "border", 0.6)
    local thumb = CreateFrame("Button", nil, well)
    thumb:SetWidth(THUMB + 6)
    local thumbFace = thumb:CreateTexture(nil, "OVERLAY")
    thumbFace:SetPoint("TOP")
    thumbFace:SetPoint("BOTTOM")
    thumbFace:SetWidth(THUMB)
    Paint(thumbFace, "accent", 0.85)
    thumb.face = thumbFace
    thumb:SetScript("OnEnter", function() Paint(thumbFace, "accentHi", 1) end)
    thumb:SetScript("OnLeave", function() if not thumb.dragging then Paint(thumbFace, "accent", 0.85) end end)
    thumb:SetScript("OnMouseDown", function()
        local _, y = GetCursorPosition()
        thumb.dragging = { y = y, offset = WhatsNew.offset or 0 }
        -- Follows the cursor only while held: nothing runs at rest.
        thumb:SetScript("OnUpdate", function()
            local drag = thumb.dragging
            if not drag then return end
            local _, now = GetCursorPosition()
            local scale = frame:GetEffectiveScale()
            local moved = (drag.y - now) / ((type(scale) == "number" and scale > 0) and scale or 1)
            local room = (WhatsNew.trackRoom or 1)
            WhatsNew:ScrollTo(drag.offset + moved / math.max(1, room) * (WhatsNew.maxOffset or 0))
        end)
    end)
    thumb:SetScript("OnMouseUp", function()
        thumb.dragging = nil
        thumb:SetScript("OnUpdate", nil)
        Paint(thumbFace, "accent", 0.85)
    end)
    self.track, self.thumb = track, thumb

    -- Footer: the two switches and the main button.
    local Widgets = ns.Widgets
    self.popupBox = Widgets.CreateCheckbox(frame, L["Show after updates"], function(checked)
        WhatsNew:SetOn(checked)
        if ns.SettingsUI and ns.SettingsUI.Refresh then pcall(ns.SettingsUI.Refresh, ns.SettingsUI) end
    end, self:IsOn())
    self.popupBox:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, 19)

    self.motionBox = Widgets.CreateCheckbox(frame, L["Motion"], function(checked)
        WhatsNew:SetMotionOn(checked)
        if ns.SettingsUI and ns.SettingsUI.Refresh then pcall(ns.SettingsUI.Refresh, ns.SettingsUI) end
    end, self:IsMotionOn())
    self.motionBox:SetPoint("LEFT", self.popupBox, "RIGHT", 14, 0)

    local measure = Text(frame, "normal", "text")
    measure:SetText(L["Got It"])
    local buttonWidth = math.max(112, math.ceil(Wide(measure)) + 40)
    measure:Hide()
    local done = Widgets.CreateButton(frame, L["Got It"], function() WhatsNew:Close() end,
        { primary = true, width = buttonWidth, height = 26 })
    done:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, 15)
    self.doneButton = done

    local glow = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    glow:SetTexture(Media("Glow"))
    glow:SetPoint("TOPLEFT", done, "TOPLEFT", -18, 14)
    glow:SetPoint("BOTTOMRIGHT", done, "BOTTOMRIGHT", 18, -14)
    glow:SetVertexColor(Color("accent"))
    Additive(glow)
    glow:SetAlpha(0)
    self.doneGlow = glow
    self.doneGlowAnim = Pulse(glow)

    -- Wide enough for the footer in any language.
    local footer = PAD + WidthOf(self.popupBox, 0) + 14 + WidthOf(self.motionBox, 0)
        + 20 + buttonWidth + PAD
    if footer > self.WIDTH then frame:SetWidth(footer) end

    -- The house size grip, where the addon has it.
    if Widgets.CreateSizeGrip then
        pcall(Widgets.CreateSizeGrip, frame, {
            get = function()
                local db = Store()
                return db and db.whatsNewScale
            end,
            save = function(percent)
                for _, db in ipairs(WhatsNew:Stores()) do db.whatsNewScale = percent end
            end,
            name = "window",
        })
    end

    frame:SetScript("OnHide", function()
        -- Closed with the scroll thumb held: it never hears the mouse come up.
        if WhatsNew.thumb then
            WhatsNew.thumb.dragging = nil
            WhatsNew.thumb:SetScript("OnUpdate", nil)
        end
        if WhatsNew.doneGlowAnim then pcall(WhatsNew.doneGlowAnim.Stop, WhatsNew.doneGlowAnim) end
        WhatsNew.closing = nil
        pcall(frame.SetAlpha, frame, 1)
    end)

    self.cards = {}
    return frame
end

--------------------------------------------------------------------------------
-- Cards
--------------------------------------------------------------------------------

local function CardHover(card, on)
    local target = on and 1 or 0
    local function Apply(p)
        Light(card.wash, "HORIZONTAL", "accent", 0.18, 0, p)
        card.stripe:SetAlpha(0.8 + 0.2 * p)
        card.edge:SetAlpha(0.35 + 0.4 * p)
    end
    if Moving() and ns.Motion.Blend then
        ns.Motion:Blend(card, "hover", target, on and 0.12 or 0.2, Apply)
    else
        Apply(target)
    end
end

function WhatsNew:Card(index)
    local card = self.cards[index]
    if card then return card end

    card = CreateFrame("Frame", nil, self.child)
    pcall(card.SetClipsChildren, card, true)
    card:EnableMouse(true)
    card:SetScript("OnEnter", function(c) CardHover(c, true) end)
    card:SetScript("OnLeave", function(c) CardHover(c, false) end)
    -- The list scrolls under the cards too.
    pcall(card.EnableMouseWheel, card, true)
    card:SetScript("OnMouseWheel", function(_, delta)
        WhatsNew:ScrollTo((WhatsNew.offset or 0) - (tonumber(delta) or 0) * SCROLL_STEP)
    end)

    card.bg = card:CreateTexture(nil, "BACKGROUND")
    card.bg:SetAllPoints(card)

    -- The gold wash, lit only under the mouse.
    card.wash = card:CreateTexture(nil, "BACKGROUND", nil, 1)
    card.wash:SetAllPoints(card)
    Light(card.wash, "HORIZONTAL", "accent", 0.18, 0, 0)

    card.stripe = card:CreateTexture(nil, "ARTWORK")
    card.stripe:SetWidth(2)
    card.stripe:SetPoint("TOPLEFT")
    card.stripe:SetPoint("BOTTOMLEFT")
    Paint(card.stripe, "accentHi")
    card.stripe:SetAlpha(0.8)
    -- The neon edge: a soft gold light spilling in from the stripe.
    card.edge = card:CreateTexture(nil, "BACKGROUND", nil, 2)
    card.edge:SetWidth(26)
    card.edge:SetPoint("TOPLEFT", card, "TOPLEFT", 2, 0)
    card.edge:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 2, 0)
    Fade(card.edge, "HORIZONTAL", "accent", 0.16, 0)
    card.edge:SetAlpha(0.35)

    card.rule = card:CreateTexture(nil, "ARTWORK")
    card.rule:SetHeight(1)
    card.rule:SetPoint("BOTTOMLEFT")
    card.rule:SetPoint("BOTTOMRIGHT")
    Paint(card.rule, "border", 0.5)

    -- The addon's icon in a gold ring, with a soft light behind it.
    card.halo = card:CreateTexture(nil, "BORDER")
    card.halo:SetTexture(Media("Glow"))
    card.halo:SetSize(ICON + 30, ICON + 30)
    card.halo:SetVertexColor(Color("accent"))
    Additive(card.halo)
    card.ring = card:CreateTexture(nil, "ARTWORK", nil, 1)
    Paint(card.ring, "accent")
    card.icon = card:CreateTexture(nil, "ARTWORK", nil, 2)
    pcall(card.icon.SetTexCoord, card.icon, 0.08, 0.92, 0.08, 0.92)

    card.title = Text(card, "title", "accentHi")

    card.pill = CreateFrame("Frame", nil, card)
    -- The version on a dark tag in a fine gold edge.
    card.pill.fill = card.pill:CreateTexture(nil, "BACKGROUND")
    card.pill.fill:SetAllPoints(card.pill)
    Paint(card.pill.fill, "ink", 0.95)
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local edge = card.pill:CreateTexture(nil, "BORDER")
        Paint(edge, "accent", 0.8)
        if side == "TOP" or side == "BOTTOM" then
            edge:SetHeight(1)
            edge:SetPoint(side .. "LEFT")
            edge:SetPoint(side .. "RIGHT")
        else
            edge:SetWidth(1)
            edge:SetPoint("TOP" .. side)
            edge:SetPoint("BOTTOM" .. side)
        end
    end
    card.pill.text = Text(card.pill, "small", "gilt")
    card.pill.text:SetPoint("CENTER", card.pill, "CENTER", 0, 0)

    -- A light that crosses the card once as it arrives.
    card.sweep = card:CreateTexture(nil, "OVERLAY")
    card.sweep:SetSize(110, 140)
    card.sweep:SetTexture(Media("Glow"))
    card.sweep:SetVertexColor(Color("accentHi"))
    Additive(card.sweep)
    card.sweep:SetAlpha(0)

    card.lines = {}
    self.cards[index] = card
    return card
end

local function Line(card, index)
    local line = card.lines[index]
    if line then return line end
    line = {}
    line.dot = card:CreateTexture(nil, "ARTWORK", nil, 3)
    line.dot:SetSize(5, 5)
    Paint(line.dot, "accent")
    pcall(line.dot.SetRotation, line.dot, math.pi / 4)
    line.text = Text(card, "normal", "text")
    line.label = Text(card, "small", "muted")
    card.lines[index] = line
    return line
end

--- Fill a card for one sister, `width` wide. Returns its height.
local function Fill(card, entry, width, index)
    Paint(card.bg, index % 2 == 1 and "glass" or "glassAlt", 0.96)
    card:SetWidth(width)

    local left = 14
    card.icon:SetTexture(entry.addon.icon)
    card.icon:ClearAllPoints()
    card.icon:SetPoint("CENTER", card, "TOPLEFT", left + ICON / 2, -(14 + ICON / 2))
    card.icon:SetSize(ICON - 2, ICON - 2)
    card.ring:ClearAllPoints()
    card.ring:SetPoint("CENTER", card.icon, "CENTER")
    card.ring:SetSize(ICON, ICON)
    card.halo:ClearAllPoints()
    card.halo:SetPoint("CENTER", card.icon, "CENTER")
    card.halo:SetAlpha(0.35)

    local column = left + ICON + 14
    local room = width - column - 14

    local pillWidth = 0
    if entry.note then
        card.pill:Hide()
    else
        card.pill:Show()
        card.pill.text:SetText("v" .. tostring(entry.sections[1].version))
        pillWidth = math.ceil(Wide(card.pill.text)) + 14
        card.pill:SetSize(pillWidth, Size("small") + 7)
    end

    -- The name, wrapping before it would run into the version.
    card.title:SetText(entry.addon.title)
    local titleWidth = math.min(math.ceil(Wide(card.title)) + 2, math.max(80, room - pillWidth - 10))
    card.title:SetWidth(titleWidth)
    card.title:ClearAllPoints()
    card.title:SetPoint("TOPLEFT", card, "TOPLEFT", column, -15)
    card.pill:ClearAllPoints()
    card.pill:SetPoint("TOPLEFT", card.title, "TOPRIGHT", 10, 1)

    local y = -(15 + Tall(card.title, titleWidth) + 10)
    local used = 0
    -- The note: its paragraphs, no dots.
    for _, words in ipairs(entry.note and entry.paragraphs or {}) do
        used = used + 1
        local line = Line(card, used)
        line.label:Hide()
        line.dot:Hide()
        line.text:SetText(words)
        line.text:SetWidth(room)
        line.text:ClearAllPoints()
        line.text:SetPoint("TOPLEFT", card, "TOPLEFT", column, y)
        line.text:Show()
        line.y = y
        y = y - Tall(line.text, room) - 9
    end
    -- A one-time card's button, with a word beside it.
    -- rawget: a card's own fields only, never anything a frame answers.
    local actions, hint = rawget(card, "actions"), rawget(card, "hint")
    for _, button in pairs(actions or {}) do button:Hide() end
    if hint then hint:Hide() end
    if entry.button and type(entry.run) == "function" then
        local Widgets = ns.Widgets
        if not actions then actions = {} card.actions = actions end
        local button = actions[entry.button]
        if not button and Widgets and Widgets.CreateButton then
            local measure = Text(card, "normal", "text")
            measure:SetText(entry.button)
            local wide = math.max(110, math.ceil(Wide(measure)) + 32)
            measure:Hide()
            button = Widgets.CreateButton(card, entry.button, function() end,
                { primary = true, width = wide, height = 24 })
            actions[entry.button] = button
        end
        if button then
            button:SetScript("OnClick", function()
                local ok, err = pcall(entry.run)
                if not ok and ns.Debug then ns.Debug("what's new:", tostring(err)) end
                if not entry.stay then WhatsNew.Owner():Close() end
            end)
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", card, "TOPLEFT", column, y - 1)
            button:Show()
            local tall = 26
            if entry.hint then
                if not hint then hint = Text(card, "small", "muted") card.hint = hint end
                local wide = math.max(80, room - WidthOf(button, 110) - 12)
                hint:SetText(entry.hint)
                hint:SetWidth(wide)
                hint:ClearAllPoints()
                hint:SetPoint("TOPLEFT", button, "TOPRIGHT", 12, -1)
                hint:Show()
                tall = math.max(tall, Tall(hint, wide) + 4)
            end
            y = y - tall - 8
        end
    end
    for s, section in ipairs(entry.sections or {}) do
        for n, words in ipairs(section.lines) do
            used = used + 1
            local line = Line(card, used)
            line.label:Hide()
            if n == 1 and s > 1 then
                -- An earlier release the player skipped, under its number.
                line.label:SetText(Format(L["Also in %s"], "v" .. tostring(section.version)))
                line.label:SetWidth(room)
                line.label:ClearAllPoints()
                line.label:SetPoint("TOPLEFT", card, "TOPLEFT", column, y - 2)
                line.label:Show()
                y = y - Tall(line.label, room) - 8
            end
            line.text:SetText(words)
            line.text:SetWidth(room - 14)
            line.text:ClearAllPoints()
            line.text:SetPoint("TOPLEFT", card, "TOPLEFT", column + 14, y)
            line.text:Show()
            line.dot:ClearAllPoints()
            line.dot:SetPoint("CENTER", card, "TOPLEFT", column + 3, y - math.floor(Size("normal") / 2) - 1)
            line.dot:Show()
            line.y = y
            y = y - Tall(line.text, room - 14) - 7
        end
    end
    for n = used + 1, #card.lines do
        card.lines[n].text:Hide()
        card.lines[n].dot:Hide()
        card.lines[n].label:Hide()
    end
    card.used = used

    local height = math.max(-y + 8, 14 + ICON + 16)
    card:SetHeight(height)
    card.sweep:SetSize(110, height * 2)
    return height
end

--------------------------------------------------------------------------------
-- Opening, scrolling and closing
--------------------------------------------------------------------------------

local function ScreenHeight()
    local ok, height = pcall(UIParent.GetHeight, UIParent)
    if ok and type(height) == "number" and height > 0 then return height end
    return 768
end

function WhatsNew:ScrollTo(offset)
    local most = self.maxOffset or 0
    offset = math.max(0, math.min(most, tonumber(offset) or 0))
    self.offset = offset
    if self.scroll then pcall(self.scroll.SetVerticalScroll, self.scroll, offset) end
    if self.thumb and most > 0 then
        local room = self.trackRoom or 1
        self.thumb:ClearAllPoints()
        self.thumb:SetPoint("TOPRIGHT", self.well, "TOPRIGHT", -3, -6 - room * (offset / most))
    end
end

--- Open on `list` (from Entries). `auto`: the window came up by itself.
function WhatsNew:Open(list, auto)
    local frame = self:Build()
    self.list = list
    if ns.Motion and ns.Motion.Stop then pcall(ns.Motion.Stop, ns.Motion, frame) end
    self.closing = nil

    local onlyNote = #list > 0
    for _, entry in ipairs(list) do
        if not entry.note then onlyNote = false end
    end
    self.lede:SetText(onlyNote and L["A note from Blackthornes."]
        or auto and L["Here's what changed since you last played."]
        or L["The newest changes in each of your Blackthornes addons."])
    local width = WidthOf(frame, self.WIDTH)
    self.lede:SetWidth(width - 2 * PAD)

    self.popupBox:SetChecked(self:IsOn())
    self.motionBox:SetChecked(self:IsMotionOn())

    -- Lay the cards out, then fit the window to them, up to most of the screen.
    local inner = width - 2 * PAD - 2
    local most = math.floor(math.min(620, ScreenHeight() * 0.8)) - HEAD - FOOT
    local function Layout(cardWidth)
        local y = 0
        for index, entry in ipairs(list) do
            local card = self:Card(index)
            local height = Fill(card, entry, cardWidth, index)
            card.baseY = -y
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", self.child, "TOPLEFT", 0, card.baseY)
            card:SetAlpha(1)
            card:Show()
            y = y + height + (index < #list and CARD_GAP or 0)
        end
        for index = #list + 1, #self.cards do self.cards[index]:Hide() end
        return y
    end

    local total = Layout(inner)
    local scrolls = total > most
    if scrolls then total = Layout(inner - THUMB - 10) end
    self.child:SetWidth(scrolls and inner - THUMB - 10 or inner)
    self.child:SetHeight(math.max(1, total))

    local view = math.min(total, most)
    frame:SetHeight(HEAD + view + 2 + FOOT)
    self.maxOffset = math.max(0, total - view)
    self.trackRoom = math.max(1, view - 12 - math.max(24, view * view / math.max(1, total)))
    self.thumb:SetHeight(math.max(24, view * view / math.max(1, total)))
    self.thumb:SetShown(scrolls)
    pcall(self.track.SetShown, self.track, scrolls)
    self:ScrollTo(0)

    frame:Show()
    self:Arrive()
end

--- The window rises in, the divider draws out, the cards slide up one by one
--- and a light crosses each. With Motion off it all lands at once.
function WhatsNew:Arrive()
    local frame = self.frame
    local base = SavedScale()
    local back = EaseBack()

    Animate(frame, "open", 0.55, function(p)
        frame:SetAlpha(math.min(1, p * 1.6))
        pcall(frame.SetScale, frame, base * (0.8 + 0.2 * p))
    end, { ease = back })

    local divider = self.divider
    local half = math.max(0, (WidthOf(frame, self.WIDTH) - 2 * PAD) / 2 - 10)
    Animate(divider.gem, "draw", 0.8, function(p)
        divider.left:SetWidth(math.max(0.1, half * p))
        divider.right:SetWidth(math.max(0.1, half * p))
        divider.shine:SetAlpha(math.sin(math.pi * p))
    end, { delay = 0.25 })

    for index = 1, #(self.list or {}) do
        local card = self.cards[index]
        local delay = 0.45 + (index - 1) * 0.22
        local function Place(offset)
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", self.child, "TOPLEFT", offset, card.baseY - offset * 0.5)
        end
        card:SetAlpha(0)
        Animate(card, "arrive", 0.6, function(p)
            card:SetAlpha(math.min(1, p * 1.4))
            Place((1 - p) * 70)
        end, {
            ease = back,
            delay = delay,
            done = function()
                Place(0)
                WhatsNew:Sweep(card)
            end,
        })
        Animate(card.icon, "pop", 0.5, function(p)
            local size = (ICON - 2) * (0.2 + 0.8 * p)
            card.icon:SetSize(size, size)
            card.ring:SetSize(size + 2, size + 2)
            card.halo:SetAlpha(0.35 + 0.65 * math.sin(math.pi * math.min(1, p)))
        end, { delay = delay + 0.25, ease = back })
        for n = 1, card.used or 0 do
            local line = card.lines[n]
            Animate(line.text, "arrive", 0.4, function(p)
                line.text:SetAlpha(p)
                line.dot:SetAlpha(p)
                line.label:SetAlpha(p)
            end, { delay = delay + 0.35 + n * 0.12 })
        end
    end

    local glow, anim = self.doneGlow, self.doneGlowAnim
    local settle = 0.9 + #(self.list or {}) * 0.22
    Animate(glow, "glow", 0.5, function(p) glow:SetAlpha(0.6 * p) end, {
        delay = settle,
        done = function()
            if anim and Moving() and frame:IsShown() then pcall(anim.Play, anim) end
        end,
    })
end

--- The light across a card, once.
function WhatsNew:Sweep(card)
    if not Moving() then
        card.sweep:SetAlpha(0)
        return
    end
    local width = WidthOf(card, 0)
    if width <= 0 then return end
    Animate(card.sweep, "sweep", 1.1, function(p)
        card.sweep:ClearAllPoints()
        card.sweep:SetPoint("CENTER", card, "LEFT", -60 + (width + 120) * p, 0)
        card.sweep:SetAlpha(math.sin(math.pi * p) * 0.6)
    end, { ease = false, done = function() card.sweep:SetAlpha(0) end })
end

function WhatsNew:Close()
    local frame = self.frame
    if not (frame and frame:IsShown()) or self.closing then return end
    if not Moving() then
        frame:Hide()
        return
    end
    self.closing = true
    local base = SavedScale()
    ns.Motion:Run(frame, "open", 0.16, function(p)
        frame:SetAlpha(1 - p)
        pcall(frame.SetScale, frame, base * (1 - 0.03 * p))
    end, {
        ease = false,
        done = function()
            frame:Hide()
            pcall(frame.SetScale, frame, base)
        end,
    })
end
