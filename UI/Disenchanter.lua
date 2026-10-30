-- Blackthornes Tradeskills -- UI/Disenchanter.lua
-- The Disenchant button on the Deals and Profit tabs.
--
-- Addon code may not cast a spell, but the player's own click on a secure
-- action button may. So the tab's Disenchant button has a secure button laid
-- over it, set to cast Disenchant and aim it at one bag slot. It is the same
-- arrangement as UI/ProfessionOpener.lua, and it keeps the lessons learnt
-- there in game: the secure button is parented to UIParent and placed by
-- screen position, re-raised above the tab's button every frame, a whole
-- layer above it, fires on mouse release, and the button underneath stops
-- taking the mouse while it shows.
--
-- The spell is aimed through the template's own target-bag and target-slot
-- attributes, which it only uses while a spell is waiting for an item. A
-- macro ("/cast Disenchant" then "/use bag slot") would equip the item
-- instead whenever the cast did not start, and equipping binds it, so that
-- is deliberately not how this works.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Disenchanter = ns.NewModule("Disenchanter")

local Util = ns.Util

local DISENCHANT_SPELL = 13262

local CLICK_DIRECTION = "AnyUp"

local STRATA_ABOVE = {
    BACKGROUND = "LOW", LOW = "MEDIUM", MEDIUM = "HIGH", HIGH = "DIALOG",
    DIALOG = "FULLSCREEN", FULLSCREEN = "FULLSCREEN_DIALOG",
    FULLSCREEN_DIALOG = "TOOLTIP", TOOLTIP = "TOOLTIP",
}

local function InCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown() and true or false
end

--------------------------------------------------------------------------------
-- What there is to know
--------------------------------------------------------------------------------

--- The spell's name as this client writes it, or English as a fallback.
function Disenchanter:SpellName()
    if Util.HasFunction("C_Spell.GetSpellName") then
        local ok, name = pcall(C_Spell.GetSpellName, DISENCHANT_SPELL)
        if ok and type(name) == "string" and name ~= "" then return name end
    end

    if type(GetSpellInfo) == "function" then
        local ok, name = pcall(GetSpellInfo, DISENCHANT_SPELL)
        if ok and type(name) == "string" and name ~= "" then return name end
    end

    return "Disenchant"
end

--- Does this character know Disenchant? nil when the client will not say.
function Disenchanter:Knows()
    for _, name in ipairs({ "IsPlayerSpell", "IsSpellKnown" }) do
        local fn = _G[name]
        if type(fn) == "function" then
            local ok, known = pcall(fn, DISENCHANT_SPELL)
            if ok and known then return true end
        end
    end

    if Util.HasFunction("C_SpellBook.IsSpellKnown") then
        local ok, known = pcall(C_SpellBook.IsSpellKnown, DISENCHANT_SPELL)
        if ok and known then return true end
    end

    -- Every check that exists said no.
    if type(_G.IsPlayerSpell) == "function" or type(_G.IsSpellKnown) == "function" then
        return false
    end

    return nil
end

--- The first bag slot holding this item, or nil.
function Disenchanter:FindSlot(itemID)
    if not itemID or not Util.HasFunction("C_Container.GetContainerItemID") then return nil end

    for _, bag in ipairs(ns.Inventory:GetCarriedBags()) do
        local gotSlots, slots = pcall(C_Container.GetContainerNumSlots, bag)
        if gotSlots and type(slots) == "number" then
            for slot = 1, slots do
                local ok, found = pcall(C_Container.GetContainerItemID, bag, slot)
                if ok and found == itemID then return bag, slot end
            end
        end
    end

    return nil
end

--- What the tab's button should do for this item.
-- @return { ok = true } or { ok = false, why = "..." }
function Disenchanter:Check(itemID)
    if not itemID then return { ok = false, why = L["Pick an item from your bags."] } end
    if InCombat() then return { ok = false, why = L["Not during combat."] } end

    if self:Knows() == false then
        return { ok = false, why = L["This character does not know Disenchant."] }
    end

    if not ns.Disenchant:IsDisenchantable(itemID) then
        return { ok = false, why = L["That item cannot be disenchanted."] }
    end

    local bag, slot = self:FindSlot(itemID)
    if not bag then return { ok = false, why = L["That item is no longer in your bags."] } end

    return { ok = true, bag = bag, slot = slot }
end

--------------------------------------------------------------------------------
-- The secure button
--------------------------------------------------------------------------------

function Disenchanter:CreateOverlay()
    if self.overlay then return self.overlay end

    local overlay = CreateFrame("Button", "BlackthornesTSDisenchant", UIParent,
        "SecureActionButtonTemplate")
    overlay:Hide()
    overlay:EnableMouse(true)

    -- Drawn like the button under it, a primary one with a gold edge, so a
    -- misplaced one can be seen. It used a grey edge, so Disenchant lost its
    -- gold look exactly while it could be used.
    local Theme = ns.Theme
    overlay.background = Theme.Fill(overlay, "rowActive")
    Theme.Border(overlay, "accent", 0.55)
    if Theme.TopSheen then Theme.TopSheen(overlay) end
    -- The mouse finds this button rather than the one under it, so it is the
    -- one that glows gold under the mouse, as primary buttons do.
    if Theme.Halo then Theme.Halo(overlay, 5, 0) end
    overlay.label = Theme.CreateLabel(overlay, "small", "accent", "CENTER")
    overlay.label:SetPoint("LEFT", 4, 0)
    overlay.label:SetPoint("RIGHT", -4, 0)
    overlay.label:SetWordWrap(false)
    overlay.label:SetText(L["Disenchant"])

    overlay:SetScript("OnEnter", function(self)
        self.background:SetColorTexture(Theme.Unpack("rowHover"))
        Theme.SetBorderColor(self, "accent")
        if Theme.SetHalo then Theme.SetHalo(self, 0.32) end
        local anchor = Disenchanter.anchor
        if anchor and anchor.tooltipText then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(anchor.tooltipText, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)

    overlay:SetScript("OnLeave", function(self)
        self.background:SetColorTexture(Theme.Unpack("rowActive"))
        Theme.SetBorderColor(self, "accent", 0.55)
        if Theme.SetHalo then Theme.SetHalo(self, 0) end
        GameTooltip:Hide()
    end)

    -- Last look before the secure action runs. Bags can change between the
    -- button being set and the click, and the slot must still hold the item
    -- the button names, or nothing is cast at all. Attributes may be changed
    -- here: it runs before the action, and never in combat (the button is
    -- hidden then).
    overlay:SetScript("PreClick", function(button)
        Disenchanter.lastClick = GetTime()

        -- The key binding reaches this button in combat, when its
        -- attributes may not be written: the write would be refused and
        -- the click would run with whatever slot was aimed at last. The
        -- button is emptied as combat starts, so nothing runs here.
        if InCombat() then
            ns.Print(L["can't disenchant in combat"])
            return
        end

        local wanted = Disenchanter.itemID

        -- The key binding clicks this button even when no tab has set it.
        if not wanted then
            button:SetAttribute("type", nil)
            ns.Print(L["pick an item in your bags on the Disenchanting tab, or a craft you carry on the Profit tab, first"])
            return
        end

        local bag, slot = Disenchanter:FindSlot(wanted)

        if not bag then
            button:SetAttribute("type", nil)
            ns.Print(L["that item is no longer in your bags, so nothing was disenchanted"])
            return
        end

        button:SetAttribute("type", "spell")
        button:SetAttribute("target-bag", bag)
        button:SetAttribute("target-slot", slot)

        -- The disenchant log is told which item this cast is for, since the
        -- game does not say on Classic Era.
        local log = ns.DisenchantLog
        if log and log.Aim then pcall(log.Aim, log, wanted, "button") end

        -- The Queue tab's Disenchant next counts its marks off this.
        local anchor = Disenchanter.anchor
        if anchor and type(anchor.onSecureClick) == "function" then anchor.onSecureClick(wanted) end
    end)

    self.overlay = overlay
    return overlay
end

local function SetAnchorMouse(anchor, enabled)
    if anchor and anchor.EnableMouse then anchor:EnableMouse(enabled) end
end

--- Keep the secure button exactly over the tab's button, a layer above it.
function Disenchanter:Place()
    local overlay, anchor = self.overlay, self.anchor
    if not overlay or not anchor or InCombat() then return end

    local left, bottom = anchor:GetLeft(), anchor:GetBottom()
    if not left or not bottom then return end

    local scale = anchor:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local x, y = left * scale, bottom * scale
    local w, h = anchor:GetWidth() * scale, anchor:GetHeight() * scale

    local strata = STRATA_ABOVE[anchor:GetFrameStrata()] or "DIALOG"
    local level = anchor:GetFrameLevel() + 5
    if overlay:GetFrameStrata() ~= strata then overlay:SetFrameStrata(strata) end
    if overlay:GetFrameLevel() ~= level then overlay:SetFrameLevel(level) end

    local last = self.placed
    if last and last[1] == x and last[2] == y and last[3] == w and last[4] == h then return end

    overlay:ClearAllPoints()
    overlay:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
    overlay:SetSize(w, h)
    self.placed = { x, y, w, h }
end

--- Lay the secure button over `anchor`, set to disenchant this item.
-- @return true when armed
function Disenchanter:Arm(anchor, itemID, bag, slot)
    -- Only over a button the player can see. A tab redrawn while hidden took
    -- the one secure button from the tab on screen and aimed it at its own
    -- item, so the Disenchant button the player saw broke something else, and
    -- the button then stayed up after the window closed.
    if InCombat() or not anchor or not anchor:IsVisible() then return false end

    local overlay = self:CreateOverlay()

    if self.anchor ~= anchor then
        -- Two tabs have a Disenchant button. The one given up takes clicks
        -- again, or it stays dead if it is shown without being armed.
        SetAnchorMouse(self.anchor, true)
        self.anchor = anchor
        self.placed = nil

        if not anchor.btsDisenchantHooked then
            anchor.btsDisenchantHooked = true
            anchor:HookScript("OnUpdate", function(button)
                if Disenchanter.anchor == button and Disenchanter.overlay:IsShown() then
                    Disenchanter:Place()
                end
            end)
            anchor:HookScript("OnHide", function(button)
                if Disenchanter.anchor == button then Disenchanter:Disarm() end
            end)
        end
    end

    overlay:SetAttribute("type", "spell")
    overlay:SetAttribute("spell", DISENCHANT_SPELL)
    overlay:SetAttribute("target-bag", bag)
    overlay:SetAttribute("target-slot", slot)

    if self.direction ~= CLICK_DIRECTION then
        overlay:RegisterForClicks(CLICK_DIRECTION)
        overlay:SetAttribute("useOnKeyDown", false)
        self.direction = CLICK_DIRECTION
    end

    self.itemID = itemID
    -- The button underneath says what it does (Disenchant next names the
    -- item), and the secure one over it must say the same.
    overlay.label:SetText(type(anchor.overlayText) == "string" and anchor.overlayText or "Disenchant")
    self:Place()

    if anchor:IsVisible() then overlay:Show() end
    SetAnchorMouse(anchor, false)
    return true
end

--- Take the secure button away so clicks reach the tab's button again.
function Disenchanter:Disarm()
    SetAnchorMouse(self.anchor, true)
    self.itemID = nil
    if InCombat() then return false end

    if self.overlay then
        self.overlay:Hide()
        -- Nothing left aimed at a slot while it is not in use.
        self.overlay:SetAttribute("type", nil)
        self.overlay:SetAttribute("target-bag", nil)
        self.overlay:SetAttribute("target-slot", nil)
    end
    return true
end

function Disenchanter:IsArmed()
    return self.itemID ~= nil and self.overlay ~= nil and self.overlay:IsShown()
end

function Disenchanter:OnEnable()
    ns.RegisterEvent(self, "PLAYER_REGEN_DISABLED", function()
        local overlay = Disenchanter.overlay
        if overlay then
            overlay:Hide()
            -- Emptied while attributes may still be written, so the key
            -- binding casts nothing at a slot the fight has since refilled.
            overlay:SetAttribute("type", nil)
            overlay:SetAttribute("target-bag", nil)
            overlay:SetAttribute("target-slot", nil)
        end
        SetAnchorMouse(Disenchanter.anchor, true)
    end)

    -- Put the button back once combat ends. Nothing else re-armed it, so
    -- every click on Disenchant said it missed until the bags changed.
    ns.RegisterEvent(self, "PLAYER_REGEN_ENABLED", function()
        local anchor, itemID = Disenchanter.anchor, Disenchanter.itemID

        -- A refresh during combat disarms the button and forgets the item, so
        -- the tab is redrawn to set it up again from the selection.
        if not itemID then
            if ns.UI and ns.UI.RefreshActiveTab then ns.UI:RefreshActiveTab() end
            return
        end
        if not anchor or not anchor:IsVisible() then return end

        local bag, slot = Disenchanter:FindSlot(itemID)
        if bag and slot then Disenchanter:Arm(anchor, itemID, bag, slot) end
    end)
end

--------------------------------------------------------------------------------
-- /bts disenchant
--------------------------------------------------------------------------------

local function Describe()
    ns.Print(("Disenchant known: %s. Spell name: %s.")
        :format(tostring(Disenchanter:Knows()), Disenchanter:SpellName()))

    local overlay, anchor = Disenchanter.overlay, Disenchanter.anchor
    if not overlay or not Disenchanter.itemID then
        ns.Print("Disenchant button: not in use. Pick an item in your bags on the Disenchanting tab, or a craft you carry on the Profit tab.")
        return
    end

    ns.Print(("Disenchant button: set on %s, bag %s slot %s, %s.")
        :format(Util.GetItemLabel(Disenchanter.itemID),
            tostring(overlay:GetAttribute("target-bag")), tostring(overlay:GetAttribute("target-slot")),
            overlay:IsShown() and "showing" or "hidden"))

    if anchor then
        ns.Print(("layer %s %d over the tab button's %s %d; mouse over it: %s.")
            :format(overlay:GetFrameStrata(), overlay:GetFrameLevel(),
                anchor:GetFrameStrata(), anchor:GetFrameLevel(), tostring(overlay:IsMouseOver())))
    end

    ns.Print(Disenchanter.lastClick
        and ("last clicked %.1f seconds ago."):format(GetTime() - Disenchanter.lastClick)
        or "not clicked yet.")
end

ns.RegisterCommand("disenchant", L["check the Disenchant button"], Describe)
