# Forever sync

Where this Classic Era copy stands against Forever Tradeskills
(`Blackthornes/Blackthornes_Tradeskills`). Forever is only ever read from here.

Last Forever commit copied over: `d5455e9` (Forever main, 2026-11-14).
The first copy was made from `94517cf` (Forever main, the merge of its
PR #964, 2026-10-24). This copy was made from it with its history on
2026-10-24.

Copied over since, one at a time:
- `42521d9` Start release posts with the game name (2026-10-24, copied
  by hand with "Classic Era" in place of "Forever"; see
  `docs/CLASSIC_DIFFERENCES.md`).
- `6ee89ef`, `91ce852` Sending disenchants and recipe levels to
  Blackthornes, and faster (2026-10-26, `Logic/Contribute.lua` taken whole
  with Classic's own recipients, realm check and region; see "Sending data
  to Blackthornes goes to Era characters").
- `aba4139` Road to 300's "Pick By:" drop-down, Lowest Cost or Real Cost
  (2026-10-27, from Forever's testing branch, taken whole; it sits beside
  Classic's nearest-trainer pick from PR #43).
- Up to `57fb2bc` (Forever main, 2026-10-28), cherry-picked:
  - `6073644` Shuffles on the Profit tab, taken whole.
  - `05b616d`, `87123d2` Price limits: Highest, When Cheaper and percent
    floors, with their screens on the Prices tab and in list rules.
  - `803650f`, `fbac807`, `40e2fbf`, `328fbf8` the gold fold gem on the
    sell drawer and craft queue pane, and the house frame on the mail
    panels and Goal reached window.
  - `cadbb0c` Click Again on confirm buttons, List It or Skip on the
    listing pop-up; `1e6e117` the French and Spanish item line fix.
  - `7c449e3` the shared table built less often, a big one waited on
    longer, with Classic's own recipients, realm check and region kept.
  - `1213b7e` Arrow Size, with 65% as Era's usual size (see
    `docs/CLASSIC_DIFFERENCES.md`).
  - `f73ac60` Ask Before Listing, blended with Classic's #47 (see
    `docs/CLASSIC_DIFFERENCES.md`).
  Left out: `fcd2720` (Forever's recipient names), the changelog and
  release PRs, and `deploy.ps1`. Already here: Price Order, QueueLearned,
  the five-minute hello and Pick By.
- `b974d36` One minimap button for every Blackthornes addon (2026-10-28,
  Forever PR #1015, cherry-picked as it is; `UI/SharedMinimap.lua` and its test
  are the same in all five Classic repos).
- `9d90d31` Shared minimap button shows the Blackthornes thorn B (2026-10-29,
  taken as it is: `UI/SharedMinimap.lua` at FILE_VERSION 2,
  `Media/Frame/MinimapBadge.tga` and `tools/make_minimap_art.py`, the same
  in all five Classic repos).
- `cdc19b2` Slim the shared minimap menu: names only, sized to fit (2026-10-29,
  taken as it is: `UI/SharedMinimap.lua` at FILE_VERSION 3 and its test, the
  same in all five Classic repos).
- `97f8633` Time arrow flights by their real length (2026-10-29, as it is).
- `6c323db` Show the way lays our own map marker (2026-10-29; Forever's own
  zones left out of `ZONE_MAPS`; `UI/SpotMarker.lua` is the same in Farmer,
  Butler, Tradeskills and Pets Classic).
- `dea75f5` (Butler's) the way there card's rows grow when a step wraps
  (2026-10-29, `UI/TravelCard.lua` only).
- `7e928b9` Sale Total counts up in the drawer header as you list
  (2026-10-29, Forever PR #1027). `UI/SaleTotal.lua` and its test taken
  whole; Classic's own plaque from PR #50 goes, with its scan calls in
  `UI/Main.lua` and its words. The Settings row stays where Classic had it.
  The Sell list's title and summary leave the gold out while it shows, as
  Forever's had since its band.
- `d163db1` One look across the five addons (2026-10-29, Forever PR #1035):
  `UI/HouseKit.lua`, `UI/RowMenu.lua`, `UI/Notice.lua` and
  `UI/SharedChoices.lua` as they are (the same in all five Classic repos),
  the row menus, hover hints, Title Case buttons, the General page, the
  scan chip and Scan Auctions, the Prices tab's Stats view and the gold
  plaque on Buy Materials and Sell Marked. `UI/Plaque.lua` is the shared
  Classic copy (Farmer, Pets, Equipment). Kept Classic's: the real tabs on
  the Profit and Level Up switches (from #67 to #75), the TOOLTIPS page,
  and no version line past the portrait. The drawer's view tabs are Sell,
  Buy, Lists and Auctions; Favors never shows without Merchant's Favor.
- `41442e1` One Window steps aside for an open letter (2026-10-31): docked at
  the mailbox it moves beside the letter and back, and tells side panels
  when it docks, moves or undocks (`SharedWindow.Watch`, `DockedFrame`).
  `UI/SharedWindow.lua` is FILE_VERSION 5, the same in all five Classic
  repos. The queue's mail panel (`UI/QueueMailPanel.lua`) sits past the docked window at the mailbox, with `tools/test_queuemaildock.lua`.
- `18449eb` Bypass Disallowed Postings (not taken, 2026-10-31): Classic asks
  on the List click instead, with the List It or Skip box (see
  `docs/CLASSIC_DIFFERENCES.md`).
- `34b9a6a` Bypass Disallowed Postings, taken 2026-11-02 as "List Anyway:"
  (`postAnyway`, off unless ticked), blended by hand into Classic's
  `Logic/Posting.lua` beside the List It or Skip box; the label is
  translated fresh in all five locales, `tools/test_postanyway.lua` as is.
- `0df1229` Disenchant results on the tooltip show what one of each is
  worth ("%s each"), kept with Classic's header and Disenchant check.
- Picked fix (2026-11-07, the owner said yes): the folded One Window opens
  full after docking (Forever's shared `UI/SharedWindow.lua` fix, here at
  FILE_VERSION 8, the same in all five Classic repos).

- Forever catch-up of 2026-11-15 (the owner said do the week's ideas):
  about 60 commits from Forever main up to `d5455e9`, cherry-picked one at
  a time with Classic's code kept where they met: money box Tab keys,
  vendor pin icons, the second account's characters, whether Tradeskills
  opens by itself at the auction house and professions, the Sell list's
  skipped rows and Hidden Items window, Crafted Only and no greys on Sell,
  the account link's craft queue, sales, shopping lists, prices and last
  synced (kept beside Classic's Friends box), Road to 300 for Cooking,
  First Aid and Fishing, price graphs in Recipes to Learn and Your Time,
  the Sales tab's By Item view, Bought For on tooltips, Demand in Recipes
  to Learn, queue cast time, Road to 300 skip and trainer, where profit
  comes from, gold an hour, Disenchant Results in chat, Export and Import
  Prices, bind on pickup material costs, dropped professions, Profit by
  method by profession and character, Goblin Gold's goal window, Craft
  Next skipping crafts away from a tool, queue pause and moves, and Craft
  Cost and Profit. Missing words came from Forever's locale files by key.
  Not taken: `695619e` Buy Sets (the modern auction house) and `3671228`
  Ignore Deposit (Forever's deposit rework). Snipe, My Auctions, Auction
  Tracker, Legacy, writs and data refreshes were left out on purpose.

Every catch-up reads `docs/CLASSIC_DIFFERENCES.md` first, and the PR that
brings Forever commits over updates the line above to the newest one it took.
