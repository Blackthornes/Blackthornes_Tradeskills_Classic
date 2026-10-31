-- Blackthornes Tradeskills -- UI/BankView.lua
-- The Characters tab's Bank view: every character's bank in one list.
--
-- The list is by item, so one search answers "who has my Silk Cloth". The pane
-- on the right shows each bank at a glance until an item is picked, then who
-- holds that item and how many. Counts are snapshots from each character's
-- last bank visit, and the pane says how old each one is.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local BankView = {}
ns.BankView = BankView

local ROW_HEIGHT = 24
-- A character's name on the detail pane: its own size, then smaller ones.
local NAME_SIZES = { "normal", "small", "tiny" }
local DETAIL_WIDTH = 300
-- Seven fit the panel now that it starts below the option bar, as on
-- every tab; "and N more" covers the rest.
local DETAIL_LINES = 7
local ALL = "all"

-- Right to left. WORTH sits to the right, so its coins line up; the rest is
-- centred under its heading. `width` is the least each gets:
-- Widgets.FitColumns widens it to fit the heading and a full amount.
local COLUMNS = {
    { key = "worth", label = L["WORTH"], width = 96, money = true },
    { key = "have",  label = L["HAVE"],  width = 52, justify = "CENTER" },
    { key = "who",   label = L["WHO"],   width = 150, justify = "CENTER" },
}

-- Any column but the name can be hidden (UI/Columns.lua).
ns.Columns:Register("banks", L["Characters: Banks"], COLUMNS)

local state = {
    search = "",
    character = ALL,
    sortBy = "worth",
    bags = false,
    selected = nil,
}

local widgets = {}
local names = {}
local current = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function Money(copper)
    if not copper then return Util.FormatMoney(nil) end
    return Util.FormatMoney(copper, { short = true })
end

--- "bank 40  ·  bags 4", leaving out a side that holds none.
local function WhereText(bank, bags)
    local parts = {}
    if bank > 0 then parts[#parts + 1] = L.Format("bank %s", Util.Comma(bank)) end
    if bags > 0 then parts[#parts + 1] = L.Format("bags %s", Util.Comma(bags)) end
    return table.concat(parts, "  ·  ")
end

local function NameColor(key)
    return key == current.key and "accent" or "text"
end

-- The running count's frame and the value on the label right now.
local counter = { driver = nil, shown = 0 }

--- The gold total runs up to its new value rather than jumping to it.
local function CountTo(label, prefix, to)
    local driver = counter.driver
    if not driver then
        driver = CreateFrame("Frame", nil, label:GetParent())
        counter.driver = driver
    end

    -- A count still running stops where it is, and the new one starts from
    -- there. Left running, it finished on the old total after the new one
    -- was drawn: type a letter in the search and take it out again, and the
    -- footer kept the filtered total under the whole list.
    driver:SetScript("OnUpdate", nil)

    local from = counter.shown
    if from == to then
        label:SetText(prefix .. Money(to))
        return
    end

    local elapsed, duration = 0, 0.6
    driver:SetScript("OnUpdate", function(self, delta)
        elapsed = elapsed + (delta or 0)
        local p = math.min(1, elapsed / duration)
        local eased = 1 - (1 - p) * (1 - p)
        counter.shown = p >= 1 and to or math.floor(from + (to - from) * eased)
        label:SetText(prefix .. Money(counter.shown))
        if p >= 1 then self:SetScript("OnUpdate", nil) end
    end)
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

--- The shown columns from the right edge; the name has the rest.
local function PlaceRow(row)
    local offset = ns.Columns:Place("banks", COLUMNS, row.cells, { gap = 8 })
    row.name:SetPoint("RIGHT", row, "RIGHT", offset - 8, 0)
    row.columnsVersion = ns.Columns.version
end

local function CreateRow(row)
    row.icon = Theme.CreateItemIcon(row, 18)
    row.icon:SetPoint("LEFT", 8, 0)

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("LEFT", 32, 0)
    row.name:SetWordWrap(false)

    row.cells = {}
    for _, column in ipairs(COLUMNS) do
        local cell = Theme.CreateLabel(row, "small", "muted", column.justify or "RIGHT")
        cell:SetWordWrap(false)
        row.cells[column.key] = cell
    end

    PlaceRow(row)
end

local function UpdateRow(row, entry)
    if row.columnsVersion ~= ns.Columns.version then PlaceRow(row) end
    Theme.SetItemIcon(row.icon, entry.itemID)
    Theme.SetRowName(row.name, Util.GetItemLabel(entry.itemID))
    Theme.SetItemNameColor(row.name, entry.itemID)

    row.cells.worth:SetText(Money(entry.worth))
    row.cells.have:SetText(Util.Comma(entry.total))
    row.cells.have:SetTextColor(Theme.Unpack("text"))

    local who
    if #entry.holders == 1 then
        who = names[entry.holders[1].key] or "?"
    else
        who = L.Format("%d characters", #entry.holders)
    end
    row.cells.who:SetText(who)
end

local function ShowRowTooltip(row, entry)
    Widgets.ShowItemTooltip(row, "ANCHOR_RIGHT", entry.itemID, entry.name)

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["Held by"], Theme.Unpack("accent"))

    for _, holder in ipairs(entry.holders) do
        local r, g, b = Theme.Unpack(NameColor(holder.key))
        GameTooltip:AddDoubleLine(names[holder.key] or "?", WhereText(holder.bank, holder.bags),
            r, g, b, 1, 1, 1)
    end

    GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- Detail pane
--------------------------------------------------------------------------------

local function BuildDetail(parent)
    local detail = Theme.CreatePanel(parent, "window")
    Theme.AccentStripe(detail, 2, 0.6)
    detail:SetWidth(DETAIL_WIDTH)

    detail.icon = Theme.CreateItemIcon(detail, 32)
    detail.icon:SetPoint("TOPLEFT", 12, -12)
    if Widgets.ItemHotspot then Widgets.ItemHotspot(detail.icon) end

    detail.title = Theme.CreateLabel(detail, "large", "accent")
    detail.title:SetPoint("TOPLEFT", 12, -12)
    detail.title:SetPoint("TOPRIGHT", -12, -12)
    detail.title:SetWordWrap(false)

    detail.subtitle = Theme.CreateLabel(detail, "small", "muted")
    detail.subtitle:SetPoint("TOPLEFT", detail.title, "BOTTOMLEFT", 0, -4)
    detail.subtitle:SetPoint("TOPRIGHT", detail.title, "BOTTOMRIGHT", 0, -4)

    detail.heading = Theme.CreateHeading(detail, "")
    detail.heading:SetPoint("TOPLEFT", 12, -64)

    detail.lines = {}
    for index = 1, DETAIL_LINES do
        local line = CreateFrame("Frame", nil, detail)
        line:SetHeight(34)
        line:SetPoint("TOPLEFT", 12, -78 - (index - 1) * 36)
        line:SetPoint("TOPRIGHT", -12, -78 - (index - 1) * 36)

        line.name = Theme.CreateLabel(line, "normal", "text")
        line.name:SetPoint("TOPLEFT", 0, -2)
        line.name:SetPoint("TOPRIGHT", -110, -2)

        line.value = Theme.CreateLabel(line, "normal", "text", "RIGHT")
        line.value:SetPoint("TOPRIGHT", 0, -2)
        line.value:SetWidth(106)

        line.sub = Theme.CreateLabel(line, "tiny", "dim")
        line.sub:SetPoint("TOPLEFT", 0, -18)
        line.sub:SetPoint("TOPRIGHT", 0, -18)

        line.bar = Theme.CreateBar(line, DETAIL_WIDTH - 24, 2)
        line.bar:SetPoint("BOTTOMLEFT", line, "BOTTOMLEFT", 0, 0)

        line:Hide()
        detail.lines[index] = line
    end

    detail.more = Theme.CreateLabel(detail, "tiny", "dim")
    detail.more:SetPoint("TOPLEFT", 12, -78 - DETAIL_LINES * 36)

    detail.note = Theme.CreateLabel(detail, "tiny", "dim")
    detail.note:SetPoint("BOTTOMLEFT", 12, 12)
    detail.note:SetPoint("BOTTOMRIGHT", -12, 12)
    detail.note:SetWordWrap(true)

    return detail
end

local function HideLines(detail)
    for _, line in ipairs(detail.lines) do line:Hide() end
    detail.more:SetText("")
end

-- Across the pane inside its padding, for the title and the line under it;
-- less the icon beside them once an item is picked.
local TITLE_ROOM = DETAIL_WIDTH - 24
local ITEM_TITLE_ROOM = TITLE_ROOM - 32 - 8

--- Whether a label's text fits `room` pixels across. One that cannot be
--- measured is taken to fit.
local function Fits(label, room)
    local ok, width = pcall(label.GetStringWidth, label)
    return not ok or type(width) ~= "number" or width <= room
end

--- The pane's title in the room it has: its own size, then a size smaller,
--- then two lines, so a long item name is never cut off.
local function SetTitle(label, text, room)
    label:SetWordWrap(false)
    pcall(label.SetFont, label, Theme.FONT, Theme.sizes.large, "")
    label:SetText(text)
    if Fits(label, room) then return end

    pcall(label.SetFont, label, Theme.FONT, Theme.sizes.normal, "")
    if Fits(label, room) then return end

    label:SetWordWrap(true)
end

--- "40 held  ·  12g 34s 56c  ·  30s each", with the amounts in fewer coins,
--- rounded, until the line fits. Measured, so it never ends in "...".
local function SetItemSubtitle(label, entry, room)
    for _, parts in ipairs({ false, 2, 1 }) do
        local function Amount(copper)
            if not copper then return Util.FormatMoney(nil) end
            return Util.FormatMoney(copper, { short = true, parts = parts or nil })
        end

        label:SetText(L.Format("%s held  ·  %s%s",
            Util.Comma(entry.total), Amount(entry.worth),
            entry.unit and L.Format("  ·  %s each", Amount(entry.unit)) or ""))
        if Fits(label, room) then return end
    end
end

--- No item picked: each bank, what is in it and what it is worth.
local function ShowOverview(detail, overview)
    HideLines(detail)

    detail.icon:Hide()
    detail.title:ClearAllPoints()
    detail.title:SetPoint("TOPLEFT", 12, -12)
    detail.title:SetPoint("TOPRIGHT", -12, -12)

    local total, read = 0, 0
    local best = 0
    for _, row in ipairs(overview) do
        total = total + row.worth
        if row.bankAt then read = read + 1 end
        if row.worth > best then best = row.worth end
    end

    SetTitle(detail.title, L["Every bank"], TITLE_ROOM)
    detail.subtitle:SetText(L.Format("%d of %d banks read  ·  %s", read, #overview, Money(total)))
    detail.heading:SetText(L["BY CHARACTER"])

    for index, row in ipairs(overview) do
        local line = detail.lines[index]
        if not line then
            detail.more:SetText(L.Format("and %d more", #overview - DETAIL_LINES))
            break
        end

        -- A whole name, a size smaller when long, never cut.
        Theme.FitWhole(line.name, row.name, NAME_SIZES)
        line.name:SetTextColor(Theme.Unpack(row.isCurrent and "accent" or "text"))

        if row.bankAt then
            line.value:SetText(Money(row.worth))

            local age = row.isCurrent and ns.Inventory and ns.Inventory.bankOpen
                and L["open now"] or L.Format("read %s", Util.FormatAgeAgo(time() - row.bankAt))
            Theme.FitWhole(line.sub, L.Format("%s items  ·  %s", Util.Comma(row.count), age), { "tiny" })
            line.sub:SetTextColor(Theme.Unpack("dim"))
            line.bar:Set(best > 0 and row.worth / best or 0, row.isCurrent and "accent" or "profit")
        else
            line.value:SetText("")
            Theme.FitWhole(line.sub, L["Bank not opened yet"], { "tiny" })
            line.sub:SetTextColor(Theme.Unpack("warn"))
            line.bar:Set(nil)
        end

        line:Show()
    end

    detail.note:SetText(L["Open the bank once on each character to add it here. Click an item to see who has it."])
end

--- An item picked: who holds it and how many.
local function ShowItem(detail, entry)
    HideLines(detail)

    Theme.SetItemIcon(detail.icon, entry.itemID)
    detail.title:ClearAllPoints()
    detail.title:SetPoint("TOPLEFT", detail.icon, "TOPRIGHT", 8, 0)
    detail.title:SetPoint("TOPRIGHT", -12, -12)
    SetTitle(detail.title, Util.GetItemLabel(entry.itemID), ITEM_TITLE_ROOM)

    SetItemSubtitle(detail.subtitle, entry, ITEM_TITLE_ROOM)
    detail.heading:SetText(L["WHO HAS IT"])

    for index, holder in ipairs(entry.holders) do
        local line = detail.lines[index]
        if not line then
            detail.more:SetText(L.Format("and %d more", #entry.holders - DETAIL_LINES))
            break
        end

        local held = holder.bank + holder.bags

        Theme.FitWhole(line.name, names[holder.key] or "?", NAME_SIZES)
        line.name:SetTextColor(Theme.Unpack(NameColor(holder.key)))
        line.value:SetText(Util.Comma(held))
        Theme.FitWhole(line.sub, WhereText(holder.bank, holder.bags), { "tiny" })
        line.sub:SetTextColor(Theme.Unpack("dim"))
        line.bar:Set(entry.total > 0 and held / entry.total or 0,
            holder.key == current.key and "accent" or "profit")
        line:Show()
    end

    detail.note:SetText(L["Counts are from each character's last bank visit. Bags are from their last time online."])
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

local function CharacterOptions(characters)
    local options = { { value = ALL, text = L["All characters"] } }
    for _, character in ipairs(characters) do
        options[#options + 1] = { value = character.key, text = character.name }
    end
    return options
end

function BankView.Refresh()
    if not widgets.list or not ns.db then return end

    local characters = ns.Recipes:GetCharacters()

    names = {}
    current = {}
    for _, character in ipairs(characters) do
        names[character.key] = character.name
        if character.isCurrent then current.key = character.key end
    end

    widgets.character:SetOptions(CharacterOptions(characters))
    if state.character ~= ALL and not names[state.character] then state.character = ALL end
    widgets.character:SetValue(state.character)

    -- Set again by Banks for any item the client has not loaded yet.
    ns.Banks.waiting = false

    local list = ns.Banks:Collect({
        character = state.character ~= ALL and state.character or nil,
        bags = state.bags,
        search = state.search,
    })
    ns.Banks:Sort(list, state.sortBy)
    -- A clicked heading's order over the menu's.
    if widgets.sorter then list = widgets.sorter:Sort(list) end

    widgets.list:SetData(list)

    local total, count = 0, 0
    for _, entry in ipairs(list) do
        total = total + (entry.worth or 0)
        count = count + entry.total
    end

    local overview = ns.Banks:Overview()
    state.waiting = ns.Banks.waiting and true or false
    local anyRead = false
    for _, row in ipairs(overview) do
        if row.bankAt then anyRead = true break end
    end

    widgets.empty:SetShown(#list == 0)
    if #list == 0 then
        if not anyRead and not state.bags then
            widgets.empty:SetText(L["No bank read yet. Open your bank on each character and it shows up here."])
        elseif state.search ~= "" then
            widgets.empty:SetText(L.Format("Nothing matches \"%s\".", state.search))
        else
            widgets.empty:SetText(L["Nothing here yet."])
        end
    end

    widgets.summary:SetText(L.Format("%s different items  ·  %s in all  ·  ",
        Util.Comma(#list), Util.Comma(count)))
    CountTo(widgets.total, "", total)

    -- Keep the pane on the same item across refreshes.
    local selected
    if state.selected then
        for _, entry in ipairs(list) do
            if entry.itemID == state.selected then selected = entry break end
        end
        if not selected then state.selected = nil end
    end

    if selected then
        ShowItem(widgets.detail, selected)
    else
        ShowOverview(widgets.detail, overview)
    end
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

--- Fill `view`, a frame covering the whole Characters tab. The top 28 pixels
--- on the left are the tab's view switch.
function BankView.Build(view)
    -- Before any row or heading is laid out: they read these widths.
    if Widgets.FitColumns then Widgets.FitColumns(COLUMNS) end

    local right = -DETAIL_WIDTH - 16

    -- Dropdown, search, tick box, as on every tab (2026-10-06). No
    -- sort menu: the headings sort, and the list opens by worth.
    local character = Widgets.CreateDropdown(view, {}, function(value)
        state.character = value
        state.selected = nil
        BankView.Refresh()
    end, { width = 160 })
    character:SetPoint("TOPLEFT", 8, -32)
    widgets.character = character

    local search = Widgets.CreateSearchBox(view, L["Search every bank"], function(text)
        state.search = text or ""
        BankView.Refresh()
    end)
    search:SetPoint("LEFT", character, "RIGHT", 8, 0)
    search:SetWidth(Widgets.SEARCH_WIDTH)
    widgets.search = search

    local bags = Widgets.CreateCheckbox(view, L["Bags too"], function(checked)
        state.bags = checked and true or false
        BankView.Refresh()
    end, state.bags)
    bags:SetPoint("LEFT", search, "RIGHT", 12, 0)
    widgets.bags = bags

    -- Column headings over the list, lined up with the row cells.
    local headings = CreateFrame("Frame", nil, view)
    headings:SetHeight(14)
    headings:SetPoint("TOPLEFT", 8, -62)
    headings:SetPoint("TOPRIGHT", view, "TOPRIGHT", right, -62)

    local itemHeading = Theme.CreateLabel(headings, "tiny", "dim")
    itemHeading:SetPoint("LEFT", 32, 0)
    itemHeading:SetText(L["ITEM"])

    headings.cells = {}
    for _, column in ipairs(COLUMNS) do
        local cell = Theme.CreateLabel(headings, "tiny", "dim", column.justify or "RIGHT")
        cell:SetText(column.label)
        headings.cells[column.key] = cell
    end
    ns.Columns:Place("banks", COLUMNS, headings.cells, { gap = 8 })
    widgets.headings = headings

    -- Click a heading to sort by it.
    local sortLabels = { name = itemHeading }
    for key, cell in pairs(headings.cells) do sortLabels[key] = cell end
    widgets.sorter = Widgets.SortableHeadings and Widgets.SortableHeadings(sortLabels, {
        name = function(entry) return entry.name end,
        worth = function(entry) return entry.worth end,
        have = function(entry) return entry.total end,
        who = function(entry)
            if #entry.holders == 1 then return names[entry.holders[1].key] end
            return ("%d characters"):format(#entry.holders)
        end,
    }, function() BankView.Refresh() end)
    if widgets.sorter then widgets.sorter:SetText({ "name", "who" }) end

    -- Right-click the headings to choose the columns.
    ns.Columns:Attach(headings, "banks", widgets.sorter)
    ns.Columns:OnChange("banks", function()
        ns.Columns:Place("banks", COLUMNS, headings.cells, { gap = 8 })
        if widgets.sorter then widgets.sorter:Sync() end
        if widgets.list then widgets.list:Refresh() end
    end)

    local list = Widgets.CreateScrollList(view, {
        rowHeight = ROW_HEIGHT,
        createRow = CreateRow,
        updateRow = UpdateRow,

        isSelected = function(entry)
            return state.selected ~= nil and entry.itemID == state.selected
        end,

        onClick = function(entry)
            -- A second click on the same item goes back to the overview.
            state.selected = state.selected ~= entry.itemID and entry.itemID or nil
            BankView.Refresh()
        end,

        onEnter = ShowRowTooltip,
        onLeave = function() GameTooltip:Hide() end,

        -- Headings step left with the rows while the scrollbar shows.
        onScrollbarShown = function(shown)
            headings:SetPoint("TOPRIGHT", view, "TOPRIGHT", right - (shown and 10 or 0), -62)
        end,
    })
    list:SetPoint("TOPLEFT", 8, -78)
    list:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", right, 28)
    widgets.list = list

    local empty = Theme.CreateLabel(view, "small", "dim", "CENTER")
    empty:SetPoint("CENTER", list, "CENTER")
    empty:SetWidth(360)
    empty:SetWordWrap(true)
    widgets.empty = empty

    local summary = Theme.CreateLabel(view, "small", "text")
    summary:SetPoint("BOTTOMLEFT", 8, 10)
    widgets.summary = summary

    local total = Theme.CreateLabel(view, "small", "text")
    total:SetPoint("LEFT", summary, "RIGHT", 0, 0)
    widgets.total = total

    local detail = BuildDetail(view)
    detail:SetPoint("TOPRIGHT", view, "TOPRIGHT", -8, -40)
    detail:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -8, 8)
    widgets.detail = detail

    -- An item the client had not loaded is drawn as "item 1234" with no
    -- worth. Drawn again once items arrive: a burst of them is one redraw,
    -- and nothing happens unless something on show was waiting. An item the
    -- game says does not exist never arrives, and drawing again would only
    -- ask for it again, so that answer is not a reason to.
    local redrawQueued = false
    ns.RegisterEvent(BankView, "GET_ITEM_INFO_RECEIVED", function(_, _, _, success)
        if success == false then return end
        if redrawQueued or not state.waiting then return end
        if not list:IsVisible() then return end

        redrawQueued = true
        C_Timer.After(0.2, function()
            redrawQueued = false
            BankView.Refresh()
        end)
    end)
end

--- For the tests: the view's state, so a test can set a filter, and what it
--- drew, so a test can read it back.
BankView._state = state
BankView._widgets = widgets
