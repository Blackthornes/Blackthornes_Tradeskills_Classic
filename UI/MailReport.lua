-- Blackthornes Tradeskills -- UI/MailReport.lua
-- The report after a mailbox visit, and the running tally while you are there.
--
-- Asked 2026-09-28: "better mail tracking and reporting after mails are
-- collected, needs to look nextgen and keep with the dopamine hits as we're
-- doing with farmer". So collecting mail is a moment: a tally over the
-- mailbox counts up with a "+3g" rising off it each time gold lands, and when
-- you walk away a report opens with the total counting up to the sound of
-- coins, where it came from, the best sale lit gold, what came back, and a
-- fanfare when the visit beats your best haul or holds your best sale ever.
--
-- Logic/MailHaul.lua works out what was collected; this only draws it.

local ADDON, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local MailReport = {}
ns.MailReport = MailReport

local WIDTH = 380
local PAD = 16
local ROW = 20
local MAX_SALE_ROWS = 5

-- A row's width inside the padding; the room an items row's list gets when
-- its label cannot be measured; and the width of a sale's amount.
local ROW_WIDTH = WIDTH - 2 * PAD
local ITEMS_ROOM = ROW_WIDTH - 150
local SALE_VALUE = 110

local BRIGHT_GOLD = { 1, 0.84, 0.32 }

-- The addon's own sounds, made by tools/make_sounds.py. A file added since
-- the game started is only found after a full restart; until then the
-- game's own sounds play instead.
local MEDIA = ([[Interface\AddOns\%s\Media\Sounds\]]):format(ADDON)
MailReport.SOUNDS = {
    haul = MEDIA .. "mail-haul.ogg",
    record = MEDIA .. "mail-record.ogg",
}

-- The game's own, by id, for when the files cannot play: coins from the loot
-- window, then the achievement toast and the level-up chime.
local FALLBACK = {
    haul = { 120, 878 },
    record = { 12891, 888 },
}

--------------------------------------------------------------------------------
-- Sound
--------------------------------------------------------------------------------

--- Play one of the report's sounds. True if the game said it would.
function MailReport.Play(which)
    -- Settings: SOUNDS, Mail report. The report itself still shows.
    if ns.Config and ns.Config:Get("mailReportSound") == false then return false end

    if type(PlaySoundFile) == "function" then
        local ok, willPlay = pcall(PlaySoundFile, MailReport.SOUNDS[which], "Master")
        if ok and willPlay then return true end
    end

    if type(PlaySound) == "function" then
        for _, id in ipairs(FALLBACK[which] or {}) do
            local ok, willPlay = pcall(PlaySound, id, "Master")
            if ok and willPlay then return true end
        end
    end

    return false
end

--------------------------------------------------------------------------------
-- Motion
--------------------------------------------------------------------------------

local effects = {}
local driver

local function EaseOut(p)
    return 1 - (1 - p) ^ 3
end

local function Step(elapsed)
    local live = {}

    for _, effect in ipairs(effects) do
        effect.age = effect.age + (tonumber(elapsed) or 0)

        if effect.age < 0 then
            live[#live + 1] = effect
        else
            local p = math.min(1, effect.age / effect.duration)
            local ok, err = pcall(effect.apply, p)

            if not ok then
                ns.Debug("mail report effect dropped:", tostring(err))
                if effect.stop then pcall(effect.stop) end
            elseif p < 1 or effect.loop then
                if p >= 1 then effect.age = 0 end
                live[#live + 1] = effect
            end
        end
    end

    effects = live
    if #live == 0 and driver then driver:Hide() end
end

--- Start an effect: { slot, duration, delay, apply(p), stop(), loop }. A new
--- one in the same slot replaces the old.
function MailReport.Start(effect)
    for index = #effects, 1, -1 do
        if effect.slot and effects[index].slot == effect.slot then
            local old = table.remove(effects, index)
            if old.stop then pcall(old.stop) end
        end
    end

    effect.age = -(effect.delay or 0)
    effects[#effects + 1] = effect

    if not driver then
        driver = CreateFrame("Frame", nil, UIParent)
        driver:SetScript("OnUpdate", function(_, elapsed) Step(elapsed) end)
    end
    driver:Show()
end

--- Stop every effect whose slot starts with `prefix`, putting things back.
local function StopAll(prefix)
    local live = {}
    for _, effect in ipairs(effects) do
        if type(effect.slot) == "string" and effect.slot:sub(1, #prefix) == prefix then
            if effect.stop then pcall(effect.stop) end
        else
            live[#live + 1] = effect
        end
    end
    effects = live
end

--- A gold count running from `from` to `to` on `label`.
local function CountUp(slot, label, from, to, duration, delay, onDone)
    MailReport.Start({ slot = slot, duration = duration, delay = delay,
        apply = function(p)
            label:SetText(Util.FormatMoney(math.floor(from + (to - from) * EaseOut(p))))
            if p >= 1 and onDone then onDone() end
        end,
        stop = function() label:SetText(Util.FormatMoney(to)) end })
end

--- A label growing for a beat and settling back.
local function Pop(slot, label, size, delay)
    MailReport.Start({ slot = slot, duration = 0.35, delay = delay,
        apply = function(p)
            local grow = math.sin(p * math.pi) * 0.25
            pcall(label.SetFont, label, Theme.FONT, math.floor(size * (1 + grow) + 0.5), "OUTLINE")
        end,
        stop = function() pcall(label.SetFont, label, Theme.FONT, size, "OUTLINE") end })
end

--------------------------------------------------------------------------------
-- Text
--------------------------------------------------------------------------------

--- "1 sale" or "7 sales": `one` and `many` are the two wordings, each with
--- its %d, as L gives them.
local function Plural(n, one, many)
    return L.Format(n == 1 and one or many, n)
end

--- "from 7 sales, 2 refunded bids and 1 letter"
function MailReport.Sources(haul)
    local parts = {}

    if (haul.salesCount or 0) > 0 then parts[#parts + 1] = Plural(haul.salesCount, L["%d sale"], L["%d sales"]) end

    if (haul.gold and haul.gold.outbid or 0) > 0 then parts[#parts + 1] = L["refunded bids"] end

    if (haul.letters or 0) > 0 then parts[#parts + 1] = Plural(haul.letters, L["%d letter"], L["%d letters"]) end

    if #parts == 0 then
        if (haul.itemCount or 0) > 0 then
            return L.Format("%s collected", Plural(haul.itemCount, L["%d item"], L["%d items"]))
        end
        return ""
    end

    if #parts == 1 then return L.Format("from %s", parts[1]) end
    local last = table.remove(parts)
    return L.Format("from %s and %s", table.concat(parts, ", "), last)
end

--- An item's name for the report, coloured by rarity where the game knows it.
local function ItemText(itemID, fallback)
    if not itemID then return fallback or L["an item"] end

    -- GetItemLabel says "item 1234" for an item the client has not cached,
    -- which a sold item usually is. The name the mail carried reads better.
    local label = Util.GetItemLabel(itemID)
    if type(label) == "string" and label ~= "" and not (fallback and label == L.Format("item %d", itemID)) then
        return label
    end

    return Util.ColorItemName(itemID, fallback) or L.Format("item %d", itemID)
end

--- A sale's name: the item's own where the game knows it, with the stack
--- size the mail's subject carried ("Linen Cloth (20)" reads "Linen Cloth x20").
local function SaleText(itemID, name)
    local text = ItemText(itemID, name)
    local count = type(name) == "string" and name:match(" %((%d+)%)$")
    if count and text ~= name then text = ("%s x%s"):format(text, count) end
    return text
end

--- "Linen Cloth x20, Wool Cloth x4, 2 more": the first `shown` (2 unless
--- said) by name, then how many more there are.
local function ItemsLine(list, shown)
    shown = math.min(shown or 2, #list)
    local parts = {}
    for index = 1, shown do
        local entry = list[index]
        parts[#parts + 1] = ("%s x%d"):format(ItemText(entry.itemID), entry.count)
    end
    if #list > shown then parts[#parts + 1] = L.Format("%d more", #list - shown) end
    return table.concat(parts, ", ")
end

local function Total(list)
    local n = 0
    for _, entry in ipairs(list or {}) do n = n + (entry.count or 0) end
    return n
end

--- The rows the report shows, top to bottom. Kept apart from the drawing so
--- the tests can read what the report says without a game client.
-- @return array of { type = "heading"|"money"|"sale"|"items", ... }
function MailReport.Lines(haul)
    local lines = {}
    local function Add(line) lines[#lines + 1] = line end

    local gold = haul.gold or {}
    local total = math.max(1, haul.total or 0)

    local sources = {
        { L["Auction sales"], gold.sold or 0, "profit" },
        { L["Refunded bids"], gold.outbid or 0, "accent" },
        { L["Other mail"], gold.other or 0, "text" },
    }

    local shown = 0
    for _, source in ipairs(sources) do
        if source[2] > 0 then shown = shown + 1 end
    end

    if shown > 0 then
        Add({ type = "heading", text = L["WHERE IT CAME FROM"] })
        for _, source in ipairs(sources) do
            if source[2] > 0 then
                Add({ type = "money", label = source[1], amount = source[2],
                    share = source[2] / total, color = source[3] })
            end
        end
    end

    local sales = haul.sales or {}
    if #sales > 0 then
        -- The record tag sits on the heading, so the best sale's name keeps
        -- the whole row.
        Add({ type = "heading", text = L["BEST SALE"], tag = haul.recordSale and L["BEST EVER"] or nil })
        Add({ type = "sale", itemID = sales[1].itemID, name = sales[1].name,
            amount = sales[1].amount, best = true, record = haul.recordSale })

        if #sales > 1 then
            Add({ type = "heading", text = L["ALSO SOLD"] })
            for index = 2, math.min(#sales, MAX_SALE_ROWS + 1) do
                local sale = sales[index]
                Add({ type = "sale", itemID = sale.itemID, name = sale.name, amount = sale.amount })
            end

            local more = (haul.salesCount or #sales) - math.min(#sales, MAX_SALE_ROWS + 1)
            if more > 0 then
                Add({ type = "items", label = Plural(more, L["and %d more sale"], L["and %d more sales"]), text = "", color = "muted" })
            end
        end
    end

    local items = haul.items or {}
    local kinds = {
        { "expired", L["Came back unsold"], "loss" },
        { "removed", L["You cancelled"], "muted" },
        { "won", L["Bought"], "profit" },
        { "other", L["Items from letters"], "text" },
    }

    local any = false
    for _, kind in ipairs(kinds) do
        if items[kind[1]] and #items[kind[1]] > 0 then any = true end
    end

    if any then
        Add({ type = "heading", text = L["ITEMS COLLECTED"] })
        for _, kind in ipairs(kinds) do
            local list = items[kind[1]]
            if list and #list > 0 then
                Add({ type = "items", label = ("%s (%d)"):format(kind[2], Total(list)),
                    text = ItemsLine(list), list = list, color = kind[3] })
            end
        end

        if (haul.returnedValue or 0) > 0 then
            Add({ type = "items", label = L["Worth relisting"],
                text = Util.FormatMoney(haul.returnedValue, { short = true }), color = "muted" })
        end
    end

    return lines
end

--------------------------------------------------------------------------------
-- The report window
--------------------------------------------------------------------------------

local function Bright(label)
    label:SetTextColor(BRIGHT_GOLD[1], BRIGHT_GOLD[2], BRIGHT_GOLD[3], 1)
end

local function Wash(parent, layer)
    local wash = parent:CreateTexture(nil, layer or "BACKGROUND", nil, 1)
    wash:SetAllPoints(parent)
    wash:SetColorTexture(BRIGHT_GOLD[1], BRIGHT_GOLD[2], BRIGHT_GOLD[3], 1)
    pcall(wash.SetBlendMode, wash, "ADD")
    wash:SetAlpha(0)
    return wash
end

local SPARKS = {
    { 0.06, 0.25 }, { 0.14, 0.8 }, { 0.26, 0.1 }, { 0.38, 0.9 }, { 0.62, 0.12 },
    { 0.74, 0.85 }, { 0.86, 0.2 }, { 0.94, 0.7 }, { 0.5, 0.95 }, { 0.2, 0.5 },
}

function MailReport:Build()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", "BlackthornesTSMailReport", UIParent)
    frame:SetSize(WIDTH, 300)
    frame:SetPoint("CENTER", 0, 80)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(f) f:StartMoving() end)
    frame:SetScript("OnDragStop", function(f) f:StopMovingOrSizing() end)
    frame:SetScript("OnHide", function() StopAll("report") end)
    frame:Hide()

    Theme.Fill(frame, "window", 0.97)
    -- The house frame (UI/Titanforged.lua): the gold rim, corner gems and
    -- the red close gem in the top right corner.
    if ns.Titanforged then
        ns.Titanforged:Dress(frame, { close = function() frame:Hide() end })
    else
        Theme.AddGameOutline(frame, { style = "dialog", color = "natural" })
    end
    -- The house glow round its edge, flaring as the report opens.
    Theme.Halo(frame, 10, 0.12)

    -- Escape closes it, like the main window.
    tinsert(UISpecialFrames, "BlackthornesTSMailReport")

    -- Header band: gold stripe, sheen, and a shine that sweeps it on open.
    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT", 6, -6)
    header:SetPoint("TOPRIGHT", -6, -6)
    header:SetHeight(34)
    Theme.Fill(header, "header")
    Theme.AccentStripe(header, 3)
    Theme.TopSheen(header, 0.08)
    frame.header = header

    local title = Theme.CreateLabel(header, "large", "accent")
    pcall(title.SetFont, title, Theme.FONT, Theme.sizes.large, "OUTLINE")
    Bright(title)
    title:SetPoint("LEFT", 14, 0)
    title:SetText(L["MAIL COLLECTED"])
    frame.title = title

    -- Clear of the close gem over the corner.
    local who = Theme.CreateLabel(header, "small", "muted", "RIGHT")
    who:SetPoint("RIGHT", -24, 0)
    -- A full two-part name with its time ran back under the title.
    who:SetPoint("LEFT", title, "RIGHT", 8, 0)
    frame.who = who

    local shine = header:CreateTexture(nil, "OVERLAY")
    shine:SetSize(60, 34)
    shine:SetColorTexture(BRIGHT_GOLD[1], BRIGHT_GOLD[2], BRIGHT_GOLD[3], 1)
    pcall(shine.SetBlendMode, shine, "ADD")
    shine:SetAlpha(0)
    frame.shine = shine

    -- The hero: the total, big, counting up.
    local hero = CreateFrame("Frame", nil, frame)
    hero:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    hero:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -4)
    hero:SetHeight(66)
    frame.hero = hero
    frame.heroWash = Wash(hero)

    local amount = Theme.CreateLabel(hero, 26, "accent", "CENTER")
    pcall(amount.SetFont, amount, Theme.FONT, 26, "OUTLINE")
    Bright(amount)
    amount:SetPoint("TOP", 0, -8)
    frame.amount = amount

    local sources = Theme.CreateLabel(hero, "small", "muted", "CENTER")
    sources:SetPoint("TOP", amount, "BOTTOM", 0, -8)
    frame.sources = sources

    frame.sparks = {}
    for index = 1, #SPARKS do
        local spark = hero:CreateTexture(nil, "OVERLAY")
        spark:SetSize(3, 3)
        spark:SetColorTexture(BRIGHT_GOLD[1], BRIGHT_GOLD[2], BRIGHT_GOLD[3], 1)
        pcall(spark.SetBlendMode, spark, "ADD")
        spark:SetAlpha(0)
        frame.sparks[index] = spark
    end

    -- The record ribbon, shown when the visit beat something.
    local ribbon = CreateFrame("Frame", nil, frame)
    ribbon:SetHeight(24)
    Theme.Fill(ribbon, "rowActive")
    Theme.Border(ribbon, "accent", 0.8)
    ribbon.wash = Wash(ribbon, "BORDER")
    ribbon.text = Theme.CreateLabel(ribbon, "normal", "accent", "CENTER")
    pcall(ribbon.text.SetFont, ribbon.text, Theme.FONT, Theme.sizes.normal, "OUTLINE")
    Bright(ribbon.text)
    ribbon.text:SetPoint("CENTER")
    ribbon:Hide()
    frame.ribbon = ribbon

    frame.rows = {}

    -- Footer: the day, the week and the best haul, then the buttons.
    local stats = Theme.CreateLabel(frame, "tiny", "muted", "CENTER")
    stats:SetPoint("BOTTOMLEFT", PAD, 44)
    stats:SetPoint("BOTTOMRIGHT", -PAD, 44)
    frame.stats = stats

    local done = Widgets.CreateButton(frame, L["Close"], function() frame:Hide() end,
        { width = 110, height = 24, primary = true })
    done:SetPoint("BOTTOMRIGHT", -PAD, 14)

    local visits = Widgets.CreateButton(frame, L["See all visits"], function()
        frame:Hide()
        MailReport:OpenVisits()
    end, { width = 130, height = 24, tooltip = L["Every mailbox visit, on the Sales tab"] })
    -- Grows for a longer wording (German), never ending in "...".
    local visitsWidth = Theme.TextWidth and visits.label and Theme.TextWidth(visits.label)
    if type(visitsWidth) == "number" and visitsWidth + 16 > 130 then
        visits:SetWidth(math.ceil(visitsWidth) + 16)
    end
    visits:SetPoint("BOTTOMLEFT", PAD, 14)

    self.frame = frame
    return frame
end

--- A pooled row of the report.
local function Row(frame, index)
    local row = frame.rows[index]
    if row then return row end

    row = CreateFrame("Frame", nil, frame)
    row:SetHeight(ROW)

    row.glow = Wash(row)

    row.icon = Theme.CreateItemIcon(row, 16)
    row.icon:SetPoint("LEFT", 0, 0)
    if Widgets.ItemHotspot then Widgets.ItemHotspot(row.icon, row) end

    row.label = Theme.CreateLabel(row, "small", "text")
    row.value = Theme.CreateLabel(row, "small", "text", "RIGHT")
    row.value:SetPoint("RIGHT", 0, 0)

    row.tag = Theme.CreateLabel(row, "tiny", "accent", "RIGHT")
    Bright(row.tag)

    row.rule = row:CreateTexture(nil, "ARTWORK")
    row.rule:SetColorTexture(Theme.Unpack("border"))
    row.rule:SetHeight(1)

    row.bar = Theme.CreateBar(row, 90, 3)

    frame.rows[index] = row
    return row
end

local function ResetRow(row)
    row.icon:Hide()
    row.rule:Hide()
    row.tag:Hide()
    row.bar:Set(nil)
    row.glow:SetAlpha(0)
    row.label:ClearAllPoints()
    row.label:SetPoint("LEFT", 0, 0)
    row.label:SetPoint("RIGHT", row.value, "LEFT", -8, 0)
    row.label:SetFont(Theme.FONT, Theme.sizes.small, "")
    row.label:SetTextColor(Theme.Unpack("text"))
    row.label:SetWidth(0)
    row.label:SetWordWrap(false)
    row.value:SetWidth(0)
    row.value:SetWordWrap(false)
    row.value:SetText("")
    row.value:SetTextColor(Theme.Unpack("text"))
    row:SetAlpha(1)
end

--- Whether a label's text fits `room` pixels across. One that cannot be
--- measured is taken to fit.
local function Fits(label, room)
    local ok, width = pcall(label.GetStringWidth, label)
    return not ok or type(width) ~= "number" or width <= room
end

--- A label `room` wide that runs onto more lines rather than end in "...".
-- @return the height the row needs to hold it
local function WrapToFit(label, room, height, size)
    if Fits(label, room) then return height end

    label:SetWordWrap(true)
    local ok, needed = pcall(label.GetStringHeight, label)
    if ok and type(needed) == "number" and needed > 0 then
        return math.max(height, math.ceil(needed) + 8)
    end
    return height + size + 3
end

--- As many items by name as fit `room` beside how many more there are, so the
--- count is never the part cut off.
-- @return false when even one name and the count need a second line
local function FitItems(label, list, room)
    for shown = math.min(2, #list), 1, -1 do
        label:SetText(ItemsLine(list, shown))
        if Fits(label, room) then return true end
    end
    return false
end

--- Fill one row from a line of MailReport.Lines.
-- @return the row's height: taller than usual when its text needs two lines
local function DrawLine(row, line)
    ResetRow(row)

    if line.type == "heading" then
        row.label:SetFont(Theme.FONT, Theme.sizes.tiny, "")
        row.label:SetTextColor(Theme.Unpack("accent"))
        row.label:ClearAllPoints()
        row.label:SetPoint("BOTTOMLEFT", 0, 3)
        row.label:SetText(line.text)
        row.rule:ClearAllPoints()
        row.rule:SetPoint("LEFT", row.label, "RIGHT", 6, 0)
        if line.tag then
            row.tag:ClearAllPoints()
            row.tag:SetPoint("BOTTOMRIGHT", 0, 3)
            row.tag:SetText(line.tag)
            row.tag:Show()
            row.rule:SetPoint("RIGHT", row.tag, "LEFT", -6, 0)
        else
            row.rule:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        end
        row.rule:Show()

    elseif line.type == "money" then
        row.label:SetText(line.label)
        row.value:SetText(Util.FormatMoney(line.amount))
        row.value:SetTextColor(Theme.Unpack(line.color or "text"))
        row.value:SetWidth(120)
        row.label:ClearAllPoints()
        row.label:SetPoint("LEFT", 0, 0)
        row.bar.track:ClearAllPoints()
        row.bar.track:SetPoint("RIGHT", row.value, "LEFT", -10, 0)
        row.bar:Set(0.001, line.color == "text" and "accent" or line.color)

    elseif line.type == "sale" then
        Theme.SetItemIcon(row.icon, line.itemID)
        if not line.itemID then row.icon:Hide() end
        row.value:SetText(Util.FormatMoney(line.amount))
        row.value:SetTextColor(Theme.Unpack("profit"))
        row.value:SetWidth(SALE_VALUE)

        -- The name has the row up to the amount. Sized before it is
        -- measured, and given a second line rather than cut off.
        local left = line.itemID and 22 or 0
        local room = ROW_WIDTH - left - SALE_VALUE - 8
        local size = line.best and Theme.sizes.normal or Theme.sizes.small
        row.label:SetFont(Theme.FONT, size, "")
        row.label:ClearAllPoints()
        row.label:SetPoint("LEFT", left, 0)
        row.label:SetWidth(room)
        row.label:SetText(SaleText(line.itemID, line.name))
        local r, g, b = Util.GetItemQualityColor(line.itemID)
        if r then row.label:SetTextColor(r, g, b) end

        return WrapToFit(row.label, room, line.best and 24 or ROW, size)

    else
        row.label:SetText(line.label)
        row.label:SetTextColor(Theme.Unpack(line.color or "text"))
        row.label:ClearAllPoints()
        row.label:SetPoint("LEFT", 0, 0)
        row.value:SetTextColor(Theme.Unpack("muted"))

        -- The value has what the label leaves, so a short label gives the
        -- items more names.
        local room = ITEMS_ROOM
        local ok, used = pcall(row.label.GetStringWidth, row.label)
        if ok and type(used) == "number" and used > 0 then
            room = ROW_WIDTH - math.ceil(used) - 12
        end
        row.value:SetWidth(room)

        if line.list and FitItems(row.value, line.list, room) then return ROW end
        if not line.list then row.value:SetText(line.text or "") end
        return WrapToFit(row.value, room, ROW, Theme.sizes.small)
    end

    return line.best and 24 or ROW
end

--- The character's name for a haul's key. Keys are now the character's GUID
--- ("Player-..."), where the text before the first dash is just "Player", so
--- the name comes from the character's record; old "Name-Realm" keys still
--- work. Empty when the character is unknown.
function MailReport.WhoName(key)
    return Util.CharacterName(key)
end

--- "Blackthornes, just now" or "Blackthornes, 2h ago"
local function WhoWhen(haul)
    local name = MailReport.WhoName(haul.who)
    local age = haul.t and (time() - haul.t) or 0
    local when = age < 60 and L["just now"] or Util.FormatAgeAgo(age)
    if name == "" then return when end
    return ("%s, %s"):format(name, when)
end

--- Show the report for a haul. `opts.replay` when reopening an old one.
function MailReport:Show(haul, opts)
    opts = opts or {}
    local frame = self:Build()

    StopAll("report")

    -- Whole: a size smaller, then on two lines, never cut.
    Theme.FitWhole(frame.who, haul.sample and L["sample"] or WhoWhen(haul), { "small", "tiny" })
    frame.sources:SetText(MailReport.Sources(haul))
    frame.amount:SetText(Util.FormatMoney(0))

    -- The record ribbon.
    local ribbonText
    -- Reopened from the Sales tab, a record is told as one it was then,
    -- not as news.
    if haul.recordHaul then
        ribbonText = L.Format(opts.replay and L["BEST HAUL AT THE TIME!  Old best %s"] or L["NEW BEST HAUL!  Old best %s"],
            Util.FormatMoney(haul.previousBest or 0, { short = true }))
    elseif haul.recordSale then
        ribbonText = opts.replay and L["BEST SALE AT THE TIME!"] or L["YOUR BEST SALE EVER!"]
    elseif haul.first then
        ribbonText = L["YOUR FIRST HAUL ON RECORD"]
    end

    local y = -(6 + 34 + 4 + 66)

    if ribbonText then
        frame.ribbon:ClearAllPoints()
        frame.ribbon:SetPoint("TOPLEFT", PAD, y - 2)
        frame.ribbon:SetPoint("TOPRIGHT", -PAD, y - 2)
        frame.ribbon.text:SetText(ribbonText)
        frame.ribbon:SetAlpha(0)
        frame.ribbon:Show()
        y = y - 32
    else
        frame.ribbon:Hide()
    end

    -- The rows.
    local lines = MailReport.Lines(haul)
    for index, line in ipairs(lines) do
        local row = Row(frame, index)
        local gap = (line.type == "heading" and index > 1) and 8 or 0
        y = y - gap

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", PAD, y)
        row:SetPoint("TOPRIGHT", -PAD, y)
        local height = DrawLine(row, line)
        row:SetHeight(height)
        row:Show()

        -- Each row fades in after the one above, and a share bar slides out.
        row:SetAlpha(0)
        local delay = 0.25 + index * 0.06
        MailReport.Start({ slot = "report:row" .. index, duration = 0.3, delay = delay,
            apply = function(p) row:SetAlpha(EaseOut(p)) end,
            stop = function() row:SetAlpha(1) end })

        if line.type == "money" then
            MailReport.Start({ slot = "report:bar" .. index, duration = 0.8, delay = delay + 0.1,
                apply = function(p) row.bar:Set(math.max(0.001, line.share * EaseOut(p)),
                    line.color == "text" and "accent" or line.color) end,
                stop = function() row.bar:Set(line.share, line.color == "text" and "accent" or line.color) end })
        end

        if line.best then
            -- The best sale beats gold for a while.
            MailReport.Start({ slot = "report:best", duration = 2.4, delay = delay + 0.2,
                apply = function(p) row.glow:SetAlpha(0.16 * math.sin(p * 3 * math.pi) ^ 2) end,
                stop = function() row.glow:SetAlpha(0) end })
        end

        y = y - height
    end

    for index = #lines + 1, #frame.rows do frame.rows[index]:Hide() end

    -- The footer.
    local stats = {}
    -- Today and the last week are about now, so an old haul reopened from the
    -- Sales tab leaves them out rather than showing that day's figures.
    if opts.replay then
        -- nothing: only the best haul below still means something
    elseif (haul.today or 0) > 0 then
        stats[#stats + 1] = L.Format("Today %s", Util.FormatMoney(haul.today, { short = true }))
    end
    if not opts.replay and (haul.week or 0) > 0 then
        stats[#stats + 1] = L.Format("Last 7 days %s", Util.FormatMoney(haul.week, { short = true }))
    end
    local bestHaul = ns.MailHaul and ns.MailHaul:Records() or 0
    if bestHaul > 0 then
        stats[#stats + 1] = L.Format("Best haul %s", Util.FormatMoney(bestHaul, { short = true }))
    end
    frame.stats:SetText(table.concat(stats, "   ·   "))

    frame:SetHeight(-y + 16 + 62)
    frame:SetAlpha(0)
    frame:Show()
    if frame.Raise then frame:Raise() end

    self:Animate(haul, ribbonText ~= nil, opts)
end

--- The opening: fade in, the shine, the count-up, the pop, the ribbon.
function MailReport:Animate(haul, hasRibbon, opts)
    local frame = self.frame
    local record = haul.recordHaul or haul.recordSale

    MailReport.Start({ slot = "report:open", duration = 0.25,
        apply = function(p)
            frame:SetAlpha(EaseOut(p))
        end,
        stop = function() frame:SetAlpha(1) end })

    -- The glow round the edge flares and settles; brighter for a record.
    local rest = frame.haloRest
    if rest then
        local peak = rest * (record and 5 or 3.2)
        MailReport.Start({ slot = "report:halo", duration = record and 1.4 or 0.9,
            apply = function(p)
                Theme.SetHalo(frame, peak + (rest - peak) * EaseOut(p))
            end,
            stop = function() Theme.SetHalo(frame, rest) end })
    end

    local okWidth, width = pcall(frame.header.GetWidth, frame.header)
    width = okWidth and tonumber(width) or WIDTH

    MailReport.Start({ slot = "report:shine", duration = 0.9, delay = 0.15,
        apply = function(p)
            frame.shine:ClearAllPoints()
            frame.shine:SetPoint("LEFT", frame.header, "LEFT", (width - 60) * p, 0)
            frame.shine:SetAlpha(0.3 * math.sin(p * math.pi))
        end,
        stop = function() frame.shine:SetAlpha(0) end })

    local countTime = math.min(2.2, 1.0 + 0.1 * math.log10(math.max(10, haul.total or 0)))

    MailReport.Play("haul")

    CountUp("report:count", frame.amount, 0, haul.total or 0, countTime, 0.2, function()
        Pop("report:pop", frame.amount, 26, 0)

        MailReport.Start({ slot = "report:wash", duration = 0.9,
            apply = function(p) frame.heroWash:SetAlpha(0.14 * (1 - p)) end,
            stop = function() frame.heroWash:SetAlpha(0) end })

        if record then MailReport.Play("record") end
    end)

    if hasRibbon then
        local ribbon = frame.ribbon
        local ribbonDelay = 0.2 + countTime

        MailReport.Start({ slot = "report:ribbon", duration = 3.0, delay = ribbonDelay,
            apply = function(p)
                ribbon:SetAlpha(math.min(1, p * 8))
                ribbon.wash:SetAlpha(0.1 + 0.1 * math.sin(p * 8 * math.pi))
                if p >= 1 then ribbon.wash:SetAlpha(0.06) end
            end,
            stop = function() ribbon:SetAlpha(1); ribbon.wash:SetAlpha(0.06) end })

        if record then
            local heroWidth = width
            for index, spark in ipairs(frame.sparks) do
                spark:ClearAllPoints()
                spark:SetPoint("CENTER", frame.hero, "TOPLEFT",
                    SPARKS[index][1] * heroWidth, -SPARKS[index][2] * 66)
            end

            MailReport.Start({ slot = "report:sparks", duration = 3.0, delay = ribbonDelay,
                apply = function(p)
                    local fade = p > 0.7 and (1 - p) / 0.3 or 1
                    for index, spark in ipairs(frame.sparks) do
                        spark:SetAlpha(fade * (0.5 + 0.5 * math.sin(p * 14 * math.pi + index * 1.7)))
                    end
                end,
                stop = function()
                    for _, spark in ipairs(frame.sparks) do spark:SetAlpha(0) end
                end })
        end
    end
end

function MailReport:Hide()
    if self.frame then self.frame:Hide() end
end

--- Open the main window on the Sales tab's list of visits.
function MailReport:OpenVisits()
    if not ns.UI then return end
    ns.UI:Show()
    if ns.SalesTab and ns.SalesTab.ShowVisits then ns.SalesTab.ShowVisits() end
    ns.UI:SelectTab("sales")
end

--------------------------------------------------------------------------------
-- The tally over the mailbox
--------------------------------------------------------------------------------

function MailReport:BuildTally()
    if self.tally then return self.tally end

    local tally = CreateFrame("Frame", nil, UIParent)
    tally:SetSize(250, 44)
    tally:SetFrameStrata("HIGH")
    Theme.Fill(tally, "window", 0.92)
    -- A thin gold rim: a bright line round the edge, a deeper gold inside it.
    Theme.Border(tally, "accentHi", 1)
    local inner = CreateFrame("Frame", nil, tally)
    inner:SetPoint("TOPLEFT", 1, -1)
    inner:SetPoint("BOTTOMRIGHT", -1, 1)
    Theme.Border(inner, "accent", 0.9)
    Theme.AccentStripe(tally, 3)
    Theme.TopSheen(tally, 0.08)
    tally.wash = Wash(tally, "BORDER")
    tally:Hide()

    local heading = Theme.CreateLabel(tally, "small", "accent")
    heading:SetPoint("TOPLEFT", 12, -6)
    heading:SetText(L["COLLECTED THIS VISIT"])

    -- Asked 2026-09-28: "i see no way to get rid of the message". A close
    -- button, and the tally also goes by itself once the mailbox is gone.
    -- The house's small red close gem over the top right corner.
    local close
    local tip = L["Hide this until the next mailbox visit"]
    if ns.Titanforged and ns.Titanforged.CloseGem then
        close = ns.Titanforged.CloseGem(tally, function() MailReport:HideTally() end)
        close:SetSize(18, 18)
        close:ClearAllPoints()
        close:SetPoint("CENTER", tally, "TOPRIGHT", -4, -4)
        local ok, level = pcall(tally.GetFrameLevel, tally)
        if ok and type(level) == "number" then close:SetFrameLevel(level + 5) end
        -- The gem says "Close"; this one says what closing does here.
        close:HookScript("OnEnter", function(self)
            if GameTooltip then
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(tip, 1, 1, 1)
                GameTooltip:Show()
            end
        end)
    else
        close = Widgets.CreateButton(tally, "X", function() MailReport:HideTally() end,
            { width = 18, height = 16, fontSize = "tiny", tooltip = tip })
        close:SetPoint("TOPRIGHT", -4, -4)
    end
    tally.close = close

    local count = Theme.CreateLabel(tally, "small", "muted", "RIGHT")
    count:SetPoint("TOPRIGHT", -18, -6)
    tally.count = count

    -- A check once a second that the mailbox is still there, whatever the
    -- game did or did not say when it closed.
    local since = 0
    tally:SetScript("OnUpdate", function(_, elapsed)
        since = since + (tonumber(elapsed) or 0)
        if since < 1 then return end
        since = 0
        if not MailReport.MailboxOpen() then MailReport:FadeTally() end
    end)

    local amount = Theme.CreateLabel(tally, 16, "accent")
    pcall(amount.SetFont, amount, Theme.FONT, 16, "OUTLINE")
    Bright(amount)
    amount:SetPoint("BOTTOMLEFT", 12, 6)
    tally.amount = amount

    tally.floats = {}
    for index = 1, 4 do
        local float = Theme.CreateLabel(tally, 14, "profit")
        pcall(float.SetFont, float, Theme.FONT, 14, "OUTLINE")
        float:Hide()
        tally.floats[index] = float
    end
    tally.nextFloat = 1

    self.tally = tally
    return tally
end

--- Put the tally just above the mailbox window, or near the top of the
--- screen if the mailbox is not the game's own.
local function PlaceTally(tally)
    tally:ClearAllPoints()
    local mailFrame = _G.MailFrame
    if mailFrame and mailFrame.IsShown and mailFrame:IsShown() then
        tally:SetPoint("BOTTOMLEFT", mailFrame, "TOPLEFT", 0, 6)
    else
        tally:SetPoint("TOP", UIParent, "TOP", 0, -140)
    end
end

--- "+3g 20s" rising off the right of the tally.
local function Float(tally, text)
    local float = tally.floats[tally.nextFloat]
    tally.nextFloat = tally.nextFloat % #tally.floats + 1

    float:SetText(text)
    float:Show()

    MailReport.Start({ slot = "tally:float" .. tostring(float), duration = 1.4,
        apply = function(p)
            float:ClearAllPoints()
            float:SetPoint("LEFT", tally, "RIGHT", 8, -4 + 30 * EaseOut(p))
            float:SetAlpha(p < 0.15 and p / 0.15 or 1 - (p - 0.15) / 0.85)
            if p >= 1 then float:Hide() end
        end,
        stop = function() float:Hide() end })
end

--- Is a mailbox open right now? The game's own window is the first word.
function MailReport.MailboxOpen()
    local mailFrame = _G.MailFrame
    if mailFrame and mailFrame.IsShown then
        local ok, shown = pcall(mailFrame.IsShown, mailFrame)
        if ok then return shown and true or false end
    end
    return ns.Mail and ns.Mail.isOpen == true
end

function MailReport:HideTally()
    StopAll("tally")
    self.tallyFading = false
    if self.tally then
        self.tally:Hide()
        self.tally:SetAlpha(1)
    end
    self.tallyDismissed = true
end

-- Asked 2026-09-28: "it should fade on it's own 30sec after leaving mailbox".
local TALLY_LINGER = 30
local TALLY_FADE = 1.5

--- Leave the tally up for a while after the mailbox closes, then fade it.
function MailReport:FadeTally()
    local tally = self.tally
    if not (tally and tally:IsShown()) or self.tallyFading then return end

    self.tallyFading = true
    MailReport.Start({ slot = "tally:fade", duration = TALLY_FADE, delay = TALLY_LINGER,
        apply = function(p)
            tally:SetAlpha(1 - p)
            if p >= 1 then
                tally:Hide()
                tally:SetAlpha(1)
                MailReport.tallyFading = false
            end
        end,
        stop = function()
            tally:SetAlpha(1)
            MailReport.tallyFading = false
        end })
end

function MailReport:OnMailboxOpened()
    StopAll("tally")
    if self.tally then self.tally:Hide() end
    self.tallyShown = 0
    self.tallyDismissed = false
end

function MailReport:OnMailboxClosed()
    self:FadeTally()
end

--- Something was just collected. Logic/MailHaul.lua calls this.
function MailReport:OnCollected(visit, gained)
    if ns.Config:Get("mailReport") == false then return end
    if (visit.total or 0) <= 0 then return end
    if self.tallyDismissed then return end

    local tally = self:BuildTally()
    if not tally:IsShown() then
        PlaceTally(tally)
        tally:Show()
    end

    local sales = #(visit.sales or {})
    tally.count:SetText(sales > 0 and Plural(sales, L["%d sale"], L["%d sales"]) or "")

    local from = self.tallyShown or 0
    self.tallyShown = visit.total
    CountUp("tally:count", tally.amount, from, visit.total, 0.6, 0)

    if gained > 0 then
        Float(tally, "+" .. Util.FormatMoney(gained, { short = true }))

        MailReport.Start({ slot = "tally:wash", duration = 0.6,
            apply = function(p) tally.wash:SetAlpha(0.18 * (1 - p)) end,
            stop = function() tally.wash:SetAlpha(0) end })
    end
end
