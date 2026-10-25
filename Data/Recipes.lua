-- Blackthornes Tradeskills -- Data/Recipes.lua
-- Recipe discovery and caching.
--
-- GetAllRecipeIDs only returns anything while a profession window is open, so
-- recipes are harvested opportunistically when that window appears and served
-- from cache forever after. That is what makes the profit table work while you
-- are standing at the auction house with no profession open.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Recipes = ns.NewModule("Recipes")

local Util = ns.Util

-- Blizzard ships an internal test profession on the Forever beta. It has no
-- recipes and no business appearing in anyone's profession list.
-- Matched by its skill lines too (docs/FOREVER_API_FINDINGS.md), so a
-- client that words the tag differently still leaves it out.
local IGNORED_PROFESSION_PATTERN = "%[DNT%]"
local IGNORED_SKILL_LINES = { [2933] = true, [2934] = true }

-- Every profession under both of Forever's skill lines (the findings
-- file), by the English name the addon keeps. The client names them in its
-- own language ("Verzauberkunst" on a German client), so a check by name
-- alone only worked in English.
Recipes.SKILL_LINE_PROFESSIONS = {
    [2937] = "Alchemy",        [171] = "Alchemy",
    [2938] = "Blacksmithing",  [164] = "Blacksmithing",
    [2940] = "Enchanting",     [333] = "Enchanting",
    [2941] = "Engineering",    [202] = "Engineering",
    [2944] = "Herbalism",      [182] = "Herbalism",
    [2945] = "Leatherworking", [165] = "Leatherworking",
    [2946] = "Mining",         [186] = "Mining",
    [2947] = "Skinning",       [393] = "Skinning",
    [2948] = "Tailoring",      [197] = "Tailoring",
    [185] = "Cooking",         [129] = "First Aid",
}

local ENGLISH_PROFESSIONS = {}
for _, name in pairs(Recipes.SKILL_LINE_PROFESSIONS) do ENGLISH_PROFESSIONS[name] = true end

-- [the client's name for a profession] = its English name. Read from the
-- client once it answers, then kept for the session.
local clientProfessionNames

local function ClientProfessionNames()
    if clientProfessionNames then return clientProfessionNames end

    local names, any = {}, false
    local get = C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID
    if type(get) == "function" then
        for skillLineID, english in pairs(Recipes.SKILL_LINE_PROFESSIONS) do
            -- Copied inside the pcall: a secret value raises when touched.
            local ok, name = pcall(function()
                local info = get(skillLineID)
                local value = type(info) == "table" and info.professionName
                if type(value) == "string" and value ~= "" then return value .. "" end
            end)
            if ok and name then
                names[name] = english
                any = true
            end
        end
    end

    -- Era names a profession only through a spell it teaches.
    if not any and ns.EraRecipes then
        for name, english in pairs(ns.EraRecipes:ClientNames()) do
            names[name] = english
            any = true
        end
    end

    if any then clientProfessionNames = names end
    return names
end

--- The English name the addon keeps for a profession, in any client
--- language: from a profession entry ({ name, skillLineID }, as saved in
--- a character's `professions`) or a name alone. By skill line first, then
--- an English name as it is (old records), then the client's own names.
-- @return the English name, or nil when it is none of the known ones
function Recipes.EnglishProfessionName(profession)
    local skillLineID, name
    if type(profession) == "table" then
        skillLineID, name = profession.skillLineID, profession.name
    else
        name = profession
    end

    local english = type(skillLineID) == "number" and Recipes.SKILL_LINE_PROFESSIONS[skillLineID]
    if english then return english end
    if type(name) ~= "string" then return nil end
    if ENGLISH_PROFESSIONS[name] then return name end
    return ClientProfessionNames()[name]
end

--- Is this profession entry (or name) Enchanting? Never raises.
function Recipes.IsEnchanting(profession)
    local ok, english = pcall(Recipes.EnglishProfessionName, profession)
    return ok and english == "Enchanting"
end

--- Forget the client's names (for tests, whose pretend client changes).
function Recipes._ForgetProfessionNames()
    clientProfessionNames = nil
end

--------------------------------------------------------------------------------
-- Professions
--------------------------------------------------------------------------------

--- The character's professions, deduplicated.
--
-- GetAllProfessionTradeSkillLines returns each profession twice on Forever,
-- once under a modern skill-line ID and once under the classic one (e.g.
-- Leatherworking is both 2945 and 165). Both report identical skill levels, so
-- we keep the first sighting per name and drop the rest.
function Recipes:GetProfessions()
    local trade = ns.Compat:Get().tradeskill
    if not trade.hasAllProfessionLines then
        return ns.EraRecipes and ns.EraRecipes:GetProfessions() or {}
    end

    local ok, skillLines = pcall(C_TradeSkillUI.GetAllProfessionTradeSkillLines)
    if not ok or type(skillLines) ~= "table" then return {} end

    local seen, professions = {}, {}

    for _, skillLineID in ipairs(skillLines) do
        local infoOk, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, skillLineID)

        if infoOk and info and info.professionName then
            local name = info.professionName

            if not name:find(IGNORED_PROFESSION_PATTERN) and not IGNORED_SKILL_LINES[skillLineID] then
                local entry = {
                    name = name,
                    skillLineID = skillLineID,
                    skillLevel = info.skillLevel or 0,
                    maxSkillLevel = info.maxSkillLevel or 0,
                    -- Levels of zero mean the profession is listed but unlearned.
                    learned = (info.maxSkillLevel or 0) > 0,
                }

                -- Forever lists each profession under two IDs, and only one
                -- of them may carry the levels. The one that does wins,
                -- whichever the client happens to list first.
                local old = seen[name]
                if not old then
                    seen[name] = entry
                    professions[#professions + 1] = entry
                elseif entry.maxSkillLevel > old.maxSkillLevel then
                    for key, value in pairs(entry) do old[key] = value end
                end
            end
        end
    end

    table.sort(professions, function(a, b) return a.name < b.name end)
    return professions
end

--- Every skill line the client lists, learned or not, under BOTH ID spaces.
--
-- Unlike GetProfessions this keeps both of Forever's IDs for a profession,
-- because a cached recipe may carry either one.
-- @return { [skillLineID] = learned }, true when anything read as learned
local function ReadProfessionLines()
    local lines, anyLearned = {}, false

    local trade = ns.Compat:Get().tradeskill
    if not trade.hasAllProfessionLines then
        if ns.EraRecipes then return ns.EraRecipes:ProfessionLines() end
        return lines, false
    end

    local ok, skillLines = pcall(C_TradeSkillUI.GetAllProfessionTradeSkillLines)
    if not ok or type(skillLines) ~= "table" then return lines, false end

    -- Forever lists each profession under two IDs and only one of them may
    -- carry the levels, so a line counts as learned when any line of the
    -- same profession is. Read alone, Tailoring's other ID said "not
    -- learned" and its crafts were hidden as a dropped profession.
    local nameOf, learnedName = {}, {}
    for _, skillLineID in ipairs(skillLines) do
        local infoOk, learned, name = pcall(function()
            local info = C_TradeSkillUI.GetProfessionInfoBySkillLineID(skillLineID)
            if type(info) ~= "table" then return nil end
            local value = info.professionName
            return (info.maxSkillLevel or 0) > 0,
                type(value) == "string" and value ~= "" and value .. "" or nil
        end)
        if infoOk and learned ~= nil and type(skillLineID) == "number" then
            lines[skillLineID] = learned
            name = Recipes.SKILL_LINE_PROFESSIONS[skillLineID] or name
            nameOf[skillLineID] = name
            if learned then
                anyLearned = true
                if name then learnedName[name] = true end
            end
        end
    end

    for skillLineID, name in pairs(nameOf) do
        if learnedName[name] then lines[skillLineID] = true end
    end

    return lines, anyLearned
end

--- Does a saved line list say this skill line's profession is learned
--- under its other ID? Records saved before ReadProfessionLines joined the
--- two IDs can hold false for one beside true for the other.
local function SiblingLearned(lines, skillLineID)
    local name = Recipes.SKILL_LINE_PROFESSIONS[skillLineID]
    if not name then return false end
    for otherID, other in pairs(Recipes.SKILL_LINE_PROFESSIONS) do
        if other == name and otherID ~= skillLineID and lines[otherID] == true then return true end
    end
    return false
end

--- Is this cached recipe from a profession the character has since dropped?
--
-- Only when the last reliable read of that character's professions listed
-- the recipe's skill line as not learned. Anything unknown (no read yet, a
-- recipe with no skill line, a skill line the list did not name) counts as
-- kept. Nothing is deleted: learn the profession again and its crafts come
-- back on the next read.
function Recipes:IsDropped(recipe, characterKey)
    if type(recipe) ~= "table" or not recipe.skillLineID then return false end

    local record = ns.db and ns.db.characters
        and ns.db.characters[characterKey or ns.Config:GetCharacterKey()]
    local lines = type(record) == "table" and record.professionLines
    if type(lines) ~= "table" then return false end

    return lines[recipe.skillLineID] == false and not SiblingLearned(lines, recipe.skillLineID)
end

--- This character's professions, with their levels.
--
-- Read from the client, and from the last good read saved for this character
-- when the client has not loaded skill levels yet (just after login or a
-- loading screen, when everything reads as level 0). Without it, Recipes to
-- learn lost its SKILL colours until the levels arrived (a player saw them
-- vanish and come back on their own, 2026-10-09).
function Recipes:GetLearnedProfessions()
    local learned, byName = {}, {}
    for _, profession in ipairs(self:GetProfessions()) do
        if profession.learned then
            learned[#learned + 1] = profession
            byName[profession.name] = true
        end
    end

    local record = self.GetCharacterRecord and self:GetCharacterRecord(false)
    for _, profession in ipairs(type(record) == "table" and record.professions or {}) do
        if type(profession) == "table" and profession.learned and profession.name
            and not byName[profession.name] then
            learned[#learned + 1] = profession
            byName[profession.name] = true
        end
    end

    table.sort(learned, function(a, b) return a.name < b.name end)
    return learned
end

--------------------------------------------------------------------------------
-- Cache access
--------------------------------------------------------------------------------

-- A plain, non-empty string from a client call, or nil. Tested and copied
-- inside the pcall: in a dungeon the client can hand back a name that raises
-- when compared or joined, and a stored one would raise forever.
local function PlainString(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(function(...)
        local v = fn(...)
        if type(v) == "string" and v ~= "" then return v .. "" end
    end, ...)
    if ok then return value end
    return nil
end

local function GetCharacterRecord(create)
    if not ns.db then return nil end

    local key = ns.Config:GetCharacterKey()
    local characters = ns.db.characters

    local record = characters[key]

    -- No record is made under the old name-and-realm key. That key is only
    -- handed out when the game would not give the character's GUID (a
    -- /reload inside a dungeon), and a record made then stayed for good as a
    -- second copy of this character: its bags counted again as an alt's, its
    -- recipes listed twice. The next read, with the GUID, makes the real one.
    local config = ns.Config
    if not record and create and config.characterKey == nil
        and config.GetLegacyCharacterKey and key == config:GetLegacyCharacterKey() then
        create = false
    end

    if not record and create then
        -- Plain copies: inside a dungeon the client can hand back names
        -- that raise when compared, and a stored one would raise forever.
        record = {
            name = PlainString(UnitName, "player") or "Unknown",
            realm = PlainString(GetRealmName) or "?",
            recipes = {},
            inventory = {},
        }
        characters[key] = record
    end

    if record and not Recipes.identityStamped and key == ns.Config.characterKey then
        -- Protected: a name the client will not let us compare must not stop
        -- the recipe cache from loading.
        pcall(Recipes.StampIdentity, Recipes, record)
    end

    return record
end

Recipes.GetCharacterRecord = function(_, create) return GetCharacterRecord(create) end

--- Cached recipes for the logged-in character.
function Recipes:GetAll()
    local record = GetCharacterRecord(false)
    return record and record.recipes or {}
end

function Recipes:Get(recipeID)
    return self:GetAll()[recipeID]
end

--- A recipe from any character's cache, preferring the logged-in one.
--
-- Lets the cost and profit engines reason about crafts that live on an alt,
-- without every caller having to know which character owns what.
-- @return recipe, characterKey
function Recipes:GetAny(recipeID)
    local mine = self:GetAll()[recipeID]
    local selfKey = ns.Config:GetCharacterKey()
    if mine and not self:IsDropped(mine, selfKey) then
        return mine, selfKey
    end

    if not ns.db then return mine, mine and selfKey or nil end

    -- A profession this character dropped: an alt who still has it is the
    -- one who can make it.
    for characterKey, record in pairs(ns.db.characters) do
        local recipe = record.recipes and record.recipes[recipeID]
        if recipe and characterKey ~= selfKey and not self:IsDropped(recipe, characterKey) then
            return recipe, characterKey
        end
    end

    if mine then return mine, selfKey end

    for characterKey, record in pairs(ns.db.characters) do
        local recipe = record.recipes and record.recipes[recipeID]
        if recipe then
            return recipe, characterKey
        end
    end
end

--- Who a record belongs to, written once a session so that characters
--- sharing a first name can be told apart on screen.
function Recipes:StampIdentity(record)
    self.identityStamped = true

    local guid = ns.Config.characterKey
    if guid then record.guid = guid end

    local name = PlainString(UnitName, "player")
    if name then record.name = name end

    local surname = ns.Config:ReadSurname()
    if surname then record.surname = surname end

    -- Mail only goes to characters of the same faction, so the shared
    -- queue only gives one character's sub-crafts to another of its side.
    local faction = PlainString(UnitFactionGroup, "player")
    if faction then record.faction = faction end

    local classOk, className = pcall(UnitClass, "player")
    if classOk and type(className) == "string" then record.class = className end

    local levelOk, level = pcall(UnitLevel, "player")
    if levelOk and tonumber(level) then record.level = tonumber(level) end

    -- Now that the last name is known, an old record saved under the whole
    -- name is this character's too (Config:AdoptLegacyCharacter).
    if guid and ns.Config.AdoptLegacyCharacter then
        pcall(ns.Config.AdoptLegacyCharacter, ns.Config, guid)
    end
end

--- The character's name, for display: first and last name when the last one
--- is known. Old keys are "Name-Realm"; new ones are the character's GUID.
function Recipes:GetCharacterName(characterKey)
    if not characterKey then return "?" end
    if ns.Characters then characterKey = ns.Characters:Canonical(characterKey) end

    local record = ns.db and ns.db.characters[characterKey]
    if type(record) == "table" and type(record.name) == "string" then
        if record.surname then
            return record.name .. " " .. record.surname
        end
        return record.name
    end

    return (characterKey:match("^([^-]+)")) or characterKey
end

--- The name shown wherever a character is named. It was once shortened
--- ("Bob", or "Bob B." when two shared a first name), but the owner's rule
--- (2026-10-11) is never to shorten a last name: Forever names are first and
--- last together, and a short one could not address a mail. So it is the
--- full name now; the function is kept because Equipment and Butler call it.
function Recipes:GetShortCharacterName(characterKey)
    return self:GetCharacterName(characterKey)
end

--- What to add after a name that another character also has.
local function Distinguish(record)
    if type(record) ~= "table" then return nil end

    if record.level and record.class then
        return L.Format("level %d %s", record.level, record.class)
    end
    if record.class then return record.class end
    if not record.guid then return L["older record"] end
end

local function Text(value)
    return type(value) == "string" and value ~= "" and value or nil
end

--- What the Characters tab shows beside the recipes: side, race, class,
--- XP, rest, zone, played time, when last seen and mail waiting. Every field
--- is nil when the record does not have it (one saved before these notes,
--- or shared from another account without them).
function Recipes:AddNotes(entry, record)
    local Notes = ns.CharacterNotes
    entry.faction = Text(record.faction)
    entry.class = Text(record.class)
    entry.classFile = Text(record.classFile)
    entry.race = Text(record.race)
    entry.level = type(record.level) == "number" and record.level or nil
    entry.zone = Text(record.zone)
    entry.seenAt = tonumber(record.seenAt) or tonumber(record.inventoryAt)
    if Notes then
        entry.levelShare = Notes.LevelShare(record)
        entry.rested, entry.restedGuess = Notes.Rested(record, entry.isCurrent)
        entry.played = Notes.Played(record, entry.isCurrent)
    end

    -- Mail waiting, as last read at a mailbox.
    if type(record.mail) == "table" then
        local count = 0
        for _, n in pairs(record.mail) do
            if type(n) == "number" and n > 0 then count = count + n end
        end
        entry.mailCount = count
    end
end

--- Every known character, newest data first.
function Recipes:GetCharacters()
    local characters = {}
    if not ns.db then return characters end

    local selfKey = ns.Config:GetCharacterKey()

    for characterKey, record in pairs(ns.db.characters) do
        characters[#characters + 1] = {
            key = characterKey,
            name = self:GetCharacterName(characterKey),
            realm = record.realm,
            gold = record.gold,
            professions = record.professions,
            recipeCount = record.recipes and Util.Count(record.recipes) or 0,
            inventoryAt = record.inventoryAt,
            bankAt = record.bankAt,
            isCurrent = characterKey == selfKey,
            -- A character from another account of yours (Logic/AccountLink.lua):
            -- the name of the character it came through.
            linkedFrom = type(record.linkedFrom) == "string" and record.linkedFrom or nil,
        }
        self:AddNotes(characters[#characters], record)
    end

    -- Two characters showing the same name get told apart by level and class.
    local seen = {}
    for _, entry in ipairs(characters) do
        seen[entry.name] = (seen[entry.name] or 0) + 1
    end

    for _, entry in ipairs(characters) do
        if seen[entry.name] > 1 then
            local extra = Distinguish(ns.db.characters[entry.key])
            if extra then
                entry.name = ("%s (%s)"):format(entry.name, extra)
            end
        end
    end

    table.sort(characters, function(a, b)
        if a.isCurrent ~= b.isCurrent then return a.isCurrent end
        if a.name ~= b.name then return a.name < b.name end
        return a.key < b.key
    end)

    return characters
end

function Recipes:ForgetCharacter(characterKey)
    if not ns.db or characterKey == ns.Config:GetCharacterKey() then return false end

    ns.db.characters[characterKey] = nil

    -- Its listings stop counting toward Keep in stock too.
    for _, record in pairs(ns.db.postedAuctions or {}) do
        if type(record) == "table" and record.byCharacter then
            record.byCharacter[characterKey] = nil
        end
    end

    ns.Cost:InvalidateIndex()
    return true
end

function Recipes:Count()
    return Util.Count(self:GetAll())
end

--- Every cached recipe across all characters, tagged with who knows it.
-- @param skipDropped  leave out crafts of professions a character dropped
function Recipes:GetAccountWide(skipDropped)
    local results = {}
    if not ns.db then return results end

    for characterKey, record in pairs(ns.db.characters) do
        for recipeID, recipe in pairs(record.recipes or {}) do
            local existing = results[recipeID]
            if skipDropped and self:IsDropped(recipe, characterKey) then
                -- Left out, as if this character did not know it.
            elseif existing then
                existing.knownBy[#existing.knownBy + 1] = characterKey
            else
                local copy = Util.CopyDeep(recipe)
                copy.knownBy = { characterKey }
                results[recipeID] = copy
            end
        end
    end

    return results
end

--- Every saved recipe of every character, not copied and not merged: one
--- entry per character that knows it. For readers that only look (an
--- output's recipe ID) and must not pay for GetAccountWide's copies.
function Recipes:GetAccountWideOutputs()
    local results = {}
    if not ns.db then return results end
    for _, record in pairs(ns.db.characters) do
        for _, recipe in pairs(record.recipes or {}) do
            results[#results + 1] = recipe
        end
    end
    return results
end

--- Which skill line a recipe belongs to.
--
-- GetRecipeInfo does not carry skillLineID on Forever -- it comes back nil for
-- every recipe, which silently empties the profession filter. These two calls
-- do report it.
local function GetRecipeSkillLine(recipeID, info)
    if info and info.skillLineID then return info.skillLineID end

    if Util.HasFunction("C_TradeSkillUI.GetTradeSkillLineForRecipe") then
        local ok, skillLineID = pcall(C_TradeSkillUI.GetTradeSkillLineForRecipe, recipeID)
        if ok and skillLineID then return skillLineID end
    end

    if Util.HasFunction("C_TradeSkillUI.GetProfessionInfoByRecipeID") then
        local ok, professionInfo = pcall(C_TradeSkillUI.GetProfessionInfoByRecipeID, recipeID)
        if ok and professionInfo and professionInfo.professionID then
            return professionInfo.professionID
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- Lookup
--------------------------------------------------------------------------------

--- A clickable link for a recipe's output, falling back to its plain name.
-- Players recognise the item, not the recipe ID, so this is what gets shown.
--
-- The item's own link comes first: it carries the item's rarity colour, which
-- the profession window's recipe link did not always (a chat line read
-- "made 1 of [Bolt of Silk Cloth]" in plain white). Without either, the name
-- in its rarity colour.
function Recipes:GetDisplayLink(recipeID)
    local recipe = self:Get(recipeID) or (self.GetAny and self:GetAny(recipeID))
    local outputItemID = recipe and recipe.outputItemID

    if outputItemID and Util.HasFunction("C_Item.GetItemInfo") then
        local ok, _, link = pcall(C_Item.GetItemInfo, outputItemID)
        if ok and link then return link end
    end

    if Util.HasFunction("C_TradeSkillUI.GetRecipeItemLink") then
        local ok, link = pcall(C_TradeSkillUI.GetRecipeItemLink, recipeID)
        if ok and type(link) == "string" and link ~= "" then
            if outputItemID and Util.ColorItemName and not link:find("|c", 1, true) then
                return Util.ColorItemName(outputItemID, link)
            end
            return link
        end
    end

    local name = (recipe and recipe.name) or L.Format("recipe %s", tostring(recipeID))
    if outputItemID and Util.ColorItemName then return Util.ColorItemName(outputItemID, name) end
    return name
end

--- Resolve whatever the player typed into matching recipes.
--
-- Accepts a shift-clicked item link, a recipe or item ID, or any part of a
-- recipe name. Returns an array of matches, best first.
function Recipes:Find(query)
    query = (query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then return {} end

    local all = self:GetAll()

    -- A shift-clicked link carries the item ID, which is the exact answer.
    local linkedItemID = tonumber(query:match("item:(%d+)"))
    if linkedItemID then
        for recipeID, recipe in pairs(all) do
            if recipe.outputItemID == linkedItemID then
                return { recipe }
            end
        end
        return {}
    end

    -- A bare number is either a recipe ID or an output item ID.
    local number = tonumber(query)
    if number then
        if all[number] then return { all[number] } end

        for _, recipe in pairs(all) do
            if recipe.outputItemID == number then
                return { recipe }
            end
        end
        return {}
    end

    -- Otherwise match on name. Exact beats prefix beats substring, so typing
    -- "bolt of linen" does not lose to "bolt of linen cloth bandage".
    local needle = query:lower()
    local exact, prefix, substring = {}, {}, {}

    for _, recipe in pairs(all) do
        local name = (recipe.name or ""):lower()

        if name == needle then
            exact[#exact + 1] = recipe
        elseif name:sub(1, #needle) == needle then
            prefix[#prefix + 1] = recipe
        elseif name:find(needle, 1, true) then
            substring[#substring + 1] = recipe
        end
    end

    local matches = {}
    for _, list in ipairs({ exact, prefix, substring }) do
        table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
        for _, recipe in ipairs(list) do
            matches[#matches + 1] = recipe
        end
    end

    return matches
end

--------------------------------------------------------------------------------
-- Harvesting
--------------------------------------------------------------------------------

--- Read every recipe the open profession window exposes into the cache.
--- Is the open profession window someone else's?
--
-- A [Tailoring] link in chat, a guild member's list or an NPC crafter all
-- open the same window, and their recipes read as learned. Saved as this
-- character's, they put crafts in Profit and Level Up that nobody here can
-- make, with no way to remove them.
local function ShowingSomeoneElses()
    for _, name in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsNPCCrafting" }) do
        local fn = C_TradeSkillUI and C_TradeSkillUI[name]
        if type(fn) == "function" then
            local ok, yes = pcall(function() return fn() == true end)
            if ok and yes then return true end
        end
    end
    return false
end

Recipes.ShowingSomeoneElses = ShowingSomeoneElses

--- Is the open profession window still filling in or switching profession?
--
-- While it is, GetRecipeInfo can answer for a recipe with a difficulty that
-- is not this character's: a player saw the Level Up colours vanish and come
-- back on their own (2026-10-09). A client without these calls never waits.
local function WindowSettling()
    local api = C_TradeSkillUI
    if type(api) ~= "table" then return false end

    for _, call in ipairs({ { "IsTradeSkillReady", false }, { "IsDataSourceChanging", true } }) do
        local fn = api[call[1]]
        if type(fn) == "function" then
            local ok, answer = pcall(function() return fn() == call[2] end)
            if ok and answer then return true end
        end
    end
    return false
end

Recipes.WindowSettling = WindowSettling

-- Counted up whenever a profession window opens, closes or changes what it
-- shows. A harvest that sees it move stops: the recipes it has left belong
-- to a window that is gone, and the colours they would read are not theirs.
Recipes.windowGeneration = 0

function Recipes:OnWindowChanged()
    self.windowGeneration = (self.windowGeneration or 0) + 1
end

--- What a harvest's answers depend on that can change while the window stays
--- open: how many recipes it lists, and every profession's skill level (a
--- point gained turns recipe colours). Nil when the client will not say.
function Recipes:HarvestSignature()
    if ns.Compat:Get().tradeskill.mode ~= "modern" then
        return ns.EraRecipes and ns.EraRecipes:Signature() or nil
    end

    local ok, recipeIDs = pcall(C_TradeSkillUI.GetAllRecipeIDs)
    if not ok or type(recipeIDs) ~= "table" then return nil end

    local parts = { #recipeIDs }
    if ns.SkillUp and ns.SkillUp.ReadSkillLevels then
        local levels = ns.SkillUp:ReadSkillLevels()
        local lines = {}
        for skillLineID in pairs(levels) do lines[#lines + 1] = skillLineID end
        table.sort(lines)
        for _, skillLineID in ipairs(lines) do
            parts[#parts + 1] = skillLineID .. "=" .. tostring(levels[skillLineID])
        end
    end
    return table.concat(parts, ",")
end

--- Is a craft casting, or a run of them under way?
local function CraftUnderWay()
    if ns.Crafting and ns.Crafting.active then return true end

    local api = C_TradeSkillUI
    local repeating = type(api) == "table" and api.IsRecipeRepeating
    if type(repeating) == "function" then
        local ok, yes = pcall(function() return repeating() == true end)
        if ok and yes then return true end
    end

    local castBar = ns.CastBarOnTop
    if castBar and castBar.IsCrafting then
        local ok, yes = pcall(castBar.IsCrafting, castBar)
        if ok and yes then return true end
    end
    return false
end

--- Whether a list update in the middle of a run of crafts has nothing new to
--- read. Every craft changes the bags, the window says its list changed, and
--- reading every recipe again each time was a hitch per craft that a player
--- saw as a jerky craft bar (2026-10-09). The bags are not in the cache, so
--- such an update is skipped unless the same window has since listed more
--- recipes or a skill point came, which still reads at once.
function Recipes:NothingNewMidCraft()
    local last = self.lastHarvest
    if not last or last.generation ~= self.windowGeneration then return false end
    if not CraftUnderWay() then return false end
    local signature = self:HarvestSignature()
    return signature ~= nil and signature == last.signature
end

function Recipes:Harvest()
    local trade = ns.Compat:Get().tradeskill
    if trade.mode == "legacy" and ns.EraRecipes then return ns.EraRecipes:Harvest() end
    if trade.mode ~= "modern" then return false end
    if self.harvesting then return false end
    if ShowingSomeoneElses() then return false end

    local ok, recipeIDs = pcall(C_TradeSkillUI.GetAllRecipeIDs)
    if not ok or type(recipeIDs) ~= "table" or #recipeIDs == 0 then
        return false
    end

    local record = GetCharacterRecord(true)
    if not record then return false end

    self.harvesting = true
    local generation = self.windowGeneration
    local signature = self:HarvestSignature()

    -- Difficulties are only readable while this window is open, so they are
    -- collected alongside the recipes rather than looked up later.
    if ns.SkillUp then ns.SkillUp:BeginCapture() end

    local added, updated = 0, 0

    local worker = Util.NewWorker({
        budgetMs = ns.Config:Get("scanBudgetMs") or 8,

        onItem = function(recipeID, _, worker)
            -- The window closed or moved on: the next harvest reads it.
            if Recipes.windowGeneration ~= generation then
                worker:Cancel()
                return
            end

            local infoOk, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
            if not infoOk or not info then return end

            local schematicOk, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
            if not schematicOk or not schematic then return end

            local reagents = {}
            for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
                -- reagentType 1 is a required basic reagent. Optional and
                -- finishing slots are not part of the base cost.
                local isRequired = (slot.reagentType == nil or slot.reagentType == 1)
                local first = slot.reagents and slot.reagents[1]

                if isRequired and first and first.itemID and (slot.quantityRequired or 0) > 0 then
                    reagents[#reagents + 1] = {
                        itemID = first.itemID,
                        quantity = slot.quantityRequired,
                    }
                end
            end

            if #reagents == 0 then return end

            local skillLineID = GetRecipeSkillLine(recipeID, info)

            -- Every recipe the window shows, learned or not, goes in the
            -- account's recipe book (Logic/RecipeBook.lua), so a recipe can
            -- be valued before anyone buys it. No character's name in it.
            if ns.RecipeBook and ns.RecipeBook.NoteSeen then
                pcall(ns.RecipeBook.NoteSeen, ns.RecipeBook, recipeID, {
                    name = info.name or schematic.name,
                    outputItemID = schematic.outputItemID,
                    quantityMin = schematic.quantityMin or 1,
                    quantityMax = schematic.quantityMax or schematic.quantityMin or 1,
                    skillLineID = skillLineID,
                    reagents = reagents,
                    learned = info.learned ~= false,
                })
            end

            -- Recipes the character has not learned cannot be crafted, so they
            -- have no place in a "what should I make" table.
            if info.learned == false then return end

            local existing = record.recipes[recipeID]
            if existing then updated = updated + 1 else added = added + 1 end

            -- Whether this still skills you up, kept with the recipe so the
            -- Profit tab can say so at the auction house, where no profession
            -- window is open to ask.
            local skillUp = existing and existing.skillUp or nil

            -- A craft that can only be made every so often (a transmute,
            -- Mooncloth): Logic/Cooldowns.lua keeps when it is ready.
            if ns.Cooldowns and ns.Cooldowns.NoteRecipe then
                pcall(ns.Cooldowns.NoteRecipe, ns.Cooldowns, recipeID, info)
            end

            if ns.SkillUp then
                skillUp = ns.SkillUp:Capture(recipeID, info, skillLineID, skillUp)
            end

            record.recipes[recipeID] = {
                recipeID = recipeID,
                name = info.name or schematic.name,
                outputItemID = schematic.outputItemID,
                quantityMin = schematic.quantityMin or 1,
                quantityMax = schematic.quantityMax or schematic.quantityMin or 1,
                skillLineID = skillLineID,
                skillUp = skillUp,
                reagents = reagents,
                cachedAt = time(),
            }
        end,

        onDone = function()
            self.harvesting = false
            record.recipesCachedAt = time()
            self.lastHarvest = { generation = generation, signature = signature }

            if ns.SkillUp then ns.SkillUp:EndCapture() end

            if added > 0 or updated > 0 then
                ns.Debug(("saved %d new and %d updated recipe(s)"):format(added, updated))
            end
            if added > 0 and ns.Mail and ns.Mail.ForgetOutputSet then ns.Mail:ForgetOutputSet() end

            if ns.UI and ns.UI.OnRecipesUpdated then
                ns.UI:OnRecipesUpdated()
            end
        end,

        onCancel = function()
            self.harvesting = false
            if ns.SkillUp then ns.SkillUp:EndCapture() end
        end,
    })

    worker:Start(recipeIDs)
    return true
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function Recipes:OnTradeSkillUpdate()
    -- A profession window is open, so skill levels are certainly loaded now.
    -- This is the read that fixes a zeroed one from login.
    self:RefreshProfessions()

    -- The list fires repeatedly while a profession window settles; coalesce.
    if self.harvestTimer then
        self.harvestTimer:Cancel()
    end

    -- Not while the window is still settling, but never put off for good:
    -- a client that always says "not ready" still gets read.
    local waits = 0
    local function Try()
        if WindowSettling() and waits < 6 then
            waits = waits + 1
            Recipes.harvestTimer = C_Timer.NewTimer(0.5, Try)
            return
        end
        Recipes.harvestTimer = nil
        if Recipes:NothingNewMidCraft() then return end
        Recipes:Harvest()
    end

    self.harvestTimer = C_Timer.NewTimer(0.5, Try)
end

--- A fresh profession read with the saved professions it left out put
--- back. With one profession window open, Forever can answer only for that
--- profession and say nothing of the others, so a read made then dropped
--- every other profession from the saved list, and with it their levels
--- (Butler's skill-up line showed only Tailoring, 2026-10-20). A saved one
--- goes only when the fresh read names it and says it is not learned.
-- @return a new list, fresh's entries first
function Recipes.KeepUnread(fresh, saved)
    local function Key(profession)
        return Recipes.EnglishProfessionName(profession) or profession.name
    end

    local merged, named = {}, {}
    for _, profession in ipairs(fresh or {}) do
        merged[#merged + 1] = profession
        local key = Key(profession)
        if key then named[key] = true end
    end

    for _, profession in ipairs(type(saved) == "table" and saved or {}) do
        local key = type(profession) == "table" and profession.learned and Key(profession)
        if key and not named[key] then
            merged[#merged + 1] = profession
            named[key] = true
        end
    end

    table.sort(merged, function(a, b) return (a.name or "") < (b.name or "") end)
    return merged
end

--- Re-read professions into the cache, refusing to make things worse.
--
-- At PLAYER_LOGIN the profession list is already enumerable but the skill
-- levels are not loaded yet, so every profession reads as maxSkillLevel 0 and
-- therefore unlearned. That was harmless while the database was rebuilt each
-- session; now that it persists, a bad read at login would stick.
--
-- So a read with nothing learned is only accepted when there is nothing
-- better already stored.
-- @return true if the cache now holds a learned profession
-- @return true if this read itself found one (the login retry waits for that)
function Recipes:RefreshProfessions()
    local record = GetCharacterRecord(true)
    if not record then return false end

    local fresh = self:GetProfessions()

    local function AnyLearned(list)
        for _, profession in ipairs(list or {}) do
            if profession.learned then return true end
        end
        return false
    end

    if AnyLearned(fresh) then
        record.professions = Recipes.KeepUnread(fresh, record.professions)
    elseif not AnyLearned(record.professions) then
        record.professions = fresh
    end

    -- Which skill lines are learned, for hiding the crafts of a dropped
    -- profession. Taken only from a read that found something learned: at
    -- login everything reads as unlearned until skill levels arrive, and
    -- trusting that would hide every craft this character has.
    local lines, linesLearned = ReadProfessionLines()
    if linesLearned then
        -- The sub-craft index is built from the crafts not dropped, so it is
        -- rebuilt when the lines change. Left alone, a dropped profession's
        -- crafts stayed on offer as sub-crafts until the next harvest.
        local changed = false
        local old = record.professionLines or {}
        for skillLineID, learned in pairs(lines) do
            if old[skillLineID] ~= learned then changed = true end
        end
        for skillLineID in pairs(old) do
            if lines[skillLineID] == nil then changed = true end
        end
        record.professionLines = lines
        if changed and ns.Cost and ns.Cost.InvalidateIndex then ns.Cost:InvalidateIndex() end
    end

    return AnyLearned(record.professions), AnyLearned(fresh)
end

function Recipes:OnEnable()
    ns.RegisterEvent(self, "TRADE_SKILL_LIST_UPDATE", self.OnTradeSkillUpdate)
    ns.RegisterEvent(self, "TRADE_SKILL_SHOW", self.OnTradeSkillUpdate)

    -- A harvest that outlives its window stops (see Harvest). The data
    -- source events are retail's, for switching profession with the window
    -- open; a client without them still has show and close.
    ns.RegisterEvent(self, "TRADE_SKILL_SHOW", self.OnWindowChanged)
    ns.RegisterEvent(self, "TRADE_SKILL_CLOSE", self.OnWindowChanged)
    ns.RegisterEvent(self, "TRADE_SKILL_DATA_SOURCE_CHANGING", self.OnWindowChanged)
    ns.RegisterEvent(self, "TRADE_SKILL_DATA_SOURCE_CHANGED", self.OnWindowChanged)
    ns.RegisterEvent(self, "TRADE_SKILL_DATA_SOURCE_CHANGED", self.OnTradeSkillUpdate)

    -- Learning or dropping a profession, read at once rather than at the
    -- next profession window. Not every client has this event; RegisterEvent
    -- says so by returning false, and the reads above still cover it.
    ns.RegisterEvent(self, "SKILL_LINES_CHANGED", function() Recipes:RefreshProfessions() end)

    -- Skill levels arrive after login, so the first read is usually zeroes.
    -- Retried a few times rather than once: how long it takes varies, and
    -- the cost of asking again is a single API call.
    self:RefreshProfessions()

    local attempts = 0
    self.professionTimer = C_Timer.NewTicker(3, function()
        attempts = attempts + 1

        -- Stopped on a fresh read that found something: the saved list
        -- already holds last session's professions, so it proves nothing
        -- about whether this session's skill levels have arrived yet.
        local _, freshLearned = Recipes:RefreshProfessions()
        if freshLearned or attempts >= 5 then
            if Recipes.professionTimer then
                Recipes.professionTimer:Cancel()
                Recipes.professionTimer = nil
            end
        end
    end)
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

ns.RegisterCommand("professions", L["list this character's professions"], function()
    local professions = ns.Recipes:GetProfessions()
    if #professions == 0 then
        ns.Print(L["no professions found"])
        return
    end

    ns.Print(L["professions"])
    for _, profession in ipairs(professions) do
        if profession.learned then
            ns.PrintRaw(("  |c%s%s|r %d/%d"):format(
                ns.COLORS.accent, profession.name, profession.skillLevel, profession.maxSkillLevel))
        else
            ns.PrintRaw(L.Format("  |c%s%s (not learned)|r", ns.COLORS.muted, profession.name))
        end
    end

    ns.PrintRaw(L.Format("  |c%s%d recipe(s) saved|r", ns.COLORS.muted, ns.Recipes:Count()))
end)
