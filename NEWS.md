# News

What each release says in the Discord server's #general channel: a few
short bullets per version, in plain words for players, saying what they'll
notice, then one line thanking, by their Discord name, everyone whose
feedback or report led to the changes (each name once; no line when nobody
asked). Each release PR writes the new version's section here next to its
CHANGELOG.md section, and after the upload `tools/post_general.py` posts it
under a line with the addon's name and version that points players to
#announcements for the full list. No link or addon card goes with it. This
is the only report that names players. A version with no section here posts
nothing in #general.
This file does not ship in the addon, but its newest sections do, without
the thanks line: `python tools/make_whatsnew.py` writes them into
Core/WhatsNewText.lua for the in-game What's New window. Run it after
writing a section; the release check refuses a tag while it is behind.

The window shows new features only. Write a section's features first, then
a "Fixes and changes:" line with the fixes and other changes under it: those
go to Discord but stay out of the window, and a section of only fixes puts
nothing in it. Say what each feature does in a few plain words, the way you'd
tell a friend: no hype, no questions to the reader, no exclamation marks
outside the thanks line, no dashes as punctuation, no "now you can". The
tool prints a note for a shipped line that reads like an advert.

## 0.5.0

- The Profit tab now has a Shuffles view.
- The auction house now shows a Sale Total counter.
- Posting to the auction house no longer asks Yes or No.
- You can set the highest price you will sell for.
- The guide arrow now comes in three sizes.

Fixes and changes:
- Various bug fixes.

## 0.4.0

- The Road to 300 and Learn Next now send you to the closest trainer.
- The Road to 300 lets you pick recipes by lowest cost or real cost.

Fixes and changes:
- Various bug fixes.

## 0.3.1

Fixes and changes:
- Various bug fixes.

## 0.3.0

- The auction house List button now lists in one press.
- The auction house Buy button buys your queue's materials stack by stack.
- Item tooltips show what a vendor sells the item for.

Fixes and changes:
- Various bug fixes.

## 0.2.1

Fixes and changes:
- Various bug fixes.

## 0.2.0

- The Road to 300 now tells you when you need to buy a recipe.

Fixes and changes:
- Various bug fixes.

## 0.1.2

Fixes and changes:
- Listing at the auction house no longer stops with an auction error.

## 0.1.1

Fixes and changes:
- Listing items at the auction house works now.

Thanks for trying it on Era.

## 0.1.0

- Tradeskills is here for Classic Era. Level Up shows the cheapest craft for your next skill point.
- Road to 300 lays out every step to 300 and what it costs.
- Learn Next shows which recipes to learn and where to find the trainer.
- The craft queue adds up your materials, and the Craft button crafts with one click.
- Scan the auction house for prices.

Thanks for trying it on Era.
