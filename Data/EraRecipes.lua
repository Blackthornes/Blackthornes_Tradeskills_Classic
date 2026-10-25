-- Blackthornes Tradeskills -- Data/EraRecipes.lua
-- Recipes and professions read the Classic Era way.
--
-- Era has no C_TradeSkillUI recipe calls. Its profession window is read by
-- position (GetTradeSkillInfo and friends), Enchanting has a window of its
-- own (GetCraftInfo and friends), and the professions and their levels come
-- from the skill list (GetSkillLineInfo). This file reads those into the
-- same records Data/Recipes.lua keeps on Forever, so everything after it
-- (prices, Profit, Level Up, the queue) works unchanged. Recipes.lua asks
-- for it only when the client lacks the modern calls, so on Forever it is
-- never used.
--
-- A recipe is still kept by its spell ID. The window's recipe link names it
-- when the client gives one; else it is found in Classic's recipe book by
-- what it makes, then by name. One neither finds is left unread.

local _, ns = ...

local EraRecipes = ns.NewModule("EraRecipes")

local Util = ns.Util

-- A spell each profession teaches whose name is the profession's own, in the
-- client's language. Era has no call that names a skill line by its ID, so
-- these let a German client's "Schneiderei" be known as Tailoring.
-- Herbalism's spell is named for gathering, not the skill, so it is left out:
-- an English client still knows it by name, and it has no recipes.
EraRecipes.PROFESSION_SPELLS = {
    Alchemy = 2259, Blacksmithing = 2018, Enchanting = 7411, Engineering = 4036,
    Leatherworking = 2108, Tailoring = 3908, Cooking = 2550, ["First Aid"] = 3273,
    Mining = 2575, Skinning = 8613,
}

-- The Classic skill line for each profession, by its English name.
local function ClassicLines()
    local lines = {}
    for skillLineID, english in pairs(ns.Recipes and ns.Recipes.SKILL_LINE_PROFESSIONS or {}) do
        if skillLineID < 1000 then lines[english] = skillLineID end
    end
    return lines
end

function EraRecipes.ClassicLine(english)
    return ClassicLines()[english or ""]
end

-- A plain, non-empty string, copied inside the pcall: a secret value raises
-- when touched, and a stored one would raise forever.
local function Plain(value)
    if type(value) == "string" and value ~= "" then return value .. "" end
    return nil
end

local function Call(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

local function NumberFromLink(link, kind)
    if type(link) ~= "string" then return nil end
    local ok, id = pcall(function() return link:match(kind .. ":(%d+)") end)
    return ok and tonumber(id) or nil
end

--------------------------------------------------------------------------------
-- Professions
--------------------------------------------------------------------------------

local clientNames

--- [the client's name for a profession] = its English name.
function EraRecipes:ClientNames()
    if clientNames then return clientNames end

    local names, any = {}, false
    for english, spellID in pairs(self.PROFESSION_SPELLS) do
        local ok, name = pcall(function()
            local fn = _G.GetSpellInfo
            if type(fn) == "function" then return Plain((fn(spellID))) end
        end)
        if ok and name then
            names[name] = english
            any = true
        end
    end

    if any then clientNames = names end
    return names
end

--- The client's own name for a profession's skill line, in its language.
-- Era has no call that names a skill line by ID, so the name comes from
-- the spell the profession teaches, else from the skill list.
function EraRecipes:LineName(skillLineID)
    local english = ns.Recipes and ns.Recipes.SKILL_LINE_PROFESSIONS
        and ns.Recipes.SKILL_LINE_PROFESSIONS[skillLineID]
    if not english then return nil end

    for name, eng in pairs(self:ClientNames()) do
        if eng == english then return name end
    end

    for _, skill in ipairs(self:ReadSkills()) do
        if skill.english == english then return skill.name end
    end

    return nil
end

function EraRecipes._Forget()
    clientNames = nil
    EraRecipes.bookIndex = nil
end

local function EnglishName(name)
    if not name then return nil end
    if ns.Recipes and ns.Recipes.EnglishProfessionName then
        local english = ns.Recipes.EnglishProfessionName(name)
        if english then return english end
    end
    return EraRecipes:ClientNames()[name]
end

--- Every profession in the skill list, learned or not, once each.
-- @return { { name, english, skillLineID, skillLevel, maxSkillLevel, learned } }
function EraRecipes:ReadSkills()
    local found = {}

    local ok, count = Call("GetNumSkillLines")
    if not ok or type(count) ~= "number" then return found end

    local seen = {}
    for index = 1, count do
        local gotIt, name, isHeader, rank, maxRank = pcall(function()
            local skillName, header, _, skillRank, _, _, skillMax = GetSkillLineInfo(index)
            return Plain(skillName), header and true or false,
                tonumber(skillRank) or 0, tonumber(skillMax) or 0
        end)
        local english = gotIt and not isHeader and EnglishName(name)
        local skillLineID = english and self.ClassicLine(english)
        if skillLineID and not seen[english] then
            seen[english] = true
            found[#found + 1] = {
                name = name,
                english = english,
                skillLineID = skillLineID,
                skillLevel = rank,
                maxSkillLevel = maxRank,
                learned = maxRank > 0,
            }
        end
    end

    return found
end

--- The character's professions, in the shape Recipes:GetProfessions gives.
function EraRecipes:GetProfessions()
    local professions = {}
    for _, skill in ipairs(self:ReadSkills()) do
        professions[#professions + 1] = {
            name = skill.name,
            skillLineID = skill.skillLineID,
            skillLevel = skill.skillLevel,
            maxSkillLevel = skill.maxSkillLevel,
            learned = skill.learned,
        }
    end
    table.sort(professions, function(a, b) return a.name < b.name end)
    return professions
end

--- Which skill lines are learned. The skill list names only what the
--- character has, so once it names any profession, the ones it leaves out
--- read as not learned (a dropped profession's crafts are then hidden, as on
--- Forever). Before that, at login, nothing is said about any of them.
-- @return { [skillLineID] = learned }, true when anything read as learned
function EraRecipes:ProfessionLines()
    local lines, anyLearned = {}, false
    for _, skill in ipairs(self:ReadSkills()) do
        lines[skill.skillLineID] = skill.learned
        if skill.learned then anyLearned = true end
    end
    if not anyLearned then return {}, false end

    for _, skillLineID in pairs(ClassicLines()) do
        if lines[skillLineID] == nil then lines[skillLineID] = false end
    end
    return lines, true
end

--- [Classic skill line] = this character's level in it.
function EraRecipes:SkillLevels()
    local levels = {}
    for _, skill in ipairs(self:ReadSkills()) do
        if skill.maxSkillLevel > 0 then levels[skill.skillLineID] = skill.skillLevel end
    end
    return levels
end

--------------------------------------------------------------------------------
-- The windows
--------------------------------------------------------------------------------

-- Set by the windows' own events, so a list a closed window leaves behind is
-- never read.
EraRecipes.open = { trade = false, craft = false }

--- The profession windows open now and what they list.
-- @return { { kind = "trade" | "craft", english, skillLineID, rank, count } }
function EraRecipes:Windows()
    local windows = {}

    if self.open.trade then
        local ok, name, rank = Call("GetTradeSkillLine")
        local okCount, count = Call("GetNumTradeSkills")
        local english = ok and EnglishName(Plain(name))
        local skillLineID = english and self.ClassicLine(english)
        if skillLineID and okCount and type(count) == "number" and count > 0 then
            windows[#windows + 1] = { kind = "trade", english = english, skillLineID = skillLineID,
                rank = tonumber(rank) or 0, count = count }
        end
    end

    -- The same window serves Beast Training, which is no profession: only
    -- Enchanting's is read.
    if self.open.craft then
        local ok, name, rank = Call("GetCraftDisplaySkillLine")
        local okCount, count = Call("GetNumCrafts")
        local english = ok and EnglishName(Plain(name))
        if english == "Enchanting" and okCount and type(count) == "number" and count > 0 then
            windows[#windows + 1] = { kind = "craft", english = english,
                skillLineID = self.ClassicLine(english), rank = tonumber(rank) or 0, count = count }
        end
    end

    return windows
end

--- What a harvest depends on that can change while a window stays open: how
--- many recipes each lists and the skill level each shows.
function EraRecipes:Signature()
    local windows = self:Windows()
    if #windows == 0 then return nil end
    local parts = {}
    for _, window in ipairs(windows) do
        parts[#parts + 1] = ("%s:%d=%d"):format(window.kind, window.count, window.rank)
    end
    return table.concat(parts, ",")
end

-- One line of a window: its name and colour, or nil for a heading.
local function LineAt(kind, index)
    local ok, name, tier = pcall(function()
        if kind == "trade" then
            local skillName, skillType = GetTradeSkillInfo(index)
            return Plain(skillName), Plain(skillType)
        end
        local craftName, _, craftType = GetCraftInfo(index)
        return Plain(craftName), Plain(craftType)
    end)
    if not ok or not name or not tier or tier == "header" or tier == "used" then return nil end
    return name, tier
end

--- Every recipe line the open windows show, as it stands now. A heading the
--- player folded hides its recipes; they are read the next time it shows.
function EraRecipes:Entries()
    local entries = {}
    for _, window in ipairs(self:Windows()) do
        for index = 1, window.count do
            local name, tier = LineAt(window.kind, index)
            if name then
                entries[#entries + 1] = { kind = window.kind, index = index, name = name, tier = tier,
                    skillLineID = window.skillLineID }
            end
        end
    end
    return entries
end

--------------------------------------------------------------------------------
-- Which recipe a line is
--------------------------------------------------------------------------------

--- Classic's recipe book by skill line, what each makes and its name.
function EraRecipes:BookIndex()
    if self.bookIndex then return self.bookIndex end

    local index = {}
    local recipes = ns.RECIPE_BOOK and ns.RECIPE_BOOK.RECIPES or {}
    for recipeID, row in pairs(recipes) do
        local line = row[1]
        local byLine = index[line]
        if not byLine then
            byLine = { byOutput = {}, byName = {} }
            index[line] = byLine
        end
        local output = row[3]
        if output and output > 0 then
            local list = byLine.byOutput[output] or {}
            list[#list + 1] = recipeID
            byLine.byOutput[output] = list
        end
        if row[7] then byLine.byName[row[7]] = recipeID end
    end

    self.bookIndex = index
    return index
end

--- The spell ID of a recipe line.
-- @param link the line's recipe link, when the client gave one
function EraRecipes:RecipeID(skillLineID, name, outputItemID, link)
    local fromLink = NumberFromLink(link, "enchant") or NumberFromLink(link, "spell")
    if fromLink then return fromLink end

    local byLine = self:BookIndex()[skillLineID]
    if not byLine then return nil end

    local makers = outputItemID and byLine.byOutput[outputItemID]
    if makers and #makers == 1 then return makers[1] end
    local named = byLine.byName[name]
    if makers and named then
        for _, recipeID in ipairs(makers) do
            if recipeID == named then return named end
        end
        return nil
    end
    return named
end

--- Everything about one line, read now.
-- @return recipeID, { name, outputItemID, quantityMin, quantityMax,
--   skillLineID, reagents, tier }; nil when it moved or is not whole yet,
--   nil and "unknown" when nothing says which recipe it is
function EraRecipes:Read(entry)
    local kind, index = entry.kind, entry.index

    -- The list moved under us (a heading folded, a filter changed): leave it.
    local name, tier = LineAt(kind, index)
    if name ~= entry.name then return nil end

    local trade = kind == "trade"
    local _, itemLink = Call(trade and "GetTradeSkillItemLink" or "GetCraftItemLink", index)
    local _, recipeLink = Call(trade and "GetTradeSkillRecipeLink" or "GetCraftRecipeLink", index)
    itemLink, recipeLink = Plain(itemLink), Plain(recipeLink)

    -- An enchant's line links its spell where an item would be.
    local outputItemID = NumberFromLink(itemLink, "item")
    if not recipeLink and itemLink and not outputItemID then recipeLink = itemLink end

    local quantityMin, quantityMax = 1, 1
    if trade then
        local ok, low, high = Call("GetTradeSkillNumMade", index)
        if ok then
            quantityMin = tonumber(low) or 1
            quantityMax = tonumber(high) or quantityMin
        end
    end

    local okCount, count = Call(trade and "GetTradeSkillNumReagents" or "GetCraftNumReagents", index)
    if not okCount or type(count) ~= "number" or count <= 0 then return nil end

    local reagents = {}
    for slot = 1, count do
        local _, link = Call(trade and "GetTradeSkillReagentItemLink" or "GetCraftReagentItemLink", index, slot)
        local _, _, _, needed = Call(trade and "GetTradeSkillReagentInfo" or "GetCraftReagentInfo", index, slot)
        local itemID = NumberFromLink(Plain(link), "item")
        needed = tonumber(needed)
        -- A material the client has not loaded yet: read the whole line
        -- again next time rather than keep half of it.
        if not itemID or not needed or needed <= 0 then return nil end
        reagents[#reagents + 1] = { itemID = itemID, quantity = needed }
    end

    -- Not in Classic's book and no link to name it: reading again won't help.
    local recipeID = self:RecipeID(entry.skillLineID, name, outputItemID, recipeLink)
    if not recipeID then return nil, "unknown" end

    return recipeID, {
        name = name,
        outputItemID = outputItemID,
        quantityMin = quantityMin,
        quantityMax = quantityMax,
        skillLineID = entry.skillLineID,
        reagents = reagents,
        tier = tier,
    }
end

--------------------------------------------------------------------------------
-- The harvest
--------------------------------------------------------------------------------

--- Read the open windows into this character's recipes, a few a frame.
-- Uses Recipes' own state (harvesting, windowGeneration, lastHarvest), so
-- its window checks work the same as on Forever.
-- @return true when a harvest started
function EraRecipes:Harvest()
    local Recipes = ns.Recipes
    if not Recipes or Recipes.harvesting then return false end

    local entries = self:Entries()
    if #entries == 0 then return false end

    local record = Recipes:GetCharacterRecord(true)
    if not record then return false end

    local generation = Recipes.windowGeneration
    local signature = Recipes:HarvestSignature()

    -- Every craft changes the bags and the window says its list changed.
    -- Nothing a recipe is made of moved, so with the same lines and skill
    -- as the last whole read of this window there is nothing to read again.
    local last = Recipes.lastHarvest
    if last and last.generation == generation and signature and last.signature == signature
        and last.whole then
        return false
    end

    Recipes.harvesting = true

    if ns.SkillUp then ns.SkillUp:BeginCapture() end

    local added, updated, missed = 0, 0, 0

    local worker = Util.NewWorker({
        budgetMs = ns.Config:Get("scanBudgetMs") or 8,

        onItem = function(entry, _, worker)
            if Recipes.windowGeneration ~= generation then
                worker:Cancel()
                return
            end

            local recipeID, data = EraRecipes:Read(entry)
            if not recipeID then
                if data ~= "unknown" then missed = missed + 1 end
                return
            end

            if ns.RecipeBook and ns.RecipeBook.NoteSeen then
                pcall(ns.RecipeBook.NoteSeen, ns.RecipeBook, recipeID, {
                    name = data.name,
                    outputItemID = data.outputItemID,
                    quantityMin = data.quantityMin,
                    quantityMax = data.quantityMax,
                    skillLineID = data.skillLineID,
                    reagents = data.reagents,
                    learned = true,
                })
            end

            local existing = record.recipes[recipeID]
            if existing then updated = updated + 1 else added = added + 1 end

            local skillUp = existing and existing.skillUp or nil
            if ns.SkillUp then
                skillUp = ns.SkillUp:Capture(recipeID, { name = data.name, difficulty = data.tier },
                    data.skillLineID, skillUp)
            end

            record.recipes[recipeID] = {
                recipeID = recipeID,
                name = data.name,
                outputItemID = data.outputItemID,
                quantityMin = data.quantityMin,
                quantityMax = data.quantityMax,
                skillLineID = data.skillLineID,
                skillUp = skillUp,
                reagents = data.reagents,
                cachedAt = time(),
            }
        end,

        onDone = function()
            Recipes.harvesting = false
            record.recipesCachedAt = time()
            Recipes.lastHarvest = { generation = generation, signature = signature, whole = missed == 0 }

            if ns.SkillUp then ns.SkillUp:EndCapture() end

            if added > 0 or updated > 0 then
                ns.Debug(("saved %d new and %d updated recipe(s)"):format(added, updated))
            end
            if added > 0 and ns.Mail and ns.Mail.ForgetOutputSet then ns.Mail:ForgetOutputSet() end
            -- A recipe learned since Queue Step put its materials on the list
            -- to buy: the craft goes in the queue now.
            if ns.Queue and ns.Queue.QueueLearned then pcall(ns.Queue.QueueLearned, ns.Queue) end

            if ns.UI and ns.UI.OnRecipesUpdated then
                ns.UI:OnRecipesUpdated()
            end
        end,

        onCancel = function()
            Recipes.harvesting = false
            if ns.SkillUp then ns.SkillUp:EndCapture() end
        end,
    })

    worker:Start(entries)
    return true
end

--------------------------------------------------------------------------------
-- Crafting from the old windows
--------------------------------------------------------------------------------

-- Era has no CraftRecipe: a craft is made by its place in the open window,
-- DoTradeSkill(index, count), or for Enchanting DoCraft(index), one at a
-- time. A place moves when a heading folds or a filter changes, so the
-- lines are laid out again whenever the window's signature or the
-- character's recipe count moves, and a line is checked by name again
-- right before it is used.

local function KnownByName()
    local byLine = {}
    local mine = ns.Recipes and ns.Recipes:GetAll() or {}
    for recipeID, recipe in pairs(mine) do
        local line, name = recipe.skillLineID, recipe.name
        if line and name then
            byLine[line] = byLine[line] or {}
            byLine[line][name] = recipeID
        end
    end
    return byLine
end

local function RecipeCount()
    local n = 0
    for _ in pairs(ns.Recipes and ns.Recipes:GetAll() or {}) do n = n + 1 end
    return n
end

--- Where each recipe the open windows show sits.
-- @return { [recipeID] = { kind, index, name } }
function EraRecipes:OpenLines()
    local key = (self:Signature() or "") .. "#" .. RecipeCount()
    if self.lines and self.linesKey == key then return self.lines end

    local known = KnownByName()
    local lines = {}
    for _, entry in ipairs(self:Entries()) do
        local recipeID = known[entry.skillLineID] and known[entry.skillLineID][entry.name]
            or self:RecipeID(entry.skillLineID, entry.name)
        if recipeID and not lines[recipeID] then
            lines[recipeID] = { kind = entry.kind, index = entry.index, name = entry.name }
        end
    end

    self.lines, self.linesKey = lines, key
    return lines
end

--- The recipes the open profession windows can make: every recipe this
--- character knows in their professions, shown or hidden by a heading or a
--- filter, so a folded heading never reads as the wrong window.
-- @return { [recipeID] = true }, or nil when no profession window is open
function EraRecipes:OpenRecipeIDs()
    local windows = self:Windows()
    if #windows == 0 then return nil end

    local open = {}
    local mine = ns.Recipes and ns.Recipes:GetAll() or {}
    for _, window in ipairs(windows) do
        for recipeID, recipe in pairs(mine) do
            if recipe.skillLineID == window.skillLineID then open[recipeID] = true end
        end
    end
    for recipeID in pairs(self:OpenLines()) do open[recipeID] = true end
    return open
end

--- Make a recipe from the open window. Must run from a click.
-- @return true, or false when the window does not show it now
function EraRecipes:Craft(recipeID, count)
    local line = self:OpenLines()[recipeID]
    if line and LineAt(line.kind, line.index) ~= line.name then
        self.lines = nil
        line = self:OpenLines()[recipeID]
    end
    if not line or LineAt(line.kind, line.index) ~= line.name then return false end

    if line.kind == "trade" then
        DoTradeSkill(line.index, math.max(1, count or 1))
    else
        -- Enchanting makes one a click, and an enchant waits for its target.
        DoCraft(line.index)
    end
    return true
end

--- How many crafts a craft started from the Craft window makes: always one.
function EraRecipes:MakesOneAtATime(recipeID)
    local line = self:OpenLines()[recipeID]
    return line ~= nil and line.kind == "craft"
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function EraRecipes:OnEnable()
    -- Forever's windows are read by Data/Recipes.lua alone.
    if not ns.Compat or ns.Compat:TradeskillMode() ~= "legacy" then return end

    local function Update() ns.Recipes:OnTradeSkillUpdate() end
    local function Changed() ns.Recipes:OnWindowChanged() end

    -- Recipes already hears TRADE_SKILL_SHOW and _CLOSE for its own checks.
    ns.RegisterEvent(self, "TRADE_SKILL_SHOW", function() EraRecipes.open.trade = true end)
    ns.RegisterEvent(self, "TRADE_SKILL_CLOSE", function() EraRecipes.open.trade = false end)
    ns.RegisterEvent(self, "TRADE_SKILL_UPDATE", Update)

    ns.RegisterEvent(self, "CRAFT_SHOW", function()
        EraRecipes.open.craft = true
        Changed()
        Update()
    end)
    ns.RegisterEvent(self, "CRAFT_UPDATE", Update)
    ns.RegisterEvent(self, "CRAFT_CLOSE", function()
        EraRecipes.open.craft = false
        Changed()
    end)
end
