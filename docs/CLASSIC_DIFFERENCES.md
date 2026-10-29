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
- With those gone, `UI/Tab_Deals.lua` registers the Favors and Writs tab
  only with the flips or one of its views, and `UI/Tab_Settings.lua` shows
  the "Crate Costs:" row only with `ns.MerchantsFavor`. The drawer's Favors
  switch never shows. Saved settings for them (`favorGoal`, `writGoal`,
  `merchantsFavor`) stay in the save, unread.
- A Forever change to any of these features is "Forever only, skip"; one to
  the tab or Settings row around them is a clash to blend, keeping the guard.

### Sending data to Blackthornes goes to Era characters
- `Logic/Contribute.lua` is in the TOC again (2026-10-26). Its
  `RECIPIENTS` names the owner's own Era characters as Name-Realm, never
  Forever's. Keep this list on a catch-up.
- Era characters have no last name and a whisper only reaches its own
  realm, so `Contribute:Recipients()` keeps only names on the realm of the
  character playing (`RealmKey`, `MyRealm`; none when the realm can't be
  read), and `Receiving()` needs no space in the name. The About page's
  tick box shows only while someone is named (`UI/Tab_Settings.lua`), so
  players on other realms don't see it.
- `Contribute.REGIONS` is only `[1]`; Forever's test client region 110 is gone.
- Tested in `tools/test_contribute.lua` and `tools/test_era.lua`.

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
- `DoCraft` is the game's own: from addon code, even on a click, it is
  blocked ("only available to the Blizzard UI", 2026-10-29). So an enchant
  is only picked in the Enchanting window (`EraRecipes:SelectCraftLine`),
  and `UI/SecureCraft.lua` lays an invisible secure button over our Craft
  buttons (Queue tab, Level Up, the craft pane) while the mouse is on one
  whose craft is an enchant. Its PreClick calls `Crafting:Start(id, n,
  true)`, then its macro, `/click CraftCreateButton`, presses the window's
  Create button. `Crafting:Start` refuses an enchant without that third
  argument, and Butler's Craft opens the Queue tab for one.
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
  goes in and the click says "ready to list". Since 2026-10-26 (the
  owner: every listing took two presses) `Posting:PrepareFor` also puts
  it in when the Sell list draws (`PostPanel:UpdateListAll`, next frame)
  and as the mouse goes over List Next or a row's List, so a press lists
  at once; it leaves a fight, the cursor, an item put in by hand and a
  Yes/No box for another item alone. Since 2026-10-29 (the owner: posting
  felt clunky, hovering swapped stacks) a stack already in the slot is
  never swapped by a hover or a redraw, only by a click on another row,
  and the slot emptying after a listing (`NEW_AUCTION_UPDATE`) puts the
  next stack in at once. While a listing goes in and the next stack
  settles (`Posting:Settling`, at most `SETTLE_WAIT` seconds), List Next
  and the rows' List buttons go grey (`PostPanel.Grey`, from
  `PostPanel:UpdateWaitLabels`) and a press or wheel notch does nothing,
  so the first one once ready lists (`AuctionWheel:List`). Tested in
  `tools/test_legacypost.lua` and `tools/test_auctionwheel.lua`.
- The AH buttons search on Era (2026-10-27, the owner: the AH search
  button did nothing, "the auction house stayed busy" in chat):
  `UI:SearchAuctionHouse` hands a "legacy" client to `LegacyScan:Browse`,
  which sends `QueryAuctionItems` by the item's name, page one, once the
  game takes a query, so the results land in the game's own Browse list.
  It never touches the game's frames. Forever's `SendBrowseQuery` path is
  left as it was. Tested in `tools/test_legacyscan.lua`.
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
- Buying the queue's materials works on Era (the owner said build it,
  2026-10-27). Era sells whole stacks, each at its own price, so a click
  on a row of the drawer's Buy view (or its Search) opens a plan at the
  foot of the list (`UI/LegacyBuyView.lua`): `Logic/LegacyBuy.lua` reads
  every page of the item by its exact name and `LegacyBuy.Plan` picks the
  cheapest stacks that cover the need, at most a quarter over it
  (`EXTRA`; with nothing inside that, the least extra there is), leaving
  out the player's own and any over half again the usual price
  (`TOO_DEAR`). The gold button buys one stack a click
  (`PlaceAuctionBid` at its buyout, the row read again first); a stack
  gone or moved is looked for again and the plan redone. `AHBuys` counts
  Era buys from a post-hook on `PlaceAuctionBid`, so they are looked for
  in the mailbox. Forever's Buy view is untouched. Tested in
  `tools/test_legacybuy.lua`.
- Era fills in a seller's name a moment after the row (bug pass,
  2026-10-27). The buy plan and the price check read a page once more when
  a row of the item has no seller yet, so your own stacks are known as
  yours, and the plan's `Same` counts a name missing on either side as no
  mismatch. Short of gold, Buy bids nothing and says "not enough gold on
  you". After three looks that can't find the next stack, the button stays
  pressable and a press looks again from the start (`state.stuck`). A long
  name on a stack row drops a size and wraps (`Theme.SetRowName`). Tested
  in `tools/test_legacybuy.lua` and `tools/test_legacyscan.lua`.

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

- Arrow Size (from Forever, 2026-10-28): Forever's choices are 50%, 75% and
  100%, 100% usual. Era's arrow already stood at 65%, so here the choices
  are 50%, 65% and 100%, and 65% is the usual size that saves nothing
  (`ArrowUI.USUAL`). A catch-up keeps that.

- Ask Before Listing (from Forever, 2026-10-28): Forever's box is off
  unless ticked and "Fast listing" no longer matters to it. Era keeps #47
  too: with "Fast listing" unticked the box still comes back
  (`Posting:AsksFirst`), and a checked price says "ready to list" with the
  stack put in Era's auction slot, so the next click lists.

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

### No Forever zones in the map list

Forever added its own zones (Mount Hyjal, Zephras Isle, Riverglades,
Shen'dralas) to `Waypoints.ZONE_MAPS` with its marker fix (2026-10-29).
Era has none of them, so Classic's list stays as it was. A catch-up that
adds them again leaves them out.

### Potential Sale Total

The owner renamed the drawer's counter "Potential Sale Total:" and took
out the line under the number (2026-10-29). Only the label and the number
show; what is still on the Sell list is on the hover. A catch-up that
brings Forever's "Sale Total:" or its "of X" / "all listed" line back
leaves them out.

### Disenchant results on tooltips

Classic only (a player asked, the owner said build it, 2026-10-29): on a
character that knows Disenchant, an item's tooltip lists each thing it can
break into, its count and its chance, under "Disenchant value"
(`ItemTooltip:AddDisenchantResults`, from `Disenchant:GetOutcomes`, the
same chances as the Disenchanting tab). "Disenchant Results on Tooltips:"
on the Look page, Off, Shift or Always, Shift unless picked
(`tooltipDisenchantResults`, `tooltipDisenchantShift`; never rename
them). Tested in `tools/test_disenchantresults.lua`. A catch-up keeps it.

### The craft pane beside Enchanting

Classic only (the owner said build it, 2026-10-29): Era's Enchanting has a
window of its own (`CraftFrame`, `CRAFT_SHOW`/`CRAFT_CLOSE`), so the craft
pane opens beside it too. With both windows open it docks to the one opened
last, and moves to the other when that one closes (`CraftPanel:WindowShown`,
`WindowClosed`, `eraOpen`, `eraLast`; `FindTradeSkillFrame` answers only an
open window on Era). Tested in `tools/test_enchantpane.lua`. A catch-up
keeps it.

### Buy plans one after another

Classic only (the owner said build it, 2026-10-29): once Era's buy plan
is done, its gold button reads "Next: NAME" and opens the next Buy line
still to buy (`PostPanel:NextBuyLine`, `LegacyBuyView.nextLine`). With the
drawer up, the AH buttons on the Queue panel, the Gather tab and the Lists
open that item's plan on Buy (`UI:SearchOrPlan`, `PostPanel:OpenBuyPlan`)
instead of a Browse search, and the search buttons' hover is "Searches the
auction house." (`PostPanel.SearchTip`). Tested in
`tools/test_buyplannext.lua`. A catch-up keeps it.
