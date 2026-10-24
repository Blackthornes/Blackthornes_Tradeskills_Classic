"""Post a new version's changelog to the Discord #announcements channel.

Run by .github/workflows/release.yml after the upload:

    python tools/announce_discord.py v0.2.0

It posts through a channel webhook kept in the DISCORD_WEBHOOK_URL repository
secret, which the owner makes in Discord (#announcements > Edit Channel >
Integrations > Webhooks) and pastes into GitHub himself. Without the secret it
does nothing, so the release works the same as before.

The text is the version's CHANGELOG.md section, which the clear-to-post check
has already passed inside the package. Mentions are switched off, so nothing
in it can ping the server.
"""

import glob
import json
import os
import re
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TAG = re.compile(r"^v(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)$")
HEADING = re.compile(r"^##\s+v?(\S+)")
GAME = "Classic Era"  # leads every post, so each game's releases read apart
GOLD = 0xE8B530
LIMIT = 3800  # Discord allows 4096 in an embed's text; leave room for the link


def section(changelog, version):
    """The changelog text under '## <version>', up to the next '## ', or None."""
    lines, found = [], False
    for line in changelog.splitlines():
        match = HEADING.match(line)
        if match:
            if found:
                break
            found = match.group(1) == version
            continue
        if found:
            lines.append(line)
    return "\n".join(lines).strip() if found else None


def unwrap(text):
    """Join the changelog's hard-wrapped lines: Discord shows every line break."""
    out = []
    for line in text.splitlines():
        stripped = line.strip()
        starts_item = re.match(r"^(?:[-*+]|\d+\.)\s", stripped) or stripped.startswith("#")
        if out and out[-1] and stripped and not starts_item:
            out[-1] += " " + stripped
        else:
            out.append(line.rstrip())
    return "\n".join(out)


def toc_field(toc, name):
    match = re.search(r"^##\s*%s:\s*(.+?)\s*$" % re.escape(name), toc, re.M)
    return match.group(1) if match else None


def message(title, project_id, version, notes):
    """The webhook body for one release."""
    url = "https://www.curseforge.com/projects/%s" % project_id if project_id else None
    text = unwrap(notes) if notes else "A new version is out."
    if len(text) > LIMIT:
        cut = text.rfind("\n", 0, LIMIT)
        text = text[:cut if cut > 0 else LIMIT].rstrip() + "\n..."
    if url:
        text += "\n\n[Download on CurseForge](%s)" % url
    embed = {"title": "%s: %s %s%s" % (GAME, title, version, " (beta)" if "-" in version else ""),
             "description": text, "color": GOLD}
    if url:
        embed["url"] = url
    return {"username": "Blackthornes AddOns", "embeds": [embed],
            "allowed_mentions": {"parse": []}}


def main(argv):
    if len(argv) != 2 or not TAG.match(argv[1]):
        print("usage: python tools/announce_discord.py v0.2.0")
        return 2
    hook = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
    if not hook:
        print("No DISCORD_WEBHOOK_URL secret; not announcing on Discord.")
        return 0
    version = TAG.match(argv[1]).group(1)
    with open(os.path.join(ROOT, "CHANGELOG.md"), encoding="utf-8") as f:
        notes = section(f.read(), version)
    with open(glob.glob(os.path.join(ROOT, "*.toc"))[0], encoding="utf-8") as f:
        toc = f.read()
    title = toc_field(toc, "Title") or "Blackthornes"
    body = json.dumps(message(title, toc_field(toc, "X-Curse-Project-ID"), version, notes))
    req = urllib.request.Request(hook + ("&" if "?" in hook else "?") + "wait=true",
                                 data=body.encode("utf-8"), method="POST",
                                 headers={"Content-Type": "application/json",
                                          "User-Agent": "Blackthornes release"})
    try:
        with urllib.request.urlopen(req, timeout=30):
            pass
    except urllib.error.HTTPError as err:
        # Never print the webhook address: it is the secret.
        print("Discord refused the announcement (%d): %s"
              % (err.code, err.read().decode("utf-8", "replace")[:300]))
        return 1
    except urllib.error.URLError as err:
        print("Could not reach Discord: %s" % err.reason)
        return 1
    print("Announced %s %s on Discord." % (title, version))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
