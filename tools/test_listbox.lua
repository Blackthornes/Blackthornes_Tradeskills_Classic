-- The LIST box on the Ready to sell list, outside WoW.
--
-- What must hold:
--   1. A number typed and not yet entered counts when List is clicked.
--      Clicking a button leaves the box focused, so the old amount (often
--      the whole stack) was listed with the new one on screen.
--   2. A half-typed number does not move to another item when the list
--      scrolls: the reused row drops it rather than setting that many of
--      whatever it shows now.

local saved = { CreateFrame = CreateFrame, UIParent = UIParent, GameTooltip = GameTooltip,
    C_Timer = C_Timer, GetTime = GetTime }

local function noop() end

-- Frames whose methods do nothing unless named here; fields read as nil. Edit
-- boxes keep focus the game's way: only SetFocus, ClearFocus and hiding
-- change it, and losing it runs OnEditFocusLost.
local function NewFrame()
    local f = { scripts = {}, shown = true, text = "", height = 0, width = 0, points = {} }

    setmetatable(f, { __index = function(_, k)
        if type(k) == "string" and k:match("^%u") then return noop end
    end })

    f.SetScript = function(self, n, fn) self.scripts[n] = fn end
    f.GetScript = function(self, n) return self.scripts[n] end
    f.HookScript = function(self, n, fn)
        local old = self.scripts[n]
        self.scripts[n] = function(...) if old then old(...) end fn(...) end
    end
    f.Show = function(self) self.shown = true end
    f.Hide = function(self)
        self.shown = false
        if self.focus then self:ClearFocus() end
    end
    f.SetShown = function(self, v) if v then self:Show() else self:Hide() end end
    f.IsShown = function(self) return self.shown end
    f.IsVisible = function(self) return self.shown end
    f.SetText = function(self, t) self.text = t end
    f.GetText = function(self) return self.text end
    f.SetHeight = function(self, h) self.height = h end
    f.GetHeight = function(self) return self.height end
    f.SetWidth = function(self, w) self.width = w end
    f.GetWidth = function(self) return self.width end
    f.SetSize = function(self, w, h) self.width, self.height = w, h end
    f.GetStringWidth = function(self) return #tostring(self.text or "") * 6 end
    f.CreateTexture = function() return NewFrame() end
    f.CreateFontString = function() return NewFrame() end
    f.SetMinMaxValues = function(self, a, b) self.minv, self.maxv = a, b end
    f.GetMinMaxValues = function(self) return self.minv or 0, self.maxv or 0 end
    f.SetValue = function(self, v) self.value = v end
    f.GetValue = function(self) return self.value or 0 end
    f.IsMouseOver = function() return false end
    f.SetPoint = function(self, ...) self.points[#self.points + 1] = { ... } end
    f.ClearAllPoints = function(self) self.points = {} end
    f.GetNumPoints = function(self) return #self.points end
    f.SetFocus = function(self) self.focus = true end
    f.HasFocus = function(self) return self.focus == true end
    f.ClearFocus = function(self)
        if self.focus then
            self.focus = false
            if self.scripts.OnEditFocusLost then self.scripts.OnEditFocusLost(self) end
        end
    end

    return f
end

CreateFrame = function() return NewFrame() end
UIParent = NewFrame()
GameTooltip = NewFrame()
C_Timer = { After = noop, NewTicker = function() return { Cancel = noop } end }
GetTime = function() return 1000 end

local function Theme()
    return {
        FONT = "font",
        sizes = { tiny = 10, small = 11, normal = 12, large = 14, title = 16 },
        -- The dropdowns fit their words with these; the full wording here.
        FitText = function(label, texts) label:SetText(texts[1]); return texts[1] end,
        -- Measured as the real one measures: unbounded first.
        TextWidth = function(label)
            for _, method in ipairs({ "GetUnboundedStringWidth", "GetStringWidth" }) do
                local ok, width = pcall(label[method], label)
                if ok and type(width) == "number" and width > 0 then return width end
            end
        end,
        Fill = function() return NewFrame() end,
        Unpack = function() return 1, 1, 1, 1 end,
        Border = noop, SetBorderColor = noop, TopSheen = noop, AddGameOutline = noop,
        Halo = noop, SetHalo = noop, HeaderGlow = noop, SetGradientAlpha = noop,
        GlowBand = function() return NewFrame() end,
        AccentStripe = function() return NewFrame() end,
        CreatePanel = function() return NewFrame() end,
        CreateLabel = function() return NewFrame() end,
        CreateDivider = function() return NewFrame() end,
        CreateItemIcon = function() return NewFrame() end,
        SetItemIcon = noop,
        SetMoneyText = function(label, copper) label:SetText(tostring(copper)) end,
        SetRowName = function(label, text) label:SetText(text) end,
        CreateHeading = function() local h = NewFrame(); h.rule = NewFrame(); return h end,
        ProfitColor = function() return 1, 1, 1, 1 end,
    }
end

local function NewNamespace()
    local ns = {}
    ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
    ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
    ns.RegisterCommand = noop
    ns.RegisterEvent = noop
    ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = noop, noop, noop, noop

    ns.db = {}
    ns.Config = { Get = function(_, k) if k == "postDuration" then return 2 end end, Set = noop }
    ns.Scanner = { isAuctionHouseOpen = true, isScanning = false, IsCommodity = function() return true end }
    ns.Prices = { GetValue = function() return nil end }
    ns.Inventory = { GetCarriedBags = function() return {} end, GetBagCount = function() return 0 end }
    ns.Recipes = { GetAccountWide = function() return {} end }
    ns.Queue = { GetShoppingList = function() return {} end }
    ns.Cost = { FindRecipeForItem = function() return nil end }
    ns.Cost.FindAnyRecipeForItem = ns.Cost.FindRecipeForItem
    ns.Theme = Theme()
    return ns
end

local function Load(ns, path)
    assert(loadfile(lfs_cwd .. path))("Blackthornes_TS", ns)
end

local function Lines()
    local lines = {}
    for i = 1, 14 do
        lines[i] = { itemID = 1000 + i, label = "item" .. i, count = 20, maxQuantity = 20,
            postQuantity = 20, unitPrice = 300, postTotal = 6000, total = 6000 }
    end
    return lines
end

local passed, failed = 0, 0

local function check(label, got, want)
    local ok = got == want
    if ok then passed = passed + 1 else failed = failed + 1 end
    print(string.format("  %-58s %-8s %s", label, tostring(got), ok and "ok" or
        ("WRONG, wanted " .. tostring(want))))
end

--- Type 5 into the first row's box, click List, then scroll and press Enter.
local function Exercise(list, Posting, requested)
    local row = list.rows[1]
    row.quantity.editBox:SetFocus()
    row.quantity.editBox:SetText("5")
    row.post.scripts.OnClick(row.post, "LeftButton")

    check("List lists the 5 typed, not the whole stack", requested.quantity, 5)
    check("of the item typed for", requested.itemID, 1001)
    check("and the box no longer holds the keyboard", row.quantity.editBox:HasFocus(), false)

    -- Typed again, not entered, and then the list scrolls under it.
    row.quantity.editBox:SetFocus()
    row.quantity.editBox:SetText("7")
    list.scripts.OnMouseWheel(list, -1)
    check("the row now shows another item", row.data.itemID ~= 1001, true)
    check("its box shows that item's amount", row.quantity.editBox:GetText(), "20")
    check("and lets go of the keyboard", row.quantity.editBox:HasFocus(), false)
    row.quantity.editBox.scripts.OnEnterPressed(row.quantity.editBox)
    check("Enter sets nothing on the item that scrolled in", Posting.chosenQuantity[row.data.itemID], nil)
    check("and the first item keeps its 5", Posting.chosenQuantity[1001], 5)
end

print("")
print("Ready to sell, beside the auction house")

do
    local ns = NewNamespace()
    ns.Collapse = {
        CONTENT_TOP = -46,
        CreateHeader = function() return NewFrame(), NewFrame() end,
        Attach = noop,
        IsCollapsed = function() return false end,
        Height = function(_, full) return full end,
    }
    ns.UI = { ApplyWaitLabel = noop, FindAuctionFrame = function() return nil end }

    Load(ns, "/Core/Util.lua")
    Load(ns, "/Logic/Posting.lua")
    Load(ns, "/UI/Widgets.lua")
    Load(ns, "/UI/HouseKit.lua")
    Load(ns, "/UI/PostPanel.lua")

    local requested = {}
    ns.Posting.Request = function(_, itemID, quantity)
        requested.itemID, requested.quantity = itemID, quantity
    end

    ns.PostPanel:Build()
    ns.PostPanel.list.height = 300
    ns.PostPanel.list:SetData(Lines())

    Exercise(ns.PostPanel.list, ns.Posting, requested)

    -- The line under the name is shortened to fit, never cut off.
    local row = ns.PostPanel.list.rows[2]
    row.detail.width = 400
    ns.PostPanel.list:Refresh()
    check("with room, the line has the total", row.detail.text, "20 @ 3s 00c  =  60s 00c")
    row.detail.width = 60
    ns.PostPanel.list:Refresh()
    check("short of room, it keeps the amount and price", row.detail.text, "20 @ 3s 00c")

    -- A label's own GetStringWidth can stop at the label's width. Measured
    -- unbounded, the line is still shortened.
    row.detail.GetUnboundedStringWidth = function(self) return #tostring(self.text or "") * 6 end
    row.detail.GetStringWidth = function(self) return math.min(#tostring(self.text or "") * 6, self.width) end
    row.detail.width = 400
    ns.PostPanel.list:Refresh()
    row.detail.width = 60
    ns.PostPanel.list:Refresh()
    check("measured past a capped width, it is still shortened", row.detail.text, "20 @ 3s 00c")

    -- A List button showing a countdown says what it is waiting for.
    local button = ns.PostPanel.list.rows[1].post
    button.waitingLabel, button.waitTip = true, "spacing out requests to the auction house"
    button.scripts.OnEnter(button)
    check("hovering a waiting List says why first",
        GameTooltip.text:find("^|c%x+Waiting: spacing out requests") ~= nil, true)
    check("then what it will list", GameTooltip.text:find("List 20 of 20", 1, true) ~= nil, true)
end

print("")
print("The price each in the game's coins")

do
    local ns = NewNamespace()
    ns.Collapse = {
        CONTENT_TOP = -46,
        CreateHeader = function() return NewFrame(), NewFrame() end,
        Attach = noop,
        IsCollapsed = function() return false end,
        Height = function(_, full) return full end,
    }
    ns.UI = { ApplyWaitLabel = noop, FindAuctionFrame = function() return nil end }

    Load(ns, "/Core/Util.lua")
    Load(ns, "/Logic/Posting.lua")
    Load(ns, "/UI/Widgets.lua")
    Load(ns, "/UI/HouseKit.lua")
    Load(ns, "/UI/Coins.lua")
    Load(ns, "/UI/PostPanel.lua")

    ns.PostPanel:Build()
    ns.PostPanel.list.height = 300
    local lines = Lines()
    lines[1].unitPrice = 31560
    lines[1].postQuantity = 7
    lines[3].held = "Kept for your queue"
    ns.PostPanel.list:SetData(lines)

    local row = ns.PostPanel.list.rows[1]
    row.detail.width = 400
    ns.PostPanel.list:Refresh()
    check("the row has coin columns", row.coins ~= nil, true)
    check("gold shows", row.coins.gold.shown and row.coins.gold.text:find("^3|T") ~= nil, true)
    check("silver shows", row.coins.silver.text:find("^15|T") ~= nil, true)
    check("the line keeps how many go up", row.detail.text:find("^7 of 20") ~= nil, true)
    check("and leaves the price each to the coins", row.detail.text:find("@", 1, true), nil)

    local held = ns.PostPanel.list.rows[3]
    check("a row kept back shows no coins", held.coins.silver.shown or held.coins.copper.shown, false)
    check("and says why", held.detail.text, "Kept for your queue")
end

for key, value in pairs(saved) do _G[key] = value end

print("")
print(("%d passed, %d failed"):format(passed, failed))
assert(failed == 0, "LIST box checks failed")
