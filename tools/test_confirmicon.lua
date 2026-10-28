-- The item's icon in the posting confirmation.
--
-- The icon sits beside the four lines, not as a line of its own: the house rule
-- is that the dialog says exactly "Average Market Value", "Lowest Market
-- Posting", "Posting at" and "List it at this price, or skip it.". It goes with the
-- dialog when it closes, since the game lends the same popup frame to other
-- dialogs afterwards.

local ns = {}
ns.COLORS = setmetatable({ accent = "ffc8a44d" }, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() return true end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end

ns.Util = {
    Clamp = function(v, l, h) return math.max(l, math.min(h, v)) end,
    Count = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end,
    Comma = tostring,
    FormatMoney = function(c) return tostring(c) end,
    FormatAge = function() return "" end,
    FormatAgeAgo = function() return "" end,
    GetItemLabel = function(i) return "item" .. tostring(i) end,
    GetItemIcon = function(i) if i == 2589 then return 132889 end return nil end,
    GetMaxStackSize = function() return 20 end,
    UnitPriceFromStack = function(_, buyout, quantity) return math.floor(buyout / (quantity or 1)) end,
    HasFunction = function() return false end,
    RoundToSilver = function(p) if p < 100 then return 100 end return math.floor(p / 100) * 100 end,
    IsWholeSilver = function(p) return p >= 100 and p % 100 == 0 end,
    WhenAuctionReady = function(action) action() end,
}

local priceTable = {}
ns.Config = {
    Get = function() return nil end,
    GetPriceTable = function() return priceTable end,
    GetRealmKey = function() return "TestRealm" end,
}
ns.db = {}
ns.Cost = { FindRecipeForItem = function() return nil end }
ns.Cost.FindAnyRecipeForItem = ns.Cost.FindRecipeForItem
ns.Auctions = { GetPostedCount = function() return 0 end }
ns.AHQueue = { PRIORITY = { urgent = 10, normal = 50, scan = 90 } }

time = time or os.time
GetTime = function() return 100 end
Enum = { ItemCommodityStatus = { Commodity = 2 }, BagIndex = {} }
UnitName = function() return "Tester" end
GetRealmName = function() return "TestRealm" end
C_Timer = {
    NewTimer = function() return { Cancel = function() end } end,
    After = function() end,
    NewTicker = function() return { Cancel = function() end } end,
}

-- A popup frame that records the textures made on it.
local function NewPopup(width)
    local popup = { width = width, textures = {} }
    function popup:GetWidth() return self.width end
    function popup:GetName() return nil end
    function popup:CreateTexture()
        local tex = { shown = false }
        function tex:ClearAllPoints() end
        function tex:SetAllPoints() end
        function tex:SetSize() end
        function tex:SetPoint() end
        function tex:SetTexture(t) self.texture = t end
        function tex:Show() self.shown = true end
        function tex:Hide() self.shown = false end
        self.textures[#self.textures + 1] = tex
        return tex
    end
    return popup
end

local nextPopup, shownText
StaticPopupDialogs = {}
StaticPopup_Show = function(_, text)
    shownText = text
    return nextPopup
end

assert(loadfile(lfs_cwd .. "/Data/Prices.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Data/Scanner.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Profit.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Posting.lua"))("Blackthornes_TS", ns)

local Prices, Posting = ns.Prices, ns.Posting
local entry = StaticPopupDialogs["BLACKTHORNES_TS_CONFIRM_POST"]

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

local function lines(text)
    local out = {}
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    for line in (text .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then out[#out + 1] = line end
    end
    return out
end

local function iconOn(popup)
    local tex = popup.textures[1]
    return tex and tex.shown and tex.texture or nil
end

print("\nthe item icon in the posting confirmation")

check("the dialog makes room beside its text", entry.showAlert == true)

Prices:Record(2589, 500, 450, 20, time(), 450, nil)
local wide = NewPopup(420)
nextPopup = wide
Posting:Confirm(2589, 1, 400, { state = "fresh" })

check("the item's icon is shown", iconOn(wide) == 132889)
local l = lines(shownText)
check("the text is still exactly four lines", #l == 4
    and l[1] == "Average Market Value: 500"
    and l[2] == "Lowest Market Posting: 450"
    and l[3] == "Posting at: 400, item2589"
    and l[4] == "List it at this price, or skip it.")

-- Closing the dialog takes the icon with it: the frame is lent to other
-- dialogs next.
entry.OnHide(wide)
check("the icon goes when the dialog closes", iconOn(wide) == nil)

-- An item the game has not loaded yet shows the question mark, never the
-- alert sign underneath.
nextPopup = wide
Posting:Confirm(9999, 1, 100)
check("an unknown icon shows the question mark", iconOn(wide) == 134400)
check("and the same texture is reused", #wide.textures == 1)

-- The next confirmation lands in another popup frame: only it has an icon.
local other = NewPopup(420)
nextPopup = other
Posting:Confirm(2589, 1, 400, { state = "fresh" })
check("the new dialog has the icon", iconOn(other) == 132889)
check("the old frame's icon is gone", iconOn(wide) == nil)

-- A popup that did not widen has no room beside its text.
local narrow = NewPopup(320)
nextPopup = narrow
Posting:Confirm(2589, 1, 400, { state = "fresh" })
check("no icon over the words of a narrow popup", iconOn(narrow) == nil)

StaticPopupDialogs, StaticPopup_Show = nil, nil

print(("\n%d check(s) passed\n"):format(checks))
