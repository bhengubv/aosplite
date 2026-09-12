#!/usr/bin/env bash
# preflight.sh [tree]
#
#   tools/preflight.sh ~/android
#
# Checks a synced tree for references to projects the prune tiers removed,
# BEFORE you spend hours finding out one at a time.
#
# Why this exists: every pruning failure found so far has the same shape -
# a build file in the surviving tree names a path inside a project that was
# pruned. The build reports them late, one per run:
#
#   platform/cts                   analysis, ~20 min in
#   test/app_compat/csuite         analysis
#   test/vts-testcase/hal          analysis
#   device/sample                  packaging, after analysis
#   prebuilts/jdk/jdk8             action 705 of 165,364
#
# The last two are the expensive ones and analysis can never catch them:
# ALLOW_MISSING_DEPENDENCIES turns a missing path into a runtime
# "echo ... && false", so it only fails when that action runs.
#
# Exit 0 = no .bp references to pruned projects. Exit 1 = there are.
# Exit 1 is a warning worth acting on, not proof of failure: Soong only
# errors on a missing path once the referencing module is actually built.

set -eo pipefail

TREE="${1:-$HOME/android}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ -d "$TREE" ] || { echo "no tree at $TREE" >&2; exit 1; }
[ -d "$SELF/manifests" ] || { echo "no manifests at $SELF/manifests" >&2; exit 1; }

python3 - "$TREE" "$SELF" <<'PY'
import os, re, sys, glob, collections
import xml.etree.ElementTree as ET

tree, self_dir = sys.argv[1], sys.argv[2]

# Projects the tiers remove. Entries inside XML comments are deliberately
# kept (see the manifests) and are not checked.
removed = []
for f in sorted(glob.glob(os.path.join(self_dir, "manifests", "prune-tier*.xml"))):
    for e in ET.parse(f).getroot().findall("remove-project"):
        if e.get("name"):
            removed.append(e.get("name"))

# repo name -> tree path, and only those genuinely absent. A project a
# local manifest kept is not a problem.
absent = []
for name in removed:
    p = name[len("platform/"):] if name.startswith("platform/") else name
    if not os.path.exists(os.path.join(tree, p)):
        absent.append(p)

print("tree      : %s" % tree)
print("pruned    : %d entries, %d absent from the tree" % (len(removed), len(absent)))
print()

if not absent:
    print("nothing to check.")
    sys.exit(0)

# A path must start at a path boundary, or "sdk/" matches "prebuilts/sdk/"
# and every other suffix. Longest first so nested paths win.
absent.sort(key=len, reverse=True)
pattern = re.compile(
    r'(?:(?<=^)|(?<=[\s"\'=:,(\[]))(' +
    "|".join(re.escape(p) + "/" for p in absent) + r')'
)

# Soong parses EVERY Android.bp in the tree, so a .bp reference always
# breaks the build. A .mk reference only matters if that makefile is
# actually inherited by the product you build - most are another device's.
blocking = collections.defaultdict(set)   # path -> referencing .bp files
advisory = collections.defaultdict(set)   # path -> referencing .mk files

skip_dirs = {".repo", ".git", "out"}
scanned = 0
for root, dirs, files in os.walk(tree):
    dirs[:] = [d for d in dirs if d not in skip_dirs]
    for fn in files:
        if not (fn.endswith(".bp") or fn.endswith(".mk")):
            continue
        fp = os.path.join(root, fn)
        scanned += 1
        try:
            with open(fp, "r", encoding="utf-8", errors="ignore") as fh:
                text = fh.read()
        except OSError:
            continue
        for m in pattern.finditer(text):
            hit = m.group(1).rstrip("/")
            rel = os.path.relpath(fp, tree)
            (blocking if fn.endswith(".bp") else advisory)[hit].add(rel)

print("scanned   : %d build files" % scanned)
print()

if blocking:
    print("LIKELY BLOCKING - referenced from Android.bp. Soong parses every")
    print("Android.bp in the tree, so these fail as soon as the referencing")
    print("module is built - which may be hours in:")
    for path in sorted(blocking, key=lambda p: -len(blocking[p])):
        print("  %s" % path)
        for r in sorted(blocking[path])[:3]:
            print("      %s" % r)
        if len(blocking[path]) > 3:
            print("      ... and %d more" % (len(blocking[path]) - 3))
    print()

if advisory:
    print("ADVISORY - referenced only from .mk files. These matter only if")
    print("your product inherits that makefile; most belong to other devices:")
    for path in sorted(advisory, key=lambda p: -len(advisory[p]))[:15]:
        print("  %-44s %d file(s)" % (path, len(advisory[path])))
    if len(advisory) > 15:
        print("  ... and %d more" % (len(advisory) - 15))
    print()

if not blocking and not advisory:
    print("clean: no build file references a pruned project.")

print("Module types and defaults (csuite_test, cts_defaults) are not paths")
print("and cannot appear above. Run the analysis gate for those:")
print()
print("    tools/build.sh <lunch-target> nothing")
print()
print("which runs Soong and stops before compiling anything.")

if blocking:
    print()
    print("%d .bp reference(s) to pruned projects. If one of those modules" % len(blocking))
    print("gets built, it fails. Comment the entry out in the relevant")
    print("manifest - keep the line, add the reason - then:")
    print()
    print("    repo sync -c -j$(nproc) --no-clone-bundle <project>")
    sys.exit(1)
sys.exit(0)
PY
