-- The Sell list leaves off only what the player hid with the x. What it
-- would not sell (no price yet, a vendor pays more, the queue needs it all,
-- grey) stays on, dimmed, with a note saying why, and List all passes it by.

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
local vendorPaid = {}

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
        }
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

ns.Vendor = { GetPaid = function(_, id) return vendorPaid[id] end }
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

local SCRAPS, LEATHER, NOPRICE, QUEUED, GREY, HIDDEN, BOUND = 2934, 2318, 2589, 2592, 4865, 2770, 6948

local function LineFor(lines, itemID)
    for _, line in ipairs(lines) do
        if line.itemID == itemID then return line end
    end
end

prices = { [SCRAPS] = { market = 13 }, [LEATHER] = { market = 46 }, [QUEUED] = { market = 50 },
           [GREY] = { market = 30 }, [HIDDEN] = { market = 40 }, [BOUND] = { market = 40 } }
commodities = { [SCRAPS] = true, [LEATHER] = true, [NOPRICE] = true, [QUEUED] = true,
                [GREY] = true, [HIDDEN] = true, [BOUND] = true }
vendorPaid = { [SCRAPS] = 15, [LEATHER] = 10 }
reserved = { [QUEUED] = true }
qualities = { [GREY] = 0 }
bindTypes = { [BOUND] = 1 }
bags = {
    [0] = {
        { itemID = SCRAPS, stackCount = 13, quality = 1 },
        { itemID = LEATHER, stackCount = 9, quality = 1 },
        { itemID = NOPRICE, stackCount = 22, quality = 1 },
        { itemID = QUEUED, stackCount = 6, quality = 1 },
        { itemID = GREY, stackCount = 3, quality = 0 },
        { itemID = HIDDEN, stackCount = 5, quality = 1 },
        { itemID = BOUND, stackCount = 1, quality = 2 },
    },
}
Posting:SetIgnored(HIDDEN, true, "Hidden thing")

print("")
print("the Sell tab keeps what it won't sell, with why")

do
    local lines = Posting:GetPostable({ includeAll = true, showHeld = true, showNoted = true })
    check("leather the auction house pays for is a plain row",
        LineFor(lines, LEATHER) ~= nil and not LineFor(lines, LEATHER).noted, true)
    for _, case in ipairs({ { "no price yet", NOPRICE }, { "a vendor pays more", SCRAPS },
                            { "the queue needs it all", QUEUED }, { "grey", GREY } }) do
        local line = LineFor(lines, case[2])
        check(case[1] .. " stays on the list", line ~= nil, true)
        check(case[1] .. " is noted", line and line.noted, true)
        check(case[1] .. " says why", line and type(line.held) == "string" and line.held ~= "", true)
    end
    check("all 22 with no price show", (LineFor(lines, NOPRICE) or {}).postCount or (LineFor(lines, NOPRICE) or {}).count, 22)
    check("an item the player hid stays off", LineFor(lines, HIDDEN), nil)
    check("noted rows come after the rest", lines[1].itemID, LEATHER)
    local nextLine = Posting:GetNextPostable({ includeAll = true }, lines)
    check("List all picks the leather", nextLine and nextLine.itemID, LEATHER)
end

do
    local lines = Posting:GetPostable({ includeAll = true, showHeld = true })
    check("without showNoted, no price stays off", LineFor(lines, NOPRICE), nil)
    check("without showNoted, the vendor pile stays off", LineFor(lines, SCRAPS), nil)
    check("without showNoted, grey stays off", LineFor(lines, GREY), nil)
end

do
    Posting:SetIgnored(HIDDEN, false)
    local lines = Posting:GetPostable({ includeAll = true, showHeld = true, showNoted = true })
    check("restored, it comes back", LineFor(lines, HIDDEN) ~= nil, true)
end

print("")

if failures > 0 then
    error(("%d check(s) failed"):format(failures), 0)
end

print("PASS -- only hidden items leave the Sell list")
print("")
