-- Blackthornes Tradeskills -- UI/Tab_Prices.lua
-- The price database, browsable.
--
-- The Profit tab tells you what to make; this tells you why it thinks so. Every
-- number the profit engine uses is visible here, including the ones that
-- undermine it: how thin the market is, how old the reading is, and how few
-- scans it rests on.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local UI = ns.UI

local ROW_HEIGHT = 22
local DETAIL_WIDTH = 300
-- Room between the detail pane's rows. With every row shown the graph was
-- left a sliver (a player's report, 2026-10-18), so the gaps are a little
-- smaller and the three rows below go under the Market value row's hover.
local ROW_GAP = 6
local FOLDED_ROWS = { quantity = true, scans = true, confidence = true }

-- Right to left. Money sits to the right, so its coins line up; the rest is
-- centred under its heading. `width` is the least each gets:
-- Widgets.FitColumns widens it to fit the heading and a full amount.
local COLUMNS = {
    -- Market value now against its average over the picked period
    -- (2026-10-14): green up, red down.
    { key = "trend",     label = L["TREND"], width = 48, justify = "CENTER" },
    { key = "age",       label = L["AGE"], width = 44, justify = "CENTER" },
    { key = "liquidity", label = L["MOVES"], width = 52, justify = "CENTER" },
    { key = "quantity",  label = L["LISTED"], width = 52, justify = "CENTER" },
    -- Few columns, so room for two digits of gold.
    { key = "min",       label = L["CHEAPEST"], width = 80, money = true, sample = "88g 88s 88c" },
    { key = "market",    label = L["MARKET"], width = 80, money = true, sample = "88g 88s 88c" },
}

-- Any column but the name can be hidden (UI/Columns.lua).
ns.Columns:Register("prices", L["Prices"], COLUMNS)

local state = {
    search = "",
    reagentsOnly = false,
    favouritesOnly = false,
    mineOnly = false,
    enchantingOnly = false,
    sortBy = "market",
    selected = nil,
}

local widgets = {}

--------------------------------------------------------------------------------
-- Data
--------------------------------------------------------------------------------

--- Item IDs used as reagents by any cached recipe.
local function GetReagentSet()
    local reagents = {}

    for _, recipe in pairs(ns.Recipes:GetAll()) do
        for _, reagent in ipairs(recipe.reagents or {}) do
            reagents[reagent.itemID] = true
        end

        if recipe.outputItemID then
            reagents[recipe.outputItemID] = true
        end
    end

    return reagents
end

--- An item's plain name without fetching it: the saved facts first, then
--- the client only for an item it already holds. The whole price table is
--- thousands of items, and reading each through the client on every redraw
--- pushed bag items out of its small cache (Ready to sell then flickers).
local function PlainName(itemID)
    local name = ns.Disenchant and ns.Disenchant.KnownName and ns.Disenchant:KnownName(itemID)
    if name then return name end

    if Util.HasFunction("C_Item.IsItemDataCachedByID") then
        local ok, cached = pcall(C_Item.IsItemDataCachedByID, itemID)
        if not ok or cached ~= true then return nil end
    else
        return nil
    end

    local ok, itemName = pcall(C_Item.GetItemInfo, itemID)
    return ok and itemName or nil
end

--- Names the addon saved itself, for items the game has not loaded: the
--- sales history's item names and what your recipes make. Read from saved
--- data only, so a search never asks the game to load anything.
local function StoredNames()
    local names = {}

    if ns.Mail and ns.Mail.GetLedger then
        local ok, ledger = pcall(ns.Mail.GetLedger, ns.Mail)
        for _, entry in ipairs(ok and type(ledger) == "table" and ledger.entries or {}) do
            if entry.itemID and type(entry.name) == "string" then names[entry.itemID] = entry.name end
        end
    end

    for _, record in pairs(ns.db and ns.db.characters or {}) do
        for _, recipe in pairs(type(record) == "table" and record.recipes or {}) do
            local itemID = type(recipe) == "table" and recipe.outputItemID
            if itemID and not names[itemID] and type(recipe.name) == "string" then
                names[itemID] = recipe.name
            end
        end
    end

    -- A starred item keeps the name it had when it was starred.
    for itemID, name in pairs(ns.Prices.GetFavourites and ns.Prices:GetFavourites() or {}) do
        if not names[itemID] and type(name) == "string" then names[itemID] = name end
    end

    -- And an item given its own price, the name it had then.
    for itemID, entry in pairs(ns.Prices.GetAllMine and ns.Prices:GetAllMine() or {}) do
        if not names[itemID] and type(entry) == "table" and type(entry.name) == "string" then
            names[itemID] = entry.name
        end
    end

    return names
end

local function IsFavourite(itemID)
    return ns.Prices.IsFavourite ~= nil and ns.Prices:IsFavourite(itemID)
end

--- The price the player set on an item, and its kind, or nil.
local function Mine(itemID)
    if not ns.Prices.GetMine then return nil end
    return ns.Prices:GetMine(itemID)
end

local function BuildList()
    local rows = {}
    local reagents = state.reagentsOnly and GetReagentSet() or nil
    local favourites = ns.Prices.GetFavourites and ns.Prices:GetFavourites() or {}

    -- Names are only needed to search or sort by; the label itself is read
    -- for the rows on screen, in UpdateRow.
    local wantNames = state.search ~= "" or state.sortBy == "name"
        or (widgets.sorter ~= nil and widgets.sorter.key == "name")
    local stored = wantNames and StoredNames() or {}

    local prices = ns.Prices:GetTable()
    local trendDays = ns.Prices.TrendDays and ns.Prices:TrendDays() or 7

    -- The Enchanting tab's materials list lives here now
    -- (2026-10-07): every enchanting material, priced or not.
    local materials
    if state.enchantingOnly and ns.Disenchant and ns.Disenchant.MATERIALS then
        materials = {}
        for _, material in ipairs(ns.Disenchant.MATERIALS) do
            materials[material.itemID] = material.name or true
            if wantNames and type(material.name) == "string" and not stored[material.itemID] then
                stored[material.itemID] = material.name
            end
        end
    end

    local function Add(itemID, record)
        if reagents and not reagents[itemID] then return end
        if materials and not materials[itemID] then return end
        if state.favouritesOnly and favourites[itemID] == nil then return end
        if state.mineOnly and not Mine(itemID) then return end

        rows[#rows + 1] = {
            itemID = itemID,
            record = record,
            market = record.market or 0,
            min = record.min or 0,
            quantity = record.quantity or 0,
            age = ns.Prices:GetAge(itemID) or math.huge,
            liquidity = ns.Prices:GetSalesPerDay(itemID),
            trend = ns.Prices.GetTrend and (ns.Prices:GetTrend(itemID, trendDays)) or nil,
            name = wantNames and (PlainName(itemID) or stored[itemID]
                or ("~item %d"):format(itemID)) or "",
        }
    end

    for itemID, record in pairs(prices) do
        Add(itemID, record)
    end

    -- A starred item with no price yet (never scanned, or pruned for age)
    -- still shows, with dashes, so it never quietly drops off the list.
    local added = {}
    for itemID in pairs(favourites) do
        if type(itemID) == "number" and not prices[itemID] then
            Add(itemID, {})
            added[itemID] = true
        end
    end

    -- So does an item given its own price.
    for itemID in pairs(ns.Prices.GetAllMine and ns.Prices:GetAllMine() or {}) do
        if type(itemID) == "number" and not prices[itemID] and not added[itemID] and Mine(itemID) then
            Add(itemID, {})
            added[itemID] = true
        end
    end

    -- And, with Enchanting materials ticked, a material never scanned.
    for itemID in pairs(materials or {}) do
        if not prices[itemID] and not added[itemID] then Add(itemID, {}) end
    end

    if state.search ~= "" then
        local needle = state.search:lower()
        local filtered = {}

        for _, row in ipairs(rows) do
            if row.name:lower():find(needle, 1, true) then
                filtered[#filtered + 1] = row
            end
        end
        rows = filtered
    end

    local sortBy = state.sortBy

    table.sort(rows, function(a, b)
        -- Age sorts ascending: freshest first is the useful direction.
        if sortBy == "age" then
            -- One scan prices many items at once; ties go by item so those
            -- rows do not swap places on every redraw.
            if a.age ~= b.age then return a.age < b.age end
            return a.itemID < b.itemID
        end

        if sortBy == "name" then
            if a.name ~= b.name then return a.name < b.name end
            return a.itemID < b.itemID
        end

        local left = a[sortBy] or 0
        local right = b[sortBy] or 0

        if left == right then return a.itemID < b.itemID end
        return left > right
    end)

    -- A clicked heading's order over the menu's.
    if widgets.sorter then rows = widgets.sorter:Sort(rows) end

    return rows
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local Refresh
local BuildMyPrice

--- The favourite star: a gold star when the item is starred, a grey one when
--- not, lit under the mouse with a tooltip saying what a click does, so it
--- reads as a button rather than decoration. `getItemID` names the item the
--- star belongs to when it is clicked.
local function CreateStar(parent, size, getItemID)
    local star = CreateFrame("Button", nil, parent)
    star:SetSize(size + 4, size + 4)

    local file = (Theme.MEDIA or "") .. "SkillUpStar"

    -- A soft gold light behind the star, under the mouse and when starred.
    local glow = star:CreateTexture(nil, "BACKGROUND")
    glow:SetPoint("CENTER")
    glow:SetSize(size + 10, size + 10)
    glow:SetTexture(file)
    pcall(glow.SetBlendMode, glow, "ADD")
    glow:SetAlpha(0)
    star.glow = glow

    local art = star:CreateTexture(nil, "ARTWORK")
    art:SetPoint("CENTER")
    art:SetSize(size, size)
    art:SetTexture(file)
    star.art = art

    local function Paint(hovered)
        local on = star.itemID ~= nil and IsFavourite(star.itemID)
        star.on = on
        pcall(art.SetDesaturated, art, not on)
        if on then
            art:SetVertexColor(1, 1, 1)
            art:SetAlpha(1)
        else
            -- Grey but plain to see, brighter under the mouse.
            art:SetVertexColor(0.85, 0.85, 0.85)
            art:SetAlpha(hovered and 0.95 or 0.5)
        end
        glow:SetAlpha(hovered and 0.55 or on and 0.2 or 0)
    end
    star.Paint = Paint

    function star:SetItem(itemID)
        self.itemID = itemID
        Paint(self.IsMouseOver ~= nil and self:IsMouseOver() == true)
    end

    local function ShowTip()
        GameTooltip:SetOwner(star, "ANCHOR_TOP")
        GameTooltip:SetText(star.on and L["Remove from favourites"] or L["Add to favourites"], 1, 1, 1, 1, true)
        GameTooltip:AddLine(L["Tick Favourites only to hide everything you haven't starred."], 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end

    star:SetScript("OnClick", function(self)
        local itemID = getItemID and getItemID() or self.itemID
        if not itemID then return end

        local on = not IsFavourite(itemID)
        local name = PlainName(itemID)
        ns.Prices:SetFavourite(itemID, on, name)

        -- Starred by hand, the star pops: a little past full size, then settles.
        if on and ns.Motion and ns.Motion.Run then
            ns.Motion:Run(art, "pop", 0.25, function(p)
                local grown = math.max(1, size * p)
                art:SetSize(grown, grown)
            end, { ease = ns.Motion.EaseOutBack })
        end

        if Refresh then Refresh() end
        Paint(true)
        ShowTip()
    end)

    star:SetScript("OnEnter", function()
        Paint(true)
        ShowTip()
    end)
    star:SetScript("OnLeave", function()
        Paint(false)
        GameTooltip:Hide()
    end)

    Paint(false)
    return star
end

--- The shown columns from the right edge; the name has the rest.
local function PlaceRow(row)
    local offset = ns.Columns:Place("prices", COLUMNS, row.cells)
    row.name:SetPoint("RIGHT", row, "RIGHT", offset - 8, 0)
    row.columnsVersion = ns.Columns.version
end

local function CreateRow(row)
    -- The favourite star at the row's left end, before the icon.
    row.star = CreateStar(row, 14, function() return row.data and row.data.itemID end)
    row.star:SetPoint("LEFT", 4, 0)

    -- The item's icon beside its name, as the bags draw it.
    row.icon = Theme.CreateItemIcon(row, 16)
    row.icon:SetPoint("LEFT", 26, 0)

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("LEFT", 46, 0)

    row.cells = {}
    for _, column in ipairs(COLUMNS) do
        row.cells[column.key] = Theme.CreateLabel(row, "small", "muted", column.justify or "RIGHT")
    end

    PlaceRow(row)
end

local function UpdateRow(row, entry)
    if row.columnsVersion ~= ns.Columns.version then PlaceRow(row) end

    entry.label = Util.GetItemLabel(entry.itemID)
    -- An item with its own price says so, in gold, beside its name.
    if Mine(entry.itemID) then
        Theme.SetRowName(row.name, L.Format("%s  |c%smy price|r", entry.label, ns.COLORS.warn))
    else
        Theme.SetRowName(row.name, entry.label)
    end
    Theme.SetItemIcon(row.icon, entry.itemID)
    row.star:SetItem(entry.itemID)

    local stale = ns.Prices:IsStale(entry.itemID)
    row.name:SetTextColor(Theme.Unpack(stale and "muted" or "text"))

    local cells = row.cells

    -- Measured into the cell: "12g 34s 56c" is wider than it, and was cut
    -- off. It drops to the two largest coins, then one, rounded.
    Theme.SetMoneyText(cells.market, entry.record.market, { short = true })
    cells.market:SetTextColor(Theme.Unpack("text"))

    local listedMin = entry.record.min ~= nil
    if listedMin then
        Theme.SetMoneyText(cells.min, entry.record.min, { short = true })
    else
        cells.min:SetText(L["none"])
    end
    cells.min:SetTextColor(Theme.Unpack(listedMin and "text" or "dim"))

    -- Sold out reads as sold out, apart from a thin shelf at a glance.
    local listed = (entry.quantity or 0) > 0
    cells.quantity:SetText(listed and Util.Comma(entry.quantity) or L["none"])
    cells.quantity:SetTextColor(Theme.Unpack(listed and "muted" or "dim"))

    if entry.liquidity then
        cells.liquidity:SetText(("%d%%"):format(math.floor(entry.liquidity * 100)))
        cells.liquidity:SetTextColor(Theme.Unpack(entry.liquidity >= 0.30 and "profit" or "muted"))
    else
        -- One scan cannot show movement; say so rather than implying zero sales.
        cells.liquidity:SetText("--")
        cells.liquidity:SetTextColor(Theme.Unpack("dim"))
    end

    -- Up in green, down in red; "--" until a few days were scanned.
    local trendText, trendColor = ns.Prices.TrendText and ns.Prices.TrendText(entry.trend)
    cells.trend:SetText(trendText or "--")
    cells.trend:SetTextColor(Theme.Unpack(trendColor or "dim"))

    -- "now" rather than "just now", which is wider than the column.
    local age = Util.FormatAge(entry.record.seen and (time() - entry.record.seen))
    cells.age:SetText(age == L["just now"] and L["now"] or age)
    cells.age:SetTextColor(Theme.Unpack(stale and "warn" or "dim"))
end

--------------------------------------------------------------------------------
-- Detail panel
--------------------------------------------------------------------------------

-- My price (2026-10-06): the player's own price for the item, in
-- gold, silver and copper boxes, and whether it is used instead of the
-- auction price or only as the least it can be. Saved as it is typed;
-- a price of nothing clears it, and so does Clear.

local MY_MODES = {
    { text = L["Use this price"], value = "use" },
    { text = L["Never below"], value = "floor" },
}

local MY_STATUS = {
    use = L["Used instead of the AH price"],
    floor = L["AH price, but never below"],
}

-- When Cheaper (2026-10-28): what a "Never below" price does while others
-- sell under it.
local MY_UNDER = {
    { text = L["List Anyway"], value = "list" },
    { text = L["Wait"], value = "wait" },
}

--- A hover on a frame that may already have one: ours runs after it.
local function AddHover(frame, title, lines)
    local before = frame.GetScript and frame:GetScript("OnEnter")
    local after = frame.GetScript and frame:GetScript("OnLeave")
    frame:SetScript("OnEnter", function(self, ...)
        if before then before(self, ...) end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(title, 1, 1, 1)
        for _, line in ipairs(lines) do GameTooltip:AddLine(line, 0.9, 0.9, 0.9, true) end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function(self, ...)
        if after then after(self, ...) end
        GameTooltip:Hide()
    end)
end

local HIGHEST_HOVER = { L["The most it lists for. When the auction house asks more, it lists at this price. Leave it empty for no limit."] }
local UNDER_HOVER = {
    L["What to do when others sell it for less than your price."],
    L["List Anyway: list it at your price."],
    L["Wait: keep it in your bags until the price comes back up."],
}

local function MyPriceTyped(my)
    local gold = my.gold:GetValue() or 0
    local silver = my.silver:GetValue() or 0
    local copper = my.copper:GetValue() or 0
    return gold * 10000 + silver * 100 + copper
end

local function SaveMyPrice()
    -- The item the boxes were filled for: a box left mid-edit by a click on
    -- another row saves to the item it was typed for.
    local my = widgets.detail and widgets.detail.myPrice
    local itemID = my and my.itemID
    if not itemID then return end

    ns.Prices:SetMine(itemID, MyPriceTyped(my), my.mode:GetValue() or "use", PlainName(itemID))
    if Refresh then Refresh() end
end

local function MyHighTyped(my)
    local gold = my.highGold:GetValue() or 0
    local silver = my.highSilver:GetValue() or 0
    local copper = my.highCopper:GetValue() or 0
    return gold * 10000 + silver * 100 + copper
end

local function SaveMyLimits(field)
    local my = widgets.detail and widgets.detail.myPrice
    local itemID = my and my.itemID
    if not itemID or not ns.Prices.SetMyHigh then return end
    if field == "high" then
        ns.Prices:SetMyHigh(itemID, MyHighTyped(my))
    else
        ns.Prices:SetMyWait(itemID, my.under:GetValue() == "wait")
    end
    if Refresh then Refresh() end
end

BuildMyPrice = function(detail, anchor)
    local my = {}
    detail.myPrice = my

    local heading = Theme.CreateLabel(detail, "tiny", "dim")
    heading:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -14)
    heading:SetText(L["MY PRICE"])
    Theme.StyleHeading(heading, detail)
    my.heading = heading

    local parts = {}
    local last
    local function Coin(key, width, max, suffix)
        local box = Widgets.CreateNumberBox(detail, {
            width = width, min = 0, max = max,
            onChange = function() SaveMyPrice() end,
        })
        if last then
            box:SetPoint("LEFT", last, "RIGHT", 4, 0)
        else
            box:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -6)
        end

        local mark = Theme.CreateLabel(detail, "small", "text")
        mark:SetPoint("LEFT", box, "RIGHT", 2, 0)
        mark:SetText(suffix)

        my[key] = box
        parts[#parts + 1] = box
        parts[#parts + 1] = mark
        last = mark
    end

    Coin("gold", 44, 214748, "|cffffd700g|r")
    Coin("silver", 28, 99, "|cffc7c7cfs|r")
    Coin("copper", 28, 99, "|cffeda55fc|r")

    my.mode = Widgets.CreateDropdown(detail, MY_MODES, function() SaveMyPrice() end, { width = 118 })
    my.mode:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -12, 0)
    my.mode:SetPoint("TOP", my.gold, "TOP", 0, 0)
    my.mode:SetValue("use")
    parts[#parts + 1] = my.mode

    my.clear = Widgets.CreateButton(detail, L["Clear"], function()
        if not my.itemID then return end
        ns.Prices:SetMine(my.itemID, nil)
        if Refresh then Refresh() end
    end, { width = 64, height = 22, tooltip = L["Back to the auction house price"] })
    my.clear:SetPoint("TOPRIGHT", my.mode, "BOTTOMRIGHT", 0, -6)
    parts[#parts + 1] = my.clear

    -- Beside Clear, as wide as the pane leaves it.
    local status = Theme.CreateLabel(detail, "small", "muted")
    status:SetPoint("TOPLEFT", my.gold, "BOTTOMLEFT", 0, -11)
    status:SetWidth(DETAIL_WIDTH - 24 - 64 - 8)
    status:SetWordWrap(false)
    my.status = status
    parts[#parts + 1] = status

    -- Highest and When Cheaper, under the status line, only with a
    -- "Never below" price.
    local limits = {}
    local highLabel = Theme.CreateLabel(detail, "small", "text")
    highLabel:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -12)
    highLabel:SetWidth(96)
    highLabel:SetText(L["Highest:"])
    limits[#limits + 1] = highLabel

    local lastHigh
    local function HighCoin(key, width, max, suffix)
        local box = Widgets.CreateNumberBox(detail, {
            width = width, min = 0, max = max,
            onChange = function() SaveMyLimits("high") end,
        })
        if lastHigh then
            box:SetPoint("LEFT", lastHigh, "RIGHT", 4, 0)
        else
            box:SetPoint("LEFT", highLabel, "RIGHT", 4, 0)
        end
        local mark = Theme.CreateLabel(detail, "small", "text")
        mark:SetPoint("LEFT", box, "RIGHT", 2, 0)
        mark:SetText(suffix)
        my[key] = box
        limits[#limits + 1] = box
        limits[#limits + 1] = mark
        lastHigh = mark
    end
    HighCoin("highGold", 44, 214748, "|cffffd700g|r")
    HighCoin("highSilver", 28, 99, "|cffc7c7cfs|r")
    HighCoin("highCopper", 28, 99, "|cffeda55fc|r")

    local underLabel = Theme.CreateLabel(detail, "small", "text")
    underLabel:SetPoint("TOPLEFT", highLabel, "BOTTOMLEFT", 0, -14)
    underLabel:SetWidth(96)
    underLabel:SetText(L["When Cheaper:"])
    limits[#limits + 1] = underLabel

    my.under = Widgets.CreateDropdown(detail, MY_UNDER, function() SaveMyLimits("under") end, { width = 118 })
    my.under:SetPoint("LEFT", underLabel, "RIGHT", 4, 0)
    my.under:SetValue("list")
    limits[#limits + 1] = my.under
    AddHover(my.under, L["When Cheaper"], UNDER_HOVER)
    for _, key in ipairs({ "highGold", "highSilver", "highCopper" }) do
        AddHover(my[key].editBox, L["Highest"], HIGHEST_HOVER)
    end

    -- What the price graph hangs from: under the status line, or under
    -- When Cheaper while the limits show.
    local foot = CreateFrame("Frame", nil, detail)
    foot:SetSize(1, 1)
    foot:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, 0)
    my.foot = foot
    my.limits = limits

    local function ShowLimits(shown)
        for _, part in ipairs(limits) do part:SetShown(shown) end
        foot:ClearAllPoints()
        if shown then
            foot:SetPoint("TOPLEFT", underLabel, "BOTTOMLEFT", 0, -8)
        else
            foot:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, 0)
        end
    end
    my.ShowLimits = ShowLimits
    ShowLimits(false)

    -- Tooltips on the boxes, so what they are for is never a guess.
    for _, box in ipairs({ my.gold, my.silver, my.copper }) do
        box.editBox:SetScript("OnEnter", function(self)
            Theme.SetBorderColor(box, "borderLit")
            GameTooltip:SetOwner(box, "ANCHOR_TOP")
            GameTooltip:SetText(L["My price"], 1, 1, 1)
            GameTooltip:AddLine(L["Your own price. Pick whether it replaces the auction house price or is the lowest it can go."], 0.9, 0.9, 0.9, true)
            GameTooltip:Show()
        end)
        box.editBox:SetScript("OnLeave", function()
            Theme.SetBorderColor(box, "border")
            GameTooltip:Hide()
        end)
    end

    function my:SetShown(shown)
        heading:SetShown(shown)
        for _, part in ipairs(parts) do part:SetShown(shown) end
        if not shown then ShowLimits(false) end
    end

    local function Focused(box)
        local edit = box.editBox
        return type(edit.HasFocus) == "function" and edit:HasFocus() == true
    end

    function my:Show(itemID)
        -- Another item: a box still being typed in saves first, to its own.
        if self.itemID ~= itemID then
            for _, box in ipairs({ self.gold, self.silver, self.copper }) do
                if Focused(box) then box.editBox:ClearFocus() end
            end
        end
        self.itemID = itemID

        -- A redraw while typing (the auction house redraws often) leaves
        -- the box being typed in alone.
        local price, mode = Mine(itemID)
        local gold, silver, copper = Util.SplitMoney(price or 0)
        if not Focused(self.gold) then self.gold:SetValue(gold, true) end
        if not Focused(self.silver) then self.silver:SetValue(silver, true) end
        if not Focused(self.copper) then self.copper:SetValue(copper, true) end
        self.mode:SetValue(mode or self.mode:GetValue() or "use")
        self.clear:SetEnabledState(price ~= nil)

        local limited = price ~= nil and mode == "floor" and ns.Prices.GetMyLimits ~= nil
        local high, wait
        if limited then high, wait = ns.Prices:GetMyLimits(itemID) end
        ShowLimits(limited)
        if limited then
            local hg, hs, hc = Util.SplitMoney(high or 0)
            if not Focused(self.highGold) then self.highGold:SetValue(hg, true) end
            if not Focused(self.highSilver) then self.highSilver:SetValue(hs, true) end
            if not Focused(self.highCopper) then self.highCopper:SetValue(hc, true) end
            self.under:SetValue(wait and "wait" or "list")
        end

        if price then
            status:SetText(MY_STATUS[mode])
            if high then
                status:SetText(L.Format("AH price, but never below. Never above %s.",
                    Util.FormatMoney(high, { noColor = true })))
            end
            status:SetTextColor(Theme.Unpack("warn"))
        else
            status:SetText(L["Not set, the AH price is used"])
            status:SetTextColor(Theme.Unpack("dim"))
        end
    end
end

local function BuildDetail(parent)
    local detail = Theme.CreatePanel(parent, "window")
    detail:SetWidth(DETAIL_WIDTH)

    Theme.AccentStripe(detail, 2, 0.6)

    -- The item's icon beside its name, as on the other detail panes.
    local icon = Theme.CreateItemIcon(detail, 30)
    icon:SetPoint("TOPLEFT", 12, -12)
    detail.icon = icon
    if Widgets.ItemHotspot then Widgets.ItemHotspot(icon) end

    -- The same star as the rows', at the pane's top right.
    detail.star = CreateStar(detail, 18, function() return state.selected and state.selected.itemID end)
    detail.star:SetPoint("TOPRIGHT", -8, -10)

    local title = Theme.CreateLabel(detail, "large", "accent")
    title:SetPoint("TOPLEFT", 50, -12)
    title:SetPoint("TOPRIGHT", detail.star, "TOPLEFT", -6, -2)
    title:SetWordWrap(true)
    detail.title = title

    -- Rows start under the icon or the title, whichever is lower, back at
    -- the pane's left edge.
    local titleBlock = CreateFrame("Frame", nil, detail)
    titleBlock:SetPoint("TOPLEFT", 12, -12)
    titleBlock:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
    titleBlock:SetHeight(30)
    detail.titleBlock = titleBlock

    local rowsAnchor = titleBlock

    detail.values = {}
    detail.rowOrder = {}

    local function AddRow(key, labelText)
        local label = Theme.CreateLabel(detail, "small", "muted")
        label:SetPoint("TOPLEFT", rowsAnchor, "BOTTOMLEFT", 0, -ROW_GAP)
        detail.rowOrder[#detail.rowOrder + 1] = key

        local value = Theme.CreateLabel(detail, "small", "text", "RIGHT")
        value:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -12, 0)
        value:SetPoint("TOP", label, "TOP", 0, 0)

        label:SetText(labelText)

        detail.values[key] = value
        detail.labels = detail.labels or {}
        detail.labels[key] = label
        rowsAnchor = label
        return value
    end

    AddRow("market", L["Market value"])
    AddRow("min", L["Cheapest listing"])
    AddRow("rival", L["Cheapest rival"])
    AddRow("own", L["Your listing"])
    AddRow("quantity", L["Listed quantity"])
    AddRow("scans", L["Times scanned"])
    AddRow("confidence", L["Confidence"])
    AddRow("liquidity", L["Stock movement"])
    AddRow("bags", L["In your bags"])
    AddRow("suffixes", L["Random suffixes"])

    -- Each suffix's own price ("of the Monkey"), listed on hover.
    local suffixHover = CreateFrame("Frame", nil, detail)
    suffixHover:SetPoint("TOPLEFT", detail.labels.suffixes, "TOPLEFT", 0, 2)
    suffixHover:SetPoint("BOTTOMRIGHT", detail.values.suffixes, "BOTTOMRIGHT", 0, -2)
    suffixHover:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
    suffixHover:EnableMouse(true)
    suffixHover:SetScript("OnEnter", function(self)
        local rows = detail.suffixRows
        if not rows or #rows == 0 then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L["Price for each suffix"])
        for _, row in ipairs(rows) do
            GameTooltip:AddDoubleLine(row.name or L.Format("Suffix %d", row.suffix),
                Util.FormatMoney(row.market), 1, 1, 1, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    suffixHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    detail.suffixHover = suffixHover

    -- The rows folded away (FOLDED_ROWS), on the Market value row's hover.
    local marketHover = CreateFrame("Frame", nil, detail)
    marketHover:SetPoint("TOPLEFT", detail.labels.market, "TOPLEFT", 0, 2)
    marketHover:SetPoint("BOTTOMRIGHT", detail.values.market, "BOTTOMRIGHT", 0, -2)
    marketHover:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
    marketHover:EnableMouse(true)
    marketHover:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddDoubleLine(detail.labels.market:GetText(), detail.values.market:GetText(),
            1, 1, 1, 1, 1, 1)
        for _, key in ipairs(detail.rowOrder) do
            if FOLDED_ROWS[key] then
                GameTooltip:AddDoubleLine(detail.labels[key]:GetText(), detail.values[key]:GetText(),
                    0.7, 0.7, 0.7, 1, 1, 1)
            end
        end
        GameTooltip:Show()
    end)
    marketHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    detail.marketHover = marketHover

    BuildMyPrice(detail, rowsAnchor)

    -- The price graph: the cheapest price hour by hour, 24 hours or 7 days,
    -- and when in the day it is cheapest and dearest. It runs down to the
    -- buttons, so it gets whatever room the rows above leave.
    if ns.PriceGraph then
        local graph = ns.PriceGraph.Create(detail, { heading = L["PRICE HISTORY"] })
        graph:SetPoint("TOPLEFT", detail.myPrice.foot, "BOTTOMLEFT", 0, -12)
        graph:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -12, 14 + 24 + 8)
        detail.graph = graph
    end

    -- Actions
    detail.deepScan = Widgets.CreateButton(detail, L["Deep scan"], function()
        if not state.selected then return end

        local itemID = state.selected.itemID
        ns.Print(L.Format("scanning %s...", Util.GetItemLabel(itemID)))

        ns.Scanner:ScanItem(itemID, function()
            UI:RefreshActiveTab()
        end)
    end, { width = 110, height = 24, primary = true,
           tooltip = L["Looks up every listing of this item."] })
    detail.deepScan:SetPoint("BOTTOMLEFT", 12, 14)

    detail.searchAH = Widgets.CreateButton(detail, L["Search AH"], function()
        if not state.selected then return end
        UI:SearchAuctionHouse(state.selected.itemID)
    end, { width = 110, height = 24, tooltip = L["Search the auction house for this item"] })
    detail.searchAH:SetPoint("LEFT", detail.deepScan, "RIGHT", 8, 0)

    local empty = Theme.CreateLabel(detail, "small", "dim", "CENTER")
    empty:SetPoint("CENTER")
    empty:SetWidth(240)
    empty:SetWordWrap(true)
    empty:SetText(L["Pick an item to see its price history."])
    detail.empty = empty

    return detail
end

--- Lay the rows that show one under another, then My price under them,
--- so the price graph below gets the room the hidden ones leave.
local function LayoutRows(detail)
    local previous = detail.titleBlock
    for _, key in ipairs(detail.rowOrder or {}) do
        local label = detail.labels[key]
        if label:IsShown() then
            label:ClearAllPoints()
            label:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -ROW_GAP)
            previous = label
        end
    end
    local heading = detail.myPrice and detail.myPrice.heading
    if heading then
        heading:ClearAllPoints()
        heading:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -14)
    end
end

local function UpdateDetail(entry)
    local detail = widgets.detail
    local shown = entry ~= nil

    detail.empty:SetShown(not shown)
    detail.title:SetShown(shown)
    detail.icon:SetShown(shown)
    local graph = rawget(detail, "graph")
    if type(graph) == "table" then graph:SetShown(shown) end
    detail.deepScan:SetShown(shown)
    detail.searchAH:SetShown(shown)
    detail.star:SetShown(shown)

    for key, value in pairs(detail.values) do
        value:SetShown(shown and not FOLDED_ROWS[key])
    end

    -- The labels go with their values: left up with nothing selected, they
    -- stood around the "Select an item" line saying nothing.
    for key, label in pairs(detail.labels or {}) do
        label:SetShown(shown and not FOLDED_ROWS[key])
    end
    if detail.marketHover then detail.marketHover:SetShown(shown) end
    detail.myPrice:SetShown(shown)
    if not shown then detail.suffixRows = nil end

    if not shown then
        if detail.suffixHover then detail.suffixHover:Hide() end
        return
    end

    local record = ns.Prices:Get(entry.itemID) or entry.record

    detail.title:SetText(Util.GetItemLabel(entry.itemID))
    Theme.SetItemIcon(detail.icon, entry.itemID)
    detail.star:SetItem(entry.itemID)
    detail.myPrice:Show(entry.itemID)

    -- A name that wraps to two lines pushes the rows down with it.
    local titleHeight = detail.title.GetStringHeight and detail.title:GetStringHeight() or 0
    detail.titleBlock:SetHeight(math.max(30, tonumber(titleHeight) or 0))

    detail.values.market:SetText(Util.FormatMoney(record.market))
    -- Worded like the Cheapest rival line when there is nothing listed.
    if record.min then
        detail.values.min:SetText(Util.FormatMoney(record.min))
        detail.values.min:SetTextColor(Theme.Unpack("text"))
    else
        detail.values.min:SetText(L["none listed"])
        detail.values.min:SetTextColor(Theme.Unpack("dim"))
    end

    if record.rivalMin then
        detail.values.rival:SetText(Util.FormatMoney(record.rivalMin))
        detail.values.rival:SetTextColor(Theme.Unpack("text"))
    else
        detail.values.rival:SetText(L["none listed"])
        detail.values.rival:SetTextColor(Theme.Unpack("dim"))
    end

    if record.ownMin then
        detail.values.own:SetText(Util.FormatMoney(record.ownMin))
        detail.values.own:SetTextColor(Theme.Unpack(
            ns.Prices:HoldsLowest(entry.itemID) and "profit" or "loss"))
    else
        detail.values.own:SetText(L["none"])
        detail.values.own:SetTextColor(Theme.Unpack("dim"))
    end

    detail.values.quantity:SetText(Util.Comma(record.quantity or 0))
    detail.values.scans:SetText(tostring(record.scans or 0))

    local confidence, reason = ns.Prices:GetConfidence(entry.itemID)
    -- No reason means nothing is holding the number down, so nothing is named.
    detail.values.confidence:SetText(("%d%%%s"):format(math.floor(confidence * 100),
        reason and ("  (" .. reason .. ")") or ""))
    detail.values.confidence:SetTextColor(Theme.Unpack(confidence > 0.6 and "profit" or "warn"))

    local liquidity = ns.Prices:GetSalesPerDay(entry.itemID)
    if liquidity then
        detail.values.liquidity:SetText(L.Format("%d%% a day", math.floor(liquidity * 100)))
        detail.values.liquidity:SetTextColor(Theme.Unpack("text"))
    else
        detail.values.liquidity:SetText(L["not enough history"])
        detail.values.liquidity:SetTextColor(Theme.Unpack("dim"))
    end

    -- How many you carry and what they are worth, as the Enchanting tab's
    -- materials list said.
    local have = ns.Inventory and ns.Inventory.GetBagCount and ns.Inventory:GetBagCount(entry.itemID) or 0
    if have > 0 and record.market then
        detail.values.bags:SetText(L.Format("%d, worth %s", have,
            Util.FormatMoney(record.market * have, { short = true })))
        detail.values.bags:SetTextColor(Theme.Unpack("text"))
    elseif have > 0 then
        detail.values.bags:SetText(tostring(have))
        detail.values.bags:SetTextColor(Theme.Unpack("text"))
    else
        detail.values.bags:SetText(L["none"])
        detail.values.bags:SetTextColor(Theme.Unpack("dim"))
    end

    -- Random suffixes: how many have a price of their own, and the spread.
    local suffixRows = ns.Prices.SuffixRows and ns.Prices:SuffixRows(entry.itemID) or {}
    detail.suffixRows = suffixRows
    if #suffixRows > 0 then
        local high, low = suffixRows[1].market, suffixRows[#suffixRows].market
        if #suffixRows == 1 then
            detail.values.suffixes:SetText(L.Format("1, %s", Util.FormatMoney(high, { short = true })))
        else
            detail.values.suffixes:SetText(L.Format("%d, %s to %s", #suffixRows,
                Util.FormatMoney(low, { short = true }), Util.FormatMoney(high, { short = true })))
        end
        detail.values.suffixes:SetTextColor(Theme.Unpack("text"))
    else
        detail.values.suffixes:SetText(L["none"])
        detail.values.suffixes:SetTextColor(Theme.Unpack("dim"))
    end

    -- Most items have no random suffix, and a row saying "none" took room
    -- the price graph needs.
    local hasSuffixes = #suffixRows > 0
    detail.labels.suffixes:SetShown(hasSuffixes)
    detail.values.suffixes:SetShown(hasSuffixes)
    if detail.suffixHover then detail.suffixHover:SetShown(hasSuffixes) end
    LayoutRows(detail)

    detail.deepScan:SetEnabledState(ns.Scanner.isAuctionHouseOpen)
    detail.deepScan.tooltipText = ns.Scanner.isAuctionHouseOpen
        and L["Looks up every listing of this item."]
        or L["The auction house must be open"]

    if type(graph) == "table" then graph:SetItem(entry.itemID) end
end

--- The list a search would show, for the tests.
function UI._PricesList(search, favouritesOnly, mineOnly)
    state.search = search or ""
    state.favouritesOnly = favouritesOnly and true or false
    state.mineOnly = mineOnly and true or false
    return BuildList()
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

function Refresh()
    if not widgets.list then return end

    local data = BuildList()
    widgets.list:SetData(data)

    widgets.emptyLabel:SetShown(#data == 0)
    local starred = ns.Prices.GetFavourites and Util.Count(ns.Prices:GetFavourites()) or 0

    if #data == 0 then
        if state.favouritesOnly and starred == 0 then
            widgets.emptyLabel:SetText(L["No favourites yet. Click the star beside an item to keep it here."])
        elseif state.mineOnly and not next(ns.Prices.GetAllMine and ns.Prices:GetAllMine() or {}) then
            widgets.emptyLabel:SetText(L["No prices of your own yet. Pick an item and type one under My price."])
        else
            widgets.emptyLabel:SetText(ns.Prices:Count() == 0
                and L["No auction data yet. Open the auction house and press Scan."]
                or L["Nothing matches these filters."])
        end
    end

    local starredText = starred > 0 and L.Format(", %d starred", starred) or ""
    widgets.countLabel:SetText(#data == 1
        and L.Format("%s item priced%s", Util.Comma(#data), starredText)
        or L.Format("%s items priced%s", Util.Comma(#data), starredText))

    UpdateDetail(state.selected)
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function BuildDetails(container)
    -- Before any row or heading is laid out: they read these widths.
    if Widgets.FitColumns then Widgets.FitColumns(COLUMNS) end

    local toolbar = CreateFrame("Frame", nil, container)
    toolbar:SetPoint("TOPLEFT", 8, -8)
    toolbar:SetPoint("TOPRIGHT", -8, -8)
    toolbar:SetHeight(24)

    -- A new search, filter or sort is a different list, so it starts at the
    -- top. The list keeps its place on the redraws that bag and auction
    -- events cause, which left a new search showing its results part way
    -- down, with the best of them above the view.
    local function ShowFromTop()
        Refresh()
        if widgets.list then widgets.list:ScrollToTop() end
    end

    -- The trend's period (2026-10-14), shared with the tooltip line.
    local trendPeriod = Widgets.CreateDropdown(toolbar, {
        { text = L["Trend: 7 days"], value = 7 },
        { text = L["Trend: 14 days"], value = 14 },
    }, function(value)
        ns.Config:Set("priceTrendDays", value == 14 and 14 or 7)
        Refresh()
    end, { width = 120 })
    trendPeriod:SetPoint("LEFT", 0, 0)
    trendPeriod:SetValue(ns.Prices.TrendDays and ns.Prices:TrendDays() or 7)
    widgets.trendPeriod = trendPeriod

    local search = Widgets.CreateSearchBox(toolbar, L["Search items"], function(text)
        state.search = text or ""
        ShowFromTop()
    end)
    search:SetPoint("LEFT", trendPeriod, "RIGHT", 8, 0)
    search:SetWidth(Widgets.SEARCH_WIDTH)

    local reagentsOnly = Widgets.CreateCheckbox(toolbar, L["Only what I craft with"], function(checked)
        state.reagentsOnly = checked
        ShowFromTop()
    end, false)
    reagentsOnly:SetPoint("LEFT", search, "RIGHT", 12, 0)

    -- Only the starred items (2026-10-06). Remembered, so the tab
    -- opens on the watch list for whoever keeps one.
    state.favouritesOnly = ns.Config:Get("pricesFavouritesOnly") == true
    local favouritesOnly = Widgets.CreateCheckbox(toolbar, L["Favourites only"], function(checked)
        state.favouritesOnly = checked
        ns.Config:Set("pricesFavouritesOnly", checked)
        ShowFromTop()
    end, state.favouritesOnly)
    favouritesOnly:SetPoint("LEFT", reagentsOnly, "RIGHT", 12, 0)

    -- Only the items given their own price (2026-10-06).
    local mineOnly = Widgets.CreateCheckbox(toolbar, L["My prices only"], function(checked)
        state.mineOnly = checked
        ShowFromTop()
    end, false)
    mineOnly:SetPoint("LEFT", favouritesOnly, "RIGHT", 12, 0)

    -- Every enchanting material, scanned or not: the Enchanting tab's
    -- materials list, which moved here (2026-10-07).
    local enchantingOnly = Widgets.CreateCheckbox(toolbar, L["Enchanting materials"], function(checked)
        state.enchantingOnly = checked
        ShowFromTop()
    end, false)
    enchantingOnly:SetPoint("LEFT", mineOnly, "RIGHT", 12, 0)

    -- No sort menu: the headings sort (2026-10-06). The list opens
    -- by market value.

    -- Column headings
    local headings = CreateFrame("Frame", nil, container)
    headings:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -8)
    headings:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", -DETAIL_WIDTH - 8, -8)
    headings:SetHeight(16)

    local nameHeading = Theme.CreateLabel(headings, "tiny", "muted")
    nameHeading:SetPoint("LEFT", 46, 0)
    nameHeading:SetText(L["ITEM"])

    local sortLabels, cells = { name = nameHeading }, {}
    for _, column in ipairs(COLUMNS) do
        local heading = Theme.CreateLabel(headings, "tiny", "muted", column.justify or "RIGHT")
        heading:SetText(column.label)
        sortLabels[column.key] = heading
        cells[column.key] = heading
    end
    ns.Columns:Place("prices", COLUMNS, cells)

    -- Click a heading to sort by it. Unknown ages sort as unknown, not as
    -- the oldest.
    local function Field(key) return function(row) return row[key] end end
    widgets.sorter = Widgets.SortableHeadings and Widgets.SortableHeadings(sortLabels, {
        name = Field("name"), market = Field("market"), min = Field("min"),
        quantity = Field("quantity"), liquidity = Field("liquidity"), trend = Field("trend"),
        age = function(row) return row.age ~= math.huge and row.age or nil end,
    }, function() ShowFromTop() end)
    if widgets.sorter then widgets.sorter:SetText({ "name" }) end

    -- Right-click the headings to choose the columns.
    ns.Columns:Attach(headings, "prices", widgets.sorter)
    ns.Columns:OnChange("prices", function()
        ns.Columns:Place("prices", COLUMNS, cells)
        if widgets.sorter then widgets.sorter:Sync() end
        if widgets.list then widgets.list:Refresh() end
    end)

    local divider = Theme.CreateDivider(container, "borderLit")
    divider:SetPoint("TOPLEFT", headings, "BOTTOMLEFT", 0, -2)
    divider:SetPoint("TOPRIGHT", headings, "BOTTOMRIGHT", 0, -2)

    local list = Widgets.CreateScrollList(container, {
        -- The headings move in with the rows when the scrollbar takes its room.
        onScrollbarShown = function(shown)
            headings:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", -DETAIL_WIDTH - 8 - (shown and 10 or 0), -8)
        end,
        rowHeight = ROW_HEIGHT,
        createRow = CreateRow,
        updateRow = UpdateRow,
        onEnter = function(row, entry) Widgets.ShowItemOnly(row, entry.itemID, entry.label) end,
        onLeave = function() GameTooltip:Hide() end,
        -- The row the detail pane is showing stays lit.
        isSelected = function(entry)
            return state.selected ~= nil and entry.itemID == state.selected.itemID
        end,

        onClick = function(entry)
            state.selected = entry
            UpdateDetail(entry)
        end,
    })
    list:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -4)
    list:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -DETAIL_WIDTH - 16, 24)
    widgets.list = list

    local emptyLabel = Theme.CreateLabel(container, "small", "dim", "CENTER")
    emptyLabel:SetPoint("CENTER", list, "CENTER")
    emptyLabel:SetWidth(320)
    emptyLabel:SetWordWrap(true)
    widgets.emptyLabel = emptyLabel
    if Widgets.DressEmpty then Widgets.DressEmpty(emptyLabel) end

    local countLabel = Theme.CreateLabel(container, "tiny", "dim")
    countLabel:SetPoint("BOTTOMLEFT", 8, 8)
    widgets.countLabel = countLabel

    local detail = BuildDetail(container)
    detail:SetPoint("TOPRIGHT", container, "TOPRIGHT", -8, -40)
    detail:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -8, 8)
    widgets.detail = detail

    UpdateDetail(nil)
end

--------------------------------------------------------------------------------
-- Details and Stats (the owner, 2026-10-29): the Stats tab's charts moved
-- in here behind the house's small view tabs, one tab fewer on the strip.
-- UI/Tab_Stats.lua hands over its view as ns.StatsUI.view.
--------------------------------------------------------------------------------

local PricesUI = {}
ns.PricesUI = PricesUI
PricesUI.view = "details"

local VIEW_TOP = 32

--- The Stats view, when UI/Tab_Stats.lua is loaded.
local function StatsView()
    return ns.StatsUI and ns.StatsUI.view
end

local function SelectedItem()
    return state.selected and state.selected.itemID
end

--- Show Details or Stats. Stats opens on the item Details had picked.
function PricesUI:ShowView(key, itemID)
    if key ~= "stats" or not StatsView() then key = "details" end
    self.view = key
    if widgets.viewTabs then widgets.viewTabs:Select(key, true) end
    if widgets.detailsView then widgets.detailsView:SetShown(key == "details") end
    if widgets.statsView then widgets.statsView:SetShown(key == "stats") end
    if key == "stats" then
        local stats = StatsView()
        if stats.onShow then stats.onShow() end
        if ns.StatsUI.Pick then ns.StatsUI:Pick(itemID or SelectedItem()) end
        if stats.refresh then stats.refresh() end
    else
        Refresh()
    end
end

--- True while the Stats view is the one showing.
function PricesUI:ShowingStats()
    return UI.activeTab == "prices" and self.view == "stats"
end

local function Build(container)
    local stats = StatsView()
    local tabs = { { key = "details", text = L["Details"] } }
    if stats then tabs[#tabs + 1] = { key = "stats", text = L["Stats"] } end
    local viewTabs = Widgets.CreateViewTabs(container, tabs, function(key)
        PricesUI:ShowView(key)
    end)
    viewTabs:SetPoint("TOPLEFT", container, "TOPLEFT", 8, -6)
    viewTabs:SetPoint("RIGHT", container, "RIGHT", -8, 0)
    widgets.viewTabs = viewTabs

    local detailsView = CreateFrame("Frame", nil, container)
    detailsView:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -VIEW_TOP)
    detailsView:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
    widgets.detailsView = detailsView
    BuildDetails(detailsView)

    if stats then
        local statsView = CreateFrame("Frame", nil, container)
        statsView:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -VIEW_TOP)
        statsView:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
        statsView:Hide()
        widgets.statsView = statsView
        stats.build(statsView)
    end

    viewTabs:Select(PricesUI.view, true)
    detailsView:SetShown(PricesUI.view ~= "stats")
end

local function RefreshShown()
    if PricesUI.view == "stats" and StatsView() then
        StatsView().refresh()
    else
        Refresh()
    end
end

UI:RegisterTab({
    key = "prices",
    text = L["Prices"],
    order = 8,
    build = Build,
    refresh = RefreshShown,
    onShow = function()
        if PricesUI.view == "stats" and StatsView() and StatsView().onShow then StatsView().onShow() end
    end,
})
