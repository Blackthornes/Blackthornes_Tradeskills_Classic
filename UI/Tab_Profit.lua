-- Blackthornes Tradeskills -- UI/Tab_Profit.lua
-- The headline table: what is worth making, and why.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local UI = ns.UI

local ROW_HEIGHT = 22
local DETAIL_WIDTH = 300
-- The guildmates line: its label, then one row of names.
local CRAFTERS_HEIGHT = 32

-- The detail pane's summary lines: materials, prices, cut, profit.
local SUMMARY_ROW_HEIGHT = 17

-- Room at the left of every row for the skill-up star. Always reserved, shown
-- or not, so the craft names stay in one straight line down the list -- names
-- that shuffle sideways as the marks come and go are worse than the gap.
local MARK_GUTTER = 16

-- The made item's icon, between the star and the name.
local ICON_SIZE = 16
local ICON_GUTTER = ICON_SIZE + 4

-- The columns, measured from the right edge of the list and laid out right
-- to left. Money sits to the right, so its coins line up down the column;
-- everything else is centred under its heading. `width` is the least each
-- gets: Widgets.FitColumns widens it to fit the heading and a full amount.
-- WHO only earns its space when more than one character is in play, so it
-- is hidden otherwise and the craft name takes the room back.
local COLUMNS = {
    { key = "age",    label = L["AGE"],    width = 40, justify = "CENTER" },
    { key = "posted", label = L["STOCK"],  width = 44, justify = "CENTER" },
    -- How well it sells (Logic/Demand.lua), beside what you already hold:
    -- together they say whether to make more.
    { key = "demand", label = L["DEMAND"], width = 50, justify = "CENTER" },
    { key = "make",   label = L["MAKE"],   width = 40, justify = "CENTER" },
    { key = "who",    label = L["WHO"],    width = 96, justify = "CENTER", accountWideOnly = true },
    { key = "margin", label = L["MARGIN"], width = 46, justify = "CENTER" },
    -- Which way the profit is for (AH, Vendor, DE), when the list is
    -- ranked by whichever pays most. Ranked by one way, it says nothing.
    { key = "via",    label = L["VIA"],    width = 44, justify = "CENTER", bestOnly = true },
    -- How long one takes, sub-crafts included (asked 2026-10-09), and what
    -- it makes a day at the rate it sells (A DAY, 2026-10-16, in place of
    -- GOLD/HR). Shown with the "Per day" tick box. The key stays "perHour"
    -- so the saved column choices still find it.
    { key = "time",    label = L["TIME"],    width = 44, justify = "CENTER", perHourOnly = true },
    { key = "perHour", label = L["A DAY"],   width = 74, money = true, perHourOnly = true },
    { key = "profit", label = L["PROFIT"], width = 74, money = true },
    -- Beside SELLS so the two read against each other. Only shown when
    -- something in the list can be disenchanted.
    { key = "disenchant", label = L["DISENCHANT"], width = 62, money = true, disenchantOnly = true },
    { key = "sells",  label = L["SELLS"],  width = 70, money = true },
    { key = "cost",   label = L["COST"],   width = 70, money = true },
}

-- Any column but the craft's name can be hidden as well (UI/Columns.lua).
ns.Columns:Register("profit", L["Profit"], COLUMNS)

local MARGIN_COLUMN
for _, column in ipairs(COLUMNS) do
    if column.key == "margin" then MARGIN_COLUMN = column end
end

-- Bumped whenever the visible column set changes, so recycled rows know to
-- re-anchor rather than keeping a stale layout.
local layoutVersion = 1

-- Forward declaration: defined below, used by the toolbar built after it.
local ApplyHeadingLayout

-- Defined with the cells below, used by the rows.
local UpdateTimeCells

local state = {
    search = "",
    accountWide = false,
    showDisenchant = false,
    ignorePostLimit = false,
    profession = nil,
    craftableOnly = false,
    includeUnpriceable = false,
    sortBy = "profit",
    selected = nil,
}

local widgets = {}

-- The row hint, as much of it as fits beside the count on its left.
local HINT_TEXTS = {
    L["Right-click a row to queue one, Shift-click to search the auction house"],
    L["Right-click to queue, Shift-click to search"],
    L["Right-click a row to queue one"],
}

local function FitHint()
    local hint, count, list = widgets.hint, widgets.countLabel, widgets.list
    if not (hint and count and list and Theme.TextWidth and Theme.FitText) then return end
    local listWidth = list:GetWidth()
    local used = Theme.TextWidth(count) or 0
    local room = type(listWidth) == "number" and listWidth > 0 and (listWidth - used - 124) or nil
    Theme.FitText(hint, HINT_TEXTS, room)
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

--- What the profit is for: Settings' "profitBy", "best" unless picked.
local function Method()
    return ns.Profit.GetMethod and ns.Profit:GetMethod() or nil
end

-- With every column on (Per day ticked, All characters, disenchants) the
-- columns can take more room than the list has and run over the craft names
-- and each other. Then the ones read least are set aside for as long as it
-- lasts, least needed first, so the name keeps NAME_MIN. Nothing saved: they
-- come back once there is room. COST, SELLS, PROFIT, TIME and A DAY stay.
local NAME_MIN = 160
local SQUEEZE_ORDER = { "age", "via", "make", "posted", "demand", "margin", "disenchant", "who" }
local squeezed = {}
local squeezedKey = ""

--- The list's own rules for a column, before any is set aside for room.
local function ColumnWanted(column)
    if column.accountWideOnly then return state.accountWide end
    if column.bestOnly then return Method() == "best" end
    if column.disenchantOnly then return state.showDisenchant end
    if column.perHourOnly then return ns.Config:Get("profitShowsPerHour") == true end
    return true
end

local function IsColumnVisible(column)
    if not ns.Columns:Shown("profit", column) then return false end
    if squeezed[column.key] then return false end
    return ColumnWanted(column)
end

--- Position the numeric columns and give the craft name whatever is left.
local function ApplyRowLayout(row)
    local offset = -8

    for _, column in ipairs(COLUMNS) do
        local cell = row.cells[column.key]

        if IsColumnVisible(column) then
            cell:SetPoint("RIGHT", row, "RIGHT", offset, 0)
            cell:SetWidth(column.width)
            cell:Show()
            offset = offset - column.width - 6
        else
            cell:Hide()
        end
    end

    row.name:SetPoint("RIGHT", row, "RIGHT", offset - 4, 0)

    -- The margin's bar sits centred under its number.
    row.marginBar:SetPoint("TOP", row.cells.margin, "BOTTOM", 0, -1)

    row.layoutVersion = layoutVersion
    row.columnsVersion = ns.Columns.version
end

local function CreateRow(row)
    row.mark = Theme.CreateMark(row)
    row.mark:SetPoint("LEFT", 7, 0)

    row.icon = Theme.CreateItemIcon(row, ICON_SIZE)
    row.icon:SetPoint("LEFT", 8 + MARK_GUTTER, 0)

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("LEFT", 8 + MARK_GUTTER + ICON_GUTTER, 0)

    row.cells = {}
    for _, column in ipairs(COLUMNS) do
        row.cells[column.key] = Theme.CreateLabel(row, "small", "text", column.justify or "RIGHT")
    end

    row.marginBar = Theme.CreateBar(row, 40, 2)

    ApplyRowLayout(row)
end

-- Item data arrives from the server on its own schedule, so the first pass
-- over a recipe whose output is not cached yet gets no colour back. Those rows
-- are drawn in the plain text colour and remembered here; GET_ITEM_INFO_RECEIVED
-- redraws them once the client has the item.
local awaitingItemData = false

--- Colour a craft's name by the rarity of the item it makes.
--
-- Rarity is what tells the player whether a craft is worth making at all, so it
-- is on every row, including ones that cannot be made or priced right now.
local function ApplyNameColor(row, analysis)
    local r, g, b = Util.GetItemQualityColor(analysis.outputItemID)

    if r then
        row.name:SetTextColor(r, g, b)
        return
    end

    row.name:SetTextColor(Theme.Unpack("text"))
    if analysis.outputItemID then awaitingItemData = true end
end

--- How many of this craft the materials on hand cover.
--
-- This column exists because the name no longer carries it: greying the name
-- out was the old "you are short of materials", and it drowned out rarity.
local function UpdateMakeCell(cells, analysis)
    local craftable = analysis.craftableNow or 0

    if craftable > 0 then
        cells.make:SetText(tostring(craftable))
        cells.make:SetTextColor(Theme.Unpack("text"))
    else
        cells.make:SetText("0")
        cells.make:SetTextColor(Theme.Unpack("loss"))
    end
end

--- What the craft is worth disenchanted. Green when that beats selling it,
--- so the rows where it does stand out down the column.
local function UpdateDisenchantCell(cells, analysis)
    local cell = cells.disenchant

    if analysis.disenchantValue then
        Theme.SetMoneyText(cell, analysis.disenchantValue, { short = true })
        cell:SetTextColor(Theme.Unpack(analysis.disenchantBeatsSale and "profit" or "muted"))
    elseif analysis.disenchantable then
        cell:SetText(L["no price"])
        cell:SetTextColor(Theme.Unpack("dim"))
    else
        cell:SetText("")
    end
end

--- How many a day A DAY counts on, in words: "About 4 sell a day.", or
--- "You keep 2 listed, so it counts 2." when Keep in stock caps it.
local function PerDayNote(analysis)
    local sells = analysis.perDaySells or 0
    local count = sells >= 10 and ("%d"):format(math.floor(sells + 0.5))
        or ("%.1f"):format(sells):gsub("%.0$", "")
    if analysis.perDayCapped then
        return L.Format("You keep %s listed, so it counts %s a day.", count, count)
    end
    return L.Format("About %s sell a day.", count)
end

--- How long the craft takes, and what it makes a day at the rate it sells.
--- The time is "?" until a cast of every craft in it has been seen or the
--- game says how long it is, and "--" for a recipe the character playing
--- does not know. A day is "--" without a sales estimate.
function UpdateTimeCells(cells, analysis)
    if analysis.perDay then
        Theme.SetMoneyText(cells.perHour, analysis.perDay, { short = true })
        cells.perHour:SetTextColor(Theme.ProfitColor(analysis.perDay))
    else
        cells.perHour:SetText("--")
        cells.perHour:SetTextColor(Theme.Unpack("dim"))
    end

    local CraftTime = ns.CraftTime
    if not CraftTime then
        cells.time:SetText("")
        return
    end

    if analysis.knownByMe == false then
        cells.time:SetText("--")
        cells.time:SetTextColor(Theme.Unpack("dim"))
        return
    end

    local seconds = analysis.timeSeconds or analysis.craftSeconds
    cells.time:SetText(CraftTime.Format(seconds))
    cells.time:SetTextColor(Theme.Unpack(seconds and "muted" or "dim"))
end

--- The time line on a row's tooltip: how long it takes, what is in that
--- time, and what it makes an hour.
local function AddTimeLines(analysis)
    local CraftTime = ns.CraftTime
    if not CraftTime or not GameTooltip:IsShown() then return end

    local timing = analysis.craftTime
    local seconds = analysis.timeSeconds or analysis.craftSeconds
    if not timing then return end

    local r, g, b = 0.7, 0.7, 0.7
    if not seconds then
        GameTooltip:AddLine(L["Make one to learn how long it takes."], r, g, b, true)
        GameTooltip:Show()
        return
    end

    local parts = {}
    if (timing.casts or 1) > 1 + 1e-6 then parts[#parts + 1] = L["sub-crafts included"] end
    if analysis.via == "disenchant" and analysis.timeSeconds then parts[#parts + 1] = L["and disenchanting"] end
    local note = #parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""

    GameTooltip:AddDoubleLine(L["Craft time"] .. note, CraftTime.Format(seconds), r, g, b, 1, 1, 1)
    GameTooltip:Show()
end

--- The A DAY line on a row's tooltip: what it makes a day and how many
--- that counts on selling.
local function AddPerDayLine(analysis)
    if not analysis.perDay or not GameTooltip:IsShown() then return end
    local r, g, b = 0.7, 0.7, 0.7
    local vr, vg, vb = Theme.Unpack(analysis.perDay >= 0 and "profit" or "loss")
    GameTooltip:AddDoubleLine(L["Profit a day"],
        Util.FormatMoney(analysis.perDay, { noColor = true, short = true }), r, g, b, vr, vg, vb)
    GameTooltip:AddLine(PerDayNote(analysis), r, g, b, true)
    GameTooltip:Show()
end

--- What the STOCK column's "0/3" means (a player asked, the owner said yes,
--- 2026-10-22): how many you have, and how many you keep and why.
local function StockLine(analysis)
    local stock = analysis.stock or 0
    if analysis.postLimit and analysis.postLimit > 0 then
        return L.Format("You have %d. You keep %d (Keep in Stock).", stock, analysis.postLimit)
    elseif analysis.learnedLimit then
        return L.Format("You have %d. You keep %d (learned from your sales).", stock, analysis.learnedLimit)
    end
end

local function AddStockLine(analysis)
    local text = StockLine(analysis)
    if not text or not GameTooltip:IsShown() then return end
    local r, g, b = 0.7, 0.7, 0.7
    GameTooltip:AddLine(text, r, g, b, true)
    GameTooltip:Show()
end

--- Say so on the row's tooltip when disenchanting pays more than selling.
local function AddDisenchantLine(analysis)
    if not analysis.disenchantBeatsSale or not GameTooltip:IsShown() then return end

    GameTooltip:AddLine(L.Format("Disenchanting it is worth %s more than selling it.",
        Util.FormatMoney(analysis.disenchantValue - (analysis.unitRevenue or 0), { noColor = true })),
        0.35, 0.85, 0.45, true)
    GameTooltip:Show()
end

--- What the craft makes each way it can be turned into gold, the one the
--- profit is for in gold. Returns whether it added anything.
local function AddWaysLines(analysis)
    if not ns.Profit.DescribeWays or not GameTooltip:IsShown() then return false end

    local lines = ns.Profit:DescribeWays(analysis)
    if #lines == 0 then return false end

    GameTooltip:AddLine(" ")
    for _, line in ipairs(lines) do
        local label = line.label .. (line.note and (" (" .. line.note .. ")") or "")
        local r, g, b = 0.7, 0.7, 0.7
        if line.chosen then r, g, b = Theme.Unpack("accent") end
        local vr, vg, vb = Theme.Unpack(line.profit >= 0 and "profit" or "loss")
        GameTooltip:AddDoubleLine(label, Util.FormatMoney(line.profit, { noColor = true }),
            r, g, b, vr, vg, vb)
    end
    GameTooltip:Show()
    return true
end

--- The full name of who can make it, for the WHO column's tooltip.
local function AddOwnerLine(analysis)
    if not state.accountWide or not analysis.ownerName or not GameTooltip:IsShown() then return end

    GameTooltip:AddLine(L.Format("Crafted by %s", analysis.ownerName), 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

--- A cell's text, or its short form when the full one runs past the cell.
--- Measured, so a narrow column never ends in "..." on a wide font.
local function SetFitted(cell, text, short)
    cell:SetText(text)
    if not short then return end

    local ok, width = pcall(cell.GetStringWidth, cell)
    local room = cell:GetWidth()
    if ok and type(width) == "number" and type(room) == "number" and room > 0 and width > room then
        cell:SetText(short)
    end
end

local function UpdateRow(row, analysis)
    -- Rows are recycled, so one built under a different column set has to
    -- be re-anchored before it is filled.
    if row.layoutVersion ~= layoutVersion or row.columnsVersion ~= ns.Columns.version then
        ApplyRowLayout(row)
    end

    -- Gear another of your characters would wear, from Blackthornes
    -- Equipment (Logic/Upgrades.lua).
    local name = analysis.name or L.Format("recipe %s", analysis.recipeID)
    if ns.Upgrades and ns.Upgrades.WithAltText then name = ns.Upgrades:WithAltText(name, analysis.outputItemID) end
    Theme.SetRowName(row.name, name)
    Theme.SetItemIcon(row.icon, analysis.outputItemID)
    row.marginBar:Set(nil)

    local cells = row.cells

    -- All three hold whatever the row's price data looks like, so they are
    -- filled before the unpriceable case takes its early exit.
    ApplyNameColor(row, analysis)
    UpdateMakeCell(cells, analysis)
    UpdateDisenchantCell(cells, analysis)

    -- The star: this craft raises your skill AND turns a profit. Set from
    -- analysis.recommended rather than from the tier alone, so an orange
    -- recipe that loses gold is not recommended by the back door.
    Theme.SetMark(row.mark, analysis.recommended
        and analysis.skillUp and analysis.skillUp.tier or nil)

    -- Only meaningful when several characters are in play.
    if state.accountWide then
        -- The whole name, wrapped smaller when it is long (never shortened).
        Theme.SetRowName(cells.who, analysis.ownerShortName or analysis.ownerName or "")
        cells.who:SetTextColor(Theme.Unpack(analysis.isMine and "accent" or "muted"))
    else
        cells.who:SetText("")
    end

    -- Shown on unpriced rows too: what sold needs no price.
    local reading = ns.Demand and ns.Demand:Get(analysis.outputItemID)
    if reading then
        cells.demand:SetText(ns.Demand:Label(reading))
        cells.demand:SetTextColor(Theme.Unpack(ns.Demand:Color(reading)))
    else
        cells.demand:SetText("--")
        cells.demand:SetTextColor(Theme.Unpack("dim"))
    end

    -- Everything you already hold: listed, plus bags and bank.
    local stock = analysis.stock or 0

    if analysis.postLimit and analysis.postLimit > 0 then
        cells.posted:SetText(("%d/%d"):format(stock, analysis.postLimit))
        cells.posted:SetTextColor(Theme.Unpack(analysis.atPostLimit and "warn" or "muted"))
    elseif analysis.learnedLimit then
        -- No number set, but Queue All keeps what your sales taught, so
        -- the column says how many, in a quieter colour than a typed one.
        cells.posted:SetText(("%d/%d"):format(stock, analysis.learnedLimit))
        cells.posted:SetTextColor(Theme.Unpack("dim"))
    elseif stock > 0 then
        cells.posted:SetText(tostring(stock))
        cells.posted:SetTextColor(Theme.Unpack("muted"))
    else
        cells.posted:SetText("")
    end

    -- The time needs no price, so it shows on unpriced rows too.
    UpdateTimeCells(cells, analysis)

    if not analysis.priceable then
        cells.cost:SetText("--")
        cells.sells:SetText("--")
        cells.via:SetText("")
        cells.margin:SetText("")
        cells.age:SetText("")

        -- STOCK stays: what you hold needs no price, and it was blanked
        -- here on exactly the rows the Keep in stock limit still applies to.
        cells.profit:SetText(analysis.soulbound and L["soulbound"]
            or analysis.reason == L["output has no price data"] and L["no price"]
            or L["no data"])
        cells.profit:SetTextColor(Theme.Unpack("dim"))
        return
    end

    -- Measured: "12g 34s 56c" is wider than these columns and ended in
    -- "...". It drops to "12g 35s" instead.
    Theme.SetMoneyText(cells.cost, analysis.totalCost, { short = true })
    cells.cost:SetTextColor(Theme.Unpack("muted"))

    Theme.SetMoneyText(cells.sells, analysis.revenue, { short = true })
    cells.sells:SetTextColor(Theme.Unpack("text"))

    Theme.SetMoneyText(cells.profit, analysis.profit, { short = true })
    cells.profit:SetTextColor(Theme.ProfitColor(analysis.profit))

    cells.via:SetText(ns.Profit.WAY_LABELS and ns.Profit.WAY_LABELS[analysis.via] or "")
    cells.via:SetTextColor(Theme.Unpack(analysis.via == "disenchant" and "accent" or "muted"))

    cells.margin:SetText(("%d%%"):format(math.floor((analysis.margin or 0) * 100)))
    cells.margin:SetTextColor(Theme.ProfitColor(analysis.profit))

    -- Full at 100% and over; a loss draws no bar, its red number says it.
    -- Nor does a hidden MARGIN column.
    if (analysis.profit or 0) > 0 and IsColumnVisible(MARGIN_COLUMN) then
        row.marginBar:Set(math.min(1, analysis.margin or 0), "profit")
    end

    if analysis.priceDerived then
        -- There is no scan behind this row, so an age would be a blank or a
        -- lie. The column says what the price actually is instead: the
        -- materials-plus-markup estimate, which is a different kind of
        -- number from everything else in the list.
        SetFitted(cells.age, L["estimate"], L["est."])
        cells.age:SetTextColor(Theme.Unpack("warn"))
    elseif analysis.priceBasis == "vendor" then
        -- What a vendor pays never goes out of date, so there is no age to
        -- show. VIA already says Vendor; repeating it here read as a bug
        -- (Discord, 2026-10-08).
        cells.age:SetText("--")
        cells.age:SetTextColor(Theme.Unpack("dim"))
    elseif analysis.priceBasis == "mine" or analysis.priceBasis == "floor"
        or analysis.priceBasis == "highest" then
        -- Priced at what the player set on the Prices tab, not a scan.
        SetFitted(cells.age, L["my price"], L["mine"])
        cells.age:SetTextColor(Theme.Unpack("warn"))
    else
        local age = Util.FormatAge(analysis.age)
        SetFitted(cells.age, age, age == L["just now"] and L["now"] or nil)
        cells.age:SetTextColor(Theme.Unpack(analysis.stale and "warn" or "dim"))
    end
end

--- Why this row is wearing a star.
--
-- The mark is small and new, so it has to be able to explain itself; a symbol
-- nobody can interrogate is a symbol people learn to ignore.
local function ShowMarkTooltip(row, analysis)
    local skillUp = analysis.skillUp
    if not skillUp then return end

    ns.Widgets.ShowItemTooltip(row, "ANCHOR_LEFT", analysis.outputItemID, analysis.name or L["craft"])
    GameTooltip:AddLine(" ")

    local r, g, b = ns.SkillUp:GetTierColor(skillUp.tier)
    GameTooltip:AddDoubleLine(L["Skill up"], ns.SkillUp:GetTierLabel(skillUp.tier),
        0.7, 0.7, 0.7, r, g, b)

    local steps = ns.SkillUp:ColorSteps(analysis.recipeID)
    if steps then GameTooltip:AddLine(steps, 1, 1, 1, true) end

    GameTooltip:AddDoubleLine(L["Profit each"],
        Util.FormatMoney(analysis.profit, { noColor = true }), 0.7, 0.7, 0.7, 1, 1, 1)

    -- Skill only rises, so a reading taken lower down may have gone green
    -- since. Better said than quietly trusted.
    if skillUp.stale then
        GameTooltip:AddLine(L.Format("Read at skill %d, and you're %d now. Open your profession to refresh it.",
            skillUp.skill or 0, skillUp.currentSkill or 0), 0.91, 0.76, 0.35, true)
    end

    GameTooltip:AddLine(L["Starred: it raises your skill and it pays."], 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- Detail panel
--------------------------------------------------------------------------------

-- Defined below; the Price graph button redraws the pane with it.
local UpdateDetail

--- The tooltip on "If disenchanted": what the craft breaks into, the chance
--- of each, and what each is worth, as the Enchanting tab's pane showed it.
local function ShowBreaksInto(owner, analysis)
    local itemID = analysis and analysis.outputItemID
    if not itemID or not ns.Disenchant or not ns.Disenchant.GetValue then return end

    local _, _, breakdown = ns.Disenchant:GetValue(itemID)
    breakdown = breakdown or {}

    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:SetText(L["Breaks into"], 1, 1, 1)

    for _, outcome in ipairs(breakdown.outcomes or {}) do
        local count = outcome.min == outcome.max and tostring(outcome.min)
            or ("%d-%d"):format(outcome.min, outcome.max)
        GameTooltip:AddDoubleLine(
            ("%s%%  %sx %s%s"):format(Util.Round(outcome.chance * 100, 1), count,
                Util.ColorItemName(outcome.itemID, outcome.name) or Util.GetItemLabel(outcome.itemID),
                outcome.counted == false and L["  (bonus)"] or ""),
            outcome.price and L.Format("%s each", Util.FormatMoney(outcome.price, { noColor = true, short = true }))
                or L["no price"],
            1, 1, 1, 0.8, 0.8, 0.8)
    end

    local facts = breakdown.facts or {}
    if facts.skill then
        GameTooltip:AddLine(L.Format("Needs Enchanting about %d.", facts.skill), 0.7, 0.7, 0.7, true)
    end
    if facts.source == "yours" then
        GameTooltip:AddLine(L.Format("Chances come from %s.", ns.Disenchant:YoursPhrase(facts)), 0.5, 0.5, 0.5, true)
    else
        GameTooltip:AddLine(L["Rough chances for now. They get better as you disenchant."], 0.5, 0.5, 0.5, true)
    end
    GameTooltip:Show()
end

--- Widen a fixed-width button to its label when the label is longer (a
--- German one is): never narrower than it was made, never "...".
local function GrowToFit(button)
    local label = rawget(button, "label")
    if type(label) ~= "table" or not Theme.TextWidth then return end
    local text = Theme.TextWidth(label)
    local ok, width = pcall(button.GetWidth, button)
    if type(text) == "number" and ok and type(width) == "number" and text + 12 > width then
        button:SetWidth(math.ceil(text + 12))
    end
end

--- One name on the guildmates line: gold, lit under the mouse, a click
--- opens a whisper. `name` is nil for the "+N more" button, whose hover
--- lists the rest.
local function CrafterButton(crafters, index)
    local button = crafters.names[index]
    if button then return button end
    button = CreateFrame("Button", nil, crafters)
    button:SetHeight(14)
    button.text = Theme.CreateLabel(button, "small", "accent")
    button.text:SetPoint("LEFT", 0, 0)
    button:SetScript("OnEnter", function(self)
        self.text:SetTextColor(Theme.Unpack("text"))
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self.name then
            GameTooltip:SetText(L.Format("Click to whisper %s.", self.name), 1, 1, 1, 1, true)
        else
            for _, other in ipairs(self.rest or {}) do GameTooltip:AddLine(other, 1, 0.82, 0) end
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function(self)
        self.text:SetTextColor(Theme.Unpack(self.name and "accent" or "muted"))
        GameTooltip:Hide()
    end)
    button:SetScript("OnClick", function(self)
        if self.name and ns.GuildCrafters then ns.GuildCrafters.Whisper(self.name) end
    end)
    crafters.names[index] = button
    return button
end

--- Who can make it, for one line: the guildmates' or the friends'.
local function CraftersFor(analysis, friends)
    local crafters = ns.GuildCrafters
    if not (analysis and crafters) then return {} end
    local fn = friends and crafters.WhoCanMakeFriends or crafters.WhoCanMake
    if not fn then return {} end
    local ok, found = pcall(fn, crafters, analysis.recipeID)
    return (ok and type(found) == "table") and found or {}
end

--- Fill one line of names, or hide it. The names go on one row, as many as
--- fit, then "+N more". True when it shows.
local function FillCrafters(crafters, names, anchor)
    for _, button in ipairs(crafters.names) do button:Hide() end
    if #names == 0 then
        crafters:Hide()
        return false
    end
    crafters:ClearAllPoints()
    crafters:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)
    crafters:SetPoint("RIGHT", crafters:GetParent(), "RIGHT", -12, 0)
    crafters:Show()

    local okWidth, room = pcall(crafters.GetWidth, crafters)
    if not okWidth or type(room) ~= "number" or room <= 0 then room = DETAIL_WIDTH - 62 end
    local gap = 10
    local x, shown = 0, 0
    for index, name in ipairs(names) do
        local button = CrafterButton(crafters, index)
        button.name, button.rest = name, nil
        button.text:SetText(name)
        button.text:SetTextColor(Theme.Unpack("accent"))
        local width = math.ceil(Theme.TextWidth(button.text) or (#name * 6))
        -- Room left for this name, and for a "+N more" after it when more follow.
        local need = width + (index < #names and 60 or 0)
        if shown > 0 and x + need > room then break end
        button:SetWidth(width)
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", crafters, "TOPLEFT", x, -16)
        button:Show()
        x = x + width + gap
        shown = index
    end

    if shown < #names then
        local more = CrafterButton(crafters, shown + 1)
        more.name = nil
        more.rest = {}
        for index = shown + 1, #names do more.rest[#more.rest + 1] = names[index] end
        more.text:SetText(L.Format("+%d more", #names - shown))
        more.text:SetTextColor(Theme.Unpack("muted"))
        more:SetWidth(math.ceil(Theme.TextWidth(more.text) or 50))
        more:ClearAllPoints()
        more:SetPoint("TOPLEFT", crafters, "TOPLEFT", x, -16)
        more:Show()
    end
    return true
end

--- Fill the guildmates line and the friends line for a craft, or hide
--- them. The materials move down under whichever shows last.
local function UpdateCrafters(detail, analysis)
    local crafters = rawget(detail, "crafters")
    if type(crafters) ~= "table" then return end
    local below = detail.subtitle
    if FillCrafters(crafters, CraftersFor(analysis, false), below) then below = crafters end
    local friends = rawget(detail, "friendCrafters")
    if type(friends) == "table" and FillCrafters(friends, CraftersFor(analysis, true), below) then
        below = friends
    end

    detail.reagentHeading:ClearAllPoints()
    if below == detail.subtitle then
        detail.reagentHeading:SetPoint("TOPLEFT", detail.subtitle, "BOTTOMLEFT", -38, -12)
    else
        detail.reagentHeading:SetPoint("TOPLEFT", below, "BOTTOMLEFT", -38, -8)
    end
end

local function BuildDetail(parent)
    local detail = Theme.CreatePanel(parent, "window")
    detail:SetWidth(DETAIL_WIDTH)

    Theme.AccentStripe(detail, 2, 0.6)

    local icon = Theme.CreateItemIcon(detail, 30)
    icon:SetPoint("TOPLEFT", 12, -12)
    detail.icon = icon
    if Widgets.ItemHotspot then Widgets.ItemHotspot(icon) end

    -- What it makes, on the Stats tab (UI/Tab_Stats.lua), as the Prices
    -- tab has it.
    detail.stats = Widgets.CreateButton(detail, L["Stats"], function()
        if detail.statsItem and ns.StatsUI then ns.StatsUI:ShowItem(detail.statsItem) end
    end, { width = 50, height = 20, tooltip = L["See this item's charts on the Stats tab"] })
    detail.stats:SetPoint("TOPRIGHT", -8, -9)
    detail.stats:Hide()

    local title = Theme.CreateLabel(detail, "large", "accent")
    title:SetPoint("TOPLEFT", 50, -12)
    title:SetPoint("TOPRIGHT", detail.stats, "TOPLEFT", -6, -3)
    title:SetWordWrap(true)
    detail.title = title

    local subtitle = Theme.CreateLabel(detail, "small", "muted")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    -- Held inside the pane and wrapped there. On one line, "You have 12 and
    -- 4 more queued, your limit" ended in "..."; the materials below move
    -- down to make room.
    subtitle:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
    subtitle:SetWordWrap(true)
    detail.subtitle = subtitle

    -- Guildmates online who can make it (Logic/GuildCrafters.lua): a line
    -- under the subtitle, shown only when someone is, each name a click
    -- that opens a whisper. The materials move down under it.
    -- Friends online who can make it (the owner, 2026-10-25) get a line of
    -- their own under it, the same way.
    local function CrafterLine(label)
        local line = CreateFrame("Frame", nil, detail)
        line:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -6)
        line:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
        line:SetHeight(CRAFTERS_HEIGHT)
        line.label = Theme.CreateLabel(line, "small", "muted")
        line.label:SetPoint("TOPLEFT", 0, 0)
        line.label:SetPoint("RIGHT", line, "RIGHT", 0, 0)
        line.label:SetWordWrap(true)
        line.label:SetText(label)
        line.names = {}
        line:Hide()
        return line
    end
    detail.crafters = CrafterLine(L["Guildmates who can make it:"])
    detail.friendCrafters = CrafterLine(L["Friends who can make it:"])

    local reagentHeading = Theme.CreateHeading(detail, L["MATERIALS"])
    -- Back out under the icon, so the list of materials starts at the edge.
    reagentHeading:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", -38, -12)
    detail.reagentHeading = reagentHeading

    -- The price graph (2026-10-06) goes where the materials list
    -- does, for the craft and each material, hour by hour. This swaps the
    -- two; which one shows is remembered.
    if ns.PriceGraph then
        local graphButton = Widgets.CreateButton(detail, L["Price graph"], function()
            ns.Config:Set("profitShowsGraph", not ns.Config:Get("profitShowsGraph"))
            UpdateDetail(state.selected)
        end, { width = 76, height = 16, fontSize = "tiny" })
        GrowToFit(graphButton)
        graphButton:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -12, 0)
        graphButton:SetPoint("TOP", reagentHeading, "TOP", 0, 4)
        detail.graphButton = graphButton
        if reagentHeading.rule then
            reagentHeading.rule:ClearAllPoints()
            reagentHeading.rule:SetPoint("LEFT", reagentHeading, "RIGHT", 6, 0)
            reagentHeading.rule:SetPoint("RIGHT", graphButton, "LEFT", -6, 0)
        end

        local graph = ns.PriceGraph.Create(detail, { picker = true, ticks = true })
        graph:SetPoint("TOPLEFT", reagentHeading, "BOTTOMLEFT", 0, -6)
        graph:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -12, 84 + 170 + 6)
        graph:Hide()
        detail.graph = graph
    end

    -- Disenchant, for a craft you carry (it came from the Enchanting tab,
    -- 2026-10-07). The click itself is taken by the secure button
    -- UI/Disenchanter.lua lays over this one; this handler only runs when
    -- that button is not there, so it says why.
    local disenchantButton = Widgets.CreateButton(detail, L["Disenchant"], function()
        local analysis = state.selected
        local check = ns.Disenchanter:Check(analysis and analysis.outputItemID)

        if not check.ok then
            ns.Print(check.why)
        else
            ns.Warn(L["that click missed the Disenchant button. Click it again, and if it misses twice, type /bts disenchant and send the lines it prints."])
        end
    end, { width = 76, height = 16, fontSize = "tiny", primary = true })
    GrowToFit(disenchantButton)
    disenchantButton:SetPoint("TOP", reagentHeading, "TOP", 0, 4)
    if detail.graphButton then
        disenchantButton:SetPoint("RIGHT", detail.graphButton, "LEFT", -6, 0)
    else
        disenchantButton:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
    end
    disenchantButton:Hide()
    detail.disenchantButton = disenchantButton

    detail.reagentLines = {}

    -- The last line when the materials do not all fit above the summary. The
    -- whole list is in its tooltip.
    local more = CreateFrame("Frame", nil, detail)
    more:SetHeight(16)
    more:EnableMouse(true)
    more.label = Theme.CreateLabel(more, "small", "muted")
    more.label:SetPoint("LEFT", 18, 0)
    more:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(L["Materials"], 1, 1, 1)
        for _, reagent in ipairs(self.reagents or {}) do
            GameTooltip:AddDoubleLine(
                ("%dx %s"):format(reagent.quantity, Util.GetItemLabel(reagent.itemID)),
                reagent.shortfall > 0 and L.Format("need %d", reagent.shortfall)
                    or Util.FormatMoney(reagent.lineCost, { short = true }),
                1, 1, 1, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    more:SetScript("OnLeave", function() GameTooltip:Hide() end)
    more:Hide()
    detail.moreLine = more

    -- Summary block, anchored to the bottom so it never collides with a long
    -- reagent list.
    local summary = CreateFrame("Frame", nil, detail)
    summary:SetPoint("BOTTOMLEFT", 12, 84)
    summary:SetPoint("BOTTOMRIGHT", -12, 84)
    -- Twelve rows of 17: the sale, what each way makes, then the time.
    summary:SetHeight(204)
    detail.summary = summary
    detail.summaryRows = {}

    local function SummaryRow(index, labelText)
        local label = Theme.CreateLabel(summary, "small", "muted")
        label:SetPoint("TOPLEFT", 0, -(index - 1) * SUMMARY_ROW_HEIGHT)
        label:SetText(labelText)

        local value = Theme.CreateLabel(summary, "small", "text", "RIGHT")
        value:SetPoint("TOPRIGHT", 0, -(index - 1) * SUMMARY_ROW_HEIGHT)

        detail.summaryRows[index] = { label = label, value = value }
        return value, label
    end

    detail.costValue = SummaryRow(1, L["Materials"])
    detail.rivalValue, detail.rivalLabel = SummaryRow(2, L["Cheapest rival"])
    detail.ownValue, detail.ownLabel = SummaryRow(3, L["Your listing"])
    detail.postValue, detail.postLabel = SummaryRow(4, L["You post at"])
    detail.cutValue = SummaryRow(5, L["Auction cut"])
    detail.depositValue, detail.depositLabel = SummaryRow(6, L["Deposit"])
    detail.profitValue = SummaryRow(7, L["Profit"])
    -- What each way makes, when there is more than one. The one the
    -- profit above is for is lit.
    detail.wayRows = {
        auction = { SummaryRow(8, L["If sold at AH"]) },
        vendor = { SummaryRow(9, L["If vendored"]) },
        disenchant = { SummaryRow(10, L["If disenchanted"]) },
    }
    -- How long one takes, sub-crafts included, and the profit an hour.
    detail.timeValue = SummaryRow(11, L["Craft time"])
    detail.perHourValue = SummaryRow(12, L["A day"])

    -- What the craft breaks into, with each chance, under the mouse on the
    -- "If disenchanted" line (from the Enchanting tab, 2026-10-07).
    local breaks = CreateFrame("Frame", nil, summary)
    breaks:SetPoint("TOPLEFT", detail.wayRows.disenchant[2], "TOPLEFT", 0, 2)
    breaks:SetPoint("BOTTOMRIGHT", detail.wayRows.disenchant[1], "BOTTOMRIGHT", 0, -2)
    breaks:EnableMouse(true)
    breaks:SetScript("OnEnter", function(self) ShowBreaksInto(self, state.selected) end)
    breaks:SetScript("OnLeave", function() GameTooltip:Hide() end)
    detail.breaksInto = breaks

    -- Per-item posted limit. Sits with the queue controls because it is the
    -- thing that decides how many you should be adding.
    local limitLabel = Theme.CreateLabel(detail, "small", "muted")
    limitLabel:SetPoint("BOTTOMLEFT", 12, 46)
    limitLabel:SetText(L["Keep in stock"])
    detail.limitLabel = limitLabel

    detail.limitBox = Widgets.CreateNumberBox(detail, {
        width = 46, min = 0, max = 999,
        onChange = function(value)
            if not state.selected or not state.selected.outputItemID then return end
            -- Zero means "use the profession's number, or the usual one",
            -- which is what clearing the override does.
            ns.Auctions:SetLimit(state.selected.outputItemID,
                value > 0 and value or nil)
        end,
    })
    detail.limitBox:SetPoint("BOTTOMLEFT", 92, 42)

    -- What the box shows when this item has no number of its own: its
    -- profession's or the usual one, greyed, with where it comes from
    -- under the mouse (2026-10-13). The x puts an item's own number back.
    detail.limitBox:SetScript("OnEnter", function(self)
        Theme.SetBorderColor(self, "borderLit")
        if not (GameTooltip and self.sourceTip) then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L["Keep in stock"], Theme.Unpack("accent"))
        GameTooltip:AddLine(self.sourceTip, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    detail.limitBox:SetScript("OnLeave", function(self)
        Theme.SetBorderColor(self, "border")
        if GameTooltip then GameTooltip:Hide() end
    end)

    detail.limitClear = Widgets.CreateButton(detail, "x", function()
        if not state.selected or not state.selected.outputItemID then return end
        ns.Auctions:SetLimit(state.selected.outputItemID, nil)
    end, { width = 20, height = 20,
           tooltip = L["Use the usual number again"] })
    detail.limitClear:SetPoint("LEFT", detail.limitBox, "RIGHT", 4, 0)
    detail.limitClear:Hide()

    detail.limitHint = Theme.CreateLabel(detail, "tiny", "dim")
    detail.limitHint:SetPoint("LEFT", detail.limitBox, "RIGHT", 6, 0)
    -- Out to the pane's edge and onto a second line: "3 listed, 1 in mail,
    -- room for 2" is wider than the 144 there, and ended in "..." just
    -- where the room left was. Two lines, centred on the box, clear both
    -- the buttons below and the summary above; a third would not.
    detail.limitHint:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
    detail.limitHint:SetWordWrap(true)
    if detail.limitHint.SetMaxLines then detail.limitHint:SetMaxLines(2) end

    -- Queue controls
    local quantityBox = Theme.CreatePanel(detail, "row")
    quantityBox:SetSize(46, 24)
    quantityBox:SetPoint("BOTTOMLEFT", 12, 14)

    local quantity = CreateFrame("EditBox", nil, quantityBox)
    quantity:SetAllPoints(quantityBox)
    quantity:SetAutoFocus(false)
    quantity:SetNumeric(true)
    quantity:SetJustifyH("CENTER")
    quantity:SetFont(Theme.FONT, Theme.sizes.small, "")
    quantity:SetTextColor(Theme.Unpack("text"))
    quantity:SetText("1")
    quantity:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    quantity:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    detail.quantity = quantity

    local addButton = Widgets.CreateButton(detail, L["Add to queue"], function()
        if not state.selected then return end

        -- Whole crafts, one at least: Queue:Add clamps the same way, and the
        -- line printed should say what was queued.
        local count = math.max(1, math.floor(tonumber(quantity:GetText()) or 1))

        -- Max writes 0 when the stock limit leaves no room. Queue:Add would
        -- still make that one craft, which is not what the box says.
        if tonumber(quantity:GetText()) == 0 then
            ns.Print(L.Format("nothing queued: the amount for %s is 0",
                state.selected.name or L["that craft"]))
            return
        end

        local recipeID, name = state.selected.recipeID, state.selected.name
        ns.Queue:Add(recipeID, count)
        ns.Print(L.Format("queued %dx %s", count, name or L["craft"]))
        if ns.Demand then ns.Demand:WarnIfLow(state.selected.outputItemID, name) end

        -- Suggest again from what is now queued, as Max would. Left as it
        -- was, a second click queued the full amount again over the limit.
        -- Set here rather than by the redraw Queue:Add makes, which has
        -- already run by now and keeps the box as it was for the same craft.
        local fresh = ns.Profit:Analyse(recipeID, nil, Method())
        if fresh then
            quantity:SetText(tostring(ns.Profit.MaxCrafts(fresh.craftableNow, fresh.roomInCrafts,
                fresh.learnedRoomInCrafts)))
        end
    end, { width = 100, primary = true, height = 24 })
    GrowToFit(addButton)
    addButton:SetPoint("BOTTOMLEFT", quantityBox, "BOTTOMRIGHT", 8, 0)
    detail.addButton = addButton

    local maxButton = Widgets.CreateButton(detail, L["Max"], function()
        if not state.selected then return end

        -- Whichever runs out first: materials, or room under the limit.
        -- Room is counted in items and this box is counted in crafts, so it
        -- is the converted figure that may be compared against a craft count.
        local most = ns.Profit.MaxCrafts(state.selected.craftableNow,
            state.selected.roomInCrafts, state.selected.learnedRoomInCrafts)
        if most == 0 and state.selected.waitingForLow then
            ns.Print(L.Format("no more %s yet: Restock When Down To is on, so more are made once you are down to %d",
                state.selected.name or L["of that craft"], state.selected.restockAt or 0))
        elseif most == 0 then
            ns.Print(L.Format("no room for more %s: you already have your Max on hand (Keep in stock in Settings)",
                state.selected.name or L["of that craft"]))
        end

        quantity:SetText(tostring(most))
    end, { width = 44, height = 24,
           tooltip = L["As many as your materials and stock limit allow"] })
    GrowToFit(maxButton)
    maxButton:SetPoint("BOTTOMLEFT", addButton, "BOTTOMRIGHT", 8, 0)
    detail.maxButton = maxButton

    -- Takes the craft off this list for good, on every character. Settings
    -- lists what is ignored, with a Restore button for each.
    local ignoreButton = Widgets.CreateButton(detail, L["Ignore"], function()
        local analysis = state.selected
        if not analysis then return end

        -- Cleared first: SetIgnored redraws the tab, and the pane should
        -- not go on showing a craft the list no longer has.
        state.selected = nil
        ns.Profit:SetIgnored(analysis.recipeID, true, analysis.name)
        ns.Print(L.Format("ignored %s: it no longer shows on the Profit tab. Restore it under Ignored crafts in Settings.",
            analysis.name or L["that craft"]))
    end, { width = 60, height = 24,
           tooltip = L["Stops suggesting this craft. Restore it in Settings."] })
    GrowToFit(ignoreButton)
    ignoreButton:SetPoint("BOTTOMLEFT", maxButton, "BOTTOMRIGHT", 8, 0)
    detail.ignoreButton = ignoreButton

    local empty = Theme.CreateLabel(detail, "small", "dim", "CENTER")
    empty:SetPoint("CENTER")
    empty:SetText(L["Select a craft to see the breakdown"])
    detail.empty = empty

    return detail
end

-- How many material lines fit between the MATERIALS heading and the summary.
-- Six always fit, which is what is assumed when the pane has not been laid
-- out yet; a seventh ran into the summary.
local REAGENT_LINE_HEIGHT = 16
local REAGENT_LINES_FALLBACK = 6

local function ReagentRoom(detail)
    local ok, top, bottom = pcall(function()
        return detail.reagentHeading:GetBottom(), detail.summary:GetTop()
    end)
    if not (ok and type(top) == "number" and type(bottom) == "number") then
        return REAGENT_LINES_FALLBACK
    end

    -- 6 above the first line (its anchor offset) and a little air above the
    -- summary.
    return math.max(2, math.floor((top - bottom - 6 - 4) / REAGENT_LINE_HEIGHT))
end

--- Close the summary up around the rows that are hidden. "Your listing" with
--- nothing listed left a blank line between the prices; now a hidden row's
--- space goes to the top of the block, and the rows shown stay together just
--- above the queue controls, in their order.
--- The craft pane's time rows: how long one takes and the profit a day.
local function UpdateTimeRows(detail, analysis)
    if type(rawget(detail, "timeValue")) ~= "table" then return end
    local CraftTime = ns.CraftTime
    local seconds = analysis.timeSeconds or analysis.craftSeconds

    if analysis.perDay then
        detail.perHourValue:SetText(Util.FormatMoney(analysis.perDay))
        detail.perHourValue:SetTextColor(Theme.ProfitColor(analysis.perDay))
    else
        detail.perHourValue:SetText("--")
        detail.perHourValue:SetTextColor(Theme.Unpack("dim"))
    end

    if not CraftTime then
        detail.timeValue:SetText("--")
        return
    end

    -- A recipe this character does not know: nothing to time.
    if analysis.knownByMe == false then
        detail.timeValue:SetText("--")
        detail.timeValue:SetTextColor(Theme.Unpack("dim"))
        return
    end

    if seconds then
        local casts = analysis.craftTime and analysis.craftTime.casts or 1
        local text = CraftTime.Format(seconds)
        if casts > 1 + 1e-6 then
            local count = ("%.1f"):format(casts):gsub("%.0$", "")
            text = L.Format("%s  (%s casts)", text, count)
        end
        detail.timeValue:SetText(text)
        detail.timeValue:SetTextColor(Theme.Unpack("text"))
    else
        detail.timeValue:SetText(L["make one to learn it"])
        detail.timeValue:SetTextColor(Theme.Unpack("dim"))
    end
end

local function LayoutSummary(detail)
    local rows = detail.summaryRows
    local shown = {}

    for _, row in ipairs(rows) do
        if row.label:IsShown() then shown[#shown + 1] = row end
    end

    local skipped = #rows - #shown
    for position, row in ipairs(shown) do
        local y = -(skipped + position - 1) * SUMMARY_ROW_HEIGHT
        row.label:SetPoint("TOPLEFT", 0, y)
        row.value:SetPoint("TOPRIGHT", 0, y)
    end
end

-- The summary rows put away while the price graph shows: the cheapest
-- rival, your listing, the auction cut, the deposit and what each way
-- makes. "always" marks the rows that show for every craft.
local GRAPH_HIDES = {
    [2] = "always", [3] = "sometimes", [5] = "always", [6] = "always",
    [8] = "sometimes", [9] = "sometimes", [10] = "sometimes",
}

--- Show the price graph or the materials list, and fit the graph above the
--- summary rows that are shown.
local function UpdateGraph(detail, analysis)
    -- rawget: a test's stand-in frame answers any field with a function.
    if type(rawget(detail, "graph")) ~= "table" then return false end
    local showGraph = analysis ~= nil and ns.Config:Get("profitShowsGraph") == true

    detail.graphButton:SetShown(analysis ~= nil)
    detail.graphButton:SetText(showGraph and L["Materials"] or L["Price graph"])
    GrowToFit(detail.graphButton)
    detail.graphButton.tooltipText = not showGraph
        and L["The cheapest price hour by hour, and the best times to buy and sell"] or nil
    detail.reagentHeading:SetText(showGraph and L["PRICE HISTORY"] or L["MATERIALS"])
    detail.graph:SetShown(showGraph)

    -- With the graph up, only the summary's main rows show, so the graph
    -- has room to be read; the rest are back with the materials. Rows that
    -- are always there come back here; the others were set again just now.
    for index in pairs(GRAPH_HIDES) do
        local row = detail.summaryRows[index]
        if row and row.graphHidden then
            row.graphHidden = nil
            if GRAPH_HIDES[index] == "always" then
                row.label:Show()
                row.value:Show()
            end
        end
    end
    if not showGraph then
        LayoutSummary(detail)
        return false
    end
    for index in pairs(GRAPH_HIDES) do
        local row = detail.summaryRows[index]
        if row and row.label:IsShown() then
            row.graphHidden = true
            row.label:Hide()
            row.value:Hide()
        end
    end
    if type(rawget(detail, "breaksInto")) == "table" then detail.breaksInto:Hide() end
    LayoutSummary(detail)

    -- Hidden summary rows leave their room at the top of the block.
    local skipped = 0
    for _, row in ipairs(detail.summaryRows) do
        if not row.label:IsShown() then skipped = skipped + 1 end
    end
    if not detail.summary:IsShown() then skipped = #detail.summaryRows end

    detail.graph:ClearAllPoints()
    detail.graph:SetPoint("TOPLEFT", detail.reagentHeading, "BOTTOMLEFT", 0, -8)
    detail.graph:SetPoint("BOTTOMRIGHT", detail.summary, "TOPRIGHT", 0,
        6 - skipped * SUMMARY_ROW_HEIGHT)

    -- The craft first, then its materials, dearest line first.
    local items = {}
    if analysis.outputItemID then items[1] = analysis.outputItemID end
    for _, reagent in ipairs((analysis.cost and analysis.cost.reagents) or {}) do
        if reagent.itemID then items[#items + 1] = reagent.itemID end
    end
    detail.graph:SetItems(items, analysis.outputItemID)
    return true
end

--- Show the Disenchant button for a craft that is in the bags and can be
--- disenchanted, armed when it can be used now and saying why when not.
-- The heading's rule stops short of it.
local function UpdateDisenchantButton(detail, analysis)
    local button = rawget(detail, "disenchantButton")
    if type(button) ~= "table" or not ns.Disenchanter then return end

    local itemID = analysis and analysis.outputItemID
    local carried = itemID and analysis.disenchantable == true
        and ns.Disenchanter:FindSlot(itemID) ~= nil or false

    button:SetShown(carried)

    local rule = rawget(detail.reagentHeading, "rule")
    if type(rule) == "table" then
        local stop = carried and button or rawget(detail, "graphButton")
        rule:ClearAllPoints()
        rule:SetPoint("LEFT", detail.reagentHeading, "RIGHT", 6, 0)
        if type(stop) == "table" then
            rule:SetPoint("RIGHT", stop, "LEFT", -6, 0)
        else
            rule:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
        end
    end

    local disenchanter = ns.Disenchanter
    if not carried then
        if disenchanter.anchor == button then disenchanter:Disarm() end
        return
    end

    local check = disenchanter:Check(itemID)
    button:SetEnabledState(check.ok)
    button.tooltipText = check.ok
        and L.Format("Disenchant one %s from your bags.", analysis.name or L["item"]) or check.why

    if check.ok then
        disenchanter:Arm(button, itemID, check.bag, check.slot)
    elseif disenchanter.anchor == button then
        disenchanter:Disarm()
    end
end

function UpdateDetail(analysis)
    local detail = widgets.detail

    local hasSelection = analysis ~= nil
    detail.empty:SetShown(not hasSelection)

    -- A new craft starts the box at a suggestion; the same craft redrawn
    -- (a bag change, an auction update) keeps what was typed there.
    local newCraft = not analysis or detail.shownRecipeID ~= analysis.recipeID
    detail.shownRecipeID = analysis and analysis.recipeID or nil

    for _, line in ipairs(detail.reagentLines) do
        line.frame:Hide()
    end
    detail.moreLine:Hide()

    detail.title:SetShown(hasSelection)
    detail.statsItem = analysis and analysis.outputItemID or nil
    detail.stats:SetShown(detail.statsItem ~= nil)
    detail.subtitle:SetShown(hasSelection)
    detail.reagentHeading:SetShown(hasSelection)
    detail.maxButton:SetShown(hasSelection)
    detail.ignoreButton:SetShown(hasSelection)
    detail.icon:SetShown(hasSelection)
    detail.summary:SetShown(hasSelection)
    detail.addButton:SetShown(hasSelection)
    detail.limitLabel:SetShown(hasSelection)
    detail.limitBox:SetShown(hasSelection)
    detail.limitHint:SetShown(hasSelection)
    if not hasSelection then detail.limitClear:Hide() end
    detail.quantity:GetParent():SetShown(hasSelection)

    UpdateDisenchantButton(detail, analysis)

    if not hasSelection then
        UpdateCrafters(detail, nil)
        UpdateGraph(detail, nil)
        return
    end

    detail.title:SetText(analysis.name or L.Format("recipe %s", analysis.recipeID))
    -- In the rarity of what it makes, as its row is; gold for an enchant.
    if not Theme.SetItemNameColor(detail.title, analysis.outputItemID, "accent")
        and analysis.outputItemID then
        awaitingItemData = true
    end
    Theme.SetItemIcon(detail.icon, analysis.outputItemID)

    -- The skill-up clause is coloured inline rather than by the whole label,
    -- because the line already carries a colour of its own for materials.
    local skillUpText = ""
    local skillUp = analysis.skillUp

    if skillUp and skillUp.tier ~= "trivial" then
        skillUpText = ("  %s%s|r"):format(
            ns.SkillUp:GetTierColorCode(skillUp.tier), ns.SkillUp:GetTierLabel(skillUp.tier))
    end

    if analysis.craftableNow and analysis.craftableNow > 0 then
        detail.subtitle:SetText(L.Format("You can make %d now", analysis.craftableNow) .. skillUpText)
        detail.subtitle:SetTextColor(Theme.Unpack("profit"))
    else
        detail.subtitle:SetText(L["Missing materials"] .. skillUpText)
        detail.subtitle:SetTextColor(Theme.Unpack("muted"))
    end

    if not analysis.priceable then
        detail.summary:Hide()
        detail.subtitle:SetText(analysis.reason or L["cannot be priced"])
        detail.subtitle:SetTextColor(Theme.Unpack("warn"))
    end

    UpdateCrafters(detail, analysis)

    -- Reagent lines. When there are more than fit, the last line that fits
    -- says how many more there are instead.
    local y = -12
    local anchor = detail.reagentHeading

    local reagents = (analysis.cost and analysis.cost.reagents) or {}
    local shownCount = #reagents
    local room = ReagentRoom(detail)
    if shownCount > room then shownCount = room - 1 end

    for index = 1, shownCount do
        local reagent = reagents[index]
        local line = detail.reagentLines[index]

        if not line then
            local frame = CreateFrame("Frame", nil, detail)
            frame:SetHeight(16)

            local icon = Theme.CreateItemIcon(frame, 14)
            icon:SetPoint("LEFT", 0, 0)
            if Widgets.ItemHotspot then Widgets.ItemHotspot(icon, frame) end

            local name = Theme.CreateLabel(frame, "small", "text")
            name:SetPoint("LEFT", 18, 0)
            name:SetPoint("RIGHT", -70, 0)

            local value = Theme.CreateLabel(frame, "small", "muted", "RIGHT")
            value:SetPoint("RIGHT", 0, 0)

            line = { frame = frame, icon = icon, name = name, value = value }
            detail.reagentLines[index] = line
        end

        line.frame:ClearAllPoints()
        line.frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, index == 1 and -6 or 0)
        line.frame:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -12, 0)

        local label = Util.GetItemLabel(reagent.itemID)
        -- A link carries its rarity colour; a name before the client has the
        -- item is drawn again when it comes.
        if not label:find("|c", 1, true) then awaitingItemData = true end
        Theme.SetItemIcon(line.icon, reagent.itemID)
        -- Made by an alt and mailed here, priced at its materials.
        local maker = ns.Cost and ns.Cost.MadeByName and ns.Cost.MadeByName(reagent.madeBy)
        if maker then
            label = L.Format("%s (made by %s)", label, maker)
        end

        -- Showing have/need inline is the whole point: it answers "can I make
        -- this" without a second screen.
        if reagent.shortfall > 0 then
            line.name:SetText(("%dx %s"):format(reagent.quantity, label))
            line.value:SetText(L.Format("need %d", reagent.shortfall))
            line.value:SetTextColor(Theme.Unpack("loss"))
        elseif reagent.source == "mine" then
            -- Costed at the player's own price from the Prices tab.
            line.name:SetText(L.Format("%dx %s |c%s(my price)|r", reagent.quantity, label, ns.COLORS.warn))
            line.value:SetText(Util.FormatMoney(reagent.lineCost, { short = true }))
            line.value:SetTextColor(Theme.Unpack("warn"))
        else
            line.name:SetText(("%dx %s"):format(reagent.quantity, label))
            line.value:SetText(Util.FormatMoney(reagent.lineCost, { short = true }))
            line.value:SetTextColor(Theme.Unpack("muted"))
        end

        line.frame:Show()
        anchor = line.frame
        y = y - 16
    end

    if shownCount < #reagents then
        local more = detail.moreLine
        more:ClearAllPoints()
        more:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, shownCount == 0 and -6 or 0)
        more:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -12, 0)
        more.label:SetText(L.Format("+%d more materials", #reagents - shownCount))
        more.reagents = reagents
        more:Show()
    end

    if analysis.priceable then
        detail.summary:Show()
        detail.costValue:SetText(Util.FormatMoney(analysis.totalCost))

        if analysis.undercut then
            -- An item auction that cannot be undercut by less than a silver is
            -- matched instead, and the label says so rather than implying a
            -- price below the rival's.
            detail.rivalLabel:SetText(analysis.matchedRival
                and L["Matching rival"] or L["Cheapest rival"])
            detail.rivalValue:SetText(Util.FormatMoney(analysis.competitorPrice))
            detail.rivalValue:SetTextColor(Theme.Unpack("muted"))
        elseif analysis.priceUncontested then
            -- Nobody is competing, so the price above is the markup over
            -- materials rather than anything the book says. Checked before
            -- "You hold lowest" below, which is the same situation described
            -- less usefully: what matters is where the price came from.
            detail.rivalLabel:SetText(L["No competition"])
            detail.rivalValue:SetText(L["materials + markup"])
            detail.rivalValue:SetTextColor(Theme.Unpack("profit"))
        elseif analysis.youHoldLowest then
            -- Your own auction is the cheapest. Undercutting it would just walk
            -- your own price down, so we hold at market and say so.
            detail.rivalLabel:SetText(L["You hold lowest"])
            detail.rivalValue:SetText(L["no rival"])
            detail.rivalValue:SetTextColor(Theme.Unpack("profit"))
        elseif analysis.priceDerived then
            -- No scan has ever priced this one, so the sale price above is
            -- the material value plus the markup in Settings. Named
            -- differently from "None listed" below, which is an item the
            -- auction house has seen and simply has none of right now.
            detail.rivalLabel:SetText(L["Never scanned"])
            detail.rivalValue:SetText(L["from materials"])
            detail.rivalValue:SetTextColor(Theme.Unpack("warn"))
        elseif analysis.priceBasis == "vendor" then
            -- Nothing listed, and the price below is what a vendor pays:
            -- not an estimate, as "None listed" below would call it.
            detail.rivalLabel:SetText(L["None listed"])
            detail.rivalValue:SetText(L["no rival"])
            detail.rivalValue:SetTextColor(Theme.Unpack("muted"))
        else
            -- Nothing listed means no competition to undercut, so the number
            -- shown is an estimate rather than an observed price.
            detail.rivalLabel:SetText(L["None listed"])
            detail.rivalValue:SetText(L["estimate"])
            detail.rivalValue:SetTextColor(Theme.Unpack("warn"))
        end

        -- Your own listing, shown whenever you have one, so it is obvious
        -- whether the rival price above sits below or above where you already
        -- are. Hidden entirely when you have nothing listed.
        if analysis.ownListing then
            detail.ownLabel:Show()
            detail.ownValue:Show()
            detail.ownValue:SetText(Util.FormatMoney(analysis.ownListing))

            -- Undercut by a rival: your listing is not the one that sells.
            local beaten = analysis.competitorPrice
                and analysis.competitorPrice < analysis.ownListing
            detail.ownValue:SetTextColor(Theme.Unpack(beaten and "loss" or "profit"))
        else
            detail.ownLabel:Hide()
            detail.ownValue:Hide()
        end

        -- Valued at what a vendor pays when that beats the listing, which
        -- then takes no cut and no deposit. Disenchanted, the cut is the
        -- one on selling the materials, and there is no deposit.
        local toVendor = analysis.priceBasis == "vendor"
        local toEnchanter = analysis.priceBasis == "disenchant"

        detail.postLabel:SetText(toVendor and L["Vendor pays"]
            or toEnchanter and L["Disenchants to"] or L["You post at"])
        detail.postValue:SetText(Util.FormatMoney(analysis.unitRevenue))
        detail.postValue:SetTextColor(Theme.Unpack("accent"))

        if toVendor then
            detail.cutValue:SetText(L["none"])
            detail.cutValue:SetTextColor(Theme.Unpack("dim"))
        else
            detail.cutValue:SetText("-" .. Util.FormatMoney(analysis.cut))
            detail.cutValue:SetTextColor(Theme.Unpack("text"))
        end

        -- Only known once the item has been priced at an auction house.
        if toVendor or toEnchanter then
            detail.depositLabel:SetText(L["Deposit"])
            detail.depositValue:SetText(L["none"])
            detail.depositValue:SetTextColor(Theme.Unpack("dim"))
        elseif analysis.depositKnown and (analysis.deposit or 0) <= 0 and analysis.depositHeld then
            -- Paid when listing and handed back with the sale, so it costs
            -- nothing here. Shown so the player knows to have it on hand.
            detail.depositLabel:SetText(L["Deposit"])
            detail.depositValue:SetText(L.Format("%s, back when it sells", Util.FormatMoney(analysis.depositHeld)))
            detail.depositValue:SetTextColor(Theme.Unpack("dim"))
        elseif analysis.depositKnown then
            detail.depositLabel:SetText(L["Deposit"])
            detail.depositValue:SetText("-" .. Util.FormatMoney(analysis.deposit))
            detail.depositValue:SetTextColor(Theme.Unpack("muted"))
        else
            detail.depositLabel:SetText(L["Deposit"])
            detail.depositValue:SetText(L["unknown"])
            detail.depositValue:SetTextColor(Theme.Unpack("dim"))
        end

        detail.profitValue:SetText(Util.FormatMoney(analysis.profit))
        detail.profitValue:SetTextColor(Theme.ProfitColor(analysis.profit))

        -- What each way makes, when there is more than one to compare.
        -- Something that can be disenchanted but whose materials have no
        -- price yet says so on its row.
        local lines = ns.Profit.DescribeWays and ns.Profit:DescribeWays(analysis) or {}
        local byWay = {}
        for _, line in ipairs(lines) do byWay[line.way] = line end

        for way, pair in pairs(detail.wayRows) do
            local value, label = pair[1], pair[2]
            local line = byWay[way]
            local unscanned = way == "disenchant" and analysis.disenchantable == true
                and not analysis.disenchantValue

            label:SetShown(line ~= nil or unscanned)
            value:SetShown(line ~= nil or unscanned)
            if way == "disenchant" and type(rawget(detail, "breaksInto")) == "table" then
                detail.breaksInto:SetShown(line ~= nil)
            end

            if line then
                local text = Util.FormatMoney(line.profit, { short = true })
                if line.note then text = text .. "  " .. line.note end
                value:SetText(text)
                value:SetTextColor(Theme.ProfitColor(line.profit))
                label:SetTextColor(Theme.Unpack(line.chosen and "accent" or "muted"))
            elseif unscanned then
                value:SetText(L["materials not scanned"])
                value:SetTextColor(Theme.Unpack("dim"))
                label:SetTextColor(Theme.Unpack("muted"))
            end
        end

        UpdateTimeRows(detail, analysis)

        LayoutSummary(detail)
    end

    -- After the summary, which decides how much room the graph has.
    if UpdateGraph(detail, analysis) then
        for _, line in ipairs(detail.reagentLines) do line.frame:Hide() end
        detail.moreLine:Hide()
    end

    -- Limit control reflects the override if there is one, else the default.
    if analysis.outputItemID then
        detail.limitLabel:Show()
        detail.limitBox:Show()
        detail.limitHint:Show()

        -- Not over a number being typed: a bag update mid-typing put the
        -- old limit back and the next key landed after it (1, then 5 from
        -- the redraw, then 2, saved as 52). A different craft does replace
        -- it, and drops the half-typed number with it.
        local box = detail.limitBox
        local typing = box.editBox.HasFocus and box.editBox:HasFocus()
        if not typing then
            box:SetValue(analysis.baseLimit or analysis.postLimit or 0, true)
        elseif newCraft then
            box:SetValue(analysis.baseLimit or analysis.postLimit or 0, true)
            box.editBox:ClearFocus()
        end

        -- Whose number it is: the item's own in white with its x, else
        -- greyed, its profession's or the usual one.
        local source, profession, professionName
        if ns.Auctions.GetLimit then
            local ok, _, from, name = pcall(ns.Auctions.GetLimit, ns.Auctions, analysis.outputItemID)
            if ok then source, profession = from, name end
        end
        if profession and ns.Auctions.ProfessionLabel then
            professionName = ns.Auctions:ProfessionLabel(profession)
        end
        professionName = professionName or profession
        local own = source == "item"
        box.editBox:SetTextColor(Theme.Unpack(own and "text" or "dim"))
        local raised = own and ns.SellOut and ns.SellOut.GetRaised
            and ns.SellOut:GetRaised(analysis.outputItemID)
        if raised and raised.lowered and ns.db.postLimits and raised.to == ns.db.postLimits[analysis.outputItemID] then
            box.sourceTip = L.Format("Lowered from %d to %d because it came back unsold 3 times in a row. Click x to use the usual number again.",
                raised.from or 0, raised.to or 0)
        elseif raised and ns.db.postLimits and raised.to == ns.db.postLimits[analysis.outputItemID] then
            box.sourceTip = L.Format("Raised from %d to %d because every copy you listed sold. Click x to use the usual number again.",
                raised.from or 0, raised.to or 0)
        elseif own then
            box.sourceTip = L["Set for this item only. Click x to use the usual number again."]
        elseif source == "profession" then
            box.sourceTip = L.Format("From %s in Settings. Type a number to set it for this item only.", professionName)
        else
            box.sourceTip = L["The usual amount from Settings. Type a number to set it for this item only."]
        end
        detail.limitClear:SetShown(own)
        detail.limitHint:ClearAllPoints()
        detail.limitHint:SetPoint("LEFT", own and detail.limitClear or box, "RIGHT", 6, 0)
        detail.limitHint:SetPoint("RIGHT", detail, "RIGHT", -12, 0)

        -- Spell out where the stock is, so a hidden craft is explicable.
        local parts = {}
        if (analysis.posted or 0) > 0 then
            parts[#parts + 1] = L.Format("%d listed", analysis.posted)
        end
        if (analysis.onHand or 0) > 0 then
            parts[#parts + 1] = L.Format("%d held", analysis.onHand)
        end
        -- Named separately from "held": an item in the mailbox is one that came
        -- back from a listing that did not sell, which is worth knowing.
        if (analysis.inMail or 0) > 0 then
            parts[#parts + 1] = L.Format("%d in mail", analysis.inMail)
        end
        if (analysis.queuedElsewhere or 0) > 0 then
            parts[#parts + 1] = L.Format("%d queued", analysis.queuedElsewhere)
        end

        local where = #parts > 0 and table.concat(parts, ", ") or L["none yet"]
        if source == "profession" then
            where = L.Format("From %s. %s", professionName, where)
        end
        -- A fast seller's limit is the box's number plus the extra; said
        -- here, since the box shows only the number set.
        if (analysis.fastSellerExtra or 0) > 0 then
            where = L.Format("%s, +%d fast seller", where, analysis.fastSellerExtra)
        end

        if analysis.postLimit and analysis.postLimit > 0 and analysis.waitingForLow then
            detail.limitHint:SetText(L.Format("%s, restock at %d", where, analysis.restockAt or 0))
            detail.limitHint:SetTextColor(Theme.Unpack("warn"))
        elseif analysis.postLimit and analysis.postLimit > 0 then
            detail.limitHint:SetText(L.Format("%s, room for %d", where, analysis.postRoom or 0))
            detail.limitHint:SetTextColor(Theme.Unpack(
                analysis.atPostLimit and "warn" or "dim"))
        elseif analysis.learnedLimit then
            -- No number set: Queue All keeps what your sales taught.
            detail.limitHint:SetText(L.Format("%s, learned %d from your sales", where, analysis.learnedLimit))
            detail.limitHint:SetTextColor(Theme.Unpack("dim"))
        elseif (analysis.stockDivisor or 1) > 1 then
            -- Say out loud that the list order is not pure profit. A craft
            -- sitting lower than its profit suggests, with no explanation, is
            -- exactly the sort of thing that reads as a bug.
            detail.limitHint:SetText(L.Format("%s, so ranked as %s",
                where, Util.FormatMoney(
                    (analysis.profit or 0) > 0
                        and (analysis.profit / analysis.stockDivisor)
                        or analysis.profit)))
            detail.limitHint:SetTextColor(Theme.Unpack("dim"))
        elseif #parts > 0 then
            detail.limitHint:SetText(where)
            detail.limitHint:SetTextColor(Theme.Unpack("dim"))
        else
            detail.limitHint:SetText(source == "profession" and where or L["none on hand"])
            detail.limitHint:SetTextColor(Theme.Unpack("dim"))
        end
    else
        detail.limitLabel:Hide()
        detail.limitBox:Hide()
        detail.limitClear:Hide()
        detail.limitHint:Hide()
    end

    -- Crafts, not items, and what Max would write: 0 once the limit is
    -- reached. Floored at 1, the box said 1 at "room for 0" and Add queued
    -- one past the limit.
    local suggested = ns.Profit.MaxCrafts(analysis.craftableNow, analysis.roomInCrafts,
        analysis.learnedRoomInCrafts)
    if newCraft then detail.quantity:SetText(tostring(suggested)) end

    if analysis.atPostLimit then
        -- Queued crafts count toward the limit too, and "You already have 0,
        -- your limit" read as nonsense when they were all that filled it.
        local queued = analysis.queuedElsewhere or 0
        if analysis.waitingForLow then
            detail.subtitle:SetText(L.Format("You have %d, more once you are down to %d",
                (analysis.stock or 0) + queued, analysis.restockAt or 0))
        elseif queued > 0 then
            detail.subtitle:SetText(L.Format("You have %d and %d more queued, your limit",
                analysis.stock or 0, queued))
        else
            detail.subtitle:SetText(L.Format("You already have %d, your limit",
                analysis.stock or 0))
        end
        detail.subtitle:SetTextColor(Theme.Unpack("warn"))
    end
end

--------------------------------------------------------------------------------
-- Filtering
--------------------------------------------------------------------------------

--- Mirror the row layout onto the column headings.
--- Work out which columns fit the headings' width (the list's); a width
--- not known yet sets nothing aside. A change moves layoutVersion, so the
--- rows lay themselves out again on their next draw.
local function Squeeze()
    local frame = widgets.headingFrame
    local ok, room = pcall(function() return frame and frame:GetWidth() end)
    squeezed = {}
    for key in pairs(ns.Columns:Squeeze("profit", COLUMNS, ok and room or nil, {
        order = SQUEEZE_ORDER, nameMin = NAME_MIN,
        left = 8 + MARK_GUTTER + ICON_GUTTER + 4, visible = ColumnWanted })) do
        squeezed[key] = true
    end
    local keys = {}
    for _, key in ipairs(SQUEEZE_ORDER) do
        if squeezed[key] then keys[#keys + 1] = key end
    end
    local key = table.concat(keys, ",")
    if key ~= squeezedKey then
        squeezedKey = key
        layoutVersion = layoutVersion + 1
    end
end

ApplyHeadingLayout = function()
    if not widgets.headings then return end
    Squeeze()

    local offset = -8
    for _, column in ipairs(COLUMNS) do
        local heading = widgets.headings[column.key]

        if IsColumnVisible(column) then
            heading:SetPoint("RIGHT", offset, 0)
            heading:SetWidth(column.width)
            heading:Show()
            offset = offset - column.width - 6
        else
            heading:Hide()
        end
    end

    if widgets.sorter then widgets.sorter:Sync() end
end

--- What the list's order was worked out for. While it stays the same, rows
--- keep their places: queueing a craft counts it as stock you will have and
--- ranks it lower, so a right-click to queue dropped the row from under the
--- cursor and the next click queued a different craft. The order is worked
--- out afresh when a filter, the sort or the search changes, or when the tab
--- is opened again.
local function OrderKey()
    return table.concat({ tostring(state.accountWide), tostring(state.ignorePostLimit),
        tostring(state.sortBy), tostring(state.craftableOnly),
        tostring(state.includeUnpriceable), tostring(state.profession),
        tostring(Method()), state.search or "" }, "|")
end

local function BuildList()
    local key = OrderKey()
    if key ~= state.orderKey then
        state.orderKey, state.heldOrder = key, nil
    end

    local ranked = ns.Profit:GetRanked({
        accountWide = state.accountWide,
        ignorePostLimit = state.ignorePostLimit,
        sortBy = state.sortBy,
        craftableOnly = state.craftableOnly,
        includeUnpriceable = state.includeUnpriceable,
        skillLineID = state.profession,
        method = Method(),
        keepOrder = state.heldOrder,
    })

    if state.search ~= "" then
        local needle = state.search:lower()
        local filtered = {}

        for _, analysis in ipairs(ranked) do
            if (analysis.name or ""):lower():find(needle, 1, true) then
                filtered[#filtered + 1] = analysis
            end
        end
        ranked = filtered
    end

    state.heldOrder = {}
    for index, analysis in ipairs(ranked) do
        state.heldOrder[analysis.recipeID] = index
    end

    return ranked
end

local function Refresh()
    if not widgets.list then return end

    local data = BuildList()

    -- A clicked heading's order over the ranking's.
    if widgets.sorter then data = widgets.sorter:Sort(data) end

    -- The DISENCHANT column earns its space only when something listed can
    -- be disenchanted: an alchemist's list would otherwise carry an empty one.
    local anyDisenchantable = false
    for _, analysis in ipairs(data) do
        if analysis.disenchantable then
            anyDisenchantable = true
            break
        end
    end

    if anyDisenchantable ~= state.showDisenchant then
        state.showDisenchant = anyDisenchantable
        layoutVersion = layoutVersion + 1
        ApplyHeadingLayout()
    end

    -- Rows set this again while they draw if an item is still uncached.
    awaitingItemData = false
    widgets.list:SetData(data)

    widgets.emptyLabel:SetShown(#data == 0)
    widgets.emptyScan:Hide()

    if #data == 0 then
        if ns.Recipes:Count() == 0 then
            widgets.emptyLabel:SetText(L["Open a profession window once so your recipes can be read."])
        elseif ns.Prices:Count() == 0 then
            widgets.emptyLabel:SetText(L["No auction data yet."])
            widgets.emptyScan:Show()
        else
            -- "Nothing matches these filters" is true and useless. A threshold
            -- set once and forgotten now survives logout, so the message says
            -- which one is doing the hiding and what it would take to see them.
            local hidden = ns.Profit:GetRanked({
                accountWide = state.accountWide,
                ignorePostLimit = state.ignorePostLimit,
                craftableOnly = state.craftableOnly,
                includeUnpriceable = state.includeUnpriceable,
                skillLineID = state.profession,
                method = Method(),
                minProfit = 0,
                minMargin = 0,
            })

            local minProfit = ns.Config:Get("minProfit") or 0
            local minMargin = ns.Config:Get("minMarginPercent") or 0

            -- A search that matches nothing says so first: the minimums
            -- message would be about crafts the search never named.
            if state.search ~= "" then
                widgets.emptyLabel:SetText(L.Format("Nothing matching \"%s\".", state.search))
            elseif #hidden > 0 and (minProfit > 0 or minMargin > 0) then
                local best = hidden[1]

                local floor = Util.FormatMoney(minProfit, { noColor = true, short = true })
                local bestText = Util.FormatMoney(best.profit or 0, { noColor = true, short = true })
                widgets.emptyLabel:SetText(#hidden == 1
                    and L.Format("%d craft hidden by your minimums in Settings (%s profit, %d%% margin).\nThe best right now makes %s.",
                        #hidden, floor, minMargin, bestText)
                    or L.Format("%d crafts hidden by your minimums in Settings (%s profit, %d%% margin).\nThe best right now makes %s.",
                        #hidden, floor, minMargin, bestText))

            else
                widgets.emptyLabel:SetText(L["Nothing matches these filters."])
            end
        end
    end

    -- Keep the detail panel in step with the refreshed numbers.
    if state.selected then
        -- Written back, so Max reads what can be made now and not what could
        -- be made when the row was clicked.
        local fresh = ns.Profit:Analyse(state.selected.recipeID, nil, Method())
        if fresh then state.selected = fresh end
        UpdateDetail(fresh)
    else
        UpdateDetail(nil)
    end

    local ignored = ns.Profit.GetIgnored and #ns.Profit:GetIgnored() or 0
    widgets.countLabel:SetText((#data == 1 and L.Format("%d craft", #data) or L.Format("%d crafts", #data))
        .. (ignored > 0 and L.Format(", %d ignored", ignored) or ""))
    FitHint()
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

--- Fill the profession dropdown from the skill lines the listed recipes carry.
--
-- Built from the recipes themselves, not from the profession list. Forever
-- reports each profession under two skill-line IDs (Leatherworking is both
-- 2945 and 165) and a recipe may be tagged with either, so matching the two
-- lists against each other drops entries.
--
-- With "All characters" ticked the list shows every character's recipes, so
-- the choices come from all of them too; otherwise an alt's profession could
-- not be picked at all.
local function RefreshProfessionOptions()
    local dropdown = widgets.professionDropdown
    if not dropdown then return end

    local recipes = state.accountWide and ns.Recipes:GetAccountWide(true) or ns.Recipes:GetAll()

    -- Names the characters' own profession reads saved, for a skill line the
    -- client will not name for this character.
    local savedNames = {}
    for _, record in pairs(ns.db and ns.db.characters or {}) do
        if type(record) == "table" and type(record.professions) == "table" then
            for _, profession in ipairs(record.professions) do
                if type(profession) == "table" and profession.skillLineID and profession.name then
                    savedNames[profession.skillLineID] = profession.name
                end
            end
        end
    end

    local options = { { text = L["All professions"], value = nil } }

    local seen = {}
    for _, recipe in pairs(recipes) do
        local skillLineID = recipe.skillLineID

        -- A dropped profession has no crafts left to list. The account-wide
        -- list has already left out each character's own dropped ones.
        if not state.accountWide and ns.Recipes:IsDropped(recipe) then skillLineID = nil end

        if skillLineID and not seen[skillLineID] then
            seen[skillLineID] = true

            local name
            if ns.Util.HasFunction("C_TradeSkillUI.GetProfessionInfoBySkillLineID") then
                local ok, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, skillLineID)
                if ok and info and info.professionName ~= "" then name = info.professionName end
            end

            options[#options + 1] = {
                text = name or savedNames[skillLineID]
                    or (ns.EraRecipes and ns.EraRecipes:LineName(skillLineID))
                    or (ns.RecipeBook and ns.RecipeBook:ProfessionName(skillLineID))
                    or L.Format("Skill line %s", skillLineID),
                value = skillLineID,
            }
        end
    end

    table.sort(options, function(a, b)
        if a.value == nil then return true end
        if b.value == nil then return false end
        return a.text < b.text
    end)

    dropdown:SetOptions(options)

    -- Unticking can take away the profession that was picked. The dropdown
    -- falls back to "All professions" on its own, and the filter has to
    -- follow it or the list would stay filtered to a choice no longer shown.
    state.profession = dropdown:GetValue()

    -- And named on its face. The dropdown writes that only when the choice
    -- changes, and "All professions" is already the choice when the tab
    -- first opens, so the face stayed blank until something was picked.
    dropdown:SetValue(state.profession)
end

local function BuildCrafts(container)
    -- Before any row or heading is laid out: they read these widths.
    if Widgets.FitColumns then Widgets.FitColumns(COLUMNS) end

    -- Toolbar
    local toolbar = CreateFrame("Frame", nil, container)
    toolbar:SetPoint("TOPLEFT", 8, -8)
    toolbar:SetPoint("TOPRIGHT", -8, -8)
    toolbar:SetHeight(24)

    -- Every tab's option bar runs dropdowns, then search, then tick boxes
    -- (a player's request, 2026-10-06). The headings do the sorting.
    local profession = Widgets.CreateDropdown(toolbar, { { text = L["All professions"], value = nil } },
        function(value)
            state.profession = value
            Refresh()
        end, { width = 150 })
    profession:SetPoint("LEFT", 0, 0)
    widgets.professionDropdown = profession

    -- What the profit is for (2026-10-06): whichever way pays
    -- most, or one way alone. Kept in Settings, so /bts top and /bts why
    -- rank the same way, and the Level Up tab counts what a craft gets
    -- back by it too.
    local labels = ns.Profit.WAY_LABELS or {}
    local methodOptions = { { text = L["Profit: Best"], value = "best" } }
    for _, method in ipairs(ns.Profit.METHODS or {}) do
        if labels[method] then
            methodOptions[#methodOptions + 1] = { text = L.Format("Profit: %s", labels[method]), value = method }
        end
    end

    local method = Widgets.CreateDropdown(toolbar, methodOptions, function(value)
        ns.Config:Set("profitBy", value)

        -- VIA shows only when ranked by whichever pays most.
        layoutVersion = layoutVersion + 1
        ApplyHeadingLayout()

        Refresh()

        -- The pane beside the profession window counts the same way.
        local pane = ns.CraftPanel
        if pane and pane.RequestRefresh and pane.IsShown and pane:IsShown() then
            pane:RequestRefresh()
        end
    end, { width = 140 })
    method:SetPoint("LEFT", profession, "RIGHT", 8, 0)
    method:SetValue(Method() or "best")
    widgets.methodDropdown = method

    local search = Widgets.CreateSearchBox(toolbar, L["Search crafts"], function(text)
        state.search = text or ""
        Refresh()
    end)
    search:SetPoint("LEFT", method, "RIGHT", 8, 0)
    search:SetWidth(Widgets.SEARCH_WIDTH)

    local craftable = Widgets.CreateCheckbox(toolbar, L["Craftable now"], function(checked)
        state.craftableOnly = checked
        Refresh()
    end, false)
    craftable:SetPoint("LEFT", search, "RIGHT", 12, 0)

    local unpriceable = Widgets.CreateCheckbox(toolbar, L["Show unpriced"], function(checked)
        state.includeUnpriceable = checked
        Refresh()
    end, false)
    unpriceable:SetPoint("LEFT", craftable, "RIGHT", 12, 0)

    local accountWide = Widgets.CreateCheckbox(toolbar, L["All characters"], function(checked)
        state.accountWide = checked
        RefreshProfessionOptions()

        -- The WHO column appears or disappears with this.
        layoutVersion = layoutVersion + 1
        ApplyHeadingLayout()

        Refresh()
    end, false)
    accountWide:SetPoint("LEFT", unpriceable, "RIGHT", 12, 0)

    local showMaxed = Widgets.CreateCheckbox(toolbar, L["Show maxed"], function(checked)
        state.ignorePostLimit = checked
        Refresh()
    end, false)
    showMaxed:SetPoint("LEFT", accountWide, "RIGHT", 12, 0)

    -- TIME and A DAY (asked 2026-10-09; A DAY was GOLD/HR until
    -- 2026-10-16). Kept in Settings (the key still says per hour); off, the
    -- craft names keep their room. The craft pane always shows both.
    local perHour = Widgets.CreateCheckbox(toolbar, L["Per day"], function(checked)
        ns.Config:Set("profitShowsPerHour", checked == true)
        layoutVersion = layoutVersion + 1
        ApplyHeadingLayout()
        Refresh()
    end, ns.Config:Get("profitShowsPerHour") == true)
    perHour:SetPoint("LEFT", showMaxed, "RIGHT", 12, 0)

    -- Column headings
    local headings = CreateFrame("Frame", nil, container)
    headings:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -8)
    headings:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", -DETAIL_WIDTH - 8, -8)
    headings:SetHeight(16)
    widgets.headingFrame = headings

    -- The width is known only once the window is laid out, and Text size
    -- or a scale change can move it: fit the columns again then.
    headings:SetScript("OnSizeChanged", function()
        local before = squeezedKey
        ApplyHeadingLayout()
        if squeezedKey ~= before and widgets.list then widgets.list:Refresh() end
    end)

    local nameHeading = Theme.CreateLabel(headings, "tiny", "muted")
    nameHeading:SetPoint("LEFT", 8 + MARK_GUTTER + ICON_GUTTER, 0)
    nameHeading:SetText(L["CRAFT"])

    widgets.headings = {}
    for _, column in ipairs(COLUMNS) do
        local heading = Theme.CreateLabel(headings, "tiny", "muted", column.justify or "RIGHT")
        heading:SetText(column.label)
        widgets.headings[column.key] = heading
    end

    -- Click a heading to sort by it.
    local sortLabels = { name = nameHeading }
    for key, heading in pairs(widgets.headings) do sortLabels[key] = heading end
    widgets.sorter = Widgets.SortableHeadings and Widgets.SortableHeadings(sortLabels, {
        name = function(a) return a.name end,
        -- What the cells show: one craft's cost and what it sells for. Per
        -- item, a craft that makes several sorted out of step with its row.
        cost = function(a) return a.priceable and a.totalCost or nil end,
        sells = function(a) return a.priceable and a.revenue or nil end,
        profit = function(a) return a.priceable and a.profit or nil end,
        margin = function(a) return a.priceable and a.margin or nil end,
        age = function(a) return a.age end,
        posted = function(a) return a.stock end,
        make = function(a) return a.craftableNow end,
        who = function(a) return a.ownerName end,
        disenchant = function(a) return a.disenchantValue end,
        via = function(a) return a.via end,
        time = function(a) return a.timeSeconds or a.craftSeconds end,
        perHour = function(a) return a.perDay end,
        demand = function(a)
            return ns.Demand and ns.Demand:Rank(ns.Demand:Get(a.outputItemID)) or 0
        end,
    }, function() Refresh() end)
    if widgets.sorter then widgets.sorter:SetText({ "name", "who", "via" }) end

    ApplyHeadingLayout()

    -- Right-click the headings to choose the columns.
    ns.Columns:Attach(headings, "profit", widgets.sorter)
    ns.Columns:OnChange("profit", function()
        layoutVersion = layoutVersion + 1
        ApplyHeadingLayout()
        if widgets.list then widgets.list:Refresh() end
    end)

    local divider = Theme.CreateDivider(container, "borderLit")
    divider:SetPoint("TOPLEFT", headings, "BOTTOMLEFT", 0, -2)
    divider:SetPoint("TOPRIGHT", headings, "BOTTOMRIGHT", 0, -2)

    -- List
    local list = Widgets.CreateScrollList(container, {
        -- The headings move in with the rows when the scrollbar takes its room.
        onScrollbarShown = function(shown)
            headings:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", -DETAIL_WIDTH - 8 - (shown and 10 or 0), -8)
        end,
        rowHeight = ROW_HEIGHT,
        createRow = CreateRow,
        updateRow = UpdateRow,

        -- Every row shows the item it makes, as the bags would. A starred
        -- row adds why it wears the star underneath.
        onEnter = function(row, analysis)
            if analysis.recommended and analysis.skillUp then
                ShowMarkTooltip(row, analysis)
            else
                Widgets.ShowItemOnly(row, analysis.outputItemID, analysis.name)
            end
            if not AddWaysLines(analysis) then AddDisenchantLine(analysis) end
            AddTimeLines(analysis)
            AddPerDayLine(analysis)
            AddStockLine(analysis)
            AddOwnerLine(analysis)
        end,

        onLeave = function() GameTooltip:Hide() end,

        -- The row the detail pane is showing stays lit.
        isSelected = function(entry)
            return state.selected ~= nil and entry.recipeID == state.selected.recipeID
        end,

        onClick = function(analysis, _, mouseButton)
            if mouseButton == "RightButton" then
                -- Right-click is the fast path: queue one without leaving the list.
                ns.Queue:Add(analysis.recipeID, 1)
                ns.Print(L.Format("queued 1x %s", analysis.name or L["craft"]))
                if ns.Demand then ns.Demand:WarnIfLow(analysis.outputItemID, analysis.name) end
                return
            end

            state.selected = analysis
            UpdateDetail(ns.Profit:Analyse(analysis.recipeID, nil, Method()))
        end,
    })

    list:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -4)
    list:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -DETAIL_WIDTH - 16, 24)
    widgets.list = list

    local emptyLabel = Theme.CreateLabel(container, "small", "dim", "CENTER")
    emptyLabel:SetPoint("CENTER", list, "CENTER", 0, 10)
    emptyLabel:SetWidth(320)
    emptyLabel:SetWordWrap(true)
    widgets.emptyLabel = emptyLabel

    -- When there is simply no data, the fix is one click away; put it here
    -- rather than making the player go hunting for the header.
    local emptyScan = Widgets.CreateButton(container, L["Scan auctions"], function()
        UI:TriggerScan()
    end, { width = 130, height = 26, primary = true })
    GrowToFit(emptyScan)
    emptyScan:SetPoint("TOP", emptyLabel, "BOTTOM", 0, -12)
    emptyScan:Hide()
    widgets.emptyScan = emptyScan

    local countLabel = Theme.CreateLabel(container, "tiny", "dim")
    countLabel:SetPoint("BOTTOMLEFT", 8, 8)
    widgets.countLabel = countLabel

    -- Queues every row on screen, so the filters and search above decide
    -- what it covers. Each craft goes up to its Max on hand, less what is
    -- already held, listed, in the mail or queued.
    local queueAll = Widgets.CreateButton(container, L["Queue All"], function()
        local rows = BuildList()
        local crafts, items, noLimit, learned = ns.Queue:AddUpToLimit(rows)

        if crafts > 0 then
            ns.Print(L.Format("queued %d %s (%d %s) from %d listed%s",
                crafts, crafts == 1 and L["craft"] or L["crafts"],
                items, items == 1 and L["item"] or L["items"], #rows,
                (learned or 0) > 0 and L[", topping up what sells for you"] or ""))
        elseif #rows == 0 then
            ns.Print(L["nothing listed to queue"])
        elseif noLimit == #rows and not ns.Auctions:LearnsFromSales() then
            ns.Print(L["nothing queued: none of these has a Keep in stock number, so set one per item in Settings"])
        elseif noLimit == #rows then
            ns.Print(L["nothing queued: none of these has sold for you this week, so set Keep in Stock in Settings"])
        else
            local waiting = false
            for _, row in ipairs(rows) do
                if row.waitingForLow then waiting = true break end
            end
            if waiting then
                ns.Print(L["nothing queued: every listed craft is at its Max on hand or waiting until it runs low"])
            else
                ns.Print(L["nothing queued: every listed craft is already at its Max on hand"])
            end
        end
    end, { width = 90, height = 20,
           tooltip = L["Queues every craft in this list up to Keep in Stock, less what you have or have queued."] })
    GrowToFit(queueAll)
    queueAll:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -DETAIL_WIDTH - 16, 2)
    widgets.queueAll = queueAll

    local hint = Theme.CreateLabel(container, "tiny", "dim", "RIGHT")
    hint:SetPoint("RIGHT", queueAll, "LEFT", -10, 0)
    hint:SetText(HINT_TEXTS[1])
    widgets.hint = hint

    -- Detail panel
    local detail = BuildDetail(container)
    detail:SetPoint("TOPRIGHT", container, "TOPRIGHT", -8, -40)
    detail:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -8, 8)
    widgets.detail = detail

    UpdateDetail(nil)

    -- A rarity colour needs the client to have the item, and it may not when
    -- the list is first drawn. Redraw once the missing ones arrive, coalescing
    -- a burst of arrivals into a single pass and doing nothing at all unless a
    -- visible row is actually waiting.
    local redrawQueued = false

    ns.RegisterEvent(UI, "GET_ITEM_INFO_RECEIVED", function()
        if redrawQueued or not awaitingItemData then return end
        if not widgets.list:IsVisible() then return end

        redrawQueued = true
        C_Timer.After(0.2, function()
            redrawQueued = false
            Refresh()
        end)
    end)
end

--------------------------------------------------------------------------------
-- Views: your crafts, and recipes to learn
--------------------------------------------------------------------------------

-- Recipes to learn (UI/RecipeBookView.lua) was asked for 2026-10-05: every
-- recipe of a profession you have not learned, and whether it is worth
-- getting. It is the same question as this tab's, asked before the recipe
-- is bought, so it lives here behind a switch like the Characters tab's.
-- Without that file (the tests load this one alone) the tab is the crafts.
local switch = ns.RecipeBookView and ns.RecipeBookView.WithSwitch({
    mainKey = "crafts",
    mainText = L["MY CRAFTS"],
    mainTip = L["The crafts you know, by profit"],
    buildMain = BuildCrafts,
    refreshMain = Refresh,
    corner = function(parent)
        return ns.Upgrades and ns.Upgrades.CreateAltCheckbox and ns.Upgrades:CreateAltCheckbox(parent)
    end,
    -- Your time (UI/YourTimeView.lua, the owner said build it 2026-10-15):
    -- farming a craft's materials against selling them and buying them.
    -- Shuffles (UI/ShuffleView.lua, the owner said build it 2026-10-25):
    -- every way to turn one item into gold, after RECIPES TO LEARN.
    extras = (function()
        local list = {}
        if ns.YourTimeView then
            list[#list + 1] = { key = "time", text = L["YOUR TIME"],
                tip = L["Farm it, sell the mats, or buy them: which pays best for your time"],
                build = ns.YourTimeView.Build, refresh = ns.YourTimeView.Refresh }
        end
        if ns.ShuffleView then
            list[#list + 1] = { key = "shuffles", text = L["SHUFFLES"], last = true,
                build = ns.ShuffleView.Build, refresh = ns.ShuffleView.Refresh }
        end
        return list[1] and list or nil
    end)(),
})

local Build = switch and switch.Build or BuildCrafts
local RefreshView = switch and switch.Refresh or Refresh
local ShowView = switch and switch.ShowView or function() end

local function OnShow()
    -- Opening the tab again sorts afresh.
    state.orderKey, state.heldOrder = nil, nil

    RefreshProfessionOptions()
end

--- /bts recipes and the Settings button: the window, on this tab, on
--- Recipes to learn, optionally on one profession.
ns.ProfitTab = {
    ShowView = ShowView,
    StockLine = StockLine,
    ShowRecipesToLearn = function(profession)
        if not (ns.UI and ns.UI.Show) then
            ns.Print(L["the window is not ready yet, try again in a moment"])
            return
        end
        if profession and ns.RecipeBookView then ns.RecipeBookView.SetProfession(profession) end
        ns.UI:Show()
        if ns.UI.SelectTab then ns.UI:SelectTab("profit") end
        ShowView("learn")
    end,
}

UI:RegisterTab({
    key = "profit",
    text = L["Profit"],
    order = 1,
    build = Build,
    refresh = RefreshView,
    onShow = OnShow,
})
