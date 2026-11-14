-- Blackthornes Tradeskills -- UI/EnchantTooltip.lua
-- What an enchant's materials cost, on the enchant's own tooltip.
--
-- A player asked (2026-10-14, the owner agreeing): hovering an enchant in the
-- Enchanting window, or a linked enchant in chat, should say what the
-- materials cost. An enchant is a spell, not an item, so UI/ItemTooltip.lua
-- never sees it. This hooks spell tooltips and adds, for an Enchanting recipe
-- that makes no item:
--
--   Materials        1g 42s
--     2 Soul Dust      1g 10s
--     1 Lesser Mystic Essence   32s
--   You're short     1 Soul Dust
--   Known by         you
--
-- A recipe's ID is its spell ID, so the spell on the tooltip is the recipe.
-- Prices come from Logic/Cost.lua, the same as the craft queue, so the usual
-- order (your scans, guild, TSM, Auctionator, vendor) and the grey rule hold.
-- What you have counts bags and bank, as the queue's shopping list does.
--
-- Smooth play: a hover asks Cost for one recipe of a few materials, and the
-- lines are kept per spell until the bags change or `KEEP_FOR` passes, so
-- the game redrawing a tooltip costs a table lookup.
--
-- "Enchant costs on tooltips" on the Look page (`tooltipEnchantCosts`, on
-- unless unticked, never rename it). Blizzard's tooltips are hooked and
-- appended to; nothing of ours is written onto one.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local EnchantTooltip = ns.NewModule("EnchantTooltip")

local Util = ns.Util

-- Seconds a spell's lines are kept, when the bags have not moved.
EnchantTooltip.KEEP_FOR = 5

-- The tooltips a chat link and a hover open, for the script and setter hooks.
local TOOLTIP_NAMES = { "GameTooltip", "ItemRefTooltip" }

-- Calls that put a spell or a link on a tooltip, hooked only when neither
-- the data processor nor the script hook could be installed, and SetHyperlink
-- always on ItemRefTooltip: an enchant linked in chat opens there.
local FALLBACK_SETTERS = { "SetSpellByID", "SetHyperlink", "SetCraftSpell", "SetTradeSkillItem" }

--------------------------------------------------------------------------------
-- Talking to frames that may not answer
--------------------------------------------------------------------------------

local function Index(object, key) return object[key] end

local function Field(object, key)
    if type(object) ~= "table" then return nil end
    local ok, value = pcall(Index, object, key)
    if ok then return value end
    return nil
end

local function Try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function PlainNumber(value)
    local ok, number = pcall(function()
        if type(value) == "number" and value > 0 then return value end
        return nil
    end)
    return ok and number or nil
end

--------------------------------------------------------------------------------
-- The setting
--------------------------------------------------------------------------------

function EnchantTooltip:IsEnabled()
    if not ns.Config then return true end
    return ns.Config:Get("tooltipEnchantCosts") ~= false
end

--------------------------------------------------------------------------------
-- Which enchant
--------------------------------------------------------------------------------

--- The spell ID inside an enchant or spell link, or nil.
function EnchantTooltip.SpellIDFromLink(link)
    if type(link) ~= "string" then return nil end
    local ok, id = pcall(function()
        return link:match("|Henchant:(%d+)") or link:match("|Hspell:(%d+)")
            or link:match("^enchant:(%d+)") or link:match("^spell:(%d+)")
    end)
    if not ok or not id then return nil end
    return tonumber(id)
end

--- The spell a tooltip shows: the data a post call is handed, else
--- `GetSpell`, whose spell ID is its last number (retail gives name and ID,
--- older clients name, rank and ID).
function EnchantTooltip:SpellForTooltip(tooltip, data)
    local fromData = PlainNumber(Field(data, "id"))
    if fromData then return fromData end

    local getSpell = Field(tooltip, "GetSpell")
    if type(getSpell) ~= "function" then return nil end

    local results = { pcall(getSpell, tooltip) }
    if not results[1] then return nil end
    for i = #results, 2, -1 do
        local id = PlainNumber(results[i])
        if id then return id end
    end
    return nil
end

local function IsEnchanting(record)
    if record.profession == "Enchanting" then return true end
    local Recipes = ns.Recipes
    if Recipes and type(Recipes.IsEnchanting) == "function" then
        return Recipes.IsEnchanting({ skillLineID = record.skillLineID, name = record.profession }) == true
    end
    return false
end

--- The recipe for an enchant spell, or nil: one a character knows first
--- (its materials are the game's own), else the book's.
function EnchantTooltip:RecipeFor(spellID)
    -- The book is laid out once, after login (RecipeBook's sweep). Until it
    -- is, only known recipes are read, so hovering an action button before
    -- then never makes the game wait while it is built.
    local RecipeBook = ns.RecipeBook
    local book = RecipeBook and RecipeBook.merged and Try(RecipeBook.Get, RecipeBook, spellID)
    if RecipeBook and not RecipeBook.merged then self:BuildBookSoon() end
    local known = ns.Recipes and Try(ns.Recipes.GetAny, ns.Recipes, spellID)

    local record = known or book
    if type(record) ~= "table" then return nil end

    -- An enchant makes no item. A rod or an oil has its own item tooltip.
    if record.outputItemID or (book and book.outputItemID) then return nil end

    local check = record
    if not (check.profession or check.skillLineID) and book then check = book end
    if not IsEnchanting(check) then return nil end

    if type(record.reagents) ~= "table" or #record.reagents == 0 then
        if book and type(book.reagents) == "table" and #book.reagents > 0 then
            record = book
        else
            return nil
        end
    end

    return record, book or record
end

--- Lay the book out once, a moment after the first spell hover and never in
--- a fight, so an enchant nobody here knows (one linked in chat) has its
--- materials on the next hover.
function EnchantTooltip:BuildBookSoon()
    if self.bookAsked or not (C_Timer and C_Timer.After) then return end
    self.bookAsked = true
    local function Build()
        if InCombatLockdown and InCombatLockdown() then
            C_Timer.After(2, Build)
            return
        end
        if ns.RecipeBook then pcall(ns.RecipeBook.GetAll, ns.RecipeBook) end
        self:Forget()
    end
    C_Timer.After(1, Build)
end

--------------------------------------------------------------------------------
-- The lines
--------------------------------------------------------------------------------

local function Money(copper)
    return Util.FormatMoney(copper, { short = true })
end

-- The plain name, in its rarity colour once the client has the item.
local function ItemName(itemID)
    local name
    if C_Item and type(C_Item.GetItemInfo) == "function" then
        local ok, found = pcall(C_Item.GetItemInfo, itemID)
        if ok and type(found) == "string" then name = found end
    end
    if not name then
        local label = Util.GetItemLabel(itemID)
        name = Util.Uncolored and Util.Uncolored(label) or label
    end
    return Util.ColorItemName and Util.ColorItemName(itemID, name) or name
end

--- `{ label, value, muted }` lines, ItemTooltip's shape; empty for a spell
--- that is no enchant.
function EnchantTooltip:LinesFor(spellID)
    local lines = {}
    if not spellID or not ns.Cost then return lines end

    local record, bookRecord = self:RecipeFor(spellID)
    if not record then return lines end

    local ok, cost = pcall(ns.Cost.GetCraftCost, ns.Cost, spellID, nil, nil,
        { valueOwned = true, recipe = record })
    if not ok or type(cost) ~= "table" then return lines end

    lines[#lines + 1] = { L["Materials"],
        cost.priceable and cost.total and Money(cost.total)
            or (ns.RecipeBook and ns.RecipeBook.CostText and ns.RecipeBook:CostText({ costDetail = cost }))
            or L["materials not scanned"],
        not cost.priceable }

    local short = {}
    for _, reagent in ipairs(cost.reagents or {}) do
        local name = ItemName(reagent.itemID)
        lines[#lines + 1] = {
            "  " .. L.Format("%d %s", reagent.quantity or 0, name),
            reagent.lineCost and Money(reagent.lineCost) or L["not scanned yet"],
            not reagent.lineCost,
            color = (reagent.lineCost and "text") or nil,
            label = "muted",
        }
        if (reagent.shortfall or 0) > 0 then
            short[#short + 1] = L.Format("%d %s", reagent.shortfall, name)
        end
    end

    if #short > 0 then
        lines[#lines + 1] = { L["You're short"], table.concat(short, ", "), color = "warn" }
    else
        lines[#lines + 1] = { L["You have"], L["all of it"], color = "profit" }
    end

    if ns.RecipeBook and ns.RecipeBook.KnownByText then
        local knownOk, text, mine = pcall(ns.RecipeBook.KnownByText, ns.RecipeBook, bookRecord)
        if knownOk and text then
            lines[#lines + 1] = { L["Known by"], text, color = mine and "profit" or "text" }
        end
    end

    -- Where it goes on the character playing and how much better, when
    -- Blackthornes Equipment says it beats what is on now.
    local forYou = ns.Upgrades and ns.Upgrades.EnchantText and ns.Upgrades:EnchantText(spellID, true)
    if forYou then
        lines[#lines + 1] = { L["Best for you"], forYou, color = "profit" }
    end

    return lines
end

--- LinesFor, kept per spell until the bags move or KEEP_FOR passes.
function EnchantTooltip:CachedLines(spellID)
    local now = (GetTime and GetTime()) or 0
    local bags = ns.Inventory and ns.Inventory.changes or 0
    local kept = self.cache[spellID]
    if kept and kept.bags == bags and now - kept.at < self.KEEP_FOR then
        return kept.lines
    end
    local lines = self:LinesFor(spellID)
    self.cache[spellID] = { lines = lines, at = now, bags = bags }
    return lines
end

function EnchantTooltip:Forget()
    self.cache = {}
end

--------------------------------------------------------------------------------
-- Writing it on
--------------------------------------------------------------------------------

local decorated = setmetatable({}, { __mode = "k" })

local function Component(hex, first)
    return (tonumber(hex:sub(first, first + 1), 16) or 255) / 255
end

local function WriteLine(tooltip, line)
    local add = Field(tooltip, "AddDoubleLine")
    if type(add) ~= "function" then return end

    local labelColor = ns.COLORS[line.label or "accent"] or ns.COLORS.accent
    local valueColor = (line.color and ns.COLORS[line.color])
        or (line[3] and ns.COLORS.muted) or ns.COLORS.text

    Try(add, tooltip, line[1], line[2],
        Component(labelColor, 3), Component(labelColor, 5), Component(labelColor, 7),
        Component(valueColor, 3), Component(valueColor, 5), Component(valueColor, 7))
end

--- Append an enchant's lines. Returns what happened, for `/bts tip`.
function EnchantTooltip:Decorate(tooltip, data, spellID)
    if type(tooltip) ~= "table" then return "nospell" end
    if not self:IsEnabled() then return "quiet" end
    if self.writing then return "duplicate" end

    spellID = spellID or self:SpellForTooltip(tooltip, data)
    if not spellID then return "nospell" end

    local mark = decorated[tooltip]
    if mark and mark.spellID == spellID then
        local now = Try(Field(tooltip, "NumLines"), tooltip)
        if type(now) ~= "number" or now >= mark.lines then return "duplicate" end
    end

    local lines = self:CachedLines(spellID)
    if #lines == 0 then return "quiet" end
    if type(Field(tooltip, "AddDoubleLine")) ~= "function" then return "nospell" end

    -- On Shift (UI/TooltipShift.lua), asked here each time, never kept with
    -- the lines: with Shift up only "Hold Shift for more." goes on.
    local shift = ns.TooltipShift
    if shift and not shift:Shows("enchant") then
        self.writing = true
        pcall(shift.Held, shift, tooltip)
        self.writing = false
        return "held"
    end

    self.writing = true
    for i = 1, #lines do WriteLine(tooltip, lines[i]) end
    Try(Field(tooltip, "Show"), tooltip)
    self.writing = false

    decorated[tooltip] = { spellID = spellID, lines = Try(Field(tooltip, "NumLines"), tooltip) or 0 }
    self.shown = (self.shown or 0) + 1
    return "shown"
end

function EnchantTooltip:OnTooltip(tooltip, data, source, spellID)
    local ok, outcome = pcall(self.Decorate, self, tooltip, data, spellID)
    if not ok then
        self.writing = false
        return "nospell"
    end
    if outcome == "shown" then
        self.fired[source] = (self.fired[source] or 0) + 1
    end
    return outcome
end

--------------------------------------------------------------------------------
-- Getting told about a tooltip
--------------------------------------------------------------------------------

function EnchantTooltip:InstallDataProcessor()
    local processor = _G.TooltipDataProcessor
    local add = Field(processor, "AddTooltipPostCall")
    local types = Field(_G.Enum, "TooltipDataType")
    if type(add) ~= "function" or type(types) ~= "table" then return false end

    local installed = false
    -- A recipe in the profession list may come as its own kind; its ID is
    -- the recipe's, which is the spell's.
    for _, kind in ipairs({ "Spell", "RecipeRankInfo" }) do
        local dataType = Field(types, kind)
        if dataType ~= nil then
            local ok = pcall(add, dataType, function(tooltip, data)
                EnchantTooltip:OnTooltip(tooltip, data, "TooltipDataProcessor")
            end)
            installed = installed or ok
        end
    end
    return installed
end

function EnchantTooltip:InstallScriptHooks()
    local installed = false
    for _, name in ipairs(TOOLTIP_NAMES) do
        local tooltip = _G[name]
        local hook = Field(tooltip, "HookScript")
        if type(hook) == "function" then
            local ok = pcall(hook, tooltip, "OnTooltipSetSpell", function(shown)
                EnchantTooltip:OnTooltip(shown, nil, "OnTooltipSetSpell")
            end)
            installed = installed or ok
            pcall(hook, tooltip, "OnTooltipCleared", function(shown)
                decorated[shown] = nil
            end)
        end
    end
    return installed
end

function EnchantTooltip:InstallSetterHooks(fallback)
    local hook = _G.hooksecurefunc
    if type(hook) ~= "function" then return false end
    local installed = false

    -- A linked enchant opens in ItemRefTooltip by SetHyperlink, whatever
    -- else fires: its ID is read off the link itself.
    local ref = _G.ItemRefTooltip
    if type(Field(ref, "SetHyperlink")) == "function" then
        installed = (pcall(hook, ref, "SetHyperlink", function(shown, link)
            local spellID = EnchantTooltip.SpellIDFromLink(link)
            if spellID then EnchantTooltip:OnTooltip(shown, nil, "chat link", spellID) end
        end)) or installed
    end

    if fallback then
        local tooltip = _G.GameTooltip
        for _, name in ipairs(FALLBACK_SETTERS) do
            if type(Field(tooltip, name)) == "function" then
                installed = (pcall(hook, tooltip, name, function(shown, arg)
                    local spellID = name == "SetSpellByID" and PlainNumber(arg)
                        or (name == "SetHyperlink" and EnchantTooltip.SpellIDFromLink(arg)) or nil
                    EnchantTooltip:OnTooltip(shown, nil, "setter hooks", spellID or nil)
                end)) or installed
            end
        end
    end
    return installed
end

function EnchantTooltip:InstallHooks()
    local installed = {}
    installed["TooltipDataProcessor"] = self:InstallDataProcessor()
    installed["OnTooltipSetSpell"] = self:InstallScriptHooks()
    installed["setter hooks"] = self:InstallSetterHooks(
        not installed["TooltipDataProcessor"] and not installed["OnTooltipSetSpell"])
    self.installed = installed
    return installed
end

--- Lines for `/bts tip`: which hook has carried enchant costs so far.
function EnchantTooltip:ReportLines()
    local firing = {}
    for source, count in pairs(self.fired or {}) do
        firing[#firing + 1] = ("%s (%d)"):format(source, count)
    end
    table.sort(firing)
    return {
        { "enchant tooltips with costs", tostring(self.shown or 0) },
        { "enchant tooltip types seen", #firing > 0 and table.concat(firing, ", ") or "none yet" },
    }
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function EnchantTooltip:OnEnable()
    self.fired = {}
    self.cache = {}
    self.shown = 0
    self:InstallHooks()
end
