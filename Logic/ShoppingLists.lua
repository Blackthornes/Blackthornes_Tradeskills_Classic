-- Blackthornes Tradeskills -- Logic/ShoppingLists.lua
-- Named shopping lists (a player asked, the owner said build it, 2026-10-14).
--
-- The player makes lists, names them and puts items on them, each with how
-- many they want. At the auction house the drawer's Lists view
-- (UI/ShoppingListsView.lua) shows them; a list's Search looks up every item
-- on it the player still needs, and an item's own Search looks up that one.
-- The craft queue's shopping list is always the first list, "From your craft
-- queue", built from Queue:GetShoppingList and never saved.
--
-- Saved account wide in `shoppingLists` (never rename it):
--   { { name = "Potion herbs", items = { { id = 2447, want = 40 }, ... },
--       id = 3, rules = { ... } }, ... }
-- `id` is made once for each list (`shoppingListNextId`, never rename
-- either) and `rules` are the list's rules (Logic/ListRules.lua).
-- in the order the player made them. Nothing else from the save goes in, and
-- a list is only ever removed by the player (Delete).
--
-- Copy and paste: Export gives one line, "BTSlist1:<name>:<id>x<want>,...",
-- items only, and Import makes a new list from one. The line is read as data:
-- numbers and a name, nothing run.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local ShoppingLists = ns.NewModule("ShoppingLists")

local Util = ns.Util

ShoppingLists.MAX_LISTS = 50
ShoppingLists.MAX_ITEMS = 100
ShoppingLists.MAX_NAME = 40
ShoppingLists.MAX_WANT = 99999
ShoppingLists.PREFIX = "BTSlist1"

-- Moves on every change, so a view redraws only when something moved.
ShoppingLists.version = 0

local function Changed()
    ShoppingLists.version = ShoppingLists.version + 1
    -- With Share Shopping Lists ticked, the other account hears soon.
    if ns.AccountLink and ns.AccountLink.ListsChanged then pcall(ns.AccountLink.ListsChanged, ns.AccountLink) end
end

--- Something about a list changed outside this file (its rules,
--- Logic/ListRules.lua, or the other account's lists coming in): move the
--- version so views and lookups redraw. Nothing is sent for it.
function ShoppingLists:Touch()
    ShoppingLists.version = ShoppingLists.version + 1
end

--------------------------------------------------------------------------------
-- Storage
--------------------------------------------------------------------------------

--- Every list the player made, in order. A broken entry in the save is
--- skipped, never deleted.
function ShoppingLists:All()
    if not ns.db then return {} end
    if type(ns.db.shoppingLists) ~= "table" then ns.db.shoppingLists = {} end
    return ns.db.shoppingLists
end

local function IsList(list)
    return type(list) == "table" and type(list.name) == "string"
end

--- Give a list its stable id (a number, made once and kept, never
--- renamed), so Butler can keep its own rules for a list through a rename.
local function GiveId(list)
    if tonumber(list.id) then return end
    local nextId = math.max(1, math.floor(tonumber(ns.db.shoppingListNextId) or 1))
    for _, other in ipairs(ns.db.shoppingLists or {}) do
        if type(other) == "table" and tonumber(other.id) and tonumber(other.id) >= nextId then nextId = tonumber(other.id) + 1 end
    end
    list.id = nextId
    ns.db.shoppingListNextId = nextId + 1
end

local function Items(list)
    if type(list.items) ~= "table" then list.items = {} end
    return list.items
end

--- The lists that can be read, in order, with their place in the save.
-- @return { { index, list } ... }
function ShoppingLists:Readable()
    local out = {}
    for index, list in ipairs(self:All()) do
        if IsList(list) then
            GiveId(list)
            out[#out + 1] = { index = index, list = list }
        end
    end
    return out
end

function ShoppingLists:Get(index)
    local list = self:All()[tonumber(index) or 0]
    return IsList(list) and list or nil
end

--- A name as kept: trimmed, no line breaks or the two marks the copy line
--- uses, and no longer than MAX_NAME.
function ShoppingLists.CleanName(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("[\r\n\t:,|]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #name > ShoppingLists.MAX_NAME then
        -- Cut between letters, never inside one (an ä or ß is two bytes).
        local cut = ShoppingLists.MAX_NAME
        while cut > 0 and name:byte(cut + 1) and name:byte(cut + 1) >= 128 and name:byte(cut + 1) < 192 do
            cut = cut - 1
        end
        name = name:sub(1, cut):gsub("%s+$", "")
    end
    if name == "" then return nil end
    return name
end

local function NameTaken(name, except)
    local lower = name:lower()
    for index, list in ipairs(ShoppingLists:All()) do
        if index ~= except and IsList(list) and list.name:lower() == lower then return true end
    end
    return false
end

--- The name given, or with a number after it when another list has it.
local function FreeName(name, except)
    if not NameTaken(name, except) then return name end
    for n = 2, ShoppingLists.MAX_LISTS + 1 do
        -- Room for the number, so a long name is not cut back to itself.
        local suffix = (" %d"):format(n)
        local base = ShoppingLists.CleanName(name:sub(1, ShoppingLists.MAX_NAME - #suffix)) or name
        local tried = ShoppingLists.CleanName(base .. suffix)
        if tried and not NameTaken(tried, except) then return tried end
    end
    return name
end

--- Make a new empty list.
-- @return its index, or nil and why
function ShoppingLists:Make(name)
    name = self.CleanName(name)
    if not name then return nil, L["Give the list a name."] end
    local lists = self:All()
    if #self:Readable() >= self.MAX_LISTS then
        return nil, L.Format("You have %d lists, the most there can be.", self.MAX_LISTS)
    end
    lists[#lists + 1] = { name = FreeName(name), items = {} }
    Changed()
    return #lists
end

function ShoppingLists:Rename(index, name)
    local list = self:Get(index)
    if not list then return nil, L["That list is gone."] end
    name = self.CleanName(name)
    if not name then return nil, L["Give the list a name."] end
    list.name = FreeName(name, tonumber(index))
    Changed()
    return true
end

--- Remove a list. Only ever the player's own click (a second one, in the
--- view), so a list never goes by itself.
function ShoppingLists:Delete(index)
    index = tonumber(index)
    if not self:Get(index) then return false end
    table.remove(self:All(), index)
    Changed()
    return true
end

local function CleanWant(want)
    want = math.floor(tonumber(want) or 1)
    return math.max(1, math.min(ShoppingLists.MAX_WANT, want))
end

--- Put an item on a list, or add to how many are wanted when it is there.
-- @return true, or nil and why
function ShoppingLists:Add(index, itemID, want)
    local list = self:Get(index)
    if not list then return nil, L["That list is gone."] end
    itemID = math.floor(tonumber(itemID) or 0)
    if itemID <= 0 then return nil, L["That is not an item."] end

    local items = Items(list)
    for _, item in ipairs(items) do
        if type(item) == "table" and item.id == itemID then
            item.want = CleanWant((tonumber(item.want) or 0) + CleanWant(want))
            Changed()
            return true
        end
    end
    if #items >= self.MAX_ITEMS then
        return nil, L.Format("A list holds at most %d items.", self.MAX_ITEMS)
    end
    items[#items + 1] = { id = itemID, want = CleanWant(want) }
    Changed()
    return true
end

function ShoppingLists:Remove(index, itemID)
    local list = self:Get(index)
    if not list then return false end
    local items = Items(list)
    for i, item in ipairs(items) do
        if type(item) == "table" and item.id == itemID then
            table.remove(items, i)
            Changed()
            return true
        end
    end
    return false
end

function ShoppingLists:SetWant(index, itemID, want)
    local list = self:Get(index)
    if not list then return false end
    for _, item in ipairs(Items(list)) do
        if type(item) == "table" and item.id == itemID then
            local clean = CleanWant(want)
            if item.want ~= clean then
                item.want = clean
                Changed()
            end
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- Reading a list
--------------------------------------------------------------------------------

--- Can the auction house help with this line? Still short, and not from a
--- vendor that never runs out (the Buy list's own rule).
function ShoppingLists.CanSearch(line)
    return type(line) == "table" and (line.need or 0) > 0
        and (not line.fromVendor or line.vendorLimited == true)
end

--- One item of a list as a row: how many are wanted, owned (bags, bank and
--- mail, as the craft queue counts) and still needed, and what one costs.
--- `have`, when given, is used as it is (the other account's own count).
function ShoppingLists:Line(itemID, want, have)
    if type(have) ~= "number" and ns.Inventory and ns.Inventory.GetOwnedCount then
        have = 0
        local ok, owned = pcall(ns.Inventory.GetOwnedCount, ns.Inventory, itemID)
        if ok and type(owned) == "number" then have = owned end
    end
    have = type(have) == "number" and have or 0

    local vendor = ns.Vendor and ns.Vendor:GetUnitPrice(itemID) or nil
    local auction = ns.Prices and ns.Prices:GetValue(itemID, "lowest") or nil
    local keeps = vendor ~= nil and ns.Vendor:KeepsInStock(itemID)
    -- A shop with limited stock is never where a list sends you (the craft
    -- queue's rule, Queue:GetShoppingList); the auction house prices it.
    local limited = vendor ~= nil and ns.Vendor:IsLimited(itemID)
    local fromVendor = vendor ~= nil and not limited and (keeps or not auction or vendor <= auction)

    local need = math.max(0, want - have)
    local unit = fromVendor and vendor or auction
    return {
        itemID = itemID,
        want = want,
        have = have,
        need = need,
        unit = unit,
        cost = unit and unit * need or nil,
        fromVendor = fromVendor,
        vendorLimited = limited == true,
    }
end

--- Every item on a list as rows, in the list's order.
function ShoppingLists:Lines(index)
    local list = self:Get(index)
    local lines = {}
    if not list then return lines end
    for _, item in ipairs(Items(list)) do
        local id = type(item) == "table" and tonumber(item.id)
        if id then lines[#lines + 1] = self:Line(id, CleanWant(item.want)) end
    end
    return lines
end

--- The craft queue's shopping list as the same rows: what it still needs.
function ShoppingLists:QueueLines()
    local lines = {}
    if not (ns.Queue and ns.Queue.GetShoppingList) then return lines end
    local ok, shopping = pcall(ns.Queue.GetShoppingList, ns.Queue)
    if not ok or type(shopping) ~= "table" then return lines end
    for _, line in ipairs(shopping) do
        if (line.shortfall or 0) > 0 then
            lines[#lines + 1] = {
                itemID = line.itemID,
                want = line.needed or line.shortfall,
                have = line.have or 0,
                need = line.shortfall,
                unit = line.unitCost,
                cost = line.estimatedCost,
                fromVendor = line.fromVendor,
                vendorLimited = line.vendorLimited,
            }
        end
    end
    return lines
end

--------------------------------------------------------------------------------
-- The other account's lists (Share Shopping Lists, Logic/AccountLink.lua)
--------------------------------------------------------------------------------

local LINK_PREFIX = "link:"

--- Is this key one of the other account's lists?
function ShoppingLists.IsLinkedKey(key)
    return type(key) == "string" and key:sub(1, #LINK_PREFIX) == LINK_PREFIX
end

--- The other account's lists, read only, while Share Shopping Lists is
--- ticked here: { { key, name, from, queue, items }, ... }, each partner's
--- craft queue first, partners by name.
function ShoppingLists:Linked()
    local out = {}
    if not (ns.Config and ns.Config:Get("linkShareLists") == true) then return out end
    local all = ns.db and ns.db.linkedShoppingLists
    if type(all) ~= "table" then return out end
    local keys = {}
    for key, held in pairs(all) do
        if type(key) == "string" and type(held) == "table" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local held = all[key]
        local from = type(held.from) == "string" and held.from or key
        if type(held.queue) == "table" and #held.queue > 0 then
            out[#out + 1] = { key = LINK_PREFIX .. key .. ":q", queue = true, from = from, items = held.queue,
                              name = L.Format("Craft queue (%s)", from) }
        end
        for index, list in ipairs(type(held.lists) == "table" and held.lists or {}) do
            if type(list) == "table" and type(list.n) == "string" and type(list.i) == "table" then
                out[#out + 1] = { key = LINK_PREFIX .. key .. ":" .. index, from = from, items = list.i,
                                  name = L.Format("%s (%s)", list.n, from) }
            end
        end
    end
    return out
end

--- One of the other account's lists by key, or nil once it is gone.
function ShoppingLists:LinkedList(key)
    if not ShoppingLists.IsLinkedKey(key) then return nil end
    for _, list in ipairs(self:Linked()) do
        if list.key == key then return list end
    end
    return nil
end

--- The rows of one of the other account's lists: how many it wants and
--- has, with this side's prices.
function ShoppingLists:LinkedLines(key)
    local lines = {}
    local list = self:LinkedList(key)
    if not list then return lines end
    for _, item in ipairs(list.items) do
        local id, want = tonumber(item[1]), tonumber(item[2])
        if id and want then lines[#lines + 1] = self:Line(id, want, tonumber(item[3]) or 0) end
    end
    return lines
end

--- What the items still needed cost, and whether any had no price.
function ShoppingLists.Total(lines)
    local total, unpriced = 0, 0
    for _, line in ipairs(lines) do
        if (line.need or 0) > 0 then
            if line.cost then total = total + line.cost else unpriced = unpriced + 1 end
        end
    end
    return total, unpriced
end

--- The items of these rows worth searching the auction house for.
function ShoppingLists.Searchable(lines)
    local ids = {}
    for _, line in ipairs(lines) do
        if ShoppingLists.CanSearch(line) then ids[#ids + 1] = line.itemID end
    end
    return ids
end

--- Save the craft queue's list as a list of the player's own, to change.
function ShoppingLists:SaveQueue(name)
    local lines = self:QueueLines()
    if #lines == 0 then return nil, L["The craft queue needs nothing right now."] end
    local index, why = self:Make(name or L["From your craft queue"])
    if not index then return nil, why end
    for _, line in ipairs(lines) do self:Add(index, line.itemID, line.want) end
    return index
end

--------------------------------------------------------------------------------
-- Finding an item from what the player typed
--------------------------------------------------------------------------------

--- An item from a link, an item ID or a name the client knows.
function ShoppingLists.ResolveItem(text)
    if type(text) ~= "string" then return tonumber(text) end
    local id = tonumber(text:match("item:(%d+)")) or tonumber(text:match("^%s*(%d+)%s*$"))
    if id then return id end

    local name = text:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    for _, path in ipairs({ "C_Item.GetItemInfoInstant", "C_Item.GetItemInfo" }) do
        if Util.HasFunction(path) then
            local fn = path == "C_Item.GetItemInfoInstant" and C_Item.GetItemInfoInstant or C_Item.GetItemInfo
            local ok, a, b = pcall(fn, name)
            if ok then
                if type(a) == "number" then return a end
                if type(b) == "string" then
                    local found = tonumber(b:match("item:(%d+)"))
                    if found then return found end
                end
            end
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Names to pick from
--------------------------------------------------------------------------------

-- The add box suggests items as the player types part of a name, in any
-- case. The names come from what the addon already knows: every item it has
-- a price for, every character's recipes and their materials, the bags,
-- starred items, the mail ledger and the lists themselves. A name the game
-- has not loaded is skipped rather than asked for (thousands of requests at
-- once), so it is found next time. The index is built a slice a frame and
-- kept for NAMES_KEEP seconds.
ShoppingLists.NAMES_SLICE = 300
ShoppingLists.NAMES_KEEP = 60
ShoppingLists.SUGGEST_MOST = 6

ShoppingLists.names = nil        -- { { id, name, lower }, ... }, the last built
ShoppingLists.namesAt = nil
ShoppingLists.namesVersion = 0   -- moves when a new index is in
local building = nil

local function CachedName(itemID)
    if not (Util.HasFunction("C_Item.IsItemDataCachedByID") and Util.HasFunction("C_Item.GetItemInfo")) then
        return nil
    end
    local ok, cached = pcall(C_Item.IsItemDataCachedByID, itemID)
    if not ok or cached ~= true then return nil end
    local okName, name = pcall(C_Item.GetItemInfo, itemID)
    if okName and type(name) == "string" and name ~= "" then return name end
end

--- Every item ID worth suggesting, with a name where one is saved.
function ShoppingLists:NameCandidates()
    local ids, known = {}, {}
    local function Note(id, name)
        id = tonumber(id)
        if not id or id <= 0 then return end
        ids[id] = true
        if type(name) == "string" and name ~= "" and not known[id] then known[id] = name end
    end

    local function Try(fn) pcall(fn) end
    Try(function()
        for id in pairs(ns.Prices:GetTable()) do Note(id) end
    end)
    Try(function()
        for id, name in pairs(ns.Prices:GetFavourites()) do Note(id, name) end
    end)
    Try(function()
        for _, record in pairs(ns.db.characters) do
            for _, recipe in pairs(type(record) == "table" and type(record.recipes) == "table" and record.recipes or {}) do
                if type(recipe) == "table" then
                    Note(recipe.outputItemID, recipe.name)
                    for _, reagent in ipairs(type(recipe.reagents) == "table" and recipe.reagents or {}) do
                        if type(reagent) == "table" then Note(reagent.itemID) end
                    end
                end
            end
        end
    end)
    Try(function()
        for id in pairs(ns.Inventory:GetBagCounts()) do Note(id) end
    end)
    Try(function()
        for _, entry in ipairs(ns.Mail:GetLedger().entries) do
            if type(entry) == "table" then Note(entry.itemID, entry.name) end
        end
    end)
    for _, list in ipairs(self:All()) do
        if IsList(list) then
            for _, item in ipairs(Items(list)) do
                if type(item) == "table" then Note(item.id) end
            end
        end
    end
    -- Everything a recipe makes or uses, learned or not (2026-10-18: a
    -- material nobody had priced, carried or crafted with was never found,
    -- so the names ran out as more of it was typed). Only names the game
    -- already has are kept, as for the rest.
    Try(function()
        local book = ns.RECIPE_BOOK and ns.RECIPE_BOOK.RECIPES
        for _, row in pairs(type(book) == "table" and book or {}) do
            if type(row) == "table" then
                Note(row[3])
                local mats = type(row[6]) == "table" and row[6] or {}
                for i = 1, #mats, 2 do Note(mats[i]) end
            end
        end
    end)
    return ids, known
end

--- Start building the name index, unless a fresh one is kept or one is on
--- its way. done() is called once it is in.
function ShoppingLists:BuildNames(done, force)
    if building then
        building.done = done or building.done
        return
    end
    if not force and self.names and self.namesAt and GetTime() - self.namesAt < self.NAMES_KEEP then
        return
    end

    local ids, known = self:NameCandidates()
    local order = {}
    for id in pairs(ids) do order[#order + 1] = id end
    building = { order = order, known = known, pos = 1, out = {}, seen = {}, done = done }

    local function Step()
        local job = building
        if not job then return end
        local last = math.min(#job.order, job.pos + self.NAMES_SLICE - 1)
        for i = job.pos, last do
            local id = job.order[i]
            local name = CachedName(id) or job.known[id]
            if name then
                local lower = name:lower()
                job.out[#job.out + 1] = { id = id, name = name, lower = lower }
            end
        end
        job.pos = last + 1
        if job.pos <= #job.order and C_Timer and C_Timer.After then
            C_Timer.After(0, Step)
            return
        end
        if job.pos <= #job.order then return Step() end
        building = nil
        self.names, self.namesAt = job.out, GetTime()
        self.namesVersion = self.namesVersion + 1
        if job.done then pcall(job.done) end
    end
    Step()
end

--- The words of what was typed, for a match by words: each in lower case,
--- with a plural's "s" let go ("linen cloths" still finds Linen Cloth).
local function Words(wanted)
    local words = {}
    for word in wanted:gmatch("%S+") do
        if #word > 3 and word:sub(-1) == "s" then word = word:sub(1, -2) end
        words[#words + 1] = word
    end
    return words
end

local function HasWords(lower, words)
    for _, word in ipairs(words) do
        if not lower:find(word, 1, true) then return false end
    end
    return true
end

--- The items whose name holds what was typed, best first: the name itself,
--- then names that start with it, then a word that does, then anywhere,
--- then names holding every word typed in any order ("linen bolt" finds
--- Bolt of Linen Cloth). Shorter names first within each, so "linen" gives
--- Linen Cloth before Bolt of Linen Cloth. When nothing the addon knows
--- matches, the game is asked for an item of exactly that name.
function ShoppingLists:Suggest(text, most)
    most = most or self.SUGGEST_MOST
    if type(text) ~= "string" then return {} end
    local wanted = text:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "):lower()
    if wanted == "" then return {} end

    local found, seen = {}, {}
    local words = Words(wanted)
    for _, entry in ipairs(self.names or {}) do
        local at = entry.lower:find(wanted, 1, true)
        local rank
        if at then
            if entry.lower == wanted then
                rank = 1
            elseif at == 1 then
                rank = 2
            elseif entry.lower:sub(at - 1, at - 1):match("[%s%-%(]") then
                rank = 3
            else
                rank = 4
            end
        elseif #words > 0 and HasWords(entry.lower, words) then
            rank = 5
        end
        if rank and not seen[entry.id] then
            seen[entry.id] = true
            found[#found + 1] = { id = entry.id, name = entry.name, rank = rank, lower = entry.lower }
        end
    end

    if #found == 0 then
        local id = self.ResolveItem(text)
        local name = id and CachedName(id)
        if name then found[1] = { id = id, name = name, rank = 1, lower = name:lower() } end
    end

    table.sort(found, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if #a.name ~= #b.name then return #a.name < #b.name end
        if a.lower ~= b.lower then return a.lower < b.lower end
        return a.id < b.id
    end)
    for i = #found, most + 1, -1 do found[i] = nil end
    return found
end

--------------------------------------------------------------------------------
-- Copy and paste
--------------------------------------------------------------------------------

function ShoppingLists:Export(index)
    local list = self:Get(index)
    if not list then return nil end
    local parts = {}
    for _, item in ipairs(Items(list)) do
        local id = type(item) == "table" and tonumber(item.id)
        if id then parts[#parts + 1] = ("%dx%d"):format(id, CleanWant(item.want)) end
    end
    return ("%s:%s:%s"):format(self.PREFIX, self.CleanName(list.name) or "", table.concat(parts, ","))
end

--- Make a new list from a copied line.
-- @return its index, or nil and why
function ShoppingLists:Import(text)
    if type(text) ~= "string" then return nil, L["That is not a copied list."] end
    local name, body = text:match("^%s*" .. self.PREFIX .. ":([^:]*):([%d%*xX,]*)%s*$")
    if not name then return nil, L["That is not a copied list."] end

    local items = {}
    for id, want in body:gmatch("(%d+)[%*xX](%d+)") do
        if #items >= self.MAX_ITEMS then break end
        items[#items + 1] = { tonumber(id), tonumber(want) }
    end
    if #items == 0 then return nil, L["That list has no items."] end

    local index, why = self:Make(self.CleanName(name) or L["Pasted list"])
    if not index then return nil, why end
    for _, item in ipairs(items) do self:Add(index, item[1], item[2]) end
    return index
end

--------------------------------------------------------------------------------
-- Searching
--------------------------------------------------------------------------------

--- Look up several items at once in the game's own results, where the
--- client offers it; through the same throttled queue as every other search,
--- so it never costs the player a listing.
-- @param counts optional [itemID] = how many are still needed: picking one
--   in the results fills the buy window's quantity box (UI/BuyQuantity.lua)
-- @param owner optional: the list the search is for (UI/ShoppingListsView.lua
--   searches it again after a buy). An owner may search for one item too.
-- @return true when the search was queued, or false and why
function ShoppingLists:SearchMany(itemIDs, counts, owner)
    if type(itemIDs) ~= "table" or #itemIDs == 0 then
        return false, L["Nothing on this list to look for on the auction house."]
    end
    local scanner = ns.Scanner
    if not (scanner and scanner.isAuctionHouseOpen) then
        return false, L["open the auction house first"]
    end
    if scanner.isScanning then
        return false, L["a scan is running; search again once it finishes"]
    end

    -- One item: the ordinary search, which also fills the quantity.
    if (#itemIDs == 1 and owner == nil) or not (Util.HasFunction("C_AuctionHouse.SearchForItemKeys")
            and Util.HasFunction("C_AuctionHouse.MakeItemKey")) then
        return false, "single"
    end

    local keys = {}
    for _, id in ipairs(itemIDs) do
        local ok, key = pcall(C_AuctionHouse.MakeItemKey, id)
        if ok and key then keys[#keys + 1] = key end
    end
    if #keys == 0 then return false, "single" end

    if ns.BuyQuantity then ns.BuyQuantity:WantMany(counts) end

    ns.AHQueue:Request({
        name = ("search the auction house for %d items"):format(#keys),
        key = "ui-search",
        priority = ns.AHQueue.PRIORITY.urgent,
        expires = 8,
        send = function()
            ShoppingLists:WatchSearches()
            -- Set first: the hook below sees these keys and keeps it.
            -- Buys from the same list's last search stay counted.
            local prev = ShoppingLists.lastSearch
            ShoppingLists.lastSearch = owner ~= nil and {
                owner = owner, keys = keys, ids = itemIDs,
                bought = prev and prev.owner == owner and prev.bought or {},
            } or nil
            local ok = pcall(C_AuctionHouse.SearchForItemKeys, keys, {})
            if not ok then
                ns.Warn(L["the game refused that search"])
                return false
            end
            return true
        end,
        onGiveUp = function()
            if not (ns.AHQueue.IsFlushing and ns.AHQueue:IsFlushing()) then
                ns.Warn(L["the auction house stayed busy; that search was not sent."])
            end
        end,
    })
    return true
end

-- The list whose search the results show: { owner, keys, ids, bought },
-- until any other search fills the results (the player's own, a scan, a
-- check) or the auction house closes.
ShoppingLists.lastSearch = nil

--- Watch every search that fills the browse results, once. hooksecurefunc
--- runs after the game's own call and changes nothing.
function ShoppingLists:WatchSearches()
    if self.watching then return end
    self.watching = true
    ns.RegisterEvent(self, "AUCTION_HOUSE_CLOSED", function() ShoppingLists.lastSearch = nil end)
    if type(hooksecurefunc) ~= "function" or type(C_AuctionHouse) ~= "table" then return end
    for _, name in ipairs({ "SendBrowseQuery", "SearchForFavorites", "SearchForItemKeys" }) do
        if type(C_AuctionHouse[name]) == "function" then
            pcall(hooksecurefunc, C_AuctionHouse, name, function(query)
                local last = ShoppingLists.lastSearch
                if last and query ~= last.keys then ShoppingLists.lastSearch = nil end
            end)
        end
    end
end
