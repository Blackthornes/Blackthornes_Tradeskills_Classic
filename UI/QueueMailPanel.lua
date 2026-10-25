-- Blackthornes Tradeskills -- UI/QueueMailPanel.lua
-- Beside the mailbox: what to send your other characters for the queue.
--
-- Asked 2026-10-03: "when you go to the mail it should allow you to auto
-- send materials this character has to the one that needs it". One row per
-- character, with what to send and a Send to button that opens Send Mail,
-- fills in the name and attaches the items. The player presses Send: mail
-- costs postage and cannot be taken back. Logic/QueueMail.lua works out
-- what goes where; this only draws it.
--
-- Asked 2026-10-06: an alt that has finished a craft another character
-- needs gets its own row for it at the mailbox, "Crafts for Bob", in the
-- profit green, with a Send crafts to Bob button, ahead of any materials.
--
-- Blackthornes Butler takes over the mailbox when it is loaded (the owner
-- picked it, 2026-10-11): while Butler's window is up there it says so
-- through Butler:Mailbox (Logic/Butler.lua), and this panel stays hidden
-- until that window closes.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local QueueMailPanel = {}
ns.QueueMailPanel = QueueMailPanel

local WIDTH = 286
local PAD = 12
local ROW_HEIGHT = 44
local BUTTON_WIDTH = 112
local MAX_ROWS = 5

--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------

-- The plain name in its rarity colour: a link's brackets read as clutter
-- in a line of several items.
local function ItemName(itemID)
    return Util.ColoredItemName(itemID)
end

--- The items line, longest wording first, so the row can take the first
--- that fits: every item, then the first and a count, then a count.
local function ItemTexts(items)
    local parts = {}
    local total = 0
    for index, item in ipairs(items) do
        parts[index] = ("%d %s"):format(item.count, ItemName(item.itemID))
        total = total + item.count
    end

    local texts = { table.concat(parts, ", ") }
    if #parts > 1 then
        texts[#texts + 1] = L.Format("%s and %d more", parts[1], #parts - 1)
    end
    texts[#texts + 1] = total == 1 and L["1 item"] or L.Format("%d items", total)
    return texts
end

-- Quality words in the game's own rarity colours.
local QUALITY_WORDS = {
    [2] = L["|cff1eff00green|r"],
    [3] = L["|cff0070ddblue|r"],
    [4] = L["|cffa335eepurple|r"],
}

--- The disenchanter's row: how many of each quality, then just how many.
local function GearTexts(items)
    local byQuality, total = {}, 0
    for _, item in ipairs(items) do
        local quality = item.quality or 2
        byQuality[quality] = (byQuality[quality] or 0) + item.count
        total = total + item.count
    end

    local parts = {}
    for quality = 4, 2, -1 do
        if byQuality[quality] then
            parts[#parts + 1] = ("%d %s"):format(byQuality[quality], QUALITY_WORDS[quality])
        end
    end

    local joined = #parts > 1
        and L.Format("%s and %s", table.concat(parts, ", ", 1, #parts - 1), parts[#parts])
        or parts[1] or ""
    return {
        L.Format("%s to disenchant", joined),
        joined,
        total == 1 and L["1 piece of gear"] or L.Format("%d pieces of gear", total),
    }
end

--- The name a row's button and status use: the character's short name, or
--- the disenchanter's name as typed, without its realm.
local function ShortName(delivery)
    if delivery.to and ns.Recipes.GetShortCharacterName then
        return ns.Recipes:GetShortCharacterName(delivery.to)
    end
    local name = delivery.recipient or delivery.name or ""
    return name:match("^([^-]+)") or name
end

local function CreateRow(panel, index)
    local row = CreateFrame("Frame", nil, panel)
    row:SetSize(WIDTH - 2 * PAD, ROW_HEIGHT)

    row.name = Theme.CreateLabel(row, "normal", "text")
    row.name:SetPoint("TOPLEFT", 0, -6)
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -(BUTTON_WIDTH + 8), -6)

    row.items = Theme.CreateLabel(row, "small", "muted")
    row.items:SetPoint("TOPLEFT", 0, -24)
    row.items:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, -24)

    row.send = Widgets.CreateButton(row, L["Send"], function()
        if row.delivery and row.delivery.take then
            QueueMailPanel:TakeFor(row)
        elseif row.delivery then
            QueueMailPanel:FillFor(row)
        end
    end, { width = BUTTON_WIDTH, height = 20, primary = true,
        tooltip = L["Fills in the mail. You press Send."] })
    row.send:SetPoint("TOPRIGHT", 0, -3)

    row.rule = Theme.CreateDivider(row)
    row.rule:SetPoint("BOTTOMLEFT", 0, 0)
    row.rule:SetPoint("BOTTOMRIGHT", 0, 0)

    panel.rows[index] = row
    return row
end

function QueueMailPanel:Build()
    if self.frame then return self.frame end

    local panel = CreateFrame("Frame", nil, UIParent)
    panel:SetSize(WIDTH, 100)
    panel:SetFrameStrata("HIGH")
    panel:SetClampedToScreen(true)
    Theme.Fill(panel, "window", 0.94)
    Theme.Border(panel, "accent", 0.6)
    Theme.AccentStripe(panel, 3)
    Theme.TopSheen(panel, 0.08)
    Theme.Halo(panel, 6, 0.14)
    panel:Hide()

    local heading = Theme.CreateLabel(panel, "tiny", "accent")
    heading:SetPoint("TOPLEFT", PAD, -8)
    heading:SetText(L["SEND FOR THE CRAFT QUEUE"])
    panel.heading = heading

    local close = Widgets.CreateButton(panel, "X", function()
        QueueMailPanel.dismissed = true
        panel:Hide()
    end, { width = 18, height = 16, fontSize = "tiny", tooltip = L["Hide this until the next mailbox visit"] })
    close:SetPoint("TOPRIGHT", -4, -4)

    -- Asked 2026-10-04: the words under the heading were too many, and
    -- there was no way from here to the setting that picks the disenchanter.
    -- The Send button's tooltip says what it does; this goes to Settings.
    local settings = Widgets.CreateButton(panel, L["Settings"], function()
        if not ns.UI then return end
        ns.UI:Show()
        ns.UI:SelectTab("settings")
    end, { width = 60, height = 16, fontSize = "tiny",
        tooltip = L["Pick your disenchanter and the best quality mailed to them"] })
    local labelWidth = Theme.TextWidth and Theme.TextWidth(settings.label)
    if type(labelWidth) == "number" and labelWidth + 14 > 60 then
        settings:SetWidth(math.ceil(labelWidth) + 14)
    end
    settings:SetPoint("RIGHT", close, "LEFT", -6, 0)
    panel.settings = settings

    panel.rows = {}

    panel.more = Theme.CreateLabel(panel, "tiny", "muted")

    panel.status = Theme.CreateLabel(panel, "small", "accent")
    panel.status:SetPoint("BOTTOMLEFT", PAD, 8)
    panel.status:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD, 8)

    -- The mailbox can close without the game saying so, and a mail being
    -- read opens beside it. Checked once a second.
    local since = 0
    panel:SetScript("OnUpdate", function(_, elapsed)
        since = since + (tonumber(elapsed) or 0)
        if since < 1 then return end
        since = 0
        if not QueueMailPanel.MailboxOpen() then
            panel:Hide()
        else
            QueueMailPanel:Place()
        end
    end)

    self.frame = panel
    return panel
end

--------------------------------------------------------------------------------
-- Placing
--------------------------------------------------------------------------------

function QueueMailPanel.MailboxOpen()
    local mailFrame = _G.MailFrame
    if mailFrame and mailFrame.IsShown then
        local ok, shown = pcall(mailFrame.IsShown, mailFrame)
        if ok then return shown and true or false end
    end
    return ns.Mail and ns.Mail.isOpen == true
end

local function Shown(frame)
    if not (frame and frame.IsShown) then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return ok and shown and true or false
end

--- To the right of the mailbox, or of the open letter when one is open, so
--- neither is covered.
function QueueMailPanel:Place()
    local panel = self.frame
    if not panel then return end

    local anchor = Shown(_G.OpenMailFrame) and _G.OpenMailFrame or _G.MailFrame
    if anchor == self.anchoredTo then return end
    self.anchoredTo = anchor

    panel:ClearAllPoints()
    if anchor then
        panel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 8, 0)
    else
        panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 420, -110)
    end
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

--- What to list: the next batch to take from the mail, when that setting is
--- on, then the disenchanter's gear, when one is set, then the queue's
--- deliveries, when the queue mail setting is on.
function QueueMailPanel:GetDeliveries()
    local deliveries = {}

    local okTake, batch = pcall(ns.QueueMail.GetMailBatch, ns.QueueMail)
    if okTake and batch then
        deliveries[1] = { take = true, batch = batch, items = batch.items, name = L["Next batch from your mail"] }
    elseif not okTake then
        ns.Debug("mail batch:", batch)
    end

    local okGear, gear = pcall(ns.QueueMail.GetDisenchantDelivery, ns.QueueMail)
    if okGear and gear then
        deliveries[#deliveries + 1] = gear
    elseif not okGear then
        ns.Debug("disenchanter mail:", gear)
    end

    if ns.Config:Get("queueMailPanel") ~= false then
        local ok, queued = pcall(ns.QueueMail.GetDeliveries, ns.QueueMail)
        if ok then
            for _, delivery in ipairs(queued) do deliveries[#deliveries + 1] = delivery end
        else
            ns.Debug("queue mail:", queued)
        end
    end

    return deliveries, okGear and gear ~= nil
end

function QueueMailPanel:Refresh()
    if self.dismissed or not self.MailboxOpen() then return end
    if self.coveredByButler then
        if self.frame then self.frame:Hide() end
        return
    end

    local deliveries, hasGear = self:GetDeliveries()

    if #deliveries == 0 then
        if self.frame then self.frame:Hide() end
        return
    end

    local panel = self:Build()

    -- Headed for what is on it.
    local onlyGear = hasGear and #deliveries == 1
    local onlyTake = deliveries[1].take and #deliveries == 1
    local onlyCrafts = true
    for _, delivery in ipairs(deliveries) do
        if not delivery.crafts then onlyCrafts = false end
    end
    local headingRoom = WIDTH - PAD - 4 - 18 - 6 - (panel.settings:GetWidth() or 60) - 8
    Theme.FitText(panel.heading, onlyTake and { L["TAKE FOR THE CRAFT QUEUE"], L["TAKE"] }
        or deliveries[1].take and not hasGear and { L["FOR THE CRAFT QUEUE"], L["QUEUE"] }
        or onlyGear and { L["SEND TO YOUR DISENCHANTER"], L["DISENCHANTER"] }
        or hasGear and { L["SEND FROM YOUR BAGS"], L["SEND"] }
        or onlyCrafts and { L["SEND YOUR FINISHED CRAFTS"], L["FINISHED CRAFTS"], L["CRAFTS"] }
        or { L["SEND FOR THE CRAFT QUEUE"], L["FOR THE QUEUE"] }, headingRoom)
    local room = WIDTH - 2 * PAD
    local top = -28

    for index, delivery in ipairs(deliveries) do
        if index > MAX_ROWS then break end
        local row = panel.rows[index] or CreateRow(panel, index)
        row.delivery = delivery

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", PAD, top - (index - 1) * ROW_HEIGHT)

        local short = ShortName(delivery)
        row.name:SetTextColor(Theme.Unpack(delivery.crafts and "profit" or "text"))
        if delivery.take then
            local batch = delivery.batch
            Theme.FitText(row.name, { delivery.name, L["Next batch"] }, room - BUTTON_WIDTH - 8)
            if batch.noRoom then
                Theme.FitText(row.items, { L.Format("No room in your bags (keeping %d slots free)", batch.spare),
                    L["No room in your bags"] }, room)
            else
                Theme.FitText(row.items, ItemTexts(delivery.items), room)
            end
            Theme.FitText(row.send.label, { L["Take next batch"], L["Take"] }, BUTTON_WIDTH - 8)
            row.send.tooltipText = batch.batches > 1
                and L.Format("Takes as much as fits, keeping %d slots free. About 1 of %d batches. Craft, then take the next.",
                    batch.spare, math.min(batch.batches, 999))
                or L["Takes the queue's materials from your mail. Never COD mail."]
            row.send:SetEnabledState(not batch.noRoom and not ns.QueueMail.filling and not ns.QueueMail.taking)
        elseif delivery.disenchant then
            Theme.FitText(row.name, { L.Format("%s, disenchanter", delivery.name), L.Format("%s, disenchanter", short), short },
                room - BUTTON_WIDTH - 8)
            Theme.FitText(row.items, GearTexts(delivery.items), room)
        elseif delivery.crafts then
            Theme.FitText(row.name, { L.Format("Crafts for %s", delivery.name), L.Format("Crafts for %s", short), short },
                room - BUTTON_WIDTH - 8)
            Theme.FitText(row.items, ItemTexts(delivery.items), room)
        else
            Theme.FitText(row.name, { delivery.name, short }, room - BUTTON_WIDTH - 8)
            Theme.FitText(row.items, ItemTexts(delivery.items), room)
        end
        if delivery.crafts then
            Theme.FitText(row.send.label, { L.Format("Send crafts to %s", short), L.Format("Send to %s", short), L["Send"] }, BUTTON_WIDTH - 8)
            row.send.tooltipText = L.Format("Fills in a mail to %s with the crafts their queue needs. You press Send.", short)
            row.send:SetEnabledState(not ns.QueueMail.filling and not ns.QueueMail.taking)
        elseif not delivery.take then
            Theme.FitText(row.send.label, { L.Format("Send to %s", short), L["Send"] }, BUTTON_WIDTH - 8)
            row.send.tooltipText = L["Fills in the mail. You press Send."]
            row.send:SetEnabledState(not ns.QueueMail.filling and not ns.QueueMail.taking)
        end
        row:Show()
    end

    for index = math.min(#deliveries, MAX_ROWS) + 1, #panel.rows do
        panel.rows[index]:Hide()
        panel.rows[index].delivery = nil
    end

    local shownRows = math.min(#deliveries, MAX_ROWS)
    local height = 28 + shownRows * ROW_HEIGHT + 30

    panel.more:ClearAllPoints()
    if #deliveries > MAX_ROWS then
        panel.more:SetPoint("TOPLEFT", PAD, top - shownRows * ROW_HEIGHT - 4)
        panel.more:SetText(L.Format("and %d more after these are sent", #deliveries - MAX_ROWS))
        panel.more:Show()
        height = height + 16
    else
        panel.more:Hide()
    end

    panel:SetHeight(height)
    self:Place()
    panel:Show()
end

--- The postage the game asks for the mail as it stands, or nil.
local function Postage()
    if type(GetSendMailPrice) ~= "function" then return nil end
    local ok, price = pcall(function() return GetSendMailPrice() + 0 end)
    if ok then return price end
end

function QueueMailPanel:FillFor(row)
    local panel = self.frame
    local delivery = row.delivery
    local short = ShortName(delivery)
    self.lastFilled = delivery

    local started, why = ns.QueueMail:Fill(delivery, function(attached, leftOver)
        if not panel then return end

        local postage = Postage()
        local cost = postage and postage > 0 and Util.FormatMoney(postage, { short = true }) or nil

        local texts
        if attached == 0 and leftOver == 0 then
            texts = { L.Format("Name filled in. Drag the items in for %s.", short), L["Drag the items in."] }
        elseif leftOver > 0 then
            texts = { cost and L.Format("%d attached; the rest go in the next mail. Postage %s. Press Send.", attached, cost)
                    or L.Format("%d attached; the rest go in the next mail. Press Send.", attached),
                L.Format("%d attached. Press Send.", attached) }
        else
            texts = { cost and L.Format("All attached. Postage %s. Press Send.", cost) or L["All attached. Press Send."],
                L["Press Send."] }
        end
        -- Part of a stack needs an empty bag slot to be split into first.
        if ns.QueueMail.splitBlocked then
            texts = { L["Free one bag slot to split a stack, then press the button again."],
                L["Free a bag slot, then try again."] }
        end
        Theme.FitText(panel.status, texts, WIDTH - 2 * PAD)
        QueueMailPanel:Refresh()
    end)

    if not started then
        Theme.FitText(panel.status, { L.Format("Can't fill the mail: %s", why or L["the mailbox is busy"]), why or "" },
            WIDTH - 2 * PAD)
        return
    end

    Theme.FitText(panel.status, { L.Format("Filling a mail for %s...", short), L["Filling..."] }, WIDTH - 2 * PAD)
    for _, other in ipairs(panel.rows) do other.send:SetEnabledState(false) end
end

--- Take the next batch out of the mail for the queue.
function QueueMailPanel:TakeFor(row)
    local panel = self.frame

    local started, why = ns.QueueMail:TakeBatch(function(units, stacks)
        if not panel then return end
        local texts = stacks > 0
            and { stacks == 1 and L.Format("Took %d (%d stack). Craft, then take the next batch.", units, stacks)
                    or L.Format("Took %d (%d stacks). Craft, then take the next batch.", units, stacks),
                L.Format("Took %d.", units) }
            or { L["Took nothing. Your bags are full, or the mail wouldn't give it up."], L["Took nothing."] }
        Theme.FitText(panel.status, texts, WIDTH - 2 * PAD)
        QueueMailPanel:Refresh()
    end)

    if not started then
        Theme.FitText(panel.status, { L.Format("Can't take it: %s", why or L["the mailbox is busy"]), why or "" },
            WIDTH - 2 * PAD)
        return
    end

    Theme.FitText(panel.status, { L["Taking the next batch..."], L["Taking..."] }, WIDTH - 2 * PAD)
    for _, other in ipairs(panel.rows) do other.send:SetEnabledState(false) end
end

--- A mail to one of your characters went. Logic/QueueMail.lua calls this.
function QueueMailPanel:OnSent(toKey)
    local panel = self.frame
    if panel then
        local short = ns.Recipes.GetShortCharacterName
            and ns.Recipes:GetShortCharacterName(toKey) or ns.Recipes:GetCharacterName(toKey)
        Theme.FitText(panel.status, { L.Format("Sent to %s.", short), L["Sent."] }, WIDTH - 2 * PAD)
    end
    self:Refresh()
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local function Soon(fn)
    if C_Timer and C_Timer.After then C_Timer.After(0.6, fn) else fn() end
end

ns.RegisterEvent(QueueMailPanel, "MAIL_SHOW", function()
    QueueMailPanel.dismissed = false
    QueueMailPanel.anchoredTo = nil
    if QueueMailPanel.frame then QueueMailPanel.frame.status:SetText("") end
    -- A moment for the inbox to be read, so what is waiting there counts.
    Soon(function() QueueMailPanel:Refresh() end)
end)

-- A mail to someone who is not one of your characters (a disenchanter on
-- another account) is not written down by Logic/QueueMail.lua, so the panel
-- says it went itself.
ns.RegisterEvent(QueueMailPanel, "MAIL_SEND_SUCCESS", function()
    local panel, filled = QueueMailPanel.frame, QueueMailPanel.lastFilled
    QueueMailPanel.lastFilled = nil
    if panel and panel:IsShown() and filled and not filled.to then
        Theme.FitText(panel.status, { L.Format("Sent to %s.", ShortName(filled)), L["Sent."] }, WIDTH - 2 * PAD)
        Soon(function() QueueMailPanel:Refresh() end)
    end
end)

-- The inbox fills in after the mailbox opens, and changes as mail is taken:
-- what Take next batch offers comes from it. Only with that setting on.
ns.RegisterEvent(QueueMailPanel, "MAIL_INBOX_UPDATE", function()
    if ns.Config:Get("mailBatchTake") ~= true or ns.QueueMail.taking or QueueMailPanel.inboxSoon then return end
    QueueMailPanel.inboxSoon = true
    Soon(function()
        QueueMailPanel.inboxSoon = false
        QueueMailPanel:Refresh()
    end)
end)

ns.RegisterEvent(QueueMailPanel, "MAIL_CLOSED", function()
    QueueMailPanel.coveredByButler = false
    if QueueMailPanel.frame then QueueMailPanel.frame:Hide() end
end)

-- Items going into a mail and coming out of the bags change what is left.
ns.RegisterEvent(QueueMailPanel, "BAG_UPDATE_DELAYED", function()
    if QueueMailPanel.frame and QueueMailPanel.frame:IsShown()
        and not ns.QueueMail.filling and not ns.QueueMail.taking then
        QueueMailPanel:Refresh()
    end
end)
