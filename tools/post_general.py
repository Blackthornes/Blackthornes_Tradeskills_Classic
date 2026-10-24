"""Post a new version's friendly news to the Discord #general channel.

Run by .github/workflows/release.yml after the upload, next to
announce_discord.py (which posts the full changelog in #announcements):

    python tools/post_general.py v0.2.0

The text is the version's section of NEWS.md: a few short bullets in plain
words for players, written with the CHANGELOG section in each release PR,
ending with the thanks. The post opens with the addon's name and version, so
each addon's bullets read as their own group, and that line points players to
#announcements for the full list. No CurseForge link and no link preview, so
the post stays small (the owner, 2026-10-10). A version with no NEWS.md
section posts nothing.

The thanks line is left out of this post (the owner, 2026-10-13): he wants
each player thanked with a real @mention, so they get a notification, and a
mention needs their Discord ID, which never goes in a public repo. His bot,
on his PC, posts the thanks under this post once he approves the wording, and
looks the names up there.

It posts through a channel webhook kept in the DISCORD_GENERAL_WEBHOOK_URL
repository secret, which the owner makes in Discord (#general > Edit Channel >
Integrations > Webhooks) and pastes into GitHub himself. Without the secret it
does nothing. NEWS.md does not ship in the package, so before posting the
text gets the same clear-to-post scan the package gets (check_package.py's
PRIVATE list), and anything it finds stops the post. This post is the one
place a player is named: NEWS.md's thanks line names, by their Discord
name, whoever asked for or reported each change (the owner, 2026-10-09), and
the bot reads it from there. Mentions are switched off, so nothing in this
post can ping the server.
"""

import glob
import json
import os
import re
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from announce_discord import TAG, section, toc_field, unwrap  # noqa: E402
from check_package import PRIVATE  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIMIT = 1800  # Discord allows 2000 characters in a message; leave room for the heading
POINTER = "(full list of changes in #announcements)"
GAME = "Classic Era"  # leads every post, so each game's releases read apart
SUPPRESS_EMBEDS = 4  # Discord's message flag: no link previews or cards

# A player's name never goes in a report (the owner, 2026-10-09), except this
# #general post, which thanks them; check_release.py uses this on CHANGELOG.md.
# Names can't be listed here without naming players, so this looks for the
# shapes a name takes when someone is credited.
CREDIT = [
    re.compile(r"\b(?i:thanks|thank you|shout[- ]?out)[,!]?\s+(?:to\s+)?@?([A-Z][\w-]{2,})"),
    re.compile(r"\b(?i:requested|reported|asked|suggested|found|spotted|raised)\s+(?i:by)\s+@?([A-Z][\w-]{2,})"),
    re.compile(r"\b([A-Z][\w-]{2,})(?:'s|’s)\s+(?i:request|idea|report|suggestion|ask|bug)\b"),
    re.compile(r"(?<![\w.])@([A-Za-z][\w-]{2,})"),
]
NOT_NAMES = {"everyone", "everybody", "all", "you", "the", "our", "every",
             "players", "player", "discord", "curseforge", "blackthornes",
             "again", "so", "much", "for", "folks", "guys"}


def names_a_player(text):
    """The words that look like a credited player's name, or an empty list."""
    found = []
    for pattern in CREDIT:
        for name in pattern.findall(text or ""):
            if name.lower() not in NOT_NAMES and name not in found:
                found.append(name)
    return found


def not_clear(text):
    """What the clear-to-post scan finds in the post, as a list of labels."""
    return [label for label, pattern in PRIVATE if pattern.search(text)]


THANKS = re.compile(r"^\s*(?:thanks|thank you|shout[- ]?out)\b", re.I)


def without_thanks(post):
    """The post with its thanks paragraph left out: the bot on the owner's PC
    posts the thanks with real @mentions instead."""
    paragraphs = re.split(r"\n\s*\n", (post or "").strip())
    return "\n\n".join(p for p in paragraphs if not THANKS.match(p)).strip()


def message(title, version, post):
    """The webhook body: the addon and version with the pointer to
    #announcements, then the post as written. No link and no card."""
    text = unwrap(without_thanks(post))
    if len(text) > LIMIT:
        cut = text.rfind("\n", 0, LIMIT)
        text = text[:cut if cut > 0 else LIMIT].rstrip() + "\n..."
    heading = ("**%s: %s %s**" % (GAME, title, version) if title
               else "**%s: %s**" % (GAME, version))
    text = "%s %s\n%s" % (heading, POINTER, text)
    return {"username": "Blackthornes AddOns", "content": text,
            "flags": SUPPRESS_EMBEDS, "allowed_mentions": {"parse": []}}


def main(argv):
    if len(argv) != 2 or not TAG.match(argv[1]):
        print("usage: python tools/post_general.py v0.2.0")
        return 2
    hook = os.environ.get("DISCORD_GENERAL_WEBHOOK_URL", "").strip()
    if not hook:
        print("No DISCORD_GENERAL_WEBHOOK_URL secret; not posting in #general.")
        return 0
    version = TAG.match(argv[1]).group(1)
    path = os.path.join(ROOT, "NEWS.md")
    post = None
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            post = section(f.read(), version)
    if not post:
        print("NEWS.md has no section for %s; nothing to post in #general." % version)
        return 0
    found = not_clear(post)
    if found:
        print("Not posting in #general: the post holds %s." % ", ".join(found))
        return 1
    with open(glob.glob(os.path.join(ROOT, "*.toc"))[0], encoding="utf-8") as f:
        toc = f.read()
    body = json.dumps(message(toc_field(toc, "Title"), version, post))
    req = urllib.request.Request(hook + ("&" if "?" in hook else "?") + "wait=true",
                                 data=body.encode("utf-8"), method="POST",
                                 headers={"Content-Type": "application/json",
                                          "User-Agent": "Blackthornes release"})
    try:
        with urllib.request.urlopen(req, timeout=30):
            pass
    except urllib.error.HTTPError as err:
        # Never print the webhook address: it is the secret.
        print("Discord refused the #general post (%d): %s"
              % (err.code, err.read().decode("utf-8", "replace")[:300]))
        return 1
    except urllib.error.URLError as err:
        print("Could not reach Discord: %s" % err.reason)
        return 1
    print("Posted %s news in #general." % version)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
