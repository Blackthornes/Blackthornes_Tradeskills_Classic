-- Blackthornes Tradeskills -- UI/AuctionsView.lua
-- The auction house drawer's Auctions view (a player asked, the owner
-- agreeing 2026-10-14, from a mockup): every auction you have up, the
-- undercut ones first with a red edge and a Cancel button each, then the
-- ones nobody is under, then those no recent scan can judge, then your other
-- characters' as last seen. Logic/MyAuctions.lua works it out; this draws it
-- inside UI/PostPanel.lua's drawer.
--
-- Cancelling is one auction a click, as the game asks: each row's Cancel, or
-- Cancel next at the foot for the undercut auction with the most money under.

local _, ns = ...

local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local AuctionsView = ns.NewModule("AuctionsView")

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local ROW_HEIGHT = 36
local ICON_SIZE = 24

-- The Cancel button, wide enough for its word in either language.
local CANCEL_WIDTH = 58
do
    local measure = Theme and Theme.MeasureText
    if type(measure) == "function" then
        for _, word in ipairs({ L["Cancel"], L["Cancelling"] }) do
            local ok, width = pcall(measure, "small", word)
            if ok and type(width) == "number" then CANCEL_WIDTH = math.max(CANCEL_WIDTH, width + 12) end
        end
    end
end
local RIGHT_INSET = 8 + CANCEL_WIDTH + 8

local function Money(copper)
    return Util.FormatMoney(copper or 0, { noColor = true, short = true })
end

local function Colored(color, text)
    local hex = ns.COLORS and ns.COLORS[color]
    if not hex then return text end
    return ("|c%s%s|r"):format(hex, text)
end

local function CharacterName(who)
    local Recipes = ns.Recipes
    if Recipes and Recipes.GetCharacterName then
        local ok, name = pcall(Recipes.GetCharacterName, Recipes, who)
        if ok and name then return name end
    end
    return tostring(who or "?")
end

--------------------------------------------------------------------------------
-- What each row says
--------------------------------------------------------------------------------

--- The detail line under the name, longest first: the row keeps the first
--- that fits, so nothing ends in "...".
function AuctionsView.DetailTexts(row)
    local each = L.Format("%d @ %s", row.quantity or 1, Money(row.unit))
    local ends = row.left and L.Format("ends in %s", Util.FormatAge(row.left)) or nil
    local texts = {}

    local function Add(...)
        local parts = {}
        for i = 1, select("#", ...) do
            local part = select(i, ...)
            if part and part ~= "" then parts[#parts + 1] = part end
        end
        texts[#texts + 1] = table.concat(parts, "  ·  ")
    end

    local who = row.alt and CharacterName(row.who) or nil

    if row.state == "undercut" then
        local cheapest = L.Format("cheapest %s", Colored("loss", Money(row.rival)))
        local under = Colored("loss", L.Format("%s under", Money(row.gap)))
        Add(who, each, cheapest, under, ends)
        Add(who, each, cheapest, under)
        Add(who, each, under)
    elseif row.state == "overcut" then
        local big = row.gap and L.Format("big stack %s", Money(row.gap)) or nil
        Add(who, each, big, ends)
        Add(who, each, big)
        Add(who, each)
    elseif row.state == "cheapest" then
        local next_ = row.rival and L.Format("next %s", Money(row.rival)) or L["only yours listed"]
        local place = AuctionsView.PlaceText(row)
        if place then
            Add(who, each, next_, place, ends)
            Add(who, each, next_, place)
            Add(who, each, place)
        end
        Add(who, each, next_, ends)
        Add(who, each, next_)
        Add(who, each)
    else
        local age = ns.Prices and ns.Prices.GetAge and ns.Prices:GetAge(row.itemID)
        local scanned = age and L.Format("scanned %s", Util.FormatAgeAgo(age)) or L["never scanned"]
        Add(who, each, scanned, ends)
        Add(who, each, scanned)
        Add(who, each)
    end
    if who then Add(each) end
    return texts
end

--- Where a cheapest auction stands in line, coloured, or nil when no
--- recent search has said.
function AuctionsView.PlaceText(row)
    if row.ahead then
        if row.ahead > 0 then return Colored("warn", L.Format("%d ahead of you", row.ahead)) end
        return Colored("profit", L["First in line"])
    end
    if row.more and row.more > 0 then return Colored("warn", L.Format("%d more at your price", row.more)) end
    return nil
end

--- A row with a Cancel button: undercut, or cheapest with others selling
--- first at its price.
function AuctionsView.Cancellable(row)
    if ns.MyAuctions and ns.MyAuctions.CanEverCancel and not ns.MyAuctions:CanEverCancel() then return false end
    return row.mine and not row.cancelling and (row.state == "undercut" or row.behind == true) or false
end

--- What sits at the row's right end: the state, beside Cancel when there is one.
function AuctionsView.BadgeText(row)
    if row.alt then return L["Log in to cancel"], "dim" end
    if row.cancelling then return L["Cancelling"], "warn" end
    if row.state == "cheapest" then return L["Cheapest"], row.behind and "warn" or "profit" end
    if row.state == "overcut" then return L["Overcut"], "profit" end
    if row.state == "unknown" then return L["Unknown"], "muted" end
    return nil
end

--- The deposit line under Cancel.
function AuctionsView.DepositText(row)
    local deposit, rough = ns.MyAuctions:Deposit(row)
    if not deposit then return nil end
    return rough and L.Format("deposit about %s", Money(deposit)) or L.Format("deposit %s", Money(deposit))
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function CreateRow(row)
    row.icon = Theme.CreateItemIcon(row, ICON_SIZE)
    row.icon:SetPoint("LEFT", 8, 0)

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("TOPLEFT", 8 + ICON_SIZE + 8, -4)
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -RIGHT_INSET, -4)

    row.detail = Theme.CreateLabel(row, "tiny", "muted")
    row.detail:SetPoint("TOPLEFT", 8 + ICON_SIZE + 8, -20)
    row.detail:SetPoint("TOPRIGHT", row, "TOPRIGHT", -RIGHT_INSET, -20)
    row.detail:SetWordWrap(false)

    -- A red edge on an undercut auction, so they read at a glance.
    row.redEdge = Theme.AccentStripe(row, 3)
    row.redEdge:SetColorTexture(Theme.Unpack("loss"))
    row.redEdge:Hide()

    row.cancel = Widgets.CreateButton(row, L["Cancel"], function()
        local data = row.data
        if not data then return end
        local ok, reason = ns.MyAuctions:Cancel(data)
        if not ok and reason then ns.Print(reason) end
        if ns.PostPanel then ns.PostPanel:Refresh() end
    end, { width = CANCEL_WIDTH, height = 18 })
    row.cancel:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -4)
    row.cancel:HookScript("OnEnter", function(self)
        local data = row.data
        if not data then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(L["Cancel this auction"])
        GameTooltip:AddLine(L["It comes back to you in the mail."], 1, 1, 1, true)
        if row.cancelReason then GameTooltip:AddLine(row.cancelReason, Theme.Unpack("loss")) end
        local deposit = ns.MyAuctions:Deposit(data)
        if deposit then
            GameTooltip:AddLine(L.Format("You lose the deposit, so listing it again costs about %s.",
                Util.FormatMoney(deposit, { noColor = true })), 0.7, 0.7, 0.7, true)
        end
        if ns.MyAuctions:GapSmallerThanDeposit(data) then
            GameTooltip:AddLine(L["Listing it again costs more than you'd gain."], Theme.Unpack("warn"))
        end
        GameTooltip:Show()
    end)
    row.cancel:HookScript("OnLeave", function() GameTooltip:Hide() end)

    row.deposit = Theme.CreateLabel(row, "tiny", "dim", "RIGHT")
    row.deposit:SetPoint("TOPRIGHT", row.cancel, "BOTTOMRIGHT", 0, -1)

    row.badge = Theme.CreateLabel(row, "tiny", "muted", "RIGHT")
    row.badge:SetPoint("RIGHT", row, "RIGHT", -8, 0)

    -- A heading row: the group's name in gold and a note at its right.
    row.heading = Theme.CreateLabel(row, "tiny", "accent")
    row.heading:SetPoint("BOTTOMLEFT", 8, 5)
    row.headingNote = Theme.CreateLabel(row, "tiny", "dim", "RIGHT")
    row.headingNote:SetPoint("BOTTOMRIGHT", -8, 5)
end

local function UpdateRow(row, entry)
    local isHeading = entry.heading ~= nil
    row.heading:SetShown(isHeading)
    row.headingNote:SetShown(isHeading)
    row.icon:SetShown(not isHeading)
    row.name:SetShown(not isHeading)
    row.detail:SetShown(not isHeading)

    if isHeading then
        row.heading:SetText(entry.heading)
        row.headingNote:SetText(entry.note or "")
        row.redEdge:Hide()
        row.cancel:Hide()
        row.deposit:Hide()
        row.badge:Hide()
        return
    end

    local undercut = AuctionsView.Cancellable(entry)
    row.redEdge:SetShown(entry.state == "undercut")
    row.cancel:SetShown(undercut)
    if undercut then
        local allowed, reason = ns.MyAuctions:CanCancel(entry)
        row.cancel:SetEnabledState(allowed)
        row.cancelReason = (not allowed) and reason or nil
    end

    local deposit = undercut and AuctionsView.DepositText(entry) or nil
    row.deposit:SetShown(deposit ~= nil)
    row.deposit:SetText(deposit or "")
    if deposit then
        row.deposit:SetTextColor(Theme.Unpack(ns.MyAuctions:GapSmallerThanDeposit(entry) and "warn" or "dim"))
    end

    -- An undercut row's red edge and Cancel say it all; a cheapest one with
    -- others ahead keeps its amber word beside Cancel.
    local badge, color = nil, nil
    if entry.state ~= "undercut" or not undercut then badge, color = AuctionsView.BadgeText(entry) end
    row.badge:SetShown(badge ~= nil)
    row.badge:ClearAllPoints()
    if badge and undercut then
        row.badge:SetPoint("RIGHT", row.cancel, "LEFT", -6, 0)
    else
        row.badge:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    end
    if badge then
        row.badge:SetText(badge)
        row.badge:SetTextColor(Theme.Unpack(color or "muted"))
    end

    -- The name and the line under it stop short of what sits at the right:
    -- the badge stands across both, the deposit beside the line under.
    local nameInset, detailInset = RIGHT_INSET, RIGHT_INSET
    if badge then
        local width = Theme.TextWidth(row.badge)
        local beside = undercut and (CANCEL_WIDTH + 14) or 0
        if width then nameInset = math.max(nameInset, math.ceil(width) + 16 + beside) end
        detailInset = nameInset
    end
    if deposit then
        local width = Theme.TextWidth(row.deposit)
        if width then detailInset = math.max(detailInset, math.ceil(width) + 16) end
    end
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -nameInset, -4)

    local label = (entry.link and entry.link:match("%[(.-)%]")) or Util.GetItemLabel(entry.itemID)
        or L["that item"]
    if Theme.SetRowName then Theme.SetRowName(row.name, label) else row.name:SetText(label) end
    Theme.SetItemIcon(row.icon, entry.itemID)
    local r, g, b = Util.GetItemQualityColor(entry.itemID)
    if r then row.name:SetTextColor(r, g, b) else row.name:SetTextColor(Theme.Unpack("text")) end

    -- A name that wraps pushes the line under it down, and the row grows
    -- by that line too.
    local wrapped = type(rawget(row.name, "rowNeed")) == "number"
    row.detail:ClearAllPoints()
    if wrapped then
        row.detail:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
        row.detail:SetPoint("TOPRIGHT", row.name, "BOTTOMRIGHT", nameInset - detailInset, -2)
        row.name.rowNeed = row.name.rowNeed + 14
    else
        row.detail:SetPoint("TOPLEFT", row, "TOPLEFT", 8 + ICON_SIZE + 8, -20)
        row.detail:SetPoint("TOPRIGHT", row, "TOPRIGHT", -detailInset, -20)
    end

    local okWidth, rowWidth = pcall(row.GetWidth, row)
    local room = okWidth and type(rowWidth) == "number" and rowWidth > 0
        and rowWidth - (8 + ICON_SIZE + 8) - detailInset or nil
    Theme.FitText(row.detail, AuctionsView.DetailTexts(entry), room)
end

local function ShowTooltip(row, entry)
    if entry.heading then return end
    Widgets.ShowItemTooltip(row, "ANCHOR_LEFT", entry.itemID)
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine(L["Your price each"], Util.FormatMoney(entry.unit or 0, { noColor = true }),
        0.7, 0.7, 0.7, 1, 1, 1)
    if entry.rival then
        GameTooltip:AddDoubleLine(L["Cheapest not yours"], Util.FormatMoney(entry.rival, { noColor = true }),
            0.7, 0.7, 0.7, 1, 1, 1)
    end
    if entry.state == "undercut" and entry.gap then
        GameTooltip:AddDoubleLine(L["Under you by"], Util.FormatMoney(entry.gap, { noColor = true }),
            0.7, 0.7, 0.7, Theme.Unpack("loss"))
    end
    if entry.left then
        GameTooltip:AddDoubleLine(L["Ends in"], Util.FormatAge(entry.left), 0.7, 0.7, 0.7, 1, 1, 1)
    end
    if entry.state == "cheapest" and (entry.ahead or entry.more) then
        if entry.ahead and entry.ahead > 0 then
            GameTooltip:AddLine(L.Format("%d listings at your price will sell before yours.", entry.ahead),
                Theme.Unpack("warn"))
        elseif entry.ahead then
            GameTooltip:AddLine(L["Yours sells first at this price."], Theme.Unpack("profit"))
        elseif entry.more and entry.more > 0 then
            GameTooltip:AddLine(L.Format("%d more at your price", entry.more), Theme.Unpack("warn"))
        end
        if entry.placeAt then
            GameTooltip:AddLine(L.Format("Checked %s.", Util.FormatAgeAgo(math.max(0, time() - entry.placeAt))),
                0.7, 0.7, 0.7)
        end
    end
    if entry.state == "overcut" then
        GameTooltip:AddLine(L["Posted just under the big stack. The cheaper ones should sell first."], 0.7, 0.7, 0.7, true)
    end
    if entry.state == "unknown" then
        GameTooltip:AddLine(L["No recent scan. Scan to see if you were undercut."], 0.7, 0.7, 0.7, true)
    end
    if entry.alt then
        GameTooltip:AddLine(L.Format("On %s, as last seen. Log in there to cancel it.", CharacterName(entry.who)),
            0.7, 0.7, 0.7, true)
    end
    GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- The list
--------------------------------------------------------------------------------

--- The rows with their group headings, ready to draw.
function AuctionsView.Lay(rows)
    local out = {}
    local heads = {
        undercut = { L["UNDERCUT"], nil },
        cheapest = { L["CHEAPEST"], L["nobody under you"] },
        unknown = { L["NOT SCANNED LATELY"], L["scan to check"] },
    }
    local last
    for _, row in ipairs(rows) do
        local group = row.alt and "alt" or row.state
        if group ~= last then
            if group == "alt" then
                out[#out + 1] = { heading = L["ON YOUR OTHER CHARACTERS"], note = L["as last seen"] }
            else
                local head = heads[group] or heads.unknown
                out[#out + 1] = { heading = head[1], note = head[2] }
            end
            last = group
        end
        out[#out + 1] = row
    end
    return out
end

function AuctionsView:Build(body, frame, topAnchor, opts)
    if self.list then return end
    opts = opts or {}

    local list = Widgets.CreateScrollList(body, {
        rowHeight = ROW_HEIGHT,
        createRow = CreateRow,
        updateRow = UpdateRow,
        onEnter = ShowTooltip,
        onLeave = function() GameTooltip:Hide() end,
    })
    list:SetPoint("TOPLEFT", topAnchor, "BOTTOMLEFT", 0, -4)
    list:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, opts.bottom or 49)
    self.list = list

    local pad = opts.edge or 11
    local footMiddle = pad + (opts.footHeight or 34) / 2

    local nextWidth = 120
    if Theme.MeasureText then
        local ok, width = pcall(Theme.MeasureText, "small", L.Format("Cancel next (%d)", 88))
        if ok and type(width) == "number" then nextWidth = math.max(nextWidth, width + 20) end
    end
    local cancelNext = Widgets.CreateButton(body, L["Cancel next"], function()
        ns.MyAuctions:CancelNext()
        AuctionsView:Refresh(true)
    end, { width = nextWidth, height = 22, primary = true,
           tooltip = L["Cancels the auction undercut the most. It comes back in the mail."] })
    cancelNext:SetPoint("RIGHT", frame, "BOTTOMRIGHT", -(pad + 6), footMiddle)
    self.cancelNext = cancelNext

    -- Check Places: searches each of your auctions, to see who sells first.
    local checkWidth = 90
    if Theme.MeasureText then
        local ok, width = pcall(Theme.MeasureText, "small", L["Check Places"])
        if ok and type(width) == "number" then checkWidth = math.max(checkWidth, width + 20) end
    end
    local checkPlaces = Widgets.CreateButton(body, L["Check Places"], function()
        ns.MyAuctions:CheckPlaces()
        AuctionsView:Refresh(true)
    end, { width = checkWidth, height = 22,
           tooltip = L["Looks up each of your auctions to see how many sell before yours."] })
    checkPlaces:SetPoint("RIGHT", cancelNext, "LEFT", -6, 0)
    self.checkPlaces = checkPlaces

    local note = Theme.CreateLabel(body, "tiny", "muted")
    note:SetPoint("LEFT", frame, "BOTTOMLEFT", pad + 8, footMiddle)
    note:SetPoint("RIGHT", checkPlaces, "LEFT", -8, 0)
    note:SetWordWrap(true)
    note:SetText(L["One cancel per click. Items come back in the mail."])
    self.note = note

    local empty = Theme.CreateLabel(body, "small", "dim", "CENTER")
    empty:SetPoint("CENTER", list, "CENTER")
    empty:SetWidth(300)
    empty:SetWordWrap(true)
    self.empty = empty

    self.parts = { list, cancelNext, checkPlaces, note }
    self:SetShown(false)
end

function AuctionsView:SetShown(on)
    self.shown = on and true or false
    for _, part in ipairs(self.parts or {}) do part:SetShown(self.shown) end
    if self.empty and not self.shown then self.empty:Hide() end
    if self.shown then
        self.key = nil
        self.controls = nil
        self:PlaceControls()
    end
end

--- Only the buttons this client can use: on Era there is no Check Places,
--- and no Cancel at all once the game has turned a cancel down. The
--- undercut list stays either way.
function AuctionsView:PlaceControls()
    local MyAuctions = ns.MyAuctions
    local cancel = MyAuctions:CanEverCancel() and true or false
    local places = MyAuctions:CanEverCheckPlaces() and true or false
    local controls = (cancel and "c" or "") .. (places and "p" or "")
    if controls == self.controls then return end
    self.controls = controls

    self.cancelNext:SetShown(cancel)
    self.note:SetShown(cancel)
    self.checkPlaces:SetShown(places)
    self.checkPlaces:ClearAllPoints()
    if cancel then
        self.checkPlaces:SetPoint("RIGHT", self.cancelNext, "LEFT", -6, 0)
    else
        self.checkPlaces:SetPoint("RIGHT", self.cancelNext, "RIGHT", 0, 0)
    end
    self.note:SetPoint("RIGHT", places and self.checkPlaces or self.cancelNext, "LEFT", -8, 0)
    self.key = nil
end

--- Built again only when a read, a cancel or a scan moved, or a minute
--- passed (the time left on each row): the drawer refreshes every second.
function AuctionsView:Refresh(force)
    if not (self.list and self.shown) then return end

    local MyAuctions = ns.MyAuctions
    self:PlaceControls()
    -- Every tick: a scan starting or ending says whether it can run.
    local canCheck = (MyAuctions:CanCheckPlaces()) and true or false
    if canCheck ~= self.canCheck then
        self.canCheck = canCheck
        self.checkPlaces:SetEnabledState(canCheck)
    end

    local key = ("%d:%d:%d"):format(MyAuctions.version or 0, math.floor(time() / 60),
        ns.Prices and ns.Prices.changes or 0)
    if not force and key == self.key then return end
    self.key = key

    local rows, summary = MyAuctions:Rows()
    self.rows, self.summaryData = rows, summary
    self.list:SetData(AuctionsView.Lay(rows))

    self.empty:SetShown(#rows == 0)
    if #rows == 0 then
        self.empty:SetText(summary.read and L["You have no auctions up."]
            or L["Reading your auctions..."])
    end

    local next_ = 0
    for _, row in ipairs(rows) do
        if row.mine and row.state == "undercut" and not row.cancelling then next_ = next_ + 1 end
    end
    self.cancelNext:SetText(next_ > 0 and L.Format("Cancel next (%d)", next_) or L["Cancel next"])
    self.cancelNext:SetEnabledState(next_ > 0)
end

--- The drawer's summary line.
function AuctionsView:Summary()
    local summary = self.summaryData
    if not summary then return "" end
    local parts = { L.Format("%d up", summary.up) }
    if summary.undercut > 0 then parts[#parts + 1] = Colored("loss", L.Format("%d undercut", summary.undercut)) end
    if summary.worth > 0 then
        parts[#parts + 1] = L.Format("worth %s", Colored("accent", Money(summary.worth)))
    end
    if summary.alts > 0 then parts[#parts + 1] = L.Format("%d on other characters", summary.alts) end
    return table.concat(parts, "  ·  ")
end

--- The drawer's header title.
function AuctionsView:Title()
    local summary = self.summaryData
    if summary and summary.undercut > 0 then
        return L.Format("Your auctions (%d undercut)", summary.undercut), L["Your auctions"]
    end
    return L["Your auctions"]
end

--- How many are undercut, for the count on the switch.
function AuctionsView:UndercutCount()
    local MyAuctions = ns.MyAuctions
    if not MyAuctions then return 0 end
    local count = 0
    local ownUnits
    for _, auction in ipairs((ns.Auctions and ns.Auctions.live) or {}) do
        local cancelling = MyAuctions.cancelling and MyAuctions.cancelling[auction.auctionID]
        ownUnits = ownUnits or MyAuctions:OwnUnits()
        if not cancelling and MyAuctions:JudgeOwn(auction.itemID, auction.unit, ownUnits, auction.link) == "undercut" then
            count = count + 1
        end
    end
    return count
end
