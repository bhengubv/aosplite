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

# Paths a human has looked at and ruled out. See the file's own header.
allow = set()
_fp = os.path.join(self_dir, "tools", "known-false-positives.txt")
try:
    for line in open(_fp, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if line:
            allow.add(line.rstrip("/"))
except OSError:
    pass

# Projects the tiers remove. Entries inside XML comments are deliberately
# kept (see the manifests) and are not checked.
removed = []
for f in sorted(glob.glob(os.path.join(self_dir, "manifests", "prune-tier*.xml"))):
    for e in ET.parse(f).getroot().findall("remove-project"):
        if e.get("name"):
            removed.append(e.get("name"))

# repo name -> tree path, and only those genuinely absent. A project a
# local manifest kept is not a problem. Keep the repo name against the
# path: the report has to tell you which manifest line to change, and
# "device/sample" and "platform/device/sample" are not the same string.
absent = []
repo_name = {}
for name in removed:
    p = name[len("platform/"):] if name.startswith("platform/") else name
    if not os.path.exists(os.path.join(tree, p)) and p not in allow:
        absent.append(p)
        repo_name[p] = name

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
# breaks the build.
#
# A .mk reference depends on how the path is used, and the difference is
# the whole game:
#
#   PRODUCT_COPY_FILES += device/sample/etc/apns-full-conf.xml:...
#       a real file dependency. ninja stops at packaging with "missing and
#       no known rule to make it". This is what device/sample was.
#
#   include device/foo/bar.mk  /  $(call inherit-product, device/foo/x.mk)
#       a real file dependency, and fatal earlier - make cannot read it.
#
#   SOME_LIST += hardware/qcom/wlan
#       a path in a variable. Nothing opens it. Harmless.
#
# Classifying by use is far more accurate than guessing from the file's
# location, and it is why the earlier version reported eleven device
# makefiles belonging to other phones.
FILE_DEP = re.compile(
    r'(PRODUCT_COPY_FILES|LOCAL_SRC_FILES|LOCAL_PATH|\binclude\b|'
    r'inherit-product(?:-if-exists)?|add_lunch_combo)'
)

blocking = collections.defaultdict(set)   # path -> referencing .bp files
filedep = collections.defaultdict(set)    # path -> .mk files that open it
advisory = collections.defaultdict(set)   # path -> .mk files that only name it

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
        rel = os.path.relpath(fp, tree)
        here = os.path.dirname(rel)
        for m in pattern.finditer(text):
            hit = m.group(1).rstrip("/")

            # Soong and Make paths are relative to the file's own
            # directory. "sdk/foo" inside art/build/sdk/Android.bp means
            # art/build/sdk/foo, which exists and has nothing to do with
            # the pruned platform/sdk project. Resolving that first is
            # what separates a real reference from a coincidence of
            # names - without it, every project whose last path segment
            # is a common word reports constantly.
            if here and os.path.exists(os.path.join(tree, here, hit)):
                continue

            # Same coincidence one level up: a path that resolves
            # anywhere in the surviving tree is not a reference to a
            # project that is gone.
            if os.path.exists(os.path.join(tree, hit)):
                continue

            if fn.endswith(".bp"):
                blocking[hit].add(rel)
                continue

            # Classify the makefile reference by the line it sits on.
            line_start = text.rfind("\n", 0, m.start()) + 1
            line_end = text.find("\n", m.end())
            line = text[line_start:line_end if line_end != -1 else len(text)]
            (filedep if FILE_DEP.search(line) else advisory)[hit].add(
                "%s: %s" % (rel, line.strip()[:100]))

print("scanned   : %d build files" % scanned)
print()

# Which manifest file holds the entry for a given project, so the report
# can name the line to change rather than leaving you to grep for it.
entry_file = {}
for f in sorted(glob.glob(os.path.join(self_dir, "manifests", "prune-tier*.xml"))):
    for e in ET.parse(f).getroot().findall("remove-project"):
        if e.get("name"):
            entry_file[e.get("name")] = os.path.basename(f)

def fix_for(path):
    name = repo_name.get(path, path)
    return (name, entry_file.get(name, "(entry not found)"))

if blocking:
    print("LIKELY BLOCKING - referenced from Android.bp. Soong parses every")
    print("Android.bp in the tree, so these fail as soon as the referencing")
    print("module is built - which may be hours in:")
    print()
    for path in sorted(blocking, key=lambda p: -len(blocking[p])):
        name, where = fix_for(path)
        print("  %s" % path)
        print("      referenced by:")
        for r in sorted(blocking[path])[:3]:
            print("        %s" % r)
        if len(blocking[path]) > 3:
            print("        ... and %d more" % (len(blocking[path]) - 3))
        print("      fix: comment out in manifests/%s" % where)
        print("           <remove-project name=\"%s\" optional=\"true\"/>" % name)
        print("           repo sync -c -j$(nproc) --no-clone-bundle %s" % name)
        print()

if filedep:
    print("BLOCKING - a makefile opens one of these paths. PRODUCT_COPY_FILES,")
    print("include and inherit-product are real file dependencies: the build")
    print("stops with \"missing and no known rule to make it\", at packaging,")
    print("after everything has compiled. This is what device/sample was:")
    print()
    for path in sorted(filedep, key=lambda p: -len(filedep[p])):
        name, where = fix_for(path)
        print("  %s" % path)
        for r in sorted(filedep[path])[:3]:
            print("        %s" % r)
        if len(filedep[path]) > 3:
            print("        ... and %d more" % (len(filedep[path]) - 3))
        print("      fix: comment out in manifests/%s" % where)
        print("           <remove-project name=\"%s\" optional=\"true\"/>" % name)
        print("           repo sync -c -j$(nproc) --no-clone-bundle %s" % name)
        print()

if advisory:
    print("ADVISORY - the path is only named in a variable, never opened.")
    print("Nothing reads it, so nothing breaks. Listed for completeness:")
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

if blocking or filedep:
    print()
    print("%d blocking reference(s). Each fails the build - the .bp ones when"
          % (len(blocking) + len(filedep)))
    print("the module is reached, the makefile ones at packaging. The fix for")
    print("each is printed above it.")
    sys.exit(1)
sys.exit(0)
PY
