-- Blackthornes Tradeskills -- UI/ShoppingListsView.lua
-- The auction house drawer's Lists view: the player's named shopping lists
-- (Logic/ShoppingLists.lua), beside Sell and Buy (UI/PostPanel.lua).
--
-- A list is a row with its name, how many items, what is still to buy and a
-- gold Search that looks up every item on it the player still needs. A click
-- opens it: a row of tools (Rename, Copy, Delete), then a row per item with
-- how many are owned, the price, how many are wanted (a box to change it),
-- its own Search and an x. The first list, "From your craft queue", is the
-- Buy view's list and only offers Save as a list.
--
-- The foot holds one box that does what the moment needs: add an item to the
-- open list (type part of a name and pick it from the names above the box, or
-- Shift-click an item anywhere while a list is open), name a new list, rename
-- one, show a list's copy line or take a pasted one. Enter saves.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local View = ns.NewModule("ShoppingListsView")

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local ROW_HEIGHT = 30
-- At most this often the rows are worked out again while nothing moved; a
-- change to a list (ShoppingLists.version) or a click redraws at once.
local REFRESH_SECONDS = 2
local RESTATE_SECONDS = 30
-- How long Delete waits for its second click.
local ARM_SECONDS = 4
-- Names are looked up this long after the last key, not on every key.
local SUGGEST_DELAY = 0.15
local SUGGEST_ROW = 20
-- One shift-click reaches both of the game's calls this addon listens to;
-- the second within this long is the same click.
local SAME_CLICK = 0.3
local QUEUE_KEY = "queue"

View.open = nil       -- the key of the open list: an index, or QUEUE_KEY
View.mode = nil       -- what the foot box does: add, new, rename, copy, paste
View.step = nil       -- a list searched one item at a time: { key, ids, needs, pos }
View.armed = nil      -- { key, at } while Delete waits for its second click

local function Lists() return ns.ShoppingLists end

--------------------------------------------------------------------------------
-- Building the rows
--------------------------------------------------------------------------------

local function LinesFor(key)
    if key == QUEUE_KEY then return Lists():QueueLines() end
    return Lists():Lines(key)
end

--- Every row to draw, in order: each list, and the open one's tools and items.
function View:Entries()
    local entries = {}
    local function AddList(key, name, lines, auto, rules)
        local total, unpriced = Lists().Total(lines)
        local open = self.open == key
        entries[#entries + 1] = {
            kind = "list", key = key, name = name, auto = auto, open = open,
            count = #lines, total = total, unpriced = unpriced,
            searchable = Lists().Searchable(lines), lines = lines, rules = rules or 0,
        }
        if not open then return end
        entries[#entries + 1] = { kind = "tools", key = key, auto = auto }
        for _, line in ipairs(lines) do
            entries[#entries + 1] = { kind = "item", key = key, auto = auto, line = line, itemID = line.itemID }
        end
    end

    AddList(QUEUE_KEY, L["From your craft queue"], LinesFor(QUEUE_KEY), true)
    for _, held in ipairs(Lists():Readable()) do
        AddList(held.index, held.list.name, LinesFor(held.index), false,
            ns.ListRules and ns.ListRules.Count(held.list) or 0)
    end
    return entries
end

--------------------------------------------------------------------------------
-- Searching
--------------------------------------------------------------------------------

local function NeedOf(lines, itemID)
    for _, line in ipairs(lines or {}) do
        if line.itemID == itemID then return line.need end
    end
end

--- Search a list: every item at once where the game allows it, else one at
--- a time, the button reading "Next 2/5" until the last.
function View:SearchList(entry)
    local step = self.step
    if step and step.key == entry.key and step.pos <= #step.ids then
        local id = step.ids[step.pos]
        if ns.UI:SearchAuctionHouse(id, NeedOf(entry.lines, id)) then step.pos = step.pos + 1 end
        if step.pos > #step.ids then self.step = nil end
        self:Refresh(true)
        return
    end

    local ids = entry.searchable
    if #ids == 0 then
        ns.Print(L["Nothing on this list to look for on the auction house."])
        return
    end
    local counts = {}
    for _, id in ipairs(ids) do counts[id] = NeedOf(entry.lines, id) end
    local ok, why = Lists():SearchMany(ids, counts, entry.key)
    if ok then
        self.step = nil
    elseif why == "single" then
        if ns.UI:SearchAuctionHouse(ids[1], NeedOf(entry.lines, ids[1])) and #ids > 1 then
            self.step = { key = entry.key, ids = ids, pos = 2 }
        end
    elseif why then
        ns.Print(why)
    end
    self:Refresh(true)
end

-- After a buy from a list's search, its results are searched again this long
-- later, once for a run of buys, so they show only what is still needed.
local AFTER_BUY = 1.5

--- Something was bought on the auction house. When the results shown are a
--- list's search, look again soon for what that list still needs.
function View:OnBought(itemID, quantity)
    local last = Lists().lastSearch
    if not last then return end
    -- A list's own counts only see a buy once the mail is read; the craft
    -- queue's already count it.
    if last.owner ~= QUEUE_KEY and itemID and quantity then
        last.bought[itemID] = (last.bought[itemID] or 0) + quantity
    end
    if self.afterBuy then self.afterBuy:Cancel() end
    self.afterBuy = C_Timer.NewTimer(AFTER_BUY, function()
        self.afterBuy = nil
        self:SearchAgain()
    end)
end

--- Search the list the results show again, without what was just bought.
--- Nothing is sent when the same items are still needed: only the counts
--- for the buy box change.
function View:SearchAgain()
    local lists = Lists()
    local last = lists.lastSearch
    if not last then return end
    if not (ns.Scanner and ns.Scanner.isAuctionHouseOpen) then lists.lastSearch = nil; return end
    if type(last.owner) == "number" and not lists:Get(last.owner) then lists.lastSearch = nil; return end

    local ids, counts = {}, {}
    for _, line in ipairs(LinesFor(last.owner)) do
        local need = (line.need or 0) - (last.bought[line.itemID] or 0)
        if need > 0 and Lists().CanSearch(line) then
            ids[#ids + 1] = line.itemID
            counts[line.itemID] = need
        end
    end

    if #ids == 0 then
        lists.lastSearch = nil
        ns.Print(L["That's everything on the list."])
        self:Refresh(true)
        return
    end
    local same = #ids == #(last.ids or {})
    for _, id in ipairs(same and last.ids or {}) do
        if not counts[id] then same = false; break end
    end
    if same then
        if ns.BuyQuantity then ns.BuyQuantity:WantMany(counts) end
    else
        lists:SearchMany(ids, counts, last.owner)
    end
    self:Refresh(true)
end

function View:SearchLabel(entry)
    local step = self.step
    if step and step.key == entry.key and step.pos <= #step.ids then
        return L.Format("Next %d/%d", step.pos, #step.ids)
    end
    return L["Search"]
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function Arm(key)
    View.armed = { key = key, at = GetTime() }
end

local function Armed(key)
    local armed = View.armed
    return armed and armed.key == key and GetTime() - armed.at <= ARM_SECONDS
end

--- Which list and item a row's want box is for.
local function WantKey(data)
    return tostring(data.key) .. ":" .. tostring(data.itemID)
end

local function CreateRow(row)
    row.chevron = Theme.CreateLabel(row, "small", "accent", "CENTER")
    row.chevron:SetPoint("LEFT", 4, 0)
    row.chevron:SetWidth(12)

    row.icon = Theme.CreateItemIcon(row, 14)
    row.icon:SetPoint("TOPLEFT", 20, -4)

    row.listSearch = Widgets.CreateButton(row, L["Search"], function()
        if row.data and row.data.kind == "list" then View:SearchList(row.data) end
    end, { width = 66, height = 20, primary = true,
        tooltip = L["Search the auction house for everything on this list you still need."] })
    row.listSearch:SetPoint("RIGHT", row, "RIGHT", -6, 0)

    row.total = Theme.CreateLabel(row, "small", "text", "RIGHT")
    row.total:SetPoint("RIGHT", row.listSearch, "LEFT", -6, 0)

    row.remove = Widgets.CreateButton(row, "x", function()
        local data = row.data
        if data and data.kind == "item" and not data.auto then
            Lists():Remove(data.key, data.itemID)
            View:Refresh(true)
        end
    end, { width = 18, height = 18, danger = true, tooltip = L["Take this off the list."] })
    row.remove:SetPoint("RIGHT", row, "RIGHT", -6, 0)

    row.itemSearch = Widgets.CreateButton(row, L["Search"], function()
        local data = row.data
        if data and data.kind == "item" and Lists().CanSearch(data.line) then
            ns.UI:SearchOrPlan(data.itemID, data.line.need)
        end
    end, { width = 50, height = 18,
        tooltip = ns.PostPanel and ns.PostPanel.SearchTip(L["Searches the auction house. Pick it and how many you need fills in."])
            or L["Searches the auction house. Pick it and how many you need fills in."] })
    row.itemSearch:SetPoint("RIGHT", row.remove, "LEFT", -4, 0)

    row.want = Widgets.CreateNumberBox(row, { width = 46, height = 18, min = 1, max = Lists().MAX_WANT,
        onChange = function(value)
            local data = row.data
            -- Only for the item the number was typed for: a scroll can hand
            -- the row another item while the box has focus.
            if data and row.wantFor ~= WantKey(data) then return end
            if data and data.kind == "item" and not data.auto and value then
                Lists():SetWant(data.key, data.itemID, value)
                View:Refresh(true)
            end
        end })
    row.want:SetPoint("RIGHT", row.itemSearch, "LEFT", -4, 0)

    -- "N rules", after a list's name.
    if ns.ListRulesUI then
        row.chip = ns.ListRulesUI.CreateChip(row)
        row.chip:SetPoint("RIGHT", row.total, "LEFT", -6, 0)
    end

    row.name = Theme.CreateLabel(row, "small", "text")
    row.name:SetPoint("TOPLEFT", 20, -4)
    row.name:SetPoint("RIGHT", row.total, "LEFT", -6, 0)
    row.name:SetWordWrap(false)

    row.sub = Theme.CreateLabel(row, "tiny", "muted")
    row.sub:SetPoint("TOPLEFT", 40, -17)
    row.sub:SetPoint("RIGHT", row.want, "LEFT", -6, 0)
    row.needLabels = { row.sub }

    -- The tools under an open list.
    row.tools = {}
    local function Tool(text, width, onClick, opts)
        opts = opts or {}
        opts.width, opts.height = width, 20
        local button = Widgets.CreateButton(row, text, onClick, opts)
        row.tools[#row.tools + 1] = button
        return button
    end
    row.rename = Tool(L["Rename"], 70, function() View:SetMode("rename", row.data.key) end)
    row.rename:SetPoint("LEFT", row, "LEFT", 22, 0)
    row.copy = Tool(L["Copy"], 60, function() View:SetMode("copy", row.data.key) end,
        { tooltip = L["Gives you a line of text to paste in chat or Discord. Paste a list turns it back into a list."] })
    row.copy:SetPoint("LEFT", row.rename, "RIGHT", 6, 0)
    -- The list's rules (UI/ListRulesWindow.lua, 2026-10-19).
    row.rules = Tool(L["Rules"], 60, function()
        if ns.ListRulesUI then ns.ListRulesUI:Toggle(row.data.key, View.frame) end
    end, { tooltip = L["Set prices and amounts for everything on this list."] })
    row.rules:SetPoint("LEFT", row.copy, "RIGHT", 6, 0)
    row.delete = Tool(L["Delete"], 70, function()
        local key = row.data.key
        if Armed(key) then
            -- The lists after it move up a place, so nothing keeps a key.
            View.armed, View.open, View.step = nil, nil, nil
            Lists():Delete(key)
            View:SetMode(nil)
        else
            Arm(key)
        end
        View:Refresh(true)
    end, { danger = true, tooltip = L["Deletes this list. Click again to be sure."] })
    row.delete:SetPoint("LEFT", row.rules, "RIGHT", 6, 0)
    row.saveQueue = Tool(L["Save as a list"], 110, function()
        local index, why = Lists():SaveQueue()
        if index then
            View.open = index
            View:SetMode("rename", index)
        elseif why then
            ns.Print(why)
        end
        View:Refresh(true)
    end, { tooltip = L["Saves a copy of what the queue needs now as a list you can change."] })
    row.saveQueue:SetPoint("LEFT", row, "LEFT", 22, 0)
end

local function HideAll(row)
    for _, part in ipairs({ row.chevron, row.icon, row.listSearch, row.total, row.remove,
        row.itemSearch, row.want, row.name, row.sub }) do
        part:Hide()
    end
    for _, tool in ipairs(row.tools) do tool:Hide() end
    local chip = rawget(row, "chip")
    if chip then chip:Set(nil) end
end

local function Money(copper)
    return Util.FormatMoney(copper or 0, { short = true })
end

local function UpdateRow(row, entry)
    HideAll(row)
    row.name:SetTextColor(Theme.Unpack("text"))

    if entry.kind == "list" then
        row.chevron:SetText(entry.open and "-" or "+")
        row.chevron:Show()
        row.name:ClearAllPoints()
        row.name:SetPoint("LEFT", 20, 0)
        local tag = ns.ListRulesUI and ns.ListRulesUI.CountText(entry.rules)
        local chip = rawget(row, "chip")
        if chip and tag then
            chip:Set(tag)
            row.name:SetPoint("RIGHT", chip, "LEFT", -6, 0)
        else
            row.name:SetPoint("RIGHT", row.total, "LEFT", -6, 0)
        end
        local count = entry.count == 1 and L["1 item"] or L.Format("%d items", entry.count)
        row.name:SetText(("|c%s%s|r  |c%s%s|r"):format(ns.COLORS.accent, entry.name, ns.COLORS.muted, count))
        row.name:Show()
        row.total:SetText(entry.total > 0 and Money(entry.total) or "")
        row.total:Show()
        row.listSearch:SetText(View:SearchLabel(entry))
        row.listSearch:SetEnabledState(#entry.searchable > 0)
        row.listSearch:Show()
        return
    end

    if entry.kind == "tools" then
        if entry.auto then
            row.saveQueue:Show()
        else
            row.rename:Show()
            row.copy:Show()
            row.rules:Show()
            row.delete:SetText(Armed(entry.key) and L["Click Again"] or L["Delete"])
            row.delete:SetConfirming(Armed(entry.key))
            row.delete:Show()
        end
        return
    end

    local line = entry.line
    Theme.SetItemIcon(row.icon, line.itemID)
    row.icon:Show()
    row.name:ClearAllPoints()
    row.name:SetPoint("TOPLEFT", 40, -3)
    row.name:SetPoint("RIGHT", row.want, "LEFT", -6, 0)
    -- The plain name in its rarity colour; plain until the client has the
    -- item, and coloured by the redraw when it comes (View:OnItemInfo).
    row.name:SetText(Util.GetItemName(line.itemID))
    local r, g, b = Util.GetItemQualityColor(line.itemID)
    if r then
        row.name:SetTextColor(r, g, b)
    else
        row.name:SetTextColor(Theme.Unpack("text"))
        View.waiting = true
    end
    row.name:Show()

    local have = line.need > 0 and L.Format("You have %d, need %d", line.have, line.need)
        or L.Format("You have %d", line.have)
    local price
    if line.fromVendor and line.unit then
        price = L.Format("|c%svendor|r %s each", ns.COLORS.profit, Money(line.unit))
    elseif line.unit then
        price = L.Format("%s each", Money(line.unit))
    else
        price = L["no price"]
    end
    -- Whole: a long line wraps and the row grows to hold it.
    if Theme.SetRowLine then
        Theme.SetRowLine(row.sub, have .. "  ·  " .. price, 17)
    else
        row.sub:SetText(have .. "  ·  " .. price)
    end
    row.sub:SetTextColor(Theme.Unpack(line.need > 0 and "muted" or "profit"))
    row.sub:Show()

    if entry.auto then
        -- The queue's own list: how many it needs, nothing to change here.
        row.want:SetValue(line.want, true)
        row.want:Hide()
    else
        local key = WantKey(entry)
        local focused = row.want.editBox.HasFocus and row.want.editBox:HasFocus()
        if focused and row.wantFor ~= key then
            -- Another item now: what was typed is dropped, not saved on it.
            row.wantFor = nil
            row.want.editBox:ClearFocus()
            focused = false
        end
        if not focused then
            row.want:SetValue(line.want, true)
            row.wantFor = key
        end
        row.want:Show()
        row.remove:Show()
    end
    row.itemSearch:SetShown(Lists().CanSearch(line))
    if entry.auto then
        row.itemSearch:ClearAllPoints()
        row.itemSearch:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    else
        row.itemSearch:ClearAllPoints()
        row.itemSearch:SetPoint("RIGHT", row.remove, "LEFT", -4, 0)
    end
end

local function ShowTooltip(row, entry)
    if entry.kind == "item" then
        Widgets.ShowItemTooltip(row, "ANCHOR_LEFT", entry.itemID)
    elseif entry.kind == "list" then
        GameTooltip:SetOwner(row, "ANCHOR_LEFT")
        GameTooltip:SetText(entry.name)
        if entry.auto then
            GameTooltip:AddLine(L["What your craft queue still needs. It changes with the queue."], 1, 1, 1, true)
        end
        if entry.unpriced > 0 then
            GameTooltip:AddLine(L.Format("%d without a price yet.", entry.unpriced), 0.6, 0.6, 0.6, true)
        end
        GameTooltip:AddLine(entry.open and L["Click to close it."] or L["Click to open it."], 0.78, 0.64, 0.30)
        GameTooltip:Show()
    end
end

--------------------------------------------------------------------------------
-- The foot box
--------------------------------------------------------------------------------

local HINTS = {
    add = L["Add an item: type part of its name or Shift-click it"],
    new = L["Name the new list"],
    rename = L["A new name for the list"],
    copy = L["Press Ctrl+C to copy, then Escape"],
    paste = L["Paste a copied list here"],
}

--- Set what the foot box does. key is the list it acts on, where it needs one.
function View:SetMode(mode, key)
    self.mode, self.modeKey = mode, key
    local box = self.box
    if not box then return end
    box.edit:SetText("")
    self:ClearSuggestions()
    if mode == "rename" then
        local list = Lists():Get(key)
        box.edit:SetText(list and list.name or "")
    elseif mode == "copy" then
        box.edit:SetText(Lists():Export(key) or "")
    end
    self:UpdateFoot()
    if mode and mode ~= "add" then
        box.edit:SetFocus()
        if mode == "copy" or mode == "rename" then box.edit:HighlightText() end
    end
end

--- The mode the box falls back to: adding to the open list, or nothing.
function View:RestingMode()
    if type(self.open) == "number" and Lists():Get(self.open) then return "add", self.open end
    return nil
end

function View:UpdateFoot()
    local box = self.box
    if not box then return end
    local mode = self.mode
    box:SetShown(mode ~= nil)
    Theme.FitWhole(box.hint, mode and HINTS[mode] or "", { "small", "tiny" })
    box.hint:SetShown(mode ~= nil and (box.edit:GetText() or "") == "")
    self.save:SetShown(mode ~= nil and mode ~= "copy")
    self.save:SetText(mode == "add" and L["Add"] or L["Save"])
    self.note:SetShown(mode == nil)
    self.note:SetText(#Lists():Readable() == 0
        and L["Make a list, then add items to it."]
        or L["Click a list to open it."])
end

--- The name part and how many of what was typed: "Peacebloom 40" and
--- "40 Peacebloom" both give "Peacebloom", 40; anything else is all name.
function View.SplitCount(text)
    if type(text) ~= "string" then return "", 1 end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    local name, count = text:match("^(.-)%s+[xX%*]?(%d+)$")
    if name and name ~= "" then return name, tonumber(count) end
    count, name = text:match("^(%d+)%s*[xX%*]?%s+(.+)$")
    if name then return name, tonumber(count) end
    return text, 1
end

--- An item from the text typed, with how many: "Peacebloom 40", "40
--- Peacebloom", a link, an item ID, or part of a name in any case ("linen
--- 20"), which takes the best of the names the box suggests.
function View.ParseAdd(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    local id = Lists().ResolveItem(text)
    if id then return id, 1 end
    local name, count = View.SplitCount(text)
    if name ~= text then
        id = Lists().ResolveItem(name)
        if id then return id, count end
    end
    local best = Lists():Suggest(name, 1)[1]
    if best then return best.id, count end
    return nil
end

--- Enter in the foot box: do what it is there for.
function View:Submit()
    local text = self.box and self.box.edit:GetText() or ""
    local mode, key = self.mode, self.modeKey
    local ok, why

    if mode == "add" then
        local id, count
        local picked = self.suggestions and self.suggestions[self.pick or 0]
        if picked then
            id = picked.id
            count = select(2, View.SplitCount(text))
        else
            id, count = View.ParseAdd(text)
        end
        if not id then
            ns.Print(L["No item by that name yet. Shift-click it, or hover over it once and try again."])
            return
        end
        ok, why = Lists():Add(key, id, count)
        if ok then self.box.edit:SetText("") end
        self:ClearSuggestions()
    elseif mode == "new" then
        local index
        index, why = Lists():Make(text)
        ok = index ~= nil
        if ok then
            self.open = index
            self:SetMode("add", index)
            self.box.edit:SetFocus()
        end
    elseif mode == "rename" then
        ok, why = Lists():Rename(key, text)
        if ok then self:SetMode(self:RestingMode()) end
    elseif mode == "paste" then
        local index
        index, why = Lists():Import(text)
        ok = index ~= nil
        if ok then
            self.open = index
            self:SetMode("add", index)
        end
    end

    if not ok and why then ns.Print(why) end
    self:Refresh(true)
end

--- True while the player is typing in a chat box, where a Shift-click
--- links the item in chat and must stay that way.
local function ChatOpen()
    local util = _G.ChatFrameUtil
    local get = (type(util) == "table" and type(util.GetActiveWindow) == "function" and util.GetActiveWindow)
        or _G.ChatEdit_GetActiveWindow
    if type(get) ~= "function" then return false end
    local ok, box = pcall(get)
    return ok and box ~= nil and box ~= false
end

--- True while the Lists view is on screen with a list open to add to.
function View:Adding()
    if self.mode ~= "add" or not self.box or not self.box:IsShown() then return false end
    if self.list and self.list.IsVisible and not self.list:IsVisible() then return false end
    return Lists():Get(self.modeKey) ~= nil
end

--- A Shift-click on an item while a list is open puts it on that list: from
--- the bags, a chat link, the auction house's own list or any item the addon
--- shows (Widgets.ItemShiftClick). Not while a chat box is being typed in,
--- unless the list's box has the keyboard. From the addon's own rows
--- (`fromAddon`) an item already on the list is left to its usual click, so a
--- Shift-click on the list's own rows still searches.
-- @return true when the item was taken
function View:TakeItem(itemID, fromAddon)
    if not self:Adding() then return false end
    itemID = tonumber(itemID)
    if not itemID then return false end
    local edit = self.box.edit
    local typing = edit.HasFocus and edit:HasFocus()
    if not typing then
        if ChatOpen() then return false end
        if fromAddon then
            for _, line in ipairs(Lists():Lines(self.modeKey)) do
                if line.itemID == itemID then return false end
            end
        end
    end

    local now = GetTime()
    local last = self.lastTaken
    if last and last.id == itemID and now - last.at < SAME_CLICK then return true end
    self.lastTaken = { id = itemID, at = now }

    local ok, why = Lists():Add(self.modeKey, itemID, 1)
    if ok then
        local list = Lists():Get(self.modeKey)
        ns.Print(L.Format("Added %s to %s.", Util.GetItemLabel(itemID), list and list.name or ""))
    elseif why then
        ns.Print(why)
    end
    self:Refresh(true)
    return true
end

local function TakeLink(link)
    if not (IsShiftKeyDown and IsShiftKeyDown()) then return end
    local ok, id = pcall(function() return tonumber(link:match("item:(%d+)")) end)
    if ok and id then View:TakeItem(id) end
end

--- Listens after the game's own Shift-click handling, never instead of it:
--- the bags and chat links go through HandleModifiedItemClick, and some of
--- the game's lists put a link straight into chat.
function View:HookShiftClick()
    if self.hooked or type(hooksecurefunc) ~= "function" then return end
    self.hooked = true
    if type(_G.HandleModifiedItemClick) == "function" then
        hooksecurefunc("HandleModifiedItemClick", TakeLink)
    end
    if type(_G.ChatEdit_InsertLink) == "function" then
        hooksecurefunc("ChatEdit_InsertLink", TakeLink)
    end
    local util = _G.ChatFrameUtil
    if type(util) == "table" and type(util.InsertLink) == "function" then
        hooksecurefunc(util, "InsertLink", TakeLink)
    end
end

--------------------------------------------------------------------------------
-- Names under the fingers
--------------------------------------------------------------------------------

--- Look the typed words up a moment after the last key.
function View:SuggestSoon()
    self.suggestToken = (self.suggestToken or 0) + 1
    local token = self.suggestToken
    local function Run()
        if token == View.suggestToken then View:UpdateSuggestions() end
    end
    if C_Timer and C_Timer.After then C_Timer.After(SUGGEST_DELAY, Run) else Run() end
end

function View:ClearSuggestions()
    self.suggestions, self.pick = nil, nil
    if self.suggest then self.suggest:Hide() end
end

function View:UpdateSuggestions()
    if not (self.box and self.mode == "add" and self.box:IsShown()) then return self:ClearSuggestions() end
    local text = self.box.edit:GetText() or ""
    local name = View.SplitCount(text)
    if name == "" or name:find("|H", 1, true) or name:match("^%d+$") then return self:ClearSuggestions() end

    -- The index may still be on its way: look again when it is in.
    Lists():BuildNames(function() View:UpdateSuggestions() end)
    local found = Lists():Suggest(name)
    if #found == 0 then return self:ClearSuggestions() end

    self.suggestions, self.pick = found, nil
    self:DrawSuggestions()
end

function View:DrawSuggestions()
    local pop = self.suggest
    if not pop then return end
    local found = self.suggestions or {}
    pop:SetHeight(#found * SUGGEST_ROW + 4)
    pop.list:SetData(found)
    pop:Show()
end

--- Up and Down walk the names; nothing picked means Enter takes the best.
function View:MovePick(step)
    local found = self.suggestions
    if not found or #found == 0 then return end
    local pick = (self.pick or 0) + step
    if pick < 1 then pick = #found elseif pick > #found then pick = 1 end
    self.pick = pick
    self:DrawSuggestions()
end

--- Put a suggestion on the open list, keeping a count typed with the name.
function View:TakeSuggestion(entry)
    if not (entry and self:Adding()) then return end
    local _, count = View.SplitCount(self.box.edit:GetText() or "")
    local ok, why = Lists():Add(self.modeKey, entry.id, count)
    if ok then self.box.edit:SetText("") elseif why then ns.Print(why) end
    self:ClearSuggestions()
    self:Refresh(true)
end

local function BuildSuggest(body, box)
    local pop = Theme.CreatePanel(body, "glass", "accent")
    pop:SetPoint("BOTTOMLEFT", box, "TOPLEFT", 0, 2)
    pop:SetPoint("BOTTOMRIGHT", box, "TOPRIGHT", 0, 2)
    pop:SetHeight(SUGGEST_ROW)
    if pop.SetFrameLevel and body.GetFrameLevel then pop:SetFrameLevel((body:GetFrameLevel() or 0) + 30) end
    pop:Hide()

    local list = Widgets.CreateScrollList(pop, {
        rowHeight = SUGGEST_ROW,
        createRow = function(row)
            row.icon = Theme.CreateItemIcon(row, 14)
            row.icon:SetPoint("LEFT", 6, 0)
            row.name = Theme.CreateLabel(row, "small", "text")
            row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
            row.name:SetPoint("RIGHT", -6, 0)
        end,
        updateRow = function(row, entry)
            Theme.SetItemIcon(row.icon, entry.id)
            Theme.SetRowName(row.name, entry.name)
            local r, g, b = Util.GetItemQualityColor(entry.id)
            if r then row.name:SetTextColor(r, g, b) else row.name:SetTextColor(Theme.Unpack("text")) end
        end,
        isSelected = function(entry)
            local picked = View.suggestions and View.suggestions[View.pick or 0]
            return picked == entry
        end,
        searchItem = function() return nil end,
        onEnter = function(row, entry) Widgets.ShowItemTooltip(row, "ANCHOR_RIGHT", entry.id) end,
        onLeave = function() GameTooltip:Hide() end,
        onClick = function(entry) View:TakeSuggestion(entry) end,
    })
    list:SetPoint("TOPLEFT", 2, -2)
    list:SetPoint("BOTTOMRIGHT", -2, 2)
    pop.list = list
    return pop
end

--------------------------------------------------------------------------------
-- Building and drawing
--------------------------------------------------------------------------------

--- Make the view inside the drawer. topAnchor is the frame the list hangs
--- under; the foot sits in the drawer's foot.
function View:Build(body, frame, topAnchor, opts)
    if self.list then return end
    opts = opts or {}

    local list = Widgets.CreateScrollList(body, {
        rowHeight = ROW_HEIGHT,
        createRow = CreateRow,
        updateRow = UpdateRow,
        onEnter = ShowTooltip,
        onLeave = function() GameTooltip:Hide() end,
        isSelected = function(entry) return entry.kind == "list" and entry.open end,
        onClick = function(entry)
            if entry.kind ~= "list" then return end
            View.open = (View.open ~= entry.key) and entry.key or nil
            View.armed = nil
            View:SetMode(View:RestingMode())
            View:Refresh(true)
        end,
    })
    list:SetPoint("TOPLEFT", topAnchor, "BOTTOMLEFT", 0, -4)
    list:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, opts.bottom or 49)
    list:Hide()
    self.list = list
    self.frame = frame

    local pad = opts.edge or 11
    local footMiddle = pad + (opts.footHeight or 34) / 2

    local newList = Widgets.CreateButton(body, L["New list"], function()
        View:SetMode("new")
    end, { width = 86, height = 22, primary = true })
    newList:SetPoint("RIGHT", frame, "BOTTOMRIGHT", -(pad + 6), footMiddle)
    self.newList = newList

    -- Wide enough for either word it shows (German runs longer).
    local saveWidth = 50
    if Theme.MeasureText then
        for _, word in ipairs({ L["Save"], L["Add"] }) do
            local ok, width = pcall(Theme.MeasureText, "small", word)
            if ok and type(width) == "number" then saveWidth = math.max(saveWidth, math.ceil(width) + 20) end
        end
    end
    local save = Widgets.CreateButton(body, L["Save"], function() View:Submit() end, { width = saveWidth, height = 22 })
    save:SetPoint("RIGHT", newList, "LEFT", -6, 0)
    self.save = save

    local box = Theme.CreatePanel(body, "row")
    box:SetHeight(22)
    box:SetPoint("LEFT", frame, "BOTTOMLEFT", pad + 8, footMiddle)
    box:SetPoint("RIGHT", save, "LEFT", -6, 0)
    if Theme.Recess then Theme.Recess(box) end
    local edit = CreateFrame("EditBox", nil, box)
    edit:SetPoint("TOPLEFT", 6, 0)
    edit:SetPoint("BOTTOMRIGHT", -6, 0)
    edit:SetAutoFocus(false)
    edit:SetFont(Theme.FONT, Theme.sizes.small, "")
    edit:SetTextColor(Theme.Unpack("text"))
    edit:SetMaxLetters(4000)
    local hint = Theme.CreateLabel(box, "small", "dim")
    hint:SetPoint("LEFT", 6, 0)
    hint:SetPoint("RIGHT", -6, 0)
    box.edit, box.hint = edit, hint
    edit:SetScript("OnTextChanged", function(self, userInput)
        hint:SetShown(View.mode ~= nil and (self:GetText() or "") == "")
        if View.mode == "add" then
            if userInput then View.pick = nil end
            View:SuggestSoon()
        end
    end)
    edit:SetScript("OnEditFocusGained", function()
        if View.mode == "add" then Lists():BuildNames() end
    end)
    edit:SetScript("OnEditFocusLost", function()
        -- A click on a name lands after the box lets go of the keyboard.
        if C_Timer and C_Timer.After then
            C_Timer.After(0.2, function()
                if not (edit.HasFocus and edit:HasFocus()) then View:ClearSuggestions() end
            end)
        end
    end)
    edit:SetScript("OnArrowPressed", function(_, key)
        if key == "UP" then View:MovePick(-1) elseif key == "DOWN" then View:MovePick(1) end
    end)
    edit:SetScript("OnTabPressed", function()
        local best = View.suggestions and (View.suggestions[View.pick or 0] or View.suggestions[1])
        if best then
            local _, count = View.SplitCount(edit:GetText() or "")
            edit:SetText(count > 1 and ("%s %d"):format(best.name, count) or best.name)
            edit:SetCursorPosition(#(edit:GetText() or ""))
        end
    end)
    edit:SetScript("OnEnterPressed", function() View:Submit() end)
    edit:SetScript("OnEscapePressed", function(self)
        if View.suggestions then return View:ClearSuggestions() end
        self:ClearFocus()
        View:SetMode(View:RestingMode())
    end)
    box:Hide()
    self.box = box
    self.suggest = BuildSuggest(body, box)

    local note = Theme.CreateLabel(body, "tiny", "muted")
    note:SetPoint("LEFT", frame, "BOTTOMLEFT", pad + 8, footMiddle)
    note:SetPoint("RIGHT", save, "LEFT", -6, 0)
    note:SetWordWrap(true)
    self.note = note

    local paste = Widgets.CreateButton(body, L["Paste a list"], function()
        View:SetMode("paste")
    end, { width = 90, height = 20, tooltip = L["Makes a new list from a line someone copied with Copy."] })
    self.paste = paste

    self.parts = { list, newList, save, box, note, paste, self.suggest }
    self:HookShiftClick()
    self:SetShown(false)
end

function View:SetShown(on)
    for _, part in ipairs(self.parts or {}) do
        if part == self.box or part == self.save or part == self.note then
            if not on then part:Hide() end
        elseif part == self.suggest then
            if not on then self:ClearSuggestions() end
        else
            part:SetShown(on)
        end
    end
    self.shown = on
    if on then self:UpdateFoot() end
end

--- Draw the rows again: at once when forced or a list changed, otherwise at
--- most every REFRESH_SECONDS (the drawer redraws every second).
function View:Refresh(force)
    if not (self.list and self.shown) then return end
    local now = GetTime()
    -- Laid out again only when the lists, the bags, a price or the queue
    -- moved, and at least every RESTATE_SECONDS for anything else (mail,
    -- another character's bags): every list's lines are worked out each time.
    local version = table.concat({ tostring(Lists().version),
        tostring(ns.Inventory and ns.Inventory.changes or 0),
        tostring(ns.Prices and ns.Prices.changes or 0),
        tostring(ns.Queue and ns.Queue.version or 0),
        tostring(ns.Vendor and ns.Vendor.isMerchantOpen or false) }, ":")
    if not force and self.drawnAt then
        local since = now - self.drawnAt
        if since < REFRESH_SECONDS then return end
        if self.drawnVersion == version and since < RESTATE_SECONDS then return end
    end
    -- Never under a box being typed in: rows are reused, and the number would
    -- land on another item.
    for _, row in ipairs(self.list.rows or {}) do
        if row:IsShown() and row.want and row.want:IsShown()
            and row.want.editBox.HasFocus and row.want.editBox:HasFocus() then
            return
        end
    end
    self.drawnVersion, self.drawnAt = version, now

    if type(self.open) == "number" and not Lists():Get(self.open) then self.open = nil end
    local entries = self:Entries()
    self.entries = entries
    self.list:SetData(entries)
    self:UpdateFoot()
end

--- Item data arrived: names drawn before it get their rarity colour, the
--- rows on screen drawn again once for a burst, only while one waits.
function View:OnItemInfo()
    if self.itemRedrawQueued or not self.waiting then return end
    if not (self.list and self.shown) then return end
    self.itemRedrawQueued = true
    C_Timer.After(0.2, function()
        View.itemRedrawQueued = false
        if not (View.list and View.shown) then return end
        -- Never under a box being typed in (View:Refresh's rule).
        for _, row in ipairs(View.list.rows or {}) do
            if row:IsShown() and row.want and row.want:IsShown()
                and row.want.editBox.HasFocus and row.want.editBox:HasFocus() then
                return
            end
        end
        View.waiting = false
        View.list:Refresh()
    end)
end

if ns.RegisterEvent then
    ns.RegisterEvent(View, "GET_ITEM_INFO_RECEIVED", function() View:OnItemInfo() end)
end

--- What the drawer's summary line says on Lists.
function View:Summary()
    local count = #Lists():Readable()
    if count == 0 then return L["Your own lists of things to buy."] end
    return count == 1 and L["1 list of your own"] or L.Format("%d lists of your own", count)
end
