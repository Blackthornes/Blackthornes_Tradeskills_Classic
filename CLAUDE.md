# Notes for Claude

Read this before working in this repo. The owner also runs a separate Claude
project for his other addon, **Blackthornes_Farmer**
(`Blackthornes/Blackthornes_Farmer`), and that project has made changes here.
The two projects cannot read each other's memory, so what one of them needs to
know about the other lives in the repos, in this file and in Farmer's
`CLAUDE.md`. Keep it current: when work here changes something Farmer depends
on, or a new standing rule from the owner applies to both addons, add it to both
files.

Nothing private goes in this file (no local paths, emails or account names).
It never ships: `.pkgmeta` leaves it out of the zip and
`tools/check_package.py` refuses it.

## This repo is the Classic Era copy

`Blackthornes/Blackthornes_Tradeskills_Classic` is Tradeskills for WoW
Classic Era, copied from `Blackthornes/Blackthornes_Tradeskills` (Forever)
with its history on 2026-10-24 (the owner asked, after Farmer's, Butler's,
Pets' and Equipment's Era copies). Its releases, tests and CurseForge page
are its own. Forever comes first, and nothing done here may ever touch the
Forever addon. So:

- Never push to, or open PRs on, the Forever repo from work here. Changes
  come over from Forever on purpose (cherry-pick or copy), never the other
  way.
- The addon folder and TOC stay `Blackthornes_TS`, the saved data
  `BlackthornesTSDB` and `BlackthornesTSCharDB`, the global and `/bts`, so
  nothing is renamed.
- The TOC names Era's interface, `## Interface: 11509` (what the owner's
  Era client reports, 2026-10-24).
- Never put Forever's CurseForge ID (1710638) in the TOC:
  `tools/check_release.py` refuses a tag that does. The owner makes the Era
  project himself: Tradeskills Classic is **1763353** (2026-10-24), on the
  TOC's `X-Curse-Project-ID` line, and `tools/test_era.lua` checks it is there.
- What only Forever has comes out of the TOC a small PR at a time, its
  files kept in the repo so Forever changes merge cleanly. The plan is
  `docs/handoff/classic-port.md`. Era's auction house is the old one (no
  `C_AuctionHouse`), the biggest piece of work.
- Step 1 is done (2026-10-24): `Data/ForeverRecipes.lua` and
  `Data/ForeverVendorSpots.lua` are out of the TOC, so the recipe book is
  Classic's and only spots seen in game lie over Classic's.
  `VendorPins:Known` reads `ns.FOREVER_VENDOR_SPOTS` and
  `ns.FOREVER_TRAINER_SPOTS` only when they exist. `tools/test_era.lua`
  checks the TOC and loads every file it lists, then logs in, with no
  sister addon and no `C_AuctionHouse` (a loose client of its own, since
  this repo has no shared one).
- Step 2 is done (2026-10-24): Legacy, Merchant's Favor and its Waylaid
  Crates and the Craftsman's Writs are out of the TOC (their files stay).
  The Favors and Writs tab is not registered without them
  (`UI/Tab_Deals.lua`), and the "Crate Costs:" Settings row shows only
  with `ns.MerchantsFavor`. Saved settings for them stay, unread.
- Sending data to Blackthornes is back (2026-10-26): `Logic/Contribute.lua`
  is in the TOC again, sending to the owner's own Era characters, never
  Forever's. See `docs/CLASSIC_DIFFERENCES.md`.
- Scan works on Era's older auction house (2026-10-25): `Data/LegacyScan.lua`,
  the quick full scan when the game allows it, else page by page (see
  `docs/CLASSIC_DIFFERENCES.md`). Buying, your auctions and the drawer's
  other views are still to come.
- Calls to the other Blackthornes addons stay inside a pcall, and
  Tradeskills works on its own without them.
- Not yet seen in an Era client. Read client calls in a pcall as everywhere
  else.
- The rest of this file describes the Forever addon; read it as the
  starting point, not as what Era has.

## What the Farmer project did here

- **Release setup (PR #77, merged 2026-09-25).** Pushing a `vX.Y.Z` tag on
  `main` runs `.github/workflows/release.yml`: `tools/check_release.py`
  (CHANGELOG.md must open with `## X.Y.Z`), the tests, a packager build with
  nothing uploaded, `tools/check_package.py` (the clear-to-post scan), then the
  upload of that same checked folder. The TOC version is `@project-version@`
  and is never typed by hand. Details are in the README under Releasing.
- **CurseForge.** Project IDs: Tradeskills **1710638**, Farmer **1710618**.
  The upload uses the `CF_API_KEY` repository secret, which the owner set himself;
  never ask him to paste a token anywhere. The hand-uploaded original counts
  as 0.1.0.
- **v0.2.0 was tagged and uploaded to CurseForge on 2026-09-25.** Nothing has
  changed here since, so there is no newer release yet.
- **The CurseForge page.** The Farmer project wrote the Tradeskills
  description and its animated GIF and screenshots. They are not in this repo;
  The owner pasted and uploaded them on CurseForge himself. Description rules
  below.

## How Farmer uses Tradeskills

Farmer prices mob drops (worth per kill, rankings, fishing and gathering
value) from Tradeskills' auction data when both addons are loaded. It reads,
at runtime, inside a pcall and read only:

```lua
_G.BlackthornesTS.Prices:GetValue(itemID)   -- no second argument: "market"
```

It expects a copper number, or nil when there is no price. Since
2026-10-06 `GetValue` also follows a price the player set on the Prices tab
(`Prices:GetMine`, saved in `myPrices`): "use" replaces the scanned price,
"floor" lifts it, and "rival" stays the auction house's. `GetScanValue` is
the scans alone. It copies no data,
writes nothing, and has no TOC dependency; without Tradeskills it falls back to
vendor prices. So keep all three stable: the `_G.BlackthornesTS` global
(`Core/Init.lua`), `ns.Prices` on it, and `Prices:GetValue(itemID)` defaulting
to the smoothed market value (`Data/Prices.lua`). If one has to change, change
Farmer's `Logic/Value.lua` in the same breath and tell the owner both need
updating.

Farmer's top farm alert (2026-10-14) also asks to hear when a scan
finishes, inside a pcall:

```lua
_G.BlackthornesTS.Prices:WatchScans(fn)   -- fn({ items, at }) after each scan that wrote prices
```

`Prices:ScanFinished(result)` (from `UI:OnScanComplete`, only for a scan
that recorded prices) calls each watcher in a pcall and moves
`Prices.scanCount`. Keep `WatchScans` stable; if it changes, change
Farmer's `Logic/TopFarm.lua` too. Tested in `tools/test_scanwatch.lua`.

## How Tradeskills uses Farmer

The Gather tab's **Set goal** button (`Logic/FarmerGoals.lua`) turns a
material the queue still needs into a Farmer gathering goal. It shows only
when Farmer is loaded (`## OptionalDeps: Blackthornes_Farmer` in the TOC) and
calls, inside a pcall:

```lua
_G.BlackthornesFarmer.Goals:Find(name)            -- optional, to say "updated"
_G.BlackthornesFarmer.Goals:Set(name, amount)     -- goal table, or nil and why
_G.BlackthornesFarmer.GoalsUI:Show()              -- opens Farmer's Goals panel
_G.BlackthornesFarmer.Goals:Remove(name)          -- the queue no longer needs it
```

`name` is the item's plain name and `amount` the row's NEED. A goal made
with Set goal follows the queue (the owner, 2026-10-11, "work for the user
almost like magic"): `FarmerGoals:Remember` keeps it in
`farmerGoalsFromQueue[characterKey][itemID] = { name, target }` (never
rename it), and a second after a burst of `Queue:Notify` calls
`FarmerGoals:Follow` sets it to the shopping list's new `needed`, or
removes it when nothing queued needs it or the bags already hold enough.
A goal whose target the player changed in Farmer, or that finished or was
removed, is let go and never touched again. "Goals follow the queue"
(`farmerGoalsFollowQueue`, on unless unticked) on the Queue page. Farmer's goals
belong to the character that set them, so `Find` and `Set` act on the
character playing. Farmer's `CLAUDE.md` asks its side to keep these stable;
if one changes, change `Logic/FarmerGoals.lua` in the same breath.

## Craft or farm (the Your time view)

The owner said yes (2026-10-15, from a mockup): the Profit tab's switch
reads MY CRAFTS, YOUR TIME, RECIPES TO LEARN (`RecipeBookView.WithSwitch`
takes `extras`). `Logic/CraftOrFarm.lua` works out, for each craft the
character playing knows, three ways: farm the materials and craft (gold an
hour), farm them and sell them as they are (gold an hour), and buy them
and craft (the Profit tab's profit for one craft, never an hour, since a
craft takes seconds). Farming time is the player's own, from Farmer,
inside a pcall, read only:

```lua
_G.BlackthornesFarmer.Pace:ForItem(itemID)
  -- { seconds, kind, source, zone, samples, perAction }, or nil and { samples }
```

Crafting time is `CraftTime:GetCast` for every cast in the tree. A
material a vendor keeps in stock is bought on every way; one a craft of
the player's makes, with no pace of its own, is followed down to what it
is made from (`DEPTH`). Without Farmer, or with under 20 of the player's
own kills or gathers behind a material, the farm ways stay "--", never
guessed from drop tables. Walking and selling are not counted. Built a few
crafts a frame (`BUDGET`), kept `KEEP` seconds, nothing saved.
`UI/YourTimeView.lua` draws it (columns `yourtime`; right-click or Queue 1
queues one). Farmer's material tooltip asks:

```lua
_G.BlackthornesTS.CraftOrFarm:ForMaterial(itemID)
  -- { name, recipeID, perHour, rawPerHour } when crafting beats selling, or nil
```

Keep both calls stable; if one changes, change Farmer's `Logic/Pace.lua`
or `UI/ItemTooltip.lua` too. Tested in `tools/test_craftorfarm.lua` and
`tools/test_yourtimeview.lua`. Not yet seen in game.

## How Tradeskills uses Equipment

Gear that **Blackthornes_Equipment** (`Blackthornes/Blackthornes_Equipment`)
calls an upgrade for the character playing gets the green arrow on its icon,
everywhere Tradeskills draws item icons (`Theme.SetItemIcon` asks
`Logic/Upgrades.lua`). Equipment is optional (`## OptionalDeps` in the TOC);
without it nothing is drawn. It calls, inside a pcall and read only:

```lua
_G.BlackthornesEquipment.Compare:IsUpgrade(item)   -- item ID or link; true or false
```

Most windows ask by item ID. Bag rows on the Disenchanting tab pass the carried copy's link (`Theme.SetItemIcon(icon, itemID, link)`),
so random-suffix gear ("of the Monkey") is judged as that copy; Equipment's
`CLAUDE.md` already promises links. Answers are kept per item ID, or per
item string for a link, and forgotten on gear, level, talent and
item-info events. Setting: `showUpgradeArrows`. Equipment's `CLAUDE.md` asks
its side to keep the call stable; if it changes, change `Logic/Upgrades.lua`
in the same breath.

Enchants for your gear (a player asked, the owner said build it,
2026-10-16): an enchanting recipe makes no item, so the Level Up tab shows
its spell's icon (`Theme.SetSpellIcon`), and when Equipment says it beats
what is on the gear worn, the green arrow and "For you: Chest +3%" on the
row, the detail pane, the row's tooltip, "Best for you" on the Learn next
pane and on the enchant's own tooltip (`UI/EnchantTooltip.lua`). It
follows `showUpgradeArrows` and asks, inside a pcall, kept per recipe and
forgotten with the item answers (`Upgrades:EnchantFor`, `EnchantText`):

```lua
_G.BlackthornesEquipment.Enchants:ForRecipe(recipeID)
  -- { slot, slotID, gain, current, best }, or nil
```

Equipment's Enchants view in Where to get upgrades calls back, inside a
pcall, besides `Queue:Ensure` and `Queue:EnsureBuy`:

```lua
ns.LearnNext:WhereFor(recipeID)       -- { kind, name, zone, x, y, price } or nil, a fresh table
ns.LearnNext:ShowTheWayFor(recipeID)  -- Show the way by recipe ID; true when a pin was set
```

Keep these stable; if one changes, change Equipment's `Logic/Enchants.lua`
too. Tested in `tools/test_enchantsforyou.lua` and
`tools/test_learnnext.lua`. Not yet seen in game.

Equipment calls back one way: when a player changes their own stat weights
in Equipment's weights window, or picks a spec there, it calls, inside a
pcall:

```lua
_G.BlackthornesTS.Upgrades:RedrawSoon()   -- forget kept answers, redraw what shows arrows
```

So keep `ns.Upgrades` on the global and `Upgrades:RedrawSoon()` stable too;
if it changes, change Equipment's `Weights:Changed` (`Logic/Weights.lua`).

Equipment's upgrade finder also lists crafted gear (who can make it, what
the materials cost). Its `Logic/Crafting.lua` reads, inside a pcall and read
only:

```lua
ns.Recipes:GetAccountWide(true)        -- recipes by ID (= spell ID), each with knownBy
ns.Recipes:GetShortCharacterName(key)  -- an alt's short name
ns.Config:GetCharacterKey()            -- the character playing
ns.db.characters[key].faction          -- to leave out the other faction's alts
ns.Prices:GetValue(itemID)             -- material and auction prices
ns.RecipeBook:GetSkill(recipeID)       -- the skill a recipe needs on Forever, or nil
```

`GetSkill` (added 2026-10-09, after a player found Forever had moved some
Leatherworking patterns to lower skills) answers what the recipe item's
own tooltip says (`Logic/RecipeBook.lua`, `RecipeBook:LearnSkill`, kept
account wide in `recipeSkills[recipe item ID]`, never rename it), then
the players' reports in `FOREVER_SKILLS`, then Classic's book.

Keep these stable as well; if one changes, change Equipment's
`Logic/Crafting.lua` in the same breath.

Equipment's **Queue it** button (a player asked on Discord, the owner agreeing
2026-10-10; on crafted rows in Where to get upgrades and the Upgrade
quest's Crafted tab) calls, inside a pcall, through its
`Logic/TradeskillsQueue.lua`:

```lua
ns.Queue:Ensure(recipeID, quantity)         -- at least that many queued; true, or nil and why
ns.Queue:EnsureBuy(itemID, count, forItem)  -- that many on the list to buy for forItem; true, or nil and why
ns.Queue:ForUpgrade(itemID)                 -- "craft", "buy" or nil: what the queue holds for the gear
ns.Queue:ShowQueue()                        -- opens the window on the Queue tab
```

Gear the character or an alt can make is queued; gear it still has to
learn has its materials put on the list to buy; gear nobody makes goes on
the list itself. The list to buy is `queueBuys` (account wide, each line
kept for its `owner`, never rename it). A line goes when the gear's craft
is queued (`Queue:Add`), when the gear is owned or worn, with its row's x
on the Queue tab, or with Clear all. Keep these four stable; if one
changes, change Equipment's `Logic/TradeskillsQueue.lua` too.

## What Butler calls here

**Blackthornes_Butler** (`Blackthornes/Blackthornes_Butler`, the owner's
new addon, 2026-10-10) tells the player what to do with each item in the
bags. It asks Tradeskills one thing, through its `Logic/Sisters.lua`,
inside a pcall, read only, with no TOC dependency:

```lua
_G.BlackthornesTS.Butler:Advise(item)   -- item ID or the bag copy's link; a table, or nil; never raises
```

A link (2026-10-15; `Butler.TAKES_LINK` says it can) prices a random suffix ("of the Monkey") as that
suffix sells: `auction` and `auctionNow` read `Prices:GetLinkValue`, which
answers the suffix's own price when one is recent, else the item's.

`Logic/Butler.lua` answers with a fresh table, any field nil when unknown:

- `auction`: copper for one sold on the auction house, after the cut and
  the deposit (`Profit:NetFromListing` on `Prices:GetValue(itemID,
  "market")`), never below 0. nil for greys (vendor only), gear that binds
  when picked up, and items never priced.
- `auctionNow`: the same, at the cheapest listing that is not the
  player's own (`Prices:GetScanValue(itemID, "rival")`), only while the
  scan is fresh (`Prices:IsStale`); nil without `auction`. Butler holds
  an item back when it is well below `auction` (2026-10-13).
- `belowCost`: copper one costs to make, when the Sell list's price for it
  (`Posting:GetChosenPrice`, else `GetPostPrice`) is under that and
  Posting would refuse it (`Posting:BelowCost`, or `BelowCraftedCost` with
  "Never below what I paid" on); nil for anything not crafted, a price that
  covers it, or "Recommend selling at a loss" ticked. Butler holds such an
  item back instead of saying Auction (2026-10-13).
- `fast`: `Demand:Get` "high" is true, "low" false, "some" or no reading nil.
- `disenchant`: `Disenchant:GetValue`, copper for one; nil when it cannot
  be broken or its material has no price.
- `canDisenchant`: the character playing knows Disenchant
  (`Disenchanter:Knows`) and has the Enchanting the item needs; false for
  anything that cannot be disenchanted, nil while the item is not loaded.
- `enchanter`: only when the character playing cannot: the disenchanter
  typed in Settings (`QueueMail:GetDisenchanter`, up to its quality), else
  the alt on this account (not `linkedFrom`, `Queue:CanMail`) with the most
  Enchanting that is enough. The full name.
- `disenchanter`: the disenchanter typed in Settings (full name) when the
  item is gear the Mail page sends there (`QueueMail:GoesToDisenchanter`:
  green up to the quality picked, can be disenchanted, does not bind when
  picked up, not crafted (`RecipeBook:IsCrafted`: any recipe makes it),
  no upgrade for the character playing; the owner asked 2026-10-11 for
  Butler to follow that setting, for "disenchantable, non-crafted items").
  With the box empty it is the one picked for the player
  (`QueueMail:GuessDisenchanter`, 2026-10-11, "do the work for the
  player"): the alt on this account, same realm and side (`Queue:CanMail`,
  not `linkedFrom`), with the most Enchanting, if more than the character
  playing; "Pick one for me" on the Mail page (`disenchanterGuess`, on
  unless unticked, never rename it) turns that off, and then it is nil.
  `GetDisenchanter` returns the name and `true` when it was picked; the box
  shows the pick where "Character name" sits. A typed name always wins.
  `GetDisenchantDelivery` uses the same rule, so the two never disagree.
- `need`: what this character's own queued crafts use from its bags (use,
  less what it makes, less its bank), as `QueueMail:GetDeliveries` keeps back.
- `mailTo`, `mailCount`: the alt `GetDeliveries` would send the most of it
  to, full name, and how many.
- `bought`: how many the account bought on the auction house to
  disenchant (`DisenchantBuys:Count`), nil for none.
- `forEnchanting` (the owner asked 2026-10-13): a green the character
  playing can disenchant, not crafted (`RecipeBook:IsCrafted`), whose
  likely material (chance at least `Butler.LIKELY_OUTCOME`, 0.15) its own
  Enchanting still lacks for the crafts that give a point every time:
  `{ recipe, material, materialName, short, yield }`. The orange recipes
  it knows (the profession window's reading at this skill, else up to the
  book's `yellow`) are taken cheapest first, each for the points the ones
  before do not reach, and what it owns (bags, bank, mailbox) comes off,
  so it stops once there is enough. Kept in the lookup. Butler then says
  Disenchant. Tested in `tools/test_butlerenchanting.lua`.
- `youDisenchant` (the owner asked 2026-10-14): true when the character
  playing is the disenchanter (`QueueMail:IsDisenchanterPlaying`: the name
  typed on the Mail page, else, with the box empty and "Pick one for me"
  on, this character when it has Enchanting and no character it can mail
  has more), nil otherwise; kept in the lookup. `crafted`: true for a
  green some recipe makes, asked only then. Butler's "Disenchant greens
  here" (off unless ticked) reads both. Tested in
  `tools/test_butlerenchanting.lua` and `tools/test_disenchantmail.lua`.

Bought to disenchant (the owner asked 2026-10-11): `Logic/DisenchantBuys.lua`
marks an auction house buy that follows a search sent from the
Disenchanting tab (`Intend`, then `OnBought` from `AHBuys:Confirm`, within
15 minutes). Marks are account wide, by item and count, in
`boughtToDisenchant[itemID] = { count, at }` (never rename it), so mailing
or banking keeps them; they only shrink on a disenchant
(`DisenchantLog:Record` calls `Used`) or when the account holds fewer
(`Settle`: every character's bags, bank and mail, mail on its way, auction
buys in the mail; once per burst of bag events, never while the mailbox is
open). The tab's bags list puts them first, tagged, and picks them first
for its Disenchant button; a right-click there marks or unmarks. Butler's
menu calls, inside a pcall:

```lua
_G.BlackthornesTS.Butler:SetBoughtToDisenchant(itemID, on, count)  -- true, or false and why
```

Butler asks once per bag item, a hundred in a burst, so the queue plan,
the deliveries and the characters' Enchanting are read once into a lookup,
kept until `Queue.version` (moved by `Queue:Notify`) or
`Inventory.changes` moves, or two seconds pass, and built again only on
the next question. Keep the call and the fields stable; if one has to
change, change Butler's `Logic/Sisters.lua` in the same breath.

Butler's All characters list (a player asked, the owner agreeing
2026-10-10) asks once each time that list is built, never per item:

```lua
_G.BlackthornesTS.Butler:Holdings()   -- a list, or nil; never raises; reads only
```

One entry per character on record, in `Recipes:GetCharacters`' order (the
character playing first): `key`, `name`, `short`, `realm`, `faction`,
`isCurrent`, `playing` (the character playing under any of its records,
`Characters:IsPlaying`; added 2026-10-11, never mail it), `linked` (the
character it came through, for another account of the owner's), and `bags`, `bank`, `mail` as fresh `{ [itemID] = count }`
copies with `bagsAt`, `bankAt`, `mailAt` (`time()`, nil when never read),
and `gold`, `goldAt` (copper as last seen with the bags' snapshot, live for
the character playing; nil when never recorded; added 2026-10-11 for
Butler's gold top-ups).
The playing character's bags are live (`Inventory:GetBagCounts`), the rest
the saved snapshots (`inventory`, `bank`, `mail` on its record). Keep it
stable too; Butler's `Logic/Everyone.lua` reads it.

At a mailbox and the bank (the owner said start, 2026-10-11), Butler's
`Logic/Errands.lua` calls two more, inside a pcall:

```lua
_G.BlackthornesTS.Butler:FillMail(name, items, money)  -- true, or false and why; never raises
_G.BlackthornesTS.Butler:FromBank()             -- { [itemID] = count }, or nil; reads only
```

`FillMail` fills the Send Mail page through `QueueMail:Fill` for one of
the player's characters (`name` as Advise gave it, resolved with
`QueueMail:FindCharacter` and `MailName`; `items` a list of `{ itemID,
count }`, subject "From Blackthornes Butler"; `money`, optional copper,
goes in the gold boxes through `QueueMail.PutMoney`, gold alone being a
mail of its own, never with COD ticked and never more than the purse less
postage); the player presses Send and
QueueMail's own SendMail hook writes down what went. What did not fit
or could not be split goes in chat (`Butler.FillDone`), since Butler's
window covers the mail panel that says it; a split goes in the stack's own
bag first, then an ordinary bag, then a profession bag made for the item
(2026-10-13, herbs in a herb bag were left out). It never fills a mail
to the character playing, under any record of it (`QueueMail:IsPlaying`:
its key, a record carrying its GUID, or the old name-realm record left
beside the GUID one; a player found Butler filling one, 2026-10-11), and
answers false and "that's the character you're on"; filled, its third
return is the full name it went to, for Butler's chat line. Deliveries,
the enchanter and `FindCharacter` leave those records out too. `FromBank` is what
the playing character's own queued crafts use, less what it makes and
carries, no more than its bank holds, plus the `bank` count of its Jobs
mail for another character's craft (so Butler opens at the bank and
takes it out; 2026-10-11). Keep both stable too.

A craft step for the character playing also carries `slots` (the bag slots
making it frees, `Crafting:SlotsFreed`; nil with "Craft what frees bag space
first" off), which Butler's `Jobs.Order` sorts its plain crafts by (the
owner, 2026-10-15). Keep it stable.

Butler's step list for jobs on other characters (the owner asked
2026-10-11: "craft Medium Leather on another, then send it back") calls
two more, inside a pcall:

```lua
_G.BlackthornesTS.Butler:Jobs()            -- a list, or nil; never raises; reads only
_G.BlackthornesTS.Butler:Craft(recipeID)   -- true and "crafting" or "opened", or false and why
_G.BlackthornesTS.Butler:Profession(recipeID)  -- { name, spell, open }, or nil
```

`Jobs` is one entry per character with something to do in the queue (the
character playing first, then by name; only characters it can mail, never
`linkedFrom`): `key`, `name` (full), `isCurrent`, `steps`. A step is a
craft (`kind = "craft"`, `recipeID`, `itemID`, `name`, `count` made,
`crafts`, `forNames` in full, `ready`, `missing = { { itemID, count } }`
from `Queue:HeldBy`) or a mail (`kind = "mail"`, `to` in full, `items`,
`crafts`): the playing character's `QueueMail:GetDeliveries`, the others'
`QueueMail:GetOwedBy(key)` (made for someone, not yet mailed). A craft
held up for materials another character carries or banks names it as
that missing item's `from`, and that character gets a mail step to the
crafter first (`forCraft = true`), so Butler can send the player there
before the craft (the owner, 2026-10-11: a sub-craft whose materials are
on hand goes to the top). The character playing counts too, read live,
its item's `bank` saying how many to take out of the bank first, and the
same item in its deliveries joins that mail rather than making a second
(a player logged in on the holder and the mail step was gone,
2026-10-11). An old name-realm record of the
crafter (`SameCharacter`) counts as the crafter's own. Each missing
material carries `vendor`, the copper for one when a vendor sells it
(`Vendor:GetUnitPrice`), so Butler lists it under Buy from a vendor and
the rest under Buy or gather (the owner, 2026-10-13). Records of one
character (its GUID one and an old name-realm one) are one entry, named
by the GUID record, and no step mails a character to itself under any
of its records (a player was told to log out for the character they were
on, 2026-10-11). `Craft`
runs the playing character's queued craft of that recipe from Butler's
click: `Crafting:Start` when the profession window shows it, else
`Queue:ShowQueue()` so the Open button opens the profession. Mail
waiting for a character (the owner, 2026-10-13: "if a character needs to
visit the mail for something sent to it, butler should move that up the
priority list") is a `pickup` step put first on its line (`items`,
`forCraft`): materials its crafts count on (`Queue:HeldBy`) that are not in
its bags or bank, so sit in its mailbox or are on their way, and anything
else mailed to it and not yet seen arrive (`QueueMail:InFlightItems`).
`Profession` (2026-10-15) names the profession a recipe is made in and the
spell that opens its window (`ProfessionOpener:ProfessionFor`), with `open`
while the window shows the recipe, so Butler's Craft button can open the
profession through a secure button of its own and craft on the next click.
Tested in `tools/test_butlerjobs.lua`. Keep all three stable; Butler's
`Logic/Jobs.lua` reads them.

Butler takes over the mailbox (the owner picked it, 2026-10-11): its
window comes up at every mailbox, and while it is up there it calls

```lua
_G.BlackthornesTS.Butler:Mailbox(covered)   -- true: the mail panel steps aside; false: it comes back
```

`UI/QueueMailPanel.lua` stays hidden while `coveredByButler` is set
(cleared on `MAIL_CLOSED`), so closing Butler's window brings it back.
Butler's Always mail list names characters from `Holdings()` (same realm
and faction). Keep `Mailbox` stable; Butler's `Logic/Errands.lua` calls it.

Butler's gold goals (the owner said build it, 2026-10-13) ask what the
trainers' recipes the character playing could learn now would cost:

```lua
_G.BlackthornesTS.Butler:LearnCost()   -- { [Classic skill line] = { skill, count, cost, recipes } }, or nil
```

`recipes` (2026-10-22, a player asked which recipe it meant) is `{ {
recipeID, name, cost } }`, cheapest first; Butler names them on the goal's
hover and a click calls `LearnNext:ShowTheWayFor(recipeID)`.

Recipes with a trainer's price in the book, reached by the skill, not
learned and not grey (`LearnNext.Tier`), by profession; a profession
whose recipes were never read is left out. Kept 30 s, or until the
character's `recipesCachedAt` moves. Tested in `tools/test_learnnext.lua`.
Keep it stable; Butler's `Logic/GoldGoals.lua` reads it.

Butler's Buy from a vendor row (the owner asked 2026-10-14 for the Buy
materials button in Butler too) has the same button, calling, inside a
pcall:

```lua
_G.BlackthornesTS.Butler:VendorOffer()     -- { count, cost, items, cheaperElsewhere, buying }, or nil
_G.BlackthornesTS.Butler:BuyFromVendor()   -- true, or false and why; never raises
```

`VendorOffer` is `Vendor:GetNeeded`'s answer (nil while no vendor is open
or its list is not read), `BuyFromVendor` the button's own click
(`Vendor:BuyNeeded`, then `UI:UpdateMerchantButton`). Tested in
`tools/test_butlervendor.lua`. Keep both stable; Butler's `Logic/Jobs.lua`
reads them. While Butler is loaded and its window opens at vendors (its
`openAtVendor`, read from `BlackthornesButlerDB`), the Buy materials button
over the vendor window hides (`UI.ButlerBuysHere`, the owner 2026-10-18):
Butler's Buy row does the buying. Tested in `tools/test_merchantbutton.lua`.

Butler's tooltip line "Vendors sell it for 25c" (a player asked, the
owner said build it, 2026-10-22) asks what a vendor charges for one,
inside a pcall, read only:

```lua
_G.BlackthornesTS.Butler:VendorPrice(itemID)   -- copper, or nil
```

`Vendor:GetUnitPrice`'s answer (a price seen at a merchant, else
`Data/VendorPrices.lua`); nil for anything no vendor is known to sell.
Tested in `tools/test_butlervendor.lua`. Keep it stable; Butler's
`Logic/VendorPrices.lua` reads it.

Butler's "For your quests" line (a player asked 2026-10-14, the owner said
build it: buy what open quests need) has a Search button at the auction
house, calling, inside a pcall:

```lua
_G.BlackthornesTS.Butler:SearchAuctions(items)   -- { { itemID, count } }: true and "all" or "one", or false and why
```

Several items go in one `ShoppingLists:SearchMany` ("all"); where the game
takes one a search, the first goes through `UI:SearchAuctionHouse` with its
count for the buy box ("one"), and Butler sends the rest on the next click.
Tested in `tools/test_butlersearch.lua`. Keep it stable; Butler's
`Logic/Quests.lua` calls it.

Butler's bank alt (a player asked, the owner said build it, 2026-10-14)
can take everything on one of the player's shopping lists, so it reads
them, inside a pcall:

```lua
_G.BlackthornesTS.Butler:Lists()   -- { { name, id, items = { [itemID] = want } } }, ShoppingLists.version; or nil
```

`id` (2026-10-19) is the list's stable id (see "List rules"); Butler's
Lists page keeps its own Mail To and Keep Here for a list by it.

The player's own lists only (`ShoppingLists:Readable`), never the craft
queue's, fresh tables each time; nothing is written. Tested in
`tools/test_butlerlists.lua`. Keep it stable; Butler's `Logic/BankAlt.lua`
reads it.

Butler's "Cheapest Skill-Up" line in Jobs (a player asked, the owner said
build it, 2026-10-19; off unless ticked in Butler) shows the Level Up
tab's top pick for each profession, inside a pcall:

```lua
_G.BlackthornesTS.Butler:NextSkillUp()      -- { { profession, skill, max, recipeID, itemID, name, tier, cost, queued, toBuy } }, or nil
_G.BlackthornesTS.Butler:QueueSkillUp(id)   -- one in the queue: true, or false and why
```

The first row of each profession in `LevelUp:GetRanked`'s order that is a
sure or likely point with a priced cost (`cost` is REAL COST, below 0 when
the craft pays). A profession at its max for now (2026-10-20, the owner:
Butler names the next trainer) comes as `{ profession, english, skill, max,
capped = true }` with no recipe, from the rows and from the saved read
(`Recipes:GetLearnedProfessions`); an older Butler skips it. Kept 30 s, or
until the queue, bags, a scan, the recipes, the purse or "Can afford"
move. `toBuy` (2026-10-22) is copper to buy what the bags and bank lack
(`LevelUp.ToBuy`), and Butler shows the same red note when it is more
than the purse; with "Can afford" ticked the pick skips crafts the purse
can't cover. Tested in `tools/test_butlerskillup.lua` and
`tools/test_canafford.lua`. Keep both stable; Butler's `Logic/Jobs.lua`
reads them.

Butler's "Craft When It Pays More" (a player asked, the owner said build
it, 2026-10-19; off unless ticked in Butler) asks, only while it is on,
inside a pcall:

```lua
_G.BlackthornesTS.Butler:CraftFor(item, carried, skip)
  -- { recipeID, name, itemID (what it makes), per, crafts, perItem, needs = { { itemID, count } } }, or nil
_G.BlackthornesTS.Butler:QueueCraft(recipeID, crafts)   -- Queue:Ensure; true, or false and why
```

Only recipes the character playing knows (not a dropped profession) that
use the item. Each is valued by `Profit:Analyse` "best" after the cut and
deposit (a slow auction at `Butler.SLOW`, a derived or uncontested price
never), less the other materials (`Cost:GetCraftCost`, owned at their
worth); `perItem` is that over how many one craft uses. Kept in the
lookup. `skip` (2026-10-26, optional) is `{ [recipeID] = name }`, the
crafts the player told Butler to stop suggesting; they are passed over, so
the next best answers. Tested in `tools/test_butlercraft.lua`. Keep both stable; Butler's
`Logic/Sisters.lua` reads them.

## Random suffix prices

A player asked (2026-10-15, the owner said build it): gear "of the Monkey"
and "of the Spirit" share one item ID, and its one price mixed every
suffix. Each suffix seen at the auction house now keeps a price of its own
beside the item's, in the item's price record as `record.suffixes[suffix]
= { market, min, rival, quantity, seen }` (never rename it; at most
`Prices.SUFFIX_MOST`, the oldest seen going first; used for
`Prices.SUFFIX_KEEP`). The item's own price is unchanged. Read from full
scans (`C_AuctionHouse.GetReplicateItemLink`, asked only for green or better
weapons and armour, `Scanner.MayHaveSuffix`), browse rows (the key's
`itemSuffix`) and item searches (each listing's `itemLink`).
`Prices:GetLinkValue(link, which)` is a copy's price: its suffix's, else
`GetValue`'s, with the player's own price still winning. The tooltip adds
"This one" for a copy whose suffix has a price, and Butler's `Advise` takes
the bag link. `GetValue(itemID)` is unchanged, so Farmer and Equipment read
as before. The screens that follow a copy's suffix (the owner, 2026-10-15:
"people want Tradeskills to respect suffixes on greens"): Post's suggested
price, worth and confirm box (`Posting:ListedCopy`, the bag copy's link,
kept until `Inventory.changes` moves; `Profit:ChoosePostPrice` takes it),
Your auctions' undercut (`MyAuctions:Judge` by the auction's link), the
Disenchanting tab's bag rows, and a "Random suffixes" row on the Prices
tab (`Prices:SuffixRows`, each on hover). For a suffixed copy whose item has
suffix readings, `GetLinkValue(link, "rival")` is that suffix's rival or
nil, never the item's mixed one. Sales, Profit and auction house search
rows stay by item: sales are money received, a craft can't pick its roll,
and the game already lists searches by suffix. Tested in
`tools/test_suffixprices.lua`. Not yet seen in game.

## Profession cooldowns

The owner said yes (2026-10-12) to keeping profession cooldowns for every
character. `Logic/Cooldowns.lua` keeps, account wide,
`professionCooldowns[characterKey][id] = { name, group, readyAt, recipeID
or itemID, told }` (never rename it; `id` is `spell:N` or `item:N`): Classic's
cooldown crafts (`Cooldowns.KNOWN`: transmutes, Mooncloth) once the
character's recipes include them, any learned craft the game says is
cooling down (the profession window's harvest calls `Cooldowns:NoteRecipe`
with `C_TradeSkillUI.GetRecipeCooldown`; a cast by the character reads its
spell cooldown a second later), and the Salt Shaker while carried
(`Cooldowns.ITEMS`). Crafts sharing a cooldown show once, by `group` (the
name before the colon). A ready one is said in chat once each time it comes
ready (`told`), at login and from one timer for the next to come ready, and
the Characters tab's detail lists them. "Profession cooldowns" on the Look
page (`cooldownAlerts`, on unless unticked) and `/bts cooldowns`. Butler's
`Jobs()` gives each ready group as a `cooldown` step, and `Butler:Craft`
makes a ready cooldown craft once, queued or not. Tested in
`tools/test_cooldowns.lua` and `tools/test_butlerjobs.lua`. Not yet seen in
game.

## Craft requests in Trade

The owner said yes (2026-10-12) to a word in chat when someone in Trade
asks for something the player's characters make. `Logic/CraftRequests.lua`
listens to `CHAT_MSG_CHANNEL` (Trade by its channel number 2, else a name
with "Trade" or "Handel"): a line with an asking word (`ASK`: LF, WTB,
need, anyone, suche...) and no selling word (`SELL`: WTS, LFW, can make,
tips...) is matched against every character's recipes, by item or enchant
link, else by name (longest first) or an enchant's effect with its slot or
"enchant". It prints "NAME in Trade wants ITEM. You and FULL NAME can make
it." with the asker as a player link to whisper. Reads only, saves
nothing; one asker and item once per `REPEAT_GAP`; the player's own lines
skipped; every read in a pcall (chat can be secret). The names are laid
out again only when the recipe count changes (checked at most every
`REBUILD_GAP`). "Craft requests in Trade" on the Look page
(`tradeRequests`, off unless ticked, the owner 2026-10-12; never rename it) and `/bts requests`.
Tested in `tools/test_craftrequests.lua`. Not yet seen in game.

## Shuffles

A player asked for a shuffle calculator, and the owner said build it
(2026-10-25, from a mockup whose words he approved). The Profit tab's
switch reads MY CRAFTS, YOUR TIME, RECIPES TO LEARN, SHUFFLES (an extra
with `last = true` goes after the learn view in `RecipeBookView.WithSwitch`).
Pick something in the bags ("Start With:", only items some recipe uses) and
"How Many:", and every way to turn it into gold is listed, best gain first:
sell it as it is, or craft it up to `Shuffle.DEPTH` (3) crafts deep and
sell, vendor or disenchant the result. `Logic/Shuffle.lua` works it out a
few steps a frame (`BUDGET`), at most `MAX_NODES` looked at and `MAX_WAYS`
shown, kept `KEEP` seconds, nothing saved. Prices are the usual order:
`Prices:GetValue` (own scans, guild, realm, TSM, Auctionator), auction net
of the cut through `Profit:NetFromListing`, a grey vendor only
(`Util.GetVendorSellPrice`), a disenchant at `Disenchant:GetValue` with the
odds the player's own breaks gave. Other materials a craft needs are bought
(`Cost:GetReagentCost`); a craft with a material nobody prices is left out.
Each step says what stopping there is worth, the best one "Best place to
stop", one worth less than the step before "This step loses gold. Sell
before it." "Only My Recipes" (on, session only) leaves out recipes not
known. Queue It (`Queue:Ensure`, only when every craft is known) and Add to
List (a shopping list named for the start, never doubling a count).
`UI/ShuffleView.lua` draws it (columns `shuffles`). Tested in
`tools/test_shuffle.lua` and `tools/test_shuffleview.lua`. Not yet seen in
game.

## Parts an alt makes, in the profit math

A player asked, the owner said yes (2026-10-24): a part only another of
your characters can make was priced at what buying it costs. With "Alts
Make Sub-Crafts:" ticked (`queueAltCrafting`, the switch that already
hands sub-crafts to alts in `Queue:DeriveAcrossCharacters`),
`Cost:GetCraftCost` prices such a part at the alt's materials plus postage
(`Queue.PostagePerUnit`) when that beats buying, marks it `crafted` with
`madeBy` (the alt's key, `Cost:AltRecipeFor`, `BuildAltIndex`), and the
material lines on the Profit and Level Up tabs and `/bts why` say "made by
NAME" (`Cost.MadeByName`, the whole name). Left at the buying price: a
cooldown craft (`Cooldowns:HasCooldown`: Classic's `KNOWN`, or one any
character was seen waiting on), one in `neverSubCrafts`, a dropped
profession's, an alt this character can't mail, and anything bound when
picked up. The character's own recipe always comes first. Nothing saved.
Tested in `tools/test_altpartcost.lua`.

## Craft next frees bag space first

A player asked (2026-10-14, the owner agreeing) for the queue to craft
what frees the most bag slots first. Only Craft next's pick changes, on the
Queue tab and in the profession window (`Crafting:PickNext`, called by
`GetNextReady` and `CraftPanel:GetNextReadyHere`): of the ready crafts,
the one whose materials stop taking the most stacks, less the new stacks
what it makes takes (`Crafting:SlotsFreed`, from the bags' counts and
`BagsFull.MaxStack`, kept until `Inventory.changes` or `Queue.version`
moves). Ties keep queue order, and a craft waits while a ready sub-craft
of its own (up its `forRecipes` chain) is ready. Bag space only picks within the
first profession group with something ready (below), and the crafts the
player queued come after every sub-craft.

Bars all at once (a player's report, 2026-10-19: forge, anvil, forge):
`Queue:RebuildDependencies` keeps one sub-craft per recipe and crafter
(`MergeSubCrafts`, at the deeper level, `forRecipes` joined), counts what
is held once across levels (`HeldPool`), and lays the sub-crafts out a
profession at a time, the one feeding another first, deepest first within
it (`OrderSubCrafts`, `Queue:ProfessionOf`). Nothing saved changes shape;
sub-crafts are rebuilt as before. Butler's Jobs keeps this order for its
parts. Tested in `tools/test_stationorder.lua`. The stored queue never
moves. The button's tooltip says how many slots it frees. "Craft what frees
bag space first" on the Queue page (`craftFreesSpaceFirst`, on unless
unticked, never rename it). Tested in `tools/test_freespacefirst.lua`.

## Keep in stock by profession

A player asked (2026-10-13, the owner agreeing) for Keep in stock per
profession, and the owner for per item too. `Auctions:GetLimit(itemID)`
answers in three steps and says which: the item's own number
(`postLimits`, set in the Profit tab's detail pane, an x puts it back),
else its profession's (`professionStockLimits[English name]`, account wide,
never rename it; `Auctions:ProfessionOf` from every character's saved
recipes, laid out again when a `recipesCachedAt` moves), else
`maxPostedPerItem`. A profession's 0 is no limit; an empty box is the usual
number. Settings > Queue has a KEEP IN STOCK BY PROFESSION list
(`Auctions:StockProfessions`, `Widgets.CreateNumberBox` with `allowEmpty`);
the Profit tab greys an inherited number and says where it comes from. The
export code carries them as `P<name>:<n>` in its limits section. Tested in
`tools/test_professionstock.lua`. Not yet seen in game.

## Raise Keep in stock when a craft sells out

The owner asked (2026-10-13): when every copy of a craft listed sells
before its listings run out, Keep in stock for that item goes up by 1.
`Logic/SellOut.lua`: a confirmed listing (`Posting:ResolvePending` calls
`SellOut:NotePosted`) opens or joins a window per character and item,
ending when its longest listing would; the poster's next full mailbox
read after that (`Mail:Read` calls `SellOut:MailRead`) settles it: anything
back expired or cancelled since it opened, nothing changes; nothing back
and a sale seen (ledger or heard), `Auctions:SetLimit(item, limit + 1)`,
once a window, with a gold chat line and a sound; no sale seen yet, it
waits. An item with no limit is left alone. Back down (the owner,
2026-10-16, part of the same tick box): every window that comes back
unsold counts (`sellOutUnsold[itemID]`, never rename it), and after
`SellOut.UNSOLD_ROUNDS` (3) in a row the number comes down by 1, never
below where it started (`sellOutRaised[itemID].base`, `own` when that
was the item's own number), and only while it is still the number this
set; a sell out starts the count again. Settings > Queue lists what it
changed under CHANGED WHEN SOLD OUT (`SellOut:Changed`), each with Reset
(`SellOut:Reset`: the item's own number back, or the usual one). "Raise it
when it sells out" on the Queue page (`raiseStockOnSellOut`, off unless
ticked, the owner 2026-10-13). Saved, never renamed: `sellOutWatch[realm][character][itemID]`,
`sellOutRaised[itemID]` (the Profit tab's tooltip on the number) and
`sellOutUnsold[itemID]`.
Tested in `tools/test_sellout.lua`. Not yet seen in game.

## Your auctions and undercuts

A player asked (2026-10-14, the owner said build it, from a mockup) for an
Auctions switch in the auction house drawer beside Sell and Buy:
`UI/AuctionsView.lua` draws it inside `UI/PostPanel.lua`, and
`Logic/MyAuctions.lua` works it out. It lists the auctions you have up
(`Auctions.live`, kept for the session by `Auctions:ReadOwned` with each
auction's ID; nothing new is saved), then other characters' as last read
(`Auctions:GetListings`, dimmed, never cancellable here). Undercut means
your price for one is above the cheapest listing not yours
(`Prices:GetScanValue(id, "rival")`) from a scan no older than
`MyAuctions.FRESH` (an hour); older says Unknown. Undercut ones come first
with a red edge and a Cancel button; the switch shows their count in red.
`MyAuctions:Cancel` calls `C_AuctionHouse.CancelAuction` straight from a
click, one auction a click (the game wants a click each; never queue or
loop it), refuses at a busy or closed auction house, and is read back:
gone means cancelled ("comes back in the mail"), still up after
`CANCEL_WAIT` means it did not go through. Each row says about what
listing it again costs (`GetCancelCost`, else the remembered deposit) and
warns when that is more than the gap. Cancel next at the foot takes the
one with the most money under. `/bts probe` has a "cancel auctions" line.
Tested in `tools/test_myauctions.lua`. Not yet seen in game.

Places in line (a player asked, the owner said build it from a mockup,
2026-10-20): "Cheapest" says nothing about auctions at your price listed
before yours, which sell first. Every item or commodity search that comes
back for an item you have up (the addon's, the player's own, or **Check
Places** at the foot, `MyAuctions:CheckPlaces`, one item and suffix at a
time at background priority, through each live auction's `itemKey`) is read
once more (`MyAuctions:NoteItemPlaces`, `NoteCommodityPlaces`, called first
in the Scanner's two search handlers): an item auction keeps how many
others at its price and suffix come before it (`MyAuctions.places`), a
commodity how many of others' units share its price (`MyAuctions.more`).
Session only, nothing saved, shown while under `FRESH`. A cheapest row then
ends its line with amber "34 ahead of you", green "First in line" or amber
"480 more at your price"; with others ahead (`row.behind`) it sorts first
among the cheapest, its "Cheapest" is amber and it gets Cancel. Cancel next
stays undercut only. Tested in `tools/test_auctionplaces.lua`. Not yet
seen in game.

## Can afford

A player asked, the owner said build it (2026-10-22): the Level Up tab
says when a craft's missing materials cost more than the gold on hand,
and can leave those out. `LevelUp.ToBuy(costDetail)` adds each reagent's
`shortfall` (bags and bank count as owned) times its `unitCost`; each row
carries it as `toBuy`. `LevelUp:ShortNote(row)` gives "You need about X
to buy what's missing. You have Y." in red on the row's hover and the
detail panel. "Can afford" in the toolbar (`levelUpCanAfford`, account
wide, off unless ticked, never rename it) passes `canAfford` to
`GetRanked`, which drops rows the purse (`GetMoney`) can't cover; Learn
Next and Road to 300 are unchanged. `PLAYER_MONEY` redraws the shown
list 0.3 s later. Butler's Cheapest Skill-Up follows the same box. Tested
in `tools/test_canafford.lua`.

## Legacy perks, read only

The owner said build it (2026-10-22): Forever's Legacy is a C_Traits
config (the spell "Legacy System - Create Trait Config"), and Tradeskills
reads what the player spent, never more. `Logic/Legacy.lua` finds the
config a slice a frame, 10 s after login and again after a trait event
(trait system IDs, then tree IDs; class talents never count; a config
named Legacy or holding a node in `NODE_FIRST` to `NODE_LAST`, 110284 to
110319, not confirmed), and reads each node's rank through
`C_Traits.GetNodeInfo`, every call in a pcall. It never buys a rank,
commits a config or suggests a build (the owner: "we just read what they
have set"). Master Chef (found by its English name, or
`MASTER_CHEF_NODE` once a probe shows its ID) raises a cooking recipe's
yield in `Cost:GetCraftCost` by up to `MASTER_CHEF_MOST` (50% at its last
rank), only for a recipe the character playing knows, so the Profit tab
follows it. Bartering needs nothing: vendor prices come from the real
merchant window. Nothing read, nothing changes. Nothing is saved and no
player words are new. `/bts probe` has "legacy" lines (the config, points
left, each node's rank, Master Chef's yield, currencies 3485 and 3499).
Tested in `tools/test_legacy.lua`. Not yet seen in game.

## Learn next

The owner said build it (2026-10-12), from a mockup he picked
(`mockups/tradeskills-learn-next-mockup.png` in the project files, Show
the way buttons in one column). The Level Up tab's own list goes on past
what the character knows: under a LEARN NEXT heading, the recipes they
have not learned that a trainer or vendor teaches and that raise the skill
now, cheapest way up first, then any a few points out of reach
(`LearnNext.REACH`), greyed, "At 120". `Logic/LearnNext.lua` builds the
rows (`GetRows`, `Place` picks a trainer or vendor of the player's side
that teaches that far: the nearest on the continent the character is on,
by where the game saw it stand else Classic's spot (`Nearest`, `Closest`,
2026-10-27: Road to 300 sent a player in The Barrens to Undercity), else
the zone they are in, then a city; `TrainerFor` picks the same way);
`UI/Tab_LevelUp.lua` adds the LEARN, WHERE and Show the way columns (shown
only while "Learn next" is ticked, `levelUpLearnNext`, on unless unticked,
never rename it) and a detail pane with Show the way and Queue materials
(enough to craft until it turns yellow, `Queue:EnsureBuy`). Show the way
(`LearnNext:ShowTheWay`, also a right-click on the row) puts the game's
own map pin on them, or hands TomTom the place when it is installed
(`Logic/Waypoints.lua`, Equipment's trimmed to the pin), and says where in
chat; `/bts probe` has a "show the way" line.

`Data/LearnSpots.lua` is generated by `tools/make_learn_spots.py`, never
by hand: Forever's own skill to learn, yellow and grey for each recipe
(the client tables give yellow and grey; the skill to learn is Classic's
moved as much as the yellow moved), the trainers of each profession with
the highest skill they teach, and the spots of the vendors
`Data/RecipeBook.lua` names. `RecipeBook:GetAll` lays those skills over
the book (keeping Classic's as `classicSkill`); players' reports and a
recipe item's tooltip still win. Never name where the data came from in
the repo. Tested in `tools/test_learnnext.lua`. Not yet seen in game.

## Show the way across zones and the sea

The owner said build it (2026-10-21, from a mockup) in every addon: with
"Guide Me:" ticked on the Look page (`arrowRoute`, account wide, on
unless unticked, never rename it), the arrow below leads to a trainer or
vendor in another zone or across the sea step by step (flights this
character knows, the boats and zeppelins of its side, its Hearthstone,
walks through the zones between). Without the arrow (no map for the
place) Learn next's Show the way lists the steps in chat and pins the
first stop (`LearnNext.Guide`, `Travel:Guide`). `Logic/Travel.lua`,
`Data/Travel.lua`, `Data/TravelZones.lua`, `UI/TravelCard.lua`,
`UI/TravelMap.lua`, `Media/Frame/TravelDot.tga` and the two
`tools/make_travel*.py` are Farmer's, the same in every addon (a fix to
one belongs in all; Farmer's `CLAUDE.md` has the details). It reads the
flights, crossings and Hearthstone spot the other addons saved. Tested in
`tools/test_learnnext.lua`. Not yet seen in game.

## The arrow

The owner asked (2026-10-22) for Tradeskills and Butler to guide as the
other addons do: the arrow when they point at an NPC or a place, and the
same TomTom choice. `Logic/WayArrow.lua` and `UI/WayArrow.lua` are the
house dial (Farmer's `Logic/Arrow.lua` and `UI/Arrow.lua`, by way of
Butler's copy; `tools/make_arrow_art.py` draws the same `Media/Arrow/*.tga`),
with `ns.TravelHost` at the end of `Logic/WayArrow.lua`. `WayArrow:AimAt
(place, title)` (place `{ zone or mapID, x, y }`, 0 to 100; false when no
map is found) is called first by Learn next's Show the way
(`LearnNext:ShowTheWay`) and a vendor pin's click (`VendorPins:ShowTheWay`),
which print "The arrow shows the way to NAME (WHAT)."; the old pin is the
fallback. The arrow shows only while a place is set
(`charDb.wayArrowPlace`, per character; its spot `wayArrowX`/`wayArrowY`,
account wide), and goes with its close gem or when a trainer or vendor
window opens on arrival (`WayArrow:Reached`). The dial takes no clicks and shows no hover text (the owner,
2026-10-23): drag moves it and the red gem closes it. It joins the one-arrow rule
(`_G.BlackthornesArrows`, as "Tradeskills"). `Logic/TomTom.lua` is the
shared TomTom file: "Use TomTom:" on the Look page (`useTomTom`, account
wide, on unless unticked, never rename it) hands TomTom the place
instead. Never rename `wayArrowPlace`, `wayArrowX` or `wayArrowY`. Tested
in `tools/test_learnnext.lua`. Not yet seen in game.

## Road to 300

The owner said build it (2026-10-20, from a mockup whose words he
approved): the Level Up tab's switch reads Next Point (the tab's own
list), Road to 300 and Learn Next (the recipes to learn;
`RecipeBookView.WithSwitch` takes `learnText`). `Logic/RoadPlan.lua` lays
out the whole way to 300 for one profession: from the skill now, each
stretch takes the recipe cheapest a point, known or taught by a trainer
or vendor of the player's side (`RoadPlan:Candidates`, `LearnNext:Place`);
a step is one recipe in one colour, "every craft" while orange, "most
crafts" while yellow, "some crafts" once green (halfway from yellow to
grey, `RoadPlan.Tier`), its crafts 1 over the chance (`RoadPlan.Chance`: 1
below yellow, (grey - skill) / (grey - yellow) up to grey). Trainer steps
sit at Classic's ranks (`RoadPlan.RANKS`: Journeyman at 50 to 150 and
level 10, Expert at 125 to 225 and level 20, Artisan at 200 to 300 and
level 35), with "You're level N." while the level is short
(`LearnNext:TrainerFor` names the nearest trainer). What the bags, then
the bank hold comes off once across the steps, and the footer says how
much ("To 300:", "What you own already takes off X."). Steps below the
skill are done and sit at the foot of the list (`RoadPlan.Shown`; "Step N
of M", the meter and Queue All keep the plan's order). Queue Step queues a known recipe's crafts
(`Queue:Ensure`) or puts a recipe still to learn's materials on the list
to buy (`Queue:EnsureBuy`); Queue All does every step left; Show the Way
is `LearnNext:ShowTheWay`. `UI/RoadView.lua` draws it (a profession
picker, the heading with the skill, "Step N of M" and a meter, dark glass
rows, the step to do now `glassActive`). The plan is worked out only
while the view shows, its prices a few recipes a frame
(`RoadPlan.BUDGET`), and kept until its key moves (skill, cap, level,
recipes, `Inventory.changes`, `Prices.scanCount`, `Queue.version`).
Nothing new is saved. Cooking and First Aid stop at their last rank.
Tested in `tools/test_roadto300.lua`. Not yet seen in game.

## Welcome card

The owner said build it (2026-10-20, from the same mockup): the first
time the window opens on a character, a card ("Welcome", the house frame)
asks which of its professions to level, each ticked with its skill. Show
My Road keeps the ticked ones and opens Road to 300 on the first
(`LevelUpTab.ShowRoad`); Not Now closes it. Either way it never comes back
by itself (`Welcome:Due`, asked from `UI:Show`); "Road to 300:" on the
Look page of Settings opens it again (`WelcomeUI:Show`). It changes no
setting: the picks only put those roads first in the picker
(`RoadPlan:Professions`). `Logic/Welcome.lua` keeps, per character in
`BlackthornesTSCharDB`, `welcomeSeen` and `roadPicks` (Classic skill
lines in order); never rename either. `UI/Welcome.lua` draws it. Tested
in `tools/test_welcome.lua`. Not yet seen in game.

## Vendor map pins

A player asked (2026-10-18, the owner said build it, from a mockup with
the words he approved): gold pins on the world map at vendors that sell a
material the queue still needs for less than the auction house, or that
nobody lists there. Only the world map, for the map it shows; only
vendors of the player's side or of neither; gone once there are enough
(the shopping list's shortfall). Not for an item set to Buy on the Level
Up tab. `Logic/VendorPins.lua` picks them (`Wanted`, `For(mapID)`),
`UI/VendorPins.lua` draws them on the map's canvas (a key, redrawn only
when the map, zoom, queue, bags, a scan or a learned vendor moved). The
hover names the vendor, "Has what your queue needs:", each item with how
many and the cost, "Saves you X over the auction house." and "Click to set
a map pin." (or "Click for a TomTom arrow."); a click is
`Waypoints:Pin`/`TomTom`, which now take a `mapID` in place of a zone.
The look (the owner said build it, 2026-10-19, from a mockup): a gold rim
round a bag with a gem on top and a glow that breathes (an animation the
game loops, Window effects Full only), a gold badge with how many queue
items, names under the pins only zoomed in or with `NAMES_MOST` (4) or
fewer, the vendors that save less `SMALL` the size, and a beam under the
one a click pinned (`VendorPins.pinned`); `VendorPinsUI.Looks` works it
out. The hover is our own card (`ShowCard`: gold rim, dark glass rows,
rarity and coin colours), on UIParent, never GameTooltip.
Where vendors stand: `Data/VendorSpots.lua` (`ns.VENDOR_SPOTS`, Classic's
vendors of the items in `Data/VendorPrices.lua` that never run out, by
`tools/make_vendor_spots.py <quest database>`, never by hand), and every
vendor the player opens (`VendorPins:Learn` from `Vendor:Scan`: NPC ID,
map and spot, side, and its materials with whether they run out), kept
account wide in `vendorSpots[npcID]` (never rename it; at most
`MOST_VENDORS`). A learned vendor takes its shipped place; one whose stock
runs out is pinned only while the auction house has none. Butler's Buy
from a vendor row still does the buying. "Vendor Map Pins:" under AT
VENDORS on the Mail & Vendors page (`vendorMapPins`, off unless ticked,
never rename it) and `/bts vendorpins on|off`. Tested in
`tools/test_vendorpins.lua`. Not yet seen in game.

Where the game saw it wins (the owner, 2026-10-22, after a player's Show
the way led to a recipe vendor's Classic spot; his rule for every addon):
a spot seen in game always beats Classic's listed one. `Vendor:Scan`
keeps recipe-only vendors too, and a trainer's window keeps where it
stands (`VendorPins:LearnTrainer` on `TRAINER_SHOW`, account wide in
`trainerSpots[npcID] = { name, mapID, x, y, side, at }`, never rename
it). Between them and Classic sit the shipped Forever spots,
`Data/ForeverVendorSpots.lua` (`ns.FOREVER_VENDOR_SPOTS`,
`ns.FOREVER_TRAINER_SPOTS`), written by `tools/forever_vendor_spots.py
<save>` from only those two tables of the owner's save (never when it was
seen), keeping what is shipped; never by hand, and run at each release
with the other fold-ins, never announced. `VendorPins:SeenAt(name, zone,
kind)` (by name, any case, on the zone's map when known) is what Learn
next's `Place` reads first, so Show the way, the arrow and Equipment's
`WhereFor` follow; `VendorPins:Known` lays the shipped spots under the
player's own for the map pins. Tested in `tools/test_vendorpins.lua`,
`tools/test_learnnext.lua` and `tools/test_forever_vendor_spots.py`.

## Sealed writs

The owner said build it (2026-10-19): mobs drop a Sealed Journeyman's or
Expert's Writ, and tearing it open gives one Craftsman's Writ, so the
addon learns what each opens into. `Writs:NoteOpenings` (from `OnBags`):
a sealed writ (`Writs.IsSealedName`, "Sealed ... Writ") leaving the bags
and a Craftsman's Writ coming in within `MATCH_SECONDS` is one opening,
kept account wide in `merchantsFavor.sealedWrits[sealedID] = { opens,
writs = { [item the writ asks for] = count }, name, at }` (never rename
it). The item tooltip (`ItemTooltip:AddSealedLines`, `Writs:SealedInfo`)
says "You opened N", up to five writs with "3 of 6" and "Writ inside
worth about" once every writ it gave has a price; a writ row's tooltip
on the Writs view says "Came from NAME: 3 of 6" (`Writs:SealedSources`).
Nothing is opened for the player. Tested in `tools/test_writs.lua` and
`tools/test_itemtooltip.lua`. Not yet seen in game.

Coin bags (the owner said build it, 2026-10-24, after a player noticed
each rank's bag shares one item ID): an item that comes into the bags
with a learned turn-in is that level's bag, account wide in
`merchantsFavor.writBags[tier] = { [itemID] = time }`; one leaving the
bags with money coming in within `MATCH_SECONDS`, never at a vendor,
mailbox, auction house or trade, is an opening, kept in
`merchantsFavor.coinBags[itemID] = { opens, copper, at }` (never rename
either). `Writs:BagWorth(tier)`, the average, is added to `GetReward`'s
money, so it comes off a turn-in's cost and shows as Money back. No new
words. Tested in `tools/test_writs.lua`. Not yet seen in game.

## The favor goal

The owner said build it (2026-10-20, from a mockup): a Merchant's Favor
goal on the Favors and Writs tab. "Favor Goal:" takes a number
(`favorGoal`, nil for none, never rename it; `MerchantsFavor.Goal`,
`SetGoal`). `MerchantsFavor:GetPlan` works out the cheapest way there
from the first priced row of `GetRows` (crates and bundles held come off
the gold), `FavorHave` reads the favor (its currency by ID once seen,
`favorCurrency`, else its item, `favorItem`, else the currency list by
name), and `Steps` lays it out a crate and a bundle at a time. The strip
(`UI/DealsFavor.lua`) shows a gold bar with tenth ticks, You Have, Still
to go, Cheapest way and Gold to get there; Add to a List fills a list
named Merchant's Favor (`AddToList`, set, never doubled). `CheckGoal`
chimes each new tenth and cheers the goal with the game's own sounds by
ID; the first look only notes where it stands. A crate's tooltip shows
what it costs and pays (`ItemTooltip:AddCrateLines`, `RowForItem`;
"Crate Costs:" on the Look page, Off, Shift or Always, `tooltipCrateCosts`
on unless unticked and `tooltipCrateShift`, never rename either). While a
goal is set the auction house drawer has a Favors switch
(`UI/FavorsView.lua`, `PostPanel:LayTabs`): the steps, and Buy Next buys
one listing a click (a crate by a search, a bundle by
`StartCommoditiesPurchase`, then Pay with the game's total); a buy is
counted until the bags or bank show it (`FavorsView.bought`). Nothing is
bought without the player's click. Tested in `tools/test_favorgoal.lua`.
Not yet seen in game.

## Recipes Forever added

The owner (2026-10-17): "always add new recipe finds to tradeskills".
`Data/ForeverRecipes.lua` is written by `tools/make_forever_recipes.py
<tables folder> --build <build>` from the Forever client's game tables
(SkillLineAbility, SpellName, SpellEffect, SpellReagents, Item,
ItemEffect, ItemXItemEffect, ItemSparse); never edit it by hand, never
commit the tables or name where they came from. It lays every profession
recipe in Forever's own spell range (`FOREVER_FIRST`, 1,000,000 and up;
below are other Classic seasons' leftovers) that the book lacks into
`ns.RECIPE_BOOK`, in the book's row shape with `f = 1` and `y`/`g` for
yellow and grey, and its recipe items with their vendor price. So they
show among the recipes to learn and on enchant tooltips before anyone
opens a profession window; a window's own recipe still wins. They are
never matched to a Classic recipe by what they make or their name
(`record.forever`). Where to learn most is not known, so Learn next
leaves them out, and Recipes to learn says "New on Forever". **Rerun it
whenever the client tables are pulled again** (the Saturday check), and
after `make_recipe_book.py`. Tested in `tools/test_foreverrecipes.lua`.

## Sales details on the item tooltip

A player asked (2026-10-13, the owner agreeing, from a mockup) for more
under the tooltip's Demand line. `ItemTooltip:AddDemandLines` adds "Sold
a day" (`Prices:GetUnitsSoldPerDay`, listings gone per day from the kept
readings, an estimate and said so), "Listed now" (the last scan's count
and its age), "Last 7 days" (inline bars from `Prices:GetDailySales` and a
trend once four whole days were scanned) and "You sold" (`Demand:Week`,
this week's sales and expiries from the ledger). Each price record keeps
`daily` for it (`Prices.NoteDaily`; never rename it). "Sales Details:" on
the Look page, Shift or Always (`tooltipSalesShift`, true for Shift, off
unless picked, never rename it; see "Off, Shift or Always on tooltips"). Tested in `tools/test_tooltipsales.lua`. Not yet seen in
game; the bars are the game's inline texture escape.

## The Stats tab

The owner asked (2026-10-14, from a mockup) for a tab like Farmer's
Stats tab, one item at a time. `UI/Tab_Stats.lua` (order 9, after
Prices) lists what you craft, star and sell (sold most in 30 days first;
a search finds any priced item by its saved name) and draws the picked
item: four numbers (worth now against a week ago, profit each, sold a
day, you sold this week), the price graph, then cards: cheapest times
by day and hour, where each sale goes, your listings, sales by week
(the best week lit, cheered once a week with a sound, "Best week of
sales", `statsCheer`, on unless unticked), listed at each scan, price by
source, the last 90 days, who else sells it, how fast yours sell and
the last 30 days by method. `Logic/ItemStats.lua` builds it (each part
in a pcall), only while the tab shows and again only when
`ItemStats:Key` moves, a moment after. `Data/StatsLog.lua` keeps what
nothing else did, for tracked items only (`PriceHistory:IsTracked`),
per realm, never renamed: `statsDays` (day, cheapest, sold; 90 days,
from `Prices:Record`), `statsSellers` (how many sell it and the shares,
from `CommitScan` with the full scan's `seller`; never a name),
`statsPosts` and `statsSellTimes` (your postings from `Posting`, timed
when the mail ledger writes the sale) and `statsCheered`. `/bts stats
[item]`, a Settings row on the Look page and a Stats button on the
Prices tab's detail pane open it. The Sold a day tile shows demand as the
market's numbers, not High, Some or Low (a player asked, 2026-10-16):
"18% of stock sells a day" with a bar coloured by `Demand.MarketLevel`, and
a hover (`StatsUI.MarketLines`) with sells a day, up for sale now, time to
sell what's up and your own listings, all from `stats.market`
(`ItemStats` `Market`). Tested in `tools/test_itemstats.lua`.

## Enchant costs on tooltips

A player asked (2026-10-14, the owner agreeing) for an enchant's material
cost on its tooltip. `UI/EnchantTooltip.lua` hooks spell tooltips
(`TooltipDataProcessor` for Spell and RecipeRankInfo, `OnTooltipSetSpell`,
and ItemRefTooltip's `SetHyperlink` for a linked enchant; the other
setters only when neither hook took). A recipe's ID is its spell ID, so an
Enchanting recipe that makes no item (`EnchantTooltip:RecipeFor`: a known
recipe first, else the book's, read only once `RecipeBook.merged` is built)
gets Materials with its total, each material's cost (`Cost:GetCraftCost`
with `valueOwned`, so the usual price order), You're short (bags and bank)
and Known by. Lines are kept per spell until `Inventory.changes` moves or
`KEEP_FOR` passes. "Enchant costs on tooltips" on the Look page
(`tooltipEnchantCosts`, on unless unticked, never rename it); `/bts tip`
counts them. Tested in `tools/test_enchanttooltip.lua`.

## Off, Shift or Always on tooltips

A player asked (2026-10-18, the owner said yes): each tooltip line
Tradeskills adds can be Off, Shift (only while Shift is held) or Always.
`UI/TooltipShift.lua` is the same file in all five addons (a fix to it
belongs in all five); nobody's settings change, so a line that was on
reads Always and one that was off reads Off. Whether a line is on stays in
its own setting; Tradeskills keeps the Shift choice in Config (it sets
`TooltipShift.Read`/`Write` in `UI/ItemTooltip.lua`, `ItemTooltip.SHIFT_SETTINGS`):
`value` (`showValueOnItemTooltips`, every value line, Shift in
`tooltipValueShift`), `sales` (the sales lines under Demand, no Off: their
Shift is the old `tooltipSalesShift`), `trend` (`tooltipTrend`,
`tooltipTrendShift`), `recipe` (`showRecipeValueOnTooltips`,
`tooltipRecipeShift`) and `enchant` (`tooltipEnchantCosts`,
`tooltipEnchantShift`; asked when the lines are written, never kept in
`EnchantTooltip`'s cache). Never rename any of them. A line held back adds
"Hold Shift for more." once a tooltip (`TooltipShift:Held`), and the shared
frame redraws GameTooltip when Shift moves, only while a line is on Shift.
Dropdowns on the Look page (`ShiftDropdown`, `ShowShiftMode` in
`UI/Tab_Settings.lua`); the row once "Sales Details on Shift:" is "Sales
Details:". Tested in `tools/test_tooltipshift.lua`. Not yet seen in game.

## Find a material

A player asked (2026-10-16, the owner said build it, from a mockup) what
to break, make or farm for the best odds at one enchanting material, and
what had given it before. The Disenchanting tab's "Find a material" tick
box (at the toolbar's right end; the other views' tick boxes step aside)
and a material picker show it, under headings: YOU'VE GOTTEN IT FROM
(your own disenchants, `DisenchantLog`, with "You made it" or "Looted,
MOB"), BREAK WHAT YOU HAVE, BUY AND BREAK, MAKE AND BREAK (crafts this
character knows; Queue one) and FARM AND BREAK (Farmer's own kills;
Show in Farmer). Columns COST EACH (price over how many one gives on
average), ODDS and WHERE (`disenchantmaterial`). `Logic/MaterialFinder.lua`
works it out from the tab's own rows (`GetBagRows`, `GetAuctionRows`,
`GetCraftRows`; a row keeps its `source`, so a bag or auction row's detail
is the usual one), kept per material until the bags, prices, queue,
recipes or disenchants move or `KEEP` passes. Nothing is saved; the
material picked lasts the session (`FirstPick`: the best your disenchants
have given). Farmer is asked inside a pcall, read only:

```lua
_G.BlackthornesFarmer.DisenchantFarm:Best(gives, max)   -- gives(itemID): how many one gives
  -- { { mob, zone, shownZone, kills, perKill, seconds, perHour, items = { { id, name, corpses } } } }
_G.BlackthornesFarmer.DisenchantFarm:DroppedBy(itemID)  -- the mob that dropped it most, or nil
_G.BlackthornesFarmer.DisenchantFarm:Show(mob)          -- opens its loot table
```

Without Farmer the farm heading and "Looted" are left out. Tested in
`tools/test_materialfinder.lua`. Not yet seen in game.

## The Characters tab by side

The owner asked (2026-10-16, from a mockup) for the Characters tab to split
Horde from Alliance and show more about each character. `UI/Tab_Characters.lua`
is one full-width table: a heading row per side (the side playing first,
then the other, then OTHER for a record saved before its side was kept)
with how many, their gold and time played; a click folds it. Columns
CHARACTER (class colour, race and class under it), LEVEL (purple XP bar),
RESTED (blue bar, Full at 150%), GOLD, PROFESSIONS (two, then "+N"), MAIL
(items waiting), ZONE, PLAYED and LAST SEEN, each sortable within its side
and hideable (`ns.Columns` list "characters"). Realm: (a player asked,
the owner said yes 2026-10-18) is first on the bar: This Realm (the
default, the realm of the character playing; a character saved with no
realm stays under it), All Realms, then each realm by name, matched
without case or spaces. Realm, Show: Both, Horde, Alliance and the search
(name, profession, zone) last the session. A click on a
character opens a line under it with its best crafts, cooldowns, bags and
bank age, and Forget character (arms first, never the one playing). The
Bank view is unchanged.

`Logic/CharacterNotes.lua` keeps what it shows on the character's own
record in `characters[guid]`, only once the GUID is known: `race`,
`classFile`, `xp`, `xpMax`, `restXP`, `resting`, `zone`, `played` and
`seenAt` (never rename them). Played time is asked of the game
(`RequestTimePlayed`, which prints in chat) once, for a character never
read, and counted on from there. Rested for a character not playing grows
by Classic's rule from when it was last seen (`CharacterNotes.Rested`,
marked a guess in the row's tooltip). `Recipes:AddNotes` gives them to
`GetCharacters`, and AccountLink carries them for the other account's
characters. Tested in `tools/test_characternotes.lua` and
`tools/test_uifit.lua`. Not yet seen in game.

## Profit by method

A player asked (2026-10-11, the owner agreeing) for profit split by how it
was made. The Sales tab's **Profit by method** view (`Logic/MethodProfit.lua`,
a Period menu like Gold in and out) lists Crafted, Flipped, Vendored,
Disenchanted and Other sales, each with its items beneath. Auction sales are
read from the mail ledger: a stamped `entry.cost` is crafted, or flipped
when `entry.bought` (the average paid on the auction house, stamped in
`Mail:Describe` from `MethodProfit:BuyCost`). Vendor sales come from the
buyback list (`Vendor:ReadBuyback` hands it to `MethodProfit:NoteBuyback`;
the first look of a visit is the baseline) and disenchants from
`DisenchantLog:Record`; both are kept per realm in `methodLog[realm].events`
(never rename it), and `AHBuys:NoteCost` keeps what was paid in
`methodLog[realm].buys`. An item with no cost known counts as all profit and
the panel says how many. Tested in `tools/test_methodprofit.lua`. Not yet
seen in game.

Farmed (the owner said build it, 2026-10-16): an auction sale with no cost
known goes under Farmed, not Other sales, when Blackthornes Farmer says
you looted, gathered or fished it yourself (`MethodProfit:Farmed`, asked
once an item per Summary, inside a pcall, read only):

```lua
_G.BlackthornesFarmer.Looted:Has(itemID)   -- true or false; its own records only
```

Without Farmer it stays Other sales. If Farmer changes the call, change
`MethodProfit:Farmed` too.

## What the other addons want kept (the Sell list)

The owner said build it (2026-10-16): the auction house drawer's Sell list
and List all used to offer the whole bag, holding back only what the craft
queue needs. `Logic/SisterKeeps.lua` asks the sisters what they would keep,
through the calls they already make for Butler, inside a pcall, read only:

```lua
_G.BlackthornesFarmer.Butler:Advise(itemID)             -- a goal: up to its target
_G.BlackthornesFarmer.Value:Contents(name)              -- a clam worth more opened
_G.BlackthornesEquipment.Butler:Advise(link, bag, slot) -- upgrade, alt, tool
_G.BlackthornesPets.Butler:Advise(itemID)               -- eats (not buff food)
_G.BlackthornesButler.Verdicts:Choice(itemID)           -- keep, bank, mail
_G.BlackthornesButler.Verdicts:InSet(itemID)            -- an equipment set
_G.BlackthornesButler.Quests:Reason(itemID)             -- an open quest
```

`Posting:GetPostable` takes off what is held (`line.kept`, `keptWhy`); one
held whole is left out, or with `showHeld` (the drawer) kept as a dimmed
row whose detail is why (`line.held`), its own List button still working.
`GetNextPostable` and `GetSummary` never pick a held line, so List all and
Post Crafted never post one; the drawer's summary counts them. Answers are
kept per bag copy until `Inventory.changes` moves or `KEEP` seconds pass. An upgrade
(for you or, ticked, an alt) is held only as many copies as a character
wears, one or two rings or trinkets (`SisterKeeps.Wears`, 2026-10-18); the
spares sell, as Butler's own window says.
"Keep What Other Addons Need" on the Pricing page (`sellHoldsSisterKeeps`,
off unless ticked since the owner asked the same day; `Config:SisterKeepsOffOnce`
turned off the true the first default saved, once, `sisterKeepsOffOnce`;
never rename either). Gear Equipment calls an upgrade
for another character (its `alt`) is held only while "Keep Upgrades for
Alts" is ticked (`sellHoldsAltUpgrades`, off unless ticked, the owner
2026-10-16, never rename it). Tested in
`tools/test_sisterkeeps.lua`. If a sister changes a call, change this file
too. Not yet seen in game.

Also from the sisters (2026-10-16): the Gather tab's tooltip says how fast
you farm a material and how long the rest would take (`CraftOrFarm:PaceOf`,
the Your time view's Farmer call), and crafted gear that's an upgrade for
another of your characters says so after its name on the Profit, Level Up
and Queue tabs (`Upgrades:AltFor`, `AltText`, `WithAltText`, from
Equipment's `Butler:Advise` `alt`; off with the upgrade arrows; tested in
`tools/test_altupgradecrafts.lua`). Those lines show only while "Show
Equipment Upgrades" is ticked (the owner, 2026-10-17): a box at the right
of the Profit and Level Up switch rows (`spec.corner` in
`RecipeBookView.WithSwitch`) and after the Queue's heading, all one saved
value (`showAltUpgrades`, off unless ticked, never rename it;
`Upgrades:ShowsAlts`, `SetShowsAlts`, `CreateAltCheckbox`), shown only
while Equipment is loaded.

## Keep on this character

A player asked (2026-10-18, the owner said build it, "bigger number"):
the Sell list's x hides an item on every character, so there was no way
to keep a few potions on one character and sell the rest on another.
Right-click a row on the Sell list (`UI/KeepBox.lua`, the house frame,
Save and Keep All) to keep a number of it on the character playing;
Settings, Queue page, KEEP ON THIS CHARACTER lists them with Clear.
`Logic/KeepHere.lua` keeps them account wide by GUID,
`keepOnCharacter[GUID] = { [itemID] = count }` (never rename it; a
character whose GUID isn't known reads and writes nothing; 9999,
`KeepHere.MOST`, is Keep All). `SisterKeeps`' keep-here hold takes the
bigger of this number and Butler's own (its `KeepHere:Count`), ticked or
not, and Butler reads this one back the same way, inside a pcall, read
only:

```lua
_G.BlackthornesTS.KeepHere:Count(itemID)   -- how many to keep here, or nil
_G.BlackthornesTS.KeepHere.IsAll(count)    -- true for Keep All
```

Keep both stable; if one changes, change Butler's `Logic/KeepHere.lua`
too. Tested in `tools/test_sisterkeeps.lua`. Not yet seen in game.

## Goblin Gold

The owner said build it (2026-10-17, from a mockup): a small bar on
screen with the gold on every character of this realm and side, and a
goal cheered a tenth at a time. Off unless ticked. `Logic/GoldGoal.lua`
adds it up from `ns.db.characters` (the character playing at `GetMoney`,
the rest as last seen, one character under two records once through
`Characters:Same`, the other account's characters counted; guild data
never), keeps the goal in `goldGoals[realmKey] = { goal, setAt, best,
reachedAt }` (never rename it) and cheers once each time `best`, the
highest tenth reached, moves (a goal starts at the tenth you are on, so
a dip and a climb back cheers nothing). A cheer waits while you fight,
at the auction house or with a game panel open (`GoldGoal:Busy`).
Today, this week, the best day and where most of it came from are
`GoldLog`'s, gold moved between your characters left out; new gold
floats up off the bar from `GoldLog:Record` (`GoldGoal:OnRecord`), never
a transfer. `UI/GoldGoal.lua` draws it: the total counting up, a fill
with lit ticks, coins and a line at each tenth, a window at the goal with
how long it took and a box for the next, the hover card listing every
character in dark glass, drag to move, its own size grip. Sounds are the
game's own by ID. Settings, Look page, GOBLIN GOLD ("Gold Tracker:",
"Gold Goal:", "Gold Tracker Place:") and "Goblin Gold:" under SOUNDS;
`/bts gold [on|off|goal N|reset]`, and `/bts gold test [goal|float]`
(typed only, not in the help line) shows a cheer without saving anything.
Saved, account wide, never renamed: `goldTracker` (off unless ticked), `goldTrackerSound`,
`goldTrackerScale`, `goldTrackerX`, `goldTrackerY`. "Count Gold On:" (a player asked,
the owner said build it, 2026-10-21) picks All Characters or This
Character (`goldTrackerCount`, "all" unless picked, never rename it):
counting one character, `GoldGoal:Members` keeps only the one playing and
its goal is its own, by GUID in `goldGoalCharacters[guid]` (the same
fields; never rename it), so the realm's goal stays as it was. Today,
this week and the sources stay the realm's, since `GoldLog` is per realm. Like every cheer, it
is never announced. Tested in `tools/test_goldgoal.lua`. Not yet seen in
game.

Where the gold came from (the owner said build it, 2026-10-20, from a
mockup whose words he approved): the hover card ends with THIS WEEK
(Quests with how many were handed in and gold each, Mobs with kills and
gold each counting their loot, "Their loot is worth", Auction sales and
Vendor sales) and ALL TIME (Quests done, Mobs killed, Gold from quests,
Gold looted). `GoldGoal:Sources` reads `GoldLog`'s week by source,
`GoldLog:QuestsDone` (every hand-in counted from this update, in
`goldLog[realm].questsDone[YYYYMMDD]`, never rename it) and the game's
Statistics (`GoldGoal.STATISTICS`, `GoldGoal.Statistic`: a statistic the
client does not give is left out; `/bts probe` has a "statistics" line).
Kills and loot worth are Blackthornes Farmer's, inside a pcall, read only:

```lua
_G.BlackthornesFarmer.Stats:KillsAndLoot(7)   -- { kills, loot, coin } over the last 7 days
```

Without Farmer the Mobs row is its gold alone. If the call changes, change
`GoldGoal:Sources` too. `UI/GoldGoal.lua`'s `GoldGoalUI.SourceLines`
builds the rows. Tested in `tools/test_goldsources.lua` and
`tools/test_goldlog.lua`.

## The public price API

The owner said yes (2026-10-12) to a documented price call for other
authors' addons. `Logic/PublicAPI.lua` sets `_G.BlackthornesTS_API` with
`version` (1), `GetPrice(item)` (`Prices:GetValue(id, "market")`, copper or
nil) and `GetPriceAge(item)` (`Prices:GetAge`, seconds or nil); `item` is
an ID or a link, and neither ever raises. The README's "For addon authors"
section documents it. Other people's addons read it, so never rename or
change these; a new call raises `version`. Tested in
`tools/test_publicapi.lua`.

## Sending data to Blackthornes

The owner said build it (2026-10-18), as Farmer's "Sending drops to
Blackthornes": players can opt in to send what their disenchants gave
(`disenchantLog.items`: casts and each material's times and total) and the
skill each recipe needs on Forever (`recipeSkills`, the number only) to his
characters. Prices are never sent. Off by default (`shareData`, never
rename it), never announced: one tick box on the About page of Settings,
"Share your data with Blackthornes to improve the Tradeskills AddOn.", no
hover, only on North American clients (`Contribute:InRegion`,
`GetCurrentRegion` 1 or 110, else `GetCurrentRegionName` "US"), and
`/bts share data on|off|log` (typed only, not in the help line).
`Logic/Contribute.lua` whispers a hello (`Q<id>:<hash>`) over Comm to each
name in `Contribute.RECIPIENTS` (full names, only in code, never shown; the
same two as Farmer's list, change both together) 30 s after login and
every five minutes (the owner, 2026-10-26). Only those characters ask
(`R<id>`), one sender at a time, the next as soon as one is done (or given
up after `SYNC_TIMEOUT`), each at most every five minutes, and the sender
answers only a recipient asking for its own id, at most every `SEND_GAP`.
The sender builds and hashes its table at most every `PAYLOAD_KEEP`
(`Contribute:Built`, kept per id; the hello and the answer send the same
build, so a hash a recipient heard always matches what it then keeps), and
the receiver waits `SYNC_TIMEOUT` (30 minutes, a big table takes a while
at Comm's pace) before giving one up. The table (`K`) is checked by `Contribute:Clean` and
kept apart on the receiver in `sharedData[id] = { at, hash, disenchants,
skills }`, each sender's newest replacing the last (at most `MAX_SENDERS`);
it never joins the receiver's own logs. A chat line, a sound and a screen
line say "Got disenchants and recipe levels from NAME.", and `sharedDataLog`
(`/bts share data log`, the newest `LOG_KEEP`) keeps who sent. Never rename
`shareDataId`, `sharedData` or `sharedDataLog`. Nothing is folded into the
shipped data yet. Tested in `tools/test_contribute.lua`. Not yet seen in
game.

## Sharing between accounts and with a guild

Asked 2026-10-07 (on Discord, the owner agreeing). Over addon
messages (`Core/Comm.lua`, prefix `BTSshare`):

- `Logic/AccountLink.lua`: the player names characters on another account
  of theirs (`linkNames`); both sides must name each other. Their
  characters arrive as ordinary `characters[guid]` records marked
  `linkedFrom` (never rename it), so everything that reads alts (Farmer
  aside, Equipment's crafting included) sees them. A copy never replaces
  one of the account's own characters and is never sent on.
- `Logic/GuildPrices.lua`: on by default since 2026-10-07 (`guildPrices`). Guildmates'
  prices are kept apart in `guildPrices[realm][itemID]` and only fill gaps
  in `Prices:GetValue`: an item never scanned, or one gone stale while
  theirs is newer. So Farmer's `GetValue` can now answer from a guild
  price unless the player turned it off; still copper or nil.
  Catching up (a player's report, 2026-10-22): `ASK_AFTER` seconds after
  login a guildmate sends `G<newest scan held>`, and anyone whose own scan
  is newer (under `ANSWER_SCAN_AGE`) waits, the newer the sooner, and sends
  it again unless another scan went out since (`OnAsk`, `Resend`, at most
  every `ANSWER_EVERY`). "Guild Status:" on the Sharing page is
  `GuildPrices:Status()`, from the save (`guildPricesSent` now keeps
  `count`). Comm sends 8 in a burst, then one a second.

TradeSkillMaster (a player asked, the owner agreed 2026-10-12 and said TSM
may be named in public for this, a second exception beside TomTom):
`Logic/TSMPrices.lua` reads `TSM_API.GetCustomPriceValue("DBMarket" or
"DBMinBuyout", "i:<itemID>")` inside a pcall, no TOC dependency, kept 60 s
an item. `Prices:GetValue` asks it only when neither your scans nor guild
prices have the item ("rival" never). "TSM prices" on the Sharing page
(`tsmPrices`, on unless unticked, never rename it). So Farmer's, Equipment's
and Butler's `GetValue` can answer from TSM too; still copper or nil. TSM's
prices come from its desktop app, which may not cover Forever's realms; then
it answers nil. Tested in `tools/test_tsmprices.lua`. Not yet seen in game.
Auctionator comes after TSM (the owner said yes and allowed naming it,
2026-10-12): `Logic/AuctionatorPrices.lua` reads
`Auctionator.API.v1.GetAuctionPriceByItemID("Blackthornes_TS", itemID)`
the same way, one price for market, min and lowest. Its price is the
player's own scans, so it has Forever prices (other Forever addons read the
same call). A stale price of your own also gives way to it when Auctionator
saw the item a whole day later (the owner said yes to a player's idea,
2026-10-22; `AuctionatorPrices:NewerThan`, from
`Auctionator.API.v1.GetAuctionAgeByItemID`, kept 60 s), as guild and
realm prices may; only for a stale price neither of those replaced. "Auctionator prices" (`auctionatorPrices`, on unless unticked,
never rename it). "Price Order:" under OTHER PRICE ADDONS (the
owner, 2026-10-25) picks TSM First or Auctionator First (`priceOrder`,
"tsm" unless picked, never rename it): it only swaps which of the two
fills a gap; your scans, guild, realm and set prices still come first.
Farmer has the same choice for when Tradeskills isn't loaded. Tested in `tools/test_auctionatorprices.lua`.

Farmer shares its own counts the same way (2026-10-11): its `Core/Comm.lua`
and `Core/Serialize.lua` are copies of ours (prefix `BFRshare` instead of
`BTSshare`, no test command, listening only while sharing is on), and it has
its own pairing (`shareNames`) rather than reading `linkNames`. A fix to
`Core/Comm.lua` or `Core/Serialize.lua` here belongs in Farmer's too.

## Guildmates who can make it

A player asked (2026-10-24) to see, on a craft, who else using the addon
online knows the recipe and whisper them; the owner said guild only, never
the realm. Off unless ticked: "Guild Crafters:" under YOUR GUILD on the
Sharing page (`guildCrafters`, account wide, never rename it).
`Logic/GuildCrafters.lua` talks over `Core/Comm.lua`: a guild hello
(`B<hash>`, `:1` the first a session) 40 s after login and every ten
minutes, a whispered ask (`N`) when the hash is new, and the list whispered
back (`L`, `{ h, r }`, recipe IDs in base 36), each guildmate at most every
ten minutes, answers to a first hello spread over a few seconds. Only names
and recipe IDs go. A whisper is taken only from someone whose guild hello
came first, or in the minute after our own first hello (`OPEN_FOR`), and
once the roster is read only names on it show (`members`); one it shows
offline, or not heard for `ONLINE_FOR`, is dropped. Nothing is saved.
The Profit tab's detail pane lists them under "Guildmates who can make
it:" (`UpdateCrafters` in `UI/Tab_Profit.lua`), a click whispers by full
name (`GuildCrafters.Whisper`). Tested in `tools/test_guildcrafters.lua`.
Not yet seen in game.

## Sharing with your realm

The owner asked (2026-10-20) for live prices without an app, a server or a
cost, picked a hidden in-game channel, and said build it from a mockup whose
words he approved. Tradeskills only: Farmer never shares past the guild.
`Logic/RealmPrices.lua`, off unless ticked (`realmPrices`, YOUR REALM on the
Sharing page, `/bts share realm on|off`, typed only like guild). When on it
joins a hidden channel for the side (`BTSPrices` plus A, H or N), hides its
join lines, and shares the last scan (Y announce, then Z prices, the guild's
batches) one message every `SEND_GAP` seconds, never in a fight, at most once
an hour, and not when `MIN_SENDERS` others covered that scan. Kept by a hash
of the sender's name, never the name, in `realmPrices[realm][itemID]` and
`realmPricesSent` (never rename either). A price is used only once 3 players
sent one, the middle of the last 5, and only to fill a gap after your own
scans and your guild's (`Prices:GetValue`), before TSM and Auctionator. A
price far from a fresh one of your own is refused. `Comm` hands handlers the
channel's name and target as fourth and fifth arguments. Tested in
`tools/test_realmprices.lua`. Not yet seen in game.

## German translation

The owner said yes (2026-10-12) to German in Tradeskills, after Pets'
pilot and Farmer. Players are told the language as "Deutsch"; the code
names stay `deDE` and `Locale/deDE.lua`.

- **English is the key and the fallback.** `Locale/Locale.lua` (in the TOC
  before `Core/Init.lua`, Pets' file) makes `ns.L`, whose missing keys
  answer the key itself; `L.Format(key, ...)` is `string.format` on the
  translation and puts values named by place (`%2$s ... %1$d`) in order.
  The tests load single files with a stub `ns`, so every file that shows
  text opens with `local L = ns.L or setmetatable({ Format =
  string.format }, { __index = function(_, key) return key end })`.
- **Adding a string:** `L["English text"]` or `L.Format("English %s",
  value)`, a literal where it is written, one whole sentence a key (never
  pieces joined with `..`), both forms for a plural; add its line to
  `Locale/deDE.lua` (informal "du" and the game's words: Auktionshaus,
  Händler, Entzaubern, Herstellen, Liste for the queue, Gewinn, Stufe) and
  run `python tools/check_locale.py` (warns only; keep it at 0 missing).
  `tools/test_locale.lua` loads the locale as a German client.
- **Text compared with text:** a caller that checks a wrapped string (an
  age's "just now", a reason like "need materials") compares it with the
  same `L[...]`, never the English.
- **Left in English on purpose:** slash command words, saved and internal
  keys, mail subjects, anything matched against the client (chat
  patterns, tooltip lines, spell and profession names), data names
  (items, crates and writs, Forever's own items such as Merchant's Favor,
  whose German names nobody has seen), debug and verbose scan lines, and
  the checks players run for a report (`/bts probe`, `perf`, `openprof`,
  `mail`, `disenchant`, `value` and the like; their help lines are
  translated).
- German runs about 30% longer: fixed-width buttons got short German
  ("Los" for Craft, "Kauf" for Buy) or grow to fit; a new fixed width must
  wrap or grow, never end in "...". The Columns menu lowers capital
  umlauts itself, since Lua's `lower()` does not.

## Simplified Chinese, French, Spanish and Russian

The owner asked (2026-10-18) for Simplified Chinese, French, Spanish and
Russian in every addon, after a player asked for Chinese. They work like
German: written by us from the English keys, never from a player's or
anyone else's file (the owner turned down a player's zip for safety).
`Locale/zhCN.lua`, `Locale/frFR.lua` ("tu"), `Locale/esES.lua` (one
Spanish for both Spanish clients: it loads on "esES" and "esMX", neutral
words, "tú") and `Locale/ruRU.lua` ("ты"), each in the game's own words,
listed in the TOC after deDE. Lines shared with the other addons (About,
the sister note, What's New, Settings) use the same wording as theirs.
Forever's own item names and "Overcutting" stay English, as in German.
Talk to the owner about "Simplified Chinese", "French" and so on, never
the codes. Every new string gets a line in all five files;
`tools/check_locale.py` checks them all. Tested in
`tools/test_locale.lua`. Not yet seen in game.

## The house frame (Titanforged)

The owner picked this look for all four addons on 2026-10-04 from two mockups
(the other was "Arcane Glass"). It's the game's own window shape with the
light turned up: a gold metal rim with corner gems, a round portrait with
the addon's emblem, the name on a plate across the top edge, a red close
gem, and tabs hanging below the window. Buttons are raised metal with gold
labels, and the main action is solid gold with dark lettering.

It lives in `UI/Titanforged.lua` (`Titanforged:Dress(frame, opts)`,
`:Opened(frame)`), with the art in `Media/Frame/*.tga`, drawn by
`tools/make_frame_art.py`. Hanging tabs are `CreateTabStrip(..., { hanging =
true })`. Tradeskills got it first. Farmer, Equipment and Pets copy the file,
the art and the tool, changing only `EMBLEM` in the tool (pick, shield,
paw). Glows and glints follow the Window effects setting.

List rows are dark glass (the owner picked it 2026-10-10 over a gold glow
that lit every row): `glass`/`glassAlt` bands in the well with a fine line
under each, `glassHover` and the gold wash only under the mouse,
`glassActive` for the picked row. A gradient that fades goes through
`Theme.LightGradient`, which hides it at 0; faded with SetAlpha alone it
stayed lit on Forever. Equipment's gear window and finder have the same.

## The auction house drawer

The owner picked it from a mockup (2026-10-13), after trying and reverting a
Tradeskills tab under the auction house (#616, reverted in #618; don't
re-offer the tab). `UI/PostPanel.lua` is one drawer beside the auction
window, its full height: the Titanforged plate reads "Tradeskills", its
close gem puts it away until the next visit (`CloseForVisit`), and its
header is `UI/Main.lua`'s auction bar (`UI:GetAuctionBar`, made inside the
drawer, placed by `PostPanel:PlaceBar`): the fold button, "Ready to sell" and
its worth, the scan's status and progress, and Post Crafted and Scan as
quiet metal buttons. Post Crafted is off the header for now (the owner,
2026-10-16): its code stays, and `UI.POST_CRAFTED_BUTTON = true` in
`UI/Main.lua` brings it back. Folded, the drawer is that header
(`PostPanel.FOLDED_HEIGHT`), so Scan stays in reach. Rows are dark glass,
names whole (`Theme.SetRowName`), List quiet metal; the one gold button is
List all at the foot (`PostPanel:ListNext`, one listing a click, most
valuable first of what Sell shows). Beside it on Sell, a Duration box (2, 8 or 24
hours, opening upward) sets the same `postDuration` as the Post tab's. Tested in `tools/test_postdrawer.lua`.
Not yet seen in game.

## Fast listing

Players kept asking (the owner said build it, 2026-10-14) for posting
faster than about five seconds a listing. The wait was ours, not the
game's: every click searched for its one item, then asked Yes or No, and
each search and read back counted against `AHQueue`'s budget. The game
only asks for a real click per listing. Now (`Logic/Posting.lua`, "Fast
listing"): List all's first click checks every price on Sell in one
search (`Posting:CheckAll`, `C_AuctionHouse.SearchForItemKeys`, at most
`CHECK_ALL_MOST`), read back by `Posting:OnCheckResults` from the
scanner's browse handler. An item counts as checked (`NoteChecked`,
`IsFresh`, for `FRESH_FOR` seconds; also after any one-item search) only
when the cheapest is someone else's (`Posting.RivalFromRow`) and not under
`CHECK_ALL_FAR_UNDER` of market (a lone low one is the one-item search's to
judge); a copy with a random suffix is never fast. While fresh, a click
(List all, a row's List, Post Crafted, the price editor) calls `Post`
straight away with no Yes/No box (`CanListOnClick`; a listing under what
it cost to make still asks), and `Post`'s guards all still run. List all
passes over an item still being confirmed (`GetNextPostable`'s
`skipSettling`), so nothing goes up twice. Listings close together share
one read back (`ShareVerify`, `NewerVerifying`), and `MAX_CONFIRMING` is
6. Leaving the auction house forgets every check. Since 2026-10-28 (the
owner: less in the way of posting) a click whose price was not fresh
checks it and says "ready to list" instead of the Yes/No box (on Era the
stack goes in the auction slot then), so the next click lists; with Check
Price First off the click lists at once; and with selling at a loss on, a
listing under its cost lists on the click too. Fast listing unticked
brings the box back for every listing. `allowPostingAtALoss` is on by
default for new saves; a value already saved is kept. The button says what its
next click does (the owner, 2026-10-16): "Check Prices - N to list" when
it would only check prices (`Posting:WouldCheckAll`, the same test as
`PostPanel:ListNext`, read again with the wait labels since a check goes
stale), else "List Next - N remaining", and its hover
(`PostPanel.ListNextTooltip`, through the button's `tooltipFunc`) previews
the next stack: item, how many at what price, total, after the cut,
deposit, market, vendor, disenchant, cost to make, then what comes after. "Fast listing" on the
auction page (`fastListing`, on unless unticked, never rename it). Tested
in `tools/test_fastlisting.lua`. Not yet seen in game.

## The mouse wheel at the auction house

A player asked (2026-10-16, the owner said build it, off by default): with
"Mouse Wheel" ticked on the Auction house page (`mouseWheelListing`, off
unless ticked, never rename it), while the drawer shows, wheel up does List
Next (`PostPanel:ListNext`) and wheel down Cancel next
(`MyAuctions:CancelNext`). `UI/AuctionWheel.lua` binds the wheel with
override bindings to two named buttons (`BlackthornesTSWheelList`,
`BlackthornesTSWheelCancel`), so each notch is the click the game asks
for; they go when the drawer hides, wait out a fight, and a flick does one
thing (`AuctionWheel.GAP`). A list under the mouse still scrolls; the
camera does not zoom while it is bound. Tested in
`tools/test_auctionwheel.lua`. Not yet seen in game.

## Overcutting

The owner said build it (2026-10-15, from a mockup, and picked the name):
an option to post just under the big stack instead of 1c under a few cheap
listings that sell first. `Profit:Overcut` (asked by `ChooseMarketPostPrice`
for stackable goods only, `status == true`, never a random suffix) walks the
scan's price steps (`record.ladder`, now `Prices.LADDER_STEPS` 10, with
`record.ladderAt` when they were read): the first step after the cheapest
with at least `OVERCUT.WALL_MIN` and `WALL_RATIO` times everything cheaper is
the big stack, and it posts 1c under it (Undercut by) only while the
cheaper ones add up to no more than `Prices:GetUnitsSoldPerDay`, the steps
are under `FRESH` old and still start at the cheapest rival, Demand is not
low and the price is within `CAP` of the scanned market value. Basis
"overcut"; Your auctions calls such an auction "overcut", not undercut
(`MyAuctions:Judge`). "Overcutting" on the Pricing page and beside Hide
losses on Sell (`overcutting`, off unless ticked, never rename it). The
setting's tooltip is `Profit.OVERCUT_HELP`. Tested in
`tools/test_overcutting.lua`. Not yet seen in game.

## Shopping lists

A player asked (2026-10-14, the owner said build it) for named shopping
lists. The auction house drawer's switch is Sell, Buy and Lists
(`UI/ShoppingListsView.lua`): "From your craft queue" first (the Buy view's
items, never saved, Save as a list keeps a copy), then the player's own
lists, each with a gold Search that looks up every item still needed (one
`C_AuctionHouse.SearchForItemKeys` through `AHQueue` where the client has
it, else one at a time with a "Next 2/5" button), and per item how many are
owned, the price, a box for how many are wanted, its own Search and an x.
The foot box adds an item (part of a name in any case, "linen 20", an ID,
or a Shift-click anywhere while a list is open and no chat box is typed in:
`View:TakeItem`, hooked after `HandleModifiedItemClick`, `ChatEdit_InsertLink`
and `ChatFrameUtil.InsertLink`, and from `Widgets.ItemShiftClick`; a player
found Shift-click and part names did nothing, 2026-10-14). Names above the
box come from `ShoppingLists:Suggest` over `BuildNames` (prices, recipes and
their materials, bags, stars, the ledger; only names the client has loaded,
built a slice a frame, kept 60 s), dark glass rows, Up/Down, Tab and Enter;
it also names a new list, renames, shows a list's
copy line (`BTSlist1:<name>:<id>x<want>,...`) or takes a pasted one. Delete
takes a second click. `Logic/ShoppingLists.lua` keeps them account wide in
`shoppingLists = { { name, items = { { id, want } } } }` (never rename it).
Tested in `tools/test_shoppinglists.lua` and
`tools/test_shoppinglistsview.lua`.

## List rules

The owner said build it (2026-10-19, from a mockup; he approved the words):
a list can carry rules every item on it follows, like a group in other
auction addons. A **Rules** button on each list's row opens "Rules for
NAME" (`UI/ListRulesWindow.lua`, the house frame, dark glass rows): WHEN
YOU SELL Lowest Price, Keep Listed (stacks at a time), Post For, Keep in
Bags (of each); WHEN YOU BUY Most I'll Pay (each); Clear. The row shows
"N rules". `Logic/ListRules.lua` keeps them on the list itself,
`shoppingLists[i].rules = { floor, listed, duration, bags, maxPay }`, and
each list gets a stable `id` from `shoppingListNextId` (never rename
`rules`, `id` or `shoppingListNextId`). None is set on a new list, so
nothing changes until the player sets one. An item follows the first list
on the Lists view that holds it and has a rule (`ListRules:For`, laid out
once per `ShoppingLists.version`). Where they reach: `Profit:ChoosePostPrice`
(Lowest Price, basis "list", unless the Prices tab has the item's own
price: that wins), `Posting:GetPostable` (Keep in Bags, the bigger keep
wins with `SisterKeeps`; Keep Listed against `Auctions:GetOwnPostedCount`,
"Waiting, already N up"), `Posting:DurationFor` (Post For) and
`BuyQuantity:Fill` (Most I'll Pay fills the box only with units at or
under it, `BuyQuantity.UnitsUpTo`). The Sell list tags a row with its list
or "Own price" (`PostPanel._ListTag`). Tested in `tools/test_listrules.lua`.
Not yet seen in game.

## Price limits

The owner said yes (2026-10-28) to three limits on a price the player
sets. A "Never below" price on the Prices tab can carry **Highest**
(`myPrices[realm][itemID].high`, copper: never list above it) and **When
Cheaper** (`.under = "wait"`: while others sell under the floor it stays in
the bags; nil lists at the floor, as before). `Prices:GetMyLimits`,
`SetMyHigh`, `SetMyWait`; `SetMine` keeps both when the price changes, and a
"use" price ignores them. A list's rules get the same (`high`, `wait`) and a
Lowest Price as a percent (`floorMarket`, `floorCost`, 1 to
`ListRules.MAX_PERCENT`; one floor kind at a time). % of Cost is the last
craft (`CraftedCost`), else the caller's costing for the item's recipe,
else `Cost:GetMaterialValue` (`ListRules.CostOf`); no base, no floor. Never
rename any of these. `Profit:ChoosePostPrice` returns basis "highest" over
Highest (whole silver for an item auction; one under the floor is left
out) and a 5th return `waits`, never for a "derived" or "uncontested"
price; `Posting:GetPostable` then holds the row ("Waiting, others are
selling for less"), so List all skips it, its own List still lists it and a
typed price wins. `GetValue` is unchanged. The screens (the owner said
build it from the mockup `previews/ts-price-limits/`, words approved,
2026-10-28): the Prices tab's own price shows "Highest:" (gold, silver,
copper) and "When Cheaper:" (List Anyway or Wait) only under "Never
below", and its line adds "Never above X." (`UI/Tab_Prices.lua`, the graph
hangs from `my.foot`); the Rules window (`UI/ListRulesWindow.lua`, now
420 wide) has Lowest Price with a Set Price, % of Market or % of Cost
drop-down (`FLOOR_KINDS`, `PickFloor`), Highest Price and When Cheaper;
the Sell list adds "(the most you set)" to a row at Highest. Tested in
`tools/test_myprices.lua`, `tools/test_listrules.lua` and
`tools/test_ownprice.lua`. Not yet seen in game.

## The fold gem

A player asked, the owner picked the mockup (2026-10-24), in all five
addons: a small gold gem left of a window's red close gem folds the window
down to its plate and opens it back up. `UI/FoldWindow.lua` is the same
file in all five (a fix to it belongs in all five), and so are
`tools/make_fold_art.py` (draws `Media/Frame/FoldGem.tga`; rerun it, never
edit the TGA) and `tools/test_foldwindow.lua`. `FoldWindow:Add(frame,
{ onToggle, canFold })` after `Titanforged:Dress`; it sits on the trim, so
`Titanforged.lua` and `BlizzardLook.lua` are untouched. Folded, the window
keeps its place and width and is `FoldWindow.HEIGHT` tall: the rim, fill
and halo stay (`FoldWindow.Keeps`, by where each lies), the bottom corners
and everything else on it hide and stay hidden while folded, and it can
still be dragged. The gem again, closing it, or opening it by a command or
the minimap button opens it full (`Unfold`). In a fight it will not fold
over a button the game guards. With the Blizzard style it is the game's
own minimize and maximize art when the client has it. Tooltips "Collapse
this window" and "Expand this window"; nothing is saved. Here: the main window (`UI/Main.lua`).

## The Blizzard window style

The owner asked (2026-10-10) for a choice of the game's own look beside
Titanforged, in all four addons. "Window style" in Settings (`windowStyle`,
`titanforged` or `blizzard`, Titanforged by default; read once at login,
so a change waits for /reload, as Text size does). `UI/BlizzardLook.lua`
is the same file in all four (a fix to it belongs in all four): picked, it
lays the game's colours over `Theme.colors` (grey metal, the game's gold,
plain rows with a blue bar for the one picked) and puts out the halos;
`Titanforged:Dress` hands the window to `BlizzardLook.Dress` (silver rim,
a title tab where the plate sits, a silver-ringed portrait and the game's
`UIPanelCloseButton`, with the same trim fields); and the widgets call
`BlizzardLook.Button`, `.Checkbox`, `.Tab`/`.SelectTab` (hanging tabs) and
`.Thumb` (via `Widgets.LightThumb`) to wear the game's own texture files.
It never touches a Blizzard frame. Each file is checked once
(`BlizzardLook.HasArt`); a client without one keeps that widget in the
house look, and `/bts probe` lists what is missing. Not yet seen in game.
New widgets should look right in both styles.

## Reading the probe

The owner asked (2026-10-10) for check results without screenshots, in all
four addons. `ns.KeepCheck(name, fn)` in `Core/Init.lua` runs a check that
prints to chat, keeps every line it prints (colours and links taken out, a
secret value kept as "(secret)") and saves them in the account save as
`lastProbe = { check, at, version, lines }`, replacing the last one; chat
adds "Saved for Claude, /reload to write it." It wraps `/bts probe`
(Tradeskills, saved under `BlackthornesTSDB.global`), `/beq probe` and
`/beq arrow check` (Equipment), `/bpet probe` and `/bpet arrow check`
(Pets), and `/farm arrow check` and `/farm gathering check` (Farmer, which
has no probe). None has a Settings button (the owner, 2026-10-23: checks and debug are typed only, so players never see them; `RegisterHiddenCommand` keeps them out of help, Tradeskills' short help leaves them out). Never rename `lastProbe`; a new
check that players run for a report goes through `ns.KeepCheck` too, and a
fix to it belongs in all four.

When the owner says "read the probe": he has run the check and typed
`/reload` (or logged out). In the thread, connect to his device, ask for
his game's WTF folder (already approved; the path is in the project's
memory) and stage the addon's account save from
`WTF\Account\<account>\SavedVariables\` (`Blackthornes_TS.lua`,
`Blackthornes_Farmer.lua`, `Blackthornes_Equipment.lua` or
`Blackthornes_Pets.lua`), read only. Read its `lastProbe`: `check` says
which one ran and `at` when; one older than his message means the save was
not written yet, so ask him to `/reload`. Use only the probe lines; never
commit the save or copy anything else out of it.

## Discord

The addons share a Discord server, Blackthornes AddOns (public invite
https://discord.gg/f2geDecrw2, set up 2026-10-05). After a release uploads,
`release.yml` runs `tools/announce_discord.py`, which posts the version's
CHANGELOG section to the server's #announcements through a channel webhook
kept in the `DISCORD_WEBHOOK_URL` repository secret. The owner sets that secret
himself; never ask him to paste the webhook address anywhere. Without it the
step does nothing, and a failed post never undoes the upload. The tool is the
same in all four repos; a fix to it belongs in all four.

The owner asked (2026-10-09) for one post in #general per release too,
and (2026-10-10) for it to be short: a few bullets in plain words, a
sixth-grade reading level, warm, in his voice (short, contractions, no
jargon, no file or setting names, never his name), saying what players will
notice. Each release PR writes the new version's section in `NEWS.md`
(`## X.Y.Z`, like CHANGELOG.md; it never ships) next to the CHANGELOG
section: the bullets, then one line of thanks. After the upload
`tools/post_general.py` scans it with `check_package.py`'s PRIVATE list and
posts it through the `DISCORD_GENERAL_WEBHOOK_URL` secret, which the owner
sets himself, under a line with the addon's name and version (so each
addon's bullets are their own group) and "(full list of changes in
#announcements)". It carries no CurseForge link and no card (link previews
are turned off). No section or no secret means no post.
A player's name never goes in a report (the owner, 2026-10-09): no
CHANGELOG, #announcements post, commit or PR text names a player, and
`check_release.py` refuses a CHANGELOG section that credits one
(`names_a_player` in `post_general.py`). The #general post is the one
exception: its last line thanks, by their Discord name, everyone who asked
for or reported the changes, each name once ("Thanks Ana and Bob for the
ideas and reports!"); leave it out when nobody asked. Find who asked from
the project's threads.
The thanks line no longer goes out with the webhook post (the owner,
2026-10-13: thank each player with a real @mention, so they get a
notification): `post_general.py` leaves out the paragraph that starts
"Thanks" (`without_thanks`), and the owner's bot, on his PC, posts it under
the release post with the mentions once he approves the wording, looking
the Discord names up there. Discord IDs never go in a repo. NEWS.md keeps
the thanks line, by Discord name, as before; ask the owner for any name
that isn't known.
This tool is also the same in all four repos.
Changes to the Discord bots, the digest or the release posting tools
(like this one) never go in a CHANGELOG, #announcements or #general
section (the owner, 2026-10-10): they are not changes to the addon.

The language is "Deutsch" in every post (the owner, 2026-10-11): a
CHANGELOG.md or NEWS.md section about the German translation or German
clients says "Deutsch", or "Deutsch (German)" where English readers need
the hint, never "German" alone. `tools/check_release.py` warns (it does
not refuse) when this version's CHANGELOG.md or NEWS.md section says
German without Deutsch. This rule is in every addon's notes; keep them
the same.

## What's New

The owner asked (2026-10-12) for the Discord #general post to show in game,
the first time it loads after an update, in one window for every addon.
`UI/WhatsNew.lua` is the same file in all five (a fix to it belongs in all
five), and so are `tools/test_whatsnew.lua`, `tools/make_whatsnew.py` and
`tools/test_make_whatsnew.py`. There is no shared core addon: every copy
signs up in `_G.BlackthornesWhatsNew` as it loads, the first to reach
PLAYER_LOGIN starts the only timer (`WhatsNew.DELAY`, 5 s, never in a
fight), and that one check gathers what is new in all of them. The copy
with the highest `FILE_VERSION` draws the window (first in
`WhatsNew.ADDONS` on a tie); raise it when a change needs the newer copy.

The words are NEWS.md's: it never ships, so `tools/make_whatsnew.py` writes
its newest three sections, bullets only (the thanks line names players and
never ships), into `Core/WhatsNewText.lua` (`ns.WHATS_NEW`; never edit it by
hand). The window shows new features only (the owner,
2026-10-13): a section's
fixes and other changes go under a "Fixes and changes:" line, which go to
Discord but not the window, and every line is plain words with no hype,
no questions to the reader, no exclamation marks and no dashes as
punctuation (the tool notes one that trips `STYLE`). **Every release PR that writes a NEWS.md section runs
`python tools/make_whatsnew.py` too**; `check_release.py` refuses a tag
while the file is behind, and `tools/test_make_whatsnew.py` fails on every
push. The bullets stay in English, also on a German client.

Shown once a version: each addon keeps the newest version shown in its own
account save (`whatsNewSeen`); after an update the sections newer than that
(at most three) show, and an addon that never kept one shows its newest.
"After an update" (`whatsNewPopup`) and "What's New motion"
(`whatsNewMotion`) are on unless unticked, off in all when off in any;
`whatsNewScale` is the size grip's, where the addon has one. Never rename
them. The `whatsnew` command and a Settings button open it any time, with
each addon's newest. It rises in, its divider draws out, each addon's card
slides up with its icon popping and a light crossing it, and the Got it
button glows (one looping animation the game plays, only while it shows);
Motion off lands it all at once. Not yet seen in game.

## The About page and the note

The owner asked (2026-10-13) for a note on how the addons are made, once at
the top of What's New and kept on an About page in every addon's Settings.
`UI/About.lua` is the same file in all five (a fix to it belongs in all
five): `About.NOTE` is the owner's wording, a paragraph a key; change it
only when he asks, in all five, with each `Locale/deDE.lua`. `About:Note`
and `About:Info` build the page's two columns (the version, the Discord in
a box to copy, how to report a bug, a thank-you that names no player, a
What's New button and the other Blackthornes addons from
`SisterNote.ADDONS`); each addon's Settings places them on its "about"
page. `UI/WhatsNew.lua` (FILE_VERSION 3) puts the note at the top of the
next window that comes up by itself, alone when nothing is new, then sets
`aboutNoteSeen` in every sister's account save (never rename it); with the
window turned off it waits. Tested in `tools/test_whatsnew.lua`.

One-time cards (the owner, 2026-10-13): an addon can put cards in
`ns.WHATS_NEW_TIPS`, each `{ key, title, icon, paragraphs, hint, button,
run, due }`. The next window that comes up by itself shows each one after
the note, only when `due()` says so (in a pcall), with a button that calls
`run()` and closes the window. Looked at once either way: the key goes in
that addon's account save as `whatsNewTipsSeen[key]` (never rename it), so
a card never comes back; with the window turned off it waits.
`UI/WhatsNew.lua` is at FILE_VERSION 4 for it. Equipment's
`Logic/UpgradeQuest.lua` has the first, for the upgrade quest, due while
it is off.

## The sister note

The owner asked (2026-10-11) for the addons to say, once, which of the
others a player does not have. `Core/SisterNote.lua` is the same file in
all five (a fix to it belongs in all five), and so is
`tools/test_sisternote.lua`. Every copy signs up in `_G.BlackthornesSisterNote`
as it loads; the first to reach PLAYER_LOGIN starts the only timer
(`SisterNote.DELAY`, 8 s, no ticker), and that one check prints one line for
all of them: the sisters not installed (`C_AddOns.DoesAddOnExist`, else
`GetAddOnInfo`'s "MISSING"), each with what it adds. One installed but
turned off is never named. Once per account: what it named is kept in every
loaded addon's account save as `sisterNoteTold[folder] = true`, so only a
sister never named before (one released later) brings it back. "Sister
addons" in Settings (`sisterNote`, on unless unticked) and the `sisters`
command on each addon: off in any is off in all, and changing it writes all.
Never rename `sisterNote` or `sisterNoteTold`. A new addon goes in
`SisterNote.ADDONS` in all the copies. It names only our own addons.

## One key per character

The owner asked (2026-10-11) that a character can never be mistaken for
another again. Old records had sent errands to the character playing:
Butler filled a mail to itself and told a player to mail Medium Leather to,
and log out for, the character they were on (an old "Name-Realm" record of
Tradeskills' beside the GUID one), and a reload wiped alts' saved gear in
Equipment. The rule, in every addon:

- **A character is its GUID** (`UnitGUID("player")`) in saved data and in
  every call between the addons. Never a first name, "Name-Realm" or a
  short name: Forever lets characters share a first name. Names are for
  showing and for a mail's To line only, always first and last.
- **A GUID the client won't read (a dungeon) means "not sure who's
  playing":** write nothing under another key, and offer nothing for an
  alt. Tradeskills remembers each character's GUID in its own file
  (`BlackthornesTSCharDB.guid`) for that case.
- **Old records stay readable and count as the same character; nothing is
  deleted.** Tradeskills folds an old "Name-Realm" record into the GUID one
  at login, once (`Config:AdoptLegacyCharacter`): it is kept whole in
  `formerCharacters[old key]` with `retiredInto` (never rename either), what
  the GUID record lacks is filled from it when it carries that GUID, and
  the queue's references to the old key follow. Farmer reads a goal tagged
  "Name-Realm" as the character's and tags it with the GUID once the
  character gathers toward it or changes it.
- **One test per addon answers "the same character?" and "the one
  playing?"; never compare keys or names by hand.** Tradeskills:
  `Characters:Same`, `:IsPlaying` and `:Canonical` (`Core/Characters.lua`),
  and `playing` on each `Butler:Holdings()` entry. Butler:
  `Errands:IsMe(name)` (full name, first name alone, any old record's name,
  any case, with or without a realm). Farmer: `Goals:IsOwner`. Equipment:
  `Alts.PlayerGUID()`.
- **Every errand that targets a character asks that test right before it
  acts and refuses the character playing:** a mail, a gold top-up, a Log
  out, an alt's upgrade, a learned habit, the disenchanter.
- Tested in Tradeskills' `tools/test_onecharacter.lua`, Butler's
  `tools/test_notme.lua`, Farmer's `tools/test_goals.lua` and Equipment's
  `tools/test_alts.lua`. This rule is in every addon's notes; keep them the
  same.

## Writing for players

Every word a player reads (labels, buttons, tooltips, Settings rows and
their descriptions, empty lists, chat lines, slash command help) reads the
way a friend who plays would say it: plain, warm and human. Write it at a sixth grade reading level. Short
sentences in everyday words, contractions welcome. Say what the player
sees or does, not how the addon works inside. No hype or sales words
("seamlessly", "effortlessly", "now you can", "powerful"), no filler, no
em-dashes, and no questions to the reader. The German in
`Locale/deDE.lua` changes with the English, in the same informal "du"
voice. Farmer's play cheers keep their "!" (drop-quality cheers, goal
marks, streaks, "Up to #N!", "Goal done: X!"), and `About.NOTE` is the
owner's own wording. This rule is in every addon's notes; keep them the
same.

## The owner's standing rules (both addons)

- **Every list is dark glass** (the owner, 2026-10-12: "keep this as the
  standard across all Blackthornes addons", after Farmer's Kills & Loot
  panel was given the look of Tradeskills' queue). Rows or lines take
  `glass` and `glassAlt` in turn, by place, with a 1 px `border` line
  (alpha 0.6) under each; under the mouse `glassHover` and a gold edge,
  only on that row; the row picked or open is `glassActive` with a bright
  gold edge down its left. Never the older `row`/`rowAlt` bands for a
  list, a panel's lines or cards. A gradient fades through
  `Theme.LightGradient` or is hidden, never with SetAlpha alone (it stayed
  lit on Forever). This rule is in every addon's notes; keep them the same.
- **"Always check that it's clear to post."** Anything that goes public (a
  release, a CurseForge page, a post) is checked for private or unexpected
  content first, and nothing is published or uploaded without the owner's
  go-ahead. He tags releases himself.
- **Changelogs come from git history.** Work out what changed since the last
  tag from the merged PRs and commits (`git log vX.Y.Z..origin/main --merges`);
  never ask the owner what went in. Claude drafts the CHANGELOG section in a PR;
  The owner merges, pulls `main`, tags and pushes.
- **A checkout shows the real version number** (the owner,
  2026-10-12). `ns.RELEASED_VERSION` in `Core/Init.lua` is the newest
  `## X.Y.Z` in CHANGELOG.md, shown when the packager has not filled in the
  TOC's `@project-version@` (he plays from a clone). The release PR that
  writes the CHANGELOG section changes it too; `tools/check_release.py`
  refuses a tag it does not match, and `tools/test_check_release.py` fails
  while the two disagree. This rule is in every addon's notes.
- **Every reply that ships code ends with the GitHub Desktop steps,** naming
  the branch: merge the PR on github.com (Ready for review, then Merge pull
  request); in GitHub Desktop switch **Current branch** to **main** and click
  **Pull origin**; then say whether the game needs `/reload` or a full restart
  (a full restart when a file is added, removed or renamed, or the TOC
  changes). For a release, add: History, right-click the newest commit,
  Create Tag, `vX.Y.Z`, Push origin. Remind him to pull `main` first, or the
  tag lands on an old commit and nothing runs.
- **Grey (poor quality) items are priced at vendor only,** never from the
  auction house. Everything else is worth max(auction, vendor). Farmer applies
  this to every value it shows; follow it here if Tradeskills ever values grey
  items.
- **CurseForge descriptions are features only.** Leave out privacy or
  "your data stays yours" notes and any explanation of public emotes or their
  switches: "they don't care to know this." Those belong in the README and
  CHANGELOG.
- **Smooth play comes first, but never at the cost of looks** (the owner,
  2026-10-09, after a hitch while crafting). Nothing on a timer or
  OnUpdate rebuilds or re-places a whole list, map or set of markers when
  only one thing moved: keep what is drawn, and redo only rows or pins
  whose inputs changed (a per-row key, a version number). Bag, loot,
  cast, skill and profession-list events arrive in bursts, several per
  craft or loot: coalesce them, read only what they changed, and skip
  work for windows that are hidden. Work over hundreds of items (recipes,
  sources, saved spots) is spread over frames (a worker with a small
  per-frame budget) rather than done in one frame, and shown when done.
  Clicks and typing still answer at once. The two causes found: Farmer's
  minimap markers gathered, sorted and re-placed every saved spot once a
  second because the clock second was in their redraw key (now only the
  fade moves, `MapMarkers:FadeMinimap`); and on every craft Tradeskills
  re-read every recipe in the profession window and repriced the whole
  craft pane in one frame (now `Recipes:NothingNewMidCraft` skips the
  re-read mid-run and `CraftPanel:RefreshInSlices` spreads the pane over
  frames). Visuals and usability are never traded away for speed. This
  rule is in all four addons' notes; keep them the same.
- **Never shorten a character's last name** (the owner, 2026-10-11:
  "they must be included in WoW Forever"). Forever names are first and
  last together, so every place a character is named shows the whole name,
  made to fit by growing or wrapping (`Theme.SetRowName`, `FitText` with a
  wording that drops words, never the surname), never "Bob B." or the
  first name alone. `Recipes:GetShortCharacterName` keeps its name for
  Equipment and Butler but returns the full name.
- **The client is WoW: Forever, a retail engine** (`## Interface: 16001`,
  modern Lua), not 1.12. Instances hand addons secret values that raise when
  compared, concatenated or formatted, so read client values inside a pcall.
  `docs/FOREVER_API_FINDINGS.md` has what the client actually does.
