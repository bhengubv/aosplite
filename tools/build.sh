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
