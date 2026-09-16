#!/usr/bin/env bash
# apply-patches.sh [tree]
#
#   tools/apply-patches.sh ~/android
#
# Reapplies every patch in patches/ to the tree.
#
# Why this exists
# ---------------
# repo sync overwrites the projects these patch. A change made by hand in
# bionic/ or build/soong/ survives exactly until the next sync, and then it
# is gone with no message - the build simply starts behaving differently
# and nobody knows why.
#
# That is not hypothetical here. The hardened_malloc integration lived as
# four uncommitted edits in one WSL tree for weeks. It was one sync from
# being lost, and the machine holding it was the only copy - the same
# failure shape as the com.circleos.server sources that exist on one build
# box and in no repository.
#
# So: patches are the unit. This script is what makes them a default rather
# than something somebody remembers.
#
# It is idempotent. A patch already applied is detected and skipped, so
# running it twice is safe and running it after a partial sync is safe.
#
# Exit 0 = tree carries every patch. Exit 1 = at least one would not apply.

set -uo pipefail

TREE="${1:-$HOME/android}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHES="$SELF/patches"

BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; OFF=""
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[1;31m'
    GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; OFF=$'\033[0m'
fi
ok()   { printf '  %sok%s      %s\n' "$GRN" "$OFF" "$1"; }
skip() { printf '  %sapplied%s %s\n' "$DIM" "$OFF" "$1"; }
warn() { printf '  %sWARN%s    %s\n' "$YEL" "$OFF" "$1"; }
bad()  { printf '  %sFAIL%s    %s\n' "$RED" "$OFF" "$1"; }

[ -d "$TREE" ] || { echo "no tree at $TREE" >&2; exit 2; }
[ -d "$PATCHES" ] || { echo "no patches/ at $PATCHES" >&2; exit 2; }

# Which project does a patch belong to? The paths inside a git diff are
# relative to the project it was generated in, so the mapping has to be
# stated. Adding a patch means adding a line here.
project_for() {
    case "$(basename "$1")" in
        0001-sepolicy-*)  echo "system/sepolicy" ;;
        0002-bionic-*)    echo "bionic" ;;
        0003-soong-*)     echo "build/soong" ;;
        0004-make-*)      echo "build/make" ;;
        *)                echo "" ;;
    esac
}

printf '%sapply-patches%s  tree=%s\n\n' "$BOLD" "$OFF" "$TREE"

applied=0; already=0; failed=0; unknown=0

for p in "$PATCHES"/*.patch; do
    [ -e "$p" ] || continue
    name=$(basename "$p")
    proj=$(project_for "$p")

    if [ -z "$proj" ]; then
        warn "$name - no project mapping in apply-patches.sh; skipped"
        unknown=$((unknown+1))
        continue
    fi

    d="$TREE/$proj"
    if [ ! -d "$d/.git" ]; then
        warn "$name - $proj is not in this tree; skipped"
        unknown=$((unknown+1))
        continue
    fi

    # --check tells us whether it would apply, without touching anything.
    # -R --check tells us whether it is ALREADY applied. Testing both is
    # what makes this idempotent: a patch that fails forward and succeeds
    # in reverse is not an error, it is done.
    if git -C "$d" apply --check "$p" >/dev/null 2>&1; then
        if git -C "$d" apply "$p" >/dev/null 2>&1; then
            ok "$name -> $proj"
            applied=$((applied+1))
        else
            bad "$name -> $proj applied cleanly in --check and then failed"
            failed=$((failed+1))
        fi
    elif git -C "$d" apply -R --check "$p" >/dev/null 2>&1; then
        skip "$name -> $proj"
        already=$((already+1))
    else
        bad "$name -> $proj will not apply, and is not already applied.
          The project has moved under the patch. Regenerate it:
            cd $d && git diff <files> > $p"
        failed=$((failed+1))
    fi
done

echo
printf '  %d applied, %d already present, %d skipped, %d failed\n' \
       "$applied" "$already" "$unknown" "$failed"

if [ "$failed" -gt 0 ]; then
    echo
    echo "  A patch that will not apply is not a warning. The tree is missing"
    echo "  a change the build expects - for the hardened_malloc ones that"
    echo "  means the allocator silently reverts to Scudo and nothing says so."
    exit 1
fi
exit 0
