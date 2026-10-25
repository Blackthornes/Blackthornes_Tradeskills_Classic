# Tradeskills Classic Era port: the plan

Written 2026-10-24, after PR #1 (Interface 11509, Forever's CurseForge ID
out and refused). Steps 1, 2 and 3a are done. Each step is one small PR,
built only after the owner's yes, merged only on his "merge it".

Rules for every step: never touch the Forever repo; keep Forever-only
files in this repo but out of the TOC, so Forever fixes copy over cleanly;
every reader of a dropped file asks for it first (`if ns.X then`), so the
code stays the same shape as Forever's; calls to the other Blackthornes
addons stay inside a pcall and Tradeskills works alone; no new player
words without the owner's OK; read the big files in pieces.

## What the survey found

The TOC loads 155 files. Two kinds of work stand out.

**1. The client calls (the big work).** Forever is a retail engine; Era is
not.

- *Auction house.* Era has the old one: `QueryAuctionItems`,
  `GetAuctionItemInfo`, `GetNumAuctionItems`, `StartAuction`, no
  `C_AuctionHouse`. `Core/Compat.lua` already detects this
  (`auction.mode = "legacy"`), and `Logic/Posting.lua` already has an old
  `StartAuction` way to post. But scanning (`Data/Scanner.lua`, 2,430
  lines, 33 `C_AuctionHouse` calls), buying (`Logic/AHBuys.lua`,
  `Logic/ShoppingLists.lua`, `UI/BuyQuantity.lua`), your auctions and
  undercuts (`Logic/MyAuctions.lua`, `Data/Auctions.lua`) and the
  drawer's views are modern only. This is the hardest part: a page scan
  (and the whole-house scan `QueryAuctionItems(..., getAll)`) needs its
  own reader, throttle and buy-by-row logic.
- *Profession windows.* `Data/Recipes.lua`, `Logic/Crafting.lua`,
  `Logic/SkillUp.lua`, `Logic/LevelUp.lua` and `UI/CraftPanel.lua` read
  `C_TradeSkillUI.GetAllRecipeIDs`, `GetRecipeSchematic` and
  `CraftRecipe`. Era has the old `GetTradeSkillInfo`,
  `GetTradeSkillReagentInfo`, `DoTradeSkill`, and Enchanting uses its own
  Craft window (`GetCraftInfo`, `DoCraft`). Without this nothing is
  learned from a profession window, so nothing can be priced as a craft.
  `Logic/SkillUp.lua` already reads `GetTradeSkillInfo` for difficulty,
  which is a start.

**2. Forever-only data and features (easy to take out).**

| What | Files | Plan |
|---|---|---|
| Forever's own recipes | `Data/ForeverRecipes.lua` (184 KB) | out of the TOC |
| Forever's vendor and trainer spots | `Data/ForeverVendorSpots.lua` | out of the TOC; Classic's spots stay |
| Forever's recipe skills in Learn next | `Data/LearnSpots.lua` (Classic spots, Forever skills) | keep for now; redo from Era data later |
| Legacy perks (Master Chef) | `Logic/Legacy.lua` | out of the TOC; readers ask for `ns.Legacy` first |
| Merchant's Favor, Waylaid Crates, the favor goal, the Favors drawer | `Logic/MerchantsFavor.lua`, `Data/WaylaidCrates.lua`, `UI/DealsFavor.lua`, `UI/FavorsView.lua` | out of the TOC; the Deals tab and drawer hide the parts |
| Craftsman's Writs, Sealed writs, coin bags | `Logic/Writs.lua`, `Data/CraftsmansWrits.lua`, `UI/DealsWrits.lua` | out of the TOC, as above |
| Sending data to Blackthornes | `Logic/Contribute.lua` | `RECIPIENTS` emptied and no tick box while nobody is named, as Farmer's Era copy did (those characters play on Forever) |

Kept as they are: the travel files (Forever-only zones and flights are
simply never met on Era), `Data/RecipeBook.lua` and `Data/VendorSpots.lua`
(already Classic 1.12 data), prices from other addons, sharing between
accounts and guild, the Butler, Farmer and Equipment calls.

## The order

1. **Forever data out.** (Done, 2026-10-24.) `ForeverRecipes`, `ForeverVendorSpots` out of the
   TOC; a `tools/test_era.lua` (as Farmer's and Butler's) checks the TOC
   and that the addon loads and logs in without them and with no sister.
2. **Forever features out.** (Done, 2026-10-24.) `Logic/Legacy.lua`,
   `Logic/MerchantsFavor.lua`, `Data/WaylaidCrates.lua`, `UI/DealsFavor.lua`,
   `UI/FavorsView.lua`, `Logic/Writs.lua`, `Data/CraftsmansWrits.lua`,
   `UI/DealsWrits.lua` and `Logic/Contribute.lua` are out of the TOC (as
   Equipment's Era copy did with its Contribute). Every reader already
   asked for the module first. The Favors and Writs tab has nothing left,
   so `UI/Tab_Deals.lua` registers it only with the flips or one of its
   views; the drawer's Favors switch never shows (no goal can be set); the
   "Crate Costs:" row in Settings shows only with `ns.MerchantsFavor`;
   the share-data tick box and `/bts share data` go with Contribute.
   Saved settings (`favorGoal`, `writGoal`, `merchantsFavor`, `shareData`
   and the rest) stay in the save, unread. `tools/test_era.lua` checks it.
3. **Profession windows, the Era way.** Two PRs.
   - *3a, reading.* (Done, 2026-10-24.) `Data/EraRecipes.lua` reads the
     old profession window (`GetTradeSkillInfo` and friends), Enchanting's
     own window (`GetCraftInfo` and friends; Beast Training's is skipped)
     and the professions and levels in the skill list (`GetSkillLineInfo`)
     into the same records Forever's harvest makes, with Classic's skill
     lines. A recipe is kept by its spell ID: the recipe link when the
     client gives one, else Classic's book by what it makes, then by
     name; one none of them finds is left out. A German client knows its
     professions by a spell each teaches (`PROFESSION_SPELLS`). Recipes.lua
     hands over only when the modern calls are missing (`GetProfessions`,
     `ReadProfessionLines`, `HarvestSignature`, `Harvest`, the client's
     profession names) and `SkillUp:ReadSkillLevels` likewise, so Forever
     merges stay small. A bag change mid-craft reads nothing again unless
     the lines or the skill moved. Tested in `tools/test_eraharvest.lua`.
     Known gaps: a heading the player folded, or the window's filters, hide
     those recipes until they show; Herbalism is known by name on an
     English client only (it has no recipes).
   - *3b, crafting.* Craft buttons through `DoTradeSkill`/`DoCraft`, and
     the craft panel beside the old window (`UI/CraftPanel.lua`,
     `Logic/Crafting.lua`). Mid-craft skipping then also uses the craft
     under way.
4. **Auction house, the Era way.** The whole-house scan is done
   (`Data/LegacyScan.lua`, 2026-10-25: quick full scan, page by page
   while it waits). Still to come, in several PRs: page scan of one item
   and of the shopping list; the whole-house scan; posting through the
   old sell slot (much of it exists); buying a row; your auctions and
   undercuts (`GetOwnerAuctionItems`). Until a part is done its button
   stays hidden on Era rather than raising.
5. **The probe in Era.** `/bts probe` lines for the old calls, then the
   owner runs it in the Era client and we fix what it finds.
6. **Data from Era's tables** where Forever's were used (recipe skills in
   `LearnSpots`), and the sister lists.

Steps 1 and 2 are a day or so. Steps 3 and 4 are the weeks the memory
warned about; the auction house alone is most of it.

## Answered by the owner

- The Merchant's Favor and Writs views just disappear on Era (2026-10-24).
- The auction house parts come one at a time, hidden on Era until each
  one works (2026-10-24).
