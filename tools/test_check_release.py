"""Tests for tools/check_release.py. Run: python tools/test_check_release.py"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_release import check, released_version, HEADING, language_warnings  # noqa: E402

TOC = "## Interface: 11509\n## Version: @project-version@\n"
LOG = "# Changelog\n\n## 0.2.0 - 2026-09-30\n\n- New.\n\n## 0.1.0\n\n- First.\n"

checks = 0
failures = 0


def expect(label, ok):
    global checks, failures
    checks += 1
    if not ok:
        failures += 1
        print("FAIL: " + label)


expect("the newest version releases", check("v0.2.0", LOG, TOC) == [])
expect("a beta of it too", check("v0.2.0-beta1", LOG.replace("0.2.0 -", "0.2.0-beta1 -"), TOC) == [])
expect("an older version is refused", check("v0.1.0", LOG, TOC) != [])
expect("an unwritten version is refused", check("v0.3.0", LOG, TOC) != [])
expect("a tag without the v is refused", check("0.2.0", LOG, TOC) != [])
expect("a tag that is not a version is refused", check("vnext", LOG, TOC) != [])
expect("a changelog with no sections is refused", check("v0.2.0", "# Changelog\n", TOC) != [])
INIT = 'ns.RELEASED_VERSION = "0.2.0"\n'
expect("a matching released version releases", check("v0.2.0", LOG, TOC, INIT) == [])
expect("a released version left behind is refused",
       check("v0.2.0", LOG, TOC, INIT.replace("0.2.0", "0.1.0")) != [])
expect("a missing released version is refused", check("v0.2.0", LOG, TOC, "") != [])
expect("the Forever CurseForge project is refused",
       check("v0.2.0", LOG, TOC + "## X-Curse-Project-ID: 1710638\n") != [])
expect("another project is fine",
       check("v0.2.0", LOG, TOC + "## X-Curse-Project-ID: 999\n") == [])
expect("a hand-typed TOC version is refused",
       check("v0.2.0", LOG, TOC.replace("@project-version@", "0.2.0")) != [])

DE = "## 0.2.0\n\n- Works on German game clients.\n\n## 0.1.0\n\n- German.\n"
expect("German alone warns, in either file",
       len(language_warnings("v0.2.0", DE, DE)) == 2)
expect("Deutsch (German) does not warn",
       language_warnings("v0.2.0", DE.replace("German game", "Deutsch (German) game"), "") == [])
expect("an older section saying German does not warn",
       language_warnings("v0.2.0", LOG + "\n- German.\n", "") == [])
expect("Germany is not the language",
       language_warnings("v0.2.0", "## 0.2.0\n\n- Germany.\n", "") == [])
expect("a missing NEWS.md does not warn", language_warnings("v0.2.0", LOG, None) == [])

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
with open(os.path.join(root, "Blackthornes_TS.toc"), encoding="utf-8") as f:
    expect("the real TOC is set up for tags", "@project-version@" in f.read())

# Played from a checkout the addon shows ns.RELEASED_VERSION, so it must be
# the changelog's newest: the release PR changes both together.
with open(os.path.join(root, "Core", "Init.lua"), encoding="utf-8") as f:
    shown = released_version(f.read())
if os.path.exists(os.path.join(root, "CHANGELOG.md")):
    with open(os.path.join(root, "CHANGELOG.md"), encoding="utf-8") as f:
        newest = next((HEADING.match(line).group(1) for line in f
                       if HEADING.match(line)), None)
    expect("Core/Init.lua's RELEASED_VERSION (%s) is CHANGELOG.md's newest (%s)"
           % (shown, newest), shown == newest)
else:
    expect("Core/Init.lua has a RELEASED_VERSION", shown is not None)

print("  check_release: %d checks, %d failure(s)" % (checks, failures))
sys.exit(1 if failures else 0)
