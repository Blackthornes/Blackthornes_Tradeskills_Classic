-- Blackthornes Tradeskills -- UI/SellMarked.lua
-- The vendor window's Sell marked button (a player's request, 2026-10-07).
--
-- It sells what the craft queue made on Vendor (Logic/QueueActions.lua), and
-- nothing else: never an item the player looted, bought or wears, never blue
-- or better, never a stack bigger than what the queue made of it. It is
-- never automatic: one click, and no more than 12 sales a visit, because the
-- vendor's buyback keeps the last 12 and every sale stays undoable.
--
-- Selling is using a bag item with a vendor open, and the Warcraft Wiki marks
-- C_Container.UseContainerItem as protected on current retail. So the button
-- is a secure one, and each click of the player's sells one stack through a
-- "/use bag slot" line. Not the template's "item" type: that equips gear
-- instead of using it, and equipping binds. The line is only set while the
-- vendor is open, and checked again just before the click runs, since a
-- "/use" away from a vendor would equip the item too.
--
-- Whether Forever lets addon code sell is not known. There is no Test
-- button (the owner, 2026-10-23): after the first click sells a stack, the
-- next marked stack is sold from addon code and what happened is kept
-- (`SellMarked:QuietTest`). If it worked, one click sells every marked item
-- (up to 12) instead of one. /bts selltest still runs the old check, on the
-- cheapest grey item.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local SellMarked = ns.NewModule("SellMarked")

local Util = ns.Util

local BUTTON_WIDTH = 150
local BUTTON_PAD = 12
local SELL_GAP = 0.3
-- How long after the first click's sale the quiet check waits.
SellMarked.QUIET_WAIT = 1

local function InCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown() and true or false
end

local function MerchantOpen()
    if not (ns.Vendor and ns.Vendor.isMerchantOpen) then return false end
    local frame = _G.MerchantFrame
    return not frame or not frame.IsShown or frame:IsShown() == true
end

--- What the selling test found: "works", "blocked", or nil when not run.
function SellMarked:TestResult()
    local test = ns.db and ns.db.sellTest
    return type(test) == "table" and test.result or nil, test and test.at
end

--- Sell from addon code in one go, rather than a click a stack?
function SellMarked:CanSellAll()
    return self:TestResult() == "works" and Util.HasFunction("C_Container.UseContainerItem")
end

--- How many more this visit may sell.
function SellMarked:Room()
    return math.max(0, ns.QueueActions.SELL_PER_VISIT - (self.soldThisVisit or 0))
end

--------------------------------------------------------------------------------
-- The button
--------------------------------------------------------------------------------

function SellMarked:Create()
    if self.button then return self.button end

    local Theme = ns.Theme
    local button
    if ns.Plaque then
        -- The gold plaque, as the house's other buttons out on the screen
        -- (UI/Plaque.lua, 2026-10-29): what a click does, and under it how
        -- many stacks wait. Still the same secure button underneath.
        button = ns.Plaque.Create(UIParent, { name = "BlackthornesTSSellMarked",
            template = "SecureActionButtonTemplate", minWidth = BUTTON_WIDTH })
        button:SetIcon("Interface\\Icons\\INV_Misc_Coin_02")
        button.label = button.first
        button.isPlaque = true
    else
        button = CreateFrame("Button", "BlackthornesTSSellMarked", UIParent, "SecureActionButtonTemplate")
        button:SetSize(BUTTON_WIDTH, 30)
        -- A raised metal button with a gold label, like Disenchant's.
        button.background = Theme.Fill(button, "rowActive")
        Theme.Border(button, "accent", 0.55)
        if Theme.TopSheen then Theme.TopSheen(button) end
        if Theme.Halo then Theme.Halo(button, 5, 0) end
        button.label = Theme.CreateLabel(button, "small", "accent", "CENTER")
        button.label:SetPoint("CENTER")
        button.label:SetWordWrap(false)
    end
    button:Hide()
    button:SetFrameStrata("FULLSCREEN_DIALOG")
    button:SetFrameLevel(100)
    button:RegisterForClicks("AnyUp")
    button:SetAttribute("useOnKeyDown", false)

    local enter, leave = button:GetScript("OnEnter"), button:GetScript("OnLeave")
    button:SetScript("OnEnter", function(frame)
        if enter then enter(frame) end
        if frame.background then
            frame.background:SetColorTexture(Theme.Unpack("rowHover"))
            Theme.SetBorderColor(frame, "accent")
            if Theme.SetHalo then Theme.SetHalo(frame, 0.32) end
        end
        if frame.tooltipText then
            GameTooltip:SetOwner(frame, "ANCHOR_TOP")
            GameTooltip:SetText(frame.tooltipText, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)

    button:SetScript("OnLeave", function(frame)
        if leave then leave(frame) end
        if frame.background then
            frame.background:SetColorTexture(Theme.Unpack("rowActive"))
            Theme.SetBorderColor(frame, "accent", 0.55)
            if Theme.SetHalo then Theme.SetHalo(frame, 0) end
        end
        GameTooltip:Hide()
    end)

    -- Last look before the secure action runs: the vendor must still be
    -- open and the slot must still hold a marked item, or nothing is used.
    button:SetScript("PreClick", function(frame)
        frame.sellAll = nil
        frame.pending = nil

        -- Hidden in combat, and attributes cannot be changed then anyway.
        if InCombat() then return end

        if not MerchantOpen() or SellMarked:Room() <= 0 then
            frame:SetAttribute("type", nil)
            return
        end

        if SellMarked:CanSellAll() then
            frame:SetAttribute("type", nil)
            frame.sellAll = true
            return
        end

        local itemID, bag, slot, _, count = ns.QueueActions:Next("vendor")
        if not itemID then
            frame:SetAttribute("type", nil)
            return
        end

        frame:SetAttribute("type", "macro")
        frame:SetAttribute("macrotext", ("/use %d %d"):format(bag, slot))
        frame.pending = { itemID = itemID, count = count or 1, bag = bag, slot = slot }
    end)

    button:SetScript("PostClick", function(frame)
        if rawget(frame, "sellAll") == true then
            frame.sellAll = nil
            SellMarked:SellAll()
            return
        end

        local pending = rawget(frame, "pending")
        frame.pending = nil
        -- Nothing is left aimed at a slot between clicks.
        if not InCombat() then
            frame:SetAttribute("type", nil)
            frame:SetAttribute("macrotext", nil)
        end

        -- Taken off the mark now, before the bag change lets
        -- QueueActions:Settle cut marks to what is left, so the one sale is
        -- not counted twice. A sale the game refused only loses the mark,
        -- which leaves the item alone rather than selling something else.
        if pending then
            SellMarked.soldThisVisit = (SellMarked.soldThisVisit or 0) + 1
            ns.QueueActions:Used(pending.itemID, pending.count)
            if SellMarked:TestResult() == nil then
                -- Once the click's own sale has settled.
                C_Timer.After(SellMarked.QUIET_WAIT, function() SellMarked:QuietTest(pending) end)
            end
        end
        SellMarked:Update()
    end)

    self.button = button
    return button
end

--- Sell every marked stack this visit has room for, from addon code. Only
--- once the selling test has shown the game allows it.
function SellMarked:SellAll()
    if self.selling then return end

    local slots = ns.QueueActions:Slots("vendor", self:Room())
    if #slots == 0 then return end

    self.selling = true
    local index = 0

    local function Step()
        index = index + 1
        local item = slots[index]
        if not item or not MerchantOpen() or SellMarked:Room() <= 0 then
            SellMarked.selling = false
            SellMarked:Update()
            return
        end

        -- The slot must still hold what it held when the list was made.
        local ok, id = pcall(C_Container.GetContainerItemID, item.bag, item.slot)
        if ok and id == item.itemID then
            local sold = pcall(C_Container.UseContainerItem, item.bag, item.slot)
            if sold then
                SellMarked.soldThisVisit = (SellMarked.soldThisVisit or 0) + 1
                ns.QueueActions:Used(item.itemID, item.count)
            end
        end

        C_Timer.After(SELL_GAP, Step)
    end

    Step()
end

--- Show, hide and word the button for what is marked now.
function SellMarked:Update()
    local button = self.button

    local show = MerchantOpen() and not InCombat()
        and ns.Config:Get("sellMarkedButton") ~= false

    local list, total = ns.QueueActions:List("vendor")
    if show and #list == 0 then show = false end

    if not show then
        if button and not InCombat() then button:Hide() end
        return
    end

    button = self:Create()

    local room = self:Room()
    local itemID, _, _, _, count = ns.QueueActions:Next("vendor")

    local text
    if self.selling then
        text = L["Selling..."]
    elseif room <= 0 then
        text = L["Sold 12 this visit"]
    elseif not itemID then
        text = L["Sell marked (none in bags)"]
    elseif self:CanSellAll() then
        text = L.Format("Sell marked (%d)", math.min(total, room))
    else
        local name = Util.Uncolored(Util.GetItemLabel(itemID))
        name = name:match("^%[(.*)%]$") or name
        text = (count and count > 1) and L.Format("Sell %s x%d", name, count) or L.Format("Sell %s", name)
    end
    if rawget(button, "isPlaque") then
        -- The plaque says what a click does, and how many stacks wait under it.
        local first, second = text, nil
        if not self.selling and room > 0 and itemID then
            if self:CanSellAll() then first = L["Sell Marked"] end
            local stacks = math.min(total, room)
            second = L.Format(stacks == 1 and "%d stack to sell" or "%d stacks to sell", stacks)
        end
        button:SetLines(first, second)
        button:SetGlowing(not self.selling and room > 0 and itemID ~= nil)
    else
        button.label:SetText(text)
        local width = ns.Theme.TextWidth(button.label) or 0
        button:SetWidth(math.max(BUTTON_WIDTH, math.ceil(width + BUTTON_PAD * 2)))
    end

    local lines = { L.Format("Sells what your craft queue made on Vendor: %d marked.", total) }
    if room <= 0 then
        lines[#lines + 1] = L["That's 12 this visit, all still in buyback. Come back later to sell more."]
    elseif self:CanSellAll() then
        lines[#lines + 1] = L.Format("One click sells up to %d, and every sale can be bought back.", room)
    else
        lines[#lines + 1] = L["Each click sells one stack, up to 12 a visit. You can buy any of them back."]
    end
    lines[#lines + 1] = L["Never sells blue or better, anything worn, or anything the queue did not make."]
    button.tooltipText = table.concat(lines, "\n")

    -- Beside the Buy materials button when it is there, else on the vendor
    -- window's top edge.
    button:ClearAllPoints()
    local buy = ns.UI and ns.UI.merchantButton
    local merchantFrame = _G.MerchantFrame
    if buy and buy:IsShown() then
        button:SetPoint("BOTTOMRIGHT", buy, "BOTTOMLEFT", -6, 0)
    elseif merchantFrame then
        button:SetPoint("BOTTOMRIGHT", merchantFrame, "TOPRIGHT", -4, 4)
    else
        button:SetPoint("TOP", UIParent, "TOP", 0, -180)
    end

    button:Show()
end

--------------------------------------------------------------------------------
-- The selling test
--------------------------------------------------------------------------------

--- The cheapest grey item in the bags, and where it is.
local function CheapestGrey()
    local best
    for _, bag in ipairs(ns.Inventory:GetCarriedBags()) do
        local gotSlots, slots = pcall(C_Container.GetContainerNumSlots, bag)
        if gotSlots and type(slots) == "number" then
            for slot = 1, slots do
                local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
                if ok and type(info) == "table" and info.quality == 0 and info.itemID
                    and not info.isLocked then
                    local price = Util.GetVendorSellPrice(info.itemID) or 0
                    local worth = price * (tonumber(info.stackCount) or 1)
                    if price > 0 and (not best or worth < best.worth) then
                        best = { itemID = info.itemID, bag = bag, slot = slot, worth = worth }
                    end
                end
            end
        end
    end
    return best
end

--- Sell the cheapest grey from addon code and keep whether the game let it.
function SellMarked:Test()
    if not MerchantOpen() then
        ns.Print(L["open a vendor first, then run this again. It sells your cheapest grey item to see whether the game lets the addon sell."])
        return
    end
    if not Util.HasFunction("C_Container.UseContainerItem") then
        ns.Print(L["this version of the game has no C_Container.UseContainerItem."])
        return
    end

    local grey = CheapestGrey()
    if not grey then
        ns.Print(L["no grey item in your bags to test with. Carry one and try again."])
        return
    end

    local moneyBefore = GetMoney and GetMoney() or 0
    ns.Print(L.Format("trying to sell %s (%s) from addon code...", Util.GetItemLabel(grey.itemID),
        Util.FormatMoney(grey.worth)))

    local called, err = pcall(C_Container.UseContainerItem, grey.bag, grey.slot)

    C_Timer.After(1, function()
        local ok, still = pcall(C_Container.GetContainerItemID, grey.bag, grey.slot)
        local gone = ok and still ~= grey.itemID
        local gained = (GetMoney and GetMoney() or 0) > moneyBefore
        local works = called and gone and gained

        ns.db.sellTest = { at = time(), result = works and "works" or "blocked",
            error = (not called and err) and tostring(err):sub(1, 120) or nil }

        if works then
            ns.Print(L["|cff4fd18cselling from the addon works|r: Sell marked now sells every marked item in one click (up to 12 a visit)."])
        else
            ns.Print(L.Format("|cffe6614fselling from the addon is blocked|r (%s). Sell marked stays at one click a stack.",
                not called and L["the game refused the call"] or not gone and L["the item stayed"] or L["no gold came in"]))
        end
        SellMarked:Update()
    end)
end

--- After a click sold a stack, sell the next marked stack from addon code
--- and keep whether the game let it. Says nothing: the button's words
--- change when it works.
function SellMarked:QuietTest(clicked)
    if self:TestResult() ~= nil or self.selling or InCombat() then return end
    if not MerchantOpen() or self:Room() <= 0 then return end
    if not Util.HasFunction("C_Container.UseContainerItem") then return end
    local item
    for _, candidate in ipairs(ns.QueueActions:Slots("vendor", self:Room() + 1)) do
        local same = clicked and candidate.bag == clicked.bag and candidate.slot == clicked.slot
        local ok, id = pcall(C_Container.GetContainerItemID, candidate.bag, candidate.slot)
        if not same and ok and id == candidate.itemID then
            item = candidate
            break
        end
    end
    if not item then return end

    local moneyBefore = GetMoney and GetMoney() or 0
    local called, err = pcall(C_Container.UseContainerItem, item.bag, item.slot)

    C_Timer.After(1, function()
        local ok, still = pcall(C_Container.GetContainerItemID, item.bag, item.slot)
        local gone = ok and still ~= item.itemID
        local gained = (GetMoney and GetMoney() or 0) > moneyBefore
        if SellMarked:TestResult() ~= nil then return end
        ns.db.sellTest = { at = time(), result = (called and gone and gained) and "works" or "blocked",
            quiet = true, error = (not called and err) and tostring(err):sub(1, 120) or nil }
        if gone then
            SellMarked.soldThisVisit = (SellMarked.soldThisVisit or 0) + 1
            ns.QueueActions:Used(item.itemID, item.count)
        end
        SellMarked:Update()
    end)
end

--- One line for /bts probe.
function SellMarked:ProbeText()
    local result, at = self:TestResult()
    if result == "works" then
        return ("|c%sworks|r (tested %s)"):format(ns.COLORS.profit, Util.FormatAgeAgo and Util.FormatAgeAgo(time() - (at or time())) or "")
    elseif result == "blocked" then
        return ("|c%sblocked|r, one click a stack (tested %s)"):format(ns.COLORS.loss, Util.FormatAgeAgo and Util.FormatAgeAgo(time() - (at or time())) or "")
    end
    return ("|c%snot tested|r: the second stack Sell marked sells checks it, or /bts selltest"):format(ns.COLORS.warn)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function SellMarked:OnEnable()
    ns.RegisterEvent(self, "MERCHANT_SHOW", function()
        SellMarked.soldThisVisit = 0
        -- After the Buy materials button, which waits the same 0.2s.
        C_Timer.After(0.3, function() SellMarked:Update() end)
    end)

    ns.RegisterEvent(self, "MERCHANT_CLOSED", function()
        SellMarked.selling = false
        local button = SellMarked.button
        if button and not InCombat() then
            button:SetAttribute("type", nil)
            button:SetAttribute("macrotext", nil)
            button:Hide()
        end
    end)

    ns.RegisterEvent(self, "PLAYER_REGEN_DISABLED", function()
        if SellMarked.button then SellMarked.button:Hide() end
    end)

    ns.RegisterEvent(self, "PLAYER_REGEN_ENABLED", function() SellMarked:Update() end)
end

ns.RegisterCommand("selltest", L["at a vendor, sell your cheapest grey item to test whether the addon may sell"],
    function() SellMarked:Test() end)
