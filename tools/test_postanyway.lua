-- "List Anyway:" (Forever's Bypass Disallowed Postings) (postAnyway, 2026-10-31).
--
-- Off, nothing changes: what the other addons keep and what a queued craft
-- needs are held back as before. Ticked, every one of them lists:
--   * no row is held, and the whole stack is offered;
--   * List all picks them, and the summary counts them;
--   * the price floor and the early refusal step aside.
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

C_Container = {
    GetContainerNumSlots = function(bag) return bags[bag] and #bags[bag] or 0 end,
    GetContainerItemInfo = function(bag, slot)
        local entry = bags[bag] and bags[bag][slot]
        if not entry then return nil end
        return {
            itemID = entry.itemID,
            stackCount = entry.stackCount,
            isLocked = entry.isLocked and true or false,
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
            1,                              -- quality
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
sisterKeepsOn = true
altUpgradesOn = true
ns.Config = {
    Get = function(_, k)
        if k == "undercutCopper" then return 1 end
        if k == "staleAfterSeconds" then return 48 * 3600 end
        if k == "postDuration" then return 2 end
        if k == "allowPostingAtALoss" then return false end
        if k == "sellHoldsSisterKeeps" then return sisterKeepsOn end
        if k == "sellHoldsAltUpgrades" then return altUpgradesOn end
        if k == "postAnyway" then return postAnyway end
        return nil
    end,
    GetPriceTable = function() return {} end,
    GetCharacterKey = function() return playerKey end,
}
playerKey = "Player-1-ME"

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

ns.Recipes = {
    GetAccountWide = function() return recipes end,
    GetCharacterName = function(_, key) return key == "Player-1-ALT" and "Ana Stormwood" or "?" end,
}
ns.FarmerGoals = { ItemName = function(itemID) return ("item%d"):format(itemID) end }

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
assert(loadfile(lfs_cwd .. "/Logic/KeepHere.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/SisterKeeps.lua"))("Blackthornes_TS", ns)

local Posting = ns.Posting

-- What a craft cost is not what this file is about, and the real Analyse wants
-- a whole recipe tree to answer. A flat figure keeps the crafted rows honest
-- without dragging costing into a test about which rows appear at all.
ns.Profit.Analyse = function(_, recipeID)
    return recipeID and { costPerUnit = 1 } or nil
end

local failures = 0

local function check(label, got, expected)
    local ok = got == expected
    if not ok then failures = failures + 1 end
    print(("  %-52s %-30s %s"):format(label, tostring(got), ok and "ok" or
        ("FAILED, expected " .. tostring(expected))))
end

local GOAL, UPGRADE, ALTGEAR, FOOD, KEEP, SET, QUEST, CLAM, PLAIN =
    2589, 7955, 7956, 4536, 3466, 6948, 4306, 7973, 2770
local MAILHERE, MAILAWAY = 4655, 5503

local function LineFor(lines, itemID)
    for _, line in ipairs(lines) do
        if line.itemID == itemID then return line end
    end
end

local function Sisters()
    BlackthornesFarmer = {
        Butler = { Advise = function(_, id)
            if id == GOAL then return { goal = "item2589", have = 20, target = 12, need = 0 } end
        end },
        Value = { Contents = function(_, name) if name == "item7973" then return 4400 end end },
    }
    BlackthornesEquipment = {
        Butler = { Advise = function(_, item)
            if item == UPGRADE then return { upgrade = "now", gain = 6.2 } end
            if item == ALTGEAR then return { alt = { key = "Player-1-ALT", gain = 9 } } end
        end },
    }
    BlackthornesPets = {
        Butler = { Advise = function(_, id) if id == FOOD then return { eats = true, buff = false } end end },
    }
    BlackthornesButler = {
        Verdicts = {
            Choice = function(_, id)
                if id == KEEP then return "keep" end
                if id == MAILHERE then return "mail", "Ana Stormwood" end
                if id == MAILAWAY then return "mail", "Bo Ashgrove" end
            end,
            IsMe = function(_, name) return name == "Ana Stormwood" end,
            InSet = function(_, id) if id == SET then return "Tank" end end,
        },
        Quests = { Reason = function(_, id) if id == QUEST then return "Spider's Silk needs 4 more" end end },
    }
end

local ALL = { GOAL, UPGRADE, ALTGEAR, FOOD, KEEP, SET, QUEST, CLAM, PLAIN }

local function Reset(on)
    postAnyway = on
    Posting.chosenQuantity = {}
    ns.SisterKeeps:Forget()
    sisterKeepsOn = true
    altUpgradesOn = true
    commodities = { [GOAL] = true, [FOOD] = true, [KEEP] = true, [QUEST] = true, [CLAM] = true, [PLAIN] = true }
    reserved, recipes, bindTypes = { [PLAIN] = true }, {}, {}
    prices = {}
    for _, id in ipairs(ALL) do prices[id] = { market = 1000 } end
    bags = { [0] = {} }
    for _, id in ipairs(ALL) do
        table.insert(bags[0], { itemID = id, stackCount = (id == GOAL and 20) or ((id == UPGRADE or id == ALTGEAR or id == SET) and 1) or 3 })
    end
    Sisters()
end

print("\noff: held back as before")
Reset(nil)
do
    check("the setting is off unless ticked", Posting:PostsAnyway(), false)
    local lines = Posting:GetPostable({ includeAll = true, showHeld = true })
    check("the goal keeps its target", LineFor(lines, GOAL) and LineFor(lines, GOAL).count, 8)
    check("an upgrade is held", LineFor(lines, UPGRADE) and LineFor(lines, UPGRADE).held, "An upgrade for you, +6%")
    check("pet food is held", LineFor(lines, FOOD) and LineFor(lines, FOOD).held, "Your pet eats this")
    check("a queued craft's material is left out", LineFor(lines, PLAIN), nil)
    check("only the goal's spare is counted", (Posting:GetSummary(nil, lines)), 1)
end

print("\nticked: everything lists")
Reset(true)
do
    check("the setting reads on", Posting:PostsAnyway(), true)
    local lines = Posting:GetPostable({ includeAll = true, showHeld = true })
    for _, id in ipairs(ALL) do
        local line = LineFor(lines, id)
        check(("item %d is on the list"):format(id), line ~= nil, true)
        check(("item %d is not held"):format(id), line and line.held, nil)
    end
    check("the whole goal stack", LineFor(lines, GOAL).count, 20)
    check("the queued craft's material, all of it", LineFor(lines, PLAIN) and LineFor(lines, PLAIN).count, 3)
    check("every row counts", (Posting:GetSummary(nil, lines)), #ALL)

    local picked = {}
    for _, line in ipairs(lines) do
        if Posting:GetNextPostable(nil, { line }) then picked[line.itemID] = true end
    end
    check("List all would pick the upgrade", picked[UPGRADE], true)
    check("and the pet food", picked[FOOD], true)

    check("the price floor steps aside", Posting:IsUnderFloor({ itemID = PLAIN, unitPrice = 1 }), false)
    check("and so does the early refusal", Posting:RefusesEarly(PLAIN, 1, true), false)
end

print("\nunticked again, it holds again")
Reset(false)
do
    local lines = Posting:GetPostable({ includeAll = true, showHeld = true })
    check("the upgrade is held again", LineFor(lines, UPGRADE) and LineFor(lines, UPGRADE).held, "An upgrade for you, +6%")
end

BlackthornesFarmer, BlackthornesEquipment, BlackthornesPets, BlackthornesButler = nil, nil, nil, nil
sisterKeepsOn, postAnyway = nil, nil

print("")
if failures > 0 then
    print(("%d check(s) failed"):format(failures))
    error(("%d check(s) failed"):format(failures), 0)
end
print("all checks passed")
