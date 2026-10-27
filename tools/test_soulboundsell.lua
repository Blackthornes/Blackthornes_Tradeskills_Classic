-- A soulbound copy can never be auctioned. A green that binds when equipped
-- is bound once worn, and Era has no IsSellItemValid to say so, so such a
-- copy was offered on the Sell list and the auction house refused it.

local ns = {}
ns.COLORS = setmetatable({}, {__index = function() return "ffffffff" end})
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end

--------------------------------------------------------------------------------
-- A player with bags
--------------------------------------------------------------------------------

-- bags[bag][slot] = { itemID, stackCount, isLocked }
local bags = {}
local commodities = {}
local prices = {}
local bindTypes = {}
local reserved = {}
local recipes = {}
local qualities = {}

C_Container = {
    GetContainerNumSlots = function(bag) return bags[bag] and #bags[bag] or 0 end,
    GetContainerItemInfo = function(bag, slot)
        local entry = bags[bag] and bags[bag][slot]
        if not entry then return nil end
        return {
            itemID = entry.itemID,
            stackCount = entry.stackCount,
            isLocked = entry.isLocked and true or false,
            quality = entry.quality,
            isBound = entry.isBound,
            hyperlink = entry.link,
        }
    end,
    GetContainerItemLink = function(bag, slot)
        local entry = bags[bag] and bags[bag][slot]
        return entry and entry.link or nil
    end,
}

-- The client's own item data, in the order C_Item.GetItemInfo returns it.
-- bindType is the fourteenth, which is the one under test here; the vendor
-- price is deliberately zero so no loss floor muddies these rows.
C_Item = {
    GetItemInfo = function(itemID)
        return ("item%d"):format(itemID),  -- name
            nil,                            -- link
            qualities[itemID] or 1,         -- quality
            1, 1, "Trade Goods", "Cloth",   -- ilvl, minLevel, type, subType
            20,                             -- maxStack
            "", "",                         -- equipLoc, texture
            0,                              -- sellPrice
            0, 0,                           -- classID, subclassID
            bindTypes[itemID] or 0          -- bindType
    end,
    RequestLoadItemDataByID = function() end,
    -- Only asked when the slot's info says nothing about binding.
    IsBound = function(location)
        local entry = bags[location.bag] and bags[location.bag][location.slot]
        return entry and entry.boundByLocation == true or false
    end,
}

ItemLocation = {
    CreateFromBagAndSlot = function(_, bag, slot)
        return { bag = bag, slot = slot, IsValid = function() return true end }
    end,
}

CreateFrame = function()
    local frame = {}
    for _, name in ipairs({ "SetScript", "Show", "Hide", "SetPoint", "SetSize" }) do
        frame[name] = function() end
    end
    return frame
end

GetTime = function() return os.clock() end
time = time or os.time

ns.db = {}
ns.Config = {
    Get = function(_, k)
        if k == "undercutCopper" then return 1 end
        if k == "staleAfterSeconds" then return 48 * 3600 end
        if k == "postDuration" then return 2 end
        if k == "allowPostingAtALoss" then return false end
        return nil
    end,
    GetPriceTable = function() return {} end,
}

ns.Scanner = {
    isAuctionHouseOpen = false,
    IsCommodity = function(_, itemID) return commodities[itemID] == true end,
}

ns.Prices = {
    GetValue = function(_, itemID, key)
        local entry = prices[itemID]
        return entry and entry[key] or nil
    end,
}

ns.Inventory = {
    GetCarriedBags = function() return { 0, 1, 2, 3, 4, 5 } end,

    -- Locked slots still hold stock: the count is what is there, and whether
    -- any of it can be listed right now is a separate question.
    GetBagCount = function(_, itemID)
        local total = 0
        for _, slots in pairs(bags) do
            for _, entry in ipairs(slots) do
                if entry.itemID == itemID then total = total + entry.stackCount end
            end
        end
        return total
    end,
}

ns.Recipes = { GetAccountWide = function() return recipes end }

ns.Queue = {
    GetShoppingList = function()
        local list = {}
        for itemID in pairs(reserved) do list[#list + 1] = { itemID = itemID } end
        return list
    end,
}

ns.Cost = { FindRecipeForItem = function() return nil end }
ns.Cost.FindAnyRecipeForItem = ns.Cost.FindRecipeForItem

assert(loadfile(lfs_cwd .. "/Core/Util.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Profit.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Posting.lua"))("Blackthornes_TS", ns)

local Posting = ns.Posting

-- What a craft cost is not what this file is about, and the real Analyse wants
-- a whole recipe tree to answer. A flat figure keeps the crafted rows honest
-- without dragging costing into a test about which rows appear at all.
ns.Profit.Analyse = function(_, recipeID)
    return recipeID and { costPerUnit = 1 } or nil
end

--------------------------------------------------------------------------------

local failures = 0

local function check(label, got, expected)
    local ok = got == expected
    if not ok then failures = failures + 1 end
    print(("  %-52s %-8s %s"):format(label, tostring(got), ok and "ok" or
        ("FAILED, expected " .. tostring(expected))))
end

local function LineFor(lines, itemID)
    for _, line in ipairs(lines) do
        if line.itemID == itemID then return line end
    end
end

local ORB, BAND, CLOTH, CLOAK = 5000, 5001, 2589, 5002
local OWL = "|cff1eff00|Hitem:5000:0:0:0:0:0:5|h[Beaded Orb of the Owl]|h|r"
local BEAR = "|cff1eff00|Hitem:5001:0:0:0:0:0:7|h[Band of the Bear]|h|r"
local MONKEY = "|cff1eff00|Hitem:5001:0:0:0:0:0:9|h[Band of the Monkey]|h|r"

prices = { [ORB] = { market = 1400 }, [BAND] = { market = 900 }, [CLOTH] = { market = 40 },
    [CLOAK] = { market = 700 } }
commodities = { [CLOTH] = true }
qualities = { [ORB] = 2, [BAND] = 2, [CLOAK] = 2 }
bags = {
    [0] = {
        -- Worn once, so bound, though it binds when equipped.
        { itemID = ORB, stackCount = 1, quality = 2, isBound = true, link = OWL },
        -- Two of one ring: the bound one first in the bags.
        { itemID = BAND, stackCount = 1, quality = 2, isBound = true, link = BEAR },
        { itemID = BAND, stackCount = 1, quality = 2, isBound = false, link = MONKEY },
        { itemID = CLOTH, stackCount = 9, quality = 1, isBound = false },
        -- A client whose slot info says nothing: the location is asked.
        { itemID = CLOAK, stackCount = 1, quality = 2, boundByLocation = true },
    },
}

print("")
print("soulbound copies are never offered to post")

for _, opts in ipairs({
    { label = "Sell list", opts = { includeAll = true } },
    { label = "Post tab", opts = { includeAll = true, includeUnpriced = true } },
    { label = "drawer with held rows", opts = { includeAll = true, showHeld = true } },
}) do
    local lines = Posting:GetPostable(opts.opts)
    check(opts.label .. ": cloth is offered", LineFor(lines, CLOTH) ~= nil, true)
    check(opts.label .. ": the bound orb is not", LineFor(lines, ORB), nil)
    check(opts.label .. ": nor a cloak bound by its location", LineFor(lines, CLOAK), nil)
    local band = LineFor(lines, BAND)
    check(opts.label .. ": the free ring is", band ~= nil, true)
    check(opts.label .. ": one of the two rings", band and band.count, 1)
    check(opts.label .. ": as the copy that is free", band and band.link, MONKEY)
end

do
    local sellable, count = Posting:GetSellInfo(BAND)
    check("a click finds the free ring", sellable, true)
    check("and counts only it", count, 1)
    sellable = Posting:GetSellInfo(ORB)
    check("a click on the bound orb lists nothing", sellable, false)
    check("the ring is priced as the free copy", Posting:ListedCopy(BAND), MONKEY)
end

print("")

if failures > 0 then
    error(("%d check(s) failed"):format(failures), 0)
end

print("PASS -- soulbound copies stay off the Sell list")
print("")
