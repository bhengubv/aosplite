#!/usr/bin/env bash
# verify-manifest.sh - check prune entries against a real AOSP manifest.
#
# A <remove-project> naming a project that does not exist is a SILENT
# no-op: no error, no warning, no saving. Project names move between
# releases, so a prune list that worked last year can quietly stop
# working and you would never be told.
#
# Two ways to run it.
#
#   From the root of a synced tree, checking .repo/manifests/default.xml:
#       /path/to/aosplite/tools/verify-manifest.sh
#
#   Against a release tag, no tree needed - fetches from googlesource:
#       tools/verify-manifest.sh --tag android-15.0.0_r20
#
# Exits non-zero if any entry is dead.

set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_DIR="$SELF/manifests"
SRC=""
TMP=""

case "${1:-}" in
    --tag)
        TAG="${2:?usage: $0 --tag <android-release-tag>}"
        TMP=$(mktemp)
        URL="https://android.googlesource.com/platform/manifest/+/refs/tags/$TAG/default.xml?format=TEXT"
        echo "fetching $TAG"
        curl -sSfL "$URL" | base64 -d > "$TMP"
        SRC="$TMP"
        ;;
    "")
        SRC=".repo/manifests/default.xml"
        if [ ! -f "$SRC" ]; then
            echo "error: $SRC not found." >&2
            echo "Run from the root of a synced tree, or use --tag <release>." >&2
            exit 1
        fi
        ;;
    *)
        SRC="$1"
        ;;
esac

known=$(mktemp)
grep -o 'name="[^"]*"' "$SRC" | sed 's/name="//;s/"//' | sort -u > "$known"
echo "$(wc -l < "$known") projects in reference manifest"
echo

rc=0
total=0
dead=0
for f in "$MANIFEST_DIR"/prune-*.xml; do
    [ -e "$f" ] || continue
    n=0; m=0
    while IFS= read -r name; do
        n=$((n+1))
        if ! grep -qxF "$name" "$known"; then
            printf '  MISSING  %s\n' "$name"
            m=$((m+1))
        fi
    done < <(grep -o 'remove-project name="[^"]*"' "$f" | sed 's/.*name="//;s/"//')
    printf '%-32s %3d entries, %d dead\n' "$(basename "$f")" "$n" "$m"
    total=$((total+n)); dead=$((dead+m))
done

echo
echo "$total entries checked, $dead dead"
[ "$dead" -eq 0 ] || rc=1

rm -f "$known" ${TMP:+"$TMP"}

if [ $rc -ne 0 ]; then
    echo
    echo "Entries marked MISSING do nothing at all. Either the project was"
    echo "renamed upstream, or it no longer exists. Fix or drop those lines."
fi
exit $rc
