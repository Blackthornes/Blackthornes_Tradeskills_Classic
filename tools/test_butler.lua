-- Logic/Butler.lua outside WoW.
--
-- Blackthornes Butler asks Butler:Advise(itemID) once per bag item. What
-- must hold:
--   1. The auction value is per unit, after the cut and the deposit; greys
--      and bind-on-pickup gear have none.
--   2. Demand "high" is fast, "low" is slow, anything else unknown.
--   3. Disenchant value, whether the character playing can break it, and
--      who can when it cannot.
--   4. The queue's need from these bags, and the alt to mail it to.
--   5. The queue, mail plan and enchanters are read once a burst, not once
--      an item.
--   6. Anything that raises gives nil, never an error.

local now = 100
GetTime = function() return now end

local ns = {}
ns.NewModule = function(name) local m = {} ns[name] = m return m end

local SELF, ALT, ALT2, OTHER = "Player-1", "Player-2", "Player-3", "Player-4"
ns.db = {
  characters = {
    [SELF] = { name = "Mia", realm = "R", faction = "Alliance", professions = {} },
    [ALT] = { name = "Ana", realm = "R", faction = "Alliance",
      professions = { { name = "Enchanting", skillLevel = 150 } } },
    [ALT2] = { name = "Bo", realm = "R", faction = "Alliance",
      professions = { { name = "Enchanting", skillLevel = 300 } }, linkedFrom = "other" },
    [OTHER] = { name = "Cy", realm = "R", faction = "Horde",
      professions = { { name = "Enchanting", skillLevel = 300 } } },
  },
}

ns.Config = {
  GetCharacterKey = function() return SELF end,
  Get = function(_, key) if key == "auctionCut" then return 0.05 end end,
}

local quality = { [1] = 2, [2] = 0, [3] = 2, [4] = 3, [5] = 2 }
local prices = { [1] = 10000, [2] = 500, [3] = 2000, [5] = 4000 }
local deposits = { [1] = 100 }
local rivals = { [1] = 6000, [3] = 2000 }
local stale = { [3] = true }
ns.Prices = {
  GetValue = function(_, itemID) return prices[itemID] end,
  GetScanValue = function(_, itemID, which) if which == "rival" then return rivals[itemID] end end,
  IsStale = function(_, itemID) return stale[itemID] == true end,
}
ns.Profit = {
  NetFromListing = function(_, itemID, unit) return unit * 0.95 - (deposits[itemID] or 0) end,
}
ns.Util = { IsBoundOnPickup = function(itemID) return itemID == 5 end }

local demand = { [1] = "high", [3] = "low", [5] = "some" }
ns.Demand = { Get = function(_, itemID) return demand[itemID] and { level = demand[itemID] } or nil end }

-- 1 and 4 break; 1 needs 100 Enchanting, 4 needs 200. 3 is not gear.
local skills = { [1] = 100, [4] = 200 }
ns.Disenchant = {
  GetItemFacts = function(_, itemID) return quality[itemID] and { quality = quality[itemID] } end,
  IsDisenchantable = function(_, itemID)
    if itemID == 99 then return nil end
    return skills[itemID] ~= nil
  end,
  GetValue = function(_, itemID)
    return itemID == 1 and 3000 or 7000, nil, { facts = { skill = skills[itemID] } }
  end,
}

local knows = false
ns.Disenchanter = { Knows = function() return knows end }

local plans = 0
local deliveries = {}
ns.Queue = {
  version = 0,
  GetAll = function() return {} end,
  CanMail = function(_, from, to)
    return ns.db.characters[from].faction == ns.db.characters[to].faction
  end,
}
ns.Inventory = { changes = 0, GetBankCount = function(_, itemID) return itemID == 3 and 2 or 0 end }
local typed
ns.QueueMail = {
  GetPlan = function()
    plans = plans + 1
    return { [SELF] = { [3] = 10, [1] = 1 } }, { [SELF] = { [1] = 4 } }
  end,
  GetDeliveries = function() return deliveries end,
  GetDisenchanter = function() return typed end,
  GetDisenchantQuality = function() return 2 end,
  FindCharacter = function() return nil end,
  -- The Mail page's rule for the disenchanter, as QueueMail has it.
  GoesToDisenchanter = function(_, itemID, q) return itemID == 1 and q == 2 end,
}
ns.Recipes = {
  GetShortCharacterName = function(_, key) return ns.db.characters[key].name end,
}

assert(loadfile(lfs_cwd .. "/Core/Characters.lua"))("Blackthornes_TS", ns)
local chunk = assert(loadfile(lfs_cwd .. "/Logic/Butler.lua"))
chunk("Blackthornes_TS", ns)
local Butler = ns.Butler

local failures = 0
local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(string.format("  FAIL  %-52s got %s, wanted %s", label, tostring(got), tostring(want)))
  else
    print(string.format("  ok    %-52s %s", label, tostring(got)))
  end
end

print("\nauction and demand")
local a = Butler:Advise(1)
check("after the cut and the deposit, per unit", a.auction, 9400)
check("high demand is fast", a.fast, true)
check("a grey has no auction value", Butler:Advise(2).auction, nil)
check("bind on pickup has no auction value", Butler:Advise(5).auction, nil)
check("some demand is unknown", Butler:Advise(5).fast, nil)
check("low demand is slow", Butler:Advise(3).fast, false)
check("never priced has no auction value", Butler:Advise(4).auction, nil)
check("an ID as text is read", Butler:Advise("1").auction, 9400)
check("today's cheapest rival, after the cut and the deposit", a.auctionNow, 5600)
check("an old scan says nothing about today", Butler:Advise(3).auctionNow, nil)
check("nobody else listing it", Butler:Advise(5).auctionNow, nil)
check("no auction value, no price today", Butler:Advise(2).auctionNow, nil)
check("not an item gives nil", Butler:Advise(nil), nil)

-- A copy's link prices its random suffix ("of the Monkey") as it sells.
local MONKEY = "|cff1eff00|Hitem:1::::::612:1:60|h[Band of the Monkey]|h|r"
ns.Prices.GetLinkValue = function(_, link, which)
  if link == MONKEY then return which == "rival" and 18000 or 20000, true end
end
local m = Butler:Advise(MONKEY)
check("a link prices its suffix", m and m.auction, 18900)
check("and today's cheapest of that suffix", m and m.auctionNow, 17000)
check("a link is still the item: its demand", m and m.fast, true)
check("a plain ID is unchanged", Butler:Advise(1).auction, 9400)
check("a link with no item gives nil", Butler:Advise("[Band]"), nil)
ns.Prices.GetLinkValue = nil

print("\nlisting under what it costs to make")
check("no Posting module: nothing said", a.belowCost, nil)
local allowLoss, chosen, paidFor = false, {}, {}
local craftCost = { [1] = 12000, [3] = 1000 }
ns.Cost = { FindAnyRecipeForItem = function(_, itemID) return craftCost[itemID] and itemID end }
ns.CraftedCost = { Get = function(_, itemID) return paidFor[itemID] and { cost = paidFor[itemID] } end }
ns.Posting = {
  GetPostPrice = function(_, itemID) return rivals[itemID] or prices[itemID] end,
  GetChosenPrice = function(_, itemID) return chosen[itemID] end,
  BelowCost = function(_, itemID, price)
    if allowLoss then return nil end
    local unit = craftCost[itemID]
    if unit and price < unit then return unit end
  end,
  BelowCraftedCost = function(_, itemID, price)
    if paidFor[itemID] and price < paidFor[itemID] then return paidFor[itemID] end
  end,
}
check("a craft listed under its materials: the cost", Butler:Advise(1).belowCost, 12000)
check("a craft whose price covers it", Butler:Advise(3).belowCost, nil)
check("not a craft", Butler:Advise(5).belowCost, nil)
check("no auction value says nothing", Butler:Advise(2).belowCost, nil)
chosen[1] = 15000
check("a price the player chose covers it", Butler:Advise(1).belowCost, nil)
chosen[1] = nil
allowLoss = true
check("selling at a loss allowed", Butler:Advise(1).belowCost, nil)
paidFor[1] = 7000
check("under what the last craft cost, with that guard on", Butler:Advise(1).belowCost, 7000)
allowLoss, paidFor[1] = false, nil
ns.Posting.GetPostPrice = function() error("boom") end
check("a price that raises gives nil", Butler:Advise(1), nil)
ns.Posting, ns.Cost, ns.CraftedCost = nil, nil, nil

print("\ndisenchanting")
check("value", a.disenchant, 3000)
check("cannot without the spell", a.canDisenchant, false)
check("the alt with enough skill on this account", a.enchanter, "Ana")
local b = Butler:Advise(4)
check("too much for every alt here: nobody", b.enchanter, nil)
check("its value still shows", b.disenchant, 7000)
check("not gear cannot be broken", Butler:Advise(3).canDisenchant, false)
check("and has no value", Butler:Advise(3).disenchant, nil)
check("not loaded yet is unknown", Butler:Advise(99).canDisenchant, nil)

typed = "Zed"
Butler:Forget()
check("the disenchanter typed in Settings comes first", Butler:Advise(1).enchanter, "Zed")
check("but not above the quality picked", Butler:Advise(4).enchanter, nil)
check("gear the Mail page sends there names it", Butler:Advise(1).disenchanter, "Zed")
check("gear it does not send names nobody", Butler:Advise(4).disenchanter, nil)
typed = nil
Butler:Forget()
check("no disenchanter typed names nobody", Butler:Advise(1).disenchanter, nil)

knows = true
ns.db.characters[SELF].professions = { { name = "Enchanting", skillLevel = 150 } }
Butler:Forget()
local c = Butler:Advise(1)
check("knows it and has the skill", c.canDisenchant, true)
check("then no alt is named", c.enchanter, nil)
check("short of the skill", Butler:Advise(4).canDisenchant, false)

print("\nthe queue")
check("own crafts use less what it makes", Butler:Advise(1).need, nil)
check("own crafts use less what is in the bank", Butler:Advise(3).need, 8)

deliveries = {
  { to = ALT2, items = { { itemID = 3, count = 2 } } },
  { to = ALT, items = { { itemID = 3, count = 5 }, { itemID = 4, count = 1 } } },
}
-- The bags moved, so the lookup is built again.
ns.Inventory.changes = 1
local d = Butler:Advise(3)
check("mail to the alt that takes the most", d.mailTo, "Ana")
check("and how many", d.mailCount, 5)
check("nothing to mail", Butler:Advise(1).mailTo, nil)

print("\nonce a burst")
local before = plans
for itemID = 1, 100 do Butler:Advise(itemID) end
check("a hundred questions, no new plan", plans, before)
ns.Queue.version = 1
Butler:Advise(1)
check("the queue changed: one new plan", plans, before + 1)
now = now + 5
Butler:Advise(1)
check("kept too long: one new plan", plans, before + 2)

print("\nevery character's holdings")
ns.db.characters[SELF].inventory = { [1] = 99 }
ns.db.characters[SELF].bank = { [3] = 4, [7] = 0 }
ns.db.characters[ALT].inventory = { [1] = 2, ["x"] = 5 }
ns.db.characters[ALT].inventoryAt = 50
ns.db.characters[ALT].mail = { [4] = 1 }
ns.db.characters[ALT].mailAt = 60
ns.db.characters[ALT].mailExpiry = { count = 4, soonest = 1.5, soon = 3, returns = 1, gone = 2 }
ns.Inventory.GetBagCounts = function() return { [1] = 3, [5] = 1 } end
ns.Recipes.GetCharacters = function()
  return {
    { key = SELF, name = "Mia", isCurrent = true },
    { key = ALT, name = "Ana", isCurrent = false },
    { key = ALT2, name = "Bo", isCurrent = false, linkedFrom = "other" },
    { key = "Gone-1", name = "Gone", isCurrent = false },
  }
end
ns.db.characters[ALT].gold = 1234
ns.db.characters[SELF].gold = 5
local oldGetMoney = GetMoney
GetMoney = function() return 99999 end
local held = Butler:Holdings()
GetMoney = oldGetMoney
check("one entry per character on record", #held, 3)
check("the character playing first", held[1].key, SELF)
check("its bags are read live", held[1].bags[1], 3)
check("its bank is the snapshot", held[1].bank[3], 4)
check("empty counts are left out", held[1].bank[7], nil)
check("an alt's bags are its snapshot", held[2].bags[1], 2)
check("a key that is not an item is left out", held[2].bags["x"], nil)
check("when the bags were read", held[2].bagsAt, 50)
check("its mail", held[2].mail[4], 1)
check("when the mail was read", held[2].mailAt, 60)
check("never read is nil", held[2].bankAt, nil)
check("how many mails in the box", held[2].mailCount, 4)
check("the soonest a mail runs out", held[2].mailSoonest, 1.5)
check("how many run out soon", held[2].mailSoonCount, 3)
check("how many go back", held[2].mailReturns, 1)
check("how many are gone for good", held[2].mailGone, 2)
check("never read this way is nil", held[1].mailSoonest, nil)
check("another account's character says so", held[3].linked, "other")
check("the short name", held[2].short, "Ana")
check("an alt's gold as last seen", held[2].gold, 1234)
check("when it was seen", held[2].goldAt, 50)
check("never seen is nil", held[3].gold, nil)
check("the character playing's purse is live", held[1].gold, 99999)
held[2].bags[1] = 1000
check("a copy: the save is untouched", ns.db.characters[ALT].inventory[1], 2)
ns.Recipes.GetCharacters = function() error("boom") end
check("an error gives nil", Butler:Holdings(), nil)

print("\nfilling mail and taking from the bank")
local filled
ns.QueueMail.Fill = function(_, delivery) filled = delivery return true end
ns.QueueMail.FindCharacter = function(_, typed) return typed == "Ana" and ALT or nil end
ns.QueueMail.MailName = function(record) return record.name .. " Smith" end
local started = Butler:FillMail("Ana", { { itemID = 3, count = 5 }, { itemID = "x" }, { itemID = 4, count = 0 } })
check("filling starts", started, true)
check("to the character's full mail name", filled and filled.recipient, "Ana Smith")
check("only real counts go in", filled and #filled.items, 1)
Butler:FillMail("Zed", { { itemID = 3, count = 1 } })
check("a name not on record is used as typed", filled.recipient, "Zed")
-- Two characters sharing a first name are "Ana S." and "Ana T." to Butler,
-- which FindCharacter cannot read back: the full name still goes in.
local shortNames = ns.Recipes.GetShortCharacterName
ns.Recipes.GetShortCharacterName = function(_, key) return key == ALT and "Ana S." or key end
ns.QueueMail.FindCharacter = function() return nil end
Butler:FillMail("Ana S.", { { itemID = 3, count = 1 } })
check("a shared first name still gets the full name", filled.recipient, "Ana Smith")
-- The same character kept under a second key gives the same short name;
-- the account's own record on this realm is the one mailed.
ns.db.characters["Ana-Old"] = { name = "Ana", realm = "Elsewhere", linkedFrom = "Bob" }
ns.Recipes.GetShortCharacterName = function(_, key)
  return (key == ALT or key == "Ana-Old") and "Ana S." or key
end
ns.QueueMail.MailName = function(record) return record.name .. (record.linkedFrom and " Copy" or " Smith") end
Butler:FillMail("Ana S.", { { itemID = 3, count = 1 } })
check("two records with that short name: still the full name", filled.recipient, "Ana Smith")
ns.db.characters["Ana-Old"] = nil
-- Short names worked out differently since: the full name still matches.
ns.Recipes.GetShortCharacterName = function(_, key) return key end
ns.Recipes.GetCharacterName = function(_, key) return key == ALT and "Ana Smith" or key end
Butler:FillMail("Ana S.", { { itemID = 3, count = 1 } })
check("matched by the full name when short names differ", filled.recipient, "Ana Smith")
ns.Recipes.GetCharacterName = nil
ns.QueueMail.MailName = function(record) return record.name .. " Smith" end
ns.Recipes.GetShortCharacterName = shortNames
ns.QueueMail.FindCharacter = function(_, typed) return typed == "Ana" and ALT or nil end
-- Never a mail to the character playing, under any record of it (a player
-- found one, 2026-10-11), and the full name comes back for the chat line.
local _, _, fullName = Butler:FillMail("Ana", { { itemID = 3, count = 1 } })
check("the full name it went to comes back", fullName, "Ana Smith")
ns.QueueMail.IsPlaying = function(_, key) return key == ALT end
filled = nil
local toMe, whyMe = Butler:FillMail("Ana", { { itemID = 3, count = 1 } })
check("a mail to the character playing is not filled", toMe == false and filled == nil, true)
check("and says why", whyMe, "that's the character you're on")
ns.QueueMail.IsPlaying = nil
ns.QueueMail.IsPlayingName = function(_, typed) return typed == "Zed" or typed == "Ana Smith" end
check("nor to a name that is the character playing", (Butler:FillMail("Zed", { { itemID = 3, count = 1 } })), false)
check("nor when the full name is", (Butler:FillMail("Ana", { { itemID = 3, count = 1 } })), false)
ns.QueueMail.IsPlayingName = nil
-- Gold alone is a mail (Butler's gold top-ups, 2026-10-11).
check("gold alone fills a mail", (Butler:FillMail("Ana", {}, 50000)), true)
check("with the gold", filled.money, 50000)
check("and no items", #filled.items, 0)
check("under its own subject", filled.subject, "Gold from Blackthornes Butler")
Butler:FillMail("Ana", { { itemID = 3, count = 1 } })
check("no gold asked, none put in", filled.money, nil)
local none, why = Butler:FillMail("Ana", {})
check("nothing to mail", none, false)
check("and says why", why, "nothing to mail")
ns.QueueMail.Fill = function() return false, "the mailbox is not open" end
local _, whyNot = Butler:FillMail("Ana", { { itemID = 3, count = 1 } })
check("the mailbox shut", whyNot, "the mailbox is not open")
ns.QueueMail.Fill = function() error("boom") end
check("an error inside is false", (Butler:FillMail("Ana", { { itemID = 3, count = 1 } })), false)

-- The plan uses 10 of item 3 and 1 of item 1 (makes 4 of item 1); the bank
-- holds 2 of item 3.
ns.Inventory.GetBagCount = function(_, itemID) return itemID == 3 and 3 or 0 end
local wants = Butler:FromBank()
check("what the bank should give: no more than it holds", wants[3], 2)
check("nothing for what it makes", wants[1], nil)
ns.Inventory.GetBankCount = function(_, itemID) return itemID == 3 and 20 or 0 end
check("up to what the crafts are short", Butler:FromBank()[3], 7)
ns.Inventory.GetBagCount = function() return 10 end
check("carried enough: nothing", Butler:FromBank()[3], nil)
ns.QueueMail.GetPlan = function() error("boom") end
check("an error gives nil", Butler:FromBank(), nil)

print("\nthe mailbox, when Butler takes it over")
local realPanel = ns.QueueMailPanel
local hidden, refreshed = 0, 0
ns.QueueMailPanel = {
  frame = { Hide = function() hidden = hidden + 1 end },
  Refresh = function() refreshed = refreshed + 1 end,
}
Butler:Mailbox(true)
check("covered: the mail panel steps aside", ns.QueueMailPanel.coveredByButler, true)
check("and is hidden", hidden, 1)
Butler:Mailbox(false)
check("uncovered: it comes back", ns.QueueMailPanel.coveredByButler, false)
check("drawn again", refreshed, 1)
ns.QueueMailPanel.Refresh = function() error("boom") end
check("never raises", pcall(Butler.Mailbox, Butler, false), true)
ns.QueueMailPanel = realPanel

print("\nnever raises")
ns.Prices.GetValue = function() error("boom") end
check("an error inside gives nil", Butler:Advise(1), nil)

print("")
if failures > 0 then
  error(string.format("%d Butler check(s) failed", failures))
end
print("  all Butler checks passed")
print("")
