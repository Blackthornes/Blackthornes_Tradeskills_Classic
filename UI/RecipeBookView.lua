-- Blackthornes Tradeskills -- UI/RecipeBookView.lua
-- The Recipes to learn view, on the Profit and Level Up tabs: every recipe of
-- a profession that the character playing has not learned, with what one craft costs, sells
-- and disenchants for, and what the recipe costs to get.
--
-- Asked 2026-10-05 by a player who wanted to judge "if it's worth it to get
-- a recipe or not at a glance", and "even a list of all recipes possible for
-- a profession". The numbers come from Logic/RecipeBook.lua; the pane on the
-- right says where a picked recipe is learned and what goes into it.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local RecipeBookView = {}
ns.RecipeBookView = RecipeBookView

local ROW_HEIGHT = 22
local DETAIL_WIDTH = 300
local ALL = "all"

--- The book's (English) name for one of the character's professions. The
--- client names them in its own language, and the book in English.
local function BookName(profession)
    local recipes = ns.Recipes
    if recipes and type(recipes.EnglishProfessionName) == "function" then
        local ok, english = pcall(recipes.EnglishProfessionName, profession)
        if ok and english then return english end
    end
    return profession.name
end

-- Right to left, measured from the list's right edge. Money sits to the
-- right, so its coins line up; the rest is centred under its heading.
-- `width` is the least each gets: Widgets.FitColumns widens it to fit the
-- heading and a full amount.
local COLUMNS = {
    { key = "learn",      label = L["LEARN FROM"], width = 92, justify = "CENTER" },
    { key = "price",      label = L["RECIPE"],     width = 66, money = true },
    { key = "profit",     label = L["PROFIT"],     width = 70, money = true },
    { key = "disenchant", label = L["DISENCHANT"], width = 66, money = true },
    { key = "sells",      label = L["SELLS"],      width = 66, money = true },
    { key = "cost",       label = L["COST"],       width = 66, money = true },
    { key = "skill",      label = L["SKILL"],      width = 36, justify = "CENTER" },
}

-- Any column but the recipe's name can be hidden (UI/Columns.lua). The
-- Profit and Level Up tabs' copies share the choice.
ns.Columns:Register("recipes", L["Recipes to learn"], COLUMNS)

--- One copy of the view, with its own filters and its own frames. The
--- Profit tab and the Level Up tab each carry one (asked 2026-10-05: "recipes
--- to learn should be under level up as well").
--
-- @param opts.order  "skill" lists recipes by the skill they need, for
--   levelling; otherwise the most profit comes first
-- @param opts.showSkill  the picked profession's skill at the top right, as
--   Road to 300 shows it (every profession you have under All professions)
local function NewView(opts)
    opts = opts or {}
    local instance = {}

    local state = {
        search = "",
        profession = nil,
        includeKnown = false,
        selected = nil,
        waiting = false,
    }

    local widgets = {}

    --------------------------------------------------------------------------------
    -- Rows
    --------------------------------------------------------------------------------

    --- The shown columns from the right edge; the name has the rest.
    local function PlaceRow(row)
        local offset = ns.Columns:Place("recipes", COLUMNS, row.cells, { gap = 8 })
        row.name:SetPoint("RIGHT", row, "RIGHT", offset - 8, 0)
        row.columnsVersion = ns.Columns.version
    end

    local function CreateRow(row)
        row.icon = Theme.CreateItemIcon(row, 16)
        row.icon:SetPoint("LEFT", 8, 0)

        row.name = Theme.CreateLabel(row, "small", "text")
        row.name:SetPoint("LEFT", 30, 0)
        row.name:SetWordWrap(false)

        row.cells = {}
        for _, column in ipairs(COLUMNS) do
            local cell = Theme.CreateLabel(row, "small", "muted", column.justify or "RIGHT")
            cell:SetWordWrap(false)
            row.cells[column.key] = cell
        end

        PlaceRow(row)
    end

    local function SetMoney(cell, copper, colorKey)
        if copper == nil then
            cell:SetText("--")
            cell:SetTextColor(Theme.Unpack("dim"))
            return
        end
        Theme.SetMoneyText(cell, copper, { short = true })
        cell:SetTextColor(Theme.Unpack(colorKey or "text"))
    end

    local function UpdateRow(row, entry)
        if row.columnsVersion ~= ns.Columns.version then PlaceRow(row) end

        -- No item made (an enchant): the recipe item's icon stands in.
        local iconItem = entry.outputItemID or (entry.record.recipeItems and entry.record.recipeItems[1])
        Theme.SetItemIcon(row.icon, iconItem)
        if iconItem then
            local ok, name = pcall(function() return C_Item.GetItemInfo(iconItem) end)
            if not ok or not name then state.waiting = true end
        end

        Theme.SetRowName(row.name, entry.name)
        -- The name in the rarity of what it makes, as on My crafts, faded for
        -- a recipe already known. Plain until the client has the item; the
        -- redraw on GET_ITEM_INFO_RECEIVED colours it then.
        local okColor, r, g, b = pcall(Util.GetItemQualityColor, entry.outputItemID)
        if okColor and r then
            row.name:SetTextColor(r, g, b, entry.known and 0.55 or 1)
        else
            row.name:SetTextColor(Theme.Unpack(entry.known and "dim" or "text"))
            if entry.outputItemID then state.waiting = true end
        end

        local cells = row.cells
        -- Green when your skill is already enough to learn it, amber when
        -- not yet; grey for a profession this character does not have.
        cells.skill:SetText(entry.skill and entry.skill > 0 and tostring(entry.skill) or "")
        local mine = state.skills and entry.profession and state.skills[entry.profession]
        cells.skill:SetTextColor(Theme.Unpack(not mine and "muted"
            or (entry.skill or 0) <= mine and "profit" or "warn"))

        SetMoney(cells.cost, entry.cost, "muted")

        if not entry.outputItemID then
            cells.sells:SetText(L["no item"])
            cells.sells:SetTextColor(Theme.Unpack("dim"))
        else
            SetMoney(cells.sells, entry.auction)
        end

        if entry.disenchant then
            SetMoney(cells.disenchant, entry.disenchant)
        else
            cells.disenchant:SetText("")
        end

        if entry.profit then
            Theme.SetMoneyText(cells.profit, entry.profit, { short = true })
            cells.profit:SetTextColor(Theme.ProfitColor(entry.profit))
        else
            cells.profit:SetText("--")
            cells.profit:SetTextColor(Theme.Unpack("dim"))
        end

        SetMoney(cells.price, entry.price, "muted")

        cells.learn:SetText(entry.known and L["Known"] or entry.learn)
        cells.learn:SetTextColor(Theme.Unpack(entry.known and "profit" or "muted"))
    end

    local function ShowRowTooltip(row, entry)
        if entry.outputItemID then
            Widgets.ShowItemOnly(row, entry.outputItemID, entry.name)
        else
            GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
            GameTooltip:SetText(entry.name, 1, 1, 1)
        end

        local _, where = ns.RecipeBook:LearnFrom(entry.record)
        if #where > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(L["Learned from"], Theme.Unpack("accent"))
            for _, line in ipairs(where) do
                GameTooltip:AddLine(line, 1, 1, 1, true)
            end
        end

        if entry.payback then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(entry.payback == 1 and L["Pays for itself after 1 craft"]
                or L.Format("Pays for itself after %d crafts", entry.payback), Theme.Unpack("profit"))
        end

        GameTooltip:Show()
    end

    --------------------------------------------------------------------------------
    -- Detail pane
    --------------------------------------------------------------------------------

    local VALUE_LINES = 7
    local MATERIAL_LINES = 5
    local LEARN_LINES = 4

    local function DoubleLine(parent, anchor, gap)
        local line = CreateFrame("Frame", nil, parent)
        line:SetHeight(16)
        line:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(gap or 1))
        line:SetPoint("RIGHT", parent, "RIGHT", -12, 0)

        line.label = Theme.CreateLabel(line, "small", "muted")
        line.label:SetPoint("LEFT", 0, 0)
        line.label:SetPoint("RIGHT", line, "RIGHT", -120, 0)
        line.label:SetWordWrap(false)

        line.value = Theme.CreateLabel(line, "small", "text", "RIGHT")
        line.value:SetPoint("RIGHT", 0, 0)
        line.value:SetWidth(116)
        line.value:SetWordWrap(false)

        return line
    end

    local function BuildDetail(parent)
        local detail = Theme.CreatePanel(parent, "window")
        Theme.AccentStripe(detail, 2, 0.6)
        detail:SetWidth(DETAIL_WIDTH)

        detail.title = Theme.CreateLabel(detail, "normal", "accent")
        detail.title:SetPoint("TOPLEFT", 12, -12)
        detail.title:SetPoint("TOPRIGHT", -12, -12)
        detail.title:SetWordWrap(true)

        detail.subtitle = Theme.CreateLabel(detail, "tiny", "muted")
        detail.subtitle:SetPoint("TOPLEFT", detail.title, "BOTTOMLEFT", 0, -4)
        detail.subtitle:SetPoint("TOPRIGHT", detail.title, "BOTTOMRIGHT", 0, -4)
        detail.subtitle:SetWordWrap(true)

        detail.worthHeading = Theme.CreateHeading(detail, L["ONE CRAFT"])
        detail.worthHeading:SetPoint("TOPLEFT", detail.subtitle, "BOTTOMLEFT", 0, -10)

        detail.values = {}
        local anchor = detail.worthHeading
        for index = 1, VALUE_LINES do
            local line = DoubleLine(detail, anchor, index == 1 and 5 or 1)
            detail.values[index] = line
            anchor = line
        end

        detail.materialsHeading = Theme.CreateHeading(detail, L["MATERIALS"])
        detail.materialsHeading:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -8)

        detail.materials = {}
        anchor = detail.materialsHeading
        for index = 1, MATERIAL_LINES do
            local line = DoubleLine(detail, anchor, index == 1 and 5 or 1)
            detail.materials[index] = line
            anchor = line
        end

        detail.learnHeading = Theme.CreateHeading(detail, L["WHERE TO LEARN IT"])
        detail.learnHeading:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -8)

        detail.learn = Theme.CreateLabel(detail, "small", "text")
        detail.learn:SetPoint("TOPLEFT", detail.learnHeading, "BOTTOMLEFT", 0, -6)
        detail.learn:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
        detail.learn:SetWordWrap(true)

        detail.note = Theme.CreateLabel(detail, "tiny", "dim")
        detail.note:SetPoint("BOTTOMLEFT", 12, 12)
        detail.note:SetPoint("BOTTOMRIGHT", -12, 12)
        detail.note:SetWordWrap(true)

        return detail
    end

    local function SetLine(line, label, value, colorKey)
        if not label then
            line:Hide()
            return
        end
        line.label:SetText(label)
        line.value:SetText(value or "")
        line.value:SetTextColor(Theme.Unpack(colorKey or "text"))
        line:Show()
    end

    local function Money(copper)
        return Util.FormatMoney(copper, { short = true })
    end

    local PRICE_HOW = { trainer = L["Recipe, at a trainer"], vendor = L["Recipe, from a vendor"],
        auction = L["Recipe, on the auction house"] }
    local BACK_WAY = { vendor = L["Profit, by vendor"], disenchant = L["Profit, by disenchant"] }

    local function ShowNothing(detail)
        detail.title:SetText(L["Recipes to learn"])
        detail.title:SetTextColor(Theme.Unpack("accent"))
        detail.subtitle:SetText(L["Pick a recipe to see what goes into it and where to learn it."])
        for _, line in ipairs(detail.values) do line:Hide() end
        for _, line in ipairs(detail.materials) do line:Hide() end
        detail.worthHeading:Hide()
        detail.materialsHeading:Hide()
        detail.learnHeading:Hide()
        detail.learn:SetText("")
        detail.note:SetText(L["Values use the prices you have scanned. Recipes come from Classic's data, corrected by what your profession windows and recipe tooltips show."])
    end

    local function ShowEntry(detail, entry)
        local record = entry.record
        local value = ns.RecipeBook:Value(record)
        local returns = value.returns or {}

        detail.title:SetText(entry.name)
        -- In the rarity of what it makes, as its row is; gold for an enchant.
        if not Theme.SetItemNameColor(detail.title, entry.outputItemID, "accent") and entry.outputItemID then
            state.waiting = true
        end

        local parts = {}
        if record.profession then
            parts[#parts + 1] = record.skill and record.skill > 0
                and ("%s %d"):format(record.profession, record.skill) or record.profession
        end
        local knownBy = ns.RecipeBook:KnownByText(record)
        parts[#parts + 1] = knownBy and L.Format("known by %s", knownBy) or L["nobody on this account knows it"]
        detail.subtitle:SetText(table.concat(parts, "  ·  "))

        detail.worthHeading:Show()
        local rows = {}
        rows[#rows + 1] = { L["Cost to make"], value.cost and Money(value.cost) or L["not scanned"],
            value.cost and "text" or "dim" }
        if record.outputItemID then
            rows[#rows + 1] = { L["Sells for, after the cut"],
                returns.auction and Money(returns.auction) or L["not scanned"], returns.auction and "text" or "dim" }
            if returns.disenchant then rows[#rows + 1] = { L["Disenchants for"], Money(returns.disenchant) } end
            if returns.vendor then rows[#rows + 1] = { L["Vendors for"], Money(returns.vendor) } end
            if value.profit then
                rows[#rows + 1] = { value.backWay and value.backWay ~= "auction"
                        and (BACK_WAY[value.backWay] or L["Profit"]) or L["Profit"],
                    Money(value.profit), value.profit >= 0 and "profit" or "loss" }
            end
        else
            rows[#rows + 1] = { L["Makes"], L["no item to sell"], "dim" }
        end
        if value.price then
            rows[#rows + 1] = { PRICE_HOW[value.priceHow] or L["Recipe"], Money(value.price) }
        end
        if value.payback then
            rows[#rows + 1] = { L["Pays for itself after"], value.payback == 1 and L["1 craft"]
                or L.Format("%d crafts", value.payback), "profit" }
        elseif value.profit and value.profit <= 0 then
            rows[#rows + 1] = { L["Pays for itself"], L["not at today's prices"], "warn" }
        end
        for index, line in ipairs(detail.values) do
            local row = rows[index]
            SetLine(line, row and row[1], row and row[2], row and row[3])
        end

        detail.materialsHeading:Show()
        local reagents = (value.costDetail and value.costDetail.reagents) or {}
        for index, line in ipairs(detail.materials) do
            local reagent = reagents[index]
            if reagent then
                local name = Util.GetItemLabel(reagent.itemID)
                if index == MATERIAL_LINES and #reagents > MATERIAL_LINES then
                    SetLine(line, L.Format("and %d more", #reagents - MATERIAL_LINES + 1), "", "dim")
                else
                    SetLine(line, ("%dx %s"):format(reagent.quantity, Util.Uncolored(name)),
                        reagent.lineCost and Money(reagent.lineCost) or L["not scanned"],
                        reagent.lineCost and "text" or "dim")
                end
            else
                line:Hide()
            end
        end

        detail.learnHeading:Show()
        local _, where = ns.RecipeBook:LearnFrom(record)
        local shown = {}
        for index = 1, math.min(#where, LEARN_LINES) do shown[index] = where[index] end
        if #where > LEARN_LINES then
            shown[LEARN_LINES] = L.Format("and %d more places", #where - LEARN_LINES + 1)
        end
        detail.learn:SetText(#shown > 0 and table.concat(shown, "\n") or L["Not known yet."])
        detail.note:SetText("")
    end

    --------------------------------------------------------------------------------
    -- Refresh
    --------------------------------------------------------------------------------

    --- The professions to offer: those of the character playing first, so the
    --- view opens on one of them, then the rest.
    local function ProfessionOptions()
        local options = { { value = ALL, text = L["All professions"] } }
        local mine, first = {}, nil

        if ns.Recipes and ns.Recipes.GetLearnedProfessions then
            for _, profession in ipairs(ns.Recipes:GetLearnedProfessions()) do
                mine[BookName(profession)] = true
            end
        end

        for _, name in ipairs(ns.RecipeBook:GetProfessions()) do
            if mine[name] then
                options[#options + 1] = { value = name, text = name }
                first = first or name
            end
        end
        -- The rest under a line of their own, so yours first then the
        -- others reads as two groups rather than a list out of order.
        local others = {}
        for _, name in ipairs(ns.RecipeBook:GetProfessions()) do
            if not mine[name] then others[#others + 1] = { value = name, text = name } end
        end
        if first and #others > 0 then
            options[#options + 1] = { text = L["Other professions"], header = true }
        end
        for _, option in ipairs(others) do options[#options + 1] = option end

        return options, first
    end

    function instance.Refresh()
        if not widgets.list or not ns.RecipeBook then return end

        local options, first = ProfessionOptions()
        widgets.profession:SetOptions(options)
        if state.profession == nil then state.profession = first or ALL end
        widgets.profession:SetValue(state.profession)

        state.waiting = false

        -- The character's skill in each profession, for the SKILL column.
        state.skills = {}
        local levels = {}
        if ns.Recipes and ns.Recipes.GetLearnedProfessions then
            for _, profession in ipairs(ns.Recipes:GetLearnedProfessions()) do
                state.skills[BookName(profession)] = profession.skillLevel
                levels[#levels + 1] = { book = BookName(profession), profession = profession }
            end
        end

        if widgets.skill then
            local parts = {}
            for _, level in ipairs(levels) do
                local profession = level.profession
                if (profession.maxSkillLevel or 0) > 0
                    and (state.profession == ALL or state.profession == level.book) then
                    parts[#parts + 1] = ("%s  %d / %d"):format(tostring(profession.name):upper(),
                        profession.skillLevel or 0, profession.maxSkillLevel)
                end
            end
            widgets.skill:SetText(table.concat(parts, "   ·   "))
        end

        local rows = ns.RecipeBook:List({
            profession = state.profession ~= ALL and state.profession or nil,
            includeKnown = state.includeKnown,
            search = state.search,
            order = opts.order,
        })
        if widgets.sorter then rows = widgets.sorter:Sort(rows) end

        widgets.list:SetData(rows)

        widgets.empty:SetShown(#rows == 0)
        if #rows == 0 then
            if state.search ~= "" then
                widgets.empty:SetText(L.Format("Nothing matching \"%s\".", state.search))
            else
                widgets.empty:SetText(L["You know every recipe of this profession."])
            end
        end

        local paying = 0
        for _, entry in ipairs(rows) do
            if entry.profit and entry.profit > 0 then paying = paying + 1 end
        end
        widgets.summary:SetText(#rows == 1
            and L.Format("%d recipe  ·  %d make a profit at today's prices", #rows, paying)
            or L.Format("%d recipes  ·  %d make a profit at today's prices", #rows, paying))

        local selected
        if state.selected then
            for _, entry in ipairs(rows) do
                if entry.recipeID == state.selected then selected = entry break end
            end
            if not selected then state.selected = nil end
        end

        if selected then
            ShowEntry(widgets.detail, selected)
        else
            ShowNothing(widgets.detail)
        end
    end

    --- Open on a profession, by name (any case) or part of one.
    function instance.SetProfession(name)
        if not name then return end
        local needle = name:lower()
        for _, profession in ipairs(ns.RecipeBook:GetProfessions()) do
            if profession:lower():find(needle, 1, true) then
                state.profession = profession
                state.selected = nil
                return
            end
        end
    end

    --------------------------------------------------------------------------------
    -- Build
    --------------------------------------------------------------------------------

    --- Fill `view`, a frame covering a tab below its view switch.
    function instance.Build(view)
        -- Before any row or heading is laid out: they read these widths.
        if Widgets.FitColumns then Widgets.FitColumns(COLUMNS) end

        local right = -DETAIL_WIDTH - 16

        -- Dropdown, search, tick box: the order every tab uses.
        local profession = Widgets.CreateDropdown(view, { { value = ALL, text = L["All professions"] } },
            function(value)
                state.profession = value
                state.selected = nil
                instance.Refresh()
            end, { width = 150 })
        profession:SetPoint("TOPLEFT", 8, -8)
        widgets.profession = profession

        local search = Widgets.CreateSearchBox(view, L["Search recipes"], function(text)
            state.search = text or ""
            instance.Refresh()
        end)
        search:SetPoint("LEFT", profession, "RIGHT", 8, 0)
        search:SetWidth(Widgets.SEARCH_WIDTH)

        local known = Widgets.CreateCheckbox(view, L["Show learned too"], function(checked)
            state.includeKnown = checked and true or false
            instance.Refresh()
        end, false)
        known:SetPoint("LEFT", search, "RIGHT", 12, 0)

        if opts.showSkill then
            local skill = Theme.CreateLabel(view, "normal", "accent", "RIGHT")
            skill:SetPoint("RIGHT", view, "TOPRIGHT", right, -19)
            skill:SetPoint("LEFT", known, "RIGHT", 12, 0)
            skill:SetWordWrap(false)
            widgets.skill = skill
        end

        local headings = CreateFrame("Frame", nil, view)
        headings:SetHeight(16)
        headings:SetPoint("TOPLEFT", 8, -40)
        headings:SetPoint("TOPRIGHT", view, "TOPRIGHT", right, -40)

        local nameHeading = Theme.CreateLabel(headings, "tiny", "muted")
        nameHeading:SetPoint("LEFT", 30, 0)
        nameHeading:SetText(L["RECIPE"])

        headings.cells = {}
        for _, column in ipairs(COLUMNS) do
            local cell = Theme.CreateLabel(headings, "tiny", "muted", column.justify or "RIGHT")
            cell:SetText(column.label)
            headings.cells[column.key] = cell
        end
        ns.Columns:Place("recipes", COLUMNS, headings.cells, { gap = 8 })

        local sortLabels = { name = nameHeading }
        for key, cell in pairs(headings.cells) do sortLabels[key] = cell end
        widgets.sorter = Widgets.SortableHeadings and Widgets.SortableHeadings(sortLabels, {
            name = function(entry) return entry.name end,
            skill = function(entry) return entry.skill end,
            cost = function(entry) return entry.cost end,
            sells = function(entry) return entry.auction end,
            disenchant = function(entry) return entry.disenchant end,
            profit = function(entry) return entry.profit end,
            price = function(entry) return entry.price end,
            learn = function(entry) return entry.known and L["Known"] or entry.learn end,
        }, function() instance.Refresh() end)
        if widgets.sorter then widgets.sorter:SetText({ "name", "learn" }) end

        -- Right-click the headings to choose the columns.
        ns.Columns:Attach(headings, "recipes", widgets.sorter)
        ns.Columns:OnChange("recipes", function()
            ns.Columns:Place("recipes", COLUMNS, headings.cells, { gap = 8 })
            if widgets.sorter then widgets.sorter:Sync() end
            if widgets.list then widgets.list:Refresh() end
        end)

        local divider = Theme.CreateDivider(view, "borderLit")
        divider:SetPoint("TOPLEFT", headings, "BOTTOMLEFT", 0, -2)
        divider:SetPoint("TOPRIGHT", headings, "BOTTOMRIGHT", 0, -2)

        local list = Widgets.CreateScrollList(view, {
            rowHeight = ROW_HEIGHT,
            createRow = CreateRow,
            updateRow = UpdateRow,

            isSelected = function(entry)
                return state.selected ~= nil and entry.recipeID == state.selected
            end,

            onClick = function(entry)
                state.selected = state.selected ~= entry.recipeID and entry.recipeID or nil
                instance.Refresh()
            end,

            onEnter = ShowRowTooltip,
            onLeave = function() GameTooltip:Hide() end,

            onScrollbarShown = function(shown)
                headings:SetPoint("TOPRIGHT", view, "TOPRIGHT", right - (shown and 10 or 0), -40)
            end,
        })
        list:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -4)
        list:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", right, 24)
        widgets.list = list

        local empty = Theme.CreateLabel(view, "small", "dim", "CENTER")
        empty:SetPoint("CENTER", list, "CENTER")
        empty:SetWidth(320)
        empty:SetWordWrap(true)
        widgets.empty = empty

        local summary = Theme.CreateLabel(view, "tiny", "dim")
        summary:SetPoint("BOTTOMLEFT", 8, 8)
        widgets.summary = summary

        local detail = BuildDetail(view)
        detail:SetPoint("TOPRIGHT", view, "TOPRIGHT", -8, -8)
        detail:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -8, 8)
        widgets.detail = detail
        ShowNothing(detail)

        -- Items the client has not loaded draw without an icon or a sell price;
        -- drawn again once they arrive, a burst of them as one redraw.
        local redrawQueued = false
        ns.RegisterEvent(instance, "GET_ITEM_INFO_RECEIVED", function(_, _, _, success)
            if success == false then return end
            if redrawQueued or not state.waiting then return end
            if not list:IsVisible() then return end

            redrawQueued = true
            C_Timer.After(0.3, function()
                redrawQueued = false
                instance.Refresh()
            end)
        end)
    end

    --- For the tests.
    instance._state = state
    instance._widgets = widgets

    return instance
end

RecipeBookView.New = NewView

-- The Profit tab's copy, which /bts recipes and the Settings button open.
local main = NewView()
RecipeBookView.Build = main.Build
RecipeBookView.Refresh = main.Refresh
RecipeBookView.SetProfession = main.SetProfession
RecipeBookView._state = main._state
RecipeBookView._widgets = main._widgets

--------------------------------------------------------------------------------
-- The switch at the top of a tab
--------------------------------------------------------------------------------

-- The switch's height; both views start below it.
local SWITCH_HEIGHT = 22

--- A tab's own view and Recipes to learn behind a switch at its top, drawn
--- like the Characters tab's: the view showing is lit gold and underlined,
--- the other waits in grey and lights under the mouse.
--
-- @param spec.mainKey, spec.mainText, spec.mainTip  the tab's own view
-- @param spec.buildMain(view), spec.refreshMain()  how the tab fills and
--   redraws its own view
-- @param spec.learn  the copy of Recipes to learn to show (a NewView), or
--   the Profit tab's when nil
-- @param spec.learnText  the learn view's name, when not RECIPES TO LEARN
-- @param spec.extras  optional views shown between the two, each
--   { key, text, tip (optional), last (optional), build(view), refresh() };
--   one marked last comes after the learn view instead (Shuffles, 2026-10-25)
-- @return { Build(container), Refresh(), ShowView(key) }
function RecipeBookView.WithSwitch(spec)
    local learn = spec.learn or main
    local extras = spec.extras or {}
    local tab = { view = spec.mainKey }
    local views, parts

    local function Extra(key)
        for _, extra in ipairs(extras) do
            if extra.key == key then return extra end
        end
    end

    local function RefreshView()
        if tab.view == "learn" then
            learn.Refresh()
        elseif Extra(tab.view) then
            Extra(tab.view).refresh()
        else
            spec.refreshMain()
        end
    end

    function tab.ShowView(key)
        if not views then
            tab.view = key
            return
        end

        tab.view = views[key] and key or spec.mainKey

        for viewKey, view in pairs(views) do
            view:SetShown(viewKey == tab.view)
        end

        for _, part in ipairs(parts) do
            local active = part.key == tab.view
            part.label:SetTextColor(Theme.Unpack(active and "accent" or "muted"))
            if part.underline then part.underline:SetShown(active) end
        end

        RefreshView()
    end

    local function BuildSwitch(container)
        local definitions = {
            { key = spec.mainKey, text = spec.mainText, tip = spec.mainTip },
        }
        for _, extra in ipairs(extras) do
            if not extra.last then
                definitions[#definitions + 1] = { key = extra.key, text = extra.text, tip = extra.tip }
            end
        end
        definitions[#definitions + 1] = { key = "learn", text = spec.learnText or L["RECIPES TO LEARN"],
            tip = L["Recipes you have not learned, and what each is worth"] }
        for _, extra in ipairs(extras) do
            if extra.last then
                definitions[#definitions + 1] = { key = extra.key, text = extra.text, tip = extra.tip }
            end
        end
        local built, previous = {}, nil

        for _, definition in ipairs(definitions) do
            local button = CreateFrame("Button", nil, container)
            button:SetHeight(18)
            local level = container:GetFrameLevel()
            button:SetFrameLevel((type(level) == "number" and level or 1) + 5)

            -- Kept beside the button rather than on it.
            local part = { key = definition.key }

            part.label = Theme.CreateLabel(button, "tiny", "muted")
            part.label:SetPoint("LEFT", 0, 0)
            part.label:SetText(definition.text)
            local width = Theme.TextWidth and Theme.TextWidth(part.label)
            button:SetWidth((type(width) == "number" and width or 100) + 4)

            local underline = button:CreateTexture(nil, "OVERLAY")
            if underline then
                underline:SetPoint("BOTTOMLEFT", 0, 1)
                underline:SetPoint("BOTTOMRIGHT", -4, 1)
                underline:SetHeight(1)
                underline:SetColorTexture(Theme.Unpack("accent"))
                underline:Hide()
                part.underline = underline
            end

            if previous then
                button:SetPoint("LEFT", previous, "RIGHT", 14, 0)
            else
                button:SetPoint("TOPLEFT", 8, -4)
            end

            button:SetScript("OnClick", function() tab.ShowView(part.key) end)
            button:SetScript("OnEnter", function(self)
                if part.key ~= tab.view then
                    part.label:SetTextColor(Theme.Unpack("text"))
                end
                -- A view with no tip shows none (Road to 300, 2026-10-20).
                if definition.tip then
                    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                    GameTooltip:SetText(definition.tip, 1, 1, 1)
                    GameTooltip:Show()
                end
            end)
            button:SetScript("OnLeave", function()
                if part.key ~= tab.view then
                    part.label:SetTextColor(Theme.Unpack("muted"))
                end
                GameTooltip:Hide()
            end)

            built[#built + 1] = part
            previous = button
        end

        -- A tick box at the right end of the switch, for every view
        -- (Show Equipment Upgrades, 2026-10-17); the rule stops short of it.
        local corner = spec.corner and spec.corner(container)
        if corner then
            corner:SetPoint("RIGHT", container, "TOPRIGHT", -8, -13)
            local level = container:GetFrameLevel()
            corner:SetFrameLevel((type(level) == "number" and level or 1) + 5)
        end

        local rule = container:CreateTexture(nil, "ARTWORK")
        if rule then
            rule:SetColorTexture(Theme.Unpack("border"))
            rule:SetHeight(1)
            rule:SetPoint("LEFT", previous, "RIGHT", 6, 0)
            if corner and corner:IsShown() then
                rule:SetPoint("RIGHT", corner, "LEFT", -10, 0)
            else
                rule:SetPoint("RIGHT", container, "RIGHT", -8, 0)
            end
        end

        return built
    end

    function tab.Build(container)
        local made = {}

        local keys = { spec.mainKey }
        for _, extra in ipairs(extras) do keys[#keys + 1] = extra.key end
        keys[#keys + 1] = "learn"

        for _, key in ipairs(keys) do
            local view = CreateFrame("Frame", nil, container)
            view:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -SWITCH_HEIGHT)
            view:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
            view:Hide()
            made[key] = view
        end

        spec.buildMain(made[spec.mainKey])
        for _, extra in ipairs(extras) do extra.build(made[extra.key]) end
        learn.Build(made.learn)

        views = made
        parts = BuildSwitch(container)

        tab.ShowView(tab.view)
    end

    tab.Refresh = RefreshView

    return tab
end
