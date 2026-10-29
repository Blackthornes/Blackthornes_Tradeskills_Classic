-- Blackthornes Tradeskills -- Logic/Crafting.lua
-- What you can make, and starting it.
--
-- Blizzard requires a hardware event to begin a craft, so one click runs one
-- queue entry; within an entry the client repeats the craft itself. If this
-- client refuses an addon-started craft outright, that is noticed on the
-- first attempt and the queue falls back to being a work list.
--
-- Either way the queue reconciles itself from your bags rather than from
-- counting casts, so crafting by hand in Blizzard's window works the same.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Crafting = ns.NewModule("Crafting")

-- On Era, the old profession windows' reader, which also starts crafts;
-- nil on Forever's client.
local function EraWindows()
    if not ns.EraRecipes or not ns.Compat or ns.Compat:TradeskillMode() ~= "legacy" then return nil end
    return ns.EraRecipes
end
Crafting.EraWindows = EraWindows

-- Seconds after a craft finishes that an Era run with crafts left still
-- counts as going, waiting for the next cast to begin.
local REPEAT_GAP = 2

Crafting.isTradeSkillOpen = false

--------------------------------------------------------------------------------
-- Capability
--------------------------------------------------------------------------------

--- True once this client has been *seen* refusing an addon-started craft.
--
-- Deliberately not inferred from issecurevariable. That reports whether a
-- variable is untainted, which is true of nearly every Blizzard function an
-- addon has not overwritten -- it says nothing about whether calling it from
-- addon code is allowed. Reading it as proof of protection was a mistake.
--
-- The only reliable evidence is the client refusing a real attempt, so this
-- stays false until that happens.
function Crafting:IsBlocked()
    return self.blocked == true
end

--- Record that the client refused a craft started from addon code.
function Crafting:MarkBlocked()
    if self.blocked then return end

    self.blocked = true
    ns.Warn(L["the game will not let addons start crafts; use Blizzard's own profession window."])

    if ns.UI then ns.UI:RefreshActiveTab() end
end

--------------------------------------------------------------------------------
-- Readiness
--------------------------------------------------------------------------------

--- Can this be made right now, and if not why not?
-- @return ready, reason
function Crafting:GetReadiness(recipeID)
    if self:IsBlocked() then
        return false, L["Craft from the game's own profession window."]
    end

    local recipe, owner = ns.Recipes:GetAny(recipeID)
    if not recipe then
        return false, L["recipe not read yet"]
    end

    -- Queued from the account-wide view: this character simply cannot make it.
    if owner ~= ns.Config:GetCharacterKey() then
        return false, L.Format("on %s", ns.Recipes:GetCharacterName(owner))
    end

    if ns.Profit:GetCraftableCount(recipeID) < 1 then
        return false, L["need materials"]
    end

    if not self.isTradeSkillOpen then
        return true, L["open your profession"]
    end

    return true
end

--- How many queued entries you could make right now.
-- @return ready, total
function Crafting:GetQueueReadiness()
    local ready, total = 0, 0

    for _, entry in ipairs(ns.Queue:GetAll()) do
        total = total + 1
        if self:GetReadiness(entry.recipeID) then
            ready = ready + 1
        end
    end

    return ready, total
end

--------------------------------------------------------------------------------
-- What to craft next
--------------------------------------------------------------------------------

-- A player asked (2026-10-14, the owner agreeing) for Craft next to make
-- whatever frees the most bag space first. Only the pick changes: the queue
-- keeps its order, and a craft never goes before a sub-craft of its own that
-- is ready to make.

-- Bag slots worked out per recipe, kept until the bags or the queue move.
local freedCache, freedKey = {}, nil

local function Slots(count, stack)
    if count <= 0 then return 0 end
    return math.ceil(count / stack)
end

--- Bag slots making all you can of an entry now frees: the slots its
--- materials stop taking, less the new slots what it makes takes. Counted
--- as stacks from the bags' totals, so it can be negative.
-- @return slots, crafts
function Crafting:SlotsFreed(entry)
    local key = tostring(ns.Inventory and ns.Inventory.changes) .. ":" .. tostring(ns.Queue.version)
    if key ~= freedKey then freedCache, freedKey = {}, key end

    local kept = freedCache[entry.recipeID]
    if kept and kept.quantity == entry.quantity then return kept.slots, kept.crafts end

    local slots, crafts = 0, 0
    local recipe = ns.Recipes:GetAny(entry.recipeID)
    if recipe and recipe.reagents then
        crafts = math.min(entry.quantity or 0, ns.Profit:GetCraftableCount(entry.recipeID))
    end

    if crafts > 0 then
        local maxStack = (ns.BagsFull and ns.BagsFull.MaxStack) or function() return 1 end

        for _, reagent in ipairs(recipe.reagents) do
            local have = ns.Inventory:GetBagCount(reagent.itemID)
            local used = math.min(have, (reagent.quantity or 1) * crafts)
            local stack = maxStack(reagent.itemID)
            slots = slots + Slots(have, stack) - Slots(have - used, stack)
        end

        if recipe.outputItemID then
            local held = ns.Inventory:GetBagCount(recipe.outputItemID)
            local made = crafts * math.max(1, recipe.quantityMin or 1)
            local stack = maxStack(recipe.outputItemID)
            slots = slots - (Slots(held + made, stack) - Slots(held, stack))
        end
    end

    freedCache[entry.recipeID] = { quantity = entry.quantity, slots = slots, crafts = crafts }
    return slots, crafts
end

--- Is "Craft what frees bag space first" ticked? On unless unticked.
function Crafting:FreesSpaceFirst()
    return ns.Config:Get("craftFreesSpaceFirst") ~= false
end

--- Pick from ready entries, given in queue order.
--
-- With the setting off, or one entry, the first. Otherwise the one freeing
-- the most bag slots, ties going to the earlier, and never an entry while a
-- sub-craft of its own (or of one of its sub-crafts) is among the ready ones.
-- @return entry, slots -- slots is nil when bag space did not decide
function Crafting:PickNext(ready)
    if #ready == 0 then return nil end
    if #ready == 1 or not self:FreesSpaceFirst() then return ready[1] end

    local byRecipe = {}
    for _, entry in ipairs(ns.Queue:GetAll()) do
        byRecipe[entry.recipeID] = entry
    end

    -- Everything a ready sub-craft feeds, up the chain, waits for it.
    local waits = {}
    for _, entry in ipairs(ready) do
        local seen, stack = {}, { entry }
        while #stack > 0 do
            local current = table.remove(stack)
            for parentID in pairs(current.forRecipes or {}) do
                if not seen[parentID] then
                    seen[parentID] = true
                    waits[parentID] = true
                    if byRecipe[parentID] then stack[#stack + 1] = byRecipe[parentID] end
                end
            end
        end
    end

    -- The queue lists sub-crafts a profession at a time, bars before the
    -- parts made from them (Queue's OrderSubCrafts). Bag space only picks
    -- within the first of those groups that has something ready, so Craft
    -- next never sends you from the forge to the anvil and back. The
    -- crafts you queued yourself come after every sub-craft.
    local group, groupOf, lastProfession = 0, {}, nil
    for _, entry in ipairs(ns.Queue:GetAll()) do
        if entry.isDependency then
            local profession = ns.Queue.ProfessionOf and ns.Queue:ProfessionOf(entry) or "?"
            if profession ~= lastProfession then group, lastProfession = group + 1, profession end
            groupOf[entry] = group
        else
            groupOf[entry] = math.huge
        end
    end
    local firstGroup = math.huge
    for _, entry in ipairs(ready) do
        if not waits[entry.recipeID] then
            firstGroup = math.min(firstGroup, groupOf[entry] or math.huge)
        end
    end

    local best, bestSlots
    for _, entry in ipairs(ready) do
        if not waits[entry.recipeID] and (groupOf[entry] or math.huge) == firstGroup then
            local slots = self:SlotsFreed(entry)
            if not best or slots > bestSlots then best, bestSlots = entry, slots end
        end
    end

    -- A loop in the sub-crafts would leave nothing; fall back to queue order.
    if not best then return ready[1] end
    return best, bestSlots
end

--- The queued craft you could make right now that Craft next makes.
-- @return entry, slots -- see PickNext
function Crafting:GetNextReady()
    local ready = {}
    for _, entry in ipairs(ns.Queue:GetAll()) do
        if self:GetReadiness(entry.recipeID) then
            ready[#ready + 1] = entry
        end
    end
    return self:PickNext(ready)
end

--------------------------------------------------------------------------------
-- Following along
--------------------------------------------------------------------------------

-- However a craft was started -- from here or from Blizzard's own window --
-- the queue reconciles from what appears in your bags. That keeps the list
-- honest whichever way you work, and survives interrupts and partial runs.

-- How long a finished cast waits for its items to reach the bags before it
-- no longer caps what the bag walk counts, in seconds.
local CAST_KEPT_FOR = 10

-- How long the bags are still read after a batch started here has ended, in
-- seconds. The last craft's items land a moment after its cast ends, and with
-- the profession window closed nothing was left reading them, so the last
-- craft of the batch stayed on the queue.
local AFTER_BATCH_SECONDS = 3

--- How many are still queued after a "made N of X" line, or nil when all are done.
local function LeftText(left)
    if left and left > 0 then return left end
    return nil
end

function Crafting:OnBagUpdate()
    if ns.Queue:Count() == 0 then return end

    -- A copy, because SetQuantity below removes finished entries from the
    -- live array and rebuilds it. Walking the live array while that happens
    -- skips the entry that slides into the removed one's slot, so two crafts
    -- finishing in one bag update left the second still on the queue.
    local entries = {}
    for index, entry in ipairs(ns.Queue:GetAll()) do entries[index] = entry end

    -- Two recipes can make the same item, and one craft's items used to count
    -- down both. What turned up is now shared out once, and the recipe just
    -- cast (or started from here) is first in line for it.
    local preferred = (self.active and self.active.recipeID) or self.lastCastSpell
    if preferred then
        local first, rest = {}, {}
        for _, entry in ipairs(entries) do
            if entry.recipeID == preferred then first[#first + 1] = entry
            else rest[#rest + 1] = entry end
        end
        for _, entry in ipairs(rest) do first[#first + 1] = entry end
        entries = first
    end

    -- Items that turned up and are not yet put down to a craft, per item.
    local unclaimed = {}

    -- Finished casts per recipe not yet matched to items. A recipe that can
    -- make more than one item per craft sometimes gives a lucky extra, and
    -- counting items alone took that extra off the queue as another craft.
    -- When a cast of a queued recipe was seen, each entry is capped at its
    -- own casts. When none was (crafted where the addon could not see the
    -- cast), the item count is all there is to go on.
    --
    -- Only the casts that count a craft are used up. The reagents leaving
    -- the bags can be a bag update of their own, before the made item
    -- arrives, and wiping the casts on that one lost the cap for the next.
    -- A cast no items turned up for is let go after a short while.
    local casts = self.casts or {}
    self.casts = casts
    local now = GetTime()
    for recipeID, cast in pairs(casts) do
        if now - cast.at > CAST_KEPT_FOR then casts[recipeID] = nil end
    end
    local castsKnown = false
    for _, entry in ipairs(entries) do
        if casts[entry.recipeID] then castsKnown = true end
    end

    -- Queue changes made during the walk must not reset the snapshot the
    -- walk is comparing against; see OnQueueChanged.
    self.walking = true
    local dependencyMade = false

    for _, entry in ipairs(entries) do
        local recipe = ns.Recipes:GetAny(entry.recipeID)

        -- A craft this character does not know is made on another one, and
        -- what turns up here was mailed over, not made. Counted, the bolts
        -- the tailor sent took the bolts off the tailor's queue a second time.
        local elsewhere = ns.Recipes.Get and ns.Recipes:Get(entry.recipeID) == nil

        if recipe and recipe.outputItemID and not elsewhere then
            local held = ns.Inventory:GetBagCount(recipe.outputItemID)
            local previous = self.seen and self.seen[recipe.outputItemID]

            if previous and held > previous then
                local perCraft = math.max(1, recipe.quantityMin or 1)

                local output = recipe.outputItemID
                if unclaimed[output] == nil then unclaimed[output] = held - previous end

                -- A variable-yield recipe can produce more than its minimum,
                -- which would otherwise read as extra crafts completed.
                local made = math.min(
                    math.floor(unclaimed[output] / perCraft),
                    entry.quantity)
                if castsKnown then
                    local cast = casts[entry.recipeID]
                    made = math.min(made, cast and cast.count or 0)
                    if made > 0 then
                        cast.count = cast.count - made
                        if cast.count <= 0 then casts[entry.recipeID] = nil end
                    end
                end

                if made > 0 and entry.isDependency then
                    -- A sub-craft is sized from what its parents still need
                    -- minus what is held, so it is re-derived rather than
                    -- counted down. Counting it down went through SetQuantity,
                    -- which finds the MANUAL entry for the same recipe first:
                    -- queue 5 bolts and a bag that needs 3, make 2, and the
                    -- bolts you asked for were written down to 1 and then
                    -- removed.
                    --
                    -- The items still go to it first, and are taken out of
                    -- what the manual entry can count. The re-derive already
                    -- sees them as held, so counting the manual entry down as
                    -- well took one craft's items off both: 5 bolts asked for
                    -- plus 3 for a bag, make 3, and only 2 were left to make.
                    dependencyMade = true
                    unclaimed[output] = unclaimed[output] - made * perCraft

                    ns.Print(L.Format("made %d of %s, as materials for another craft", made,
                        ns.Recipes:GetDisplayLink(entry.recipeID)))

                elseif made > 0 then
                    unclaimed[output] = unclaimed[output] - made * perCraft

                    -- Marked for the row's action (DE or Vendor), before
                    -- SetQuantity can take the entry off the queue.
                    if ns.QueueActions then
                        ns.QueueActions:NoteMade(entry, output, made * perCraft)
                    end

                    -- Worked out first: SetQuantity changes the entry itself.
                    local left = entry.quantity - made
                    local owner = entry.owner
                    ns.Queue:SetQuantity(entry.recipeID, left)

                    -- Made for the character who queued it: the mailbox
                    -- offers to send it to them.
                    if owner and owner ~= ns.Config:GetCharacterKey()
                        and ns.QueueMail and ns.QueueMail.NoteMadeFor then
                        ns.QueueMail:NoteMadeFor(owner, output, made * perCraft)
                    end

                    local stillLeft = LeftText(left)
                    if stillLeft then
                        ns.Print(L.Format("made %d of %s, %d left", made,
                            ns.Recipes:GetDisplayLink(entry.recipeID), stillLeft))
                    else
                        ns.Print(L.Format("made %d of %s, all done", made,
                            ns.Recipes:GetDisplayLink(entry.recipeID)))
                    end
                end
            end
        end
    end

    if dependencyMade then
        ns.Queue:RebuildDependencies()
        ns.Queue:Notify()
    end

    self.walking = false
    self:RememberOutputs()
end

--- The queue changed by hand (added to, stepped, cleared).
--
-- A recipe queued while the profession window was already open had no
-- snapshot until the next bag change, so its first craft went unnoticed and
-- the queue stayed one too high. Snapshot whenever the queue changes, except
-- while OnBagUpdate is mid-walk, when the snapshot is the thing being
-- compared against.
function Crafting:OnQueueChanged()
    if self.walking then return end
    self:RememberOutputs()
end

--- Snapshot the queue's output items, so the next bag change can be compared.
function Crafting:RememberOutputs()
    self.seen = {}

    for _, entry in ipairs(ns.Queue:GetAll()) do
        local recipe = ns.Recipes:GetAny(entry.recipeID)

        if recipe and recipe.outputItemID then
            self.seen[recipe.outputItemID] = ns.Inventory:GetBagCount(recipe.outputItemID)
        end
    end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function Crafting:OnTradeSkillShow()
    self.isTradeSkillOpen = true
    self:RememberOutputs()

    if ns.UI then ns.UI:RefreshActiveTab() end
end

function Crafting:OnTradeSkillClose()
    self.isTradeSkillOpen = false
    if ns.UI then ns.UI:RefreshActiveTab() end
end

--- A craft that makes no item, such as an enchant, finished casting.
--
-- The queue counts crafts down by the made item turning up in the bags, and
-- an enchant never puts one there, so ten queued enchants stayed at ten for
-- good however many were cast. For those alone the finished cast is the
-- count. The spell is compared inside a pcall: inside an instance it can be
-- a value the game will not let an addon compare.
function Crafting:OnCastSucceeded(_, unit, _, spellID)
    if not self:IsFollowing() then return end

    local okUnit, isPlayer = pcall(function() return unit == "player" end)
    if not (okUnit and isPlayer) then return end

    -- Which recipe was just made, so the bag change it causes is put down to
    -- that one when two recipes make the same item. Copied inside a pcall
    -- for the same reason as the compare below.
    local okSpell, copied = pcall(function() return spellID + 0 end)
    self.lastCastSpell = okSpell and copied or nil

    -- Counted for the bag walk, which caps what it puts down to a recipe by
    -- how many times it was actually cast.
    if okSpell and copied then
        self.casts = self.casts or {}
        local cast = self.casts[copied] or { count = 0 }
        cast.count = cast.count + 1
        cast.at = GetTime()
        self.casts[copied] = cast
    end
    if self.active then self.active.lastCastAt = GetTime() end

    -- What one cost to make, kept for when it is listed later (2026-10-05).
    if okSpell and copied and ns.CraftedCost then
        ns.CraftedCost:NoteCraft(copied)
    end

    for _, entry in ipairs(ns.Queue:GetAll()) do
        local ok, same = pcall(function() return entry.recipeID == spellID end)
        if ok and same and not entry.isDependency then
            local recipe = ns.Recipes:GetAny(entry.recipeID)
            if recipe and not recipe.outputItemID then
                local left = entry.quantity - 1
                ns.Queue:SetQuantity(entry.recipeID, left)
                if LeftText(left) then
                    ns.Print(L.Format("made 1 of %s, %d left", ns.Recipes:GetDisplayLink(entry.recipeID), left))
                else
                    ns.Print(L.Format("made 1 of %s, all done", ns.Recipes:GetDisplayLink(entry.recipeID)))
                end
            end
            return
        end
    end
end

function Crafting:OnEnable()
    -- Only the player's casts are wanted (ns.RegisterPlayerEvent).
    local RegisterForPlayer = ns.RegisterPlayerEvent or ns.RegisterEvent
    RegisterForPlayer(self, "UNIT_SPELLCAST_SUCCEEDED", self.OnCastSucceeded)

    -- Era's Enchanting has a window of its own. It counts as a profession
    -- window open too, so its crafts can start and are followed, and the two
    -- windows can be open at once.
    if EraWindows() then
        local open = { trade = false, craft = false }
        local function Shown(kind)
            return function()
                open[kind] = true
                Crafting:OnTradeSkillShow()
            end
        end
        local function Closed(kind)
            return function()
                open[kind] = false
                if not open.trade and not open.craft then Crafting:OnTradeSkillClose() end
            end
        end
        ns.RegisterEvent(self, "TRADE_SKILL_SHOW", Shown("trade"))
        ns.RegisterEvent(self, "TRADE_SKILL_CLOSE", Closed("trade"))
        ns.RegisterEvent(self, "CRAFT_SHOW", Shown("craft"))
        ns.RegisterEvent(self, "CRAFT_CLOSE", Closed("craft"))
    else
        ns.RegisterEvent(self, "TRADE_SKILL_SHOW", self.OnTradeSkillShow)
        ns.RegisterEvent(self, "TRADE_SKILL_CLOSE", self.OnTradeSkillClose)
    end

    -- Only while a profession window is open: bags change constantly otherwise,
    -- and a looted item is not a completed craft. Or while a batch the addon
    -- started is still casting: closing the window does not stop it, and the
    -- crafts made after that were never taken off the queue.
    ns.RegisterEvent(self, "BAG_UPDATE_DELAYED", function()
        if Crafting:IsFollowing() then
            Crafting:OnBagUpdate()
        end
    end)

    self:RememberOutputs()
end

--- Whether casts and bag changes are being read as crafts: while a
--- profession window is open, while a batch started here runs, and for a
--- moment after it ends, when its last items are still on their way.
function Crafting:IsFollowing()
    if self.isTradeSkillOpen or self.active then return true end
    return self.followUntil ~= nil and GetTime() < self.followUntil
end

--------------------------------------------------------------------------------
-- Starting a craft
--------------------------------------------------------------------------------

--- Begin crafting a queued entry. Must be called from a hardware event.
-- `secureClick` is true only from UI/SecureCraft.lua's button, whose own
-- press of the Enchanting window's Create button makes an Era enchant.
--
-- Blizzard requires a real click to start a craft, so one click runs one queue
-- entry. Within an entry the client repeats the craft itself, so queueing 20 of
-- something genuinely is a single click.
function Crafting:Start(recipeID, count, secureClick)
    local ready, reason = self:GetReadiness(recipeID)
    if not ready then
        ns.Print(reason or L["cannot craft that"])
        return false
    end

    if self.active then
        ns.Print(L["already crafting"])
        return false
    end

    local recipe = ns.Recipes:GetAny(recipeID)

    -- Never ask for more than the bags support: the client would stop partway
    -- and the queue would be left guessing what happened.
    local craftable = ns.Profit:GetCraftableCount(recipeID)
    count = math.max(1, math.min(count or 1, craftable))

    -- Era's Enchanting window makes one a click.
    local era = EraWindows()
    if era and era:MakesOneAtATime(recipeID) then
        count = 1
        -- The game blocks DoCraft from addon code, so only the secure
        -- button can make an enchant.
        if not secureClick then
            ns.Print(L["cannot craft that"])
            return false
        end
    end

    self.active = {
        recipeID = recipeID,
        requested = count,
        outputItemID = recipe.outputItemID,
        -- Measured from what actually appears, not from counting spell casts.
        before = recipe.outputItemID and ns.Inventory:GetBagCount(recipe.outputItemID) or 0,
        startedAt = GetTime(),
    }

    local ok, err
    if era then
        local shown
        ok, shown = pcall(era.Craft, era, recipeID, count)
        if ok and not shown then
            self.active = nil
            ns.Print(L["cannot craft that"])
            return false
        end
        err = shown
    else
        ok, err = pcall(C_TradeSkillUI.CraftRecipe, recipeID, count)
    end
    if not ok then
        self.active = nil

        -- "Interface action failed because of an AddOn" means the client will
        -- not accept a craft from addon code at all.
        if tostring(err):lower():find("addon") then
            self:MarkBlocked()
        else
            ns.Warn(L.Format("the game refused the craft: %s",
                tostring(err):gsub("^.-:%d+: ", "")))
        end
        return false
    end

    ns.Print(L.Format("crafting %dx %s...", count, ns.Recipes:GetDisplayLink(recipeID)))

    self:StartWatching()
    return true
end

function Crafting:Stop()
    if ns.Util.HasFunction("C_TradeSkillUI.StopRecipeRepeat") then
        pcall(C_TradeSkillUI.StopRecipeRepeat)
    elseif type(StopTradeSkillRepeat) == "function" then
        pcall(StopTradeSkillRepeat)
    end

    self.active = nil
    -- The craft under way still finishes, and its items still count.
    self.followUntil = GetTime() + CAST_KEPT_FOR
    self:StopWatching()

    if ns.UI then ns.UI:RefreshActiveTab() end
    if ns.CraftPanel and ns.CraftPanel.RequestRefresh then ns.CraftPanel:RequestRefresh() end
end

function Crafting:IsBusy()
    return self.active ~= nil
end

--- Watch for the craft loop ending.
--
-- Counting UNIT_SPELLCAST_SUCCEEDED is unreliable: the recipe ID is not always
-- the spell ID, and an interrupted run would desync the queue. The bag-watching
-- in OnBagUpdate does the actual reconciliation; this just clears the busy flag.
function Crafting:StartWatching()
    if self.ticker then self.ticker:Cancel() end

    self.ticker = C_Timer.NewTicker(0.5, function()
        if not Crafting.active then
            Crafting:StopWatching()
            return
        end

        if Crafting:IsStillCrafting() then return end

        local finished = Crafting.active
        Crafting.active = nil
        Crafting:AnnounceRunDone(finished)
        Crafting.followUntil = GetTime() + AFTER_BATCH_SECONDS
        Crafting:StopWatching()

        if ns.UI then ns.UI:RefreshActiveTab() end
        -- The craft pane beside the profession window too: RefreshActiveTab
        -- only redraws the main window, and a failed or interrupted craft
        -- left the pane saying "Stop crafting" (whose click started one).
        if ns.CraftPanel and ns.CraftPanel.RequestRefresh then ns.CraftPanel:RequestRefresh() end
    end)
end

--- A chime when a run of two or more crafts ends having made something, so a
--- long run can be left to finish (a player's request, 2026-10-02). Stop
--- clears the run before this is reached, so a stopped run stays quiet.
function Crafting:AnnounceRunDone(run)
    if not run or (run.requested or 0) < 2 then return end

    -- Settings: SOUNDS, A run of crafts finishes.
    if ns.Config:Get("craftDoneSound") == false or type(PlaySound) ~= "function" then return end

    if run.outputItemID then
        local made = ns.Inventory:GetBagCount(run.outputItemID) - (run.before or 0)
        if made <= 0 then return end
    end

    local kits = type(_G.SOUNDKIT) == "table" and _G.SOUNDKIT or {}
    pcall(PlaySound, kits.READY_CHECK or 8960, "Master")
end

function Crafting:StopWatching()
    if self.ticker then
        self.ticker:Cancel()
        self.ticker = nil
    end
end

function Crafting:IsStillCrafting()
    if ns.Util.HasFunction("C_TradeSkillUI.IsRecipeRepeating") then
        local ok, repeating = pcall(C_TradeSkillUI.IsRecipeRepeating)
        if ok and repeating then return true end
    end

    local castOk, castName = pcall(UnitCastingInfo, "player")
    if castOk and castName then return true end

    -- Era repeats a craft by itself and has no IsRecipeRepeating; between two
    -- casts nothing is casting, so a run counts as going while crafts are
    -- left and the last one finished a moment ago.
    if self.active and type(GetTradeskillRepeatCount) == "function" then
        local okLeft, left = pcall(GetTradeskillRepeatCount)
        local last = self.active.lastCastAt
        if okLeft and type(left) == "number" and left > 1 and last and GetTime() - last < REPEAT_GAP then
            return true
        end
    end

    -- A craft takes a moment to begin; do not declare it finished instantly.
    if self.active and (GetTime() - self.active.startedAt) < 1.5 then
        return true
    end

    return false
end
