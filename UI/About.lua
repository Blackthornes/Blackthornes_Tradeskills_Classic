-- UI/About.lua
-- The About page in Settings, and the note at the top of What's New (asked
-- 2026-10-13): how the addons are made, the version, the Discord, how to
-- report a bug, a thank-you to players and the other Blackthornes addons.
--
-- This file is the same in all five addons (Farmer, Tradeskills, Equipment,
-- Pets and Butler); a fix to it belongs in all five.
--
-- It only builds pieces. Each addon's Settings places them on its own About
-- page: About:Note(parent, width) and About:Info(parent, width), each a frame
-- whose height is `fixedHeight`. UI/WhatsNew.lua reads About.NOTE for its
-- one-time card. Built once, when Settings is built; nothing runs after.

local ADDON_NAME, ns = ...

local About = {}
ns.About = About

-- The words through the addon's translation table where it has one (ns.L,
-- Locale/Locale.lua), else in English, so this file stays the same in all.
local L = ns.L or setmetatable({}, { __index = function(_, key) return key end })
local Format = rawget(L, "Format")
if type(Format) ~= "function" then Format = string.format end

About.DISCORD = "https://discord.gg/f2geDecrw2"

--- The note, a paragraph each.
About.NOTE = {
    L["A few of you have asked if AI is used in the creation of my AddOns. It is."],
    L["I've spent 25 years developing software and working in IT, and I recommend developers today use it, but with care and intention. For me that means I decide what gets built, I set the rules the code has to follow, I review the code, and I test changes in game myself. AI helps me write the code, run the tests and track down bugs."],
    L["Used well, it means more features, faster bug fixes and quicker turnaround on your requests. A lot of what's in these addons started as an idea or a bug report from a player."],
    L["If you have an idea or something isn't working, come find me on my Discord at discord.gg/f2geDecrw2. I read every comment and report."],
}

--- The thank-you at the very top of What's New, once per account, a
--- paragraph each (the owner, 2026-10-23).
About.THANKS = {
    L["Thank you to everyone who sent ideas and bug reports. You helped shape every one of these add-ons. Without you, they would not be what they are today."],
    L["There are still some bugs to work out, and those fixes will come with time. If you find one, jump on our Discord and share it. You can find the link on the About page in Settings. Every message gets read."],
}

-- The name each addon goes by, for "Blackthornes Farmer 0.31.0".
About.TITLES = {
    Blackthornes_Farmer = "Blackthornes Farmer",
    Blackthornes_TS = "Blackthornes Tradeskills",
    Blackthornes_Equipment = "Blackthornes Equipment",
    Blackthornes_Pets = "Blackthornes Pets",
    Blackthornes_Butler = "Blackthornes Butler",
}

local GAP = 10

--------------------------------------------------------------------------------
-- Pieces
--------------------------------------------------------------------------------

local FALLBACK = {
    well = { 0.039, 0.047, 0.063 },
    border = { 0.204, 0.224, 0.263 },
}

local function Color(key)
    local colors = ns.Theme and rawget(ns.Theme, "colors")
    local c = type(colors) == "table" and colors[key]
    if type(c) ~= "table" then c = FALLBACK[key] or { 0.9, 0.9, 0.9 } end
    return c[1], c[2], c[3]
end

--- How tall a wrapped label is at `width`, or a fair guess when the client
--- cannot say yet.
local function Tall(label, width, size)
    local ok, height = pcall(label.GetStringHeight, label)
    if ok and type(height) == "number" and height > 0 then return math.ceil(height) end
    local text = label:GetText() or ""
    local perLine = math.max(1, math.floor(width / ((size or 11) * 0.5)))
    return math.max(1, math.ceil(#text / perLine)) * ((size or 11) + 3)
end

local function SizeOf(key)
    local ok, size = pcall(function() return ns.Theme.sizes[key] end)
    return ok and tonumber(size) or 11
end

--- A wrapped label under `y` in `holder`. Returns the y under it.
local function Words(holder, y, width, text, size, color)
    local label = ns.Theme.CreateLabel(holder, size or "small", color or "text")
    pcall(label.SetWordWrap, label, true)
    pcall(label.SetJustifyV, label, "TOP")
    label:SetWidth(width)
    label:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -y)
    label:SetText(text)
    return y + Tall(label, width, SizeOf(size or "small")), label
end

--- A small gold heading over a line of words.
local function Titled(holder, y, width, title, text)
    y = Words(holder, y, width, title, "tiny", "accent")
    y = y + 3
    return Words(holder, y, width, text, "small", "text")
end

--- A box holding `text` for the player to copy: the game cannot open a
--- link, so a click selects it all for Ctrl+C. Typing never changes it.
local function CopyBox(holder, y, width, text)
    local box = CreateFrame("EditBox", nil, holder)
    box:SetSize(width, 22)
    box:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -y)
    pcall(box.SetAutoFocus, box, false)
    local sample = ns.Theme.CreateLabel(holder, "small", "text")
    local ok, font, size, flags = pcall(sample.GetFont, sample)
    if ok and font then pcall(box.SetFont, box, font, size, flags or "") end
    sample:Hide()
    pcall(box.SetTextInsets, box, 6, 6, 0, 0)
    box:SetTextColor(Color("accentHi"))

    local fill = box:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints(box)
    local r, g, b = Color("well")
    fill:SetColorTexture(r, g, b, 0.95)
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local edge = box:CreateTexture(nil, "BORDER")
        local er, eg, eb = Color("border")
        edge:SetColorTexture(er, eg, eb, 0.9)
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

    box:SetText(text)
    pcall(box.SetCursorPosition, box, 0)
    box:SetScript("OnTextChanged", function(self, typed)
        if typed then self:SetText(text) self:HighlightText() end
    end)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    box:SetScript("OnEditFocusLost", function(self) self:HighlightText(0, 0) end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return y + 22, box
end

local function Holder(parent, width)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetWidth(width)
    return holder
end

local function Finish(holder, y)
    holder.fixedHeight = math.ceil(y)
    holder:SetHeight(holder.fixedHeight)
    return holder
end

--------------------------------------------------------------------------------
-- The two columns
--------------------------------------------------------------------------------

--- The note, a paragraph each, `width` wide.
function About:Note(parent, width)
    local holder = Holder(parent, width)
    local y = 0
    for index, paragraph in ipairs(self.NOTE) do
        if index > 1 then y = y + GAP end
        y = Words(holder, y, width, paragraph, "small", "text")
    end
    holder.words = table.concat(self.NOTE, " ")
    return Finish(holder, y)
end

--- This addon's version, the Discord, reporting a bug, the thank-you, the
--- What's New button and the other Blackthornes addons.
function About:Info(parent, width)
    local holder = Holder(parent, width)
    local title = self.TITLES[ADDON_NAME] or ADDON_NAME
    local y = Words(holder, 0, width, Format(L["%s, version %s"], title, tostring(ns.VERSION or "")),
        "small", "accentHi")

    y = y + GAP + 2
    y = Words(holder, y, width, L["DISCORD"], "tiny", "accent")
    y = y + 4
    y = CopyBox(holder, y, width, self.DISCORD)
    y = y + 3
    y = Words(holder, y, width, L["Click the box, then press Ctrl+C to copy the link."], "tiny", "muted")

    y = y + GAP
    y = Titled(holder, y, width, L["REPORT A BUG"],
        L["Post it on my Discord with what you were doing when it happened. I read every comment and report."])

    y = y + GAP
    y = Titled(holder, y, width, L["THANK YOU"],
        L["A lot of what's here started as a player's idea or bug report. Thank you to everyone who sent one in."])

    y = y + GAP + 2
    local Widgets = ns.Widgets
    if ns.WhatsNew and Widgets and Widgets.CreateButton then
        local measure = ns.Theme.CreateLabel(holder, "small", "text")
        measure:SetText(L["What's New"])
        local ok, wide = pcall(measure.GetStringWidth, measure)
        measure:Hide()
        wide = ok and type(wide) == "number" and wide or 70
        local button = Widgets.CreateButton(holder, L["What's New"], function()
            ns.WhatsNew:Toggle()
        end, { width = math.max(110, math.ceil(wide) + 30), height = 22 })
        button:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -y)
        y = y + 22
    end

    local Sisters = ns.SisterNote
    if Sisters and type(Sisters.ADDONS) == "table" then
        y = y + GAP + 4
        y = Words(holder, y, width, L["BLACKTHORNES ADDONS"], "tiny", "accent")
        for _, entry in ipairs(Sisters.ADDONS) do
            y = y + 5
            local state = Sisters.State and Sisters.State(entry.folder)
            local status = state == "loaded" and L["installed"]
                or state == "off" and L["turned off"]
                or state == "missing" and L["not installed"]
                or nil
            local line = status and Format(L["%s (%s)"], entry.title, status) or entry.title
            y = Words(holder, y, width, line, "small", state == "loaded" and "text" or "muted")
            if entry.adds then
                y = y + 1
                y = Words(holder, y, width, entry.adds, "tiny", "muted")
            end
        end
    end

    holder.words = table.concat({ title, "Discord", L["REPORT A BUG"], L["THANK YOU"],
        L["What's New"], L["BLACKTHORNES ADDONS"] }, " ")
    return Finish(holder, y)
end
