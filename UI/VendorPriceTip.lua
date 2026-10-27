-- Blackthornes Tradeskills -- UI/VendorPriceTip.lua
-- What a vendor pays for one, as the last line of an item's tooltip (the
-- owner asked 2026-10-27: Era's tooltips say nothing about it, and the
-- "Stack of" line read as if it might be).
--
-- Last line: Butler's verdict line goes in a second after the loading
-- screen, and ItemTooltip's "Stack of" line is added after the bag call
-- returns (its SetBagItem post-hook). So this goes in later than both
-- (`DELAY`), and a tooltip drawn for a bag slot gets the line from a
-- SetBagItem post-hook of its own, which runs after ItemTooltip's. Anything
-- else (a link, the bank, a vendor's list) gets it from the item hook.
--
-- It follows the item value setting (`showValueOnItemTooltips`, Off, Shift
-- or Always), so it needs no setting of its own. Greys get it too: Era shows
-- no vendor price for them either. Nothing is written on the game's
-- tooltips but a line; what has been decorated lives in a weak table.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local VendorPriceTip = ns.NewModule("VendorPriceTip")

-- Seconds after the first loading screen before the hooks go in: after
-- Butler's verdict line (1 s).
VendorPriceTip.DELAY = 1.5

local TOOLTIPS = { "GameTooltip", "ItemRefTooltip" }

-- tooltip -> item ID the line went on for, until the tooltip is cleared.
local done = setmetatable({}, { __mode = "k" })

local function Field(object, key)
    if type(object) ~= "table" then return nil end
    local ok, value = pcall(function() return object[key] end)
    if ok then return value end
    return nil
end

function VendorPriceTip.Forget(tooltip)
    done[tooltip] = nil
end

--- Shown at all: the item value lines' setting and their Shift choice.
function VendorPriceTip:Shows()
    local tip = ns.ItemTooltip
    if tip and tip.IsEnabled and not tip:IsEnabled() then return false end
    if tip and tip.Shows and not tip.Shows("value") then return false end
    return true
end

--- The text for one, or nil when a vendor won't buy it.
function VendorPriceTip.Text(itemID)
    local util = ns.Util
    if not (itemID and util and util.GetVendorSellPrice) then return nil end
    local ok, price = pcall(util.GetVendorSellPrice, itemID)
    if not ok or type(price) ~= "number" or price <= 0 then return nil end
    return util.FormatMoney(price, { short = true })
end

--- The bag and slot a tooltip's owner is, when it is a bag's item button
--- holding that item (as Butler's VerdictTip reads it).
function VendorPriceTip.OwnerSlot(tooltip, itemID)
    local ok, bag, slot = pcall(function()
        local owner = tooltip:GetOwner()
        if type(owner) ~= "table" then return nil end
        local bagID
        if type(owner.GetBagID) == "function" then
            bagID = owner:GetBagID()
        elseif type(owner.GetParent) == "function" then
            bagID = owner:GetParent():GetID()
        end
        return bagID, owner:GetID()
    end)
    if not ok or type(bag) ~= "number" or type(slot) ~= "number" or slot < 1 then return nil end
    local container = _G.C_Container
    local get = Field(container, "GetContainerItemID")
    if type(get) ~= "function" then return nil end
    local idOk, id = pcall(get, bag, slot)
    if idOk and id == itemID then return bag, slot end
    return nil
end

--- Put the line on, once per draw.
-- @return true when a line went on
function VendorPriceTip:Add(tooltip, itemID)
    if type(tooltip) ~= "table" or not itemID then return false end
    if done[tooltip] == itemID then return false end
    if not self:Shows() then return false end

    local text = self.Text(itemID)
    if not text then return false end

    local add = Field(tooltip, "AddDoubleLine")
    if type(add) ~= "function" then return false end

    done[tooltip] = itemID
    local accent = ns.COLORS and ns.COLORS.accent or "ffffd100"
    local r = (tonumber(accent:sub(3, 4), 16) or 255) / 255
    local g = (tonumber(accent:sub(5, 6), 16) or 255) / 255
    local b = (tonumber(accent:sub(7, 8), 16) or 255) / 255
    pcall(add, tooltip, L["Vendor price"], text, r, g, b, 1, 1, 1)
    pcall(Field(tooltip, "Show"), tooltip)
    return true
end

--- The item hook: everything but a bag slot, which waits for SetBagItem.
function VendorPriceTip:OnItem(tooltip, data)
    local tip = ns.ItemTooltip
    if not (tip and tip.ItemForTooltip) then return end
    local ok, itemID = pcall(tip.ItemForTooltip, tip, tooltip, data)
    if not ok or not itemID then return end
    if tooltip == _G.GameTooltip and self.bagHooked and self.OwnerSlot(tooltip, itemID) then
        return
    end
    self:Add(tooltip, itemID)
end

--- After the game drew a bag slot (and ItemTooltip added its stack line).
function VendorPriceTip:OnBagItem(tooltip, bag, slot)
    local get = Field(_G.C_Container, "GetContainerItemID")
    if type(get) ~= "function" then return end
    local ok, itemID = pcall(get, bag, slot)
    if ok and type(itemID) == "number" then self:Add(tooltip, itemID) end
end

function VendorPriceTip:Install()
    if self.installed then return self.installed end
    local hooked = {}

    local hook = _G.hooksecurefunc
    local game = _G.GameTooltip
    if type(hook) == "function" and type(Field(game, "SetBagItem")) == "function" then
        if pcall(hook, game, "SetBagItem", function(shown, bag, slot)
            VendorPriceTip:OnBagItem(shown, bag, slot)
        end) then
            self.bagHooked = true
            hooked[#hooked + 1] = "bag slots"
        end
    end

    local processor = _G.TooltipDataProcessor
    local enum = _G.Enum
    local itemType = type(enum) == "table" and type(enum.TooltipDataType) == "table"
        and enum.TooltipDataType.Item
    if type(processor) == "table" and type(processor.AddTooltipPostCall) == "function" and itemType ~= nil then
        if pcall(processor.AddTooltipPostCall, itemType, function(tooltip, data)
            VendorPriceTip:OnItem(tooltip, data)
        end) then
            hooked[#hooked + 1] = "post call"
        end
    end

    for _, name in ipairs(TOOLTIPS) do
        local tooltip = _G[name]
        local hookScript = Field(tooltip, "HookScript")
        if type(hookScript) == "function" then
            if pcall(hookScript, tooltip, "OnTooltipSetItem", function(shown)
                VendorPriceTip:OnItem(shown, nil)
            end) then
                hooked[#hooked + 1] = name
            end
            pcall(hookScript, tooltip, "OnTooltipCleared", function(shown)
                VendorPriceTip.Forget(shown)
            end)
        end
    end

    self.installed = #hooked > 0 and table.concat(hooked, ", ") or "none"
    return self.installed
end

function VendorPriceTip:OnEnable()
    ns.RegisterEvent(self, "PLAYER_ENTERING_WORLD", function()
        if VendorPriceTip.installed or VendorPriceTip.waiting then return end
        VendorPriceTip.waiting = true
        local ok = pcall(C_Timer.After, VendorPriceTip.DELAY, function()
            VendorPriceTip:Install()
        end)
        if not ok then VendorPriceTip:Install() end
    end)
end
