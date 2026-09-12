#!/usr/bin/env bash
# manifest-diff.sh - what changed between two AOSP releases.
#
# This is the per-release maintenance job. New projects arrive included
# by default, so bloat creeps back in unless someone looks at the list.
#
#   tools/manifest-diff.sh old-default.xml new-default.xml

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 <old-default.xml> <new-default.xml>" >&2
    exit 1
fi

# Reference manifests have no commented-out entries, so a grep is fine
# here. Do not copy this into anything that reads the prune tiers - those
# deliberately keep disabled entries inside XML comments, and a grep
# counts them as live. See entries() in verify-manifest.sh.
names() { grep -o 'name="[^"]*"' "$1" | sed 's/name="//;s/"//' | sort -u; }

old=$(mktemp); new=$(mktemp)
names "$1" > "$old"
names "$2" > "$new"

echo "=== ADDED upstream (review: keep or prune) ==="
comm -13 "$old" "$new"
echo
echo "=== REMOVED upstream (drop from prune lists if present) ==="
comm -23 "$old" "$new"
echo
printf 'old: %s projects\nnew: %s projects\n' "$(wc -l < "$old")" "$(wc -l < "$new")"

rm -f "$old" "$new"
