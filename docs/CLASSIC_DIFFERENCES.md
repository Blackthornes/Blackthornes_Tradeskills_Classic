# Classic differences

Every place this Classic Era copy differs from Forever Tradeskills, and why.
Keep it short and current: a PR that adds a Classic-only change adds its
line here in the same breath. The port's plan and what is still to come are
in `docs/handoff/classic-port.md`.

## The catch-up rule

Every Forever catch-up checks this note first, before sorting commits into
"fits Era", "Forever only, skip" or "needs changes for Era".

- A Forever commit that touches nothing listed here comes over as it is.
- A Forever commit that touches only a file Classic leaves out of the TOC
  (below) is "Forever only, skip", unless it also changes how the readers
  that ask for it behave.
- A Forever commit that lands on something listed here is a clash. Show the
  owner both versions side by side and offer three choices:
  - **Keep Classic's:** skip the Forever change.
  - **Take Forever's:** only when it really replaces what Classic did.
  - **Blend them (the usual pick):** bring Forever's idea over on top of
    Classic's version. For example, a Forever fix to how a recipe is read
    from the modern profession window also goes into `Data/EraRecipes.lua`
    when Era reads the same thing.
- Whatever is picked, nothing below gets lost by accident. If a pick changes
  a line here, the same PR changes the note.

## What differs

### The TOC
- `## Interface: 11509`, what the owner's Era client reports. Forever is 16001.
- `## X-Curse-Project-ID: 1763353`, Tradeskills Classic's own project.
  Forever's 1710638 must never be here: `tools/check_release.py` refuses a
  tag that has it (tested in `tools/test_check_release.py`;
  `tools/test_era.lua` checks the Classic ID is there).
- The folder and TOC (`Blackthornes_TS`), saved data (`BlackthornesTSDB`,
  `BlackthornesTSCharDB`), the global and `/bts` are the same as Forever's,
  on purpose. Never rename them.
- `## Notes:` still ends "for WoW: Forever". New wording waits on the
  owner's OK.

### Forever data left out of the TOC (step 1)
The files stay in the repo so Forever changes merge cleanly; Era never
loads them, and every reader asks for them first.
- `Data/ForeverRecipes.lua`: Forever's own recipes, so the recipe book is
  Classic's alone (`Logic/RecipeBook.lua` says so in its notes).
- `Data/ForeverVendorSpots.lua`: Forever's vendor and trainer spots, so only
  spots seen in game lie over Classic's. `VendorPins:Known`
  (`Logic/VendorPins.lua`) reads `ns.FOREVER_VENDOR_SPOTS` and
  `ns.FOREVER_TRAINER_SPOTS` only when they are tables. Keep that guard in
  a blend.

### Forever features left out of the TOC (step 2)
- `Logic/Legacy.lua` (Master Chef and the other perks).
- Merchant's Favor and its Waylaid Crates: `Logic/MerchantsFavor.lua`,
  `Data/WaylaidCrates.lua`, `UI/DealsFavor.lua`, `UI/FavorsView.lua`.
- The Craftsman's Writs: `Logic/Writs.lua`, `Data/CraftsmansWrits.lua`,
  `UI/DealsWrits.lua`.
- `Logic/Contribute.lua`: its recipients play on Forever, so the share-data
  tick box and `/bts share data` go with it.
- With those gone, `UI/Tab_Deals.lua` registers the Favors and Writs tab
  only with the flips or one of its views, and `UI/Tab_Settings.lua` shows
  the "Crate Costs:" row only with `ns.MerchantsFavor`. The drawer's Favors
  switch never shows. Saved settings for them (`favorGoal`, `writGoal`,
  `merchantsFavor`, `shareData`) stay in the save, unread.
- A Forever change to any of these features is "Forever only, skip"; one to
  the tab or Settings row around them is a clash to blend, keeping the guard.

### Profession windows, the Era way (step 3a)
- `Data/EraRecipes.lua` (new here) reads the old profession window
  (`GetTradeSkillInfo` and friends), Enchanting's own Craft window
  (`GetCraftInfo` and friends; Beast Training skipped) and the skill list
  (`GetSkillLineInfo`) into the same records Forever's harvest makes, with
  Classic's skill lines. A recipe is kept by its spell ID: the recipe link,
  else Classic's book by what it makes, then by name. A German client knows
  its professions by a spell each teaches (`PROFESSION_SPELLS`).
- `Data/Recipes.lua` hands over to it only when the modern calls are
  missing: `ClientProfessionNames`, `Recipes:GetProfessions`,
  `ReadProfessionLines`, `Recipes:HarvestSignature` and `Recipes:Harvest`
  each have a small `ns.EraRecipes` branch at the top.
  `SkillUp:ReadSkillLevels` (`Logic/SkillUp.lua`) likewise. A Forever change
  to these functions is a clash to blend: keep the Era branch, and ask
  whether the same change belongs in `EraRecipes`.
- Tested in `tools/test_eraharvest.lua`. Known gaps: a heading the player
  folded, or the window's filters, hide those recipes until they show;
  Herbalism is known by name on an English client only.

### Crafting from the old windows (step 3b)
- Era has no `C_TradeSkillUI.CraftRecipe`, so Craft raised "attempt to call
  a nil value". `Crafting:Start` (`Logic/Crafting.lua`) hands over to
  `EraRecipes:Craft` when `Crafting.EraWindows()` says the client is
  legacy: `DoTradeSkill(index, count)` in the old window, `DoCraft(index)`
  (one a click) in Enchanting's. The index comes from
  `EraRecipes:OpenLines` (the window's lines matched to this character's
  recipes by name, laid out again when the window or the recipe count
  moves) and is checked by name again right before the call. A recipe a
  folded heading or a filter hides says "cannot craft that".
- `Crafting.isTradeSkillOpen` also follows Enchanting's window
  (`CRAFT_SHOW`/`CRAFT_CLOSE`), so the two can be open at once.
  `CraftPanel:GetOpenRecipeIDs` answers `EraRecipes:OpenRecipeIDs` (every
  recipe this character knows in the open windows' professions; nothing
  for Beast Training). `Crafting:Stop` falls back to
  `StopTradeSkillRepeat`, and `IsStillCrafting` counts a run with crafts
  left (`GetTradeskillRepeatCount`) as going for `REPEAT_GAP` seconds
  after a cast. A Forever change to these is a clash to blend. No new
  words. Tested in `tools/test_eracraft.lua`.

### The old auction house
- Era has no `C_AuctionHouse`. `Core/Compat.lua` already reports
  `auction.mode = "legacy"`, and `Logic/Posting.lua` already has an old
  `StartAuction` way to post. Buying, your auctions and the drawer's
  views are still modern only (step 4 of the plan): until a part is done
  its button stays hidden on Era rather than raising.
- The price check before a listing works on Era (2026-10-25): with
  `auction.mode` "legacy", `Scanner:ScanItem` hands over to
  `LegacyScan:ScanItem`, which searches the item by its exact name, reads
  up to `ITEM_PAGES` pages inside `ITEM_BUDGET` seconds and settles through
  `Scanner:FinishItemScan`, as Forever's search does. A scan holding the
  list, or the player's own search, makes it give way. Era's item auctions
  take copper, so `Util.SilverOnly()` is false there and `RoundToSilver`,
  `CeilToSilver` and `IsWholeSilver` only make a price whole. A Forever
  change to either is a clash to blend. Tested in
  `tools/test_legacyscan.lua`.
- Listing works on Era (2026-10-25, the owner: Yes on the box did
  nothing): `Posting:Post` lists through `LegacyStart` (the bag slot into
  the auction slot, then `PostAuction` with the stack's price as bid and
  buyout, one stack a click; never `StartAuction` while `PostAuction` is
  there, since Era refuses the old name with the game's "This addon has been
  disabled" box, seen the same day) when `Posting.IsLegacy()`; `GetSellInfo` asks
  no item location there. List Next's first click checks the Sell list one
  item at a time (`Posting:CheckAllLegacy`, each search by name, at most
  `LEGACY_CHECK_WAIT` seconds each, said once when done), so the clicks and
  wheel turns after it list with no box; while it runs a click waits
  (`Posting:CheckingAll`). Your auctions are read from Era's own list
  (`Auctions.LegacyOwnedInfo`, `GetNumAuctionItems("owner")`,
  `AUCTION_OWNED_LIST_UPDATE`), so a listing is confirmed. A stack is
  never put in the auction slot and listed in the same click: Era answers
  "Internal auction error" (seen the same day). `Posting:PrepareNext` puts
  the next stack in ahead (after the price check and a second after each
  listing), and a click lists only once the slot has taken it
  (`NEW_AUCTION_UPDATE`, else `HELD_SETTLE` seconds); a stack not yet in
  goes in and the click says "ready to list". Tested in
  `tools/test_legacypost.lua`.
- Scan works on Era (2026-10-25, the owner picked "full scan, page scan
  backup"): `Data/LegacyScan.lua` asks for the quick full scan
  (`QueryAuctionItems` with getAll) when `CanSendAuctionQuery` says it is
  free, else reads page by page, 50 rows a page, each page sent only when
  the game takes a query. `Scanner:StartFullScan` hands over to it when
  `auction.mode` is "legacy", and the rows go through
  `Scanner:ReadReplicateResults` (now with a `source`), a few a frame, into
  the same prices. The player's own search mid-scan is caught by a
  post-hook on `QueryAuctionItems`: a page is asked again, and nothing is
  marked sold out. No new words. Tested in `tools/test_legacyscan.lua`.

### Tests
- `tools/test_era.lua` checks the TOC and loads every file it lists, then
  logs in, with no sister addon and no `C_AuctionHouse` (a loose client of
  its own, since this repo has no shared one).

### Notes and docs
- `CLAUDE.md` opens with "This repo is the Classic Era copy".
- `README.md` names the Classic CurseForge project.
- `docs/handoff/classic-port.md` is the plan.

### Discord release posts
- `tools/announce_discord.py` and `tools/post_general.py` start both
  posts with "Classic Era: " (their `GAME`), where Forever's start with
  "Forever: ", so the two games' releases read apart. A catch-up that
  touches these tools keeps Classic's word. Tested in
  `tools/test_announce_discord.py` and `tools/test_post_general.py`.

### No Forever words for players
- The owner asked (2026-10-24) for no "Forever" a player can see. A recipe
  marked `forever` gets no "New on Forever" line in `RecipeBook:LearnFrom`
  (none ships on Era, but one could come from a catch-up). A catch-up that
  brings the lines back keeps Classic's. Tested in
  `tools/test_foreverrecipes.lua`. The TOC's Notes line ends "keeps a
  craft queue." with no "for WoW: Forever".
- The About thank-you (`About.THANKS`) has no "WoW Forever is almost here"
  paragraph (the owner, 2026-10-24). `UI/About.lua` is shared with Forever;
  a catch-up that brings the paragraph back keeps Classic's.

- A vendor's list is read with `GetMerchantItemInfo` when the client has
  no `C_MerchantFrame.GetItemInfo` (Era), laid into the same shape
  (`Vendor.MerchantItemInfo` in `Data/Vendor.lua`), so the Buy materials
  run and Butler's Buy button work at Era's vendors. A catch-up that brings
  `Vendor:Scan` back keeps the fallback. Tested in
  `tools/test_eramerchant.lua`.

- One-word names (the owner, 2026-10-25): Era characters have one name.
  The mail panel no longer asks for a last name, the account link hint
  asks for names only, and a record without a GUID reads "older record".

- Friends (the owner, 2026-10-25; Classic only): "Friends:" on the Sharing
  page (`friendNames`, never rename it). A friend's recipes come by whisper
  (`GuildCrafters:HelloFriends`, `WhoCanMakeFriends`) and show as "Friends
  who can make it:" on the Profit tab; nothing of theirs is saved. A name
  there is never an account link partner, and copies it sent before are
  moved to `friendCopies[guid]` (`AccountLink:SetAsideFriends`, never
  rename it), out of the Characters list but not deleted. Tested in
  `tools/test_friends.lua`.

## Not yet done
- Steps 4 (the auction house), 5 (the probe in Era) and
  6 (data from Era's tables, such as recipe skills in `Data/LearnSpots.lua`)
  in `docs/handoff/classic-port.md`. Each adds its line here.
- Calls to the other Blackthornes addons stay in a pcall, and Tradeskills
  works alone.
- Not yet seen in an Era client. Client calls are read in a pcall.
- Profession names in the Level Up and Profit menus: Era has no call that
  names a skill line by ID, so `EraRecipes:LineName` gives the client's own
  word (the spell the profession teaches, else the skill list), then the
  book's English name.
