-- Blackthornes Tradeskills -- UI/Tab_Settings.lua
-- The knobs that change which crafts come out on top.
--
-- Each one shows what it actually does rather than just its name: several of
-- these silently reshuffle the whole profit table, and a setting you cannot
-- reason about is worse than no setting.
--
-- Layout rule: a row is [label ......... control] on one line. What it does
-- is the row's tooltip, or, with Show descriptions ticked, wrapped on its own
-- lines underneath spanning the full column, the row grown to fit. Rows sit
-- in two columns on one of the category pages (PAGES), picked along the top.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local UI = ns.UI

local COLUMN_WIDTH = 400
local COLUMN_ONE_X = 16
local COLUMN_TWO_X = 452

-- Wide enough for the longest label ("Recommend selling at a loss"), with the
-- widest control ("Charge market price") still inside the column.
local LABEL_WIDTH = 228
local CONTROL_X = 240

local ROW_GAP = -8
local SECTION_GAP = -22

-- The category switch along the top, and the room it takes.
local BAR_HEIGHT = 34

-- A player's request (2026-10-07): the one long page grew crowded, so the
-- settings sit on category pages picked along the top, like Recipes /
-- Recipes to learn. Every setting kept its saved name; only its place moved.
local PAGES = {
    { key = "pricing", text = L["PRICING"],
      tip = L["Undercut, the auction house cut, markups and what counts as profit"] },
    { key = "queue", text = L["QUEUE"],
      tip = L["What gets queued, sub-crafts, alts, ignored crafts and items, export and import"] },
    { key = "mail", text = L["MAIL & VENDORS"],
      tip = L["The mailbox, your disenchanter, selling to vendors and the mail report"] },
    { key = "auction", text = L["AUCTION HOUSE"],
      tip = L["Buying, posting and scanning"] },
    { key = "look", text = L["LOOK & SOUND"],
      tip = L["Window size and effects, values on tooltips, and every sound"] },
    { key = "sharing", text = L["SHARING"],
      tip = L["Your other account and guild prices"] },
    { key = "data", text = L["DATA"],
      tip = L["What is saved and clearing old prices"] },
    { key = "about", text = L["ABOUT"],
      tip = L["How these addons are made, the version, the Discord and the other Blackthornes addons"] },
}
local DEFAULT_PAGE = "pricing"

local widgets = {}

--- An Off / Shift / Always box (see the Look page) set to the saved mode,
--- without calling its onSelect.
local function ShowShiftMode(dropdown)
    local setting = dropdown.shiftSetting
    local isOn = setting == nil or ns.Config:Get(setting) ~= false
    dropdown:SetValue(ns.TooltipShift:Mode(isOn, dropdown.shiftKey), true)
end

-- [key] = { holder, scroll, content, last = { [1], [2] }, rows }; built in Build.
local pages = {}

-- Every row and button the search looks through, in the order built.
local searchables = {}

--------------------------------------------------------------------------------
-- Layout helpers
--------------------------------------------------------------------------------

--- Put `frame` under the last thing in a page's column, or at its top, and
--- make it the new last thing there.
local function Place(page, column, frame, gap)
    local last = page.last[column]
    if last then
        frame:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, gap or ROW_GAP)
    else
        frame:SetPoint("TOPLEFT", page.content, "TOPLEFT",
            column == 1 and COLUMN_ONE_X or COLUMN_TWO_X, -12)
    end
    page.last[column] = frame
    return frame
end

--- A soft gold frame around something the search found. Drawn on the
--- page itself, so it sits behind the row's own controls.
local function AddFoundGlow(page, frame)
    local glow = page.content:CreateTexture(nil, "BACKGROUND")
    glow:SetPoint("TOPLEFT", frame, "TOPLEFT", -6, 3)
    glow:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 6, -3)
    glow:SetColorTexture(Theme.Unpack("accent"))
    glow:SetAlpha(0.16)
    glow:Hide()
    return glow
end

--- Let the search find `frame` by its words, on `page`.
local function Searchable(page, frame, words)
    searchables[#searchables + 1] = {
        page = page.key,
        frame = frame,
        words = (words or ""):lower(),
        glow = AddFoundGlow(page, frame),
    }
end

--- Section heading with a rule underneath, next in a page's column.
local function CreateSection(page, column, text)
    local section = CreateFrame("Frame", nil, page.content)
    section:SetSize(COLUMN_WIDTH, 20)
    Place(page, column, section, page.last[column] and SECTION_GAP)

    local heading = Theme.CreateLabel(section, "tiny", "accent")
    heading:SetPoint("TOPLEFT", 0, 0)
    heading:SetText(text)

    local divider = Theme.CreateDivider(section)
    divider:SetPoint("TOPLEFT", 0, -14)
    divider:SetWidth(COLUMN_WIDTH)

    return section
end

--- The tooltip a row shows under the mouse: its name, then what it does,
--- in white so it reads easily.
local function ShowRowTip(row)
    if not (row.description and GameTooltip) then return end
    if ns.Config:Get("settingsDescriptions") == true then return end

    GameTooltip:SetOwner(row, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    GameTooltip:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -2)
    GameTooltip:SetText(row.labelText, Theme.Unpack("accent"))
    GameTooltip:AddLine(row.description, 1, 1, 1, true)
    GameTooltip:Show()
end

--- Light a row while the mouse is over it or any control on it. Its
--- controls take the mouse from it, so it checks each frame until the
--- mouse has left the whole row rather than trusting OnLeave.
local function LightRow(row)
    row.hover:Show()
    ShowRowTip(row)
    row:SetScript("OnUpdate", function(self)
        if self:IsMouseOver() then return end
        self:SetScript("OnUpdate", nil)
        self.hover:Hide()
        if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
end

--- How tall a row is with its description shown, or without.
local function FitRow(row, showDescription)
    row.hint:SetShown(showDescription)
    row:SetHeight(showDescription and row.fullHeight or row.compactHeight)
end

--- One setting: label and control on a line. What it does is a tooltip on
--- the row, or the line beneath it with Show descriptions ticked.
-- Returns the row frame; anchor the control at CONTROL_X inside it.
local function CreateRow(page, column, labelText, description)
    -- No description (nil or "") means no tooltip and nothing under the
    -- row with Show descriptions ticked.
    if description == "" then description = nil end

    local row = CreateFrame("Frame", nil, page.content)
    row:SetSize(COLUMN_WIDTH, 24)
    Place(page, column, row)

    -- Wrapped rather than cut off should a label still outgrow its room at
    -- the player's font; the description then starts under its last line.
    local label = Theme.CreateLabel(row, "small", "text")
    label:SetPoint("TOPLEFT", 0, -4)
    label:SetWidth(LABEL_WIDTH)
    label:SetWordWrap(true)
    label:SetText(labelText)

    local top = 24
    local labelHeight = label.GetStringHeight and label:GetStringHeight() or 0
    if type(labelHeight) == "number" and labelHeight > 16 then
        top = math.ceil(4 + labelHeight + 6)
    end
    row.compactHeight = top
    row.fullHeight = top

    -- Lit under the mouse, so it is plain the row has more to say.
    row.hover = row:CreateTexture(nil, "BACKGROUND")
    row.hover:SetPoint("TOPLEFT", -6, 2)
    row.hover:SetPoint("BOTTOMRIGHT", 6, -2)
    row.hover:SetColorTexture(Theme.Unpack("accent"))
    row.hover:SetAlpha(0.1)
    row.hover:Hide()

    row.labelText = labelText
    row.description = description
    row:EnableMouse(true)
    row:SetScript("OnEnter", LightRow)

    if description then
        -- "muted" rather than "dim": the small print says what each setting
        -- does, and "dim" was hard to read on the panel.
        local hint = Theme.CreateLabel(row, "tiny", "muted")
        hint:SetPoint("TOPLEFT", 0, -top)
        hint:SetWidth(COLUMN_WIDTH)
        -- Wrapped, with the row grown to fit: on one line the longer ones
        -- (Undercut by, Minimum profit) were cut off halfway with "...".
        hint:SetWordWrap(true)
        hint:SetText(description)
        row.hint = hint

        local height = hint.GetStringHeight and hint:GetStringHeight() or 0
        row.fullHeight = math.max(40, top + (type(height) == "number" and math.ceil(height) or 14) + 2)
        FitRow(row, ns.Config:Get("settingsDescriptions") == true)
    else
        row:SetHeight(top)
    end

    page.rows = page.rows or {}
    page.rows[#page.rows + 1] = row
    Searchable(page, row, labelText .. " " .. (description or ""))

    return row
end

--- Small unit label sitting to the right of a control.
local function AddUnit(row, control, text)
    local unit = Theme.CreateLabel(row, "small", "muted")
    unit:SetPoint("LEFT", control, "RIGHT", 6, 0)
    unit:SetText(text)
    return unit
end

--- Put a row's Reload button under its control, lined up with the
--- control's right edge, the row a line taller for it. Every Reload in
--- Settings sits the same way, as in the other Blackthornes addons.
local function ReloadUnder(row, control, reload)
    reload:ClearAllPoints()
    reload:SetPoint("TOPRIGHT", control, "BOTTOMRIGHT", 0, -4)
    row.compactHeight = row.compactHeight + 24
    row.fullHeight = row.fullHeight + 24
    if row.hint then
        row.hint:ClearAllPoints()
        row.hint:SetPoint("TOPLEFT", 0, -row.compactHeight)
    end
    row:SetHeight(row.compactHeight)
end

--- Widen a button to its label when the label, measured at the player's
--- font, needs more room than the button was given: "Remove old prices"
--- and "Reset to defaults" ended in "..." on 140-pixel buttons.
local function FitButton(button)
    local width = Theme.TextWidth(button.label)
    local have = button:GetWidth()
    if width and type(have) == "number" and width + 16 > have then
        button:SetWidth(math.ceil(width) + 16)
    end
end

--------------------------------------------------------------------------------
-- Pages, the switch along the top, and the search
--------------------------------------------------------------------------------

--- The page showing now: the one saved, or Pricing.
local function CurrentPage()
    local saved = ns.Config:Get("settingsPage")
    return pages[saved] and saved or DEFAULT_PAGE
end

--- Size a page's scrolling area to what is on it, once it has real
--- coordinates.
--
-- On the first build the frames have not been laid out yet, so GetTop() is
-- nil and there is nothing to measure. Retrying on the next frame costs one
-- timer and avoids a page that cannot scroll until you click away and back.
local function FitScroll(key)
    local page = pages[key or CurrentPage()]
    if not page then return end

    if not page.scroll:FitContent() then
        C_Timer.After(0, function() page.scroll:FitContent() end)
    end
end

--- Light the switch: the page showing gold and underlined, a page the
--- search found nothing on dimmed, the rest grey until hovered.
local function PaintSwitch()
    local current = CurrentPage()
    for _, part in ipairs(widgets.switch or {}) do
        local active = part.key == current
        local color = active and "accent"
            or (widgets.query and not part.found) and "dim"
            or part.hovered and "text"
            or "muted"
        part.label:SetTextColor(Theme.Unpack(color))
        part.underline:SetShown(active)
    end
end

--- Lay the switch out left to right, each part as wide as its name.
local function LayoutSwitch()
    local previous
    for _, part in ipairs(widgets.switch or {}) do
        local width = Theme.TextWidth and Theme.TextWidth(part.label)
        part.button:SetWidth((type(width) == "number" and width or 100) + 4)
        part.button:ClearAllPoints()
        if previous then
            part.button:SetPoint("LEFT", previous, "RIGHT", 22, 0)
        else
            part.button:SetPoint("LEFT", widgets.bar, "LEFT", COLUMN_ONE_X, 0)
        end
        previous = part.button
    end
end

--- Show one page and remember it.
local function ShowPage(key)
    if not pages[key] then key = DEFAULT_PAGE end
    -- Only written when it changes: every setting write is mirrored out at
    -- once (Persist), and a page being redrawn is not a change.
    if ns.Config:Get("settingsPage") ~= key then ns.Config:Set("settingsPage", key) end
    for pageKey, page in pairs(pages) do
        page.holder:SetShown(pageKey == key)
    end
    widgets.shownPage = key
    PaintSwitch()
    FitScroll(key)
end

--- Scroll a page so `frame` is in view, near the top.
local function ScrollTo(key, frame)
    local page = pages[key]
    local top, at = page.content:GetTop(), frame:GetTop()
    if type(top) ~= "number" or type(at) ~= "number" then return end
    page.scroll:UpdateRange()
    local bar = page.scroll.scrollbar
    local _, range = bar:GetMinMaxValues()
    bar:SetValue(math.max(0, math.min(range or 0, top - at - 12)))
end

--- Find settings by their words. Each one found glows, each page with
--- none dims on the switch, and when the page showing has none, the first
--- page that does is shown.
local function Search(text)
    local query = (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    widgets.query = query ~= "" and query or nil

    local counts, firstFound = {}, {}
    for _, entry in ipairs(searchables) do
        local found = widgets.query and entry.words:find(widgets.query, 1, true) ~= nil
        entry.glow:SetShown(found and true or false)
        if found then
            counts[entry.page] = (counts[entry.page] or 0) + 1
            firstFound[entry.page] = firstFound[entry.page] or entry.frame
        end
    end

    -- No counts beside the names: the switch has to stay clear of the
    -- search box at the player's font.
    for _, part in ipairs(widgets.switch or {}) do
        part.found = (counts[part.key] or 0) > 0
    end

    local show = CurrentPage()
    if widgets.query and not counts[show] then
        for _, definition in ipairs(PAGES) do
            if counts[definition.key] then show = definition.key break end
        end
    end
    if show ~= CurrentPage() then ShowPage(show) else PaintSwitch() end
    if widgets.query and firstFound[show] then ScrollTo(show, firstFound[show]) end
end

--- Show or hide the line under every setting, and fit each page to it.
local function ShowDescriptions(show)
    for _, page in pairs(pages) do
        for _, row in ipairs(page.rows or {}) do
            if row.hint then FitRow(row, show) end
        end
    end
    FitScroll()
end

local function BuildBar(outer)
    local bar = CreateFrame("Frame", nil, outer)
    bar:SetPoint("TOPLEFT", 0, 0)
    bar:SetPoint("TOPRIGHT", 0, 0)
    bar:SetHeight(BAR_HEIGHT)
    widgets.bar = bar

    local rule = Theme.CreateDivider(bar)
    rule:SetPoint("BOTTOMLEFT", COLUMN_ONE_X, 0)
    rule:SetPoint("BOTTOMRIGHT", -16, 0)

    widgets.switch = {}
    for _, definition in ipairs(PAGES) do
        local button = CreateFrame("Button", nil, bar)
        button:SetHeight(22)

        local part = { key = definition.key, button = button }
        part.label = Theme.CreateLabel(button, "small", "muted")
        part.label:SetPoint("LEFT", 0, 0)
        part.label:SetText(definition.text)

        part.underline = button:CreateTexture(nil, "ARTWORK")
        part.underline:SetColorTexture(Theme.Unpack("accent"))
        part.underline:SetHeight(2)
        part.underline:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, 1)
        part.underline:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, 1)
        part.underline:Hide()

        button:SetScript("OnClick", function() ShowPage(definition.key) end)
        button:SetScript("OnEnter", function(self)
            part.hovered = true
            PaintSwitch()
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(definition.tip, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function()
            part.hovered = false
            PaintSwitch()
            GameTooltip:Hide()
        end)

        widgets.switch[#widgets.switch + 1] = part
    end
    LayoutSwitch()

    -- The house order for an option bar: search, then tick boxes.
    widgets.describe = Widgets.CreateCheckbox(bar, L["Show descriptions"], function(checked)
        ns.Config:Set("settingsDescriptions", checked)
        ShowDescriptions(checked)
    end, false)
    widgets.describe:SetPoint("RIGHT", bar, "RIGHT", -16, 0)

    widgets.find = Widgets.CreateSearchBox(bar, L["Find a setting"], Search)
    widgets.find:SetWidth(Widgets.SEARCH_WIDTH or 170)
    widgets.find:SetPoint("RIGHT", widgets.describe, "LEFT", -16, 0)
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

--- While the Disenchanter box is empty, the name picked for the player
--- shows where "Character name" sits, and the row's tooltip says so. A whole
--- name too wide for the box is never cut: the box then says "Picked for
--- you" and the tooltip names them.
local DISENCHANTER_HINT_ROOM = 124
local function ShowPickedDisenchanter()
    local box = widgets.disenchanter
    if not (box and box.hint) then return end
    local picked
    if ns.QueueMail and ns.QueueMail.GuessDisenchanter then
        local ok, name = pcall(ns.QueueMail.GuessDisenchanter, ns.QueueMail)
        picked = ok and name or nil
    end
    box.hint:SetText(picked or L["Character name"])
    if picked and (box.hint:GetStringWidth() or 0) > DISENCHANTER_HINT_ROOM then
        box.hint:SetText(L["Picked for you"])
    end
    local row = widgets.disenchanterRow
    if row then
        row.description = picked
            and L.Format("%s Picked for you now: %s.", widgets.disenchanterTip, picked)
            or widgets.disenchanterTip
    end
end

local function Build(outer)
    local Config = ns.Config

    BuildBar(outer)

    -- Each page scrolls on its own, should one outgrow the window (a long
    -- ignored list, or every description shown). The holder carries the
    -- scrollbar, which sits beside the scrolling area rather than in it, so
    -- hiding a page hides its bar too.
    for _, definition in ipairs(PAGES) do
        local holder = CreateFrame("Frame", nil, outer)
        holder:SetPoint("TOPLEFT", 0, -BAR_HEIGHT - 2)
        holder:SetPoint("BOTTOMRIGHT", 0, 0)
        holder:Hide()

        local scroll = Widgets.CreateScrollFrame(holder, { step = 40 })
        scroll:SetPoint("TOPLEFT", 0, 0)
        scroll:SetPoint("BOTTOMRIGHT", -14, 0)

        pages[definition.key] = {
            key = definition.key, holder = holder, scroll = scroll,
            content = scroll.content, last = {},
        }
    end


    CreateSection(pages.pricing, 1, L["AUCTION PRICES"])

    local undercutRow = CreateRow(pages.pricing, 1, L["Undercut By:"],
        L["How far under the cheapest listing you post. Set 0 to match it."])

    widgets.undercut = Widgets.CreateNumberBox(undercutRow, {
        width = 70, min = 0, max = 1000000,
        onChange = function(value)
            Config:Set("undercutCopper", value)
            UI:RefreshActiveTab()
        end,
    })
    widgets.undercut:SetPoint("TOPLEFT", CONTROL_X, 0)
    AddUnit(undercutRow, widgets.undercut, L["copper"])

    -- No Undercutting on/off button (the owner, 2026-10-15): 0 in the box
    -- matches the cheapest price, and any other number can be typed there.

    -- Overcutting (the owner, 2026-10-15): post just under the big stack
    -- when a few cheap ones below it should sell first. Off unless ticked.
    local overcutRow = CreateRow(pages.pricing, 1, L["Overcutting:"], ns.Profit.OVERCUT_HELP)

    widgets.overcutting = Widgets.CreateCheckbox(overcutRow, L["On"], function(checked)
        Config:Set("overcutting", checked)
        UI:RefreshActiveTab()
        if ns.PostPanel and ns.PostPanel.Refresh then ns.PostPanel:Refresh() end
    end, false)
    widgets.overcutting:SetPoint("TOPLEFT", CONTROL_X, -2)

    local cutRow = CreateRow(pages.pricing, 1, L["Auction House Cut:"],
        L["The share of each sale the auction house keeps."])

    widgets.cut = Widgets.CreateNumberBox(cutRow, {
        width = 70, min = 0, max = 100, decimals = 1,
        onChange = function(value)
            Config:Set("auctionCut", value / 100)
            UI:RefreshActiveTab()
        end,
    })
    widgets.cut:SetPoint("TOPLEFT", CONTROL_X, 0)
    AddUnit(cutRow, widgets.cut, "%")

    local unscannedRow = CreateRow(pages.pricing, 1, L["Markup With No Rivals:"],
        L["When nobody else sells it, your price is the material cost plus this."])

    widgets.unscannedMarkup = Widgets.CreateNumberBox(unscannedRow, {
        width = 70, min = 0, max = 1000,
        onChange = function(value)
            Config:Set("unscannedMarkupPercent", value)
            UI:RefreshActiveTab()
        end,
    })
    widgets.unscannedMarkup:SetPoint("TOPLEFT", CONTROL_X, 0)
    AddUnit(unscannedRow, widgets.unscannedMarkup, L["% markup"])

    local unscannedOnRow = CreateRow(pages.pricing, 1, L["Use That Markup:"],
        L["When off, crafts nobody else sells have no price."])

    widgets.priceUnscanned = Widgets.CreateCheckbox(unscannedOnRow, L["On"], function(checked)
        Config:Set("priceUnscannedCrafts", checked)
        UI:RefreshActiveTab()
    end, true)
    widgets.priceUnscanned:SetPoint("TOPLEFT", CONTROL_X, -2)

    local ownedRow = CreateRow(pages.pricing, 1, L["Charge for Own Materials:"],
        L["When off, materials you already have count as free."])

    widgets.valueOwned = Widgets.CreateCheckbox(ownedRow, L["On"], function(checked)
        Config:Set("valueOwnedMaterials", checked)
        UI:RefreshActiveTab()
    end, true)
    widgets.valueOwned:SetPoint("TOPLEFT", CONTROL_X, -2)

    CreateSection(pages.queue, 1, L["WHAT GETS QUEUED"])
    local postedRow = CreateRow(pages.queue, 1, L["Keep in Stock:"],
        L["The most of each craft to keep. Listings, bags, bank, mail and queue all count. At 0 it keeps about two days of your sales. Set one per profession below or per item on the Profit tab."])

    widgets.maxPosted = Widgets.CreateNumberBox(postedRow, {
        width = 70, min = 0, max = 999,
        onChange = function(value)
            Config:Set("maxPostedPerItem", value)
            UI:RefreshActiveTab()
        end,
    })
    widgets.maxPosted:SetPoint("TOPLEFT", CONTROL_X, 0)

    widgets.maxPostedHint = Theme.CreateLabel(postedRow, "small", "muted")
    widgets.maxPostedHint:SetPoint("LEFT", widgets.maxPosted, "RIGHT", 6, 0)
    widgets.maxPostedHint:SetWidth(120)

    local soldRow = CreateRow(pages.queue, 1, L["Restock What Sells:"],
        L["When an auction sells, another goes in the queue. Never a craft that loses money."])

    widgets.restockOnSale = Widgets.CreateCheckbox(soldRow, L["On"], function(checked)
        Config:Set("restockOnSale", checked)
    end, true)
    widgets.restockOnSale:SetPoint("TOPLEFT", CONTROL_X, -2)

    local sellOutRow = CreateRow(pages.queue, 1, L["Raise When Sold Out:"],
        L["When every copy you listed sells, Keep in Stock goes up by 1. When it comes back unsold 3 times in a row, it goes down by 1, but never below where it started."])

    widgets.raiseOnSellOut = Widgets.CreateCheckbox(sellOutRow, L["On"], function(checked)
        Config:Set("raiseStockOnSellOut", checked)
    end, true)
    widgets.raiseOnSellOut:SetPoint("TOPLEFT", CONTROL_X, -2)

    local learnRow = CreateRow(pages.queue, 1, L["Stock From Sales:"],
        L["At 0, Keep in Stock follows about two days of your sales. Off, crafts with no number are never queued."])

    widgets.learnStock = Widgets.CreateCheckbox(learnRow, L["On"], function(checked)
        Config:Set("learnStockFromSales", checked)
        UI:RefreshActiveTab()
    end, true)
    widgets.learnStock:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- One row each (the owner, 2026-10-15): the number, and beside it the
    -- tick box that turns it on. Same saved keys as the two rows before.
    local restockRow = CreateRow(pages.queue, 1, L["Restock When Down To:"],
        L["Waits until you're down to this many, then makes it back up. Off tops it up right away."])

    widgets.restockAt = Widgets.CreateNumberBox(restockRow, {
        width = 70, min = 0, max = 999,
        onChange = function(value)
            Config:Set("restockAt", value)
            UI:RefreshActiveTab()
        end,
    })
    widgets.restockAt:SetPoint("TOPLEFT", CONTROL_X, 0)

    widgets.restockWhenLow = Widgets.CreateCheckbox(restockRow, L["On"], function(checked)
        Config:Set("restockWhenLow", checked)
        UI:RefreshActiveTab()
    end, true)
    widgets.restockWhenLow:SetPoint("TOPLEFT", CONTROL_X + 82, -2)

    local extraRow = CreateRow(pages.queue, 1, L["Extra for Fast Sellers:"],
        L["Items that sell fast for you can go over Keep in Stock by this many."])

    widgets.fastSellerExtra = Widgets.CreateNumberBox(extraRow, {
        width = 70, min = 0, max = 999,
        onChange = function(value)
            Config:Set("fastSellerExtra", value)
            UI:RefreshActiveTab()
        end,
    })
    widgets.fastSellerExtra:SetPoint("TOPLEFT", CONTROL_X, 0)

    widgets.fastSellerBoost = Widgets.CreateCheckbox(extraRow, L["On"], function(checked)
        Config:Set("fastSellerBoost", checked)
        UI:RefreshActiveTab()
    end, true)
    widgets.fastSellerBoost:SetPoint("TOPLEFT", CONTROL_X + 82, -2)

    local hideMaxedRow = CreateRow(pages.queue, 1, L["Hide Maxed Crafts:"],
        L["Hides crafts at their limit."])

    widgets.hideMaxed = Widgets.CreateCheckbox(hideMaxedRow, L["On"], function(checked)
        Config:Set("hideAtPostLimit", checked)
        UI:RefreshActiveTab()
    end, true)
    widgets.hideMaxed:SetPoint("TOPLEFT", CONTROL_X, -2)

    local subCraftRow = CreateRow(pages.queue, 1, L["Queue Sub-Crafts:"],
        L["Also queues materials that are cheaper to make than buy."])

    widgets.subCrafts = Widgets.CreateCheckbox(subCraftRow, L["On"], function(checked)
        Config:Set("autoQueueSubCrafts", checked)

        -- Sub-crafts are only worked out when the queue changes, so unticking
        -- this left them queued (and ticking it queued none) until then.
        ns.Queue:RebuildDependencies()
        ns.Queue:Notify()
    end, true)
    widgets.subCrafts:SetPoint("TOPLEFT", CONTROL_X, -2)

    local freeSpaceRow = CreateRow(pages.queue, 1, L["Free Bag Space First:"],
        L["Craft Next picks the craft that frees the most bag slots."])

    widgets.freeSpaceFirst = Widgets.CreateCheckbox(freeSpaceRow, L["On"], function(checked)
        Config:Set("craftFreesSpaceFirst", checked)
        UI:RefreshActiveTab()
        if ns.CraftPanel and ns.CraftPanel.UpdateCraftButton then ns.CraftPanel:UpdateCraftButton() end
    end, true)
    widgets.freeSpaceFirst:SetPoint("TOPLEFT", CONTROL_X, -2)

    local altCraftRow = CreateRow(pages.queue, 1, L["Suggest Other Characters:"],
        L["Points out materials an alt can make for less."])

    widgets.altCrafts = Widgets.CreateCheckbox(altCraftRow, L["On"], function(checked)
        Config:Set("suggestOtherCharacters", checked)
        UI:RefreshActiveTab()
    end, true)
    widgets.altCrafts:SetPoint("TOPLEFT", CONTROL_X, -2)

    local followRow = CreateRow(pages.queue, 1, L["Goals Follow the Queue:"],
        L["With Farmer, goals from Set Goal change with the queue."])

    widgets.followGoals = Widgets.CreateCheckbox(followRow, L["On"], function(checked)
        Config:Set("farmerGoalsFollowQueue", checked)
        if checked then ns.FarmerGoals:Follow() end
    end, true)
    widgets.followGoals:SetPoint("TOPLEFT", CONTROL_X, -2)

    local shareRow = CreateRow(pages.queue, 1, L["Alts Make Sub-Crafts:"],
        L["Puts a sub-craft on the alt who can make it, and the mailbox lists what to send."])

    widgets.shareQueue = Widgets.CreateCheckbox(shareRow, L["On"], function(checked)
        Config:Set("queueAltCrafting", checked)
        -- Who makes each sub-craft is worked out when the queue is rebuilt,
        -- and a part an alt makes is priced at its materials only while on.
        if ns.Cost.Changed then
            ns.Cost:Changed()
        else
            ns.Queue:RebuildDependencies()
            ns.Queue:Notify()
        end
    end, false)
    widgets.shareQueue:SetPoint("TOPLEFT", CONTROL_X, -2)

    CreateSection(pages.mail, 1, L["AT THE MAILBOX"])
    local queueMailRow = CreateRow(pages.mail, 1, L["Queue Mail:"],
        L["At the mailbox, lists what to send your alts with a button that fills in the mail."])

    widgets.queueMail = Widgets.CreateCheckbox(queueMailRow, L["Show"], function(checked)
        Config:Set("queueMailPanel", checked)
        if ns.QueueMailPanel then ns.QueueMailPanel:Refresh() end
    end, true)
    widgets.queueMail:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- Asked 2026-10-04: a character to mail gear to for disenchanting.
    -- Typed rather than picked, so one on another account works too.
    local disenchanterRow = CreateRow(pages.mail, 1, L["Disenchanter:"],
        L["The character you mail gear to for disenchanting. Leave it empty to pick your alt with the most Enchanting."])
    widgets.disenchanterRow = disenchanterRow
    widgets.disenchanterTip = disenchanterRow.description

    widgets.disenchanter = Widgets.CreateSearchBox(disenchanterRow, L["Character name"], function(text)
        local trimmed = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
        Config:Set("disenchanterName", trimmed)
        if ns.QueueMailPanel then ns.QueueMailPanel:Refresh() end
    end)
    widgets.disenchanter:SetWidth(150)
    widgets.disenchanter:SetPoint("TOPLEFT", CONTROL_X, 0)
    -- A letter where the search box has its magnifier: this is a name.
    if widgets.disenchanter.icon then
        widgets.disenchanter.icon:SetTexture([[Interface\Minimap\Tracking\Mailbox]])
        widgets.disenchanter.icon:SetSize(14, 14)
    end
    -- Escape puts the saved name back rather than clearing it.
    widgets.disenchanter.editBox:SetScript("OnEscapePressed", function(self)
        self:SetText(Config:Get("disenchanterName") or "")
        self:ClearFocus()
    end)

    -- Asked 2026-10-11 (the owner: the addons should do the work).
    local guessRow = CreateRow(pages.mail, 1, L["Pick One for Me:"],
        L["When the box is empty, picks your best enchanter."])

    widgets.disenchanterGuess = Widgets.CreateCheckbox(guessRow, L["On"], function(checked)
        Config:Set("disenchanterGuess", checked)
        if ns.QueueMailPanel then ns.QueueMailPanel:Refresh() end
        ShowPickedDisenchanter()
    end, true)
    widgets.disenchanterGuess:SetPoint("TOPLEFT", CONTROL_X, -2)

    local disenchantQualityRow = CreateRow(pages.mail, 1, L["Mail Gear Up To:"],
        L["The best quality that goes to your disenchanter."])

    widgets.disenchantQuality = Widgets.CreateDropdown(disenchantQualityRow, {
        { text = L["Greens only"], value = 2 },
        { text = L["Greens and blues"], value = 3 },
        { text = L["Up to purples"], value = 4 },
    }, function(value)
        Config:Set("disenchanterQuality", value)
        if ns.QueueMailPanel then ns.QueueMailPanel:Refresh() end
    end, { width = 150 })
    widgets.disenchantQuality:SetPoint("TOPLEFT", CONTROL_X, 0)

    -- Asked 2026-10-05: big shuffles taken from the mail a bagful at a time.
    local spareRow = CreateRow(pages.mail, 1, L["Bag Slots Kept Free:"],
        L["Take Next Batch leaves this many slots empty."])

    widgets.bagSpare = Widgets.CreateNumberBox(spareRow, {
        width = 70, min = 0, max = 50,
        onChange = function(value)
            Config:Set("bagSpareSlots", value)
            if ns.QueueMailPanel then ns.QueueMailPanel:Refresh() end
        end,
    })
    widgets.bagSpare:SetPoint("TOPLEFT", CONTROL_X, 0)

    local mailBatchRow = CreateRow(pages.mail, 1, L["Take Mail in Batches:"],
        L["A button at the mailbox takes the queue's materials, as much as fits. Never COD mail."])

    widgets.mailBatch = Widgets.CreateCheckbox(mailBatchRow, L["Show"], function(checked)
        Config:Set("mailBatchTake", checked)
        if ns.QueueMailPanel then ns.QueueMailPanel:Refresh() end
    end, false)
    widgets.mailBatch:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- Asked 2026-10-07: each queue row says AH, DE or Vendor, and what the
    -- queue made on DE or Vendor can be disenchanted or sold from here.
    local deNextRow = CreateRow(pages.queue, 1, L["Disenchant Next Button:"],
        L["A button that disenchants the next item your queue marked DE, one per click."])

    widgets.deNext = Widgets.CreateCheckbox(deNextRow, L["On"], function(checked)
        Config:Set("queueDisenchantNext", checked)
        UI:RefreshActiveTab()
    end, false)
    widgets.deNext:SetPoint("TOPLEFT", CONTROL_X, -2)

    CreateSection(pages.mail, 2, L["AT VENDORS"])
    local sellMarkedRow = CreateRow(pages.mail, 2, L["Sell Marked Items:"],
        L["A button at vendors sells what your queue marked Vendor, up to 12 a visit."])

    widgets.sellMarked = Widgets.CreateCheckbox(sellMarkedRow, L["Show"], function(checked)
        Config:Set("sellMarkedButton", checked)
        if ns.SellMarked then ns.SellMarked:Update() end
    end, true)
    widgets.sellMarked:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- Logic/VendorPins.lua (asked 2026-10-18): gold pins on the world map
    -- at vendors that sell what the queue needs for less.
    local vendorPinsRow = CreateRow(pages.mail, 2, L["Vendor Map Pins:"],
        L["Pins vendors on your world map that sell what your queue needs for less than the auction house."])

    widgets.vendorMapPins = Widgets.CreateCheckbox(vendorPinsRow, L["On"], function(checked)
        if ns.VendorPins then ns.VendorPins:SetOn(checked) else Config:Set("vendorMapPins", checked) end
    end, false)
    widgets.vendorMapPins:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- Asked 2026-10-06: the buy window opened at 1 after a Buy list search.
    CreateSection(pages.auction, 1, L["BUYING AND POSTING"])
    local fillBuyRow = CreateRow(pages.auction, 1, L["Fill In Buy Amount:"],
        L["Fills the quantity box with how many the queue still needs."])

    widgets.fillBuy = Widgets.CreateCheckbox(fillBuyRow, L["On"], function(checked)
        Config:Set("fillBuyQuantity", checked)
    end, true)
    widgets.fillBuy:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- The owner, 2026-10-13: Red Dye was sent to the auction house.
    local vendorAuctionRow = CreateRow(pages.auction, 1, L["AH for Vendor Items:"],
        L["Sends you to the auction house for vendor items when they're cheaper there."])

    widgets.vendorAuction = Widgets.CreateCheckbox(vendorAuctionRow, L["On"], function(checked)
        Config:Set("vendorItemsOnAuction", checked)
        if ns.Queue and ns.Queue.Notify then ns.Queue:Notify() end
        UI:RefreshActiveTab()
    end, false)
    widgets.vendorAuction:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- Asked 2026-10-11: the real cost of many could run far past the estimate.
    local buyWarnRow = CreateRow(pages.auction, 1, L["Warn When Price Is Higher:"],
        L["Warns under Buy Now when a material costs this much more than expected. 0 turns it off."])

    widgets.buyWarn = Widgets.CreateNumberBox(buyWarnRow, {
        width = 70, min = 0, max = 500,
        onChange = function(value)
            Config:Set("buyWarnPercent", value)
            if ns.BuyQuantity then ns.BuyQuantity:CheckCostSoon() end
        end,
    })
    widgets.buyWarn:SetPoint("TOPLEFT", CONTROL_X, 0)
    local buyWarnUnit = Theme.CreateLabel(buyWarnRow, "small", "muted")
    buyWarnUnit:SetPoint("LEFT", widgets.buyWarn, "RIGHT", 6, 0)
    buyWarnUnit:SetText(L["% over"])

    CreateSection(pages.pricing, 1, L["WHEN TO SELL"])
    local lossRow = CreateRow(pages.pricing, 1, L["Sell at a Loss:"],
        L["When off, losses show in red but aren't listed."])

    widgets.allowLoss = Widgets.CreateCheckbox(lossRow, L["On"], function(checked)
        Config:Set("allowPostingAtALoss", checked)
        UI:RefreshActiveTab()
    end, false)
    widgets.allowLoss:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- Asked by a player on 2026-10-05: the guard above compares with what the
    -- materials cost today; this one with what the last craft actually cost.
    local paidRow = CreateRow(pages.pricing, 1, L["Never Below What I Paid:"],
        L["Won't list a craft for less than it cost to make."])

    widgets.neverBelowPaid = Widgets.CreateCheckbox(paidRow, L["On"], function(checked)
        Config:Set("neverBelowCraftedCost", checked)
        UI:RefreshActiveTab()
        if ns.PostPanel and ns.PostPanel.Refresh then ns.PostPanel:Refresh() end
    end, false)
    widgets.neverBelowPaid:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- Logic/SisterKeeps.lua (2026-10-16): what the other Blackthornes
    -- addons want kept stays off List all.
    local sisterKeepsRow = CreateRow(pages.pricing, 1, L["Keep What Other Addons Need:"],
        L["Goal items, your upgrades and pet food stay off List all. What Butler keeps always does."])

    widgets.sisterKeeps = Widgets.CreateCheckbox(sisterKeepsRow, L["On"], function(checked)
        Config:Set("sellHoldsSisterKeeps", checked)
        if ns.SisterKeeps then ns.SisterKeeps:Forget() end
        UI:RefreshActiveTab()
        if ns.PostPanel and ns.PostPanel.Refresh then ns.PostPanel:Refresh() end
    end, false)
    widgets.sisterKeeps:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- Off unless ticked (the owner, 2026-10-16): gear for another
    -- character goes up with everything else.
    local altKeepsRow = CreateRow(pages.pricing, 1, L["Keep Upgrades for Alts:"],
        L["Gear your other characters could wear stays off List all."])

    widgets.altKeeps = Widgets.CreateCheckbox(altKeepsRow, L["On"], function(checked)
        Config:Set("sellHoldsAltUpgrades", checked)
        if ns.SisterKeeps then ns.SisterKeeps:Forget() end
        UI:RefreshActiveTab()
        if ns.PostPanel and ns.PostPanel.Refresh then ns.PostPanel:Refresh() end
    end, false)
    widgets.altKeeps:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- No "Confirm before each listing" switch: the confirmation's Yes is the
    -- click that lists. Posting needs a real click, and after the price
    -- check (an auction house search, answered later) there is no other.
    -- The switch never did anything; its saved value is left where it is.
    local verifyRow = CreateRow(pages.auction, 1, L["Check Price First:"],
        L["Searches for the item first so your price is current."])

    widgets.verifyPrice = Widgets.CreateCheckbox(verifyRow, L["On"], function(checked)
        Config:Set("verifyPriceBeforePosting", checked)
    end, true)
    widgets.verifyPrice:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- Fast listing (the owner, 2026-10-14): a fresh price lists on the
    -- click, with no Yes/No box. Unticked, every listing asks first.
    local fastRow = CreateRow(pages.auction, 1, L["Fast Listing:"],
        L["List All checks every price at once, then each click lists one with no Yes or No."])

    widgets.fastListing = Widgets.CreateCheckbox(fastRow, L["On"], function(checked)
        Config:Set("fastListing", checked)
    end, true)
    widgets.fastListing:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- The mouse wheel (a player asked, the owner said build it, 2026-10-16):
    -- off unless ticked, and only while the auction house is open.
    local wheelRow = CreateRow(pages.auction, 1, L["Mouse Wheel:"],
        L["At the auction house, wheel up lists the next stack and wheel down cancels the next undercut auction."])

    widgets.mouseWheel = Widgets.CreateCheckbox(wheelRow, L["On"], function(checked)
        Config:Set("mouseWheelListing", checked)
        if ns.AuctionWheel then ns.AuctionWheel:Update() end
    end, false)
    widgets.mouseWheel:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- The sale alarm and the scan chime moved down to SOUNDS, with a switch
    -- for every other sound (2026-10-02).
    CreateSection(pages.mail, 2, L["AFTER A SALE"])
    local mailReportRow = CreateRow(pages.mail, 2, L["Mail Report:"],
        L["Shows what you collected when you leave the mailbox."])

    widgets.mailReport = Widgets.CreateCheckbox(mailReportRow, L["On"], function(checked)
        Config:Set("mailReport", checked)
    end, true)
    widgets.mailReport:SetPoint("TOPLEFT", CONTROL_X, -2)

    local mailPreviewRow = CreateRow(pages.mail, 2, L["Sample Mail Report:"])

    local mailReportTest = Widgets.CreateButton(mailPreviewRow, L["Preview"], function()
        if ns.MailReport and ns.MailHaul then ns.MailReport:Show(ns.MailHaul:Sample()) end
    end, { width = 70, height = 20 })
    mailReportTest:SetPoint("TOPLEFT", CONTROL_X, -2)
    FitButton(mailReportTest)

    -- Requested by a player whose chat filled with sale lines: the Sales tab
    -- keeps every sale, so the chat copy can go.
    local saleChatRow = CreateRow(pages.mail, 2, L["Hide Sale Messages:"],
        L["Keeps \"A buyer has been found\" out of chat."])

    widgets.hideSaleChat = Widgets.CreateCheckbox(saleChatRow, L["On"], function(checked)
        Config:Set("hideSaleChat", checked)
        if checked and ns.SaleAlarm then ns.SaleAlarm:InstallChatHider() end
    end, false)
    widgets.hideSaleChat:SetPoint("TOPLEFT", CONTROL_X, -2)

    CreateSection(pages.pricing, 2, L["WHAT COUNTS AS PROFIT"])

    local profitRow = CreateRow(pages.pricing, 2, L["Minimum Profit:"],
        L["Crafts that make less than this are hidden on the Profit tab."])

    widgets.minProfit = Widgets.CreateNumberBox(profitRow, {
        width = 70, min = 0, max = 1000000,
        onChange = function(value)
            -- Entered in silver: copper is unusable at realistic values.
            Config:Set("minProfit", value * 100)
            widgets.minProfitPreview:SetText(Util.FormatMoney(value * 100, { short = true }))
            UI:RefreshActiveTab()
        end,
    })
    widgets.minProfit:SetPoint("TOPLEFT", CONTROL_X, 0)

    widgets.minProfitPreview = Theme.CreateLabel(profitRow, "small", "muted")
    widgets.minProfitPreview:SetPoint("LEFT", widgets.minProfit, "RIGHT", 6, 0)
    widgets.minProfitPreview:SetWidth(100)

    local marginRow = CreateRow(pages.pricing, 2, L["Minimum Margin:"],
        L["Profit as a share of the sale price."])

    widgets.minMargin = Widgets.CreateNumberBox(marginRow, {
        width = 70, min = 0, max = 100,
        onChange = function(value)
            Config:Set("minMarginPercent", value)
            UI:RefreshActiveTab()
        end,
    })
    widgets.minMargin:SetPoint("TOPLEFT", CONTROL_X, 0)
    AddUnit(marginRow, widgets.minMargin, "%")

    CreateSection(pages.pricing, 2, L["PRICE AGE"])
    local staleRow = CreateRow(pages.pricing, 2, L["Prices Go Stale After:"],
        L["Older prices are greyed out but still used."])

    widgets.stale = Widgets.CreateDropdown(staleRow, {
        { text = L["12 hours"], value = 12 * 3600 },
        { text = L["24 hours"], value = 24 * 3600 },
        { text = L["2 days"], value = 48 * 3600 },
        { text = L["7 days"], value = 7 * 24 * 3600 },
    }, function(value)
        Config:Set("staleAfterSeconds", value)
        UI:RefreshActiveTab()
    end, { width = 110 })
    widgets.stale:SetPoint("TOPLEFT", CONTROL_X, 0)

    -- Keep in stock by profession (a player asked, the owner agreeing
    -- 2026-10-13): one box per profession your characters craft with,
    -- empty for the usual number. Rows made in Refresh, as the lists
    -- below are.
    widgets.ignoredParent = pages.queue.content
    local stockSection = CreateSection(pages.queue, 2, L["KEEP IN STOCK BY PROFESSION"])
    Searchable(pages.queue, stockSection, L["Keep in stock by profession per profession alchemy blacksmithing tailoring leatherworking stock limit"])

    local stockHint = Theme.CreateLabel(pages.queue.content, "tiny", "muted")
    stockHint:SetPoint("TOPLEFT", stockSection, "BOTTOMLEFT", 0, ROW_GAP)
    stockHint:SetWidth(COLUMN_WIDTH)
    stockHint:SetWordWrap(true)
    stockHint:SetText(L["Leave a box empty to use Keep in Stock. A number on one item in the Profit tab still wins."])
    widgets.stockHint = stockHint

    widgets.stockEmpty = Theme.CreateLabel(pages.queue.content, "small", "dim")
    widgets.stockEmpty:SetWidth(COLUMN_WIDTH)
    widgets.stockEmpty:SetWordWrap(true)
    widgets.stockEmpty:SetText(L["None yet. Open a profession window on each character once, and its professions show here."])
    widgets.stockRows = {}

    local stockEnd = CreateFrame("Frame", nil, pages.queue.content)
    stockEnd:SetSize(COLUMN_WIDTH, 1)
    stockEnd:SetPoint("TOPLEFT", widgets.stockEmpty, "BOTTOMLEFT", 0, 0)
    widgets.stockEnd = stockEnd
    pages.queue.last[2] = stockEnd

    -- Items Raise When Sold Out changed (the owner, 2026-10-16), with
    -- Reset to put each back. Rows made in Refresh, as the lists below are.
    local changed = CreateSection(pages.queue, 2, L["CHANGED WHEN SOLD OUT"])
    widgets.changedSection = changed
    Searchable(pages.queue, changed, L["Changed when sold out raise when sold out keep in stock reset"])

    local changedHint = Theme.CreateLabel(pages.queue.content, "tiny", "muted")
    changedHint:SetPoint("TOPLEFT", changed, "BOTTOMLEFT", 0, ROW_GAP)
    changedHint:SetWidth(COLUMN_WIDTH)
    changedHint:SetWordWrap(true)
    changedHint:SetText(L["Keep in Stock numbers that Raise When Sold Out changed. Click Reset to put one back."])
    widgets.changedHint = changedHint

    widgets.changedEmpty = Theme.CreateLabel(pages.queue.content, "small", "dim")
    widgets.changedEmpty:SetWidth(COLUMN_WIDTH)
    widgets.changedEmpty:SetWordWrap(true)
    widgets.changedEmpty:SetText(L["None yet."])
    widgets.changedRows = {}

    local changedEnd = CreateFrame("Frame", nil, pages.queue.content)
    changedEnd:SetSize(COLUMN_WIDTH, 1)
    changedEnd:SetPoint("TOPLEFT", widgets.changedEmpty, "BOTTOMLEFT", 0, 0)
    widgets.changedEnd = changedEnd
    pages.queue.last[2] = changedEnd

    -- Crafts never made to go into another craft (2026-10-07),
    -- marked from the Level Up tab or the x on a queued sub-craft. Laid out
    -- as Ignored crafts below is, rows made in Refresh.
    local never = CreateSection(pages.queue, 2, L["NEVER MADE AS SUB-CRAFTS"])
    widgets.neverSection = never
    Searchable(pages.queue, never, L["Never made as sub-crafts bought instead intermediates allow light leather"])

    local neverHint = Theme.CreateLabel(pages.queue.content, "tiny", "muted")
    neverHint:SetPoint("TOPLEFT", never, "BOTTOMLEFT", 0, ROW_GAP)
    neverHint:SetWidth(COLUMN_WIDTH)
    neverHint:SetWordWrap(true)
    neverHint:SetText(L["These are bought, not made, when another craft needs them. Click Allow to put one back."])
    widgets.neverHint = neverHint

    widgets.neverEmpty = Theme.CreateLabel(pages.queue.content, "small", "dim")
    widgets.neverEmpty:SetWidth(COLUMN_WIDTH)
    widgets.neverEmpty:SetWordWrap(true)
    widgets.neverEmpty:SetText(L["None. Click Make beside a craft on the Level Up tab (tick Sub-crafts only), or the x on a sub-craft in the queue."])
    widgets.neverRows = {}

    local neverEnd = CreateFrame("Frame", nil, pages.queue.content)
    neverEnd:SetSize(COLUMN_WIDTH, 1)
    neverEnd:SetPoint("TOPLEFT", widgets.neverEmpty, "BOTTOMLEFT", 0, 0)
    widgets.neverEnd = neverEnd
    pages.queue.last[2] = neverEnd

    -- Crafts taken off the Profit tab with its Ignore button. The rows are
    -- made in Refresh, one per craft, since the list grows and shrinks.
    local ignored = CreateSection(pages.queue, 2, L["IGNORED CRAFTS"])
    widgets.ignoredSection = ignored
    Searchable(pages.queue, ignored, L["Ignored crafts Restore puts one back on the Profit tab"])

    local ignoredHint = Theme.CreateLabel(pages.queue.content, "tiny", "muted")
    ignoredHint:SetPoint("TOPLEFT", ignored, "BOTTOMLEFT", 0, ROW_GAP)
    ignoredHint:SetWidth(COLUMN_WIDTH)
    ignoredHint:SetWordWrap(true)
    ignoredHint:SetText(L["These never show on the Profit tab, on any character. Click Restore to bring one back."])
    widgets.ignoredHint = ignoredHint

    widgets.ignoredEmpty = Theme.CreateLabel(pages.queue.content, "small", "dim")
    widgets.ignoredEmpty:SetWidth(COLUMN_WIDTH)
    widgets.ignoredEmpty:SetWordWrap(true)
    widgets.ignoredEmpty:SetText(L["None. Pick a craft on the Profit tab and click Ignore."])
    widgets.ignoredRows = {}

    -- Where the ignored crafts end, moved under the last of them in Refresh,
    -- so the section below follows the list as it grows and shrinks.
    local ignoredEnd = CreateFrame("Frame", nil, pages.queue.content)
    ignoredEnd:SetSize(COLUMN_WIDTH, 1)
    ignoredEnd:SetPoint("TOPLEFT", widgets.ignoredEmpty, "BOTTOMLEFT", 0, 0)
    widgets.ignoredEnd = ignoredEnd

    -- Items taken off Ready to sell at the auction house with the x on
    -- their row (2026-10-04). Laid out as Ignored crafts is.
    pages.queue.last[2] = ignoredEnd
    local ignoredItems = CreateSection(pages.queue, 2, L["IGNORED ITEMS"])
    widgets.ignoredItemsSection = ignoredItems
    Searchable(pages.queue, ignoredItems, L["Ignored items Restore puts one back on Ready to sell"])

    local ignoredItemsHint = Theme.CreateLabel(pages.queue.content, "tiny", "muted")
    ignoredItemsHint:SetPoint("TOPLEFT", ignoredItems, "BOTTOMLEFT", 0, ROW_GAP)
    ignoredItemsHint:SetWidth(COLUMN_WIDTH)
    ignoredItemsHint:SetWordWrap(true)
    ignoredItemsHint:SetText(L["These are never offered for sale on Ready to sell, on any character. Click Restore to bring one back."])
    widgets.ignoredItemsHint = ignoredItemsHint

    widgets.ignoredItemsEmpty = Theme.CreateLabel(pages.queue.content, "small", "dim")
    widgets.ignoredItemsEmpty:SetWidth(COLUMN_WIDTH)
    widgets.ignoredItemsEmpty:SetWordWrap(true)
    widgets.ignoredItemsEmpty:SetText(L["None. Click the x on an item in Ready to sell at the auction house."])
    widgets.ignoredItemsRows = {}

    local ignoredItemsEnd = CreateFrame("Frame", nil, pages.queue.content)
    ignoredItemsEnd:SetSize(COLUMN_WIDTH, 1)
    ignoredItemsEnd:SetPoint("TOPLEFT", widgets.ignoredItemsEmpty, "BOTTOMLEFT", 0, 0)
    widgets.ignoredItemsEnd = ignoredItemsEnd

    -- What this character keeps back from the Sell list (Logic/KeepHere.lua,
    -- a player asked, the owner said build it 2026-10-18). Set by
    -- right-clicking a Sell list row; Clear takes one off.
    pages.queue.last[2] = ignoredItemsEnd
    local keepHere = CreateSection(pages.queue, 2, L["KEEP ON THIS CHARACTER"])
    widgets.keepHereSection = keepHere
    Searchable(pages.queue, keepHere, L["Keep on this character Sell list right-click"])

    widgets.keepHereEmpty = Theme.CreateLabel(pages.queue.content, "small", "dim")
    widgets.keepHereEmpty:SetWidth(COLUMN_WIDTH)
    widgets.keepHereEmpty:SetWordWrap(true)
    widgets.keepHereEmpty:SetText(L["Right-click an item on the Sell list to keep some on this character."])
    widgets.keepHereRows = {}

    local data = CreateSection(pages.data, 1, L["SAVED DATA"])

    -- All four wrap: "last scan 3h ago (stopped at the page limit)" and the
    -- bank and auction warnings are longer than the column, and were cut
    -- off. Refresh measures the page after setting them.
    widgets.dataSummary = Theme.CreateLabel(pages.data.content, "small", "text")
    widgets.dataSummary:SetPoint("TOPLEFT", data, "BOTTOMLEFT", 0, -6)
    widgets.dataSummary:SetWidth(COLUMN_WIDTH)
    widgets.dataSummary:SetWordWrap(true)

    widgets.recipeSummary = Theme.CreateLabel(pages.data.content, "small", "text")
    widgets.recipeSummary:SetPoint("TOPLEFT", widgets.dataSummary, "BOTTOMLEFT", 0, -4)
    widgets.recipeSummary:SetWidth(COLUMN_WIDTH)
    widgets.recipeSummary:SetWordWrap(true)

    widgets.bankSummary = Theme.CreateLabel(pages.data.content, "tiny", "dim")
    widgets.bankSummary:SetPoint("TOPLEFT", widgets.recipeSummary, "BOTTOMLEFT", 0, -6)
    widgets.bankSummary:SetWidth(COLUMN_WIDTH)
    widgets.bankSummary:SetWordWrap(true)

    widgets.auctionSummary = Theme.CreateLabel(pages.data.content, "tiny", "dim")
    widgets.auctionSummary:SetPoint("TOPLEFT", widgets.bankSummary, "BOTTOMLEFT", 0, -4)
    widgets.auctionSummary:SetWidth(COLUMN_WIDTH)
    widgets.auctionSummary:SetWordWrap(true)

    widgets.loadWarning = Theme.CreateLabel(pages.data.content, "tiny", "warn")
    widgets.loadWarning:SetPoint("TOPLEFT", widgets.auctionSummary, "BOTTOMLEFT", 0, -6)
    widgets.loadWarning:SetWidth(COLUMN_WIDTH)
    widgets.loadWarning:SetWordWrap(true)

    pages.data.last[1] = widgets.loadWarning
    local pruneRow = CreateRow(pages.data, 1, L["Remove Old Prices:"],
        L["Drops items not seen at the auction house for 21 days."])
    pruneRow:ClearAllPoints()
    pruneRow:SetPoint("TOPLEFT", widgets.loadWarning, "BOTTOMLEFT", 0, -18)
    local pruneButton = Widgets.CreateButton(pruneRow, L["Remove"], function()
        local removed = ns.Prices:Prune()
        ns.Print(L.Format("removed %d old price(s)", removed))
        UI:RefreshActiveTab()
    end, { width = 80, height = 20 })
    pruneButton:SetPoint("TOPLEFT", CONTROL_X, -2)
    FitButton(pruneButton)

    -- Clear price data and Reset to defaults are typed commands now (the
    -- owner, 2026-10-15): /bts clearprices confirm and /bts reset confirm.
    -- Settings never deletes data.

    CreateSection(pages.queue, 1, L["EXPORT AND IMPORT"])
    local exportButton = Widgets.CreateButton(pages.queue.content, L["Export"], function()
        UI:ShowTransferDialog("export")
    end, { width = 100, height = 22,
           tooltip = L["Copy your queue, settings and stock limits as a code."] })
    Place(pages.queue, 1, exportButton, -8)
    FitButton(exportButton)

    local importButton = Widgets.CreateButton(pages.queue.content, L["Import"], function()
        UI:ShowTransferDialog("import")
    end, { width = 100, height = 22,
           tooltip = L["Load a code."] })
    FitButton(importButton)
    importButton:SetPoint("LEFT", exportButton, "RIGHT", 8, 0)

    CreateSection(pages.auction, 2, L["SCANNING"])

    local budgetRow = CreateRow(pages.auction, 2, L["Scan Speed:"],
        L["Higher is faster, but the game can stutter."])

    widgets.budget = Widgets.CreateNumberBox(budgetRow, {
        width = 60, min = 2, max = 16,
        onChange = function(value) Config:Set("scanBudgetMs", value) end,
    })
    widgets.budget:SetPoint("TOPLEFT", CONTROL_X, 0)
    AddUnit(budgetRow, widgets.budget, L["ms"])

    local autoScanRow = CreateRow(pages.auction, 2, L["Auto Scan:"],
        L["Scans when the auction house opens and prices are old or missing."])

    widgets.autoScan = Widgets.CreateCheckbox(autoScanRow, L["On"], function(checked)
        Config:Set("autoScan", checked)
    end, true)
    widgets.autoScan:SetPoint("TOPLEFT", CONTROL_X, -2)

    local learnRow = CreateRow(pages.auction, 2, L["Learn From Searches:"],
        L["Also takes prices from your own searches."])

    widgets.learnFromSearches = Widgets.CreateCheckbox(learnRow, L["On"], function(checked)
        Config:Set("learnFromSearches", checked)
    end, true)
    widgets.learnFromSearches:SetPoint("TOPLEFT", CONTROL_X, -2)

    CreateSection(pages.look, 1, L["SHOWN IN THE GAME"])
    local professionValueRow = CreateRow(pages.look, 1, L["Value in Profession Window:"],
        L["Shows what each recipe sells for beside its name."])

    widgets.professionValue = Widgets.CreateCheckbox(professionValueRow, L["On"], function(checked)
        Config:Set("showValueInProfessionWindow", checked)
        if ns.RecipeValue then ns.RecipeValue:Refresh() end
    end, true)
    widgets.professionValue:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- Off, Shift or Always for each tooltip line (asked 2026-10-18, see
    -- UI/TooltipShift.lua). Whether the line is on stays in its own
    -- setting; Shift is kept beside it. The sales lines have no Off.
    local function ShiftDropdown(row, key, setting, onChange)
        local Shift = ns.TooltipShift
        local options = {}
        if setting then options[#options + 1] = { text = Shift.NAMES[Shift.OFF], value = Shift.OFF } end
        options[#options + 1] = { text = Shift.NAMES[Shift.SHIFT], value = Shift.SHIFT }
        options[#options + 1] = { text = Shift.NAMES[Shift.ALWAYS], value = Shift.ALWAYS }

        local dropdown = Widgets.CreateDropdown(row, options, function(mode)
            local isOn = setting == nil or Config:Get(setting) ~= false
            Shift:Apply(mode, key, isOn, setting and function(on)
                Config:Set(setting, on)
                if onChange then onChange() end
            end or nil)
        end, { width = 110 })
        dropdown:SetPoint("TOPLEFT", CONTROL_X, 0)
        dropdown.shiftKey, dropdown.shiftSetting = key, setting
        return dropdown
    end

    local tooltipValueRow = CreateRow(pages.look, 1, L["Value on Tooltips:"])

    widgets.tooltipValue = ShiftDropdown(tooltipValueRow, "value", "showValueOnItemTooltips")

    -- Asked 2026-10-13: the sales lines under Demand, kept for Shift.
    local salesShiftRow = CreateRow(pages.look, 1, L["Sales Details:"],
        L["The sales lines under Demand."])

    widgets.tooltipSalesShift = ShiftDropdown(salesShiftRow, "sales", nil)

    -- Asked 2026-10-14: the Prices tab's trend on the tooltip too.
    local trendRow = CreateRow(pages.look, 1, L["Price Trend on Tooltips:"],
        L["How much the price moved from its 7 or 14 day average."])

    widgets.tooltipTrend = ShiftDropdown(trendRow, "trend", "tooltipTrend")

    -- Asked 2026-10-05: is a recipe worth buying, at a glance. The button
    -- is /bts recipes.
    local recipeTipRow = CreateRow(pages.look, 1, L["Recipe Value on Tooltips:"],
        L["On a recipe, shows its cost, what it sells for, and how many crafts pay it back."])

    widgets.recipeTooltips = ShiftDropdown(recipeTipRow, "recipe", "showRecipeValueOnTooltips")

    -- Asked 2026-10-14: what an enchant's materials cost, on its tooltip.
    local enchantTipRow = CreateRow(pages.look, 1, L["Enchant Costs on Tooltips:"],
        L["On an enchant, shows what each material costs and who knows it."])

    widgets.enchantTooltips = ShiftDropdown(enchantTipRow, "enchant", "tooltipEnchantCosts", function()
        if ns.EnchantTooltip and ns.EnchantTooltip.Forget then ns.EnchantTooltip:Forget() end
    end)

    -- Asked 2026-10-20: what a Waylaid Crate costs to fill, on its tooltip.
    -- Only where the crates exist (not on Era).
    if ns.MerchantsFavor then
        local crateTipRow = CreateRow(pages.look, 1, L["Crate Costs:"])

        widgets.crateTooltips = ShiftDropdown(crateTipRow, "crate", "tooltipCrateCosts")
    end

    -- Its own row (a player's report, 2026-10-09): beside the tick box it
    -- started 340 pixels in and ran past the column into the next one.
    local recipeListRow = CreateRow(pages.look, 1, L["Recipes to Learn:"])

    local recipeList = Widgets.CreateButton(recipeListRow, L["Open"], function()
        if ns.ProfitTab and ns.ProfitTab.ShowRecipesToLearn then ns.ProfitTab.ShowRecipesToLearn() end
    end, { width = 60, height = 20 })
    recipeList:SetPoint("TOPLEFT", CONTROL_X, -2)
    FitButton(recipeList)

    local upgradeRow = CreateRow(pages.look, 1, L["Upgrade Arrows:"],
        L["A green arrow on gear that's an upgrade for you. Needs Blackthornes Equipment."])

    widgets.upgradeArrows = Widgets.CreateCheckbox(upgradeRow, L["On"], function(checked)
        Config:Set("showUpgradeArrows", checked)
        if ns.Upgrades then ns.Upgrades:Forget() end
        UI:RefreshActiveTab()
    end, true)
    widgets.upgradeArrows:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- Logic/Cooldowns.lua (asked 2026-10-12): a line in chat when a
    -- transmute, Mooncloth or the Salt Shaker is ready on any character,
    -- and a step for it in Blackthornes Butler. The list stays typed:
    -- /bts cooldowns (the owner, 2026-10-15).
    local cooldownRow = CreateRow(pages.look, 1, L["Profession Cooldowns:"],
        L["Says in chat when a transmute, Mooncloth or the Salt Shaker is ready."])

    widgets.cooldownAlerts = Widgets.CreateCheckbox(cooldownRow, L["On"], function(checked)
        Config:Set("cooldownAlerts", checked)
        if ns.Cooldowns then ns.Cooldowns:Schedule() end
    end, true)
    widgets.cooldownAlerts:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- Logic/CraftRequests.lua (asked 2026-10-12): a line in chat when
    -- someone in Trade asks for something one of your characters makes.
    local requestsRow = CreateRow(pages.look, 1, L["Trade Requests:"],
        L["Says in chat when someone in Trade asks for something you can make."])

    widgets.tradeRequests = Widgets.CreateCheckbox(requestsRow, L["On"], function(checked)
        Config:Set("tradeRequests", checked)
    end, false)
    widgets.tradeRequests:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- Core/SisterNote.lua: one chat line, once, naming the Blackthornes
    -- addons the player does not have. Off here is off in all of them.
    local sistersRow = CreateRow(pages.look, 1, L["Sister Addons:"],
        L["Says once in chat which Blackthornes addons you don't have."])

    widgets.sisters = Widgets.CreateCheckbox(sistersRow, L["On"], function(checked)
        ns.SisterNote:SetOn(checked)
    end, true)
    widgets.sisters:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- UI/WhatsNew.lua: one window after an update for every Blackthornes
    -- addon. Off here is off in all of them, as the sister note is.
    local whatsNewRow = CreateRow(pages.look, 1, L["What's New:"])
    widgets.whatsnew = Widgets.CreateButton(whatsNewRow, L["Open"], function()
        ns.WhatsNew:Toggle()
    end, { width = 60, height = 20 })
    FitButton(widgets.whatsnew)
    widgets.whatsnew:SetPoint("TOPLEFT", CONTROL_X, 0)

    local whatsNewPopupRow = CreateRow(pages.look, 1, L["What's New After Updates:"],
        L["Opens What's New the first time you play after an update."])
    widgets.whatsNewPopup = Widgets.CreateCheckbox(whatsNewPopupRow, L["On"], function(checked)
        ns.WhatsNew:SetOn(checked)
    end, true)
    widgets.whatsNewPopup:SetPoint("TOPLEFT", CONTROL_X, -2)

    local whatsNewMotionRow = CreateRow(pages.look, 1, L["What's New Motion:"])
    widgets.whatsNewMotion = Widgets.CreateCheckbox(whatsNewMotionRow, L["On"], function(checked)
        ns.WhatsNew:SetMotionOn(checked)
    end, true)
    widgets.whatsNewMotion:SetPoint("TOPLEFT", CONTROL_X, -2)

    local shopsRow = CreateRow(pages.auction, 1, L["Open With AH and Vendors:"],
        L["Opens this window with the auction house or a vendor."])

    widgets.openWithShops = Widgets.CreateCheckbox(shopsRow, L["On"], function(checked)
        Config:Set("openWithShops", checked)
    end, false)
    widgets.openWithShops:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- A player's request (2026-10-07): the window was too big on a 4K
    -- screen. The grip below its bottom right corner does the same, to any
    -- size; one dragged to shows in the box as its percent.
    CreateSection(pages.look, 1, L["THIS WINDOW"])
    local sizeRow = CreateRow(pages.look, 1, L["Window Size:"])

    widgets.windowSize = Widgets.CreateDropdown(sizeRow, {}, function(value)
        UI:SetWindowScale(value)
    end, { width = 150 })
    widgets.windowSize:SetPoint("TOPLEFT", CONTROL_X, 0)

    -- Asked 2026-10-07 ("I'm getting old"): bigger letters in the same
    -- window. Every size is read as text is drawn, so it waits for /reload.
    local textRow = CreateRow(pages.look, 1, L["Text Size:"])

    widgets.textSize = Widgets.CreateDropdown(textRow, {
        { text = L["Normal"], value = "normal" },
        { text = L["Large"], value = "large" },
        { text = L["Larger"], value = "larger" },
    }, function(value)
        Config:Set("textSize", value)
        local now = Theme.TextStep and Theme.TextStep() or 0
        local wanted = Theme.TEXT_STEPS and Theme.TEXT_STEPS[value] or 0
        widgets.textReload:SetShown(now ~= wanted)
    end, { width = 110 })
    widgets.textSize:SetPoint("TOPLEFT", CONTROL_X, 0)

    -- ReloadUI is allowed from a click, and saves everything first.
    widgets.textReload = Widgets.CreateButton(textRow, L["Reload now"], function()
        if ReloadUI then ReloadUI() end
    end, { width = 90, height = 20 })
    FitButton(widgets.textReload)
    ReloadUnder(textRow, widgets.textSize, widgets.textReload)
    widgets.textReload:Hide()

    -- Asked 2026-10-10: the game's own look for players who would rather
    -- the windows matched the rest of their screen. Read at login, so it
    -- waits for /reload as Text size does. See UI/BlizzardLook.lua.
    local styleRow = CreateRow(pages.look, 1, L["Window Style:"])

    widgets.windowStyle = Widgets.CreateDropdown(styleRow, {
        { text = "Titanforged", value = "titanforged" },
        { text = "Blizzard", value = "blizzard" },
    }, function(value)
        Config:Set("windowStyle", value)
        local Look = ns.BlizzardLook
        widgets.styleReload:SetShown(Look and Look.Style() ~= value or false)
    end, { width = 110 })
    widgets.windowStyle:SetPoint("TOPLEFT", CONTROL_X, 0)

    widgets.styleReload = Widgets.CreateButton(styleRow, L["Reload now"], function()
        if ReloadUI then ReloadUI() end
    end, { width = 90, height = 20 })
    FitButton(widgets.styleReload)
    ReloadUnder(styleRow, widgets.windowStyle, widgets.styleReload)
    widgets.styleReload:Hide()

    local effectsRow = CreateRow(pages.look, 1, L["Effects:"])

    widgets.effects = Widgets.CreateDropdown(effectsRow, {
        { text = L["Full"], value = "full" },
        { text = L["Subtle"], value = "subtle" },
        { text = L["Off"], value = "off" },
    }, function(value)
        Config:Set("windowEffects", value)
        -- Anything moving now lands at once rather than finishing slowly.
        if value == "off" and ns.Motion then ns.Motion:FinishAll() end
    end, { width = 110 })
    widgets.effects:SetPoint("TOPLEFT", CONTROL_X, 0)

    -- Which columns each list shows (asked 2026-10-09). The same tick list
    -- a right-click on a list's headings opens. See UI/Columns.lua.
    CreateSection(pages.look, 1, L["COLUMNS"])
    local columnsRow = CreateRow(pages.look, 1, L["Columns Shown:"],
        L["Pick a list to choose its columns. Right-click a list's headings does the same."])

    local listOptions = {}
    for _, list in ipairs(ns.Columns:Lists()) do
        listOptions[#listOptions + 1] = { text = list.title, value = list.id }
    end
    -- Picking a list opens its tick list under the box.
    widgets.columnsList = Widgets.CreateDropdown(columnsRow, listOptions, function(id)
        if id then ns.Columns:Open(id, widgets.columnsList) end
    end, { width = 160 })
    widgets.columnsList:SetPoint("TOPLEFT", CONTROL_X, 0)
    if listOptions[1] then widgets.columnsList:SetValue(listOptions[1].value) end

    local showAllRow = CreateRow(pages.look, 1, L["Hidden Columns:"])
    widgets.columnsHidden = Theme.CreateLabel(showAllRow, "small", "muted")
    widgets.columnsHidden:SetPoint("TOPLEFT", CONTROL_X, -4)

    widgets.columnsShowAll = Widgets.CreateButton(showAllRow, L["Show All"], function()
        ns.Columns:ShowAll()
    end, { width = 80, height = 20 })
    widgets.columnsShowAll:SetPoint("TOPLEFT", CONTROL_X + 70, 0)
    FitButton(widgets.columnsShowAll)

    local function PaintHiddenCount()
        local count = ns.Columns:HiddenCount()
        widgets.columnsHidden:SetText(count == 0 and L["None"] or tostring(count))
        widgets.columnsHidden:SetTextColor(Theme.Unpack(count == 0 and "muted" or "accent"))
        widgets.columnsShowAll:SetEnabledState(count > 0)
    end
    widgets.paintHiddenColumns = PaintHiddenCount
    ns.Columns.onAnyChange = PaintHiddenCount
    PaintHiddenCount()

    -- Debug, the client check and the speed check are typed only (/bts
    -- debug, probe, perf; the owner, 2026-10-23): players don't need them.

    -- Every sound the addon plays, each with its own switch, all on to start
    -- with. The one sound not here is the warning that saved data failed to
    -- load, which is about losing data rather than an effect.
    CreateSection(pages.look, 2, L["SOUNDS"])
    widgets.sounds = {}

    local function SoundRow(key, label, description, test)
        local row = CreateRow(pages.look, 2, label, description)
        local box = Widgets.CreateCheckbox(row, L["On"], function(checked)
            Config:Set(key, checked)
        end, true)
        box:SetPoint("TOPLEFT", CONTROL_X, -2)
        widgets.sounds[key] = box

        if test then
            local button = Widgets.CreateButton(row, L["Test"], test,
                { width = 60, height = 20, tooltip = L["Play it now"] })
            button:SetPoint("TOPLEFT", CONTROL_X + 100, -2)
        end

        return box
    end

    -- The sale alarm picks its sound (asked 2026-10-11: players found the
    -- raid warning too much and asked for an old cash register). Off is the
    -- saleAlarm switch; the sound is saleSound. Picking one plays it.
    local saleRow = CreateRow(pages.look, 2, L["An Auction Sells:"],
        L["Plays a sound when one of your auctions sells."])

    local function SaleSound()
        if Config:Get("saleAlarm") == false then return "off" end
        return ns.SaleAlarm and ns.SaleAlarm:Sound() or "register"
    end

    widgets.saleAlarm = Widgets.CreateDropdown(saleRow, {
        { text = L["Cash register"], value = "register" },
        { text = L["Coins"], value = "coins" },
        { text = L["Raid warning"], value = "raid" },
        { text = L["Off"], value = "off" },
    }, function(value)
        if value == "off" then
            Config:Set("saleAlarm", false)
            return
        end
        Config:Set("saleAlarm", true)
        Config:Set("saleSound", value)
        if ns.SaleAlarm then ns.SaleAlarm:Play(value) end
    end, { width = 100 })
    widgets.saleAlarm:SetPoint("TOPLEFT", CONTROL_X, 0)

    widgets.saleAlarmPlay = Widgets.CreateButton(saleRow, L["Play"], function()
        local value = SaleSound()
        if ns.SaleAlarm then ns.SaleAlarm:Play(value ~= "off" and value or nil) end
    end, { width = 50, height = 20, tooltip = L["Play the sale sound now"] })
    widgets.saleAlarmPlay:SetPoint("LEFT", widgets.saleAlarm, "RIGHT", 6, 0)
    FitButton(widgets.saleAlarmPlay)
    widgets.saleAlarm.Refresh = function(self) self:SetValue(SaleSound()) end

    widgets.scanSounds = SoundRow("scanSounds", L["A Scan Finishes:"],
        L["A chime when a scan finishes, and another when it finds disenchant or vendor deals."])
    SoundRow("mailReportSound", L["Mail Report:"],
        L["The coins as the mail report counts up, and the fanfare on a new record."])
    SoundRow("craftDoneSound", L["Crafting Finishes:"],
        L["A chime when a run of two or more crafts is done."])
    SoundRow("bagsFullSound", L["Bags Are Full:"],
        L["A warning the moment your last free bag slot fills."])
    SoundRow("disenchantSound", L["Disenchant Finds:"],
        L["A chime when a disenchant turns up something new or lucky."])
    SoundRow("altCraftSound", L["Cheaper on an Alt:"],
        L["A coin when another of your characters can make a material for less."])
    SoundRow("goalSound", L["Farmer Goal Set:"],
        L["A cheer when Set goal on the Gather tab makes a Farmer goal."])
    SoundRow("goldTrackerSound", L["Goblin Gold:"],
        L["Coins at each tenth of your gold goal, and a cheer when you reach it."],
        function() if ns.GoldGoalUI then ns.GoldGoalUI.Play("step") end end)
    SoundRow("statsCheer", L["Best Week of Sales:"],
        L["A cheer on the Stats tab when an item has its best week of sales yet, once a week."],
        function()
            local kit = type(SOUNDKIT) == "table" and SOUNDKIT.IG_QUEST_LIST_COMPLETE or 878
            pcall(PlaySound, kit, "Master")
        end)

    -- UI/Tab_Stats.lua (asked 2026-10-14): one item at a time, in charts.
    -- The button is /bts stats.
    local statsRow = CreateRow(pages.look, 2, L["Stats:"])
    local statsOpen = Widgets.CreateButton(statsRow, L["Open"], function()
        if ns.StatsUI then ns.StatsUI:ShowItem(nil) end
    end, { width = 60, height = 20 })
    statsOpen:SetPoint("TOPLEFT", CONTROL_X, -2)
    FitButton(statsOpen)

    -- The Welcome card (2026-10-20): which professions' roads come first on
    -- the Level Up tab's Road to 300. Opens the card again.
    local roadRow = CreateRow(pages.look, 2, L["Road to 300:"])
    local roadOpen = Widgets.CreateButton(roadRow, L["Open"], function()
        if ns.WelcomeUI then ns.WelcomeUI:Show() end
    end, { width = 60, height = 20 })
    roadOpen:SetPoint("TOPLEFT", CONTROL_X, -2)
    FitButton(roadOpen)

    -- Show the way aims the arrow (Logic/WayArrow.lua); with TomTom
    -- installed, its arrow instead while this is ticked (Logic/TomTom.lua,
    -- the same file in every addon with an arrow). On unless unticked.
    local tomtomRow = CreateRow(pages.look, 2, L["Use TomTom:"],
        L["With TomTom installed, its arrow shows the way instead."])
    widgets.useTomTom = Widgets.CreateCheckbox(tomtomRow, L["On"], function(checked)
        if ns.TomTom then ns.TomTom:SetOn(checked) end
    end, true)
    widgets.useTomTom:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- Show the way to a trainer or vendor far away step by step
    -- (Logic/Travel.lua, the same in every addon). On unless unticked.
    local guideRow = CreateRow(pages.look, 2, L["Guide Me:"],
        L["When the place is in another zone or across the sea, the arrow leads you there step by step."])
    widgets.arrowRoute = Widgets.CreateCheckbox(guideRow, L["On"], function(checked)
        if ns.Travel then ns.Travel:SetOn(checked) end
    end, true)
    widgets.arrowRoute:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- Goblin Gold (asked 2026-10-17): the gold on every character of this
    -- realm and side, on a small bar, with a goal. Off unless ticked; its
    -- sound is under SOUNDS. Logic/GoldGoal.lua, UI/GoldGoal.lua. The
    -- buttons are /bts gold on, off, goal and reset.
    CreateSection(pages.look, 2, L["GOBLIN GOLD"])
    local goldRow = CreateRow(pages.look, 2, L["Gold Tracker:"],
        L["A small bar with the gold on all your characters on this realm and side."])

    widgets.goldTracker = Widgets.CreateCheckbox(goldRow, L["On"], function(checked)
        if ns.GoldGoal then ns.GoldGoal:SetOn(checked) end
    end, false)
    widgets.goldTracker:SetPoint("TOPLEFT", CONTROL_X, -2)

    -- Count Gold On (asked 2026-10-21): every character, or only the one
    -- playing, with a goal of its own (Logic/GoldGoal.lua).
    local countRow = CreateRow(pages.look, 2, L["Count Gold On:"])
    widgets.goldCount = Widgets.CreateDropdown(countRow, {
        { text = L["All Characters"], value = "all" },
        { text = L["This Character"], value = "character" },
    }, function(value)
        if ns.GoldGoal then
            ns.GoldGoal:SetCount(value)
        else
            Config:Set("goldTrackerCount", value)
        end
        -- The goal box shows the goal of what is counted now.
        local goal = ns.GoldGoal and ns.GoldGoal:Goal()
        widgets.goldGoal:SetValue(goal and math.floor(goal / 10000) or nil, true)
    end, { width = 130 })
    widgets.goldCount:SetPoint("TOPLEFT", CONTROL_X, 0)

    local goalRow = CreateRow(pages.look, 2, L["Gold Goal:"],
        L["Each tenth of the way gets a cheer. Leave it empty for no goal."])

    widgets.goldGoal = Widgets.CreateNumberBox(goalRow, {
        width = 80, min = 1, max = 99999999, allowEmpty = true, placeholder = L["None"],
        onChange = function(value)
            if not ns.GoldGoal then return end
            local goal = ns.GoldGoal:Goal()
            if value and goal and math.floor(goal / 10000) == value then return end
            ns.GoldGoal:SetGoalGold(value)
        end,
    })
    widgets.goldGoal:SetPoint("TOPLEFT", CONTROL_X, 0)
    AddUnit(goalRow, widgets.goldGoal, "g")

    -- Transparent (asked 2026-10-19), as Farmer's panels have it: the
    -- bar's glass thins out and comes back under the mouse. Off by default.
    local goldClearRow = CreateRow(pages.look, 2, L["Transparent:"])
    widgets.goldSeeThrough = Widgets.CreateDropdown(goldClearRow, {
        { text = L["Off"], value = 0 },
        { text = L["Some"], value = 1 },
        { text = L["More"], value = 2 },
        { text = L["Most"], value = 3 },
    }, function(value)
        if ns.GoldGoalUI then
            ns.GoldGoalUI:SetSeeThrough(value)
        else
            Config:Set("goldTrackerSeeThrough", value)
        end
    end, { width = 110 })
    widgets.goldSeeThrough:SetPoint("TOPLEFT", CONTROL_X, 0)

    local goldPlaceRow = CreateRow(pages.look, 2, L["Gold Tracker Place:"])
    local goldPlace = Widgets.CreateButton(goldPlaceRow, L["Reset"], function()
        if ns.GoldGoalUI then ns.GoldGoalUI:ResetPlace() end
    end, { width = 60, height = 20 })
    goldPlace:SetPoint("TOPLEFT", CONTROL_X, -2)
    FitButton(goldPlace)

    -- Sharing (asked 2026-10-07): your characters on another account of
    -- yours, and prices within your guild. Logic/AccountLink.lua and
    -- Logic/GuildPrices.lua; every /bts share command has a control here.
    CreateSection(pages.sharing, 1, L["ACCOUNT LINK"])

    local linkRow = CreateRow(pages.sharing, 1, L["Your Other Account:"],
        L["Type your other account's character names, with commas. Type this character's name over there too."])

    widgets.linkNames = Widgets.CreateSearchBox(linkRow, L["Character names"], function(text)
        if ns.AccountLink then ns.AccountLink:SetNames(text) end
    end)
    widgets.linkNames:SetWidth(150)
    widgets.linkNames:SetPoint("TOPLEFT", CONTROL_X, 0)
    if widgets.linkNames.icon then
        widgets.linkNames.icon:SetTexture([[Interface\FriendsFrame\UI-Toast-FriendOnlineIcon]])
        widgets.linkNames.icon:SetSize(14, 14)
    end
    widgets.linkNames.editBox:SetScript("OnEscapePressed", function(self)
        self:SetText(Config:Get("linkNames") or "")
        self:ClearFocus()
    end)
    -- Saved as typed; the hello waits for Enter, so half a name is never
    -- whispered.
    widgets.linkNames.editBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        if ns.AccountLink then ns.AccountLink:Check() end
        UI:RefreshActiveTab()
    end)

    widgets.linkShares = {}
    local function ShareRow(key, label, description)
        local row = CreateRow(pages.sharing, 1, label, description)
        local box = Widgets.CreateCheckbox(row, L["On"], function(checked)
            Config:Set(key, checked)
        end, true)
        box:SetPoint("TOPLEFT", CONTROL_X, -2)
        widgets.linkShares[key] = box
    end

    ShareRow("linkShareRecipes", L["Share Recipes:"], L["Your characters' professions and recipes."])
    ShareRow("linkShareBags", L["Share Bags, Bank and Mail:"], L["What your characters carry, bank and have in the mail."])
    ShareRow("linkShareGold", L["Share Gold:"], L["How much gold each of your characters has."])
    ShareRow("linkShareAuctions", L["Share Auctions:"], L["What your characters have listed, so Keep in stock counts it."])

    local syncButton = Widgets.CreateButton(pages.sharing.content, L["Sync"], function()
        if ns.AccountLink then ns.AccountLink:Check() end
        ns.Print(L["asked your other account for anything new"])
        C_Timer.After(3, function() UI:RefreshActiveTab() end)
    end, { width = 80, height = 22, tooltip = L["Contact your other account now and swap anything that changed"] })
    Place(pages.sharing, 1, syncButton, -10)
    FitButton(syncButton)

    -- The whisper test is typed only (/bts share test; the owner, 2026-10-23).

    -- Forget their characters is a typed command now (the owner,
    -- 2026-10-15): /bts forgetlinked confirm. Settings never deletes data.

    widgets.linkStatus = Theme.CreateLabel(pages.sharing.content, "tiny", "muted")
    Place(pages.sharing, 1, widgets.linkStatus, -8)
    widgets.linkStatus:SetWidth(COLUMN_WIDTH)
    widgets.linkStatus:SetWordWrap(true)

    -- Friends (the owner, 2026-10-25): a friend's recipes show on the
    -- Profit tab, and their characters never join yours.
    -- Logic/GuildCrafters.lua.
    CreateSection(pages.sharing, 1, L["FRIENDS"])
    local friendRow = CreateRow(pages.sharing, 1, L["Friends:"],
        L["Type your friend's character names, with commas. Their data stays apart from yours."])
    widgets.friendNames = Widgets.CreateSearchBox(friendRow, L["Character names"], function(text)
        if ns.GuildCrafters then ns.GuildCrafters:SetFriends(text) else Config:Set("friendNames", text) end
    end)
    widgets.friendNames:SetWidth(150)
    widgets.friendNames:SetPoint("TOPLEFT", CONTROL_X, 0)
    if widgets.friendNames.icon then
        widgets.friendNames.icon:SetTexture([[Interface\FriendsFrame\UI-Toast-FriendOnlineIcon]])
        widgets.friendNames.icon:SetSize(14, 14)
    end
    widgets.friendNames.editBox:SetScript("OnEscapePressed", function(self)
        self:SetText(Config:Get("friendNames") or "")
        self:ClearFocus()
    end)
    -- The hello waits for Enter, so half a name is never whispered.
    widgets.friendNames.editBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        if ns.AccountLink and ns.AccountLink.SetAsideFriends then ns.AccountLink:SetAsideFriends() end
        if ns.GuildCrafters then ns.GuildCrafters:HelloFriends() end
        UI:RefreshActiveTab()
    end)

    CreateSection(pages.sharing, 2, L["GUILD"])
    local guildRow = CreateRow(pages.sharing, 2, L["Guild Prices:"],
        L["Swaps scans with guildmates who use Tradeskills. Your own scans always win."])
    widgets.guildPrices = Widgets.CreateCheckbox(guildRow, L["On"], function(checked)
        Config:Set("guildPrices", checked)
        UI:RefreshActiveTab()
    end, false)
    widgets.guildPrices:SetPoint("TOPLEFT", CONTROL_X, -2)

    CreateRow(pages.sharing, 2, L["Guild Status:"], nil)
    widgets.guildStatus = Theme.CreateLabel(pages.sharing.content, "tiny", "muted")
    Place(pages.sharing, 2, widgets.guildStatus, -2)
    widgets.guildStatus:SetWidth(COLUMN_WIDTH)
    widgets.guildStatus:SetWordWrap(true)

    local craftersRow = CreateRow(pages.sharing, 2, L["Guild Crafters:"],
        L["Shows guildmates online who can make a craft. Your guild sees which recipes you know."])
    widgets.guildCrafters = Widgets.CreateCheckbox(craftersRow, L["On"], function(checked)
        if ns.GuildCrafters then ns.GuildCrafters:SetOn(checked) else Config:Set("guildCrafters", checked) end
        UI:RefreshActiveTab()
    end, false)
    widgets.guildCrafters:SetPoint("TOPLEFT", CONTROL_X, -2)

    CreateSection(pages.sharing, 2, L["YOUR REALM"])
    local realmRow = CreateRow(pages.sharing, 2, L["Realm Prices:"],
        L["Swaps auction prices with players on your realm who use Tradeskills. Only prices are sent, never names. Your own scans always win."])
    widgets.realmPrices = Widgets.CreateCheckbox(realmRow, L["On"], function(checked)
        if ns.RealmPrices then ns.RealmPrices:SetOn(checked) else Config:Set("realmPrices", checked) end
        UI:RefreshActiveTab()
    end, false)
    widgets.realmPrices:SetPoint("TOPLEFT", CONTROL_X, -2)

    widgets.realmStatus = Theme.CreateLabel(pages.sharing.content, "tiny", "muted")
    Place(pages.sharing, 2, widgets.realmStatus, -4)
    widgets.realmStatus:SetWidth(COLUMN_WIDTH)
    widgets.realmStatus:SetWordWrap(true)

    CreateSection(pages.sharing, 2, L["OTHER PRICE ADDONS"])
    local tsmRow = CreateRow(pages.sharing, 2, L["TSM Prices:"],
        L["Uses TradeSkillMaster prices for items you haven't priced."])
    widgets.tsmPrices = Widgets.CreateCheckbox(tsmRow, L["On"], function(checked)
        Config:Set("tsmPrices", checked)
        if ns.TSMPrices then ns.TSMPrices:Forget() end
        UI:RefreshActiveTab()
    end, false)
    widgets.tsmPrices:SetPoint("TOPLEFT", CONTROL_X, -2)

    widgets.tsmStatus = Theme.CreateLabel(pages.sharing.content, "tiny", "muted")
    Place(pages.sharing, 2, widgets.tsmStatus, -4)
    widgets.tsmStatus:SetWidth(COLUMN_WIDTH)
    widgets.tsmStatus:SetWordWrap(true)

    local auctionatorRow = CreateRow(pages.sharing, 2, L["Auctionator Prices:"],
        L["Uses Auctionator prices for items nothing else has priced, or when its price is newer than your old one."])
    widgets.auctionatorPrices = Widgets.CreateCheckbox(auctionatorRow, L["On"], function(checked)
        Config:Set("auctionatorPrices", checked)
        if ns.AuctionatorPrices then ns.AuctionatorPrices:Forget() end
        UI:RefreshActiveTab()
    end, false)
    widgets.auctionatorPrices:SetPoint("TOPLEFT", CONTROL_X, -2)

    widgets.auctionatorStatus = Theme.CreateLabel(pages.sharing.content, "tiny", "muted")
    Place(pages.sharing, 2, widgets.auctionatorStatus, -4)
    widgets.auctionatorStatus:SetWidth(COLUMN_WIDTH)
    widgets.auctionatorStatus:SetWordWrap(true)

    -- Price Order (the owner, 2026-10-25): which of TSM and Auctionator
    -- fills a gap first. Your own scans and set prices always come first.
    local orderRow = CreateRow(pages.sharing, 2, L["Price Order:"],
        L["Picks which addon's price is used first when both have one. Your own scans always win."])
    widgets.priceOrder = Widgets.CreateDropdown(orderRow, {
        { text = L["TSM First"], value = "tsm" },
        { text = L["Auctionator First"], value = "auctionator" },
    }, function(value)
        Config:Set("priceOrder", value)
        UI:RefreshActiveTab()
    end, { width = 130 })
    widgets.priceOrder:SetPoint("TOPLEFT", CONTROL_X, 0)

    -- The buttons standing on their own, so the search finds them too.
    Searchable(pages.queue, exportButton, L["Export queue Copy your queue, settings and stock limits as a code"])
    Searchable(pages.queue, importButton, L["Import Load a code"])
    Searchable(pages.sharing, syncButton, L["Sync now Contact your other account now and swap anything that changed"])

    -- About (UI/About.lua): the note on how the addons are made, then the
    -- version, the Discord and the other Blackthornes addons.
    if ns.About then
        CreateSection(pages.about, 1, L["HOW THESE ADDONS ARE MADE"])
        local note = Place(pages.about, 1, ns.About:Note(pages.about.content, COLUMN_WIDTH))
        Searchable(pages.about, note, note.words)
        CreateSection(pages.about, 2, L["ABOUT"])
        local info = Place(pages.about, 2, ns.About:Info(pages.about.content, COLUMN_WIDTH))
        Searchable(pages.about, info, info.words)
    end

    -- Sending your own disenchants and recipe skills to the addon's maker
    -- (Logic/Contribute.lua, the owner 2026-10-18). Off unless ticked, and
    -- offered only where it can send (North America, and on Classic Era
    -- the realm the owner's characters are on). Its words wrap under the
    -- box, since they run long.
    if ns.Contribute and ns.Contribute:InRegion() and #ns.Contribute:Recipients() > 0 then
        local text = L["Share your data with Blackthornes to improve the Tradeskills AddOn."]
        local holder = CreateFrame("Frame", nil, pages.about.content)
        holder:SetSize(COLUMN_WIDTH, 36)
        local box = Widgets.CreateCheckbox(holder, text, function(checked)
            ns.Contribute:SetOn(checked)
        end, Config:Get("shareData") == true)
        box:SetPoint("TOPLEFT", 0, -2)
        box:SetWidth(COLUMN_WIDTH)
        box.box:ClearAllPoints()
        box.box:SetPoint("TOPLEFT", box, "TOPLEFT", 0, -1)
        box.label:ClearAllPoints()
        box.label:SetPoint("TOPLEFT", box.box, "TOPRIGHT", 6, 1)
        box.label:SetWidth(COLUMN_WIDTH - 24)
        box.label:SetJustifyH("LEFT")
        if box.label.SetWordWrap then box.label:SetWordWrap(true) end
        local ok, tall = pcall(box.label.GetStringHeight, box.label)
        tall = ok and tonumber(tall) or 0
        if tall < 14 then tall = 28 end
        box:SetHeight(math.max(18, tall + 2))
        holder:SetHeight(math.max(18, tall + 2) + 6)
        Place(pages.about, 2, holder, -14)
        Searchable(pages.about, holder, text)
        widgets.shareData = box
    end

    widgets.describe:SetChecked(Config:Get("settingsDescriptions") == true)
    ShowPage(CurrentPage())
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

--- Write a stored value back into its box, unless the player is typing in
--- it. Bag, mail and auction events redraw this page every few seconds at
--- the auction house, and each redraw put the stored number back over the
--- one being typed, so Enter then saved the old number (or a mix of both).
local function Put(box, value)
    local editBox = box.editBox
    if editBox and editBox.HasFocus and editBox:HasFocus() then return end
    box:SetValue(value, true)
end

local IGNORED_ROW_HEIGHT = 22
local RESTORE_WIDTH = 70

--- One line per ignored craft or item: its name, and Restore at the
--- column's edge. `rows` is the list's own row table, `hint` the label the
--- rows hang under, `onRestore(key)` puts one back.
local function IgnoredRow(rows, hint, index, onRestore, restoreTip, buttonText)
    local row = rows[index]
    if row then return row end

    row = CreateFrame("Frame", nil, widgets.ignoredParent)
    row:SetSize(COLUMN_WIDTH, IGNORED_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0,
        -6 - (index - 1) * (IGNORED_ROW_HEIGHT + 2))

    row.label = Theme.CreateLabel(row, "small", "text")
    row.label:SetPoint("LEFT", 0, 0)
    row.label:SetPoint("RIGHT", row, "RIGHT", -RESTORE_WIDTH - 8, 0)
    row.label:SetWordWrap(false)

    row.restore = Widgets.CreateButton(row, buttonText or L["Restore"], function()
        if row.key then onRestore(row.key) end
    end, { width = RESTORE_WIDTH, height = 20, tooltip = restoreTip })
    row.restore:SetPoint("RIGHT", 0, 0)
    FitButton(row.restore)

    rows[index] = row
    return row
end

--- Fill one ignored list; returns the last line drawn, for what follows.
local function FillIgnored(list, rows, hint, empty, onRestore, restoreTip, color, buttonText)
    for index, entry in ipairs(list) do
        local row = IgnoredRow(rows, hint, index, onRestore, restoreTip, buttonText)
        row.key = entry.key
        row.label:SetText(entry.name)
        if color then
            local r, g, b = color(entry.key)
            if r then row.label:SetTextColor(r, g, b)
            else row.label:SetTextColor(Theme.Unpack("text")) end
        end
        row:Show()
    end
    for index = #list + 1, #rows do
        rows[index].key = nil
        rows[index]:Hide()
    end

    empty:ClearAllPoints()
    empty:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -6)
    empty:SetShown(#list == 0)

    return #list > 0 and rows[#list] or empty
end

--- One never-made sub-craft's line: its name in its item's colour, then
--- what buying the item costs, or that nobody sells it.
local function NeverLine(entry)
    local name = entry.name
    local r, g, b = Util.GetItemQualityColor(entry.outputItemID)
    if r then
        name = ("|cff%02x%02x%02x%s|r"):format(math.floor(r * 255 + 0.5),
            math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5), name)
    end

    if not entry.outputItemID then
        return L.Format("%s |cff7a8089· no character knows it|r", name)
    end
    local buy = ns.Cost:GetReagentUnitCost(entry.outputItemID)
    if not buy then
        return L.Format("%s |cff7a8089·|r |c%sno price to buy it|r", name, ns.COLORS.warn)
    end
    return L.Format("%s |cff7a8089· buy %s each|r", name,
        Util.FormatMoney(buy, { noColor = true, short = true }))
end

--- One always-made sub-craft's line: its name in its item's colour, then
--- that it is always made.
local function AlwaysLine(entry)
    local name = entry.name
    local r, g, b = Util.GetItemQualityColor(entry.outputItemID)
    if r then
        name = ("|cff%02x%02x%02x%s|r"):format(math.floor(r * 255 + 0.5),
            math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5), name)
    end
    return L.Format("%s |cff7a8089· always made|r", name)
end

local function RefreshNeverSubCrafts()
    if not widgets.neverHint or not (ns.Cost and ns.Cost.GetNeverSubCrafts) then return end

    local list = {}
    for _, entry in ipairs(ns.Cost:GetNeverSubCrafts()) do
        list[#list + 1] = { key = entry.recipeID, name = NeverLine(entry) }
    end
    -- Those set to Make on the Level Up tab follow (2026-10-13), and Allow
    -- puts them back to the usual too.
    if ns.Cost.GetAlwaysSubCrafts then
        for _, entry in ipairs(ns.Cost:GetAlwaysSubCrafts()) do
            list[#list + 1] = { key = entry.recipeID, name = AlwaysLine(entry) }
        end
    end

    local last = FillIgnored(list, widgets.neverRows, widgets.neverHint, widgets.neverEmpty,
        function(recipeID)
            if ns.Cost.SetSubCraftChoice then ns.Cost:SetSubCraftChoice(recipeID, nil)
            else ns.Cost:SetNeverSubCraft(recipeID, false) end
        end,
        L["Make it as a sub-craft again whenever that is cheaper than buying it"],
        nil, L["Allow"])

    widgets.neverEnd:ClearAllPoints()
    widgets.neverEnd:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, 0)
end

local STOCK_ROW_HEIGHT = 26

--- One profession's line: dark glass by place, its name, its number box
--- (empty for the usual number) and an x while it has one of its own.
local function StockRow(index)
    local row = widgets.stockRows[index]
    if row then return row end

    row = CreateFrame("Frame", nil, widgets.ignoredParent)
    row:SetSize(COLUMN_WIDTH, STOCK_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", widgets.stockHint, "BOTTOMLEFT", 0,
        -6 - (index - 1) * STOCK_ROW_HEIGHT)

    row.band = row:CreateTexture(nil, "BACKGROUND")
    row.band:SetAllPoints(row)
    row.band:SetColorTexture(Theme.Unpack(index % 2 == 1 and "glass" or "glassAlt"))

    row.line = row:CreateTexture(nil, "BORDER")
    row.line:SetPoint("BOTTOMLEFT", 0, 0)
    row.line:SetPoint("BOTTOMRIGHT", 0, 0)
    row.line:SetHeight(1)
    row.line:SetColorTexture(Theme.Unpack("border"))
    row.line:SetAlpha(0.6)

    row.label = Theme.CreateLabel(row, "small", "text")
    row.label:SetPoint("LEFT", 8, 0)
    row.label:SetPoint("RIGHT", row, "LEFT", CONTROL_X - 8, 0)
    row.label:SetWordWrap(false)

    row.box = Widgets.CreateNumberBox(row, {
        width = 56, min = 0, max = 999, allowEmpty = true,
        onChange = function(value)
            if row.profession then ns.Auctions:SetProfessionLimit(row.profession, value) end
        end,
    })
    row.box:SetPoint("LEFT", row, "LEFT", CONTROL_X, 0)

    row.usual = Theme.CreateLabel(row, "tiny", "dim")
    row.usual:SetPoint("LEFT", row.box, "RIGHT", 6, 0)
    row.usual:SetText(L["usual"])

    row.clear = Widgets.CreateButton(row, "x", function()
        if row.profession then ns.Auctions:SetProfessionLimit(row.profession, nil) end
    end, { width = 20, height = 20, tooltip = L["Use Keep in Stock for this profession again"] })
    row.clear:SetPoint("RIGHT", row, "RIGHT", -6, 0)

    widgets.stockRows[index] = row
    return row
end

local function RefreshStockProfessions()
    if not widgets.stockHint or not (ns.Auctions and ns.Auctions.StockProfessions) then return end

    local professions = ns.Auctions:StockProfessions()
    local usual = ns.Config:Get("maxPostedPerItem") or 0
    local usualText = usual > 0 and tostring(usual) or "0"

    for index, profession in ipairs(professions) do
        local row = StockRow(index)
        row.profession = profession
        row.label:SetText(ns.Auctions:ProfessionLabel(profession))

        local own = ns.Auctions:GetProfessionLimit(profession)
        row.box:SetPlaceholder(usualText)
        local typing = row.box.editBox.HasFocus and row.box.editBox:HasFocus()
        if not typing then row.box:SetValue(own, true) end
        row.usual:SetShown(own == nil)
        row.clear:SetShown(own ~= nil)
        row:Show()
    end
    for index = #professions + 1, #widgets.stockRows do
        widgets.stockRows[index].profession = nil
        widgets.stockRows[index]:Hide()
    end

    widgets.stockEmpty:ClearAllPoints()
    widgets.stockEmpty:SetPoint("TOPLEFT", widgets.stockHint, "BOTTOMLEFT", 0, -6)
    widgets.stockEmpty:SetShown(#professions == 0)

    local last = #professions > 0 and widgets.stockRows[#professions] or widgets.stockEmpty
    widgets.stockEnd:ClearAllPoints()
    widgets.stockEnd:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, 0)
end

local function RefreshChangedStock()
    if not widgets.changedHint or not (ns.SellOut and ns.SellOut.Changed) then return end

    local list = {}
    for _, entry in ipairs(ns.SellOut:Changed()) do
        list[#list + 1] = { key = entry.itemID,
            name = L.Format("%s: %d to %d", entry.name, entry.base, entry.limit) }
    end

    local last = FillIgnored(list, widgets.changedRows, widgets.changedHint,
        widgets.changedEmpty,
        function(itemID) ns.SellOut:Reset(itemID) end,
        L["Put Keep in Stock back to where it started"],
        function(itemID) return Util.GetItemQualityColor(itemID) end,
        L["Reset"])

    widgets.changedEnd:ClearAllPoints()
    widgets.changedEnd:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, 0)
end

local function RefreshIgnored()
    RefreshStockProfessions()
    RefreshChangedStock()
    RefreshNeverSubCrafts()
    if not widgets.ignoredHint or not ns.Profit.GetIgnored then return end

    local crafts = {}
    for _, entry in ipairs(ns.Profit:GetIgnored()) do
        crafts[#crafts + 1] = { key = entry.recipeID, name = entry.name }
    end

    local last = FillIgnored(crafts, widgets.ignoredRows, widgets.ignoredHint,
        widgets.ignoredEmpty,
        function(recipeID) ns.Profit:SetIgnored(recipeID, false) end,
        L["Show this craft on the Profit tab again"],
        function(recipeID)
            -- In the rarity colour of what the craft makes.
            local recipe = ns.Recipes and ((ns.Recipes.Get and ns.Recipes:Get(recipeID))
                or (ns.Recipes.GetAny and ns.Recipes:GetAny(recipeID)))
            local itemID = recipe and recipe.outputItemID
            if itemID then return Util.GetItemQualityColor(itemID) end
        end)

    widgets.ignoredEnd:ClearAllPoints()
    widgets.ignoredEnd:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, 0)

    if not widgets.ignoredItemsHint or not (ns.Posting and ns.Posting.GetIgnored) then return end

    local items = {}
    for _, entry in ipairs(ns.Posting:GetIgnored()) do
        items[#items + 1] = { key = entry.itemID, name = entry.name }
    end

    -- In the item's rarity colour, as Ready to sell draws it.
    local lastIgnored = FillIgnored(items, widgets.ignoredItemsRows, widgets.ignoredItemsHint,
        widgets.ignoredItemsEmpty,
        function(itemID) ns.Posting:SetIgnored(itemID, false) end,
        L["Offer this item on Ready to sell again"],
        function(itemID) return Util.GetItemQualityColor(itemID) end)

    if widgets.ignoredItemsEnd then
        widgets.ignoredItemsEnd:ClearAllPoints()
        widgets.ignoredItemsEnd:SetPoint("TOPLEFT", lastIgnored, "BOTTOMLEFT", 0, 0)
    end

    if not widgets.keepHereSection or not ns.KeepHere then return end
    local keeps = {}
    for _, entry in ipairs(ns.KeepHere:Items()) do
        keeps[#keeps + 1] = { key = entry.itemID,
            name = L.Format("%s  |cff7a8089Keep: %s|r", entry.name, ns.KeepHere.Shown(entry.count)) }
    end
    FillIgnored(keeps, widgets.keepHereRows, widgets.keepHereSection, widgets.keepHereEmpty,
        function(itemID) ns.KeepHere:Set(itemID, 0) end, nil,
        function(itemID) return Util.GetItemQualityColor(itemID) end,
        L["Clear"])
end

local function Refresh()
    if not widgets.undercut then return end

    RefreshIgnored()

    if widgets.shownPage ~= CurrentPage() then ShowPage(CurrentPage()) end

    if widgets.paintHiddenColumns then widgets.paintHiddenColumns() end

    -- Reset to defaults can turn the descriptions back off.
    local describe = ns.Config:Get("settingsDescriptions") == true
    if widgets.describe:GetChecked() ~= describe then
        widgets.describe:SetChecked(describe)
        ShowDescriptions(describe)
    end

    local Config = ns.Config

    -- silent = true (inside Put): writing a stored value back into its own
    -- box must not fire the change handler and write it straight back to
    -- the database.
    Put(widgets.undercut, Config:Get("undercutCopper") or 1)
    Put(widgets.cut, (Config:Get("auctionCut") or 0.05) * 100)
    Put(widgets.minProfit, (Config:Get("minProfit") or 0) / 100)
    Put(widgets.minMargin, Config:Get("minMarginPercent") or 0)
    Put(widgets.budget, Config:Get("scanBudgetMs") or 8)

    local markup = Config:Get("unscannedMarkupPercent")
    Put(widgets.unscannedMarkup, type(markup) == "number" and markup or 50)
    widgets.priceUnscanned:SetChecked(Config:Get("priceUnscannedCrafts") ~= false)

    widgets.minProfitPreview:SetText(
        Util.FormatMoney(Config:Get("minProfit") or 0, { short = true }))

    Put(widgets.maxPosted, Config:Get("maxPostedPerItem") or 0)

    local overrides = 0
    for _ in pairs(ns.db.postLimits or {}) do overrides = overrides + 1 end
    widgets.maxPostedHint:SetText(overrides > 0
        -- Short enough for the 120 pixels beside the box; the longer wording
        -- was cut off with "...".
        and L.Format("%d set per item", overrides)
        or "")

    widgets.restockWhenLow:SetChecked(Config:Get("restockWhenLow") == true)
    widgets.restockOnSale:SetChecked(Config:Get("restockOnSale") ~= false)
    widgets.raiseOnSellOut:SetChecked(Config:Get("raiseStockOnSellOut") == true)
    widgets.learnStock:SetChecked(Config:Get("learnStockFromSales") ~= false)
    Put(widgets.restockAt, Config:Get("restockAt") or 0)
    widgets.fastSellerBoost:SetChecked(Config:Get("fastSellerBoost") == true)
    local extra = Config:Get("fastSellerExtra")
    Put(widgets.fastSellerExtra, type(extra) == "number" and extra or 2)
    widgets.hideMaxed:SetChecked(Config:Get("hideAtPostLimit") ~= false)
    widgets.allowLoss:SetChecked(Config:Get("allowPostingAtALoss") == true)
    widgets.neverBelowPaid:SetChecked(Config:Get("neverBelowCraftedCost") == true)
    widgets.sisterKeeps:SetChecked(Config:Get("sellHoldsSisterKeeps") == true)
    widgets.altKeeps:SetChecked(Config:Get("sellHoldsAltUpgrades") == true)
    widgets.verifyPrice:SetChecked(Config:Get("verifyPriceBeforePosting") ~= false)
    widgets.fastListing:SetChecked(Config:Get("fastListing") ~= false)
    widgets.mouseWheel:SetChecked(Config:Get("mouseWheelListing") == true)
    widgets.overcutting:SetChecked(Config:Get("overcutting") == true)
    widgets.subCrafts:SetChecked(Config:Get("autoQueueSubCrafts") ~= false)
    widgets.freeSpaceFirst:SetChecked(Config:Get("craftFreesSpaceFirst") ~= false)
    widgets.altCrafts:SetChecked(Config:Get("suggestOtherCharacters") ~= false)
    widgets.followGoals:SetChecked(Config:Get("farmerGoalsFollowQueue") ~= false)
    widgets.shareQueue:SetChecked(Config:Get("queueAltCrafting") == true)
    widgets.queueMail:SetChecked(Config:Get("queueMailPanel") ~= false)
    local spare = Config:Get("bagSpareSlots")
    Put(widgets.bagSpare, type(spare) == "number" and spare or 5)
    widgets.mailBatch:SetChecked(Config:Get("mailBatchTake") == true)
    widgets.deNext:SetChecked(Config:Get("queueDisenchantNext") == true)
    widgets.sellMarked:SetChecked(Config:Get("sellMarkedButton") ~= false)
    widgets.fillBuy:SetChecked(Config:Get("fillBuyQuantity") ~= false)
    widgets.vendorAuction:SetChecked(Config:Get("vendorItemsOnAuction") == true)
    local buyWarn = Config:Get("buyWarnPercent")
    Put(widgets.buyWarn, type(buyWarn) == "number" and buyWarn or 25)
    local disenchanterBox = widgets.disenchanter.editBox
    if not (disenchanterBox.HasFocus and disenchanterBox:HasFocus()) then
        local saved = Config:Get("disenchanterName") or ""
        if widgets.disenchanter:GetText() ~= saved then widgets.disenchanter:SetText(saved) end
    end
    widgets.disenchanterGuess:SetChecked(Config:Get("disenchanterGuess") ~= false)
    ShowPickedDisenchanter()
    widgets.disenchantQuality:SetValue(ns.QueueMail and ns.QueueMail:GetDisenchantQuality()
        or Config:Get("disenchanterQuality") or 2, true)
    widgets.valueOwned:SetChecked(Config:Get("valueOwnedMaterials") ~= false)
    widgets.autoScan:SetChecked(Config:Get("autoScan") ~= false)
    widgets.learnFromSearches:SetChecked(Config:Get("learnFromSearches") ~= false)
    widgets.professionValue:SetChecked(Config:Get("showValueInProfessionWindow") == true)
    ShowShiftMode(widgets.tooltipValue)
    ShowShiftMode(widgets.tooltipSalesShift)
    ShowShiftMode(widgets.tooltipTrend)
    widgets.upgradeArrows:SetChecked(Config:Get("showUpgradeArrows") ~= false)
    widgets.sisters:SetChecked(ns.SisterNote:IsOn())
    if ns.WhatsNew then
        widgets.whatsNewPopup:SetChecked(ns.WhatsNew:IsOn())
        widgets.whatsNewMotion:SetChecked(ns.WhatsNew:IsMotionOn())
    end
    ShowShiftMode(widgets.recipeTooltips)
    ShowShiftMode(widgets.enchantTooltips)
    if widgets.crateTooltips then ShowShiftMode(widgets.crateTooltips) end
    widgets.openWithShops:SetChecked(Config:Get("openWithShops") == true)
    widgets.effects:SetValue(ns.Motion and ns.Motion.Level() or "full")
    local textSize = Config:Get("textSize")
    widgets.textSize:SetValue(Theme.TEXT_STEPS[textSize] and textSize or "normal", true)
    widgets.textReload:SetShown((Theme.TEXT_STEPS[textSize] or 0) ~= Theme.TextStep())
    local Look = ns.BlizzardLook
    if Look then
        widgets.windowStyle:SetValue(Look.Wanted(), true)
        widgets.styleReload:SetShown(Look.Wanted() ~= Look.Style())
    end

    -- The three sizes, and the one dragged to when it is none of them.
    local scale = UI.GetWindowScale and UI:GetWindowScale() or 1
    local sizes, shown = {}, nil
    for _, size in ipairs(UI.SIZES or {}) do
        sizes[#sizes + 1] = { text = UI.ScaleText(size.scale), value = size.scale }
        if math.abs(size.scale - scale) < 0.005 then shown = size.scale end
    end
    if not shown then
        sizes[#sizes + 1] = { text = UI.ScaleText(scale), value = scale }
        shown = scale
    end
    widgets.windowSize:SetOptions(sizes)
    widgets.windowSize:SetValue(shown)
    widgets.mailReport:SetChecked(Config:Get("mailReport") ~= false)
    widgets.hideSaleChat:SetChecked(Config:Get("hideSaleChat") == true)
    for key, box in pairs(widgets.sounds) do
        box:SetChecked(Config:Get(key) ~= false)
    end
    widgets.saleAlarm:Refresh()
    widgets.cooldownAlerts:SetChecked(Config:Get("cooldownAlerts") ~= false)
    widgets.tradeRequests:SetChecked(Config:Get("tradeRequests") == true)
    widgets.vendorMapPins:SetChecked(Config:Get("vendorMapPins") == true)
    widgets.arrowRoute:SetChecked(type(ns.db) == "table" and ns.db.arrowRoute ~= false)
    widgets.useTomTom:SetChecked(type(ns.db) ~= "table" or ns.db.useTomTom ~= false)
    widgets.goldTracker:SetChecked(Config:Get("goldTracker") == true)
    widgets.priceOrder:SetValue(Config:Get("priceOrder") == "auctionator" and "auctionator" or "tsm", true)
    widgets.goldCount:SetValue(Config:Get("goldTrackerCount") == "character" and "character" or "all", true)
    local goldGoal = ns.GoldGoal and ns.GoldGoal:Goal()
    widgets.goldSeeThrough:SetValue(ns.GoldGoalUI and ns.GoldGoalUI.SeeThroughLevel()
        or tonumber(Config:Get("goldTrackerSeeThrough")) or 0, true)
    widgets.goldGoal:SetValue(goldGoal and math.floor(goldGoal / 10000) or nil, true)
    widgets.stale:SetValue(Config:Get("staleAfterSeconds") or (48 * 3600), true)

    local linkBox = widgets.linkNames.editBox
    if not (linkBox.HasFocus and linkBox:HasFocus()) then
        local saved = Config:Get("linkNames") or ""
        if widgets.linkNames:GetText() ~= saved then widgets.linkNames:SetText(saved) end
    end
    for key, box in pairs(widgets.linkShares) do
        box:SetChecked(Config:Get(key) ~= false)
    end
    local friendBox = widgets.friendNames.editBox
    if not (friendBox.HasFocus and friendBox:HasFocus()) then
        local saved = Config:Get("friendNames") or ""
        if widgets.friendNames:GetText() ~= saved then widgets.friendNames:SetText(saved) end
    end
    widgets.linkStatus:SetText(ns.AccountLink and ns.AccountLink:Describe() or "")
    widgets.guildPrices:SetChecked(Config:Get("guildPrices") == true)
    widgets.guildCrafters:SetChecked(Config:Get("guildCrafters") == true)
    if widgets.shareData then widgets.shareData:SetChecked(Config:Get("shareData") == true) end
    widgets.guildStatus:SetText(ns.GuildPrices and ns.GuildPrices:Status() or "")
    widgets.realmPrices:SetChecked(Config:Get("realmPrices") == true)
    widgets.realmStatus:SetText(ns.RealmPrices and ns.RealmPrices:Describe() or "")
    widgets.tsmPrices:SetChecked(Config:Get("tsmPrices") ~= false)
    widgets.tsmStatus:SetText(ns.TSMPrices and ns.TSMPrices:Describe() or "")
    widgets.auctionatorPrices:SetChecked(Config:Get("auctionatorPrices") ~= false)
    widgets.auctionatorStatus:SetText(ns.AuctionatorPrices and ns.AuctionatorPrices:Describe() or "")

    local lastScan, capped = ns.Prices:GetLastScan()

    widgets.dataSummary:SetText(L.Format("%s items priced on %s",
        Util.Comma(ns.Prices:Count()), Config:GetRealmKey()))

    local lastText = L["never"]
    if lastScan then
        local age = Util.FormatAgeAgo(time() - lastScan)
        lastText = capped and L.Format("%s (stopped at the page limit)", age) or age
    end
    widgets.recipeSummary:SetText(L.Format("%s recipes saved  ·  last scan %s",
        Util.Comma(ns.Recipes:Count()), lastText))

    -- The beta can start a session with nothing. Say so where the data
    -- counts are shown, rather than leaving it looking like the addon
    -- forgot everything on its own.
    local diagnostics = ns.Config:GetLoadDiagnostics()
    widgets.loadWarning:SetTextColor(Theme.Unpack("warn"))
    if ns.Config:IsFirstRun() then
        widgets.loadWarning:SetTextColor(Theme.Unpack("text"))
        widgets.loadWarning:SetText(
            L["This is the first time the addon has run here, so there is no saved data yet."])
    elseif diagnostics.restoredFromCVars then
        widgets.loadWarning:SetText(
            L["The game did not load your saved data at login, so it was recovered from the backup in CVars."])
    elseif diagnostics.globalType ~= "table" and not diagnostics.restored then
        widgets.loadWarning:SetText(
            L["The game did not load your saved data at login, so this session started fresh."])
    else
        widgets.loadWarning:SetText("")
    end

    local auctionAge = ns.Auctions:GetAge()
    widgets.auctionSummary:SetText(auctionAge
        and L.Format("Your auctions last read %s.", Util.FormatAgeAgo(auctionAge))
        or L["Your auctions have never been read. Open the auction house once."])

    local bankAge = ns.Inventory:GetBankAge()
    widgets.bankSummary:SetText(bankAge
        and L.Format("Bank contents last read %s.", Util.FormatAgeAgo(bankAge))
        or L["Bank never read. Visit a bank so material counts include it."])

    -- Last: the warnings above wrap to different heights depending on what
    -- they say, so the page's total height is only known once they are set.
    FitScroll()
end

--------------------------------------------------------------------------------
-- Clear price data and Reset to defaults, typed (the owner, 2026-10-15)
--------------------------------------------------------------------------------

--- Delete every stored price for this realm. The other realms keep their
--- prices, so they keep their scan times and sizes too.
function UI:ClearPriceData()
    local realmKey = ns.Config:GetRealmKey()
    ns.db.prices[realmKey] = {}
    ns.db.lastFullScan = nil
    -- The page-limit stamp too: a big auction house only ever has that one,
    -- and left behind it went on saying "scanned 3h ago" over no prices.
    for _, field in ipairs({ "lastFullScanByRealm", "lastCappedScanByRealm",
                             "sweepSeenByRealm", "sweepRefusedByRealm" }) do
        if ns.db[field] then ns.db[field][realmKey] = nil end
    end
    ns.Print(L["price data cleared for this realm"])
    if UI.RefreshActiveTab then UI:RefreshActiveTab() end
    if UI.UpdateHeader then UI:UpdateHeader() end
end

--- Put every setting back to how it started.
function UI:ResetSettings()
    -- Through Config:Set, as every other setting change is, so a session
    -- keeping its settings in the backup store saves these too.
    for key, value in pairs(ns.Config.DEFAULTS.settings) do
        ns.Config:Set(key, value)
    end

    -- What each control does on a change, done for the reset too. Only the
    -- values moved before: queued sub-crafts stayed as they were, the
    -- profession window kept its old values, and a folded side panel grew
    -- to full height with nothing in it.
    ns.Queue:RebuildDependencies()
    ns.Queue:Notify()
    if ns.RecipeValue then ns.RecipeValue:Refresh() end
    if ns.Columns then ns.Columns:Reload() end
    if UI.ApplyScale then UI:ApplyScale() end
    for _, panel in ipairs({ ns.PostPanel, ns.CraftPanel }) do
        if panel and panel.frame then
            ns.Collapse.Apply(panel.frame)
            panel:ApplyHeight()
            panel:Refresh()
        end
    end

    ns.Print(L["settings reset to defaults"])
    if UI.RefreshActiveTab then UI:RefreshActiveTab() end
end

--- True when the typed words are "confirm".
local function Confirmed(args)
    return (args or ""):lower():match("^%s*confirm%s*$") ~= nil
end

-- These delete data, so they are typed and never a Settings button.
ns.RegisterCommand("clearprices", L["delete every saved price on this realm (add confirm)"], function(args)
    if not Confirmed(args) then
        ns.Print(L["This deletes every saved price on this realm. Type /bts clearprices confirm to do it."])
        return
    end
    UI:ClearPriceData()
end)

ns.RegisterCommand("reset", L["put every setting back to how it started (add confirm)"], function(args)
    if not Confirmed(args) then
        ns.Print(L["This puts every setting back to how it started. Type /bts reset confirm to do it."])
        return
    end
    UI:ResetSettings()
end)

UI:RegisterTab({
    key = "settings",
    text = L["Settings"],
    order = 12,
    build = Build,
    refresh = Refresh,
    onShow = Refresh,
})
