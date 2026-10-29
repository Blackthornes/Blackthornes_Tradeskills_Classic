-- Blackthornes Tradeskills -- UI/Tab_Queue.lua
-- Queued crafts on the left, the materials they need on the right.
--
-- These are one screen rather than two tabs on purpose: "what am I making" and
-- "what am I missing" are the same question, and splitting them means bouncing
-- between tabs to answer it.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local UI = ns.UI

local ROW_HEIGHT = 24
-- Wider since 2026-10-05, with the window: the headings sat tight against
-- each other and long material names were cut short. The craft list keeps
-- the width it had, because the window grew by the same amount.
local MATERIALS_WIDTH = 420

-- Columns for the materials panel, laid out from the right edge inward. The
-- AH button occupies the rightmost slot. COST sits to the right, so its
-- coins line up; NEED and HAVE are centred under their headings. `width` is
-- the least each gets: Widgets.FitColumns widens it to fit the heading and
-- all three coins ("12g 34s 56c"), and PlaceMaterialRow lays the shown
-- ones out from there, with a gap between every column.
local MATERIAL_COLUMNS = {
    { key = "cost", label = L["COST"], width = 70, money = true },
    { key = "have", label = L["HAVE"], width = 42, justify = "CENTER" },
    { key = "need", label = L["NEED"], width = 42, justify = "CENTER" },
}

-- Any of them can be hidden, never the material's name (UI/Columns.lua).
ns.Columns:Register("queue", L["Queue: materials"], MATERIAL_COLUMNS)

if Widgets.FitColumns then Widgets.FitColumns(MATERIAL_COLUMNS) end

-- The queued amount is a box you can type in (asked 2026-10-05: taking 100
-- off meant 100 clicks on -). Wide enough for four digits; the label it
-- replaced was 22 wide and lost the last digit of 100.
local QUANTITY_WIDTH = 42

-- The row's AH / DE / Vendor button (2026-10-07). Wide enough for
-- "Vendor" at the client's font, with the button's own insets.
local ACTION_WIDTH = 54

-- Disenchant next, left of Clear all, when Settings turns it on.
local DE_NEXT_WIDTH = 230

local function InCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown() and true or false
end

local widgets = {}

-- Each queued craft's cost and profit for its whole count, worked out once
-- per redraw (Queue:GetEntryCosts) so a row and the footer agree.
local entryCosts = {}

--------------------------------------------------------------------------------
-- Craft rows
--------------------------------------------------------------------------------

local function CreateCraftRow(row)
    -- The item's icon beside its name, as the bags draw it.
    row.icon = Theme.CreateItemIcon(row, 16)
    row.icon:SetPoint("LEFT", 8, 0)

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("LEFT", 28, 0)
    -- Ends short of the action button, so a long name never draws under it.
    row.name:SetPoint("RIGHT", row, "RIGHT", -(198 + ACTION_WIDTH + 6), 0)

    -- What the craft is for once made: AH, DE or Vendor. A click steps to
    -- the next, a right-click goes back to whichever pays most.
    row.action = Widgets.CreateButton(row, L["AH"], function(_, mouseButton)
        if not row.data or not ns.QueueActions then return end
        if mouseButton == "RightButton" then
            ns.QueueActions:Set(row.data, nil)
        else
            ns.QueueActions:Cycle(row.data)
        end
    end, { width = ACTION_WIDTH, height = 16 })
    row.action:SetPoint("RIGHT", -198, 0)
    if row.action.RegisterForClicks then row.action:RegisterForClicks("LeftButtonUp", "RightButtonUp") end

    row.profit = Theme.CreateLabel(row, "small", "text", "RIGHT")
    row.profit:SetPoint("RIGHT", -114, 0)
    row.profit:SetWidth(80)

    -- Quantity stepper: - and + either side of a box you can type the
    -- amount into. 0 takes the craft off the queue, as - does at 1.
    row.minus = Widgets.CreateButton(row, "-", function()
        if not row.data then return end
        ns.Queue:SetQuantity(row.data.recipeID, row.data.quantity - 1)
    end, { width = 18, height = 16 })
    row.minus:SetPoint("RIGHT", -90, 0)

    row.quantity = Widgets.CreateNumberBox(row, {
        width = QUANTITY_WIDTH,
        height = 18,
        background = "panel",
        justify = "CENTER",
        min = 0,
        max = 9999,
        onChange = function(value)
            if row.data then ns.Queue:SetQuantity(row.data.recipeID, value) end
        end,
    })
    row.quantity:SetPoint("RIGHT", -45, 0)

    -- Sub-crafts show their amount without the box: it comes from the
    -- crafts they serve, so a typed one would be worked out away again.
    row.count = Theme.CreateLabel(row, "small", "accent", "CENTER")
    row.count:SetPoint("RIGHT", -45, 0)
    row.count:SetWidth(QUANTITY_WIDTH)

    row.plus = Widgets.CreateButton(row, "+", function()
        if not row.data then return end
        ns.Queue:SetQuantity(row.data.recipeID, row.data.quantity + 1)
    end, { width = 18, height = 16 })
    row.plus:SetPoint("RIGHT", -24, 0)

    -- On a sub-craft the x means never make it as one (2026-10-07):
    -- taking it off alone would bring it straight back on the next rebuild.
    row.remove = Widgets.CreateButton(row, "x", function()
        if not row.data then return end
        if row.data.isDependency then
            -- Asks first: it sets the craft to Buy for good (UI/NeverMakeBox.lua).
            if ns.NeverMakeBox then ns.NeverMakeBox.Click(row.data, row.remove)
            else ns.Queue:NeverMake(row.data) end
        else
            ns.Queue:Remove(row.data.recipeID)
        end
    end, { width = 16, height = 16, tooltip = L["Remove from queue"] })
    row.remove:SetPoint("RIGHT", -4, 0)

    -- On a sub-craft kept after buying its item turned cheaper, in the
    -- profit column, which such a row has no use for.
    row.buyInstead = Widgets.CreateButton(row, L["Buy instead"], function()
        if row.data then ns.Queue:BuyInstead(row.data) end
    end, { width = 80, height = 18 })
    row.buyInstead:SetPoint("RIGHT", -114, 0)
    row.buyInstead:Hide()
end

--- The row's action button: its word, and a hover with what each way pays.
local function UpdateActionButton(row, entry)
    local actions = ns.QueueActions
    local action, chosen, choices, analysis
    if actions then action, chosen, choices, analysis = actions:Get(entry) end

    if not action then
        row.action:Hide()
        return
    end

    row.action:Show()
    row.action:SetText(actions.SHORT[action])

    local ways = analysis and analysis.ways or {}
    local lines = { chosen and L.Format("%s, picked by you.", actions.LONG[action])
        or L.Format("%s, because it pays most.", actions.LONG[action]) }

    for _, way in ipairs(choices) do
        local option = ways[way]
        local pays = option and Util.FormatMoney(option.profit * entry.quantity, { noColor = true, short = true })
            or L["no price yet"]
        lines[#lines + 1] = ("%s %s: %s"):format(way == action and ">" or "  ", actions.LONG[way], pays)
    end

    if action == "disenchant" then
        lines[#lines + 1] = L["Made items are marked for Disenchant next on this tab."]
    elseif action == "vendor" then
        lines[#lines + 1] = L["Made items are marked for Sell marked at a vendor."]
    end
    lines[#lines + 1] = #choices > 1 and L["Click to change. Right-click for whichever pays most."]
        or L["There's no other way to sell this item."]
    row.action.tooltipText = table.concat(lines, "\n")
end

--- The hover for Buy instead: both prices, when known, and what it does.
local function BuyInsteadTooltip(entry)
    local recipe = ns.Recipes:GetAny(entry.recipeID)
    local name = (recipe and recipe.name) or L["this"]
    local buy, make = ns.Queue:GetBuyOrMake(entry)

    local text = L.Format("Buying %s is now cheaper than making it.", name)
    if buy and make then
        text = text .. "\n" .. L.Format("Buy: %s each. Make: %s each.",
            Util.FormatMoney(buy), Util.FormatMoney(make))
    end
    return text .. "\n" .. L["Buy instead takes it off the queue and puts it on the shopping list."]
end

-- A queued craft's name is the colour of what it makes (asked 2026-10-07),
-- as on the Profit tab and in the craft pane. The client may not have the
-- item yet when the list is drawn: such a row is drawn in the plain text
-- colour, and GET_ITEM_INFO_RECEIVED redraws the list once it arrives.
local awaitingItemData = false

local function ApplyNameColor(row, itemID)
    local r, g, b = Util.GetItemQualityColor(itemID)
    if r then
        row.name:SetTextColor(r, g, b)
        return
    end

    row.name:SetTextColor(Theme.Unpack("text"))
    if itemID then awaitingItemData = true end
end

-- A material's name: its rarity colour, or the colour that says something
-- (muted once you have them all, green when an alt makes it for less).
local function ApplyMaterialColor(row, itemID, nameColour)
    if nameColour then
        row.name:SetTextColor(Theme.Unpack(nameColour))
    else
        ApplyNameColor(row, itemID)
    end
end

local function UpdateCraftRow(row, entry)
    local recipe = ns.Recipes:GetAny(entry.recipeID)
    local analysis = ns.Profit:Analyse(entry.recipeID)

    local plain = (recipe and recipe.name) or L.Format("recipe %s", tostring(entry.recipeID))
    local label = plain
    -- Gear another of your characters would wear (Logic/Upgrades.lua).
    if recipe and ns.Upgrades and ns.Upgrades.WithAltText then
        label = ns.Upgrades:WithAltText(plain, recipe.outputItemID)
    end
    Theme.SetItemIcon(row.icon, recipe and recipe.outputItemID)

    -- Marked so a craft the player did not add directly is explicable.
    if entry.isDependency then
        local parents = ns.Queue:GetDependencyParents(entry)

        label = L.Format("|cff7a8089>|r %s |cff7a8089(for %s)|r",
            plain,
            #parents > 0 and table.concat(parents, ", ") or L["another craft"])
    end

    -- Who it is for and who makes it, when that is not all this character:
    -- "you make this for Ana" on the tailor, "Bob makes this for you" on
    -- Ana. The longest wording that fits the row, then shorter ones.
    local who = ns.Queue.DescribeWho and ns.Queue:DescribeWho(entry) or {}
    local texts = {}
    local function Note(base, text)
        return ("%s |cff7a8089·|r |cffc8a44d%s|r"):format(base, text)
    end

    -- Kept after buying turned cheaper: said on the row ahead of who makes
    -- it, so it is not mistaken for the cheaper way.
    if entry.buyCheaper then
        local cheaper = L.Format("|c%sbuying is cheaper now|r", ns.COLORS.warn)
        texts[#texts + 1] = ("%s |cff7a8089·|r %s"):format(label, cheaper)
        texts[#texts + 1] = ("%s |cff7a8089·|r %s"):format(plain, cheaper)
    end

    -- A craft queued when it was worth 4g and now worth 40s should say so,
    -- rather than silently re-pricing. This was an amber name until the
    -- name took the item's rarity colour, so it is said in words now.
    if not entry.isDependency and analysis and analysis.priceable
        and entry.snapshotProfit and entry.snapshotProfit > 0
        and analysis.profit / entry.snapshotProfit < 0.6 then
        local dropped = L.Format("|c%sworth less than when queued|r", ns.COLORS.warn)
        texts[#texts + 1] = ("%s |cff7a8089·|r %s"):format(label, dropped)
        texts[#texts + 1] = ("%s |cff7a8089·|r %s"):format(plain, dropped)
    end
    for _, text in ipairs(who) do texts[#texts + 1] = Note(label, text) end
    if #who > 0 then texts[#texts + 1] = Note(plain, who[#who]) end
    texts[#texts + 1] = label
    texts[#texts + 1] = plain
    Theme.FitText(row.name, texts)
    ApplyNameColor(row, recipe and recipe.outputItemID)

    -- Colour by whether it can be made, since nothing here can start one.
    local ready, reason = ns.Crafting:GetReadiness(entry.recipeID)
    local countColor = ready and "profit" or "muted"
    row.count:SetTextColor(Theme.Unpack(countColor))
    row.quantity.editBox:SetTextColor(Theme.Unpack(countColor))

    -- Derived rows have no controls: their quantity comes from the parents,
    -- so anything set here would be recalculated away on the next change.
    row.minus:SetShown(not entry.isDependency)
    row.plus:SetShown(not entry.isDependency)
    row.remove:Show()
    row.remove.tooltipText = entry.isDependency and ns.Queue.NeverMakeTooltip
        and ns.Queue:NeverMakeTooltip(entry) or nil
    row.quantity:SetShown(not entry.isDependency)
    row.count:SetShown(entry.isDependency == true)
    row.count:SetText(tostring(entry.quantity))

    -- A redraw leaves a number being typed alone, unless the row now shows
    -- a different craft: then what was typed belonged to the old one.
    local typing = row.quantity.editBox.HasFocus and row.quantity.editBox:HasFocus()
    if typing and row.boundRecipeID ~= entry.recipeID then
        row.quantity:SetValue(entry.quantity, true)
        row.quantity.editBox:ClearFocus()
    elseif not typing then
        row.quantity:SetValue(entry.quantity, true)
    end
    row.boundRecipeID = entry.recipeID

    UpdateActionButton(row, entry)

    local kept = entry.isDependency and entry.buyCheaper == true
    row.buyInstead:SetShown(kept)
    row.profit:SetShown(not kept)
    if kept then row.buyInstead.tooltipText = BuyInsteadTooltip(entry) end

    if entry.isDependency then
        -- Made to go into another craft, not sold, so it earns nothing of
        -- its own. The footer already counts it that way; a sale profit here
        -- made the column add up to more than the total under it.
        row.profit:SetText(L["used"])
        row.profit:SetTextColor(Theme.Unpack("dim"))
    elseif analysis and analysis.priceable then
        local priced = entryCosts[entry]
        local total = priced and priced.profit or (analysis.profit * entry.quantity)
        row.profit:SetText(Util.FormatMoney(total, { short = true }))
        row.profit:SetTextColor(Theme.ProfitColor(total))
    else
        row.profit:SetText("--")
        row.profit:SetTextColor(Theme.Unpack("dim"))
    end
end

--------------------------------------------------------------------------------
-- Material rows
--------------------------------------------------------------------------------

--- The shown columns from the AH button inward; the name has the rest.
-- The x on a line put there to buy (Queue:EnsureBuy), between the name and
-- the columns.
local REMOVE_WIDTH = 16

local function PlaceMaterialRow(row)
    local offset = ns.Columns:Place("queue", MATERIAL_COLUMNS, row.cells, { start = -36, gap = 8 })
    row.columnsOffset = offset
    row.remove:ClearAllPoints()
    row.remove:SetPoint("RIGHT", row, "RIGHT", offset - 2, 0)
    local nameRight = row.remove:IsShown() and offset - REMOVE_WIDTH - 6 or offset
    row.name:SetPoint("RIGHT", row, "RIGHT", nameRight, 0)
    row.columnsVersion = ns.Columns.version
end

local function CreateMaterialRow(row)
    row.icon = Theme.CreateItemIcon(row, 14)
    row.icon:SetPoint("LEFT", 6, 0)

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("LEFT", 24, 0)

    row.cells = {}
    for _, column in ipairs(MATERIAL_COLUMNS) do
        row.cells[column.key] = Theme.CreateLabel(row, "small", "muted", column.justify or "RIGHT")
    end

    -- Takes a line asked for from Blackthornes Equipment off the list.
    row.remove = Widgets.CreateButton(row, "x", function()
        if row.data then ns.Queue:RemoveBuys(row.data.itemID) end
    end, { width = REMOVE_WIDTH, height = 16, danger = true,
        tooltip = L["Take this off the list to buy. Your queued crafts keep what they need."] })
    row.remove:Hide()
    PlaceMaterialRow(row)

    row.search = Widgets.CreateButton(row, L["AH"], function()
        if row.data then UI:SearchOrPlan(row.data.itemID, row.data.shortfall) end
    end, { width = 26, height = 16, tooltip = L["Search the auction house for this"] })
    row.search:SetPoint("RIGHT", -4, 0)
end

local function UpdateMaterialRow(row, line)
    local asked = line.buys ~= nil
    if row.columnsVersion ~= ns.Columns.version or row.remove:IsShown() ~= asked then
        row.remove:SetShown(asked)
        PlaceMaterialRow(row)
    end

    -- The plain name, in its rarity colour unless it is recoloured below
    -- (set on the label, so no link's own colour code covers it).
    local nameColour = line.shortfall <= 0 and "muted" or line.altCraft and "profit" or nil
    local name = Util.GetItemName(line.itemID)
    -- Bought and still to collect: a quiet note, so a smaller "still needed"
    -- is not a surprise. Once they cover the lot the cost column says so.
    if (line.bought or 0) > 0 and line.shortfall > 0 then
        name = name .. " |c" .. ns.COLORS.muted .. L.Format("(%d in mail)", line.bought) .. "|r"
    end
    Theme.SetRowName(row.name, name)
    Theme.SetItemIcon(row.icon, line.itemID)

    local cells = row.cells

    -- Need and have as separate columns under their own headings, rather than
    -- a combined "2/5" that has to be decoded. The raw holding is shown here,
    -- surplus and all, because the column heading now says what it means.
    cells.need:SetText(tostring(line.needed))
    cells.need:SetTextColor(Theme.Unpack("muted"))

    cells.have:SetText(tostring(line.have))

    if line.shortfall > 0 then
        cells.have:SetTextColor(Theme.Unpack("loss"))
    elseif line.needsBankTrip or line.needsMailTrip then
        -- Owned, but not on you. Amber rather than green: nothing to buy, but
        -- you cannot craft it until you visit the bank or the mailbox.
        cells.have:SetTextColor(Theme.Unpack("warn"))
    else
        cells.have:SetTextColor(Theme.Unpack("profit"))
    end

    if line.shortfall > 0 then
        -- Measured: an amount too wide for the column loses coins, rounded,
        -- rather than ending in "...".
        if line.estimatedCost then
            Theme.SetMoneyText(cells.cost, line.estimatedCost, { short = true })
        else
            cells.cost:SetText("?")
        end
        cells.cost:SetTextColor(Theme.Unpack(line.overpaid and "warn"
            or line.fromVendor and "accent" or "muted"))

        -- Green: another of your characters can make it for less.
        ApplyMaterialColor(row, line.itemID, nameColour)

        -- Buying a vendor reagent off the auction house is a mistake, so do
        -- not offer the search for it, unless the vendor's stock is limited.
        row.search:SetShown(not line.fromVendor or line.vendorLimited == true)
    elseif line.paid and not line.needsBankTrip then
        -- Bought: what it cost stands where the estimate stood, amber when
        -- it came to well over it.
        Theme.SetMoneyText(cells.cost, line.paid, { short = true })
        cells.cost:SetTextColor(Theme.Unpack(line.overpaid and "warn" or "muted"))

        ApplyMaterialColor(row, line.itemID, nameColour)
        row.search:Hide()
    else
        cells.cost:SetText(line.needsBankTrip and L["in bank"]
            or line.needsMailTrip and L["in mail"] or "")
        cells.cost:SetTextColor(Theme.Unpack("warn"))

        ApplyMaterialColor(row, line.itemID, nameColour)
        row.search:Hide()
    end
end

--- What was paid on the auction house today against the estimate, for a
--- shopping list tooltip. Shared with the Gather tab.
function UI.AddPaidLines(line)
    if not line.paid then return end
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine(L.Format("Paid for %d today", line.paidUnits or 0),
        Util.FormatMoney(line.paid, { noColor = true }),
        0.7, 0.7, 0.7, 1, 1, 1)
    if line.paidEstimate then
        GameTooltip:AddDoubleLine(L["The list had said"],
            Util.FormatMoney(line.paidEstimate, { noColor = true }),
            0.7, 0.7, 0.7, 1, 1, 1)
    end
    if line.overpaid then
        local over = math.floor((line.paid / line.paidEstimate - 1) * 100 + 0.5)
        GameTooltip:AddLine(L.Format("%d%% more than expected. The cheap listings may have sold out.", over),
            0.91, 0.76, 0.35, true)
    end
end

--- Full numbers on hover, including surplus and anything held by alts.
-- On UI as well, for the shopping list beside the profession window.
local function ShowMaterialTooltip(row, line)
    ns.Widgets.ShowItemTooltip(row, "ANCHOR_RIGHT", line.itemID, Util.GetItemLabel(line.itemID))
    GameTooltip:AddLine(" ")

    if line.fromVendor then
        GameTooltip:AddLine(line.vendorLimited
            and L["Sold by a vendor (limited stock)"] or L["Sold by a vendor"], 0.78, 0.64, 0.30)
    end

    GameTooltip:AddDoubleLine(L["Required"], tostring(line.needed), 0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddDoubleLine(L["In bags"], tostring(line.inBags or 0), 0.7, 0.7, 0.7, 1, 1, 1)

    if (line.inBank or 0) > 0 then
        GameTooltip:AddDoubleLine(L["In bank"], tostring(line.inBank),
            0.7, 0.7, 0.7, 0.91, 0.76, 0.35)
    end

    if (line.inMail or 0) > 0 then
        GameTooltip:AddDoubleLine(L["In mail"], tostring(line.inMail),
            0.7, 0.7, 0.7, 0.91, 0.76, 0.35)
    end

    if (line.bought or 0) > 0 then
        GameTooltip:AddLine(L.Format("%d bought on the auction house, waiting in the mail.", line.bought),
            0.91, 0.76, 0.35)
    end

    if line.needsBankTrip then
        GameTooltip:AddLine(L["You own enough, but some is in the bank."], 0.91, 0.76, 0.35)
    elseif line.needsMailTrip then
        GameTooltip:AddLine(L["You own enough, but some is in the mailbox."], 0.91, 0.76, 0.35)
    end

    if line.have > line.needed then
        GameTooltip:AddDoubleLine(L["Surplus"], tostring(line.have - line.needed),
            0.7, 0.7, 0.7, 0.31, 0.82, 0.55)
    end

    if line.shortfall > 0 then
        GameTooltip:AddDoubleLine(L["Still needed"], tostring(line.shortfall),
            0.7, 0.7, 0.7, 0.9, 0.38, 0.31)

        if line.unitCost then
            GameTooltip:AddDoubleLine(L["Cost to buy"],
                Util.FormatMoney(line.estimatedCost, { noColor = true }),
                0.7, 0.7, 0.7, 1, 1, 1)
        else
            GameTooltip:AddLine(L["No auction data for this material"], 0.9, 0.38, 0.31)
        end
    end

    UI.AddPaidLines(line)

    local offer = line.altCraft
    if offer then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L.Format("Cheaper to make on %s", offer.characterName), 0.31, 0.82, 0.55)
        GameTooltip:AddDoubleLine(L["Cost to make"],
            Util.FormatMoney(offer.unitCost * line.shortfall, { noColor = true }),
            0.7, 0.7, 0.7, 1, 1, 1)
        if offer.saving then
            GameTooltip:AddDoubleLine(L["You save"],
                Util.FormatMoney(offer.saving, { noColor = true }),
                0.7, 0.7, 0.7, 0.31, 0.82, 0.55)
        end
        GameTooltip:AddLine(L.Format("Log in on that character to queue %d x %s there. Mail it over once it's made.",
            offer.crafts, offer.recipeName or L["it"]), 0.7, 0.7, 0.7, true)
    end

    -- Shared with the alts: how much of this another character's crafts
    -- use. What they already hold of it is not on your list.
    if line.forOthers then
        local keys = {}
        for characterKey in pairs(line.forOthers) do keys[#keys + 1] = characterKey end
        table.sort(keys)
        for _, characterKey in ipairs(keys) do
            GameTooltip:AddDoubleLine(L.Format("For %s's crafts", ns.Recipes:GetCharacterName(characterKey)),
                tostring(line.forOthers[characterKey]), 0.7, 0.7, 0.7, 0.91, 0.76, 0.35)
        end
        if (line.othersHold or 0) > 0 then
            GameTooltip:AddDoubleLine(L["They already hold"], tostring(line.othersHold),
                0.7, 0.7, 0.7, 0.31, 0.82, 0.55)
        end
    end

    -- Put here by Blackthornes Equipment's Queue it button.
    if line.buys then
        GameTooltip:AddLine(" ")
        local forUpgrade = false
        for _, wanted in ipairs(line.buys) do
            local label
            if wanted.forRecipe then
                label = L.Format("To learn and skill up, %s", wanted.forRecipeName or L["a recipe"])
            else
                forUpgrade = true
                label = wanted.forItem == line.itemID and L["To buy for your upgrade"]
                    or L.Format("For your upgrade, %s", Util.GetItemLabel(wanted.forItem))
            end
            GameTooltip:AddDoubleLine(label, tostring(wanted.count), 0.7, 0.7, 0.7, 0.31, 0.82, 0.55)
        end
        GameTooltip:AddLine(forUpgrade
            and L["The x on the Queue tab takes it off. It's removed once you have the upgrade."]
            or L["The x on the Queue tab takes it off."],
            0.7, 0.7, 0.7, true)
    end

    -- Alt-held stock is never counted as yours automatically: it is not in
    -- reach of the craft you are about to make.
    if line.onAlts and line.onAlts > 0 then
        GameTooltip:AddDoubleLine(L["On other characters"], tostring(line.onAlts),
            0.7, 0.7, 0.7, 0.91, 0.76, 0.35)
    end

    GameTooltip:Show()
end

UI.ShowMaterialTooltip = ShowMaterialTooltip

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

--- Warn when bank counts have not been refreshed this session.
local function UpdateBankNote()
    local note = widgets.bankNote
    if not note then return end

    -- Nothing queued means nothing to be wrong about; do not nag.
    if ns.Inventory:HasReadBankThisSession() or ns.Queue:Count() == 0 then
        note:SetText("")
        return
    end

    local age = ns.Inventory:GetBankAge()

    if age then
        note:SetText(L.Format("Bank not checked this session, so using what it held %s.",
            Util.FormatAgeAgo(age)))
    else
        note:SetText(L["Bank never checked, so HAVE counts bags only."])
    end
end

--- The Craft button's tooltip, saying the bag space it frees when that
--- picked it (Crafting:PickNext).
local function CraftTooltip(slots)
    if slots and slots > 0 then
        return slots == 1
            and L["Makes every craft in this entry. It frees 1 bag slot, more than anything else ready."]
            or L.Format("Makes every craft in this entry. It frees %d bag slots, more than anything else ready.", slots)
    end
    return L["Makes every craft in this entry"]
end

--- Keep the Craft button honest about what it will do, and why it cannot.
-- @return true when the button was set to open a profession window
local function SetCraftButton(button, label)
    button.opensProfession = false

    if ns.Crafting:IsBusy() then
        button:SetText(L["Stop crafting"])
        button:SetEnabledState(true)
        button.tooltipText = L["Stop after the current craft"]
        label:SetText(L["crafting..."])
        label:SetTextColor(Theme.Unpack("profit"))
        return
    end

    if ns.Queue:Count() == 0 then
        button:SetText(L["Craft next"])
        button:SetEnabledState(false)
        button.tooltipText = L["Nothing is queued"]
        label:SetText("")
        return
    end

    local ready, total = ns.Crafting:GetQueueReadiness()
    local entry, slots = ns.Crafting:GetNextReady()

    if not entry then
        button:SetText(L["Craft next"])
        button:SetEnabledState(false)

        -- Report the first entry's actual obstacle rather than a generic one.
        local _, reason = ns.Crafting:GetReadiness(ns.Queue:GetAll()[1].recipeID)

        button.tooltipText = reason or L["Nothing here can be made yet"]
        label:SetText(reason or L["nothing ready"])
        label:SetTextColor(Theme.Unpack("warn"))
        return
    end

    local recipe = ns.Recipes:GetAny(entry.recipeID)
    local canMake = math.min(entry.quantity, ns.Profit:GetCraftableCount(entry.recipeID))

    -- A craft only starts from its own profession window. When that is not
    -- the one open, this click opens it instead: the game lets a player's
    -- click cast the profession, which addon code alone may not do.
    local opener = ns.ProfessionOpener

    -- In travel form or the like, the first click leaves it (a secure
    -- button, since addon code may not); the next opens or crafts.
    local leave = opener and opener.LeaveFormStep and opener:LeaveFormStep()
    if leave then
        button:SetText(L["Leave form"])
        button:SetEnabledState(true)
        button.tooltipText = L["Click to leave your form, then click again to craft. Not in combat."]
        label:SetText(L.Format("%d of %d ready. Leave your form first", ready, total))
        label:SetTextColor(Theme.Unpack("accent"))
        button.opensProfession = true
        opener:Arm(button, leave, entry.recipeID)
        return true
    end

    if opener and not opener:WindowShowsRecipe(entry.recipeID) then
        local profession = opener:ProfessionFor(entry.recipeID)

        if profession then
            button:SetText(L.Format("Open %s", profession.name))
            button:SetEnabledState(true)
            button.tooltipText = L.Format("Opens your %s window. Click again to craft %dx %s.",
                profession.name, canMake, (recipe and recipe.name) or L["item"])

            label:SetText(L.Format("%d of %d ready. Click to open %s", ready, total, profession.name))
            label:SetTextColor(Theme.Unpack("accent"))

            button.opensProfession = true
            opener:Arm(button, profession, entry.recipeID)
            return true
        end
    end

    button:SetText(L.Format("Craft %dx %s", canMake, (recipe and recipe.name) or L["item"]))
    button:SetEnabledState(true)
    button.tooltipText = CraftTooltip(slots)

    label:SetText(L.Format("%d of %d ready", ready, total))
    label:SetTextColor(Theme.Unpack("profit"))

    -- Crafting works without the window open on some clients and not others;
    -- say so rather than letting a click quietly do nothing.
    if not ns.Crafting.isTradeSkillOpen then
        label:SetText(L.Format("%d of %d ready. Open your profession", ready, total))
        label:SetTextColor(Theme.Unpack("accent"))
    end
end

local function UpdateCraftStatus()
    local button, label = widgets.craftButton, widgets.craftStatus
    if not button then return end

    -- Every other state wants the click to reach the craft button itself.
    -- Only our own button, as the Level Up tab does: that tab may be holding
    -- the secure button over its Craft button.
    local opener = ns.ProfessionOpener
    if not SetCraftButton(button, label) and opener and opener.anchor == button then
        opener:Disarm()
    end
end

-- Suggestions already announced in chat this session, so each is said once.
local announcedAltCrafts = {}

--- Say in chat, once, each time a new cheaper way turns up on another character.
local function AnnounceAltCrafts(lines)
    local found = false

    for _, line in ipairs(lines) do
        local offer = line.altCraft
        local key = offer and (line.itemID .. ":" .. offer.characterKey)

        if key and not announcedAltCrafts[key] then
            announcedAltCrafts[key] = true
            found = true

            if offer.saving and offer.saving > 0 then
                ns.Print(L.Format("Cheaper way found: %s can make %s and save you %s. Log in there and it will be in your queue.",
                    offer.characterName, Util.GetItemLabel(line.itemID), Util.FormatMoney(offer.saving)))
            else
                ns.Print(L.Format("Cheaper way found: %s can make %s. Log in there and it will be in your queue.",
                    offer.characterName, Util.GetItemLabel(line.itemID)))
            end
        end
    end

    -- Settings: SOUNDS, Cheaper on another character.
    if found and type(PlaySound) == "function" and ns.Config:Get("altCraftSound") ~= false then
        local kits = type(_G.SOUNDKIT) == "table" and _G.SOUNDKIT or {}
        local kit = kits.LOOT_WINDOW_COIN_SOUND or 120
        pcall(PlaySound, kit, "Master")
    end
end

--- The line under the materials naming each character worth swapping to.
local MAX_ALT_NOTES = 3

local function UpdateAltNote(lines)
    local note = widgets.altNote
    if not note then return end

    local notes, extra = {}, 0
    for _, line in ipairs(lines) do
        local offer = line.altCraft
        if offer then
            if #notes < MAX_ALT_NOTES then
                if offer.saving and offer.saving > 0 then
                    notes[#notes + 1] = L.Format("Swap to %s to make %s, saves %s",
                        offer.characterName, Util.GetItemLabel(line.itemID),
                        Util.FormatMoney(offer.saving, { short = true }))
                else
                    notes[#notes + 1] = L.Format("Swap to %s to make %s",
                        offer.characterName, Util.GetItemLabel(line.itemID))
                end
            else
                extra = extra + 1
            end
        end
    end

    if extra > 0 then
        notes[#notes + 1] = L.Format("and %d more, shown in green", extra)
    end

    note:SetText(table.concat(notes, "\n"))

    -- The list makes room for the note rather than running under it.
    local reserve = 48
    if #notes > 0 then
        reserve = reserve + (note:GetStringHeight() or 0) + 4
    end
    widgets.materialList:SetPoint("BOTTOMRIGHT", widgets.materials, "BOTTOMRIGHT", -10, reserve)
end

--- Disenchant next: the secure Disenchant button aimed at the next item the
--- queue made on DE. Off unless Settings turns it on, and only for items
--- the queue marked (Logic/QueueActions.lua). One click, one disenchant.
local function UpdateDisenchantNext()
    local button = widgets.deNext
    if not button then return end

    local itemID, bag, slot, total
    local show = ns.Config:Get("queueDisenchantNext") == true and ns.QueueActions ~= nil
        and ns.Disenchanter ~= nil and not InCombat()
        and widgets.craftList:IsVisible()

    if show and ns.Disenchanter:Knows() == false then show = false end
    if show then
        itemID, bag, slot, total = ns.QueueActions:Next("disenchant")
        show = itemID ~= nil
    end

    local rule = widgets.queueHeading and widgets.queueHeading.rule

    if not show then
        if not InCombat() then button:Hide() end
        if rule then rule:SetPoint("RIGHT", widgets.clearButton, "LEFT", -8, 0) end
        return
    end

    button:Show()
    if rule then rule:SetPoint("RIGHT", button, "LEFT", -8, 0) end

    local label = Util.GetItemLabel(itemID)
    local name = Util.Uncolored(label)
    name = name:match("^%[(.*)%]$") or name

    button.overlayText = Theme.FitText(button.label, {
        L.Format("Disenchant next: %s (%d)", name, total),
        L.Format("Disenchant: %s", name),
        L.Format("Disenchant next (%d)", total),
    })
    button.tooltipText = L.Format("Disenchants %s from your bags. Your queue marked %d to disenchant.", name, total)
        .. "\n" .. L["Never blue or better, anything worn, or anything the queue didn't make."]

    ns.Disenchanter:Arm(button, itemID, bag, slot)
end

local function Refresh()
    if not widgets.craftList then return end

    local queue = ns.Queue:GetAll()

    -- Copy so sorting for display never reorders the stored queue.
    local entries = {}
    for index, entry in ipairs(queue) do
        entries[index] = entry
    end

    entryCosts = ns.Queue:GetEntryCosts()
    widgets.craftList:SetData(entries)
    local shopping = ns.Queue:GetShoppingList()
    -- A clicked heading's order over the list's own.
    widgets.materialList:SetData(widgets.materialSorter and widgets.materialSorter:Sort(shopping) or shopping)
    UpdateAltNote(shopping)
    AnnounceAltCrafts(shopping)

    widgets.emptyLabel:SetShown(#entries == 0)

    local totals = ns.Queue:GetTotals()
    -- From the list already built above, not a second walk of everything.
    local shoppingCost, unknown = ns.Queue:GetShoppingTotal(shopping)

    UpdateCraftStatus()
    UpdateBankNote()
    UpdateDisenchantNext()

    if #entries == 0 then
        widgets.summaryLabel:SetText("")
        -- Nothing queued, but gear may still be on the list to buy.
        widgets.shoppingLabel:SetText(#shopping > 0 and (unknown > 0
            and L.Format("To buy: %s  (+%d unpriced)", Util.FormatMoney(shoppingCost, { short = true }), unknown)
            or L.Format("To buy: %s", Util.FormatMoney(shoppingCost, { short = true }))) or "")
        return
    end

    widgets.summaryLabel:SetText(L.Format(totals.crafts == 1
            and L["%d craft  ·  materials %s  ·  profit %s"] or L["%d crafts  ·  materials %s  ·  profit %s"],
        totals.crafts,
        Util.FormatMoney(totals.cost, { short = true }),
        Util.FormatMoney(totals.profit, { short = true }))
        .. (totals.priceable and "" or L["  (some unpriced)"]))

    widgets.shoppingLabel:SetText(unknown > 0
        and L.Format("To buy: %s  (+%d unpriced)", Util.FormatMoney(shoppingCost, { short = true }), unknown)
        or L.Format("To buy: %s", Util.FormatMoney(shoppingCost, { short = true })))
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function Build(container)
    -- Before any row or heading is laid out: they read these widths.
    if Widgets.FitColumns then Widgets.FitColumns(MATERIAL_COLUMNS) end

    local heading = Theme.CreateLabel(container, "tiny", "accent")
    heading:SetPoint("TOPLEFT", 8, -10)
    heading:SetText(L["QUEUED CRAFTS"])

    -- A queue can take a while to build, so emptying it takes a second click,
    -- the same as Clear queue on the craft pane.
    local clear
    local armedUntil

    local function Disarm()
        armedUntil = nil
        clear:SetText(L["Clear all"])
        clear:SetConfirming(false)
        clear.tooltipText = L["Empties the whole craft queue. Click twice to clear."]
    end

    clear = Widgets.CreateButton(container, L["Clear all"], function()
        if armedUntil and GetTime() < armedUntil then
            local count = ns.Queue:Count()
            Disarm()
            ns.Queue:Clear()
            ns.Print(count == 1 and L.Format("Craft queue cleared (%d entry).", count)
                or L.Format("Craft queue cleared (%d entries).", count))
            return
        end

        if ns.Queue:Count() == 0 and not ns.Queue:HasBuys() then return end

        armedUntil = GetTime() + 4
        clear:SetText(L["Click Again"])
        clear:SetConfirming(true)
        clear.tooltipText = L["Click again to empty the whole craft queue"]

        C_Timer.After(4, function()
            if armedUntil and GetTime() >= armedUntil then Disarm() end
        end)
    end, { width = 84, height = 18 })
    clear.tooltipText = L["Empties the whole craft queue. Click twice to clear."]
    clear:SetPoint("TOPRIGHT", container, "TOPRIGHT", -MATERIALS_WIDTH - 16, -8)
    widgets.clearButton = clear
    widgets.queueHeading = heading

    -- The secure Disenchant button lies over this one while it is armed; a
    -- click that reaches this one found it not set, so it is set now.
    local deNext = Widgets.CreateButton(container, L["Disenchant next"], function()
        UpdateDisenchantNext()
        ns.Print(L["Disenchant next was not ready. Click it again."])
    end, { width = DE_NEXT_WIDTH, height = 18, primary = true })
    deNext:SetPoint("RIGHT", clear, "LEFT", -6, 0)
    deNext.onSecureClick = function(itemID)
        if ns.QueueActions then ns.QueueActions:NoteDisenchantClick(itemID) end
    end
    deNext:Hide()
    widgets.deNext = deNext

    local divider = Theme.CreateDivider(container)
    divider:SetPoint("TOPLEFT", 8, -26)
    divider:SetPoint("TOPRIGHT", container, "TOPRIGHT", -MATERIALS_WIDTH - 16, -26)
    -- Kept as the list's anchor, but the heading carries the house rule now,
    -- running from the words to the Clear all button, like MATERIALS NEEDED.
    divider:Hide()
    Theme.StyleHeading(heading, container)
    heading.rule:ClearAllPoints()
    heading.rule:SetPoint("LEFT", heading, "RIGHT", 6, 0)
    heading.rule:SetPoint("RIGHT", clear, "LEFT", -8, 0)

    -- Show Equipment Upgrades (2026-10-17), after the heading; the rule
    -- starts past it.
    local altBox = ns.Upgrades and ns.Upgrades.CreateAltCheckbox and ns.Upgrades:CreateAltCheckbox(container)
    if altBox then
        altBox:SetPoint("LEFT", heading, "RIGHT", 10, 0)
        if altBox:IsShown() then
            heading.rule:ClearAllPoints()
            heading.rule:SetPoint("LEFT", altBox, "RIGHT", 6, 0)
            heading.rule:SetPoint("RIGHT", clear, "LEFT", -8, 0)
        end
    end

    local craftList = Widgets.CreateScrollList(container, {
        -- The craft being made stays lit, as in the craft pane's list.
        isSelected = function(entry)
            local active = ns.Crafting.active
            return active ~= nil and active.recipeID == entry.recipeID
        end,
        rowHeight = ROW_HEIGHT,
        createRow = CreateCraftRow,
        updateRow = UpdateCraftRow,

        -- The item the craft makes, as the bags would show it.
        onEnter = function(row, entry)
            local recipe = ns.Recipes:GetAny(entry.recipeID)
            Widgets.ShowItemOnly(row, recipe and recipe.outputItemID, recipe and recipe.name)
        end,
        onLeave = function() GameTooltip:Hide() end,
    })
    craftList:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -4)
    craftList:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -MATERIALS_WIDTH - 16, 62)
    widgets.craftList = craftList

    -- Crafting needs a hardware event, so this is a real click each time:
    -- one click runs one queue entry to completion.
    widgets.craftButton = Widgets.CreateButton(container, L["Craft next"], function()
        if ns.Crafting:IsBusy() then
            ns.Crafting:Stop()
        else
            local entry = ns.Crafting:GetNextReady()
            if widgets.craftButton.opensProfession and ns.ProfessionOpener then
                -- The secure Open button should have taken this click.
                ns.ProfessionOpener:MissedClick()
            elseif entry then
                ns.Crafting:Start(entry.recipeID, entry.quantity)
            end
        end

        Refresh()
    end, { width = 220, height = 26, primary = true })
    widgets.craftButton:SetPoint("BOTTOMLEFT", 8, 32)
    -- An Era enchant is made by a secure button laid over this one.
    if ns.SecureCraft then
        ns.SecureCraft:Attach(widgets.craftButton, function()
            local entry = ns.Crafting:GetNextReady()
            if entry then return entry.recipeID, entry.quantity end
        end)
    end

    widgets.craftStatus = Theme.CreateLabel(container, "small", "accent")
    widgets.craftStatus:SetPoint("LEFT", widgets.craftButton, "RIGHT", 10, 0)
    widgets.craftStatus:SetWidth(320)

    -- While a craft casts, a progress bar takes the status line's place.
    widgets.craftProgress = ns.CraftProgress:Create(container, {
        width = 320, height = 20, covers = widgets.craftStatus,
    })
    widgets.craftProgress:SetPoint("LEFT", widgets.craftButton, "RIGHT", 10, 0)


    local emptyLabel = Theme.CreateLabel(container, "small", "dim", "CENTER")
    emptyLabel:SetPoint("CENTER", craftList, "CENTER")
    emptyLabel:SetWidth(300)
    emptyLabel:SetWordWrap(true)
    emptyLabel:SetText(L["Nothing queued.\nRight-click a craft on the Profit tab to add one."])
    widgets.emptyLabel = emptyLabel

    local summaryLabel = Theme.CreateLabel(container, "small", "text")
    summaryLabel:SetPoint("BOTTOMLEFT", 8, 10)
    widgets.summaryLabel = summaryLabel

    -- Materials panel
    local materials = Theme.CreatePanel(container, "window")
    materials:SetPoint("TOPRIGHT", -8, -8)
    materials:SetPoint("BOTTOMRIGHT", -8, 8)
    materials:SetWidth(MATERIALS_WIDTH)
    widgets.materials = materials

    local materialsHeading = Theme.CreateLabel(materials, "tiny", "accent")
    materialsHeading:SetPoint("TOPLEFT", 10, -10)
    materialsHeading:SetText(L["MATERIALS NEEDED"])
    -- The house heading: gold, with the rule running off to the right.
    Theme.StyleHeading(materialsHeading, materials)

    -- Column headings, so NEED and HAVE are labelled rather than inferred.
    local columnHeader = CreateFrame("Frame", nil, materials)
    columnHeader:SetPoint("TOPLEFT", 10, -28)
    columnHeader:SetPoint("TOPRIGHT", -10, -28)
    columnHeader:SetHeight(14)

    local nameHeading = Theme.CreateLabel(columnHeader, "tiny", "muted")
    nameHeading:SetPoint("LEFT", 24, 0)
    nameHeading:SetText(L["MATERIAL"])

    local sortLabels, cells = { name = nameHeading }, {}
    for _, column in ipairs(MATERIAL_COLUMNS) do
        local heading = Theme.CreateLabel(columnHeader, "tiny", "muted", column.justify or "RIGHT")
        heading:SetText(column.label)
        sortLabels[column.key] = heading
        cells[column.key] = heading
    end
    ns.Columns:Place("queue", MATERIAL_COLUMNS, cells, { start = -36, gap = 8 })

    -- Click a heading to sort the materials by it.
    widgets.materialSorter = Widgets.SortableHeadings and Widgets.SortableHeadings(sortLabels, {
        name = function(line)
            return Util.Uncolored(Util.GetItemName(line.itemID) or "")
        end,
        cost = function(line) return line.estimatedCost end,
        have = function(line) return line.have end,
        need = function(line) return line.needed end,
    }, function() Refresh() end)
    if widgets.materialSorter then widgets.materialSorter:SetText({ "name" }) end

    -- Right-click the headings to choose the columns.
    ns.Columns:Attach(columnHeader, "queue", widgets.materialSorter)
    ns.Columns:OnChange("queue", function()
        ns.Columns:Place("queue", MATERIAL_COLUMNS, cells, { start = -36, gap = 8 })
        if widgets.materialSorter then widgets.materialSorter:Sync() end
        if widgets.materialList then widgets.materialList:Refresh() end
    end)

    local materialsDivider = Theme.CreateDivider(materials)
    materialsDivider:SetPoint("TOPLEFT", 10, -45)
    materialsDivider:SetPoint("TOPRIGHT", -10, -45)

    local materialList = Widgets.CreateScrollList(materials, {
        rowHeight = 20,
        createRow = CreateMaterialRow,
        updateRow = UpdateMaterialRow,
        onEnter = ShowMaterialTooltip,
        onLeave = function() GameTooltip:Hide() end,
        -- The headings move in with the rows when the scrollbar takes its room.
        onScrollbarShown = function(shown)
            columnHeader:SetPoint("TOPRIGHT", shown and -20 or -10, -28)
        end,
    })
    materialList:SetPoint("TOPLEFT", materialsDivider, "BOTTOMLEFT", 0, -4)
    materialList:SetPoint("BOTTOMRIGHT", materials, "BOTTOMRIGHT", -10, 48)
    widgets.materialList = materialList

    -- Bank stock counts toward HAVE, so if the bank has not been opened this
    -- session those numbers may be understated. Say so rather than letting
    -- the player trust a stale snapshot.
    local bankNote = Theme.CreateLabel(materials, "tiny", "warn")
    bankNote:SetPoint("BOTTOMLEFT", 10, 26)
    bankNote:SetPoint("BOTTOMRIGHT", -10, 26)
    bankNote:SetWordWrap(true)
    bankNote:SetJustifyV("BOTTOM")
    widgets.bankNote = bankNote

    -- Materials another character can make for less, when Settings asks.
    -- Grows upward from just above the bank note.
    local altNote = Theme.CreateLabel(materials, "tiny", "profit")
    altNote:SetPoint("BOTTOMLEFT", 10, 48)
    altNote:SetPoint("BOTTOMRIGHT", -10, 48)
    altNote:SetWordWrap(true)
    altNote:SetJustifyV("BOTTOM")
    widgets.altNote = altNote

    local shoppingLabel = Theme.CreateLabel(materials, "small", "text")
    shoppingLabel:SetPoint("BOTTOMLEFT", 10, 10)
    widgets.shoppingLabel = shoppingLabel

    -- A craft drawn before the client had its item gets its rarity colour
    -- when the item arrives. Only the craft list is redrawn, not the whole
    -- tab, so the alt-craft chat line and sound do not play again; a burst
    -- of arrivals is one redraw, and nothing happens unless a row waits.
    local redrawQueued = false
    ns.RegisterEvent(widgets, "GET_ITEM_INFO_RECEIVED", function()
        if redrawQueued or not awaitingItemData then return end
        if not craftList:IsVisible()
            and not (widgets.materialList and widgets.materialList:IsVisible()) then return end

        redrawQueued = true
        C_Timer.After(0.2, function()
            redrawQueued = false
            awaitingItemData = false
            craftList:Refresh()
            if widgets.materialList and widgets.materialList:IsVisible() then
                widgets.materialList:Refresh()
            end
        end)
    end)
end

UI:RegisterTab({
    key = "queue",
    text = L["Queue"],
    order = 2,
    build = Build,
    refresh = Refresh,
})

--- Marks changed, or the bags did: re-aim Disenchant next and Sell marked.
function UI:OnQueueMarksChanged()
    if self.activeTab == "queue" and self.window and self.window:IsShown() then
        UpdateDisenchantNext()
    end
    if ns.SellMarked then ns.SellMarked:Update() end
end

function UI:OnQueueUpdated()
    -- A finished sub-craft changes the queue twice in one frame, and each
    -- redraw prices the whole queue. The first redraws at once (a click
    -- answers at once); any more in the same frame make one on the next.
    local now = type(GetTime) == "function" and GetTime() or nil
    if now and self.queueRedrawnAt == now then
        if not self.queueRedrawSoon and C_Timer and C_Timer.After then
            self.queueRedrawSoon = true
            C_Timer.After(0, function()
                UI.queueRedrawSoon = false
                UI.queueRedrawnAt = nil
                UI:OnQueueUpdated()
            end)
        end
        return
    end
    self.queueRedrawnAt = now
    ns.Queue:Keeping(UI.RedrawQueue, self)
end

--- The craft pane and the Queue tab (or the tab showing), sharing one
--- build of the costs and the shopping list (Queue:Keeping).
function UI:RedrawQueue()
    -- The craft pane beside the profession window shows the same queue, and
    -- is usually the thing that just changed it.
    if ns.CraftPanel then ns.CraftPanel:OnQueueChanged() end

    -- Only while the window is showing: redrawing a hidden Queue tab also
    -- ran its alt-craft announcement, chat line and coin sound included,
    -- every time something was queued from the craft pane.
    if self.activeTab == "queue" and self.window and self.window:IsShown() then
        Refresh()
    else
        -- The Gather tab is derived from the queue, so it goes stale too.
        self:RefreshActiveTab()
    end
end
