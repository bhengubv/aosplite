#!/usr/bin/env bash
# build.sh <lunch-target> [make-target]
#
#   tools/build.sh circle_arm64-bp4a-userdebug systemimage
#
# The environment is set here, in a file, on purpose. Every variable below
# was learned by losing a build to it. Setting them by hand each time is
# how they get set differently each time.

# No -u: build/envsetup.sh reads unbound variables (TOP among them) and
# dies immediately under set -u.
set -eo pipefail

TREE="${AOSP_TREE:-$HOME/android}"

# WSL's ~/.cache is root-owned on a default install. Go's build cache and
# ccache both die with "permission denied" if left pointing at it:
#   failed to initialize build cache at ~/.cache/go-build: permission denied
export GOCACHE="$HOME/buildcache/go"
export XDG_CACHE_HOME="$HOME/buildcache/xdg"

# The prune tiers remove projects that fuzzer and test modules still name.
# Without this, Soong does not skip them - it panics, in
# system/sepolicy/build/soong/validate_bindings.go:
#   panic(fmt.Errorf("Fuzzer doesn't exist : %s", fuzzer))
export ALLOW_MISSING_DEPENDENCIES=true

# DO NOT set USE_CCACHE here, and do not set it in your shell either.
# It controls CC_WRAPPER, which is prepended to every C++ compile command.
# Changing it - in either direction - makes ninja see ~100,000 changed
# command lines and rebuild all of them. A 90-minute incremental becomes a
# 28-hour full build, and Soong re-reads the whole tree on top of that.
# Whatever out/ was built with, leave it alone.

usage() {
    echo "usage: build.sh <lunch-target> [make-target]" >&2
    echo "  e.g. build.sh circle_arm64-bp4a-userdebug systemimage" >&2
    exit 1
}

LUNCH="${1:-}"; [ -n "$LUNCH" ] || usage
TARGET="${2:-systemimage}"

# The release config is the middle field of the lunch target and it is not
# cosmetic. trunk_staging produces a pre-release image - codename Baklava,
# preview_sdk=1, llndk 202604 - which will not boot against a released
# vendor partition. A released config (bp2a, bp4a, ...) gives REL / 202504.
case "$LUNCH" in
    *-trunk_staging-*)
        echo "warning: trunk_staging builds a pre-release image." >&2
        echo "         It will not boot on a retail device." >&2
        echo "         Use a released config, e.g. ${LUNCH/trunk_staging/bp4a}" >&2
        ;;
esac

[ -d "$TREE" ] || { echo "no tree at $TREE (set AOSP_TREE)" >&2; exit 1; }

# --- pruning checks -----------------------------------------------------
#
# These are not optional and there is no flag to turn them off. A pruned
# tree reports this class of breakage one item per build, hours apart - see
# "How a wrong cut presents" in docs/RATIONALE.md - so finding it up front
# is the difference between minutes and days.
#
# Leaving them as scripts somebody might remember to run did not work:
# lint_api was sitting in check-modules.sh output before the build that
# failed on it, and nobody looked.
#
# Everything below is written so that a check which cannot run is a
# failure, never a pass. The first version of this gate resolved the script
# paths through an undefined variable, found nothing, and printed "checks
# passed" in two seconds. That is worse than having no gate at all.

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pruned_tree() {
    [ -d "$TREE/.repo/local_manifests" ] &&
        ls "$TREE"/.repo/local_manifests/*.xml >/dev/null 2>&1
}

if pruned_tree; then
    echo "pruned tree - running checks"
    echo

    CHECKS="check-env preflight check-modules"

    for check in $CHECKS; do
        script="$SELF/tools/$check.sh"
        if [ ! -f "$script" ]; then
            echo "ERROR: $script not found." >&2
            echo "The checks are part of the build. Refusing to build without" >&2
            echo "them rather than pretending they passed." >&2
            exit 2
        fi
    done

    failed=""
    for check in $CHECKS; do
        script="$SELF/tools/$check.sh"
        echo "  $check.sh ..."
        set +e
        # check-env wants the target as well - it is the only one that can
        # tell you the lunch config is staging or the make target builds
        # nothing.
        if [ "$check" = "check-env" ]; then
            out=$(bash "$script" "$TREE" "$LUNCH" "$TARGET" 2>&1)
        else
            out=$(bash "$script" "$TREE" 2>&1)
        fi
        rc=$?
        set -e
        case "$rc" in
            0) echo "    clean" ;;
            1) failed="$failed $check"
               echo
               echo "$out" | sed -n '1,40p'
               echo ;;
            *) echo "ERROR: $check.sh exited $rc - it did not complete." >&2
               echo "$out" | tail -5 >&2
               exit 2 ;;
        esac
    done

    if [ -n "$failed" ]; then
        cat >&2 <<'BLOCKED'

Not building. The checks found references to projects that are not in this
tree. Each one fails the build - some during analysis, some only when the
module is reached, hours in.

Fix by un-pruning: comment the remove-project entry out in the relevant
manifest, keep the line, write down why, then

    repo sync -c -j$(nproc) --no-clone-bundle <project>

Both scripts over-report - generated module names and Soong-namespace
prebuilts look undefined. Read the list; un-prune what is real. If you have
checked and every remaining entry is a false positive, record that by
adding the name to tools/known-false-positives.txt, which both scripts
read. There is deliberately no flag to skip the checks: a skip flag is how
you end up finding these one per build again.
BLOCKED
        exit 1
    fi

    echo
    echo "checks clean"
    echo
fi

mkdir -p "$GOCACHE" "$XDG_CACHE_HOME"
cd "$TREE"

# shellcheck disable=SC1091
source build/envsetup.sh >/dev/null
lunch "$LUNCH" >/dev/null

echo "tree     : $TREE"
echo "lunch    : $LUNCH"
echo "target   : $TARGET"
echo "jobs     : $(nproc)"
echo "memory   : $(free -g | awk '/^Mem:/{print $2"G ram"} /^Swap:/{print $2"G swap"}' | tr '\n' ' ')"
echo

m -j"$(nproc)" "$TARGET"
