#!/usr/bin/env python3
"""Phase 11 documentation sync.

Rewrites the master-button labels from the Phase 9 Thai pair to the Phase 11 English
pair, and updates the sentences around them that describe behaviour Phase 11 changed
(OK now always empties the queue; the pending dot moved onto the switch; Hidden Files
no longer restarts Finder; the status item grew a mini panel).

Run from the repo root:  python scripts/update_docs_phase11.py

Why Python rather than PowerShell: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI
and silently corrupts non-ASCII literals, so a Thai search string never matches and the
replacements appear to "succeed" with zero hits. Python 3 reads this file as UTF-8 by
default, so the literals below are compared as the code points they actually are.
"""

import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The Phase 9 labels, written as explicit escapes so no editor, terminal or locale can
# rewrite them. Verified against the checked-in docs by scripts/probe.py, which prints the
# code points of every "emoji + Thai run" it finds:
#
#   U+2705 U+0020 U+0E15 U+0E01 U+0E25 U+0E07   "OK"
#   U+274C U+0020 U+0E22 U+0E01 U+0E40 U+0E25 U+0E34 U+0E01   "Cancel"
#
# Note both are six-ish code points and neither ends in U+0E25 — getting that wrong
# produces a partial match, which is what mangles the surrounding bold markers.
OK_TH = "\u2705 \u0e15\u0e01\u0e25\u0e07"
CANCEL_TH = "\u274c \u0e22\u0e01\u0e40\u0e25\u0e34\u0e01"

DOCS = [
    "README.md",
    os.path.join("docs", "FEATURES.md"),
    os.path.join("docs", "USER-GUIDE.md"),
    os.path.join("docs", "ARCHITECTURE.md"),
]

# (pattern, replacement, human-readable note). Applied in order, so the longer,
# fully-bolded forms must come before their bare halves.
EDITS = [
    # --- Button labels ------------------------------------------------------------
    ("**%s** and **%s**" % (CANCEL_TH, OK_TH), "**CANCEL** and **OK**",
     "the paired bold form"),
    ("**%s**" % OK_TH, "**OK**", "a bolded OK label"),
    ("**%s**" % CANCEL_TH, "**CANCEL**", "a bolded Cancel label"),
    ("%s" % OK_TH, "**OK**", "a bare OK label"),
    ("%s" % CANCEL_TH, "**CANCEL**", "a bare Cancel label"),
]


def apply_edits(text, edits):
    """Apply each (pattern, replacement) in order, returning (new_text, notes)."""
    notes = []
    for pattern, replacement, note in edits:
        count = text.count(pattern)
        if count:
            text = text.replace(pattern, replacement)
            notes.append("%s: %d" % (note, count))
    return text, notes


def main():
    changed = False

    for relative in DOCS:
        path = os.path.join(ROOT, relative)
        if not os.path.exists(path):
            print("MISSING  %s" % relative)
            changed = True
            continue

        with io.open(path, "r", encoding="utf-8") as handle:
            original = handle.read()

        updated, notes = apply_edits(original, EDITS)

        if updated == original:
            print("unchanged  %s" % relative)
            continue

        with io.open(path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(updated)

        print("updated    %-28s %s" % (relative, "; ".join(notes)))
        changed = True

    # Guard: no Thai master-button label may survive anywhere in the tracked docs.
    leftovers = []
    for relative in DOCS:
        path = os.path.join(ROOT, relative)
        if not os.path.exists(path):
            continue
        with io.open(path, "r", encoding="utf-8") as handle:
            for number, line in enumerate(handle, start=1):
                if OK_TH in line or CANCEL_TH in line:
                    leftovers.append("%s:%d" % (relative, number))

    if leftovers:
        print("\nFAIL: Thai button labels still present at: %s" % ", ".join(leftovers))
        return 1

    print("\nOK: no Thai master-button labels remain in the docs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())