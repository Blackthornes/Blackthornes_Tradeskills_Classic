-- Blackthornes Tradeskills -- Logic/SkillUp.lua
-- Which crafts still raise your skill.
--
-- The profit table answers "what is worth making for gold". While a profession
-- is still climbing, that is only half the question: a craft that earns a
-- little AND takes you a point closer to the next recipe is worth more of your
-- materials than one that only earns, and the two facts live in different
-- places in the client.
--
-- WoW's answer to "will this skill me up" is the colour the profession window
-- paints a recipe: orange is guaranteed, yellow is very likely, green is a
-- small chance, grey is never. What is NOT known ahead of time is which of the
-- several APIs that carry that colour exist on this client, so nothing here
-- assumes one. Every source is tried in turn, the one that answered is
-- recorded, and `/bts skillup` reports what actually came back rather than
-- what was hoped for. If none of them answer, no craft is ever starred and the
-- command says so in as many words.

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local SkillUp = ns.NewModule("SkillUp")

local Util = ns.Util

-- The four tiers, best chance of a point first.
local TIER_RANK = { optimal = 1, medium = 2, easy = 3, trivial = 4 }

-- Tiers that count as "this will skill you up". Green is a real chance, but a
-- small enough one that marking it would put a star on most of the list and
-- the star would stop meaning anything.
local WORTH_IT = { optimal = true, medium = true }

SkillUp.TIER_LABEL = {
    optimal = L["guaranteed skill up"],
    medium  = L["very likely skill up"],
    easy    = L["small chance of a skill up"],
    trivial = L["no skill up"],
}

-- The game's own difficulty colours, used when the client does not expose its
-- table. Players read orange and yellow here without being told what they mean.
local TIER_COLOR = {
    optimal = { 1.00, 0.50, 0.25 },
    medium  = { 1.00, 1.00, 0.00 },
    easy    = { 0.25, 0.75, 0.25 },
    trivial = { 0.50, 0.50, 0.50 },
}

--- Colour for a tier, preferring the client's own table so the star and the
--- tooltip match the profession window exactly.
function SkillUp:GetTierColor(tier)
    local swatch = type(TradeSkillTypeColor) == "table" and TradeSkillTypeColor[tier]
    if type(swatch) == "table" and swatch.r then
        return swatch.r, swatch.g, swatch.b
    end

    local colour = TIER_COLOR[tier] or TIER_COLOR.trivial
    return colour[1], colour[2], colour[3]
end

--- The same colour as an inline "|cffRRGGBB" escape.
--
-- The components are fractions, so they are rounded before formatting: this
-- client's string.format refuses a non-integer for %x, and 0.5 * 255 is one.
function SkillUp:GetTierColorCode(tier)
    local r, g, b = self:GetTierColor(tier)
    return ("|cff%02x%02x%02x"):format(
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

function SkillUp:GetTierLabel(tier)
    return self.TIER_LABEL[tier or ""] or L["unknown"]
end

--------------------------------------------------------------------------------
-- Reading a difficulty out of the client
--------------------------------------------------------------------------------

--- Map an Enum.TradeskillRelativeDifficulty value onto a tier, by NAME.
--
-- Deliberately not by number. Retail's enum happens to run Optimal, Medium,
-- Easy, Trivial, but an addon that hardcodes 0-3 and is wrong has every craft
-- in the list wearing the wrong colour with nothing to show it is wrong. If
-- the enum is absent the value is reported as unmapped instead, which is a
-- fact someone can act on.
local ENUM_FIELDS = { Optimal = "optimal", Medium = "medium", Easy = "easy", Trivial = "trivial" }

local function TierFromEnum(value)
    local enum = type(Enum) == "table" and Enum.TradeskillRelativeDifficulty
    if type(enum) ~= "table" then return nil end

    for field, tier in pairs(ENUM_FIELDS) do
        if enum[field] ~= nil and enum[field] == value then return tier end
    end

    return nil
end

--- A tier straight from a word, which is how the classic list reports it.
local function TierFromWord(value)
    if type(value) ~= "string" then return nil end

    local word = value:lower()
    if TIER_RANK[word] then return word end

    return nil
end

local function TierFrom(value)
    if value == nil then return nil end
    return TierFromWord(value) or TierFromEnum(value)
end

--- Every place a difficulty might be, best first.
--
-- Each returns the tier it worked out and the raw value it was given, so a
-- value that could not be mapped is still reported rather than silently
-- becoming "no answer".
local SOURCES = {
    {
        key = "relativeDifficulty",
        label = "GetRecipeInfo().relativeDifficulty",
        read = function(_, info)
            local value = info and info.relativeDifficulty
            return TierFrom(value), value
        end,
    },
    {
        key = "difficulty",
        label = "GetRecipeInfo().difficulty",
        read = function(_, info)
            local value = info and info.difficulty
            return TierFrom(value), value
        end,
    },
    {
        key = "recipeDifficulty",
        label = "C_TradeSkillUI.GetRecipeDifficulty()",
        read = function(recipeID)
            if not Util.HasFunction("C_TradeSkillUI.GetRecipeDifficulty") then return nil end

            local ok, value = pcall(C_TradeSkillUI.GetRecipeDifficulty, recipeID)
            if not ok then return nil end

            return TierFrom(value), value
        end,
    },
    {
        key = "legacyList",
        label = "GetTradeSkillInfo() by recipe name",
        read = function(_, info)
            local byName = SkillUp.legacyByName
            local name = info and info.name

            if not byName or not name then return nil end

            local entry = byName[name]
            if not entry then return nil end

            return entry.tier, entry.tier
        end,
    },
}

--- Index the classic profession list by recipe name.
--
-- The old API is indexed by position in an open profession window rather than
-- by recipe ID, so the only thing the two models share is the name. Built once
-- per harvest and thrown away afterwards, because the indices shift the moment
-- a filter changes.
function SkillUp:BuildLegacyIndex()
    self.legacyByName = nil

    if not Util.HasFunction("GetNumTradeSkills") then return end
    if not Util.HasFunction("GetTradeSkillInfo") then return end

    local ok, count = pcall(GetNumTradeSkills)
    if not ok or type(count) ~= "number" or count <= 0 then return end

    local byName = {}

    for index = 1, count do
        local gotIt, name, kind, _, _, _, skillUps = pcall(GetTradeSkillInfo, index)
        local tier = gotIt and TierFromWord(kind)

        -- Headers come back as type "header" and are not recipes.
        if tier and name then
            byName[name] = { tier = tier, skillUps = skillUps }
        end
    end

    self.legacyByName = byName
end

--- Ask every source in turn what this recipe's difficulty is.
-- @return tier, source key, the raw value the client gave
function SkillUp:Read(recipeID, info)
    local capture = self.capture

    for _, source in ipairs(SOURCES) do
        local tier, raw = source.read(recipeID, info)

        if tier then
            -- Recorded the same way Probe records quality tiers: observed, not
            -- inferred from a function existing.
            if ns.Compat then
                local trade = ns.Compat:Get().tradeskill
                trade.skillUpSource = source.key
                trade.skillUpSourceLabel = source.label
            end

            return tier, source.key, raw
        end

        -- The client answered with something no mapping covered. That is the
        -- single most useful thing this file can report, so keep it.
        if raw ~= nil and capture then
            capture.unmapped[source.key] = ("%s (%s)"):format(tostring(raw), type(raw))
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- Skill levels
--------------------------------------------------------------------------------

--- Current skill level per skill line, under BOTH ID spaces.
--
-- Forever lists every profession twice, once modern and once classic, and a
-- recipe may carry either ID. Recipes:GetProfessions deduplicates by name,
-- which is right for a profession list and wrong here: half the lookups would
-- miss and the staleness check would silently never fire.
function SkillUp:ReadSkillLevels()
    local levels = {}

    if not Util.HasFunction("C_TradeSkillUI.GetAllProfessionTradeSkillLines") then
        return ns.EraRecipes and ns.EraRecipes:SkillLevels() or levels
    end
    if not Util.HasFunction("C_TradeSkillUI.GetProfessionInfoBySkillLineID") then return levels end

    local ok, skillLines = pcall(C_TradeSkillUI.GetAllProfessionTradeSkillLines)
    if not ok or type(skillLines) ~= "table" then return levels end

    for _, skillLineID in ipairs(skillLines) do
        local gotIt, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, skillLineID)

        -- A maxSkillLevel of zero is a profession listed but not learned, or a
        -- read taken before skill levels have loaded. Neither is a level.
        if gotIt and info and (info.maxSkillLevel or 0) > 0 then
            levels[skillLineID] = info.skillLevel or 0
        end
    end

    return levels
end

local LEVEL_TTL = 20

--- This character's level in a skill line, memoised.
--
-- Profit:Analyse runs for every row of the list several times a second, so
-- this cannot be a pair of API calls per row.
function SkillUp:GetSkillLevel(skillLineID)
    if not skillLineID then return nil end

    if not self.levels or (time() - (self.levelsAt or 0)) > LEVEL_TTL then
        self.levels = self:ReadSkillLevels()
        self.levelsAt = time()
    end

    return self.levels[skillLineID]
end

function SkillUp:ForgetSkillLevels()
    self.levels = nil
    self.levelsAt = nil
end

--------------------------------------------------------------------------------
-- Capture, during a recipe harvest
--------------------------------------------------------------------------------

--- Start a run of reads, collecting what the client said as it goes.
function SkillUp:BeginCapture()
    self:ForgetSkillLevels()
    self:BuildLegacyIndex()

    self.capture = {
        attempted = 0,
        answered = 0,
        bySource = {},
        byTier = {},
        unmapped = {},
        examples = {},
        startedAt = time(),
        hadLegacyList = self.legacyByName ~= nil,
    }
end

function SkillUp:EndCapture()
    local capture = self.capture

    self.capture = nil
    self.legacyByName = nil

    if capture then
        capture.finishedAt = time()
        self.lastCapture = capture
    end

    return capture
end

--- Read one recipe's difficulty and package it for the cache.
--
-- @param existing what was stored for this recipe last time, kept when the
--   client will not answer now -- a profession window that has just opened
--   reports nothing for a moment, and dropping a good reading in favour of
--   that would make the stars flicker.
-- @return the record to store, which may be `existing`
function SkillUp:Capture(recipeID, info, skillLineID, existing)
    local capture = self.capture
    if capture then capture.attempted = capture.attempted + 1 end

    local tier, source, raw = self:Read(recipeID, info)
    if not tier then return existing end

    if capture then
        capture.answered = capture.answered + 1
        capture.bySource[source] = (capture.bySource[source] or 0) + 1
        capture.byTier[tier] = (capture.byTier[tier] or 0) + 1

        if #capture.examples < 6 then
            capture.examples[#capture.examples + 1] = {
                name = (info and info.name) or ("recipe " .. tostring(recipeID)),
                tier = tier,
                raw = tostring(raw),
            }
        end
    end

    return {
        tier = tier,
        source = source,
        skill = self:GetSkillLevel(skillLineID),
        at = time(),
    }
end

--- Read difficulties for whatever the open profession window is showing, right
--- now, without waiting for a harvest.
--
-- This is the command's evidence. It reports an outcome -- how many recipes
-- answered and with what -- rather than that a call was made.
function SkillUp:Probe(limit)
    if not Util.HasFunction("C_TradeSkillUI.GetAllRecipeIDs") then
        return nil, "this version of the game has no GetAllRecipeIDs"
    end

    -- A harvest is already collecting these, and two runs would share one set
    -- of counters and finish each other's. The harvest's own numbers are
    -- reported instead.
    if self.capture then
        return nil, "recipes are still being read, try again in a moment"
    end

    local ok, recipeIDs = pcall(C_TradeSkillUI.GetAllRecipeIDs)

    if not ok or type(recipeIDs) ~= "table" or #recipeIDs == 0 then
        return nil, "no recipes visible (open a profession window)"
    end

    self:BeginCapture()

    local count = math.min(limit or 60, #recipeIDs)

    for index = 1, count do
        local recipeID = recipeIDs[index]
        local infoOk, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)

        self:Capture(recipeID, infoOk and info or nil, nil, nil)
    end

    local capture = self:EndCapture()
    capture.visibleRecipes = #recipeIDs

    return capture
end

--------------------------------------------------------------------------------
-- Lookup
--------------------------------------------------------------------------------

--- What is known about a recipe's skill up.
--
-- @return { tier, source, skill, currentSkill, at, stale } or nil when the
--   client has never reported one for this recipe.
function SkillUp:GetForRecipe(recipeID, recipe)
    recipe = recipe or (ns.Recipes and ns.Recipes:GetAny(recipeID))

    local stored = recipe and recipe.skillUp
    if type(stored) ~= "table" or not stored.tier then return nil end

    local current = self:GetSkillLevel(recipe.skillLineID)

    -- Skill only ever rises, so a reading taken at a lower level is an upper
    -- bound: what was orange then may be yellow or green now. Said out loud in
    -- the tooltip rather than quietly trusted or quietly dropped.
    -- Only against the logged-in character's own reading: the skill level
    -- read here is theirs, and an alt's recipe says nothing about it.
    local stale = nil
    -- Compared by content, since the account-wide view hands in copies.
    local mine = ns.Recipes and ns.Recipes:Get(recipeID)
    local own = mine and type(mine.skillUp) == "table" and mine.skillUp.skill == stored.skill
        and mine.skillUp.at == stored.at
    if own and stored.skill and current and current > stored.skill then
        stale = true
    end

    return {
        tier = stored.tier,
        source = stored.source,
        skill = stored.skill,
        currentSkill = current,
        at = stored.at,
        stale = stale,
    }
end

--- Where a recipe changes colour, as one tooltip line: "Yellow at 150 ·
--- Green at 165 · Grey at 180", only the colours still ahead of the skill,
--- or "Grey now, no more skill ups" once it is grey. nil when the book has
--- no yellow and grey for it. Green starts halfway, as LearnNext.Tier has it.
function SkillUp:ColorSteps(recipeID, recipe)
    local book = ns.RecipeBook and recipeID and ns.RecipeBook:Get(recipeID)
    local yellow, grey = book and tonumber(book.yellow), book and tonumber(book.grey)
    if not yellow or not grey or grey <= yellow then return nil end
    local green = math.floor((yellow + grey) / 2)

    recipe = recipe or (ns.Recipes and ns.Recipes:GetAny(recipeID))
    local current = self:GetSkillLevel((recipe and recipe.skillLineID) or book.skillLineID)

    if current and current >= grey then
        return self:GetTierColorCode("trivial") .. L["Grey now, no more skill ups"] .. "|r"
    end

    local parts = {}
    local function Add(level, tier, text)
        if not current or current < level then
            parts[#parts + 1] = self:GetTierColorCode(tier) .. text .. "|r"
        end
    end
    Add(yellow, "medium", L.Format("Yellow at %d", yellow))
    Add(green, "easy", L.Format("Green at %d", green))
    Add(grey, "trivial", L.Format("Grey at %d", grey))
    return table.concat(parts, " \194\183 ")
end

--- Does this craft earn a star: it raises your skill AND it pays.
--
-- "Pays" is measured against the Minimum profit setting rather than against
-- zero, because that number is the player's own answer to what is worth their
-- materials. At the default of zero, any craft in profit qualifies.
function SkillUp:IsWorthIt(analysis)
    if not analysis or not analysis.priceable then return false end

    local skillUp = analysis.skillUp
    if not skillUp or not WORTH_IT[skillUp.tier] then return false end

    local profit = analysis.profit or 0
    if profit <= 0 then return false end

    return profit >= (ns.Config:Get("minProfit") or 0)
end

--- Everything starred right now, best profit first.
function SkillUp:GetRecommended()
    local starred = {}

    if not ns.Profit then return starred end

    for recipeID in pairs(ns.Recipes:GetAll()) do
        local analysis = ns.Profit:Analyse(recipeID)

        if analysis and analysis.recommended then
            starred[#starred + 1] = analysis
        end
    end

    table.sort(starred, function(a, b) return (a.profit or 0) > (b.profit or 0) end)

    return starred
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function SkillUp:OnEnable()
    -- A skill point changes every recipe's colour at once, so the memoised
    -- levels are dropped whenever the profession window says anything.
    ns.RegisterEvent(self, "TRADE_SKILL_LIST_UPDATE", self.ForgetSkillLevels)
    ns.RegisterEvent(self, "TRADE_SKILL_SHOW", self.ForgetSkillLevels)

    -- The line that says you gained a point. RegisterEvent refuses events the
    -- client does not have, so an absent one costs nothing.
    ns.RegisterEvent(self, "CHAT_MSG_SKILL", self.ForgetSkillLevels)
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function Accent(text)
    return ("|c%s%s|r"):format(ns.COLORS.accent, tostring(text))
end

local function Muted(text)
    return ("|c%s%s|r"):format(ns.COLORS.muted, tostring(text))
end

local function TierWord(tier)
    return ("%s%s|r"):format(SkillUp:GetTierColorCode(tier or "trivial"), tostring(tier))
end

local function ReportCapture(capture, heading)
    ns.PrintRaw(Muted(heading))

    if capture.attempted == 0 then
        ns.PrintRaw("  nothing was read")
        return
    end

    ns.PrintRaw(("  %d recipe(s) read, %s answered"):format(
        capture.attempted, Accent(capture.answered)))

    for source, count in pairs(capture.bySource) do
        local label = source
        for _, entry in ipairs(SOURCES) do
            if entry.key == source then label = entry.label end
        end
        ns.PrintRaw(("  from %s: %d"):format(Accent(label), count))
    end

    local tiers = {}
    for _, tier in ipairs({ "optimal", "medium", "easy", "trivial" }) do
        if capture.byTier[tier] then
            tiers[#tiers + 1] = ("%s %d"):format(TierWord(tier), capture.byTier[tier])
        end
    end

    if #tiers > 0 then
        ns.PrintRaw("  " .. table.concat(tiers, "   "))
    end

    for _, example in ipairs(capture.examples) do
        ns.PrintRaw(("  %s: %s (game value %s)"):format(
            example.name, TierWord(example.tier), Muted(example.raw)))
    end

    local sawUnmapped = false
    for source, raw in pairs(capture.unmapped) do
        sawUnmapped = true
        ns.PrintRaw(("  |cffE5604Funknown|r %s returned %s"):format(source, raw))
    end

    if sawUnmapped then
        ns.PrintRaw(Muted("  an unknown value means the game does answer, but with"))
        ns.PrintRaw(Muted("  something this addon cannot read yet. Report the value above."))
    end
end

ns.RegisterCommand("skillup",
    L["what the game says about skill ups, and what is starred right now"],
function()
    ns.Print(("|c%sSkill ups|r"):format(ns.COLORS.accent))

    local trade = ns.Compat:Get().tradeskill

    ns.PrintRaw(("  difficulty list present: %s"):format(
        Accent(tostring(type(Enum) == "table"
            and type(Enum.TradeskillRelativeDifficulty) == "table"))))
    ns.PrintRaw(("  GetRecipeDifficulty: %s   classic list: %s"):format(
        Accent(tostring(Util.HasFunction("C_TradeSkillUI.GetRecipeDifficulty"))),
        Accent(tostring(Util.HasFunction("GetTradeSkillInfo")))))
    ns.PrintRaw(("  IsTradeSkillReady: %s   window still settling: %s"):format(
        Accent(tostring(Util.HasFunction("C_TradeSkillUI.IsTradeSkillReady"))),
        Accent(tostring(ns.Recipes.WindowSettling and ns.Recipes.WindowSettling() or false))))

    -- A live read beats anything cached, so it is tried first and reported as
    -- what it is: what this client answered, just now.
    local capture, why = SkillUp:Probe(60)

    if capture then
        ReportCapture(capture, ("read just now from %d visible recipe(s):"):format(
            capture.visibleRecipes or 0))
    else
        ns.PrintRaw("  " .. Muted(why or "nothing to read"))
        if SkillUp.lastCapture then
            ReportCapture(SkillUp.lastCapture, "from the last time recipes were read:")
        end
    end

    -- What is in the database is what the Profit tab actually draws from,
    -- which is not the same question as what the client will answer now.
    local cached, byTier = 0, {}

    for _, recipe in pairs(ns.Recipes:GetAll()) do
        local tier = type(recipe.skillUp) == "table" and recipe.skillUp.tier
        if tier then
            cached = cached + 1
            byTier[tier] = (byTier[tier] or 0) + 1
        end
    end

    local stored = {}
    for _, tier in ipairs({ "optimal", "medium", "easy", "trivial" }) do
        if byTier[tier] then
            stored[#stored + 1] = ("%s %d"):format(TierWord(tier), byTier[tier])
        end
    end

    ns.PrintRaw(("  saved on %s of %s recipe(s)%s"):format(
        Accent(cached), Accent(ns.Util.Count(ns.Recipes:GetAll())),
        #stored > 0 and ("   " .. table.concat(stored, "   ")) or ""))

    if cached == 0 then
        ns.PrintRaw(Muted("  open a profession window once to fill this in."))
    end

    -- The outcome that matters: what is starred, by name.
    local starred = SkillUp:GetRecommended()

    ns.PrintRaw(("  starred right now: %s"):format(Accent(#starred)))

    for index = 1, math.min(8, #starred) do
        local analysis = starred[index]
        ns.PrintRaw(("    %s: %s, %s each"):format(
            analysis.name or "?",
            TierWord(analysis.skillUp and analysis.skillUp.tier),
            ns.Util.FormatMoney(analysis.profit, { noColor = true, short = true })))
    end

    if #starred == 0 then
        ns.PrintRaw(Muted("  nothing both raises your skill and makes a profit right now."))
    end
end)

ns.RegisterCommand("star", L["how the skill-up mark is drawn: /bts star [star|raid|pip]"],
function(args)
    local choice = (args or ""):lower():gsub("%s", "")
    local styles = ns.Theme and ns.Theme.marks

    if choice == "" or not styles or not styles[choice] then
        ns.Print(L.Format("the skill-up mark is drawn as %s",
            Accent(ns.Config:Get("skillUpMarker") or "star")))
        ns.PrintRaw(Muted(L["  /bts star star: this addon's own gold star"]))
        ns.PrintRaw(Muted(L["  /bts star raid: the game's raid-target star"]))
        ns.PrintRaw(Muted(L["  /bts star pip:  a plain gold square, if neither draws"]))
        return
    end

    ns.Config:Set("skillUpMarker", choice)
    ns.Print(L.Format("the skill-up mark is now %s. Reopen the window to see it.",
        Accent(choice)))

    if ns.UI and ns.UI.RefreshActiveTab then ns.UI:RefreshActiveTab() end
end)
