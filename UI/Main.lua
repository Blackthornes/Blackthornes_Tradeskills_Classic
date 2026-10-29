-- Blackthornes Tradeskills -- UI/Main.lua
-- The single window everything lives in, plus the minimap button that opens it.
--
-- Tabs register themselves here rather than being hardcoded, so each tab file
-- owns its own layout and this file only routes between them.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local UI = ns.NewModule("UI")

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

--- Widen the header's scan button to its label when the words need more
--- than its usual width (German runs longer), never narrower than that.
local SCAN_BUTTON_WIDTH = 120
local function FitScanButton(button)
    local width = button and button.label and Theme.TextWidth and Theme.TextWidth(button.label)
    if width then button:SetWidth(math.max(SCAN_BUTTON_WIDTH, math.ceil(width) + 24)) end
end

-- 1120 since 2026-10-05 (was 1060): the room went to the Queue tab's
-- materials list, whose headings sat tight against each other.
local WINDOW_WIDTH = 1120

-- The tabs hang below the window now (Titanforged, 2026-10-04), so it is
-- shorter by their row: its contents keep the height they had, and with the
-- tabs the whole stands no taller than before.
local WINDOW_HEIGHT = 548

-- The metal rim sits on the window's edge and reaches this far inward, with
-- room to spare, so everything inside is padded by the same amount.
local EDGE_PAD = 11

-- The tabs hanging below the window: how tall, and how far in from each
-- corner gem.
local TAB_HANG = 28
local TAB_INSET = 34

-- The strip of controls at the top of the sell list (UI/PostPanel.lua):
-- what is ready to sell, the scan's status, Post Crafted and Scan. As wide as
-- the inside of the sell list, which sets it in place.
local AUCTION_BAR_HEIGHT = 44
local AUCTION_BAR_PAD = 10
local AUCTION_BAR_WIDTH = 350

-- Where the words start: the sell list's fold gem sits on its rim, beside
-- the close gem, so they start just past the gold stripe.
local AUCTION_BAR_TEXT_LEFT = 10

-- The two buttons on the strip: quiet metal, one line high, as wide as
-- their words. The one solid gold button is List all, at the list's foot.
local AUCTION_BAR_BUTTON_HEIGHT = 22
local AUCTION_BAR_GAP = 6

UI.AUCTION_BAR_HEIGHT = AUCTION_BAR_HEIGHT
UI.AUCTION_BAR_WIDTH = AUCTION_BAR_WIDTH

--- A button as wide as the longest of its words, plus room for the bevel.
local function FitButtonWidth(words, least)
    local width = least
    local measure = Theme and Theme.MeasureText
    if type(measure) == "function" then
        for _, word in ipairs(words) do
            local ok, w = pcall(measure, "small", word)
            if ok and type(w) == "number" then width = math.max(width, w + 20) end
        end
    end
    return width
end

-- How big the window can be drawn, as a share of its normal size: dragged
-- by the grip below its bottom right corner, picked on the Settings tab or
-- typed with /bts size (a player's request, 2026-10-07: too big on a 4K
-- screen, and in the way of other windows on a 1080p one). Drawn smaller or
-- larger as a whole, so every tab keeps its layout and nothing is cut off.
local SCALE_MIN = 0.5
local SCALE_MAX = 1.5
UI.SIZES = {
    { key = "small", text = L["Small"], scale = 0.8 },
    { key = "normal", text = L["Normal"], scale = 1 },
    { key = "large", text = L["Large"], scale = 1.2 },
}

-- The grip hangs below the window's bottom right corner, right of the tabs
-- (which stop TAB_INSET short of the corner), so it covers nothing inside.
local GRIP_SIZE = 20

-- How long "Scan complete" stays on the bar before it goes back to idle.
local SCAN_DONE_HOLD = 5

-- How far the window sits off the screen corner while the auction house is
-- open. Small: the three panels together are wider than the screen, so every
-- unit of margin is a unit of overlap somewhere else.
local AUCTION_LAYOUT_INSET = 4

UI.tabs = {}
UI.tabOrder = {}

--------------------------------------------------------------------------------
-- Tab registration
--------------------------------------------------------------------------------

--- @param tab { key, text, order, build(container), refresh(), onShow() }
function UI:RegisterTab(tab)
    self.tabs[tab.key] = tab
    self.tabOrder[#self.tabOrder + 1] = tab

    table.sort(self.tabOrder, function(a, b)
        return (a.order or 99) < (b.order or 99)
    end)
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

function UI:Build()
    if self.window then return self.window end

    local window = CreateFrame("Frame", "BlackthornesTSWindow", UIParent)
    window:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    window:SetScale(self:GetWindowScale())
    window:SetPoint("CENTER")
    window:SetFrameStrata("HIGH")
    window:SetClampedToScreen(true)
    window:EnableMouse(true)

    -- Clicking the window brings it to the front of its strata. The sell list
    -- docked beside the auction house shares that strata, and without this
    -- whichever was created last stays on top forever -- which is how the sell
    -- list ended up sitting across this window's tab row.
    if window.SetToplevel then window:SetToplevel(true) end
    window:SetMovable(true)
    window:RegisterForDrag("LeftButton")
    window:Hide()

    Theme.Fill(window, "window")

    -- The house frame: the game's own window shape, a gold rim with corner
    -- gems, the anvil in a round portrait, the name on a plate and a red
    -- close gem (UI/Titanforged.lua).
    if ns.Titanforged then
        local trim = ns.Titanforged:Dress(window, {
            title = "Blackthornes Tradeskills",
            portrait = true,
            close = function() UI:Hide() end,
        })

        -- Kept on the screen whole: the portrait and plate reach out past
        -- the top left, and the tabs hang below.
        local left, right, top = ns.Titanforged.Reach(trim)
        if window.SetClampRectInsets then
            window:SetClampRectInsets(-left, right, top, -TAB_HANG)
        end
    end

    -- A soft gold glow round the outside, Farmer's neon edge: it flares as
    -- the window opens and settles to a faint light.
    Theme.Halo(window, 12, 0.14)

    -- The fold gem beside the close gem folds the window down to its plate
    -- (UI/FoldWindow.lua, a player asked, 2026-10-24).
    if ns.FoldWindow then
        ns.FoldWindow:Add(window, { onToggle = function(folded)
            if ns.PostPanel then ns.PostPanel:Reflow() end
            if not folded then UI:RefreshActiveTab() end
        end })
    end

    window:SetScript("OnDragStart", function(self)
        -- Still rising into place: land it first, or the opening would keep
        -- pulling the window back under the cursor.
        if ns.Motion then ns.Motion:Stop(self, "open", true) end
        self:StartMoving()
    end)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        UI:SavePosition()

        -- The sell list gives way to this window rather than overlapping it,
        -- so it needs to know where the window came to rest.
        if ns.PostPanel then ns.PostPanel:Reflow() end
    end)

    -- Escape closes it, like every other panel in the game.
    tinsert(UISpecialFrames, "BlackthornesTSWindow")

    self.window = window

    self:BuildHeader()
    self:BuildTabs()
    self:BuildSizeGrip()

    self:RestorePosition()

    return window
end

function UI:BuildHeader()
    local window = self.window

    -- The window's name is on the plate across the top edge and the close
    -- gem sits on the top right corner (UI/Titanforged.lua), so the header
    -- holds what the scan has done and the scan button, clear of the
    -- portrait on the left.
    local header = CreateFrame("Frame", nil, window)
    header:SetPoint("TOPLEFT", EDGE_PAD, -EDGE_PAD)
    header:SetPoint("TOPRIGHT", -EDGE_PAD, -EDGE_PAD)
    header:SetHeight(52)

    -- A gold rule under it, bright at the left and fading out to the right.
    local rule = header:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("BOTTOMLEFT")
    rule:SetPoint("BOTTOMRIGHT")
    rule:SetHeight(1)
    Theme.SetGradientAlpha(rule, "HORIZONTAL", "accent", 0.6, 0.05)

    local status = Theme.CreateLabel(header, "small", "muted")
    status:SetPoint("LEFT", header, "LEFT", 58, -6)
    self.statusLabel = status

    -- The installed version, small and faint under that line, so a player
    -- can see at a glance which one they run. The header is on every tab,
    -- Settings included.
    local version = Theme.CreateLabel(header, "tiny", "dim")
    version:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 58, 4)
    version:SetText(ns.VersionLabel())
    self.versionLabel = version

    -- Something for the scan button to sit beside, where the close button
    -- used to be: the gem is on the window's corner now.
    local close = CreateFrame("Frame", nil, header)
    close:SetSize(1, 24)
    close:SetPoint("TOPRIGHT", -8, -12)

    -- Scan.
    --
    -- The button stays clickable even when a scan is not currently possible:
    -- a greyed-out control that cannot say why is worse than one that tells
    -- you to open the auction house.
    local scanButton = Widgets.CreateButton(header, L["Scan auctions"], function()
        UI:TriggerScan()
    end, { width = SCAN_BUTTON_WIDTH, height = 24, primary = true })
    FitScanButton(scanButton)

    scanButton:SetPoint("TOPRIGHT", close, "TOPLEFT", -8, -1)
    self.scanButton = scanButton

    -- Inline explanation, so the reason appears in the window rather than only
    -- in the chat frame.
    local hint = Theme.CreateLabel(header, "small", "warn", "RIGHT")
    hint:SetPoint("TOPRIGHT", scanButton, "BOTTOMRIGHT", 0, -4)
    hint:SetWidth(260)
    self.scanHint = hint

    self.header = header

    local progress = Widgets.CreateProgressBar(window)
    progress:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
    progress:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
    progress:Hide()
    self.progressBar = progress
end

--- Start or cancel a scan, explaining itself when it cannot.
function UI:TriggerScan()
    -- A scan still waiting its turn can be called off too.
    local scanner = ns.Scanner
    if scanner.isScanning or scanner.scanQueued or scanner.browseQueued then
        ns.Scanner:CancelScan()
        self:UpdateHeader()
        return
    end

    local allowed, reason = ns.Scanner:CanFullScan()
    if not allowed then
        if self.scanHint then
            self.scanHint:SetText(reason or L["cannot scan right now"])
        end
        ns.Print(reason or L["cannot scan right now"])
        return
    end

    ns.Scanner:StartFullScan()
    self:UpdateHeader()
end

function UI:BuildTabs()
    local window = self.window

    -- Each tab as wide as its own name, within the width of the window.
    -- Twelve tabs of one width were too narrow for "Disenchanting" and
    -- "Vendor Flips", whose names ran into their neighbours.
    local stripWidth = WINDOW_WIDTH - 2 * TAB_INSET

    local definitions = {}
    for _, tab in ipairs(self.tabOrder) do
        definitions[#definitions + 1] = { key = tab.key, text = tab.text }
    end

    -- Hung below the window, as the game's own windows wear their tabs. The
    -- one showing reaches up over the rim and joins the window.
    local strip = Widgets.CreateTabStrip(window, definitions, function(key)
        UI:SelectTab(key)
    end, { width = stripWidth, hanging = true })
    strip:SetPoint("TOPLEFT", window, "BOTTOMLEFT", TAB_INSET, 0)
    self.tabStrip = strip

    local content = Theme.CreatePanel(window, "panel")
    content:SetPoint("TOPLEFT", self.header, "BOTTOMLEFT", 0, -4)
    content:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -EDGE_PAD, EDGE_PAD)
    Theme.Recess(content)
    self.content = content

    for _, tab in ipairs(self.tabOrder) do
        local container = CreateFrame("Frame", nil, content)
        container:SetPoint("TOPLEFT", 1, -1)
        container:SetPoint("BOTTOMRIGHT", -1, 1)
        container:Hide()

        tab.container = container

        if tab.build then
            tab.build(container)
        end
    end
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- Tabs that were folded into others (a player's idea, 2026-10-07). A saved
-- last tab, or a call, naming one of them opens where it went.
UI.MOVED_TABS = {
    enchanting = "profit",
    vendorflips = "deals",
    -- Posting is the drawer's Sell list now; a window left on the old Post
    -- tab opens on Profit.
    post = "profit",
}

function UI:SelectTab(key)
    key = UI.MOVED_TABS[key] or key
    local tab = self.tabs[key]
    if not tab then return end

    for _, other in ipairs(self.tabOrder) do
        if other.container then
            other.container:SetShown(other.key == key)
        end
    end

    self.activeTab = key
    self.tabStrip:Select(key)

    if ns.db then ns.db.lastTab = key end

    if tab.onShow then tab.onShow() end
    if tab.refresh then tab.refresh() end
end

function UI:UpdateHeader()
    if not self.statusLabel then return end

    local priceCount = ns.Prices:Count()
    local recipeCount = ns.Recipes:Count()

    -- A sweep stopped at the page limit counts as a scan here. On a big
    -- auction house every sweep stops there, and "never scanned" was wrong.
    local lastScan, capped = ns.Prices:GetLastScan()
    local scanText = L["never scanned"]
    if lastScan then
        local ago = Util.FormatAgeAgo(time() - lastScan)
        scanText = capped and L.Format("scanned %s (stopped at the page limit)", ago)
            or L.Format("scanned %s", ago)
    end

    self.statusLabel:SetText(L.Format("%s items priced  ·  %s recipes known  ·  %s",
        Util.Comma(priceCount), Util.Comma(recipeCount), scanText))

    -- The scan button stays live and explains itself rather than greying out
    -- into something that looks broken.
    local scanner = ns.Scanner
    if scanner.isScanning or scanner.scanQueued or scanner.browseQueued then
        -- A scan waiting its turn is cancelled by this button too, so it
        -- says so rather than offering to start one.
        self.scanButton:SetText(L["Cancel scan"])
        FitScanButton(self.scanButton)
        self.scanButton.tooltipText = L["Stop the running scan"]
        -- The progress ("scanning... 42%") lives here while a scan runs, and
        -- clearing it on this five-second tick made it blink out.
        if not scanner.isScanning then
            self.scanHint:SetText("|c" .. ns.COLORS.warn .. L["waiting to start..."] .. "|r")
        else
            -- The progress line starts with the same words ("scanning... 42%").
            local scanning = L["scanning..."]
            if (self.scanHint:GetText() or ""):sub(1, #scanning) ~= scanning then
                self.scanHint:SetText(scanning)
            end
        end
    else
        self.scanButton:SetText(L["Scan auctions"])
        FitScanButton(self.scanButton)

        local allowed, reason = ns.Scanner:CanFullScan()
        self.scanButton.tooltipText = allowed
            and L["Scan the whole auction house in one go"]
            or reason

        self.scanHint:SetText(allowed and "" or (reason or ""))
    end
end

function UI:SetScanProgress(fraction)
    if self.progressBar then
        self.progressBar:Show()
        self.progressBar:SetProgress(fraction)
    end

    -- The auction house bar reads the scanner's own state for its progress,
    -- so it only needs telling that something moved.
    self:RefreshAuctionStatus()

    if self.scanHint then
        self.scanHint:SetText(L.Format("scanning... %d%%", math.floor((fraction or 0) * 100)))
    end
end

--- @param result nil when the scan was cancelled or gave up; on a finished
--- scan, { items = how many prices it recorded }.
function UI:OnScanComplete(result)
    -- Fresh prices: the drawer's Auctions view judges undercuts again.
    if ns.MyAuctions then ns.MyAuctions.version = (ns.MyAuctions.version or 0) + 1 end

    if self.progressBar then self.progressBar:Hide() end
    if self.scanHint then self.scanHint:SetText("") end

    if result then
        self:CelebrateScan(result)
        -- Other addons that asked to hear about it (Prices:WatchScans).
        if ns.Prices and ns.Prices.ScanFinished then ns.Prices:ScanFinished(result) end

        -- A moment later, so its chime does not land on the scan's own.
        if ns.Disenchant and C_Timer and C_Timer.After then
            C_Timer.After(1.5, function() ns.Disenchant:AnnounceDeals() end)
        end
        -- Not while the flips are put away (UI/Tab_Deals.lua).
        if UI.DEALS_SHOW_FLIPS and ns.VendorFlips and C_Timer and C_Timer.After then
            C_Timer.After(3, function() ns.VendorFlips:AnnounceDeals() end)
        end
    end

    self:UpdateAuctionButton()
    self:UpdateHeader()
    self:RefreshActiveTab()
end

function UI:OnRecipesUpdated()
    ns.Cost:InvalidateIndex()
    self:UpdateHeader()
    self:RefreshActiveTab()

    -- The craft pane lists what the profession window is showing, and the
    -- cache it reads from fills in over several frames after that window opens.
    if ns.CraftPanel then ns.CraftPanel:RequestRefresh() end
end

--- What you have listed on the auction house has changed.
--
-- Kept apart from OnInventoryUpdated because nothing in the bags moved, and
-- because the craft pane needs telling. The pane ranks crafts by how many you
-- already hold and hides the ones at their limit, so a reading taken when the
-- auction house opened is no use to it if it is never told the number changed.
function UI:OnAuctionsUpdated()
    self:RefreshActiveTab()
    self:UpdateHeader()

    if ns.CraftPanel then ns.CraftPanel:RequestRefresh() end
end

function UI:OnInventoryUpdated()
    -- One build of the queue's costs and shopping list for the whole
    -- redraw (Queue:Keeping).
    if ns.Queue and ns.Queue.Keeping then
        ns.Queue:Keeping(self.RefreshActiveTab, self)
    else
        self:RefreshActiveTab()
    end

    -- Crafting something new changes what there is to list.
    if self.postButton and self.postButton:IsVisible() then
        self:UpdatePostButton()
    end

    -- And changes how many of each craft the materials still cover.
    if ns.CraftPanel then ns.CraftPanel:RequestRefresh() end
end

function UI:RefreshActiveTab()
    if not self.window or not self.window:IsShown() then return end

    local tab = self.tabs[self.activeTab]
    if tab and tab.refresh then tab.refresh() end
end

--------------------------------------------------------------------------------
-- Position
--------------------------------------------------------------------------------

--- Which remembered position applies right now.
--
-- Centred is the right place for this window when it is the only thing on
-- screen, and the wrong place the moment the auction house is open: it lands
-- on top of Blizzard's window and the sell list docked beside it. So there are
-- two positions. Dragging the window while the auction house is open moves
-- only the auction-house one, and the everyday position is left alone.
function UI:PositionKey()
    if ns.Scanner and ns.Scanner.isAuctionHouseOpen then
        return "auctionWindowPosition"
    end

    return "windowPosition"
end

function UI:SavePosition()
    if not ns.db or not self.window then return end

    local point, _, relativePoint, x, y = self.window:GetPoint()

    -- The offsets are in the window's own units, which change with its
    -- size, so the size they were taken at goes with them.
    ns.db[self:PositionKey()] = { point = point, relativePoint = relativePoint,
        x = x, y = y, scale = self.window:GetScale() }
end

--- @param key string|nil which slot to restore; defaults to the current state.
-- The auction house close handler passes its slot explicitly: Scanner clears
-- isAuctionHouseOpen on the same event, and which handler runs first is not
-- ours to decide.
function UI:RestorePosition(key)
    if not self.window then return end

    key = key or self:PositionKey()

    local position = ns.db and ns.db[key]

    -- Still rising into place from opening: land that first, or its last
    -- steps would put the window back where it was before this move.
    if ns.Motion then ns.Motion:Stop(self.window, "open", true) end

    self.window:ClearAllPoints()

    if position then
        -- Saved at another size (or before there were sizes, at 1): the same
        -- spot on the screen, in the units of the size it is now.
        local factor = UI.PositionFactor(position.scale, self.window:GetScale())
        self.window:SetPoint(position.point or "CENTER", UIParent,
            position.relativePoint or "CENTER", (position.x or 0) * factor, (position.y or 0) * factor)
    elseif key == "auctionWindowPosition" then
        -- Never dragged at the auction house before: the bottom right corner.
        -- The auction window owns the left of the screen and the sell list the
        -- strip beside it, so this is the largest clear space there is.
        -- Raised by the tabs hanging below it, so they stay on the screen.
        self.window:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT",
            -AUCTION_LAYOUT_INSET, AUCTION_LAYOUT_INSET + TAB_HANG)
    else
        self.window:SetPoint("CENTER")
    end
end

--- How much to multiply a saved offset by, taken at `saved` size and put
--- back at `now`.
function UI.PositionFactor(saved, now)
    saved = tonumber(saved) or 1
    now = tonumber(now) or 1
    if saved <= 0 or now <= 0 then return 1 end
    return saved / now
end

--------------------------------------------------------------------------------
-- Window size
--------------------------------------------------------------------------------

--- A size kept within bounds and to a whole percent.
function UI.ClampScale(value)
    value = tonumber(value)
    if not value or value ~= value then return 1 end

    value = math.max(SCALE_MIN, math.min(SCALE_MAX, value))
    return math.floor(value * 100 + 0.5) / 100
end

--- The largest size at which the whole window, its portrait, plate and
--- hanging tabs, still fits on the screen. The smallest size if it cannot
--- be measured, never anything larger than SCALE_MAX.
function UI.FitScale()
    local ok, width, height = pcall(function()
        return UIParent:GetWidth(), UIParent:GetHeight()
    end)
    if not ok or type(width) ~= "number" or type(height) ~= "number"
        or width <= 0 or height <= 0 then
        return SCALE_MAX
    end

    -- The portrait reaches 20 past the top left, the tabs TAB_HANG below.
    local fit = math.min(width / (WINDOW_WIDTH + 30), height / (WINDOW_HEIGHT + 20 + TAB_HANG + 10))
    return math.max(SCALE_MIN, math.min(SCALE_MAX, math.floor(fit * 100) / 100))
end

--- The size the window is drawn at: the saved one, kept on the screen.
function UI:GetWindowScale()
    local saved = ns.Config and ns.Config:Get("windowScale")
    return math.min(UI.ClampScale(saved or 1), UI.FitScale())
end

--- The name of a size, "Small (80%)", or "87%" for one dragged to.
function UI.ScaleText(scale)
    local percent = math.floor((tonumber(scale) or 1) * 100 + 0.5)
    for _, size in ipairs(UI.SIZES) do
        if math.floor(size.scale * 100 + 0.5) == percent then
            return ("%s (%d%%)"):format(size.text, percent)
        end
    end
    return ("%d%%"):format(percent)
end

--- Draw the window at `scale` (from a stored or typed value) with its top
--- left corner where it was, so it grows and shrinks toward the bottom
--- right, as it does from the grip.
function UI:ApplyScale(scale)
    local window = self.window
    if not window then return end

    scale = math.min(UI.ClampScale(scale or self:GetWindowScale()), UI.FitScale())

    local old = window:GetScale()
    if type(old) ~= "number" or old <= 0 then old = 1 end
    if math.abs(old - scale) < 0.001 then return end

    -- Still rising into place from opening: land it, or the last steps of
    -- the opening would put back the point it had at the old size.
    if ns.Motion then ns.Motion:Stop(window, "open", true) end

    local left, top = window:GetLeft(), window:GetTop()
    window:SetScale(scale)

    if type(left) == "number" and type(top) == "number" then
        window:ClearAllPoints()
        window:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * old / scale, top * old / scale)
        self:SavePosition()
    end

    if ns.PostPanel then ns.PostPanel:Reflow() end
end

--- Save a size and draw the window at it. Returns the size it ended up at.
function UI:SetWindowScale(value)
    local scale = UI.ClampScale(value)
    if ns.Config then ns.Config:Set("windowScale", scale) end
    self:ApplyScale(scale)

    -- The Settings tab shows the size; keep it in step when it is open.
    if self.activeTab == "settings" then self:RefreshActiveTab() end

    return math.min(scale, UI.FitScale())
end

--- The grip below the bottom right corner: drag it to make the window
--- bigger or smaller, right-click it for the normal size.
function UI:BuildSizeGrip()
    local window = self.window

    local grip = Theme.CreatePanel(window, "panel", "borderLit")
    grip:SetSize(GRIP_SIZE, GRIP_SIZE)
    grip:SetPoint("TOPRIGHT", window, "BOTTOMRIGHT", -6, -3)
    grip:SetFrameLevel((window:GetFrameLevel() or 0) + 20)
    grip:EnableMouse(true)
    Theme.TopSheen(grip)
    self.sizeGrip = grip

    -- Six gold dots in a stair down to the bottom right corner, the shape
    -- every resizable window in the game wears, drawn from plain colour so
    -- it needs no texture file.
    local dots = {}
    for row = 0, 2 do
        for column = 2 - row, 2 do
            local dot = grip:CreateTexture(nil, "ARTWORK")
            dot:SetSize(3, 3)
            dot:SetPoint("BOTTOMRIGHT", grip, "BOTTOMRIGHT", -3 - (2 - column) * 5, 3 + (2 - row) * 5)
            dot:SetColorTexture(Theme.Unpack("accent"))
            dots[#dots + 1] = dot
        end
    end

    local function Light(on)
        Theme.SetBorderColor(grip, on and "accent" or "borderLit")
        for _, dot in ipairs(dots) do
            dot:SetColorTexture(Theme.Unpack(on and "accentHi" or "accent"))
        end
    end

    local function Track(self)
        local cx, cy = GetCursorPosition()
        local uiScale = UIParent:GetEffectiveScale()
        if not cx or not uiScale or uiScale <= 0 then return end
        cx, cy = cx / uiScale, cy / uiScale

        -- Where the corner would be for the cursor to sit on the grip as it
        -- did when the drag began, then the size that puts it there: the
        -- width's and the height's answers averaged, so a drag in any
        -- direction off the diagonal still feels right.
        local width = cx - self.grabX - self.anchorLeft
        local height = self.anchorTop - (cy + self.grabY)
        local scale = UI.ClampScale((width / WINDOW_WIDTH + height / WINDOW_HEIGHT) / 2)
        scale = math.min(scale, self.fit)

        if math.abs(scale - (window:GetScale() or 1)) < 0.005 then return end

        window:SetScale(scale)
        window:ClearAllPoints()
        window:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", self.anchorLeft / scale, self.anchorTop / scale)

        if GameTooltip:IsOwned(self) then
            GameTooltip:SetText(UI.ScaleText(scale), Theme.Unpack("accentHi"))
            GameTooltip:Show()
        end
    end

    local function StopSizing(self)
        if not self.sizing then return end
        self.sizing = false
        self:SetScript("OnUpdate", nil)

        if ns.Config then ns.Config:Set("windowScale", UI.ClampScale(window:GetScale())) end
        UI:SavePosition()
        if ns.PostPanel then ns.PostPanel:Reflow() end
        if UI.activeTab == "settings" then UI:RefreshActiveTab() end
    end

    grip:SetScript("OnMouseDown", function(self, button)
        if button == "RightButton" then
            UI:SetWindowScale(1)
            return
        end
        if button ~= "LeftButton" then return end

        if ns.Motion then ns.Motion:Stop(window, "open", true) end

        local scale = window:GetScale() or 1
        local left, top = window:GetLeft(), window:GetTop()
        local cx, cy = GetCursorPosition()
        local uiScale = UIParent:GetEffectiveScale()
        if not (left and top and cx and uiScale and uiScale > 0) then return end

        -- All in the screen's units (UIParent's), which do not change as
        -- the window's own scale does.
        self.anchorLeft, self.anchorTop = left * scale, top * scale
        self.grabX = cx / uiScale - (self.anchorLeft + WINDOW_WIDTH * scale)
        self.grabY = (self.anchorTop - WINDOW_HEIGHT * scale) - cy / uiScale
        self.fit = UI.FitScale()

        window:ClearAllPoints()
        window:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)

        self.sizing = true
        self:SetScript("OnUpdate", Track)
    end)
    grip:SetScript("OnMouseUp", StopSizing)
    grip:SetScript("OnHide", StopSizing)

    grip:SetScript("OnEnter", function(self)
        Light(true)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(UI.ScaleText(window:GetScale()), Theme.Unpack("accentHi"))
        GameTooltip:AddLine(L["Drag to make the window bigger or smaller."], 1, 1, 1, true)
        GameTooltip:AddLine(L["Right-click to go back to the normal size."], 1, 1, 1, true)
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function(self)
        Light(false)
        GameTooltip:Hide()
    end)

    return grip
end

--- "small", "normal", "large", "80", "80%" or "0.8" as a size, or nil.
function UI.ParseSize(text)
    text = (text or ""):lower():gsub("%s", ""):gsub("%%$", "")
    if text == "" then return nil end

    for _, size in ipairs(UI.SIZES) do
        if size.key == text then return size.scale end
    end

    local number = tonumber(text)
    if not number or number <= 0 then return nil end

    -- 80 means 80%; 0.8 means the same.
    if number > 5 then number = number / 100 end
    return number
end

if ns.RegisterCommand then
    ns.RegisterCommand("size", L["how big the window is: /bts size [small|normal|large|50-150%]"], function(args)
        local scale = UI.ParseSize(args)
        if not scale then
            ns.Print(L.Format("the window is at %s. Change it with /bts size small, normal, large or a percent from %d%% to %d%%, or drag the corner below its bottom right.",
                UI.ScaleText(UI:GetWindowScale()), math.floor(SCALE_MIN * 100 + 0.5), math.floor(SCALE_MAX * 100 + 0.5)))
            return
        end

        local now = UI:SetWindowScale(scale)
        ns.Print(L.Format("window size: %s.", UI.ScaleText(now)))
    end)
end

--------------------------------------------------------------------------------
-- Show / hide
--------------------------------------------------------------------------------

function UI:Show()
    self:Build()

    local opening = not self.window:IsShown()
    self.window:Show()
    -- Asked for again while folded: open it full.
    if ns.FoldWindow then ns.FoldWindow:Unfold(self.window) end

    -- In front of the craft queue pane and the sell list, which share its
    -- strata: the window just asked for is the one wanted on top (a
    -- screenshot, 2026-10-04: the craft queue drawn across it).
    if self.window.Raise then self.window:Raise() end

    local last = ns.db and ns.db.lastTab
    last = last and (UI.MOVED_TABS[last] or last)
    if last and not self.tabs[last] then last = nil end
    self:SelectTab(self.activeTab or last or self.tabOrder[1].key)
    self:UpdateHeader()

    if ns.PostPanel then ns.PostPanel:Reflow() end

    -- Fades up into place with its glow flaring, as Farmer's windows open,
    -- and a light runs round the portrait. After the reflow, so it rises
    -- from wherever it is going to sit.
    if opening and ns.Motion then ns.Motion:Open(self.window) end
    if opening and ns.Titanforged then ns.Titanforged:Opened(self.window) end

    -- The Welcome card, the first time this character opens the window
    -- (UI/Welcome.lua, 2026-10-20).
    if opening and ns.WelcomeUI then pcall(ns.WelcomeUI.MaybeShow, ns.WelcomeUI) end
end

function UI:Hide()
    -- Closed mid-opening: drawn in full and back in its place for next time.
    if self.window and ns.Motion then ns.Motion:Settle(self.window) end
    if self.window then self.window:Hide() end

    -- Hidden, so the sell list can have its full height back.
    if ns.PostPanel then ns.PostPanel:Reflow() end
end

-- Names for Bindings.xml, shown under Options, Keybindings, AddOns (a player's
-- request, 2026-10-02). The Disenchant key clicks the same secure button the
-- Deals and Profit tabs put over their Disenchant buttons, so it
-- works while one of those tabs shows a picked item, as the button does.
_G.BINDING_HEADER_BLACKTHORNESTS = "Blackthornes Tradeskills"
_G.BINDING_NAME_BLACKTHORNESTS_TOGGLE = L["Open or close the window"]
_G["BINDING_NAME_CLICK BlackthornesTSDisenchant:LeftButton"] = L["Disenchant the picked item"]

function UI:Toggle()
    self:Build()

    if self.window:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

--------------------------------------------------------------------------------
-- Auction house attachment
--------------------------------------------------------------------------------

-- Candidate globals for Blizzard's auction window. Forever is a retail client,
-- so AuctionHouseFrame is expected, but the name is not worth assuming.
local AUCTION_FRAME_NAMES = { "AuctionHouseFrame", "AuctionFrame" }

--- Locate Blizzard's auction window, whatever it is called on this client.
function UI:FindAuctionFrame()
    for _, name in ipairs(AUCTION_FRAME_NAMES) do
        local frame = _G[name]

        -- Guard against a global that exists but is not a frame.
        if type(frame) == "table" and frame.GetObjectType then
            local ok = pcall(frame.GetObjectType, frame)
            if ok then return frame, name end
        end
    end
end

--- The strip of addon controls at the top of the sell list.
--
-- Scan and Post Crafted used to sit on a bar of their own on the auction
-- window's top edge, a second loose piece beside the sell list. The owner's
-- mockup (2026-10-13) put them in the sell list's header instead, so the
-- auction house has one Tradeskills drawer beside it: this strip is that
-- header, with what is ready to sell and the scan's status on the left and
-- the two buttons on the right. The sell list places it (PostPanel:PlaceBar).
function UI:GetAuctionBar()
    if self.auctionBar then return self.auctionBar end

    -- Inside the sell list, so it shows, hides, folds and layers with it.
    local parent = UIParent
    local panel = ns.PostPanel
    if panel and type(panel.Build) == "function" then
        local ok, frame = pcall(panel.Build, panel)
        if ok and frame then parent = frame end
    end

    -- Building the sell list asks for this bar for its header, so the bar
    -- may have been made just now, inside that call. That one is the
    -- header: a second would carry Scan and Post Crafted where nothing
    -- shows them.
    if self.auctionBar then return self.auctionBar end

    local bar = CreateFrame("Frame", "BlackthornesTSAuctionBar", parent)
    bar:SetSize(AUCTION_BAR_WIDTH, AUCTION_BAR_HEIGHT)

    -- Mouse-catching: a click meant for a button should never fall through
    -- the gaps onto whatever is behind the bar.
    bar:EnableMouse(true)
    bar:Hide()

    -- Drawn as the house title strip (UI/Collapse.lua's), so the sell list
    -- reads as one window with one header.
    Theme.Fill(bar, "header")
    Theme.TopSheen(bar, 0.07)
    Theme.AccentStripe(bar, 3)
    local rule = Theme.CreateDivider(bar, "borderLit")
    rule:SetPoint("BOTTOMLEFT")
    rule:SetPoint("BOTTOMRIGHT")

    local left = AUCTION_BAR_TEXT_LEFT

    -- What is ready to sell and what it is worth (PostPanel:Refresh).
    local title = Theme.CreateLabel(bar, "small", "accent")
    title:SetPoint("TOPLEFT", bar, "TOPLEFT", left, -8)
    title:SetWidth(AUCTION_BAR_WIDTH - left - AUCTION_BAR_PAD)
    title:SetWordWrap(false)
    title:SetText(L["Ready to sell"])
    bar.title = title

    -- One line under the name: when the last scan was, or what the running
    -- scan is doing. As wide as the bar until the buttons arrive and take
    -- their share (AttachPostButton), so it can be measured from the start.
    local status = Theme.CreateLabel(bar, "tiny", "muted")
    status:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    status:SetWidth(AUCTION_BAR_WIDTH - left - AUCTION_BAR_PAD)
    status:SetWordWrap(false)
    bar.status = status

    -- When the line had to be shortened to fit, the whole of it is a hover
    -- away.
    bar:SetScript("OnEnter", function(frame)
        if not frame.statusFull then return end
        GameTooltip:SetOwner(frame, "ANCHOR_BOTTOM")
        GameTooltip:SetText(frame.statusFull, 1, 1, 1, 1, true)
        GameTooltip:Show()
        frame.statusTip = true
    end)
    bar:SetScript("OnLeave", function(frame)
        if not frame.statusTip then return end
        frame.statusTip = nil
        GameTooltip:Hide()
    end)

    -- The scan's progress, along the bottom of the text column. Shown only
    -- while a scan runs, and for a moment after one finishes.
    local progress = Widgets.CreateProgressBar(bar)
    progress:SetHeight(4)
    progress:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", left, 7)
    progress:Hide()
    bar.progress = progress

    -- While there is nothing to measure yet (the scan is waiting its turn, or
    -- waiting for the quick scan to answer), a glint runs along the track so
    -- the bar still reads as busy.
    local glint = progress:CreateTexture(nil, "OVERLAY")
    glint:SetSize(28, 2)
    glint:SetColorTexture(1, 0.92, 0.65, 0.8)
    glint:Hide()
    bar.glint = glint

    -- A gold wash over the whole bar that fades out when a scan finishes.
    local flash = bar:CreateTexture(nil, "OVERLAY")
    flash:SetAllPoints()
    flash:SetColorTexture(Theme.Unpack("accent"))
    flash:SetBlendMode("ADD")
    flash:SetAlpha(0)
    bar.flash = flash

    local sinceRefresh, glintAt = 0, 0

    bar:SetScript("OnUpdate", function(frame, elapsed)
        if frame.flashLeft and frame.flashLeft > 0 then
            frame.flashLeft = math.max(0, frame.flashLeft - elapsed)
            flash:SetAlpha(0.35 * frame.flashLeft)
        end

        if glint:IsShown() then
            local span = math.max(1, progress:GetWidth() - glint:GetWidth() - 2)
            glintAt = (glintAt + elapsed * 90) % span
            glint:ClearAllPoints()
            glint:SetPoint("LEFT", progress, "LEFT", 1 + glintAt, 0)
        end

        -- The scanner is read a few times a second rather than every frame.
        -- The Scan button comes along too: a queued scan starts on its own
        -- turn, with no click to say the button should now read Cancel.
        sinceRefresh = sinceRefresh + elapsed
        if sinceRefresh >= 0.2 then
            sinceRefresh = 0
            UI:UpdateAuctionButton()
        end
    end)

    self.auctionBar = bar
    return bar
end

--- Put the first of `texts` that fits on the bar's status line, from the
--- full wording to the shortest, rather than running it into the buttons.
--- The full wording is kept for the bar's tooltip when a shorter one shows.
local function SetAuctionStatus(bar, texts)
    local shown = Theme.FitText(bar.status, texts)
    bar.statusFull = shown ~= texts[1] and texts[1] or nil
end

--- Bring the bar's status line and progress bar up to date with the scanner.
function UI:RefreshAuctionStatus()
    local bar = self.auctionBar
    if not (bar and bar.status) then return end

    local scan = ns.Scanner and ns.Scanner.GetScanStatus and ns.Scanner:GetScanStatus()

    if scan then
        bar.doneUntil = nil
        SetAuctionStatus(bar, { scan.text, scan.fraction and L["Scanning"] or L["Waiting to scan"] })
        bar.status:SetTextColor(Theme.Unpack("text"))
        bar.progress:Show()
        bar.progress:SetProgress(scan.fraction or 0)
        bar.glint:SetShown(scan.fraction == nil)
        return
    end

    bar.glint:Hide()

    -- A finished scan keeps its full bar and its line for a moment.
    if bar.doneUntil and GetTime() < bar.doneUntil then return end
    bar.doneUntil = nil

    bar.progress:Hide()
    bar.status:SetTextColor(Theme.Unpack("muted"))

    local lastScan, capped = ns.Prices:GetLastScan()
    if not lastScan then
        SetAuctionStatus(bar, { L["No scan yet. Click Scan to price everything."], L["No scan yet"] })
        return
    end

    local ago = Util.FormatAgeAgo(time() - lastScan)
    if capped then
        SetAuctionStatus(bar, { L.Format("Last scan %s, stopped at the page limit", ago),
            L.Format("Last scan %s (page limit)", ago), L.Format("Scanned %s", ago) })
    else
        SetAuctionStatus(bar, { L.Format("Last scan %s", ago), L.Format("Scanned %s", ago) })
    end
end

--- The finish of a scan: the bar fills, flashes gold, says what it found and
--- plays a short sound.
function UI:CelebrateScan(result)
    local bar = self.auctionBar
    if not (bar and bar.status and bar:IsShown()) then return end

    bar.doneUntil = GetTime() + SCAN_DONE_HOLD
    bar.glint:Hide()
    bar.progress:Show()
    bar.progress:SetProgress(1)

    local prices = Util.Comma(result.items or 0)
    local texts
    if (result.soldOut or 0) > 0 then
        local soldOut = Util.Comma(result.soldOut)
        texts = {
            L.Format("Scan complete: %s prices updated, %s sold out", prices, soldOut),
            L.Format("Scan complete: %s prices, %s sold out", prices, soldOut),
        }
    else
        texts = {
            L.Format("Scan complete: %s prices updated", prices),
        }
    end
    texts[#texts + 1] = L.Format("Scan complete: %s prices", prices)
    texts[#texts + 1] = L["Scan complete"]
    SetAuctionStatus(bar, texts)
    bar.status:SetTextColor(Theme.Unpack("profit"))
    bar.flashLeft = 1

    if (not ns.Config or ns.Config:Get("scanSounds") ~= false) and type(PlaySound) == "function" then
        local kits = type(_G.SOUNDKIT) == "table" and _G.SOUNDKIT or {}
        pcall(PlaySound, kits.IG_QUEST_LIST_COMPLETE or 878, "Master")
    end
end

--- The auction house opened: the sell list docks beside it, with Scan and
--- Post Crafted in its header.
--
-- Scanning only works while the auction house is open, so the control belongs
-- where the player already is rather than only inside our own window.
function UI:AttachToAuctionHouse()
    local auctionFrame, frameName = self:FindAuctionFrame()
    local bar = self:GetAuctionBar()

    -- Placed in the sell list's header by the sell list itself
    -- (PostPanel:PlaceBar), which docks beside the auction window.
    if auctionFrame then
        ns.Debug("auction house found:", frameName)
    else
        ns.Debug("no auction frame found; the sell list uses its fallback position")
    end

    bar:Show()

    local button = self.auctionButton

    if not button then
        button = Widgets.CreateButton(bar, L["Scan"], function()
            UI:TriggerScan()
            UI:UpdateAuctionButton()
        end, {
            -- Wide enough for Cancel too, which it reads while a scan runs.
            width = FitButtonWidth({ L["Scan"], L["Cancel"] }, 56),
            height = AUCTION_BAR_BUTTON_HEIGHT,
        })

        self.auctionButton = button
    end

    button:ClearAllPoints()
    button:SetPoint("RIGHT", bar, "RIGHT", -AUCTION_BAR_PAD, 0)
    button:Show()

    self:UpdateAuctionButton()

    self:AttachPostButton()

    -- Before the sell list attaches: the list measures itself around this
    -- window, so it needs the window where it is going to sit. Built centred,
    -- or wherever it was last dragged with the auction house shut, it is in
    -- the wrong place now either way.
    self:RestorePosition("auctionWindowPosition")

    if ns.PostPanel then ns.PostPanel:Attach() end
end

--- A Post button beside the Scan button on the auction house window.
--
-- Left-click lists the most valuable stack; posting needs a hardware event per
-- listing anyway, so clicking repeatedly works through them. Right-click opens
-- the Post tab for the full table when you want to pick rather than take the
-- top of the list.
function UI:UpdateAuctionButton()
    self:RefreshAuctionStatus()

    local button = self.auctionButton
    if not button then return end

    if ns.Scanner.isScanning or ns.Scanner.scanQueued or ns.Scanner.browseQueued then
        button:SetText(L["Cancel"])
        button.tooltipText = L["Stop the running scan"]
        -- Cancelling is always allowed, even when the button was disabled a
        -- moment ago because a scan was waiting to start.
        button:SetEnabledState(true)
        return
    end

    button:SetText(L["Scan"])

    local allowed, reason = ns.Scanner:CanFullScan()
    button:SetEnabledState(allowed)

    -- The bulk snapshot is rate limited; browsing is not, so say which one a
    -- click will actually do rather than implying a wait.
    local cooldown = ns.Scanner:GetSnapshotCooldown()

    button.tooltipText = allowed
        and (cooldown
            and L.Format("Scans page by page for now. The quick scan is back in %s.",
                Util.FormatAge(cooldown))
            or L["Scan the whole auction house in one go"])
        or reason
end

--- Whether the Post Crafted button shows beside Scan. Taken off for now
--- (2026-10-16); the code stays, so true brings it back.
UI.POST_CRAFTED_BUTTON = false

--- The progress bar and status line run up to the buttons and no further.
-- Corner to corner, never a bare RIGHT or BOTTOM point: those also fix the
-- centre on the other axis, and the client drops one of two points that
-- disagree.
local function FitBarText(bar, buttons)
    if not bar.progress then return end

    local left = AUCTION_BAR_TEXT_LEFT

    bar.progress:ClearAllPoints()
    bar.progress:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", left, 7)
    bar.progress:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -(AUCTION_BAR_PAD + buttons), 7)

    local room = math.max(40, bar:GetWidth() - left - AUCTION_BAR_PAD - buttons)
    bar.status:SetWidth(room)
    if bar.title then bar.title:SetWidth(room) end
end

--- Fit the header's text to the buttons and the Sale Total counter
--- (UI/SaleTotal.lua), which sits left of them and grows with its number.
function UI:FitAuctionText()
    local bar = self.auctionBar
    if not bar then return end
    local counter = ns.SaleTotal and ns.SaleTotal:Width() or 0
    FitBarText(bar, (bar.buttonsWidth or 0) + counter)
end

--- A Post button beside the Scan button on the auction house window.
--
-- Left-click lists the most valuable stack; posting needs a hardware event
-- per listing anyway, so clicking repeatedly works down the list.
-- Right-click opens the window.
function UI:AttachPostButton()
    local bar = self:GetAuctionBar()
    local button = self.postButton
    local gap = 10
    local scanWidth = self.auctionButton and self.auctionButton:GetWidth() or 0

    if not UI.POST_CRAFTED_BUTTON then
        if button then button:Hide() end
        bar.buttonsWidth = scanWidth + gap
        if ns.SaleTotal then ns.SaleTotal:Attach(bar, self.auctionButton) end
        self:FitAuctionText()
        return
    end

    if not button then
        button = Widgets.CreateButton(bar, L["Post Crafted"], function(_, mouseButton)
            if mouseButton == "RightButton" or ns.Posting:IsBlocked() then
                -- The Post tab is gone (a player asked; posting is the
                -- drawer's Sell list), so this opens the window.
                UI:Show()
                return
            end

            local line = ns.Posting:GetNextPostable()

            local allowed, reason = ns.Posting:CanPost(line and line.itemID)
            if not allowed then
                ns.Print(reason or L["cannot post right now"])
                return
            end

            if line then
                ns.Posting:Request(line.itemID, line.postQuantity, line.unitPrice)
            else
                ns.Print(L["nothing in your bags worth listing right now"])
            end

            UI:UpdatePostButton()
        end, {
            width = FitButtonWidth({ L["Post Crafted"] }, 84),
            height = AUCTION_BAR_BUTTON_HEIGHT,
        })

        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        self.postButton = button
    end

    button:ClearAllPoints()

    if self.auctionButton then
        button:SetPoint("RIGHT", self.auctionButton, "LEFT", -AUCTION_BAR_GAP, 0)
    else
        button:SetPoint("RIGHT", bar, "RIGHT", -AUCTION_BAR_PAD, 0)
    end

    button:Show()

    bar.buttonsWidth = (self.auctionButton and scanWidth + AUCTION_BAR_GAP or 0)
        + button:GetWidth() + gap
    if ns.SaleTotal then ns.SaleTotal:Attach(bar, button) end
    self:FitAuctionText()

    self:UpdatePostButton()
end

--- Show a button's wait on the button itself, rather than only in a tooltip.
--
-- Posting is paced on purpose, and with the label unchanged the only sign of
-- that was a button that did nothing when clicked. The countdown is the whole
-- point: a number going down reads as working, where a dead button reads as
-- broken.
--
-- The button stays enabled throughout. Disabling it would swallow the
-- right-click that opens the full list, and a left-click during the wait still
-- prints the reason.
--
-- @param name the label to go back to once the wait is over
local function ApplyWaitLabel(button, name, seconds, reason)
    if not button then return end

    if seconds and seconds > 0.05 then
        -- Rounded up, so the last fraction of a second still shows "1s" rather
        -- than sitting on "0s" while the wait is genuinely still running.
        button:SetText(("%ds"):format(math.max(1, math.ceil(seconds))))
        button.waitingLabel = true
        button.waitTip = reason
    elseif reason then
        -- No number to give: the client's throttle and the player's own sell
        -- window both end when they end. Saying "wait" beats counting down to
        -- zero and then carrying on refusing.
        button:SetText(L["wait"])
        button.waitingLabel = true
        button.waitTip = reason
    else
        button:SetText(name)
        button.waitingLabel = false
        button.waitTip = nil
    end
end

-- Exposed as a plain function, not a method: the tests drive it directly.
UI.ApplyWaitLabel = ApplyWaitLabel

--- Relabel the posting buttons with the current wait, and nothing else.
--
-- Deliberately separate from UpdatePostButton, which rebuilds summaries and
-- walks the bags. This runs four times a second while the auction house is
-- open, so it may only touch labels.
function UI:UpdateWaitLabels()
    if not ns.Scanner.isAuctionHouseOpen then return end

    -- The button lists the item UpdatePostButton last found, and another copy
    -- of an item being confirmed does not wait for it.
    local buttonSeconds, buttonReason = ns.Posting:SecondsUntilPostable(self.postButtonItemID)
    ApplyWaitLabel(self.postButton, L["Post Crafted"], buttonSeconds, buttonReason)

    local seconds, reason = ns.Posting:SecondsUntilPostable()

    if ns.PostPanel then
        ns.PostPanel:UpdateWaitLabels(seconds, reason)
    end
end

--- Everything the sell lists at the auction house are made from, as one
--- string: the bags, prices, the queue (reagents it holds back), settings,
--- prices and amounts chosen this session, ignored items, item data the game
--- has just loaded, the owned auctions read, and whether listing is open
--- (blocked, a scan, the house busy, a listing still being confirmed). The
--- lists are rebuilt only when it changes.
local itemInfoSeen = 0
do
    local watcher = {}
    ns.RegisterEvent(watcher, "GET_ITEM_INFO_RECEIVED", function()
        itemInfoSeen = itemInfoSeen + 1
    end)
end

function UI.SellListKey()
    local queued, amount = 0, 0
    for _, entry in ipairs(ns.Queue:GetAll() or {}) do
        queued = queued + 1
        amount = amount + (tonumber(entry.quantity) or 0)
    end

    local Posting = ns.Posting
    local blocked = Posting.IsBlocked and Posting:IsBlocked()
    local throttled = Posting.IsThrottled and Posting:IsThrottled()
    local pending = Posting.pending and tostring(Posting.pending.itemID) or "-"

    -- And what is showing: a panel or tab that has just come into view is
    -- filled at once.
    local panel = ns.PostPanel
    local frame = panel and panel.frame
    local shown = frame and frame:IsShown() and (tostring(panel.view) .. tostring(panel:IsCollapsed())) or "hidden"
    local tab = UI.window and UI.window:IsShown() and tostring(UI.activeTab) or "closed"

    return table.concat({
        shown, tab,
        ns.Inventory.changes or 0, ns.Prices.changes or 0,
        queued, amount,
        ns.Config.changes or 0, Posting.changes or 0, itemInfoSeen,
        ns.Auctions.readCount or 0,
        tostring(blocked), tostring(ns.Scanner.isScanning), tostring(throttled), pending,
    }, ":")
end

function UI:UpdatePostButton()
    local button = self.postButton
    if not button then return end

    -- One list for the button and its tooltip's summary: making it reads
    -- the bags and prices every craftable stack, once a second here.
    local lines = ns.Posting:GetPostable()
    local line = ns.Posting:GetNextPostable(nil, lines)
    self.postButtonItemID = line and line.itemID

    if not line then
        -- Inert rather than absent, so it never looks like it failed to load.
        button:SetText(L["Post Crafted"])
        button:SetEnabledState(true)
        button.tooltipText =
            L["Nothing in your bags that one of your recipes makes, at a price worth listing."]
        return
    end

    local count, total = ns.Posting:GetSummary(nil, lines)
    local allowed, reason = ns.Posting:CanPost(line.itemID)
    local waitSeconds, waitReason = ns.Posting:SecondsUntilPostable(line.itemID)

    ApplyWaitLabel(button, L["Post Crafted"], waitSeconds, waitReason)
    button:SetEnabledState(true)

    button.tooltipText = allowed
        and L.Format("Lists %d x %s at %s each.\n%d stack(s) to sell, worth about %s.\n\nRight-click for the full list.",
            line.postQuantity, line.label,
            Util.FormatMoney(line.unitPrice, { noColor = true }),
            count, Util.FormatMoney(total, { noColor = true, short = true }))
        or ((reason or L["cannot post right now"]) .. "\n\n" .. L["Right-click for the full list and prices."])
end

--------------------------------------------------------------------------------
-- Transfer dialog
--------------------------------------------------------------------------------

--- A selectable text box for copying an export code out, or pasting one in.
--
-- WoW chat cannot be selected, so a code has to live in an edit box for Ctrl+C
-- to reach it.
function UI:ShowTransferDialog(mode)
    local dialog = self.transferDialog

    if not dialog then
        dialog = CreateFrame("Frame", "BlackthornesTSTransferDialog", UIParent)
        dialog:SetSize(560, 260)
        dialog:SetPoint("CENTER")
        dialog:SetFrameStrata("FULLSCREEN_DIALOG")
        dialog:EnableMouse(true)
        dialog:SetMovable(true)
        dialog:RegisterForDrag("LeftButton")
        dialog:SetScript("OnDragStart", dialog.StartMoving)
        dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)

        Theme.Fill(dialog, "window")
        -- The house frame (UI/Titanforged.lua): the gold rim and corner gems.
        if ns.Titanforged then
            ns.Titanforged:Dress(dialog)
        else
            Theme.AddGameOutline(dialog, { style = "dialog", color = "natural" })
        end
        Theme.Halo(dialog, 10, 0.10)

        tinsert(UISpecialFrames, "BlackthornesTSTransferDialog")

        dialog.title = Theme.CreateLabel(dialog, "large", "accent")
        dialog.title:SetPoint("TOPLEFT", 20, -20)

        dialog.hint = Theme.CreateLabel(dialog, "small", "muted")
        dialog.hint:SetPoint("TOPLEFT", dialog.title, "BOTTOMLEFT", 0, -6)
        dialog.hint:SetPoint("RIGHT", dialog, "RIGHT", -20, 0)
        dialog.hint:SetWordWrap(true)

        local box = Theme.CreatePanel(dialog, "row")
        box:SetPoint("TOPLEFT", 20, -80)
        box:SetPoint("BOTTOMRIGHT", -20, 56)

        local scroll = CreateFrame("ScrollFrame", nil, box)
        scroll:SetPoint("TOPLEFT", 6, -6)
        scroll:SetPoint("BOTTOMRIGHT", -6, 6)

        local editBox = CreateFrame("EditBox", nil, scroll)
        editBox:SetMultiLine(true)
        editBox:SetAutoFocus(false)
        editBox:SetFont(Theme.FONT, Theme.sizes.small, "")
        editBox:SetTextColor(Theme.Unpack("text"))
        editBox:SetWidth(500)
        editBox:SetScript("OnEscapePressed", function() dialog:Hide() end)

        scroll:SetScrollChild(editBox)
        dialog.editBox = editBox

        -- A long code runs past the bottom of the box. A slim bar down its
        -- right edge and the mouse wheel move through it; before, only the
        -- first lines could be seen.
        local bar = CreateFrame("Slider", nil, box)
        bar:SetOrientation("VERTICAL")
        bar:SetWidth(6)
        bar:SetPoint("TOPRIGHT", -3, -6)
        bar:SetPoint("BOTTOMRIGHT", -3, 6)
        bar:SetValueStep(1)
        bar:SetMinMaxValues(0, 0)
        bar:SetValue(0)
        bar:Hide()

        local track = bar:CreateTexture(nil, "BACKGROUND")
        track:SetAllPoints(bar)
        track:SetColorTexture(Theme.Unpack("panel"))

        local thumb = bar:CreateTexture(nil, "ARTWORK")
        thumb:SetColorTexture(Theme.Unpack("borderLit"))
        thumb:SetSize(6, 30)
        bar:SetThumbTexture(thumb)
        Widgets.LightThumb(bar, thumb)

        local function ScrollTo(offset)
            local range = scroll:GetVerticalScrollRange() or 0
            offset = math.max(0, math.min(range, offset or 0))
            scroll:SetVerticalScroll(offset)
            if bar:GetValue() ~= offset then bar:SetValue(offset) end
        end

        bar:SetScript("OnValueChanged", function(_, value) scroll:SetVerticalScroll(value) end)

        scroll:SetScript("OnScrollRangeChanged", function(_, _, range)
            range = tonumber(range) or 0
            bar:SetMinMaxValues(0, range)
            bar:SetShown(range > 0)
            if (scroll:GetVerticalScroll() or 0) > range then ScrollTo(range) end
        end)

        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(_, delta)
            ScrollTo((scroll:GetVerticalScroll() or 0) - (tonumber(delta) or 0) * 30)
        end)
        dialog.scrollTo = ScrollTo

        dialog.action = Widgets.CreateButton(dialog, L["Import"], function()
            local ok, message = ns.Transfer:Import(dialog.editBox:GetText())

            ns.Print(message)
            if ok then dialog:Hide() end
        end, { width = 120, height = 26, primary = true })
        dialog.action:SetPoint("BOTTOMRIGHT", -20, 18)

        local close = Widgets.CreateButton(dialog, L["Close"], function()
            dialog:Hide()
        end, { width = 90, height = 26 })
        close:SetPoint("BOTTOMRIGHT", dialog.action, "BOTTOMLEFT", -8, 0)
        dialog.close = close

        self.transferDialog = dialog
    end

    if mode == "export" then
        local code = ns.Transfer:Export()
        local queued, settings, limits = ns.Transfer:Describe()

        dialog.title:SetText(L["Export"])
        dialog.hint:SetText(L.Format("%d craft(s), %d changed setting(s), %d stock limit(s). Press Ctrl+C to copy, then keep it somewhere until you need it.",
            queued, settings, limits))

        dialog.editBox:SetText(code)
        dialog.editBox:HighlightText()
        dialog.action:Hide()
        -- Import is hidden here, so Close takes its corner rather than
        -- floating where Import would have been beside it.
        dialog.close:ClearAllPoints()
        dialog.close:SetPoint("BOTTOMRIGHT", -20, 18)
    else
        dialog.title:SetText(L["Import"])
        dialog.hint:SetText(L["Paste a code with Ctrl+V, then press Import. Crafts are added to your queue, and the code's settings and stock limits replace yours."])

        dialog.editBox:SetText("")
        dialog.action:Show()
        dialog.close:ClearAllPoints()
        dialog.close:SetPoint("BOTTOMRIGHT", dialog.action, "BOTTOMLEFT", -8, 0)
    end

    -- A new code starts at its top, not wherever the last one was left.
    dialog.scrollTo(0)

    local opening = not dialog:IsShown()
    dialog:Show()
    dialog.editBox:SetFocus()
    if opening and ns.Motion then ns.Motion:Open(dialog) end
end

--------------------------------------------------------------------------------
-- Merchant attachment
--------------------------------------------------------------------------------

-- The button's width at rest, and the room kept each side of its label when
-- a long cost makes it wider.
local MERCHANT_BUTTON_WIDTH = 170
local MERCHANT_BUTTON_PAD = 12

--- Size the button to its label, never narrower than at rest. At 170 wide,
--- "Buy materials  1g 50s 50c" lost its last coins to "...", and the cost
--- is the one thing the button is there to say. It hangs from the vendor
--- window's top right corner, so it grows to the left.
local function FitMerchantButton(button)
    -- The unbounded width where the client has it, else the plain one.
    local width
    for _, method in ipairs({ "GetUnboundedStringWidth", "GetStringWidth" }) do
        if not width and type(button.label[method]) == "function" then
            local ok, value = pcall(button.label[method], button.label)
            width = ok and tonumber(value) or nil
        end
    end

    button:SetWidth(math.max(MERCHANT_BUTTON_WIDTH, math.ceil((width or 0) + MERCHANT_BUTTON_PAD * 2)))
end

--- True while Blackthornes Butler is loaded and its window comes up at a
--- vendor ("Open at a vendor", on unless unticked there). Butler's Buy from
--- a vendor row then buys the queue's materials, so this button hides.
function UI.ButlerBuysHere()
    local ok, yes = pcall(function()
        if type(_G.BlackthornesButler) ~= "table" then return false end
        local db = _G.BlackthornesButlerDB
        return not (type(db) == "table" and db.openAtVendor == false)
    end)
    return ok and yes == true
end

--- A button on Blizzard's vendor window that buys the queue's shortfalls.
--
-- Spending your gold is never automatic: this is one deliberate click, and the
-- button states the exact cost before you press it.
function UI:AttachToMerchant()
    -- Only while a vendor is open. A call that lands after it closed showed
    -- the button over the game world, with no vendor to buy from.
    if not (ns.Vendor and ns.Vendor.isMerchantOpen) then
        if self.merchantButton then self.merchantButton:Hide() end
        return
    end

    -- Blackthornes Butler has the same Buy button on its Buy from a vendor
    -- row, and its window comes up at the vendor, so this one stands down
    -- (the owner, 2026-10-18). Butler buys through Butler:VendorOffer and
    -- Butler:BuyFromVendor, so nothing is lost.
    if UI.ButlerBuysHere() then
        if self.merchantButton then self.merchantButton:Hide() end
        return
    end

    local button = self.merchantButton

    if not button then
        button = Widgets.CreateButton(UIParent, L["Buy materials"], function()
            ns.Vendor:BuyNeeded()
            UI:UpdateMerchantButton()
        end, {
            width = MERCHANT_BUTTON_WIDTH,
            height = 30,
            primary = true,
        })

        button:SetFrameStrata("FULLSCREEN_DIALOG")
        button:SetFrameLevel(100)

        Theme.AddGameOutline(button, {
            style = "tooltip", color = "natural", edgeSize = 12, expand = 4,
        })
        button:ApplyBaseColor()

        self.merchantButton = button
    end

    local merchantFrame = _G.MerchantFrame

    button:ClearAllPoints()
    if merchantFrame then
        button:SetPoint("BOTTOMRIGHT", merchantFrame, "TOPRIGHT", -4, 4)
    else
        button:SetPoint("TOP", UIParent, "TOP", 0, -180)
    end

    button:Show()
    self:UpdateMerchantButton()
end

function UI:UpdateMerchantButton()
    local button = self.merchantButton
    if not button then return end

    if ns.Vendor:IsBuying() then
        button:SetText(L["Buying..."])
        FitMerchantButton(button)
        button:SetEnabledState(false)
        button.tooltipText = L["Purchases in progress"]
        return
    end

    local lines, total, cheaperElsewhere = ns.Vendor:GetNeeded()
    cheaperElsewhere = cheaperElsewhere or 0

    -- Materials this vendor has but the auction house sells for less are
    -- left for the auction house, and the tooltip says so, or the button
    -- reads as though the vendor did not have them.
    local cheaperNote
    if cheaperElsewhere == 1 then
        cheaperNote = L["1 material is cheaper at the auction house."]
    elseif cheaperElsewhere > 1 then
        cheaperNote = L.Format("%d materials are cheaper at the auction house.",
            cheaperElsewhere)
    end

    if #lines == 0 then
        -- Present but inert, so it never looks like it failed to appear.
        button:SetText(L["Nothing needed here"])
        FitMerchantButton(button)
        button:SetEnabledState(false)
        button.tooltipText = ns.Queue:Count() == 0
            and L["Your craft queue is empty"]
            or cheaperNote
            or L["This vendor has nothing your queue needs."]
        return
    end

    button:SetText(("%s  %s"):format(L["Buy materials"],
        Util.FormatMoney(total, { short = true })))
    FitMerchantButton(button)
    button:SetEnabledState(true)

    -- Spell out exactly what will be bought before any gold moves.
    local totalText = Util.FormatMoney(total, { noColor = true, short = true })
    local parts = { #lines == 1 and L.Format("Buy %d material for %s:", #lines, totalText)
        or L.Format("Buy %d materials for %s:", #lines, totalText) }

    for index = 1, math.min(#lines, 10) do
        local line = lines[index]
        parts[#parts + 1] = ("  %dx %s  (%s)%s"):format(
            line.amount, Util.GetItemLabel(line.itemID),
            Util.FormatMoney(line.cost, { noColor = true, short = true }),
            line.short and ("  " .. L["(limited stock)"]) or "")
    end

    if #lines > 10 then
        parts[#parts + 1] = "  " .. L.Format("...and %d more", #lines - 10)
    end

    if cheaperNote then parts[#parts + 1] = cheaperNote end

    button.tooltipText = table.concat(parts, "\n")
end

--------------------------------------------------------------------------------
-- Minimap button
--------------------------------------------------------------------------------

-- Where the button sits until it is dragged. Farmer's sits at 200 degrees on
-- the same ring, and this one sat there too, hidden under it (or Farmer's
-- under this) for anyone running both. Equipment's is at 230 and Pets' at
-- 260. A saved angle is kept as it is.
local DEFAULT_ANGLE = math.rad(170)

function UI:BuildMinimapButton()
    if self.minimapButton or not Minimap then return end

    local button = CreateFrame("Button", "BlackthornesTSMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetPoint("CENTER")
    background:SetColorTexture(Theme.Unpack("window"))

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER")
    icon:SetTexture([[Interface\Icons\Trade_BlackSmithing]])
    icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture([[Interface\Minimap\MiniMap-TrackingBorder]])

    -- The game's own round glow under the mouse, as every minimap button
    -- has, Farmer's included.
    if button.SetHighlightTexture then
        pcall(button.SetHighlightTexture, button,
            [[Interface\Minimap\UI-Minimap-ZoomButton-Highlight]], "ADD")
    end

    -- The icon swells a little under the mouse and dips when pressed, as
    -- Farmer's does.
    local function IconSize(size)
        icon:SetSize(size, size)
    end
    button:SetScript("OnMouseDown", function() IconSize(16) end)
    button:SetScript("OnMouseUp", function()
        -- Back to its hover size if the mouse is still on it, else its own.
        local target = 18 + 2 * ns.Motion:Value(button, "hover")
        ns.Motion:Run(button, "press", 0.2, function(p) IconSize(16 + (target - 16) * p) end,
            { ease = ns.Motion.EaseOutBack })
    end)

    -- Derived from the minimap's real size rather than assumed. A fixed radius
    -- only clears the ring on a default 140px minimap; anyone running a larger
    -- one gets the button sitting on top of the map.
    local function GetOrbitRadius()
        local size = Minimap:GetWidth()
        if not size or size <= 0 then size = 140 end

        -- Centre the button on the ring, where other minimap buttons sit:
        -- 5 pixels past the map's edge. A saved minimapGap is kept but no
        -- longer read; its 16 pixels left the button floating off the ring.
        return (size / 2) + 5
    end

    local function UpdatePosition(angle)
        local radius = GetOrbitRadius()

        button:ClearAllPoints()
        button:SetPoint("CENTER", Minimap, "CENTER",
            math.cos(angle) * radius, math.sin(angle) * radius)
    end

    button.UpdatePosition = UpdatePosition

    local angle = (ns.db and ns.db.minimapAngle) or DEFAULT_ANGLE
    UpdatePosition(angle)

    -- Dragging around the minimap edge is the expected behaviour for these.
    button:SetMovable(true)
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", function(self)
        self.dragging = true
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            -- The minimap's own scale, since its centre is in its own
            -- coordinates: a minimap sized up or down (Edit Mode does it
            -- through scale) put the button at the wrong angle to the cursor.
            local scale = Minimap:GetEffectiveScale()

            local newAngle = math.atan2((cy / scale) - my, (cx / scale) - mx)
            UpdatePosition(newAngle)

            if ns.db then ns.db.minimapAngle = newAngle end
        end)
    end)

    button:SetScript("OnDragStop", function(self)
        self.dragging = false
        self:SetScript("OnUpdate", nil)
    end)

    -- Left-click opens the window, right-click its Settings tab (the
    -- owner, 2026-10-28, the same in every addon).
    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            UI:OpenSettings()
        else
            UI:Toggle()
        end
    end)

    button:SetScript("OnEnter", function(self)
        ns.Motion:Blend(self, "hover", 1, 0.12, function(v) IconSize(18 + 2 * v) end)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Blackthornes Tradeskills")
        -- Which version is installed, so a player can say when reporting.
        GameTooltip:AddLine(ns.VersionLabel(), 0.5, 0.5, 0.5)
        GameTooltip:AddLine(L["Click to open"], 0.7, 0.7, 0.7)
        GameTooltip:AddLine(L["Right-click for settings"], 0.7, 0.7, 0.7)
        GameTooltip:AddLine(L["Drag to move it round the minimap"], 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function(self)
        ns.Motion:Blend(self, "hover", 0, 0.18, function(v) IconSize(18 + 2 * v) end)
        GameTooltip:Hide()
    end)

    self.minimapButton = button
    self.lastMinimapWidth = Minimap:GetWidth()

    self:JoinSharedMinimap()
end

--- The window on its Settings tab; a second right-click puts it away.
function UI:OpenSettings()
    self:Build()
    if self.window:IsShown() and self.activeTab == "settings" then
        self:Hide()
        return
    end
    self:Show()
    self:SelectTab("settings")
end

--- Sign up for the shared Blackthornes button (UI/SharedMinimap.lua). While
--- it is combined, this addon's own button stays out of sight.
function UI:JoinSharedMinimap()
    if not ns.SharedMinimap or not self.minimapButton then return end
    ns.SharedMinimap:Join({
        key = "tradeskills", order = 2, name = "Blackthornes Tradeskills",
        icon = [[Interface\Icons\Trade_BlackSmithing]],
        blurb = L["Crafting, prices and the auction house"],
        button = self.minimapButton,
        angle = function() return (ns.db and ns.db.minimapAngle) or DEFAULT_ANGLE end,
        open = function() UI:Toggle() end,
        settings = function() UI:OpenSettings() end,
        db = function() return ns.db end,
    })
end

-- Whether a name search for this item must stay wide: green or better
-- weapons and armour can roll a suffix, and their copies carry a longer name.
-- An item not loaded yet stays wide too, so nothing is hidden by a guess.
function UI.MaySearchWide(itemID)
    local quality
    if Util.HasFunction("C_Item.GetItemInfo") then
        local ok, _, _, rarity = pcall(C_Item.GetItemInfo, itemID)
        if ok then quality = tonumber(rarity) end
    end
    if quality == nil and type(GetItemInfo) == "function" then
        local ok, _, _, rarity = pcall(GetItemInfo, itemID)
        if ok then quality = tonumber(rarity) end
    end
    if quality == nil then return true end
    local Scanner = ns.Scanner
    if not (Scanner and Scanner.MayHaveSuffix) then return quality >= 2 end
    local ok, may = pcall(Scanner.MayHaveSuffix, itemID, quality)
    return not ok or may == true
end

--- Point Blizzard's auction browse at one item.
--
-- Searching is unrestricted; buying is never automated. The addon puts the item
-- in front of you and gets out of the way.
--
-- quantity is how many the queue still needs, from the shopping lists: picking
-- the item in Blizzard's results then fills its quantity box with that
-- (UI/BuyQuantity.lua). Other searches leave it out and fill nothing.
function UI:SearchAuctionHouse(itemID, quantity)
    if not ns.Scanner.isAuctionHouseOpen then
        ns.Print(L["open the auction house first"])
        return false
    end

    -- A search sent mid-scan takes over the scan's shared results, which
    -- ends the scan early. Wait for it instead.
    if ns.Scanner.isScanning then
        ns.Print(L["a scan is running; search again once it finishes"])
        return false
    end

    local name
    if Util.HasFunction("C_Item.GetItemInfo") then
        local ok, itemName = pcall(C_Item.GetItemInfo, itemID)
        if ok then name = itemName end
    end

    -- Deal rows are mostly items the player has never hovered, so the name
    -- the addon saved when it last saw the item will do.
    if not name and ns.Disenchant and ns.Disenchant.KnownName then
        local ok, known = pcall(ns.Disenchant.KnownName, ns.Disenchant, itemID)
        if ok and type(known) == "string" and known ~= "" then name = known end
    end

    if not name then
        ns.Print(L["the game has not loaded that item yet; hover over it once and try again"])
        return false
    end

    -- Era's older auction house has no C_AuctionHouse: search by name the
    -- way its own Search button does, and the Browse list shows the results.
    if ns.LegacyScan and ns.LegacyScan:Applies() then
        return ns.LegacyScan:Browse(name, function(refused)
            if refused then
                ns.Warn(L["the game refused that search"])
            elseif ns.Scanner.isAuctionHouseOpen then
                ns.Warn(L["the auction house stayed busy; that search was not sent."])
            end
        end, not UI.MaySearchWide(itemID))
    end

    if ns.BuyQuantity then ns.BuyQuantity:Want(itemID, quantity) end

    -- Queued rather than sent directly. This shares one throttled channel with
    -- the player's own posting, and a search fired the instant a row is clicked
    -- is a search that can cost them a listing.
    ns.AHQueue:Request({
        name = ("search the auction house for %s"):format(name),
        key = "ui-search",
        -- The player clicked this and is watching the auction house for it, so
        -- it ranks with their other clicks.
        priority = ns.AHQueue.PRIORITY.urgent,
        expires = 8,

        send = function()
            -- An answer without the item then says nobody is selling one.
            if ns.Scanner.ExpectSearch then ns.Scanner:ExpectSearch(itemID, name) end
            local ok = pcall(C_AuctionHouse.SendBrowseQuery, {
                searchString = name,
                sorts = {},
                filters = {},
                itemClassFilters = {},
                minLevel = 0,
                maxLevel = 0,
            })

            if not ok then
                ns.Warn(L["the game refused that search"])
                return false
            end

            return true
        end,

        onGiveUp = function()
            if not (ns.AHQueue and ns.AHQueue.IsFlushing and ns.AHQueue:IsFlushing()) then
                ns.Warn(L["the auction house stayed busy; that search was not sent."])
            end
        end,
    })

    return true
end

--- With "Open with the auction house and vendors" ticked, the window opens
--- as either opens and closes again as it closes (a player's request,
--- 2026-10-02). Only a window opened this way is closed: one the player
--- already had open stays open.
function UI:OpenWithShop(which)
    if ns.Config:Get("openWithShops") ~= true then return end
    self:Build()
    if self.window:IsShown() then return end
    self.openedFor = which
    self:Show()
end

function UI:CloseWithShop(which)
    if self.openedFor ~= which then return end
    self.openedFor = nil
    if self.window and self.window:IsShown() then self:Hide() end
end

--- Alt-click any item, in the bags, a chat link or a loot window, with the
--- auction house open, and the house searches for it (kronosbest's request,
--- 2026-10-02: "a global action to search the auction house for that item").
--- The search is by name, so every suffix of "Lead Band" comes back.
---
--- Hooked after Blizzard's own handler, so its shift and ctrl clicks are
--- untouched; an Alt-click there does nothing of Blizzard's own.
function UI:HookAltClickSearch()
    if self.altClickHooked or type(hooksecurefunc) ~= "function" then return end
    if type(_G.HandleModifiedItemClick) ~= "function" then return end
    self.altClickHooked = true

    hooksecurefunc("HandleModifiedItemClick", function(link)
        if not ns.Scanner.isAuctionHouseOpen then return end
        if not (IsAltKeyDown and IsAltKeyDown()) then return end
        if (IsShiftKeyDown and IsShiftKeyDown()) or (IsControlKeyDown and IsControlKeyDown()) then return end

        local ok, itemID = pcall(function() return tonumber(link:match("item:(%d+)")) end)
        if ok and itemID then UI:SearchAuctionHouse(itemID) end
    end)
end

--- Re-seat the minimap button at its stored angle, using the current radius.
function UI:RepositionMinimapButton()
    local button = self.minimapButton
    if not button or not button.UpdatePosition then return end

    button.UpdatePosition((ns.db and ns.db.minimapAngle) or DEFAULT_ANGLE)
    self.lastMinimapWidth = Minimap and Minimap:GetWidth()
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function UI:OnEnable()
    self:Build()
    self:BuildMinimapButton()
    self:HookAltClickSearch()

    -- The minimap's final size is not always settled at login, and other addons
    -- resize it afterwards, so re-seat the button once things have calmed down.
    C_Timer.After(1, function() UI:RepositionMinimapButton() end)

    -- The header is the addon's status line; keep it honest while open.
    self.ticker = C_Timer.NewTicker(5, function()
        if UI.window and UI.window:IsShown() then
            UI:UpdateHeader()
        end

        -- Cheap enough to check, and catches a minimap resized at any point.
        if Minimap and UI.lastMinimapWidth ~= Minimap:GetWidth() then
            UI:RepositionMinimapButton()
        end
    end)

    ns.RegisterEvent(self, "AUCTION_HOUSE_SHOW", function()
        UI:UpdateHeader()
        UI:AttachToAuctionHouse()

        -- Blizzard's auction UI is load-on-demand, so on the first open of a
        -- session the frame may not exist yet when this event arrives.
        -- Re-anchor shortly after in case it appeared late.
        C_Timer.After(0.5, function()
            if ns.Scanner.isAuctionHouseOpen then
                UI:AttachToAuctionHouse()
            end
        end)

        -- The auction house throttle clears on its own with no event to say
        -- so. Without this the Post button stays greyed out, explaining that
        -- the house is busy, long after it stopped being busy.
        if UI.postTicker then UI.postTicker:Cancel() end

        -- It used to rebuild the sell lists every second whatever happened,
        -- walking the bags and pricing every stack three times over. Now it
        -- rebuilds only when something they are made from has changed; a
        -- second with nothing new costs a handful of comparisons.
        UI.sellListKey = nil
        UI.postTicker = C_Timer.NewTicker(1, function()
            if not ns.Scanner.isAuctionHouseOpen then return end

            local key = UI.SellListKey()
            if key == UI.sellListKey then
                -- Still each second, and cheap: the panel steps back in when
                -- the character window closes, and follows the main window
                -- when it is dragged, and neither has an event.
                if ns.PostPanel and ns.PostPanel.Place then ns.PostPanel:Place() end
                return
            end
            UI.sellListKey = key

            UI:UpdatePostButton()

            if ns.PostPanel then ns.PostPanel:Refresh() end

        end)

        -- A second, faster ticker purely for the countdown. One second is too
        -- coarse for a wait that is often only a second or two: the number
        -- would jump or sit still, which is what a broken button looks like.
        -- Kept apart from the ticker above because that one rebuilds the sell
        -- list and walks the bags, which is far too much to do four times a
        -- second.
        if UI.waitTicker then UI.waitTicker:Cancel() end

        UI.waitTicker = C_Timer.NewTicker(0.25, function()
            UI:UpdateWaitLabels()
        end)
    end)

    -- Settings: Open with the auction house and vendors.
    ns.RegisterEvent(self, "AUCTION_HOUSE_SHOW", function() UI:OpenWithShop("auction") end)
    ns.RegisterEvent(self, "MERCHANT_SHOW", function() UI:OpenWithShop("merchant") end)
    ns.RegisterEvent(self, "MERCHANT_CLOSED", function() UI:CloseWithShop("merchant") end)

    ns.RegisterEvent(self, "AUCTION_HOUSE_CLOSED", function()
        UI:CloseWithShop("auction")
        UI:UpdateHeader()
        if UI.auctionBar then UI.auctionBar:Hide() end
        if ns.PostPanel then ns.PostPanel:Hide() end

        -- Back to wherever the window normally lives.
        UI:RestorePosition("windowPosition")

        if UI.postTicker then
            UI.postTicker:Cancel()
            UI.postTicker = nil
        end

        if UI.waitTicker then
            UI.waitTicker:Cancel()
            UI.waitTicker = nil
        end
    end)
end
