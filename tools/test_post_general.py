"""Tests for tools/post_general.py. Run: python tools/test_post_general.py"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from announce_discord import section  # noqa: E402
from post_general import main, message, names_a_player, not_clear, without_thanks  # noqa: E402

NEWS = ("# News\n\n## 0.2.0\n\n- The map shows\n  herbs again.\n- Goals sort by name.\n\n"
        "Thanks @everyone for the reports!\n\n## 0.1.0\n\nFirst.\n")

checks = 0
failures = 0


def expect(label, ok):
    global checks, failures
    checks += 1
    if not ok:
        failures += 1
        print("FAIL: " + label)


post = section(NEWS, "0.2.0")
body = message("Blackthornes Farmer", "0.2.0", post)
lines = body["content"].split("\n")
expect("opens with the addon and version, pointing to #announcements",
       lines[0] == "**Classic Era: Blackthornes Farmer 0.2.0** (full list of changes in #announcements)")
expect("the bullets follow, wrapped lines joined",
       lines[1] == "- The map shows herbs again." and lines[2] == "- Goals sort by name.")
expect("the thanks line is left out (the bot posts it with @mentions)",
       lines[-1] == "- Goals sort by name." and "Thanks" not in body["content"])
expect("a named thanks is left out too",
       "Ana" not in message("Blackthornes Farmer", "0.2.0", "- Fixed.\n\nThanks Ana and Bob for the reports!")["content"])
expect("a bullet that says thanks stays",
       "- Thanks to a fix" in message("x", "0.2.0", "- Thanks to a fix, it loads.")["content"])
expect("no CurseForge link", "curseforge" not in body["content"].lower())
expect("no link previews or cards", body["flags"] == 4)
expect("nothing in it can ping", body["allowed_mentions"] == {"parse": []})
expect("posted as the house name", body["username"] == "Blackthornes AddOns")
expect("no title, still the version", message(None, "0.2.0", "- Hi.")["content"].startswith("**Classic Era: 0.2.0** ("))
long_post = "\n\n".join("Paragraph %d of a very long post about the update." % i for i in range(200))
expect("a long post fits in one message", len(message("Blackthornes Farmer", "0.2.0", long_post)["content"]) <= 2000)

expect("only the thanks paragraph goes", without_thanks(post) == "- The map shows\n  herbs again.\n- Goals sort by name.")
expect("a plain post is clear to post", not_clear(post) == [])
expect("a Windows path is caught", "a Windows path" in not_clear("See D:\\Games\\WoW for it."))
expect("an email address is caught", "an email address" in not_clear("Mail me at someone@example.com"))
expect("the owner's name is caught", "the owner's name" in not_clear("Thanks, " + "Tr" + "ent"))

expect("a thanked player is caught", names_a_player("Thanks Ana for the idea!") == ["Ana"])
expect("thanks after a comma is caught", names_a_player("Thanks, Bob27!") == ["Bob27"])
expect("requested by a player is caught", names_a_player("Requested by Cara.") == ["Cara"])
expect("a player's request is caught", names_a_player("It was Dax's request.") == ["Dax"])
expect("a Discord handle is caught", names_a_player("@eli found it") == ["eli"])
expect("thanking everyone is fine", names_a_player("Thanks everyone! Thanks again.") == [])
expect("thanking the players who reported it is fine",
       names_a_player("Thanks to the players who reported it.") == [])
expect("game names are fine", names_a_player("Get the cloak from Ghost Howl in Mulgore.") == [])

os.environ.pop("DISCORD_GENERAL_WEBHOOK_URL", None)
expect("without the secret it does nothing and succeeds", main(["x", "v0.2.0"]) == 0)
expect("a bad tag is refused", main(["x", "next"]) == 2)

print("  post_general: %d checks, %d failure(s)" % (checks, failures))
sys.exit(1 if failures else 0)
