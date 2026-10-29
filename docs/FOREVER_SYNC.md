# Forever sync

Where this Classic Era copy stands against Forever Tradeskills
(`Blackthornes/Blackthornes_Tradeskills`). Forever is only ever read from here.

Last Forever commit copied over: `57fb2bc` (Forever main, 2026-10-28).
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

Every catch-up reads `docs/CLASSIC_DIFFERENCES.md` first, and the PR that
brings Forever commits over updates the line above to the newest one it took.
