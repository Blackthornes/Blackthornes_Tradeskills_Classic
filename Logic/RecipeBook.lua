-- Blackthornes Tradeskills -- Logic/RecipeBook.lua
-- Every recipe, learned or not, and what each is worth making.
--
-- Asked 2026-10-05 by a player: "is there a way to see make costs and
-- disenchants for a recipe you haven't learnt yet? Would love to know if
-- it's worth it to get a recipe or not at a glance", at the auction house
-- and as a list of every recipe a profession has.
--
-- The rest of the addon only knows recipes a character has learned, read
-- from the profession window (Data/Recipes.lua). A recipe item at the auction
-- house is just an item to the game: nothing says what it teaches. So three
-- sources are laid together here:
--
--   * Data/RecipeBook.lua, generated from Classic 1.12 data: every recipe of
--     every crafting profession, what it makes and from what, and which
--     recipe item teaches it, with who sells or drops that item.
--   * Data/ForeverRecipes.lua, generated from the Forever client's game
--     tables: the recipes Forever added, laid into that book (f = 1), so
--     they show before anyone has opened a profession window. The Classic
--     Era copy leaves it out of the TOC, so the book is Classic's alone.
--   * What profession windows have shown on this account, learned or not
--     (`seenRecipes`, written by Recipes:Harvest). Where Forever differs
--     from Classic, the game wins, and recipes Forever added are listed from
--     here alone.
--
-- Values follow the house rules: materials at what they cost to buy (a
-- vendor's price for what a vendor sells), what one craft gets back the way
-- the Level Up tab works it out (LevelUp:GetReturns: a grey item at vendor
-- only, a disenchant at its most likely result), and nothing is ever priced
-- from a missing number.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local RecipeBook = ns.NewModule("RecipeBook")

local Util = ns.Util

-- Forever lists each profession under a second, modern skill line as well
-- (docs/FOREVER_API_FINDINGS.md). Recipes the game shows may carry either.
local MODERN_SKILL_LINES = {
    [2937] = 171, [2938] = 164, [2940] = 333, [2941] = 202,
    [2945] = 165, [2946] = 186, [2948] = 197,
}

-- The game's item class for recipes.
local CLASS_RECIPE = 9

-- How long a read of who knows what is reused. Hovering down a column of
-- recipe items at the auction house asks once, not once per row.
local KNOWN_TTL = 5

local function Book()
    return ns.RECIPE_BOOK or { PROFESSIONS = {}, RECIPES = {}, ITEMS = {} }
end

local function SeenTable(create)
    if not ns.db then return nil end
    if create and type(ns.db.seenRecipes) ~= "table" then ns.db.seenRecipes = {} end
    return ns.db.seenRecipes
end

local function SkillTable(create)
    if not ns.db then return nil end
    if create and type(ns.db.recipeSkills) ~= "table" then ns.db.recipeSkills = {} end
    return type(ns.db.recipeSkills) == "table" and ns.db.recipeSkills or nil
end

--- A plain, non-empty string from a client call, or nil. Copied inside the
--- pcall: in a dungeon the client can hand back one that raises when used.
local function PlainString(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(function(...)
        local v = fn(...)
        if type(v) == "string" and v ~= "" then return v .. "" end
    end, ...)
    if ok then return value end
    return nil
end

local function Now()
    return (type(GetTime) == "function" and GetTime()) or time()
end

-- Skill levels Forever changed from Classic, as players reported them
-- before a recipe item's tooltip had been read on this account (a player
-- on Discord, 2026-10-09: "Seems levels have changed a bit?"). Keyed by
-- the recipe's name in lower case. What the game's own tooltip says wins
-- over these (RecipeBook:LearnSkill).
local FOREVER_SKILLS = {
    ["hillman's leather boots"] = 110,
    ["herbalist's gloves"] = 110,
    ["raptor hide belt"] = 140,
    ["raptor hide harness"] = 140,
    ["green whelp armor"] = 150,
}

-- Required skills read from recipe items' tooltips, one read per item a
-- session (a skill can change again on a patch, so it is read again on
-- the next login).
local skillReadThisSession = {}

--------------------------------------------------------------------------------
-- Professions
--------------------------------------------------------------------------------

--- The Classic skill line for either of Forever's two.
function RecipeBook.ClassicLine(skillLineID)
    return MODERN_SKILL_LINES[skillLineID] or skillLineID
end

--- A profession's name from a skill line, either of Forever's two.
function RecipeBook:ProfessionName(skillLineID)
    if type(skillLineID) ~= "number" then return nil end

    local professions = Book().PROFESSIONS
    local name = professions[MODERN_SKILL_LINES[skillLineID] or skillLineID]
    if name then return name end

    local get = C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID
    if type(get) == "function" then
        local ok, info = pcall(get, skillLineID)
        if ok and type(info) == "table" then
            return PlainString(function() return info.professionName end)
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- What the profession window shows
--------------------------------------------------------------------------------

--- Remember a recipe a profession window showed, learned or not.
--- Called by Recipes:Harvest. Nothing about who was looking is kept.
function RecipeBook:NoteSeen(recipeID, data)
    if type(recipeID) ~= "number" or type(data) ~= "table" then return end

    local seen = SeenTable(true)
    if not seen then return end

    local reagents = {}
    for _, reagent in ipairs(data.reagents or {}) do
        reagents[#reagents + 1] = { itemID = reagent.itemID, quantity = reagent.quantity }
    end

    local old = seen[recipeID]
    seen[recipeID] = {
        name = data.name or (old and old.name),
        outputItemID = data.outputItemID,
        quantityMin = data.quantityMin or 1,
        quantityMax = data.quantityMax or data.quantityMin or 1,
        skillLineID = data.skillLineID,
        profession = self:ProfessionName(data.skillLineID) or (old and old.profession),
        reagents = reagents,
        seenAt = time(),
    }

    self.merged = nil
end

--------------------------------------------------------------------------------
-- The merged book
--------------------------------------------------------------------------------

--- Every recipe, the shipped book with what the game showed laid over it.
--
-- @return merged  { [recipeID] = record } in Data/Recipes.lua's shape plus
--   profession, skill, trainerCost, starter, recipeItems, seenInGame
-- @return aliases { [book recipe ID] = game recipe ID } where the game listed
--   a Classic recipe under an ID of its own
function RecipeBook:GetAll()
    if self.merged then return self.merged, self.aliases end

    local book = Book()
    local merged, aliases, byOutput, byName = {}, {}, {}, {}

    local itemsFor = {}
    for itemID, row in pairs(book.ITEMS) do
        local list = itemsFor[row[1]]
        if not list then list = {}; itemsFor[row[1]] = list end
        list[#list + 1] = itemID
    end
    for _, list in pairs(itemsFor) do table.sort(list) end

    -- Forever's own materials and item made, where its client differs from
    -- Classic (Data/LearnSpots.lua); a profession window's still win.
    local spots = ns.LEARN_SPOTS or {}
    local foreverMaterials, foreverMade = spots.MATERIALS or {}, spots.MADE or {}

    for recipeID, row in pairs(book.RECIPES) do
        local reagents = {}
        local materials = foreverMaterials[recipeID] or row[6] or {}
        for i = 1, #materials - 1, 2 do
            reagents[#reagents + 1] = { itemID = materials[i], quantity = materials[i + 1] }
        end

        local record = {
            recipeID = recipeID,
            bookID = recipeID,
            name = row[7],
            skillLineID = row[1],
            profession = book.PROFESSIONS[row[1]],
            skill = row[2],
            outputItemID = foreverMade[recipeID] or ((row[3] or 0) ~= 0 and row[3] or nil),
            quantityMin = row[4] or 1,
            quantityMax = row[5] or row[4] or 1,
            reagents = reagents,
            trainerCost = row.t,
            starter = row.s == 1,
            recipeItems = itemsFor[recipeID],
            forever = row.f == 1 or nil,
            yellow = row.y,
            grey = row.g,
        }

        merged[recipeID] = record
        -- A recipe Forever added (Data/ForeverRecipes.lua) is kept under the
        -- game's own ID, so a window's recipe never has to be matched to it
        -- by what it makes or its name (Forever's First Aid Minor Healing
        -- Potion makes the same potion as Alchemy's).
        if not record.forever then
            if record.outputItemID then byOutput[record.outputItemID] = record end
            if record.name then byName[record.name:lower()] = record end
        end
    end

    for recipeID, seen in pairs(SeenTable(false) or {}) do
        if type(seen) == "table" then
            local target = merged[recipeID]
                or (seen.outputItemID and byOutput[seen.outputItemID])
                or (not seen.outputItemID and seen.name and byName[seen.name:lower()])

            if target and target.recipeID ~= recipeID then
                -- The same Classic recipe under the game's own ID: kept under
                -- the game's, which is what characters' recipes use.
                merged[target.recipeID] = nil
                aliases[target.recipeID] = recipeID
                target.recipeID = recipeID
                merged[recipeID] = target
            end

            local record = target or { recipeID = recipeID }
            merged[recipeID] = record

            record.name = seen.name or record.name
            record.outputItemID = seen.outputItemID or record.outputItemID
            record.quantityMin = seen.quantityMin or record.quantityMin or 1
            record.quantityMax = seen.quantityMax or record.quantityMax or record.quantityMin
            record.skillLineID = seen.skillLineID or record.skillLineID
            record.profession = record.profession or seen.profession
                or self:ProfessionName(seen.skillLineID)
            if type(seen.reagents) == "table" and #seen.reagents > 0 then
                record.reagents = seen.reagents
            end
            record.seenInGame = true
        end
    end

    -- The skill each recipe needs on Forever: the Forever client's own
    -- yellow and grey (Data/LearnSpots.lua, the skill to learn moved by as
    -- much as the yellow moved), then players' reports, then what the game's
    -- own recipe item tooltips say, which beats everything. Classic's skill
    -- is kept as classicSkill: which trainer teaches it goes by that.
    local foreverSkills = ns.LEARN_SPOTS and ns.LEARN_SPOTS.SKILLS or {}
    for _, record in pairs(merged) do
        record.classicSkill = record.skill
        local forever = foreverSkills[record.bookID or record.recipeID]
        if type(forever) == "table" then
            record.skill = forever[1] or record.skill
            record.yellow, record.grey = forever[2], forever[3]
        end
    end
    for _, record in pairs(merged) do
        local fixed = record.name and FOREVER_SKILLS[record.name:lower()]
        if fixed then
            record.skill = fixed
        end
    end
    for itemID, learned in pairs(SkillTable(false) or {}) do
        if type(learned) == "table" and type(learned.skill) == "number" then
            local row = book.ITEMS[itemID]
            local record = row and (merged[row[1]] or merged[aliases[row[1]] or false])
            if not record and type(learned.teaches) == "string" then
                record = byName[learned.teaches]
                if not record then
                    for _, candidate in pairs(merged) do
                        if candidate.name and candidate.name:lower() == learned.teaches then
                            record = candidate
                            break
                        end
                    end
                end
            end
            if record and (not learned.profession or not record.profession
                    or learned.profession == record.profession) then
                record.skill = learned.skill
            end
        end
    end

    self.merged, self.aliases = merged, aliases
    return merged, aliases
end

function RecipeBook:Invalidate()
    self.merged = nil
    self.known = nil
    self.made = nil
end

--- Is this item made by a profession? Any recipe in the book or seen in a
--- profession window, learned or not. The disenchanter's mail leaves these
--- out (the owner, 2026-10-11: "disenchantable, non-crafted items").
function RecipeBook:IsCrafted(itemID)
    itemID = tonumber(itemID)
    if not itemID then return false end
    if not self.made then
        local made = {}
        for _, record in pairs((self:GetAll())) do
            if record.outputItemID then made[record.outputItemID] = true end
        end
        self.made = made
    end
    return self.made[itemID] == true
end

--- One recipe by ID, or nil.
function RecipeBook:Get(recipeID)
    local merged, aliases = self:GetAll()
    return merged[recipeID] or merged[aliases[recipeID] or false]
end

--- The skill a recipe needs, Forever's where it is known, else Classic's;
--- nil when nothing says. Equipment reads this (inside a pcall) for its
--- crafted upgrades, so keep it stable.
function RecipeBook:GetSkill(recipeID)
    local record = self:Get(recipeID)
    return record and record.skill or nil
end

--- Every profession the book has recipes for, sorted.
function RecipeBook:GetProfessions()
    local seen, names = {}, {}
    for _, record in pairs((self:GetAll())) do
        local name = record.profession
        if name and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

--------------------------------------------------------------------------------
-- Recipe items
--------------------------------------------------------------------------------

local function ItemInfo(itemID)
    if not (C_Item and type(C_Item.GetItemInfo) == "function") then return nil end
    local ok, name, classID = pcall(function()
        local n, _, _, _, _, _, _, _, _, _, _, c = C_Item.GetItemInfo(itemID)
        if type(n) == "string" then n = n .. "" else n = nil end
        if type(c) == "number" then c = c + 0 else c = nil end
        return n, c
    end)
    if not ok then return nil end
    return name, classID
end

--- The recipe a recipe item teaches.
--
-- By the shipped table first. A recipe item it does not list (one Forever
-- added) is matched by name: "Pattern: Fine Leather Boots" teaches the recipe
-- called Fine Leather Boots, among those a profession window has shown.
--
-- @return recipe record or nil
function RecipeBook:ForItem(itemID)
    if type(itemID) ~= "number" then return nil end

    local row = Book().ITEMS[itemID]
    if row then return self:Get(row[1]) end

    local name, classID = ItemInfo(itemID)
    if not name or classID ~= CLASS_RECIPE then return nil end

    local taught = name:match("^[^:]+:%s*(.+)$")
    if not taught then return nil end
    taught = taught:lower()

    for _, record in pairs((self:GetAll())) do
        if record.name and record.name:lower() == taught then return record end
    end

    return nil
end

--- The recipe items that teach a recipe: the shipped ones, and the item a
--- tooltip was showing when it is one the table does not list.
function RecipeBook:RecipeItemsFor(record, extraItemID)
    local items = {}
    for _, itemID in ipairs(record and record.recipeItems or {}) do items[#items + 1] = itemID end
    if extraItemID then
        local listed = false
        for _, itemID in ipairs(items) do if itemID == extraItemID then listed = true end end
        if not listed then items[#items + 1] = extraItemID end
    end
    return items
end

--------------------------------------------------------------------------------
-- The skill a recipe needs, read from the game
--------------------------------------------------------------------------------

-- Forever moved some recipes to other skill levels (Raptor Hide Belt needs
-- Leatherworking 140 there, 165 in Classic). A recipe item's own tooltip
-- says what it needs ("Requires Leatherworking (140)"), so that is read
-- whenever one is hovered, and for every recipe item the client already
-- holds after the auction house closes and soon after logging in.

-- How many recipe items one step of the sweep reads, and how often.
local SWEEP_BATCH = 20
local SWEEP_STEP = 0.2

--- "Requires %s (%d)" as a Lua pattern catching the name and the number.
local function RequiresPattern()
    local format = type(_G.ITEM_MIN_SKILL) == "string" and _G.ITEM_MIN_SKILL or "Requires %s (%d)"
    format = format:gsub("%%%d%$", "%%")
    format = format:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    format = format:gsub("%%s", "(.-)"):gsub("%%d", "(%%d+)")
    return "^" .. format .. "$"
end

local function LineText(line)
    if type(line) ~= "table" then return nil end
    local text = line.leftText
    if text == nil and type(line.args) == "table" then
        for _, arg in ipairs(line.args) do
            if type(arg) == "table" and arg.field == "leftText" then text = arg.stringVal end
        end
    end
    if type(text) ~= "string" then return nil end
    return (text .. ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
end

--- The book's (English) name for a profession the tooltip names, or nil.
--- The tooltip is in the client's language ("Benötigt Lederverarbeitung
--- (140)" on a German client), so its name goes through Recipes.
local function BookProfession(name)
    for _, profession in pairs(Book().PROFESSIONS) do
        if profession == name then return profession end
    end

    local recipes = ns.Recipes
    if recipes and type(recipes.EnglishProfessionName) == "function" then
        local ok, english = pcall(recipes.EnglishProfessionName, name)
        if ok and english then
            for _, profession in pairs(Book().PROFESSIONS) do
                if profession == english then return profession end
            end
        end
    end
    return nil
end

--- What a recipe item's tooltip says it needs.
--
-- The tooltip also shows the item the recipe makes, which can need a skill
-- of its own (engineering goggles), and the recipe's line comes after it,
-- so the last matching line wins, and one naming the recipe's own
-- profession beats the rest.
--
-- @return skill, profession, or nil when the client has no lines for it
function RecipeBook:ReadSkill(itemID, profession)
    if not Util.HasFunction("C_TooltipInfo.GetItemByID") then return nil end

    local found, foundProfession
    local ok = pcall(function()
        local data = C_TooltipInfo.GetItemByID(itemID)
        if type(data) ~= "table" or type(data.lines) ~= "table" then return end

        local pattern = RequiresPattern()
        for _, line in ipairs(data.lines) do
            local text = LineText(line)
            local name, number = nil, nil
            if text then name, number = text:match(pattern) end
            number = tonumber(number)
            name = name and BookProfession(name)
            if name and number then
                if not profession or name == profession or foundProfession ~= profession then
                    found, foundProfession = number, name
                end
            end
        end
    end)
    if not ok then return nil end
    return found, foundProfession
end

--- Read and keep the skill one recipe item needs, once a session.
--
-- @return true when it changed what was kept
function RecipeBook:LearnSkill(itemID)
    if type(itemID) ~= "number" or skillReadThisSession[itemID] then return false end

    local name, classID = ItemInfo(itemID)
    if not name or classID ~= CLASS_RECIPE then return false end

    local record = self:ForItem(itemID)
    local skill, profession = self:ReadSkill(itemID, record and record.profession)
    if not skill then return false end
    skillReadThisSession[itemID] = true

    local taught = name:match("^[^:]+:%s*(.+)$")
    local skills = SkillTable(true)
    if not skills then return false end

    local old = skills[itemID]
    if type(old) == "table" and old.skill == skill and old.profession == profession then return false end

    -- Game IDs and numbers only; nothing about who looked.
    skills[itemID] = {
        skill = skill,
        profession = profession,
        teaches = taught and taught:lower() or nil,
        at = time(),
    }
    -- A sweep rebuilds the book once at its end, not once per item.
    if not self.sweeping then self.merged = nil end
    return true
end

local function AuctionHouseOpen()
    return ns.Scanner ~= nil and ns.Scanner.isAuctionHouseOpen == true
end

--- Is the item already in the client's cache? Only those are read in a
--- sweep: reading any other would fetch it and push bag items out.
local function Cached(itemID)
    if not Util.HasFunction("C_Item.IsItemDataCachedByID") then return false end
    local ok, answer = pcall(C_Item.IsItemDataCachedByID, itemID)
    return ok and answer == true
end

--- Read every recipe item the client holds, a few at a time. Nothing
--- happens while the auction house is open.
function RecipeBook:SweepSkills()
    if self.sweeping or not Util.HasFunction("C_TooltipInfo.GetItemByID") then return end

    local queue = {}
    for itemID in pairs(Book().ITEMS) do
        if not skillReadThisSession[itemID] then queue[#queue + 1] = itemID end
    end
    for itemID in pairs(SkillTable(false) or {}) do
        if type(itemID) == "number" and not skillReadThisSession[itemID] and not Book().ITEMS[itemID] then
            queue[#queue + 1] = itemID
        end
    end
    if #queue == 0 then return end
    table.sort(queue)

    self.sweeping = true
    local index, changed = 1, false
    local function Step()
        if AuctionHouseOpen() then
            self.sweeping = false
            if changed then self.merged = nil end
            return
        end
        local last = math.min(index + SWEEP_BATCH - 1, #queue)
        for i = index, last do
            local itemID = queue[i]
            if Cached(itemID) and self:LearnSkill(itemID) then changed = true end
        end
        index = last + 1
        if index <= #queue and C_Timer and C_Timer.After then
            C_Timer.After(SWEEP_STEP, Step)
            return
        end
        self.sweeping = false
        if changed then self.merged = nil end
        if changed and ns.UI and ns.UI.RefreshActiveTab then pcall(ns.UI.RefreshActiveTab, ns.UI) end
    end
    Step()
end

--- Sweep a little later, out of the way of whatever is loading now.
function RecipeBook:SweepSoon(delay)
    if not (C_Timer and C_Timer.After) then return end
    C_Timer.After(delay or 2, function() self:SweepSkills() end)
end

--------------------------------------------------------------------------------
-- Who knows it
--------------------------------------------------------------------------------

--- { byRecipe = { [recipeID] = keys }, byOutput = { [itemID] = keys } },
--- read from every character's recipes and reused for a few seconds.
local function KnownIndex()
    local self = RecipeBook
    local known = self.known
    if known and Now() - known.at < KNOWN_TTL then return known end

    known = { at = Now(), byRecipe = {}, byOutput = {} }

    if ns.Recipes and ns.Recipes.GetAccountWide then
        for recipeID, recipe in pairs(ns.Recipes:GetAccountWide(true)) do
            known.byRecipe[recipeID] = recipe.knownBy
            if recipe.outputItemID then known.byOutput[recipe.outputItemID] = recipe.knownBy end
        end
    end

    self.known = known
    return known
end

--- The characters on the account who know a recipe; an empty list for none.
function RecipeBook:WhoKnows(record)
    if not record then return {} end
    local known = KnownIndex()
    return known.byRecipe[record.recipeID]
        or (record.outputItemID and known.byOutput[record.outputItemID])
        or {}
end

--- Does the character playing know it?
function RecipeBook:KnowsIt(record, knownBy)
    local me = ns.Config and ns.Config:GetCharacterKey()
    for _, key in ipairs(knownBy or self:WhoKnows(record)) do
        if key == me then return true end
    end
    return false
end

--- "you", "Ana", "Ana, Bob" or "you and Ana"; nil when nobody does. The
--- second value is true when the character playing is among them.
function RecipeBook:KnownByText(record)
    local knownBy = self:WhoKnows(record)
    if #knownBy == 0 then return nil end

    local me = ns.Config and ns.Config:GetCharacterKey()
    local mine, others = false, {}
    for _, key in ipairs(knownBy) do
        if key == me then
            mine = true
        else
            others[#others + 1] = ns.Recipes:GetShortCharacterName(key)
        end
    end
    table.sort(others)

    if mine and #others == 0 then return L["you"], true end
    if mine then return L.Format("you and %s", table.concat(others, ", ")), true end
    return table.concat(others, ", ")
end

--------------------------------------------------------------------------------
-- Where it is learned
--------------------------------------------------------------------------------

local function PlayerFaction()
    local faction = PlainString(UnitFactionGroup, "player")
    if faction == "Alliance" then return "A" end
    if faction == "Horde" then return "H" end
    return nil
end

--- Vendors of a recipe item on the player's side: { { name, zone }, ... }.
local function VendorsOf(itemID)
    local row = Book().ITEMS[itemID]
    local list = row and row.v
    if not list then return {} end

    local side = PlayerFaction()
    local vendors = {}
    for i = 1, #list - 2, 3 do
        local fac = list[i + 2] or ""
        if not side or fac == "" or fac:find(side, 1, true) then
            vendors[#vendors + 1] = { name = list[i], zone = list[i + 1] }
        end
    end
    return vendors
end

--- How a recipe is learned.
--
-- @return short, lines  short is one word for a list cell ("Trainer",
--   "Vendor", "Drop", "Quest or other", "Starter" or "Unknown"); lines are
--   the whole story for a tooltip or the detail pane, most useful first.
function RecipeBook:LearnFrom(record)
    local short, lines = nil, {}
    if not record then return L["Unknown"], lines end

    if record.starter then
        short = L["Starter"]
        lines[#lines + 1] = L["Comes with the profession"]
    end

    if record.trainerCost then
        short = short or L["Trainer"]
        lines[#lines + 1] = record.trainerCost > 0
            and L.Format("Trainer, %s", Util.FormatMoney(record.trainerCost, { noColor = true }))
            or L["Trainer"]
    end

    local drops, named, otherItem = 0, nil, false
    for _, itemID in ipairs(record.recipeItems or {}) do
        local row = Book().ITEMS[itemID]
        local vendors = VendorsOf(itemID)
        for _, vendor in ipairs(vendors) do
            short = short or L["Vendor"]
            lines[#lines + 1] = vendor.zone ~= "" and L.Format("Vendor: %s, %s", vendor.name, vendor.zone)
                or L.Format("Vendor: %s", vendor.name)
        end
        if row and (row.d or 0) > drops then drops, named = row.d, row.n end
        if #vendors == 0 and not (row and row.d) then otherItem = true end
    end

    if drops > 0 then
        short = short or L["Drop"]
        if named then
            lines[#lines + 1] = L.Format("Drops from %s", table.concat(named, ", "))
        else
            lines[#lines + 1] = L.Format("World drop (%d kinds of creature)", drops)
        end
    end

    if otherItem and record.forever then
        lines[#lines + 1] = L["New on Forever. Where to get it isn't known yet."]
    elseif otherItem then
        short = short or L["Quest or other"]
        lines[#lines + 1] = L["Recipe item from a quest, reputation or the other faction"]
    end

    if not short and record.seenInGame and not record.recipeItems then
        lines[#lines + 1] = L["Seen in a profession window, but where it's learned isn't known yet"]
    elseif not short and record.forever and not record.recipeItems then
        lines[#lines + 1] = L["New on Forever. Where to learn it isn't known yet."]
    end

    return short or L["Unknown"], lines
end

--------------------------------------------------------------------------------
-- What it is worth
--------------------------------------------------------------------------------

--- The cheapest way to get a recipe: a trainer, a vendor or the auction
--- house. Prices for recipe items come from scans and vendors seen in game,
--- then the shipped vendor price.
--
-- @return price, how ("trainer", "vendor" or "auction"), itemID
function RecipeBook:GetRecipePrice(record, extraItemID)
    local best, how, which

    local function Offer(price, way, itemID)
        if price and price > 0 and (not best or price < best) then
            best, how, which = price, way, itemID
        end
    end

    if record and record.trainerCost and record.trainerCost > 0 then
        Offer(record.trainerCost, "trainer")
    end

    for _, itemID in ipairs(self:RecipeItemsFor(record, extraItemID)) do
        local row = Book().ITEMS[itemID]
        local seenAtVendor = ns.Vendor and ns.Vendor.GetTable and ns.Vendor:GetTable()[itemID]
        if seenAtVendor then
            Offer(ns.Vendor:GetUnitPrice(itemID), "vendor", itemID)
        elseif row and row.v and #VendorsOf(itemID) > 0 then
            Offer(row[2], "vendor", itemID)
        end
        Offer(ns.Prices and ns.Prices:GetValue(itemID, "lowest"), "auction", itemID)
    end

    return best, how, which
end

--- Everything a recipe is worth, for one craft.
--
-- @return {
--   cost        materials for one craft, or nil when one has no price
--   costDetail  Cost:GetCraftCost's breakdown
--   returns     LevelUp:GetReturns: vendor, auction, disenchant, best, bestWay
--   back, backWay  the most one craft gets back, and how
--   profit      back less cost, nil when either is unknown
--   price, priceHow  the cheapest way to get the recipe
--   payback     crafts until the profit has paid for the recipe
-- }
function RecipeBook:Value(record, extraItemID)
    if not record then return nil end

    local costDetail = ns.Cost:GetCraftCost(record.recipeID, nil, nil,
        { valueOwned = true, recipe = record })
    local cost = costDetail and costDetail.priceable and costDetail.total or nil

    local returns
    if record.outputItemID and ns.LevelUp and ns.LevelUp.GetReturns then
        local ok, result = pcall(ns.LevelUp.GetReturns, ns.LevelUp, record, costDetail)
        if ok then returns = result end
    end

    local back = returns and returns.best or nil
    local profit = (cost and back) and (back - cost) or nil

    local price, priceHow = self:GetRecipePrice(record, extraItemID)
    local payback
    if price and profit and profit > 0 then
        payback = math.max(1, math.ceil(price / profit))
    end

    return {
        cost = cost,
        costDetail = costDetail,
        returns = returns,
        back = back,
        backWay = returns and returns.bestWay or nil,
        profit = profit,
        price = price,
        priceHow = priceHow,
        payback = payback,
    }
end

--------------------------------------------------------------------------------
-- The list
--------------------------------------------------------------------------------

--- Recipes of one profession (or all), valued, for the Profit tab's
--- Recipes to learn view.
--
-- @param opts.profession  a profession's name, or nil for every one
-- @param opts.includeKnown  keep recipes the character playing knows
-- @param opts.search  part of the recipe's name
-- @param opts.order  "skill" for the skill each needs, lowest first (the
--   Level Up tab's order); otherwise the most profit first
-- @return rows { recipeID, record, name, profession, skill, outputItemID,
--   value fields..., learn, known, knownBy }
function RecipeBook:List(opts)
    opts = opts or {}
    local needle = opts.search and opts.search ~= "" and opts.search:lower() or nil

    local rows = {}
    for recipeID, record in pairs((self:GetAll())) do
        if (not opts.profession or record.profession == opts.profession)
            and (not needle or (record.name or ""):lower():find(needle, 1, true)) then
            local knownBy = self:WhoKnows(record)
            local known = self:KnowsIt(record, knownBy)

            if opts.includeKnown or not known then
                local value = self:Value(record)
                local learn = self:LearnFrom(record)

                rows[#rows + 1] = {
                    recipeID = recipeID,
                    record = record,
                    name = record.name or L.Format("recipe %s", recipeID),
                    profession = record.profession,
                    skill = record.skill,
                    outputItemID = record.outputItemID,
                    cost = value.cost,
                    back = value.back,
                    backWay = value.backWay,
                    returns = value.returns,
                    auction = value.returns and value.returns.auction or nil,
                    disenchant = value.returns and value.returns.disenchant or nil,
                    profit = value.profit,
                    price = value.price,
                    priceHow = value.priceHow,
                    payback = value.payback,
                    learn = learn,
                    known = known,
                    knownBy = knownBy,
                }
            end
        end
    end

    if opts.order == "skill" then
        -- A recipe whose skill is not known (one only a profession window
        -- has shown) goes after the rest.
        table.sort(rows, function(a, b)
            local sa, sb = a.skill or math.huge, b.skill or math.huge
            if sa ~= sb then return sa < sb end
            if (a.profit or -math.huge) ~= (b.profit or -math.huge) then
                return (a.profit or -math.huge) > (b.profit or -math.huge)
            end
            return a.name < b.name
        end)
        return rows
    end

    -- Most profit first; recipes that cannot be valued go last, by skill.
    table.sort(rows, function(a, b)
        if (a.profit ~= nil) ~= (b.profit ~= nil) then return a.profit ~= nil end
        if a.profit and b.profit and a.profit ~= b.profit then return a.profit > b.profit end
        if (a.skill or 0) ~= (b.skill or 0) then return (a.skill or 0) < (b.skill or 0) end
        return a.name < b.name
    end)

    return rows
end

--------------------------------------------------------------------------------
-- The tooltip
--------------------------------------------------------------------------------

function RecipeBook:TooltipEnabled()
    if not ns.Config then return true end
    return ns.Config:Get("showRecipeValueOnTooltips") ~= false
end

local function Money(copper)
    return Util.FormatMoney(copper, { short = true })
end

local WAY_NAMES = { vendor = L["vendor"], auction = L["auction"], disenchant = L["disenchant"] }

--- Lines for a recipe item's tooltip, in ItemTooltip's `{ label, value }`
--- shape. Nothing for an item that teaches no recipe the book knows.
function RecipeBook:TooltipLines(itemID)
    local lines = {}
    if not self:TooltipEnabled() then return lines end

    -- The tooltip on screen says what skill the recipe needs on Forever.
    self:LearnSkill(itemID)

    local record = self:ForItem(itemID)
    if not record then return lines end

    -- An unlearned recipe's item has usually never been in the bags, so the
    -- client has not loaded it. Asking now means the next hover can say
    -- what it sells and disenchants for.
    if record.outputItemID and C_Item and type(C_Item.RequestLoadItemDataByID) == "function" then
        if not ItemInfo(record.outputItemID) then
            pcall(C_Item.RequestLoadItemDataByID, record.outputItemID)
        end
    end

    local needs = record.profession and record.skill and record.skill > 0
        and ("%s %d"):format(record.profession, record.skill) or record.profession
    -- What it makes, in that item's rarity colour.
    local taught = record.name or "?"
    if record.outputItemID and ns.Util and ns.Util.ColorItemName then
        taught = ns.Util.ColorItemName(record.outputItemID, taught)
    end
    lines[#lines + 1] = { L["Teaches"], taught .. (needs and ("  (" .. needs .. ")") or "") }

    local knownBy, mine = self:KnownByText(record)
    if knownBy then
        lines[#lines + 1] = { L["Known by"], knownBy, color = mine and "profit" or "text" }
    else
        lines[#lines + 1] = { L["Known by"], L["nobody on this account"], color = "warn" }
    end

    local value = self:Value(record, itemID)

    lines[#lines + 1] = { L["Cost to make"], value.cost and Money(value.cost) or L["materials not scanned"],
        not value.cost }

    if not record.outputItemID then
        lines[#lines + 1] = { L["Makes"], L["no item to sell"], true }
        return lines
    end

    if not ItemInfo(record.outputItemID) then
        lines[#lines + 1] = { L["Sells for"], L["loading, hover again"], true }
        return lines
    end

    local returns = value.returns or {}
    lines[#lines + 1] = { L["Sells for"], returns.auction and L.Format("%s after the cut", Money(returns.auction))
        or L["not scanned yet"], not returns.auction }
    if returns.disenchant then
        lines[#lines + 1] = { L["Disenchants for"], Money(returns.disenchant) }
    end
    if returns.vendor and value.backWay == "vendor" then
        lines[#lines + 1] = { L["Vendors for"], Money(returns.vendor) }
    end

    if value.profit then
        local text = Money(value.profit)
        if value.backWay and value.backWay ~= "auction" then
            text = L.Format("%s  (by %s)", text, WAY_NAMES[value.backWay] or value.backWay)
        end
        lines[#lines + 1] = { L["Profit per craft"], text, color = value.profit >= 0 and "profit" or "loss" }

        if value.payback then
            lines[#lines + 1] = { L["Pays for itself"], value.payback == 1 and L["after 1 craft"]
                or L.Format("after %d crafts", value.payback), color = "profit" }
        elseif value.profit <= 0 then
            lines[#lines + 1] = { L["Pays for itself"], L["not at today's prices"], color = "warn" }
        end
    end

    return lines
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function RecipeBook:OnEnable()
    ns.RegisterEvent(self, "PLAYER_ENTERING_WORLD", function() self:SweepSoon(15) end)
    ns.RegisterEvent(self, "AUCTION_HOUSE_CLOSED", function() self:SweepSoon(2) end)

    ns.RegisterCommand("recipes", L["list recipes you have not learned, with what each is worth"],
        function(input)
            input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if ns.ProfitTab and ns.ProfitTab.ShowRecipesToLearn then
                ns.ProfitTab.ShowRecipesToLearn(input ~= "" and input or nil)
            end
        end)
end
