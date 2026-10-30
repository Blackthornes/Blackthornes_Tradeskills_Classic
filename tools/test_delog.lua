-- Learning disenchant results from your own disenchants.
--
-- Asked 2026-09-27: "yes, build it", on recording what his own disenchants
-- give and using that over the built-in table. What this pins down:
--   * each of the three ways of telling which item went in: the loot
--     window's source, the bag slot clicked, the name sent with the cast;
--   * a click aimed at some other spell is not taken for a disenchant;
--   * loot that is not enchanting materials, or an item nobody can name,
--     is counted as a miss rather than recorded wrong;
--   * after LEARN_AFTER disenchants of a kind of item, its chances and
--     counts are yours, and the value follows them;
--   * an item that breaks into something other than its row says (a
--     player's Dire Wands, 2026-10-07) uses its own results after
--     ITEM_LEARN_AFTER of it, while the rest of its row does not.

local ns = {}
ns.COLORS = setmetatable({}, { __index = function() return "ffffffff" end })
ns.NewModule = function(name) local m = {}; ns[name] = m; return m end
ns.RegisterCommand = function() end
ns.RegisterEvent = function() end
local printed = {}
ns.Print = function(text) printed[#printed + 1] = text end
ns.PrintRaw, ns.Debug, ns.Warn = function() end, function() end, function() end

local saved = {
    C_Item = C_Item, C_Container = C_Container, GetTime = GetTime, CreateFrame = CreateFrame,
    SpellIsTargeting = SpellIsTargeting, GetNumLootItems = GetNumLootItems,
    GetLootSlotLink = GetLootSlotLink, GetLootSlotInfo = GetLootSlotInfo,
    GetLootSourceInfo = GetLootSourceInfo,
    UIErrorsFrame = UIErrorsFrame, PlaySound = PlaySound, SOUNDKIT = SOUNDKIT,
}

-- What was said on screen and which sounds played.
local flashed, sounds = {}, {}
UIErrorsFrame = { AddMessage = function(_, text) flashed[#flashed + 1] = text end }
SOUNDKIT = { LEVELUPSOUND = 888, UI_EPICLOOT_TOAST = 31578 }
PlaySound = function(kit) sounds[#sounds + 1] = kit end

local function Said(pattern, from)
    for index = from or 1, #printed do
        if printed[index]:find(pattern) then return printed[index] end
    end
    return nil
end

CreateFrame = function()
    local frame = {}
    for _, name in ipairs({ "SetScript", "Show", "Hide", "SetPoint", "SetSize" }) do
        frame[name] = function() end
    end
    return frame
end

local clock = 100
GetTime = function() return clock end
time = time or os.time

local STRANGE_DUST, LESSER_ASTRAL, SMALL_GLIMMERING = 10940, 10998, 10978
local GREATER_MAGIC = 10939
local LINEN = 2589

-- itemID -> quality, itemLevel, equipLoc, classID
local items = {
    [1001] = { 2, 22, "INVTYPE_CHEST", 4 },
    [1002] = { 2, 23, "INVTYPE_LEGS", 4 },
    [1003] = { 2, 24, "INVTYPE_WEAPON", 2 },
    [1004] = { 2, 23, "INVTYPE_RANGEDRIGHT", 2 },
    [1005] = { 2, 25, "INVTYPE_RANGEDRIGHT", 2 },
}

C_Item = {
    GetItemInfo = function(itemID)
        local item = items[itemID]
        if not item then return nil end
        return "item" .. itemID, nil, item[1], item[2], 1, "Armor", "Cloth", 1,
            item[3], 1, 10, item[4], 1, 2
    end,
    GetItemIDByGUID = function(guid) return tonumber(guid:match("Item%-(%d+)")) end,
}

-- Bag 0: slot 1 the chest, slot 2 the legs, slot 3 the sword, slots 4 and
-- 5 two wands.
local slots = { 1001, 1002, 1003, 1004, 1005 }
C_Container = {
    GetContainerItemID = function(_, slot) return slots[slot] end,
}

local targeting = false
SpellIsTargeting = function() return targeting end

local loot, lootSource = {}, nil
GetNumLootItems = function() return #loot end
GetLootSlotLink = function(slot) return ("|Hitem:%d::|h[x]|h"):format(loot[slot][1]) end
GetLootSlotInfo = function(slot) return "icon", "name", loot[slot][2] end
GetLootSourceInfo = function() return lootSource end

local prices = { [STRANGE_DUST] = 100, [LESSER_ASTRAL] = 1000, [SMALL_GLIMMERING] = 2000,
                 [GREATER_MAGIC] = 400 }

assert(loadfile(lfs_cwd .. "/Core/Util.lua"))("Blackthornes_TS", ns)

ns.db = {}
ns.Prices = { GetValue = function(_, itemID) return prices[itemID] end }
ns.Inventory = { GetBagCounts = function()
    return { [1001] = 1, [1002] = 1, [1003] = 1, [1004] = 1, [1005] = 1 }
end }

assert(loadfile(lfs_cwd .. "/Logic/Disenchant.lua"))("Blackthornes_TS", ns)
assert(loadfile(lfs_cwd .. "/Logic/DisenchantLog.lua"))("Blackthornes_TS", ns)

local Disenchant, Log = ns.Disenchant, ns.DisenchantLog

local checks = 0
local function check(label, condition)
    checks = checks + 1
    if not condition then error(("FAILED: %s"):format(label), 2) end
    print(("  ok  %s"):format(label))
end

local SPELL = 13262

--- One disenchant, the way the game plays it out.
local function Disenchantment(opts)
    clock = clock + 60

    if opts.click then
        targeting = true
        Log:OnBagClick(0, opts.click)
        targeting = false
    end

    Log:OnCastSent("UNIT_SPELLCAST_SENT", "player", opts.name or "", "cast", opts.spell or SPELL)
    clock = clock + 1.5
    Log:OnCastSucceeded("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", opts.spell or SPELL)

    loot, lootSource = opts.loot or {}, opts.source
    clock = clock + 0.3
    Log:OnLootReady()
    Log:OnLootReady()   -- LOOT_OPENED follows LOOT_READY; it must not count twice
end

local function Casts(key)
    local band = Log:GetBand(key)
    return band and band.casts or 0
end

local CHEST_KEY = "2:armor:25"

print("\ntelling which item went in")

Disenchantment({ click = 1, loot = { { STRANGE_DUST, 5 } } })
check("a bag click names the item", Casts(CHEST_KEY) == 1)
check("found by the click, and counted once across both loot events", Log:GetTable().recent[1].from == "click")
check("chat says what it gave", Said("Disenchanted.-5 Strange Dust") ~= nil)
check("and how far along learning that kind of item is",
    Said("learning green armor, item level 21 to 25: 1 of 10") ~= nil)
check("a first disenchant is not a new find", Said("New find") == nil and #sounds == 0)

Disenchantment({ loot = { { STRANGE_DUST, 4 } }, source = "Item-1002-0-ABC" })
check("the loot window's source names the item", Casts(CHEST_KEY) == 2
    and Log:GetTable().recent[1].itemID == 1002 and Log:GetTable().recent[1].from == "loot")

Disenchantment({ name = "item1001", loot = { { STRANGE_DUST, 6 } } })
check("the cast's item name finds it in the bags", Casts(CHEST_KEY) == 3
    and Log:GetTable().recent[1].from == "name")

Disenchantment({ name = "item1001 of the Bear", loot = { { STRANGE_DUST, 6 } } })
check("a random-suffix name still finds it", Casts(CHEST_KEY) == 4)

-- The Disenchanting tab's running total for this session.
local sessionCount, sessionWorth = Log:GetSession()
check("the session tally counts each disenchant", sessionCount == 4)
check("and adds up what the materials are worth", sessionWorth == Disenchant:GetMaterialPrice(STRANGE_DUST) * 21)

-- A click aimed at an enchant, then a Disenchant with nothing to go on.
clock = clock + 60
targeting = true
Log:OnBagClick(0, 3)
targeting = false
Log:OnCastSent("UNIT_SPELLCAST_SENT", "player", "item1003", "cast", 7418)
Disenchantment({ loot = { { STRANGE_DUST, 5 } } })
check("a click for some other spell is not taken as the target", Casts("2:weapon:25") == 0)
check("the disenchant is counted as missed instead", Log:GetTable().missed == 1)
check("and says why", Log:GetTable().lastMiss == "the game did not say which item was disenchanted")

Disenchantment({ click = 1, loot = { { LINEN, 2 } } })
check("loot that is not enchanting materials is not recorded", Casts(CHEST_KEY) == 4)
check("but counted as missed", Log:GetTable().missed == 2)

-- Any other spell's loot is none of this module's business.
Disenchantment({ click = 1, spell = 2575, loot = { { STRANGE_DUST, 5 } } })
check("loot after some other spell is ignored", Casts(CHEST_KEY) == 4 and Log:GetTable().missed == 2)
check("a missed disenchant is not added to the session tally", (Log:GetSession()) == 4)

-- A value the game will not let us compare, as inside an instance.
local secret = setmetatable({}, { __eq = function() error("secret") end,
    __concat = function() error("secret") end })
local ok = pcall(Log.OnCastSent, Log, "UNIT_SPELLCAST_SENT", secret, secret, "cast", SPELL)
check("a secret unit is ignored, not an error", ok)

-- A loot link the game will not let us read: matching it raises.
local SECRET_LINK = "|Hitem:10940::|h[secret]|h"
local realMatch, realLink = string.match, GetLootSlotLink
string.match = function(text, ...)
    if text == SECRET_LINK then error("secret value") end
    return realMatch(text, ...)
end
GetLootSlotLink = function() return SECRET_LINK end
local missedBefore = Log:GetTable().missed
ok = pcall(Disenchantment, { click = 1, loot = { { STRANGE_DUST, 5 } } })
string.match, GetLootSlotLink = realMatch, realLink
check("a secret loot link is missed, not an error", ok and Log:GetTable().missed == missedBefore + 1
    and Casts(CHEST_KEY) == 4)

print("\nClassic Era: no loot source, no name, no click seen")

-- Era's bags lock the item while Disenchant is cast on it.
local locked = {}
C_Container.GetContainerNumSlots = function(bag) return bag == 0 and #slots or 0 end
C_Container.GetContainerItemInfo = function(_, slot)
    return slots[slot] and { itemID = slots[slot], isLocked = locked[slot] == true } or nil
end

local function EraCast(lockSlots, before)
    clock = clock + 60
    if before then before() end
    Log:OnCastSent("UNIT_SPELLCAST_SENT", "player", "", "cast", SPELL)
    locked = lockSlots
    Log:OnCastStart("UNIT_SPELLCAST_START", "player", "cast", SPELL)
    clock = clock + 1.5
    Log:OnCastSucceeded("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", SPELL)
    loot, lootSource = { { STRANGE_DUST, 3 } }, nil
    clock = clock + 0.3
    Log:OnLootReady()
    locked = {}
end

local missedEra = Log:GetTable().missed
EraCast({ [3] = true })
check("the item locked in the bags is the one broken", Casts("2:weapon:25") == 1
    and Log:GetTable().recent[1].itemID == 1003 and Log:GetTable().recent[1].from == "locked")

EraCast({}, function() Log:Aim(1003, "button") end)
check("our Disenchant button says which item it aimed at", Casts("2:weapon:25") == 2
    and Log:GetTable().recent[1].from == "button")

EraCast({ [1] = true, [3] = true })
check("two kinds locked at once is no guess", Casts("2:weapon:25") == 2
    and Log:GetTable().missed == missedEra + 1)
C_Container.GetContainerNumSlots, C_Container.GetContainerItemInfo = nil, nil

print("\nusing your results")

local outcomes, facts = Disenchant:GetOutcomes(1001)
check("with 4 recorded, the table is still used", facts.source == "table" and facts.casts == 4)
check("and says how many of yours there are", facts.key == CHEST_KEY)

-- Six more, one of which also gave a shard, to reach ten.
local before = #printed
for index = 1, 6 do
    local got = { { STRANGE_DUST, 5 } }
    if index == 1 then got[2] = { SMALL_GLIMMERING, 1 } end
    Disenchantment({ click = 2, loot = got })
end

check("a material not seen before from that kind of item is a new find",
    Said("New find:.-Small Glimmering Shard can come from green armor", before) ~= nil)
check("a disenchant worth well over the usual is lucky", Said("Lucky:", before) ~= nil)
check("reaching ten says it was learnt, with the odds",
    Said("Learned:.-green armor, item level 21 to 25 now uses your own results: Strange Dust 100%%, Small Glimmering Shard 10%%", before) ~= nil)
check("each of those shows on screen too", #flashed == 2
    and flashed[1]:find("New find") and flashed[2]:find("Learned"))
check("with a soft sound for the find and the fanfare for learning",
    #sounds == 2 and sounds[1] == 31578 and sounds[2] == 888)
check("after ten the count goes on without 'of 10'",
    Said("green armor, item level 21 to 25: 10 recorded", before) ~= nil)

print("\nnaming kinds of item")
check("the lowest band", Disenchant:DescribeKey("2:weapon:15") == "green weapon, item level 15 and below")
check("the highest band", Disenchant:DescribeKey("3:any:top") == "blue items, item level 56 and up")
check("a middle band", Disenchant:DescribeKey("4:any:50") == "purple items, item level 46 to 50")

outcomes, facts = Disenchant:GetOutcomes(1002)
check("at ten, your results are used", facts.source == "yours" and facts.casts == 10)
check("dust came every time", outcomes[1].itemID == STRANGE_DUST and outcomes[1].chance == 1)
check("with the counts you saw", outcomes[1].min == 4 and outcomes[1].max == 6)
check("the shard once in ten", outcomes[2].itemID == SMALL_GLIMMERING and outcomes[2].chance == 0.1)
check("essence never, so it is not listed", #outcomes == 2)

-- Dust every time, 5.1 on average at 100: 510. The shard is a bonus.
check("the value follows your results", Disenchant:GetValue(1002) == 510)

check("a weapon of the same level is still on the table",
    select(2, Disenchant:GetOutcomes(1003)).source == "table")

print("\nan item that breaks differently from its row")

-- The table says a green weapon of item level 21 to 25 mostly gives Greater
-- Magic Essence (Forever's own); this wand gives Lesser Astral every time.
local wand = select(1, Disenchant:GetOutcomes(1004))
check("before any, the wand is on the table", wand[1].itemID == GREATER_MAGIC)

before = #printed
Disenchantment({ click = 4, loot = { { LESSER_ASTRAL, 1 } } })
Disenchantment({ click = 4, loot = { { LESSER_ASTRAL, 2 } } })
outcomes, facts = Disenchant:GetOutcomes(1004)
check("two of it are not yet enough", facts.source == "table" and not facts.byItem)

Disenchantment({ click = 4, loot = { { LESSER_ASTRAL, 1 } } })
outcomes, facts = Disenchant:GetOutcomes(1004)
check("at three, the wand uses what it gave", facts.source == "yours" and facts.byItem
    and facts.casts == 3)
check("Lesser Astral Essence every time", outcomes[1].itemID == LESSER_ASTRAL
    and outcomes[1].chance == 1 and #outcomes == 1)
check("with the counts it gave", outcomes[1].min == 1 and outcomes[1].max == 2)
check("the value follows it", Disenchant:GetValue(1004) == math.floor(1000 * 4 / 3 + 0.5)
    or math.abs(Disenchant:GetValue(1004) - 1000 * 4 / 3) < 1)
check("chat says it was learnt and why", Said("Learned:.-item1004 does not break the way the table says", before) ~= nil)
local learnedLines = 0
for index = before, #printed do
    if printed[index]:find("Learned:.-item1004") then learnedLines = learnedLines + 1 end
end
check("and says it once", learnedLines == 1)
check("the notes name this item", Disenchant:YoursPhrase(facts) == "your own 3 disenchants of this item")

local _, other = Disenchant:GetOutcomes(1005)
check("another wand of its row keeps the table", other.source == "table" and not other.byItem)

-- An item whose own results agree with its row keeps the bigger pool.
outcomes, facts = Disenchant:GetOutcomes(1002)
check("an item that agrees with its row keeps the row's results", facts.casts == 10 and not facts.byItem)

print("\nper item results from before they were kept")

ns.db = { disenchantLog = { bands = {}, missed = 0, recent = {
    { itemID = 1005, results = { [LESSER_ASTRAL] = 1 } },
    { itemID = 1005, results = { [LESSER_ASTRAL] = 2 } },
    { itemID = 1005, results = { [LESSER_ASTRAL] = 1 } },
} } }
check("the recent list fills them in", Log:GetItem(1005) and Log:GetItem(1005).casts == 3)
check("so that item learns from them at once", select(2, Disenchant:GetOutcomes(1005)).byItem == true)
check("the bands are left as they were", next(Log:GetTable().bands) == nil)

print("\nthree casts that only by luck lead with something else")

-- The sword's row mostly gives Greater Magic Essence. Two dust and one
-- essence in three is luck, not a different item: it stays on the table.
local function Casts(itemID, list)
    local recent = {}
    for _, results in ipairs(list) do
        recent[#recent + 1] = { itemID = itemID, results = results }
    end
    ns.db = { disenchantLog = { bands = {}, missed = 0, recent = recent } }
end

Casts(1003, { { [STRANGE_DUST] = 1 }, { [STRANGE_DUST] = 2 }, { [GREATER_MAGIC] = 1 } })
check("the table's likeliest came out once: still the table",
    select(2, Disenchant:GetOutcomes(1003)).source == "table")

local ten = {}
for i = 1, 8 do ten[i] = { [STRANGE_DUST] = 1 } end
ten[9], ten[10] = { [GREATER_MAGIC] = 1 }, { [GREATER_MAGIC] = 1 }
Casts(1003, ten)
check("ten that mostly give something else: its own results",
    select(2, Disenchant:GetOutcomes(1003)).byItem == true)

Casts(1003, { { [LESSER_ASTRAL] = 1 }, { [LESSER_ASTRAL] = 1 }, { [STRANGE_DUST] = 1 } })
check("three where the table's likeliest never came: its own results",
    select(2, Disenchant:GetOutcomes(1003)).byItem == true)

C_Item, C_Container, GetTime, CreateFrame = saved.C_Item, saved.C_Container, saved.GetTime, saved.CreateFrame
SpellIsTargeting, GetNumLootItems = saved.SpellIsTargeting, saved.GetNumLootItems
GetLootSlotLink, GetLootSlotInfo, GetLootSourceInfo =
    saved.GetLootSlotLink, saved.GetLootSlotInfo, saved.GetLootSourceInfo
UIErrorsFrame, PlaySound, SOUNDKIT = saved.UIErrorsFrame, saved.PlaySound, saved.SOUNDKIT

print(("\n%d check(s) passed\n"):format(checks))
