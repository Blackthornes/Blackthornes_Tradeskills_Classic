-- Blackthornes Tradeskills -- Logic/TSMPrices.lua
-- TradeSkillMaster's prices, as a last resort.
--
-- A player asked (2026-10-12) for TSM as a price source; the owner agreed
-- and said TSM may be named in public for it. Read only, inside a pcall,
-- through TSM's own addon API, with no TOC dependency:
--
--   TSM_API.GetCustomPriceValue(source, "i:<itemID>")   -- copper, or nil
--
-- It only fills a gap: Prices:GetValue asks here when neither your own scans
-- nor your guildmates' have a price for the item. Your own scans always win.
-- "market" reads DBRecent, "min" and "lowest" DBMinBuyout; "rival" is never
-- asked, since it is the price to undercut on this auction house now.
--
-- TSM's prices come from its desktop app, which may not cover Forever's
-- realms; then it answers nil and nothing changes.
--
-- "TSM Price Source:" (a player asked, the owner said build it, 2026-11-13)
-- lets the player name the price "market" reads: DBMarket, DBMinBuyout or
-- one of their own TSM custom prices. Saved as `tsmPriceSource` (account
-- wide, never rename it); nil or empty reads DBRecent (the owner,
-- 2026-11-13). A source TSM says is not valid (TSM_API.IsCustomPriceValid),
-- or one that gives no price for an item, falls back to DBRecent, and when
-- DBRecent has none either, quietly to DBMarket, so a price never goes
-- blank. "min" and "lowest" stay DBMinBuyout.
--
-- On unless unticked (`tsmPrices`, Settings, Sharing; never rename it).
-- Prices are read many times a redraw, so each answer is kept CACHE_FOR
-- seconds.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local TSMPrices = ns.NewModule("TSMPrices")

TSMPrices.CACHE_FOR = 60
TSMPrices.MAX_PRICE = 1e11            -- above this is not a price (10 million gold)
TSMPrices.DEFAULT_SOURCE = "DBRecent"
TSMPrices.FALLBACK_SOURCE = "DBMarket"  -- when DBRecent has no price for an item
TSMPrices.SOURCES = {
    market = TSMPrices.DEFAULT_SOURCE,
    min = "DBMinBuyout",
    lowest = "DBMinBuyout",
}

local cache = {}                      -- [which][itemID] = { value or false, at }
local validity = {}                   -- [source text] = true or false
TSMPrices.used = 0                    -- prices taken from TSM this session

function TSMPrices:IsOn()
    return not (ns.Config and ns.Config:Get("tsmPrices") == false)
end

--- TSM's API, or nil when TSM is not loaded.
function TSMPrices.Api()
    local api = rawget(_G, "TSM_API")
    if type(api) ~= "table" or type(api.GetCustomPriceValue) ~= "function" then return nil end
    return api
end

function TSMPrices:Loaded()
    return self.Api() ~= nil
end

--- The source the player typed, trimmed, or nil for the usual DBRecent.
function TSMPrices.Typed()
    local text = ns.Config and ns.Config:Get("tsmPriceSource")
    if type(text) ~= "string" then return nil end
    text = text:match("^%s*(.-)%s*$")
    if text == "" or text:lower() == TSMPrices.DEFAULT_SOURCE:lower() then return nil end
    return text
end

--- false when TSM says the typed source is not one it knows; true when it
--- is, or when TSM can't say (not loaded, or no check call).
function TSMPrices:SourceValid(text)
    text = text or self.Typed()
    if not text then return true end
    local api = self.Api()
    if not api or type(api.IsCustomPriceValid) ~= "function" then return true end
    if validity[text] == nil then
        local ok, valid = pcall(api.IsCustomPriceValid, text)
        -- A check that raises can't say, so the source is tried as typed.
        validity[text] = (not ok) or (valid and true or false)
    end
    return validity[text]
end

--- The source "market" reads: the player's own when TSM knows it, else DBRecent.
function TSMPrices:MarketSource()
    local text = self.Typed()
    if text and self:SourceValid(text) then return text end
    return self.DEFAULT_SOURCE
end

--- True while a typed source is one TSM says it doesn't know (the note
--- under the box in Settings).
function TSMPrices:SourceRefused()
    local text = self.Typed()
    return text ~= nil and self:Loaded() and not self:SourceValid(text)
end

local function Read(api, source, itemID)
    local ok, value = pcall(api.GetCustomPriceValue, source, "i:" .. itemID)
    if not ok or type(value) ~= "number" then return nil end
    if value ~= value or value <= 0 or value > TSMPrices.MAX_PRICE then return nil end
    return math.floor(value + 0.5)
end

--- TSM's price for one, in copper, or nil. Same `which` as Prices:GetValue.
function TSMPrices:GetValue(itemID, which)
    if type(itemID) ~= "number" or not self:IsOn() then return nil end
    local source = self.SOURCES[which or "market"]
    if not source then return nil end
    local custom
    if (which or "market") == "market" then
        local picked = self:MarketSource()
        if picked ~= source then custom = picked end
    end
    local api = self.Api()
    if not api then return nil end

    local key = which or "market"
    local kept = cache[key]
    if not kept then kept = {}; cache[key] = kept end
    local now = GetTime and GetTime() or 0
    local entry = kept[itemID]
    if entry and now - entry[2] < self.CACHE_FOR then
        return entry[1] or nil
    end

    local value = custom and Read(api, custom, itemID) or Read(api, source, itemID)
    if not value and key == "market" and source ~= self.FALLBACK_SOURCE then
        value = Read(api, self.FALLBACK_SOURCE, itemID)
    end
    kept[itemID] = { value or false, now }
    return value
end

--- Forget kept answers (the setting was changed).
function TSMPrices:Forget()
    cache = {}
    validity = {}
end

--- Called by Prices:GetValue when it hands out a TSM price.
function TSMPrices:Used()
    self.used = self.used + 1
end

function TSMPrices:Describe()
    if not self:IsOn() then return L["TSM prices are off."] end
    if not self:Loaded() then return L["TSM isn't loaded, so nothing changes."] end
    if self.used == 0 then
        return L["TSM is loaded. It hasn't filled any gaps yet this session."]
    end
    return L["TSM is loaded and is filling gaps in your prices."]
end
