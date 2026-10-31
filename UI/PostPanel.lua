-- Blackthornes Tradeskills -- UI/PostPanel.lua
-- The sell list, docked beside Blizzard's auction house: the one Tradeskills
-- drawer there (the owner's mockup, 2026-10-13), the full height of the
-- auction window, with Scan and Post Crafted in its header and List all at
-- its foot.
--
-- Listing can work through a whole bag, so what is about to be sold needs to
-- be visible before the first click rather than discovered one confirmation
-- dialog at a time. This is that list: everything postable, its price, and a
-- button per row for selling just the one.
--
-- Deliberately beside the auction house rather than inside our own window:
-- the decision to sell is made while looking at the auction house, and a list
-- behind another frame may as well not exist.

local _, ns = ...

local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local PostPanel = ns.NewModule("PostPanel")

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

-- Wider than it needs to be for the text alone: the amount to list sits beside
-- the button, and squeezing it in would have cost the item names their width.
local PANEL_WIDTH = 372
local ROW_HEIGHT = 32

-- Inside the gold rim: the header strip starts below the plate across the
-- top edge, and everything else below the header (UI/Main.lua's auction bar,
-- which carries the fold button, the scan's status and the two buttons).
local EDGE_PAD = 11
local HEADER_TOP = 18
local HEADER_HEIGHT = (ns.UI and ns.UI.AUCTION_BAR_HEIGHT) or 44
local CONTENT_TOP = -(HEADER_TOP + HEADER_HEIGHT + 7)

-- Folded, the drawer is its header, so Scan stays in reach.
PostPanel.FOLDED_HEIGHT = HEADER_TOP + HEADER_HEIGHT + EDGE_PAD
PostPanel.SUMMARY_LEAST = 18

-- The band at the foot with List all, the drawer's one gold button.
local FOOT_HEIGHT = 34
local LIST_BOTTOM = EDGE_PAD + FOOT_HEIGHT + 4

local BUTTON_WIDTH = 46

-- Wider when the List or Search word needs it (German runs longer). Measured
-- once at load; a client that cannot measure yet keeps 46.
do
    local measure = Theme and Theme.MeasureText
    if type(measure) == "function" then
        for _, word in ipairs({ L["List"], L["Search"] }) do
            local ok, width = pcall(measure, "small", word)
            if ok and type(width) == "number" then
                BUTTON_WIDTH = math.max(BUTTON_WIDTH, width + 10)
            end
        end
    end
end
local QUANTITY_WIDTH = 42

-- The red x that ignores an item, at the row's right end past List. A
-- symbol rather than the word: "Ignore" would have cost the item names their
-- room. Beside the amount box it read as "x 8", so it sits apart from it.
local IGNORE_WIDTH = 20

-- Right margin, ignore, gap, button, gap, quantity box, gap before the text.
local TEXT_INSET = 6 + IGNORE_WIDTH + 6 + BUTTON_WIDTH + 6 + QUANTITY_WIDTH + 10

-- Clear of the auction window's bevelled edge without opening a gap you could
-- see the world through.
local PANEL_GAP = 6

-- Only used when Blizzard's auction window cannot be found at all.
local PANEL_FALLBACK_HEIGHT = 420

-- Short enough to still show a few rows. Below this the panel stops giving
-- way to the main window: at that point there is no arrangement that fits,
-- and a panel squeezed to nothing is worse than one that overlaps.
local PANEL_MIN_HEIGHT = 200

-- Remembers whether the panel is folded down to its title (UI/Collapse.lua).
local COLLAPSE_KEY = "postPanelCollapsed"

-- The Sell and Buy switch under the title. Buy is the craft queue's shopping
-- list, the one beside the profession window (2026-10-01: "could we
-- have a shopping list also appear on the actual AH UI somewhere that's not
-- in the way?"). Sharing this panel puts it at the auction house without
-- taking any more of the screen.
local SWITCH_HEIGHT = 28
local SHOPPING_ROW_HEIGHT = 28

-- The shopping list walks the queue, the bags and every character's saved
-- counts, too much for the one-second ticker; at most this often instead.
local SHOPPING_REFRESH_SECONDS = 2

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

-- Declared early because typing in a row's quantity box redraws that one row.
-- Rebuilding the list instead would scroll it back to the top, and losing your
-- place every time you change a number is worse than the problem being solved.
local UpdateRow

--- Is the player part-way through typing a number into this box?
--
-- Guarded rather than called outright: this client has gaps in the frame API,
-- and a missing HasFocus would turn a redraw into an error.
local function BeingTyped(box)
    return box.editBox.HasFocus and box.editBox:HasFocus()
end

--- Is a LIST box anywhere in this list being typed into?
--
-- The list is redrawn every second at the auction house, sorted by value,
-- and rows are reused. Redrawn mid-number, the box being typed in could end
-- up on a different item, and the number went to that one when it was
-- entered. So the redraw waits until the typing is done.
local function TypingInList(list)
    for _, row in ipairs((list and list.rows) or {}) do
        if row.quantity and row:IsShown() and BeingTyped(row.quantity) then
            return true
        end
    end
    return false
end

--- Enter whatever is half-typed in a LIST box of this list, as Enter would.
--
-- Clicking a button does not take the keyboard from a box, so a number typed
-- and not yet entered was still waiting when List was clicked: the old
-- amount was listed, often the whole stack, with the new one on screen.
local function CommitTyping(list)
    for _, row in ipairs((list and list.rows) or {}) do
        if row.quantity and BeingTyped(row.quantity) then
            row.quantity.editBox:ClearFocus()
        end
    end
end

local function CreateRow(row)
    -- The item's icon at the start of the name line, as the bags draw it.
    row.icon = Theme.CreateItemIcon(row, 13)
    row.icon:SetPoint("TOPLEFT", 8, -3)

    -- Right edges tied to the row, which is narrower than the panel (the
    -- list is inset, and narrower again with the scrollbar). Widths taken
    -- from the panel ran the text under the quantity box and List button.
    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("TOPLEFT", 25, -4)
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -TEXT_INSET, -4)

    -- The list whose rules it follows (Logic/ListRules.lua), or "Own price"
    -- when its own price on the Prices tab wins, at the end of the name line.
    if ns.ListRulesUI then
        row.chip = ns.ListRulesUI.CreateChip(row)
        row.chip:SetPoint("TOPRIGHT", row, "TOPRIGHT", -TEXT_INSET, -4)
    end

    row.detail = Theme.CreateLabel(row, "tiny", "muted")
    row.detail:SetPoint("TOPLEFT", 8, -18)
    row.detail:SetPoint("TOPRIGHT", row, "TOPRIGHT", -TEXT_INSET, -18)

    -- The price line is a field: click it to set your own price each, or a
    -- total (UI/PriceEditor.lua, asked 2026-10-08 to sell a bad buy under
    -- market). Drawn as a box with a gold edge that lights under the mouse,
    -- so it reads as something to click rather than plain text.
    local field = CreateFrame("Button", nil, row)
    field:SetPoint("TOPLEFT", row.detail, "TOPLEFT", -4, 2)
    field:SetHeight(14)
    field:SetWidth(60)
    Theme.Fill(field, "panel", 0.6)
    Theme.Border(field, "metal", 0.45)
    if Theme.Halo then Theme.Halo(field, 4, 0) end
    -- The text stays on top of the box.
    row.detail:SetParent(field)
    row.detail:SetDrawLayer("OVERLAY")
    field:SetScript("OnEnter", function(self)
        Theme.SetBorderColor(self, "accentHi")
        if rawget(self, "haloTextures") then Theme.SetHalo(self, 0.25) end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["Set your own price"], 1, 1, 1)
        GameTooltip:AddLine(L["Click to set a price each, or a total for the stack."], 0.9, 0.9, 0.9, true)
        if row.data and row.data.priceBasis == "chosen" and row.data.suggestedPrice then
            GameTooltip:AddDoubleLine(L["Suggested"],
                Util.FormatMoney(row.data.suggestedPrice, { noColor = true }), 0.7, 0.7, 0.7, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    field:SetScript("OnLeave", function(self)
        Theme.SetBorderColor(self, "metal", 0.45)
        if rawget(self, "haloTextures") then Theme.SetHalo(self, 0) end
        GameTooltip:Hide()
    end)
    field:SetScript("OnClick", function()
        CommitTyping(PostPanel.list)
        if row.data and ns.PriceEditor then ns.PriceEditor:Open(row.data, PostPanel.frame) end
    end)
    row.priceField = field

    row.post = Widgets.CreateButton(row, L["List"], function()
        CommitTyping(PostPanel.list)
        if not row.data then return end

        ns.Posting:Request(row.data.itemID, row.data.postQuantity, row.data.unitPrice)
    end, { width = BUTTON_WIDTH, height = 18 })
    row.post:SetPoint("RIGHT", -(6 + IGNORE_WIDTH + 6), 0)

    -- How many to list, beside the button that lists them. Empty-handed this
    -- panel posted whole stacks with no way to say otherwise.
    row.quantity = Widgets.CreateNumberBox(row, {
        width = QUANTITY_WIDTH,
        height = 18,
        background = "panel",
        min = 1,
        onChange = function(value)
            if not row.data then return end

            ns.Posting:ApplyQuantity(row.data, value)
            UpdateRow(row, row.data)
        end,
    })
    row.quantity:SetPoint("RIGHT", row.post, "LEFT", -6, 0)

    -- Takes the item off this list for good, on every character
    -- (2026-10-04). Settings lists what is ignored, with a Restore button for
    -- each, so a misclick is never for good.
    row.ignore = Widgets.CreateButton(row, "x", function()
        if not row.data then return end
        CommitTyping(PostPanel.list)

        -- By item, so every copy goes: a "Lead Band of the Wolf" ignores
        -- all Lead Bands, and Settings names it by the plain item name.
        local line = row.data
        ns.Posting:SetIgnored(line.itemID, true)
        ns.Print(L.Format("ignored %s: it no longer shows on Ready to sell. Restore it under Ignored items in Settings.",
            line.label or L["that item"]))
    end, { width = IGNORE_WIDTH, height = 18,
           tooltip = L["Hides this from Ready to sell. Restore it in Settings."] })
    row.ignore:SetPoint("RIGHT", -6, 0)
end

--- What one of this item is worth disenchanted, for an enchanter.
--
-- Only for a character that knows Disenchant (or a client that will not
-- say), since to anyone else it is not a choice they have.
-- @return value, beatsSale  -- nil when it does not apply
local function DisenchantFor(line)
    if not ns.Disenchant or not ns.Disenchanter then return nil end
    if ns.Disenchanter:Knows() == false then return nil end

    local value = ns.Disenchant:GetValue(line.itemID)
    if not value then return nil end

    return value, line.unitPrice ~= nil and value > line.unitPrice
end

PostPanel._DisenchantFor = DisenchantFor
PostPanel._TypingInList = TypingInList

--- Whether a row's detail line runs past the room it has. False when it
--- cannot be measured, so nothing is shortened on a guess.
local function DetailTooWide(row)
    local label = row.detail
    -- Theme.TextWidth, because a label's own GetStringWidth can stop at the
    -- label's width, and then nothing is ever too wide.
    local width = Theme.TextWidth(label)
    if not width then return false end

    local room = label:GetWidth()
    if type(room) ~= "number" or room <= 0 then
        -- Not laid out yet: the room its anchors will give it.
        local rowWidth = row:GetWidth()
        room = type(rowWidth) == "number" and (rowWidth - 8 - TEXT_INSET) or nil
    end

    return room ~= nil and room > 0 and width > room
end

PostPanel._DetailTooWide = DetailTooWide

--- Why a line is a loss, in words the player can act on.
local function LossText(line)
    if line.lossReason == "vendor" then
        return L["Below what a vendor would pay for it."]
    end
    if line.lossReason == "crafted" then
        return L["Below what you paid to make it, after the auction house's cut."]
    end
    return L["Below what the materials cost."]
end

--- Where the price line sits: under the name, which can wrap onto more
--- lines. A long name used to run over the price line (a player's report,
--- 2026-10-17), so a wrapped name pushes it down and the row grows to hold
--- both. `need` is how tall the wrapped name stands, nil on one line.
local function PlaceDetail(row, need)
    local y = need and -(4 + need + 2) or -18
    row.detail:SetPoint("TOPLEFT", row, "TOPLEFT", 8, y)
    row.detail:SetPoint("TOPRIGHT", row, "TOPRIGHT", -TEXT_INSET, y)
    if need then
        -- The price line under it, and a little room below.
        row.name.rowNeed = need + 16
    end
end

PostPanel._PlaceDetail = PlaceDetail

--- The row's tag: its list's name, or "Own price", and what each means.
local function ListTag(line)
    if not line.listName then return nil end
    if line.ownPriceWins then
        return L["Own price"], "own", L.Format("On %s, but its own price wins", line.listName)
    end
    return line.listName, "list", L.Format("Following your %s list.", line.listName)
end

PostPanel._ListTag = ListTag

function UpdateRow(row, line)
    -- The tag first, so the name knows how much room it has.
    local chip = rawget(row, "chip")
    if chip then
        local text, kind, hover = ListTag(line)
        chip:Set(text, kind, hover)
        row.name:ClearAllPoints()
        row.name:SetPoint("TOPLEFT", 25, -4)
        if text then
            row.name:SetPoint("TOPRIGHT", chip, "TOPLEFT", -4, 0)
        else
            row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -TEXT_INSET, -4)
        end
    end

    -- Whole, never cut to "...": smaller, then wrapped, when it is long.
    if Theme.SetRowName then Theme.SetRowName(row.name, line.label) else row.name:SetText(line.label) end
    local need = rawget(row.name, "rowNeed")
    PlaceDetail(row, type(need) == "number" and need or nil)
    Theme.SetItemIcon(row.icon, line.itemID)

    local maxQuantity = line.maxQuantity or line.count or 1
    -- How many the bags hold sits on the icon's corner, as in the bags
    -- (UI/ItemLook.lua); the price line still says how many go up.
    if ns.ItemLook then ns.ItemLook.SetCount(row.icon, maxQuantity) end

    -- Not while it is being typed into: overwriting someone mid-number is how
    -- a field ends up refusing to accept what they meant.
    -- A reused row now showing another item drops the half-typed number,
    -- though: it was for the item that scrolled away, and pressing Enter
    -- would have set that many of this one. The Queue tab does the same.
    local typing = BeingTyped(row.quantity)
    if not typing or row.boundItemID ~= line.itemID then
        row.quantity:SetLimits(1, math.max(1, maxQuantity))
        row.quantity:SetValue(line.postQuantity or maxQuantity, true)
        if typing then row.quantity.editBox:ClearFocus() end
    end
    row.boundItemID = line.itemID

    -- Quantity and unit price on one line: together they are the decision,
    -- and a commodity posting 63 at once is worth noticing before clicking.
    -- Listing part of a stack says so, since "7 @ 6c" out of 20 in the bag
    -- reads the same as all of them otherwise.
    local eachPrice = Util.FormatMoney(line.unitPrice, { noColor = true, short = true })
    local each = line.postQuantity < maxQuantity
        and L.Format("%d of %d @ %s", line.postQuantity, maxQuantity, eachPrice)
        or L.Format("%d @ %s", line.postQuantity, eachPrice)
    -- Held down to the Highest price the player set (2026-10-28).
    if line.priceBasis == "highest" then each = L.Format("%s (the most you set)", each) end
    local total = "  =  " .. Util.FormatMoney(line.postTotal or 0, { noColor = true, short = true })

    -- Beside the price, so selling and disenchanting read against each
    -- other: green when disenchanting one is worth more than listing it.
    local disenchant, beats = DisenchantFor(line)
    local de = ""
    if disenchant then
        de = "   " .. L.Format("DE %s", Util.FormatMoney(disenchant, { noColor = true, short = true }))
        if beats then de = ("|c%s%s|r"):format(ns.COLORS.profit, de) end
    end

    -- Measured, and shortened rather than cut off: with gold-sized prices
    -- the end of the line ran under the LIST box. The total goes first when
    -- disenchanting wins (that green is the point), the disenchant value
    -- first otherwise; the tooltip has both.
    row.detail:SetText(each .. total .. de)

    if DetailTooWide(row) then
        row.detail:SetText(beats and (each .. de) or (each .. total))
        if DetailTooWide(row) then row.detail:SetText(each) end
    end

    -- Another Blackthornes addon wants it kept: why, in place of the price
    -- (the price is on the tooltip and the List button).
    if line.held then row.detail:SetText(line.held) end

    -- The field round the price line, as wide as its words.
    if row.priceField then
        local width = Theme.TextWidth(row.detail)
        local room = row.detail:GetWidth()
        if type(room) == "number" and room > 0 and width and width > room then width = room end
        row.priceField:SetWidth(math.max(40, (width or 60) + 8))
    end

    if line.held then
        row.name:SetTextColor(Theme.Unpack("muted"))
        row.detail:SetTextColor(Theme.Unpack("accent"))
    elseif line.atALoss then
        row.name:SetTextColor(Theme.Unpack("loss"))
        row.detail:SetTextColor(Theme.Unpack("loss"))
    else
        -- Rarity, the same as the Profit tab, so the two read alike.
        local r, g, b = Util.GetItemQualityColor(line.itemID)

        if r then
            row.name:SetTextColor(r, g, b)
        else
            row.name:SetTextColor(Theme.Unpack("text"))
        end

        -- A price of your own (the price editor) in gold, as the Prices
        -- tab draws "my price".
        row.detail:SetTextColor(Theme.Unpack(line.priceBasis == "chosen" and "accent" or "muted"))
    end

    row.post:SetEnabledState(line.unitPrice ~= nil)

    row.post.tooltipText = line.held
        and L.Format("%s. A click still lists it.", line.held)
        or line.atALoss
        and LossText(line)
        or L.Format("List %d of %d at %s each.",
            line.postQuantity, maxQuantity,
            Util.FormatMoney(line.unitPrice or 0, { noColor = true }))
end

--- The crafted cost lines (Logic/CraftedCost.lua) on the row's tooltip.
local function AddCraftedLines(line)
    if not ns.CraftedCost then return end
    for _, entry in ipairs(ns.CraftedCost:Lines(line.itemID, line.unitPrice)) do
        local r, g, b = 1, 1, 1
        if entry.color then r, g, b = Theme.Unpack(entry.color) end
        GameTooltip:AddDoubleLine(entry[1], entry[2], 0.7, 0.7, 0.7, r, g, b)
    end
end

local function ShowRowTooltip(row, line)
    -- The copy that would be listed, so its suffix and stats show.
    ns.Widgets.ShowItemTooltip(row, "ANCHOR_LEFT", line.itemID, line.label, line.link)
    GameTooltip:AddLine(" ")

    -- Another Blackthornes addon wants it kept (Logic/SisterKeeps.lua).
    if line.held then
        GameTooltip:AddLine(line.held, Theme.Unpack("accent"))
        GameTooltip:AddLine(L["List all leaves it. Its List button still lists it."], 0.5, 0.5, 0.5, true)
        GameTooltip:AddLine(" ")
    elseif line.kept and line.keptWhy then
        GameTooltip:AddLine(L.Format("%d kept back: %s", line.kept, line.keptWhy), Theme.Unpack("accent"))
        GameTooltip:AddLine(" ")
    end

    -- The list it follows (Logic/ListRules.lua).
    local _, _, listHover = ListTag(line)
    if listHover and not (line.held or line.keptWhy == listHover) then
        GameTooltip:AddLine(listHover, Theme.Unpack("accent"))
        GameTooltip:AddLine(" ")
    end

    GameTooltip:AddDoubleLine(L["In bags"], tostring(line.count), 0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddDoubleLine(L["Listing"], L.Format("%d of %d",
        line.postQuantity, line.maxQuantity or line.count), 0.7, 0.7, 0.7, 1, 1, 1)

    if line.unitCost then
        GameTooltip:AddDoubleLine(L["Cost each"],
            Util.FormatMoney(line.unitCost, { noColor = true }), 0.7, 0.7, 0.7, 1, 1, 1)
    end

    -- What it cost when it was made, what it last went up at, and what this
    -- listing makes over that cost (2026-10-05).
    AddCraftedLines(line)

    if line.vendorPrice then
        GameTooltip:AddDoubleLine(L["Vendor pays"],
            Util.FormatMoney(line.vendorPrice, { noColor = true }), 0.7, 0.7, 0.7, 1, 1, 1)
    end

    local disenchant, beats = DisenchantFor(line)
    if disenchant then
        GameTooltip:AddDoubleLine(L["Disenchant value"],
            Util.FormatMoney(disenchant, { noColor = true }), 0.7, 0.7, 0.7, 1, 1, 1)
        if beats then
            GameTooltip:AddLine(L.Format("Disenchanting it is worth %s more than listing it.",
                Util.FormatMoney(disenchant - line.unitPrice, { noColor = true })), 0.35, 0.85, 0.45, true)
        end
    end

    -- Overcutting (2026-10-15): why the price sits above the cheapest.
    if line.priceBasis == "overcut" and ns.Profit and ns.Profit.Overcut then
        local rival = ns.Prices:GetScanValue(line.itemID, "rival")
        local ok, over, _, wall, count, ahead = pcall(ns.Profit.Overcut, ns.Profit, line.itemID, rival,
            ns.Config:Get("undercutCopper") or 1)
        if ok and over then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(L["Overcutting"], Theme.Unpack("accent"))
            GameTooltip:AddDoubleLine(L["Cheapest now"], Util.FormatMoney(rival, { noColor = true }),
                0.7, 0.7, 0.7, 1, 1, 1)
            GameTooltip:AddDoubleLine(L["Big stack"], L.Format("%d at %s", count,
                Util.FormatMoney(wall, { noColor = true })), 0.7, 0.7, 0.7, 1, 1, 1)
            GameTooltip:AddDoubleLine(L["Cheaper ones ahead of you"], tostring(ahead),
                0.7, 0.7, 0.7, 1, 1, 1)
            GameTooltip:AddLine(L["Those should sell first, then yours."], 0.5, 0.5, 0.5, true)
        end
    end

    GameTooltip:AddLine(line.isCommodity
        and L["Sells from all your bags at once"]
        or L["Lists one stack at a time"], 0.5, 0.5, 0.5)

    if line.priceBasis == "chosen" then
        GameTooltip:AddDoubleLine(L["Your price"],
            Util.FormatMoney(line.unitPrice, { noColor = true }), 0.7, 0.7, 0.7, 0.78, 0.64, 0.30)
        if line.suggestedPrice then
            GameTooltip:AddDoubleLine(L["Suggested"],
                Util.FormatMoney(line.suggestedPrice, { noColor = true }), 0.7, 0.7, 0.7, 1, 1, 1)
        end
    end

    GameTooltip:AddLine(L["Type in the box to list fewer than that."], 0.5, 0.5, 0.5)
    GameTooltip:AddLine(L["Click the price to set your own."], 0.5, 0.5, 0.5)

    GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------

function PostPanel:Build()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", "BlackthornesTSPostPanel", UIParent)
    frame:SetWidth(PANEL_WIDTH)
    frame:SetFrameStrata("HIGH")

    -- Opaque, so a click on a row cannot fall through to the auction window
    -- underneath, and raised on click: this panel shares its strata with the
    -- main window, and without this the two have a fixed order forever. That
    -- order put the sell list across the main window's tab row.
    frame:EnableMouse(true)
    if frame.SetToplevel then frame:SetToplevel(true) end
    frame:Hide()

    Theme.Fill(frame, "window")
    -- The house frame (UI/Titanforged.lua): the gold rim and corner gems,
    -- the name on its plate, and the close gem, which puts the drawer away
    -- until the next visit to the auction house.
    if ns.Titanforged then
        ns.Titanforged:Dress(frame, {
            title = L["Tradeskills"],
            close = function() PostPanel:CloseForVisit() end,
        })
    else
        Theme.AddGameOutline(frame, { style = "dialog", color = "natural" })
    end
    -- The house glow round its edge, flaring as it opens.
    Theme.Halo(frame, 8, 0.08)

    -- Kept before the header is made: the header is UI/Main.lua's auction
    -- bar, which asks for this frame to live in.
    self.frame = frame

    -- The mouse wheel lists and cancels while the drawer shows, if ticked.
    if ns.AuctionWheel then ns.AuctionWheel:Watch(frame) end

    local header, title
    local UI = ns.UI
    if UI and type(UI.GetAuctionBar) == "function" then
        header = UI:GetAuctionBar()
        title = header.title
    end
    if not (header and title) then
        header, title = ns.Collapse.CreateHeader(frame, L["Ready to sell"])
    end
    header:ClearAllPoints()
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", EDGE_PAD, -HEADER_TOP)
    header:SetWidth(PANEL_WIDTH - 2 * EDGE_PAD)
    header:SetHeight(HEADER_HEIGHT)
    self.header = header
    self.title = title

    -- Everything under the title, so the collapse button can fold it away in
    -- one go and leave the title strip showing.
    local body = CreateFrame("Frame", nil, frame)
    body:SetAllPoints(frame)
    self.body = body

    ns.Collapse.Attach(frame, {
        key = COLLAPSE_KEY,
        header = header,
        title = title,
        body = body,
        onToggle = function()
            PostPanel:ApplyHeight()
            PostPanel:Refresh()
        end,
    })

    -- Lists (a player asked, 2026-10-14): the player's own named shopping
    -- lists, UI/ShoppingListsView.lua. Auctions (asked the same day): your
    -- auctions, the undercut ones first with a Cancel each, UI/AuctionsView.lua.
    -- Favors (the owner, 2026-10-20): what a favor goal still needs, shown
    -- only while a goal is set (PostPanel:LayTabs), UI/FavorsView.lua.
    local views = { { "sell", L["Sell"] }, { "buy", L["Buy"] }, { "lists", L["Lists"] }, { "auctions", L["Auctions"] },
        { "favors", L["Favors"] } }
    local tabs = {}
    for _, view in ipairs(views) do tabs[#tabs + 1] = { key = view[1], text = view[2] } end
    -- The house's small view tabs, each as wide as its word (2026-10-29).
    -- What you searched for in the game's auction window, and its price
    -- (UI/SearchedPrice.lua, a player asked 2026-10-30): a gold row above
    -- the view tabs, only while there is one. PostPanel:PlaceSearched moves
    -- the tabs down under it.
    if ns.SearchedPrice and ns.SearchedPrice:Applies() then
        local searched = ns.SearchedPrice:Build(body)
        searched:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, CONTENT_TOP)
        searched:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, CONTENT_TOP)
        self.searched = searched
    end

    local switch = Widgets.CreateViewTabs(body, tabs, function(key)
        PostPanel:SetView(key)
    end, { width = PANEL_WIDTH - 28 })
    switch:SetPoint("TOPLEFT", 14, CONTENT_TOP)
    self.switch = switch
    self:LayTabs(true)
    switch:Select(self.view)

    -- Hide losses (asked 2026-10-11): a small box at the summary line's right
    -- end that leaves out the rows drawn red, the ones the auction house would
    -- sell for less than they cost. Off by default and kept between sessions.
    local hideLosses = Widgets.CreateCheckbox(body, L["Hide losses"], function(checked)
        ns.Config:Set("postHideLosses", checked and true or false)
        PostPanel:Refresh()
    end, PostPanel:HidingLosses())
    hideLosses:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, CONTENT_TOP - 28 - 3)
    hideLosses:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L["Hides items that would sell for less than they cost, or less than a vendor pays."], 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    hideLosses:HookScript("OnLeave", function() GameTooltip:Hide() end)
    self.hideLosses = hideLosses

    -- Overcutting (the owner, 2026-10-15): the same switch as Settings,
    -- beside Hide losses on Sell. Off unless ticked.
    local overcut = Widgets.CreateCheckbox(body, L["Overcutting"], function(checked)
        ns.Config:Set("overcutting", checked and true or false)
        PostPanel:Refresh()
        if ns.UI and ns.UI.RefreshActiveTab then ns.UI:RefreshActiveTab() end
    end, ns.Config:Get("overcutting") == true)
    overcut:SetPoint("TOPRIGHT", hideLosses, "TOPLEFT", -10, 0)
    overcut:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(ns.Profit.OVERCUT_HELP, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    overcut:HookScript("OnLeave", function() GameTooltip:Hide() end)
    self.overcutBox = overcut

    local summary = Theme.CreateLabel(body, "tiny", "muted")
    summary:SetPoint("TOPLEFT", switch, "BOTTOMLEFT", 0, -6)
    summary:SetPoint("RIGHT", overcut, "LEFT", -8, 0)
    summary:SetWordWrap(true)
    if summary.SetJustifyV then summary:SetJustifyV("TOP") end
    self.summary = summary

    local divider = Theme.CreateDivider(body)
    divider:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -6)
    divider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, 0)

    local list = Widgets.CreateScrollList(body, {
        rowHeight = ROW_HEIGHT,
        createRow = CreateRow,
        updateRow = UpdateRow,
        onEnter = ShowRowTooltip,
        onLeave = function() GameTooltip:Hide() end,
        -- Right-click: how many to keep on this character (UI/KeepBox.lua,
        -- the owner said build it 2026-10-18).
        onClick = function(line, _, mouseButton)
            if mouseButton == "RightButton" and line and line.itemID and ns.KeepBox then
                CommitTyping(PostPanel.list)
                ns.KeepBox:Open(line, PostPanel.frame)
            end
        end,
    })
    list:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -4)
    list:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, LIST_BOTTOM)
    self.list = list

    local shopping = Widgets.CreateScrollList(body, {
        rowHeight = SHOPPING_ROW_HEIGHT,
        createRow = PostPanel.CreateShoppingRow,
        updateRow = PostPanel.UpdateShoppingRow,
        onEnter = PostPanel.ShowShoppingTooltip,
        onLeave = function() GameTooltip:Hide() end,
        onClick = function(line) PostPanel:OpenShoppingLine(line) end,
        -- On Era, the line whose buy plan is open.
        isSelected = function(line)
            local buy = ns.LegacyBuy
            return buy ~= nil and buy.state ~= nil and type(line) == "table" and buy:IsOpenFor(line.itemID)
        end,
    })
    shopping:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -4)
    shopping:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, LIST_BOTTOM)
    shopping:Hide()
    self.shoppingList = shopping

    local View = ns.ShoppingListsView
    if View then
        View:Build(body, frame, divider, { bottom = LIST_BOTTOM, edge = EDGE_PAD, footHeight = FOOT_HEIGHT })
        if View.paste then View.paste:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, CONTENT_TOP - 28 - 3) end
    end

    if ns.AuctionsView then
        ns.AuctionsView:Build(body, frame, divider, { bottom = LIST_BOTTOM, edge = EDGE_PAD, footHeight = FOOT_HEIGHT })
    end
    if ns.FavorsView then
        ns.FavorsView:Build(body, frame, divider, { bottom = LIST_BOTTOM, edge = EDGE_PAD, footHeight = FOOT_HEIGHT })
    end

    local empty = Theme.CreateLabel(body, "small", "dim", "CENTER")
    empty:SetPoint("CENTER", list, "CENTER")
    empty:SetWidth(PANEL_WIDTH - 40)
    empty:SetWordWrap(true)
    self.empty = empty

    -- The foot: what List all does, and List all itself, the drawer's one
    -- solid gold button. One listing a click, most valuable first, since
    -- the game takes a click for every listing.
    if ns.Collapse.CreateFooter then ns.Collapse.CreateFooter(body, FOOT_HEIGHT) end

    local listAll = Widgets.CreateButton(body, L["List Next"], function()
        PostPanel:ListNext()
    end, { width = 110, height = 22, primary = true })
    listAll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(EDGE_PAD + 6), EDGE_PAD + 6)
    self.listAll = listAll
    listAll:HookScript("OnEnter", function()
        local line = PostPanel.nextLine
        if line and not PostPanel.checksFirst and ns.Posting.PrepareFor then
            ns.Posting:PrepareFor(line.itemID)
        end
    end)

    -- Search all (asked 2026-10-14): on Buy, the same place holds one
    -- button that looks up everything the auction house can sell you at
    -- once, as the Lists view's Search does. Shown only on Buy.
    local searchAll = Widgets.CreateButton(body, L["Search all"], function()
        PostPanel:SearchAll()
    end, { width = 110, height = 22, primary = true })
    searchAll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(EDGE_PAD + 6), EDGE_PAD + 6)
    searchAll:Hide()
    self.searchAll = searchAll

    -- How long listings stay up (a player asked, 2026-10-14): the same
    -- account wide postDuration as the Post tab's, so a pick in either shows
    -- in both. Forever's auction house offers 2, 8 and 24 hours.
    local durationWidth = 70
    if Theme.MeasureText then
        for _, option in ipairs(ns.Posting.DURATIONS) do
            local ok, width = pcall(Theme.MeasureText, "small", option.text)
            if ok and type(width) == "number" then durationWidth = math.max(durationWidth, width + 28) end
        end
    end
    local duration = Widgets.CreateDropdown(body, ns.Posting.DURATIONS, function(value)
        ns.Config:Set("postDuration", value)
        if ns.UI and ns.UI.RefreshActiveTab then ns.UI:RefreshActiveTab() end
        PostPanel:Refresh()
    end, { width = durationWidth, up = true })
    duration:SetPoint("LEFT", frame, "BOTTOMLEFT", EDGE_PAD + 8, EDGE_PAD + FOOT_HEIGHT / 2)
    duration:SetValue(ns.Config:Get("postDuration") or 2)
    duration:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["Duration"])
        GameTooltip:AddLine(L["How long each listing stays up. A longer one costs a bigger deposit."], 1, 1, 1, true)
        GameTooltip:Show()
    end)
    duration:HookScript("OnLeave", function() GameTooltip:Hide() end)
    self.duration = duration

    local footNote = Theme.CreateLabel(body, "tiny", "muted")
    footNote:SetPoint("LEFT", duration, "RIGHT", 8, 0)
    footNote:SetPoint("RIGHT", listAll, "LEFT", -8, 0)
    footNote:SetWordWrap(true)
    self.footNote = footNote

    -- Era's buy plan, at the foot of the Buy list (UI/LegacyBuyView.lua).
    if ns.LegacyBuyView then
        ns.LegacyBuyView:Build(body, frame, { edge = EDGE_PAD, bottom = LIST_BOTTOM })
    end

    return frame
end

--- A click on a Buy row or its Search: on Era, its buy plan opens (or
--- closes); elsewhere the auction house searches for it.
function PostPanel:OpenShoppingLine(line)
    if not self:CanSearch(line) then return end
    local View = ns.LegacyBuyView
    if View and View:Toggle(line) then
        self:Refresh()
        return
    end
    ns.UI:SearchAuctionHouse(line.itemID, line.shortfall)
end

--- On Era with the drawer up: open the Buy view on an item's buy plan,
--- for the AH buttons on the Queue panel, the Gather tab and the Lists.
-- @return true when the plan is open (or already was)
function PostPanel:OpenBuyPlan(itemID, need)
    local View, buy = ns.LegacyBuyView, ns.LegacyBuy
    if not (View and View:Applies() and buy) then return false end
    if not (self.frame and self.frame:IsShown()) then return false end
    if not buy:IsOpenFor(itemID) and not buy:Open(itemID, need) then return false end
    if self.view ~= "buy" then
        self:SetView("buy")
    else
        self:Refresh()
    end
    return true
end

--- The next Buy line still to buy after an item, for the plan's Next
--- button: list order from the one after it, then from the top. Only lines
--- a Search would look up (not vendor materials), never the same item.
function PostPanel:NextBuyLine(itemID)
    local lines = self:ShoppingLines() or {}
    local at = 0
    for i, line in ipairs(lines) do
        if line.itemID == itemID then at = i; break end
    end
    for step = 1, #lines do
        local line = lines[(at + step - 1) % #lines + 1]
        if line.itemID ~= itemID and self:CanSearch(line) then return line end
    end
end

--- What the search buttons' hover says. Era's auction house fills in no
--- count, so it only says what the button does there.
function PostPanel.SearchTip(text)
    if ns.LegacyScan and ns.LegacyScan:Applies() then return L["Searches the auction house."] end
    return text
end

--- A purchase was counted, or one in the mail was taken (Logic/AHBuys.lua):
--- the shopping list is built again, and drawn at once while it shows.
function PostPanel:OnPurchase()
    self.shoppingAt = nil
    if self.view == "buy" and self.frame and self.frame:IsShown() then self:Refresh() end
end

--- Era's buy plan moved on (Logic/LegacyBuy.lua).
function PostPanel:OnLegacyBuy()
    if self.frame and self.frame:IsShown() then self:Refresh() end
end

--- Make room at the foot of the Buy list for Era's buy plan, or give the
--- room back once it closes.
function PostPanel:PlaceBuyPlan()
    local View = ns.LegacyBuyView
    if not View or not View.panel then return end
    View:Refresh()
    local open = self.view == "buy" and View:IsOpen()
    local room = open and (View:Height() + 4) or 0
    if self.shoppingRoom ~= room then
        self.shoppingList:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -14, LIST_BOTTOM + room)
        self.shoppingRoom = room
    end
    if self.view ~= "buy" then return end
    if open then
        if self.searchAll then self.searchAll:Hide() end
        if self.footNote then
            self.footNote:SetText(L["One stack each click. They go to your mailbox."])
            if View.button and View.button:IsShown() then
                self.footNote:SetPoint("RIGHT", View.button, "LEFT", -8, 0)
            end
        end
    elseif self.footNote and self.searchAll then
        self.footNote:SetPoint("RIGHT", self.searchAll, "LEFT", -8, 0)
    end
end

--- Put the Scan strip in the header. The strip is UI/Main.lua's (it carries
--- the scan's status and the two buttons); this is where it goes.
--- Lay the view tabs, and what hangs off the same top, under the searched
--- item's row while it shows, or at the top as before.
function PostPanel:PlaceSearched(shown)
    shown = shown and true or false
    if self.searchedShown == shown then return end
    self.searchedShown = shown
    local frame, switch = self.frame, self.switch
    if not (frame and switch) then return end
    local top = CONTENT_TOP - (shown and (ns.SearchedPrice.HEIGHT + 6) or 0)
    switch:ClearAllPoints()
    switch:SetPoint("TOPLEFT", 14, top)
    if self.hideLosses then
        self.hideLosses:ClearAllPoints()
        self.hideLosses:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, top - 28 - 3)
    end
    local View = ns.ShoppingListsView
    if View and View.paste then
        View.paste:ClearAllPoints()
        View.paste:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, top - 28 - 3)
    end
end

function PostPanel:PlaceBar()
    local bar = self.header
    if not (bar and self.frame) then return end
    bar:ClearAllPoints()
    if self.inside then
        -- Inside the window's Auction House tab, as wide as the tab.
        bar:SetPoint("TOPLEFT", self.frame, "TOPLEFT", EDGE_PAD, -HEADER_TOP)
        bar:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -EDGE_PAD, -HEADER_TOP)
    else
        bar:SetPoint("TOPLEFT", self.frame, "TOPLEFT", EDGE_PAD, -HEADER_TOP)
        bar:SetWidth(PANEL_WIDTH - 2 * EDGE_PAD)
    end
    bar:Show()
end

--------------------------------------------------------------------------------
-- Inside the one Blackthornes window (the owner picked it, 2026-10-30): at
-- the auction house the drawer is laid into the window's Auction House tab,
-- filling it, bare of its own rim, plate, gems and glow, and back beside the
-- auction house when the window lets it go.
--------------------------------------------------------------------------------

-- The tab's container while the drawer is in it, else nil.
PostPanel.inside = nil

-- What the drawer wears on its own, put out of sight inside and back after.
local function Bare(frame, bare)
    local trim = rawget(frame, "titan")
    if trim and trim.SetShown then trim:SetShown(not bare) end
    if Theme.SetHalo then Theme.SetHalo(frame, bare and 0 or 0.08) end
end

--- Lay the drawer into `container`, filling it.
function PostPanel:LayIn(container)
    if not container then return end
    local frame = self:Build()
    self.inside = container
    if frame:GetParent() ~= container then frame:SetParent(container) end
    frame:ClearAllPoints()
    frame:SetAllPoints(container)
    Bare(frame, true)
    -- Never folded in there: the fold gem is the drawer's own.
    if self.body then self.body:Show() end
    self.attached = true
    self.closedThisVisit = false
    self:PlaceBar()
    frame:Show()
    self:Refresh()
end

--- Give the drawer back its own place, size and look. Hidden: the caller
--- docks it again beside the auction house when it is still open.
function PostPanel:LayOut()
    if not self.inside then return end
    self.inside = nil
    local frame = self.frame
    if not frame then return end
    frame:Hide()
    frame:SetParent(UIParent)
    frame:ClearAllPoints()
    frame:SetWidth(PANEL_WIDTH)
    Bare(frame, false)
    if ns.Collapse and ns.Collapse.Apply then ns.Collapse.Apply(frame) end
    self:PlaceBar()
end

--- The close gem: put the drawer away until the auction house is opened
--- again. Nothing is lost; the next visit brings it back.
function PostPanel:CloseForVisit()
    self.closedThisVisit = true
    if self.frame then self.frame:Hide() end
    if ns.PriceEditor and ns.PriceEditor.IsShown and ns.PriceEditor:IsShown() then ns.PriceEditor:Hide() end
end

--- The lines Sell shows now, Hide losses applied.
function PostPanel:ShownLines()
    local lines, toVendor = ns.Posting:GetPostable({ includeAll = true, showHeld = true })
    local hidden = 0
    if self:HidingLosses() then lines, hidden = PostPanel.WithoutLosses(lines) end
    return lines, hidden, toVendor or 0
end

--- List all: list the most valuable stack still on the list. Each click
--- lists one, as the game asks for a click a listing.
function PostPanel:ListNext()
    CommitTyping(self.list)

    local Posting = ns.Posting
    -- Era: the last listing is still going in. The press waits for the
    -- next one rather than being spent half way.
    if Posting.Settling and Posting:Settling() then return end

    local lines = self.shownLines or self:ShownLines()
    local fast = Posting.FastListing ~= nil and Posting:FastListing()

    -- Fast listing passes over an item still being confirmed: before the
    -- bags catch up, the same stack would come up again.
    local line, settling = Posting:GetNextPostable(fast and { skipSettling = true } or nil, lines)
    if not line then
        if settling then
            ns.Print(L["waiting for your last listing to go through"])
        else
            ns.Print(L["nothing in your bags worth listing right now"])
        end
        return
    end

    -- The whole list is still being checked (Era, one item at a time):
    -- this one lists once its price is in.
    if fast and Posting.CheckingAll and Posting:CheckingAll() and not Posting:IsFresh(line.itemID) then
        return
    end

    -- Its price not checked lately: one search checks every price on the
    -- list, and the clicks after it list straight away. One the search
    -- could not price is searched for alone, as before.
    if fast and not Posting:IsFresh(line.itemID) and not Posting:BulkTried(line.itemID)
            and ns.Config:Get("verifyPriceBeforePosting") ~= false then
        local started, count = Posting:CheckAll(lines)
        if started then
            ns.Print(L.Format("checking the prices of %d items on your Sell list...", count))
            return
        end
    end

    local allowed, reason = ns.Posting:CanPost(line.itemID)
    if not allowed then
        ns.Print(reason or L["cannot post right now"])
        return
    end

    ns.Posting:Request(line.itemID, line.postQuantity, line.unitPrice)
end

--- List all's label and tooltip, from the lines Sell shows.
function PostPanel:UpdateListAll(lines)
    local button = self.listAll
    if not button then return end

    local count = 0
    if lines then count = ns.Posting:GetSummary(nil, lines) or 0 end
    self.listAllCount = count

    -- The stack the next click lists, and the one after it, for the hover.
    local Posting = ns.Posting
    local fast = Posting.FastListing ~= nil and Posting:FastListing()
    local nextLine = count > 0 and lines and Posting:GetNextPostable(fast and { skipSettling = true } or nil, lines) or nil
    self.nextLine = nextLine
    self.afterLine = nil
    if nextLine then
        local after = {}
        for _, line in ipairs(lines) do
            if line ~= nextLine then after[#after + 1] = line end
        end
        self.afterLine = Posting:GetNextPostable(fast and { skipSettling = true } or nil, after)
    end

    button.tooltipFunc = PostPanel.ListNextTooltip
    self:RefreshListAllLabel()
    self:RefreshListAllTip()

    -- Era: the stack the next click lists goes in the auction slot now, so
    -- one press lists it. Next frame, out of this redraw; it is a no-op
    -- once that stack is in.
    if nextLine and Posting.PrepareFor and Posting.IsLegacy and Posting.IsLegacy() then
        local itemID = nextLine.itemID
        C_Timer.After(0, function()
            if PostPanel.nextLine and PostPanel.nextLine.itemID == itemID then
                Posting:PrepareFor(itemID)
            end
        end)
    end

    button:SetEnabledState(count > 0)
    button.tooltipText = count > 0
        and L["Lists the most valuable stack. Click again for the next one."]
        or L["Nothing on the list can be listed right now."]
end

--- "Check Prices" when the next click only checks prices, else "List Next".
--- Cheap: run with the wait labels too, since a check goes stale with time.
function PostPanel:RefreshListAllLabel()
    local button = self.listAll
    if not button then return end

    local count = self.listAllCount or 0
    local checks = count > 0 and ns.Posting.WouldCheckAll ~= nil
        and ns.Posting:WouldCheckAll(self.nextLine, self.shownLines) or false
    self.checksFirst = checks

    local label
    if count <= 0 then
        label = L["List Next"]
    elseif checks then
        label = L.Format("Check Prices - %d to list", count)
    else
        label = L.Format("List Next - %d remaining", count)
    end
    if label == self.listAllLabel then return end
    self.listAllLabel = label

    if button.waitingLabel ~= true then button:SetText(label) end

    local width = Theme.MeasureText and Theme.MeasureText("small", label)
    button:SetWidth(math.max(110, (width or 0) + 24))
end

--- What List Next's hover shows, as one string, so it is drawn again only
--- when that changes.
local function ListTipKey(self, button)
    local function LineKey(line)
        if not line then return "" end
        return table.concat({ tostring(line.itemID), tostring(line.link or ""),
            tostring(line.postQuantity or 1), tostring(line.unitPrice or 0) }, ":")
    end
    return table.concat({ LineKey(self.nextLine), LineKey(self.afterLine),
        tostring(self.listAllCount or 0), tostring(self.checksFirst),
        tostring(button.waitingLabel == true and button.waitTip or "") }, "|")
end

--- After a click lists a stack the mouse is still on List Next, so its hover
--- would keep showing the stack just listed. Draw it again for the next one,
--- only while it is ours and only when what it shows moved.
function PostPanel:RefreshListAllTip()
    local button = self.listAll
    if not button then return end

    local key = ListTipKey(self, button)
    if key == button.tipKey then return end
    button.tipKey = key

    if type(GameTooltip) ~= "table" or type(GameTooltip.IsOwned) ~= "function" then return end
    local ok, owned = pcall(GameTooltip.IsOwned, GameTooltip, button)
    if not (ok and owned == true) then return end
    if button.IsMouseOver and not button:IsMouseOver() then return end

    local onEnter = button.GetScript and button:GetScript("OnEnter")
    if onEnter then pcall(onEnter, button) end
end

local function Money(copper)
    return Util.FormatMoney(copper)
end

local function ItemIcon(itemID)
    local ok, icon = pcall(function()
        if C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(itemID) end
        return GetItemIcon and GetItemIcon(itemID)
    end)
    return ok and icon or nil
end

--- List Next's hover: what the next click does. Returns true when drawn.
function PostPanel.ListNextTooltip(_, tooltip, wait)
    local self = PostPanel
    local line = self.nextLine
    if not line or (self.listAllCount or 0) <= 0 then return false end

    local gold = { 1, 0.82, 0 }
    if wait then
        tooltip:SetText(wait, 1, 1, 1, 1, true)
        tooltip:AddLine(" ")
    end
    local function Head(text)
        if wait then tooltip:AddLine(text, gold[1], gold[2], gold[3])
        else tooltip:SetText(text, gold[1], gold[2], gold[3]) end
    end

    if self.checksFirst then
        Head(L["Check prices first"])
        tooltip:AddLine(L["This click checks prices for everything here."], 1, 1, 1, true)
        tooltip:AddLine(L["Then each click lists one."], 1, 1, 1, true)
        return true
    end

    Head(L["Next to list"])
    local icon = ItemIcon(line.itemID)
    local name = line.label or Util.GetItemLabel(line.itemID)
    tooltip:AddLine((icon and ("|T%s:20:20|t "):format(icon) or "") .. tostring(name))

    local quantity = line.postQuantity or 1
    tooltip:AddLine(L.Format("%d at %s each", quantity, Money(line.unitPrice)), 1, 1, 1)
    tooltip:AddLine(" ")

    local total = line.postTotal or (line.unitPrice * quantity)
    local cut = ns.Config:Get("auctionCut") or 0.05
    tooltip:AddDoubleLine(L["Total"], Money(total), 1, 1, 1, 1, 1, 1)
    tooltip:AddDoubleLine(L["You get after the cut"], Money(total * (1 - cut)), 1, 1, 1, 1, 1, 1)
    if line.deposit then
        tooltip:AddDoubleLine(L["Deposit"], Money(line.deposit), 1, 1, 1, 1, 1, 1)
    end

    local Prices = ns.Prices
    local market
    if Prices then
        local ok, value = pcall(function()
            if line.link and Prices.GetLinkValue then return Prices:GetLinkValue(line.link) end
            return Prices:GetValue(line.itemID, "market")
        end)
        market = ok and value or nil
    end
    local disenchant
    if ns.Disenchant and ns.Disenchant.GetValue then
        local ok, value = pcall(ns.Disenchant.GetValue, ns.Disenchant, line.itemID)
        disenchant = ok and value or nil
    end
    local made = line.craftedCost or line.unitCost

    if market or line.vendorPrice or disenchant or made then tooltip:AddLine(" ") end
    local grey = 0.6
    if market then tooltip:AddDoubleLine(L["Market value"], Money(market), grey, grey, grey, 1, 1, 1) end
    if line.vendorPrice and line.vendorPrice > 0 then
        tooltip:AddDoubleLine(L["Vendor"], Money(line.vendorPrice), grey, grey, grey, 1, 1, 1)
    end
    if disenchant then tooltip:AddDoubleLine(L["Disenchant"], Money(disenchant), grey, grey, grey, 1, 1, 1) end
    if made then tooltip:AddDoubleLine(L["Cost to make"], Money(made), grey, grey, grey, 1, 1, 1) end

    local after = self.afterLine
    if after then
        tooltip:AddLine(" ")
        local afterName = after.label or Util.GetItemLabel(after.itemID)
        tooltip:AddLine(L.Format("Then: %s x%d", tostring(afterName), after.postQuantity or 1), grey, grey, grey)
    end
    return true
end

--- How tall the panel can be without running into the main window.
--
-- The auction window's own height, normally. But the auction window, this
-- panel and the main window together are wider than the screen on a lot of
-- setups, so when the main window is parked under this panel the two collide.
-- The panel is the one that gives way: it loses a row or two off the bottom,
-- where the main window would lose its title bar and tab row.
--
-- Returns nil while the frames have no screen coordinates yet, which is what
-- a frame that has never been laid out reports.
--
-- @param left  where the panel's left edge is, when it is not right beside the
--   auction window (it moves over for the character window)
function PostPanel:DesiredHeight(auctionFrame, left)
    local top, bottom, right =
        auctionFrame:GetTop(), auctionFrame:GetBottom(), auctionFrame:GetRight()

    if not top or not bottom or not right then return nil end

    left = left or right + PANEL_GAP

    local window = ns.UI and ns.UI.window

    if window and window:IsShown() then
        local windowTop, windowLeft, windowRight =
            window:GetTop(), window:GetLeft(), window:GetRight()

        -- Read in the window's own units, which a player-sized window does
        -- not share with this panel (/bts size): put into the panel's.
        local scale = type(window.GetScale) == "function" and window:GetScale()
        if type(scale) == "number" and scale > 0 and scale ~= 1
            and windowTop and windowLeft and windowRight then
            windowTop, windowLeft, windowRight =
                windowTop * scale, windowLeft * scale, windowRight * scale
        end

        -- Only when the two really do share screen space. The main window is
        -- movable, so most of the time it is somewhere else entirely.
        if windowTop and windowLeft and windowRight then
            if windowRight > left and windowLeft < left + PANEL_WIDTH
                and windowTop > bottom then
                bottom = windowTop + PANEL_GAP
            end
        end
    end

    return math.max(top - bottom, PANEL_MIN_HEIGHT)
end

--------------------------------------------------------------------------------
-- Making room for the character window
--------------------------------------------------------------------------------

-- With the auction house open, the game puts the character window (and any
-- other window that opens beside it) in the slot to the auction window's
-- right. That is exactly where this panel docks, and the panel sits in a
-- higher strata, so it covered the paper doll completely. Now it moves over
-- to the right of whatever window has opened there, and steps aside if the
-- screen has no room for both.

-- Windows worth checking even if the game's panel slots cannot be read.
local SIDE_FRAME_NAMES = { "CharacterFrame" }

--- A frame edge in the panel's own coordinates (UIParent's), or nil.
--
-- Blizzard shrinks some windows to fit the screen, and an edge read off a
-- scaled frame is in that frame's units, not ours.
local function Edge(frame, method)
    local ok, value = pcall(frame[method], frame)
    if not ok or type(value) ~= "number" then return nil end

    local parent = _G.UIParent
    if frame == parent or type(frame.GetEffectiveScale) ~= "function"
        or type(parent) ~= "table" or type(parent.GetEffectiveScale) ~= "function" then
        return value
    end

    local okFrame, frameScale = pcall(frame.GetEffectiveScale, frame)
    local okParent, parentScale = pcall(parent.GetEffectiveScale, parent)

    if okFrame and okParent and type(frameScale) == "number"
        and type(parentScale) == "number" and parentScale > 0 then
        value = value * frameScale / parentScale
    end

    return value
end

--- How far a window's own buttons stick out past its right edge, in the
-- panel's coordinates.
--
-- A player's screenshot, 2026-10-04: with a custom interface, the Professions
-- window carries a column of buttons hanging off its right side, and the
-- list docked to the window's edge sat on top of them. The craft queue pane
-- already measures the same thing beside the profession window
-- (CraftPanel:RightOverhang), so the same measure is used here.
local function Overhang(frame)
    local panel = ns.CraftPanel
    if type(panel) ~= "table" or type(panel.RightOverhang) ~= "function" then return 0 end

    local ok, overhang = pcall(panel.RightOverhang, panel, frame)
    if not ok or type(overhang) ~= "number" or overhang <= 0 then return 0 end

    -- Measured in the window's own units, which a scaled window does not
    -- share with the panel.
    local parent = _G.UIParent
    if type(frame.GetEffectiveScale) == "function" and type(parent) == "table"
        and type(parent.GetEffectiveScale) == "function" then
        local okFrame, frameScale = pcall(frame.GetEffectiveScale, frame)
        local okParent, parentScale = pcall(parent.GetEffectiveScale, parent)
        if okFrame and okParent and type(frameScale) == "number"
            and type(parentScale) == "number" and parentScale > 0 then
            overhang = overhang * frameScale / parentScale
        end
    end

    return overhang
end

local function IsShownFrame(frame)
    if type(frame) ~= "table" or type(frame.IsShown) ~= "function" then return false end

    local ok, shown = pcall(frame.IsShown, frame)
    return ok and shown == true
end

--- The game window open beside the auction house, if one is in the way.
--
-- Anything in the game's right-hand panel slot counts, not just the character
-- window: the spellbook and the rest land in the same place.
function PostPanel:SideFrame(auctionFrame)
    local candidates = {}

    if type(_G.GetUIPanel) == "function" then
        local ok, frame = pcall(_G.GetUIPanel, "right")
        if ok and frame then candidates[#candidates + 1] = frame end
    end

    for _, name in ipairs(SIDE_FRAME_NAMES) do
        candidates[#candidates + 1] = _G[name]
    end

    local ahRight, ahTop, ahBottom =
        Edge(auctionFrame, "GetRight"), Edge(auctionFrame, "GetTop"), Edge(auctionFrame, "GetBottom")
    if not (ahRight and ahTop and ahBottom) then return nil end

    -- Where the panel would sit, docked beside the auction window.
    local dockLeft, dockRight = ahRight + PANEL_GAP, ahRight + PANEL_GAP + PANEL_WIDTH

    for _, frame in ipairs(candidates) do
        if frame ~= auctionFrame and frame ~= self.frame and IsShownFrame(frame) then
            local left, right = Edge(frame, "GetLeft"), Edge(frame, "GetRight")
            local top, bottom = Edge(frame, "GetTop"), Edge(frame, "GetBottom")

            -- Only a window actually in the panel's spot. One the player has
            -- dragged somewhere else is left to itself.
            if left and right and top and bottom
                and left < dockRight and right > dockLeft
                and bottom < ahTop and top > ahBottom then
                return self:PastOwnPanes(frame, right + Overhang(frame), ahTop, ahBottom)
            end
        end
    end
end

-- Panes of this addon that dock to the right of a game window: the craft
-- queue beside the profession window, and its queued crafts beside that.
local function OwnPanes()
    local panel = ns.CraftPanel
    if type(panel) ~= "table" then return {} end
    return { panel.frame, panel.queuedFrame }
end

--- Past the craft queue panes, when they are docked beside the window found.
--
-- With the auction house and a profession both open, the profession window
-- takes the slot beside the auction window and the craft queue panes dock to
-- its right, which is where this panel went next. A screenshot,
-- 2026-10-01: Ready to sell drawn over the queued crafts and shopping list.
-- @return the frame to dock to, its right edge
function PostPanel:PastOwnPanes(frame, right, ahTop, ahBottom)
    local moved = true
    while moved do
        moved = false
        for _, pane in ipairs(OwnPanes()) do
            if pane ~= frame and IsShownFrame(pane) then
                local left, paneRight = Edge(pane, "GetLeft"), Edge(pane, "GetRight")
                local top, bottom = Edge(pane, "GetTop"), Edge(pane, "GetBottom")

                -- Anywhere in the panel's spot past the edge so far. The
                -- craft pane sits clear of the profession tabs, which stick
                -- out past that window's edge, so it is not right beside it.
                if left and paneRight and top and bottom
                    and left < right + PANEL_GAP + PANEL_WIDTH and paneRight > right
                    and bottom < ahTop and top > ahBottom then
                    frame, right, moved = pane, paneRight, true
                end
            end
        end
    end
    return frame, right
end

--- Where the panel should be right now.
--
-- @return the frame to dock to, the panel's left edge (nil for "beside the
--   auction window"), and false when there is no room for it at all
function PostPanel:Placement(auctionFrame)
    local side, sideRight = self:SideFrame(auctionFrame)
    if not side then return auctionFrame, nil, true end

    local left = sideRight + PANEL_GAP
    local screenRight = _G.UIParent and Edge(_G.UIParent, "GetRight")
    local fits = not screenRight or left + PANEL_WIDTH <= screenRight

    return side, left, fits
end

--- Put the panel where Placement says, showing or hiding it to match.
--
-- Cheap enough for the one-second auction house ticker, which is what brings
-- the panel back after the character window closes if no event does.
function PostPanel:Redock()
    local frame = self.frame
    if not (frame and self.attached) or self.inside then return end

    -- Put away with the close gem: it stays away until the next visit.
    if self.closedThisVisit then return end

    local auctionFrame = ns.UI:FindAuctionFrame()
    if not auctionFrame then return end

    local host, left, fits = self:Placement(auctionFrame)

    if not fits then
        -- No room beside the character window. Out of the way until it
        -- closes: the paper doll is what the player just asked to see.
        self.dockedTo = nil
        if frame:IsShown() then frame:Hide() end
        return
    end

    self.dockedLeft = left

    -- Past the window's edge by the gap, and by whatever of its own sticks
    -- out there (Overhang).
    local offset = PANEL_GAP
    local hostRight = left and Edge(host, "GetRight")
    if hostRight then offset = math.max(PANEL_GAP, left - hostRight) end

    if self.dockedTo ~= host or math.abs((self.dockedOffset or PANEL_GAP) - offset) > 0.5 then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", host, "TOPRIGHT", offset, 0)
        self.dockedTo, self.dockedOffset = host, offset

        -- Beside a different window, the main window may be in the way now,
        -- or no longer.
        self:ApplyHeight(true)
    end

    if not frame:IsShown() then
        frame:Show()
        self:ApplyHeight(true)
        self:Refresh()
        -- Fades in where it docked; it never rises, since it sits beside
        -- another window.
        if ns.Motion then ns.Motion:Open(frame, 0) end
    end
end

--- Redock as soon as the game has placed a window, rather than on the next
-- tick of the ticker. Hooked once; hooksecurefunc and HookScript leave the
-- game's own code untouched.
function PostPanel:WatchSideFrames()
    if self.watching then return end
    self.watching = true

    local function Soon()
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function() PostPanel:Redock() end)
        end
    end

    if type(_G.hooksecurefunc) == "function" then
        for _, name in ipairs({ "ShowUIPanel", "HideUIPanel" }) do
            if type(_G[name]) == "function" then pcall(_G.hooksecurefunc, name, Soon) end
        end
    end

    for _, name in ipairs(SIDE_FRAME_NAMES) do
        local frame = _G[name]
        if type(frame) == "table" and type(frame.HookScript) == "function" then
            pcall(frame.HookScript, frame, "OnShow", Soon)
            pcall(frame.HookScript, frame, "OnHide", Soon)
        end
    end
end

--- Dock to the right of the auction house, as tall as there is room for.
function PostPanel:Attach()
    local frame = self:Build()
    -- In the window's Auction House tab: it stays there.
    if self.inside then
        self.attached = true
        self:PlaceBar()
        self:Refresh()
        return
    end
    local auctionFrame = ns.UI:FindAuctionFrame()

    frame:ClearAllPoints()
    self.dockedTo, self.dockedLeft = nil, nil

    if auctionFrame then
        -- One anchor and a measured height, rather than a point on the auction
        -- window's top and another on its bottom. Two points would keep the
        -- height in step on their own, but they would also pin the bottom to
        -- the auction window, and the bottom is exactly what has to move out
        -- of the main window's way.
        --
        -- (The pair to avoid is TOPLEFT with BOTTOM, which is what this used to
        -- be: a BOTTOM point fixes the horizontal centre too, which TOPLEFT has
        -- already decided, so the client drops one of the two and the panel
        -- keeps whatever height it had. That is how it ended up half as tall as
        -- the window it was docked to.)
        frame:SetPoint("TOPLEFT", auctionFrame, "TOPRIGHT", PANEL_GAP, 0)
        self.dockedTo, self.dockedOffset = auctionFrame, PANEL_GAP
    else
        -- The auction house window is load-on-demand and may not exist yet.
        frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 40, -120)
    end

    self.attached = true
    self:WatchSideFrames()
    self:PlaceBar()

    if self.closedThisVisit then
        frame:Hide()
        return
    end

    self:ApplyHeight(true)

    local opening = not frame:IsShown()
    frame:Show()
    self:Redock()
    self:Refresh()

    if opening and ns.Motion then ns.Motion:Open(frame, 0) end
end

--- The height to be right now: the title strip when collapsed, otherwise as
-- tall as there is room for.
--
-- @param fallback  use the fallback height when nothing can be measured,
--   rather than leaving the height alone
-- @return nil when there is nothing to go on
function PostPanel:TargetHeight(fallback)
    local auctionFrame = ns.UI:FindAuctionFrame()
    local full = auctionFrame and self:DesiredHeight(auctionFrame, self.dockedLeft)

    if not full and fallback then full = PANEL_FALLBACK_HEIGHT end
    if not full then return nil end

    if self:IsCollapsed() then return PostPanel.FOLDED_HEIGHT end
    return full
end

function PostPanel:IsCollapsed()
    if self.inside then return false end
    return ns.Collapse.IsCollapsed(COLLAPSE_KEY)
end

--- Set the height outright, after attaching or folding.
function PostPanel:ApplyHeight(fallback)
    if not self.frame or self.inside then return end

    local height = self:TargetHeight(fallback ~= false)
    if height then self.frame:SetHeight(height) end
end

--- Re-measure after the main window is opened, closed or dragged.
function PostPanel:Reflow()
    if not self.frame or not self.frame:IsShown() or self.inside then return end

    local height = self:TargetHeight(false)

    -- Only when it actually moved. This runs on the auction house ticker, and
    -- setting the height every second would relayout the list for nothing.
    if height and math.abs(height - self.frame:GetHeight()) > 0.5 then
        self.frame:SetHeight(height)
    end
end

--------------------------------------------------------------------------------
-- Buy: the craft queue's shopping list
--------------------------------------------------------------------------------

PostPanel.view = "sell"

--- Is Hide losses ticked? Off until the player ticks it.
function PostPanel:HidingLosses()
    return ns.Config ~= nil and ns.Config:Get("postHideLosses") == true
end

--- The lines left once those at a loss are taken out, and how many went.
function PostPanel.WithoutLosses(lines)
    local kept, hidden = {}, 0
    for _, line in ipairs(lines) do
        if line.atALoss then
            hidden = hidden + 1
        else
            kept[#kept + 1] = line
        end
    end
    return kept, hidden
end

--- Switch between the sell list and the shopping list.
function PostPanel:SetView(view)
    if view == "favors" and not PostPanel.ShowsFavors() then view = "sell" end
    self.view = (view == "buy" or view == "lists" or view == "auctions" or view == "favors") and view or "sell"
    self.searchStep = nil
    if self.switch then self.switch:Select(self.view, true) end
    self.shoppingAt = nil
    self:Refresh()
end

--- A row worth searching the auction house for: still short, and not a
--- vendor material, which is a mistake to buy there. A vendor with limited
--- stock is the exception (Healing Potion, 2026-10-14): it may run out
--- before the queue has enough, so the auction house stays on offer.
function PostPanel:CanSearch(line)
    return type(line) == "table" and (line.shortfall or 0) > 0
        and (not line.fromVendor or line.vendorLimited == true)
end

--- The items Search all looks up: every line CanSearch passes, in list
--- order, with how many each is short of.
-- @return { itemID, ... }, { [itemID] = shortfall }
function PostPanel.SearchableIDs(lines)
    local ids, counts = {}, {}
    for _, line in ipairs(lines or {}) do
        if PostPanel:CanSearch(line) and type(line.itemID) == "number" and not counts[line.itemID] then
            ids[#ids + 1] = line.itemID
            counts[line.itemID] = line.shortfall
        end
    end
    return ids, counts
end

-- Search all, one at a time on a client that takes one item a search:
-- { ids, counts, pos }, the button reading "Next 2/5" until the last.
PostPanel.searchStep = nil

--- Search the auction house for everything on the Buy list it sells: all at
--- once where the game allows it (ShoppingLists:SearchMany, with each
--- count, so picking one fills the buy box), else one a click.
function PostPanel:SearchAll()
    -- Era (a player found it went round and round, 2026-10-31): open the buy
    -- plan on the first item still to buy, the way a row's Search does. The
    -- plan's own button buys a stack a click, then reads "Next: NAME".
    local View = ns.LegacyBuyView
    if View and View.Applies and View:Applies() then
        self.searchStep = nil
        local ids, counts = PostPanel.SearchableIDs(self:ShoppingLines())
        if #ids == 0 then
            ns.Print(L["Nothing on this list to look for on the auction house."])
        elseif self:OpenBuyPlan(ids[1], counts[ids[1]]) then
            return
        end
        self:UpdateSearchAll()
        return
    end

    local step = self.searchStep
    if step and step.pos <= #step.ids then
        local id = step.ids[step.pos]
        if ns.UI:SearchAuctionHouse(id, step.counts[id]) then step.pos = step.pos + 1 end
        if step.pos > #step.ids then self.searchStep = nil end
        self:UpdateSearchAll()
        return
    end
    self.searchStep = nil

    local ids, counts = PostPanel.SearchableIDs(self:ShoppingLines())
    if #ids == 0 then
        ns.Print(L["Nothing on this list to look for on the auction house."])
        return
    end

    local lists = ns.ShoppingLists
    local ok, why = false, "single"
    if #ids > 1 and lists and lists.SearchMany then ok, why = lists:SearchMany(ids, counts) end
    if not ok and why == "single" then
        if ns.UI:SearchAuctionHouse(ids[1], counts[ids[1]]) and #ids > 1 then
            self.searchStep = { ids = ids, counts = counts, pos = 2 }
        end
    elseif not ok and why then
        ns.Print(why)
    end
    self:UpdateSearchAll()
end

--- Search all's words and state: "Next 2/5" mid-way, greyed with nothing to
--- look for.
function PostPanel:UpdateSearchAll(lines)
    local button = self.searchAll
    if not button then return end
    local step = self.searchStep
    local label
    if step and step.pos <= #step.ids then
        label = L.Format("Next %d/%d", step.pos, #step.ids)
        button:SetEnabledState(true)
    else
        local ids = PostPanel.SearchableIDs(lines or self:ShoppingLines())
        label = #ids > 0 and L.Format("Search all %d", #ids) or L["Search all"]
        button:SetEnabledState(#ids > 0)
    end
    button:SetText(label)
    local width = Theme.MeasureText and Theme.MeasureText("small", label)
    button:SetWidth(math.max(110, (width or 0) + 24))
    button.tooltipText = PostPanel.SearchTip(L["Searches the auction house for everything on this list. Pick one and how many you need fills in."])
end

-- Clicking the row searched already, but nothing said so. Asked for: "a button
-- would be clearer to a new user". The same size as the sell list's List.
local SEARCH_WIDTH = BUTTON_WIDTH

--- The craft pane's shopping row, with a Search button at its right end and
--- the counts moved over to make room for it.
function PostPanel.CreateShoppingRow(row)
    ns.CraftPanel.CreateShoppingRow(row)

    row.search = Widgets.CreateButton(row, L["Search"], function()
        PostPanel:OpenShoppingLine(row.data)
    end, { width = SEARCH_WIDTH, height = 18, primary = true, tooltip = PostPanel.SearchTip(L["Searches the auction house. Pick it and how many you need fills in."]) })
    row.search:SetPoint("RIGHT", row, "RIGHT", -8, 0)

    local inset = -(8 + SEARCH_WIDTH + 6)
    row.count:SetPoint("TOPRIGHT", row, "TOPRIGHT", inset, -4)
    row.tagRight = inset
    row.tag:SetPoint("TOPRIGHT", row, "TOPRIGHT", inset, -15)
end

function PostPanel.UpdateShoppingRow(row, line)
    ns.CraftPanel.UpdateShoppingRow(row, line)
    row.search:SetShown(PostPanel:CanSearch(line))
end

--- The Queue tab's tooltip, and what a click does.
function PostPanel.ShowShoppingTooltip(row, line)
    if ns.UI and ns.UI.ShowMaterialTooltip then ns.UI.ShowMaterialTooltip(row, line) end
    if PostPanel:CanSearch(line) then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["Click to search the auction house"], 0.78, 0.64, 0.30)
        GameTooltip:Show()
    end
end

--- The shopping list, at most once every couple of seconds.
function PostPanel:ShoppingLines()
    local now = GetTime()
    if not self.shoppingLines or not self.shoppingAt
        or now - self.shoppingAt >= SHOPPING_REFRESH_SECONDS then
        self.shoppingLines = ns.Queue:GetShoppingList()
        self.shoppingAt = now
    end
    return self.shoppingLines
end

--- What the Buy view's summary line says.
-- @return text, and how many lines are still short
function PostPanel:ShoppingSummary(lines)
    local short = 0
    for _, line in ipairs(lines) do
        if (line.shortfall or 0) > 0 then short = short + 1 end
    end

    if short == 0 then
        return L["You have everything the queue needs."], 0
    end

    -- From the lines in hand. Asked for on its own, the total built the whole
    -- list again on every one-second tick, which the cache above is there
    -- to stop.
    local cost = ns.Queue:GetShoppingTotal(lines)
    local about = Util.FormatMoney(cost or 0, { short = true })
    return short == 1 and L.Format("%d material to buy, about %s", short, about)
        or L.Format("%d materials to buy, about %s", short, about), short
end

function PostPanel:RefreshShopping()
    self.list:Hide()
    self.shoppingList:Show()

    local lines = self:ShoppingLines()
    local text, short = self:ShoppingSummary(lines)

    self.title:SetText(self:IsCollapsed() and short > 0
        and L.Format("Shopping list (%d)", short) or L["Shopping list"])

    self.shoppingList:SetData(lines)
    self.empty:SetShown(#lines == 0)

    if #lines == 0 then
        self.empty:SetText(ns.Queue:Count() == 0
            and L["Nothing queued.\n\nQueue crafts and the materials they need show up here."]
            or L["You already have everything the queue needs."])
        self:SetSummary("")
        return
    end

    self:SetSummary(text)
end

--- The summary line under the tabs. Never shorter than the tick boxes at
--- its right (a player's report, 2026-10-22): with no words in it the line
--- under it rose through Overcutting and Hide losses.
function PostPanel:SetSummary(text)
    local summary = self.summary
    if not summary then return end
    summary:SetText(text or "")
    if not summary.SetHeight then return end
    local box = self.hideLosses
    local least = (box and box.GetHeight and box:GetHeight()) or 0
    if not least or least <= 0 then least = PostPanel.SUMMARY_LEAST end
    local tall = (text and text ~= "" and summary.GetStringHeight and summary:GetStringHeight()) or 0
    summary:SetHeight(math.max(least, tall or 0))
end

--- Back in place, and laid out against the main window, without rebuilding
--- the list: what the one-second ticker does when nothing on it changed.
function PostPanel:Place()
    self:Redock()
    if self.frame and self.frame:IsShown() then self:Reflow() end
end

function PostPanel:Refresh()
    -- Before the shown check: this is how a panel that stepped aside for the
    -- character window comes back.
    self:Redock()

    if not self.frame or not self.frame:IsShown() then return end

    -- The Potential Sale Total counter sits in the header, left of Scan
    -- (UI/SaleTotal.lua), folded or not, while it is on.
    local banding = ns.SaleTotal ~= nil and ns.SaleTotal:SetShown(true) or false

    -- Cheap, and it catches the main window being dragged, which has no event.
    self:Reflow()

    if self.searched then self:PlaceSearched(ns.SearchedPrice:Update()) end

    if self.hideLosses then
        local showBox = self.view == "sell"
        self.hideLosses:SetShown(showBox)
        if self.overcutBox then
            self.overcutBox:SetShown(showBox)
            self.overcutBox:SetChecked(ns.Config:Get("overcutting") == true)
        end
        -- What sits at the summary line's right end: Hide losses on Sell,
        -- Paste a list on Lists, nothing on Buy, where the summary has the
        -- whole width rather than wrapping beside an empty space.
        local beside = showBox and "box" or self.view == "lists" and "paste" or "none"
        if self.summaryBeside ~= beside then
            if self.summary and self.frame then
                local View = ns.ShoppingListsView
                self.summary:ClearAllPoints()
                self.summary:SetPoint("TOPLEFT", self.switch, "BOTTOMLEFT", 0, -6)
                if beside == "box" then
                    self.summary:SetPoint("RIGHT", self.overcutBox or self.hideLosses, "LEFT", -8, 0)
                elseif beside == "paste" and View and View.paste then
                    self.summary:SetPoint("RIGHT", View.paste, "LEFT", -8, 0)
                else
                    self.summary:SetPoint("RIGHT", self.frame, "RIGHT", -14, 0)
                end
            end
            self.summaryBeside = beside
        end
    end

    if self.duration then
        local selling = self.view == "sell"
        self.duration:SetShown(selling)
        if selling then self.duration:SetValue(ns.Config:Get("postDuration") or 2) end
        -- On Buy the box is gone, so the note starts at the edge.
        if self.footNote and self.noteBeside ~= selling then
            self.footNote:ClearAllPoints()
            if selling then
                self.footNote:SetPoint("LEFT", self.duration, "RIGHT", 8, 0)
            else
                self.footNote:SetPoint("LEFT", self.frame, "BOTTOMLEFT", EDGE_PAD + 8, EDGE_PAD + FOOT_HEIGHT / 2)
            end
            self.footNote:SetPoint("RIGHT", (selling or not self.searchAll) and self.listAll or self.searchAll, "LEFT", -8, 0)
            self.noteBeside = selling
        end
    end

    if self.searchAll then self.searchAll:SetShown(self.view == "buy") end

    self:UpdateAuctionsTab()
    if self:LayTabs() and self.view == "favors" and not PostPanel.ShowsFavors() then
        self.view = "sell"
        if self.switch then self.switch:Select(self.view, true) end
    end
    local View = ns.ShoppingListsView
    if View and View.list then View:SetShown(self.view == "lists") end
    local Auctions = ns.AuctionsView
    if Auctions and Auctions.list then Auctions:SetShown(self.view == "auctions") end
    local Favors = ns.FavorsView
    if Favors and Favors.list and (Favors.shown or false) ~= (self.view == "favors") then
        Favors:SetShown(self.view == "favors")
    end
    if self.footNote then
        self.footNote:SetShown(self.view ~= "lists" and self.view ~= "auctions" and self.view ~= "favors")
    end

    -- Era's buy plan shows on Buy only.
    if self.view ~= "buy" then self:PlaceBuyPlan() end

    if self.view == "favors" then
        if self.listAll then self.listAll:Hide() end
        self.list:Hide()
        self.shoppingList:Hide()
        self.empty:Hide()
        if Favors then
            Favors:Refresh()
            self:SetSummary(Favors:Summary())
            self:SetTitle(Favors:Title())
        end
        return
    end

    if self.view == "auctions" then
        if self.listAll then self.listAll:Hide() end
        self.list:Hide()
        self.shoppingList:Hide()
        self.empty:Hide()
        if Auctions then
            Auctions:Refresh()
            self:SetSummary(Auctions:Summary())
            self:SetTitle(Auctions:Title())
        end
        return
    end

    if self.view == "lists" then
        if self.listAll then self.listAll:Hide() end
        self.list:Hide()
        self.shoppingList:Hide()
        self.empty:Hide()
        self:SetTitle(L["Shopping lists"])
        if View then
            self:SetSummary(View:Summary())
            View:Refresh()
        end
        return
    end

    if self.view == "buy" then
        if self.listAll then self.listAll:Hide() end
        if self.footNote then self.footNote:SetText(L["Click a row to search the auction house for it."]) end
        self:RefreshShopping()
        self:UpdateSearchAll()
        self:PlaceBuyPlan()
        return
    end

    self.shoppingList:Hide()
    self.list:Show()
    if self.listAll then self.listAll:Show() end
    if self.footNote then self.footNote:SetText(L["Lists at your price or the market's."]) end

    if TypingInList(self.list) then return end

    local lines, hidden, toVendor = self:ShownLines()
    self.shownLines = lines
    self:UpdateListAll(lines)

    self.list:SetData(lines)
    self.empty:SetShown(#lines == 0)

    if #lines == 0 then
        self.empty:SetText(hidden == 0 and toVendor > 0
            and (toVendor == 1
                and L.Format("A vendor pays more for everything here (%d item).\n\nSell it at a vendor.", toVendor)
                or L.Format("A vendor pays more for everything here (%d items).\n\nSell them at a vendor.", toVendor))
            or hidden > 0
            and (hidden == 1
                and L.Format("Everything here would sell at a loss (%d item).\n\nUntick Hide losses to see them.", hidden)
                or L.Format("Everything here would sell at a loss (%d items).\n\nUntick Hide losses to see them.", hidden))
            or L["Nothing in your bags with a known price.\n\nScan the auction house to find out what things sell for."])
        self:SetSummary("")
        self:SetTitle(L["Ready to sell"])
        if banding then ns.SaleTotal:Update(lines, 0) end
        return
    end

    local total, losses, keptBack = 0, 0, 0
    for _, line in ipairs(lines) do
        if line.held then
            keptBack = keptBack + 1
        else
            total = total + (line.postTotal or 0)
            if line.atALoss then losses = losses + 1 end
        end
    end

    -- What it would all fetch, in gold beside the title, so it is still
    -- there to see with the drawer folded away; folded, the count too.
    local worth = ("|c%s%s|r"):format(ns.COLORS.accent,
        Util.FormatMoney(total, { noColor = true, short = true }))
    -- With the Potential Sale Total counter on, the header has the numbers, so the
    -- title and the summary leave the worth out, folded or not.
    if banding then
        self:SetTitle(self:IsCollapsed() and L.Format("Ready to sell (%d)", #lines) or L["Ready to sell"])
    elseif self:IsCollapsed() then
        self:SetTitle(L.Format("Ready to sell (%d) · %s", #lines, worth),
            L.Format("Ready to sell (%d)", #lines))
    else
        self:SetTitle(L.Format("Ready to sell · %s", worth), L["Ready to sell"])
    end
    if banding then ns.SaleTotal:Update(lines, keptBack) end

    local about = ("|c%s%s|r"):format(ns.COLORS.accent,
        Util.FormatMoney(total, { noColor = true, short = true }))
    local count
    if banding then
        count = #lines == 1 and L.Format("%d item", #lines) or L.Format("%d items", #lines)
    else
        count = #lines == 1 and L.Format("%d item, about %s", #lines, about)
            or L.Format("%d items, about %s", #lines, about)
    end
    self:SetSummary(count
        .. (hidden > 0 and ("  ·  " .. L.Format("%d hidden", hidden))
            or losses > 0 and ("  ·  |c%s%s|r"):format(ns.COLORS.loss, L.Format("%d at a loss", losses)) or "")
        .. (keptBack > 0 and ("  ·  " .. L.Format("%d kept for your other addons", keptBack)) or "")
        .. (toVendor > 0 and ("  ·  " .. L.Format("%d for the vendor", toVendor)) or ""))
end

--- The Favors switch shows only while a favor goal is set.
function PostPanel.ShowsFavors()
    local MerchantsFavor = ns.MerchantsFavor
    return MerchantsFavor ~= nil and ns.FavorsView ~= nil and MerchantsFavor.Goal() ~= nil
end

--- Lay the switch's tabs side by side, sharing the drawer's width, with
--- Favors only while a goal is set. Laid out again only when that changes.
-- @return true when the tabs moved
function PostPanel:LayTabs(force)
    local switch = self.switch
    if not (switch and switch.tabs) then return false end
    local withFavors = PostPanel.ShowsFavors()
    if not force and withFavors == self.tabsWithFavors then return false end
    self.tabsWithFavors = withFavors

    switch:SetTabShown("favors", withFavors)
    if switch.selected then switch:Select(switch.selected, true) end
    return true
end

--- The Auctions switch says how many of yours are undercut, in red, so it
--- shows from Sell and Buy too. Set only when the count moves.
function PostPanel:UpdateAuctionsTab()
    local Auctions = ns.AuctionsView
    if not (self.switch and self.switch.tabs and Auctions and Auctions.UndercutCount) then return end
    local count = Auctions:UndercutCount()
    if count == self.undercutShown then return end
    self.undercutShown = count
    self.switch:SetTabText("auctions", count > 0
        and ("%s |c%s%d|r"):format(L["Auctions"], ns.COLORS.loss or "ffe5604f", count)
        or L["Auctions"])
end

--- The header's title, the first wording that fits beside the buttons.
function PostPanel:SetTitle(...)
    local title = self.title
    if not title then return end
    if Theme.FitText then Theme.FitText(title, { ... }) else title:SetText((...)) end
end

--- Put the current wait on every visible List button.
--
-- The bar's Post Crafted is not the only way to list something, and a row
-- button that did nothing for three seconds looked exactly as broken there as
-- it did on the bar. Every row shows the same number because the wait is the
-- auction house's, not the row's.
--
-- Labels only: called four times a second, so it must not rebuild the list or
-- touch anything that walks the bags.
function PostPanel:UpdateWaitLabels(seconds, reason)
    if not self.list or not self.list.rows then return end
    if not self.frame or not self.frame:IsShown() then return end

    local Apply = ns.UI and ns.UI.ApplyWaitLabel
    if not Apply then return end

    -- Era: while a listing goes in, the List buttons are grey and take no
    -- press, keeping their labels; the hover says why.
    local Posting = ns.Posting
    local settling = Posting and Posting.Settling ~= nil and Posting:Settling() or false
    local checking = Posting and Posting.CheckingAll ~= nil and Posting:CheckingAll() or false
    local SETTLE_WHY = L["your listing is going through"]

    -- List all waits with the rest, back to its count once the wait is over.
    if self.listAll and self.listAll:IsShown() and (self.listAllCount or 0) > 0 then
        self:RefreshListAllLabel()
        local button = self.listAll
        local label = self.listAllLabel or L["List Next"]
        if settling then
            PostPanel.SettleLabel(button, label, SETTLE_WHY)
        else
            Apply(button, label, (not checking) and seconds or 0, (not checking) and reason or nil)
        end
        PostPanel.Grey(button, settling or checking)
        self:RefreshListAllTip()
    end

    for i = 1, #self.list.rows do
        local row = self.list.rows[i]

        -- A row with no price is disabled on its own account, and leaving it
        -- alone keeps that reason visible rather than replacing it with a
        -- countdown it is not really serving.
        if row and row.post and row.post.greyed and not (row.data and settling) then
            PostPanel.Grey(row.post, false, row.data ~= nil and row.data.unitPrice ~= nil)
        end
        if row and row.data and row.post and settling and (row.post.greyed or not row.post.disabled) then
            PostPanel.SettleLabel(row.post, L["List"], SETTLE_WHY)
            PostPanel.Grey(row.post, true)
        elseif row and row.data and row.post and not row.post.disabled then
            -- Another copy of the item being confirmed does not wait for it.
            local pending = ns.Posting and ns.Posting.pending
            if pending and pending.itemID == row.data.itemID then
                Apply(row.post, L["List"], ns.Posting:SecondsUntilPostable(row.data.itemID))
            else
                Apply(row.post, L["List"], seconds, reason)
            end
        end
    end
end

--- A List button keeps its own label while a listing goes in, and its
--- hover says why it waits.
function PostPanel.SettleLabel(button, label, why)
    if button.waitTip ~= why or rawget(button, "settleLabel") ~= label then
        button:SetText(label)
        button.settleLabel = label
    end
    button.waitingLabel = true
    button.waitTip = why
end

--- Grey a List button while a listing goes in, or bring it back. Only the
--- buttons this greyed come back; one grey for its own reason stays so.
-- @param back for a button coming back: whether it may be pressed again
function PostPanel.Grey(button, on, back)
    if on then
        if not button.disabled then
            button.greyed = true
            button:SetEnabledState(false)
        end
    elseif button.greyed then
        button.greyed = nil
        if back ~= false then button:SetEnabledState(true) end
    end
end

function PostPanel:Hide()
    -- The auction house closed: nothing should bring the panel back now.
    self.attached = false
    self.closedThisVisit = false
    self.dockedTo, self.dockedLeft = nil, nil

    if self.frame then self.frame:Hide() end

    -- A price being set for a listing goes with it: nothing can be listed
    -- away from the auction house.
    if ns.PriceEditor and ns.PriceEditor.IsShown and ns.PriceEditor:IsShown() then ns.PriceEditor:Hide() end
end

function PostPanel:IsShown()
    return self.frame ~= nil and self.frame:IsShown()
end
