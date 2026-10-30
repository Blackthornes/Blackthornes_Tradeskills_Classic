-- Blackthornes Tradeskills -- UI/SearchedPrice.lua
-- The price of what you searched for, at the top of the auction house drawer.
--
-- A player asked (2026-10-30, the owner said build it from a mockup): after a
-- search in the game's own auction window, a gold row at the top of the
-- drawer shows the item's icon, its name and "Auction value" from your
-- scans, or "not scanned yet". Hovering it shows the item's own tooltip. It
-- goes when the auction house closes. Only on Era's older auction house.
--
-- Nothing is written to the game's window: its search box is only read
-- (BrowseName:GetText), and QueryAuctionItems is only post-hooked. The item
-- is the one whose name is the search's words (the client's own names, so
-- every language works), else the only item the results hold. Our own scans
-- and searches fire the same events; a list that names no item for the same
-- words leaves the row as it was, and new words that name nothing hide it.
-- Nothing is saved.

local _, ns = ...

local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local SearchedPrice = ns.NewModule("SearchedPrice")

local Theme = ns.Theme
local Util = ns.Util

SearchedPrice.HEIGHT = 34
-- Results looked at for the item, a list page at most.
SearchedPrice.READ_MOST = 50

-- What is shown: { itemID, words }, or nil.
SearchedPrice.current = nil

function SearchedPrice:Applies()
    return ns.LegacyScan ~= nil and ns.LegacyScan.Applies ~= nil and ns.LegacyScan:Applies()
end

local function Lower(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    return text:lower()
end

local function ItemIDOf(link)
    if type(link) == "number" then return link end
    if type(link) ~= "string" then return nil end
    local id = link:match("item:(%d+)")
    return id and tonumber(id) or nil
end

--- The words in the game's search box, lowered, or nil.
function SearchedPrice.SearchWords()
    local box = _G.BrowseName
    if not (box and box.GetText) then return nil end
    local ok, text = pcall(box.GetText, box)
    return ok and Lower(text) or nil
end

--- The item a search for `words` means: the one the client names that way,
-- else the result named that way, else the only item in the results.
-- `results` is a list of { name, itemID }.
function SearchedPrice.Resolve(words, results)
    words = Lower(words)
    if not words then return nil end
    if type(GetItemInfoInstant) == "function" then
        local ok, id = pcall(GetItemInfoInstant, words)
        if ok and type(id) == "number" then return id end
    end
    local only, several
    for _, result in ipairs(results or {}) do
        if result.itemID then
            if Lower(result.name) == words then return result.itemID end
            if only == nil then
                only = result.itemID
            elseif only ~= result.itemID then
                several = true
            end
        end
    end
    if only and not several then return only end
    return nil
end

--- The browse list's items, read from the game, a page at most.
function SearchedPrice.ReadResults()
    local results = {}
    if type(GetNumAuctionItems) ~= "function" then return results end
    local ok, count = pcall(GetNumAuctionItems, "list")
    if not ok or type(count) ~= "number" then return results end
    for index = 1, math.min(count, SearchedPrice.READ_MOST) do
        local okName, name = pcall(GetAuctionItemInfo, "list", index)
        local okLink, link = pcall(GetAuctionItemLink, "list", index)
        local itemID = okLink and ItemIDOf(link) or nil
        if itemID then
            results[#results + 1] = { name = okName and name or nil, itemID = itemID }
        end
    end
    return results
end

--- Look again at what was searched. `results` (optional) are the list's.
-- @return true when the row changed
function SearchedPrice:Look(words, results)
    words = Lower(words)
    local itemID = SearchedPrice.Resolve(words, results)
    local current = self.current
    if itemID then
        if current and current.itemID == itemID and current.words == words then return false end
        self.current = { itemID = itemID, words = words }
        return true
    end
    -- Our own scans fire the same events for the same words: keep the row.
    if current and current.words == words then return false end
    if current then
        self.current = nil
        return true
    end
    return false
end

function SearchedPrice:Clear()
    if not self.current then return false end
    self.current = nil
    return true
end

--- The row's words: { name, value text } for the item shown, or nil.
function SearchedPrice:Texts()
    local current = self.current
    if not current then return nil end
    local itemID = current.itemID
    local name = Util and Util.GetItemName and Util.GetItemName(itemID)
    if not name and type(GetItemInfo) == "function" then
        local ok, got = pcall(GetItemInfo, itemID)
        if ok then name = got end
    end
    local prices = ns.Prices
    local value = prices and prices.GetValue and prices:GetValue(itemID)
    local text
    if type(value) == "number" and value > 0 then
        text = Util.FormatMoney(value, { short = true })
        if prices.IsStale and prices:IsStale(itemID) then
            local age = prices.GetAge and prices:GetAge(itemID)
            if age then text = L.Format("%s  (%s)", text, Util.FormatAgeAgo(age)) end
        end
    else
        text = L["not scanned yet"]
    end
    return { name = name or tostring(itemID), value = text, itemID = itemID }
end

--------------------------------------------------------------------------------
-- The row
--------------------------------------------------------------------------------

function SearchedPrice:Build(parent)
    if self.row then return self.row end
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(SearchedPrice.HEIGHT)
    row.fill = Theme.Fill(row, "glassActive", 0.95)
    Theme.Border(row, "accentHi", 0.85)
    row.icon = Theme.CreateItemIcon(row, 24)
    row.icon:SetPoint("LEFT", 6, 0)
    row.value = Theme.CreateLabel(row, "small", "text", "RIGHT")
    row.value:SetPoint("RIGHT", -8, 0)
    row.name = Theme.CreateLabel(row, "normal", "text")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.name:SetPoint("RIGHT", row.value, "LEFT", -8, 0)
    row.name:SetWordWrap(true)
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        local current = SearchedPrice.current
        if not current or not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetItemByID then
            pcall(GameTooltip.SetItemByID, GameTooltip, current.itemID)
        else
            pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. current.itemID)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    row:Hide()
    self.row = row
    return row
end

--- Fill the row and show it, or hide it. @return true when it shows
function SearchedPrice:Update()
    local row = self.row
    if not row then return false end
    local texts = self:Texts()
    if not texts then
        row:Hide()
        return false
    end
    Theme.SetItemIcon(row.icon, texts.itemID)
    row.name:SetText(texts.name)
    Theme.SetItemNameColor(row.name, texts.itemID)
    row.value:SetText(L.Format("%s: %s", L["Auction value"], texts.value))
    row:Show()
    return true
end

local function Redraw()
    local panel = ns.PostPanel
    if panel and panel.Refresh then panel:Refresh() end
end

function SearchedPrice:OnListUpdate()
    local words = SearchedPrice.SearchWords()
    -- The same words as the row shown (our own scans' pages): nothing to read.
    if words and self.current and self.current.words == words then return end
    if self:Look(words, words and SearchedPrice.ReadResults() or nil) then Redraw() end
end

function SearchedPrice:OnQuery(name)
    -- Only a search whose words are the box's is the player's; the client
    -- may name the item before any result comes back.
    local words = SearchedPrice.SearchWords()
    if not words or Lower(name) ~= words then return end
    if self:Look(words) then Redraw() end
end

function SearchedPrice:OnEnable()
    if not self:Applies() then return end
    if type(hooksecurefunc) == "function" and type(QueryAuctionItems) == "function" then
        pcall(hooksecurefunc, "QueryAuctionItems", function(name)
            pcall(SearchedPrice.OnQuery, SearchedPrice, name)
        end)
    end
    ns.RegisterEvent(self, "AUCTION_ITEM_LIST_UPDATE", function()
        pcall(SearchedPrice.OnListUpdate, SearchedPrice)
    end)
    ns.RegisterEvent(self, "AUCTION_HOUSE_CLOSED", function()
        if SearchedPrice:Clear() then Redraw() end
    end)
end
