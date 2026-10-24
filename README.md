# Blackthornes_Tradeskills

Tradeskill addon for WoW: Forever. It works out which crafts are worth making,
scans the auction house for the prices that answer depends on, and manages a
craft queue, a shopping list and a posting list around it.

Built without Ace3 or LibStub, because neither is known to work on Forever yet.
The small framework in `Core/` is written for this addon instead, so it does not
have to wait for anyone else to update theirs.

## Layout

| Folder | What is in it |
|---|---|
| `Core/` | Slash commands, settings, checking what the game supports, saving your data between sessions, and spacing out requests to the auction house |
| `Data/` | Everything read from the game: prices, auction scans, recipes, bags and bank, your own listings, vendor prices |
| `Logic/` | Craft cost, profit, the queue, starting crafts, posting, and export/import |
| `UI/` | Theme, reusable widgets, the main window, the auction house side panel, and the seven tabs |
| `Probe/` | `/bts probe`, which checks what the running game actually supports instead of guessing |

`Blackthornes_TS.toc` lists every Lua file in load order. A file that is not in
it does not load, and WoW says nothing about it.

## Development

Not shipped to the client: `tools/`, `docs/`, `deploy.ps1`. `deploy.ps1`
excludes them.

```powershell
.\deploy.ps1              # syntax check, lint, then mirror into Interface\AddOns
.\deploy.ps1 -SkipCheck   # skip the checks (not recommended)
```

```bash
python tools/syntaxcheck.py   # parse every Lua file with a real 5.1 parser
python tools/lintcalls.py     # find calls to methods, and constants, never defined
python tools/runtests.py      # run the pure-logic tests outside WoW
```

These checks matter because WoW quietly turns off an addon when one of its
files has a typo in it, and a call to a function that no longer exists only
fails when that line of code runs.

`tools/` requires `lupa` (`python -m pip install --user lupa`).

## A note on saved data

Since WoW: Forever build 1.60.1.70009 (2026-09-24) the game keeps the addon's
saved data (`BlackthornesTSDB` and `BlackthornesTSCharDB`) across a restart,
so nothing else is needed. The old workarounds, a generated data addon and
storage in macros, were removed; `Core/OldMacros.lua` deletes the leftover
`BTSd` macros on a login where the saved data loaded. The CVar store in
`Core/Persist.lua` stays as a fallback and stands down whenever the saved data
loads. `/bts db` and `/bts persist` show what loaded.

## API findings

`docs/FOREVER_API_FINDINGS.md` records what the game actually does, as found
with `/bts probe` rather than taken from documentation. Read it before changing
anything to do with the auction house or professions.

## Releasing

Releases are cut by pushing a tag like `v0.2.0`.
`.github/workflows/release.yml` then:

1. refuses the tag unless `CHANGELOG.md` opens with a `## 0.2.0` section
   (`tools/check_release.py`);
2. runs the tests;
3. builds the player-facing zip with the
   [BigWigs packager](https://github.com/BigWigsMods/packager), uploading
   nothing;
4. checks that zip is clear to post (`tools/check_package.py`): only the
   addon's own files, and nothing that looks private, such as a Windows path,
   an email address, a saved-variables dump or a token;
5. only then uploads that same zip to CurseForge (project 1763353, Tradeskills Classic) and
   attaches it to a GitHub release.

To release from GitHub Desktop: add the new version's section to the top of
`CHANGELOG.md` and merge it to `main`, pull `main`, then **History**, right-click
the newest commit, **Create Tag...**, name it `v0.2.0`, and **Push origin**.

The version is never typed by hand. The TOC says
`## Version: @project-version@` and the packager fills in the tag. Running
straight from a clone there is no packager, so the addon shows
`ns.RELEASED_VERSION` from `Core/Init.lua`, the newest version in
CHANGELOG.md: the release PR changes both, and `tools/check_release.py`
refuses a tag they disagree with. The middle number moves for new
behaviour, the last for fixes alone; a tag like `v0.3.0-beta1` is uploaded as a beta.

`.pkgmeta` leaves `tools/`, `docs/`, `deploy.ps1` and this README out of the
zip. The upload needs the `CF_API_KEY` repository secret; without it the
workflow still builds and checks the zip but uploads nothing to CurseForge.

## For addon authors

Other addons can read Tradeskills' auction prices through one global. Check
that it exists, since Tradeskills may not be installed:

```lua
local api = BlackthornesTS_API
if api then
    local copper = api.GetPrice(2589)          -- item ID or item link; copper for one, or nil
    local age = api.GetPriceAge(2589)          -- seconds since this account's own scan saw it, or nil
end
```

- `GetPrice` is the market value Tradeskills itself uses: the player's own
  scans first, then guild prices and other price sources for items not
  scanned. It is per realm and faction.
- `GetPriceAge` is nil when the price did not come from this account's own
  scans.
- Neither call raises an error; anything it can't answer is nil.
- `BlackthornesTS_API.version` is 1. These calls will not be renamed or
  changed; new ones raise the version.
