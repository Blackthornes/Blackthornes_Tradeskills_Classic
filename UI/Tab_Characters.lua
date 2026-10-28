-- Blackthornes Tradeskills -- UI/Tab_Characters.lua
-- Every character on one table, split by side: Horde, then Alliance, each
-- under its own heading with how many there are, their gold and their time
-- played (asked 2026-10-16, from a mockup).
--
-- A row says the character's level and how far into it, rested XP, gold,
-- professions, mail waiting, the zone, time played and when last seen. A
-- click opens a line under it with the best crafts, cooldowns and how old
-- its bags and bank are; Forget character sits there too, for an alt.
--
-- Every figure but the logged-in character's is from the last time that
-- character was played (Logic/CharacterNotes.lua keeps them), so the table
-- says when that was. Nothing new is saved here: the realm, which side
-- shows, the search, the sort and the open line last the session. The tab
-- opens on the realm you're playing (a player asked, 2026-10-18).

local _, ns = ...
local L = ns.L or setmetatable({ Format = string.format }, { __index = function(_, key) return key end })

local Theme = ns.Theme
local Widgets = ns.Widgets
local Util = ns.Util

local UI = ns.UI

local ROW_HEIGHT = 26
-- A character's row: the name with race and class under it, and the bars.
local CHARACTER_NEED = 34
-- The open line under a character.
local CARD_NEED = 74
local CARD_CRAFTS = 3
local CARD_COOLDOWNS = 3
-- How long the open line keeps its best crafts before working them out again.
local CRAFTS_KEEP = 30

-- `realm` is REALM_HERE, REALM_ALL or a realm's name.
local REALM_HERE, REALM_ALL = "\1here", "\1all"
local state = { view = "characters", realm = REALM_HERE, show = "both", search = "", open = nil, folded = {} }
local widgets = {}

-- The tab has two views: the characters themselves, and every character's
-- bank in one list (UI/BankView.lua).
local VIEWS = {
    { key = "characters", text = L["CHARACTERS"] },
    { key = "bank",       text = L["BANK"] },
}

-- Right to left, as every list lays them out; the name has the rest.
local COLUMNS = {
    { key = "seen",        label = L["LAST SEEN"],   width = 76, justify = "RIGHT" },
    { key = "played",      label = L["PLAYED"],      width = 64, justify = "RIGHT" },
    { key = "zone",        label = L["ZONE"],        width = 120, justify = "LEFT" },
    { key = "mail",        label = L["MAIL"],        width = 40, justify = "CENTER" },
    { key = "professions", label = L["PROFESSIONS"], width = 150, justify = "LEFT" },
    { key = "gold",        label = L["GOLD"],        width = 96, money = true, justify = "RIGHT" },
    { key = "rested",      label = L["RESTED"],      width = 56, justify = "CENTER" },
    { key = "level",       label = L["LEVEL"],       width = 52, justify = "CENTER" },
}

ns.Columns:Register("characters", L["Characters"], COLUMNS)

-- The two sides, in the order shown, and anything else (a character saved
-- before its side was kept) after them.
local SIDES = {
    Horde    = { title = L["HORDE"],    color = "horde",
                 crest = [[Interface\TargetingFrame\UI-PVP-Horde]] },
    Alliance = { title = L["ALLIANCE"], color = "alliance",
                 crest = [[Interface\TargetingFrame\UI-PVP-Alliance]] },
    Other    = { title = L["OTHER"],    color = "muted" },
}

local SHOW = {
    { key = "both",     text = L["Both"] },
    { key = "Horde",    text = L["Horde"],    color = "horde" },
    { key = "Alliance", text = L["Alliance"], color = "alliance" },
}

-- The game's class colours, for a client that has no table of its own.
local CLASS_COLORS = {
    WARRIOR = { 0.78, 0.61, 0.43 }, PALADIN = { 0.96, 0.55, 0.73 }, HUNTER = { 0.67, 0.83, 0.45 },
    ROGUE = { 1.00, 0.96, 0.41 }, PRIEST = { 1.00, 1.00, 1.00 }, SHAMAN = { 0.00, 0.44, 0.87 },
    MAGE = { 0.25, 0.78, 0.92 }, WARLOCK = { 0.53, 0.53, 0.93 }, DRUID = { 1.00, 0.49, 0.04 },
}

--------------------------------------------------------------------------------
-- Words
--------------------------------------------------------------------------------

local function Money(copper)
    if not copper then return "--" end
    return Util.FormatMoney(copper, { short = true })
end

--- Time played: "12d 4h", "5h 20m", "40m".
local function PlayedText(seconds)
    if type(seconds) ~= "number" then return "--" end
    seconds = math.max(0, math.floor(seconds))
    local days, hours = math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600)
    local minutes = math.floor(seconds % 3600 / 60)
    if days > 0 then return L.Format("%dd %dh", days, hours) end
    if hours > 0 then return L.Format("%dh %dm", hours, minutes) end
    return L.Format("%dm", minutes)
end

local function SeenText(entry)
    if entry.isCurrent then return L["Here now"] end
    if not entry.seenAt then return "--" end
    return Util.FormatAgeAgo(time() - entry.seenAt)
end

--- The class colour, or nil for the usual text colour.
local function ClassColor(classFile)
    if type(classFile) ~= "string" then return nil end
    local ok, color = pcall(function()
        local colors = rawget(_G, "RAID_CLASS_COLORS")
        local c = type(colors) == "table" and colors[classFile]
        if type(c) == "table" and type(c.r) == "number" then return { c.r, c.g, c.b } end
    end)
    return ok and color or CLASS_COLORS[classFile]
end

--- Learned professions, highest skill first.
local function Learned(entry)
    local learned = {}
    for _, profession in ipairs(entry.professions or {}) do
        if type(profession) == "table" and profession.learned and profession.name then
            learned[#learned + 1] = profession
        end
    end
    table.sort(learned, function(a, b)
        if (a.skillLevel or 0) ~= (b.skillLevel or 0) then return (a.skillLevel or 0) > (b.skillLevel or 0) end
        return a.name < b.name
    end)
    return learned
end

local function ProfessionLine(profession)
    return ("%s %d"):format(profession.name, profession.skillLevel or 0)
end

-- Rested XP tops out at a level and a half.
local function RestMost()
    return ns.CharacterNotes and ns.CharacterNotes.REST_MOST or 150
end

--- A realm's name to compare by: case and spaces left out, as the game
--- writes some names with spaces and some without.
local function FoldRealm(name)
    if type(name) ~= "string" or name == "" then return nil end
    return (name:gsub("%s", ""):lower())
end

--- The realm of the character playing: its own record's, else the game's.
local function HereRealm(characters)
    for _, entry in ipairs(characters) do
        if entry.isCurrent and type(entry.realm) == "string" and entry.realm ~= "" then return entry.realm end
    end
    local ok, realm = pcall(function()
        local name = GetRealmName()
        if type(name) == "string" and name ~= "" then return name .. "" end
    end)
    return ok and realm or nil
end

--- Does this character belong under the realm picked? A character saved
--- before its realm was kept stays under This Realm, so none goes missing.
local function RealmMatches(entry, here)
    if state.realm == REALM_ALL then return true end
    local realm = FoldRealm(entry.realm)
    if state.realm == REALM_HERE then
        here = FoldRealm(here)
        return not here or not realm or realm == here
    end
    return realm == FoldRealm(state.realm)
end

--- This Realm, All Realms, then every realm a character is on, by name.
local function RealmOptions(characters)
    local names, seen = {}, {}
    for _, entry in ipairs(characters) do
        local folded = FoldRealm(entry.realm)
        if folded and not seen[folded] then
            seen[folded] = true
            names[#names + 1] = entry.realm
        end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    local options = {
        { value = REALM_HERE, text = L["This Realm"] },
        { value = REALM_ALL,  text = L["All Realms"] },
    }
    for _, name in ipairs(names) do options[#options + 1] = { value = name, text = name } end
    return options, table.concat(names, "\n")
end

local function SideOf(entry)
    if entry.faction == "Horde" or entry.faction == "Alliance" then return entry.faction end
    return "Other"
end

--------------------------------------------------------------------------------
-- The open line: best crafts, cooldowns, bags and bank
--------------------------------------------------------------------------------

local craftsKept = { key = nil, at = 0, list = nil }

--- This character's crafts that pay most, against its own bags. Crafts of
--- a profession it dropped are left out, as the Profit tab leaves them out.
local function BestCrafts(key)
    if craftsKept.key == key and craftsKept.list and time() - craftsKept.at < CRAFTS_KEEP then
        return craftsKept.list
    end

    local record = ns.db and ns.db.characters and ns.db.characters[key]
    local ranked = {}
    for recipeID, recipe in pairs((record and record.recipes) or {}) do
        if not ns.Recipes:IsDropped(recipe, key) then
            local ok, analysis = pcall(ns.Profit.Analyse, ns.Profit, recipeID, key)
            if ok and analysis and analysis.priceable then
                ranked[#ranked + 1] = analysis
            end
        end
    end

    -- Ties settled by name, then recipe, so equal crafts keep their places.
    table.sort(ranked, function(a, b)
        if a.profit ~= b.profit then return a.profit > b.profit end
        if (a.name or "") ~= (b.name or "") then return (a.name or "") < (b.name or "") end
        return (a.recipeID or 0) < (b.recipeID or 0)
    end)

    craftsKept.key, craftsKept.at, craftsKept.list = key, time(), ranked
    return ranked
end

local function Disarm(button)
    button.armed = false
    button:SetText(L["Forget character"])
    button:SetConfirming(false)
end

local function BuildCard(row)
    local card = CreateFrame("Frame", nil, row)
    card:SetPoint("TOPLEFT", 14, -6)
    card:SetPoint("BOTTOMRIGHT", -12, 6)
    card:Hide()

    local function Column(left, width, title)
        local heading = Theme.CreateLabel(card, "tiny", "dim")
        heading:SetPoint("TOPLEFT", left, 0)
        heading:SetText(title)

        local lines = {}
        local count = title == L["BEST CRAFTS"] and CARD_CRAFTS or CARD_COOLDOWNS
        for index = 1, count do
            local line = {}
            line.name = Theme.CreateLabel(card, "small", "text")
            line.name:SetPoint("TOPLEFT", left, -14 - (index - 1) * 15)
            line.name:SetWidth(width - 96)
            line.value = Theme.CreateLabel(card, "small", "muted", "RIGHT")
            line.value:SetPoint("TOPLEFT", left + width - 92, -14 - (index - 1) * 15)
            line.value:SetWidth(92)
            lines[index] = line
        end
        return lines
    end

    card.crafts = Column(0, 340, L["BEST CRAFTS"])
    card.cooldowns = Column(370, 250, L["COOLDOWNS"])

    local heading = Theme.CreateLabel(card, "tiny", "dim")
    heading:SetPoint("TOPLEFT", 650, 0)
    heading:SetText(L["BAGS AND BANK"])

    card.bags = Theme.CreateLabel(card, "small", "muted")
    card.bags:SetPoint("TOPLEFT", 650, -14)
    card.bags:SetPoint("RIGHT", card, "RIGHT", 0, 0)
    card.bags:SetWordWrap(true)

    -- Removing a character is destructive, so it arms first, for that
    -- character only.
    card.forget = Widgets.CreateButton(card, L["Forget character"], function()
        local button = card.forget
        local key = card.key
        if not key then return end

        if button.armed and button.armed == key then
            ns.Recipes:ForgetCharacter(key)
            Disarm(button)
            state.open = nil
            UI:RefreshActiveTab()
            return
        end

        button.armed = key
        button:SetText(L["Click Again"])
        -- Red while armed, like the craft pane's Clear queue.
        button:SetConfirming(true)
        C_Timer.After(4, function()
            if button.armed == key then Disarm(button) end
        end)
    end, { width = 140, height = 20,
           tooltip = L["Delete this character's saved recipes and inventory"] })
    card.forget:SetPoint("BOTTOMRIGHT", 0, 0)

    row.card = card
end

local function FillCard(card, entry)
    card.key = entry.key

    local crafts = BestCrafts(entry.key)
    for index, line in ipairs(card.crafts) do
        local analysis = crafts[index]
        if analysis then
            line.name:SetText(analysis.name or "?")
            -- In the rarity of what it makes, faded while there's nothing to
            -- make it with.
            local r, g, b = Util.GetItemQualityColor(analysis.outputItemID)
            if r then
                line.name:SetTextColor(r, g, b, (analysis.craftableNow or 0) > 0 and 1 or 0.55)
            else
                line.name:SetTextColor(Theme.Unpack((analysis.craftableNow or 0) > 0 and "text" or "muted"))
            end
            Theme.SetMoneyText(line.value, analysis.profit, { short = true })
            line.value:SetTextColor(Theme.ProfitColor(analysis.profit))
        elseif index == 1 then
            -- A character with no recipes read needs a profession window
            -- opened, not a scan.
            line.name:SetText((entry.recipeCount or 0) == 0
                and L["No recipes read. Open a profession."] or L["Nothing with a price yet"])
            line.name:SetTextColor(Theme.Unpack("dim"))
            line.value:SetText("")
        else
            line.name:SetText("")
            line.value:SetText("")
        end
    end

    local cooldowns = ns.Cooldowns and ns.Cooldowns:Groups(entry.key) or {}
    for index, line in ipairs(card.cooldowns) do
        local group = cooldowns[index]
        if group then
            line.name:SetText(group.group)
            Theme.SetItemNameColor(line.name, group.itemID, "text")
            if group.ready then
                line.value:SetText(L["Ready"])
                line.value:SetTextColor(Theme.Unpack("profit"))
            else
                line.value:SetText(ns.Cooldowns.LeftText(group.readyAt - time()))
                line.value:SetTextColor(Theme.Unpack("muted"))
            end
        elseif index == 1 then
            line.name:SetText(L["None"])
            line.name:SetTextColor(Theme.Unpack("dim"))
            line.value:SetText("")
        else
            line.name:SetText("")
            line.value:SetText("")
        end
    end

    if entry.isCurrent then
        card.bags:SetText(L["Live for the character you're playing."])
    else
        local bags = entry.inventoryAt and Util.FormatAgeAgo(time() - entry.inventoryAt) or L["never"]
        local bank = entry.bankAt and Util.FormatAgeAgo(time() - entry.bankAt) or L["never"]
        card.bags:SetText(L.Format("Bags read %s. Bank read %s.", bags, bank))
    end

    -- Only an alt can be forgotten; never the character you're on.
    card.forget:SetShown(not entry.isCurrent)
    if card.forget.armed and card.forget.armed ~= entry.key then Disarm(card.forget) end
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

--- The shown columns from the right edge; the name has the rest.
local function PlaceRow(row)
    row.offsets = {}
    row.nameRight = ns.Columns:Place("characters", COLUMNS, row.cells, {
        gap = 8,
        place = function(column, offset, shown)
            row.offsets[column.key] = shown and offset or nil
            local bar = column.key == "level" and row.levelBar or column.key == "rested" and row.restBar
            if bar then
                bar.width = column.width - 10
                bar.track:SetWidth(bar.width)
                bar:SetPoint("TOP", row, "RIGHT", offset - column.width / 2, -6)
            end
        end,
    })
    row.columnsVersion = ns.Columns.version
end

local function CreateRow(row)
    -- A side's heading: its colour down the left edge, washing across.
    row.stripe = row:CreateTexture(nil, "ARTWORK")
    row.stripe:SetPoint("TOPLEFT")
    row.stripe:SetPoint("BOTTOMLEFT")
    row.stripe:SetWidth(3)

    row.wash = row:CreateTexture(nil, "BACKGROUND", nil, 3)
    row.wash:SetAllPoints(row)

    row.crest = row:CreateTexture(nil, "ARTWORK")
    row.crest:SetSize(20, 20)
    row.crest:SetPoint("LEFT", 10, 0)

    row.fold = row:CreateTexture(nil, "ARTWORK")
    row.fold:SetSize(12, 12)

    row.name = Theme.CreateLabel(row, "normal", "text")
    row.sub = Theme.CreateLabel(row, "tiny", "muted")
    row.count = Theme.CreateLabel(row, "small", "muted")

    row.cells = {}
    for _, column in ipairs(COLUMNS) do
        local cell = Theme.CreateLabel(row, "small", "text", column.justify or "RIGHT")
        cell:SetWordWrap(false)
        row.cells[column.key] = cell
    end
    row.cells.professions:SetWordWrap(true)
    row.cells.zone:SetWordWrap(true)

    row.levelBar = Theme.CreateBar(row, 40, 3)
    row.restBar = Theme.CreateBar(row, 40, 3)

    BuildCard(row)
    PlaceRow(row)
end

--- A cell back on its column, raised a little on a row with bars.
local function Seat(row, key, raise)
    local offset = row.offsets[key]
    if not offset then return end
    local cell = row.cells[key]
    cell:ClearAllPoints()
    cell:SetPoint("RIGHT", row, "RIGHT", offset, raise or 0)
end

local function ShowParts(row, kind)
    local heading, character, card = kind == "heading", kind == "char", kind == "card"
    row.stripe:SetShown(heading)
    row.wash:SetShown(heading)
    row.crest:SetShown(false)
    row.fold:SetShown(heading)
    row.count:SetShown(heading)
    row.name:SetShown(not card)
    row.sub:SetShown(character)
    row.card:SetShown(card)
    for _, column in ipairs(COLUMNS) do
        local cell = row.cells[column.key]
        cell:SetShown(not card and row.offsets[column.key] ~= nil)
        if heading then cell:SetText("") end
    end
    if not character then
        row.levelBar:Set(nil)
        row.restBar:Set(nil)
    end
end

local function UpdateHeading(row, entry)
    local side = SIDES[entry.side]
    local r, g, b = Theme.Unpack(side.color)
    row.stripe:SetColorTexture(r, g, b, 1)
    if Theme.SetGradientAlpha then Theme.SetGradientAlpha(row.wash, "HORIZONTAL", side.color, 0.22, 0) end

    local left = 10
    if side.crest then
        local ok = pcall(row.crest.SetTexture, row.crest, side.crest)
        if ok then
            pcall(row.crest.SetTexCoord, row.crest, 0.06, 0.62, 0.04, 0.6)
            row.crest:Show()
            left = 34
        end
    end

    pcall(row.fold.SetTexture, row.fold, state.folded[entry.side]
        and [[Interface\Buttons\UI-PlusButton-Up]] or [[Interface\Buttons\UI-MinusButton-Up]])

    pcall(row.name.SetFont, row.name, Theme.FONT, Theme.sizes.normal, "")
    pcall(row.name.SetWordWrap, row.name, false)
    pcall(row.name.SetHeight, row.name, 0)
    row.name.rowNeed, row.name.rowNeedText = nil, nil
    row.name:ClearAllPoints()
    row.name:SetPoint("LEFT", left, 0)
    row.name:SetWidth(0)
    row.name:SetText(side.title)
    row.name:SetTextColor(r, g, b)

    row.count:ClearAllPoints()
    row.count:SetPoint("LEFT", row.name, "RIGHT", 10, 0)
    row.count:SetText(entry.count == 1 and L["1 character"] or L.Format("%d characters", entry.count))

    row.fold:ClearAllPoints()
    row.fold:SetPoint("LEFT", row.count, "RIGHT", 8, 0)

    Seat(row, "gold")
    Seat(row, "played")
    Theme.SetMoneyText(row.cells.gold, entry.gold, { short = true })
    row.cells.played:SetText(entry.played and PlayedText(entry.played) or "")
    row.cells.played:SetTextColor(Theme.Unpack("muted"))
end

local function UpdateCharacter(row, entry)
    -- The name, whole, with race and class under it.
    row.name:ClearAllPoints()
    row.name:SetPoint("TOPLEFT", 14, -5)
    row.name:SetPoint("RIGHT", row, "RIGHT", row.nameRight - 8, 0)
    Theme.SetRowName(row.name, entry.name, "normal")
    local color = ClassColor(entry.classFile)
    if color then row.name:SetTextColor(color[1], color[2], color[3]) else row.name:SetTextColor(Theme.Unpack("text")) end
    local nameNeed = rawget(row.name, "rowNeed") or 14
    row.name.rowNeed, row.name.rowNeedText = math.max(CHARACTER_NEED, nameNeed + 18), entry.name

    local about = {}
    if entry.race then about[#about + 1] = entry.race end
    if entry.class then about[#about + 1] = entry.class end
    local sub = table.concat(about, " ")
    if entry.linkedFrom then
        sub = sub ~= "" and L.Format("%s, other account", sub) or L["Other account"]
    end
    row.sub:ClearAllPoints()
    row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
    row.sub:SetPoint("RIGHT", row, "RIGHT", row.nameRight - 8, 0)
    row.sub:SetText(sub)

    local cells = row.cells

    Seat(row, "level", entry.levelShare and 4 or 0)
    cells.level:SetText(entry.level and tostring(entry.level) or "--")
    cells.level:SetTextColor(Theme.Unpack(entry.level and "text" or "dim"))
    row.levelBar:Set(row.offsets.level and entry.levelShare or nil, "xp")

    Seat(row, "rested", entry.rested and 4 or 0)
    if entry.rested then
        cells.rested:SetText(entry.rested >= RestMost() and L["Full"] or ("%d%%"):format(entry.rested))
        cells.rested:SetTextColor(Theme.Unpack("rested"))
        row.restBar:Set(row.offsets.rested and entry.rested / RestMost() or nil, "rested")
    else
        cells.rested:SetText("--")
        cells.rested:SetTextColor(Theme.Unpack("dim"))
        row.restBar:Set(nil)
    end

    Seat(row, "gold")
    if entry.gold then
        Theme.SetMoneyText(cells.gold, entry.gold, { short = true })
    else
        cells.gold:SetText("--")
    end

    -- Two professions, each on its line; any more are counted on the second
    -- and listed in the row's tooltip.
    Seat(row, "professions")
    local learned = Learned(entry)
    local lines = {}
    for index = 1, math.min(2, #learned) do lines[index] = ProfessionLine(learned[index]) end
    if #learned > 2 then lines[2] = L.Format("%s  +%d", lines[2], #learned - 2) end
    pcall(cells.professions.SetFont, cells.professions, Theme.FONT, Theme.sizes.tiny, "")
    cells.professions:SetText(#lines > 0 and table.concat(lines, "\n") or L["No professions"])
    cells.professions:SetTextColor(Theme.Unpack(#lines > 0 and "muted" or "dim"))

    Seat(row, "mail")
    if entry.mailCount and entry.mailCount > 0 then
        cells.mail:SetText(Util.Comma(entry.mailCount))
        cells.mail:SetTextColor(Theme.Unpack("accent"))
    else
        cells.mail:SetText("--")
        cells.mail:SetTextColor(Theme.Unpack("dim"))
    end

    Seat(row, "zone")
    pcall(cells.zone.SetFont, cells.zone, Theme.FONT, Theme.sizes.tiny, "")
    cells.zone:SetText(entry.zone or "--")
    cells.zone:SetTextColor(Theme.Unpack(entry.zone and "muted" or "dim"))

    Seat(row, "played")
    cells.played:SetText(PlayedText(entry.played))
    cells.played:SetTextColor(Theme.Unpack(entry.played and "text" or "dim"))

    Seat(row, "seen")
    cells.seen:SetText(SeenText(entry))
    cells.seen:SetTextColor(Theme.Unpack(entry.isCurrent and "profit" or entry.seenAt and "muted" or "dim"))
end

local function UpdateRow(row, entry)
    if row.columnsVersion ~= ns.Columns.version then PlaceRow(row) end
    ShowParts(row, entry.kind)

    if entry.kind == "heading" then
        UpdateHeading(row, entry)
    elseif entry.kind == "card" then
        -- The open line's height rides on the hidden name.
        row.name:SetText("card")
        row.name.rowNeed, row.name.rowNeedText = CARD_NEED, "card"
        FillCard(row.card, entry.of)
    else
        UpdateCharacter(row, entry.of)
    end
end

--- Everything the row can only say in part: every profession, and how
--- sure the rested number is.
local function ShowRowTooltip(row, entry)
    if entry.kind ~= "char" then return end
    local character = entry.of

    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText(character.name or "", 1, 1, 1)

    local about = {}
    if character.level then about[#about + 1] = L.Format("Level %d", character.level) end
    if character.race then about[#about + 1] = character.race end
    if character.class then about[#about + 1] = character.class end
    if #about > 0 then GameTooltip:AddLine(table.concat(about, " "), 0.7, 0.7, 0.7) end
    if character.realm then GameTooltip:AddLine(character.realm, 0.7, 0.7, 0.7) end

    local learned = Learned(character)
    if #learned > 0 then
        GameTooltip:AddLine(" ")
        for _, profession in ipairs(learned) do
            GameTooltip:AddLine(ProfessionLine(profession), 0.9, 0.9, 0.9)
        end
    end

    if character.rested and character.restedGuess then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L["Rested has grown since you last played them."], 0.44, 0.66, 1)
    end
    if character.mailCount and character.mailCount > 0 then
        GameTooltip:AddLine(L.Format("%s items waiting in the mail", Util.Comma(character.mailCount)), 0.78, 0.64, 0.3)
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(state.open == character.key and L["Click to close"] or L["Click for best crafts and cooldowns"],
        0.55, 0.57, 0.61)
    GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

local function Matches(entry, search)
    if search == "" then return true end
    local function Has(text) return type(text) == "string" and text:lower():find(search, 1, true) ~= nil end
    if Has(entry.name) or Has(entry.zone) or Has(entry.class) or Has(entry.race) then return true end
    for _, profession in ipairs(entry.professions or {}) do
        if type(profession) == "table" and profession.learned and Has(profession.name) then return true end
    end
    return false
end

--- The rows to draw: each side's heading, then its characters in the
--- clicked heading's order, with the open line under the one clicked.
local function BuildRows(characters)
    local groups, order = {}, {}
    local current
    for _, entry in ipairs(characters) do
        if entry.isCurrent then current = SideOf(entry) end
    end
    -- The side you're playing comes first.
    for _, side in ipairs(current == "Alliance" and { "Alliance", "Horde", "Other" } or { "Horde", "Alliance", "Other" }) do
        groups[side] = { members = {} }
        order[#order + 1] = side
    end

    local search = (state.search or ""):lower()
    local here = HereRealm(characters)
    for _, entry in ipairs(characters) do
        local side = SideOf(entry)
        if RealmMatches(entry, here) and (state.show == "both" or state.show == side)
                and Matches(entry, search) then
            local members = groups[side].members
            members[#members + 1] = entry
        end
    end

    local rows, shown = {}, 0
    local totals = { gold = 0, played = 0, count = 0 }
    for _, side in ipairs(order) do
        local members = groups[side].members
        if #members > 0 then
            if widgets.sorter then members = widgets.sorter:Sort(members) end

            local gold, played = 0, 0
            for _, entry in ipairs(members) do
                gold = gold + (entry.gold or 0)
                played = played + (entry.played or 0)
            end
            totals.gold, totals.played = totals.gold + gold, totals.played + played
            totals.count = totals.count + #members

            rows[#rows + 1] = { kind = "heading", side = side, count = #members, gold = gold,
                played = played > 0 and played or nil }
            if not state.folded[side] then
                for _, entry in ipairs(members) do
                    rows[#rows + 1] = { kind = "char", of = entry, key = entry.key }
                    shown = shown + 1
                    if state.open == entry.key then
                        rows[#rows + 1] = { kind = "card", of = entry, key = entry.key }
                    end
                end
            end
        end
    end
    return rows, totals
end

local function RefreshCharacters()
    if not widgets.list then return end

    local characters = ns.Recipes:GetCharacters()
    local open
    for _, entry in ipairs(characters) do
        if entry.key == state.open then open = entry end
    end
    if not open then state.open = nil end

    -- The realm list is laid out again only when a realm comes or goes. A
    -- realm picked that no character is on now goes back to This Realm.
    if widgets.realm then
        local options, key = RealmOptions(characters)
        if key ~= widgets.realmKey then
            widgets.realmKey = key
            widgets.realm:SetOptions(options)
            state.realm = widgets.realm:GetValue() or REALM_HERE
        end
    end

    local rows, totals = BuildRows(characters)
    widgets.list:SetData(rows)

    widgets.emptyLabel:SetShown(#rows == 0)
    if #characters == 0 then
        widgets.emptyLabel:SetText(L["No characters recorded yet."])
    elseif #rows == 0 then
        widgets.emptyLabel:SetText(L["No character matches."])
    end

    local count = totals.count == 1 and L["1 character"] or L.Format("%d characters", totals.count)
    local parts = { count, L.Format("All: %s", Money(totals.gold)) }
    if totals.played > 0 then parts[#parts + 1] = PlayedText(totals.played) end
    widgets.summary:SetText(table.concat(parts, "  ·  "))
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function Refresh()
    if state.view == "bank" then
        if ns.BankView then ns.BankView.Refresh() end
    else
        RefreshCharacters()
    end
end

--- Show one of the two views and paint the switch to match.
local function ShowView(key)
    if not widgets.views then
        state.view = key
        return
    end

    state.view = widgets.views[key] and key or "characters"

    for viewKey, view in pairs(widgets.views) do
        view:SetShown(viewKey == state.view)
    end

    for _, button in ipairs(widgets.switch) do
        local active = button.key == state.view
        button.label:SetTextColor(Theme.Unpack(active and "accent" or "muted"))
        button.underline:SetShown(active)
    end

    Refresh()
end

ns.CharactersTab = { ShowView = ShowView }

--- CHARACTERS | BANK, drawn as the tab's heading: the view showing is lit
--- gold and underlined, the other waits in grey.
local function BuildSwitch(container)
    local buttons = {}
    local previous

    for _, definition in ipairs(VIEWS) do
        local button = CreateFrame("Button", nil, container)
        button:SetHeight(18)
        button:SetFrameLevel(container:GetFrameLevel() + 5)

        button.label = Theme.CreateLabel(button, "tiny", "muted")
        button.label:SetPoint("LEFT", 0, 0)
        button.label:SetText(definition.text)
        button:SetWidth(button.label:GetStringWidth() + 4)

        button.underline = button:CreateTexture(nil, "OVERLAY")
        button.underline:SetPoint("BOTTOMLEFT", 0, 1)
        button.underline:SetPoint("BOTTOMRIGHT", -4, 1)
        button.underline:SetHeight(1)
        button.underline:SetColorTexture(Theme.Unpack("accent"))
        button.underline:Hide()

        button.key = definition.key

        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 14, 0)
        else
            button:SetPoint("TOPLEFT", 8, -5)
        end

        button:SetScript("OnClick", function(self) ShowView(self.key) end)
        button:SetScript("OnEnter", function(self)
            if self.key ~= state.view then
                self.label:SetTextColor(Theme.Unpack("text"))
            end
        end)
        button:SetScript("OnLeave", function(self)
            if self.key ~= state.view then
                self.label:SetTextColor(Theme.Unpack("muted"))
            end
        end)

        buttons[#buttons + 1] = button
        previous = button
    end

    local rule = container:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(Theme.Unpack("border"))
    rule:SetHeight(1)
    rule:SetPoint("LEFT", previous, "RIGHT", 6, 0)
    rule:SetPoint("RIGHT", container, "RIGHT", -8, 0)

    return buttons
end

--- Realm: This Realm, All Realms, then each realm by name. First on the
--- bar, as every tab's menus are.
local function BuildRealm(view)
    local lead = Theme.CreateLabel(view, "small", "muted")
    lead:SetPoint("TOPLEFT", 8, -36)
    lead:SetText(L["Realm:"])

    local realm = Widgets.CreateDropdown(view, RealmOptions({}), function(value)
        state.realm = value or REALM_HERE
        RefreshCharacters()
    end, { width = 150 })
    realm:SetPoint("LEFT", lead, "RIGHT", 8, 0)
    realm:SetValue(state.realm)
    widgets.realm = realm
    return realm
end

--- Show: Both, Horde, Alliance. The one picked is lit gold.
local function BuildChips(view, after)
    local lead = Theme.CreateLabel(view, "small", "muted")
    lead:SetPoint("LEFT", after, "RIGHT", 14, 0)
    lead:SetText(L["Show:"])

    local chips, previous = {}, lead
    local function Paint()
        for _, chip in ipairs(chips) do
            local active = chip.key == state.show
            chip.label:SetTextColor(Theme.Unpack(active and "accent" or "muted"))
            Theme.SetBorderColor(chip, active and "accent" or "border")
            chip.background:SetColorTexture(Theme.Unpack(active and "glassActive" or "glass"))
        end
    end

    for _, definition in ipairs(SHOW) do
        local chip = CreateFrame("Button", nil, view)
        chip:SetHeight(20)
        chip.background = Theme.Fill(chip, "glass")
        Theme.Border(chip, "border")
        chip.key = definition.key

        local left = 10
        if definition.color then
            local dot = chip:CreateTexture(nil, "ARTWORK")
            dot:SetSize(6, 6)
            dot:SetPoint("LEFT", 8, 0)
            dot:SetColorTexture(Theme.Unpack(definition.color))
            left = 18
        end

        chip.label = Theme.CreateLabel(chip, "small", "muted")
        chip.label:SetPoint("LEFT", left, 0)
        chip.label:SetText(definition.text)
        local width = Theme.TextWidth and Theme.TextWidth(chip.label)
        chip:SetWidth(math.ceil(type(width) == "number" and width or 40) + left + 10)
        chip:SetPoint("LEFT", previous, "RIGHT", previous == lead and 8 or 6, 0)

        chip:SetScript("OnClick", function(self)
            state.show = self.key
            Paint()
            RefreshCharacters()
        end)
        chip:SetScript("OnEnter", function(self)
            if self.key ~= state.show then self.label:SetTextColor(Theme.Unpack("text")) end
        end)
        chip:SetScript("OnLeave", Paint)

        chips[#chips + 1] = chip
        previous = chip
    end

    Paint()
    widgets.chips = chips
    return previous
end

local function BuildCharacters(view)
    -- Before any row or heading is laid out: they read these widths.
    if Widgets.FitColumns then Widgets.FitColumns(COLUMNS) end

    local lastChip = BuildChips(view, BuildRealm(view))

    local search = Widgets.CreateSearchBox(view, L["Find a character or profession"], function(text)
        state.search = text or ""
        RefreshCharacters()
    end)
    search:SetPoint("LEFT", lastChip, "RIGHT", 14, 0)
    search:SetWidth((Widgets.SEARCH_WIDTH or 170) + 40)
    widgets.search = search

    -- Column headings over the list, lined up with the row cells.
    local headings = CreateFrame("Frame", nil, view)
    headings:SetHeight(14)
    headings:SetPoint("TOPLEFT", 8, -62)
    headings:SetPoint("TOPRIGHT", view, "TOPRIGHT", -8, -62)

    local nameHeading = Theme.CreateLabel(headings, "tiny", "dim")
    nameHeading:SetPoint("LEFT", 14, 0)
    nameHeading:SetText(L["CHARACTER"])

    headings.cells = {}
    for _, column in ipairs(COLUMNS) do
        local cell = Theme.CreateLabel(headings, "tiny", "dim", column.justify or "RIGHT")
        cell:SetText(column.label)
        headings.cells[column.key] = cell
    end
    ns.Columns:Place("characters", COLUMNS, headings.cells, { gap = 8 })
    widgets.headings = headings

    -- Click a heading to sort each side by it.
    local labels = { name = nameHeading }
    for key, cell in pairs(headings.cells) do labels[key] = cell end
    widgets.sorter = Widgets.SortableHeadings and Widgets.SortableHeadings(labels, {
        name = function(entry) return entry.name end,
        level = function(entry)
            if not entry.level then return nil end
            return entry.level + (entry.levelShare or 0) * 0.99
        end,
        rested = function(entry) return entry.rested end,
        gold = function(entry) return entry.gold end,
        professions = function(entry)
            local best = Learned(entry)[1]
            return best and best.skillLevel or nil
        end,
        mail = function(entry) return entry.mailCount end,
        zone = function(entry) return entry.zone end,
        played = function(entry) return entry.played end,
        seen = function(entry) return entry.isCurrent and math.huge or entry.seenAt end,
    }, function() RefreshCharacters() end)
    if widgets.sorter then widgets.sorter:SetText({ "name", "zone" }) end

    -- Right-click the headings to choose the columns.
    ns.Columns:Attach(headings, "characters", widgets.sorter)
    ns.Columns:OnChange("characters", function()
        ns.Columns:Place("characters", COLUMNS, headings.cells, { gap = 8 })
        if widgets.sorter then widgets.sorter:Sync() end
        if widgets.list then widgets.list:Refresh() end
    end)

    local list = Widgets.CreateScrollList(view, {
        rowHeight = ROW_HEIGHT,
        createRow = CreateRow,
        updateRow = UpdateRow,
        -- The character whose line is open stays lit, and so does its line.
        isSelected = function(entry)
            return entry.kind ~= "heading" and state.open ~= nil and entry.key == state.open
        end,

        onClick = function(entry)
            if entry.kind == "heading" then
                state.folded[entry.side] = not state.folded[entry.side] or nil
            elseif entry.kind == "char" then
                state.open = state.open ~= entry.key and entry.key or nil
            else
                return
            end
            RefreshCharacters()
        end,

        onEnter = ShowRowTooltip,
        onLeave = function() GameTooltip:Hide() end,

        -- Headings step left with the rows while the scrollbar shows.
        onScrollbarShown = function(shown)
            headings:SetPoint("TOPRIGHT", view, "TOPRIGHT", -8 - (shown and 10 or 0), -62)
        end,
    })
    list:SetPoint("TOPLEFT", 8, -78)
    list:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT", -8, 28)
    widgets.list = list

    local emptyLabel = Theme.CreateLabel(view, "small", "dim", "CENTER")
    emptyLabel:SetPoint("CENTER", list, "CENTER")
    emptyLabel:SetWidth(360)
    emptyLabel:SetWordWrap(true)
    widgets.emptyLabel = emptyLabel

    local summary = Theme.CreateLabel(view, "small", "text")
    summary:SetPoint("BOTTOMLEFT", 8, 10)
    widgets.summary = summary

    local hint = Theme.CreateLabel(view, "tiny", "dim", "RIGHT")
    hint:SetPoint("BOTTOMRIGHT", -8, 10)
    hint:SetText(L["Click a heading to sort"])
end

local function Build(container)
    local views = {}

    for _, definition in ipairs(VIEWS) do
        local view = CreateFrame("Frame", nil, container)
        view:SetAllPoints(container)
        view:Hide()
        views[definition.key] = view
    end

    BuildCharacters(views.characters)
    if ns.BankView then ns.BankView.Build(views.bank) end

    widgets.views = views
    widgets.switch = BuildSwitch(container)

    ShowView(state.view)
end

UI:RegisterTab({
    key = "characters",
    text = L["Characters"],
    order = 11,
    build = Build,
    refresh = Refresh,
})

--- For the tests: what the tab drew and its state.
ns.CharactersTab._state = state
ns.CharactersTab._widgets = widgets
ns.CharactersTab.PlayedText = PlayedText
