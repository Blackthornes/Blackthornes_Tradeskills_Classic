-- A price of the player's own on Ready to sell (UI/PriceEditor.lua).
--
-- Asked 2026-10-08: a player wanted to sell under market value to get rid of
-- a bad buy: see the suggested 7s 21c, change it to 6s and see 6 x 6s = 36s,
-- or type 40s for the lot and have it split per unit. The price lasts the
-- session, the guard against a fifth of market stands aside for it, the vendor
-- floor does not, and nothing saved changes unless asked.


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
    print(("  %-56s %-10s %s"):format(label, tostring(got), ok and "ok" or
        ("FAILED, expected " .. tostring(expected))))
end

local function LineFor(itemID)
    for _, line in ipairs(Posting:GetPostable({ includeAll = true })) do
        if line.itemID == itemID then return line end
    end
end

local CLOTH, SWORD = 4306, 7955

local function Reset()
    Posting.chosenQuantity = {}
    Posting.chosenPrice = {}
    commodities = { [CLOTH] = true }
    -- 7s 21c each: the player's example.
    prices = { [CLOTH] = { market = 721 }, [SWORD] = { market = 50000 } }
    vendor = { [CLOTH] = 100, [SWORD] = 500 }
    bags = {
        [0] = {
            { itemID = CLOTH, stackCount = 6 },
            { itemID = SWORD, stackCount = 1 },
        },
    }
end

print("")
print("the sums")

check("6s each stays 6s on a commodity", Posting:NormalisePrice(600, true), 600)
check("6s 50c on gear rounds down to whole silver", Posting:NormalisePrice(650, false), 600)
check("nothing typed is no price", Posting:NormalisePrice(0, true), nil)
check("40s over 6 is 6s 66c each", Posting:PriceFromTotal(4000, 6, true), 666)
check("36s over 6 is 6s each", Posting:PriceFromTotal(3600, 6, true), 600)
check("a total over nothing is no price", Posting:PriceFromTotal(4000, 0, true), nil)

print("")
print("setting a price")

Reset()
do
    local line = LineFor(CLOTH)
    local suggested = line.unitPrice
    check("the suggestion is on the line", line.suggestedPrice, suggested)

    Posting:ApplyPrice(line, 600)
    check("the line lists at 6s", line.unitPrice, 600)
    check("and says it is the player's", line.priceBasis, "chosen")
    check("6 x 6s = 36s", line.postTotal, 3600)
    check("the suggestion is kept beside it", line.suggestedPrice, suggested)
    check("remembered for the item", Posting:GetChosenPrice(CLOTH), 600)

    local again = LineFor(CLOTH)
    check("the next redraw lists at it too", again.unitPrice, 600)
    check("still marked as the player's", again.priceBasis, "chosen")
    check("with the suggestion beside it", again.suggestedPrice, suggested)

    Posting:ApplyQuantity(again, 4)
    check("fewer of them: the total follows", again.postTotal, 2400)

    Posting:ApplyPrice(again, nil)
    check("Use suggested goes back to it", again.unitPrice, suggested)
    check("and forgets the price", Posting:GetChosenPrice(CLOTH), nil)
    check("with the suggested reason back", again.priceBasis == "chosen", false)
end

print("")
print("guards")

Reset()
check("a fifth of market is guarded normally", Posting:GetPriceFloor(SWORD), 10000)
check("but not for a price typed by hand", Posting:GetPriceFloor(SWORD, true), 500)
check("the vendor floor still holds by hand", Posting:RefusesEarly(SWORD, 400, true), true)
check("a dump at 20s goes through by hand", Posting:RefusesEarly(SWORD, 2000, true), false)
check("the same 20s is refused when not typed", Posting:RefusesEarly(SWORD, 2000), true)

do
    local line = LineFor(CLOTH)
    Posting:ApplyPrice(line, 50)
    check("under what a vendor pays is a loss", line.atALoss, true)
    check("and says why", line.lossReason, "vendor")
    Posting:ApplyPrice(line, 600)
    check("6s is not", line.atALoss, false)
end

print("")
print("listing")

Reset()
do
    local confirmed
    Posting.CanPost = function() return true end
    Posting.Confirm = function(_, itemID, quantity, price, check)
        confirmed = { itemID = itemID, quantity = quantity, price = price, byHand = check and check.byHand }
    end

    Posting:SetChosenPrice(CLOTH, 600)
    Posting:Request(CLOTH, 6, 721)
    check("the player's price is what is asked about", confirmed and confirmed.price, 600)
    check("marked as typed by hand", confirmed and confirmed.byHand, true)

    Posting:SetChosenPrice(CLOTH, nil)
    confirmed = nil
    Posting:Request(CLOTH, 6, 721)
    check("without one, the suggested price as before", confirmed and confirmed.price, 721)
    check("not by hand", confirmed and confirmed.byHand, false)
end

print("")
print("the editor's notes")

ns.Theme = {}
ns.Widgets = {}
ns.Profit.NetFromListing = function(_, _, price) return price * 0.95 end
assert(loadfile(lfs_cwd .. "/UI/PriceEditor.lua"))("Blackthornes_TS", ns)

Reset()
do
    local line = LineFor(CLOTH)
    local notes, refused = ns.PriceEditor.Notes(line, 600, 6)
    local text = {}
    for _, note in ipairs(notes) do text[#text + 1] = note[1] end
    text = table.concat(text, " | ")
    check("6s is not refused", refused, false)
    check("says how far under market", text:find("17% under market", 1, true) ~= nil, true)
    check("says what comes back after the cut", text:find("You get about", 1, true) ~= nil, true)

    notes, refused = ns.PriceEditor.Notes(line, 50, 6)
    check("under the vendor price is refused", refused, true)
    check("first note is the refusal", notes[1][2], "loss")

    notes, refused = ns.PriceEditor.Notes(line, nil, 6)
    check("no price yet cannot be listed", refused, true)
end

print("")
print("when cheaper, wait")

Reset()
do
    local realPrice = Posting.GetPostPrice
    Posting.GetPostPrice = function(self, itemID, link)
        if itemID == CLOTH then return 900, "floor", "the least you set", false, true end
        return realPrice(self, itemID, link)
    end

    local held
    for _, line in ipairs(Posting:GetPostable({ includeAll = true, showHeld = true })) do
        if line.itemID == CLOTH then held = line end
    end
    check("the row still shows on the drawer", held ~= nil, true)
    check("dimmed, saying why", held and held.held, "Waiting, others are selling for less")
    check("left out of what List all takes", LineFor(CLOTH), nil)
    check("other items list as before", LineFor(SWORD) ~= nil, true)

    Posting:SetChosenPrice(CLOTH, 950)
    local chosen = LineFor(CLOTH)
    check("a price typed by hand lists it anyway", chosen and chosen.unitPrice, 950)
    Posting:SetChosenPrice(CLOTH, nil)

    Posting.GetPostPrice = realPrice
end

print("")
if failures > 0 then
    print(("%d check(s) failed"):format(failures))
    os.exit(1)
end
print("all checks passed")
