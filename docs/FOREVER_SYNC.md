# Forever sync

Where this Classic Era copy stands against Forever Tradeskills
(`Blackthornes/Blackthornes_Tradeskills`). Forever is only ever read from here.

Last Forever commit copied over: `94517cf` (Forever main, the merge of its
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

Every catch-up reads `docs/CLASSIC_DIFFERENCES.md` first, and the PR that
brings Forever commits over updates the line above to the newest one it took.
