-- Blackthornes Tradeskills -- Core/Util.lua
-- Money formatting, table helpers, and a frame-budgeted worker used to grind
-- through thousands of recipes or auction rows without stuttering the client.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Util = {}
ns.Util = Util

local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD   = 100 * 100

--------------------------------------------------------------------------------
-- Money
--------------------------------------------------------------------------------

local GOLD_SUFFIX   = "|cffffd700g|r"
local SILVER_SUFFIX = "|cffc7c7cfs|r"
local COPPER_SUFFIX = "|cffeda55fc|r"

-- The game's own coin icons, for text drawn on a gold button, where the
-- coloured letters wash out.
local GOLD_ICON   = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

--- Format a copper amount as gold/silver/copper.
-- @param copper  amount in copper; nil renders as a muted dash
-- Every coin below the largest shows, zero-padded: "1g 05s 00c", "8s 00c".
-- @param opts    { short = true } drops trailing silver/copper once gold is large,
--                { noColor = true } strips the colour escapes,
--                { icons = true } shows the game's coin icons for g, s and c,
--                { parts = 1 or 2 } at most that many coins, counted from the
--                largest, rounded to the last one shown ("12g 35s" for
--                12g 34s 56c): for a narrow cell, see Theme.SetMoneyText
function Util.FormatMoney(copper, opts)
    if copper == nil then
        return "|c" .. ns.COLORS.muted .. "--|r"
    end

    opts = opts or {}

    local amount = math.floor(math.abs(copper) + 0.5)

    if opts.parts then
        -- The smallest coin shown, from the largest the amount has.
        local largest = amount >= COPPER_PER_GOLD and 3 or amount >= COPPER_PER_SILVER and 2 or 1
        local smallest = largest - opts.parts + 1
        local unit = smallest >= 3 and COPPER_PER_GOLD or smallest == 2 and COPPER_PER_SILVER or 1
        amount = math.floor(amount / unit + 0.5) * unit
    end

    -- Signed after rounding: a loss of a fraction of a copper rounds to
    -- nothing, and "-0c" in red read as a loss that was not there.
    local negative = copper < 0 and amount > 0

    local gold   = math.floor(amount / COPPER_PER_GOLD)
    local silver = math.floor((amount % COPPER_PER_GOLD) / COPPER_PER_SILVER)
    local copperPart = amount % COPPER_PER_SILVER

    local g, s, c = GOLD_SUFFIX, SILVER_SUFFIX, COPPER_SUFFIX
    if opts.icons then
        g, s, c = GOLD_ICON, SILVER_ICON, COPPER_ICON
    elseif opts.noColor then
        g, s, c = "g", "s", "c"
    end

    local parts = {}
    if gold > 0 then
        parts[#parts + 1] = Util.Comma(gold) .. g
    end

    -- Past a few hundred gold the copper column is noise, not precision.
    local suppressMinor = opts.short and gold >= 100

    -- Coins left out by `parts` are rounded away above, and stay out even
    -- when they come to zero ("12g", not "12g 0s").
    local showSilver = not suppressMinor and not (opts.parts and gold > 0 and opts.parts < 2)
    local showCopper = not suppressMinor and not (opts.parts and
        ((gold > 0 and opts.parts < 3) or (silver > 0 and opts.parts < 2)))

    -- Once a larger coin shows, every smaller one shows too, two digits wide
    -- ("1g 05s 00c", "8s 00c", "45c"): one shape for every amount, so a
    -- right-aligned column lines its coins up (a player's request, 2026-10-07).
    if showSilver and (silver > 0 or gold > 0) then
        parts[#parts + 1] = (gold > 0 and ("%02d"):format(silver) or tostring(silver)) .. s
    end
    if showCopper then
        if #parts > 0 then
            parts[#parts + 1] = ("%02d"):format(copperPart) .. c
        else
            parts[#parts + 1] = copperPart .. c
        end
    end

    local text = table.concat(parts, " ")
    if negative then
        text = "-" .. text
    end
    return text
end

--- Split copper into the three fields Blizzard's auction price box wants.
-- @return gold, silver, copper
function Util.SplitMoney(amount)
    amount = math.floor(math.max(0, amount or 0))

    return math.floor(amount / COPPER_PER_GOLD),
        math.floor((amount % COPPER_PER_GOLD) / COPPER_PER_SILVER),
        amount % COPPER_PER_SILVER
end

--- Insert thousands separators into a non-negative integer.
function Util.Comma(number)
    local text = tostring(math.floor(number))
    local result = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (result:gsub("^,", ""))
end

function Util.Round(value, decimals)
    local mult = 10 ^ (decimals or 0)
    return math.floor(value * mult + 0.5) / mult
end

--- Clamp helper; the client provides Clamp() on mainline but we do not rely on it.
function Util.Clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

--------------------------------------------------------------------------------
-- Tables
--------------------------------------------------------------------------------

function Util.CopyDeep(source)
    if type(source) ~= "table" then return source end

    local copy = {}
    for key, value in pairs(source) do
        copy[key] = Util.CopyDeep(value)
    end
    return copy
end

--- Fill in any keys present in defaults but missing from target, recursively.
-- Existing values are never overwritten, so user settings survive upgrades.
function Util.ApplyDefaults(target, defaults)
    if type(target) ~= "table" then target = {} end

    for key, value in pairs(defaults) do
        if type(value) == "table" then
            target[key] = Util.ApplyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
    return target
end

function Util.Count(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
end

--- Sorted array of a table's keys, for stable output in reports.
function Util.SortedKeys(tbl)
    local keys = {}
    for key in pairs(tbl) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return tostring(a) < tostring(b)
    end)
    return keys
end

--------------------------------------------------------------------------------
-- Frame-budgeted worker
--------------------------------------------------------------------------------

-- Processing several thousand recipes in one go visibly hitches the client.
-- A worker spreads the same work across frames, spending at most `budgetMs` of
-- each frame and reporting progress so the UI can show a bar.

local workerFrame = CreateFrame("Frame", "BlackthornesTSWorkerFrame")
local activeWorkers = {}

local workerProto = {}
workerProto.__index = workerProto

--- Begin processing a list. Any in-flight run is discarded.
function workerProto:Start(items)
    self.items = items or {}
    self.index = 0
    self.running = true
    self.startedAt = GetTime()
    activeWorkers[self] = true
    workerFrame:Show()
    return self
end

function workerProto:Cancel()
    if not self.running then return end
    self.running = false
    activeWorkers[self] = nil
    if self.onCancel then
        self.onCancel(self)
    end
end

function workerProto:IsRunning()
    return self.running == true
end

--- 0..1 completion, for progress bars.
function workerProto:GetProgress()
    local total = #(self.items or {})
    if total == 0 then return 1 end
    return Util.Clamp(self.index / total, 0, 1)
end

local function StepWorker(worker)
    local deadline = debugprofilestop() + worker.budgetMs
    local items = worker.items
    local total = #items

    while worker.index < total do
        worker.index = worker.index + 1

        local ok, err = pcall(worker.onItem, items[worker.index], worker.index, worker)
        if not ok then
            geterrorhandler()(err)
        end

        -- Not worker.running: onItem may have cancelled us mid-batch.
        if not worker.running then return end

        if debugprofilestop() >= deadline then break end
    end

    if worker.onProgress then
        worker.onProgress(worker:GetProgress(), worker.index, total, worker)
    end

    if worker.index >= total then
        worker.running = false
        activeWorkers[worker] = nil
        if worker.onDone then
            worker.onDone(worker)
        end
    end
end

workerFrame:SetScript("OnUpdate", function()
    if not next(activeWorkers) then
        workerFrame:Hide()
        return
    end

    for worker in pairs(activeWorkers) do
        if worker.running then
            StepWorker(worker)
        else
            activeWorkers[worker] = nil
        end
    end
end)

workerFrame:Hide()

--- Create a worker.
-- @param opts { onItem = function(item, index, worker),
--               onProgress = function(fraction, index, total, worker),
--               onDone = function(worker),
--               onCancel = function(worker),
--               budgetMs = milliseconds of each frame to spend (default 8) }
function Util.NewWorker(opts)
    assert(type(opts) == "table" and type(opts.onItem) == "function",
        "NewWorker requires an onItem handler")

    return setmetatable({
        onItem     = opts.onItem,
        onProgress = opts.onProgress,
        onDone     = opts.onDone,
        onCancel   = opts.onCancel,
        budgetMs   = opts.budgetMs or 8,
        items      = {},
        index      = 0,
        running    = false,
    }, workerProto)
end

--------------------------------------------------------------------------------
-- Misc
--------------------------------------------------------------------------------

--- Existence check for a dotted API path, e.g. "C_AuctionHouse.SendBrowseQuery".
-- Returns the value and true when every segment resolves.
function Util.ResolvePath(path)
    local current = _G
    for segment in path:gmatch("[^%.]+") do
        if type(current) ~= "table" then return nil, false end

        local ok, value = pcall(function() return current[segment] end)
        if not ok or value == nil then return nil, false end

        current = value
    end
    return current, true
end

function Util.HasFunction(path)
    local value, found = Util.ResolvePath(path)
    return found and type(value) == "function"
end

--- What a vendor pays for one unit, or nil if the client has not cached it.
--
-- This is the floor under any listing. An auction below it is worse than
-- walking to a vendor, and that is true before the auction house takes its cut
-- or keeps the deposit, so it is a floor rather than a break-even point.
--
-- Not to be confused with Vendor:GetUnitPrice, which is what a merchant
-- *charges* for the item and is several times larger. That one answers "can I
-- buy this reagent"; this one answers "is listing this worth doing at all".
-- Answers kept for the session: neither a vendor price nor a binding ever
-- changes, and the Profit list asks about every recipe's output on every
-- redraw. Asking the client again each time pulls those items back into its
-- small item cache, which pushes bag items out (Ready to sell then flickers).
local sellPriceMemo, bindTypeMemo, maxStackMemo = {}, {}, {}

--- Forget the kept answers (for tests, whose pretend items change).
function Util._ForgetItemMemo()
    sellPriceMemo, bindTypeMemo, maxStackMemo = {}, {}, {}
end

-- The tooltip line type retail gives "Sell Price:". 11 on every retail build
-- that has the enum; read from the client when it says.
local function SellPriceLineType()
    local enum = _G.Enum and _G.Enum.TooltipDataLineType
    return (type(enum) == "table" and enum.SellPrice) or 11
end

-- "5 Charges" as Lua patterns: the English line, then the client's own
-- ITEM_SPELL_CHARGES ("%d |4Aufladung:Aufladungen;" on a German client),
-- once with each word of its |4one:many; choice. Built once.
local chargesPatterns

local function ChargesPatterns()
    if chargesPatterns then return chargesPatterns end
    local patterns = { "^(%d+) Charges?$" }

    local format = _G.ITEM_SPELL_CHARGES
    if type(format) == "string" and format:find("%d", 1, true) then
        for _, pick in ipairs({ "%1", "%2" }) do
            local ok, pattern = pcall(function()
                local text = format:gsub("|4([^:;]*):([^;]*);", pick)
                text = text:gsub("%%d", "\1")
                text = text:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
                return "^" .. text:gsub("\1", "(%%d+)") .. "$"
            end)
            if ok and type(pattern) == "string" then patterns[#patterns + 1] = pattern end
        end
    end

    chargesPatterns = patterns
    return patterns
end

--- What the item's own tooltip says a vendor pays for one, or nil when the
--- client has no tooltip data for it or the tooltip shows no sell price.
--
-- Forever's server changed some sell prices from Classic's, and only the
-- tooltip has the new one: Greater Magic Wand's tooltip says 1c while
-- GetItemInfo still answers Classic's 15s 35c (2026-10-03). So the
-- tooltip wins. Read by item ID, so it is the price of one, never a stack.
-- Only ask for an item the client already holds.
--
-- @return copper, then true when the tooltip was there to read at all
--
-- Also says whether the item has charges ("5 Charges"): a vendor on Forever
-- can pay a charged item's price split across its charges while both the
-- item info and the tooltip show the whole of it (Minor Wizard Oil, 2026-10-09).
-- @return copper or nil, whether the tooltip was read, charges or nil
function Util.GetTooltipSellPrice(itemID)
    if not itemID or not Util.HasFunction("C_TooltipInfo.GetItemByID") then return nil, false end

    local ok, data = pcall(C_TooltipInfo.GetItemByID, itemID)
    if not ok or type(data) ~= "table" or type(data.lines) ~= "table" or #data.lines == 0 then
        return nil, false
    end

    local sellType = SellPriceLineType()
    local found, charges
    for _, line in ipairs(data.lines) do
        if type(line) == "table" then
            local price, kind, text = line.price, line.type, line.leftText

            -- Early 10.0 builds hand the fields over as an args list.
            if type(line.args) == "table" then
                for _, arg in ipairs(line.args) do
                    if type(arg) == "table" then
                        if arg.field == "type" and kind == nil then kind = arg.intVal end
                        if arg.field == "price" and price == nil then price = arg.intVal end
                        if arg.field == "leftText" and text == nil then text = arg.stringVal end
                    end
                end
            end

            if found == nil and kind == sellType and type(price) == "number" and price >= 0 then
                found = price
            end

            if charges == nil and type(text) == "string" then
                for _, pattern in ipairs(ChargesPatterns()) do
                    local read, count = pcall(string.match, text, pattern)
                    charges = read and tonumber(count) or nil
                    if charges then break end
                end
            end
        end
    end

    return found, true, charges
end

function Util.GetVendorSellPrice(itemID)
    if not itemID then return nil end

    -- What a vendor on Forever was seen paying beats what the client says.
    local paid = ns.Vendor and ns.Vendor.GetPaid and ns.Vendor:GetPaid(itemID)
    if paid then return paid > 0 and paid or nil end

    local known = sellPriceMemo[itemID]
    if known ~= nil then return known or nil end

    if not Util.HasFunction("C_Item.GetItemInfo") then return nil end

    -- sellPrice is the eleventh return. Items the client has not cached yet
    -- return nothing at all, which reads the same as "no vendor value" here;
    -- GetItemLabel already asks the client to cache anything it renders, so a
    -- second look once the list refreshes has it.
    local ok, name, _, _, _, _, _, _, _, _, _, sellPrice = pcall(C_Item.GetItemInfo, itemID)

    -- The tooltip's price wins where it shows one (see GetTooltipSellPrice).
    if ok and name then
        local fromTooltip = Util.GetTooltipSellPrice(itemID)
        if fromTooltip then sellPrice = fromTooltip end
    end

    -- Only a real answer is kept: an item not cached yet returns no name.
    if ok and name and type(sellPrice) == "number" then
        sellPriceMemo[itemID] = sellPrice > 0 and sellPrice or false
    end

    if not ok or type(sellPrice) ~= "number" or sellPrice <= 0 then return nil end

    return sellPrice
end

--- The most of an item that can sit in one stack, or nil if uncached.
--
-- Used to tell a stack count apart from something that is not one. An auction
-- house that reports 241 of an item whose stack size is 1 is not describing a
-- stack, and a price divided by that number is not a unit price.
function Util.GetMaxStackSize(itemID)
    if not itemID then return nil end

    -- Kept, like the vendor price: a full scan asks this for nearly every
    -- row, and most items appear in many rows.
    if maxStackMemo[itemID] then return maxStackMemo[itemID] end

    if not Util.HasFunction("C_Item.GetItemInfo") then return nil end

    -- maxStack is the eighth return.
    local ok, _, _, _, _, _, _, _, maxStack = pcall(C_Item.GetItemInfo, itemID)

    if not ok or type(maxStack) ~= "number" or maxStack < 1 then return nil end

    maxStackMemo[itemID] = maxStack
    return maxStack
end

-- Enum.ItemBind values that bind an item the moment it exists: 1 is bind on
-- pickup, 4 is a quest item. Written out rather than read from Enum.ItemBind,
-- the same as Logic/Posting.lua, because this client's Enum tables have been
-- patchy. Bind on equip (2) and bind on use (3) still sell, so they are not
-- here.
local BINDS_ON_PICKUP = { [1] = true, [4] = true }

--- Does this item bind to whoever makes or loots it, so it can never be
--- auctioned?
--
-- @return true, false, or nil when the client has not cached the item yet.
--   Callers decide what unknown means; the Profit list keeps an unknown craft
--   rather than quietly dropping one that may well sell.
-- @return bindType, the raw number, for /bts soulbound to report.
function Util.IsBoundOnPickup(itemID)
    if not itemID then return nil end

    local known = bindTypeMemo[itemID]
    if known then return BINDS_ON_PICKUP[known] == true, known end

    if not Util.HasFunction("C_Item.GetItemInfo") then return nil end

    -- bindType is the fourteenth return.
    local ok, _, _, _, _, _, _, _, _, _, _, _, _, _, bindType =
        pcall(C_Item.GetItemInfo, itemID)

    if not ok or type(bindType) ~= "number" then return nil end
    bindTypeMemo[itemID] = bindType

    return BINDS_ON_PICKUP[bindType] == true, bindType
end

--- The price of one, given what a whole listing costs and how many it holds.
--
-- Item auctions quote the price of the stack, so a unit price is a division.
-- The trap is that the quantity is not always a stack count. This client has
-- been seen reporting the total available across every listing of the item
-- instead: 241 Linen Bags on offer, one 3s listing, 300 / 241 = 1, and the
-- sell list offered a bag for a copper.
--
-- Two things prove a quantity is not a stack count, and either means the price
-- is already per unit:
--
--   * it is more than the item can stack to at all -- a Linen Bag stacks to 1,
--     so 241 of them is a market, not a stack;
--   * the whole listing costs less than the number of items in it, so the
--     division would round to nothing.
--
-- When the stack size is not cached the old behaviour stands and the division
-- happens. That is the case worth watching, which is why `/bts listings`
-- prints the stack size it managed to read.
function Util.UnitPriceFromStack(itemID, totalPrice, quantity)
    if not quantity or quantity <= 1 then return totalPrice end
    if totalPrice < quantity then return totalPrice end

    local maxStack = Util.GetMaxStackSize(itemID)
    if maxStack and quantity > maxStack then return totalPrice end

    return math.floor(totalPrice / quantity)
end

--- The random suffix in an item link ("of the Wolf"), or nil for none.
--
-- The eighth field of item:ID:enchant:gem1:gem2:gem3:gem4:suffix:... in the
-- link. Negative numbers are suffixes too, so anything but 0 counts.
local function ParseSuffix(link)
    if type(link) ~= "string" then return nil end
    local body = link:match("item:([%-%d:]+)")
    if not body then return nil end

    local fields, index = {}, 0
    for field in (body .. ":"):gmatch("([^:]*):") do
        index = index + 1
        fields[index] = field
        if index >= 7 then break end
    end

    local suffix = tonumber(fields[7] or "")
    if not suffix or suffix == 0 then return nil end
    return suffix
end

function Util.LinkSuffix(link)
    -- Inside a pcall: a link read in an instance can be a secret value that
    -- raises when it is matched.
    local ok, suffix = pcall(ParseSuffix, link)
    return ok and suffix or nil
end

--- A player-readable label for an item: its clickable link when the client has
-- the item cached, its name otherwise, and only as a last resort the raw ID.
--
-- Item data is loaded lazily, so an uncached item genuinely has no name to show
-- until something requests it.
function Util.GetItemLabel(itemID)
    if not itemID then return "?" end

    if Util.HasFunction("C_Item.GetItemInfo") then
        local ok, name, link, quality = pcall(C_Item.GetItemInfo, itemID)
        if ok then
            if link then return link end
            if name then return Util.ColorItemName(itemID, name, quality) end
        end
    end

    -- Ask the client to cache it so the next render can show a real name.
    if Util.HasFunction("C_Item.RequestLoadItemDataByID") then
        pcall(C_Item.RequestLoadItemDataByID, itemID)
    end

    return L.Format("item %d", itemID)
end

--- Text without its colour codes, so a label's own colour shows. An item
--- link carries its quality colour inside it, which wins over SetTextColor:
--- a row greyed out as done, or green for a cheaper craft on another
--- character, still showed in the item's colour. Both colour codes go: the
--- "|cff1eff00" kind and the named "|cnIQ2:" kind newer clients put in item
--- links. Text that cannot be read (a value the game keeps from addons) comes
--- back as it was.
function Util.Uncolored(text)
    if type(text) ~= "string" then return text end

    local ok, plain = pcall(function()
        return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[%w_]+:", ""):gsub("|r", ""))
    end)
    if ok and type(plain) == "string" then return plain end
    return text
end

--- A character's name for display from a saved key, or "" when unknown.
--- Keys are now the character's GUID ("Player-..."), where the text before
--- the first dash is just "Player"; the name then comes from the character's
--- record. Old "Name-Realm" keys still read as the name.
function Util.CharacterName(key)
    if type(key) ~= "string" or key == "" then return "" end

    local record = ns.db and ns.db.characters and ns.db.characters[key]
    if type(record) == "table" and ns.Recipes and ns.Recipes.GetCharacterName then
        local name = ns.Recipes:GetCharacterName(key)
        if type(name) == "string" and name ~= "?" then return name end
    end

    if key:match("^Player%-") then return "" end
    return key:match("^([^%-]+)") or ""
end

--- The item's icon texture, or nil when the game has not got the item yet.
--
-- GetItemIconByID answers from the item's static data, so it usually works
-- before the item is fully cached; GetItemInfoInstant is the fallback. A miss
-- is not cached, so a later redraw picks the icon up.
local itemIcons = {}

function Util.GetItemIcon(itemID)
    if not itemID then return end

    local cached = itemIcons[itemID]
    if cached then return cached end

    local icon

    if Util.HasFunction("C_Item.GetItemIconByID") then
        local ok, value = pcall(C_Item.GetItemIconByID, itemID)
        if ok and value then icon = value end
    end

    if not icon and Util.HasFunction("C_Item.GetItemInfoInstant") then
        local ok, _, _, _, _, value = pcall(C_Item.GetItemInfoInstant, itemID)
        if ok and value then icon = value end
    end

    if icon then itemIcons[itemID] = icon end
    return icon
end

--- A rarity's colour (0 grey to 5 legendary), as the game itself draws it,
--- or nothing for a rarity it does not know.
function Util.GetQualityColor(quality)
    if type(quality) ~= "number" then return end

    -- ITEM_QUALITY_COLORS is the table the default UI itself reads, so the
    -- shades match Blizzard's exactly rather than being approximated here.
    local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if color then return color.r, color.g, color.b end

    if Util.HasFunction("C_Item.GetItemQualityColor") then
        local gotColor, r, g, b = pcall(C_Item.GetItemQualityColor, quality)
        if gotColor and r then return r, g, b end
    end
end

--- The item's rarity colour, as the game itself draws it.
--
-- Returns nothing when the item is not in the client's cache yet, so callers
-- fall back to their own colour rather than flashing white for one frame. The
-- request below means the next render usually has it.
--
-- `knownQuality`, when the caller already has the item's rarity (the
-- disenchant facts kept in the saved data), colours from that without asking
-- the client at all. The Disenchanting tab lists items read in earlier
-- sessions that the client's small cache no longer holds, and asking for
-- each of them is what pushed bag items out of it (Logic/Disenchant.lua).
--
-- Cached only once a colour is actually found: a miss must stay a miss, or an
-- item looked at before it loaded would be stuck uncoloured for the session.
local qualityColors = {}

function Util.GetItemQualityColor(itemID, knownQuality)
    if not itemID then return end

    local cached = qualityColors[itemID]
    if cached then return cached[1], cached[2], cached[3] end

    local quality = type(knownQuality) == "number" and knownQuality or nil

    if not quality then
        if not Util.HasFunction("C_Item.GetItemInfo") then return end

        local ok, _, _, fromClient = pcall(C_Item.GetItemInfo, itemID)
        if not ok or not fromClient then
            if Util.HasFunction("C_Item.RequestLoadItemDataByID") then
                pcall(C_Item.RequestLoadItemDataByID, itemID)
            end
            return
        end
        quality = fromClient
    end

    local r, g, b = Util.GetQualityColor(quality)
    if not r then return end

    qualityColors[itemID] = { r, g, b }
    return r, g, b
end

--- An item's plain name, never a link: the client's name, else the one the
--- caller already has, else "item 1234". For a label whose colour is set
--- with SetTextColor, which a link's own colour code would cover.
function Util.GetItemName(itemID, fallback)
    if itemID and Util.HasFunction("C_Item.GetItemInfo") then
        local ok, name = pcall(C_Item.GetItemInfo, itemID)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    if type(fallback) == "string" and fallback ~= "" then return Util.Uncolored(fallback) end
    if not itemID then return "?" end
    if Util.HasFunction("C_Item.RequestLoadItemDataByID") then
        pcall(C_Item.RequestLoadItemDataByID, itemID)
    end
    return L.Format("item %d", itemID)
end

--- A name in its item's rarity colour, for a name inside a sentence: only the
--- name is coloured, the words around it keep their own. Text that already
--- carries a colour (an item link) and an item whose rarity is not known yet
--- come back as they are.
function Util.ColorItemName(itemID, name, knownQuality)
    if type(name) ~= "string" or name == "" or name:find("|c", 1, true) then return name end
    local r, g, b = Util.GetItemQualityColor(itemID, knownQuality)
    if not r then return name end
    return ("|cff%02x%02x%02x%s|r"):format(
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5), name)
end

--- An item's name in its rarity colour, for a label that also carries words
--- in other colours: Util.GetItemName, coloured once the rarity is known.
function Util.ColoredItemName(itemID, fallback)
    return Util.ColorItemName(itemID, Util.GetItemName(itemID, fallback))
end

--- Run something only when the auction house is ready for another request.
--
-- The auction house throttles addon traffic, and exceeding it does not just
-- drop our request: it puts the whole auction house into "You're doing that
-- too fast", which blocks the player's own manual posting too. Ours is not
-- the only traffic that matters, so every throttled call waits its turn here
-- rather than firing and hoping.
--
-- This used to poll IsThrottledMessageSystemReady on its own half-second timer
-- and call the action the first time it said yes. That check reserves nothing,
-- so two callers polling independently both saw yes in the same frame and both
-- sent -- which is how a paced-looking addon still spent the player's
-- allowance. The wait now happens in one shared queue instead.
--
-- @param action   called when it is our turn to send
-- @param onGiveUp called if that turn never comes
-- @param opts     { name, key, priority, expires }, passed to AHQueue
function Util.WhenAuctionReady(action, onGiveUp, opts)
    opts = opts or {}

    if not ns.AHQueue then
        -- Only reachable if this file is loaded on its own, as the tests do.
        action()
        return
    end

    ns.AHQueue:Request({
        name = opts.name or "auction request",
        key = opts.key,
        priority = opts.priority,
        expires = opts.expires,
        onGiveUp = onGiveUp,
        send = function()
            action()
            return true
        end,
    })
end

--- Is this table field a secure value, and therefore uncallable by addons?
--
-- Returns nil when the client cannot answer, which is different from false:
-- "not protected" and "unknown" should not be confused when comparing two
-- client builds.
function Util.IsSecure(container, field)
    if type(issecurevariable) ~= "function" or type(container) ~= "table" then
        return nil
    end

    local ok, secure = pcall(issecurevariable, container, field)
    if not ok then return nil end

    return secure == true
end

--- Seconds elapsed rendered as a compact age, e.g. "3h", "12m", "just now".
function Util.FormatAge(seconds)
    if not seconds then return L["never"] end
    if seconds < 60 then return L["just now"] end
    if seconds < 3600 then return L.Format("%dm", math.floor(seconds / 60)) end
    if seconds < 86400 then return L.Format("%dh", math.floor(seconds / 3600)) end
    return L.Format("%dd", math.floor(seconds / 86400))
end

--- The same age, phrased to sit in a sentence: "seen %s".
--
-- FormatAge returns "just now" and "never", which are already complete
-- phrases, so callers that appended " ago" to it produced "just now ago".
function Util.FormatAgeAgo(seconds)
    local age = Util.FormatAge(seconds)
    if age == L["just now"] or age == L["never"] then return age end
    return L.Format("%s ago", age)
end

--- Round a price down to something an item auction will actually accept.
--
-- C_AuctionHouse.PostItem takes whole gold and silver only: a price carrying
-- any copper at all silently fails, which the client surfaces as an internal
-- error rather than anything readable. Commodities are unaffected and keep
-- copper precision, so this is only ever applied to item auctions.
--
-- Below a silver there is nothing to round down to, so the floor is one
-- silver. That can land above market value on a near-worthless item, but it
-- is the only price the server will take.
--- Whether item auctions take only whole silver. Era's older auction house
--- takes any copper, so there a price is only made whole.
function Util.SilverOnly()
    local compat = ns.Compat
    if not (compat and compat.Get) then return true end
    local ok, caps = pcall(compat.Get, compat)
    return not (ok and type(caps) == "table" and type(caps.auction) == "table"
        and caps.auction.mode == "legacy")
end

function Util.RoundToSilver(price)
    if type(price) ~= "number" then return nil end
    if not Util.SilverOnly() then return math.max(1, math.floor(price)) end
    if price < COPPER_PER_SILVER then return COPPER_PER_SILVER end
    return math.floor(price / COPPER_PER_SILVER) * COPPER_PER_SILVER
end

--- Round a price UP to something an item auction will accept.
--
-- Rounding down is right when there is a rival to get beneath: the price has
-- to be below theirs to sell first. With no rival there is nothing to get
-- beneath, and rounding down instead throws away up to a silver of a price
-- that was only ever an estimate -- enough, on a cheap craft, to put it under
-- what the materials cost and have the listing refused.
function Util.CeilToSilver(price)
    if type(price) ~= "number" then return nil end
    if not Util.SilverOnly() then return math.max(1, math.ceil(price)) end
    if price <= COPPER_PER_SILVER then return COPPER_PER_SILVER end
    return math.ceil(price / COPPER_PER_SILVER) * COPPER_PER_SILVER
end

--- Is this price one an item auction will accept?
function Util.IsWholeSilver(price)
    if not Util.SilverOnly() then return type(price) == "number" and price >= 1 and price % 1 == 0 end
    return type(price) == "number" and price >= COPPER_PER_SILVER
        and price % COPPER_PER_SILVER == 0
end
