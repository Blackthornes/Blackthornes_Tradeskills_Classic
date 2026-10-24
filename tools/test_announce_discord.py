"""Tests for tools/announce_discord.py. Run: python tools/test_announce_discord.py"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from announce_discord import main, message, section, toc_field, unwrap  # noqa: E402

LOG = "# Changelog\n\n## 0.2.0 - 2026-09-30\n\n- New thing.\n- Fixed @everyone.\n\n## 0.1.0\n\n- First.\n"
TOC = "## Interface: 16001\n## Title: Blackthornes Example\n## X-Curse-Project-ID: 123\n"

checks = 0
failures = 0


def expect(label, ok):
    global checks, failures
    checks += 1
    if not ok:
        failures += 1
        print("FAIL: " + label)


expect("the newest section is found", section(LOG, "0.2.0") == "- New thing.\n- Fixed @everyone.")
expect("an older section stops at the end", section(LOG, "0.1.0") == "- First.")
expect("a missing section is None", section(LOG, "0.3.0") is None)
expect("the TOC title is read", toc_field(TOC, "Title") == "Blackthornes Example")
expect("the project ID is read", toc_field(TOC, "X-Curse-Project-ID") == "123")

body = message("Blackthornes Example", "123", "0.2.0", section(LOG, "0.2.0"))
embed = body["embeds"][0]
expect("titled with name and version", embed["title"] == "Classic Era: Blackthornes Example 0.2.0")
expect("links to CurseForge", embed["url"] == "https://www.curseforge.com/projects/123")
expect("the notes are posted", "- New thing." in embed["description"])
expect("nothing in it can ping", body["allowed_mentions"] == {"parse": []})
expect("a beta says so", "(beta)" in message("X", "1", "0.2.0-beta1", "x")["embeds"][0]["title"])
long_notes = "\n".join("- line %d of a long changelog" % i for i in range(400))
expect("long notes fit in an embed", len(message("X", "1", "1.0.0", long_notes)["embeds"][0]["description"]) < 4096)
expect("no project ID, no link", "url" not in message("X", None, "1.0.0", "x")["embeds"][0])

expect("wrapped lines are joined",
       unwrap("Restart the game\nafter updating.\n\n- One thing\n  goes on.\n- Two") ==
       "Restart the game after updating.\n\n- One thing goes on.\n- Two")

os.environ.pop("DISCORD_WEBHOOK_URL", None)
expect("without the secret it does nothing and succeeds", main(["x", "v0.2.0"]) == 0)
expect("a bad tag is refused", main(["x", "next"]) == 2)

print("  announce_discord: %d checks, %d failure(s)" % (checks, failures))
sys.exit(1 if failures else 0)
