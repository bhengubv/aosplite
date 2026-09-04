#!/usr/bin/env bash
# init.sh - shallow-init an AOSP tree and install the prune tiers.
#
#   tools/init.sh <target-dir> [aosp-branch] [tier-count]
#
# Default branch is android-15.0.0_r20. Default is all five tiers; pass a
# lower number to apply fewer.
#
# Applying tiers one at a time and running `m nothing` between them is
# the way to find out which one broke your target. This script does not
# do that for you.

set -euo pipefail

DIR="${1:?usage: init.sh <target-dir> [branch] [tier-count]}"
BRANCH="${2:-android-15.0.0_r20}"
TIERS="${3:-5}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$DIR"
cd "$DIR"

repo init -u https://android.googlesource.com/platform/manifest \
    -b "$BRANCH" --depth=1 --no-tags

mkdir -p .repo/local_manifests
for n in $(seq 1 "$TIERS"); do
    src=$(ls "$SELF"/manifests/prune-tier"$n"-*.xml 2>/dev/null | head -1)
    [ -n "$src" ] || continue
    cp "$src" .repo/local_manifests/
    echo "installed $(basename "$src")"
done

echo
echo "Tiers installed. Next:"
echo "  repo sync -c -j4 --no-clone-bundle --prune"
echo "  $SELF/tools/verify-manifest.sh $SELF/manifests"
