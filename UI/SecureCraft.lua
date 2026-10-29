-- Blackthornes Tradeskills -- UI/SecureCraft.lua
-- Lets our Craft buttons make an enchant on Era.
--
-- Era's Enchanting window makes an enchant with DoCraft, which the game
-- keeps for its own buttons: called from addon code, even on a click, it
-- shows "blocked from an action only available to the Blizzard UI". A
-- secure button's macro may press the window's own Create button, though.
-- So while the mouse is on one of our Craft buttons and its craft is an
-- enchant the open window shows, an invisible secure button lies over it.
-- Its PreClick picks the enchant in the window (Crafting:Start with
-- secureClick), then its macro presses Create, which makes it.
--
-- Placed by screen position on UIParent, never anchored to our button, so
-- our windows stay free to move and close in combat, and only touched out
-- of combat (see UI/ProfessionOpener.lua, which does the same to open a
-- profession window). Every other craft still goes through our button.

local _, ns = ...

local SecureCraft = ns.NewModule("SecureCraft")

local CREATE_MACRO = "/click CraftCreateButton"

local STRATA_ABOVE = {
    BACKGROUND = "LOW", LOW = "MEDIUM", MEDIUM = "HIGH", HIGH = "DIALOG",
    DIALOG = "FULLSCREEN", FULLSCREEN = "FULLSCREEN_DIALOG",
    FULLSCREEN_DIALOG = "TOOLTIP", TOOLTIP = "TOOLTIP",
}

local function InCombat()
    return type(InCombatLockdown) == "function" and InCombatLockdown() and true or false
end

local function Refresh()
    if ns.UI and ns.UI.RefreshActiveTab then ns.UI:RefreshActiveTab() end
    if ns.CraftPanel and ns.CraftPanel.RequestRefresh then ns.CraftPanel:RequestRefresh() end
end

--- Whether a craft needs the secure button: an Era enchant the open
--- Enchanting window shows, with its Create button there to press.
function SecureCraft:Needed(recipeID)
    local era = ns.Crafting and ns.Crafting.EraWindows and ns.Crafting.EraWindows()
    if not era or not recipeID then return false end
    local ok, one = pcall(era.MakesOneAtATime, era, recipeID)
    if not (ok and one) then return false end
    local create = _G.CraftCreateButton
    return create ~= nil and create.IsVisible ~= nil and create:IsVisible() and true or false
end

function SecureCraft:CreateOverlay()
    if self.overlay then return self.overlay end

    local overlay = CreateFrame("Button", "BlackthornesTSSecureCraft", UIParent,
        "SecureActionButtonTemplate")
    overlay:Hide()
    overlay:EnableMouse(true)
    -- On release only, as the profession opener found it must be.
    overlay:RegisterForClicks("AnyUp")
    overlay:SetAttribute("useOnKeyDown", false)
    overlay:SetAttribute("type", "macro")
    overlay:SetAttribute("macrotext", "")

    -- Invisible: our own button underneath still shows its hover and
    -- tooltip, played here since the mouse is on this one.
    overlay:SetScript("OnEnter", function()
        local anchor = SecureCraft.anchor
        local onEnter = anchor and anchor:GetScript("OnEnter")
        if onEnter then pcall(onEnter, anchor) end
    end)
    overlay:SetScript("OnLeave", function()
        local anchor = SecureCraft.anchor
        local onLeave = anchor and anchor:GetScript("OnLeave")
        if onLeave then pcall(onLeave, anchor) end
        SecureCraft:Disarm()
    end)

    -- Runs before the macro: pick the enchant, or empty the macro so a
    -- click that can't craft presses nothing.
    overlay:SetScript("PreClick", function(button)
        if InCombat() then return end
        local macro = ""
        local ok, started = pcall(SecureCraft.OnClicked, SecureCraft)
        if ok and started then macro = CREATE_MACRO end
        button:SetAttribute("macrotext", macro)
    end)
    overlay:SetScript("PostClick", function()
        Refresh()
    end)

    self.overlay = overlay
    return overlay
end

--- The click: Stop a craft under way, or start the one under the mouse.
-- @return true when the window's Create button should be pressed
function SecureCraft:OnClicked()
    local crafting = ns.Crafting
    if crafting:IsBusy() then
        crafting:Stop()
        return false
    end
    local anchor = self.anchor
    if not anchor or anchor.disabled then return false end
    local recipeID, count = self.resolve and self.resolve()
    if not self:Needed(recipeID) then return false end
    return crafting:Start(recipeID, count, true) == true
end

--- Lay the secure button exactly over `anchor`.
function SecureCraft:Place(anchor)
    local overlay = self.overlay
    local left, bottom = anchor:GetLeft(), anchor:GetBottom()
    if not overlay or not left or not bottom then return false end

    local scale = anchor:GetEffectiveScale() / UIParent:GetEffectiveScale()
    overlay:SetFrameStrata(STRATA_ABOVE[anchor:GetFrameStrata()] or "DIALOG")
    overlay:SetFrameLevel(anchor:GetFrameLevel() + 5)
    overlay:ClearAllPoints()
    overlay:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left * scale, bottom * scale)
    overlay:SetSize(anchor:GetWidth() * scale, anchor:GetHeight() * scale)
    return true
end

--- The mouse came onto one of our Craft buttons: cover it when its craft
--- is an enchant.
function SecureCraft:Arm(anchor, resolve)
    if InCombat() or anchor.disabled then return end
    if self.overlay and self.overlay:IsShown() and self.anchor == anchor then return end
    if ns.Crafting:IsBusy() then return end

    local okResolve, recipeID = pcall(resolve)
    if not okResolve or not self:Needed(recipeID) then return end

    local overlay = self:CreateOverlay()
    self.anchor, self.resolve = anchor, resolve
    if not self:Place(anchor) then return end
    overlay:SetAttribute("macrotext", "")
    overlay:Show()
end

function SecureCraft:Disarm()
    if InCombat() then return end
    if self.overlay then self.overlay:Hide() end
    self.anchor, self.resolve = nil, nil
end

--- Watch one of our Craft buttons. `resolve()` gives the recipe ID and how
--- many to make, read again at the click.
function SecureCraft:Attach(button, resolve)
    if not button or button.btsSecureCraft then return end
    button.btsSecureCraft = true
    button:HookScript("OnEnter", function(self) SecureCraft:Arm(self, resolve) end)
    button:HookScript("OnHide", function(self)
        if SecureCraft.anchor == self then SecureCraft:Disarm() end
    end)
end

function SecureCraft:OnEnable()
    -- The last moment a secure frame may be hidden before combat locks it.
    ns.RegisterEvent(self, "PLAYER_REGEN_DISABLED", function()
        SecureCraft:Disarm()
    end)
    ns.RegisterEvent(self, "CRAFT_CLOSE", function()
        SecureCraft:Disarm()
    end)
end
