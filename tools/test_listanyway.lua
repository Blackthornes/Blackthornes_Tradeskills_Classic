-- A List click on a stack Tradeskills would refuse (the owner, 2026-10-31).
--
-- The List It / Skip box asks instead, with the reason, and List It lists
-- that one stack with the guards stepped aside. List Next still passes such
-- stacks by, and a refusal with no click behind it (no quantity) is as before.

local ns = {}
ns.COLORS = setmetatable({}, {__index = function() return "ffffffff" end})
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() end
ns.Print, ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end, function() end

--------------------------------------------------------------------------------
-- A player with bags
--------------------------------------------------------------------------------

-- bags[bag][slot] = { itemID, stackCount }
local bags = {}
local commodities = {}
local prices = {}

C_Container = {
    GetContainerNumSlots = function(bag) return bags[bag] and #bags[bag] or 0 end,
    GetContainerItemInfo = function(bag, slot)
        local entry = bags[bag] and bags[bag][slot]
        if not entry then return nil end
        return { itemID = entry.itemID, stackCount = entry.stackCount, isLocked = false }
    end,
}

-- MakeLocation only needs something that answers IsValid.
ItemLocation = {
    CreateFromBagAndSlot = function(_, bag, slot)
        return { bag = bag, slot = slot, IsValid = function() return true end }
    end,
}

ns.Util = {
    Clamp = function(v, l, h) return math.max(l, math.min(h, v)) end,
    Count = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end,
    FormatMoney = function(c) return tostring(c) end,
    FormatAge = function() return "" end,
    GetItemLabel = function(i) return "item" .. tostring(i) end,
    -- Nothing from C_AuctionHouse: the postable count then comes from the bags
    -- and the deposit is unknown, which is the away-from-the-auction-house case
    -- and the one that keeps this test about quantities.
    HasFunction = function() return false end,
}

-- Core/Util.lua builds a worker frame at load time. Nothing here drives it.
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
    GetTable = function() return prices end,
    LowestListed = function(record) return record.rivalMin end,
}

ns.Inventory = {
    -- The containers the character carries, reagent bag last. Posting walks
    -- whatever this returns rather than keeping a range of its own, which is
    -- how a reagent bag came to be invisible to the sell list.
    GetCarriedBags = function() return { 0, 1, 2, 3, 4, 5 } end,

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

ns.Recipes = { GetAccountWide = function() return {} end }
ns.Queue = { GetShoppingList = function() return {} end }

-- Nothing here is craftable, so the profit side stays out of the way and the
-- prices are whatever the price table says.
ns.Cost = { FindRecipeForItem = function() return nil end }
ns.Cost.FindAnyRecipeForItem = ns.Cost.FindRecipeForItem

assert(loadfile(lfs_cwd .. "/Core/Util.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Profit.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/Posting.lua"))("Blackthornes_TS", ns)

local Posting = ns.Posting

local vendor = {}
ns.Util.GetVendorSellPrice = function(itemID) return vendor[itemID] end

local failures = 0

local function check(label, got, expected)
    local ok = got == expected
    if not ok then failures = failures + 1 end
    print(("  %-56s %-24s %s"):format(label, tostring(got), ok and "ok" or
        ("FAILED, expected " .. tostring(expected))))
end

local SWORD = 2488
prices = { [SWORD] = { market = 50000 } }
vendor[SWORD] = 500

print("\nwhat would stop it")
local kind, warn = Posting:RefusalOf(SWORD, 400, true)
check("under a vendor's price, typed by hand", kind, "floor")
check("says a vendor pays more", warn, "This is under what a vendor pays.")
kind, warn = Posting:RefusalOf(SWORD, 2000)
check("a fifth of market", kind, "floor")
check("says far under the usual", warn, "This is far under what it usually sells for.")
check("a fair price is not stopped", Posting:RefusalOf(SWORD, 40000), nil)

print("\na List click asks")
local shown
Posting.ShowConfirm = function(_, itemID, quantity, price, text, byHand, anyway)
    shown = { itemID = itemID, quantity = quantity, price = price, text = text, anyway = anyway }
end
Posting.BuildConfirmText = function(_, _, _, _, chk) return "box" .. (chk.warn and (":" .. chk.warn) or "") end
check("refused with a click: the box takes it", Posting:RefusesEarly(SWORD, 2000, false, 3), true)
check("the box is for this stack", shown and shown.quantity, 3)
check("its List It lists anyway", shown and shown.anyway, true)
check("it says why", shown and shown.text, "box:This is far under what it usually sells for.")

shown = nil
check("no click behind it: refused as before", Posting:RefusesEarly(SWORD, 2000), true)
check("and no box", shown, nil)
check("a fair price with a click is not refused", Posting:RefusesEarly(SWORD, 40000, false, 3), false)

print("\nList It said once stands for the next click")
local posted
local realPost = Posting.Post
Posting.Post = function(_, itemID, quantity, price, byHand, anyway) posted = { anyway = anyway } return true end
Posting.saidAnyway = { [SWORD] = { price = 2000, at = GetTime() } }
shown = nil
check("the next click lists", Posting:AskAnyway(SWORD, 3, 2000, false), true)
check("with the guards aside", posted and posted.anyway, true)
check("without asking again", shown, nil)
posted = nil
check("another price asks again", Posting:AskAnyway(SWORD, 3, 1900, false), true)
check("and lists nothing yet", posted, nil)
Posting.Post = realPost
Posting.saidAnyway = nil

print("")
if failures > 0 then error(("%d check(s) failed"):format(failures), 0) end
print("all checks passed")
