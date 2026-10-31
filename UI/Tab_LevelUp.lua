-- Blackthornes Tradeskills -- UI/Tab_LevelUp.lua
-- The cheapest way up a profession: what still gives skill, cheapest first.
--
-- The ranking lives in Logic/LevelUp.lua. This file only draws it, and hands
-- anything picked here to the one craft queue the Queue tab and the craft
-- pane also show.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local UI = ns.UI

local ROW_HEIGHT = 22
local DETAIL_WIDTH = 300

-- Columns, measured from the right edge of the list and laid out right to
-- left. Money sits to the right, so its coins line up; the rest is centred
-- under its heading. `width` is the least each gets: Widgets.FitColumns
-- widens it to fit the heading and a full amount.
local COLUMNS = {
    -- Learn next (2026-10-12): where an unlearned recipe is learned, what
    -- it costs, and a Show the way button, all lined up at the far right.
    -- Shown only while Learn next is ticked.
    { key = "way",    label = "", menuText = L["Show the Way"], width = 84, button = "way", learnOnly = true },
    { key = "where",  label = L["WHERE"], width = 120, justify = "LEFT", learnOnly = true },
    { key = "learn",  label = L["LEARN"], width = 50, money = true, learnOnly = true },
    { key = "make",   label = L["MAKE"], width = 40, justify = "CENTER" },
    { key = "real",   label = L["REAL COST"], width = 74, money = true },
    { key = "via",    label = L["VIA"], width = 44, justify = "CENTER" },
    { key = "back",   label = L["GETS BACK"], width = 74, money = true },
    { key = "cost",   label = L["COST"], width = 74, money = true },
    { key = "chance", label = L["SKILL UP"], width = 80, justify = "CENTER" },
    -- Make or Buy when another craft uses the item: a button that says
    -- whether it is made as a sub-craft (2026-10-07).
    { key = "sub",    label = L["SUB-CRAFT"], width = 50, justify = "CENTER", button = true },
}

-- Any column but the recipe's name can be hidden (UI/Columns.lua).
ns.Columns:Register("levelup", L["Level Up"], COLUMNS)

-- How each way of getting gold back is named: short in the VIA column, in
-- full in the tooltip and the detail panel.
local WAY_SHORT = { vendor = L["Vendor"], auction = L["AH"], disenchant = L["DE"] }
-- In a sentence, for the note on which way the Profit tab counts.
local WAY_WORD = { vendor = L["vendor"], auction = L["auction house"], disenchant = L["disenchant"] }
local WAY_LONG = {
    vendor = L["Vendor"],
    auction = L["Auction house, after the cut"],
    disenchant = L["Disenchant, most likely result"],
}

local state = {
    search = "",
    profession = nil,       -- a profession name, or nil for all of them
    followed = nil,         -- the last-open skill line the choice was made from
    started = false,        -- a default has been picked once already
    craftableOnly = false,
    canAfford = false,
    includeTrivial = false,
    subCraftsOnly = false,
    learnNext = true,
    selected = nil,
}

--- Are the Learn next rows and columns showing?
local function LearnShown()
    return state.learnNext and not state.subCraftsOnly
end

local widgets = {}

-- What a click does is on each row's hover, not under the list (the owner,
-- 2026-10-29: label and value only).
-- The row's menu (a right-click, the house kit, 2026-10-29), the usual
-- one first: a recipe to learn shows the way, one you know is queued.
local function RowMenu(entry)
    if entry.heading then return nil end
    local lines = {}
    if entry.learnNext then
        lines[1] = { text = L["Show the Way"], run = function() ns.LearnNext:ShowTheWay(entry) end }
    else
        lines[1] = { text = L["Queue One"], run = function()
            ns.Queue:Add(entry.recipeID, 1)
            ns.Print(L.Format("queued %dx %s", 1, entry.name or L["craft"]))
        end }
    end
    local itemID = Widgets.RowItemID(entry)
    if itemID and ns.Scanner and ns.Scanner.isAuctionHouseOpen then
        lines[#lines + 1] = { text = L["Search the Auction House"], run = function()
            ns.UI:SearchAuctionHouse(itemID)
        end }
    end
    return lines
end

-- Defined with the detail panel, used by the controls built inside it.
local UpdateCraftButton

-- Defined after Build; Sub-crafts only rebuilds the profession list with it.
local OnShow
local FitToolbar

-- Profession name -> set of skill-line IDs carrying it. Forever lists every
-- profession under two IDs and a recipe may be tagged with either, so the
-- dropdown works in names and filters by the whole set.
local skillLinesByName = {}
local nameBySkillLine = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function ProfessionInfo(skillLineID)
    if not skillLineID then return nil end
    if not Util.HasFunction("C_TradeSkillUI.GetProfessionInfoBySkillLineID") then return nil end

    local ok, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, skillLineID)
    if ok and type(info) == "table" then return info end

    return nil
end

--- A profession's name where the client gives no profession info (Era):
-- the client's own word, else the book's English one.
local function ProfessionName(skillLineID)
    local name = ns.EraRecipes and ns.EraRecipes:LineName(skillLineID)
    if name then return name end
    return ns.RecipeBook and ns.RecipeBook.ProfessionName and ns.RecipeBook:ProfessionName(skillLineID) or nil
end

--- The game's colour for a tier, or plain text for one never read.
local function TierColor(tier)
    if not tier or tier == "unknown" then return Theme.Unpack("muted") end
    return ns.SkillUp:GetTierColor(tier)
end

-- Rounded: this client refuses a fraction for %x, and the tier colours
-- scale to 127.5 and the like.
local function ColorCode(r, g, b)
    return ("|cff%02x%02x%02x"):format(math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

--- The row's SUB-CRAFT button: Vendor, Make or Buy for an item a vendor
--- sells (2026-10-13), Make or Buy for the rest. Make on an item no vendor
--- sells is the usual (made when cheaper), so it needs no third state.
local function SubCraftState(entry)
    if entry.subChoice == "buy" or (entry.subChoice == nil and entry.neverSubCraft) then return "buy" end
    if entry.vendorSells then return entry.subChoice == "make" and "make" or "vendor" end
    return "make"
end

local SUB_LABEL = { vendor = L["Vendor"], make = L["Make"], buy = L["Buy"] }

--- Size the SUB-CRAFT button, and its column, to the widest of its three
--- words, so "Vendor" (or a longer German word) never ends in "...".
local function FitSubButton(button, column)
    local label = rawget(button, "label")
    if type(label) ~= "table" or not Theme.TextWidth then return end
    local widest = 0
    for _, text in pairs(SUB_LABEL) do
        label:SetText(text)
        local width = Theme.TextWidth(label)
        if type(width) == "number" and width > widest then widest = width end
    end
    label:SetText(L["Make"])
    local need = math.ceil(widest + 12)
    local ok, width = pcall(button.GetWidth, button)
    if ok and type(width) == "number" and need > width then
        button:SetWidth(need)
        if need + 2 > column.width then column.width = need + 2 end
    end
end

--- One click moves the button on: Vendor, Make, Buy, then Vendor again; on
--- an item no vendor sells, Make and Buy. Cost:SetSubCraftChoice redraws
--- everything.
local function ToggleSubCraft(entry)
    if not entry then return end
    local name = entry.name or L["that craft"]
    local state = SubCraftState(entry)

    if entry.vendorSells then
        if state == "vendor" then
            ns.Cost:SetSubCraftChoice(entry.recipeID, "make", entry.name)
            ns.Print(L.Format("%s is always made when another craft needs it, whatever buying it costs.", name))
        elseif state == "make" then
            ns.Cost:SetSubCraftChoice(entry.recipeID, "buy", entry.name)
            ns.Print(L.Format("%s is never made and is priced at the auction house, not the vendor, when another craft needs it.", name))
        else
            ns.Cost:SetSubCraftChoice(entry.recipeID, nil, entry.name)
            ns.Print(L.Format("%s is priced at the vendor again when another craft needs it.", name))
        end
        return
    end

    local never = state ~= "buy"
    ns.Cost:SetSubCraftChoice(entry.recipeID, never and "buy" or nil, entry.name)
    if never then
        ns.Print(L.Format("%s is no longer made as a sub-craft. Crafts that use it buy it instead.", name))
    else
        ns.Print(L.Format("%s is made as a sub-craft again when that is cheaper than buying it.", name))
    end
end

local function SubCraftTooltip(entry)
    local name = entry.name or L["this"]
    local state = SubCraftState(entry)
    local text

    if entry.vendorSells then
        if state == "vendor" then
            text = L.Format("Vendor: crafts count %s at the vendor's price, and make it only when that's cheaper.\nClick for Make: always make it.", name)
        elseif state == "make" then
            text = L.Format("Make: %s is always made for other crafts, whatever buying it costs.\nClick for Buy: never make it, and use the auction house price.", name)
        else
            text = L.Format("Buy: %s is never made for other crafts, and uses the auction house price.\nClick for Vendor to use the vendor's price again.", name)
        end
    elseif state == "buy" then
        text = L.Format("Buy: %s is never made for other crafts. It's bought instead.\nClick to make it again when that's cheaper.", name)
    else
        text = L.Format("Make: %s is made for other crafts when that's cheaper than buying it.\nClick to always buy it instead.", name)
    end
    if not entry.isMaterial then
        text = text .. "\n" .. L["No craft your characters know uses it yet."]
    end
    return text
end

-- Columns set aside while the list is too narrow for them all, so the
-- recipe's name keeps NAME_MIN. Learn next's three columns took all the
-- name's room on the window's own width (more with German or a larger
-- text size), and the columns ran over the names and into each other.
-- The least needed go first; the saved column choice is left alone, and
-- they come back as soon as there is room (Learn next unticked).
local NAME_MIN = 160
local SQUEEZE_ORDER = { "via", "back", "make", "sub", "real" }
local squeezed = {}
local layoutVersion = 0

--- The shown columns from the right edge; the name has the rest. The
--- SUB-CRAFT button sits centred in its column, or stays hidden with it.
local function ColumnVisible(column)
    if squeezed[column.key] then return false end
    return not column.learnOnly or LearnShown()
end

--- Work out which columns fit the list's width; with the width not known
--- yet (not laid out), nothing is set aside.
local function Squeeze(room)
    layoutVersion = layoutVersion + 1
    wipe(squeezed)
    local learnOk = function(column) return not column.learnOnly or LearnShown() end
    for key in pairs(ns.Columns:Squeeze("levelup", COLUMNS, room, {
        order = SQUEEZE_ORDER, nameMin = NAME_MIN, left = 28 + 4, visible = learnOk })) do
        squeezed[key] = true
    end
end

--- Lay the headings out for the list's width; the rows follow on their
--- next draw (layoutVersion).
local function PlaceHeadings()
    local headings = widgets.headings
    local ok, room = pcall(function() return headings and headings:GetWidth() end)
    Squeeze(ok and room or nil)
    if widgets.headingCells then
        ns.Columns:Place("levelup", COLUMNS, widgets.headingCells, { visible = ColumnVisible })
    end
end

local function PlaceRow(row)
    local offset = ns.Columns:Place("levelup", COLUMNS, row.cells, {
        visible = ColumnVisible,
        place = function(column, offset, shown)
            local button = column.button == "way" and row.wayButton
                or column.button and row.subButton
            if not button then return end
            if column.button == "way" then row.wayHidden = not shown else row.subHidden = not shown end
            if shown then
                local width = math.min(column.width, column.button == "way" and column.width or 48)
                button:ClearAllPoints()
                button:SetPoint("RIGHT", row, "RIGHT", offset - (column.width - width) / 2, 0)
            else
                button:Hide()
            end
        end,
    })
    row.name:SetPoint("RIGHT", row, "RIGHT", offset - 4, 0)
    row.columnsVersion = ns.Columns.version
    row.learnShown = LearnShown()
    row.layoutVersion = layoutVersion
end

local function CreateRow(row)
    -- The item's icon beside its name, as the bags draw it.
    row.icon = Theme.CreateItemIcon(row, 16)
    row.icon:SetPoint("LEFT", 8, 0)

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("LEFT", 28, 0)

    row.cells = {}
    for _, column in ipairs(COLUMNS) do
        if column.button == "way" then
            row.wayButton = Widgets.CreateButton(row, L["Show the Way"], function()
                if row.data and row.data.learnNext then ns.LearnNext:ShowTheWay(row.data) end
            end, { width = column.width, height = 16,
                   tooltip = L["Put a pin on your map where this recipe is learned"] })
        elseif column.button then
            row.subButton = Widgets.CreateButton(row, L["Make"], function()
                ToggleSubCraft(row.data)
            end, { width = math.min(column.width, 48), height = 16 })
            FitSubButton(row.subButton, column)
        else
            row.cells[column.key] = Theme.CreateLabel(row, "small", "text", column.justify or "RIGHT")
        end
    end
    -- A zone's name wraps under "Vendor" rather than ending in "...".
    row.cells.where:SetWordWrap(true)

    -- The LEARN NEXT heading, drawn on a row of its own between the
    -- recipes known and those to learn.
    row.heading = Theme.CreateLabel(row, "tiny", "accent")
    row.heading:SetPoint("LEFT", 8, 0)
    row.heading:SetText(L["LEARN NEXT"])
    row.heading:Hide()

    PlaceRow(row)
end

--- The LEARN NEXT heading row: everything else on it hidden.
local function ShowHeadingRow(row, heading)
    row.heading:SetShown(heading)
    row.icon:SetShown(not heading)
    row.name:SetShown(not heading)
    if heading then
        for _, cell in pairs(row.cells) do cell:Hide() end
    elseif row.wasHeading then
        -- Back to a recipe: the columns shown come back as they were.
        PlaceRow(row)
    end
    row.wasHeading = heading
end

--- A recipe to learn: its colour, where it is learned and what it costs.
local function UpdateLearnCells(row, entry)
    local cells = row.cells
    if entry.price then
        Theme.SetMoneyText(cells.learn, entry.price, { short = true })
        cells.learn:SetTextColor(Theme.Unpack("text"))
    else
        cells.learn:SetText("--")
        cells.learn:SetTextColor(Theme.Unpack("dim"))
    end

    local kind, zone = ns.LearnNext.WhereText(entry.place)
    if zone then
        cells.where:SetText(("%s |cff7a8089%s|r"):format(kind, zone))
    else
        cells.where:SetText(kind)
    end
    cells.where:SetTextColor(Theme.Unpack(entry.locked and "dim" or "text"))

    if entry.locked then
        row.name:SetTextColor(Theme.Unpack("dim"))
        cells.chance:SetText(L.Format("At %d", entry.needs))
        cells.chance:SetTextColor(Theme.Unpack("dim"))
        cells.make:SetText("--")
        cells.make:SetTextColor(Theme.Unpack("dim"))
    end
end

local function UpdateRow(row, entry)
    if row.columnsVersion ~= ns.Columns.version or row.learnShown ~= LearnShown()
        or row.layoutVersion ~= layoutVersion then PlaceRow(row) end
    row.data = entry

    ShowHeadingRow(row, entry.heading == true)
    if entry.heading then
        if row.subButton then row.subButton:Hide() end
        if row.wayButton then row.wayButton:Hide() end
        return
    end

    local cells = row.cells
    if not entry.learnNext then
        cells.learn:SetText("")
        cells.where:SetText("")
    end

    -- Coloured the way the profession window colours it, so the list reads
    -- the same as the game without being told what orange means.
    local name = entry.name or L.Format("recipe %s", entry.recipeID)
    -- A craft only another character knows (Sub-crafts only) says who.
    if entry.knownBy and ns.Recipes.GetShortCharacterName then
        name = ("%s |cff7a8089(%s)|r"):format(name, ns.Recipes:GetShortCharacterName(entry.knownBy))
    end
    -- An enchant makes no item, so it shows its spell's icon, with the green
    -- arrow and where it goes when Equipment says it beats what is on your
    -- gear now (see Logic/Upgrades.lua).
    local forYou = not entry.outputItemID and ns.Upgrades and ns.Upgrades:EnchantText(entry.recipeID)
    if forYou then
        name = ("%s  |c%s%s|r"):format(name, ns.COLORS.profit or "ff4fd17a", forYou)
    elseif entry.outputItemID and ns.Upgrades and ns.Upgrades.WithAltText then
        name = ns.Upgrades:WithAltText(name, entry.outputItemID)
    end
    Theme.SetRowName(row.name, name)
    row.name:SetTextColor(TierColor(entry.tier))
    if entry.outputItemID then
        Theme.SetItemIcon(row.icon, entry.outputItemID)
    else
        Theme.SetSpellIcon(row.icon, entry.recipeID, forYou ~= nil)
    end

    cells.chance:SetText(ns.LevelUp.CHANCE_LABEL[entry.tier] or "")
    cells.chance:SetTextColor(TierColor(entry.tier))

    if entry.cost then
        Theme.SetMoneyText(cells.cost, entry.cost, { short = true })
        cells.cost:SetTextColor(Theme.Unpack("text"))
    else
        cells.cost:SetText(L["no price"])
        cells.cost:SetTextColor(Theme.Unpack("dim"))
    end

    if entry.back then
        Theme.SetMoneyText(cells.back, entry.back, { short = true })
        cells.via:SetText(WAY_SHORT[entry.backWay] or "")
        cells.via:SetTextColor(Theme.Unpack("muted"))
    else
        cells.back:SetText("--")
        cells.back:SetTextColor(Theme.Unpack("dim"))
        cells.via:SetText("")
    end

    -- What levelling on it really costs once it is sold back. Below nothing
    -- the craft pays for itself, shown as a gain in green.
    if entry.realCost and entry.realCost < 0 then
        -- Fitted a little narrower, so the plus sign has room too.
        local width = cells.real:GetWidth()
        cells.real:SetWidth(width - 8)
        Theme.SetMoneyText(cells.real, -entry.realCost, { short = true })
        cells.real:SetWidth(width)
        cells.real:SetText("+" .. (cells.real:GetText() or ""))
        cells.real:SetTextColor(Theme.Unpack("profit"))
    elseif entry.realCost or entry.cost then
        Theme.SetMoneyText(cells.real, entry.realCost or entry.cost, { short = true })
        cells.real:SetTextColor(Theme.Unpack("text"))
    else
        cells.real:SetText(L["no price"])
        cells.real:SetTextColor(Theme.Unpack("dim"))
    end

    local craftable = entry.craftableNow or 0
    cells.make:SetText(tostring(craftable))
    cells.make:SetTextColor(Theme.Unpack(craftable > 0 and "text" or "loss"))

    -- On every craft that makes an item (2026-10-09): only on
    -- those another known craft used, a craft whose user was never read
    -- could not be marked.
    local button = row.subButton
    if button then
        local shown = entry.outputItemID ~= nil and not entry.learnNext
        button:SetShown(shown == true and not row.subHidden)
        if shown then
            button:SetText(SUB_LABEL[SubCraftState(entry)])
            button.tooltipText = SubCraftTooltip(entry)
        end
    end

    if row.wayButton then
        row.wayButton:SetShown(entry.learnNext == true and not entry.locked and not row.wayHidden)
    end

    if entry.learnNext then UpdateLearnCells(row, entry) end
end

--- A reading taken at a lower skill may have changed colour since. Said out
--- loud rather than quietly trusted.
local function StaleNote(skillUp)
    if not skillUp or not skillUp.stale then return nil end

    return L.Format("Read at skill %d, and you're %d now. Open your profession to refresh it.",
        skillUp.skill or 0, skillUp.currentSkill or 0)
end

--- How a recipe to learn is got, as { label, value } pairs: the recipe
--- item or the trainer and its price, who, where and the skill it needs.
local function LearnLines(entry)
    local place, lines = entry.place, {}
    if not place then return lines end
    local price = entry.price and Util.FormatMoney(entry.price, { noColor = true }) or "--"
    if place.kind == "trainer" then
        lines[#lines + 1] = { L["Trainer"], price }
        lines[#lines + 1] = { L["Taught by"], place.name or "" }
    else
        local item = place.itemID and Util.GetItemLabel(place.itemID)
        item = item and Util.Uncolored and Util.Uncolored(item) or item
        lines[#lines + 1] = { item or L["Recipe"], price }
        lines[#lines + 1] = { L["Sold by"], place.name or "" }
    end
    if place.zone then
        lines[#lines + 1] = { L["Where"], place.x and ("%s (%s, %s)"):format(place.zone, place.x, place.y)
            or place.zone }
    end
    local profession = nameBySkillLine[entry.skillLineID] or (entry.record and entry.record.profession) or ""
    lines[#lines + 1] = { L["Needs"], ("%s %d"):format(profession, entry.needs or 0) }
    local forYou = ns.Upgrades and ns.Upgrades:EnchantText(entry.recipeID, true)
    if forYou then lines[#lines + 1] = { L["Best for you"], forYou } end
    return lines
end

local function ShowRowTooltip(row, entry)
    if entry.heading then
        -- What the heading means lives on its hover, not beside it.
        GameTooltip:SetOwner(row, "ANCHOR_LEFT")
        GameTooltip:SetText(L["LEARN NEXT"], Theme.Unpack("accent"))
        GameTooltip:AddLine(L["recipes you don't know yet that raise your skill now, cheapest way up first"], 1, 1, 1, true)
        GameTooltip:Show()
        return
    end
    ns.Widgets.ShowItemTooltip(row, "ANCHOR_LEFT", entry.outputItemID, entry.name or L["craft"])
    GameTooltip:AddLine(" ")

    local r, g, b = TierColor(entry.tier)
    local chance = entry.tier == "unknown" and L["not read yet"]
        or ns.SkillUp:GetTierLabel(entry.tier)
    GameTooltip:AddDoubleLine(L["Skill up"], chance, 0.7, 0.7, 0.7, r, g, b)

    local steps = entry.recipeID and ns.SkillUp:ColorSteps(entry.recipeID)
    if steps then GameTooltip:AddLine(steps, 1, 1, 1, true) end

    GameTooltip:AddDoubleLine(L["Materials"], entry.cost
        and Util.FormatMoney(entry.cost, { noColor = true }) or L["no price"],
        0.7, 0.7, 0.7, 1, 1, 1)

    local returns = entry.returns
    local anyWay = returns and (returns.vendor or returns.auction or returns.disenchant)
    if anyWay then
        for _, way in ipairs({ "vendor", "auction", "disenchant" }) do
            if returns[way] then
                local r, g, b = 1, 1, 1
                if way == entry.backWay then r, g, b = Theme.Unpack("profit") end
                GameTooltip:AddDoubleLine(WAY_LONG[way], Util.FormatMoney(returns[way], { noColor = true }),
                    0.7, 0.7, 0.7, r, g, b)
            end
        end

        if entry.realCost then
            local gain = entry.realCost < 0
            local r, g, b = 1, 1, 1
            if gain then r, g, b = Theme.Unpack("profit") end
            GameTooltip:AddDoubleLine(gain and L["Pays you back"] or L["Real cost"],
                Util.FormatMoney(math.abs(entry.realCost), { noColor = true }),
                1, 0.82, 0, r, g, b)
        end

        -- The Profit tab's "Profit:" choice picks the way that counts.
        if returns.method and returns.method ~= "best" then
            local label = WAY_WORD[returns.method] or returns.method
            local text = returns.best
                and L.Format("Only the %s counts, because the Profit tab is set to it.", label)
                or L.Format("Only the %s counts (the Profit tab is set to it), and it pays nothing for this.", label)
            GameTooltip:AddLine(text, 0.7, 0.7, 0.7, true)
        end
    elseif entry.outputItemID then
        GameTooltip:AddLine(L["Nothing to sell it back for yet. It has no vendor, auction or disenchant price."], 0.7, 0.7, 0.7, true)
    end

    local note = StaleNote(entry.skillUp)
    if note then GameTooltip:AddLine(note, 0.91, 0.76, 0.35, true) end

    local short = not entry.learnNext and ns.LevelUp:ShortNote(entry)
    if short then GameTooltip:AddLine(short, Theme.Unpack("loss")) end

    local forYou = not entry.learnNext and ns.Upgrades and ns.Upgrades:EnchantText(entry.recipeID)
    if forYou then GameTooltip:AddLine(forYou, Theme.Unpack("profit")) end
    local forAlt = entry.outputItemID and ns.Upgrades and ns.Upgrades.AltText and ns.Upgrades:AltText(entry.outputItemID)
    if forAlt then GameTooltip:AddLine(forAlt, Theme.Unpack("profit")) end

    if entry.neverSubCraft then
        GameTooltip:AddLine(L["Never made as a sub-craft. Crafts that use it buy it instead."], 0.91, 0.76, 0.35, true)
    elseif entry.subChoice == "make" then
        GameTooltip:AddLine(L["Always made as a sub-craft, whatever buying it costs."], 0.91, 0.76, 0.35, true)
    end

    if entry.learnNext then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(entry.locked and L.Format("You can learn this at %d.", entry.needs)
            or L["You can learn this now."], Theme.Unpack(entry.locked and "warn" or "accent"))
        for _, line in ipairs(LearnLines(entry)) do
            GameTooltip:AddDoubleLine(line[1], line[2], 0.7, 0.7, 0.7, 1, 1, 1)
        end
        GameTooltip:AddLine(L["Right-click to show the way. Shift-click to search the auction house."], 0.5, 0.5, 0.5)
        GameTooltip:Show()
        return
    end

    GameTooltip:AddLine(L["Right-click to queue one. Shift-click to search the auction house."], 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- Detail panel
--------------------------------------------------------------------------------

--- Set the Craft button for the selected recipe: craft, open its profession
--- window first, stop a craft under way, or say why it cannot.
UpdateCraftButton = function()
    local detail = widgets.detail
    local button = detail and detail.craftButton
    if not button then return end

    local entry = state.selected
    local opener = ns.ProfessionOpener
    button.opensProfession = false

    if not entry or not button:IsVisible() then
        if opener and opener.anchor == button then opener:Disarm() end
        return
    end

    local action = ns.LevelUp:CraftAction(entry.recipeID, detail.quantity:GetText())

    button:SetText(action.text)
    button:SetEnabledState(action.kind ~= "none")
    button.tooltipText = action.status
    detail.craftStatus:SetText(action.status or "")
    detail.craftStatus:SetTextColor(Theme.Unpack(action.kind == "none" and "warn" or "accent"))

    if action.kind == "open" and opener then
        button.opensProfession = true
        opener:Arm(button, action.profession, entry.recipeID)
    elseif opener and opener.anchor == button then
        -- Only our own button: the Queue tab may be holding the secure
        -- button over its Craft button.
        opener:Disarm()
    end
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

local function BuildDetail(parent)
    local detail = Theme.CreatePanel(parent, "window")
    detail:SetWidth(DETAIL_WIDTH)

    Theme.AccentStripe(detail, 2, 0.6)

    local icon = Theme.CreateItemIcon(detail, 30)
    icon:SetPoint("TOPLEFT", 12, -12)
    detail.icon = icon
    if Widgets.ItemHotspot then Widgets.ItemHotspot(icon) end

    local title = Theme.CreateLabel(detail, "large", "accent")
    title:SetPoint("TOPLEFT", 50, -12)
    title:SetPoint("TOPRIGHT", -12, -12)
    title:SetWordWrap(true)
    detail.title = title

    local subtitle = Theme.CreateLabel(detail, "small", "muted")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    subtitle:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
    subtitle:SetWordWrap(true)
    detail.subtitle = subtitle

    local note = Theme.CreateLabel(detail, "tiny", "warn")
    note:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -4)
    note:SetPoint("RIGHT", detail, "RIGHT", -12, 0)
    note:SetWordWrap(true)
    detail.note = note

    local reagentHeading = Theme.CreateLabel(detail, "tiny", "dim")
    -- Back out under the icon, so the list of materials starts at the edge.
    reagentHeading:SetPoint("TOPLEFT", note, "BOTTOMLEFT", -38, -12)
    reagentHeading:SetText(L["MATERIALS"])
    Theme.StyleHeading(reagentHeading, detail)
    detail.reagentHeading = reagentHeading

    detail.reagentLines = {}

    local summary = CreateFrame("Frame", nil, detail)
    summary:SetPoint("BOTTOMLEFT", 12, 72)
    summary:SetPoint("BOTTOMRIGHT", -12, 72)
    summary:SetHeight(6 * 16)
    detail.summary = summary

    local function SummaryRow(index, labelText)
        local label = Theme.CreateLabel(summary, "small", "muted")
        label:SetPoint("TOPLEFT", 0, -(index - 1) * 16)
        label:SetText(labelText)

        local value = Theme.CreateLabel(summary, "small", "text", "RIGHT")
        value:SetPoint("TOPRIGHT", 0, -(index - 1) * 16)
        value:SetPoint("LEFT", label, "RIGHT", 8, 0)

        return value, label
    end

    detail.costValue = SummaryRow(1, L["Materials for one"])
    detail.wayValues = {
        vendor = SummaryRow(2, L["Vendor pays"]),
        auction = SummaryRow(3, L["Auction, after cut"]),
        disenchant = SummaryRow(4, L["Disenchant, likely"]),
    }
    detail.realValue, detail.realLabel = SummaryRow(5, L["Real cost"])
    detail.makeValue = SummaryRow(6, L["You can make now"])

    -- What the Craft button will do, or why it cannot. A craft's progress bar
    -- takes this line's place while it casts. Wrapped, growing upwards into
    -- the space under the summary: "Opens your Leatherworking window. Click
    -- again to craft." is about as wide as the pane on one line, and longer
    -- profession names ran past it.
    local craftStatus = Theme.CreateLabel(detail, "tiny", "accent")
    craftStatus:SetPoint("BOTTOMLEFT", 12, 46)
    craftStatus:SetPoint("BOTTOMRIGHT", -12, 46)
    craftStatus:SetWordWrap(true)
    detail.craftStatus = craftStatus

    detail.craftProgress = ns.CraftProgress:Create(detail, {
        width = DETAIL_WIDTH - 24, height = 18, covers = craftStatus,
    })
    detail.craftProgress:SetPoint("BOTTOMLEFT", 12, 42)

    local quantityBox = Theme.CreatePanel(detail, "row")
    quantityBox:SetSize(40, 24)
    quantityBox:SetPoint("BOTTOMLEFT", 12, 14)
    detail.quantityBox = quantityBox

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
    -- The Craft button names the number it will make, so it follows the box.
    quantity:SetScript("OnTextChanged", function(_, userInput)
        if userInput then UpdateCraftButton() end
    end)
    detail.quantity = quantity

    local function Wanted()
        return math.max(1, tonumber(quantity:GetText()) or 1)
    end

    -- Crafting needs a real click, so this runs straight from the button.
    -- When the recipe's window is not open, the secure Open button laid over
    -- this one takes the click instead and this handler never runs.
    local craftButton = Widgets.CreateButton(detail, L["Craft"], function(button)
        local entry = state.selected
        if not entry then return end

        if ns.Crafting:IsBusy() then
            ns.Crafting:Stop()
        elseif button.opensProfession and ns.ProfessionOpener then
            ns.ProfessionOpener:MissedClick()
        else
            ns.Crafting:Start(entry.recipeID, Wanted())
        end

        UpdateCraftButton()
    end, { width = 110, primary = true, height = 24 })
    craftButton:SetPoint("BOTTOMLEFT", quantityBox, "BOTTOMRIGHT", 6, 0)
    detail.craftButton = craftButton
    -- An Era enchant is made by a secure button laid over this one.
    if ns.SecureCraft then
        ns.SecureCraft:Attach(craftButton, function()
            if state.selected then return state.selected.recipeID, Wanted() end
        end)
    end

    local addButton = Widgets.CreateButton(detail, L["Queue"], function()
        if not state.selected then return end

        local count = Wanted()
        ns.Queue:Add(state.selected.recipeID, count)
        ns.Print(L.Format("queued %dx %s", count, state.selected.name or L["craft"]))
    end, { width = 64, height = 24, tooltip = L["Add this many to the craft queue"] })
    addButton:SetPoint("BOTTOMLEFT", craftButton, "BOTTOMRIGHT", 6, 0)
    detail.addButton = addButton

    local maxButton = Widgets.CreateButton(detail, L["Max"], function()
        if not state.selected then return end
        quantity:SetText(tostring(math.max(1, state.selected.craftableNow or 1)))
        UpdateCraftButton()
    end, { width = 40, height = 24, tooltip = L["As many as the materials in your bags make"] })
    maxButton:SetPoint("BOTTOMLEFT", addButton, "BOTTOMRIGHT", 6, 0)
    detail.maxButton = maxButton

    -- A recipe to learn (Learn next) has its own pane: how to get it, what
    -- one craft takes, Show the way and Queue materials.
    local learn = CreateFrame("Frame", nil, detail)
    learn:SetPoint("TOPLEFT", note, "BOTTOMLEFT", -38, -12)
    learn:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -12, 12)
    learn:Hide()
    detail.learnPane = learn

    local function PaneLine(anchor, gap)
        local frame = CreateFrame("Frame", nil, learn)
        frame:SetHeight(16)
        frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, gap or 0)
        frame:SetPoint("RIGHT", learn, "RIGHT", 0, 0)
        local value = Theme.CreateLabel(frame, "small", "text", "RIGHT")
        value:SetPoint("RIGHT", 0, 0)
        local label = Theme.CreateLabel(frame, "small", "muted")
        label:SetPoint("LEFT", 0, 0)
        label:SetPoint("RIGHT", value, "LEFT", -8, 0)
        frame.label, frame.value = label, value
        return frame
    end

    local howHeading = Theme.CreateLabel(learn, "tiny", "dim")
    howHeading:SetPoint("TOPLEFT", 0, 0)
    howHeading:SetText(L["HOW TO GET IT"])
    Theme.StyleHeading(howHeading, learn)

    learn.how = {}
    local anchor = howHeading
    for index = 1, 5 do
        learn.how[index] = PaneLine(anchor, index == 1 and -6 or 0)
        anchor = learn.how[index]
    end

    local makeHeading = Theme.CreateLabel(learn, "tiny", "dim")
    makeHeading:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -14)
    makeHeading:SetText(L["TO MAKE ONE"])
    Theme.StyleHeading(makeHeading, learn)

    learn.materials = {}
    anchor = makeHeading
    for index = 1, 6 do
        learn.materials[index] = PaneLine(anchor, index == 1 and -6 or 0)
        anchor = learn.materials[index]
    end

    learn.wayButton = Widgets.CreateButton(learn, L["Show the Way"], function()
        if state.selected and state.selected.learnNext then ns.LearnNext:ShowTheWay(state.selected) end
    end, { width = 120, height = 24, primary = true,
           tooltip = L["Put a pin on your map where this recipe is learned"] })
    learn.wayButton:SetPoint("BOTTOMLEFT", 0, 2)

    learn.queueButton = Widgets.CreateButton(learn, L["Queue materials"], function()
        if state.selected and state.selected.learnNext then ns.LearnNext:QueueMaterials(state.selected) end
    end, { width = 130, height = 24,
           tooltip = L["Puts the materials to reach yellow on your list to buy"] })
    learn.queueButton:SetPoint("BOTTOMLEFT", learn.wayButton, "BOTTOMRIGHT", 8, 0)
    GrowToFit(learn.wayButton)
    GrowToFit(learn.queueButton)

    local empty = Theme.CreateLabel(detail, "small", "dim", "CENTER")
    empty:SetPoint("CENTER")
    empty:SetWidth(DETAIL_WIDTH - 40)
    empty:SetWordWrap(true)
    empty:SetText(L["Pick a recipe to see its materials."])
    detail.empty = empty

    return detail
end

--- The detail pane for a recipe to learn.
local function UpdateLearnDetail(detail, entry)
    detail.title:SetText(entry.name or L.Format("recipe %s", entry.recipeID))
    local iconItem = entry.outputItemID or (entry.place and entry.place.itemID)
    if iconItem then
        Theme.SetItemIcon(detail.icon, iconItem)
    else
        Theme.SetSpellIcon(detail.icon, entry.recipeID, ns.Upgrades and ns.Upgrades:EnchantFor(entry.recipeID) ~= nil)
    end

    if entry.locked then
        detail.subtitle:SetText(L.Format("You can learn this at %d", entry.needs or 0))
        detail.subtitle:SetTextColor(Theme.Unpack("warn"))
    else
        local tier = entry.tier ~= "unknown" and ns.SkillUp:GetTierLabel(entry.tier) or L["skill up not known"]
        detail.subtitle:SetText(L.Format("You can learn this · %s at %d", tier, entry.skill or 0))
        detail.subtitle:SetTextColor(TierColor(entry.tier))
    end
    detail.note:SetText("")

    local learn = detail.learnPane
    local lines = LearnLines(entry)
    for index, line in ipairs(learn.how) do
        local row = lines[index]
        line:SetShown(row ~= nil)
        if row then
            line.label:SetText(row[1])
            line.value:SetText(row[2])
        end
    end

    local reagents = (entry.costDetail and entry.costDetail.reagents) or {}
    if #reagents == 0 and entry.record then reagents = entry.record.reagents or {} end
    for index, line in ipairs(learn.materials) do
        local reagent = reagents[index]
        line:SetShown(reagent ~= nil)
        if reagent then
            if index == #learn.materials and #reagents > index then
                line.label:SetText(L.Format("and %d more", #reagents - index + 1))
                line.value:SetText("")
            else
                line.label:SetText(("%dx %s"):format(reagent.quantity or 1,
                    Util.Uncolored(Util.GetItemLabel(reagent.itemID))))
                if reagent.lineCost then
                    line.value:SetText(Util.FormatMoney(reagent.lineCost, { short = true }))
                    line.value:SetTextColor(Theme.Unpack("muted"))
                else
                    line.value:SetText(L["no price"])
                    line.value:SetTextColor(Theme.Unpack("dim"))
                end
            end
        end
    end

    learn.wayButton:SetEnabledState(entry.place ~= nil)
end

local function UpdateDetail(entry)
    local detail = widgets.detail
    local shown = entry ~= nil

    detail.empty:SetShown(not shown)

    for _, line in ipairs(detail.reagentLines) do
        line.frame:Hide()
    end

    detail.icon:SetShown(shown)

    local learning = shown and entry.learnNext == true
    for _, part in ipairs({ detail.title, detail.subtitle, detail.note }) do
        part:SetShown(shown)
    end
    for _, part in ipairs({ detail.reagentHeading, detail.summary, detail.quantityBox,
                            detail.addButton, detail.maxButton, detail.craftButton }) do
        part:SetShown(shown and not learning)
    end
    detail.learnPane:SetShown(learning)

    if learning then
        detail.shownRecipeID = nil
        detail.craftStatus:SetText("")
        UpdateCraftButton()
        UpdateLearnDetail(detail, entry)
        return
    end

    if not shown then
        detail.shownRecipeID = nil
        -- Emptied rather than hidden: the progress bar hides and shows this
        -- line itself while a craft casts.
        detail.craftStatus:SetText("")
        UpdateCraftButton()
        return
    end

    detail.title:SetText(entry.name or L.Format("recipe %s", entry.recipeID))
    if entry.outputItemID then
        Theme.SetItemIcon(detail.icon, entry.outputItemID)
    else
        Theme.SetSpellIcon(detail.icon, entry.recipeID, ns.Upgrades and ns.Upgrades:EnchantFor(entry.recipeID) ~= nil)
    end

    local r, g, b = TierColor(entry.tier)
    if entry.tier == "unknown" then
        detail.subtitle:SetText(L["Skill up chance not read yet. Open the profession window to read it."])
    else
        local text = ns.SkillUp:GetTierLabel(entry.tier)
        detail.subtitle:SetText(text:sub(1, 1):upper() .. text:sub(2))
    end
    detail.subtitle:SetTextColor(r, g, b)

    local stale = StaleNote(entry.skillUp)
    local short = ns.LevelUp:ShortNote(entry)
    local forYou = not (stale or short) and ns.Upgrades and ns.Upgrades:EnchantText(entry.recipeID)
    detail.note:SetText(stale and short and (stale .. "\n" .. short) or stale or short or forYou or "")
    detail.note:SetTextColor(Theme.Unpack(forYou and "profit" or (short and not stale) and "loss" or "warn"))

    local anchor = detail.reagentHeading
    local reagents = (entry.costDetail and entry.costDetail.reagents) or {}

    for index, reagent in ipairs(reagents) do
        local line = detail.reagentLines[index]

        if not line then
            local frame = CreateFrame("Frame", nil, detail)
            frame:SetHeight(16)

            local icon = Theme.CreateItemIcon(frame, 14)
            icon:SetPoint("LEFT", 0, 0)
            if Widgets.ItemHotspot then Widgets.ItemHotspot(icon, frame) end

            local name = Theme.CreateLabel(frame, "small", "text")
            name:SetPoint("LEFT", 18, 0)
            name:SetPoint("RIGHT", -74, 0)

            local value = Theme.CreateLabel(frame, "small", "muted", "RIGHT")
            value:SetPoint("RIGHT", 0, 0)

            line = { frame = frame, icon = icon, name = name, value = value }
            detail.reagentLines[index] = line
        end

        line.frame:ClearAllPoints()
        line.frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, index == 1 and -6 or 0)
        line.frame:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -12, 0)

        -- How many sits on the icon's corner (UI/ItemLook.lua), set below.
        local label = Util.GetItemLabel(reagent.itemID)
        local maker = ns.Cost and ns.Cost.MadeByName and ns.Cost.MadeByName(reagent.madeBy)
        if maker then
            -- Made by an alt and mailed here.
            label = L.Format("%s (made by %s)", label, maker)
        elseif reagent.crafted then
            label = L.Format("%s (make it)", label)
        elseif ns.Cost.NeverMadeRecipeFor and ns.Cost:NeverMadeRecipeFor(reagent.itemID) then
            -- Marked never to make as a sub-craft, so it is bought.
            label = L.Format("%s (bought, never made)", label)
        end
        line.name:SetText(label)
        Theme.SetItemIcon(line.icon, reagent.itemID)
        if ns.ItemLook then ns.ItemLook.SetCount(line.icon, reagent.quantity) end

        -- Have or need first: it answers "can I make this" without a second
        -- screen. Bank stock counts here, the same as on the Profit tab.
        if (reagent.shortfall or 0) > 0 then
            line.value:SetText(L.Format("need %d", reagent.shortfall))
            line.value:SetTextColor(Theme.Unpack("loss"))
        elseif reagent.lineCost then
            line.value:SetText(Util.FormatMoney(reagent.lineCost, { short = true }))
            line.value:SetTextColor(Theme.Unpack("muted"))
        else
            line.value:SetText(L["no price"])
            line.value:SetTextColor(Theme.Unpack("dim"))
        end

        line.frame:Show()
        anchor = line.frame
    end

    if entry.cost then
        detail.costValue:SetText(Util.FormatMoney(entry.cost))
    else
        detail.costValue:SetText(L["a material has no price"])
    end

    -- Each way back, the one the list counts in green.
    local returns = entry.returns or {}
    for way, label in pairs(detail.wayValues) do
        if returns[way] then
            label:SetText(Util.FormatMoney(returns[way]))
            if way == entry.backWay then
                label:SetTextColor(Theme.Unpack("profit"))
            else
                label:SetTextColor(Theme.Unpack("text"))
            end
        else
            label:SetText("--")
            label:SetTextColor(Theme.Unpack("dim"))
        end
    end

    if entry.realCost and entry.realCost < 0 then
        detail.realLabel:SetText(L["Pays you back"])
        detail.realValue:SetText(Util.FormatMoney(-entry.realCost))
        detail.realValue:SetTextColor(Theme.Unpack("profit"))
    else
        detail.realLabel:SetText(L["Real cost"])
        local real = entry.realCost or entry.cost
        detail.realValue:SetText(real and Util.FormatMoney(real) or "--")
        detail.realValue:SetTextColor(Theme.Unpack(real and "text" or "dim"))
    end

    local craftable = entry.craftableNow or 0
    detail.makeValue:SetText(tostring(craftable))
    detail.makeValue:SetTextColor(Theme.Unpack(craftable > 0 and "profit" or "loss"))

    -- Only when a different recipe is picked. The list refreshes on every
    -- bag change, and a number the player typed must survive that.
    if detail.shownRecipeID ~= entry.recipeID then
        detail.shownRecipeID = entry.recipeID
        detail.quantity:SetText(tostring(math.max(1, craftable)))
    end

    UpdateCraftButton()
end

--------------------------------------------------------------------------------
-- List
--------------------------------------------------------------------------------

--- The picked profession's skill, as Road to 300 shows it. Read by name
--- from Recipes:GetLearnedProfessions, which keeps the last good read, so it
--- shows with the profession window shut too; Forever lists a profession
--- under two IDs and the one with the levels may not be the recipes' own.
--- The search box gives up room when the tick boxes would run into the
--- skill line on the right (a longer language, "Can afford" added).
FitToolbar = function()
    local search, last, label = widgets.search, widgets.canAfford, widgets.skillLabel
    if not (search and last and label and widgets.toolbar) then return end
    search:SetWidth(Widgets.SEARCH_WIDTH)
    local ok, lastRight = pcall(last.GetRight, last)
    local okRight, edge = pcall(widgets.toolbar.GetRight, widgets.toolbar)
    local okWidth, width = pcall(label.GetStringWidth, label)
    if not (ok and okRight and okWidth and type(lastRight) == "number"
            and type(edge) == "number" and type(width) == "number") then return end
    local over = lastRight + 12 - (edge - width)
    if over > 0 then search:SetWidth(math.max(90, Widgets.SEARCH_WIDTH - over)) end
end

local function UpdateSkillLabel()
    local label = widgets.skillLabel
    local skillLines = state.profession and skillLinesByName[state.profession]

    if not skillLines then
        label:SetText("")
        return
    end

    local best
    for skillLineID in pairs(skillLines) do
        local info = ProfessionInfo(skillLineID)
        if info and (info.maxSkillLevel or 0) > ((best and best.max) or 0) then
            best = { skill = info.skillLevel or 0, max = info.maxSkillLevel }
        end
    end

    if not best and ns.Recipes and ns.Recipes.GetLearnedProfessions then
        local ok, learned = pcall(ns.Recipes.GetLearnedProfessions, ns.Recipes)
        for _, profession in ipairs(ok and type(learned) == "table" and learned or {}) do
            if (profession.maxSkillLevel or 0) > 0
                and (profession.name == state.profession or skillLines[profession.skillLineID]) then
                best = { skill = profession.skillLevel or 0, max = profession.maxSkillLevel }
                break
            end
        end
    end

    if best then
        label:SetText(("%s  %d / %d"):format(tostring(state.profession):upper(), best.skill, best.max))
    else
        label:SetText("")
    end
    FitToolbar()
end

--- The character's skill in each profession shown, by Classic skill line,
--- for Learn next: the one picked, or every one they have.
local function LearnSkills()
    local skills = {}
    local sets = {}
    if state.profession then
        sets[1] = skillLinesByName[state.profession]
    else
        for _, set in pairs(skillLinesByName) do sets[#sets + 1] = set end
    end
    local classic = ns.RecipeBook and ns.RecipeBook.ClassicLine or function(id) return id end
    for _, set in ipairs(sets) do
        for skillLineID in pairs(set or {}) do
            local info = ProfessionInfo(skillLineID)
            if info and (info.maxSkillLevel or 0) > 0 then
                skills[classic(skillLineID)] = info.skillLevel or 0
            end
        end
    end
    return skills
end

--- Learn next's rows (2026-10-12), under the recipes known.
local function LearnRows()
    if not (LearnShown() and ns.LearnNext) then return {} end
    local ok, rows = pcall(ns.LearnNext.GetRows, ns.LearnNext, {
        skills = LearnSkills(), search = state.search,
    })
    if not ok then
        ns.Debug("Learn next:", tostring(rows))
        return {}
    end
    if state.craftableOnly then
        local kept = {}
        for _, row in ipairs(rows) do
            if (row.craftableNow or 0) > 0 and not row.locked then kept[#kept + 1] = row end
        end
        rows = kept
    end
    return rows
end

local function Refresh()
    if not widgets.list then return end

    local known = ns.LevelUp:GetRanked({
        skillLines = state.profession and skillLinesByName[state.profession] or nil,
        includeTrivial = state.includeTrivial,
        craftableOnly = state.craftableOnly,
        canAfford = state.canAfford,
        subCraftsOnly = state.subCraftsOnly,
        search = state.search,
    })
    local learnRows = LearnRows()

    local shown = {}
    for _, row in ipairs(known) do shown[#shown + 1] = row end
    if #learnRows > 0 then
        shown[#shown + 1] = { heading = true }
        for _, row in ipairs(learnRows) do shown[#shown + 1] = row end
    end

    widgets.list:SetData(shown)
    UpdateSkillLabel()

    -- The colours count the recipes known; Learn next has its own count.
    local rows = known

    -- How many of each colour, so the footer says at a glance how much
    -- levelling is left in what you know.
    local counts, unread = {}, 0
    for _, row in ipairs(rows) do
        counts[row.tier] = (counts[row.tier] or 0) + 1
        if row.tier == "unknown" then unread = unread + 1 end
    end

    -- Its own words: the CHANCE column's "Small" and "None" read as "25
    -- small  200 none" down here.
    local FOOTER_WORDS = {
        optimal = L["guaranteed"], medium = L["likely"], easy = L["small chance"],
        unknown = L["not read"], trivial = L["no skill-up"],
    }

    local parts = {}
    for _, tier in ipairs({ "optimal", "medium", "easy", "unknown", "trivial" }) do
        if counts[tier] then
            parts[#parts + 1] = ("%s%d %s|r"):format(ColorCode(TierColor(tier)), counts[tier],
                FOOTER_WORDS[tier] or ns.LevelUp.CHANCE_LABEL[tier]:lower())
        end
    end
    if #learnRows > 0 then
        parts[#parts + 1] = ("%s%s|r"):format(ColorCode(Theme.Unpack("accent")),
            #learnRows == 1 and L["1 to learn"] or L.Format("%d to learn", #learnRows))
    end
    widgets.countLabel:SetText(table.concat(parts, "   "))

    widgets.emptyLabel:SetShown(#shown == 0)
    if Widgets.EmptyAction then Widgets.EmptyAction(widgets.emptyLabel, nil) end

    if #shown == 0 then
        if ns.Recipes:Count() == 0 then
            widgets.emptyLabel:SetText(L["Open a profession window once so your recipes can be read."])
        elseif state.search ~= "" then
            widgets.emptyLabel:SetText(L.Format("Nothing matching \"%s\".", state.search))
            if Widgets.EmptyAction then Widgets.EmptyAction(widgets.emptyLabel, L["Clear Search"], function() widgets.search:SetText("") end) end
        elseif state.subCraftsOnly then
            widgets.emptyLabel:SetText(L["Nothing you know here makes a material for another craft."])
        elseif state.craftableOnly then
            widgets.emptyLabel:SetText(L["Nothing that gives skill can be made from your bags right now."])
        elseif state.canAfford then
            widgets.emptyLabel:SetText(L["Nothing that gives skill fits the gold you have."])
        else
            widgets.emptyLabel:SetText(L["Nothing you know gives skill any more. Tick \"Show grey\" to see the rest, or learn new recipes."])
        end
    end

    -- Colours are only readable while the profession window is open. A
    -- list that is all "not read" is one that has never been opened since
    -- this addon was installed, and says so.
    if #rows > 0 and unread == #rows then
        widgets.countLabel:SetText(L["Open this profession once so the skill up colours can be read."])
    end

    -- Keep the detail panel in step with the fresh numbers.
    if state.selected and state.selected.learnNext then
        local fresh
        for _, row in ipairs(learnRows) do
            if row.recipeID == state.selected.recipeID then fresh = row break end
        end
        state.selected = fresh
        UpdateDetail(fresh)
    elseif state.selected then
        local fresh = ns.LevelUp:BuildRow(state.selected.recipeID)
        state.selected = fresh
        UpdateDetail(fresh)
    else
        UpdateDetail(nil)
    end
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function Build(container)
    -- Before any row or heading is laid out: they read these widths. The
    -- Show the way column is as wide as its button's words.
    local wayWidth = Theme.MeasureText and Theme.MeasureText("small", L["Show the Way"])
    if type(wayWidth) == "number" then COLUMNS[1].width = math.max(COLUMNS[1].width, math.ceil(wayWidth + 16)) end
    if Widgets.FitColumns then Widgets.FitColumns(COLUMNS) end

    local toolbar = CreateFrame("Frame", nil, container)
    toolbar:SetPoint("TOPLEFT", 8, -8)
    toolbar:SetPoint("TOPRIGHT", -8, -8)
    toolbar:SetHeight(24)

    local profession = Widgets.CreateDropdown(toolbar, { { text = L["All professions"], value = nil } },
        function(value)
            state.profession = value
            state.selected = nil
            widgets.list:ScrollToTop()
            Refresh()
        end, { width = 150 })
    profession:SetPoint("LEFT", 0, 0)
    widgets.professionDropdown = profession

    local search = Widgets.CreateSearchBox(toolbar, L["Search recipes"], function(text)
        state.search = text or ""
        Refresh()
    end)
    search:SetPoint("LEFT", profession, "RIGHT", 8, 0)
    search:SetWidth(Widgets.SEARCH_WIDTH)
    widgets.search = search
    widgets.toolbar = toolbar

    local craftable = Widgets.CreateCheckbox(toolbar, L["Craftable now"], function(checked)
        state.craftableOnly = checked
        Refresh()
    end, false)
    craftable:SetPoint("LEFT", search, "RIGHT", 12, 0)

    local trivial = Widgets.CreateCheckbox(toolbar, L["Show grey"], function(checked)
        state.includeTrivial = checked
        Refresh()
    end, false)
    trivial:SetPoint("LEFT", craftable, "RIGHT", 12, 0)

    -- Asked 2026-10-07: the crafts that make another's materials, grey
    -- ones too, to choose which to make and which to buy.
    local subCrafts = Widgets.CreateCheckbox(toolbar, L["Sub-crafts only"], function(checked)
        state.subCraftsOnly = checked
        state.selected = nil
        -- Other characters' professions join the menu, or leave it.
        OnShow()
        -- Learn next stands aside while only sub-crafts show.
        PlaceHeadings()
        widgets.list:ScrollToTop()
        Refresh()
    end, false)
    subCrafts:SetPoint("LEFT", trivial, "RIGHT", 12, 0)
    subCrafts:HookScript("OnEnter", function(box)
        GameTooltip:SetOwner(box, "ANCHOR_BOTTOM")
        GameTooltip:SetText(L["Only crafts that make a material for another craft, on all your characters. Use the SUB-CRAFT button to pick Make or Buy."], 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    subCrafts:HookScript("OnLeave", function() GameTooltip:Hide() end)

    -- Learn next (the owner said build it, 2026-10-12): recipes not learned
    -- yet that raise the skill now, under the ones known. Kept between
    -- sessions.
    state.learnNext = ns.Config:Get("levelUpLearnNext") ~= false
    local learnNext = Widgets.CreateCheckbox(toolbar, L["Learn next"], function(checked)
        state.learnNext = checked
        ns.Config:Set("levelUpLearnNext", checked)
        if state.selected and state.selected.learnNext then state.selected = nil end
        PlaceHeadings()
        Refresh()
    end, state.learnNext)
    learnNext:SetPoint("LEFT", subCrafts, "RIGHT", 12, 0)
    learnNext:HookScript("OnEnter", function(box)
        GameTooltip:SetOwner(box, "ANCHOR_BOTTOM")
        GameTooltip:SetText(L["Shows recipes you haven't learned that would raise your skill now, and who teaches each."], 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    learnNext:HookScript("OnLeave", function() GameTooltip:Hide() end)

    -- Can afford (a player asked, the owner said build it, 2026-10-22):
    -- leaves out crafts whose missing materials cost more than the gold
    -- carried. Kept between sessions; Butler's Cheapest Skill-Up follows it.
    state.canAfford = ns.Config:Get("levelUpCanAfford") == true
    local canAfford = Widgets.CreateCheckbox(toolbar, L["Can afford"], function(checked)
        state.canAfford = checked
        ns.Config:Set("levelUpCanAfford", checked)
        widgets.list:ScrollToTop()
        Refresh()
    end, state.canAfford)
    canAfford:SetPoint("LEFT", learnNext, "RIGHT", 12, 0)
    canAfford:HookScript("OnEnter", function(box)
        GameTooltip:SetOwner(box, "ANCHOR_BOTTOM")
        GameTooltip:SetText(L["Only shows crafts you can buy the missing materials for with the gold you have on you."], 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    canAfford:HookScript("OnLeave", function() GameTooltip:Hide() end)
    widgets.canAfford = canAfford

    local skillLabel = Theme.CreateLabel(toolbar, "normal", "accent", "RIGHT")
    skillLabel:SetPoint("RIGHT", 0, 0)
    widgets.skillLabel = skillLabel

    -- Column headings
    local headings = CreateFrame("Frame", nil, container)
    headings:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -8)
    headings:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", -DETAIL_WIDTH - 8, -8)
    headings:SetHeight(16)

    local nameHeading = Theme.CreateLabel(headings, "tiny", "muted")
    nameHeading:SetPoint("LEFT", 28, 0)
    nameHeading:SetText(L["RECIPE"])

    local cells = {}
    for _, column in ipairs(COLUMNS) do
        local heading = Theme.CreateLabel(headings, "tiny", "muted", column.justify or "RIGHT")
        heading:SetText(column.label)
        cells[column.key] = heading
    end
    widgets.headingCells = cells
    widgets.headings = headings
    PlaceHeadings()

    -- Laid out again when the list's width is known or changes (the
    -- scrollbar taking its room), so the columns that fit are worked out
    -- for the room there really is.
    local placedWidth
    headings:SetScript("OnSizeChanged", function(_, width)
        -- Only a new width moves anything; the game can say so more than
        -- once for the same one while it settles.
        if width ~= nil and width == placedWidth then return end
        placedWidth = width
        PlaceHeadings()
        if widgets.list then widgets.list:Refresh() end
    end)

    -- Right-click the headings to choose the columns.
    ns.Columns:Attach(headings, "levelup")
    ns.Columns:OnChange("levelup", function()
        PlaceHeadings()
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

        onEnter = function(row, entry) ShowRowTooltip(row, entry) end,
        onLeave = function() GameTooltip:Hide() end,
        clickHint = function(entry) return not entry.heading and L["Right-click for more."] or nil end,
        menu = RowMenu,

        -- The row the detail pane is showing stays lit.
        isSelected = function(entry)
            return state.selected ~= nil and entry.recipeID == state.selected.recipeID
                and (entry.learnNext == true) == (state.selected.learnNext == true)
        end,

        onClick = function(entry, _, mouseButton)
            if entry.heading or mouseButton == "RightButton" then return end

            state.selected = entry
            UpdateDetail(entry)
        end,
    })

    list:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -4)
    list:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -DETAIL_WIDTH - 16, 24)
    widgets.list = list

    -- Gold coming in or going out moves "Can afford" and the red notes:
    -- redrawn a moment later, only while the list shows.
    local goldQueued = false
    ns.RegisterEvent(state, "PLAYER_MONEY", function()
        if goldQueued or not list:IsVisible() then return end
        goldQueued = true
        C_Timer.After(0.3, function()
            goldQueued = false
            if list:IsVisible() then Refresh() end
        end)
    end)

    local emptyLabel = Theme.CreateLabel(container, "small", "dim", "CENTER")
    emptyLabel:SetPoint("CENTER", list, "CENTER", 0, 10)
    emptyLabel:SetWidth(340)
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

--- Rebuild the profession list, and follow the profession last opened.
OnShow = function()
    wipe(skillLinesByName)
    wipe(nameBySkillLine)

    local options = {}

    -- With Sub-crafts only, every character's professions, so an alt's
    -- alchemy or engineering can be picked too.
    local alts = state.subCraftsOnly
    local recipes = ns.LevelUp.ListedRecipes and ns.LevelUp:ListedRecipes(alts) or ns.Recipes:GetAll()

    for _, recipe in pairs(recipes) do
        local skillLineID = recipe.skillLineID

        -- A dropped profession has no crafts left to list. ListedRecipes
        -- has already left those out of every character's.
        if not alts and ns.Recipes.IsDropped and ns.Recipes:IsDropped(recipe) then skillLineID = nil end

        if skillLineID and not nameBySkillLine[skillLineID] then
            local info = ProfessionInfo(skillLineID)
            local name = (info and info.professionName ~= "" and info.professionName)
                or ProfessionName(skillLineID) or L.Format("Skill line %s", skillLineID)

            nameBySkillLine[skillLineID] = name

            if not skillLinesByName[name] then
                skillLinesByName[name] = {}
                options[#options + 1] = { text = name, value = name }
            end

            skillLinesByName[name][skillLineID] = true
        end
    end

    -- "All professions" first, as in every profession menu (it sat last
    -- here, first on the Profit tab).
    table.sort(options, function(a, b) return a.text < b.text end)
    table.insert(options, 1, { text = L["All professions"], value = nil })

    local dropdown = widgets.professionDropdown
    dropdown:SetOptions(options)

    -- Open on the profession you last had open. Only when that changes,
    -- though: a choice made in the dropdown sticks until you open a different
    -- profession window.
    local last = ns.LevelUp:GetLastSkillLine()
    local lastName = last and nameBySkillLine[last]

    if lastName and last ~= state.followed then
        state.followed = last
        state.profession = lastName
        state.selected = nil
    elseif state.profession and not skillLinesByName[state.profession] then
        state.profession = nil
    elseif not state.started and options[2] then
        -- No profession opened since this was added: start on the first one
        -- rather than a mix of all of them.
        state.profession = options[2].value
    end

    state.started = true

    dropdown:SetValue(state.profession)
end

-- Recipes to learn here too (2026-10-05: "recipes to learn should be under
-- level up as well"), its own copy listed by the skill each recipe needs, so
-- the next recipe to get on the way up is near the top. Without
-- UI/RecipeBookView.lua (the tests load this file alone) the tab is the list.
--
-- Road to 300 (the owner said build it, 2026-10-20, from a mockup): the
-- views are Next Point (the tab's own list), Road to 300 (UI/RoadView.lua)
-- and Learn Next (the recipes to learn).
local switch = ns.RecipeBookView and ns.RecipeBookView.WithSwitch({
    mainKey = "recipes",
    mainText = L["Next Point"],
    mainTip = L["The recipes you know, cheapest way up first"],
    buildMain = Build,
    refreshMain = Refresh,
    extras = ns.RoadView and {
        {
            key = "road",
            text = L["Road to 300"],
            build = function(view) ns.RoadView:Build(view) end,
            refresh = function() ns.RoadView:Refresh() end,
        },
    } or nil,
    learnText = L["Recipes to Learn"],
    learn = ns.RecipeBookView.New({ order = "skill", showSkill = true }),
    corner = function(parent)
        return ns.Upgrades and ns.Upgrades.CreateAltCheckbox and ns.Upgrades:CreateAltCheckbox(parent)
    end,
})

UI:RegisterTab({
    key = "levelup",
    text = L["Level Up"],
    order = 6,
    build = switch and switch.Build or Build,
    refresh = switch and switch.Refresh or Refresh,
    onShow = OnShow,
})

--- Open the Level Up tab on Road to 300 for a profession (its Classic
--- skill line), for the Welcome card's Show My Road.
ns.LevelUpTab = {
    ShowRoad = function(line)
        if not switch then return end
        if ns.RoadView then ns.RoadView:Pick(line) end
        UI:Show()
        if UI.SelectTab then UI:SelectTab("levelup") end
        switch.ShowView("road")
    end,
}
