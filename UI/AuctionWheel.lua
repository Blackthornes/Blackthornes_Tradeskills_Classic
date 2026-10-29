-- The mouse wheel at the auction house (a player asked, the owner said
-- build it, 2026-10-16). With "Mouse Wheel" ticked (Settings > Auction
-- house, `mouseWheelListing`, off unless ticked, never rename it), while
-- the drawer is up, wheel up does what List Next does and wheel down what
-- Cancel next does. When the drawer goes, the wheel is the player's again.
--
-- How: the game asks for a real click or key press for each listing and
-- each cancel. A wheel turn bound to a button is one, so two named buttons
-- (never shown, never take the mouse) get the wheel through override
-- bindings, held by our own owner frame only while the drawer shows. A list
-- under the mouse still takes the wheel first, so scrolling still works.
-- Bindings can't change in a fight: the change waits for its end.

local _, ns = ...

local AuctionWheel = ns.NewModule("AuctionWheel")

-- A flick of the wheel sends several notches at once: one action this far
-- apart, so a flick lists one stack, not five.
AuctionWheel.GAP = 0.35

AuctionWheel.LIST_BUTTON = "BlackthornesTSWheelList"
AuctionWheel.CANCEL_BUTTON = "BlackthornesTSWheelCancel"

local function Now()
    return type(GetTime) == "function" and GetTime() or 0
end

local function InFight()
    return type(InCombatLockdown) == "function" and InCombatLockdown() == true
end

--- Whether the setting is on.
function AuctionWheel:IsOn()
    return ns.Config ~= nil and ns.Config:Get("mouseWheelListing") == true
end

--- Whether the wheel should be ours right now.
function AuctionWheel:Wanted()
    if not self:IsOn() then return false end
    local panel = ns.PostPanel
    return panel ~= nil and panel.IsShown ~= nil and panel:IsShown() == true
end

-- A notch too soon after the last one does nothing.
function AuctionWheel:Ready()
    local now = Now()
    if self.lastAt and now - self.lastAt < self.GAP then return false end
    self.lastAt = now
    return true
end

--- Wheel up: the next stack on Sell, as List Next.
function AuctionWheel:List()
    if not self:Wanted() then return false end
    -- Era: while the last listing goes in, a notch does nothing, so rolling
    -- the wheel lists the next one as soon as it is ready.
    local Posting = ns.Posting
    if Posting and Posting.Settling and Posting:Settling() then return false end
    if Posting and Posting.CheckingAll and Posting:CheckingAll() then return false end
    if not self:Ready() then return false end
    local panel = ns.PostPanel
    -- Another view showing: Sell's lines read fresh rather than as last drawn.
    if panel.view ~= nil and panel.view ~= "sell" then panel.shownLines = nil end
    panel:ListNext()
    return true
end

--- Wheel down: the undercut auction with the most money under, as Cancel next.
function AuctionWheel:Cancel()
    if not self:Wanted() or not self:Ready() then return false end
    if not (ns.MyAuctions and ns.MyAuctions.CancelNext) then return false end
    ns.MyAuctions:CancelNext()
    return true
end

local function MakeButton(name, onClick)
    local button = CreateFrame("Button", name, UIParent)
    button:SetSize(1, 1)
    button:SetAlpha(0)
    button:EnableMouse(false)
    button:RegisterForClicks("AnyUp", "AnyDown")
    -- A binding clicks on the press and the release: act on one only.
    button:SetScript("OnClick", function(_, _, down)
        if down == false then return end
        onClick()
    end)
    return button
end

function AuctionWheel:Build()
    if self.owner then return end
    self.owner = CreateFrame("Frame", nil, UIParent)
    self.listButton = MakeButton(self.LIST_BUTTON, function() AuctionWheel:List() end)
    self.cancelButton = MakeButton(self.CANCEL_BUTTON, function() AuctionWheel:Cancel() end)
end

--- Take the wheel or give it back, to match the setting and the drawer.
function AuctionWheel:Update()
    local want = self:Wanted()
    if want == (self.bound == true) then return end

    if InFight() then
        self.waiting = true
        return
    end
    self.waiting = false

    self:Build()
    if want then
        if type(SetOverrideBindingClick) ~= "function" then return end
        pcall(SetOverrideBindingClick, self.owner, true, "MOUSEWHEELUP", self.LIST_BUTTON, "LeftButton")
        pcall(SetOverrideBindingClick, self.owner, true, "MOUSEWHEELDOWN", self.CANCEL_BUTTON, "LeftButton")
        self.bound = true
    else
        if type(ClearOverrideBindings) == "function" then pcall(ClearOverrideBindings, self.owner) end
        self.bound = false
    end
end

--- Follow the drawer: called once it is built.
function AuctionWheel:Watch(frame)
    if not frame or self.watching == frame then return end
    self.watching = frame
    frame:HookScript("OnShow", function() AuctionWheel:Update() end)
    frame:HookScript("OnHide", function() AuctionWheel:Update() end)
    self:Update()
end

if ns.RegisterEvent then
    ns.RegisterEvent(AuctionWheel, "PLAYER_REGEN_ENABLED", function()
        if AuctionWheel.waiting then AuctionWheel:Update() end
    end)
end
