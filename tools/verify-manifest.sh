#!/usr/bin/env bash
# verify-manifest.sh - check prune entries against the real AOSP manifest.
#
# A <remove-project> naming a project that does not exist is a SILENT
# no-op. No error, no warning, no saving. This is the single most common
# way a prune list quietly stops working after an AOSP release.
#
# Run from the root of a synced tree:
#   tools/verify-manifest.sh /path/to/aosplite/manifests

set -euo pipefail

MANIFEST_DIR="${1:-manifests}"
AOSP_MANIFEST=".repo/manifests/default.xml"

if [ ! -f "$AOSP_MANIFEST" ]; then
    echo "error: $AOSP_MANIFEST not found - run this from the root of a synced tree" >&2
    exit 1
fi

known=$(mktemp)
grep -o 'name="[^"]*"' "$AOSP_MANIFEST" | sed 's/name="//;s/"//' | sort -u > "$known"

rc=0
for f in "$MANIFEST_DIR"/prune-*.xml; do
    [ -e "$f" ] || continue
    echo "--- $(basename "$f")"
    while IFS= read -r name; do
        if grep -qxF "$name" "$known"; then
            printf '  ok      %s\n' "$name"
        else
            printf '  MISSING %s\n' "$name"
            rc=1
        fi
    done < <(grep -o 'remove-project name="[^"]*"' "$f" | sed 's/.*name="//;s/"//')
done

rm -f "$known"

if [ $rc -ne 0 ]; then
    echo
    echo "Entries marked MISSING do nothing. Either the project was renamed"
    echo "upstream, or it no longer exists. Fix or drop those lines."
fi
exit $rc
