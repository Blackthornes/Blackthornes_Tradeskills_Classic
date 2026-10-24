"""Refuse to release a tag the changelog says nothing about.

Run by .github/workflows/release.yml before anything is packaged:

    python tools/check_release.py v0.2.0

The tag must look like vMAJOR.MINOR.PATCH (a suffix such as -beta1 is allowed,
and makes the packager mark the upload as a beta), and CHANGELOG.md must open
with a section for that version, "## 0.2.0" or "## 0.2.0 - 2026-09-25". That
is what players read on CurseForge, so a release without it is refused rather
than shipped with last version's notes.

It also refuses a CHANGELOG.md section that credits a player by name: a
player's name never goes in a report (only the #general post thanks them).

It also warns, without refusing, when this version's CHANGELOG.md or NEWS.md
section says "German" without "Deutsch": the posts call the language Deutsch
(the owner, 2026-10-11), or "Deutsch (German)" where English readers need it.

It also checks the TOC still says `## Version: @project-version@`: a version
typed in by hand would disagree with the tag the packager builds.

It also checks Core/WhatsNewText.lua, the in-game What's New window's
notes, is what tools/make_whatsnew.py writes from NEWS.md.

And it checks `ns.RELEASED_VERSION` in Core/Init.lua is the tag's version:
played from a checkout, that is the version the addon shows, so the release
PR that writes the CHANGELOG.md section changes it in the same breath.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TAG = re.compile(r"^v(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)$")
HEADING = re.compile(r"^##\s+v?(\S+)")
RELEASED = re.compile(r'^ns\.RELEASED_VERSION\s*=\s*"([^"]*)"', re.M)

# Forever Tradeskills' CurseForge project. This repo is the Classic Era copy.
FOREVER_PROJECT = "1710638"


def released_version(init):
    """The version Core/Init.lua shows from a checkout, or None."""
    match = RELEASED.search(init or "")
    return match and match.group(1)


def check(tag, changelog, toc, init=None):
    """Return a list of problems; empty means the tag can be released."""
    match = TAG.match(tag)
    if not match:
        return ["tag %r is not like v0.2.0 (or v0.2.0-beta1)" % tag]
    version = match.group(1)

    problems = []
    headings = [HEADING.match(line).group(1)
                for line in changelog.splitlines() if HEADING.match(line)]
    if not headings:
        problems.append("CHANGELOG.md has no '## <version>' sections")
    elif headings[0] != version:
        if version in headings:
            problems.append("CHANGELOG.md has %s, but not as the newest "
                            "section at the top (that is %s)"
                            % (version, headings[0]))
        else:
            problems.append("CHANGELOG.md has no section for %s; add "
                            "'## %s' at the top saying what changed"
                            % (version, version))

    if not re.search(r"^## Version: @project-version@\s*$", toc, re.M):
        problems.append("Blackthornes_TS.toc must say "
                        "'## Version: @project-version@' so the tag sets it")

    # The Classic Era copy must never upload to the Forever project on CurseForge.
    if re.search(r"^## X-Curse-Project-ID:\s*%s\b" % FOREVER_PROJECT, toc, re.M):
        problems.append("Blackthornes_TS.toc names the Forever project "
                        "(%s); the Classic Era copy needs its own" % FOREVER_PROJECT)

    if init is not None and released_version(init) != version:
        problems.append("Core/Init.lua says ns.RELEASED_VERSION = %r; make it "
                        "%r, the version a checkout shows" % (released_version(init), version))
    return problems


def named_players(tag, changelog):
    """A player's name never goes in a report (the owner, 2026-10-09): look in
    this version's CHANGELOG.md section, which goes to CurseForge and
    #announcements, for a credited player. NEWS.md, the #general post, is the
    one place players are thanked by name, so it is not checked."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from announce_discord import section
    from post_general import names_a_player
    match = TAG.match(tag)
    if not match:
        return []
    return ["CHANGELOG.md names a player (%s); thank them in NEWS.md instead"
            % player for player in names_a_player(section(changelog, match.group(1)) or "")]


def language_warnings(tag, changelog, news):
    """The language is "Deutsch" in every post (the owner, 2026-10-11), or
    "Deutsch (German)" where English readers need the hint. A warning, not a
    refusal: this version's CHANGELOG.md (#announcements) or NEWS.md
    (#general) section saying German without Deutsch."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from announce_discord import section
    match = TAG.match(tag)
    if not match:
        return []
    warnings = []
    for name, text in (("CHANGELOG.md", changelog), ("NEWS.md", news)):
        body = section(text or "", match.group(1)) or ""
        if re.search(r"\bGerman\b", body) and "Deutsch" not in body:
            warnings.append('%s says "German" without "Deutsch"; call the '
                            'language Deutsch, or "Deutsch (German)"' % name)
    return warnings


def main(argv):
    if len(argv) != 2:
        print("usage: python tools/check_release.py v0.2.0")
        return 2
    with open(os.path.join(ROOT, "CHANGELOG.md"), encoding="utf-8") as f:
        changelog = f.read()
    with open(os.path.join(ROOT, "Blackthornes_TS.toc"), encoding="utf-8") as f:
        toc = f.read()
    news = ""
    if os.path.exists(os.path.join(ROOT, "NEWS.md")):
        with open(os.path.join(ROOT, "NEWS.md"), encoding="utf-8") as f:
            news = f.read()
    for warning in language_warnings(argv[1], changelog, news):
        print("Warning: " + warning)
    with open(os.path.join(ROOT, "Core", "Init.lua"), encoding="utf-8") as f:
        init = f.read()
    problems = check(argv[1], changelog, toc, init) + named_players(argv[1], changelog)
    # The in-game What's New window ships NEWS.md as Core/WhatsNewText.lua;
    # a release whose file is behind NEWS.md would show last version's news.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import make_whatsnew
    problems += make_whatsnew.problems()
    for problem in problems:
        print("Not releasing: " + problem)
    if not problems:
        print("%s is ready to release." % argv[1])
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
