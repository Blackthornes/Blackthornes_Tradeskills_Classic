-- Blackthornes Tradeskills -- Logic/FarmerGoals.lua
-- Hands a material from the Gather tab to Blackthornes Farmer as a gathering
-- goal (2026-09-27).
--
-- Farmer is optional. Without it nothing here shows and nothing is called.
-- With it, Farmer's own Goals:Set does the work, so the goal is exactly what
-- "/farm goal Copper Ore 40" would make: counted from the bags, shown on
-- Farmer's Goals panel, with its milestones and finish fanfare.
--
-- Read through `_G.BlackthornesFarmer`, inside a pcall. Farmer's CLAUDE.md
-- asks its side to keep that global, `Goals`, `Goals:Find(name)`,
-- `Goals:Set(name, amount)`, `Goals:Remove(name)` and `GoalsUI:Show()`
-- stable.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local FarmerGoals = ns.NewModule("FarmerGoals")

--- Farmer's Goals module, or nil when Farmer is not loaded (or too old to
--- have goals).
function FarmerGoals:Farmer()
    local farmer = rawget(_G, "BlackthornesFarmer")
    if type(farmer) ~= "table" then return nil end

    local goals = farmer.Goals
    if type(goals) ~= "table" or type(goals.Set) ~= "function" then return nil end
    return farmer
end

function FarmerGoals:Available()
    return self:Farmer() ~= nil
end

--- The plain name of an item (no colour, no brackets), or nil until the
--- client has it.
local function ItemName(itemID)
    if type(C_Item) == "table" then
        if type(C_Item.GetItemNameByID) == "function" then
            local ok, name = pcall(C_Item.GetItemNameByID, itemID)
            if ok and type(name) == "string" and name ~= "" then return name end
        end
        if type(C_Item.GetItemInfo) == "function" then
            local ok, name = pcall(C_Item.GetItemInfo, itemID)
            if ok and type(name) == "string" and name ~= "" then return name end
        end
    end
    if type(GetItemInfo) == "function" then
        local ok, name = pcall(GetItemInfo, itemID)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    return nil
end

FarmerGoals.ItemName = ItemName

local function Cheer()
    if type(PlaySound) ~= "function" then return end
    -- Settings: SOUNDS, Farmer goal set.
    if ns.Config and ns.Config:Get("goalSound") == false then return end
    local kits = type(_G.SOUNDKIT) == "table" and _G.SOUNDKIT or {}
    pcall(ns.PlaySound or PlaySound, kits.IG_QUEST_LIST_COMPLETE or 878, "Master")
end

--- Hand one goal to Farmer. Returns the goal and whether it already
--- existed, or nil and why not. Prints nothing.
local function Apply(farmer, itemID, amount)
    local name = ItemName(itemID)
    if not name then return nil, L["the game has not sent its name yet"] end

    amount = math.floor(tonumber(amount) or 0)

    local Goals = farmer.Goals
    local existed = false
    if type(Goals.Find) == "function" then
        local ok, found = pcall(Goals.Find, Goals, name)
        existed = ok and found ~= nil
    end

    local ok, goal, why = pcall(Goals.Set, Goals, name, amount)
    if not ok then return nil, L["Farmer could not make it. It may need updating"] end
    if type(goal) ~= "table" then return nil, tostring(why or L["Farmer said no"]), name end

    FarmerGoals:Remember(itemID, name, tonumber(goal.target) or amount)
    return goal, existed
end

--------------------------------------------------------------------------------
-- Goals that follow the queue
--
-- A goal made here is the queue's (the owner, 2026-10-11: the addons should
-- do the work for the player): when the queue grows or shrinks its target
-- moves with it, and when nothing queued needs the material any more it
-- goes. Only goals made here, by this character, and only while their
-- target is still the one set here: a goal the player changed in Farmer is
-- theirs and is let go. Kept account wide by character key in
-- `farmerGoalsFromQueue[key][itemID] = { name, target }` (never rename it).
-- "Goals follow the queue" in Settings (`farmerGoalsFollowQueue`, on unless
-- unticked). Smooth play: worked out once, a second after a burst of queue
-- changes, only when this character has such a goal.
--------------------------------------------------------------------------------

FarmerGoals.WAIT = 1

local function Followed(create)
    if not ns.db then return nil end
    local key = ns.Config and ns.Config.GetCharacterKey and ns.Config:GetCharacterKey()
    if not key then return nil end
    if type(ns.db.farmerGoalsFromQueue) ~= "table" then
        if not create then return nil end
        ns.db.farmerGoalsFromQueue = {}
    end
    local all = ns.db.farmerGoalsFromQueue
    if type(all[key]) ~= "table" then
        if not create then return nil end
        all[key] = {}
    end
    return all[key]
end

--- Is a goal's target to follow the queue?
function FarmerGoals:Follows()
    return not (ns.Config and ns.Config:Get("farmerGoalsFollowQueue") == false)
end

--- Note a goal made from the queue, to follow it.
function FarmerGoals:Remember(itemID, name, target)
    local followed = Followed(true)
    if followed and itemID then followed[itemID] = { name = name, target = target } end
end

--- The queue changed (Queue:Notify): look again a moment later, once a
--- burst is over.
function FarmerGoals:QueueChanged()
    if self.soon or not self:Follows() then return end
    local followed = Followed(false)
    if not followed or next(followed) == nil then return end
    self.soon = true
    C_Timer.After(self.WAIT, function()
        FarmerGoals.soon = false
        FarmerGoals:Follow()
    end)
end

--- Move each followed goal to what the queue needs now, or take it away
--- when nothing queued needs it. Says what changed in one chat line.
function FarmerGoals:Follow()
    if not self:Follows() then return end
    local followed = Followed(false)
    if not followed or next(followed) == nil then return end
    local farmer = self:Farmer()
    if not farmer then return end
    local Goals = farmer.Goals

    local needs = {}
    local okList, list = pcall(ns.Queue.GetShoppingList, ns.Queue)
    if not okList or type(list) ~= "table" then return end
    for _, line in ipairs(list) do needs[line.itemID] = tonumber(line.needed) or 0 end

    local moved, gone = {}, {}
    for itemID, kept in pairs(followed) do
        local name = type(kept) == "table" and kept.name
        local goal
        if name and type(Goals.Find) == "function" then
            local ok, found = pcall(Goals.Find, Goals, name)
            goal = ok and type(found) == "table" and found or nil
        end
        local target = goal and tonumber(goal.target)

        if not goal or goal.done or target ~= kept.target then
            -- Finished, removed, or changed by the player: no longer the queue's.
            followed[itemID] = nil
        else
            local need = math.floor(needs[itemID] or 0)
            if need <= 0 then
                if type(Goals.Remove) == "function" then pcall(Goals.Remove, Goals, name) end
                followed[itemID] = nil
                gone[#gone + 1] = name
            elseif need ~= target then
                local ok, changed = pcall(Goals.Set, Goals, name, need)
                if ok and type(changed) == "table" then
                    kept.target = tonumber(changed.target) or need
                    moved[#moved + 1] = ("%s %d"):format(name, kept.target)
                else
                    -- Already have that many: the queue needs no gathering.
                    if type(Goals.Remove) == "function" then pcall(Goals.Remove, Goals, name) end
                    followed[itemID] = nil
                    gone[#gone + 1] = name
                end
            end
        end
    end

    if #moved == 0 and #gone == 0 then return end
    table.sort(moved)
    table.sort(gone)
    local parts = {}
    if #moved > 0 then parts[#parts + 1] = L.Format("now %s", table.concat(moved, ", ")) end
    if #gone > 0 then parts[#parts + 1] = L.Format("no longer needed: %s", table.concat(gone, ", ")) end
    ns.Print(L.Format("|c%sFarmer goals follow your queue:|r %s.",
        ns.COLORS.accent or "ffffffff", table.concat(parts, "; ")))
end

local function ShowPanel(farmer)
    local ui = farmer.GoalsUI
    if type(ui) == "table" and type(ui.Show) == "function" then
        pcall(ui.Show, ui)
    end
end

--- Make (or change) a Farmer goal to have `amount` of `itemID`.
-- Returns true, or false and why not. Says the outcome in chat either way.
function FarmerGoals:SetGoal(itemID, amount)
    local farmer = self:Farmer()
    if not farmer then
        ns.Print(L["Blackthornes Farmer is not loaded, so there is nowhere to put a goal."])
        return false, "no farmer"
    end

    local goal, existed = Apply(farmer, itemID, amount)
    if not goal then
        ns.Print(L.Format("No Farmer goal set: %s.", existed))
        return false, existed
    end

    local target = tonumber(goal.target) or amount
    local have = tonumber(goal.have) or 0
    local colour, left = ns.COLORS.profit or ns.COLORS.accent, math.max(0, target - have)
    if existed then
        ns.Print(L.Format("|c%sFarmer goal updated:|r %d %s. You have %d, %d to go.",
            colour, target, tostring(goal.item), have, left))
    else
        ns.Print(L.Format("|c%sFarmer goal set:|r %d %s. You have %d, %d to go.",
            colour, target, tostring(goal.item), have, left))
    end

    ShowPanel(farmer)
    Cheer()
    return true
end

--- A goal for every line in `lines` ({ itemID, needed }), in order.
-- Farmer holds only so many goals at once; the rest are named as not set.
-- One summary in chat and one sound, however many there are.
-- Returns how many were set.
function FarmerGoals:SetGoals(lines)
    local farmer = self:Farmer()
    if not farmer then
        ns.Print(L["Blackthornes Farmer is not loaded, so there is nowhere to put goals."])
        return 0
    end

    local set, missed = {}, {}
    for _, line in ipairs(lines or {}) do
        local goal, existed, name = Apply(farmer, line.itemID, line.needed)
        if goal then
            set[#set + 1] = tostring(goal.item)
        else
            missed[#missed + 1] = ("%s (%s)"):format(
                name or ItemName(line.itemID) or L.Format("item %s", tostring(line.itemID)), existed)
        end
    end

    if #set == 0 and #missed == 0 then
        ns.Print(L["Nothing still needed, so no Farmer goals to set."])
        return 0
    end

    if #set > 0 then
        local colour = ns.COLORS.profit or ns.COLORS.accent
        if #set == 1 then
            ns.Print(L.Format("|c%s%d Farmer goal set:|r %s.", colour, #set, table.concat(set, ", ")))
        else
            ns.Print(L.Format("|c%s%d Farmer goals set:|r %s.", colour, #set, table.concat(set, ", ")))
        end
        ShowPanel(farmer)
        Cheer()
    end

    if #missed > 0 then
        ns.Print(L.Format("Not set: %s.", table.concat(missed, "; ")))
    end

    return #set
end
